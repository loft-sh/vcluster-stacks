#!/usr/bin/env bash
# Static checks for the NVIDIA GPU Operator Stack: the invariants the Platform does not validate
# for you. Modeled on community-stacks/openclaw/test-manifests.sh.
#
#   ./test-manifests.sh
#
# Renders the graph the way the Platform would, for the default parameters and for a variant that
# takes the other branch of every conditional: StackTemplate tasks, then each referenced
# ArgoCDApplicationTemplate or App. App manifests are rendered as the Helm chart the Platform
# builds from them.
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

python3 - "$root" "$work" <<'CHECKS'
import copy
import json
import re
import subprocess
import sys
from pathlib import Path

import yaml

root, work = Path(sys.argv[1]), Path(sys.argv[2])
errors = []

PREFIX = "nvidia-gpu-operator"
PART_OF = "nvidia-gpu-operator-stack"
STACK = "nvidia-gpu-operator"
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
# Keys the gate patches into its contract, whatever contractData declares.
GATE_KEYS = {"ready", "observedCount", "verifiedAt", "resourceName"}
# What the discover Job writes for each resolved mode. The Job's script must contain every value,
# and the rendered graph is checked against these, standing in for the Job's runtime result.
DISCOVER_FACTS = {
    "device-plugin": {"mode": "device-plugin", "dcgmHost": "nvidia-dcgm.gpu-operator.svc",
                      "dcgmDaemonSet": "nvidia-dcgm", "operatorResource": "clusterpolicy/cluster-policy",
                      "operatorResources": "clusterpolicies", "capacitySource": "allocatable",
                      "capacityResource": "nvidia.com/gpu"},
    "dra": {"mode": "dra", "dcgmHost": "nvidia-dcgm-dra.gpu-operator.svc",
            "dcgmDaemonSet": "nvidia-dcgm-dra", "operatorResource": "gpucluster/gpu-cluster",
            "operatorResources": "gpuclusters", "capacitySource": "resourceslices",
            "capacityResource": "gpu.nvidia.com"},
}
DISCOVER_KEYS = set(DISCOVER_FACTS["dra"]) | {"source", "discoveredAt"}


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


def cpu_selector(values):
    """The CPU node selector every CPU workload must carry: cpuNodeSelector, or the pool label."""
    raw = str(values.get("cpuNodeSelector") or "") or f"workload.example.com/pool={values['cpuNodePool']}"
    return dict(p.strip().split("=", 1) for p in raw.split(",") if p.strip())


def gpu_selector(values):
    """The GPU node selector every GPU workload must carry: gpuNodeSelector, or the GPU pool label."""
    raw = str(values.get("gpuNodeSelector") or "") or "workload.example.com/pool=gpu-compute"
    return dict(p.strip().split("=", 1) for p in raw.split(",") if p.strip())


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


# --- NodeProfiles --------------------------------------------------------------------------------
profiles = {}
for doc in load(root / "nodeprofiles.yaml"):
    common(root / "nodeprofiles.yaml", doc, "NodeProfile")
    profiles[doc["metadata"]["name"]] = doc["spec"]
cpu_profile = profiles.get(f"{PREFIX}-cpu-services", {})
gpu_profile = profiles.get(f"{PREFIX}-gpu-compute", {})
if not cpu_profile or not gpu_profile:
    fail(f"nodeprofiles.yaml: expected {PREFIX}-cpu-services and {PREFIX}-gpu-compute")
if cpu_profile.get("taints"):
    fail("nodeprofiles.yaml: the CPU services profile must stay untainted; controllers and gates carry no toleration")
if (gpu_profile.get("nodeLabels") or {}).get("workload.example.com/pool") != "gpu-compute":
    fail("nodeprofiles.yaml: the GPU profile must label workload.example.com/pool=gpu-compute, the selector an empty gpuNodeSelector falls back to")
