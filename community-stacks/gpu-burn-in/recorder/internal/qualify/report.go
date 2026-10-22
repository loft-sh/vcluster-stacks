package qualify

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"regexp"
	"sort"
	"strings"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"
)

// ReportGVK is the provider-neutral record of one qualification run of one machine.
var ReportGVK = schema.GroupVersionKind{Group: "qualification.vcluster-stacks.io", Version: "v1alpha1", Kind: "QualificationReport"}

// Labels on every QualificationReport, so reports can be selected per machine and result.
const (
	reportGroup     = "qualification.vcluster-stacks.io"
	labelMachine    = reportGroup + "/machine"
	labelResult     = reportGroup + "/result"
	labelProvider   = reportGroup + "/provider"
	labelSourceKind = reportGroup + "/source-kind"
	labelProfile    = reportGroup + "/profile"
	labelGroup      = reportGroup + "/group"
	// labelNoInventory marks a report of a server with no inventory Machine, recorded report-only.
	labelNoInventory    = reportGroup + "/no-inventory"
	reportJSONOutputKey = reportTask + ".reportjson"
)

// stackReport is the report.json the gpu-burn-in report step writes (schema gpu-burn-in.vcluster.com/v1).
type stackReport struct {
	Result       string   `json:"result"`
	FailedTests  []string `json:"failedTests"`
	Summary      string   `json:"summary"`
	AssetID      string   `json:"assetID"`
	Profile      string   `json:"profile"`
	ExpectedGPUs int64    `json:"expectedGPUs"`
	DetectedGPUs int64    `json:"detectedGPUs"`
	StartedAt    string   `json:"startedAt"`
	ReportURI    string   `json:"reportURI"`
	Host         struct {
		Name string            `json:"name"`
		DMI  map[string]string `json:"dmi"`
	} `json:"host"`
	GPUs []struct {
		Index  int64  `json:"index"`
		UUID   string `json:"uuid"`
		Name   string `json:"name"`
		Serial string `json:"serial"`
		Driver string `json:"driver"`
	} `json:"gpus"`
	Tests []struct {
		Test       string             `json:"test"`
		Status     string             `json:"status"`
		Summary    string             `json:"summary"`
		Node       string             `json:"node"`
		StartedAt  string             `json:"startedAt"`
		FinishedAt string             `json:"finishedAt"`
		Metrics    map[string]float64 `json:"metrics"`
	} `json:"tests"`
	Nodes []nodeVerdict `json:"nodes"`
}

// nodeVerdict is one node's own result, from the tests that ran on it.
type nodeVerdict struct {
	Name        string   `json:"name"`
	Result      string   `json:"result"`
	FailedTests []string `json:"failedTests"`
	Summary     string   `json:"summary"`
}

// parseStackReport reads the reportjson output. An empty one, from an older Stack, gives an empty
// report.
func parseStackReport(raw []byte) (stackReport, error) {
	var full stackReport
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &full); err != nil {
			return full, fmt.Errorf("parse report.json: %w", err)
		}
	}
	return full, nil
}

// reportOnlyMachines stands in for the Machines a provider without an inventory does not create:
// one per node the report names (the report's host when it names none), called
// <provider>.<node> like an inventory Machine, so reports, metrics and dashboards treat it the same.
// The provider is the tenant cluster's NodeClaims' provider.
func reportOnlyMachines(claims []unstructured.Unstructured, full stackReport) []unstructured.Unstructured {
	provider, _, _ := unstructured.NestedString(claims[0].Object, "spec", "providerRef")
	var nodes []string
	for _, n := range full.Nodes {
		if n.Name != "" {
			nodes = append(nodes, n.Name)
		}
	}
	if len(nodes) == 0 && full.Host.Name != "" {
		nodes = []string{full.Host.Name}
	}
	if len(nodes) == 0 {
		for _, c := range claims {
			nodes = append(nodes, c.GetName())
		}
	}
	out := make([]unstructured.Unstructured, 0, len(nodes))
	for _, n := range nodes {
		m := newObj(storageMachine)
		m.SetName(provider + "." + n)
		m.Object["spec"] = map[string]any{"providerRef": provider, "displayName": n}
		out = append(out, *m)
	}
	return out
}

func mergeLabels(a, b map[string]string) map[string]string {
	out := map[string]string{}
	for k, v := range a {
		out[k] = v
	}
	for k, v := range b {
		out[k] = v
	}
	return out
}

