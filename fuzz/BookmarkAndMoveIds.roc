import docx.Docx
import docx.Document
import docx.Opc

BookmarkAndMoveIds := [].{}

main : Str
main = "/word/document.xml"

source : Str -> Try(List(U8), Opc.WriteError)
source = |body| {
	xml = "<w:document xmlns:w='http://schemas.openxmlformats.org/wordprocessingml/2006/main'><w:body>${body}</w:body></w:document>"
	graph = {
		relationships: [{ id: "rId1", kind: Opc.officedocument_relationship, target: main, mode: Internal }],
		parts: [{ name: main, content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml", relationships: [] }],
	}
	Opc.to_bytes(graph, |_| Bytes(xml.to_utf8()))
}

run : Str -> Str
run = |text| "<w:r><w:t>${text}</w:t></w:r>"

# The internal link is to the bookmark's name; the end is joined by its ID.
matched : Document -> Bool
matched = |document|
	match Docx.body(document) {
		[Paragraph({ properties: _, content: [BookmarkStart("terms"), Run(_)] }), Paragraph({ properties: _, content: [Run(_), BookmarkEnd("terms"), Hyperlink(link)] })] =>
			link.target == Internal("terms")
		_ => Bool.False
	}

witness : Str, Str -> Try(Bool, _)
witness = |start, end| {
	body = "<w:p><w:bookmarkStart w:id='${start}' w:name='terms'/>${run("one")}</w:p><w:p>${run("two")}<w:bookmarkEnd w:id='${end}'/><w:hyperlink w:anchor='terms'>${run("See terms")}</w:hyperlink></w:p>"
	bytes = source(body)?
	first = Docx.parse(bytes)?.document
	tree = Document.from_package(Opc.open(bytes, {})?, {})?.document
	written = Docx.to_bytes(first)?
	reopened = Docx.parse(written)?.document
	xml = Str.from_utf8(Opc.part_bytes(Opc.open(written, {})?, main)?)?
	# A newly allocated bookmark uses the same canonical number at each end.
	Ok(
		matched(first) and matched(reopened)
			and Docx.body(tree) == Docx.body(first)
			and Docx.body(reopened) == Docx.body(first)
			and xml.contains("<w:bookmarkStart w:id=\"0\" w:name=\"terms\"/>")
			and xml.contains("<w:bookmarkEnd w:id=\"0\"/>")
			and xml.contains("<w:hyperlink w:anchor=\"terms\">"),
	)
}

## ECMA-376 Part 1 pairs a bookmark's markers by integer value. The link to
## the bookmark's name and both markers survive writing and reopening.
expect ["1", "+001", " 01 "].all(|start| ["1", "+001", " 01 "].all(|end| witness(start, end) ?? Bool.False))

column_bookmark : Str
column_bookmark = "<w:tbl><w:tblPr/><w:tblGrid><w:gridCol w:w='1440'/></w:tblGrid><w:tr><w:tc><w:p><w:bookmarkStart w:id='+000' w:name='column' w:colFirst='0' w:colLast='0'/>${run("a")}<w:bookmarkEnd w:id='0'/></w:p></w:tc></w:tr></w:tbl>"

## A table-column bookmark's preserved start owns its integer ID. Writing
## an ordinary bookmark in another paragraph leaves the table's ID available
## for its original end.
expect {
	ordinary = "<w:p><w:bookmarkStart w:id='340' w:name='terms'/>${run("terms")}<w:bookmarkEnd w:id='340'/></w:p>"
	first = Docx.parse(source(column_bookmark.concat(ordinary))?)?.document
	written = Docx.to_bytes(first)?
	reopened = Docx.parse(written)?.document
	xml = Str.from_utf8(Opc.part_bytes(Opc.open(written, {})?, main)?)?
	Docx.body(reopened) == Docx.body(first)
		and xml.contains("<w:bookmarkStart w:id=\"+000\" w:name=\"column\" w:colFirst=\"0\" w:colLast=\"0\"/>")
		and xml.contains("<w:bookmarkEnd w:id=\"+000\"/>")
		and xml.contains("<w:bookmarkStart w:id=\"1\" w:name=\"terms\"/>")
		and xml.contains("<w:bookmarkEnd w:id=\"1\"/>")
}

## ECMA-376 Part 1 pairs each move range's markers by integer value. The
## revision on each side independently retains its move name and text,
## and allocating move IDs avoids the preserved column bookmark.
expect {
	date = "2026-11-25T09:00:00Z"
	moved_from = "<w:p><w:moveFromRangeStart w:id='+001' w:name='terms' w:author='Ada' w:date='${date}'/><w:moveFrom w:id='3' w:author='Ada'>${run("payment")}</w:moveFrom><w:moveFromRangeEnd w:id='1'/></w:p>"
	moved_to = "<w:p><w:moveToRangeStart w:id='2' w:name='terms' w:author='Ada' w:date='${date}'/><w:moveTo w:id='4' w:author='Ada'>${run("payment")}</w:moveTo><w:moveToRangeEnd w:id=' 002 '/></w:p>"
	ends = |document| match Docx.body(document) {
		[Table(_), Paragraph(from), Paragraph(to)] => (from.content.last(), to.content.last())
		_ => (Err(ListWasEmpty), Err(ListWasEmpty))
	}
	listed = |document| Docx.revisions(document).map(|change| (change.kind, change.move, change.text))
	first = Docx.parse(source(column_bookmark.concat(moved_from).concat(moved_to))?)?.document
	written = Docx.to_bytes(first)?
	reopened = Docx.parse(written)?.document
	accepted = Docx.accept_all(reopened)?
	rejected = Docx.reject_all(reopened)?
	xml = Str.from_utf8(Opc.part_bytes(Opc.open(written, {})?, main)?)?
	ends(first) == (Ok(MoveEnd({ side: Source, name: "terms" })), Ok(MoveEnd({ side: Destination, name: "terms" })))
		and Docx.body(reopened) == Docx.body(first)
		and listed(reopened) == [(MoveSource, Move("terms"), "payment"), (MoveDestination, Move("terms"), "payment")]
		and Docx.text(accepted) == "a\n\npayment\n"
		and Docx.text(rejected) == "a\npayment\n\n"
		and xml.contains("<w:moveFromRangeStart w:id=\"1\" w:name=\"terms\"")
		and xml.contains("<w:moveFromRangeEnd w:id=\"1\"/>")
		and xml.contains("<w:moveToRangeStart w:id=\"3\" w:name=\"terms\"")
		and xml.contains("<w:moveToRangeEnd w:id=\"3\"/>")
}
