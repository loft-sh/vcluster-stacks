#!/usr/bin/env python3
"""Keep offline validation universal; select expensive Platform checks by changed paths."""

import json
import os
from pathlib import Path
import re
import subprocess


def needs_platform(paths):
    return any(not path.endswith(".md") or path.startswith("certified-stacks/run-ai/")
               or "/source/" in path for path in paths)


def main():
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    base = (event.get("pull_request") or {}).get("base", {}).get("sha") or event.get("before", "")
    required = True  # Dispatch, a new branch, or unknown history gets the full check.
    if re.fullmatch(r"[0-9a-f]{40}", base) and base != "0" * 40:
        changed = subprocess.run(["git", "diff", "--name-only", "--no-renames", "-z", base, "HEAD", "--"],
                                 capture_output=True, check=False)
        if changed.returncode == 0:
            required = needs_platform([p.decode() for p in changed.stdout.split(b"\0") if p])
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"platform={str(required).lower()}\n")


if __name__ == "__main__":
    main()
