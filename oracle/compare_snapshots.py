"""Validate roc-docx-snapshot/1 documents and compare them on the keys both sides declare.

    compare_snapshots.py A.json B.json
        validate both snapshots and compare them
    compare_snapshots.py --lane ADAPTER[,ADAPTER...] PATH...
        run each adapter (pandoc, libreoffice) over every .docx under PATH,
        validate every snapshot, and compare each pair of adapters per document

Validation is against oracle/snapshot_schema.json. Comparison follows the
contract in that file: only keys in the intersection of the two sides'
`keys` are compared; text compares exactly after line-ending normalization;
dates compare as instants; order is significant; runs are compared after
projecting them onto the shared run keys and joining neighbours that have
become equal.

A disagreement that matches an entry for the snapshot lane in
conformance/accepted-deviations.json is reported as ACCEPTED, separately
from passes. Any other disagreement, or any invalid snapshot, makes the exit
status nonzero.
"""

import datetime
import fnmatch
import json
import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
HERE = pathlib.Path(__file__).resolve().parent
SCHEMA_PATH = HERE / "snapshot_schema.json"
DEVIATIONS = ROOT / "conformance" / "accepted-deviations.json"
ADAPTERS = {"pandoc": HERE / "snapshot_pandoc.py", "libreoffice": HERE / "snapshot_libreoffice.py"}
COLLECTIONS = ["blocks", "notes", "comments", "revisions", "sections"]
RUN_FIELDS = ["bold", "italic", "underline", "strike", "superscript", "subscript", "link"]


# Validation: the subset of JSON Schema that snapshot_schema.json uses.
def validate(value, schema, root, path="$"):
    if "$ref" in schema:
        return validate(value, root["$defs"][schema["$ref"].rsplit("/", 1)[-1]], root, path)
    errors = []
    expected = schema.get("type")
    types = {"object": dict, "array": list, "string": str, "boolean": bool}
    if expected == "integer":
        if not isinstance(value, int) or isinstance(value, bool):
            return [f"{path}: expected integer"]
    elif expected and not isinstance(value, types[expected]):
        return [f"{path}: expected {expected}"]
    if "const" in schema and value != schema["const"]:
        errors.append(f"{path}: expected {schema['const']!r}")
    if "enum" in schema and value not in schema["enum"]:
        errors.append(f"{path}: {value!r} is not one of {schema['enum']}")
    if "minimum" in schema and value < schema["minimum"]:
        errors.append(f"{path}: below {schema['minimum']}")
    if "pattern" in schema and not re.fullmatch(schema["pattern"], value):
        errors.append(f"{path}: {value!r} does not match {schema['pattern']}")
    if expected == "object":
        properties = schema.get("properties", {})
        errors += [f"{path}: missing {name}" for name in schema.get("required", []) if name not in value]
        if schema.get("additionalProperties") is False:
            errors += [f"{path}: unexpected {name}" for name in value if name not in properties]
        for name, child in value.items():
            if name in properties:
                errors += validate(child, properties[name], root, f"{path}.{name}")
    if expected == "array":
        if schema.get("uniqueItems") and len(set(map(json.dumps, value))) != len(value):
            errors.append(f"{path}: items are not unique")
        for index, item in enumerate(value):
            errors += validate(item, schema["items"], root, f"{path}[{index}]")
    return errors


# Normalization, as the contract defines it.
def text(value):
    return value.replace("\r\n", "\n").replace("\r", "\n")


def instant(value):
    if not value:
        return ""
    parsed = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=datetime.timezone.utc)
    return parsed.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def normal(field, value):
    if field in ("date", "created", "modified"):
        return instant(value)
    if isinstance(value, str):
        return text(value)
    if field == "rows":
        return [[text(cell) for cell in row] for row in value]
    return value


def project_runs(runs, fields):
    projected = []
    for run in runs:
        item = {field: run[field] for field in fields}
        if projected and all(projected[-1][field] == item[field] for field in fields):
            projected[-1]["text"] += text(run["text"])
        else:
            projected.append(dict(item, text=text(run["text"])))
    return [run for run in projected if run["text"]]


def project(element, fields, run_fields):
    projected = {field: normal(field, element[field]) for field in fields}
    if run_fields:
        projected["runs"] = project_runs(element["runs"], run_fields)
    return projected


def describe(value):
    return json.dumps(value, ensure_ascii=False)


