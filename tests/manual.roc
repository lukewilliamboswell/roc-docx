app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.27.0/9yjxqdGTP4xSpSEmDazwTmRsehfRZzA19pwEKkR6fj1g.tar.zst",
	docx: "../package/main.roc",
}

import cli.Path
import cli.Stderr
import cli.Stdout
import docx.Build
import docx.Comments
import docx.Docx
import docx.Document
import docx.Mce
import docx.Numbering
import docx.Opc
import docx.Styles
import docx.WmlRead
import docx.WmlWrite
import docx.XmlTree

## The manual's Roc snippets, compiled and run from the repository root:
##
##     roc tests/manual.roc
##
## Every Roc listing in `docs/` is a tagged region of a function below, which
## the chapter includes by its tag, so what the manual shows is what this
## program compiles. Each function runs on a document of the repository and
## must succeed; the program prints every snippet with PASS or FAIL.
main! : List([Utf8(Str), UnixBytes(List(U8)), WindowsU16s(List(U16))]) => Try({}, _)
main! = |_args| {
	contract = Path.read_bytes!(Path.utf8("examples/review_contract/contract.docx"))?
	amendment = Path.read_bytes!(Path.utf8("examples/redline/amendment.docx"))?
	report = Path.read_bytes!(Path.utf8("tests/fixtures/word/report.docx"))?
	basics = Path.read_bytes!(Path.utf8("tests/fixtures/pandoc/basics.docx"))?
	tables = Path.read_bytes!(Path.utf8("tests/fixtures/word/tables.docx"))?
	main_part = Opc.part_bytes(Opc.open(report, {})?, "/word/document.xml")?
	reported = Docx.parse(report)?.document
	reviewed = Docx.parse(contract)?.document
	amended = Docx.parse(amendment)?.document
	tabled = Docx.parse(tables)?.document
	first_line_end = (Docx.text(amended).split_first("\n") ?? { before: "", after: "" }).before.to_utf8().len()
	basics_shell = XmlTree.parse(Opc.part_bytes(Opc.open(basics, {})?, "/word/document.xml")?, {})?
	outcomes = [
		{ name: "xml-parse", outcome: done(part_xml(main_part)) },
		{ name: "mce", outcome: done(interpret(main_part)) },
		{ name: "pass-through", outcome: done(pass_through(report)) },
		{ name: "limits", outcome: done(bounded(report)) },
		{ name: "diagnostics", outcome: done(described_diagnostics(report)) },
		{ name: "query-diagnostics", outcome: done(query_diagnostics(reported)) },
		{ name: "text", outcome: done(read_text(report)) },
		{ name: "paragraphs", outcome: done(paragraph_texts(reported)) },
		{ name: "notes", outcome: done(first_footnote(reported)) },
		{ name: "fields", outcome: done(page_fields(reported)) },
		{ name: "headings", outcome: done(heading_list(reported)) },
		{ name: "effective-paragraphs", outcome: done(bold_text(reported)) },
		{ name: "lists", outcome: done(list_items(reported)) },
		{ name: "tables", outcome: done(cell_counts(tabled)) },
		{ name: "sections", outcome: done(any_landscape(reported)) },
		{ name: "headers-footers", outcome: done(footer_fields(reported)) },
		{ name: "comments", outcome: done(comment_summaries(contract)) },
		{ name: "threads", outcome: done(threads_of(reviewed)) },
		{ name: "edit-comments", outcome: done(review(contract)) },
		{ name: "review-texts", outcome: done(review_texts(amendment)) },
		{ name: "revisions", outcome: done(change_summaries(amended)) },
		{ name: "accept-all", outcome: done(settle_all(amendment)) },
		{ name: "select", outcome: done(settle_some(amended)) },
		{ name: "replace-text", outcome: done(replace_terms(reviewed)) },
		{ name: "across-lines", outcome: done(across_lines(amended, first_line_end, first_line_end + 1)) },
		{ name: "block-edits", outcome: done(block_edits(amended, 0, first_line_end + 1)) },
		{ name: "model-revision", outcome: done(inserted_run(Build.text("New text", {}))) },
		{ name: "tracks", outcome: done(Ok(tracking_said(amended))) },
		{ name: "set-tracking", outcome: done(for_review(reviewed)) },
		{ name: "write-body", outcome: done(write_body(basics_shell, Docx.body(Docx.parse(basics)?.document))) },
		{ name: "write-options", outcome: done(written_with_options(reviewed)) },
		{ name: "write-chunks", outcome: done(streamed_length(reviewed)) },
		{ name: "set-properties", outcome: done(retitled(reviewed)) },
		{ name: "new-document", outcome: done(new_lease({})) },
		{ name: "build", outcome: done(tenancy_notice({})) },
		{ name: "footer", outcome: done(footer_added(Docx.new_document({})?)) },
		{ name: "odd-even-first", outcome: done(pages_headed(Docx.new_document({})?)) },
		{ name: "section", outcome: done(Ok(annexed(Docx.new_document({})?))) },
		{ name: "styles-writer", outcome: done(Ok(styles_tree({ paragraph: Document.no_paragraph_properties, run: Document.no_run_properties }, []))) },
	]
	var $failed = 0.U64
	for snippet in outcomes {
		match snippet.outcome {
			Ok({}) => Stdout.line!("PASS ${snippet.name}")?
			Err(problem) => {
				$failed = $failed + 1
				Stderr.line!("FAIL ${snippet.name}: ${problem}")?
			}
		}
	}
	Stdout.line!("Summary: ${outcomes.len().to_str()} snippets, ${(outcomes.len() - $failed).to_str()} passed, ${$failed.to_str()} failed")?
	if $failed > 0 {
		Err(Exit(1))
	} else {
		Ok({})
	}
}

