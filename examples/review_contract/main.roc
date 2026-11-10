app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.27.0/9yjxqdGTP4xSpSEmDazwTmRsehfRZzA19pwEKkR6fj1g.tar.zst",
	docx: "../../package/main.roc",
}

import cli.OsStr
import cli.Path
import cli.Stdout
import docx.Comments
import docx.Docx
import docx.Document

# Review a contract's comments: add one, reply, resolve a thread and remove
# a comment, then write the document back.
#
# `Docx.comments` lists a document's comments in the order their anchors
# begin, each with its `id`, the place an edit names it by. A new comment is
# anchored to a span of `Docx.text`, as byte offsets, which no comment edit
# changes. Every edit returns a new document; the author and date of a new
# comment come from the application, since the package reads no clock.
#
#     cd examples/review_contract && roc main.roc                      # contract.docx to reviewed.docx
#     cd examples/review_contract && roc main.roc in.docx out.docx
main! : List([Utf8(Str), UnixBytes(List(U8)), WindowsU16s(List(U16))]) => Try({}, _)
main! = |args| {
	{ input, output } = match args {
		[from, to] => { input: Path.from_os_str(OsStr.from_raw(from)), output: Path.from_os_str(OsStr.from_raw(to)) }
		_ => { input: Path.utf8("contract.docx"), output: Path.utf8("reviewed.docx") }
	}
	parsed = Docx.parse(Path.read_bytes!(input)?)?
	reviewed = review(parsed.document)?
	Path.write_bytes!(output, Docx.to_bytes(reviewed)?)?

	Stdout.line!("Comments in ${Path.display(output)}:")?
	for entry in Docx.comments(reviewed).comments {
		indent = if (entry.comment.parent == Unset) "  " else "    reply "
		resolved = if (entry.comment.resolved) ", resolved" else ""
		said = match Str.join_with(entry.comment.content.map(paragraph_text), " ") {
			"" => ""
			text => ": ${text}"
		}
		on = match entry.anchor {
			Range(text) => " on \"${text}\""
			Point => ""
			Unanchored => ""
		}
		Stdout.line!("${indent}[${entry.id.to_str()}] ${entry.comment.author}${resolved}${on}${said}")?
	}
	Ok({})
}

# A reviewer's pass: comment on the title, the first line of text; reply to
# the comment that comes first and resolve its thread; then remove the last
# of the comments the document came with, when it came with more than one.
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

paragraph_text : Document.Block -> Str
paragraph_text = |block|
	match block {
		Paragraph(paragraph) => Document.paragraph_text(paragraph)
		_ => ""
	}
