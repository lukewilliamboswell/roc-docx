import docx.Build
import docx.Docx
import docx.Document
import docx.Revisions
import fuzz.Model

# A character is part of the original, or needs its insertion to stand.
# Independently, a pending deletion hides the character until rejected.
# This lets the reference account for a deletion inside an insertion
# without representing the document as a tree of revision wrappers.
Author : [Ada, Bo]

Mark : [Unchanged, Pending(Author)]

Character : { byte : U8, birth : Mark, death : Mark }

Selection : [Everyone, Only(Author)]

Action : [Prefix, CutPrefix, ReplaceLast, Accept(Selection), Reject(Selection)]

World : { document : Try(Document, Docx.EditError), text : List(Character), history : List(Action) }

machine : Model.Machine(World, Action)
machine = {
	init: {
		document: Ok(
			Build.append(
				Docx.new_document({}) ?? crash "the default document kit did not build",
				[Build.paragraph({}, [Build.text("ab", {})])],
			),
		),
		text: [plain('a'), plain('b')],
		history: [],
	},
	actions,
	step,
	rules: [
		Model.always("the current text hides pending deletions", |world| world.document.map_ok(Docx.text) == Ok(projected(world.text, Current))),
		Model.always("the final text keeps pending insertions and omits pending deletions", |world| world.document.map_ok(Docx.final_text) == Ok(projected(world.text, Current))),
		Model.always("the original text omits pending insertions and restores pending deletions", |world| world.document.map_ok(Docx.original_text) == Ok(projected(world.text, Original))),
		Model.always("the pending authors and kinds agree with the reference", pending_agrees),
		Model.sometimes_step(
			"accepting an insertion leaves another author's nested deletion pending",
			|{ before, action, after }| {
				action == Accept(Only(Ada))
					and before.text.contains({ byte: 'x', birth: Pending(Ada), death: Pending(Bo) })
					and after.text.contains({ byte: 'x', birth: Unchanged, death: Pending(Bo) })
			},
		),
		Model.sometimes_step(
			"rejecting a nested deletion restores the byte inside its pending insertion",
			|{ before, action, after }| {
				action == Reject(Only(Bo))
					and before.text.contains({ byte: 'x', birth: Pending(Ada), death: Pending(Bo) })
					and after.text.contains({ byte: 'x', birth: Pending(Ada), death: Unchanged })
			},
		),
		Model.sometimes_step(
			"a replacement crosses a hidden byte when locating its visible span",
			|{ before, action, after: _ }| {
				action == ReplaceLast and before.text.any(|character| character.byte == 'x' and character.death == Pending(Bo))
			},
		),
	],
}

plain : U8 -> Character
plain = |byte| { byte, birth: Unchanged, death: Unchanged }

inserted : U8, Author -> Character
inserted = |byte, author| { ..plain(byte), birth: Pending(author) }

projected : List(Character), [Current, Original] -> Str
projected = |characters, view| {
	visible = match view {
		Current => characters.keep_if(|character| character.death == Unchanged)
		Original => characters.keep_if(|character| character.birth == Unchanged)
	}
	Str.from_utf8(visible.map(|character| character.byte).append('\n')) ?? crash "the reference uses ASCII bytes"
}

author_name : Author -> Str
author_name = |author| match author {
	Ada => "Ada"
	Bo => "Bo"
}

selected : Mark, Selection -> Bool
selected = |mark, selection| match (mark, selection) {
	(Pending(_), Everyone) => Bool.True
	(Pending(author), Only(who)) => author == who
	(Unchanged, _) => Bool.False
}

pending_agrees : World -> Bool
pending_agrees = |world| match world.document {
	Err(_) => Bool.False
	Ok(document) => {
		actual = Docx.revisions(document).map(|change| (change.author, change.kind))
		expected = world.text.join_map(
			|character| {
				birth = match character.birth {
					Unchanged => []
					Pending(author) => [(author_name(author), Insertion)]
				}
				death = match character.death {
					Unchanged => []
					Pending(author) => [(author_name(author), Deletion)]
				}
				birth.concat(death)
			},
		)
		# One wrapper can hold several characters or be split into runs.
		actual.all(|change| expected.contains(change)) and expected.all(|change| actual.contains(change))
	}
}

# Each edit happens at most once. Resolve only pending selections, so the
# search has a finite history tree without a depth cutoff at an active state.
actions : World -> List(Action)
actions = |world| {
	edits = [Prefix, CutPrefix, ReplaceLast].keep_if(
		|action| {
			!world.history.contains(action) and (action != CutPrefix or world.text.any(|character| character.byte == 'x' and character.death == Unchanged))
		},
	)
	resolutions = [Everyone, Only(Ada), Only(Bo)].keep_if(
		|selection| {
			world.text.any(|character| selected(character.birth, selection) or selected(character.death, selection))
		},
	)
	edits.concat(resolutions.join_map(|selection| [Accept(selection), Reject(selection)]))
}

resolved : List(Character), Selection, [KeepNew, KeepOld] -> List(Character)
resolved = |characters, selection, decision| {
	keeps = |character| match decision {
		KeepNew => !selected(character.death, selection)
		KeepOld => !selected(character.birth, selection)
	}
	characters.keep_if(keeps).map(
		|character| {
			..character,
			birth: if (selected(character.birth, selection)) Unchanged else character.birth,
			death: if (selected(character.death, selection)) Unchanged else character.death,
		},
	)
}

selection_of : Selection -> Revisions.Selection
selection_of = |selection| match selection {
	Everyone => All
	Only(author) => By(author_name(author))
}

tracked : Author -> Revisions.Context
tracked = |author| Tracked({ author: author_name(author), date: Unset })

# The application receives byte offsets in the current view. Obtain them
# from the independently projected text, with the hidden bytes already gone.
edit : Try(Document, Docx.EditError), List(Character), Action -> Try(Document, Docx.EditError)
edit = |prior, characters, action| {
	document = prior?
	match action {
		Prefix => Docx.insert_text(document, 0, "xy", tracked(Ada))
		CutPrefix => Docx.delete_text(document, { start: 0, end: 1 }, tracked(Bo))
		ReplaceLast => {
			at = projected(characters, Current).to_utf8().len() - 2
			Docx.replace_text(document, { start: at, end: at + 1 }, "z", tracked(Bo))
		}
		Accept(selection) => Docx.accept(document, selection_of(selection))
		Reject(selection) => Docx.reject(document, selection_of(selection))
	}
}

step : World, Action -> World
step = |world, action| {
	document = edit(world.document, world.text, action)
	text = match action {
		Prefix => [inserted('x', Ada), inserted('y', Ada)].concat(world.text)
		CutPrefix => world.text.map(|character| if (character.byte == 'x') { ..character, death: Pending(Bo) } else character)
		ReplaceLast => world.text.map(|character| if (character.byte == 'b') { ..character, death: Pending(Bo) } else character).append(inserted('z', Bo))
		Accept(selection) => resolved(world.text, selection, KeepNew)
		Reject(selection) => resolved(world.text, selection, KeepOld)
	}
	{ document, text, history: world.history.append(action) }
}

## All histories over the three single-use edits and every enabled
## resolution are searched. Keying by the whole trace preserves distinct
## document states even when their current text and pending authors agree.
expect {
	report = Model.explore(machine, { depth: 7, key: |world| world.history })
	if report.verdict != Holds(Exhausted) {
		crash "${Model.explain(report)} Verdict: ${Str.inspect(report.verdict)}"
	}
	report.depth == 6 and report.states == 713
}
