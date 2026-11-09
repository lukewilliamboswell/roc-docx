"""Turn a Google Docs export into the fixture tests/fixtures/gdocs/resume.docx.

    scrub_gdocs_fixture.py EXPORT.docx

A maintainer task that neither `check` nor CI runs: only a person with a
Google account can export a document from Google Docs, so the export is made
by hand and this script makes it fit to commit. It changes exactly this and
nothing else:

* Every author, initials and user identifier attribute, and the document
  properties' creator and last editor, become a fictional person, because
  Google Docs stamps the exporting account's name on comments and revisions.
* The embedded fonts are removed: each `word/fonts/` part a font relationship
  of the font table targets, those relationships, the font table's embedding
  elements that name them, and the content-type default for `.ttf`. The
  fonts are third-party files, and they would make up nearly all of the
  archive. The font table itself, its `w:font` entries and every other part
  stay.

Every other entry is copied with its stored bytes, header and data
descriptor unchanged; the entries that change are deflated again with the
same flags. The result is checked before it is written: no part may contain
the maintainer's names, every relationship must resolve to a part and every
`r:id` to a relationship, and LibreOffice must convert it.

The export is untrusted input: entry sizes are bounded, and nothing in it is
used as a path.
"""

import io
import os
import pathlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile
import zlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "tests" / "fixtures" / "gdocs" / "resume.docx"
ENTRY_LIMIT = 16 * 1024 * 1024
PRIVATE = ["luke", "william", "boswell", "lukewilliamboswell"]
FICTIONAL = [("Morgan Reviewer", "MR")]

FONT_REL = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/font"
PACKAGE_RELS = "http://schemas.openxmlformats.org/package/2006/relationships"
R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
DESCRIPTOR = 0x08074B50


def entries(blob):
    """Each entry's info and its raw local record: header, stored data and data descriptor."""
    with zipfile.ZipFile(io.BytesIO(blob)) as archive:
        infos = archive.infolist()
    out = []
    for info in infos:
        if info.file_size > ENTRY_LIMIT or info.compress_size > ENTRY_LIMIT:
            raise SystemExit(f"{info.filename}: larger than {ENTRY_LIMIT} bytes")
        signature, = struct.unpack("<I", blob[info.header_offset:info.header_offset + 4])
        if signature != 0x04034B50:
            raise SystemExit(f"{info.filename}: no local header at its offset")
        name_length, extra_length = struct.unpack("<HH", blob[info.header_offset + 26:info.header_offset + 30])
        data_start = info.header_offset + 30 + name_length + extra_length
        end = data_start + info.compress_size
        if info.flag_bits & 0x08:
            end += 16 if struct.unpack("<I", blob[end:end + 4])[0] == DESCRIPTOR else 12
        out.append((info, bytes(blob[info.header_offset:end])))
    return out


def dos_time(date_time):
    year, month, day, hour, minute, second = date_time
    return (hour << 11) | (minute << 5) | (second // 2), ((year - 1980) << 9) | (month << 5) | day


def deflated(info, data):
    """A new local record for changed content, with the entry's name, flags and time."""
    compressor = zlib.compressobj(9, zlib.DEFLATED, -15)
    stored = compressor.compress(data) + compressor.flush()
    crc = zlib.crc32(data) & 0xFFFFFFFF
    name = info.filename.encode("utf-8")
    time, date = dos_time(info.date_time)
    described = info.flag_bits & 0x08
    sizes = (0, 0, 0) if described else (crc, len(stored), len(data))
    header = struct.pack("<IHHHHHIIIHH", 0x04034B50, info.extract_version, info.flag_bits, zipfile.ZIP_DEFLATED,
                         time, date, *sizes, len(name), 0) + name
    tail = struct.pack("<IIII", DESCRIPTOR, crc, len(stored), len(data)) if described else b""
    return header + stored + tail, crc, len(stored), len(data)


def archive(records):
    """An archive of (info, local record, crc, stored size, size) in order."""
    local, central = bytearray(), bytearray()
    for info, record, crc, stored_size, size in records:
        offset = len(local)
        local += record
        time, date = dos_time(info.date_time)
        name = info.filename.encode("utf-8")
        central += struct.pack("<IHHHHHHIIIHHHHHII", 0x02014B50, info.create_system << 8 | info.create_version,
                               info.extract_version, info.flag_bits, info.compress_type, time, date, crc,
                               stored_size, size, len(name), len(info.extra), len(info.comment), 0,
                               info.internal_attr, info.external_attr, offset) + name + info.extra + info.comment
    end = struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, len(records), len(records), len(central), len(local), 0)
    return bytes(local + central + end)


