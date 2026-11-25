#!/usr/bin/env python3
"""Check every stack.json of this repository and build the catalog release files.

  check [PATH ...]   Check the stack.json files under certified-stacks/ and community-stacks/,
                     or only those under the given files and folders.
  build              Check the whole repository, then write one <entry name>.tgz per entry and
                     index.json into an output folder.

See catalog/README.md for the rules. The Platform reads the same files in Go, so the rules for
paths, globs, links, icons and the content hash must stay the same on both sides.
"""
from __future__ import annotations

import argparse
import datetime
import gzip
import hashlib
import importlib
import io
import json
import os
import posixpath
import re
import struct
import sys
import tarfile
import xml.etree.ElementTree as ElementTree
from pathlib import Path

TOOL_DIR = Path(__file__).resolve().parent
SCHEMA_PATH = TOOL_DIR / "stack.schema.json"
DEFAULT_ROOT = TOOL_DIR.parent

STACK_FILE = "stack.json"
STACK_FOLDERS = {"certified-stacks": "Certified", "community-stacks": "Community"}
# Generated Run:ai folders are rendered from source/, which holds a second copy of their
# stack.json with the same entry name.
SKIPPED_FOLDER = "source"

API_VERSION = "management.loft.sh/v1"
MEMBER_KINDS = ("App", "ArgoCDApplicationTemplate", "NodeProfile", "StackTemplate", "VirtualClusterTemplate")

# Only "*" is allowed: Python's glob and Go's fs.Glob read the other characters differently.
GLOB_FORBIDDEN = ("?", "[", "]", "{", "}", "**")

# The characters the Platform refuses in a path. A file name that is not UTF-8 reaches
# Python with surrogate characters in it, and Go's fs.ValidPath refuses such a name.
FORBIDDEN_IN_PATH = re.compile(r"[\\:\x00-\x1f\x7f\ud800-\udfff]")

ICON_MAX_BYTES = 64 * 1024
ICON_MAX_PIXELS = 512
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
SVG_ROOT = "{http://www.w3.org/2000/svg}svg"
XML_ENCODING = re.compile(r"""\A\ufeff?<\?xml\s[^>]*?\bencoding\s*=\s*["']([^"']*)["']""")
DATE = re.compile(r"\d{4}-\d{2}-\d{2}")
CONTENT_HASH = re.compile(r"sha256:[0-9a-f]{64}")

INDEX_SCHEMA_VERSION = 1
INDEX_ENTRY_KEYS = (
    "name", "tier", "path", "contentHash", "changedIn", "updated",
    "platformVersion", "archive", "archiveHash", "members",
)


class CatalogError(Exception):
    """A problem that stops the command: a bad option, an unreadable previous index."""


class Problems:
    def __init__(self) -> None:
        self.errors: list[str] = []
        self.warnings: list[str] = []

    def error(self, where: str, message: str) -> None:
        self.errors.append(f"error: {where}: {message}")

    def warn(self, where: str, message: str) -> None:
        self.warnings.append(f"warning: {where}: {message}")


class Entry:
    def __init__(self, stack_file: Path, shown: str) -> None:
        self.directory = stack_file.parent
        # The stack.json path as messages show it.
        self.shown = shown
        self.data: dict = {}
        self.members: list[str] = []
        # (kind, name, canonical JSON of the object, member path as shown)
        self.objects: list[tuple[str, str, str, str]] = []

    @property
    def name(self) -> str:
        return self.data["name"]

    def shown_member(self, path: str) -> str:
        return posixpath.join(posixpath.dirname(self.shown), path)


# ---------- reading ----------

PREREQUISITES = (
    ("yaml", "PyYAML (python3 -m pip install pyyaml, or apt-get install python3-yaml)"),
    ("jsonschema", "jsonschema (python3 -m pip install jsonschema, or apt-get install python3-jsonschema)"),
)


def missing_prerequisites() -> list[str]:
    missing = []
    for module, hint in PREREQUISITES:
        try:
            importlib.import_module(module)
        except ImportError:
            missing.append(hint)
    return missing


