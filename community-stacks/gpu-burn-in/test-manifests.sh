#!/usr/bin/env bash
# Static checks for the GPU burn-in Stack: the invariants the Platform does not validate for you.
# Modeled on community-stacks/nvidia-gpu-operator/test-manifests.sh.
#
#   ./test-manifests.sh
#
# Renders each StackTemplate task, then the ArgoCDApplicationTemplate it references, then the chart
# with the Helm values that template produces, for the default parameters and for a variant that
# takes the other branch of every conditional. Then runs the pass/fail unit tests in
# tests/evaluate-test.sh.
#
# Needs bash >= 4, python3 with PyYAML, helm, jq, sh and, for the recorder, go. Exits 1 on failures, 2 on a missing
# prerequisite.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

missing=()
[[ "${BASH_VERSINFO[0]}" -ge 4 ]] || missing+=("bash >= 4 (running ${BASH_VERSION}; macOS /bin/bash is 3.2, try 'brew install bash')")
for tool in python3 helm jq; do
  command -v "$tool" >/dev/null || missing+=("$tool")
done
command -v python3 >/dev/null && { python3 -c 'import yaml' 2>/dev/null || missing+=("PyYAML (python3 -m pip install pyyaml)"); }
if [[ "${#missing[@]}" -gt 0 ]]; then
  echo "cannot run: missing prerequisite(s)" >&2
  printf '  - %s\n' "${missing[@]}" >&2
  exit 2
fi

