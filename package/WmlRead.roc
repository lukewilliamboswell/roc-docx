## WordprocessingML trees read as the typed model.
##
## The reader is lenient and loses nothing: an element it models becomes a
## typed value, and every other element is kept, in its place, as the
## [XmlTree.Node] it was read as. Elements whose content is itself blocks or
## paragraph content, such as a content control or a tracked insertion, are
## kept without their children and their content is read, so text inside
## them is still text. What a part's elements name elsewhere in the package,
## such as a hyperlink's relationship or a note reference's note, is resolved
## through the part's [WmlRead.Context], so the model holds what is named
## rather than the part's identifiers for it. Whitespace-only text between
## elements is not content and is not kept.
##
## A body, its notes, its comments and its headers and footers are read as
## they are written, without [Mce.process] first, so that the model holds everything
## [WmlWrite] writes back: an extension element or
## alternative content (`mc:AlternateContent`) is kept whole in its place,
## and a paragraph, run, table, row, cell, piece of run content or property
## list with an attribute the model cannot hold is kept whole rather than
## read without it. Word's paragraph and row identifiers, `w14:paraId` and
## `w14:textId`, are not part of the model.
import Document
import Lenient
import Mce
import Opc
import XmlTree

WmlRead :: [].{

	## What reading a part needs from the rest of its package: the
	## relationships whose source is the part, which hyperlinks and pictures
	## name; the identifiers of the footnotes and of the endnotes in the
	## order of their parts, as [WmlRead.note_ids] lists them, which note
	## references name; and the identifiers of the comments in the order of
	## their part, as [WmlRead.comment_ids] lists them, which comment ranges
	## and references name.
	Context : { relationships : List(Opc.Relationship), footnotes : List(Str), endnotes : List(Str), comments : List(Str) }

	## The body of a main document part, block by block in reading order, from
	## the part's tree as [Docx.parse] read it. A tree whose root is not a
	## WordprocessingML document, or that has no body, has no blocks.
	##
	## A paragraph's first `w:pPr` holds its properties and a run's first
	## `w:rPr` its properties. In a run, `w:t` is text, `w:tab` a tab, `w:br`
	## a break (`w:cr` a line break), `w:sym` a symbol, `w:softHyphen` and
	## `w:noBreakHyphen` hyphens, `w:footnoteReference` and
	## `w:endnoteReference` note references, `w:footnoteRef` and
	## `w:endnoteRef` note marks, `w:commentReference` a comment reference,
	## `w:fldChar` a field's mark, `w:instrText` a piece of its code, and a
	## `w:drawing` holding a `wp:inline` picture a picture. In a paragraph,
	## `w:hyperlink` is a hyperlink, `w:fldSimple` a simple field and
	## `w:bookmarkStart` and `w:bookmarkEnd` a bookmark's boundaries.
	## `w:commentRangeStart` and `w:commentRangeEnd` are a comment range's
	## boundaries, in a paragraph or between blocks, rows or cells.
	##
	## In a paragraph, `w:ins`, `w:del`, `w:moveFrom` and `w:moveTo` are
	## tracked changes, and `w:moveFromRangeStart`, `w:moveToRangeStart` and
	## their ends a move's ranges. In a deletion or a move's source,
	## `w:delText` is text and `w:delInstrText` a piece of a field's code.
	##
	## An element whose attributes are not ones the model can hold, such as a
	## break of an unknown type, a symbol without a character code, a note
	## reference with a custom mark or a bookmark spanning table columns, or
	## that names what the package does not have, such as a missing note or
	## comment, a relationship that is not there or a bookmark end without
	## its start, is kept as it was read; a hyperlink, simple field or
	## tracked change like that is a container of its content.
	##
	## A table's first `w:tblPr` holds its properties and its first
	## `w:tblGrid` its grid, a row's first `w:trPr` and a cell's first
	## `w:tcPr` theirs. Each property the model holds is read from the first
	## element that gives it in a form the model can hold; every other
	## property element stays in `preserved`, in order.
	##
	## Under tracking, a row's `w:ins` and `w:del` are its insertion and
	## deletion, a cell's `w:cellIns`, `w:cellDel` and `w:cellMerge` its
	## insertion, deletion or merge, and a `w:tblPrChange`, `w:trPrChange`,
	## `w:tcPrChange` or `w:sectPrChange` a change of the properties that hold
	## it, as [WmlRead.paragraph_properties] reads a paragraph's.
	##
	## A `w:sectPr` in the body, or in a paragraph's `w:pPr`, ends a section:
	## it is a section block, after the paragraph whose mark ends the
	## section, and a `w:headerReference` or `w:footerReference` names the
	## part its relationship targets.
	body : XmlTree.Node, Context -> List(Document.Block)
	body = |tree, context| WmlRead.read_body(tree, context).blocks

	## The body as [WmlRead.body] reads it, with what reading it noticed, in
	## document order.
	read_body : XmlTree.Node, Context -> { blocks : List(Document.Block), diagnostics : List(WmlRead.Diagnostic) }
	read_body = |tree, context|
		match tree {
			Element(root) if is_w(root.name, "document") =>
				match root.children.find_first(|child| is_element(child, "body")) {
					Ok(Element(element)) => blocks(element.children, reading(tree, context), [])
					_ => { blocks: [], diagnostics: [] }
				}

			_ => { blocks: [], diagnostics: [] }
		}

	## The reader [Document.from_package_with_body] reads a main document's
	## body with one block at a time, giving the blocks and diagnostics
	## [WmlRead.read_body] gives for the part's tree: its first pass learns
	## the names of the part's bookmarks and moves, and its second reads
	## each block as it comes.
	body_reader : Context -> Document.BodyReader(NamesScan, BodyReading)
	body_reader = |context| {
		scanned: { names: no_range_names, depth: 0, opaque: 0 },
		scan: names_step,
		start: |scan| { within: reading_with(context, scan.names), read: { blocks: List.with_capacity(64), diagnostics: List.with_capacity(0) } },
		block: |state, node| { within: state.within, read: block_step(state.read, node, state.within) },
		finish: |state| state.read,
	}

	## The notes of a footnotes or endnotes part, in the part's order, from
	## the part's tree as [Docx.parse] read it. A note's content is read as a
	## body's blocks are, and `w:type` says what kind of note it is. A tree
	## whose root is not a WordprocessingML footnotes or endnotes part has no
	## notes.
	notes : XmlTree.Node, Context -> List(Document.Note)
	notes = |tree, context| {
		within = reading(tree, context)
		note_elements(tree).map(
			|element| {
				kind = match value_of(element, "type") {
					Ok("separator") => Separator
					Ok("continuationSeparator") => ContinuationSeparator
					Ok("continuationNotice") => ContinuationNotice
					_ => Note
				}
				{ kind, content: blocks(element.children, within, []).blocks }
			},
		)
	}

	## The identifiers of a footnotes or endnotes part's notes, in the order
	## [WmlRead.notes] reads them; a note without one has the empty string.
	note_ids : XmlTree.Node -> List(Str)
	note_ids = |tree| note_elements(tree).map(|element| value_of(element, "id") ?? "")

	## The comments of a comments part, in the part's order, from the part's
	## tree as [Docx.parse] read it, read as written as a body is, with what
	## reading them noticed. A comment's content is read as a body's
	## blocks are; `w:author`, `w:initials` and `w:date` say who wrote it and
	## when. A comment without an author, which the schema requires, has the
	## empty author and a `Defaulted` diagnostic. A tree whose root is not a
	## WordprocessingML comments part has no comments. The comments part does
	## not say how comments thread, so every comment is read without a
	## parent, unresolved and without a durable identifier or UTC date, as
	## [Comments.threads] completes them from the parts beside it.
	comments : XmlTree.Node, Context -> { comments : List(Document.Comment), diagnostics : List(WmlRead.Diagnostic) }
	comments = |tree, context| {
		within = reading(tree, context)
		elements = comment_elements(tree)
		var $comments = List.with_capacity(elements.len())
		var $diagnostics = List.with_capacity(0)
		for element in elements {
			author = match value_of(element, "author") {
				Ok(name) => name
				Err(NotFound) => {
					$diagnostics = List.append($diagnostics, Defaulted({ element: "comment", attribute: "author" }))
					""
				}
			}
			date = match value_of(element, "date") {
				Ok(written) =>
					match timestamp(written) {
						Ok(stamp) => Date(stamp)
						Err(NotDate) => Unset
					}

				Err(NotFound) => Unset
			}
			kept = |attribute| is_w_in(attribute.name, ["id", "author", "initials"]) or (is_w(attribute.name, "date") and date != Unset)
			read = blocks(element.children, within, $diagnostics)
			$diagnostics = read.diagnostics
			comment : Document.Comment
			comment = {
				author,
				initials: match value_of(element, "initials") {
					Ok(initials) => Initials(initials)
					Err(NotFound) => Unset
				},
				date,
				content: read.blocks,
				preserved: element.attributes.drop_if(kept),
				parent: Unset,
				resolved: Bool.False,
				durable_id: Unset,
				utc_date: Unset,
			}
			$comments = List.append($comments, comment)
		}
		{ comments: $comments, diagnostics: $diagnostics }
	}

	## A date and time in the XML Schema `dateTime` form, such as
	## `2026-05-04T09:15:00Z`, with the instant it names, read as a
	## comment's `w:date` is read.
	date_time : Str -> Try(Document.Timestamp, [NotDate])
	date_time = |written| timestamp(written)

	## The identifiers of a comments part's comments, in the order
	## [WmlRead.comments] reads them; a comment without one has the empty
	## string.
	comment_ids : XmlTree.Node -> List(Str)
	comment_ids = |tree| comment_elements(tree).map(|element| value_of(element, "id") ?? "")

	## The blocks of a header or footer part, from the part's tree as
	## [Docx.parse] read it, read as a body's blocks are. A tree whose root is not a WordprocessingML header
	## or footer has no blocks.
	header_footer : XmlTree.Node, Context -> List(Document.Block)
	header_footer = |tree, context|
		match tree {
			Element(root) if is_w(root.name, "hdr") or is_w(root.name, "ftr") => blocks(root.children, reading(tree, context), []).blocks
			_ => []
		}

	## The core properties of a core properties part, from the part's tree,
	## interpreted by [Mce.process] first. A property is read from the first
	## element that gives it in a form the model can hold: text without
	## markup or attributes, a revision number of decimal digits, or a date
	## in the W3C date and time format with no attribute but its `xsi:type`.
	## A tree whose root is not core properties has none.
	core_properties : XmlTree.Node -> Document.CoreProperties
	core_properties = |tree| {
		var $properties = { title: Unset, subject: Unset, creator: Unset, keywords: Unset, description: Unset, last_modified_by: Unset, revision: Unset, created: Unset, modified: Unset, preserved: List.with_capacity(4) }
		for child in property_elements(tree, core_namespace, "coreProperties") {
			$properties = match child {
				Element(element) =>
					match core_property(element, $properties) {
						Ok(properties) => properties
						Err(CannotHold) => { ..$properties, preserved: List.append($properties.preserved, child) }
					}

				Text(_) => $properties
			}
		}
		$properties
	}

	## The extended properties of an extended properties part, read as
	## [WmlRead.core_properties] reads core properties: text without markup
	## or attributes, and counts of decimal digits. A tree whose root is not
	## extended properties has none.
	extended_properties : XmlTree.Node -> Document.ExtendedProperties
	extended_properties = |tree| {
		var $properties = {
			application: Unset,
			app_version: Unset,
			company: Unset,
			manager: Unset,
			template: Unset,
			pages: Unset,
			words: Unset,
			characters: Unset,
			characters_with_spaces: Unset,
			lines: Unset,
			paragraphs: Unset,
			total_time: Unset,
			preserved: List.with_capacity(8),
		}
		for child in property_elements(tree, extended_namespace, "Properties") {
			$properties = match child {
				Element(element) =>
					match extended_property(element, $properties) {
						Ok(properties) => properties
						Err(CannotHold) => { ..$properties, preserved: List.append($properties.preserved, child) }
					}

				Text(_) => $properties
			}
		}
		$properties
	}

	## The custom properties of a custom properties part, in order. A
	## property with a name and one value, text (`vt:lpwstr`, `vt:lpstr`,
	## `vt:bstr`), a whole number (`vt:i1` to `vt:i8`, `vt:int`, `vt:ui1` to
	## `vt:ui8`, `vt:uint`), a truth value (`vt:bool`) or a date (`vt:filetime`,
	## `vt:date`), is read; any other is kept as it was read. The property's
	## format and identifier attributes are how the part numbers it, not part
	## of the property. A tree whose root is not custom properties has none.
	custom_properties : XmlTree.Node -> List(Document.CustomProperty)
	custom_properties = |tree|
		property_elements(tree, custom_namespace, "Properties").map(
			|child|
				match custom_property(child) {
					Ok(property) => property
					Err(CannotHold) => Preserved(child)
				},
		)

	## Whether a settings part's tree says that changes are tracked: its
	## first `w:trackRevisions` is on, in any spelling the schema allows. A
	## tree whose root is not WordprocessingML settings, or that has none, or
	## whose value is not one the schema allows, does not.
	tracks_revisions : XmlTree.Node -> Bool
	tracks_revisions = |tree| setting_on(tree, "trackRevisions")

	## Whether a settings part's tree says that odd and even pages have
	## different headers and footers: its first `w:evenAndOddHeaders` is on,
	## read as [WmlRead.tracks_revisions] reads tracking. When they do, a
	## section's `Even` headers and footers are for its even pages and its
	## `Default` ones for its odd pages; when they do not, `Default` ones
	## are for every page and `Even` ones are not shown.
	different_odd_and_even : XmlTree.Node -> Bool
	different_odd_and_even = |tree| setting_on(tree, "evenAndOddHeaders")

	## Something the reader accepted that the schema does not allow: a number
	## the schema wants whole written with a fraction, such as the width
	## `w:w="10470.0"` that Google Docs exports write, or a percentage finer
	## than the fiftieths of a per cent the model holds, read rounded to the
	## nearest, halves away from zero; or a required attribute that is
	## missing, such as the gutter Google Docs exports leave out of a
	## section's margins, read as zero. `element` and `attribute` are the
	## local names of the WordprocessingML element and attribute, and `value`
	## is the value as the document wrote it.
	##
	## Or an entry of a part beside the comments part that the model does
	## not hold as it was written, `NotApplied`: an entry of the extended
	## comments, comment identifiers or extensible comments parts (`element`
	## `commentEx`, `commentId` or `commentExtensible`) that names no
	## comment, repeats an identifier a later entry has, or holds what the
	## model cannot, keyed by the paragraph or durable identifier it names;
	## or a person's presence (`presenceInfo`) without both a provider and an
	## identifier, keyed by the person's author. What is not applied is kept
	## and written back as it was read, as [Comments.kept] says.
	Diagnostic : [Rounded({ element : Str, attribute : Str, value : Str }), Defaulted({ element : Str, attribute : Str }), NotApplied({ element : Str, key : Str })]

	## A paragraph's properties from the children of its `w:pPr`, or of a
	## style's or the document defaults' `w:pPr`. Each modelled property is
	## read from its first element; an element whose attributes or children
	## the model cannot represent, a repeated one and every other element are
	## kept in `preserved` as they were read, in order. On and off values
	## take every spelling the schema allows (`true`, `1`, `on` and their
	## opposites, and no value for on).
	##
	## Under tracking, the `w:ins`, `w:del`, `w:moveFrom` and `w:moveTo` of
	## the first `w:rPr`, the paragraph mark's character properties, are the
	## mark's changes, its other children staying in a `w:rPr` kept in
	## `preserved`, and `w:pPrChange` is a change of the properties, the
	## properties it holds read as these are. A change without the author the
	## schema requires is kept as it was read.
	paragraph_properties : List(XmlTree.Node) -> Document.ParagraphProperties
	paragraph_properties = |nodes| paragraph_properties_from(nodes, Document.no_paragraph_properties, tracked_paragraph)

	## A run's properties from the children of its `w:rPr`, or of a style's
	## or the document defaults' `w:rPr`, read as
	## [WmlRead.paragraph_properties] reads a paragraph's; `w:rPrChange` is a
	## change of the properties.
	run_properties : List(XmlTree.Node) -> Document.RunProperties
	run_properties = |nodes| run_properties_from(nodes, Document.no_run_properties, tracked_run)

	## The alignment a paragraph's `w:jc` or a list level's `w:lvlJc` names,
	## as the schema spells it.
	alignment : Str -> Try(Document.Alignment, [CannotHold])
	alignment = |value| paragraph_alignment(value)
}

# Whether the first setting named `local` of a settings part's tree is on.
setting_on : XmlTree.Node, Str -> Bool
setting_on = |tree, local|
	match tree {
		Element(root) if is_w(root.name, "settings") =>
			match root.children.find_first(|child| is_element(child, local)) {
				Ok(Element(element)) => on_off(element) == Ok(On)
				_ => Bool.False
			}

		_ => Bool.False
	}

# What reading a part looks up: its relationships and its bookmarks' names by
# identifier, each note's and comment's place by identifier, and the names of
# its moves' source and destination ranges by identifier; and whether what is
# read is deleted content, where deleted text is text.
Reading : {
	relationships : Dict(Str, Opc.Relationship),
	bookmarks : Dict(Str, Str),
	footnotes : Dict(Str, U64),
	endnotes : Dict(Str, U64),
	comments : Dict(Str, U64),
	move_sources : Dict(Str, Str),
	move_destinations : Dict(Str, Str),
	deleted : Bool,
}

reading : XmlTree.Node, WmlRead.Context -> Reading
reading = |tree, context| reading_with(context, range_names(tree))

reading_with : WmlRead.Context, RangeNames -> Reading
reading_with = |context, names| {
	var $relationships = Dict.with_capacity(context.relationships.len())
	for relationship in context.relationships {
		$relationships = $relationships.insert(relationship.id, relationship)
	}
	{
		relationships: $relationships,
		bookmarks: names.bookmarks,
		footnotes: places(context.footnotes),
		endnotes: places(context.endnotes),
		comments: places(context.comments),
		move_sources: names.move_sources,
		move_destinations: names.move_destinations,
		deleted: Bool.False,
	}
}

# What the first pass of [WmlRead.body_reader] carries: the range names so
# far, the depth of the element being read and that of the element whose
# content holds no range names being passed over, if any.
NamesScan : { names : RangeNames, depth : U64, opaque : U64 }

# What the second pass of [WmlRead.body_reader] carries: what reading looks
# up, and the blocks read so far with what reading them noticed.
BodyReading : { within : Reading, read : { blocks : List(Document.Block), diagnostics : List(WmlRead.Diagnostic) } }

# The range names of a part read as events, as [range_names] finds them in
# its tree.
names_step : NamesScan, XmlTree.Event -> NamesScan
names_step = |state, event|
	match event {
		Start(start) => {
			depth = state.depth + 1
			if state.opaque > 0 {
				{ ..state, depth }
			} else {
				match range_rule(start.name, start.attributes) {
					Named(named) => { names: with_name(state.names, named), depth, opaque: depth }
					Opaque => { ..state, depth, opaque: depth }
					Through => { ..state, depth }
				}
			}
		}

		End =>
			if state.opaque == state.depth {
				{ ..state, depth: state.depth - 1, opaque: 0 }
			} else {
				{ ..state, depth: state.depth - 1 }
			}
	}

places : List(Str) -> Dict(Str, U64)
places = |ids| {
	var $places = Dict.with_capacity(ids.len())
	var $index = 0.U64
	for id in ids {
		$places = $places.insert(id, $index)
		$index = $index + 1
	}
	$places
}

# The names of a tree's bookmarks, and of its moves' source and destination
# ranges, by identifier, from every start that has both and that the reader
# models, a move's with its author and date, outside runs,
# property elements of any namespace and bookmark ends, where none ever is.
# The tree is walked as deep as the readers walk it, within the XML depth
# limit, without copying any list of children.
RangeNames : { bookmarks : Dict(Str, Str), move_sources : Dict(Str, Str), move_destinations : Dict(Str, Str) }

no_range_names : RangeNames
no_range_names = { bookmarks: Dict.with_capacity(0), move_sources: Dict.with_capacity(0), move_destinations: Dict.with_capacity(0) }

range_names : XmlTree.Node -> RangeNames
range_names = |root| names_in(no_range_names, root)

names_in : RangeNames, XmlTree.Node -> RangeNames
names_in = |names, node|
	match node {
		Element(element) =>
			match range_rule(element.name, element.attributes) {
				Named(named) => with_name(names, named)
				Opaque => names
				Through => element.children.fold(names, names_in)
			}

		Text(_) => names
	}