def load_json_strict(data: bytes):
    """Read JSON the way the Platform's strict decoder does.

    Python's json module accepts a duplicate key and NaN by default. Go refuses both, and also a
    byte order mark and invalid UTF-8, so this refuses them too. Trailing commas are already an
    error in Python.
    """
    if data.startswith(b"\xef\xbb\xbf"):
        raise ValueError("starts with a byte order mark")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as err:
        raise ValueError(f"is not valid UTF-8 (byte {err.start})") from None

    def no_duplicates(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"has the key {key!r} twice")
            result[key] = value
        return result

    def no_constant(name):
        raise ValueError(f"holds {name}, which is not JSON")

    try:
        return json.loads(text, object_pairs_hook=no_duplicates, parse_constant=no_constant)
    except json.JSONDecodeError as err:
        raise ValueError(f"is not valid JSON: {err.msg} (line {err.lineno}, column {err.colno})") from None


_validator = None


def schema_errors(document) -> list[str]:
    global _validator
    if _validator is None:
        import jsonschema

        schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
        _validator = jsonschema.Draft7Validator(schema)
    found = []
    for err in sorted(_validator.iter_errors(document), key=lambda e: [str(p) for p in e.absolute_path]):
        where = "$" + "".join(f"[{p}]" if isinstance(p, int) else f".{p}" for p in err.absolute_path)
        found.append(f"{where}: {err.message}")
    return found


# ---------- paths ----------

def path_problem(path: str) -> str | None:
    """The path rules of the Platform's validatePath, which it uses to open the same files."""
    if path.startswith("/"):
        return "is absolute"
    if FORBIDDEN_IN_PATH.search(path):
        return "has a backslash, a colon or a control character"
    for segment in path.split("/"):
        if segment == "":
            return "has an empty segment"
        if segment in (".", ".."):
            return f"has a {segment!r} segment"
    return None


def link_on_path(base: Path, relative: str) -> str | None:
    """The first part of base/relative that is a symbolic link, as a relative path."""
    current = base
    parts = relative.split("/")
    for i, part in enumerate(parts):
        current = current / part
        if current.is_symlink():
            return "/".join(parts[: i + 1])
    return None


def expand_glob(directory: Path, pattern: str) -> list[str]:
    """Expand a member path in which "*" matches any characters inside one folder name.

    It follows Go's fs.Glob, which the Platform uses on the same patterns:
    - "*" also matches a name that starts with a dot (Python's glob skips those).
    - The folders before the first segment with a "*" are opened by path. From that segment on,
      every name is compared with the folder listing exactly, so a name in another case does not
      match, also on a file system that ignores case.
    Returns every existing path, files and folders, so the caller can tell them apart.
    """
    segments = pattern.split("/")
    first_glob = next((i for i, s in enumerate(segments) if "*" in s), len(segments))
    found = [""]
    for index, segment in enumerate(segments):
        next_found = []
        for prefix in found:
            candidate = posixpath.join(prefix, segment) if prefix else segment
            if index < first_glob:
                if os.path.lexists(directory / candidate):
                    next_found.append(candidate)
                continue
            base = directory / prefix if prefix else directory
            # A linked folder is listed too: the caller then reports the link.
            if not base.is_dir():
                continue
            matcher = re.compile("[\\s\\S]*".join(re.escape(part) for part in segment.split("*")))
            for name in sorted(os.listdir(base)):
                if matcher.fullmatch(name):
                    next_found.append(posixpath.join(prefix, name) if prefix else name)
        found = next_found
    return found


def utf8_key(path: str) -> bytes:
    # Sort as bytes so that Go's sort of the same strings gives the same order.
    return path.encode("utf-8")


# ---------- icon ----------

