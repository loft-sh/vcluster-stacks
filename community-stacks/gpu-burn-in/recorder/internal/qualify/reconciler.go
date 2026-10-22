// Package qualify records gpu-burn-in results on the servers they qualified.
//
// When a StackInstance of a watched StackTemplate has captured its report task's outputs, the
// reconciler finds the server the run tested (tenant cluster -> NodeClaims -> the Machines whose
// node-claim annotation names them), creates a QualificationReport for it, writes the result label
// and annotations to the Machine or its BareMetalHost, optionally updates the NetBox device, and optionally deletes the tenant
// cluster to release the server. It must run before the tenant cluster is deleted, because the
// node-claim annotation disappears with the claim; with releaseServer it does the deletion itself.
package qualify

import (
	"context"
	"fmt"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/tools/record"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/builder"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/event"
	"sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/predicate"
)

var (
	StackInstanceGVK = schema.GroupVersionKind{Group: "storage.loft.sh", Version: "v1", Kind: "StackInstance"}
	stackTemplateGVK = schema.GroupVersionKind{Group: "storage.loft.sh", Version: "v1", Kind: "StackTemplate"}
	nodeClaimGVK     = schema.GroupVersionKind{Group: "storage.loft.sh", Version: "v1", Kind: "NodeClaim"}
	storageMachine   = schema.GroupVersionKind{Group: "storage.loft.sh", Version: "v1", Kind: "Machine"}
	nodeProviderGVK  = schema.GroupVersionKind{Group: "storage.loft.sh", Version: "v1", Kind: "NodeProvider"}
	tenantClusterGVK = schema.GroupVersionKind{Group: "management.loft.sh", Version: "v1", Kind: "VirtualClusterInstance"}
)

// machineNodeClaimAnnotation names the NodeClaim ("<namespace>/<name>") holding a Machine.
const machineNodeClaimAnnotation = "machines.vcluster.com/node-claim"

// Reconciler records one StackInstance's result.
type Reconciler struct {
	// Client reads Platform storage objects (cached) and writes management objects.
	Client client.Client
	// Reader reads without the cache: the outputs Secret, which the controller may only get.
	Reader   client.Reader
	Clusters ClusterClients
	NetBox   *NetBox
	Events   record.EventRecorder
	Config   Config
	// Now is the clock for report retention; nil uses time.Now.
	Now func() time.Time
}

func (r *Reconciler) now() time.Time {
	if r.Now != nil {
		return r.Now()
	}
	return time.Now()
}

func newObj(gvk schema.GroupVersionKind) *unstructured.Unstructured {
	u := &unstructured.Unstructured{}
	u.SetGroupVersionKind(gvk)
	return u
}

func newList(gvk schema.GroupVersionKind) *unstructured.UnstructuredList {
	l := &unstructured.UnstructuredList{}
	l.SetGroupVersionKind(gvk.GroupVersion().WithKind(gvk.Kind + "List"))
	return l
}

func (r *Reconciler) event(obj client.Object, kind, reason, msg string) {
	if r.Events != nil {
		r.Events.Event(obj, kind, reason, msg)
	}
}

