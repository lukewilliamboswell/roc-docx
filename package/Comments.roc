## A document's comments joined with the body that anchors them.
##
## A comment's content and authorship are in the comments part, which
## [WmlRead.comments] reads; where it applies is in the body, as the range
## boundaries and references [Document.Inline] and [Document.Block] hold. This
## module joins the two: each comment with what the body says about it.
import Document
import WmlRead
import XmlTree

Comments :: [].{

	## Where a comment applies in the body: the current text its range
	## covers, as [Document.paragraph_text] counts text, each paragraph's end
	## within the range a line feed; a point, where the body refers to the
	## comment without a range around it; or nowhere, when the body neither
	## marks a range for it nor refers to it.
	##
	## A range that starts and ends at one position, as Word writes a comment
	## on no text, covers the empty text. A range that never ends runs to the
	## end of the body.
	Anchor : [Range(Str), Point, Unanchored]

	## A comment with its anchor, and its `id`: its place among the comments
	## of the comments part, which is how the body's ranges and references
	## name it.
	Anchored : { id : U64, comment : Document.Comment, anchor : Anchor }

	## The comments joined with the body: those the body anchors in the order
	## their anchors begin, a range at its start and a point where the body
	## refers to the comment, then the others in the order of their part.
	## Paragraphs end and join as [Docx.text] says: a paragraph whose mark is
	## deleted or moved away runs on into the next without a line feed unless
	## a table, row or cell begins or ends between them.
	anchored : List(Document.Block), List(Document.Comment) -> List(Anchored)
	anchored = |body, comments| {
		if comments.is_empty() {
			return []
		}
		start = { marks: List.repeat({ begun: NotYet, range: NoRange }, comments.len()), text: List.with_capacity(1024), joining: Bool.False, events: 0 }
		walked = line_end(body.fold(start, walk_block))
		var $out = List.with_capacity(comments.len())
		var $id = 0.U64
		for comment in comments {
			mark = walked.marks.get($id) ?? { begun: NotYet, range: NoRange }
			anchor = match mark.range {
				Open(from) => Range(text_between(walked.text, from, walked.text.len()))
				Closed({ begin: from, end: to }) => Range(text_between(walked.text, from, to))
				NoRange => if (mark.begun == NotYet) Unanchored else Point
			}
			order = match mark.begun {
				Begun(event) => event
				NotYet => walked.events + $id
			}
			$out = List.append($out, { order, anchored: { id: $id, comment, anchor } })
			$id = $id + 1
		}
		$out
			.sort_with(|a, b| if (a.order < b.order) Before else if (a.order > b.order) After else Same)
			.map(|entry| entry.anchored)
	}
}

# The body's current text so far, with every comment's range as offsets in
# it; whether the last paragraph joins the next; and how many anchors have
# begun, which orders them.
Walk : { marks : List(Mark), text : List(U8), joining : Bool, events : U64 }

# Whether a comment's anchor has begun, and its range in the text.
Mark : { begun : [NotYet, Begun(U64)], range : [NoRange, Open(U64), Closed({ begin : U64, end : U64 })] }

walk_block : Walk, Document.Block -> Walk
walk_block = |state, block|
	match block {
		Paragraph(paragraph) => {
			walked = paragraph.content.fold(state, |inner, inline| walk_inline(inner, inline, Bool.True))
			if Document.joins_next(paragraph) {
				{ ..walked, joining: Bool.True }
			} else {
				{ ..walked, text: List.append(walked.text, 10), joining: Bool.False }
			}
		}

		Table(table) => line_end(table.content.fold(line_end(state), walk_table_content))
		Container({ element: _, content }) => content.fold(state, walk_block)
		CommentStart(id) => begin(state, id)
		CommentEnd(id) => end(state, id)
		Section(_) => state
		Preserved(_) => state
	}

walk_table_content : Walk, Document.TableContent -> Walk
walk_table_content = |state, content|
	match content {
		Row(row) => line_end(row.content.fold(line_end(state), walk_row_content))
		Container({ element: _, content: inner }) => inner.fold(state, walk_table_content)
		CommentStart(id) => begin(state, id)
		CommentEnd(id) => end(state, id)
		Preserved(_) => state
	}

walk_row_content : Walk, Document.RowContent -> Walk
walk_row_content = |state, content|
	match content {
		Cell(cell) => line_end(cell.content.fold(line_end(state), walk_block))
		Container({ element: _, content: inner }) => inner.fold(state, walk_row_content)
		CommentStart(id) => begin(state, id)
		CommentEnd(id) => end(state, id)
		Preserved(_) => state
	}

# An inline's boundaries and references, and its text when it is current
# text: content deleted or moved away is not.
walk_inline : Walk, Document.Inline, Bool -> Walk
walk_inline = |state, inline, current|
	match inline {
		Run(run) => {
			referred = run.content.fold(
				state,
				|inner, content|
					match content {
						CommentReference(id) => refer(inner, id)
						_ => inner
					},
			)
			if current {
				{ ..referred, text: List.concat(referred.text, Document.inline_text(inline).to_utf8()) }
			} else {
				referred
			}
		}

		Hyperlink({ target: _, preserved: _, content }) => content.fold(state, |inner, child| walk_inline(inner, child, current))
		SimpleField({ code: _, preserved: _, content }) => content.fold(state, |inner, child| walk_inline(inner, child, current))
		Container({ element, content }) => content.fold(state, |inner, child| walk_inline(inner, child, current and !is_removal(element)))
		CommentStart(id) => begin(state, id)
		CommentEnd(id) => end(state, id)
		BookmarkStart(_) => state
		BookmarkEnd(_) => state
		Preserved(_) => state
	}

