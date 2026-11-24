#!/usr/bin/env bash
# Static checks for the NVSentinel Stack: the invariants the Platform does not validate
# for you. Modeled on community-stacks/nvidia-gpu-operator/test-manifests.sh.
#
#   ./test-manifests.sh
#
# Renders the graph the way the Platform would, for the default parameters and for a variant that
# takes the other branch of every conditional: StackTemplate tasks, then each referenced
# ArgoCDApplicationTemplate or App. App manifests are rendered as the Helm chart the Platform
# builds from them.
#
# Pass --offline to skip rendering the upstream NVSentinel chart, which needs the network.
#
# Needs bash >= 4, python3 with PyYAML and helm. Exits 1 on failures, 2 on a missing prerequisite.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

missing=()
[[ "${BASH_VERSINFO[0]}" -ge 4 ]] || missing+=("bash >= 4 (running ${BASH_VERSION}; macOS /bin/bash is 3.2, try 'brew install bash')")
for tool in python3 helm; do
  command -v "$tool" >/dev/null || missing+=("$tool")
done
command -v python3 >/dev/null && { python3 -c 'import yaml' 2>/dev/null || missing+=("PyYAML (python3 -m pip install pyyaml)"); }
if [[ "${#missing[@]}" -gt 0 ]]; then
  echo "cannot run: missing prerequisite(s)" >&2
  printf '  - %s\n' "${missing[@]}" >&2
  exit 2
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

python3 - "$root" "$work" "$@" <<'CHECKS'
import copy
import json
import re
import subprocess
import sys
from pathlib import Path

import yaml

root, work = Path(sys.argv[1]), Path(sys.argv[2])
offline = "--offline" in sys.argv[3:]
errors = []

PREFIX = "nvsentinel"
PART_OF = "nvsentinel-stack"
STACK = "nvsentinel"
GPU_STACK_GATE = "community-stacks/nvidia-gpu-operator/apps/02-gate.yaml"
GATE = f"{PREFIX}-gate"
DISCOVER = f"{PREFIX}-discover"
SLINKY = f"{PREFIX}-slinky-drainer"
# The Platform caps every App deploy (helm --wait) at 30 minutes.
APP_DEPLOY_CAP = 30 * 60
# Stands in for the image the Platform injects as .Values.__image__.
PLATFORM_IMAGE = "ghcr.io/loft-sh/vcluster-platform:test"
TYPES = {"string", "multiline", "boolean", "number", "password", None}
VALUES_REF = re.compile(r"\.Values\.([A-Za-z_][A-Za-z0-9_]*)")
OUTPUTS_REF = re.compile(r"\.Outputs\.([A-Za-z0-9_]+)\.([A-Za-z0-9_]+)")
# What the discover Job writes for each resolved mode. The Job's script must contain every value,
# and the rendered graph is checked against these, standing in for the Job's runtime result.
DISCOVER_FACTS = {
    "device-plugin": {"mode": "device-plugin", "dcgmDaemonSet": "nvidia-dcgm",
                      "capacitySource": "allocatable", "capacityResource": "nvidia.com/gpu"},
    "dra": {"mode": "dra", "dcgmDaemonSet": "nvidia-dcgm-dra",
            "capacitySource": "resourceslices", "capacityResource": "gpu.nvidia.com"},
}
DISCOVER_KEYS = set(DISCOVER_FACTS["dra"]) | {"dcgmHost", "dcgmPort", "dcgmNamespace", "dcgmWait", "cpuNodeSelector",
                                              "gpuNodeSelector", "source", "discoveredAt"}


def discover_facts(mode, values):
    """What the discover Job would publish for these Stack parameters."""
    facts = dict(DISCOVER_FACTS[mode])
    override = str(values.get("dcgmHost") or "")
    facts["dcgmNamespace"] = str(values["gpuOperatorNamespace"])
    facts["dcgmHost"] = override or f"{facts['dcgmDaemonSet']}.{facts['dcgmNamespace']}.svc"
    facts["dcgmPort"] = str(values["dcgmPort"])
    facts["dcgmWait"] = "false" if override else "true"
    # discover publishes the selectors it checked, exactly as it received them.
    facts["cpuNodeSelector"] = cpu_selector_raw(values)
    facts["gpuNodeSelector"] = gpu_selector_raw(values)
    return facts


def fail(message):
    errors.append(message)


def rel(path):
    return str(path.relative_to(root))


def load(path):
    try:
        return [d for d in yaml.safe_load_all(path.read_text()) if d is not None]
    except yaml.YAMLError as e:
        fail(f"{rel(path)}: not valid YAML: {e}")
        return []


def go_duration(text, where):
    """Seconds for a Go duration, failing unless it is in the canonical form metav1.Duration stores."""
    m = re.fullmatch(r"(?:(\d+)h)?(?:(\d+)m)?(\d+)s", str(text))
    if not m:
        fail(f"{where}: timeout {text!r} must be a full Go duration such as 45m0s")
        return None
    h, mi, s = (int(g or 0) for g in m.groups())
    total = h * 3600 + mi * 60 + s
    canonical = (f"{total // 3600}h" if total >= 3600 else "") + (f"{total % 3600 // 60}m" if total >= 60 else "") + f"{total % 60}s"
    if text != canonical:
        fail(f"{where}: timeout {text!r} is stored as {canonical!r}; write that, or Argo CD drifts forever")
    return total


def short_duration(text, where):
    """Seconds for an App timeout such as 25m."""
    m = re.fullmatch(r"(\d+)(s|m|h)", str(text))
    if not m:
        fail(f"{where}: timeout {text!r} must look like 25m")
        return None
    return int(m.group(1)) * {"s": 1, "m": 60, "h": 3600}[m.group(2)]


def strings(node, path=()):
    if isinstance(node, dict):
        for k, v in node.items():
            yield from strings(v, path + (k,))
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield from strings(v, path + (i,))
    elif isinstance(node, str):
        yield path, node


def put(node, path, value):
    for p in path[:-1]:
        node = node[p]
    node[path[-1]] = value


# StackTemplate tasks and ArgoCDApplicationTemplates are rendered one string at a time with
# Helm's own engine (text/template plus sprig), through tpl. Parameter values are strings, as the
# Platform passes them.
render_chart = work / "render"
(render_chart / "templates").mkdir(parents=True)
(render_chart / "Chart.yaml").write_text("apiVersion: v2\nname: render\nversion: 0.0.0\n")
(render_chart / "templates" / "out.yaml").write_text(
    '{{- $ctx := dict "Values" (omit .Values "__strings" "__outputs") "Outputs" .Values.__outputs "Template" .Template }}\n'
    "{{- range $k, $v := .Values.__strings }}\n"
    "{{ $k }}: {{ tpl $v $ctx | toJson }}\n"
    "{{- end }}\n"
)
counter = {"render": 0, "app": 0}


def as_strings(values):
    return {k: ("" if v is None else str(v)) for k, v in values.items()}


def render(node, values, where, outputs=None):
    """node with every templated string rendered against values; None if Helm refuses."""
    node = copy.deepcopy(node)
    todo = {f"s{i}": (p, s) for i, (p, s) in enumerate(strings(node)) if "{{" in s}
    if not todo:
        return node
    counter["render"] += 1
    vals = as_strings(values)
    vals["__strings"] = {k: s for k, (_, s) in todo.items()}
    vals["__outputs"] = outputs or {}
    vf = work / f"values-{counter['render']}.json"
    vf.write_text(json.dumps(vals))
    r = subprocess.run(["helm", "template", "r", str(render_chart), "-f", str(vf)], capture_output=True, text=True)
    if r.returncode != 0:
        fail(f"{where}: does not render: {r.stderr.strip()}")
        return None
    out = {}
    for d in yaml.safe_load_all(r.stdout):
        out.update(d or {})
    for k, (p, _) in todo.items():
        put(node, p, out[k])
    return node