# What an element is to the range names: the start of a bookmark or of a
# move's source or destination range with its identifier and name, an
# element whose content holds none, or one whose content is looked through.
# Names are compared by local name first, as comparing a namespace costs an
# allocation.
range_rule : XmlTree.Name, List(XmlTree.Attribute) -> [Named({ range : [Bookmark, MoveSource, MoveDestination], id : Str, name : Str }), Opaque, Through]
range_rule = |name, attributes| {
	range = if name.local == "bookmarkStart" and is_w(name, "bookmarkStart") {
		Ok(Bookmark)
	} else if name.local == "moveFromRangeStart" and is_w(name, "moveFromRangeStart") {
		Ok(MoveSource)
	} else if name.local == "moveToRangeStart" and is_w(name, "moveToRangeStart") {
		Ok(MoveDestination)
	} else {
		Err(NotARange)
	}
	match range {
		Ok(Bookmark) =>
			match (attribute_value(attributes, "id"), attribute_value(attributes, "name")) {
				(Ok(id), Ok(named)) => Named({ range: Bookmark, id, name: named })
				_ => Opaque
			}

		Ok(kind) =>
			match (attribute_value(attributes, "id"), attribute_value(attributes, "name"), attribute_value(attributes, "author"), attribute_value(attributes, "date").map_ok(timestamp)) {
				(Ok(id), Ok(named), Ok(_), Ok(Ok(_))) => Named({ range: kind, id, name: named })
				_ => Opaque
			}

		Err(NotARange) =>
			if name.local == "r" or name.local.ends_with("Pr") or (name.local == "bookmarkEnd" and is_w(name, "bookmarkEnd")) {
				Opaque
			} else {
				Through
			}
	}
}

with_name : RangeNames, { range : [Bookmark, MoveSource, MoveDestination], id : Str, name : Str } -> RangeNames
with_name = |names, named|
	match named.range {
		Bookmark => { ..names, bookmarks: names.bookmarks.insert(named.id, named.name) }
		MoveSource => { ..names, move_sources: names.move_sources.insert(named.id, named.name) }
		MoveDestination => { ..names, move_destinations: names.move_destinations.insert(named.id, named.name) }
	}

# The note elements of a footnotes or endnotes part's root.
note_elements : XmlTree.Node -> List(Element)
note_elements = |root|
	match root {
		Element(element) if is_w(element.name, "footnotes") or is_w(element.name, "endnotes") =>
			element.children.keep_oks(
				|child|
					match child {
						Element(note) if is_w(note.name, "footnote") or is_w(note.name, "endnote") => Ok(note)
						_ => Err(NotANote)
					},
			)

		_ => []
	}

# The comment elements of a comments part's root.
comment_elements : XmlTree.Node -> List(Element)
comment_elements = |root|
	match root {
		Element(element) if is_w(element.name, "comments") =>
			element.children.keep_oks(
				|child|
					match child {
						Element(comment) if is_w(comment.name, "comment") => Ok(comment)
						_ => Err(NotAComment)
					},
			)

		_ => []
	}

# A date and time in the XML Schema `dateTime` form: a four-digit year, month
# and day, `T`, hours, minutes and seconds with an optional fraction, and an
# optional zone, `Z` or an offset in hours and minutes.
timestamp : Str -> Try(Document.Timestamp, [NotDate])
timestamp = |written| {
	bytes = written.to_utf8()
	at = |index, byte| bytes.get(index) == Ok(byte)
	number = |start, count| {
		var $sum = 0.I64
		var $index = start
		while $index < start + count {
			match bytes.get($index) {
				Ok(digit) if digit >= '0' and digit <= '9' => {
					$sum = $sum * 10 + (digit - '0').to_i64()
				}

				_ => {
					return Err(NotDate)
				}
			}
			$index = $index + 1
		}
		Ok($sum)
	}
	if !(at(4, '-') and at(7, '-') and at(10, 'T') and at(13, ':') and at(16, ':')) {
		return Err(NotDate)
	}
	year = number(0, 4)?
	month = number(5, 2)?
	day = number(8, 2)?
	hour = number(11, 2)?
	minute = number(14, 2)?
	second = number(17, 2)?
	var $zone = 19.U64
	if at(19, '.') {
		$zone = 20
		while bytes.get($zone).map_ok(|digit| digit >= '0' and digit <= '9') == Ok(Bool.True) {
			$zone = $zone + 1
		}
		if $zone == 20 {
			return Err(NotDate)
		}
	}
	rest = bytes.len() - $zone
	offset = if rest == 0 or (rest == 1 and at($zone, 'Z')) {
		0
	} else if rest == 6 and (at($zone, '+') or at($zone, '-')) and at($zone + 3, ':') {
		minutes = number($zone + 1, 2)? * 60 + number($zone + 4, 2)?
		if (at($zone, '-')) 0 - minutes else minutes
	} else {
		return Err(NotDate)
	}
	if month < 1 or month > 12 or day < 1 or day > days_in_month(year, month) or hour > 23 or minute > 59 or second > 59 {
		return Err(NotDate)
	}
	Ok({ written, utc_seconds: days_from_civil(year, month, day) * 86400 + hour * 3600 + minute * 60 + second - offset * 60 })
}

days_in_month : I64, I64 -> I64
days_in_month = |year, month|
	if month == 2 {
		if ((year % 4 == 0 and year % 100 != 0) or year % 400 == 0) 29 else 28
	} else if month == 4 or month == 6 or month == 9 or month == 11 {
		30
	} else {
		31
	}

# The days from 1970-01-01 to a day of the proleptic Gregorian calendar,
# counting each year from March so that a leap day ends it.
days_from_civil : I64, I64, I64 -> I64
days_from_civil = |year, month, day| {
	shifted = if (month <= 2) year - 1 else year
	era = (if (shifted >= 0) shifted else shifted - 399) // 400
	of_era = shifted - era * 400
	of_year = (153 * (if (month > 2) month - 3 else month + 9) + 2) // 5 + day - 1
	era * 146097 + of_era * 365 + of_era // 4 - of_era // 100 + of_year - 719468
}

# How a reader of properties reads a tracked change among them: given the
# properties read so far, an element and the local names of the property
# elements already read, the properties with the element read into them, or
# `NotTracking` when the element is not a change it reads. The properties a
# change replaced are read with `untracked`, as they have no changes of their
# own.
Tracking(p) : p, Element, List(Str) -> Try(p, [NotTracking])

untracked : Tracking(p)
untracked = |_, _, _| Err(NotTracking)

paragraph_properties_from : List(XmlTree.Node), Document.ParagraphPropertiesOf(c), Tracking(Document.ParagraphPropertiesOf(c)) -> Document.ParagraphPropertiesOf(c)
paragraph_properties_from = |nodes, start, tracking| {
	var $properties = start
	var $taken = List.with_capacity(8)
	for node in nodes {
		tracked = match node {
			Element(element) => tracking($properties, element, $taken)
			Text(_) => Err(NotTracking)
		}
		match (tracked, node) {
			(Ok(next), Element(element)) => {
				$properties = next
				$taken = List.append($taken, element.name.local)
			}

			(_, Element(element)) if element.name.namespace == Uri(wordprocessingml) and !$taken.contains(element.name.local) =>
				match paragraph_property($properties, element) {
					Ok(next) => {
						$properties = next
						$taken = List.append($taken, element.name.local)
					}

					Err(CannotHold) => {
						$properties = { ..$properties, preserved: List.append($properties.preserved, node) }
					}
				}

			_ => {
				if is_content(node) {
					$properties = { ..$properties, preserved: List.append($properties.preserved, node) }
				}
			}
		}
	}
	$properties
}

# A paragraph mark's changes in the first `w:rPr`, and the first
# `w:pPrChange`.
tracked_paragraph : Tracking(Document.ParagraphProperties)
tracked_paragraph = |properties, element, taken|
	if element.name.local == "rPr" and !taken.contains("rPr") and element.children.any(
		|child| match child {
			Element(change) => mark_kind(change.name.local).is_ok()
			Text(_) => Bool.False
		},
	) and is_w(element.name, "rPr") {
		read = mark_of(element)
		Ok({ ..properties, mark: read.mark, preserved: List.concat(properties.preserved, read.rest) })
	} else if element.name.local == "pPrChange" and !taken.contains("pPrChange") and is_w(element.name, "pPrChange") {
		match property_change(element, "pPr") {
			Ok({ change, previous }) => Ok({ ..properties, change: [{ author: change.author, date: change.date, preserved: change.preserved, previous: paragraph_properties_from(previous, Document.paragraph_properties_with(Unset), untracked) }] })
			Err(CannotHold) => Ok({ ..properties, preserved: List.append(properties.preserved, Element(element)) })
		}
	} else {
		Err(NotTracking)
	}

run_properties_from : List(XmlTree.Node), Document.RunPropertiesOf(c), Tracking(Document.RunPropertiesOf(c)) -> Document.RunPropertiesOf(c)
run_properties_from = |nodes, start, tracking| {
	var $properties = start
	var $taken = List.with_capacity(8)
	for node in nodes {
		tracked = match node {
			Element(element) => tracking($properties, element, $taken)
			Text(_) => Err(NotTracking)
		}
		match (tracked, node) {
			(Ok(next), Element(element)) => {
				$properties = next
				$taken = List.append($taken, element.name.local)
			}

			(_, Element(element)) if element.name.namespace == Uri(wordprocessingml) and !$taken.contains(element.name.local) =>
				match run_property($properties, element) {
					Ok(next) => {
						$properties = next
						$taken = List.append($taken, element.name.local)
					}

					Err(CannotHold) => {
						$properties = { ..$properties, preserved: List.append($properties.preserved, node) }
					}
				}

			_ => {
				if is_content(node) {
					$properties = { ..$properties, preserved: List.append($properties.preserved, node) }
				}
			}
		}
	}
	$properties
}

# The first `w:rPrChange`.
tracked_run : Tracking(Document.RunProperties)
tracked_run = |properties, element, taken|
	if element.name.local == "rPrChange" and !taken.contains("rPrChange") and is_w(element.name, "rPrChange") {
		match property_change(element, "rPr") {
			Ok({ change, previous }) => Ok({ ..properties, change: [{ author: change.author, date: change.date, preserved: change.preserved, previous: run_properties_from(previous, Document.run_properties_with(Unset), untracked) }] })
			Err(CannotHold) => Ok({ ..properties, preserved: List.append(properties.preserved, Element(element)) })
		}
	} else {
		Err(NotTracking)
	}

# A paragraph mark's character properties: the first change of each kind
# that names its author and holds nothing is the mark's, and what is left,
# unless nothing is, stays a `w:rPr` of its own.
mark_of : Element -> { mark : List(Document.MarkChange), rest : List(XmlTree.Node) }
mark_of = |element| {
	var $mark = List.with_capacity(0)
	var $rest = List.with_capacity(element.children.len())
	for child in element.children {
		read = match child {
			Element(change) if kept(change.children).is_empty() =>
				match (mark_kind(change.name.local), change_of(change)) {
					(Ok(kind), Ok(tracked)) if is_w(change.name, change.name.local) and !$mark.any(|found| found.kind == kind) => Ok({ kind, author: tracked.author, date: tracked.date, preserved: tracked.preserved })
					_ => Err(CannotHold)
				}

			_ => Err(CannotHold)
		}
		match read {
			Ok(found) => {
				$mark = List.append($mark, found)
			}

			Err(CannotHold) => {
				$rest = List.append($rest, child)
			}
		}
	}
	rest =
		if $mark.is_empty() {
			[Element(element)]
		} else if kept($rest).is_empty() and element.attributes.is_empty() {
			[]
		} else {
			[Element({ name: element.name, bindings: element.bindings, attributes: element.attributes, children: $rest })]
		}
	{ mark: $mark.sort_with(|one, other| by_mark_order(one.kind, other.kind)), rest }
}

# The kind of change a paragraph mark's change element records.
mark_kind : Str -> Try(Document.RevisionKind, [NotMark])
mark_kind = |local|
	match local {
		"ins" => Ok(Insertion)
		"del" => Ok(Deletion)
		"moveFrom" => Ok(MoveSource)
		"moveTo" => Ok(MoveDestination)
		_ => Err(NotMark)
	}

# The schema's order of a paragraph mark's changes: inserted, deleted, moved
# away, moved here.
by_mark_order : Document.RevisionKind, Document.RevisionKind -> [Before, Same, After]
by_mark_order = |one, other| {
	rank = |kind|
		match kind {
			Insertion => 0.U8
			Deletion => 1
			MoveSource => 2
			MoveDestination => 3
		}
	if (rank(one) < rank(other)) Before else if (rank(one) > rank(other)) After else Same
}

# Who made a tracked change and when: `w:author`, which the schema requires,
# and `w:date`. The change's document identifier, `w:id`, is replaced by its
# place, and every other attribute is kept.
change_of : Element -> Try(Document.Change, [CannotHold])
change_of = |element| {
	author = value_of(element, "author") ? |_| CannotHold
	stamp = date_of(element)
	Ok({ author, date: stamp, preserved: element.attributes.drop_if(|attribute| is_w_in(attribute.name, ["id", "author"]) or (is_w(attribute.name, "date") and stamp != Unset)) })
}

# A change of properties: who made it and when, and the children of the one
# property element `inner` it holds, without attributes, the properties as
# they were. One that holds nothing, as LibreOffice writes a change of
# properties that had none, which the schema does not allow, had none.
property_change : Element, Str -> Try({ change : Document.Change, previous : List(XmlTree.Node) }, [CannotHold])
property_change = |element, inner| {
	change = change_of(element)?
	held = kept(element.children)
	match held.first() {
		Err(ListWasEmpty) => Ok({ change, previous: [] })
		Ok(Element(properties)) if held.len() == 1 and is_w(properties.name, inner) and properties.attributes.is_empty() => Ok({ change, previous: properties.children })
		_ => Err(CannotHold)
	}
}

# One paragraph property element read into the properties, or `CannotHold`
# when the model cannot represent it.
paragraph_property : Document.ParagraphPropertiesOf(c), Element -> Try(Document.ParagraphPropertiesOf(c), [CannotHold])
paragraph_property = |properties, element|
	match element.name.local {
		"pStyle" => Ok({ ..properties, style: Style(only_value(element)?) })
		"keepNext" => Ok({ ..properties, keep_next: on_off(element)? })
		"keepLines" => Ok({ ..properties, keep_lines: on_off(element)? })
		"pageBreakBefore" => Ok({ ..properties, page_break_before: on_off(element)? })
		"widowControl" => Ok({ ..properties, widow_control: on_off(element)? })
		"outlineLvl" => {
			level = U8.from_str(only_value(element)?) ? |_| CannotHold
			if level > 9 {
				Err(CannotHold)
			} else {
				Ok({ ..properties, outline_level: Level(level) })
			}
		}

		"jc" => Ok({ ..properties, alignment: Aligned(paragraph_alignment(only_value(element)?)?) })
		"ind" => {
			leaf(element, ["left", "right", "firstLine", "hanging"])?
			first_line = match (value_of(element, "firstLine"), value_of(element, "hanging")) {
				(Err(NotFound), Err(NotFound)) => Unset
				(Ok(value), Err(NotFound)) => FirstLine(signed(value)?)
				(Err(NotFound), Ok(value)) => Hanging(signed(value)?)
				_ => return Err(CannotHold)
			}
			Ok({ ..properties, indentation: { left: twips_attribute(element, "left")?, right: twips_attribute(element, "right")?, first_line } })
		}

		"spacing" => {
			leaf(element, ["before", "after", "line", "lineRule"])?
			line = match (value_of(element, "line"), value_of(element, "lineRule")) {
				(Err(NotFound), Err(NotFound)) => Unset
				(Ok(value), Err(NotFound)) => Auto(signed(value)?)
				(Ok(value), Ok("auto")) => Auto(signed(value)?)
				(Ok(value), Ok("exact")) => Exact(signed(value)?)
				(Ok(value), Ok("atLeast")) => AtLeast(signed(value)?)
				_ => return Err(CannotHold)
			}
			Ok({ ..properties, spacing: { before: unsigned_attribute(element, "before")?, after: unsigned_attribute(element, "after")?, line } })
		}

		"pBdr" => {
			read = borders(element, paragraph_edges)?
			if read.noticed.is_empty() {
				Ok({ ..properties, borders: read.value })
			} else {
				Err(CannotHold)
			}
		}

		"shd" => Ok({ ..properties, shading: shading(element)? })

		"tabs" => {
			if !element.attributes.is_empty() {
				return Err(CannotHold)
			}
			var $stops = List.with_capacity(element.children.len())
			for child in element.children {
				match child {
					Element(stop) if is_w(stop.name, "tab") => {
						$stops = List.append($stops, tab_stop(stop)?)
					}

					_ => {
						if is_content(child) {
							return Err(CannotHold)
						}
					}
				}
			}
			if $stops.is_empty() {
				Err(CannotHold)
			} else {
				Ok({ ..properties, tabs: Tabs($stops) })
			}
		}

		"numPr" => {
			if !element.attributes.is_empty() {
				return Err(CannotHold)
			}
			var $numbering = properties.numbering
			var $seen = List.with_capacity(2)
			for child in element.children {
				match child {
					Element(part) if part.name.namespace == Uri(wordprocessingml) and !$seen.contains(part.name.local) => {
						value = only_value(part)?
						$numbering = match part.name.local {
							"numId" => { ..$numbering, instance: Instance(U32.from_str(value) ? |_| CannotHold) }
							"ilvl" => { ..$numbering, level: Level(U8.from_str(value) ? |_| CannotHold) }
							_ => return Err(CannotHold)
						}
						$seen = List.append($seen, part.name.local)
					}

					_ => {
						if is_content(child) {
							return Err(CannotHold)
						}
					}
				}
			}
			Ok({ ..properties, numbering: $numbering })
		}

		_ => Err(CannotHold)
	}

# One run property element read into the properties, or `CannotHold` when
# the model cannot represent it.
run_property : Document.RunPropertiesOf(c), Element -> Try(Document.RunPropertiesOf(c), [CannotHold])
run_property = |properties, element|
	match element.name.local {
		"rStyle" => Ok({ ..properties, style: Style(only_value(element)?) })
		"b" => Ok({ ..properties, bold: on_off(element)? })
		"i" => Ok({ ..properties, italic: on_off(element)? })
		"caps" => Ok({ ..properties, caps: on_off(element)? })
		"smallCaps" => Ok({ ..properties, small_caps: on_off(element)? })
		"strike" => Ok({ ..properties, strike: on_off(element)? })
		"dstrike" => Ok({ ..properties, double_strike: on_off(element)? })
		"vanish" => Ok({ ..properties, hidden: on_off(element)? })
		"u" => Ok({ ..properties, underline: Underline(underline(only_value(element)?)?) })
		"vertAlign" => {
			value = match only_value(element)? {
				"baseline" => Baseline
				"superscript" => Superscript
				"subscript" => Subscript
				_ => return Err(CannotHold)
			}
			Ok({ ..properties, vertical_align: value })
		}

		"color" => {
			leaf(element, ["val", "themeColor", "themeTint", "themeShade"])?
			value = match value_of(element, "val") {
				Ok("auto") => Auto
				Ok(rgb) => Rgb(rgb)
				Err(NotFound) => return Err(CannotHold)
			}
			theme = match value_of(element, "themeColor") {
				Ok(name) => Theme(name)
				Err(NotFound) => Unset
			}
			tint = match value_of(element, "themeTint") {
				Ok(amount) => Tint(amount)
				Err(NotFound) => Unset
			}
			shade = match value_of(element, "themeShade") {
				Ok(amount) => Shade(amount)
				Err(NotFound) => Unset
			}
			Ok({ ..properties, color: Color({ value, theme, tint, shade }) })
		}

		"highlight" => Ok({ ..properties, highlight: Highlight(highlight(only_value(element)?)?) })
		"sz" => Ok({ ..properties, size: HalfPoints(U32.from_str(only_value(element)?) ? |_| CannotHold) })
		"rFonts" => {
			leaf(element, ["ascii", "hAnsi", "eastAsia", "cs", "asciiTheme", "hAnsiTheme", "eastAsiaTheme", "cstheme"])?
			fonts = {
				ascii: named(element, "ascii"),
				high_ansi: named(element, "hAnsi"),
				east_asia: named(element, "eastAsia"),
				complex: named(element, "cs"),
				ascii_theme: theme_font(element, "asciiTheme")?,
				high_ansi_theme: theme_font(element, "hAnsiTheme")?,
				east_asia_theme: theme_font(element, "eastAsiaTheme")?,
				complex_theme: theme_font(element, "cstheme")?,
			}
			Ok({ ..properties, fonts: fonts })
		}

		"lang" => {
			leaf(element, ["val", "eastAsia", "bidi"])?
			Ok({ ..properties, language: { latin: language_tag(element, "val"), east_asia: language_tag(element, "eastAsia"), complex: language_tag(element, "bidi") } })
		}

		_ => Err(CannotHold)
	}

# An element with only WordprocessingML attributes among these names and no
# content.
leaf : Element, List(Str) -> Try({}, [CannotHold])
leaf = |element, locals|
	if holds(element, locals) and !element.children.any(is_content) {
		Ok({})
	} else {
		Err(CannotHold)
	}

# The `w:val` of an element that has only that attribute and no content.
only_value : Element -> Try(Str, [CannotHold])
only_value = |element| {
	leaf(element, ["val"])?
	Ok(value_of(element, "val") ? |_| CannotHold)
}

signed : Str -> Try(I32, [CannotHold])
signed = |value| Ok(I32.from_str(value) ? |_| CannotHold)

