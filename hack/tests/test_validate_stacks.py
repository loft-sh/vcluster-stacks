import copy
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import validate_stacks as validator


class StackValidationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.template = {"apiVersion": "management.loft.sh/v1", "kind": "StackTemplate",
                         "metadata": {"name": "sample"}, "spec": {"tasks": []}}
        self.example = {"apiVersion": "management.loft.sh/v1", "kind": "StackInstance",
                        "metadata": {"name": "sample", "namespace": "p-example"}}

    def integration(self, name="new-contribution"):
        directory = self.root / "community-stacks" / name
        directory.mkdir(parents=True)
        (directory / "README.md").write_text("# Sample\n")
        check = directory / "test-manifests.sh"
        check.write_text("#!/usr/bin/env bash\nexit 0\n")
        check.chmod(0o755)
        self.write(directory / "stacktemplate.yaml", self.template)
        self.write(directory / "example.yaml", self.example)
        return directory

    def write(self, path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(yaml.safe_dump(value))

    def test_new_directory_is_discovered_without_workflow_registration(self):
        directory = self.integration()
        records, checks = validator.validate(self.root)
        self.assertEqual(len(records), 2)
        self.assertEqual(checks, [directory / "test-manifests.sh"])

    def test_missing_checks_readme_template_and_example_fail(self):
        directory = self.integration()
        for filename in ("README.md", "test-manifests.sh", "stacktemplate.yaml", "example.yaml"):
            with self.subTest(filename=filename):
                path = directory / filename
                original = path.read_text()
                path.unlink()
                with self.assertRaises(ValueError):
                    validator.validate(self.root)
                path.write_text(original)
                path.chmod(0o755)

    def test_generator_inputs_are_excluded_but_generated_files_are_checked(self):
        directory = self.integration()
        source = directory / "source/input.yaml"
        source.parent.mkdir()
        source.write_text("not: valid: yaml\n")
        validator.validate(self.root)
        generated = directory / "generated.yaml"
        generated.write_text(source.read_text())
        with self.assertRaises(ValueError):
            validator.validate(self.root)

    def test_duplicate_yaml_keys_are_rejected(self):
        directory = self.integration()
        (directory / "bad.yaml").write_text("kind: App\nkind: StackTemplate\n")
        with self.assertRaisesRegex(ValueError, "duplicate YAML key"):
            validator.validate(self.root)

    def test_same_global_definition_can_be_shared_but_conflicts_fail(self):
        self.integration("one")
        second = self.integration("two")
        validator.validate(self.root)
        changed = copy.deepcopy(self.template)
        changed["spec"]["description"] = "Different content"
        self.write(second / "stacktemplate.yaml", changed)
        with self.assertRaisesRegex(ValueError, "conflicting StackTemplate"):
            validator.validate(self.root)

    def test_missing_static_reference_needs_installation_declaration(self):
        directory = self.integration()
        self.template["spec"]["tasks"] = [{"name": "runtime", "app": {"templateRef": {"name": "platform-app"}}}]
        self.write(directory / "stacktemplate.yaml", self.template)
        with self.assertRaisesRegex(ValueError, "missing App platform-app"):
            validator.validate(self.root)
        self.write(self.root / "hack/external-template-references.yaml", [{
            "path": "community-stacks/new-contribution/stacktemplate.yaml", "kind": "App",
            "name": "platform-app", "instructions": "README.md#requirements: supplied by Platform",
        }])
        validator.validate(self.root)

    def test_literal_readme_defaults_match_manifest(self):
        directory = self.integration()
        self.template["spec"]["parameters"] = [{"variable": "version", "defaultValue": "1.2.3"}]
        self.write(directory / "stacktemplate.yaml", self.template)
        readme = directory / "README.md"
        readme.write_text("| Parameter | Default |\n| --- | --- |\n| `version` | `1.0.0` |\n")
        with self.assertRaisesRegex(ValueError, "version default"):
            validator.validate(self.root)
        readme.write_text(readme.read_text().replace("`1.0.0`", "`1.2.3`"))
        validator.validate(self.root)

    def test_mixed_yaml_submits_only_platform_documents_as_dry_runs(self):
        directory = self.integration()
        with (directory / "example.yaml").open("a") as out:
            out.write("---\napiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: support\n")
        records, _ = validator.validate(self.root)
        with patch.object(validator.subprocess, "run") as run:
            validator.server_validate(records)
        self.assertEqual(run.call_count, 2)
        for call in run.call_args_list:
            self.assertIn("--dry-run=server", call.args[0])
            self.assertIn("--validate=strict", call.args[0])
            self.assertNotIn("kind: ConfigMap", call.kwargs["input"])

    def test_single_file_starter_must_match_split_resources(self):
        self.integration()
        starter = self.root / "templates/stack"
        starter.mkdir(parents=True)
        (starter / "README.md").write_text("# Starter")
        check = starter / "test-manifests.sh"
        check.write_text("#!/bin/bash\nexit 0\n")
        check.chmod(0o755)
        self.write(starter / "stacktemplate.yaml", self.template)
        self.write(starter / "example/stackinstance.yaml", self.example)
        combined = self.root / "examples/starter-stack.yaml"
        self.write(combined, self.template)
        with self.assertRaisesRegex(ValueError, "differs from"):
            validator.validate(self.root)
        combined.write_text(yaml.safe_dump_all([self.template, self.example]))
        validator.validate(self.root)


if __name__ == "__main__":
    unittest.main()
