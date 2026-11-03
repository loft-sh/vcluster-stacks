#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

missing=()
for tool in python3 helm git; do
  command -v "$tool" >/dev/null || missing+=("$tool")
done
command -v python3 >/dev/null && { python3 -c 'import yaml' 2>/dev/null || missing+=("PyYAML (python3 -m pip install pyyaml); needed to verify the manifests parse as YAML"); }
if [[ "${#missing[@]}" -gt 0 ]]; then
  echo "cannot run: missing prerequisite(s)" >&2
  printf '  - %s\n' "${missing[@]}" >&2
  exit 2
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Static checks on the StackTemplate, the Apps, the tenant cluster templates and the example, then
# write what the render checks below need: each chart task's values with the Stack's parameters and
# the verify task's outputs substituted, and the verify App's manifests as a Helm chart.
python3 - "$root" "$work" <<'MANIFESTS'
import re
import sys
from pathlib import Path

import yaml

root, work = Path(sys.argv[1]), Path(sys.argv[2])
errors = []
NAME = "nvidia-nvke-mgmt"
TASKS = ["verify", "certmanager", "baseconfig", "nktp", "postgres", "spirecrds", "temporal", "spire", "controller"]
CHART_TASKS = ["certmanager", "nktp", "postgres", "spirecrds", "temporal", "spire", "controller"]
CREDENTIALS = {"registryPassword", "dbPassword"}


def load(path):
    return yaml.safe_load((root / path).read_text())


def minutes(where, duration):
    match = re.fullmatch(r"(\d+)m", str(duration))
    if not match:
        errors.append(f"{where}: timeout {duration!r} must be whole minutes, like 20m")
        return None
    return int(match.group(1))


apps = {}
for path in sorted((root / "apps").glob("*.yaml")):
    app = load(f"apps/{path.name}")
    if app.get("apiVersion") != "management.loft.sh/v1" or app.get("kind") != "App":
        errors.append(f"apps/{path.name}: expected an App on management.loft.sh/v1")
        continue
    name = app["metadata"]["name"]
    if not name.startswith(NAME + "-"):
        errors.append(f"apps/{path.name}: App name {name!r} must start with {NAME}-")
    if "annotations" in app["metadata"] and "vcluster.com/certified" in app["metadata"]["annotations"]:
        errors.append(f"apps/{path.name}: the certified annotation belongs on the StackTemplate only")
    spec = app["spec"]
    if spec.get("wait") and minutes(f"apps/{path.name}", spec.get("timeout", "")) is None:
        pass
    for parameter in spec.get("parameters", []):
        if parameter["variable"] in CREDENTIALS and "defaultValue" in parameter:
            errors.append(f"apps/{path.name}: credential parameter {parameter['variable']} has a default")
    apps[name] = {"path": f"apps/{path.name}", "spec": spec, "parameters": {p["variable"] for p in spec.get("parameters", [])}}

template = load("stacktemplate.yaml")
if template.get("apiVersion") != "management.loft.sh/v1" or template.get("kind") != "StackTemplate" or template["metadata"].get("name") != NAME:
    errors.append(f"stacktemplate.yaml: expected StackTemplate {NAME} on management.loft.sh/v1")
if (template["metadata"].get("annotations") or {}).get("vcluster.com/certified") != "true":
    errors.append('stacktemplate.yaml: missing annotation vcluster.com/certified: "true"')

parameters = {p["variable"]: p for p in template["spec"].get("parameters", [])}
for variable, parameter in parameters.items():
    default = parameter.get("defaultValue")
    if variable in CREDENTIALS and default is not None:
        errors.append(f"stacktemplate.yaml: credential parameter {variable} has a default")
    if default is not None and not isinstance(default, str):
        errors.append(f"stacktemplate.yaml: {variable} defaultValue must be a string (YAML booleans like off need quotes)")
    if "options" in parameter and any(not isinstance(o, str) for o in parameter["options"]):
        errors.append(f"stacktemplate.yaml: {variable} options must all be strings (quote off/on/yes/no)")
    validation = parameter.get("validation")
    if validation and default not in (None, "") and not re.fullmatch(validation, str(default)):
        errors.append(f"stacktemplate.yaml: {variable} default {default!r} does not match {validation!r}")
