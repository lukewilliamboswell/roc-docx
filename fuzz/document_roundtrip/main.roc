app [target] {
	docx: "../../package/main.roc",
	fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.1/GDoZFRDnzMRiVk9nE8wdWn52btGsM1GhcY9VDKqy9f1Y.tar.zst",
}

import fuzz.Fuzz
import docx.Docx
import docx.Document
import docx.Opc
import docx.WmlWrite
import docx.XmlTree

## A generated document writes and parses to an equivalent document, and
## writes to identical bytes twice.
##
## A program of bytes describes a body: paragraphs with every modelled
## paragraph property, runs with every modelled run property and kind of run
## content, hyperlinks of each kind of target, bookmarks whose ends may come
## before their starts, simple and complex fields, tracked insertions holding
## runs, kept comment ranges whose identifiers bookmarks must avoid, nested
## tables with row and cell properties, sections in a paragraph's
## properties, in a cell and at the body's end, with headers and footers
## for every page, even pages and a first page, and tracked changes of
## paragraph marks, of paragraph, run, table, row, cell and section
## properties and of rows and cells. The body is written by
## `WmlWrite.document` into a package, with an empty part for each header
## and footer it names, which `Docx.parse` must read back as
## exactly the blocks written; `Docx.to_bytes` must then give the same bytes
## twice, and bytes that read back as an equivalent document that writes the
## same bytes again. Written a part at a time by `Docx.to_chunks` and
## `Docx.next_chunk`, at the compression the program's first byte chooses,
## its chunks concatenated are the bytes of `Docx.to_bytes_with` with the
## same options, which with the default options are those of `to_bytes`.
##
## Allocation ratchets, which only ever move down: writing allocates at most
## linearly in the written tree's nodes and attributes and keeps at most
## linearly many bytes live, and each declared example allocates no more than it did when its
## ceiling was set. The large declared body, sixteen times the small one,
## allocates, requests and holds live at most sixteen times what the small
## one does in the same run. Raising a ceiling needs a cause recorded in the pull
## request.
test! : List(U8) => Fuzz.Outcome
test! = |program| {
	cost = round_trip!(program)
	match exact_ceiling(program) {
		Ok(ceiling) =>
			if cost.allocations > ceiling {
				crash "a declared body allocated more than its ceiling"
			}

		Err(NotDeclared) => {}
	}
	if program == large_program {
		small = round_trip!(small_program)
		if cost.allocations > 16 * small.allocations or cost.requested_bytes > 16 * small.requested_bytes or cost.held_bytes > 16 * small.held_bytes {
			crash "the large body cost more than sixteen times the small one"
		}
	}
	Fuzz.keep
}

generator : Fuzz.Generator(List(U8))
generator = Fuzz.bytes

# Write a program's body, measuring the writing, and check the round trip.
# Returns the allocations and reallocations writing made, the bytes it
# requested and the most it held live beyond entry.
round_trip! : List(U8) => { allocations : U64, requested_bytes : U64, held_bytes : U64 }
round_trip! = |program| {
	content = body(program)
	{ value: result, stats } = Fuzz.measure!("wml-write-document", || WmlWrite.document(shell, content, context))
	written = result ?? crash "a generated body did not write"
	check_linear(stats, size(written.tree))
	main = XmlTree.render(written.tree) ?? crash "a written body did not render"
	regions = written.relationships.keep_if(|relationship| relationship.kind == header_relationship or relationship.kind == footer_relationship)
	graph = {
		relationships: [{ id: "rId1", kind: Opc.officedocument_relationship, target: "/word/document.xml", mode: Internal }],
		parts: List.concat(
			[{ name: "/word/document.xml", content_type: main_type, relationships: written.relationships }],
			regions.map(|relationship| { name: relationship.target, content_type: if (relationship.kind == header_relationship) header_type else footer_type, relationships: [] }),
		),
	}
	bytes = Opc.to_bytes(graph, |name| if (name == "/word/document.xml") Bytes(main) else Bytes(empty_region(name))) ?? crash "a written body did not package"
	parsed = Docx.parse(bytes) ?? crash "a written document did not parse"
	if Docx.body(parsed.document) != content {
		crash "a written body read back differently"
	}
	first = Docx.to_bytes(parsed.document) ?? crash "a read document did not write"
	if Docx.to_bytes(parsed.document) != Ok(first) {
		crash "writing a document twice gave different bytes"
	}
	again = Docx.parse(first) ?? crash "a rewritten document did not parse"
	if !Docx.equivalent(parsed.document, again.document) {
		crash "a rewritten document is not equivalent to the one written"
	}
	if Docx.to_bytes(again.document) != Ok(first) {
		crash "writing a rewritten document gave different bytes"
	}
	check_chunks!(program, parsed.document, first, size(written.tree))
	{ allocations: stats.allocs + stats.reallocs, requested_bytes: stats.requested_bytes, held_bytes: stats.peak_live_bytes - stats.entry_live_bytes }
}

