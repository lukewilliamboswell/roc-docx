## WordprocessingML trees read as the typed model.
##
## The reader is lenient and loses nothing: an element it models becomes a
## typed value, and every other element is kept, in its place, as the
## [XmlTree.Node] it was read as. Elements whose content is itself blocks or
## paragraph content, such as a content control or a tracked insertion, are
## kept without their children and their content is read, so text inside
## them is still text. What a part's elements name elsewhere in the package,
## such as a hyperlink's relationship or a note reference's note, is resolved
## through the part's [WmlRead.Context], so the model holds what is named
## rather than the part's identifiers for it. Whitespace-only text between
## elements is not content and is not kept.
import Document
import Mce
import Opc
import XmlTree

WmlRead :: [].{

	## What reading a part needs from the rest of its package: the
	## relationships whose source is the part, which hyperlinks and pictures
	## name, and the identifiers of the footnotes and of the endnotes in the
	## order of their parts, as [WmlRead.note_ids] lists them, which note
	## references name.
	Context : { relationships : List(Opc.Relationship), footnotes : List(Str), endnotes : List(Str) }

	## The body of a main document part, block by block in reading order, from
	## the part's tree as [Docx.parse] read it. The tree is interpreted by
	## [Mce.process] first, so extensions are skipped and each alternative is
	## read as the branch the package understands. A tree whose root is not a
	## WordprocessingML document, or that has no body, has no blocks.
	##
	## A paragraph's first `w:pPr` holds its properties and a run's first
	## `w:rPr` its properties. In a run, `w:t` is text, `w:tab` a tab, `w:br`
	## a break (`w:cr` a line break), `w:sym` a symbol, `w:softHyphen` and
	## `w:noBreakHyphen` hyphens, `w:footnoteReference` and
	## `w:endnoteReference` note references, `w:footnoteRef` and
	## `w:endnoteRef` note marks, `w:fldChar` a field's mark, `w:instrText` a
	## piece of its code, and a `w:drawing` holding a `wp:inline` picture a
	## picture. In a paragraph, `w:hyperlink` is a hyperlink, `w:fldSimple` a
	## simple field and `w:bookmarkStart` and `w:bookmarkEnd` a bookmark's
	## boundaries.
	##
	## An element whose attributes are not ones the model can hold, such as a
	## break of an unknown type, a symbol without a character code, a note
	## reference with a custom mark or a bookmark spanning table columns, or
	## that names what the package does not have, such as a missing note, a
	## relationship that is not there or a bookmark end without its start,
	## is kept as it was read; a hyperlink or simple field like that is a
	## container of its content.
	##
	## A table's first `w:tblPr` holds its properties and its first
	## `w:tblGrid` its grid, a row's first `w:trPr` and a cell's first
	## `w:tcPr` theirs. Each property the model holds is read from the first
	## element that gives it in a form the model can hold; every other
	## property element stays in `preserved`, in order.
	body : XmlTree.Node, Context -> List(Document.Block)
	body = |tree, context| WmlRead.read_body(tree, context).blocks

	## The body as [WmlRead.body] reads it, with what reading it noticed, in
	## document order.
	read_body : XmlTree.Node, Context -> { blocks : List(Document.Block), diagnostics : List(WmlRead.Diagnostic) }
	read_body = |tree, context| {
		interpreted = Mce.process(tree).interpreted
		match interpreted {
			Element(root) if is_w(root.name, "document") =>
				match root.children.find_first(|child| is_element(child, "body")) {
					Ok(Element(element)) => blocks(element.children, reading(interpreted, context), [])
					_ => { blocks: [], diagnostics: [] }
				}

			_ => { blocks: [], diagnostics: [] }
		}
	}

	## The notes of a footnotes or endnotes part, in the part's order, from
	## the part's tree as [Docx.parse] read it, interpreted by [Mce.process]
	## first. A note's content is read as a body's blocks are, and `w:type`
	## says what kind of note it is. A tree whose root is not a
	## WordprocessingML footnotes or endnotes part has no notes.
	notes : XmlTree.Node, Context -> List(Document.Note)
	notes = |tree, context| {
		interpreted = Mce.process(tree).interpreted
		within = reading(interpreted, context)
		note_elements(interpreted).map(
			|element| {
				kind = match value_of(element, "type") {
					Ok("separator") => Separator
					Ok("continuationSeparator") => ContinuationSeparator
					Ok("continuationNotice") => ContinuationNotice
					_ => Note
				}
				{ kind, content: blocks(element.children, within, []).blocks }
			},
		)
	}

	## The identifiers of a footnotes or endnotes part's notes, in the order
	## [WmlRead.notes] reads them; a note without one has the empty string.
	note_ids : XmlTree.Node -> List(Str)
	note_ids = |tree| note_elements(Mce.process(tree).interpreted).map(|element| value_of(element, "id") ?? "")

	## Something the reader accepted that the schema does not allow: a number
	## the schema wants whole written with a fraction, such as the width
	## `w:w="10470.0"` that Google Docs exports write, or a percentage finer
	## than the fiftieths of a per cent the model holds, read rounded to the
	## nearest, halves away from zero. `element` and `attribute` are the local
	## names of the WordprocessingML element and attribute, and `value` is the
	## value as the document wrote it.
	Diagnostic : [Rounded({ element : Str, attribute : Str, value : Str })]

	## A paragraph's properties from the children of its `w:pPr`, or of a
	## style's or the document defaults' `w:pPr`. Each modelled property is
	## read from its first element; an element whose attributes or children
	## the model cannot represent, a repeated one and every other element are
	## kept in `preserved` as they were read, in order. On and off values
	## take every spelling the schema allows (`true`, `1`, `on` and their
	## opposites, and no value for on).
	paragraph_properties : List(XmlTree.Node) -> Document.ParagraphProperties
	paragraph_properties = |nodes| {
		var $properties = Document.no_paragraph_properties
		var $taken = List.with_capacity(8)
		for node in nodes {
			match node {
				Element(element) if element.name.namespace == Uri(wordprocessingml) and !$taken.contains(element.name.local) =>
					match paragraph_property($properties, element) {
						Ok(next) => {
							$properties = next
							$taken = List.append($taken, element.name.local)
						}

						Err(CannotHold) => {
							$properties = { ..$properties, preserved: List.append($properties.preserved, node) }
						}
					}

				_ => {
					if is_content(node) {
						$properties = { ..$properties, preserved: List.append($properties.preserved, node) }
					}
				}
			}
		}
		$properties
	}

	## A run's properties from the children of its `w:rPr`, or of a style's
	## or the document defaults' `w:rPr`, read as
	## [WmlRead.paragraph_properties] reads a paragraph's.
	run_properties : List(XmlTree.Node) -> Document.RunProperties
	run_properties = |nodes| {
		var $properties = Document.no_run_properties
		var $taken = List.with_capacity(8)
		for node in nodes {
			match node {
				Element(element) if element.name.namespace == Uri(wordprocessingml) and !$taken.contains(element.name.local) =>
					match run_property($properties, element) {
						Ok(next) => {
							$properties = next
							$taken = List.append($taken, element.name.local)
						}

						Err(CannotHold) => {
							$properties = { ..$properties, preserved: List.append($properties.preserved, node) }
						}
					}

				_ => {
					if is_content(node) {
						$properties = { ..$properties, preserved: List.append($properties.preserved, node) }
					}
				}
			}
		}
		$properties
	}
}

# What reading a part looks up: its relationships and its bookmarks' names by
# identifier, and each note's place by identifier.
Reading : {
	relationships : Dict(Str, Opc.Relationship),
	bookmarks : Dict(Str, Str),
	footnotes : Dict(Str, U64),
	endnotes : Dict(Str, U64),
}

reading : XmlTree.Node, WmlRead.Context -> Reading
reading = |interpreted, context| {
	var $relationships = Dict.with_capacity(context.relationships.len())
	for relationship in context.relationships {
		$relationships = $relationships.insert(relationship.id, relationship)
	}
	{ relationships: $relationships, bookmarks: bookmark_names(interpreted), footnotes: places(context.footnotes), endnotes: places(context.endnotes) }
}

places : List(Str) -> Dict(Str, U64)
places = |ids| {
	var $places = Dict.with_capacity(ids.len())
	var $index = 0.U64
	for id in ids {
		$places = $places.insert(id, $index)
		$index = $index + 1
	}
	$places
}

# The names of a tree's bookmarks by identifier, from every start that has
# both, outside runs and property elements of any namespace, where bookmarks
# never are. The tree is walked as deep as the readers walk it, within the
# XML depth limit, without copying any list of children, and names are
# compared by local name first, as comparing a namespace costs an
# allocation.
bookmark_names : XmlTree.Node -> Dict(Str, Str)
bookmark_names = |root| names_in(Dict.with_capacity(0), root)

names_in : Dict(Str, Str), XmlTree.Node -> Dict(Str, Str)
names_in = |names, node|
	match node {
		Element(element) if element.name.local == "bookmarkStart" and is_w(element.name, "bookmarkStart") =>
			match (value_of(element, "id"), value_of(element, "name")) {
				(Ok(id), Ok(name)) => names.insert(id, name)
				_ => names
			}

		Element(element) if element.name.local == "r" or element.name.local.ends_with("Pr") => names
		Element(element) => element.children.fold(names, names_in)
		Text(_) => names
	}

# The note elements of a footnotes or endnotes part's root.
note_elements : XmlTree.Node -> List(Element)
note_elements = |root|
	match root {
		Element(element) if is_w(element.name, "footnotes") or is_w(element.name, "endnotes") =>
			element.children.keep_oks(
				|child|
					match child {
						Element(note) if is_w(note.name, "footnote") or is_w(note.name, "endnote") => Ok(note)
						_ => Err(NotANote)
					},
			)

		_ => []
	}

