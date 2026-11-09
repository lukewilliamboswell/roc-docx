## The package's reading of a document as a semantic snapshot: the JSON
## document, versioned `roc-docx-snapshot/1`, that the oracle lanes compare
## with LibreOffice's and pandoc's readings of the same document.
##
## The snapshot has the contract's fixed shape, every field present, and
## declares in `keys` only what the package is authoritative for: the
## body's blocks, their text and their runs' hyperlinks, and the notes' kinds
## and text. Every other field holds its empty value.
import Docx
import Document
import Opc
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
	## [Document.field_target] reads.
	##
	## The notes are the footnotes and endnotes the body refers to, in the
	## order of their references, each with its blocks' text joined by line
	## feeds.
	json : Document, { path : Str, version : Str } -> Str
	json = |document, { path, version }| {
		body = Docx.body(document)
		blocks = snapshot_of_blocks(body).map(block_json)
		footnotes = Docx.footnotes(document)
		endnotes = Docx.endnotes(document)
		notes = body.fold(List.with_capacity(8), note_references).keep_oks(
			|reference| {
				(kind, list) = match reference.kind {
					Footnote => ("footnote", footnotes)
					Endnote => ("endnote", endnotes)
				}
				note = list.get(reference.note) ? |_| Missing
				text = Str.join_with(snapshot_of_blocks(note.content).map(|block| block.text), "\n")
				Ok("{\"kind\": \"${kind}\", \"text\": ${quoted(text)}}")
			},
		)
		properties = ["title", "subject", "creator", "keywords", "description", "last_modified_by", "created", "modified"].map(|name| "\"${name}\": \"\"")
		Str.join_with(
			[
				"{",
				"  \"schema\": \"roc-docx-snapshot/1\",",
				"  \"producer\": {\"name\": \"roc-docx\", \"version\": ${quoted(version)}},",
				"  \"document\": ${quoted(path)},",
				"  \"keys\": [\"blocks.text\", \"blocks.rows\", \"blocks.runs.link\", \"notes.kind\", \"notes.text\"],",
				"  \"blocks\": [${list_json(blocks)}],",
				"  \"notes\": [${list_json(notes)}],",
				"  \"comments\": [],",
				"  \"revisions\": [],",
				"  \"sections\": [],",
				"  \"properties\": {${Str.join_with(properties, ", ")}}",
				"}",
				"",
			],
			"\n",
		)
	}
}

wordprocessingml : Str
wordprocessingml = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

# A block of the snapshot, and a run of its text with its hyperlink's target.
SnapshotBlock : { kind : Str, text : Str, runs : List(SnapshotRun), rows : List(List(Str)) }

SnapshotRun : { text : Str, link : Str }

# The snapshot blocks so far; the paragraphs whose marks are deleted, joined,
# waiting for the paragraph they run on into; and the complex fields open
# where they end, innermost last, with their code so far and whether their
# result has begun: a field's result can span paragraphs.
Blocks : { blocks : List(SnapshotBlock), joined : Try(Joined, [NoParagraph]), fields : List(OpenField) }

Joined : { text : Str, anchored : Bool, runs : List(SnapshotRun) }

OpenField : { code : Str, in_result : Bool }

# Runs so far, and the complex fields open where they end.
Runs : { runs : List(SnapshotRun), fields : List(OpenField) }

# The snapshot blocks of blocks.
snapshot_of_blocks : List(Document.Block) -> List(SnapshotBlock)
snapshot_of_blocks = |blocks| flush(blocks.fold({ blocks: List.with_capacity(64), joined: Err(NoParagraph), fields: [] }, snapshot_blocks)).blocks

# Append a block's snapshot blocks.
snapshot_blocks : Blocks, Document.Block -> Blocks
snapshot_blocks = |state, block|
	match block {
		Paragraph(paragraph) => {
			before = state.joined ?? { text: "", anchored: Bool.False, runs: [] }
			read = paragraph.content.fold({ runs: before.runs, fields: state.fields }, |runs, inline| snapshot_runs(runs, inline, ""))
			joined = { text: Str.concat(before.text, Document.paragraph_text(paragraph)), anchored: before.anchored or anchors(paragraph), runs: read.runs }
			if Document.joins_next(paragraph) {
				{ blocks: state.blocks, joined: Ok(joined), fields: read.fields }
			} else {
				flush({ blocks: state.blocks, joined: Ok(joined), fields: read.fields })
			}
		}

		Table(table) => {
			flushed = flush(state)
			{ blocks: List.append(flushed.blocks, { kind: "table", text: "", runs: [], rows: rows(table) }), joined: Err(NoParagraph), fields: flushed.fields }
		}

		Container({ element: _, content }) => content.fold(state, snapshot_blocks)
		Preserved(_) => state
	}

