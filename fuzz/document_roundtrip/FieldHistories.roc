import docx.Docx
import docx.Document
import docx.Opc
import fuzz.Model

FieldHistories := [].{}

Placement : [Instruction, Result]

Layout : [Together, Paragraphs, ContentControl]

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
	ChooseLayout(_) => [LayOut(Together), LayOut(Paragraphs), LayOut(ContentControl)]
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
	date = "${begin}${code(" DATE ")}${separator}${after_separator}${text("01-04")}${end}"
	condition = code(" IF ")
	comparison = code(" &lt;&gt; &quot;1-1&quot; &quot;yes&quot; &quot;no&quot; ")
	page = "<w:fldSimple w:instr=' PAGE '>${text("7")}</w:fldSimple>"
	conditional = match placement {
		Instruction => "${begin}${condition}${date}${comparison}${separator}${text("yes")}${end}"
		Result => "${begin}${condition}${code("1")}${comparison}${separator}${text("yes")}${date}${end}"
	}
	first = "${begin}${code(" TOC ")}${separator}${text("α")}"
	middle = "${conditional}${page}"
	last = "${text("✓")}${end}${text("after")}"
	body = match layout {
		Together => paragraph("${first}${middle}${last}")
		Paragraphs => "${paragraph(first)}${paragraph(middle)}${paragraph(last)}"
		ContentControl => "${paragraph(first)}<w:sdt><w:sdtContent>${paragraph(middle)}</w:sdtContent></w:sdt>${paragraph(last)}"
	}
	packed = Opc.to_bytes(
		{
			relationships: [{ id: "rId1", kind: Opc.officedocument_relationship, target: part, mode: Internal }],
			parts: [{ name: part, content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml", relationships: [] }],
		},
		|_| Bytes("<w:document xmlns:w='http://schemas.openxmlformats.org/wordprocessingml/2006/main'><w:body>${body}</w:body></w:document>".to_utf8()),
	) ?? crash "could not package field history"
	parsed = Docx.parse(packed) ?? crash "could not parse field history"
	parsed.document
}

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
	line = if (layout == Together) "" else "\n"
	[
		{ code: " TOC ", result: "α${line}yes${embedded}7${line}✓" },
		{ code: " IF ${literal} <> \"1-1\" \"yes\" \"no\" ", result: "yes${embedded}" },
		{ code: " DATE ", result: "01-04" },
		{ code: " PAGE ", result: "7" },
	]
}

## A nested expression's cached value is its own result. It contributes to
## an enclosing field only when placed in its result. Exhaust both placements
## across paragraphs and a content control before and after reopening.
expect {
	goal = "reopen a nested instruction across a block content control"
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
					goal,
					|state| match state {
						Reopened({ placement: Instruction, layout: ContentControl, .. }) => Bool.True
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
		Holds(Exhausted) => Model.witness(report, goal) == Ok([Place(Instruction), LayOut(ContentControl), Reopen])
		_ => crash "${Model.explain(report)} ${Str.inspect(report.verdict)}"
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