// forMachine narrows a run's verdict to one machine. A report with nodes[] gives each node its own
// verdict, matched to the Machine by host name: the Machine's name after "<provider>.", as Metal3
// names Machines, or its display name, which NICo sets to the host name. A report without nodes[]
// applies the run's verdict to every machine. ok is false when the report has nodes[] but none for
// this machine; the machine is then not recorded.
func forMachine(rep Report, full stackReport, machine *unstructured.Unstructured) (r Report, node string, ok bool) {
	if len(full.Nodes) == 0 {
		return rep, full.Host.Name, true
	}
	providerRef, _, _ := unstructured.NestedString(machine.Object, "spec", "providerRef")
	displayName, _, _ := unstructured.NestedString(machine.Object, "spec", "displayName")
	host := ""
	if providerRef != "" {
		host = strings.TrimPrefix(machine.GetName(), providerRef+".")
	}
	for _, n := range full.Nodes {
		if n.Name == "" || (n.Name != host && n.Name != displayName) {
			continue
		}
		rep.Result = n.Result
		rep.FailedTests = strings.Join(n.FailedTests, ",")
		rep.Summary = n.Summary
		return rep, n.Name, true
	}
	return rep, "", false
}

var labelValue = regexp.MustCompile(`[^A-Za-z0-9._-]+`)

// safeLabel turns any string into a valid label value: allowed characters, at most 63, with a
// short hash when it had to be cut.
func safeLabel(v string) string {
	v = strings.Trim(labelValue.ReplaceAllString(v, "-"), "-._")
	if len(v) <= 63 {
		return v
	}
	sum := sha256.Sum256([]byte(v))
	return strings.Trim(v[:54], "-._") + "-" + hex.EncodeToString(sum[:])[:8]
}

// reportName is stable per run and machine, so creating it twice is a no-op.
func reportName(machine, runUID string) string {
	uid := strings.ReplaceAll(runUID, "-", "")
	if len(uid) > 8 {
		uid = uid[:8]
	}
	name := strings.ToLower(machine) + "-" + uid
	if len(name) > 253 {
		name = name[:244] + "-" + uid
	}
	return name
}

// buildReport turns a run's outputs into a QualificationReport for one machine: rep and node as
// forMachine returned them for it, and full, the report task's reportjson output. Without that
// output (an older Stack) the report carries what the published outputs hold. group names the run's
// node group when the run tested more than one node.
func buildReport(si, machine *unstructured.Unstructured, rep Report, full stackReport, node, group string, topology []TopologyLabel) *unstructured.Unstructured {
	providerRef, _, _ := unstructured.NestedString(machine.Object, "spec", "providerRef")
	profile := rep.Profile
	if full.Profile != "" {
		profile = full.Profile
	}
	failed := full.FailedTests
	if failed == nil || len(full.Nodes) > 0 {
		failed = []string{}
		if rep.FailedTests != "" {
			failed = strings.Split(rep.FailedTests, ",")
		}
	}

	spec := map[string]any{
		"machineRef":  machine.GetName(),
		"providerRef": providerRef,
		"source": map[string]any{
			"kind": "Stack", "namespace": si.GetNamespace(), "name": si.GetName(),
			"uid": string(si.GetUID()), "template": templateName(si),
		},
		"profile":     profile,
		"result":      rep.Result,
		"failedTests": toAny(failed),
		"summary":     rep.Summary,
		"reportURI":   firstNonEmpty(full.ReportURI, rep.ReportURI),
	}
	if full.AssetID != "" {
		spec["assetID"] = full.AssetID
	}
	if url := machine.GetAnnotations()[netboxDeviceURLAnnotation]; url != "" {
		spec["inventoryURL"] = url
	}
	if topo := machineTopology(machine, topology); len(topo) > 0 {
		spec["topology"] = topo
	}
	if full.StartedAt != "" {
		spec["startedAt"] = full.StartedAt
	}
	if group != "" {
		spec["group"] = group
	}
	if rep.FinishedAt != "" {
		spec["finishedAt"] = rep.FinishedAt
	}

	hardware := map[string]any{"node": node}
	// The inventory fields describe the report's host; another node's machine gets only its name.
	if node != full.Host.Name {
		full.DetectedGPUs, full.GPUs, full.Host.DMI = 0, nil, nil
	}
	if full.DetectedGPUs > 0 {
		hardware["gpuCount"] = full.DetectedGPUs
	}
	if full.ExpectedGPUs > 0 {
		hardware["expectedGPUs"] = full.ExpectedGPUs
	}
	models, gpus := map[string]bool{}, []any{}
	for _, g := range full.GPUs {
		models[g.Name] = true
		gpus = append(gpus, map[string]any{"index": g.Index, "uuid": g.UUID, "name": g.Name, "serial": g.Serial})
		if g.Driver != "" {
			hardware["driver"] = g.Driver
		}
	}
	if len(gpus) > 0 {
		names := make([]string, 0, len(models))
		for m := range models {
			names = append(names, m)
		}
		sort.Strings(names)
		hardware["gpuModel"] = strings.Join(names, ",")
		hardware["gpus"] = gpus
	}
	if len(full.Host.DMI) > 0 {
		dmi := map[string]any{}
		for k, v := range full.Host.DMI {
			dmi[k] = v
		}
		hardware["dmi"] = dmi
	}
	spec["hardware"] = hardware

	tests := []any{}
	for _, t := range full.Tests {
		// A machine's tests are those that ran on its node, and those with no node.
		if t.Node != "" && node != "" && t.Node != node {
			continue
		}
		entry := map[string]any{"name": t.Test, "status": t.Status, "summary": t.Summary,
			"startedAt": t.StartedAt, "finishedAt": t.FinishedAt}
		if len(t.Metrics) > 0 {
			m := map[string]any{}
			for k, v := range t.Metrics {
				m[k] = v
			}
			entry["metrics"] = m
		}
		tests = append(tests, entry)
	}
	spec["tests"] = tests

	r := newObj(ReportGVK)
	r.SetName(reportName(machine.GetName(), string(si.GetUID())))
	labels := map[string]string{
		labelMachine:    safeLabel(machine.GetName()),
		labelResult:     rep.Result,
		labelProvider:   safeLabel(providerRef),
		labelSourceKind: "Stack",
		labelProfile:    safeLabel(profile),
	}
	if group != "" {
		labels[labelGroup] = safeLabel(group)
	}
	r.SetLabels(labels)
	r.Object["spec"] = spec
	return r
}

