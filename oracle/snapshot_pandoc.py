"""Reduce pandoc's reading of a .docx to a roc-docx-snapshot/1 document.

    snapshot_pandoc.py DOCX                 print the snapshot of one document
    snapshot_pandoc.py PATH... --out DIR    write DIR/<document>.json for every .docx under PATH

pandoc reads the document with `-t json --track-changes=all`; this adapter
walks that JSON and nothing else, so it shares no logic with the package or
with the LibreOffice adapter. oracle/snapshot_schema.json defines the contract
and lists the keys this adapter is authoritative for.

Rules this adapter applies, each because of how pandoc represents a document:

- pandoc lifts paragraphs styled Title, Subtitle, Author, Date and Abstract
  into metadata. They are restored as leading paragraphs in that order, which
  is where they stand in every document whose metadata pandoc reads this way.
- pandoc gives a vertically merged cell a row span and leaves the cells it
  covers out of the rows below; in the text grid each covered column is an
  empty cell, as a column a cell spans is.
- A horizontal rule is the paragraph that holds it; with no text it is an
  empty paragraph and so not a block.
- pandoc does not say whether a note is a footnote or an endnote, whether a
  comment is resolved or a reply, or anything about sections, headers,
  footers or core properties, so it declares none of those keys.
- Inline code is text and an image contributes none; pandoc's other
  formatting maps onto the run keys.
- A construct this adapter does not know fails the run instead of being
  dropped silently.

pandoc is found through PANDOC or PATH.
"""

import json
import os
import pathlib
import shutil
import subprocess
import sys

SCHEMA = "roc-docx-snapshot/1"
ROOT = pathlib.Path(__file__).resolve().parent.parent

KEYS = [
    "blocks.kind", "blocks.level", "blocks.list", "blocks.text", "blocks.rows",
    "blocks.runs.bold", "blocks.runs.italic", "blocks.runs.underline", "blocks.runs.strike",
    "blocks.runs.superscript", "blocks.runs.subscript", "blocks.runs.link",
    "notes.text",
    "comments.author", "comments.date", "comments.text", "comments.anchor",
    "revisions.kind", "revisions.author", "revisions.date", "revisions.text",
]

METADATA_PARAGRAPHS = ["title", "subtitle", "author", "date", "abstract"]
FORMATS = {"Strong": "bold", "Emph": "italic", "Underline": "underline", "Strikeout": "strike",
           "Superscript": "superscript", "Subscript": "subscript"}
PLAIN = {"bold": False, "italic": False, "underline": False, "strike": False,
         "superscript": False, "subscript": False, "link": ""}


class Unsupported(Exception):
    pass


def pandoc_binary():
    return os.environ.get("PANDOC") or shutil.which("pandoc") or sys.exit("pandoc not found: set PANDOC or run through blueprint")


def version(pandoc):
    return subprocess.run([pandoc, "--version"], capture_output=True, text=True, check=True).stdout.split("\n")[0].split()[-1]


def attributes(attr):
    _identifier, classes, pairs = attr
    return classes, dict(pairs)


