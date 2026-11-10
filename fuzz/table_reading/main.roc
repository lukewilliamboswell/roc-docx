app [target] {
	docx: "../../package/main.roc",
	fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.5.0/9WT86CuwM7ZJBSs8iTd1jLyrUFTTiGp5hcJE63TwswGE.tar.zst",
}

import fuzz.Fuzz
import docx.Document
import docx.WmlRead
import docx.XmlTree

## Reading a body of tables gives back the tables a program wrote: every
## row with the grid columns it skips, every cell with its text, the columns
## it spans and its vertical merge, nested tables in their cells, and cells
## and rows inside content controls in their place. Every width written with
## a fraction is rounded with exactly one diagnostic.
##
## Allocation ratchets, which only ever move down: reading allocates at most
## linearly in the tree's nodes and attributes and keeps at most linearly
## many bytes live, and each declared example allocates no more than it did
## when its ceiling was set. The large declared table, sixteen times the
## small one, allocates, requests and holds live at most sixteen times what
## the small one does in the same run. Raising a ceiling needs a cause recorded in the
## pull request.
test! : List(U8) => Fuzz.Outcome
test! = |program| {
	written = write(program)
	cost = agree!(written)
	match exact_ceiling(program) {
		Ok(ceiling) =>
			if cost.allocations > ceiling {
				crash "a declared table allocated more than its ceiling"
			}

		Err(NotDeclared) => {}
	}
	if program == large_program {
		small = agree!(write(small_program))
		if cost.allocations > 16 * small.allocations or cost.requested_bytes > 16 * small.requested_bytes or cost.held_bytes > 16 * small.held_bytes {
			crash "the large table cost more than sixteen times the small one"
		}
	}
	Fuzz.keep
}

generator : Fuzz.Generator(List(U8))
generator = Fuzz.bytes

# A table as the program wrote it: each row with the grid columns it skips
# and its cells.
Written : { xml : Str, rows : List(WrittenRow), fractions : U64 }

WrittenRow : { before : U64, after : U64, cells : List(WrittenCell) }

WrittenCell : { text : Str, span : U64, merge : [Unset, Restart, Continue], nested : Bool }

# Read a written table, measuring the reading, and check it against what was
# written. Returns the allocations and reallocations reading made, the bytes
# it requested and the most it held live beyond entry.
agree! : Written => { allocations : U64, requested_bytes : U64, held_bytes : U64 }
agree! = |written| {
	tree = XmlTree.parse(written.xml.to_utf8(), {}) ?? crash "a written table is not XML"
	{ value: read, stats } = Fuzz.measure!("wml-read-body", || WmlRead.read_body(tree, { relationships: [], footnotes: [], endnotes: [], comments: [] }))
	check_linear(stats, size(tree))
	table = match read.blocks {
		[Table(only)] => only
		_ => crash "the body is not one table"
	}
	rows = Document.table_rows(table)
	if rows.len() != written.rows.len() {
		crash "the table has a different number of rows"
	}
	for pair in List.map2(rows, written.rows, |row, expected| { row, expected }) {
		if pair.row.properties.grid_before != columns(pair.expected.before) or pair.row.properties.grid_after != columns(pair.expected.after) {
			crash "a row skips different grid columns"
		}
		cells = Document.row_cells(pair.row)
		if cells.len() != pair.expected.cells.len() {
			crash "a row has a different number of cells"
		}
		for cell_pair in List.map2(cells, pair.expected.cells, |cell, expected| { cell, expected }) {
			if !same_cell(cell_pair.cell, cell_pair.expected) {
				crash "a cell reads differently from how it was written"
			}
		}
	}
	if read.diagnostics.len() != written.fractions {
		crash "the widths written with a fraction and the diagnostics differ"
	}
	{ allocations: stats.allocs + stats.reallocs, requested_bytes: stats.requested_bytes, held_bytes: stats.peak_live_bytes - stats.entry_live_bytes }
}

