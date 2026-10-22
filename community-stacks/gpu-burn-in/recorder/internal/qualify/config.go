package qualify

import (
	"fmt"
	"regexp"
	"strings"
	"time"
)

// Target is where a result is recorded.
type Target string

const (
	// TargetMachine labels the vCluster Platform Machine through the management API. It is
	// provider-neutral. NodeTypes select on Machine labels from Platform v5.0.0-alpha.5; before that,
	// Metal3 NodeTypes read only BareMetalHost labels.
	TargetMachine Target = "machine"
	// TargetBareMetalHost labels the Metal3 BareMetalHost on the cluster that runs Metal3. It gates
	// Metal3 NodeTypes on any Platform build; from v5.0.0-alpha.5 the Platform copies the labels to
	// the Machine.
	TargetBareMetalHost Target = "bmh"
)

// Config is the controller-wide policy. Per-run choices come from the StackInstance parameters
// (see RunParams).
type Config struct {
	// TemplateNames are the StackTemplates whose instances are recorded.
	TemplateNames []string
	// LabelDomain prefixes the result label and annotations: <domain>/result and so on.
	LabelDomain string
	Target      Target
	// LocalCluster is the Platform cluster name of the cluster this controller runs in. A Metal3
	// provider whose clusterRef names it uses the controller's own client.
	LocalCluster string
	// ClusterKubeconfigDir holds one kubeconfig file per other Platform cluster, named after it.
	ClusterKubeconfigDir string
	// NetBox tags, used when a run sets netboxUpdate. The device comes from the Machine's NetBox
	// annotations, and the token from the controller's NetBox client.
	NetBoxAdmitTag     string
	NetBoxQualifiedTag string
	// KeepReports is how many QualificationReports to keep per machine. 0 keeps all.
	KeepReports int
	// MaxReportAge drops reports finished longer ago. 0 keeps them. A machine's latest report is
	// always kept, whatever its age: it is the machine's current state.
	MaxReportAge time.Duration
	// Topology maps each topology name a report records (and its metrics carry as a label) to the
	// Machine label it is read from, in order. The default reads NetBox's site, location and rack.
	Topology []TopologyLabel
	// DryRun logs every write instead of making it.
	DryRun bool
}

// TopologyLabel is one topology name and the Machine label it comes from.
type TopologyLabel struct {
	Name         string
	MachineLabel string
}

// DefaultTopology reads what vCluster Platform's NetBox import puts on every Machine.
const DefaultTopology = "site=netbox.vcluster.com/site,location=netbox.vcluster.com/location,rack=netbox.vcluster.com/rack"

var topologyName = regexp.MustCompile(`^[a-z_][a-z0-9_]*$`)

// ParseTopology parses name=machine-label pairs, comma-separated.
func ParseTopology(s string) ([]TopologyLabel, error) {
	var out []TopologyLabel
	seen := map[string]bool{}
	for _, pair := range strings.Split(s, ",") {
		pair = strings.TrimSpace(pair)
		if pair == "" {
			continue
		}
		name, label, ok := strings.Cut(pair, "=")
		if !ok || label == "" {
			return nil, fmt.Errorf("topology %q: want name=machine-label", pair)
		}
		if !topologyName.MatchString(name) || reservedMetricLabels[name] {
			return nil, fmt.Errorf("topology name %q: want a lowercase metric label name that is not one of the recorder's own", name)
		}
		if seen[name] {
			return nil, fmt.Errorf("topology name %q given twice", name)
		}
		seen[name] = true
		out = append(out, TopologyLabel{Name: name, MachineLabel: label})
	}
	return out, nil
}

// Validate rejects settings that would record nothing useful or nothing at all.
func (c *Config) Validate() error {
	if len(c.TemplateNames) == 0 {
		return fmt.Errorf("no StackTemplate names to watch")
	}
	if c.LabelDomain == "" {
		return fmt.Errorf("label domain is empty")
	}
	// Newer Platform builds keep labels in these domains out of NodeType selection, so a result
	// recorded there could never gate allocation.
	d := c.LabelDomain
	for _, reserved := range []string{"vcluster.com", "loft.sh"} {
		if d == reserved || strings.HasSuffix(d, "."+reserved) {
			return fmt.Errorf("label domain %q: NodeType selection ignores labels in %s domains", d, reserved)
		}
	}
	switch c.Target {
	case TargetMachine, TargetBareMetalHost:
	default:
		return fmt.Errorf("target %q: want %q or %q", c.Target, TargetMachine, TargetBareMetalHost)
	}
	return nil
}

func (c *Config) key(name string) string { return c.LabelDomain + "/" + name }

func (c *Config) watches(template string) bool {
	for _, n := range c.TemplateNames {
		if n == template {
			return true
		}
	}
	return false
}

// Labels the recorder's metrics already use; a topology name may not shadow one.
var reservedMetricLabels = map[string]bool{
	"machine": true, "provider": true, "profile": true, "gpu_model": true, "source": true,
	"result": true, "test": true, "status": true, "metric": true, "kind": true,
	"failed_tests": true, "summary": true, "report": true, "inventory_url": true,
}
