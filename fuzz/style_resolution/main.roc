app [target] {
	docx: "../../package/main.roc",
	fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.5.0/9WT86CuwM7ZJBSs8iTd1jLyrUFTTiGp5hcJE63TwswGE.tar.zst",
	zip: "https://github.com/lukewilliamboswell/roc-zip/releases/download/0.3.0-rc1/3vvx2cPVp1vjjVgrXcugJqqfrp55ZrURYQUcSArAUHdr.tar.zst",
}

import fuzz.Fuzz
import docx.Document
import docx.Styles
import docx.XmlTree
import zip.Zip
import "../../tests/fixtures/pandoc/basics.docx" as pandoc_basics : List(U8)
import "../../tests/fixtures/pandoc/comments.docx" as pandoc_comments : List(U8)
import "../../tests/fixtures/pandoc/lists.docx" as pandoc_lists : List(U8)
import "../../tests/fixtures/pandoc/notes.docx" as pandoc_notes : List(U8)
import "../../tests/fixtures/pandoc/review.docx" as pandoc_review : List(U8)
import "../../tests/fixtures/pandoc/revisions.docx" as pandoc_revisions : List(U8)
import "../../tests/fixtures/pandoc/tables.docx" as pandoc_tables : List(U8)
import "../../tests/fixtures/libreoffice/basics.docx" as libreoffice_basics : List(U8)
import "../../tests/fixtures/libreoffice/comments.docx" as libreoffice_comments : List(U8)
import "../../tests/fixtures/libreoffice/lists.docx" as libreoffice_lists : List(U8)
import "../../tests/fixtures/libreoffice/notes.docx" as libreoffice_notes : List(U8)
import "../../tests/fixtures/libreoffice/review.docx" as libreoffice_review : List(U8)
import "../../tests/fixtures/libreoffice/revisions.docx" as libreoffice_revisions : List(U8)
import "../../tests/fixtures/libreoffice/tables.docx" as libreoffice_tables : List(U8)
import "../../tests/fixtures/word/comments.docx" as word_comments : List(U8)
import "../../tests/fixtures/word/pages.docx" as word_pages : List(U8)
import "../../tests/fixtures/word/report.docx" as word_report : List(U8)
import "../../tests/fixtures/word/revisions.docx" as word_revisions : List(U8)
import "../../tests/fixtures/word/tables.docx" as word_tables : List(U8)

## Effective properties are idempotent under re-resolution and agree with a
## direct evaluation of the inheritance chain. A program describes up to
## eight paragraph and character styles, each perhaps based on another, on a
## style that does not exist or on itself through a cycle, with bold, italic,
## size, outline level, keep-with-next and alignment set, cleared or left
## alone, document defaults, and a paragraph and run with direct properties
## and style references. The styles are written as a styles part and read by
## `Styles.read`; resolving the paragraph and the run, then resolving their
## effective properties again as if they were direct, gives the same
## properties, and each generated property equals what a separately written
## walk of the description's base chains gives, toggles combined between
## kinds of style. Every fixture's styles part reads, and every one of its
## styles resolves idempotently.
##
## Allocation ratchets, which only ever move down: reading allocates at most
## linearly in the part's bytes and resolving a paragraph and a run at most a
## constant, and each declared example allocates no more than it did when its
## ceiling was set. The long chain, sixteen times the short one's styles,
## reads with at most seventeen times the short one's allocations,
## requested bytes and bytes held live in the same run, and resolves its
## last style for no more than the short chain's last. Raising a ceiling
## needs a cause recorded in the pull request.
test! : Input => Fuzz.Outcome
test! = |input|
	match input {
		Generated(program) => {
			agree!(describe(program))
			Fuzz.keep
		}

		# Exploration mutates the declared examples; a chain of another length
		# is not one of them.
		Chain(length) =>
			match chains.find_first(|chain| chain.length == length) {
				Ok(chain) => {
					short = chain_cost!(16)
					cost = chain_cost!(length)
					if cost.read > chain.allocations {
						crash "a declared chain allocated more than its ceiling"
					}
					if cost.read > 17 * short.read or cost.requested_bytes > 17 * short.requested_bytes or cost.held_bytes > 17 * short.held_bytes {
						crash "the long chain read for more than seventeen times the short one"
					}
					if cost.resolve > short.resolve {
						crash "resolving a long chain's style cost more than a short chain's"
					}
					Fuzz.keep
				}

				Err(_) => Fuzz.reject
			}

		Fixture(index) =>
			match fixtures.get(index) {
				Ok(fixture) => {
					entries = Zip.extract(fixture.bytes) ?? crash "a fixture is not a ZIP archive"
					part = entries.find_first(|entry| entry.path == "word/styles.xml") ?? crash "a fixture has no styles part"
					tree = XmlTree.parse(part.content, {}) ?? crash "a fixture's styles part does not read"
					{ value: read, stats } = Fuzz.measure!("styles-read", || Styles.read(tree))
					check_read(stats, part.content.len())
					if stats.allocs + stats.reallocs > fixture.allocations {
						crash "a fixture's styles allocated more than its ceiling"
					}
					for id in fixture.styles {
						paragraph = { ..Document.no_paragraph_properties, style: Style(id) }
						run = { ..Document.no_run_properties, style: Style(id) }
						check_idempotent(read.styles, paragraph, run)
					}
					Fuzz.keep
				}

				Err(_) => Fuzz.reject
			}
	}

