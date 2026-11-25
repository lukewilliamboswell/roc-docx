import docx.Comments
import docx.Docx
import docx.Document
import docx.Opc
import fuzz.Model
import ValueIds

Spec := [].{}

# A single body paragraph, two adjacent multibyte spans, and at most three
# successful additions (including replies). This admits siblings, a grandchild,
# and reusing a removed place. The reference stores stable serials in ancestry
# paths. Dense public ids are derived only when projecting those paths.
Site : [Earlier, Later]

Action : [Add(Site), Reply(U64), Resolve(U64), Remove(U64), SplitCharacter]

Entry : { path : List(U64), site : Site, resolved : Bool }

Reference : { made : U64, entries : List(Entry) }

Created : [NoId, Id(U64)]

World : { document : Document, reference : Reference, issue : [None, EditResult] }

# Keep the exact XML trees and relationships and the typed body, which
# can be held separately from its XML shell. The seed archive and its
# only root relationship are fixed throughout the search.
Key := { reference : Reference, parts : List(Document.XmlPart), body : List(Document.Block) }.{
	is_eq : _
	to_hash = |{ reference, .. }, hasher| reference.to_hash(hasher)
}

span : Site -> Comments.Span
span = |site| match site {
	Earlier => { start: 1, end: 3 }
	Later => { start: 3, end: 7 }
}

anchor : Site -> Str
anchor = |site| match site {
	Earlier => "é"
	Later => "🙂"
}

split : Comments.Span
split = { start: 2, end: 3 }

body_text : Str
body_text = "Aé🙂Z"

