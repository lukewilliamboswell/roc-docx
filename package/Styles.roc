## A document's style table and the effective properties of its paragraphs
## and runs.
##
## The style table is read from the styles part: each style by its
## identifier with its kind, base style, next and linked styles and its
## paragraph and run properties, and the document defaults. Effective
## properties are resolved in the order ECMA-376 Part 1 §17.7.2 gives: the
## document defaults, then the table style, then the numbering level, then the
## paragraph style and the styles it is based on, then the paragraph's direct
## properties; for a run, then the character style and its bases, then the
## run's direct properties. A style's own properties override those of the
## style it is based on. Toggle properties (bold, italic, caps, small caps,
## strike, double strike and hidden) combine as §17.7.3 says: each of the
## table, paragraph and character styles that turns one on inverts it, and
## direct formatting sets it outright.
##
## Resolution reads the model and never changes it: a document keeps only
## the properties it states, so writing it never bakes resolved values in.
import Document
import Mce
import WmlRead
import XmlTree

Styles :: {
	by_id : Dict(Str, Styles.Style),
	inherited : Dict(Str, { paragraph : Document.ParagraphProperties, run : Document.RunProperties }),
	defaults : { paragraph : Document.ParagraphProperties, run : Document.RunProperties },
	default_paragraph : [NoDefault, Default(Str)],
	default_character : [NoDefault, Default(Str)],
}.{

	## A style: its identifier and name; its kind; the style it is based on,
	## the style a paragraph after one of this style takes, and the style of
	## the other kind it is linked to; whether it is its kind's default, and
	## whether it is one a user or application defined rather than one of the
	## schema's built-in names; its own paragraph and run properties; and
	## every other element of the style (its user-interface priority, a table
	## style's table properties and conditional formatting) as it was read.
	Style : {
		id : Str,
		name : [Unnamed, Named(Str)],
		kind : Kind,
		based_on : [NoBase, BasedOn(Str)],
		next : [NoNext, Next(Str)],
		link : [NoLink, Linked(Str)],
		usage : [KindDefault, Ordinary],
		origin : [Custom, BuiltIn],
		paragraph : Document.ParagraphProperties,
		run : Document.RunProperties,
		preserved : List(XmlTree.Node),
	}

	## What a style formats: paragraphs, runs, tables or numbering.
	Kind : [Paragraph, Character, Table, Numbering]

	## Something in the styles part that reading did not take as written: a
	## style without an identifier or of a kind the schema does not define,
	## at its position among the styles from 1, which is skipped; a second
	## style with an identifier already taken, which is skipped; a style based
	## on one that does not exist, or on a style of another kind, which is
	## read without a base; and a style on a cycle of base styles, which is
	## read without a base, as is every other style on that cycle.
	Diagnostic : [
		UnreadableStyle({ position : U64 }),
		DuplicateStyle(Str),
		MissingBaseStyle({ style : Str, base : Str }),
		BaseOfOtherKind({ style : Str, base : Str }),
		StyleCycle(Str),
	]

	## What a table style and a numbering level contribute to a paragraph or
	## run, between the document defaults and the paragraph style. A caller
	## that knows the table a paragraph is in or the list level it is at
	## passes their properties; by default they contribute nothing.
	Contributions := {
		table_paragraph : Document.ParagraphProperties ?? Document.no_paragraph_properties,
		table_run : Document.RunProperties ?? Document.no_run_properties,
		numbering : Document.ParagraphProperties ?? Document.no_paragraph_properties,
	}

	## The style table of a styles part's tree, with what reading did not
	## take as written. The tree is interpreted by [Mce.process] first. A tree
	## whose root is not a WordprocessingML `w:styles` element has no styles
	## and no defaults.
	read : XmlTree.Node -> { styles : Styles, diagnostics : List(Diagnostic) }
	read = |tree| {
		children = match Mce.process(tree).interpreted {
			Element(root) if is_w(root.name, "styles") => root.children
			_ => []
		}
		var $defaults = { paragraph: Document.no_paragraph_properties, run: Document.no_run_properties }
		var $by_id = Dict.with_capacity(children.len())
		var $order = List.with_capacity(children.len())
		var $diagnostics = List.with_capacity(0)
		var $default_paragraph = NoDefault
		var $default_character = NoDefault
		var $position = 0.U64
		for child in children {
			match child {
				Element(element) if is_w(element.name, "docDefaults") => {
					$defaults = document_defaults(element)
				}

				Element(element) if is_w(element.name, "style") => {
					$position = $position + 1
					match style_of(element) {
						Ok(found_style) =>
							if $by_id.contains(found_style.id) {
								$diagnostics = List.append($diagnostics, DuplicateStyle(found_style.id))
							} else {
								$by_id = $by_id.insert(found_style.id, found_style)
								$order = List.append($order, found_style.id)
								if found_style.usage == KindDefault {
									match found_style.kind {
										Paragraph => {
											$default_paragraph = match $default_paragraph {
												NoDefault => Default(found_style.id)
												chosen => chosen
											}
										}

										Character => {
											$default_character = match $default_character {
												NoDefault => Default(found_style.id)
												chosen => chosen
											}
										}

										_ => {}
									}
								}
							}

						Err(Unreadable) => {
							$diagnostics = List.append($diagnostics, UnreadableStyle({ position: $position }))
						}
					}
				}

				_ => {}
			}
		}
		chains = inherit($by_id, $order)
		{
			styles: { by_id: $by_id, inherited: chains.inherited, defaults: $defaults, default_paragraph: $default_paragraph, default_character: $default_character },
			diagnostics: List.concat($diagnostics, chains.diagnostics),
		}
	}

	## The style table of a document without a styles part.
	empty : Styles
	empty = { by_id: Dict.empty(), inherited: Dict.empty(), defaults: { paragraph: Document.no_paragraph_properties, run: Document.no_run_properties }, default_paragraph: NoDefault, default_character: NoDefault }

	## The style with this identifier.
	get : Styles, Str -> Try(Style, [NotFound])
	get = |styles, id| Ok(styles.by_id.get(id) ? |_| NotFound)

	## The properties a style gives with the styles it is based on: its own
	## properties over its base style's, and so on up the chain. A toggle
	## property here is the nearest one stated along the chain; the toggling
	## happens between the kinds of style, in [Styles.effective_run].
	inherited : Styles, Str -> Try({ paragraph : Document.ParagraphProperties, run : Document.RunProperties }, [NotFound])
	inherited = |styles, id| Ok(styles.inherited.get(id) ? |_| NotFound)

	## A paragraph's effective properties from its direct properties: the
	## document defaults, then the contributions of a table style and a
	## numbering level, then its paragraph style with the styles it is based
	## on, then its direct properties, each property taken from the last that
	## states it. A paragraph without a style, or whose style is not a
	## paragraph style in the table, has the default paragraph style, and
	## `style` names the style that applied. A property nobody states stays
	## `Unset`, the application's default; a tab stop a style set and the
	## paragraph cleared stays in `tabs` as cleared; and `preserved` is empty,
	## since content the model does not hold is not resolved.
	##
	## A numbering level's properties come from the paragraph's numbering
	## reference, which itself may come from its style; a caller resolves
	## once to find the reference and again with the level's properties.
	effective_paragraph : Styles, Document.ParagraphProperties, Contributions -> Document.ParagraphProperties
	effective_paragraph = |styles, direct, contributions| {
		applied = paragraph_style(styles, direct)
		from_style = match applied {
			Default(id) => (styles.inherited.get(id) ?? { paragraph: Document.no_paragraph_properties, run: Document.no_run_properties }).paragraph
			NoDefault => Document.no_paragraph_properties
		}
		merged = [contributions.table_paragraph, contributions.numbering, from_style, direct].fold(styles.defaults.paragraph, merge_paragraph)
		style = match applied {
			Default(id) => Style(id)
			NoDefault => Unset
		}
		{ ..merged, style: style, preserved: [] }
	}

	## A run's effective properties from its direct properties and those of
	## its paragraph: the document defaults, then a table style's
	## contribution, then the paragraph's style with its bases, then the
	## run's character style with its bases, then its direct properties. A
	## run without a character style has the default character style, and a
	## style named for a run that is a paragraph style applies the character
	## style linked to it. Every toggle property is `On` or `Off`: on in the
	## defaults or off, inverted by each of the table, paragraph and character
	## styles that turns it on, and set outright by direct formatting. Every
	## other property is taken from the last that states it, `Unset`
	## where nobody does, and `preserved` is empty.
	effective_run : Styles, { paragraph : Document.ParagraphProperties, run : Document.RunProperties }, Contributions -> Document.RunProperties
	effective_run = |styles, { paragraph, run }, contributions| {
		none = { paragraph: Document.no_paragraph_properties, run: Document.no_run_properties }
		from_paragraph = match paragraph_style(styles, paragraph) {
			Default(id) => (styles.inherited.get(id) ?? none).run
			NoDefault => Document.no_run_properties
		}
		applied = character_style(styles, run)
		from_character = match applied {
			Default(id) => (styles.inherited.get(id) ?? none).run
			NoDefault => Document.no_run_properties
		}
		levels = [contributions.table_run, from_paragraph, from_character]
		merged = levels.append(run).fold(styles.defaults.run, merge_run)
		toggled = |field| {
			var $state = field(styles.defaults.run) == On
			for level in levels {
				if field(level) == On {
					$state = !$state
				}
			}
			match field(run) {
				Unset => if ($state) On else Off
				stated => stated
			}
		}
		style = match applied {
			Default(id) => Style(id)
			NoDefault => Unset
		}
		{
			..merged,
			style: style,
			bold: toggled(|properties| properties.bold),
			italic: toggled(|properties| properties.italic),
			caps: toggled(|properties| properties.caps),
			small_caps: toggled(|properties| properties.small_caps),
			strike: toggled(|properties| properties.strike),
			double_strike: toggled(|properties| properties.double_strike),
			hidden: toggled(|properties| properties.hidden),
			preserved: [],
		}
	}
}

