app [target] {
	docx: "../../package/main.roc",
	fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.5.0/9WT86CuwM7ZJBSs8iTd1jLyrUFTTiGp5hcJE63TwswGE.tar.zst",
}

import fuzz.Fuzz
import docx.Docx
import docx.Document
import docx.Opc
import docx.Revisions
import docx.WmlWrite
import docx.XmlTree

## Accepting and rejecting tracked changes, and the final and original text
## of a document with them, agree with the untracked documents those changes
## lead to and come from; a tracked edit accepted is the same edit made
## silently, and rejected restores the document.
##
## A program of bytes describes three bodies at once: one with tracked
## changes, the untracked body every change accepted gives, built directly
## rather than by accepting, and the untracked body every change rejected
## gives. Its changes are insertions, deletions, a deletion holding an
## insertion, a deleted field, moves' sources and destinations with their
## ranges, an insertion inside a hyperlink, a run's changed formatting,
## paragraph marks inserted, deleted, moved away and moved here, and tables
## with rows and cells inserted and deleted. `Revisions.text` of the tracked
## body in the final and original views must equal the current text of the
## accepted and rejected bodies, and `Revisions.accept` and
## `Revisions.reject` of every change must give exactly those bodies. The
## tracked body is then written by `WmlWrite.document` into a package that
## `Docx.parse` must read back as the same body, whose `Docx.final_text` and
## `Docx.original_text` are those texts again.
##
## The program also chooses a span of the rejected body's text, or of the
## accepted body's for a program of odd length, which may run over line
## feeds, and a replacement, which may hold one. `Revisions.replace` made
## silently must splice the replacement into the text, or fail, as the
## tracked edit must, only for a span holding a line feed; made as tracked
## changes, its final text must be that text and its original text the text
## before, accepting its changes, all of them or the editor's, must give the
## silent edit and rejecting them the body before, each the same up to how
## text is split into runs, hyperlinks and changes, and it must write and
## read back with the same final and original text. The same laws hold for
## blocks, a paragraph, two, a table or a table and a paragraph, inserted
## by `Revisions.insert_blocks` where a line begins, and for the blocks
## between two line starts deleted by `Revisions.delete_blocks`: the text
## is spliced, and silent and tracked edits fail alike.
##
## The document read back gives its changes through `Docx.revisions`;
## `Docx.accept_all` and `Docx.reject_all` give documents whose text is the
## final and original text, and accepting the changes with even ids by
## `Docx.accept` with an `Ids` selection, or rejecting those with odd ids by
## `Docx.reject`, leaves no more changes than the others, fewer when a
## resolved change held some, and the final or original text as it was.
## Each edit is also made on the untracked body written as a document, as
## tracked changes: `Docx.replace_text` of the span, `Docx.insert_text` of
## the replacement at the span's start, `Docx.delete_text` of the span,
## `Docx.insert_blocks` and `Docx.delete_blocks`; where the same tracked edit
## of the body succeeds, the edited document's final and original texts
## must be that edit's final text and the text before, and where it fails,
## the document edit must fail.
##
## Allocation ratchets, which only ever move down: `Revisions.text` in the
## final and original views, `Docx.revisions`, the accepts and rejects and
## the five document edits each allocate at most linearly many times and
## hold at most linearly many bytes live in the program's length, and each declared
## example allocates no more than it did when its ceiling was set. Two pairs
## bound growth: the program above, sixteen times as often in the large one
## as in the small one, and changes of every kind, 256 against 16. Running a
## large example runs its small one again and fails if any region allocates
## more than sixteen times as often, or requests or holds live more than
## `byte_ratio` times as many bytes. Raising a ceiling needs a cause recorded
## in the pull request.
test! : List(U8) => Fuzz.Outcome
test! = |program| {
	costs = algebra!(program)
	match exact_ceilings(program) {
		Ok(ceilings) =>
			for (region, ceiling) in ceilings {
				match costs.find_first(|(name, _)| name == region) {
					Ok((_, stats)) =>
						if stats.allocs + stats.reallocs > ceiling {
							crash "a declared program allocated more than its ceiling in ${region}"
						}

					Err(_) => crash "a declared program did not measure ${region}"
				}
			}

		Err(NotDeclared) => {}
	}
	match small_of(program) {
		Ok(small_program) => {
			small = algebra!(small_program)
			for (region, stats) in costs {
				match small.find_first(|(name, _)| name == region) {
					Ok((_, base)) =>
						if stats.allocs + stats.reallocs > 16 * (base.allocs + base.reallocs) or stats.requested_bytes > byte_ratio * base.requested_bytes or held(stats) > byte_ratio * held(base) {
							crash "a large program cost more than its small one allows in ${region}"
						}

					Err(_) => crash "a small program did not measure ${region}"
				}
			}
		}

		Err(NotAPair) => {}
	}
	Fuzz.keep
}

