app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.0/2yhxoR7cZPSYbyUzPWULFw8AA6QEcdsgFNRmzu7pZbst.tar.zst",
	docx: "../../package/main.roc",
}

import cli.OsStr
import cli.Path
import cli.Stdout
import docx.Build
import docx.Docx
import docx.Document

# Write a letter: a new document from the default document kit, with its
# title, author and date, and paragraphs of formatted text. A line feed in a
# run of text is a line break, so each address is one paragraph.
#
#     cd examples/letter && roc main.roc              # writes letter.docx
#     cd examples/letter && roc main.roc out.docx
main! : List([Utf8(Str), UnixBytes(List(U8)), WindowsU16s(List(U16))]) => Try({}, _)
main! = |args| {
	output = match args {
		[to] => Path.from_os_str(OsStr.from_raw(to))
		_ => Path.utf8("letter.docx")
	}
	document = letter()?
	Path.write_bytes!(output, Docx.to_bytes(document)?)?
	Stdout.line!("Wrote ${Path.display(output)}:\n${Docx.text(document)}")?
	Ok({})
}

# The letter. The package reads no clock, so its date is the application's.
letter : () -> Try(Document, [NotADate(Str)])
letter = || {
	created = Docx.new_document({ title: Text("Winter deliveries"), creator: Text("Nora Quill"), created: Date("2026-11-10T09:00:00Z") })?
	plain = |text| Build.paragraph({}, [Build.text(text, {})])
	Ok(
		Build.append(
			created,
			[
				Build.paragraph({ alignment: Right }, [Build.text("Harbour Lane Bakery\n14 Quay Street\nPortwen", {})]),
				Build.paragraph({ alignment: Right }, [Build.text("10 November 2026", {})]),
				plain("Odile Fenwick\nOrchard Mill Supplies\n2 Mill Row\nAshcombe"),
				plain("Dear Ms Fenwick,"),
				Build.paragraph({}, [Build.text("Flour deliveries for the winter", { bold: On })]),
				Build.paragraph(
					{ alignment: Justified },
					[
						Build.text("Thank you for a year of reliable deliveries. From December we bake on Sundays too, so we would like ", {}),
						Build.text("two deliveries a week", { bold: On }),
						Build.text(", on Mondays and Thursdays, until the end of February.", {}),
					],
				),
				Build.paragraph({ alignment: Justified }, [Build.text("Our agreement for the new year follows separately. ", {}), Build.text("Please let me know by Friday", { italic: On }), Build.text(" whether the new days suit you.", {})]),
				plain("Yours sincerely,"),
				plain("Nora Quill\nOwner, Harbour Lane Bakery"),
			],
		),
	)
}
