#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

missing=()
for tool in python3 helm; do
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

# Check the shape the Platform bundles and serves, then write what `helm template` needs to render
# the operator chart. The server-side dry run in validate.yml checks the fields against the API.
python3 - "$root" "$work" <<'MANIFESTS'
import re
import sys
from pathlib import Path

import yaml

root, work = Path(sys.argv[1]), Path(sys.argv[2])
errors = []


def load(path):
    return yaml.safe_load((root / path).read_text())


manifests = ["stacktemplate.yaml", "virtualclustertemplate.yaml", *sorted(f"apps/{p.name}" for p in (root / "apps").glob("*.yaml"))]
for path in manifests:
    # Users apply these through the management API, and Platform bundles them from the same files.
    if load(path).get("apiVersion") != "management.loft.sh/v1":
        errors.append(f"{path}: apiVersion must be management.loft.sh/v1")

template = load("stacktemplate.yaml")
if template.get("kind") != "StackTemplate" or template["metadata"].get("name") != "saturn-enterprise":
    errors.append("stacktemplate.yaml: expected StackTemplate saturn-enterprise")
if (template["metadata"].get("annotations") or {}).get("vcluster.com/certified") != "true":
    errors.append('stacktemplate.yaml: missing annotation vcluster.com/certified: "true"')
for removed in ("inputs",):
    if removed in template["spec"]:
        errors.append(f"stacktemplate.yaml: spec.{removed} was renamed to spec.parameters")

parameters = {p["variable"] for p in template["spec"].get("parameters", [])}
apps = {}
for path in manifests[2:]:
    app = load(path)
    apps[app["metadata"]["name"]] = app


def minutes(where, duration):
    match = re.fullmatch(r"(\d+)m", str(duration))
    if not match:
        errors.append(f"{where}: timeout {duration!r} must be whole minutes, like 20m")
        return None
    return int(match.group(1))


for task in template["spec"]["tasks"]:
    where = f"stacktemplate.yaml task {task['name']}"
    if "taskTimeout" in task:
        errors.append(f"{where}: taskTimeout was renamed to timeout")
    reference = task["app"]["templateRef"]["name"]
    app = apps.get(reference)
    if app is None:
        errors.append(f"{where}: references missing App {reference!r}")
        continue
    declared = {p["variable"] for p in app["spec"].get("parameters", [])}
    for variable, value in (task["app"].get("parameters") or {}).items():
        if variable not in declared:
            errors.append(f"{where}: App {reference} does not declare parameter {variable!r}")
        for used in re.findall(r"\.Values\.(\w+)", str(value)):
            if used not in parameters:
                errors.append(f"{where}: {variable} uses .Values.{used}, which the StackTemplate does not declare")
    # The task timeout is only the Stack's deadline. Keep Helm's below it so a failed install
    # reports Helm's error instead of a bare task timeout.
    if app["spec"].get("wait") and "timeout" in app["spec"]:
        helm, deadline = minutes(f"App {reference}", app["spec"]["timeout"]), minutes(where, task.get("timeout", "10m"))
        if helm is not None and deadline is not None and helm >= deadline:
            errors.append(f"{where}: App timeout {app['spec']['timeout']} must be below task timeout {task.get('timeout', '10m')}")

vct = load("virtualclustertemplate.yaml")
release = vct["spec"]["template"]["helmRelease"]
if not (release.get("chart") or {}).get("version"):
    errors.append("virtualclustertemplate.yaml: helmRelease.chart.version must be set; Platform rewrites it to its default vCluster version")
values = release.get("values", "")
if "engnode" in values:
    errors.append("virtualclustertemplate.yaml: values reference the internal engnode pull secret")
rendered = yaml.safe_load(re.sub(r"{{[^}]*}}", "x", values))
for stack in (rendered.get("deploy") or {}).get("stacks") or []:
    where = f"virtualclustertemplate.yaml deploy.stacks {stack.get('name')}"
    if "inputs" in stack:
        errors.append(f"{where}: inputs was renamed to parameters")
    if (stack.get("templateRef") or {}).get("name") != "saturn-enterprise":
        errors.append(f"{where}: expected templateRef saturn-enterprise")
    for variable in stack.get("parameters") or {}:
        if variable not in parameters:
            errors.append(f"{where}: parameter {variable!r} is not declared by the StackTemplate")

chart = apps["saturn-step-01-helm-operator"]["spec"]["config"]["chart"]
(work / "chart").write_text("\n".join([chart["name"], chart["repoURL"], chart["version"]]) + "\n")

if errors:
    for error in errors:
        print(f"FAIL {error}", file=sys.stderr)
    sys.exit(1)
MANIFESTS
echo "ok manifests"

{ read -r chart; read -r repo; read -r version; } < "$work/chart"
if ! helm template saturn "$repo/$chart" --version "$version" --namespace saturn-system --kube-version 1.33.0 > "$work/rendered.yaml"; then
  echo "FAIL $chart $version from $repo does not render" >&2
  exit 1
fi
grep -q '^kind: Deployment$' "$work/rendered.yaml" || {
  echo "FAIL $chart $version rendered no operator Deployment" >&2
  exit 1
}
echo "ok chart $chart $version renders"
