package qualify

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/testutil"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

// A report.json as the gpu-burn-in report step writes it, trimmed to what the recorder reads.
const sampleReportJSON = `{
  "schema": "gpu-burn-in.vcluster.com/v1", "result": "failed", "failedTests": ["soak"],
  "summary": "soak failed: above 85C: GPU 0 91C", "assetID": "rack-c-u12", "profile": "single-gpu-smoke",
  "host": {"name": "rack-c-u12", "dmi": {"product_serial": "S123"}},
  "expectedGPUs": 1, "detectedGPUs": 1, "startedAt": "2026-10-20T20:31:00Z",
  "gpus": [{"index": 0, "uuid": "GPU-5192", "name": "NVIDIA RTX 2000 Ada Generation", "serial": "1652", "driver": "580.95.05"}],
  "tests": [
    {"test": "inventory", "status": "passed", "summary": "1 x NVIDIA RTX 2000", "metrics": {"gpus": 1, "allocatable_gpus": 1}},
    {"test": "soak", "status": "failed", "summary": "above 85C", "metrics": {"peak_temp_c": 91, "gpus_with_xid": 0}}
  ]
}`

func listReports(t *testing.T, c client.Client) []unstructured.Unstructured {
	t.Helper()
	l := newList(ReportGVK)
	if err := c.List(context.Background(), l); err != nil {
		t.Fatal(err)
	}
	return l.Items
}

func TestCreatesQualificationReport(t *testing.T) {
	c := fake.NewClientBuilder().WithScheme(testScheme()).WithObjects(fixture{result: "failed"}.objects()...).Build()
	r := newReconciler(c, TargetMachine)
	reconcile(t, r)
	reconcile(t, r) // once per run: the second pass creates nothing

	reports := listReports(t, c)
	if len(reports) != 1 {
		t.Fatalf("%d reports, want 1", len(reports))
	}
	qr := reports[0]
	spec := qr.Object["spec"].(map[string]any)
	if spec["machineRef"] != machine || spec["result"] != "failed" || spec["profile"] != "single-gpu-smoke" || spec["assetID"] != "rack-c-u12" {
		t.Fatalf("spec %v", spec)
	}
	if src := spec["source"].(map[string]any); src["kind"] != "Stack" || src["name"] != stack || src["uid"] != "uid-1" || src["template"] != "gpu-burn-in" {
		t.Fatalf("source %v", src)
	}
	hw := spec["hardware"].(map[string]any)
	if hw["gpuModel"] != "NVIDIA RTX 2000 Ada Generation" || hw["driver"] != "580.95.05" || fmt.Sprint(hw["gpuCount"]) != "1" {
		t.Fatalf("hardware %v", hw)
	}
	tests := spec["tests"].([]any)
	soak := tests[1].(map[string]any)
	if soak["name"] != "soak" || fmt.Sprint(soak["metrics"].(map[string]any)["peak_temp_c"]) != "91" {
		t.Fatalf("soak test %v", soak)
	}
	if l := qr.GetLabels(); l[labelMachine] != machine || l[labelResult] != "failed" || l[labelSourceKind] != "Stack" {
		t.Fatalf("labels %v", l)
	}
}

func TestReportWithoutFullReport(t *testing.T) {
	objs := fixture{result: "passed"}.objects()
	for _, o := range objs {
		if s, ok := o.(interface{ GetName() string }); ok && s.GetName() == outputsSecretName(stack) {
			delete(o.(*corev1.Secret).Data, reportJSONOutputKey)
		}
	}
	c := fake.NewClientBuilder().WithScheme(testScheme()).WithObjects(objs...).Build()
	reconcile(t, newReconciler(c, TargetMachine))
	reports := listReports(t, c)
	if len(reports) != 1 || reports[0].Object["spec"].(map[string]any)["result"] != "passed" {
		t.Fatalf("reports %v", reports)
	}
}

func TestPrunesOldReports(t *testing.T) {
	var objs []client.Object
	for i := 0; i < 5; i++ {
		r := obj(ReportGVK, "", fmt.Sprintf("old-%d", i), map[string]any{"spec": map[string]any{
			"machineRef": machine, "result": "passed", "source": map[string]any{"kind": "Stack"},
			"finishedAt": fmt.Sprintf("2026-10-1%dT00:00:00Z", i)}})
		r.SetLabels(map[string]string{labelMachine: machine})
		objs = append(objs, r)
	}
	objs = append(objs, fixture{result: "failed"}.objects()...)
	c := fake.NewClientBuilder().WithScheme(testScheme()).WithObjects(objs...).Build()
	r := newReconciler(c, TargetMachine)
	r.Config.KeepReports = 3
	reconcile(t, r)

	var names []string
	for _, qr := range listReports(t, c) {
		names = append(names, qr.GetName())
	}
	got := strings.Join(names, ",")
	if len(names) != 3 || !strings.Contains(got, "old-4") || !strings.Contains(got, "old-3") || strings.Contains(got, "old-0") {
		t.Fatalf("kept %s; want the new report, old-4 and old-3", got)
	}
}