// machineTopology reads the configured topology names from the Machine's labels. Missing ones are
// left out.
func machineTopology(machine *unstructured.Unstructured, topology []TopologyLabel) map[string]any {
	out := map[string]any{}
	labels := machine.GetLabels()
	for _, t := range topology {
		if v := labels[t.MachineLabel]; v != "" {
			out[t.Name] = v
		}
	}
	return out
}

func toAny(ss []string) []any {
	out := make([]any, len(ss))
	for i, s := range ss {
		out[i] = s
	}
	return out
}

func firstNonEmpty(vs ...string) string {
	for _, v := range vs {
		if v != "" {
			return v
		}
	}
	return ""
}

// createReport writes the report once; an existing report for the same run and machine is left
// alone, because a report is never changed.
func (r *Reconciler) createReport(ctx context.Context, report *unstructured.Unstructured) error {
	logger := log.FromContext(ctx).WithValues("report", report.GetName())
	if r.Config.DryRun {
		logger.Info("would create QualificationReport")
		return nil
	}
	if err := r.Client.Create(ctx, report); err != nil {
		if apierrors.IsAlreadyExists(err) {
			return nil
		}
		// Without the CRD the history is lost, but the label, NetBox and release still happen.
		if meta.IsNoMatchError(err) {
			logger.Info("QualificationReport CRD not installed; skipping the report. Apply recorder/chart/crds/.")
			return nil
		}
		return fmt.Errorf("create QualificationReport %s: %w", report.GetName(), err)
	}
	logger.Info("created QualificationReport")
	return r.pruneReports(ctx, report.GetLabels()[labelMachine])
}

// pruneReports keeps a machine's newest Config.KeepReports reports (0 keeps any number) and drops
// those finished more than Config.MaxReportAge ago (0 keeps any age). The newest report is always
// kept, whatever its age: it is the machine's current state, which gates and dashboards read.
func (r *Reconciler) pruneReports(ctx context.Context, machineLabel string) error {
	if r.Config.KeepReports <= 0 && r.Config.MaxReportAge <= 0 {
		return nil
	}
	list := newList(ReportGVK)
	if err := r.Client.List(ctx, list, client.MatchingLabels{labelMachine: machineLabel}); err != nil {
		return err
	}
	items := list.Items
	sort.Slice(items, func(i, j int) bool { return reportTime(&items[i]) > reportTime(&items[j]) })
	cutoff := ""
	if r.Config.MaxReportAge > 0 {
		cutoff = r.now().Add(-r.Config.MaxReportAge).UTC().Format("2006-01-02T15:04:05Z")
	}
	for i := 1; i < len(items); i++ {
		tooMany := r.Config.KeepReports > 0 && i >= r.Config.KeepReports
		tooOld := cutoff != "" && reportTime(&items[i]) < cutoff
		if !tooMany && !tooOld {
			continue
		}
		if err := r.Client.Delete(ctx, &items[i]); client.IgnoreNotFound(err) != nil {
			return fmt.Errorf("prune QualificationReport %s: %w", items[i].GetName(), err)
		}
	}
	return nil
}

// reportTime orders reports: finishedAt, else creation time. RFC 3339 strings sort as times.
func reportTime(u *unstructured.Unstructured) string {
	if t, _, _ := unstructured.NestedString(u.Object, "spec", "finishedAt"); t != "" {
		return t
	}
	return u.GetCreationTimestamp().UTC().Format("2006-01-02T15:04:05Z")
}
