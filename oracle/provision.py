"""Fetch and verify the standards corpus the oracle lanes need.

    provision.py          fetch every `schemas` and `file` entry of conformance/ledger.json
    provision.py --all    also fetch the `reference` entries (large PDFs)

Downloads land in .roc-docx/oracle/downloads/ and are verified against the
ledger's sha256 and size before anything is extracted; a mismatch deletes the
download and fails. Schemas are unpacked under .roc-docx/oracle/schemas/, and
two adapters are written beside them: wrapper schemas that import the W3C
xml.xsd the ECMA files reference without a location, and an XML catalog that
maps the remote locations inside the OPC and Dublin Core schemas to the
verified local files, so xmllint runs with --nonet.

Nothing from the ECMA archives is modified or committed; set
ROC_DOCX_ORACLE_DIR to provision elsewhere.
"""

import hashlib
import json
import os
import pathlib
import shutil
import sys
import urllib.request
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
LEDGER = ROOT / "conformance" / "ledger.json"
ORACLE_DIR = pathlib.Path(os.environ.get("ROC_DOCX_ORACLE_DIR", ROOT / ".roc-docx" / "oracle"))
DOWNLOADS = ORACLE_DIR / "downloads"
SCHEMAS = ORACLE_DIR / "schemas"
# Some standards hosts refuse the default urllib agent.
USER_AGENT = "roc-docx-oracle-provision/1 (+https://github.com/lukewilliamboswell/roc-docx)"

WRAPPERS = {
    # Each wrapper imports the XML namespace schema first, then the target
    # schema, so the `xml:space` and `xml:lang` references resolve.
    "wml.xsd": ("http://schemas.openxmlformats.org/wordprocessingml/2006/main", "../transitional/wml.xsd"),
    "dml-main.xsd": ("http://schemas.openxmlformats.org/drawingml/2006/main", "../transitional/dml-main.xsd"),
    "opc-coreProperties.xsd": ("http://schemas.openxmlformats.org/package/2006/metadata/core-properties", "../opc/opc-coreProperties.xsd"),
}


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download(entry):
    target = DOWNLOADS / (entry["id"] + pathlib.PurePosixPath(entry["url"]).suffix)
    if not target.exists():
        print(f"fetching {entry['url']}")
        DOWNLOADS.mkdir(parents=True, exist_ok=True)
        request = urllib.request.Request(entry["url"], headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(request, timeout=120) as response, open(target, "wb") as out:
            shutil.copyfileobj(response, out)
    actual = (sha256(target), target.stat().st_size)
    expected = (entry["sha256"], entry["bytes"])
    if actual != expected:
        target.unlink()
        sys.exit(f"{entry['id']}: digest or size mismatch: got {actual}, ledger says {expected}")
    print(f"verified {entry['id']} ({entry['bytes']} bytes)")
    return target


def extract_members(entry, archive_path):
    with zipfile.ZipFile(archive_path) as outer:
        for member in entry.get("members", []):
            destination = SCHEMAS / member["extract_to"]
            if destination.exists():
                shutil.rmtree(destination)
            destination.mkdir(parents=True)
            with outer.open(member["path"]) as inner_bytes:
                inner_path = destination / "_member.zip"
                inner_path.write_bytes(inner_bytes.read())
            with zipfile.ZipFile(inner_path) as inner:
                for info in inner.infolist():
                    name = pathlib.PurePosixPath(info.filename)
                    if name.is_absolute() or ".." in name.parts:
                        sys.exit(f"{entry['id']}: refusing archive member {info.filename}")
                    inner.extract(info, destination)
            inner_path.unlink()
            print(f"unpacked {member['path']} to {destination.relative_to(ORACLE_DIR)}")


def write_wrappers():
    wrappers = SCHEMAS / "wrappers"
    wrappers.mkdir(parents=True, exist_ok=True)
    for name, (namespace, location) in WRAPPERS.items():
        (wrappers / name).write_text(
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<!-- Written by oracle/provision.py: supplies the XML namespace schema the ECMA-376 files import without a location. -->\n'
            '<xsd:schema xmlns:xsd="http://www.w3.org/2001/XMLSchema" elementFormDefault="qualified">\n'
            '  <xsd:import namespace="http://www.w3.org/XML/1998/namespace" schemaLocation="../w3c/xml.xsd"/>\n'
            f'  <xsd:import namespace="{namespace}" schemaLocation="{location}"/>\n'
            '</xsd:schema>\n')


def write_catalog(entries):
    lines = ['<?xml version="1.0"?>', '<catalog xmlns="urn:oasis:names:tc:entity:xmlns:xml:catalog">']
    for entry in entries:
        for uri in entry.get("catalog_uris", []):
            local = (SCHEMAS / entry["copy_to"]).as_uri()
            lines.append(f'  <uri name="{uri}" uri="{local}"/>')
            lines.append(f'  <system systemId="{uri}" uri="{local}"/>')
    lines.append("</catalog>")
    (ORACLE_DIR / "catalog.xml").write_text("\n".join(lines) + "\n")


def main(argv):
    ledger = json.loads(LEDGER.read_text())
    wanted = {"schemas", "file"} | ({"reference"} if "--all" in argv else set())
    fetched = []
    for entry in ledger["standards"]:
        if entry.get("fetch", "none") not in wanted:
            continue
        path = download(entry)
        if entry["fetch"] == "schemas":
            extract_members(entry, path)
        elif entry["fetch"] == "file":
            destination = SCHEMAS / entry["copy_to"]
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, destination)
            fetched.append(entry)
    write_wrappers()
    write_catalog(fetched)
    (ORACLE_DIR / "provisioned.json").write_text(json.dumps({"ledger_sha256": sha256(LEDGER), "reviewed_on": ledger["reviewed_on"]}, indent=2))
    print(f"provisioned under {ORACLE_DIR}")


if __name__ == "__main__":
    main(sys.argv[1:])
