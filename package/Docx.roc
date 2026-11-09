## Read a Word document from its bytes, read its body and text, and write it
## back.
##
## `Docx.parse` opens the package within the default `Limits` and reads it as
## a [Document]; `Docx.body` and `Docx.text` read what its body says,
## `Docx.final_text`, `Docx.original_text` and `Docx.revisions` its tracked
## changes, `Docx.footnotes` and `Docx.endnotes` its notes, `Docx.comments`
## its comments, `Docx.people` their authors and `Docx.fields` its fields;
## `Docx.to_bytes` writes a document as a package, its body written from the
## model, and `Docx.equivalent` says whether two documents write the same.
## What reading drops comes back as diagnostics beside the document, never
## printed.
import Comments
import Document
import Mce
import Numbering
import Opc
import Revisions
import Styles
import WmlRead
import WmlWrite
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

	## Why a document cannot be written: the errors of [Document.to_bytes],
	## and a note or comment that a reference or range names and the document
	## does not have, as [WmlWrite.document] reports it.
	WriteError : [
		InvalidPartName(Str),
		DuplicatePart(Str),
		InvalidContentType(Str),
		InvalidRelationship({ source : Str, id : Str }),
		DuplicateRelationshipId({ source : Str, id : Str }),
		NothingPending,
		NotWritten(Str),
		MissingPart(Str),
		TruncatedArchive,
		PartSizeMismatch({ name : Str, declared : U64 }),
		XmlPartUnwritable({ part : Str, problem : XmlTree.WriteError }),
		MissingNote({ kind : Document.NoteKind, note : U64 }),
		MissingComment(U64),
	]

	## Write a document as the bytes of a `.docx`. The main document part is
	## written from the model, as [Docx.body] reads it, by
	## [WmlWrite.document], with the relationships it needs; every other part
	## as [Document.to_bytes] writes it. The same document always gives the
	## same bytes.
	to_bytes : Document -> Try(List(U8), WriteError)
	to_bytes = |document| Ok(Document.to_bytes(as_written(document)?)?)

	## Whether two documents are the same document: the same parts with the
	## same relationships, every part but the main document equivalent as
	## [Document.equivalent] says, and the main document the same when each is
	## written from its model, so that two spellings the model reads alike,
	## and identifiers the writer allocates, make no difference. A document
	## and the document its bytes read back as are equivalent.
	equivalent : Document, Document -> Bool
	equivalent = |one, other|
		match (as_written(one), as_written(other)) {
			(Ok(written), Ok(other_written)) => Document.equivalent(written, other_written)
			_ => Bool.False
		}

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
			Ok(main) => WmlRead.read_body(main.tree, main_context(document, main))
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

	## A document's comments joined with its body by [Comments.anchored]:
	## each comment, read by [WmlRead.comments] from the part the main
	## document's comments relationship targets and threaded by
	## [Comments.threads] from the parts its extended comments, comment
	## identifiers and extensible comments relationships target, with its
	## place in that part and the text it is anchored to, those the body
	## anchors in the order their anchors begin. What reading the comments
	## noticed comes beside them. A document without a comments part has
	## none.
	comments : Document -> { comments : List(Comments.Anchored), diagnostics : List(WmlRead.Diagnostic) }
	comments = |document| {
		read = match comments_part(document) {
			Ok(part) => {
				found = WmlRead.comments(part.tree, { relationships: part.relationships, footnotes: [], endnotes: [], comments: [] })
				parts = { comments: part.tree, extended: main_related_tree(document, comments_extended_relationship), ids: main_related_tree(document, comments_ids_relationship), extensible: main_related_tree(document, comments_extensible_relationship) }
				{ comments: Comments.threads(found.comments, parts), diagnostics: found.diagnostics }
			}

			Err(NotFound) => { comments: [], diagnostics: [] }
		}
		{ comments: Comments.anchored(Docx.body(document), read.comments), diagnostics: read.diagnostics }
	}

	## The people who wrote a document's comments and tracked changes, as
	## [Comments.people] reads them from the part the main document's people
	## relationship targets. A document without the part has none.
	people : Document -> List(Document.Person)
	people = |document| Comments.people(main_related_tree(document, people_relationship))

	## The fields of a document's body, as [Document.fields] gathers them:
	## each field's code and its result as last calculated. The fields of a
	## header or footer, such as its page numbers, are those of its blocks,
	## as [Docx.header_footer] reads them.
	fields : Document -> List(Document.Field)
	fields = |document| Document.fields(Docx.body(document))

	## A document's style table, read from the styles part of its main
	## document by [Styles.read], with what reading did not take as written.
	## A document without a styles part has no styles.
	styles : Document -> { styles : Styles, diagnostics : List(Styles.Diagnostic) }
	styles = |document| {
		found = match Document.related(document, "/", Opc.officedocument_relationship) {
			Ok(main) => Document.related(document, main.name, styles_relationship)
			Err(NotFound) => Err(NotFound)
		}
		match found {
			Ok(part) => Styles.read(part.tree)
			Err(NotFound) => { styles: Styles.empty, diagnostics: [] }
		}
	}

	## The sections of a document's body in order, as [Document.sections]
	## finds them in [Docx.body]. Content after the last section's end, which
	## a document should not have, is in no section.
	sections : Document -> List(Document.Section)
	sections = |document| Document.sections(Docx.body(document))

	## The blocks of the header or footer part named `part`, as a section's
	## [Document.HeaderFooter] names it, read by [WmlRead.header_footer] with
	## the part's own relationships. A part that is not in the document, or
	## is not a header or footer, has no blocks.
	header_footer : Document, Str -> List(Document.Block)
	header_footer = |document, part|
		match Document.xml_part(document, part) {
			Ok(found) => WmlRead.header_footer(found.tree, { relationships: found.relationships, footnotes: [], endnotes: [], comments: comment_ids(document) })
			Err(NotFound) => []
		}

	## A document's core properties, as [WmlRead.core_properties] reads them
	## from the part the package's core properties relationship targets. A
	## document without the part has every property `Unset`.
	core_properties : Document -> Document.CoreProperties
	core_properties = |document| WmlRead.core_properties(properties_tree(document, core_properties_relationship))

	## A document's extended properties, as [WmlRead.extended_properties]
	## reads them from the part the package's extended properties
	## relationship targets. A document without the part has every property
	## `Unset`.
	extended_properties : Document -> Document.ExtendedProperties
	extended_properties = |document| WmlRead.extended_properties(properties_tree(document, extended_properties_relationship))

	## A document's custom properties in order, as
	## [WmlRead.custom_properties] reads them from the part the package's
	## custom properties relationship targets. A document without the part
	## has none.
	custom_properties : Document -> List(Document.CustomProperty)
	custom_properties = |document| WmlRead.custom_properties(properties_tree(document, custom_properties_relationship))

	## A document's numbering table, read from the numbering part of its main
	## document by [Numbering.read], with what reading did not take as
	## written. A document without a numbering part has no lists.
	numbering : Document -> { numbering : Numbering, diagnostics : List(Numbering.Diagnostic) }
	numbering = |document| {
		found = match Document.related(document, "/", Opc.officedocument_relationship) {
			Ok(main) => Document.related(document, main.name, numbering_relationship)
			Err(NotFound) => Err(NotFound)
		}
		match found {
			Ok(part) => Numbering.read(part.tree)
			Err(NotFound) => { numbering: Numbering.empty, diagnostics: [] }
		}
	}

	## The current text of a document's body, its tracked changes as they
	## stand: every paragraph's text, as [Document.paragraph_text] gives it,
	## followed by a line feed, in reading order, including the paragraphs in
	## tables and content controls. A paragraph whose mark is deleted or moved
	## away, as [Document.joins_next] says, runs on into the next paragraph
	## without a line feed, unless a table, row or cell begins or ends between
	## them. Every change the package reads stands as accepting it would
	## leave it, so this is [Docx.final_text].
	text : Document -> Str
	text = |document| Revisions.text(Docx.body(document), Final)

	## The text of a document's body with every tracked change accepted, as
	## [Revisions.text] gives the final text of [Docx.body].
	final_text : Document -> Str
	final_text = |document| Revisions.text(Docx.body(document), Final)

	## The text of a document's body with every tracked change rejected, as
	## [Revisions.text] gives the original text of [Docx.body]: deleted and
	## moved-away text in, inserted and moved-in text out.
	original_text : Document -> Str
	original_text = |document| Revisions.text(Docx.body(document), Original)

	## The tracked changes of a document's body in reading order, as
	## [Revisions.list] finds them in [Docx.body]: each with its kind,
	## author, date, content, text and move.
	revisions : Document -> List(Revisions.Listed)
	revisions = |document| Revisions.list(Docx.body(document))
}

