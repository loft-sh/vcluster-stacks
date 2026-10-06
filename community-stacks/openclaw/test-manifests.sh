#!/usr/bin/env bash
# Static checks for the OpenClaw Stack: the invariants the Platform does not validate for you.
# Modeled on certified-stacks/nvidia-dynamo/test-certified-manifests.sh in loft-sh/vcluster-stacks.
#
#   ./test-manifests.sh
#
# Needs bash >= 4, python3 with PyYAML, helm and git. Exits 1 on failures, 2 on a missing prerequisite.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

missing=()
[[ "${BASH_VERSINFO[0]}" -ge 4 ]] || missing+=("bash >= 4 (running ${BASH_VERSION}; macOS /bin/bash is 3.2, try 'brew install bash')")
for tool in python3 helm git; do
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

# ---------------------------------------------------------------------------------------------
# 1. The template, the Apps, the examples and the tenant cluster template, as YAML.
# ---------------------------------------------------------------------------------------------
python3 - "$root" "$work" <<'MANIFESTS'
import re
import sys
from pathlib import Path

import yaml

root, work = Path(sys.argv[1]), Path(sys.argv[2])
errors = []

NS = "openclaw"
STACK = "openclaw"
PART_OF = "openclaw-stack"
API = "management.loft.sh/v1"
TYPES = {"string", "multiline", "boolean", "number", "password"}
# Closed string choices render as UI options, not hand-maintained regex alternation.
SIMPLE_ENUM = re.compile(r"^\^\([a-z][a-z0-9-]*(?:\|[a-z][a-z0-9-]*)+\)\$$")
VALUES_REF = re.compile(r"\.Values\.([A-Za-z_][A-Za-z0-9_]*)")
IF_TPL = re.compile(r'\{\{-?\s*if eq \.Values\.(\w+) "([^"]+)"\s*-?\}\}(.*?)\{\{-?\s*end\s*-?\}\}', re.S)


def fail(message):
    errors.append(message)


def load_one(path):
    try:
        docs = [d for d in yaml.safe_load_all(path.read_text()) if d is not None]
    except yaml.YAMLError as e:
        fail(f"{path.relative_to(root)}: not valid YAML: {str(e).splitlines()[-1] if str(e) else e}")
        return None
    if len(docs) != 1:
        fail(f"{path.relative_to(root)}: expected exactly one YAML document, found {len(docs)}")
        return None
    return docs[0]


def seconds(duration, where):
    m = re.fullmatch(r"(\d+)(s|m|h)", str(duration))
    if not m:
        fail(f"{where}: duration {duration!r} must look like 10m")
        return None
    return int(m.group(1)) * {"s": 1, "m": 60, "h": 3600}[m.group(2)]


def check_parameters(where, params, require_section):
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
            fail(f"{where}: {v} has type {t!r}, expected one of {sorted(TYPES)}")
        if not p.get("label"):
            fail(f"{where}: {v} has no label")
        if require_section and not p.get("section"):
            fail(f"{where}: {v} has no section")
        validation = p.get("validation")
        if validation and SIMPLE_ENUM.fullmatch(validation):
            fail(f"{where}: {v} uses an enum regex; use options")
        options = [str(o) for o in (p.get("options") or [])]
        if "defaultValue" not in p:
            continue
        d = "" if p["defaultValue"] is None else str(p["defaultValue"])
        if validation and not re.fullmatch(validation, d):
            fail(f"{where}: {v} default {d!r} does not match its validation {validation!r}")
        if t == "boolean" and d not in ("true", "false"):
            fail(f"{where}: {v} is a boolean with default {d!r}")
        if t == "number":
            if not re.fullmatch(r"-?[0-9]+", d):
                fail(f"{where}: {v} is a number with default {d!r}")
            else:
                n = int(d)
                if "min" in p and n < int(p["min"]):
                    fail(f"{where}: {v} default {n} is below min {p['min']}")
                if "max" in p and n > int(p["max"]):
                    fail(f"{where}: {v} default {n} is above max {p['max']}")
        if options and d not in options:
            fail(f"{where}: {v} default {d!r} is not one of its options {options}")
        if t == "password" and d != "":
            fail(f"{where}: {v} is a password with a non-empty default")
    return by_name


