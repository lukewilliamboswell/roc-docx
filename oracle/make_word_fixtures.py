"""Produce the Word fixtures under tests/fixtures/word/ with Microsoft Word.

    make_word_fixtures.py            write a seed package for each fixture, open and save it in Word,
                                     and copy Word's output into tests/fixtures/word/

macOS only, with Microsoft Word installed; a maintainer task that neither
`check` nor CI runs. Word's scripting dictionary cannot reply to or resolve a
comment, move text or record structural revisions, so every construct is
authored here, in a seed package with fictional authors and fixed dates, and
Word contributes its serialization: the seed is opened and saved as a Word
document, and the saved file is the fixture. Word output is not reproducible
(it stamps revision-save identifiers, paragraph identifiers and the save
time), so the fixtures are committed bytes with the Word version recorded in
tests/fixtures/provenance.json.

Word records the signed-in account's name as the document's last editor,
whatever its own user name setting says, so that one value in
docProps/core.xml is replaced by the seed's fictional editor; every other
entry of the archive is copied with its stored bytes unchanged. Each output
is then checked: every construct the seed authored must still be there (one
Word drops is reported, not silently lost), and no XML part may contain
Word's user name, the account's login or full name, the home directory or an
`@`. A fixture that fails a check is not written.

Word is sandboxed, so the seeds and outputs pass through a directory inside
its container. Only documents this script opened are closed, and Word's
settings are not changed.
"""

import os
import pathlib
import pwd
import re
import shutil
import struct
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile
import zlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "tests" / "fixtures" / "word"
WORK = pathlib.Path.home() / "Library" / "Containers" / "com.microsoft.Word" / "Data" / "roc-docx-fixtures"
EDITOR = "Grace Author"
TIMEOUT = 120

NAMESPACES = {
    "w": "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
    "r": "http://schemas.openxmlformats.org/officeDocument/2006/relationships",
    "mc": "http://schemas.openxmlformats.org/markup-compatibility/2006",
    "w14": "http://schemas.microsoft.com/office/word/2010/wordml",
    "w15": "http://schemas.microsoft.com/office/word/2012/wordml",
    "w16cid": "http://schemas.microsoft.com/office/word/2016/wordml/cid",
    "w16cex": "http://schemas.microsoft.com/office/word/2018/wordml/cex",
    "wp": "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
    "a": "http://schemas.openxmlformats.org/drawingml/2006/main",
    "pic": "http://schemas.openxmlformats.org/drawingml/2006/picture",
}
DECLARATIONS = " ".join(f'xmlns:{prefix}="{uri}"' for prefix, uri in NAMESPACES.items())
IGNORABLE = 'mc:Ignorable="w14 w15 w16cid w16cex"'

REL = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
MS_REL = {
    "commentsExtended": "http://schemas.microsoft.com/office/2011/relationships/commentsExtended",
    "commentsIds": "http://schemas.microsoft.com/office/2016/09/relationships/commentsIds",
    "commentsExtensible": "http://schemas.microsoft.com/office/2018/08/relationships/commentsExtensible",
    "people": "http://schemas.microsoft.com/office/2011/relationships/people",
}
WML_TYPE = "application/vnd.openxmlformats-officedocument.wordprocessingml.{}+xml"

# Part name in word/ -> (relationship type, content type).
PART_KINDS = {
    "styles.xml": (f"{REL}/styles", WML_TYPE.format("styles")),
    "settings.xml": (f"{REL}/settings", WML_TYPE.format("settings")),
    "numbering.xml": (f"{REL}/numbering", WML_TYPE.format("numbering")),
    "comments.xml": (f"{REL}/comments", WML_TYPE.format("comments")),
    "commentsExtended.xml": (MS_REL["commentsExtended"], WML_TYPE.format("commentsExtended")),
    "commentsIds.xml": (MS_REL["commentsIds"], WML_TYPE.format("commentsIds")),
    "commentsExtensible.xml": (MS_REL["commentsExtensible"], WML_TYPE.format("commentsExtensible")),
    "people.xml": (MS_REL["people"], WML_TYPE.format("people")),
    "footnotes.xml": (f"{REL}/footnotes", WML_TYPE.format("footnotes")),
    "endnotes.xml": (f"{REL}/endnotes", WML_TYPE.format("endnotes")),
    "header1.xml": (f"{REL}/header", WML_TYPE.format("header")),
    "footer1.xml": (f"{REL}/footer", WML_TYPE.format("footer")),
}


# ---------------------------------------------------------------- seed markup

def esc(text):
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


def t(text):
    return f'<w:t xml:space="preserve">{esc(text)}</w:t>'


def run(text, props=""):
    return f"<w:r>{f'<w:rPr>{props}</w:rPr>' if props else ''}{t(text)}</w:r>"


def para(content, props=""):
    return f"<w:p>{f'<w:pPr>{props}</w:pPr>' if props else ''}{content}</w:p>"


def heading(text, level=1):
    return para(run(text), f'<w:pStyle w:val="Heading{level}"/>')


def mark(author, date, ident):
    return f'w:id="{ident}" w:author="{author}" w:date="{date}"'