if not any(t.get("key") == "nvidia.com/gpu" and t.get("effect") == "NoSchedule" for t in gpu_profile.get("taints") or []):
    fail("nodeprofiles.yaml: the GPU profile must taint nvidia.com/gpu:NoSchedule; every GPU toleration matches it")

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
        if key == "dcgmHost":
            value = value.split(".")[0]
        if value not in discover_manifests:
            fail(f"apps/: {DISCOVER} never writes {key}={value!r} for {mode}; the test's DISCOVER_FACTS and the Job disagree")

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
# from the parameter, or `auto` would leave it on a different mode than the GPU Operator.
for name, task in tasks.items():
    if name != "discover" and any("gpuDriverMode" in ref for _, s in strings(task) for ref in VALUES_REF.findall(s)):
        fail(f"stacktemplate.yaml task {name}: reads .Values.gpuDriverMode; take the resolved mode from .Outputs.discover.mode")
    passed = (task.get("app") or task.get("argoCDApplication") or {}).get("parameters") or {}
    if name != "discover" and "gpuDriverMode" in passed and passed["gpuDriverMode"] != "{{ .Outputs.discover.mode }}":
        fail(f"stacktemplate.yaml task {name}: gpuDriverMode must be '{{{{ .Outputs.discover.mode }}}}'")
for name in ("gpu-operator", "gpu-smoke-test", "nvsentinel"):
    if name in tasks and "gpuDriverMode" not in ((tasks[name].get("app") or tasks[name].get("argoCDApplication") or {}).get("parameters") or {}):
        fail(f"stacktemplate.yaml task {name}: does not pass gpuDriverMode; it would stay on its default mode")

# node-drainer mounts the Slinky drain template and creates DrainRequests, so with Slinky drain on
# the ConfigMap and the CRD must exist before NVSentinel starts.
if "slinky-drainer" in tasks and "slinky-drainer" not in ancestors("nvsentinel"):
    fail("stacktemplate.yaml task nvsentinel: must depend on slinky-drainer; node-drainer mounts its drain template")

# A rollout wait on a DaemonSet that schedules no pods yet passes at once, so dcgmready must
# follow gpuready, which proves a GPU node is there.
if "dcgmready" in tasks and "gpuready" not in ancestors("dcgmready"):
    fail("stacktemplate.yaml task dcgmready: must depend on gpuready; before a GPU node joins, nvidia-dcgm has already rolled out")

# The shipped behavior: NVSentinel cordons on a GPU fault, for real, unless told otherwise.
if (str(defaults(stack_params).get("nvsentinelCordon")), str(defaults(stack_params).get("nvsentinelDryRun")),
        str(defaults(stack_params).get("nvsentinelDrain"))) != ("true", "false", "false"):
    fail("stacktemplate.yaml: NVSentinel must default to cordoning without draining (nvsentinelCordon=true, nvsentinelDryRun=false, nvsentinelDrain=false)")
if defaults(stack_params).get("cpuNodeSelector"):
    fail("stacktemplate.yaml: cpuNodeSelector must default to empty, so an upgrade keeps workload.example.com/pool=<cpuNodePool>")
if defaults(stack_params).get("gpuNodeSelector"):
    fail("stacktemplate.yaml: gpuNodeSelector must default to empty, so an upgrade keeps workload.example.com/pool=gpu-compute")
if str(defaults(stack_params).get("nvsentinelSlinkyDrain")) != "false":
    fail("stacktemplate.yaml: Slinky drain is opt-in; nvsentinelSlinkyDrain must default to false")

# Defaults that must agree across files: a stack default overrides the template's, so a drifted
# template default only bites when someone deploys the template on its own.
for stack_var, app, app_var in [
    ("gpuOperatorVersion", f"{PREFIX}-gpu-operator", "version"),
    ("nvsentinelVersion", f"{PREFIX}-nvsentinel", "version"),
    ("cpuNodePool", f"{PREFIX}-gpu-operator", "cpuNodePool"),
    ("cpuNodePool", f"{PREFIX}-nvsentinel", "cpuNodePool"),
    ("nvsentinelCordon", f"{PREFIX}-nvsentinel", "cordon"),
    ("nvsentinelDryRun", f"{PREFIX}-nvsentinel", "dryRun"),
    ("nvsentinelDrain", f"{PREFIX}-nvsentinel", "drain"),
    ("nvsentinelMongodbReplicas", f"{PREFIX}-nvsentinel", "mongodbReplicas"),
    ("nvsentinelCircuitBreakerPercentage", f"{PREFIX}-nvsentinel", "circuitBreakerPercentage"),
    ("nvsentinelCircuitBreakerMaxNodes", f"{PREFIX}-nvsentinel", "circuitBreakerMaxNodes"),
    ("nvsentinelSlinkyNodeSelector", f"{PREFIX}-nvsentinel", "slinkyNodeSelector"),
    ("nvsentinelVersion", SLINKY, "version"),
    ("nvsentinelSlinkyNamespace", SLINKY, "slinkyNamespace"),
    ("cpuNodePool", SLINKY, "cpuNodePool"),
]:
    a = defaults(stack_params).get(stack_var)
    b = defaults(apps.get(app, {}).get("params", {})).get(app_var)
    if str(a) != str(b):
        fail(f"default {stack_var}={a!r} in stacktemplate.yaml disagrees with {app_var}={b!r} in {app}")