def fictional_people(texts):
    """The people the export names, each mapped to a fictional person with initials."""
    names = []
    for text in texts:
        for match in re.finditer(r'\b[\w.]*:?author="([^"]*)"', text):
            if match.group(1) not in names:
                names.append(match.group(1))
        for match in re.finditer(r"<(?:dc:creator|cp:lastModifiedBy)>([^<]*)<", text):
            if match.group(1) not in names:
                names.append(match.group(1))
    if len(names) > len(FICTIONAL):
        raise SystemExit(f"the export names {len(names)} people; add fictional ones")
    return dict(zip(names, FICTIONAL))


def scrub_people(text, people):
    def attribute(match):
        prefix, local, value = match.group(1), match.group(2), match.group(3)
        person = people.get(value, FICTIONAL[0])
        replacement = {"author": person[0], "initials": person[1], "userId": person[0]}[local]
        return f'{prefix}{local}="{replacement}"'

    text = re.sub(r'(\s(?:[\w.]+:)?)(author|initials|userId)="([^"]*)"', attribute, text)
    return re.sub(r"<(dc:creator|cp:lastModifiedBy)>([^<]*)<",
                  lambda m: f"<{m.group(1)}>{people.get(m.group(2), FICTIONAL[0])[0]}<", text)


def without_fonts(parts):
    """Remove the font relationships of the font table, their target parts, the embedding elements
    that name them and the .ttf content-type default."""
    rels_name = "word/_rels/fontTable.xml.rels"
    rels = parts.get(rels_name, "")
    removed = {}
    for match in re.finditer(r"<Relationship\b[^>]*/>", rels):
        element = ET.fromstring(match.group(0).replace("<Relationship", f'<Relationship xmlns="{PACKAGE_RELS}"', 1))
        if element.get("Type") == FONT_REL:
            removed[element.get("Id")] = "word/" + element.get("Target")
    rels = re.sub(r"<Relationship\b[^>]*/>",
                  lambda m: "" if re.search(r'Id="([^"]*)"', m.group(0)).group(1) in removed else m.group(0), rels)
    if "<Relationship " in rels:
        parts[rels_name] = rels
    else:
        parts.pop(rels_name, None)
    parts["word/fontTable.xml"] = re.sub(
        r'<w:embed(?:Regular|Bold|Italic|BoldItalic)\b[^>]*\br:id="([^"]*)"[^>]*/>',
        lambda m: "" if m.group(1) in removed else m.group(0), parts["word/fontTable.xml"])
    parts["[Content_Types].xml"] = re.sub(r'<Default [^>]*Extension="ttf"[^>]*/>', "", parts["[Content_Types].xml"])
    return set(removed.values())


def resolve(rels_name, target):
    """The part a relationship targets, from the name of the relationships part that holds it."""
    pieces = []
    joined = pathlib.PurePosixPath(target[1:]) if target.startswith("/") else pathlib.PurePosixPath(rels_name).parent.parent / target
    for piece in joined.parts:
        if piece == "..":
            pieces = pieces[:-1]
        elif piece != ".":
            pieces.append(piece)
    return "/".join(pieces)


def rels_of(name):
    path = pathlib.PurePosixPath(name)
    return str(path.parent / "_rels" / f"{path.name}.rels").removeprefix("./")


