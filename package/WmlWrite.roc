## The typed model written as WordprocessingML, the inverse of [WmlRead].
##
## Every modelled value is written in one canonical form: the elements of a
## property list in the order the schema's sequence gives them, each
## element's attributes in a fixed order, a property that is on as the
## element alone and one that is off with `w:val="0"`, numbers as whole
## decimal numbers, and text with `xml:space="preserve"` exactly where its
## whitespace would otherwise be read as layout. What the model keeps as it
## was read is written as it was: a `Preserved` node in its place among the
## modelled content, a container's element around its written content, and
## a property element in `preserved` at its place in the schema's order.
##
## What the model names by meaning is given its identifier here, as a
## deterministic function of the model and the part's relationships: a
## bookmark, a tracked change and a move's range its `w:id`, a note reference
## the identifier of its note, and a hyperlink, picture, header or footer the
## relationship that leads to its target, found among the part's
## relationships or added to them.
import Document
import Opc
import XmlTree

WmlWrite :: [].{

	## What writing a part needs from the rest of its package, as
	## [WmlRead.Context] gives reading it: the relationships whose source is
	## the part, the identifiers of the footnotes and of the endnotes in the
	## order of their parts, which a note reference's place indexes, and the
	## identifiers of the comments in the order of their part, which a
	## comment's range and reference index.
	Context : { relationships : List(Opc.Relationship), footnotes : List(Str), endnotes : List(Str), comments : List(Str) }

	## Why blocks cannot be written: a note reference names a note by a
	## place the document's footnotes or endnotes do not have, or a comment's
	## range or reference a comment by a place its comments do not have.
	WriteError : [MissingNote({ kind : Document.NoteKind, note : U64 }), MissingComment(U64)]

	## The tree of a main document part whose body holds `content`, and the
	## part's relationships with any it needs added. `shell` is the part as
	## it was read: its root's declarations, attributes and children other
	## than the body are kept, and the body's content is written from the
	## model, a body added after them when the root has none. A shell whose
	## root is not a WordprocessingML document is not a main document, and is
	## returned as it is.
	##
	## A section ends after the paragraph whose mark ends it, in that
	## paragraph's properties, except the body's last block, which is the
	## body's own section; in a table cell, and wherever no paragraph comes
	## before it, a section is written where it stands.
	##
	## Bookmark identifiers come from one space shared with the identifiers
	## of the comments and those the kept content uses, such as a paragraph
	## mark's revision: each bookmark takes the lowest number no kept element
	## and no earlier bookmark uses, in the order the bookmarks begin, and its
	## end takes its start's. Tracked changes and moves' ranges then take the
	## lowest numbers left, in the order they are written, a range's end its
	## start's. A comment's range and reference take its comment's identifier.
	##
	## A tracked change is written with its identifier, author, date as it
	## was written and the attributes it kept; in a deletion, text is
	## `w:delText` and a piece of field code `w:delInstrText`.
	## A relationship is reused when the part has one to the same
	## target in the same mode, of the kind the reference needs where the
	## reader asks for one; otherwise it is added as `rId` with the lowest
	## number from the count of relationships up that no relationship uses.
	document : XmlTree.Node, List(Document.Block), Context -> Try({ tree : XmlTree.Node, relationships : List(Opc.Relationship) }, WriteError)
	document = |shell, content, context| {
		root = match shell {
			Element(element) if is_w(element.name, "document") => element
			_ => return Ok({ tree: shell, relationships: context.relationships })
		}
		var $state = initial(content, context)?
		var $children = List.with_capacity(root.children.len() + 1)
		var $written = Bool.False
		for child in root.children {
			match child {
				Element(body) if !$written and is_w(body.name, "body") => {
					out = blocks(content, Body, $state)
					node : XmlTree.Node
					node = Element({ name: body.name, bindings: body.bindings, attributes: body.attributes, children: out.nodes })
					$children = List.append($children, node)
					$state = out.state
					$written = Bool.True
				}

				_ => {
					$children = List.append($children, child)
				}
			}
		}
		if !$written {
			out = blocks(content, Body, $state)
			$children = List.append($children, element("body", [], out.nodes))
			$state = out.state
		}
		tree : XmlTree.Node
		tree = Element({ name: root.name, bindings: root.bindings, attributes: root.attributes, children: $children })
		Ok({ tree, relationships: $state.relationships })
	}
}

# What writing carries from one piece of content to the next: the part's
# relationships so far, the notes' identifiers, each modelled bookmark
# name's identifier and each kept bookmark start's, the names whose start is written, the identifiers kept
# content uses and the lowest identifier a further bookmark may take; the
# identifiers of the moves' source and destination ranges begun, by name;
# and whether what is written is deleted content.
State : {
	relationships : List(Opc.Relationship),
	footnotes : List(Str),
	endnotes : List(Str),
	comments : List(Str),
	bookmarks : Dict(Str, Str),
	kept_bookmarks : Dict(Str, Str),
	started : Set(Str),
	used : Set(Str),
	next : U64,
	move_sources : Dict(Str, Str),
	move_destinations : Dict(Str, Str),
	deleted : Bool,
}

# Written content and the state after it.
Out : { nodes : List(XmlTree.Node), state : State }

Written : { node : XmlTree.Node, state : State }

# Where blocks stand: the body, whose last section is its own; other content
# read as the body's is, such as a content control's; or a table cell, read
# block by block.
Mode : [Body, Flow, Cell]

# What a walk over the model finds before writing: the identifiers kept
# content uses, the names of kept bookmark starts by identifier, the names of
# the modelled bookmark starts in order, and the first note reference that
# names no note.
Scan : { used : Set(Str), named : Dict(Str, Str), starts : List(Str), missing : Try({}, WmlWrite.WriteError) }

initial : List(Document.Block), WmlWrite.Context -> Try(State, WmlWrite.WriteError)
initial = |content, context| {
	empty = { used: Set.with_capacity(8), named: Dict.with_capacity(0), starts: List.with_capacity(8), missing: Ok({}) }
	scan = content.fold(empty, |found, block| scan_block(context, found, block))
	scan.missing?
	var $bookmarks = Dict.with_capacity(scan.starts.len() + scan.named.len())
	var $next = 0.U64
	for name in scan.starts {
		if $bookmarks.get(name).is_err() {
			id = free_id(scan.used, $next)
			$bookmarks = $bookmarks.insert(name, id.to_str())
			$next = id + 1
		}
	}
	Ok({ relationships: context.relationships, footnotes: context.footnotes, endnotes: context.endnotes, comments: context.comments, bookmarks: $bookmarks, kept_bookmarks: scan.named, started: Set.with_capacity(scan.starts.len()), used: scan.used, next: $next, move_sources: Dict.with_capacity(0), move_destinations: Dict.with_capacity(0), deleted: Bool.False })
}

# The lowest identifier from `from` up that no kept content uses.
free_id : Set(Str), U64 -> U64
free_id = |used, from| {
	var $id = from
	while used.contains($id.to_str()) {
		$id = $id + 1
	}
	$id
}

scan_block : WmlWrite.Context, Scan, Document.Block -> Scan
scan_block = |context, scan, block|
	match block {
		Paragraph(paragraph) => paragraph.content.fold(scan_nodes(scan, paragraph.properties.preserved), |found, item| scan_inline(context, found, item))
		Table(table) => {
			grid = table.grid.fold(
				scan_nodes(scan, table.properties.preserved),
				|found, column|
					match column {
						Column(_) => found
						Preserved(node) => scan_node(found, node)
					},
			)
			table.content.fold(grid, |found, item| scan_table_content(context, found, item))
		}

		Section(section) => scan_nodes(scan, section.preserved)
		CommentStart(place) => scan_comment(context, scan, place)
		CommentEnd(place) => scan_comment(context, scan, place)
		Container({ element: node, content }) => content.fold(scan_node(scan, node), |found, item| scan_block(context, found, item))
		Preserved(node) => scan_node(scan, node)
	}

