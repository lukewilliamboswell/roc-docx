import docx.Docx
import docx.Document
import docx.Opc
import docx.Snapshot
import fuzz.Model

FieldHistories := [].{}

Placement : [Instruction, Result]

Layout : [Together, Paragraphs, ContentControl, Simple, SimpleWithRevisions]

Action : [Place(Placement), LayOut(Layout), Reopen]

State : [
	ChoosePlacement,
	ChooseLayout(Placement),
	Read({ placement : Placement, layout : Layout, document : Document }),
	Reopened({ placement : Placement, layout : Layout, document : Document }),
]

actions : State -> List(Action)
actions = |state| match state {
	ChoosePlacement => [Place(Instruction), Place(Result)]
	ChooseLayout(_) => [LayOut(Together), LayOut(Paragraphs), LayOut(ContentControl), LayOut(Simple), LayOut(SimpleWithRevisions)]
	Read(_) => [Reopen]
	Reopened(_) => []
}

part : Str
part = "/word/document.xml"

paragraph : Str -> Str
paragraph = |runs| "<w:p>${runs}</w:p>"

mark : Str -> Str
mark = |kind| "<w:r><w:fldChar w:fldCharType='${kind}'/></w:r>"

code : Str -> Str
code = |xml| "<w:r><w:instrText xml:space='preserve'>${xml}</w:instrText></w:r>"

text : Str -> Str
text = |xml| "<w:r><w:t>${xml}</w:t></w:r>"

document_with : Placement, Layout, Str -> Document
document_with = |placement, layout, after_separator| {
	begin = mark("begin")
	separator = mark("separate")
	end = mark("end")
	simple_layout = layout == Simple or layout == SimpleWithRevisions
	date_text = if (simple_layout) code("01-04") else text("01-04")
	date = "${begin}${code(" DATE ")}${separator}${after_separator}${date_text}${end}"
	condition = code(" IF ")
	comparison = code(" &lt;&gt; &quot;1-1&quot; &quot;yes&quot; &quot;no&quot; ")
	page_text = if (simple_layout) code("7") else text("7")
	page = "<w:fldSimple w:instr=' PAGE '>${page_text}</w:fldSimple>"
	conditional = match placement {
		Instruction => "${begin}${condition}${date}${comparison}${separator}${text("yes")}${end}"
		Result => "${begin}${condition}${code("1")}${comparison}${separator}${text("yes")}${date}${end}"
	}
	first = "${begin}${code(" TOC ")}${separator}${text("α")}"
	middle = "${conditional}${page}"
	last = "${text("✓")}${end}${text("after")}"
	simple = |runs| paragraph("<w:fldSimple w:instr=' TOC '>${text("α")}${runs}${text("✓")}</w:fldSimple>${text("after")}")
	deleted = "<w:del w:id='1' w:author='Ada'>${begin}<w:r><w:delInstrText>NUMPAGES</w:delInstrText></w:r>${separator}<w:r><w:delText>gone</w:delText></w:r>${end}</w:del>"
	inserted = "<w:ins w:id='2' w:author='Ada'>${text("+")}</w:ins>"
	body = match layout {
		Together => paragraph("${first}${middle}${last}")
		Paragraphs => "${paragraph(first)}${paragraph(middle)}${paragraph(last)}"
		ContentControl => "${paragraph(first)}<w:sdt><w:sdtContent>${paragraph(middle)}</w:sdtContent></w:sdt>${paragraph(last)}"
		Simple => simple(middle)
		SimpleWithRevisions => simple("${deleted}${inserted}<w:sdt><w:sdtContent>${middle}</w:sdtContent></w:sdt>")
	}
	packed = body_bytes(body) ?? crash "could not package field history"
	parsed = Docx.parse(packed) ?? crash "could not parse field history"
	parsed.document
}

