## A document's comments joined with the body that anchors them.
##
## A comment's content and authorship are in the comments part, which
## [WmlRead.comments] reads; where it applies is in the body, as the range
## boundaries and references [Document.Inline] and [Document.Block] hold. This
## module joins the two: each comment with what the body says about it. It
## joins the parts Word keeps threads in with the comments on reading, and
## splits the threads into those parts again on writing.
import Document
import WmlRead
import XmlTree

Comments :: [].{

	## Where a comment applies in the body: the current text its range
	## covers, as [Document.paragraph_text] counts text, each paragraph's end
	## within the range a line feed; a point, where the body refers to the
	## comment without a range around it; or nowhere, when the body neither
	## marks a range for it nor refers to it.
	##
	## A range that starts and ends at one position, as Word writes a comment
	## on no text, covers the empty text. A range that never ends runs to the
	## end of the body.
	Anchor : [Range(Str), Point, Unanchored]

	## A comment with its anchor, and its `id`: its place among the comments
	## of the comments part, which is how the body's ranges and references
	## name it.
	Anchored : { id : U64, comment : Document.Comment, anchor : Anchor }

	## The comments joined with the body: those the body anchors in the order
	## their anchors begin, a range at its start and a point where the body
	## refers to the comment, then the others in the order of their part.
	## Paragraphs end and join as [Docx.text] says: a paragraph whose mark is
	## deleted or moved away runs on into the next without a line feed unless
	## a table, row or cell begins or ends between them.
	anchored : List(Document.Block), List(Document.Comment) -> List(Anchored)
	anchored = |body, comments| {
		if comments.is_empty() {
			return []
		}
		start = { marks: List.repeat({ begun: NotYet, range: NoRange }, comments.len()), text: List.with_capacity(1024), joining: Bool.False, events: 0 }
		walked = line_end(body.fold(start, walk_block))
		var $out = List.with_capacity(comments.len())
		var $id = 0.U64
		for comment in comments {
			mark = walked.marks.get($id) ?? { begun: NotYet, range: NoRange }
			anchor = match mark.range {
				Open(from) => Range(text_between(walked.text, from, walked.text.len()))
				Closed({ begin: from, end: to }) => Range(text_between(walked.text, from, to))
				NoRange => if (mark.begun == NotYet) Unanchored else Point
			}
			order = match mark.begun {
				Begun(event) => event
				NotYet => walked.events + $id
			}
			$out = List.append($out, { order, anchored: { id: $id, comment, anchor } })
			$id = $id + 1
		}
		$out
			.sort_with(|a, b| if (a.order < b.order) Before else if (a.order > b.order) After else Same)
			.map(|entry| entry.anchored)
	}

	## The parts that make a document's comments threads, each the tree
	## [Docx.parse] read, or the empty text where the document does not have
	## the part: the comments part, whose paragraphs carry the identifiers
	## the others are joined by; the extended comments part, which says what
	## each comment replies to and whether it is done; the comment
	## identifiers part, which gives each its durable identifier; and the
	## extensible comments part, which gives a durable identifier its UTC
	## date.
	Parts : { comments : XmlTree.Node, extended : XmlTree.Node, ids : XmlTree.Node, extensible : XmlTree.Node }

	## The comments of a comments part, as [WmlRead.comments] reads them,
	## completed from the parts beside it. A comment is known to those parts
	## by the paragraph identifier of the last paragraph of its content, its
	## `w14:paraId`: the extended comments entry with that identifier gives
	## its parent, by the identifier of the parent's last paragraph, and
	## whether it is done; the comment identifiers entry gives its durable
	## identifier, eight hexadecimal digits; and the extensible comments
	## entry with that durable identifier its UTC date.
	##
	## The parts are read as written, without [Mce.process], since their
	## namespaces are extensions to ECMA-376. An entry that names no comment,
	## a parent that is no other comment, and a durable identifier or date
	## that is not one are not applied. Where an identifier repeats, the last
	## entry with it counts. A document without the parts, as older
	## producers write it, has comments without parents, unresolved and
	## without durable identifiers or UTC dates.
	threads : List(Document.Comment), Parts -> List(Document.Comment)
	threads = |comments, parts| {
		{ paragraphs, places } = indexed(parts.comments)
		var $extended = Dict.with_capacity(paragraphs.len())
		for element in entries(parts.extended, w15, "commentsEx", "commentEx") {
			entry = { parent: attribute(element, w15, "paraIdParent") ?? "", done: is_on(attribute(element, w15, "done") ?? "") }
			$extended = $extended.insert(attribute(element, w15, "paraId") ?? "", entry)
		}
		var $durable = Dict.with_capacity(paragraphs.len())
		for element in entries(parts.ids, w16cid, "commentsIds", "commentId") {
			match hexadecimal(attribute(element, w16cid, "durableId") ?? "") {
				Ok(id) => {
					$durable = $durable.insert(attribute(element, w16cid, "paraId") ?? "", id)
				}

				Err(NotHex) => {}
			}
		}
		var $dates = Dict.with_capacity(paragraphs.len())
		for element in entries(parts.extensible, w16cex, "commentsExtensible", "commentExtensible") {
			match (hexadecimal(attribute(element, w16cex, "durableId") ?? ""), WmlRead.date_time(attribute(element, w16cex, "dateUtc") ?? "")) {
				(Ok(id), Ok(stamp)) => {
					$dates = $dates.insert(id, stamp)
				}

				_ => {}
			}
		}
		var $out = List.with_capacity(comments.len())
		var $index = 0.U64
		for comment in comments {
			paragraph = paragraphs.get($index) ?? ""
			threaded = if paragraph == "" {
				comment
			} else {
				extended = $extended.get(paragraph) ?? { parent: "", done: Bool.False }
				durable = $durable.get(paragraph)
				durable_id = match durable {
					Ok(id) => DurableId(id)
					Err(_) => Unset
				}
				utc_date = match durable {
					Ok(id) =>
						match $dates.get(id) {
							Ok(stamp) => Date(stamp)
							Err(_) => Unset
						}

					Err(_) => Unset
				}
				parent = match places.get(extended.parent) {
					Ok(place) if extended.parent != "" and place != $index => Parent(place)
					_ => Unset
				}
				{ ..comment, parent, resolved: extended.done, durable_id, utc_date }
			}
			$out = List.append($out, threaded)
			$index = $index + 1
		}
		$out
	}

	## The people of a people part, in its order: each `w15:person`'s
	## author, with its presence where its `w15:presenceInfo` names both a
	## provider and an identifier there, and a `NotApplied` diagnostic for a
	## presence that does not, which [Comments.people_part] writes back as it
	## was read. The part is read as written, as [Comments.threads] reads the
	## comments' parts. A tree that is not a people part has no people.
	people : XmlTree.Node -> { people : List(Document.Person), diagnostics : List(WmlRead.Diagnostic) }
	people = |tree| {
		var $people = List.with_capacity(4)
		var $diagnostics = List.with_capacity(0)
		for element in entries(tree, w15, "people", "person") {
			author = attribute(element, w15, "author") ?? ""
			presence = match element.children.find_first(|child| is_named(child, w15, "presenceInfo")) {
				Ok(Element(info)) =>
					match (attribute(info, w15, "providerId"), attribute(info, w15, "userId")) {
						(Ok(provider), Ok(user)) => Presence({ provider, user })
						_ => {
							$diagnostics = List.append($diagnostics, NotApplied({ element: "presenceInfo", key: author }))
							Unset
						}
					}

				_ => Unset
			}
			$people = List.append($people, { author, presence })
		}
		{ people: $people, diagnostics: $diagnostics }
	}

	## The entries of the parts beside a comments part that the model does
	## not hold as they were written, to be written back as they were read,
	## each with a `NotApplied` diagnostic: an extended comments or comment
	## identifiers entry that names no comment by its paragraph, is not the
	## entry that counts for its paragraph, or holds a parent that is no
	## other comment, a `done` that is not on or off, a durable identifier
	## that is not one, or any other attribute or child; and an extensible
	## comments entry whose durable identifier is no comment's, that is not
	## the last entry for it, or whose date is not a date. An extensible
	## entry the model holds keeps its other attributes and children, which
	## [Comments.split] writes back in it.
	Kept : { extended : List(XmlTree.Node), ids : List(XmlTree.Node), extensible : List(XmlTree.Node), diagnostics : List(WmlRead.Diagnostic) }

	## What [Comments.threads] does not hold of these parts, as
	## [Comments.Kept] says.
	kept : Parts -> Kept
	kept = |parts| {
		{ paragraphs, places } = indexed(parts.comments)
		extended = entries(parts.extended, w15, "commentsEx", "commentEx")
		extended_last = last_by(extended, |element| Ok(attribute(element, w15, "paraId") ?? ""))
		var $extended = List.with_capacity(0)
		var $diagnostics = List.with_capacity(0)
		var $index = 0.U64
		for element in extended {
			key = attribute(element, w15, "paraId") ?? ""
			parent_held = match attribute(element, w15, "paraIdParent") {
				Ok(parent) =>
					match (places.get(parent), places.get(key)) {
						(Ok(other), Ok(own)) => other != own
						_ => Bool.False
					}

				Err(NotFound) => Bool.True
			}
			done_held = ["0", "1", "true", "false", "on", "off"].contains(attribute(element, w15, "done") ?? "0")
			if !(places.get(key).is_ok() and extended_last.get(key) == Ok($index) and parent_held and done_held and holds_only(element, w15, ["paraId", "paraIdParent", "done"])) {
				$extended = List.append($extended, Element(element))
				$diagnostics = List.append($diagnostics, NotApplied({ element: "commentEx", key }))
			}
			$index = $index + 1
		}
		ids = entries(parts.ids, w16cid, "commentsIds", "commentId")
		ids_last = last_by(ids, |element| hexadecimal(attribute(element, w16cid, "durableId") ?? "").map_ok(|_| attribute(element, w16cid, "paraId") ?? ""))
		var $ids = List.with_capacity(0)
		var $durable = Set.with_capacity(paragraphs.len())
		$index = 0
		for element in ids {
			key = attribute(element, w16cid, "paraId") ?? ""
			match hexadecimal(attribute(element, w16cid, "durableId") ?? "") {
				Ok(id) if places.get(key).is_ok() and ids_last.get(key) == Ok($index) => {
					$durable = $durable.insert(id)
				}

				_ => {}
			}
			held = hexadecimal(attribute(element, w16cid, "durableId") ?? "").is_ok() and places.get(key).is_ok() and ids_last.get(key) == Ok($index)
			if !(held and holds_only(element, w16cid, ["paraId", "durableId"])) {
				$ids = List.append($ids, Element(element))
				$diagnostics = List.append($diagnostics, NotApplied({ element: "commentId", key }))
			}
			$index = $index + 1
		}
		extensible = entries(parts.extensible, w16cex, "commentsExtensible", "commentExtensible")
		extensible_last = last_by(extensible, |element| hexadecimal(attribute(element, w16cex, "durableId") ?? "").map_ok(hex8))
		var $extensible = List.with_capacity(0)
		$index = 0
		for element in extensible {
			key = attribute(element, w16cex, "durableId") ?? ""
			held = match hexadecimal(key) {
				Ok(id) => $durable.contains(id) and extensible_last.get(hex8(id)) == Ok($index) and dated(element)
				Err(NotHex) => Bool.False
			}
			if !held {
				$extensible = List.append($extensible, Element(element))
				$diagnostics = List.append($diagnostics, NotApplied({ element: "commentExtensible", key }))
			}
			$index = $index + 1
		}
		{ extended: $extended, ids: $ids, extensible: $extensible, diagnostics: $diagnostics }
	}

	## The parts beside a comments part that make its comments threads, as
	## [Comments.split] writes them: the extended comments, comment
	## identifiers and extensible comments parts.
	Extensions : { extended : XmlTree.Node, ids : XmlTree.Node, extensible : XmlTree.Node }

	## The extension parts of these comments, the inverse of
	## [Comments.threads]: `paragraphs` gives the identifier of each
	## comment's last paragraph, as [WmlWrite.comments] writes it, the empty
	## string for a comment without a paragraph, which the parts cannot
	## name. Each shell is the part as it was read, its root's declarations,
	## attributes and children other than entries kept, or anything else for
	## a new part, and the entries `kept` holds, as [Comments.kept] finds
	## them, are written as they were read before the written ones.
	##
	## The extended comments part has an entry for every comment with a
	## paragraph: its parent's paragraph where its parent has one, and
	## whether it is done. The comment identifiers part has an entry for
	## every such comment with a durable identifier, as eight hexadecimal
	## digits, and the extensible comments part one for the same durable
	## identifier with the comment's UTC date where it has one, keeping
	## what else the shell's last entry for that durable identifier holds,
	## such as reactions, where that entry's date is one.
	split : List(Document.Comment), List(Str), Extensions, Kept -> Extensions
	split = |comments, paragraphs, shells, kept_entries| {
		var $extended = List.with_capacity(comments.len())
		var $ids = List.with_capacity(comments.len())
		var $extensible = List.with_capacity(comments.len())
		merged = entries(shells.extensible, w16cex, "commentsExtensible", "commentExtensible").fold(
			Dict.with_capacity(comments.len()),
			|found, element|
				match hexadecimal(attribute(element, w16cex, "durableId") ?? "") {
					Ok(id) if dated(element) => found.insert(id, element)
					Ok(id) => found.remove(id)
					Err(NotHex) => found
				},
		)
		var $place = 0.U64
		for comment in comments {
			paragraph = paragraphs.get($place) ?? ""
			if paragraph != "" {
				parent = match comment.parent {
					Parent(other) if other != $place =>
						match paragraphs.get(other) {
							Ok(found) if found != "" => [named(w15, "paraIdParent", found)]
							_ => []
						}

					_ => []
				}
				done = named(w15, "done", if (comment.resolved) "1" else "0")
				$extended = List.append($extended, extension_element(w15, "commentEx", List.join([[named(w15, "paraId", paragraph)], parent, [done]]), []))
				match comment.durable_id {
					DurableId(id) => {
						durable = hex8(id)
						$ids = List.append($ids, extension_element(w16cid, "commentId", [named(w16cid, "paraId", paragraph), named(w16cid, "durableId", durable)], []))
						date = match comment.utc_date {
							Date(stamp) => [named(w16cex, "dateUtc", stamp.written)]
							Unset => []
						}
						previous = merged.get(id) ?? { name: name(w16cex, "commentExtensible"), bindings: [], attributes: [], children: [] }
						others = previous.attributes.drop_if(|candidate| candidate.name.namespace == Uri(w16cex) and (candidate.name.local == "durableId" or candidate.name.local == "dateUtc"))
						$extensible = List.append($extensible, extension_element(w16cex, "commentExtensible", List.join([[named(w16cex, "durableId", durable)], date, others]), previous.children))
					}

					Unset => {}
				}
			}
			$place = $place + 1
		}
		{
			extended: extension_part(shells.extended, w15, "commentsEx", "commentEx", List.concat(kept_entries.extended, $extended)),
			ids: extension_part(shells.ids, w16cid, "commentsIds", "commentId", List.concat(kept_entries.ids, $ids)),
			extensible: extension_part(shells.extensible, w16cex, "commentsExtensible", "commentExtensible", List.concat(kept_entries.extensible, $extensible)),
		}
	}

	## The people part of these people, the inverse of [Comments.people]:
	## each person's author, and their presence where they have one. `shell`
	## is the part as it was read, as [Comments.split] keeps a shell; where
	## the shell's person at the same place has the same author, what else
	## it holds is kept, and so is its presence when the person has none, as
	## a presence without both a provider and an identifier reads.
	people_part : XmlTree.Node, List(Document.Person) -> XmlTree.Node
	people_part = |shell, listed| {
		previous = entries(shell, w15, "people", "person")
		var $written = List.with_capacity(listed.len())
		var $place = 0.U64
		for person in listed {
			base = match previous.get($place) {
				Ok(found) if attribute(found, w15, "author") == Ok(person.author) => found
				_ => { name: name(w15, "person"), bindings: [], attributes: [named(w15, "author", person.author)], children: [] }
			}
			children = match person.presence {
				Presence({ provider, user }) => List.prepend(base.children.drop_if(|child| is_named(child, w15, "presenceInfo")), extension_element(w15, "presenceInfo", [named(w15, "providerId", provider), named(w15, "userId", user)], []))
				Unset => base.children
			}
			$written = List.append($written, Element({ ..base, children }))
			$place = $place + 1
		}
		extension_part(shell, w15, "people", "person", $written)
	}
}