twips_attribute : Element, Str -> Try([Unset, Twips(I32)], [CannotHold])
twips_attribute = |element, local|
	match value_of(element, local) {
		Ok(value) => Ok(Twips(signed(value)?))
		Err(NotFound) => Ok(Unset)
	}

unsigned_attribute : Element, Str -> Try([Unset, Twips(U32)], [CannotHold])
unsigned_attribute = |element, local|
	match value_of(element, local) {
		Ok(value) => Ok(Twips(U32.from_str(value) ? |_| CannotHold))
		Err(NotFound) => Ok(Unset)
	}

named : Element, Str -> [Unset, Named(Str)]
named = |element, local|
	match value_of(element, local) {
		Ok(name) => Named(name)
		Err(NotFound) => Unset
	}

language_tag : Element, Str -> [Unset, Tag(Str)]
language_tag = |element, local|
	match value_of(element, local) {
		Ok(tag) => Tag(tag)
		Err(NotFound) => Unset
	}

tab_stop : Element -> Try(Document.TabStop, [CannotHold])
tab_stop = |element| {
	leaf(element, ["val", "pos", "leader"])?
	kind = match value_of(element, "val") {
		Ok("clear") => Clear
		Ok("start") => Start
		Ok("end") => End
		Ok("left") => Left
		Ok("right") => Right
		Ok("center") => Center
		Ok("decimal") => Decimal
		Ok("bar") => Bar
		Ok("num") => Num
		_ => return Err(CannotHold)
	}
	leader = match value_of(element, "leader") {
		Err(NotFound) => Unset
		Ok("none") => NoLeader
		Ok("dot") => Dot
		Ok("hyphen") => Hyphen
		Ok("underscore") => Underscore
		Ok("heavy") => Heavy
		Ok("middleDot") => MiddleDot
		Ok(_) => return Err(CannotHold)
	}
	position = signed(value_of(element, "pos") ? |_| CannotHold)?
	Ok({ kind, position, leader })
}

paragraph_alignment : Str -> Try(Document.Alignment, [CannotHold])
paragraph_alignment = |value|
	match value {
		"start" => Ok(Start)
		"end" => Ok(End)
		"left" => Ok(Left)
		"right" => Ok(Right)
		"center" => Ok(Center)
		"both" => Ok(Both)
		"distribute" => Ok(Distribute)
		"mediumKashida" => Ok(MediumKashida)
		"highKashida" => Ok(HighKashida)
		"lowKashida" => Ok(LowKashida)
		"thaiDistribute" => Ok(ThaiDistribute)
		"numTab" => Ok(NumTab)
		_ => Err(CannotHold)
	}

underline : Str -> Try(Document.Underline, [CannotHold])
underline = |value|
	match value {
		"single" => Ok(Single)
		"words" => Ok(Words)
		"double" => Ok(Double)
		"thick" => Ok(Thick)
		"dotted" => Ok(Dotted)
		"dottedHeavy" => Ok(DottedHeavy)
		"dash" => Ok(Dash)
		"dashedHeavy" => Ok(DashedHeavy)
		"dashLong" => Ok(DashLong)
		"dashLongHeavy" => Ok(DashLongHeavy)
		"dotDash" => Ok(DotDash)
		"dashDotHeavy" => Ok(DashDotHeavy)
		"dotDotDash" => Ok(DotDotDash)
		"dashDotDotHeavy" => Ok(DashDotDotHeavy)
		"wave" => Ok(Wave)
		"wavyHeavy" => Ok(WavyHeavy)
		"wavyDouble" => Ok(WavyDouble)
		"none" => Ok(NoUnderline)
		_ => Err(CannotHold)
	}

highlight : Str -> Try(Document.Highlight, [CannotHold])
highlight = |value|
	match value {
		"black" => Ok(Black)
		"blue" => Ok(Blue)
		"cyan" => Ok(Cyan)
		"green" => Ok(Green)
		"magenta" => Ok(Magenta)
		"red" => Ok(Red)
		"yellow" => Ok(Yellow)
		"white" => Ok(White)
		"darkBlue" => Ok(DarkBlue)
		"darkCyan" => Ok(DarkCyan)
		"darkGreen" => Ok(DarkGreen)
		"darkMagenta" => Ok(DarkMagenta)
		"darkRed" => Ok(DarkRed)
		"darkYellow" => Ok(DarkYellow)
		"darkGray" => Ok(DarkGray)
		"lightGray" => Ok(LightGray)
		"none" => Ok(NoHighlight)
		_ => Err(CannotHold)
	}

theme_font : Element, Str -> Try([Unset, Theme(Document.ThemeFont)], [CannotHold])
theme_font = |element, local|
	match value_of(element, local) {
		Err(NotFound) => Ok(Unset)
		Ok("majorEastAsia") => Ok(Theme(MajorEastAsia))
		Ok("majorBidi") => Ok(Theme(MajorBidi))
		Ok("majorAscii") => Ok(Theme(MajorAscii))
		Ok("majorHAnsi") => Ok(Theme(MajorHighAnsi))
		Ok("minorEastAsia") => Ok(Theme(MinorEastAsia))
		Ok("minorBidi") => Ok(Theme(MinorBidi))
		Ok("minorAscii") => Ok(Theme(MinorAscii))
		Ok("minorHAnsi") => Ok(Theme(MinorHighAnsi))
		Ok(_) => Err(CannotHold)
	}

# Elements whose content is blocks, read as containers in a block's place.
block_containers : List(Str)
block_containers = ["sdt", "sdtContent", "customXml"]

# Elements whose content is paragraph content, read as containers in an
# inline's place.
inline_containers : List(Str)
inline_containers = ["sdt", "sdtContent", "smartTag", "customXml", "dir", "bdo"]

# Block reading carries what it has noticed so far and gives it back with
# what it read.
blocks : List(XmlTree.Node), Reading, List(WmlRead.Diagnostic) -> { blocks : List(Document.Block), diagnostics : List(WmlRead.Diagnostic) }
blocks = |nodes, within, diagnostics| {
	var $read = { blocks: List.with_capacity(nodes.len()), diagnostics }
	for node in nodes {
		$read = block_step($read, node, within)
	}
	$read
}

# The blocks read so far with the next node read after them: nothing for
# whitespace, and a paragraph whose mark ends a section followed by the
# section.
block_step : { blocks : List(Document.Block), diagnostics : List(WmlRead.Diagnostic) }, XmlTree.Node, Reading -> { blocks : List(Document.Block), diagnostics : List(WmlRead.Diagnostic) }
block_step = |so_far, node, within|
	if is_content(node) {
		read = block(node, within, so_far.diagnostics)
		match read.block {
			Paragraph(read_paragraph) if read_paragraph.properties.preserved.any(is_plain_section) => {
				ended = section_end(read_paragraph, within, read.diagnostics)
				{ blocks: List.append(List.append(so_far.blocks, Paragraph(ended.paragraph)), Section(ended.section)), diagnostics: ended.diagnostics }
			}

			_ => { blocks: List.append(so_far.blocks, read.block), diagnostics: read.diagnostics }
		}
	} else {
		so_far
	}

# A paragraph whose mark ends a section holds the section's properties in its
# own; they are read as the section that ends after it.
section_end : Document.Paragraph, Reading, List(WmlRead.Diagnostic) -> { paragraph : Document.Paragraph, section : Document.Section, diagnostics : List(WmlRead.Diagnostic) }
section_end = |paragraph, within, diagnostics| {
	var $preserved = List.with_capacity(paragraph.properties.preserved.len())
	var $properties = Err(Missing)
	for property in paragraph.properties.preserved {
		match ($properties, property) {
			(Err(Missing), Element(element)) if is_w(element.name, "sectPr") and element.attributes.is_empty() => {
				$properties = Ok(element.children)
			}

			_ => {
				$preserved = List.append($preserved, property)
			}
		}
	}
	read = section($properties ?? [], within, diagnostics)
	{ paragraph: { ..paragraph, properties: { ..paragraph.properties, preserved: $preserved } }, section: read.section, diagnostics: read.diagnostics }
}

# A section's properties: each the model holds is read from the first
# element that gives it in a form the model can hold, a header or footer
# from the first reference of its kind to a header or footer part of the
# package. Under tracking, `w:sectPrChange` is a change of the properties.
section : List(XmlTree.Node), Reading, List(WmlRead.Diagnostic) -> { section : Document.Section, diagnostics : List(WmlRead.Diagnostic) }
section = |children, within, diagnostics| section_from(children, diagnostics, unstated_section([]), |found, element| tracked_section(within, found, element))

# How a reader of a section's or a table's, row's or cell's properties reads
# what only the properties that stand hold, such as a tracked change of
# them: the properties with the element read into them and what reading it
# noticed, `CannotHold` when the element is one it reads but cannot hold, or
# `NotTracking` when it is not one it reads.
TrackingRead(p) : p, Element -> Try(Read(p), [CannotHold, NotTracking])

untracked_read : TrackingRead(p)
untracked_read = |_, _| Err(NotTracking)

unstated_section : change -> Document.SectionOf(change)
unstated_section = |change| { start: Unset, page_size: Unset, margins: Unset, columns: Unset, page_numbers: Unset, title_page: Unset, headers: [], footers: [], preserved: [], change }

# A section's headers and footers, which the properties a change replaced do
# not have, and its first `w:sectPrChange`.
tracked_section : Reading, Document.Section, Element -> Try(Read(Document.Section), [CannotHold, NotTracking])
tracked_section = |within, found, element|
	if element.name.local == "headerReference" and is_w(element.name, "headerReference") {
		reference = header_footer_reference(element, within, header_relationship, found.headers) ? |_| CannotHold
		Ok({ value: { ..found, headers: List.append(found.headers, reference) }, noticed: [] })
	} else if element.name.local == "footerReference" and is_w(element.name, "footerReference") {
		reference = header_footer_reference(element, within, footer_relationship, found.footers) ? |_| CannotHold
		Ok({ value: { ..found, footers: List.append(found.footers, reference) }, noticed: [] })
	} else if element.name.local == "sectPrChange" and found.change.is_empty() and is_w(element.name, "sectPrChange") {
		{ change, previous } = property_change(element, "sectPr") ? |_| CannotHold
		before = section_from(previous, [], unstated_section(Unset), untracked_read)
		Ok({ value: { ..found, change: [{ author: change.author, date: change.date, preserved: change.preserved, previous: before.section }] }, noticed: before.diagnostics })
	} else {
		Err(NotTracking)
	}

section_from : List(XmlTree.Node), List(WmlRead.Diagnostic), Document.SectionOf(c), TrackingRead(Document.SectionOf(c)) -> { section : Document.SectionOf(c), diagnostics : List(WmlRead.Diagnostic) }
section_from = |children, diagnostics, start, tracking| {
	var $section = { ..start, preserved: List.with_capacity(children.len()) }
	var $diagnostics = diagnostics
	for child in kept(children) {
		read = match child {
			Element(element) =>
				match tracking($section, element) {
					Ok(found) => Ok(found)
					Err(CannotHold) => Err(CannotHold)
					Err(NotTracking) => section_property($section, element)
				}

			Text(_) => Err(CannotHold)
		}
		match read {
			Ok({ value, noticed }) => {
				$section = value
				$diagnostics = List.concat($diagnostics, noticed)
			}

			Err(CannotHold) => {
				$section = { ..$section, preserved: List.append($section.preserved, child) }
			}
		}
	}
	{ section: $section, diagnostics: $diagnostics }
}

# One section property element read into the properties, unless it was
# given before.
section_property : Document.SectionOf(c), Element -> Try(Read(Document.SectionOf(c)), [CannotHold])
section_property = |found, element|
	if is_w(element.name, "type") and found.start == Unset {
		section_start(element).map_ok(|start| { value: { ..found, start }, noticed: [] })
	} else if is_w(element.name, "pgSz") and found.page_size == Unset {
		page_size(element).map_ok(|size| { value: { ..found, page_size: size.value }, noticed: size.noticed })
	} else if is_w(element.name, "pgMar") and found.margins == Unset {
		margins(element).map_ok(|margins_read| { value: { ..found, margins: margins_read.value }, noticed: margins_read.noticed })
	} else if is_w(element.name, "cols") and found.columns == Unset {
		section_columns(element).map_ok(|columns_read| { value: { ..found, columns: columns_read.value }, noticed: columns_read.noticed })
	} else if is_w(element.name, "pgNumType") and found.page_numbers == Unset {
		page_numbers(element).map_ok(|numbers| { value: { ..found, page_numbers: numbers.value }, noticed: numbers.noticed })
	} else if is_w(element.name, "titlePg") and found.title_page == Unset {
		on_off(element).map_ok(|title_page| { value: { ..found, title_page }, noticed: [] })
	} else {
		Err(CannotHold)
	}

# A reference to a header or footer: its kind, and `r:id` naming an internal
# relationship of the expected type; a section has one of each kind.
header_footer_reference : Element, Reading, Str, List(Document.HeaderFooter) -> Try(Document.HeaderFooter, [CannotHold])
header_footer_reference = |element, within, relationship_kind, existing| {
	if !element.attributes.all(|attribute| is_w(attribute.name, "type") or is_r(attribute.name, "id")) {
		return Err(CannotHold)
	}
	kind = match value_of(element, "type") {
		Ok("default") => Default
		Ok("first") => First
		Ok("even") => Even
		_ => return Err(CannotHold)
	}
	if existing.any(|reference| reference.kind == kind) {
		return Err(CannotHold)
	}
	id = relationship_of(element, "id") ? |_| CannotHold
	match within.relationships.get(id) {
		Ok({ id: _, kind: found, target, mode: Internal }) if found == relationship_kind => Ok({ kind, part: target })
		_ => Err(CannotHold)
	}
}

# Where a section starts: no `w:val` is on the next page.
section_start : Element -> Try([Unset, NextPage, Continuous, EvenPage, OddPage, NextColumn], [CannotHold])
section_start = |element| {
	if !holds(element, ["val"]) {
		return Err(CannotHold)
	}
	match value_of(element, "val") {
		Err(NotFound) | Ok("nextPage") => Ok(NextPage)
		Ok("continuous") => Ok(Continuous)
		Ok("evenPage") => Ok(EvenPage)
		Ok("oddPage") => Ok(OddPage)
		Ok("nextColumn") => Ok(NextColumn)
		Ok(_) => Err(CannotHold)
	}
}

# A page size: its width and height, and its orientation, portrait unless
# it says otherwise. A size without both lengths, or naming a paper by its
# code, cannot be held.
page_size : Element -> Try(Read([Unset, Size({ width : U64, height : U64, orientation : [Portrait, Landscape] })]), [CannotHold])
page_size = |element| {
	if !holds(element, ["w", "h", "orient"]) {
		return Err(CannotHold)
	}
	width = unsigned(element, "w")?
	height = unsigned(element, "h")?
	orientation = match value_of(element, "orient") {
		Err(NotFound) | Ok("portrait") => Portrait
		Ok("landscape") => Landscape
		Ok(_) => return Err(CannotHold)
	}
	Ok({ value: Size({ width: width.value, height: height.value, orientation }), noticed: List.concat(width.noticed, height.noticed) })
}

# Page margins: every one is required, and one that is missing is zero,
# noticed.
margins : Element -> Try(Read([Unset, Margins({ top : I64, right : U64, bottom : I64, left : U64, header : U64, footer : U64, gutter : U64 })]), [CannotHold])
margins = |element| {
	if !holds(element, ["top", "right", "bottom", "left", "header", "footer", "gutter"]) {
		return Err(CannotHold)
	}
	top = whole_or_zero(element, "top")?
	right = unsigned_or_zero(element, "right")?
	bottom = whole_or_zero(element, "bottom")?
	left = unsigned_or_zero(element, "left")?
	header = unsigned_or_zero(element, "header")?
	footer = unsigned_or_zero(element, "footer")?
	gutter = unsigned_or_zero(element, "gutter")?
	noticed = [top.noticed, right.noticed, bottom.noticed, left.noticed, header.noticed, footer.noticed, gutter.noticed].fold(List.with_capacity(0), List.concat)
	Ok({ value: Margins({ top: top.value, right: right.value, bottom: bottom.value, left: left.value, header: header.value, footer: footer.value, gutter: gutter.value }), noticed })
}

whole_or_zero : Element, Str -> Try(Read(I64), [CannotHold])
whole_or_zero = |element, local|
	match value_of(element, local) {
		Ok(_) => whole(element, local)
		Err(NotFound) => Ok({ value: 0, noticed: [Defaulted({ element: element.name.local, attribute: local })] })
	}

unsigned_or_zero : Element, Str -> Try(Read(U64), [CannotHold])
unsigned_or_zero = |element, local|
	match value_of(element, local) {
		Ok(_) => unsigned(element, local)
		Err(NotFound) => Ok({ value: 0, noticed: [Defaulted({ element: element.name.local, attribute: local })] })
	}

SectionColumns : [Unset, Equal({ count : U64, space : U64, separator : [NoLine, Line] }), Unequal({ widths : List({ width : U64, space : U64 }), separator : [NoLine, Line] })]

# Columns of equal width, one unless `w:num` says otherwise with 720 twips
# between them unless `w:space` does, or, when `w:equalWidth` is off, each
# `w:col` with its width and the space after it, none by default. The space
# and count of unequal columns are their columns', as the schema says.
section_columns : Element -> Try(Read(SectionColumns), [CannotHold])
section_columns = |element| {
	if !holds(element, ["equalWidth", "space", "num", "sep"]) {
		return Err(CannotHold)
	}
	separator = match value_of(element, "sep") {
		Err(NotFound) => NoLine
		Ok(text) => if (toggle(text)? == On) Line else NoLine
	}
	equal = match value_of(element, "equalWidth") {
		Err(NotFound) => On
		Ok(text) => toggle(text)?
	}
	listed = kept(element.children)
	if equal == On {
		if !listed.is_empty() {
			return Err(CannotHold)
		}
		count = match value_of(element, "num") {
			Ok(_) => unsigned(element, "num")?
			Err(NotFound) => { value: 1, noticed: [] }
		}
		space = match value_of(element, "space") {
			Ok(_) => unsigned(element, "space")?
			Err(NotFound) => { value: 720, noticed: [] }
		}
		Ok({ value: Equal({ count: count.value, space: space.value, separator }), noticed: List.concat(count.noticed, space.noticed) })
	} else {
		var $widths = List.with_capacity(listed.len())
		var $noticed = List.with_capacity(0)
		for child in listed {
			match child {
				Element(column) if is_w(column.name, "col") and holds(column, ["w", "space"]) => {
					width = unsigned(column, "w")?
					space = match value_of(column, "space") {
						Ok(_) => unsigned(column, "space")?
						Err(NotFound) => { value: 0, noticed: [] }
					}
					$widths = List.append($widths, { width: width.value, space: space.value })
					$noticed = List.concat($noticed, List.concat(width.noticed, space.noticed))
				}

				_ => {
					return Err(CannotHold)
				}
			}
		}
		if $widths.is_empty() {
			Err(CannotHold)
		} else {
			Ok({ value: Unequal({ widths: $widths, separator }), noticed: $noticed })
		}
	}
}

# Page numbering: its format and the number it starts from. Chapter
# numbering in page numbers cannot be held.
page_numbers : Element -> Try(Read([Unset, PageNumbers({ format : [Unset, Format(Str)], start : [Unset, Start(U64)] })]), [CannotHold])
page_numbers = |element| {
	if !holds(element, ["fmt", "start"]) {
		return Err(CannotHold)
	}
	format = match value_of(element, "fmt") {
		Ok(name) => Format(name)
		Err(NotFound) => Unset
	}
	match value_of(element, "start") {
		Ok(_) => {
			first = unsigned(element, "start")?
			Ok({ value: PageNumbers({ format, start: Start(first.value) }), noticed: first.noticed })
		}

		Err(NotFound) => Ok({ value: PageNumbers({ format, start: Unset }), noticed: [] })
	}
}

# An on or off value as the schema spells it.
toggle : Str -> Try([On, Off], [CannotHold])
toggle = |text|
	match text {
		"true" | "1" | "on" => Ok(On)
		"false" | "0" | "off" => Ok(Off)
		_ => Err(CannotHold)
	}

header_relationship : Str
header_relationship = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/header"

footer_relationship : Str
footer_relationship = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer"

core_namespace : Str
core_namespace = "http://schemas.openxmlformats.org/package/2006/metadata/core-properties"

dublin_core : Str
dublin_core = "http://purl.org/dc/elements/1.1/"

dc_terms : Str
dc_terms = "http://purl.org/dc/terms/"

extended_namespace : Str
extended_namespace = "http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"

custom_namespace : Str
custom_namespace = "http://schemas.openxmlformats.org/officeDocument/2006/custom-properties"

variant_types : Str
variant_types = "http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"

instance_namespace : Str
instance_namespace = "http://www.w3.org/2001/XMLSchema-instance"

# The properties of a properties part: its root's elements, when the root is
# the one named, after markup compatibility processing.
property_elements : XmlTree.Node, Str, Str -> List(XmlTree.Node)
property_elements = |tree, namespace, local| {
	interpreted = Mce.process(tree).interpreted
	match interpreted {
		Element(root) if is_named(interpreted, namespace, local) => root.children.keep_if(|child| is_named_element(child))
		_ => []
	}
}

