## Markup Compatibility and Extensibility (ECMA-376 Part 3): what a part
## means to a consumer that understands a fixed set of namespaces.
##
## A producer marks extension namespaces that a consumer may skip with
## `mc:Ignorable`, and offers alternative markup with `mc:AlternateContent`.
## [Mce.process] applies those rules to a part's tree and gives the
## interpreted tree: the content the package reads, with ignorable content in
## namespaces it does not understand removed and each alternative resolved to
## one branch. The tree it was given is the preserved tree, which still holds
## every extension and alternative so that they can be written back.
import XmlTree

Mce :: [].{

	## Where in a part a diagnostic arises: the element's name as the part
	## writes it, and its position among the part's elements in document
	## order, counting the root as 1.
	Location : { element : Str, position : U64 }

	## Something a part does that the compatibility rules call an error,
	## accepted so the part can still be read: a namespace the package does
	## not understand used without being declared ignorable (reported once
	## per namespace and part, where it is first used), a namespace named by
	## `mc:MustUnderstand` that it does not understand, a prefix in a
	## compatibility attribute with no declaration in scope, or a
	## compatibility element or attribute where the rules do not allow it.
	Diagnostic : [
		UndeclaredExtension({ namespace : Str, at : Location }),
		RequiredExtension({ namespace : Str, at : Location }),
		UnboundPrefix({ prefix : Str, at : Location }),
		InvalidCompatibilityMarkup({ at : Location }),
	]

	## The namespaces the package understands: those ECMA-376 defines for the
	## parts of a WordprocessingML package, including the VML of Part 4, with
	## the XML and markup compatibility namespaces. Content in any other
	## namespace is an extension.
	understood : List(Str)
	understood = [
		"http://schemas.openxmlformats.org/wordprocessingml/2006/main",
		"http://schemas.openxmlformats.org/officeDocument/2006/relationships",
		"http://schemas.openxmlformats.org/officeDocument/2006/math",
		"http://schemas.openxmlformats.org/officeDocument/2006/sharedTypes",
		"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties",
		"http://schemas.openxmlformats.org/officeDocument/2006/custom-properties",
		"http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes",
		"http://schemas.openxmlformats.org/drawingml/2006/main",
		"http://schemas.openxmlformats.org/drawingml/2006/picture",
		"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
		"http://schemas.openxmlformats.org/drawingml/2006/chart",
		"http://schemas.openxmlformats.org/drawingml/2006/diagram",
		"http://schemas.openxmlformats.org/drawingml/2006/lockedCanvas",
		"http://schemas.openxmlformats.org/schemaLibrary/2006/main",
		"http://schemas.openxmlformats.org/package/2006/content-types",
		"http://schemas.openxmlformats.org/package/2006/relationships",
		"http://schemas.openxmlformats.org/package/2006/metadata/core-properties",
		"http://purl.org/dc/elements/1.1/",
		"http://purl.org/dc/terms/",
		"http://purl.org/dc/dcmitype/",
		"http://www.w3.org/2001/XMLSchema-instance",
		"urn:schemas-microsoft-com:vml",
		"urn:schemas-microsoft-com:office:office",
		"urn:schemas-microsoft-com:office:word",
		markup_compatibility,
		xml_namespace,
	]

	## The interpreted tree of a part and what processing it reported. The
	## root element is always kept, since a part has exactly one; from it
	## down, every rule of Part 3 applies:
	##
	## * `mc:Ignorable` lists prefixes, resolved by the declarations in scope
	##   where it appears; it applies to that element, its attributes and its
	##   descendants. An element or attribute in an ignorable namespace that
	##   the package does not understand is removed.
	## * `mc:ProcessContent` names ignorable elements, as `prefix:name` or
	##   `prefix:*`, whose content is kept in their place when they are
	##   removed.
	## * `mc:AlternateContent` is replaced by the content of its first
	##   `mc:Choice` whose `Requires` prefixes all name understood
	##   namespaces, or else of its `mc:Fallback`, or else by nothing.
	## * `mc:PreserveElements` and `mc:PreserveAttributes` ask an editor to
	##   keep ignorable content when it saves; the preserved tree keeps all of
	##   it, so they need nothing more.
	## * A namespace the package does not understand that is not declared
	##   ignorable is treated as if it were, with an `UndeclaredExtension`
	##   diagnostic, as Google Docs exports need.
	##
	## Compatibility attributes are removed from the interpreted tree. An
	## extension list (`extLst` in an understood namespace, as DrawingML
	## writes them), whose content Part 1 leaves to applications, is kept as
	## it is without being processed.
	process : XmlTree.Node -> { interpreted : XmlTree.Node, diagnostics : List(Diagnostic) }
	process = |root| {
		var $pending = [Visit(root)]
		var $frames = List.with_capacity(16)
		var $nodes = List.with_capacity(16)
		var $diagnostics = List.with_capacity(4)
		var $reported = List.with_capacity(4)
		var $position = 0.U64
		while !$pending.is_empty() {
			next = $pending.last() ?? Close
			$pending = List.drop_last($pending, 1)
			match next {
				Visit(Text(content)) => {
					text : XmlTree.Node
					text = Text(content)
					$nodes = List.append($nodes, text)
				}

				Visit(Element(element)) => {
					$position = $position + 1
					at = { element: written(element.name), position: $position }
					declared = declare(element, $frames, at)
					$diagnostics = List.concat($diagnostics, declared.diagnostics)
					context = declared.context
					disposition = if $frames.is_empty() {
						Keep
					} else {
						dispose(element.name, context)
					}
					match disposition {
						Keep => {
							kept = interpret_attributes(element.attributes, context)
							undeclared = if $frames.is_empty() and !is_understood(element.name.namespace) and !is_ignorable(element.name.namespace, context) {
								List.concat(namespace_of(element.name.namespace), kept.undeclared)
							} else {
								kept.undeclared
							}
							for namespace in undeclared {
								if !$reported.contains(namespace) {
									$reported = List.append($reported, namespace)
									$diagnostics = List.append($diagnostics, UndeclaredExtension({ namespace, at }))
								}
							}
							$frames = List.append($frames, { name: element.name, bindings: element.bindings, context, output: Kept({ attributes: kept.attributes, first_child: $nodes.len() }) })
							$pending = push_children(List.append($pending, Close), element.children)
						}

						Opaque => {
							node : XmlTree.Node
							node = Element(element)
							$nodes = List.append($nodes, node)
							$position = $position + descendants(element.children)
						}

						Unwrap => {
							$frames = List.append($frames, { name: element.name, bindings: element.bindings, context, output: Spliced })
							$pending = push_children(List.append($pending, Close), element.children)
						}

						Alternate => {
							$frames = List.append($frames, { name: element.name, bindings: element.bindings, context, output: Spliced })
							$pending = push_branches(List.append($pending, Close), element.children, select(element, $frames))
						}

						Drop => {
							$position = $position + descendants(element.children)
						}

						Undeclared(namespace) => {
							if !$reported.contains(namespace) {
								$reported = List.append($reported, namespace)
								$diagnostics = List.append($diagnostics, UndeclaredExtension({ namespace, at }))
							}
							$position = $position + descendants(element.children)
						}

						Invalid => {
							$diagnostics = List.append($diagnostics, InvalidCompatibilityMarkup({ at: at }))
							$position = $position + descendants(element.children)
						}
					}
				}

				Branch(Element(branch), role) => {
					$position = $position + 1
					at = { element: written(branch.name), position: $position }
					match role {
						Taken => {
							declared = declare(branch, $frames, at)
							$diagnostics = List.concat($diagnostics, declared.diagnostics)
							$frames = List.append($frames, { name: branch.name, bindings: branch.bindings, context: declared.context, output: Spliced })
							$pending = push_children(List.append($pending, Close), branch.children)
						}

						Passed(unbound) => {
							for prefix in unbound {
								$diagnostics = List.append($diagnostics, UnboundPrefix({ prefix, at }))
							}
							$position = $position + descendants(branch.children)
						}

						Misplaced => {
							$diagnostics = List.append($diagnostics, InvalidCompatibilityMarkup({ at: at }))
							$position = $position + descendants(branch.children)
						}
					}
				}

				Branch(Text(_), _) => {}

				Close =>
					match $frames.last() {
						Ok(frame) => {
							$frames = List.drop_last($frames, 1)
							match frame.output {
								Kept({ attributes, first_child }) => {
									node : XmlTree.Node
									node = Element({ name: frame.name, bindings: frame.bindings, attributes, children: copy_from($nodes, first_child) })
									$nodes = List.append(truncate($nodes, first_child), node)
								}

								Spliced => {}
							}
						}

						Err(_) => {}
					}
			}
		}
		{ interpreted: $nodes.last() ?? root, diagnostics: $diagnostics }
	}
}

