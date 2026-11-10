## Read a Word document from its bytes, read its body and text, edit its
## text, comments and tracked changes, and write it back.
##
## `Docx.parse` opens the package within the default `Limits` and reads it as
## a [Document], and `Docx.new_document` builds a new one from the default
## document kit; `Docx.body` and `Docx.text` read what its body says,
## `Docx.final_text`, `Docx.original_text` and `Docx.revisions` its tracked
## changes, `Docx.footnotes` and `Docx.endnotes` its notes, `Docx.comments`
## its comments, `Docx.people` their authors, `Docx.fields` its fields and
## `Docx.tracks_revisions` whether it tracks changes;
## `Docx.add_comment`, `Docx.reply`, `Docx.resolve` and
## `Docx.remove_comment` edit its comments; `Docx.accept`, `Docx.reject`,
## `Docx.accept_all` and `Docx.reject_all` its tracked changes;
## `Docx.replace_text`, `Docx.insert_text` and `Docx.delete_text` its text,
## and `Docx.insert_blocks` and `Docx.delete_blocks` its paragraphs and
## tables, silently or as tracked changes; `Docx.set_tracking` whether it
## tracks changes;
## `Docx.to_bytes` writes a document as a package, its body written from the
## model, and `Docx.equivalent` says whether two documents write the same.
## What reading drops comes back as diagnostics beside the document, never
## printed.
import Comments
import Document
import Kit
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
	## The body is read one block at a time by [WmlRead.body_reader] and kept
	## as the model, as [Document.from_package_with_body] reads it, so no
	## tree of the whole body is held beside it.
	parse : List(U8) -> Try({ document : Document, diagnostics : List(Document.Diagnostic) }, ParseError)
	parse = |bytes| Ok(Document.from_package_with_body(Opc.open(bytes, {})?, {}, |document, main| WmlRead.body_reader(main_context(document, main.name, main.relationships)))?)

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
		CommentWithoutParagraph(U64),
	]

	## A new document from the default document kit, as [Kit.document]
	## builds it: an empty page, the kit's styles and lists, settings, a font
	## table, and the title, author and dates `properties` gives as its core
	## properties; or the date it gives that is not in the W3C date and time
	## format. `Docx.new_document({})` is a document with no properties, and
	## `Docx.new_document({ title: Text("Lease"), created: Date("2026-11-10T09:00:00Z") })`
	## names only what it has.
	new_document : Kit.New -> Try(Document, [NotADate(Str)])
	new_document = |properties| Kit.document(properties)

	## Write a document as the bytes of a `.docx`. The main document part is
	## written from the model, as [Docx.body] reads it, by
	## [WmlWrite.document], its footnotes and endnotes parts from
	## [Docx.footnotes] and [Docx.endnotes] by [WmlWrite.notes], and each
	## header and footer part it relates to from [Docx.header_footer] by
	## [WmlWrite.header_footer], each with the relationships it needs; every
	## other part as [Document.to_bytes] writes it. The same document always
	## gives the same bytes.
	to_bytes : Document -> Try(List(U8), WriteError)
	to_bytes = |document| Ok(Document.to_bytes(as_written(document)?)?)

	## Whether two documents are the same document: the same parts with the
	## same relationships, every part [Docx.to_bytes] writes from the model
	## (the main document, its notes, headers and footers) the same when each
	## is written from its model, so that two spellings the model reads
	## alike, and identifiers the writer allocates, make no difference, and
	## every other part equivalent as [Document.equivalent] says. A document
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
		match Document.body(document) {
			Ok(read) => read
			Err(Whole) =>
				match Document.related(document, "/", Opc.officedocument_relationship) {
					Ok(main) => WmlRead.read_body(main.tree, main_context(document, main.name, main.relationships))
					Err(NotFound) => { blocks: [], diagnostics: [] }
				}
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
	## noticed comes beside them, with the entries of the parts beside them
	## that the model does not hold as [Comments.kept] finds them. A document
	## without a comments part has none.
	comments : Document -> { comments : List(Comments.Anchored), diagnostics : List(WmlRead.Diagnostic) }
	comments = |document| {
		read = threads(document)
		{ comments: Comments.anchored(Docx.body(document), read.comments), diagnostics: List.concat(read.diagnostics, read.kept.diagnostics) }
	}

	## The people who wrote a document's comments and tracked changes, as
	## [Comments.people] reads them from the part the main document's people
	## relationship targets, with a diagnostic for each presence it does not
	## apply. A document without the part has none.
	people : Document -> { people : List(Document.Person), diagnostics : List(WmlRead.Diagnostic) }
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
			Ok(found) => WmlRead.header_footer(found.tree, part_context(found, comment_ids(document)))
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
	## them. A deleted row or cell is still there, without the text deleted
	## from it, as [Revisions.text] gives the current text.
	text : Document -> Str
	text = |document| Revisions.text(Docx.body(document), Current)

	## The text of a document's body with every tracked change accepted, as
	## [Revisions.text] gives the final text of [Docx.body]: deleted text,
	## rows and cells out, and a paragraph whose mark is deleted run on into
	## the next.
	final_text : Document -> Str
	final_text = |document| Revisions.text(Docx.body(document), Final)

	## The text of a document's body with every tracked change rejected, as
	## [Revisions.text] gives the original text of [Docx.body]: deleted and
	## moved-away text in, inserted and moved-in text, inserted rows and
	## cells out, and a paragraph whose mark is inserted run on into the
	## next.
	original_text : Document -> Str
	original_text = |document| Revisions.text(Docx.body(document), Original)

	## The tracked changes of a document's body in reading order, as
	## [Revisions.list] finds them in [Docx.body]: each with its kind, what
	## it changed, its author, date, content, text and move.
	revisions : Document -> List(Revisions.Listed)
	revisions = |document| Revisions.list(Docx.body(document))

	## Whether a document records changes as tracked changes when it is
	## edited, as [WmlRead.tracks_revisions] reads it from the settings part
	## of its main document. A document without the part does not.
	tracks_revisions : Document -> Bool
	tracks_revisions = |document| WmlRead.tracks_revisions(main_related_tree(document, settings_relationship))

	## Why a document cannot be edited: it has no main document part; the
	## span is not within the text, ends before it starts, or starts or ends
	## inside a character, as [Comments.mark] and [Revisions.replace] say;
	## a text edit's span holds a line feed it cannot take away, as
	## [Revisions.replace] says; no block begins or ends where a block edit
	## asks, or its paragraphs would have no paragraph to join, as
	## [Revisions.insert_blocks] and [Revisions.delete_blocks] say; no
	## comment has the place; a date is not a date and time; or the document
	## cannot be written, as [Docx.WriteError] says.
	EditError : [
		NoMainDocument,
		OutsideText({ start : U64, end : U64 }),
		NotACharacterBoundary(U64),
		LineFeedInSpan({ start : U64, end : U64 }),
		NotABlockBoundary(U64),
		NoParagraphToJoin(U64),
		NoSuchComment(U64),
		NotADate(Str),
		MissingNote({ kind : Document.NoteKind, note : U64 }),
		MissingComment(U64),
		CommentWithoutParagraph(U64),
	]

	## The document with a new comment around `span` of its current text, as
	## [Comments.mark] places it, and the comment's `id`, its place among the
	## comments, after every comment the document has. The document is
	## written as [Docx.to_bytes] writes it, with a comments part where it
	## had none. A document with a people part gains the comment's author
	## there when the part has no person by that name, as Word records an
	## author who signed in to no account: with the presence of provider
	## `None` and the author as the identifier. A document without a people
	## part is not given one.
	add_comment : Document, Comments.Span, Comments.New -> Try({ document : Document, id : U64 }, EditError)
	add_comment = |document, span, new| {
		_ = main_part(document)?
		read = threads(document)
		id = read.comments.len()
		marked = Comments.mark(Docx.body(document), id, span)?
		comment = Comments.comment(new)?
		edited = written_with(document, { body: marked, comments: List.append(read.comments, comment), kept: read.kept, places: [] })?
		Ok({ document: with_author(edited, comment.author), id })
	}

	## The document with a reply to the comment `to`, and the reply's `id`,
	## after every comment the document has. The reply's range starts and
	## ends just after its parent's, and its reference follows its
	## parent's, wherever they are. The document is written as
	## [Docx.to_bytes] writes it, with an extended comments part where it had
	## none, so the reply is a reply, and gains the reply's author in its
	## people part as [Docx.add_comment] says.
	reply : Document, U64, Comments.New -> Try({ document : Document, id : U64 }, EditError)
	reply = |document, to, new| {
		_ = main_part(document)?
		read = threads(document)
		if to >= read.comments.len() {
			return Err(NoSuchComment(to))
		}
		id = read.comments.len()
		comment = Comments.comment(new)?
		places = List.set(unchanged(read.comments), to, [to, id]) ?? []
		edited = written_with(document, { body: Comments.relabel(Docx.body(document), places), comments: List.append(read.comments, { ..comment, parent: Parent(to) }), kept: read.kept, places })?
		Ok({ document: with_author(edited, comment.author), id })
	}

	## The document with the thread of the comment `id` resolved: every
	## comment in it, from the comment its replies lead up to, marked done,
	## as Word marks a thread. The document is written as [Docx.to_bytes]
	## writes it, with an extended comments part where it had none.
	resolve : Document, U64 -> Try(Document, EditError)
	resolve = |document, id| {
		_ = main_part(document)?
		read = threads(document)
		if id >= read.comments.len() {
			return Err(NoSuchComment(id))
		}
		thread = Comments.thread(read.comments, id)
		var $comments = List.with_capacity(read.comments.len())
		var $place = 0.U64
		for comment in read.comments {
			$comments = List.append($comments, if (thread.contains($place)) { ..comment, resolved: Bool.True } else comment)
			$place = $place + 1
		}
		written_with(document, { body: Docx.body(document), comments: $comments, kept: read.kept, places: [] })
	}

	## The document without the comment `id` and its replies, and the replies
	## to those, with their ranges' boundaries and their references, in the
	## body, its notes and its headers and footers, and their entries in the
	## parts beside the comments part. A reply is not left without what it
	## replies to. The comments after a removed one move up to its place, so
	## their ids change: [Docx.comments] gives them again.
	remove_comment : Document, U64 -> Try(Document, EditError)
	remove_comment = |document, id| {
		_ = main_part(document)?
		read = threads(document)
		if id >= read.comments.len() {
			return Err(NoSuchComment(id))
		}
		removed = Comments.replies(read.comments, id)
		var $places = List.with_capacity(read.comments.len())
		var $next = 0.U64
		var $place = 0.U64
		for _ in read.comments {
			if removed.contains($place) {
				$places = List.append($places, [])
			} else {
				$places = List.append($places, [$next])
				$next = $next + 1
			}
			$place = $place + 1
		}
		var $comments = List.with_capacity($next)
		$place = 0
		for comment in read.comments {
			if !removed.contains($place) {
				parent = match comment.parent {
					Parent(above) =>
						match $places.get(above) {
							Ok([moved]) => Parent(moved)
							_ => Unset
						}

					Unset => Unset
				}
				$comments = List.append($comments, { ..comment, parent })
			}
			$place = $place + 1
		}
		written_with(document, { body: Comments.relabel(Docx.body(document), $places), comments: $comments, kept: read.kept, places: $places })
	}

	## The document with the selected tracked changes accepted, as
	## [Revisions.accept] accepts them, in [Docx.body], in its notes, in its
	## headers and footers and in its comments, and written as
	## [Docx.to_bytes] writes it. Changes selected by id are the body's:
	## ids are those of [Docx.revisions], which lists the body's changes, so
	## once changes go the others' ids change and [Docx.revisions] gives them
	## again. Every other selection applies to every part.
	accept : Document, Revisions.Selection -> Try(Document, EditError)
	accept = |document, selection| resolved_everywhere(document, |blocks, in_part| Revisions.accept(blocks, if (in_part) beside_body(selection) else selection))

	## The document with the selected tracked changes rejected, as
	## [Revisions.reject] rejects them, where [Docx.accept] accepts them.
	reject : Document, Revisions.Selection -> Try(Document, EditError)
	reject = |document, selection| resolved_everywhere(document, |blocks, in_part| Revisions.reject(blocks, if (in_part) beside_body(selection) else selection))

	## The document with every tracked change accepted: its text is the
	## final text, [Docx.final_text], of the document it came from.
	accept_all : Document -> Try(Document, EditError)
	accept_all = |document| Docx.accept(document, All)

	## The document with every tracked change rejected: its text is the
	## original text, [Docx.original_text], of the document it came from.
	reject_all : Document -> Try(Document, EditError)
	reject_all = |document| Docx.reject(document, All)

	## The document with `span` of its current text, byte offsets into
	## [Docx.text], replaced by `replacement`, as [Revisions.replace] replaces it in
	## the body: silently, or as tracked changes by the author the context
	## names, at its date. The document is written as [Docx.to_bytes]
	## writes it. Positions after the span move by the difference in length
	## between `replacement` and the span's text; positions before it stay.
	replace_text : Document, Comments.Span, Str, Revisions.Context -> Try(Document, EditError)
	replace_text = |document, span, replacement, context| {
		_ = main_part(document)?
		read = threads(document)
		written_with(document, { body: Revisions.replace(Docx.body(document), span, replacement, context)?, comments: read.comments, kept: read.kept, places: [] })
	}

	## The document with `inserted` at byte `at` of its current text,
	## as [Docx.replace_text] replaces an empty span there.
	insert_text : Document, U64, Str, Revisions.Context -> Try(Document, EditError)
	insert_text = |document, at, inserted, context| Docx.replace_text(document, { start: at, end: at }, inserted, context)

	## The document without `span` of its current text, as
	## [Docx.replace_text] replaces it with nothing.
	delete_text : Document, Comments.Span, Revisions.Context -> Try(Document, EditError)
	delete_text = |document, span, context| Docx.replace_text(document, span, "", context)

	## The document with `blocks` inserted in its body where a paragraph or
	## table begins at byte `at` of its current text, or at its end, as
	## [Revisions.insert_blocks] inserts them: silently, or as tracked
	## changes by the author the context names, at its date. The document is
	## written as [Docx.to_bytes] writes it. Positions from `at` move by the
	## length of the new blocks' text.
	insert_blocks : Document, U64, List(Document.Block), Revisions.Context -> Try(Document, EditError)
	insert_blocks = |document, at, blocks, context| {
		_ = main_part(document)?
		read = threads(document)
		written_with(document, { body: Revisions.insert_blocks(Docx.body(document), at, blocks, context)?, comments: read.comments, kept: read.kept, places: [] })
	}

	## The document without the paragraphs and tables of its body from byte
	## `start` of its current text, where one begins, to byte `end`, where
	## one ends, as [Revisions.delete_blocks] deletes them: silently, or as
	## tracked changes. The document is written as [Docx.to_bytes] writes it.
	delete_blocks : Document, Comments.Span, Revisions.Context -> Try(Document, EditError)
	delete_blocks = |document, span, context| {
		_ = main_part(document)?
		read = threads(document)
		written_with(document, { body: Revisions.delete_blocks(Docx.body(document), span, context)?, comments: read.comments, kept: read.kept, places: [] })
	}

	## The document with tracking `On`, so that its editor records edits as
	## tracked changes, or `Off`, as [WmlWrite.tracking] sets it in the
	## settings part of its main document; a document without settings that
	## is to track changes is given a settings part. Tracking is the
	## editor's setting: it changes no content, and the package's own edits
	## are tracked or not by their context.
	set_tracking : Document, [On, Off] -> Try(Document, EditError)
	set_tracking = |document, state| {
		main = main_part(document)?
		match Document.related(document, main.name, settings_relationship) {
			Ok(part) => Ok(Document.with_part(document, part.name, WmlWrite.tracking(part.tree, state), part.relationships))
			Err(NotFound) =>
				match state {
					On => Ok(new_part(document, settings_relationship, WmlWrite.tracking(Text(""), On)).document)
					Off => Ok(document)
				}
		}
	}
}