Input : [Generated(List(U8)), Chain(U64), Fixture(U64)]

generator : Fuzz.Generator(Input)
generator = Fuzz.map(Fuzz.bytes, |program| Generated(program))

# A generated style: its kind, its base (none, a style of the description
# by index, or one that does not exist), whether it is its kind's default,
# and the properties it states.
GenStyle : { kind : [Paragraph, Character], base : [NoBase, Base(U64), Missing], default : Bool, set : Settings }

# The generated properties: each `Unset` where not stated.
Settings : {
	bold : Document.OnOff,
	italic : Document.OnOff,
	size : [Unset, HalfPoints(U32)],
	outline : [Unset, Level(U8)],
	keep_next : Document.OnOff,
	alignment : [Unset, Aligned(Document.Alignment)],
}

Description : { styles : List(GenStyle), defaults : Settings, paragraph : { style : [NoStyle, Index(U64)], set : Settings }, run : { style : [NoStyle, Index(U64)], set : Settings } }

# The description a program of bytes gives: each byte read in turn,
# wrapping round, so every program describes something.
describe : List(U8) -> Description
describe = |program| {
	at = |index| if (program.is_empty()) 0 else (program.get(index % program.len()) ?? 0).to_u64()
	count = at(0) % 8 + 1
	settings = |offset| {
		bold: on_off(at(offset)),
		italic: on_off(at(offset) // 3),
		size: if (at(offset + 1) % 3 == 0) HalfPoints((at(offset + 1) % 40 + 16).to_u32_wrap()) else Unset,
		outline: if (at(offset + 1) % 5 == 1) Level((at(offset + 1) % 10).to_u8_wrap()) else Unset,
		keep_next: on_off(at(offset + 2)),
		alignment: match at(offset + 2) // 3 % 4 {
			0 => Aligned(Center)
			1 => Aligned(Both)
			2 => Aligned(Left)
			_ => Unset
		},
	}
	styles = List.repeat(0, count).map_with_index(
		|_, index| {
			offset = 1 + index * 5
			choice = at(offset)
			{
				kind: if (choice % 3 == 0) Character else Paragraph,
				base: match choice // 3 % 4 {
					0 => NoBase
					1 => Missing
					_ => Base(at(offset + 1) % count)
				},
				default: choice // 12 % 4 == 0,
				set: settings(offset + 2),
			}
		},
	)
	reference = |byte| if (byte % 4 == 0) NoStyle else Index(byte % count)
	next = 1 + count * 5
	{
		styles,
		defaults: settings(next),
		paragraph: { style: reference(at(next + 3)), set: settings(next + 4) },
		run: { style: reference(at(next + 7)), set: { ..settings(next + 8), outline: Unset, keep_next: Unset, alignment: Unset } },
	}
}

