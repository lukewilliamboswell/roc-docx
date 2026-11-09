app [target] {
	docx: "../../package/main.roc",
	fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.5.0/9WT86CuwM7ZJBSs8iTd1jLyrUFTTiGp5hcJE63TwswGE.tar.zst",
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
## tables with row and cell properties, and sections in a paragraph's
## properties, in a cell and at the body's end. The body is written by
## `WmlWrite.document` into a package, which `Docx.parse` must read back as
## exactly the blocks written; `Docx.to_bytes` must then give the same bytes
## twice, and bytes that read back as an equivalent document that writes the
## same bytes again.
##
## Allocation ratchets, which only ever move down: writing allocates at most
## linearly in the written tree's nodes and attributes and keeps at most
## linearly many bytes live, and each declared example allocates no more than it did when its
## ceiling was set. The large declared body, sixteen times the small one,
## allocates and requests at most sixteen times what the small one does in
## the same run. Raising a ceiling needs a cause recorded in the pull
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
		if cost.allocations > 16 * small.allocations or cost.requested_bytes > 16 * small.requested_bytes {
			crash "the large body cost more than sixteen times the small one"
		}
	}
	Fuzz.keep
}

generator : Fuzz.Generator(List(U8))
generator = Fuzz.bytes

# Write a program's body, measuring the writing, and check the round trip.
# Returns the allocations and reallocations writing made and the bytes it
# requested.
round_trip! : List(U8) => { allocations : U64, requested_bytes : U64 }
round_trip! = |program| {
	content = body(program)
	{ value: result, stats } = Fuzz.measure!("wml-write-document", || WmlWrite.document(shell, content, context))
	written = result ?? crash "a generated body did not write"
	check_linear(stats, size(written.tree))
	main = XmlTree.render(written.tree) ?? crash "a written body did not render"
	graph = {
		relationships: [{ id: "rId1", kind: Opc.officedocument_relationship, target: "/word/document.xml", mode: Internal }],
		parts: [{ name: "/word/document.xml", content_type: main_type, relationships: written.relationships }],
	}
	bytes = Opc.to_bytes(graph, |_| Bytes(main)) ?? crash "a written body did not package"
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
	{ allocations: stats.allocs + stats.reallocs, requested_bytes: stats.requested_bytes }
}

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
# body, as measured on nightly-2026-11-07 when the ceiling was set.
exact_ceiling : List(U8) -> Try(U64, [NotDeclared])
exact_ceiling = |program|
	if program == small_program {
		Ok(965)
	} else if program == large_program {
		Ok(15_189)
	} else {
		Err(NotDeclared)
	}

# The small and large declared bodies repeat one program, the large one
# sixteen times as often. Writing them takes 965 and 15,189 allocations
# and requests 222,632 and 3,536,976 bytes, ratios of 15.7 and 15.9 against
# the sixteen the test allows: writing is linear with a small constant.
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
		2 => with_inline(state, run(run_properties(variant), [Text("formatted")]))
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

		8 => { ..state, properties: paragraph_properties(variant) }
		9 => with_block(state, Table(table(variant, position)))
		10 => with_block(end_paragraph(state), Section(section(variant)))
		11 => with_inline(state, Revision({ kind: Insertion, author: "Ada", date: Unset, content: [plain([Text("added")])], preserved: [] }))
		12 => with_inline(state, Preserved(node("commentRangeStart", [("id", (variant % 4).to_str())], [])))
		_ => with_inline(state, plain([Text("x")]))
	}

run_properties : U64 -> Document.RunProperties
run_properties = |variant| {
	on = if (variant % 2 == 0) On else Off
	base = Document.no_run_properties
	match variant % 6 {
		0 => { ..base, bold: on, italic: On, size: HalfPoints(24) }
		1 => { ..base, style: Style("Emphasis"), underline: Underline(Double), vertical_align: Superscript }
		2 => { ..base, color: Color({ value: Rgb("1F3864"), theme: Theme("accent1"), tint: Unset, shade: Shade("BF") }), highlight: Highlight(Yellow) }
		3 => { ..base, fonts: { ..base.fonts, ascii: Named("Aptos"), high_ansi: Named("Aptos"), east_asia_theme: Theme(MinorEastAsia) }, language: { latin: Tag("en-AU"), east_asia: Unset, complex: Tag("ar-SA") } }
		4 => { ..base, caps: on, small_caps: Off, strike: On, double_strike: Off, hidden: on }
		_ => { ..base, color: Color({ value: Auto, theme: Unset, tint: Unset, shade: Unset }), underline: Underline(NoUnderline) }
	}
}