def render_app(app, passed, release, where):
    """The objects an App's manifests render to, as the Platform deploys them from a Stack task:
    only the task's parameters (no App defaults), plus __image__ when the manifests use it."""
    manifests = app["doc"]["spec"]["config"].get("manifests")
    if not manifests:
        return None
    counter["app"] += 1
    chart = work / f"app-{counter['app']}"
    (chart / "templates").mkdir(parents=True)
    (chart / "Chart.yaml").write_text("apiVersion: v2\nname: app\nversion: 0.0.1\n")
    (chart / "templates" / "manifests.yaml").write_text(manifests)
    vals = as_strings(passed)
    if "__image__" in manifests:
        vals["__image__"] = PLATFORM_IMAGE
    vf = work / f"app-values-{counter['app']}.json"
    vf.write_text(json.dumps(vals))
    ns = app["doc"]["spec"].get("defaultNamespace", "default")
    r = subprocess.run(["helm", "template", release, str(chart), "--namespace", ns, "-f", str(vf)], capture_output=True, text=True)
    if r.returncode != 0:
        fail(f"{where}: does not render: {r.stderr.strip()}")
        return None
    try:
        return [d for d in yaml.safe_load_all(r.stdout) if d]
    except yaml.YAMLError as e:
        fail(f"{where}: rendered output is not YAML: {e}")
        return None


def check_parameters(where, params):
    by_name = {}
    for p in params or []:
        v = p.get("variable")
        if not v:
            fail(f"{where}: parameter without a variable")
            continue
        if v in by_name:
            fail(f"{where}: duplicate parameter {v}")
        by_name[v] = p
        t = p.get("type")
        if t not in TYPES:
            fail(f"{where}: {v} has type {t!r}")
        if not p.get("label"):
            fail(f"{where}: {v} has no label")
        if "defaultValue" not in p:
            continue
        d = str(p["defaultValue"])
        if t == "boolean" and d not in ("true", "false"):
            fail(f"{where}: {v} is a boolean with default {d!r}")
        if t == "number":
            if not re.fullmatch(r"-?[0-9]+", d):
                fail(f"{where}: {v} is a number with default {d!r}")
            elif "min" in p and int(d) < int(p["min"]):
                fail(f"{where}: {v} default {d} is below min {p['min']}")
        options = [str(o) for o in p.get("options") or []]
        if options and d not in options:
            fail(f"{where}: {v} default {d!r} is not one of {options}")
    return by_name


def defaults(params):
    return {v: p["defaultValue"] for v, p in params.items() if "defaultValue" in p}


def parse_selector(raw):
    """Comma-separated key=value labels as a dict."""
    return dict(p.strip().split("=", 1) for p in str(raw or "").split(",") if p.strip())


def cpu_selector_raw(values):
    """The CPU node selector in effect, as the Stack hands it to discover: cpuNodeSelector, or the pool label."""
    return str(values.get("cpuNodeSelector") or "") or f"workload.example.com/pool={values['cpuNodePool']}"


def gpu_selector_raw(values):
    """The GPU node selector in effect: gpuNodeSelector, or the GPU pool label."""
    return str(values.get("gpuNodeSelector") or "") or "workload.example.com/pool=gpu-compute"


def check_refs(where, node, declared, extra_ok=()):
    for path, s in strings(node):
        for ref in VALUES_REF.findall(s):
            if ref not in declared and ref not in extra_ok:
                fail(f"{where}: {'.'.join(map(str, path))} uses .Values.{ref}, which is not a declared parameter")


def common(path, doc, kinds):
    md = doc.get("metadata") or {}
    kinds = (kinds,) if isinstance(kinds, str) else kinds
    if doc.get("apiVersion") != "management.loft.sh/v1" or doc.get("kind") not in kinds:
        fail(f"{rel(path)}: expected management.loft.sh/v1 {' or '.join(kinds)}, found {doc.get('apiVersion')} {doc.get('kind')}")
    if not str(md.get("name", "")).startswith(PREFIX):
        fail(f"{rel(path)}: {doc.get('kind')} {md.get('name')!r} must start with {PREFIX} so it cannot collide in the catalog")
    if (md.get("labels") or {}).get("app.kubernetes.io/part-of") != PART_OF:
        fail(f"{rel(path)}: {doc.get('kind')} {md.get('name')} lacks label app.kubernetes.io/part-of: {PART_OF}")


# --- ArgoCDApplicationTemplates and Apps ---------------------------------------------------------
apps = {}
for path in sorted((root / "apps").glob("*.yaml")):
    docs = load(path)
    if len(docs) != 1:
        fail(f"{rel(path)}: expected exactly one YAML document, found {len(docs)}")
        continue
    doc = docs[0]
    common(path, doc, ("ArgoCDApplicationTemplate", "App"))
    name = doc["metadata"]["name"]
    stem = re.sub(r"^\d+-", "", path.stem)
    if name != f"{PREFIX}-{stem}":
        fail(f"{rel(path)}: name {name!r} does not match its file; expected {PREFIX}-{stem}")
    params = check_parameters(rel(path), doc["spec"].get("parameters"))
    kind = doc["kind"]
    if kind == "App":
        spec = doc["spec"]
        check_refs(rel(path), spec.get("config"), params, extra_ok=("__image__",))
        if spec.get("config", {}).get("chart"):
            fail(f"{rel(path)}: this Stack's Apps carry their manifests; a chart source brings back an outside dependency")
        if spec.get("wait") is not True:
            fail(f"{rel(path)}: wait must be true, or the task is Healthy before its Job or Deployment is ready")
        seconds = short_duration(spec.get("timeout", ""), rel(path))
        if seconds is not None and seconds >= APP_DEPLOY_CAP:
            fail(f"{rel(path)}: timeout {spec['timeout']} reaches the Platform's 30m per-deploy cap")
        if not spec.get("defaultNamespace"):
            fail(f"{rel(path)}: no defaultNamespace; Stack outputs can be read only from a namespace a task deploys into")
    else:
        check_refs(rel(path), doc["spec"]["template"], params)
        # The Platform renders these itself, with fewer functions than Helm's tpl that this test
        # uses. Functions it was seen to lack ("function ... not defined"):
        for func in ("merge",):
            for _, text in strings(doc["spec"]["template"]):
                if re.search(r"\{\{[^}]*\b" + func + r"\b", re.sub(r"/\*.*?\*/", "", text, flags=re.S)):
                    fail(f"{rel(path)}: uses {func}, which the Platform's template renderer does not define")
                    break
    apps[name] = {"path": path, "doc": doc, "params": params, "kind": kind}

gate_doc = apps.get(GATE, {})
if gate_doc.get("kind") != "App" or "__image__" not in gate_doc["doc"]["spec"].get("config", {}).get("manifests", ""):
    fail(f"apps/: {GATE} must be an App whose Job runs .Values.__image__; that keeps this Stack free of its own image")
discover_manifests = apps.get(DISCOVER, {}).get("doc", {}).get("spec", {}).get("config", {}).get("manifests", "")
for mode, facts in DISCOVER_FACTS.items():
    for key, value in facts.items():
        if value not in discover_manifests:
            fail(f"apps/: {DISCOVER} never writes {key}={value!r} for {mode}; the test's DISCOVER_FACTS and the Job disagree")

# The gate is a copy of the nvidia-gpu-operator Stack's gate, so either Stack installs alone.
# Apart from the names, the two Apps must be the same: a fix to one belongs in both.
gpu_gate_path = root.parent.parent / GPU_STACK_GATE
if gpu_gate_path.exists() and gate_doc:
    theirs = copy.deepcopy((load(gpu_gate_path) or [{}])[0].get("spec") or {})
    ours = copy.deepcopy(gate_doc["doc"]["spec"])
    for spec_, name_, display in ((theirs, "nvidia-gpu-operator-gate", "NVIDIA GPU Stack - Readiness Gate"),
                                  (ours, GATE, "NVSentinel - Readiness Gate")):
        spec_["config"]["manifests"] = spec_["config"]["manifests"].replace(name_, "GATE")
        if spec_.pop("displayName", None) != display:
            fail(f"apps/: unexpected gate displayName in {name_}")
        spec_.pop("defaultNamespace", None)
    for key in sorted(set(theirs) | set(ours)):
        if theirs.get(key) != ours.get(key):
            fail(f"apps/: the gate App's spec.{key} differs from {GPU_STACK_GATE}; keep the two copies in step")

# The Slinky drainer's manifests are a copy of upstream's at one tag. A version bump without a
# re-sync would run a new image against the old CRD and RBAC.
slinky_text = apps.get(SLINKY, {}).get("path").read_text() if SLINKY in apps else ""
copied = re.search(r"^# manifests copied from: (\S+)$", slinky_text, flags=re.M)
slinky_version = defaults(apps.get(SLINKY, {}).get("params", {})).get("version")
if not copied or copied.group(1) != slinky_version:
    fail(f"apps/: {SLINKY} pins version {slinky_version!r}, but its manifests were copied from {copied.group(1) if copied else None!r}; re-sync them from upstream and update the 'manifests copied from' line")

