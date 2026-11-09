## Read a Word document from its bytes, read its body and text, and write it
## back.
##
## `Docx.parse` opens the package within the default `Limits` and reads it as
## a [Document]; `Docx.body` and `Docx.text` read what its body says;
## `Docx.to_bytes` writes a document as a package. What reading drops comes
## back as diagnostics beside the document, never printed.
import Document
import Mce
import Opc
import WmlRead
import XmlTree

Docx :: [].{

	## Why bytes cannot be read as a document: the errors of [Opc.open] and of
	## [Document.from_package].
	ParseError : [
		InvalidSignature,
		TruncatedArchive,
		InvalidFilename,
		CompressionNotSupported(U16),
		CrcMismatch({ path : Str, expected : U32, actual : U32 }),
		InvalidCompressedData(Str),
		DuplicatePart(Str),
		PartSizeMismatch({ name : Str, declared : U64 }),
		TooManyEntries(U64),
		PartTooLarge({ name : Str, bytes : U64 }),
		PackageTooLarge(U64),
		MissingContentTypes,
		ContentTypesNotXml(XmlTree.ReadError),
		ContentTypesRootIsNotTypes,
		MissingAttribute(Opc.AttributeLocation),
		NoContentType(Str),
		MissingPart(Str),
		RelationshipsNotXml({ part : Str, problem : XmlTree.ReadError }),
		XmlPartUnreadable({ part : Str, problem : XmlTree.ReadError }),
	]

	## Read a document from the bytes of a `.docx`, with what reading dropped.
	parse : List(U8) -> Try({ document : Document, diagnostics : List(Document.Diagnostic) }, ParseError)
	parse = |bytes| Ok(Document.from_package(Opc.open(bytes, {})?, {})?)

	## Write a document as the bytes of a `.docx`. The same document always
	## gives the same bytes.
	to_bytes : Document -> Try(List(U8), Document.WriteError)
	to_bytes = |document| Document.to_bytes(document)

	## The body of a document's main part as the typed model, block by block
	## in reading order, as [WmlRead.body] reads it. A document without a main
	## document part has no blocks.
	body : Document -> List(Document.Block)
	body = |document| Docx.read_body(document).blocks

	## The body as [Docx.body] reads it, with what the reader accepted that
	## the schema does not allow, as [WmlRead.read_body] gives it.
	read_body : Document -> { blocks : List(Document.Block), diagnostics : List(WmlRead.Diagnostic) }
	read_body = |document|
		match Document.main_document(document) {
			Ok(tree) => WmlRead.read_body(tree)
			Err(NoMainDocument) => { blocks: [], diagnostics: [] }
		}

	## The current text of a document's body, its tracked changes as they
	## stand: every paragraph's text, as [Document.paragraph_text] gives it,
	## followed by a line feed, in reading order, including the paragraphs in
	## tables and content controls. A paragraph whose mark is deleted or moved
	## away, as [Document.joins_next] says, runs on into the next paragraph
	## without a line feed, unless a table, row or cell begins or ends between
	## them.
	text : Document -> Str
	text = |document| {
		var $state = { text: List.with_capacity(1024), joining: Bool.False }
		for block in Docx.body(document) {
			$state = block_text($state, block)
		}
		Str.from_utf8(line_end($state).text) ?? ""
	}
}

TextState : { text : List(U8), joining : Bool }

block_text : TextState, Document.Block -> TextState
block_text = |state, block|
	match block {
		Paragraph(paragraph) => {
			text = List.concat(state.text, Document.paragraph_text(paragraph).to_utf8())
			if Document.joins_next(paragraph) {
				{ text, joining: Bool.True }
			} else {
				{ text: List.append(text, 10), joining: Bool.False }
			}
		}

		Table(table) =>
			line_end(
				Document.table_rows(table).fold(
					line_end(state),
					|row_state, row| line_end(Document.row_cells(row).fold(line_end(row_state), |cell_state, cell| line_end(cell.content.fold(line_end(cell_state), block_text)))),
				),
			)

		Container({ element: _, content }) => content.fold(state, block_text)
		Preserved(_) => state
	}

# The line feed a joining paragraph owes where nothing follows it to join.
line_end : TextState -> TextState
line_end = |state| if (state.joining) { text: List.append(state.text, 10), joining: Bool.False } else state

# A package whose main document has this body content.
package_of : Str -> Try(List(U8), Opc.WriteError)
package_of = |content| {
	main = "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"
	graph = {
		relationships: [{ id: "rId1", kind: Opc.officedocument_relationship, target: "/word/document.xml", mode: Internal }],
		parts: [{ name: "/word/document.xml", content_type: main, relationships: [] }],
	}
	xml = "<w:document xmlns:w='http://schemas.openxmlformats.org/wordprocessingml/2006/main'><w:body>${content}</w:body></w:document>"
	Opc.to_bytes(graph, |_| Bytes(xml.to_utf8()))
}

