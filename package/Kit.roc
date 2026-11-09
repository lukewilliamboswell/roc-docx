## The default document kit: what a new document holds before anything is
## written in it.
##
## A new document is a package with a main document part whose body is one
## empty paragraph on an A4 page with one-inch margins; a styles part with
## a minimal style set that Word and LibreOffice recognise as their own
## built-in styles; a numbering part with a bulleted and a numbered list of
## nine levels each; a settings part; a font table; and core properties from
## the caller. Nothing is taken from a clock or the host: the same
## [Kit.New] always gives the same document.
##
## The styles, the list definitions and the core properties are model
## values written by [WmlWrite.styles], [WmlWrite.numbering] and
## [WmlWrite.core_properties], so [Docx.styles], [Docx.numbering] and
## [Docx.core_properties] read them back as they were built. The settings
## and the font table have no model and are built as trees. Each style is
## named as Word names its built-in style (`heading 1`, `annotation text`),
## which is how Word and LibreOffice recognise it and show it under the
## name of their own language.
import Document
import Numbering
import Opc
import Styles
import WmlRead
import WmlWrite
import XmlTree

Kit :: [].{

	## What a new document says about itself: its title, its author
	## (`creator`), and when it was created and last modified, each in the
	## W3C date and time format, such as `2026-11-10T09:00:00Z`. Each is left
	## out of the document's core properties when `Unset`; the package reads
	## no clock, so a document has the dates its caller gives it.
	New := {
		title : [Unset, Text(Str)] ?? Unset,
		creator : [Unset, Text(Str)] ?? Unset,
		created : [Unset, Date(Str)] ?? Unset,
		modified : [Unset, Date(Str)] ?? Unset,
	}

	## A new document with the kit's parts and the properties `new` gives,
	## or the date it gives that is not in the W3C date and time format, as
	## [WmlRead.core_properties] reads a date: a year, a month or a day, or a
	## day and a time with its time zone.
	document : New -> Try(Document, [NotADate(Str)])
	document = |new| {
		properties = { title: new.title, subject: Unset, creator: new.creator, keywords: Unset, description: Unset, last_modified_by: Unset, revision: Unset, created: new.created, modified: new.modified, preserved: [] }
		core = WmlWrite.core_properties(properties)
		read = WmlRead.core_properties(core)
		dated = |given, kept|
			match given {
				Date(written) if kept != given => Err(NotADate(written))
				_ => Ok({})
			}
		dated(new.created, read.created)?
		dated(new.modified, read.modified)?
		trees = Dict.empty().insert(main_part, shell).insert(styles_part, styles_tree).insert(numbering_part, numbering_tree).insert(settings_part, settings_tree).insert(fonts_part, fonts_tree).insert(core_part, core)
		Ok(Document.from_trees(graph, trees, body))
	}
}

main_part : Str
main_part = "/word/document.xml"

styles_part : Str
styles_part = "/word/styles.xml"

numbering_part : Str
numbering_part = "/word/numbering.xml"

settings_part : Str
settings_part = "/word/settings.xml"

fonts_part : Str
fonts_part = "/word/fontTable.xml"

core_part : Str
core_part = "/docProps/core.xml"

# The package's parts and relationships: the main document and the core
# properties from the package, and the styles, numbering, settings and font
# table from the main document.
graph : Opc.Graph
graph = {
	relationships: [
		{ id: "rId1", kind: Opc.officedocument_relationship, target: main_part, mode: Internal },
		{ id: "rId2", kind: "http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties", target: core_part, mode: Internal },
	],
	parts: [
		{
			name: main_part,
			content_type: wordprocessingml_type("document.main"),
			relationships: [
				{ id: "rId1", kind: office_relationship("styles"), target: styles_part, mode: Internal },
				{ id: "rId2", kind: office_relationship("numbering"), target: numbering_part, mode: Internal },
				{ id: "rId3", kind: office_relationship("settings"), target: settings_part, mode: Internal },
				{ id: "rId4", kind: office_relationship("fontTable"), target: fonts_part, mode: Internal },
			],
		},
		{ name: styles_part, content_type: wordprocessingml_type("styles"), relationships: [] },
		{ name: numbering_part, content_type: wordprocessingml_type("numbering"), relationships: [] },
		{ name: settings_part, content_type: wordprocessingml_type("settings"), relationships: [] },
		{ name: fonts_part, content_type: wordprocessingml_type("fontTable"), relationships: [] },
		{ name: core_part, content_type: "application/vnd.openxmlformats-package.core-properties+xml", relationships: [] },
	],
}

