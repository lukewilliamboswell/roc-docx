import docx.Build
import docx.Comments
import docx.Docx
import docx.Document
import docx.Opc
import docx.Revisions
import docx.WmlRead
import fuzz.Model
import fuzz.Solve
import BlockHistory

Spec := [].{}

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

## XML Schema 1.0 §3.2.7.3 allows two-digit timezone minutes only up to
## 59, and permits hour 14 only with zero minutes. On the full two-digit
## input domain, the parser's total-minute cap implements that rule.
expect Solve.prove_within(
	{ hours: Solve.u16_in(0, 99), minutes: Solve.u16_in(0, 99) }.Solve,
	|zone| {
		parser = zone.minutes.lt(60).both((zone.hours * 60 + zone.minutes).lte(840))
		schema = zone.hours.lt(14).both(zone.minutes.lt(60)).either(zone.hours.eq(14).both(zone.minutes.eq(0)))
		parser.iff(schema)
	},
	25_000,
) == Ok(Proved)

two_digits : U64 -> Str
two_digits = |n| if (n < 10) "0${n.to_str()}" else n.to_str()

## Drive every signed offset with two decimal digits per field through
## the timestamp parser, checking its accepted instants against the epoch.
expect {
	for sign in ["+", "-"] {
		for hours in (0.U64).until(100) {
			for minutes in (0.U64).until(100) {
				written = "1970-01-01T00:00:00${sign}${two_digits(hours)}:${two_digits(minutes)}"
				seconds = (hours * 3600 + minutes * 60).to_i64_wrap()
				expected = if (hours < 14 and minutes < 60) or (hours == 14 and minutes == 0) {
					Ok({ written, utc_seconds: if (sign == "+") -seconds else seconds })
				} else {
					Err(NotDate)
				}
				if WmlRead.date_time(written) != expected {
					crash "incorrect dateTime zone in ${written}"
				}
			}
		}
	}
	Bool.True
}

## XML Schema 1.0 §3.2.7.1 starts the supported unsigned four-digit years
## at 0001. The first year still maps to its proleptic Gregorian instant.
expect {
	first = "0001-01-01T12:00:00Z"
	WmlRead.date_time(first) == Ok({ written: first, utc_seconds: -62_135_553_600 })
		and WmlRead.date_time("0000-01-01T12:00:00Z") == Err(NotDate)
}

## Comment authoring refuses invalid dates. The two legal timezone endpoints
## cross a day in opposite directions and retain their original spelling
## through writing and reopening the document.
expect {
	document = Build.append(Docx.new_document({})?, [Build.paragraph({}, [Build.text("ab", {})])])
	span = { start: 0, end: 1 }
	new = |written| Comments.New.{ author: "Ada", content: Text("Review"), date: Date(written) }
	positive = "1970-01-01T00:30:00+14:00"
	negative = "1970-01-01T23:30:00-14:00"
	added = Docx.add_comment(document, span, new(positive))?
	replied = Docx.reply(added.document, added.id, new(negative))?
	reopened = Docx.parse(Docx.to_bytes(replied.document)?)?
	dates = Docx.comments(reopened.document).comments.map(|entry| entry.comment.date)
	dates == [Date({ written: positive, utc_seconds: -48_600 }), Date({ written: negative, utc_seconds: 135_000 })]
		and ["1970-01-01T00:00:00+02:60", "1970-01-01T00:00:00-14:01", "0000-01-01T12:00:00Z"].all(
			|written| Docx.add_comment(document, span, new(written)).map_ok(|_| {}) == Err(NotADate(written))
				and Docx.reply(added.document, added.id, new(written)).map_ok(|_| {}) == Err(NotADate(written)),
		)
}

## Structural edits distinguish a table from the paragraphs in its cells.
## Exhaust short histories of tracked insertions, deletions, resolutions,
## and failed attempts at byte and cell boundaries.
expect BlockHistory.exhausted({})

## A tracked-deleted paragraph mark cannot join through a table. The
## table's byte boundary refers to the table itself. Refuse a span ending
## inside it, then retry both public block edits at that outer boundary.
expect {
	part = "/word/document.xml"
	first = "<w:p><w:pPr><w:rPr><w:del w:id='1' w:author='Ada'/></w:rPr></w:pPr><w:r><w:t>é</w:t></w:r></w:p>"
	table = "<w:tbl><w:tblPr/><w:tblGrid><w:gridCol w:w='1000'/></w:tblGrid><w:tr><w:tc><w:p><w:r><w:t>cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>"
	last = "<w:p><w:r><w:t>after</w:t></w:r></w:p>"
	xml = "<w:document xmlns:w='http://schemas.openxmlformats.org/wordprocessingml/2006/main'><w:body>${first}${table}${last}</w:body></w:document>"
	bytes = Opc.to_bytes(
		{
			relationships: [{ id: "rId1", kind: Opc.officedocument_relationship, target: part, mode: Internal }],
			parts: [{ name: part, content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml", relationships: [] }],
		},
		|_| Bytes(xml.to_utf8()),
	)?
	document = (Docx.parse(bytes)?).document
	original_body = Docx.body(document)
	refused = Docx.delete_blocks(document, { start: 3, end: 7 }, Untracked).map_ok(|_| {})
	new_table = Build.table({}, [[Build.cell({}, [Build.paragraph({}, [Build.text("new", {})])])]])
	put_before = Docx.insert_blocks(document, 3, [new_table], Untracked)?
	removed = Docx.delete_blocks(document, { start: 3, end: 8 }, Untracked)?
	by_bo = Tracked({ author: "Bo", date: Unset })
	tracked_insert = Docx.insert_blocks(document, 3, [new_table], by_bo)?
	tracked_remove = Docx.delete_blocks(document, { start: 3, end: 8 }, by_bo)?
	match original_body {
		[before, old_table, after] =>
			Docx.text(document) == "é\ncell\nafter\n"
				and refused == Err(NotABlockBoundary(7))
				and Docx.body(document) == original_body
				and Docx.body(put_before) == [before, new_table, old_table, after]
				and Docx.body(removed) == [before, after]
				and Docx.text(removed) == "éafter\n"
				and Docx.original_text(removed) == "é\nafter\n"
				and Docx.body(Docx.accept(tracked_insert, By("Bo"))?) == Docx.body(put_before)
				and Docx.body(Docx.reject(tracked_insert, By("Bo"))?) == original_body
				and Docx.body(Docx.accept(tracked_remove, By("Bo"))?) == Docx.body(removed)
				and Docx.body(Docx.reject(tracked_remove, By("Bo"))?) == original_body
		_ => Bool.False
	}
}
