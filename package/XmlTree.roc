## The XML of a part as a namespaced tree, read within explicit limits and
## written with the package's fixed prefix table.
##
## Every element and attribute is named by its namespace and local name, as
## Namespaces in XML 1.0 defines; the prefix a name was written with and each
## element's own namespace declarations are kept beside the name. Reading is
## one pass over the part with a pull reader, and a malformed part, a broken
## namespace rule or an exceeded limit is a located error, never a crash.
## Writing ignores the declarations a tree was read with: each namespace is
## written with its prefix from [XmlTree.prefixes], or, outside that table,
## with a prefix chosen by a fixed rule, declared once on the root, so the
## same tree always gives the same bytes.
import parser.Xml
import parser.XmlNs
import Limits

XmlTree :: [].{

	## The namespace a name is in: unprefixed attributes, and unprefixed
	## elements where no default namespace is declared, are in `NoNamespace`.
	Namespace : [Uri(Str), NoNamespace]

	## A name by namespace and local part, with the prefix it was written with.
	## Two names are the same name when their namespace and local part are.
	Name : { namespace : Namespace, local : Str, prefix : [Prefix(Str), Unprefixed] }

	## A namespace declaration an element makes: `xmlns:p="u"` binds
	## `Prefix("p")`, and `xmlns="u"` binds `Default`.
	Binding : { prefix : [Prefix(Str), Default], namespace : Namespace }

	## An attribute other than a namespace declaration, with its decoded value.
	Attribute : { name : Name, value : Str }

	## An element, with its declarations, attributes in source order and
	## children in document order, or a run of character data.
	Node := [
		Element({ name : Name, bindings : List(Binding), attributes : List(Attribute), children : List(Node) }),
		Text(Str),
	].{

		## Compare two trees structurally, prefixes and declarations included.
		is_eq : _
	}

	## A rule of Namespaces in XML 1.0 that a part breaks: a prefix used
	## without a declaration, a reserved prefix or namespace misused, an empty
	## prefixed declaration, a name that is not a qualified name, or two
	## attributes with the same namespace and local name.
	NamespaceProblem : [
		UndeclaredPrefix(Str),
		ReservedPrefix(Str),
		ReservedNamespace(Str),
		EmptyNamespace(Str),
		NotAQName(Str),
		DuplicateAttribute(Name),
	]

	## Why a part cannot be read. Every error but `XmlNotUtf8` carries the
	## one-based line and column where reading stopped: malformed XML with
	## the reader's message, a namespace rule broken in a start tag, or the
	## `Limits` bound on nesting depth, element count or attributes per
	## element that the part exceeds.
	ReadError : [
		XmlNotUtf8,
		MalformedXml({ message : Str, line : U64, column : U64 }),
		NamespaceError({ problem : NamespaceProblem, line : U64, column : U64 }),
		XmlTooDeep({ max : U64, line : U64, column : U64 }),
		TooManyXmlElements({ max : U64, line : U64, column : U64 }),
		TooManyXmlAttributes({ max : U64, line : U64, column : U64 }),
	]

	## Why a tree cannot be written as namespace-well-formed XML: a prefix or
	## local name that is not an XML name, a character XML does not allow, a
	## name whose namespace cannot be bound where it is used, or two
	## attributes with the same name. `path` names the elements from the root
	## to the one the problem is in.
	WriteError : [
		XmlUnwritable({ problem : [InvalidName(Str), InvalidChar(U32), UnknownNamespace(Str), DuplicateAttribute(Str)], path : List(Str) }),
	]

	## The fixed prefix of every namespace the package writes, in the order a
	## part's root declares them. The package-level namespaces of content
	## types, relationships and document properties are not listed: a part
	## whose root is in one of them writes it as the default namespace.
	prefixes : List({ prefix : Str, namespace : Str })
	prefixes = [
		{ prefix: "w", namespace: "http://schemas.openxmlformats.org/wordprocessingml/2006/main" },
		{ prefix: "r", namespace: "http://schemas.openxmlformats.org/officeDocument/2006/relationships" },
		{ prefix: "m", namespace: "http://schemas.openxmlformats.org/officeDocument/2006/math" },
		{ prefix: "mc", namespace: "http://schemas.openxmlformats.org/markup-compatibility/2006" },
		{ prefix: "wp", namespace: "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" },
		{ prefix: "a", namespace: "http://schemas.openxmlformats.org/drawingml/2006/main" },
		{ prefix: "pic", namespace: "http://schemas.openxmlformats.org/drawingml/2006/picture" },
		{ prefix: "sl", namespace: "http://schemas.openxmlformats.org/schemaLibrary/2006/main" },
		{ prefix: "vt", namespace: "http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes" },
		{ prefix: "cp", namespace: "http://schemas.openxmlformats.org/package/2006/metadata/core-properties" },
		{ prefix: "dc", namespace: "http://purl.org/dc/elements/1.1/" },
		{ prefix: "dcterms", namespace: "http://purl.org/dc/terms/" },
		{ prefix: "dcmitype", namespace: "http://purl.org/dc/dcmitype/" },
		{ prefix: "xsi", namespace: "http://www.w3.org/2001/XMLSchema-instance" },
		{ prefix: "v", namespace: "urn:schemas-microsoft-com:vml" },
		{ prefix: "o", namespace: "urn:schemas-microsoft-com:office:office" },
		{ prefix: "w10", namespace: "urn:schemas-microsoft-com:office:word" },
		{ prefix: "w14", namespace: "http://schemas.microsoft.com/office/word/2010/wordml" },
		{ prefix: "w15", namespace: "http://schemas.microsoft.com/office/word/2012/wordml" },
		{ prefix: "wp14", namespace: "http://schemas.microsoft.com/office/word/2010/wordprocessingDrawing" },
		{ prefix: "wps", namespace: "http://schemas.microsoft.com/office/word/2010/wordprocessingShape" },
		{ prefix: "wpg", namespace: "http://schemas.microsoft.com/office/word/2010/wordprocessingGroup" },
		{ prefix: "thm15", namespace: "http://schemas.microsoft.com/office/thememl/2012/main" },
	]

	## The namespaces of the package-level parts, written as the default
	## namespace of a part whose root is in one of them.
	default_namespaces : List(Str)
	default_namespaces = [
		"http://schemas.openxmlformats.org/package/2006/content-types",
		"http://schemas.openxmlformats.org/package/2006/relationships",
		"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties",
		"http://schemas.openxmlformats.org/officeDocument/2006/custom-properties",
	]

	## Read a part's bytes as a namespaced tree, within the XML bounds of
	## `limits`. The bytes are UTF-8, with or without a byte order mark.
	## Namespaces are resolved as each start tag is read and the tree is
	## built in the same pass; whitespace between elements is kept as text.
	parse : List(U8), Limits -> Try(Node, ReadError)
	parse = |bytes, limits| Ok(XmlTree.parse_split(bytes, limits, |_, _| Bool.False, {}, |state, _| state)?.tree)

	## Read a part's bytes as [XmlTree.parse] does, except the content of one
	## element: the root's first child that `splits(root, child)` accepts, by
	## their names, is in the tree without children, and each of its children
	## is given to `step` in order instead, as a whole subtree as soon as its
	## end is read, built as the tree is. A part whose bulk is the children of one element, such as a main
	## document's body, is so read without a tree of all of them.
	parse_split : List(U8), Limits, (Name, Name -> Bool), s, (s, Node -> s) -> Try({ tree : Node, state : s }, ReadError)
	parse_split = |bytes, limits, splits, state, step| {
		text = Str.from_utf8(bytes) ? |_| XmlNotUtf8
		var $reader = XmlNs.reader(text, reader_props(limits)) ? read_error
		var $frames = List.with_capacity(16)
		var $nodes = List.with_capacity(16)
		var $state = state
		var $split = Before
		var $reading = Bool.True
		while $reading {
			match $reader.next() {
				Event(Start(start), rest) => {
					if $split == Before and $frames.len() == 1 {
						match $frames.first() {
							Ok(root) if splits(root.start.name, start.name) => {
								$split = Inside
							}

							_ => {}
						}
					}
					$frames = List.append($frames, { start, first_child: $nodes.len() })
					$reader = rest
				}

				Event(Text(content), rest) => {
					if $split == Inside and $frames.len() == 2 {
						$state = step($state, Text(content))
					} else {
						$nodes = List.append($nodes, Text(content))
					}
					$reader = rest
				}

				Event(End(_), rest) => {
					if $split == Inside and $frames.len() == 2 {
						$split = After
					}
					# The reader pairs every end tag with a start, so a frame is open.
					match $frames.last() {
						Ok({ start, first_child }) => {
							$frames = List.drop_last($frames, 1)
							node : Node
							node = Element({ name: start.name, bindings: start.bindings, attributes: start.attributes, children: copy_from($nodes, first_child) })
							if $split == Inside and $frames.len() == 2 {
								$state = step($state, node)
								$nodes = truncate($nodes, first_child)
							} else {
								$nodes = List.append(truncate($nodes, first_child), node)
							}
						}

						Err(_) => {}
					}
					$reader = rest
				}

				Done => {
					$reading = Bool.False
				}

				Failed(error) => {
					return Err(read_error(error))
				}
			}
		}
		tree = $nodes.last() ? |_| MalformedXml({ message: "no root element", line: 1, column: 1 })
		Ok({ tree, state: $state })
	}

	## One step through a part as [XmlTree.scan] reads it: an element's start,
	## with its name and attributes, or the end of the element most recently
	## started and not yet ended.
	Event : [Start({ name : Name, attributes : List(Attribute) }), End]

	## Read a part's bytes within the XML bounds of `limits`, as
	## [XmlTree.parse] reads them, giving each element's start and end to
	## `step` in document order and building no tree. Text is not given.
	scan : List(U8), Limits, s, (s, Event -> s) -> Try(s, ReadError)
	scan = |bytes, limits, state, step| {
		text = Str.from_utf8(bytes) ? |_| XmlNotUtf8
		var $reader = XmlNs.reader(text, reader_props(limits)) ? read_error
		var $state = state
		var $reading = Bool.True
		while $reading {
			match $reader.next() {
				Event(Start(start), rest) => {
					$state = step($state, Start({ name: start.name, attributes: start.attributes }))
					$reader = rest
				}

				Event(End(_), rest) => {
					$state = step($state, End)
					$reader = rest
				}

				Event(Text(_), rest) => {
					$reader = rest
				}

				Done => {
					$reading = Bool.False
				}

				Failed(error) => {
					return Err(read_error(error))
				}
			}
		}
		Ok($state)
	}

	## Write a tree as a part: an XML declaration with `standalone="yes"`,
	## then the root, which declares every namespace the tree uses, and no
	## other, so the same tree always writes the same bytes and [XmlTree.parse]
	## reads them back as the same tree up to prefixes and declarations.
	## Attributes are written in the order the tree gives them.
	##
	## A namespace in [XmlTree.prefixes] is written with its prefix there, and
	## the root declares those first, in table order. Any other namespace is
	## written with the prefix it was first read with in document order, unless
	## that prefix is unprefixed, in the table, taken by an earlier namespace or
	## begins with `xml`; then it is written as `ns1`, `ns2` and so on, the
	## first that is free. Those are declared after the table's, in the order
	## the tree first uses them. A part whose root is in a namespace of
	## [XmlTree.default_namespaces] writes that namespace as the default.
	##
	## Some attribute values name namespaces by prefix: `mc:Ignorable` and
	## `mc:MustUnderstand` list prefixes, `Requires` on `mc:Choice` too, and
	## `mc:ProcessContent`, `mc:PreserveElements`, `mc:PreserveAttributes` and
	## `xsi:type` list qualified names. Each prefix in them is resolved with
	## the declarations in scope where it was read and written as the prefix
	## its namespace is written with, and a namespace named only there is
	## still declared, so the values mean what they meant. The items are
	## written separated by one space. A prefix with no declaration in scope
	## is written as it was.
	render : Node -> Try(List(U8), WriteError)
	render = |root| {
		default = part_default(root)
		plan = plan_prefixes(needed_prefixes(root, default))
		written = XmlNs.render({ declaration: Err(Missing), root: canonical(root, default, plan) }, { declaration: Standalone }) ? write_error
		Ok(written.to_utf8())
	}

	## The same tree without prefixes or declarations, so that two trees
	## compare equal when they differ only in how they spell namespaces. In an
	## attribute value that names namespaces by prefix, as [XmlTree.render]
	## lists them, each declared prefix is replaced by its namespace in
	## braces: `mc:Ignorable="w14"` becomes
	## `{http://schemas.microsoft.com/office/word/2010/wordml}` and
	## `xsi:type="dcterms:W3CDTF"` becomes `{http://purl.org/dc/terms/}:W3CDTF`.
	unprefixed : Node -> Node
	unprefixed = |root| {
		var $pending = [Visit(root)]
		var $scopes = List.with_capacity(16)
		var $frames = List.with_capacity(16)
		var $nodes = List.with_capacity(16)
		while !$pending.is_empty() {
			next = $pending.last() ?? Leave
			$pending = List.drop_last($pending, 1)
			match next {
				Visit(Text(content)) => {
					text : Node
					text = Text(content)
					$nodes = List.append($nodes, text)
				}

				Visit(Element(element)) => {
					$scopes = List.append($scopes, element.bindings)
					scopes = $scopes
					attributes = element.attributes.map(
						|attribute| {
							name: { namespace: attribute.name.namespace, local: attribute.name.local, prefix: Unprefixed },
							value: rewrite(element.name, attribute, scopes, |uri| "{${uri}}"),
						},
					)
					$frames = List.append($frames, { name: { namespace: element.name.namespace, local: element.name.local, prefix: Unprefixed }, attributes, first_child: $nodes.len() })
					$pending = push_children(List.append($pending, Leave), element.children)
				}

				Leave => {
					$scopes = List.drop_last($scopes, 1)
					match $frames.last() {
						Ok(frame) => {
							$frames = List.drop_last($frames, 1)
							node : Node
							node = Element({ name: frame.name, bindings: [], attributes: frame.attributes, children: copy_from($nodes, frame.first_child) })
							$nodes = List.append(truncate($nodes, frame.first_child), node)
						}

						Err(_) => {}
					}
				}
			}
		}
		$nodes.last() ?? root
	}
}

