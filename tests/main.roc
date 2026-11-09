app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.27.0/9yjxqdGTP4xSpSEmDazwTmRsehfRZzA19pwEKkR6fj1g.tar.zst",
	docx: "../package/main.roc",
}

import cli.Duration
import cli.Monotonic
import cli.Path
import cli.Stderr
import cli.Stdout
import docx.Comments
import docx.Docx
import docx.Document
import docx.Opc
import docx.Revisions
import docx.Snapshot
import docx.WmlWrite
import docx.XmlTree

## The data-driven cases, built once and run together from the repository
## root:
##
##     roc tests/main.roc            # every case against its expectation
##     roc tests/main.roc --update   # rewrite the expectations, to review as a diff
##
## Each family runs once for every `.docx` under `tests/fixtures/`, writes
## its output under `.roc-docx/<family>/` at the fixture's own path, and
## compares a report with the expectation under `tests/<family>/`.
##
## Pass-through: the fixture is parsed and written, and the written document
## must parse to a document equivalent to the original, without anything
## left to drop or repair; writing it twice, and writing what was written,
## must give the same bytes. The expectation records what reading dropped and
## repaired and the written package's parts and digest, so a change in what
## the writer produces is a reviewed diff. The written documents are what the schema
## and LibreOffice oracles read.
##
## Snapshots: the fixture's semantic snapshot, which is its own expectation
## and what `oracle/compare_snapshots.py` compares with the oracles' readings
## as the `package` adapter.
##
## Generated: documents built from the model rather than read, for content
## the fixtures do not hold together, such as every kind of tracked change.
## Each is written under `.roc-docx/generated/`, must read back as the model
## it was built from, without anything to drop or repair, and pass through
## as a fixture does; its snapshot goes beside the fixtures' and its report,
## the pass-through report with the tracked changes read back, is compared
## with `tests/generated/<name>.txt`.
##
## Review: the fixture edited by the reviewer's pass of
## `examples/review_contract`, which adds a comment on the first line of
## text, replies to the comment that comes first, resolves that thread and
## removes the last of the fixture's own comments when it has more than one.
## The edits must leave the text as it was, and the edited document must
## write twice to the same bytes and read back as the same comments. The
## written document and its snapshot, the expectation, are what the schema
## and LibreOffice oracles read.
##
## Redline: the fixture edited by the session of `examples/redline`, which
## turns tracking on, accepts one reviewer's changes and rejects another's,
## then replaces, inserts and deletes text as tracked changes. The edited
## document's current text must be the same edits made silently; rejecting
## the new changes must give the text before them and accepting them the
## silent edits' text; it must write twice to the same bytes and read back
## with the same changes, tracking on. The written document and its
## snapshot, the expectation, are what the schema and LibreOffice oracles
## read.
main! : List([Utf8(Str), UnixBytes(List(U8)), WindowsU16s(List(U16))]) => Try({}, _)
main! = |args| {
	update = args.any(|arg| is_update(arg))
	fixtures = sorted(files_under!(Path.utf8("tests/fixtures"))?.map(Path.display).keep_if(|path| path.ends_with(".docx")))
	var $failed = 0.U64
	for family in families {
		$failed = $failed + run_family!(family, fixtures, update)?
	}
	$failed = $failed + run_generated!(update)?
	if $failed > 0 {
		Err(Exit(1))
	} else {
		Ok({})
	}
}

# A family of cases: what one fixture's case writes, and the report its
# expectation, `tests/<name>/<fixture><extension>`, records.
Family : {
	name : Str,
	extension : Str,
	run : Str, List(U8) -> Try({ outputs : List({ extension : Str, bytes : List(U8) }), report : Str }, Str),
}

families : List(Family)
families = [
	{ name: "passthrough", extension: ".txt", run: |_, bytes| pass_through(bytes).map_ok(|{ written, report }| { outputs: [{ extension: "", bytes: written }], report }) },
	{ name: "snapshots", extension: ".json", run: |fixture, bytes| snapshot(fixture, bytes).map_ok(|json| { outputs: [{ extension: ".json", bytes: json.to_utf8() }], report: json }) },
	{ name: "review", extension: ".json", run: |fixture, bytes| reviewed(fixture, bytes).map_ok(|{ written, json }| { outputs: [{ extension: "", bytes: written }, { extension: ".json", bytes: json.to_utf8() }], report: json }) },
	{ name: "redline", extension: ".json", run: |fixture, bytes| redlined(fixture, bytes).map_ok(|{ written, json }| { outputs: [{ extension: "", bytes: written }, { extension: ".json", bytes: json.to_utf8() }], report: json }) },
]