# The document with its tracked changes resolved by `resolve`: in the body,
# then, told that they are not the body's, in its notes, headers, footers
# and comments, each part written from its model.
resolved_everywhere : Document, (List(Document.Block), Bool -> Try(List(Document.Block), [NotADate(Str)])) -> Try(Document, EditError)
resolved_everywhere = |document, resolve| {
	main = main_part(document)?
	body = resolve(Docx.body(document), Bool.False)?
	read_ids = comment_ids(document)
	var $document = document
	for kind in [footnotes_relationship, endnotes_relationship] {
		match Document.related(document, main.name, kind) {
			Ok(part) => {
				context = part_context(part, read_ids)
				var $notes = List.with_capacity(8)
				for note in WmlRead.notes(part.tree, context) {
					$notes = List.append($notes, { ..note, content: resolve(note.content, Bool.True)? })
				}
				written = WmlWrite.notes(part.tree, $notes, writing(context, read_ids, Set.with_capacity(0), 0))?
				$document = Document.with_part($document, part.name, written.tree, written.relationships)
			}

			Err(NotFound) => {}
		}
	}
	for relationship in main.relationships {
		if relationship.mode == Internal and (relationship.kind == header_relationship or relationship.kind == footer_relationship) {
			match Document.xml_part(document, relationship.target) {
				Ok(part) => {
					context = part_context(part, read_ids)
					written = WmlWrite.header_footer(part.tree, resolve(WmlRead.header_footer(part.tree, context), Bool.True)?, writing(context, read_ids, Set.with_capacity(0), 0))?
					$document = Document.with_part($document, part.name, written.tree, written.relationships)
				}

				Err(NotFound) => {}
			}
		}
	}
	read = threads($document)
	var $comments = List.with_capacity(read.comments.len())
	for comment in read.comments {
		$comments = List.append($comments, { ..comment, content: resolve(comment.content, Bool.True)? })
	}
	written_with($document, { body, comments: $comments, kept: read.kept, places: [] })
}

# A selection as it applies beside the body: ids name the body's changes
# only, so they select none there.
beside_body : Revisions.Selection -> Revisions.Selection
beside_body = |selection|
	match selection {
		Ids(_) => Ids([])
		_ => selection
	}

# The main document part, which every edit needs.
main_part : Document -> Try(Document.XmlPart, [NoMainDocument])
main_part = |document| Document.related(document, "/", Opc.officedocument_relationship).map_err(|_| NoMainDocument)

# Every comment keeping its place.
unchanged : List(Document.Comment) -> List(List(U64))
unchanged = |comments| {
	var $places = List.with_capacity(comments.len())
	var $place = 0.U64
	for _ in comments {
		$places = List.append($places, [$place])
		$place = $place + 1
	}
	$places
}

# What a document is written with: its body, its comments in their places,
# the entries beside the comments part kept as read, and where each
# comment's boundaries and references in the notes, headers and footers go,
# as [Comments.relabel] takes them, or nothing where they stay.
Written : { body : List(Document.Block), comments : List(Document.Comment), kept : Comments.Kept, places : List(List(U64)) }