# The XML bounds of `limits`, as the pull reader takes them.
reader_props : Limits -> Xml.ReaderProps
reader_props = |limits| { max_depth: limits.max_xml_depth, max_elements: limits.max_xml_elements, max_attributes: limits.max_xml_attributes }

# The dependency's read errors, in the package's words.
read_error : XmlNs.ReadError -> XmlTree.ReadError
read_error = |error|
	match error {
		InvalidXml({ line, column, message }) => MalformedXml({ message, line, column })
		InvalidNamespace({ problem, line, column }) => NamespaceError({ problem, line, column })
		LimitExceeded({ limit: Depth, max, line, column }) => XmlTooDeep({ max, line, column })
		LimitExceeded({ limit: Elements, max, line, column }) => TooManyXmlElements({ max, line, column })
		LimitExceeded({ limit: Attributes, max, line, column }) => TooManyXmlAttributes({ max, line, column })
	}

# The dependency's render errors, in the package's words.
write_error : [Unrenderable({ problem : XmlNs.RenderProblem, path : List(Str) })] -> XmlTree.WriteError
write_error = |error|
	match error {
		Unrenderable({ problem, path }) =>
			XmlUnwritable({
				problem: match problem {
					InvalidName(name) => InvalidName(name)
					InvalidChar(code) => InvalidChar(code)
					UnboundNamespace(namespace) => UnknownNamespace(namespace)
					DuplicateAttribute(name) => DuplicateAttribute(name)
				},
				path,
			})
	}

