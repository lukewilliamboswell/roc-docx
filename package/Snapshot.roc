## The package's reading of a document as a semantic snapshot: the JSON
## document, versioned `roc-docx-snapshot/1`, that the oracle lanes compare
## with LibreOffice's and pandoc's readings of the same document.
##
## The snapshot has the contract's fixed shape, every field present, and
## declares in `keys` only what the package is authoritative for: the
## body's blocks with their kind, level and text, their runs' direct
## formatting and hyperlinks, the notes' kinds and text, the sections' page
## geometry and header and footer text, and the core properties. Every other
## field holds its empty value.
import Docx
import Document
import Opc
import Styles
import XmlTree

Snapshot :: [].{

	## The snapshot of a document as JSON text, one block to a line. `path`
	## names the document relative to the repository root, as the oracle
	## adapters do, and `version` is the producer version it reports.
	##
	## The blocks are the body's in reading order, through content controls
	## and custom XML: each paragraph with its text, unless the text is empty
	## and the paragraph anchors no note, comment or revision, and each table
	## as a block of its own with no text. A paragraph anchors something when
	## it holds a revision, a comment range boundary or reference, a footnote
	## or endnote reference, or a revision of its paragraph mark. The text is
	## the current text of [Document.paragraph_text], and a paragraph whose
	## mark is deleted or moved away is one block with the paragraph after
	## it, unless a table comes between them. A paragraph's runs split its text where a hyperlink begins or ends, each
	## with the hyperlink's target: its address, its address and `#` and the
	## location, or `#` and the bookmark's name. A hyperlink is a hyperlink
	## element or the result of a `HYPERLINK` field, whose target
	## [Document.field_target] reads. Runs also split where a run's direct
	## formatting changes; formatting a style gives is not run formatting.
	##
	## A paragraph is a heading when its effective outline level, from its
	## style or stated directly, is one of the nine heading levels, its level
	## counted from 1; otherwise it is a list item when its effective
	## numbering reference names a numbering instance, its level its list
	## level counted from 1. Paragraphs joined into one block take the kind of
	## the last of them, whose mark remains.
	##
	## The notes are the footnotes and endnotes the body refers to, in the
	## order of their references, each with its blocks' text joined by line
	## feeds.
	##
	## The sections are those [Document.sections] finds in the body, with
	## their page geometry in twips and the text of their default header
	## and footer, and the properties are the document's core properties,
	## as `sections_json` and `properties_json` describe.
	json : Document, { path : Str, version : Str } -> Str
	json = |document, { path, version }| {
		body = Docx.body(document)
		styles = Docx.styles(document).styles
		blocks = snapshot_of_blocks(body, styles).map(block_json)
		footnotes = Docx.footnotes(document)
		endnotes = Docx.endnotes(document)
		notes = body.fold(List.with_capacity(8), note_references).keep_oks(
			|reference| {
				(kind, list) = match reference.kind {
					Footnote => ("footnote", footnotes)
					Endnote => ("endnote", endnotes)
				}
				note = list.get(reference.note) ? |_| Missing
				text = Str.join_with(snapshot_of_blocks(note.content, styles).map(|block| block.text), "\n")
				Ok("{\"kind\": \"${kind}\", \"text\": ${quoted(text)}}")
			},
		)
		Str.join_with(
			[
				"{",
				"  \"schema\": \"roc-docx-snapshot/1\",",
				"  \"producer\": {\"name\": \"roc-docx\", \"version\": ${quoted(version)}},",
				"  \"document\": ${quoted(path)},",
				"  \"keys\": [${Str.join_with(keys.map(quoted), ", ")}],",
				"  \"blocks\": [${list_json(blocks)}],",
				"  \"notes\": [${list_json(notes)}],",
				"  \"comments\": [],",
				"  \"revisions\": [],",
				"  \"sections\": [${list_json(sections_json(document, body, styles))}],",
				"  \"properties\": ${properties_json(Docx.core_properties(document))}",
				"}",
				"",
			],
			"\n",
		)
	}
}

wordprocessingml : Str
wordprocessingml = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

keys : List(Str)
keys = [
	"blocks.kind",
	"blocks.level",
	"blocks.text",
	"blocks.rows",
	"blocks.runs.bold",
	"blocks.runs.italic",
	"blocks.runs.underline",
	"blocks.runs.strike",
	"blocks.runs.superscript",
	"blocks.runs.subscript",
	"blocks.runs.link",
	"notes.kind",
	"notes.text",
	"sections.page_width",
	"sections.page_height",
	"sections.orientation",
	"sections.margin_top",
	"sections.margin_bottom",
	"sections.margin_left",
	"sections.margin_right",
	"sections.header",
	"sections.footer",
	"properties.title",
	"properties.subject",
	"properties.creator",
	"properties.keywords",
	"properties.description",
	"properties.last_modified_by",
	"properties.created",
	"properties.modified",
]

