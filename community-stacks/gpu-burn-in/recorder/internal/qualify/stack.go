package qualify

import (
	"fmt"
	"strings"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

// The StackInstance parameters a run sets for this controller. Their defaults come from the
// StackTemplate, because a StackInstance created from a tenant cluster template carries only the
// parameters the instance set.
const (
	ParamRecordResult  = "recordResult"
	ParamNetBoxUpdate  = "netboxUpdate"
	ParamReleaseServer = "releaseServer"
)

// RunParams are the per-run choices.
type RunParams struct {
	RecordResult  bool
	NetBoxUpdate  bool
	ReleaseServer bool
}

// Report is what the report task published, read from the instance's outputs Secret.
type Report struct {
	Result      string
	FailedTests string
	Summary     string
	Profile     string
	ReportURI   string
	FinishedAt  string
}

// reportTask is the task whose outputs carry the result.
const reportTask = "report"

func templateName(si *unstructured.Unstructured) string {
	name, _, _ := unstructured.NestedString(si.Object, "spec", "templateRef", "name")
	return name
}

func tenantCluster(si *unstructured.Unstructured) string {
	name, _, _ := unstructured.NestedString(si.Object, "spec", "destination", "virtualCluster", "name")
	return name
}

// taskPhase is the phase of one task in the instance's status, or "".
func taskPhase(si *unstructured.Unstructured, task string) string {
	tasks, _, _ := unstructured.NestedSlice(si.Object, "status", "tasks")
	for _, t := range tasks {
		m, ok := t.(map[string]any)
		if !ok {
			continue
		}
		if m["name"] == task {
			phase, _ := m["phase"].(string)
			return phase
		}
	}
	return ""
}

// stringParams flattens a parameters map to strings, as the Platform passes them.
func stringParams(obj map[string]any) map[string]string {
	out := map[string]string{}
	for k, v := range obj {
		if v != nil {
			out[k] = fmt.Sprint(v)
		}
	}
	return out
}

// runParams resolves the run's choices: the instance's value, else the template default, else
// the built-in default (record yes, NetBox no, release no).
func runParams(si, template *unstructured.Unstructured) RunParams {
	defaults := map[string]string{}
	if template != nil {
		params, _, _ := unstructured.NestedSlice(template.Object, "spec", "parameters")
		for _, p := range params {
			m, ok := p.(map[string]any)
			if !ok {
				continue
			}
			if v, ok := m["variable"].(string); ok {
				if d, ok := m["defaultValue"].(string); ok {
					defaults[v] = d
				}
			}
		}
	}
	set, _, _ := unstructured.NestedMap(si.Object, "spec", "parameters")
	given := stringParams(set)
	value := func(name string, builtin bool) bool {
		v, ok := given[name]
		if !ok || v == "" {
			v, ok = defaults[name]
		}
		if !ok || v == "" {
			return builtin
		}
		return strings.EqualFold(v, "true")
	}
	return RunParams{
		RecordResult:  value(ParamRecordResult, true),
		NetBoxUpdate:  value(ParamNetBoxUpdate, false),
		ReleaseServer: value(ParamReleaseServer, false),
	}
}

// reportFromOutputs reads the report task's outputs. ok is false until the result is captured.
func reportFromOutputs(data map[string][]byte, profile string) (Report, bool) {
	get := func(output string) string { return strings.TrimSpace(string(data[reportTask+"."+output])) }
	r := Report{
		Result:      get("result"),
		FailedTests: get("failedtests"),
		Summary:     get("summary"),
		ReportURI:   get("reporturi"),
		FinishedAt:  get("finishedat"),
		Profile:     profile,
	}
	switch r.Result {
	case "passed", "failed":
		return r, true
	default:
		return r, false
	}
}