# What reading and writing the main document part need from the rest of the
# package: its relationships and its notes' and comments' identifiers.
main_context : Document, Document.XmlPart -> WmlRead.Context
main_context = |document, main| {
	ids = |kind|
		match Document.related(document, main.name, kind) {
			Ok(part) => WmlRead.note_ids(part.tree)
			Err(NotFound) => []
		}
	{ relationships: main.relationships, footnotes: ids(footnotes_relationship), endnotes: ids(endnotes_relationship), comments: comment_ids(document) }
}

# The document as it is written: its main document part written from the
# model, with the relationships writing it needs.
as_written : Document -> Try(Document, WmlWrite.WriteError)
as_written = |document|
	match Document.related(document, "/", Opc.officedocument_relationship) {
		Ok(main) => {
			context = main_context(document, main)
			written = WmlWrite.document(main.tree, WmlRead.body(main.tree, context), context)?
			Ok(Document.with_part(document, main.name, written.tree, written.relationships))
		}

		Err(NotFound) => Ok(document)
	}

footnotes_relationship : Str
footnotes_relationship = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/footnotes"

endnotes_relationship : Str
endnotes_relationship = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/endnotes"

core_properties_relationship : Str
core_properties_relationship = "http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties"

extended_properties_relationship : Str
extended_properties_relationship = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties"