# --- StackTemplate -------------------------------------------------------------------------------
st_path = root / "stacktemplate.yaml"
st_text = st_path.read_text()
st = load_one(st_path) or {}
spec = st.get("spec") or {}
if st.get("kind") != "StackTemplate" or (st.get("metadata") or {}).get("name") != STACK:
    fail(f"stacktemplate.yaml: expected StackTemplate {STACK}")
if st.get("apiVersion") != API:
    fail(f"stacktemplate.yaml: apiVersion must be {API}")
if "vcluster.com/certified" in ((st.get("metadata") or {}).get("annotations") or {}):
    fail("stacktemplate.yaml: a community stack must not carry the vcluster.com/certified annotation")
if ((st.get("metadata") or {}).get("labels") or {}).get("app.kubernetes.io/part-of") != PART_OF:
    fail(f"stacktemplate.yaml: label app.kubernetes.io/part-of must be {PART_OF}")
if "owner" in spec:
    fail("stacktemplate.yaml: spec.owner belongs on the StackInstance, not on the template")
if "icon" in spec:
    fail("stacktemplate.yaml: spec.icon is not set (no stable, licensed asset to point at)")
for key in ("displayName", "description"):
    if not spec.get(key):
        fail(f"stacktemplate.yaml: spec.{key} is required")
st_params = check_parameters("stacktemplate.yaml", spec.get("parameters"), require_section=True)
for literal in ("http://vllm.openclaw.svc:8000", "http://openclaw.openclaw.svc"):
    if literal not in st_text:
        fail(f"stacktemplate.yaml: expected the in-cluster URL {literal} (Service names are fixed in the Apps)")

# --- Apps ---------------------------------------------------------------------------------------
apps = {}
step_files = {}
for path in sorted((root / "apps").glob("*.yaml")):
    rel = path.relative_to(root)
    m = re.fullmatch(r"([0-9]{2})-([a-z0-9-]+)\.yaml", path.name)
    if not m:
        fail(f"{rel}: file name must be NN-<thing>.yaml")
        continue
    step, stem = m.group(1), m.group(2)
    step_files.setdefault(step, []).append(path)
    app = load_one(path)
    if app is None:
        continue
    if app.get("kind") != "App" or app.get("apiVersion") != API:
        fail(f"{rel}: expected kind App with apiVersion {API}")
    meta = app.get("metadata") or {}
    name = meta.get("name")
    want = f"openclaw-step-{step}-{stem}"
    if name != want:
        fail(f"{rel}: metadata.name is {name!r}, expected {want!r} (file stem and App name agree)")
    if (meta.get("labels") or {}).get("app.kubernetes.io/part-of") != PART_OF:
        fail(f"{rel}: label app.kubernetes.io/part-of must be {PART_OF}")
    if "vcluster.com/certified" in (meta.get("annotations") or {}):
        fail(f"{rel}: a community stack must not carry the vcluster.com/certified annotation")
    aspec = app.get("spec") or {}
    display = aspec.get("displayName", "")
    dm = re.fullmatch(r"\[OpenClaw Step - ([0-9]+)\] .+", display)
    if not dm or int(dm.group(1)) != int(step):
        fail(f"{rel}: displayName {display!r} must be '[OpenClaw Step - {int(step)}] <Thing>'")
    if aspec.get("defaultNamespace") != NS:
        fail(f"{rel}: defaultNamespace must be {NS} (outputs may only read namespaces the stack deploys into)")
    if "owner" in aspec:
        fail(f"{rel}: spec.owner does not belong on an App")
    config = aspec.get("config") or {}
    manifests = config.get("manifests") or ""
    if f'$ns := "{NS}"' not in manifests:
        fail(f"{rel}: manifests must pin the namespace with {{{{- $ns := \"{NS}\" }}}}")
    params = check_parameters(str(rel), aspec.get("parameters"), require_section=False)
    declared = set(params)
    refs = set(VALUES_REF.findall(manifests + (config.get("values") or "")))
    for r in sorted(refs - declared - {"__image__"}):
        fail(f"{rel}: manifests use .Values.{r}, which the App does not declare")
    for v in sorted(declared - refs):
        # A parameter may exist only so one task can feed two Apps (the -skip pattern); say so.
        if not str(params[v].get("description") or "").startswith("Ignored"):
            fail(f"{rel}: parameter {v} is declared but never used (describe it as 'Ignored ...' if it only exists so one task can feed two Apps)")
    for p in params.values():
        if p.get("type") == "password" and f".Values.{p['variable']}" in manifests:
            # A password must only ever reach a Secret.
            for line in manifests.splitlines():
                if f".Values.{p['variable']}" in line and ("ConfigMap" in line or "value:" in line):
                    fail(f"{rel}: password {p['variable']} is rendered outside a Secret: {line.strip()}")
    apps[name] = (path, app)