scan_table_content : WmlWrite.Context, Scan, Document.TableContent -> Scan
scan_table_content = |context, scan, item|
	match item {
		Row(row) => row.content.fold(scan_nodes(scan, row.properties.preserved), |found, inner| scan_row_content(context, found, inner))
		CommentStart(place) => scan_comment(context, scan, place)
		CommentEnd(place) => scan_comment(context, scan, place)
		Container({ element: node, content }) => content.fold(scan_node(scan, node), |found, inner| scan_table_content(context, found, inner))
		Preserved(node) => scan_node(scan, node)
	}

scan_row_content : WmlWrite.Context, Scan, Document.RowContent -> Scan
scan_row_content = |context, scan, item|
	match item {
		Cell(cell) => cell.content.fold(scan_nodes(scan, cell.properties.preserved), |found, block| scan_block(context, found, block))
		CommentStart(place) => scan_comment(context, scan, place)
		CommentEnd(place) => scan_comment(context, scan, place)
		Container({ element: node, content }) => content.fold(scan_node(scan, node), |found, inner| scan_row_content(context, found, inner))
		Preserved(node) => scan_node(scan, node)
	}

scan_inline : WmlWrite.Context, Scan, Document.Inline -> Scan
scan_inline = |context, scan, item|
	match item {
		Run(run) => run.content.fold(scan_nodes(scan, run.properties.preserved), |found, content| scan_run_content(context, found, content))
		Hyperlink({ target: _, preserved: _, content }) => content.fold(scan, |found, inner| scan_inline(context, found, inner))
		SimpleField({ code: _, preserved: _, content }) => content.fold(scan, |found, inner| scan_inline(context, found, inner))
		BookmarkStart(name) => { ..scan, starts: List.append(scan.starts, name) }
		BookmarkEnd(_) => scan
		CommentStart(place) => scan_comment(context, scan, place)
		CommentEnd(place) => scan_comment(context, scan, place)
		Container({ element: node, content }) => content.fold(scan_node(scan, node), |found, inner| scan_inline(context, found, inner))
		Revision({ kind: _, author: _, date: _, content, preserved: _ }) => content.fold(scan, |found, inner| scan_inline(context, found, inner))
		MoveStart(_) => scan
		MoveEnd(_) => scan
		Preserved(node) => scan_node(scan, node)
	}

scan_run_content : WmlWrite.Context, Scan, Document.RunContent -> Scan
scan_run_content = |context, scan, content|
	match content {
		NoteReference({ kind, note }) => {
			ids = match kind {
				Footnote => context.footnotes
				Endnote => context.endnotes
			}
			if ids.get(note).is_ok() or scan.missing.is_err() {
				scan
			} else {
				{ ..scan, missing: Err(MissingNote({ kind, note })) }
			}
		}

		CommentReference(place) => scan_comment(context, scan, place)
		FieldMark({ kind: _, element: node }) => scan_node(scan, node)
		Preserved(node) => scan_node(scan, node)
		_ => scan
	}

# A comment's identifier is in use, or the comment is missing.
scan_comment : WmlWrite.Context, Scan, U64 -> Scan
scan_comment = |context, scan, place|
	match context.comments.get(place) {
		Ok(id) => { ..scan, used: scan.used.insert(id) }
		Err(_) => if (scan.missing.is_err()) scan else { ..scan, missing: Err(MissingComment(place)) }
	}

scan_nodes : Scan, List(XmlTree.Node) -> Scan
scan_nodes = |scan, nodes| nodes.fold(scan, scan_node)

# The identifiers a kept element and its content use, and the names of the
# bookmarks they begin. Local names are compared first, as comparing a
# namespace allocates.
scan_node : Scan, XmlTree.Node -> Scan
scan_node = |scan, node|
	match node {
		Element(kept) => {
			id = kept.attributes.find_first(|attribute| attribute.name.local == "id" and attribute.name.namespace == Uri(wordprocessingml))
			used = match id {
				Ok(attribute) => { ..scan, used: scan.used.insert(attribute.value) }
				Err(_) => scan
			}
			named = match (id, kept.name.local == "bookmarkStart" and is_w(kept.name, "bookmarkStart")) {
				(Ok(attribute), Bool.True) =>
					match kept.attributes.find_first(|candidate| candidate.name.local == "name" and candidate.name.namespace == Uri(wordprocessingml)) {
						Ok(name) if used.named.get(name.value).is_err() => { ..used, named: used.named.insert(name.value, attribute.value) }
						_ => used
					}

				_ => used
			}
			kept.children.fold(named, scan_node)
		}

		Text(_) => scan
	}

# Blocks in order. In the body and content read as the body's, a section
# after a paragraph goes into that paragraph's properties, unless it is the
# body's last block.
blocks : List(Document.Block), Mode, State -> Out
blocks = |content, mode, state| {
	var $nodes = List.with_capacity(content.len())
	var $state = state
	var $index = 0.U64
	while $index < content.len() {
		match content.get($index) {
			Ok(Paragraph(paragraph)) => {
				ending = match (mode, content.get($index + 1)) {
					(Cell, _) => Err(NoSection)
					(Body, Ok(Section(_))) if $index + 2 == content.len() => Err(NoSection)
					(_, Ok(Section(section))) => Ok(section)
					_ => Err(NoSection)
				}
				written = paragraph_node(paragraph, ending, $state)
				$nodes = List.append($nodes, written.node)
				$state = written.state
				$index = $index + (if (ending.is_ok()) 2 else 1)
			}

			Ok(Table(table)) => {
				written = table_node(table, $state)
				$nodes = List.append($nodes, written.node)
				$state = written.state
				$index = $index + 1
			}

			Ok(Section(section)) => {
				written = section_node(section, $state)
				$nodes = List.append($nodes, written.node)
				$state = written.state
				$index = $index + 1
			}

			Ok(CommentStart(place)) => {
				$nodes = List.append($nodes, comment_node("commentRangeStart", place, $state))
				$index = $index + 1
			}

			Ok(CommentEnd(place)) => {
				$nodes = List.append($nodes, comment_node("commentRangeEnd", place, $state))
				$index = $index + 1
			}

			Ok(Container({ element: kept, content: inner })) => {
				out = blocks(inner, if (mode == Cell) Cell else Flow, $state)
				$nodes = List.append($nodes, with_children(kept, out.nodes))
				$state = out.state
				$index = $index + 1
			}

			Ok(Preserved(node)) => {
				$nodes = List.append($nodes, node)
				$index = $index + 1
			}

			Err(_) => {
				$index = $index + 1
			}
		}
	}
	{ nodes: $nodes, state: $state }
}

paragraph_node : Document.Paragraph, Try(Document.Section, [NoSection]), State -> Written
paragraph_node = |paragraph, ending, state| {
	typed = paragraph_properties(paragraph.properties)
	with_section = match ending {
		Ok(section) => {
			written = section_node(section, state)
			{ typed: List.append(typed, written.node), state: written.state }
		}

		Err(NoSection) => { typed, state }
	}
	properties = ordered(paragraph_order, with_section.typed, paragraph.properties.preserved)
	out = paragraph.content.fold({ nodes: List.with_capacity(paragraph.content.len() + 1), state: with_section.state }, inline)
	nodes = if (properties.is_empty()) out.nodes else List.prepend(out.nodes, element("pPr", [], properties))
	{ node: element("p", [], nodes), state: out.state }
}

