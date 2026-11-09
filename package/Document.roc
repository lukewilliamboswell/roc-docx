## A document as the package holds it, and what it means for two documents
## to be the same.
##
## Until the WordprocessingML model exists, a document is its package and the
## namespaced XML tree of each of its XML parts. Reading parses every XML part
## and drops the editor state the architecture's fidelity rules name, with a
## diagnostic; writing renders each tree in the canonical form of
## [XmlTree.render] and copies every other part exactly as its archive stored
## it. A document therefore holds the archive's bytes and the trees of its XML
## parts, and while it is read or written, one part's bytes beyond them.
import Limits
import Opc
import XmlTree

Document :: { pkg : Opc.Package, graph : Opc.Graph, trees : Dict(Str, XmlTree.Node) }.{

	## Something reading did to a document that writing it back shows: a part
	## lost `count` occurrences of editor state that carries no document
	## meaning.
	Diagnostic : [Dropped({ part : Str, content : Dropped, count : U64 })]

	## The editor state that is dropped, each by a rule of the architecture:
	## revision save identifiers (`w:rsid` and every other WordprocessingML
	## attribute whose name begins with `rsid`), rendered page breaks
	## (`w:lastRenderedPageBreak`), proofing marks (`w:proofErr`), and the
	## bookmark named `_GoBack` with its end.
	Dropped : [RevisionSaveIds, RenderedPageBreaks, ProofingMarks, GoBackBookmark]

	## Why an opened package cannot be read as a document: a relationship part
	## that cannot be read, an XML part whose stored data is damaged, or one
	## that is not namespace-well-formed XML within the limits.
	ReadError : [
		MissingPart(Str),
		RelationshipsNotXml({ part : Str, problem : XmlTree.ReadError }),
		MissingAttribute(Opc.AttributeLocation),
		TruncatedArchive,
		CompressionNotSupported(U16),
		CrcMismatch({ path : Str, expected : U32, actual : U32 }),
		InvalidCompressedData(Str),
		PartSizeMismatch({ name : Str, declared : U64 }),
		XmlPartUnreadable({ part : Str, problem : XmlTree.ReadError }),
	]

	## Why a document cannot be written: the package writer's errors, or a
	## tree that cannot be written as XML.
	WriteError : [
		InvalidPartName(Str),
		DuplicatePart(Str),
		InvalidContentType(Str),
		InvalidRelationship({ source : Str, id : Str }),
		DuplicateRelationshipId({ source : Str, id : Str }),
		NothingPending,
		NotWritten(Str),
		MissingPart(Str),
		TruncatedArchive,
		PartSizeMismatch({ name : Str, declared : U64 }),
		XmlPartUnwritable({ part : Str, problem : XmlTree.WriteError }),
	]

	## Read an opened package as a document: its part graph, and every part
	## whose content type is XML (`application/xml`, `text/xml` or a type
	## ending in `+xml`) parsed within the XML bounds of `limits`, with the
	## dropped content removed. The diagnostics list each part's dropped
	## content by kind, parts in graph order.
	from_package : Opc.Package, Limits -> Try({ document : Document, diagnostics : List(Diagnostic) }, ReadError)
	from_package = |pkg, limits| {
		graph = Opc.graph(pkg)?
		var $trees = Dict.with_capacity(graph.parts.len())
		var $diagnostics = List.with_capacity(4)
		for part in graph.parts {
			if is_xml(part.content_type) {
				bytes = Opc.part_bytes(pkg, part.name)?
				tree = XmlTree.parse(bytes, limits) ? |problem| XmlPartUnreadable({ part: part.name, problem })
				kept = drop(tree)
				$trees = $trees.insert(part.name, kept.tree)
				for dropped in kept.dropped {
					$diagnostics = List.append($diagnostics, Dropped({ part: part.name, content: dropped.content, count: dropped.count }))
				}
			}
		}
		Ok({ document: { pkg, graph, trees: $trees }, diagnostics: $diagnostics })
	}

	## Write a document as a package, in the order and form of [Opc.writer]:
	## each XML part rendered by [XmlTree.render], every other part copied
	## with its stored bytes. The same document always gives the same bytes,
	## and either the whole package is written or an error names the reason.
	to_bytes : Document -> Try(List(U8), WriteError)
	to_bytes = |document| {
		var $writer = Opc.writer(document.graph)?
		var $out = List.with_capacity(0)
		for name in Opc.pending($writer) {
			content = match document.trees.get(name) {
				Ok(tree) => Bytes(XmlTree.render(tree) ? |problem| XmlPartUnwritable({ part: name, problem }))
				Err(_) => Copied(document.pkg)
			}
			added = Opc.add($writer, content)?
			$out = List.concat($out, added.chunk)
			$writer = added.writer
		}
		Ok(List.concat($out, Opc.finish($writer)?))
	}

	## Two documents are equivalent when they have the same package
	## relationships and the same parts by name, each with the same content
	## type and relationships, every XML part's tree equivalent by
	## [Document.equivalent_xml] and every other part's content byte for byte
	## the same. This is the equivalence a document keeps when it is written
	## and read again.
	equivalent : Document, Document -> Bool
	equivalent = |one, other| {
		if one.graph.relationships != other.graph.relationships or one.graph.parts.len() != other.graph.parts.len() {
			return Bool.False
		}
		var $counterparts = Dict.with_capacity(other.graph.parts.len())
		for part in other.graph.parts {
			$counterparts = $counterparts.insert(part.name, part)
		}
		for part in one.graph.parts {
			same = match $counterparts.get(part.name) {
				Ok(counterpart) =>
					counterpart == part and match (one.trees.get(part.name), other.trees.get(part.name)) {
						(Ok(tree), Ok(other_tree)) => Document.equivalent_xml(tree, other_tree)
						(Err(_), Err(_)) => same_content(one.pkg, other.pkg, part.name)
						_ => Bool.False
					}

				Err(_) => Bool.False
			}
			if !same {
				return Bool.False
			}
		}
		Bool.True
	}

	## Two trees of a part are equivalent when they are equal after these
	## normalizations, which are the architecture's round-trip equivalence:
	##
	## * Names compare by namespace and local name; prefixes and declarations
	##   are ignored, and so are the prefixes in attribute values that name
	##   namespaces, as [XmlTree.unprefixed] resolves them.
	## * Attribute order is ignored.
	## * Text that is only whitespace, beside an element among an element's
	##   children, is ignored unless `xml:space="preserve"` applies there; all
	##   other text compares exactly, adjacent runs of text joined.
	## * The dropped content of [Document.Dropped] is removed from both.
	equivalent_xml : XmlTree.Node, XmlTree.Node -> Bool
	equivalent_xml = |one, other| normalized(one) == normalized(other)
}