if sorted(step_files) != ["01", "02", "03", "04", "05"]:
    fail(f"apps/: expected steps 01 to 05, found {sorted(step_files)}")
for step, paths in sorted(step_files.items()):
    names = sorted(p.name for p in paths)
    want = 2 if step == "01" else 1
    if len(paths) != want:
        fail(f"apps/: expected {want} file(s) for step {step}, found {names}")
    if step == "01" and not any(n.endswith("-skip.yaml") for n in names):
        fail("apps/: step 01 needs its -skip twin for modelBackend external")

# --- Tasks --------------------------------------------------------------------------------------
tasks = spec.get("tasks") or []
task_by_name = {}
for t in tasks:
    n = t.get("name")
    if not n:
        fail("stacktemplate.yaml: task without a name")
        continue
    if n in task_by_name:
        fail(f"stacktemplate.yaml: duplicate task {n}")
    task_by_name[n] = t
if len(tasks) > 20:
    fail("stacktemplate.yaml: a stack supports at most 20 tasks")

for t in tasks:
    for d in t.get("dependsOn") or []:
        if d not in task_by_name:
            fail(f"stacktemplate.yaml task {t.get('name')}: dependsOn {d!r} is not a task")


def has_cycle():
    state = {}

    def visit(n):
        if state.get(n) == 1:
            return True
        if state.get(n) == 2:
            return False
        state[n] = 1
        for d in task_by_name.get(n, {}).get("dependsOn") or []:
            if d in task_by_name and visit(d):
                return True
        state[n] = 2
        return False

    return any(visit(n) for n in task_by_name)


if has_cycle():
    fail("stacktemplate.yaml: dependsOn forms a cycle")


def candidate_apps(ref, where):
    m = IF_TPL.search(ref)
    if not m:
        return {ref}
    var, val, body = m.groups()
    p = st_params.get(var)
    if not p:
        fail(f"{where}: templateRef conditions on undeclared parameter {var}")
        return set()
    options = [str(o) for o in (p.get("options") or [])]
    if val not in options:
        fail(f"{where}: templateRef conditions on {var} == {val!r}, which is not one of its options {options}")
        return set()
    return {ref[: m.start()] + (body if o == val else "") + ref[m.end():] for o in options}