is_named_element : XmlTree.Node -> Bool
is_named_element = |node|
	match node {
		Element(_) => Bool.True
		Text(_) => Bool.False
	}

core_property : Element, Document.CoreProperties -> Try(Document.CoreProperties, [CannotHold])
core_property = |element, properties|
	match (element.name.namespace, element.name.local) {
		(Uri(namespace), "title") if namespace == dublin_core and properties.title == Unset => Ok({ ..properties, title: Text(plain_text(element)?) })
		(Uri(namespace), "subject") if namespace == dublin_core and properties.subject == Unset => Ok({ ..properties, subject: Text(plain_text(element)?) })
		(Uri(namespace), "creator") if namespace == dublin_core and properties.creator == Unset => Ok({ ..properties, creator: Text(plain_text(element)?) })
		(Uri(namespace), "description") if namespace == dublin_core and properties.description == Unset => Ok({ ..properties, description: Text(plain_text(element)?) })
		(Uri(namespace), "keywords") if namespace == core_namespace and properties.keywords == Unset => Ok({ ..properties, keywords: Text(plain_text(element)?) })
		(Uri(namespace), "lastModifiedBy") if namespace == core_namespace and properties.last_modified_by == Unset => Ok({ ..properties, last_modified_by: Text(plain_text(element)?) })
		(Uri(namespace), "revision") if namespace == core_namespace and properties.revision == Unset => Ok({ ..properties, revision: Number(natural(plain_text(element)?) ? |_| CannotHold) })
		(Uri(namespace), "created") if namespace == dc_terms and properties.created == Unset => Ok({ ..properties, created: Date(date(element)?) })
		(Uri(namespace), "modified") if namespace == dc_terms and properties.modified == Unset => Ok({ ..properties, modified: Date(date(element)?) })
		_ => Err(CannotHold)
	}

extended_property : Element, Document.ExtendedProperties -> Try(Document.ExtendedProperties, [CannotHold])
extended_property = |element, properties| {
	count = || Ok(natural(plain_text(element)?) ? |_| CannotHold)
	match element.name.local {
		"Application" if properties.application == Unset => Ok({ ..properties, application: Text(plain_text(element)?) })
		"AppVersion" if properties.app_version == Unset => Ok({ ..properties, app_version: Text(plain_text(element)?) })
		"Company" if properties.company == Unset => Ok({ ..properties, company: Text(plain_text(element)?) })
		"Manager" if properties.manager == Unset => Ok({ ..properties, manager: Text(plain_text(element)?) })
		"Template" if properties.template == Unset => Ok({ ..properties, template: Text(plain_text(element)?) })
		"Pages" if properties.pages == Unset => Ok({ ..properties, pages: Count(count()?) })
		"Words" if properties.words == Unset => Ok({ ..properties, words: Count(count()?) })
		"Characters" if properties.characters == Unset => Ok({ ..properties, characters: Count(count()?) })
		"CharactersWithSpaces" if properties.characters_with_spaces == Unset => Ok({ ..properties, characters_with_spaces: Count(count()?) })
		"Lines" if properties.lines == Unset => Ok({ ..properties, lines: Count(count()?) })
		"Paragraphs" if properties.paragraphs == Unset => Ok({ ..properties, paragraphs: Count(count()?) })
		"TotalTime" if properties.total_time == Unset => Ok({ ..properties, total_time: Count(count()?) })
		_ => Err(CannotHold)
	}
}

custom_property : XmlTree.Node -> Try(Document.CustomProperty, [CannotHold])
custom_property = |node| {
	element = match node {
		Element(found) if is_named(node, custom_namespace, "property") => found
		_ => return Err(CannotHold)
	}
	if !element.attributes.all(|attribute| attribute.name.namespace == NoNamespace and ["fmtid", "pid", "name"].contains(attribute.name.local)) {
		return Err(CannotHold)
	}
	name = unqualified(element, "name") ? |_| CannotHold
	held = match kept(element.children) {
		[Element(held_value)] if held_value.name.namespace == Uri(variant_types) => held_value
		_ => return Err(CannotHold)
	}
	text = plain_text(held)?
	value = match held.name.local {
		"lpwstr" | "lpstr" | "bstr" => Text(text)
		"i1" | "i2" | "i4" | "i8" | "int" | "ui1" | "ui2" | "ui4" | "ui8" | "uint" => Integer(integer(text)?)
		"bool" => Boolean(toggle(text)? == On)
		"filetime" | "date" => if (is_w3c_date(text)) Date(text) else return Err(CannotHold)
		_ => return Err(CannotHold)
	}
	Ok(Property({ name, value }))
}

# A whole number, an optional sign and decimal digits, as [decimal] reads it.
integer : Str -> Try(I64, [CannotHold])
integer = |text|
	if text.contains(".") {
		Err(CannotHold)
	} else {
		Ok((Lenient.decimal(text, 1) ? |_| CannotHold).value)
	}

# The text of an element without attributes that holds only text.
plain_text : Element -> Try(Str, [CannotHold])
plain_text = |element| {
	if !element.attributes.is_empty() {
		return Err(CannotHold)
	}
	var $text = List.with_capacity(32)
	for child in element.children {
		match child {
			Text(content) => {
				$text = List.concat($text, content.to_utf8())
			}

			Element(_) => {
				return Err(CannotHold)
			}
		}
	}
	Ok(Str.from_utf8($text) ?? "")
}

# A date in the W3C date and time format, whose only attribute may name its
# type as that format.
date : Element -> Try(Str, [CannotHold])
date = |element| {
	typed = element.attributes.all(|attribute| attribute.name.namespace == Uri(instance_namespace) and attribute.name.local == "type" and attribute.value.ends_with(":W3CDTF"))
	text = plain_text({ ..element, attributes: [] })?
	if typed and is_w3c_date(text) {
		Ok(text)
	} else {
		Err(CannotHold)
	}
}

# Whether text is a date in the W3C date and time format: a year, a month or
# a day, or a day and a time to the minute, second or fraction of a second
# with its zone, `Z` or an offset in hours and minutes.
is_w3c_date : Str -> Bool
is_w3c_date = |text| {
	bytes = text.to_utf8()
	at = |index, byte| bytes.get(index) == Ok(byte)
	digits = |start, count| {
		var $index = start
		var $all = Bool.True
		while $index < start + count {
			$all = $all and match bytes.get($index) {
				Ok(byte) => byte >= '0' and byte <= '9'
				Err(_) => Bool.False
			}
			$index = $index + 1
		}
		$all
	}
	day = digits(0, 4) and at(4, '-') and digits(5, 2) and at(7, '-') and digits(8, 2)
	if bytes.len() == 4 {
		digits(0, 4)
	} else if bytes.len() == 7 {
		digits(0, 4) and at(4, '-') and digits(5, 2)
	} else if bytes.len() == 10 {
		day
	} else if day and at(10, 'T') and digits(11, 2) and at(13, ':') and digits(14, 2) {
		seconds = if (at(16, ':') and digits(17, 2)) 19 else 16
		var $zone = seconds
		if seconds == 19 and at(19, '.') and digits(20, 1) {
			$zone = 21
			while digits($zone, 1) {
				$zone = $zone + 1
			}
		}
		rest = bytes.len() - $zone
		(rest == 1 and at($zone, 'Z')) or (rest == 6 and (at($zone, '+') or at($zone, '-')) and digits($zone + 1, 2) and at($zone + 3, ':') and digits($zone + 4, 2))
	} else {
		Bool.False
	}
}

# A count: decimal digits, at most nineteen.
natural : Str -> Try(U64, [NotNumber])
natural = |text| {
	digits = text.to_utf8()
	if digits.is_empty() or digits.len() > 19 {
		return Err(NotNumber)
	}
	digits.fold(Ok(0.U64), |sum, digit| if (digit >= '0' and digit <= '9') Ok((sum?) * 10 + (digit - '0').to_u64()) else Err(NotNumber))
}

block : XmlTree.Node, Reading, List(WmlRead.Diagnostic) -> { block : Document.Block, diagnostics : List(WmlRead.Diagnostic) }
block = |node, within, diagnostics|
	match node {
		Element(element) if is_w(element.name, "p") and identified_only(element) and plain_first(element.children, "pPr") => { block: Paragraph(paragraph(element.children, within)), diagnostics: diagnostics }
		Element(element) if is_w(element.name, "tbl") and element.attributes.is_empty() and plain_first(element.children, "tblPr") and plain_first(element.children, "tblGrid") => {
			read = table(element.children, within, diagnostics)
			{ block: Table(read.table), diagnostics: read.diagnostics }
		}

		Element(element) if is_w_in(element.name, block_containers) => {
			read = blocks(element.children, within, diagnostics)
			{ block: Container({ element: without_children(element), content: read.blocks }), diagnostics: read.diagnostics }
		}

		Element(element) if is_w(element.name, "sectPr") and element.attributes.is_empty() => {
			read = section(element.children, within, diagnostics)
			{ block: Section(read.section), diagnostics: read.diagnostics }
		}

		Element(element) if element.name.local == "commentRangeStart" and is_w(element.name, "commentRangeStart") => { block: comment_place(element, within).map_ok(|place| CommentStart(place)) ?? Preserved(node), diagnostics: diagnostics }
		Element(element) if element.name.local == "commentRangeEnd" and is_w(element.name, "commentRangeEnd") => { block: comment_place(element, within).map_ok(|place| CommentEnd(place)) ?? Preserved(node), diagnostics: diagnostics }
		_ => { block: Preserved(node), diagnostics: diagnostics }
	}

table : List(XmlTree.Node), Reading, List(WmlRead.Diagnostic) -> { table : Document.Table, diagnostics : List(WmlRead.Diagnostic) }
table = |children, within, diagnostics| {
	var $properties = Err(Missing)
	var $grid = Err(Missing)
	var $content = List.with_capacity(children.len())
	var $diagnostics = diagnostics
	for child in children {
		match ($properties, $grid, child) {
			(Err(Missing), _, Element(element)) if is_w(element.name, "tblPr") => {
				read = table_properties(element.children, $diagnostics, unstated_table([]), tracked_table)
				$properties = Ok(read.properties)
				$diagnostics = read.diagnostics
			}

			(_, Err(Missing), Element(element)) if is_w(element.name, "tblGrid") => {
				read = grid(element.children, $diagnostics)
				$grid = Ok(read.grid)
				$diagnostics = read.diagnostics
			}

			_ => {
				if is_content(child) {
					read = table_content(child, within, $diagnostics)
					$content = List.append($content, read.content)
					$diagnostics = read.diagnostics
				}
			}
		}
	}
	properties = $properties ?? { style: Unset, width: Unset, borders: [], shading: Unset, preserved: [], change: [] }
	{ table: { properties, grid: $grid ?? [], content: $content }, diagnostics: $diagnostics }
}

table_content : XmlTree.Node, Reading, List(WmlRead.Diagnostic) -> { content : Document.TableContent, diagnostics : List(WmlRead.Diagnostic) }
table_content = |node, within, diagnostics|
	match node {
		Element(element) if is_w(element.name, "tr") and identified_only(element) and plain_first(element.children, "trPr") => {
			read = row(element.children, within, diagnostics)
			{ content: Row(read.row), diagnostics: read.diagnostics }
		}

		Element(element) if is_w_in(element.name, block_containers) => {
			var $content = List.with_capacity(element.children.len())
			var $diagnostics = diagnostics
			for child in element.children {
				if is_content(child) {
					read = table_content(child, within, $diagnostics)
					$content = List.append($content, read.content)
					$diagnostics = read.diagnostics
				}
			}
			{ content: Container({ element: without_children(element), content: $content }), diagnostics: $diagnostics }
		}

		Element(element) if element.name.local == "commentRangeStart" and is_w(element.name, "commentRangeStart") => { content: comment_place(element, within).map_ok(|place| CommentStart(place)) ?? Preserved(node), diagnostics: diagnostics }
		Element(element) if element.name.local == "commentRangeEnd" and is_w(element.name, "commentRangeEnd") => { content: comment_place(element, within).map_ok(|place| CommentEnd(place)) ?? Preserved(node), diagnostics: diagnostics }
		_ => { content: Preserved(node), diagnostics: diagnostics }
	}

row : List(XmlTree.Node), Reading, List(WmlRead.Diagnostic) -> { row : Document.Row, diagnostics : List(WmlRead.Diagnostic) }
row = |children, within, diagnostics| {
	var $properties = Err(Missing)
	var $content = List.with_capacity(children.len())
	var $diagnostics = diagnostics
	for child in children {
		match ($properties, child) {
			(Err(Missing), Element(element)) if is_w(element.name, "trPr") => {
				read = row_properties(element.children, $diagnostics, unstated_row([]), tracked_row)
				$properties = Ok(read.properties)
				$diagnostics = read.diagnostics
			}

			_ => {
				if is_content(child) {
					read = row_content(child, within, $diagnostics)
					$content = List.append($content, read.content)
					$diagnostics = read.diagnostics
				}
			}
		}
	}
	properties = $properties ?? { header: Unset, grid_before: Unset, grid_after: Unset, preserved: [], inserted: Unset, deleted: Unset, change: [] }
	{ row: { properties, content: $content }, diagnostics: $diagnostics }
}

row_content : XmlTree.Node, Reading, List(WmlRead.Diagnostic) -> { content : Document.RowContent, diagnostics : List(WmlRead.Diagnostic) }
row_content = |node, within, diagnostics|
	match node {
		Element(element) if is_w(element.name, "tc") and element.attributes.is_empty() and plain_first(element.children, "tcPr") => {
			read = cell(element.children, within, diagnostics)
			{ content: Cell(read.cell), diagnostics: read.diagnostics }
		}

		Element(element) if is_w_in(element.name, block_containers) => {
			var $content = List.with_capacity(element.children.len())
			var $diagnostics = diagnostics
			for child in element.children {
				if is_content(child) {
					read = row_content(child, within, $diagnostics)
					$content = List.append($content, read.content)
					$diagnostics = read.diagnostics
				}
			}
			{ content: Container({ element: without_children(element), content: $content }), diagnostics: $diagnostics }
		}

		Element(element) if element.name.local == "commentRangeStart" and is_w(element.name, "commentRangeStart") => { content: comment_place(element, within).map_ok(|place| CommentStart(place)) ?? Preserved(node), diagnostics: diagnostics }
		Element(element) if element.name.local == "commentRangeEnd" and is_w(element.name, "commentRangeEnd") => { content: comment_place(element, within).map_ok(|place| CommentEnd(place)) ?? Preserved(node), diagnostics: diagnostics }
		_ => { content: Preserved(node), diagnostics: diagnostics }
	}

cell : List(XmlTree.Node), Reading, List(WmlRead.Diagnostic) -> { cell : Document.Cell, diagnostics : List(WmlRead.Diagnostic) }
cell = |children, within, diagnostics| {
	var $properties = Err(Missing)
	var $content = List.with_capacity(children.len())
	var $diagnostics = diagnostics
	for child in children {
		match ($properties, child) {
			(Err(Missing), Element(element)) if is_w(element.name, "tcPr") => {
				read = cell_properties(element.children, $diagnostics, unstated_cell([]), tracked_cell)
				$properties = Ok(read.properties)
				$diagnostics = read.diagnostics
			}

			_ => {
				if is_content(child) {
					read = block(child, within, $diagnostics)
					$content = List.append($content, read.block)
					$diagnostics = read.diagnostics
				}
			}
		}
	}
	properties = $properties ?? { width: Unset, span: Unset, merge: Unset, borders: [], shading: Unset, alignment: Unset, preserved: [], revision: Unset, change: [] }
	{ cell: { properties, content: $content }, diagnostics: $diagnostics }
}

# A grid column is a `w:gridCol` whose only attribute is its width.
grid : List(XmlTree.Node), List(WmlRead.Diagnostic) -> { grid : List(Document.GridColumn), diagnostics : List(WmlRead.Diagnostic) }
grid = |children, diagnostics| {
	var $columns = List.with_capacity(children.len())
	var $diagnostics = diagnostics
	for child in kept(children) {
		read = match child {
			Element(element) if is_w(element.name, "gridCol") and holds(element, ["w"]) => unsigned(element, "w")
			_ => Err(CannotHold)
		}
		match read {
			Ok({ value, noticed }) => {
				$columns = List.append($columns, Column(value))
				$diagnostics = List.concat($diagnostics, noticed)
			}

			Err(CannotHold) => {
				$columns = List.append($columns, Preserved(child))
			}
		}
	}
	{ grid: $columns, diagnostics: $diagnostics }
}

table_properties : List(XmlTree.Node), List(WmlRead.Diagnostic), Document.TablePropertiesOf(c), TrackingRead(Document.TablePropertiesOf(c)) -> { properties : Document.TablePropertiesOf(c), diagnostics : List(WmlRead.Diagnostic) }
table_properties = |children, diagnostics, start, tracking| {
	var $properties = { ..start, preserved: List.with_capacity(children.len()) }
	var $diagnostics = diagnostics
	for child in kept(children) {
		tracked = match child {
			Element(element) => tracking($properties, element)
			Text(_) => Err(NotTracking)
		}
		match tracked {
			Ok({ value, noticed }) => {
				$properties = value
				$diagnostics = List.concat($diagnostics, noticed)
			}

			Err(CannotHold) => {
				$properties = { ..$properties, preserved: List.append($properties.preserved, child) }
			}

			Err(NotTracking) =>
				match child {
					Element(element) if is_w(element.name, "tblStyle") and $properties.style == Unset and holds(element, ["val"]) =>
						match value_of(element, "val") {
							Ok(id) => {
								$properties = { ..$properties, style: Style(id) }
							}

							Err(NotFound) => {
								$properties = { ..$properties, preserved: List.append($properties.preserved, child) }
							}
						}

					Element(element) if is_w(element.name, "tblW") and $properties.width == Unset =>
						match width(element) {
							Ok({ value, noticed }) => {
								$properties = { ..$properties, width: value }
								$diagnostics = List.concat($diagnostics, noticed)
							}

							Err(CannotHold) => {
								$properties = { ..$properties, preserved: List.append($properties.preserved, child) }
							}
						}

					Element(element) if is_w(element.name, "tblBorders") and $properties.borders.is_empty() =>
						match borders(element, table_edges) {
							Ok({ value, noticed }) => {
								$properties = { ..$properties, borders: value }
								$diagnostics = List.concat($diagnostics, noticed)
							}

							Err(CannotHold) => {
								$properties = { ..$properties, preserved: List.append($properties.preserved, child) }
							}
						}

					Element(element) if is_w(element.name, "shd") and $properties.shading == Unset =>
						match shading(element) {
							Ok(value) => {
								$properties = { ..$properties, shading: value }
							}

							Err(CannotHold) => {
								$properties = { ..$properties, preserved: List.append($properties.preserved, child) }
							}
						}

					_ => {
						$properties = { ..$properties, preserved: List.append($properties.preserved, child) }
					}
				}
		}
	}
	{ properties: $properties, diagnostics: $diagnostics }
}

row_properties : List(XmlTree.Node), List(WmlRead.Diagnostic), Document.RowPropertiesOf(c), TrackingRead(Document.RowPropertiesOf(c)) -> { properties : Document.RowPropertiesOf(c), diagnostics : List(WmlRead.Diagnostic) }
row_properties = |children, diagnostics, start, tracking| {
	var $properties = { ..start, preserved: List.with_capacity(children.len()) }
	var $diagnostics = diagnostics
	for child in kept(children) {
		tracked = match child {
			Element(element) => tracking($properties, element)
			Text(_) => Err(NotTracking)
		}
		match tracked {
			Ok({ value, noticed }) => {
				$properties = value
				$diagnostics = List.concat($diagnostics, noticed)
			}

			Err(CannotHold) => {
				$properties = { ..$properties, preserved: List.append($properties.preserved, child) }
			}

			Err(NotTracking) =>
				match child {
					Element(element) if is_w(element.name, "tblHeader") and $properties.header == Unset =>
						match on_off(element) {
							Ok(value) => {
								$properties = { ..$properties, header: value }
							}

							Err(CannotHold) => {
								$properties = { ..$properties, preserved: List.append($properties.preserved, child) }
							}
						}

					Element(element) if is_w(element.name, "gridBefore") and $properties.grid_before == Unset =>
						match columns(element) {
							Ok({ value, noticed }) => {
								$properties = { ..$properties, grid_before: value }
								$diagnostics = List.concat($diagnostics, noticed)
							}

							Err(CannotHold) => {
								$properties = { ..$properties, preserved: List.append($properties.preserved, child) }
							}
						}

					Element(element) if is_w(element.name, "gridAfter") and $properties.grid_after == Unset =>
						match columns(element) {
							Ok({ value, noticed }) => {
								$properties = { ..$properties, grid_after: value }
								$diagnostics = List.concat($diagnostics, noticed)
							}

							Err(CannotHold) => {
								$properties = { ..$properties, preserved: List.append($properties.preserved, child) }
							}
						}

					_ => {
						$properties = { ..$properties, preserved: List.append($properties.preserved, child) }
					}
				}
		}
	}
	{ properties: $properties, diagnostics: $diagnostics }
}