# --- StackTemplate -------------------------------------------------------------------------------
st_path = root / "stacktemplate.yaml"
st = (load(st_path) or [{}])[0]
common(st_path, st, "StackTemplate")
if st["metadata"]["name"] != STACK:
    fail(f"stacktemplate.yaml: expected StackTemplate {STACK}")
if (st["metadata"].get("annotations") or {}).get("vcluster.com/certified"):
    fail("stacktemplate.yaml: a community stack must not carry vcluster.com/certified")
spec = st["spec"]
stack_params = check_parameters("stacktemplate.yaml", spec.get("parameters"))
tasks = {t["name"]: t for t in spec.get("tasks") or []}
check_refs("stacktemplate.yaml", spec.get("tasks"), stack_params)

task_seconds = {}
for name, task in tasks.items():
    where = f"stacktemplate.yaml task {name}"
    task_seconds[name] = go_duration(task.get("timeout", ""), where)
    if ("app" in task) == ("argoCDApplication" in task):
        fail(f"{where}: needs exactly one of app or argoCDApplication")
    for dep in task.get("dependsOn") or []:
        if dep not in tasks:
            fail(f"{where}: depends on unknown task {dep}")
    if task.get("outputs") and not re.fullmatch(r"[A-Za-z0-9]+", name):
        fail(f"{where}: declares outputs, so its name must be letters and digits only")


def ancestors(name, seen=()):
    if name in seen:
        fail(f"stacktemplate.yaml: dependency cycle through {name}")
        return set()
    out = set()
    for dep in tasks.get(name, {}).get("dependsOn") or []:
        out |= {dep} | ancestors(dep, seen + (name,))
    return out


declared_outputs = {n: {o["name"]: o for o in t.get("outputs") or []} for n, t in tasks.items()}
for name, task in tasks.items():
    up = ancestors(name)
    for _, s in strings(task):
        for src, out in OUTPUTS_REF.findall(s):
            if src not in up:
                fail(f"stacktemplate.yaml task {name}: reads .Outputs.{src}, which is not one of its dependencies")
            elif out not in declared_outputs.get(src, {}):
                fail(f"stacktemplate.yaml task {name}: reads .Outputs.{src}.{out}, which {src} does not declare")
for po in spec.get("publishedOutputs") or []:
    ft = po.get("fromTask") or {}
    if ft.get("output") not in declared_outputs.get(ft.get("task"), {}):
        fail(f"stacktemplate.yaml: published output {po.get('name')} reads an undeclared task output {ft}")

# Every task that differs between device-plugin and DRA must take the mode from discover, never
# from the parameter, or `auto` would leave it on a different mode than the GPU Operator runs.
for name, task in tasks.items():
    if name != "discover" and any("gpuDriverMode" in ref for _, s in strings(task) for ref in VALUES_REF.findall(s)):
        fail(f"stacktemplate.yaml task {name}: reads .Values.gpuDriverMode; take the resolved mode from .Outputs.discover.mode")
    passed = (task.get("app") or task.get("argoCDApplication") or {}).get("parameters") or {}
    if name != "discover" and "gpuDriverMode" in passed and passed["gpuDriverMode"] != "{{ .Outputs.discover.mode }}":
        fail(f"stacktemplate.yaml task {name}: gpuDriverMode must be '{{{{ .Outputs.discover.mode }}}}'")
for name in ("nvsentinel",):
    if name in tasks and "gpuDriverMode" not in ((tasks[name].get("app") or tasks[name].get("argoCDApplication") or {}).get("parameters") or {}):
        fail(f"stacktemplate.yaml task {name}: does not pass gpuDriverMode; it would stay on its default mode")

# node-drainer mounts the Slinky drain template and creates DrainRequests, so with Slinky drain on
# the ConfigMap and the CRD must exist before NVSentinel starts.
if "slinky-drainer" in tasks and "slinky-drainer" not in ancestors("nvsentinel"):
    fail("stacktemplate.yaml task nvsentinel: must depend on slinky-drainer; node-drainer mounts its drain template")

# discover checks the node selectors and publishes them. A task that read the parameter itself
# would deploy a selector discover rejected, because a running Stack re-syncs changed tasks without
# waiting for discover.
for name, task in tasks.items():
    if name == "discover":
        continue
    passed = (task.get("app") or task.get("argoCDApplication") or {}).get("parameters") or {}
    for param in ("cpuNodeSelector", "gpuNodeSelector", "capacityNodeSelector"):
        value = str(passed.get(param, ""))
        if param in passed and (".Values." in value or ".Outputs." not in value):
            fail(f"stacktemplate.yaml task {name}: {param} must come from a task output, not from a parameter: {value!r}")
passed = (tasks.get("nvsentinel", {}).get("argoCDApplication") or {}).get("parameters") or {}
if not {"cpuNodeSelector", "gpuNodeSelector"} <= set(passed):
    fail("stacktemplate.yaml task nvsentinel: must pass cpuNodeSelector and gpuNodeSelector from discover's outputs")

# A rollout wait on a DaemonSet that schedules no pods yet passes at once, so dcgmready must
# follow gpuready, which proves a GPU node is there.
if "dcgmready" in tasks and "gpuready" not in ancestors("dcgmready"):
    fail("stacktemplate.yaml task dcgmready: must depend on gpuready; before a GPU node joins, the DCGM DaemonSet has already rolled out")

# The shipped behavior: NVSentinel cordons on a GPU fault, for real, unless told otherwise.
if (str(defaults(stack_params).get("cordon")), str(defaults(stack_params).get("dryRun")),
        str(defaults(stack_params).get("drain"))) != ("true", "false", "false"):
    fail("stacktemplate.yaml: NVSentinel must default to cordoning without draining (cordon=true, dryRun=false, drain=false)")
if defaults(stack_params).get("cpuNodeSelector"):
    fail("stacktemplate.yaml: cpuNodeSelector must default to empty, which selects workload.example.com/pool=<cpuNodePool>")
if defaults(stack_params).get("gpuNodeSelector"):
    fail("stacktemplate.yaml: gpuNodeSelector must default to empty, which selects workload.example.com/pool=gpu-compute")
if defaults(stack_params).get("mongodbStorageClass"):
    fail("stacktemplate.yaml: mongodbStorageClass must default to empty; the StatefulSet's volume claims cannot change on upgrade")
if str(defaults(stack_params).get("circuitBreakerEnabled")) != "true":
    fail("stacktemplate.yaml: NVSentinel's circuit breaker must default to on")
if not re.fullmatch(r"(?:\d+(?:\.\d+)?(?:h|m|s|ms|us|ns))+", str(defaults(stack_params).get("circuitBreakerDuration", ""))) \
        or not re.search(r"[1-9]", str(defaults(stack_params).get("circuitBreakerDuration", ""))):
    fail("stacktemplate.yaml: circuitBreakerDuration must default to a positive Go duration; fault-quarantine refuses to start otherwise")
if str(defaults(stack_params).get("remediation")) != "none":
    fail("stacktemplate.yaml: remediation is opt-in; it must default to none")
if str(defaults(stack_params).get("drainMode")) != "Immediate":
    fail("stacktemplate.yaml: drainMode must default to Immediate, the only mode that evicts through the Eviction API")
if str(defaults(stack_params).get("slinkyDrain")) != "false":
    fail("stacktemplate.yaml: Slinky drain is opt-in; slinkyDrain must default to false")
if str(defaults(stack_params).get("gpuDriverMode")) != "auto":
    fail("stacktemplate.yaml: gpuDriverMode must default to auto, so the Stack follows the GPU Operator already in the cluster")
if defaults(stack_params).get("dcgmHost"):
    fail("stacktemplate.yaml: dcgmHost must default to empty, which follows the GPU Operator's DCGM Service")

# Defaults that must agree across files: a stack default overrides the template's, so a drifted
# template default only bites when someone deploys the template on its own.
NVS = f"{PREFIX}-nvsentinel"
for stack_var, app, app_var in [
    ("version", NVS, "version"), ("version", SLINKY, "version"),
    ("cpuNodePool", NVS, "cpuNodePool"), ("cpuNodePool", SLINKY, "cpuNodePool"),
    ("slinkyNamespace", SLINKY, "slinkyNamespace"),
    ("gpuDriverMode", DISCOVER, "gpuDriverMode"), ("gpuOperatorNamespace", DISCOVER, "gpuOperatorNamespace"),
    ("dcgmPort", DISCOVER, "dcgmPort"), ("dcgmPort", NVS, "dcgmPort"),
] + [(v, NVS, v) for v in (
    "cordon", "dryRun", "drain", "drainMode", "drainTimeoutMinutes", "drainImmediateNamespaces", "remediation",
    "mongodbReplicas", "circuitBreakerEnabled", "circuitBreakerDuration", "circuitBreakerPercentage",
    "circuitBreakerMaxNodes", "slinkyNodeSelector", "driverPreinstalled")]:
    a = defaults(stack_params).get(stack_var)
    b = defaults(apps.get(app, {}).get("params", {})).get(app_var)
    if str(a) != str(b):
        fail(f"default {stack_var}={a!r} in stacktemplate.yaml disagrees with {app_var}={b!r} in {app}")