# Trees are built bottom-up on one list of finished nodes: an element's
# children are the nodes after the place its start left, copied into a list
# of their own when it ends. Every node is copied once, and both lists stay
# uniquely owned, so building is linear.
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

# Drop the nodes from `len` on, one at a time from the end, so the list is
# shortened in place rather than sliced.
truncate : List(a), U64 -> List(a)
truncate = |nodes, len| {
	var $out = nodes
	while $out.len() > len {
		$out = List.drop_last($out, 1)
	}
	$out
}

# A namespace that needs a prefix, with the prefix it was first read with,
# or "" when it was read unprefixed.
Need : { namespace : Str, read : Str }

# The prefixes a part is written with: the declarations its root makes, in
# order, and the prefix of each namespace.
Plan : { declarations : List({ prefix : Str, namespace : Str }), prefix_of : Dict(Str, Str) }

# A walk over a tree with an explicit work list, so a deep tree cannot
# exhaust the call stack: an element is visited, then its children, then left.
Step : [Visit(XmlTree.Node), Leave]

Element : { name : XmlTree.Name, bindings : List(XmlTree.Binding), attributes : List(XmlTree.Attribute), children : List(XmlTree.Node) }

# The namespace a part writes as its default: the root's, when that is one of
# the package-level namespaces.
part_default : XmlTree.Node -> XmlTree.Namespace
part_default = |root|
	match root {
		Element(element) =>
			match element.name.namespace {
				Uri(uri) if XmlTree.default_namespaces.contains(uri) => Uri(uri)
				_ => NoNamespace
			}

		Text(_) => NoNamespace
	}