cell_properties : List(XmlTree.Node), List(WmlRead.Diagnostic), Document.CellPropertiesOf(c), TrackingRead(Document.CellPropertiesOf(c)) -> { properties : Document.CellPropertiesOf(c), diagnostics : List(WmlRead.Diagnostic) }
cell_properties = |children, diagnostics, start, tracking| {
	var $properties = { ..start, preserved: List.with_capacity(children.len()) }
	var $diagnostics = diagnostics
	for child in kept(children) {
		tracked = match child {
			Element(element) => tracking($properties, element)
			Text(_) => Err(NotTracking)
		}
		match tracked {
			Ok({ value, noticed }) => {
				$properties = value
				$diagnostics = List.concat($diagnostics, noticed)
			}

			Err(CannotHold) => {
				$properties = { ..$properties, preserved: List.append($properties.preserved, child) }
			}

			Err(NotTracking) =>
				match child {
					Element(element) if is_w(element.name, "tcW") and $properties.width == Unset =>
						match width(element) {
							Ok({ value, noticed }) => {
								$properties = { ..$properties, width: value }
								$diagnostics = List.concat($diagnostics, noticed)
							}

							Err(CannotHold) => {
								$properties = { ..$properties, preserved: List.append($properties.preserved, child) }
							}
						}

					Element(element) if is_w(element.name, "gridSpan") and $properties.span == Unset =>
						match columns(element) {
							Ok({ value, noticed }) => {
								$properties = { ..$properties, span: value }
								$diagnostics = List.concat($diagnostics, noticed)
							}

							Err(CannotHold) => {
								$properties = { ..$properties, preserved: List.append($properties.preserved, child) }
							}
						}

					Element(element) if is_w(element.name, "vMerge") and $properties.merge == Unset =>
						match merge(element) {
							Ok(value) => {
								$properties = { ..$properties, merge: value }
							}

							Err(CannotHold) => {
								$properties = { ..$properties, preserved: List.append($properties.preserved, child) }
							}
						}

					Element(element) if is_w(element.name, "tcBorders") and $properties.borders.is_empty() =>
						match borders(element, cell_edges) {
							Ok({ value, noticed }) => {
								$properties = { ..$properties, borders: value }
								$diagnostics = List.concat($diagnostics, noticed)
							}

							Err(CannotHold) => {
								$properties = { ..$properties, preserved: List.append($properties.preserved, child) }
							}
						}

					Element(element) if is_w(element.name, "shd") and $properties.shading == Unset =>
						match shading(element) {
							Ok(value) => {
								$properties = { ..$properties, shading: value }
							}

							Err(CannotHold) => {
								$properties = { ..$properties, preserved: List.append($properties.preserved, child) }
							}
						}

					Element(element) if is_w(element.name, "vAlign") and $properties.alignment == Unset =>
						match alignment(element) {
							Ok(value) => {
								$properties = { ..$properties, alignment: value }
							}

							Err(CannotHold) => {
								$properties = { ..$properties, preserved: List.append($properties.preserved, child) }
							}
						}

					_ => {
						$properties = { ..$properties, preserved: List.append($properties.preserved, child) }
					}
				}
		}
	}
	{ properties: $properties, diagnostics: $diagnostics }
}

unstated_table : change -> Document.TablePropertiesOf(change)
unstated_table = |change| { style: Unset, width: Unset, borders: [], shading: Unset, preserved: [], change }

unstated_row : change -> Document.RowPropertiesOf(change)
unstated_row = |change| { header: Unset, grid_before: Unset, grid_after: Unset, preserved: [], inserted: Unset, deleted: Unset, change }

unstated_cell : change -> Document.CellPropertiesOf(change)
unstated_cell = |change| { width: Unset, span: Unset, merge: Unset, borders: [], shading: Unset, alignment: Unset, preserved: [], revision: Unset, change }

# A table's first `w:tblPrChange`.
tracked_table : TrackingRead(Document.TableProperties)
tracked_table = |found, element|
	if element.name.local == "tblPrChange" and found.change.is_empty() and is_w(element.name, "tblPrChange") {
		{ change, previous } = property_change(element, "tblPr") ? |_| CannotHold
		before = table_properties(previous, [], unstated_table(Unset), untracked_read)
		Ok({ value: { ..found, change: [{ author: change.author, date: change.date, preserved: change.preserved, previous: before.properties }] }, noticed: before.diagnostics })
	} else {
		Err(NotTracking)
	}

# A row's first `w:ins` and `w:del`, which hold nothing, and its first
# `w:trPrChange`.
tracked_row : TrackingRead(Document.RowProperties)
tracked_row = |found, element|
	if element.name.local == "ins" and found.inserted == Unset and kept(element.children).is_empty() and is_w(element.name, "ins") {
		Ok({ value: { ..found, inserted: Tracked(change_of(element)?) }, noticed: [] })
	} else if element.name.local == "del" and found.deleted == Unset and kept(element.children).is_empty() and is_w(element.name, "del") {
		Ok({ value: { ..found, deleted: Tracked(change_of(element)?) }, noticed: [] })
	} else if element.name.local == "trPrChange" and found.change.is_empty() and is_w(element.name, "trPrChange") {
		{ change, previous } = property_change(element, "trPr") ? |_| CannotHold
		before = row_properties(previous, [], unstated_row(Unset), untracked_read)
		Ok({ value: { ..found, change: [{ author: change.author, date: change.date, preserved: change.preserved, previous: before.properties }] }, noticed: before.diagnostics })
	} else {
		Err(NotTracking)
	}

# A cell's first `w:cellIns`, `w:cellDel` or `w:cellMerge`, and its first
# `w:tcPrChange`.
tracked_cell : TrackingRead(Document.CellProperties)
tracked_cell = |found, element|
	if (element.name.local == "cellIns" or element.name.local == "cellDel" or element.name.local == "cellMerge") and found.revision == Unset and is_w_in(element.name, ["cellIns", "cellDel", "cellMerge"]) {
		Ok({ value: { ..found, revision: cell_revision(element)? }, noticed: [] })
	} else if element.name.local == "tcPrChange" and found.change.is_empty() and is_w(element.name, "tcPrChange") {
		{ change, previous } = property_change(element, "tcPr") ? |_| CannotHold
		before = cell_properties(previous, [], unstated_cell(Unset), untracked_read)
		Ok({ value: { ..found, change: [{ author: change.author, date: change.date, preserved: change.preserved, previous: before.properties }] }, noticed: before.diagnostics })
	} else {
		Err(NotTracking)
	}

# A cell's tracked insertion, deletion or merge, which holds nothing; a
# merge's `w:vMerge` and `w:vMergeOrig` are `cont` or `rest`.
cell_revision : Element -> Try([Unset, Inserted(Document.Change), Deleted(Document.Change), Merged(Document.CellMerge)], [CannotHold])
cell_revision = |element| {
	if !kept(element.children).is_empty() {
		return Err(CannotHold)
	}
	change = change_of(element)?
	match element.name.local {
		"cellIns" => Ok(Inserted(change))
		"cellDel" => Ok(Deleted(change))
		_ => {
			vertical = |local|
				match value_of(element, local) {
					Ok("cont") => Ok(Continue)
					Ok("rest") => Ok(Restart)
					Ok(_) => Err(CannotHold)
					Err(NotFound) => Ok(Unset)
				}
			Ok(Merged({ author: change.author, date: change.date, preserved: change.preserved.drop_if(|attribute| is_w_in(attribute.name, ["vMerge", "vMergeOrig"])), merge: vertical("vMerge")?, previous: vertical("vMergeOrig")? }))
		}
	}
}

# A value read from a property element, with what reading it noticed.
Read(a) : { value : a, noticed : List(WmlRead.Diagnostic) }

# A preferred width: `w:type` is `auto`, `nil`, `dxa` (twips, the default)
# or `pct`, fiftieths of a per cent or a percentage written with `%`. An
# automatic or zero width with a non-zero `w:w` cannot be held.
width : Element -> Try(Read(Document.Width), [CannotHold])
width = |element| {
	if !holds(element, ["w", "type"]) {
		return Err(CannotHold)
	}
	match value_of(element, "type") {
		Ok("auto") => if (zero_or_absent(element)) Ok({ value: Auto, noticed: [] }) else Err(CannotHold)
		Ok("nil") => if (zero_or_absent(element)) Ok({ value: Nil, noticed: [] }) else Err(CannotHold)
		Ok("pct") => {
			text = value_of(element, "w") ? |_| CannotHold
			if text.ends_with("%") {
				read = Lenient.decimal(Str.drop_suffix(text, "%"), 50) ? |_| CannotHold
				Ok({ value: Fiftieths(read.value), noticed: if (read.exact) [] else [rounded(element, "w", text)] })
			} else {
				read = whole(element, "w")?
				Ok({ value: Fiftieths(read.value), noticed: read.noticed })
			}
		}

		Ok("dxa") | Err(NotFound) => {
			read = whole(element, "w")?
			Ok({ value: Twips(read.value), noticed: read.noticed })
		}

		Ok(_) => Err(CannotHold)
	}
}

zero_or_absent : Element -> Bool
zero_or_absent = |element|
	match value_of(element, "w") {
		Ok(text) => Lenient.decimal(text, 1).map_ok(|read| read.value) == Ok(0)
		Err(NotFound) => Bool.True
	}

# A count of grid columns in `w:val`.
columns : Element -> Try(Read([Unset, Columns(U64)]), [CannotHold])
columns = |element| {
	if !holds(element, ["val"]) {
		return Err(CannotHold)
	}
	read = unsigned(element, "val")?
	Ok({ value: Columns(read.value), noticed: read.noticed })
}

# An on or off property: no `w:val` is on.
on_off : Element -> Try([Unset, On, Off], [CannotHold])
on_off = |element| {
	if !holds(element, ["val"]) {
		return Err(CannotHold)
	}
	match value_of(element, "val") {
		Err(NotFound) | Ok("true") | Ok("1") | Ok("on") => Ok(On)
		Ok("false") | Ok("0") | Ok("off") => Ok(Off)
		Ok(_) => Err(CannotHold)
	}
}

# A vertical merge: no `w:val` continues the merge above.
merge : Element -> Try([Unset, Restart, Continue], [CannotHold])
merge = |element| {
	if !holds(element, ["val"]) {
		return Err(CannotHold)
	}
	match value_of(element, "val") {
		Ok("restart") => Ok(Restart)
		Err(NotFound) | Ok("continue") => Ok(Continue)
		Ok(_) => Err(CannotHold)
	}
}

alignment : Element -> Try([Unset, Top, Center, Bottom, Both], [CannotHold])
alignment = |element| {
	if !holds(element, ["val"]) {
		return Err(CannotHold)
	}
	match value_of(element, "val") {
		Ok("top") => Ok(Top)
		Ok("center") => Ok(Center)
		Ok("bottom") => Ok(Bottom)
		Ok("both") => Ok(Both)
		_ => Err(CannotHold)
	}
}

paragraph_edges : List(Str)
paragraph_edges = ["top", "left", "bottom", "right", "between", "bar"]

table_edges : List(Str)
table_edges = ["top", "left", "start", "bottom", "right", "end", "insideH", "insideV"]

cell_edges : List(Str)
cell_edges = ["top", "left", "start", "bottom", "right", "end", "insideH", "insideV", "tl2br", "tr2bl"]

# Borders the model holds only whole: an element with no edges, an edge it
# does not allow, or an edge with attributes beyond its line, width, space
# and colour, such as a theme colour, is kept as it was read.
borders : Element, List(Str) -> Try(Read(List(Document.Border)), [CannotHold])
borders = |element, allowed| {
	if !element.attributes.is_empty() {
		return Err(CannotHold)
	}
	var $borders = List.with_capacity(element.children.len())
	var $noticed = List.with_capacity(0)
	for child in kept(element.children) {
		match child {
			Element(edge_element) if is_w_in(edge_element.name, allowed) and holds(edge_element, ["val", "sz", "space", "color"]) => {
				line = value_of(edge_element, "val") ? |_| CannotHold
				size = match value_of(edge_element, "sz") {
					Ok(_) => {
						read = unsigned(edge_element, "sz")?
						$noticed = List.concat($noticed, read.noticed)
						Eighths(read.value)
					}

					Err(NotFound) => Unset
				}
				space = match value_of(edge_element, "space") {
					Ok(_) => {
						read = unsigned(edge_element, "space")?
						$noticed = List.concat($noticed, read.noticed)
						Points(read.value)
					}

					Err(NotFound) => Unset
				}
				$borders = List.append($borders, { edge: edge(edge_element.name.local), line, size, space, color: color(edge_element, "color")? })
			}

			_ => {
				return Err(CannotHold)
			}
		}
	}
	if $borders.is_empty() {
		Err(CannotHold)
	} else {
		Ok({ value: $borders, noticed: $noticed })
	}
}

edge : Str -> [Top, Left, Start, Bottom, Right, End, InsideHorizontal, InsideVertical, DiagonalDown, DiagonalUp, Between, Bar]
edge = |local|
	match local {
		"left" => Left
		"start" => Start
		"bottom" => Bottom
		"right" => Right
		"end" => End
		"insideH" => InsideHorizontal
		"insideV" => InsideVertical
		"tl2br" => DiagonalDown
		"tr2bl" => DiagonalUp
		"between" => Between
		"bar" => Bar
		_ => Top
	}

# A shading with its pattern and, if it gives them, its colour and fill;
# theme colours cannot be held.
shading : Element -> Try(Document.Shading, [CannotHold])
shading = |element| {
	if !holds(element, ["val", "color", "fill"]) {
		return Err(CannotHold)
	}
	pattern = value_of(element, "val") ? |_| CannotHold
	Ok(Shading({ pattern, color: color(element, "color")?, fill: color(element, "fill")? }))
}

# A colour attribute: `auto` or six hexadecimal digits.
color : Element, Str -> Try(Document.Color, [CannotHold])
color = |element, local|
	match value_of(element, local) {
		Err(NotFound) => Ok(Unset)
		Ok("auto") => Ok(Auto)
		Ok(text) =>
			if text.to_utf8().len() == 6 and text.to_utf8().all(|byte| hex_digit(byte).is_ok()) {
				Ok(Rgb(text))
			} else {
				Err(CannotHold)
			}
	}

# Whether every attribute of an element is a WordprocessingML one of these.
holds : Element, List(Str) -> Bool
holds = |element, locals| element.attributes.all(|attribute| is_w_in(attribute.name, locals))

# A whole number in an attribute, read leniently: a value written with a
# fraction is rounded, and noticed.
whole : Element, Str -> Try(Read(I64), [CannotHold])
whole = |element, local| {
	text = value_of(element, local) ? |_| CannotHold
	read = Lenient.decimal(text, 1) ? |_| CannotHold
	Ok({ value: read.value, noticed: if (text.contains(".")) [rounded(element, local, text)] else [] })
}

unsigned : Element, Str -> Try(Read(U64), [CannotHold])
unsigned = |element, local| {
	read = whole(element, local)?
	if read.value < 0 {
		Err(CannotHold)
	} else {
		Ok({ value: read.value.to_u64_wrap(), noticed: read.noticed })
	}
}

rounded : Element, Str, Str -> WmlRead.Diagnostic
rounded = |element, local, text| Rounded({ element: element.name.local, attribute: local, value: text })

paragraph : List(XmlTree.Node), Reading -> Document.Paragraph
paragraph = |children, within| {
	var $properties = Err(Missing)
	var $content = List.with_capacity(children.len())
	for child in children {
		match ($properties, child) {
			(Err(Missing), Element(element)) if is_w(element.name, "pPr") => {
				$properties = Ok(WmlRead.paragraph_properties(element.children))
			}

			_ => {
				if is_content(child) {
					$content = List.append($content, inline(child, within))
				}
			}
		}
	}
	{ properties: $properties ?? Document.no_paragraph_properties, content: $content }
}

inlines : List(XmlTree.Node), Reading -> List(Document.Inline)
inlines = |nodes, within| {
	var $out = List.with_capacity(nodes.len())
	for node in nodes {
		if is_content(node) {
			$out = List.append($out, inline(node, within))
		}
	}
	$out
}

inline : XmlTree.Node, Reading -> Document.Inline
inline = |node, within|
	match node {
		Element(element) if is_w(element.name, "r") and element.attributes.is_empty() and plain_first(element.children, "rPr") => Run(run(element.children, within))
		Element(element) if is_w(element.name, "hyperlink") => hyperlink(element, within) ?? container(element, within)
		Element(element) if is_w(element.name, "fldSimple") => simple_field(element, within) ?? container(element, within)
		Element(element) if is_w(element.name, "bookmarkStart") => bookmark_start(element) ?? Preserved(node)
		Element(element) if is_w(element.name, "bookmarkEnd") => bookmark_end(element, within) ?? Preserved(node)
		Element(element) if element.name.local == "commentRangeStart" and is_w(element.name, "commentRangeStart") => comment_place(element, within).map_ok(|place| CommentStart(place)) ?? Preserved(node)
		Element(element) if element.name.local == "commentRangeEnd" and is_w(element.name, "commentRangeEnd") => comment_place(element, within).map_ok(|place| CommentEnd(place)) ?? Preserved(node)
		Element(element) if is_w_in(element.name, ["ins", "del", "moveFrom", "moveTo"]) => revision(element, within) ?? container(element, within)
		Element(element) if is_w_in(element.name, ["moveFromRangeStart", "moveToRangeStart"]) => move_start(element) ?? Preserved(node)
		Element(element) if is_w_in(element.name, ["moveFromRangeEnd", "moveToRangeEnd"]) => move_end(element, within) ?? Preserved(node)
		Element(element) if is_w_in(element.name, inline_containers) => container(element, within)
		_ => Preserved(node)
	}

# A tracked change: `w:ins` an insertion, `w:del` a deletion, `w:moveFrom`
# and `w:moveTo` a move's source and destination, by `w:author` and at
# `w:date`, its document identifier `w:id` replaced by its place. Content
# deleted or moved away is deleted content. One without an author, which
# the schema requires, is not modelled.
revision : Element, Reading -> Try(Document.Inline, [NoAuthor])
revision = |element, within| {
	kind = match element.name.local {
		"ins" => Insertion
		"del" => Deletion
		"moveFrom" => MoveSource
		_ => MoveDestination
	}
	author = value_of(element, "author") ? |_| NoAuthor
	stamp = date_of(element)
	inner = if (kind == Deletion or kind == MoveSource) { ..within, deleted: Bool.True } else within
	Ok(Revision({ kind, author, date: stamp, content: inlines(element.children, inner), preserved: element.attributes.drop_if(|attribute| is_w_in(attribute.name, ["id", "author"]) or (is_w(attribute.name, "date") and stamp != Unset)) }))
}

# The start of a move's range, `w:moveFromRangeStart` of its source or
# `w:moveToRangeStart` of its destination, named by `w:name`, by `w:author`
# at `w:date`. One without a name, an author or a date and time, which the
# schema requires, is not modelled, and neither is its end, as
# [range_rule] names none for it.
move_start : Element -> Try(Document.Inline, [Unknown])
move_start = |element| {
	name = value_of(element, "name") ? |_| Unknown
	author = value_of(element, "author") ? |_| Unknown
	stamp = timestamp(value_of(element, "date") ? |_| Unknown) ? |_| Unknown
	side = if (element.name.local == "moveFromRangeStart") Source else Destination
	Ok(MoveStart({ side, name, author, date: stamp, preserved: element.attributes.drop_if(|attribute| is_w_in(attribute.name, ["id", "name", "author", "date"])) }))
}

# The end of a move's range names the range its `w:id` started; an end
# without a start, or displaced by custom XML, is not modelled.
move_end : Element, Reading -> Try(Document.Inline, [Unknown])
move_end = |element, within|
	if only(element, ["id"]) {
		id = value_of(element, "id") ? |_| Unknown
		(side, names) = if (element.name.local == "moveFromRangeEnd") (Source, within.move_sources) else (Destination, within.move_destinations)
		Ok(MoveEnd({ side, name: names.get(id) ? |_| Unknown }))
	} else {
		Err(Unknown)
	}

# A tracked change's `w:date`, unless it has none or it is not a date and
# time.
date_of : Element -> [Unset, Date(Document.Timestamp)]
date_of = |element|
	match value_of(element, "date") {
		Ok(written) =>
			match timestamp(written) {
				Ok(stamp) => Date(stamp)
				Err(NotDate) => Unset
			}

		Err(NotFound) => Unset
	}

container : Element, Reading -> Document.Inline
container = |element, within| Container({ element: without_children(element), content: inlines(element.children, within) })

# A hyperlink: `r:id` names an external relationship, whose target is the
# address, and `w:anchor` a location in it, or a bookmark of the document
# when there is no `r:id`.
hyperlink : Element, Reading -> Try(Document.Inline, [Unresolved])
hyperlink = |element, within| {
	anchor = value_of(element, "anchor")
	target = match relationship_of(element, "id") {
		Ok(id) =>
			match (within.relationships.get(id), anchor) {
				(Ok({ id: _, kind: _, target: url, mode: External }), Ok(location)) => ExternalAt({ url, location })
				(Ok({ id: _, kind: _, target: url, mode: External }), Err(_)) => External(url)
				_ => return Err(Unresolved)
			}

		Err(_) =>
			match anchor {
				Ok(name) => Internal(name)
				Err(_) => return Err(Unresolved)
			}
	}
	preserved = element.attributes.drop_if(|attribute| is_w(attribute.name, "anchor") or is_r(attribute.name, "id"))
	Ok(Hyperlink({ target, preserved, content: inlines(element.children, within) }))
}

