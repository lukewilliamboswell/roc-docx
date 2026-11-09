app [target] {
	docx: "../../package/main.roc",
	fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.5.0/9WT86CuwM7ZJBSs8iTd1jLyrUFTTiGp5hcJE63TwswGE.tar.zst",
	zip: "https://github.com/lukewilliamboswell/roc-zip/releases/download/0.3.0-rc1/3vvx2cPVp1vjjVgrXcugJqqfrp55ZrURYQUcSArAUHdr.tar.zst",
}

import fuzz.Fuzz
import docx.Numbering
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
import "../../tests/fixtures/libreoffice/lists.docx" as libreoffice_lists : List(U8)
import "../../tests/fixtures/libreoffice/review.docx" as libreoffice_review : List(U8)
import "../../tests/fixtures/word/report.docx" as word_report : List(U8)
import "../../tests/fixtures/gdocs/resume.docx" as gdocs_resume : List(U8)

## List levels resolve as a direct evaluation of the numbering rules gives
## them. A program describes up to six numbering definitions, each with up
## to four levels of a bullet, no number, a numbered format or none stated,
## and a start or none, each perhaps standing for one of two numbering styles
## or using one; up to eight instances, each naming a definition or one that
## does not exist, with start overrides and replacement levels; and the two
## numbering styles, each naming an instance, instance 0, one that does not
## exist or none. The definitions and instances are written as a numbering
## part and the styles as a styles part, read by `Numbering.read` and
## `Styles.read`, and every instance from 0 to one past the last, at no
## level and at levels 0 to 4, resolves by `Numbering.level` to the format
## and start, or the reason it is not listed, that a separately written walk
## of the description gives. Every fixture's numbering part reads, and every
## one of its instances resolves at every level.
##
## Allocation ratchets, which only ever move down: reading allocates at most
## linearly in the part's bytes and resolving a reference at most a
## constant, and each declared example allocates no more than it did when its
## ceiling was set. The large table, sixteen times the small one's
## definitions and instances, reads with at most seventeen times the small
## one's allocations and requested bytes in the same run, and resolves its
## last instance for no more than the small table's last. Raising a ceiling
## needs a cause recorded in the pull request.
test! : Input => Fuzz.Outcome
test! = |input|
	match input {
		Generated(program) => {
			agree!(describe(program))
			Fuzz.keep
		}

		# Exploration mutates the declared examples; a table of another size
		# is not one of them.
		Table(size) =>
			match tables.find_first(|table| table.size == size) {
				Ok(table) => {
					small = table_cost!(16)
					cost = table_cost!(size)
					if cost.read > table.allocations {
						crash "a declared table allocated more than its ceiling"
					}
					if cost.read > 17 * small.read or cost.requested_bytes > 17 * small.requested_bytes {
						crash "the large table read for more than seventeen times the small one"
					}
					if cost.resolve > small.resolve {
						crash "resolving in a large table cost more than in a small one"
					}
					Fuzz.keep
				}

				Err(_) => Fuzz.reject
			}

		Fixture(index) =>
			match fixtures.get(index) {
				Ok(fixture) => {
					entries = Zip.extract(fixture.bytes) ?? crash "a fixture is not a ZIP archive"
					part = entries.find_first(|entry| entry.path == "word/numbering.xml") ?? crash "a fixture has no numbering part"
					tree = XmlTree.parse(part.content, {}) ?? crash "a fixture's numbering part does not read"
					{ value: read, stats } = Fuzz.measure!("numbering-read", || Numbering.read(tree))
					check_read(stats, part.content.len())
					if stats.allocs + stats.reallocs > fixture.allocations {
						crash "a fixture's numbering allocated more than its ceiling"
					}
					if !read.diagnostics.is_empty() {
						crash "a fixture's numbering part reads with a diagnostic"
					}
					for instance in fixture.instances {
						for level in upto(9) {
							resolved = resolve!(read.numbering, Styles.empty, Instance(instance), Level(level.to_u8_wrap()))
							if resolved.is_err() {
								crash "a fixture's instance does not resolve"
							}
						}
					}
					Fuzz.keep
				}

				Err(_) => Fuzz.reject
			}
	}

