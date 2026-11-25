"""Unit tests for stackcatalog.py. Run: python3 -B -m unittest discover -s catalog"""
from __future__ import annotations

import contextlib
import gzip
import hashlib
import io
import json
import os
import shutil
import struct
import sys
import tarfile
import tempfile
import unittest
import zlib
from pathlib import Path

# The repository does not ignore __pycache__, so importing the tool must not create it.
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import stackcatalog  # noqa: E402

CATALOG = Path(__file__).resolve().parent
FIXTURES = CATALOG / "testdata" / "stack-json"
CONTENT_HASH = CATALOG / "testdata" / "content-hash"

SVG = b'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1 1"><rect width="1" height="1"/></svg>'


def png(width: int, height: int) -> bytes:
    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    header = struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0)
    pixels = zlib.compress(b"\x00" * (width + 1))
    return stackcatalog.PNG_SIGNATURE + chunk(b"IHDR", header) + chunk(b"IDAT", pixels) + chunk(b"IEND", b"")


def manifest(kind: str, name: str, extra: str = "") -> str:
    return f"apiVersion: management.loft.sh/v1\nkind: {kind}\nmetadata:\n  name: {name}\nspec:\n  displayName: {name}\n{extra}"


class Repo:
    """A small repository in a temporary folder."""

    def __init__(self, test: unittest.TestCase) -> None:
        self.root = Path(tempfile.mkdtemp(prefix="stackcatalog-"))
        test.addCleanup(shutil.rmtree, self.root)

    def write(self, path: str, content) -> Path:
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(content, bytes):
            target.write_bytes(content)
        else:
            target.write_text(content, encoding="utf-8")
        return target

    def stack(self, folder: str, name: str, members=None, files=None, **keys) -> Path:
        data = {
            "schemaVersion": 1,
            "name": name,
            "displayName": name,
            "description": f"Test entry {name}.",
            "author": "vCluster Labs",
            "platformVersion": ">=5.1.0",
            "members": members or ["stacktemplate.yaml"],
        }
        data.update(keys)
        if files is None:
            files = {"stacktemplate.yaml": manifest("StackTemplate", name)}
        for path, content in files.items():
            self.write(f"{folder}/{path}", content)
        return self.write(f"{folder}/stack.json", json.dumps(data, indent=2) + "\n")

    def check(self, *paths: str) -> stackcatalog.Problems:
        problems = stackcatalog.Problems()
        targets = [self.root / p for p in paths] or stackcatalog.default_stack_folders(self.root)
        stackcatalog.check(targets, self.root, problems)
        return problems