simple_field : Element, Reading -> Try(Document.Inline, [NoCode])
simple_field = |element, within| {
	code = value_of(element, "instr") ? |_| NoCode
	preserved = element.attributes.drop_if(|attribute| is_w(attribute.name, "instr"))
	Ok(SimpleField({ code, preserved, content: inlines(element.children, within) }))
}

bookmark_start : Element -> Try(Document.Inline, [Unknown])
bookmark_start = |element|
	if only(element, ["id", "name"]) {
		match (value_of(element, "id"), value_of(element, "name")) {
			(Ok(_), Ok(name)) => Ok(BookmarkStart(name))
			_ => Err(Unknown)
		}
	} else {
		Err(Unknown)
	}

bookmark_end : Element, Reading -> Try(Document.Inline, [Unknown])
bookmark_end = |element, within|
	if only(element, ["id"]) {
		id = value_of(element, "id") ? |_| Unknown
		Ok(BookmarkEnd(within.bookmarks.get(id) ? |_| Unknown))
	} else {
		Err(Unknown)
	}

# A comment range's boundary or a comment reference: `w:id` names a comment
# of the comments part. One displaced by custom XML is not modelled.
comment_place : Element, Reading -> Try(U64, [Unknown])
comment_place = |element, within|
	if only(element, ["id"]) {
		id = value_of(element, "id") ? |_| Unknown
		Ok(within.comments.get(id) ? |_| Unknown)
	} else {
		Err(Unknown)
	}

run : List(XmlTree.Node), Reading -> Document.Run
run = |children, within| {
	var $properties = Err(Missing)
	var $content = List.with_capacity(children.len())
	for child in children {
		match ($properties, child) {
			(Err(Missing), Element(element)) if is_w(element.name, "rPr") => {
				$properties = Ok(WmlRead.run_properties(element.children))
			}

			_ => {
				if is_content(child) {
					$content = List.append($content, run_content(child, within))
				}
			}
		}
	}
	{ properties: $properties ?? Document.no_run_properties, content: $content }
}

run_content : XmlTree.Node, Reading -> Document.RunContent
run_content = |node, within|
	match node {
		Element(element) if element.name.namespace == Uri(wordprocessingml) =>
			match element.name.local {
				"t" => text(element).map_ok(|value| Text(value)) ?? Preserved(node)
				"tab" if element.attributes.is_empty() => Tab
				"br" if only(element, ["type", "clear"]) => break_of(element) ?? Preserved(node)
				"cr" if element.attributes.is_empty() => Break({ kind: Line, clear: NoClear })
				"sym" if only(element, ["font", "char"]) => symbol(element) ?? Preserved(node)
				"softHyphen" if element.attributes.is_empty() => SoftHyphen
				"noBreakHyphen" if element.attributes.is_empty() => NonBreakingHyphen
				"footnoteReference" => note_reference(element, Footnote, within.footnotes) ?? Preserved(node)
				"endnoteReference" => note_reference(element, Endnote, within.endnotes) ?? Preserved(node)
				"footnoteRef" if element.attributes.is_empty() => NoteMark(Footnote)
				"endnoteRef" if element.attributes.is_empty() => NoteMark(Endnote)
				"commentReference" => comment_place(element, within).map_ok(|place| CommentReference(place)) ?? Preserved(node)
				"fldChar" => field_mark(element, node) ?? Preserved(node)
				"instrText" => text(element).map_ok(|code| FieldCode(code)) ?? Preserved(node)
				"delText" if within.deleted => text(element).map_ok(|value| Text(value)) ?? Preserved(node)
				"delInstrText" if within.deleted => text(element).map_ok(|code| FieldCode(code)) ?? Preserved(node)
				"drawing" => picture(element, node, within) ?? Preserved(node)
				_ => Preserved(node)
			}

		_ => Preserved(node)
	}

# A note reference: `w:id` names a note of its part. A reference whose mark
# is the text that follows it, `w:customMarkFollows`, is not modelled.
note_reference : Element, Document.NoteKind, Dict(Str, U64) -> Try(Document.RunContent, [Unknown])
note_reference = |element, kind, notes|
	if only(element, ["id"]) {
		id = value_of(element, "id") ? |_| Unknown
		Ok(NoteReference({ kind, note: notes.get(id) ? |_| Unknown }))
	} else {
		Err(Unknown)
	}

field_mark : Element, XmlTree.Node -> Try(Document.RunContent, [Unknown])
field_mark = |element, node| {
	kind = match value_of(element, "fldCharType") {
		Ok("begin") => Begin
		Ok("separate") => Separate
		Ok("end") => End
		_ => return Err(Unknown)
	}
	Ok(FieldMark({ kind, element: node }))
}

# An inline picture: a drawing whose one element is `wp:inline`, with the
# `wp:extent` of its size and an `a:blip` embedding an image part of the
# package by `r:embed`.
picture : Element, XmlTree.Node, Reading -> Try(Document.RunContent, [NotPicture])
picture = |element, node, within| {
	inline_drawing = match element.children.keep_if(|child| is_content(child)) {
		[Element(child)] if child.name.namespace == Uri(drawing_namespace) and child.name.local == "inline" => child
		_ => return Err(NotPicture)
	}
	extent = inline_drawing.children.find_first(|child| is_named(child, drawing_namespace, "extent")) ? |_| NotPicture
	(across, down) = match extent {
		Element(sized) => (emus(unqualified(sized, "cx")) ? |_| NotPicture, emus(unqualified(sized, "cy")) ? |_| NotPicture)
		Text(_) => return Err(NotPicture)
	}
	id = embedded(Element(inline_drawing)) ? |_| NotPicture
	media = match within.relationships.get(id) {
		Ok({ id: _, kind: _, target, mode: Internal }) => target
		_ => return Err(NotPicture)
	}
	Ok(Picture({ media, size: { width: across, height: down }, drawing: node }))
}

# The `r:embed` of the first `a:blip` in a tree.
embedded : XmlTree.Node -> Try(Str, [NotFound])
embedded = |root| {
	var $pending = [root]
	while !$pending.is_empty() {
		match $pending.last() {
			Ok(Element(element)) => {
				if element.name.namespace == Uri(drawingml) and element.name.local == "blip" {
					return relationship_of(element, "embed")
				}
				$pending = List.drop_last($pending, 1)
				var $index = element.children.len()
				while $index > 0 {
					$index = $index - 1
					$pending = List.append($pending, element.children.get($index) ?? Text(""))
				}
			}

			_ => {
				$pending = List.drop_last($pending, 1)
			}
		}
	}
	Err(NotFound)
}

# A length in English Metric Units: decimal digits, at most nineteen.
emus : Try(Str, [NotFound]) -> Try(U64, [NotLength])
emus = |value| natural(value ? |_| NotLength).map_err(|_| NotLength)

# The text of `w:t`, `w:instrText` or their deleted forms, which hold only
# character data. Unless the element says `xml:space="preserve"`, its
# whitespace is the producer's layout, as Word and LibreOffice read it:
# leading and trailing whitespace is removed, and each tab, carriage return
# and line feed left is a space.
text : Element -> Try(Str, [NotText])
text = |element| {
	if !element.attributes.all(|attribute| attribute.name.local == "space" and attribute.name.namespace == Uri(xml_namespace)) {
		return Err(NotText)
	}
	var $value = List.with_capacity(16)
	for child in element.children {
		match child {
			Text(content) => {
				$value = List.concat($value, content.to_utf8())
			}

			Element(_) => {
				return Err(NotText)
			}
		}
	}
	preserve = element.attributes.any(|attribute| attribute.name.namespace == Uri(xml_namespace) and attribute.name.local == "space" and attribute.value == "preserve")
	value = if preserve {
		$value
	} else {
		var $start = 0.U64
		while $start < $value.len() and is_space($value.get($start) ?? 0) {
			$start = $start + 1
		}
		var $end = $value.len()
		while $end > $start and is_space($value.get($end - 1) ?? 0) {
			$end = $end - 1
		}
		$value.sublist({ start: $start, len: $end - $start }).map(|byte| if (is_space(byte)) 32 else byte)
	}
	Ok(Str.from_utf8(value) ?? "")
}

is_space : U8 -> Bool
is_space = |byte| byte == 32 or byte == 9 or byte == 10 or byte == 13

xml_namespace : Str
xml_namespace = "http://www.w3.org/XML/1998/namespace"

break_of : Element -> Try(Document.RunContent, [Unknown])
break_of = |element| {
	kind = match value_of(element, "type") {
		Err(NotFound) => Line
		Ok("textWrapping") => Line
		Ok("page") => Page
		Ok("column") => Column
		Ok(_) => return Err(Unknown)
	}
	clear = match value_of(element, "clear") {
		Err(NotFound) => NoClear
		Ok("none") => NoClear
		Ok("left") => Left
		Ok("right") => Right
		Ok("all") => All
		Ok(_) => return Err(Unknown)
	}
	Ok(Break({ kind, clear }))
}

# A symbol: `w:char` is four hexadecimal digits, and a symbol without a
# font is in the run's font, which the model names as "".
symbol : Element -> Try(Document.RunContent, [Unknown])
symbol = |element| {
	digits = (value_of(element, "char") ? |_| Unknown).to_utf8()
	if digits.len() != 4 {
		return Err(Unknown)
	}
	code = digits.fold(Ok(0.U16), |sum, digit| Ok((sum?) * 16 + (hex_digit(digit)?))) ? |_| Unknown
	Ok(Symbol({ font: value_of(element, "font") ?? "", code }))
}

hex_digit : U8 -> Try(U16, [NotHex])
hex_digit = |digit|
	if digit >= '0' and digit <= '9' {
		Ok((digit - '0').to_u16())
	} else if digit >= 'a' and digit <= 'f' {
		Ok((digit - 'a' + 10).to_u16())
	} else if digit >= 'A' and digit <= 'F' {
		Ok((digit - 'A' + 10).to_u16())
	} else {
		Err(NotHex)
	}

Element : { name : XmlTree.Name, bindings : List(XmlTree.Binding), attributes : List(XmlTree.Attribute), children : List(XmlTree.Node) }

wordprocessingml : Str
wordprocessingml = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

is_w : XmlTree.Name, Str -> Bool
is_w = |name, local| name.namespace == Uri(wordprocessingml) and name.local == local

is_w_in : XmlTree.Name, List(Str) -> Bool
is_w_in = |name, locals| name.namespace == Uri(wordprocessingml) and locals.contains(name.local)

is_element : XmlTree.Node, Str -> Bool
is_element = |node, local|
	match node {
		Element(element) => is_w(element.name, local)
		Text(_) => Bool.False
	}

# An element, or text that is not only whitespace.
is_content : XmlTree.Node -> Bool
is_content = |node|
	match node {
		Element(_) => Bool.True
		Text(content) => !content.to_utf8().all(|byte| byte == 32 or byte == 9 or byte == 10 or byte == 13)
	}

# Whether an element's attributes are at most the identifiers of a paragraph
# or row in Word's extension, `w14:paraId` and `w14:textId`, which the model
# does not hold and the writer allocates.
identified_only : Element -> Bool
identified_only = |element| element.attributes.all(|attribute| (attribute.name.local == "paraId" or attribute.name.local == "textId") and attribute.name.namespace == Uri(word_2010))

# Whether the first child element of a WordprocessingML name, where there is
# one, has no attributes, as the property elements the model reads have none.
plain_first : List(XmlTree.Node), Str -> Bool
plain_first = |children, local|
	match children.find_first(|child| is_element(child, local)) {
		Ok(Element(element)) => element.attributes.is_empty()
		_ => Bool.True
	}

# Whether a node is section properties as the model reads them, without
# attributes of their own.
is_plain_section : XmlTree.Node -> Bool
is_plain_section = |node|
	match node {
		Element(element) => is_w(element.name, "sectPr") and element.attributes.is_empty()
		Text(_) => Bool.False
	}

word_2010 : Str
word_2010 = "http://schemas.microsoft.com/office/word/2010/wordml"

kept : List(XmlTree.Node) -> List(XmlTree.Node)
kept = |nodes| nodes.keep_if(is_content)

without_children : Element -> XmlTree.Node
without_children = |element| Element({ name: element.name, bindings: element.bindings, attributes: element.attributes, children: [] })

# The value of a WordprocessingML attribute of an element.
value_of : Element, Str -> Try(Str, [NotFound])
value_of = |element, local| attribute_value(element.attributes, local)

attribute_value : List(XmlTree.Attribute), Str -> Try(Str, [NotFound])
attribute_value = |attributes, local| attributes.find_first(|attribute| is_w(attribute.name, local)).map_ok(|attribute| attribute.value)

relationships_namespace : Str
relationships_namespace = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

drawing_namespace : Str
drawing_namespace = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"

drawingml : Str
drawingml = "http://schemas.openxmlformats.org/drawingml/2006/main"

is_r : XmlTree.Name, Str -> Bool
is_r = |name, local| name.namespace == Uri(relationships_namespace) and name.local == local

is_named : XmlTree.Node, Str, Str -> Bool
is_named = |node, namespace, local|
	match node {
		Element(element) => element.name.namespace == Uri(namespace) and element.name.local == local
		Text(_) => Bool.False
	}

# The value of a relationship attribute of an element, such as `r:id`.
relationship_of : Element, Str -> Try(Str, [NotFound])
relationship_of = |element, local|
	element.attributes.find_first(|attribute| is_r(attribute.name, local)).map_ok(|attribute| attribute.value)

# The value of an attribute in no namespace.
unqualified : Element, Str -> Try(Str, [NotFound])
unqualified = |element, local|
	element.attributes.find_first(|attribute| attribute.name.namespace == NoNamespace and attribute.name.local == local).map_ok(|attribute| attribute.value)

# Whether an element's attributes are all WordprocessingML attributes the
# model holds.
only : Element, List(Str) -> Bool
only = |element, locals| element.attributes.all(|attribute| is_w_in(attribute.name, locals))

# The blocks of a main document part with this body content.
read : Str -> List(Document.Block)
read = |content| read_in(content, { relationships: [], footnotes: [], endnotes: [], comments: [] })

# The blocks of a main document part with this body content, in a package.
read_in : Str, WmlRead.Context -> List(Document.Block)
read_in = |content, context| {
	namespaces = "xmlns:w='${wordprocessingml}' xmlns:r='${relationships_namespace}' xmlns:wp='${drawing_namespace}' xmlns:a='${drawingml}'"
	tree = XmlTree.parse("<w:document ${namespaces}><w:body>${content}</w:body></w:document>".to_utf8(), {}) ?? Text("")
	WmlRead.body(tree, context)
}

# The properties of a `w:pPr` or `w:rPr` with this content.
properties_of : Str -> List(XmlTree.Node)
properties_of = |content|
	match XmlTree.parse("<w:pPr xmlns:w='${wordprocessingml}'>${content}</w:pPr>".to_utf8(), {}) {
		Ok(Element(element)) => element.children
		_ => []
	}

## Every modelled paragraph property is read, each from its first element,
## and what the model cannot hold is kept in order.
expect {
	border_xml = "<w:pBdr><w:top w:val='single' w:sz='4' w:space='1' w:color='auto'/><w:between w:val='double' w:sz='6'/></w:pBdr>"
	tabs = "<w:tabs><w:tab w:val='clear' w:pos='720'/><w:tab w:val='right' w:leader='dot' w:pos='9000'/></w:tabs>"
	stated = "<w:pStyle w:val='Quote'/><w:keepNext/><w:keepLines w:val='false'/><w:pageBreakBefore w:val='on'/><w:widowControl w:val='0'/><w:numPr><w:ilvl w:val='2'/><w:numId w:val='5'/></w:numPr>${border_xml}<w:shd w:val='clear' w:color='auto' w:fill='FFFF00'/>${tabs}<w:spacing w:before='120' w:after='60' w:line='360' w:lineRule='auto'/><w:ind w:left='720' w:right='-10' w:hanging='360'/><w:jc w:val='both'/><w:outlineLvl w:val='2'/>"
	unheld = "<w:keepNext w:val='false'/><w:spacing w:beforeLines='100'/><w:ind w:left='720.5'/><w:suppressAutoHyphens/><w:rPr><w:b/></w:rPr>"
	properties = WmlRead.paragraph_properties(properties_of("${stated}${unheld}"))
	expected : Document.ParagraphProperties
	expected = {
		style: Style("Quote"),
		alignment: Aligned(Both),
		indentation: { left: Twips(720), right: Twips(-10), first_line: Hanging(360) },
		spacing: { before: Twips(120), after: Twips(60), line: Auto(360) },
		keep_next: On,
		keep_lines: Off,
		page_break_before: On,
		widow_control: Off,
		outline_level: Level(2),
		borders: [
			{ edge: Top, line: "single", size: Eighths(4), space: Points(1), color: Auto },
			{ edge: Between, line: "double", size: Eighths(6), space: Unset, color: Unset },
		],
		shading: Shading({ pattern: "clear", color: Auto, fill: Rgb("FFFF00") }),
		tabs: Tabs([{ kind: Clear, position: 720, leader: Unset }, { kind: Right, position: 9000, leader: Dot }]),
		numbering: { instance: Instance(5), level: Level(2) },
		preserved: properties_of(unheld),
		mark: [],
		change: [],
	}
	properties == expected
}

## Every modelled run property is read, and an element with attributes the
## model cannot hold, such as an underline colour or a font hint, is kept.
expect {
	stated = "<w:rStyle w:val='Emphasis'/><w:rFonts w:ascii='Aptos' w:hAnsi='Aptos' w:eastAsia='' w:asciiTheme='minorHAnsi' w:cstheme='majorBidi'/><w:b/><w:i w:val='0'/><w:caps/><w:smallCaps w:val='off'/><w:strike/><w:dstrike w:val='false'/><w:vanish/><w:color w:val='0F4761' w:themeColor='accent1' w:themeShade='BF'/><w:sz w:val='28'/><w:highlight w:val='darkYellow'/><w:u w:val='dottedHeavy'/><w:vertAlign w:val='subscript'/><w:lang w:val='en-GB' w:eastAsia='zh-CN'/>"
	unheld = "<w:u w:val='single' w:color='FF0000'/><w:bCs/><w:sz w:val='big'/>"
	properties = WmlRead.run_properties(properties_of("${stated}${unheld}"))
	expected : Document.RunProperties
	expected = {
		style: Style("Emphasis"),
		bold: On,
		italic: Off,
		caps: On,
		small_caps: Off,
		strike: On,
		double_strike: Off,
		hidden: On,
		underline: Underline(DottedHeavy),
		vertical_align: Subscript,
		color: Color({ value: Rgb("0F4761"), theme: Theme("accent1"), tint: Unset, shade: Shade("BF") }),
		highlight: Highlight(DarkYellow),
		size: HalfPoints(28),
		fonts: { ascii: Named("Aptos"), high_ansi: Named("Aptos"), east_asia: Named(""), complex: Unset, ascii_theme: Theme(MinorHighAnsi), high_ansi_theme: Unset, east_asia_theme: Unset, complex_theme: Theme(MajorBidi) },
		language: { latin: Tag("en-GB"), east_asia: Tag("zh-CN"), complex: Unset },
		preserved: properties_of(unheld),
		change: [],
	}
	properties == expected
}

## A run's text, tab, breaks, symbol and hyphens are read in order.
expect {
	run_xml = "<w:r><w:rPr><w:b/></w:rPr><w:t xml:space='preserve'>a </w:t><w:tab/><w:br/><w:br w:type='page'/><w:br w:type='column'/><w:br w:clear='all'/><w:cr/><w:sym w:font='Wingdings' w:char='F0E0'/><w:softHyphen/><w:noBreakHyphen/></w:r>"
	expected : List(Document.RunContent)
	expected = [
		Text("a "),
		Tab,
		Break({ kind: Line, clear: NoClear }),
		Break({ kind: Page, clear: NoClear }),
		Break({ kind: Column, clear: NoClear }),
		Break({ kind: Line, clear: All }),
		Break({ kind: Line, clear: NoClear }),
		Symbol({ font: "Wingdings", code: 0xF0E0 }),
		SoftHyphen,
		NonBreakingHyphen,
	]
	match read("<w:p>${run_xml}</w:p>") {
		[Paragraph({ properties, content: [Run(r)] })] => properties == Document.no_paragraph_properties and r.content == expected and r.properties == { ..Document.no_run_properties, bold: On }
		_ => Bool.False
	}
}

## Text keeps its whitespace where `xml:space="preserve"` says so; elsewhere
## leading and trailing whitespace is removed and tabs and line ends are
## spaces.
expect {
	match read("<w:p><w:r><w:t xml:space='preserve'> a\tb </w:t><w:t>  c  d\n\te  </w:t><w:t> </w:t></w:r></w:p>") {
		[Paragraph({ properties: _, content: [Run(r)] })] => r.content == [Text(" a\tb "), Text("c  d  e"), Text("")]
		_ => Bool.False
	}
}