def problems_of(docx, names):
    problems = []
    with zipfile.ZipFile(docx) as result:
        if result.testzip() is not None:
            problems.append("the archive fails its CRC check")
        present = set(result.namelist())
        for name in sorted(present):
            text = result.read(name).decode("utf-8", "replace").lower()
            problems += [f"{name}: contains {needle!r}" for needle in names if needle in text]
        ids_of = {}
        for name in sorted(n for n in present if n.endswith(".rels")):
            ids_of[name] = set()
            for rel in ET.fromstring(result.read(name)):
                ids_of[name].add(rel.get("Id"))
                if rel.get("TargetMode") != "External" and resolve(name, rel.get("Target")) not in present:
                    problems.append(f"{name}: {rel.get('Id')} targets a missing part {rel.get('Target')}")
        for name in sorted(n for n in present if n.endswith(".xml") and n != "[Content_Types].xml"):
            ids = ids_of.get(rels_of(name), set())
            for element in ET.fromstring(result.read(name)).iter():
                for key, value in element.attrib.items():
                    if key.startswith(f"{{{R}}}") and value not in ids:
                        problems.append(f"{name}: {key} names a missing relationship {value}")
        types = ET.fromstring(result.read("[Content_Types].xml"))
        defaults = {e.get("Extension").lower() for e in types if e.tag.endswith("Default")}
        overrides = {e.get("PartName").lstrip("/") for e in types if e.tag.endswith("Override")}
        problems += [f"{name}: no content type" for name in sorted(present - {"[Content_Types].xml"})
                     if name not in overrides and name.rsplit(".", 1)[-1].lower() not in defaults]
        problems += [f"[Content_Types].xml: an override for a missing part {name}" for name in sorted(overrides - present)]
    return problems


def libreoffice_converts(docx):
    soffice = next((c for c in [os.environ.get("SOFFICE"), shutil.which("soffice"),
                                "/Applications/LibreOffice.app/Contents/MacOS/soffice"] if c and pathlib.Path(c).exists()), None)
    if soffice is None:
        return ["LibreOffice not found: set SOFFICE"]
    with tempfile.TemporaryDirectory() as work:
        run = subprocess.run([soffice, f"-env:UserInstallation=file://{work}/profile", "--headless", "--norestore",
                              "--convert-to", "fodt", "--outdir", work, str(docx)], capture_output=True, text=True)
        out = pathlib.Path(work) / (docx.stem + ".fodt")
        if run.returncode != 0 or not out.exists() or "<text:p" not in out.read_text("utf-8"):
            return [f"LibreOffice did not convert it: {run.stderr.strip()}"]
    return []


def main(export):
    blob = export.read_bytes()
    records = entries(blob)
    with zipfile.ZipFile(io.BytesIO(blob)) as source:
        texts = {info.filename: source.read(info).decode("utf-8")
                 for info, _ in records if info.filename.endswith((".xml", ".rels"))}
    people = fictional_people(texts.values())
    parts = {name: scrub_people(text, people) for name, text in texts.items()}
    fonts = without_fonts(parts)
    out = []
    for info, record in records:
        if info.filename in fonts or (info.filename.endswith(".rels") and info.filename not in parts):
            continue
        if info.filename in parts and parts[info.filename] != texts[info.filename]:
            out.append((info, *deflated(info, parts[info.filename].encode("utf-8"))))
        else:
            out.append((info, record, info.CRC, info.compress_size, info.file_size))
    with tempfile.TemporaryDirectory() as work:
        candidate = pathlib.Path(work) / "resume.docx"
        candidate.write_bytes(archive(out))
        problems = problems_of(candidate, PRIVATE + [name.lower() for name in people]) + libreoffice_converts(candidate)
        for problem in problems:
            print(f"FAIL {problem}")
        if problems:
            return 1
        OUT.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(candidate, OUT)
    print(f"wrote {OUT.relative_to(ROOT)}: {len(out)} entries, {len(fonts)} fonts removed, "
          f"{len(people)} people made fictional")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    sys.exit(main(pathlib.Path(sys.argv[1])))