def xml(root, body):
    return f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<{root} {DECLARATIONS} {IGNORABLE}>{body}</{root.split()[0]}>'


def document(body, section):
    return xml("w:document", f"<w:body>{body}{section}</w:body>")


def section(references="", landscape=False, change=""):
    size = '<w:pgSz w:w="16838" w:h="11906" w:orient="landscape"/>' if landscape else '<w:pgSz w:w="11906" w:h="16838"/>'
    margins = '<w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="708" w:footer="708" w:gutter="0"/>'
    return f"<w:sectPr>{references}{size}{margins}{change}</w:sectPr>"


STYLES = xml("w:styles", "".join([
    '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>',
    *(f'<w:style w:type="paragraph" w:styleId="Heading{n}"><w:name w:val="heading {n}"/><w:basedOn w:val="Normal"/>'
      f'<w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:outlineLvl w:val="{n - 1}"/></w:pPr>'
      f'<w:rPr><w:b/><w:sz w:val="{36 - 4 * n}"/></w:rPr></w:style>' for n in (1, 2)),
    '<w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/>'
    '<w:qFormat/><w:pPr><w:ind w:left="720"/></w:pPr></w:style>',
    '<w:style w:type="paragraph" w:styleId="FootnoteText"><w:name w:val="footnote text"/><w:basedOn w:val="Normal"/>'
    '<w:rPr><w:sz w:val="20"/></w:rPr></w:style>',
    '<w:style w:type="paragraph" w:styleId="EndnoteText"><w:name w:val="endnote text"/><w:basedOn w:val="Normal"/>'
    '<w:rPr><w:sz w:val="20"/></w:rPr></w:style>',
    '<w:style w:type="paragraph" w:styleId="Header"><w:name w:val="header"/><w:basedOn w:val="Normal"/></w:style>',
    '<w:style w:type="paragraph" w:styleId="Footer"><w:name w:val="footer"/><w:basedOn w:val="Normal"/></w:style>',
    '<w:style w:type="paragraph" w:styleId="CommentText"><w:name w:val="annotation text"/><w:basedOn w:val="Normal"/></w:style>',
    '<w:style w:type="character" w:styleId="FootnoteReference"><w:name w:val="footnote reference"/>'
    '<w:rPr><w:vertAlign w:val="superscript"/></w:rPr></w:style>',
    '<w:style w:type="character" w:styleId="EndnoteReference"><w:name w:val="endnote reference"/>'
    '<w:rPr><w:vertAlign w:val="superscript"/></w:rPr></w:style>',
    '<w:style w:type="character" w:styleId="CommentReference"><w:name w:val="annotation reference"/></w:style>',
    '<w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/>'
    '<w:rPr><w:color w:val="0563C1"/><w:u w:val="single"/></w:rPr></w:style>',
    '<w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/><w:tblPr><w:tblBorders>'
    + "".join(f'<w:{side} w:val="single" w:sz="4" w:space="0" w:color="auto"/>'
              for side in ("top", "left", "bottom", "right", "insideH", "insideV"))
    + "</w:tblBorders></w:tblPr></w:style>",
]))


def settings(tracking="", notes=""):
    return xml("w:settings", f'{tracking}<w:defaultTabStop w:val="720"/>{notes}<w:compat>'
                             '<w:compatSetting w:name="compatibilityMode" w:uri="http://schemas.microsoft.com/office/word" w:val="15"/>'
                             "</w:compat>")


def core(title):
    return ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
            '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
            'xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" '
            'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">'
            f"<dc:title>{esc(title)}</dc:title><dc:creator>Ada Reviewer</dc:creator>"
            f"<cp:lastModifiedBy>{EDITOR}</cp:lastModifiedBy>"
            '<dcterms:created xsi:type="dcterms:W3CDTF">2026-05-04T08:00:00Z</dcterms:created>'
            '<dcterms:modified xsi:type="dcterms:W3CDTF">2026-05-04T08:00:00Z</dcterms:modified>'
            "</cp:coreProperties>")


def rel_id(name):
    return "rId" + name.split(".")[0]


def package(title, main, parts, links=(), media=()):
    """A .docx as {name: bytes}: `main` as word/document.xml and each of `parts` under word/, related from it
    with the identifier `rel_id` gives. `links` are external hyperlinks as (id, url); `media` are
    (name, bytes) images under word/media/, related as rIdImage1."""
    rels, overrides = [], []
    for name in sorted(parts):
        rel_type, content_type = PART_KINDS[name]
        rels.append(f'<Relationship Id="{rel_id(name)}" Type="{rel_type}" Target="{name}"/>')
        overrides.append(f'<Override PartName="/word/{name}" ContentType="{content_type}"/>')
    for ident, url in links:
        rels.append(f'<Relationship Id="{ident}" Type="{REL}/hyperlink" Target="{esc(url)}" TargetMode="External"/>')
    for name, _ in media:
        rels.append(f'<Relationship Id="rIdImage1" Type="{REL}/image" Target="media/{name}"/>')
    files = {
        "[Content_Types].xml": (
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
            '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
            '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
            '<Default Extension="xml" ContentType="application/xml"/>'
            '<Default Extension="png" ContentType="image/png"/>'
            f'<Override PartName="/word/document.xml" ContentType="{WML_TYPE.format("document.main")}"/>'
            '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>'
            + "".join(overrides) + "</Types>"),
        "_rels/.rels": (
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            f'<Relationship Id="rId1" Type="{REL}/officeDocument" Target="word/document.xml"/>'
            '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" '
            'Target="docProps/core.xml"/></Relationships>'),
        "word/_rels/document.xml.rels": (
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            + "".join(rels) + "</Relationships>"),
        "docProps/core.xml": core(title),
        "word/document.xml": main,
    }
    files.update({f"word/{name}": text for name, text in parts.items()})
    encoded = {name: text.encode("utf-8") for name, text in files.items()}
    encoded.update({f"word/media/{name}": data for name, data in media})
    return encoded