generator : Fuzz.Generator(List(U8))
generator = Fuzz.bytes

# What a program's regions cost, by region.
Costs : List((Str, Fuzz.Stats))

# The bytes a region held live beyond those live when it began.
held : Fuzz.Stats -> U64
held = |stats| stats.peak_live_bytes - stats.entry_live_bytes

# Fail when a region cost more than linearly in the program's length.
check_linear : Str, Fuzz.Stats, U64 -> {}
check_linear = |region, stats, length| {
	if stats.allocs + stats.reallocs > linear_allocation_ceiling(region, length) {
		crash "${region} allocated more than linearly in the program's length"
	}
	if held(stats) > linear_memory_ceiling(region, length) {
		crash "${region} held more than linearly many bytes live"
	}
	{}
}

# Build a program's bodies, measure the tracked body's final and original
# text, and check them against the untracked bodies and through writing and
# reading; then measure and check the document's changes, accepting and
# rejecting them, and the edits.
algebra! : List(U8) => Costs
algebra! = |program| {
	built = bodies(program)
	{ value: (final, original), stats: texts } = Fuzz.measure!("revisions-text", || (Revisions.text(built.tracked, Final), Revisions.text(built.tracked, Original)))
	check_linear("revisions-text", texts, program.len())
	if final != Revisions.text(built.final, Current) {
		crash "the final text differs from the text of the accepted body"
	}
	if original != Revisions.text(built.original, Current) {
		crash "the original text differs from the text of the rejected body"
	}
	document = document_of(built.tracked)
	if Docx.body(document) != built.tracked {
		crash "a written body read back differently"
	}
	if Docx.final_text(document) != final or Docx.original_text(document) != original {
		crash "a written document's final or original text differs"
	}
	if Revisions.accept(built.tracked, All) != Ok(built.final) {
		crash "accepting every change differs from the accepted body"
	}
	if Revisions.reject(built.tracked, All) != Ok(built.original) {
		crash "rejecting every change differs from the rejected body"
	}
	{ value: listed, stats: listing } = Fuzz.measure!("docx-revisions", || Docx.revisions(document))
	if listed != Revisions.list(built.tracked) {
		crash "the document's changes differ from the body's"
	}
	{ value: accepted, stats: accepting_all } = Fuzz.measure!("docx-accept-all", || Docx.accept_all(document))
	{ value: rejected, stats: rejecting_all } = Fuzz.measure!("docx-reject-all", || Docx.reject_all(document))
	if Docx.text(accepted ?? crash "accepting every change failed") != final or Docx.text(rejected ?? crash "rejecting every change failed") != original {
		crash "accepting or rejecting every change differs from the final or original text"
	}
	evens = listed.keep_if(|change| change.id % 2 == 0).map(|change| change.id)
	odds = listed.keep_if(|change| change.id % 2 == 1).map(|change| change.id)
	{ value: some_accepted, stats: accepting } = Fuzz.measure!("docx-accept", || Docx.accept(document, Ids(evens)))
	{ value: some_rejected, stats: rejecting } = Fuzz.measure!("docx-reject", || Docx.reject(document, Ids(odds)))
	left_accepted = some_accepted ?? crash "accepting selected changes failed"
	left_rejected = some_rejected ?? crash "rejecting selected changes failed"
	if Docx.final_text(left_accepted) != final or Docx.revisions(left_accepted).len() > odds.len() {
		crash "accepting the changes with even ids changed the final text or left a selected change"
	}
	if Docx.original_text(left_rejected) != original or Docx.revisions(left_rejected).len() > evens.len() {
		crash "rejecting the changes with odd ids changed the original text or left a selected change"
	}
	measured = [("revisions-text", texts), ("docx-revisions", listing), ("docx-accept-all", accepting_all), ("docx-reject-all", rejecting_all), ("docx-accept", accepting), ("docx-reject", rejecting)]
	for (region, stats) in measured {
		check_linear(region, stats, program.len())
	}
	List.concat(measured, edits!(program, if (program.len() % 2 == 0) built.original else built.final))
}