inline : Out, Document.Inline -> Out
inline = |out, item|
	match item {
		Run(run) => {
			written = run_node(run, out.state)
			{ nodes: List.append(out.nodes, written.node), state: written.state }
		}

		Hyperlink({ target, preserved, content }) => {
			linked = match target {
				External(url) => {
					found = external(out.state, url)
					{ attributes: [relationship_attribute("id", found.id)], state: found.state }
				}

				ExternalAt({ url, location }) => {
					found = external(out.state, url)
					{ attributes: [relationship_attribute("id", found.id), attribute("anchor", location)], state: found.state }
				}

				Internal(name) => { attributes: [attribute("anchor", name)], state: out.state }
			}
			inner = content.fold({ nodes: List.with_capacity(content.len()), state: linked.state }, inline)
			{ nodes: List.append(out.nodes, element("hyperlink", List.concat(linked.attributes, preserved), inner.nodes)), state: inner.state }
		}

		SimpleField({ code, preserved, content }) => {
			inner = content.fold({ nodes: List.with_capacity(content.len()), state: out.state }, inline)
			{ nodes: List.append(out.nodes, element("fldSimple", List.prepend(preserved, attribute("instr", code)), inner.nodes)), state: inner.state }
		}

		BookmarkStart(name) => {
			state = out.state
			begun = if state.started.contains(name) {
				id = free_id(state.used, state.next)
				{ id: id.to_str(), state: { ..state, next: id + 1 } }
			} else {
				{ id: state.bookmarks.get(name) ?? "0", state: { ..state, started: state.started.insert(name) } }
			}
			{ nodes: List.append(out.nodes, element("bookmarkStart", [attribute("id", begun.id), attribute("name", name)], [])), state: begun.state }
		}

		BookmarkEnd(name) => {
			state = out.state
			ended = match (state.bookmarks.get(name), state.kept_bookmarks.get(name)) {
				(Ok(id), _) | (Err(_), Ok(id)) => { id, state }
				_ => {
					id = free_id(state.used, state.next)
					{ id: id.to_str(), state: { ..state, next: id + 1 } }
				}
			}
			{ nodes: List.append(out.nodes, element("bookmarkEnd", [attribute("id", ended.id)], [])), state: ended.state }
		}

		CommentStart(place) => { ..out, nodes: List.append(out.nodes, comment_node("commentRangeStart", place, out.state)) }
		CommentEnd(place) => { ..out, nodes: List.append(out.nodes, comment_node("commentRangeEnd", place, out.state)) }
		Container({ element: kept, content }) => {
			inner = content.fold({ nodes: List.with_capacity(content.len()), state: out.state }, inline)
			{ nodes: List.append(out.nodes, with_children(kept, inner.nodes)), state: inner.state }
		}

		Revision({ kind, author, date, content, preserved }) => {
			local = match kind {
				Insertion => "ins"
				Deletion => "del"
				MoveSource => "moveFrom"
				MoveDestination => "moveTo"
			}
			numbered = fresh_id(out.state)
			outer = numbered.state.deleted
			inner = content.fold({ nodes: List.with_capacity(content.len()), state: { ..numbered.state, deleted: outer or kind == Deletion } }, inline)
			attributes = List.concat([attribute("id", numbered.id), attribute("author", author)], List.concat(date_attribute(date), preserved))
			{ nodes: List.append(out.nodes, element(local, attributes, inner.nodes)), state: { ..inner.state, deleted: outer } }
		}

		MoveStart({ side, name, author, date, preserved }) => {
			numbered = fresh_id(out.state)
			(local, state) = match side {
				Source => ("moveFromRangeStart", { ..numbered.state, move_sources: numbered.state.move_sources.insert(name, numbered.id) })
				Destination => ("moveToRangeStart", { ..numbered.state, move_destinations: numbered.state.move_destinations.insert(name, numbered.id) })
			}
			attributes = List.concat([attribute("id", numbered.id), attribute("name", name), attribute("author", author)], List.concat(date_attribute(date), preserved))
			{ nodes: List.append(out.nodes, element(local, attributes, [])), state }
		}

		MoveEnd({ side, name }) => {
			(local, begun) = match side {
				Source => ("moveFromRangeEnd", out.state.move_sources.get(name))
				Destination => ("moveToRangeEnd", out.state.move_destinations.get(name))
			}
			ended = match begun {
				Ok(id) => { id, state: out.state }
				Err(_) => fresh_id(out.state)
			}
			{ nodes: List.append(out.nodes, element(local, [attribute("id", ended.id)], [])), state: ended.state }
		}

		Preserved(node) => { ..out, nodes: List.append(out.nodes, node) }
	}

# The lowest identifier no kept content and nothing written before uses.
fresh_id : State -> { id : Str, state : State }
fresh_id = |state| {
	id = free_id(state.used, state.next)
	{ id: id.to_str(), state: { ..state, next: id + 1 } }
}

# A tracked change's date as it was written, when it has one.
date_attribute : [Unset, Date(Document.Timestamp)] -> List(XmlTree.Attribute)
date_attribute = |date|
	match date {
		Date(stamp) => [attribute("date", stamp.written)]
		Unset => []
	}

run_node : Document.Run, State -> Written
run_node = |run, state| {
	properties = ordered(run_order, run_properties(run.properties), run.properties.preserved)
	start = if (properties.is_empty()) List.with_capacity(run.content.len()) else List.append(List.with_capacity(run.content.len() + 1), element("rPr", [], properties))
	out = run.content.fold({ nodes: start, state }, run_content)
	{ node: element("r", [], out.nodes), state: out.state }
}

run_content : Out, Document.RunContent -> Out
run_content = |out, content|
	match content {
		Picture({ media, size, drawing }) => {
			found = related(out.state, image_relationship, media, Internal, |relationship| relationship.mode == Internal and relationship.target == media)
			{ nodes: List.append(out.nodes, sized_drawing(drawing, size, found.id)), state: found.state }
		}

		NoteReference({ kind, note }) => {
			(local, ids) = match kind {
				Footnote => ("footnoteReference", out.state.footnotes)
				Endnote => ("endnoteReference", out.state.endnotes)
			}
			{ ..out, nodes: List.append(out.nodes, element(local, [attribute("id", ids.get(note) ?? "")], [])) }
		}

		CommentReference(place) => { ..out, nodes: List.append(out.nodes, comment_node("commentReference", place, out.state)) }
		Text(value) if out.state.deleted => { ..out, nodes: List.append(out.nodes, text_element("delText", value)) }
		FieldCode(code) if out.state.deleted => { ..out, nodes: List.append(out.nodes, text_element("delInstrText", code)) }
		_ => { ..out, nodes: List.append(out.nodes, plain_content(content)) }
	}

# A comment's range boundary or reference, by its comment's identifier.
comment_node : Str, U64, State -> XmlTree.Node
comment_node = |local, place, state| element(local, [attribute("id", state.comments.get(place) ?? "")], [])

# Run content that needs nothing from the rest of the part.
plain_content : Document.RunContent -> XmlTree.Node
plain_content = |content|
	match content {
		Text(value) => text_element("t", value)
		Tab => element("tab", [], [])
		Break({ kind, clear }) => {
			kind_attributes = match kind {
				Line => []
				Page => [attribute("type", "page")]
				Column => [attribute("type", "column")]
			}
			clear_attributes = match clear {
				NoClear => []
				Left => [attribute("clear", "left")]
				Right => [attribute("clear", "right")]
				All => [attribute("clear", "all")]
			}
			element("br", List.concat(kind_attributes, clear_attributes), [])
		}

		Symbol({ font, code }) => {
			font_attributes = if (font == "") [] else [attribute("font", font)]
			element("sym", List.append(font_attributes, attribute("char", hex4(code))), [])
		}

		SoftHyphen => element("softHyphen", [], [])
		NonBreakingHyphen => element("noBreakHyphen", [], [])
		NoteMark(Footnote) => element("footnoteRef", [], [])
		NoteMark(Endnote) => element("endnoteRef", [], [])
		FieldMark({ kind: _, element: node }) => node
		FieldCode(code) => text_element("instrText", code)
		Preserved(node) => node
		NoteReference(_) => Text("")
		CommentReference(_) => Text("")
		Picture({ media: _, size: _, drawing }) => drawing
	}

# Text in `w:t`, `w:instrText` or their deleted forms, said to keep its
# whitespace exactly when reading would otherwise take some of it as layout.
text_element : Str, Str -> XmlTree.Node
text_element = |local, value| {
	bytes = value.to_utf8()
	space = |byte| byte == 32 or byte == 9 or byte == 10 or byte == 13
	preserve = bytes.first().map_ok(space) == Ok(Bool.True)
		or bytes.last().map_ok(space) == Ok(Bool.True)
		or bytes.any(|byte| byte == 9 or byte == 10 or byte == 13)
	attributes = if (preserve) [{ name: { namespace: Uri(xml_namespace), local: "space", prefix: Prefix("xml") }, value: "preserve" }] else []
	element(local, attributes, if (value == "") [] else [Text(value)])
}

