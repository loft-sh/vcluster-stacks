#!/usr/bin/env python3
"""Discover and validate deployable stack resources. Never contacts a cluster by default."""

import argparse
import os
from pathlib import Path
import re
import subprocess
import sys

import yaml

ROOT = Path(__file__).resolve().parents[1]
GLOBAL_KINDS = {"App", "ArgoCDApplicationTemplate", "StackTemplate", "VirtualClusterTemplate"}


class UniqueKeysLoader(yaml.SafeLoader):
    """Reject overwritten YAML fields instead of silently validating the last value."""


def unique_mapping(loader, node, deep=False):
    loader.flatten_mapping(node)
    result = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in result:
            raise ValueError(f"duplicate YAML key {key!r} at line {key_node.start_mark.line + 1}")
        result[key] = loader.construct_object(value_node, deep=deep)
    return result


UniqueKeysLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, unique_mapping)


def load_documents(path):
    return [doc for doc in yaml.load_all(path.read_text(), Loader=UniqueKeysLoader) if doc is not None]


def integration_directories(root):
    directories = []
    for category in ("certified-stacks", "community-stacks"):
        parent = root / category
        if parent.is_dir():
            directories.extend(sorted(p for p in parent.iterdir() if p.is_dir() and not p.name.startswith(".")))
    return directories


def manifest_paths(directory):
    for path in sorted(directory.rglob("*")):
        if path.suffix not in (".yaml", ".yml") or "source" in path.relative_to(directory).parts:
            continue
        if path.is_symlink():
            raise ValueError(f"{path}: deployable manifests must not be symlinks")
        yield path


def check_entrypoint(directory):
    for name in ("test-manifests.sh", "test-certified-manifests.sh"):
        path = directory / name
        if path.is_file() and os.access(path, os.X_OK):
            return path
    raise ValueError(f"{directory}: add an executable test-manifests.sh (or test-certified-manifests.sh)")


def platform_document(doc):
    return isinstance(doc, dict) and re.fullmatch(r"[a-z0-9.-]+\.loft\.sh/v[\w]+", str(doc.get("apiVersion", "")))


def readme_defaults(directory, document):
    """Check literal defaults in Markdown tables, leaving prose and complex values to review."""
    parameters = {p["variable"]: p for p in document.get("spec", {}).get("parameters", [])}
    default_column = None
    errors = []
    for number, line in enumerate((directory / "README.md").read_text().splitlines(), 1):
        if not line.startswith("|"):
            default_column = None
            continue
        cells = [c.strip() for c in line.strip("|").split("|")]
        if "Default" in cells:
            default_column = cells.index("Default")
            continue
        if default_column is None or len(cells) <= default_column:
            continue
        name = cells[0].strip("`")
        value = cells[default_column]
        if name not in parameters or not re.fullmatch(r"`[^`\n]+`", value):
            continue
        expected = parameters[name].get("defaultValue")
        if expected is not None and "\n" not in str(expected) and value[1:-1].strip('"\'') != str(expected):
            errors.append(f"{directory / 'README.md'}:{number}: {name} default is {value}, manifest has {expected!r}")
    return errors


def validate(root):
    errors, records, checks = [], [], []
    declarations = root / "hack/external-template-references.yaml"
    external = []
    if declarations.is_file():
        documents = load_documents(declarations)
        if len(documents) != 1 or not isinstance(documents[0], list):
            raise ValueError(f"{declarations}: expected one YAML list")
        external = documents[0]
        if not all(isinstance(entry, dict) and all(entry.get(key) for key in ("path", "kind", "name", "instructions")) for entry in external):
            raise ValueError(f"{declarations}: entries need path, kind, name, and instructions")
    directories = integration_directories(root)
    if not directories:
        raise ValueError("no integrations found")
    starter = root / "templates/stack"
    for directory in directories + ([starter] if starter.is_dir() else []):
        try:
            if not (directory / "README.md").is_file():
                raise ValueError(f"{directory}: missing README.md")
            checks.append(check_entrypoint(directory))
            local = []
            for path in manifest_paths(directory):
                for doc in load_documents(path):
                    if platform_document(doc):
                        local.append((path, doc))
            kinds = {doc.get("kind") for _, doc in local}
            if "StackTemplate" not in kinds:
                raise ValueError(f"{directory}: no deployable StackTemplate found")
            if not kinds.intersection({"StackInstance", "VirtualClusterTemplate"}):
                raise ValueError(f"{directory}: add an example StackInstance or cluster template")
            records.extend(local)
            # Only an unambiguous root StackTemplate can be compared with its README table.
            templates = [doc for path, doc in local if path.parent == directory and doc.get("kind") == "StackTemplate"]
            if len(templates) == 1:
                errors.extend(readme_defaults(directory, templates[0]))
        except (ValueError, yaml.YAMLError, OSError, TypeError, KeyError) as exc:
            errors.append(str(exc))

    definitions = {}
    for path, doc in records:
        if doc.get("kind") not in GLOBAL_KINDS:
            continue
        key = (doc["kind"], doc.get("metadata", {}).get("name"))
        if not key[1]:
            errors.append(f"{path}: {key[0]} has no metadata.name")
        elif key in definitions and definitions[key][1] != doc:
            errors.append(f"{path}: conflicting {key[0]} {key[1]} also defined in {definitions[key][0]}")
        else:
            definitions[key] = (path, doc)

    for path, doc in records:
        if doc.get("kind") != "StackTemplate":
            continue
        for task in doc.get("spec", {}).get("tasks", []):
            for arm, kind in (("app", "App"), ("argoCDApplication", "ArgoCDApplicationTemplate")):
                name = (task.get(arm) or {}).get("templateRef", {}).get("name")
                if name and "{{" not in name and (kind, name) not in definitions:
                    # External dependencies are legitimate, but need an explicit declaration.
                    relative = str(path.relative_to(root))
                    if not any(e.get("path") == relative and e.get("kind") == kind and e.get("name") == name
                               and e.get("instructions") for e in external):
                        errors.append(f"{path}: missing {kind} {name}; include it or declare its installation instructions in hack/external-template-references.yaml")

    combined = root / "examples/starter-stack.yaml"
    if starter.is_dir() and combined.is_file():
        split = load_documents(starter / "stacktemplate.yaml") + load_documents(starter / "example/stackinstance.yaml")
        if load_documents(combined) != split:
            errors.append("examples/starter-stack.yaml differs from templates/stack resources")
    if errors:
        raise ValueError("\n".join(errors))
    return records, checks


def server_validate(records):
    for path, document in records:
        print(f"Validate {path}: {document['kind']} {document['metadata']['name']}", flush=True)
        # Submit documents separately: mixed files can include plain Kubernetes resources
        # that the Platform management API does not serve. No changes are persisted.
        subprocess.run([
            "kubectl", "apply", "--server-side", "--dry-run=server", "--validate=strict",
            "--force-conflicts", "--request-timeout=30s", "--filename=-",
        ], input=yaml.safe_dump(document), text=True, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-checks", action="store_true", help="execute integration checks; may fetch charts")
    parser.add_argument("--server", action="store_true", help="dry-run Platform documents against the current management API context")
    args = parser.parse_args()
    try:
        records, checks = validate(ROOT)
        print(f"Validated {len(checks)} integration/starter folders and {len(records)} Platform documents", flush=True)
        if args.run_checks:
            for path in checks:
                print(f"Run {path.relative_to(ROOT)}", flush=True)
                subprocess.run(["bash", str(path)], cwd=ROOT, check=True)
        if args.server:
            server_validate(records)
    except (ValueError, OSError, yaml.YAMLError, subprocess.CalledProcessError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