# What reading and writing the main document part need from the rest of the
# package: its relationships and its notes' and comments' identifiers.
main_context : Document, Str, List(Opc.Relationship) -> WmlRead.Context
main_context = |document, name, relationships| {
	ids = |kind|
		match Document.related(document, name, kind) {
			Ok(part) => WmlRead.note_ids(part.tree)
			Err(NotFound) => []
		}
	comments = match Document.related(document, name, comments_relationship) {
		Ok(part) => WmlRead.comment_ids(part.tree)
		Err(NotFound) => []
	}
	{ relationships, footnotes: ids(footnotes_relationship), endnotes: ids(endnotes_relationship), comments }
}

# What reading and writing a notes, header or footer part need: its
# relationships and the comments' identifiers. Notes are not referred to from
# them.
part_context : Document.XmlPart, List(Str) -> WmlRead.Context
part_context = |part, comments| { relationships: part.relationships, footnotes: [], endnotes: [], comments }

# What writing a part needs: what reading it needs, with the comments'
# identifiers it is written with, the identifiers kept content anywhere in
# the document uses and the lowest number its own may take.
writing : WmlRead.Context, List(Str), Set(Str), U64 -> WmlWrite.Context
writing = |context, comments, reserved, from| { relationships: context.relationships, footnotes: context.footnotes, endnotes: context.endnotes, comments, reserved, from }

# A part beside the main document written from the model: a footnotes or
# endnotes part and its notes, or a header or footer and its blocks.
Story : { part : Document.XmlPart, content : [Notes(List(Document.Note)), Region(List(Document.Block))] }

# The document as it is written: its main document part, its notes parts and
# the header and footer parts it relates to written from the model, with the
# relationships writing them needs, then its comments and the parts beside
# them written from their threads. Comments take the identifiers
# [WmlWrite.comment_ids] allocates, avoiding what content kept in any part
# uses, and every part's ranges and references name them by those; the
# parts' bookmarks and tracked changes share one space of identifiers across
# the document, each part taking its numbers after the part written before
# it.
as_written : Document -> Try(Document, WmlWrite.WriteError)
as_written = |document| {
	read = threads(document)
	written_with(document, { body: Docx.body(document), comments: read.comments, kept: read.kept, places: [] })
}

# The document written as [as_written] writes it, from this body and these
# comments, with the comments' boundaries and references in its notes,
# headers and footers taking their places.
written_with : Document, Written -> Try(Document, WmlWrite.WriteError)
written_with = |document, change| {
	main = match Document.related(document, "/", Opc.officedocument_relationship) {
		Ok(found) => found
		Err(NotFound) => return Ok(document)
	}
	read_ids = comment_ids(document)
	moved = |blocks| if (change.places.is_empty()) blocks else Comments.relabel(blocks, change.places)
	var $stories = List.with_capacity(0)
	for kind in [footnotes_relationship, endnotes_relationship] {
		match Document.related(document, main.name, kind) {
			Ok(part) => {
				read_notes = WmlRead.notes(part.tree, part_context(part, read_ids))
				placed = if (change.places.is_empty()) read_notes else read_notes.map(|note| { ..note, content: Comments.relabel(note.content, change.places) })
				$stories = List.append($stories, { part, content: Notes(placed) })
			}

			Err(NotFound) => {}
		}
	}
	for relationship in main.relationships {
		if relationship.mode == Internal and (relationship.kind == header_relationship or relationship.kind == footer_relationship) {
			match Document.xml_part(document, relationship.target) {
				Ok(part) => {
					$stories = List.append($stories, { part, content: Region(moved(WmlRead.header_footer(part.tree, part_context(part, read_ids)))) })
				}

				Err(NotFound) => {}
			}
		}
	}
	in_parts = $stories.fold(WmlWrite.kept_ids(Set.with_capacity(8), change.body), kept_in)
	kept = change.comments.fold(in_parts, |found, comment| WmlWrite.kept_ids(found, comment.content))
	comments = WmlWrite.comment_ids(kept, change.comments)
	written = WmlWrite.document(main.tree, change.body, writing(main_context(document, main.name, main.relationships), comments, kept, 0))?
	var $document = Document.with_part(document, main.name, written.tree, written.relationships)
	var $next = written.next
	for story in $stories {
		context = writing(part_context(story.part, comments), comments, kept, $next)
		out = match story.content {
			Notes(listed) => WmlWrite.notes(story.part.tree, listed, context)?
			Region(blocks) => WmlWrite.header_footer(story.part.tree, blocks, context)?
		}
		$document = Document.with_part($document, story.part.name, out.tree, out.relationships)
		$next = out.next
	}
	with_comments($document, change.comments, change.kept, comments)
}

# `found` with the identifiers content kept in a story uses.
kept_in : Set(Str), Story -> Set(Str)
kept_in = |found, story|
	match story.content {
		Notes(listed) => listed.fold(found, |inner, note| WmlWrite.kept_ids(inner, note.content))
		Region(blocks) => WmlWrite.kept_ids(found, blocks)
	}

header_relationship : Str
header_relationship = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/header"

footer_relationship : Str
footer_relationship = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer"

# The document with its comments part written from `comments`, taking `ids`,
# and its extended comments, comment identifiers, extensible comments and
# people parts written from the model, each where the document has it. The
# comments' identifiers avoid those of every other part. A document with
# comments and without a comments part is given one, and one whose comments
# have threads, durable identifiers or UTC dates to write and that has no
# part for them is given the part, as [new_part] names it.
with_comments : Document, List(Document.Comment), Comments.Kept, List(Str) -> Try(Document, WmlWrite.WriteError)
with_comments = |document, comments, kept, ids| {
	people = match Document.related(document, main_name(document), people_relationship) {
		Ok(part) => Document.with_part(document, part.name, Comments.people_part(part.tree, Comments.people(part.tree).people), part.relationships)
		Err(NotFound) => document
	}
	{ document: with_part, part } = match comments_part(people) {
		Ok(found) => { document: people, part: found }
		Err(NotFound) if comments.is_empty() => return Ok(people)
		Err(NotFound) => {
			added = new_part(people, comments_relationship, Text(""))
			{ document: added.document, part: { name: added.name, tree: Text(""), relationships: [] } }
		}
	}
	rewritten = [part.name, related_name(with_part, comments_extended_relationship), related_name(with_part, comments_ids_relationship)]
	others = Document.xml_parts(with_part).drop_if(|other| rewritten.contains(other.name)).map(|other| other.tree)
	taken = WmlWrite.taken(List.join([others, kept.extended, kept.ids]))
	written = WmlWrite.comments(part.tree, comments, { relationships: part.relationships, footnotes: [], endnotes: [], comments: ids }, taken)?
	shells = { extended: main_related_tree(with_part, comments_extended_relationship), ids: main_related_tree(with_part, comments_ids_relationship), extensible: main_related_tree(with_part, comments_extensible_relationship) }
	split = Comments.split(comments, written.paragraphs, shells, kept)
	with_comments_part = Document.with_part(with_part, part.name, written.tree, written.relationships)
	threaded = comments.any(|comment| comment.parent != Unset or comment.resolved)
	durable = comments.any(|comment| comment.durable_id != Unset)
	dated = comments.any(|comment| comment.durable_id != Unset and comment.utc_date != Unset)
	with_extended = rewrite(with_comments_part, comments_extended_relationship, split.extended, threaded)
	with_ids = rewrite(with_extended, comments_ids_relationship, split.ids, durable)
	Ok(rewrite(with_ids, comments_extensible_relationship, split.extensible, dated))
}

# The document with `author` after the people of its people part, as Word
# records a new author, where it has the part and no person there has the
# name.
with_author : Document, Str -> Document
with_author = |document, author|
	match Document.related(document, main_name(document), people_relationship) {
		Ok(part) => {
			people = Comments.people(part.tree).people
			if people.any(|person| person.author == author) {
				document
			} else {
				Document.with_part(document, part.name, Comments.people_part(part.tree, List.append(people, { author, presence: Presence({ provider: "None", user: author }) })), part.relationships)
			}
		}

		Err(NotFound) => document
	}

# The document with a new part of a kind the comments or the tracking state
# need, related from the main document: the comments part, `comments.xml`,
# the extended comments, comment identifiers or extensible comments part,
# `commentsExtended.xml`, `commentsIds.xml` or `commentsExtensible.xml`, or
# the settings part, `settings.xml`, beside the main document,
# with the content type Word gives it, a number after the name when the
# document already has a part by that name; and the part's name.
new_part : Document, Str, XmlTree.Node -> { document : Document, name : Str }
new_part = |document, kind, tree| {
	local = if kind == comments_relationship {
		"comments"
	} else if kind == settings_relationship {
		"settings"
	} else if kind == comments_extended_relationship {
		"commentsExtended"
	} else if kind == comments_ids_relationship {
		"commentsIds"
	} else {
		"commentsExtensible"
	}
	main = main_name(document)
	directory = match main.split_last("/") {
		Ok({ before, after: _ }) => before
		Err(_) => ""
	}
	var $name = "${directory}/${local}.xml"
	var $number = 1.U64
	while Document.xml_parts(document).any(|part| part.name == $name) {
		$number = $number + 1
		$name = "${directory}/${local}${$number.to_str()}.xml"
	}
	content_type = "application/vnd.openxmlformats-officedocument.wordprocessingml.${local}+xml"
	{ document: Document.with_new_part(document, { source: main, kind, name: $name, content_type }, tree), name: $name }
}

# The document with the part the main document's relationship of `kind`
# targets holding `tree`, where it has one, or with a new part holding it,
# as [new_part] adds it, where it has none and `needed`.
rewrite : Document, Str, XmlTree.Node, Bool -> Document
rewrite = |document, kind, tree, needed|
	match Document.related(document, main_name(document), kind) {
		Ok(part) => Document.with_part(document, part.name, tree, part.relationships)
		Err(NotFound) if needed => new_part(document, kind, tree).document
		Err(NotFound) => document
	}