# Run a family's case for every fixture and report each; the number that failed.
run_family! : Family, List(Str), Bool => Try(U64, _)
run_family! = |family, fixtures, update| {
	output_root = ".roc-docx/${family.name}"
	match Path.delete_all!(Path.utf8(output_root)) {
		_ => {}
	}
	Stdout.line!("${family.name}: ${fixtures.len().to_str()} cases${if (update) ", updating expectations" else ""}")?
	var $failed = 0.U64
	var $updated = 0.U64
	var $position = 0.U64
	for fixture in fixtures {
		$position = $position + 1
		started = Monotonic.now!()
		document = Str.drop_prefix(fixture, "tests/fixtures/")
		outcome = (family.run)(fixture, Path.read_bytes!(Path.utf8(fixture))?)
		status = match outcome {
			Ok({ outputs, report }) => {
				for output in outputs {
					written = "${output_root}/${document}${output.extension}"
					Path.create_all!(Path.utf8(directory_of(written)))?
					Path.write_bytes!(Path.utf8(written), output.bytes)?
				}
				expectation = Path.utf8("tests/${family.name}/${Str.drop_suffix(document, ".docx")}${family.extension}")
				expected = Path.read_utf8!(expectation) ?? ""
				if expected == report {
					"PASS"
				} else if update {
					Path.create_all!(Path.utf8(directory_of(Path.display(expectation))))?
					Path.write_utf8!(expectation, report)?
					$updated = $updated + 1
					"UPDATED"
				} else {
					$failed = $failed + 1
					Stderr.line!("${Path.display(expectation)} expects:\n${expected}but the case reports:\n${report}")?
					"FAIL"
				}
			}

			Err(problem) => {
				$failed = $failed + 1
				Stderr.line!("${fixture}: ${problem}")?
				"FAIL"
			}
		}
		elapsed = Duration.to_millis(Monotonic.elapsed!(started))
		Stdout.line!(" [${$position.to_str()}/${fixtures.len().to_str()}] ${document} ${status} ${elapsed.to_str()}ms")?
	}
	Stdout.line!("Summary: ${fixtures.len().to_str()} cases, ${(fixtures.len() - $failed - $updated).to_str()} passed, ${$updated.to_str()} updated, ${$failed.to_str()} failed, 0 skipped")?
	Ok($failed)
}

# A fixture's snapshot, naming it by its path from the repository root as the
# oracle adapters do.
snapshot : Str, List(U8) -> Try(Str, Str)
snapshot = |fixture, bytes| {
	parsed = Docx.parse(bytes) ? |problem| "the fixture does not parse: ${Str.inspect(problem)}"
	Ok(Snapshot.json(parsed.document, { path: fixture, version: "working tree" }))
}

# A fixture edited by the reviewer's pass, written, with its snapshot naming
# it where the case writes it; or what went wrong.
reviewed : Str, List(U8) -> Try({ written : List(U8), json : Str }, Str)
reviewed = |fixture, bytes| {
	parsed = Docx.parse(bytes) ? |problem| "the fixture does not parse: ${Str.inspect(problem)}"
	edited = review(parsed.document) ? |problem| "the review's edits failed: ${Str.inspect(problem)}"
	if Docx.text(edited) != Docx.text(parsed.document) {
		return Err("the review's edits changed the text")
	}
	written = Docx.to_bytes(edited) ? |problem| "the reviewed document does not write: ${Str.inspect(problem)}"
	if Docx.to_bytes(edited) != Ok(written) {
		return Err("writing the reviewed document twice gave different bytes")
	}
	again = Docx.parse(written) ? |problem| "the reviewed document does not parse: ${Str.inspect(problem)}"
	if Docx.comments(again.document) != Docx.comments(edited) {
		return Err("the reviewed document reads back as different comments")
	}
	path = ".roc-docx/review/${Str.drop_prefix(fixture, "tests/fixtures/")}"
	Ok({ written, json: Snapshot.json(again.document, { path, version: "working tree" }) })
}