# The body's current text so far, with every comment's range as offsets in
# it; whether the last paragraph joins the next; and how many anchors have
# begun, which orders them.
Walk : { marks : List(Mark), text : List(U8), joining : Bool, events : U64 }

# Whether a comment's anchor has begun, and its range in the text.
Mark : { begun : [NotYet, Begun(U64)], range : [NoRange, Open(U64), Closed({ begin : U64, end : U64 })] }

walk_block : Walk, Document.Block -> Walk
walk_block = |state, block|
	match block {
		Paragraph(paragraph) => {
			walked = paragraph.content.fold(state, |inner, inline| walk_inline(inner, inline, Bool.True))
			if Document.joins_next(paragraph) {
				{ ..walked, joining: Bool.True }
			} else {
				{ ..walked, text: List.append(walked.text, 10), joining: Bool.False }
			}
		}

		Table(table) => line_end(table.content.fold(line_end(state), walk_table_content))
		Container({ element: _, content }) => content.fold(state, walk_block)
		CommentStart(id) => begin(state, id)
		CommentEnd(id) => end(state, id)
		Section(_) => state
		Preserved(_) => state
	}

walk_table_content : Walk, Document.TableContent -> Walk
walk_table_content = |state, content|
	match content {
		Row(row) => line_end(row.content.fold(line_end(state), walk_row_content))
		Container({ element: _, content: inner }) => inner.fold(state, walk_table_content)
		CommentStart(id) => begin(state, id)
		CommentEnd(id) => end(state, id)
		Preserved(_) => state
	}