class CheckTest(unittest.TestCase):
    def setUp(self) -> None:
        self.repo = Repo(self)

    def assertOneError(self, problems, *parts) -> None:
        self.assertEqual(len(problems.errors), 1, problems.errors)
        for part in parts:
            self.assertIn(part, problems.errors[0])

    def test_valid_entry_passes(self):
        self.repo.stack("community-stacks/a", "a")
        problems = self.repo.check()
        self.assertEqual(problems.errors, [])
        self.assertEqual(problems.warnings, [])

    # Reading

    def test_unknown_key(self):
        path = self.repo.stack("community-stacks/a", "a", homepage="https://example.com")
        self.assertOneError(self.repo.check(), "community-stacks/a/stack.json", "homepage")
        self.assertTrue(path.exists())

    def test_version_key_is_ignored(self):
        self.repo.stack("community-stacks/a", "a", version="1.2.3")
        self.assertEqual(self.repo.check().errors, [])

    def test_duplicate_key(self):
        path = self.repo.stack("community-stacks/a", "a")
        path.write_text(path.read_text().replace('"author"', '"author": "x",\n  "author"', 1))
        self.assertOneError(self.repo.check(), "has the key 'author' twice")

    def test_trailing_comma(self):
        path = self.repo.stack("community-stacks/a", "a")
        path.write_text(path.read_text().replace('"stacktemplate.yaml"\n', '"stacktemplate.yaml",\n'))
        self.assertOneError(self.repo.check(), "is not valid JSON")

    def test_nan(self):
        path = self.repo.stack("community-stacks/a", "a")
        path.write_text(path.read_text().replace('"schemaVersion": 1', '"schemaVersion": NaN'))
        self.assertOneError(self.repo.check(), "NaN")

    def test_byte_order_mark(self):
        path = self.repo.stack("community-stacks/a", "a")
        path.write_bytes(b"\xef\xbb\xbf" + path.read_bytes())
        self.assertOneError(self.repo.check(), "byte order mark")

    def test_invalid_utf8(self):
        path = self.repo.stack("community-stacks/a", "a")
        path.write_bytes(path.read_bytes().replace(b"Test entry", b"Test \xff entry"))
        self.assertOneError(self.repo.check(), "not valid UTF-8")

    def test_schema_fixtures(self):
        for folder in sorted(FIXTURES.iterdir()):
            with self.subTest(folder.name):
                problems = stackcatalog.Problems()
                stackcatalog.check([folder], CATALOG.parent, problems)
                if folder.name == "valid":
                    self.assertEqual(problems.errors, [])
                else:
                    self.assertEqual(len(problems.errors), 1, problems.errors)
                    self.assertIn(f"{folder.name}/stack.json", problems.errors[0])

    def test_source_folders_are_skipped(self):
        self.repo.stack("certified-stacks/x/a", "a")
        self.repo.stack("certified-stacks/x/source/a", "a")
        problems = self.repo.check()
        self.assertEqual(problems.errors, [])

    def test_no_stack_json(self):
        self.repo.write("community-stacks/a/stacktemplate.yaml", manifest("StackTemplate", "a"))
        self.assertOneError(self.repo.check(), "no stack.json found")

    # Names

    def test_duplicate_entry_name(self):
        self.repo.stack("community-stacks/a", "same")
        self.repo.stack("community-stacks/b", "same", files={"stacktemplate.yaml": manifest("StackTemplate", "b")})
        self.assertOneError(self.repo.check(), "community-stacks/b/stack.json", "'same' is also used by community-stacks/a/stack.json")

    # Paths

    def test_absolute_and_dotdot_paths(self):
        for path in ("/etc/passwd", "../x.yaml", "apps/../x.yaml"):
            with self.subTest(path):
                repo = Repo(self)
                repo.stack("community-stacks/a", "a", members=[path])
                problems = repo.check()
                self.assertEqual(len(problems.errors), 1, problems.errors)
                self.assertIn("$.members[0]", problems.errors[0])

    def test_empty_and_dot_segments(self):
        for path, problem in (("apps//a.yaml", "empty segment"), ("./stacktemplate.yaml", "'.' segment")):
            with self.subTest(path):
                repo = Repo(self)
                repo.stack("community-stacks/a", "a", members=[path])
                self.assertOneError(repo.check(), problem)

    def test_member_names_no_file(self):
        self.repo.stack("community-stacks/a", "a", members=["stacktemplate.yaml", "missing.yaml"])
        self.assertOneError(self.repo.check(), "member 'missing.yaml' names no file")

    def test_member_names_a_folder(self):
        self.repo.stack("community-stacks/a", "a", members=["stacktemplate.yaml", "apps"],
                        files={"stacktemplate.yaml": manifest("StackTemplate", "a"),
                               "apps/x.yaml": manifest("App", "x")})
        self.assertOneError(self.repo.check(), "member 'apps' names no file")

    def test_readme_and_icon_name_no_file(self):
        self.repo.stack("community-stacks/a", "a", readme="README.md", icon="icon.svg")
        problems = self.repo.check()
        self.assertEqual(len(problems.errors), 2, problems.errors)
        self.assertIn("readme 'README.md' names no file", problems.errors[0])
        self.assertIn("icon 'icon.svg' names no file", problems.errors[1])

    def test_icon_must_not_be_a_glob(self):
        self.repo.stack("community-stacks/a", "a", icon="*.svg", files={
            "stacktemplate.yaml": manifest("StackTemplate", "a"), "icon.svg": SVG})
        self.assertOneError(self.repo.check(), "icon '*.svg' is a glob")

    # Globs

    def test_glob_matches_files(self):
        self.repo.stack("community-stacks/a", "a", members=["stacktemplate.yaml", "apps/*.yaml"], files={
            "stacktemplate.yaml": manifest("StackTemplate", "a"),
            "apps/x.yaml": manifest("App", "x"),
            "apps/.hidden.yaml": manifest("App", "hidden"),
            "apps/notes.txt": "not a member",
        })
        problems = stackcatalog.Problems()
        entries = stackcatalog.check([self.repo.root / "community-stacks"], self.repo.root, problems)
        self.assertEqual(problems.errors, [])
        # "*" matches a leading dot, as Go's fs.Glob does.
        self.assertEqual(entries[0].members, ["apps/.hidden.yaml", "apps/x.yaml", "stacktemplate.yaml"])

    def test_glob_forbidden_characters(self):
        for pattern in ("apps/?.yaml", "apps/[ab].yaml", "**/*.yaml", "apps/{a,b}.yaml"):
            with self.subTest(pattern):
                repo = Repo(self)
                repo.stack("community-stacks/a", "a", members=["stacktemplate.yaml", pattern])
                self.assertOneError(repo.check(), f"member {pattern!r}", "may use only '*'")

    def test_glob_matches_no_file(self):
        self.repo.stack("community-stacks/a", "a", members=["stacktemplate.yaml", "apps/*.yaml"])
        self.assertOneError(self.repo.check(), "member 'apps/*.yaml' matches no file")

    def test_glob_matching_only_folders(self):
        self.repo.stack("community-stacks/a", "a", members=["stacktemplate.yaml", "apps/*"], files={
            "stacktemplate.yaml": manifest("StackTemplate", "a"), "apps/sub/x.yaml": manifest("App", "x")})
        self.assertOneError(self.repo.check(), "member 'apps/*' matches no file")

    def test_file_listed_twice_counts_once(self):
        self.repo.stack("community-stacks/a", "a", members=["stacktemplate.yaml", "*.yaml"])
        problems = stackcatalog.Problems()
        entries = stackcatalog.check([self.repo.root / "community-stacks"], self.repo.root, problems)
        self.assertEqual(problems.errors, [])
        self.assertEqual(entries[0].members, ["stacktemplate.yaml"])

    # Links

    @unittest.skipUnless(hasattr(os, "symlink"), "needs symbolic links")
    def test_member_link(self):
        self.repo.stack("community-stacks/a", "a", members=["stacktemplate.yaml", "apps/*.yaml"])
        self.repo.write("outside.yaml", manifest("App", "outside"))
        (self.repo.root / "community-stacks/a/apps").mkdir()
        os.symlink(self.repo.root / "outside.yaml", self.repo.root / "community-stacks/a/apps/x.yaml")
        self.assertOneError(self.repo.check(), "member 'apps/x.yaml': apps/x.yaml is a symbolic link")

    @unittest.skipUnless(hasattr(os, "symlink"), "needs symbolic links")
    def test_member_link_matched_twice_is_reported_once(self):
        self.repo.stack("community-stacks/a", "a", members=["stacktemplate.yaml", "apps/*.yaml", "apps/x.yaml"])
        self.repo.write("outside.yaml", manifest("App", "outside"))
        (self.repo.root / "community-stacks/a/apps").mkdir()
        os.symlink(self.repo.root / "outside.yaml", self.repo.root / "community-stacks/a/apps/x.yaml")
        self.assertOneError(self.repo.check(), "member 'apps/x.yaml': apps/x.yaml is a symbolic link")

    @unittest.skipUnless(hasattr(os, "symlink"), "needs symbolic links")
    def test_folder_link(self):
        self.repo.stack("community-stacks/a", "a", members=["stacktemplate.yaml", "apps/*.yaml"])
        self.repo.write("elsewhere/x.yaml", manifest("App", "x"))
        os.symlink(self.repo.root / "elsewhere", self.repo.root / "community-stacks/a/apps")
        self.assertOneError(self.repo.check(), "apps is a symbolic link")

    @unittest.skipUnless(hasattr(os, "symlink"), "needs symbolic links")
    def test_readme_link(self):
        self.repo.stack("community-stacks/a", "a", readme="README.md")
        self.repo.write("README.md", "# outside")
        os.symlink(self.repo.root / "README.md", self.repo.root / "community-stacks/a/README.md")
        self.assertOneError(self.repo.check(), "readme 'README.md': README.md is a symbolic link")

    @unittest.skipUnless(hasattr(os, "symlink"), "needs symbolic links")
    def test_stack_folder_link(self):
        self.repo.stack("elsewhere/a", "a")
        (self.repo.root / "community-stacks").mkdir()
        os.symlink(self.repo.root / "elsewhere/a", self.repo.root / "community-stacks/a")
        problems = self.repo.check("community-stacks/a/stack.json")
        self.assertOneError(problems, "community-stacks/a is a symbolic link")

    @unittest.skipUnless(hasattr(os, "symlink"), "needs symbolic links")
    def test_linked_stack_folder_in_default_scan(self):
        # Without this error, the linked entry would drop out of the catalog unseen.
        self.repo.stack("community-stacks/real", "real")
        self.repo.stack("elsewhere/linked", "linked")
        os.symlink(self.repo.root / "elsewhere/linked", self.repo.root / "community-stacks/linked")
        self.assertOneError(self.repo.check(), "community-stacks/linked: is a symbolic link to a folder")

    @unittest.skipUnless(hasattr(os, "symlink"), "needs symbolic links")
    def test_glob_ignores_linked_folder(self):
        self.repo.stack("community-stacks/a", "a", members=["stacktemplate.yaml", "apps/*"], files={
            "stacktemplate.yaml": manifest("StackTemplate", "a"), "apps/x.yaml": manifest("App", "x")})
        (self.repo.root / "elsewhere/sub").mkdir(parents=True)
        os.symlink(self.repo.root / "elsewhere/sub", self.repo.root / "community-stacks/a/apps/sub")
        self.assertEqual(self.repo.check().errors, [])

    def test_given_file_that_is_not_stack_json(self):
        self.repo.stack("community-stacks/a", "a", readme="README.md", files={
            "stacktemplate.yaml": manifest("StackTemplate", "a"), "README.md": "# A\n"})
        self.assertOneError(self.repo.check("community-stacks/a/README.md"),
                            "community-stacks/a/README.md: is not a stack.json file")

    def test_names_after_a_glob_match_exactly(self):
        # Go's fs.Glob compares names from a folder listing, so "X.yaml" does not match "x.yaml",
        # also on a file system that ignores case.
        self.repo.stack("community-stacks/a", "a", members=["stacktemplate.yaml", "*/X.yaml"], files={
            "stacktemplate.yaml": manifest("StackTemplate", "a"), "d/x.yaml": manifest("App", "x")})
        self.assertOneError(self.repo.check(), "member '*/X.yaml' matches no file")

    def test_same_folder_named_twice(self):
        self.repo.stack("community-stacks/a", "a")
        problems = self.repo.check("community-stacks", "community-stacks/../community-stacks")
        self.assertEqual(problems.errors, [])

    @unittest.skipIf(hasattr(os, "geteuid") and os.geteuid() == 0, "root can read every file")
    def test_unreadable_member(self):
        self.repo.stack("community-stacks/a", "a")
        path = self.repo.root / "community-stacks/a/stacktemplate.yaml"
        path.chmod(0)
        self.addCleanup(path.chmod, 0o644)
        self.assertOneError(self.repo.check(), "stacktemplate.yaml: cannot be read")

    # Kinds

    def test_other_kind(self):
        self.repo.stack("community-stacks/a", "a", members=["stacktemplate.yaml", "instance.yaml"], files={
            "stacktemplate.yaml": manifest("StackTemplate", "a"), "instance.yaml": manifest("StackInstance", "a")})
        self.assertOneError(self.repo.check(), "community-stacks/a/instance.yaml", "StackInstance")

    def test_other_api_version(self):
        self.repo.stack("community-stacks/a", "a", files={
            "stacktemplate.yaml": manifest("StackTemplate", "a").replace("management.loft.sh/v1", "apps/v1")})
        self.assertOneError(self.repo.check(), "apps/v1 StackTemplate")

    def test_every_allowed_kind(self):
        files = {"stacktemplate.yaml": manifest("StackTemplate", "a")}
        for kind in stackcatalog.MEMBER_KINDS:
            files[f"m/{kind}.yaml"] = manifest(kind, kind.lower())
        files["m/StackTemplate.yaml"] = manifest("StackTemplate", "other")
        self.repo.stack("community-stacks/a", "a", members=["stacktemplate.yaml", "m/*.yaml"], files=files)
        self.assertEqual(self.repo.check().errors, [])

    def test_document_without_name_or_mapping(self):
        self.repo.stack("community-stacks/a", "a", members=["stacktemplate.yaml", "bad.yaml"], files={
            "stacktemplate.yaml": manifest("StackTemplate", "a"),
            "bad.yaml": "apiVersion: management.loft.sh/v1\nkind: App\nmetadata: {}\n---\n- a list\n"})
        problems = self.repo.check()
        self.assertEqual(len(problems.errors), 2, problems.errors)
        self.assertIn("document 1 (App) has no metadata.name", problems.errors[0])
        self.assertIn("document 2 is not a mapping", problems.errors[1])

    def test_empty_member_and_invalid_yaml(self):
        self.repo.stack("community-stacks/a", "a", members=["stacktemplate.yaml", "empty.yaml", "broken.yaml"], files={
            "stacktemplate.yaml": manifest("StackTemplate", "a"),
            "empty.yaml": "# nothing\n",
            "broken.yaml": "kind: [\n"})
        problems = self.repo.check()
        self.assertEqual(len(problems.errors), 2, problems.errors)
        self.assertIn("broken.yaml: is not valid YAML", problems.errors[0])
        self.assertIn("(line 2, column 1)", problems.errors[0])
        self.assertIn("empty.yaml: holds no object", problems.errors[1])
        for line in problems.errors:
            self.assertNotIn("\n", line)

    def test_anchors_and_aliases(self):
        cases = {
            "self reference": manifest("StackTemplate", "a", "  extra: &s {self: *s}\n"),
            "nested aliases": manifest("StackTemplate", "a", "  a: &a [x, x]\n  b: [*a, *a]\n"),
            "anchor only": manifest("StackTemplate", "a", "  a: &a x\n"),
        }
        for label, content in cases.items():
            with self.subTest(label):
                repo = Repo(self)
                repo.stack("community-stacks/a", "a", files={"stacktemplate.yaml": content})
                self.assertOneError(repo.check(), "uses a YAML anchor or alias")

    def test_key_that_is_not_a_string(self):
        self.repo.stack("community-stacks/a", "a", files={
            "stacktemplate.yaml": manifest("StackTemplate", "a", "  extra:\n    1: x\n    b: y\n")})
        self.assertOneError(self.repo.check(), "document 1 (StackTemplate a): .spec.extra has the key 1, which is not a string")

    # Objects listed twice

    def test_same_object_twice_in_one_entry(self):
        self.repo.stack("community-stacks/a", "a", members=["stacktemplate.yaml", "copy.yaml"], files={
            "stacktemplate.yaml": manifest("StackTemplate", "a"), "copy.yaml": manifest("StackTemplate", "a")})
        # Members are read in byte order, so copy.yaml comes first.
        self.assertOneError(self.repo.check(), "a/stacktemplate.yaml", "StackTemplate a is also in copy.yaml of the same entry")

    def test_shared_object_same_content(self):
        app = manifest("App", "shared")
        self.repo.stack("certified-stacks/a", "a", members=["stacktemplate.yaml", "app.yaml"], files={
            "stacktemplate.yaml": manifest("StackTemplate", "a"), "app.yaml": app})
        # A different comment and key order is the same object.
        other = "# another comment\nkind: App\napiVersion: management.loft.sh/v1\nmetadata:\n  name: shared\nspec:\n  displayName: shared\n"
        self.repo.stack("certified-stacks/b", "b", members=["stacktemplate.yaml", "app.yaml"], files={
            "stacktemplate.yaml": manifest("StackTemplate", "b"), "app.yaml": other})
        self.assertEqual(self.repo.check().errors, [])

    def test_shared_object_different_content(self):
        self.repo.stack("certified-stacks/a", "a", members=["stacktemplate.yaml", "app.yaml"], files={
            "stacktemplate.yaml": manifest("StackTemplate", "a"), "app.yaml": manifest("App", "shared")})
        self.repo.stack("certified-stacks/b", "b", members=["stacktemplate.yaml", "app.yaml"], files={
            "stacktemplate.yaml": manifest("StackTemplate", "b"),
            "app.yaml": manifest("App", "shared", "  description: changed\n")})
        self.assertOneError(self.repo.check(), "certified-stacks/b/app.yaml", "App shared differs from the one entry 'a' lists")

    # Icons

    def icon_errors(self, name: str, data: bytes) -> list[str]:
        repo = Repo(self)
        repo.stack("community-stacks/a", "a", icon=name, files={
            "stacktemplate.yaml": manifest("StackTemplate", "a"), name: data})
        return repo.check().errors

    def test_icons_that_pass(self):
        self.assertEqual(self.icon_errors("icon.svg", SVG), [])
        self.assertEqual(self.icon_errors("icon.SVG", SVG), [])
        self.assertEqual(self.icon_errors("icon.png", png(512, 512)), [])
        self.assertEqual(self.icon_errors("icon.svg", b"<?xml version='1.0'?>\n<!-- c -->" + SVG), [])
        self.assertEqual(self.icon_errors("icon.svg", b'<?xml version="1.0" encoding="UTF-8"?>' + SVG), [])

    def test_icons_that_fail(self):
        cases = {
            "png over 512 pixels": ("icon.png", png(513, 10), "513 by 10 pixels"),
            "file over 64 KB": ("icon.svg", SVG.replace(b"</svg>", b"<!--" + b"x" * 65536 + b"--></svg>"), "more than 65536"),
            "jpeg named .png": ("icon.png", b"\xff\xd8\xff\xe0" + b"\x00" * 20, "neither a PNG nor a UTF-8 SVG"),
            "png named .svg": ("icon.svg", png(8, 8), "holds a PNG but its name ends in .svg"),
            "svg named .png": ("icon.png", SVG, "holds a SVG but its name ends in .png"),
            "doctype": ("icon.svg", b'<!DOCTYPE svg [<!ENTITY a "b">]>' + SVG, "DOCTYPE"),
            "not svg root": ("icon.svg", b"<html/>", "root element is 'html'"),
            "svg without namespace": ("icon.svg", b"<svg/>", "root element is 'svg'"),
            "broken xml": ("icon.svg", b"<svg", "well-formed XML"),
            "text after the root": ("icon.svg", SVG + b"<svg/>", "well-formed XML"),
            "other encoding declared": ("icon.svg", b'<?xml version="1.0" encoding="ISO-8859-1"?>' + SVG,
                                        "declares the encoding 'ISO-8859-1'"),
            "byte order mark and other encoding": (
                "icon.svg", b'\xef\xbb\xbf<?xml version="1.0" encoding="ISO-8859-1"?>' + SVG,
                "declares the encoding 'ISO-8859-1'"),
            "utf8 without dash": ("icon.svg", b'<?xml version="1.0" encoding="utf8"?>' + SVG, "declares the encoding 'utf8'"),
            "png without header": ("icon.png", stackcatalog.PNG_SIGNATURE + b"\x00" * 4, "no IHDR header"),
        }
        for label, (name, data, message) in cases.items():
            with self.subTest(label):
                errors = self.icon_errors(name, data)
                self.assertEqual(len(errors), 1, errors)
                self.assertIn(message, errors[0])

    # Warning

    def test_runtime_template_warning(self):
        app = manifest("App", "maker", (
            "  config:\n"
            "    manifests: |-\n"
            "      apiVersion: v1\n      kind: ConfigMap\n      metadata:\n        name: c\n"
            "      ---\n"
            "      apiVersion: management.loft.sh/v1\n      kind: StackTemplate\n      metadata:\n        name: t\n"
            "      ---\n"
            "      apiVersion: management.loft.sh/v1\n      kind: NodeProvider\n      metadata:\n        name: n\n"
        ))
        self.repo.stack("community-stacks/a", "a", members=["stacktemplate.yaml", "app.yaml"], files={
            "stacktemplate.yaml": manifest("StackTemplate", "a"), "app.yaml": app})
        problems = self.repo.check()
        self.assertEqual(problems.errors, [])
        self.assertEqual(len(problems.warnings), 1, problems.warnings)
        self.assertIn("App maker creates StackTemplate objects at runtime (spec.config.manifests)", problems.warnings[0])

    def test_no_warning_without_platform_template(self):
        app = manifest("App", "maker", "  config:\n    manifests: |-\n      apiVersion: v1\n      kind: ConfigMap\n")
        self.repo.stack("community-stacks/a", "a", members=["stacktemplate.yaml", "app.yaml"], files={
            "stacktemplate.yaml": manifest("StackTemplate", "a"), "app.yaml": app})
        self.assertEqual(self.repo.check().warnings, [])


