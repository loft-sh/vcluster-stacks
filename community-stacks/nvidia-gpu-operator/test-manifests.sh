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
# The Platform caps every App deploy (helm --wait) at 30 minutes.
APP_DEPLOY_CAP = 30 * 60
# Stands in for the image the Platform injects as .Values.__image__.
PLATFORM_IMAGE = "ghcr.io/loft-sh/vcluster-platform:test"
TYPES = {"string", "multiline", "boolean", "number", "password", None}
VALUES_REF = re.compile(r"\.Values\.([A-Za-z_][A-Za-z0-9_]*)")
OUTPUTS_REF = re.compile(r"\.Outputs\.([A-Za-z0-9_]+)\.([A-Za-z0-9_]+)")
# Keys the gate patches into its contract, whatever contractData declares.
GATE_KEYS = {"ready", "observedCount", "verifiedAt", "resourceName"}


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
    fail("nodeprofiles.yaml: the GPU profile must label workload.example.com/pool=gpu-compute; the templates hard-code it")
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
            fail(f"{rel(path)}: wait must be true, or the task is Healthy before its Job finishes")
        seconds = short_duration(spec.get("timeout", ""), rel(path))
        if seconds is not None and seconds >= APP_DEPLOY_CAP:
            fail(f"{rel(path)}: timeout {spec['timeout']} reaches the Platform's 30m per-deploy cap")
        if not spec.get("defaultNamespace"):
            fail(f"{rel(path)}: no defaultNamespace; Stack outputs can be read only from a namespace a task deploys into")
    else:
        check_refs(rel(path), doc["spec"]["template"], params)
    apps[name] = {"path": path, "doc": doc, "params": params, "kind": kind}

gate_doc = apps.get(GATE, {})
if gate_doc.get("kind") != "App" or "__image__" not in gate_doc["doc"]["spec"].get("config", {}).get("manifests", ""):
    fail(f"apps/: {GATE} must be an App whose Job runs .Values.__image__; that keeps this Stack free of its own image")

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

# A rollout wait on a DaemonSet that schedules no pods yet passes at once, so dcgmready must
# follow gpuready, which proves a GPU node is there.
if "dcgmready" in tasks and "gpuready" not in ancestors("dcgmready"):
    fail("stacktemplate.yaml task dcgmready: must depend on gpuready; before a GPU node joins, nvidia-dcgm has already rolled out")

# Defaults that must agree across files: a stack default overrides the template's, so a drifted
# template default only bites when someone deploys the template on its own.
for stack_var, app, app_var in [
    ("gpuOperatorVersion", f"{PREFIX}-gpu-operator", "version"),
    ("nvsentinelVersion", f"{PREFIX}-nvsentinel", "version"),
    ("cpuNodePool", f"{PREFIX}-gpu-operator", "cpuNodePool"),
    ("cpuNodePool", f"{PREFIX}-nvsentinel", "cpuNodePool"),
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
    "alternate": {"driverPreinstalled": "true", "waitForClusterPolicy": "true", "minGPUs": "2"},
}
for variant, overrides in VARIANTS.items():
    values = {**defaults(stack_params), **overrides}
    on = lambda k: str(values[k]) == "true"
    contract = {}
    outputs = {}
    rendered = {}
    # gpuready first: its rendered contract stands in for what the gate publishes at runtime.
    for name in sorted(tasks, key=lambda n: (n != "gpuready", n)):
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
            if ref == GATE:
                if pod["containers"][0]["image"] != PLATFORM_IMAGE:
                    fail(f"{where}: the gate Job does not run the Platform image")
                if (pod.get("nodeSelector") or {}).get("workload.example.com/pool") != values["cpuNodePool"]:
                    fail(f"{where}: the gate Job is not on the CPU services pool")
        else:
            spec_r = render(app["doc"]["spec"]["template"], {**defaults(app["params"]), **passed}, f"{ref} for {where}")
            if not spec_r:
                continue
            try:
                hv = yaml.safe_load(spec_r["spec"]["source"].get("helm", {}).get("values") or "") or {}
            except yaml.YAMLError as e:
                fail(f"{ref} for {where}: rendered Helm values are not YAML: {e}")
                continue
            rendered[name] = {"ref": ref, "values": hv}

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
            outputs = {"gpuready": {o["name"]: str(contract.get(o["fromResource"]["jsonPath"][len("{.data."):-1], ""))
                                    for o in declared_outputs["gpuready"].values()}}

    # Behavior the parameters promise.
    if "gpu-operator" in rendered:
        driver = rendered["gpu-operator"]["values"]["driver"]["enabled"]
        if driver is on("driverPreinstalled"):
            fail(f"task gpu-operator ({variant}): driver.enabled={driver} with driverPreinstalled={values['driverPreinstalled']}")
    if "gpuready" in rendered:
        env = rendered["gpuready"]["env"]
        if bool(env.get("WAIT_RESOURCE")) is not on("waitForClusterPolicy"):
            fail(f"task gpuready ({variant}): WAIT_RESOURCE={env.get('WAIT_RESOURCE')!r} with waitForClusterPolicy={values['waitForClusterPolicy']}")
        if env.get("CAPACITY_MIN") != str(values["minGPUs"]) or env.get("CAPACITY_RESOURCE") != "nvidia.com/gpu":
            fail(f"task gpuready ({variant}): the gate does not wait for minGPUs={values['minGPUs']} nvidia.com/gpu")
        if env.get("CAPACITY_NODE_SELECTOR") != "workload.example.com/pool=gpu-compute":
            fail(f"task gpuready ({variant}): capacity is not counted on the GPU pool")
    if "dcgmready" in rendered:
        env = rendered["dcgmready"]["env"]
        if (env.get("WAIT_RESOURCE"), env.get("WAIT_CONDITION")) != ("daemonset/nvidia-dcgm", "rollout"):
            fail(f"task dcgmready ({variant}): must wait for daemonset/nvidia-dcgm to roll out, which covers any number of GPU workers")
        if env.get("CONTRACT_NAME"):
            fail(f"task dcgmready ({variant}): publishes a contract; only gpuready does")
    if "gpu-smoke-test" in rendered:
        pod = rendered["gpu-smoke-test"]["pod"]
        if (pod.get("nodeSelector") or {}).get("workload.example.com/pool") != contract.get("gpuPool"):
            fail(f"task gpu-smoke-test ({variant}): does not select the GPU pool from the gate's contract")
        if not any(t.get("key") == "nvidia.com/gpu" for t in pod.get("tolerations") or []):
            fail(f"task gpu-smoke-test ({variant}): does not tolerate the GPU taint")
    if "nvsentinel" in rendered:
        hv = rendered["nvsentinel"]["values"]
        if hv["global"]["dcgm"]["service"]["endpoint"] != contract.get("dcgmHost"):
            fail(f"task nvsentinel ({variant}): DCGM endpoint does not come from the gate's contract")
        if str(hv["labeler"]["assumeDriverInstalled"]).lower() != str(values["driverPreinstalled"]):
            fail(f"task nvsentinel ({variant}): labeler.assumeDriverInstalled disagrees with driverPreinstalled")
        # cert-manager is a production prerequisite, not part of this Stack: every NVSentinel
        # component that needs it stays off.
        g = hv["global"]
        for component in ("mongodbStore", "janitor", "janitorProvider", "preflight"):
            if (g.get(component) or {}).get("enabled") is True:
                fail(f"task nvsentinel ({variant}): global.{component} needs cert-manager, which this Stack does not install")

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
