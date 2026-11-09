## A body's tracked changes: each change with its authorship, the content it
## covers and the move it is part of, and the body's text with every change
## accepted or every change rejected.
##
## A tracked change is a [Document.Revision] in a paragraph's content: an
## insertion, a deletion, or a move's source or destination. Changes are
## identified by their place among the body's changes in reading order, so
## the identifiers a document writes for them are never needed.
import Document
import XmlTree

Revisions :: [].{

	## A tracked change as [Revisions.list] finds it: its place among the
	## body's changes in reading order, which identifies it; its kind, author,
	## date and content as the [Document.Revision] holds them; the move it is
	## part of, named by the range of its side that it stands in, for a move's
	## source or destination; its text; and whether it follows the change
	## listed before it directly, with nothing between them in the same
	## content, as one change split in two does.
	##
	## A change's text is its content's text as [Document.paragraph_text]
	## counts text, with every change inside it shown, so a deletion's text
	## is the text it deleted.
	Listed : {
		id : U64,
		kind : Document.RevisionKind,
		author : Str,
		date : [Unset, Date(Document.Timestamp)],
		content : List(Document.Inline),
		move : [Unpaired, Move(Str)],
		text : Str,
		follows : Bool,
	}

	## Which text a body has with its tracked changes resolved: with every
	## change accepted, so insertions and moved content stand where they
	## arrived and deletions are gone, or with every change rejected, so
	## deletions and moved content stand where they were and insertions are
	## gone.
	View : [Final, Original]

	## The tracked changes of blocks in reading order, through tables,
	## content controls, hyperlinks and fields, a change inside another after
	## it.
	list : List(Document.Block) -> List(Listed)
	list = |blocks| blocks.fold({ listed: List.with_capacity(16), sources: [], destinations: [] }, list_block).listed

	## A paragraph's text in a view. The final text is the current text of
	## [Document.paragraph_text]; the original text has inserted and moved-in
	## text left out and deleted and moved-away text in.
	paragraph_text : Document.Paragraph, View -> Str
	paragraph_text = |paragraph, view|
		match view {
			Final => Document.paragraph_text(paragraph)
			Original => Str.from_utf8(paragraph.content.fold(List.with_capacity(64), |text, inline| inline_bytes(text, inline, Original))) ?? ""
		}

	## The text of blocks in a view: every paragraph's text, as
	## [Revisions.paragraph_text] gives it, followed by a line feed, in
	## reading order, including the paragraphs in tables and content
	## controls. A paragraph whose mark the view takes away runs on into the
	## next paragraph without a line feed, unless a table, row or cell begins
	## or ends between them: in the final text a mark deleted or moved away,
	## as [Document.joins_next] says, and in the original text a mark
	## inserted or moved in.
	text : List(Document.Block), View -> Str
	text = |blocks, view| {
		var $state = { text: List.with_capacity(1024), joining: Bool.False }
		for block in blocks {
			$state = block_text($state, block, view)
		}
		Str.from_utf8(line_end($state).text) ?? ""
	}
}

wordprocessingml : Str
wordprocessingml = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

# The changes listed so far, and the names of the moves' source and
# destination ranges open where they end, innermost last.
Walk : { listed : List(Revisions.Listed), sources : List(Str), destinations : List(Str) }

list_block : Walk, Document.Block -> Walk
list_block = |walk, block|
	match block {
		Paragraph(paragraph) => list_content(walk, paragraph.content)
		Table(table) => Document.table_rows(table).fold(walk, |by_row, row| Document.row_cells(row).fold(by_row, |by_cell, cell| cell.content.fold(by_cell, list_block)))
		Container({ element: _, content }) => content.fold(walk, list_block)
		Section(_) => walk
		CommentStart(_) => walk
		CommentEnd(_) => walk
		Preserved(_) => walk
	}

# List the changes of content. A change follows the one before when the
# inline before it is that change, with no change listed inside it.
list_content : Walk, List(Document.Inline) -> Walk
list_content = |walk, content| {
	var $walk = walk
	var $previous = Err(NoChange)
	for inline in content {
		match inline {
			Revision(revision) => {
				id = $walk.listed.len()
				move = match revision.kind {
					MoveSource => innermost($walk.sources)
					MoveDestination => innermost($walk.destinations)
					_ => Unpaired
				}
				listed = {
					id,
					kind: revision.kind,
					author: revision.author,
					date: revision.date,
					content: revision.content,
					move,
					text: Str.from_utf8(revision.content.fold(List.with_capacity(16), |text, inner| inline_bytes(text, inner, Shown))) ?? "",
					follows: $previous == Ok(id),
				}
				$walk = list_content({ ..$walk, listed: List.append($walk.listed, listed) }, revision.content)
				$previous = if ($walk.listed.len() == id + 1) Ok(id + 1) else Err(NoChange)
			}

			MoveStart({ side: Source, name, author: _, date: _, preserved: _ }) => {
				$walk = { ..$walk, sources: List.append($walk.sources, name) }
				$previous = Err(NoChange)
			}

			MoveStart({ side: Destination, name, author: _, date: _, preserved: _ }) => {
				$walk = { ..$walk, destinations: List.append($walk.destinations, name) }
				$previous = Err(NoChange)
			}

			MoveEnd({ side: Source, name }) => {
				$walk = { ..$walk, sources: closed($walk.sources, name) }
				$previous = Err(NoChange)
			}

			MoveEnd({ side: Destination, name }) => {
				$walk = { ..$walk, destinations: closed($walk.destinations, name) }
				$previous = Err(NoChange)
			}

			Hyperlink({ target: _, preserved: _, content: inner }) => {
				$walk = list_content($walk, inner)
				$previous = Err(NoChange)
			}

			SimpleField({ code: _, preserved: _, content: inner }) => {
				$walk = list_content($walk, inner)
				$previous = Err(NoChange)
			}

			Container({ element: _, content: inner }) => {
				$walk = list_content($walk, inner)
				$previous = Err(NoChange)
			}

			_ => {
				$previous = Err(NoChange)
			}
		}
	}
	$walk
}