# A body written by `WmlWrite.document` as the main document of a package,
# read back.
document_of : List(Document.Block) -> Document
document_of = |body| {
	written = WmlWrite.document(shell, body, context) ?? crash "a body did not write"
	main = XmlTree.render(written.tree) ?? crash "a written body did not render"
	graph = {
		relationships: [{ id: "rId1", kind: Opc.officedocument_relationship, target: "/word/document.xml", mode: Internal }],
		parts: [{ name: "/word/document.xml", content_type: main_type, relationships: written.relationships }],
	}
	bytes = Opc.to_bytes(graph, |_| Bytes(main)) ?? crash "a written body did not package"
	(Docx.parse(bytes) ?? crash "a written document did not parse").document
}

# The body's edits, each checked against the same edit made silently and
# made again as tracked changes in the body written as a document,
# measured.
edits! : List(U8), List(Document.Block) => Costs
edits! = |program, body| {
	document = document_of(body)
	before = Revisions.text(body, Current)
	measured = List.join([edited!(program, body, document, before), blocks_inserted!(program, body, document, before), blocks_deleted!(program, body, document, before)])
	for (region, stats) in measured {
		check_linear(region, stats, program.len())
	}
	measured
}

# A tracked edit of an untracked body against the same edit made silently;
# then that edit, an insertion of its replacement at the span's start and a
# deletion of its span, made in the document.
edited! : List(U8), List(Document.Block), Document, Str => Costs
edited! = |program, body, document, before| {
	text = before.to_utf8()
	first = (program.first() ?? 0).to_u64() % text.len()
	last = first + (program.last() ?? 0).to_u64() % 24
	span = { start: first, end: if (last < text.len()) last else text.len() }
	replacement = match program.len() % 4 {
		0 => "new"
		1 => ""
		2 => "t\tx"
		_ => "a\nb"
	}
	spliced = List.join([text.sublist({ start: 0, len: span.start }), replacement.to_utf8(), text.drop_first(span.end)])
	across = text.sublist({ start: span.start, len: span.end - span.start }).contains(10)
	match (Revisions.replace(body, span, replacement, Untracked), Revisions.replace(body, span, replacement, by_morgan)) {
		(Ok(silent), Ok(tracked)) => {
			if Revisions.text(silent, Current).to_utf8() != spliced {
				crash "a silent edit's text is not the replacement spliced in"
			}
			laws(body, silent, tracked)
		}

		(Err(LineFeedInSpan(_)), Err(LineFeedInSpan(_))) if across => {}
		_ => crash "a silent and a tracked edit did not both succeed or both fail for a line feed in the span"
	}
	at = { start: span.start, end: span.start }
	[
		measured_edit!("docx-replace-text", final_of(Revisions.replace(body, span, replacement, by_morgan)), before, || Docx.replace_text(document, span, replacement, by_morgan)),
		measured_edit!("docx-insert-text", final_of(Revisions.replace(body, at, replacement, by_morgan)), before, || Docx.insert_text(document, span.start, replacement, by_morgan)),
		measured_edit!("docx-delete-text", final_of(Revisions.replace(body, span, "", by_morgan)), before, || Docx.delete_text(document, span, by_morgan)),
	]
}

# Blocks inserted where a line begins, silently and tracked, and in the
# document.
blocks_inserted! : List(U8), List(Document.Block), Document, Str => Costs
blocks_inserted! = |program, body, document, before| {
	text = before.to_utf8()
	starts = line_starts(text)
	at = starts.get((program.get(1) ?? 0).to_u64() % starts.len()) ?? 0
	new = match program.len() % 4 {
		0 => [said(Document.no_paragraph_properties, "n")]
		1 => [said(Document.no_paragraph_properties, "n"), said({ ..Document.no_paragraph_properties, style: Style("Quote") }, "q")]
		2 => [new_table]
		_ => [new_table, said({ ..Document.no_paragraph_properties, style: Style("Quote") }, "q")]
	}
	spliced = List.join([text.sublist({ start: 0, len: at }), Revisions.text(new, Current).to_utf8(), text.drop_first(at)])
	match (Revisions.insert_blocks(body, at, new, Untracked), Revisions.insert_blocks(body, at, new, by_morgan)) {
		(Ok(silent), Ok(tracked)) => {
			if Revisions.text(silent, Current).to_utf8() != spliced {
				crash "a silent block insertion's text is not the new blocks' text spliced in"
			}
			laws(body, silent, tracked)
		}

		(Err(NoParagraphToJoin(one)), Err(NoParagraphToJoin(other))) if one == at and other == at => {}
		_ => crash "a silent and a tracked block insertion did not both succeed or both fail for want of a paragraph to join"
	}
	[measured_edit!("docx-insert-blocks", final_of(Revisions.insert_blocks(body, at, new, by_morgan)), before, || Docx.insert_blocks(document, at, new, by_morgan))]
}