wordprocessingml : Str
wordprocessingml = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

Element : { name : XmlTree.Name, bindings : List(XmlTree.Binding), attributes : List(XmlTree.Attribute), children : List(XmlTree.Node) }

is_w : XmlTree.Name, Str -> Bool
is_w = |name, local| name.namespace == Uri(wordprocessingml) and name.local == local

value_of : Element, Str -> Try(Str, [NotFound])
value_of = |element, local|
	element.attributes.find_first(|attribute| is_w(attribute.name, local)).map_ok(|attribute| attribute.value)

# The `w:val` of a WordprocessingML child of an element.
child_value : Element, Str -> Try(Str, [NotFound])
child_value = |element, local|
	match element.children.find_first(|child| is_element(child, local)) {
		Ok(Element(child)) => value_of(child, "val")
		_ => Err(NotFound)
	}

is_element : XmlTree.Node, Str -> Bool
is_element = |node, local|
	match node {
		Element(element) => is_w(element.name, local)
		Text(_) => Bool.False
	}

on : Element, Str -> Bool
on = |element, local|
	match value_of(element, local) {
		Ok(value) => value == "1" or value == "true" or value == "on"
		Err(NotFound) => Bool.False
	}

document_defaults : Element -> { paragraph : Document.ParagraphProperties, run : Document.RunProperties }
document_defaults = |element| {
	properties = |outer, inner|
		match element.children.find_first(|child| is_element(child, outer)) {
			Ok(Element(default)) =>
				match default.children.find_first(|child| is_element(child, inner)) {
					Ok(Element(found)) => found.children
					_ => []
				}

			_ => []
		}
	{ paragraph: WmlRead.paragraph_properties(properties("pPrDefault", "pPr")), run: WmlRead.run_properties(properties("rPrDefault", "rPr")) }
}