markup_compatibility : Str
markup_compatibility = "http://schemas.openxmlformats.org/markup-compatibility/2006"

xml_namespace : Str
xml_namespace = "http://www.w3.org/XML/1998/namespace"

Element : { name : XmlTree.Name, bindings : List(XmlTree.Binding), attributes : List(XmlTree.Attribute), children : List(XmlTree.Node) }

# What the compatibility attributes in scope say: the ignorable namespaces
# and the elements whose content is processed when they are ignored, with
# `*` as the local name of every element in a namespace.
Context : { ignorable : List(Str), process_content : List({ namespace : Str, local : Str }) }

# An element being processed: its name and declarations, the context its
# attributes establish, and whether it becomes an element of the interpreted
# tree or has its content spliced into its parent's.
Frame : { name : XmlTree.Name, bindings : List(XmlTree.Binding), context : Context, output : [Kept({ attributes : List(XmlTree.Attribute), first_child : U64 }), Spliced] }

# The work left: a node to process, a child of an `mc:AlternateContent` with
# what becomes of it, or the end of the element whose frame is last.
Pending : [Visit(XmlTree.Node), Branch(XmlTree.Node, Role), Close]

# What becomes of a child of an `mc:AlternateContent`: taken for
# interpretation, passed over with the prefixes it requires that have no
# declaration, or misplaced.
Role : [Taken, Passed(List(Str)), Misplaced]