# --- Render the graph for two parameter sets -----------------------------------------------------
VARIANTS = {
    "defaults": {"gpuDriverMode": "device-plugin"},
    "alternate": {"gpuDriverMode": "device-plugin", "driverPreinstalled": "true",
                  "cordon": "false", "dryRun": "true", "drain": "true",
                  "slinkyDrain": "true", "remediation": "reboot",
                  "gpuOperatorNamespace": "nvidia-system", "dcgmPort": "5556",
                  "cpuNodeSelector": "foo.acme.corp/cpu-node=true, tier=services",
                  "gpuNodeSelector": "foo.acme.corp/gpu-node=true, tier=gpu"},
    "dra": {"gpuDriverMode": "dra"},
    # Remediation and Slinky drain both act on drained nodes. With drain off they must stay off,
    # or a node could be rebooted with its pods still on it.
    "cordon-remediate-no-drain": {"gpuDriverMode": "device-plugin", "cordon": "true", "drain": "false",
                                  "remediation": "reboot", "slinkyDrain": "true"},
    "reboot": {"gpuDriverMode": "device-plugin", "drain": "true", "remediation": "reboot",
               "drainMode": "AllowCompletion", "dcgmHost": "dcgm.monitoring.svc"},
    "dra-alternate": {"gpuDriverMode": "dra", "driverPreinstalled": "true",
                      "dryRun": "true", "mongodbReplicas": "3", "drain": "true",
                      "mongodbStorageClass": "fast-ssd",
                      "circuitBreakerPercentage": "100", "circuitBreakerMaxNodes": "2",
                      "circuitBreakerEnabled": "false", "circuitBreakerDuration": "1h30m",
                      "remediation": "gpu-reset",
                      "drainMode": "DeleteAfterTimeout", "drainTimeoutMinutes": "10",
                      "drainImmediateNamespaces": "gpu-test, demo-* ,",
                      "slinkyDrain": "true", "slinkyNodeSelector": "slurm=worker",
                      "slinkyNamespace": "hpc", "gpuOperatorNamespace": "nvidia-system",
                      "cpuNodeSelector": "foo.acme.corp/cpu-node=true",
                      "gpuNodeSelector": "foo.acme.corp/gpu-node=true"},
}
chart_runs = []
for variant, overrides in VARIANTS.items():
    values = {**defaults(stack_params), **overrides}
    on = lambda k: str(values[k]) == "true"
    slinky = on("cordon") and on("drain") and on("slinkyDrain")
    cpu_sel = parse_selector(cpu_selector_raw(values))
    cpu_pod_sel = {"kubernetes.io/os": "linux", **cpu_sel}
    gpu_sel = parse_selector(gpu_selector_raw(values))
    gpu_pod_sel = {"kubernetes.io/os": "linux", **gpu_sel}
    parse_sel = parse_selector
    # The variants name the mode: auto needs a cluster, and is exercised against a fake kubectl below.
    mode = values["gpuDriverMode"]
    dra = mode == "dra"
    facts = discover_facts(mode, values)
    outputs = {}
    rendered = {}
    # discover first: its rendered ConfigMap stands in for what the Job publishes at runtime.
    for name in sorted(tasks, key=lambda n: (n != "discover", n)):
        task = tasks[name]
        where = f"task {name} ({variant})"
        t = render(task, values, where, outputs)
        if not t:
            continue
        kind = "app" if "app" in t else "argoCDApplication"
        ref = t[kind]["templateRef"]["name"]
        app = apps.get(ref)
        if not app:
            fail(f"{where}: templateRef {ref!r} is not in apps/")
            continue
        if (kind == "app") != (app["kind"] == "App"):
            fail(f"{where}: a {kind} task references {app['kind']} {ref}")
            continue
        passed = t[kind].get("parameters") or {}
        for p in passed:
            if p not in app["params"]:
                fail(f"{where}: passes {p!r}, which {ref} does not declare")
        for v, p in app["params"].items():
            if p.get("required") and "defaultValue" not in p and v not in passed:
                fail(f"{where}: {ref} requires {v!r}, which the task does not pass")

        if app["kind"] == "App":
            app_spec = app["doc"]["spec"]
            limit = short_duration(app_spec.get("timeout", ""), rel(app["path"])) or 0
            if "timeoutSeconds" in passed:
                # The gate Job's own deadline, below the App timeout, is the reporting path.
                limit = min(limit, int(passed["timeoutSeconds"]) + 60)
            if task_seconds.get(name) is not None and task_seconds[name] <= limit:
                fail(f"{where}: task timeout {task['timeout']} must exceed the App deadline it waits on ({limit}s)")
            docs = render_app(app, passed, name, where)
            if docs is None:
                continue
            if ref == SLINKY:
                rendered[name] = {"ref": ref, "docs": docs}
                continue
            jobs = [d for d in docs if d.get("kind") == "Job"]
            if len(jobs) != 1:
                fail(f"{where}: expected exactly one Job, whose completion holds the task; found {len(jobs)}")
                continue
            job = jobs[0]
            pod = job["spec"]["template"]["spec"]
            if pod.get("restartPolicy") != "Never" or "ttlSecondsAfterFinished" in job["spec"]:
                fail(f"{where}: the Job must not restart in place or expire")
            rendered[name] = {"ref": ref, "docs": docs, "pod": pod,
                              "env": {e["name"]: e.get("value") for e in pod["containers"][0].get("env", [])}}
            if ref in (GATE, DISCOVER):
                if pod["containers"][0]["image"] != PLATFORM_IMAGE:
                    fail(f"{where}: the Job does not run the Platform image")
                if pod.get("nodeSelector") != cpu_sel:
                    fail(f"{where}: Job nodeSelector {pod.get('nodeSelector')} is not the CPU node selector {cpu_sel}")
        else:
            spec_r = render(app["doc"]["spec"]["template"], {**defaults(app["params"]), **passed}, f"{ref} for {where}")
            if not spec_r:
                continue
            try:
                hv = yaml.safe_load(spec_r["spec"]["source"].get("helm", {}).get("values") or "") or {}
            except yaml.YAMLError as e:
                fail(f"{ref} for {where}: rendered Helm values are not YAML: {e}")
                continue
            rendered[name] = {"ref": ref, "values": hv, "syncPolicy": spec_r["spec"].get("syncPolicy") or {}}
            if name == "nvsentinel":
                chart_runs.append((variant, spec_r["spec"]["source"], hv))

        if name == "discover" and name in rendered:
            cms = [d for d in rendered[name]["docs"] if d.get("kind") == "ConfigMap"]
            for out in declared_outputs[name].values():
                fr = out["fromResource"]
                key = fr["jsonPath"][len("{.data."):-1]
                if fr["namespace"] != app["doc"]["spec"]["defaultNamespace"] or fr["name"] not in [c["metadata"]["name"] for c in cms]:
                    fail(f"{where}: output {out['name']} reads {fr['namespace']}/{fr['name']}, which discover does not create")
                if key not in DISCOVER_KEYS:
                    fail(f"{where}: output {out['name']} reads key {key!r}, which the discover Job never writes")
                if key in (cms[0].get("data") or {} if cms else {}):
                    fail(f"{where}: key {key!r} is declared by the release, so a Helm upgrade would reset what the Job wrote")
            env = rendered[name]["env"]
            if dict(p.strip().split("=", 1) for p in env.get("CPU_NODE_SELECTOR", "").split(",") if p.strip()) != cpu_sel \
                    or env.get("PINNED_VOLUME_NAMESPACE") != "nvsentinel":
                fail(f"{where}: the guard gets CPU_NODE_SELECTOR={env.get('CPU_NODE_SELECTOR')!r} PINNED_VOLUME_NAMESPACE={env.get('PINNED_VOLUME_NAMESPACE')!r}; expected the CPU node selector and nvsentinel")
            if parse_sel(env.get("GPU_NODE_SELECTOR")) != gpu_sel:
                fail(f"{where}: the selector check gets GPU_NODE_SELECTOR={env.get('GPU_NODE_SELECTOR')!r}; expected the GPU node selector {gpu_sel}")
            if env.get("REQUIRE_CERT_MANAGER") != str(values["cordon"]):
                fail(f"{where}: REQUIRE_CERT_MANAGER={env.get('REQUIRE_CERT_MANAGER')!r} with cordon={values['cordon']}; cordon is what needs cert-manager")
            if env.get("REQUESTED_MODE") != values["gpuDriverMode"]:
                fail(f"{where}: the Job does not receive gpuDriverMode={values['gpuDriverMode']}")
            got = (env.get("GPU_OPERATOR_NAMESPACE"), env.get("DCGM_HOST"), env.get("DCGM_PORT"))
            if got != (str(values["gpuOperatorNamespace"]), str(values.get("dcgmHost") or ""), str(values["dcgmPort"])):
                fail(f"{where}: the Job gets namespace, host and port {got}, not gpuOperatorNamespace, dcgmHost and dcgmPort")
            outputs = {"discover": {o["name"]: facts.get(o["fromResource"]["jsonPath"][len("{.data."):-1], "")
                                    for o in declared_outputs[name].values()}}

    # Behavior the parameters promise.
    for gate in ("gpuready", "dcgmready"):
        if gate not in rendered:
            continue
        env = rendered[gate]["env"]
        expected = ("1", facts["capacitySource"], facts["capacityResource"])
        if (env.get("CAPACITY_MIN"), env.get("CAPACITY_SOURCE"), env.get("CAPACITY_RESOURCE")) != expected:
            fail(f"task {gate} ({variant}): the gate does not wait for one {expected[2]} from {expected[1]}")
        rules = next(d for d in rendered[gate]["docs"] if d.get("kind") == "ClusterRole")["rules"]
        if dra and not any("resourceslices" in r.get("resources", []) for r in rules):
            fail(f"task {gate} ({variant}): counts ResourceSlices without RBAC to list them")
        if parse_sel(env.get("CAPACITY_NODE_SELECTOR")) != gpu_sel:
            fail(f"task {gate} ({variant}): capacity is counted on {env.get('CAPACITY_NODE_SELECTOR')!r}, not the GPU node selector {gpu_sel}")
        if env.get("CONTRACT_NAME"):
            fail(f"task {gate} ({variant}): publishes a contract; this Stack's values come from discover")
    if "gpuready" in rendered and rendered["gpuready"]["env"].get("WAIT_RESOURCE"):
        fail(f"task gpuready ({variant}): waits for {rendered['gpuready']['env']['WAIT_RESOURCE']}; it only counts GPUs")
    if "dcgmready" in rendered:
        env = rendered["dcgmready"]["env"]
        if values.get("dcgmHost"):
            if env.get("WAIT_RESOURCE"):
                fail(f"task dcgmready ({variant}): waits for {env['WAIT_RESOURCE']} although dcgmHost names another DCGM")
        else:
            expected = (f"daemonset/{facts['dcgmDaemonSet']}", "rollout", str(values["gpuOperatorNamespace"]))
            if (env.get("WAIT_RESOURCE"), env.get("WAIT_CONDITION"), env.get("WAIT_NAMESPACE")) != expected:
                fail(f"task dcgmready ({variant}): must wait for {expected[0]} to roll out in {expected[2]}, which covers any number of GPU workers")
    if "nvsentinel" in rendered:
        hv = rendered["nvsentinel"]["values"]
        svc = hv["global"]["dcgm"]["service"]
        if (svc["endpoint"], str(svc["port"])) != (facts["dcgmHost"], facts["dcgmPort"]):
            fail(f"task nvsentinel ({variant}): DCGM endpoint {svc['endpoint']}:{svc['port']} is not what discover resolved, {facts['dcgmHost']}:{facts['dcgmPort']}")
        if str(hv["labeler"]["assumeDriverInstalled"]).lower() != str(values["driverPreinstalled"]):
            fail(f"task nvsentinel ({variant}): labeler.assumeDriverInstalled disagrees with driverPreinstalled")
        # The chart fails on anything but a YAML boolean here.
        if hv["global"].get("gpuDraEnabled") is not dra:
            fail(f"task nvsentinel ({variant}): global.gpuDraEnabled={hv['global'].get('gpuDraEnabled')!r} for mode {mode}")
        if dra and ((((hv.get("janitor") or {}).get("config") or {}).get("controllers") or {}).get("gpuReset") or {}).get("resetJob", {}).get("runtimeClassName") != "":
            fail(f"task nvsentinel ({variant}): janitor's reset Job must not use the nvidia RuntimeClass in DRA mode")
        label = rendered["nvsentinel"]["syncPolicy"].get("managedNamespaceMetadata", {}).get("labels", {}).get("resource.kubernetes.io/admin-access")
        if label != ("true" if dra else "false"):
            fail(f"task nvsentinel ({variant}): namespace label resource.kubernetes.io/admin-access={label!r} for mode {mode}; DRA admin-access claims need 'true'")
        # Quarantine (with the MongoDB store it needs) follows cordon, the drainer needs
        # quarantine too, and nothing that remediates or reboots is ever on.
        g = hv["global"]
        cordon = on("cordon")
        remediate = cordon and on("drain") and values["remediation"] in ("reboot", "gpu-reset")
        gpu_reset = remediate and values["remediation"] == "gpu-reset"
        for component, want in (("faultQuarantine", cordon), ("mongodbStore", cordon),
                                ("nodeDrainer", cordon and on("drain")),
                                ("faultRemediation", remediate), ("janitor", remediate), ("janitorProvider", remediate),
                                ("healthEventsAnalyzer", False), ("preflight", False)):
            if (g.get(component) or {}).get("enabled", False) is not want:
                fail(f"task nvsentinel ({variant}): global.{component}.enabled must be {want} with cordon={values['cordon']} drain={values['drain']} remediation={values['remediation']}")
        # Remediation: the generic provider reboots; gpu-reset adds a partial drain and maps
        # COMPONENT_RESET to GPUReset; without it the chart's reboot mapping stays untouched.
        provider = ((hv.get("janitor-provider") or {}).get("csp") or {}).get("provider")
        if (provider == "generic") is not remediate:
            fail(f"task nvsentinel ({variant}): janitor-provider.csp.provider={provider!r}; it must be generic exactly when remediation is on")
        if bool(g.get("partialDrainEnabled")) is not gpu_reset:
            fail(f"task nvsentinel ({variant}): global.partialDrainEnabled={g.get('partialDrainEnabled')!r} with remediation {values['remediation']}")
        maint = (hv.get("fault-remediation") or {}).get("maintenance") or {}
        if gpu_reset:
            action = (maint.get("actions") or {}).get("COMPONENT_RESET") or {}
            if (action.get("kind"), action.get("templateFileName"), action.get("impactedEntityScope")) != ("GPUReset", "gpureset-template.yaml", "GPU_UUID") \
                    or "restart" not in (action.get("supersedingEquivalenceGroups") or []):
                fail(f"task nvsentinel ({variant}): COMPONENT_RESET must map to a per-GPU GPUReset that supersedes restart, got {action}")
            tmpl = (maint.get("templates") or {}).get("gpureset-template.yaml", "")
            if "{{ .ImpactedEntityScopeValue }}" not in tmpl or "{{ .HealthEvent.NodeName }}" not in tmpl:
                fail(f"task nvsentinel ({variant}): the GPUReset template lost its Go template; fault-remediation must render it, not the Platform")
            else:
                try:
                    if (yaml.safe_load(re.sub(r"\{\{[^}]*\}\}", "x", tmpl)) or {}).get("kind") != "GPUReset":
                        fail(f"task nvsentinel ({variant}): the GPUReset template is not a GPUReset manifest")
                except yaml.YAMLError as e:
                    fail(f"task nvsentinel ({variant}): the GPUReset template is not YAML: {e}")
        elif maint:
            fail(f"task nvsentinel ({variant}): overrides fault-remediation.maintenance {maint} without gpu-reset")
        reset_job = (((((hv.get("janitor") or {}).get("config") or {}).get("controllers") or {}).get("gpuReset") or {}).get("resetJob") or {})
        want_root = "/" if on("driverPreinstalled") else "/run/nvidia/driver"
        if reset_job.get("hostDriverRootPath") != want_root:
            fail(f"task nvsentinel ({variant}): janitor reset Job hostDriverRootPath={reset_job.get('hostDriverRootPath')!r}, expected {want_root!r} with driverPreinstalled={values['driverPreinstalled']}")
        if g.get("dryRun") is not on("dryRun"):
            fail(f"task nvsentinel ({variant}): global.dryRun={g.get('dryRun')!r} with dryRun={values['dryRun']}")
        mongo = hv["mongodb-store"]["mongodb"]
        replicas = int(values["mongodbReplicas"])
        # Empty must leave the key out, so an existing StatefulSet's volume claims stay as they are.
        persistence = mongo.get("persistence") or {}
        want_sc = values.get("mongodbStorageClass") or None
        if persistence.get("storageClass") != want_sc or (not want_sc and "storageClass" in persistence):
            fail(f"task nvsentinel ({variant}): mongodb persistence {persistence}, expected storageClass {want_sc!r}")
        if mongo.get("replicaCount") != replicas or mongo["tls"]["replicaset"]["existingSecrets"] != [f"mongo-server-cert-{i}" for i in range(replicas)]:
            fail(f"task nvsentinel ({variant}): MongoDB needs {replicas} replicas with one server certificate each")
        for path in (("global", "systemNodeSelector"), ("mongodb-store", "mongodb", "nodeSelector"),
                     ("nodeConditionCleanup", "nodeSelector")):
            got = hv
            for k in path:
                got = (got or {}).get(k)
            if got != cpu_pod_sel:
                fail(f"task nvsentinel ({variant}): {'.'.join(path)} is {got}, expected the CPU node selector {cpu_pod_sel}")
        if hv["global"].get("nodeSelector") != gpu_pod_sel:
            fail(f"task nvsentinel ({variant}): global.nodeSelector is {hv['global'].get('nodeSelector')}, expected the GPU node selector {gpu_pod_sel}")
        terms = hv["platformConnector"]["affinity"]["nodeAffinity"]["requiredDuringSchedulingIgnoredDuringExecution"]["nodeSelectorTerms"]
        exprs = {e["key"]: (e["operator"], e["values"]) for t in terms for e in t.get("matchExpressions") or []}
        if len(terms) != 1 or exprs != {k: ("In", [v]) for k, v in gpu_sel.items()}:
            fail(f"task nvsentinel ({variant}): platformConnector affinity {terms} does not require exactly the GPU node selector {gpu_sel}")
        if cordon:
            cb = (hv.get("fault-quarantine") or {}).get("circuitBreaker") or {}
            want = {"enabled": on("circuitBreakerEnabled"), "duration": values["circuitBreakerDuration"],
                    "percentage": int(values["circuitBreakerPercentage"]),
                    "maxNodes": int(values["circuitBreakerMaxNodes"])}
            if {k: cb.get(k) for k in want} != want:
                fail(f"task nvsentinel ({variant}): fault-quarantine.circuitBreaker is {cb}, expected {want}")

    # Slinky drain: the drainer renders only when NVSentinel hands nodes to it, and both sides name
    # the same ConfigMap, CRD and completion condition.
    if "slinky-drainer" in rendered:
        docs = {(d["kind"], d["metadata"]["name"]): d for d in rendered["slinky-drainer"]["docs"]}
        where = f"task slinky-drainer ({variant})"
        if not slinky and docs:
            fail(f"{where}: renders {sorted(docs)} with Slinky drain off; it must render nothing")
        if slinky:
            crd = docs.get(("CustomResourceDefinition", "drainrequests.nvsentinel.nvidia.com"))
            cm = docs.get(("ConfigMap", "slinky-drain-template"))
            dep = docs.get(("Deployment", "slinky-drainer"))
            if not (crd and cm and dep):
                fail(f"{where}: expected the DrainRequest CRD, the slinky-drain-template ConfigMap and the slinky-drainer Deployment")
            else:
                if "{{ .HealthEvent.NodeName }}" not in (cm.get("data") or {}).get("drain-template.yaml", ""):
                    fail(f"{where}: the drain template lost its Go template; node-drainer must render it, not the App")
                c = dep["spec"]["template"]["spec"]["containers"][0]
                if c["image"] != f"ghcr.io/nvidia/nvsentinel/slinky-drainer:{values['version']}":
                    fail(f"{where}: image {c['image']} does not follow version")
                if f"--slinky-namespace={values['slinkyNamespace']}" not in c.get("args", []):
                    fail(f"{where}: does not watch slinkyNamespace={values['slinkyNamespace']}")
                if dep["spec"]["template"]["spec"].get("nodeSelector") != cpu_pod_sel:
                    fail(f"{where}: the controller is not on the CPU services pool")
                # The controller reads and deletes the Slurm worker pods, through a Role in their
                # namespace. In the wrong namespace, or short a verb, a drain never completes.
                role = docs.get(("Role", "slinky-drainer-pods")) or {}
                binding = docs.get(("RoleBinding", "slinky-drainer-pods")) or {}
                account = dep["spec"]["template"]["spec"].get("serviceAccountName")
                pod_verbs = {v for r in role.get("rules") or [] if "pods" in r.get("resources", []) and "" in r.get("apiGroups", [])
                             for v in r.get("verbs", [])}
                if (role.get("metadata") or {}).get("namespace") != values["slinkyNamespace"] or not {"get", "list", "watch", "delete"} <= pod_verbs:
                    fail(f"{where}: Role slinky-drainer-pods must grant get, list, watch and delete on pods in slinkyNamespace={values['slinkyNamespace']}; found namespace {(role.get('metadata') or {}).get('namespace')!r} and verbs {sorted(pod_verbs)}")
                subjects = [(x.get("kind"), x.get("name"), x.get("namespace")) for x in binding.get("subjects") or []]
                if (binding.get("metadata") or {}).get("namespace") != values["slinkyNamespace"] \
                        or (binding.get("roleRef") or {}).get("name") != "slinky-drainer-pods" \
                        or ("ServiceAccount", account, "nvsentinel") not in subjects:
                    fail(f"{where}: RoleBinding slinky-drainer-pods must bind the Role to the controller's ServiceAccount {account!r} in slinkyNamespace; found {subjects}")
    if "nvsentinel" in rendered:
        nd = rendered["nvsentinel"]["values"].get("node-drainer") or {}
        cd = nd.get("customDrain") or {}
        where = f"task nvsentinel ({variant})"
        # Drain settings: the listed namespaces Immediate, then "*" in the chosen mode. The chart
        # writes the list as TOML, so it must render as a list of name/mode pairs.
        if on("cordon") and on("drain"):
            immediate = [n.strip() for n in str(values.get("drainImmediateNamespaces") or "").split(",") if n.strip()]
            want_ns = [{"name": n, "mode": "Immediate"} for n in immediate] + [{"name": "*", "mode": values["drainMode"]}]
            if nd.get("userNamespaces") != want_ns:
                fail(f"{where}: node-drainer.userNamespaces {nd.get('userNamespaces')}, expected {want_ns}")
            if nd.get("deleteAfterTimeoutMinutes") != int(values["drainTimeoutMinutes"]):
                fail(f"{where}: node-drainer.deleteAfterTimeoutMinutes {nd.get('deleteAfterTimeoutMinutes')!r}, expected {values['drainTimeoutMinutes']}")
            if nd.get("podDrainPolicies"):
                fail(f"{where}: node-drainer.podDrainPolicies is set; the chart rejects it next to userNamespaces")
        elif nd:
            fail(f"{where}: renders node-drainer values {sorted(nd)} with the drainer off")
        if bool(cd.get("enabled")) is not slinky:
            fail(f"{where}: node-drainer.customDrain.enabled={cd.get('enabled')!r} with Slinky drain {'on' if slinky else 'off'}")
        if slinky:
            if cd.get("nodeSelector") != values["slinkyNodeSelector"] or not cd.get("nodeSelector"):
                fail(f"{where}: customDrain.nodeSelector {cd.get('nodeSelector')!r} must be slinkyNodeSelector and never empty")
            docs = {(d["kind"], d["metadata"]["name"]): d for d in rendered.get("slinky-drainer", {}).get("docs", [])}
            crd = docs.get(("CustomResourceDefinition", "drainrequests.nvsentinel.nvidia.com"), {}).get("spec", {})
            want = {"templateConfigMapName": "slinky-drain-template", "templateFileName": "drain-template.yaml",
                    "apiGroup": crd.get("group"), "kind": crd.get("names", {}).get("kind"),
                    "resource": crd.get("names", {}).get("plural"),
                    "version": next((v["name"] for v in crd.get("versions", []) if v.get("served")), None),
                    "statusConditionType": "DrainComplete", "statusConditionStatus": "True"}
            got = {k: cd.get(k) for k in want}
            if got != want:
                fail(f"{where}: customDrain {got} does not match what the slinky-drainer App deploys {want}")