func (r *Reconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)
	si := newObj(StackInstanceGVK)
	if err := r.Client.Get(ctx, req.NamespacedName, si); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}
	if !r.Config.watches(templateName(si)) || si.GetDeletionTimestamp() != nil {
		return ctrl.Result{}, nil
	}
	if taskPhase(si, reportTask) != "Healthy" {
		return ctrl.Result{}, nil
	}

	template := newObj(stackTemplateGVK)
	if err := r.Client.Get(ctx, types.NamespacedName{Name: templateName(si)}, template); err != nil {
		if !apierrors.IsNotFound(err) {
			return ctrl.Result{}, err
		}
		template = nil
	}
	run := runParams(si, template)
	if !run.RecordResult {
		return ctrl.Result{}, nil
	}

	secret := &corev1.Secret{}
	key := types.NamespacedName{Namespace: si.GetNamespace(), Name: outputsSecretName(si.GetName())}
	if err := r.Reader.Get(ctx, key, secret); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}
	set, _, _ := unstructured.NestedMap(si.Object, "spec", "parameters")
	profile := stringParams(set)["profile"]
	report, ok := reportFromOutputs(secret.Data, profile)
	if !ok {
		// Healthy but not captured yet; the outputs Secret update does not wake us, so look again.
		return ctrl.Result{RequeueAfter: requeueCapture}, nil
	}

	full, err := parseStackReport(secret.Data[reportJSONOutputKey])
	if err != nil {
		r.event(si, corev1.EventTypeWarning, "RecordFailed", err.Error())
		return ctrl.Result{}, err
	}

	claims, err := r.claimsFor(ctx, si)
	if err != nil {
		return ctrl.Result{}, err
	}
	machines, err := r.machinesHolding(ctx, claims)
	if err != nil {
		return ctrl.Result{}, err
	}
	// A server from a provider without an inventory, such as a cloud VM a Terraform provider creates
	// per NodeClaim, has no Machine to label. Its run still becomes a QualificationReport, so it shows
	// in the history and on the dashboards; nothing is labeled and NetBox is not touched.
	reportOnly := false
	if len(machines) == 0 {
		if len(claims) == 0 {
			r.event(si, corev1.EventTypeWarning, "NoMachine",
				fmt.Sprintf("result %s not recorded: tenant cluster %s holds no NodeClaim", report.Result, tenantCluster(si)))
			logger.Info("no NodeClaim for this run; was the tenant cluster deleted before the run was recorded?")
			return ctrl.Result{}, nil
		}
		machines, reportOnly = reportOnlyMachines(claims, full), true
		r.event(si, corev1.EventTypeNormal, "ReportOnly",
			fmt.Sprintf("no inventory Machine for tenant cluster %s: recording %d report(s) only, with no label", tenantCluster(si), len(machines)))
	}
	group := ""
	if len(full.Nodes) > 1 {
		group = si.GetNamespace() + "/" + tenantCluster(si)
	}

	runID := fmt.Sprintf("%s/%s/%s", si.GetNamespace(), si.GetName(), si.GetUID())
	for i := range machines {
		verdict, node, ok := forMachine(report, full, &machines[i])
		if !ok {
			r.event(si, corev1.EventTypeWarning, "NoNodeResult",
				fmt.Sprintf("machine %s not recorded: the report has no result for its node", machines[i].GetName()))
			logger.Info("no node result for this Machine; is its node name its host name?", "machine", machines[i].GetName())
			continue
		}
		// The report first: it is the history, and creating it again is a no-op.
		qr := buildReport(si, &machines[i], verdict, full, node, group, r.Config.Topology)
		if reportOnly {
			qr.SetLabels(mergeLabels(qr.GetLabels(), map[string]string{labelNoInventory: "true"}))
		}
		if err := r.createReport(ctx, qr); err != nil {
			r.event(si, corev1.EventTypeWarning, "RecordFailed", fmt.Sprintf("machine %s: %v", machines[i].GetName(), err))
			return ctrl.Result{}, err
		}
		if reportOnly {
			continue
		}
		if err := r.record(ctx, si, &machines[i], verdict, run, runID); err != nil {
			r.event(si, corev1.EventTypeWarning, "RecordFailed", fmt.Sprintf("machine %s: %v", machines[i].GetName(), err))
			return ctrl.Result{}, err
		}
	}

	if run.ReleaseServer {
		vci := newObj(tenantClusterGVK)
		vci.SetNamespace(si.GetNamespace())
		vci.SetName(tenantCluster(si))
		logger.Info("releasing the server: deleting the tenant cluster", "tenantCluster", vci.GetName(), "dryRun", r.Config.DryRun)
		if !r.Config.DryRun {
			if err := r.Client.Delete(ctx, vci); client.IgnoreNotFound(err) != nil {
				return ctrl.Result{}, fmt.Errorf("delete tenant cluster %s: %w", vci.GetName(), err)
			}
		}
		r.event(si, corev1.EventTypeNormal, "Released", fmt.Sprintf("deleted tenant cluster %s after recording %s", vci.GetName(), report.Result))
	}
	return ctrl.Result{}, nil
}

// claimsFor returns the NodeClaims of the run's tenant cluster.
func (r *Reconciler) claimsFor(ctx context.Context, si *unstructured.Unstructured) ([]unstructured.Unstructured, error) {
	tenant := tenantCluster(si)
	claims := newList(nodeClaimGVK)
	if err := r.Client.List(ctx, claims, client.InNamespace(si.GetNamespace())); err != nil {
		return nil, err
	}
	var out []unstructured.Unstructured
	for _, c := range claims.Items {
		if ref, _, _ := unstructured.NestedString(c.Object, "spec", "vClusterRef"); ref == tenant {
			out = append(out, c)
		}
	}
	return out, nil
}