# The reviewer's pass of `examples/review_contract`, step for step.
review : Document -> Try(Document, Docx.EditError)
review = |document| {
	before = Docx.comments(document).comments.len()
	title = first_line(Docx.text(document))
	added = Docx.add_comment(document, title, { author: "Morgan Reviewer", initials: Initials("MR"), date: Date("2026-11-10T09:00:00Z"), content: Text("Please give the parties' full legal names.") })?
	first = match Docx.comments(added.document).comments.first() {
		Ok(entry) => entry.id
		Err(_) => added.id
	}
	replied = Docx.reply(added.document, first, { author: "Lin Editor", initials: Initials("LE"), date: Date("2026-11-10T09:30:00Z"), content: Text("Done; both names now match the register.") })?
	resolved = Docx.resolve(replied.document, replied.id)?
	if before >= 2 {
		Docx.remove_comment(resolved, before - 1)
	} else {
		Ok(resolved)
	}
}

# A fixture edited by the redline session, written, with its snapshot naming
# it where the case writes it; or what went wrong.
redlined : Str, List(U8) -> Try({ written : List(U8), json : Str }, Str)
redlined = |fixture, bytes| {
	parsed = Docx.parse(bytes) ? |problem| "the fixture does not parse: ${Str.inspect(problem)}"
	settled = settle(parsed.document) ? |problem| "settling the changes failed: ${Str.inspect(problem)}"
	edited = redline(settled, morgan) ? |problem| "the redline's edits failed: ${Str.inspect(problem)}"
	silent = redline(settled, Untracked) ? |problem| "the silent edits failed: ${Str.inspect(problem)}"
	if Docx.text(edited) != Docx.text(silent) {
		return Err("the tracked edits' text differs from the silent edits'")
	}
	rejected = Docx.reject(edited, By("Morgan Reviewer")) ? |problem| "rejecting the redline failed: ${Str.inspect(problem)}"
	accepted = Docx.accept(edited, By("Morgan Reviewer")) ? |problem| "accepting the redline failed: ${Str.inspect(problem)}"
	if Docx.text(rejected) != Docx.text(settled) or Docx.text(accepted) != Docx.text(silent) {
		return Err("rejecting or accepting the redline does not give the text before or after it")
	}
	written = Docx.to_bytes(edited) ? |problem| "the redlined document does not write: ${Str.inspect(problem)}"
	if Docx.to_bytes(edited) != Ok(written) {
		return Err("writing the redlined document twice gave different bytes")
	}
	again = Docx.parse(written) ? |problem| "the redlined document does not parse: ${Str.inspect(problem)}"
	if Docx.revisions(again.document) != Docx.revisions(edited) or !Docx.tracks_revisions(again.document) {
		return Err("the redlined document reads back as different changes or does not track them")
	}
	path = ".roc-docx/redline/${Str.drop_prefix(fixture, "tests/fixtures/")}"
	Ok({ written, json: Snapshot.json(again.document, { path, version: "working tree" }) })
}

# The redline session of `examples/redline`, step for step: tracking on, Ada
# Reviewer's changes accepted and Grace Author's rejected.
settle : Document -> Try(Document, Docx.EditError)
settle = |document| {
	tracking = Docx.set_tracking(document, On)?
	accepted = Docx.accept(tracking, By("Ada Reviewer"))?
	Docx.reject(accepted, By("Grace Author"))
}

morgan : Revisions.Context
morgan = Tracked({ author: "Morgan Reviewer", date: Date("2026-11-10T10:00:00Z") })

# Then the first word of the first line of text replaced, text added to the
# end of that line and the last word of the next line deleted, last first.
redline : Document, Revisions.Context -> Try(Document, Docx.EditError)
redline = |document, context| {
	text = Docx.text(document)
	lines = lines_of(text)
	trimmed = match lines.get(1) {
		Ok(line) => Docx.delete_text(document, last_word(text, line), context)?
		Err(_) => document
	}
	match lines.first() {
		Ok(line) => {
			extended = Docx.insert_text(trimmed, line.end, " (as agreed)", context)?
			Docx.replace_text(extended, first_word(text, line), "Revised", context)
		}

		Err(_) => Ok(trimmed)
	}
}