# Every namespace the tree needs a prefix for, once, in the order the tree
# first uses it: the names of elements outside the default namespace and of
# attributes, and the namespaces attribute values name by prefix.
needed_prefixes : XmlTree.Node, XmlTree.Namespace -> List(Need)
needed_prefixes = |root, default| {
	var $needed = { order: List.with_capacity(8), seen: Set.with_capacity(8) }
	var $scopes = List.with_capacity(16)
	var $pending = [Visit(root)]
	while !$pending.is_empty() {
		next = $pending.last() ?? Leave
		$pending = List.drop_last($pending, 1)
		match next {
			Visit(Element(element)) => {
				$scopes = List.append($scopes, element.bindings)
				if element.name.namespace != default {
					$needed = note_name($needed, element.name)
				}
				for attribute in element.attributes {
					$needed = note_name($needed, attribute.name)
					for prefix in named_prefixes(element.name, attribute) {
						match resolve(prefix, $scopes) {
							Ok(namespace) => {
								$needed = note($needed, namespace, prefix)
							}

							Err(_) => {}
						}
					}
				}
				$pending = push_children(List.append($pending, Leave), element.children)
			}

			Visit(Text(_)) => {}

			Leave => {
				$scopes = List.drop_last($scopes, 1)
			}
		}
	}
	$needed.order
}