// machinesHolding returns the inventory Machines that hold the given NodeClaims.
func (r *Reconciler) machinesHolding(ctx context.Context, claims []unstructured.Unstructured) ([]unstructured.Unstructured, error) {
	held := map[string]bool{}
	for _, c := range claims {
		held[c.GetNamespace()+"/"+c.GetName()] = true
	}
	if len(held) == 0 {
		return nil, nil
	}
	all := newList(storageMachine)
	if err := r.Client.List(ctx, all); err != nil {
		return nil, err
	}
	var out []unstructured.Unstructured
	for _, m := range all.Items {
		if held[m.GetAnnotations()[machineNodeClaimAnnotation]] {
			out = append(out, m)
		}
	}
	return out, nil
}

// record writes one result to one server. NetBox goes first and the target's run marker last, so
// a failure part way is retried until the marker is written.
func (r *Reconciler) record(ctx context.Context, si, machine *unstructured.Unstructured, rep Report, run RunParams, runID string) error {
	logger := log.FromContext(ctx).WithValues("machine", machine.GetName(), "result", rep.Result, "target", r.Config.Target, "dryRun", r.Config.DryRun)

	var (
		target client.Object
		cli    client.Client
	)
	switch r.Config.Target {
	case TargetMachine:
		if r.Config.recorded(machine, rep, runID) {
			return nil
		}
		m := newObj(managementMachine)
		m.SetName(machine.GetName())
		target, cli = m, r.Client
	case TargetBareMetalHost:
		providerName, _, _ := unstructured.NestedString(machine.Object, "spec", "providerRef")
		provider := newObj(nodeProviderGVK)
		if err := r.Client.Get(ctx, types.NamespacedName{Name: providerName}, provider); err != nil {
			return fmt.Errorf("node provider %s: %w", providerName, err)
		}
		cluster, namespace, name, err := bareMetalHostFor(machine, provider)
		if err != nil {
			return err
		}
		if cli, err = r.Clusters.For(cluster); err != nil {
			return err
		}
		bmh := newObj(bareMetalHost)
		if err := cli.Get(ctx, types.NamespacedName{Namespace: namespace, Name: name}, bmh); err != nil {
			return fmt.Errorf("BareMetalHost %s/%s on cluster %s: %w", namespace, name, cluster, err)
		}
		if r.Config.recorded(bmh, rep, runID) {
			return nil
		}
		target = bmh
		logger = logger.WithValues("bareMetalHost", namespace+"/"+name, "cluster", cluster)
	}

	if run.NetBoxUpdate {
		webURL := machine.GetAnnotations()[netboxDeviceURLAnnotation]
		switch {
		case r.NetBox == nil:
			logger.Info("netboxUpdate is set, but the controller has no NetBox token; skipping NetBox")
		case webURL == "":
			logger.Info("netboxUpdate is set, but the Machine has no NetBox device; skipping NetBox")
		case r.Config.DryRun:
			logger.Info("would update NetBox device", "device", webURL)
		default:
			if err := r.NetBox.Record(ctx, webURL, rep, r.Config.NetBoxAdmitTag, r.Config.NetBoxQualifiedTag); err != nil {
				return fmt.Errorf("NetBox: %w", err)
			}
			logger.Info("updated NetBox device", "device", webURL)
		}
	}

	if err := patchMetadata(ctx, cli, target.(*unstructured.Unstructured), r.Config.metadataPatch(rep, runID), r.Config.DryRun); err != nil {
		return fmt.Errorf("record on %s %s: %w", r.Config.Target, target.GetName(), err)
	}
	if r.Config.DryRun {
		// Nothing is written, so the run marker never lands and every status update logs this again.
		logger.Info("would record qualification result", "failedTests", rep.FailedTests)
		return nil
	}
	logger.Info("recorded qualification result", "failedTests", rep.FailedTests)
	r.event(si, corev1.EventTypeNormal, "Recorded",
		fmt.Sprintf("%s %s: %s=%s", r.Config.Target, target.GetName(), r.Config.key("result"), rep.Result))
	return nil
}

// SetupWithManager watches StackInstances of the configured templates, reacting to status changes.
func (r *Reconciler) SetupWithManager(mgr ctrl.Manager) error {
	watched := predicate.NewPredicateFuncs(func(o client.Object) bool {
		u, ok := o.(*unstructured.Unstructured)
		return ok && r.Config.watches(templateName(u))
	})
	return ctrl.NewControllerManagedBy(mgr).
		Named("gpu-burn-in-recorder").
		For(newObj(StackInstanceGVK), builder.WithPredicates(watched, predicate.Funcs{
			DeleteFunc: func(event.DeleteEvent) bool { return false },
		})).
		Complete(r)
}