walk_row_content : Walk, Document.RowContent -> Walk
walk_row_content = |state, content|
	match content {
		Cell(cell) => line_end(cell.content.fold(line_end(state), walk_block))
		Container({ element: _, content: inner }) => inner.fold(state, walk_row_content)
		CommentStart(id) => begin(state, id)
		CommentEnd(id) => end(state, id)
		Preserved(_) => state
	}

# An inline's boundaries and references, and its text when it is current
# text: content deleted or moved away is not.
walk_inline : Walk, Document.Inline, Bool -> Walk
walk_inline = |state, inline, current|
	match inline {
		Run(run) => {
			referred = run.content.fold(
				state,
				|inner, content|
					match content {
						CommentReference(id) => refer(inner, id)
						_ => inner
					},
			)
			if current {
				{ ..referred, text: List.concat(referred.text, Document.inline_text(inline).to_utf8()) }
			} else {
				referred
			}
		}

		Hyperlink({ target: _, preserved: _, content }) => content.fold(state, |inner, child| walk_inline(inner, child, current))
		SimpleField({ code: _, preserved: _, content }) => content.fold(state, |inner, child| walk_inline(inner, child, current))
		Container({ element: _, content }) => content.fold(state, |inner, child| walk_inline(inner, child, current))
		Revision({ kind, author: _, date: _, content, preserved: _ }) => content.fold(state, |inner, child| walk_inline(inner, child, current and kind != Deletion and kind != MoveSource))
		CommentStart(id) => begin(state, id)
		CommentEnd(id) => end(state, id)
		BookmarkStart(_) => state
		BookmarkEnd(_) => state
		MoveStart(_) => state
		MoveEnd(_) => state
		Preserved(_) => state
	}