for variable in ("verifyMode", "sharedNodes"):
    if variable in parameters and "options" not in parameters[variable]:
        errors.append(f"stacktemplate.yaml: {variable} must use options, not a regex alternation")

tasks = template["spec"]["tasks"]
names = [task["name"] for task in tasks]
if names != TASKS:
    errors.append(f"stacktemplate.yaml: expected tasks {TASKS}, found {names}")
by_name = {task["name"]: task for task in tasks}

# Dependency graph: every edge resolves, no cycles, and verify gates everything.
for task in tasks:
    for dependency in task.get("dependsOn", []):
        if dependency not in by_name:
            errors.append(f"stacktemplate.yaml: task {task['name']} depends on unknown task {dependency}")
    if task["name"] != "verify" and "verify" not in set(task.get("dependsOn", [])) and task["name"] not in ("certmanager", "baseconfig"):
        # Chart tasks consume verify's outputs, so they must list verify directly (admission rule).
        errors.append(f"stacktemplate.yaml: task {task['name']} must list verify in dependsOn")


def reaches(start, target, seen=()):
    if start == target:
        return True
    return any(reaches(d, target, seen + (start,)) for d in by_name[start].get("dependsOn", []) if d in by_name and d not in seen)


for task in tasks:
    if any(reaches(d, task["name"]) for d in task.get("dependsOn", []) if d in by_name):
        errors.append(f"stacktemplate.yaml: dependency cycle through {task['name']}")
    if task["name"] != "verify" and not reaches(task["name"], "verify"):
        errors.append(f"stacktemplate.yaml: task {task['name']} is not gated by verify")

# Outputs: only on verify, hyphen-free names, each read from the verify App's namespace; published
# outputs and every {{ .Outputs.x.y }} reference a declared output of a listed dependency.
declared_outputs = {}
for task in tasks:
    outputs = task.get("outputs", [])
    if outputs and task["name"] != "verify":
        errors.append(f"stacktemplate.yaml: only verify declares outputs, found some on {task['name']}")
    if outputs and "-" in task["name"]:
        errors.append(f"stacktemplate.yaml: task {task['name']} declares outputs but its name contains a hyphen")
    for output in outputs:
        if not re.fullmatch(r"[a-z0-9]+", output["name"]):
            errors.append(f"stacktemplate.yaml: output {output['name']} must be lowercase letters and digits")
        source = output.get("fromResource") or {}
        if source.get("kind") == "Secret":
            errors.append(f"stacktemplate.yaml: output {output['name']} reads a Secret with fromResource; use fromSecret")
        if source.get("namespace") != apps[NAME + "-verify"]["spec"]["defaultNamespace"]:
            errors.append(f"stacktemplate.yaml: output {output['name']} must read from the verify App's namespace")
        declared_outputs.setdefault(task["name"], set()).add(output["name"])
for published in template["spec"].get("publishedOutputs", []):
    source = published["fromTask"]
    if source["output"] not in declared_outputs.get(source["task"], set()):
        errors.append(f"stacktemplate.yaml: publishedOutput {published['name']} references undeclared {source['task']}.{source['output']}")

task_text = {task["name"]: yaml.safe_dump(task) for task in tasks}
for task in tasks:
    text = task_text[task["name"]]
    for variable in set(re.findall(r"\.Values\.(\w+)", text)):
        if variable not in parameters:
            errors.append(f"stacktemplate.yaml: task {task['name']} references undeclared parameter {variable}")
    for owner, output in set(re.findall(r"\.Outputs\.(\w+)\.(\w+)", text)):
        if output not in declared_outputs.get(owner, set()):
            errors.append(f"stacktemplate.yaml: task {task['name']} references undeclared output {owner}.{output}")
        if owner not in task.get("dependsOn", []):
            errors.append(f"stacktemplate.yaml: task {task['name']} uses {owner}.{output} but does not list {owner} in dependsOn")
    if re.search(r"\{\{[^}]*\.Outputs[^}]*\.Values[^}]*\}\}|\{\{[^}]*\.Values[^}]*\.Outputs[^}]*\}\}", text):
        errors.append(f"stacktemplate.yaml: task {task['name']} mixes .Values and .Outputs in one action")