# The body's sections as JSON objects: each section that ends in the body,
# and after the last one, unless the body ends with it, the section the rest
# of the body is in, which states nothing. A section that does not give its
# page size or margins has the contract's: a portrait Letter page, 12,240 by
# 15,840 twips, with margins of 1,440. Its header and footer are the text of
# its default header and footer, a section without one having the previous
# section's, each block's text joined by line feeds as a note's is.
sections_json : Document, List(Document.Block), Styles -> List(Str)
sections_json = |document, body, styles| {
	unstated = { start: Unset, page_size: Unset, margins: Unset, columns: Unset, page_numbers: Unset, title_page: Unset, headers: [], footers: [], preserved: [] }
	trailing = match body.last() {
		Ok(Section(_)) => []
		_ => [unstated]
	}
	var $header = Err(NoPart)
	var $footer = Err(NoPart)
	var $out = List.with_capacity(2)
	for section in List.concat(Document.sections(body), trailing) {
		$header = default_part(section.headers, $header)
		$footer = default_part(section.footers, $footer)
		$out = List.append($out, section_json(section, region_text(document, $header, styles), region_text(document, $footer, styles)))
	}
	$out
}

default_part : List(Document.HeaderFooter), Try(Str, [NoPart]) -> Try(Str, [NoPart])
default_part = |references, previous|
	match references.find_first(|reference| reference.kind == Default) {
		Ok(reference) => Ok(reference.part)
		Err(_) => previous
	}

region_text : Document, Try(Str, [NoPart]), Styles -> Str
region_text = |document, part, styles|
	match part {
		Ok(name) => Str.join_with(snapshot_of_blocks(Docx.header_footer(document, name), styles).map(|block| block.text), "\n")
		Err(NoPart) => ""
	}

section_json : Document.Section, Str, Str -> Str
section_json = |section, header, footer| {
	(width, height, orientation) = match section.page_size {
		Size(size) => (size.width, size.height, if (size.orientation == Landscape) "landscape" else "portrait")
		Unset => (12240, 15840, "portrait")
	}
	(top, bottom, left, right) = match section.margins {
		Margins(margins) => (margins.top.to_str(), margins.bottom.to_str(), margins.left.to_str(), margins.right.to_str())
		Unset => ("1440", "1440", "1440", "1440")
	}
	"{\"page_width\": ${width.to_str()}, \"page_height\": ${height.to_str()}, \"orientation\": \"${orientation}\", \"margin_top\": ${top}, \"margin_bottom\": ${bottom}, \"margin_left\": ${left}, \"margin_right\": ${right}, \"header\": ${quoted(header)}, \"footer\": ${quoted(footer)}}"
}

# The core properties as the snapshot's object, a property that is not
# given empty and a date as the document writes it.
properties_json : Document.CoreProperties -> Str
properties_json = |core| {
	text = |property|
		match property {
			Text(value) => quoted(value)
			Unset => "\"\""
		}
	date = |property|
		match property {
			Date(value) => quoted(value)
			Unset => "\"\""
		}
	"{\"title\": ${text(core.title)}, \"subject\": ${text(core.subject)}, \"creator\": ${text(core.creator)}, \"keywords\": ${text(core.keywords)}, \"description\": ${text(core.description)}, \"last_modified_by\": ${text(core.last_modified_by)}, \"created\": ${date(core.created)}, \"modified\": ${date(core.modified)}}"
}

# A block of the snapshot, and a run of its text with its direct formatting
# and its hyperlink's target.
SnapshotBlock : { kind : Str, level : U64, text : Str, runs : List(SnapshotRun), rows : List(List(Str)) }

SnapshotRun : { text : Str, formatting : Formatting, link : Str }

# The run formatting the snapshot compares, from a run's direct properties.
Formatting : { bold : Bool, italic : Bool, underline : Bool, strike : Bool, superscript : Bool, subscript : Bool }

formatting : Document.RunProperties -> Formatting
formatting = |properties| {
	bold: properties.bold == On,
	italic: properties.italic == On,
	underline: match properties.underline {
		Underline(NoUnderline) => Bool.False
		Underline(_) => Bool.True
		Unset => Bool.False
	},
	strike: properties.strike == On or properties.double_strike == On,
	superscript: properties.vertical_align == Superscript,
	subscript: properties.vertical_align == Subscript,
}

# A paragraph's kind and level: a heading by its outline level, otherwise a
# list item by its numbering reference, otherwise a paragraph.
paragraph_shape : Styles, Document.ParagraphProperties -> { kind : Str, level : U64 }
paragraph_shape = |styles, properties| {
	effective = Styles.effective_paragraph(styles, properties, {})
	match (effective.outline_level, effective.numbering.instance, effective.numbering.level) {
		(Level(level), _, _) if level < 9 => { kind: "heading", level: level.to_u64() + 1 }
		(_, Instance(instance), Level(level)) if instance != 0 => { kind: "list_item", level: level.to_u64() + 1 }
		(_, Instance(instance), Unset) if instance != 0 => { kind: "list_item", level: 1 }
		_ => { kind: "paragraph", level: 0 }
	}
}

# The snapshot blocks so far; the paragraphs whose marks are deleted, joined,
# waiting for the paragraph they run on into; and the complex fields open
# where they end, innermost last, with their code so far and whether their
# result has begun: a field's result can span paragraphs.
Blocks : { blocks : List(SnapshotBlock), joined : Try(Joined, [NoParagraph]), fields : List(OpenField) }