# A document's chunks, streamed and measured, are the bytes written whole
# with the same options, and with the default options the bytes of
# `to_bytes`. Streaming allocates and holds at most linearly in the main
# document tree's nodes and attributes.
check_chunks! : List(U8), Document, List(U8), U64 => {}
check_chunks! = |program, document, written, nodes| {
	options : Docx.WriteOptions
	options = { compression: pick([Fastest, Balanced, Smallest], program.first().map_ok(|byte| byte.to_u64()) ?? 0, Balanced) }
	whole = Docx.to_bytes_with(document, options) ?? crash "a read document did not write with options"
	{ value: streamed, stats } = Fuzz.measure!("docx-to-chunks", || streamed_length(document, options))
	if streamed != Ok(whole.len()) or concatenated(document, options) != Ok(whole) {
		crash "the chunks are not the bytes of to_bytes_with"
	}
	if Docx.to_bytes_with(document, {}) != Ok(written) or concatenated(document, {}) != Ok(written) {
		crash "the default options do not write the bytes of to_bytes"
	}
	if stats.allocs + stats.reallocs > chunk_allocation_ceiling(program, nodes) {
		crash "writing in chunks allocated more than its ceiling"
	}
	if stats.peak_live_bytes - stats.entry_live_bytes > chunk_memory_ceiling(nodes) {
		crash "writing in chunks held more than linearly many bytes live"
	}
	{}
}

# The length of a document written in chunks, each dropped once counted, as a
# caller streaming to a file would.
streamed_length : Document, Docx.WriteOptions -> Try(U64, Docx.WriteError)
streamed_length = |document, options| {
	var $next = Docx.next_chunk(Docx.to_chunks(document, options)?)
	var $length = 0.U64
	var $writing = Bool.True
	while $writing {
		match $next {
			Emit(chunk, rest) => {
				$length = $length + chunk.len()
				$next = Docx.next_chunk(rest)
			}

			Done => {
				$writing = Bool.False
			}
		}
	}
	Ok($length)
}

# A document's chunks, concatenated.
concatenated : Document, Docx.WriteOptions -> Try(List(U8), Docx.WriteError)
concatenated = |document, options| {
	var $next = Docx.next_chunk(Docx.to_chunks(document, options)?)
	var $out = List.with_capacity(4096)
	var $writing = Bool.True
	while $writing {
		match $next {
			Emit(chunk, rest) => {
				$out = List.concat($out, chunk)
				$next = Docx.next_chunk(rest)
			}

			Done => {
				$writing = Bool.False
			}
		}
	}
	Ok($out)
}

# Exact chunk-writing ceilings measured on nightly-2026-11-10-f7d1f19
# with roc-fuzz 0.6.0. The declared bodies have 711 and 11,331 nodes.
# Other generated bodies use the linear bound below; the memory bound
# covers the document, current part, current chunk and compressor state.
chunk_allocation_ceiling : List(U8), U64 -> U64
chunk_allocation_ceiling = |program, nodes|
	if program == small_program {
		7_494
	} else if program == large_program {
		107_932
	} else {
		2_048 + 32 * nodes
	}

chunk_memory_ceiling : U64 -> U64
# Smallest uses the DEFLATE level-12 tables, whose fixed state alone is
# 512 KiB. Allow another 64 KiB for the fixed document parts and archive
# metadata, including when the generated main body is empty.
chunk_memory_ceiling = |nodes| 589_824 + 2_560 * nodes

# Writing allocates at most linearly in the written tree's nodes and
# attributes, and the bytes it holds live beyond the body grow at most
# linearly.
check_linear : Fuzz.Stats, U64 -> {}
check_linear = |stats, nodes| {
	if stats.allocs + stats.reallocs > linear_allocation_ceiling(nodes) {
		crash "writing allocated more than linearly in the written tree's nodes"
	}
	if stats.peak_live_bytes - stats.entry_live_bytes > linear_memory_ceiling(nodes) {
		crash "writing held more than linearly many bytes live"
	}
	{}
}