# The namespaces needed so far, in order, and as a set.
Needed : { order : List(Need), seen : Set(Str) }

note_name : Needed, XmlTree.Name -> Needed
note_name = |needed, name|
	match (name.namespace, name.prefix) {
		(Uri(uri), Prefix(prefix)) => note(needed, uri, prefix)
		(Uri(uri), Unprefixed) => note(needed, uri, "")
		(NoNamespace, _) => needed
	}

# Note a namespace with the prefix it was read with, unless it is noted
# already or is the `xml` namespace, whose prefix is fixed.
note : Needed, Str, Str -> Needed
note = |needed, namespace, read|
	if namespace == xml_namespace or needed.seen.contains(namespace) {
		needed
	} else {
		{ order: List.append(needed.order, { namespace, read }), seen: needed.seen.insert(namespace) }
	}

# The prefix of every needed namespace: the table's for a namespace in it,
# declared first in table order; otherwise the prefix it was read with, or
# the first free `ns1`, `ns2` and so on, declared in the order of `needed`.
plan_prefixes : List(Need) -> Plan
plan_prefixes = |needed| {
	var $declarations = List.with_capacity(needed.len())
	var $prefix_of = Dict.with_capacity(needed.len())
	var $taken = Set.with_capacity(XmlTree.prefixes.len() + needed.len())
	for entry in XmlTree.prefixes {
		$taken = $taken.insert(entry.prefix)
		if needed.any(|need| need.namespace == entry.namespace) {
			$declarations = List.append($declarations, entry)
			$prefix_of = $prefix_of.insert(entry.namespace, entry.prefix)
		}
	}
	var $counter = 0.U64
	for need in needed {
		if !$prefix_of.contains(need.namespace) {
			var $prefix = need.read
			if need.read == "" or $taken.contains(need.read) or is_reserved(need.read) {
				$counter = $counter + 1
				$prefix = "ns${$counter.to_str()}"
				while $taken.contains($prefix) {
					$counter = $counter + 1
					$prefix = "ns${$counter.to_str()}"
				}
			}
			$taken = $taken.insert($prefix)
			$declarations = List.append($declarations, { prefix: $prefix, namespace: need.namespace })
			$prefix_of = $prefix_of.insert(need.namespace, $prefix)
		}
	}
	{ declarations: $declarations, prefix_of: $prefix_of }
}

# Prefixes beginning with `xml`, in any case, are reserved by Namespaces in
# XML 1.0.
is_reserved : Str -> Bool
is_reserved = |prefix|
	prefix.to_utf8().sublist({ start: 0, len: 3 }).map(|byte| if (byte >= 'A' and byte <= 'Z') byte + 32 else byte) == "xml".to_utf8()

# The tree in the dependency's node type, with the prefixes and declarations
# of `plan` and the values that name namespaces by prefix rewritten to them.
canonical : XmlTree.Node, XmlTree.Namespace, Plan -> XmlNs.Node
canonical = |root, default, plan| {
	var $pending = [Visit(root)]
	var $scopes = List.with_capacity(16)
	var $frames = List.with_capacity(16)
	var $nodes = List.with_capacity(16)
	while !$pending.is_empty() {
		next = $pending.last() ?? Leave
		$pending = List.drop_last($pending, 1)
		match next {
			Visit(Text(content)) => {
				text : XmlNs.Node
				text = Text(content)
				$nodes = List.append($nodes, text)
			}

			Visit(Element(element)) => {
				$scopes = List.append($scopes, element.bindings)
				scopes = $scopes
				outer = match $frames.last() {
					Ok(frame) => frame.default
					Err(_) => NoNamespace
				}
				declared = if $frames.is_empty() {
					plan.declarations.map(|entry| { prefix: Prefix(entry.prefix), namespace: Uri(entry.namespace) })
				} else {
					[]
				}
				namespace = element.name.namespace
				inner = if (namespace == NoNamespace or namespace == default) namespace else outer
				bindings = if (inner != outer) List.prepend(declared, { prefix: Default, namespace: inner }) else declared
				prefix = if (namespace == default) Unprefixed else prefix_of(namespace, plan)
				# Attributes already written as the plan writes them are kept as
				# they are, so most elements copy nothing.
				unchanged = element.attributes.all(|attribute| attribute.name.prefix == prefix_of(attribute.name.namespace, plan) and value_kind(element.name, attribute.name) == Plain)
				attributes = if unchanged {
					element.attributes
				} else {
					element.attributes.map(
						|attribute| {
							name: { namespace: attribute.name.namespace, local: attribute.name.local, prefix: prefix_of(attribute.name.namespace, plan) },
							value: rewrite(element.name, attribute, scopes, |uri| written_prefix(uri, plan)),
						},
					)
				}
				$frames = List.append($frames, { name: { namespace, local: element.name.local, prefix }, bindings, attributes, first_child: $nodes.len(), default: inner })
				$pending = push_children(List.append($pending, Leave), element.children)
			}

			Leave => {
				$scopes = List.drop_last($scopes, 1)
				match $frames.last() {
					Ok(frame) => {
						$frames = List.drop_last($frames, 1)
						node : XmlNs.Node
						node = Element({ name: frame.name, bindings: frame.bindings, attributes: frame.attributes, children: copy_from($nodes, frame.first_child) })
						$nodes = List.append(truncate($nodes, frame.first_child), node)
					}

					Err(_) => {}
				}
			}
		}
	}
	$nodes.last() ?? Text("")
}