# The blocks between two line starts deleted, silently and tracked, and in
# the document.
blocks_deleted! : List(U8), List(Document.Block), Document, Str => Costs
blocks_deleted! = |program, body, document, before| {
	text = before.to_utf8()
	starts = line_starts(text)
	one = starts.get((program.get(1) ?? 0).to_u64() % starts.len()) ?? 0
	other = starts.get((program.get(2) ?? 0).to_u64() % starts.len()) ?? 0
	span = if (one < other) { start: one, end: other } else { start: other, end: one }
	spliced = List.concat(text.sublist({ start: 0, len: span.start }), text.drop_first(span.end))
	match (Revisions.delete_blocks(body, span, Untracked), Revisions.delete_blocks(body, span, by_morgan)) {
		(Ok(silent), Ok(tracked)) => {
			if Revisions.text(silent, Current).to_utf8() != spliced {
				crash "a silent block deletion's text is not the text without the span"
			}
			laws(body, silent, tracked)
		}

		(Err(NotABlockBoundary(at)), Err(NotABlockBoundary(again))) if at == again => {}
		(Err(NoParagraphToJoin(at)), Err(NoParagraphToJoin(again))) if at == again => {}
		_ => crash "a silent and a tracked block deletion did not both succeed or both fail alike"
	}
	[measured_edit!("docx-delete-blocks", final_of(Revisions.delete_blocks(body, span, by_morgan)), before, || Docx.delete_blocks(document, span, by_morgan))]
}

# The final text of a tracked edit of the body, or that it fails.
final_of : Try(List(Document.Block), _) -> Try(Str, [Fails])
final_of = |edit|
	match edit {
		Ok(tracked) => Ok(Revisions.text(tracked, Final))
		Err(_) => Err(Fails)
	}

# An edit of the document measured: where the same tracked edit of its body
# succeeds, the edited document's final and original text are that edit's
# final text and the text before; where it fails, the document edit fails.
measured_edit! : Str, Try(Str, [Fails]), Str, (() -> Try(Document, Docx.EditError)) => (Str, Fuzz.Stats)
measured_edit! = |region, expected, before, edit| {
	{ value: done, stats } = Fuzz.measure!(region, || edit())
	match (done, expected) {
		(Ok(edited), Ok(final)) =>
			if Docx.final_text(edited) != final or Docx.original_text(edited) != before {
				crash "a tracked edit of a document has a different final or original text in ${region}"
			}

		(Err(_), Err(Fails)) => {}
		_ => crash "a tracked edit of a document succeeded or failed unlike the same edit of its body in ${region}"
	}
	(region, stats)
}

# Linear ceilings in the program's length, by region. Measured on
# nightly-2026-11-07: the texts take two to four allocations whatever the
# program, the growth of the two texts' bytes, and hold 4.0 bytes live a
# byte of the large program. Listing changes takes 1.0 allocation a byte of
# the large program and 7.1 a byte of a program of tables; accepting,
# rejecting and editing, each of which writes the whole document, take 4.6
# to 10.3 a byte of the large program and 34.9 to 65.6 a byte of programs
# of tables, the costliest step, which also hold most live: 10.7 KB a byte
# for tables of three cells.
linear_allocation_ceiling : Str, U64 -> U64
linear_allocation_ceiling = |region, length|
	match region {
		"revisions-text" => 16 + length // 16
		"docx-revisions" => 64 + 16 * length
		_ => 1024 + 96 * length
	}

linear_memory_ceiling : Str, U64 -> U64
linear_memory_ceiling = |region, length|
	match region {
		"revisions-text" => 16_384 + 64 * length
		"docx-revisions" => 16_384 + 2048 * length
		_ => 262_144 + 16_384 * length
	}