# The content a part holds, read from each package: the same when both
# inflate to the same bytes, or, when either cannot be inflated, when both
# are stored identically.
same_content : Opc.Package, Opc.Package, Str -> Bool
same_content = |one, other, name|
	match (Opc.part_bytes(one, name), Opc.part_bytes(other, name)) {
		(Ok(bytes), Ok(other_bytes)) => bytes == other_bytes
		_ => Opc.stored(one, name) == Opc.stored(other, name)
	}

is_xml : Str -> Bool
is_xml = |content_type| content_type.ends_with("+xml") or content_type == "application/xml" or content_type == "text/xml"

wordprocessingml : Str
wordprocessingml = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

xml_namespace : Str
xml_namespace = "http://www.w3.org/XML/1998/namespace"

Element : { name : XmlTree.Name, bindings : List(XmlTree.Binding), attributes : List(XmlTree.Attribute), children : List(XmlTree.Node) }

# A walk over a tree with an explicit work list, so a deep tree cannot
# exhaust the call stack: an element is visited, then its children, then left.
Step : [Visit(XmlTree.Node), Leave]

# A tree without its dropped content, with how much of each kind it lost, in
# the order of `Dropped`. The root is always kept.
drop : XmlTree.Node -> { tree : XmlTree.Node, dropped : List({ content : Document.Dropped, count : U64 }) }
drop = |root| {
	go_back = go_back_ids(root)
	var $save_ids = 0.U64
	var $page_breaks = 0.U64
	var $proofing = 0.U64
	var $bookmarks = 0.U64
	var $pending = [Visit(root)]
	var $frames = List.with_capacity(16)
	var $nodes = List.with_capacity(16)
	while !$pending.is_empty() {
		next = $pending.last() ?? Leave
		$pending = List.drop_last($pending, 1)
		match next {
			Visit(Text(content)) => {
				text : XmlTree.Node
				text = Text(content)
				$nodes = List.append($nodes, text)
			}

			Visit(Element(element)) => {
				kind = if ($frames.is_empty()) Kept else dropped_kind(element, go_back)
				match kind {
					Kept => {
						attributes = element.attributes.drop_if(is_save_id)
						$save_ids = $save_ids + element.attributes.len() - attributes.len()
						$frames = List.append($frames, { name: element.name, bindings: element.bindings, attributes, first_child: $nodes.len() })
						$pending = push_children(List.append($pending, Leave), element.children)
					}

					RenderedPageBreak => {
						$page_breaks = $page_breaks + 1
					}

					ProofingMark => {
						$proofing = $proofing + 1
					}

					GoBackStart => {
						$bookmarks = $bookmarks + 1
					}

					GoBackEnd => {}
				}
			}

			Leave =>
				match $frames.last() {
					Ok(frame) => {
						$frames = List.drop_last($frames, 1)
						node : XmlTree.Node
						node = Element({ name: frame.name, bindings: frame.bindings, attributes: frame.attributes, children: copy_from($nodes, frame.first_child) })
						$nodes = List.append(truncate($nodes, frame.first_child), node)
					}

					Err(_) => {}
				}
		}
	}
	counts = [
		{ content: RevisionSaveIds, count: $save_ids },
		{ content: RenderedPageBreaks, count: $page_breaks },
		{ content: ProofingMarks, count: $proofing },
		{ content: GoBackBookmark, count: $bookmarks },
	]
	{ tree: $nodes.last() ?? root, dropped: counts.keep_if(|entry| entry.count > 0) }
}