# A range's start: the comment's anchor begins here unless a reference began
# it earlier, and its range unless one began before.
begin : Walk, U64 -> Walk
begin = |state, id| {
	at = state.text.len()
	started = change(state, id, |mark| { begun: mark.begun, range: if (mark.range == NoRange) Open(at) else mark.range })
	refer(started, id)
}

# A range's end closes the range open for the comment; an end without a start
# closes nothing.
end : Walk, U64 -> Walk
end = |state, id| {
	at = state.text.len()
	change(
		state,
		id,
		|mark|
			match mark.range {
				Open(start) => { begun: mark.begun, range: Closed({ begin: start, end: at }) }
				_ => mark
			},
	)
}

# A reference, or a range's start, begins the comment's anchor when nothing
# began it before.
refer : Walk, U64 -> Walk
refer = |state, id|
	match state.marks.get(id) {
		Ok({ begun: NotYet, range }) => { ..state, marks: List.set(state.marks, id, { begun: Begun(state.events), range }) ?? [], events: state.events + 1 }
		_ => state
	}

change : Walk, U64, (Mark -> Mark) -> Walk
change = |state, id, update|
	match state.marks.get(id) {
		Ok(mark) => { ..state, marks: List.set(state.marks, id, update(mark)) ?? [] }
		Err(_) => state
	}

# The line feed a joining paragraph owes where nothing follows it to join.
line_end : Walk -> Walk
line_end = |state| if (state.joining) { ..state, text: List.append(state.text, 10), joining: Bool.False } else state

text_between : List(U8), U64, U64 -> Str
text_between = |text, from, to| Str.from_utf8(text.sublist({ start: from, len: to - from })) ?? ""

# Whether an element marks content deleted or moved away under tracking.
is_removal : XmlTree.Node -> Bool
is_removal = |node|
	match node {
		Element(element) => element.name.namespace == Uri(wordprocessingml) and ["del", "moveFrom"].contains(element.name.local)
		Text(_) => Bool.False
	}

wordprocessingml : Str
wordprocessingml = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

# The comments of a body with this content, whose comments part has
# comments with these identifiers, each anchored or not.
anchors_of : Str, List(Str) -> List({ id : U64, anchor : Comments.Anchor })
anchors_of = |content, ids| {
	namespaces = "xmlns:w='${wordprocessingml}'"
	tree = XmlTree.parse("<w:document ${namespaces}><w:body>${content}</w:body></w:document>".to_utf8(), {}) ?? Text("")
	body = WmlRead.body(tree, { relationships: [], footnotes: [], endnotes: [], comments: ids })
	comment : Document.Comment
	comment = { author: "Ada Reviewer", initials: Unset, date: Unset, content: [], preserved: [] }
	Comments.anchored(body, List.repeat(comment, ids.len())).map(|entry| { id: entry.id, anchor: entry.anchor })
}

## A range covers the current text between its start and its end, a line
## feed for each paragraph's end within it, without deleted text and with
## inserted text; comments are in the order their anchors begin, a reference
## without a range a point, an empty range the empty text and a comment the
## body does not anchor last.
expect {
	run = |text| "<w:r><w:t xml:space='preserve'>${text}</w:t></w:r>"
	reference = |id| "<w:r><w:commentReference w:id='${id}'/></w:r>"
	first = "<w:p>${run("Lead ")}${reference("1")}<w:commentRangeStart w:id='0'/>${run("one")}<w:del><w:r><w:delText>gone</w:delText></w:r></w:del><w:ins>${run(" new")}</w:ins></w:p>"
	second = "<w:p>${run("two")}<w:commentRangeEnd w:id='0'/>${reference("0")}<w:commentRangeStart w:id='2'/><w:commentRangeEnd w:id='2'/>${reference("2")}</w:p>"
	anchors_of("${first}${second}", ["0", "1", "2", "3"])
		== [
			{ id: 1, anchor: Point },
			{ id: 0, anchor: Range("one new\ntwo") },
			{ id: 2, anchor: Range("") },
			{ id: 3, anchor: Unanchored },
		]
}

## A range can start and end between blocks, rows and cells, takes a table's
## paragraphs with their line feeds, and runs to the end of the body when it
## never ends; a paragraph whose mark is deleted runs on into the next.
expect {
	cell = |text| "<w:tc><w:p><w:r><w:t>${text}</w:t></w:r></w:p></w:tc>"
	table = "<w:tbl><w:tr><w:commentRangeStart w:id='1'/>${cell("a")}${cell("b")}<w:commentRangeEnd w:id='1'/></w:tr></w:tbl>"
	joined = "<w:p><w:pPr><w:rPr><w:del w:id='9'/></w:rPr></w:pPr><w:r><w:t>c</w:t></w:r></w:p><w:p><w:r><w:t>d</w:t></w:r></w:p>"
	anchors_of("<w:commentRangeStart w:id='0'/>${table}<w:commentRangeEnd w:id='0'/><w:commentRangeStart w:id='2'/>${joined}", ["0", "1", "2"])
		== [
			{ id: 0, anchor: Range("a\nb\n") },
			{ id: 1, anchor: Range("a\nb\n") },
			{ id: 2, anchor: Range("cd\n") },
		]
}