## A document's text is its paragraphs' text in reading order, each followed
## by a line feed: inserted text, tables and content controls included,
## deleted text not.
expect {
	revised = "<w:p><w:r><w:t xml:space='preserve'>Rent is </w:t></w:r><w:del><w:r><w:delText>two</w:delText></w:r></w:del><w:ins><w:r><w:t>three</w:t></w:r></w:ins><w:r><w:tab/><w:t>years.</w:t></w:r></w:p>"
	table = "<w:tbl><w:tr><w:tc><w:p><w:r><w:t>a</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>b</w:t></w:r></w:p></w:tc></w:tr></w:tbl>"
	control = "<w:sdt><w:sdtPr/><w:sdtContent><w:p><w:r><w:t>c</w:t></w:r></w:p></w:sdtContent></w:sdt>"
	parsed = Docx.parse(package_of("${revised}<w:p/>${table}${control}<w:sectPr/>")?)?
	Docx.text(parsed.document) == "Rent is three\tyears.\n\na\nb\nc\n"
}

## Moved-in text is current text and moved-away text is not, with the
## insertions and deletions inside a move applied.
expect {
	moved_away = "<w:moveFrom><w:r><w:t>away</w:t></w:r><w:ins><w:r><w:t>too</w:t></w:r></w:ins></w:moveFrom>"
	moved_in = "<w:moveTo><w:r><w:t>in</w:t></w:r><w:del><w:r><w:delText>gone</w:delText></w:r></w:del><w:ins><w:r><w:t>+</w:t></w:r></w:ins></w:moveTo>"
	parsed = Docx.parse(package_of("<w:p><w:r><w:t>a</w:t></w:r>${moved_away}</w:p><w:p>${moved_in}</w:p>")?)?
	Docx.text(parsed.document) == "a\nin+\n"
}

## A paragraph whose mark is deleted or moved away runs on into the next,
## through a content control but not into or out of a table, row or cell;
## an inserted mark changes nothing.
expect {
	mark = |revision, text| "<w:p><w:pPr><w:rPr><w:${revision}/></w:rPr></w:pPr><w:r><w:t>${text}</w:t></w:r></w:p>"
	plain = |text| "<w:p><w:r><w:t>${text}</w:t></w:r></w:p>"
	control = "<w:sdt><w:sdtContent>${plain("b")}</w:sdtContent></w:sdt>"
	table = "<w:tbl><w:tr><w:tc>${mark("del", "d")}</w:tc><w:tc>${plain("e")}</w:tc></w:tr></w:tbl>"
	body = "${mark("del", "a")}${control}${mark("moveFrom", "c")}${table}${mark("ins", "f")}${mark("del", "g")}"
	parsed = Docx.parse(package_of(body)?)?
	Docx.text(parsed.document) == "ab\nc\nd\ne\nf\ng\n"
}

## A document without a main document part has no blocks and no text.
expect {
	graph = { relationships: [], parts: [{ name: "/data.xml", content_type: "application/xml", relationships: [] }] }
	parsed = Docx.parse(Opc.to_bytes(graph, |_| Bytes("<data/>".to_utf8()))?)?
	Docx.body(parsed.document) == [] and Docx.text(parsed.document) == ""
}

## A paragraph identifier in an extension namespace that is not declared
## ignorable, as Google Docs exports write `w14:paraId`, passes through and is
## written declared ignorable, so the written part reads without a diagnostic.
expect {
	w14 = "http://schemas.microsoft.com/office/word/2010/wordml"
	main = "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"
	graph = {
		relationships: [{ id: "rId1", kind: Opc.officedocument_relationship, target: "/word/document.xml", mode: Internal }],
		parts: [{ name: "/word/document.xml", content_type: main, relationships: [] }],
	}
	xml = "<w:document xmlns:w='http://schemas.openxmlformats.org/wordprocessingml/2006/main' xmlns:w14='${w14}'><w:body><w:p w14:paraId='1A2B3C4D'><w:r><w:t>a</w:t></w:r></w:p></w:body></w:document>"
	parsed = Docx.parse(Opc.to_bytes(graph, |_| Bytes(xml.to_utf8()))?)?
	written = Docx.to_bytes(parsed.document)?
	again = Docx.parse(written)?
	part = Opc.part_bytes(Opc.open(written, {})?, "/word/document.xml")?
	declared = "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:mc=\"http://schemas.openxmlformats.org/markup-compatibility/2006\" xmlns:w14=\"${w14}\" mc:Ignorable=\"w14\"><w:body><w:p w14:paraId=\"1A2B3C4D\">"
	undeclared = |document| Document.main_document(document).map_ok(|tree| Mce.process(tree).diagnostics.len())
	Document.equivalent(parsed.document, again.document)
		and Str.from_utf8(part).map_ok(|text| text.contains(declared)) == Ok(Bool.True)
		and undeclared(parsed.document) == Ok(1)
		and undeclared(again.document) == Ok(0)
}
