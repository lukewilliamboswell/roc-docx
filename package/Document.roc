## A document as the package holds it, the typed model of its body, and what
## it means for two documents to be the same.
##
## A document is its package and the namespaced XML tree of each of its XML
## parts. Reading parses every XML part and drops the editor state the
## architecture's fidelity rules name, with a diagnostic; writing renders each
## tree in the canonical form of [XmlTree.render] and copies every other part
## exactly as its archive stored it. A document therefore holds the archive's
## bytes and the trees of its XML parts, and while it is read or written, one
## part's bytes beyond them.
##
## The body's model, [Document.Block] and what it holds, is read from the
## main document's tree by [Docx.body]. Until the model is written, the trees
## are what a document writes, so the model is a reading of them rather than
## a copy kept beside them.
import Limits
import Opc
import XmlTree

Document :: { pkg : Opc.Package, graph : Opc.Graph, trees : Dict(Str, XmlTree.Node) }.{

	## A block of the body, in reading order: a paragraph; a table; an
	## element the model does not represent whose content is still read as
	## blocks, kept without its children in `element` (a content control and
	## its content, custom XML); or any other element, kept whole as it was
	## read.
	Block := [
		Paragraph(Paragraph),
		Table(Table),
		Container({ element : XmlTree.Node, content : List(Block) }),
		Preserved(XmlTree.Node),
	].{

		## Compare two blocks structurally.
		is_eq : _
	}

	## A paragraph: its properties and its content in order.
	Paragraph : { properties : ParagraphProperties, content : List(Inline) }

	## A paragraph's properties. None is modelled yet: each property element
	## is kept as it was read, in order.
	ParagraphProperties : { preserved : List(XmlTree.Node) }

	## A paragraph's content, in order: a run; an element the model does not
	## represent whose content is still read as paragraph content, kept
	## without its children in `element` (a hyperlink, an inserted, deleted or
	## moved range, a simple field, a content control and its content, a smart
	## tag, custom XML, a bidirectional embedding); or any other element, such
	## as a bookmark or comment range boundary, kept whole in its place.
	Inline := [
		Run(Run),
		Container({ element : XmlTree.Node, content : List(Inline) }),
		Preserved(XmlTree.Node),
	].{

		## Compare two inlines structurally.
		is_eq : _
	}

	## A run: text with one set of character properties.
	Run : { properties : RunProperties, content : List(RunContent) }

	## A run's character properties. None is modelled yet: each property
	## element is kept as it was read, in order.
	RunProperties : { preserved : List(XmlTree.Node) }

	## What a run holds, in order: text; a tab; a line, page or column break,
	## a line break saying which floating objects the next line clears; a
	## symbol, a character `code` in a named `font`; a soft hyphen, shown only
	## where a line breaks; a hyphen at which a line never breaks; or any other
	## element, such as a note reference, a field character or a drawing, kept
	## whole in its place.
	RunContent : [
		Text(Str),
		Tab,
		Break({ kind : [Line, Page, Column], clear : [NoClear, Left, Right, All] }),
		Symbol({ font : Str, code : U16 }),
		SoftHyphen,
		NonBreakingHyphen,
		Preserved(XmlTree.Node),
	]

	## A table: its properties, its grid of columns, and its content in
	## order.
	Table : { properties : TableProperties, grid : List(GridColumn), content : List(TableContent) }

	## A table's properties as the table states them, without what its style
	## contributes: the identifier of its table style in the document's
	## styles, its preferred width, its borders and its shading. Every other
	## property element is kept as it was read, in order, and so is a
	## property element whose attributes the model cannot hold.
	TableProperties : { style : [Unset, Style(Str)], width : Width, borders : List(Border), shading : Shading, preserved : List(XmlTree.Node) }

	## A column of a table's grid, its width in twips; any other element of
	## the grid, such as a column without a width or a revision of the grid,
	## is kept in its place as it was read.
	GridColumn : [Column(U64), Preserved(XmlTree.Node)]

	## A table's content, in order: a row; an element the model does not
	## represent whose content is still read as rows, kept without its
	## children in `element` (a content control and its content, custom XML);
	## or any other element, such as a bookmark boundary, kept whole in its
	## place.
	TableContent := [
		Row(Row),
		Container({ element : XmlTree.Node, content : List(TableContent) }),
		Preserved(XmlTree.Node),
	].{

		## Compare two pieces of table content structurally.
		is_eq : _
	}

	## A row: its properties and its content in order.
	Row : { properties : RowProperties, content : List(RowContent) }

	## A row's properties: whether it is a header row, repeated at the top of
	## each page the table spans, and how many grid columns come before its
	## first cell and after its last. Every other property element is kept as
	## it was read, in order.
	RowProperties : { header : [Unset, On, Off], grid_before : [Unset, Columns(U64)], grid_after : [Unset, Columns(U64)], preserved : List(XmlTree.Node) }

	## A row's content, in order: a cell; an element the model does not
	## represent whose content is still read as cells, kept without its
	## children in `element` (a content control and its content, custom XML);
	## or any other element, such as the table property exceptions of the row
	## or a bookmark boundary, kept whole in its place.
	RowContent := [
		Cell(Cell),
		Container({ element : XmlTree.Node, content : List(RowContent) }),
		Preserved(XmlTree.Node),
	].{

		## Compare two pieces of row content structurally.
		is_eq : _
	}

	## A cell: its properties and its blocks, which may hold further tables.
	Cell : { properties : CellProperties, content : List(Block) }

	## A cell's properties: its preferred width, how many grid columns it
	## spans, whether it starts or continues a vertical merge with the cell
	## above, its borders, its shading and the vertical alignment of its
	## content. Every other property element is kept as it was read, in
	## order, and so is a property element whose attributes the model cannot
	## hold.
	CellProperties : {
		width : Width,
		span : [Unset, Columns(U64)],
		merge : [Unset, Restart, Continue],
		borders : List(Border),
		shading : Shading,
		alignment : [Unset, Top, Center, Bottom, Both],
		preserved : List(XmlTree.Node),
	}

	## A preferred width: automatic, zero, in twips, or a share of the
	## available width in fiftieths of a per cent.
	Width : [Unset, Auto, Nil, Twips(I64), Fiftieths(I64)]

	## One edge of a table's or cell's borders: the line, by its name in the
	## schema (`single`, `double`, `dotted`, `nil` and so on), its width in
	## eighths of a point, its distance from the content in points, and its
	## colour. `Left` and `Start`, `Right` and `End` are the two spellings
	## the schema has for the same edges.
	Border : {
		edge : [Top, Left, Start, Bottom, Right, End, InsideHorizontal, InsideVertical, DiagonalDown, DiagonalUp],
		line : Str,
		size : [Unset, Eighths(U64)],
		space : [Unset, Points(U64)],
		color : Color,
	}

	## A shading: its pattern, by its name in the schema (`clear`, `solid`,
	## `pct25` and so on), the pattern's colour and the fill behind it.
	Shading : [Unset, Shading({ pattern : Str, color : Color, fill : Color })]

	## A colour: automatic, or red, green and blue as six hexadecimal digits
	## as the document writes them.
	Color : [Unset, Auto, Rgb(Str)]

	## A paragraph's text as a reader sees it, revisions shown: every run's
	## text, inserted text included, and nothing from the content the model
	## keeps without reading, so deleted text, field instructions and note
	## references contribute none. A tab is a tab character, a break of any
	## kind a line feed, a symbol its character, a soft hyphen U+00AD and a
	## non-breaking hyphen U+2011.
	paragraph_text : Paragraph -> Str
	paragraph_text = |paragraph| {
		var $text = List.with_capacity(64)
		for inline in paragraph.content {
			$text = inline_text($text, inline)
		}
		Str.from_utf8($text) ?? ""
	}

	## A table's rows in order, through the content controls and custom XML
	## that hold them.
	table_rows : Table -> List(Row)
	table_rows = |table| table.content.fold(List.with_capacity(table.content.len()), rows_of)

	## A row's cells in order, through the content controls and custom XML
	## that hold them.
	row_cells : Row -> List(Cell)
	row_cells = |row| row.content.fold(List.with_capacity(row.content.len()), cells_of)

	## The tree of the main document part, the target of the package's
	## `officeDocument` relationship, as reading left it.
	main_document : Document -> Try(XmlTree.Node, [NoMainDocument])
	main_document = |document| {
		relationship = document.graph.relationships.find_first(|rel| rel.kind == Opc.officedocument_relationship and rel.mode == Internal) ? |_| NoMainDocument
		part = Opc.part(document.pkg, relationship.target) ? |_| NoMainDocument
		Ok(document.trees.get(part.name) ? |_| NoMainDocument)
	}

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

# An inline's text, as [Document.paragraph_text] defines it, appended as UTF-8.
inline_text : List(U8), Document.Inline -> List(U8)
inline_text = |text, inline|
	match inline {
		Run(run) => run.content.fold(text, run_content_text)
		Container({ element: _, content }) => content.fold(text, inline_text)
		Preserved(_) => text
	}

rows_of : List(Document.Row), Document.TableContent -> List(Document.Row)
rows_of = |rows, content|
	match content {
		Row(row) => List.append(rows, row)
		Container({ element: _, content: inner }) => inner.fold(rows, rows_of)
		Preserved(_) => rows
	}

cells_of : List(Document.Cell), Document.RowContent -> List(Document.Cell)
cells_of = |cells, content|
	match content {
		Cell(cell) => List.append(cells, cell)
		Container({ element: _, content: inner }) => inner.fold(cells, cells_of)
		Preserved(_) => cells
	}

run_content_text : List(U8), Document.RunContent -> List(U8)
run_content_text = |text, content|
	match content {
		Text(value) => List.concat(text, value.to_utf8())
		Tab => List.append(text, 9)
		Break(_) => List.append(text, 10)
		Symbol({ font: _, code }) => List.concat(text, utf8(code))
		SoftHyphen => List.concat(text, [0xC2, 0xAD])
		NonBreakingHyphen => List.concat(text, [0xE2, 0x80, 0x91])
		Preserved(_) => text
	}

# A character code as UTF-8; a surrogate, which is no character, is U+FFFD.
utf8 : U16 -> List(U8)
utf8 = |code|
	if code < 0x80 {
		[code.to_u8_wrap()]
	} else if code < 0x800 {
		[(0xC0 + code // 64).to_u8_wrap(), (0x80 + code % 64).to_u8_wrap()]
	} else if code >= 0xD800 and code < 0xE000 {
		[0xEF, 0xBF, 0xBD]
	} else {
		[(0xE0 + code // 4096).to_u8_wrap(), (0x80 + (code // 64) % 64).to_u8_wrap(), (0x80 + code % 64).to_u8_wrap()]
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

## A paragraph's text takes each kind of run content as its character, reads
## through containers, and skips preserved content.
expect {
	preserved = parse("<w:delText xmlns:w='${wordprocessingml}'>gone</w:delText>")
	run = |content| Run({ properties: { preserved: [] }, content })
	paragraph : Document.Paragraph
	paragraph = {
		properties: { preserved: [] },
		content: [
			run([Text("a"), Tab, Break({ kind: Line, clear: NoClear }), Break({ kind: Page, clear: NoClear }), Symbol({ font: "Symbol", code: 0x3B1 }), SoftHyphen, NonBreakingHyphen, Preserved(preserved)]),
			Container({ element: preserved, content: [run([Text("b"), Symbol({ font: "", code: 0xD800 }), Symbol({ font: "", code: 0x41 }), Symbol({ font: "Wingdings", code: 0xF0E0 })])] }),
			Preserved(preserved),
		],
	}
	Document.paragraph_text(paragraph) == "a\t\n\n\u(3B1)\u(AD)\u(2011)b\u(FFFD)A\u(F0E0)"
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