wordprocessingml_type : Str -> Str
wordprocessingml_type = |kind| "application/vnd.openxmlformats-officedocument.wordprocessingml.${kind}+xml"

office_relationship : Str -> Str
office_relationship = |kind| "http://schemas.openxmlformats.org/officeDocument/2006/relationships/${kind}"

# The main document part the body is written into.
shell : XmlTree.Node
shell = w("document", [], [])

# One empty paragraph, which Word and LibreOffice show as an empty page, in
# a section of A4 paper, portrait, with one-inch margins and the header and
# footer half an inch from the edge.
body : List(Document.Block)
body = [
	Paragraph({ properties: Document.no_paragraph_properties, content: [] }),
	Section({
		start: Unset,
		page_size: Size({ width: 11906, height: 16838, orientation: Portrait }),
		margins: Margins({ top: 1440, right: 1440, bottom: 1440, left: 1440, header: 708, footer: 708, gutter: 0 }),
		columns: Unset,
		page_numbers: Unset,
		title_page: Unset,
		headers: [],
		footers: [],
		preserved: [],
		change: [],
	}),
]

# ---- Styles ----------------------------------------------------------------

styles_tree : XmlTree.Node
styles_tree = WmlWrite.styles({ defaults, styles: style_set })

# Calibri at 11 points, with 8 points after each paragraph and lines at
# 1.08 times their height, as Word's own defaults are.
defaults : { paragraph : Document.ParagraphProperties, run : Document.RunProperties }
defaults = {
	paragraph: { ..Document.no_paragraph_properties, spacing: { before: Unset, after: Twips(160), line: Auto(259) } },
	run: { ..Document.no_run_properties, fonts: { ascii: Named(body_font), high_ansi: Named(body_font), east_asia: Named(body_font), complex: Named(body_font), ascii_theme: Unset, high_ansi_theme: Unset, east_asia_theme: Unset, complex_theme: Unset }, size: HalfPoints(22) },
}

body_font : Str
body_font = "Calibri"

# The style set: the defaults of each kind Word gives every document, the
# headings, a list paragraph, a bordered table, a hyperlink, and the text and
# reference styles of footnotes, endnotes and comments.
style_set : List(Styles.Style)
style_set = List.join([
	[
		{ ..style(Paragraph, "Normal", "Normal"), usage: KindDefault, preserved: [quick] },
		{ ..style(Character, "DefaultParagraphFont", "Default Paragraph Font"), usage: KindDefault, preserved: [priority(1), semi_hidden, unhide] },
		{ ..style(Table, "TableNormal", "Normal Table"), usage: KindDefault, preserved: [priority(99), semi_hidden, unhide, normal_table] },
		{ ..style(Numbering, "NoList", "No List"), usage: KindDefault, preserved: [priority(99), semi_hidden, unhide] },
	],
	headings,
	[
		{
			..paragraph_style("ListParagraph", "List Paragraph"),
			paragraph: { ..Document.no_paragraph_properties, indentation: { left: Twips(720), right: Unset, first_line: Unset }, preserved: [w("contextualSpacing", [], [])] },
			preserved: [priority(34), quick],
		},
		{
			..style(Table, "TableGrid", "Table Grid"),
			based_on: BasedOn("TableNormal"),
			paragraph: single_spaced,
			preserved: [priority(39), grid],
		},
		{
			..character_style("Hyperlink", "Hyperlink"),
			run: { ..Document.no_run_properties, color: Color({ value: Rgb("0563C1"), theme: Unset, tint: Unset, shade: Unset }), underline: Underline(Single) },
			preserved: [priority(99), unhide],
		},
		note_text("FootnoteText", "footnote text"),
		note_reference("FootnoteReference", "footnote reference"),
		note_text("EndnoteText", "endnote text"),
		note_reference("EndnoteReference", "endnote reference"),
		{
			..paragraph_style("CommentText", "annotation text"),
			paragraph: { ..Document.no_paragraph_properties, spacing: { before: Unset, after: Unset, line: Auto(240) } },
			run: { ..Document.no_run_properties, size: HalfPoints(20) },
			preserved: [priority(99), unhide],
		},
		{
			..character_style("CommentReference", "annotation reference"),
			run: { ..Document.no_run_properties, size: HalfPoints(16) },
			preserved: [priority(99), semi_hidden, unhide],
		},
	],
])