# The context an element establishes for itself and its descendants, from the
# context it inherits and its own compatibility attributes.
declare : Element, List(Frame), Mce.Location -> { context : Context, diagnostics : List(Mce.Diagnostic) }
declare = |element, frames, at| {
	inherited = match frames.last() {
		Ok(frame) => frame.context
		Err(_) => { ignorable: [], process_content: [] }
	}
	var $ignorable = inherited.ignorable
	var $process_content = inherited.process_content
	var $diagnostics = List.with_capacity(0)
	for attribute in element.attributes {
		if attribute.name.namespace == Uri(markup_compatibility) {
			local = attribute.name.local
			if local == "Ignorable" or local == "MustUnderstand" {
				for prefix in words(attribute.value) {
					match lookup(prefix, element.bindings, frames) {
						Ok(namespace) => {
							if local == "Ignorable" {
								if !$ignorable.contains(namespace) {
									$ignorable = List.append($ignorable, namespace)
								}
							} else if !Mce.understood.contains(namespace) {
								$diagnostics = List.append($diagnostics, RequiredExtension({ namespace, at }))
							}
						}

						Err(_) => {
							$diagnostics = List.append($diagnostics, UnboundPrefix({ prefix, at }))
						}
					}
				}
			} else if local == "ProcessContent" {
				for qualified in words(attribute.value) {
					match qualified.split_first(":") {
						Ok({ before: prefix, after: name }) =>
							match lookup(prefix, element.bindings, frames) {
								Ok(namespace) => {
									$process_content = List.append($process_content, { namespace, local: name })
								}

								Err(_) => {
									$diagnostics = List.append($diagnostics, UnboundPrefix({ prefix, at }))
								}
							}

						Err(_) => {
							$diagnostics = List.append($diagnostics, InvalidCompatibilityMarkup({ at: at }))
						}
					}
				}
			} else if local != "PreserveElements" and local != "PreserveAttributes" {
				$diagnostics = List.append($diagnostics, InvalidCompatibilityMarkup({ at: at }))
			}
		}
	}
	{ context: { ignorable: $ignorable, process_content: $process_content }, diagnostics: $diagnostics }
}