# A range's start: the comment's anchor begins here unless a reference began
# it earlier, and its range unless one began before.
begin : Walk, U64 -> Walk
begin = |state, id| {
	at = state.text.len()
	started = change(state, id, |mark| { begun: mark.begun, range: if (mark.range == NoRange) Open(at) else mark.range })
	refer(started, id)
}

# A range's end closes the range open for the comment; an end without a start
# closes nothing.
end : Walk, U64 -> Walk
end = |state, id| {
	at = state.text.len()
	change(
		state,
		id,
		|mark|
			match mark.range {
				Open(start) => { begun: mark.begun, range: Closed({ begin: start, end: at }) }
				_ => mark
			},
	)
}

# A reference, or a range's start, begins the comment's anchor when nothing
# began it before.
refer : Walk, U64 -> Walk
refer = |state, id|
	match state.marks.get(id) {
		Ok({ begun: NotYet, range }) => { ..state, marks: List.set(state.marks, id, { begun: Begun(state.events), range }) ?? [], events: state.events + 1 }
		_ => state
	}

change : Walk, U64, (Mark -> Mark) -> Walk
change = |state, id, update|
	match state.marks.get(id) {
		Ok(mark) => { ..state, marks: List.set(state.marks, id, update(mark)) ?? [] }
		Err(_) => state
	}

# The line feed a joining paragraph owes where nothing follows it to join.
line_end : Walk -> Walk
line_end = |state| if (state.joining) { ..state, text: List.append(state.text, 10), joining: Bool.False } else state