used_params = set()
for t in tasks:
    n = t.get("name")
    where = f"stacktemplate.yaml task {n}"
    app_task = t.get("app")
    if not app_task:
        fail(f"{where}: only App tasks are used in this stack")
        continue
    if "template" in app_task:
        fail(f"{where}: inline templates are not used here; reference an App in apps/")
        continue
    ref = (app_task.get("templateRef") or {}).get("name") or ""
    passed = app_task.get("parameters") or {}
    for k, v in passed.items():
        if not isinstance(v, str):
            fail(f"{where}: parameter {k} must be a quoted string, got {type(v).__name__}")
    joined = " ".join(str(v) for v in passed.values()) + " " + ref
    for r in VALUES_REF.findall(joined):
        if r not in st_params:
            fail(f"{where}: references undeclared .Values.{r}")
        used_params.add(r)
    for src, _out in re.findall(r"\.Outputs\.(\w+)\.(\w+)", joined):
        if src not in (t.get("dependsOn") or []):
            fail(f"{where}: uses .Outputs.{src} without depending on task {src}")
    task_timeout = seconds(t.get("timeout", "10m"), where)
    for app_name in sorted(candidate_apps(ref, where)):
        if app_name not in apps:
            fail(f"{where}: templateRef {app_name!r} is not an App in apps/")
            continue
        apath, app = apps[app_name]
        aspec = app["spec"]
        app_params = {p["variable"]: p for p in aspec.get("parameters") or []}
        for k in sorted(set(app_params) - set(passed)):
            fail(f"{where}: does not pass {k}, which {app_name} declares (it would arrive empty, not defaulted)")
        for k in sorted(set(passed) - set(app_params)):
            fail(f"{where}: passes {k}, which {app_name} does not declare")
        for k, v in passed.items():
            m = re.fullmatch(r"\s*\{\{\s*\.Values\.(\w+)\s*\}\}\s*", str(v))
            if not m or k not in app_params:
                continue
            tp, ap = st_params.get(m.group(1)), app_params[k]
            if not tp:
                continue
            if tp.get("type") != ap.get("type"):
                fail(f"{where}: {k} has type {ap.get('type')} in {app_name} but {tp.get('type')} in the template")
            if (tp.get("options") or ap.get("options")) and tp.get("options") != ap.get("options"):
                fail(f"{where}: {k} options differ between the template and {app_name}")
            if ap.get("validation") and ap.get("validation") != tp.get("validation"):
                fail(f"{where}: {k} validation differs between the template and {app_name}")
            if re.search(r"(Image|Version)$", m.group(1)) and str(tp.get("defaultValue")) != str(ap.get("defaultValue")):
                fail(f"{where}: default for {m.group(1)} differs between the template and {app_name}; one version bump must update both")
        if aspec.get("wait"):
            if "timeout" not in aspec:
                fail(f"{apath.name}: wait is true but no timeout is set, so Helm would use its 5m default")
            else:
                a = seconds(aspec["timeout"], apath.name)
                if a is not None and task_timeout is not None and a >= task_timeout:
                    fail(f"{where}: App timeout {aspec['timeout']} must be below the task timeout {t.get('timeout', '10m')} so Helm's error is reported")
        if app_name == "openclaw-step-01-vllm" and aspec.get("wait"):
            fail("apps/01-vllm.yaml: must keep wait: false; the model-ready gate is what waits")
        if app_name == "openclaw-step-02-model-ready":
            a = seconds(aspec.get("timeout", "5m"), apath.name)
            deadlines = [int(x) for x in re.findall(r"[0-9]+", str(passed.get("deadlineSeconds", "")))]
            if app_params.get("deadlineSeconds", {}).get("defaultValue") is not None:
                deadlines.append(int(app_params["deadlineSeconds"]["defaultValue"]))
            for d in deadlines:
                if d > 1740:
                    fail(f"{where}: deadlineSeconds {d} exceeds the Platform's 30 minute deploy cap (1740)")
                if a is not None and d >= a:
                    fail(f"{where}: deadlineSeconds {d} must be below the App timeout {aspec.get('timeout')}")
    outputs = t.get("outputs") or []
    if outputs and not re.fullmatch(r"[a-z0-9]+", n):
        fail(f"{where}: declares outputs, so its name may contain only lowercase letters and digits")
    seen = set()
    for o in outputs:
        on = o.get("name") or ""
        if not re.fullmatch(r"[a-z0-9]+", on):
            fail(f"{where}: output name {on!r} may contain only lowercase letters and digits")
        if on in seen:
            fail(f"{where}: duplicate output {on}")
        seen.add(on)
        src = o.get("fromResource") or o.get("fromSecret")
        if not src:
            fail(f"{where}: output {on} has neither fromResource nor fromSecret")
            continue
        if "fromResource" in o and o["fromResource"].get("kind") == "Secret":
            fail(f"{where}: output {on} reads a Secret with fromResource; use fromSecret")
        if src.get("namespace") != NS:
            fail(f"{where}: output {on} reads namespace {src.get('namespace')!r}; the stack only deploys into {NS}")

for v in sorted(set(st_params) - used_params):
    fail(f"stacktemplate.yaml: parameter {v} is not used by any task")

seen = set()
for po in spec.get("publishedOutputs") or []:
    pn = po.get("name") or ""
    if not re.fullmatch(r"[a-z][a-zA-Z0-9]*", pn):
        fail(f"stacktemplate.yaml: published output {pn!r} must be camelCase")
    if pn in seen:
        fail(f"stacktemplate.yaml: duplicate published output {pn}")
    seen.add(pn)
    ft = po.get("fromTask") or {}
    task = task_by_name.get(ft.get("task"))
    if not task:
        fail(f"stacktemplate.yaml: published output {pn} references unknown task {ft.get('task')!r}")
        continue
    if ft.get("output") not in {o.get("name") for o in task.get("outputs") or []}:
        fail(f"stacktemplate.yaml: published output {pn} references unknown output {ft.get('output')!r} of task {ft.get('task')}")

