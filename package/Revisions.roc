## A body's tracked changes: each change with its authorship, what it
## changed and the move it is part of, and the body's text as it stands, with
## every change accepted or with every change rejected.
##
## A tracked change is a [Document.Revision] in a paragraph's content, an
## insertion, a deletion, or a move's source or destination; a change of a
## paragraph's mark, a table's row or a cell; or a change of a run's,
## paragraph's, section's, table's, row's or cell's properties. Changes are
## identified by their place among the body's changes in reading order, so
## the identifiers a document writes for them are never needed.
import Document

Revisions :: [].{

	## A tracked change as [Revisions.list] finds it: its place among the
	## body's changes in reading order, which identifies it; its kind and
	## what it changed; its author and date; the content it covers; the move
	## it is part of, named by the range of its side that it stands in, for a
	## move's source or destination; its text; and whether it follows the
	## change listed before it directly, with nothing between them, as one
	## change split in two does, or a change running on over a paragraph's
	## mark.
	##
	## Content, a paragraph's mark and a row are inserted or deleted, content
	## and a mark also moved away or here; a cell is inserted, deleted or
	## merged with the cell above; and the properties of a run, a paragraph,
	## a section, a table, a row or a cell are changed, which is `Formatting`.
	##
	## A content change covers the content its [Document.Revision] holds, a
	## run's formatting the run, and a paragraph's formatting the paragraph's
	## content; the other changes cover none. A change's text is the text of
	## what it covers as [Document.paragraph_text] counts text, with every
	## change inside it shown, so a deletion's text is the text it deleted; a
	## change of a paragraph's mark has a line feed, the text a mark ends a
	## paragraph with, and the other changes have none.
	Listed : {
		id : U64,
		kind : Kind,
		of : Subject,
		author : Str,
		date : [Unset, Date(Document.Timestamp)],
		content : List(Document.Inline),
		move : [Unpaired, Move(Str)],
		text : Str,
		follows : Bool,
	}

	## The kinds of tracked change.
	Kind : [Insertion, Deletion, MoveSource, MoveDestination, Merge, Formatting]

	## What a tracked change changed: paragraph content, a paragraph's mark,
	## or a run, paragraph, section, table, row or cell.
	Subject : [Content, ParagraphMark, Run, Paragraph, Section, Table, Row, Cell]

	## Which text a body has: its current text, the tracked changes as they
	## stand, which is the text a reader sees with changes shown, deleted
	## text left out and deleted rows and cells kept, empty of the text they
	## deleted; or the text with every change accepted, so insertions and
	## moved content stand where they arrived and deletions, deleted rows and
	## deleted cells are gone; or with every change rejected, so deletions
	## and moved content stand where they were and insertions, inserted rows
	## and inserted cells are gone.
	View : [Current, Final, Original]

	## The tracked changes of blocks in reading order, through tables,
	## content controls, hyperlinks and fields, a change inside another after
	## it. A paragraph's formatting comes before the changes of its content
	## and its mark's changes after them, in the order inserted, deleted,
	## moved away, moved here; a table's formatting comes before its rows, a
	## row's insertion, deletion and formatting before its cells, and a
	## cell's insertion, deletion or merge and its formatting before its
	## content.
	list : List(Document.Block) -> List(Listed)
	list = |blocks| blocks.fold({ listed: List.with_capacity(16), sources: [], destinations: [], previous: Err(NoChange) }, list_block).listed

	## A paragraph's text in a view. The current and final text are the
	## current text of [Document.paragraph_text]; the original text has
	## inserted and moved-in text left out and deleted and moved-away text
	## in.
	paragraph_text : Document.Paragraph, View -> Str
	paragraph_text = |paragraph, view|
		match view {
			Current | Final => Document.paragraph_text(paragraph)
			Original => Str.from_utf8(paragraph.content.fold(List.with_capacity(64), |text, inline| inline_bytes(text, inline, Original))) ?? ""
		}

	## The text of blocks in a view: every paragraph's text, as
	## [Revisions.paragraph_text] gives it, followed by a line feed, in
	## reading order, including the paragraphs in tables and content
	## controls, except in the rows and cells the view takes away. A
	## paragraph whose mark the view takes away runs on into the next
	## paragraph without a line feed, unless a table, row or cell begins or
	## ends between them: in the current and final text a mark deleted or
	## moved away, as [Document.joins_next] says, and in the original text a
	## mark inserted or moved in.
	text : List(Document.Block), View -> Str
	text = |blocks, view| {
		var $state = { text: List.with_capacity(1024), joining: Bool.False }
		for block in blocks {
			$state = block_text($state, block, view)
		}
		Str.from_utf8(line_end($state).text) ?? ""
	}
}