paragraph_properties : U64 -> Document.ParagraphProperties
paragraph_properties = |variant| {
	base = Document.no_paragraph_properties
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
	plain_cell = { width: Unset, span: Unset, merge: Unset, borders: [], shading: Unset, alignment: Unset, preserved: [] }
	inner = Table({ properties: { style: Unset, width: Auto, borders: [], shading: Unset, preserved: [] }, grid: [Column(1000)], content: [Row({ properties: { header: Unset, grid_before: Unset, grid_after: Unset, preserved: [] }, content: [cell(plain_cell, [text("inner")])] })] })
	nested = if (variant % 2 == 0) [inner, text("after")] else [text("c${position.to_str()}")]
	first = cell({ ..plain_cell, width: Twips(2000), merge: Restart, alignment: Center, shading: Shading({ pattern: "pct25", color: Unset, fill: Auto }) }, nested)
	second = cell({ ..plain_cell, width: Fiftieths(2500), span: Columns(2), borders: [{ edge: Top, line: "double", size: Unset, space: Unset, color: Unset }, { edge: DiagonalDown, line: "nil", size: Unset, space: Unset, color: Unset }] }, [text("b"), Section(section(variant))])
	below = cell({ ..plain_cell, merge: Continue, width: Nil }, [text("")])
	rows = [
		Row({ properties: { header: On, grid_before: Unset, grid_after: Columns(1), preserved: [] }, content: [first, second] }),
		Row({ properties: { header: Off, grid_before: Columns(1), grid_after: Unset, preserved: [] }, content: [below] }),
	]
	{ properties: { style: Style("Grid"), width: Fiftieths(5000), borders: [{ edge: Top, line: "single", size: Eighths(8), space: Points(0), color: Auto }, { edge: InsideVertical, line: "nil", size: Unset, space: Unset, color: Unset }], shading: Unset, preserved: [] }, grid: [Column(2000), Column(1000), Column(1500)], content: rows }
}

section : U64 -> Document.Section
section = |variant|
	match variant % 3 {
		0 => { start: NextPage, page_size: Size({ width: 11906, height: 16838, orientation: Portrait }), margins: Margins({ top: 1440, right: 1440, bottom: 1440, left: 1800, header: 708, footer: 708, gutter: 0 }), columns: Equal({ count: 1, space: 720, separator: NoLine }), page_numbers: Unset, title_page: Unset, headers: [], footers: [], preserved: [] }
		1 => { start: Continuous, page_size: Size({ width: 16838, height: 11906, orientation: Landscape }), margins: Margins({ top: -720, right: 720, bottom: 720, left: 720, header: 360, footer: 360, gutter: 100 }), columns: Equal({ count: 2, space: 360, separator: Line }), page_numbers: PageNumbers({ format: Format("lowerRoman"), start: Start(3) }), title_page: On, headers: [], footers: [], preserved: [] }
		_ => { start: Unset, page_size: Unset, margins: Unset, columns: Unequal({ widths: [{ width: 4000, space: 500 }, { width: 5000, space: 0 }], separator: NoLine }), page_numbers: PageNumbers({ format: Unset, start: Unset }), title_page: Off, headers: [], footers: [], preserved: [] }
	}

target = Fuzz.target_with!({
	name: "document-roundtrip",
	examples: [
		Fuzz.example({ name: "small-body", revision: "1", make: || small_program }),
		Fuzz.example({ name: "large-body", revision: "1", make: || large_program }),
	],
	generator,
	test!,
	show: |program| Str.inspect(program),
})