# Headings 1 to 6, each followed by a normal paragraph, kept with the next
# paragraph and at its outline level, sized and coloured as Word's.
headings : List(Styles.Style)
headings = {
	dark = "2F5496"
	darker = "1F3763"
	heading = |level, before, run| {
		..paragraph_style("Heading${(level + 1).to_str()}", "heading ${(level + 1).to_str()}"),
		next: Next("Normal"),
		paragraph: { ..Document.no_paragraph_properties, keep_next: On, keep_lines: On, spacing: { before: Twips(before), after: Twips(0), line: Unset }, outline_level: Level(level) },
		run,
		preserved: [priority(9), quick],
	}
	coloured = |rgb| { ..Document.no_run_properties, color: Color({ value: Rgb(rgb), theme: Unset, tint: Unset, shade: Unset }) }
	[
		heading(0, 240, { ..coloured(dark), size: HalfPoints(32) }),
		heading(1, 40, { ..coloured(dark), size: HalfPoints(26) }),
		heading(2, 40, { ..coloured(darker), size: HalfPoints(24) }),
		heading(3, 40, { ..coloured(dark), italic: On }),
		heading(4, 40, coloured(dark)),
		heading(5, 40, coloured(darker)),
	]
}

# A note's text: single-spaced at 10 points.
note_text : Str, Str -> Styles.Style
note_text = |id, name| {
	..paragraph_style(id, name),
	paragraph: single_spaced,
	run: { ..Document.no_run_properties, size: HalfPoints(20) },
	preserved: [priority(99), semi_hidden, unhide],
}

# A note's reference: superscript.
note_reference : Str, Str -> Styles.Style
note_reference = |id, name| {
	..character_style(id, name),
	run: { ..Document.no_run_properties, vertical_align: Superscript },
	preserved: [priority(99), semi_hidden, unhide],
}

single_spaced : Document.ParagraphProperties
single_spaced = { ..Document.no_paragraph_properties, spacing: { before: Unset, after: Twips(0), line: Auto(240) } }

style : Styles.Kind, Str, Str -> Styles.Style
style = |kind, id, name| { id, name: Named(name), kind, based_on: NoBase, next: NoNext, link: NoLink, usage: Ordinary, origin: BuiltIn, paragraph: Document.no_paragraph_properties, run: Document.no_run_properties, preserved: [] }

paragraph_style : Str, Str -> Styles.Style
paragraph_style = |id, name| { ..style(Paragraph, id, name), based_on: BasedOn("Normal") }

character_style : Str, Str -> Styles.Style
character_style = |id, name| { ..style(Character, id, name), based_on: BasedOn("DefaultParagraphFont") }

# Where a style sits in the style gallery and pane, and when it is shown.
priority : U64 -> XmlTree.Node
priority = |rank| w("uiPriority", [attribute("val", rank.to_str())], [])

quick : XmlTree.Node
quick = w("qFormat", [], [])

semi_hidden : XmlTree.Node
semi_hidden = w("semiHidden", [], [])

unhide : XmlTree.Node
unhide = w("unhideWhenUsed", [], [])

# A table without indent, with Word's cell margins.
normal_table : XmlTree.Node
normal_table = w(
	"tblPr",
	[],
	[
		w("tblInd", [attribute("w", "0"), attribute("type", "dxa")], []),
		w(
			"tblCellMar",
			[],
			[
				w("top", [attribute("w", "0"), attribute("type", "dxa")], []),
				w("left", [attribute("w", "108"), attribute("type", "dxa")], []),
				w("bottom", [attribute("w", "0"), attribute("type", "dxa")], []),
				w("right", [attribute("w", "108"), attribute("type", "dxa")], []),
			],
		),
	],
)

# A half-point line around every cell.
grid : XmlTree.Node
grid = {
	line = |edge| w(edge, [attribute("val", "single"), attribute("sz", "4"), attribute("space", "0"), attribute("color", "auto")], [])
	w("tblPr", [], [w("tblBorders", [], ["top", "left", "bottom", "right", "insideH", "insideV"].map(line))])
}

# ---- Lists -------------------------------------------------------------------