innermost : List(Str) -> [Unpaired, Move(Str)]
innermost = |names|
	match names.last() {
		Ok(name) => Move(name)
		Err(_) => Unpaired
	}

# The open ranges without the innermost one of this name.
closed : List(Str), Str -> List(Str)
closed = |names, name| {
	var $index = names.len()
	while $index > 0 {
		$index = $index - 1
		if names.get($index) == Ok(name) {
			return List.concat(names.sublist({ start: 0, len: $index }), names.sublist({ start: $index + 1, len: names.len() - $index - 1 }))
		}
	}
	names
}

# An inline's text in a view, or with every change shown, appended as UTF-8.
inline_bytes : List(U8), Document.Inline, [Final, Original, Shown] -> List(U8)
inline_bytes = |text, inline, view|
	match inline {
		Revision(revision) if hidden(revision.kind, view) => text
		Revision(revision) => revision.content.fold(text, |inner, child| inline_bytes(inner, child, view))
		Hyperlink({ target: _, preserved: _, content }) => content.fold(text, |inner, child| inline_bytes(inner, child, view))
		SimpleField({ code: _, preserved: _, content }) => content.fold(text, |inner, child| inline_bytes(inner, child, view))
		Container({ element: _, content }) => content.fold(text, |inner, child| inline_bytes(inner, child, view))
		_ => List.concat(text, Document.inline_text(inline).to_utf8())
	}

# Whether a view leaves out a change's content.
hidden : Document.RevisionKind, [Final, Original, Shown] -> Bool
hidden = |kind, view|
	match view {
		Final => kind == Deletion or kind == MoveSource
		Original => kind == Insertion or kind == MoveDestination
		Shown => Bool.False
	}

TextState : { text : List(U8), joining : Bool }

block_text : TextState, Document.Block, Revisions.View -> TextState
block_text = |state, block, view|
	match block {
		Paragraph(paragraph) => {
			text = List.concat(state.text, Revisions.paragraph_text(paragraph, view).to_utf8())
			if joins_next(paragraph, view) {
				{ text, joining: Bool.True }
			} else {
				{ text: List.append(text, 10), joining: Bool.False }
			}
		}

		Table(table) =>
			line_end(
				Document.table_rows(table).fold(
					line_end(state),
					|row_state, row| line_end(Document.row_cells(row).fold(line_end(row_state), |cell_state, cell| line_end(cell.content.fold(line_end(cell_state), |inner, child| block_text(inner, child, view))))),
				),
			)

		Container({ element: _, content }) => content.fold(state, |inner, child| block_text(inner, child, view))
		Section(_) => state
		CommentStart(_) => state
		CommentEnd(_) => state
		Preserved(_) => state
	}

# The line feed a joining paragraph owes where nothing follows it to join.
line_end : TextState -> TextState
line_end = |state| if (state.joining) { text: List.append(state.text, 10), joining: Bool.False } else state

# Whether a view takes away a paragraph's mark: in the final text a mark
# deleted or moved away, in the original text one inserted or moved in, as
# the paragraph's mark properties say.
joins_next : Document.Paragraph, Revisions.View -> Bool
joins_next = |paragraph, view|
	match view {
		Final => Document.joins_next(paragraph)
		Original =>
			paragraph.properties.preserved.any(
				|property|
					match property {
						Element(element) if is_w(element.name, "rPr") => element.children.any(|child| is_element_in(child, ["ins", "moveTo"]))
						_ => Bool.False
					},
			)
	}

is_w : XmlTree.Name, Str -> Bool
is_w = |name, local| name.namespace == Uri(wordprocessingml) and name.local == local

is_element_in : XmlTree.Node, List(Str) -> Bool
is_element_in = |node, locals|
	match node {
		Element(element) => element.name.namespace == Uri(wordprocessingml) and locals.contains(element.name.local)
		Text(_) => Bool.False
	}