# --- CPU node selector: Job names and the discover guard -----------------------------------------
# A Job spec is immutable, so a changed selector must name a new Job, or the upgrade fails.
for ref in (GATE, DISCOVER):
    names = []
    for sel in ("workload.example.com/pool=cpu-services", "foo.acme.corp/cpu-node=true"):
        docs = render_app(apps[ref], {"cpuNodeSelector": sel, "pinnedVolumeNamespace": "nvsentinel"}, "hash", f"{ref} hash")
        names.append([d["metadata"]["name"] for d in docs or [] if d.get("kind") == "Job"])
    if names[0] == names[1]:
        fail(f"apps/: {ref} keeps Job name {names[0]} when cpuNodeSelector changes; Helm cannot patch a Job's pod template")
names = []
for sel in ("workload.example.com/pool=gpu-compute", "foo.acme.corp/gpu-node=true"):
    docs = render_app(apps[GATE], {"capacityNodeSelector": sel}, "hash", f"{GATE} hash")
    names.append([d["metadata"]["name"] for d in docs or [] if d.get("kind") == "Job"])
if names[0] == names[1]:
    fail(f"apps/: {GATE} keeps Job name {names[0]} when capacityNodeSelector changes; Helm cannot patch a Job's pod template")
names = []
for ns in ("gpu-operator", "nvidia-system"):
    docs = render_app(apps[DISCOVER], {"gpuOperatorNamespace": ns}, "hash", f"{DISCOVER} hash")
    names.append([d["metadata"]["name"] for d in docs or [] if d.get("kind") == "Job"])