Joined : { text : Str, anchored : Bool, runs : List(SnapshotRun), properties : Document.ParagraphProperties }

OpenField : { code : Str, in_result : Bool }

# Runs so far, and the complex fields open where they end.
Runs : { runs : List(SnapshotRun), fields : List(OpenField) }

# The snapshot blocks of blocks.
snapshot_of_blocks : List(Document.Block), Styles -> List(SnapshotBlock)
snapshot_of_blocks = |blocks, styles| flush(blocks.fold({ blocks: List.with_capacity(64), joined: Err(NoParagraph), fields: [] }, |state, block| snapshot_blocks(state, block, styles)), styles).blocks

# Append a block's snapshot blocks.
snapshot_blocks : Blocks, Document.Block, Styles -> Blocks
snapshot_blocks = |state, block, styles|
	match block {
		Paragraph(paragraph) => {
			before = state.joined ?? { text: "", anchored: Bool.False, runs: [], properties: paragraph.properties }
			read = paragraph.content.fold({ runs: before.runs, fields: state.fields }, |runs, inline| snapshot_runs(runs, inline, ""))
			joined = { text: Str.concat(before.text, Document.paragraph_text(paragraph)), anchored: before.anchored or anchors(paragraph), runs: read.runs, properties: paragraph.properties }
			if Document.joins_next(paragraph) {
				{ blocks: state.blocks, joined: Ok(joined), fields: read.fields }
			} else {
				flush({ blocks: state.blocks, joined: Ok(joined), fields: read.fields }, styles)
			}
		}

		Table(table) => {
			flushed = flush(state, styles)
			{ blocks: List.append(flushed.blocks, { kind: "table", level: 0, text: "", runs: [], rows: rows(table) }), joined: Err(NoParagraph), fields: flushed.fields }
		}

		Container({ element: _, content }) => content.fold(state, |inner_state, inner| snapshot_blocks(inner_state, inner, styles))
		Section(_) => state
		Preserved(_) => state
	}

# Append the joined paragraph, as a block when it has text or anchors something.
flush : Blocks, Styles -> Blocks
flush = |state, styles|
	match state.joined {
		Ok(joined) if joined.text != "" or joined.anchored => {
			shape = paragraph_shape(styles, joined.properties)
			{ blocks: List.append(state.blocks, { kind: shape.kind, level: shape.level, text: joined.text, runs: joined.runs, rows: [] }), joined: Err(NoParagraph), fields: state.fields }
		}

		_ => { blocks: state.blocks, joined: Err(NoParagraph), fields: state.fields }
	}

# A table as a text grid: a row's cells in order, each a cell's text with
# an empty cell for every further grid column it spans, after an empty cell
# for every grid column the row skips before its first cell and before one
# for every grid column it skips after its last. A cell that continues a
# vertical merge is empty, whatever it holds, as the cell that starts the
# merge covers it.
rows : Document.Table -> List(List(Str))
rows = |table|
	Document.table_rows(table).map(
		|row| {
			var $cells = List.repeat("", columns(row.properties.grid_before, 0))
			for cell in Document.row_cells(row) {
				text = if (cell.properties.merge == Continue) "" else cell_text(cell.content)
				$cells = List.concat(List.append($cells, text), List.repeat("", columns(cell.properties.span, 1) - 1))
			}
			List.concat($cells, List.repeat("", columns(row.properties.grid_after, 0)))
		},
	)

# A count of grid columns, or the default when none is given.
columns : [Unset, Columns(U64)], U64 -> U64
columns = |count, default|
	match count {
		Columns(n) => n
		Unset => default
	}

# A cell's text: the text of each of its blocks the snapshot has, joined by
# line feeds; a table in the cell is a block without text.
cell_text : List(Document.Block) -> Str
cell_text = |content| Str.join_with(content.fold(List.with_capacity(content.len()), block_texts), "\n")

block_texts : List(Str), Document.Block -> List(Str)
block_texts = |out, block|
	match block {
		Paragraph(paragraph) => {
			text = Document.paragraph_text(paragraph)
			if text != "" or anchors(paragraph) {
				List.append(out, text)
			} else {
				out
			}
		}

		Table(_) => List.append(out, "")
		Container({ element: _, content }) => content.fold(out, block_texts)
		Section(_) => out
		Preserved(_) => out
	}

# Append an inline's runs, under the target of the hyperlink element it is
# in, or "" when it is in none.
snapshot_runs : Runs, Document.Inline, Str -> Runs
snapshot_runs = |state, inline, link|
	match inline {
		Hyperlink({ target, preserved: _, content }) => content.fold(state, |out, inner| snapshot_runs(out, inner, address(target)))
		SimpleField({ code, preserved: _, content }) => {
			field_link = match Document.field_target(code) {
				Ok(target) => address(target)
				Err(NotAHyperlink) => link
			}
			content.fold(state, |out, inner| snapshot_runs(out, inner, field_link))
		}

		Container({ element, content }) =>
			if is_named(element, ["del", "moveFrom"]) {
				state
			} else {
				content.fold(state, |out, inner| snapshot_runs(out, inner, link))
			}

		Run(run) => run.content.fold(state, |out, content| content_runs(out, run, content, link))
		_ => with_text(state, { text: Document.inline_text(inline), formatting: formatting(Document.no_run_properties), link })
	}