# Whether a snippet succeeded, and if not, why.
done : Try(a, e) -> Try({}, Str)
done = |result|
	match result {
		Ok(_) => Ok({})
		Err(problem) => Err(Str.inspect(problem))
	}

# Read and write the parts of a document

part_xml : List(U8) -> Try(XmlTree.Node, _)
part_xml = |bytes| {
	# tag::xml-parse[]
	tree = XmlTree.parse(bytes, { max_xml_depth: 64 })?
	# end::xml-parse[]
	Ok(tree)
}

interpret : List(U8) -> Try({ interpreted : XmlTree.Node, diagnostics : List(Mce.Diagnostic) }, _)
interpret = |bytes| {
	# tag::mce[]
	tree = XmlTree.parse(bytes, {})?
	{ interpreted, diagnostics } = Mce.process(tree)
	# end::mce[]
	Ok({ interpreted, diagnostics })
}

pass_through : List(U8) -> Try({ written : List(U8), diagnostics : List(Document.Diagnostic) }, _)
pass_through = |bytes| {
	# tag::pass-through[]
	{ document, diagnostics } = Docx.parse(bytes)?
	written = Docx.to_bytes(document)?
	# end::pass-through[]
	Ok({ written, diagnostics })
}

# Read untrusted and imperfect documents

bounded : List(U8) -> Try(Str, _)
bounded = |bytes| {
	# tag::limits[]
	{ document, diagnostics: _ } = Docx.parse_with(bytes, { max_part_bytes: 8_388_608, max_xml_depth: 256 })?
	# end::limits[]
	Ok(Docx.text(document))
}

described_diagnostics : List(U8) -> Try(List(Str), _)
described_diagnostics = |bytes| {
	# tag::diagnostics[]
	{ document: _, diagnostics } = Docx.parse(bytes)?
	notes = diagnostics.map(
		|diagnostic|
			match diagnostic {
				Dropped({ part, content, count }) => "${part}: ${Str.inspect(content)} dropped ${count.to_str()} times"
				Rounded({ part, element, attribute, value }) => "${part}: ${element} ${attribute} ${value} rounded"
				Defaulted({ part, element, attribute, value }) => "${part}: ${element} ${attribute} supplied as ${value}"
			},
	)
	# end::diagnostics[]
	Ok(notes)
}