def icon_problem(data: bytes, path: str) -> str | None:
    if len(data) > ICON_MAX_BYTES:
        return f"is {len(data)} bytes, more than {ICON_MAX_BYTES}"
    if data.startswith(PNG_SIGNATURE):
        if len(data) < 24 or data[12:16] != b"IHDR":
            return "starts like a PNG but has no IHDR header"
        width, height = struct.unpack(">II", data[16:24])
        if width > ICON_MAX_PIXELS or height > ICON_MAX_PIXELS:
            return f"is a PNG of {width} by {height} pixels, more than {ICON_MAX_PIXELS} by {ICON_MAX_PIXELS}"
        kind = "png"
    else:
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            return "is neither a PNG nor a UTF-8 SVG"
        # Checked before parsing, so that no entity in a DOCTYPE is ever expanded.
        if "<!DOCTYPE" in text:
            return "is an SVG with a DOCTYPE, which is not allowed"
        # Python's parser obeys a declared encoding. Go's encoding/xml refuses any but utf-8.
        declared = XML_ENCODING.match(text)
        if declared and declared.group(1).lower() != "utf-8":
            return f"declares the encoding {declared.group(1)!r}, but an SVG icon must be UTF-8"
        try:
            root = ElementTree.fromstring(data)
        except ElementTree.ParseError as err:
            return f"is neither a PNG nor well-formed XML ({err})"
        if root.tag != SVG_ROOT:
            return f"is XML whose root element is {root.tag!r}, not an SVG"
        kind = "svg"
    ending = posixpath.splitext(path)[1].lower().lstrip(".")
    if ending != kind:
        return f"holds a {kind.upper()} but its name ends in .{ending}"
    return None


# ---------- runtime templates ----------

DOCUMENT_SPLIT = re.compile(r"(?m)^---[ \t]*$")
PLATFORM_API = re.compile(r"(?m)^[ \t]*apiVersion:[ \t]*['\"]?management\.loft\.sh/")
KIND_LINE = re.compile(r"(?m)^[ \t]*kind:[ \t]*['\"]?([A-Za-z]+)['\"]?[ \t]*$")


def runtime_templates(document) -> list[tuple[str, str]]:
    """(field, kind) for each Platform template an App writes from one of its strings.

    The strings are Helm templates, so they are searched as text, not parsed as YAML.
    """
    found = []

    def walk(value, where):
        if isinstance(value, dict):
            for key, item in value.items():
                walk(item, f"{where}.{key}")
        elif isinstance(value, list):
            for i, item in enumerate(value):
                walk(item, f"{where}[{i}]")
        elif isinstance(value, str):
            for part in DOCUMENT_SPLIT.split(value):
                kind = KIND_LINE.search(part)
                if PLATFORM_API.search(part) and kind and kind.group(1) in MEMBER_KINDS:
                    found.append((where.lstrip("."), kind.group(1)))

    walk(document.get("spec"), "spec")
    return sorted(set(found))


# ---------- check ----------

LINKED_FOLDER = "is a symbolic link to a folder; links are not followed"


def relative_to_root(path: Path, root: Path) -> str | None:
    """path relative to root, without resolving links (resolving would hide them)."""
    relative = os.path.relpath(os.path.abspath(path), os.path.abspath(root)).replace(os.sep, "/")
    if relative == ".." or relative.startswith("../"):
        return None
    return relative


def shown_path(path: Path, root: Path) -> str:
    return relative_to_root(path, root) or str(path)


def default_stack_folders(root: Path) -> list[Path]:
    return [root / folder for folder in STACK_FOLDERS if (root / folder).is_dir()]


def walk_stack_folder(folder: Path, root: Path, problems: Problems) -> list[Path]:
    """Every stack.json under folder. source/ folders and links to folders are skipped.

    A link to a folder outside a stack directory is an error: it could hold a stack.json that
    would drop out of the catalog unseen. Inside a stack directory the member rules decide.
    """
    found = []
    stack_directories: list[str] = []
    for here, subfolders, files in os.walk(folder):
        absolute = os.path.abspath(here)
        if STACK_FILE in files:
            stack_directories.append(absolute)
            found.append(Path(here) / STACK_FILE)
        inside_entry = any(absolute == d or absolute.startswith(d + os.sep) for d in stack_directories)
        links = {name for name in subfolders if name != SKIPPED_FOLDER and os.path.islink(os.path.join(here, name))}
        if not inside_entry:
            for name in sorted(links):
                problems.error(shown_path(Path(here) / name, root), LINKED_FOLDER)
        subfolders[:] = sorted(name for name in subfolders if name != SKIPPED_FOLDER and name not in links)
    return found