if names[0] == names[1]:
    fail(f"apps/: {DISCOVER} keeps Job name {names[0]} when gpuOperatorNamespace changes; it would not decide again")

# The values above are checked against what this file expects, not against the chart. Render the
# NVSentinel chart itself with each variant's values, so a values key a chart version renamed or
# rejects fails here and not when Argo CD syncs.
charts_rendered = 0
if not offline and chart_runs:
    source = chart_runs[0][1]
    chart_dir = work / "upstream-chart"
    r = subprocess.run(["helm", "pull", f"{source['repoURL']}/{source['chart']}" if not source["repoURL"].endswith(source["chart"]) else source["repoURL"],
                        "--version", str(source["targetRevision"]), "--untar", "--untardir", str(chart_dir)], capture_output=True, text=True)
    if r.returncode != 0:
        fail(f"apps/{PREFIX}-nvsentinel: could not pull {source['repoURL']} {source['targetRevision']} (pass --offline to skip): {r.stderr.strip()[-300:]}")
    else:
        for variant, source, hv in chart_runs:
            vf = work / f"chart-values-{variant}.yaml"
            vf.write_text(yaml.safe_dump(hv))
            r = subprocess.run(["helm", "template", source["helm"]["releaseName"], str(chart_dir / source["chart"]),
                                "--namespace", "nvsentinel", "-f", str(vf)], capture_output=True, text=True)
            if r.returncode != 0:
                fail(f"task nvsentinel ({variant}): the NVSentinel chart {source['targetRevision']} does not render with these values: {r.stderr.strip()[-400:]}")
            else:
                charts_rendered += 1

