# Catalog tool

Every stack directory under `certified-stacks/` and `community-stacks/` has a `stack.json` file. It describes one catalog entry: name, display name, description, author, supported Platform versions, and the manifest files to install. `stack.schema.json` defines the format.

`stackcatalog.py` has two commands:

- `check` finds mistakes in the `stack.json` files.
- `build` writes the files of a catalog release.

## Prerequisites

- Python 3.10 or later
- PyYAML: `python3 -m pip install pyyaml` or `apt-get install python3-yaml`
- jsonschema: `python3 -m pip install jsonschema` or `apt-get install python3-jsonschema`

If one is missing, the tool says which one and exits with code 2.

## check

```bash
python3 catalog/stackcatalog.py check            # the whole repository
python3 catalog/stackcatalog.py check PATH ...   # only these stack.json files or folders
```

`check` skips folders named `source`. The Run:ai variants are generated from `certified-stacks/run-ai/source/`, which holds a second copy of their `stack.json`.

Each problem is printed on its own line, on stderr. A summary line goes to stdout. The exit code is 0 when there is no error, 1 when there is at least one, and 2 when the tool cannot run.

### What `stack.json` must be

- Valid JSON in UTF-8, without a byte order mark, duplicate keys, trailing commas, `NaN` or `Infinity`.
- Valid against `stack.schema.json`. The key `version` is allowed and ignored.

### Errors

Files and paths:

- A file given to `check` is not named `stack.json`.
- Two entries have the same `name`.
- A path starts with `/`, contains `\`, or has an empty, `.` or `..` part.
- A path names no file, or a glob matches no file.
- The `readme` or `icon` is a glob. Each must name one file.
- A file cannot be read.
- `stack.json`, a member file, the README or the icon is a symbolic link, or is inside a linked folder.
- A linked folder sits outside a stack directory. `check` does not follow links, so it could miss a `stack.json` there.

Globs in `members`:

- Only `*` is allowed. It matches any part of one file or folder name, also names that start with a dot.
- `?`, `[`, `]`, `{`, `}` and `**` are errors. Python and Go treat them differently.
- After the first `*`, names must match exactly, with the same upper and lower case, even on macOS.
- Folders that a glob matches are skipped.

Member files:

- The file is not valid YAML, holds nothing, or uses YAML anchors or aliases (`&name`, `*name`).
- A document is not `apiVersion: management.loft.sh/v1` with kind App, ArgoCDApplicationTemplate, NodeProfile, StackTemplate or VirtualClusterTemplate.
- A document has no `metadata.name`, or has a key that is not a string.
- One entry lists the same kind and name twice.
- Two entries list the same kind and name with different content. Comments, indentation and key order do not count.

Icon:

- It is larger than 65,536 bytes.
- It is not a PNG or an SVG, or its file extension does not match its content.
- A PNG is larger than 512 by 512 pixels.
- An SVG is not UTF-8, declares an encoding other than `utf-8` (upper or lower case), has a DOCTYPE, or is not valid XML.
- The root element of an SVG is not `svg` in the namespace `http://www.w3.org/2000/svg`.

### Warning

`check` warns when an App contains a Platform object of one of the five kinds above in a text field. The App creates that object when it runs, so the catalog cannot see or manage it.

## build

```bash
python3 catalog/stackcatalog.py build \
  --catalog-version v1.3.0 \
  --date 2026-11-24 \
  --previous-index previous/index.json \
  --output release/
```

`build` first runs `check` on the whole repository and stops on any error. The output folder must be empty or not exist yet. It then writes:

- One `<entry name>.tgz` per entry, with its `stack.json`, member files, README and icon.
- `index.json`, with `schemaVersion` 1, `catalogVersion`, and one item per entry, sorted by name. Each item has `name`, `tier` (`Certified` or `Community`, from the top folder), `path`, `contentHash`, `changedIn`, `updated`, `platformVersion`, `archive`, `archiveHash` and `members`.

### Previous index

`--previous-index` is the `index.json` of the last release. When an entry's `contentHash` is unchanged, it keeps its old `changedIn` and `updated`. New and changed entries get `--catalog-version` and `--date`. Without a previous index, every entry gets them.

The build stops when the previous index has an unknown key, an entry listed twice, a bad `contentHash` or date, `entries` that is not a list, or a `schemaVersion` other than 1.

### Content hash

1. For each member file, write one line: the file's SHA-256 in hex, two spaces, its path in the stack directory, and a newline.
2. Sort the lines by path, byte by byte.
3. The content hash is `sha256:` followed by the SHA-256 of all the lines.

The README, the icon and `stack.json` are not included. `testdata/content-hash/` holds a sample stack directory, its lines (`listing.txt`) and its hash (`expected-content-hash.txt`). The Platform uses a copy of this folder to check that it computes the same hash.

### Archives

Two builds of the same files give the same archive bytes. Files are sorted by path, with time 0, mode 0644, and owner and group 0. The gzip header has time 0 and no file name.

This holds with the standard zlib library. Systems that use zlib-ng instead, such as Fedora, compress differently and give other archive hashes.

## Tests

```bash
python3 -B -m unittest discover -s catalog
```

`-B` stops Python from writing a `__pycache__` folder into `catalog/`. Git does not ignore that folder.