# Exact ceilings: the allocations and reallocations of each region of each
# declared program, as measured on nightly-2026-11-07 when the ceiling was
# set.
exact_ceilings : List(U8) -> Try(List((Str, U64)), [NotDeclared])
exact_ceilings = |program|
	if program == small_program {
		Ok([("revisions-text", 2), ("docx-revisions", 80), ("docx-accept-all", 656), ("docx-reject-all", 600), ("docx-accept", 848), ("docx-reject", 854), ("docx-replace-text", 782), ("docx-insert-text", 776), ("docx-delete-text", 767), ("docx-insert-blocks", 417), ("docx-delete-blocks", 410)])
	} else if program == large_program {
		Ok([("revisions-text", 4), ("docx-revisions", 1227), ("docx-accept-all", 10_076), ("docx-reject-all", 9180), ("docx-accept", 13_044), ("docx-reject", 13_214), ("docx-replace-text", 11_769), ("docx-insert-text", 11_763), ("docx-delete-text", 11_754), ("docx-insert-blocks", 5937), ("docx-delete-blocks", 5930)])
	} else if program == few_changes {
		Ok([("revisions-text", 2), ("docx-revisions", 31), ("docx-accept-all", 290), ("docx-reject-all", 286), ("docx-accept", 399), ("docx-reject", 390), ("docx-replace-text", 383), ("docx-insert-text", 377), ("docx-delete-text", 368), ("docx-insert-blocks", 228), ("docx-delete-blocks", 221)])
	} else if program == many_changes {
		Ok([("revisions-text", 2), ("docx-revisions", 488), ("docx-accept-all", 4220), ("docx-reject-all", 4156), ("docx-accept", 5910), ("docx-reject", 5766), ("docx-replace-text", 5399), ("docx-insert-text", 5393), ("docx-delete-text", 5384), ("docx-insert-blocks", 2913), ("docx-delete-blocks", 2906)])
	} else {
		Err(NotDeclared)
	}

# The small example of a pair whose large example this is.
small_of : List(U8) -> Try(List(U8), [NotAPair])
small_of = |program|
	if program == large_program {
		Ok(small_program)
	} else if program == many_changes {
		Ok(few_changes)
	} else {
		Err(NotAPair)
	}

# How many times its small example's bytes requested and held live a large
# example may take: thirty-two, twice the sixteen of the count, since a list
# grows geometrically from a fixed capacity and so requests, over its
# growth, up to about twice its final size, while the small example's list
# may never have grown. The list of changes starts with room for sixteen,
# which few-changes fills, so many-changes' 256 request 31.1 times as many
# bytes in `docx-revisions` and hold 23.1 times; every other region takes
# at most 17.8 times. A quadratic step costs sixteen times more again.
byte_ratio : U64
byte_ratio = 32

# The small and large declared programs repeat one program, the large one
# sixteen times as often. Each declared program begins with a plain
# paragraph and ends with plain text, its length a multiple of four, so that
# in both of a pair the edits are the same and succeed: the replacement
# `new` over the second character, a paragraph inserted before the second
# line and the first line's paragraph deleted.
small_program : List(U8)
small_program = List.join(List.repeat(program_unit, 4))

large_program : List(U8)
large_program = List.join(List.repeat(program_unit, 64))

# A plain paragraph, then an insertion, a deletion, a deleted mark, a move's
# source, an inserted mark, a nested change, a move's destination,
# formatting, a table, a hyperlink, a deleted field and marks moved away and
# here.
program_unit : List(U8)
program_unit = [1, 1, 0, 2, 3, 6, 4, 7, 8, 5, 0, 9, 10, 11, 12, 13, 1, 14, 0, 1]

# Sixteen and 256 changes of every kind.
few_changes : List(U8)
few_changes = changes_unit

many_changes : List(U8)
many_changes = List.join(List.repeat(changes_unit, 16))

# A plain paragraph, then sixteen changes: an insertion, a move's source and
# destination, a deleted and an inserted mark, a deletion holding an
# insertion, changed formatting, an inserted row, a deleted row, an inserted
# and a deleted cell, an insertion in a hyperlink, a deleted field and marks
# moved away and here, with text between them.
changes_unit : List(U8)
changes_unit = [1, 1, 0, 2, 4, 5, 6, 1, 7, 8, 9, 0x0A, 0x1A, 0x2A, 11, 12, 1, 13, 1, 14, 0, 1, 1, 1]