# The name of the part the main document's relationship of `kind` targets,
# or the empty string where there is none.
related_name : Document, Str -> Str
related_name = |document, kind|
	match Document.related(document, main_name(document), kind) {
		Ok(part) => part.name
		Err(NotFound) => ""
	}

# The name of the main document part, or the package's own `/` when there is
# none, which no part's relationship is.
main_name : Document -> Str
main_name = |document|
	match Document.related(document, "/", Opc.officedocument_relationship) {
		Ok(main) => main.name
		Err(NotFound) => "/"
	}

# The comments of a document's comments part, as [WmlRead.comments] reads
# them, threaded by [Comments.threads] from the parts the main document's
# extended comments, comment identifiers and extensible comments
# relationships target, with what reading them noticed.
threads : Document -> { comments : List(Document.Comment), kept : Comments.Kept, diagnostics : List(WmlRead.Diagnostic) }
threads = |document|
	match comments_part(document) {
		Ok(part) => {
			found = WmlRead.comments(part.tree, { relationships: part.relationships, footnotes: [], endnotes: [], comments: [] })
			parts = { comments: part.tree, extended: main_related_tree(document, comments_extended_relationship), ids: main_related_tree(document, comments_ids_relationship), extensible: main_related_tree(document, comments_extensible_relationship) }
			{ comments: Comments.threads(found.comments, parts), kept: Comments.kept(parts), diagnostics: found.diagnostics }
		}

		Err(NotFound) => { comments: [], kept: { extended: [], ids: [], extensible: [], diagnostics: [] }, diagnostics: [] }
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
		Ok(part) => WmlRead.notes(part.tree, part_context(part, comment_ids(document)))
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

settings_relationship : Str
settings_relationship = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings"

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
	mark = |revision, text| "<w:p><w:pPr><w:rPr><w:${revision} w:author='A'/></w:rPr></w:pPr><w:r><w:t>${text}</w:t></w:r></w:p>"
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
	away = "<w:moveFromRangeStart w:id='1' w:name='m' w:author='B' w:date='2026-05-07T09:00:00Z'/><w:moveFrom w:author='B'><w:r><w:t>Away</w:t></w:r><w:ins w:author='C'><w:r><w:t>!</w:t></w:r></w:ins></w:moveFrom><w:moveFromRangeEnd w:id='1'/>"
	inserted = "<w:ins w:author='A'><w:r><w:t>a</w:t></w:r></w:ins><w:ins w:author='A'><w:r><w:t>b</w:t></w:r></w:ins><w:r><w:t>-</w:t></w:r><w:ins w:author='A'><w:r><w:t>c</w:t></w:r></w:ins>"
	arrived = "<w:moveToRangeStart w:id='3' w:name='m' w:author='B' w:date='2026-05-07T09:00:00Z'/><w:moveTo w:author='B'><w:r><w:t>Away</w:t></w:r></w:moveTo><w:moveToRangeEnd w:id='3'/><w:moveTo w:author='B'><w:r><w:t>loose</w:t></w:r></w:moveTo>"
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

## A deleted row or cell is current text but not final text, and an
## inserted one is not original text; changes of paragraph marks, rows,
## cells and properties are listed in reading order with what they changed,
## and a change in the next paragraph follows a change of a mark.
expect {
	formatted = "<w:p><w:pPr><w:rPr><w:ins w:author='E'/></w:rPr><w:pPrChange w:author='F'><w:pPr/></w:pPrChange></w:pPr><w:r><w:rPr><w:b/><w:rPrChange w:author='G'><w:rPr/></w:rPrChange></w:rPr><w:t>p</w:t></w:r></w:p>"
	following = "<w:p><w:ins w:author='E'><w:r><w:t>q</w:t></w:r></w:ins></w:p>"
	row = |properties, cells| "<w:tr><w:trPr>${properties}</w:trPr>${cells}</w:tr>"
	cell = |properties, text| "<w:tc><w:tcPr>${properties}</w:tcPr><w:p><w:r><w:t>${text}</w:t></w:r></w:p></w:tc>"
	rows = [row("<w:ins w:author='A'/>", cell("", "new")), row("<w:del w:author='B'/>", cell("", "old")), row("", Str.concat(cell("<w:cellIns w:author='C'/>", "in"), cell("<w:cellDel w:author='D'/>", "out")))]
	parsed = Docx.parse(package_of("${formatted}${following}<w:tbl>${Str.join_with(rows, "")}</w:tbl>")?)?
	listed = Docx.revisions(parsed.document).map(|change| (change.id, change.kind, change.of, change.author, change.text, change.follows))
	Docx.text(parsed.document) == "p\nq\nnew\nold\nin\nout\n"
		and Docx.final_text(parsed.document) == "p\nq\nnew\nin\n"
		and Docx.original_text(parsed.document) == "p\nold\nout\n"
		and listed
			== [
				(0, Formatting, Paragraph, "F", "p", Bool.False),
				(1, Formatting, Run, "G", "p", Bool.False),
				(2, Insertion, ParagraphMark, "E", "\n", Bool.True),
				(3, Insertion, Content, "E", "q", Bool.True),
				(4, Insertion, Row, "A", "", Bool.False),
				(5, Deletion, Row, "B", "", Bool.False),
				(6, Insertion, Cell, "C", "", Bool.False),
				(7, Deletion, Cell, "D", "", Bool.False),
			]
}

## A document tracks changes when the settings part of its main document
## says so, and one without the part does not.
expect {
	main = "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"
	settings = "application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"
	graph = {
		relationships: [{ id: "rId1", kind: Opc.officedocument_relationship, target: "/word/document.xml", mode: Internal }],
		parts: [
			{ name: "/word/document.xml", content_type: main, relationships: [{ id: "rId1", kind: settings_relationship, target: "/word/settings.xml", mode: Internal }] },
			{ name: "/word/settings.xml", content_type: settings, relationships: [] },
		],
	}
	namespace = "xmlns:w='http://schemas.openxmlformats.org/wordprocessingml/2006/main'"
	content = |name| if (name == "/word/settings.xml") "<w:settings ${namespace}><w:trackRevisions/></w:settings>" else "<w:document ${namespace}><w:body/></w:document>"
	tracked = Docx.parse(Opc.to_bytes(graph, |name| Bytes(content(name).to_utf8()))?)?
	untracked = Docx.parse(package_of("")?)?
	Docx.tracks_revisions(tracked.document) and !Docx.tracks_revisions(untracked.document)
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
	source = Opc.to_bytes(graph, |_| Bytes(xml.to_utf8()))?
	parsed = Docx.parse(source)?
	written = Docx.to_bytes(parsed.document)?
	again = Docx.parse(written)?
	part = Opc.part_bytes(Opc.open(written, {})?, "/word/document.xml")?
	declared = "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:mc=\"http://schemas.openxmlformats.org/markup-compatibility/2006\" xmlns:w14=\"${w14}\" mc:Ignorable=\"w14\"><w:body><w:p><w:r><w:t>a</w:t><w14:mark/></w:r></w:p></w:body>"
	undeclared = |bytes| {
		pkg = Opc.open(bytes, {}).map_err(|_| Unreadable)?
		tree = XmlTree.parse(Opc.part_bytes(pkg, "/word/document.xml").map_err(|_| Unreadable)?, {}).map_err(|_| Unreadable)?
		Ok(Mce.process(tree).diagnostics.len())
	}
	Docx.equivalent(parsed.document, again.document)
		and Str.from_utf8(part).map_ok(|text| text.contains(declared)) == Ok(Bool.True)
		and undeclared(source) == Ok(1)
		and undeclared(written) == Ok(0)
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
						"<w:hdr ${declarations}><w:p><w:r><w:rPr><w:b w:val='true'/></w:rPr><w:t>Draft</w:t></w:r></w:p></w:hdr>"
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

## Reading the body block by block gives the blocks and diagnostics reading
## its tree gives: a bookmark ends before the block it starts in, a `_GoBack`
## bookmark ends before it starts and stands between blocks, a start inside
## a dropped proofing mark names nothing, and the repairs of the body and of
## the section after it keep their order.
expect {
	go_back = "<w:p><w:bookmarkEnd w:id='5'/><w:bookmarkEnd w:id='1'/><w:r w:rsidR='00A1'><w:t>a</w:t></w:r></w:p><w:bookmarkStart w:id='5' w:name='_GoBack'/>"
	marked = "<w:p><w:proofErr w:type='spellStart'><w:bookmarkStart w:id='1' w:name='hidden'/></w:proofErr><w:bookmarkStart w:id='1' w:name='seen'/><w:bookmarkEnd w:id='9'/></w:p>"
	table = "<w:tbl><w:tblPr><w:tblW w:w='100.5' w:type='dxa'/></w:tblPr><w:tblGrid/></w:tbl>"
	section = "<w:sectPr><w:pgMar w:top='1' w:right='2' w:bottom='3' w:left='4.5' w:header='5' w:footer='6'/></w:sectPr>"
	bytes = package_of("${go_back}\n${marked}${table}<w:bookmarkStart w:id='9' w:name='late'/>${section}")?
	parsed = Docx.parse(bytes)?
	whole = Document.from_package(Opc.open(bytes, {})?, {})?
	read = Docx.read_body(parsed.document)
	ends = match read.blocks {
		[Paragraph(first), Paragraph(second), ..] => (first.content.first(), second.content.last())
		_ => (Err(ListWasEmpty), Err(ListWasEmpty))
	}
	parsed.diagnostics == whole.diagnostics
		and read == Docx.read_body(whole.document)
		and ends == (Ok(BookmarkEnd("seen")), Ok(BookmarkEnd("late")))
		and parsed.diagnostics.len() == 6
		and Document.body(whole.document).is_err()
		and Document.body(parsed.document) == Ok(read)
}

## Notes, headers and footers are written from the model: they read back
## the same, a toggle written with a value is written as the element alone,
## and a note's link keeps its part's relationship.
expect {
	parsed = Docx.parse(illustrated([0x89, 0x50, 0x4E, 0x47])?)?
	again = Docx.parse(Docx.to_bytes(parsed.document)?)?
	sectioned_document = Docx.parse(sectioned({})?)?.document
	written = Docx.to_bytes(sectioned_document)?
	reread = Docx.parse(written)?.document
	header = Str.from_utf8(Opc.part_bytes(Opc.open(written, {})?, "/word/header1.xml")?) ?? ""
	footnotes = Opc.part_bytes(Opc.open(Docx.to_bytes(parsed.document)?, {})?, "/word/footnotes.xml").map_ok(|text| Str.from_utf8(text) ?? "")
	Docx.footnotes(again.document) == Docx.footnotes(parsed.document)
		and Docx.header_footer(reread, "/word/header1.xml") == Docx.header_footer(sectioned_document, "/word/header1.xml")
		and Docx.header_footer(reread, "/word/footer1.xml") == Docx.header_footer(sectioned_document, "/word/footer1.xml")
		and header.contains("<w:p><w:r><w:rPr><w:b/></w:rPr><w:t>Draft</w:t></w:r></w:p></w:hdr>")
		and footnotes.map_ok(|text| text.contains("<w:footnote w:type=\"separator\" w:id=\"0\">") and text.contains("<w:hyperlink r:id=\"rId7\">")) == Ok(Bool.True)
		and Docx.equivalent(parsed.document, again.document)
}

# Each comment's place, author, content as text, anchor, parent and resolved
# mark, as `Docx.comments` gives them.
summary : Document -> List({ id : U64, author : Str, text : List(Str), anchor : Comments.Anchor, parent : [Unset, Parent(U64)], resolved : Bool })
summary = |document|
	Docx.comments(document).comments.map(|entry| { id: entry.id, author: entry.comment.author, text: entry.comment.content.map(paragraph_of), anchor: entry.anchor, parent: entry.comment.parent, resolved: entry.comment.resolved })

## A comment added to a document without comments is anchored to the span of
## its text, a run split where the span starts and ends, with a reference
## after the range; the document gains a comments part, the text is
## unchanged, and the comment reads back the same from the written bytes.
expect {
	parsed = Docx.parse(package_of("<w:p><w:r><w:t>Rent is due monthly.</w:t></w:r></w:p>")?)?
	added = Docx.add_comment(parsed.document, { start: 8, end: 11 }, { author: "Morgan Reviewer", content: Text("Which day?\nIn advance?"), date: Date("2026-11-10T09:00:00+01:00") })?
	again = Docx.parse(Docx.to_bytes(added.document)?)?
	run = |text| Run({ properties: Document.no_run_properties, content: [Text(text)] })
	reference = Run({ properties: Document.no_run_properties, content: [CommentReference(0)] })
	stamp = Docx.comments(added.document).comments.map(|entry| entry.comment.date)
	added.id == 0
		and Docx.body(added.document) == [Paragraph({ properties: Document.no_paragraph_properties, content: [run("Rent is "), CommentStart(0), run("due"), CommentEnd(0), reference, run(" monthly.")] })]
		and summary(added.document) == [{ id: 0, author: "Morgan Reviewer", text: ["Which day?", "In advance?"], anchor: Range("due"), parent: Unset, resolved: Bool.False }]
		and stamp == [Date({ written: "2026-11-10T09:00:00+01:00", utc_seconds: 1_794_297_600 })]
		and summary(again.document) == summary(added.document)
		and Docx.text(added.document) == Docx.text(parsed.document)
		and Opc.parts(Opc.open(Docx.to_bytes(added.document)?, {})?).any(|part| part.name == "/word/comments.xml" and part.content_type == "application/vnd.openxmlformats-officedocument.wordprocessingml.comments+xml")
}

## A reply to a comment of a document without the extended comments part
## shares its parent's range and follows its reference; resolving the reply
## resolves the whole thread, and the document gains the extended comments
## part, so the thread reads back from the written bytes.
expect {
	parsed = Docx.parse(commented({})?)?
	replied = Docx.reply(parsed.document, 1, { author: "Lin Editor", content: Text("Agreed."), initials: Initials("LE") })?
	resolved = Docx.resolve(replied.document, replied.id)?
	again = Docx.parse(Docx.to_bytes(resolved)?)?
	parts = Opc.parts(Opc.open(Docx.to_bytes(resolved)?, {})?)
	extended = parts.any(|part| part.name == "/word/commentsExtended.xml" and part.content_type == "application/vnd.openxmlformats-officedocument.wordprocessingml.commentsExtended+xml")
	replied.id == 2
		and summary(resolved)
			== [
				{ id: 1, author: "Morgan Reviewer", text: ["Earlier"], anchor: Range("first"), parent: Unset, resolved: Bool.True },
				{ id: 2, author: "Lin Editor", text: ["Agreed."], anchor: Range("first"), parent: Parent(1), resolved: Bool.True },
				{ id: 0, author: "Morgan Reviewer", text: ["Later"], anchor: Range("second"), parent: Unset, resolved: Bool.False },
			]
		and summary(again.document) == summary(resolved)
		and extended
		and !parts.any(|part| part.name == "/word/commentsIds.xml")
		and Docx.text(resolved) == Docx.text(parsed.document)
}

## Removing a comment removes its replies, their ranges and references and
## a run left holding nothing; the comments after it move up, and the text is
## unchanged.
expect {
	parsed = Docx.parse(commented({})?)?
	replied = Docx.reply(parsed.document, 1, { author: "Lin Editor", content: Text("Agreed.") })?
	again = Docx.reply(replied.document, replied.id, { author: "Morgan Reviewer", content: Text("Thanks.") })?
	removed = Docx.remove_comment(again.document, 1)?
	body_ok = match Docx.body(removed) {
		[Paragraph({ properties: _, content: [Run(_), Run(_), CommentStart(0), Run(_), CommentEnd(0), Run(reference)] })] => reference.content == [CommentReference(0)]
		_ => Bool.False
	}
	body_ok
		and summary(removed) == [{ id: 0, author: "Morgan Reviewer", text: ["Later"], anchor: Range("second"), parent: Unset, resolved: Bool.False }]
		and Docx.text(removed) == Docx.text(parsed.document)
		and Docx.remove_comment(removed, 1).map_ok(|_| {}) == Err(NoSuchComment(1))
}

# A package whose body, footnote and header each hold a bookmark, the
# footnote a tracked insertion and the header a permission range kept as it
# was read, with a people part naming Ada.
story_parts : {} -> Try(List(U8), Opc.WriteError)
story_parts = |{}| {
	relationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
	declarations = "xmlns:w='http://schemas.openxmlformats.org/wordprocessingml/2006/main' xmlns:r='${relationships}'"
	part = |name, kind| { name, content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.${kind}+xml", relationships: [] }
	graph = {
		relationships: [{ id: "rId1", kind: Opc.officedocument_relationship, target: "/word/document.xml", mode: Internal }],
		parts: [
			{
				name: "/word/document.xml",
				content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml",
				relationships: [
					{ id: "rId7", kind: "${relationships}/header", target: "/word/header1.xml", mode: Internal },
					{ id: "rId8", kind: "${relationships}/footnotes", target: "/word/footnotes.xml", mode: Internal },
					{ id: "rId9", kind: people_relationship, target: "/word/people.xml", mode: Internal },
				],
			},
			part("/word/header1.xml", "header"),
			part("/word/footnotes.xml", "footnotes"),
			part("/word/people.xml", "people"),
		],
	}
	marked = |name, inner| "<w:bookmarkStart w:id='0' w:name='${name}'/>${inner}<w:bookmarkEnd w:id='0'/>"
	body = "<w:p>${marked("body", "<w:r><w:t>body</w:t></w:r>")}</w:p><w:sectPr><w:headerReference w:type='default' r:id='rId7'/></w:sectPr>"
	header = "<w:p><w:permStart w:id='0' w:edGrp='everyone'/>${marked("head", "<w:r><w:t>head</w:t></w:r>")}<w:permEnd w:id='0'/></w:p>"
	note = "<w:footnote w:id='1'><w:p>${marked("note", "<w:ins w:id='0' w:author='Grace'><w:r><w:t>note</w:t></w:r></w:ins>")}</w:p></w:footnote>"
	people = "<w15:people xmlns:w15='http://schemas.microsoft.com/office/word/2012/wordml'><w15:person w15:author='Ada'><w15:presenceInfo w15:providerId='None' w15:userId='Ada'/></w15:person></w15:people>"
	Opc.to_bytes(
		graph,
		|name|
			Bytes(
				(
					if name == "/word/document.xml" {
						"<w:document ${declarations}><w:body>${body}</w:body></w:document>"
					} else if name == "/word/header1.xml" {
						"<w:hdr ${declarations}>${header}</w:hdr>"
					} else if name == "/word/footnotes.xml" {
						"<w:footnotes ${declarations}>${note}</w:footnotes>"
					} else {
						people
					}
				).to_utf8(),
			),
	)
}

# The identifiers of the comments, bookmarks, tracked insertions and
# deletions and permission ranges that begin in these parts of a package, in
# the parts' order.
started_ids : List(U8), List(Str) -> List(Str)
started_ids = |bytes, names|
	match Opc.open(bytes, {}) {
		Ok(opened) =>
			names.fold(
				[],
				|found, name|
					match Opc.part_bytes(opened, name) {
						Ok(content) => starts_in(found, XmlTree.parse(content, {}) ?? Text(""))
						Err(_) => found
					},
			)

		Err(_) => []
	}

starts_in : List(Str), XmlTree.Node -> List(Str)
starts_in = |found, node|
	match node {
		Element(element) => {
			here = if ["comment", "bookmarkStart", "ins", "del", "permStart"].contains(element.name.local) {
				match element.attributes.find_first(|attribute| attribute.name.local == "id") {
					Ok(attribute) => List.append(found, attribute.value)
					Err(_) => found
				}
			} else {
				found
			}
			element.children.fold(here, starts_in)
		}

		Text(_) => found
	}

## Identifiers are allocated across the document: a comment avoids an
## identifier kept in a header, the body's, footnotes' and header's
## bookmarks and tracked changes take numbers no other part takes, each part
## after the one written before it, and the kept permission range keeps
## its own.
expect {
	parsed = Docx.parse(story_parts({})?)?
	added = Docx.add_comment(parsed.document, { start: 0, end: 4 }, { author: "Ada", content: Text("Which body?") })?
	parts = ["/word/document.xml", "/word/footnotes.xml", "/word/header1.xml", "/word/comments.xml"]
	started_ids(Docx.to_bytes(parsed.document)?, parts) == ["1", "2", "3", "0", "4"]
		and started_ids(Docx.to_bytes(added.document)?, parts) == ["2", "3", "4", "0", "5", "1"]
}

## A new comment's or reply's author is added once to a people part, as Word
## records an author without an account; a document without a people part
## is not given one.
expect {
	parsed = Docx.parse(story_parts({})?)?
	added = Docx.add_comment(parsed.document, { start: 0, end: 4 }, { author: "Morgan Reviewer", content: Text("Which body?") })?
	replied = Docx.reply(added.document, added.id, { author: "Ada", content: Text("This one.") })?
	again = Docx.reply(replied.document, added.id, { author: "Morgan Reviewer", content: Text("Thanks.") })?
	plain = Docx.add_comment(Docx.parse(commented({})?)?.document, { start: 0, end: 5 }, { author: "Lin Editor", content: Text("Here.") })?
	person = |author| { author, presence: Presence({ provider: "None", user: author }) }
	Docx.people(again.document) == { people: [person("Ada"), person("Morgan Reviewer")], diagnostics: [] }
		and Docx.people(Docx.parse(Docx.to_bytes(again.document)?)?.document) == Docx.people(again.document)
		and Docx.people(plain.document) == { people: [], diagnostics: [] }
		and !Opc.parts(Opc.open(Docx.to_bytes(plain.document)?, {})?).any(|part| part.name == "/word/people.xml")
}

## A span is placed in the current text: across paragraphs, inside a
## hyperlink and an insertion with the reference after them, at a
## paragraph's end without its line feed, and on no text; a span outside the
## text or inside a character fails.
expect {
	link = "<w:hyperlink w:anchor='terms'><w:r><w:t>terms</w:t></w:r></w:hyperlink>"
	inserted = "<w:ins w:author='A'><w:r><w:t>new</w:t></w:r></w:ins><w:del w:author='A'><w:r><w:delText>old</w:delText></w:r></w:del>"
	parsed = Docx.parse(package_of("<w:p><w:r><w:t xml:space='preserve'>See </w:t></w:r>${link}</w:p><w:p>${inserted}<w:r><w:t>é.</w:t></w:r></w:p>")?)?
	new : Comments.New
	new = { author: "Ada Reviewer", content: Text("Check.") }
	anchors = |spans| {
		var $document = parsed.document
		for span in spans {
			$document = Docx.add_comment($document, span, new)?.document
		}
		Ok(Docx.comments($document).comments.map(|entry| entry.anchor))
	}
	inner = match Docx.add_comment(parsed.document, { start: 5, end: 9 }, new) {
		Ok({ document, id: _ }) =>
			match Docx.body(document) {
				[Paragraph({ properties: _, content: [_, Hyperlink(found), Run(after)] }), _] => (found.content.len(), after.content)
				_ => (0, [])
			}

		Err(_) => (0, [])
	}
	Docx.text(parsed.document) == "See terms\nnewé.\n"
		and anchors([{ start: 4, end: 13 }, { start: 0, end: 10 }, { start: 10, end: 10 }, { start: 13, end: 17 }])
			== Ok([Range("See terms"), Range("terms\nnew"), Range(""), Range("é.")])
		and inner == (4, [CommentReference(0)])
		and Docx.add_comment(parsed.document, { start: 3, end: 30 }, new).map_ok(|_| {}) == Err(OutsideText({ start: 3, end: 30 }))
		and Docx.add_comment(parsed.document, { start: 14, end: 15 }, new).map_ok(|_| {}) == Err(NotACharacterBoundary(14))
		and Docx.add_comment(parsed.document, { start: 4, end: 2 }, new).map_ok(|_| {}) == Err(OutsideText({ start: 4, end: 2 }))
}

# A body with a change of every kind the algebra resolves: text inserted
# and deleted, a move with its ranges, a deleted and an inserted paragraph
# mark, run and paragraph formatting, and a table with an inserted row, a
# deleted row, an inserted cell, a deleted cell and a merged cell.
every_change : Str
every_change = {
	by = |author, date| "w:author='${author}' w:date='${date}'"
	ada = by("Ada", "2026-05-07T09:00:00Z")
	grace = by("Grace", "2026-05-08T09:00:00Z")
	run = |text| "<w:r><w:t xml:space='preserve'>${text}</w:t></w:r>"
	gone = |text| "<w:r><w:delText xml:space='preserve'>${text}</w:delText></w:r>"
	cell = |properties, text| "<w:tc><w:tcPr>${properties}</w:tcPr><w:p>${run(text)}</w:p></w:tc>"
	content = "<w:p>${run("Rent is ")}<w:del ${ada}>${gone("two")}</w:del><w:ins ${ada}>${run("three")}</w:ins>${run(" years.")}</w:p>"
	moved = "<w:p><w:moveFromRangeStart w:id='1' w:name='m' ${grace}/><w:moveFrom ${grace}>${run("Moved.")}</w:moveFrom><w:moveFromRangeEnd w:id='1'/>${run("Stays.")}</w:p>"
	joined = "<w:p><w:pPr><w:rPr><w:del ${ada}/></w:rPr></w:pPr>${run("Joined ")}</w:p><w:p><w:pPr><w:jc w:val='center'/><w:pPrChange ${grace}><w:pPr/></w:pPrChange></w:pPr>${run("here.")}<w:moveToRangeStart w:id='2' w:name='m' ${grace}/><w:moveTo ${grace}>${run("Moved.")}</w:moveTo><w:moveToRangeEnd w:id='2'/></w:p>"
	inserted = "<w:p><w:pPr><w:rPr><w:ins ${grace}/></w:rPr></w:pPr><w:r><w:rPr><w:b/><w:rPrChange ${ada}><w:rPr/></w:rPrChange></w:rPr><w:t>Bold</w:t></w:r></w:p>"
	row = |properties, cells| "<w:tr><w:trPr>${properties}</w:trPr>${cells}</w:tr>"
	table = "<w:tbl><w:tblPr/><w:tblGrid><w:gridCol w:w='1000'/><w:gridCol w:w='1000'/></w:tblGrid>${row("", "${cell("", "a")}${cell("<w:cellIns ${ada}/>", "b")}")}${row("<w:ins ${grace}/>", cell("", "c"))}${row("<w:del ${ada}/>", cell("", "d"))}${row("", "${cell("<w:cellDel ${grace}/>", "e")}${cell("<w:vMerge/><w:cellMerge ${ada} w:vMerge='cont' w:vMergeOrig='rest'/>", "f")}")}</w:tbl>"
	"${content}${moved}${joined}${inserted}${table}<w:p/><w:sectPr/>"
}

## Accepting every change gives a document whose text is the final text and
## that has no changes left; rejecting every change gives the original text.
## A deleted mark accepted joins its paragraph to the next, which keeps its
## own properties; an inserted mark rejected joins likewise; a move's ranges
## go with it; a row or cell deleted and accepted, or inserted and rejected,
## goes; a rejected merge restores the merge before it; rejected formatting
## restores the properties before it.
expect {
	parsed = Docx.parse(package_of(every_change)?)?
	accepted = Docx.accept_all(parsed.document)?
	rejected = Docx.reject_all(parsed.document)?
	cells = |document|
		Docx.body(document).keep_oks(
			|block|
				match block {
					Table(table) => Ok(Document.table_rows(table).map(|row| Document.row_cells(row).map(|cell| cell.properties.merge)))
					_ => Err(NotATable)
				},
		)
	has_ranges = |document|
		Docx.body(document).any(
			|block|
				match block {
					Paragraph(paragraph) =>
						paragraph.content.any(
							|inline|
								match inline {
									MoveStart(_) | MoveEnd(_) => Bool.True
									_ => Bool.False
								},
						)

					_ => Bool.False
				},
		)
	centred = |document|
		Docx.body(document).any(
			|block|
				match block {
					Paragraph(paragraph) => paragraph.properties.alignment == Aligned(Center)
					_ => Bool.False
				},
		)
	Docx.text(accepted) == Docx.final_text(parsed.document)
		and Docx.text(rejected) == Docx.original_text(parsed.document)
		and Docx.final_text(parsed.document) == "Rent is three years.\nStays.\nJoined here.Moved.\nBold\na\nb\nc\nf\n\n"
		and Docx.revisions(accepted).is_empty()
		and Docx.revisions(rejected).is_empty()
		and !has_ranges(accepted)
		and !has_ranges(rejected)
		and centred(accepted)
		and !centred(rejected)
		and cells(accepted) == [[[Unset, Unset], [Unset], [Continue]]]
		and cells(rejected) == [[[Unset], [Unset], [Unset, Restart]]]
}

## Filtered forms resolve only the changes they select: by author, by a
## date range from its start up to its end, or by id, the others staying.
expect {
	parsed = Docx.parse(package_of(every_change)?)?
	authors = |document| Docx.revisions(document).map(|change| change.author)
	graces = Docx.revisions(parsed.document).keep_if(|change| change.author == "Grace").len()
	by_author = Docx.accept(parsed.document, By("Ada"))?
	dated = Docx.reject(parsed.document, Between({ from: "2026-05-08T00:00:00Z", until: "2026-05-09T00:00:00Z" }))?
	first_two = Docx.reject(parsed.document, Ids([0, 1]))?
	authors(by_author).len() == graces
		and authors(by_author).all(|author| author == "Grace")
		and authors(dated).all(|author| author == "Ada")
		and Docx.text(first_two).starts_with("Rent is two years.\n")
		and Docx.revisions(first_two).len() + 2 == Docx.revisions(parsed.document).len()
		and Docx.accept(parsed.document, Between({ from: "yesterday", until: "2026-05-09T00:00:00Z" })).map_ok(|_| {}) == Err(NotADate("yesterday"))
}

## A tracked replacement deletes the span's text and inserts the new text
## after it, by the context's author at its date: the final text is the
## untracked replacement's text and the original text the text before.
## Inserting at a paragraph's start takes the first run's properties.
expect {
	run = |text| "<w:r><w:t xml:space='preserve'>${text}</w:t></w:r>"
	parsed = Docx.parse(package_of("<w:p>${run("Rent is ")}${run("two")}${run(" years.")}</w:p><w:p><w:r><w:rPr><w:b/></w:rPr><w:t>Due</w:t></w:r></w:p>")?)?
	before = Docx.text(parsed.document)
	morgan = Tracked({ author: "Morgan", date: Date("2026-11-10T09:00:00Z") })
	tracked = Docx.replace_text(parsed.document, { start: 8, end: 11 }, "three", morgan)?
	silent = Docx.replace_text(parsed.document, { start: 8, end: 11 }, "three", Untracked)?
	listed = Docx.revisions(tracked).map(|change| (change.kind, change.author, change.text))
	prefixed = Docx.insert_text(parsed.document, 19, "Rent ", Untracked)?
	bold = match Docx.body(prefixed) {
		[_, Paragraph({ properties: _, content: [Run(added), ..] })] => added.properties.bold == On and added.content == [Text("Rent ")]
		_ => Bool.False
	}
	deleted = Docx.delete_text(parsed.document, { start: 5, end: 11 }, morgan)?
	Docx.text(silent) == "Rent is three years.\nDue\n"
		and Docx.text(tracked) == Docx.text(silent)
		and Docx.final_text(tracked) == Docx.text(silent)
		and Docx.original_text(tracked) == before
		and listed == [(Deletion, "Morgan", "two"), (Insertion, "Morgan", "three")]
		and Docx.revisions(silent).is_empty()
		and Docx.text(prefixed) == "Rent is two years.\nRent Due\n"
		and bold
		and Docx.text(deleted) == "Rent  years.\nDue\n"
		and Docx.original_text(deleted) == before
		and Docx.revisions(deleted).map(|change| change.text) == ["is ", "two"]
}

## Inserted text goes after the character before its position, inside the
## hyperlink that character is in unless it ends it; deleting inserted text
## by a tracked edit puts a deletion inside the insertion, and silently
## removes it, an emptied insertion going too.
expect {
	link = "<w:hyperlink w:anchor='x'><w:r><w:t>link</w:t></w:r></w:hyperlink>"
	parsed = Docx.parse(package_of("<w:p>${link}<w:ins w:author='A'><w:r><w:t>new</w:t></w:r></w:ins></w:p>")?)?
	inside = Docx.insert_text(parsed.document, 2, "-", Untracked)?
	after = Docx.insert_text(parsed.document, 4, "!", Untracked)?
	linked = |document|
		match Docx.body(document) {
			[Paragraph({ properties: _, content: [Hyperlink({ target: _, preserved: _, content }), ..] })] => Document.paragraph_text({ properties: Document.no_paragraph_properties, content })
			_ => ""
		}
	tracked = Docx.delete_text(parsed.document, { start: 4, end: 7 }, Tracked({ author: "B", date: Unset }))?
	silent = Docx.delete_text(parsed.document, { start: 4, end: 7 }, Untracked)?
	Docx.text(inside) == "li-nknew\n"
		and linked(inside) == "li-nk"
		and Docx.text(after) == "link!new\n"
		and linked(after) == "link"
		and Docx.revisions(tracked).map(|change| (change.kind, change.author)) == [(Insertion, "A"), (Deletion, "B")]
		and Docx.final_text(tracked) == "link\n"
		and Docx.original_text(tracked) == "link\n"
		and Docx.revisions(silent).is_empty()
		and Docx.text(silent) == "link\n"
}

## An edit's span must lie within the text and start and end between
## characters, and a line feed in it must end a paragraph with a paragraph
## after it to join.
expect {
	parsed = Docx.parse(package_of("<w:p><w:r><w:t>caf\u(e9)</w:t></w:r></w:p><w:p><w:r><w:t>b</w:t></w:r></w:p><w:tbl><w:tr><w:tc><w:p><w:r><w:t>c</w:t></w:r></w:p></w:tc></w:tr></w:tbl><w:p/>")?)?
	failed = |result| result.map_ok(|_| {})
	failed(Docx.delete_text(parsed.document, { start: 6, end: 9 }, Untracked)) == Err(LineFeedInSpan({ start: 6, end: 9 }))
		and failed(Docx.delete_text(parsed.document, { start: 9, end: 11 }, Untracked)) == Err(LineFeedInSpan({ start: 9, end: 11 }))
		and failed(Docx.delete_text(parsed.document, { start: 3, end: 4 }, Untracked)) == Err(NotACharacterBoundary(4))
		and failed(Docx.insert_text(parsed.document, 12, "x", Untracked)) == Err(OutsideText({ start: 12, end: 12 }))
		and failed(Docx.insert_text(parsed.document, 11, "x", Untracked)) == Err(OutsideText({ start: 11, end: 11 }))
		and failed(Docx.insert_text(parsed.document, 0, "x", Tracked({ author: "A", date: Date("soon") }))) == Err(NotADate("soon"))
		and Docx.text(Docx.insert_text(parsed.document, 6, "x", Untracked)?) == "caf\u(e9)\nxb\nc\n\n"
		and Docx.text(Docx.delete_text(parsed.document, { start: 2, end: 7 }, Untracked)?) == "ca\nc\n\n"
}

## A span over a paragraph's line feed joins the paragraph into the next,
## which keeps its own properties, or, tracked, deletes the mark, so that
## accepting the edit gives the silent edit and rejecting it the paragraphs
## before; new text holding a line feed splits its paragraph, the part
## before taking a copy of its properties and, tracked, an inserted mark.
expect {
	centred = "<w:pPr><w:jc w:val='center'/></w:pPr>"
	parsed = Docx.parse(package_of("<w:p><w:r><w:t>one</w:t></w:r></w:p><w:p><w:r><w:t>two</w:t></w:r></w:p><w:p>${centred}<w:r><w:t>three</w:t></w:r></w:p>")?)?
	before = Docx.text(parsed.document)
	morgan = Tracked({ author: "Morgan", date: Date("2026-11-10T09:00:00Z") })
	silent = Docx.replace_text(parsed.document, { start: 2, end: 9 }, "-", Untracked)?
	tracked = Docx.replace_text(parsed.document, { start: 2, end: 9 }, "-", morgan)?
	aligned = |document| Docx.body(document).map(
		|block| match block {
			Paragraph(paragraph) => paragraph.properties.alignment
			_ => Unset
		},
	)
	marks = |document| Docx.revisions(document).keep_if(|change| change.of == ParagraphMark).map(|change| change.kind)
	split_silent = Docx.insert_text(parsed.document, 9, "a\nb", Untracked)?
	split = Docx.insert_text(parsed.document, 9, "a\nb", morgan)?
	Docx.text(silent) == "on-hree\n"
		and aligned(silent) == [Aligned(Center)]
		and Docx.text(tracked) == Docx.text(silent)
		and Docx.final_text(tracked) == Docx.text(silent)
		and Docx.original_text(tracked) == before
		and marks(tracked) == [Deletion, Deletion]
		and Docx.text(Docx.accept(tracked, By("Morgan"))?) == Docx.text(silent)
		and aligned(Docx.accept(tracked, All)?) == [Aligned(Center)]
		and Docx.text(Docx.reject(tracked, All)?) == before
		and Docx.text(split_silent) == "one\ntwo\nta\nbhree\n"
		and aligned(split_silent) == [Unset, Unset, Aligned(Center), Aligned(Center)]
		and Docx.text(split) == Docx.text(split_silent)
		and Docx.original_text(split) == before
		and marks(split) == [Insertion]
		and aligned(Docx.reject(split, All)?) == [Unset, Unset, Aligned(Center)]
		and Docx.text(Docx.reject(split, All)?) == before
}

## Blocks are inserted where a paragraph or table begins, or at the end of
## the body; tracked, their content and marks are inserted, or, at the end,
## the mark of the paragraph before, so rejecting takes them away again and
## accepting keeps them as given.
expect {
	parsed = Docx.parse(package_of("<w:p><w:r><w:t>one</w:t></w:r></w:p><w:tbl><w:tr><w:tc><w:p><w:r><w:t>c</w:t></w:r></w:p></w:tc></w:tr></w:tbl><w:p><w:r><w:t>two</w:t></w:r></w:p><w:sectPr/>")?)?
	before = Docx.text(parsed.document)
	morgan = Tracked({ author: "Morgan", date: Date("2026-11-10T09:00:00Z") })
	heading = Paragraph({ properties: { ..Document.no_paragraph_properties, style: Style("Heading1") }, content: [Run({ properties: Document.no_run_properties, content: [Text("new")] })] })
	table = Table({
		properties: { style: Unset, width: Unset, borders: [], shading: Unset, preserved: [], change: [] },
		grid: [Column(1000)],
		content: [Row({ properties: { header: Unset, grid_before: Unset, grid_after: Unset, preserved: [], inserted: Unset, deleted: Unset, change: [] }, content: [Cell({ properties: { width: Unset, span: Unset, merge: Unset, borders: [], shading: Unset, alignment: Unset, preserved: [], revision: Unset, change: [] }, content: [Paragraph({ properties: Document.no_paragraph_properties, content: [Run({ properties: Document.no_run_properties, content: [Text("t")] })] })] })] })],
	})
	first = Docx.insert_blocks(parsed.document, 0, [table, heading], morgan)?
	ending = Docx.insert_blocks(parsed.document, 10, [heading], morgan)?
	silent_end = Docx.insert_blocks(parsed.document, 10, [heading], Untracked)?
	failed = |result| result.map_ok(|_| {})
	Docx.text(Docx.insert_blocks(parsed.document, 0, [table, heading], Untracked)?) == "t\nnew\n${before}"
		and Docx.final_text(first) == "t\nnew\n${before}"
		and Docx.original_text(first) == before
		and Docx.text(Docx.reject(first, All)?) == before
		and Docx.text(silent_end) == "${before}new\n"
		and Docx.final_text(ending) == Docx.text(silent_end)
		and Docx.body(Docx.accept(ending, All)?) == Docx.body(silent_end)
		and Docx.body(Docx.reject(ending, All)?) == Docx.body(parsed.document)
		and Docx.text(Docx.insert_blocks(parsed.document, 4, [table], morgan)?) == "one\nt\nc\ntwo\n"
		and failed(Docx.insert_blocks(parsed.document, 4, [table, heading], morgan)) == Err(NoParagraphToJoin(4))
		and failed(Docx.insert_blocks(parsed.document, 1, [heading], Untracked)) == Err(NotABlockBoundary(1))
}

## Deleting blocks removes the paragraphs and tables of a span of whole
## blocks, what the paragraphs leave behind joining the paragraph after;
## tracked, their content, marks and rows are deleted, so accepting gives
## the silent deletion and rejecting the blocks before.
expect {
	parsed = Docx.parse(package_of("<w:p><w:r><w:t>one</w:t></w:r></w:p><w:tbl><w:tr><w:tc><w:p><w:r><w:t>c</w:t></w:r></w:p></w:tc></w:tr></w:tbl><w:p><w:r><w:t>two</w:t></w:r></w:p><w:p><w:r><w:t>three</w:t></w:r></w:p>")?)?
	before = Docx.text(parsed.document)
	morgan = Tracked({ author: "Morgan", date: Date("2026-11-10T09:00:00Z") })
	silent = Docx.delete_blocks(parsed.document, { start: 4, end: 10 }, Untracked)?
	tracked = Docx.delete_blocks(parsed.document, { start: 4, end: 10 }, morgan)?
	failed = |result| result.map_ok(|_| {})
	Docx.text(silent) == "one\nthree\n"
		and Docx.final_text(tracked) == Docx.text(silent)
		and Docx.original_text(tracked) == before
		and Docx.body(Docx.accept(tracked, All)?) == Docx.body(silent)
		and Docx.body(Docx.reject(tracked, All)?) == Docx.body(parsed.document)
		and failed(Docx.delete_blocks(parsed.document, { start: 0, end: 6 }, morgan)) == Err(NoParagraphToJoin(0))
		and failed(Docx.delete_blocks(parsed.document, { start: 0, end: 5 }, Untracked)) == Err(NotABlockBoundary(5))
		and failed(Docx.delete_blocks(parsed.document, { start: 10, end: 16 }, Untracked)) == Err(NoParagraphToJoin(10))
		and Docx.text(Docx.delete_blocks(parsed.document, { start: 6, end: 10 }, Untracked)?) == "one\nc\nthree\n"
}

## Setting tracking on gives a document without settings a settings part
## that tracks changes, and setting it off again stops it.
expect {
	parsed = Docx.parse(package_of("<w:p/>")?)?
	on = Docx.set_tracking(parsed.document, On)?
	written = Docx.parse(Docx.to_bytes(on)?)?
	off = Docx.set_tracking(written.document, Off)?
	!Docx.tracks_revisions(parsed.document)
		and Docx.tracks_revisions(written.document)
		and !Docx.tracks_revisions(off)
		and Docx.set_tracking(parsed.document, Off).map_ok(|document| Docx.tracks_revisions(document)) == Ok(Bool.False)
}

## A new document writes to the same bytes every time, and reads back as an
## empty page with the kit's styles, lists and the properties it was given.
expect {
	created = Docx.new_document({ title: Text("Lease"), creator: Text("Ada Reviewer"), created: Date("2026-11-10T09:00:00Z") })?
	written = Docx.to_bytes(created)?
	parsed = Docx.parse(written)?
	properties = Docx.core_properties(parsed.document)
	styles = Docx.styles(parsed.document)
	Docx.to_bytes(created) == Ok(written)
		and parsed.diagnostics.is_empty()
		and Docx.equivalent(created, parsed.document)
		and Docx.text(parsed.document) == "\n"
		and styles.diagnostics.is_empty()
		and Styles.get(styles.styles, "Heading1").map_ok(|style| style.name) == Ok(Named("heading 1"))
		and Docx.numbering(parsed.document).diagnostics.is_empty()
		and (properties.title, properties.creator, properties.created, properties.modified) == (Text("Lease"), Text("Ada Reviewer"), Date("2026-11-10T09:00:00Z"), Unset)
}
# A package whose body, header, footnotes and comment each hold a tracked
# insertion and deletion, by Ada in the body and by Grace elsewhere.
revised_parts : {} -> Try(List(U8), Opc.WriteError)
revised_parts = |{}| {
	relationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
	declarations = "xmlns:w='http://schemas.openxmlformats.org/wordprocessingml/2006/main' xmlns:r='${relationships}'"
	part = |name, kind| { name, content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.${kind}+xml", relationships: [] }
	graph = {
		relationships: [{ id: "rId1", kind: Opc.officedocument_relationship, target: "/word/document.xml", mode: Internal }],
		parts: [
			{
				name: "/word/document.xml",
				content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml",
				relationships: [
					{ id: "rId7", kind: "${relationships}/header", target: "/word/header1.xml", mode: Internal },
					{ id: "rId8", kind: "${relationships}/footnotes", target: "/word/footnotes.xml", mode: Internal },
					{ id: "rId9", kind: "${relationships}/comments", target: "/word/comments.xml", mode: Internal },
				],
			},
			part("/word/header1.xml", "header"),
			part("/word/footnotes.xml", "footnotes"),
			part("/word/comments.xml", "comments"),
		],
	}
	changes = |author| "<w:p><w:ins w:author='${author}'><w:r><w:t>new</w:t></w:r></w:ins><w:del w:author='${author}'><w:r><w:delText>old</w:delText></w:r></w:del></w:p>"
	anchored = "<w:p><w:commentRangeStart w:id='0'/><w:r><w:t>body</w:t></w:r><w:commentRangeEnd w:id='0'/><w:r><w:commentReference w:id='0'/></w:r></w:p>"
	body = "${changes("Ada")}${anchored}<w:sectPr><w:headerReference w:type='default' r:id='rId7'/></w:sectPr>"
	Opc.to_bytes(
		graph,
		|name|
			Bytes(
				(
					if name == "/word/document.xml" {
						"<w:document ${declarations}><w:body>${body}</w:body></w:document>"
					} else if name == "/word/header1.xml" {
						"<w:hdr ${declarations}>${changes("Grace")}</w:hdr>"
					} else if name == "/word/footnotes.xml" {
						"<w:footnotes ${declarations}><w:footnote w:id='1'>${changes("Grace")}</w:footnote></w:footnotes>"
					} else {
						"<w:comments ${declarations}><w:comment w:id='0' w:author='Ada'>${changes("Grace")}</w:comment></w:comments>"
					}
				).to_utf8(),
			),
	)
}

## Accepting and rejecting resolve the changes of notes, headers, footers
## and comments too, except a selection by id, which names the body's.
expect {
	parsed = Docx.parse(revised_parts({})?)?
	texts = |document| {
		blocks = List.join([
			Docx.header_footer(document, "/word/header1.xml"),
			List.join(Docx.footnotes(document).map(|note| note.content)),
			List.join(Docx.comments(document).comments.map(|anchored| anchored.comment.content)),
		])
		(Revisions.text(blocks, Current), Revisions.list(blocks).len())
	}
	accepted = Docx.accept_all(parsed.document)?
	rejected = Docx.reject_all(parsed.document)?
	by_grace = Docx.accept(parsed.document, By("Grace"))?
	by_id = Docx.accept(parsed.document, Ids([0, 1]))?
	texts(parsed.document) == ("new\nnew\nnew\n", 6)
		and texts(accepted) == ("new\nnew\nnew\n", 0)
		and texts(rejected) == ("old\nold\nold\n", 0)
		and texts(by_grace) == ("new\nnew\nnew\n", 0)
		and Docx.revisions(by_grace).len() == 2
		and texts(by_id) == ("new\nnew\nnew\n", 6)
		and Docx.revisions(by_id).is_empty()
}
