#!/usr/bin/env python3
"""Generates the GPU Burn-In dashboards into ../chart/dashboards/. Edit here, rerun:

    python3 community-stacks/gpu-burn-in/recorder/dashboards/gen_gpu_burn_in.py

Three dashboards over the gpu_qualification_* metrics the gpu-burn-in-recorder computes from
QualificationReports, from any source (the gpu-burn-in Stack, record-qualification.sh, NICo
Machine Validation):

  gpu-burn-in           Fleet: aggregates only, so it reads the same at 10 servers or 10,000.
  gpu-burn-in-failures  Failures: one row per server whose latest qualification did not pass.
  gpu-burn-in-server    Server: one machine's latest results, measurements and history.

Per-machine metrics carry machine, provider, profile, gpu_model and the topology labels site,
location and rack (the recorder's defaults), and describe each machine's latest report. Panels
that list servers are bounded (topk, or failing servers only), never one row per server.
"""
import json
import pathlib

DS = {"type": "prometheus", "uid": "${datasource}"}
OUT = pathlib.Path(__file__).resolve().parent.parent / "chart" / "dashboards"
UID_FLEET, UID_FAILURES, UID_SERVER = "gpu-burn-in", "gpu-burn-in-failures", "gpu-burn-in-server"

FILTER = ('provider=~"$provider",profile=~"$profile",gpu_model=~"$gpu_model",'
          'site=~"$site",rack=~"$rack"')
SERVER_LINK = f"/d/{UID_SERVER}?var-machine=${{__value.raw}}&${{datasource:queryparam}}"

RESULT_MAPPING = [{"type": "value", "options": {
    "1": {"text": "Qualified", "color": "green", "index": 0},
    "0": {"text": "Not qualified", "color": "red", "index": 1}}}]
STATUS_MAPPING = [{"type": "value", "options": {
    "passed": {"color": "green", "index": 0}, "failed": {"color": "red", "index": 1},
    "error": {"color": "dark-red", "index": 2}, "skipped": {"color": "orange", "index": 3},
    "disabled": {"color": "transparent", "index": 4}, "missing": {"color": "purple", "index": 5}}}]
RED_ABOVE_0 = {"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "red", "value": 1}]}
TEMP = {"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "orange", "value": 85},
                                       {"color": "red", "value": 90}]}


class Dashboard:
    def __init__(self, uid, title, description):
        self.uid, self.title, self.description = uid, title, description
        self.panels, self.y, self.next_id, self.vars = [], 0, 0, []

    def id(self):
        self.next_id += 1
        return self.next_id

    def pos(self, w, h, x):
        return {"h": h, "w": w, "x": x, "y": self.y}

    def row(self, title):
        self.panels.append({"type": "row", "title": title, "id": self.id(), "collapsed": False,
                            "gridPos": {"h": 1, "w": 24, "x": 0, "y": self.y}, "panels": []})
        self.y += 1

    def advance(self, h):
        self.y += h

    def add(self, panel, w, h, x):
        panel.update({"id": self.id(), "datasource": DS, "gridPos": self.pos(w, h, x)})
        self.panels.append(panel)

    def json(self, links, tags):
        return {
            "uid": self.uid, "title": self.title, "description": self.description,
            "tags": ["vcluster", "fleet-observability", "gpu", "qualification", "burn-in"] + tags,
            "timezone": "browser", "schemaVersion": 41, "editable": True, "graphTooltip": 1,
            "time": {"from": "now-7d", "to": "now"}, "refresh": "1m",
            "links": links,
            "templating": {"list": [{"name": "datasource", "label": "Datasource", "type": "datasource",
                                     "query": "prometheus", "current": {}, "hide": 0}] + self.vars},
            "panels": self.panels,
        }


def target(expr, ref="A", legend="", instant=False, table=False):
    t = {"datasource": DS, "expr": expr, "refId": ref, "legendFormat": legend}
    if instant or table:
        t.update({"instant": True, "range": False})
    if table:
        t["format"] = "table"
    return t