custom_properties_relationship : Str
custom_properties_relationship = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/custom-properties"

# The tree of the part a package relationship of `kind` targets, or an empty
# one, which holds no properties.
properties_tree : Document, Str -> XmlTree.Node
properties_tree = |document, kind|
	match Document.related(document, "/", kind) {
		Ok(part) => part.tree
		Err(NotFound) => Text("")
	}

# The notes of the part the main document's relationship of `kind` targets.
notes : Document, Str -> List(Document.Note)
notes = |document, kind| {
	found = match Document.related(document, "/", Opc.officedocument_relationship) {
		Ok(main) => Document.related(document, main.name, kind)
		Err(NotFound) => Err(NotFound)
	}
	match found {
		Ok(part) => WmlRead.notes(part.tree, { relationships: part.relationships, footnotes: [], endnotes: [], comments: comment_ids(document) })
		Err(NotFound) => []
	}
}

comments_relationship : Str
comments_relationship = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/comments"

# The comments part of the main document.
comments_part : Document -> Try(Document.XmlPart, [NotFound])
comments_part = |document| {
	main = Document.related(document, "/", Opc.officedocument_relationship)?
	Document.related(document, main.name, comments_relationship)
}

comments_extended_relationship : Str
comments_extended_relationship = "http://schemas.microsoft.com/office/2011/relationships/commentsExtended"

comments_ids_relationship : Str
comments_ids_relationship = "http://schemas.microsoft.com/office/2016/09/relationships/commentsIds"

comments_extensible_relationship : Str
comments_extensible_relationship = "http://schemas.microsoft.com/office/2018/08/relationships/commentsExtensible"

people_relationship : Str
people_relationship = "http://schemas.microsoft.com/office/2011/relationships/people"

# The tree of the part the main document's relationship of `kind` targets,
# or an empty one.
main_related_tree : Document, Str -> XmlTree.Node
main_related_tree = |document, kind| {
	found = match Document.related(document, "/", Opc.officedocument_relationship) {
		Ok(main) => Document.related(document, main.name, kind)
		Err(NotFound) => Err(NotFound)
	}
	match found {
		Ok(part) => part.tree
		Err(NotFound) => Text("")
	}
}