# ------------------------------------------------------------------ comments

ADA, GRACE, LIN = "Ada Reviewer", "Grace Author", "Lin Editor"


def comment(ident, author, initials, date, para_id, *paragraphs):
    body = "".join(
        f'<w:p w14:paraId="{para_id if index == len(paragraphs) - 1 else f"{int(para_id, 16) + 0x100 + index:08X}"}" '
        f'w14:textId="77777777"><w:pPr><w:pStyle w:val="CommentText"/></w:pPr>'
        + (f'<w:r><w:rPr><w:rStyle w:val="CommentReference"/></w:rPr><w:annotationRef/></w:r>' if index == 0 else "")
        + run(text) + "</w:p>"
        for index, text in enumerate(paragraphs))
    return f'<w:comment w:id="{ident}" w:author="{author}" w:date="{date}" w:initials="{initials}">{body}</w:comment>'


def reference(ident):
    return f'<w:r><w:rPr><w:rStyle w:val="CommentReference"/></w:rPr><w:commentReference w:id="{ident}"/></w:r>'


def comments_fixture():
    # (id, author, initials, local date, UTC date, paraId, durableId, parent paraId, done, text)
    threads = [
        (0, ADA, "AR", "2026-05-04T09:15:00Z", "1A000001", "5A000001", None, False,
         ["Should this be best endeavours?"]),
        (1, GRACE, "GA", "2026-05-04T10:02:00Z", "1A000002", "5A000002", "1A000001", False,
         ["No: reasonable skill and care is the market standard."]),
        (2, ADA, "AR", "2026-05-04T10:30:00Z", "1A000003", "5A000003", "1A000001", False,
         ["Agreed; leaving it as drafted."]),
        (3, GRACE, "GA", "2026-05-05T08:45:00Z", "1A000004", "5A000004", None, True,
         ["Confirm the payment term with finance."]),
        (4, ADA, "AR", "2026-05-05T09:10:00Z", "1A000005", "5A000005", "1A000004", True,
         ["Finance confirmed thirty days."]),
        (5, LIN, "LE", "2026-05-06T14:20:00Z", "1A000006", "5A000006", None, False,
         ["Add a cap on indemnities here."]),
        (6, GRACE, "GA", "2026-05-06T15:00:00Z", "1A000007", "5A000007", None, False,
         ["These two paragraphs repeat each other.", "Merge them before signature."]),
    ]
    comments = "".join(comment(i, a, ini, d, p, *texts) for i, a, ini, d, p, _, _, _, texts in threads)
    extended = "".join(
        f'<w15:commentEx w15:paraId="{p}"' + (f' w15:paraIdParent="{parent}"' if parent else "")
        + f' w15:done="{1 if done else 0}"/>'
        for _, _, _, _, p, _, parent, done, _ in threads)
    ids = "".join(f'<w16cid:commentId w16cid:paraId="{p}" w16cid:durableId="{durable}"/>'
                  for _, _, _, _, p, durable, _, _, _ in threads)
    extensible = "".join(f'<w16cex:commentExtensible w16cex:durableId="{durable}" w16cex:dateUtc="{d}"/>'
                         for _, _, _, d, _, durable, _, _, _ in threads)
    people = "".join(f'<w15:person w15:author="{name}"><w15:presenceInfo w15:providerId="None" w15:userId="{name}"/></w15:person>'
                     for name in (ADA, GRACE, LIN))

    def start(*ids):
        return "".join(f'<w:commentRangeStart w:id="{i}"/>' for i in ids)

    def end(*ids):
        return "".join(f'<w:commentRangeEnd w:id="{i}"/>{reference(i)}' for i in ids)

    body = "".join([
        heading("Services Agreement"),
        para(run("The Provider shall perform the Services with ") + start(0, 1, 2) + run("reasonable skill and care")
             + end(0, 1, 2) + run(".")),
        heading("Fees", 2),
        para(run("The Customer shall pay the Fees within ") + start(3, 4) + run("thirty days") + end(3, 4)
             + run(" of receipt of a valid invoice.")),
        heading("Liability", 2),
        para(run("Neither party is liable for indirect or consequential loss.") + reference(5)),
        para(start(6) + run("Each party shall keep the other's information confidential.")),
        para(run("Neither party shall disclose the other's confidential information.") + end(6)),
    ])
    parts = {
        "styles.xml": STYLES,
        "settings.xml": settings(),
        "comments.xml": xml("w:comments", comments),
        "commentsExtended.xml": xml("w15:commentsEx", extended),
        "commentsIds.xml": xml("w16cid:commentsIds", ids),
        "commentsExtensible.xml": xml("w16cex:commentsExtensible", extensible),
        "people.xml": xml("w15:people", people),
    }
    expected = {
        "word/comments.xml": ["w:comment"],
        "word/commentsExtended.xml": ["w15:commentEx@w15:paraIdParent", "w15:commentEx@w15:done=1"],
        "word/commentsIds.xml": ["w16cid:commentId"],
        "word/commentsExtensible.xml": ["w16cex:commentExtensible"],
        "word/people.xml": ["w15:person"],
        "word/document.xml": ["w:commentRangeStart", "w:commentRangeEnd", "w:commentReference"],
    }
    return package("Draft Services Agreement", document(body, section()), parts), expected


