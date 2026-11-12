app [target] {
	docx: "../../package/main.roc",
	fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.1/GDoZFRDnzMRiVk9nE8wdWn52btGsM1GhcY9VDKqy9f1Y.tar.zst",
	zip: "https://github.com/lukewilliamboswell/roc-zip/releases/download/0.3.0-rc1/3vvx2cPVp1vjjVgrXcugJqqfrp55ZrURYQUcSArAUHdr.tar.zst",
}

import fuzz.Fuzz
import docx.Limits
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

## A namespaced tree written with the package's prefix table reads back as
## the same tree up to prefixes and declarations, and writing what was read
## gives the same bytes again. Generated trees come from a small program of
## input bytes; every XML part of every fixture document also reads,
## writes and reads back this way, so the corpus is read without error.
##
## Allocation ratchets, which only ever move down: reading and writing a
## part each allocate at most linearly in its written bytes and keep at most
## linearly many bytes live, and each declared example allocates no more
## than it did when its ceiling was set. The large declared tree, sixteen
## times the small one, allocates and requests at most sixteen times what
## the small one does in the same run. Raising a ceiling needs a cause
## recorded in the pull request.
test! : Input => Fuzz.Outcome
test! = |input| {
	match input {
		Generated(program) => {
			tree = build(program)
			trip = round_trip!(tree)
			if strip(trip.read) != tree {
				crash "a written tree read back as a different tree"
			}
			match examples_by_program.find_first(|example| example.program == program) {
				Ok(example) => {
					if trip.allocations > example.allocations {
						crash "a declared tree allocated more than its ceiling"
					}
				}

				Err(_) => {}
			}
			if program == large_program {
				small = round_trip!(build(small_program))
				if trip.allocations > 16 * small.allocations or trip.requested_bytes > 16 * small.requested_bytes {
					crash "the large tree cost more than sixteen times the small one"
				}
			}
			Fuzz.keep
		}

		Fixture(index) =>
			match fixtures.get(index) {
				Ok(fixture) => {
					entries = Zip.extract(fixture.bytes) ?? crash "a fixture is not a ZIP archive"
					var $allocations = 0.U64
					for entry in entries {
						if entry.path.ends_with(".xml") or entry.path.ends_with(".rels") {
							{ value: read, stats } = Fuzz.measure!("xml-tree-parse", || XmlTree.parse(entry.content, {}))
							check_linear(stats, entry.content.len(), "reading a fixture part")
							tree = read ?? crash "a fixture part does not read as namespaced XML"
							trip = round_trip!(tree)
							if strip(trip.read) != strip(tree) {
								crash "a fixture part read back as a different tree"
							}
							$allocations = $allocations + stats.allocs + stats.reallocs + trip.allocations
						}
					}
					if $allocations > fixture.allocations {
						crash "a fixture allocated more than its ceiling"
					}
					Fuzz.keep
				}

				Err(_) => Fuzz.reject
			}
	}
}

# Exploration generates programs; the fixtures are declared examples.
Input : [Generated(List(U8)), Fixture(U64)]

generator : Fuzz.Generator(Input)
generator = Fuzz.map(Fuzz.bytes, |program| Generated(program))

# Write a tree and read it back, measuring both, then check that writing
# what was read gives the same bytes.
round_trip! : XmlTree.Node => { read : XmlTree.Node, allocations : U64, requested_bytes : U64 }
round_trip! = |tree| {
	{ value: rendered, stats: render_stats } = Fuzz.measure!("xml-tree-render", || XmlTree.render(tree))
	bytes = rendered ?? crash "a tree in the prefix table's namespaces could not be written"
	check_linear(render_stats, bytes.len(), "writing a part")
	{ value: parsed, stats: read_stats } = Fuzz.measure!("xml-tree-parse", || XmlTree.parse(bytes, {}))
	check_linear(read_stats, bytes.len(), "reading a written part")
	read = parsed ?? crash "a written part does not read back"
	if XmlTree.render(read) != Ok(bytes) {
		crash "writing a tree read from written bytes gave different bytes"
	}
	{
		read,
		allocations: render_stats.allocs + render_stats.reallocs + read_stats.allocs + read_stats.reallocs,
		requested_bytes: render_stats.requested_bytes + read_stats.requested_bytes,
	}
}