# The identifiers of the comments that ranges and references name, in the
# order of the comments part.
comment_ids : Document -> List(Str)
comment_ids = |document|
	match comments_part(document) {
		Ok(part) => WmlRead.comment_ids(part.tree)
		Err(NotFound) => []
	}

numbering_relationship : Str
numbering_relationship = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering"

styles_relationship : Str
styles_relationship = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles"

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
	revised = "<w:p><w:r><w:t xml:space='preserve'>Rent is </w:t></w:r><w:del w:author='A'><w:r><w:delText>two</w:delText></w:r></w:del><w:ins w:author='A'><w:r><w:t>three</w:t></w:r></w:ins><w:r><w:tab/><w:t>years.</w:t></w:r></w:p>"
	table = "<w:tbl><w:tr><w:tc><w:p><w:r><w:t>a</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>b</w:t></w:r></w:p></w:tc></w:tr></w:tbl>"
	control = "<w:sdt><w:sdtPr/><w:sdtContent><w:p><w:r><w:t>c</w:t></w:r></w:p></w:sdtContent></w:sdt>"
	parsed = Docx.parse(package_of("${revised}<w:p/>${table}${control}<w:sectPr/>")?)?
	Docx.text(parsed.document) == "Rent is three\tyears.\n\na\nb\nc\n"
}

