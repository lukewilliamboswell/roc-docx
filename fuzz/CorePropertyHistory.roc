import docx.Docx
import docx.Document
import docx.Opc
import docx.XmlTree
import fuzz.Model

CorePropertyHistory := [].{}

Source : [Imported, Occupied, CaseOccupied]

Action : [Title, Describe, Refuse, Reopen]

World : { document : Document, history : List(Action), saved : Bool }

main : Str
main = "/word/document.xml"

core_type : Str
core_type = "application/vnd.openxmlformats-package.core-properties+xml"

core_kind : Str
core_kind = "http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties"

core_namespace : Str
core_namespace = "http://schemas.openxmlformats.org/package/2006/metadata/core-properties"

dc : Str
dc = "http://purl.org/dc/elements/1.1/"

custom_core : Str
custom_core = "/metadata/publication.xml"

payload_path : Source -> Str
payload_path = |source| if (source == CaseOccupied) "/DocProps/Core.xml" else "/docProps/core.xml"

payload_relationship : Source -> Opc.Relationship
payload_relationship = |source|
	{ id: "rId2", kind: "urn:example:binary-metadata", target: payload_path(source), mode: Internal }

imported_relationship : Opc.Relationship
imported_relationship = { id: "rId9", kind: core_kind, target: custom_core, mode: Internal }

date : Str
date = "2026-11-09T15:30:00-06:00"