# How a name in a namespace is prefixed under a plan.
prefix_of : XmlTree.Namespace, Plan -> [Prefix(Str), Unprefixed]
prefix_of = |namespace, plan|
	match namespace {
		Uri(uri) => Prefix(written_prefix(uri, plan))
		NoNamespace => Unprefixed
	}

written_prefix : Str, Plan -> Str
written_prefix = |uri, plan|
	if uri == xml_namespace {
		"xml"
	} else {
		plan.prefix_of.get(uri) ?? ""
	}

# Children are pushed last first, so the first is visited next.
push_children : List(Step), List(XmlTree.Node) -> List(Step)
push_children = |pending, children| {
	var $out = pending
	var $index = children.len()
	while $index > 0 {
		$index = $index - 1
		match children.get($index) {
			Ok(child) => {
				$out = List.append($out, Visit(child))
			}

			Err(_) => {}
		}
	}
	$out
}

# How an attribute's value names namespaces: as a list of prefixes, as a list
# of qualified names, or not at all.
value_kind : XmlTree.Name, XmlTree.Name -> [Prefixes, QualifiedNames, Plain]
value_kind = |element, attribute|
	match attribute.namespace {
		Uri(uri) =>
			if uri == markup_compatibility and (attribute.local == "Ignorable" or attribute.local == "MustUnderstand") {
				Prefixes
			} else if uri == markup_compatibility and (attribute.local == "ProcessContent" or attribute.local == "PreserveElements" or attribute.local == "PreserveAttributes") {
				QualifiedNames
			} else if uri == schema_instance and attribute.local == "type" {
				QualifiedNames
			} else {
				Plain
			}

		NoNamespace =>
			if attribute.local == "Requires" and element.namespace == Uri(markup_compatibility) and element.local == "Choice" {
				Prefixes
			} else {
				Plain
			}
	}

# The prefixes an attribute's value names.
named_prefixes : XmlTree.Name, XmlTree.Attribute -> List(Str)
named_prefixes = |element, attribute|
	match value_kind(element, attribute.name) {
		Prefixes => words(attribute.value)
		QualifiedNames => words(attribute.value).keep_oks(|word| word.split_first(":").map_ok(|parts| parts.before))
		Plain => []
	}

# An attribute's value with every prefix it names that `scopes` declares
# replaced by `replace` of its namespace, the items separated by one space;
# any other value as it is.
rewrite : XmlTree.Name, XmlTree.Attribute, List(List(XmlTree.Binding)), (Str -> Str) -> Str
rewrite = |element, attribute, scopes, replace|
	match value_kind(element, attribute.name) {
		Plain => attribute.value
		Prefixes =>
			Str.join_with(
				words(attribute.value).map(
					|word|
						match resolve(word, scopes) {
							Ok(namespace) => replace(namespace)
							Err(_) => word
						},
				),
				" ",
			)

		QualifiedNames =>
			Str.join_with(
				words(attribute.value).map(
					|word|
						match word.split_first(":") {
							Ok({ before, after }) =>
								match resolve(before, scopes) {
									Ok(namespace) => "${replace(namespace)}:${after}"
									Err(_) => word
								}

							Err(_) => word
						},
				),
				" ",
			)
	}

# The namespace a prefix is bound to by the declarations in scope, the last
# of `scopes` innermost; `xml` is bound everywhere.
resolve : Str, List(List(XmlTree.Binding)) -> Try(Str, [Unbound])
resolve = |prefix, scopes| {
	if prefix == "xml" {
		return Ok(xml_namespace)
	}
	var $index = scopes.len()
	while $index > 0 {
		$index = $index - 1
		match (scopes.get($index) ?? []).find_first(|binding| binding.prefix == Prefix(prefix)) {
			Ok({ prefix: _, namespace: Uri(uri) }) => {
				return Ok(uri)
			}

			Ok(_) => {
				return Err(Unbound)
			}

			Err(_) => {}
		}
	}
	Err(Unbound)
}

