## The XML of a part as a namespaced tree, read within explicit limits and
## written with the package's fixed prefix table.
##
## Every element and attribute is named by its namespace and local name, as
## Namespaces in XML 1.0 defines; the prefix a name was written with and each
## element's own namespace declarations are kept beside the name. Reading is
## one pass over the part with a pull reader, and a malformed part, a broken
## namespace rule or an exceeded limit is a located error, never a crash.
## Writing ignores the prefixes a tree was read with: each namespace is
## written with its prefix from [XmlTree.prefixes], declared once on the root,
## so the same tree always gives the same bytes.
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
	## namespace with no prefix in [XmlTree.prefixes], or two attributes with
	## the same name. `path` names the elements from the root to the one the
	## problem is in.
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
	parse = |bytes, limits| {
		text = Str.from_utf8(bytes) ? |_| XmlNotUtf8
		var $reader = XmlNs.reader(text, { max_depth: limits.max_xml_depth, max_elements: limits.max_xml_elements, max_attributes: limits.max_xml_attributes }) ? read_error
		var $frames = List.with_capacity(16)
		var $nodes = List.with_capacity(16)
		var $reading = Bool.True
		while $reading {
			match $reader.next() {
				Event(Start(start), rest) => {
					$frames = List.append($frames, { start, first_child: $nodes.len() })
					$reader = rest
				}

				Event(Text(content), rest) => {
					$nodes = List.append($nodes, Text(content))
					$reader = rest
				}

				Event(End(_), rest) => {
					# The reader pairs every end tag with a start, so a frame is open.
					match $frames.last() {
						Ok({ start, first_child }) => {
							$frames = List.drop_last($frames, 1)
							node : Node
							node = Element({ name: start.name, bindings: start.bindings, attributes: start.attributes, children: copy_from($nodes, first_child) })
							$nodes = List.append(truncate($nodes, first_child), node)
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
		Ok($nodes.last() ? |_| MalformedXml({ message: "no root element", line: 1, column: 1 }))
	}

	## Write a tree as a part: an XML declaration with `standalone="yes"`,
	## then the root, which declares every namespace the tree uses with its
	## prefix from [XmlTree.prefixes], in that order. Attributes are written
	## in the order the tree gives them, so the same tree always writes the
	## same bytes, and [XmlTree.parse] reads them back as the same tree up to
	## prefixes and declarations.
	render : Node -> Try(List(U8), WriteError)
	render = |root| {
		table = match root {
			Element(element) =>
				match element.name.namespace {
					Uri(uri) if default_namespaces.contains(uri) => List.prepend(prefixes, { prefix: "", namespace: uri })
					_ => prefixes
				}

			Text(_) => prefixes
		}
		written = XmlNs.render({ declaration: Err(Missing), root: to_dependency(root) }, { declaration: Standalone, prefixes: Table(table) }) ? write_error
		Ok(written.to_utf8())
	}
}

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

# The same tree in the dependency's node type, built with an explicit work
# list so a deep tree cannot exhaust the call stack.
to_dependency : XmlTree.Node -> XmlNs.Node
to_dependency = |root| {
	var $pending = [Visit(root)]
	var $frames = List.with_capacity(16)
	var $nodes = List.with_capacity(16)
	while !$pending.is_empty() {
		next = $pending.last() ?? Close
		$pending = List.drop_last($pending, 1)
		match next {
			Visit(Text(content)) => {
				text : XmlNs.Node
				text = Text(content)
				$nodes = List.append($nodes, text)
			}

			Visit(Element(element)) => {
				$frames = List.append($frames, { name: element.name, bindings: element.bindings, attributes: element.attributes, first_child: $nodes.len() })
				$pending = List.append($pending, Close)
				var $index = element.children.len()
				while $index > 0 {
					$index = $index - 1
					match element.children.get($index) {
						Ok(child) => {
							$pending = List.append($pending, Visit(child))
						}

						Err(_) => {}
					}
				}
			}

			Close =>
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
	$nodes.last() ?? Text("")
}

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

## A namespace outside the prefix table cannot be written.
expect {
	tree = XmlTree.parse("<e:x xmlns:e='urn:example'/>".to_utf8(), {})?
	XmlTree.render(tree) == Err(XmlUnwritable({ problem: UnknownNamespace("urn:example"), path: ["e:x"] }))
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