# ----------------------------------------------------------------- revisions

def revisions_fixture():
    ids = iter(range(100, 200))
    d1, d2, d3 = "2026-05-07T09:00:00Z", "2026-05-07T11:30:00Z", "2026-05-08T16:45:00Z"

    def m(author, date):
        return mark(author, date, next(ids))

    def ins(author, date, content):
        return f"<w:ins {m(author, date)}>{content}</w:ins>"

    def deleted(author, date, text):
        return f'<w:del {m(author, date)}><w:r><w:delText xml:space="preserve">{esc(text)}</w:delText></w:r></w:del>'

    def moved(kind, author, date, name, text):
        ident = next(ids)
        return (f'<w:{kind}RangeStart {mark(author, date, ident)} w:name="{name}"/>'
                f"<w:{kind} {m(author, date)}>{run(text)}</w:{kind}><w:{kind}RangeEnd w:id=\"{ident}\"/>")

    def cell(content, props=""):
        return f'<w:tc><w:tcPr><w:tcW w:w="3000" w:type="dxa"/>{props}</w:tcPr>{content}</w:tc>'

    deleted_field = (
        f"<w:del {m(ADA, d1)}>"
        '<w:r><w:fldChar w:fldCharType="begin"/></w:r>'
        '<w:r><w:delInstrText xml:space="preserve"> CREATEDATE \\* MERGEFORMAT </w:delInstrText></w:r>'
        '<w:r><w:fldChar w:fldCharType="separate"/></w:r>'
        "<w:r><w:delText>4 May 2026</w:delText></w:r>"
        '<w:r><w:fldChar w:fldCharType="end"/></w:r></w:del>')
    shading = '<w:shd w:val="clear" w:color="auto" w:fill="D9E2F3"/>'
    width_before = '<w:tcPr><w:tcW w:w="3000" w:type="dxa"/></w:tcPr>'
    table = "".join([
        '<w:tbl><w:tblPr><w:tblStyle w:val="TableGrid"/><w:tblW w:w="0" w:type="auto"/></w:tblPr>',
        '<w:tblGrid><w:gridCol w:w="3000"/><w:gridCol w:w="3000"/></w:tblGrid>',
        f'<w:tr>{cell(para(run("Milestone")))}{cell(para(run("Due")))}</w:tr>',
        f'<w:tr>{cell(para(run("Design")))}{cell(para(run("June")))}</w:tr>',
        f"<w:tr><w:trPr><w:ins {m(GRACE, d2)}/></w:trPr>",
        cell(para(ins(GRACE, d2, run("Testing")))), cell(para(ins(GRACE, d2, run("August")))), "</w:tr>",
        f"<w:tr><w:trPr><w:del {m(ADA, d1)}/></w:trPr>",
        cell(para(deleted(ADA, d1, "Pilot"))), cell(para(deleted(ADA, d1, "July"))), "</w:tr>",
        f"<w:tr><w:trPr><w:cantSplit/><w:trPrChange {m(LIN, d3)}><w:trPr/></w:trPrChange></w:trPr>",
        cell(para(run("Launch")), f"{shading}<w:tcPrChange {m(LIN, d3)}>{width_before}</w:tcPrChange>"),
        cell(para(run("September"))), "</w:tr>",
        "</w:tbl>",
    ])
    # Word 16.114 drops a table property change (tblPrChange) from a seed wherever it stands, so none is
    # authored; for the cell revisions below it writes its own table-exception and grid changes.
    cells = "".join([
        '<w:tbl><w:tblPr><w:tblStyle w:val="TableGrid"/><w:tblW w:w="0" w:type="auto"/></w:tblPr>',
        '<w:tblGrid><w:gridCol w:w="3000"/><w:gridCol w:w="3000"/></w:tblGrid>',
        "<w:tr>", cell(para(run("Owner"))), cell(para(run("Lin")), f"<w:cellIns {m(LIN, d3)}/>"), "</w:tr>",
        "<w:tr>", cell(para(run("Review"))), cell(para(run("October")), f"<w:cellDel {m(LIN, d3)}/>"), "</w:tr>",
        "<w:tr>", cell(para(run("Sign-off")), '<w:vMerge w:val="restart"/>'), cell(para(run("Board"))), "</w:tr>",
        "<w:tr>", cell(para(""), f'<w:vMerge/><w:cellMerge {m(GRACE, d2)} w:vMerge="cont"/>'),
        cell(para(run("Legal"))), "</w:tr>",
        "</w:tbl>",
    ])
    body = "".join([
        heading("Supply Agreement Amendment"),
        para(run("The Supplier shall deliver the Goods ") + deleted(ADA, d1, "within ten days")
             + ins(ADA, d1, run("within five working days")) + run(" of each order.")),
        para(run("Payment is due monthly.") + moved("moveFrom", GRACE, d2, "move1", " Late payments bear interest.")),
        para(run("Interest accrues daily.") + moved("moveTo", GRACE, d2, "move1", " Late payments bear interest.")),
        para(ins(LIN, d3, run("This paragraph was inserted in full.")), f"<w:rPr><w:ins {m(LIN, d3)}/></w:rPr>"),
        para(run("This paragraph's mark was deleted, joining it to the next."), f"<w:rPr><w:del {m(ADA, d1)}/></w:rPr>"),
        para(run("The joined paragraph continues here.")),
        para(run("The parties agree ")
             + f'<w:r><w:rPr><w:b/><w:rPrChange {m(GRACE, d2)}><w:rPr/></w:rPrChange></w:rPr>{t("in writing")}</w:r>'
             + run(" to any variation.")),
        para(run("This paragraph was centred under tracking."),
             f'<w:jc w:val="center"/><w:pPrChange {m(LIN, d3)}><w:pPr/></w:pPrChange>'),
        para(run("This agreement was signed on ") + deleted_field + run(".")),
        table,
        para(run("Responsibilities:")),
        cells,
        para(run("End of amendment.")),
    ])
    sect = section(change=f'<w:sectPrChange {m(ADA, d1)}><w:sectPr><w:pgSz w:w="12240" w:h="15840"/>'
                   '<w:pgMar w:top="1440" w:right="1800" w:bottom="1440" w:left="1800" w:header="720" w:footer="720" '
                   'w:gutter="0"/></w:sectPr></w:sectPrChange>')
    parts = {"styles.xml": STYLES, "settings.xml": settings("<w:trackRevisions/>")}
    expected = {
        "word/settings.xml": ["w:trackRevisions"],
        "word/document.xml": ["w:ins", "w:del", "w:delText", "w:moveFrom", "w:moveTo", "w:moveFromRangeStart",
                              "w:moveToRangeStart", "w:rPr/w:ins", "w:rPr/w:del", "w:trPr/w:ins", "w:trPr/w:del",
                              "w:rPrChange", "w:pPrChange", "w:sectPrChange", "w:trPrChange", "w:tcPrChange",
                              "w:cellIns", "w:cellDel", "w:cellMerge", "w:delInstrText"],
    }
    return package("Supply Agreement Amendment", document(body, sect), parts), expected


