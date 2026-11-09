"""Validate every XML part of .docx files against the pinned ECMA-376 schemas.

    validate_schema.py PATH [PATH...] [--raw] [--json REPORT]

PATH is a .docx file, a directory searched recursively for .docx files, or an
extracted package directory containing [Content_Types].xml. Each XML part is
validated with xmllint against the schema its root namespace selects, after
the Part 3 preprocessing in mce_strip.py unless --raw is given. A part whose
root namespace has no schema in the corpus (Microsoft extension parts) is
reported as UNSCHEMED and checked for well-formedness only.

A failure every message of which matches an entry in
conformance/accepted-deviations.json is reported as ACCEPTED. Any other
failure makes the exit status nonzero.

Documents are untrusted: archive entries are size-capped and never written
outside the temporary directory.
"""

import json
import pathlib
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile

# `python3 -I` does not put the script directory on the path; the adapter beside this file is the only local import.
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import mce_strip  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
ORACLE_DIR = pathlib.Path(__import__("os").environ.get("ROC_DOCX_ORACLE_DIR", ROOT / ".roc-docx" / "oracle"))
SCHEMAS = ORACLE_DIR / "schemas"
DEVIATIONS = ROOT / "conformance" / "accepted-deviations.json"
PART_LIMIT = 64 * 1024 * 1024
TOTAL_LIMIT = 256 * 1024 * 1024

# Root namespace of a part to the schema that validates it (relative to SCHEMAS).
SCHEMA_FOR = {
    "http://schemas.openxmlformats.org/wordprocessingml/2006/main": "wrappers/wml.xsd",
    "http://schemas.openxmlformats.org/package/2006/content-types": "opc/opc-contentTypes.xsd",
    "http://schemas.openxmlformats.org/package/2006/relationships": "opc/opc-relationships.xsd",
    "http://schemas.openxmlformats.org/package/2006/metadata/core-properties": "wrappers/opc-coreProperties.xsd",
    "http://schemas.openxmlformats.org/officeDocument/2006/extended-properties": "transitional/shared-documentPropertiesExtended.xsd",
    "http://schemas.openxmlformats.org/officeDocument/2006/custom-properties": "transitional/shared-documentPropertiesCustom.xsd",
    "http://schemas.openxmlformats.org/drawingml/2006/main": "wrappers/dml-main.xsd",
}


def root_namespace(path):
    for _event, element in ET.iterparse(path, events=("start",)):
        return mce_strip.namespace_of(element.tag)
    return ""


def xmllint(args):
    env = dict(__import__("os").environ, XML_CATALOG_FILES=str(ORACLE_DIR / "catalog.xml"))
    run = subprocess.run(["xmllint", "--noout", "--nonet", *args], capture_output=True, text=True, env=env)
    messages = [line for line in run.stderr.splitlines() if line.strip() and not line.endswith(" validates")]
    return run.returncode, messages


def load_deviations():
    if not DEVIATIONS.exists():
        return []
    return [d for d in json.loads(DEVIATIONS.read_text()).get("deviations", []) if d.get("oracle") == "schema"]


def accepted(deviations, document, part, messages):
    applicable = [d for d in deviations
                  if pathlib.PurePosixPath(document).match(d["document"]) and d["part"] == part]
    if not applicable or not messages:
        return False
    return all(any(re.search(d["message_pattern"], message) for d in applicable) for message in messages)


def extract(docx, into):
    total = 0
    with zipfile.ZipFile(docx) as archive:
        for info in archive.infolist():
            name = pathlib.PurePosixPath(info.filename)
            if name.is_absolute() or ".." in name.parts or info.file_size > PART_LIMIT:
                raise ValueError(f"refusing entry {info.filename}")
            total += info.file_size
            if total > TOTAL_LIMIT:
                raise ValueError("archive exceeds the total size limit")
            archive.extract(info, into)


def xml_parts(package_dir):
    for path in sorted(package_dir.rglob("*")):
        if path.is_file() and path.suffix.lower() in {".xml", ".rels"}:
            yield path


def validate_package(label, package_dir, raw, deviations, results):
    for part in xml_parts(package_dir):
        part_name = part.relative_to(package_dir).as_posix()
        ok, messages = xmllint([str(part)])
        if ok != 0:
            results.append((label, part_name, "FAIL", ["not well-formed", *messages]))
            continue
        ns = root_namespace(part)
        schema = SCHEMA_FOR.get(ns)
        if schema is None:
            results.append((label, part_name, "UNSCHEMED", [ns]))
            continue
        target = part
        if not raw:
            target = part.with_suffix(part.suffix + ".mce.xml")
            mce_strip.strip(part, target)
        code, messages = xmllint(["--schema", str(SCHEMAS / schema), str(target)])
        if code == 0:
            results.append((label, part_name, "PASS", []))
        elif accepted(deviations, label, part_name, messages):
            results.append((label, part_name, "ACCEPTED", messages))
        else:
            results.append((label, part_name, "FAIL", messages))


def documents(paths):
    for raw_path in paths:
        path = pathlib.Path(raw_path)
        if path.is_dir() and (path / "[Content_Types].xml").exists():
            yield path, path
        elif path.is_dir():
            for docx in sorted(path.rglob("*.docx")):
                yield docx, None
        elif path.suffix.lower() == ".docx":
            yield path, None
        else:
            sys.exit(f"not a .docx or directory: {path}")


def main(argv):
    raw = "--raw" in argv
    report_path = None
    if "--json" in argv:
        report_path = argv[argv.index("--json") + 1]
        argv = [a for i, a in enumerate(argv) if a != "--json" and argv[i - 1] != "--json"]
    paths = [a for a in argv if not a.startswith("--")]
    if not paths:
        sys.exit(__doc__)
    if not (SCHEMAS / "wrappers" / "wml.xsd").exists():
        sys.exit(f"schemas not provisioned under {SCHEMAS}: run oracle/provision.py")
    deviations = load_deviations()
    results = []
    with tempfile.TemporaryDirectory() as tmp:
        for index, (document, package_dir) in enumerate(documents(paths)):
            label = document.relative_to(ROOT).as_posix() if document.is_relative_to(ROOT) else str(document)
            if package_dir is None:
                package_dir = pathlib.Path(tmp) / str(index)
                try:
                    extract(document, package_dir)
                except (zipfile.BadZipFile, ValueError) as error:
                    results.append((label, "", "FAIL", [f"cannot open archive: {error}"]))
                    continue
            validate_package(label, package_dir, raw, deviations, results)
    counts = {}
    for label, part, status, messages in results:
        counts[status] = counts.get(status, 0) + 1
        if status in {"FAIL", "ACCEPTED"}:
            print(f"{status} {label} {part}")
            for message in messages[:5]:
                print(f"    {message}")
    print("summary: " + ", ".join(f"{k} {counts.get(k, 0)}" for k in ("PASS", "ACCEPTED", "UNSCHEMED", "FAIL")))
    if report_path:
        pathlib.Path(report_path).write_text(json.dumps(
            [{"document": d, "part": p, "status": s, "messages": m} for d, p, s, m in results], indent=2))
    return 1 if counts.get("FAIL") else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