# One paragraph property element read into the properties, or `CannotHold`
# when the model cannot represent it.
paragraph_property : Document.ParagraphProperties, Element -> Try(Document.ParagraphProperties, [CannotHold])
paragraph_property = |properties, element|
	match element.name.local {
		"pStyle" => Ok({ ..properties, style: Style(only_value(element)?) })
		"keepNext" => Ok({ ..properties, keep_next: on_off(element)? })
		"keepLines" => Ok({ ..properties, keep_lines: on_off(element)? })
		"pageBreakBefore" => Ok({ ..properties, page_break_before: on_off(element)? })
		"widowControl" => Ok({ ..properties, widow_control: on_off(element)? })
		"outlineLvl" => {
			level = U8.from_str(only_value(element)?) ? |_| CannotHold
			if level > 9 {
				Err(CannotHold)
			} else {
				Ok({ ..properties, outline_level: Level(level) })
			}
		}

		"jc" => Ok({ ..properties, alignment: Aligned(paragraph_alignment(only_value(element)?)?) })
		"ind" => {
			leaf(element, ["left", "right", "firstLine", "hanging"])?
			first_line = match (value_of(element, "firstLine"), value_of(element, "hanging")) {
				(Err(NotFound), Err(NotFound)) => Unset
				(Ok(value), Err(NotFound)) => FirstLine(signed(value)?)
				(Err(NotFound), Ok(value)) => Hanging(signed(value)?)
				_ => return Err(CannotHold)
			}
			Ok({ ..properties, indentation: { left: twips_attribute(element, "left")?, right: twips_attribute(element, "right")?, first_line } })
		}

		"spacing" => {
			leaf(element, ["before", "after", "line", "lineRule"])?
			line = match (value_of(element, "line"), value_of(element, "lineRule")) {
				(Err(NotFound), Err(NotFound)) => Unset
				(Ok(value), Err(NotFound)) => Auto(signed(value)?)
				(Ok(value), Ok("auto")) => Auto(signed(value)?)
				(Ok(value), Ok("exact")) => Exact(signed(value)?)
				(Ok(value), Ok("atLeast")) => AtLeast(signed(value)?)
				_ => return Err(CannotHold)
			}
			Ok({ ..properties, spacing: { before: unsigned_attribute(element, "before")?, after: unsigned_attribute(element, "after")?, line } })
		}

		"pBdr" => {
			read = borders(element, paragraph_edges)?
			if read.noticed.is_empty() {
				Ok({ ..properties, borders: read.value })
			} else {
				Err(CannotHold)
			}
		}

		"shd" => Ok({ ..properties, shading: shading(element)? })

		"tabs" => {
			if !element.attributes.is_empty() {
				return Err(CannotHold)
			}
			var $stops = List.with_capacity(element.children.len())
			for child in element.children {
				match child {
					Element(stop) if is_w(stop.name, "tab") => {
						$stops = List.append($stops, tab_stop(stop)?)
					}

					_ => {
						if is_content(child) {
							return Err(CannotHold)
						}
					}
				}
			}
			if $stops.is_empty() {
				Err(CannotHold)
			} else {
				Ok({ ..properties, tabs: Tabs($stops) })
			}
		}

		"numPr" => {
			if !element.attributes.is_empty() {
				return Err(CannotHold)
			}
			var $numbering = properties.numbering
			var $seen = List.with_capacity(2)
			for child in element.children {
				match child {
					Element(part) if part.name.namespace == Uri(wordprocessingml) and !$seen.contains(part.name.local) => {
						value = only_value(part)?
						$numbering = match part.name.local {
							"numId" => { ..$numbering, instance: Instance(U32.from_str(value) ? |_| CannotHold) }
							"ilvl" => { ..$numbering, level: Level(U8.from_str(value) ? |_| CannotHold) }
							_ => return Err(CannotHold)
						}
						$seen = List.append($seen, part.name.local)
					}

					_ => {
						if is_content(child) {
							return Err(CannotHold)
						}
					}
				}
			}
			Ok({ ..properties, numbering: $numbering })
		}

		_ => Err(CannotHold)
	}

# One run property element read into the properties, or `CannotHold` when
# the model cannot represent it.
run_property : Document.RunProperties, Element -> Try(Document.RunProperties, [CannotHold])
run_property = |properties, element|
	match element.name.local {
		"rStyle" => Ok({ ..properties, style: Style(only_value(element)?) })
		"b" => Ok({ ..properties, bold: on_off(element)? })
		"i" => Ok({ ..properties, italic: on_off(element)? })
		"caps" => Ok({ ..properties, caps: on_off(element)? })
		"smallCaps" => Ok({ ..properties, small_caps: on_off(element)? })
		"strike" => Ok({ ..properties, strike: on_off(element)? })
		"dstrike" => Ok({ ..properties, double_strike: on_off(element)? })
		"vanish" => Ok({ ..properties, hidden: on_off(element)? })
		"u" => Ok({ ..properties, underline: Underline(underline(only_value(element)?)?) })
		"vertAlign" => {
			value = match only_value(element)? {
				"baseline" => Baseline
				"superscript" => Superscript
				"subscript" => Subscript
				_ => return Err(CannotHold)
			}
			Ok({ ..properties, vertical_align: value })
		}

		"color" => {
			leaf(element, ["val", "themeColor", "themeTint", "themeShade"])?
			value = match value_of(element, "val") {
				Ok("auto") => Auto
				Ok(rgb) => Rgb(rgb)
				Err(NotFound) => return Err(CannotHold)
			}
			theme = match value_of(element, "themeColor") {
				Ok(name) => Theme(name)
				Err(NotFound) => Unset
			}
			tint = match value_of(element, "themeTint") {
				Ok(amount) => Tint(amount)
				Err(NotFound) => Unset
			}
			shade = match value_of(element, "themeShade") {
				Ok(amount) => Shade(amount)
				Err(NotFound) => Unset
			}
			Ok({ ..properties, color: Color({ value, theme, tint, shade }) })
		}

		"highlight" => Ok({ ..properties, highlight: Highlight(highlight(only_value(element)?)?) })
		"sz" => Ok({ ..properties, size: HalfPoints(U32.from_str(only_value(element)?) ? |_| CannotHold) })
		"rFonts" => {
			leaf(element, ["ascii", "hAnsi", "eastAsia", "cs", "asciiTheme", "hAnsiTheme", "eastAsiaTheme", "cstheme"])?
			fonts = {
				ascii: named(element, "ascii"),
				high_ansi: named(element, "hAnsi"),
				east_asia: named(element, "eastAsia"),
				complex: named(element, "cs"),
				ascii_theme: theme_font(element, "asciiTheme")?,
				high_ansi_theme: theme_font(element, "hAnsiTheme")?,
				east_asia_theme: theme_font(element, "eastAsiaTheme")?,
				complex_theme: theme_font(element, "cstheme")?,
			}
			Ok({ ..properties, fonts: fonts })
		}

		"lang" => {
			leaf(element, ["val", "eastAsia", "bidi"])?
			Ok({ ..properties, language: { latin: language_tag(element, "val"), east_asia: language_tag(element, "eastAsia"), complex: language_tag(element, "bidi") } })
		}

		_ => Err(CannotHold)
	}

# An element with only WordprocessingML attributes among these names and no
# content.
leaf : Element, List(Str) -> Try({}, [CannotHold])
leaf = |element, locals|
	if holds(element, locals) and !element.children.any(is_content) {
		Ok({})
	} else {
		Err(CannotHold)
	}

# The `w:val` of an element that has only that attribute and no content.
only_value : Element -> Try(Str, [CannotHold])
only_value = |element| {
	leaf(element, ["val"])?
	Ok(value_of(element, "val") ? |_| CannotHold)
}

signed : Str -> Try(I32, [CannotHold])
signed = |value| Ok(I32.from_str(value) ? |_| CannotHold)

twips_attribute : Element, Str -> Try([Unset, Twips(I32)], [CannotHold])
twips_attribute = |element, local|
	match value_of(element, local) {
		Ok(value) => Ok(Twips(signed(value)?))
		Err(NotFound) => Ok(Unset)
	}

unsigned_attribute : Element, Str -> Try([Unset, Twips(U32)], [CannotHold])
unsigned_attribute = |element, local|
	match value_of(element, local) {
		Ok(value) => Ok(Twips(U32.from_str(value) ? |_| CannotHold))
		Err(NotFound) => Ok(Unset)
	}

named : Element, Str -> [Unset, Named(Str)]
named = |element, local|
	match value_of(element, local) {
		Ok(name) => Named(name)
		Err(NotFound) => Unset
	}

language_tag : Element, Str -> [Unset, Tag(Str)]
language_tag = |element, local|
	match value_of(element, local) {
		Ok(tag) => Tag(tag)
		Err(NotFound) => Unset
	}

tab_stop : Element -> Try(Document.TabStop, [CannotHold])
tab_stop = |element| {
	leaf(element, ["val", "pos", "leader"])?
	kind = match value_of(element, "val") {
		Ok("clear") => Clear
		Ok("start") => Start
		Ok("end") => End
		Ok("left") => Left
		Ok("right") => Right
		Ok("center") => Center
		Ok("decimal") => Decimal
		Ok("bar") => Bar
		Ok("num") => Num
		_ => return Err(CannotHold)
	}
	leader = match value_of(element, "leader") {
		Err(NotFound) => Unset
		Ok("none") => NoLeader
		Ok("dot") => Dot
		Ok("hyphen") => Hyphen
		Ok("underscore") => Underscore
		Ok("heavy") => Heavy
		Ok("middleDot") => MiddleDot
		Ok(_) => return Err(CannotHold)
	}
	position = signed(value_of(element, "pos") ? |_| CannotHold)?
	Ok({ kind, position, leader })
}

paragraph_alignment : Str -> Try(Document.Alignment, [CannotHold])
paragraph_alignment = |value|
	match value {
		"start" => Ok(Start)
		"end" => Ok(End)
		"left" => Ok(Left)
		"right" => Ok(Right)
		"center" => Ok(Center)
		"both" => Ok(Both)
		"distribute" => Ok(Distribute)
		"mediumKashida" => Ok(MediumKashida)
		"highKashida" => Ok(HighKashida)
		"lowKashida" => Ok(LowKashida)
		"thaiDistribute" => Ok(ThaiDistribute)
		"numTab" => Ok(NumTab)
		_ => Err(CannotHold)
	}

underline : Str -> Try(Document.Underline, [CannotHold])
underline = |value|
	match value {
		"single" => Ok(Single)
		"words" => Ok(Words)
		"double" => Ok(Double)
		"thick" => Ok(Thick)
		"dotted" => Ok(Dotted)
		"dottedHeavy" => Ok(DottedHeavy)
		"dash" => Ok(Dash)
		"dashedHeavy" => Ok(DashedHeavy)
		"dashLong" => Ok(DashLong)
		"dashLongHeavy" => Ok(DashLongHeavy)
		"dotDash" => Ok(DotDash)
		"dashDotHeavy" => Ok(DashDotHeavy)
		"dotDotDash" => Ok(DotDotDash)
		"dashDotDotHeavy" => Ok(DashDotDotHeavy)
		"wave" => Ok(Wave)
		"wavyHeavy" => Ok(WavyHeavy)
		"wavyDouble" => Ok(WavyDouble)
		"none" => Ok(NoUnderline)
		_ => Err(CannotHold)
	}

highlight : Str -> Try(Document.Highlight, [CannotHold])
highlight = |value|
	match value {
		"black" => Ok(Black)
		"blue" => Ok(Blue)
		"cyan" => Ok(Cyan)
		"green" => Ok(Green)
		"magenta" => Ok(Magenta)
		"red" => Ok(Red)
		"yellow" => Ok(Yellow)
		"white" => Ok(White)
		"darkBlue" => Ok(DarkBlue)
		"darkCyan" => Ok(DarkCyan)
		"darkGreen" => Ok(DarkGreen)
		"darkMagenta" => Ok(DarkMagenta)
		"darkRed" => Ok(DarkRed)
		"darkYellow" => Ok(DarkYellow)
		"darkGray" => Ok(DarkGray)
		"lightGray" => Ok(LightGray)
		"none" => Ok(NoHighlight)
		_ => Err(CannotHold)
	}