# --- Examples -----------------------------------------------------------------------------------
examples = sorted((root / "example").glob("*.yaml"))
if not examples:
    fail("example/: at least one example StackInstance is required")
for ex in examples:
    rel = ex.relative_to(root)
    try:
        docs = [d for d in yaml.safe_load_all(ex.read_text()) if d is not None]
    except yaml.YAMLError as e:
        fail(f"{rel}: not valid YAML: {str(e).splitlines()[-1] if str(e) else e}")
        continue
    if not docs:
        fail(f"{rel}: empty")
        continue
    # A supporting manifest (such as the llama.cpp endpoint) is plain Kubernetes YAML: every
    # document needs a kind and a name, and the StackInstance rules below do not apply.
    if not any(d.get("kind") == "StackInstance" for d in docs):
        for d in docs:
            if not d.get("kind") or not (d.get("metadata") or {}).get("name"):
                fail(f"{rel}: every document needs kind and metadata.name")
        continue
    if len(docs) != 1:
        fail(f"{rel}: a StackInstance example must be a single document")
        continue
    inst = docs[0]
    ispec = inst.get("spec") or {}
    if (ispec.get("templateRef") or {}).get("name") != STACK:
        fail(f"{rel}: expected a StackInstance of {STACK}")
        continue
    if (inst.get("metadata") or {}).get("namespace"):
        fail(f"{rel}: do not set metadata.namespace; the README applies examples with -n <project namespace>")
    if not ispec.get("owner"):
        fail(f"{rel}: spec.owner is required (App tasks deploy as the owner)")
    if not ispec.get("prunePolicy"):
        fail(f"{rel}: set prunePolicy explicitly")
    uncommented = re.sub(r"#.*", "", ex.read_text())
    if re.search(r"<[A-Z_]+>", uncommented):
        fail(f"{rel}: contains a <PLACEHOLDER> that does not apply cleanly; use documentation values")
    params = ispec.get("parameters") or {}
    for k, v in params.items():
        p = st_params.get(k)
        if not p:
            fail(f"{rel}: parameter {k} is not declared by the template")
            continue
        v = "" if v is None else str(v)
        if p.get("validation") and not re.fullmatch(p["validation"], v):
            fail(f"{rel}: {k}={v!r} does not match {p['validation']!r}")
        if p.get("options") and v not in [str(o) for o in p["options"]]:
            fail(f"{rel}: {k}={v!r} is not one of {p['options']}")
        if p.get("type") == "boolean" and v not in ("true", "false"):
            fail(f"{rel}: {k} must be \"true\" or \"false\"")
        if p.get("type") == "number" and not re.fullmatch(r"-?[0-9]+", v):
            fail(f"{rel}: {k} must be a whole number")
        if p.get("type") == "password" and v:
            fail(f"{rel}: password parameter {k} must not carry a value in a committed example")
    if params.get("accessMode") == "nodeport" and not params.get("allowedCidr"):
        fail(f"{rel}: nodeport mode with an empty allowedCidr denies everyone")
    if params.get("accessMode") == "ingress" and not params.get("ingressHost"):
        fail(f"{rel}: ingress mode needs ingressHost")
    if params.get("modelBackend") == "external" and not params.get("externalBaseUrl"):
        fail(f"{rel}: external backend needs externalBaseUrl")