## Moved-in text is current text and moved-away text is not, with the
## insertions and deletions inside a move applied.
expect {
	moved_away = "<w:moveFrom w:author='A'><w:r><w:t>away</w:t></w:r><w:ins w:author='A'><w:r><w:t>too</w:t></w:r></w:ins></w:moveFrom>"
	moved_in = "<w:moveTo w:author='A'><w:r><w:t>in</w:t></w:r><w:del w:author='A'><w:r><w:delText>gone</w:delText></w:r></w:del><w:ins w:author='A'><w:r><w:t>+</w:t></w:r></w:ins></w:moveTo>"
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

## The final text accepts every change and the original text rejects every
## change: deleted and moved-away text, a deleted field's result included, is
## original text, and inserted and moved-in text final text; a paragraph
## whose mark is inserted runs on into the next in the original text, one
## whose mark is deleted in the final text.
expect {
	change = |kind, content| "<w:${kind} w:author='A'>${content}</w:${kind}>"
	run = |text| "<w:r><w:t xml:space='preserve'>${text}</w:t></w:r>"
	field = "<w:r><w:fldChar w:fldCharType='begin'/></w:r><w:r><w:delInstrText> DATE </w:delInstrText></w:r><w:r><w:fldChar w:fldCharType='separate'/></w:r><w:r><w:delText>May</w:delText></w:r><w:r><w:fldChar w:fldCharType='end'/></w:r>"
	due = "<w:p>${run("Due ")}${change("del", field)}${change("ins", run("June"))}${run(".")}</w:p>"
	inserted = "<w:p><w:pPr><w:rPr><w:ins w:author='A'/></w:rPr></w:pPr>${change("ins", run("New"))}</w:p>"
	deleted = "<w:p><w:pPr><w:rPr><w:del w:author='A'/></w:rPr></w:pPr>${run("Old")}</w:p>"
	moved = "<w:p>${change("moveFrom", run("Here"))}${run(" and ")}${change("moveTo", run("there"))}</w:p>"
	parsed = Docx.parse(package_of("${due}${inserted}${deleted}${moved}")?)?
	Docx.final_text(parsed.document) == "Due June.\nNew\nOld and there\n"
		and Docx.original_text(parsed.document) == "Due May.\nOld\nHere and \n"
		and Docx.text(parsed.document) == Docx.final_text(parsed.document)
}

## Tracked changes are listed in reading order with their place, kind,
## author, move and text, a change inside another after it; a move's source
## and destination are paired by their ranges' names; a change follows the
## one before only when nothing comes between them.
expect {
	away = "<w:moveFromRangeStart w:id='1' w:name='m' w:author='B'/><w:moveFrom w:author='B'><w:r><w:t>Away</w:t></w:r><w:ins w:author='C'><w:r><w:t>!</w:t></w:r></w:ins></w:moveFrom><w:moveFromRangeEnd w:id='1'/>"
	inserted = "<w:ins w:author='A'><w:r><w:t>a</w:t></w:r></w:ins><w:ins w:author='A'><w:r><w:t>b</w:t></w:r></w:ins><w:r><w:t>-</w:t></w:r><w:ins w:author='A'><w:r><w:t>c</w:t></w:r></w:ins>"
	arrived = "<w:moveToRangeStart w:id='3' w:name='m' w:author='B'/><w:moveTo w:author='B'><w:r><w:t>Away</w:t></w:r></w:moveTo><w:moveToRangeEnd w:id='3'/><w:moveTo w:author='B'><w:r><w:t>loose</w:t></w:r></w:moveTo>"
	parsed = Docx.parse(package_of("<w:p>${away}${inserted}</w:p><w:tbl><w:tr><w:tc><w:p>${arrived}</w:p></w:tc></w:tr></w:tbl>")?)?
	listed = Docx.revisions(parsed.document).map(|change| (change.id, change.kind, change.author, change.move, change.text, change.follows))
	listed
		== [
			(0, MoveSource, "B", Move("m"), "Away!", Bool.False),
			(1, Insertion, "C", Unpaired, "!", Bool.False),
			(2, Insertion, "A", Unpaired, "a", Bool.False),
			(3, Insertion, "A", Unpaired, "b", Bool.True),
			(4, Insertion, "A", Unpaired, "c", Bool.False),
			(5, MoveDestination, "B", Move("m"), "Away", Bool.False),
			(6, MoveDestination, "B", Unpaired, "loose", Bool.False),
		]
}

## A document without a main document part has no blocks and no text.
expect {
	graph = { relationships: [], parts: [{ name: "/data.xml", content_type: "application/xml", relationships: [] }] }
	parsed = Docx.parse(Opc.to_bytes(graph, |_| Bytes("<data/>".to_utf8()))?)?
	Docx.body(parsed.document) == [] and Docx.text(parsed.document) == ""
}

## An element in an extension namespace that is not declared ignorable, as
## Google Docs exports use `w14`, passes through in its place and is written
## declared ignorable, so the written part reads without a diagnostic; the
## paragraph's `w14:paraId`, an identifier the writer allocates and nothing
## refers to, is not written.
expect {
	w14 = "http://schemas.microsoft.com/office/word/2010/wordml"
	main = "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"
	graph = {
		relationships: [{ id: "rId1", kind: Opc.officedocument_relationship, target: "/word/document.xml", mode: Internal }],
		parts: [{ name: "/word/document.xml", content_type: main, relationships: [] }],
	}
	xml = "<w:document xmlns:w='http://schemas.openxmlformats.org/wordprocessingml/2006/main' xmlns:w14='${w14}'><w:body><w:p w14:paraId='1A2B3C4D'><w:r><w:t>a</w:t><w14:mark/></w:r></w:p></w:body></w:document>"
	parsed = Docx.parse(Opc.to_bytes(graph, |_| Bytes(xml.to_utf8()))?)?
	written = Docx.to_bytes(parsed.document)?
	again = Docx.parse(written)?
	part = Opc.part_bytes(Opc.open(written, {})?, "/word/document.xml")?
	declared = "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:mc=\"http://schemas.openxmlformats.org/markup-compatibility/2006\" xmlns:w14=\"${w14}\" mc:Ignorable=\"w14\"><w:body><w:p><w:r><w:t>a</w:t><w14:mark/></w:r></w:p></w:body>"
	undeclared = |document| Document.main_document(document).map_ok(|tree| Mce.process(tree).diagnostics.len())
	Docx.equivalent(parsed.document, again.document)
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

# A package of two sections, the first with a header and a footer holding a
# page number, the second inheriting them, with core, extended and custom
# properties.
sectioned : {} -> Try(List(U8), Opc.WriteError)
sectioned = |{}| {
	relationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
	declarations = "xmlns:w='http://schemas.openxmlformats.org/wordprocessingml/2006/main' xmlns:r='${relationships}'"
	part = |name, kind| { name, content_type: "application/vnd.openxmlformats-officedocument.${kind}+xml", relationships: [] }
	graph = {
		relationships: [
			{ id: "rId1", kind: Opc.officedocument_relationship, target: "/word/document.xml", mode: Internal },
			{ id: "rId2", kind: core_properties_relationship, target: "/docProps/core.xml", mode: Internal },
			{ id: "rId3", kind: extended_properties_relationship, target: "/docProps/app.xml", mode: Internal },
			{ id: "rId4", kind: custom_properties_relationship, target: "/docProps/custom.xml", mode: Internal },
		],
		parts: [
			{
				name: "/word/document.xml",
				content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml",
				relationships: [
					{ id: "rId7", kind: "${relationships}/header", target: "/word/header1.xml", mode: Internal },
					{ id: "rId8", kind: "${relationships}/footer", target: "/word/footer1.xml", mode: Internal },
				],
			},
			part("/word/header1.xml", "wordprocessingml.header"),
			part("/word/footer1.xml", "wordprocessingml.footer"),
			{ name: "/docProps/core.xml", content_type: "application/vnd.openxmlformats-package.core-properties+xml", relationships: [] },
			part("/docProps/app.xml", "extended-properties"),
			part("/docProps/custom.xml", "custom-properties"),
		],
	}
	references = "<w:headerReference w:type='default' r:id='rId7'/><w:footerReference w:type='default' r:id='rId8'/>"
	body = "<w:p><w:pPr><w:sectPr>${references}<w:pgSz w:w='11906' w:h='16838'/></w:sectPr></w:pPr><w:r><w:t>One</w:t></w:r></w:p><w:p><w:r><w:t>Two</w:t></w:r></w:p><w:sectPr><w:pgSz w:w='16838' w:h='11906' w:orient='landscape'/></w:sectPr>"
	page = "<w:r><w:fldChar w:fldCharType='begin'/></w:r><w:r><w:instrText xml:space='preserve'> PAGE </w:instrText></w:r><w:r><w:fldChar w:fldCharType='separate'/></w:r><w:r><w:t>1</w:t></w:r><w:r><w:fldChar w:fldCharType='end'/></w:r>"
	core = "<cp:coreProperties xmlns:cp='http://schemas.openxmlformats.org/package/2006/metadata/core-properties' xmlns:dc='http://purl.org/dc/elements/1.1/' xmlns:dcterms='http://purl.org/dc/terms/' xmlns:xsi='http://www.w3.org/2001/XMLSchema-instance'><dc:title>Lease</dc:title><dc:creator>Ada Reviewer</dc:creator><cp:revision>3</cp:revision><dcterms:created xsi:type='dcterms:W3CDTF'>2026-11-09T11:03:00Z</dcterms:created></cp:coreProperties>"
	extended = "<Properties xmlns='http://schemas.openxmlformats.org/officeDocument/2006/extended-properties'><Application>Example</Application><Pages>2</Pages></Properties>"
	custom = "<Properties xmlns='http://schemas.openxmlformats.org/officeDocument/2006/custom-properties' xmlns:vt='http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes'><property fmtid='{D5CDD505-2E9C-101B-9397-08002B2CF9AE}' pid='2' name='Matter'><vt:i4>41</vt:i4></property></Properties>"
	Opc.to_bytes(
		graph,
		|name|
			Bytes(
				(
					if name == "/word/document.xml" {
						"<w:document ${declarations}><w:body>${body}</w:body></w:document>"
					} else if name == "/word/header1.xml" {
						"<w:hdr ${declarations}><w:p><w:r><w:t>Draft</w:t></w:r></w:p></w:hdr>"
					} else if name == "/word/footer1.xml" {
						"<w:ftr ${declarations}><w:p><w:r><w:t xml:space='preserve'>Page </w:t></w:r>${page}</w:p></w:ftr>"
					} else if name == "/docProps/core.xml" {
						core
					} else if name == "/docProps/app.xml" {
						extended
					} else {
						custom
					}
				).to_utf8(),
			),
	)
}

## Sections, their headers and footers and the fields in them, and the core,
## extended and custom properties are read through relationships, and are
## read the same from the document as written.
expect {
	parsed = Docx.parse(sectioned({})?)?
	again = Docx.parse(Docx.to_bytes(parsed.document)?)?
	read = |document| {
		sections = Docx.sections(document)
		footer = sections.first().map_ok(|section| section.footers.map(|reference| Document.fields(Docx.header_footer(document, reference.part))))
		{ sections, footer, core: Docx.core_properties(document), extended: Docx.extended_properties(document), custom: Docx.custom_properties(document) }
	}
	first = read(parsed.document)
	match first.sections {
		[opening, closing] =>
			opening.headers == [{ kind: Default, part: "/word/header1.xml" }]
				and closing.headers == []
				and closing.page_size == Size({ width: 16838, height: 11906, orientation: Landscape })
				and first.footer == Ok([[{ code: " PAGE ", result: "1" }]])
				and first.core.title == Text("Lease")
				and first.core.revision == Number(3)
				and first.core.created == Date("2026-11-09T11:03:00Z")
				and first.extended.pages == Count(2)
				and first.custom == [Property({ name: "Matter", value: Integer(41) })]
				and read(again.document) == first
				and Docx.text(parsed.document) == "One\nTwo\n"

		_ => Bool.False
	}
}

# A package whose main document anchors comments of a comments part that
# lists them in another order than their identifiers.
commented : {} -> Try(List(U8), Opc.WriteError)
commented = |{}| {
	relationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
	declarations = "xmlns:w='http://schemas.openxmlformats.org/wordprocessingml/2006/main'"
	graph = {
		relationships: [{ id: "rId1", kind: Opc.officedocument_relationship, target: "/word/document.xml", mode: Internal }],
		parts: [
			{
				name: "/word/document.xml",
				content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml",
				relationships: [{ id: "rId9", kind: "${relationships}/comments", target: "/word/comments.xml", mode: Internal }],
			},
			{ name: "/word/comments.xml", content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.comments+xml", relationships: [] },
		],
	}
	range = |id, text| "<w:commentRangeStart w:id='${id}'/><w:r><w:t>${text}</w:t></w:r><w:commentRangeEnd w:id='${id}'/><w:r><w:commentReference w:id='${id}'/></w:r>"
	body = "<w:p>${range("0", "first")}<w:r><w:t xml:space='preserve'> and </w:t></w:r>${range("1", "second")}</w:p>"
	comment = |id, initials, text| "<w:comment w:id='${id}' w:author='Morgan Reviewer' w:initials='${initials}' w:date='2026-11-09T10:54:16Z'><w:p><w:r><w:t>${text}</w:t></w:r></w:p></w:comment>"
	Opc.to_bytes(
		graph,
		|name|
			if name == "/word/document.xml" {
				Bytes("<w:document ${declarations}><w:body>${body}</w:body></w:document>".to_utf8())
			} else {
				Bytes("<w:comments ${declarations}>${comment("1", "MR", "Later")}${comment("0", "", "Earlier")}</w:comments>".to_utf8())
			},
	)
}

# A block's text when it is a paragraph.
paragraph_of : Document.Block -> Str
paragraph_of = |block|
	match block {
		Paragraph(paragraph) => Document.paragraph_text(paragraph)
		_ => ""
	}

## Comments are found through the main document's relationship, each with its
## place in the comments part, which the body's ranges and references name,
## and the text it covers, in the order their ranges begin; they read the
## same from the document as written.
expect {
	parsed = Docx.parse(commented({})?)?
	again = Docx.parse(Docx.to_bytes(parsed.document)?)?
	read = |document| Docx.comments(document).comments.map(|entry| { id: entry.id, anchor: entry.anchor, initials: entry.comment.initials, text: entry.comment.content.map(paragraph_of) })
	body_ok = match Docx.body(parsed.document) {
		[Paragraph({ properties: _, content: [CommentStart(1), Run(_), CommentEnd(1), Run(_), Run(_), CommentStart(0), Run(_), CommentEnd(0), Run(_)] })] => Bool.True
		_ => Bool.False
	}
	body_ok
		and read(parsed.document) == [{ id: 1, anchor: Range("first"), initials: Initials(""), text: ["Earlier"] }, { id: 0, anchor: Range("second"), initials: Initials("MR"), text: ["Later"] }]
		and read(again.document) == read(parsed.document)
		and Docx.text(parsed.document) == "first and second\n"
}