# The schema's style children the style table models; every other child is
# kept in the style's `preserved`.
modelled_children : List(Str)
modelled_children = ["name", "basedOn", "next", "link", "pPr", "rPr"]

style_of : Element -> Try(Styles.Style, [Unreadable])
style_of = |element| {
	id = value_of(element, "styleId") ? |_| Unreadable
	kind = match value_of(element, "type") {
		Err(NotFound) => Paragraph
		Ok("paragraph") => Paragraph
		Ok("character") => Character
		Ok("table") => Table
		Ok("numbering") => Numbering
		Ok(_) => return Err(Unreadable)
	}
	properties = |local|
		match element.children.find_first(|child| is_element(child, local)) {
			Ok(Element(found)) => found.children
			_ => []
		}
	Ok({
		id,
		name: match child_value(element, "name") {
			Ok(name) => Named(name)
			Err(NotFound) => Unnamed
		},
		kind,
		based_on: match child_value(element, "basedOn") {
			Ok(base) => BasedOn(base)
			Err(NotFound) => NoBase
		},
		next: match child_value(element, "next") {
			Ok(next) => Next(next)
			Err(NotFound) => NoNext
		},
		link: match child_value(element, "link") {
			Ok(link) => Linked(link)
			Err(NotFound) => NoLink
		},
		usage: if (on(element, "default")) KindDefault else Ordinary,
		origin: if (on(element, "customStyle")) Custom else BuiltIn,
		paragraph: WmlRead.paragraph_properties(properties("pPr")),
		run: WmlRead.run_properties(properties("rPr")),
		preserved: element.children.keep_if(
			|child|
				match child {
					Element(found) => !(found.name.namespace == Uri(wordprocessingml) and modelled_children.contains(found.name.local))
					Text(content) => !content.to_utf8().all(|byte| byte == 32 or byte == 9 or byte == 10 or byte == 13)
				},
		),
	})
}