# The items of a whitespace-separated list.
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

xml_namespace : Str
xml_namespace = "http://www.w3.org/XML/1998/namespace"

markup_compatibility : Str
markup_compatibility = "http://schemas.openxmlformats.org/markup-compatibility/2006"

schema_instance : Str
schema_instance = "http://www.w3.org/2001/XMLSchema-instance"

w : Str
w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

## A part resolves every name to its namespace, keeps the prefixes and
## declarations it was written with, and keeps whitespace between elements.
expect {
	part = "<?xml version='1.0' encoding='UTF-8' standalone='yes'?>\n<w:document xmlns:w='${w}'>\n<w:body><w:p w:rsidR='00A1'/></w:body></w:document>"
	body : XmlTree.Node
	body = Element({
		name: { namespace: Uri(w), local: "body", prefix: Prefix("w") },
		bindings: [],
		attributes: [],
		children: [Element({ name: { namespace: Uri(w), local: "p", prefix: Prefix("w") }, bindings: [], attributes: [{ name: { namespace: Uri(w), local: "rsidR", prefix: Prefix("w") }, value: "00A1" }], children: [] })],
	})
	expected : XmlTree.Node
	expected = Element({ name: { namespace: Uri(w), local: "document", prefix: Prefix("w") }, bindings: [{ prefix: Prefix("w"), namespace: Uri(w) }], attributes: [], children: [Text("\n"), body] })
	XmlTree.parse(part.to_utf8(), {}) == Ok(expected)
}

## A tree is written with the fixed prefixes, declared once on the root, and
## reads back to the same names whatever prefix the source used.
expect {
	source = "<x:document xmlns:x='${w}'><x:body xmlns:rel='http://schemas.openxmlformats.org/officeDocument/2006/relationships'><x:p rel:id='rId1'>a &amp; b</x:p></x:body></x:document>"
	tree = XmlTree.parse(source.to_utf8(), {})?
	written = XmlTree.render(tree)?
	expected = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<w:document xmlns:w=\"${w}\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><w:body><w:p r:id=\"rId1\">a &amp; b</w:p></w:body></w:document>"
	Str.from_utf8(written) == Ok(expected) and XmlTree.render(XmlTree.parse(written, {})?) == Ok(written)
}

## A package-level part keeps its namespace as the default.
expect {
	source = "<Relationships xmlns='http://schemas.openxmlformats.org/package/2006/relationships'><Relationship Id='rId1'/></Relationships>"
	written = XmlTree.render(XmlTree.parse(source.to_utf8(), {})?)?
	Str.from_utf8(written) == Ok("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\"/></Relationships>")
}

## A namespace outside the prefix table keeps the prefix it was read with,
## unless the table or an earlier namespace has it, and is declared after the
## table's namespaces.
expect {
	source = "<x:document xmlns:x='${w}' xmlns:e='urn:e'><e:a xmlns:w='urn:w' w:k='1'/><x:b xmlns:e='urn:f' e:k='2'/></x:document>"
	written = XmlTree.render(XmlTree.parse(source.to_utf8(), {})?)?
	Str.from_utf8(written) == Ok("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<w:document xmlns:w=\"${w}\" xmlns:e=\"urn:e\" xmlns:ns1=\"urn:w\" xmlns:ns2=\"urn:f\"><e:a ns1:k=\"1\"/><w:b ns2:k=\"2\"/></w:document>")
}

## Prefixes named in compatibility attributes and in `xsi:type` are written
## as the prefixes of their namespaces, which the root declares even when no
## name uses them.
expect {
	declarations = "xmlns:x='${w}' xmlns:mc='http://schemas.openxmlformats.org/markup-compatibility/2006' xmlns:q='http://schemas.microsoft.com/office/word/2010/wordml' xmlns:z='urn:z' xmlns:i='http://www.w3.org/2001/XMLSchema-instance'"
	source = "<x:document ${declarations} mc:Ignorable='q  z' mc:ProcessContent='z:* q:p'><mc:AlternateContent><mc:Choice Requires='z'/></mc:AlternateContent><x:p i:type='x:CT_P'/></x:document>"
	written = XmlTree.render(XmlTree.parse(source.to_utf8(), {})?)?
	root = "<w:document xmlns:w=\"${w}\" xmlns:mc=\"http://schemas.openxmlformats.org/markup-compatibility/2006\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" xmlns:w14=\"http://schemas.microsoft.com/office/word/2010/wordml\" xmlns:z=\"urn:z\" mc:Ignorable=\"w14 z\" mc:ProcessContent=\"z:* w14:p\">"
	Str.from_utf8(written) == Ok("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n${root}<mc:AlternateContent><mc:Choice Requires=\"z\"/></mc:AlternateContent><w:p xsi:type=\"w:CT_P\"/></w:document>")
}