on_off : U64 -> Document.OnOff
on_off = |byte|
	match byte % 3 {
		0 => Unset
		1 => On
		_ => Off
	}

# Identifiers of one length, so a chain's bytes grow with its styles alone.
id_of : U64 -> Str
id_of = |index| {
	digits = index.to_str()
	"S${Str.repeat("0", 4 - Str.count_utf8_bytes(digits))}${digits}"
}

# The description's styles as a styles part.
styles_xml : Description -> Str
styles_xml = |description| {
	properties = |set| {
		rpr = Str.join_with(
			[
				toggle_xml("b", set.bold),
				toggle_xml("i", set.italic),
				match set.size {
					HalfPoints(size) => "<w:sz w:val=\"${size.to_str()}\"/>"
					Unset => ""
				},
			],
			"",
		)
		ppr = Str.join_with(
			[
				toggle_xml("keepNext", set.keep_next),
				match set.alignment {
					Aligned(Center) => "<w:jc w:val=\"center\"/>"
					Aligned(Both) => "<w:jc w:val=\"both\"/>"
					Aligned(_) => "<w:jc w:val=\"left\"/>"
					Unset => ""
				},
				match set.outline {
					Level(level) => "<w:outlineLvl w:val=\"${level.to_str()}\"/>"
					Unset => ""
				},
			],
			"",
		)
		"<w:pPr>${ppr}</w:pPr><w:rPr>${rpr}</w:rPr>"
	}
	styles = description.styles.map_with_index(
		|style, index| {
			kind = if (style.kind == Character) "character" else "paragraph"
			default = if (style.default) " w:default=\"1\"" else ""
			based_on = match style.base {
				NoBase => ""
				Missing => "<w:basedOn w:val=\"Missing\"/>"
				Base(base) => "<w:basedOn w:val=\"${id_of(base)}\"/>"
			}
			"<w:style w:type=\"${kind}\"${default} w:styleId=\"${id_of(index)}\"><w:name w:val=\"Style ${index.to_str()}\"/>${based_on}${properties(style.set)}</w:style>"
		},
	)
	defaults = properties(description.defaults)
	"<w:styles xmlns:w=\"${w}\"><w:docDefaults><w:pPrDefault>${defaults_part(defaults, "pPr")}</w:pPrDefault><w:rPrDefault>${defaults_part(defaults, "rPr")}</w:rPrDefault></w:docDefaults>${Str.join_with(styles, "")}</w:styles>"
}

# The `w:pPr` or `w:rPr` element of a style's rendered properties.
defaults_part : Str, Str -> Str
defaults_part = |rendered, local| {
	start = "<w:${local}>"
	end = "</w:${local}>"
	inner = match rendered.split_first(start) {
		Ok({ before: _, after }) =>
			match after.split_first(end) {
				Ok({ before, after: _ }) => before
				Err(NotFound) => ""
			}

		Err(NotFound) => ""
	}
	"${start}${inner}${end}"
}

toggle_xml : Str, Document.OnOff -> Str
toggle_xml = |local, value|
	match value {
		On => "<w:${local}/>"
		Off => "<w:${local} w:val=\"0\"/>"
		Unset => ""
	}

as_paragraph : Settings, [NoStyle, Index(U64)] -> Document.ParagraphProperties
as_paragraph = |set, style| {
	..Document.no_paragraph_properties,
	style: match style {
		Index(index) => Style(id_of(index))
		NoStyle => Unset
	},
	keep_next: set.keep_next,
	alignment: set.alignment,
	outline_level: set.outline,
}

as_run : Settings, [NoStyle, Index(U64)] -> Document.RunProperties
as_run = |set, style| {
	..Document.no_run_properties,
	style: match style {
		Index(index) => Style(id_of(index))
		NoStyle => Unset
	},
	bold: set.bold,
	italic: set.italic,
	size: set.size,
}