# The laws of a tracked edit against the same edit made silently: its final
# and original text are the silent edit's and the body's; accepting its
# changes, all of them or the editor's, gives the silent edit and rejecting
# them the body, up to how text is split; and it writes and reads back with
# the same final and original text.
laws : List(Document.Block), List(Document.Block), List(Document.Block) -> {}
laws = |body, silent, tracked| {
	if Revisions.text(tracked, Final) != Revisions.text(silent, Current) or Revisions.text(tracked, Original) != Revisions.text(body, Current) {
		crash "a tracked edit's final or original text differs"
	}
	if (Revisions.accept(tracked, All) ?? []).map(joined) != silent.map(joined) or (Revisions.accept(tracked, By("Morgan")) ?? []).map(joined) != silent.map(joined) {
		crash "accepting a tracked edit differs from the silent edit"
	}
	if (Revisions.reject(tracked, All) ?? []).map(joined) != body.map(joined) {
		crash "rejecting a tracked edit does not restore the body"
	}
	written = WmlWrite.document(shell, tracked, context) ?? crash "a tracked edit did not write"
	main = XmlTree.render(written.tree) ?? crash "a tracked edit did not render"
	graph = {
		relationships: [{ id: "rId1", kind: Opc.officedocument_relationship, target: "/word/document.xml", mode: Internal }],
		parts: [{ name: "/word/document.xml", content_type: main_type, relationships: written.relationships }],
	}
	parsed = Docx.parse(Opc.to_bytes(graph, |_| Bytes(main)) ?? crash "a tracked edit did not package") ?? crash "a tracked edit did not parse"
	if Docx.final_text(parsed.document) != Revisions.text(silent, Current) or Docx.original_text(parsed.document) != Revisions.text(body, Current) {
		crash "a written tracked edit's final or original text differs"
	}
	{}
}

by_morgan : Revisions.Context
by_morgan = Tracked({ author: "Morgan", date: Date("2026-11-10T09:00:00Z") })

# The offsets where lines of text begin, the end of the text among them.
line_starts : List(U8) -> List(U64)
line_starts = |text| {
	var $starts = [0]
	var $at = 0.U64
	for byte in text {
		$at = $at + 1
		if byte == 10 {
			$starts = List.append($starts, $at)
		}
	}
	$starts
}

# A paragraph of these properties saying `words`, for inserting.
said : Document.ParagraphProperties, Str -> Document.Block
said = |properties, words| Paragraph({ properties, content: [Run({ properties: Document.no_run_properties, content: [Text(words)] })] })

# A table of one row of two cells, for inserting.
new_table : Document.Block
new_table = {
	no_row = { header: Unset, grid_before: Unset, grid_after: Unset, preserved: [], inserted: Unset, deleted: Unset, change: [] }
	no_cell = { width: Unset, span: Unset, merge: Unset, borders: [], shading: Unset, alignment: Unset, preserved: [], revision: Unset, change: [] }
	cell = |words| Cell({ properties: no_cell, content: [said(Document.no_paragraph_properties, words)] })
	Table({ properties: { style: Unset, width: Unset, borders: [], shading: Unset, preserved: [], change: [] }, grid: [Column(1000), Column(1000)], content: [Row({ properties: no_row, content: [cell("x"), cell("y")] })] })
}

# A block with every two neighbouring runs of the same properties joined into
# one, and neighbouring text, hyperlinks to one target and changes of one
# kind, author and date joined, through tables, hyperlinks, fields and
# changes, so that blocks compare whatever runs, hyperlinks and changes
# their text is split into.
joined : Document.Block -> Document.Block
joined = |block|
	match block {
		Paragraph(paragraph) => Paragraph({ ..paragraph, content: joined_inlines(paragraph.content) })
		Table(table) => Table({ ..table, content: table.content.map(joined_table) })
		_ => block
	}

joined_table : Document.TableContent -> Document.TableContent
joined_table = |item|
	match item {
		Row(row) => Row({ ..row, content: row.content.map(joined_cell) })
		_ => item
	}

joined_cell : Document.RowContent -> Document.RowContent
joined_cell = |item|
	match item {
		Cell(cell) => Cell({ ..cell, content: cell.content.map(joined) })
		_ => item
	}

joined_inlines : List(Document.Inline) -> List(Document.Inline)
joined_inlines = |inlines|
	inlines.fold(
		[],
		|out, inline| {
			next = match inline {
				Hyperlink({ target, preserved, content }) => Hyperlink({ target, preserved, content: joined_inlines(content) })
				SimpleField({ code, preserved, content }) => SimpleField({ code, preserved, content: joined_inlines(content) })
				Revision(revision) => Revision({ ..revision, content: joined_inlines(revision.content) })
				_ => inline
			}
			match (out.last(), next) {
				(Ok(Run(before)), Run(run)) if before.properties == run.properties => List.append(out.drop_last(1), Run({ ..run, content: joined_text(List.concat(before.content, run.content)) }))
				(Ok(Hyperlink(before)), Hyperlink(link)) if before.target == link.target and before.preserved == link.preserved => List.append(out.drop_last(1), Hyperlink({ ..link, content: joined_inlines(List.concat(before.content, link.content)) }))
				(Ok(Revision(before)), Revision(revision)) if before.kind == revision.kind and before.author == revision.author and before.date == revision.date and before.preserved == revision.preserved => List.append(out.drop_last(1), Revision({ ..revision, content: joined_inlines(List.concat(before.content, revision.content)) }))
				_ => List.append(out, next)
			}
		},
	)