text_between : List(U8), U64, U64 -> Str
text_between = |text, from, to| Str.from_utf8(text.sublist({ start: from, len: to - from })) ?? ""

wordprocessingml : Str
wordprocessingml = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

# The namespaces of the paragraph identifiers, the extended comments and
# people parts, the comment identifiers part and the extensible comments
# part, from MS-DOCX.
w14 : Str
w14 = "http://schemas.microsoft.com/office/word/2010/wordml"

w15 : Str
w15 = "http://schemas.microsoft.com/office/word/2012/wordml"

w16cid : Str
w16cid = "http://schemas.microsoft.com/office/word/2016/wordml/cid"

w16cex : Str
w16cex = "http://schemas.microsoft.com/office/word/2018/wordml/cex"

Element : { name : XmlTree.Name, bindings : List(XmlTree.Binding), attributes : List(XmlTree.Attribute), children : List(XmlTree.Node) }

is_named : XmlTree.Node, Str, Str -> Bool
is_named = |node, namespace, local|
	match node {
		Element(element) => element.name.namespace == Uri(namespace) and element.name.local == local
		Text(_) => Bool.False
	}

# The children named `entry` of a root named `root`, both in `namespace`.
entries : XmlTree.Node, Str, Str, Str -> List(Element)
entries = |tree, namespace, root, entry|
	match tree {
		Element(element) if is_named(tree, namespace, root) =>
			element.children.keep_oks(
				|child|
					match child {
						Element(found) if is_named(child, namespace, entry) => Ok(found)
						_ => Err(NotAnEntry)
					},
			)

		_ => []
	}

attribute : Element, Str, Str -> Try(Str, [NotFound])
attribute = |element, namespace, local|
	match element.attributes.find_first(|candidate| candidate.name.namespace == Uri(namespace) and candidate.name.local == local) {
		Ok(found) => Ok(found.value)
		Err(_) => Err(NotFound)
	}

# The paragraph identifier of the last paragraph among these nodes, looking
# into tables and other containers but not into a paragraph; the empty
# string when there is none or that paragraph has no identifier.
last_paragraph : List(XmlTree.Node) -> Str
last_paragraph = |nodes|
	nodes.fold(
		"",
		|found, node|
			match node {
				Element(element) if is_named(node, wordprocessingml, "p") => attribute(element, w14, "paraId") ?? ""
				Element(element) =>
					match last_paragraph(element.children) {
						"" => found
						inner => inner
					}

				Text(_) => found
			},
	)

# Each comment's last paragraph identifier, as its comments part orders
# them, and each identifier's place, the last comment with it counting.
indexed : XmlTree.Node -> { paragraphs : List(Str), places : Dict(Str, U64) }
indexed = |tree| {
	var $last = Dict.with_capacity(8)
	for element in entries(tree, wordprocessingml, "comments", "comment") {
		$last = $last.insert(attribute(element, wordprocessingml, "id") ?? "", last_paragraph(element.children))
	}
	paragraphs = WmlRead.comment_ids(tree).map(|id| $last.get(id) ?? "")
	var $places = Dict.with_capacity(paragraphs.len())
	var $place = 0.U64
	for paragraph in paragraphs {
		$places = $places.insert(paragraph, $place)
		$place = $place + 1
	}
	{ paragraphs, places: $places }
}

# The place of the last of `elements` with each key, among those that have
# one.
last_by : List(Element), (Element -> Try(Str, _)) -> Dict(Str, U64)
last_by = |elements, key_of| {
	var $last = Dict.with_capacity(elements.len())
	var $index = 0.U64
	for element in elements {
		match key_of(element) {
			Ok(key) => {
				$last = $last.insert(key, $index)
			}

			Err(_) => {}
		}
		$index = $index + 1
	}
	$last
}

# Whether an entry has only these attributes of its namespace and no child
# elements.
holds_only : Element, Str, List(Str) -> Bool
holds_only = |element, namespace, locals|
	element.attributes.all(|candidate| candidate.name.namespace == Uri(namespace) and locals.contains(candidate.name.local))
		and !element.children.any(
			|child|
				match child {
					Element(_) => Bool.True
					Text(_) => Bool.False
				},
		)

# Whether an extensible comments entry's date, where it has one, is a date.
dated : Element -> Bool
dated = |element|
	match attribute(element, w16cex, "dateUtc") {
		Ok(written) => WmlRead.date_time(written).is_ok()
		Err(NotFound) => Bool.True
	}

# An on or off value as the extended comments part writes `done`.
is_on : Str -> Bool
is_on = |value| ["1", "true", "on"].contains(value)

# A durable identifier: one to eight hexadecimal digits.
hexadecimal : Str -> Try(U32, [NotHex])
hexadecimal = |text| {
	digits = text.to_utf8()
	if digits.is_empty() or digits.len() > 8 {
		return Err(NotHex)
	}
	digits.fold(Ok(0.U32), |sum, digit| Ok((sum?) * 16 + (hex_value(digit)?)))
}

