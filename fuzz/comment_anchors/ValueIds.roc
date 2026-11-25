import docx.Docx
import docx.Opc

ValueIds := [].{}

main : Str
main = "/word/document.xml"

comments : Str
comments = "/word/comments.xml"

namespace : Str
namespace = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

source : Str, List((Str, Str)) -> Try(List(U8), Opc.WriteError)
source = |body, entries| {
	header = "application/vnd.openxmlformats-officedocument.wordprocessingml."
	graph = {
		relationships: [{ id: "rId1", kind: Opc.officedocument_relationship, target: main, mode: Internal }],
		parts: [
			{ name: main, content_type: "${header}document.main+xml", relationships: [{ id: "rId1", kind: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/comments", target: comments, mode: Internal }] },
			{ name: comments, content_type: "${header}comments+xml", relationships: [] },
		],
	}
	listed = entries.map(|(id, author)| "<w:comment w:id='${id}' w:author='${author}'><w:p><w:r><w:t>Check the terms.</w:t></w:r></w:p></w:comment>")
	main_xml = "<w:document xmlns:w='${namespace}'><w:body>${body}</w:body></w:document>"
	comments_xml = "<w:comments xmlns:w='${namespace}'>${Str.join_with(listed, "")}</w:comments>"
	Opc.to_bytes(graph, |name| Bytes(if (name == main) main_xml.to_utf8() else comments_xml.to_utf8()))
}

text_run : Str -> Str
text_run = |text| "<w:r><w:t>${text}</w:t></w:r>"

reference : Str -> Str
reference = |id| "<w:r><w:commentReference w:id='${id}'/></w:r>"

## Transitional ST_DecimalNumber admits equivalent integer spellings.
## A comment's boundaries and reference use its value. An unmatched kept
## reference still names no comment after the writer allocates fresh IDs.
expect {
	intro = "<w:p>${reference("+000")}${text_run("intro")}</w:p>"
	range = "<w:p><w:commentRangeStart w:id='+001'/>${text_run("terms")}<w:commentRangeEnd w:id='001'/>${reference(" 1 ")}${text_run("end")}</w:p>"
	first = Docx.parse(source(intro.concat(range), [("0001", "Ada Reviewer")])?)?.document
	bytes = Docx.to_bytes(first)?
	reopened = Docx.parse(bytes)?.document
	package_index = Opc.open(bytes, {})?
	main_xml = Str.from_utf8(Opc.part_bytes(package_index, main)?)?
	comments_xml = Str.from_utf8(Opc.part_bytes(package_index, comments)?)?
	joined = |document| Docx.comments(document).comments.map(|entry| (entry.id, entry.comment.author, entry.anchor))
	joined(first) == [(0, "Ada Reviewer", Range("terms"))]
		and joined(reopened) == joined(first)
		and Docx.body(reopened) == Docx.body(first)
		and main_xml.contains("w:commentReference w:id=\"+000\"")
		and main_xml.contains("w:commentReference w:id=\"1\"")
		and comments_xml.contains("w:comment w:id=\"1\"")
}

## Exact spellings still select their original definitions if a producer
## writes two comments with equivalent identifiers. The fresh identifiers
## on write preserve these two joins.
expect {
	body = "<w:p>${reference("+01")}${text_run("one")}${reference("1")}</w:p>"
	first = Docx.parse(source(body, [("+01", "Ada Reviewer"), ("1", "Lin Editor")])?)?.document
	reopened = Docx.parse(Docx.to_bytes(first)?)?.document
	points = |document| Docx.comments(document).comments.map(|entry| (entry.id, entry.comment.author, entry.anchor))
	points(first) == [(0, "Ada Reviewer", Point), (1, "Lin Editor", Point)]
		and points(first) == points(reopened)
		and Docx.body(first) == Docx.body(reopened)
}