theme_font : Element, Str -> Try([Unset, Theme(Document.ThemeFont)], [CannotHold])
theme_font = |element, local|
	match value_of(element, local) {
		Err(NotFound) => Ok(Unset)
		Ok("majorEastAsia") => Ok(Theme(MajorEastAsia))
		Ok("majorBidi") => Ok(Theme(MajorBidi))
		Ok("majorAscii") => Ok(Theme(MajorAscii))
		Ok("majorHAnsi") => Ok(Theme(MajorHighAnsi))
		Ok("minorEastAsia") => Ok(Theme(MinorEastAsia))
		Ok("minorBidi") => Ok(Theme(MinorBidi))
		Ok("minorAscii") => Ok(Theme(MinorAscii))
		Ok("minorHAnsi") => Ok(Theme(MinorHighAnsi))
		Ok(_) => Err(CannotHold)
	}

# Elements whose content is blocks, read as containers in a block's place.
block_containers : List(Str)
block_containers = ["sdt", "sdtContent", "customXml"]

# Elements whose content is paragraph content, read as containers in an
# inline's place.
inline_containers : List(Str)
inline_containers = ["ins", "del", "moveFrom", "moveTo", "sdt", "sdtContent", "smartTag", "customXml", "dir", "bdo"]

# Block reading carries what it has noticed so far and gives it back with
# what it read.
blocks : List(XmlTree.Node), Reading, List(WmlRead.Diagnostic) -> { blocks : List(Document.Block), diagnostics : List(WmlRead.Diagnostic) }
blocks = |nodes, within, diagnostics| {
	var $out = List.with_capacity(nodes.len())
	var $diagnostics = diagnostics
	for node in nodes {
		if is_content(node) {
			read = block(node, within, $diagnostics)
			$out = List.append($out, read.block)
			$diagnostics = read.diagnostics
		}
	}
	{ blocks: $out, diagnostics: $diagnostics }
}

block : XmlTree.Node, Reading, List(WmlRead.Diagnostic) -> { block : Document.Block, diagnostics : List(WmlRead.Diagnostic) }
block = |node, within, diagnostics|
	match node {
		Element(element) if is_w(element.name, "p") => { block: Paragraph(paragraph(element.children, within)), diagnostics: diagnostics }
		Element(element) if is_w(element.name, "tbl") => {
			read = table(element.children, within, diagnostics)
			{ block: Table(read.table), diagnostics: read.diagnostics }
		}

		Element(element) if is_w_in(element.name, block_containers) => {
			read = blocks(element.children, within, diagnostics)
			{ block: Container({ element: without_children(element), content: read.blocks }), diagnostics: read.diagnostics }
		}

		_ => { block: Preserved(node), diagnostics: diagnostics }
	}

table : List(XmlTree.Node), Reading, List(WmlRead.Diagnostic) -> { table : Document.Table, diagnostics : List(WmlRead.Diagnostic) }
table = |children, within, diagnostics| {
	var $properties = Err(Missing)
	var $grid = Err(Missing)
	var $content = List.with_capacity(children.len())
	var $diagnostics = diagnostics
	for child in children {
		match ($properties, $grid, child) {
			(Err(Missing), _, Element(element)) if is_w(element.name, "tblPr") => {
				read = table_properties(element.children, $diagnostics)
				$properties = Ok(read.properties)
				$diagnostics = read.diagnostics
			}

			(_, Err(Missing), Element(element)) if is_w(element.name, "tblGrid") => {
				read = grid(element.children, $diagnostics)
				$grid = Ok(read.grid)
				$diagnostics = read.diagnostics
			}

			_ => {
				if is_content(child) {
					read = table_content(child, within, $diagnostics)
					$content = List.append($content, read.content)
					$diagnostics = read.diagnostics
				}
			}
		}
	}
	properties = $properties ?? { style: Unset, width: Unset, borders: [], shading: Unset, preserved: [] }
	{ table: { properties, grid: $grid ?? [], content: $content }, diagnostics: $diagnostics }
}

table_content : XmlTree.Node, Reading, List(WmlRead.Diagnostic) -> { content : Document.TableContent, diagnostics : List(WmlRead.Diagnostic) }
table_content = |node, within, diagnostics|
	match node {
		Element(element) if is_w(element.name, "tr") => {
			read = row(element.children, within, diagnostics)
			{ content: Row(read.row), diagnostics: read.diagnostics }
		}

		Element(element) if is_w_in(element.name, block_containers) => {
			var $content = List.with_capacity(element.children.len())
			var $diagnostics = diagnostics
			for child in element.children {
				if is_content(child) {
					read = table_content(child, within, $diagnostics)
					$content = List.append($content, read.content)
					$diagnostics = read.diagnostics
				}
			}
			{ content: Container({ element: without_children(element), content: $content }), diagnostics: $diagnostics }
		}

		_ => { content: Preserved(node), diagnostics: diagnostics }
	}

row : List(XmlTree.Node), Reading, List(WmlRead.Diagnostic) -> { row : Document.Row, diagnostics : List(WmlRead.Diagnostic) }
row = |children, within, diagnostics| {
	var $properties = Err(Missing)
	var $content = List.with_capacity(children.len())
	var $diagnostics = diagnostics
	for child in children {
		match ($properties, child) {
			(Err(Missing), Element(element)) if is_w(element.name, "trPr") => {
				read = row_properties(element.children, $diagnostics)
				$properties = Ok(read.properties)
				$diagnostics = read.diagnostics
			}

			_ => {
				if is_content(child) {
					read = row_content(child, within, $diagnostics)
					$content = List.append($content, read.content)
					$diagnostics = read.diagnostics
				}
			}
		}
	}
	properties = $properties ?? { header: Unset, grid_before: Unset, grid_after: Unset, preserved: [] }
	{ row: { properties, content: $content }, diagnostics: $diagnostics }
}

row_content : XmlTree.Node, Reading, List(WmlRead.Diagnostic) -> { content : Document.RowContent, diagnostics : List(WmlRead.Diagnostic) }
row_content = |node, within, diagnostics|
	match node {
		Element(element) if is_w(element.name, "tc") => {
			read = cell(element.children, within, diagnostics)
			{ content: Cell(read.cell), diagnostics: read.diagnostics }
		}

		Element(element) if is_w_in(element.name, block_containers) => {
			var $content = List.with_capacity(element.children.len())
			var $diagnostics = diagnostics
			for child in element.children {
				if is_content(child) {
					read = row_content(child, within, $diagnostics)
					$content = List.append($content, read.content)
					$diagnostics = read.diagnostics
				}
			}
			{ content: Container({ element: without_children(element), content: $content }), diagnostics: $diagnostics }
		}

		_ => { content: Preserved(node), diagnostics: diagnostics }
	}

cell : List(XmlTree.Node), Reading, List(WmlRead.Diagnostic) -> { cell : Document.Cell, diagnostics : List(WmlRead.Diagnostic) }
cell = |children, within, diagnostics| {
	var $properties = Err(Missing)
	var $content = List.with_capacity(children.len())
	var $diagnostics = diagnostics
	for child in children {
		match ($properties, child) {
			(Err(Missing), Element(element)) if is_w(element.name, "tcPr") => {
				read = cell_properties(element.children, $diagnostics)
				$properties = Ok(read.properties)
				$diagnostics = read.diagnostics
			}

			_ => {
				if is_content(child) {
					read = block(child, within, $diagnostics)
					$content = List.append($content, read.block)
					$diagnostics = read.diagnostics
				}
			}
		}
	}
	properties = $properties ?? { width: Unset, span: Unset, merge: Unset, borders: [], shading: Unset, alignment: Unset, preserved: [] }
	{ cell: { properties, content: $content }, diagnostics: $diagnostics }
}

# A grid column is a `w:gridCol` whose only attribute is its width.
grid : List(XmlTree.Node), List(WmlRead.Diagnostic) -> { grid : List(Document.GridColumn), diagnostics : List(WmlRead.Diagnostic) }
grid = |children, diagnostics| {
	var $columns = List.with_capacity(children.len())
	var $diagnostics = diagnostics
	for child in kept(children) {
		read = match child {
			Element(element) if is_w(element.name, "gridCol") and holds(element, ["w"]) => unsigned(element, "w")
			_ => Err(CannotHold)
		}
		match read {
			Ok({ value, noticed }) => {
				$columns = List.append($columns, Column(value))
				$diagnostics = List.concat($diagnostics, noticed)
			}

			Err(CannotHold) => {
				$columns = List.append($columns, Preserved(child))
			}
		}
	}
	{ grid: $columns, diagnostics: $diagnostics }
}

table_properties : List(XmlTree.Node), List(WmlRead.Diagnostic) -> { properties : Document.TableProperties, diagnostics : List(WmlRead.Diagnostic) }
table_properties = |children, diagnostics| {
	var $properties = { style: Unset, width: Unset, borders: [], shading: Unset, preserved: List.with_capacity(children.len()) }
	var $diagnostics = diagnostics
	for child in kept(children) {
		match child {
			Element(element) if is_w(element.name, "tblStyle") and $properties.style == Unset and holds(element, ["val"]) =>
				match value_of(element, "val") {
					Ok(id) => {
						$properties = { ..$properties, style: Style(id) }
					}

					Err(NotFound) => {
						$properties = { ..$properties, preserved: List.append($properties.preserved, child) }
					}
				}

			Element(element) if is_w(element.name, "tblW") and $properties.width == Unset =>
				match width(element) {
					Ok({ value, noticed }) => {
						$properties = { ..$properties, width: value }
						$diagnostics = List.concat($diagnostics, noticed)
					}

					Err(CannotHold) => {
						$properties = { ..$properties, preserved: List.append($properties.preserved, child) }
					}
				}

			Element(element) if is_w(element.name, "tblBorders") and $properties.borders.is_empty() =>
				match borders(element, table_edges) {
					Ok({ value, noticed }) => {
						$properties = { ..$properties, borders: value }
						$diagnostics = List.concat($diagnostics, noticed)
					}

					Err(CannotHold) => {
						$properties = { ..$properties, preserved: List.append($properties.preserved, child) }
					}
				}

			Element(element) if is_w(element.name, "shd") and $properties.shading == Unset =>
				match shading(element) {
					Ok(value) => {
						$properties = { ..$properties, shading: value }
					}

					Err(CannotHold) => {
						$properties = { ..$properties, preserved: List.append($properties.preserved, child) }
					}
				}

			_ => {
				$properties = { ..$properties, preserved: List.append($properties.preserved, child) }
			}
		}
	}
	{ properties: $properties, diagnostics: $diagnostics }
}