# The spans of the lines of text that are not empty.
lines_of : Str -> List(Comments.Span)
lines_of = |text| {
	var $lines = List.with_capacity(8)
	var $start = 0.U64
	for line in text.split_on("\n") {
		size = line.to_utf8().len()
		if size > 0 {
			$lines = List.append($lines, { start: $start, end: $start + size })
		}
		$start = $start + size + 1
	}
	$lines
}

# The span of a line's first word, up to its first space, or the whole line.
first_word : Str, Comments.Span -> Comments.Span
first_word = |text, line| {
	bytes = text.to_utf8()
	var $at = line.start
	while $at < line.end and bytes.get($at) != Ok(' ') {
		$at = $at + 1
	}
	{ start: line.start, end: $at }
}

# The span of a line's last word with the space before it, or the whole line.
last_word : Str, Comments.Span -> Comments.Span
last_word = |text, line| {
	bytes = text.to_utf8()
	var $at = line.end
	while $at > line.start and bytes.get($at - 1) != Ok(' ') {
		$at = $at - 1
	}
	{ start: if ($at > line.start) $at - 1 else line.start, end: line.end }
}

# The span of the first line of text that is not empty.
first_line : Str -> Comments.Span
first_line = |text| {
	var $start = 0.U64
	for line in text.split_on("\n") {
		size = line.to_utf8().len()
		if size > 0 {
			return { start: $start, end: $start + size }
		}
		$start = $start + size + 1
	}
	{ start: 0, end: 0 }
}

# Parse a document, write it, and check the pass-through properties; the
# written bytes and the report its expectation records, or what went wrong.
pass_through : List(U8) -> Try({ written : List(U8), report : Str }, Str)
pass_through = |bytes| {
	parsed = Docx.parse(bytes) ? |problem| "the fixture does not parse: ${Str.inspect(problem)}"
	written = Docx.to_bytes(parsed.document) ? |problem| "the document does not write: ${Str.inspect(problem)}"
	if Docx.to_bytes(parsed.document) != Ok(written) {
		return Err("writing the document twice gave different bytes")
	}
	again = Docx.parse(written) ? |problem| "the written document does not parse: ${Str.inspect(problem)}"
	if !Docx.equivalent(parsed.document, again.document) {
		return Err("the written document is not equivalent to the fixture")
	}
	if !again.diagnostics.is_empty() {
		return Err("the written document still has content to drop or repair: ${Str.inspect(again.diagnostics)}")
	}
	if Docx.to_bytes(again.document) != Ok(written) {
		return Err("writing the written document gave different bytes")
	}
	parts = Opc.parts(Opc.open(written, {}) ? |problem| "the written package does not open: ${Str.inspect(problem)}")
	lines = List.join([
		["written: ${written.len().to_str()} bytes, FNV-1a 64 ${hex(fnv1a(written))}"],
		parsed.diagnostics.map(describe),
		parts.map(|part| "part: ${part.name} ${part.size.to_str()} bytes ${part.content_type}"),
	])
	Ok({ written, report: Str.join_with(lines.map(|line| "${line}\n"), "") })
}