# What becomes of an element below the root.
dispose : XmlTree.Name, Context -> [Keep, Opaque, Unwrap, Alternate, Drop, Undeclared(Str), Invalid]
dispose = |name, context|
	match name.namespace {
		NoNamespace => Keep
		Uri(namespace) =>
			if namespace == markup_compatibility {
				if name.local == "AlternateContent" {
					Alternate
				} else {
					Invalid
				}
			} else if Mce.understood.contains(namespace) {
				if name.local == "extLst" {
					Opaque
				} else {
					Keep
				}
			} else if context.ignorable.contains(namespace) {
				if context.process_content.any(|entry| entry.namespace == namespace and (entry.local == name.local or entry.local == "*")) {
					Unwrap
				} else {
					Drop
				}
			} else {
				Undeclared(namespace)
			}
	}

# The attributes an element keeps, and the namespaces of those it loses that
# were not declared ignorable.
interpret_attributes : List(XmlTree.Attribute), Context -> { attributes : List(XmlTree.Attribute), undeclared : List(Str) }
interpret_attributes = |attributes, context| {
	var $kept = List.with_capacity(attributes.len())
	var $undeclared = List.with_capacity(0)
	for attribute in attributes {
		match attribute.name.namespace {
			NoNamespace => {
				$kept = List.append($kept, attribute)
			}

			Uri(namespace) => {
				if Mce.understood.contains(namespace) and namespace != markup_compatibility {
					$kept = List.append($kept, attribute)
				} else if namespace != markup_compatibility and !context.ignorable.contains(namespace) and !$undeclared.contains(namespace) {
					$undeclared = List.append($undeclared, namespace)
				}
			}
		}
	}
	{ attributes: $kept, undeclared: $undeclared }
}

# What becomes of each child of an `mc:AlternateContent`, whose frame is the
# last of `frames`. The first `mc:Choice` whose `Requires` prefixes all name
# understood namespaces is taken, or else the `mc:Fallback`. A `Choice`
# after the `Fallback`, a second `Fallback`, a `Choice` without `Requires`
# and any other element are misplaced.
select : Element, List(Frame) -> List(Role)
select = |alternate, frames| {
	var $roles = List.with_capacity(alternate.children.len())
	var $taken = Bool.False
	var $has_fallback = Bool.False
	var $fallback = 0.U64
	for child in alternate.children {
		match child {
			Element(branch) => {
				is_compatibility = branch.name.namespace == Uri(markup_compatibility)
				if is_compatibility and branch.name.local == "Choice" and !$has_fallback {
					required = match branch.attributes.find_first(|attribute| attribute.name.namespace == NoNamespace and attribute.name.local == "Requires") {
						Ok(attribute) => words(attribute.value)
						Err(_) => []
					}
					var $unbound = List.with_capacity(0)
					var $acceptable = !required.is_empty()
					for prefix in required {
						match lookup(prefix, branch.bindings, frames) {
							Ok(namespace) => {
								if !Mce.understood.contains(namespace) {
									$acceptable = Bool.False
								}
							}

							Err(_) => {
								$acceptable = Bool.False
								$unbound = List.append($unbound, prefix)
							}
						}
					}
					if required.is_empty() {
						$roles = List.append($roles, Misplaced)
					} else if $acceptable and !$taken {
						$taken = Bool.True
						$roles = List.append($roles, Taken)
					} else {
						$roles = List.append($roles, Passed($unbound))
					}
				} else if is_compatibility and branch.name.local == "Fallback" and !$has_fallback {
					$has_fallback = Bool.True
					$fallback = $roles.len()
					$roles = List.append($roles, Passed([]))
				} else {
					$roles = List.append($roles, Misplaced)
				}
			}

			Text(_) => {
				$roles = List.append($roles, Passed([]))
			}
		}
	}
	if $has_fallback and !$taken {
		# The fallback's role was appended at this index, so it is in bounds.
		List.set($roles, $fallback, Taken) ?? []
	} else {
		$roles
	}
}