def find_stack_files(paths: list[Path], root: Path, problems: Problems) -> list[Path]:
    """Every stack.json in or under paths, each once, sorted."""
    found: dict[str, Path] = {}
    for path in paths:
        if path.is_symlink() and path.is_dir():
            problems.error(shown_path(path, root), LINKED_FOLDER)
        elif path.is_dir():
            for stack_file in walk_stack_folder(path, root, problems):
                found[os.path.abspath(stack_file)] = stack_file
        elif path.name != STACK_FILE:
            problems.error(shown_path(path, root), f"is not a {STACK_FILE} file")
        else:
            # Also a linked stack.json: read_stack_json reports the link.
            found[os.path.abspath(path)] = path
    return sorted(found.values(), key=lambda p: utf8_key(os.path.abspath(p)))


def yaml_problem(err) -> str:
    """PyYAML's message on one line, so that each problem stays one line."""
    mark = getattr(err, "problem_mark", None)
    problem = getattr(err, "problem", None)
    if mark is not None and problem:
        return f"{problem} (line {mark.line + 1}, column {mark.column + 1})"
    return " ".join(str(err).split())


def non_string_key(value, where: str = "") -> str | None:
    if isinstance(value, dict):
        for key, item in value.items():
            if not isinstance(key, str):
                return f"{where or '.'} has the key {key!r}, which is not a string"
            found = non_string_key(item, f"{where}.{key}")
            if found:
                return found
    elif isinstance(value, list):
        for i, item in enumerate(value):
            found = non_string_key(item, f"{where}[{i}]")
            if found:
                return found
    return None


def read_stack_json(stack_file: Path, root: Path, problems: Problems) -> Entry | None:
    """The entry of a stack.json that is strict JSON and passes the schema."""
    entry = Entry(stack_file, shown_path(stack_file, root))
    inside_root = relative_to_root(stack_file, root)
    link = link_on_path(Path(os.path.abspath(root)), inside_root) if inside_root else None
    if link or stack_file.is_symlink():
        problems.error(entry.shown, f"{link or STACK_FILE} is a symbolic link")
        return None
    try:
        entry.data = load_json_strict(stack_file.read_bytes())
    except OSError as err:
        problems.error(entry.shown, f"cannot be read: {err.strerror}")
        return None
    except ValueError as err:
        problems.error(entry.shown, str(err))
        return None
    found = schema_errors(entry.data)
    for message in found:
        problems.error(entry.shown, message)
    return None if found else entry


def check_readme_and_icon(entry: Entry, problems: Problems) -> None:
    for key in ("readme", "icon"):
        if key not in entry.data:
            continue
        path = entry.data[key]
        problem = "is a glob, but must name one file" if "*" in path else path_problem(path)
        if problem:
            problems.error(entry.shown, f"{key} {path!r} {problem}")
            continue
        link = link_on_path(entry.directory, path)
        if link:
            problems.error(entry.shown, f"{key} {path!r}: {link} is a symbolic link")
            continue
        file = entry.directory / path
        if not file.is_file():
            problems.error(entry.shown, f"{key} {path!r} names no file")
            continue
        try:
            content = file.read_bytes()
        except OSError as err:
            problems.error(entry.shown, f"{key} {path!r} cannot be read: {err.strerror}")
            continue
        problem = icon_problem(content, path) if key == "icon" else None
        if problem:
            problems.error(entry.shown, f"icon {path!r} {problem}")


def expand_members(entry: Entry, problems: Problems) -> list[str]:
    """The member files that the paths and globs under "members" name, sorted."""
    members = set()
    reported_links = set()
    reported_names = set()
    for pattern in entry.data["members"]:
        problem = path_problem(pattern)
        forbidden = [c for c in GLOB_FORBIDDEN if c in pattern]
        if problem is None and forbidden:
            problem = f"uses {', '.join(repr(c) for c in forbidden)}; a member glob may use only '*'"
        if problem:
            problems.error(entry.shown, f"member {pattern!r} {problem}")
            continue
        matched = False
        for path in expand_glob(entry.directory, pattern):
            # Skip folders, linked ones too, as the Platform does.
            if (entry.directory / path).is_dir():
                continue
            link = link_on_path(entry.directory, path)
            if link:
                # The link gets its own error, so it still counts as a match.
                matched = True
                if path not in reported_links:
                    reported_links.add(path)
                    problems.error(entry.shown, f"member {path!r}: {link} is a symbolic link")
            elif (entry.directory / path).is_file():
                matched = True
                # The schema checks only what stack.json says. A line break in a matched
                # name would split a line of the content hash. Checked only for a regular
                # file: the Platform skips anything else before it checks the name.
                problem = path_problem(path)
                if problem is None:
                    members.add(path)
                elif path not in reported_names:
                    reported_names.add(path)
                    problems.error(entry.shown, f"member {path!r} {problem}")
        if not matched:
            what = "matches no file" if "*" in pattern else "names no file"
            problems.error(entry.shown, f"member {pattern!r} {what}")
    return sorted(members, key=utf8_key)


