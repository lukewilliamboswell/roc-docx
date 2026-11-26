import docx.Build
import docx.Docx
import docx.Document
import docx.Opc
import docx.XmlTree
import fuzz.Model

NoteOwnership := [].{}

NoteAction : [Add, Reopen]

NoteWorld : { document : Document, history : List(NoteAction), added : U64, saved_ids_match : Bool }

note_namespace : Str
note_namespace = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

wide_id : Str
wide_id = "10000000000000000000000000000000000000000"

next_wide_id : Str
next_wide_id = "10000000000000000000000000000000000000001"

# Part order is deliberately unrelated to numeric order. The two kinds
# share ID 19 but belong to distinct parts.
note_fixture : Bool -> Try(List(U8), Opc.WriteError)
note_fixture = |aliases| {
	footnote_path = "/word/footnotes.xml"
	endnote_path = "/word/endnotes.xml"
	part = |name, kind, relationships| { name, content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.${kind}+xml", relationships }
	graph = {
		relationships: [{ id: "rId1", kind: Opc.officedocument_relationship, target: "/word/document.xml", mode: Internal }],
		parts: [
			part(
				"/word/document.xml",
				"document.main",
				[
					{ id: "rId1", kind: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/footnotes", target: footnote_path, mode: Internal },
					{ id: "rId2", kind: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/endnotes", target: endnote_path, mode: Internal },
				],
			),
			part(footnote_path, "footnotes", []),
			part(endnote_path, "endnotes", []),
		],
	}
	separator = if (aliases) "-0001" else "-1"
	continuation = if (aliases) " -000 " else "0"
	low = if (aliases) "+001" else "1"
	wide = if (aliases) "+00${wide_id}" else wide_id
	low_reference = if (aliases) " 01 " else "1"
	next_reference = if (aliases) " +0${next_wide_id} " else next_wide_id
	end_reference = if (aliases) "19 " else "19"
	custom_reference = if (aliases) "+0019" else "19"
	text_run = |text| "<w:r><w:t>${text}</w:t></w:r>"
	main = "<w:document xmlns:w='${note_namespace}'><w:body><w:p>"
		.concat("<w:r><w:footnoteReference w:id='${low_reference}'/><w:endnoteReference w:id='${end_reference}'/><w:footnoteReference w:id='19'/><w:footnoteReference w:id='${wide_id}'/><w:footnoteReference w:id='${next_reference}'/></w:r>")
		.concat("<w:r><w:footnoteReference w:id='${custom_reference}' w:customMarkFollows='1'/><w:t>*</w:t></w:r></w:p></w:body></w:document>")
	footnotes = "<w:footnotes xmlns:w='${note_namespace}'>"
		.concat("<w:footnote w:id='${separator}' w:type='separator'><w:p><w:r><w:separator/></w:r></w:p></w:footnote>")
		.concat("<w:footnote w:id='19'><w:p>${text_run("Nineteen")}</w:p></w:footnote>")
		.concat("<w:footnote w:id='${continuation}' w:type='continuationSeparator'><w:p><w:r><w:continuationSeparator/></w:r></w:p></w:footnote>")
		.concat("<w:footnote w:id='${low}'><w:p>${text_run("One")}</w:p></w:footnote>")
		.concat("<w:footnote w:id='${wide}'><w:p>${text_run("Wide")}</w:p></w:footnote>")
		.concat("<w:footnote w:id='${next_wide_id}'><w:p>${text_run("Next wide")}</w:p></w:footnote></w:footnotes>")
	endnotes = "<w:endnotes xmlns:w='${note_namespace}'><w:endnote w:id='19'><w:p>${text_run("End")}</w:p></w:endnote></w:endnotes>"
	Opc.to_bytes(
		graph,
		|name| Bytes(
			(
				match name {
					"/word/footnotes.xml" => footnotes
					"/word/endnotes.xml" => endnotes
					_ => main
				}
			).to_utf8(),
		),
	)
}

note_texts : List(Document.Note) -> List(Str)
note_texts = |notes| notes.map(
	|note| match note.content {
		[Paragraph(paragraph)] => Document.paragraph_text(paragraph)
		_ => crash "expected one note paragraph"
	},
)

extra_notes : U64 -> List(Str)
extra_notes = |count| [" Added 1", " Added 2"].take_first(count)

note_references : Document -> List((Document.NoteKind, U64))
note_references = |document| Docx.body(document).fold(
	[],
	|all, block| match block {
		Paragraph(paragraph) => paragraph.content.fold(
			all,
			|refs, inline| match inline {
				Run(run) => run.content.fold(
					refs,
					|found, item| match item {
						NoteReference(reference) => found.append((reference.kind, reference.note))
						_ => found
					},
				)
				_ => refs
			},
		)
		_ => all
	},
)

note_projection : NoteWorld -> Bool
note_projection = |{ document, added, .. }| {
	footnotes = Docx.footnotes(document)
	endnotes = Docx.endnotes(document)
	note_texts(footnotes) == List.concat(["", "Nineteen", "", "One", "Wide", "Next wide"], extra_notes(added))
		and footnotes.map(|note| note.kind) == List.concat([Separator, Note, ContinuationSeparator, Note, Note, Note], [Note, Note].take_first(added))
		and note_texts(endnotes) == ["End"]
		and note_references(document) == List.concat([(Footnote, 3), (Endnote, 0), (Footnote, 1), (Footnote, 4), (Footnote, 5)], [(Footnote, 6), (Footnote, 7)].take_first(added))
}

# Read emitted attributes from the OPC part as XML. Never use WmlRead's
# identifier lookup or WmlWrite's allocator to predict the IDs.
wire_note_ids : Opc.Package, Str, Str -> Try(List(Str), [Absent])
wire_note_ids = |container, path, local| {
	bytes = Opc.part_bytes(container, path) ? |_| Absent
	match XmlTree.parse(bytes, {}) ? |_| Absent {
		Element(root) => Ok(
			root.children.keep_oks(
				|child| match child {
					Element(note) if note.name.local == local and note.name.namespace == Uri(note_namespace) => {
						id = note.attributes.find_first(|attribute| attribute.name.local == "id" and attribute.name.namespace == Uri(note_namespace)) ? |_| Absent
						Ok(id.value)
					}
					_ => Err(Absent)
				},
			),
		)
		_ => Err(Absent)
	}
}

note_wire : List(U8), Bool, U64 -> Bool
note_wire = |bytes, aliases, added| {
	container = Opc.open(bytes, {}) ?? return Bool.False
	custom_reference = if (aliases) "+0019" else "19"
	imported = if (aliases) ["-0001", "19", " -000 ", "+001", "+00${wide_id}", next_wide_id] else ["-1", "19", "0", "1", wide_id, next_wide_id]
	wire_note_ids(container, "/word/footnotes.xml", "footnote") == Ok(List.concat(imported, ["2", "3"].take_first(added)))
		and wire_note_ids(container, "/word/endnotes.xml", "endnote") == Ok(["19"])
		and Opc.part_bytes(container, "/word/document.xml").map_ok(|part| (Str.from_utf8(part) ?? "").contains("<w:footnoteReference w:id=\"${custom_reference}\" w:customMarkFollows=\"1\"/>")) == Ok(Bool.True)
}

note_actions : NoteWorld -> List(NoteAction)
note_actions = |{ history, added, .. }| {
	choices = if (added < 2) [Add] else []
	if (history.contains(Reopen)) choices else choices.append(Reopen)
}

note_step : Bool, NoteWorld, NoteAction -> NoteWorld
note_step = |aliases, before, action| {
	history = before.history.append(action)
	match action {
		Add => {
			added = before.added + 1
			made = Build.footnote(before.document, [Build.text("Added ${added.to_str()}", {})]) ?? crash "a new note was refused"
			document = Build.append(made.document, [Build.paragraph({}, [made.reference])])
			{ ..before, document, history, added }
		}
		Reopen => {
			bytes = Docx.to_bytes(before.document) ?? crash "saving the notes failed"
			parsed = Docx.parse(bytes) ?? crash "reopening the notes failed"
			{ ..before, document: parsed.document, history, saved_ids_match: note_wire(bytes, aliases, before.added) }
		}
	}
}

# The complete action history keys this finite enumeration without merging
# different sequences which happen to have the same note counts.
note_history : Bool -> Bool
note_history = |aliases| {
	bytes = note_fixture(aliases) ?? crash "the imported notes could not be built"
	parsed = Docx.parse(bytes) ?? crash "the imported notes could not be parsed"
	goal = "add a footnote, reopen, and then add a second footnote"
	initial = { document: parsed.document, history: [], added: 0, saved_ids_match: Bool.True }
	report = Model.explore(
		{
			init: initial,
			actions: note_actions,
			step: |world, action| note_step(aliases, world, action),
			rules: [
				Model.always("note contents and references retain their respective owners", note_projection),
				Model.always("the archive preserves imported note IDs and gives distinct IDs to additions", |world| world.saved_ids_match),
				Model.sometimes(goal, |world| world.history == [Add, Reopen, Add]),
			],
		},
		{ depth: 4, key: |world| world.history, verify: EveryStep },
	)
	match report.verdict {
		Holds(Exhausted) => {
			trace = Model.witness(report, goal) ?? return Bool.False
			final = trace.fold(initial, |world, action| note_step(aliases, world, action))
			bytes_after = Docx.to_bytes(final.document) ?? return Bool.False
			saved = Docx.parse(bytes_after) ?? return Bool.False
			note_wire(bytes_after, aliases, 2) and note_projection({ ..final, document: saved.document })
		}
		_ => crash "${Model.explain(report)} ${Str.inspect(report.verdict)}"
	}
}

## Exhaust two incremental footnote edits and a save and reopen in any
## order. Existing note identities belong to the original kind and part
## position, including the separators and non-dense, arbitrary-width IDs.
expect note_history(Bool.False)

## ST_DecimalNumber has integer value semantics. A padded, signed, or
## whitespace-surrounded spelling matches its numeric reference and takes
## that value out of the writer's allocation space. Keep the definitions'
## original spellings and the custom-mark reference through the edits.
expect note_history(Bool.True)