# A measured operation allocates at most linearly in the part's bytes, and
# the bytes it holds live beyond what it was given grow at most linearly.
check_linear : Fuzz.Stats, U64, Str -> {}
check_linear = |stats, part_bytes, operation| {
	if stats.allocs + stats.reallocs > linear_allocation_ceiling(part_bytes) {
		crash "${operation} allocated more than linearly in the part's bytes"
	}
	if stats.peak_live_bytes - stats.entry_live_bytes > linear_memory_ceiling(part_bytes) {
		crash "${operation} held more than linearly many bytes live"
	}
	{}
}

# Measured on nightly-2026-11-07 with roc-parser 6.0.0-rc.1: reading the
# largest fixture part, 27,124 bytes of styles, takes 1,437 allocations and
# 355 KB beyond its input, writing it 2,528 and 291 KB; the constants cover
# the prefix table and the smallest parts.
linear_allocation_ceiling : U64 -> U64
linear_allocation_ceiling = |part_bytes| 64 + 2 * part_bytes

linear_memory_ceiling : U64 -> U64
linear_memory_ceiling = |part_bytes| 16_384 + 320 * part_bytes

# The declared large tree repeats the small tree's program sixteen times.
# The property compares their allocation and requested-byte growth directly.
small_program : List(U8)
small_program = List.join(List.repeat(program_unit, 4))

large_program : List(U8)
large_program = List.join(List.repeat(program_unit, 64))

# Opens a `w` element with attributes in the `w` and `r` namespaces and in
# none, whose values and text need escaping, then a child in no namespace
# with non-ASCII text, and closes both.
program_unit : List(U8)
program_unit = [0, 99, 140, 27, 23, 42, 55, 5, 5]

# Exact ceilings: the allocations of every measured region of an example,
# measured on nightly-2026-11-10-f7d1f19 with roc-fuzz 0.6.0.
examples_by_program : List({ program : List(U8), allocations : U64 })
examples_by_program = [
	{ program: small_program, allocations: 234 },
	{ program: large_program, allocations: 2_717 },
]

fixtures : List({ name : Str, bytes : List(U8), allocations : U64 })
fixtures = [
	{ name: "pandoc-basics", bytes: pandoc_basics, allocations: 12_464 },
	{ name: "pandoc-comments", bytes: pandoc_comments, allocations: 11_801 },
	{ name: "pandoc-lists", bytes: pandoc_lists, allocations: 13_711 },
	{ name: "pandoc-notes", bytes: pandoc_notes, allocations: 11_540 },
	{ name: "pandoc-review", bytes: pandoc_review, allocations: 13_272 },
	{ name: "pandoc-revisions", bytes: pandoc_revisions, allocations: 11_538 },
	{ name: "pandoc-tables", bytes: pandoc_tables, allocations: 12_816 },
	{ name: "libreoffice-basics", bytes: libreoffice_basics, allocations: 10_774 },
	{ name: "libreoffice-comments", bytes: libreoffice_comments, allocations: 10_396 },
	{ name: "libreoffice-lists", bytes: libreoffice_lists, allocations: 15_963 },
	{ name: "libreoffice-notes", bytes: libreoffice_notes, allocations: 10_465 },
	{ name: "libreoffice-review", bytes: libreoffice_review, allocations: 14_122 },
	{ name: "libreoffice-revisions", bytes: libreoffice_revisions, allocations: 10_029 },
	{ name: "libreoffice-tables", bytes: libreoffice_tables, allocations: 15_498 },
]