Properties : { paragraph : Document.ParagraphProperties, run : Document.RunProperties }

# Each style's properties with its bases', computed once per style by
# walking each base chain until it reaches a style already done, a style
# without a usable base, or a style already on the walk, which closes a
# cycle. Every style on a cycle is read without a base.
inherit : Dict(Str, Styles.Style), List(Str) -> { inherited : Dict(Str, Properties), diagnostics : List(Styles.Diagnostic) }
inherit = |by_id, order| {
	var $done = Dict.with_capacity(by_id.len())
	var $diagnostics = List.with_capacity(0)
	for start in order {
		if !$done.contains(start) {
			var $path = List.with_capacity(4)
			var $on_path = Dict.with_capacity(4)
			var $current = start
			var $base = Root
			var $walking = Bool.True
			while $walking {
				$on_path = $on_path.insert($current, $path.len())
				$path = List.append($path, $current)
				own = by_id.get($current) ?? empty_style($current)
				match own.based_on {
					NoBase => {
						$walking = Bool.False
					}

					BasedOn(base) =>
						if $done.contains(base) {
							if same_kind(by_id, own, base) {
								$base = Anchor(base)
							} else {
								$diagnostics = List.append($diagnostics, BaseOfOtherKind({ style: $current, base }))
							}
							$walking = Bool.False
						} else {
							match $on_path.get(base) {
								Ok(index) => {
									$base = Cycle(index)
									$walking = Bool.False
								}

								Err(_) =>
									match by_id.get(base) {
										Ok(next) =>
											if next.kind == own.kind {
												$current = base
											} else {
												$diagnostics = List.append($diagnostics, BaseOfOtherKind({ style: $current, base }))
												$walking = Bool.False
											}

										Err(_) => {
											$diagnostics = List.append($diagnostics, MissingBaseStyle({ style: $current, base }))
											$walking = Bool.False
										}
									}
							}
						}
				}
			}
			# The cycle's members, from the repeated style to the end of the
			# walk, are roots; the styles before them inherit down the walk.
			roots_from = match $base {
				Cycle(index) => index
				_ => $path.len()
			}
			var $inherited = match $base {
				Anchor(base) => $done.get(base) ?? no_properties
				_ => no_properties
			}
			var $index = $path.len()
			while $index > 0 {
				$index = $index - 1
				id = $path.get($index) ?? ""
				own = by_id.get(id) ?? empty_style(id)
				if $index >= roots_from {
					$diagnostics = List.append($diagnostics, StyleCycle(id))
					$done = $done.insert(id, { paragraph: own.paragraph, run: own.run })
					if $index == roots_from {
						$inherited = { paragraph: own.paragraph, run: own.run }
					}
				} else {
					$inherited = { paragraph: merge_paragraph($inherited.paragraph, own.paragraph), run: merge_run($inherited.run, own.run) }
					$done = $done.insert(id, $inherited)
				}
			}
		}
	}
	{ inherited: $done, diagnostics: $diagnostics }
}

no_properties : Properties
no_properties = { paragraph: Document.no_paragraph_properties, run: Document.no_run_properties }

empty_style : Str -> Styles.Style
empty_style = |id| { id, name: Unnamed, kind: Paragraph, based_on: NoBase, next: NoNext, link: NoLink, usage: Ordinary, origin: BuiltIn, paragraph: Document.no_paragraph_properties, run: Document.no_run_properties, preserved: [] }

same_kind : Dict(Str, Styles.Style), Styles.Style, Str -> Bool
same_kind = |by_id, own, base|
	match by_id.get(base) {
		Ok(found) => found.kind == own.kind
		Err(_) => Bool.False
	}