# A bulleted list, instance 1, and a numbered list, instance 2, each of nine
# levels indented by half an inch more at each level with the bullet or
# number hanging a quarter inch.
numbering_tree : XmlTree.Node
numbering_tree = WmlWrite.numbering({
	definitions: [
		{ id: 0, definition: list(|at| { format: Bullet, text: bullets.get((at % 3).to_u64()) ?? "•", alignment: Left }) },
		{ id: 1, definition: list(|at| { format: Number(numbers.get((at % 3).to_u64()) ?? "decimal"), text: "%${(at + 1).to_str()}.", alignment: if (at % 3 == 2) Right else Left }) },
	],
	instances: [
		{ id: 1, instance: { definition: Definition(0), overrides: [], preserved_attributes: [], preserved: [] } },
		{ id: 2, instance: { definition: Definition(1), overrides: [], preserved_attributes: [], preserved: [] } },
	],
})

bullets : List(Str)
bullets = ["•", "◦", "▪"]

numbers : List(Str)
numbers = ["decimal", "lowerLetter", "lowerRoman"]

list : (U8 -> { format : Numbering.Format, text : Str, alignment : Document.Alignment }) -> Numbering.Definition
list = |shown| {
	kind: Multilevel,
	style: Unset,
	uses_style: Unset,
	levels: [0, 1, 2, 3, 4, 5, 6, 7, 8].map(
		|at| {
			level = shown(at)
			{
				level: at,
				start: Start(1),
				format: level.format,
				text: Text(level.text),
				alignment: Aligned(level.alignment),
				paragraph_style: Unset,
				paragraph: { ..Document.no_paragraph_properties, indentation: { left: Twips(720 * (at.to_i32() + 1)), right: Unset, first_line: Hanging(360) } },
				run: Document.no_run_properties,
				preserved_attributes: [],
				preserved: [],
			}
		},
	),
	preserved_attributes: [],
	preserved: [],
}

# ---- Settings and fonts ----------------------------------------------------

# Tab stops every half inch, and Word 2013's layout rather than an earlier
# version's compatibility mode.
settings_tree : XmlTree.Node
settings_tree = w(
	"settings",
	[],
	[
		w("defaultTabStop", [attribute("val", "720")], []),
		w("characterSpacingControl", [attribute("val", "doNotCompress")], []),
		w("compat", [], [w("compatSetting", [attribute("name", "compatibilityMode"), attribute("uri", "http://schemas.microsoft.com/office/word"), attribute("val", "15")], [])]),
	],
)

# The fonts the styles use.
fonts_tree : XmlTree.Node
fonts_tree = w(
	"fonts",
	[],
	[
		w(
			"font",
			[attribute("name", body_font)],
			[
				w("panose1", [attribute("val", "020F0502020204030204")], []),
				w("charset", [attribute("val", "00")], []),
				w("family", [attribute("val", "swiss")], []),
				w("pitch", [attribute("val", "variable")], []),
			],
		),
	],
)

wordprocessingml : Str
wordprocessingml = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

w : Str, List(XmlTree.Attribute), List(XmlTree.Node) -> XmlTree.Node
w = |local, attributes, children| Element({ name: { namespace: Uri(wordprocessingml), local, prefix: Prefix("w") }, bindings: [], attributes, children })

attribute : Str, Str -> XmlTree.Attribute
attribute = |local, text| { name: { namespace: Uri(wordprocessingml), local, prefix: Prefix("w") }, value: text }

## The style set reads back from the styles part as it was built: every
## style by its identifier, with the defaults, and nothing reading did not
## take as written.
expect {
	read = Styles.read(styles_tree)
	read.diagnostics.is_empty() and style_set.all(|built| Styles.get(read.styles, built.id) == Ok(built))
}

## The lists read back from the numbering part as they were built, and a
## paragraph of the numbered list at its third level is numbered with
## lower-case Roman numerals.
expect {
	read = Numbering.read(numbering_tree)
	level = Numbering.level(read.numbering, Styles.empty, { instance: Instance(2), level: Level(2) })
	read.diagnostics.is_empty()
		and Numbering.definition(read.numbering, Definition(0)).map_ok(|found| found.levels.len()) == Ok(9)
		and level.map_ok(|found| (found.format, found.text)) == Ok((Number("lowerRoman"), Text("%3.")))
}

## A date that is not in the W3C date and time format is refused, and
## nothing is taken from a clock: without dates the document has none.
expect {
	refused = Kit.document({ created: Date("10 November 2026") })
	undated = Kit.document({ title: Text("Lease") })
	refused.is_err() and undated.is_ok()
}
