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

## The final and original text of a document with tracked changes agree with
## the text of the untracked documents those changes lead to and come from.
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
## accepted and rejected bodies. The tracked body is then written by
## `WmlWrite.document` into a package that `Docx.parse` must read back as the
## same body, whose `Docx.final_text` and `Docx.original_text` are those
## texts again.
##
## Allocation ratchets, which only ever move down: the final and original
## text of the tracked body take at most linearly many allocations and bytes
## live in the program's length, and each declared example allocates no more
## than it did when its ceiling was set. The large declared program, sixteen
## times the small one, allocates, requests and holds live at most sixteen
## times what the small one does in the same run. Raising a ceiling needs a
## cause recorded in the pull request.
test! : List(U8) => Fuzz.Outcome
test! = |program| {
	cost = texts!(program)
	match exact_ceiling(program) {
		Ok(ceiling) =>
			if cost.allocations > ceiling {
				crash "a declared program allocated more than its ceiling"
			}

		Err(NotDeclared) => {}
	}
	if program == large_program {
		small = texts!(small_program)
		if cost.allocations > 16 * small.allocations or cost.requested_bytes > 16 * small.requested_bytes or cost.held_bytes > 16 * small.held_bytes {
			crash "the large program cost more than sixteen times the small one"
		}
	}
	Fuzz.keep
}

generator : Fuzz.Generator(List(U8))
generator = Fuzz.bytes

# Build a program's bodies, measure the tracked body's final and original
# text, and check them against the untracked bodies and through writing and
# reading. Returns the allocations and reallocations the texts took, the
# bytes they requested and the most they held live beyond entry.
texts! : List(U8) => { allocations : U64, requested_bytes : U64, held_bytes : U64 }
texts! = |program| {
	built = bodies(program)
	{ value: (final, original), stats } = Fuzz.measure!("revisions-text", || (Revisions.text(built.tracked, Final), Revisions.text(built.tracked, Original)))
	if stats.allocs + stats.reallocs > linear_allocation_ceiling(program.len()) {
		crash "the texts allocated more than linearly in the program's length"
	}
	if stats.peak_live_bytes - stats.entry_live_bytes > linear_memory_ceiling(program.len()) {
		crash "the texts held more than linearly many bytes live"
	}
	if final != Revisions.text(built.final, Current) {
		crash "the final text differs from the text of the accepted body"
	}
	if original != Revisions.text(built.original, Current) {
		crash "the original text differs from the text of the rejected body"
	}
	written = WmlWrite.document(shell, built.tracked, context) ?? crash "a tracked body did not write"
	main = XmlTree.render(written.tree) ?? crash "a written body did not render"
	graph = {
		relationships: [{ id: "rId1", kind: Opc.officedocument_relationship, target: "/word/document.xml", mode: Internal }],
		parts: [{ name: "/word/document.xml", content_type: main_type, relationships: written.relationships }],
	}
	bytes = Opc.to_bytes(graph, |_| Bytes(main)) ?? crash "a written body did not package"
	parsed = Docx.parse(bytes) ?? crash "a written document did not parse"
	if Docx.body(parsed.document) != built.tracked {
		crash "a written body read back differently"
	}
	if Docx.final_text(parsed.document) != final or Docx.original_text(parsed.document) != original {
		crash "a written document's final or original text differs"
	}
	{ allocations: stats.allocs + stats.reallocs, requested_bytes: stats.requested_bytes, held_bytes: stats.peak_live_bytes - stats.entry_live_bytes }
}

# Measured on nightly-2026-11-07: the declared programs, of 68 and 1,088
# bytes, take 3.3 and 3.1 allocations a byte and hold 1,289 and 4,593 bytes
# live.
linear_allocation_ceiling : U64 -> U64
linear_allocation_ceiling = |length| 64 + 8 * length

linear_memory_ceiling : U64 -> U64
linear_memory_ceiling = |length| 16_384 + 64 * length

# Exact ceilings: the allocations and reallocations of the declared
# programs' texts, as measured on nightly-2026-11-07 when the ceiling was
# set.
exact_ceiling : List(U8) -> Try(U64, [NotDeclared])
exact_ceiling = |program|
	if program == small_program {
		Ok(224)
	} else if program == large_program {
		Ok(3_352)
	} else {
		Err(NotDeclared)
	}

# The small and large declared programs repeat one program, the large one
# sixteen times as often. Their texts take 224 and 3,352 allocations, request
# 18,606 and 263,290 bytes and hold 1,289 and 4,593 live, ratios of 15.0,
# 14.2 and 3.6 against the sixteen the test allows.
small_program : List(U8)
small_program = List.join(List.repeat(program_unit, 4))

large_program : List(U8)
large_program = List.join(List.repeat(program_unit, 64))

# Plain text, an insertion, a deletion, a deleted mark, a move's source, an
# inserted mark, a nested change, a move's destination, formatting, a
# table, a hyperlink, a deleted field and marks moved away and here.
program_unit : List(U8)
program_unit = [1, 2, 3, 6, 4, 7, 8, 5, 0, 9, 10, 11, 12, 13, 1, 14, 0]

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
			formatted = Run({ properties: { ..Document.no_run_properties, bold: On, change: [{ author: "Ada", date: Date(stamp), preserved: [], previous: Document.run_properties_with(Unset) }] }, content: [Text("f")] })
			adding(state, [formatted], [run("f")], [run("f")])
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
		Fuzz.example({ name: "small-program", revision: "1", make: || small_program }),
		Fuzz.example({ name: "large-program", revision: "1", make: || large_program }),
	],
	generator,
	test!,
	show: |program| Str.inspect(program),
})
