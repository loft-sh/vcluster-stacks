#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
python3 - "$root" <<'PY'
from pathlib import Path
import sys
import yaml

root = Path(sys.argv[1])
template = yaml.safe_load((root / "stacktemplate.yaml").read_text())
instance = yaml.safe_load((root / "example/stackinstance.yaml").read_text())
tasks = {task["name"]: task for task in template["spec"]["tasks"]}
assert instance["spec"]["templateRef"]["name"] == template["metadata"]["name"]
assert tasks["frontend"]["dependsOn"] == ["backend"]
assert tasks["backend"]["outputs"][0]["fromResource"]["namespace"] == tasks["backend"]["app"]["template"]["spec"]["defaultNamespace"]
assert '{{ .Outputs.backend.greeting | quote }}' in tasks["frontend"]["app"]["template"]["spec"]["config"]["manifests"]
assert template["spec"]["publishedOutputs"][0]["fromTask"] == {"task": "backend", "output": "greeting"}
print("ok starter references, dependency, and output handoff")
PY
