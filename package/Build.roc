## Build a document's content: paragraphs, text, lists, tables, links,
## footnotes, headers and footers, sections and properties.
##
## The constructors give model values, [Document.Block], [Document.Inline]
## and [Document.Cell], each from its content and a props record of options
## that all have defaults, so `{}` asks for none:
##
## ```
## title = Build.paragraph({ style: Heading(1) }, [Build.text("Lease", {})])
## clause = Build.paragraph({}, [Build.text("The rent is ", {}), Build.text("due monthly", { bold: On }), Build.text(".", {})])
## ```
##
## The document functions add what lives beside the body: [Build.append]
## adds blocks to the body, [Build.footnote] a footnote, [Build.header] and
## [Build.footer] the final section's header and footer, [Build.page_setup]
## and [Build.new_section] its page, and [Build.properties] the document's
## properties. Each part a document needs for them, such as the footnotes or
## a footer, is added with its relationship and content type where the
## document has none. Nothing is written as XML text: the body, its notes,
## headers and footers are written from the model by [WmlWrite], which
## allocates every identifier and relationship they need.
import Document
import Docx
import Opc
import WmlRead
import WmlWrite
import XmlTree

Build :: [].{

	## How a paragraph is set: its style, the normal paragraph's or a
	## heading's of level 1 to 6 (a level beyond 6 is 6, and 0 is 1) or a
	## style by its identifier; how its lines are aligned, the document's
	## default where `Unset`, `Justified` filling each line but the last; and
	## whether it starts on a new page.
	Paragraph := {
		style : [Normal, Heading(U8), Style(Str)] ?? Normal,
		alignment : [Unset, Left, Center, Right, Justified] ?? Unset,
		page_break_before : Document.OnOff ?? Unset,
	}

	## How text is set: its character style by its identifier; bold, italic,
	## single underline and strikethrough, each `On`, `Off` against what a
	## style sets, or `Unset`; superscript or subscript; its size in
	## half-points (22 is 11 points); its colour as red, green and blue; and
	## its font by name. What is `Unset` comes from the paragraph's style and
	## the document's defaults.
	Text := {
		style : [Unset, Style(Str)] ?? Unset,
		bold : Document.OnOff ?? Unset,
		italic : Document.OnOff ?? Unset,
		underline : Document.OnOff ?? Unset,
		strike : Document.OnOff ?? Unset,
		vertical_align : [Unset, Baseline, Superscript, Subscript] ?? Unset,
		size : [Unset, HalfPoints(U32)] ?? Unset,
		color : [Unset, Rgb({ red : U8, green : U8, blue : U8 })] ?? Unset,
		font : [Unset, Named(Str)] ?? Unset,
	}

	## Which of the default document kit's lists an item is in, the
	## bulleted or the numbered, and its level, from 0 for the first; a
	## level beyond 8, the ninth, is 8.
	ListItem := {
		list : [Bulleted, Numbered] ?? Bulleted,
		level : U8 ?? 0,
	}

	## How a table is set: the width of each column of its grid in twips,
	## and how many of its first rows are header rows, repeated at the top of
	## each page the table runs onto. Without widths, the columns share
	## 9,026 twips, the width of an A4 page between one-inch margins, as
	## many as the widest row spans.
	Table := {
		widths : List(U64) ?? [],
		header_rows : U64 ?? 0,
	}

	## How a cell is set: how many grid columns it spans, and whether it
	## starts a vertical merge with the cells below it or continues the one
	## from the cell above, whose content the merged cell shows.
	Cell := {
		span : U64 ?? 1,
		merge : [Unset, Restart, Continue] ?? Unset,
	}

	## A section's page: its paper, A4, US Letter, US Legal or a size in
	## twips as it is held upright; its orientation, the longer edge
	## across for `Landscape`; its margins in twips from each edge to the
	## body, and from the top and bottom edges to the header and footer; and
	## where the section starts. The defaults are the default document kit's
	## page: A4 portrait with one-inch margins, the header and footer half an
	## inch from the edge, starting on a new page.
	PageSetup := {
		size : [A4, Letter, Legal, Size({ width : U64, height : U64 })] ?? A4,
		orientation : [Portrait, Landscape] ?? Portrait,
		top : U64 ?? 1440,
		right : U64 ?? 1440,
		bottom : U64 ?? 1440,
		left : U64 ?? 1440,
		header : U64 ?? 708,
		footer : U64 ?? 708,
		start : [NextPage, Continuous, EvenPage, OddPage] ?? NextPage,
	}

	## Which pages of a section a header or footer is for, as
	## [Document.HeaderFooter] names them: `Default`, every page the others
	## do not take; `Even`, the even pages, which gives the whole document
	## different headers and footers for odd and even pages, so that the
	## `Default` ones are for the odd pages; or `First`, the section's first
	## page, which gives the section a title page.
	HeaderFooter := {
		kind : [Default, Even, First] ?? Default,
	}

	## Why a document cannot be given a footnote, header or footer: it has
	## no main document part, or the content cannot be written, as
	## [WmlWrite.WriteError] says.
	Error : [NoMainDocument, MissingNote({ kind : Document.NoteKind, note : U64 }), MissingComment(U64), CommentWithoutParagraph(U64)]

	## A paragraph of `content`, set as `options` says.
	paragraph : Paragraph, List(Document.Inline) -> Document.Block
	paragraph = |options, content| {
		style = match options.style {
			Normal => Unset
			Heading(level) => Style("Heading${level.max(1).min(6).to_str()}")
			Style(id) => Style(id)
		}
		alignment = match options.alignment {
			Unset => Unset
			Left => Aligned(Left)
			Center => Aligned(Center)
			Right => Aligned(Right)
			Justified => Aligned(Both)
		}
		Paragraph({ properties: { ..Document.no_paragraph_properties, style, alignment, page_break_before: options.page_break_before }, content })
	}

	## A run of `value`, set as `options` says; a tab in it is a tab, and a
	## line feed a line break.
	text : Str, Text -> Document.Inline
	text = |value, options| {
		color = match options.color {
			Unset => Unset
			Rgb({ red, green, blue }) => Color({ value: Rgb(Str.join_with([red, green, blue].map(hex2), "")), theme: Unset, tint: Unset, shade: Unset })
		}
		underline = match options.underline {
			Unset => Unset
			On => Underline(Single)
			Off => Underline(NoUnderline)
		}
		fonts = match options.font {
			Unset => Document.no_run_properties.fonts
			Named(name) => { ..Document.no_run_properties.fonts, ascii: Named(name), high_ansi: Named(name), east_asia: Named(name), complex: Named(name) }
		}
		properties = {
			..Document.no_run_properties,
			style: options.style,
			bold: options.bold,
			italic: options.italic,
			underline,
			strike: options.strike,
			vertical_align: options.vertical_align,
			size: options.size,
			color,
			fonts,
		}
		Run({ properties, content: run_content(value) })
	}

	## An item of a list, a paragraph of `content` in the List Paragraph
	## style numbered by the default document kit's bulleted list, numbering
	## instance 1, or its numbered list, instance 2, at the level `options`
	## gives.
	list_item : ListItem, List(Document.Inline) -> Document.Block
	list_item = |options, content| {
		instance = match options.list {
			Bulleted => 1
			Numbered => 2
		}
		numbering = { instance: Instance(instance), level: Level(options.level.min(8)) }
		Paragraph({ properties: { ..Document.no_paragraph_properties, style: Style("ListParagraph"), numbering }, content })
	}

	## A link to the address `url` around `content`, whose runs without a
	## character style of their own take the Hyperlink style. The
	## relationship that names the address is added when the document is
	## written.
	link : Str, List(Document.Inline) -> Document.Inline
	link = |url, content| {
		styled = content.map(
			|inline|
				match inline {
					Run(run) if run.properties.style == Unset => Run({ properties: { ..run.properties, style: Style("Hyperlink") }, content: run.content })
					other => other
				},
		)
		Hyperlink({ target: External(url), preserved: [], content: styled })
	}

	## A field showing the number of the page it is on, as a header or
	## footer shows it; Word and LibreOffice calculate it as they lay the
	## document out, and until then it shows 1.
	page_number : Document.Inline
	page_number = field(" PAGE ")

	## A field showing how many pages the document has, calculated as
	## [Build.page_number] is.
	page_count : Document.Inline
	page_count = field(" NUMPAGES ")

	## A cell holding `content`, set as `options` says. A cell ends with a
	## paragraph, so an empty one, or one whose content ends with a table, is
	## given an empty paragraph at its end. Its width is its columns' in the
	## table [Build.table] makes of it.
	cell : Cell, List(Document.Block) -> Document.Cell
	cell = |options, content| {
		ended = match content.last() {
			Ok(Paragraph(_)) => content
			_ => List.append(content, empty_paragraph)
		}
		span = if (options.span > 1) Columns(options.span) else Unset
		{ properties: { width: Unset, span, merge: options.merge, borders: [], shading: Unset, alignment: Unset, preserved: [], revision: Unset, change: [] }, content: ended }
	}

	## A table in the Table Grid style, a thin line around every cell, of
	## `rows` of cells in order, set as `options` says. Each cell is as wide
	## as the grid columns it spans.
	table : Table, List(List(Document.Cell)) -> Document.Block
	table = |options, rows| {
		spanned = |row| row.fold(0, |sum, one| sum + spans(one))
		widths = if options.widths.is_empty() {
			count = rows.fold(1, |widest, row| widest.max(spanned(row)))
			List.repeat(9026 // count, count)
		} else {
			options.widths
		}
		var $content = List.with_capacity(rows.len())
		var $index = 0.U64
		for row in rows {
			var $cells = List.with_capacity(row.len())
			var $column = 0.U64
			for one in row {
				width = widths.sublist({ start: $column, len: spans(one) }).fold(0.U64, |sum, each| sum + each)
				$cells = List.append($cells, Cell({ properties: { ..one.properties, width: Twips(width.to_i64_wrap()) }, content: one.content }))
				$column = $column + spans(one)
			}
			header = if ($index < options.header_rows) On else Unset
			properties = { header, grid_before: Unset, grid_after: Unset, preserved: [], inserted: Unset, deleted: Unset, change: [] }
			$content = List.append($content, Row({ properties, content: $cells }))
			$index = $index + 1
		}
		Table({ properties: { style: Style("TableGrid"), width: Auto, borders: [], shading: Unset, preserved: [], change: [] }, grid: widths.map(|width| Column(width)), content: $content })
	}

	## The document with `blocks` at the end of its body, before the end of
	## its final section. A document whose body is the one empty paragraph a
	## new document has, as [Docx.new_document] makes it, loses it to the
	## first blocks appended. The body is extended in place when nothing else
	## holds the document, so appending a block at a time costs what the
	## blocks cost.
	append : Document, List(Document.Block) -> Document
	append = |document, blocks|
		body_changed(
			document,
			|body| {
				{ content, final } = split_final(body)
				kept = if (!blocks.is_empty() and content.len() == 1 and content.first() == Ok(empty_paragraph)) [] else content
				List.append(List.concat(kept, blocks), Section(final))
			},
		)

	## The document with a footnote of `content` after its footnotes, and a
	## reference to it to place in a paragraph: a run in the footnote
	## reference style that shows the note's number. The note is a
	## paragraph in the footnote text style that starts with its number and
	## a space. A document without footnotes is given a footnotes part, with
	## the separator lines Word and LibreOffice draw above notes. The
	## footnotes are kept as the model from the first footnote added, as
	## [Document.with_notes] keeps them, and added to in place when nothing
	## else holds the document, so adding a footnote costs what the note
	## costs; the note is written into the part, with its identifier and any
	## relationship it needs, when the document is written.
	footnote : Document, List(Document.Inline) -> Try({ document : Document, reference : Document.Inline }, Error)
	footnote = |document, content| {
		main = main_name(document)?
		has_notes = Document.related(document, main, footnotes_relationship).is_ok()
		with_part = if (has_notes) document else Document.with_new_part(document, { source: main, kind: footnotes_relationship, name: free_name(document, "footnotes", One), content_type: wordprocessingml_type("footnotes") }, footnotes_shell)
		part = Document.related(with_part, main, footnotes_relationship) ? |_| NoMainDocument
		mark = Run({ properties: { ..Document.no_run_properties, style: Style("FootnoteReference") }, content: [NoteMark(Footnote)] })
		note = { kind: Note, content: [Paragraph({ properties: { ..Document.no_paragraph_properties, style: Style("FootnoteText") }, content: List.concat([mark, Build.text(" ", {})], content) })] }
		_ = WmlWrite.notes(w("footnotes", [], []), [note], part_context(with_part, main, part.relationships))?
		held = match Document.notes(with_part, part.name) {
			Ok(_) => with_part
			Err(Whole) => Document.with_notes(with_part, part.name, Docx.footnotes(with_part))
		}
		place = Document.notes(held, part.name).map_ok(|notes| notes.len()) ?? 0
		Ok({ document: Document.map_notes(held, part.name, |notes| List.append(notes, note)), reference: reference_to(place) })
	}

	## The document with `content` as the header of the pages of its final
	## section that `options` names, every page with `{}`, written into the
	## header part the section has for them or a new one. An even pages'
	## header turns on different odd and even pages, as
	## [Docx.set_different_odd_and_even] does, and a first page's turns on
	## the section's title page. A header ends with a paragraph, as Word
	## writes one, so an empty one is given an empty paragraph. A section
	## after it without a header of its own for the same pages has this one,
	## as Word and LibreOffice lay it out.
	header : Document, HeaderFooter, List(Document.Block) -> Try(Document, Error)
	header = |document, options, content| region(document, content, Header, options.kind)

	## The document with `content` as the footer of the pages of its final
	## section that `options` names, as [Build.header] gives it a header.
	footer : Document, HeaderFooter, List(Document.Block) -> Try(Document, Error)
	footer = |document, options, content| region(document, content, Footer, options.kind)

	## The document with its final section's page set as `setup` says; the
	## section keeps its headers, footers and everything else it states.
	page_setup : Document, PageSetup -> Document
	page_setup = |document, setup|
		body_changed(
			document,
			|body| {
				{ content, final } = split_final(body)
				List.append(content, Section(with_setup(final, setup)))
			},
		)

	## The document with its final section ended where its body ends, keeping
	## its page, headers and footers, and a new final section after it whose
	## page is set as `setup` says. The new section states no header or
	## footer of its own, so it has the section's before it until
	## [Build.header] or [Build.footer] gives it its own. A section ends with
	## a paragraph's mark, so a body that does not end with a paragraph is
	## given an empty one.
	new_section : Document, PageSetup -> Document
	new_section = |document, setup|
		body_changed(
			document,
			|body| {
				{ content, final } = split_final(body)
				ended = match content.last() {
					Ok(Paragraph(_)) => content
					_ => List.append(content, empty_paragraph)
				}
				next = { ..with_setup(final, setup), columns: final.columns, page_numbers: Unset, title_page: Unset, headers: [], footers: [], change: [] }
				List.append(List.append(ended, Section(final)), Section(next))
			},
		)

	## The document with its core properties as `properties` gives them over
	## those it has, as [Docx.set_properties] sets them; a date that is not in
	## the W3C date and time format is refused with `NotADate` and the date as
	## given.
	properties : Document, Docx.Properties -> Try(Document, [NotADate(Str)])
	properties = |document, given| Docx.set_properties(document, given)
}

# The main document part's name. Only the name is kept, so that adding a
# relationship to the part does not copy the relationships it has.
main_name : Document -> Try(Str, [NoMainDocument])
main_name = |document|
	match Document.related(document, "/", Opc.officedocument_relationship) {
		Ok(part) => Ok(part.name)
		Err(NotFound) => Err(NoMainDocument)
	}

# What writing a notes, header or footer part needs: its relationships and
# the comments' identifiers, which a range or reference in it names.
part_context : Document, Str, List(Opc.Relationship) -> WmlWrite.Context
part_context = |document, main, relationships| {
	comments = match Document.related(document, main, comments_relationship) {
		Ok(part) => WmlRead.comment_ids(part.tree)
		Err(NotFound) => []
	}
	{ relationships, footnotes: [], endnotes: [], comments }
}

# The document with its body as `change` makes it, in place when nothing
# else holds the document; a body its main document part's tree holds is
# read first.
body_changed : Document, (List(Document.Block) -> List(Document.Block)) -> Document
body_changed = |document, change| {
	held = match Document.body(document) {
		Ok(_) => document
		Err(Whole) => Document.with_body(document, Docx.body(document))
	}
	Document.map_body(held, change)
}

# A body's content and its final section, the last block where it is a
# section, or a section that states nothing.
split_final : List(Document.Block) -> { content : List(Document.Block), final : Document.Section }
split_final = |blocks|
	match blocks.last() {
		Ok(Section(final)) => { content: blocks.drop_last(1), final }
		_ => { content: blocks, final: no_section }
	}

# A body's final section, as [split_final] finds it, read without taking
# the body apart.
final_of : List(Document.Block) -> Document.Section
final_of = |blocks|
	match blocks.last() {
		Ok(Section(final)) => final
		_ => no_section
	}

no_section : Document.Section
no_section = { start: Unset, page_size: Unset, margins: Unset, columns: Unset, page_numbers: Unset, title_page: Unset, headers: [], footers: [], preserved: [], change: [] }

# A section with its page and start as `setup` says.
with_setup : Document.Section, Build.PageSetup -> Document.Section
with_setup = |section, setup| {
	(short, long) = match setup.size {
		A4 => (11906, 16838)
		Letter => (12240, 15840)
		Legal => (12240, 20160)
		Size({ width, height }) => (width.min(height), width.max(height))
	}
	page_size = match setup.orientation {
		Portrait => Size({ width: short, height: long, orientation: Portrait })
		Landscape => Size({ width: long, height: short, orientation: Landscape })
	}
	margins = Margins({ top: setup.top.to_i64_wrap(), right: setup.right, bottom: setup.bottom.to_i64_wrap(), left: setup.left, header: setup.header, footer: setup.footer, gutter: 0 })
	start = match setup.start {
		NextPage => NextPage
		Continuous => Continuous
		EvenPage => EvenPage
		OddPage => OddPage
	}
	{ ..section, start, page_size, margins }
}

# The document with `content` as its final section's header or footer for
# the pages `pages` names; even pages turn on different odd and even pages,
# and a first page the section's title page.
region : Document, List(Document.Block), [Header, Footer], [Default, Even, First] -> Try(Document, Build.Error)
region = |document, content, which, pages| {
	main = main_name(document)?
	(kind, local, root) = match which {
		Header => (header_relationship, "header", "hdr")
		Footer => (footer_relationship, "footer", "ftr")
	}
	final = final_of(Docx.body(document))
	listed = match which {
		Header => final.headers
		Footer => final.footers
	}
	existing = match listed.find_first(|reference| reference.kind == pages) {
		Ok(reference) if Document.xml_part(document, reference.part).is_ok() => Ok(reference.part)
		_ => Err(NotFound)
	}
	(with_part, name) = match existing {
		Ok(found) => (document, found)
		Err(NotFound) => {
			added = free_name(document, local, Many)
			(Document.with_new_part(document, { source: main, kind, name: added, content_type: wordprocessingml_type(local) }, w(root, [], [])), added)
		}
	}
	part = Document.xml_part(with_part, name) ? |_| NoMainDocument
	ended = match content.last() {
		Ok(Paragraph(_)) => content
		_ => List.append(content, empty_paragraph)
	}
	written = WmlWrite.header_footer(w(root, [], []), ended, part_context(with_part, main, part.relationships))?
	referenced = List.append(listed.drop_if(|reference| reference.kind == pages), { kind: pages, part: name })
	referring = |body| {
		{ content: blocks, final: last } = split_final(body)
		titled = if (pages == First) { ..last, title_page: On } else last
		section = match which {
			Header => { ..titled, headers: referenced }
			Footer => { ..titled, footers: referenced }
		}
		List.append(blocks, Section(section))
	}
	with_region = body_changed(Document.with_part(with_part, name, written.tree, written.relationships), referring)
	if pages == Even {
		Ok(Docx.set_different_odd_and_even(with_region, On) ? |_| NoMainDocument)
	} else {
		Ok(with_region)
	}
}

# The name of a new part beside the main document, as Word names its parts:
# `word/<local>N.xml` with the lowest number from 1 that no part has for a
# part a document may have many of, `word/<local>.xml` for one it has one
# of, a number from 2 after it when the document has a part by that name.
free_name : Document, Str, [One, Many] -> Str
free_name = |document, local, how_many| {
	name = |number| if (number == 1 and how_many == One) "/word/${local}.xml" else "/word/${local}${number.to_str()}.xml"
	var $number = 1.U64
	while Document.has_part(document, name($number)) {
		$number = $number + 1
	}
	name($number)
}

# A reference to the footnote at `place` among a document's footnotes.
reference_to : U64 -> Document.Inline
reference_to = |place| Run({ properties: { ..Document.no_run_properties, style: Style("FootnoteReference") }, content: [NoteReference({ kind: Footnote, note: place })] })

# A run's content: the text between tabs and line feeds, a tab for each tab
# and a line break for each line feed.
run_content : Str -> List(Document.RunContent)
run_content = |value| {
	var $content = List.with_capacity(1)
	var $line = 0.U64
	for piece in value.split_on("\n") {
		if $line > 0 {
			$content = List.append($content, Break({ kind: Line, clear: NoClear }))
		}
		var $tab = 0.U64
		for part in piece.split_on("\t") {
			if $tab > 0 {
				$content = List.append($content, Tab)
			}
			if part != "" {
				$content = List.append($content, Text(part))
			}
			$tab = $tab + 1
		}
		$line = $line + 1
	}
	$content
}

# A simple field of `code` whose result, until it is calculated, is 1.
field : Str -> Document.Inline
field = |code| SimpleField({ code, preserved: [], content: [Run({ properties: Document.no_run_properties, content: [Text("1")] })] })

# A cell's span in grid columns.
spans : Document.Cell -> U64
spans = |one|
	match one.properties.span {
		Columns(count) if count > 0 => count
		_ => 1
	}

empty_paragraph : Document.Block
empty_paragraph = Paragraph({ properties: Document.no_paragraph_properties, content: [] })

# A byte as two hexadecimal digits.
hex2 : U8 -> Str
hex2 = |byte| {
	digits = "0123456789ABCDEF".to_utf8()
	Str.from_utf8([digits.get((byte // 16).to_u64()) ?? '0', digits.get((byte % 16).to_u64()) ?? '0']) ?? "00"
}

# A footnotes part holding the line above notes and the longer line above
# notes continued from the page before, as Word writes them, with the
# identifiers -1 and 0 Word gives them.
footnotes_shell : XmlTree.Node
footnotes_shell = {
	separator = |kind, id, mark| w("footnote", [attribute("type", kind), attribute("id", id)], [w("p", [], [w("pPr", [], [w("spacing", [attribute("after", "0"), attribute("line", "240"), attribute("lineRule", "auto")], [])]), w("r", [], [w(mark, [], [])])])])
	w("footnotes", [], [separator("separator", "-1", "separator"), separator("continuationSeparator", "0", "continuationSeparator")])
}

wordprocessingml_type : Str -> Str
wordprocessingml_type = |kind| "application/vnd.openxmlformats-officedocument.wordprocessingml.${kind}+xml"

footnotes_relationship : Str
footnotes_relationship = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/footnotes"

header_relationship : Str
header_relationship = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/header"

footer_relationship : Str
footer_relationship = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer"

comments_relationship : Str
comments_relationship = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/comments"

wordprocessingml : Str
wordprocessingml = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

w : Str, List(XmlTree.Attribute), List(XmlTree.Node) -> XmlTree.Node
w = |local, attributes, children| Element({ name: { namespace: Uri(wordprocessingml), local, prefix: Prefix("w") }, bindings: [], attributes, children })

attribute : Str, Str -> XmlTree.Attribute
attribute = |local, text| { name: { namespace: Uri(wordprocessingml), local, prefix: Prefix("w") }, value: text }

# A document written and read back.
round_trip : Document -> Try(Document, [Unwritable, Unreadable])
round_trip = |document| {
	bytes = Docx.to_bytes(document) ? |_| Unwritable
	Ok((Docx.parse(bytes) ? |_| Unreadable).document)
}

# A new document from the default document kit with `blocks` appended,
# written and read back.
built : List(Document.Block) -> Try(Document, [Unwritable, Unreadable, NotADate(Str)])
built = |blocks| round_trip(Build.append(Docx.new_document({})?, blocks))

## A paragraph is set as its options say: a heading's style, alignment and a
## page break before it, each run's formatting, tabs and line breaks; and it
## reads back as built.
expect {
	heading = Build.paragraph({ style: Heading(2), alignment: Justified, page_break_before: On }, [Build.text("Title\tone\ntwo", { bold: On, italic: Off, underline: On, size: HalfPoints(28), color: Rgb({ red: 255, green: 16, blue: 0 }), font: Named("Arial") })])
	expected_run : Document.RunProperties
	expected_run = { ..Document.no_run_properties, bold: On, italic: Off, underline: Underline(Single), size: HalfPoints(28), color: Color({ value: Rgb("FF1000"), theme: Unset, tint: Unset, shade: Unset }), fonts: { ..Document.no_run_properties.fonts, ascii: Named("Arial"), high_ansi: Named("Arial"), east_asia: Named("Arial"), complex: Named("Arial") } }
	expected : Document.Block
	expected = Paragraph({ properties: { ..Document.no_paragraph_properties, style: Style("Heading2"), alignment: Aligned(Both), page_break_before: On }, content: [Run({ properties: expected_run, content: [Text("Title"), Tab, Text("one"), Break({ kind: Line, clear: NoClear }), Text("two")] })] })
	read = built([heading, Build.paragraph({ style: Heading(9) }, [])])
	heading == expected and match read {
		Ok(document) => Docx.body(document).take_first(2) == [expected, Paragraph({ properties: { ..Document.no_paragraph_properties, style: Style("Heading6") }, content: [] })]
		Err(_) => Bool.False
	}
}

## Appending to a new document replaces its one empty paragraph and keeps
## the final section's end last; appending again adds after the blocks.
expect {
	one = Build.paragraph({}, [Build.text("One", {})])
	two = Build.paragraph({}, [Build.text("Two", {})])
	match Docx.new_document({}) {
		Ok(created) => {
			body = Docx.body(Build.append(Build.append(created, [one]), [two]))
			body.take_first(2) == [one, two] and body.len() == 3 and Document.sections(body).len() == 1
		}

		Err(_) => Bool.False
	}
}

## A list item is a List Paragraph numbered by the kit's bulleted or
## numbered list at its level, a level beyond the ninth being the ninth.
expect {
	items = [Build.list_item({}, [Build.text("a", {})]), Build.list_item({ list: Numbered, level: 1 }, []), Build.list_item({ level: 12 }, [])]
	numbering = |block|
		match block {
			Paragraph(paragraph) if paragraph.properties.style == Style("ListParagraph") => Ok(paragraph.properties.numbering)
			_ => Err(NotAnItem)
		}
	match built(items) {
		Ok(document) => Docx.body(document).take_first(3).map(numbering) == [Ok({ instance: Instance(1), level: Level(0) }), Ok({ instance: Instance(2), level: Level(1) }), Ok({ instance: Instance(1), level: Level(8) })]
		Err(_) => Bool.False
	}
}

## A table has the Table Grid style, its grid's widths, its header rows,
## each cell as wide as the columns it spans, merges as given, and a
## paragraph ending every cell; without widths the columns share an A4
## page's text width.
expect {
	rows = [
		[Build.cell({ span: 2 }, [Build.paragraph({}, [Build.text("Head", {})])])],
		[Build.cell({ merge: Restart }, []), Build.cell({}, [])],
		[Build.cell({ merge: Continue }, []), Build.cell({}, [])],
	]
	shape = |block|
		match block {
			Table(table) => {
				cells = Document.table_rows(table).map(|row| Document.row_cells(row).map(|one| (one.properties.width, one.properties.span, one.properties.merge, one.content.len())))
				Ok((table.properties.style, table.grid, Document.table_rows(table).map(|row| row.properties.header), cells))
			}

			_ => Err(NotATable)
		}
	match (built([Build.table({ widths: [3000, 6000], header_rows: 1 }, rows)]), built([Build.table({}, [[Build.cell({}, []), Build.cell({}, []), Build.cell({}, [])]])])) {
		(Ok(document), Ok(even)) => {
			expected = Ok((Style("TableGrid"), [Column(3000), Column(6000)], [On, Unset, Unset], [[(Twips(9000), Columns(2), Unset, 1)], [(Twips(3000), Unset, Restart, 1), (Twips(6000), Unset, Unset, 1)], [(Twips(3000), Unset, Continue, 1), (Twips(6000), Unset, Unset, 1)]]))
			match (Docx.body(document).first(), Docx.body(even).first()) {
				(Ok(first), Ok(Table(evenly))) => shape(first) == expected and evenly.grid == [Column(3008), Column(3008), Column(3008)]
				_ => Bool.False
			}
		}

		_ => Bool.False
	}
}

## A link leads to its address through a relationship the writer adds, and
## its unstyled runs take the Hyperlink style.
expect {
	linked = Build.paragraph({}, [Build.link("https://example.org/lease", [Build.text("the lease", {}), Build.text("!", { style: Style("Strong") })])])
	match built([linked]) {
		Ok(document) =>
			match Docx.body(document).first() {
				Ok(Paragraph(paragraph)) =>
					match paragraph.content {
						[Hyperlink(found)] => {
							styles = found.content.map(
								|inline|
									match inline {
										Run(run) => run.properties.style
										_ => Unset
									},
							)
							found.target == External("https://example.org/lease") and styles == [Style("Hyperlink"), Style("Strong")]
						}

						_ => Bool.False
					}

				_ => Bool.False
			}

		Err(_) => Bool.False
	}
}

## Footnotes are added after the separators of a new footnotes part, each
## reference naming its note, and read back with their text.
expect {
	match footnoted({}) {
		Ok(read) => {
			notes = Docx.footnotes(read)
			texts = notes.drop_first(2).map(|note| Str.join_with(note.content.map(block_text), ""))
			references = match Docx.body(read).first() {
				Ok(Paragraph(paragraph)) => paragraph.content.keep_oks(note_reference)
				_ => []
			}
			notes.map(|note| note.kind) == [Separator, ContinuationSeparator, Note, Note] and texts == [" First source.", " Second source."] and references == [{ kind: Footnote, note: 2 }, { kind: Footnote, note: 3 }]
		}

		Err(_) => Bool.False
	}
}

## Footnotes added one by one, one of them holding a bookmark, are written
## with the lowest identifiers after the separators' and read back in place
## with their text and the bookmark.
expect {
	built_notes = |{}| {
		created = Docx.new_document({}) ? |_| Unbuilt
		first = Build.footnote(created, [Build.text("Plain.", {})]) ? |_| Unbuilt
		second = Build.footnote(first.document, [BookmarkStart("cited"), Build.text("Marked.", {}), BookmarkEnd("cited")]) ? |_| Unbuilt
		third = Build.footnote(second.document, [Build.text("Last.", {})]) ? |_| Unbuilt
		body = Build.append(third.document, [Build.paragraph({}, [first.reference, second.reference, third.reference])])
		read = round_trip(body) ? |_| Unbuilt
		ids = match Document.related(read, "/word/document.xml", footnotes_relationship) {
			Ok(part) => WmlRead.note_ids(part.tree)
			Err(NotFound) => []
		}
		Ok({ ids, read })
	}
	match built_notes({}) {
		Ok({ ids, read }) => {
			notes = Docx.footnotes(read).drop_first(2)
			marked = match notes.get(1) {
				Ok(note) => note.content.any(
					|block| match block {
						Paragraph(paragraph) => paragraph.content.contains(BookmarkStart("cited"))
						_ => Bool.False
					},
				)
				Err(_) => Bool.False
			}
			ids == ["-1", "0", "1", "2", "3"] and notes.map(|note| Str.join_with(note.content.map(block_text), "")) == [" Plain.", " Marked.", " Last."] and marked
		}

		Err(_) => Bool.False
	}
}

## The final section takes its page from the setup: Letter landscape with
## its margins; a new section ends the one before with the page it had.
expect {
	match sectioned({}) {
		Ok(read) => {
			geometry = Docx.sections(read).map(|section| (section.start, section.page_size, section.margins))
			geometry == [
				(NextPage, Size({ width: 15840, height: 12240, orientation: Landscape }), Margins({ top: 720, right: 1440, bottom: 1440, left: 1080, header: 708, footer: 708, gutter: 0 })),
				(Continuous, Size({ width: 11906, height: 16838, orientation: Portrait }), Margins({ top: 1440, right: 1440, bottom: 1440, left: 1440, header: 708, footer: 708, gutter: 0 })),
			]
		}

		Err(_) => Bool.False
	}
}

## A header and a footer with page number fields are new parts the final
## section names; giving the footer again rewrites its part; a new section
## names none of its own until it is given one.
expect {
	match headed({}) {
		Ok(read) => {
			parts = Docx.sections(read).map(|section| (section.headers, section.footers))
			parts == [([{ kind: Default, part: "/word/header1.xml" }], [{ kind: Default, part: "/word/footer1.xml" }]), ([], [{ kind: Default, part: "/word/footer2.xml" }])]
				and Document.fields(Docx.header_footer(read, "/word/footer1.xml")) == [{ code: " PAGE ", result: "1" }, { code: " NUMPAGES ", result: "1" }]
		}

		Err(_) => Bool.False
	}
}

## An even pages' header and footer are new parts the final section names
## as `Even` beside its default ones, and they turn on different odd and
## even pages, which headers for every page leave off.
expect {
	match paged(Even) {
		Ok({ before, read }) => {
			parts = Docx.sections(read).map(|section| (section.headers, section.footers, section.title_page))
			parts == [([{ kind: Default, part: "/word/header1.xml" }, { kind: Even, part: "/word/header2.xml" }], [{ kind: Even, part: "/word/footer1.xml" }], Unset)]
				and !Docx.different_odd_and_even(before)
				and Docx.different_odd_and_even(read)
				and Docx.header_footer(read, "/word/header2.xml").map(block_text) == ["Even"]
		}

		Err(_) => Bool.False
	}
}

## A first page's header and footer are new parts the final section names
## as `First`, and they give the section a title page but leave odd and
## even pages alike.
expect {
	match paged(First) {
		Ok({ before: _, read }) => {
			parts = Docx.sections(read).map(|section| (section.headers, section.footers, section.title_page))
			parts == [([{ kind: Default, part: "/word/header1.xml" }, { kind: First, part: "/word/header2.xml" }], [{ kind: First, part: "/word/footer1.xml" }], On)]
				and !Docx.different_odd_and_even(read)
				and Docx.header_footer(read, "/word/footer1.xml").map(block_text) == ["First"]
		}

		Err(_) => Bool.False
	}
}

## Bookmarks in the body, an even pages' header and a first page's footer
## take identifiers from the one space the whole document is written in, so
## no two parts give a bookmark the same number.
expect {
	marked = |name| Build.paragraph({}, [BookmarkStart(name), Build.text(name, {}), BookmarkEnd(name)])
	created = Docx.new_document({}) ? |_| Unbuilt
	body = Build.append(created, [marked("body")])
	even = Build.header(body, { kind: Even }, [marked("even")]) ? |_| Unbuilt
	first = Build.footer(even, { kind: First }, [marked("first")]) ? |_| Unbuilt
	bytes = Docx.to_bytes(first) ? |_| Unbuilt
	ids = bookmark_ids(bytes, ["/word/document.xml", "/word/header1.xml", "/word/footer1.xml"])
	ids.len() == 3 and Set.from_list(ids).len() == 3
}

## Properties given replace the document's and those left out stay; a date
## that is not one is refused.
expect {
	match propertied({}) {
		Ok({ read, refused }) => (read.title, read.subject, read.creator, read.revision, read.modified) == (Text("Lease"), Text("Rent"), Text("Grace Author"), Number(2), Date("2026-11-10T09:00:00Z")) and refused == Err(NotADate("10 November"))
		Err(_) => Bool.False
	}
}

# Two footnotes added to a new document and referred to from its body,
# written and read back.
footnoted : {} -> Try(Document, [Unbuilt])
footnoted = |{}| {
	created = Docx.new_document({}) ? |_| Unbuilt
	first = Build.footnote(created, [Build.text("First source.", {})]) ? |_| Unbuilt
	second = Build.footnote(first.document, [Build.text("Second source.", {})]) ? |_| Unbuilt
	body = Build.append(second.document, [Build.paragraph({}, [Build.text("Claim", {}), first.reference, Build.text(" and claim", {}), second.reference])])
	Ok(round_trip(body) ? |_| Unbuilt)
}

# A new document on Letter landscape, then a new continuous A4 section,
# written and read back.
sectioned : {} -> Try(Document, [Unbuilt])
sectioned = |{}| {
	created = Docx.new_document({}) ? |_| Unbuilt
	set = Build.page_setup(Build.append(created, [Build.paragraph({}, [Build.text("Portrait", {})])]), { size: Letter, orientation: Landscape, top: 720, left: 1080 })
	split = Build.append(Build.new_section(set, { start: Continuous }), [Build.paragraph({}, [Build.text("A4", {})])])
	Ok(round_trip(split) ? |_| Unbuilt)
}

# A new document with a header, a footer given twice, and a new section
# with a footer of its own, written and read back.
headed : {} -> Try(Document, [Unbuilt])
headed = |{}| {
	created = Docx.new_document({}) ? |_| Unbuilt
	page = [Build.paragraph({ alignment: Center }, [Build.text("Page ", {}), Build.page_number, Build.text(" of ", {}), Build.page_count])]
	with_header = Build.header(created, {}, [Build.paragraph({}, [Build.text("Lease", {})])]) ? |_| Unbuilt
	blank = Build.footer(with_header, {}, []) ? |_| Unbuilt
	with_footer = Build.footer(blank, {}, page) ? |_| Unbuilt
	split = Build.footer(Build.new_section(with_footer, {}), {}, [Build.paragraph({}, [Build.text("Annex", {})])]) ? |_| Unbuilt
	Ok(round_trip(split) ? |_| Unbuilt)
}

# A new document with a header for every page, then a header and a footer
# for the pages `pages` names, written and read back; and the document
# before them.
paged : [Default, Even, First] -> Try({ before : Document, read : Document }, [Unbuilt])
paged = |pages| {
	created = Docx.new_document({}) ? |_| Unbuilt
	before = Build.header(created, {}, [Build.paragraph({}, [Build.text("Every", {})])]) ? |_| Unbuilt
	label = if (pages == Even) "Even" else "First"
	with_header = Build.header(before, { kind: pages }, [Build.paragraph({}, [Build.text(label, {})])]) ? |_| Unbuilt
	with_footer = Build.footer(with_header, { kind: pages }, [Build.paragraph({}, [Build.text(label, {})])]) ? |_| Unbuilt
	Ok({ before, read: round_trip(with_footer) ? |_| Unbuilt })
}

# A new document's properties replaced in part and read back, and a date
# that is not one refused.
propertied : {} -> Try({ read : Document.CoreProperties, refused : Try({}, [NotADate(Str)]) }, [Unbuilt])
propertied = |{}| {
	created = Docx.new_document({ title: Text("Lease"), creator: Text("Ada Reviewer") }) ? |_| Unbuilt
	given = Build.properties(created, { subject: Text("Rent"), creator: Text("Grace Author"), revision: Number(2), modified: Date("2026-11-10T09:00:00Z") }) ? |_| Unbuilt
	read = Docx.core_properties(round_trip(given) ? |_| Unbuilt)
	Ok({ read, refused: Build.properties(created, { created: Date("10 November") }).map_ok(|_| {}) })
}

# The identifiers of the bookmarks that start in the named parts of a
# written package, in order.
bookmark_ids : List(U8), List(Str) -> List(Str)
bookmark_ids = |bytes, names|
	match Opc.open(bytes, {}) {
		Ok(opened) =>
			names.fold(
				[],
				|found, name|
					match Opc.part_bytes(opened, name) {
						Ok(content) => List.concat(found, starts(XmlTree.parse(content, {}) ?? Text("")))
						Err(_) => found
					},
			)

		Err(_) => []
	}

starts : XmlTree.Node -> List(Str)
starts = |node|
	match node {
		Element(element) => {
			own = if (element.name.local == "bookmarkStart") element.attributes.keep_if(|found| found.name.local == "id").map(|found| found.value) else []
			element.children.fold(own, |found, child| List.concat(found, starts(child)))
		}

		Text(_) => []
	}

# A block's text, a paragraph's or none.
block_text : Document.Block -> Str
block_text = |block|
	match block {
		Paragraph(paragraph) => Document.paragraph_text(paragraph)
		_ => ""
	}

# The note a run refers to, where it is a note reference's run.
note_reference : Document.Inline -> Try({ kind : Document.NoteKind, note : U64 }, [NoReference])
note_reference = |inline|
	match inline {
		Run(run) =>
			match run.content {
				[NoteReference(found)] => Ok(found)
				_ => Err(NoReference)
			}

		_ => Err(NoReference)
	}