query_diagnostics : Document -> Try(U64, _)
query_diagnostics = |document| {
	# tag::query-diagnostics[]
	{ blocks: _, diagnostics: in_body } = Docx.read_body(document)
	{ comments: _, diagnostics: in_comments } = Docx.comments(document)
	{ styles: _, diagnostics: in_styles } = Docx.styles(document)
	{ numbering: _, diagnostics: in_numbering } = Docx.numbering(document)
	# end::query-diagnostics[]
	Ok(in_body.len() + in_comments.len() + in_styles.len() + in_numbering.len())
}

# Read a document's text

read_text : List(U8) -> Try(Str, _)
read_text = |bytes| {
	# tag::text[]
	{ document, diagnostics: _ } = Docx.parse(bytes)?
	text = Docx.text(document)
	# end::text[]
	Ok(text)
}

paragraph_texts : Document -> Try(List(Str), _)
paragraph_texts = |document| {
	# tag::paragraphs[]
	paragraphs = Docx.body(document).keep_oks(
		|block|
			match block {
				Paragraph(paragraph) => Ok(Document.paragraph_text(paragraph))
				_ => Err(NotAParagraph)
			},
	)
	# end::paragraphs[]
	Ok(paragraphs)
}

first_footnote : Document -> Try(Document.Note, _)
first_footnote = |document| {
	# tag::notes[]
	note_of = |reference|
		match reference.kind {
			Footnote => Docx.footnotes(document).get(reference.note)
			Endnote => Docx.endnotes(document).get(reference.note)
		}
	# end::notes[]
	note_of({ kind: Footnote, note: 0 })
}

page_fields : Document -> Try(List(Document.Field), _)
page_fields = |document| {
	# tag::fields[]
	pages = Docx.fields(document).keep_if(|field| field.code.contains("PAGE"))
	# end::fields[]
	Ok(pages)
}

heading_list : Document -> Try(List({ level : U8, text : Str }), _)
heading_list = |document| {
	# tag::headings[]
	{ styles, diagnostics: _ } = Docx.styles(document)
	headings = Docx.body(document).keep_oks(
		|block|
			match block {
				Paragraph(paragraph) =>
					match Styles.effective_paragraph(styles, paragraph.properties, {}).outline_level {
						Level(level) if level < 9 => Ok({ level, text: Document.paragraph_text(paragraph) })
						_ => Err(NotAHeading)
					}

				_ => Err(NotAHeading)
			},
	)
	# end::headings[]
	Ok(headings)
}

bold_text : Document -> Try(List(Str), _)
bold_text = |document| {
	# tag::effective-paragraphs[]
	bold = List.join(
		Docx.paragraphs(document).keep_if(|paragraph| paragraph.location == Body).map(
			|paragraph| paragraph.runs.keep_if(|run| run.properties.bold == On).map(|run| Document.inline_text(Run(run.run))),
		),
	)
	# end::effective-paragraphs[]
	Ok(bold)
}

list_items : Document -> Try(List({ depth : U8, bullet : Bool, text : Str }), _)
list_items = |document| {
	# tag::lists[]
	{ styles, diagnostics: _ } = Docx.styles(document)
	{ numbering, diagnostics: _ } = Docx.numbering(document)
	items = Docx.body(document).keep_oks(
		|block|
			match block {
				Paragraph(paragraph) => {
					reference = Styles.effective_paragraph(styles, paragraph.properties, {}).numbering
					level = Numbering.level(numbering, styles, reference)?
					Ok({ depth: level.level, bullet: level.format == Bullet, text: Document.paragraph_text(paragraph) })
				}

				_ => Err(NotAListItem)
			},
	)
	# end::lists[]
	Ok(items)
}

cell_counts : Document -> Try(List(List(List(U64))), _)
cell_counts = |document| {
	tables = Docx.body(document).keep_oks(
		|block|
			match block {
				Table(table) => Ok(table)
				_ => Err(NotATable)
			},
	)
	grids = tables.map(
		|table| {
			# tag::tables[]
			grid = Document.table_rows(table).map(
				|row| Document.row_cells(row).map(|cell| cell.content.len()),
			)
			# end::tables[]
			grid
		},
	)
	Ok(grids)
}