Input : [Generated(List(U8)), Table(U64), Fixture(U64)]

generator : Fuzz.Generator(Input)
generator = Fuzz.map(Fuzz.bytes, |program| Generated(program))

# A generated level: how it is numbered and its start, each perhaps unstated.
GenLevel : { format : Numbering.Format, start : [Unset, Start(I32)] }

# A generated definition: its levels 0 to 3, each perhaps absent; whether it
# stands for a numbering style, uses one, or neither.
GenDefinition : { levels : List([Absent, Present(GenLevel)]), link : [NoLink, Stands(U64), Uses(U64)] }

# A generated instance: the definition it names by index, or one that does
# not exist, and its override of each level 0 to 3.
GenInstance : { definition : [Index(U64), Missing], overrides : List([NoOverride, Override({ start : [Unset, Start(I32)], replacement : [Unset, Replaced(GenLevel)] })]) }

# A numbering style's instance: none stated, 0, an instance by index, or one
# that does not exist.
GenStyle : [NoInstance, Zero, Index(U64), Missing]

Description : { definitions : List(GenDefinition), instances : List(GenInstance), styles : List(GenStyle) }

# The description a program of bytes gives: each byte read in turn,
# wrapping round, so every program describes something.
describe : List(U8) -> Description
describe = |program| {
	at = |index| if (program.is_empty()) 0 else (program.get(index % program.len()) ?? 0).to_u64()
	definition_count = at(0) % 6 + 1
	instance_count = at(1) % 8 + 1
	level = |offset| {
		format: match at(offset) % 5 {
			0 => Bullet
			1 => NoNumber
			2 => Number("decimal")
			3 => Number("lowerRoman")
			_ => Unset
		},
		start: if (at(offset + 1) % 3 == 0) Unset else Start((at(offset + 1) % 7).to_i32_wrap()),
	}
	definitions = List.repeat(0, definition_count).map_with_index(
		|_, index| {
			offset = 2 + index * 9
			{
				levels: upto(4).map(|position| if (at(offset + 1 + 2 * position) % 4 == 0) Absent else Present(level(offset + 1 + 2 * position))),
				link: match at(offset) % 4 {
					1 => Stands(at(offset) // 4 % 2)
					2 => Uses(at(offset) // 4 % 2)
					_ => NoLink
				},
			}
		},
	)
	next = 2 + definition_count * 9
	instances = List.repeat(0, instance_count).map_with_index(
		|_, index| {
			offset = next + index * 9
			choice = at(offset)
			{
				definition: if (choice % 7 == 6) Missing else Index(choice % definition_count),
				overrides: upto(4).map(
					|position| {
						kind = at(offset + 1 + 2 * position)
						if kind % 3 == 0 {
							Override({
								start: if (kind // 3 % 2 == 0) Unset else Start((kind % 5).to_i32_wrap()),
								replacement: if (kind // 6 % 2 == 0) Unset else Replaced(level(offset + 2 + 2 * position)),
							})
						} else {
							NoOverride
						}
					},
				),
			}
		},
	)
	last = next + instance_count * 9
	style = |byte|
		match byte % 5 {
			0 => NoInstance
			1 => Zero
			2 => Missing
			_ => Index(byte // 5 % instance_count)
		}
	{ definitions, instances, styles: [style(at(last)), style(at(last + 1))] }
}

# The numbers from 0 to one before `count`.
upto : U64 -> List(U64)
upto = |count| List.repeat(0, count).map_with_index(|_, index| index)

style_id : U64 -> Str
style_id = |index| "List${index.to_str()}"

level_xml : U64, GenLevel -> Str
level_xml = |position, level| {
	start = match level.start {
		Start(value) => "<w:start w:val=\"${value.to_str()}\"/>"
		Unset => ""
	}
	format = match level.format {
		Bullet => "<w:numFmt w:val=\"bullet\"/>"
		NoNumber => "<w:numFmt w:val=\"none\"/>"
		Number(name) => "<w:numFmt w:val=\"${name}\"/>"
		Unset => ""
	}
	"<w:lvl w:ilvl=\"${position.to_str()}\">${start}${format}</w:lvl>"
}

# The description's definitions and instances as a numbering part, the
# definitions numbered from 1 and the instances from 1, and its styles as a
# styles part.
numbering_xml : Description -> Str
numbering_xml = |description| {
	definitions = description.definitions.map_with_index(
		|definition, index| {
			link = match definition.link {
				Stands(style) => "<w:styleLink w:val=\"${style_id(style)}\"/>"
				Uses(style) => "<w:numStyleLink w:val=\"${style_id(style)}\"/>"
				NoLink => ""
			}
			levels = definition.levels.map_with_index(
				|level, position|
					match level {
						Present(found) => level_xml(position, found)
						Absent => ""
					},
			)
			"<w:abstractNum w:abstractNumId=\"${(index + 1).to_str()}\">${link}${Str.join_with(levels, "")}</w:abstractNum>"
		},
	)
	instances = description.instances.map_with_index(
		|instance, index| {
			definition = match instance.definition {
				Index(found) => found + 1
				Missing => 99
			}
			overrides = instance.overrides.map_with_index(
				|override, position|
					match override {
						Override({ start, replacement }) => {
							start_xml = match start {
								Start(value) => "<w:startOverride w:val=\"${value.to_str()}\"/>"
								Unset => ""
							}
							replacement_xml = match replacement {
								Replaced(level) => level_xml(position, level)
								Unset => ""
							}
							"<w:lvlOverride w:ilvl=\"${position.to_str()}\">${start_xml}${replacement_xml}</w:lvlOverride>"
						}

						NoOverride => ""
					},
			)
			"<w:num w:numId=\"${(index + 1).to_str()}\"><w:abstractNumId w:val=\"${definition.to_str()}\"/>${Str.join_with(overrides, "")}</w:num>"
		},
	)
	"<w:numbering xmlns:w=\"${w}\">${Str.join_with(definitions, "")}${Str.join_with(instances, "")}</w:numbering>"
}

styles_xml : Description -> Str
styles_xml = |description| {
	styles = description.styles.map_with_index(
		|style, index| {
			reference = match style {
				NoInstance => ""
				Zero => "<w:pPr><w:numPr><w:numId w:val=\"0\"/></w:numPr></w:pPr>"
				Missing => "<w:pPr><w:numPr><w:numId w:val=\"99\"/></w:numPr></w:pPr>"
				Index(found) => "<w:pPr><w:numPr><w:numId w:val=\"${(found + 1).to_str()}\"/></w:numPr></w:pPr>"
			}
			"<w:style w:type=\"numbering\" w:styleId=\"${style_id(index)}\">${reference}</w:style>"
		},
	)
	"<w:styles xmlns:w=\"${w}\">${Str.join_with(styles, "")}</w:styles>"
}

# What a reference resolves to, as the target compares it.
Resolved : Try({ format : Numbering.Format, start : [Unset, Start(I32)] }, Numbering.Unlisted)

resolve! : Numbering, Styles, [Unset, Instance(U32)], [Unset, Level(U8)] => Resolved
resolve! = |numbering, styles, instance, level| {
	{ value, stats } = Fuzz.measure!("numbering-level", || Numbering.level(numbering, styles, { instance, level }))
	check_resolve(stats)
	value.map_ok(|found| { format: found.format, start: found.start })
}

# Read the description's tables and check every reference against the
# reference walk.
agree! : Description => {}
agree! = |description| {
	xml = numbering_xml(description)
	tree = XmlTree.parse(xml.to_utf8(), {}) ?? crash "a generated numbering part does not parse"
	{ value: read, stats } = Fuzz.measure!("numbering-read", || Numbering.read(tree))
	check_read(stats, xml.to_utf8().len())
	styles = Styles.read(XmlTree.parse(styles_xml(description).to_utf8(), {}) ?? crash "a generated styles part does not parse").styles
	instances = upto(description.instances.len() + 2)
	levels = [Unset, Level(0), Level(1), Level(2), Level(3), Level(4)]
	for instance in instances {
		for level in levels {
			actual = resolve!(read.numbering, styles, Instance(instance.to_u32_wrap()), level)
			if actual != reference(description, instance, level) {
				crash "a list level differs from a direct evaluation of the numbering"
			}
		}
	}
	{}
}

# The format and start of an instance's level, by walking the description:
# instance 0 is no list; an instance or definition that does not exist is a
# reason; a definition that uses a style takes the levels of the definition
# of the instance the style names, or failing that of the first definition
# standing for the style, which must not use a style itself; a start
# override replaces the level's start and a replacement level the level.
reference : Description, U64, [Unset, Level(U8)] -> Resolved
reference = |description, number, level| {
	if number == 0 {
		return Err(NotListed)
	}
	at = match level {
		Level(found) => found.to_u64()
		Unset => 0
	}
	instance = description.instances.get(number - 1) ? |_| MissingInstance(number.to_u32_wrap())
	definition_index = match instance.definition {
		Index(found) => found
		Missing => return Err(MissingDefinition({ instance: number.to_u32_wrap(), definition: 99 }))
	}
	definition = description.definitions.get(definition_index) ?? { levels: [], link: NoLink }
	levels = match definition.link {
		Uses(style) => {
			through_style = match description.styles.get(style) {
				Ok(Index(found)) =>
					match description.instances.get(found) {
						Ok({ definition: Index(linked), overrides: _ }) => description.definitions.get(linked)
						_ => Err(NotFound)
					}

				_ => Err(NotFound)
			}
			found = match through_style {
				Ok(linked) => linked
				Err(_) => description.definitions.find_first(|candidate| candidate.link == Stands(style)) ? |_| UnresolvedStyle(style_id(style))
			}
			match found.link {
				Uses(_) => return Err(UnresolvedStyle(style_id(style)))
				_ => found.levels
			}
		}

		_ => definition.levels
	}
	defined = match levels.get(at) {
		Ok(Present(found)) => found
		_ => { format: Unset, start: Unset }
	}
	match instance.overrides.get(at) {
		Ok(Override({ start, replacement })) => {
			replaced = match replacement {
				Replaced(found) => found
				Unset => defined
			}
			match start {
				Start(_) => Ok({ ..replaced, start })
				Unset => Ok(replaced)
			}
		}

		_ => Ok(defined)
	}
}

# A table of `size` definitions of three levels each and as many instances,
# each using the definition of its number with a start override, read and
# its last instance resolved: the allocations of each and the bytes reading
# requested.
table_cost! : U64 => { read : U64, requested_bytes : U64, resolve : U64 }
table_cost! = |size| {
	padded = |index| {
		digits = index.to_str()
		"${Str.repeat("0", 4 - Str.count_utf8_bytes(digits))}${digits}"
	}
	numbers = upto(size).map(|index| index + 1)
	definitions = numbers.map(|index| "<w:abstractNum w:abstractNumId=\"${padded(index)}\"><w:multiLevelType w:val=\"multilevel\"/>${level_xml(0, { format: Number("decimal"), start: Start(1) })}${level_xml(1, { format: Bullet, start: Unset })}${level_xml(2, { format: NoNumber, start: Unset })}</w:abstractNum>")
	instances = numbers.map(|index| "<w:num w:numId=\"${padded(index)}\"><w:abstractNumId w:val=\"${padded(index)}\"/><w:lvlOverride w:ilvl=\"0\"><w:startOverride w:val=\"1\"/></w:lvlOverride></w:num>")
	xml = "<w:numbering xmlns:w=\"${w}\">${Str.join_with(definitions, "")}${Str.join_with(instances, "")}</w:numbering>"
	tree = XmlTree.parse(xml.to_utf8(), {}) ?? crash "a table's numbering part does not parse"
	{ value: read, stats: read_stats } = Fuzz.measure!("numbering-read", || Numbering.read(tree))
	check_read(read_stats, xml.to_utf8().len())
	{ value: _, stats } = Fuzz.measure!("numbering-level", || Numbering.level(read.numbering, Styles.empty, { instance: Instance(size.to_u32_wrap()), level: Level(0) }))
	check_resolve(stats)
	{ read: read_stats.allocs + read_stats.reallocs, requested_bytes: read_stats.requested_bytes, resolve: stats.allocs + stats.reallocs }
}

# Reading allocates about a quarter of an allocation and holds 12 to 15
# bytes live for each byte of a numbering part (LibreOffice's 16,272-byte
# part: 4,102 allocations, 194 KB). A level holds its paragraph and run
# properties whole, so a part of bare levels holds more bytes live for each
# of its bytes than a real part, which the bound of 64 allows.
check_read : Fuzz.Stats, U64 -> {}
check_read = |stats, bytes| {
	if stats.allocs + stats.reallocs > 64 + bytes // 2 {
		crash "reading numbering allocated more than linearly in the part's bytes"
	}
	if stats.peak_live_bytes - stats.entry_live_bytes > 16_384 + 64 * bytes {
		crash "reading numbering held more than linearly many bytes live"
	}
	{}
}

check_resolve : Fuzz.Stats -> {}
check_resolve = |stats| {
	if stats.allocs + stats.reallocs > 2 {
		crash "resolving a numbering reference allocated more than a constant"
	}
	{}
}

# Exact ceilings: the allocations of reading a declared table's numbering
# part, measured on nightly-2026-11-07: about 98 a definition with its
# instance (1,586 and 25,118, a ratio of 15.8) and 509,132 and 8,081,292
# requested bytes, a ratio of 15.9. Resolving allocates nothing at either
# size.
tables : List({ size : U64, allocations : U64 })
tables = [
	{ size: 16, allocations: 1_586 },
	{ size: 256, allocations: 25_118 },
]

# Each fixture's numbering-reading allocations and its instances.
fixtures : List({ name : Str, bytes : List(U8), allocations : U64, instances : List(U32) })
fixtures = [
	{ name: "pandoc-basics", bytes: pandoc_basics, allocations: 432, instances: pandoc_instances },
	{ name: "pandoc-comments", bytes: pandoc_comments, allocations: 432, instances: pandoc_instances },
	{ name: "pandoc-lists", bytes: pandoc_lists, allocations: 1_735, instances: [1000, 1001, 1002, 1003, 1004, 1005] },
	{ name: "pandoc-notes", bytes: pandoc_notes, allocations: 432, instances: pandoc_instances },
	{ name: "pandoc-review", bytes: pandoc_review, allocations: 986, instances: [1000, 1001] },
	{ name: "pandoc-revisions", bytes: pandoc_revisions, allocations: 432, instances: pandoc_instances },
	{ name: "pandoc-tables", bytes: pandoc_tables, allocations: 432, instances: pandoc_instances },
	{ name: "libreoffice-lists", bytes: libreoffice_lists, allocations: 4_102, instances: [1, 2, 3, 4, 5, 6, 7, 8] },
	{ name: "libreoffice-review", bytes: libreoffice_review, allocations: 1_362, instances: [1, 2] },
	{ name: "word-report", bytes: word_report, allocations: 702, instances: [1, 2] },
	{ name: "gdocs-resume", bytes: gdocs_resume, allocations: 1_083, instances: [1, 2] },
]

pandoc_instances : List(U32)
pandoc_instances = [1000]

w : Str
w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

target = Fuzz.target_with!({
	name: "numbering-resolution",
	examples: [
		Fuzz.example({ name: "small-table", revision: "1", make: || Table(16) }),
		Fuzz.example({ name: "large-table", revision: "1", make: || Table(256) }),
	].concat(fixtures.map_with_index(|fixture, index| Fuzz.example({ name: fixture.name, revision: "1", make: || Fixture(index) }))),
	generator,
	test!,
	show: |input| Str.inspect(input),
})