row_properties : List(XmlTree.Node), List(WmlRead.Diagnostic) -> { properties : Document.RowProperties, diagnostics : List(WmlRead.Diagnostic) }
row_properties = |children, diagnostics| {
	var $properties = { header: Unset, grid_before: Unset, grid_after: Unset, preserved: List.with_capacity(children.len()) }
	var $diagnostics = diagnostics
	for child in kept(children) {
		match child {
			Element(element) if is_w(element.name, "tblHeader") and $properties.header == Unset =>
				match on_off(element) {
					Ok(value) => {
						$properties = { ..$properties, header: value }
					}

					Err(CannotHold) => {
						$properties = { ..$properties, preserved: List.append($properties.preserved, child) }
					}
				}

			Element(element) if is_w(element.name, "gridBefore") and $properties.grid_before == Unset =>
				match columns(element) {
					Ok({ value, noticed }) => {
						$properties = { ..$properties, grid_before: value }
						$diagnostics = List.concat($diagnostics, noticed)
					}

					Err(CannotHold) => {
						$properties = { ..$properties, preserved: List.append($properties.preserved, child) }
					}
				}

			Element(element) if is_w(element.name, "gridAfter") and $properties.grid_after == Unset =>
				match columns(element) {
					Ok({ value, noticed }) => {
						$properties = { ..$properties, grid_after: value }
						$diagnostics = List.concat($diagnostics, noticed)
					}

					Err(CannotHold) => {
						$properties = { ..$properties, preserved: List.append($properties.preserved, child) }
					}
				}

			_ => {
				$properties = { ..$properties, preserved: List.append($properties.preserved, child) }
			}
		}
	}
	{ properties: $properties, diagnostics: $diagnostics }
}

cell_properties : List(XmlTree.Node), List(WmlRead.Diagnostic) -> { properties : Document.CellProperties, diagnostics : List(WmlRead.Diagnostic) }
cell_properties = |children, diagnostics| {
	var $properties = { width: Unset, span: Unset, merge: Unset, borders: [], shading: Unset, alignment: Unset, preserved: List.with_capacity(children.len()) }
	var $diagnostics = diagnostics
	for child in kept(children) {
		match child {
			Element(element) if is_w(element.name, "tcW") and $properties.width == Unset =>
				match width(element) {
					Ok({ value, noticed }) => {
						$properties = { ..$properties, width: value }
						$diagnostics = List.concat($diagnostics, noticed)
					}

					Err(CannotHold) => {
						$properties = { ..$properties, preserved: List.append($properties.preserved, child) }
					}
				}

			Element(element) if is_w(element.name, "gridSpan") and $properties.span == Unset =>
				match columns(element) {
					Ok({ value, noticed }) => {
						$properties = { ..$properties, span: value }
						$diagnostics = List.concat($diagnostics, noticed)
					}

					Err(CannotHold) => {
						$properties = { ..$properties, preserved: List.append($properties.preserved, child) }
					}
				}

			Element(element) if is_w(element.name, "vMerge") and $properties.merge == Unset =>
				match merge(element) {
					Ok(value) => {
						$properties = { ..$properties, merge: value }
					}

					Err(CannotHold) => {
						$properties = { ..$properties, preserved: List.append($properties.preserved, child) }
					}
				}

			Element(element) if is_w(element.name, "tcBorders") and $properties.borders.is_empty() =>
				match borders(element, cell_edges) {
					Ok({ value, noticed }) => {
						$properties = { ..$properties, borders: value }
						$diagnostics = List.concat($diagnostics, noticed)
					}

					Err(CannotHold) => {
						$properties = { ..$properties, preserved: List.append($properties.preserved, child) }
					}
				}

			Element(element) if is_w(element.name, "shd") and $properties.shading == Unset =>
				match shading(element) {
					Ok(value) => {
						$properties = { ..$properties, shading: value }
					}

					Err(CannotHold) => {
						$properties = { ..$properties, preserved: List.append($properties.preserved, child) }
					}
				}

			Element(element) if is_w(element.name, "vAlign") and $properties.alignment == Unset =>
				match alignment(element) {
					Ok(value) => {
						$properties = { ..$properties, alignment: value }
					}

					Err(CannotHold) => {
						$properties = { ..$properties, preserved: List.append($properties.preserved, child) }
					}
				}

			_ => {
				$properties = { ..$properties, preserved: List.append($properties.preserved, child) }
			}
		}
	}
	{ properties: $properties, diagnostics: $diagnostics }
}

# A value read from a property element, with what reading it noticed.
Read(a) : { value : a, noticed : List(WmlRead.Diagnostic) }

# A preferred width: `w:type` is `auto`, `nil`, `dxa` (twips, the default)
# or `pct`, fiftieths of a per cent or a percentage written with `%`. An
# automatic or zero width with a non-zero `w:w` cannot be held.
width : Element -> Try(Read(Document.Width), [CannotHold])
width = |element| {
	if !holds(element, ["w", "type"]) {
		return Err(CannotHold)
	}
	match value_of(element, "type") {
		Ok("auto") => if (zero_or_absent(element)) Ok({ value: Auto, noticed: [] }) else Err(CannotHold)
		Ok("nil") => if (zero_or_absent(element)) Ok({ value: Nil, noticed: [] }) else Err(CannotHold)
		Ok("pct") => {
			text = value_of(element, "w") ? |_| CannotHold
			if text.ends_with("%") {
				read = decimal(Str.drop_suffix(text, "%"), 50) ? |_| CannotHold
				Ok({ value: Fiftieths(read.value), noticed: if (read.exact) [] else [rounded(element, "w", text)] })
			} else {
				read = whole(element, "w")?
				Ok({ value: Fiftieths(read.value), noticed: read.noticed })
			}
		}

		Ok("dxa") | Err(NotFound) => {
			read = whole(element, "w")?
			Ok({ value: Twips(read.value), noticed: read.noticed })
		}

		Ok(_) => Err(CannotHold)
	}
}

zero_or_absent : Element -> Bool
zero_or_absent = |element|
	match value_of(element, "w") {
		Ok(text) => decimal(text, 1).map_ok(|read| read.value) == Ok(0)
		Err(NotFound) => Bool.True
	}

# A count of grid columns in `w:val`.
columns : Element -> Try(Read([Unset, Columns(U64)]), [CannotHold])
columns = |element| {
	if !holds(element, ["val"]) {
		return Err(CannotHold)
	}
	read = unsigned(element, "val")?
	Ok({ value: Columns(read.value), noticed: read.noticed })
}

# An on or off property: no `w:val` is on.
on_off : Element -> Try([Unset, On, Off], [CannotHold])
on_off = |element| {
	if !holds(element, ["val"]) {
		return Err(CannotHold)
	}
	match value_of(element, "val") {
		Err(NotFound) | Ok("true") | Ok("1") | Ok("on") => Ok(On)
		Ok("false") | Ok("0") | Ok("off") => Ok(Off)
		Ok(_) => Err(CannotHold)
	}
}

# A vertical merge: no `w:val` continues the merge above.
merge : Element -> Try([Unset, Restart, Continue], [CannotHold])
merge = |element| {
	if !holds(element, ["val"]) {
		return Err(CannotHold)
	}
	match value_of(element, "val") {
		Ok("restart") => Ok(Restart)
		Err(NotFound) | Ok("continue") => Ok(Continue)
		Ok(_) => Err(CannotHold)
	}
}

alignment : Element -> Try([Unset, Top, Center, Bottom, Both], [CannotHold])
alignment = |element| {
	if !holds(element, ["val"]) {
		return Err(CannotHold)
	}
	match value_of(element, "val") {
		Ok("top") => Ok(Top)
		Ok("center") => Ok(Center)
		Ok("bottom") => Ok(Bottom)
		Ok("both") => Ok(Both)
		_ => Err(CannotHold)
	}
}

paragraph_edges : List(Str)
paragraph_edges = ["top", "left", "bottom", "right", "between", "bar"]

table_edges : List(Str)
table_edges = ["top", "left", "start", "bottom", "right", "end", "insideH", "insideV"]

cell_edges : List(Str)
cell_edges = ["top", "left", "start", "bottom", "right", "end", "insideH", "insideV", "tl2br", "tr2bl"]

# Borders the model holds only whole: an element with no edges, an edge it
# does not allow, or an edge with attributes beyond its line, width, space
# and colour, such as a theme colour, is kept as it was read.
borders : Element, List(Str) -> Try(Read(List(Document.Border)), [CannotHold])
borders = |element, allowed| {
	if !element.attributes.is_empty() {
		return Err(CannotHold)
	}
	var $borders = List.with_capacity(element.children.len())
	var $noticed = List.with_capacity(0)
	for child in kept(element.children) {
		match child {
			Element(edge_element) if is_w_in(edge_element.name, allowed) and holds(edge_element, ["val", "sz", "space", "color"]) => {
				line = value_of(edge_element, "val") ? |_| CannotHold
				size = match value_of(edge_element, "sz") {
					Ok(_) => {
						read = unsigned(edge_element, "sz")?
						$noticed = List.concat($noticed, read.noticed)
						Eighths(read.value)
					}

					Err(NotFound) => Unset
				}
				space = match value_of(edge_element, "space") {
					Ok(_) => {
						read = unsigned(edge_element, "space")?
						$noticed = List.concat($noticed, read.noticed)
						Points(read.value)
					}

					Err(NotFound) => Unset
				}
				$borders = List.append($borders, { edge: edge(edge_element.name.local), line, size, space, color: color(edge_element, "color")? })
			}

			_ => {
				return Err(CannotHold)
			}
		}
	}
	if $borders.is_empty() {
		Err(CannotHold)
	} else {
		Ok({ value: $borders, noticed: $noticed })
	}
}

edge : Str -> [Top, Left, Start, Bottom, Right, End, InsideHorizontal, InsideVertical, DiagonalDown, DiagonalUp, Between, Bar]
edge = |local|
	match local {
		"left" => Left
		"start" => Start
		"bottom" => Bottom
		"right" => Right
		"end" => End
		"insideH" => InsideHorizontal
		"insideV" => InsideVertical
		"tl2br" => DiagonalDown
		"tr2bl" => DiagonalUp
		"between" => Between
		"bar" => Bar
		_ => Top
	}

# A shading with its pattern and, if it gives them, its colour and fill;
# theme colours cannot be held.
shading : Element -> Try(Document.Shading, [CannotHold])
shading = |element| {
	if !holds(element, ["val", "color", "fill"]) {
		return Err(CannotHold)
	}
	pattern = value_of(element, "val") ? |_| CannotHold
	Ok(Shading({ pattern, color: color(element, "color")?, fill: color(element, "fill")? }))
}

# A colour attribute: `auto` or six hexadecimal digits.
color : Element, Str -> Try(Document.Color, [CannotHold])
color = |element, local|
	match value_of(element, local) {
		Err(NotFound) => Ok(Unset)
		Ok("auto") => Ok(Auto)
		Ok(text) =>
			if text.to_utf8().len() == 6 and text.to_utf8().all(|byte| hex_digit(byte).is_ok()) {
				Ok(Rgb(text))
			} else {
				Err(CannotHold)
			}
	}

