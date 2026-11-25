import docx.Opc
import fuzz.Model
import zip.Zip

Content : [Generated, Copied]

Action : [Generate, Copy, CopyMissing, FinishEarly, AddExtra, Finish]

Reply : [Ready, Emitted, Refused(Opc.WriteError), Finished(List(U8))]

World : {
	writer : Opc.Writer,
	choices : List(Content),
	prefix : List(U8),
	history : List(Action),
	reply : Reply,
}

# The main document links to an opaque part. Its back link requires a
# generated relationship entry after the last supplied part.
document : Str
document = "/word/document.xml"

attachment : Str
attachment = "/word/attachment.bin"

graph : Opc.Graph
graph = {
	relationships: [{ id: "rId1", kind: Opc.officedocument_relationship, target: document, mode: Internal }],
	parts: [
		{ name: attachment, content_type: "application/octet-stream", relationships: [{ id: "rId1", kind: "urn:example:owner", target: document, mode: Internal }] },
		{ name: document, content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml", relationships: [{ id: "rId1", kind: "urn:example:attachment", target: attachment, mode: Internal }] },
	],
}

plan : List(Str)
plan = [document, attachment]

generated : Str -> List(U8)
generated = |name| if (name == document) document_xml("fresh") else [2, 3, 5]

document_xml : Str -> List(U8)
document_xml = |word| "<w:document xmlns:w='http://schemas.openxmlformats.org/wordprocessingml/2006/main'><w:body><w:p><w:r><w:t>${word}</w:t></w:r></w:p></w:body></w:document>".to_utf8()

# The source ZIP is built without the OPC writer, and stores even the
# compressible attachment without DEFLATE so re-encoding a copy is visible.
source_zip : List(U8)
source_zip = Zip.create(
	[
		{ path: "[Content_Types].xml", content: "<Types xmlns='http://schemas.openxmlformats.org/package/2006/content-types'><Default Extension='xml' ContentType='application/xml'/><Default Extension='bin' ContentType='application/octet-stream'/></Types>".to_utf8() },
		{ path: "word/document.xml", content: document_xml("carried") },
		{ path: "word/attachment.bin", content: List.repeat(7.U8, 128) },
	],
	None,
) ?? crash "the independent copy source did not write"

source : Opc.Package
source = Opc.open(source_zip, {}) ?? crash "the independent copy source did not open"

pending : World -> List(Str)
pending = |world| plan.drop_first(world.choices.len())

actions : World -> List(Action)
actions = |world| {
	if world.history.contains(Finish) {
		return []
	}
	if pending(world).is_empty() {
		return if (world.history.contains(AddExtra)) [Finish] else [AddExtra, Finish]
	}
	[Generate, Copy, CopyMissing, FinishEarly].keep_if(|action| action == Generate or action == Copy or !world.history.contains(action))
}

next_name : World -> Str
next_name = |world| pending(world).first() ?? crash "this action needs a pending part"

step : World, Action -> World
step = |world, action| {
	next = { ..world, history: world.history.append(action) }
	match action {
		Generate => add_part(next, Bytes(generated(next_name(world))), Generated)
		Copy => add_part(next, Copied(source), Copied)
		CopyMissing => probe_add(next, Copied(Opc.empty))
		AddExtra => probe_add(next, Bytes([]))
		FinishEarly | Finish =>
			match Opc.finish(world.writer) {
				Ok(tail) => { ..next, reply: Finished(world.prefix.concat(tail)) }
				Err(error) => { ..next, reply: Refused(error) }
			}
	}
}

add_part : World, Opc.Content, Content -> World
add_part = |world, content, choice|
	match Opc.add(world.writer, content) {
		Ok(added) => {
			..world,
			writer: added.writer,
			choices: world.choices.append(choice),
			prefix: world.prefix.concat(added.chunk),
			reply: Emitted,
		}
		Err(error) => { ..world, reply: Refused(error) }
	}

probe_add : World, Opc.Content -> World
probe_add = |world, content| {
	reply = match Opc.add(world.writer, content) {
		Ok(_) => Emitted
		Err(error) => Refused(error)
	}
	{ ..world, reply }
}

reply_as_promised : Model.Transition(World, Action) -> Bool
reply_as_promised = |{ before, action, after }|
	match action {
		Generate | Copy => after.reply == Emitted
		CopyMissing => after.reply == Refused(MissingPart(next_name(before)))
		FinishEarly => after.reply == Refused(NotWritten(next_name(before)))
		AddExtra => after.reply == Refused(NothingPending)
		Finish => match after.reply {
			Finished(bytes) => archive_as_promised(after.choices, bytes).is_ok()
			_ => Bool.False
		}
	}

# Look at the ZIP layer directly: the archive layout comes from this graph,
# and the copied entries' data and metadata come from the source ZIP.
archive_as_promised : List(Content), List(U8) -> Try({}, [WrongArchive])
archive_as_promised = |choices, bytes| {
	entries = Zip.entries(bytes) ? |_| WrongArchive
	if entries.map(|entry| entry.path) != ["[Content_Types].xml", "_rels/.rels", "word/document.xml", "word/_rels/document.xml.rels", "word/attachment.bin", "word/_rels/attachment.bin.rels"] {
		return Err(WrongArchive)
	}
	originals = Zip.entries(source_zip) ? |_| WrongArchive
	for (name, choice) in List.map2(plan, choices, |name, choice| (name, choice)) {
		path = name.drop_prefix("/")
		entry = entries.find_first(|candidate| candidate.path == path) ? |_| WrongArchive
		match choice {
			Generated => {
				if Zip.extract_entry(bytes, entry, {}) != Ok(generated(name)) {
					return Err(WrongArchive)
				}
			}

			Copied => {
				original = originals.find_first(|candidate| candidate.path == path) ? |_| WrongArchive
				if { ..entry, data_offset: original.data_offset } != original or stored(bytes, entry) != stored(source_zip, original) {
					return Err(WrongArchive)
				}
			}
		}
	}
	Ok({})
}

stored : List(U8), Zip.Entry -> List(U8)
stored = |archive, entry| archive.sublist({ start: entry.data_offset, len: entry.compressed_size })

same_after_retry : World -> Bool
same_after_retry = |world| match world.reply {
	Finished(bytes) if world.history.contains(Finish) and [CopyMissing, FinishEarly, AddExtra].any(|probe| world.history.contains(probe)) => {
		Opc.to_bytes(
			graph,
			|name| {
				index = plan.find_first_index(|planned| planned == name) ?? crash "a name in the graph is missing from the plan"
				match world.choices.get(index) {
					Ok(Copied) => Copied(source)
					Ok(Generated) => Bytes(generated(name))
					Err(_) => crash "a completed history has no choice for a part"
				}
			},
		) == Ok(bytes)
	}
	_ => Bool.True
}

machine : Model.Machine(World, Action)
machine = {
	init: { writer: Opc.writer(graph) ?? crash "the two-part graph did not start", choices: [], prefix: [], history: [], reply: Ready },
	actions,
	step,
	rules: [
		Model.always("pending names are the unwritten suffix of the plan", |world| Opc.pending(world.writer) == pending(world)),
		Model.always_step("each operation returns its expected error or valid output", reply_as_promised),
		Model.always("probes and failed writes leave a retry's bytes unchanged", same_after_retry),
		Model.sometimes_step("early finish names the first of multiple missing parts", |{ before, action, after: _ }| action == FinishEarly and pending(before).len() == 2),
		Model.sometimes_step("copying a missing part fails after a committed prefix", |{ before, action, after: _ }| action == CopyMissing and !before.choices.is_empty()),
		Model.sometimes(
			"a mixed archive is finished after a failed copy and an extra add",
			|world| {
				world.history.contains(Finish) and world.history.contains(CopyMissing) and world.history.contains(AddExtra)
					and world.choices.contains(Generated) and world.choices.contains(Copied)
			},
		),
	],
}

## Exhaust every generated/copied choice for two parts, with one failed copy
## and one early finish at any pending position, and an optional extra add.
## Full traces keep different progress and retry histories distinct.
expect {
	report = Model.explore(machine, { depth: 7, key: |world| world.history })
	if report.verdict != Holds(Exhausted) {
		crash "${Model.explain(report)} Verdict: ${Str.inspect(report.verdict)}"
	}
	report.depth == 6 and report.states == 203
}