# The tree a program of bytes describes. Each byte is one step: its low
# three bits choose the step and the rest choose among its variants. The
# root is always a WordprocessingML or relationships element; a step that
# does not apply where it falls is skipped, so every program is a tree, and
# an element that would nest deeper than the default depth limit is not
# opened, so every tree can be read back.
build : List(U8) -> XmlTree.Node
build = |program| {
	root_namespace =
		if (program.first() ?? 0) % 2 == 0 {
			Uri("http://schemas.openxmlformats.org/wordprocessingml/2006/main")
		} else {
			Uri("http://schemas.openxmlformats.org/package/2006/relationships")
		}
	var $open = [{ name: { namespace: root_namespace, local: "root", prefix: Unprefixed }, attributes: [], children: [] }]
	for byte in program.drop_first(1) {
		variant = (byte // 8).to_u64()
		$open = match byte % 8 {
			0 | 1 => open_one($open, name_of(variant))
			2 => open_one($open, { namespace: NoNamespace, local: pick(locals, variant), prefix: Unprefixed })
			3 | 4 => add_attribute($open, { name: name_of(variant), value: pick(texts, variant // 3) })
			5 | 6 => close_one($open)
			_ => add_text($open, pick(texts, variant))
		}
	}
	while $open.len() > 1 {
		$open = close_one($open)
	}
	match $open.first() {
		Ok(root) => as_node(root)
		Err(_) => Text("")
	}
}

Open : { name : XmlTree.Name, attributes : List(XmlTree.Attribute), children : List(XmlTree.Node) }

as_node : Open -> XmlTree.Node
as_node = |open| Element({ name: open.name, bindings: [], attributes: open.attributes, children: open.children })

update_last : List(Open), (Open -> Open) -> List(Open)
update_last = |open, change|
	match open.last() {
		Ok(last) => List.append(List.drop_last(open, 1), change(last))
		Err(_) => open
	}

open_one : List(Open), XmlTree.Name -> List(Open)
open_one = |open, name| {
	limits : Limits
	limits = {}
	if open.len() < limits.max_xml_depth {
		List.append(open, { name, attributes: [], children: [] })
	} else {
		open
	}
}

close_one : List(Open) -> List(Open)
close_one = |open|
	if open.len() < 2 {
		open
	} else {
		match open.last() {
			Ok(last) => update_last(List.drop_last(open, 1), |parent| { name: parent.name, attributes: parent.attributes, children: List.append(parent.children, as_node(last)) })
			Err(_) => open
		}
	}

# An attribute is skipped when its element already has one of that name.
add_attribute : List(Open), XmlTree.Attribute -> List(Open)
add_attribute = |open, attribute|
	update_last(
		open,
		|element|
			if element.attributes.any(|existing| existing.name.namespace == attribute.name.namespace and existing.name.local == attribute.name.local) {
				element
			} else {
				{ name: element.name, attributes: List.append(element.attributes, attribute), children: element.children }
			},
	)

# Text directly after text would read back as one run, so it is skipped.
add_text : List(Open), Str -> List(Open)
add_text = |open, content|
	update_last(
		open,
		|element|
			match element.children.last() {
				Ok(Text(_)) => element
				_ => { name: element.name, attributes: element.attributes, children: List.append(element.children, Text(content)) }
			},
	)

name_of : U64 -> XmlTree.Name
name_of = |variant| {
	namespace = namespaces_used.get(variant % namespaces_used.len()) ?? NoNamespace
	{ namespace, local: pick(locals, variant // namespaces_used.len()), prefix: Unprefixed }
}

# Namespaces from the prefix table and no namespace, which attributes use.
namespaces_used : List(XmlTree.Namespace)
namespaces_used = [
	Uri("http://schemas.openxmlformats.org/wordprocessingml/2006/main"),
	Uri("http://schemas.openxmlformats.org/officeDocument/2006/relationships"),
	Uri("http://schemas.microsoft.com/office/word/2010/wordml"),
	NoNamespace,
]

locals : List(Str)
locals = ["p", "r", "t", "val", "rsidR", "x-y.z", "_a1", "é"]

texts : List(Str)
texts = ["a", " ", "a & b < c > d", "\"quoted\" 'single'", "\t\n\r", "]]>", "é € 😀", "  spaced  "]

pick : List(Str), U64 -> Str
pick = |choices, index| choices.get(index % choices.len()) ?? ""

# A tree with every prefix and declaration removed, which is how a written
# tree compares with the tree it was written from.
strip : XmlTree.Node -> XmlTree.Node
strip = |node|
	match node {
		Element(element) =>
			Element({
				name: unprefixed(element.name),
				bindings: [],
				attributes: element.attributes.map(|attribute| { name: unprefixed(attribute.name), value: attribute.value }),
				children: element.children.map(strip),
			})

		Text(content) => Text(content)
	}

unprefixed : XmlTree.Name -> XmlTree.Name
unprefixed = |name| { namespace: name.namespace, local: name.local, prefix: Unprefixed }

target = Fuzz.target_with!({
	name: "xml-namespace-roundtrip",
	examples: [
		Fuzz.example({ name: "small-tree", revision: "1", make: || Generated(small_program) }),
		Fuzz.example({ name: "large-tree", revision: "1", make: || Generated(large_program) }),
	].concat(fixtures.map_with_index(|fixture, index| Fuzz.example({ name: fixture.name, revision: "1", make: || Fixture(index) }))),
	generator,
	test!,
	show: |input| Str.inspect(input),
})