var testTopology, _ = ParseTopology(DefaultTopology)

func TestReportMetrics(t *testing.T) {
	objs := fixture{result: "failed"}.objects()
	for _, o := range objs {
		if u, ok := o.(*unstructured.Unstructured); ok && u.GroupVersionKind() == storageMachine {
			u.SetLabels(map[string]string{"netbox.vcluster.com/site": "dc1", "netbox.vcluster.com/rack": "rack-c"})
			a := u.GetAnnotations()
			a[netboxDeviceURLAnnotation] = "https://netbox.example/dcim/devices/10/"
			u.SetAnnotations(a)
		}
	}
	c := fake.NewClientBuilder().WithScheme(testScheme()).WithObjects(objs...).Build()
	r := newReconciler(c, TargetMachine)
	r.Config.Topology = testTopology
	reconcile(t, r)
	older := obj(ReportGVK, "", "older", map[string]any{"spec": map[string]any{
		"machineRef": machine, "result": "failed", "source": map[string]any{"kind": "Stack"},
		"finishedAt": "2026-10-01T00:00:00Z"}})
	oldest := obj(ReportGVK, "", "oldest", map[string]any{"spec": map[string]any{
		"machineRef": machine, "result": "passed", "source": map[string]any{"kind": "Stack"},
		"finishedAt": "2026-09-01T00:00:00Z"}})
	for _, o := range []client.Object{older, oldest} {
		if err := c.Create(context.Background(), o); err != nil {
			t.Fatal(err)
		}
	}

	id := map[string]string{"machine": machine, "provider": provider, "profile": "single-gpu-smoke",
		"gpu_model": "NVIDIA RTX 2000 Ada Generation", "site": "dc1", "location": "", "rack": "rack-c"}
	with := func(extra map[string]string) map[string]string {
		out := map[string]string{}
		for k, v := range id {
			out[k] = v
		}
		for k, v := range extra {
			out[k] = v
		}
		return out
	}
	want := []sample{
		{"gpu_qualification_consecutive_failures", with(nil), 2},
		{"gpu_qualification_passed", with(nil), 0},
		{"gpu_qualification_failure_info", with(map[string]string{"result": "failed", "failed_tests": "soak",
			"summary": "soak failed: above 85C: GPU 0 91C", "report": reportName(machine, "uid-1"),
			"inventory_url": "https://netbox.example/dcim/devices/10/"}), 1},
		{"gpu_qualification_reports", map[string]string{"machine": machine, "result": "failed"}, 2},
		{"gpu_qualification_reports", map[string]string{"machine": machine, "result": "passed"}, 1},
		{"gpu_qualification_test_metric", with(map[string]string{"test": "soak", "metric": "peak_temp_c"}), 91},
		{"gpu_qualification_test_metric", with(map[string]string{"test": "inventory", "metric": "allocatable_gpus"}), 1},
	}
	got := gather(t, NewReportCollector(c, testTopology))
	for _, w := range want {
		if v, ok := got[w.key()]; !ok || v != w.value {
			t.Errorf("%s = %v (present %v), want %v", w.key(), v, ok, w.value)
		}
	}
}

type sample struct {
	name   string
	labels map[string]string
	value  float64
}

func (s sample) key() string {
	keys := make([]string, 0, len(s.labels))
	for k := range s.labels {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, len(keys))
	for i, k := range keys {
		parts[i] = k + "=" + s.labels[k]
	}
	return s.name + "{" + strings.Join(parts, ",") + "}"
}

// gather collects every series into name{sorted labels} -> value.
func gather(t *testing.T, col prometheus.Collector) map[string]float64 {
	t.Helper()
	reg := prometheus.NewPedanticRegistry()
	reg.MustRegister(col)
	families, err := reg.Gather()
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]float64{}
	for _, f := range families {
		for _, m := range f.GetMetric() {
			labels := map[string]string{}
			for _, l := range m.GetLabel() {
				labels[l.GetName()] = l.GetValue()
			}
			out[sample{f.GetName(), labels, 0}.key()] = m.GetGauge().GetValue()
		}
	}
	return out
}