# --- VirtualClusterTemplate ---------------------------------------------------------------------
vct_path = root / "virtualclustertemplate.yaml"
if vct_path.exists():
    vct = load_one(vct_path) or {}
    vspec = vct.get("spec") or {}
    if vct.get("kind") != "VirtualClusterTemplate" or vct.get("apiVersion") != API:
        fail(f"virtualclustertemplate.yaml: expected VirtualClusterTemplate with apiVersion {API}")
    vparams = check_parameters("virtualclustertemplate.yaml", vspec.get("parameters"), require_section=False)
    template = vspec.get("template") or {}
    # The Platform rejects a template without one: "chart version is required" (seen on 4.13).
    chart_version = str(((template.get("helmRelease") or {}).get("chart") or {}).get("version") or "")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?", chart_version):
        fail(f"virtualclustertemplate.yaml: helmRelease.chart.version must pin a vCluster version, got {chart_version!r}")
    values = (template.get("helmRelease") or {}).get("values") or ""
    for r in sorted(set(VALUES_REF.findall(values)) - set(vparams)):
        fail(f"virtualclustertemplate.yaml: values use .Values.{r}, which is not a template parameter")
    labels = ((template.get("instanceTemplate") or {}).get("metadata") or {}).get("labels") or {}
    if labels.get("loft.sh/stacks-sync") != "true":
        fail('virtualclustertemplate.yaml: instanceTemplate needs the label loft.sh/stacks-sync: "true"')
    if re.search(r"^\s+inputs:", values, re.M):
        fail("virtualclustertemplate.yaml: deploy.stacks entries take `parameters`, not `inputs`")
    if "templateRef:" not in values or f"name: {STACK}" not in values:
        fail(f"virtualclustertemplate.yaml: deploy.stacks must reference StackTemplate {STACK}")
    block = re.search(r"^(\s*)parameters:\s*\n((?:\1\s+\S.*\n?)+)", values, re.M)
    if not block:
        fail("virtualclustertemplate.yaml: deploy.stacks entry has no parameters block")
    else:
        for key in re.findall(r"^\s+([A-Za-z]\w*):", block.group(2), re.M):
            if key not in st_params:
                fail(f"virtualclustertemplate.yaml: deploy.stacks passes {key}, which the StackTemplate does not declare")

# --- Charts for the render step -----------------------------------------------------------------
# Values that a branch needs to render at all, applied to every variant.
FILL = {"externalBaseUrl": "https://api.example.com/v1", "ingressHost": "claw.example.com"}
VARIANTS = {
    "default": {},
    "nodeport-external-hostpath": {
        "accessMode": "nodeport", "allowedCidr": "203.0.113.7/32", "modelBackend": "external",
        "externalApiKey": "placeholder", "modelCache": "hostPath", "hfToken": "placeholder",
        "telegramBotToken": "placeholder", "telegramAllowFrom": "123, 456", "storageClass": "standard",
        "modelCacheStorageClass": "standard", "runtimeClassName": "nvidia", "requireCpuNode": "true",
        "gpuCount": "2",
    },
    "ingress-emptydir": {
        "accessMode": "ingress", "ingressClassName": "nginx", "ingressTlsSecret": "claw-tls",
        "ingressScheme": "https",
        "ingressAnnotations": 'nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"',
        "modelCache": "emptyDir", "modelVision": "false", "modelReasoning": "false", "thinkingFormat": "",
        "userTimezone": "Europe/Berlin", "vllmEnv": "", "vllmExtraArgs": "",
    },
}
for name, (path, app) in apps.items():
    chart = work / "apps" / name
    (chart / "templates").mkdir(parents=True)
    (chart / "Chart.yaml").write_text(f"apiVersion: v2\nname: {name}\nversion: 0.1.0\n")
    (chart / "templates" / "manifests.yaml").write_text((app["spec"].get("config") or {}).get("manifests") or "")
    declared = {
        p["variable"]: ("" if p.get("defaultValue") is None else str(p["defaultValue"]))
        for p in app["spec"].get("parameters") or []
    }
    base = dict(declared)
    base.update({k: v for k, v in FILL.items() if k in declared})
    base["__image__"] = "ghcr.io/loft-sh/loft:0.0.0"
    for variant, overrides in VARIANTS.items():
        values = dict(base)
        values.update({k: v for k, v in overrides.items() if k in declared})
        (chart / f"values-{variant}.yaml").write_text(yaml.safe_dump(values))

if errors:
    for error in errors:
        print(f"FAIL {error}", file=sys.stderr)
    sys.exit(1)
MANIFESTS
echo "ok manifests"