## Without prefixes, two spellings of the same names and compatibility
## values compare equal, and an undeclared prefix stays as written.
expect {
	declarations = "xmlns:mc='http://schemas.openxmlformats.org/markup-compatibility/2006' mc:Ignorable='e u'"
	one = XmlTree.parse("<a:x xmlns:a='urn:a' xmlns:e='urn:e' ${declarations}/>".to_utf8(), {})?
	other = XmlTree.parse("<b:x xmlns:b='urn:a' xmlns:f='urn:e' xmlns:mc='http://schemas.openxmlformats.org/markup-compatibility/2006' mc:Ignorable='f u'/>".to_utf8(), {})?
	expected : XmlTree.Node
	expected = Element({
		name: { namespace: Uri("urn:a"), local: "x", prefix: Unprefixed },
		bindings: [],
		attributes: [{ name: { namespace: Uri("http://schemas.openxmlformats.org/markup-compatibility/2006"), local: "Ignorable", prefix: Unprefixed }, value: "{urn:e} u" }],
		children: [],
	})
	XmlTree.unprefixed(one) == expected and XmlTree.unprefixed(other) == expected
}

## An undeclared prefix is a located namespace error.
expect XmlTree.parse("<w:document/>".to_utf8(), {}) == Err(NamespaceError({ problem: UndeclaredPrefix("w"), line: 1, column: 1 }))

## Malformed XML, including content after the root, is a located error.
expect {
	match XmlTree.parse("<a/><b/>".to_utf8(), {}) {
		Err(MalformedXml(_)) => Bool.True
		_ => Bool.False
	}
}

## Bytes that are not UTF-8 are an error.
expect XmlTree.parse([0x3C, 0xFF, 0x2F, 0x3E], {}) == Err(XmlNotUtf8)

## Each XML bound of `Limits` is a named error at the place it is exceeded.
expect {
	XmlTree.parse("<a><b/></a>".to_utf8(), { max_xml_depth: 1 }) == Err(XmlTooDeep({ max: 1, line: 1, column: 4 }))
		and XmlTree.parse("<a><b/><c/></a>".to_utf8(), { max_xml_elements: 2 }) == Err(TooManyXmlElements({ max: 2, line: 1, column: 8 }))
		and XmlTree.parse("<a x='1' y='2'/>".to_utf8(), { max_xml_attributes: 1 }) == Err(TooManyXmlAttributes({ max: 1, line: 1, column: 10 }))
}

## Splitting gives the chosen element's children one at a time, text
## included, as the whole tree holds them, and leaves the element empty; a
## later element of the same name stays whole in the tree.
expect {
	text = "<a:r xmlns:a='urn:a' xmlns:b='urn:b'><a:s/><a:body k='v'><a:p><b:x b:y='1'>t</b:x></a:p>\n<a:q/></a:body><a:body><a:p/></a:body></a:r>"
	split = XmlTree.parse_split(text.to_utf8(), {}, |root, child| root.local == "r" and child.local == "body", [], |found, node| List.append(found, node))
	whole = XmlTree.parse(text.to_utf8(), {})
	expected = XmlTree.parse("<a:r xmlns:a='urn:a' xmlns:b='urn:b'><a:s/><a:body k='v'/><a:body><a:p/></a:body></a:r>".to_utf8(), {})
	children = match whole {
		Ok(Element(root)) =>
			match root.children.get(1) {
				Ok(Element(body)) => body.children
				_ => []
			}

		_ => []
	}
	split.map_ok(|read| read.state) == Ok(children) and split.map_ok(|read| read.tree) == expected and children.len() == 3
}

## Scanning gives each element's start, with its resolved name and
## attributes, and its end, in document order, and fails as parsing does.
expect {
	events = XmlTree.scan("<a xmlns='urn:a'><b c='d'>text</b><e/></a>".to_utf8(), {}, [], |found, event| List.append(found, event))
	name = |local| { namespace: Uri("urn:a"), local, prefix: Unprefixed }
	expected = [Start({ name: name("a"), attributes: [] }), Start({ name: name("b"), attributes: [{ name: { namespace: NoNamespace, local: "c", prefix: Unprefixed }, value: "d" }] }), End, Start({ name: name("e"), attributes: [] }), End, End]
	events == Ok(expected) and XmlTree.scan("<w:a/>".to_utf8(), {}, 0.U64, |count, _| count + 1) == Err(NamespaceError({ problem: UndeclaredPrefix("w"), line: 1, column: 1 }))
}