# Run the discover script against a fake kubectl. For the GPU Operator: FAKE_CP ClusterPolicies and
# FAKE_GC GPUClusters, FAKE_WARN as a warning on stderr of a successful list, FAKE_ERR as the error
# of a failed one, and FAKE_DCGM as the ClusterPolicy's spec.dcgm.enabled. FAKE_CERT_MANAGER is
# yes, no, or an error message. For the volume guard: one PVC in nvsentinel when FAKE_PV is set,
# its PV with the node affinity FAKE_TERMS, and a node only for the exact selector FAKE_MATCH. The
# patch is written to FAKE_PATCH, which stands in for the ConfigMap.
fake = work / "fakebin"
fake.mkdir()
(fake / "kubectl").write_text(r"""#!/bin/sh
list() {
  if [ -n "${FAKE_ERR:-}" ]; then echo "$FAKE_ERR" >&2; exit 1; fi
  if [ -n "${FAKE_WARN:-}" ]; then echo "$FAKE_WARN" >&2; fi
  i=0; while [ "$i" -lt "${2:-0}" ]; do echo "$1/object-$i"; i=$((i+1)); done
  exit 0
}
case "$*" in
  # First: the patch names other kinds too.
  *"patch configmap"*)
    while [ $# -gt 1 ]; do shift; done
    printf '%s' "$1" > "${FAKE_PATCH:-/dev/null}"; exit 0 ;;
  *certificates.cert-manager.io*)
    case "${FAKE_CERT_MANAGER:-yes}" in
      yes) echo customresourcedefinition.apiextensions.k8s.io/certificates.cert-manager.io; exit 0 ;;
      no) echo 'Error from server (NotFound): customresourcedefinitions.apiextensions.k8s.io "certificates.cert-manager.io" not found' >&2; exit 1 ;;
      *) echo "$FAKE_CERT_MANAGER" >&2; exit 1 ;;
    esac ;;
  *clusterpolicies*jsonpath*) printf '%s' "${FAKE_DCGM:-true}"; exit 0 ;;
  *clusterpolicies*) list clusterpolicy "${FAKE_CP:-0}" ;;
  *gpuclusters*) list gpucluster "${FAKE_GC:-0}" ;;
  *"get pvc"*) [ -n "$FAKE_PV" ] && echo "$FAKE_PV"; exit 0 ;;
  *"get pv "*) echo "$FAKE_TERMS"; exit 0 ;;
  *"get nodes"*)
    while [ $# -gt 0 ]; do [ "$1" = -l ] && sel=$2; shift; done
    [ "$sel" = "$FAKE_MATCH" ] && echo node/node-a
    exit 0 ;;
esac
echo "fake kubectl: unexpected $*" >&2; exit 1
""")
(fake / "kubectl").chmod(0o755)
docs = render_app(apps[DISCOVER], {"cpuNodeSelector": "x=y", "pinnedVolumeNamespace": "nvsentinel"}, "guard", "discover guard")
script = next(d for d in docs if d.get("kind") == "Job")["spec"]["template"]["spec"]["containers"][0]["args"][0]
HOST = "kubernetes.io/hostname In node-a|"
POOL = "workload.example.com/pool=cpu-services"
GPU_POOL = "workload.example.com/pool=gpu-compute"
patch_file = work / "discover-patch.json"


def run_discover(**env):
    base = {"PATH": f"{fake}:/usr/bin:/bin", "HOME": str(work), "REQUESTED_MODE": "device-plugin",
            "CONTRACT_NAME": "nvsentinel-discovery", "CONTRACT_NAMESPACE": "nvsentinel-stack",
            "GPU_OPERATOR_NAMESPACE": "gpu-operator", "DCGM_HOST": "", "DCGM_PORT": "5555",
            "REQUIRE_CERT_MANAGER": "false", "CPU_NODE_SELECTOR": POOL, "GPU_NODE_SELECTOR": GPU_POOL,
            "PINNED_VOLUME_NAMESPACE": "nvsentinel", "FAKE_PV": "", "FAKE_TERMS": "", "FAKE_MATCH": "",
            "FAKE_PATCH": str(patch_file)}
    patch_file.write_text("")
    r = subprocess.run(["sh", "-c", script], env={**base, **env}, capture_output=True, text=True)
    text = patch_file.read_text()
    try:
        data = json.loads(text)["data"] if text else {}
    except (ValueError, KeyError):
        fail(f"apps/{DISCOVER}: the patch it sends is not a JSON merge patch with data: {text[:200]!r}")
        data = {}
    return r.returncode, r.stdout + r.stderr, data


def expect(case, env, ok, says, want=None):
    """Run discover; on success `want` is what the patch must hold, and a failure must publish nothing."""
    code, out, data = run_discover(**env)
    where = f"apps/{DISCOVER}, {case}"
    if (code == 0) != ok or says not in out:
        fail(f"{where}: exit {code}, expected {'success' if ok else 'failure'} saying {says!r}: {out.strip()[-400:]}")
    elif not ok and data:
        fail(f"{where}: failed, but still published {data}")
    elif ok and {k: data.get(k) for k in want or {}} != (want or {}):
        fail(f"{where}: published {({k: data.get(k) for k in want})}, expected {want}")