# A character code as four hexadecimal digits.
hex4 : U16 -> Str
hex4 = |code| {
	digits = "0123456789ABCDEF".to_utf8()
	digit = |shift| digits.get(((code // shift) % 16).to_u64()) ?? '0'
	Str.from_utf8([digit(4096), digit(256), digit(16), digit(1)]) ?? "0000"
}

# An inline picture's drawing with its extent and its image's relationship
# as the model has them: the first `wp:extent` of its `wp:inline` takes the
# size, and the first `a:blip` in it embeds the relationship.
sized_drawing : XmlTree.Node, { width : U64, height : U64 }, Str -> XmlTree.Node
sized_drawing = |drawing, size, id|
	match drawing {
		Element(outer) => {
			children = outer.children.map(
				|child|
					match child {
						Element(placed) if placed.name.local == "inline" and placed.name.namespace == Uri(drawing_namespace) => {
							var $sized = List.with_capacity(placed.children.len())
							var $done = Bool.False
							for inner in placed.children {
								match inner {
									Element(extent) if !$done and extent.name.local == "extent" and extent.name.namespace == Uri(drawing_namespace) => {
										attributes = with_attribute(with_attribute(extent.attributes, unqualified("cx"), size.width.to_str()), unqualified("cy"), size.height.to_str())
										$sized = List.append($sized, Element({ name: extent.name, bindings: extent.bindings, attributes, children: extent.children }))
										$done = Bool.True
									}

									_ => {
										$sized = List.append($sized, inner)
									}
								}
							}
							embedded = with_embed(Element({ name: placed.name, bindings: placed.bindings, attributes: placed.attributes, children: $sized }), id)
							embedded.node
						}

						_ => child
					},
			)
			Element({ name: outer.name, bindings: outer.bindings, attributes: outer.attributes, children })
		}

		Text(_) => drawing
	}

# A tree whose first `a:blip` embeds the relationship `id`.
with_embed : XmlTree.Node, Str -> { node : XmlTree.Node, done : Bool }
with_embed = |node, id|
	match node {
		Element(blip) if blip.name.local == "blip" and blip.name.namespace == Uri(drawingml) => {
			embedded : XmlTree.Node
			embedded = Element({ name: blip.name, bindings: blip.bindings, attributes: with_attribute(blip.attributes, relationship_name("embed"), id), children: blip.children })
			{ node: embedded, done: Bool.True }
		}

		Element(parent) => {
			var $children = List.with_capacity(parent.children.len())
			var $done = Bool.False
			for child in parent.children {
				if $done {
					$children = List.append($children, child)
				} else {
					inner = with_embed(child, id)
					$children = List.append($children, inner.node)
					$done = inner.done
				}
			}
			rebuilt : XmlTree.Node
			rebuilt = Element({ name: parent.name, bindings: parent.bindings, attributes: parent.attributes, children: $children })
			{ node: rebuilt, done: $done }
		}

		Text(_) => { node, done: Bool.False }
	}

# Attributes with `name` set to `value`, in its place if it is there and
# last if it is not.
with_attribute : List(XmlTree.Attribute), XmlTree.Name, Str -> List(XmlTree.Attribute)
with_attribute = |attributes, name, value|
	if attributes.any(|existing| existing.name.local == name.local and existing.name.namespace == name.namespace) {
		attributes.map(|existing| if (existing.name.local == name.local and existing.name.namespace == name.namespace) { name: existing.name, value } else existing)
	} else {
		List.append(attributes, { name, value })
	}

table_node : Document.Table, State -> Written
table_node = |table, state| {
	properties = element("tblPr", [], ordered(table_order, table_properties(table.properties), table.properties.preserved))
	grid = element(
		"tblGrid",
		[],
		table.grid.map(
			|column|
				match column {
					Column(width) => element("gridCol", [attribute("w", width.to_str())], [])
					Preserved(node) => node
				},
		),
	)
	out = table.content.fold({ nodes: List.concat([properties, grid], List.with_capacity(table.content.len())), state }, table_content)
	{ node: element("tbl", [], out.nodes), state: out.state }
}

table_content : Out, Document.TableContent -> Out
table_content = |out, item|
	match item {
		Row(row) => {
			written = row_node(row, out.state)
			{ nodes: List.append(out.nodes, written.node), state: written.state }
		}

		CommentStart(place) => { ..out, nodes: List.append(out.nodes, comment_node("commentRangeStart", place, out.state)) }
		CommentEnd(place) => { ..out, nodes: List.append(out.nodes, comment_node("commentRangeEnd", place, out.state)) }
		Container({ element: kept, content }) => {
			inner = content.fold({ nodes: List.with_capacity(content.len()), state: out.state }, table_content)
			{ nodes: List.append(out.nodes, with_children(kept, inner.nodes)), state: inner.state }
		}

		Preserved(node) => { ..out, nodes: List.append(out.nodes, node) }
	}

# A row: the table property exceptions it begins with, which the schema puts
# before its properties, then its properties and the rest of its content.
row_node : Document.Row, State -> Written
row_node = |row, state| {
	var $leading = 0.U64
	var $exceptions = List.with_capacity(1)
	var $leading_done = Bool.False
	for item in row.content {
		if !$leading_done {
			match item {
				Preserved(Element(exceptions)) if exceptions.name.local == "tblPrEx" and is_w(exceptions.name, "tblPrEx") => {
					$exceptions = List.append($exceptions, Element(exceptions))
					$leading = $leading + 1
				}

				_ => {
					$leading_done = Bool.True
				}
			}
		}
	}
	properties = ordered(row_order, row_properties(row.properties), row.properties.preserved)
	start = if (properties.is_empty()) $exceptions else List.append($exceptions, element("trPr", [], properties))
	rest = List.drop_first(row.content, $leading)
	out = rest.fold({ nodes: List.concat(start, List.with_capacity(rest.len())), state }, row_content)
	{ node: element("tr", [], out.nodes), state: out.state }
}

row_content : Out, Document.RowContent -> Out
row_content = |out, item|
	match item {
		Cell(cell) => {
			properties = ordered(cell_order, cell_properties(cell.properties), cell.properties.preserved)
			inner = blocks(cell.content, Cell, out.state)
			nodes = if (properties.is_empty()) inner.nodes else List.prepend(inner.nodes, element("tcPr", [], properties))
			{ nodes: List.append(out.nodes, element("tc", [], nodes)), state: inner.state }
		}

		CommentStart(place) => { ..out, nodes: List.append(out.nodes, comment_node("commentRangeStart", place, out.state)) }
		CommentEnd(place) => { ..out, nodes: List.append(out.nodes, comment_node("commentRangeEnd", place, out.state)) }
		Container({ element: kept, content }) => {
			inner = content.fold({ nodes: List.with_capacity(content.len()), state: out.state }, row_content)
			{ nodes: List.append(out.nodes, with_children(kept, inner.nodes)), state: inner.state }
		}

		Preserved(node) => { ..out, nodes: List.append(out.nodes, node) }
	}

section_node : Document.Section, State -> Written
section_node = |section, state| {
	headers = references("headerReference", header_relationship, section.headers, state)
	footers = references("footerReference", footer_relationship, section.footers, headers.state)
	typed = List.join([headers.nodes, footers.nodes, section_properties(section)])
	{ node: element("sectPr", [], ordered(section_order, typed, section.preserved)), state: footers.state }
}

# References to headers or footers, each through a relationship of `kind`
# to its part.
references : Str, Str, List(Document.HeaderFooter), State -> Out
references = |local, kind, listed, state|
	listed.fold(
		{ nodes: List.with_capacity(listed.len()), state },
		|out, reference| {
			found = related(out.state, kind, reference.part, Internal, |relationship| relationship.mode == Internal and relationship.kind == kind and relationship.target == reference.part)
			which = match reference.kind {
				Default => "default"
				First => "first"
				Even => "even"
			}
			{ nodes: List.append(out.nodes, element(local, [attribute("type", which), relationship_attribute("id", found.id)], [])), state: found.state }
		},
	)

# The relationship to an address outside the package.
external : State, Str -> { id : Str, state : State }
external = |state, url| related(state, hyperlink_relationship, url, External, |relationship| relationship.mode == External and relationship.target == url)

# The first of the part's relationships `accepts` takes, or one added of
# `kind` to `target`.
related : State, Str, Str, [Internal, External], (Opc.Relationship -> Bool) -> { id : Str, state : State }
related = |state, kind, target, mode, accepts|
	match state.relationships.find_first(accepts) {
		Ok(found) => { id: found.id, state }
		Err(_) => {
			var $number = state.relationships.len() + 1
			while state.relationships.any(|relationship| relationship.id == "rId${$number.to_str()}") {
				$number = $number + 1
			}
			id = "rId${$number.to_str()}"
			{ id, state: { ..state, relationships: List.append(state.relationships, { id, kind, target, mode }) } }
		}
	}

# A container's element around its written content.
with_children : XmlTree.Node, List(XmlTree.Node) -> XmlTree.Node
with_children = |kept, children|
	match kept {
		Element(container) => Element({ name: container.name, bindings: container.bindings, attributes: container.attributes, children })
		Text(_) => kept
	}

# Property elements in the order of the schema's sequence `order`: modelled
# ones, which come in that order, first where both kinds share a place, kept
# ones in the order they were read. A kept element the sequence does not
# name, such as an extension, stays after the kept element before it.
ordered : List(Str), List(XmlTree.Node), List(XmlTree.Node) -> List(XmlTree.Node)
ordered = |order, typed, preserved| {
	if preserved.is_empty() {
		return typed
	}
	var $entries = List.with_capacity(typed.len() + preserved.len())
	var $seq = 0.U64
	for node in typed {
		$entries = List.append($entries, { rank: rank(order, node) ?? 0, seq: $seq, node })
		$seq = $seq + 1
	}
	var $previous = 0.U64
	for node in preserved {
		$previous = rank(order, node) ?? $previous
		$entries = List.append($entries, { rank: $previous, seq: $seq, node })
		$seq = $seq + 1
	}
	$entries
		.sort_with(|a, b| if (a.rank < b.rank or (a.rank == b.rank and a.seq < b.seq)) Before else if (a.rank == b.rank and a.seq == b.seq) Same else After)
		.map(|entry| entry.node)
}

# A WordprocessingML element's place in a sequence; a header and a footer
# reference share theirs.
rank : List(Str), XmlTree.Node -> Try(U64, [NotInSequence])
rank = |order, node|
	match node {
		Element(found) => {
			local = if (found.name.local == "footerReference") "headerReference" else found.name.local
			var $index = 0.U64
			for name in order {
				if name == local {
					return if (found.name.namespace == Uri(wordprocessingml)) Ok($index) else Err(NotInSequence)
				}
				$index = $index + 1
			}
			Err(NotInSequence)
		}

		Text(_) => Err(NotInSequence)
	}

paragraph_order : List(Str)
paragraph_order = ["pStyle", "keepNext", "keepLines", "pageBreakBefore", "framePr", "widowControl", "numPr", "suppressLineNumbers", "pBdr", "shd", "tabs", "suppressAutoHyphens", "kinsoku", "wordWrap", "overflowPunct", "topLinePunct", "autoSpaceDE", "autoSpaceDN", "bidi", "adjustRightInd", "snapToGrid", "spacing", "ind", "contextualSpacing", "mirrorIndents", "suppressOverlap", "jc", "textDirection", "textAlignment", "textboxTightWrap", "outlineLvl", "divId", "cnfStyle", "rPr", "sectPr", "pPrChange"]

run_order : List(Str)
run_order = ["rStyle", "rFonts", "b", "bCs", "i", "iCs", "caps", "smallCaps", "strike", "dstrike", "outline", "shadow", "emboss", "imprint", "noProof", "snapToGrid", "vanish", "webHidden", "color", "spacing", "w", "kern", "position", "sz", "szCs", "highlight", "u", "effect", "bdr", "shd", "fitText", "vertAlign", "rtl", "cs", "em", "lang", "eastAsianLayout", "specVanish", "oMath", "rPrChange"]

table_order : List(Str)
table_order = ["tblStyle", "tblpPr", "tblOverlap", "bidiVisual", "tblStyleRowBandSize", "tblStyleColBandSize", "tblW", "jc", "tblCellSpacing", "tblInd", "tblBorders", "shd", "tblLayout", "tblCellMar", "tblLook", "tblCaption", "tblDescription", "tblPrChange"]

row_order : List(Str)
row_order = ["cnfStyle", "divId", "gridBefore", "gridAfter", "wBefore", "wAfter", "cantSplit", "trHeight", "tblHeader", "tblCellSpacing", "jc", "hidden", "ins", "del", "trPrChange"]

cell_order : List(Str)
cell_order = ["cnfStyle", "tcW", "gridSpan", "hMerge", "vMerge", "tcBorders", "shd", "noWrap", "tcMar", "textDirection", "tcFitText", "vAlign", "hideMark", "headers", "cellIns", "cellDel", "cellMerge", "tcPrChange"]

section_order : List(Str)
section_order = ["headerReference", "footnotePr", "endnotePr", "type", "pgSz", "pgMar", "paperSrc", "pgBorders", "lnNumType", "pgNumType", "cols", "formProt", "vAlign", "noEndnote", "titlePg", "textDirection", "bidi", "rtlGutter", "docGrid", "printerSettings", "sectPrChange"]

# The edges of borders in the schema's order, which is the order of every
# borders element that has them.
edge_order : List(Str)
edge_order = ["top", "start", "left", "bottom", "end", "right", "insideH", "insideV", "tl2br", "tr2bl", "between", "bar"]

paragraph_properties : Document.ParagraphProperties -> List(XmlTree.Node)
paragraph_properties = |properties| {
	numbering = List.concat(
		match properties.numbering.level {
			Level(level) => [value("ilvl", level.to_str())]
			Unset => []
		},
		match properties.numbering.instance {
			Instance(instance) => [value("numId", instance.to_str())]
			Unset => []
		},
	)
	indentation = List.join([
		signed_twips("left", properties.indentation.left),
		signed_twips("right", properties.indentation.right),
		match properties.indentation.first_line {
			Hanging(amount) => [attribute("hanging", amount.to_str())]
			FirstLine(amount) => [attribute("firstLine", amount.to_str())]
			Unset => []
		},
	])
	line = match properties.spacing.line {
		Auto(amount) => [attribute("line", amount.to_str()), attribute("lineRule", "auto")]
		Exact(amount) => [attribute("line", amount.to_str()), attribute("lineRule", "exact")]
		AtLeast(amount) => [attribute("line", amount.to_str()), attribute("lineRule", "atLeast")]
		Unset => []
	}
	spacing = List.join([unsigned_twips("before", properties.spacing.before), unsigned_twips("after", properties.spacing.after), line])
	List.join([
		match properties.style {
			Style(id) => [value("pStyle", id)]
			Unset => []
		},
		on_off("keepNext", properties.keep_next),
		on_off("keepLines", properties.keep_lines),
		on_off("pageBreakBefore", properties.page_break_before),
		on_off("widowControl", properties.widow_control),
		if (numbering.is_empty()) [] else [element("numPr", [], numbering)],
		borders("pBdr", properties.borders),
		shading(properties.shading),
		match properties.tabs {
			Tabs(stops) => [element("tabs", [], stops.map(tab_stop))]
			Unset => []
		},
		if (spacing.is_empty()) [] else [element("spacing", spacing, [])],
		if (indentation.is_empty()) [] else [element("ind", indentation, [])],
		match properties.alignment {
			Aligned(alignment) => [value("jc", alignment_name(alignment))]
			Unset => []
		},
		match properties.outline_level {
			Level(level) => [value("outlineLvl", level.to_str())]
			Unset => []
		},
	])
}

signed_twips : Str, [Unset, Twips(I32)] -> List(XmlTree.Attribute)
signed_twips = |local, amount|
	match amount {
		Twips(number) => [attribute(local, number.to_str())]
		Unset => []
	}

unsigned_twips : Str, [Unset, Twips(U32)] -> List(XmlTree.Attribute)
unsigned_twips = |local, amount|
	match amount {
		Twips(number) => [attribute(local, number.to_str())]
		Unset => []
	}

tab_stop : Document.TabStop -> XmlTree.Node
tab_stop = |stop| {
	kind = match stop.kind {
		Clear => "clear"
		Start => "start"
		End => "end"
		Left => "left"
		Right => "right"
		Center => "center"
		Decimal => "decimal"
		Bar => "bar"
		Num => "num"
	}
	leader = match stop.leader {
		Unset => []
		NoLeader => [attribute("leader", "none")]
		Dot => [attribute("leader", "dot")]
		Hyphen => [attribute("leader", "hyphen")]
		Underscore => [attribute("leader", "underscore")]
		Heavy => [attribute("leader", "heavy")]
		MiddleDot => [attribute("leader", "middleDot")]
	}
	element("tab", List.join([[attribute("val", kind)], leader, [attribute("pos", stop.position.to_str())]]), [])
}

alignment_name : Document.Alignment -> Str
alignment_name = |alignment|
	match alignment {
		Start => "start"
		End => "end"
		Left => "left"
		Right => "right"
		Center => "center"
		Both => "both"
		Distribute => "distribute"
		MediumKashida => "mediumKashida"
		HighKashida => "highKashida"
		LowKashida => "lowKashida"
		ThaiDistribute => "thaiDistribute"
		NumTab => "numTab"
	}

run_properties : Document.RunProperties -> List(XmlTree.Node)
run_properties = |properties| {
	fonts = properties.fonts
	font_attributes = List.join([
		named("ascii", fonts.ascii),
		named("hAnsi", fonts.high_ansi),
		named("eastAsia", fonts.east_asia),
		named("cs", fonts.complex),
		theme_font("asciiTheme", fonts.ascii_theme),
		theme_font("hAnsiTheme", fonts.high_ansi_theme),
		theme_font("eastAsiaTheme", fonts.east_asia_theme),
		theme_font("cstheme", fonts.complex_theme),
	])
	language = List.join([tag("val", properties.language.latin), tag("eastAsia", properties.language.east_asia), tag("bidi", properties.language.complex)])
	List.join([
		match properties.style {
			Style(id) => [value("rStyle", id)]
			Unset => []
		},
		if (font_attributes.is_empty()) [] else [element("rFonts", font_attributes, [])],
		on_off("b", properties.bold),
		on_off("i", properties.italic),
		on_off("caps", properties.caps),
		on_off("smallCaps", properties.small_caps),
		on_off("strike", properties.strike),
		on_off("dstrike", properties.double_strike),
		on_off("vanish", properties.hidden),
		match properties.color {
			Color(color) => {
				shown = match color.value {
					Auto => "auto"
					Rgb(rgb) => rgb
				}
				theme = match color.theme {
					Theme(name) => [attribute("themeColor", name)]
					Unset => []
				}
				tint = match color.tint {
					Tint(amount) => [attribute("themeTint", amount)]
					Unset => []
				}
				shade = match color.shade {
					Shade(amount) => [attribute("themeShade", amount)]
					Unset => []
				}
				[element("color", List.join([[attribute("val", shown)], theme, tint, shade]), [])]
			}

			Unset => []
		},
		match properties.size {
			HalfPoints(size) => [value("sz", size.to_str())]
			Unset => []
		},
		match properties.highlight {
			Highlight(highlight) => [value("highlight", highlight_name(highlight))]
			Unset => []
		},
		match properties.underline {
			Underline(line) => [value("u", underline_name(line))]
			Unset => []
		},
		match properties.vertical_align {
			Baseline => [value("vertAlign", "baseline")]
			Superscript => [value("vertAlign", "superscript")]
			Subscript => [value("vertAlign", "subscript")]
			Unset => []
		},
		if (language.is_empty()) [] else [element("lang", language, [])],
	])
}

named : Str, [Unset, Named(Str)] -> List(XmlTree.Attribute)
named = |local, font|
	match font {
		Named(name) => [attribute(local, name)]
		Unset => []
	}

tag : Str, [Unset, Tag(Str)] -> List(XmlTree.Attribute)
tag = |local, language|
	match language {
		Tag(name) => [attribute(local, name)]
		Unset => []
	}

theme_font : Str, [Unset, Theme(Document.ThemeFont)] -> List(XmlTree.Attribute)
theme_font = |local, font|
	match font {
		Theme(theme) => {
			name = match theme {
				MajorEastAsia => "majorEastAsia"
				MajorBidi => "majorBidi"
				MajorAscii => "majorAscii"
				MajorHighAnsi => "majorHAnsi"
				MinorEastAsia => "minorEastAsia"
				MinorBidi => "minorBidi"
				MinorAscii => "minorAscii"
				MinorHighAnsi => "minorHAnsi"
			}
			[attribute(local, name)]
		}

		Unset => []
	}

highlight_name : Document.Highlight -> Str
highlight_name = |highlight|
	match highlight {
		Black => "black"
		Blue => "blue"
		Cyan => "cyan"
		Green => "green"
		Magenta => "magenta"
		Red => "red"
		Yellow => "yellow"
		White => "white"
		DarkBlue => "darkBlue"
		DarkCyan => "darkCyan"
		DarkGreen => "darkGreen"
		DarkMagenta => "darkMagenta"
		DarkRed => "darkRed"
		DarkYellow => "darkYellow"
		DarkGray => "darkGray"
		LightGray => "lightGray"
		NoHighlight => "none"
	}

underline_name : Document.Underline -> Str
underline_name = |line|
	match line {
		Single => "single"
		Words => "words"
		Double => "double"
		Thick => "thick"
		Dotted => "dotted"
		DottedHeavy => "dottedHeavy"
		Dash => "dash"
		DashedHeavy => "dashedHeavy"
		DashLong => "dashLong"
		DashLongHeavy => "dashLongHeavy"
		DotDash => "dotDash"
		DashDotHeavy => "dashDotHeavy"
		DotDotDash => "dotDotDash"
		DashDotDotHeavy => "dashDotDotHeavy"
		Wave => "wave"
		WavyHeavy => "wavyHeavy"
		WavyDouble => "wavyDouble"
		NoUnderline => "none"
	}

table_properties : Document.TableProperties -> List(XmlTree.Node)
table_properties = |properties|
	List.join([
		match properties.style {
			Style(id) => [value("tblStyle", id)]
			Unset => []
		},
		width("tblW", properties.width),
		borders("tblBorders", properties.borders),
		shading(properties.shading),
	])

row_properties : Document.RowProperties -> List(XmlTree.Node)
row_properties = |properties|
	List.join([
		columns("gridBefore", properties.grid_before),
		columns("gridAfter", properties.grid_after),
		on_off("tblHeader", properties.header),
	])

cell_properties : Document.CellProperties -> List(XmlTree.Node)
cell_properties = |properties|
	List.join([
		width("tcW", properties.width),
		columns("gridSpan", properties.span),
		match properties.merge {
			Restart => [value("vMerge", "restart")]
			Continue => [element("vMerge", [], [])]
			Unset => []
		},
		borders("tcBorders", properties.borders),
		shading(properties.shading),
		match properties.alignment {
			Top => [value("vAlign", "top")]
			Center => [value("vAlign", "center")]
			Bottom => [value("vAlign", "bottom")]
			Both => [value("vAlign", "both")]
			Unset => []
		},
	])

columns : Str, [Unset, Columns(U64)] -> List(XmlTree.Node)
columns = |local, count|
	match count {
		Columns(number) => [value(local, number.to_str())]
		Unset => []
	}

width : Str, Document.Width -> List(XmlTree.Node)
width = |local, preferred|
	match preferred {
		Auto => [element(local, [attribute("w", "0"), attribute("type", "auto")], [])]
		Nil => [element(local, [attribute("w", "0"), attribute("type", "nil")], [])]
		Twips(amount) => [element(local, [attribute("w", amount.to_str()), attribute("type", "dxa")], [])]
		Fiftieths(amount) => [element(local, [attribute("w", amount.to_str()), attribute("type", "pct")], [])]
		Unset => []
	}

# Borders, their edges in the schema's order whatever the order they were
# read in.
borders : Str, List(Document.Border) -> List(XmlTree.Node)
borders = |local, edges|
	if edges.is_empty() {
		[]
	} else {
		written = edges.map(
			|border| {
				size = match border.size {
					Eighths(eighths) => [attribute("sz", eighths.to_str())]
					Unset => []
				}
				space = match border.space {
					Points(points) => [attribute("space", points.to_str())]
					Unset => []
				}
				element(edge_name(border.edge), List.join([[attribute("val", border.line)], color("color", border.color), size, space]), [])
			},
		)
		[element(local, [], ordered(edge_order, [], written))]
	}

edge_name : [Top, Left, Start, Bottom, Right, End, InsideHorizontal, InsideVertical, DiagonalDown, DiagonalUp, Between, Bar] -> Str
edge_name = |edge|
	match edge {
		Top => "top"
		Left => "left"
		Start => "start"
		Bottom => "bottom"
		Right => "right"
		End => "end"
		InsideHorizontal => "insideH"
		InsideVertical => "insideV"
		DiagonalDown => "tl2br"
		DiagonalUp => "tr2bl"
		Between => "between"
		Bar => "bar"
	}

shading : Document.Shading -> List(XmlTree.Node)
shading = |shade|
	match shade {
		Shading({ pattern, color: pattern_color, fill }) => [element("shd", List.join([[attribute("val", pattern)], color("color", pattern_color), color("fill", fill)]), [])]
		Unset => []
	}

color : Str, Document.Color -> List(XmlTree.Attribute)
color = |local, chosen|
	match chosen {
		Auto => [attribute(local, "auto")]
		Rgb(rgb) => [attribute(local, rgb)]
		Unset => []
	}

section_properties : Document.Section -> List(XmlTree.Node)
section_properties = |section|
	List.join([
		match section.start {
			NextPage => [value("type", "nextPage")]
			Continuous => [value("type", "continuous")]
			EvenPage => [value("type", "evenPage")]
			OddPage => [value("type", "oddPage")]
			NextColumn => [value("type", "nextColumn")]
			Unset => []
		},
		match section.page_size {
			Size({ width: across, height, orientation }) => {
				oriented = match orientation {
					Landscape => [attribute("orient", "landscape")]
					Portrait => []
				}
				[element("pgSz", List.concat([attribute("w", across.to_str()), attribute("h", height.to_str())], oriented), [])]
			}

			Unset => []
		},
		match section.margins {
			Margins(margins) => {
				attributes = [
					attribute("top", margins.top.to_str()),
					attribute("right", margins.right.to_str()),
					attribute("bottom", margins.bottom.to_str()),
					attribute("left", margins.left.to_str()),
					attribute("header", margins.header.to_str()),
					attribute("footer", margins.footer.to_str()),
					attribute("gutter", margins.gutter.to_str()),
				]
				[element("pgMar", attributes, [])]
			}

			Unset => []
		},
		match section.page_numbers {
			PageNumbers({ format, start }) => {
				formatted = match format {
					Format(name) => [attribute("fmt", name)]
					Unset => []
				}
				started = match start {
					Start(number) => [attribute("start", number.to_str())]
					Unset => []
				}
				[element("pgNumType", List.concat(formatted, started), [])]
			}

			Unset => []
		},
		match section.columns {
			Equal({ count, space, separator }) => {
				attributes = List.join([
					if (space == 720) [] else [attribute("space", space.to_str())],
					if (count == 1) [] else [attribute("num", count.to_str())],
					separated(separator),
				])
				[element("cols", attributes, [])]
			}

			Unequal({ widths, separator }) => {
				listed = widths.map(|column| element("col", List.concat([attribute("w", column.width.to_str())], if (column.space == 0) [] else [attribute("space", column.space.to_str())]), []))
				[element("cols", List.concat([attribute("equalWidth", "0")], separated(separator)), listed)]
			}

			Unset => []
		},
		on_off("titlePg", section.title_page),
	])

separated : [NoLine, Line] -> List(XmlTree.Attribute)
separated = |separator|
	match separator {
		Line => [attribute("sep", "1")]
		NoLine => []
	}

# An on or off property: on is the element alone, off says `w:val="0"`.
on_off : Str, [Unset, On, Off] -> List(XmlTree.Node)
on_off = |local, state|
	match state {
		On => [element(local, [], [])]
		Off => [value(local, "0")]
		Unset => []
	}

value : Str, Str -> XmlTree.Node
value = |local, text| element(local, [attribute("val", text)], [])

element : Str, List(XmlTree.Attribute), List(XmlTree.Node) -> XmlTree.Node
element = |local, attributes, children| Element({ name: { namespace: Uri(wordprocessingml), local, prefix: Prefix("w") }, bindings: [], attributes, children })

attribute : Str, Str -> XmlTree.Attribute
attribute = |local, text| { name: { namespace: Uri(wordprocessingml), local, prefix: Prefix("w") }, value: text }

relationship_name : Str -> XmlTree.Name
relationship_name = |local| { namespace: Uri(relationships_namespace), local, prefix: Prefix("r") }

relationship_attribute : Str, Str -> XmlTree.Attribute
relationship_attribute = |local, text| { name: relationship_name(local), value: text }

unqualified : Str -> XmlTree.Name
unqualified = |local| { namespace: NoNamespace, local, prefix: Unprefixed }

is_w : XmlTree.Name, Str -> Bool
is_w = |name, local| name.local == local and name.namespace == Uri(wordprocessingml)

wordprocessingml : Str
wordprocessingml = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

relationships_namespace : Str
relationships_namespace = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

drawing_namespace : Str
drawing_namespace = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"

drawingml : Str
drawingml = "http://schemas.openxmlformats.org/drawingml/2006/main"

xml_namespace : Str
xml_namespace = "http://www.w3.org/XML/1998/namespace"

hyperlink_relationship : Str
hyperlink_relationship = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink"

image_relationship : Str
image_relationship = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"

header_relationship : Str
header_relationship = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/header"

footer_relationship : Str
footer_relationship = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer"

# A main document part with no body.
shell : XmlTree.Node
shell = XmlTree.parse("<w:document xmlns:w='${wordprocessingml}'/>".to_utf8(), {}) ?? Text("")

no_context : WmlWrite.Context
no_context = { relationships: [], footnotes: [], endnotes: [], comments: [] }

# The written part's text after its root's start tag, or what went wrong.
written : List(Document.Block), WmlWrite.Context -> Str
written = |content, context|
	match WmlWrite.document(shell, content, context) {
		Ok({ tree, relationships: _ }) =>
			match XmlTree.render(tree) {
				Ok(bytes) =>
					match (Str.from_utf8(bytes) ?? "").split_first("<w:body") {
						Ok({ before: _, after }) => "<w:body${after}"
						Err(_) => "no body"
					}

				Err(_) => "unrenderable"
			}

		Err(MissingNote(_)) => "missing note"
		Err(MissingComment(_)) => "missing comment"
	}

run : List(Document.RunContent) -> Document.Inline
run = |content| Run({ properties: Document.no_run_properties, content })

paragraph : List(Document.Inline) -> Document.Block
paragraph = |content| Paragraph({ properties: Document.no_paragraph_properties, content })

## Properties are written in the schema's order whatever order the model
## lists kept ones in, on as the element alone and off with `w:val="0"`,
## borders edge by edge in the schema's order, and text keeps its whitespace
## only where reading would take it as layout.
expect {
	kept = XmlTree.parse("<w:pPr xmlns:w='${wordprocessingml}'><w:rPr><w:b/></w:rPr><w:suppressAutoHyphens/></w:pPr>".to_utf8(), {}) ?? Text("")
	preserved = match kept {
		Element(found) => found.children
		Text(_) => []
	}
	border = |edge| { edge, line: "single", size: Eighths(4), space: Unset, color: Auto }
	properties = { ..Document.no_paragraph_properties, style: Style("Body"), alignment: Aligned(Both), keep_next: On, widow_control: Off, borders: [border(Bottom), border(Top)], preserved }
	content = [Run({ properties: { ..Document.no_run_properties, italic: On, bold: Off, size: HalfPoints(24) }, content: [Text("a b"), Text(" lead"), Text("tab\there"), Tab] })]
	expected_properties = "<w:pPr><w:pStyle w:val=\"Body\"/><w:keepNext/><w:widowControl w:val=\"0\"/><w:pBdr><w:top w:val=\"single\" w:color=\"auto\" w:sz=\"4\"/><w:bottom w:val=\"single\" w:color=\"auto\" w:sz=\"4\"/></w:pBdr><w:suppressAutoHyphens/><w:jc w:val=\"both\"/><w:rPr><w:b/></w:rPr></w:pPr>"
	expected_run = "<w:r><w:rPr><w:b w:val=\"0\"/><w:i/><w:sz w:val=\"24\"/></w:rPr><w:t>a b</w:t><w:t xml:space=\"preserve\"> lead</w:t><w:t xml:space=\"preserve\">tab\there</w:t><w:tab/></w:r>"
	written([Paragraph({ properties, content })], no_context) == "<w:body><w:p>${expected_properties}${expected_run}</w:p></w:body></w:document>"
}

## A section after a paragraph is written in its properties, the body's
## last is the body's own, and one in a table cell stands where it is.
expect {
	section = { start: NextPage, page_size: Unset, margins: Unset, columns: Equal({ count: 2, space: 720, separator: Line }), page_numbers: Unset, title_page: Unset, headers: [], footers: [], preserved: [] }
	cell = Cell({ properties: { width: Twips(2000), span: Unset, merge: Continue, borders: [], shading: Unset, alignment: Unset, preserved: [] }, content: [paragraph([]), Section(section)] })
	table = Table({ properties: { style: Unset, width: Unset, borders: [], shading: Unset, preserved: [] }, grid: [Column(2000)], content: [Row({ properties: { header: On, grid_before: Unset, grid_after: Unset, preserved: [] }, content: [cell] })] })
	ended = "<w:sectPr><w:type w:val=\"nextPage\"/><w:cols w:num=\"2\" w:sep=\"1\"/></w:sectPr>"
	expected_table = "<w:tbl><w:tblPr/><w:tblGrid><w:gridCol w:w=\"2000\"/></w:tblGrid><w:tr><w:trPr><w:tblHeader/></w:trPr><w:tc><w:tcPr><w:tcW w:w=\"2000\" w:type=\"dxa\"/><w:vMerge/></w:tcPr><w:p/>${ended}</w:tc></w:tr></w:tbl>"
	written([paragraph([]), Section(section), table, paragraph([]), Section(section)], no_context)
		== "<w:body><w:p><w:pPr>${ended}</w:pPr></w:p>${expected_table}<w:p/>${ended}</w:body></w:document>"
}

## Bookmarks take the lowest identifiers kept content and comments do not
## use, an end its start's; a hyperlink reuses the part's relationship to its
## address and adds one for a new address; note and comment references take
## their note's and comment's identifiers, and one naming a missing note
## cannot be written.
expect {
	comment = XmlTree.parse("<w:commentRangeStart xmlns:w='${wordprocessingml}' w:id='0'/>".to_utf8(), {}) ?? Text("")
	links = [{ id: "rId1", kind: hyperlink_relationship, target: "https://example.org/a", mode: External }]
	context = { relationships: links, footnotes: ["-1", "0", "7"], endnotes: [], comments: ["3"] }
	content = [
		paragraph([
			Preserved(comment),
			BookmarkEnd("later"),
			BookmarkStart("first"),
			Hyperlink({ target: External("https://example.org/a"), preserved: [], content: [] }),
			Hyperlink({ target: ExternalAt({ url: "https://example.org/b", location: "x" }), preserved: [], content: [] }),
			BookmarkEnd("first"),
			BookmarkStart("later"),
			run([NoteReference({ kind: Footnote, note: 2 }), CommentReference(0)]),
		]),
	]
	text = written(content, context)
	relationships = WmlWrite.document(shell, content, context).map_ok(|out| out.relationships.map(|relationship| (relationship.id, relationship.target)))
	expected = "<w:body><w:p><w:commentRangeStart w:id=\"0\"/><w:bookmarkEnd w:id=\"2\"/><w:bookmarkStart w:id=\"1\" w:name=\"first\"/><w:hyperlink r:id=\"rId1\"/><w:hyperlink r:id=\"rId2\" w:anchor=\"x\"/><w:bookmarkEnd w:id=\"1\"/><w:bookmarkStart w:id=\"2\" w:name=\"later\"/><w:r><w:footnoteReference w:id=\"7\"/><w:commentReference w:id=\"3\"/></w:r></w:p></w:body></w:document>"
	text == expected
		and relationships == Ok([("rId1", "https://example.org/a"), ("rId2", "https://example.org/b")])
		and written([paragraph([run([NoteReference({ kind: Endnote, note: 0 })])])], context) == "missing note"
}

## Tracked changes and moves' ranges take the lowest identifiers left after
## the bookmarks', in the order they are written, a range's end its start's;
## a change keeps its date as written and its other attributes, and deleted
## text and field code are written as deleted inside a deletion only.
expect {
	stamp = Date({ written: "2026-05-07T09:00:00Z", utc_seconds: 1778144400 })
	change = |kind, content| Revision({ kind, author: "Ada", date: stamp, content, preserved: [] })
	content = [
		paragraph([
			BookmarkStart("b"),
			MoveStart({ side: Source, name: "m", author: "Ada", date: Unset, preserved: [] }),
			change(MoveSource, [run([Text("away")])]),
			MoveEnd({ side: Source, name: "m" }),
			change(Deletion, [run([FieldCode(" PAGE "), Text("old")]), change(Insertion, [run([Text("x")])])]),
			Revision({ kind: Insertion, author: "Lin", date: Unset, content: [run([Text("new")])], preserved: [] }),
			BookmarkEnd("b"),
		]),
	]
	moved = "<w:moveFromRangeStart w:id=\"1\" w:name=\"m\" w:author=\"Ada\"/><w:moveFrom w:id=\"2\" w:author=\"Ada\" w:date=\"2026-05-07T09:00:00Z\"><w:r><w:t>away</w:t></w:r></w:moveFrom><w:moveFromRangeEnd w:id=\"1\"/>"
	deleted = "<w:del w:id=\"3\" w:author=\"Ada\" w:date=\"2026-05-07T09:00:00Z\"><w:r><w:delInstrText xml:space=\"preserve\"> PAGE </w:delInstrText><w:delText>old</w:delText></w:r><w:ins w:id=\"4\" w:author=\"Ada\" w:date=\"2026-05-07T09:00:00Z\"><w:r><w:delText>x</w:delText></w:r></w:ins></w:del>"
	inserted = "<w:ins w:id=\"5\" w:author=\"Lin\"><w:r><w:t>new</w:t></w:r></w:ins>"
	written(content, no_context) == "<w:body><w:p><w:bookmarkStart w:id=\"0\" w:name=\"b\"/>${moved}${deleted}${inserted}<w:bookmarkEnd w:id=\"0\"/></w:p></w:body></w:document>"
}

## A part whose root is not a WordprocessingML document is not a main
## document and is written as it is.
expect {
	other = XmlTree.parse("<w:styles xmlns:w='${wordprocessingml}'/>".to_utf8(), {}) ?? Text("")
	WmlWrite.document(other, [paragraph([])], no_context) == Ok({ tree: other, relationships: [] })
}