if (cpu_profile.get("nodeLabels") or {}).get("workload.example.com/pool") != defaults(stack_params).get("cpuNodePool"):
    fail("nodeprofiles.yaml: the CPU services profile's pool label must equal the cpuNodePool default")

# --- Render the graph for two parameter sets -----------------------------------------------------
VARIANTS = {
    "defaults": {},
    "alternate": {"gpuDriverMode": "device-plugin", "driverPreinstalled": "true", "waitForClusterPolicy": "true", "minGPUs": "2",
                  "nvsentinelCordon": "false", "nvsentinelDryRun": "true", "nvsentinelDrain": "true",
                  "nvsentinelSlinkyDrain": "true",
                  "cpuNodeSelector": "foo.acme.corp/cpu-node=true, tier=services",
                  "gpuNodeSelector": "foo.acme.corp/gpu-node=true, tier=gpu"},
    "dra": {"gpuDriverMode": "dra"},
    "dra-alternate": {"gpuDriverMode": "dra", "driverPreinstalled": "true", "waitForClusterPolicy": "true", "minGPUs": "2",
                      "nvsentinelDryRun": "true", "nvsentinelMongodbReplicas": "3", "nvsentinelDrain": "true",
                      "nvsentinelCircuitBreakerPercentage": "100", "nvsentinelCircuitBreakerMaxNodes": "2",
                      "nvsentinelSlinkyDrain": "true", "nvsentinelSlinkyNodeSelector": "slurm=worker",
                      "nvsentinelSlinkyNamespace": "hpc",
                      "cpuNodeSelector": "foo.acme.corp/cpu-node=true",
                      "gpuNodeSelector": "foo.acme.corp/gpu-node=true"},
}
for variant, overrides in VARIANTS.items():
    values = {**defaults(stack_params), **overrides}
    on = lambda k: str(values[k]) == "true"
    slinky = on("nvsentinelCordon") and on("nvsentinelDrain") and on("nvsentinelSlinkyDrain")
    cpu_sel = cpu_selector(values)
    cpu_pod_sel = {"kubernetes.io/os": "linux", **cpu_sel}
    gpu_sel = gpu_selector(values)
    gpu_pod_sel = {"kubernetes.io/os": "linux", **gpu_sel}
    parse_sel = lambda raw: dict(p.strip().split("=", 1) for p in (raw or "").split(",") if p.strip())
    # auto on a cluster without a GPU Operator resolves to device-plugin.
    mode = {"auto": "device-plugin"}.get(values["gpuDriverMode"], values["gpuDriverMode"])
    dra = mode == "dra"
    facts = DISCOVER_FACTS[mode]
    contract = {}
    outputs = {}
    rendered = {}
    # discover, then gpuready: their rendered ConfigMaps stand in for what the Jobs publish at runtime.
    for name in sorted(tasks, key=lambda n: ({"discover": 0, "gpuready": 1}.get(n, 2), n)):
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
            if rendered[name]["env"].get("REQUESTED_MODE") != values["gpuDriverMode"]:
                fail(f"{where}: the Job does not receive gpuDriverMode={values['gpuDriverMode']}")
            outputs = {"discover": {o["name"]: facts.get(o["fromResource"]["jsonPath"][len("{.data."):-1], "")
                                    for o in declared_outputs[name].values()}}

        if name == "gpuready" and name in rendered:
            cms = [d for d in rendered[name]["docs"] if d.get("kind") == "ConfigMap"]
            contract = dict((cms[0].get("data") or {}) if cms else {})
            for out in declared_outputs[name].values():
                fr = out["fromResource"]
                key = fr["jsonPath"][len("{.data."):-1]
                if fr["namespace"] != app["doc"]["spec"]["defaultNamespace"] or fr["name"] not in [c["metadata"]["name"] for c in cms]:
                    fail(f"{where}: output {out['name']} reads {fr['namespace']}/{fr['name']}, which this gate does not create")
                if key not in contract and key not in GATE_KEYS:
                    fail(f"{where}: output {out['name']} reads key {key!r}, which the contract never holds")
            contract["observedCount"] = str(values["minGPUs"])
            outputs["gpuready"] = {o["name"]: str(contract.get(o["fromResource"]["jsonPath"][len("{.data."):-1], ""))
                                   for o in declared_outputs["gpuready"].values()}

    # Behavior the parameters promise.
    if "gpu-operator" in rendered:
        hv = rendered["gpu-operator"]["values"]
        for path in (("operator", "nodeSelector"), ("node-feature-discovery", "master", "nodeSelector"),
                     ("node-feature-discovery", "gc", "nodeSelector")):
            got = hv
            for k in path:
                got = (got or {}).get(k)
            if got != cpu_pod_sel:
                fail(f"task gpu-operator ({variant}): {'.'.join(path)} is {got}, expected the CPU node selector {cpu_pod_sel}")
        got = hv["node-feature-discovery"]["worker"].get("nodeSelector")
        if got != gpu_pod_sel:
            fail(f"task gpu-operator ({variant}): node-feature-discovery.worker.nodeSelector is {got}, expected the GPU node selector {gpu_pod_sel}")
        driver = hv["driver"]["enabled"]
        if driver is on("driverPreinstalled"):
            fail(f"task gpu-operator ({variant}): driver.enabled={driver} with driverPreinstalled={values['driverPreinstalled']}")
        # The chart's own validations: exactly one CR, and a GPUCluster takes its driver from an NVIDIADriver CR.
        if (hv["clusterPolicy"]["deployCR"], hv["gpuCluster"]["deployCR"]) != (not dra, dra):
            fail(f"task gpu-operator ({variant}): deploys ClusterPolicy={hv['clusterPolicy']['deployCR']} GPUCluster={hv['gpuCluster']['deployCR']} for mode {mode}")
        if dra and driver and hv["driver"]["nvidiaDriverCRD"]["enabled"] is not True:
            fail(f"task gpu-operator ({variant}): a GPUCluster with the driver enabled needs driver.nvidiaDriverCRD.enabled=true")
    if "gpuready" in rendered:
        env = rendered["gpuready"]["env"]
        if bool(env.get("WAIT_RESOURCE")) is not on("waitForClusterPolicy"):
            fail(f"task gpuready ({variant}): WAIT_RESOURCE={env.get('WAIT_RESOURCE')!r} with waitForClusterPolicy={values['waitForClusterPolicy']}")
        if env.get("WAIT_RESOURCE") and env["WAIT_RESOURCE"] != facts["operatorResource"]:
            fail(f"task gpuready ({variant}): waits for {env['WAIT_RESOURCE']}, but mode {mode} deploys {facts['operatorResource']}")
        expected = (str(values["minGPUs"]), facts["capacitySource"], facts["capacityResource"])
        if (env.get("CAPACITY_MIN"), env.get("CAPACITY_SOURCE"), env.get("CAPACITY_RESOURCE")) != expected:
            fail(f"task gpuready ({variant}): the gate does not wait for minGPUs={expected[0]} {expected[2]} from {expected[1]}")
        rules = next(d for d in rendered["gpuready"]["docs"] if d.get("kind") == "ClusterRole")["rules"]
        if dra and not any("resourceslices" in r.get("resources", []) for r in rules):
            fail(f"task gpuready ({variant}): counts ResourceSlices without RBAC to list them")
        if parse_sel(env.get("CAPACITY_NODE_SELECTOR")) != gpu_sel:
            fail(f"task gpuready ({variant}): capacity is counted on {env.get('CAPACITY_NODE_SELECTOR')!r}, not the GPU node selector {gpu_sel}")
        if parse_sel(contract.get("gpuNodeSelector")) != gpu_sel:
            fail(f"task gpuready ({variant}): contract gpuNodeSelector {contract.get('gpuNodeSelector')!r} is not the GPU node selector {gpu_sel}")
        want_pool = "" if values.get("gpuNodeSelector") else "gpu-compute"
        if contract.get("gpuPool") != want_pool:
            fail(f"task gpuready ({variant}): contract gpuPool {contract.get('gpuPool')!r}, expected {want_pool!r}")
    if "dcgmready" in rendered:
        env = rendered["dcgmready"]["env"]
        expected = f"daemonset/{facts['dcgmDaemonSet']}"
        if (env.get("WAIT_RESOURCE"), env.get("WAIT_CONDITION")) != (expected, "rollout"):
            fail(f"task dcgmready ({variant}): must wait for {expected} to roll out, which covers any number of GPU workers")
        if env.get("CONTRACT_NAME"):
            fail(f"task dcgmready ({variant}): publishes a contract; only gpuready does")
    if "gpu-smoke-test" in rendered:
        pod = rendered["gpu-smoke-test"]["pod"]
        if pod.get("nodeSelector") != gpu_sel:
            fail(f"task gpu-smoke-test ({variant}): nodeSelector {pod.get('nodeSelector')} is not the GPU node selector {gpu_sel} from the gate's contract")
        if not any(t.get("key") == "nvidia.com/gpu" for t in pod.get("tolerations") or []):
            fail(f"task gpu-smoke-test ({variant}): does not tolerate the GPU taint")
        res = pod["containers"][0].get("resources") or {}
        if dra:
            rcts = [d for d in rendered["gpu-smoke-test"]["docs"] if d.get("kind") == "ResourceClaimTemplate"]
            claims = pod.get("resourceClaims") or []
            if (len(rcts) != 1 or [c.get("resourceClaimTemplateName") for c in claims] != [rcts[0]["metadata"]["name"]]
                    or [c["name"] for c in res.get("claims") or []] != [c["name"] for c in claims]):
                fail(f"task gpu-smoke-test ({variant}): must request its GPU through one ResourceClaimTemplate")
            elif [r["exactly"]["deviceClassName"] for r in rcts[0]["spec"]["spec"]["devices"]["requests"]] != ["gpu.nvidia.com"]:
                fail(f"task gpu-smoke-test ({variant}): the claim must use DeviceClass gpu.nvidia.com")
            if "nvidia.com/gpu" in (res.get("limits") or {}):
                fail(f"task gpu-smoke-test ({variant}): requests nvidia.com/gpu, which the DRA stack never advertises")
        elif "nvidia.com/gpu" not in (res.get("limits") or {}) or pod.get("resourceClaims"):
            fail(f"task gpu-smoke-test ({variant}): must request nvidia.com/gpu with the device plugin")
    if "nvsentinel" in rendered:
        hv = rendered["nvsentinel"]["values"]
        if hv["global"]["dcgm"]["service"]["endpoint"] != contract.get("dcgmHost"):
            fail(f"task nvsentinel ({variant}): DCGM endpoint does not come from the gate's contract")
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
        # Quarantine (with the MongoDB store it needs) follows nvsentinelCordon, the drainer needs
        # quarantine too, and nothing that remediates or reboots is ever on.
        g = hv["global"]
        cordon = on("nvsentinelCordon")
        for component, want in (("faultQuarantine", cordon), ("mongodbStore", cordon),
                                ("nodeDrainer", cordon and on("nvsentinelDrain")),
                                ("faultRemediation", False), ("janitor", False), ("janitorProvider", False),
                                ("healthEventsAnalyzer", False), ("preflight", False)):
            if (g.get(component) or {}).get("enabled", False) is not want:
                fail(f"task nvsentinel ({variant}): global.{component}.enabled must be {want} with nvsentinelCordon={values['nvsentinelCordon']} nvsentinelDrain={values['nvsentinelDrain']}")
        if g.get("dryRun") is not on("nvsentinelDryRun"):
            fail(f"task nvsentinel ({variant}): global.dryRun={g.get('dryRun')!r} with nvsentinelDryRun={values['nvsentinelDryRun']}")
        mongo = hv["mongodb-store"]["mongodb"]
        replicas = int(values["nvsentinelMongodbReplicas"])
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
            want = {"enabled": True, "percentage": int(values["nvsentinelCircuitBreakerPercentage"]),
                    "maxNodes": int(values["nvsentinelCircuitBreakerMaxNodes"])}
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
                if c["image"] != f"ghcr.io/nvidia/nvsentinel/slinky-drainer:{values['nvsentinelVersion']}":
                    fail(f"{where}: image {c['image']} does not follow nvsentinelVersion")
                if f"--slinky-namespace={values['nvsentinelSlinkyNamespace']}" not in c.get("args", []):
                    fail(f"{where}: does not watch nvsentinelSlinkyNamespace={values['nvsentinelSlinkyNamespace']}")
                if dep["spec"]["template"]["spec"].get("nodeSelector") != cpu_pod_sel:
                    fail(f"{where}: the controller is not on the CPU services pool")
    if "nvsentinel" in rendered:
        cd = (rendered["nvsentinel"]["values"].get("node-drainer") or {}).get("customDrain") or {}
        where = f"task nvsentinel ({variant})"
        if bool(cd.get("enabled")) is not slinky:
            fail(f"{where}: node-drainer.customDrain.enabled={cd.get('enabled')!r} with Slinky drain {'on' if slinky else 'off'}")
        if slinky:
            if cd.get("nodeSelector") != values["nvsentinelSlinkyNodeSelector"] or not cd.get("nodeSelector"):
                fail(f"{where}: customDrain.nodeSelector {cd.get('nodeSelector')!r} must be nvsentinelSlinkyNodeSelector and never empty")
            docs = {(d["kind"], d["metadata"]["name"]): d for d in rendered.get("slinky-drainer", {}).get("docs", [])}
            crd = docs.get(("CustomResourceDefinition", "drainrequests.nvsentinel.nvidia.com"), {}).get("spec", {})
            want = {"templateConfigMapName": "slinky-drain-template", "templateFileName": "drain-template.yaml",
                    "apiGroup": crd.get("group"), "kind": crd.get("names", {}).get("kind"),
                    "resource": crd.get("names", {}).get("plural"),
                    "version": next((v["name"] for v in crd.get("versions", []) if v.get("served")), None),
                    "statusConditionType": "DrainComplete", "statusConditionStatus": "True"}
            if not re.fullmatch(r"[1-9][0-9]*", str(cd.get("timeout", ""))):
                fail(f"{where}: customDrain.timeout {cd.get('timeout')!r} must be whole seconds; node-drainer rejects durations like 30m")
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
for ref, param in ((GATE, "capacityNodeSelector"), (f"{PREFIX}-gpu-smoke-test", "gpuNodeSelector")):
    names = []
    for sel in ("workload.example.com/pool=gpu-compute", "foo.acme.corp/gpu-node=true"):
        docs = render_app(apps[ref], {param: sel}, "hash", f"{ref} hash")
        names.append([d["metadata"]["name"] for d in docs or [] if d.get("kind") == "Job"])
    if names[0] == names[1]:
        fail(f"apps/: {ref} keeps Job name {names[0]} when {param} changes; Helm cannot patch a Job's pod template")