# Append a run's content, following the complex fields it begins, codes,
# separates and ends. Text in a `HYPERLINK` field's result, and in a field
# nested in it, has that field's target when no hyperlink element gives it
# one.
content_runs : Runs, Document.Run, Document.RunContent, Str -> Runs
content_runs = |state, run, content, link|
	match content {
		FieldMark({ kind: Begin, element: _ }) => { runs: state.runs, fields: List.append(state.fields, { code: "", in_result: Bool.False }) }
		FieldMark({ kind: Separate, element: _ }) => with_innermost(state, |field| { code: field.code, in_result: Bool.True })
		FieldMark({ kind: End, element: _ }) => { runs: state.runs, fields: List.drop_last(state.fields, 1) }
		FieldCode(code) => with_innermost(state, |field| { code: Str.concat(field.code, code), in_result: field.in_result })
		_ => {
			text = Document.inline_text(Run({ properties: run.properties, content: [content] }))
			with_text(state, { text, formatting: formatting(run.properties), link: if (link == "") field_link(state.fields) else link })
		}
	}

# The target of the innermost open `HYPERLINK` field whose result has begun,
# or "".
field_link : List(OpenField) -> Str
field_link = |fields| {
	var $index = fields.len()
	while $index > 0 {
		$index = $index - 1
		match fields.get($index) {
			Ok(field) if field.in_result =>
				match Document.field_target(field.code) {
					Ok(target) => {
						return address(target)
					}

					Err(NotAHyperlink) => {}
				}

			_ => {}
		}
	}
	""
}

with_innermost : Runs, (OpenField -> OpenField) -> Runs
with_innermost = |state, change|
	match state.fields.last() {
		Ok(field) => { runs: state.runs, fields: List.append(List.drop_last(state.fields, 1), change(field)) }
		Err(_) => state
	}

# Text joins the run before when their formatting and links are the same.
with_text : Runs, SnapshotRun -> Runs
with_text = |state, run|
	match state.runs.last() {
		_ if run.text == "" => state
		Ok(previous) if previous.link == run.link and previous.formatting == run.formatting => { runs: List.append(List.drop_last(state.runs, 1), { ..run, text: Str.concat(previous.text, run.text) }), fields: state.fields }
		_ => { runs: List.append(state.runs, run), fields: state.fields }
	}

# A hyperlink's target as the snapshot gives it: its address, its address and
# `#` and the location, or `#` and the bookmark's name.
address : Document.LinkTarget -> Str
address = |target|
	match target {
		External(url) => url
		ExternalAt({ url, location }) => "${url}#${location}"
		Internal(name) => "#${name}"
	}

block_json : SnapshotBlock -> Str
block_json = |block| {
	flag = |value| if (value) "true" else "false"
	runs = block.runs.map(
		|run| {
			f = run.formatting
			"{\"text\": ${quoted(run.text)}, \"bold\": ${flag(f.bold)}, \"italic\": ${flag(f.italic)}, \"underline\": ${flag(f.underline)}, \"strike\": ${flag(f.strike)}, \"superscript\": ${flag(f.superscript)}, \"subscript\": ${flag(f.subscript)}, \"link\": ${quoted(run.link)}}"
		},
	)
	row_json = |cells| "[${Str.join_with(cells.map(quoted), ", ")}]"
	"{\"kind\": \"${block.kind}\", \"level\": ${block.level.to_str()}, \"list\": \"\", \"text\": ${quoted(block.text)}, \"runs\": [${Str.join_with(runs, ", ")}], \"rows\": [${Str.join_with(block.rows.map(row_json), ", ")}]}"
}

# Objects of a JSON list, one to a line.
list_json : List(Str) -> Str
list_json = |items| if (items.is_empty()) "" else "\n    ${Str.join_with(items, ",\n    ")}\n  "

# Append the note references of a block, in reading order.
note_references : List({ kind : Document.NoteKind, note : U64 }), Document.Block -> List({ kind : Document.NoteKind, note : U64 })
note_references = |out, block|
	match block {
		Paragraph(paragraph) => paragraph.content.fold(out, inline_note_references)
		Table(table) => Document.table_rows(table).fold(out, |by_row, row| Document.row_cells(row).fold(by_row, |by_cell, cell| cell.content.fold(by_cell, note_references)))
		Container({ element: _, content }) => content.fold(out, note_references)
		Section(_) => out
		Preserved(_) => out
	}

inline_note_references : List({ kind : Document.NoteKind, note : U64 }), Document.Inline -> List({ kind : Document.NoteKind, note : U64 })
inline_note_references = |out, inline|
	match inline {
		Run(run) =>
			run.content.fold(
				out,
				|found, content|
					match content {
						NoteReference(reference) => List.append(found, reference)
						_ => found
					},
			)

		Hyperlink({ target: _, preserved: _, content }) => content.fold(out, inline_note_references)
		SimpleField({ code: _, preserved: _, content }) => content.fold(out, inline_note_references)
		Container({ element: _, content }) => content.fold(out, inline_note_references)
		_ => out
	}

