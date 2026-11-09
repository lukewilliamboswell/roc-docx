"""Reduce LibreOffice's reading of a .docx to a roc-docx-snapshot/1 document.

    snapshot_libreoffice.py DOCX                 print the snapshot of one document
    snapshot_libreoffice.py PATH... --out DIR    write DIR/<document>.json for every .docx under PATH

LibreOffice converts each document headless to Flat ODT (`--convert-to fodt`)
in one run with a throwaway profile; this adapter parses that XML and nothing
else, so it shares no logic with the package or with the pandoc adapter.
oracle/snapshot_schema.json defines the contract and lists the keys this
adapter is authoritative for.

Rules this adapter applies, each because of how LibreOffice represents a document:

- Run formatting is what the run's automatic style sets. Automatic styles are
  LibreOffice's form of direct formatting; named character styles such as the
  one it puts on hyperlinks are style formatting and are not run formatting.
- Deleted text lives in the tracked-changes table, not in the body; the body
  holds a marker where it was. Inserted and format-changed text is in the
  body between start and end markers.
- Dates without a zone are UTC: LibreOffice drops the `Z` of the document's
  dates on import and writes it back on export.
- Comments that start at one position, such as a comment and its replies,
  are written in reverse document order; the adapter reverses each such run.
- A paragraph-attribute change has no ODF element and is written as
  `text:UnknownChange`; it is a format change.
- A field (page number, page count, a date) contributes the result it
  displays.
- A list's kind is the kind of its list style at the item's level.
- A section is a run of body content on one page style; its header and footer
  are that page style's default header and footer.
- Comment threads and the properties other than title, creator, created and
  modified are written but not declared: their mapping is not yet verified
  against a second reader.
- Shapes and images contribute no text; one that holds text, like a table
  inside a note or comment, is not modelled and fails the run.
- An element this adapter does not know fails the run instead of being
  dropped silently.

LibreOffice is found through SOFFICE, PATH or the macOS application bundle.
"""

import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

SCHEMA = "roc-docx-snapshot/1"
ROOT = pathlib.Path(__file__).resolve().parent.parent

KEYS = [
    "blocks.kind", "blocks.level", "blocks.list", "blocks.text", "blocks.rows",
    "blocks.runs.bold", "blocks.runs.italic", "blocks.runs.underline", "blocks.runs.strike",
    "blocks.runs.superscript", "blocks.runs.subscript", "blocks.runs.link",
    "notes.kind", "notes.text",
    "comments.author", "comments.date", "comments.text", "comments.anchor", "comments.resolved",
    "revisions.kind", "revisions.author", "revisions.date", "revisions.text",
    "sections.page_width", "sections.page_height", "sections.orientation",
    "sections.margin_top", "sections.margin_bottom", "sections.margin_left", "sections.margin_right",
    "sections.header", "sections.footer",
    "properties.title", "properties.creator", "properties.created", "properties.modified",
]

NS = {
    "office": "urn:oasis:names:tc:opendocument:xmlns:office:1.0",
    "style": "urn:oasis:names:tc:opendocument:xmlns:style:1.0",
    "text": "urn:oasis:names:tc:opendocument:xmlns:text:1.0",
    "table": "urn:oasis:names:tc:opendocument:xmlns:table:1.0",
    "draw": "urn:oasis:names:tc:opendocument:xmlns:drawing:1.0",
    "fo": "urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0",
    "xlink": "http://www.w3.org/1999/xlink",
    "dc": "http://purl.org/dc/elements/1.1/",
    "meta": "urn:oasis:names:tc:opendocument:xmlns:meta:1.0",
    "loext": "urn:org:documentfoundation:names:experimental:office:xmlns:loext:1.0",
}
PLAIN = {"bold": False, "italic": False, "underline": False, "strike": False,
         "superscript": False, "subscript": False, "link": ""}
TWIPS_PER = {"in": 1440.0, "cm": 1440.0 / 2.54, "mm": 1440.0 / 25.4, "pt": 20.0, "pc": 240.0}
# Paragraph content that carries no text of its own.
SILENT = {"bookmark", "bookmark-start", "bookmark-end", "reference-mark", "reference-mark-start",
          "reference-mark-end", "soft-page-break", "alphabetical-index-mark", "alphabetical-index-mark-start",
          "alphabetical-index-mark-end", "toc-mark", "toc-mark-start", "toc-mark-end", "user-index-mark",
          "user-index-mark-start", "user-index-mark-end", "sequence-ref"}