any_landscape : Document -> Try(Bool, _)
any_landscape = |document| {
	# tag::sections[]
	landscape = Docx.sections(document).any(
		|section|
			match section.page_size {
				Size({ width: _, height: _, orientation }) => orientation == Landscape
				Unset => Bool.False
			},
	)
	# end::sections[]
	Ok(landscape)
}

footer_fields : Document -> Try(List(List(List(Document.Field))), _)
footer_fields = |document| {
	# tag::headers-footers[]
	page_numbers = Docx.sections(document).map(
		|section|
			section.footers.map(|footer| Document.fields(Docx.header_footer(document, footer.part))),
	)
	# end::headers-footers[]
	Ok(page_numbers)
}

# Read a document's comments

comment_summaries : List(U8) -> Try(List(Str), _)
comment_summaries = |bytes| {
	# tag::comments[]
	{ document, diagnostics: _ } = Docx.parse(bytes)?
	summaries = Docx.comments(document).comments.map(
		|entry|
			match entry.anchor {
				Range(text) => "${entry.comment.author} on: ${text}"
				Point => entry.comment.author
				Unanchored => entry.comment.author
			},
	)
	# end::comments[]
	Ok(summaries)
}

threads_of : Document -> Try({ open : List(Comments.Anchored), replies : List(Comments.Anchored) }, _)
threads_of = |document| {
	# tag::threads[]
	entries = Docx.comments(document).comments
	open_threads = entries.keep_if(
		|entry| entry.comment.parent == Unset and !entry.comment.resolved,
	)
	replies_to = |id| entries.keep_if(|entry| entry.comment.parent == Parent(id))
	# end::threads[]
	Ok({ open: open_threads, replies: replies_to(0) })
}

review : List(U8) -> Try(List(U8), _)
review = |bytes| {
	# tag::edit-comments[]
	{ document, diagnostics: _ } = Docx.parse(bytes)?
	text = Docx.text(document)
	{ before, after: _ } = text.split_first("thirty days") ? |_| NotFound
	start = before.to_utf8().len()
	added = Docx.add_comment(
		document,
		{ start, end: start + "thirty days".to_utf8().len() },
		{ author: "Morgan Reviewer", date: Date("2026-11-10T09:00:00Z"), content: Text("Our terms are fourteen days.") },
	)?
	replied = Docx.reply(added.document, added.id, { author: "Lin Editor", content: Text("Agreed.") })?
	resolved = Docx.resolve(replied.document, added.id)?
	written = Docx.to_bytes(resolved)?
	# end::edit-comments[]
	Ok(written)
}

# Read a document's tracked changes

review_texts : List(U8) -> Try({ before : Str, after : Str }, _)
review_texts = |bytes| {
	# tag::review-texts[]
	{ document, diagnostics: _ } = Docx.parse(bytes)?
	before = Docx.original_text(document)
	after = Docx.final_text(document)
	# end::review-texts[]
	Ok({ before, after })
}

change_summaries : Document -> Try(List(Str), _)
change_summaries = |document| {
	# tag::revisions[]
	summaries = Docx.revisions(document).map(
		|change|
			match (change.kind, change.of) {
				(Insertion, Content) => "${change.author} inserted ${change.text}"
				(Deletion, Content) => "${change.author} deleted ${change.text}"
				(Insertion, Row) => "${change.author} inserted a row"
				(Formatting, Run) => "${change.author} formatted ${change.text}"
				_ => "${change.author} changed the document"
			},
	)
	# end::revisions[]
	Ok(summaries)
}

settle_all : List(U8) -> Try({ accepted : Document, rejected : Document }, _)
settle_all = |bytes| {
	# tag::accept-all[]
	{ document, diagnostics: _ } = Docx.parse(bytes)?
	accepted = Docx.accept_all(document)?
	rejected = Docx.reject_all(document)?
	# end::accept-all[]
	Ok({ accepted, rejected })
}