# The nodes and attributes of a tree.
size : XmlTree.Node -> U64
size = |tree|
	match tree {
		Text(_) => 1
		Element(element) => element.children.fold(1 + element.attributes.len(), |total, child| total + size(child))
	}

# Measured on nightly-2026-11-07: the declared bodies, of 711 and 11,331
# nodes, take 1.4 allocations and 160 bytes live per node, and 20 seconds of
# generated bodies at most 3.7 and 370.
linear_allocation_ceiling : U64 -> U64
linear_allocation_ceiling = |nodes| 64 + 4 * nodes

linear_memory_ceiling : U64 -> U64
linear_memory_ceiling = |nodes| 16_384 + 512 * nodes

# Exact ceilings: the allocations and reallocations of writing each declared
# body, measured on nightly-2026-11-10-f7d1f19 with roc-fuzz 0.6.0.
exact_ceiling : List(U8) -> Try(U64, [NotDeclared])
exact_ceiling = |program|
	if program == small_program {
		Ok(967)
	} else if program == large_program {
		Ok(15_191)
	} else {
		Err(NotDeclared)
	}

# The small and large declared bodies repeat one program, the large one
# sixteen times as often. Writing them takes 965 and 15,189 allocations
# and requests 222,632 and 3,536,976 bytes and holds 114,708 and 1,815,348
# live, ratios of 15.7, 15.9 and 15.8 against the sixteen the test allows:
# writing is linear with a small constant.
small_program : List(U8)
small_program = List.join(List.repeat(program_unit, 4))

large_program : List(U8)
large_program = List.join(List.repeat(program_unit, 64))

# A paragraph with properties, a run of text and formatting, a hyperlink, a
# bookmark around a field, an insertion and a comment range; a table; a
# section after the paragraph; then a new paragraph.
program_unit : List(U8)
program_unit = [8, 17, 2, 3, 4, 20, 5, 6, 7, 21, 11, 12, 9, 10, 0]

main_type : Str
main_type = "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"

wordprocessingml : Str
wordprocessingml = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

header_relationship : Str
header_relationship = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/header"

footer_relationship : Str
footer_relationship = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer"

header_type : Str
header_type = "application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"

footer_type : Str
footer_type = "application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"

# A header or footer part of one empty paragraph, a footer where its name
# says so.
empty_region : Str -> List(U8)
empty_region = |name| {
	root = if (name.contains("footer")) "ftr" else "hdr"
	"<w:${root} xmlns:w=\"${wordprocessingml}\"><w:p/></w:${root}>".to_utf8()
}

context : WmlWrite.Context
context = { relationships: [], footnotes: [], endnotes: [], comments: [] }

shell : XmlTree.Node
shell = Element({ name: w("document"), bindings: [], attributes: [], children: [] })

w : Str -> XmlTree.Name
w = |local| { namespace: Uri(wordprocessingml), local, prefix: Prefix("w") }

# An element as reading gives it back: WordprocessingML names, no
# declarations of its own.
node : Str, List((Str, Str)), List(XmlTree.Node) -> XmlTree.Node
node = |local, attributes, children| Element({ name: w(local), bindings: [], attributes: attributes.map(|(name, value)| { name: w(name), value }), children })

run : Document.RunProperties, List(Document.RunContent) -> Document.Inline
run = |properties, content| Run({ properties, content })

plain : List(Document.RunContent) -> Document.Inline
plain = |content| run(Document.no_run_properties, content)

pick : List(a), U64, a -> a
pick = |choices, index, fallback| choices.get(index % choices.len()) ?? fallback

# A body a program describes, one step a byte: the low four bits choose the
# step and the rest its variant. Paragraph content collects until step 0
# ends the paragraph; a body always ends with a paragraph. A bookmark ends
# only where one of its name has begun, as reading keeps the end of a
# bookmark that never begins as it was read.
Building : { blocks : List(Document.Block), properties : Document.ParagraphProperties, content : List(Document.Inline), started : List(Str) }