# Whether an element below the root is dropped, and by which rule.
dropped_kind : Element, List(Str) -> [Kept, RenderedPageBreak, ProofingMark, GoBackStart, GoBackEnd]
dropped_kind = |element, go_back|
	if element.name.namespace != Uri(wordprocessingml) {
		Kept
	} else if element.name.local == "lastRenderedPageBreak" {
		RenderedPageBreak
	} else if element.name.local == "proofErr" {
		ProofingMark
	} else if element.name.local == "bookmarkStart" and value_of(element, "name") == Ok("_GoBack") {
		GoBackStart
	} else if element.name.local == "bookmarkEnd" and go_back.contains(value_of(element, "id") ?? "") {
		GoBackEnd
	} else {
		Kept
	}

# The identifiers of the `_GoBack` bookmarks, whose ends are dropped with them.
go_back_ids : XmlTree.Node -> List(Str)
go_back_ids = |root| {
	var $ids = List.with_capacity(1)
	var $pending = [root]
	while !$pending.is_empty() {
		match $pending.last() {
			Ok(Element(element)) => {
				$pending = List.concat(List.drop_last($pending, 1), element.children)
				if element.name.namespace == Uri(wordprocessingml) and element.name.local == "bookmarkStart" and value_of(element, "name") == Ok("_GoBack") {
					$ids = List.append($ids, value_of(element, "id") ?? "")
				}
			}

			_ => {
				$pending = List.drop_last($pending, 1)
			}
		}
	}
	$ids
}

# The value of a WordprocessingML attribute of an element.
value_of : Element, Str -> Try(Str, [NotFound])
value_of = |element, local|
	element.attributes.find_first(|attribute| attribute.name.namespace == Uri(wordprocessingml) and attribute.name.local == local).map_ok(|attribute| attribute.value)

is_save_id : XmlTree.Attribute -> Bool
is_save_id = |attribute| attribute.name.namespace == Uri(wordprocessingml) and attribute.name.local.starts_with("rsid")

# The form two trees are compared in: dropped content removed, prefixes
# resolved, attributes sorted by namespace and local name, adjacent text
# joined and whitespace between elements removed where it is insignificant.
normalized : XmlTree.Node -> XmlTree.Node
normalized = |tree| {
	root = XmlTree.unprefixed(drop(tree).tree)
	var $pending = [Visit(root)]
	var $frames = List.with_capacity(16)
	var $nodes = List.with_capacity(16)
	while !$pending.is_empty() {
		next = $pending.last() ?? Leave
		$pending = List.drop_last($pending, 1)
		match next {
			Visit(Text(content)) => {
				text : XmlTree.Node
				text = Text(content)
				$nodes = List.append($nodes, text)
			}

			Visit(Element(element)) => {
				inherited = match $frames.last() {
					Ok(frame) => frame.preserve
					Err(_) => Bool.False
				}
				preserve = match element.attributes.find_first(|attribute| attribute.name.namespace == Uri(xml_namespace) and attribute.name.local == "space") {
					Ok(attribute) => attribute.value == "preserve"
					Err(_) => inherited
				}
				attributes = element.attributes.sort_with(|a, b| by_name(a.name, b.name))
				$frames = List.append($frames, { name: element.name, attributes, preserve, first_child: $nodes.len() })
				$pending = push_children(List.append($pending, Leave), element.children)
			}

			Leave =>
				match $frames.last() {
					Ok(frame) => {
						$frames = List.drop_last($frames, 1)
						node : XmlTree.Node
						node = Element({ name: frame.name, bindings: [], attributes: frame.attributes, children: tidy(copy_from($nodes, frame.first_child), frame.preserve) })
						$nodes = List.append(truncate($nodes, frame.first_child), node)
					}

					Err(_) => {}
				}
		}
	}
	$nodes.last() ?? root
}