# ---------------------------------------------------------------------------------------------
# 2. Every App renders with Helm, with its declared defaults and with values that take the other
#    branch of every {{ if }}; everything rendered is namespaced into openclaw.
# ---------------------------------------------------------------------------------------------
status=0
for chart in "$work"/apps/*/; do
  name=$(basename "$chart")
  for values in "$chart"/values-*.yaml; do
    variant=$(basename "$values" .yaml); variant=${variant#values-}
    if ! helm template "oc-${name#openclaw-step-}" "$chart" --namespace openclaw -f "$values" \
        > "$chart/rendered-$variant.yaml" 2> "$chart/helm-$variant.err"; then
      echo "FAIL $name ($variant) does not render:" >&2
      sed 's/^/     /' "$chart/helm-$variant.err" >&2
      status=1
    fi
  done
done
[[ "$status" -eq 0 ]] || exit 1

python3 - "$work" <<'RENDERED'
import json
import sys
from pathlib import Path

import yaml

work = Path(sys.argv[1])
errors = []
NS = "openclaw"
for chart in sorted((work / "apps").iterdir()):
    name = chart.name
    for rendered in sorted(chart.glob("rendered-*.yaml")):
        variant = rendered.stem[len("rendered-"):]
        try:
            docs = [d for d in yaml.safe_load_all(rendered.read_text()) if d]
        except yaml.YAMLError as e:
            errors.append(f"{name} ({variant}): rendered output is not valid YAML: {e}")
            continue
        if not docs:
            errors.append(f"{name} ({variant}): rendered nothing")
        kinds = set()
        for d in docs:
            md = d.get("metadata") or {}
            kinds.add((d.get("kind"), md.get("name")))
            if md.get("namespace") != NS:
                errors.append(f"{name} ({variant}): {d.get('kind')} {md.get('name')} is in namespace {md.get('namespace')!r}, expected {NS}")
        # The managed OpenClaw config is JSON assembled from conditional fragments; a stray comma
        # would only surface as a crashlooping gateway.
        for d in docs:
            if d.get("kind") == "ConfigMap" and (d.get("metadata") or {}).get("name") == "openclaw-bootstrap":
                try:
                    json.loads(d["data"]["managed.json"])
                except (KeyError, ValueError) as e:
                    errors.append(f"{name} ({variant}): managed.json is not valid JSON: {e}")
        if name == "openclaw-step-01-vllm" and ("Service", "vllm") not in kinds:
            errors.append(f"{name} ({variant}): Service vllm did not render; the template hardcodes vllm.openclaw.svc")
        if name == "openclaw-step-04-gateway" and ("Service", "openclaw") not in kinds:
            errors.append(f"{name} ({variant}): Service openclaw did not render; the template hardcodes openclaw.openclaw.svc")
if errors:
    for error in errors:
        print(f"FAIL {error}", file=sys.stderr)
    sys.exit(1)
RENDERED
echo "ok render"

# ---------------------------------------------------------------------------------------------
# 3. Nothing secret or site-specific is tracked.
# ---------------------------------------------------------------------------------------------
python3 - "$root" <<'SECRETS'
import ipaddress
import re
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1])
errors = []
files = subprocess.run(["git", "-C", str(root), "ls-files"], capture_output=True, text=True, check=True).stdout.split()
if "my-instance.yaml" in files:
    errors.append("my-instance.yaml is tracked; it carries the operator's own values")
PATTERNS = {
    "Telegram bot token": r"\b[0-9]{8,10}:[A-Za-z0-9_-]{35}\b",
    "Hugging Face token": r"\bhf_[A-Za-z0-9]{30,}\b",
    "private key": r"BEGIN [A-Z ]*PRIVATE KEY",
    "AWS access key": r"\bAKIA[0-9A-Z]{16}\b",
    "GitHub token": r"\bghp_[A-Za-z0-9]{36}\b",
}
ALLOWED = [ipaddress.ip_network(n) for n in (
    "127.0.0.0/8", "0.0.0.0/32", "169.254.169.254/32",
    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
    "192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24",
)]
IPV4 = re.compile(r"(?<![\w.])((?:[0-9]{1,3}\.){3}[0-9]{1,3})(?![\w.])")
for f in files:
    try:
        text = (root / f).read_text()
    except (UnicodeDecodeError, FileNotFoundError):
        continue
    for label, pattern in PATTERNS.items():
        for m in re.finditer(pattern, text):
            errors.append(f"{f}: looks like a {label}: {m.group(0)[:10]}...")
    for m in IPV4.finditer(text):
        try:
            ip = ipaddress.ip_address(m.group(1))
        except ValueError:
            continue
        if not any(ip in n for n in ALLOWED):
            errors.append(f"{f}: IP address {ip} is outside loopback, RFC 1918 and the documentation ranges")
if errors:
    for error in errors:
        print(f"FAIL {error}", file=sys.stderr)
    sys.exit(1)
SECRETS
echo "ok secrets"
echo "all checks passed"
