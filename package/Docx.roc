## Read a Word document from its bytes, read its body and text, and write it
## back.
##
## `Docx.parse` opens the package within the default `Limits` and reads it as
## a [Document]; `Docx.body` and `Docx.text` read what its body says,
## `Docx.footnotes` and `Docx.endnotes` its notes and `Docx.fields` its fields;
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
		match Document.related(document, "/", Opc.officedocument_relationship) {
			Ok(main) => {
				ids = |kind|
					match Document.related(document, main.name, kind) {
						Ok(notes) => WmlRead.note_ids(notes.tree)
						Err(NotFound) => []
					}
				WmlRead.read_body(main.tree, { relationships: main.relationships, footnotes: ids(footnotes_relationship), endnotes: ids(endnotes_relationship) })
			}

			Err(NotFound) => { blocks: [], diagnostics: [] }
		}

	## A document's footnotes in the order of their part, as [WmlRead.notes]
	## reads them from the part the main document's footnotes relationship
	## targets; a note reference names a note by its place in this list. A
	## document without footnotes has none.
	footnotes : Document -> List(Document.Note)
	footnotes = |document| notes(document, footnotes_relationship)

	## A document's endnotes, as [Docx.footnotes] gives its footnotes.
	endnotes : Document -> List(Document.Note)
	endnotes = |document| notes(document, endnotes_relationship)

	## The fields of a document's body, as [Document.fields] gathers them:
	## each field's code and its result as last calculated.
	fields : Document -> List(Document.Field)
	fields = |document| Document.fields(Docx.body(document))

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

footnotes_relationship : Str
footnotes_relationship = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/footnotes"

endnotes_relationship : Str
endnotes_relationship = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/endnotes"

# The notes of the part the main document's relationship of `kind` targets.
notes : Document, Str -> List(Document.Note)
notes = |document, kind| {
	found = match Document.related(document, "/", Opc.officedocument_relationship) {
		Ok(main) => Document.related(document, main.name, kind)
		Err(NotFound) => Err(NotFound)
	}
	match found {
		Ok(part) => WmlRead.notes(part.tree, { relationships: part.relationships, footnotes: [], endnotes: [] })
		Err(NotFound) => []
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

# A package whose main document holds an inline picture of a media part, a
# footnote reference and a field, with a footnotes part whose note links
# outside through a relationship of its own.
illustrated : List(U8) -> Try(List(U8), Opc.WriteError)
illustrated = |image| {
	relationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
	declarations = "xmlns:w='http://schemas.openxmlformats.org/wordprocessingml/2006/main' xmlns:r='${relationships}' xmlns:wp='http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing' xmlns:a='http://schemas.openxmlformats.org/drawingml/2006/main'"
	graph = {
		relationships: [{ id: "rId1", kind: Opc.officedocument_relationship, target: "/word/document.xml", mode: Internal }],
		parts: [
			{
				name: "/word/document.xml",
				content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml",
				relationships: [
					{ id: "rId7", kind: "${relationships}/image", target: "/word/media/image1.png", mode: Internal },
					{ id: "rId8", kind: "${relationships}/footnotes", target: "/word/footnotes.xml", mode: Internal },
				],
			},
			{
				name: "/word/footnotes.xml",
				content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.footnotes+xml",
				relationships: [{ id: "rId7", kind: "${relationships}/hyperlink", target: "https://example.org/rates", mode: External }],
			},
			{ name: "/word/media/image1.png", content_type: "image/png", relationships: [] },
		],
	}
	picture = "<w:drawing><wp:inline><wp:extent cx='952500' cy='476250'/><wp:docPr id='1' name='Logo'/><a:graphic><a:graphicData uri='http://schemas.openxmlformats.org/drawingml/2006/picture'><a:blip r:embed='rId7'/></a:graphicData></a:graphic></wp:inline></w:drawing>"
	field = "<w:r><w:fldChar w:fldCharType='begin'/><w:instrText xml:space='preserve'> PAGE </w:instrText><w:fldChar w:fldCharType='separate'/><w:t>1</w:t><w:fldChar w:fldCharType='end'/></w:r>"
	body = "<w:p><w:r>${picture}<w:t>Rates</w:t><w:footnoteReference w:id='2'/></w:r>${field}</w:p>"
	footnotes = "<w:footnote w:type='separator' w:id='0'><w:p><w:r><w:separator/></w:r></w:p></w:footnote><w:footnote w:id='2'><w:p><w:r><w:footnoteRef/></w:r><w:hyperlink r:id='rId7'><w:r><w:t>Published</w:t></w:r></w:hyperlink></w:p></w:footnote>"
	Opc.to_bytes(
		graph,
		|name|
			if name == "/word/document.xml" {
				Bytes("<w:document ${declarations}><w:body>${body}</w:body></w:document>".to_utf8())
			} else if name == "/word/footnotes.xml" {
				Bytes("<w:footnotes ${declarations}>${footnotes}</w:footnotes>".to_utf8())
			} else {
				Bytes(image)
			},
	)
}

## A picture names its media part and size, a note reference its place among
## the footnotes, whose hyperlinks resolve through the footnotes part's own
## relationships, and fields give their code and result.
expect {
	parsed = Docx.parse(illustrated([0x89, 0x50, 0x4E, 0x47])?)?
	body_ok = match Docx.body(parsed.document) {
		[Paragraph({ properties: _, content: [Run(r), Run(_)] })] =>
			match r.content {
				[Picture(picture), Text("Rates"), NoteReference(reference)] =>
					picture.media == "/word/media/image1.png" and picture.size == { width: 952500, height: 476250 } and reference == { kind: Footnote, note: 1 }

				_ => Bool.False
			}

		_ => Bool.False
	}
	notes_ok = match Docx.footnotes(parsed.document) {
		[separator, { kind: Note, content: [Paragraph({ properties: _, content: [Run(_), Hyperlink(link)] })] }] =>
			separator.kind == Separator and link.target == External("https://example.org/rates")

		_ => Bool.False
	}
	body_ok and notes_ok and Docx.endnotes(parsed.document) == [] and Docx.fields(parsed.document) == [{ code: " PAGE ", result: "1" }]
}

## A picture's media part is written back byte for byte as it was read.
expect {
	image = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0xFF, 0xFE, 0x3C, 0x26]
	written = Docx.to_bytes(Docx.parse(illustrated(image)?)?.document)?
	Opc.part_bytes(Opc.open(written, {})?, "/word/media/image1.png") == Ok(image)
}