# Read the description's styles, resolve its paragraph and run, and check
# them against the reference.
agree! : Description => {}
agree! = |description| {
	xml = styles_xml(description)
	tree = XmlTree.parse(xml.to_utf8(), {}) ?? crash "a generated styles part does not parse"
	{ value: read, stats: read_stats } = Fuzz.measure!("styles-read", || Styles.read(tree))
	check_read(read_stats, xml.to_utf8().len())
	paragraph = as_paragraph(description.paragraph.set, description.paragraph.style)
	run = as_run(description.run.set, description.run.style)
	{ value: resolved, stats } = Fuzz.measure!(
		"styles-effective",
		|| {
			paragraph: Styles.effective_paragraph(read.styles, paragraph, {}),
			run: Styles.effective_run(read.styles, { paragraph, run }, {}),
		},
	)
	check_resolve(stats)
	check_idempotent(read.styles, paragraph, run)
	expected = reference(description)
	actual = {
		bold: resolved.run.bold,
		italic: resolved.run.italic,
		size: resolved.run.size,
		outline: resolved.paragraph.outline_level,
		keep_next: resolved.paragraph.keep_next,
		alignment: resolved.paragraph.alignment,
	}
	if actual != expected {
		crash "effective properties differ from a direct evaluation of the chains"
	}
	{}
}

check_idempotent : Styles, Document.ParagraphProperties, Document.RunProperties -> {}
check_idempotent = |styles, paragraph, run| {
	effective_paragraph = Styles.effective_paragraph(styles, paragraph, {})
	effective_run = Styles.effective_run(styles, { paragraph, run }, {})
	if Styles.effective_paragraph(styles, effective_paragraph, {}) != effective_paragraph {
		crash "a paragraph's effective properties resolve to something else"
	}
	if Styles.effective_run(styles, { paragraph, run: effective_run }, {}) != effective_run {
		crash "a run's effective properties resolve to something else"
	}
	{}
}

# The generated properties' effective values, by walking the description:
# the applied paragraph and character styles, each base chain followed to
# its end, a missing base, a base of another kind or a style on a cycle,
# which stands without a base, and every property taken from the last place
# that states it, toggles inverted by each kind of style that turns them on.
reference : Description -> Settings
reference = |description| {
	styles = description.styles
	usable_base = |index|
		match styles.get(index) {
			Ok({ kind, base: Base(base), default: _, set: _ }) =>
				match styles.get(base) {
					Ok(found) if found.kind == kind => Ok(base)
					_ => Err(NoBase)
				}

			_ => Err(NoBase)
		}
	on_cycle = |index| {
		var $current = index
		var $steps = 0.U64
		var $found = Bool.False
		while $steps < styles.len() and !$found {
			match usable_base($current) {
				Ok(base) => {
					$current = base
					$found = base == index
				}

				Err(_) => {
					$steps = styles.len()
				}
			}
			$steps = $steps + 1
		}
		$found
	}
	# A style's chain, nearest first.
	chain = |index| {
		var $chain = [index]
		var $current = index
		var $walking = !on_cycle(index)
		while $walking {
			match usable_base($current) {
				Ok(base) => {
					$chain = List.append($chain, base)
					$current = base
					$walking = !on_cycle(base)
				}

				Err(_) => {
					$walking = Bool.False
				}
			}
		}
		$chain
	}
	nearest = |indices, field|
		indices.fold(
			Unset,
			|found, index|
				match found {
					Unset => field((styles.get(index) ?? empty_style).set)
					_ => found
				},
		)
	default_of = |kind| styles.find_first_index(|style| style.kind == kind and style.default)
	applied = |reference_to, kind|
		match reference_to {
			Index(index) =>
				match styles.get(index) {
					Ok(found) if found.kind == kind => Ok(index)
					_ => default_of(kind)
				}

			NoStyle => default_of(kind)
		}
	paragraph_chain = match applied(description.paragraph.style, Paragraph) {
		Ok(index) => chain(index)
		Err(_) => []
	}
	character_chain = match applied(description.run.style, Character) {
		Ok(index) => chain(index)
		Err(_) => []
	}
	last = |levels|
		levels.fold(
			Unset,
			|found, value|
				match value {
					Unset => found
					_ => value
				},
		)
	toggle = |field| {
		var $state = field(description.defaults) == On
		for level_chain in [paragraph_chain, character_chain] {
			if nearest(level_chain, field) == On {
				$state = !$state
			}
		}
		match field(description.run.set) {
			Unset => if ($state) On else Off
			stated => stated
		}
	}
	{
		bold: toggle(|set| set.bold),
		italic: toggle(|set| set.italic),
		size: last([description.defaults.size, nearest(paragraph_chain, |set| set.size), nearest(character_chain, |set| set.size), description.run.set.size]),
		outline: last([description.defaults.outline, nearest(paragraph_chain, |set| set.outline), description.paragraph.set.outline]),
		keep_next: last([description.defaults.keep_next, nearest(paragraph_chain, |set| set.keep_next), description.paragraph.set.keep_next]),
		alignment: last([description.defaults.alignment, nearest(paragraph_chain, |set| set.alignment), description.paragraph.set.alignment]),
	}
}

