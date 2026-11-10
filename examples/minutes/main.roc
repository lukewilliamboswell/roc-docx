app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.27.0/9yjxqdGTP4xSpSEmDazwTmRsehfRZzA19pwEKkR6fj1g.tar.zst",
	docx: "../../package/main.roc",
}

import cli.OsStr
import cli.Path
import cli.Stdout
import docx.Build
import docx.Comments
import docx.Docx
import docx.Document

# Take minutes and amend them as tracked changes: the secretary drafts the
# minutes of a meeting, then the chair turns tracking on and corrects them,
# replacing and inserting text, deleting a decision and adding another.
#
# Each edit names a span of `Docx.text`, as byte offsets, found here by the
# text it holds, and a context, `Tracked({ author, date })`; the author and
# date come from the application, since the package reads no clock.
#
#     cd examples/minutes && roc main.roc              # writes minutes.docx
#     cd examples/minutes && roc main.roc out.docx
main! : List([Utf8(Str), UnixBytes(List(U8)), WindowsU16s(List(U16))]) => Try({}, _)
main! = |args| {
	output = match args {
		[to] => Path.from_os_str(OsStr.from_raw(to))
		_ => Path.utf8("minutes.docx")
	}
	amended = amend(draft()?)?
	Path.write_bytes!(output, Docx.to_bytes(amended)?)?

	Stdout.line!("Tracked changes in ${Path.display(output)}:")?
	for change in Docx.revisions(amended) {
		did = match change.kind {
			Insertion => "inserted"
			Deletion => "deleted"
			_ => "changed"
		}
		what = if (change.of == ParagraphMark) "a paragraph mark" else "\"${change.text}\""
		Stdout.line!("  [${change.id.to_str()}] ${change.author} ${did} ${what}")?
	}
	Stdout.line!("Final text:\n${Docx.final_text(amended)}")?
	Ok({})
}

# The secretary's draft.
draft : () -> Try(Document, [NotADate(Str)])
draft = || {
	created = Docx.new_document({ title: Text("Staff meeting minutes"), creator: Text("Iris Cole"), created: Date("2026-11-03T17:00:00Z") })?
	heading = |text| Build.paragraph({ style: Heading(2) }, [Build.text(text, {})])
	item = |options, text| Build.list_item(options, [Build.text(text, {})])
	Ok(
		Build.append(
			created,
			[
				Build.paragraph({ style: Heading(1) }, [Build.text("Staff meeting", {})]),
				Build.paragraph({}, [Build.text("Held on 3 November 2026 at the Quay Street shop.", {})]),
				heading("Present"),
				item({}, "Nora Quill, chair"),
				item({}, "Iris Cole, secretary"),
				item({}, "Tomas Reed"),
				heading("Decisions"),
				item({ list: Numbered }, "The shop opens at 7 a.m. from December."),
				item({ list: Numbered }, "Weekend shifts rotate monthly."),
				item({ list: Numbered }, "The old oven is sold."),
				heading("Next meeting"),
				Build.paragraph({}, [Build.text("The next meeting is on 1 December 2026.", {})]),
			],
		),
	)
}

# The chair's corrections, each found in the text as it stands before it.
amend : Document -> Try(Document, _)
amend = |document| {
	nora = Tracked({ author: "Nora Quill", date: Date("2026-11-04T08:30:00Z") })
	tracking = Docx.set_tracking(document, On)?
	earlier = Docx.replace_text(tracking, span_of(Docx.text(tracking), "7 a.m.")?, "6.30 a.m.", nora)?
	paired = Docx.insert_text(earlier, span_of(Docx.text(earlier), "monthly")?.end, ", in pairs", nora)?
	van = Build.list_item({ list: Numbered }, [Build.text("A second delivery van is leased.", {})])
	leased = Docx.insert_blocks(paired, span_of(Docx.text(paired), "Next meeting")?.start, [van], nora)?
	Docx.delete_blocks(leased, span_of(Docx.text(leased), "The old oven is sold.\n")?, nora)
}

# The span of the first `phrase` in `text`.
span_of : Str, Str -> Try(Comments.Span, [NotInText(Str)])
span_of = |text, phrase|
	match text.split_first(phrase) {
		Ok({ before, after: _ }) => {
			start = before.to_utf8().len()
			Ok({ start, end: start + phrase.to_utf8().len() })
		}

		Err(NotFound) => Err(NotInText(phrase))
	}
