import pf.Worker
import docx.Build
import docx.Docx
import docx.Document
import Base64
import Explore
import Review

## Generate a letter from a form, as `examples/letter` does from code: a new
## document from the default kit, its properties, and formatted paragraphs.
## A note fills in a comment on the subject line, so the generated document
## shows a comment thread too.
Generate := [].{

	Letter : { sender : Str, recipient : Str, date : Str, subject : Str, body : Str, closing : Str, signature : Str, note : Str, created : Str }

	example : Letter
	example = {
		sender: "Harbour Lane Bakery\n14 Quay Street\nPortwen",
		recipient: "Odile Fenwick\nOrchard Mill Supplies\n2 Mill Row\nAshcombe",
		date: "10 November 2026",
		subject: "Flour deliveries for the winter",
		body: "Thank you for a year of reliable deliveries. From December we bake on Sundays too, so we would like two deliveries a week, on Mondays and Thursdays, until the end of February.\n\nOur agreement for the new year follows separately. Please let me know by Friday whether the new days suit you.",
		closing: "Yours sincerely,",
		signature: "Nora Quill\nOwner, Harbour Lane Bakery",
		note: "Should we name the delivery window too?",
		created: "2026-11-10T09:00:00Z",
	}

	letter : Worker.Task(Letter, Review.Reviewed, Explore.Problem)
	letter = Worker.task({ name: "roc-docx/playground/letter", run!: |input| Generate.generated(input) })

	generated : Letter -> Try(Review.Reviewed, Explore.Problem)
	generated = |l| {
		document = Generate.document(l) ? |e| Unreadable(Str.inspect(e))
		bytes = Docx.to_bytes(document) ? |e| Unreadable("Writing failed: ${Str.inspect(e)}")
		again = Docx.parse(bytes) ? |e| Unreadable("The written document does not read: ${Str.inspect(e)}")
		model = Explore.of_document(bytes, again.document, again.diagnostics)?
		Ok({ model, base64: Base64.encode(bytes), size: bytes.len() })
	}

	document : Letter -> Try(Document, [NotADate(Str), EditFailed(Docx.EditError)])
	document = |l| {
		author = l.signature.split_on("\n").first() ?? ""
		created = Docx.new_document({ title: Text(l.subject), creator: Text(author), created: Date(l.created) })?
		plain = |text| Build.paragraph({}, [Build.text(text, {})])
		body = l.body.split_on("\n\n").map(|p| p.trim()).keep_if(|p| !p.is_empty()).map(|p| Build.paragraph({ alignment: Justified }, [Build.text(p, {})]))
		built = Build.append(
			created,
			[
				Build.paragraph({ alignment: Right }, [Build.text(l.sender, {})]),
				Build.paragraph({ alignment: Right }, [Build.text(l.date, {})]),
				plain(l.recipient),
				Build.paragraph({}, [Build.text(l.subject, { bold: On })]),
			]
				.concat(body)
				.concat([plain(l.closing), plain(l.signature)]),
		)
		if l.note.trim().is_empty() or l.subject.is_empty() {
			Ok(built)
		} else {
			span = Generate.span_of(Docx.text(built), l.subject)
			added = Docx.add_comment(built, span, { author: "Reviewer", content: Text(l.note.trim()), date: Date(l.created) }) ? EditFailed
			Ok(added.document)
		}
	}

	## The byte span of the first line that is exactly `line`.
	span_of : Str, Str -> { start : U64, end : U64 }
	span_of = |text, line| {
		var $start = 0.U64
		for each in text.split_on("\n") {
			size = each.to_utf8().len()
			if each == line {
				return { start: $start, end: $start + size }
			}
			$start = $start + size + 1
		}
		{ start: 0, end: 0 }
	}

	## The Roc that builds this letter, for the page to show beside it.
	source : Letter -> Str
	source = |l| {
		q = |s| Generate.quoted(s)
		body = l.body.split_on("\n\n").map(|p| p.trim()).keep_if(|p| !p.is_empty()).map(|p| "\t\tBuild.paragraph({ alignment: Justified }, [Build.text(${q(p)}, {})]),")
		comment =
			if l.note.trim().is_empty() {
				["Ok(letter)"]
			} else {
				[
					"span = { start: ..., end: ... } # the subject line in Docx.text(letter)",
					"commented = Docx.add_comment(letter, span, { author: \"Reviewer\", content: Text(${q(l.note.trim())}) })?",
					"Ok(commented.document)",
				]
			}
		lines = [
			"created = Docx.new_document({ title: Text(${q(l.subject)}), creator: Text(${q(l.signature.split_on("\n").first() ?? "")}), created: Date(${q(l.created)}) })?",
			"letter = Build.append(",
			"\tcreated,",
			"\t[",
			"\t\tBuild.paragraph({ alignment: Right }, [Build.text(${q(l.sender)}, {})]),",
			"\t\tBuild.paragraph({ alignment: Right }, [Build.text(${q(l.date)}, {})]),",
			"\t\tBuild.paragraph({}, [Build.text(${q(l.recipient)}, {})]),",
			"\t\tBuild.paragraph({}, [Build.text(${q(l.subject)}, { bold: On })]),",
		]
			.concat(body)
			.concat([
				"\t\tBuild.paragraph({}, [Build.text(${q(l.closing)}, {})]),",
				"\t\tBuild.paragraph({}, [Build.text(${q(l.signature)}, {})]),",
				"\t],",
				")",
			])
			.concat(comment)
		Str.join_with(lines, "\n")
	}

	quoted : Str -> Str
	quoted = |s| "\"${s.replace_each("\\", "\\\\").replace_each("\"", "\\\"").replace_each("\n", "\\n")}\""
}

## A line is found by its byte offsets.
expect Generate.span_of("ab\ncd\nef", "cd") == { start: 3, end: 5 }

## The example letter builds.
expect Generate.document(Generate.example).is_ok()

## Quoting escapes line feeds and quotes.
expect Generate.quoted("a\"b\nc") == "\"a\\\"b\\nc\""
