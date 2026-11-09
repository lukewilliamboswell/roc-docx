## A body's tracked changes: each change with its authorship, what it
## changed and the move it is part of, and the body's text as it stands, with
## every change accepted or with every change rejected; the algebra that
## accepts and rejects them; and edits of the text made silently or as
## tracked changes.
##
## A tracked change is a [Document.Revision] in a paragraph's content, an
## insertion, a deletion, or a move's source or destination; a change of a
## paragraph's mark, a table's row or a cell; or a change of a run's,
## paragraph's, section's, table's, row's or cell's properties. Changes are
## identified by their place among the body's changes in reading order, so
## the identifiers a document writes for them are never needed.
import Document
import WmlRead

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

	## Which tracked changes an accept or a reject applies to: every change;
	## the changes one author made; those made from `from` up to but not
	## including `until`, each an XML Schema `dateTime` such as
	## `2026-05-07T09:00:00Z`, compared as instants, so a change without a
	## date is in no range; or the changes with these ids, as
	## [Revisions.list] gives them.
	Selection : [All, By(Str), Between({ from : Str, until : Str }), Ids(List(U64))]

	## The blocks with the selected changes accepted, every other change as
	## it was. Accepting an insertion, or content moved here, keeps its
	## content without the change; accepting a deletion, or content moved
	## away, removes the content, leaving the comment and bookmark boundaries
	## and comment references in it where it was. An accepted change of
	## properties keeps the properties and drops those before it. An
	## accepted inserted row or cell stays; an accepted deleted row or cell
	## goes, with its content, and a table left without rows goes with it.
	## An accepted merge of a cell keeps the merge. A paragraph whose
	## accepted mark change deletes its mark, or moves it away, joins the
	## next paragraph, as [Revisions.text] runs it on: the next paragraph
	## keeps its own properties and begins with the joined paragraph's
	## content, the end of a section the mark held goes with it, and a
	## paragraph with no paragraph after it to join before a table, the end
	## of its cell or the end of the body stays. A move's ranges go once
	## every change paired with them is accepted or rejected.
	##
	## Accepting every change gives blocks whose current text is the final
	## text of the blocks they came from. A date that is not a date and time
	## fails.
	accept : List(Document.Block), Selection -> Try(List(Document.Block), [NotADate(Str)])
	accept = |blocks, selection| resolve(blocks, Accept, selection)

	## The blocks with the selected changes rejected, the inverse of
	## [Revisions.accept] for each: a rejected insertion, or content moved
	## here, goes, leaving its boundaries and references; a rejected deletion,
	## or content moved away, keeps its content without the change; a
	## rejected change of properties restores the properties before it; a
	## rejected inserted row or cell goes and a rejected deleted one stays; a
	## rejected merge restores the cell's vertical merge before it; and a
	## paragraph whose rejected mark change takes away a mark inserted or
	## moved here joins the next paragraph. Rejecting every change gives
	## blocks whose current text is the original text of the blocks they came
	## from.
	reject : List(Document.Block), Selection -> Try(List(Document.Block), [NotADate(Str)])
	reject = |blocks, selection| resolve(blocks, Reject, selection)

	## How an edit is made: silently, changing the content as it stands, or
	## as tracked changes by an author, with the date the application gives
	## as an XML Schema `dateTime`, since the package reads no clock. The same
	## edit is never both.
	Context : [Untracked, Tracked({ author : Str, date : [Unset, Date(Str)] })]

	## The blocks with the current text from byte `start` up to byte `end`
	## replaced by `replacement`, as offsets into the current text
	## [Revisions.text] gives, which is [Docx.text].
	##
	## The span's characters are removed, and so is the content without text
	## strictly inside it, such as a picture, a note reference or a field's
	## marks, but not range boundaries or comment references; text already
	## deleted has no width and stays as it is. The replacement goes just
	## after the character before `end`, inside the hyperlink, field or
	## change that character is in unless it ends its content, or at the
	## start of the paragraph where `end` begins a line. It takes the
	## character properties of the run the character before it is in, or at
	## the start of a paragraph those of the paragraph's first run, without
	## their tracked change; a tab in it is a tab.
	##
	## Untracked, the span's content is removed and the replacement added.
	## Tracked, the span's content stays inside deletions and the replacement
	## is an insertion, both by the context's author at its date, so
	## accepting the changes gives the untracked edit and rejecting them
	## gives the blocks before it. Deleting inserted text puts a deletion
	## inside the insertion; deleting all of an insertion's text untracked
	## removes the insertion.
	##
	## An empty span inserts and an empty replacement deletes. A span that
	## does not lie within the text, ends before it starts, or inserts where
	## no line continues fails, and so does one that holds a line feed, which
	## ends a paragraph or a table's row or cell; one that starts or ends
	## inside a character; a replacement holding a line feed; and a date that
	## is not a date and time.
	replace : List(Document.Block), { start : U64, end : U64 }, Str, Context -> Try(List(Document.Block), [OutsideText({ start : U64, end : U64 }), NotACharacterBoundary(U64), LineFeedInSpan({ start : U64, end : U64 }), LineFeedInText(Str), NotADate(Str)])
	replace = |blocks, span, replacement, context| {
		if replacement.to_utf8().contains(10) {
			return Err(LineFeedInText(replacement))
		}
		made = match context {
			Untracked => Untracked
			Tracked({ author, date }) =>
				match date {
					Unset => Tracked({ author, date: Unset, preserved: [] })
					Date(written) => Tracked({ author, date: Date(WmlRead.date_time(written) ? |_| NotADate(written)), preserved: [] })
				}
		}
		if span.start > span.end {
			return Err(OutsideText(span))
		}
		start = { at: 0, joining: Bool.False, fresh: Bool.True, start: span.start, end: span.end, text: replacement, made, placed: replacement == "", pending: Bool.False, properties: Document.no_run_properties, problem: Fine }
		walked = edit_blocks(blocks, start)
		ended = edit_line(walked.state)
		if span.end > ended.at or !ended.placed {
			return Err(OutsideText(span))
		}
		match ended.problem {
			Boundary(at) => Err(NotACharacterBoundary(at))
			LineFeed => Err(LineFeedInSpan(span))
			Fine => Ok(walked.blocks)
		}
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

# A selection with its dates read as instants and its ids as a set.
Chosen : [All, By(Str), Between(I64, I64), Ids(Set(U64))]

# Resolving changes: whether the selected ones are accepted or rejected,
# which are selected, the id the next change has, the names of the moves'
# ranges open where they end, innermost last, as [Revisions.list] pairs
# changes with them, and the ranges, by side and name, paired with a
# resolved change and with one that stays.
Resolving : {
	action : [Accept, Reject],
	chosen : Chosen,
	next : U64,
	sources : List(Str),
	destinations : List(Str),
	resolved : Set(Str),
	kept : Set(Str),
}

# Blocks resolved, and a paragraph whose mark went, still to join the next
# paragraph.
Resolved : { blocks : List(Document.Block), state : Resolving, carried : [Nothing, Carried(Document.Paragraph)] }

resolve : List(Document.Block), [Accept, Reject], Revisions.Selection -> Try(List(Document.Block), [NotADate(Str)])
resolve = |blocks, action, selection| {
	chosen = match selection {
		All => All
		By(author) => By(author)
		Between({ from, until }) => Between((WmlRead.date_time(from) ? |_| NotADate(from)).utc_seconds, (WmlRead.date_time(until) ? |_| NotADate(until)).utc_seconds)
		Ids(ids) => Ids(ids.fold(Set.with_capacity(ids.len()), |set, id| set.insert(id)))
	}
	start = { action, chosen, next: 0, sources: [], destinations: [], resolved: Set.with_capacity(4), kept: Set.with_capacity(4) }
	done = resolve_blocks(blocks, start, Nothing, Bool.True)
	resolved = carry_out(done.blocks, done.carried)
	gone = done.state.resolved.keep_if(|range| !done.state.kept.contains(range))
	Ok(if (gone.is_empty()) resolved else resolved.map(|block| inlines_of_block(block, |content| without_ranges(content, gone))))
}

# Whether a change is selected, and the state with the next id taken.
take : Resolving, Str, [Unset, Date(Document.Timestamp)] -> { state : Resolving, chosen : Bool }
take = |state, author, date| {
	chosen = match state.chosen {
		All => Bool.True
		By(name) => author == name
		Between(from, until) =>
			match date {
				Date(stamp) => stamp.utc_seconds >= from and stamp.utc_seconds < until
				Unset => Bool.False
			}

		Ids(ids) => ids.contains(state.next)
	}
	{ state: { ..state, next: state.next + 1 }, chosen }
}

# Whether content, or a mark, stands once a change of this kind is resolved:
# an insertion or what moved here accepted, a deletion or what moved away
# rejected.
stands : Document.RevisionKind, [Accept, Reject] -> Bool
stands = |kind, action|
	match action {
		Accept => kind == Insertion or kind == MoveDestination
		Reject => kind == Deletion or kind == MoveSource
	}

# Record a move's change against the innermost open range of its side, as
# resolved or as staying.
paired : Resolving, Document.RevisionKind, Bool -> Resolving
paired = |state, kind, chosen| {
	range = match kind {
		MoveSource => state.sources.last().map_ok(|name| range_key(Source, name))
		MoveDestination => state.destinations.last().map_ok(|name| range_key(Destination, name))
		_ => Err(ListWasEmpty)
	}
	match range {
		Ok(key) if chosen => { ..state, resolved: state.resolved.insert(key) }
		Ok(key) => { ..state, kept: state.kept.insert(key) }
		Err(_) => state
	}
}

# A tracked change of properties, the first of `changes`, resolved: whether
# it stays, was accepted, or was rejected with the properties before it.
# Every change in the list takes an id, as [Revisions.list] lists them.
property_of : Resolving, List(Document.PropertyChange(p)) -> { state : Resolving, outcome : [Stays, Accepted, Rejected(p)] }
property_of = |state, changes|
	match changes.first() {
		Ok(changed) => {
			taken = take(state, changed.author, changed.date)
			outcome = if !taken.chosen {
				Stays
			} else {
				match state.action {
					Accept => Accepted
					Reject => Rejected(changed.previous)
				}
			}
			{ state: { ..taken.state, next: state.next + changes.len() }, outcome }
		}

		Err(_) => { state, outcome: Stays }
	}

# A tracked insertion or deletion of a row resolved: the state, whether it
# was selected, and what the row's properties hold of it.
tracked_of : Resolving, Document.Tracked -> { state : Resolving, chosen : Bool, tracked : Document.Tracked }
tracked_of = |state, made|
	match made {
		Tracked(change) => {
			taken = take(state, change.author, change.date)
			{ state: taken.state, chosen: taken.chosen, tracked: if (taken.chosen) Unset else made }
		}

		Unset => { state, chosen: Bool.False, tracked: made }
	}

# The blocks with a paragraph still to join emitted where nothing follows
# for it to join.
carry_out : List(Document.Block), [Nothing, Carried(Document.Paragraph)] -> List(Document.Block)
carry_out = |blocks, carried|
	match carried {
		Carried(paragraph) => List.append(blocks, Paragraph(paragraph))
		Nothing => blocks
	}

# Blocks resolved in order. A paragraph whose mark goes is carried into the
# next paragraph, through content controls, comment boundaries and the end of
# a section, which goes with the mark that held it unless it ends the body;
# a table takes it as it is.
resolve_blocks : List(Document.Block), Resolving, [Nothing, Carried(Document.Paragraph)], Bool -> Resolved
resolve_blocks = |blocks, state, carried, body| {
	var $state = state
	var $carried = carried
	var $out = List.with_capacity(blocks.len())
	var $index = 0.U64
	for block in blocks {
		$index = $index + 1
		match block {
			Paragraph(paragraph) => {
				done = resolve_paragraph(paragraph, $state)
				$state = done.state
				joined = match $carried {
					Carried(before) => { ..done.paragraph, content: List.concat(before.content, done.paragraph.content) }
					Nothing => done.paragraph
				}
				if done.joins {
					$carried = Carried(joined)
				} else {
					$out = List.append($out, Paragraph(joined))
					$carried = Nothing
				}
			}

			Table(table) => {
				$out = carry_out($out, $carried)
				$carried = Nothing
				done = resolve_table(table, $state)
				$state = done.state
				match done.table {
					Kept(kept) => {
						$out = List.append($out, Table(kept))
					}

					Gone => {}
				}
			}

			Section(section) => {
				formatted = property_of($state, section.change)
				$state = formatted.state
				if $carried == Nothing or (body and $index == blocks.len()) {
					$out = List.append(carry_out($out, $carried), Section(section_after(section, formatted.outcome)))
					$carried = Nothing
				}
			}

			Container({ element, content }) => {
				done = resolve_blocks(content, $state, $carried, Bool.False)
				$state = done.state
				$carried = done.carried
				$out = List.append($out, Container({ element, content: done.blocks }))
			}

			_ => {
				$out = List.append($out, block)
			}
		}
	}
	{ blocks: $out, state: $state, carried: $carried }
}

# A paragraph resolved, and whether its mark went.
resolve_paragraph : Document.Paragraph, Resolving -> { paragraph : Document.Paragraph, joins : Bool, state : Resolving }
resolve_paragraph = |paragraph, state| {
	formatted = property_of(state, paragraph.properties.change)
	properties = match formatted.outcome {
		Stays => paragraph.properties
		Accepted => { ..paragraph.properties, change: [] }
		Rejected(previous) => paragraph_before(previous, paragraph.properties.mark)
	}
	content = resolve_inlines(paragraph.content, formatted.state)
	var $state = content.state
	var $mark = List.with_capacity(properties.mark.len())
	var $joins = Bool.False
	for change in properties.mark {
		taken = take($state, change.author, change.date)
		$state = paired(taken.state, change.kind, taken.chosen)
		if !taken.chosen {
			$mark = List.append($mark, change)
		} else if !stands(change.kind, state.action) {
			$joins = Bool.True
		}
	}
	{ paragraph: { properties: { ..properties, mark: $mark }, content: content.inlines }, joins: $joins, state: $state }
}

resolve_inlines : List(Document.Inline), Resolving -> { inlines : List(Document.Inline), state : Resolving }
resolve_inlines = |inlines, state| {
	var $state = state
	var $out = List.with_capacity(inlines.len())
	for inline in inlines {
		match inline {
			Revision(revision) => {
				taken = take($state, revision.author, revision.date)
				inner = resolve_inlines(revision.content, paired(taken.state, revision.kind, taken.chosen))
				$state = inner.state
				if !taken.chosen {
					$out = List.append($out, Revision({ ..revision, content: inner.inlines }))
				} else if stands(revision.kind, state.action) {
					$out = List.concat($out, inner.inlines)
				} else {
					$out = List.concat($out, left_behind(inner.inlines))
				}
			}

			Run(run) =>
				match run.properties.change.first() {
					Ok(changed) => {
						taken = take($state, changed.author, changed.date)
						$state = taken.state
						properties = if !taken.chosen {
							run.properties
						} else {
							match state.action {
								Accept => { ..run.properties, change: [] }
								Reject => run_before(changed.previous)
							}
						}
						$out = List.append($out, Run({ ..run, properties }))
					}

					Err(_) => {
						$out = List.append($out, inline)
					}
				}

			MoveStart(range) => {
				$state = match range.side {
					Source => { ..$state, sources: List.append($state.sources, range.name) }
					Destination => { ..$state, destinations: List.append($state.destinations, range.name) }
				}
				$out = List.append($out, inline)
			}

			MoveEnd({ side, name }) => {
				$state = match side {
					Source => { ..$state, sources: closed($state.sources, name) }
					Destination => { ..$state, destinations: closed($state.destinations, name) }
				}
				$out = List.append($out, inline)
			}

			Hyperlink({ target, preserved, content }) => {
				inner = resolve_inlines(content, $state)
				$state = inner.state
				$out = List.append($out, Hyperlink({ target, preserved, content: inner.inlines }))
			}

			SimpleField({ code, preserved, content }) => {
				inner = resolve_inlines(content, $state)
				$state = inner.state
				$out = List.append($out, SimpleField({ code, preserved, content: inner.inlines }))
			}

			Container({ element, content }) => {
				inner = resolve_inlines(content, $state)
				$state = inner.state
				$out = List.append($out, Container({ element, content: inner.inlines }))
			}

			_ => {
				$out = List.append($out, inline)
			}
		}
	}
	{ inlines: $out, state: $state }
}

# What removed content leaves where it was: its comment and bookmark
# boundaries, its moves' range boundaries and a run of its comment
# references.
left_behind : List(Document.Inline) -> List(Document.Inline)
left_behind = |inlines|
	inlines.fold(
		[],
		|kept, inline|
			match inline {
				BookmarkStart(_) => List.append(kept, inline)
				BookmarkEnd(_) => List.append(kept, inline)
				CommentStart(_) => List.append(kept, inline)
				CommentEnd(_) => List.append(kept, inline)
				MoveStart(_) => List.append(kept, inline)
				MoveEnd(_) => List.append(kept, inline)
				Run(run) => {
					references = run.content.keep_if(
						|item|
							match item {
								CommentReference(_) => Bool.True
								_ => Bool.False
							},
					)
					if (references.is_empty()) kept else List.append(kept, Run({ properties: run.properties, content: references }))
				}

				Hyperlink({ target: _, preserved: _, content }) => List.concat(kept, left_behind(content))
				SimpleField({ code: _, preserved: _, content }) => List.concat(kept, left_behind(content))
				Container({ element: _, content }) => List.concat(kept, left_behind(content))
				Revision(revision) => List.concat(kept, left_behind(revision.content))
				Preserved(_) => kept
			},
	)

# A table resolved, or gone when it had rows and none is left.
resolve_table : Document.Table, Resolving -> { table : [Kept(Document.Table), Gone], state : Resolving }
resolve_table = |table, state| {
	formatted = property_of(state, table.properties.change)
	properties = match formatted.outcome {
		Stays => table.properties
		Accepted => { ..table.properties, change: [] }
		Rejected(previous) => { style: previous.style, width: previous.width, borders: previous.borders, shading: previous.shading, preserved: previous.preserved, change: [] }
	}
	content = resolve_table_content(table.content, formatted.state)
	resolved = { ..table, properties, content: content.content }
	gone = !Document.table_rows(table).is_empty() and Document.table_rows(resolved).is_empty()
	{ table: if (gone) Gone else Kept(resolved), state: content.state }
}

resolve_table_content : List(Document.TableContent), Resolving -> { content : List(Document.TableContent), state : Resolving }
resolve_table_content = |items, state| {
	var $state = state
	var $out = List.with_capacity(items.len())
	for item in items {
		match item {
			Row(row) => {
				inserted = tracked_of($state, row.properties.inserted)
				deleted = tracked_of(inserted.state, row.properties.deleted)
				formatted = property_of(deleted.state, row.properties.change)
				cells = resolve_row_content(row.content, formatted.state)
				$state = cells.state
				properties = match formatted.outcome {
					Stays => row.properties
					Accepted => { ..row.properties, change: [] }
					Rejected(previous) => { header: previous.header, grid_before: previous.grid_before, grid_after: previous.grid_after, preserved: previous.preserved, inserted: row.properties.inserted, deleted: row.properties.deleted, change: [] }
				}
				gone = match state.action {
					Accept => deleted.chosen
					Reject => inserted.chosen
				}
				if !gone {
					$out = List.append($out, Row({ properties: { ..properties, inserted: inserted.tracked, deleted: deleted.tracked }, content: cells.content }))
				}
			}

			Container({ element, content }) => {
				inner = resolve_table_content(content, $state)
				$state = inner.state
				$out = List.append($out, Container({ element, content: inner.content }))
			}

			_ => {
				$out = List.append($out, item)
			}
		}
	}
	{ content: $out, state: $state }
}

resolve_row_content : List(Document.RowContent), Resolving -> { content : List(Document.RowContent), state : Resolving }
resolve_row_content = |items, state| {
	var $state = state
	var $out = List.with_capacity(items.len())
	for item in items {
		match item {
			Cell(cell) => {
				revised = match cell.properties.revision {
					Inserted(change) => take($state, change.author, change.date)
					Deleted(change) => take($state, change.author, change.date)
					Merged(merged) => take($state, merged.author, merged.date)
					Unset => { state: $state, chosen: Bool.False }
				}
				formatted = property_of(revised.state, cell.properties.change)
				inner = resolve_blocks(cell.content, formatted.state, Nothing, Bool.False)
				$state = inner.state
				before = match formatted.outcome {
					Stays => cell.properties
					Accepted => { ..cell.properties, change: [] }
					Rejected(previous) => { width: previous.width, span: previous.span, merge: previous.merge, borders: previous.borders, shading: previous.shading, alignment: previous.alignment, preserved: previous.preserved, revision: cell.properties.revision, change: [] }
				}
				(properties, gone) = match (cell.properties.revision, state.action) {
					(_, _) if !revised.chosen => (before, Bool.False)
					(Merged(merged), Reject) => ({ ..before, merge: merged.previous, revision: Unset }, Bool.False)
					(Inserted(_), Reject) => (before, Bool.True)
					(Deleted(_), Accept) => (before, Bool.True)
					_ => ({ ..before, revision: Unset }, Bool.False)
				}
				if !gone {
					$out = List.append($out, Cell({ properties, content: carry_out(inner.blocks, inner.carried) }))
				}
			}

			Container({ element, content }) => {
				inner = resolve_row_content(content, $state)
				$state = inner.state
				$out = List.append($out, Container({ element, content: inner.content }))
			}

			_ => {
				$out = List.append($out, item)
			}
		}
	}
	{ content: $out, state: $state }
}

# A paragraph's properties as they were before a rejected change of them,
# with the mark it has now.
paragraph_before : Document.ParagraphPropertiesOf([Unset]), List(Document.MarkChange) -> Document.ParagraphProperties
paragraph_before = |previous, mark| {
	style: previous.style,
	alignment: previous.alignment,
	indentation: previous.indentation,
	spacing: previous.spacing,
	keep_next: previous.keep_next,
	keep_lines: previous.keep_lines,
	page_break_before: previous.page_break_before,
	widow_control: previous.widow_control,
	outline_level: previous.outline_level,
	borders: previous.borders,
	shading: previous.shading,
	tabs: previous.tabs,
	numbering: previous.numbering,
	preserved: previous.preserved,
	mark,
	change: [],
}

# A run's properties as they were before a rejected change of them.
run_before : Document.RunPropertiesOf([Unset]) -> Document.RunProperties
run_before = |previous| {
	style: previous.style,
	bold: previous.bold,
	italic: previous.italic,
	caps: previous.caps,
	small_caps: previous.small_caps,
	strike: previous.strike,
	double_strike: previous.double_strike,
	hidden: previous.hidden,
	underline: previous.underline,
	vertical_align: previous.vertical_align,
	color: previous.color,
	highlight: previous.highlight,
	size: previous.size,
	fonts: previous.fonts,
	language: previous.language,
	preserved: previous.preserved,
	change: [],
}

# A section's properties once a change of them is resolved.
section_after : Document.Section, [Stays, Accepted, Rejected(Document.SectionOf([Unset]))] -> Document.Section
section_after = |section, outcome|
	match outcome {
		Stays => section
		Accepted => { ..section, change: [] }
		Rejected(previous) => {
			start: previous.start,
			page_size: previous.page_size,
			margins: previous.margins,
			columns: previous.columns,
			page_numbers: previous.page_numbers,
			title_page: previous.title_page,
			headers: previous.headers,
			footers: previous.footers,
			preserved: previous.preserved,
			change: [],
		}
	}

# A block with `edit` applied to every paragraph's content in it, through
# tables, cells and containers.
inlines_of_block : Document.Block, (List(Document.Inline) -> List(Document.Inline)) -> Document.Block
inlines_of_block = |block, edit|
	match block {
		Paragraph(paragraph) => Paragraph({ ..paragraph, content: edit(paragraph.content) })
		Table(table) => Table({ ..table, content: table.content.map(|item| inlines_of_table(item, edit)) })
		Container({ element, content }) => Container({ element, content: content.map(|inner| inlines_of_block(inner, edit)) })
		_ => block
	}

inlines_of_table : Document.TableContent, (List(Document.Inline) -> List(Document.Inline)) -> Document.TableContent
inlines_of_table = |item, edit|
	match item {
		Row(row) => Row({ ..row, content: row.content.map(|cell| inlines_of_row(cell, edit)) })
		Container({ element, content }) => Container({ element, content: content.map(|inner| inlines_of_table(inner, edit)) })
		_ => item
	}

inlines_of_row : Document.RowContent, (List(Document.Inline) -> List(Document.Inline)) -> Document.RowContent
inlines_of_row = |item, edit|
	match item {
		Cell(cell) => Cell({ ..cell, content: cell.content.map(|inner| inlines_of_block(inner, edit)) })
		Container({ element, content }) => Container({ element, content: content.map(|inner| inlines_of_row(inner, edit)) })
		_ => item
	}

# Inlines without the boundaries of the moves' ranges `gone` names, by side
# and name.
without_ranges : List(Document.Inline), Set(Str) -> List(Document.Inline)
without_ranges = |inlines, gone|
	inlines.fold(
		List.with_capacity(inlines.len()),
		|kept, inline|
			match inline {
				MoveStart(range) if gone.contains(range_key(range.side, range.name)) => kept
				MoveEnd({ side, name }) if gone.contains(range_key(side, name)) => kept
				Hyperlink({ target, preserved, content }) => List.append(kept, Hyperlink({ target, preserved, content: without_ranges(content, gone) }))
				SimpleField({ code, preserved, content }) => List.append(kept, SimpleField({ code, preserved, content: without_ranges(content, gone) }))
				Container({ element, content }) => List.append(kept, Container({ element, content: without_ranges(content, gone) }))
				Revision(revision) => List.append(kept, Revision({ ..revision, content: without_ranges(revision.content, gone) }))
				_ => List.append(kept, inline)
			},
	)

# A move's range by its side and name.
range_key : Document.MoveSide, Str -> Str
range_key = |side, name|
	match side {
		Source => "S${name}"
		Destination => "D${name}"
	}

# Editing the current text: the offset reached and whether the last
# paragraph joins the next, counted as [Revisions.text] counts; whether
# nothing of the current line has been passed; the span and the text that
# replaces it; how the edit is made; whether the text is placed, or is to be
# placed before whatever follows the character before the span's end; the
# properties of the last run passed; and a problem with the span.
Editing : {
	at : U64,
	joining : Bool,
	fresh : Bool,
	start : U64,
	end : U64,
	text : Str,
	made : [Untracked, Tracked(Document.Change)],
	placed : Bool,
	pending : Bool,
	properties : Document.RunProperties,
	problem : [Fine, Boundary(U64), LineFeed],
}

# A run's content split where the span starts and ends, each piece kept,
# gone, or followed by the new text.
Piece : [Keep(Document.RunContent), Gone(Document.RunContent), Place]

# A line feed at the offset reached, a problem when it is in the span.
line_feed : Editing -> Editing
line_feed = |state| {
	problem = if (state.problem == Fine and state.start <= state.at and state.at < state.end) LineFeed else state.problem
	{ ..state, at: state.at + 1, fresh: Bool.True, problem }
}

# The line feed a joining paragraph owes where nothing follows it to join.
edit_line : Editing -> Editing
edit_line = |state| if (state.joining) line_feed({ ..state, joining: Bool.False }) else state

edit_blocks : List(Document.Block), Editing -> { blocks : List(Document.Block), state : Editing }
edit_blocks = |blocks, state| {
	var $state = state
	var $out = List.with_capacity(blocks.len())
	for block in blocks {
		match block {
			Paragraph(paragraph) => {
				edited = edit_paragraph(paragraph, $state)
				$out = List.append($out, Paragraph(edited.paragraph))
				$state = edited.state
			}

			Table(table) => {
				var $inner = edit_line($state)
				var $content = List.with_capacity(table.content.len())
				for item in table.content {
					edited = edit_table_content(item, $inner)
					$content = List.append($content, edited.content)
					$inner = edited.state
				}
				$out = List.append($out, Table({ ..table, content: $content }))
				$state = edit_line($inner)
			}

			Container({ element, content }) => {
				edited = edit_blocks(content, $state)
				$out = List.append($out, Container({ element, content: edited.blocks }))
				$state = edited.state
			}

			_ => {
				$out = List.append($out, block)
			}
		}
	}
	{ blocks: $out, state: $state }
}

edit_table_content : Document.TableContent, Editing -> { content : Document.TableContent, state : Editing }
edit_table_content = |item, state|
	match item {
		Row(row) => {
			var $inner = edit_line(state)
			var $content = List.with_capacity(row.content.len())
			for cell in row.content {
				edited = edit_row_content(cell, $inner)
				$content = List.append($content, edited.content)
				$inner = edited.state
			}
			{ content: Row({ ..row, content: $content }), state: edit_line($inner) }
		}

		Container({ element, content }) => {
			var $inner = state
			var $edited = List.with_capacity(content.len())
			for child in content {
				out = edit_table_content(child, $inner)
				$edited = List.append($edited, out.content)
				$inner = out.state
			}
			{ content: Container({ element, content: $edited }), state: $inner }
		}

		_ => { content: item, state }
	}

edit_row_content : Document.RowContent, Editing -> { content : Document.RowContent, state : Editing }
edit_row_content = |item, state|
	match item {
		Cell(cell) => {
			edited = edit_blocks(cell.content, edit_line(state))
			{ content: Cell({ ..cell, content: edited.blocks }), state: edit_line(edited.state) }
		}

		Container({ element, content }) => {
			var $inner = state
			var $edited = List.with_capacity(content.len())
			for child in content {
				out = edit_row_content(child, $inner)
				$edited = List.append($edited, out.content)
				$inner = out.state
			}
			{ content: Container({ element, content: $edited }), state: $inner }
		}

		_ => { content: item, state }
	}

# A paragraph edited. New text placed where a line begins goes first, with
# the properties of the paragraph's first run; new text still to be placed
# when the paragraph's content ends goes last.
edit_paragraph : Document.Paragraph, Editing -> { paragraph : Document.Paragraph, state : Editing }
edit_paragraph = |paragraph, state| {
	starts = !state.placed and !state.pending and state.fresh and state.at == state.end
	edited = edit_inlines(paragraph.content, if (starts) { ..state, placed: Bool.True } else state, Bool.True)
	var $content = if (starts) List.prepend(edited.inlines, added(first_properties(paragraph.content) ?? Document.no_run_properties, state)) else edited.inlines
	var $state = edited.state
	if $state.pending {
		$content = List.append($content, added($state.properties, $state))
		$state = { ..$state, pending: Bool.False, placed: Bool.True }
	}
	joins = Document.joins_next(paragraph)
	ended = if (joins) $state else line_feed($state)
	{ paragraph: { ..paragraph, content: $content }, state: { ..ended, joining: joins } }
}

# The properties of the first run in content, through hyperlinks, fields
# and changes.
first_properties : List(Document.Inline) -> Try(Document.RunProperties, [NoRun])
first_properties = |content| {
	for inline in content {
		found = match inline {
			Run(run) => Ok(run.properties)
			Hyperlink({ target: _, preserved: _, content: inner }) => first_properties(inner)
			SimpleField({ code: _, preserved: _, content: inner }) => first_properties(inner)
			Container({ element: _, content: inner }) => first_properties(inner)
			Revision(revision) => first_properties(revision.content)
			_ => Err(NoRun)
		}
		if found.is_ok() {
			return found
		}
	}
	Err(NoRun)
}

# The new text as a run with these properties, without their change, inside
# an insertion when the edit is tracked.
added : Document.RunProperties, Editing -> Document.Inline
added = |properties, state| {
	var $content = List.with_capacity(2)
	var $first = Bool.True
	for piece in state.text.split_on("\t") {
		if !$first {
			$content = List.append($content, Tab)
		}
		if piece != "" {
			$content = List.append($content, Text(piece))
		}
		$first = Bool.False
	}
	run = Run({ properties: { ..properties, change: [] }, content: $content })
	match state.made {
		Untracked => run
		Tracked(change) => Revision({ kind: Insertion, author: change.author, date: change.date, content: [run], preserved: change.preserved })
	}
}

# Inlines edited where their text is current, new text still to be placed
# going before the next inline there.
edit_inlines : List(Document.Inline), Editing, Bool -> { inlines : List(Document.Inline), state : Editing }
edit_inlines = |inlines, state, current| {
	var $state = state
	var $out = List.with_capacity(inlines.len() + 1)
	for inline in inlines {
		if current and $state.pending {
			$out = List.append($out, added($state.properties, $state))
			$state = { ..$state, pending: Bool.False, placed: Bool.True }
		}
		edited = edit_inline(inline, $state, current)
		$out = List.concat($out, edited.inlines)
		$state = edited.state
	}
	{ inlines: $out, state: $state }
}

# An inline edited where its text is current. Content deleted or moved away
# is not current text. A change emptied by an untracked edit goes.
edit_inline : Document.Inline, Editing, Bool -> { inlines : List(Document.Inline), state : Editing }
edit_inline = |inline, state, current|
	match inline {
		Run(run) if current => edit_run(run, state)
		Hyperlink({ target, preserved, content }) => {
			edited = edit_inlines(content, state, current)
			{ inlines: [Hyperlink({ target, preserved, content: edited.inlines })], state: edited.state }
		}

		SimpleField({ code, preserved, content }) => {
			edited = edit_inlines(content, state, current)
			{ inlines: [SimpleField({ code, preserved, content: edited.inlines })], state: edited.state }
		}

		Container({ element, content }) => {
			edited = edit_inlines(content, state, current)
			{ inlines: [Container({ element, content: edited.inlines })], state: edited.state }
		}

		Revision(revision) => {
			edited = edit_inlines(revision.content, state, current and revision.kind != Deletion and revision.kind != MoveSource)
			emptied = match state.made {
				Untracked => edited.inlines.is_empty() and !revision.content.is_empty()
				Tracked(_) => Bool.False
			}
			{ inlines: if (emptied) [] else [Revision({ ..revision, content: edited.inlines })], state: edited.state }
		}

		_ => { inlines: [inline], state }
	}

# A run of current text edited: split where the span starts and ends, the
# span's pieces gone and the new text after the character before the span's
# end, or still to be placed when that character ends the run.
edit_run : Document.Run, Editing -> { inlines : List(Document.Inline), state : Editing }
edit_run = |run, state| {
	var $state = { ..state, properties: run.properties }
	var $pieces = List.with_capacity(run.content.len() + 2)
	var $changed = Bool.False
	var $index = 0.U64
	for item in run.content {
		$index = $index + 1
		size = Document.inline_text(Run({ properties: run.properties, content: [item] })).to_utf8().len()
		from = $state.at
		if size == 0 {
			gone = $state.start < from and from < $state.end and !is_reference(item)
			$pieces = List.append($pieces, if (gone) Gone(item) else Keep(item))
			$changed = $changed or gone
		} else {
			cuts = [$state.start, $state.end].keep_if(|offset| offset > from and offset < from + size)
			split = split_content(item, from, size, if ($state.start == $state.end) cuts.drop_last(1) else cuts)
			if $state.problem == Fine {
				$state = { ..$state, problem: split.inside }
			}
			for piece in split.pieces {
				gone = $state.start < $state.end and $state.start <= piece.from and piece.to <= $state.end
				$pieces = List.append($pieces, if (gone) Gone(piece.content) else Keep(piece.content))
				$changed = $changed or gone
				if !$state.placed and !$state.pending and piece.to == $state.end {
					if piece.to < from + size or $index < run.content.len() {
						$pieces = List.append($pieces, Place)
						$changed = Bool.True
						$state = { ..$state, placed: Bool.True }
					} else {
						$state = { ..$state, pending: Bool.True }
					}
				}
			}
			$state = { ..$state, fresh: Bool.False }
		}
		$state = { ..$state, at: from + size }
	}
	if !$changed {
		return { inlines: [Run(run)], state: $state }
	}
	{ inlines: runs_of($pieces, run.properties, $state), state: $state }
}

# Whether run content is a comment's reference, which an edit keeps.
is_reference : Document.RunContent -> Bool
is_reference = |item|
	match item {
		CommentReference(_) => Bool.True
		_ => Bool.False
	}

# Run content of `size` bytes of text from offset `from` split at `cuts`
# inside it, each piece with its offsets, and the first cut inside a
# character, where content cannot be split.
split_content : Document.RunContent, U64, U64, List(U64) -> { pieces : List({ content : Document.RunContent, from : U64, to : U64 }), inside : [Fine, Boundary(U64), LineFeed] }
split_content = |item, from, size, cuts|
	match (item, cuts.first()) {
		(_, Err(_)) => { pieces: [{ content: item, from, to: from + size }], inside: Fine }
		(Text(text), Ok(_)) => {
			bytes = text.to_utf8()
			var $pieces = List.with_capacity(cuts.len() + 1)
			var $last = 0.U64
			for offset in List.append(cuts.map(|cut| cut - from), size) {
				$pieces = List.append($pieces, { content: Text(Str.from_utf8(bytes.sublist({ start: $last, len: offset - $last })) ?? ""), from: from + $last, to: from + offset })
				$last = offset
			}
			inside = match cuts.find_first(|cut| !is_boundary(bytes, cut - from)) {
				Ok(cut) => Boundary(cut)
				Err(_) => Fine
			}
			{ pieces: $pieces, inside }
		}

		(_, Ok(cut)) => { pieces: [{ content: item, from, to: from + size }], inside: Boundary(cut) }
	}

# Whether an offset into UTF-8 text is between characters.
is_boundary : List(U8), U64 -> Bool
is_boundary = |bytes, offset|
	match bytes.get(offset) {
		Ok(byte) => byte < 0x80 or byte >= 0xC0
		Err(_) => Bool.True
	}

# A run's pieces as inlines: the pieces kept as runs with its properties, the
# pieces gone inside a deletion when the edit is tracked, and the new text
# where it is placed.
runs_of : List(Piece), Document.RunProperties, Editing -> List(Document.Inline)
runs_of = |pieces, properties, state| {
	flush = |acc| {
		kept = if (acc.kept.is_empty()) acc.out else List.append(acc.out, Run({ properties, content: acc.kept }))
		out = match state.made {
			Tracked(change) if !acc.gone.is_empty() => List.append(kept, Revision({ kind: Deletion, author: change.author, date: change.date, content: [Run({ properties, content: acc.gone })], preserved: change.preserved }))
			_ => kept
		}
		{ out, kept: [], gone: [] }
	}
	ended = pieces.fold(
		{ out: List.with_capacity(4), kept: [], gone: [] },
		|acc, piece|
			match piece {
				Keep(item) if acc.gone.is_empty() => { ..acc, kept: List.append(acc.kept, item) }
				Keep(item) => { ..flush(acc), kept: [item] }
				Gone(item) if acc.kept.is_empty() => { ..acc, gone: List.append(acc.gone, item) }
				Gone(item) => { ..flush(acc), gone: [item] }
				Place => {
					flushed = flush(acc)
					{ ..flushed, out: List.append(flushed.out, added(properties, state)) }
				}
			},
	)
	flush(ended).out
}