# The paragraph style that applies: the one named, if it is a paragraph
# style in the table, otherwise the default paragraph style.
paragraph_style : Styles, Document.ParagraphProperties -> [NoDefault, Default(Str)]
paragraph_style = |styles, properties|
	match properties.style {
		Style(id) =>
			match styles.by_id.get(id) {
				Ok(found) if found.kind == Paragraph => Default(id)
				_ => styles.default_paragraph
			}

		Unset => styles.default_paragraph
	}

# The character style that applies: the one named, or the character style
# linked to a named paragraph style, otherwise the default character style.
character_style : Styles, Document.RunProperties -> [NoDefault, Default(Str)]
character_style = |styles, properties|
	match properties.style {
		Style(id) =>
			match styles.by_id.get(id) {
				Ok(found) if found.kind == Character => Default(id)
				Ok(found) if found.kind == Paragraph =>
					match found.link {
						Linked(linked) =>
							match styles.by_id.get(linked) {
								Ok(target) if target.kind == Character => Default(linked)
								_ => styles.default_character
							}

						NoLink => styles.default_character
					}

				_ => styles.default_character
			}

		Unset => styles.default_character
	}

prefer : [Unset, ..others], [Unset, ..others] -> [Unset, ..others]
prefer = |base, over|
	match over {
		Unset => base
		_ => over
	}

# Paragraph properties stated in `over` replace those in `base`; indents,
# spacing and the numbering reference are replaced attribute by attribute,
# borders edge by edge and tab stops position by position.
merge_paragraph : Document.ParagraphProperties, Document.ParagraphProperties -> Document.ParagraphProperties
merge_paragraph = |base, over| {
	style: prefer(base.style, over.style),
	alignment: prefer(base.alignment, over.alignment),
	indentation: {
		left: prefer(base.indentation.left, over.indentation.left),
		right: prefer(base.indentation.right, over.indentation.right),
		first_line: prefer(base.indentation.first_line, over.indentation.first_line),
	},
	spacing: {
		before: prefer(base.spacing.before, over.spacing.before),
		after: prefer(base.spacing.after, over.spacing.after),
		line: prefer(base.spacing.line, over.spacing.line),
	},
	keep_next: prefer(base.keep_next, over.keep_next),
	keep_lines: prefer(base.keep_lines, over.keep_lines),
	page_break_before: prefer(base.page_break_before, over.page_break_before),
	widow_control: prefer(base.widow_control, over.widow_control),
	outline_level: prefer(base.outline_level, over.outline_level),
	borders: base.borders.drop_if(|border| over.borders.any(|other| other.edge == border.edge)).concat(over.borders),
	shading: prefer(base.shading, over.shading),
	tabs: match (base.tabs, over.tabs) {
		(Tabs(stops), Tabs(replacing)) => Tabs(merge_tabs(stops, replacing))
		(_, Unset) => base.tabs
		_ => over.tabs
	},
	numbering: {
		instance: prefer(base.numbering.instance, over.numbering.instance),
		level: prefer(base.numbering.level, over.numbering.level),
	},
	preserved: [],
}

# Tab stops by position, a stop in `replacing` taking the place of one at
# the same position, cleared or not, in order of position.
merge_tabs : List(Document.TabStop), List(Document.TabStop) -> List(Document.TabStop)
merge_tabs = |stops, replacing|
	stops
		.drop_if(|stop| replacing.any(|other| other.position == stop.position))
		.concat(replacing)
		.sort_with(|a, b| if (a.position < b.position) Before else if (a.position > b.position) After else Same)