settle_some : Document -> Try(Document, _)
settle_some = |document| {
	# tag::select[]
	settled = Docx.accept(document, By("Ada Reviewer"))?
	earlier = Docx.reject(settled, Between({ from: "2026-05-07T00:00:00Z", until: "2026-05-08T00:00:00Z" }))?
	first = Docx.accept(earlier, Ids([0]))?
	# end::select[]
	Ok(first)
}

replace_terms : Document -> Try(Document, _)
replace_terms = |document| {
	# tag::replace-text[]
	morgan = Tracked({ author: "Morgan Reviewer", date: Date("2026-11-10T10:00:00Z") })
	text = Docx.text(document)
	{ before, after: _ } = text.split_first("thirty days") ? |_| NotFound
	start = before.to_utf8().len()
	span = { start, end: start + "thirty days".to_utf8().len() }
	edited = Docx.replace_text(document, span, "fourteen days", morgan)?
	# end::replace-text[]
	Ok(edited)
}

across_lines : Document, U64, U64 -> Try({ joined : Document, split : Document }, _)
across_lines = |document, end_of_first, start_of_second| {
	morgan = Tracked({ author: "Morgan Reviewer", date: Date("2026-11-10T10:00:00Z") })
	# tag::across-lines[]
	joined = Docx.delete_text(document, { start: end_of_first, end: start_of_second }, morgan)?
	split = Docx.insert_text(document, end_of_first, " (as agreed)\nBoth parties confirm this amendment.", morgan)?
	# end::across-lines[]
	Ok({ joined, split })
}

block_edits : Document, U64, U64 -> Try(Document, _)
block_edits = |document, heading_start, heading_end| {
	morgan = Tracked({ author: "Morgan Reviewer", date: Date("2026-11-10T10:00:00Z") })
	# tag::block-edits[]
	clause = Build.paragraph({}, [Build.text("Either party may end this agreement.", {})])
	added = Docx.insert_blocks(document, Docx.text(document).to_utf8().len(), [clause], morgan)?
	removed = Docx.delete_blocks(added, { start: heading_start, end: heading_end }, morgan)?
	# end::block-edits[]
	Ok(removed)
}

inserted_run : Document.Inline -> Try(Document.Inline, _)
inserted_run = |run| {
	# tag::model-revision[]
	stamp = WmlRead.date_time("2026-05-07T09:00:00Z")?
	added = Revision({ kind: Insertion, author: "Ada", date: Date(stamp), content: [run], preserved: [] })
	# end::model-revision[]
	Ok(added)
}

tracking_said : Document -> Str
tracking_said = |document| {
	# tag::tracks[]
	said = if Docx.tracks_revisions(document) {
		"Edits to this document are tracked"
	} else {
		"Edits to this document are not tracked"
	}
	# end::tracks[]
	said
}

for_review : Document -> Try(Document, _)
for_review = |document| {
	# tag::set-tracking[]
	tracked = Docx.set_tracking(document, On)?
	# end::set-tracking[]
	Ok(tracked)
}

# Write a document

write_body : XmlTree.Node, List(Document.Block) -> Try(XmlTree.Node, _)
write_body = |shell, blocks| {
	# tag::write-body[]
	{ tree, relationships: _, next: _ } = WmlWrite.document(shell, blocks, { relationships: [], footnotes: [], endnotes: [], comments: [] })?
	# end::write-body[]
	Ok(tree)
}

written_with_options : Document -> Try(List(U8), _)
written_with_options = |document| {
	# tag::write-options[]
	bytes = Docx.to_bytes_with(document, { compression: Smallest, extension_parts: [ExtendedComments, People] })?
	# end::write-options[]
	Ok(bytes)
}