class Reducer:
    """Walks pandoc's blocks in reading order, keeping the open comments and the current paragraph."""

    def __init__(self):
        self.blocks = []
        self.notes = []
        self.comments = []
        self.revisions = []
        self.open_comments = {}
        self.runs = None
        self.anchored = False
        self.revision_stack = []

    # Text reaches the current paragraph, every open comment anchor and every open revision.
    def emit(self, text, formatting):
        if not text:
            return
        deleted = any(kind == "deletion" for kind, _ in self.revision_stack)
        for _kind, index in self.revision_stack:
            self.revisions[index]["text"] += text
        if deleted:
            return
        for index in self.open_comments.values():
            self.comments[index]["anchor"] += text
        self.runs.append(dict(formatting, text=text))

    def paragraph(self, inlines, kind="paragraph", level=0, list_kind=""):
        outer = (self.runs, self.anchored)
        self.runs, self.anchored = [], False
        self.inlines(inlines, dict(PLAIN))
        runs, anchored = self.runs, self.anchored
        self.runs, self.anchored = outer
        text = "".join(run["text"] for run in runs)
        for index in self.open_comments.values():
            self.comments[index]["anchor"] += "\n"
        if text or anchored:
            self.blocks.append({"kind": kind, "level": level, "list": list_kind, "text": text, "runs": runs, "rows": []})

    def inlines(self, inlines, formatting):
        for inline in inlines:
            self.inline(inline, formatting)

    def inline(self, inline, formatting):
        tag, content = inline["t"], inline.get("c")
        if tag == "Str":
            self.emit(content, formatting)
        elif tag in ("Space", "SoftBreak"):
            self.emit(" ", formatting)
        elif tag == "LineBreak":
            self.emit("\n", formatting)
        elif tag in FORMATS:
            self.inlines(content, dict(formatting, **{FORMATS[tag]: True}))
        elif tag == "Code":
            self.emit(content[1], formatting)
        elif tag == "Link":
            self.inlines(content[1], dict(formatting, link=content[2][0]))
        elif tag == "Image":
            pass
        elif tag == "Note":
            self.anchored = True
            self.notes.append({"kind": "footnote", "text": self.detached_text(content)})
        elif tag == "Span":
            self.span(content, formatting)
        else:
            raise Unsupported(f"inline {tag}")

    def span(self, content, formatting):
        attr, inlines = content
        classes, pairs = attributes(attr)
        if "comment-start" in classes:
            self.anchored = True
            self.open_comments[pairs["id"]] = len(self.comments)
            self.comments.append({"author": pairs.get("author", ""), "date": pairs.get("date", ""),
                                  "text": self.detached_text([{"t": "Plain", "c": inlines}]), "anchor": "",
                                  "thread": len(self.comments), "resolved": False})
        elif "comment-end" in classes:
            self.anchored = True
            self.open_comments.pop(pairs["id"], None)
        elif "insertion" in classes or "deletion" in classes:
            self.anchored = True
            kind = "insertion" if "insertion" in classes else "deletion"
            self.revision_stack.append((kind, len(self.revisions)))
            self.revisions.append({"kind": kind, "author": pairs.get("author", ""), "date": pairs.get("date", ""), "text": ""})
            self.inlines(inlines, formatting)
            self.revision_stack.pop()
        else:
            self.inlines(inlines, formatting)

    def detached_text(self, blocks):
        """The text of note or comment content: its paragraphs joined by line feeds."""
        inner = Reducer()
        inner.comments, inner.revisions = self.comments, self.revisions
        inner.block_list(blocks)
        if any(block["kind"] == "table" for block in inner.blocks):
            raise Unsupported("table inside a note or comment")
        self.notes.extend(inner.notes)
        return "\n".join(block["text"] for block in inner.blocks)

    def block_list(self, blocks, list_kind="", depth=0):
        for block in blocks:
            self.block(block, list_kind, depth)

    def block(self, block, list_kind, depth):
        tag, content = block["t"], block.get("c")
        kind = "list_item" if depth else "paragraph"
        if tag in ("Para", "Plain"):
            self.paragraph(content, kind, depth, list_kind)
        elif tag == "LineBlock":
            self.paragraph([part for line in content for part in line + [{"t": "LineBreak"}]][:-1], kind, depth, list_kind)
        elif tag == "Header":
            self.paragraph(content[2], "heading", content[0])
        elif tag == "BulletList":
            for item in content:
                self.block_list(item, "bullet", depth + 1)
        elif tag == "OrderedList":
            for item in content[1]:
                self.block_list(item, "number", depth + 1)
        elif tag in ("BlockQuote", "Div"):
            self.block_list(content if tag == "BlockQuote" else content[1], list_kind, depth)
        elif tag == "HorizontalRule":
            self.paragraph([], kind, depth, list_kind)
        elif tag == "Table":
            self.table(content)
        else:
            raise Unsupported(f"block {tag}")

    def table(self, content):
        _attr, _caption, _colspecs, head, bodies, foot = content
        rows = list(head[1])
        for body in bodies:
            rows += body[2] + body[3]
        rows += foot[1]
        grid = []
        covered = {}  # column -> (rows still covered, columns covered) by a cell spanning rows above
        for row in rows:
            cells = []

            def cover():
                while len(cells) in covered:
                    column = len(cells)
                    remaining, width = covered.pop(column)
                    cells.extend([""] * width)
                    if remaining > 1:
                        covered[column] = (remaining - 1, width)

            for cell in row[1]:
                _cell_attr, _align, rowspan, colspan, cell_blocks = cell
                cover()
                if rowspan > 1:
                    covered[len(cells)] = (rowspan - 1, colspan)
                cells.append(self.cell_text(cell_blocks))
                cells += [""] * (colspan - 1)
            cover()
            grid.append(cells)
        self.blocks.append({"kind": "table", "level": 0, "list": "", "text": "", "runs": [], "rows": grid})

    def cell_text(self, cell_blocks):
        start = len(self.blocks)
        self.block_list(cell_blocks)
        text = "\n".join(block["text"] for block in self.blocks[start:])
        del self.blocks[start:]
        return text


def metadata_blocks(meta):
    blocks = []
    for name in METADATA_PARAGRAPHS:
        value = meta.get(name)
        if value is None:
            continue
        values = value["c"] if value["t"] == "MetaList" else [value]
        for item in values:
            if item["t"] == "MetaInlines":
                blocks.append({"t": "Para", "c": item["c"]})
            elif item["t"] == "MetaBlocks":
                blocks.extend(item["c"])
            elif item["t"] == "MetaString":
                blocks.append({"t": "Para", "c": [{"t": "Str", "c": item["c"]}]})
            else:
                raise Unsupported(f"metadata {name} of type {item['t']}")
    return blocks


def snapshot(document, pandoc, pandoc_version):
    run = subprocess.run([pandoc, "-f", "docx", "-t", "json", "--track-changes=all", str(document)],
                         capture_output=True, text=True, check=True)
    tree = json.loads(run.stdout)
    reducer = Reducer()
    reducer.block_list(metadata_blocks(tree.get("meta", {})) + tree["blocks"])
    return {
        "schema": SCHEMA,
        "producer": {"name": "pandoc", "version": pandoc_version},
        "document": label(document),
        "keys": KEYS,
        "blocks": [dict(block, runs=coalesce(block["runs"])) for block in reducer.blocks],
        "notes": reducer.notes,
        "comments": reducer.comments,
        "revisions": reducer.revisions,
        "sections": [],
        "properties": {"title": "", "subject": "", "creator": "", "keywords": "", "description": "",
                       "last_modified_by": "", "created": "", "modified": ""},
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


def main(argv):
    out = None
    if "--out" in argv:
        out = pathlib.Path(argv[argv.index("--out") + 1])
        argv = argv[:argv.index("--out")] + argv[argv.index("--out") + 2:]
    if not argv or (out is None and len(argv) != 1):
        sys.exit(__doc__)
    pandoc = pandoc_binary()
    pandoc_version = version(pandoc)
    failed = 0
    for document in documents(argv):
        try:
            result = snapshot(document, pandoc, pandoc_version)
        except (Unsupported, subprocess.CalledProcessError) as error:
            print(f"FAIL {label(document)}: {error}", file=sys.stderr)
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
