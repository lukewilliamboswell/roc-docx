import docx.Build
import docx.Docx
import docx.Document
import docx.Revisions
import fuzz.Model

BlockEditHistory := [].{
	exhausted : {} -> Bool
	exhausted = |{}| {
		report = Model.explore(machine, { depth: 7, key: |world| world.history })
		if report.verdict != Holds(Exhausted) {
			crash "${Model.explain(report)} Verdict: ${Str.inspect(report.verdict)}"
		}
		report.depth == 6 and report.states == 1484
	}
}

Line : { text : Str, style : [Normal, Heading(U8), Style(Str)] }

Layout : { before : List(Line), left : List(Line), right : Line, after : Line }

Edit : [BeforeTable, IntoCell, DeleteInside]

Action : [Change(Edit), SplitCharacter, CrossCells, Accept, Reject]

Pending : [Settled, Waiting(Edit, Layout)]

World : {
	document : Document,
	layout : Layout,
	pending : Pending,
	history : List(Action),
	reply : [Ready, Changed, Refused(Docx.EditError)],
}

plain : Str -> Line
plain = |text| { text, style: Normal }

seed : Layout
seed = {
	before: [{ text: "é ", style: Heading(1) }],
	left: [plain("first"), { text: "middle", style: Heading(2) }, plain("last")],
	right: plain("next cell"),
	after: plain("after"),
}

before_table : Line
before_table = { text: "new heading", style: Heading(2) }

in_cell : Line
in_cell = plain("new in cell")

paragraph : Line -> Document.Block
paragraph = |line| Build.paragraph({ style: line.style }, [Build.text(line.text, {})])

blocks : Layout -> List(Document.Block)
blocks = |layout| {
	table = Build.table({}, [[Build.cell({}, layout.left.map(paragraph)), Build.cell({}, [paragraph(layout.right)])]])
	layout.before.map(paragraph).concat([table, paragraph(layout.after)])
}

lines_text : List(Line) -> Str
lines_text = |lines| lines.fold("", |out, line| "${out}${line.text}\n")

text_of : Layout -> Str
text_of = |layout| lines_text(layout.before.concat(layout.left).concat([layout.right, layout.after]))

table_start : Layout -> U64
table_start = |layout| lines_text(layout.before).count_utf8_bytes()

inside_cell : Layout -> U64
inside_cell = |layout| table_start(layout) + lines_text(layout.left.take_first(1)).count_utf8_bytes()

middle_index : Layout -> U64
middle_index = |layout| layout.left.find_first_index(|line| line.text == "middle") ?? crash "no middle paragraph to delete"

cross_end : Layout -> U64
cross_end = |layout| table_start(layout) + lines_text(layout.left.append(layout.right)).count_utf8_bytes()

# Each edit kind is offered once and a history tries at most two. Probes
# are offered before, during, or after tracked changes.
actions : World -> List(Action)
actions = |world| {
	probes = [SplitCharacter, CrossCells].drop_if(|action| world.history.contains(action))
	match world.pending {
		Waiting(_, _) => probes.concat([Accept, Reject])
		Settled => {
			edits = [Change(BeforeTable), Change(IntoCell), Change(DeleteInside)]
			unused = edits.drop_if(|action| world.history.contains(action))
			if (unused.len() > 1) probes.concat(unused) else probes
		}
	}
}

predict : World, Action -> { layout : Layout, pending : Pending }
predict = |world, action| {
	layout = world.layout
	match action {
		Change(edit) => {
			edited = match edit {
				BeforeTable => { ..layout, before: layout.before.append(before_table) }
				IntoCell => { ..layout, left: layout.left.take_first(1).concat([in_cell]).concat(layout.left.drop_first(1)) }
				DeleteInside => { ..layout, left: layout.left.drop_if(|line| line.text == "middle") }
			}
			{ layout: edited, pending: Waiting(edit, layout) }
		}
		Accept => { layout, pending: Settled }
		Reject => match world.pending {
			Waiting(_, prior) => { layout: prior, pending: Settled }
			Settled => crash "there is no edit to reject"
		}
		SplitCharacter | CrossCells => { layout, pending: world.pending }
	}
}