# Task shapes: referenced Apps exist here and receive every parameter they declare; inline chart
# tasks wait with Helm timeouts below their task timeouts.
values_for_render = {}
for task in tasks:
    app = task["app"]
    where = f"stacktemplate.yaml task {task['name']}"
    task_minutes = minutes(where, task.get("timeout", ""))
    if "templateRef" in app:
        ref = app["templateRef"]["name"]
        if ref not in apps:
            errors.append(f"{where}: templateRef {ref} is not an App in apps/")
            continue
        passed = set((app.get("parameters") or {}).keys())
        declared = apps[ref]["parameters"]
        if passed != declared:
            errors.append(f"{where}: passes {sorted(passed)} but App {ref} declares {sorted(declared)} (Stack tasks apply no App defaults)")
        app_minutes = minutes(apps[ref]["path"], apps[ref]["spec"].get("timeout", ""))
        if app_minutes is not None and task_minutes is not None and app_minutes >= task_minutes:
            errors.append(f"{where}: App timeout {apps[ref]['spec']['timeout']} must be below the task timeout {task['timeout']}")
    else:
        spec = app["template"]["spec"]
        if not spec.get("wait"):
            errors.append(f"{where}: inline chart task must wait")
        app_minutes = minutes(where, spec.get("timeout", ""))
        if app_minutes is not None and task_minutes is not None and app_minutes >= task_minutes:
            errors.append(f"{where}: Helm timeout {spec['timeout']} must be below the task timeout {task['timeout']}")
        if app_minutes is not None and app_minutes >= 30:
            errors.append(f"{where}: App deploys stop at 30 minutes; Helm timeout {spec['timeout']} is too long")
        chart = spec["config"]["chart"]
        if not chart.get("repoURL", "").startswith(("oci://", "https://")):
            errors.append(f"{where}: chart repoURL must be oci:// or https://")
        values_for_render[task["name"]] = {"chart": chart, "namespace": spec.get("defaultNamespace", ""), "release": spec.get("releaseName", task["name"]), "values": spec["config"].get("values", "")}

# Tenant cluster templates: pin vCluster, forward every Stack parameter or set it, pass only declared ones.
for path in ("virtualclustertemplate-shared-nodes.yaml", "virtualclustertemplate-private-nodes.yaml"):
    vct = load(path)
    if vct.get("apiVersion") != "management.loft.sh/v1" or vct.get("kind") != "VirtualClusterTemplate" or not vct["metadata"]["name"].startswith(NAME + "-"):
        errors.append(f"{path}: expected a VirtualClusterTemplate named {NAME}-*")
        continue
    chart = vct["spec"]["template"].get("helmRelease", {}).get("chart", {})
    if not re.fullmatch(r"\d+\.\d+\.\d+", str(chart.get("version", ""))):
        errors.append(f"{path}: helmRelease.chart.version must pin a vCluster release")
    values = vct["spec"]["template"]["helmRelease"]["values"]
    stacks = re.search(r"templateRef:\s*\n\s*name: (\S+)", values)
    if not stacks or stacks.group(1) != NAME:
        errors.append(f"{path}: deploy.stacks must reference {NAME}")
    block = re.search(r"^( *)parameters:\n((?:\1 +\S.*\n?)+)", values, re.M)
    stack_params = dict(re.findall(r"^\s*(\w+): (.*)$", block.group(2), re.M)) if block else {}
    for variable in stack_params:
        if variable not in parameters:
            errors.append(f"{path}: passes undeclared Stack parameter {variable}")
    for variable, parameter in parameters.items():
        if parameter.get("required") and "defaultValue" not in parameter and variable not in stack_params:
            errors.append(f"{path}: required Stack parameter {variable} is neither forwarded nor set")
    vct_params = {p["variable"] for p in vct["spec"].get("parameters", [])}
    for variable in set(re.findall(r"\.Values\.(\w+)", values)):
        if variable not in vct_params:
            errors.append(f"{path}: values reference undeclared template parameter {variable}")
    for parameter in vct["spec"].get("parameters", []):
        if parameter["variable"] in CREDENTIALS and "defaultValue" in parameter:
            errors.append(f"{path}: credential parameter {parameter['variable']} has a default")
    expected_shared = "true" if "shared" in path else "false"
    if stack_params.get("sharedNodes", "").strip('"') != expected_shared:
        errors.append(f"{path}: must set sharedNodes to \"{expected_shared}\"")