## Run content the model cannot hold is kept as it was read, in its place:
## a break of an unknown type, a symbol without a code, text holding an
## element, and elements the model does not represent.
expect {
	odd = ["<w:br w:type='sideways'/>", "<w:sym w:font='Symbol'/>", "<w:t>a<w:b/></w:t>", "<w:footnoteReference w:id='1'/>", "<w:delText>gone</w:delText>"]
	match read("<w:p><w:r>${Str.join_with(odd, "<w:tab/>")}</w:r></w:p>") {
		[Paragraph({ properties: _, content: [Run(r)] })] =>
			r.content.len() == 9
				and r.content.get(1) == Ok(Tab)
				and r.content.keep_if(|content| content != Tab).all(
					|content|
						match content {
							Preserved(_) => Bool.True
							_ => Bool.False
						},
				)

		_ => Bool.False
	}
}

## Content controls keep their element and have their content read; comment
## ranges stay in their place.
expect {
	content = "<w:pPr><w:pStyle w:val='Body'/></w:pPr><w:commentRangeStart w:id='1'/><w:sdt><w:sdtPr/><w:sdtContent><w:r><w:t>field</w:t></w:r></w:sdtContent></w:sdt><w:commentRangeEnd w:id='1'/>"
	match read("<w:p>${content}</w:p>") {
		[Paragraph({ properties, content: [Preserved(_), Container(sdt), Preserved(_)] })] =>
			properties == { ..Document.no_paragraph_properties, style: Style("Body") }
				and match sdt.content {
					[Preserved(_), Container(inner)] => inner.content.len() == 1
					_ => Bool.False
				}
				and match sdt.element {
					Element(element) => element.children.is_empty()
					Text(_) => Bool.False
				}

		_ => Bool.False
	}
}

## Tracked changes are read with their kind, author and date, the document's
## identifier dropped and an unreadable date kept; deleted text and deleted
## field code are text and field code in deleted content only; a change
## without an author is a container; a move's ranges are named, an end by
## the name its start gave, and an end without a start is kept, as are a
## range's start without the date the schema requires and its end.
expect {
	moved = "<w:moveFromRangeStart w:id='5' w:author='B' w:date='2026-05-07T11:30:00Z' w:name='move1'/><w:moveFrom w:id='6' w:author='B'><w:r><w:t>m</w:t></w:r></w:moveFrom><w:moveFromRangeEnd w:id='5'/><w:moveToRangeEnd w:id='9'/>"
	undated = "<w:moveToRangeStart w:id='7' w:author='B' w:name='move2'/><w:moveToRangeEnd w:id='7'/>"
	changed = "<w:ins w:id='2' w:author='A' w:date='soon'><w:r><w:t>new</w:t></w:r></w:ins><w:del w:id='3' w:author='A' w:date='2026-05-07T09:00:00+02:00'><w:r><w:delText>old</w:delText><w:delInstrText> PAGE </w:delInstrText></w:r></w:del><w:r><w:delText>stray</w:delText></w:r><w:ins w:id='4'><w:r><w:t>anon</w:t></w:r></w:ins>"
	match read("<w:p>${moved}${changed}${undated}</w:p>") {
		[Paragraph({ properties: _, content: [MoveStart(start), Revision(source), MoveEnd(end), Preserved(_), Revision(inserted), Revision(deleted), Run(stray), Container(_), Preserved(_), Preserved(_)] })] =>
			start == { side: Source, name: "move1", author: "B", date: { written: "2026-05-07T11:30:00Z", utc_seconds: 1778153400 }, preserved: [] }
				and end == { side: Source, name: "move1" }
				and source.kind == MoveSource
				and source.date == Unset
				and source.preserved.is_empty()
				and inserted.kind == Insertion
				and inserted.date == Unset
				and inserted.preserved.len() == 1
				and deleted == { kind: Deletion, author: "A", date: Date({ written: "2026-05-07T09:00:00+02:00", utc_seconds: 1778137200 }), content: [Run({ properties: Document.no_run_properties, content: [Text("old"), FieldCode("PAGE")] })], preserved: [] }
				and match stray.content {
					[Preserved(_)] => Bool.True
					_ => Bool.False
				}

		_ => Bool.False
	}
}