fixture : Source -> Try(List(U8), Opc.WriteError)
fixture = |source| {
	core_links = if (source == Imported) [imported_relationship] else []
	metadata = if source == Imported {
		[{ name: custom_core, content_type: core_type, relationships: [] }]
	} else {
		[{ name: "/DocProps/Core2.xml", content_type: "application/octet-stream", relationships: [] }]
	}
	graph = {
		relationships: List.concat([{ id: "rId1", kind: Opc.officedocument_relationship, target: main, mode: Internal }, payload_relationship(source)], core_links),
		parts: List.concat(
			[
				{ name: main, content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml", relationships: [] },
				{ name: payload_path(source), content_type: "application/octet-stream", relationships: [] },
			],
			metadata,
		),
	}
	primary = "<w:document xmlns:w='http://schemas.openxmlformats.org/wordprocessingml/2006/main'><w:body><w:p><w:r><w:t>Publication</w:t></w:r></w:p></w:body></w:document>"
	properties = "<cp:coreProperties xmlns:cp='${core_namespace}' xmlns:dc='${dc}' xmlns:dcterms='http://purl.org/dc/terms/' xmlns:xsi='http://www.w3.org/2001/XMLSchema-instance'><dc:title>Draft</dc:title><dc:description>Editor’s notes</dc:description><cp:revision>5</cp:revision><dcterms:created xsi:type='dcterms:W3CDTF'>2026-11-01T18:00:00Z</dcterms:created><cp:category>Archive &amp; news</cp:category><dc:language>en-AU</dc:language></cp:coreProperties>"
	Opc.to_bytes(
		graph,
		|name| Bytes(
			if name == main {
				primary.to_utf8()
			} else if name == custom_core {
				properties.to_utf8()
			} else if name == payload_path(source) {
				[0, 7, 255]
			} else {
				[22, 1]
			},
		),
	)
}

# Observe preserved metadata through its XML names and its decoded text.
preserved_value : XmlTree.Node -> Try((XmlTree.Namespace, Str, Str), [Unexpected])
preserved_value = |node| match node {
	Element({ name, children: [Text(value)], .. }) => Ok((name.namespace, name.local, value))
	_ => Err(Unexpected)
}

expected_properties : Source, World -> Bool
expected_properties = |source, { document, history, .. }| {
	actual = Docx.core_properties(document)
	titled = history.contains(Title)
	described = history.contains(Describe)
	initial_title = if (source == Imported) Text("Draft") else Unset
	title = if (titled) Text("Edition & index") else initial_title
	creator = if (described) Text("Grace Chen") else Unset
	modified = if (described) Date(date) else Unset
	notes = if (source == Imported) Text("Editor’s notes") else Unset
	created = if (source == Imported) Date("2026-11-01T18:00:00Z") else Unset
	revision = if (source == Imported) Number(5) else Unset
	extra = if (source == Imported) [Ok((Uri(core_namespace), "category", "Archive & news")), Ok((Uri(dc), "language", "en-AU"))] else []
	actual.title == title and actual.creator == creator and actual.modified == modified
		and actual.description == notes and actual.created == created
		and actual.revision == revision
		and actual.preserved.map(preserved_value) == extra
		and Docx.text(document) == "Publication\n"
}

wire_matches : Source, World, List(U8) -> Bool
wire_matches = |source, { history, .. }, bytes| {
	container = Opc.open(bytes, {}) ?? return Bool.False
	links = Opc.relationships(container, "/") ?? return Bool.False
	core = links.keep_if(|relationship| relationship.kind == core_kind)
	edited = history.contains(Title) or history.contains(Describe)
	held = if source == Imported {
		core == [imported_relationship]
	} else if edited {
		match core {
			[link] => link.mode == Internal and !link.target.caseless_ascii_equals(payload_path(source)) and !link.target.caseless_ascii_equals("/DocProps/Core2.xml")
				and Opc.part(container, link.target).map_ok(|part| part.content_type) == Ok(core_type)
			_ => Bool.False
		}
	} else {
		core.is_empty()
	}
	held and links.contains(payload_relationship(source))
		and Opc.part_bytes(container, payload_path(source)) == Ok([0, 7, 255])
		and (source == Imported or Opc.part_bytes(container, "/DocProps/Core2.xml") == Ok([22, 1]))
}

actions : World -> List(Action)
actions = |world| [Title, Describe, Refuse, Reopen].drop_if(|choice| world.history.contains(choice))

step : Source, World, Action -> World
step = |source, before, action| {
	history = before.history.append(action)
	match action {
		Title => { ..before, history, document: Docx.set_properties(before.document, { title: Text("Edition & index") }) ?? crash "title refused" }
		Describe => { ..before, history, document: Docx.set_properties(before.document, { creator: Text("Grace Chen"), modified: Date(date) }) ?? crash "description refused" }
		Refuse => {
			refused = Docx.set_properties(before.document, { title: Text("Incorrect"), modified: Date("yesterday") }).map_ok(|_| {})
			{ ..before, history, saved: before.saved and refused == Err(NotADate("yesterday")) }
		}
		Reopen => {
			bytes = Docx.to_bytes(before.document) ?? crash "saving property history failed"
			read = Docx.parse(bytes) ?? crash "reopening property history failed"
			{ document: read.document, history, saved: before.saved and wire_matches(source, before, bytes) }
		}
	}
}

check_history : Source -> Bool
check_history = |source| {
	bytes = fixture(source) ?? crash "property fixture failed"
	read = Docx.parse(bytes) ?? crash "reading property fixture failed"
	initial = { document: read.document, history: [], saved: Bool.True }
	goal = "retry with a different partial edit after a refusal and reopen"
	report = Model.explore(
		{
			init: initial,
			actions,
			step: |world, action| step(source, world, action),
			rules: [
				Model.always("partial edits keep every unrelated property intact", |world| expected_properties(source, world)),
				Model.always("refused dates and saved relationship targets preserve ownership", |world| world.saved),
				Model.sometimes(goal, |world| world.history == [Title, Refuse, Reopen, Describe]),
			],
		},
		{ depth: 5, key: |world| world.history, verify: EveryStep },
	)
	match report.verdict {
		Holds(Exhausted) => {
			trace = Model.witness(report, goal) ?? return Bool.False
			final = trace.fold(initial, |world, action| step(source, world, action))
			written = Docx.to_bytes(final.document) ?? return Bool.False
			reopened = Docx.parse(written) ?? return Bool.False
			wire_matches(source, final, written) and expected_properties(source, { ..final, document: reopened.document })
		}
		_ => crash "${Model.explain(report)} ${Str.inspect(report.verdict)}"
	}
}

## Reuse a relationship's nonstandard target and preserve imported metadata
## across both partial edits, refusal, and save and reopen.
expect check_history(Imported)

## A package can have both conventional core filenames in use by unrelated
## parts. Adding core properties leaves those parts and their links intact.
expect check_history(Occupied)

## OPC part names also collide when they differ only in ASCII case.
expect check_history(CaseOccupied)