empty_style : GenStyle
empty_style = {
	kind: Paragraph,
	base: NoBase,
	default: Bool.False,
	set: { bold: Unset, italic: Unset, size: Unset, outline: Unset, keep_next: Unset, alignment: Unset },
}

# A chain of styles, each based on the one before, read and its last style
# resolved: the allocations of each and the bytes reading requested.
chain_cost! : U64 => { read : U64, requested_bytes : U64, held_bytes : U64, resolve : U64 }
chain_cost! = |length| {
	styles = List.repeat(0, length).map_with_index(
		|_, index| {
			base = if (index == 0) "" else "<w:basedOn w:val=\"${id_of(index - 1)}\"/>"
			"<w:style w:type=\"paragraph\" w:styleId=\"${id_of(index)}\">${base}<w:pPr><w:outlineLvl w:val=\"${(index % 9).to_str()}\"/></w:pPr><w:rPr>${if (index % 2 == 0) "<w:b/>" else "<w:i/>"}</w:rPr></w:style>"
		},
	)
	xml = "<w:styles xmlns:w=\"${w}\">${Str.join_with(styles, "")}</w:styles>"
	tree = XmlTree.parse(xml.to_utf8(), {}) ?? crash "a chain's styles part does not parse"
	{ value: read, stats: read_stats } = Fuzz.measure!("styles-read", || Styles.read(tree))
	check_read(read_stats, xml.to_utf8().len())
	paragraph = { ..Document.no_paragraph_properties, style: Style(id_of(length - 1)) }
	{ value: _, stats } = Fuzz.measure!("styles-effective", || Styles.effective_run(read.styles, { paragraph, run: Document.no_run_properties }, {}))
	check_resolve(stats)
	{ read: read_stats.allocs + read_stats.reallocs, requested_bytes: read_stats.requested_bytes, held_bytes: read_stats.peak_live_bytes - read_stats.entry_live_bytes, resolve: stats.allocs + stats.reallocs }
}

# Reading allocates about a quarter of an allocation and holds 9 to 15
# bytes live for each byte of a styles part (pandoc's 27,124-byte part: 7,050
# allocations, 386 KB).
check_read : Fuzz.Stats, U64 -> {}
check_read = |stats, bytes| {
	if stats.allocs + stats.reallocs > 64 + bytes // 2 {
		crash "reading styles allocated more than linearly in the part's bytes"
	}
	if stats.peak_live_bytes - stats.entry_live_bytes > 16_384 + 32 * bytes {
		crash "reading styles held more than linearly many bytes live"
	}
	{}
}

check_resolve : Fuzz.Stats -> {}
check_resolve = |stats| {
	if stats.allocs + stats.reallocs > 16 {
		crash "resolving a paragraph and a run allocated more than a constant"
	}
	{}
}