# Write every generated document, check it and report each; the number
# that failed.
run_generated! : Bool => Try(U64, _)
run_generated! = |update| {
	match Path.delete_all!(Path.utf8(".roc-docx/generated")) {
		_ => {}
	}
	Path.create_all!(Path.utf8(".roc-docx/generated"))?
	Path.create_all!(Path.utf8(".roc-docx/snapshots/generated"))?
	Stdout.line!("generated: ${generated.len().to_str()} cases${if (update) ", updating expectations" else ""}")?
	var $failed = 0.U64
	var $updated = 0.U64
	for document in generated {
		path = ".roc-docx/generated/${document.name}.docx"
		status = match built(document.content) {
			Ok({ written, report, document: read }) => {
				Path.write_bytes!(Path.utf8(path), written)?
				Path.write_utf8!(Path.utf8(".roc-docx/snapshots/generated/${document.name}.json"), Snapshot.json(read, { path, version: "working tree" }))?
				expectation = Path.utf8("tests/generated/${document.name}.txt")
				expected = Path.read_utf8!(expectation) ?? ""
				if expected == report {
					"PASS"
				} else if update {
					Path.create_all!(Path.utf8("tests/generated"))?
					Path.write_utf8!(expectation, report)?
					$updated = $updated + 1
					"UPDATED"
				} else {
					$failed = $failed + 1
					Stderr.line!("${Path.display(expectation)} expects:\n${expected}but the case reports:\n${report}")?
					"FAIL"
				}
			}

			Err(problem) => {
				$failed = $failed + 1
				Stderr.line!("${path}: ${problem}")?
				"FAIL"
			}
		}
		Stdout.line!(" ${document.name} ${status}")?
	}
	Stdout.line!("Summary: ${generated.len().to_str()} cases, ${(generated.len() - $failed - $updated).to_str()} passed, ${$updated.to_str()} updated, ${$failed.to_str()} failed, 0 skipped")?
	Ok($failed)
}