revisions : List(Str)
revisions = ["ins", "del", "moveFrom", "moveTo"]

anchors : Document.Paragraph -> Bool
anchors = |paragraph|
	paragraph.content.any(inline_anchors)
		or paragraph.properties.preserved.any(
			|property|
				match property {
					Element(element) if is_named(property, ["rPr"]) => element.children.any(|child| is_named(child, revisions))
					_ => Bool.False
				},
		)

inline_anchors : Document.Inline -> Bool
inline_anchors = |inline|
	match inline {
		Run(run) =>
			run.content.any(
				|content|
					match content {
						NoteReference(_) => Bool.True
						Preserved(node) => is_named(node, ["footnoteReference", "endnoteReference", "commentReference"])
						_ => Bool.False
					},
			)

		Hyperlink({ target: _, preserved: _, content }) => content.any(inline_anchors)
		SimpleField({ code: _, preserved: _, content }) => content.any(inline_anchors)
		Container({ element, content }) => is_named(element, revisions) or content.any(inline_anchors)
		BookmarkStart(_) => Bool.False
		BookmarkEnd(_) => Bool.False
		Preserved(node) => is_named(node, ["commentRangeStart", "commentRangeEnd"])
	}

is_named : XmlTree.Node, List(Str) -> Bool
is_named = |node, locals|
	match node {
		Element(element) => element.name.namespace == Uri(wordprocessingml) and locals.contains(element.name.local)
		Text(_) => Bool.False
	}

