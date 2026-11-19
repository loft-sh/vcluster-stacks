#!/usr/bin/env bash
# Static checks for this Stack: the things the Platform does not check for you.
#
#   ./test-manifests.sh
#
# - every YAML document parses and is a kind this Stack is expected to ship
# - every App a StackTemplate task references exists in apps/
# - every task passes every parameter its App declares (an omitted one arrives empty)
# - every StackTemplate a tenant cluster template attaches exists here
# - every object name starts with "radar", so it cannot collide with another Stack
# - no enrollment key, license or private key is committed
#
# Needs python3 with PyYAML. Exits 1 on failures, 2 on a missing prerequisite.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

command -v python3 >/dev/null || { echo "cannot run: python3 is missing" >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "cannot run: PyYAML is missing (python3 -m pip install pyyaml)" >&2; exit 2; }

python3 - "$root" <<'CHECKS'
import re
import sys
from pathlib import Path

import yaml

root = Path(sys.argv[1])
errors = []
allowed = {"App", "StackTemplate", "StackInstance", "VirtualClusterTemplate", "VirtualClusterInstance"}
apps, stacks, refs_app, refs_stack = {}, set(), [], []

for path in sorted(root.rglob("*.yaml")):
    rel = path.relative_to(root)
    text = path.read_text()
    if re.search(r"rhe_[A-Za-z0-9_-]{43}", text):
        errors.append(f"{rel}: contains an enrollment key")
    if "PRIVATE KEY-----" in text or re.search(r"eyJ[A-Za-z0-9_-]{20,}\.eyJ", text):
        errors.append(f"{rel}: contains a private key or a license")
    try:
        docs = [d for d in yaml.safe_load_all(text) if d]
    except yaml.YAMLError as exc:
        errors.append(f"{rel}: does not parse: {exc}")
        continue
    for doc in docs:
        kind, name = doc.get("kind"), doc.get("metadata", {}).get("name", "")
        if kind not in allowed:
            errors.append(f"{rel}: unexpected kind {kind}")
            continue
        in_example = rel.parts[0] == "example"
        if not in_example and not name.startswith("radar"):
            errors.append(f"{rel}: {kind} {name} must start with 'radar'")
        spec = doc.get("spec", {})
        if kind == "App":
            apps[name] = {p["variable"] for p in spec.get("parameters", [])}
        elif kind == "StackTemplate":
            stacks.add(name)
            tasks = spec.get("tasks", [])
            if not 1 <= len(tasks) <= 20:
                errors.append(f"{rel}: a Stack has between 1 and 20 tasks, this one has {len(tasks)}")
            names = {t["name"] for t in tasks}
            for task in tasks:
                ref = task.get("app", {}).get("templateRef", {}).get("name")
                if ref:
                    passed = set(task.get("app", {}).get("parameters", {}))
                    refs_app.append((rel, ref, task["name"], passed))
                for dep in task.get("dependsOn", []):
                    if dep not in names:
                        errors.append(f"{rel}: task {task['name']} depends on unknown task {dep}")
        elif kind == "VirtualClusterTemplate":
            values = spec.get("template", {}).get("helmRelease", {}).get("values", "")
            if "deploy:" in values and "loft.sh/stacks-sync" not in str(spec):
                errors.append(f"{rel}: deploy.stacks needs the loft.sh/stacks-sync label on the instance template")
            for ref in re.findall(r"templateRef:\s*\n\s*name:\s*([a-z0-9-]+)", values):
                refs_stack.append((rel, ref))
        elif kind == "StackInstance":
            ref = spec.get("templateRef", {}).get("name")
            if ref:
                refs_stack.append((rel, ref))

for rel, ref, task, passed in refs_app:
    if ref not in apps:
        errors.append(f"{rel}: references App {ref}, which is not in apps/")
        continue
    for missing in sorted(apps[ref] - passed):
        errors.append(f"{rel}: task {task} does not pass parameter {missing} to App {ref}")
    for extra in sorted(passed - apps[ref]):
        errors.append(f"{rel}: task {task} passes {extra}, which App {ref} does not declare")
for rel, ref in refs_stack:
    if ref not in stacks:
        errors.append(f"{rel}: references StackTemplate {ref}, which is not in this directory")
if not (root / "README.md").is_file():
    errors.append("README.md is missing")

if errors:
    print("FAILED", file=sys.stderr)
    for err in errors:
        print(f"  - {err}", file=sys.stderr)
    sys.exit(1)
print(f"ok: {len(apps)} App(s), {len(stacks)} StackTemplate(s)")
CHECKS