func TestRetentionKeepsTheLatest(t *testing.T) {
	now := mustTime("2026-10-20T23:00:00Z")
	var objs []client.Object
	for i, finished := range []string{"2026-01-01T00:00:00Z", "2026-02-01T00:00:00Z", "2026-10-10T00:00:00Z", "2026-10-15T00:00:00Z"} {
		r := obj(ReportGVK, "", fmt.Sprintf("r-%d", i), map[string]any{"spec": map[string]any{
			"machineRef": "lonely", "result": "passed", "source": map[string]any{"kind": "Stack"}, "finishedAt": finished}})
		r.SetLabels(map[string]string{labelMachine: "lonely"})
		objs = append(objs, r)
	}
	ancient := obj(ReportGVK, "", "only", map[string]any{"spec": map[string]any{
		"machineRef": "old-server", "result": "passed", "source": map[string]any{"kind": "Stack"}, "finishedAt": "2025-01-01T00:00:00Z"}})
	ancient.SetLabels(map[string]string{labelMachine: "old-server"})
	objs = append(objs, ancient)
	c := fake.NewClientBuilder().WithScheme(testScheme()).WithObjects(objs...).Build()
	r := newReconciler(c, TargetMachine)
	r.Config.KeepReports, r.Config.MaxReportAge = 3, 90*24*time.Hour
	r.Now = func() time.Time { return now }
	for _, m := range []string{"lonely", "old-server"} {
		if err := r.pruneReports(context.Background(), m); err != nil {
			t.Fatal(err)
		}
	}
	var names []string
	for _, qr := range listReports(t, c) {
		names = append(names, qr.GetName())
	}
	sort.Strings(names)
	// r-0 and r-1 are past 90 days; old-server's only report is kept although it is older still.
	if got := strings.Join(names, ","); got != "only,r-2,r-3" {
		t.Fatalf("kept %s, want only,r-2,r-3", got)
	}
}

// A fleet: thousands of machines with several reports each, through the collector.
func TestCollectorAtFleetScale(t *testing.T) {
	const machines, perMachine = 5000, 3
	var objs []client.Object
	for m := 0; m < machines; m++ {
		for h := 0; h < perMachine; h++ {
			result := "passed"
			if m%50 == 0 && h == perMachine-1 {
				result = "failed"
			}
			r := obj(ReportGVK, "", fmt.Sprintf("m%05d-%d", m, h), map[string]any{"spec": map[string]any{
				"machineRef": fmt.Sprintf("metal3-dc%d.server-%05d", m%4, m), "providerRef": fmt.Sprintf("metal3-dc%d", m%4),
				"result": result, "profile": "b300-burnin-v1", "source": map[string]any{"kind": "Stack"},
				"finishedAt": fmt.Sprintf("2026-10-%02dT00:00:00Z", 10+h),
				"topology":   map[string]any{"site": fmt.Sprintf("dc%d", m%4), "rack": fmt.Sprintf("rack-%03d", m/40)},
				"hardware":   map[string]any{"gpuModel": "NVIDIA B300", "gpuCount": int64(8), "expectedGPUs": int64(8)},
				"tests": []any{
					map[string]any{"name": "inventory", "status": "passed", "metrics": map[string]any{"gpus": float64(8), "uncorrected_ecc_errors": float64(0)}},
					map[string]any{"name": "soak", "status": result, "metrics": map[string]any{"peak_temp_c": float64(70 + m%25)}},
				}}})
			objs = append(objs, r)
		}
	}
	c := fake.NewClientBuilder().WithScheme(testScheme()).WithObjects(objs...).Build()
	col := NewReportCollector(c, testTopology)
	start := time.Now()
	n := testutil.CollectAndCount(col)
	took := time.Since(start)
	// Per machine: result, passed, finished, 2 gpus, 2 test statuses, 3 test metrics, consecutive,
	// 1 or 2 report counts; plus failure_info for the 100 failing machines.
	if n < machines*12 || n > machines*13+200 {
		t.Fatalf("%d series for %d machines", n, machines)
	}
	if got := testutil.CollectAndCount(col, "gpu_qualification_failure_info"); got != machines/50 {
		t.Fatalf("%d failure_info series, want %d", got, machines/50)
	}
	t.Logf("%d machines, %d reports: %d series in %s", machines, machines*perMachine, n, took)
}

func mustTime(s string) time.Time {
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		panic(err)
	}
	return t
}

func TestSafeLabelAndReportName(t *testing.T) {
	if got := safeLabel("b300 burn-in/v1"); got != "b300-burn-in-v1" {
		t.Fatalf("safeLabel %q", got)
	}
	if got := safeLabel(strings.Repeat("a", 80)); len(got) > 63 {
		t.Fatalf("safeLabel too long: %d", len(got))
	}
	if got := reportName("Metal3.Host", "abcd1234-ef00-1111"); got != "metal3.host-abcd1234" {
		t.Fatalf("reportName %q", got)
	}
}