same_cell : Document.Cell, WrittenCell -> Bool
same_cell = |cell, expected| {
	span = if (expected.span == 1) Unset else Columns(expected.span)
	content_agrees = match cell.content {
		[Table(nested), Paragraph(paragraph)] if expected.nested => Document.table_rows(nested).len() == 1 and Document.paragraph_text(paragraph) == expected.text
		[Paragraph(paragraph)] if !expected.nested => Document.paragraph_text(paragraph) == expected.text
		_ => Bool.False
	}
	cell.properties.span == span and cell.properties.merge == expected.merge and content_agrees
}

columns : U64 -> [Unset, Columns(U64)]
columns = |count| if (count == 0) Unset else Columns(count)

# Reading allocates at most linearly in the tree's nodes and attributes,
# and the bytes it holds live beyond the tree grow at most linearly.
check_linear : Fuzz.Stats, U64 -> {}
check_linear = |stats, nodes| {
	if stats.allocs + stats.reallocs > linear_allocation_ceiling(nodes) {
		crash "reading allocated more than linearly in the tree's nodes"
	}
	if stats.peak_live_bytes - stats.entry_live_bytes > linear_memory_ceiling(nodes) {
		crash "reading held more than linearly many bytes live"
	}
	{}
}

# Measured on nightly-2026-11-07: the declared tables, of 261 and 4,041
# nodes, took 3.4 allocations and 350 bytes live per node while
# compatibility processing came first; 2.7 and 235 without it.
linear_allocation_ceiling : U64 -> U64
linear_allocation_ceiling = |nodes| 64 + 4 * nodes

linear_memory_ceiling : U64 -> U64
linear_memory_ceiling = |nodes| 16_384 + 512 * nodes

# The nodes and attributes of a tree.
size : XmlTree.Node -> U64
size = |node|
	match node {
		Text(_) => 1
		Element(element) => element.children.fold(1 + element.attributes.len(), |total, child| total + size(child))
	}

# Exact ceilings: the allocations and reallocations of reading each declared
# table, as measured on nightly-2026-11-07 when the ceiling was set.
exact_ceiling : List(U8) -> Try(U64, [NotDeclared])
exact_ceiling = |program|
	if program == small_program {
		Ok(705)
	} else if program == large_program {
		Ok(10_969)
	} else {
		Err(NotDeclared)
	}

# The small and large declared tables repeat one program, the large one
# sixteen times as often. Reading them takes 705 and 10,969 allocations and
# requests 95,520 and 1,494,484 bytes and holds 60,590 and 947,810 live,
# ratios of 15.6, 15.6 and 15.6 against the
# sixteen the test allows. Reading the part as written, without markup
# compatibility processing first, lowered them from 880 and 13,551.
small_program : List(U8)
small_program = List.join(List.repeat(program_unit, 4))

large_program : List(U8)
large_program = List.join(List.repeat(program_unit, 64))

# A row that skips a grid column before its cells, then a plain cell, a
# spanning cell, a cell starting a merge, a nested table, a cell in a content
# control and one with a fractional width; a new row with a cell continuing
# the merge.
program_unit : List(U8)
program_unit = [8 + 6, 1, 8 + 2, 3, 5, 7, 8 + 7, 0, 4]

wordprocessingml : Str
wordprocessingml = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