# A string as a JSON string literal: quotes, backslashes and control
# characters escaped, everything else as it is.
quoted : Str -> Str
quoted = |text| {
	hex = "0123456789abcdef".to_utf8()
	var $out = List.with_capacity(text.to_utf8().len() + 2)
	$out = List.append($out, '"')
	for byte in text.to_utf8() {
		$out = if byte == '"' {
			List.concat($out, ['\\', '"'])
		} else if byte == '\\' {
			List.concat($out, ['\\', '\\'])
		} else if byte == '\n' {
			List.concat($out, ['\\', 'n'])
		} else if byte == '\t' {
			List.concat($out, ['\\', 't'])
		} else if byte == '\r' {
			List.concat($out, ['\\', 'r'])
		} else if byte < 0x20 {
			List.concat($out, ['\\', 'u', '0', '0', hex.get(byte.to_u64() // 16) ?? '0', hex.get(byte.to_u64() % 16) ?? '0'])
		} else {
			List.append($out, byte)
		}
	}
	Str.from_utf8(List.append($out, '"')) ?? "\"\""
}

# The snapshot of a package whose main document has this body content, with
# an external hyperlink relationship `rId1`, these notes in its footnotes
# and endnotes parts, and a header part, `rId4`, saying `Draft`.
snapshot_of : Str, { footnotes : Str, endnotes : Str } -> Try(Str, _)
snapshot_of = |content, notes| {
	relationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
	part = |name, kind| { name: "/word/${name}.xml", content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.${kind}+xml", relationships: [] }
	graph = {
		relationships: [{ id: "rId1", kind: Opc.officedocument_relationship, target: "/word/document.xml", mode: Internal }],
		parts: [
			{
				name: "/word/document.xml",
				content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml",
				relationships: [
					{ id: "rId1", kind: "${relationships}/hyperlink", target: "https://example.org/", mode: External },
					{ id: "rId2", kind: "${relationships}/footnotes", target: "/word/footnotes.xml", mode: Internal },
					{ id: "rId3", kind: "${relationships}/endnotes", target: "/word/endnotes.xml", mode: Internal },
					{ id: "rId4", kind: "${relationships}/header", target: "/word/header1.xml", mode: Internal },
				],
			},
			part("footnotes", "footnotes"),
			part("endnotes", "endnotes"),
			part("header1", "header"),
		],
	}
	declarations = "xmlns:w='${wordprocessingml}' xmlns:r='${relationships}'"
	xml = |name|
		if name == "/word/footnotes.xml" {
			"<w:footnotes ${declarations}>${notes.footnotes}</w:footnotes>"
		} else if name == "/word/endnotes.xml" {
			"<w:endnotes ${declarations}>${notes.endnotes}</w:endnotes>"
		} else if name == "/word/header1.xml" {
			"<w:hdr ${declarations}><w:p><w:r><w:t>Draft</w:t></w:r></w:p></w:hdr>"
		} else {
			"<w:document ${declarations}><w:body>${content}</w:body></w:document>"
		}
	parsed = Docx.parse(Opc.to_bytes(graph, |name| Bytes(xml(name).to_utf8()))?)?
	Ok(Snapshot.json(parsed.document, { path: "a \"b\".docx", version: "test" }))
}

no_notes : { footnotes : Str, endnotes : Str }
no_notes = { footnotes: "", endnotes: "" }

# A snapshot block as JSON, with its runs.
block_line : Str, Str, Str -> Str
block_line = |kind, text, runs| "    {\"kind\": \"${kind}\", \"level\": 0, \"list\": \"\", \"text\": \"${text}\", \"runs\": [${runs}], \"rows\": []}"

# A snapshot run as JSON.
run_line : Str, Str -> Str
run_line = |text, link| "{\"text\": \"${text}\", \"bold\": false, \"italic\": false, \"underline\": false, \"strike\": false, \"superscript\": false, \"subscript\": false, \"link\": \"${link}\"}"

## Empty paragraphs are blocks only when they anchor something, a table is
## one block with its text grid, and paragraphs in content controls are
## blocks; a section that states no page has the contract's page, and a
## document without core properties has every property empty.
expect {
	empty = "<w:p/><w:p><w:r><w:t></w:t></w:r><w:bookmarkStart w:id='1' w:name='b'/></w:p>"
	anchoring = "<w:p><w:del><w:r><w:delText>gone</w:delText></w:r></w:del></w:p><w:p><w:commentRangeStart w:id='1'/></w:p><w:p><w:r><w:footnoteReference w:id='1'/></w:r></w:p><w:p><w:pPr><w:rPr><w:ins w:id='2'/></w:rPr></w:pPr></w:p>"
	table = "<w:tbl><w:tr><w:tc><w:p><w:r><w:t>cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>"
	control = "<w:sdt><w:sdtContent><w:p><w:r><w:t>Say \"hi\"</w:t><w:br/></w:r></w:p></w:sdtContent></w:sdt>"
	block = |kind, text| block_line(kind, text, "")
	expected = Str.join_with(
		[
			"{",
			"  \"schema\": \"roc-docx-snapshot/1\",",
			"  \"producer\": {\"name\": \"roc-docx\", \"version\": \"test\"},",
			"  \"document\": \"a \\\"b\\\".docx\",",
			"  \"keys\": [${Str.join_with(keys.map(quoted), ", ")}],",
			"  \"blocks\": [",
			"${block("paragraph", "")},\n${block("paragraph", "")},\n${block("paragraph", "")},\n${block("paragraph", "")},",
			"    {\"kind\": \"table\", \"level\": 0, \"list\": \"\", \"text\": \"\", \"runs\": [], \"rows\": [[\"cell\"]]},",
			block_line("paragraph", "Say \\\"hi\\\"\\n", run_line("Say \\\"hi\\\"\\n", "")),
			"  ],",
			"  \"notes\": [],",
			"  \"comments\": [],",
			"  \"revisions\": [],",
			"  \"sections\": [",
			"    {\"page_width\": 12240, \"page_height\": 15840, \"orientation\": \"portrait\", \"margin_top\": 1440, \"margin_bottom\": 1440, \"margin_left\": 1440, \"margin_right\": 1440, \"header\": \"\", \"footer\": \"\"}",
			"  ],",
			"  \"properties\": {\"title\": \"\", \"subject\": \"\", \"creator\": \"\", \"keywords\": \"\", \"description\": \"\", \"last_modified_by\": \"\", \"created\": \"\", \"modified\": \"\"}",
			"}",
			"",
		],
		"\n",
	)
	snapshot_of("${empty}${anchoring}${table}${control}<w:sectPr/>", no_notes) == Ok(expected)
}

## A table's text grid gives a spanning cell empty cells for the columns it
## covers, a cell continuing a vertical merge no text, and the grid columns
## a row skips empty cells; a cell's paragraphs are joined by line feeds,
## empty ones left out and a nested table an empty line.
expect {
	p = |text| "<w:p><w:r><w:t>${text}</w:t></w:r></w:p>"
	tc = |properties, content| "<w:tc><w:tcPr>${properties}</w:tcPr>${content}</w:tc>"
	nested = "<w:tbl><w:tr>${tc("", p("inner"))}</w:tr></w:tbl>"
	rows_xml = [
		"<w:tr>${tc("<w:gridSpan w:val='2'/>", p("span"))}${tc("", p("c"))}</w:tr>",
		"<w:tr>${tc("<w:vMerge w:val='restart'/>", p("down"))}${tc("", "${p("x")}<w:p/>${p("y")}")}${tc("", "<w:p/>")}</w:tr>",
		"<w:tr>${tc("<w:vMerge/>", p("hidden"))}${tc("", "${p("n1")}${nested}${p("n2")}")}${tc("", p("z"))}</w:tr>",
		"<w:tr><w:trPr><w:gridBefore w:val='1'/></w:trPr>${tc("", p("b1"))}${tc("", p("b2"))}</w:tr>",
		"<w:tr><w:trPr><w:gridAfter w:val='1'/></w:trPr>${tc("", p("a1"))}${tc("", p("a2"))}</w:tr>",
	]
	expected = "\"rows\": [[\"span\", \"\", \"c\"], [\"down\", \"x\\ny\", \"\"], [\"\", \"n1\\n\\nn2\", \"z\"], [\"\", \"b1\", \"b2\"], [\"a1\", \"a2\", \"\"]]"
	snapshot_of("<w:tbl>${Str.join_with(rows_xml, "")}</w:tbl>", no_notes).map_ok(|json| json.contains(expected)) == Ok(Bool.True)
}

## A heading is recognised by its outline level and a list item by its
## numbering reference; runs carry their direct formatting through
## hyperlinks, neighbours with the same formatting and link joined.
expect {
	heading = "<w:p><w:pPr><w:outlineLvl w:val='1'/></w:pPr><w:r><w:t>Head</w:t></w:r></w:p><w:p><w:pPr><w:outlineLvl w:val='9'/></w:pPr><w:r><w:t>Body</w:t></w:r></w:p>"
	formatted = "<w:r><w:rPr><w:b/></w:rPr><w:t>Item</w:t></w:r><w:r><w:rPr><w:b w:val='true'/></w:rPr><w:t xml:space='preserve'> one</w:t></w:r><w:hyperlink w:anchor='b'><w:r><w:rPr><w:i/><w:u w:val='single'/><w:vertAlign w:val='superscript'/><w:dstrike/></w:rPr><w:t>2</w:t></w:r></w:hyperlink><w:r><w:rPr><w:b w:val='0'/><w:u w:val='none'/><w:vertAlign w:val='subscript'/></w:rPr><w:t>3</w:t></w:r>"
	item = "<w:p><w:pPr><w:numPr><w:ilvl w:val='1'/><w:numId w:val='3'/></w:numPr></w:pPr><w:bookmarkStart w:id='1' w:name='b'/>${formatted}<w:bookmarkEnd w:id='1'/></w:p><w:p><w:pPr><w:numPr><w:numId w:val='0'/></w:numPr></w:pPr><w:r><w:t>Not listed</w:t></w:r></w:p>"
	run = |text, flags, link| "{\"text\": \"${text}\", ${flags}, \"link\": \"${link}\"}"
	runs = Str.join_with(
		[
			run("Item one", "\"bold\": true, \"italic\": false, \"underline\": false, \"strike\": false, \"superscript\": false, \"subscript\": false", ""),
			run("2", "\"bold\": false, \"italic\": true, \"underline\": true, \"strike\": true, \"superscript\": true, \"subscript\": false", "#b"),
			run("3", "\"bold\": false, \"italic\": false, \"underline\": false, \"strike\": false, \"superscript\": false, \"subscript\": true", ""),
		],
		", ",
	)
	json = snapshot_of("${heading}${item}", no_notes)?
	json.contains("{\"kind\": \"heading\", \"level\": 2, \"list\": \"\", \"text\": \"Head\"")
		and json.contains("{\"kind\": \"paragraph\", \"level\": 0, \"list\": \"\", \"text\": \"Body\"")
		and json.contains("{\"kind\": \"list_item\", \"level\": 2, \"list\": \"\", \"text\": \"Item one23\", \"runs\": [${runs}]")
		and json.contains("{\"kind\": \"paragraph\", \"level\": 0, \"list\": \"\", \"text\": \"Not listed\"")
}

## A body with no blocks has an empty list of them.
expect snapshot_of("<w:p/>", no_notes).map_ok(|json| json.contains("\"blocks\": [],")) == Ok(Bool.True)

## A paragraph's runs split its text where hyperlinks begin and end, each
## with its target; a hyperlink to a location in an address and one to a
## bookmark have `#` before the location or name.
expect {
	link = |attributes, text| "<w:hyperlink ${attributes}><w:r><w:t>${text}</w:t></w:r></w:hyperlink>"
	paragraph = "<w:p><w:r><w:t xml:space='preserve'>See </w:t></w:r>${link("r:id='rId1'", "a")}${link("r:id='rId1'", "b")}${link("r:id='rId1' w:anchor='x'", "c")}<w:r><w:t xml:space='preserve'> or </w:t></w:r>${link("w:anchor='terms'", "d")}</w:p>"
	runs = [run_line("See ", ""), run_line("ab", "https://example.org/"), run_line("c", "https://example.org/#x"), run_line(" or ", ""), run_line("d", "#terms")]
	snapshot_of(paragraph, no_notes).map_ok(|json| json.contains(block_line("paragraph", "See abc or d", Str.join_with(runs, ", ")))) == Ok(Bool.True)
}

## The result of a `HYPERLINK` field, and of a field nested in it, has the
## field's target as its link, across runs; a simple `HYPERLINK` field's
## content does too, and other fields' results do not.
expect {
	run = |content| "<w:r>${content}</w:r>"
	mark = |kind| run("<w:fldChar w:fldCharType='${kind}'/>")
	code = |text| run("<w:instrText xml:space='preserve'>${text}</w:instrText>")
	text = |value| run("<w:t xml:space='preserve'>${value}</w:t>")
	link = "${mark("begin")}${code(" HYPERLINK \\l \"_Toc1\" ")}${mark("separate")}${text("Scope ")}${mark("begin")}${code(" PAGEREF _Toc1 ")}${mark("separate")}${text("2")}${mark("end")}${mark("end")}"
	page = "${mark("begin")}${code(" PAGE ")}${mark("separate")}${text("5")}${mark("end")}"
	simple = "<w:fldSimple w:instr='HYPERLINK \"https://example.org/\"'>${text("site")}</w:fldSimple>"
	runs = [run_line("Scope 2", "#_Toc1"), run_line(" p5 ", ""), run_line("site", "https://example.org/")]
	snapshot_of("<w:p>${link}${text(" p")}${page}${text(" ")}${simple}</w:p>", no_notes).map_ok(|json| json.contains(block_line("paragraph", "Scope 2 p5 site", Str.join_with(runs, ", ")))) == Ok(Bool.True)
}

## Notes are listed in the order of their references, each with its kind and
## its paragraphs' text; a separator, an unreferenced note, a missing note
## and an empty paragraph are not.
expect {
	note = |kind, id, paragraphs| "<w:${kind} w:id='${id}'>${Str.join_with(paragraphs.map(|text| "<w:p><w:r><w:${kind}Ref/><w:t>${text}</w:t></w:r></w:p>"), "<w:p/>")}</w:${kind}>"
	footnotes = "<w:footnote w:type='separator' w:id='-1'><w:p><w:r><w:separator/></w:r></w:p></w:footnote>${note("footnote", "1", ["First", "line"])}${note("footnote", "2", ["Second"])}${note("footnote", "3", ["Unused"])}"
	endnotes = note("endnote", "1", ["End"])
	reference = |kind, id| "<w:r><w:${kind}Reference w:id='${id}'/></w:r>"
	body = "<w:p><w:r><w:t>a</w:t></w:r>${reference("endnote", "1")}${reference("footnote", "2")}${reference("footnote", "9")}</w:p><w:p>${reference("footnote", "1")}</w:p>"
	expected = "  \"notes\": [\n    {\"kind\": \"endnote\", \"text\": \"End\"},\n    {\"kind\": \"footnote\", \"text\": \"Second\"},\n    {\"kind\": \"footnote\", \"text\": \"First\\nline\"}\n  ],"
	snapshot_of(body, { footnotes, endnotes }).map_ok(|json| json.contains(expected)) == Ok(Bool.True)
}

## Moved-away text is not current text; a paragraph whose mark is deleted is
## one block with the next paragraph, through a content control, but a table
## ends it, and a joined paragraph with no text still anchors its revision.
expect {
	moved = "<w:p><w:r><w:t>a</w:t></w:r><w:moveFrom><w:r><w:t>b</w:t></w:r></w:moveFrom><w:moveTo><w:r><w:t>c</w:t></w:r></w:moveTo></w:p>"
	deleted_mark = |text| "<w:p><w:pPr><w:rPr><w:del w:id='1'/></w:rPr></w:pPr><w:r><w:t>${text}</w:t></w:r></w:p>"
	control = "<w:sdt><w:sdtContent><w:p><w:r><w:t>e</w:t></w:r></w:p></w:sdtContent></w:sdt>"
	table = "<w:tbl><w:tr><w:tc><w:p/></w:tc></w:tr></w:tbl>"
	body = "${moved}${deleted_mark("d")}${control}${deleted_mark("f")}${table}${deleted_mark("")}<w:p/>"
	paragraph = |text| block_json({ kind: "paragraph", level: 0, text, runs: if (text == "") [] else [{ text, formatting: formatting(Document.no_run_properties), link: "" }], rows: [] })
	expected = [paragraph("ac"), paragraph("de"), paragraph("f"), block_json({ kind: "table", level: 0, text: "", runs: [], rows: [[""]] }), paragraph("")]
	snapshot_of(body, no_notes).map_ok(|json| json.contains("\"blocks\": [\n    ${Str.join_with(expected, ",\n    ")}\n  ],")) == Ok(Bool.True)
}

## JSON strings escape quotes, backslashes and control characters and keep
## other characters as they are.
expect quoted("a\"b\\c\nd\te\r\u(1)é") == "\"a\\\"b\\\\c\\nd\\te\\r\\u0001é\""

## Sections give their page geometry in twips and their default header's
## text, a section without a header having the previous section's; content
## after the last section's end is a section that states nothing.
expect {
	ended = |properties| "<w:p><w:pPr><w:sectPr>${properties}</w:sectPr></w:pPr></w:p>"
	first = ended("<w:headerReference w:type='default' r:id='rId4'/><w:pgSz w:w='11906' w:h='16838'/><w:pgMar w:top='720' w:right='1440' w:bottom='-720' w:left='1800' w:header='0' w:footer='0' w:gutter='0'/>")
	second = ended("<w:pgSz w:w='16838' w:h='11906' w:orient='landscape'/>")
	section = |geometry| "{${geometry}, \"header\": \"Draft\", \"footer\": \"\"}"
	sections = [
		section("\"page_width\": 11906, \"page_height\": 16838, \"orientation\": \"portrait\", \"margin_top\": 720, \"margin_bottom\": -720, \"margin_left\": 1800, \"margin_right\": 1440"),
		section("\"page_width\": 16838, \"page_height\": 11906, \"orientation\": \"landscape\", \"margin_top\": 1440, \"margin_bottom\": 1440, \"margin_left\": 1440, \"margin_right\": 1440"),
		section("\"page_width\": 12240, \"page_height\": 15840, \"orientation\": \"portrait\", \"margin_top\": 1440, \"margin_bottom\": 1440, \"margin_left\": 1440, \"margin_right\": 1440"),
	]
	snapshot_of("${first}${second}<w:p><w:r><w:t>after</w:t></w:r></w:p>", no_notes).map_ok(|json| json.contains("  \"sections\": [\n    ${Str.join_with(sections, ",\n    ")}\n  ],")) == Ok(Bool.True)
}