streamed_length : Document -> Try(U64, _)
streamed_length = |document| {
	# tag::write-chunks[]
	var $next = Docx.next_chunk(Docx.to_chunks(document, {})?)
	var $length = 0.U64
	var $writing = Bool.True
	while $writing {
		match $next {
			Emit(chunk, rest) => {
				# Send the chunk to a file or a socket; it is not needed again.
				$length = $length + chunk.len()
				$next = Docx.next_chunk(rest)
			}

			Done => {
				$writing = Bool.False
			}
		}
	}
	# end::write-chunks[]
	if (Ok($length) == Docx.to_bytes(document).map_ok(List.len)) Ok($length) else Err(NotTheBytesOfToBytes)
}

retitled : Document -> Try(Document, _)
retitled = |document| {
	# tag::set-properties[]
	described = Docx.set_properties(document, { title: Text("Lease"), last_modified_by: Text("Grace Author"), modified: Date("2026-11-10T09:00:00Z") })?
	# end::set-properties[]
	if (Docx.core_properties(described).title == Text("Lease")) Ok(described) else Err(NotSet)
}

# Generate a document

new_lease : {} -> Try(List(U8), _)
new_lease = |{}| {
	# tag::new-document[]
	document = Docx.new_document({ title: Text("Lease"), creator: Text("Ada Reviewer"), created: Date("2026-11-10T09:00:00Z") })?
	bytes = Docx.to_bytes(document)?
	# end::new-document[]
	Ok(bytes)
}

tenancy_notice : {} -> Try(List(U8), _)
tenancy_notice = |{}| {
	# tag::build[]
	created = Docx.new_document({ title: Text("Tenancy notice"), creator: Text("Ada Reviewer") })?
	noted = Build.footnote(created, [Build.text("As agreed on signing.", {})])?
	cell = |text, options| Build.cell(options, [Build.paragraph({}, [Build.text(text, {})])])
	document = Build.append(
		noted.document,
		[
			Build.paragraph({ style: Heading(1) }, [Build.text("Tenancy notice", {})]),
			Build.paragraph({}, [Build.text("The rent is ", {}), Build.text("due monthly", { bold: On }), noted.reference, Build.text(". See ", {}), Build.link("https://example.org/tenancy", [Build.text("the terms", {})]), Build.text(".", {})]),
			Build.list_item({}, [Build.text("Rent", {})]),
			Build.list_item({ list: Numbered, level: 1 }, [Build.text("Give notice", {})]),
			Build.table({ widths: [3000, 6026], header_rows: 1 }, [[cell("Item", {}), cell("Due", {})], [cell("Rent", {}), cell("Monthly", {})]]),
		],
	)
	bytes = Docx.to_bytes(document)?
	# end::build[]
	Ok(bytes)
}

footer_added : Document -> Try(Document, _)
footer_added = |document| {
	# tag::footer[]
	footed = Build.footer(document, {}, [Build.paragraph({ alignment: Center }, [Build.text("Page ", {}), Build.page_number, Build.text(" of ", {}), Build.page_count])])?
	# end::footer[]
	Ok(footed)
}

pages_headed : Document -> Try(Document, _)
pages_headed = |document| {
	# tag::odd-even-first[]
	title = Build.paragraph({}, [Build.text("Staff handbook", {})])
	odd = Build.header(document, {}, [title])?
	even = Build.header(odd, { kind: Even }, [Build.paragraph({}, [Build.text("Harbour Lane Bakery", {})])])?
	headed = Build.header(even, { kind: First }, [])?
	# end::odd-even-first[]
	if Docx.different_odd_and_even(headed) {
		Ok(headed)
	} else {
		Err(NotOddAndEven)
	}
}

annexed : Document -> Document
annexed = |document| {
	# tag::section[]
	annex = Build.append(Build.new_section(document, { orientation: Landscape }), [Build.paragraph({ style: Heading(1) }, [Build.text("Schedule", {})])])
	# end::section[]
	annex
}

styles_tree : { paragraph : Document.ParagraphProperties, run : Document.RunProperties }, List(Styles.Style) -> XmlTree.Node
styles_tree = |defaults, styles| {
	# tag::styles-writer[]
	tree = WmlWrite.styles({ defaults, styles })
	# end::styles-writer[]
	tree
}