# Append the joined paragraph, as a block when it has text or anchors something.
flush : Blocks -> Blocks
flush = |state|
	match state.joined {
		Ok({ text, anchored, runs }) if text != "" or anchored => { blocks: List.append(state.blocks, { kind: "paragraph", text, runs, rows: [] }), joined: Err(NoParagraph), fields: state.fields }
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
		_ => with_text(state, Document.inline_text(inline), link)
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
			with_text(state, text, if (link == "") field_link(state.fields) else link)
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

# Text joins the run before when their links are the same.
with_text : Runs, Str, Str -> Runs
with_text = |state, text, link|
	match state.runs.last() {
		_ if text == "" => state
		Ok(previous) if previous.link == link => { runs: List.append(List.drop_last(state.runs, 1), { text: Str.concat(previous.text, text), link }), fields: state.fields }
		_ => { runs: List.append(state.runs, { text, link }), fields: state.fields }
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
	runs = block.runs.map(|run| "{\"text\": ${quoted(run.text)}, \"bold\": false, \"italic\": false, \"underline\": false, \"strike\": false, \"superscript\": false, \"subscript\": false, \"link\": ${quoted(run.link)}}")
	row_json = |cells| "[${Str.join_with(cells.map(quoted), ", ")}]"
	"{\"kind\": \"${block.kind}\", \"level\": 0, \"list\": \"\", \"text\": ${quoted(block.text)}, \"runs\": [${Str.join_with(runs, ", ")}], \"rows\": [${Str.join_with(block.rows.map(row_json), ", ")}]}"
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
# an external hyperlink relationship `rId1`, and these notes in its footnotes
# and endnotes parts.
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
				],
			},
			part("footnotes", "footnotes"),
			part("endnotes", "endnotes"),
		],
	}
	declarations = "xmlns:w='${wordprocessingml}' xmlns:r='${relationships}'"
	xml = |name|
		if name == "/word/footnotes.xml" {
			"<w:footnotes ${declarations}>${notes.footnotes}</w:footnotes>"
		} else if name == "/word/endnotes.xml" {
			"<w:endnotes ${declarations}>${notes.endnotes}</w:endnotes>"
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
## blocks.
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
			"  \"keys\": [\"blocks.text\", \"blocks.rows\", \"blocks.runs.link\", \"notes.kind\", \"notes.text\"],",
			"  \"blocks\": [",
			"${block("paragraph", "")},\n${block("paragraph", "")},\n${block("paragraph", "")},\n${block("paragraph", "")},",
			"    {\"kind\": \"table\", \"level\": 0, \"list\": \"\", \"text\": \"\", \"runs\": [], \"rows\": [[\"cell\"]]},",
			block_line("paragraph", "Say \\\"hi\\\"\\n", run_line("Say \\\"hi\\\"\\n", "")),
			"  ],",
			"  \"notes\": [],",
			"  \"comments\": [],",
			"  \"revisions\": [],",
			"  \"sections\": [],",
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
	paragraph = |text| block_json({ kind: "paragraph", text, runs: if (text == "") [] else [{ text, link: "" }], rows: [] })
	expected = [paragraph("ac"), paragraph("de"), paragraph("f"), block_json({ kind: "table", text: "", runs: [], rows: [[""]] }), paragraph("")]
	snapshot_of(body, no_notes).map_ok(|json| json.contains("\"blocks\": [\n    ${Str.join_with(expected, ",\n    ")}\n  ],")) == Ok(Bool.True)
}

## JSON strings escape quotes, backslashes and control characters and keep
## other characters as they are.
expect quoted("a\"b\\c\nd\te\r\u(1)é") == "\"a\\\"b\\\\c\\nd\\te\\r\\u0001é\""