# Whether every attribute of an element is a WordprocessingML one of these.
holds : Element, List(Str) -> Bool
holds = |element, locals| element.attributes.all(|attribute| is_w_in(attribute.name, locals))

# A whole number in an attribute, read leniently: a value written with a
# fraction is rounded, and noticed.
whole : Element, Str -> Try(Read(I64), [CannotHold])
whole = |element, local| {
	text = value_of(element, local) ? |_| CannotHold
	read = decimal(text, 1) ? |_| CannotHold
	Ok({ value: read.value, noticed: if (text.contains(".")) [rounded(element, local, text)] else [] })
}

unsigned : Element, Str -> Try(Read(U64), [CannotHold])
unsigned = |element, local| {
	read = whole(element, local)?
	if read.value < 0 {
		Err(CannotHold)
	} else {
		Ok({ value: read.value.to_u64_wrap(), noticed: read.noticed })
	}
}

rounded : Element, Str, Str -> WmlRead.Diagnostic
rounded = |element, local, text| Rounded({ element: element.name.local, attribute: local, value: text })

# A decimal number, an optional sign, digits and an optional fraction,
# multiplied by `factor` and rounded to the nearest whole number, halves away
# from zero; `exact` says nothing was rounded away. At most fifteen digits
# are read, so the value cannot overflow.
decimal : Str, U64 -> Try({ value : I64, exact : Bool }, [NotNumber])
decimal = |text, factor| {
	bytes = text.to_utf8()
	negative = bytes.first() == Ok('-')
	start = if (negative or bytes.first() == Ok('+')) 1 else 0
	var $mantissa = 0.U64
	var $scale = 1.U64
	var $digits = 0.U64
	var $point = Bool.False
	var $index = start
	while $index < bytes.len() {
		byte = bytes.get($index) ?? 0
		if byte == '.' and !$point {
			$point = Bool.True
		} else if byte >= '0' and byte <= '9' and $digits < 15 {
			$mantissa = $mantissa * 10 + (byte - '0').to_u64()
			$digits = $digits + 1
			if $point {
				$scale = $scale * 10
			}
		} else {
			return Err(NotNumber)
		}
		$index = $index + 1
	}
	if $digits == 0 or factor > 1_000 {
		return Err(NotNumber)
	}
	scaled = $mantissa * factor
	magnitude = scaled // $scale + (if (2 * (scaled % $scale) >= $scale) 1 else 0)
	value = magnitude.to_i64_wrap()
	Ok({ value: if (negative) -value else value, exact: scaled % $scale == 0 })
}

paragraph : List(XmlTree.Node), Reading -> Document.Paragraph
paragraph = |children, within| {
	var $properties = Err(Missing)
	var $content = List.with_capacity(children.len())
	for child in children {
		match ($properties, child) {
			(Err(Missing), Element(element)) if is_w(element.name, "pPr") => {
				$properties = Ok(WmlRead.paragraph_properties(element.children))
			}

			_ => {
				if is_content(child) {
					$content = List.append($content, inline(child, within))
				}
			}
		}
	}
	{ properties: $properties ?? Document.no_paragraph_properties, content: $content }
}

inlines : List(XmlTree.Node), Reading -> List(Document.Inline)
inlines = |nodes, within| {
	var $out = List.with_capacity(nodes.len())
	for node in nodes {
		if is_content(node) {
			$out = List.append($out, inline(node, within))
		}
	}
	$out
}

inline : XmlTree.Node, Reading -> Document.Inline
inline = |node, within|
	match node {
		Element(element) if is_w(element.name, "r") => Run(run(element.children, within))
		Element(element) if is_w(element.name, "hyperlink") => hyperlink(element, within) ?? container(element, within)
		Element(element) if is_w(element.name, "fldSimple") => simple_field(element, within) ?? container(element, within)
		Element(element) if is_w(element.name, "bookmarkStart") => bookmark_start(element) ?? Preserved(node)
		Element(element) if is_w(element.name, "bookmarkEnd") => bookmark_end(element, within) ?? Preserved(node)
		Element(element) if is_w_in(element.name, inline_containers) => container(element, within)
		_ => Preserved(node)
	}

container : Element, Reading -> Document.Inline
container = |element, within| Container({ element: without_children(element), content: inlines(element.children, within) })

# A hyperlink: `r:id` names an external relationship, whose target is the
# address, and `w:anchor` a location in it, or a bookmark of the document
# when there is no `r:id`.
hyperlink : Element, Reading -> Try(Document.Inline, [Unresolved])
hyperlink = |element, within| {
	anchor = value_of(element, "anchor")
	target = match relationship_of(element, "id") {
		Ok(id) =>
			match (within.relationships.get(id), anchor) {
				(Ok({ id: _, kind: _, target: url, mode: External }), Ok(location)) => ExternalAt({ url, location })
				(Ok({ id: _, kind: _, target: url, mode: External }), Err(_)) => External(url)
				_ => return Err(Unresolved)
			}

		Err(_) =>
			match anchor {
				Ok(name) => Internal(name)
				Err(_) => return Err(Unresolved)
			}
	}
	preserved = element.attributes.drop_if(|attribute| is_w(attribute.name, "anchor") or is_r(attribute.name, "id"))
	Ok(Hyperlink({ target, preserved, content: inlines(element.children, within) }))
}

simple_field : Element, Reading -> Try(Document.Inline, [NoCode])
simple_field = |element, within| {
	code = value_of(element, "instr") ? |_| NoCode
	preserved = element.attributes.drop_if(|attribute| is_w(attribute.name, "instr"))
	Ok(SimpleField({ code, preserved, content: inlines(element.children, within) }))
}

bookmark_start : Element -> Try(Document.Inline, [Unknown])
bookmark_start = |element|
	if only(element, ["id", "name"]) {
		match (value_of(element, "id"), value_of(element, "name")) {
			(Ok(_), Ok(name)) => Ok(BookmarkStart(name))
			_ => Err(Unknown)
		}
	} else {
		Err(Unknown)
	}

bookmark_end : Element, Reading -> Try(Document.Inline, [Unknown])
bookmark_end = |element, within|
	if only(element, ["id"]) {
		id = value_of(element, "id") ? |_| Unknown
		Ok(BookmarkEnd(within.bookmarks.get(id) ? |_| Unknown))
	} else {
		Err(Unknown)
	}

run : List(XmlTree.Node), Reading -> Document.Run
run = |children, within| {
	var $properties = Err(Missing)
	var $content = List.with_capacity(children.len())
	for child in children {
		match ($properties, child) {
			(Err(Missing), Element(element)) if is_w(element.name, "rPr") => {
				$properties = Ok(WmlRead.run_properties(element.children))
			}

			_ => {
				if is_content(child) {
					$content = List.append($content, run_content(child, within))
				}
			}
		}
	}
	{ properties: $properties ?? Document.no_run_properties, content: $content }
}

run_content : XmlTree.Node, Reading -> Document.RunContent
run_content = |node, within|
	match node {
		Element(element) if element.name.namespace == Uri(wordprocessingml) =>
			match element.name.local {
				"t" => text(element).map_ok(|value| Text(value)) ?? Preserved(node)
				"tab" => Tab
				"br" => break_of(element) ?? Preserved(node)
				"cr" => Break({ kind: Line, clear: NoClear })
				"sym" => symbol(element) ?? Preserved(node)
				"softHyphen" => SoftHyphen
				"noBreakHyphen" => NonBreakingHyphen
				"footnoteReference" => note_reference(element, Footnote, within.footnotes) ?? Preserved(node)
				"endnoteReference" => note_reference(element, Endnote, within.endnotes) ?? Preserved(node)
				"footnoteRef" => NoteMark(Footnote)
				"endnoteRef" => NoteMark(Endnote)
				"fldChar" => field_mark(element, node) ?? Preserved(node)
				"instrText" => text(element).map_ok(|code| FieldCode(code)) ?? Preserved(node)
				"drawing" => picture(element, node, within) ?? Preserved(node)
				_ => Preserved(node)
			}

		_ => Preserved(node)
	}

# A note reference: `w:id` names a note of its part. A reference whose mark
# is the text that follows it, `w:customMarkFollows`, is not modelled.
note_reference : Element, Document.NoteKind, Dict(Str, U64) -> Try(Document.RunContent, [Unknown])
note_reference = |element, kind, notes|
	if only(element, ["id"]) {
		id = value_of(element, "id") ? |_| Unknown
		Ok(NoteReference({ kind, note: notes.get(id) ? |_| Unknown }))
	} else {
		Err(Unknown)
	}

field_mark : Element, XmlTree.Node -> Try(Document.RunContent, [Unknown])
field_mark = |element, node| {
	kind = match value_of(element, "fldCharType") {
		Ok("begin") => Begin
		Ok("separate") => Separate
		Ok("end") => End
		_ => return Err(Unknown)
	}
	Ok(FieldMark({ kind, element: node }))
}

# An inline picture: a drawing whose one element is `wp:inline`, with the
# `wp:extent` of its size and an `a:blip` embedding an image part of the
# package by `r:embed`.
picture : Element, XmlTree.Node, Reading -> Try(Document.RunContent, [NotPicture])
picture = |element, node, within| {
	inline_drawing = match element.children.keep_if(|child| is_content(child)) {
		[Element(child)] if child.name.namespace == Uri(drawing_namespace) and child.name.local == "inline" => child
		_ => return Err(NotPicture)
	}
	extent = inline_drawing.children.find_first(|child| is_named(child, drawing_namespace, "extent")) ? |_| NotPicture
	(across, down) = match extent {
		Element(sized) => (emus(unqualified(sized, "cx")) ? |_| NotPicture, emus(unqualified(sized, "cy")) ? |_| NotPicture)
		Text(_) => return Err(NotPicture)
	}
	id = embedded(Element(inline_drawing)) ? |_| NotPicture
	media = match within.relationships.get(id) {
		Ok({ id: _, kind: _, target, mode: Internal }) => target
		_ => return Err(NotPicture)
	}
	Ok(Picture({ media, size: { width: across, height: down }, drawing: node }))
}

# The `r:embed` of the first `a:blip` in a tree.
embedded : XmlTree.Node -> Try(Str, [NotFound])
embedded = |root| {
	var $pending = [root]
	while !$pending.is_empty() {
		match $pending.last() {
			Ok(Element(element)) => {
				if element.name.namespace == Uri(drawingml) and element.name.local == "blip" {
					return relationship_of(element, "embed")
				}
				$pending = List.drop_last($pending, 1)
				var $index = element.children.len()
				while $index > 0 {
					$index = $index - 1
					$pending = List.append($pending, element.children.get($index) ?? Text(""))
				}
			}

			_ => {
				$pending = List.drop_last($pending, 1)
			}
		}
	}
	Err(NotFound)
}