def compare(a, b):
    """Disagreements as (key, location, message) on the keys both snapshots declare."""
    shared = set(a["keys"]) & set(b["keys"])
    findings = []
    for collection in COLLECTIONS:
        fields = sorted(key.split(".")[1] for key in shared if key.startswith(collection + ".") and key.count(".") == 1)
        run_fields = sorted(key.split(".")[2] for key in shared if key.startswith(collection + ".runs."))
        if not fields and not run_fields:
            continue
        left = [project(element, fields, run_fields) for element in a[collection]]
        right = [project(element, fields, run_fields) for element in b[collection]]
        if len(left) != len(right):
            first = next((i for i, (x, y) in enumerate(zip(left, right)) if x != y), min(len(left), len(right)))
            findings.append((collection, f"{collection}", f"{len(left)} against {len(right)}, first difference at "
                             f"[{first}]: {describe(left[first] if first < len(left) else None)} against "
                             f"{describe(right[first] if first < len(right) else None)}"))
            continue
        for index, (x, y) in enumerate(zip(left, right)):
            for field in fields + (["runs"] if run_fields else []):
                if x[field] != y[field]:
                    key = f"{collection}.{field}" if field != "runs" else f"{collection}.runs"
                    findings.append((key, f"{collection}[{index}].{field}", f"{describe(x[field])} against {describe(y[field])}"))
    for key in sorted(k for k in shared if k.startswith("properties.")):
        field = key.split(".")[1]
        x, y = normal(field, a["properties"][field]), normal(field, b["properties"][field])
        if x != y:
            findings.append((key, key, f"{describe(x)} against {describe(y)}"))
    return findings


def load_deviations():
    if not DEVIATIONS.exists():
        return []
    return [d for d in json.loads(DEVIATIONS.read_text()).get("deviations", []) if "key" in d]


def accepted(deviations, a, b, key, message):
    oracles = {a["producer"]["name"], b["producer"]["name"]}
    return any(d["oracle"] in oracles and fnmatch.fnmatch(a["document"], d["document"]) and d["key"] == key
               and re.search(d["message_pattern"], message) for d in deviations)


def load(path, schema):
    snapshot = json.loads(pathlib.Path(path).read_text())
    return snapshot, validate(snapshot, schema, schema)


def report_pair(a, b, deviations, counts):
    label = f"{a['producer']['name']} against {b['producer']['name']} {a['document']}"
    findings = compare(a, b)
    for key, location, message in findings:
        status = "ACCEPTED" if accepted(deviations, a, b, key, message) else "FAIL"
        counts[status] += 1
        print(f"{status} {label} {location}: {message}")
    if not findings:
        counts["AGREE"] += 1


def lane(adapters, paths, schema, deviations):
    counts = {"AGREE": 0, "ACCEPTED": 0, "FAIL": 0, "INVALID": 0}
    snapshots = {}
    with tempfile.TemporaryDirectory() as tmp:
        for adapter in adapters:
            out = pathlib.Path(tmp) / adapter
            run = subprocess.run([sys.executable, "-I", str(ADAPTERS[adapter]), *paths, "--out", str(out)])
            if run.returncode != 0:
                counts["FAIL"] += 1
                print(f"FAIL {adapter} adapter exited with {run.returncode}")
            for path in sorted(out.rglob("*.json")):
                snapshot, errors = load(path, schema)
                for error in errors:
                    print(f"INVALID {adapter} {path.relative_to(out)}: {error}")
                counts["INVALID"] += bool(errors)
                snapshots.setdefault(snapshot["document"], {})[adapter] = snapshot
    versions = {}
    for by_adapter in snapshots.values():
        for adapter, snapshot in by_adapter.items():
            versions[adapter] = snapshot["producer"]["version"]
    for adapter in adapters:
        print(f"{adapter}: {versions.get(adapter, 'no snapshots')}")
    for document in sorted(snapshots):
        for index, left in enumerate(adapters):
            for right in adapters[index + 1:]:
                pair = snapshots[document]
                if left in pair and right in pair:
                    report_pair(pair[left], pair[right], deviations, counts)
                else:
                    counts["FAIL"] += 1
                    print(f"FAIL {document}: no snapshot from {left if left not in pair else right}")
    total = sum(len(by_adapter) for by_adapter in snapshots.values())
    shown = counts if len(adapters) > 1 else {"FAIL": counts["FAIL"], "INVALID": counts["INVALID"]}
    print(f"summary: {len(snapshots)} documents, {total} snapshots, " + ", ".join(f"{k} {v}" for k, v in shown.items()))
    return 1 if counts["FAIL"] or counts["INVALID"] else 0


def main(argv):
    schema = json.loads(SCHEMA_PATH.read_text())
    deviations = load_deviations()
    if len(argv) >= 3 and argv[0] == "--lane":
        adapters = argv[1].split(",")
        if any(adapter not in ADAPTERS for adapter in adapters):
            sys.exit(f"unknown adapter in {argv[1]}; known: {', '.join(ADAPTERS)}")
        return lane(adapters, argv[2:], schema, deviations)
    if len(argv) != 2:
        sys.exit(__doc__)
    (a, a_errors), (b, b_errors) = load(argv[0], schema), load(argv[1], schema)
    for path, errors in ((argv[0], a_errors), (argv[1], b_errors)):
        for error in errors:
            print(f"INVALID {path}: {error}")
    if a_errors or b_errors:
        return 1
    counts = {"AGREE": 0, "ACCEPTED": 0, "FAIL": 0}
    report_pair(a, b, deviations, counts)
    print("summary: " + ", ".join(f"{k} {v}" for k, v in counts.items()))
    return 1 if counts["FAIL"] else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