# Example: references the template, only declared parameters, no real credentials.
for example in sorted((root / "example").glob("*.yaml")):
    instance = load(f"example/{example.name}")
    where = f"example/{example.name}"
    if instance.get("kind") != "StackInstance" or instance["spec"].get("templateRef", {}).get("name") != NAME:
        errors.append(f"{where}: expected a StackInstance of {NAME}")
        continue
    for variable, value in (instance["spec"].get("parameters") or {}).items():
        if variable not in parameters:
            errors.append(f"{where}: parameter {variable!r} is not declared by the template")
        elif variable in CREDENTIALS and not str(value).startswith("<"):
            errors.append(f"{where}: {variable} must be a <placeholder>")
    text = example.read_text()
    if re.search(r"gh[ops]_[A-Za-z0-9]{20,}", text) or re.search(r"sha256:(?!0{64})[0-9a-f]{64}", text):
        errors.append(f"{where}: contains what looks like a real token or digest")

if errors:
    for error in errors:
        print(f"FAIL {error}", file=sys.stderr)
    sys.exit(1)

# Render inputs. Parameters take their defaults or a plausible placeholder; verify's outputs take
# the versions NVKE v0.22.0 pins, so each chart renders exactly as the Stack would install it.
placeholders = {v: p.get("defaultValue", "") for v, p in parameters.items()}
placeholders.update({"releaseRoot": "registry.example/nvke/releases@sha256:" + "0" * 64, "registryPrefix": "registry.example/nvke",
                     "registryUsername": "user", "registryPassword": "secret", "dbPassword": "database-password", "storageClass": ""})
outputs = {"nktpversion": "0.22.0", "postgresqlversion": "18.5.15", "spirecrdsversion": "0.6.1", "spireversion": "0.30.1",
           "temporalversion": "0.74.0", "controllerchartversion": "0.22.0", "profilesdigest": "sha256:" + "1" * 64, "cwedigest": "sha256:" + "2" * 64}


def render(text, shared):
    values = dict(placeholders, sharedNodes=shared)
    text = re.sub(r'\{\{ if eq \.Values\.sharedNodes "true" \}\}(.*?)\{\{ else \}\}(.*?)\{\{ end \}\}', lambda m: m.group(1) if shared == "true" else m.group(2), text)
    text = re.sub(r"\{\{\s*\.Values\.(\w+)\s*\}\}", lambda m: str(values[m.group(1)]), text)
    return re.sub(r"\{\{\s*\.Outputs\.verify\.(\w+)\s*\}\}", lambda m: outputs[m.group(1)], text)


for name, entry in values_for_render.items():
    for shared in ("false", "true"):
        d = work / f"{name}-{shared}"
        d.mkdir()
        chart = entry["chart"]
        (d / "chart").write_text("\n".join([render(chart["name"], shared), render(chart["repoURL"], shared), render(chart["version"], shared), entry["namespace"], entry["release"]]) + "\n")
        (d / "values.yaml").write_text(render(entry["values"], shared))
        if "{{" in (d / "values.yaml").read_text():
            print(f"FAIL {name}: unrendered template action in values", file=sys.stderr)
            sys.exit(1)

