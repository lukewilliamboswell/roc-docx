## A document's numbering definitions and the lists its paragraphs belong to.
##
## The numbering table is read from the numbering part. A numbering
## definition describes up to nine list levels: how each is numbered, from
## what number it starts, the text it shows and the paragraph and run
## properties it gives. A numbering instance is what a paragraph names: it
## uses one definition, and may override the number a level starts from or
## replace a level outright. A definition can also stand for a numbering
## style, or take its levels from the definition a numbering style uses, so
## that one list style can be shared by many definitions.
##
## A paragraph is a list item when its effective numbering reference, stated
## on it or given by its paragraph style, names an instance other than 0 that
## exists and whose definition can be found. [Numbering.level] resolves the
## reference to the level the paragraph is at.
import Document
import Mce
import Styles
import WmlRead
import XmlTree

Numbering :: {
	definitions : Dict(U32, Numbering.Definition),
	instances : Dict(U32, Numbering.Instance),
	style_links : Dict(Str, U32),
}.{

	## A numbering definition: whether its levels form one list level, a
	## list of nested levels, or nested levels that a producer may restart
	## independently; the numbering style it stands for and the numbering
	## style whose definition it uses instead of its own levels; its levels
	## in the order read; the attributes and elements it has that the model
	## does not hold (its identifier for editing sessions, its template code,
	## its name) as they were read.
	Definition : {
		kind : [Unset, SingleLevel, Multilevel, HybridMultilevel],
		style : [Unset, Style(Str)],
		uses_style : [Unset, Style(Str)],
		levels : List(Level),
		preserved_attributes : List(XmlTree.Attribute),
		preserved : List(XmlTree.Node),
	}

	## A list level: its level from 0; the number it starts from; how it is
	## numbered; the text it shows, where `%1` to `%9` stand for the numbers
	## of levels 1 to 9; the alignment of that text; the paragraph style that
	## takes this level; the paragraph properties it gives a paragraph at the
	## level and the run properties of its text; and the attributes and
	## elements it has that the model does not hold (its suffix, a restart
	## rule, a picture bullet) as they were read. Each is `Unset` where the
	## level does not state it; a level a definition does not give has every
	## property `Unset`.
	Level : {
		level : U8,
		start : [Unset, Start(I32)],
		format : Format,
		text : [Unset, Text(Str)],
		alignment : [Unset, Aligned(Document.Alignment)],
		paragraph_style : [Unset, Style(Str)],
		paragraph : Document.ParagraphProperties,
		run : Document.RunProperties,
		preserved_attributes : List(XmlTree.Attribute),
		preserved : List(XmlTree.Node),
	}

	## How a level is numbered: with a bullet, which may be a character or a
	## picture; with no number at all; or with numbers in the format the
	## schema names, such as `decimal`, `lowerLetter` or `upperRoman`. A
	## level that does not say is numbered `decimal`, as the schema's default
	## is.
	Format : [Unset, Bullet, NoNumber, Number(Str)]

	## A numbering instance: the definition it uses by its identifier in this
	## table; its overrides, at most one for each level; and the attributes
	## and elements it has that the model does not hold, as they were read.
	Instance : {
		definition : [Definition(U32)],
		overrides : List(Override),
		preserved_attributes : List(XmlTree.Attribute),
		preserved : List(XmlTree.Node),
	}

	## An instance's override of one level: the number the level starts from
	## instead of the definition's, and a level that replaces the
	## definition's altogether.
	Override : { level : U8, start : [Unset, Start(I32)], replacement : [Unset, Replaced(Level)] }

	## Something in the numbering part that reading did not take as written: a
	## definition or an instance without a usable identifier, or an instance
	## that names no definition, at its position among its kind from 1,
	## which is skipped; a second definition or instance with an identifier
	## already taken, which is skipped; and an instance whose definition does
	## not exist, which is kept, though no paragraph that names it is a list
	## item.
	Diagnostic : [
		UnreadableDefinition({ position : U64 }),
		UnreadableInstance({ position : U64 }),
		DuplicateDefinition(U32),
		DuplicateInstance(U32),
		MissingDefinition({ instance : U32, definition : U32 }),
	]

	## Why a numbering reference names no list level: it names no instance,
	## or instance 0, which removes a style's numbering; the instance does
	## not exist; its definition does not exist; or its definition uses a
	## numbering style that does not lead to a definition with levels of
	## its own.
	Unlisted : [
		NotListed,
		MissingInstance(U32),
		MissingDefinition({ instance : U32, definition : U32 }),
		UnresolvedStyle(Str),
	]

	## The numbering table of a numbering part's tree, with what reading did
	## not take as written. The tree is interpreted by [Mce.process] first. A
	## tree whose root is not a WordprocessingML `w:numbering` element has no
	## definitions and no instances. A level, a level override or an override
	## element that cannot be read whole, or that repeats a level already
	## read, is kept in the `preserved` list of its definition or instance,
	## and so is every other element; within a level, an element whose
	## attributes the model cannot hold, such as a format with a custom
	## pattern, is kept in the level's `preserved`.
	read : XmlTree.Node -> { numbering : Numbering, diagnostics : List(Diagnostic) }
	read = |tree| {
		children = match Mce.process(tree).interpreted {
			Element(root) if is_w(root.name, "numbering") => root.children
			_ => []
		}
		count = |local| children.fold(0, |sum, child| if (is_element(child, local)) sum + 1 else sum)
		instance_count = count("num")
		var $definitions = Dict.with_capacity(count("abstractNum"))
		var $instances = Dict.with_capacity(instance_count)
		var $style_links = Dict.with_capacity(0)
		var $order = List.with_capacity(instance_count)
		var $diagnostics = List.with_capacity(0)
		var $definition_position = 0.U64
		var $instance_position = 0.U64
		for child in children {
			match child {
				Element(element) if is_w(element.name, "abstractNum") => {
					$definition_position = $definition_position + 1
					match number_of(element, "abstractNumId") {
						Ok(id) =>
							if $definitions.contains(id) {
								$diagnostics = List.append($diagnostics, DuplicateDefinition(id))
							} else {
								read = definition_of(element)
								$definitions = $definitions.insert(id, read)
								match read.style {
									Style(style) if !$style_links.contains(style) => {
										$style_links = $style_links.insert(style, id)
									}

									_ => {}
								}
							}

						Err(Unreadable) => {
							$diagnostics = List.append($diagnostics, UnreadableDefinition({ position: $definition_position }))
						}
					}
				}

				Element(element) if is_w(element.name, "num") => {
					$instance_position = $instance_position + 1
					match (number_of(element, "numId"), instance_of(element)) {
						(Ok(id), Ok(found)) =>
							if $instances.contains(id) {
								$diagnostics = List.append($diagnostics, DuplicateInstance(id))
							} else {
								$instances = $instances.insert(id, found)
								$order = List.append($order, id)
							}

						_ => {
							$diagnostics = List.append($diagnostics, UnreadableInstance({ position: $instance_position }))
						}
					}
				}

				_ => {}
			}
		}
		missing = $order.keep_oks(
			|id| {
				found = $instances.get(id) ? |_| Present
				Definition(definition) = found.definition
				if $definitions.contains(definition) {
					Err(Present)
				} else {
					Ok(MissingDefinition({ instance: id, definition }))
				}
			},
		)
		{ numbering: { definitions: $definitions, instances: $instances, style_links: $style_links }, diagnostics: List.concat($diagnostics, missing) }
	}

	## The numbering table of a document without a numbering part.
	empty : Numbering
	empty = { definitions: Dict.empty(), instances: Dict.empty(), style_links: Dict.empty() }

	## The definition with this identifier.
	definition : Numbering, [Definition(U32)] -> Try(Definition, [NotFound])
	definition = |numbering, Definition(id)| Ok(numbering.definitions.get(id) ? |_| NotFound)

	## The instance with this identifier, as a paragraph's numbering
	## reference names it.
	instance : Numbering, [Instance(U32)] -> Try(Instance, [NotFound])
	instance = |numbering, Instance(id)| Ok(numbering.instances.get(id) ? |_| NotFound)

	## The list level a paragraph's numbering reference names, normally its
	## effective one from [Styles.effective_paragraph]: the instance's level,
	## level 0 where the reference gives none. The level is the definition's,
	## or the one an override of the instance replaces it with, starting from
	## the override's number where it gives one. A definition that uses a
	## numbering style takes the levels of the definition of the instance that
	## style names, or failing that of the definition that stands for the
	## style. A level the definition does not give has every property
	## `Unset`.
	##
	## The level's `paragraph` properties are what it contributes to a
	## paragraph's effective properties, as the `numbering` field of
	## [Styles.Contributions].
	level : Numbering, Styles, Document.Numbering -> Try(Level, Unlisted)
	level = |numbering, styles, reference| {
		id = match reference.instance {
			Instance(found) if found != 0 => found
			_ => return Err(NotListed)
		}
		at = match reference.level {
			Level(found) => found
			Unset => 0
		}
		found = numbering.instances.get(id) ? |_| MissingInstance(id)
		Definition(definition_id) = found.definition
		named = numbering.definitions.get(definition_id) ? |_| MissingDefinition({ instance: id, definition: definition_id })
		levels = match named.uses_style {
			Unset => named.levels
			Style(style) => (styled_definition(numbering, styles, style) ? |_| UnresolvedStyle(style)).levels
		}
		defined = levels.find_first(|candidate| candidate.level == at) ?? { ..unset_level, level: at }
		match found.overrides.find_first(|candidate| candidate.level == at) {
			Ok(override) => {
				replaced = match override.replacement {
					Replaced(replacement) => { ..replacement, level: at }
					Unset => defined
				}
				match override.start {
					Start(_) => Ok({ ..replaced, start: override.start })
					Unset => Ok(replaced)
				}
			}

			Err(NotFound) => Ok(defined)
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

is_element : XmlTree.Node, Str -> Bool
is_element = |node, local|
	match node {
		Element(element) => is_w(element.name, local)
		Text(_) => Bool.False
	}

is_content : XmlTree.Node -> Bool
is_content = |node|
	match node {
		Element(_) => Bool.True
		Text(content) => !content.to_utf8().all(|byte| byte == 32 or byte == 9 or byte == 10 or byte == 13)
	}

# The attributes of an element other than these WordprocessingML ones.
other_attributes : Element, List(Str) -> List(XmlTree.Attribute)
other_attributes = |element, locals| element.attributes.drop_if(|attribute| attribute.name.namespace == Uri(wordprocessingml) and locals.contains(attribute.name.local))

number_of : Element, Str -> Try(U32, [Unreadable])
number_of = |element, local| Ok(U32.from_str(value_of(element, local) ? |_| Unreadable) ? |_| Unreadable)

# The `w:val` of an element that has no other attribute and no content.
only_value : Element -> Try(Str, [Unreadable])
only_value = |element|
	if element.attributes.len() == 1 and !element.children.any(is_content) {
		Ok(value_of(element, "val") ? |_| Unreadable)
	} else {
		Err(Unreadable)
	}

unset_level : Numbering.Level
unset_level = {
	level: 0,
	start: Unset,
	format: Unset,
	text: Unset,
	alignment: Unset,
	paragraph_style: Unset,
	paragraph: Document.no_paragraph_properties,
	run: Document.no_run_properties,
	preserved_attributes: [],
	preserved: [],
}

definition_of : Element -> Numbering.Definition
definition_of = |element| {
	var $definition = { kind: Unset, style: Unset, uses_style: Unset, levels: List.with_capacity(element.children.len()), preserved_attributes: other_attributes(element, ["abstractNumId"]), preserved: List.with_capacity(2) }
	var $taken = List.with_capacity(4)
	for child in element.children {
		read = match child {
			Element(found) if found.name.namespace == Uri(wordprocessingml) and !$taken.contains(found.name.local) =>
				match (found.name.local, only_value(found)) {
					("multiLevelType", Ok("singleLevel")) => Ok({ ..$definition, kind: SingleLevel })
					("multiLevelType", Ok("multilevel")) => Ok({ ..$definition, kind: Multilevel })
					("multiLevelType", Ok("hybridMultilevel")) => Ok({ ..$definition, kind: HybridMultilevel })
					("styleLink", Ok(style)) => Ok({ ..$definition, style: Style(style) })
					("numStyleLink", Ok(style)) => Ok({ ..$definition, uses_style: Style(style) })
					("lvl", _) =>
						match level_of(found) {
							Ok(level) if !$definition.levels.any(|other| other.level == level.level) => Ok({ ..$definition, levels: List.append($definition.levels, level) })
							_ => Err(Unreadable)
						}

					_ => Err(Unreadable)
				}

			_ => Err(Unreadable)
		}
		match (read, child) {
			(Ok(next), Element(found)) => {
				$definition = next
				if found.name.local != "lvl" {
					$taken = List.append($taken, found.name.local)
				}
			}

			_ => {
				if is_content(child) {
					$definition = { ..$definition, preserved: List.append($definition.preserved, child) }
				}
			}
		}
	}
	$definition
}

# A level from its `w:lvl` element, which must name its level.
level_of : Element -> Try(Numbering.Level, [Unreadable])
level_of = |element| {
	at = U8.from_str(value_of(element, "ilvl") ? |_| Unreadable) ? |_| Unreadable
	var $level = { ..unset_level, level: at, preserved_attributes: other_attributes(element, ["ilvl"]), preserved: List.with_capacity(2) }
	var $taken = List.with_capacity(8)
	for child in element.children {
		read = match child {
			Element(found) if found.name.namespace == Uri(wordprocessingml) and !$taken.contains(found.name.local) => level_property($level, found)
			_ => Err(Unreadable)
		}
		match (read, child) {
			(Ok(next), Element(found)) => {
				$level = next
				$taken = List.append($taken, found.name.local)
			}

			_ => {
				if is_content(child) {
					$level = { ..$level, preserved: List.append($level.preserved, child) }
				}
			}
		}
	}
	Ok($level)
}

# One element of a level read into it, or `Unreadable` when the model cannot
# hold it.
level_property : Numbering.Level, Element -> Try(Numbering.Level, [Unreadable])
level_property = |level, element|
	match element.name.local {
		"start" => Ok({ ..level, start: Start(I32.from_str(only_value(element)?) ? |_| Unreadable) })
		"numFmt" =>
			match only_value(element)? {
				"bullet" => Ok({ ..level, format: Bullet })
				"none" => Ok({ ..level, format: NoNumber })
				format => Ok({ ..level, format: Number(format) })
			}

		"lvlText" => Ok({ ..level, text: Text(only_value(element)?) })
		"lvlJc" => Ok({ ..level, alignment: Aligned(WmlRead.alignment(only_value(element)?) ? |_| Unreadable) })
		"pStyle" => Ok({ ..level, paragraph_style: Style(only_value(element)?) })
		"pPr" if element.attributes.is_empty() => Ok({ ..level, paragraph: WmlRead.paragraph_properties(element.children) })
		"rPr" if element.attributes.is_empty() => Ok({ ..level, run: WmlRead.run_properties(element.children) })
		_ => Err(Unreadable)
	}

# An instance from its `w:num` element, which must name its definition.
instance_of : Element -> Try(Numbering.Instance, [Unreadable])
instance_of = |element| {
	var $definition = Err(Unreadable)
	var $overrides = List.with_capacity(element.children.len())
	var $preserved = List.with_capacity(0)
	for child in element.children {
		read = match child {
			Element(found) if is_w(found.name, "abstractNumId") and $definition == Err(Unreadable) =>
				match only_value(found) {
					Ok(value) =>
						match U32.from_str(value) {
							Ok(id) => Ok(Definition(id))
							Err(_) => Err(Unreadable)
						}

					Err(Unreadable) => Err(Unreadable)
				}

			_ => Err(Unreadable)
		}
		match read {
			Ok(found) => {
				$definition = Ok(found)
			}

			Err(Unreadable) =>
				match child {
					Element(found) if is_w(found.name, "lvlOverride") =>
						match override_of(found) {
							Ok(override) if !$overrides.any(|other| other.level == override.level) => {
								$overrides = List.append($overrides, override)
							}

							_ => {
								$preserved = List.append($preserved, child)
							}
						}

					_ => {
						if is_content(child) {
							$preserved = List.append($preserved, child)
						}
					}
				}
		}
	}
	Ok({ definition: $definition?, overrides: $overrides, preserved_attributes: other_attributes(element, ["numId"]), preserved: $preserved })
}

# A level override from its `w:lvlOverride` element, read whole or not at
# all: its level, at most one start override and at most one replacement
# level, which must be the level it overrides.
override_of : Element -> Try(Numbering.Override, [Unreadable])
override_of = |element| {
	if !other_attributes(element, ["ilvl"]).is_empty() {
		return Err(Unreadable)
	}
	at = U8.from_str(value_of(element, "ilvl") ? |_| Unreadable) ? |_| Unreadable
	var $override = { level: at, start: Unset, replacement: Unset }
	for child in element.children {
		match child {
			Element(found) if is_w(found.name, "startOverride") and $override.start == Unset => {
				$override = { ..$override, start: Start(I32.from_str(only_value(found)?) ? |_| Unreadable) }
			}

			Element(found) if is_w(found.name, "lvl") and $override.replacement == Unset => {
				replacement = level_of(found)?
				if replacement.level != at {
					return Err(Unreadable)
				}
				$override = { ..$override, replacement: Replaced(replacement) }
			}

			_ => {
				if is_content(child) {
					return Err(Unreadable)
				}
			}
		}
	}
	Ok($override)
}

# The definition a numbering style leads to: that of the instance the style
# names, with its bases, or failing that the first definition that stands
# for the style; either must have levels of its own rather than use a style.
styled_definition : Numbering, Styles, Str -> Try(Numbering.Definition, [NotFound])
styled_definition = |numbering, styles, style| {
	found = match through_style(numbering, styles, style) {
		Ok(definition) => definition
		Err(NotFound) => numbering.definitions.get(numbering.style_links.get(style) ? |_| NotFound) ? |_| NotFound
	}
	if found.uses_style == Unset {
		Ok(found)
	} else {
		Err(NotFound)
	}
}

# The definition of the instance a numbering style names.
through_style : Numbering, Styles, Str -> Try(Numbering.Definition, [NotFound])
through_style = |numbering, styles, style| {
	if (Styles.get(styles, style)?).kind != Numbering {
		return Err(NotFound)
	}
	match (Styles.inherited(styles, style)?).paragraph.numbering.instance {
		Instance(id) if id != 0 => {
			named = numbering.instances.get(id) ? |_| NotFound
			Definition(definition_id) = named.definition
			Ok(numbering.definitions.get(definition_id) ? |_| NotFound)
		}

		_ => Err(NotFound)
	}
}

# The numbering table of a numbering part with this content.
table_of : Str -> { numbering : Numbering, diagnostics : List(Numbering.Diagnostic) }
table_of = |content| {
	tree = XmlTree.parse("<w:numbering xmlns:w='${wordprocessingml}'>${content}</w:numbering>".to_utf8(), {}) ?? Text("")
	Numbering.read(tree)
}

sample : Str
sample =
	\\<w:abstractNum w:abstractNumId="1"><w:nsid w:val="4F176EFD"/><w:multiLevelType w:val="hybridMultilevel"/>
	\\<w:lvl w:ilvl="0" w:tplc="0409000F"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/><w:lvlJc w:val="left"/><w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr></w:lvl>
	\\<w:lvl w:ilvl="1"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="o"/><w:suff w:val="space"/><w:rPr><w:rFonts w:ascii="Courier New"/></w:rPr></w:lvl>
	\\<w:lvl w:ilvl="2"><w:numFmt w:val="none"/><w:lvlText w:val=""/></w:lvl>
	\\</w:abstractNum>
	\\<w:abstractNum w:abstractNumId="2"><w:lvl w:ilvl="0"><w:numFmt w:val="upperRoman"/></w:lvl></w:abstractNum>
	\\<w:num w:numId="1"><w:abstractNumId w:val="1"/></w:num>
	\\<w:num w:numId="2"><w:abstractNumId w:val="1"/><w:lvlOverride w:ilvl="0"><w:startOverride w:val="4"/></w:lvlOverride><w:lvlOverride w:ilvl="1"><w:lvl w:ilvl="1"><w:numFmt w:val="lowerLetter"/><w:lvlText w:val="%2)"/></w:lvl></w:lvlOverride></w:num>

## A definition is read with its kind and levels, and what the model does
## not hold stays with the definition or level it was read from.
expect {
	read = table_of(sample)
	definition = Numbering.definition(read.numbering, Definition(1))?
	first = definition.levels.get(0)?
	second = definition.levels.get(1)?
	third = definition.levels.get(2)?
	read.diagnostics == []
		and definition.kind == HybridMultilevel
		and definition.levels.len() == 3
		and definition.preserved.len() == 1
		and first.start == Start(1)
		and first.format == Number("decimal")
		and first.text == Text("%1.")
		and first.alignment == Aligned(Left)
		and first.paragraph.indentation == { left: Twips(720), right: Unset, first_line: Hanging(360) }
		and first.preserved_attributes.len() == 1
		and second.format == Bullet
		and second.run.fonts.ascii == Named("Courier New")
		and second.preserved.len() == 1
		and third.format == NoNumber
		and third.text == Text("")
}

## An instance's level is its definition's, with the start an override gives
## or the level an override puts in its place; a level the definition does
## not give has nothing set, and a reference without a level is at level 0.
expect {
	numbering = table_of(sample).numbering
	at = |instance, level| Numbering.level(numbering, Styles.empty, { instance: Instance(instance), level })
	plain = at(1, Unset)?
	restarted = at(2, Level(0))?
	replaced = at(2, Level(1))?
	undefined = at(1, Level(5))?
	plain.level == 0
		and plain.start == Start(1)
		and restarted.start == Start(4)
		and restarted.format == Number("decimal")
		and replaced.format == Number("lowerLetter")
		and replaced.text == Text("%2)")
		and replaced.start == Unset
		and undefined.level == 5
		and undefined.format == Unset
		and undefined.paragraph == Document.no_paragraph_properties
}

## A reference to no instance, to instance 0, to an instance that does not
## exist or to one whose definition does not exist names no list level.
expect {
	read = table_of("${sample}<w:num w:numId='7'><w:abstractNumId w:val='9'/></w:num>")
	at = |instance| Numbering.level(read.numbering, Styles.empty, { instance, level: Level(0) }).map_ok(|level| level.level)
	read.diagnostics == [MissingDefinition({ instance: 7, definition: 9 })]
		and at(Unset) == Err(NotListed)
		and at(Instance(0)) == Err(NotListed)
		and at(Instance(5)) == Err(MissingInstance(5))
		and at(Instance(7)) == Err(MissingDefinition({ instance: 7, definition: 9 }))
}

## A definition that uses a numbering style takes the levels of the
## definition the style's instance uses, or failing that of the definition
## that stands for the style; a style that leads nowhere names no level.
expect {
	content =
		\\<w:abstractNum w:abstractNumId="1"><w:numStyleLink w:val="Legal"/></w:abstractNum>
		\\<w:abstractNum w:abstractNumId="2"><w:styleLink w:val="Legal"/><w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/></w:lvl></w:abstractNum>
		\\<w:abstractNum w:abstractNumId="3"><w:lvl w:ilvl="0"><w:numFmt w:val="upperLetter"/></w:lvl></w:abstractNum>
		\\<w:abstractNum w:abstractNumId="4"><w:numStyleLink w:val="Nowhere"/></w:abstractNum>
		\\<w:num w:numId="1"><w:abstractNumId w:val="1"/></w:num>
		\\<w:num w:numId="2"><w:abstractNumId w:val="3"/></w:num>
		\\<w:num w:numId="3"><w:abstractNumId w:val="4"/></w:num>
	numbering = table_of(content).numbering
	styles_xml = "<w:styles xmlns:w='${wordprocessingml}'><w:style w:type='numbering' w:styleId='Legal'><w:pPr><w:numPr><w:numId w:val='2'/></w:numPr></w:pPr></w:style></w:styles>"
	styles = Styles.read(XmlTree.parse(styles_xml.to_utf8(), {}) ?? Text("")).styles
	format = |with_styles, instance| Numbering.level(numbering, with_styles, { instance: Instance(instance), level: Unset }).map_ok(|level| level.format)
	format(styles, 1) == Ok(Number("upperLetter"))
		and format(Styles.empty, 1) == Ok(Bullet)
		and format(styles, 3) == Err(UnresolvedStyle("Nowhere"))
}

## Definitions and instances without usable identifiers, or with ones already
## taken, are skipped with a diagnostic, and an override that cannot be read
## whole stays with its instance.
expect {
	content =
		\\<w:abstractNum><w:lvl w:ilvl="0"/></w:abstractNum>
		\\<w:abstractNum w:abstractNumId="1"/>
		\\<w:abstractNum w:abstractNumId="1"/>
		\\<w:num w:numId="1"/>
		\\<w:num w:numId="2"><w:abstractNumId w:val="1"/><w:lvlOverride w:ilvl="0"><w:lvl w:ilvl="3"/></w:lvlOverride></w:num>
		\\<w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>
	read = table_of(content)
	instance = Numbering.instance(read.numbering, Instance(2))?
	read.diagnostics == [UnreadableDefinition({ position: 1 }), DuplicateDefinition(1), UnreadableInstance({ position: 1 }), DuplicateInstance(2)]
		and instance.overrides == []
		and instance.preserved.len() == 1
}

## A tree that is not a numbering part has no definitions and no instances.
expect {
	read = Numbering.read(XmlTree.parse("<w:styles xmlns:w='${wordprocessingml}'/>".to_utf8(), {}) ?? Text(""))
	read.diagnostics == [] and Numbering.instance(read.numbering, Instance(1)) == Err(NotFound)
}
