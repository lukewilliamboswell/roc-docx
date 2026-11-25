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
## views, and saving must retain both the raw chunk and the separator.
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
	Docx.text(document) == current
		and Docx.final_text(document) == current
		and Docx.original_text(document) == original
		and Docx.fields(document) == [{ code: instruction, result: raw }]
		and Docx.text(accepted) == current
		and Docx.text(rejected) == original
		and Docx.fields(accepted) == [{ code: instruction, result: raw }]
		and Docx.fields(rejected) == [{ code: "${instruction}${raw}", result: "" }]
		and saved.contains(">\\o \"A note\"</w:instrText>")
		and saved.contains("<w:ins ")
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