def load_member_file(file: Path, where: str, problems: Problems) -> list:
    """The YAML documents of one member file, or [] after a reported problem."""
    import yaml

    try:
        text = file.read_text(encoding="utf-8")
    except OSError as err:
        problems.error(where, f"cannot be read: {err.strerror}")
        return []
    except UnicodeDecodeError as err:
        problems.error(where, f"is not valid UTF-8 (byte {err.start})")
        return []
    try:
        # Anchors and aliases are refused before any object is built: a small file of nested
        # aliases grows without limit, and an alias to itself never ends.
        if any(isinstance(event, yaml.AliasEvent) or getattr(event, "anchor", None) for event in yaml.parse(text)):
            problems.error(where, "uses a YAML anchor or alias, which a member may not")
            return []
        documents = [d for d in yaml.safe_load_all(text) if d is not None]
    except yaml.YAMLError as err:
        problems.error(where, f"is not valid YAML: {yaml_problem(err)}")
        return []
    if not documents:
        problems.error(where, "holds no object")
    return documents


def member_document_problem(document) -> str | None:
    if not isinstance(document, dict):
        return "is not a mapping"
    api, kind = document.get("apiVersion"), document.get("kind")
    if api != API_VERSION or kind not in MEMBER_KINDS:
        return f"is {api} {kind}; a member must be {API_VERSION} {', '.join(MEMBER_KINDS)}"
    metadata = document.get("metadata")
    name = metadata.get("name") if isinstance(metadata, dict) else None
    if not isinstance(name, str) or not name:
        return f"({kind}) has no metadata.name"
    bad_key = non_string_key(document)
    if bad_key:
        return f"({kind} {name}): {bad_key}"
    return None


def read_member_objects(entry: Entry, problems: Problems) -> None:
    """Read every member file into entry.objects, and warn about Apps that create templates."""
    seen: dict[tuple[str, str], str] = {}
    for path in entry.members:
        where = entry.shown_member(path)
        for number, document in enumerate(load_member_file(entry.directory / path, where, problems), start=1):
            problem = member_document_problem(document)
            if problem:
                problems.error(where, f"document {number} {problem}")
                continue
            kind, name = document["kind"], document["metadata"]["name"]
            if (kind, name) in seen:
                problems.error(where, f"{kind} {name} is also in {seen[(kind, name)]} of the same entry")
                continue
            seen[(kind, name)] = path
            entry.objects.append((kind, name, json.dumps(document, sort_keys=True, default=str), where))
            created = runtime_templates(document) if kind == "App" else []
            if created:
                kinds = sorted({k for _, k in created})
                fields = sorted({f for f, _ in created})
                problems.warn(
                    where,
                    f"App {name} creates {' and '.join(kinds)} objects at runtime ({', '.join(fields)}). "
                    "The catalog cannot see or manage them.",
                )


def read_entry(stack_file: Path, root: Path, problems: Problems) -> Entry | None:
    entry = read_stack_json(stack_file, root, problems)
    if entry is not None:
        check_readme_and_icon(entry, problems)
        entry.members = expand_members(entry, problems)
        read_member_objects(entry, problems)
    return entry