joined_text : List(Document.RunContent) -> List(Document.RunContent)
joined_text = |content|
	content.fold(
		[],
		|out, item|
			match (out.last(), item) {
				(Ok(Text(before)), Text(more)) => List.append(out.drop_last(1), Text(Str.concat(before, more)))
				_ => List.append(out, item)
			},
	)

main_type : Str
main_type = "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"

wordprocessingml : Str
wordprocessingml = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

context : WmlWrite.Context
context = { relationships: [], footnotes: [], endnotes: [], comments: [] }

shell : XmlTree.Node
shell = Element({ name: w("document"), bindings: [], attributes: [], children: [] })

w : Str -> XmlTree.Name
w = |local| { namespace: Uri(wordprocessingml), local, prefix: Prefix("w") }

stamp : Document.Timestamp
stamp = { written: "2026-05-07T09:00:00Z", utc_seconds: 1778144400 }

run : Str -> Document.Inline
run = |words| Run({ properties: Document.no_run_properties, content: [Text(words)] })

change : Document.RevisionKind, List(Document.Inline) -> Document.Inline
change = |kind, content| Revision({ kind, author: "Ada", date: Date(stamp), content, preserved: [] })

paragraph : Document.ParagraphProperties, List(Document.Inline) -> Document.Block
paragraph = |properties, content| Paragraph({ properties, content })

# The three bodies a program describes, one step a byte: the low four bits
# choose the step and the rest its variant. Each body collects its current
# paragraph's content; a paragraph whose mark a view takes away keeps
# collecting into the next in that view's body, as the view's text runs it
# on. A table ends the paragraph before it, and a body always ends with a
# paragraph.
Building : {
	tracked : List(Document.Block),
	final : List(Document.Block),
	original : List(Document.Block),
	in_tracked : List(Document.Inline),
	in_final : List(Document.Inline),
	in_original : List(Document.Inline),
	moves : U64,
}