# LibreOffice exports a paragraph-attribute change, which has no ODF element, as `text:UnknownChange`.
CHANGE_KINDS = {"insertion": "insertion", "deletion": "deletion", "format-change": "format", "UnknownChange": "format"}
# Fields whose element holds the result the document displays.
FIELDS = {"page-number", "page-count", "creation-date", "date", "time"}
SKIPPED_BODY = {"sequence-decls", "variable-decls", "user-field-decls", "dde-connection-decls",
                "tracked-changes", "forms", "soft-page-break"}


class Unsupported(Exception):
    pass


def q(name):
    prefix, local = name.split(":")
    return f"{{{NS[prefix]}}}{local}"


def local(tag):
    return tag.rsplit("}", 1)[-1]


def namespace(tag):
    return tag[1:].split("}", 1)[0] if tag.startswith("{") else ""


def soffice_binary():
    candidates = [os.environ.get("SOFFICE"), shutil.which("soffice"), shutil.which("libreoffice"),
                  "/Applications/LibreOffice.app/Contents/MacOS/soffice"]
    for candidate in candidates:
        if candidate and pathlib.Path(candidate).exists():
            return candidate
    sys.exit("LibreOffice not found: set SOFFICE or put soffice on PATH")


def version(soffice):
    return subprocess.run([soffice, "--version"], capture_output=True, text=True, check=True).stdout.strip()


def twips(length):
    match = re.fullmatch(r"(-?[0-9.]+)(in|cm|mm|pt|pc)", length or "")
    if not match:
        raise Unsupported(f"length {length!r}")
    return round(float(match.group(1)) * TWIPS_PER[match.group(2)])