def check(paths: list[Path], root: Path, problems: Problems) -> list[Entry]:
    stack_files = find_stack_files(paths, root, problems)
    if not stack_files and not problems.errors:
        problems.error(", ".join(str(p) for p in paths), f"no {STACK_FILE} found")
        return []
    entries = []
    for stack_file in stack_files:
        entry = read_entry(stack_file, root, problems)
        if entry is not None:
            entries.append(entry)

    by_name: dict[str, Entry] = {}
    for entry in entries:
        if entry.name in by_name:
            problems.error(entry.shown, f"entry name {entry.name!r} is also used by {by_name[entry.name].shown}")
        else:
            by_name[entry.name] = entry

    owners: dict[tuple[str, str], tuple[str, str, str]] = {}
    for entry in entries:
        for kind, name, canonical, file_where in entry.objects:
            key = (kind, name)
            if key not in owners:
                owners[key] = (canonical, entry.name, file_where)
                continue
            other_canonical, other_entry, other_file = owners[key]
            if other_entry != entry.name and other_canonical != canonical:
                problems.error(
                    file_where,
                    f"{kind} {name} differs from the one entry {other_entry!r} lists in {other_file}",
                )
    return entries


# ---------- build ----------

def content_hash_listing(entry_directory: Path, members: list[str]) -> str:
    lines = []
    for path in sorted(members, key=utf8_key):
        digest = hashlib.sha256((entry_directory / path).read_bytes()).hexdigest()
        lines.append(f"{digest}  {path}\n")
    return "".join(lines)


def content_hash(entry_directory: Path, members: list[str]) -> str:
    listing = content_hash_listing(entry_directory, members)
    return "sha256:" + hashlib.sha256(listing.encode("utf-8")).hexdigest()


def archive_bytes(entry: Entry) -> bytes:
    """A .tgz that is the same every time it is built from the same files."""
    files = {STACK_FILE, *entry.members}
    for key in ("readme", "icon"):
        if key in entry.data:
            files.add(entry.data[key])
    tar_buffer = io.BytesIO()
    with tarfile.open(fileobj=tar_buffer, mode="w", format=tarfile.PAX_FORMAT) as tar:
        for path in sorted(files, key=utf8_key):
            data = (entry.directory / path).read_bytes()
            info = tarfile.TarInfo(path)
            info.size = len(data)
            info.mtime = 0
            info.mode = 0o644
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            info.type = tarfile.REGTYPE
            tar.addfile(info, io.BytesIO(data))
    gzip_buffer = io.BytesIO()
    with gzip.GzipFile(filename="", mode="wb", fileobj=gzip_buffer, mtime=0, compresslevel=9) as gz:
        gz.write(tar_buffer.getvalue())
    return gzip_buffer.getvalue()


def read_previous_index(path: Path) -> dict[str, dict]:
    try:
        index = load_json_strict(path.read_bytes())
    except (OSError, ValueError) as err:
        raise CatalogError(f"previous index {path}: {err}") from None
    if not isinstance(index, dict) or set(index) != {"schemaVersion", "catalogVersion", "entries"}:
        raise CatalogError(f"previous index {path}: needs exactly the keys schemaVersion, catalogVersion and entries")
    if index["schemaVersion"] != INDEX_SCHEMA_VERSION:
        raise CatalogError(f"previous index {path}: schemaVersion {index['schemaVersion']!r} is not known")
    if not isinstance(index["entries"], list):
        raise CatalogError(f"previous index {path}: entries is not a list")
    entries = {}
    for item in index["entries"]:
        if not isinstance(item, dict) or set(item) != set(INDEX_ENTRY_KEYS):
            raise CatalogError(f"previous index {path}: an entry does not have exactly the keys {', '.join(INDEX_ENTRY_KEYS)}")
        for key in ("name", "contentHash", "changedIn", "updated"):
            if not isinstance(item[key], str) or not item[key] or any(c.isspace() for c in item[key]):
                raise CatalogError(f"previous index {path}: {key} of an entry is not a string without spaces")
        if not CONTENT_HASH.fullmatch(item["contentHash"]):
            raise CatalogError(f"previous index {path}: entry {item['name']!r} has the contentHash {item['contentHash']!r}")
        if not valid_date(item["updated"]):
            raise CatalogError(f"previous index {path}: entry {item['name']!r} has the date {item['updated']!r}")
        if item["name"] in entries:
            raise CatalogError(f"previous index {path}: the entry {item['name']!r} is listed twice")
        entries[item["name"]] = item
    return entries


def valid_date(value: str) -> bool:
    # Since Python 3.11, fromisoformat alone also accepts other forms, such as 20261124.
    if not DATE.fullmatch(value):
        return False
    try:
        datetime.date.fromisoformat(value)
    except ValueError:
        return False
    return True


