import docx.Docx
import docx.Document
import docx.Opc
import fuzz.Model

FacadePartHistory := [].{}

Occupied : [ExactSettings, ExactComments]

Action : [Track, OddAndEven, Comment, Reopen]

World : { document : Document, history : List(Action), intact : Bool }

main : Str
main = "/stories/main.xml"

relation_kind : Str -> Str
relation_kind = |kind| "http://schemas.openxmlformats.org/officeDocument/2006/relationships/${kind}"

payloads : Occupied -> List({ name : Str, bytes : List(U8) })
payloads = |occupied| [
	{ name: if (occupied == ExactSettings) "/stories/settings.xml" else "/Stories/Settings.xml", bytes: [18, 0, 249] },
	{ name: if (occupied == ExactComments) "/stories/comments.xml" else "/Stories/Comments.xml", bytes: [255, 24, 0] },
	{ name: "/Stories/Settings2.xml", bytes: [4, 1] },
	{ name: "/Stories/Comments2.xml", bytes: [6, 2] },
]

opaque_link : Occupied -> Opc.Relationship
opaque_link = |occupied| {
	part = payloads(occupied).first() ?? crash "missing payload"
	{ id: "rId4", kind: "urn:example:stored-record", target: part.name, mode: Internal }
}

fixture : Occupied -> Try(List(U8), Opc.WriteError)
fixture = |occupied| {
	blobs = payloads(occupied)
	names = blobs.map(|blob| { name: blob.name, content_type: "application/octet-stream", relationships: [] })
	primary = { name: main, content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml", relationships: [opaque_link(occupied)] }
	source = "<w:document xmlns:w='http://schemas.openxmlformats.org/wordprocessingml/2006/main'><w:body><w:p><w:r><w:t>Alpha &amp; β</w:t></w:r></w:p></w:body></w:document>"
	Opc.to_bytes(
		{ relationships: [{ id: "rId1", kind: Opc.officedocument_relationship, target: main, mode: Internal }], parts: names.prepend(primary) },
		|name|
			if name == main {
				Bytes(source.to_utf8())
			} else {
				Bytes((blobs.find_first(|blob| blob.name == name) ?? crash "missing source part").bytes)
			},
	)
}

wire_matches : Occupied, List(Action), List(U8) -> Bool
wire_matches = |occupied, history, bytes| {
	container = Opc.open(bytes, {}) ?? return Bool.False
	links = Opc.relationships(container, main) ?? return Bool.False
	blobs = payloads(occupied)
	has_part = |kind, expected| {
		found = links.keep_if(|link| link.kind == relation_kind(kind))
		if expected {
			match found {
				[link] if link.mode == Internal =>
					!blobs.any(|blob| link.target.caseless_ascii_equals(blob.name))
						and Opc.part(container, link.target).map_ok(|part| part.content_type) == Ok("application/vnd.openxmlformats-officedocument.wordprocessingml.${kind}+xml")
				_ => Bool.False
			}
		} else {
			found.is_empty()
		}
	}
	links.contains(opaque_link(occupied))
		and has_part("settings", history.contains(Track) or history.contains(OddAndEven))
		and has_part("comments", history.contains(Comment))
		and blobs.all(|blob| Opc.part_bytes(container, blob.name) == Ok(blob.bytes))
}

comments_of : Document -> List((U64, Str, [Range(Str), Point, Unanchored], List(Str)))
comments_of = |document| Docx.comments(document).comments.map(
	|entry| {
		body = entry.comment.content.keep_oks(
			|block| match block {
				Paragraph(paragraph) => Ok(Document.paragraph_text(paragraph))
				_ => Err(NotParagraph)
			},
		)
		(entry.id, entry.comment.author, entry.anchor, body)
	},
)

actions : World -> List(Action)
actions = |world| [Track, OddAndEven, Comment, Reopen].drop_if(|choice| world.history.contains(choice))

step : Occupied, World, Action -> World
step = |occupied, before, action| {
	history = before.history.append(action)
	match action {
		Track => { ..before, history, document: Docx.set_tracking(before.document, On) ?? crash "tracking refused" }
		OddAndEven => { ..before, history, document: Docx.set_different_odd_and_even(before.document, On) ?? crash "page setting refused" }
		Comment => {
			made = Docx.add_comment(before.document, { start: 0, end: 5 }, { author: "Ada Rivera", content: Text("Check this.") }) ?? crash "comment refused"
			{ ..before, history, document: made.document, intact: before.intact and made.id == 0 }
		}
		Reopen => {
			bytes = Docx.to_bytes(before.document) ?? crash "saving edited parts failed"
			read = Docx.parse(bytes) ?? crash "reopening edited parts failed"
			{ document: read.document, history, intact: before.intact and wire_matches(occupied, before.history, bytes) }
		}
	}
}

matches : World -> Bool
matches = |{ document, history, intact }| {
	expected_comments = if (history.contains(Comment)) [(0, "Ada Rivera", Range("Alpha"), ["Check this."])] else []
	intact
		and Docx.tracks_revisions(document) == history.contains(Track)
		and Docx.different_odd_and_even(document) == history.contains(OddAndEven)
		and comments_of(document) == expected_comments
		and Docx.text(document) == "Alpha & β\n"
}

check : Occupied -> Bool
check = |occupied| {
	parsed = Docx.parse(fixture(occupied) ?? crash "building fixture failed") ?? crash "reading fixture failed"
	initial = { document: parsed.document, history: [], intact: Bool.True }
	goal = "edit settings again after their creation and the comment survive reopening"
	report = Model.explore(
		{
			init: initial,
			actions,
			step: |world, action| step(occupied, world, action),
			rules: [
				Model.always("settings and comment edits apply without changing opaque part ownership", matches),
				Model.sometimes(goal, |world| world.history == [Track, Comment, Reopen, OddAndEven]),
			],
		},
		{ depth: 5, key: |world| world.history, verify: EveryStep },
	)
	match report.verdict {
		Holds(Exhausted) => {
			trace = Model.witness(report, goal) ?? return Bool.False
			last = trace.fold(initial, |world, action| step(occupied, world, action))
			written = Docx.to_bytes(last.document) ?? return Bool.False
			reopened = Docx.parse(written) ?? return Bool.False
			again = Docx.add_comment(reopened.document, { start: 8, end: 10 }, { author: "Lin Hart", content: Text("And this.") }) ?? return Bool.False
			saved = Docx.to_bytes(again.document) ?? return Bool.False
			read = Docx.parse(saved) ?? return Bool.False
			original = Opc.open(written, {}) ?? return Bool.False
			edited = Opc.open(saved, {}) ?? return Bool.False
			wire_matches(occupied, last.history, written)
				and matches({ ..last, document: reopened.document })
				and wire_matches(occupied, last.history, saved)
				and Opc.relationships(original, main) == Opc.relationships(edited, main)
				and again.id == 1
				and comments_of(read.document) == [(0, "Ada Rivera", Range("Alpha"), ["Check this."]), (1, "Lin Hart", Range("β"), ["And this."])]
		}
		_ => crash "${Model.explain(report)} ${Str.inspect(report.verdict)}"
	}
}

## Exhaust adding settings and a comment when binary parts already use the
## conventional names beside a main document outside the usual directory.
## Save and reopen with all opaque bytes and the original relationship.
expect check(ExactSettings)

## Swapping which collision differs in ASCII case must preserve the same
## settings, comment, and opaque part ownership.
expect check(ExactComments)