# An element's children with adjacent text joined and, among element
# children, whitespace-only text removed unless whitespace is preserved.
tidy : List(XmlTree.Node), Bool -> List(XmlTree.Node)
tidy = |children, preserve| {
	var $joined = List.with_capacity(children.len())
	var $has_element = Bool.False
	for child in children {
		match (child, $joined.last()) {
			(Text(content), Ok(Text(previous))) => {
				joined : XmlTree.Node
				joined = Text(Str.concat(previous, content))
				$joined = List.append(List.drop_last($joined, 1), joined)
			}

			(Element(_), _) => {
				$has_element = Bool.True
				$joined = List.append($joined, child)
			}

			_ => {
				$joined = List.append($joined, child)
			}
		}
	}
	if $has_element and !preserve {
		$joined.drop_if(
			|child|
				match child {
					Text(content) => is_whitespace(content)
					Element(_) => Bool.False
				},
		)
	} else {
		$joined
	}
}

is_whitespace : Str -> Bool
is_whitespace = |text| text.to_utf8().all(|byte| byte == 32 or byte == 9 or byte == 10 or byte == 13)

# Names ordered by namespace, no namespace first, then by local name, byte by
# byte.
by_name : XmlTree.Name, XmlTree.Name -> [Before, Same, After]
by_name = |one, other| {
	namespace = |name|
		match name.namespace {
			Uri(uri) => uri
			NoNamespace => ""
		}
	match by_bytes(namespace(one), namespace(other)) {
		Same => by_bytes(one.local, other.local)
		order => order
	}
}