# The verify App as a chart: the Platform renders config.manifests with Helm and the parameters the task passes.
verify = apps[NAME + "-verify"]["spec"]
chart_dir = work / "verify-chart"
(chart_dir / "templates").mkdir(parents=True)
(chart_dir / "Chart.yaml").write_text("apiVersion: v2\nname: verify\nversion: 0.0.1\n")
(chart_dir / "templates" / "manifests.yaml").write_text(verify["config"]["manifests"])
params = {p: placeholders.get(p, "x") for p in apps[NAME + "-verify"]["parameters"]}
params["__image__"] = "ghcr.io/loft-sh/vcluster-platform:test"
params["verifyMode"] = "root"
params["signerIdentity"] = "^https://example/.*$"
params["oidcIssuer"] = "https://token.actions.githubusercontent.com"
(chart_dir / "values.yaml").write_text(yaml.safe_dump(params))
base = apps[NAME + "-base-config"]["spec"]
base_dir = work / "base-chart"
(base_dir / "templates").mkdir(parents=True)
(base_dir / "Chart.yaml").write_text("apiVersion: v2\nname: base\nversion: 0.0.1\n")
(base_dir / "templates" / "manifests.yaml").write_text(base["config"]["manifests"])
(base_dir / "values.yaml").write_text(yaml.safe_dump({p: placeholders.get(p, "x") for p in apps[NAME + "-base-config"]["parameters"]}))
MANIFESTS
echo "ok manifests"

# The verify App: one Job on the Platform image, RBAC limited to its ConfigMap, a script sh accepts.
helm template verify "$work/verify-chart" --namespace nvke-verify > "$work/verify.yaml"
python3 - "$work" <<'VERIFY'
import re
import subprocess
import sys
from pathlib import Path

import yaml

work = Path(sys.argv[1])
docs = [d for d in yaml.safe_load_all((work / "verify.yaml").read_text()) if d]
kinds = sorted(d["kind"] for d in docs)
if kinds != ["ConfigMap", "Job", "Role", "RoleBinding", "Secret", "ServiceAccount"]:
    print(f"FAIL verify renders {kinds}", file=sys.stderr)
    sys.exit(1)
role = next(d for d in docs if d["kind"] == "Role")
if [sorted(r["resources"]) for r in role["rules"]] != [["configmaps"]] or any("resourceNames" not in r for r in role["rules"]):
    print("FAIL verify Role must be limited to its ConfigMap", file=sys.stderr)
    sys.exit(1)
job = next(d for d in docs if d["kind"] == "Job")
container = job["spec"]["template"]["spec"]["containers"][0]
if container["image"] != "ghcr.io/loft-sh/vcluster-platform:test":
    print("FAIL verify Job must run the Platform image ({{ .Values.__image__ }})", file=sys.stderr)
    sys.exit(1)
if "post-install" not in job["metadata"]["annotations"].get("helm.sh/hook", ""):
    print("FAIL verify Job must be a post-install hook so Helm waits for it", file=sys.stderr)
    sys.exit(1)
if any(e.get("name") in ("REG_TOKEN",) and "value" in e for e in container["env"]):
    print("FAIL registry credential must come from a Secret, not an inline env value", file=sys.stderr)
    sys.exit(1)
if job["spec"]["activeDeadlineSeconds"] + 60 > 20 * 60:
    print("FAIL verify Job deadline must stay under the App's Helm timeout", file=sys.stderr)
    sys.exit(1)
script = container["args"][0]
(work / "verify.sh").write_text(script)
if subprocess.run(["sh", "-n", str(work / "verify.sh")]).returncode != 0:
    print("FAIL verify script does not parse", file=sys.stderr)
    sys.exit(1)
for needle in ("verify-attestation --type https://sigstore.dev/cosign/sign/v1", "verify-attestation --type slsaprovenance1", "publication-root.config.v4", "tags/list"):
    if needle not in script:
        print(f"FAIL verify script lost its {needle!r} step", file=sys.stderr)
        sys.exit(1)
VERIFY
echo "ok verify app"

helm template base "$work/base-chart" --namespace nvke-base > "$work/base.yaml"
for kind in Namespace Secret Issuer Certificate ConfigMap Role RoleBinding; do
  grep -qx "kind: $kind" "$work/base.yaml" || { echo "FAIL base-config renders no $kind" >&2; exit 1; }
done
grep -q 'name: nvke-registry' "$work/base.yaml" || { echo "FAIL base-config renders no pull secret when a username is set" >&2; exit 1; }
echo "ok base-config app"