# The node selectors: checked for key=value form, published as given, and the CPU one checked
# against the volumes it must still reach. A term the guard cannot turn into a label selector
# (Gt, Lt) makes the volume's reach unknown, which must not be reported as stranded.
for case, sel, pv, terms, match, ok, says in [
    ("pinned volume still reachable", POOL, "pv-1", HOST, f"kubernetes.io/hostname in (node-a),{POOL}", True, "reaches every pinned volume"),
    ("selector strands the volume", "foo.acme.corp/cpu-node=true", "pv-1", HOST, f"kubernetes.io/hostname in (node-a),{POOL}", False, "can reach PersistentVolume pv-1"),
    ("zonal volume, node in zone", "foo.acme.corp/cpu-node=true", "pv-1", "topology.kubernetes.io/zone In europe-west4-b|",
     "topology.kubernetes.io/zone in (europe-west4-b),foo.acme.corp/cpu-node=true", True, "reaches every pinned volume"),
    ("volume with a term the guard cannot evaluate", "foo.acme.corp/cpu-node=true", "pv-1", "some.key Gt 3|", "", True, "reaches every pinned volume"),
    ("no volumes yet", "foo.acme.corp/cpu-node=true", "", "", "", True, "reaches every pinned volume"),
    ("malformed selector", "foo", "", "", "", False, "is not a key=value label"),
]:
    expect(f"guard, {case}", {"CPU_NODE_SELECTOR": sel, "FAKE_PV": pv, "FAKE_TERMS": terms, "FAKE_MATCH": match}, ok, says,
           {"cpuNodeSelector": sel, "gpuNodeSelector": GPU_POOL})
expect("bare GPU key", {"GPU_NODE_SELECTOR": "tier=gpu,foo"}, False, "GPU node selector 'tier=gpu,foo': 'foo' is not a key=value label")

# Mode detection and the DCGM endpoint, read from the patch: every DISCOVER_FACTS key, so swapped
# names for the two modes fail here.
expect("auto, ClusterPolicy", {"REQUESTED_MODE": "auto", "FAKE_CP": "1"}, True, "existing ClusterPolicy",
       {**DISCOVER_FACTS["device-plugin"], "dcgmHost": "nvidia-dcgm.gpu-operator.svc", "dcgmPort": "5555",
        "dcgmNamespace": "gpu-operator", "dcgmWait": "true"})
expect("auto, GPUCluster", {"REQUESTED_MODE": "auto", "FAKE_GC": "1", "GPU_OPERATOR_NAMESPACE": "nvidia-system", "DCGM_PORT": "5556"},
       True, "existing GPUCluster",
       {**DISCOVER_FACTS["dra"], "dcgmHost": "nvidia-dcgm-dra.nvidia-system.svc", "dcgmPort": "5556",
        "dcgmNamespace": "nvidia-system", "dcgmWait": "true"})
expect("auto, no GPU Operator", {"REQUESTED_MODE": "auto"}, False, "there is no GPU Operator to follow")
expect("auto, both CRs", {"REQUESTED_MODE": "auto", "FAKE_CP": "1", "FAKE_GC": "1"}, False, "both a ClusterPolicy and a GPUCluster exist")
expect("explicit dra, no GPU Operator yet", {"REQUESTED_MODE": "dra"}, True, "gpuDriverMode parameter",
       {**DISCOVER_FACTS["dra"], "dcgmHost": "nvidia-dcgm-dra.gpu-operator.svc"})
expect("explicit device-plugin, no GPU Operator yet", {"REQUESTED_MODE": "device-plugin"}, True, "gpuDriverMode parameter",
       {**DISCOVER_FACTS["device-plugin"], "dcgmHost": "nvidia-dcgm.gpu-operator.svc"})
expect("explicit mode against the other CR", {"REQUESTED_MODE": "dra", "FAKE_CP": "1"}, True, "WARNING: gpuDriverMode is dra", {"mode": "dra"})
expect("dcgmHost override", {"REQUESTED_MODE": "auto", "FAKE_CP": "1", "DCGM_HOST": "dcgm.monitoring.svc"}, True, "comes from the dcgmHost parameter",
       {"dcgmHost": "dcgm.monitoring.svc", "dcgmWait": "false"})
expect("unknown mode", {"REQUESTED_MODE": "cdi"}, False, "gpuDriverMode must be auto, device-plugin or dra")

# count(): a CRD that is not installed is zero objects, a warning on a successful list is not an
# object, and any other error fails rather than being read as "none".
expect("CRDs not installed", {"REQUESTED_MODE": "device-plugin", "FAKE_ERR": "error: the server doesn't have a resource type \"gpuclusters\""},
       True, "found 0 ClusterPolicy and 0 GPUCluster", {"mode": "device-plugin"})
expect("auto, CRDs not installed", {"REQUESTED_MODE": "auto", "FAKE_ERR": "error: the server doesn't have a resource type \"gpuclusters\""},
       False, "there is no GPU Operator to follow")
expect("auto, GPUCluster and a warning on stderr", {"REQUESTED_MODE": "auto", "FAKE_GC": "1", "FAKE_WARN": "Warning: something is deprecated"},
       True, "found 0 ClusterPolicy and 1 GPUCluster", {"mode": "dra"})
expect("list forbidden", {"REQUESTED_MODE": "auto", "FAKE_ERR": "Error from server (Forbidden): clusterpolicies.nvidia.com is forbidden"},
       False, "could not list clusterpolicies.nvidia.com")

# cert-manager, which cordon needs: checked only when asked for, and a failed check is not read
# as "not installed".
expect("cert-manager required and installed", {"REQUIRE_CERT_MANAGER": "true"}, True, "cert-manager is installed", {"mode": "device-plugin"})
expect("cert-manager required and missing", {"REQUIRE_CERT_MANAGER": "true", "FAKE_CERT_MANAGER": "no"}, False,
       "Install cert-manager, or set cordon to false")
expect("cert-manager check forbidden", {"REQUIRE_CERT_MANAGER": "true", "FAKE_CERT_MANAGER": "Error from server (Forbidden): no"}, False,
       "could not check for cert-manager")
expect("cert-manager missing but not required", {"FAKE_CERT_MANAGER": "no"}, True, "gpuDriverMode=device-plugin", {"mode": "device-plugin"})

# The GPU Operator's Helm chart leaves standalone DCGM off. With a ClusterPolicy that says so and
# no dcgmHost, there is no Service to publish.
expect("DCGM disabled in the ClusterPolicy", {"REQUESTED_MODE": "auto", "FAKE_CP": "1", "FAKE_DCGM": "false"}, False,
       "has dcgm.enabled=false")
expect("DCGM disabled, dcgmHost set", {"REQUESTED_MODE": "auto", "FAKE_CP": "1", "FAKE_DCGM": "false", "DCGM_HOST": "dcgm.monitoring.svc"},
       True, "comes from the dcgmHost parameter", {"dcgmHost": "dcgm.monitoring.svc"})
expect("DCGM field not set", {"REQUESTED_MODE": "auto", "FAKE_CP": "1", "FAKE_DCGM": ""}, True, "existing ClusterPolicy", {"mode": "device-plugin"})
expect("no ClusterPolicy to read DCGM from", {"REQUESTED_MODE": "device-plugin", "FAKE_DCGM": "false"}, True, "gpuDriverMode=device-plugin",
       {"mode": "device-plugin"})

# --- Examples ------------------------------------------------------------------------------------
for path in sorted((root / "example").glob("*.yaml")):
    for doc in load(path):
        common(path, doc, "StackInstance")
        if (doc["spec"].get("templateRef") or {}).get("name") != STACK:
            fail(f"{rel(path)}: expected a StackInstance of {STACK}")
        if not doc["spec"].get("owner"):
            fail(f"{rel(path)}: spec.owner is required; every task fails with MissingOwner without it")
        if doc["spec"].get("prunePolicy") != "Prune":
            fail(f"{rel(path)}: set prunePolicy: Prune, or a task removed by a template update leaves its application running")
        for p, v in (doc["spec"].get("parameters") or {}).items():
            if p not in stack_params:
                fail(f"{rel(path)}: parameter {p!r} is not declared by the template")
            elif not isinstance(v, str):
                fail(f"{rel(path)}: parameter {p} must be a quoted string, found {type(v).__name__}")

if errors:
    for error in errors:
        print(f"FAIL {error}", file=sys.stderr)
    sys.exit(1)
print(f"ok manifests, {counter['render']} template renders, {counter['app']} App renders, "
      + ("upstream chart not rendered: --offline" if offline else f"upstream chart rendered {charts_rendered} times"))
CHECKS