# The changes listed so far, the names of the moves' source and destination
# ranges open where they end, innermost last, and the change that the next
# one follows directly, if it comes next.
Walk : { listed : List(Revisions.Listed), sources : List(Str), destinations : List(Str), previous : Try(U64, [NoChange]) }

# A change of structure, listed where it stands, which no change follows.
Structural : { kind : Revisions.Kind, of : Revisions.Subject, author : Str, date : [Unset, Date(Document.Timestamp)] }

list_block : Walk, Document.Block -> Walk
list_block = |walk, block|
	match block {
		Paragraph(paragraph) => {
			formatted = structural(walk, formatting(Paragraph, paragraph.properties.change), paragraph.content)
			after = list_content(formatted, paragraph.content)
			mark = paragraph.properties.mark
			mark.fold(
				{ ..after, previous: if (mark.is_empty()) Err(NoChange) else after.previous },
				|marked, change| {
					id = marked.listed.len()
					move = match change.kind {
						MoveSource => innermost(marked.sources)
						MoveDestination => innermost(marked.destinations)
						_ => Unpaired
					}
					listed = { id, kind: content_kind(change.kind), of: ParagraphMark, author: change.author, date: change.date, content: [], move, text: "\n", follows: marked.previous == Ok(id) }
					{ ..marked, listed: List.append(marked.listed, listed), previous: Ok(id + 1) }
				},
			)
		}

		Table(table) => {
			formatted = structural({ ..walk, previous: Err(NoChange) }, formatting(Table, table.properties.change), [])
			{ ..Document.table_rows(table).fold(formatted, list_row), previous: Err(NoChange) }
		}

		Container({ element: _, content }) => content.fold(walk, list_block)
		Section(section) => structural(walk, formatting(Section, section.change), [])
		CommentStart(_) => { ..walk, previous: Err(NoChange) }
		CommentEnd(_) => { ..walk, previous: Err(NoChange) }
		Preserved(_) => { ..walk, previous: Err(NoChange) }
	}

list_row : Walk, Document.Row -> Walk
list_row = |walk, row| {
	changes = List.join([tracked(Insertion, Row, row.properties.inserted), tracked(Deletion, Row, row.properties.deleted), formatting(Row, row.properties.change)])
	Document.row_cells(row).fold(structural({ ..walk, previous: Err(NoChange) }, changes, []), list_cell)
}

list_cell : Walk, Document.Cell -> Walk
list_cell = |walk, cell| {
	revised = match cell.properties.revision {
		Inserted(change) => tracked(Insertion, Cell, Tracked(change))
		Deleted(change) => tracked(Deletion, Cell, Tracked(change))
		Merged(merged) => [{ kind: Merge, of: Cell, author: merged.author, date: merged.date }]
		Unset => []
	}
	cell.content.fold(structural({ ..walk, previous: Err(NoChange) }, List.concat(revised, formatting(Cell, cell.properties.change)), []), list_block)
}

# A tracked insertion or deletion of structure, if it was made.
tracked : Revisions.Kind, Revisions.Subject, Document.Tracked -> List(Structural)
tracked = |kind, of, made|
	match made {
		Tracked(change) => [{ kind, of, author: change.author, date: change.date }]
		Unset => []
	}

# A tracked change of properties, if there is one.
formatting : Revisions.Subject, List(Document.PropertyChange(p)) -> List(Structural)
formatting = |of, changes| changes.map(|changed| { kind: Formatting, of, author: changed.author, date: changed.date })

# Changes of structure listed in order, a paragraph's formatting covering its
# content; nothing that follows them follows them directly.
structural : Walk, List(Structural), List(Document.Inline) -> Walk
structural = |walk, changes, covered|
	if changes.is_empty() {
		walk
	} else {
		changes.fold(
			{ ..walk, previous: Err(NoChange) },
			|out, change| {
				text = if (change.of == Paragraph) Str.from_utf8(covered.fold(List.with_capacity(64), |bytes, inner| inline_bytes(bytes, inner, Shown))) ?? "" else ""
				listed = { id: out.listed.len(), kind: change.kind, of: change.of, author: change.author, date: change.date, content: if (change.of == Paragraph) covered else [], move: Unpaired, text, follows: Bool.False }
				{ ..out, listed: List.append(out.listed, listed) }
			},
		)
	}