# The namespace a prefix is bound to where an element with `own` declarations
# appears below `frames`; `xml` is bound everywhere.
lookup : Str, List(XmlTree.Binding), List(Frame) -> Try(Str, [Unbound])
lookup = |prefix, own, frames| {
	if prefix == "xml" {
		return Ok(xml_namespace)
	}
	match bound(prefix, own) {
		Ok(namespace) => Ok(namespace)
		Err(_) => {
			var $index = frames.len()
			while $index > 0 {
				$index = $index - 1
				match frames.get($index) {
					Ok(frame) =>
						match bound(prefix, frame.bindings) {
							Ok(namespace) => {
								return Ok(namespace)
							}

							Err(_) => {}
						}

					Err(_) => {}
				}
			}
			Err(Unbound)
		}
	}
}

bound : Str, List(XmlTree.Binding) -> Try(Str, [Unbound])
bound = |prefix, bindings|
	match bindings.find_first(|binding| binding.prefix == Prefix(prefix)) {
		Ok({ prefix: _, namespace: Uri(namespace) }) => Ok(namespace)
		_ => Err(Unbound)
	}

is_understood : XmlTree.Namespace -> Bool
is_understood = |namespace|
	match namespace {
		Uri(uri) => Mce.understood.contains(uri)
		NoNamespace => Bool.True
	}

is_ignorable : XmlTree.Namespace, Context -> Bool
is_ignorable = |namespace, context|
	match namespace {
		Uri(uri) => context.ignorable.contains(uri)
		NoNamespace => Bool.False
	}

namespace_of : XmlTree.Namespace -> List(Str)
namespace_of = |namespace|
	match namespace {
		Uri(uri) => [uri]
		NoNamespace => []
	}

# A name as the part writes it.
written : XmlTree.Name -> Str
written = |name|
	match name.prefix {
		Prefix(prefix) => "${prefix}:${name.local}"
		Unprefixed => name.local
	}

# The items of a whitespace-separated list attribute.
words : Str -> List(Str)
words = |value| {
	var $words = List.with_capacity(4)
	var $current = List.with_capacity(16)
	for byte in value.to_utf8() {
		if byte == 32 or byte == 9 or byte == 10 or byte == 13 {
			if !$current.is_empty() {
				$words = List.append($words, Str.from_utf8($current) ?? "")
				$current = List.with_capacity(16)
			}
		} else {
			$current = List.append($current, byte)
		}
	}
	if $current.is_empty() {
		$words
	} else {
		List.append($words, Str.from_utf8($current) ?? "")
	}
}

# Children are pushed last first, so the first is visited next.
push_children : List(Pending), List(XmlTree.Node) -> List(Pending)
push_children = |pending, children| {
	var $pending = pending
	var $index = children.len()
	while $index > 0 {
		$index = $index - 1
		match children.get($index) {
			Ok(child) => {
				$pending = List.append($pending, Visit(child))
			}

			Err(_) => {}
		}
	}
	$pending
}

# The children of an `mc:AlternateContent` with what becomes of each, pushed
# last first.
push_branches : List(Pending), List(XmlTree.Node), List(Role) -> List(Pending)
push_branches = |pending, children, roles| {
	var $pending = pending
	var $index = children.len()
	while $index > 0 {
		$index = $index - 1
		match (children.get($index), roles.get($index)) {
			(Ok(child), Ok(role)) => {
				$pending = List.append($pending, Branch(child, role))
			}

			_ => {}
		}
	}
	$pending
}

