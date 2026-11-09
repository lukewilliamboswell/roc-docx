app [target] {
	docx: "../../package/main.roc",
	fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.5.0/9WT86CuwM7ZJBSs8iTd1jLyrUFTTiGp5hcJE63TwswGE.tar.zst",
	zip: "https://github.com/lukewilliamboswell/roc-zip/releases/download/0.3.0-rc1/3vvx2cPVp1vjjVgrXcugJqqfrp55ZrURYQUcSArAUHdr.tar.zst",
}

import fuzz.Fuzz
import docx.Mce
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

## MCE processing gives the interpreted tree that a separately written
## reading of the Part 3 rules gives, reports the same undeclared extension
## namespaces, and locates every diagnostic at an element of the name it
## gives. Generated trees mix understood and extension namespaces with
## `mc:Ignorable`, `mc:ProcessContent`, `mc:MustUnderstand`,
## `mc:AlternateContent` and prefixes rebound in nested elements. Every XML
## part of every fixture document also processes without a diagnostic to an
## interpreted tree with no extension or compatibility markup left, in
## agreement with the reference, while the tree it was read as, the
## preserved tree, still holds the extension content the fixture declares.
##
## Allocation ratchets, which only ever move down: processing allocates at
## most linearly in the tree's nodes and attributes and keeps at most
## linearly many bytes live, and each declared example allocates no more than
## it did when its ceiling was set. The large declared tree, sixteen times the
## small one, allocates and requests at most sixteen times what the small one
## does in the same run. Raising a ceiling needs a cause recorded in the pull
## request.
test! : Input => Fuzz.Outcome
test! = |input| {
	match input {
		Generated(program) => {
			tree = build(program)
			cost = agree!(tree, generated_understood)
			match examples_by_program.find_first(|example| example.program == program) {
				Ok(example) => {
					if cost.allocations > example.allocations {
						crash "a declared tree allocated more than its ceiling"
					}
				}

				Err(_) => {}
			}
			if program == large_program {
				small = agree!(build(small_program), generated_understood)
				if cost.allocations > 16 * small.allocations or cost.requested_bytes > 16 * small.requested_bytes {
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
					var $preserved = 0.U64
					for entry in entries {
						if entry.path.ends_with(".xml") or entry.path.ends_with(".rels") {
							tree = XmlTree.parse(entry.content, {}) ?? crash "a fixture part does not read as namespaced XML"
							{ value: processed, stats } = Fuzz.measure!("mce-process", || Mce.process(tree))
							check_linear(stats, size(tree))
							if processed.diagnostics != [] {
								crash "a fixture part has a compatibility diagnostic"
							}
							if extension_markup(processed.interpreted) != 0 {
								crash "a fixture part's interpreted tree holds extension or compatibility markup"
							}
							if reference(tree, Mce.understood).nodes != [processed.interpreted] {
								crash "a fixture part's interpreted tree differs from the reference's"
							}
							$preserved = $preserved + extension_markup(tree)
							$allocations = $allocations + stats.allocs + stats.reallocs
						}
					}
					if $preserved != fixture.preserved {
						crash "a fixture's preserved trees hold a different amount of extension markup"
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

# Process a tree, measuring it, and check it against the reference. Returns
# the allocations and reallocations processing made and the bytes it
# requested.
agree! : XmlTree.Node, List(Str) => { allocations : U64, requested_bytes : U64 }
agree! = |tree, known| {
	{ value: processed, stats } = Fuzz.measure!("mce-process", || Mce.process(tree))
	check_linear(stats, size(tree))
	expected = reference(tree, known)
	if expected.nodes != [processed.interpreted] {
		crash "the interpreted tree differs from the reference's"
	}
	reported = processed.diagnostics.keep_oks(
		|diagnostic|
			match diagnostic {
				UndeclaredExtension({ namespace, at: _ }) => Ok(namespace)
				_ => Err(NotUndeclared)
			},
	)
	if !same_members(reported, expected.undeclared) {
		crash "the undeclared extensions differ from the reference's"
	}
	names = element_names(tree)
	for diagnostic in processed.diagnostics {
		at = match diagnostic {
			UndeclaredExtension({ at: location, namespace: _ }) => location
			RequiredExtension({ at: location, namespace: _ }) => location
			UnboundPrefix({ at: location, prefix: _ }) => location
			InvalidCompatibilityMarkup({ at: location }) => location
		}
		if names.get(at.position - 1) != Ok(at.element) {
			crash "a diagnostic names an element that is not at its position"
		}
	}
	{ allocations: stats.allocs + stats.reallocs, requested_bytes: stats.requested_bytes }
}

# The names of a tree's elements in document order, as the part writes them.
element_names : XmlTree.Node -> List(Str)
element_names = |node|
	match node {
		Text(_) => []
		Element(element) => {
			own = match element.name.prefix {
				Prefix(prefix) => "${prefix}:${element.name.local}"
				Unprefixed => element.name.local
			}
			element.children.fold([own], |names, child| names.concat(element_names(child)))
		}
	}

same_members : List(Str), List(Str) -> Bool
same_members = |left, right| left.all(|item| right.contains(item)) and right.all(|item| left.contains(item))

# Processing allocates at most linearly in the tree's nodes and attributes,
# and the bytes it holds live beyond the tree grow at most linearly.
check_linear : Fuzz.Stats, U64 -> {}
check_linear = |stats, nodes| {
	if stats.allocs + stats.reallocs > linear_allocation_ceiling(nodes) {
		crash "processing allocated more than linearly in the tree's nodes"
	}
	if stats.peak_live_bytes - stats.entry_live_bytes > linear_memory_ceiling(nodes) {
		crash "processing held more than linearly many bytes live"
	}
	{}
}

# Measured on nightly-2026-11-07 with roc-parser 6.0.0-rc.1: the LibreOffice
# styles part, about 1,700 elements, attributes and text runs, takes 2,351
# allocations and 292 KB beyond its tree; fixture parts stay under 1.5
# allocations and 270 bytes per node beyond the constants, and a chain of
# 64 nested elements, the deepest a generated tree has, holds about 820
# bytes per node in the frames of its open elements.
linear_allocation_ceiling : U64 -> U64
linear_allocation_ceiling = |nodes| 64 + 2 * nodes

linear_memory_ceiling : U64 -> U64
linear_memory_ceiling = |nodes| 16_384 + 1_024 * nodes

# The small and large generated examples repeat one program, the large one
# sixteen times as often. Processing them takes 104 and 1,550 allocations and
# requests 34,292 and 431,680 bytes, ratios of 14.9 and 12.6 against the
# sixteen the test allows.
small_program : List(U8)
small_program = List.join(List.repeat(program_unit, 4))

large_program : List(U8)
large_program = List.join(List.repeat(program_unit, 64))

# Opens a `w` element that rebinds `x` and declares `w14 x` ignorable, with a
# `w14` attribute, a `w` child with text and an `x` child whose namespace is
# not the one `x` is bound to there, then an alternative whose first choice
# requires `w14` and second `w`, each with content, and closes them all.
program_unit : List(U8)
program_unit = [0, 53, 44, 19, 0, 7, 6, 24, 6, 2, 10, 28, 16, 6, 6, 10, 108, 0, 7, 6, 6, 6, 6]

# Exact ceilings: the allocations of processing an example, as measured when
# the ceiling was set.
examples_by_program : List({ program : List(U8), allocations : U64 })
examples_by_program = [
	{ program: small_program, allocations: 104 },
	{ program: large_program, allocations: 1_550 },
]

# Each fixture's processing allocations, and how many elements and attributes
# in extension or compatibility namespaces its preserved trees hold.
fixtures : List({ name : Str, bytes : List(U8), allocations : U64, preserved : U64 })
fixtures = [
	{ name: "pandoc-basics", bytes: pandoc_basics, allocations: 3_546, preserved: 0 },
	{ name: "pandoc-comments", bytes: pandoc_comments, allocations: 3_377, preserved: 0 },
	{ name: "pandoc-lists", bytes: pandoc_lists, allocations: 4_012, preserved: 0 },
	{ name: "pandoc-notes", bytes: pandoc_notes, allocations: 3_304, preserved: 0 },
	{ name: "pandoc-review", bytes: pandoc_review, allocations: 3_822, preserved: 0 },
	{ name: "pandoc-revisions", bytes: pandoc_revisions, allocations: 3_307, preserved: 0 },
	{ name: "pandoc-tables", bytes: pandoc_tables, allocations: 3_652, preserved: 0 },
	{ name: "libreoffice-basics", bytes: libreoffice_basics, allocations: 3_172, preserved: 14 },
	{ name: "libreoffice-comments", bytes: libreoffice_comments, allocations: 3_121, preserved: 3 },
	{ name: "libreoffice-lists", bytes: libreoffice_lists, allocations: 4_933, preserved: 3 },
	{ name: "libreoffice-notes", bytes: libreoffice_notes, allocations: 3_139, preserved: 3 },
	{ name: "libreoffice-review", bytes: libreoffice_review, allocations: 4_287, preserved: 4 },
	{ name: "libreoffice-revisions", bytes: libreoffice_revisions, allocations: 3_040, preserved: 2 },
	{ name: "libreoffice-tables", bytes: libreoffice_tables, allocations: 4_824, preserved: 2 },
]

w : Str
w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

r : Str
r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

mc : Str
mc = "http://schemas.openxmlformats.org/markup-compatibility/2006"

w14 : Str
w14 = "http://schemas.microsoft.com/office/word/2010/wordml"

# The namespaces generated trees use that a consumer of the ECMA-376
# namespaces understands; `w14` and the example namespaces are extensions.
generated_understood : List(Str)
generated_understood = [w, r, mc]

# The reference: Part 3 read directly as a recursive function over the tree.
# It returns the nodes an input node stands for in the interpreted tree and
# the extension namespaces used without being declared ignorable.
reference : XmlTree.Node, List(Str) -> { nodes : List(XmlTree.Node), undeclared : List(Str) }
reference = |root, known| interpret(root, { bindings: [], ignorable: [], unwrap: [] }, known, Bool.True)

Scope : { bindings : List({ prefix : Str, namespace : Str }), ignorable : List(Str), unwrap : List({ namespace : Str, local : Str }) }

interpret : XmlTree.Node, Scope, List(Str), Bool -> { nodes : List(XmlTree.Node), undeclared : List(Str) }
interpret = |node, outer, known, is_root|
	match node {
		Text(_) => { nodes: [node], undeclared: [] }
		Element(element) => {
			scope = enter(element, outer)
			namespace = uri_of(element.name.namespace)
			is_known = namespace == "" or known.contains(namespace)
			if is_root or (is_known and namespace != mc) {
				if !is_root and namespace != "" and element.name.local == "extLst" {
					{ nodes: [node], undeclared: [] }
				} else {
					attributes = element.attributes.keep_if(|attribute| attribute_kept(attribute, known))
					lost = element.attributes
						.map(|attribute| uri_of(attribute.name.namespace))
						.keep_if(|uri| uri != "" and !known.contains(uri) and !scope.ignorable.contains(uri))
					inner = interpret_all(element.children, scope, known)
					own = if is_known or scope.ignorable.contains(namespace) {
						[]
					} else {
						[namespace]
					}
					kept : XmlTree.Node
					kept = Element({ name: element.name, bindings: element.bindings, attributes, children: inner.nodes })
					{ nodes: [kept], undeclared: own.concat(lost).concat(inner.undeclared) }
				}
			} else if namespace == mc {
				if element.name.local == "AlternateContent" {
					match choose(element, scope, known) {
						Ok(branch) => interpret_all(branch.children, enter(branch, scope), known)
						Err(_) => { nodes: [], undeclared: [] }
					}
				} else {
					{ nodes: [], undeclared: [] }
				}
			} else if scope.ignorable.contains(namespace) {
				if scope.unwrap.any(|entry| entry.namespace == namespace and (entry.local == "*" or entry.local == element.name.local)) {
					interpret_all(element.children, scope, known)
				} else {
					{ nodes: [], undeclared: [] }
				}
			} else {
				{ nodes: [], undeclared: [namespace] }
			}
		}
	}

interpret_all : List(XmlTree.Node), Scope, List(Str) -> { nodes : List(XmlTree.Node), undeclared : List(Str) }
interpret_all = |children, scope, known|
	children.fold(
		{ nodes: [], undeclared: [] },
		|done, child| {
			result = interpret(child, scope, known, Bool.False)
			{ nodes: done.nodes.concat(result.nodes), undeclared: done.undeclared.concat(result.undeclared) }
		},
	)

attribute_kept : XmlTree.Attribute, List(Str) -> Bool
attribute_kept = |attribute, known| {
	uri = uri_of(attribute.name.namespace)
	uri == "" or (known.contains(uri) and uri != mc)
}

# The scope inside an element: its declarations, then its compatibility
# attributes read with them.
enter : { name : XmlTree.Name, bindings : List(XmlTree.Binding), attributes : List(XmlTree.Attribute), children : List(XmlTree.Node) }, Scope -> Scope
enter = |element, outer| {
	bindings = element.bindings.fold(
		outer.bindings,
		|all, binding|
			match binding {
				{ prefix: Prefix(prefix), namespace: Uri(namespace) } => all.append({ prefix, namespace })
				_ => all
			},
	)
	compatibility = |local| element.attributes.keep_if(|attribute| attribute.name.namespace == Uri(mc) and attribute.name.local == local).map(|attribute| attribute.value)
	ignorable = List.join(compatibility("Ignorable").map(|value| list_items(value).keep_oks(|prefix| resolve(bindings, prefix))))
	unwrap = List.join(
		compatibility("ProcessContent").map(
			|value|
				list_items(value).keep_oks(
					|item|
						match item.split_first(":") {
							Ok({ before, after }) => resolve(bindings, before).map_ok(|namespace| { namespace, local: after })
							Err(_) => Err(NoPrefix)
						},
				),
		),
	)
	{ bindings, ignorable: outer.ignorable.concat(ignorable), unwrap: outer.unwrap.concat(unwrap) }
}

resolve : List({ prefix : Str, namespace : Str }), Str -> Try(Str, [Unbound])
resolve = |bindings, prefix|
	match bindings.keep_if(|binding| binding.prefix == prefix).last() {
		Ok(binding) => Ok(binding.namespace)
		Err(_) => Err(Unbound)
	}

list_items : Str -> List(Str)
list_items = |value| List.join(value.split_on(" ").map(|part| part.split_on("\t"))).keep_if(|item| !item.is_empty())

# The first `Choice` before any `Fallback` whose required prefixes all name
# known namespaces, else the first `Fallback`.
choose : { name : XmlTree.Name, bindings : List(XmlTree.Binding), attributes : List(XmlTree.Attribute), children : List(XmlTree.Node) }, Scope, List(Str) -> Try({ name : XmlTree.Name, bindings : List(XmlTree.Binding), attributes : List(XmlTree.Attribute), children : List(XmlTree.Node) }, [NoBranch])
choose = |alternate, scope, known| {
	var $fallback = Err(NoBranch)
	var $has_fallback = Bool.False
	for child in alternate.children {
		match child {
			Element(branch) => {
				is_compatibility = branch.name.namespace == Uri(mc)
				if is_compatibility and branch.name.local == "Fallback" {
					if !$has_fallback {
						$fallback = Ok(branch)
						$has_fallback = Bool.True
					}
				} else if is_compatibility and branch.name.local == "Choice" and !$has_fallback {
					required = List.join(branch.attributes.keep_if(|attribute| attribute.name.namespace == NoNamespace and attribute.name.local == "Requires").map(|attribute| list_items(attribute.value)))
					inner = enter(branch, scope)
					if !required.is_empty() and required.all(|prefix| resolve(inner.bindings, prefix).map_ok(|namespace| known.contains(namespace)) == Ok(Bool.True)) {
						return Ok(branch)
					}
				}
			}

			Text(_) => {}
		}
	}
	$fallback
}

uri_of : XmlTree.Namespace -> Str
uri_of = |namespace|
	match namespace {
		Uri(uri) => uri
		NoNamespace => ""
	}

# Elements and attributes in a namespace outside `Mce.understood` or in the
# compatibility namespace, not counting the content of extension lists.
extension_markup : XmlTree.Node -> U64
extension_markup = |node|
	match node {
		Text(_) => 0
		Element(element) => {
			namespace = uri_of(element.name.namespace)
			if element.name.local == "extLst" and Mce.understood.contains(namespace) {
				0
			} else {
				own = if (is_extension(namespace)) 1 else 0
				attributes = element.attributes.keep_if(|attribute| is_extension(uri_of(attribute.name.namespace))).len()
				element.children.fold(own + attributes, |total, child| total + extension_markup(child))
			}
		}
	}

is_extension : Str -> Bool
is_extension = |namespace| namespace != "" and (namespace == mc or !Mce.understood.contains(namespace))

# Elements, attributes and text runs in a tree.
size : XmlTree.Node -> U64
size = |node|
	match node {
		Text(_) => 1
		Element(element) => element.children.fold(1 + element.attributes.len(), |total, child| total + size(child))
	}

# The tree a program of bytes describes. Each byte is one step: its low
# three bits choose the step and the rest choose among its variants. The
# root declares every prefix the steps use; a step that does not apply where
# it falls is skipped, and nesting stops at a fixed depth.
build : List(U8) -> XmlTree.Node
build = |program| {
	root = {
		name: { namespace: Uri(w), local: "document", prefix: Prefix("w") },
		bindings: [
			{ prefix: Prefix("w"), namespace: Uri(w) },
			{ prefix: Prefix("r"), namespace: Uri(r) },
			{ prefix: Prefix("mc"), namespace: Uri(mc) },
			{ prefix: Prefix("w14"), namespace: Uri(w14) },
			{ prefix: Prefix("x"), namespace: Uri("urn:example:x") },
			{ prefix: Prefix("y"), namespace: Uri("urn:example:y") },
		],
		attributes: [],
		children: [],
	}
	var $open = [root]
	for byte in program {
		variant = (byte // 8).to_u64()
		$open = match byte % 8 {
			0 | 1 => open_one($open, name_of(variant))
			2 => open_one($open, compatibility_element(variant))
			3 => add_attribute($open, { name: name_of(variant), value: "v" })
			4 => add_attribute($open, compatibility_attribute(variant))
			5 => add_binding($open, variant)
			6 => close_one($open)
			_ => add_text($open, pick(["a", " "], variant))
		}
	}
	while $open.len() > 1 {
		$open = close_one($open)
	}
	match $open.first() {
		Ok(element) => Element(element)
		Err(_) => Text("")
	}
}

Open : { name : XmlTree.Name, bindings : List(XmlTree.Binding), attributes : List(XmlTree.Attribute), children : List(XmlTree.Node) }

update_last : List(Open), (Open -> Open) -> List(Open)
update_last = |open, change|
	match open.last() {
		Ok(last) => List.append(List.drop_last(open, 1), change(last))
		Err(_) => open
	}

open_one : List(Open), XmlTree.Name -> List(Open)
open_one = |open, name|
	if open.len() < 64 {
		List.append(open, { name, bindings: [], attributes: [], children: [] })
	} else {
		open
	}

close_one : List(Open) -> List(Open)
close_one = |open|
	if open.len() < 2 {
		open
	} else {
		match open.last() {
			Ok(last) => update_last(List.drop_last(open, 1), |parent| { name: parent.name, bindings: parent.bindings, attributes: parent.attributes, children: List.append(parent.children, Element(last)) })
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
				{ name: element.name, bindings: element.bindings, attributes: List.append(element.attributes, attribute), children: element.children }
			},
	)

# A declaration is skipped when its element already declares the prefix.
add_binding : List(Open), U64 -> List(Open)
add_binding = |open, variant| {
	prefix = pick(["x", "w14", "y"], variant)
	namespace = pick([w, "urn:example:x", "urn:example:y", w14], variant // 3)
	update_last(
		open,
		|element|
			if element.bindings.any(|existing| existing.prefix == Prefix(prefix)) {
				element
			} else {
				{ name: element.name, bindings: List.append(element.bindings, { prefix: Prefix(prefix), namespace: Uri(namespace) }), attributes: element.attributes, children: element.children }
			},
	)
}

text_node : Str -> XmlTree.Node
text_node = |content| Text(content)

add_text : List(Open), Str -> List(Open)
add_text = |open, content| update_last(open, |element| { name: element.name, bindings: element.bindings, attributes: element.attributes, children: List.append(element.children, text_node(content)) })

name_of : U64 -> XmlTree.Name
name_of = |variant| {
	choices = [{ prefix: "w", namespace: Uri(w) }, { prefix: "r", namespace: Uri(r) }, { prefix: "w14", namespace: Uri(w14) }, { prefix: "x", namespace: Uri("urn:example:x") }, { prefix: "", namespace: NoNamespace }]
	choice = choices.get(variant % choices.len()) ?? { prefix: "", namespace: NoNamespace }
	local = pick(["p", "e", "extLst", "t"], variant // choices.len())
	{ namespace: choice.namespace, local, prefix: if (choice.prefix == "") Unprefixed else Prefix(choice.prefix) }
}

compatibility_element : U64 -> XmlTree.Name
compatibility_element = |variant| {
	local = pick(["AlternateContent", "Choice", "Fallback", "AlternateContent"], variant)
	{ namespace: Uri(mc), local, prefix: Prefix("mc") }
}

# `Requires` is an unprefixed attribute; the others are compatibility
# attributes. Their values include unbound prefixes and tab separators.
compatibility_attribute : U64 -> XmlTree.Attribute
compatibility_attribute = |variant| {
	prefix_lists = ["w14", "w14 x", "w", "x\ty", "zz", "y"]
	qualified_lists = ["w14:*", "x:e", "w14:p y:*", "zz:e", "nocolon"]
	choice = variant // 5
	match variant % 5 {
		0 => { name: { namespace: Uri(mc), local: "Ignorable", prefix: Prefix("mc") }, value: pick(prefix_lists, choice) }
		1 => { name: { namespace: Uri(mc), local: "ProcessContent", prefix: Prefix("mc") }, value: pick(qualified_lists, choice) }
		2 => { name: { namespace: Uri(mc), local: "MustUnderstand", prefix: Prefix("mc") }, value: pick(prefix_lists, choice) }
		3 => { name: { namespace: NoNamespace, local: "Requires", prefix: Unprefixed }, value: pick(prefix_lists, choice) }
		_ => { name: { namespace: Uri(mc), local: "PreserveElements", prefix: Prefix("mc") }, value: pick(qualified_lists, choice) }
	}
}

pick : List(Str), U64 -> Str
pick = |choices, index| choices.get(index % choices.len()) ?? ""

target = Fuzz.target_with!({
	name: "mce-processing",
	examples: [
		Fuzz.example({ name: "small-tree", revision: "1", make: || Generated(small_program) }),
		Fuzz.example({ name: "large-tree", revision: "1", make: || Generated(large_program) }),
	].concat(fixtures.map_with_index(|fixture, index| Fuzz.example({ name: fixture.name, revision: "1", make: || Fixture(index) }))),
	generator,
	test!,
	show: |input| Str.inspect(input),
})
