import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import ci_changes


class ChangeSelectionTests(unittest.TestCase):
    def test_markdown_only_skips_platform_without_skipping_fast_checks(self):
        self.assertFalse(ci_changes.needs_platform(["README.md", "community-stacks/openclaw/README.md"]))

    def test_manifests_tooling_workflows_and_generated_docs_use_platform_check(self):
        for path in ("community-stacks/new/stacktemplate.yaml", "hack/review_stack_pr.py",
                     ".github/workflows/validate.yml", "certified-stacks/run-ai/dedicated-control-plane/README.md",
                     "community-stacks/new/source/README.md"):
            with self.subTest(path=path):
                self.assertTrue(ci_changes.needs_platform(["README.md", path]))

    def test_renaming_code_to_markdown_keeps_deleted_code_in_inventory(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            def git(*args):
                return subprocess.check_output(["git", "-C", str(root), *args]).decode().strip()
            git("init", "-q")
            git("config", "user.name", "Test")
            git("config", "user.email", "test@example.invalid")
            (root / "check.py").write_text("pass\n")
            git("add", ".")
            git("commit", "-qm", "base")
            base = git("rev-parse", "HEAD")
            git("mv", "check.py", "README.md")
            git("commit", "-qm", "rename")
            event = root / "event.json"
            event.write_text('{"before":"' + base + '"}')
            output = root / "output"
            with patch.dict(os.environ, {"GITHUB_EVENT_PATH": str(event), "GITHUB_OUTPUT": str(output)}):
                old = os.getcwd()
                try:
                    os.chdir(root)
                    ci_changes.main()
                finally:
                    os.chdir(old)
            self.assertEqual(output.read_text(), "platform=true\n")