# -------------------------------------------------------------------- tables

def tables_fixture():
    def cell(content, width, props=""):
        return f'<w:tc><w:tcPr><w:tcW w:w="{width}" w:type="dxa"/>{props}</w:tcPr>{content}</w:tc>'

    right = '<w:jc w:val="right"/>'
    shaded = '<w:shd w:val="clear" w:color="auto" w:fill="E7E6E6"/>'
    spans = '<w:gridSpan w:val="2"/>'
    nested = "".join([
        '<w:tbl><w:tblPr><w:tblStyle w:val="TableGrid"/><w:tblW w:w="0" w:type="auto"/></w:tblPr>',
        '<w:tblGrid><w:gridCol w:w="1200"/><w:gridCol w:w="1200"/></w:tblGrid>',
        f'<w:tr>{cell(para(run("Q1")), 1200)}{cell(para(run("Q2")), 1200)}</w:tr>',
        f'<w:tr>{cell(para(run("12")), 1200)}{cell(para(run("15")), 1200)}</w:tr></w:tbl>',
    ])
    table = "".join([
        '<w:tbl><w:tblPr><w:tblStyle w:val="TableGrid"/><w:tblW w:w="9000" w:type="dxa"/>',
        '<w:tblLook w:val="04A0" w:firstRow="1" w:lastRow="0" w:firstColumn="1" w:lastColumn="0" w:noHBand="0" w:noVBand="1"/>',
        '</w:tblPr><w:tblGrid><w:gridCol w:w="3000"/><w:gridCol w:w="3000"/><w:gridCol w:w="3000"/></w:tblGrid>',
        "<w:tr><w:trPr><w:tblHeader/></w:trPr>",
        cell(para(run("Region", "<w:b/>")), 3000, shaded), cell(para(run("Product", "<w:b/>")), 3000, shaded),
        cell(para(run("Units", "<w:b/>"), right), 3000, shaded), "</w:tr>",
        "<w:tr>", cell(para(run("North")), 3000, '<w:vMerge w:val="restart"/>'), cell(para(run("Lamps")), 3000),
        cell(para(run("120"), right), 3000), "</w:tr>",
        "<w:tr>", cell(para(""), 3000, "<w:vMerge/>"), cell(para(run("Chairs")), 3000),
        cell(para(run("45"), right), 3000), "</w:tr>",
        "<w:tr>", cell(para(run("South")), 3000), cell(para(run("Discontinued in all stores")), 6000, spans), "</w:tr>",
        "<w:tr>", cell(para(run("By quarter")), 3000), cell(nested + para(""), 6000, spans), "</w:tr>",
        "</w:tbl>",
    ])
    body = heading("Sales by Region") + para(run("Units sold in the first half.")) + table + para(run("Figures are provisional."))
    parts = {"styles.xml": STYLES, "settings.xml": settings()}
    expected = {"word/document.xml": ["w:tbl", "w:gridSpan", "w:vMerge", "w:tblHeader", "w:shd", "w:tc/w:tbl"]}
    return package("Sales by Region", document(body, section()), parts), expected