# A length in English Metric Units: decimal digits, at most nineteen.
emus : Try(Str, [NotFound]) -> Try(U64, [NotLength])
emus = |value| {
	digits = (value ? |_| NotLength).to_utf8()
	if digits.is_empty() or digits.len() > 19 {
		return Err(NotLength)
	}
	digits.fold(Ok(0.U64), |sum, digit| if (digit >= '0' and digit <= '9') Ok((sum?) * 10 + (digit - '0').to_u64()) else Err(NotLength))
}

# The text of `w:t` or `w:instrText`, which hold only character data. Unless
# the element says `xml:space="preserve"`, its whitespace is the producer's
# layout, as Word and LibreOffice read it: leading and trailing whitespace is
# removed, and each tab, carriage return and line feed left is a space.
text : Element -> Try(Str, [NotText])
text = |element| {
	var $value = List.with_capacity(16)
	for child in element.children {
		match child {
			Text(content) => {
				$value = List.concat($value, content.to_utf8())
			}

			Element(_) => {
				return Err(NotText)
			}
		}
	}
	preserve = element.attributes.any(|attribute| attribute.name.namespace == Uri(xml_namespace) and attribute.name.local == "space" and attribute.value == "preserve")
	value = if preserve {
		$value
	} else {
		var $start = 0.U64
		while $start < $value.len() and is_space($value.get($start) ?? 0) {
			$start = $start + 1
		}
		var $end = $value.len()
		while $end > $start and is_space($value.get($end - 1) ?? 0) {
			$end = $end - 1
		}
		$value.sublist({ start: $start, len: $end - $start }).map(|byte| if (is_space(byte)) 32 else byte)
	}
	Ok(Str.from_utf8(value) ?? "")
}

is_space : U8 -> Bool
is_space = |byte| byte == 32 or byte == 9 or byte == 10 or byte == 13

xml_namespace : Str
xml_namespace = "http://www.w3.org/XML/1998/namespace"

break_of : Element -> Try(Document.RunContent, [Unknown])
break_of = |element| {
	kind = match value_of(element, "type") {
		Err(NotFound) => Line
		Ok("textWrapping") => Line
		Ok("page") => Page
		Ok("column") => Column
		Ok(_) => return Err(Unknown)
	}
	clear = match value_of(element, "clear") {
		Err(NotFound) => NoClear
		Ok("none") => NoClear
		Ok("left") => Left
		Ok("right") => Right
		Ok("all") => All
		Ok(_) => return Err(Unknown)
	}
	Ok(Break({ kind, clear }))
}

# A symbol: `w:char` is four hexadecimal digits, and a symbol without a
# font is in the run's font, which the model names as "".
symbol : Element -> Try(Document.RunContent, [Unknown])
symbol = |element| {
	digits = (value_of(element, "char") ? |_| Unknown).to_utf8()
	if digits.len() != 4 {
		return Err(Unknown)
	}
	code = digits.fold(Ok(0.U16), |sum, digit| Ok((sum?) * 16 + (hex_digit(digit)?))) ? |_| Unknown
	Ok(Symbol({ font: value_of(element, "font") ?? "", code }))
}

hex_digit : U8 -> Try(U16, [NotHex])
hex_digit = |digit|
	if digit >= '0' and digit <= '9' {
		Ok((digit - '0').to_u16())
	} else if digit >= 'a' and digit <= 'f' {
		Ok((digit - 'a' + 10).to_u16())
	} else if digit >= 'A' and digit <= 'F' {
		Ok((digit - 'A' + 10).to_u16())
	} else {
		Err(NotHex)
	}

Element : { name : XmlTree.Name, bindings : List(XmlTree.Binding), attributes : List(XmlTree.Attribute), children : List(XmlTree.Node) }

wordprocessingml : Str
wordprocessingml = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

is_w : XmlTree.Name, Str -> Bool
is_w = |name, local| name.namespace == Uri(wordprocessingml) and name.local == local

is_w_in : XmlTree.Name, List(Str) -> Bool
is_w_in = |name, locals| name.namespace == Uri(wordprocessingml) and locals.contains(name.local)

is_element : XmlTree.Node, Str -> Bool
is_element = |node, local|
	match node {
		Element(element) => is_w(element.name, local)
		Text(_) => Bool.False
	}

# An element, or text that is not only whitespace.
is_content : XmlTree.Node -> Bool
is_content = |node|
	match node {
		Element(_) => Bool.True
		Text(content) => !content.to_utf8().all(|byte| byte == 32 or byte == 9 or byte == 10 or byte == 13)
	}

kept : List(XmlTree.Node) -> List(XmlTree.Node)
kept = |nodes| nodes.keep_if(is_content)

without_children : Element -> XmlTree.Node
without_children = |element| Element({ name: element.name, bindings: element.bindings, attributes: element.attributes, children: [] })

# The value of a WordprocessingML attribute of an element.
value_of : Element, Str -> Try(Str, [NotFound])
value_of = |element, local|
	element.attributes.find_first(|attribute| is_w(attribute.name, local)).map_ok(|attribute| attribute.value)

relationships_namespace : Str
relationships_namespace = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

drawing_namespace : Str
drawing_namespace = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"

drawingml : Str
drawingml = "http://schemas.openxmlformats.org/drawingml/2006/main"

is_r : XmlTree.Name, Str -> Bool
is_r = |name, local| name.namespace == Uri(relationships_namespace) and name.local == local

is_named : XmlTree.Node, Str, Str -> Bool
is_named = |node, namespace, local|
	match node {
		Element(element) => element.name.namespace == Uri(namespace) and element.name.local == local
		Text(_) => Bool.False
	}

# The value of a relationship attribute of an element, such as `r:id`.
relationship_of : Element, Str -> Try(Str, [NotFound])
relationship_of = |element, local|
	element.attributes.find_first(|attribute| is_r(attribute.name, local)).map_ok(|attribute| attribute.value)

# The value of an attribute in no namespace.
unqualified : Element, Str -> Try(Str, [NotFound])
unqualified = |element, local|
	element.attributes.find_first(|attribute| attribute.name.namespace == NoNamespace and attribute.name.local == local).map_ok(|attribute| attribute.value)

# Whether an element's attributes are all WordprocessingML attributes the
# model holds.
only : Element, List(Str) -> Bool
only = |element, locals| element.attributes.all(|attribute| is_w_in(attribute.name, locals))

# The blocks of a main document part with this body content.
read : Str -> List(Document.Block)
read = |content| read_in(content, { relationships: [], footnotes: [], endnotes: [] })

# The blocks of a main document part with this body content, in a package.
read_in : Str, WmlRead.Context -> List(Document.Block)
read_in = |content, context| {
	namespaces = "xmlns:w='${wordprocessingml}' xmlns:r='${relationships_namespace}' xmlns:wp='${drawing_namespace}' xmlns:a='${drawingml}'"
	tree = XmlTree.parse("<w:document ${namespaces}><w:body>${content}</w:body></w:document>".to_utf8(), {}) ?? Text("")
	WmlRead.body(tree, context)
}

# The properties of a `w:pPr` or `w:rPr` with this content.
properties_of : Str -> List(XmlTree.Node)
properties_of = |content|
	match XmlTree.parse("<w:pPr xmlns:w='${wordprocessingml}'>${content}</w:pPr>".to_utf8(), {}) {
		Ok(Element(element)) => element.children
		_ => []
	}

## Every modelled paragraph property is read, each from its first element,
## and what the model cannot hold is kept in order.
expect {
	border_xml = "<w:pBdr><w:top w:val='single' w:sz='4' w:space='1' w:color='auto'/><w:between w:val='double' w:sz='6'/></w:pBdr>"
	tabs = "<w:tabs><w:tab w:val='clear' w:pos='720'/><w:tab w:val='right' w:leader='dot' w:pos='9000'/></w:tabs>"
	stated = "<w:pStyle w:val='Quote'/><w:keepNext/><w:keepLines w:val='false'/><w:pageBreakBefore w:val='on'/><w:widowControl w:val='0'/><w:numPr><w:ilvl w:val='2'/><w:numId w:val='5'/></w:numPr>${border_xml}<w:shd w:val='clear' w:color='auto' w:fill='FFFF00'/>${tabs}<w:spacing w:before='120' w:after='60' w:line='360' w:lineRule='auto'/><w:ind w:left='720' w:right='-10' w:hanging='360'/><w:jc w:val='both'/><w:outlineLvl w:val='2'/>"
	unheld = "<w:keepNext w:val='false'/><w:spacing w:beforeLines='100'/><w:ind w:left='720.5'/><w:suppressAutoHyphens/><w:rPr><w:b/></w:rPr>"
	properties = WmlRead.paragraph_properties(properties_of("${stated}${unheld}"))
	expected : Document.ParagraphProperties
	expected = {
		style: Style("Quote"),
		alignment: Aligned(Both),
		indentation: { left: Twips(720), right: Twips(-10), first_line: Hanging(360) },
		spacing: { before: Twips(120), after: Twips(60), line: Auto(360) },
		keep_next: On,
		keep_lines: Off,
		page_break_before: On,
		widow_control: Off,
		outline_level: Level(2),
		borders: [
			{ edge: Top, line: "single", size: Eighths(4), space: Points(1), color: Auto },
			{ edge: Between, line: "double", size: Eighths(6), space: Unset, color: Unset },
		],
		shading: Shading({ pattern: "clear", color: Auto, fill: Rgb("FFFF00") }),
		tabs: Tabs([{ kind: Clear, position: 720, leader: Unset }, { kind: Right, position: 9000, leader: Dot }]),
		numbering: { instance: Instance(5), level: Level(2) },
		preserved: properties_of(unheld),
	}
	properties == expected
}

## Every modelled run property is read, and an element with attributes the
## model cannot hold, such as an underline colour or a font hint, is kept.
expect {
	stated = "<w:rStyle w:val='Emphasis'/><w:rFonts w:ascii='Aptos' w:hAnsi='Aptos' w:eastAsia='' w:asciiTheme='minorHAnsi' w:cstheme='majorBidi'/><w:b/><w:i w:val='0'/><w:caps/><w:smallCaps w:val='off'/><w:strike/><w:dstrike w:val='false'/><w:vanish/><w:color w:val='0F4761' w:themeColor='accent1' w:themeShade='BF'/><w:sz w:val='28'/><w:highlight w:val='darkYellow'/><w:u w:val='dottedHeavy'/><w:vertAlign w:val='subscript'/><w:lang w:val='en-GB' w:eastAsia='zh-CN'/>"
	unheld = "<w:u w:val='single' w:color='FF0000'/><w:bCs/><w:sz w:val='big'/>"
	properties = WmlRead.run_properties(properties_of("${stated}${unheld}"))
	expected : Document.RunProperties
	expected = {
		style: Style("Emphasis"),
		bold: On,
		italic: Off,
		caps: On,
		small_caps: Off,
		strike: On,
		double_strike: Off,
		hidden: On,
		underline: Underline(DottedHeavy),
		vertical_align: Subscript,
		color: Color({ value: Rgb("0F4761"), theme: Theme("accent1"), tint: Unset, shade: Shade("BF") }),
		highlight: Highlight(DarkYellow),
		size: HalfPoints(28),
		fonts: { ascii: Named("Aptos"), high_ansi: Named("Aptos"), east_asia: Named(""), complex: Unset, ascii_theme: Theme(MinorHighAnsi), high_ansi_theme: Unset, east_asia_theme: Unset, complex_theme: Theme(MajorBidi) },
		language: { latin: Tag("en-GB"), east_asia: Tag("zh-CN"), complex: Unset },
		preserved: properties_of(unheld),
	}
	properties == expected
}