# Run the discover script against a fake kubectl. The fake lists one PVC in nvsentinel, gives its
# PV the node affinity FAKE_TERMS, and reports a node only for the exact selector FAKE_MATCH.
fake = work / "fakebin"
fake.mkdir()
(fake / "kubectl").write_text("""#!/bin/sh
case "$*" in
  *clusterpolicies*|*gpuclusters*|*"patch configmap"*) exit 0 ;;
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
for case, sel, pv, terms, match, ok, says in [
    ("pinned volume still reachable", POOL, "pv-1", HOST, f"kubernetes.io/hostname in (node-a),{POOL}", True, "reaches every pinned volume"),
    ("selector strands the volume", "foo.acme.corp/cpu-node=true", "pv-1", HOST, f"kubernetes.io/hostname in (node-a),{POOL}", False, "can reach PersistentVolume pv-1"),
    ("zonal volume, node in zone", "foo.acme.corp/cpu-node=true", "pv-1", "topology.kubernetes.io/zone In europe-west4-b|",
     "topology.kubernetes.io/zone in (europe-west4-b),foo.acme.corp/cpu-node=true", True, "reaches every pinned volume"),
    ("no volumes yet", "foo.acme.corp/cpu-node=true", "", "", "", True, "reaches every pinned volume"),
    ("malformed selector", "foo", "", "", "", False, "is not a key=value label"),
]:
    env = {"PATH": f"{fake}:/usr/bin:/bin", "HOME": str(work), "REQUESTED_MODE": "device-plugin",
           "CONTRACT_NAME": "gpu-driver-mode", "CONTRACT_NAMESPACE": "gpu-stack", "CPU_NODE_SELECTOR": sel,
           "PINNED_VOLUME_NAMESPACE": "nvsentinel", "FAKE_PV": pv, "FAKE_TERMS": terms, "FAKE_MATCH": match}
    r = subprocess.run(["sh", "-c", script], env=env, capture_output=True, text=True)
    out = r.stdout + r.stderr
    if (r.returncode == 0) != ok or says not in out:
        fail(f"apps/{DISCOVER} guard, {case}: exit {r.returncode}, expected {'success' if ok else 'failure'} saying {says!r}: {out.strip()[-300:]}")

# --- VirtualClusterTemplate ----------------------------------------------------------------------
vct_path = root / "virtualclustertemplate.yaml"
vct = (load(vct_path) or [{}])[0]
common(vct_path, vct, "VirtualClusterTemplate")
vct_params = check_parameters("virtualclustertemplate.yaml", vct["spec"].get("parameters"))
check_refs("virtualclustertemplate.yaml", vct["spec"]["template"], vct_params)
for stack_var, p in stack_params.items():
    if stack_var in vct_params and "defaultValue" in p and str(p["defaultValue"]) != str(vct_params[stack_var].get("defaultValue")):
        fail(f"virtualclustertemplate.yaml: default {stack_var}={vct_params[stack_var].get('defaultValue')!r} disagrees with the StackTemplate's {p['defaultValue']!r}")
for name, providers in {"one provider": ("provider-a", "provider-a"), "two providers": ("provider-a", "provider-b")}.items():
    values = {**defaults(vct_params), "argoConnector": "argocd", "gpuNodeProvider": providers[0], "cpuNodeProvider": providers[1]}
    t = render(vct["spec"]["template"], values, f"virtualclustertemplate.yaml ({name})")
    if not t:
        continue
    try:
        cfg = yaml.safe_load(t["helmRelease"]["values"])
    except yaml.YAMLError as e:
        fail(f"virtualclustertemplate.yaml ({name}): rendered vcluster.yaml is not YAML: {e}")
        continue
    auto = cfg["privateNodes"]["autoNodes"]
    if [a["provider"] for a in auto] != sorted(set(providers), key=providers.index):
        fail(f"virtualclustertemplate.yaml ({name}): autoNodes providers {[a['provider'] for a in auto]}, expected one entry per provider")
    pools = {p["name"]: p for a in auto for p in a["static"]}
    if set(pools) != {"gpu", "cpu"}:
        fail(f"virtualclustertemplate.yaml ({name}): expected pools gpu and cpu, found {sorted(pools)}")
    for pool in pools.values():
        if pool.get("profile") not in profiles:
            fail(f"virtualclustertemplate.yaml ({name}): pool {pool['name']} uses NodeProfile {pool.get('profile')!r}, which nodeprofiles.yaml does not define")
    if str(pools.get("gpu", {}).get("quantity")) != str(values["gpuNodeCount"]):
        fail(f"virtualclustertemplate.yaml ({name}): GPU pool quantity does not follow gpuNodeCount")
    stacks = cfg["deploy"]["stacks"]
    if [s["templateRef"]["name"] for s in stacks] != [STACK]:
        fail(f"virtualclustertemplate.yaml ({name}): deploy.stacks must reference {STACK}")
    passed = stacks[0].get("parameters") or {}
    for p in passed:
        if p not in stack_params:
            fail(f"virtualclustertemplate.yaml: passes {p!r} to the Stack, which does not declare it")
    for p in stack_params:
        if p not in passed:
            fail(f"virtualclustertemplate.yaml: does not pass Stack parameter {p!r}; the tenant form cannot set it")

# --- Examples ------------------------------------------------------------------------------------
for path in sorted((root / "example").glob("*.yaml")):
    for doc in load(path):
        common(path, doc, "StackInstance")
        if (doc["spec"].get("templateRef") or {}).get("name") != STACK:
            fail(f"{rel(path)}: expected a StackInstance of {STACK}")
        if not doc["spec"].get("owner"):
            fail(f"{rel(path)}: spec.owner is required; every task fails with MissingOwner without it")
        for p, v in (doc["spec"].get("parameters") or {}).items():
            if p not in stack_params:
                fail(f"{rel(path)}: parameter {p!r} is not declared by the template")
            elif not isinstance(v, str):
                fail(f"{rel(path)}: parameter {p} must be a quoted string, found {type(v).__name__}")

if errors:
    for error in errors:
        print(f"FAIL {error}", file=sys.stderr)
    sys.exit(1)
print(f"ok manifests, {counter['render']} template renders, {counter['app']} App renders")
CHECKS