# -------------------------------------------------------------------- report

def png(width, height):
    """A small RGB image: two colour bands, written deterministically."""
    rows = b"".join(b"\x00" + b"".join(bytes((31, 78, 121)) if y < height // 2 else bytes((237, 125, 49))
                                        for _ in range(width)) for y in range(height))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b"")


def field(instruction, result):
    return ('<w:r><w:fldChar w:fldCharType="begin"/></w:r>'
            f'<w:r><w:instrText xml:space="preserve"> {instruction} </w:instrText></w:r>'
            '<w:r><w:fldChar w:fldCharType="separate"/></w:r>'
            f'{run(result)}<w:r><w:fldChar w:fldCharType="end"/></w:r>')


def report_fixture():
    def note(kind, ident, text):
        style = "FootnoteText" if kind == "footnote" else "EndnoteText"
        ref = "FootnoteReference" if kind == "footnote" else "EndnoteReference"
        return (f'<w:{kind} w:id="{ident}"><w:p><w:pPr><w:pStyle w:val="{style}"/></w:pPr>'
                f'<w:r><w:rPr><w:rStyle w:val="{ref}"/></w:rPr><w:{kind}Ref/></w:r>{run(" " + text)}</w:p></w:{kind}>')

    def separators(kind):
        return (f'<w:{kind} w:type="separator" w:id="-1"><w:p><w:r><w:separator/></w:r></w:p></w:{kind}>'
                f'<w:{kind} w:type="continuationSeparator" w:id="0"><w:p><w:r><w:continuationSeparator/></w:r></w:p></w:{kind}>')

    def reference(kind, ident):
        ref = "FootnoteReference" if kind == "footnote" else "EndnoteReference"
        return f'<w:r><w:rPr><w:rStyle w:val="{ref}"/></w:rPr><w:{kind}Reference w:id="{ident}"/></w:r>'

    def item(text, num, level=0):
        return para(run(text), f'<w:pStyle w:val="ListParagraph"/><w:numPr><w:ilvl w:val="{level}"/><w:numId w:val="{num}"/></w:numPr>')

    def levels(formats):
        return "".join(f'<w:lvl w:ilvl="{i}"><w:start w:val="1"/><w:numFmt w:val="{fmt}"/><w:lvlText w:val="{text}"/>'
                       f'<w:lvlJc w:val="left"/><w:pPr><w:ind w:left="{720 * (i + 1)}" w:hanging="360"/></w:pPr></w:lvl>'
                       for i, (fmt, text) in enumerate(formats))

    numbering = xml("w:numbering", (
        f'<w:abstractNum w:abstractNumId="0"><w:multiLevelType w:val="hybridMultilevel"/>{levels([("bullet", "•"), ("bullet", "o")])}</w:abstractNum>'
        f'<w:abstractNum w:abstractNumId="1"><w:multiLevelType w:val="hybridMultilevel"/>{levels([("decimal", "%1."), ("lowerLetter", "%2)")])}</w:abstractNum>'
        '<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num><w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>'))
    emu = 914400
    image = (
        '<w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0">'
        f'<wp:extent cx="{emu}" cy="{emu // 2}"/><wp:effectExtent l="0" t="0" r="0" b="0"/>'
        '<wp:docPr id="1" name="Picture 1" descr="Two colour bands"/>'
        '<wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>'
        '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic>'
        '<pic:nvPicPr><pic:cNvPr id="1" name="bands.png"/><pic:cNvPicPr/></pic:nvPicPr>'
        '<pic:blipFill><a:blip r:embed="rIdImage1"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>'
        f'<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="{emu}" cy="{emu // 2}"/></a:xfrm>'
        '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>'
        '</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>')
    header_footer = (f'<w:headerReference w:type="default" r:id="{rel_id("header1.xml")}"/>'
                     f'<w:footerReference w:type="default" r:id="{rel_id("footer1.xml")}"/>')
    link_style = '<w:rStyle w:val="Hyperlink"/>'
    body = "".join([
        heading("Quarterly Report"),
        para('<w:bookmarkStart w:id="0" w:name="Summary"/>' + run("Summary") + '<w:bookmarkEnd w:id="0"/>', '<w:pStyle w:val="Heading2"/>'),
        para(run("Sales rose in every region") + reference("footnote", 1) + run(" and costs held steady")
             + reference("endnote", 1) + run(".")),
        para(run("The full figures are on ")
             + f'<w:hyperlink r:id="rIdLink1" w:history="1">{run("the results page", link_style)}</w:hyperlink>'
             + run("; see also the ")
             + f'<w:hyperlink w:anchor="Summary" w:history="1">{run("summary", link_style)}</w:hyperlink>'
             + run(".")),
        item("Priorities", 1), item("Retain customers", 1, 1), item("Open two stores", 1, 1),
        item("Hire a buyer", 2), item("Review suppliers", 2), item("Shortlist three", 2, 1),
        para(image),
        para(run("The second section is landscape."), section(header_footer)),
        para(run("Appendix: regional detail follows.")),
    ])
    footer = xml("w:ftr", para(run("Page ") + field("PAGE", "1") + run(" of ")
                               + field("NUMPAGES", "2"), '<w:pStyle w:val="Footer"/>'))
    header = xml("w:hdr", para(run("Quarterly Report: draft for review"), '<w:pStyle w:val="Header"/>'))
    parts = {
        "styles.xml": STYLES,
        "settings.xml": settings(notes='<w:footnotePr><w:footnote w:id="-1"/><w:footnote w:id="0"/></w:footnotePr>'
                                 '<w:endnotePr><w:endnote w:id="-1"/><w:endnote w:id="0"/></w:endnotePr>'),
        "numbering.xml": numbering,
        "footnotes.xml": xml("w:footnotes", separators("footnote") + note("footnote", 1, "Excluding the closed Western store.")),
        "endnotes.xml": xml("w:endnotes", separators("endnote") + note("endnote", 1, "Costs are unaudited.")),
        "header1.xml": header,
        "footer1.xml": footer,
    }
    expected = {
        "word/document.xml": ["w:bookmarkStart", "w:hyperlink@r:id", "w:hyperlink@w:anchor", "w:footnoteReference",
                              "w:endnoteReference", "w:numPr", "wp:inline", "a:blip", "w:pPr/w:sectPr",
                              "w:headerReference", "w:footerReference"],
        "word/footer1.xml": ["w:instrText"],
        "word/header1.xml": ["w:p"],
        "word/footnotes.xml": ["w:footnote"],
        "word/endnotes.xml": ["w:endnote"],
        "word/numbering.xml": ["w:abstractNum"],
    }
    return package("Quarterly Report", document(body, section(header_footer, landscape=True)), parts, links=[("rIdLink1", "https://example.com/results")],
                   media=[("bands.png", png(16, 8))]), expected