tracked : Revisions.Context
tracked = Tracked({ author: "Ada", date: Unset })

apply : World, Action -> Try(Document, Docx.EditError)
apply = |world, action| {
	document = world.document
	layout = world.layout
	match action {
		Change(BeforeTable) => Docx.insert_blocks(document, table_start(layout), [paragraph(before_table)], tracked)
		Change(IntoCell) => Docx.insert_blocks(document, inside_cell(layout), [paragraph(in_cell)], tracked)
		Change(DeleteInside) => {
			index = middle_index(layout)
			start = table_start(layout) + lines_text(layout.left.take_first(index)).count_utf8_bytes()
			Docx.delete_blocks(document, { start, end: start + "middle\n".count_utf8_bytes() }, tracked)
		}
		SplitCharacter => Docx.insert_blocks(document, 1, [paragraph(in_cell)], tracked)
		CrossCells => Docx.delete_blocks(document, { start: inside_cell(layout), end: cross_end(layout) }, tracked)
		Accept => Docx.accept_all(document)
		Reject => Docx.reject_all(document)
	}
}

step : World, Action -> World
step = |world, action| {
	{ layout, pending } = predict(world, action)
	next = { ..world, layout, pending, history: world.history.append(action) }
	match apply(world, action) {
		Ok(document) => { ..next, document, reply: Changed }
		Err(error) => { ..next, reply: Refused(error) }
	}
}

projections_match : World -> Bool
projections_match = |world| {
	original = match world.pending {
		Settled => world.layout
		Waiting(_, prior) => prior
	}
	expected = text_of(world.layout)
	Docx.text(world.document) == expected and Docx.final_text(world.document) == expected and Docx.original_text(world.document) == text_of(original)
}

same_result : World -> Bool
same_result = |world| {
	changes = Docx.revisions(world.document).map(|change| (change.kind, change.of, change.author))
	match world.pending {
		Settled => {
			content = Docx.body(world.document).drop_if(
				|block| match block {
					Section(_) => Bool.True
					_ => Bool.False
				},
			)
			changes.is_empty() and content == blocks(world.layout)
		}
		Waiting(BeforeTable, _) => changes == [(Insertion, ParagraphMark, "Ada"), (Formatting, Paragraph, "Ada"), (Insertion, Content, "Ada")]
		Waiting(IntoCell, _) => changes == [(Insertion, Content, "Ada"), (Insertion, ParagraphMark, "Ada")]
		Waiting(DeleteInside, _) => changes == [(Deletion, Content, "Ada"), (Deletion, ParagraphMark, "Ada")]
	}
}

machine : Model.Machine(World, Action)
machine = {
	init: {
		document: Build.append(Docx.new_document({}) ?? crash "the kit did not build", blocks(seed)),
		layout: seed,
		pending: Settled,
		history: [],
		reply: Ready,
	},
	actions,
	step,
	rules: [
		Model.always("block edits have the predicted text in all three views", projections_match),
		Model.always("the pending changes or settled block structure match the edit", same_result),
		Model.always_step(
			"the caller receives the exact result at each byte boundary",
			|{ before, action, after }| {
				match action {
					SplitCharacter => after.reply == Refused(NotABlockBoundary(1))
					CrossCells => after.reply == Refused(NotABlockBoundary(cross_end(before.layout)))
					_ => after.reply == Changed
				}
			},
		),
		Model.sometimes_step(
			"a valid cell deletion follows a refused cross-cell deletion",
			|{ before, action, after }| {
				before.history.last() == Ok(CrossCells) and action == Change(DeleteInside) and after.reply == Changed
			},
		),
		Model.sometimes_step(
			"reject restores a preceding paragraph with a different style",
			|{ before, action, after: _ }| {
				action == Reject and match before.pending {
					Waiting(BeforeTable, _) => Bool.True
					_ => Bool.False
				}
			},
		),
		Model.sometimes_step(
			"second edit addresses a cell after a new paragraph shifted the table",
			|{ before, action, after: _ }| {
				action == Change(IntoCell) and before.layout.before.len() == 2
			},
		),
	],
}