# Run properties stated in `over` replace those in `base`; fonts and
# languages are replaced script by script.
merge_run : Document.RunProperties, Document.RunProperties -> Document.RunProperties
merge_run = |base, over| {
	style: prefer(base.style, over.style),
	bold: prefer(base.bold, over.bold),
	italic: prefer(base.italic, over.italic),
	caps: prefer(base.caps, over.caps),
	small_caps: prefer(base.small_caps, over.small_caps),
	strike: prefer(base.strike, over.strike),
	double_strike: prefer(base.double_strike, over.double_strike),
	hidden: prefer(base.hidden, over.hidden),
	underline: prefer(base.underline, over.underline),
	vertical_align: prefer(base.vertical_align, over.vertical_align),
	color: prefer(base.color, over.color),
	highlight: prefer(base.highlight, over.highlight),
	size: prefer(base.size, over.size),
	fonts: {
		ascii: prefer(base.fonts.ascii, over.fonts.ascii),
		high_ansi: prefer(base.fonts.high_ansi, over.fonts.high_ansi),
		east_asia: prefer(base.fonts.east_asia, over.fonts.east_asia),
		complex: prefer(base.fonts.complex, over.fonts.complex),
		ascii_theme: prefer(base.fonts.ascii_theme, over.fonts.ascii_theme),
		high_ansi_theme: prefer(base.fonts.high_ansi_theme, over.fonts.high_ansi_theme),
		east_asia_theme: prefer(base.fonts.east_asia_theme, over.fonts.east_asia_theme),
		complex_theme: prefer(base.fonts.complex_theme, over.fonts.complex_theme),
	},
	language: {
		latin: prefer(base.language.latin, over.language.latin),
		east_asia: prefer(base.language.east_asia, over.language.east_asia),
		complex: prefer(base.language.complex, over.language.complex),
	},
	preserved: [],
}

# The style table of a styles part with this content.
table_of : Str -> { styles : Styles, diagnostics : List(Styles.Diagnostic) }
table_of = |content| {
	tree = XmlTree.parse("<w:styles xmlns:w='${wordprocessingml}'>${content}</w:styles>".to_utf8(), {}) ?? Text("")
	Styles.read(tree)
}

paragraph_of : Str -> Document.ParagraphProperties
paragraph_of = |content| {
	tree = XmlTree.parse("<w:pPr xmlns:w='${wordprocessingml}'>${content}</w:pPr>".to_utf8(), {}) ?? Text("")
	match tree {
		Element(element) => WmlRead.paragraph_properties(element.children)
		Text(_) => Document.no_paragraph_properties
	}
}

run_of : Str -> Document.RunProperties
run_of = |content| {
	tree = XmlTree.parse("<w:rPr xmlns:w='${wordprocessingml}'>${content}</w:rPr>".to_utf8(), {}) ?? Text("")
	match tree {
		Element(element) => WmlRead.run_properties(element.children)
		Text(_) => Document.no_run_properties
	}
}

sample : Str
sample =
	\\<w:docDefaults><w:rPrDefault><w:rPr><w:sz w:val="24"/><w:lang w:val="en-GB"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="160"/></w:pPr></w:pPrDefault></w:docDefaults>
	\\<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>
	\\<w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:link w:val="Heading1Char"/><w:pPr><w:keepNext/><w:spacing w:before="240"/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:sz w:val="32"/></w:rPr></w:style>
	\\<w:style w:type="paragraph" w:customStyle="1" w:styleId="Chapter"><w:name w:val="Chapter"/><w:basedOn w:val="Heading1"/><w:pPr><w:jc w:val="center"/></w:pPr></w:style>
	\\<w:style w:type="character" w:default="1" w:styleId="DefaultParagraphFont"><w:name w:val="Default Paragraph Font"/></w:style>
	\\<w:style w:type="character" w:customStyle="1" w:styleId="Heading1Char"><w:name w:val="Heading 1 Char"/><w:link w:val="Heading1"/><w:rPr><w:b/><w:sz w:val="32"/></w:rPr></w:style>
	\\<w:style w:type="character" w:styleId="Strong"><w:name w:val="Strong"/><w:rPr><w:b/><w:i w:val="0"/></w:rPr></w:style>

## A style is read with its kind, relations and properties, and what the
## table does not model stays with it.
expect {
	read = table_of(sample)
	heading = Styles.get(read.styles, "Heading1")?
	read.diagnostics == []
		and heading.kind == Paragraph
		and heading.based_on == BasedOn("Normal")
		and heading.next == Next("Normal")
		and heading.link == Linked("Heading1Char")
		and heading.usage == Ordinary
		and heading.origin == BuiltIn
		and heading.paragraph.outline_level == Level(0)
		and heading.run.size == HalfPoints(32)
		and (Styles.get(read.styles, "Normal")?).preserved.len() == 1
		and (Styles.get(read.styles, "Chapter")?).origin == Custom
}