body : List(U8) -> List(Document.Block)
body = |program| {
	var $state = { blocks: List.with_capacity(program.len()), properties: Document.no_paragraph_properties, content: List.with_capacity(8), started: List.with_capacity(3) }
	var $position = 0.U64
	for byte in program {
		variant = (byte // 16).to_u64()
		$state = step($state, byte % 16, variant, $position)
		$position = $position + 1
	}
	end_paragraph($state).blocks
}

end_paragraph : Building -> Building
end_paragraph = |state| {
	finished : Document.Block
	finished = Paragraph({ properties: state.properties, content: state.content })
	{ ..state, blocks: List.append(state.blocks, finished), properties: Document.no_paragraph_properties, content: List.with_capacity(8) }
}

with_inline : Building, Document.Inline -> Building
with_inline = |state, item| { ..state, content: List.append(state.content, item) }

with_block : Building, Document.Block -> Building
with_block = |state, block| {
	ended = end_paragraph(state)
	{ ..ended, blocks: List.append(ended.blocks, block) }
}

step : Building, U8, U64, U64 -> Building
step = |state, kind, variant, position|
	match kind {
		0 => end_paragraph(state)
		1 => with_inline(state, plain([Text(pick(["plain", " leading", "trailing ", "in\tside", "", "a & b < c", "line\nend"], variant, ""))]))
		2 => with_inline(state, run(run_properties(variant, []), [Text("formatted")]))
		3 => with_inline(state, plain(pick([[Tab], [Break({ kind: Line, clear: NoClear })], [Break({ kind: Page, clear: NoClear })], [Break({ kind: Column, clear: All })], [Symbol({ font: "Wingdings", code: 0xF0E0 })], [Symbol({ font: "", code: 0x41 })], [SoftHyphen, NonBreakingHyphen]], variant, [Tab])))
		4 => {
			target = pick([External("https://example.org/${variant.to_str()}"), ExternalAt({ url: "https://example.org/a", location: "part" }), Internal("mark${(variant % 3).to_str()}")], variant, Internal("x"))
			with_inline(state, Hyperlink({ target, preserved: [], content: [plain([Text("link")])] }))
		}

		5 => {
			name = "mark${(variant % 3).to_str()}"
			with_inline({ ..state, started: List.append(state.started, name) }, BookmarkStart(name))
		}

		6 => {
			name = "mark${(variant % 3).to_str()}"
			if (state.started.contains(name)) with_inline(state, BookmarkEnd(name)) else state
		}
		7 => {
			mark = |which, name| FieldMark({ kind: which, element: node("fldChar", [("fldCharType", name)], []) })
			if variant % 2 == 0 {
				with_inline(state, SimpleField({ code: " PAGE ", preserved: [], content: [plain([Text("1")])] }))
			} else {
				with_inline(state, plain([mark(Begin, "begin"), FieldCode(" NUMPAGES "), mark(Separate, "separate"), Text("2"), mark(End, "end")]))
			}
		}

		8 => { ..state, properties: paragraph_properties(variant, []) }
		9 => with_block(state, Table(table(variant, position)))
		10 => with_block(end_paragraph(state), Section(section(variant)))
		11 => with_inline(state, Revision({ kind: Insertion, author: "Ada", date: Unset, content: [plain([Text("added")])], preserved: [] }))
		12 => with_inline(state, Preserved(node("commentRangeStart", [("id", (variant % 4).to_str())], [])))
		13 => { ..state, properties: { ..paragraph_properties(variant, [{ author: "Lin", date: Unset, preserved: [], previous: paragraph_properties(variant + 1, Unset) }]), mark: mark(variant) } }
		14 => with_inline(state, run(run_properties(variant, [{ author: "Grace", date: Date(stamp), preserved: [], previous: run_properties(variant + 1, Unset) }]), [Text("reformatted")]))
		_ => with_block(state, Table(tracked_table(variant)))
	}

run_properties : U64, change -> Document.RunPropertiesOf(change)
run_properties = |variant, change| {
	on = if (variant % 2 == 0) On else Off
	base = Document.run_properties_with(change)
	match variant % 6 {
		0 => { ..base, bold: on, italic: On, size: HalfPoints(24) }
		1 => { ..base, style: Style("Emphasis"), underline: Underline(Double), vertical_align: Superscript }
		2 => { ..base, color: Color({ value: Rgb("1F3864"), theme: Theme("accent1"), tint: Unset, shade: Shade("BF") }), highlight: Highlight(Yellow) }
		3 => { ..base, fonts: { ..base.fonts, ascii: Named("Aptos"), high_ansi: Named("Aptos"), east_asia_theme: Theme(MinorEastAsia) }, language: { latin: Tag("en-AU"), east_asia: Unset, complex: Tag("ar-SA") } }
		4 => { ..base, caps: on, small_caps: Off, strike: On, double_strike: Off, hidden: on }
		_ => { ..base, color: Color({ value: Auto, theme: Unset, tint: Unset, shade: Unset }), underline: Underline(NoUnderline) }
	}
}

paragraph_properties : U64, change -> Document.ParagraphPropertiesOf(change)
paragraph_properties = |variant, change| {
	base = Document.paragraph_properties_with(change)
	border = |edge| { edge, line: "single", size: Eighths(4), space: Points(1), color: Rgb("FF0000") }
	match variant % 5 {
		0 => { ..base, style: Style("Heading1"), keep_next: On, keep_lines: Off, outline_level: Level(0) }
		1 => { ..base, alignment: Aligned(Center), spacing: { before: Twips(120), after: Unset, line: Exact(300) }, indentation: { left: Twips(720), right: Twips(-10), first_line: Hanging(360) } }
		2 => { ..base, numbering: { instance: Instance(3), level: Level(1) }, tabs: Tabs([{ kind: Right, position: 9000, leader: Dot }, { kind: Clear, position: 720, leader: Unset }]) }
		3 => { ..base, borders: [border(Top), border(Bottom), border(Between)], shading: Shading({ pattern: "clear", color: Auto, fill: Rgb("D9E2F3") }), page_break_before: On, widow_control: Off }
		_ => { ..base, spacing: { before: Unset, after: Twips(0), line: Auto(240) }, indentation: { left: Unset, right: Unset, first_line: FirstLine(200) } }
	}
}

table : U64, U64 -> Document.Table
table = |variant, position| {
	text = |label| Paragraph({ properties: Document.no_paragraph_properties, content: [plain([Text(label)])] })
	cell = |properties, content| Cell({ properties, content })
	plain_cell = { width: Unset, span: Unset, merge: Unset, borders: [], shading: Unset, alignment: Unset, preserved: [], revision: Unset, change: [] }
	inner = Table({ properties: { style: Unset, width: Auto, borders: [], shading: Unset, preserved: [], change: [] }, grid: [Column(1000)], content: [Row({ properties: plain_row([]), content: [cell(plain_cell, [text("inner")])] })] })
	nested = if (variant % 2 == 0) [inner, text("after")] else [text("c${position.to_str()}")]
	first = cell({ ..plain_cell, width: Twips(2000), merge: Restart, alignment: Center, shading: Shading({ pattern: "pct25", color: Unset, fill: Auto }) }, nested)
	second = cell({ ..plain_cell, width: Fiftieths(2500), span: Columns(2), borders: [{ edge: Top, line: "double", size: Unset, space: Unset, color: Unset }, { edge: DiagonalDown, line: "nil", size: Unset, space: Unset, color: Unset }] }, [text("b"), Section(section(variant))])
	below = cell({ ..plain_cell, merge: Continue, width: Nil }, [text("")])
	rows = [
		Row({ properties: { ..plain_row([]), header: On, grid_after: Columns(1) }, content: [first, second] }),
		Row({ properties: { ..plain_row([]), header: Off, grid_before: Columns(1) }, content: [below] }),
	]
	{ properties: { style: Style("Grid"), width: Fiftieths(5000), borders: [{ edge: Top, line: "single", size: Eighths(8), space: Points(0), color: Auto }, { edge: InsideVertical, line: "nil", size: Unset, space: Unset, color: Unset }], shading: Unset, preserved: [], change: [] }, grid: [Column(2000), Column(1000), Column(1500)], content: rows }
}

section : U64 -> Document.Section
section = |variant| section_of(variant, if (variant % 3 == 2) [{ author: "Ada", date: Date(stamp), preserved: [], previous: section_of(0, Unset) }] else [])

# Variants 0 to 2 name no header or footer, so the declared bodies, whose
# sections are variant 0, write none; variant 3 names headers and footers of
# every kind.
section_of : U64, change -> Document.SectionOf(change)
section_of = |variant, change|
	match variant % 4 {
		0 => { start: NextPage, page_size: Size({ width: 11906, height: 16838, orientation: Portrait }), margins: Margins({ top: 1440, right: 1440, bottom: 1440, left: 1800, header: 708, footer: 708, gutter: 0 }), columns: Equal({ count: 1, space: 720, separator: NoLine }), page_numbers: Unset, title_page: Unset, headers: [], footers: [], preserved: [], change }
		1 => { start: Continuous, page_size: Size({ width: 16838, height: 11906, orientation: Landscape }), margins: Margins({ top: -720, right: 720, bottom: 720, left: 720, header: 360, footer: 360, gutter: 100 }), columns: Equal({ count: 2, space: 360, separator: Line }), page_numbers: PageNumbers({ format: Format("lowerRoman"), start: Start(3) }), title_page: On, headers: [], footers: [], preserved: [], change }
		2 => { start: Unset, page_size: Unset, margins: Unset, columns: Unequal({ widths: [{ width: 4000, space: 500 }, { width: 5000, space: 0 }], separator: NoLine }), page_numbers: PageNumbers({ format: Unset, start: Unset }), title_page: Off, headers: [], footers: [], preserved: [], change }
		_ => {
			headers = [{ kind: Default, part: "/word/header1.xml" }, { kind: Even, part: "/word/header2.xml" }, { kind: First, part: "/word/header1.xml" }]
			footers = [{ kind: First, part: "/word/footer1.xml" }, { kind: Even, part: "/word/footer1.xml" }]
			{ start: OddPage, page_size: Unset, margins: Unset, columns: Unset, page_numbers: Unset, title_page: On, headers, footers, preserved: [], change }
		}
	}

plain_row : change -> Document.RowPropertiesOf(change)
plain_row = |change| { header: Unset, grid_before: Unset, grid_after: Unset, preserved: [], inserted: Unset, deleted: Unset, change }

stamp : Document.Timestamp
stamp = { written: "2026-05-07T09:00:00Z", utc_seconds: 1778144400 }

# A paragraph mark's changes: inserted, deleted, both, or moved away or here.
mark : U64 -> List(Document.MarkChange)
mark = |variant| {
	by = |kind| { kind, author: "Ada", date: Date(stamp), preserved: [] }
	match variant % 4 {
		0 => [by(Insertion)]
		1 => [by(Deletion)]
		2 => [by(Insertion), by(Deletion)]
		_ => [by(MoveSource), by(MoveDestination)]
	}
}

# A table whose properties, row and cell changed, its row inserted, deleted
# or both and its cell inserted, deleted, merged or none of these.
tracked_table : U64 -> Document.Table
tracked_table = |variant| {
	by = { author: "Ada", date: Unset, preserved: [] }
	plain_cell = |change| { width: Unset, span: Unset, merge: Unset, borders: [], shading: Unset, alignment: Unset, preserved: [], revision: Unset, change }
	plain_table = |change| { style: Unset, width: Unset, borders: [], shading: Unset, preserved: [], change }
	revision = pick([Inserted(by), Deleted(by), Merged({ author: "Ada", date: Unset, preserved: [], merge: Continue, previous: Restart }), Unset], variant, Unset)
	cell = Cell({ properties: { ..plain_cell([{ author: "Lin", date: Unset, preserved: [], previous: { ..plain_cell(Unset), width: Twips(1000) } }]), revision }, content: [Paragraph({ properties: Document.no_paragraph_properties, content: [plain([Text("tracked")])] })] })
	row_properties = {
		..plain_row([{ author: "Lin", date: Unset, preserved: [], previous: { ..plain_row(Unset), header: On } }]),
		inserted: if (variant % 2 == 0) Tracked(by) else Unset,
		deleted: if (variant % 3 == 0) Tracked(by) else Unset,
	}
	properties = plain_table([{ author: "Lin", date: Date(stamp), preserved: [], previous: { ..plain_table(Unset), style: Style("Grid") } }])
	{ properties, grid: [Column(1000)], content: [Row({ properties: row_properties, content: [cell] })] }
}

target = Fuzz.target_with!({
	name: "document-roundtrip",
	examples: [
		Fuzz.example({ name: "smallest-empty-body", revision: "1", make: || [2] }),
		Fuzz.example({ name: "small-body", revision: "1", make: || small_program }),
		Fuzz.example({ name: "large-body", revision: "1", make: || large_program }),
	],
	generator,
	test!,
	show: |program| Str.inspect(program),
})