class ContentHashTest(unittest.TestCase):
    MEMBERS = ["stacktemplate.yaml", "apps/a.yaml", "apps/b.yaml", "apps-extra.yaml"]

    def copy(self) -> Path:
        folder = Path(tempfile.mkdtemp(prefix="content-hash-"))
        self.addCleanup(shutil.rmtree, folder)
        shutil.copytree(CONTENT_HASH / "stack", folder / "stack")
        return folder / "stack"

    def test_shared_folder_gives_expected_hash(self):
        problems = stackcatalog.Problems()
        entries = stackcatalog.check([CONTENT_HASH / "stack"], CATALOG.parent, problems)
        self.assertEqual(problems.errors, [])
        self.assertEqual(entries[0].members, sorted(self.MEMBERS, key=stackcatalog.utf8_key))
        stack = CONTENT_HASH / "stack"
        self.assertEqual(stackcatalog.content_hash_listing(stack, self.MEMBERS), (CONTENT_HASH / "listing.txt").read_text())
        self.assertEqual(stackcatalog.content_hash(stack, self.MEMBERS), (CONTENT_HASH / "expected-content-hash.txt").read_text().strip())

    def test_paths_sort_as_bytes(self):
        lines = (CONTENT_HASH / "listing.txt").read_text().splitlines()
        self.assertEqual([line.split("  ", 1)[1] for line in lines],
                         ["apps-extra.yaml", "apps/a.yaml", "apps/b.yaml", "stacktemplate.yaml"])

    def test_readme_icon_and_stack_json_do_not_count(self):
        stack = self.copy()
        expected = (CONTENT_HASH / "expected-content-hash.txt").read_text().strip()
        (stack / "README.md").write_text("changed\n")
        (stack / "icon.svg").write_bytes(SVG)
        (stack / "stack.json").write_text((stack / "stack.json").read_text().replace("Content hash fixture", "Changed"))
        (stack / "example/stackinstance.yaml").write_text("changed\n")
        self.assertEqual(stackcatalog.content_hash(stack, self.MEMBERS), expected)

    def test_one_byte_changes_the_hash(self):
        stack = self.copy()
        expected = (CONTENT_HASH / "expected-content-hash.txt").read_text().strip()
        path = stack / "apps/b.yaml"
        path.write_bytes(path.read_bytes().replace(b"-b\n", b"-c\n", 1))
        self.assertNotEqual(stackcatalog.content_hash(stack, self.MEMBERS), expected)

    def test_a_renamed_file_changes_the_hash(self):
        stack = self.copy()
        expected = (CONTENT_HASH / "expected-content-hash.txt").read_text().strip()
        (stack / "apps/b.yaml").rename(stack / "apps/c.yaml")
        members = ["stacktemplate.yaml", "apps/a.yaml", "apps/c.yaml", "apps-extra.yaml"]
        self.assertNotEqual(stackcatalog.content_hash(stack, members), expected)