# List the changes of content. A change follows the one before when the
# inline before it is that change, with no change listed inside it, or, at
# the start of a paragraph, when the paragraph before ends with a change of
# its mark.
list_content : Walk, List(Document.Inline) -> Walk
list_content = |walk, content| {
	var $walk = walk
	var $previous = walk.previous
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
					kind: content_kind(revision.kind),
					of: Content,
					author: revision.author,
					date: revision.date,
					content: revision.content,
					move,
					text: Str.from_utf8(revision.content.fold(List.with_capacity(16), |text, inner| inline_bytes(text, inner, Shown))) ?? "",
					follows: $previous == Ok(id),
				}
				$walk = list_content({ ..$walk, listed: List.append($walk.listed, listed), previous: Err(NoChange) }, revision.content)
				$previous = if ($walk.listed.len() == id + 1) Ok(id + 1) else Err(NoChange)
			}

			Run(run) =>
				match run.properties.change.first() {
					Ok(changed) => {
						id = $walk.listed.len()
						listed = {
							id,
							kind: Formatting,
							of: Run,
							author: changed.author,
							date: changed.date,
							content: [inline],
							move: Unpaired,
							text: Str.from_utf8(inline_bytes(List.with_capacity(16), inline, Shown)) ?? "",
							follows: $previous == Ok(id),
						}
						$walk = { ..$walk, listed: List.append($walk.listed, listed) }
						$previous = Ok(id + 1)
					}

					Err(_) => {
						$previous = Err(NoChange)
					}
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
				$walk = list_content({ ..$walk, previous: Err(NoChange) }, inner)
				$previous = Err(NoChange)
			}

			SimpleField({ code: _, preserved: _, content: inner }) => {
				$walk = list_content({ ..$walk, previous: Err(NoChange) }, inner)
				$previous = Err(NoChange)
			}

			Container({ element: _, content: inner }) => {
				$walk = list_content({ ..$walk, previous: Err(NoChange) }, inner)
				$previous = Err(NoChange)
			}

			_ => {
				$previous = Err(NoChange)
			}
		}
	}
	{ ..$walk, previous: $previous }
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

# The kind of a change of content.
content_kind : Document.RevisionKind -> Revisions.Kind
content_kind = |kind|
	match kind {
		Insertion => Insertion
		Deletion => Deletion
		MoveSource => MoveSource
		MoveDestination => MoveDestination
	}

# An inline's text in a view, or with every change shown, appended as UTF-8.
inline_bytes : List(U8), Document.Inline, [Current, Final, Original, Shown] -> List(U8)
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
hidden : Document.RevisionKind, [Current, Final, Original, Shown] -> Bool
hidden = |kind, view|
	match view {
		Current | Final => kind == Deletion or kind == MoveSource
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
				Document.table_rows(table).drop_if(|row| row_taken(row.properties, view)).fold(
					line_end(state),
					|row_state, row| line_end(Document.row_cells(row).drop_if(|cell| cell_taken(cell.properties.revision, view)).fold(line_end(row_state), |cell_state, cell| line_end(cell.content.fold(line_end(cell_state), |inner, child| block_text(inner, child, view))))),
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

# Whether a view takes away a paragraph's mark: in the current and final
# text a mark deleted or moved away, in the original text one inserted or
# moved here.
joins_next : Document.Paragraph, Revisions.View -> Bool
joins_next = |paragraph, view|
	match view {
		Current | Final => Document.joins_next(paragraph)
		Original => paragraph.properties.mark.any(|change| change.kind == Insertion or change.kind == MoveDestination)
	}

# Whether a view takes away a row: the final text a deleted one, the
# original text an inserted one.
row_taken : Document.RowProperties, Revisions.View -> Bool
row_taken = |properties, view|
	match view {
		Current => Bool.False
		Final => properties.deleted != Unset
		Original => properties.inserted != Unset
	}

# Whether a view takes away a cell: the final text a deleted one, the
# original text an inserted one.
cell_taken : [Unset, Inserted(Document.Change), Deleted(Document.Change), Merged(Document.CellMerge)], Revisions.View -> Bool
cell_taken = |revision, view|
	match (revision, view) {
		(Deleted(_), Final) => Bool.True
		(Inserted(_), Original) => Bool.True
		_ => Bool.False
	}