# How many elements a list of nodes holds at any depth, so that skipping
# them keeps the positions of later elements those of the part.
descendants : List(XmlTree.Node) -> U64
descendants = |children| {
	var $pending = children
	var $count = 0.U64
	while !$pending.is_empty() {
		next = $pending.last() ?? Text("")
		$pending = List.drop_last($pending, 1)
		match next {
			Element(element) => {
				$count = $count + 1
				$pending = List.concat($pending, element.children)
			}

			Text(_) => {}
		}
	}
	$count
}

# The interpreted tree is built bottom-up on one list of finished nodes, as
# XmlTree builds a parsed one: a kept element's children are the nodes after
# the place its start left, copied into a list of their own when it ends, and
# a spliced element leaves its content where it is.
copy_from : List(a), U64 -> List(a)
copy_from = |nodes, start| {
	var $out = List.with_capacity(nodes.len() - start)
	var $index = start
	while $index < nodes.len() {
		match nodes.get($index) {
			Ok(node) => {
				$out = List.append($out, node)
			}

			Err(_) => {}
		}
		$index = $index + 1
	}
	$out
}

truncate : List(a), U64 -> List(a)
truncate = |nodes, len| {
	var $out = nodes
	while $out.len() > len {
		$out = List.drop_last($out, 1)
	}
	$out
}

# The interpreted tree of a part, written with the package's prefixes, beside
# the same for the part that is expected.
interprets_as : Str, Str -> Bool
interprets_as = |source, expected|
	match (XmlTree.parse(source.to_utf8(), {}), XmlTree.parse(expected.to_utf8(), {})) {
		(Ok(tree), Ok(wanted)) => XmlTree.render(Mce.process(tree).interpreted) == XmlTree.render(wanted)
		_ => Bool.False
	}

diagnostics_of : Str -> List(Mce.Diagnostic)
diagnostics_of = |source|
	match XmlTree.parse(source.to_utf8(), {}) {
		Ok(tree) => Mce.process(tree).diagnostics
		Err(_) => []
	}

declarations : Str
declarations = "xmlns:w='http://schemas.openxmlformats.org/wordprocessingml/2006/main' xmlns:mc='http://schemas.openxmlformats.org/markup-compatibility/2006' xmlns:w14='http://schemas.microsoft.com/office/word/2010/wordml'"

## Ignorable elements and attributes in a namespace the package does not
## understand are removed, compatibility attributes with them, and nothing is
## reported.
expect {
	source = "<w:document ${declarations} mc:Ignorable='w14'><w:p w14:paraId='1A'><w14:x><w:r/></w14:x><w:r/></w:p></w:document>"
	interprets_as(source, "<w:document ${declarations}><w:p><w:r/></w:p></w:document>") and diagnostics_of(source) == []
}

## A namespace the package understands is kept even when it is declared
## ignorable.
expect interprets_as("<w:document ${declarations} mc:Ignorable='w'><w:p w:rsidR='1'/></w:document>", "<w:document ${declarations}><w:p w:rsidR='1'/></w:document>")

## `mc:ProcessContent` keeps the content of an ignored element in its place.
expect interprets_as(
	"<w:document ${declarations} mc:Ignorable='w14' mc:ProcessContent='w14:wrap'><w14:wrap><w:p/></w14:wrap><w14:other><w:tbl/></w14:other></w:document>",
	"<w:document ${declarations}><w:p/></w:document>",
)

## `mc:Ignorable` resolves prefixes with the declarations in scope where it
## appears, not with the first declaration of the prefix in the part.
expect {
	source = "<w:document ${declarations} xmlns:x='urn:example:a'><w:body xmlns:x='urn:example:b' mc:Ignorable='x'><x:e/><w:p x:a='1'/></w:body></w:document>"
	interprets_as(source, "<w:document ${declarations}><w:body><w:p/></w:body></w:document>") and diagnostics_of(source) == []
}