def stat(title, expr, unit="none", thresholds=None, desc="", mappings=None, links=None):
    p = {"type": "stat", "title": title, "description": desc,
         "targets": [target(expr, instant=True)],
         "options": {"colorMode": "value", "graphMode": "none", "justifyMode": "center",
                     "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}},
         "fieldConfig": {"defaults": {"unit": unit, "mappings": mappings or [],
                                      "thresholds": thresholds or {"mode": "absolute", "steps": [{"color": "green", "value": None}]}},
                         "overrides": []}}
    if links:
        p["links"] = links
    return p


def bargauge(title, expr, legend, unit="none", thresholds=None, desc="", min_=None, max_=None, link=None):
    defaults = {"unit": unit, "thresholds": thresholds or {"mode": "absolute", "steps": [{"color": "blue", "value": None}]}}
    if min_ is not None:
        defaults["min"] = min_
    if max_ is not None:
        defaults["max"] = max_
    if link:
        defaults["links"] = [link]
    return {"type": "bargauge", "title": title, "description": desc,
            "targets": [target(expr, legend=legend, instant=True)],
            "options": {"displayMode": "gradient", "orientation": "horizontal", "showUnfilled": True,
                        "valueMode": "color", "namePlacement": "left", "sizing": "auto",
                        "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}},
            "fieldConfig": {"defaults": defaults, "overrides": []}}


def timeseries(title, exprs, unit="none", desc="", min_=0, step=False):
    custom = {"drawStyle": "line", "fillOpacity": 10, "lineWidth": 2}
    if step:
        custom["lineInterpolation"] = "stepAfter"
    return {"type": "timeseries", "title": title, "description": desc,
            "targets": [target(e, ref=chr(65 + i), legend=l) for i, (e, l) in enumerate(exprs)],
            "fieldConfig": {"defaults": {"custom": custom, "unit": unit, "min": min_}, "overrides": []},
            "options": {"legend": {"displayMode": "list", "placement": "bottom"}, "tooltip": {"mode": "multi"}}}


def table(title, targets, join, columns, desc="", overrides=None, sort=None, matrix=None):
    """A table of instant queries joined on `join`. columns maps a query field, or Value #<ref>,
    to its header, in display order; other fields are hidden."""
    transforms = []
    if matrix:
        transforms.append({"id": "groupingToMatrix", "options": matrix})
    elif len(targets) > 1:
        transforms.append({"id": "joinByField", "options": {"byField": join, "mode": "outer"}})
    transforms.append({"id": "organize", "options": {
        "includeByName": {k: True for k in columns},
        "indexByName": {k: i for i, k in enumerate(columns)},
        "renameByName": {k: v for k, v in columns.items() if v}}})
    if not matrix:
        transforms.insert(0 if len(targets) == 1 else 1, {"id": "filterFieldsByName",
                                                           "options": {"include": {"names": list(columns)}}})
    p = {"type": "table", "title": title, "description": desc, "targets": targets,
         "transformations": transforms,
         "options": {"showHeader": True, "cellHeight": "sm", "footer": {"show": False}},
         "fieldConfig": {"defaults": {"custom": {"align": "auto", "cellOptions": {"type": "auto"},
                                                 "filterable": True}},
                         "overrides": overrides or []}}
    if sort:
        p["options"]["sortBy"] = [sort]
    return p


def override(name, *props):
    return {"matcher": {"id": "byName", "options": name}, "properties": [{"id": k, "value": v} for k, v in props]}


def query_var(name, label, metric, depends="", multi=True):
    q = f"label_values({metric}{{{depends}}}, {name})"
    v = {"name": name, "label": label, "type": "query", "datasource": DS,
         "query": {"query": q, "refId": "StandardVariableQuery"}, "definition": q, "refresh": 2, "sort": 1}
    if multi:
        v.update({"includeAll": True, "multi": True, "allValue": ".*", "current": {"text": ["All"], "value": ["$__all"]}})
    else:
        v.update({"includeAll": False, "multi": False})
    return v


def filter_vars():
    return [
        query_var("provider", "Provider", "gpu_qualification_passed"),
        query_var("profile", "Profile", "gpu_qualification_passed", 'provider=~"$provider"'),
        query_var("gpu_model", "GPU model", "gpu_qualification_passed", 'provider=~"$provider",profile=~"$profile"'),
        query_var("site", "Site", "gpu_qualification_passed", 'provider=~"$provider"'),
        query_var("rack", "Rack", "gpu_qualification_passed", 'provider=~"$provider",site=~"$site"'),
    ]


def link(title, uid, keep=True):
    return {"title": title, "url": f"/d/{uid}", "type": "link", "tags": [], "keepTime": True,
            "includeVars": keep}


# =================================================================================================
# Fleet
# =================================================================================================
fleet = Dashboard(UID_FLEET, "GPU Burn-In",
                  "GPU server qualification across the fleet, by model, site and rack. Aggregates only; "
                  "failing servers are on GPU Burn-In: Failures.")
fleet.vars = filter_vars() + [{
    "name": "stale_days", "label": "Stale after (days)", "type": "custom", "query": "30,90,180,365",
    "current": {"text": "90", "value": "90"}, "options": [], "hide": 0}]
P = f"gpu_qualification_passed{{{FILTER}}}"
F = f"gpu_qualification_finished_timestamp_seconds{{{FILTER}}}"
failures_link = [{"title": "Not-qualified servers", "url": f"/d/{UID_FAILURES}?${{__url_time_range}}&${{datasource:queryparam}}"}]

fleet.row("Summary")
fleet.add(stat("Servers", f"count({P}) or vector(0)", desc="Servers with a qualification report."), 4, 4, 0)
fleet.add(stat("Qualified", f"count({P} == 1) or vector(0)"), 4, 4, 4)
fleet.add(stat("Not qualified", f"count({P} == 0) or vector(0)", thresholds=RED_ABOVE_0, links=failures_link,
               desc="Servers whose latest qualification failed or errored. Open GPU Burn-In: Failures for the list."), 4, 4, 8)
fleet.add(stat("Pass rate", f"sum({P}) / count({P})", unit="percentunit",
               thresholds={"mode": "absolute", "steps": [{"color": "red", "value": None}, {"color": "orange", "value": 0.95},
                                                          {"color": "green", "value": 0.99}]}), 4, 4, 12)
fleet.add(stat("Qualified in the last 24h", f"count(({P} == 1) and (time() - {F} < 86400)) or vector(0)"), 4, 4, 16)
fleet.add(stat("Stale", f"count(time() - {F} > $stale_days * 86400) or vector(0)",
               thresholds={"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "orange", "value": 1}]},
               desc="Servers whose latest qualification is older than the Stale after selector."), 4, 4, 20)
fleet.advance(4)

fleet.row("By GPU model and site")


def breakdown(by, header):
    return table(f"By {header.lower()}", [
        target(f"count by ({by}) ({P})", "A", table=True),
        target(f"sum by ({by}) ({P})", "B", table=True),
        target(f"count by ({by}) ({P} == 0)", "C", table=True),
        target(f"sum by ({by}) ({P}) / count by ({by}) ({P})", "D", table=True),
    ], by, {by: header, "Value #A": "Servers", "Value #B": "Qualified", "Value #C": "Not qualified", "Value #D": "Pass rate"},
        overrides=[override("Pass rate", ("unit", "percentunit"), ("custom.cellOptions", {"type": "color-text"}),
                            ("thresholds", {"mode": "absolute", "steps": [{"color": "red", "value": None},
                                                                           {"color": "orange", "value": 0.95},
                                                                           {"color": "green", "value": 0.99}]})),
                   override("Not qualified", ("thresholds", RED_ABOVE_0), ("custom.cellOptions", {"type": "color-text"}))],
        sort={"displayName": "Pass rate", "desc": False})


fleet.add(breakdown("gpu_model", "GPU model"), 12, 8, 0)
fleet.add(breakdown("site", "Site"), 12, 8, 12)
fleet.advance(8)

fleet.row("Failure analysis")
fleet.add(bargauge("Racks with the most not-qualified servers",
                   f"topk(20, sum by (site, rack) (1 - {P}) > 0)", "{{site}} / {{rack}}",
                   thresholds=RED_ABOVE_0, min_=0,
                   desc="Failures that cluster in a rack point at shared power, cooling or network, not single servers."), 8, 9, 0)
fleet.add(bargauge("Failing tests",
                   f'sort_desc(count by (test) (gpu_qualification_test_status{{{FILTER},status=~"failed|error"}} == 1))',
                   "{{test}}", thresholds=RED_ABOVE_0, min_=0, desc="Which tests fail most, across not-qualified servers."), 8, 9, 8)
fleet.add(timeseries("Not qualified over time", [(f"count({P} == 0) or vector(0)", "not qualified"),
                                                (f"count(time() - {F} > $stale_days * 86400) or vector(0)", "stale")]), 8, 9, 16)
fleet.advance(9)

fleet.row("Distributions")
SOAK_T = f'gpu_qualification_test_metric{{{FILTER},test="soak",metric="peak_temp_c"}}'
NCCL = f'gpu_qualification_test_metric{{{FILTER},test="nccl",metric="all_reduce_bus_bandwidth_gbps"}}'
fleet.add(table("Soak peak temperature by GPU model", [
    target(f"quantile by (gpu_model) (0.5, {SOAK_T})", "A", table=True),
    target(f"quantile by (gpu_model) (0.95, {SOAK_T})", "B", table=True),
    target(f"max by (gpu_model) ({SOAK_T})", "C", table=True),
], "gpu_model", {"gpu_model": "GPU model", "Value #A": "p50", "Value #B": "p95", "Value #C": "Hottest"},
    overrides=[override(n, ("unit", "celsius"), ("thresholds", TEMP), ("custom.cellOptions", {"type": "color-text"}))
               for n in ("p50", "p95", "Hottest")]), 12, 7, 0)
fleet.add(table("NCCL all_reduce bus bandwidth by GPU model", [
    target(f"quantile by (gpu_model) (0.5, {NCCL} > 0)", "A", table=True),
    target(f"quantile by (gpu_model) (0.05, {NCCL} > 0)", "B", table=True),
    target(f"min by (gpu_model) ({NCCL} > 0)", "C", table=True),
], "gpu_model", {"gpu_model": "GPU model", "Value #A": "p50 (GB/s)", "Value #B": "p5 (GB/s)", "Value #C": "Slowest (GB/s)"},
    desc="Single-GPU servers report 0 and are left out. Compare within a GPU model."), 12, 7, 12)
fleet.advance(7)
server_link = {"title": "Open server", "url": SERVER_LINK.replace("${__value.raw}", "${__field.labels.machine}")}
fleet.add(bargauge("Hottest 20 servers in the soak", f"topk(20, {SOAK_T})", "{{machine}}", unit="celsius",
                   thresholds=TEMP, min_=0, max_=110, link=server_link), 12, 9, 0)
fleet.add(bargauge("Slowest 20 servers for NCCL all_reduce", f"bottomk(20, {NCCL} > 0)", "{{machine}}",
                   min_=0, link=server_link, desc="GB/s. Single-GPU servers are left out."), 12, 9, 12)
fleet.advance(9)

fleet.row("NVLink")
NVL = f'gpu_qualification_test_metric{{{FILTER},test="inventory",metric=~"inactive_nvlinks|fabric_unhealthy_gpus"}}'
NVE = f'gpu_qualification_test_metric{{{FILTER},test="soak",metric="gpus_with_nvlink_errors"}}'
fleet.add(bargauge("Inactive NVLinks or unhealthy fabric, top 20", f"topk(20, {NVL} > 0)", "{{machine}}: {{metric}}",
                   thresholds=RED_ABOVE_0, min_=0, link=server_link,
                   desc="From inventory. fabric_unhealthy_gpus counts GPUs whose NVLink fabric (NVL72) is not healthy."), 12, 9, 0)
fleet.add(bargauge("GPUs with NVLink errors in the soak, top 20", f"topk(20, {NVE} > 0)", "{{machine}}",
                   thresholds=RED_ABOVE_0, min_=0, link=server_link,
                   desc="GPUs whose NVLink error counters grew during the soak. Only drivers that report the counters."), 12, 9, 12)
fleet.advance(9)

# =================================================================================================
# Failures
# =================================================================================================
fail = Dashboard(UID_FAILURES, "GPU Burn-In: Failures",
                 "Every server whose latest qualification did not pass: why, where, and for how long.")
fail.vars = filter_vars()
FI = f"gpu_qualification_failure_info{{{FILTER}}}"
fail.row("Summary")
fail.add(stat("Not qualified", f"count({FI}) or vector(0)", thresholds=RED_ABOVE_0), 6, 4, 0)
fail.add(stat("Failing repeatedly", f"count(gpu_qualification_consecutive_failures{{{FILTER}}} >= 2) or vector(0)",
              thresholds=RED_ABOVE_0, desc="Servers whose two or more newest reports did not pass: likely hardware, not a one-off."), 6, 4, 6)
fail.add(stat("Racks affected", f"count(count by (site, rack) ({FI})) or vector(0)",
              thresholds={"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "orange", "value": 1}]}), 6, 4, 12)
fail.add(stat("Oldest open failure",
              f"min(gpu_qualification_finished_timestamp_seconds{{{FILTER}}} and on (machine) ({P} == 0)) * 1000",
              unit="dateTimeFromNow", desc="When the longest-failing server's latest qualification finished."), 6, 4, 18)
fail.advance(4)

fail.row("Not-qualified servers")
M = "max by (machine)"
fail.add(table("Not-qualified servers", [
    target(FI, "A", table=True),
    target(f"{M} (gpu_qualification_finished_timestamp_seconds{{{FILTER}}}) * 1000", "B", table=True),
    target(f"{M} (gpu_qualification_consecutive_failures{{{FILTER}}})", "C", table=True),
    target(f'{M} (gpu_qualification_gpus{{{FILTER},kind="found"}})', "D", table=True),
    target(f'{M} (gpu_qualification_gpus{{{FILTER},kind="expected"}})', "E", table=True),
    target(f'{M} (gpu_qualification_test_metric{{{FILTER},test="inventory",metric="uncorrected_ecc_errors"}})', "F", table=True),
    target(f'{M} (gpu_qualification_test_metric{{{FILTER},test="soak",metric="peak_temp_c"}})', "G", table=True),
    target(f'{M} (gpu_qualification_test_metric{{{FILTER},test="soak",metric="gpus_with_xid"}})', "H", table=True),
    target(f'{M} (gpu_qualification_test_metric{{{FILTER},test="inventory",metric="inactive_nvlinks"}})', "I", table=True),
    target(f'{M} (gpu_qualification_test_metric{{{FILTER},test="inventory",metric="fabric_unhealthy_gpus"}})', "J", table=True),
    target(f'{M} (gpu_qualification_test_metric{{{FILTER},test="soak",metric="gpus_with_nvlink_errors"}})', "K", table=True),
], "machine", {
    "machine": "Machine", "site": "Site", "rack": "Rack", "gpu_model": "GPU model", "result": "Result",
    "failed_tests": "Failed tests", "summary": "Why", "Value #B": "Finished", "Value #C": "Failures in a row",
    "Value #D": "GPUs", "Value #E": "Expected", "Value #F": "Uncorrected ECC", "Value #G": "Soak peak (C)",
    "Value #H": "GPUs with XID", "Value #I": "Inactive NVLinks", "Value #J": "Fabric unhealthy",
    "Value #K": "GPUs with NVLink errors", "inventory_url": "Inventory", "report": "QualificationReport"},
    desc="One row per server whose latest qualification failed or errored, newest first. Click a machine for its history.",
    overrides=[
        override("Machine", ("links", [{"title": "Open server", "url": SERVER_LINK}])),
        override("Inventory", ("links", [{"title": "Open in the inventory", "url": "${__value.raw}", "targetBlank": True}])),
        override("Finished", ("unit", "dateTimeAsIso")),
        override("Why", ("custom.width", 420), ("custom.cellOptions", {"type": "auto", "wrapText": True})),
        override("Result", ("custom.cellOptions", {"type": "color-text"}),
                 ("mappings", [{"type": "value", "options": {"failed": {"color": "red", "index": 0},
                                                             "error": {"color": "dark-red", "index": 1}}}])),
        override("Failures in a row", ("thresholds", {"mode": "absolute", "steps": [{"color": "orange", "value": None},
                                                                                    {"color": "red", "value": 2}]}),
                 ("custom.cellOptions", {"type": "color-text"})),
        override("Uncorrected ECC", ("thresholds", RED_ABOVE_0), ("custom.cellOptions", {"type": "color-text"})),
        override("GPUs with XID", ("thresholds", RED_ABOVE_0), ("custom.cellOptions", {"type": "color-text"})),
        *[override(n, ("thresholds", RED_ABOVE_0), ("custom.cellOptions", {"type": "color-text"}))
          for n in ("Inactive NVLinks", "Fabric unhealthy", "GPUs with NVLink errors")],
        override("Soak peak (C)", ("thresholds", TEMP), ("custom.cellOptions", {"type": "color-text"})),
    ], sort={"displayName": "Finished", "desc": True}), 24, 12, 0)
fail.advance(12)

fail.row("Where and why")
fail.add(bargauge("By rack", f"topk(25, count by (site, rack) ({FI}))", "{{site}} / {{rack}}",
                  thresholds=RED_ABOVE_0, min_=0, desc="Several failures in one rack point at shared power, cooling or network."), 8, 9, 0)
fail.add(bargauge("By failed test",
                  f'sort_desc(count by (test) (gpu_qualification_test_status{{{FILTER},status=~"failed|error"}} == 1))',
                  "{{test}}", thresholds=RED_ABOVE_0, min_=0), 8, 9, 8)
fail.add(bargauge("By GPU model", f"sort_desc(count by (gpu_model) ({FI}))", "{{gpu_model}}",
                  thresholds=RED_ABOVE_0, min_=0), 8, 9, 16)
fail.advance(9)
fail.add(timeseries("Not-qualified servers over time", [(f"count({FI}) or vector(0)", "not qualified"),
                                                       (f"count(gpu_qualification_consecutive_failures{{{FILTER}}} >= 2) or vector(0)",
                                                        "failing repeatedly")]), 24, 8, 0)
fail.advance(8)

# =================================================================================================
# Server
# =================================================================================================
srv = Dashboard(UID_SERVER, "GPU Burn-In: Server", "One server's latest qualification, its measurements and its history.")
srv.vars = [query_var("machine", "Machine", "gpu_qualification_passed", multi=False)]
MS = 'machine="$machine"'
srv.row("Latest qualification")
srv.add(stat("Result", f"max(gpu_qualification_passed{{{MS}}})", mappings=RESULT_MAPPING,
             thresholds={"mode": "absolute", "steps": [{"color": "red", "value": None}, {"color": "green", "value": 1}]}), 4, 4, 0)
srv.add(stat("GPUs found", f'max(gpu_qualification_gpus{{{MS},kind="found"}})'), 4, 4, 4)
srv.add(stat("GPUs expected", f'max(gpu_qualification_gpus{{{MS},kind="expected"}})'), 4, 4, 8)
srv.add(stat("Finished", f"max(gpu_qualification_finished_timestamp_seconds{{{MS}}}) * 1000", unit="dateTimeFromNow"), 4, 4, 12)
srv.add(stat("Failures in a row", f"max(gpu_qualification_consecutive_failures{{{MS}}})",
             thresholds={"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "orange", "value": 1},
                                                        {"color": "red", "value": 2}]}), 4, 4, 16)
srv.add(stat("Reports kept", f"sum(gpu_qualification_reports{{{MS}}})"), 4, 4, 20)
srv.advance(4)
srv.add(table("Placement", [target(f"gpu_qualification_result{{{MS}}}", table=True)], "machine",
              {"provider": "Provider", "site": "Site", "location": "Location", "rack": "Rack", "gpu_model": "GPU model",
               "profile": "Profile", "source": "Source", "result": "Result"}), 24, 3, 0)
srv.advance(3)
srv.add(table("Why it did not pass", [target(f"gpu_qualification_failure_info{{{MS}}}", table=True)], "machine",
              {"failed_tests": "Failed tests", "summary": "Why", "report": "QualificationReport", "inventory_url": "Inventory"},
              desc="Empty when the latest qualification passed.",
              overrides=[override("Inventory", ("links", [{"title": "Open in the inventory", "url": "${__value.raw}",
                                                           "targetBlank": True}])),
                         override("Why", ("custom.cellOptions", {"type": "auto", "wrapText": True}))]), 24, 4, 0)
srv.advance(4)
srv.add(table("Tests", [target(f"gpu_qualification_test_status{{{MS}}} == 1", table=True)], "test",
              {"test": "Test", "status": "Status"},
              overrides=[override("Status", ("mappings", STATUS_MAPPING), ("custom.cellOptions", {"type": "color-background"}))]),
        8, 8, 0)
srv.add(table("Measurements", [target(f"gpu_qualification_test_metric{{{MS}}}", table=True)], "metric",
              {"test": "Test", "metric": "Metric", "Value": "Value"},
              sort={"displayName": "Test", "desc": False}), 16, 8, 8)
srv.advance(8)
srv.row("History")
srv.add(timeseries("Qualified", [(f"max(gpu_qualification_passed{{{MS}}})", "qualified")], step=True,
                   desc="1 while the latest qualification passed. Changes when a new report is recorded."), 12, 7, 0)
srv.add(timeseries("Soak peak temperature",
                   [(f'max(gpu_qualification_test_metric{{{MS},test="soak",metric="peak_temp_c"}})', "peak")],
                   unit="celsius", step=True), 12, 7, 12)
srv.advance(7)
srv.add(timeseries("NCCL bus bandwidth",
                   [(f'gpu_qualification_test_metric{{{MS},test="nccl",metric=~".+_bus_bandwidth_gbps"}}', "{{metric}}")],
                   step=True, desc="GB/s per collective."), 12, 7, 0)
srv.add(timeseries("Errors", [(f'max(gpu_qualification_test_metric{{{MS},test="inventory",metric="uncorrected_ecc_errors"}})', "uncorrected ECC"),
                             (f'max(gpu_qualification_test_metric{{{MS},test="soak",metric="gpus_with_xid"}})', "GPUs with XID"),
                             (f'max(gpu_qualification_test_metric{{{MS},test="inventory",metric="inactive_nvlinks"}})', "inactive NVLinks"),
                             (f'max(gpu_qualification_test_metric{{{MS},test="inventory",metric="fabric_unhealthy_gpus"}})',
                              "GPUs with unhealthy fabric"),
                             (f'max(gpu_qualification_test_metric{{{MS},test="soak",metric="gpus_with_nvlink_errors"}})',
                              "GPUs with NVLink errors")],
                   step=True, desc="NVLink fabric and soak NVLink series appear only when the run reported them."), 12, 7, 12)
srv.advance(7)

# =================================================================================================
ALL = [(fleet, "gpu-burn-in.json", [link("GPU Burn-In: Failures", UID_FAILURES), link("GPU Burn-In: Server", UID_SERVER, False),
                                    link("GPU Overview", "vcluster-gpu-overview", False)], ["fleet"]),
       (fail, "gpu-burn-in-failures.json", [link("GPU Burn-In", UID_FLEET), link("GPU Burn-In: Server", UID_SERVER, False)],
        ["failures"]),
       (srv, "gpu-burn-in-server.json", [link("GPU Burn-In", UID_FLEET, False), link("GPU Burn-In: Failures", UID_FAILURES, False),
                                         link("Tenant Cluster GPUs", "vcluster-tenant-gpus", False)], ["server"])]
OUT.mkdir(parents=True, exist_ok=True)
for d, name, links, tags in ALL:
    (OUT / name).write_text(json.dumps(d.json(links, tags), indent=2) + "\n")
    print(f"wrote {OUT / name}")
