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
import docx.Revisions

# Redline an amendment: settle the reviewers' earlier changes, then make new
# edits as tracked changes and write the document back with tracking on.
#
# `Docx.accept` and `Docx.reject` take a selection of the body's tracked
# changes: all of them, an author's, those made in a date range, or ids from
# `Docx.revisions`. Text edits name a span of `Docx.text` as byte offsets and
# take a context, `Untracked` or `Tracked({ author, date })`; the author and
# date come from the application, since the package reads no clock.
#
#     cd examples/redline && roc main.roc                      # amendment.docx to redlined.docx
#     cd examples/redline && roc main.roc in.docx out.docx
main! : List([Utf8(Str), UnixBytes(List(U8)), WindowsU16s(List(U16))]) => Try({}, _)
main! = |args| {
	{ input, output } = match args {
		[from, to] => { input: Path.from_os_str(OsStr.from_raw(from)), output: Path.from_os_str(OsStr.from_raw(to)) }
		_ => { input: Path.utf8("amendment.docx"), output: Path.utf8("redlined.docx") }
	}
	parsed = Docx.parse(Path.read_bytes!(input)?)?
	redlined = redline(parsed.document)?
	Path.write_bytes!(output, Docx.to_bytes(redlined)?)?

	Stdout.line!("Tracked changes in ${Path.display(output)}, tracking ${if (Docx.tracks_revisions(redlined)) "on" else "off"}:")?
	for change in Docx.revisions(redlined) {
		said = if (change.text == "" or change.of == ParagraphMark) "" else ": \"${change.text}\""
		Stdout.line!("  [${change.id.to_str()}] ${change.author} ${described(change)}${said}")?
	}
	Stdout.line!("Final text:\n${Docx.final_text(redlined)}")?
	Ok({})
}

# A redline: turn tracking on, accept Ada Reviewer's changes and reject
# Grace Author's, then, as Morgan Reviewer, replace the first word of the
# first line of text, add to the end of that line, and delete the last word
# of the next line. The edits are made from the last to the first, so each
# span, found in the text before them, still names the same text.
redline : Document -> Try(Document, Docx.EditError)
redline = |document| {
	tracking = Docx.set_tracking(document, On)?
	accepted = Docx.accept(tracking, By("Ada Reviewer"))?
	settled = Docx.reject(accepted, By("Grace Author"))?
	morgan = Tracked({ author: "Morgan Reviewer", date: Date("2026-11-10T10:00:00Z") })
	text = Docx.text(settled)
	lines = lines_of(text)
	trimmed = match lines.get(1) {
		Ok(line) => Docx.delete_text(settled, last_word(text, line), morgan)?
		Err(_) => settled
	}
	match lines.first() {
		Ok(line) => {
			extended = Docx.insert_text(trimmed, line.end, " (as agreed)", morgan)?
			Docx.replace_text(extended, first_word(text, line), "Revised", morgan)
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

# What a tracked change did.
described : Revisions.Listed -> Str
described = |change| {
	what = match change.of {
		Content | Run => "text"
		ParagraphMark => "a paragraph mark"
		Paragraph => "a paragraph"
		Section => "a section"
		Table => "a table"
		Row => "a row"
		Cell => "a cell"
	}
	match change.kind {
		Insertion => "inserted ${what}"
		Deletion => "deleted ${what}"
		MoveSource => "moved away ${what}"
		MoveDestination => "moved here ${what}"
		Merge => "merged ${what} with the cell above"
		Formatting => "changed the formatting of ${what}"
	}
}