class BuildTest(unittest.TestCase):
    def setUp(self) -> None:
        self.repo = Repo(self)
        self.repo.stack("certified-stacks/one", "one", readme="README.md", icon="icon.svg",
                        members=["stacktemplate.yaml", "apps/*.yaml"], files={
                            "stacktemplate.yaml": manifest("StackTemplate", "one"),
                            "apps/x.yaml": manifest("App", "x"),
                            "apps/y.yaml": manifest("App", "y") + "---\n" + manifest("App", "z"),
                            "README.md": "# One\n",
                            "icon.svg": SVG,
                            "example/stackinstance.yaml": manifest("StackInstance", "one"),
                        })
        self.repo.stack("community-stacks/two", "two")

    def output_folder(self) -> Path:
        out = Path(tempfile.mkdtemp(prefix="stackcatalog-out-"))
        self.addCleanup(shutil.rmtree, out)
        return out

    def build(self, version="v1.3.0", date="2026-11-24", previous=None):
        out = self.output_folder() / "release"
        problems = stackcatalog.Problems()
        written = stackcatalog.build(self.repo.root, version, date, previous, out, problems)
        self.assertEqual(problems.errors, [])
        return out, written

    def index(self, out: Path) -> dict:
        return {e["name"]: e for e in json.loads((out / "index.json").read_text())["entries"]}

    def test_index(self):
        out, written = self.build()
        self.assertEqual(written, ["one.tgz", "two.tgz", "index.json"])
        index = json.loads((out / "index.json").read_text())
        self.assertEqual(index["schemaVersion"], 1)
        self.assertEqual(index["catalogVersion"], "v1.3.0")
        one = index["entries"][0]
        self.assertEqual(list(one), list(stackcatalog.INDEX_ENTRY_KEYS))
        self.assertEqual(one["name"], "one")
        self.assertEqual(one["tier"], "Certified")
        self.assertEqual(one["path"], "certified-stacks/one")
        self.assertEqual(one["changedIn"], "v1.3.0")
        self.assertEqual(one["updated"], "2026-11-24")
        self.assertEqual(one["platformVersion"], ">=5.1.0")
        self.assertEqual(one["archive"], "one.tgz")
        self.assertEqual(one["archiveHash"], "sha256:" + hashlib.sha256((out / "one.tgz").read_bytes()).hexdigest())
        self.assertEqual(one["contentHash"], stackcatalog.content_hash(
            self.repo.root / "certified-stacks/one", ["apps/x.yaml", "apps/y.yaml", "stacktemplate.yaml"]))
        self.assertEqual(one["members"], [
            {"kind": "App", "name": "x"}, {"kind": "App", "name": "y"}, {"kind": "App", "name": "z"},
            {"kind": "StackTemplate", "name": "one"}])
        self.assertEqual(index["entries"][1]["tier"], "Community")

    def test_archive_content(self):
        out, _ = self.build()
        with tarfile.open(out / "one.tgz") as tar:
            members = tar.getmembers()
            self.assertEqual([m.name for m in members],
                             ["README.md", "apps/x.yaml", "apps/y.yaml", "icon.svg", "stack.json", "stacktemplate.yaml"])
            for member in members:
                self.assertTrue(member.isreg())
                self.assertEqual((member.mtime, member.mode, member.uid, member.gid, member.uname, member.gname),
                                 (0, 0o644, 0, 0, "", ""))
                self.assertEqual(tar.extractfile(member).read(), (self.repo.root / "certified-stacks/one" / member.name).read_bytes())
        with gzip.open(out / "one.tgz") as gz:
            gz.read()
        header = (out / "one.tgz").read_bytes()[:10]
        self.assertEqual(header[4:8], b"\x00\x00\x00\x00")  # gzip time
        self.assertEqual(header[3] & 0x08, 0)  # no file name in the gzip header

    def test_build_twice_is_identical(self):
        first, _ = self.build()
        second, _ = self.build()
        for name in ("index.json", "one.tgz", "two.tgz"):
            self.assertEqual((first / name).read_bytes(), (second / name).read_bytes(), name)

    def test_changed_in_and_updated(self):
        first, _ = self.build("v1.3.0", "2026-11-24")
        path = self.repo.root / "certified-stacks/one/apps/x.yaml"
        path.write_text(path.read_text() + "  description: changed\n")
        self.repo.stack("community-stacks/three", "three")
        second, _ = self.build("v1.4.0", "2026-12-01", previous=first / "index.json")
        before, after = self.index(first), self.index(second)
        self.assertEqual((after["one"]["changedIn"], after["one"]["updated"]), ("v1.4.0", "2026-12-01"))
        self.assertNotEqual(after["one"]["contentHash"], before["one"]["contentHash"])
        self.assertNotEqual(after["one"]["archiveHash"], before["one"]["archiveHash"])
        self.assertEqual((after["two"]["changedIn"], after["two"]["updated"]), ("v1.3.0", "2026-11-24"))
        self.assertEqual(after["two"]["contentHash"], before["two"]["contentHash"])
        self.assertEqual(after["two"]["archiveHash"], before["two"]["archiveHash"])
        self.assertEqual((after["three"]["changedIn"], after["three"]["updated"]), ("v1.4.0", "2026-12-01"))

    def test_only_member_changes_count(self):
        first, _ = self.build("v1.3.0", "2026-11-24")
        (self.repo.root / "certified-stacks/one/README.md").write_text("# Changed\n")
        second, _ = self.build("v1.4.0", "2026-12-01", previous=first / "index.json")
        after = self.index(second)
        self.assertEqual(after["one"]["changedIn"], "v1.3.0")
        self.assertNotEqual(after["one"]["archiveHash"], self.index(first)["one"]["archiveHash"])

    def test_build_stops_on_check_errors(self):
        self.repo.stack("community-stacks/bad", "bad", members=["missing.yaml"])
        out = self.output_folder() / "release"
        problems = stackcatalog.Problems()
        written = stackcatalog.build(self.repo.root, "v1.3.0", "2026-11-24", None, out, problems)
        self.assertEqual(written, [])
        self.assertEqual(len(problems.errors), 1)
        self.assertFalse(out.exists())

    def test_bad_options(self):
        out = self.output_folder()
        (out / "full").mkdir()
        (out / "full/old.tgz").write_bytes(b"x")
        cases = [
            ("", "2026-11-24", out / "a", "--catalog-version"),
            ("v1 .3", "2026-11-24", out / "a", "--catalog-version"),
            ("v1.3.0", "2026-13-01", out / "a", "--date"),
            ("v1.3.0", "24.11.2026", out / "a", "--date"),
            ("v1.3.0", "2026-11-24", out / "full", "--output"),
        ]
        for version, date, target, message in cases:
            with self.subTest(message=message, version=version, date=date):
                with self.assertRaises(stackcatalog.CatalogError) as caught:
                    stackcatalog.build(self.repo.root, version, date, None, target, stackcatalog.Problems())
                self.assertIn(message, str(caught.exception))

    def test_previous_index_is_read_strictly(self):
        first, _ = self.build()
        text = (first / "index.json").read_text()
        bad = {
            "unknown schemaVersion": text.replace('"schemaVersion": 1', '"schemaVersion": 2'),
            "unknown key": text.replace('"catalogVersion"', '"extra": 1,\n  "catalogVersion"'),
            "duplicate key": text.replace('"catalogVersion": "v1.3.0"', '"catalogVersion": "v1", "catalogVersion": "v2"'),
            "entry key missing": text.replace('"tier": "Community",', ""),
            "entries not a list": text.replace('"entries": [', '"entries": {"x": [', 1).rstrip()[:-1] + "]}}\n",
            "entry listed twice": json.dumps({**json.loads(text), "entries": json.loads(text)["entries"] * 2}),
            "bad date": text.replace('"updated": "2026-11-24"', '"updated": "24.11.2026"', 1),
            "bad content hash": text.replace('"contentHash": "sha256:', '"contentHash": "sha256:00', 1),
        }
        for label, content in bad.items():
            with self.subTest(label):
                path = first.parent / f"{label}.json"
                path.write_text(content)
                with self.assertRaises(stackcatalog.CatalogError):
                    stackcatalog.build(self.repo.root, "v1.4.0", "2026-12-01", path, first.parent / f"out-{label}",
                                       stackcatalog.Problems())


class CommandLineTest(unittest.TestCase):
    def run_main(self, *args: str) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = stackcatalog.main(list(args))
        return code, out.getvalue(), err.getvalue()

    def test_check_exit_codes(self):
        code, out, err = self.run_main("--root", str(CATALOG.parent), "check", str(FIXTURES / "valid"))
        self.assertEqual((code, err), (0, ""))
        self.assertIn("checked 1 entries: 0 errors, 0 warnings", out)
        code, out, err = self.run_main("--root", str(CATALOG.parent), "check", str(FIXTURES / "invalid-unknown-key"))
        self.assertEqual(code, 1)
        self.assertIn("error: catalog/testdata/stack-json/invalid-unknown-key/stack.json", err)
        self.assertIn("homepage", err)
        code, _, err = self.run_main("check", "/does/not/exist")
        self.assertEqual(code, 2)
        self.assertIn("does not exist", err)


if __name__ == "__main__":
    unittest.main()