# A document whose main part holds `content` and whose settings turn
# tracking on, written as the package writes it after reading it back as
# exactly `content`; its report; and the document the written bytes read as.
built : List(Document.Block) -> Try({ written : List(U8), report : Str, document : Document }, Str)
built = |content| {
	settings_relationship = { id: "rId1", kind: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings", target: "/word/settings.xml", mode: Internal }
	shell = Element({ name: w("document"), bindings: [{ prefix: Prefix("w"), namespace: Uri(wordprocessingml) }], attributes: [], children: [] })
	main = WmlWrite.document(shell, content, { relationships: [settings_relationship], footnotes: [], endnotes: [], comments: [] }) ? |problem| "the content does not write: ${Str.inspect(problem)}"
	main_bytes = XmlTree.render(main.tree) ? |problem| "the main part does not render: ${Str.inspect(problem)}"
	settings = "<w:settings xmlns:w=\"${wordprocessingml}\"><w:trackRevisions/></w:settings>".to_utf8()
	graph = {
		relationships: [{ id: "rId1", kind: Opc.officedocument_relationship, target: "/word/document.xml", mode: Internal }],
		parts: [
			{ name: "/word/document.xml", content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml", relationships: main.relationships },
			{ name: "/word/settings.xml", content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml", relationships: [] },
		],
	}
	bytes = Opc.to_bytes(graph, |name| if (name == "/word/settings.xml") Bytes(settings) else Bytes(main_bytes)) ? |problem| "the package does not write: ${Str.inspect(problem)}"
	parsed = Docx.parse(bytes) ? |problem| "the built document does not parse: ${Str.inspect(problem)}"
	if Docx.body(parsed.document) != content {
		return Err("the built document reads back differently from its content")
	}
	if !Docx.tracks_revisions(parsed.document) {
		return Err("the built document does not track changes")
	}
	passed = pass_through(bytes)?
	again = Docx.parse(passed.written) ? |problem| "the written document does not parse: ${Str.inspect(problem)}"
	changes = Docx.revisions(again.document).map(|change| "change: ${change.id.to_str()} ${Str.inspect(change.kind)} of ${Str.inspect(change.of)} by ${change.author} \"${change.text.replace_each("\n", "\\n")}\"")
	Ok({ written: passed.written, report: Str.concat(passed.report, Str.join_with(changes.map(|line| "${line}\n"), "")), document: again.document })
}

# Documents built from the model, by name.
generated : List({ name : Str, content : List(Document.Block) })
generated = [{ name: "revisions", content: every_revision }]

# A body with every kind of tracked change the model holds: insertions,
# deletions, a deleted field's instruction, a move's source and destination
# with their ranges ending after the moved paragraph's mark, as Word writes
# them, paragraph marks inserted, deleted and moved, changes of
# run, paragraph, table, row, cell and section properties, rows inserted
# and deleted, and cells inserted, deleted and merged; a change inside a
# hyperlink, as the schema places one.
every_revision : List(Document.Block)
every_revision = {
	text = |words| Run({ properties: Document.no_run_properties, content: [Text(words)] })
	change = |kind, author, content| Revision({ kind, author, date: Date(stamp), content, preserved: [] })
	by = |author| { author, date: Date(stamp), preserved: [] }
	changed = |author, previous| { author, date: Date(stamp), preserved: [], previous }
	plain = Document.no_paragraph_properties
	marked = |kind| { ..plain, mark: [{ kind, author: "Cy", date: Date(stamp), preserved: [] }] }
	paragraph = |properties, content| Paragraph({ properties, content })
	field_mark = |kind, name| FieldMark({ kind, element: Element({ name: w("fldChar"), bindings: [], attributes: [{ name: w("fldCharType"), value: name }], children: [] }) })
	page_field = Run({ properties: Document.no_run_properties, content: [field_mark(Begin, "begin"), FieldCode(" PAGE "), field_mark(Separate, "separate"), Text("1"), field_mark(End, "end")] })
	move = |side, name| MoveStart({ side, name, author: "Cy", date: stamp, preserved: [] })
	formatted = Run({ properties: { ..Document.no_run_properties, bold: On, change: [changed("Dee", { ..Document.run_properties_with(Unset), italic: On })] }, content: [Text("Reformatted run.")] })
	centred = { ..plain, alignment: Aligned(Center), change: [changed("Dee", { ..Document.paragraph_properties_with(Unset), alignment: Aligned(Left) })] }
	cell_of = |properties, words| Cell({ properties, content: [paragraph(plain, [text(words)])] })
	cell_with = |tracked| { width: Twips(3000), span: Unset, merge: Unset, borders: [], shading: Unset, alignment: Unset, preserved: [], revision: Unset, change: tracked }
	plain_cell = cell_with([])
	plain_row = { header: Unset, grid_before: Unset, grid_after: Unset, preserved: [], inserted: Unset, deleted: Unset, change: [] }
	wide = { ..plain_cell, width: Twips(9000), span: Columns(3) }
	rows = [
		Row({ properties: { ..plain_row, inserted: Tracked(by("Eve")) }, content: [cell_of(wide, "Inserted row.")] }),
		Row({ properties: { ..plain_row, deleted: Tracked(by("Eve")) }, content: [cell_of(wide, "Deleted row.")] }),
		Row({
			properties: { ..plain_row, header: Off, change: [changed("Eve", { header: On, grid_before: Unset, grid_after: Unset, preserved: [], inserted: Unset, deleted: Unset, change: Unset })] },
			content: [
				cell_of({ ..plain_cell, change: [changed("Eve", { ..cell_with(Unset), width: Twips(2000) })] }, "Reformatted cell."),
				cell_of(plain_cell, "Above."),
				cell_of({ ..plain_cell, merge: Restart }, "Merged above."),
			],
		}),
		Row({
			properties: plain_row,
			content: [
				cell_of({ ..plain_cell, revision: Inserted(by("Eve")) }, "Inserted cell."),
				cell_of({ ..plain_cell, revision: Deleted(by("Eve")) }, "Deleted cell."),
				cell_of({ ..plain_cell, merge: Continue, revision: Merged({ author: "Eve", date: Date(stamp), preserved: [], merge: Continue, previous: Unset }) }, ""),
			],
		}),
	]
	table = Table({ properties: { style: Unset, width: Twips(9000), borders: [], shading: Unset, preserved: [], change: [changed("Eve", { style: Unset, width: Auto, borders: [], shading: Unset, preserved: [], change: Unset })] }, grid: [Column(3000), Column(3000), Column(3000)], content: rows })
	letter = Size({ width: 12240, height: 15840, orientation: Portrait })
	section = Section({ start: Unset, page_size: Size({ width: 11906, height: 16838, orientation: Portrait }), margins: Unset, columns: Unset, page_numbers: Unset, title_page: Unset, headers: [], footers: [], preserved: [], change: [changed("Fay", { start: Unset, page_size: letter, margins: Unset, columns: Unset, page_numbers: Unset, title_page: Unset, headers: [], footers: [], preserved: [], change: Unset })] })
	[
		paragraph(plain, [text("Kept, "), change(Insertion, "Ada", [text("inserted, ")]), change(Deletion, "Ben", [text("deleted, "), page_field]), text("kept.")]),
		paragraph(marked(MoveSource), [move(Source, "move1"), change(MoveSource, "Cy", [text("Moved paragraph.")])]),
		paragraph(marked(Insertion), [MoveEnd({ side: Source, name: "move1" }), text("Inserted mark.")]),
		paragraph(marked(Deletion), [text("Deleted mark, ")]),
		paragraph(plain, [text("joined.")]),
		paragraph(marked(MoveDestination), [move(Destination, "move1"), change(MoveDestination, "Cy", [text("Moved paragraph.")])]),
		paragraph(centred, [MoveEnd({ side: Destination, name: "move1" }), formatted]),
		paragraph(plain, [Hyperlink({ target: External("https://example.org/"), preserved: [], content: [change(Insertion, "Ada", [text("Inserted link.")])] })]),
		table,
		paragraph(plain, [text("After the table.")]),
		section,
	]
}

stamp : Document.Timestamp
stamp = { written: "2026-05-07T09:00:00Z", utc_seconds: 1778144400 }

wordprocessingml : Str
wordprocessingml = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

w : Str -> XmlTree.Name
w = |local| { namespace: Uri(wordprocessingml), local, prefix: Prefix("w") }

describe : Document.Diagnostic -> Str
describe = |diagnostic|
	match diagnostic {
		Dropped({ part, content, count }) => {
			kind = match content {
				RevisionSaveIds => "revision save identifiers"
				RenderedPageBreaks => "rendered page breaks"
				ProofingMarks => "proofing marks"
				GoBackBookmark => "_GoBack bookmarks"
			}
			"dropped: ${part} ${count.to_str()} ${kind}"
		}

		Rounded({ part, element, attribute, value }) => "rounded: ${part} ${element} ${attribute} ${value}"
		Defaulted({ part, element, attribute, value }) => "defaulted: ${part} ${element} ${attribute} ${value}"
	}

fnv1a : List(U8) -> U64
fnv1a = |bytes| bytes.fold(14_695_981_039_346_656_037, |hash, byte| hash.bitwise_xor(byte.to_u64()).times_wrap(1_099_511_628_211))

hex : U64 -> Str
hex = |value| {
	digits = "0123456789abcdef".to_utf8()
	var $out = List.with_capacity(16)
	var $rest = value
	for _ in List.repeat(0, 16) {
		$out = List.prepend($out, digits.get(($rest % 16)) ?? '0')
		$rest = $rest // 16
	}
	Str.from_utf8($out) ?? ""
}

is_update : [Utf8(Str), UnixBytes(List(U8)), WindowsU16s(List(U16))] -> Bool
is_update = |arg|
	match arg {
		Utf8(text) => text == "--update"
		UnixBytes(bytes) => bytes == "--update".to_utf8()
		WindowsU16s(units) => units == "--update".to_utf8().map(|byte| byte.to_u16())
	}

directory_of : Str -> Str
directory_of = |path|
	match path.split_last("/") {
		Ok({ before, after: _ }) => before
		Err(_) => "."
	}

# Paths in byte order, so the cases run in the same order on every host.
sorted : List(Str) -> List(Str)
sorted = |paths|
	paths.sort_with(
		|a, b| {
			left = a.to_utf8()
			right = b.to_utf8()
			var $index = 0.U64
			while $index < left.len() and $index < right.len() {
				x = left.get($index) ?? 0
				y = right.get($index) ?? 0
				if x != y {
					return if (x < y) Before else After
				}
				$index = $index + 1
			}
			if (left.len() < right.len()) Before else if (left.len() > right.len()) After else Same
		},
	)

# Every file below a directory.
files_under! : Path => Try(List(Path), _)
files_under! = |directory| {
	var $files = List.with_capacity(32)
	for entry in Path.list!(directory)? {
		if Path.is_dir!(entry)? {
			$files = List.concat($files, files_under!(entry)?)
		} else {
			$files = List.append($files, entry)
		}
	}
	Ok($files)
}