status=0
for script in "$root"/chart/files/*.sh "$root"/tests/evaluate-test.sh; do
  sh -n "$script" || { echo "FAIL $script: not valid sh" >&2; status=1; }
done
for script in "$root"/automation/*.sh "$root"/tests/nvml-mock-e2e.sh; do
  bash -n "$script" || { echo "FAIL $script: not valid bash" >&2; status=1; }
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

python3 - "$root" "$work" <<'CHECKS' || status=1
import copy
import json
import re
import subprocess
import sys
from pathlib import Path

import yaml

root, work = Path(sys.argv[1]), Path(sys.argv[2])
errors = []

PREFIX = "gpu-burn-in"
PART_OF = "gpu-burn-in-stack"
STACK = "gpu-burn-in"
TEST_APP = f"{PREFIX}-test"
NAMESPACE = "gpu-burn-in"
# The steps run strictly in this order, because GPU tests disturb each other's measurements.
CHAIN = ["gpu-operator", "gpuready", "inventory", "dcgmdiag", "nccl", "soak", "report", "verdict"]
GPU_TESTS = ["inventory", "dcgmdiag", "nccl", "soak"]
TYPES = {"string", "multiline", "boolean", "number", "password", None}
VALUES_REF = re.compile(r"\.Values\.([A-Za-z_][A-Za-z0-9_]*)")
OUTPUTS_REF = re.compile(r"\.Outputs\.([A-Za-z0-9_]+)\.([A-Za-z0-9_]+)")
# Keys the steps write with --from-literal, by step. Outputs may read only these.
WRITTEN = {}
for script, step in [("gpuready.sh", "gpuready"), ("report.sh", "report")]:
    WRITTEN[step] = set(re.findall(r"--from-(?:literal|file)=([A-Za-z.]+)=", (root / "chart/files" / script).read_text()))
WRITTEN["gpuready"] |= set(re.findall(r"--from-literal=([A-Za-z]+)=", (root / "chart/files/lib.sh").read_text()))


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


# Templated strings are rendered one at a time with Helm's own engine (text/template plus sprig),
# through tpl. Parameter values are strings, as the Platform passes them.
render_chart = work / "render"
(render_chart / "templates").mkdir(parents=True)
(render_chart / "Chart.yaml").write_text("apiVersion: v2\nname: render\nversion: 0.0.0\n")
(render_chart / "templates" / "out.yaml").write_text(
    '{{- $ctx := dict "Values" (omit .Values "__strings" "__outputs") "Outputs" .Values.__outputs "Template" .Template }}\n'
    "{{- range $k, $v := .Values.__strings }}\n"
    "{{ $k }}: {{ tpl $v $ctx | toJson }}\n"
    "{{- end }}\n"
)
counter = {"render": 0, "chart": 0}


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


def render_test_chart(helm_values, release, where):
    """The objects the chart renders to, from the Helm values string an Argo CD Application carries."""
    counter["chart"] += 1
    vf = work / f"chart-values-{counter['chart']}.yaml"
    vf.write_text(helm_values)
    r = subprocess.run(["helm", "template", release, str(root / "chart"), "--namespace", NAMESPACE, "-f", str(vf)],
                       capture_output=True, text=True)
    if r.returncode != 0:
        fail(f"{where}: chart does not render: {r.stderr.strip()}")
        return None
    try:
        return [d for d in yaml.safe_load_all(r.stdout) if d]
    except yaml.YAMLError as e:
        fail(f"{where}: chart output is not YAML: {e}")
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
        if t is None:
            # The management API merges parameter lists by position on apply, so an untyped
            # parameter can inherit its neighbour's type, such as number on a string.
            fail(f"{where}: {v} has no type; give every parameter an explicit type")
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
            else:
                if "min" in p and int(d) < int(p["min"]):
                    fail(f"{where}: {v} default {d} is below min {p['min']}")
                if "max" in p and int(d) > int(p["max"]):
                    fail(f"{where}: {v} default {d} is above max {p['max']}")
        options = [str(o) for o in p.get("options") or []]
        if options and d not in options:
            fail(f"{where}: {v} default {d!r} is not one of {options}")
    return by_name


def defaults(params):
    return {v: p["defaultValue"] for v, p in params.items() if "defaultValue" in p}


def check_refs(where, node, declared):
    for path, s in strings(node):
        for ref in VALUES_REF.findall(s):
            if ref not in declared:
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


# --- ArgoCDApplicationTemplates -----------------------------------------------------------------
apps = {}
for path in sorted((root / "apps").glob("*.yaml")):
    docs = load(path)
    if len(docs) != 1:
        fail(f"{rel(path)}: expected exactly one YAML document, found {len(docs)}")
        continue
    doc = docs[0]
    common(path, doc, "ArgoCDApplicationTemplate")
    name = doc["metadata"]["name"]
    stem = re.sub(r"^\d+-", "", path.stem)
    if name != f"{PREFIX}-{stem}":
        fail(f"{rel(path)}: name {name!r} does not match its file; expected {PREFIX}-{stem}")
    params = check_parameters(rel(path), doc["spec"].get("parameters"))
    check_refs(rel(path), doc["spec"]["template"], params)
    apps[name] = {"path": path, "doc": doc, "params": params}

test_app = apps.get(TEST_APP)
chart_values = yaml.safe_load((root / "chart/values.yaml").read_text())
if test_app:
    src = test_app["doc"]["spec"]["template"]["spec"]["source"]
    if src.get("path") != f"community-stacks/{PREFIX}/chart":
        fail(f"apps/02-test.yaml: source.path must be community-stacks/{PREFIX}/chart, where the chart lives in this repository")
    if test_app["doc"]["spec"]["template"]["spec"]["destination"]["namespace"] != NAMESPACE:
        fail(f"apps/02-test.yaml: destination namespace must be {NAMESPACE}; Stack outputs read from it")
    # Every chart value is a template parameter, and both agree on defaults.
    tparams = test_app["params"]
    for k, v in chart_values.items():
        if k not in tparams:
            fail(f"chart/values.yaml: {k} is not a parameter of {TEST_APP}, so the Stack cannot set it")
        elif "defaultValue" in tparams[k] and str(tparams[k]["defaultValue"]) != str(v):
            fail(f"default {k}={v!r} in chart/values.yaml disagrees with {tparams[k]['defaultValue']!r} in {TEST_APP}")
    for k in tparams:
        if k not in chart_values and k not in ("project", "repoURL", "revision"):
            fail(f"{TEST_APP}: parameter {k} is not a chart value")

# --- StackTemplate ------------------------------------------------------------------------------
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
if list(tasks) != CHAIN:
    fail(f"stacktemplate.yaml: tasks {list(tasks)}, expected {CHAIN}")
if len(tasks) > 20:
    fail("stacktemplate.yaml: a Stack has at most 20 tasks")

task_seconds = {}
for i, (name, task) in enumerate(tasks.items()):
    where = f"stacktemplate.yaml task {name}"
    task_seconds[name] = go_duration(task.get("timeout", ""), where)
    if "argoCDApplication" not in task or "app" in task:
        fail(f"{where}: must be an argoCDApplication task; Platform App deploys stop at 30 minutes")
    want = [CHAIN[i - 1]] if i else []
    if (task.get("dependsOn") or []) != want:
        fail(f"{where}: dependsOn {task.get('dependsOn')}, expected {want}; the steps run one at a time")
    if task.get("outputs") and not re.fullmatch(r"[A-Za-z0-9]+", name):
        fail(f"{where}: declares outputs, so its name must be letters and digits only")
    for out in task.get("outputs") or []:
        fr = out.get("fromResource") or {}
        key = fr.get("jsonPath", "")[len("{.data."):-1].replace("\\.", ".")
        if fr.get("namespace") != NAMESPACE:
            fail(f"{where}: output {out['name']} reads namespace {fr.get('namespace')}; only {NAMESPACE} is one the Stack deploys into")
        if key not in WRITTEN.get(name, set()):
            fail(f"{where}: output {out['name']} reads key {key!r}, which the {name} step never writes")


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

# Defaults that must agree across files.
for stack_var, app, app_var in [
    ("gpuOperatorVersion", f"{PREFIX}-gpu-operator", "version"),
    ("chartRepoURL", TEST_APP, "repoURL"),
    ("chartRevision", TEST_APP, "revision"),
    ("toolsImage", TEST_APP, "toolsImage"),
    ("dcgmImage", TEST_APP, "dcgmImage"),
    ("ncclImage", TEST_APP, "ncclImage"),
    ("expectedGPUs", TEST_APP, "expectedGPUs"),
    ("soakMinutes", TEST_APP, "soakMinutes"),
    ("maxGPUTempC", TEST_APP, "maxGPUTempC"),
    ("dcgmDiagLevel", TEST_APP, "dcgmDiagLevel"),
]:
    a = defaults(stack_params).get(stack_var)
    b = defaults(apps.get(app, {}).get("params", {})).get(app_var)
    if str(a) != str(b):
        fail(f"default {stack_var}={a!r} in stacktemplate.yaml disagrees with {app_var}={b!r} in {app}")

# --- Render the graph for two parameter sets ----------------------------------------------------
VARIANTS = {
    "defaults": {},
    "nvml-mock": {"runDCGMDiag": "false", "runNCCL": "false", "soakLoad": "none", "soakMinutes": "5",
                  "driverPreinstalled": "true", "expectedGPUs": "4", "gpuModel": "B200", "nvmlMock": "true"},
    "no-soak": {"soakMinutes": "0", "reportS3URI": "s3://bucket/q", "s3CredentialsSecret": "s3", "telemetry": "false"},
    "v100": {"driverVersion": "580.178.04", "ncclImage": "nvcr.io/nvidia/pytorch:24.12-py3", "expectedGPUs": "1",
             "gpuModel": "V100"},
}
GPUS_SEEN = "7"  # what gpuready "observed": deliberately not expectedGPUs
for variant, overrides in VARIANTS.items():
    values = {**defaults(stack_params), **overrides}
    outputs = {"gpuready": {"gpus": GPUS_SEEN}, "report": {"result": "failed", "failedtests": "inventory,soak"}}
    jobs = {}
    for name, task in tasks.items():
        where = f"task {name} ({variant})"
        t = render(task, values, where, outputs)
        if not t:
            continue
        ref = t["argoCDApplication"]["templateRef"]["name"]
        app = apps.get(ref)
        if not app:
            fail(f"{where}: templateRef {ref!r} is not in apps/")
            continue
        passed = t["argoCDApplication"].get("parameters") or {}
        for p in passed:
            if p not in app["params"]:
                fail(f"{where}: passes {p!r}, which {ref} does not declare")
        for v, p in app["params"].items():
            if p.get("required") and "defaultValue" not in p and v not in passed:
                fail(f"{where}: {ref} requires {v!r}, which the task does not pass")
        spec_r = render(app["doc"]["spec"]["template"], {**defaults(app["params"]), **passed}, f"{ref} for {where}")
        if not spec_r or ref != TEST_APP:
            if spec_r and ref == f"{PREFIX}-gpu-operator":
                hv = yaml.safe_load(spec_r["spec"]["source"]["helm"]["values"])
                if hv["driver"]["enabled"] is (values["driverPreinstalled"] == "true" or values["nvmlMock"] == "true"):
                    fail(f"{where}: driver.enabled={hv['driver']['enabled']} with driverPreinstalled={values['driverPreinstalled']}")
                mock_env = (hv.get("validator") or {}).get("driver", {}).get("env") or []
                if hv["toolkit"]["enabled"] is (values["nvmlMock"] == "true"):
                    fail(f"{where}: toolkit.enabled={hv['toolkit']['enabled']} with nvmlMock={values['nvmlMock']}; nvml-mock nodes have no operator toolkit for the CDI hook")
                if any(e.get("name") == "DISABLE_DEV_CHAR_SYMLINK_CREATION" for e in mock_env) is not (values["nvmlMock"] == "true"):
                    fail(f"{where}: the nvml-mock validator settings must follow nvmlMock={values['nvmlMock']}")
                if hv["driver"].get("version") != (values.get("driverVersion") or None):
                    fail(f"{where}: driver.version={hv['driver'].get('version')!r} with driverVersion={values.get('driverVersion')!r}")
                want = values["telemetry"] != "false"
                if hv["dcgm"]["enabled"] is not want or hv["dcgmExporter"]["enabled"] is not want:
                    fail(f"{where}: DCGM and dcgm-exporter must both follow telemetry={values['telemetry']}")
            continue
        if passed.get("test") != name:
            fail(f"{where}: passes test={passed.get('test')!r}; each task runs the step of its own name")
        src = spec_r["spec"]["source"]
        docs = render_test_chart(src["helm"]["values"], src["helm"]["releaseName"], where)
        if docs is None:
            continue
        js = [d for d in docs if d["kind"] == "Job"]
        if len(js) != 1:
            fail(f"{where}: expected exactly one Job, whose completion holds the task; found {len(js)}")
            continue
        job = js[0]
        pod = job["spec"]["template"]["spec"]
        env = {e["name"]: e.get("value") for e in pod["containers"][0].get("env", [])}
        jobs[name] = {"job": job, "pod": pod, "env": env, "docs": docs}
        if job["spec"].get("backoffLimit") != 0 or pod.get("restartPolicy") != "Never" or "ttlSecondsAfterFinished" in job["spec"]:
            fail(f"{where}: the Job must run once, not restart in place, and not expire")
        if any(d["kind"] == "ConfigMap" and d["metadata"]["name"].startswith("gpu-burn-in-result") for d in docs):
            fail(f"{where}: the chart must not own a result ConfigMap; the step writes it, and Argo CD would prune or overwrite it")
        if name in GPU_TESTS:
            enabled = env.get("ENABLED") != "false"
            inits = pod.get("initContainers") or []
            if not enabled:
                if inits:
                    fail(f"{where}: a disabled test still runs containers and pulls its image")
                continue
            run = {c["name"]: c for c in inits}.get("run")
            if [c["name"] for c in inits] != ["gate", "run"] or not run:
                fail(f"{where}: expected init containers gate and run")
                continue
            # A device plugin request would leave the pod Pending once a GPU turns unhealthy mid-run.
            if (run.get("resources") or {}).get("limits", {}).get("nvidia.com/gpu"):
                fail(f"{where}: requests nvidia.com/gpu; GPU tests must take every GPU through the NVIDIA runtime")
            run_env = {e["name"]: e.get("value") for e in run["env"]}
            if pod.get("runtimeClassName") != "nvidia" or run_env.get("NVIDIA_VISIBLE_DEVICES") != "all":
                fail(f"{where}: GPU tests must run with runtimeClassName nvidia and NVIDIA_VISIBLE_DEVICES=all")
            if "Replace=true" in str(job["metadata"].get("annotations", {}).get("argocd.argoproj.io/sync-options", "")):
                fail(f"{where}: sync-options Replace=true makes Argo CD replace completed Jobs, which fails on their selector")
            if not any(t.get("key") == "nvidia.com/gpu" for t in pod.get("tolerations") or []):
                fail(f"{where}: does not tolerate the GPU taint")
            budget = int({e["name"]: e.get("value") for e in run["env"]}["RUN_TIMEOUT_SECONDS"])
            if task_seconds.get(name) is not None and task_seconds[name] <= budget + 300:
                fail(f"{where}: task timeout {task['timeout']} leaves under 5 minutes over the test's own {budget}s deadline")
    # Behavior the parameters promise.
    if "gpuready" in jobs and task_seconds.get("gpuready"):
        if task_seconds["gpuready"] <= int(jobs["gpuready"]["env"]["READY_WAIT_SECONDS"]) + 300:
            fail(f"task gpuready ({variant}): timeout must exceed the GPU wait by 5 minutes")
    if "soak" in jobs:
        want = "false" if values["soakMinutes"] == "0" else "true"
        if jobs["soak"]["env"]["ENABLED"] != want:
            fail(f"task soak ({variant}): ENABLED={jobs['soak']['env']['ENABLED']} with soakMinutes={values['soakMinutes']}")
    # With telemetry the DCGM tests share the GPU Operator's host engine; without it they start their own.
    for name in ("dcgmdiag", "soak"):
        if name in jobs:
            want = "" if values["telemetry"] == "false" else "nvidia-dcgm.gpu-operator.svc:5555"
            got = {e["name"]: e.get("value") for e in jobs[name]["pod"].get("initContainers", [{}])[-1].get("env", [])}.get("DCGM_HOST", jobs[name]["env"].get("DCGM_HOST"))
            if got != want:
                fail(f"task {name} ({variant}): DCGM_HOST={got!r} with telemetry={values['telemetry']}, want {want!r}")
    for name, var in (("dcgmdiag", "runDCGMDiag"), ("nccl", "runNCCL")):
        if name in jobs and jobs[name]["env"]["ENABLED"] != values[var]:
            fail(f"task {name} ({variant}): ENABLED={jobs[name]['env']['ENABLED']} with {var}={values[var]}")
    if "report" in jobs:
        env = jobs["report"]["env"]
        if env["TESTS"].split(",") != CHAIN[1:6]:
            fail(f"task report ({variant}): expects results from {env['TESTS']}, not the test tasks {CHAIN[1:6]}")
        has_secret = any("envFrom" in c for c in jobs["report"]["pod"]["containers"])
        if has_secret != bool(values.get("s3CredentialsSecret")):
            fail(f"task report ({variant}): S3 credentials Secret mounting does not follow s3CredentialsSecret")
    if "verdict" in jobs and (jobs["verdict"]["env"]["RESULT"], jobs["verdict"]["env"]["FAILED_TESTS"]) != ("failed", "inventory,soak"):
        fail(f"task verdict ({variant}): does not receive the report's result and failed tests from its outputs")

# The soak's own deadline grows with soakMinutes; at the maximum it must still end before the task.
soak_max = int(stack_params.get("soakMinutes", {}).get("max", 0))
docs = render_test_chart(f'test: soak\nsoakMinutes: "{soak_max + 100}"\n', "gpu-burn-in-soak", "soak at maximum")
if docs:
    pod = [d for d in docs if d["kind"] == "Job"][0]["spec"]["template"]["spec"]
    budget = int({e["name"]: e.get("value") for e in pod["containers"][0]["env"]}["RUN_TIMEOUT_SECONDS"])
    if budget != soak_max * 60 + 900:
        fail(f"chart: soakMinutes above {soak_max} is not clamped (deadline {budget}s)")
    if task_seconds.get("soak") and task_seconds["soak"] <= budget + 300:
        fail(f"task soak: timeout {tasks['soak']['timeout']} does not cover a {soak_max} minute soak")

# --- VirtualClusterTemplate ---------------------------------------------------------------------
vct_path = root / "virtualclustertemplate.yaml"
vct = (load(vct_path) or [{}])[0]
common(vct_path, vct, "VirtualClusterTemplate")
vct_params = check_parameters("virtualclustertemplate.yaml", vct["spec"].get("parameters"))

# A parameter the template uses directly, not through the parameter list, needs a fallback equal to
# its defaultValue. A tenant cluster created with kubectl gets no parameter defaults, and the
# Platform reports it out of date when it renders differently from one with the defaults applied.
vct_body = vct_path.read_text()
vct_defaults = {p.get("variable"): p.get("defaultValue") for p in vct["spec"].get("parameters") or []}
for m in re.finditer(r"\.Values\.(\w+)((?:\s*\|\s*[^|}]+)*)\}\}", vct_body):
    var, pipes = m.group(1), m.group(2)
    if vct_defaults.get(var) is None:
        continue
    fallback = re.search(r'default\s+"([^"]*)"', pipes)
    if not fallback:
        fail(f"virtualclustertemplate.yaml: .Values.{var} has defaultValue {vct_defaults[var]!r} but no '| default' fallback")
    elif fallback.group(1) != str(vct_defaults[var]):
        fail(f"virtualclustertemplate.yaml: .Values.{var} falls back to {fallback.group(1)!r}, but its defaultValue is {vct_defaults[var]!r}")
check_refs("virtualclustertemplate.yaml", vct["spec"]["template"], vct_params)
for stack_var, p in stack_params.items():
    if stack_var in vct_params and "defaultValue" in p and str(p["defaultValue"]) != str(vct_params[stack_var].get("defaultValue")):
        fail(f"virtualclustertemplate.yaml: default {stack_var}={vct_params[stack_var].get('defaultValue')!r} disagrees with the StackTemplate's {p['defaultValue']!r}")
# As the UI form submits it: every parameter, empty when it has no default.
values = {**{v: "" for v in vct_params}, **defaults(vct_params), "argoConnector": "argocd", "gpuNodeProvider": "metal3"}
t = render(vct["spec"]["template"], values, "virtualclustertemplate.yaml")
if t:
    try:
        cfg = yaml.safe_load(t["helmRelease"]["values"])
    except yaml.YAMLError as e:
        fail(f"virtualclustertemplate.yaml: rendered vcluster.yaml is not YAML: {e}")
        cfg = None
    if cfg:
        pools = [p for a in cfg["privateNodes"]["autoNodes"] for p in a.get("static", []) + a.get("dynamic", [])]
        if len(pools) != 1 or str(pools[0].get("quantity")) != "1":
            fail("virtualclustertemplate.yaml: must claim exactly one server; the Stack qualifies one server per tenant cluster")
        stacks = cfg["deploy"]["stacks"]
        if [s["templateRef"]["name"] for s in stacks] != [STACK]:
            fail(f"virtualclustertemplate.yaml: deploy.stacks must reference {STACK}")
        passed = stacks[0].get("parameters") or {}
        for p in passed:
            if p not in stack_params:
                fail(f"virtualclustertemplate.yaml: passes {p!r} to the Stack, which does not declare it")
        for p in stack_params:
            if p not in passed:
                fail(f"virtualclustertemplate.yaml: does not pass Stack parameter {p!r}; the tenant form cannot set it")
# A VirtualClusterInstance created with kubectl carries only the parameters it sets, with no template
# defaults. Unset Stack parameters must be left out, not rendered as <nil>.
sparse = {"argoConnector": "argocd", "gpuNodeProvider": "metal3", "nodeTypeProperty": "vcluster.com/profile",
          "nodeTypeValue": "xlarge-gpu", "runNCCL": "false"}
t = render(vct["spec"]["template"], sparse, "virtualclustertemplate.yaml (kubectl instance)")
if t:
    passed = yaml.safe_load(t["helmRelease"]["values"])["deploy"]["stacks"][0].get("parameters") or {}
    if passed != {"runNCCL": "false"}:
        fail(f"virtualclustertemplate.yaml: with only runNCCL set, passes {passed}; unset parameters must be omitted so the Stack defaults apply")

# --- Examples -----------------------------------------------------------------------------------
for path in sorted((root / "example").glob("*.yaml")):
    for doc in load(path):
        common(path, doc, ("StackInstance", "VirtualClusterInstance"))
        if doc.get("kind") == "VirtualClusterInstance":
            if (doc["spec"].get("templateRef") or {}).get("name") != vct["metadata"]["name"]:
                fail(f"{rel(path)}: expected a VirtualClusterInstance of {vct['metadata']['name']}")
            given = yaml.safe_load(doc["spec"].get("parameters") or "") or {}
            for p, v in given.items():
                if p not in vct_params:
                    fail(f"{rel(path)}: parameter {p!r} is not declared by the tenant cluster template")
                elif not isinstance(v, str):
                    fail(f"{rel(path)}: parameter {p} must be a quoted string, found {type(v).__name__}")
            for p, spec_p in vct_params.items():
                if spec_p.get("required") and "defaultValue" not in spec_p and p not in given:
                    fail(f"{rel(path)}: required parameter {p!r} is not set")
            continue
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
print(f"ok manifests, {counter['render']} template renders, {counter['chart']} chart renders")
CHECKS

sh "$root/tests/evaluate-test.sh" >"$work/evaluate.log" || { cat "$work/evaluate.log"; status=1; }
tail -n 1 "$work/evaluate.log"

# record-qualification.sh --create-report builds a QualificationReport the CRD accepts. Offline: with
# no cluster, the existence check fails and the dry run prints the report.
KUBECONFIG=/dev/null "$root/automation/record-qualification.sh" --report-file "$root/tests/reports/nvml-mock-ecc.json" \
  --create-report --report-machine metal3-dc1.rack-b-u18 >"$work/script.out" 2>&1 ||
  { cat "$work/script.out"; echo "FAIL record-qualification.sh --create-report" >&2; status=1; }
sed -n '/^would create QualificationReport/,/^}/p' "$work/script.out" | sed '1d' >"$work/qr.json"
python3 - "$root/recorder/chart/crds/qualificationreports.yaml" "$work/qr.json" <<'SCHEMA' || status=1
import json, sys
import yaml

crd = yaml.safe_load(open(sys.argv[1]))
schema = crd["spec"]["versions"][0]["schema"]["openAPIV3Schema"]
try:
    obj = json.load(open(sys.argv[2]))
except ValueError as e:
    sys.exit(f"FAIL record-qualification.sh --create-report printed no report: {e}")
errors = []

def check(node, sch, path):
    t = sch.get("type")
    if t == "object":
        if not isinstance(node, dict):
            return errors.append(f"{path}: not an object")
        for r in sch.get("required", []):
            if r not in node:
                errors.append(f"{path}: missing {r}")
        props, extra = sch.get("properties"), sch.get("additionalProperties")
        for k, v in node.items():
            if props is not None and k in props:
                check(v, props[k], f"{path}.{k}")
            elif isinstance(extra, dict):
                check(v, extra, f"{path}.{k}")
            elif props is not None and path != "":
                errors.append(f"{path}: unknown field {k}")
    elif t == "array":
        if not isinstance(node, list):
            return errors.append(f"{path}: not an array")
        for i, v in enumerate(node):
            check(v, sch.get("items", {}), f"{path}[{i}]")
    elif t == "string":
        if not isinstance(node, str):
            errors.append(f"{path}: not a string")
        elif "enum" in sch and node not in sch["enum"]:
            errors.append(f"{path}: {node!r} not in {sch['enum']}")
        elif sch.get("format") == "date-time" and not node:
            errors.append(f"{path}: empty date-time")
    elif t == "integer" and not isinstance(node, int):
        errors.append(f"{path}: not an integer")
    elif t == "number" and not isinstance(node, (int, float)):
        errors.append(f"{path}: not a number")

check(obj["spec"], schema["properties"]["spec"], "spec")
if obj["spec"]["machineRef"] != "metal3-dc1.rack-b-u18" or obj["spec"]["source"]["kind"] != "Stack":
    errors.append("machineRef or source.kind wrong")
if obj["metadata"]["labels"].get("qualification.vcluster-stacks.io/machine") != "metal3-dc1.rack-b-u18":
    errors.append("machine label wrong")
for e in errors:
    print(f"FAIL record-qualification.sh QualificationReport {e}", file=sys.stderr)
sys.exit(1 if errors else 0)
SCHEMA

# The GPU Burn-In dashboards: the committed JSON is what their generator writes, and every metric
# they query is one the recorder serves.
cp -R "$root/recorder/chart/dashboards" "$work/dashboards.committed"
python3 "$root/recorder/dashboards/gen_gpu_burn_in.py" >/dev/null
if ! diff -r -q "$work/dashboards.committed" "$root/recorder/chart/dashboards" >/dev/null; then
  echo "FAIL recorder/chart/dashboards is stale; rerun recorder/dashboards/gen_gpu_burn_in.py and commit it" >&2
  rm -rf "$root/recorder/chart/dashboards" && cp -R "$work/dashboards.committed" "$root/recorder/chart/dashboards"
  status=1
fi
python3 - "$root" <<'DASH' || status=1
import json, re, sys
from pathlib import Path
root = Path(sys.argv[1])
served = set(re.findall(r'NewDesc\("(gpu_qualification_[a-z_]+)"', (root / "recorder/internal/qualify/metrics.go").read_text()))
exprs = []
def walk(n):
    if isinstance(n, dict):
        for k, v in n.items():
            if k in ("expr", "query", "definition") and isinstance(v, str):
                exprs.append(v)
            walk(v)
    elif isinstance(n, list):
        for v in n:
            walk(v)
dashboards = sorted((root / "recorder/chart/dashboards").glob("*.json"))
for path in dashboards:
    walk(json.loads(path.read_text()))
uids = [json.loads(p.read_text())["uid"] for p in dashboards]
if len(set(uids)) != len(uids) or len(uids) != 3:
    print(f"FAIL expected three GPU Burn-In dashboards with distinct uids, found {uids}", file=sys.stderr)
    sys.exit(1)
bad = sorted({m for e in exprs for m in re.findall(r"gpu_qualification_[a-z_]+", e)} - served)
for m in bad:
    print(f"FAIL GPU Burn-In dashboard queries {m}, which the recorder does not serve", file=sys.stderr)
if not served:
    print("FAIL found no metrics in recorder/internal/qualify/metrics.go", file=sys.stderr)
sys.exit(1 if bad or not served else 0)
DASH
for args in "--set dashboard.enabled=false" "--set metrics.fleetObservability.enabled=true --set metrics.fleetObservability.endpoint=https://otel.example.com --set metrics.fleetObservability.cluster=c"; do
  # shellcheck disable=SC2086
  helm template r "$root/recorder/chart" $args >/dev/null || { echo "FAIL recorder chart does not render with: $args" >&2; status=1; }
done
if helm template r "$root/recorder/chart" --set metrics.fleetObservability.enabled=true >/dev/null 2>&1; then
  echo "FAIL recorder chart enables Fleet push without an endpoint and cluster" >&2
  status=1
fi

# The recorder controller and its chart.
helm lint --quiet "$root/recorder/chart" >/dev/null || { helm lint "$root/recorder/chart"; status=1; }
for args in "" "--set target=bmh --set localCluster=loft-cluster --set clusterKubeconfigs.existingSecret=c --set netbox.tokenSecret.name=n"; do
  # shellcheck disable=SC2086
  helm template r "$root/recorder/chart" $args >/dev/null || { echo "FAIL recorder chart does not render with: ${args:-defaults}" >&2; status=1; }
done
for bad in "labelDomain=gpu.vcluster.com" "target=nodes" "replicas=2"; do
  if helm template r "$root/recorder/chart" --set "$bad" >/dev/null 2>&1; then
    echo "FAIL recorder chart accepts $bad" >&2
    status=1
  fi
done
if command -v go >/dev/null; then
  (cd "$root/recorder" && test -z "$(gofmt -l .)" && go vet ./... && go test ./... >"$work/go.log") ||
    { cat "$work/go.log" 2>/dev/null; echo "FAIL recorder: gofmt, go vet or go test" >&2; status=1; }
  tail -n 1 "$work/go.log" 2>/dev/null
else
  echo "skip recorder Go checks: go not installed" >&2
fi
exit "$status"
