app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.0/2yhxoR7cZPSYbyUzPWULFw8AA6QEcdsgFNRmzu7pZbst.tar.zst",
	docx: "../../package/main.roc",
}

import cli.OsStr
import cli.Path
import cli.Stdout
import docx.Build
import docx.Comments
import docx.Docx
import docx.Document

# Draft an agreement and review it with comments: the buyer drafts it with
# numbered clauses and a table to sign, then the supplier comments on two of
# the clauses and the buyer replies to one of the comments.
#
# A comment is anchored to a span of `Docx.text`, as byte offsets; the
# author and date of each come from the application, since the package reads
# no clock.
#
#     cd examples/agreement && roc main.roc              # writes agreement.docx
#     cd examples/agreement && roc main.roc out.docx
main! : List([Utf8(Str), UnixBytes(List(U8)), WindowsU16s(List(U16))]) => Try({}, _)
main! = |args| {
	output = match args {
		[to] => Path.from_os_str(OsStr.from_raw(to))
		_ => Path.utf8("agreement.docx")
	}
	reviewed = review(draft()?)?
	Path.write_bytes!(output, Docx.to_bytes(reviewed)?)?

	Stdout.line!("Comments in ${Path.display(output)}:")?
	for entry in Docx.comments(reviewed).comments {
		indent = if (entry.comment.parent == Unset) "  " else "    reply "
		on = match entry.anchor {
			Range(text) => " on \"${text}\""
			Point | Unanchored => ""
		}
		said = Str.join_with(entry.comment.content.map(paragraph_text), " ")
		Stdout.line!("${indent}[${entry.id.to_str()}] ${entry.comment.author}${on}: ${said}")?
	}
	Ok({})
}

# The buyer's draft.
draft : () -> Try(Document, [NotADate(Str)])
draft = || {
	created = Docx.new_document({ title: Text("Supply agreement"), creator: Text("Nora Quill"), created: Date("2026-11-10T09:00:00Z") })?
	clause = |text| Build.list_item({ list: Numbered }, [Build.text(text, {})])
	cell = |text| Build.cell({}, [Build.paragraph({}, [Build.text(text, {})])])
	Ok(
		Build.append(
			created,
			[
				Build.paragraph({ style: Heading(1) }, [Build.text("Supply agreement", {})]),
				Build.paragraph({}, [Build.text("This agreement is made between ", {}), Build.text("Harbour Lane Bakery", { bold: On }), Build.text(", the buyer, and ", {}), Build.text("Orchard Mill Supplies", { bold: On }), Build.text(", the supplier.", {})]),
				clause("The supplier delivers flour to the bakery every Monday."),
				clause("The buyer pays each invoice within thirty days."),
				clause("Either party may end this agreement with sixty days' notice."),
				Build.table({ header_rows: 1 }, [[cell("For the buyer"), cell("For the supplier")], [cell("Nora Quill"), cell("Odile Fenwick")]]),
			],
		),
	)
}

# The supplier's comments, and the buyer's reply to the first.
review : Document -> Try(Document, _)
review = |document| {
	text = Docx.text(document)
	odile = |date, said| { author: "Odile Fenwick", initials: Initials("OF"), date: Date(date), content: Text(said) }
	payment = Docx.add_comment(document, span_of(text, "within thirty days")?, odile("2026-11-12T14:00:00Z", "We ask for payment within fourteen days."))?
	delivery = Docx.add_comment(payment.document, span_of(text, "every Monday")?, odile("2026-11-12T14:05:00Z", "Could deliveries move to Tuesdays?"))?
	replied = Docx.reply(delivery.document, payment.id, { author: "Nora Quill", initials: Initials("NQ"), date: Date("2026-11-13T09:30:00Z"), content: Text("Twenty-one days would suit us both.") })?
	Ok(replied.document)
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

paragraph_text : Document.Block -> Str
paragraph_text = |block|
	match block {
		Paragraph(paragraph) => Document.paragraph_text(paragraph)
		_ => ""
	}