FIXTURES = {
    "comments": comments_fixture,
    "revisions": revisions_fixture,
    "tables": tables_fixture,
    "report": report_fixture,
}


# ---------------------------------------------------------------- Word itself

def osascript(script, *args):
    result = subprocess.run(["osascript", "-e", script, *args], capture_output=True, text=True, timeout=TIMEOUT)
    if result.returncode != 0:
        raise RuntimeError(f"osascript: {result.stderr.strip()}")
    return result.stdout.strip()


# Paths are converted outside the `tell`: inside it, `POSIX file` of an argument opens nothing.
SAVE = """on run argv
  set seedPath to (POSIX file (item 1 of argv)) as text
  set outPath to (POSIX file (item 2 of argv)) as text
  set outName to item 3 of argv
  tell application "Microsoft Word"
    set d to open file name seedPath
    save as d file name outPath file format format document
    close document outName saving no
  end tell
end run"""


def save_in_word(seed, out):
    osascript(SAVE, str(seed), str(out), out.name)


def dos_time(date_time):
    year, month, day, hour, minute, second = date_time
    return (hour << 11) | (minute << 5) | (second // 2), ((year - 1980) << 9) | (month << 5) | day


def replace_part(docx, part, data):
    """Rewrite one part of a ZIP archive, copying every other entry's stored bytes and headers unchanged."""
    blob = docx.read_bytes()
    with zipfile.ZipFile(docx) as archive:
        infos = archive.infolist()
    local, central = bytearray(), bytearray()
    for info in infos:
        if info.flag_bits & 0x08:
            raise RuntimeError(f"{docx.name}: {info.filename} uses a data descriptor")
        name_length, extra_length = struct.unpack("<HH", blob[info.header_offset + 26:info.header_offset + 30])
        start = info.header_offset + 30 + name_length + extra_length
        header = blob[info.header_offset:start]
        stored, crc, size = blob[start:start + info.compress_size], info.CRC, info.file_size
        if info.filename == part:
            compressor = zlib.compressobj(9, zlib.DEFLATED, -15)
            stored = compressor.compress(data) + compressor.flush()
            crc, size = zlib.crc32(data) & 0xFFFFFFFF, len(data)
            header = header[:14] + struct.pack("<III", crc, len(stored), size) + header[26:]
        offset = len(local)
        local += header + stored
        time, date = dos_time(info.date_time)
        name = info.filename.encode("utf-8")
        central += struct.pack("<IHHHHHHIIIHHHHHII", 0x02014B50, info.create_system << 8 | info.create_version,
                               info.extract_version, info.flag_bits, info.compress_type, time, date, crc,
                               len(stored), size, len(name), len(info.extra), len(info.comment), 0,
                               info.internal_attr, info.external_attr, offset) + name + info.extra + info.comment
    end = struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, len(infos), len(infos), len(central), len(local), 0)
    docx.write_bytes(bytes(local + central + end))