## A run's text, tab, breaks, symbol and hyphens are read in order.
expect {
	run_xml = "<w:r><w:rPr><w:b/></w:rPr><w:t xml:space='preserve'>a </w:t><w:tab/><w:br/><w:br w:type='page'/><w:br w:type='column'/><w:br w:clear='all'/><w:cr/><w:sym w:font='Wingdings' w:char='F0E0'/><w:softHyphen/><w:noBreakHyphen/></w:r>"
	expected : List(Document.RunContent)
	expected = [
		Text("a "),
		Tab,
		Break({ kind: Line, clear: NoClear }),
		Break({ kind: Page, clear: NoClear }),
		Break({ kind: Column, clear: NoClear }),
		Break({ kind: Line, clear: All }),
		Break({ kind: Line, clear: NoClear }),
		Symbol({ font: "Wingdings", code: 0xF0E0 }),
		SoftHyphen,
		NonBreakingHyphen,
	]
	match read("<w:p>${run_xml}</w:p>") {
		[Paragraph({ properties, content: [Run(r)] })] => properties == Document.no_paragraph_properties and r.content == expected and r.properties == { ..Document.no_run_properties, bold: On }
		_ => Bool.False
	}
}

## Text keeps its whitespace where `xml:space="preserve"` says so; elsewhere
## leading and trailing whitespace is removed and tabs and line ends are
## spaces.
expect {
	match read("<w:p><w:r><w:t xml:space='preserve'> a\tb </w:t><w:t>  c  d\n\te  </w:t><w:t> </w:t></w:r></w:p>") {
		[Paragraph({ properties: _, content: [Run(r)] })] => r.content == [Text(" a\tb "), Text("c  d  e"), Text("")]
		_ => Bool.False
	}
}

## Run content the model cannot hold is kept as it was read, in its place:
## a break of an unknown type, a symbol without a code, text holding an
## element, and elements the model does not represent.
expect {
	odd = ["<w:br w:type='sideways'/>", "<w:sym w:font='Symbol'/>", "<w:t>a<w:b/></w:t>", "<w:footnoteReference w:id='1'/>", "<w:delText>gone</w:delText>"]
	match read("<w:p><w:r>${Str.join_with(odd, "<w:tab/>")}</w:r></w:p>") {
		[Paragraph({ properties: _, content: [Run(r)] })] =>
			r.content.len() == 9
				and r.content.get(1) == Ok(Tab)
				and r.content.keep_if(|content| content != Tab).all(
					|content|
						match content {
							Preserved(_) => Bool.True
							_ => Bool.False
						},
				)

		_ => Bool.False
	}
}

## Revisions and content controls keep their element and have their content
## read; comment ranges stay in their place.
expect {
	content = "<w:pPr><w:pStyle w:val='Body'/></w:pPr><w:commentRangeStart w:id='1'/><w:ins w:id='2' w:author='A'><w:r><w:t>new</w:t></w:r></w:ins><w:del w:id='3' w:author='A'><w:r><w:delText>old</w:delText></w:r></w:del><w:sdt><w:sdtPr/><w:sdtContent><w:r><w:t>field</w:t></w:r></w:sdtContent></w:sdt><w:commentRangeEnd w:id='1'/>"
	match read("<w:p>${content}</w:p>") {
		[Paragraph({ properties, content: [Preserved(_), Container(ins), Container(del), Container(sdt), Preserved(_)] })] =>
			properties == { ..Document.no_paragraph_properties, style: Style("Body") }
				and ins.content.len() == 1
				and del.content.len() == 1
				and match sdt.content {
					[Preserved(_), Container(inner)] => inner.content.len() == 1
					_ => Bool.False
				}
				and match ins.element {
					Element(element) => element.children.is_empty() and element.attributes.len() == 2
					Text(_) => Bool.False
				}

		_ => Bool.False
	}
}

