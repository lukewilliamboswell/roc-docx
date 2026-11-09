## The package's reading of a document as a semantic snapshot: the JSON
## document, versioned `roc-docx-snapshot/1`, that the oracle lanes compare
## with LibreOffice's and pandoc's readings of the same document.
##
## The snapshot has the contract's fixed shape, every field present, and
## declares in `keys` only what the package is authoritative for: the
## body's blocks and their text. Every other field holds its empty value.
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
	## or endnote reference, or a revision of its paragraph mark.
	json : Document, { path : Str, version : Str } -> Str
	json = |document, { path, version }| {
		var $blocks = List.with_capacity(64)
		for block in Docx.body(document) {
			$blocks = snapshot_blocks($blocks, block)
		}
		properties = ["title", "subject", "creator", "keywords", "description", "last_modified_by", "created", "modified"].map(|name| "\"${name}\": \"\"")
		Str.join_with(
			[
				"{",
				"  \"schema\": \"roc-docx-snapshot/1\",",
				"  \"producer\": {\"name\": \"roc-docx\", \"version\": ${quoted(version)}},",
				"  \"document\": ${quoted(path)},",
				"  \"keys\": [\"blocks.text\", \"blocks.rows\"],",
				"  \"blocks\": [${if ($blocks.is_empty()) "" else "\n    ${Str.join_with($blocks, ",\n    ")}\n  "}],",
				"  \"notes\": [],",
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

# Append a block's snapshot blocks, each as one JSON object.
snapshot_blocks : List(Str), Document.Block -> List(Str)
snapshot_blocks = |out, block|
	match block {
		Paragraph(paragraph) => {
			text = Document.paragraph_text(paragraph)
			if text != "" or anchors(paragraph) {
				List.append(out, block_json("paragraph", text, []))
			} else {
				out
			}
		}

		Table(table) => List.append(out, block_json("table", "", rows(table)))
		Container({ element: _, content }) => content.fold(out, snapshot_blocks)
		Preserved(_) => out
	}

block_json : Str, Str, List(List(Str)) -> Str
block_json = |kind, text, grid| {
	row_json = |cells| "[${Str.join_with(cells.map(quoted), ", ")}]"
	"{\"kind\": \"${kind}\", \"level\": 0, \"list\": \"\", \"text\": ${quoted(text)}, \"runs\": [], \"rows\": [${Str.join_with(grid.map(row_json), ", ")}]}"
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
						Preserved(node) => is_named(node, ["footnoteReference", "endnoteReference", "commentReference"])
						_ => Bool.False
					},
			)

		Container({ element, content }) => is_named(element, revisions) or content.any(inline_anchors)
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

# The snapshot of a package whose main document has this body content.
snapshot_of : Str -> Try(Str, _)
snapshot_of = |content| {
	main = "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"
	graph = {
		relationships: [{ id: "rId1", kind: Opc.officedocument_relationship, target: "/word/document.xml", mode: Internal }],
		parts: [{ name: "/word/document.xml", content_type: main, relationships: [] }],
	}
	xml = "<w:document xmlns:w='${wordprocessingml}'><w:body>${content}</w:body></w:document>"
	parsed = Docx.parse(Opc.to_bytes(graph, |_| Bytes(xml.to_utf8()))?)?
	Ok(Snapshot.json(parsed.document, { path: "a \"b\".docx", version: "test" }))
}

## Empty paragraphs are blocks only when they anchor something, a table is
## one block with its text grid, and paragraphs in content controls are
## blocks.
expect {
	empty = "<w:p/><w:p><w:r><w:t></w:t></w:r><w:bookmarkStart w:id='1' w:name='b'/></w:p>"
	anchoring = "<w:p><w:del><w:r><w:delText>gone</w:delText></w:r></w:del></w:p><w:p><w:commentRangeStart w:id='1'/></w:p><w:p><w:r><w:footnoteReference w:id='1'/></w:r></w:p><w:p><w:pPr><w:rPr><w:ins w:id='2'/></w:rPr></w:pPr></w:p>"
	table = "<w:tbl><w:tr><w:tc><w:p><w:r><w:t>cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>"
	control = "<w:sdt><w:sdtContent><w:p><w:r><w:t>Say \"hi\"</w:t><w:br/></w:r></w:p></w:sdtContent></w:sdt>"
	block = |kind, text| "    {\"kind\": \"${kind}\", \"level\": 0, \"list\": \"\", \"text\": \"${text}\", \"runs\": [], \"rows\": []}"
	expected = Str.join_with(
		[
			"{",
			"  \"schema\": \"roc-docx-snapshot/1\",",
			"  \"producer\": {\"name\": \"roc-docx\", \"version\": \"test\"},",
			"  \"document\": \"a \\\"b\\\".docx\",",
			"  \"keys\": [\"blocks.text\", \"blocks.rows\"],",
			"  \"blocks\": [",
			"${block("paragraph", "")},\n${block("paragraph", "")},\n${block("paragraph", "")},\n${block("paragraph", "")},",
			"    {\"kind\": \"table\", \"level\": 0, \"list\": \"\", \"text\": \"\", \"runs\": [], \"rows\": [[\"cell\"]]},",
			"${block("paragraph", "Say \\\"hi\\\"\\n")}",
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
	snapshot_of("${empty}${anchoring}${table}${control}<w:sectPr/>") == Ok(expected)
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
	snapshot_of("<w:tbl>${Str.join_with(rows_xml, "")}</w:tbl>").map_ok(|json| json.contains(expected)) == Ok(Bool.True)
}

## A body with no blocks has an empty list of them.
expect snapshot_of("<w:p/>").map_ok(|json| json.contains("\"blocks\": [],")) == Ok(Bool.True)

## JSON strings escape quotes, backslashes and control characters and keep
## other characters as they are.
expect quoted("a\"b\\c\nd\te\r\u(1)é") == "\"a\\\"b\\\\c\\nd\\te\\r\\u0001é\""