# A number as eight hexadecimal digits, as Word writes a durable identifier.
hex8 : U32 -> Str
hex8 = |number| {
	digits = "0123456789ABCDEF".to_utf8()
	shifts = [268_435_456, 16_777_216, 1_048_576, 65_536, 4096, 256, 16, 1]
	Str.from_utf8(shifts.map(|shift| digits.get(((number // shift) % 16).to_u64()) ?? '0')) ?? "00000000"
}

name : Str, Str -> XmlTree.Name
name = |namespace, local| { namespace: Uri(namespace), local, prefix: Prefix(prefix_of(namespace)) }

named : Str, Str, Str -> XmlTree.Attribute
named = |namespace, local, value| { name: name(namespace, local), value }

extension_element : Str, Str, List(XmlTree.Attribute), List(XmlTree.Node) -> XmlTree.Node
extension_element = |namespace, local, attributes, children| Element({ name: name(namespace, local), bindings: [], attributes, children })

# The prefix a part of these namespaces is written with.
prefix_of : Str -> Str
prefix_of = |namespace| if (namespace == w15) "w15" else if (namespace == w16cid) "w16cid" else "w16cex"

# A part whose root is named `root` holding `written` entries named `local`:
# the shell's root with its children other than entries, or a new root.
extension_part : XmlTree.Node, Str, Str, Str, List(XmlTree.Node) -> XmlTree.Node
extension_part = |shell, namespace, root, local, written|
	match shell {
		Element(element) if is_named(shell, namespace, root) => Element({ ..element, children: List.concat(element.children.drop_if(|child| is_named(child, namespace, local)), written) })
		_ => Element({ name: name(namespace, root), bindings: [], attributes: [], children: written })
	}

hex_value : U8 -> Try(U32, [NotHex])
hex_value = |digit|
	if digit >= '0' and digit <= '9' {
		Ok((digit - '0').to_u32())
	} else if digit >= 'a' and digit <= 'f' {
		Ok((digit - 'a' + 10).to_u32())
	} else if digit >= 'A' and digit <= 'F' {
		Ok((digit - 'A' + 10).to_u32())
	} else {
		Err(NotHex)
	}

# The comments of a body with this content, whose comments part has
# comments with these identifiers, each anchored or not.
anchors_of : Str, List(Str) -> List({ id : U64, anchor : Comments.Anchor })
anchors_of = |content, ids| {
	namespaces = "xmlns:w='${wordprocessingml}'"
	tree = XmlTree.parse("<w:document ${namespaces}><w:body>${content}</w:body></w:document>".to_utf8(), {}) ?? Text("")
	body = WmlRead.body(tree, { relationships: [], footnotes: [], endnotes: [], comments: ids })
	comment : Document.Comment
	comment = { author: "Ada Reviewer", initials: Unset, date: Unset, content: [], preserved: [], parent: Unset, resolved: Bool.False, durable_id: Unset, utc_date: Unset }
	Comments.anchored(body, List.repeat(comment, ids.len())).map(|entry| { id: entry.id, anchor: entry.anchor })
}

## A range covers the current text between its start and its end, a line
## feed for each paragraph's end within it, without deleted text and with
## inserted text; comments are in the order their anchors begin, a reference
## without a range a point, an empty range the empty text and a comment the
## body does not anchor last.
expect {
	run = |text| "<w:r><w:t xml:space='preserve'>${text}</w:t></w:r>"
	reference = |id| "<w:r><w:commentReference w:id='${id}'/></w:r>"
	first = "<w:p>${run("Lead ")}${reference("1")}<w:commentRangeStart w:id='0'/>${run("one")}<w:del w:author='A'><w:r><w:delText>gone</w:delText></w:r></w:del><w:ins w:author='A'>${run(" new")}</w:ins></w:p>"
	second = "<w:p>${run("two")}<w:commentRangeEnd w:id='0'/>${reference("0")}<w:commentRangeStart w:id='2'/><w:commentRangeEnd w:id='2'/>${reference("2")}</w:p>"
	anchors_of("${first}${second}", ["0", "1", "2", "3"])
		== [
			{ id: 1, anchor: Point },
			{ id: 0, anchor: Range("one new\ntwo") },
			{ id: 2, anchor: Range("") },
			{ id: 3, anchor: Unanchored },
		]
}

## A range can start and end between blocks, rows and cells, takes a table's
## paragraphs with their line feeds, and runs to the end of the body when it
## never ends; a paragraph whose mark is deleted runs on into the next.
expect {
	cell = |text| "<w:tc><w:p><w:r><w:t>${text}</w:t></w:r></w:p></w:tc>"
	table = "<w:tbl><w:tr><w:commentRangeStart w:id='1'/>${cell("a")}${cell("b")}<w:commentRangeEnd w:id='1'/></w:tr></w:tbl>"
	joined = "<w:p><w:pPr><w:rPr><w:del w:id='9' w:author='A'/></w:rPr></w:pPr><w:r><w:t>c</w:t></w:r></w:p><w:p><w:r><w:t>d</w:t></w:r></w:p>"
	anchors_of("<w:commentRangeStart w:id='0'/>${table}<w:commentRangeEnd w:id='0'/><w:commentRangeStart w:id='2'/>${joined}", ["0", "1", "2"])
		== [
			{ id: 0, anchor: Range("a\nb\n") },
			{ id: 1, anchor: Range("a\nb\n") },
			{ id: 2, anchor: Range("cd\n") },
		]
}

# The comments of a comments part with this content, threaded by extended
# comments, comment identifiers and extensible comments parts with this
# content each, the empty content for a part the document does not have.
threads_of : Str, { extended : Str, ids : Str, extensible : Str } -> List({ parent : [Unset, Parent(U64)], resolved : Bool, durable_id : [Unset, DurableId(U32)], utc_date : Str })
threads_of = |comments, parts| {
	namespaces = "xmlns:w='${wordprocessingml}' xmlns:w14='${w14}' xmlns:w15='${w15}' xmlns:w16cid='${w16cid}' xmlns:w16cex='${w16cex}'"
	tree = |root, content| if (content == "") Text("") else XmlTree.parse("<${root} ${namespaces}>${content}</${root}>".to_utf8(), {}) ?? Text("")
	part = tree("w:comments", comments)
	read = WmlRead.comments(part, { relationships: [], footnotes: [], endnotes: [], comments: [] }).comments
	threaded = Comments.threads(read, { comments: part, extended: tree("w15:commentsEx", parts.extended), ids: tree("w16cid:commentsIds", parts.ids), extensible: tree("w16cex:commentsExtensible", parts.extensible) })
	threaded.map(
		|comment| {
			utc_date = match comment.utc_date {
				Date(stamp) => stamp.written
				Unset => ""
			}
			{ parent: comment.parent, resolved: comment.resolved, durable_id: comment.durable_id, utc_date }
		},
	)
}

## A comment is joined with the extension parts by the identifier of its
## last paragraph, inside a table too: a reply names its parent by the
## parent's, and the durable identifier leads to the UTC date. A parent that
## is the comment itself, a durable identifier or date that is not one, and
## a comment whose last paragraph has no identifier take nothing.
expect {
	paragraph = |id| if (id == "") "<w:p/>" else "<w:p w14:paraId='${id}'/>"
	comment = |id, content| "<w:comment w:id='${id}' w:author='Ada Reviewer'>${content}</w:comment>"
	comments = Str.join_with(
		[
			comment("7", "${paragraph("0A")}${paragraph("1B")}"),
			comment("3", paragraph("2C")),
			comment("5", "<w:tbl><w:tr><w:tc>${paragraph("3D")}</w:tc></w:tr></w:tbl>"),
			comment("9", paragraph("")),
		],
		"",
	)
	extended = "<w15:commentEx w15:paraId='1B' w15:done='0'/><w15:commentEx w15:paraId='2C' w15:paraIdParent='1B' w15:done='1'/><w15:commentEx w15:paraId='3D' w15:paraIdParent='3D'/><w15:commentEx w15:paraId='4E' w15:paraIdParent='1B'/>"
	ids = "<w16cid:commentId w16cid:paraId='1B' w16cid:durableId='0000ABCD'/><w16cid:commentId w16cid:paraId='2C' w16cid:durableId='zz'/><w16cid:commentId w16cid:paraId='3D' w16cid:durableId='7F'/>"
	extensible = "<w16cex:commentExtensible w16cex:durableId='0000abcd' w16cex:dateUtc='2026-05-04T09:15:00Z'/><w16cex:commentExtensible w16cex:durableId='7F' w16cex:dateUtc='later'/>"
	threads_of(comments, { extended, ids, extensible })
		== [
			{ parent: Unset, resolved: Bool.False, durable_id: DurableId(0xABCD), utc_date: "2026-05-04T09:15:00Z" },
			{ parent: Parent(0), resolved: Bool.True, durable_id: Unset, utc_date: "" },
			{ parent: Unset, resolved: Bool.False, durable_id: DurableId(0x7F), utc_date: "" },
			{ parent: Unset, resolved: Bool.False, durable_id: Unset, utc_date: "" },
		]
}

## Without the extension parts, as older producers write a document, every
## comment is unthreaded, unresolved and without a durable identifier or UTC
## date.
expect {
	comments = "<w:comment w:id='0' w:author='Ada Reviewer'><w:p w14:paraId='1A'/></w:comment>"
	threads_of(comments, { extended: "", ids: "", extensible: "" }) == [{ parent: Unset, resolved: Bool.False, durable_id: Unset, utc_date: "" }]
}

## A person has the author and, where both are given, the presence the
## people part records, and a presence without both is not applied, with a
## diagnostic, and written back as it was read; a tree that is not a people
## part has no people.
expect {
	part = "<w15:people xmlns:w15='${w15}'><w15:person w15:author='Ada Reviewer'><w15:presenceInfo w15:providerId='None' w15:userId='Ada Reviewer'/></w15:person><w15:person w15:author='Lin Editor'><w15:presenceInfo w15:providerId='None'/></w15:person></w15:people>"
	tree = XmlTree.parse(part.to_utf8(), {})?
	read = Comments.people(tree)
	rewritten = Comments.people_part(tree, read.people)
	read.people
		== [
			{ author: "Ada Reviewer", presence: Presence({ provider: "None", user: "Ada Reviewer" }) },
			{ author: "Lin Editor", presence: Unset },
		]
		and read.diagnostics == [NotApplied({ element: "presenceInfo", key: "Lin Editor" })]
		and Document.equivalent_xml(rewritten, tree)
		and Comments.people(Text("")).people == []
}

## Split threads read back as they were written: a reply names its parent's
## last paragraph, done follows the resolved mark, and a durable identifier
## and UTC date are written for a comment that has them, keeping what else
## the shell's extensible entry for that durable identifier holds. A
## comment without a paragraph has no entries, so its thread is not
## written.
expect {
	stamp = WmlRead.date_time("2026-05-04T09:15:00Z")?
	comment = |parent, resolved, durable_id, utc_date| { author: "Ada Reviewer", initials: Unset, date: Unset, content: [], preserved: [], parent, resolved, durable_id, utc_date }
	comments = [comment(Unset, Bool.True, DurableId(0x5A), Date(stamp)), comment(Parent(0), Bool.True, DurableId(0xB), Unset), comment(Parent(0), Bool.False, Unset, Unset)]
	namespaces = "xmlns:w='${wordprocessingml}' xmlns:w14='${w14}' xmlns:w16cex='${w16cex}' xmlns:cr='urn:example:reactions'"
	part = XmlTree.parse("<w:comments ${namespaces}><w:comment w:id='0'><w:p w14:paraId='0000000A'/></w:comment><w:comment w:id='1'><w:p w14:paraId='0000000B'/></w:comment><w:comment w:id='2'/></w:comments>".to_utf8(), {})?
	shell = XmlTree.parse("<w16cex:commentsExtensible ${namespaces}><w16cex:commentExtensible w16cex:durableId='0000005a' w16cex:dateUtc='2020-01-01T00:00:00Z'><cr:reactions/></w16cex:commentExtensible></w16cex:commentsExtensible>".to_utf8(), {})?
	split = Comments.split(comments, ["0000000A", "0000000B", ""], { extended: Text(""), ids: Text(""), extensible: shell }, { extended: [], ids: [], extensible: [], diagnostics: [] })
	read = WmlRead.comments(part, { relationships: [], footnotes: [], endnotes: [], comments: [] }).comments
	threaded = Comments.threads(read, { comments: part, extended: split.extended, ids: split.ids, extensible: split.extensible })
	extensible = match (Str.from_utf8(XmlTree.render(split.extensible)?) ?? "").split_first("<w16cex:commentExtensible ") {
		Ok({ before: _, after }) => after
		Err(_) => ""
	}
	threaded.map(|found| (found.parent, found.resolved, found.durable_id, found.utc_date))
		== [(Unset, Bool.True, DurableId(0x5A), Date(stamp)), (Parent(0), Bool.True, DurableId(0xB), Unset), (Unset, Bool.False, Unset, Unset)]
		and extensible == "w16cex:durableId=\"0000005A\" w16cex:dateUtc=\"2026-05-04T09:15:00Z\"><cr:reactions/></w16cex:commentExtensible><w16cex:commentExtensible w16cex:durableId=\"0000000B\"/></w16cex:commentsExtensible>"
}

## A people part written from people reads back as those people.
expect {
	people = [{ author: "Ada Reviewer", presence: Presence({ provider: "None", user: "Ada Reviewer" }) }, { author: "Lin Editor", presence: Unset }]
	Comments.people(Comments.people_part(Text(""), people)).people == people
}

## Entries the model does not hold as written are kept, each with a
## diagnostic: a parent that is no comment, an entry naming no comment, a
## durable identifier that is not one, and extensible entries without a
## comment or with a date that is not one. Split writes them back as read
## before the written entries, so the parts read back as the same threads
## and keep the same entries.
expect {
	namespaces = "xmlns:w='${wordprocessingml}' xmlns:w14='${w14}' xmlns:w15='${w15}' xmlns:w16cid='${w16cid}' xmlns:w16cex='${w16cex}'"
	tree = |root, content| XmlTree.parse("<${root} ${namespaces}>${content}</${root}>".to_utf8(), {}) ?? Text("")
	comments_part = |first, second| tree("w:comments", "<w:comment w:id='0'><w:p w14:paraId='${first}'/></w:comment><w:comment w:id='1'><w:p w14:paraId='${second}'/></w:comment>")
	parts = {
		comments: comments_part("0A", "0B"),
		extended: tree("w15:commentsEx", "<w15:commentEx w15:paraId='0A' w15:done='1'/><w15:commentEx w15:paraId='0B' w15:paraIdParent='FF' w15:done='0'/><w15:commentEx w15:paraId='EE' w15:done='0'/>"),
		ids: tree("w16cid:commentsIds", "<w16cid:commentId w16cid:paraId='0A' w16cid:durableId='zz'/><w16cid:commentId w16cid:paraId='0A' w16cid:durableId='00000001'/>"),
		extensible: tree("w16cex:commentsExtensible", "<w16cex:commentExtensible w16cex:durableId='00000001' w16cex:dateUtc='later'/><w16cex:commentExtensible w16cex:durableId='00000009'/>"),
	}
	read = WmlRead.comments(parts.comments, { relationships: [], footnotes: [], endnotes: [], comments: [] }).comments
	threaded = Comments.threads(read, parts)
	kept = Comments.kept(parts)
	split = Comments.split(threaded, ["00000001", "00000002"], { extended: parts.extended, ids: parts.ids, extensible: parts.extensible }, kept)
	written = { comments: comments_part("00000001", "00000002"), extended: split.extended, ids: split.ids, extensible: split.extensible }
	again = Comments.kept(written)
	kept.diagnostics
		== [
			NotApplied({ element: "commentEx", key: "0B" }),
			NotApplied({ element: "commentEx", key: "EE" }),
			NotApplied({ element: "commentId", key: "0A" }),
			NotApplied({ element: "commentExtensible", key: "00000001" }),
			NotApplied({ element: "commentExtensible", key: "00000009" }),
		]
		and Comments.threads(read, written) == threaded
		and again.extended == kept.extended
		and again.ids == kept.ids
		and again.extensible == kept.extensible
}