## A hyperlink's target is its external relationship's address, with its
## location when it has one, or a bookmark; its other attributes are kept.
## One whose relationship is missing or internal, or that has no target, is
## a container of its content.
expect {
	relationships = [
		{ id: "rId1", kind: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink", target: "https://example.org/a b", mode: External },
		{ id: "rId2", kind: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles", target: "/word/styles.xml", mode: Internal },
	]
	link = |attributes| "<w:hyperlink ${attributes}><w:r><w:t>x</w:t></w:r></w:hyperlink>"
	links = [link("r:id='rId1' w:tooltip='Tip'"), link("r:id='rId1' w:anchor='part'"), link("w:anchor='terms' w:history='1'"), link("r:id='rId9'"), link("r:id='rId2'"), link("w:tgtFrame='_blank'")]
	match read_in("<w:p>${Str.join_with(links, "")}</w:p>", { relationships, footnotes: [], endnotes: [] }) {
		[Paragraph({ properties: _, content: [Hyperlink(external), Hyperlink(located), Hyperlink(internal), Container(missing), Container(part), Container(untargeted)] })] =>
			external.target == External("https://example.org/a b")
				and external.preserved.map(|attribute| attribute.value) == ["Tip"]
				and located.target == ExternalAt({ url: "https://example.org/a b", location: "part" })
				and located.preserved == []
				and internal.target == Internal("terms")
				and internal.preserved.map(|attribute| attribute.name.local) == ["history"]
				and external.content.len() == 1
				and [missing.content, part.content, untargeted.content].all(|content| content.len() == 1)

		_ => Bool.False
	}
}

## A bookmark's start and end are named by its name, wherever its start is;
## an end without a start and a bookmark spanning table columns are kept.
expect {
	content = "<w:p><w:bookmarkStart w:id='7' w:name='terms'/><w:r><w:t>a</w:t></w:r><w:bookmarkEnd w:id='5'/><w:bookmarkEnd w:id='9'/></w:p><w:p><w:bookmarkStart w:id='5' w:name='later'/><w:bookmarkEnd w:id='7'/><w:bookmarkStart w:id='8' w:name='c' w:colFirst='0' w:colLast='1'/></w:p>"
	match read(content) {
		[Paragraph(first), Paragraph(second)] =>
			match (first.content, second.content) {
				([BookmarkStart("terms"), Run(_), BookmarkEnd("later"), Preserved(_)], [BookmarkStart("later"), BookmarkEnd("terms"), Preserved(_)]) => Bool.True
				_ => Bool.False
			}

		_ => Bool.False
	}
}

## Note references name their note by its place among the notes; a
## reference to a missing note or with a custom mark is kept, and a note's
## own mark is read.
expect {
	run_xml = "<w:r><w:footnoteReference w:id='4'/><w:endnoteReference w:id='4'/><w:footnoteReference w:id='3'/><w:footnoteReference w:customMarkFollows='1' w:id='4'/><w:t>*</w:t><w:footnoteRef/><w:endnoteRef/></w:r>"
	match read_in("<w:p>${run_xml}</w:p>", { relationships: [], footnotes: ["-1", "0", "4"], endnotes: ["4"] }) {
		[Paragraph({ properties: _, content: [Run(r)] })] =>
			match r.content {
				[NoteReference(footnote), NoteReference(endnote), Preserved(_), Preserved(_), Text("*"), NoteMark(Footnote), NoteMark(Endnote)] =>
					footnote == { kind: Footnote, note: 2 } and endnote == { kind: Endnote, note: 0 }

				_ => Bool.False
			}

		_ => Bool.False
	}
}

## A complex field's marks keep their elements and its code is read as text;
## a simple field holds its code and its result as content.
expect {
	complex = "<w:r><w:fldChar w:fldCharType='begin' w:dirty='true'/></w:r><w:r><w:instrText xml:space='preserve'> PAGE </w:instrText></w:r><w:r><w:fldChar w:fldCharType='separate'/></w:r><w:r><w:t>3</w:t></w:r><w:r><w:fldChar w:fldCharType='end'/><w:fldChar w:fldCharType='sideways'/></w:r>"
	simple = "<w:fldSimple w:instr=' NUMPAGES ' w:fldLock='1'><w:r><w:t>9</w:t></w:r></w:fldSimple><w:fldSimple><w:r><w:t>?</w:t></w:r></w:fldSimple>"
	match read("<w:p>${complex}${simple}</w:p>") {
		[Paragraph({ properties: _, content: [Run(begin), Run(code), Run(separate), Run(result), Run(end), SimpleField(field), Container(_)] })] =>
			match (begin.content, code.content, separate.content, end.content) {
				([FieldMark(b)], [FieldCode(" PAGE ")], [FieldMark(s)], [FieldMark(e), Preserved(_)]) =>
					b.kind == Begin
						and s.kind == Separate
						and e.kind == End
						and result.content == [Text("3")]
						and field.code == " NUMPAGES "
						and field.preserved.len() == 1
						and field.content.len() == 1

				_ => Bool.False
			}

		_ => Bool.False
	}
}

## An inline picture names its media part and its size and keeps its
## drawing; a floating drawing, or one whose image is not in the package, is
## kept as it was read.
expect {
	relationships = [{ id: "rId4", kind: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image", target: "/word/media/image1.png", mode: Internal }]
	drawing = |placement, extent, id| "<w:drawing><wp:${placement}>${extent}<wp:docPr id='1' name='Picture 1'/><a:graphic><a:graphicData uri='http://schemas.openxmlformats.org/drawingml/2006/picture'><a:blip r:embed='${id}'/></a:graphicData></a:graphic></wp:${placement}></w:drawing>"
	extent = "<wp:extent cx='1828800' cy='914400'/>"
	drawings = [drawing("inline", extent, "rId4"), drawing("anchor", extent, "rId4"), drawing("inline", extent, "rId5"), drawing("inline", "<wp:extent cx='1.5' cy='2'/>", "rId4")]
	match read_in("<w:p><w:r>${Str.join_with(drawings, "")}</w:r></w:p>", { relationships, footnotes: [], endnotes: [] }) {
		[Paragraph({ properties: _, content: [Run(r)] })] =>
			match r.content {
				[Picture(inline_picture), Preserved(_), Preserved(_), Preserved(_)] => inline_picture.media == "/word/media/image1.png" and inline_picture.size == { width: 1828800, height: 914400 }
				_ => Bool.False
			}

		_ => Bool.False
	}
}

## A notes part's notes are read in order with their kinds and content, and
## their identifiers listed in the same order.
expect {
	notes = "<w:footnote w:type='separator' w:id='-1'><w:p><w:r><w:separator/></w:r></w:p></w:footnote><w:footnote w:id='0' w:type='continuationSeparator'/><w:footnote w:id='2'><w:p><w:r><w:footnoteRef/><w:t>Note.</w:t></w:r></w:p></w:footnote>"
	tree = XmlTree.parse("<w:footnotes xmlns:w='${wordprocessingml}'>${notes}<w:other/></w:footnotes>".to_utf8(), {}) ?? Text("")
	read_notes = WmlRead.notes(tree, { relationships: [], footnotes: [], endnotes: [] })
	WmlRead.note_ids(tree) == ["-1", "0", "2"]
		and read_notes.map(|note| note.kind) == [Separator, ContinuationSeparator, Note]
		and read_notes.map(|note| note.content.len()) == [1, 0, 1]
		and WmlRead.notes(Text("x"), { relationships: [], footnotes: [], endnotes: [] }) == []
}

## A table holds its properties, grid, rows and cells, a cell holds its
## paragraphs, and the section properties after it are kept as they were
## read.
expect {
	table_xml = "<w:tbl><w:tblPr/><w:tr><w:tc><w:tcPr/><w:p><w:r><w:t>cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>"
	match read("<w:p/>\n  ${table_xml}\n  <w:sectPr/>") {
		[Paragraph(empty), Table({ properties, grid: [], content: [Row({ properties: row_properties_read, content: [Cell({ properties: cell_properties_read, content: [Paragraph(in_cell)] })] })] }), Preserved(_)] =>
			empty == { properties: Document.no_paragraph_properties, content: [] }
				and properties == { style: Unset, width: Unset, borders: [], shading: Unset, preserved: [] }
				and row_properties_read == { header: Unset, grid_before: Unset, grid_after: Unset, preserved: [] }
				and cell_properties_read == { width: Unset, span: Unset, merge: Unset, borders: [], shading: Unset, alignment: Unset, preserved: [] }
				and in_cell.content.len() == 1

		_ => Bool.False
	}
}

## Table, row and cell properties the model holds are read and the rest are
## kept in order: a style, widths, borders, shading, a header row, grid
## columns skipped, a span, a merge and a vertical alignment.
expect {
	border = "w:val='single' w:sz='4' w:space='0' w:color='auto'"
	table_xml = "<w:tblPr><w:tblStyle w:val='Grid'/><w:tblW w:w='5000' w:type='pct'/><w:jc w:val='center'/><w:tblBorders><w:top ${border}/><w:insideV w:val='nil'/></w:tblBorders><w:shd w:val='clear' w:color='auto' w:fill='D9E2F3'/></w:tblPr>"
	grid_xml = "<w:tblGrid><w:gridCol w:w='2000'/><w:gridCol/></w:tblGrid>"
	row_xml = "<w:trPr><w:cantSplit/><w:gridBefore w:val='1'/><w:tblHeader/><w:gridAfter w:val='2'/></w:trPr>"
	cell_xml = "<w:tcPr><w:tcW w:w='0' w:type='auto'/><w:gridSpan w:val='2'/><w:vMerge w:val='restart'/><w:tcBorders><w:tl2br w:val='double' w:color='FF0000'/></w:tcBorders><w:shd w:val='pct25' w:fill='auto'/><w:noWrap/><w:vAlign w:val='center'/></w:tcPr>"
	match read("<w:tbl>${table_xml}${grid_xml}<w:tr>${row_xml}<w:tc>${cell_xml}<w:p/></w:tc></w:tr></w:tbl>") {
		[Table({ properties, grid: [Column(2000), Preserved(_)], content: [Row({ properties: row_read, content: [Cell({ properties: cell_read, content: [Paragraph(_)] })] })] })] =>
			properties.style == Style("Grid")
				and properties.width == Fiftieths(5000)
				and properties.borders == [
					{ edge: Top, line: "single", size: Eighths(4), space: Points(0), color: Auto },
					{ edge: InsideVertical, line: "nil", size: Unset, space: Unset, color: Unset },
				]
				and properties.shading == Shading({ pattern: "clear", color: Auto, fill: Rgb("D9E2F3") })
				and properties.preserved.len() == 1
				and row_read.header == On
				and row_read.grid_before == Columns(1)
				and row_read.grid_after == Columns(2)
				and row_read.preserved.len() == 1
				and cell_read.width == Auto
				and cell_read.span == Columns(2)
				and cell_read.merge == Restart
				and cell_read.borders == [{ edge: DiagonalDown, line: "double", size: Unset, space: Unset, color: Rgb("FF0000") }]
				and cell_read.shading == Shading({ pattern: "pct25", color: Unset, fill: Auto })
				and cell_read.alignment == Center
				and cell_read.preserved.len() == 1

		_ => Bool.False
	}
}

## A property element whose attributes the model cannot hold is kept as it
## was read, and the first one the model can hold gives the property: an
## automatic width with a size, an unknown merge and theme colours are kept.
expect {
	cell_xml = "<w:tcPr><w:tcW w:w='100' w:type='auto'/><w:tcW w:w='100' w:type='dxa'/><w:tcW w:w='200' w:type='dxa'/><w:vMerge w:val='sideways'/><w:shd w:val='clear' w:themeFill='accent1'/><w:tcBorders><w:top w:val='single' w:themeColor='text1'/></w:tcBorders></w:tcPr>"
	match read("<w:tbl><w:tr><w:tc>${cell_xml}<w:p/></w:tc></w:tr></w:tbl>") {
		[Table({ properties: _, grid: _, content: [Row({ properties: _, content: [Cell({ properties, content: _ })] })] })] =>
			properties.width == Twips(100)
				and properties.merge == Unset
				and properties.shading == Unset
				and properties.borders == []
				and properties.preserved.len() == 5

		_ => Bool.False
	}
}

## Widths written with a fraction, as Google Docs exports write them, are
## rounded with a diagnostic, and so is a percentage finer than the model
## holds; a whole percentage and a vertical merge without a value are read
## as they are.
expect {
	xml = "<w:tbl><w:tblPr><w:tblW w:w='33.3333%' w:type='pct'/></w:tblPr><w:tblGrid><w:gridCol w:w='10470.0'/><w:gridCol w:w='99.5'/></w:tblGrid><w:tr><w:tc><w:tcPr><w:tcW w:w='50%' w:type='pct'/><w:vMerge/></w:tcPr><w:p/></w:tc></w:tr></w:tbl>"
	tree = XmlTree.parse("<w:document xmlns:w='${wordprocessingml}'><w:body>${xml}</w:body></w:document>".to_utf8(), {}) ?? Text("")
	result = WmlRead.read_body(tree, { relationships: [], footnotes: [], endnotes: [] })
	match result.blocks {
		[Table({ properties, grid: columns_read, content: [Row({ properties: _, content: [Cell(cell_read)] })] })] =>
			properties.width == Fiftieths(1667)
				and columns_read == [Column(10470), Column(100)]
				and cell_read.properties.width == Fiftieths(2500)
				and cell_read.properties.merge == Continue
				and result.diagnostics == [
					Rounded({ element: "tblW", attribute: "w", value: "33.3333%" }),
					Rounded({ element: "gridCol", attribute: "w", value: "10470.0" }),
					Rounded({ element: "gridCol", attribute: "w", value: "99.5" }),
				]

		_ => Bool.False
	}
}

## Tables nest in cells, and rows and cells in content controls are read
## through them, with bookmarks and row property exceptions in their place.
expect {
	inner = "<w:tbl><w:tr><w:tc><w:p><w:r><w:t>inner</w:t></w:r></w:p></w:tc></w:tr></w:tbl>"
	cell_control = "<w:sdt><w:sdtPr/><w:sdtContent><w:tc><w:p/></w:tc></w:sdtContent></w:sdt>"
	row_control = "<w:sdt><w:sdtContent><w:tr><w:tblPrEx/><w:tc>${inner}<w:p/></w:tc>${cell_control}</w:tr></w:sdtContent></w:sdt>"
	match read("<w:tbl><w:bookmarkStart w:id='1' w:name='b'/>${row_control}</w:tbl>") {
		[Table(outer)] =>
			match (outer.content, Document.table_rows(outer)) {
				([Preserved(_), Container(_)], [only_row]) =>
					match (only_row.content, Document.row_cells(only_row)) {
						([Preserved(_), Cell(_), Container(_)], [first, second]) =>
							second.content.len() == 1 and match first.content {
								[Table(nested), Paragraph(_)] => Document.table_rows(nested).len() == 1
								_ => Bool.False
							}

						_ => Bool.False
					}

				_ => Bool.False
			}

		_ => Bool.False
	}
}

## Numbers are read leniently and rounded halves away from zero, and what is
## not a number, or has more digits than are read, is not one.
expect {
	decimal("12", 1) == Ok({ value: 12, exact: Bool.True })
		and decimal("-2.5", 1) == Ok({ value: -3, exact: Bool.False })
		and decimal("+.25", 50) == Ok({ value: 13, exact: Bool.False })
		and decimal("1.5", 50) == Ok({ value: 75, exact: Bool.True })
		and decimal("", 1) == Err(NotNumber)
		and decimal("1.2.3", 1) == Err(NotNumber)
		and decimal("1e3", 1) == Err(NotNumber)
		and decimal("1234567890123456", 1) == Err(NotNumber)
}

## Markup compatibility is applied first: an alternative is read as the
## branch the package understands and ignorable extensions are skipped.
expect {
	mc = "xmlns:mc='http://schemas.openxmlformats.org/markup-compatibility/2006' xmlns:x='urn:example:x' mc:Ignorable='x'"
	choice = "<mc:AlternateContent><mc:Choice Requires='x'><x:shape/></mc:Choice><mc:Fallback><w:t>fallback</w:t></mc:Fallback></mc:AlternateContent>"
	xml = "<w:document xmlns:w='${wordprocessingml}' ${mc}><w:body><x:block/><w:p x:id='1'><w:r>${choice}</w:r></w:p></w:body></w:document>"
	tree = XmlTree.parse(xml.to_utf8(), {}) ?? Text("")
	match WmlRead.body(tree, { relationships: [], footnotes: [], endnotes: [] }) {
		[Paragraph({ properties: _, content: [Run(r)] })] => r.content == [Text("fallback")]
		_ => Bool.False
	}
}

## A tree that is not a WordprocessingML document, or has no body, has no
## blocks.
expect {
	other = XmlTree.parse("<w:styles xmlns:w='${wordprocessingml}'><w:body><w:p/></w:body></w:styles>".to_utf8(), {}) ?? Text("")
	bare = XmlTree.parse("<w:document xmlns:w='${wordprocessingml}'/>".to_utf8(), {}) ?? Text("")
	none = { relationships: [], footnotes: [], endnotes: [] }
	WmlRead.body(other, none) == [] and WmlRead.body(bare, none) == []
}