start_bytes : List(U8)
start_bytes = {
	main = "/word/document.xml"
	xml = "<w:document xmlns:w='http://schemas.openxmlformats.org/wordprocessingml/2006/main'><w:body><w:p><w:r><w:t>${body_text}</w:t></w:r></w:p></w:body></w:document>"
	graph = {
		relationships: [{ id: "rId1", kind: Opc.officedocument_relationship, target: main, mode: Internal }],
		parts: [{ name: main, content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml", relationships: [] }],
	}
	Opc.to_bytes(graph, |_| Bytes(xml.to_utf8())) ?? crash "the comment model's document did not package"
}

actions : World -> List(Action)
actions = |{ reference, .. }| {
	entries = reference.entries
	var $next = [SplitCharacter, Reply(entries.len()), Resolve(entries.len()), Remove(entries.len())]
	if reference.made < 3 {
		$next = List.concat($next, [Add(Earlier), Add(Later)])
	}
	var $id = 0.U64
	for _ in entries {
		$next = List.concat($next, [Resolve($id), Remove($id)])
		if reference.made < 3 {
			$next = List.append($next, Reply($id))
		}
		$id = $id + 1
	}
	$next
}

reference_edit : Reference, Action -> Try({ reference : Reference, id : Created }, Docx.EditError)
reference_edit = |reference, action| {
	entries = reference.entries
	create = |path, site| Ok({
		reference: {
			made: reference.made + 1,
			entries: entries.append({ path: path.append(reference.made), site, resolved: Bool.False }),
		},
		id: Id(entries.len()),
	})
	match action {
		Add(site) => create([], site)
		Reply(id) => {
			parent = entries.get(id).map_err(|_| NoSuchComment(id))?
			create(parent.path, parent.site)
		}
		Resolve(id) => {
			entry = entries.get(id).map_err(|_| NoSuchComment(id))?
			root = entry.path.first()
			Ok({ reference: { ..reference, entries: entries.map(|other| if (other.path.first() == root) { ..other, resolved: Bool.True } else other) }, id: NoId })
		}
		Remove(id) => {
			entry = entries.get(id).map_err(|_| NoSuchComment(id))?
			Ok({ reference: { ..reference, entries: entries.drop_if(|other| other.path.take_first(entry.path.len()) == entry.path) }, id: NoId })
		}
		SplitCharacter => Err(NotACharacterBoundary(split.start))
	}
}

author : Str
author = "Ada Reviewer"

message : U64 -> Str
message = |serial| "Comment ${serial.to_str()}"

edit : Document, Action, U64 -> Try({ document : Document, id : Created }, Docx.EditError)
edit = |document, action, serial| {
	new : Comments.New
	new = { author, content: Text(message(serial)) }
	opened = |added| { document: added.document, id: Id(added.id) }
	changed = |edited| { document: edited, id: NoId }
	match action {
		Add(site) => Docx.add_comment(document, span(site), new).map_ok(opened)
		Reply(id) => Docx.reply(document, id, new).map_ok(opened)
		Resolve(id) => Docx.resolve(document, id).map_ok(changed)
		Remove(id) => Docx.remove_comment(document, id).map_ok(changed)
		SplitCharacter => Docx.add_comment(document, split, new).map_ok(opened)
	}
}

# A marker's position in the paragraph and its order relative to other
# markers at that byte. Relative order distinguishes a reply after its
# parent from one before it even when their anchored strings are identical.
Marker : [Begin(U64), End(U64), Reference(U64)]

Event : { at : U64, marker : Marker }

events : List(Document.Inline) -> List(Event)
events = |inlines| {
	var $at = 0.U64
	var $events = List.with_capacity(inlines.len())
	for inline in inlines {
		match inline {
			CommentStart(id) => {
				$events = $events.append({ at: $at, marker: Begin(id) })
			}
			CommentEnd(id) => {
				$events = $events.append({ at: $at, marker: End(id) })
			}
			Run(run) =>
				for content in run.content {
					match content {
						Text(text) => {
							$at = $at + text.to_utf8().len()
						}
						CommentReference(id) => {
							$events = $events.append({ at: $at, marker: Reference(id) })
						}
						_ => {}
					}
				}
			_ => {}
		}
	}
	$events
}

follows : List(Event), Marker, Marker -> Bool
follows = |seen, earlier, later| {
	var $found = Bool.False
	for event in seen {
		if $found and event.marker == later {
			return Bool.True
		}
		$found = $found or event.marker == earlier
	}
	Bool.False
}

# A parent is the preceding prefix of a reply's path. Its public id is
# therefore its position among the surviving paths, never its old id.
parent_of : List(Entry), Entry -> [Unset, Parent(U64)]
parent_of = |entries, entry| {
	path = entry.path.drop_last(1)
	var $id = 0.U64
	for other in entries {
		if other.path == path {
			return Parent($id)
		}
		$id = $id + 1
	}
	Unset
}

matches : Document, Reference -> Bool
matches = |document, { entries, .. }| {
	if Docx.text(document) != "${body_text}\n" {
		return Bool.False
	}
	{ comments, diagnostics } = Docx.comments(document)
	if comments.len() != entries.len() or !diagnostics.is_empty() {
		return Bool.False
	}
	seen = match Docx.body(document) {
		[Paragraph(paragraph)] => events(paragraph.content)
		_ => return Bool.False
	}
	if seen.len() != 3 * entries.len() {
		return Bool.False
	}
	var $id = 0.U64
	for entry in entries {
		actual = comments.find_first(|one| one.id == $id) ?? return Bool.False
		parent = parent_of(entries, entry)
		note = actual.comment
		if note.parent != parent or note.resolved != entry.resolved or note.author != author or note.content.map(
			|block| match block {
				Paragraph(paragraph) => Document.paragraph_text(paragraph)
				_ => ""
			},
		) != [message(entry.path.last() ?? crash "an empty comment ancestry")] or actual.anchor != Range(anchor(entry.site)) {
			return Bool.False
		}
		{ start, end } = span(entry.site)
		if !seen.contains({ at: start, marker: Begin($id) }) or !seen.contains({ at: end, marker: End($id) }) or !seen.contains({ at: end, marker: Reference($id) }) or !follows(seen, End($id), Reference($id)) {
			return Bool.False
		}
		match parent {
			Parent(above) if !(follows(seen, Begin(above), Begin($id)) and follows(seen, End(above), End($id)) and follows(seen, Reference(above), Reference($id))) => return Bool.False
			_ => {}
		}
		$id = $id + 1
	}
	comments_kind = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/comments"
	extended_kind = "http://schemas.microsoft.com/office/2011/relationships/commentsExtended"
	main = "/word/document.xml"
	(entries.is_empty() or Document.related(document, main, comments_kind).is_ok())
		and (!entries.any(|entry| entry.resolved or entry.path.len() > 1) or Document.related(document, main, extended_kind).is_ok())
}

step : World, Action -> World
step = |world, action| match (reference_edit(world.reference, action), edit(world.document, action, world.reference.made)) {
	(Err(wanted), Err(got)) if wanted == got => world
	(Ok(wanted), Ok(got)) if wanted.id == got.id => { document: got.document, reference: wanted.reference, issue: None }
	_ => { ..world, issue: EditResult }
}

renumbered_thread : Str
renumbered_thread = "removing an earlier comment renumbers a surviving reply and its parent"

machine : Model.Machine(World, Action)
machine = {
	init: { document: (Docx.parse(start_bytes) ?? crash "the comment model document did not parse").document, reference: { made: 0, entries: [] }, issue: None },
	actions,
	step,
	rules: [
		Model.always("the edit returns the next id or the exact error", |world| world.issue != EditResult),
		Model.always("the edited document matches the thread forest and body markers", |world| matches(world.document, world.reference)),
		Model.sometimes("a reply itself has a reply", |world| world.reference.entries.any(|entry| entry.path.len() == 3)),
		Model.sometimes(
			"a comment has two direct replies",
			|world| match world.reference.entries {
				[_, left, right] => left.path.len() == 2 and right.path.len() == 2 and left.path.first() == right.path.first()
				_ => Bool.False
			},
		),
		Model.sometimes_step(
			"resolving from a reply marks its ancestors",
			|{ before, action, after }| match action {
				Resolve(id) =>
					match before.reference.entries.get(id) {
						Ok(entry) => entry.path.len() == 3 and before.reference.entries.any(|one| !one.resolved) and after.reference.entries.all(|one| one.resolved)
						Err(_) => Bool.False
					}
				_ => Bool.False
			},
		),
		Model.sometimes_step(
			"removing a reply prunes a grandchild and keeps the root",
			|{ before, action, after }| match action {
				Remove(id) => id == 1 and before.reference.entries.any(|entry| entry.path.len() == 3) and after.reference.entries.len() == 1
				_ => Bool.False
			},
		),
		Model.sometimes_step(
			renumbered_thread,
			|{ before, action, after }| match (action, before.reference.entries, after.reference.entries) {
				(Remove(0), [_, root, reply], [_, _]) => root.path.len() == 1 and reply.path.len() == 2 and root.path.first() == reply.path.first()
				_ => Bool.False
			},
		),
		Model.sometimes_step("a later edit reuses a vacated id", |{ before, action: _, after }| before.reference.made > before.reference.entries.len() and after.reference.made > before.reference.made),
	],
}

## Exhaust all histories in the three-comment domain, including refused and
## repeated edits. Check every edge before pruning an already visited key.
## Save and reopen the witness where removal renumbers a surviving thread.
expect {
	report = Model.explore(machine, { depth: 10, key: |world| Key.{ reference: world.reference, parts: Document.xml_parts(world.document), body: Docx.body(world.document) }, verify: EveryStep })
	match report.verdict {
		Holds(Exhausted) => {
			trace = Model.witness(report, renumbered_thread)?
			final = trace.fold(machine.init, step)
			bytes = Docx.to_bytes(final.document)?
			matches(Docx.parse(bytes)?.document, final.reference)
		}
		_ => crash "${Model.explain(report)} ${Str.inspect(report.verdict)}"
	}
}