# Chart renders. The four acquired charts and cert-manager come from their public sources; NVKR
# republishes the acquired charts byte for byte, so this renders what the Stack installs. The
# controller and nktp charts come from the public NVKE source at the pinned release.
render_chart() { # <task> <shared> <chart-ref...>
  local task=$1 shared=$2; shift 2
  { read -r name; read -r repo; read -r version; read -r namespace; read -r release; } < "$work/$task-$shared/chart"
  if ! helm template "$release" "$@" --namespace "$namespace" --values "$work/$task-$shared/values.yaml" --kube-version 1.33.0 --include-crds > "$work/$task-$shared/rendered.yaml" 2> "$work/$task-$shared/err.txt"; then
    echo "FAIL $task ($name $version, sharedNodes=$shared) does not render:" >&2
    tail -5 "$work/$task-$shared/err.txt" >&2
    exit 1
  fi
}
chart_version() { { read -r _; read -r _; read -r version; } < "$work/$1-false/chart"; echo "$version"; }

render_chart certmanager false cert-manager --repo https://charts.jetstack.io --version "$(chart_version certmanager)"
render_chart postgres false oci://registry-1.docker.io/bitnamicharts/postgresql --version "$(chart_version postgres)"
render_chart spirecrds false spire-crds --repo https://spiffe.github.io/helm-charts-hardened/ --version "$(chart_version spirecrds)"
render_chart temporal false temporal --repo https://go.temporal.io/helm-charts --version "$(chart_version temporal)"
for shared in false true; do
  render_chart spire "$shared" spire --repo https://spiffe.github.io/helm-charts-hardened/ --version "$(chart_version spire)"
done
grep -q 'kind: StatefulSet' "$work/spire-false/rendered.yaml" && grep -q 'spiffe-oidc-discovery-provider' "$work/spire-false/rendered.yaml" && grep -q 'csi.spiffe.io' "$work/spire-false/rendered.yaml" || { echo "FAIL spire on private nodes must render the server, the OIDC provider and the CSI driver" >&2; exit 1; }
if grep -q 'kind: CSIDriver' "$work/spire-true/rendered.yaml" || grep -q 'spiffe-oidc-discovery-provider-[a-z]' "$work/spire-true/rendered.yaml"; then
  echo "FAIL spire on shared nodes must not render the CSI driver or the OIDC provider" >&2; exit 1
fi
grep -q 'postgres-postgresql' "$work/postgres-false/rendered.yaml" || { echo "FAIL postgres must render the postgres-postgresql Service Temporal and the controller dial" >&2; exit 1; }
grep -q 'kind: Job' "$work/temporal-false/rendered.yaml" || { echo "FAIL temporal must render its schema Job" >&2; exit 1; }
echo "ok acquired charts render"

nvke_tag=v0.22.0
git clone -q -c advice.detachedHead=false --depth 1 --branch "$nvke_tag" https://github.com/dsx-ai-factory/nvke.git "$work/nvke"
for shared in false true; do
  render_chart controller "$shared" "$work/nvke/controller/deploy/charts/controller"
done
grep -q 'kind: Deployment' "$work/controller-false/rendered.yaml" || { echo "FAIL controller must render its Deployment" >&2; exit 1; }
grep -q 'csi.spiffe.io' "$work/controller-false/rendered.yaml" || { echo "FAIL controller on private nodes must mount the SPIFFE workload API" >&2; exit 1; }
if grep -q 'csi.spiffe.io' "$work/controller-true/rendered.yaml"; then echo "FAIL controller on shared nodes must not mount the SPIFFE workload API" >&2; exit 1; fi
grep -q "registry.example/nvke/profiles@sha256:" "$work/controller-false/rendered.yaml" || { echo "FAIL controller must take the profiles image from the release" >&2; exit 1; }
helm dependency update "$work/nvke/nktp/deploy/charts/nktp" > /dev/null
render_chart nktp false "$work/nvke/nktp/deploy/charts/nktp"
grep -q 'kind: CustomResourceDefinition' "$work/nktp-false/rendered.yaml" || { echo "FAIL nktp must render the monitoring CRDs the other charts need" >&2; exit 1; }
echo "ok NVKE charts render ($nvke_tag)"