## A paragraph without a style has the default style and the document
## defaults; a style's properties override its base's, and direct ones
## override the style's.
expect {
	styles = table_of(sample).styles
	plain = Styles.effective_paragraph(styles, Document.no_paragraph_properties, {})
	chapter = Styles.effective_paragraph(styles, paragraph_of("<w:pStyle w:val='Chapter'/><w:spacing w:after='0'/>"), {})
	plain.style == Style("Normal")
		and plain.spacing == { before: Unset, after: Twips(160), line: Unset }
		and chapter.style == Style("Chapter")
		and chapter.outline_level == Level(0)
		and chapter.alignment == Aligned(Center)
		and chapter.keep_next == On
		and chapter.spacing == { before: Twips(240), after: Twips(0), line: Unset }
}

## Toggles invert between kinds of style and direct formatting sets them
## outright: a heading's bold inverted by a bold character style is off, and
## direct formatting turns it back on.
expect {
	styles = table_of(sample).styles
	heading = paragraph_of("<w:pStyle w:val='Heading1'/>")
	run = |content| Styles.effective_run(styles, { paragraph: heading, run: run_of(content) }, {})
	plain = run("")
	strong = run("<w:rStyle w:val='Strong'/>")
	direct = run("<w:rStyle w:val='Strong'/><w:b/>")
	plain.bold == On
		and plain.italic == Off
		and plain.size == HalfPoints(32)
		and plain.language.latin == Tag("en-GB")
		and plain.style == Style("DefaultParagraphFont")
		and strong.bold == Off
		and strong.italic == Off
		and direct.bold == On
}

## A run styled with a paragraph style takes the character style linked to
## it, and a table style's contribution comes before the paragraph style's.
expect {
	styles = table_of(sample).styles
	linked = Styles.effective_run(styles, { paragraph: Document.no_paragraph_properties, run: run_of("<w:rStyle w:val='Heading1'/>") }, {})
	from_table = Styles.effective_run(styles, { paragraph: Document.no_paragraph_properties, run: Document.no_run_properties }, { table_run: run_of("<w:b/><w:sz w:val='18'/>") })
	linked.style == Style("Heading1Char") and linked.bold == On and from_table.bold == On and from_table.size == HalfPoints(18)
}

## Base chains that loop, name missing styles or cross kinds are cut with a
## diagnostic, and every style on a cycle is read without a base.
expect {
	content =
		\\<w:style w:styleId="A"><w:basedOn w:val="B"/><w:rPr><w:b/></w:rPr></w:style>
		\\<w:style w:styleId="B"><w:basedOn w:val="A"/><w:rPr><w:i/></w:rPr></w:style>
		\\<w:style w:styleId="C"><w:basedOn w:val="A"/><w:rPr><w:caps/></w:rPr></w:style>
		\\<w:style w:styleId="D"><w:basedOn w:val="Missing"/></w:style>
		\\<w:style w:type="character" w:styleId="E"><w:basedOn w:val="C"/></w:style>
		\\<w:style w:styleId="A"/>
		\\<w:style w:type="paragraph"/>
	read = table_of(content)
	a = Styles.inherited(read.styles, "A")?
	c = Styles.inherited(read.styles, "C")?
	read.diagnostics
		== [
			DuplicateStyle("A"),
			UnreadableStyle({ position: 7 }),
			StyleCycle("B"),
			StyleCycle("A"),
			MissingBaseStyle({ style: "D", base: "Missing" }),
			BaseOfOtherKind({ style: "E", base: "C" }),
		]
		and a.run.bold == On
		and a.run.italic == Unset
		and c.run.bold == On
		and c.run.caps == On
}

## Tab stops merge by position, and a stop a paragraph clears stays cleared.
expect {
	styles = table_of("<w:style w:styleId='Tabbed'><w:pPr><w:tabs><w:tab w:val='left' w:pos='720'/><w:tab w:val='right' w:pos='9000' w:leader='dot'/></w:tabs></w:pPr></w:style>").styles
	resolved = Styles.effective_paragraph(styles, paragraph_of("<w:pStyle w:val='Tabbed'/><w:tabs><w:tab w:val='clear' w:pos='720'/><w:tab w:val='center' w:pos='4500'/></w:tabs>"), {})
	resolved.tabs
		== Tabs([
			{ kind: Clear, position: 720, leader: Unset },
			{ kind: Center, position: 4500, leader: Unset },
			{ kind: Right, position: 9000, leader: Dot },
		])
}

## A tree that is not a styles part has no styles.
expect {
	read = Styles.read(XmlTree.parse("<w:document xmlns:w='${wordprocessingml}'/>".to_utf8(), {}) ?? Text(""))
	read.diagnostics == [] and Styles.get(read.styles, "Normal") == Err(NotFound)
}
