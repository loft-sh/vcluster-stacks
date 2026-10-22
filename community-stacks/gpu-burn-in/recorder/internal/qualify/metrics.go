package qualify

import (
	"context"
	"sort"
	"strings"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"k8s.io/apimachinery/pkg/api/meta"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"
)

// ReportCollector publishes Prometheus metrics computed from QualificationReports on every scrape.
// It reads the controller's cache, so a scrape costs no API calls.
//
// Every per-machine metric describes the machine's latest report and carries the same identity
// labels: machine, provider, profile, gpu_model and the configured topology names (site, location
// and rack by default), so any panel can group or filter by them without a join. Series grow with
// machines, not with history: at 10,000 machines, about 20 measurements each is about 200,000
// series. Only gpu_qualification_reports counts history.
type ReportCollector struct {
	Reader   client.Reader
	topology []string

	result, passed, finished, gpus, testStatus, testMetric, failure, consecutive, reports *prometheus.Desc
}

// NewReportCollector builds a collector whose metrics carry the given topology names as labels.
func NewReportCollector(reader client.Reader, topology []TopologyLabel) *ReportCollector {
	c := &ReportCollector{Reader: reader}
	for _, t := range topology {
		c.topology = append(c.topology, t.Name)
	}
	id := append([]string{"machine", "provider", "profile", "gpu_model"}, c.topology...)
	with := func(extra ...string) []string { return append(append([]string{}, id...), extra...) }
	c.result = prometheus.NewDesc("gpu_qualification_result",
		"Latest qualification result per machine: 1 for the result label that applies.", with("source", "result"), nil)
	c.passed = prometheus.NewDesc("gpu_qualification_passed",
		"1 when the machine's latest qualification passed, 0 when it did not.", with(), nil)
	c.finished = prometheus.NewDesc("gpu_qualification_finished_timestamp_seconds",
		"When the machine's latest qualification finished.", with(), nil)
	c.gpus = prometheus.NewDesc("gpu_qualification_gpus",
		"GPUs found in the machine's latest qualification, and how many were expected.", with("kind"), nil)
	c.testStatus = prometheus.NewDesc("gpu_qualification_test_status",
		"Status of each test in the machine's latest qualification: 1 for the status that applies.", with("test", "status"), nil)
	c.testMetric = prometheus.NewDesc("gpu_qualification_test_metric",
		"A measurement from the machine's latest qualification, such as soak peak_temp_c.", with("test", "metric"), nil)
	c.failure = prometheus.NewDesc("gpu_qualification_failure_info",
		"1 for each machine whose latest qualification did not pass, with why: the failed tests and the summary.",
		with("result", "failed_tests", "summary", "report", "inventory_url"), nil)
	c.consecutive = prometheus.NewDesc("gpu_qualification_consecutive_failures",
		"How many of the machine's newest kept reports in a row did not pass. 0 when the latest passed.", with(), nil)
	c.reports = prometheus.NewDesc("gpu_qualification_reports",
		"QualificationReports kept per machine and result, the history the cluster holds.", []string{"machine", "result"}, nil)
	return c
}

func (c *ReportCollector) Describe(ch chan<- *prometheus.Desc) {
	for _, d := range []*prometheus.Desc{c.result, c.passed, c.finished, c.gpus, c.testStatus, c.testMetric, c.failure, c.consecutive, c.reports} {
		ch <- d
	}
}

// Summaries in a label are cut short, so a long reason cannot bloat the series.
const maxSummaryLabel = 200

func (c *ReportCollector) Collect(ch chan<- prometheus.Metric) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	list := newList(ReportGVK)
	if err := c.Reader.List(ctx, list); err != nil {
		if !meta.IsNoMatchError(err) {
			log.FromContext(ctx).Error(err, "list QualificationReports for metrics")
		}
		return
	}
	byMachine := map[string][]*unstructured.Unstructured{}
	counts := map[[2]string]int{}
	for i := range list.Items {
		r := &list.Items[i]
		machine := str(r, "machineRef")
		counts[[2]string{machine, str(r, "result")}]++
		byMachine[machine] = append(byMachine[machine], r)
	}
	for k, n := range counts {
		ch <- prometheus.MustNewConstMetric(c.reports, prometheus.GaugeValue, float64(n), k[0], k[1])
	}
	for machine, reports := range byMachine {
		sort.Slice(reports, func(i, j int) bool { return reportTime(reports[i]) > reportTime(reports[j]) })
		r := reports[0]
		topo, _, _ := unstructured.NestedStringMap(r.Object, "spec", "topology")
		gpuModel, _, _ := unstructured.NestedString(r.Object, "spec", "hardware", "gpuModel")
		id := []string{machine, str(r, "providerRef"), str(r, "profile"), gpuModel}
		for _, t := range c.topology {
			id = append(id, topo[t])
		}
		with := func(extra ...string) []string { return append(append([]string{}, id...), extra...) }
		gauge := func(d *prometheus.Desc, v float64, labels []string) {
			ch <- prometheus.MustNewConstMetric(d, prometheus.GaugeValue, v, labels...)
		}

		result := str(r, "result")
		gauge(c.result, 1, with(sourceKind(r), result))
		passed := 0.0
		if result == "passed" {
			passed = 1
		}
		gauge(c.passed, passed, with())
		if t, err := time.Parse(time.RFC3339, str(r, "finishedAt")); err == nil {
			gauge(c.finished, float64(t.Unix()), with())
		}
		for field, kind := range map[string]string{"gpuCount": "found", "expectedGPUs": "expected"} {
			if n, found, _ := unstructured.NestedInt64(r.Object, "spec", "hardware", field); found {
				gauge(c.gpus, float64(n), with(kind))
			}
		}
		tests, _, _ := unstructured.NestedSlice(r.Object, "spec", "tests")
		for _, t := range tests {
			m, ok := t.(map[string]any)
			if !ok {
				continue
			}
			name, _ := m["name"].(string)
			status, _ := m["status"].(string)
			gauge(c.testStatus, 1, with(name, status))
			metrics, _ := m["metrics"].(map[string]any)
			for k, v := range metrics {
				if f, ok := number(v); ok {
					gauge(c.testMetric, f, with(name, k))
				}
			}
		}

		streak := 0
		for _, h := range reports {
			if str(h, "result") == "passed" {
				break
			}
			streak++
		}
		gauge(c.consecutive, float64(streak), with())
		if result != "passed" {
			failed, _, _ := unstructured.NestedStringSlice(r.Object, "spec", "failedTests")
			summary := str(r, "summary")
			if len(summary) > maxSummaryLabel {
				summary = summary[:maxSummaryLabel-3] + "..."
			}
			gauge(c.failure, 1, with(result, strings.Join(failed, ","), summary, r.GetName(), str(r, "inventoryURL")))
		}
	}
}

func str(r *unstructured.Unstructured, field string) string {
	v, _, _ := unstructured.NestedString(r.Object, "spec", field)
	return v
}

func sourceKind(r *unstructured.Unstructured) string {
	v, _, _ := unstructured.NestedString(r.Object, "spec", "source", "kind")
	return v
}

func number(v any) (float64, bool) {
	switch n := v.(type) {
	case float64:
		return n, true
	case int64:
		return float64(n), true
	case int:
		return float64(n), true
	}
	return 0, false
}