by_bytes : Str, Str -> [Before, Same, After]
by_bytes = |one, other| {
	left = one.to_utf8()
	right = other.to_utf8()
	var $index = 0.U64
	while $index < left.len() and $index < right.len() {
		a = left.get($index) ?? 0
		b = right.get($index) ?? 0
		if a < b {
			return Before
		}
		if a > b {
			return After
		}
		$index = $index + 1
	}
	if left.len() < right.len() {
		Before
	} else if left.len() > right.len() {
		After
	} else {
		Same
	}
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

# An element's children are the nodes after the place its start left, copied
# into a list of their own when it ends, so every node is copied once.
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

w_declaration : Str
w_declaration = "xmlns:w='${wordprocessingml}'"

parse : Str -> XmlTree.Node
parse = |text| XmlTree.parse(text.to_utf8(), {}) ?? Text("unreadable")

## Dropped content is removed below the root, counted by kind, and a `_GoBack`
## bookmark's end goes with it while other bookmarks stay.
expect {
	body = "<w:p w:rsidR='00A1' w:rsidRDefault='00A1' w:val='1'><w:proofErr w:type='spellStart'/><w:bookmarkStart w:id='0' w:name='_GoBack'/><w:bookmarkStart w:id='1' w:name='keep'/><w:r><w:lastRenderedPageBreak/><w:t>a</w:t></w:r><w:bookmarkEnd w:id='0'/><w:bookmarkEnd w:id='1'/></w:p>"
	kept = drop(parse("<w:document ${w_declaration} w:rsidRoot='1'>${body}</w:document>"))
	expected = parse("<w:document ${w_declaration}><w:p w:val='1'><w:bookmarkStart w:id='1' w:name='keep'/><w:r><w:t>a</w:t></w:r><w:bookmarkEnd w:id='1'/></w:p></w:document>")
	counts = [{ content: RevisionSaveIds, count: 3 }, { content: RenderedPageBreaks, count: 1 }, { content: ProofingMarks, count: 1 }, { content: GoBackBookmark, count: 1 }]
	kept.tree == expected and kept.dropped == counts
}

## Prefixes, declarations, attribute order, whitespace between elements and
## dropped content do not make trees different.
expect {
	one = parse("<w:document ${w_declaration}>\n  <w:p w:a='1' w:b='2' w:rsidR='1'><w:proofErr/><w:r><w:t xml:space='preserve'> x </w:t></w:r></w:p>\n</w:document>")
	other = parse("<v:document xmlns:v='${wordprocessingml}'><v:p v:b='2' v:a='1'><v:r><v:t xml:space='preserve'> x </v:t></v:r></v:p></v:document>")
	Document.equivalent_xml(one, other)
}

## Text, attribute values and whitespace that `xml:space` preserves make
## trees different.
expect {
	base = parse("<w:document ${w_declaration}><w:p w:a='1'><w:t>a</w:t></w:p></w:document>")
	!Document.equivalent_xml(base, parse("<w:document ${w_declaration}><w:p w:a='1'><w:t>b</w:t></w:p></w:document>"))
		and !Document.equivalent_xml(base, parse("<w:document ${w_declaration}><w:p w:a='2'><w:t>a</w:t></w:p></w:document>"))
		and !Document.equivalent_xml(base, parse("<w:document ${w_declaration}><w:p w:a='1' xml:space='preserve'> <w:t>a</w:t></w:p></w:document>"))
		and !Document.equivalent_xml(base, parse("<w:document ${w_declaration}><w:p w:a='1'><w:t>a </w:t></w:p></w:document>"))
}

# A package of a main document with an extension, a style part and a picture.
sample : List(U8) -> Try(List(U8), Opc.WriteError)
sample = |picture| {
	relationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
	graph = {
		relationships: [{ id: "rId1", kind: Opc.officedocument_relationship, target: "/word/document.xml", mode: Internal }],
		parts: [
			{
				name: "/word/document.xml",
				content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml",
				relationships: [
					{ id: "rId1", kind: "${relationships}/styles", target: "/word/styles.xml", mode: Internal },
					{ id: "rId2", kind: "${relationships}/image", target: "/word/media/picture.png", mode: Internal },
				],
			},
			{ name: "/word/styles.xml", content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml", relationships: [] },
			{ name: "/word/media/picture.png", content_type: "image/png", relationships: [] },
		],
	}
	mc = "xmlns:mc='http://schemas.openxmlformats.org/markup-compatibility/2006' xmlns:x='urn:example:extension' mc:Ignorable='x'"
	document = "<w:document ${w_declaration} ${mc}><w:body><w:p w:rsidR='00A1' x:mark='1'><w:r><w:t>Hello</w:t></w:r></w:p></w:body></w:document>"
	Opc.to_bytes(
		graph,
		|name|
			if name == "/word/document.xml" {
				Bytes(document.to_utf8())
			} else if name == "/word/styles.xml" {
				Bytes("<w:styles ${w_declaration}/>".to_utf8())
			} else {
				Bytes(picture)
			},
	)
}

## A package read and written passes through equivalently, without its
## dropped content and with an extension namespace outside the prefix table,
## and writing twice gives the same bytes.
expect {
	picture = [0x89, 0x50, 0x4E, 0x47, 1, 2, 3]
	pkg = Opc.open(sample(picture)?, {})?
	read = Document.from_package(pkg, {})?
	written = Document.to_bytes(read.document)?
	again = Document.from_package(Opc.open(written, {})?, {})?
	document = Opc.part_bytes(Opc.open(written, {})?, "/word/document.xml")?
	extension = "xmlns:mc=\"http://schemas.openxmlformats.org/markup-compatibility/2006\" xmlns:x=\"urn:example:extension\" mc:Ignorable=\"x\""
	read.diagnostics == [Dropped({ part: "/word/document.xml", content: RevisionSaveIds, count: 1 })]
		and Document.equivalent(read.document, again.document)
		and Document.to_bytes(read.document) == Ok(written)
		and Document.to_bytes(again.document) == Ok(written)
		and Str.from_utf8(document) == Ok("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<w:document xmlns:w=\"${wordprocessingml}\" ${extension}><w:body><w:p x:mark=\"1\"><w:r><w:t>Hello</w:t></w:r></w:p></w:body></w:document>")
		and Opc.part_bytes(Opc.open(written, {})?, "/word/media/picture.png") == Ok(picture)
}

## A changed part makes documents different.
expect {
	read = Document.from_package(Opc.open(sample([1])?, {})?, {})?
	other = Document.from_package(Opc.open(sample([2])?, {})?, {})?
	Document.equivalent(read.document, read.document) and !Document.equivalent(read.document, other.document)
}