## A hyperlink's target is its external relationship's address, with its
## location when it has one, or a bookmark; its other attributes are kept.
## One whose relationship is missing or internal, or that has no target, is
## a container of its content.
expect {
	relationships = [
		{ id: "rId1", kind: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink", target: "https://example.org/a b", mode: External },
		{ id: "rId2", kind: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles", target: "/word/styles.xml", mode: Internal },
	]
	link = |attributes| "<w:hyperlink ${attributes}><w:r><w:t>x</w:t></w:r></w:hyperlink>"
	links = [link("r:id='rId1' w:tooltip='Tip'"), link("r:id='rId1' w:anchor='part'"), link("w:anchor='terms' w:history='1'"), link("r:id='rId9'"), link("r:id='rId2'"), link("w:tgtFrame='_blank'")]
	match read_in("<w:p>${Str.join_with(links, "")}</w:p>", { relationships, footnotes: [], endnotes: [], comments: [] }) {
		[Paragraph({ properties: _, content: [Hyperlink(external), Hyperlink(located), Hyperlink(internal), Container(missing), Container(part), Container(untargeted)] })] =>
			external.target == External("https://example.org/a b")
				and external.preserved.map(|attribute| attribute.value) == ["Tip"]
				and located.target == ExternalAt({ url: "https://example.org/a b", location: "part" })
				and located.preserved == []
				and internal.target == Internal("terms")
				and internal.preserved.map(|attribute| attribute.name.local) == ["history"]
				and external.content.len() == 1
				and [missing.content, part.content, untargeted.content].all(|content| content.len() == 1)

		_ => Bool.False
	}
}

## A bookmark's start and end are named by its name, wherever its start is;
## an end without a start and a bookmark spanning table columns are kept.
expect {
	content = "<w:p><w:bookmarkStart w:id='7' w:name='terms'/><w:r><w:t>a</w:t></w:r><w:bookmarkEnd w:id='5'/><w:bookmarkEnd w:id='9'/></w:p><w:p><w:bookmarkStart w:id='5' w:name='later'/><w:bookmarkEnd w:id='7'/><w:bookmarkStart w:id='8' w:name='c' w:colFirst='0' w:colLast='1'/></w:p>"
	match read(content) {
		[Paragraph(first), Paragraph(second)] =>
			match (first.content, second.content) {
				([BookmarkStart("terms"), Run(_), BookmarkEnd("later"), Preserved(_)], [BookmarkStart("later"), BookmarkEnd("terms"), Preserved(_)]) => Bool.True
				_ => Bool.False
			}

		_ => Bool.False
	}
}

## Note references name their note by its place among the notes; a
## reference to a missing note or with a custom mark is kept, and a note's
## own mark is read.
expect {
	run_xml = "<w:r><w:footnoteReference w:id='4'/><w:endnoteReference w:id='4'/><w:footnoteReference w:id='3'/><w:footnoteReference w:customMarkFollows='1' w:id='4'/><w:t>*</w:t><w:footnoteRef/><w:endnoteRef/></w:r>"
	match read_in("<w:p>${run_xml}</w:p>", { relationships: [], footnotes: ["-1", "0", "4"], endnotes: ["4"], comments: [] }) {
		[Paragraph({ properties: _, content: [Run(r)] })] =>
			match r.content {
				[NoteReference(footnote), NoteReference(endnote), Preserved(_), Preserved(_), Text("*"), NoteMark(Footnote), NoteMark(Endnote)] =>
					footnote == { kind: Footnote, note: 2 } and endnote == { kind: Endnote, note: 0 }

				_ => Bool.False
			}

		_ => Bool.False
	}
}

## A complex field's marks keep their elements and its code is read as text;
## a simple field holds its code and its result as content.
expect {
	complex = "<w:r><w:fldChar w:fldCharType='begin' w:dirty='true'/></w:r><w:r><w:instrText xml:space='preserve'> PAGE </w:instrText></w:r><w:r><w:fldChar w:fldCharType='separate'/></w:r><w:r><w:t>3</w:t></w:r><w:r><w:fldChar w:fldCharType='end'/><w:fldChar w:fldCharType='sideways'/></w:r>"
	simple = "<w:fldSimple w:instr=' NUMPAGES ' w:fldLock='1'><w:r><w:t>9</w:t></w:r></w:fldSimple><w:fldSimple><w:r><w:t>?</w:t></w:r></w:fldSimple>"
	match read("<w:p>${complex}${simple}</w:p>") {
		[Paragraph({ properties: _, content: [Run(begin), Run(code), Run(separate), Run(result), Run(end), SimpleField(field), Container(_)] })] =>
			match (begin.content, code.content, separate.content, end.content) {
				([FieldMark(b)], [FieldCode(" PAGE ")], [FieldMark(s)], [FieldMark(e), Preserved(_)]) =>
					b.kind == Begin
						and s.kind == Separate
						and e.kind == End
						and result.content == [Text("3")]
						and field.code == " NUMPAGES "
						and field.preserved.len() == 1
						and field.content.len() == 1

				_ => Bool.False
			}

		_ => Bool.False
	}
}

## An inline picture names its media part and its size and keeps its
## drawing; a floating drawing, or one whose image is not in the package, is
## kept as it was read.
expect {
	relationships = [{ id: "rId4", kind: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image", target: "/word/media/image1.png", mode: Internal }]
	drawing = |placement, extent, id| "<w:drawing><wp:${placement}>${extent}<wp:docPr id='1' name='Picture 1'/><a:graphic><a:graphicData uri='http://schemas.openxmlformats.org/drawingml/2006/picture'><a:blip r:embed='${id}'/></a:graphicData></a:graphic></wp:${placement}></w:drawing>"
	extent = "<wp:extent cx='1828800' cy='914400'/>"
	drawings = [drawing("inline", extent, "rId4"), drawing("anchor", extent, "rId4"), drawing("inline", extent, "rId5"), drawing("inline", "<wp:extent cx='1.5' cy='2'/>", "rId4")]
	match read_in("<w:p><w:r>${Str.join_with(drawings, "")}</w:r></w:p>", { relationships, footnotes: [], endnotes: [], comments: [] }) {
		[Paragraph({ properties: _, content: [Run(r)] })] =>
			match r.content {
				[Picture(inline_picture), Preserved(_), Preserved(_), Preserved(_)] => inline_picture.media == "/word/media/image1.png" and inline_picture.size == { width: 1828800, height: 914400 }
				_ => Bool.False
			}

		_ => Bool.False
	}
}

## A notes part's notes are read in order with their kinds and content, and
## their identifiers listed in the same order.
expect {
	notes = "<w:footnote w:type='separator' w:id='-1'><w:p><w:r><w:separator/></w:r></w:p></w:footnote><w:footnote w:id='0' w:type='continuationSeparator'/><w:footnote w:id='2'><w:p><w:r><w:footnoteRef/><w:t>Note.</w:t></w:r></w:p></w:footnote>"
	tree = XmlTree.parse("<w:footnotes xmlns:w='${wordprocessingml}'>${notes}<w:other/></w:footnotes>".to_utf8(), {}) ?? Text("")
	read_notes = WmlRead.notes(tree, { relationships: [], footnotes: [], endnotes: [], comments: [] })
	WmlRead.note_ids(tree) == ["-1", "0", "2"]
		and read_notes.map(|note| note.kind) == [Separator, ContinuationSeparator, Note]
		and read_notes.map(|note| note.content.len()) == [1, 0, 1]
		and WmlRead.notes(Text("x"), { relationships: [], footnotes: [], endnotes: [], comments: [] }) == []
}

## A table holds its properties, grid, rows and cells, a cell holds its
## paragraphs, and the section properties after it end a section.
expect {
	table_xml = "<w:tbl><w:tblPr/><w:tr><w:tc><w:tcPr/><w:p><w:r><w:t>cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>"
	match read("<w:p/>\n  ${table_xml}\n  <w:sectPr/>") {
		[Paragraph(empty), Table({ properties, grid: [], content: [Row({ properties: row_properties_read, content: [Cell({ properties: cell_properties_read, content: [Paragraph(in_cell)] })] })] }), Section(_)] =>
			empty == { properties: Document.no_paragraph_properties, content: [] }
				and properties == { style: Unset, width: Unset, borders: [], shading: Unset, preserved: [], change: [] }
				and row_properties_read == { header: Unset, grid_before: Unset, grid_after: Unset, preserved: [], inserted: Unset, deleted: Unset, change: [] }
				and cell_properties_read == { width: Unset, span: Unset, merge: Unset, borders: [], shading: Unset, alignment: Unset, preserved: [], revision: Unset, change: [] }
				and in_cell.content.len() == 1

		_ => Bool.False
	}
}

## A paragraph mark's changes are read from its character properties, which
## keep what else they hold, one without the author the schema requires
## staying as it was read; a change of a paragraph's or run's properties
## holds the properties before it, and a date that is not a date and time
## is kept among its attributes.
expect {
	stamp = Date({ written: "2026-05-07T09:00:00Z", utc_seconds: 1778144400 })
	marked = "<w:pPr><w:jc w:val='center'/><w:rPr><w:ins w:id='1' w:author='A' w:date='2026-05-07T09:00:00Z'/><w:del w:id='2' w:author='B'/><w:b/></w:rPr><w:pPrChange w:id='3' w:author='C'><w:pPr><w:jc w:val='left'/></w:pPr></w:pPrChange></w:pPr>"
	formatted = "<w:r><w:rPr><w:i/><w:rPrChange w:id='4' w:author='D' w:date='soon'><w:rPr><w:b/><w:rPrChange w:id='5' w:author='E'><w:rPr/></w:rPrChange></w:rPr></w:rPrChange></w:rPr><w:t>x</w:t></w:r>"
	anonymous = "<w:pPr><w:rPr><w:moveFrom w:id='6'/></w:rPr></w:pPr>"
	match read("<w:p>${marked}${formatted}</w:p><w:p>${anonymous}</w:p>") {
		[Paragraph({ properties, content: [Run(formatted_run)] }), Paragraph(other)] =>
			properties.mark == [{ kind: Insertion, author: "A", date: stamp, preserved: [] }, { kind: Deletion, author: "B", date: Unset, preserved: [] }]
				and properties.preserved == properties_of("<w:rPr><w:b/></w:rPr>")
				and properties.alignment == Aligned(Center)
				and properties.change == [{ author: "C", date: Unset, preserved: [], previous: { ..Document.paragraph_properties_with(Unset), alignment: Aligned(Left) } }]
				and match formatted_run.properties.change {
					[{ author: "D", date: Unset, preserved: [{ name: _, value: "soon" }], previous }] =>
						previous.bold == On and previous.change == Unset and previous.preserved.len() == 1

					_ => Bool.False
				}
				and other.properties.mark == []
				and other.properties.preserved == properties_of("<w:rPr><w:moveFrom w:id='6'/></w:rPr>")

		_ => Bool.False
	}
}

## A row's insertion and deletion, a cell's insertion, deletion or merge and
## a change of a table's, row's, cell's or section's properties are read;
## the properties before a change hold no changes, headers or footers of
## their own, which stay as they were read.
expect {
	change = |local, id, inner| "<w:${local} w:id='${id}' w:author='A'>${inner}</w:${local}>"
	table_properties_xml = "<w:tblPr><w:tblW w:w='0' w:type='auto'/>${change("tblPrChange", "1", "<w:tblPr/>")}</w:tblPr><w:tblGrid/>"
	row_properties_xml = "<w:trPr>${change("ins", "2", "")}${change("del", "3", "")}${change("trPrChange", "4", "<w:trPr>${change("ins", "5", "")}</w:trPr>")}</w:trPr>"
	merged = "<w:tc><w:tcPr><w:cellMerge w:id='6' w:author='A' w:vMerge='cont' w:vMergeOrig='rest'/>${change("tcPrChange", "7", "<w:tcPr><w:tcW w:w='0' w:type='auto'/></w:tcPr>")}</w:tcPr><w:p/></w:tc>"
	cell_with = |tracked| "<w:tc><w:tcPr>${tracked}</w:tcPr><w:p/></w:tc>"
	section_xml = "<w:sectPr><w:pgSz w:w='11906' w:h='16838'/>${change("sectPrChange", "10", "<w:sectPr><w:headerReference w:type='default' r:id='rId1'/><w:pgSz w:w='12240' w:h='15840'/></w:sectPr>")}</w:sectPr>"
	body = "<w:tbl>${table_properties_xml}<w:tr>${row_properties_xml}${merged}${cell_with(change("cellIns", "8", ""))}${cell_with(change("cellDel", "9", ""))}</w:tr></w:tbl>${section_xml}"
	by_a = { author: "A", date: Unset, preserved: [] }
	header = { id: "rId1", kind: header_relationship, target: "/word/header1.xml", mode: Internal }
	match read_in(body, { relationships: [header], footnotes: [], endnotes: [], comments: [] }) {
		[Table({ properties, grid: [], content: [Row({ properties: row_properties_read, content: [Cell(first), Cell(second), Cell(third)] })] }), Section(ended)] =>
			properties.change == [{ author: "A", date: Unset, preserved: [], previous: { style: Unset, width: Unset, borders: [], shading: Unset, preserved: [], change: Unset } }]
				and row_properties_read.inserted == Tracked(by_a)
				and row_properties_read.deleted == Tracked(by_a)
				and match row_properties_read.change {
					[{ author: "A", date: Unset, preserved: [], previous }] => previous.inserted == Unset and previous.preserved.len() == 1
					_ => Bool.False
				}
				and first.properties.revision == Merged({ author: "A", date: Unset, preserved: [], merge: Continue, previous: Restart })
				and match first.properties.change {
					[{ author: "A", date: Unset, preserved: [], previous }] => previous.width == Auto
					_ => Bool.False
				}
				and second.properties.revision == Inserted(by_a)
				and third.properties.revision == Deleted(by_a)
				and match ended.change {
					[{ author: "A", date: Unset, preserved: [], previous }] =>
						previous.page_size == Size({ width: 12240, height: 15840, orientation: Portrait }) and previous.headers == [] and previous.preserved.len() == 1

					_ => Bool.False
				}

		_ => Bool.False
	}
}

## A change of a run's properties that holds no properties, as LibreOffice
## writes one, changed properties that stated nothing.
expect {
	match read("<w:p><w:r><w:rPr><w:b/><w:rPrChange w:id='0' w:author='A'></w:rPrChange></w:rPr><w:t>x</w:t></w:r></w:p>") {
		[Paragraph({ properties: _, content: [Run(formatted_run)] })] => formatted_run.properties.change == [{ author: "A", date: Unset, preserved: [], previous: Document.run_properties_with(Unset) }]
		_ => Bool.False
	}
}

## A settings part tracks changes when its `w:trackRevisions` is on.
expect {
	settings = |content| XmlTree.parse("<w:settings xmlns:w='${wordprocessingml}'>${content}</w:settings>".to_utf8(), {}) ?? Text("")
	WmlRead.tracks_revisions(settings("<w:zoom w:percent='100'/><w:trackRevisions/>"))
		and !WmlRead.tracks_revisions(settings("<w:trackRevisions w:val='false'/>"))
		and !WmlRead.tracks_revisions(settings(""))
		and !WmlRead.tracks_revisions(Text(""))
}

## A settings part gives odd and even pages different headers and footers
## when its `w:evenAndOddHeaders` is on.
expect {
	settings = |content| XmlTree.parse("<w:settings xmlns:w='${wordprocessingml}'>${content}</w:settings>".to_utf8(), {}) ?? Text("")
	WmlRead.different_odd_and_even(settings("<w:defaultTabStop w:val='720'/><w:evenAndOddHeaders/>"))
		and WmlRead.different_odd_and_even(settings("<w:evenAndOddHeaders w:val='1'/>"))
		and !WmlRead.different_odd_and_even(settings("<w:evenAndOddHeaders w:val='off'/>"))
		and !WmlRead.different_odd_and_even(settings("<w:trackRevisions/>"))
		and !WmlRead.different_odd_and_even(Text(""))
}

## Table, row and cell properties the model holds are read and the rest are
## kept in order: a style, widths, borders, shading, a header row, grid
## columns skipped, a span, a merge and a vertical alignment.
expect {
	border = "w:val='single' w:sz='4' w:space='0' w:color='auto'"
	table_xml = "<w:tblPr><w:tblStyle w:val='Grid'/><w:tblW w:w='5000' w:type='pct'/><w:jc w:val='center'/><w:tblBorders><w:top ${border}/><w:insideV w:val='nil'/></w:tblBorders><w:shd w:val='clear' w:color='auto' w:fill='D9E2F3'/></w:tblPr>"
	grid_xml = "<w:tblGrid><w:gridCol w:w='2000'/><w:gridCol/></w:tblGrid>"
	row_xml = "<w:trPr><w:cantSplit/><w:gridBefore w:val='1'/><w:tblHeader/><w:gridAfter w:val='2'/></w:trPr>"
	cell_xml = "<w:tcPr><w:tcW w:w='0' w:type='auto'/><w:gridSpan w:val='2'/><w:vMerge w:val='restart'/><w:tcBorders><w:tl2br w:val='double' w:color='FF0000'/></w:tcBorders><w:shd w:val='pct25' w:fill='auto'/><w:noWrap/><w:vAlign w:val='center'/></w:tcPr>"
	match read("<w:tbl>${table_xml}${grid_xml}<w:tr>${row_xml}<w:tc>${cell_xml}<w:p/></w:tc></w:tr></w:tbl>") {
		[Table({ properties, grid: [Column(2000), Preserved(_)], content: [Row({ properties: row_read, content: [Cell({ properties: cell_read, content: [Paragraph(_)] })] })] })] =>
			properties.style == Style("Grid")
				and properties.width == Fiftieths(5000)
				and properties.borders == [
					{ edge: Top, line: "single", size: Eighths(4), space: Points(0), color: Auto },
					{ edge: InsideVertical, line: "nil", size: Unset, space: Unset, color: Unset },
				]
				and properties.shading == Shading({ pattern: "clear", color: Auto, fill: Rgb("D9E2F3") })
				and properties.preserved.len() == 1
				and row_read.header == On
				and row_read.grid_before == Columns(1)
				and row_read.grid_after == Columns(2)
				and row_read.preserved.len() == 1
				and cell_read.width == Auto
				and cell_read.span == Columns(2)
				and cell_read.merge == Restart
				and cell_read.borders == [{ edge: DiagonalDown, line: "double", size: Unset, space: Unset, color: Rgb("FF0000") }]
				and cell_read.shading == Shading({ pattern: "pct25", color: Unset, fill: Auto })
				and cell_read.alignment == Center
				and cell_read.preserved.len() == 1

		_ => Bool.False
	}
}

## A property element whose attributes the model cannot hold is kept as it
## was read, and the first one the model can hold gives the property: an
## automatic width with a size, an unknown merge and theme colours are kept.
expect {
	cell_xml = "<w:tcPr><w:tcW w:w='100' w:type='auto'/><w:tcW w:w='100' w:type='dxa'/><w:tcW w:w='200' w:type='dxa'/><w:vMerge w:val='sideways'/><w:shd w:val='clear' w:themeFill='accent1'/><w:tcBorders><w:top w:val='single' w:themeColor='text1'/></w:tcBorders></w:tcPr>"
	match read("<w:tbl><w:tr><w:tc>${cell_xml}<w:p/></w:tc></w:tr></w:tbl>") {
		[Table({ properties: _, grid: _, content: [Row({ properties: _, content: [Cell({ properties, content: _ })] })] })] =>
			properties.width == Twips(100)
				and properties.merge == Unset
				and properties.shading == Unset
				and properties.borders == []
				and properties.preserved.len() == 5

		_ => Bool.False
	}
}

## Widths written with a fraction, as Google Docs exports write them, are
## rounded with a diagnostic, and so is a percentage finer than the model
## holds; a whole percentage and a vertical merge without a value are read
## as they are.
expect {
	xml = "<w:tbl><w:tblPr><w:tblW w:w='33.3333%' w:type='pct'/></w:tblPr><w:tblGrid><w:gridCol w:w='10470.0'/><w:gridCol w:w='99.5'/></w:tblGrid><w:tr><w:tc><w:tcPr><w:tcW w:w='50%' w:type='pct'/><w:vMerge/></w:tcPr><w:p/></w:tc></w:tr></w:tbl>"
	tree = XmlTree.parse("<w:document xmlns:w='${wordprocessingml}'><w:body>${xml}</w:body></w:document>".to_utf8(), {}) ?? Text("")
	result = WmlRead.read_body(tree, { relationships: [], footnotes: [], endnotes: [], comments: [] })
	match result.blocks {
		[Table({ properties, grid: columns_read, content: [Row({ properties: _, content: [Cell(cell_read)] })] })] =>
			properties.width == Fiftieths(1667)
				and columns_read == [Column(10470), Column(100)]
				and cell_read.properties.width == Fiftieths(2500)
				and cell_read.properties.merge == Continue
				and result.diagnostics == [
					Rounded({ element: "tblW", attribute: "w", value: "33.3333%" }),
					Rounded({ element: "gridCol", attribute: "w", value: "10470.0" }),
					Rounded({ element: "gridCol", attribute: "w", value: "99.5" }),
				]

		_ => Bool.False
	}
}

## Tables nest in cells, and rows and cells in content controls are read
## through them, with bookmarks and row property exceptions in their place.
expect {
	inner = "<w:tbl><w:tr><w:tc><w:p><w:r><w:t>inner</w:t></w:r></w:p></w:tc></w:tr></w:tbl>"
	cell_control = "<w:sdt><w:sdtPr/><w:sdtContent><w:tc><w:p/></w:tc></w:sdtContent></w:sdt>"
	row_control = "<w:sdt><w:sdtContent><w:tr><w:tblPrEx/><w:tc>${inner}<w:p/></w:tc>${cell_control}</w:tr></w:sdtContent></w:sdt>"
	match read("<w:tbl><w:bookmarkStart w:id='1' w:name='b'/>${row_control}</w:tbl>") {
		[Table(outer)] =>
			match (outer.content, Document.table_rows(outer)) {
				([Preserved(_), Container(_)], [only_row]) =>
					match (only_row.content, Document.row_cells(only_row)) {
						([Preserved(_), Cell(_), Container(_)], [first, second]) =>
							second.content.len() == 1 and match first.content {
								[Table(nested), Paragraph(_)] => Document.table_rows(nested).len() == 1
								_ => Bool.False
							}

						_ => Bool.False
					}

				_ => Bool.False
			}

		_ => Bool.False
	}
}

## Extensions and alternatives are kept as they were read, in their place;
## Word's paragraph and row identifiers are not part of the model, and an
## element with any other attribute the model cannot hold, such as an
## extension's, is kept whole.
expect {
	mc = "xmlns:mc='http://schemas.openxmlformats.org/markup-compatibility/2006' xmlns:x='urn:example:x' xmlns:w14='${word_2010}' mc:Ignorable='x w14'"
	choice = "<mc:AlternateContent><mc:Choice Requires='x'><x:shape/></mc:Choice><mc:Fallback><w:t>fallback</w:t></mc:Fallback></mc:AlternateContent>"
	paragraphs = "<w:p w14:paraId='1A2B3C4D' w14:textId='77777777'><w:r>${choice}<w:t>a</w:t><w:tab x:id='1'/></w:r></w:p><w:p x:id='1'><w:r><w:t>b</w:t></w:r></w:p>"
	xml = "<w:document xmlns:w='${wordprocessingml}' ${mc}><w:body><x:block/>${paragraphs}</w:body></w:document>"
	tree = XmlTree.parse(xml.to_utf8(), {}) ?? Text("")
	match WmlRead.body(tree, { relationships: [], footnotes: [], endnotes: [], comments: [] }) {
		[Preserved(_), Paragraph({ properties: _, content: [Run(r)] }), Preserved(_)] =>
			match r.content {
				[Preserved(_), Text("a"), Preserved(_)] => Bool.True
				_ => Bool.False
			}

		_ => Bool.False
	}
}

## A tree that is not a WordprocessingML document, or has no body, has no
## blocks.
expect {
	other = XmlTree.parse("<w:styles xmlns:w='${wordprocessingml}'><w:body><w:p/></w:body></w:styles>".to_utf8(), {}) ?? Text("")
	bare = XmlTree.parse("<w:document xmlns:w='${wordprocessingml}'/>".to_utf8(), {}) ?? Text("")
	none = { relationships: [], footnotes: [], endnotes: [], comments: [] }
	WmlRead.body(other, none) == [] and WmlRead.body(bare, none) == []
}

## A paragraph whose mark ends a section is followed by the section's end,
## without the section in its properties; the body's last section ends the
## body. The properties the model holds are read, references to headers and
## footers name their parts, and the rest are kept in order.
expect {
	relationships = [
		{ id: "rId1", kind: header_relationship, target: "/word/header1.xml", mode: Internal },
		{ id: "rId2", kind: footer_relationship, target: "/word/footer1.xml", mode: Internal },
		{ id: "rId3", kind: header_relationship, target: "/word/header2.xml", mode: Internal },
	]
	references = "<w:headerReference w:type='default' r:id='rId1'/><w:footerReference w:type='first' r:id='rId2'/><w:headerReference w:type='even' r:id='rId9'/><w:footerReference w:type='default' r:id='rId3'/><w:headerReference w:type='default' r:id='rId3'/>"
	first = "<w:sectPr>${references}<w:footnotePr/><w:type w:val='continuous'/><w:pgSz w:w='16838' w:h='11906' w:orient='landscape'/><w:pgMar w:top='-1440' w:right='1440' w:bottom='1440' w:left='1800' w:header='708' w:footer='709' w:gutter='0'/><w:pgNumType w:fmt='lowerRoman' w:start='3'/><w:cols w:num='2' w:space='360' w:sep='1'/><w:titlePg/><w:docGrid w:linePitch='360'/></w:sectPr>"
	last = "<w:sectPr><w:pgSz w:w='12240' w:h='15840' w:code='1'/><w:cols w:equalWidth='0'><w:col w:w='4000' w:space='500'/><w:col w:w='5000'/></w:cols><w:pgNumType w:chapStyle='1'/></w:sectPr>"
	body = "<w:p><w:pPr><w:pStyle w:val='Body'/>${first}</w:pPr><w:r><w:t>a</w:t></w:r></w:p><w:p/>${last}"
	context = { relationships, footnotes: [], endnotes: [], comments: [] }
	match read_in(body, context) {
		[Paragraph(ending), Section(ended), Paragraph(_), Section(final)] =>
			ending.properties == { ..Document.no_paragraph_properties, style: Style("Body") }
				and ended.start == Continuous
				and ended.page_size == Size({ width: 16838, height: 11906, orientation: Landscape })
				and ended.margins == Margins({ top: -1440, right: 1440, bottom: 1440, left: 1800, header: 708, footer: 709, gutter: 0 })
				and ended.page_numbers == PageNumbers({ format: Format("lowerRoman"), start: Start(3) })
				and ended.columns == Equal({ count: 2, space: 360, separator: Line })
				and ended.title_page == On
				and ended.headers == [{ kind: Default, part: "/word/header1.xml" }]
				and ended.footers == [{ kind: First, part: "/word/footer1.xml" }]
				and ended.preserved.len() == 5
				and final.page_size == Unset
				and final.columns == Unequal({ widths: [{ width: 4000, space: 500 }, { width: 5000, space: 0 }], separator: NoLine })
				and final.page_numbers == Unset
				and final.preserved.len() == 2
				and Document.sections(read_in(body, context)) == [ended, final]

		_ => Bool.False
	}
}

## Margins written with a fraction, as Google Docs exports write them, are
## rounded with a diagnostic, and a missing margin is zero with one.
expect {
	margins_xml = "<w:sectPr><w:pgMar w:top='1440' w:right='863.9999999999999' w:bottom='1440' w:left='864' w:header='720' w:footer='720'/></w:sectPr>"
	tree = XmlTree.parse("<w:document xmlns:w='${wordprocessingml}'><w:body>${margins_xml}</w:body></w:document>".to_utf8(), {}) ?? Text("")
	result = WmlRead.read_body(tree, { relationships: [], footnotes: [], endnotes: [], comments: [] })
	match result.blocks {
		[Section(read_section)] =>
			read_section.margins == Margins({ top: 1440, right: 864, bottom: 1440, left: 864, header: 720, footer: 720, gutter: 0 })
				and result.diagnostics == [Rounded({ element: "pgMar", attribute: "right", value: "863.9999999999999" }), Defaulted({ element: "pgMar", attribute: "gutter" })]

		_ => Bool.False
	}
}

## A header or footer part's blocks are read as the body's are; another part
## has none.
expect {
	declarations = "xmlns:w='${wordprocessingml}'"
	header = XmlTree.parse("<w:hdr ${declarations}><w:p><w:r><w:t>Head</w:t></w:r></w:p><w:tbl/></w:hdr>".to_utf8(), {}) ?? Text("")
	other = XmlTree.parse("<w:document ${declarations}><w:p/></w:document>".to_utf8(), {}) ?? Text("")
	none = { relationships: [], footnotes: [], endnotes: [], comments: [] }
	match WmlRead.header_footer(header, none) {
		[Paragraph(heading), Table(_)] => Document.paragraph_text(heading) == "Head" and WmlRead.header_footer(other, none) == []
		_ => Bool.False
	}
}

## Core properties are read with their dates as written; a property with
## markup, a date that is not a W3C date and the properties the model does
## not hold are kept in order.
expect {
	declarations = "xmlns:cp='${core_namespace}' xmlns:dc='${dublin_core}' xmlns:dcterms='${dc_terms}' xmlns:xsi='${instance_namespace}'"
	dated = |name, value| "<dcterms:${name} xsi:type='dcterms:W3CDTF'>${value}</dcterms:${name}>"
	content = "<dc:title>Lease</dc:title><dc:subject></dc:subject><dc:creator>Ada</dc:creator><cp:keywords><cp:value>a</cp:value></cp:keywords><cp:lastModifiedBy>Grace</cp:lastModifiedBy><cp:revision>12</cp:revision>${dated("created", "2026-11-09T11:03:00Z")}${dated("modified", "yesterday")}<dc:language>en-AU</dc:language>"
	tree = XmlTree.parse("<cp:coreProperties ${declarations}>${content}</cp:coreProperties>".to_utf8(), {}) ?? Text("")
	read_core = WmlRead.core_properties(tree)
	read_core == { ..read_core, title: Text("Lease"), subject: Text(""), creator: Text("Ada"), keywords: Unset, description: Unset, last_modified_by: Text("Grace"), revision: Number(12), created: Date("2026-11-09T11:03:00Z"), modified: Unset }
		and read_core.preserved.len() == 3
		and WmlRead.core_properties(Text("")).title == Unset
}

## Extended properties are read as text and counts; others are kept.
expect {
	content = "<Application>Microsoft Office Word</Application><Pages>2</Pages><Company></Company><TotalTime>7</TotalTime><Words>many</Words><HeadingPairs><vt:vector size='0' baseType='variant'/></HeadingPairs><AppVersion>16.0000</AppVersion>"
	tree = XmlTree.parse("<Properties xmlns='${extended_namespace}' xmlns:vt='${variant_types}'>${content}</Properties>".to_utf8(), {}) ?? Text("")
	read_extended = WmlRead.extended_properties(tree)
	read_extended.application == Text("Microsoft Office Word")
		and read_extended.app_version == Text("16.0000")
		and read_extended.company == Text("")
		and read_extended.pages == Count(2)
		and read_extended.total_time == Count(7)
		and read_extended.words == Unset
		and read_extended.preserved.len() == 2
}

## Custom properties are read with their typed values in order; a value of
## another type and a linked property are kept.
expect {
	property = |pid, name, value| "<property fmtid='{D5CDD505-2E9C-101B-9397-08002B2CF9AE}' pid='${pid}' name='${name}'>${value}</property>"
	properties = [
		property("2", "Client", "<vt:lpwstr>Acme</vt:lpwstr>"),
		property("3", "Count", "<vt:i4>-42</vt:i4>"),
		property("4", "Signed", "<vt:bool>true</vt:bool>"),
		property("5", "Due", "<vt:filetime>2026-12-01T00:00:00Z</vt:filetime>"),
		property("6", "Rate", "<vt:r8>1.5</vt:r8>"),
		"<property fmtid='x' pid='7' name='Linked' linkTarget='bookmark'><vt:lpwstr>a</vt:lpwstr></property>",
	]
	tree = XmlTree.parse("<Properties xmlns='${custom_namespace}' xmlns:vt='${variant_types}'>${Str.join_with(properties, "")}</Properties>".to_utf8(), {}) ?? Text("")
	match WmlRead.custom_properties(tree) {
		[Property(client), Property(count), Property(sign), Property(due), Preserved(_), Preserved(_)] =>
			client == { name: "Client", value: Text("Acme") }
				and count == { name: "Count", value: Integer(-42) }
				and sign == { name: "Signed", value: Boolean(Bool.True) }
				and due == { name: "Due", value: Date("2026-12-01T00:00:00Z") }

		_ => Bool.False
	}
}

## W3C dates are a year, a month, a day, or a day and a time with its zone.
expect {
	dates = ["2026", "2026-11", "2026-11-09", "2026-11-09T11:03Z", "2026-11-09T11:03:00Z", "2026-11-09T11:03:00.25+10:00", "2026-11-09T11:03:00-05:30"]
	others = ["", "26", "2026-1", "2026-11-09T11:03:00", "2026-11-09 11:03:00Z", "2026-11-09T11:03:00.Z", "2026-11-09T11:03:00+1000", "yesterday"]
	dates.all(is_w3c_date) and !others.any(is_w3c_date)
}

## A comments part's comments are read in order with their author, initials,
## date and content, and their identifiers listed in the same order; a date
## that is not a date and time and the attributes the model does not hold are
## kept, and a comment without an author has the empty one with a
## diagnostic.
expect {
	comment_paragraph = |words| "<w:p><w:r><w:annotationRef/></w:r><w:r><w:t>${words}</w:t></w:r></w:p>"
	comments = [
		"<w:comment w:id='7' w:author='Ada Reviewer' w:initials='AR' w:date='2026-05-04T09:15:00Z'>${comment_paragraph("One")}${comment_paragraph("Two")}</w:comment>",
		"<w:comment w:id='3' w:author='Grace Author' w:date='soon' w:custom='x'>${comment_paragraph("Three")}</w:comment>",
		"<w:comment w:id='5'/>",
	]
	tree = XmlTree.parse("<w:comments xmlns:w='${wordprocessingml}'>${Str.join_with(comments, "")}<w:other/></w:comments>".to_utf8(), {}) ?? Text("")
	read_comments = WmlRead.comments(tree, { relationships: [], footnotes: [], endnotes: [], comments: [] })
	texts = |comment|
		comment.content.map(
			|content|
				match content {
					Paragraph(read_paragraph) => Document.paragraph_text(read_paragraph)
					_ => ""
				},
		)
	match read_comments.comments {
		[first, second, third] =>
			WmlRead.comment_ids(tree) == ["7", "3", "5"]
				and first.author == "Ada Reviewer"
				and first.initials == Initials("AR")
				and first.date == Date({ written: "2026-05-04T09:15:00Z", utc_seconds: 1777886100 })
				and texts(first) == ["One", "Two"]
				and first.preserved == []
				and second.initials == Unset
				and second.date == Unset
				and second.preserved.map(|attribute| attribute.name.local) == ["date", "custom"]
				and third.author == ""
				and read_comments.diagnostics == [Defaulted({ element: "comment", attribute: "author" })]
				and WmlRead.comments(Text("x"), { relationships: [], footnotes: [], endnotes: [], comments: [] }).comments == []

		_ => Bool.False
	}
}

## A date and time is read as written with its instant in UTC: an offset is
## converted, across a leap day, a time without a zone is UTC and a fraction
## of a second is left out; anything else is not a date and time.
expect {
	instant = |written| timestamp(written).map_ok(|stamp| stamp.utc_seconds)
	instant("2026-05-04T09:15:00Z") == Ok(1777886100)
		and instant("2024-02-29T23:30:00-01:00") == Ok(1709253000)
		and instant("2026-11-09T11:03:00.75+05:30") == Ok(1794202380)
		and instant("2000-01-01T00:00:00") == Ok(946684800)
		and ["", "2026-05-04", "2026-05-04T09:15Z", "2026-02-29T00:00:00Z", "2026-05-04T24:00:00Z", "2026-05-04T09:15:00.Z", "2026-05-04T09:15:00+0100"].all(|written| timestamp(written) == Err(NotDate))
}

## Comment ranges and references name their comment by its place in the
## comments part, in a paragraph and between blocks, rows and cells; one
## naming a comment that is not there, or displaced by custom XML, is kept.
expect {
	context = { relationships: [], footnotes: [], endnotes: [], comments: ["4", "9"] }
	table_xml = "<w:tbl><w:commentRangeStart w:id='9'/><w:tr><w:commentRangeEnd w:id='9'/><w:tc><w:p/></w:tc></w:tr></w:tbl>"
	paragraph_xml = "<w:p><w:commentRangeStart w:id='9'/><w:r><w:t>a</w:t><w:commentReference w:id='9'/><w:commentReference w:id='1'/></w:r><w:commentRangeEnd w:id='2'/><w:commentRangeStart w:id='4' w:displacedByCustomXml='next'/></w:p>"
	match read_in("<w:commentRangeStart w:id='4'/>${paragraph_xml}${table_xml}<w:commentRangeEnd w:id='4'/>", context) {
		[CommentStart(0), Paragraph(read_paragraph), Table(read_table), CommentEnd(0)] =>
			match (read_paragraph.content, read_table.content) {
				([CommentStart(1), Run({ properties: _, content: [Text("a"), CommentReference(1), Preserved(_)] }), Preserved(_), Preserved(_)], [CommentStart(1), Row(first_row)]) =>
					match first_row.content {
						[CommentEnd(1), Cell(_)] => Bool.True
						_ => Bool.False
					}

				_ => Bool.False
			}

		_ => Bool.False
	}
}