def scrub_last_modified_by(docx):
    """Word stamps the signed-in account's name as the last editor whatever its own user name says;
    replace it with the fictional editor the seed named."""
    with zipfile.ZipFile(docx) as archive:
        core_xml = archive.read("docProps/core.xml").decode("utf-8")
    scrubbed = re.sub(r"<cp:lastModifiedBy>[^<]*</cp:lastModifiedBy>",
                      f"<cp:lastModifiedBy>{EDITOR}</cp:lastModifiedBy>", core_xml)
    replace_part(docx, "docProps/core.xml", scrubbed.encode("utf-8"))


# --------------------------------------------------------------- verification

def qualified(tag):
    uri, name = tag[1:].split("}", 1) if tag.startswith("{") else ("", tag)
    prefix = next((p for p, u in NAMESPACES.items() if u == uri), uri)
    return f"{prefix}:{name}"


def present(root, probe):
    """An expectation: `p:name`, `p:name@p:attr`, `p:name@p:attr=value` or `p:parent/p:child`."""
    if "/" in probe:
        parent, child = probe.split("/")
        return any(qualified(e.tag) == parent and any(qualified(c.tag) == child for c in e) for e in root.iter())
    name, _, attribute = probe.partition("@")
    attribute, _, value = attribute.partition("=")
    for element in root.iter():
        if qualified(element.tag) != name:
            continue
        if not attribute:
            return True
        for key, actual in element.attrib.items():
            if qualified(key) == attribute and (not value or actual == value):
                return True
    return False


def verify(docx, expected, private):
    problems = []
    with zipfile.ZipFile(docx) as archive:
        if archive.testzip() is not None:
            problems.append("the archive fails its CRC check")
        for name in archive.namelist():
            if not name.endswith((".xml", ".rels")):
                continue
            text = archive.read(name).decode("utf-8", "replace").lower()
            problems += [f"{name}: contains {needle!r}" for needle in private if needle.lower() in text]
        for part, probes in expected.items():
            if part not in archive.namelist():
                problems.append(f"{part}: Word did not write the part")
                continue
            root = ET.fromstring(archive.read(part))
            problems += [f"{part}: Word dropped {probe}" for probe in probes if not present(root, probe)]
    return problems


def private_strings():
    """What must not appear in a fixture: Word's user name and initials, the account's login and full
    names, the home directory, and any `@`, which would begin an e-mail address."""
    user = osascript('tell application "Microsoft Word" to return (user name) & linefeed & (user initials)').split("\n")
    account = pwd.getpwuid(os.getuid())
    names = {user[0], account.pw_name, account.pw_gecos, str(pathlib.Path.home()), "@"}
    names |= {word for full in (user[0], account.pw_gecos) for word in full.split() if len(word) > 2}
    return sorted(names - {""})


def main():
    if sys.platform != "darwin" or not pathlib.Path("/Applications/Microsoft Word.app").exists():
        sys.exit("Microsoft Word for macOS is required")
    version = osascript('tell application "Microsoft Word" to return version')
    print(f"Microsoft Word {version}")
    private = private_strings()
    if WORK.exists():
        shutil.rmtree(WORK)
    (WORK / "seed").mkdir(parents=True)
    (WORK / "out").mkdir()
    OUT.mkdir(parents=True, exist_ok=True)
    failures = []
    try:
        for name, build in FIXTURES.items():
            files, expected = build()
            seed = WORK / "seed" / f"{name}.docx"
            with zipfile.ZipFile(seed, "w", zipfile.ZIP_DEFLATED) as archive:
                for part, data in files.items():
                    archive.writestr(part, data)
            out = WORK / "out" / f"{name}.docx"
            save_in_word(seed, out)
            scrub_last_modified_by(out)
            problems = verify(out, expected, private)
            failures += [f"{name}: {problem}" for problem in problems]
            if not problems:
                shutil.copyfile(out, OUT / out.name)
                print(f"wrote {(OUT / out.name).relative_to(ROOT)}")
    finally:
        shutil.rmtree(WORK, ignore_errors=True)
    for failure in failures:
        print(f"FAIL {failure}")
    print(f"record Microsoft Word {version} (macOS) in tests/fixtures/provenance.json")
    return 1 if failures else 0


if __name__ == "__main__":
    if sys.argv[1:]:
        sys.exit(__doc__)
    sys.exit(main())