body_bytes : Str -> Try(List(U8), Opc.WriteError)
body_bytes = |body| Opc.to_bytes(
	{
		relationships: [{ id: "rId1", kind: Opc.officedocument_relationship, target: part, mode: Internal }],
		parts: [{ name: part, content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml", relationships: [] }],
	},
	|_| Bytes("<w:document xmlns:w='http://schemas.openxmlformats.org/wordprocessingml/2006/main'><w:body>${body}</w:body></w:document>".to_utf8()),
)

step : State, Action -> State
step = |state, action| match (state, action) {
	(ChoosePlacement, Place(placement)) => ChooseLayout(placement)
	(ChooseLayout(placement), LayOut(layout)) => Read({ placement, layout, document: document_with(placement, layout, "") })
	(Read(held), Reopen) => {
		bytes = Docx.to_bytes(held.document) ?? crash "could not save field history"
		parsed = Docx.parse(bytes) ?? crash "could not reopen field history"
		Reopened({ ..held, document: parsed.document })
	}
	_ => crash "invalid field history action"
}

# Derive the expected result from where the cached date belongs and from
# the paragraph separators, with no walk over marks, runs or containers.
expected_fields : Placement, Layout -> List(Document.Field)
expected_fields = |placement, layout| {
	embedded = if (placement == Result) "01-04" else ""
	literal = if (placement == Result) "1" else ""
	line = if (layout == Paragraphs or layout == ContentControl) "\n" else ""
	addition = if (layout == SimpleWithRevisions) "+" else ""
	[
		{ code: " TOC ", result: "α${line}${addition}yes${embedded}7${line}✓" },
		{ code: " IF ${literal} <> \"1-1\" \"yes\" \"no\" ", result: "yes${embedded}" },
		{ code: " DATE ", result: "01-04" },
		{ code: " PAGE ", result: "7" },
	]
}

## A nested expression's cached value is its own result. It contributes to
## an enclosing field only when placed in its result. Exhaust both placements
## across paragraphs and a content control before and after reopening.
## A simple enclosing field has its own cache, with nested ordinary
## instrText read as text and deleted fields omitted from the current view.
expect {
	block_goal = "reopen a nested instruction across a block content control"
	simple_goal = "reopen a simple result with nested instructions and revisions"
	report = Model.explore(
		{
			init: ChoosePlacement,
			actions,
			step,
			rules: [
				Model.always(
					"field codes and cached results stay in start order",
					|state| match state {
						Read({ placement, layout, document }) | Reopened({ placement, layout, document }) =>
							Docx.fields(document) == expected_fields(placement, layout)
						_ => Bool.True
					},
				),
				Model.sometimes(
					block_goal,
					|state| match state {
						Reopened({ placement: Instruction, layout: ContentControl, .. }) => Bool.True
						_ => Bool.False
					},
				),
				Model.sometimes(
					simple_goal,
					|state| match state {
						Reopened({ placement: Instruction, layout: SimpleWithRevisions, .. }) => Bool.True
						_ => Bool.False
					},
				),
			],
		},
		{
			depth: 4,
			key: |state| match state {
				ChoosePlacement => NoPlacement
				ChooseLayout(placement) => Placement(placement)
				Read({ placement, layout, .. }) => Mounted((placement, layout))
				Reopened({ placement, layout, .. }) => Saved((placement, layout))
			},
			verify: EveryStep,
		},
	)
	match report.verdict {
		Holds(Exhausted) =>
			Model.witness(report, block_goal) == Ok([Place(Instruction), LayOut(ContentControl), Reopen])
				and Model.witness(report, simple_goal) == Ok([Place(Instruction), LayOut(SimpleWithRevisions), Reopen])
		_ => crash "${Model.explain(report)} ${Str.inspect(report.verdict)}"
	}
}

## An isolated paragraph starts in the ordinary phase. Its simple field's
## literal result tokens also contribute to current text.
expect {
	document = document_with(Result, SimpleWithRevisions, "")
	match Docx.body(document).first() {
		Ok(Paragraph(held)) => Document.paragraph_text(held) == "α+yes01-047✓after"
		_ => Bool.False
	}
}

## ECMA-376 Part 1 §17.16.23. An instruction-shaped result chunk cannot
## extend the code of either the nested field or the enclosing field.
## Saving retains the source element.
expect {
	document = document_with(Instruction, ContentControl, code("Outside instruction"))
	written = Docx.to_bytes(document)?
	main = Str.from_utf8(Opc.part_bytes(Opc.open(written, {})?, part)?)?
	reopened = Docx.parse(written)?
	codes = |doc| Docx.fields(doc).map(|field| field.code)
	expected = expected_fields(Instruction, ContentControl).map(|field| field.code)
	codes(document) == expected
		and codes(reopened.document) == expected
		and main.contains(">Outside instruction</w:instrText>")
}

## ECMA-376 Part 1 §17.16.23. Standalone instrText, instrText after an end,
## and instrText in a hyperlink result are ordinary text. The instruction
## between begin and separator remains field code. Field state spans
## paragraphs, and the visible text takes part in ordinary edit offsets.
expect {
	bookmark = "<w:bookmarkStart w:id='1' w:name='Toc1'/><w:bookmarkEnd w:id='1'/>"
	instruction = " HYPERLINK \\l Toc1 "
	before = paragraph("${bookmark}${code("Standalone")}${mark("begin")}${code(instruction)}")
	after = paragraph("${mark("separate")}${code("suffix")}${text("Reference")}${mark("end")}${code("After field")}")
	source = body_bytes("${before}${after}")?
	streamed = Docx.parse(source)?
	whole = Document.from_package(Opc.open(source, {})?, {})?
	reopened = Docx.parse(Docx.to_bytes(streamed.document)?)?
	read = |document| Docx.text(document) == "Standalone\nsuffixReferenceAfter field\n"
		and Docx.fields(document) == [{ code: instruction, result: "suffixReference" }]
	snapshot = Snapshot.json(streamed.document, { path: "", version: "" })
	offset = "Standalone\nsu".count_utf8_bytes()
	edited = Docx.insert_text(streamed.document, offset, "-", Untracked)?
	broken = Docx.insert_text(streamed.document, offset, "x\ny", Untracked)?
	archive = Opc.open(Docx.to_bytes(edited)?, {})?
	saved = Str.from_utf8(Opc.part_bytes(archive, part)?)?
	read(streamed.document)
		and read(whole.document)
		and read(reopened.document)
		and Docx.read_body(streamed.document) == Docx.read_body(whole.document)
		and snapshot.contains("\"text\": \"suffixReference\"")
		and snapshot.contains("\"link\": \"#Toc1\"")
		and Docx.text(edited) == "Standalone\nsu-ffixReferenceAfter field\n"
		and Docx.text(broken) == "Standalone\nsux\nyffixReferenceAfter field\n"
		and saved.contains(">su</w:instrText>")
		and saved.contains(">ffix</w:instrText>")
}

## A separator added by a revision changes how the same untracked chunk
## reads. Accepting and rejecting must agree with the corresponding text
## views, and saving must retain both the raw chunk and the separator. An
## anchor within the visible chunk uses the same byte positions as text.
expect {
	bookmark = "<w:bookmarkStart w:id='1' w:name='Toc1'/><w:bookmarkEnd w:id='1'/>"
	instruction = " HYPERLINK \\l Toc1 "
	tooltip = "\\o &quot;A note&quot;"
	separator = "<w:ins w:id='2' w:author='Ada Reviewer'>${mark("separate")}</w:ins>"
	source = body_bytes(paragraph("${bookmark}${text("before|")}${mark("begin")}${code(instruction)}${separator}${code(tooltip)}${mark("end")}${text("|after")}"))?
	parsed = Docx.parse(source)?
	document = parsed.document
	bytes = Docx.to_bytes(document)?
	saved = Str.from_utf8(Opc.part_bytes(Opc.open(bytes, {})?, part)?)?
	reopened = Docx.parse(bytes)?
	raw = "\\o \"A note\""
	accepted = Docx.accept_all(reopened.document)?
	rejected = Docx.reject_all(reopened.document)?
	current = "before|${raw}|after\n"
	original = "before||after\n"
	start = "before|\\o \"".count_utf8_bytes()
	marked = Docx.add_comment(document, { start, end: start + "A note".count_utf8_bytes() }, { author: "Lin Reviewer", content: Text("Check the wording.") })?
	marked_reopened = Docx.parse(Docx.to_bytes(marked.document)?)?.document
	Docx.text(document) == current
		and Docx.final_text(document) == current
		and Docx.original_text(document) == original
		and Docx.fields(document) == [{ code: instruction, result: raw }]
		and Docx.text(accepted) == current
		and Docx.text(rejected) == original
		and Docx.fields(accepted) == [{ code: instruction, result: raw }]
		and Docx.fields(rejected) == [{ code: "${instruction}${raw}", result: "" }]
		and Docx.text(marked_reopened) == current
		and Docx.original_text(marked_reopened) == original
		and Docx.comments(marked_reopened).comments.map(|comment| comment.anchor) == [Range("A note")]
		and saved.contains(">\\o \"A note\"</w:instrText>")
		and saved.contains("<w:ins ")
}

MovedMark : [Begin, Separate, End]

Position : [Earlier, Later]

MarkPlacement : (MovedMark, Position)

MarkAction : [Move(MarkPlacement), Reopen]

MarkHistory : [
	Unplaced,
	Moved({ placement : MarkPlacement, document : Document }),
	Saved({ placement : MarkPlacement, document : Document, accepted : Document, rejected : Document }),
]

marked_document : MarkPlacement -> Document
marked_document = |(kind, current)| {
	name = match kind {
		Begin => "begin"
		Separate => "separate"
		End => "end"
	}
	inserted = "<w:ins w:id='1' w:author='Ada Reviewer'>${mark(name)}</w:ins>"
	deleted = "<w:del w:id='2' w:author='Ada Reviewer'>${mark(name)}</w:del>"
	(early, late) = if (current == Earlier) (inserted, deleted) else (deleted, inserted)
	probes = "${early}${code("α")}${late}${code("✓")}"
	field = match kind {
		Begin => "${probes}${mark("separate")}${text("result")}${mark("end")}"
		Separate => "${mark("begin")}${probes}${mark("end")}"
		End => "${mark("begin")}${probes}"
	}
	source = body_bytes(paragraph("${text("before|")}${field}${text("|after")}")) ?? crash "could not package moved field mark"
	parsed = Docx.parse(source) ?? crash "could not read moved field mark"
	parsed.document
}

expected_mark_text : MarkPlacement -> Str
expected_mark_text = |placement| {
	middle = match placement {
		(Begin, Earlier) => "result"
		(Begin, Later) => "αresult"
		(Separate, Earlier) | (End, Earlier) => "α✓"
		(Separate, Later) | (End, Later) => "✓"
	}
	"before|${middle}|after\n"
}

other_position : Position -> Position
other_position = |position| match position {
	Earlier => Later
	Later => Earlier
}

mark_views_agree : MarkPlacement, Document -> Bool
mark_views_agree = |(kind, current), document| {
	current_text = expected_mark_text((kind, current))
	Docx.text(document) == current_text
		and Docx.final_text(document) == current_text
		and Docx.original_text(document) == expected_mark_text((kind, other_position(current)))
}

## Moving each complex field boundary in both directions leaves a complete
## field in either view and changes the visibility of the intervening text.
## Save and reopen each arrangement, then verify both resolution directions.
expect {
	reopened_end = "reopen an end marker moved across visible text"
	mark_actions : MarkHistory -> List(MarkAction)
	mark_actions = |state| match state {
		Unplaced => [
			Move((Begin, Earlier)),
			Move((Begin, Later)),
			Move((Separate, Earlier)),
			Move((Separate, Later)),
			Move((End, Earlier)),
			Move((End, Later)),
		]
		Moved(_) => [Reopen]
		Saved(_) => []
	}
	report = Model.explore(
		{
			init: Unplaced,
			actions: mark_actions,
			step: |state, action| match (state, action) {
				(Unplaced, Move(placement)) => Moved({ placement, document: marked_document(placement) })
				(Moved({ placement, document }), Reopen) => {
					bytes = Docx.to_bytes(document) ?? crash "could not save moved field mark"
					reopened = Docx.parse(bytes) ?? crash "could not reopen moved field mark"
					accepted = Docx.accept_all(reopened.document) ?? crash "could not accept moved field mark"
					rejected = Docx.reject_all(reopened.document) ?? crash "could not reject moved field mark"
					Saved({ placement, document: reopened.document, accepted, rejected })
				}
				_ => crash "invalid moved field mark action"
			},
			rules: [
				Model.always(
					"all text views agree with the position of their field boundary",
					|state| match state {
						Unplaced => Bool.True
						Moved({ placement, document }) => mark_views_agree(placement, document)
						Saved({ placement: (kind, current), document, accepted, rejected }) =>
							mark_views_agree((kind, current), document)
								and Docx.text(accepted) == expected_mark_text((kind, current))
								and Docx.text(rejected) == expected_mark_text((kind, other_position(current)))
					},
				),
				Model.sometimes(
					reopened_end,
					|state| match state {
						Saved({ placement: (End, Earlier), .. }) => Bool.True
						_ => Bool.False
					},
				),
			],
		},
		{
			depth: 3,
			key: |state| match state {
				Unplaced => Unplaced
				Moved({ placement, .. }) => Moved(placement)
				Saved({ placement, .. }) => Saved(placement)
			},
			verify: EveryStep,
		},
	)
	match report.verdict {
		Holds(Exhausted) => Model.witness(report, reopened_end) == Ok([Move((End, Earlier)), Reopen])
		_ => crash "${Model.explain(report)} ${Str.inspect(report.verdict)}"
	}
}

## ECMA-376 Part 1 §17.16.13. A deleted instruction-shaped run outside a
## field is deleted text. It is visible only in the original view or
## after rejecting the deletion.
expect {
	deleted = "<w:del w:id='1' w:author='Ada Reviewer'><w:r><w:delInstrText>before</w:delInstrText></w:r></w:del>"
	parsed = Docx.parse(body_bytes(paragraph("${deleted}${text("after")}"))?)?
	rejected = Docx.reject_all(parsed.document)?
	Docx.text(parsed.document) == "after\n"
		and Docx.original_text(parsed.document) == "beforeafter\n"
		and Docx.text(rejected) == "beforeafter\n"
}

## Revision excerpts include ordinary inserted instrText and omit actual
## instructions, following the field phase across paragraphs in story order.
expect {
	insertion = |id, value| "<w:ins w:id='${id}' w:author='Ada Reviewer'>${code(value)}</w:ins>"
	before = paragraph("${insertion("1", "seen")}${mark("begin")}")
	after = paragraph("${insertion("2", " PAGE ")}${mark("separate")}${text("3")}${mark("end")}")
	parsed = Docx.parse(body_bytes("${before}${after}")?)?
	Docx.revisions(parsed.document).map(|change| change.text) == ["seen", ""]
		and Docx.text(parsed.document) == "seen\n3\n"
}