# The table a program describes, one step a byte: the low three bits choose
# the step and the rest its variant. A row is closed and a new one started
# by step 0, and the table has at least one row.
write : List(U8) -> Written
write = |program| {
	var $rows = List.with_capacity(program.len())
	var $row = { before: 0, after: 0, cells: List.with_capacity(8) }
	var $row_xml = List.with_capacity(8)
	var $xml = List.with_capacity(program.len())
	var $fractions = 0.U64
	for byte in program {
		variant = (byte // 8).to_u64()
		text = "c${List.len($row.cells).to_str()}"
		step = match byte % 8 {
			0 => Row
			1 => Cell({ properties: "", content: paragraph(text), cell: { text, span: 1, merge: Unset, nested: Bool.False } })
			2 => Cell({ properties: "<w:gridSpan w:val='${(2 + variant % 3).to_str()}'/>", content: paragraph(text), cell: { text, span: 2 + variant % 3, merge: Unset, nested: Bool.False } })
			3 => Cell({ properties: "<w:vMerge w:val='restart'/>", content: paragraph(text), cell: { text, span: 1, merge: Restart, nested: Bool.False } })
			4 => Cell({ properties: if (variant % 2 == 0) "<w:vMerge/>" else "<w:vMerge w:val='continue'/>", content: paragraph(text), cell: { text, span: 1, merge: Continue, nested: Bool.False } })
			5 => Cell({ properties: "", content: "<w:tbl><w:tr><w:tc>${paragraph("inner")}</w:tc></w:tr></w:tbl>${paragraph(text)}", cell: { text, span: 1, merge: Unset, nested: Bool.True } })
			6 => Skip(variant % 3, (variant // 3) % 3)
			_ =>
				if variant % 2 == 0 {
					Controlled(paragraph(text), { text, span: 1, merge: Unset, nested: Bool.False })
				} else {
					Fraction(paragraph(text), { text, span: 1, merge: Unset, nested: Bool.False })
				}
		}
		match step {
			Row => {
				$rows = List.append($rows, $row)
				$xml = List.append($xml, row_xml($row, $row_xml))
				$row = { before: 0, after: 0, cells: List.with_capacity(8) }
				$row_xml = List.with_capacity(8)
			}

			Cell({ properties, content, cell }) => {
				$row = { ..$row, cells: List.append($row.cells, cell) }
				$row_xml = List.append($row_xml, "<w:tc><w:tcPr>${properties}</w:tcPr>${content}</w:tc>")
			}

			Skip(before, after) => {
				$row = { ..$row, before: before, after: after }
			}

			Controlled(content, cell) => {
				$row = { ..$row, cells: List.append($row.cells, cell) }
				$row_xml = List.append($row_xml, "<w:sdt><w:sdtPr/><w:sdtContent><w:tc>${content}</w:tc></w:sdtContent></w:sdt>")
			}

			Fraction(content, cell) => {
				$fractions = $fractions + 1
				$row = { ..$row, cells: List.append($row.cells, cell) }
				$row_xml = List.append($row_xml, "<w:tc><w:tcPr><w:tcW w:w='1000.5' w:type='dxa'/></w:tcPr>${content}</w:tc>")
			}
		}
	}
	rows = List.append($rows, $row)
	xml = List.append($xml, row_xml($row, $row_xml))
	grid = "<w:tblGrid><w:gridCol w:w='1000'/></w:tblGrid>"
	{ xml: "<w:document xmlns:w='${wordprocessingml}'><w:body><w:tbl><w:tblPr/>${grid}${Str.join_with(xml, "")}</w:tbl></w:body></w:document>", rows, fractions: $fractions }
}

row_xml : WrittenRow, List(Str) -> Str
row_xml = |row, cells| {
	skipped = |name, count| if (count == 0) "" else "<w:${name} w:val='${count.to_str()}'/>"
	"<w:tr><w:trPr>${skipped("gridBefore", row.before)}${skipped("gridAfter", row.after)}</w:trPr>${Str.join_with(cells, "")}</w:tr>"
}

paragraph : Str -> Str
paragraph = |text| "<w:p><w:r><w:t>${text}</w:t></w:r></w:p>"

target = Fuzz.target_with!({
	name: "table-reading",
	examples: [
		Fuzz.example({ name: "small-table", revision: "1", make: || small_program }),
		Fuzz.example({ name: "large-table", revision: "1", make: || large_program }),
	],
	generator,
	test!,
	show: |program| Str.inspect(program),
})