def instant(value):
    """A date as LibreOffice writes it, as a UTC instant to the second."""
    if not value:
        return ""
    match = re.fullmatch(r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?(Z)?", value)
    if not match:
        raise Unsupported(f"date {value!r}")
    return match.group(1) + "Z"


def text_formatting(properties):
    if properties is None:
        return {}
    get = lambda name: properties.get(q(name), "")
    position = get("style:text-position").split()
    formatting = {}
    if get("fo:font-weight"):
        weight = get("fo:font-weight")
        formatting["bold"] = weight == "bold" or (weight.isdigit() and int(weight) >= 600)
    if get("fo:font-style"):
        formatting["italic"] = get("fo:font-style") in ("italic", "oblique")
    if get("style:text-underline-style"):
        formatting["underline"] = get("style:text-underline-style") != "none"
    if get("style:text-line-through-style"):
        formatting["strike"] = get("style:text-line-through-style") != "none"
    if position:
        raised = position[0]
        offset = 33.0 if raised == "super" else -33.0 if raised == "sub" else float(raised.rstrip("%"))
        formatting["superscript"] = offset > 0
        formatting["subscript"] = offset < 0
    return formatting


class Document:
    def __init__(self, root):
        self.root = root
        automatic = root.find(q("office:automatic-styles"))
        styles = root.find(q("office:styles"))
        self.text_styles = {}
        self.paragraph_styles = {}
        self.list_styles = {}
        self.page_layouts = {}
        for container, automatic_container in ((styles, False), (automatic, True)):
            if container is None:
                continue
            for element in container:
                name = element.get(q("style:name"))
                if element.tag == q("style:style") and element.get(q("style:family")) == "text" and automatic_container:
                    self.text_styles[name] = text_formatting(element.find(q("style:text-properties")))
                elif element.tag == q("style:style") and element.get(q("style:family")) == "paragraph":
                    self.paragraph_styles[name] = element
                elif element.tag == q("text:list-style"):
                    self.list_styles[name] = element
                elif element.tag == q("style:page-layout"):
                    self.page_layouts[name] = element
        self.master_pages = {m.get(q("style:name")): m for m in root.iter(q("style:master-page"))}
        self.changes = {}
        for region in root.iter(q("text:changed-region")):
            change = next(child for child in region if child.tag != q("office:change-info"))
            info = change.find(q("office:change-info"))
            self.changes[region.get(q("text:id"))] = {
                "kind": CHANGE_KINDS[local(change.tag)],
                "author": (info.findtext(q("dc:creator")) or "").strip(),
                "date": instant((info.findtext(q("dc:date")) or "").strip()),
                "deleted": change if change.tag == q("text:deletion") else None,
            }
        self.blocks = []
        self.notes = []
        self.comments = []
        self.revisions = []
        self.revision_index = {}
        self.open_comments = {}
        self.open_revisions = []
        self.runs = None
        self.after_space = True
        self.anchored = False
        self.sections = []
        self.position = 0
        self.comment_positions = []

    # Text reaches the current paragraph, every open comment anchor and every open revision.
    def emit(self, text, formatting):
        if not text:
            return
        self.position += len(text)
        for index in self.open_comments.values():
            self.comments[index]["anchor"] += text
        for index in self.open_revisions:
            self.revisions[index]["text"] += text
        self.runs.append(dict(formatting, text=text))

    def revision(self, change_id):
        if change_id not in self.revision_index:
            change = self.changes[change_id]
            self.revision_index[change_id] = len(self.revisions)
            text = ""
            if change["deleted"] is not None:
                text = "\n".join(self.detached_paragraphs(change["deleted"]))
            self.revisions.append({"kind": change["kind"], "author": change["author"], "date": change["date"], "text": text})
        return self.revision_index[change_id]

    def paragraph(self, element, kind, level, list_kind):
        outer = (self.runs, self.anchored, self.after_space)
        self.runs, self.anchored, self.after_space = [], False, True
        self.inlines(element, dict(PLAIN))
        runs, anchored = self.runs, self.anchored
        self.runs, self.anchored, self.after_space = outer
        text = "".join(run["text"] for run in runs)
        self.position += 1
        for index in self.open_comments.values():
            self.comments[index]["anchor"] += "\n"
        for index in self.open_revisions:
            self.revisions[index]["text"] += "\n"
        if text or anchored:
            self.blocks.append({"kind": kind, "level": level, "list": list_kind, "text": text, "runs": runs, "rows": []})

    def inlines(self, element, formatting):
        self.characters(element.text, formatting)
        for child in element:
            self.inline(child, formatting)
            self.characters(child.tail, formatting)

    def characters(self, value, formatting):
        """Character data under ODF's white-space rule: runs collapse to one space, none at the paragraph start."""
        collapsed = re.sub(r"[ \t\r\n]+", " ", value or "")
        if self.after_space and collapsed.startswith(" "):
            collapsed = collapsed[1:]
        if collapsed:
            self.emit(collapsed, formatting)
            self.after_space = collapsed.endswith(" ")

    def inline(self, child, formatting):
        name = local(child.tag)
        ns = namespace(child.tag)
        if ns == NS["text"] and name == "s":
            self.emit_exact(" " * int(child.get(q("text:c"), "1")), formatting)
        elif ns == NS["text"] and name == "tab":
            self.emit_exact("\t", formatting)
        elif ns == NS["text"] and name == "line-break":
            self.emit_exact("\n", formatting)
        elif ns == NS["text"] and name == "span":
            style = self.text_styles.get(child.get(q("text:style-name")), {})
            self.inlines(child, dict(formatting, **style))
        elif ns == NS["text"] and name == "a":
            self.inlines(child, dict(formatting, link=child.get(q("xlink:href"), "")))
        elif ns == NS["text"] and name == "note":
            self.anchored = True
            body = child.find(q("text:note-body"))
            self.notes.append({"kind": child.get(q("text:note-class"), "footnote"),
                               "text": "\n".join(self.detached_paragraphs(body))})
        elif ns == NS["office"] and name == "annotation":
            self.anchored = True
            index = len(self.comments)
            self.comment_positions.append(self.position)
            self.comments.append({
                "author": (child.findtext(q("dc:creator")) or "").strip(),
                "date": instant((child.findtext(q("dc:date")) or "").strip()),
                "text": "", "anchor": "", "thread": index,
                "resolved": child.get(q("loext:resolved")) == "true",
            })
            self.comments[index]["text"] = "\n".join(self.detached_paragraphs(child))
            if child.get(q("office:name")):
                self.open_comments[child.get(q("office:name"))] = index
        elif ns == NS["office"] and name == "annotation-end":
            self.anchored = True
            self.open_comments.pop(child.get(q("office:name")), None)
        elif ns == NS["text"] and name == "change":
            self.anchored = True
            self.revision(child.get(q("text:change-id")))
        elif ns == NS["text"] and name == "change-start":
            self.anchored = True
            self.open_revisions.append(self.revision(child.get(q("text:change-id"))))
        elif ns == NS["text"] and name == "change-end":
            self.anchored = True
            index = self.revision(child.get(q("text:change-id")))
            if index in self.open_revisions:
                self.open_revisions.remove(index)
        elif ns == NS["text"] and name in FIELDS:
            self.inlines(child, formatting)
        elif ns == NS["text"] and name in SILENT:
            pass
        elif ns == NS["draw"]:
            if any("".join(paragraph.itertext()).strip() for paragraph in child.iter(q("text:p"))):
                raise Unsupported(f"text inside {child.tag}")
        else:
            raise Unsupported(f"inline {child.tag}")

    def emit_exact(self, text, formatting):
        self.emit(text, formatting)
        self.after_space = False

    def detached_paragraphs(self, container):
        """The texts of the paragraphs inside a note, comment or deletion, in order."""
        saved = (self.blocks, self.open_comments, self.open_revisions, self.position)
        self.blocks, self.open_comments, self.open_revisions = [], {}, []
        self.body(container, list_kind="", depth=0, list_style=None)
        blocks = self.blocks
        self.blocks, self.open_comments, self.open_revisions, self.position = saved
        if any(block["kind"] == "table" for block in blocks):
            raise Unsupported(f"table inside {container.tag}")
        return [block["text"] for block in blocks]

    def body(self, container, list_kind, depth, list_style):
        for child in container:
            self.block(child, list_kind, depth, list_style)

    def block(self, element, list_kind, depth, list_style):
        name = local(element.tag)
        ns = namespace(element.tag)
        kind = "list_item" if depth else "paragraph"
        if ns == NS["text"] and name == "p":
            self.page_style(element)
            self.paragraph(element, kind, depth, list_kind)
        elif ns == NS["text"] and name == "h":
            self.page_style(element)
            self.paragraph(element, "heading", int(element.get(q("text:outline-level"), "1")), "")
        elif ns == NS["text"] and name == "list":
            style = element.get(q("text:style-name")) or list_style
            level = depth + 1
            for item in element:
                if item.tag not in (q("text:list-item"), q("text:list-header")):
                    raise Unsupported(f"list content {item.tag}")
                self.body(item, self.list_kind(style, level), level, style)
        elif ns == NS["text"] and name == "section":
            self.body(element, list_kind, depth, list_style)
        elif ns == NS["table"] and name == "table":
            self.table(element)
        elif ns == NS["text"] and name in SKIPPED_BODY:
            pass
        elif ns in (NS["office"], NS["dc"], NS["meta"]) and name in ("change-info", "creator", "creator-initials", "date",
                                                                      "date-string"):
            pass
        else:
            raise Unsupported(f"block {element.tag}")

    def list_kind(self, style_name, level):
        style = self.list_styles.get(style_name)
        if style is None:
            raise Unsupported(f"list style {style_name!r}")
        for level_style in style:
            if level_style.get(q("text:level")) == str(level):
                return {"list-level-style-bullet": "bullet", "list-level-style-number": "number",
                        "list-level-style-image": "bullet"}[local(level_style.tag)]
        raise Unsupported(f"list style {style_name!r} has no level {level}")

    def table(self, element):
        grid = []
        for row in self.rows(element):
            cells = []
            for cell in row:
                if cell.tag not in (q("table:table-cell"), q("table:covered-table-cell")):
                    raise Unsupported(f"row content {cell.tag}")
                saved = self.blocks
                self.blocks = []
                self.body(cell, "", 0, None)
                text = "\n".join(block["text"] for block in self.blocks)
                self.blocks = saved
                cells += [text] * int(cell.get(q("table:number-columns-repeated"), "1"))
            grid.append(cells)
        self.blocks.append({"kind": "table", "level": 0, "list": "", "text": "", "runs": [], "rows": grid})

    def rows(self, element):
        for child in element:
            if child.tag == q("table:table-row"):
                yield child
            elif child.tag in (q("table:table-header-rows"), q("table:table-rows"), q("table:table-row-group")):
                yield from self.rows(child)
            elif child.tag not in (q("table:table-column"), q("table:table-columns"), q("table:table-header-columns"),
                                   q("table:table-column-group")):
                raise Unsupported(f"table content {child.tag}")

    def page_style(self, element):
        """Start a section when a top-level paragraph's style names a page style."""
        if self.blocks is not self.top_blocks:
            return
        style = self.paragraph_styles.get(element.get(q("text:style-name")))
        master = style.get(q("style:master-page-name")) if style is not None else None
        if master or not self.sections:
            self.sections.append(self.section(master or "Standard"))

    def section(self, master_name):
        master = self.master_pages.get(master_name)
        if master is None:
            raise Unsupported(f"page style {master_name!r}")
        properties = self.page_layouts[master.get(q("style:page-layout-name"))].find(q("style:page-layout-properties"))
        get = lambda name: properties.get(q(name))
        width, height = twips(get("fo:page-width")), twips(get("fo:page-height"))
        return {
            "page_width": width, "page_height": height,
            "orientation": get("style:print-orientation") or ("landscape" if width > height else "portrait"),
            "margin_top": twips(get("fo:margin-top")), "margin_bottom": twips(get("fo:margin-bottom")),
            "margin_left": twips(get("fo:margin-left")), "margin_right": twips(get("fo:margin-right")),
            "header": self.region_text(master.find(q("style:header"))),
            "footer": self.region_text(master.find(q("style:footer"))),
        }

    def region_text(self, region):
        return "" if region is None else "\n".join(self.detached_paragraphs(region))

    def properties(self):
        meta = self.root.find(q("office:meta"))
        value = lambda name: ((meta.findtext(q(name)) if meta is not None else "") or "").strip()
        keywords = [k.text.strip() for k in meta.iter(q("meta:keyword")) if k.text] if meta is not None else []
        return {
            "title": value("dc:title"), "subject": value("dc:subject"), "creator": value("meta:initial-creator"),
            "keywords": ", ".join(keywords), "description": value("dc:description"),
            "last_modified_by": value("dc:creator"), "created": instant(value("meta:creation-date")),
            "modified": instant(value("dc:date")),
        }

    def reduce(self):
        text = self.root.find(q("office:body")).find(q("office:text"))
        self.top_blocks = self.blocks
        self.body(text, "", 0, None)
        if not self.sections:
            self.sections.append(self.section("Standard"))
        self.restore_comment_order()
        return self

    def restore_comment_order(self):
        """LibreOffice writes comments that start at one position in reverse document order; reverse each such run."""
        order, start = [], 0
        for end in range(1, len(self.comments) + 1):
            if end == len(self.comments) or self.comment_positions[end] != self.comment_positions[start]:
                order += reversed(range(start, end))
                start = end
        new_index = {old: new for new, old in enumerate(order)}
        self.comments = [dict(self.comments[old], thread=new_index[self.comments[old]["thread"]]) for old in order]


def snapshot(document, fodt, soffice_version):
    reduced = Document(ET.parse(fodt).getroot()).reduce()
    return {
        "schema": SCHEMA,
        "producer": {"name": "libreoffice", "version": soffice_version},
        "document": label(document),
        "keys": KEYS,
        "blocks": [dict(block, runs=coalesce(block["runs"])) for block in reduced.blocks],
        "notes": reduced.notes,
        "comments": reduced.comments,
        "revisions": reduced.revisions,
        "sections": reduced.sections,
        "properties": reduced.properties(),
    }


def coalesce(runs):
    merged = []
    for run in runs:
        if merged and all(merged[-1][key] == run[key] for key in PLAIN):
            merged[-1] = dict(merged[-1], text=merged[-1]["text"] + run["text"])
        else:
            merged.append(run)
    return merged


def label(document):
    resolved = document.resolve()
    return resolved.relative_to(ROOT).as_posix() if resolved.is_relative_to(ROOT) else str(document)


def documents(paths):
    for raw in paths:
        path = pathlib.Path(raw)
        yield from (sorted(path.rglob("*.docx")) if path.is_dir() else [path])


def convert(soffice, documents, work):
    """Convert every document to Flat ODT in one LibreOffice run; names are indexed so equal basenames do not collide."""
    inputs = work / "in"
    outputs = work / "out"
    inputs.mkdir()
    staged = []
    for index, document in enumerate(documents):
        target = inputs / f"{index}.docx"
        shutil.copyfile(document, target)
        staged.append(str(target))
    subprocess.run([soffice, f"-env:UserInstallation={(work / 'profile').as_uri()}", "--headless", "--norestore",
                    "--convert-to", "fodt", "--outdir", str(outputs), *staged],
                   check=True, capture_output=True)
    return [outputs / f"{index}.fodt" for index in range(len(documents))]


def main(argv):
    out = None
    if "--out" in argv:
        out = pathlib.Path(argv[argv.index("--out") + 1])
        argv = argv[:argv.index("--out")] + argv[argv.index("--out") + 2:]
    if not argv or (out is None and len(argv) != 1):
        sys.exit(__doc__)
    soffice = soffice_binary()
    soffice_version = version(soffice)
    inputs = list(documents(argv))
    failed = 0
    with tempfile.TemporaryDirectory() as tmp:
        for document, fodt in zip(inputs, convert(soffice, inputs, pathlib.Path(tmp))):
            if not fodt.exists():
                print(f"FAIL {label(document)}: LibreOffice did not convert it", file=sys.stderr)
                failed += 1
                continue
            try:
                result = snapshot(document, fodt, soffice_version)
            except (Unsupported, ET.ParseError, KeyError) as error:
                print(f"FAIL {label(document)}: {error!r}", file=sys.stderr)
                failed += 1
                continue
            text = json.dumps(result, indent=1, ensure_ascii=False) + "\n"
            if out is None:
                sys.stdout.write(text)
            else:
                target = out / (result["document"] + ".json")
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(text)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
