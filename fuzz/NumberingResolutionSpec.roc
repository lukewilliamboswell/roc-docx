import docx.Docx
import docx.Document
import docx.Numbering
import docx.Opc
import docx.Snapshot

NumberingResolutionSpec := [].{}

w : Str
w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

r : Str
r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

part : Str, Str, List(Opc.Relationship) -> Opc.GraphPart
part = |name, kind, relationships| { name, content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.${kind}+xml", relationships }

paragraph : Str, Str, Str -> Str
paragraph = |name, numbering, formatting|
	"<w:p><w:pPr><w:pStyle w:val='Tier'/>${numbering}${formatting}</w:pPr><w:r><w:t>${name}</w:t></w:r></w:p>"

fixture : {} -> Try(List(U8), Opc.WriteError)
fixture = |{}| {
	links = [
		{ id: "rId1", kind: "${r}/styles", target: "/word/styles.xml", mode: Internal },
		{ id: "rId2", kind: "${r}/numbering", target: "/word/numbering.xml", mode: Internal },
		{ id: "rId3", kind: "${r}/header", target: "/word/header.xml", mode: Internal },
	]
	graph = {
		relationships: [{ id: "rId1", kind: Opc.officedocument_relationship, target: "/word/document.xml", mode: Internal }],
		parts: [
			part("/word/document.xml", "document.main", links),
			part("/word/styles.xml", "styles", []),
			part("/word/numbering.xml", "numbering", []),
			part("/word/header.xml", "header", []),
		],
	}
	styles = "<w:styles xmlns:w='${w}'>"
		.concat("<w:style w:type='paragraph' w:styleId='ListRoot'><w:pPr><w:keepNext/><w:numPr><w:numId w:val='7'/></w:numPr></w:pPr></w:style>")
		.concat("<w:style w:type='paragraph' w:styleId='Tier'><w:basedOn w:val='ListRoot'/></w:style>")
		.concat("<w:style w:type='paragraph' w:styleId='Fallback'><w:basedOn w:val='ListRoot'/><w:pPr><w:numPr><w:ilvl w:val='1'/></w:numPr></w:pPr></w:style>")
		.concat("<w:style w:type='paragraph' w:styleId='TableOnly'><w:pPr><w:keepNext/></w:pPr></w:style>")
		.concat("<w:style w:type='table' w:styleId='Grid'><w:pPr><w:numPr><w:numId w:val='7'/></w:numPr><w:jc w:val='center'/></w:pPr></w:style></w:styles>")
	numbering = "<w:numbering xmlns:w='${w}'><w:abstractNum w:abstractNumId='2'>"
		.concat("<w:lvl w:ilvl='0'><w:numFmt w:val='bullet'/><w:lvlText w:val='•'/></w:lvl>")
		.concat("<w:lvl w:ilvl='1'><w:numFmt w:val='decimal'/><w:lvlText w:val='%2.'/><w:pPr><w:jc w:val='left'/></w:pPr></w:lvl>")
		.concat("<w:lvl w:ilvl='2'><w:numFmt w:val='upperRoman'/><w:pStyle w:val='Tier'/><w:lvlText w:val='%3.'/></w:lvl>")
		.concat("<w:lvl w:ilvl='3'><w:numFmt w:val='decimal'/><w:pStyle w:val='TableOnly'/><w:lvlText w:val='%4.'/></w:lvl></w:abstractNum>")
		.concat("<w:num w:numId='7'><w:abstractNumId w:val='2'/><w:lvlOverride w:ilvl='2'><w:startOverride w:val='5'/><w:lvl w:ilvl='2'><w:numFmt w:val='lowerRoman'/><w:lvlText w:val='%3.'/><w:pPr><w:jc w:val='right'/></w:pPr><w:rPr><w:b/></w:rPr></w:lvl></w:lvlOverride></w:num>")
		.concat("<w:num w:numId='9'><w:abstractNumId w:val='2'/></w:num></w:numbering>")
	table = "<w:tbl><w:tblPr><w:tblStyle w:val='Grid'/></w:tblPr><w:tblGrid><w:gridCol w:w='720'/><w:gridCol w:w='720'/><w:gridCol w:w='720'/></w:tblGrid><w:tr>"
		.concat("<w:tc>${paragraph("table style list", "", "")}</w:tc>")
		.concat("<w:tc>${paragraph("table no list", "<w:numPr><w:numId w:val='0'/></w:numPr>", "")}</w:tc>")
		.concat("<w:tc><w:p><w:pPr><w:pStyle w:val='TableOnly'/></w:pPr><w:r><w:t>number from table</w:t></w:r></w:p></w:tc></w:tr></w:tbl>")
	main = "<w:document xmlns:w='${w}' xmlns:r='${r}'><w:body>"
		.concat(paragraph("from style", "", ""))
		.concat("<w:p><w:pPr><w:pStyle w:val='ListRoot'/></w:pPr><w:r><w:t>unmapped style</w:t></w:r></w:p>")
		.concat("<w:p><w:pPr><w:pStyle w:val='Fallback'/></w:pPr><w:r><w:t>fallback level</w:t></w:r></w:p>")
		.concat(paragraph("explicit instance", "<w:numPr><w:numId w:val='7'/></w:numPr>", ""))
		.concat(paragraph("explicit list", "<w:numPr><w:ilvl w:val='1'/><w:numId w:val='9'/></w:numPr>", ""))
		.concat(paragraph("explicit level", "<w:numPr><w:ilvl w:val='1'/></w:numPr>", "<w:jc w:val='center'/>"))
		.concat(paragraph("no list", "<w:numPr><w:numId w:val='0'/></w:numPr>", ""))
		.concat(table)
		.concat("<w:sectPr><w:headerReference w:type='default' r:id='rId3'/></w:sectPr></w:body></w:document>")
	header = "<w:hdr xmlns:w='${w}'>${paragraph("header list", "", "")}</w:hdr>"
	Opc.to_bytes(
		graph,
		|name| {
			xml = match name {
				"/word/styles.xml" => styles
				"/word/numbering.xml" => numbering
				"/word/header.xml" => header
				_ => main
			}
			Bytes(xml.to_utf8())
		},
	)
}

matches : Document -> Bool
matches = |doc| {
	{ styles, diagnostics: style_diagnostics } = Docx.styles(doc)
	{ numbering, diagnostics: numbering_diagnostics } = Docx.numbering(doc)
	paragraphs = Docx.paragraphs(doc)
	stripes = paragraphs.map(
		|one| {
			effective = one.properties.numbering
			listed = Numbering.level(numbering, styles, effective).map_ok(|level| (level.level, level.format, level.start))
			(
				Document.paragraph_text(one.paragraph),
				one.location,
				one.paragraph.properties.numbering,
				effective.instance,
				listed,
				one.properties.alignment,
			)
		},
	)
	implicit = { instance: Unset, level: Unset }
	level_only = { instance: Unset, level: Level(1) }
	explicit = { instance: Instance(9), level: Level(1) }
	no_list = { instance: Instance(0), level: Unset }
	instance_only = { instance: Instance(7), level: Unset }
	bullet = Ok((0, Bullet, Unset))
	roman = Ok((2, Number("lowerRoman"), Start(5)))
	decimal = Ok((1, Number("decimal"), Unset))
	stripes == [
		("from style", Body, implicit, Instance(7), roman, Aligned(Right)),
		("unmapped style", Body, implicit, Instance(7), bullet, Unset),
		("fallback level", Body, implicit, Instance(7), decimal, Aligned(Left)),
		("explicit instance", Body, instance_only, Instance(7), bullet, Unset),
		("explicit list", Body, explicit, Instance(9), decimal, Aligned(Left)),
		("explicit level", Body, level_only, Instance(7), decimal, Aligned(Center)),
		("no list", Body, no_list, Instance(0), Err(NotListed), Unset),
		("table style list", Body, implicit, Instance(7), roman, Aligned(Right)),
		("table no list", Body, no_list, Instance(0), Err(NotListed), Aligned(Center)),
		("number from table", Body, implicit, Instance(7), bullet, Aligned(Center)),
		("header list", Header("/word/header.xml"), implicit, Instance(7), roman, Aligned(Right)),
	]
		and style_diagnostics == []
		and numbering_diagnostics == []
		and paragraphs.all(|one| one.properties.keep_next == On and one.runs.map(|run| run.properties.bold) == [Off])
		and Snapshot.json(doc, { path: "", version: "" }).contains("{\"kind\": \"list_item\", \"level\": 3, \"list\": \"number\", \"text\": \"from style\"")
}

## ECMA-376 Part 1 §§17.3.1.19 and 17.9.23. A paragraph style taking an
## instance through its base selects the level associated with the applied
## style. The instance's override supplies that level's formatting. Direct
## formatting overrides or cancels membership. An unmatched style retains
## its existing level as a fallback. An instance supplied by a
## table style alone keeps its ordinary level. Numbering run properties
## belong to the marker alone. Save without
## baking the effective numbering into the paragraphs' direct properties.
expect {
	read = Docx.parse(fixture({})?)?
	reopened = Docx.parse(Docx.to_bytes(read.document)?)?
	matches(read.document) and matches(reopened.document)
}