## `mc:AlternateContent` takes the first `mc:Choice` whose required
## namespaces are all understood.
expect interprets_as(
	"<w:r ${declarations}><mc:AlternateContent><mc:Choice Requires='w14'><w14:x/></mc:Choice><mc:Choice Requires='w'><w:t>choice</w:t></mc:Choice><mc:Fallback><w:t>fallback</w:t></mc:Fallback></mc:AlternateContent></w:r>",
	"<w:r ${declarations}><w:t>choice</w:t></w:r>",
)

## Without an acceptable `mc:Choice`, `mc:AlternateContent` takes its
## `mc:Fallback`, as for the shapes LibreOffice writes, and without either it
## is removed.
expect {
	interprets_as(
		"<w:r ${declarations}><mc:AlternateContent><mc:Choice Requires='w14'><w14:x/></mc:Choice><mc:Fallback><w:t>a</w:t><w:t>b</w:t></mc:Fallback></mc:AlternateContent></w:r>",
		"<w:r ${declarations}><w:t>a</w:t><w:t>b</w:t></w:r>",
	)
		and interprets_as(
			"<w:r ${declarations}><mc:AlternateContent><mc:Choice Requires='w14'><w14:x/></mc:Choice></mc:AlternateContent></w:r>",
			"<w:r ${declarations}/>",
		)
}

## Undeclared extensions, as Google Docs writes `w14:paraId`, are removed and
## reported once per namespace with the element where they first appear.
expect {
	source = "<w:document ${declarations}><w:p w14:paraId='1'/><w:p w14:paraId='2'/></w:document>"
	interprets_as(source, "<w:document ${declarations}><w:p/><w:p/></w:document>")
		and diagnostics_of(source) == [UndeclaredExtension({ namespace: "http://schemas.microsoft.com/office/word/2010/wordml", at: { element: "w:p", position: 2 } })]
}

## `mc:MustUnderstand`, prefixes without a declaration and misplaced
## compatibility elements are reported where they appear.
expect {
	diagnostics_of("<w:document ${declarations} mc:MustUnderstand='w14' mc:Ignorable='x'><mc:Choice/></w:document>")
		== [
			RequiredExtension({ namespace: "http://schemas.microsoft.com/office/word/2010/wordml", at: { element: "w:document", position: 1 } }),
			UnboundPrefix({ prefix: "x", at: { element: "w:document", position: 1 } }),
			InvalidCompatibilityMarkup({ at: { element: "mc:Choice", position: 2 } }),
		]
}

## Positions count the elements of the part, including those removed and the
## branches of an alternative that are not taken.
expect {
	source = "<w:document ${declarations} mc:Ignorable='w14'><w14:x><w:p/><w:p/></w14:x><mc:AlternateContent><mc:Choice Requires='w14'><w:p/></mc:Choice><mc:Choice Requires='zz'/><mc:Fallback/><mc:Fallback/></mc:AlternateContent><w:p w15:a='1' xmlns:w15='urn:example'/></w:document>"
	diagnostics_of(source)
		== [
			UnboundPrefix({ prefix: "zz", at: { element: "mc:Choice", position: 8 } }),
			InvalidCompatibilityMarkup({ at: { element: "mc:Fallback", position: 10 } }),
			UndeclaredExtension({ namespace: "urn:example", at: { element: "w:p", position: 11 } }),
		]
}

## An extension list is kept as written.
expect {
	source = "<a:theme xmlns:a='http://schemas.openxmlformats.org/drawingml/2006/main'><a:extLst><a:ext uri='{0}'><w14:x xmlns:w14='http://schemas.microsoft.com/office/word/2010/wordml'/></a:ext></a:extLst></a:theme>"
	match XmlTree.parse(source.to_utf8(), {}) {
		Ok(tree) => Mce.process(tree) == { interpreted: tree, diagnostics: [] }
		Err(_) => Bool.False
	}
}