# Exact ceilings: the allocations of reading a declared chain's styles,
# measured on nightly-2026-11-07. Reading costs about the same a style at
# every length from 16 to 4,096 styles: 52 allocations (839 and 13,331, a
# ratio of 15.9) and, as buffer capacities round differently, 179,945 and
# 2,923,705 requested bytes, a ratio of 16.25, which is why the pair allows
# a seventeenth; they hold 37,816 and 535,504 bytes live, a ratio of 14.2.
# Resolving takes 2 allocations at any length, because each
# style's chain is merged once when the table is read.
chains : List({ length : U64, allocations : U64 })
chains = [
	{ length: 16, allocations: 839 },
	{ length: 256, allocations: 13_331 },
]

# Each fixture's styles-reading allocations and the styles it resolves.
fixtures : List({ name : Str, bytes : List(U8), allocations : U64, styles : List(Str) })
fixtures = [
	{ name: "pandoc-basics", bytes: pandoc_basics, allocations: 7_050, styles: fixture_styles },
	{ name: "pandoc-comments", bytes: pandoc_comments, allocations: 7_050, styles: fixture_styles },
	{ name: "pandoc-lists", bytes: pandoc_lists, allocations: 7_050, styles: fixture_styles },
	{ name: "pandoc-notes", bytes: pandoc_notes, allocations: 7_050, styles: fixture_styles },
	{ name: "pandoc-review", bytes: pandoc_review, allocations: 7_050, styles: fixture_styles },
	{ name: "pandoc-revisions", bytes: pandoc_revisions, allocations: 7_050, styles: fixture_styles },
	{ name: "pandoc-tables", bytes: pandoc_tables, allocations: 7_050, styles: fixture_styles },
	{ name: "libreoffice-basics", bytes: libreoffice_basics, allocations: 8_401, styles: fixture_styles },
	{ name: "libreoffice-comments", bytes: libreoffice_comments, allocations: 8_401, styles: fixture_styles },
	{ name: "libreoffice-lists", bytes: libreoffice_lists, allocations: 8_401, styles: fixture_styles },
	{ name: "libreoffice-notes", bytes: libreoffice_notes, allocations: 8_490, styles: fixture_styles },
	{ name: "libreoffice-review", bytes: libreoffice_review, allocations: 8_401, styles: fixture_styles },
	{ name: "libreoffice-revisions", bytes: libreoffice_revisions, allocations: 8_401, styles: fixture_styles },
	{ name: "libreoffice-tables", bytes: libreoffice_tables, allocations: 8_401, styles: fixture_styles },
	{ name: "word-comments", bytes: word_comments, allocations: 2_842, styles: word_styles },
	{ name: "word-pages", bytes: word_pages, allocations: 2_847, styles: List.concat(word_styles, ["Header", "Footer"]) },
	{ name: "word-report", bytes: word_report, allocations: 2_842, styles: word_styles },
	{ name: "word-revisions", bytes: word_revisions, allocations: 2_935, styles: word_styles },
	{ name: "word-tables", bytes: word_tables, allocations: 2_847, styles: word_styles },
]

# The styles the pandoc and LibreOffice fixtures' documents use, from their
# producers' shared reference styles.
fixture_styles : List(Str)
fixture_styles = ["Normal", "Title", "Heading1", "Heading2", "Heading3", "FirstParagraph", "BodyText", "Compact", "BlockText", "Hyperlink", "VerbatimChar", "TOCHeading"]

# The styles the Word fixtures' documents use.
word_styles : List(Str)
word_styles = ["Normal", "Heading1", "Heading2", "ListParagraph", "Hyperlink", "FootnoteReference", "EndnoteReference", "CommentReference"]

w : Str
w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

target = Fuzz.target_with!({
	name: "style-resolution",
	examples: [
		Fuzz.example({ name: "short-chain", revision: "1", make: || Chain(16) }),
		Fuzz.example({ name: "long-chain", revision: "1", make: || Chain(256) }),
	].concat(fixtures.map_with_index(|fixture, index| Fuzz.example({ name: fixture.name, revision: "1", make: || Fixture(index) }))),
	generator,
	test!,
	show: |input| Str.inspect(input),
})