bodies : List(U8) -> { tracked : List(Document.Block), final : List(Document.Block), original : List(Document.Block) }
bodies = |program| {
	var $state = { tracked: List.with_capacity(program.len()), final: List.with_capacity(program.len()), original: List.with_capacity(program.len()), in_tracked: [], in_final: [], in_original: [], moves: 0.U64 }
	for byte in program {
		$state = step($state, byte % 16, (byte // 16).to_u64())
	}
	ended = end($state, [])
	{ tracked: ended.tracked, final: ended.final, original: ended.original }
}

# Content added to each body's current paragraph: the tracked content, and
# what of it stands once every change is accepted and once every change is
# rejected.
adding : Building, List(Document.Inline), List(Document.Inline), List(Document.Inline) -> Building
adding = |state, tracked, final, original| {
	..state,
	in_tracked: List.concat(state.in_tracked, tracked),
	in_final: List.concat(state.in_final, final),
	in_original: List.concat(state.in_original, original),
}

# The current paragraph ended by a mark with `mark`'s changes: the accepted
# body runs on past a mark deleted or moved away, the rejected body past a
# mark inserted or moved here.
end : Building, List(Document.RevisionKind) -> Building
end = |state, mark| {
	marked = { ..Document.no_paragraph_properties, mark: mark.map(|kind| { kind, author: "Ada", date: Date(stamp), preserved: [] }) }
	plain = Document.no_paragraph_properties
	away = mark.contains(Deletion) or mark.contains(MoveSource)
	here = mark.contains(Insertion) or mark.contains(MoveDestination)
	(final, in_final) = if (away) (state.final, state.in_final) else (List.append(state.final, paragraph(plain, state.in_final)), [])
	(original, in_original) = if (here) (state.original, state.in_original) else (List.append(state.original, paragraph(plain, state.in_original)), [])
	{ ..state, tracked: List.append(state.tracked, paragraph(marked, state.in_tracked)), in_tracked: [], final, in_final, original, in_original }
}

step : Building, U8, U64 -> Building
step = |state, kind, variant|
	match kind {
		0 => end(state, [])
		1 => adding(state, [run("a")], [run("a")], [run("a")])
		2 => adding(state, [change(Insertion, [run("i")])], [run("i")], [])
		3 => adding(state, [change(Deletion, [run("d")])], [], [run("d")])
		4 => moved(state, Source)
		5 => moved(state, Destination)
		6 => end(state, [Deletion])
		7 => end(state, [Insertion])
		8 => adding(state, [change(Deletion, [run("x"), change(Insertion, [run("y")])])], [], [run("x")])
		9 => {
			bold = { ..Document.no_run_properties, bold: On }
			formatted = Run({ properties: { ..bold, change: [{ author: "Ada", date: Date(stamp), preserved: [], previous: Document.run_properties_with(Unset) }] }, content: [Text("f")] })
			adding(state, [formatted], [Run({ properties: bold, content: [Text("f")] })], [run("f")])
		}

		10 => tabled(end(state, []), variant)
		11 => {
			link = |content| Hyperlink({ target: Internal("x"), preserved: [], content })
			adding(state, [link([change(Insertion, [run("l")])])], [link([run("l")])], [link([])])
		}

		12 => {
			mark = |which, name| FieldMark({ kind: which, element: Element({ name: w("fldChar"), bindings: [], attributes: [{ name: w("fldCharType"), value: name }], children: [] }) })
			field = Run({ properties: Document.no_run_properties, content: [mark(Begin, "begin"), FieldCode(" PAGE "), mark(Separate, "separate"), Text("1"), mark(End, "end")] })
			adding(state, [change(Deletion, [field])], [], [field])
		}

		13 => end(state, [MoveSource])
		14 => end(state, [MoveDestination])
		_ => adding(state, [run("b")], [run("b")], [run("b")])
	}

# Content moved away from here or arriving here, within its move's range.
moved : Building, Document.MoveSide -> Building
moved = |state, side| {
	name = "move${state.moves.to_str()}"
	(kind, final, original) = match side {
		Source => (MoveSource, [], [run("m")])
		Destination => (MoveDestination, [run("m")], [])
	}
	tracked = [MoveStart({ side, name, author: "Ada", date: stamp, preserved: [] }), change(kind, [run("m")]), MoveEnd({ side, name })]
	{ ..adding(state, tracked, final, original), moves: state.moves + 1 }
}

# A table after the current paragraph: a plain row, and, as the variant
# says, an inserted row, a deleted row or a row with an inserted and a
# deleted cell.
tabled : Building, U64 -> Building
tabled = |state, variant| {
	by = Tracked({ author: "Ada", date: Date(stamp), preserved: [] })
	no_row = { header: Unset, grid_before: Unset, grid_after: Unset, preserved: [], inserted: Unset, deleted: Unset, change: [] }
	no_cell = { width: Unset, span: Unset, merge: Unset, borders: [], shading: Unset, alignment: Unset, preserved: [], revision: Unset, change: [] }
	cell = |revision, words| Cell({ properties: { ..no_cell, revision }, content: [paragraph(Document.no_paragraph_properties, [run(words)])] })
	row = |properties, cells| Row({ properties, content: cells })
	table = |rows| Table({ properties: { style: Unset, width: Unset, borders: [], shading: Unset, preserved: [], change: [] }, grid: [Column(1000), Column(1000)], content: rows })
	plain = row(no_row, [cell(Unset, "r")])
	(tracked, final, original) = match variant % 3 {
		0 => (table([plain, row({ ..no_row, inserted: by }, [cell(Unset, "ri")])]), table([plain, row(no_row, [cell(Unset, "ri")])]), table([plain]))
		1 => (table([plain, row({ ..no_row, deleted: by }, [cell(Unset, "rd")])]), table([plain]), table([plain, row(no_row, [cell(Unset, "rd")])]))
		_ => {
			change_of = { author: "Ada", date: Date(stamp), preserved: [] }
			(table([row(no_row, [cell(Unset, "c"), cell(Inserted(change_of), "ci"), cell(Deleted(change_of), "cd")])]), table([row(no_row, [cell(Unset, "c"), cell(Unset, "ci")])]), table([row(no_row, [cell(Unset, "c"), cell(Unset, "cd")])]))
		}
	}
	{ ..state, tracked: List.append(state.tracked, tracked), final: List.append(state.final, final), original: List.append(state.original, original) }
}

target = Fuzz.target_with!({
	name: "revision-algebra",
	examples: [
		Fuzz.example({ name: "small-program", revision: "2", make: || small_program }),
		Fuzz.example({ name: "large-program", revision: "2", make: || large_program }),
		Fuzz.example({ name: "few-changes", revision: "1", make: || few_changes }),
		Fuzz.example({ name: "many-changes", revision: "1", make: || many_changes }),
	],
	generator,
	test!,
	show: |program| Str.inspect(program),
})
