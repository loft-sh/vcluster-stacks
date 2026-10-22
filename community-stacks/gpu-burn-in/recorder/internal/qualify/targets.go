package qualify

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/tools/clientcmd"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

var (
	managementMachine = schema.GroupVersionKind{Group: "management.loft.sh", Version: "v1", Kind: "Machine"}
	bareMetalHost     = schema.GroupVersionKind{Group: "metal3.io", Version: "v1alpha1", Kind: "BareMetalHost"}
)

// metadataPatch is the label and annotations that record one result on an object.
func (c *Config) metadataPatch(r Report, run string) map[string]any {
	summary := r.Summary
	if len(summary) > 1000 {
		summary = summary[:1000]
	}
	return map[string]any{
		"metadata": map[string]any{
			"labels": map[string]any{c.key("result"): r.Result},
			"annotations": map[string]any{
				c.key("profile"):      r.Profile,
				c.key("finished-at"):  r.FinishedAt,
				c.key("failed-tests"): r.FailedTests,
				c.key("summary"):      summary,
				c.key("report"):       r.ReportURI,
				// The commit marker: a target that carries this run's marker is already recorded.
				c.key("run"): run,
			},
		},
	}
}

// recorded reports whether obj already carries this run's result.
func (c *Config) recorded(obj *unstructured.Unstructured, r Report, run string) bool {
	return obj.GetAnnotations()[c.key("run")] == run && obj.GetLabels()[c.key("result")] == r.Result
}

// ClusterClients returns a client for a vCluster Platform cluster by name.
type ClusterClients interface {
	For(cluster string) (client.Client, error)
}

// KubeconfigClusters serves the local cluster with its own client and every other cluster from a
// kubeconfig file named after it in Dir.
type KubeconfigClusters struct {
	Local     string
	LocalCli  client.Client
	Dir       string
	NewClient func(kubeconfig []byte) (client.Client, error)

	mu    sync.Mutex
	cache map[string]client.Client
}

func (k *KubeconfigClusters) For(cluster string) (client.Client, error) {
	if cluster == "" || cluster == k.Local {
		return k.LocalCli, nil
	}
	k.mu.Lock()
	defer k.mu.Unlock()
	if c, ok := k.cache[cluster]; ok {
		return c, nil
	}
	if k.Dir == "" {
		return nil, fmt.Errorf("cluster %s: no kubeconfig directory configured", cluster)
	}
	b, err := os.ReadFile(filepath.Join(k.Dir, cluster))
	if err != nil {
		return nil, fmt.Errorf("cluster %s: %w", cluster, err)
	}
	newClient := k.NewClient
	if newClient == nil {
		newClient = clientFromKubeconfig
	}
	c, err := newClient(b)
	if err != nil {
		return nil, fmt.Errorf("cluster %s: %w", cluster, err)
	}
	if k.cache == nil {
		k.cache = map[string]client.Client{}
	}
	k.cache[cluster] = c
	return c, nil
}

func clientFromKubeconfig(kubeconfig []byte) (client.Client, error) {
	cfg, err := clientcmd.RESTConfigFromKubeConfig(kubeconfig)
	if err != nil {
		return nil, err
	}
	return client.New(cfg, client.Options{})
}

// patchMetadata merge-patches labels and annotations onto obj, or logs it in a dry run.
func patchMetadata(ctx context.Context, c client.Client, obj *unstructured.Unstructured, patch map[string]any, dryRun bool) error {
	b, err := json.Marshal(patch)
	if err != nil {
		return err
	}
	if dryRun {
		return nil
	}
	return c.Patch(ctx, obj, client.RawPatch(types.MergePatchType, b))
}

// bareMetalHostFor locates the BareMetalHost behind a Machine: the Metal3 provider's clusterRef
// names the cluster and namespace, and the Machine is named "<provider>.<host>".
func bareMetalHostFor(machine *unstructured.Unstructured, provider *unstructured.Unstructured) (cluster, namespace, name string, err error) {
	providerRef, _, _ := unstructured.NestedString(machine.Object, "spec", "providerRef")
	name = strings.TrimPrefix(machine.GetName(), providerRef+".")
	if name == machine.GetName() || name == "" {
		return "", "", "", fmt.Errorf("machine %s is not named <provider>.<host>", machine.GetName())
	}
	ref, found, _ := unstructured.NestedMap(provider.Object, "spec", "metal3", "clusterRef")
	if !found {
		return "", "", "", fmt.Errorf("node provider %s is not a Metal3 provider", provider.GetName())
	}
	cluster, _ = ref["cluster"].(string)
	namespace, _ = ref["namespace"].(string)
	if namespace == "" {
		namespace = "metal3-system"
	}
	return cluster, namespace, name, nil
}