def build(root: Path, catalog_version: str, date: str, previous_index: Path | None, output: Path, problems: Problems) -> list[str]:
    if not catalog_version or any(c.isspace() for c in catalog_version):
        raise CatalogError("--catalog-version must be a non-empty string without spaces")
    if not valid_date(date):
        raise CatalogError(f"--date {date!r} is not a date in the form YYYY-MM-DD")
    if output.exists() and (not output.is_dir() or any(output.iterdir())):
        raise CatalogError(f"--output {output} must be an empty folder or not exist yet")
    previous = read_previous_index(previous_index) if previous_index else {}

    entries = check(default_stack_folders(root), root, problems)
    if problems.errors:
        return []

    index_entries = []
    archives = {}
    for entry in sorted(entries, key=lambda e: utf8_key(e.name)):
        path = relative_to_root(entry.directory, root)
        tier = STACK_FOLDERS[path.split("/")[0]]
        digest = content_hash(entry.directory, entry.members)
        archive = archive_bytes(entry)
        before = previous.get(entry.name)
        changed_in, updated = catalog_version, date
        if before is not None and before["contentHash"] == digest:
            changed_in, updated = before["changedIn"], before["updated"]
        archive_name = f"{entry.name}.tgz"
        archives[archive_name] = archive
        index_entries.append({
            "name": entry.name,
            "tier": tier,
            "path": path,
            "contentHash": digest,
            "changedIn": changed_in,
            "updated": updated,
            "platformVersion": entry.data["platformVersion"],
            "archive": archive_name,
            "archiveHash": "sha256:" + hashlib.sha256(archive).hexdigest(),
            "members": [{"kind": kind, "name": name} for kind, name, _, _ in entry.objects],
        })
    index = {"schemaVersion": INDEX_SCHEMA_VERSION, "catalogVersion": catalog_version, "entries": index_entries}

    output.mkdir(parents=True, exist_ok=True)
    written = []
    for archive_name, archive in archives.items():
        (output / archive_name).write_bytes(archive)
        written.append(archive_name)
    (output / "index.json").write_text(json.dumps(index, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    written.append("index.json")
    return written


# ---------- command line ----------

def report(problems: Problems) -> None:
    for line in problems.errors + problems.warnings:
        print(line, file=sys.stderr)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="stackcatalog.py", description=__doc__.split("\n\n")[0])
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT,
                        help="repository root (default: the folder above catalog/)")
    commands = parser.add_subparsers(dest="command", required=True)
    check_parser = commands.add_parser("check", help="check stack.json files")
    check_parser.add_argument("paths", nargs="*", type=Path,
                              help="files or folders to check (default: certified-stacks/ and community-stacks/)")
    build_parser = commands.add_parser("build", help="check the repository, then write the release files")
    build_parser.add_argument("--catalog-version", required=True, help="the release tag, for example v1.3.0")
    build_parser.add_argument("--date", required=True, help="the release date, YYYY-MM-DD")
    build_parser.add_argument("--previous-index", type=Path, help="index.json of the previous release")
    build_parser.add_argument("--output", type=Path, required=True, help="an empty or new folder")
    args = parser.parse_args(argv)

    missing = missing_prerequisites()
    if missing:
        print("cannot run: missing prerequisite(s)", file=sys.stderr)
        for item in missing:
            print(f"  - {item}", file=sys.stderr)
        return 2

    problems = Problems()
    root = args.root
    try:
        if args.command == "check":
            paths = args.paths or default_stack_folders(root)
            for path in paths:
                if not path.exists() and not path.is_symlink():
                    raise CatalogError(f"{path} does not exist")
            entries = check(paths, root, problems)
            report(problems)
            print(f"checked {len(entries)} entries: {len(problems.errors)} errors, {len(problems.warnings)} warnings")
            return 1 if problems.errors else 0
        written = build(root, args.catalog_version, args.date, args.previous_index, args.output, problems)
        report(problems)
        if problems.errors:
            print(f"build stopped: {len(problems.errors)} errors")
            return 1
        for name in written:
            print(f"wrote {args.output / name}")
        return 0
    except CatalogError as err:
        print(f"error: {err}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
