## The typed model written as WordprocessingML, the inverse of [WmlRead].
##
## Every modelled value is written in one canonical form: the elements of a
## property list in the order the schema's sequence gives them, each
## element's attributes in a fixed order, a property that is on as the
## element alone and one that is off with `w:val="0"`, numbers as whole
## decimal numbers, and text with `xml:space="preserve"` exactly where its
## whitespace would otherwise be read as layout. What the model keeps as it
## was read is written as it was: a `Preserved` node in its place among the
## modelled content, a container's element around its written content, and
## a property element in `preserved` at its place in the schema's order.
##
## What the model names by meaning is given its identifier here, as a
## deterministic function of the model and the part's relationships: a
## bookmark, a tracked change and a move's range its `w:id`, a note reference
## the identifier of its note, and a hyperlink, picture, header or footer the
## relationship that leads to its target, found among the part's
## relationships or added to them.
import Document
import Numbering
import Opc
import Styles
import XmlTree

WmlWrite :: [].{

	## What writing a part needs from the rest of its package, as
	## [WmlRead.Context] gives reading it: the relationships whose source is
	## the part, the identifiers of the footnotes and of the endnotes in the
	## order of their parts, which a note reference's place indexes, and the
	## identifiers of the comments in the order of their part, which a
	## comment's range and reference index. A part written as one of a
	## document's parts shares the document's space of identifiers:
	## `reserved` holds those kept content anywhere in the document uses, as
	## [WmlWrite.kept_ids] gathers them, and `from` is the lowest number the
	## part's bookmarks, tracked changes and moves' ranges may take, the
	## `next` of the part written before it. Both default to a part written
	## on its own.
	Context := {
		relationships : List(Opc.Relationship),
		footnotes : List(Str),
		endnotes : List(Str),
		comments : List(Str),
		reserved : Set(Str) ?? Set.with_capacity(0),
		from : U64 ?? 0,
	}

	## Why blocks cannot be written: a note reference names a note by a
	## place the document's footnotes or endnotes do not have, or a comment's
	## range or reference a comment by a place its comments do not have; or a
	## comment with a thread to write, a parent, replies, the resolved mark, a
	## durable identifier or a UTC date, has no paragraph in its content for
	## the parts beside the comments part to name it by.
	WriteError : [MissingNote({ kind : Document.NoteKind, note : U64 }), MissingComment(U64), CommentWithoutParagraph(U64)]

	## The tree of a main document part whose body holds `content`, and the
	## part's relationships with any it needs added. `shell` is the part as
	## it was read: its root's declarations, attributes and children other
	## than the body are kept, and the body's content is written from the
	## model, a body added after them when the root has none. A shell whose
	## root is not a WordprocessingML document is not a main document, and is
	## returned as it is.
	##
	## A section ends after the paragraph whose mark ends it, in that
	## paragraph's properties, except the body's last block, which is the
	## body's own section; in a table cell, and wherever no paragraph comes
	## before it, a section is written where it stands.
	##
	## Bookmark identifiers come from one space shared with the identifiers
	## of the comments, those the kept content uses, such as a grid's kept
	## change, and those the context reserves: each bookmark takes the lowest
	## number from the context's `from` up that no kept element and no
	## earlier bookmark uses, in the order the bookmarks begin, and its end
	## takes its start's. Tracked changes and moves' ranges then take the
	## lowest numbers left, in the order they are written, a range's end its
	## start's; `next` is the number after the last taken. A comment's range
	## and reference take its comment's identifier.
	##
	## A tracked change is written with its identifier, author, date as it
	## was written and the attributes it kept; in a deletion, text is
	## `w:delText` and a piece of field code `w:delInstrText`. The schema has
	## no place for a hyperlink or a simple field in a change, so a change
	## that covers one is written around the content beside it and again
	## inside it, around its content, and reads back as those changes. A
	## paragraph
	## mark's changes are written first in the mark's character properties,
	## the first kept `w:rPr` of the paragraph's properties or one of their
	## own, and a change of properties around the properties before it, whose
	## own changes are not written, nor a section's headers and footers,
	## which the schema has no place for there. A move's range is written
	## with its date, which the schema requires.
	## A relationship is reused when the part has one to the same
	## target in the same mode, of the kind the reference needs where the
	## reader asks for one; otherwise it is added as `rId` with the lowest
	## number from the count of relationships up that no relationship uses.
	document : XmlTree.Node, List(Document.Block), Context -> Try({ tree : XmlTree.Node, relationships : List(Opc.Relationship), next : U64 }, WriteError)
	document = |shell, content, context| {
		root = match shell {
			Element(element) if is_w(element.name, "document") => element
			_ => return Ok({ tree: shell, relationships: context.relationships, next: context.from })
		}
		var $state = initial(content, context)?
		var $children = List.with_capacity(root.children.len() + 1)
		var $written = Bool.False
		for child in root.children {
			match child {
				Element(body) if !$written and is_w(body.name, "body") => {
					out = blocks(content, Body, $state)
					node : XmlTree.Node
					node = Element({ name: body.name, bindings: body.bindings, attributes: body.attributes, children: out.nodes })
					$children = List.append($children, node)
					$state = out.state
					$written = Bool.True
				}

				_ => {
					$children = List.append($children, child)
				}
			}
		}
		if !$written {
			out = blocks(content, Body, $state)
			$children = List.append($children, element("body", [], out.nodes))
			$state = out.state
		}
		tree : XmlTree.Node
		tree = Element({ name: root.name, bindings: root.bindings, attributes: root.attributes, children: $children })
		Ok({ tree, relationships: $state.relationships, next: $state.next })
	}

	## The tree of a footnotes or endnotes part holding `notes`, and the
	## part's relationships with any it needs added, as [WmlWrite.document]
	## gives a main document's. `shell` is the part as it was read: its
	## root's declarations and attributes and its children other than notes
	## are kept, and each note takes the place, the identifier and every
	## attribute but the kind of the note at its place in the shell, which
	## is how references name it. A note's kind, `w:type` except for a
	## `Note`, and its content are written from the model, its blocks as a
	## body's are outside a table cell. A note beyond the shell's is written
	## after the last, with the lowest identifier no note uses; a note of the
	## shell beyond the model's is not written. A shell whose root is not a
	## WordprocessingML footnotes or endnotes part is returned as it is.
	##
	## Bookmark identifiers are allocated across the part's notes as across a
	## main document's body.
	notes : XmlTree.Node, List(Document.Note), Context -> Try({ tree : XmlTree.Node, relationships : List(Opc.Relationship), next : U64 }, WriteError)
	notes = |shell, content, context| {
		root = match shell {
			Element(part) if is_w(part.name, "footnotes") or is_w(part.name, "endnotes") => part
			_ => return Ok({ tree: shell, relationships: context.relationships, next: context.from })
		}
		local = if (is_w(root.name, "footnotes")) "footnote" else "endnote"
		var $state = initial(List.join(content.map(|note| note.content)), context)?
		var $children = List.with_capacity(root.children.len() + 1)
		var $used = Set.with_capacity(content.len())
		var $index = 0.U64
		for child in root.children {
			match child {
				Element(kept) if is_w(kept.name, local) => {
					match content.get($index) {
						Ok(note) => {
							out = blocks(note.content, Flow, $state)
							attributes = with_kind(kept.attributes, note.kind)
							node : XmlTree.Node
							node = Element({ name: kept.name, bindings: kept.bindings, attributes, children: out.nodes })
							$children = List.append($children, node)
							$state = out.state
							$used = $used.insert(value_of(kept.attributes, "id") ?? "")
						}

						Err(_) => {}
					}
					$index = $index + 1
				}

				_ => {
					$children = List.append($children, child)
				}
			}
		}
		var $next = 0.U64
		while $index < content.len() {
			match content.get($index) {
				Ok(note) => {
					$next = free_id($used, $next)
					out = blocks(note.content, Flow, $state)
					$children = List.append($children, element(local, with_kind([{ name: { namespace: Uri(wordprocessingml), local: "id", prefix: Prefix("w") }, value: $next.to_str() }], note.kind), out.nodes))
					$state = out.state
					$used = $used.insert($next.to_str())
				}

				Err(_) => {}
			}
			$index = $index + 1
		}
		tree : XmlTree.Node
		tree = Element({ name: root.name, bindings: root.bindings, attributes: root.attributes, children: $children })
		Ok({ tree, relationships: $state.relationships, next: $state.next })
	}

	## The tree of a header or footer part holding `content`, and the part's
	## relationships with any it needs added, as [WmlWrite.document] gives a
	## main document's. `shell` is the part as it was read: its root's
	## declarations and attributes are kept, and its content is written from
	## the model, its blocks as a body's are outside a table cell. A shell
	## whose root is not a WordprocessingML header or footer is returned as it
	## is.
	header_footer : XmlTree.Node, List(Document.Block), Context -> Try({ tree : XmlTree.Node, relationships : List(Opc.Relationship), next : U64 }, WriteError)
	header_footer = |shell, content, context| {
		root = match shell {
			Element(part) if is_w(part.name, "hdr") or is_w(part.name, "ftr") => part
			_ => return Ok({ tree: shell, relationships: context.relationships, next: context.from })
		}
		out = blocks(content, Flow, initial(content, context)?)
		tree : XmlTree.Node
		tree = Element({ name: root.name, bindings: root.bindings, attributes: root.attributes, children: out.nodes })
		Ok({ tree, relationships: out.state.relationships, next: out.state.next })
	}

	## What the parts a comments part is written beside use, which the
	## comments part's identifiers avoid: their WordprocessingML `w:id`
	## values, and their paragraph identifiers as numbers, `w14:paraId` and,
	## in entries kept from the parts beside a comments part, `w15:paraId` and
	## `w16cid:paraId`.
	Taken : { ids : Set(Str), paragraphs : Set(U32) }

	## The identifiers these trees use, as [WmlWrite.Taken] gathers them. A
	## paragraph identifier that is not hexadecimal is not a number and
	## takes none.
	taken : List(XmlTree.Node) -> Taken
	taken = |trees| trees.fold({ ids: Set.with_capacity(16), paragraphs: Set.with_capacity(16) }, taken_in)

	## `found` with the identifiers that content kept as it was read uses in
	## these blocks, such as a permission range's or a tracked change the
	## model keeps whole. Gathered from the blocks of every part of a
	## document, the body, notes, headers, footers and comments, they are the
	## identifiers no comment, bookmark, tracked change or move's range
	## written anywhere in the document may take, as a [WmlWrite.Context]
	## reserves them.
	kept_ids : Set(Str), List(Document.Block) -> Set(Str)
	kept_ids = |found, content| {
		none : WmlWrite.Context
		none = { relationships: [], footnotes: [], endnotes: [], comments: [] }
		empty = { used: found, named: Dict.with_capacity(0), starts: List.with_capacity(0), missing: Ok({}) }
		content.fold(empty, |scan, block| scan_block(none, scan, block)).used
	}

	## The identifier each comment takes, in the order of the comments, from
	## the space bookmarks share: the lowest number from 0 up that is not
	## `kept`, the identifiers [WmlWrite.kept_ids] gives for every part of the
	## document and every comment, and that no earlier comment takes. Parts
	## written by [WmlWrite.document], [WmlWrite.notes] and
	## [WmlWrite.header_footer] with these identifiers as their
	## [WmlWrite.Context]'s comments give their bookmarks other numbers.
	comment_ids : Set(Str), List(Document.Comment) -> List(Str)
	comment_ids = |kept, listed| {
		var $ids = List.with_capacity(listed.len())
		var $next = 0.U64
		for _ in listed {
			id = free_id(kept, $next)
			$ids = List.append($ids, id.to_str())
			$next = id + 1
		}
		$ids
	}

	## The tree of a comments part holding `listed`, the part's
	## relationships with any its comments need added, and the paragraph
	## identifier each comment's last paragraph is given, the empty string
	## for a comment without a paragraph. `shell` is the part as it was read:
	## its root's declarations, attributes and children other than comments
	## are kept, and a shell that is not a comments part gives a new root.
	##
	## Each comment is written with the identifier `context` gives its
	## place, its author, date and initials, its other attributes as the
	## model keeps them, and its content written as a body's blocks are.
	## Bookmarks in comments take the lowest numbers that no identifier in
	## `taken`, no comment and no kept content uses. The last paragraph of a
	## comment's content, looking into tables and other elements but not
	## into a paragraph, is given the lowest paragraph identifier from 1 up
	## that `taken` and the paragraphs kept in comments do not use, as eight
	## hexadecimal digits; the extended comments, comment identifiers and
	## extensible comments parts name the comment by it, as
	## [Comments.split] writes them.
	comments : XmlTree.Node, List(Document.Comment), Context, Taken -> Try({ tree : XmlTree.Node, relationships : List(Opc.Relationship), paragraphs : List(Str) }, WriteError)
	comments = |shell, listed, context, taken_ids| {
		root = match shell {
			Element(found) if is_w(found.name, "comments") => found
			_ => { name: { namespace: Uri(wordprocessingml), local: "comments", prefix: Prefix("w") }, bindings: [], attributes: [], children: [] }
		}
		content = listed.fold(List.with_capacity(listed.fold(0, |total, comment| total + comment.content.len())), |all, comment| List.concat(all, comment.content))
		var $state = initial_reserving(content, context, taken_ids.ids)?
		parents = listed.fold(
			Set.with_capacity(listed.len()),
			|found, comment|
				match comment.parent {
					Parent(place) => found.insert(place)
					Unset => found
				},
		)
		var $unmarked = List.with_capacity(listed.len())
		var $place = 0.U64
		for comment in listed {
			id = context.comments.get($place) ? |_| MissingComment($place)
			out = blocks(comment.content, Flow, $state)
			$state = out.state
			unmarked = last_paragraph(out.nodes, |paragraph| { ..paragraph, attributes: paragraph.attributes.drop_if(is_paragraph_id) })
			threaded = comment.parent != Unset or comment.resolved or comment.durable_id != Unset or comment.utc_date != Unset or parents.contains($place)
			if threaded and !unmarked.found {
				return Err(CommentWithoutParagraph($place))
			}
			$unmarked = List.append($unmarked, { attributes: comment_attributes(comment, id), content: unmarked })
			$place = $place + 1
		}
		var $used = $unmarked.fold(taken_ids.paragraphs, |used, comment| comment.content.nodes.fold(used, paragraph_ids_in))
		var $next = 1.U32
		var $written = List.with_capacity(listed.len())
		var $paragraphs = List.with_capacity(listed.len())
		for comment in $unmarked {
			if comment.content.found {
				while $used.contains($next) {
					$next = $next + 1
				}
				identifier = hex8($next)
				$used = $used.insert($next)
				marked = last_paragraph(comment.content.nodes, |paragraph| { ..paragraph, attributes: List.append(paragraph.attributes, { name: { namespace: Uri(word_2010), local: "paraId", prefix: Prefix("w14") }, value: identifier }) })
				$written = List.append($written, element("comment", comment.attributes, marked.nodes))
				$paragraphs = List.append($paragraphs, identifier)
			} else {
				$written = List.append($written, element("comment", comment.attributes, comment.content.nodes))
				$paragraphs = List.append($paragraphs, "")
			}
		}
		tree : XmlTree.Node
		tree = Element({ name: root.name, bindings: root.bindings, attributes: root.attributes, children: List.concat(root.children.drop_if(|child| is_element_named(child, "comment")), $written) })
		Ok({ tree, relationships: $state.relationships, paragraphs: $paragraphs })
	}

	## A settings part's tree with revision tracking on or off, the
	## inverse of [WmlRead.tracks_revisions]: without its
	## `w:trackRevisions`, and for `On` with one where the schema's sequence
	## puts it, after the settings that come before it; every other child
	## as it was. A tree whose root is not WordprocessingML settings gives
	## a new settings part's.
	tracking : XmlTree.Node, [On, Off] -> XmlTree.Node
	tracking = |shell, state| setting(shell, "trackRevisions", settings_before_tracking, state)

	## A settings part's tree with different headers and footers for odd
	## and even pages on or off, the inverse of
	## [WmlRead.different_odd_and_even]: its `w:evenAndOddHeaders` set as
	## [WmlWrite.tracking] sets `w:trackRevisions`, in the place the schema's
	## sequence gives it.
	different_odd_and_even : XmlTree.Node, [On, Off] -> XmlTree.Node
	different_odd_and_even = |shell, state| setting(shell, "evenAndOddHeaders", settings_before_odd_and_even, state)

	## The tree of a styles part: `defaults`, the document's default
	## paragraph and run properties, and `styles` in order. Each style is
	## written with its kind, whether it is its kind's default, whether it
	## is a custom style, and its identifier; then its name, base, next and
	## linked styles and its paragraph and run properties from the model,
	## and the elements it kept, such as its user-interface priority or a
	## table style's table properties, each in the place the schema's
	## sequence gives it. A tracked change of a style's properties is
	## written with the lowest identifier the kept elements of the part do
	## not use. [Styles.read] reads the tree as these styles and defaults.
	styles : { defaults : { paragraph : Document.ParagraphProperties, run : Document.RunProperties }, styles : List(Styles.Style) } -> XmlTree.Node
	styles = |part| styles_tree(part)

	## The tree of a numbering part: `definitions`, each by its identifier,
	## then `instances`, each by its identifier, as the schema orders them.
	## A definition is written with its kind, the numbering style it stands
	## for or uses and its levels; a level with the number it starts from,
	## its format, paragraph style, text, alignment and paragraph and run
	## properties; an instance with its definition and its overrides; each
	## with the attributes and elements it kept in the place the schema's
	## sequence gives them. A level whose format is `Unset` is written
	## without one. [Numbering.read] reads the tree as these definitions and
	## instances.
	numbering : { definitions : List({ id : U32, definition : Numbering.Definition }), instances : List({ id : U32, instance : Numbering.Instance }) } -> XmlTree.Node
	numbering = |part| numbering_tree(part)

	## The tree of a core properties part holding `properties`: its title,
	## subject, author, keywords, description, who last modified it, its
	## revision number, and when it was created and last modified, each date
	## typed as the W3C date and time format, each where it is not `Unset`;
	## then every property it kept, in order. [WmlRead.core_properties]
	## reads the tree as these properties.
	core_properties : Document.CoreProperties -> XmlTree.Node
	core_properties = |properties| core_properties_tree(properties)
}

# A settings part's tree without its settings named `local`, and for `On`
# with one after the last of the settings named in `before`; every other
# child as it was. A tree whose root is not WordprocessingML settings gives
# a new settings part's.
setting : XmlTree.Node, Str, List(Str), [On, Off] -> XmlTree.Node
setting = |shell, local, before, state| {
	root = match shell {
		Element(found) if is_w(found.name, "settings") => found
		_ => { name: { namespace: Uri(wordprocessingml), local: "settings", prefix: Prefix("w") }, bindings: [], attributes: [], children: [] }
	}
	children = root.children.drop_if(|child| is_element_named(child, local))
	tree : XmlTree.Node
	tree = match state {
		Off => Element({ ..root, children })
		On => {
			var $at = 0.U64
			var $index = 0.U64
			for child in children {
				$index = $index + 1
				if before.any(|name| is_element_named(child, name)) {
					$at = $index
				}
			}
			Element({ ..root, children: List.join([children.sublist({ start: 0, len: $at }), [element(local, [], [])], children.drop_first($at)]) })
		}
	}
	tree
}

# The settings the schema's sequence puts before `w:evenAndOddHeaders`.
settings_before_odd_and_even : List(Str)
settings_before_odd_and_even = List.concat(settings_before_tracking, ["trackRevisions", "doNotTrackMoves", "doNotTrackFormatting", "documentProtection", "autoFormatOverride", "styleLockTheme", "styleLockQFSet", "defaultTabStop", "autoHyphenation", "consecutiveHyphenLimit", "hyphenationZone", "doNotHyphenateCaps", "showEnvelope", "summaryLength", "clickAndTypeStyle", "defaultTableStyle"])

# The settings the schema's sequence puts before `w:trackRevisions`.
settings_before_tracking : List(Str)
settings_before_tracking = ["writeProtection", "view", "zoom", "removePersonalInformation", "removeDateAndTime", "doNotDisplayPageBoundaries", "displayBackgroundShape", "printPostScriptOverText", "printFractionalCharacterWidth", "printFormsData", "embedTrueTypeFonts", "embedSystemFonts", "saveSubsetFonts", "saveFormsData", "mirrorMargins", "alignBordersAndEdges", "bordersDoNotSurroundHeader", "bordersDoNotSurroundFooter", "gutterAtTop", "hideSpellingErrors", "hideGrammaticalErrors", "activeWritingStyle", "proofState", "formsDesign", "attachedTemplate", "linkStyles", "stylePaneFormatFilter", "stylePaneSortMethod", "documentType", "mailMerge", "revisionView"]

# A note's attributes with its kind: `w:type` in its place, or last where
# there was none, and none for a `Note`, which is the schema's default.
with_kind : List(XmlTree.Attribute), [Note, Separator, ContinuationSeparator, ContinuationNotice] -> List(XmlTree.Attribute)
with_kind = |attributes, kind| {
	type_name = { namespace: Uri(wordprocessingml), local: "type", prefix: Prefix("w") }
	match kind {
		Note => attributes.drop_if(|existing| is_w(existing.name, "type"))
		Separator => with_attribute(attributes, type_name, "separator")
		ContinuationSeparator => with_attribute(attributes, type_name, "continuationSeparator")
		ContinuationNotice => with_attribute(attributes, type_name, "continuationNotice")
	}
}

# The value of a WordprocessingML attribute.
value_of : List(XmlTree.Attribute), Str -> Try(Str, [NotFound])
value_of = |attributes, local| attributes.find_first(|existing| is_w(existing.name, local)).map_ok(|existing| existing.value)

# What writing carries from one piece of content to the next: the part's
# relationships so far, the notes' identifiers, each modelled bookmark
# name's identifier and each kept bookmark start's, the names whose start is written, the identifiers kept
# content uses and the lowest identifier a further bookmark may take; the
# identifiers of the moves' source and destination ranges begun, by name;
# and whether what is written is deleted content.
State : {
	relationships : List(Opc.Relationship),
	footnotes : List(Str),
	endnotes : List(Str),
	comments : List(Str),
	bookmarks : Dict(Str, Str),
	kept_bookmarks : Dict(Str, Str),
	started : Set(Str),
	used : Set(Str),
	next : U64,
	move_sources : Dict(Str, Str),
	move_destinations : Dict(Str, Str),
	deleted : Bool,
}

# Written content and the state after it.
Out : { nodes : List(XmlTree.Node), state : State }

Written : { node : XmlTree.Node, state : State }

# Where blocks stand: the body, whose last section is its own; other content
# read as the body's is, such as a content control's; or a table cell, read
# block by block.
Mode : [Body, Flow, Cell]

# What a walk over the model finds before writing: the identifiers kept
# content uses, the names of kept bookmark starts by identifier, the names of
# the modelled bookmark starts in order, and the first note reference that
# names no note.
Scan : { used : Set(Str), named : Dict(Str, Str), starts : List(Str), missing : Try({}, WmlWrite.WriteError) }

initial : List(Document.Block), WmlWrite.Context -> Try(State, WmlWrite.WriteError)
initial = |content, context| initial_reserving(content, context, context.reserved)

# The state before writing content, its bookmarks avoiding the identifiers
# `reserved` holds, every comment's and those kept content uses, and taking
# numbers from the context's `from` up.
initial_reserving : List(Document.Block), WmlWrite.Context, Set(Str) -> Try(State, WmlWrite.WriteError)
initial_reserving = |content, context, reserved| {
	empty = { used: context.comments.fold(reserved, |ids, id| ids.insert(id)), named: Dict.with_capacity(0), starts: List.with_capacity(8), missing: Ok({}) }
	scan = content.fold(empty, |found, block| scan_block(context, found, block))
	scan.missing?
	var $bookmarks = Dict.with_capacity(scan.starts.len() + scan.named.len())
	var $next = context.from
	for name in scan.starts {
		if $bookmarks.get(name).is_err() {
			id = free_id(scan.used, $next)
			$bookmarks = $bookmarks.insert(name, id.to_str())
			$next = id + 1
		}
	}
	Ok({ relationships: context.relationships, footnotes: context.footnotes, endnotes: context.endnotes, comments: context.comments, bookmarks: $bookmarks, kept_bookmarks: scan.named, started: Set.with_capacity(scan.starts.len()), used: scan.used, next: $next, move_sources: Dict.with_capacity(0), move_destinations: Dict.with_capacity(0), deleted: Bool.False })
}

# The lowest identifier from `from` up that no kept content uses.
free_id : Set(Str), U64 -> U64
free_id = |used, from| {
	var $id = from
	while used.contains($id.to_str()) {
		$id = $id + 1
	}
	$id
}

scan_block : WmlWrite.Context, Scan, Document.Block -> Scan
scan_block = |context, scan, block|
	match block {
		Paragraph(paragraph) => paragraph.content.fold(scan_nodes(scan, followed_by(paragraph.properties.preserved, before(paragraph.properties.change, |previous| previous.preserved))), |found, item| scan_inline(context, found, item))
		Table(table) => {
			grid = table.grid.fold(
				scan_nodes(scan, followed_by(table.properties.preserved, before(table.properties.change, |previous| previous.preserved))),
				|found, column|
					match column {
						Column(_) => found
						Preserved(node) => scan_node(found, node)
					},
			)
			table.content.fold(grid, |found, item| scan_table_content(context, found, item))
		}

		Section(section) => scan_nodes(scan, followed_by(section.preserved, before(section.change, |previous| previous.preserved)))
		CommentStart(place) => scan_comment(context, scan, place)
		CommentEnd(place) => scan_comment(context, scan, place)
		Container({ element: node, content }) => content.fold(scan_node(scan, node), |found, item| scan_block(context, found, item))
		Preserved(node) => scan_node(scan, node)
	}

scan_table_content : WmlWrite.Context, Scan, Document.TableContent -> Scan
scan_table_content = |context, scan, item|
	match item {
		Row(row) => row.content.fold(scan_nodes(scan, followed_by(row.properties.preserved, before(row.properties.change, |previous| previous.preserved))), |found, inner| scan_row_content(context, found, inner))
		CommentStart(place) => scan_comment(context, scan, place)
		CommentEnd(place) => scan_comment(context, scan, place)
		Container({ element: node, content }) => content.fold(scan_node(scan, node), |found, inner| scan_table_content(context, found, inner))
		Preserved(node) => scan_node(scan, node)
	}

scan_row_content : WmlWrite.Context, Scan, Document.RowContent -> Scan
scan_row_content = |context, scan, item|
	match item {
		Cell(cell) => cell.content.fold(scan_nodes(scan, followed_by(cell.properties.preserved, before(cell.properties.change, |previous| previous.preserved))), |found, block| scan_block(context, found, block))
		CommentStart(place) => scan_comment(context, scan, place)
		CommentEnd(place) => scan_comment(context, scan, place)
		Container({ element: node, content }) => content.fold(scan_node(scan, node), |found, inner| scan_row_content(context, found, inner))
		Preserved(node) => scan_node(scan, node)
	}

scan_inline : WmlWrite.Context, Scan, Document.Inline -> Scan
scan_inline = |context, scan, item|
	match item {
		Run(run) => run.content.fold(scan_nodes(scan, followed_by(run.properties.preserved, before(run.properties.change, |previous| previous.preserved))), |found, content| scan_run_content(context, found, content))
		Hyperlink({ target: _, preserved: _, content }) => content.fold(scan, |found, inner| scan_inline(context, found, inner))
		SimpleField({ code: _, preserved: _, content }) => content.fold(scan, |found, inner| scan_inline(context, found, inner))
		BookmarkStart(name) => { ..scan, starts: List.append(scan.starts, name) }
		BookmarkEnd(_) => scan
		CommentStart(place) => scan_comment(context, scan, place)
		CommentEnd(place) => scan_comment(context, scan, place)
		Container({ element: node, content }) => content.fold(scan_node(scan, node), |found, inner| scan_inline(context, found, inner))
		Revision({ kind: _, author: _, date: _, content, preserved: _ }) => content.fold(scan, |found, inner| scan_inline(context, found, inner))
		MoveStart(_) => scan
		MoveEnd(_) => scan
		Preserved(node) => scan_node(scan, node)
	}

scan_run_content : WmlWrite.Context, Scan, Document.RunContent -> Scan
scan_run_content = |context, scan, content|
	match content {
		NoteReference({ kind, note }) => {
			ids = match kind {
				Footnote => context.footnotes
				Endnote => context.endnotes
			}
			if ids.get(note).is_ok() or scan.missing.is_err() {
				scan
			} else {
				{ ..scan, missing: Err(MissingNote({ kind, note })) }
			}
		}

		CommentReference(place) => scan_comment(context, scan, place)
		FieldMark({ kind: _, element: node }) => scan_node(scan, node)
		Preserved(node) => scan_node(scan, node)
		_ => scan
	}

# A comment's identifier is in use, or the comment is missing.
scan_comment : WmlWrite.Context, Scan, U64 -> Scan
scan_comment = |context, scan, place|
	match context.comments.get(place) {
		Ok(id) => { ..scan, used: scan.used.insert(id) }
		Err(_) => if (scan.missing.is_err()) scan else { ..scan, missing: Err(MissingComment(place)) }
	}

# What `kept` gives of the properties a tracked change replaced, if there is
# one.
before : List(Document.PropertyChange(p)), (p -> List(XmlTree.Node)) -> List(XmlTree.Node)
before = |changes, kept| changes.fold([], |nodes, changed| List.concat(nodes, kept(changed.previous)))

scan_nodes : Scan, List(XmlTree.Node) -> Scan
scan_nodes = |scan, nodes| nodes.fold(scan, scan_node)

# The identifiers a kept element and its content use, and the names of the
# bookmarks they begin. Local names are compared first, as comparing a
# namespace allocates.
scan_node : Scan, XmlTree.Node -> Scan
scan_node = |scan, node|
	match node {
		Element(kept) => {
			id = kept.attributes.find_first(|attribute| attribute.name.local == "id" and attribute.name.namespace == Uri(wordprocessingml))
			used = match id {
				Ok(attribute) => { ..scan, used: scan.used.insert(attribute.value) }
				Err(_) => scan
			}
			named = match (id, kept.name.local == "bookmarkStart" and is_w(kept.name, "bookmarkStart")) {
				(Ok(attribute), Bool.True) =>
					match kept.attributes.find_first(|candidate| candidate.name.local == "name" and candidate.name.namespace == Uri(wordprocessingml)) {
						Ok(name) if used.named.get(name.value).is_err() => { ..used, named: used.named.insert(name.value, attribute.value) }
						_ => used
					}

				_ => used
			}
			kept.children.fold(named, scan_node)
		}

		Text(_) => scan
	}

# Blocks in order. In the body and content read as the body's, a section
# after a paragraph goes into that paragraph's properties, unless it is the
# body's last block.
blocks : List(Document.Block), Mode, State -> Out
blocks = |content, mode, state| {
	var $nodes = List.with_capacity(content.len())
	var $state = state
	var $index = 0.U64
	while $index < content.len() {
		match content.get($index) {
			Ok(Paragraph(paragraph)) => {
				ending = match (mode, content.get($index + 1)) {
					(Cell, _) => Err(NoSection)
					(Body, Ok(Section(_))) if $index + 2 == content.len() => Err(NoSection)
					(_, Ok(Section(section))) => Ok(section)
					_ => Err(NoSection)
				}
				written = paragraph_node(paragraph, ending, $state)
				$nodes = List.append($nodes, written.node)
				$state = written.state
				$index = $index + (if (ending.is_ok()) 2 else 1)
			}

			Ok(Table(table)) => {
				written = table_node(table, $state)
				$nodes = List.append($nodes, written.node)
				$state = written.state
				$index = $index + 1
			}

			Ok(Section(section)) => {
				written = section_node(section, $state)
				$nodes = List.append($nodes, written.node)
				$state = written.state
				$index = $index + 1
			}

			Ok(CommentStart(place)) => {
				$nodes = List.append($nodes, comment_node("commentRangeStart", place, $state))
				$index = $index + 1
			}

			Ok(CommentEnd(place)) => {
				$nodes = List.append($nodes, comment_node("commentRangeEnd", place, $state))
				$index = $index + 1
			}

			Ok(Container({ element: kept, content: inner })) => {
				out = blocks(inner, if (mode == Cell) Cell else Flow, $state)
				$nodes = List.append($nodes, with_children(kept, out.nodes))
				$state = out.state
				$index = $index + 1
			}

			Ok(Preserved(node)) => {
				$nodes = List.append($nodes, node)
				$index = $index + 1
			}

			Err(_) => {
				$index = $index + 1
			}
		}
	}
	{ nodes: $nodes, state: $state }
}

paragraph_node : Document.Paragraph, Try(Document.Section, [NoSection]), State -> Written
paragraph_node = |paragraph, ending, state| {
	marked = mark_nodes(paragraph.properties.mark, state)
	(typed, preserved) = with_mark(paragraph_properties(paragraph.properties), paragraph.properties.preserved, marked.nodes)
	with_section = match ending {
		Ok(section) => {
			written = section_node(section, marked.state)
			{ typed: List.append(typed, written.node), state: written.state }
		}

		Err(NoSection) => { typed, state: marked.state }
	}
	changed = property_change("pPrChange", "pPr", paragraph.properties.change, |previous| ordered(paragraph_order, paragraph_properties(previous), previous.preserved), with_section.state)
	properties = ordered(paragraph_order, followed_by(with_section.typed, changed.nodes), preserved)
	out = paragraph.content.fold({ nodes: List.with_capacity(paragraph.content.len() + 1), state: changed.state }, inline)
	nodes = if (properties.is_empty()) out.nodes else List.prepend(out.nodes, element("pPr", [], properties))
	{ node: element("p", [], nodes), state: out.state }
}

inline : Out, Document.Inline -> Out
inline = |out, item|
	match item {
		Run(run) => {
			written = run_node(run, out.state)
			{ nodes: List.append(out.nodes, written.node), state: written.state }
		}

		Hyperlink({ target, preserved, content }) => {
			linked = match target {
				External(url) => {
					found = external(out.state, url)
					{ attributes: [relationship_attribute("id", found.id)], state: found.state }
				}

				ExternalAt({ url, location }) => {
					found = external(out.state, url)
					{ attributes: [relationship_attribute("id", found.id), attribute("anchor", location)], state: found.state }
				}

				Internal(name) => { attributes: [attribute("anchor", name)], state: out.state }
			}
			inner = content.fold({ nodes: List.with_capacity(content.len()), state: linked.state }, inline)
			{ nodes: List.append(out.nodes, element("hyperlink", List.concat(linked.attributes, preserved), inner.nodes)), state: inner.state }
		}

		SimpleField({ code, preserved, content }) => {
			inner = content.fold({ nodes: List.with_capacity(content.len()), state: out.state }, inline)
			{ nodes: List.append(out.nodes, element("fldSimple", List.prepend(preserved, attribute("instr", code)), inner.nodes)), state: inner.state }
		}

		BookmarkStart(name) => {
			state = out.state
			begun = if state.started.contains(name) {
				id = free_id(state.used, state.next)
				{ id: id.to_str(), state: { ..state, next: id + 1 } }
			} else {
				{ id: state.bookmarks.get(name) ?? "0", state: { ..state, started: state.started.insert(name) } }
			}
			{ nodes: List.append(out.nodes, element("bookmarkStart", [attribute("id", begun.id), attribute("name", name)], [])), state: begun.state }
		}

		BookmarkEnd(name) => {
			state = out.state
			ended = match (state.bookmarks.get(name), state.kept_bookmarks.get(name)) {
				(Ok(id), _) | (Err(_), Ok(id)) => { id, state }
				_ => {
					id = free_id(state.used, state.next)
					{ id: id.to_str(), state: { ..state, next: id + 1 } }
				}
			}
			{ nodes: List.append(out.nodes, element("bookmarkEnd", [attribute("id", ended.id)], [])), state: ended.state }
		}

		CommentStart(place) => { ..out, nodes: List.append(out.nodes, comment_node("commentRangeStart", place, out.state)) }
		CommentEnd(place) => { ..out, nodes: List.append(out.nodes, comment_node("commentRangeEnd", place, out.state)) }
		Container({ element: kept, content }) => {
			inner = content.fold({ nodes: List.with_capacity(content.len()), state: out.state }, inline)
			{ nodes: List.append(out.nodes, with_children(kept, inner.nodes)), state: inner.state }
		}

		Revision(revision) if revision.content.any(covers_link) => distributed(revision, revision.content).fold(out, inline)
		Revision({ kind, author, date, content, preserved }) => {
			local = match kind {
				Insertion => "ins"
				Deletion => "del"
				MoveSource => "moveFrom"
				MoveDestination => "moveTo"
			}
			numbered = fresh_id(out.state)
			outer = numbered.state.deleted
			inner = content.fold({ nodes: List.with_capacity(content.len()), state: { ..numbered.state, deleted: outer or kind == Deletion } }, inline)
			attributes = List.concat([attribute("id", numbered.id), attribute("author", author)], List.concat(date_attribute(date), preserved))
			{ nodes: List.append(out.nodes, element(local, attributes, inner.nodes)), state: { ..inner.state, deleted: outer } }
		}

		MoveStart({ side, name, author, date, preserved }) => {
			numbered = fresh_id(out.state)
			(local, state) = match side {
				Source => ("moveFromRangeStart", { ..numbered.state, move_sources: numbered.state.move_sources.insert(name, numbered.id) })
				Destination => ("moveToRangeStart", { ..numbered.state, move_destinations: numbered.state.move_destinations.insert(name, numbered.id) })
			}
			attributes = List.concat([attribute("id", numbered.id), attribute("name", name), attribute("author", author), attribute("date", date.written)], preserved)
			{ nodes: List.append(out.nodes, element(local, attributes, [])), state }
		}

		MoveEnd({ side, name }) => {
			(local, begun) = match side {
				Source => ("moveFromRangeEnd", out.state.move_sources.get(name))
				Destination => ("moveToRangeEnd", out.state.move_destinations.get(name))
			}
			ended = match begun {
				Ok(id) => { id, state: out.state }
				Err(_) => fresh_id(out.state)
			}
			{ nodes: List.append(out.nodes, element(local, [attribute("id", ended.id)], [])), state: ended.state }
		}

		Preserved(node) => { ..out, nodes: List.append(out.nodes, node) }
	}

# Whether content is, or a change holds, a hyperlink or a simple field, or a
# kept element of either, which the schema has no place for in a change.
covers_link : Document.Inline -> Bool
covers_link = |item|
	match item {
		Hyperlink(_) | SimpleField(_) => Bool.True
		Container({ element: Element(kept), content: _ }) => is_w(kept.name, "hyperlink") or is_w(kept.name, "fldSimple")
		Revision(inner) => inner.content.any(covers_link)
		_ => Bool.False
	}

# Content a change covers, written where the schema allows the change: the
# change around each stretch of other content, and inside each hyperlink or
# simple field, around its content. A change it holds is distributed first,
# so no change written holds a hyperlink or a simple field. A change that
# covers an empty hyperlink stays inside it, covering nothing.
distributed : Document.Revision, List(Document.Inline) -> List(Document.Inline)
distributed = |revision, content| {
	flat = content.fold(
		List.with_capacity(content.len()),
		|items, item|
			match item {
				Revision(inner) if inner.content.any(covers_link) => List.concat(items, distributed(inner, inner.content))
				_ => List.append(items, item)
			},
	)
	var $pieces = List.with_capacity(flat.len())
	var $stretch = List.with_capacity(flat.len())
	for item in flat {
		inside = match item {
			Hyperlink(link) => Ok(Hyperlink({ ..link, content: distributed(revision, link.content) }))
			SimpleField(field) => Ok(SimpleField({ ..field, content: distributed(revision, field.content) }))
			Container(kept) if covers_link(item) => Ok(Container({ ..kept, content: distributed(revision, kept.content) }))
			_ => Err(Outside)
		}
		match inside {
			Ok(wrapped) => {
				if !$stretch.is_empty() {
					$pieces = List.append($pieces, Revision({ ..revision, content: $stretch }))
					$stretch = List.with_capacity(flat.len())
				}
				$pieces = List.append($pieces, wrapped)
			}

			Err(Outside) => {
				$stretch = List.append($stretch, item)
			}
		}
	}
	if !$stretch.is_empty() or $pieces.is_empty() {
		$pieces = List.append($pieces, Revision({ ..revision, content: $stretch }))
	}
	$pieces
}

# A paragraph mark's changes in the schema's order, each with a fresh
# identifier.
mark_nodes : List(Document.MarkChange), State -> Out
mark_nodes = |mark, state|
	if mark.is_empty() {
		{ nodes: [], state }
	} else {
		[(Insertion, "ins"), (Deletion, "del"), (MoveSource, "moveFrom"), (MoveDestination, "moveTo")].fold(
			{ nodes: List.with_capacity(mark.len()), state },
			|out, (kind, local)|
				match mark.find_first(|change| change.kind == kind) {
					Ok(change) => {
						written = change_node(local, { author: change.author, date: change.date, preserved: change.preserved }, [], out.state)
						{ nodes: List.append(out.nodes, written.node), state: written.state }
					}

					Err(_) => out
				},
		)
	}

# A paragraph's typed and kept properties with its mark's changes first in
# the mark's character properties: in the first kept `w:rPr`, or in one of
# their own.
with_mark : List(XmlTree.Node), List(XmlTree.Node), List(XmlTree.Node) -> (List(XmlTree.Node), List(XmlTree.Node))
with_mark = |typed, preserved, changes| {
	if changes.is_empty() {
		return (typed, preserved)
	}
	match List.find_first_index(
		preserved,
		|node| match node {
			Element(found) => is_w(found.name, "rPr")
			Text(_) => Bool.False
		},
	) {
		Ok(index) =>
			match preserved.get(index) {
				Ok(Element(properties)) => (typed, List.set(preserved, index, Element({ ..properties, children: List.concat(changes, properties.children) })) ?? preserved)
				_ => (typed, preserved)
			}

		Err(_) => (List.append(typed, element("rPr", [], changes)), preserved)
	}
}

# A tracked change with a fresh identifier, its author, its date as it was
# written, the attributes it kept and any others the element needs.
change_node : Str, Document.Change, List(XmlTree.Attribute), State -> Written
change_node = |local, change, extra, state| {
	numbered = fresh_id(state)
	attributes = List.join([[attribute("id", numbered.id), attribute("author", change.author)], date_attribute(change.date), extra, change.preserved])
	{ node: element(local, attributes, []), state: numbered.state }
}

# A tracked change of properties: the change with a fresh identifier around
# the properties as they were, written by `write`, in an `inner` element.
property_change : Str, Str, List(Document.PropertyChange(p)), (p -> List(XmlTree.Node)), State -> Out
property_change = |local, inner, change, write, state|
	match change.first() {
		Ok(changed) => {
			written = change_node(local, { author: changed.author, date: changed.date, preserved: changed.preserved }, [], state)
			{ nodes: [with_children(written.node, [element(inner, [], write(changed.previous))])], state: written.state }
		}

		Err(_) => { nodes: [], state }
	}

# The lowest identifier no kept content and nothing written before uses.
fresh_id : State -> { id : Str, state : State }
fresh_id = |state| {
	id = free_id(state.used, state.next)
	{ id: id.to_str(), state: { ..state, next: id + 1 } }
}

# A tracked change's date as it was written, when it has one.
date_attribute : [Unset, Date(Document.Timestamp)] -> List(XmlTree.Attribute)
date_attribute = |date|
	match date {
		Date(stamp) => [attribute("date", stamp.written)]
		Unset => []
	}

run_node : Document.Run, State -> Written
run_node = |run, state| {
	changed = property_change("rPrChange", "rPr", run.properties.change, |previous| ordered(run_order, run_properties(previous), previous.preserved), state)
	properties = ordered(run_order, followed_by(run_properties(run.properties), changed.nodes), run.properties.preserved)
	start = if (properties.is_empty()) List.with_capacity(run.content.len()) else List.append(List.with_capacity(run.content.len() + 1), element("rPr", [], properties))
	out = run.content.fold({ nodes: start, state: changed.state }, run_content)
	{ node: element("r", [], out.nodes), state: out.state }
}

run_content : Out, Document.RunContent -> Out
run_content = |out, content|
	match content {
		Picture({ media, size, drawing }) => {
			found = related(out.state, image_relationship, media, Internal, |relationship| relationship.mode == Internal and relationship.target == media)
			{ nodes: List.append(out.nodes, sized_drawing(drawing, size, found.id)), state: found.state }
		}

		NoteReference({ kind, note }) => {
			(local, ids) = match kind {
				Footnote => ("footnoteReference", out.state.footnotes)
				Endnote => ("endnoteReference", out.state.endnotes)
			}
			{ ..out, nodes: List.append(out.nodes, element(local, [attribute("id", ids.get(note) ?? "")], [])) }
		}

		CommentReference(place) => { ..out, nodes: List.append(out.nodes, comment_node("commentReference", place, out.state)) }
		Text(value) if out.state.deleted => { ..out, nodes: List.append(out.nodes, text_element("delText", value)) }
		FieldCode(code) if out.state.deleted => { ..out, nodes: List.append(out.nodes, text_element("delInstrText", code)) }
		_ => { ..out, nodes: List.append(out.nodes, plain_content(content)) }
	}

# A comment's identifier, author, date and initials, then the attributes the
# model keeps.
comment_attributes : Document.Comment, Str -> List(XmlTree.Attribute)
comment_attributes = |comment, id| {
	date = match comment.date {
		Date(stamp) => [attribute("date", stamp.written)]
		Unset => []
	}
	initials = match comment.initials {
		Initials(text) => [attribute("initials", text)]
		Unset => []
	}
	List.join([[attribute("id", id), attribute("author", comment.author)], date, initials, comment.preserved])
}

Element : { name : XmlTree.Name, bindings : List(XmlTree.Binding), attributes : List(XmlTree.Attribute), children : List(XmlTree.Node) }

# Nodes with their last paragraph changed by `change`, looking into every
# element but a paragraph from the last node back, and whether there was one.
last_paragraph : List(XmlTree.Node), (Element -> Element) -> { nodes : List(XmlTree.Node), found : Bool }
last_paragraph = |nodes, change| {
	var $index = nodes.len()
	while $index > 0 {
		$index = $index - 1
		match nodes.get($index) {
			Ok(Element(found)) if is_w(found.name, "p") => {
				return { nodes: List.set(nodes, $index, Element(change(found))) ?? nodes, found: Bool.True }
			}

			Ok(Element(container)) => {
				inner = last_paragraph(container.children, change)
				if inner.found {
					return { nodes: List.set(nodes, $index, Element({ ..container, children: inner.nodes })) ?? nodes, found: Bool.True }
				}
			}

			_ => {}
		}
	}
	{ nodes, found: Bool.False }
}

# The paragraph identifiers a node and its content use, added to `used`.
paragraph_ids_in : Set(U32), XmlTree.Node -> Set(U32)
paragraph_ids_in = |used, node|
	match node {
		Element(found) => found.children.fold(with_paragraph_id(used, found), paragraph_ids_in)
		Text(_) => used
	}

# The paragraph identifier an element has, added to `used`.
with_paragraph_id : Set(U32), Element -> Set(U32)
with_paragraph_id = |used, found|
	match found.attributes.find_first(is_paragraph_id) {
		Ok(identifier) =>
			match hexadecimal(identifier.value) {
				Ok(number) => used.insert(number)
				Err(NotHex) => used
			}

		Err(_) => used
	}

# The identifiers a tree uses, added to those found so far.
taken_in : WmlWrite.Taken, XmlTree.Node -> WmlWrite.Taken
taken_in = |found, node|
	match node {
		Element(found_element) => {
			ids = match found_element.attributes.find_first(|candidate| candidate.name.local == "id" and candidate.name.namespace == Uri(wordprocessingml)) {
				Ok(id) => found.ids.insert(id.value)
				Err(_) => found.ids
			}
			paragraphs = match found_element.attributes.find_first(|candidate| candidate.name.local == "paraId" and [Uri(word_2010), Uri(word_2012), Uri(word_2016_cid)].contains(candidate.name.namespace)) {
				Ok(identifier) =>
					match hexadecimal(identifier.value) {
						Ok(number) => found.paragraphs.insert(number)
						Err(NotHex) => found.paragraphs
					}

				Err(_) => found.paragraphs
			}
			found_element.children.fold({ ids, paragraphs }, taken_in)
		}

		Text(_) => found
	}

is_paragraph_id : XmlTree.Attribute -> Bool
is_paragraph_id = |candidate| candidate.name.local == "paraId" and candidate.name.namespace == Uri(word_2010)

is_element_named : XmlTree.Node, Str -> Bool
is_element_named = |node, local|
	match node {
		Element(found) => is_w(found.name, local)
		Text(_) => Bool.False
	}

# One to eight hexadecimal digits as a number.
hexadecimal : Str -> Try(U32, [NotHex])
hexadecimal = |text| {
	digits = text.to_utf8()
	if digits.is_empty() or digits.len() > 8 {
		return Err(NotHex)
	}
	digits.fold(Ok(0.U32), |sum, digit| Ok((sum?) * 16 + (hex_value(digit)?)))
}

hex_value : U8 -> Try(U32, [NotHex])
hex_value = |digit|
	if digit >= '0' and digit <= '9' {
		Ok((digit - '0').to_u32())
	} else if digit >= 'a' and digit <= 'f' {
		Ok((digit - 'a' + 10).to_u32())
	} else if digit >= 'A' and digit <= 'F' {
		Ok((digit - 'A' + 10).to_u32())
	} else {
		Err(NotHex)
	}

# A number as eight hexadecimal digits.
hex8 : U32 -> Str
hex8 = |number| {
	digits = "0123456789ABCDEF".to_utf8()
	shifts = [268_435_456, 16_777_216, 1_048_576, 65_536, 4096, 256, 16, 1]
	Str.from_utf8(shifts.map(|shift| digits.get(((number // shift) % 16).to_u64()) ?? '0')) ?? "00000000"
}

# A comment's range boundary or reference, by its comment's identifier.
comment_node : Str, U64, State -> XmlTree.Node
comment_node = |local, place, state| element(local, [attribute("id", state.comments.get(place) ?? "")], [])

# Run content that needs nothing from the rest of the part.
plain_content : Document.RunContent -> XmlTree.Node
plain_content = |content|
	match content {
		Text(value) => text_element("t", value)
		Tab => element("tab", [], [])
		Break({ kind, clear }) => {
			kind_attributes = match kind {
				Line => []
				Page => [attribute("type", "page")]
				Column => [attribute("type", "column")]
			}
			clear_attributes = match clear {
				NoClear => []
				Left => [attribute("clear", "left")]
				Right => [attribute("clear", "right")]
				All => [attribute("clear", "all")]
			}
			element("br", List.concat(kind_attributes, clear_attributes), [])
		}

		Symbol({ font, code }) => {
			font_attributes = if (font == "") [] else [attribute("font", font)]
			element("sym", List.append(font_attributes, attribute("char", hex4(code))), [])
		}

		SoftHyphen => element("softHyphen", [], [])
		NonBreakingHyphen => element("noBreakHyphen", [], [])
		NoteMark(Footnote) => element("footnoteRef", [], [])
		NoteMark(Endnote) => element("endnoteRef", [], [])
		FieldMark({ kind: _, element: node }) => node
		FieldCode(code) => text_element("instrText", code)
		Preserved(node) => node
		NoteReference(_) => Text("")
		CommentReference(_) => Text("")
		Picture({ media: _, size: _, drawing }) => drawing
	}

# Text in `w:t`, `w:instrText` or their deleted forms, said to keep its
# whitespace exactly when reading would otherwise take some of it as layout.
text_element : Str, Str -> XmlTree.Node
text_element = |local, value| {
	bytes = value.to_utf8()
	space = |byte| byte == 32 or byte == 9 or byte == 10 or byte == 13
	preserve = bytes.first().map_ok(space) == Ok(Bool.True)
		or bytes.last().map_ok(space) == Ok(Bool.True)
		or bytes.any(|byte| byte == 9 or byte == 10 or byte == 13)
	attributes = if (preserve) [{ name: { namespace: Uri(xml_namespace), local: "space", prefix: Prefix("xml") }, value: "preserve" }] else []
	element(local, attributes, if (value == "") [] else [Text(value)])
}

# A character code as four hexadecimal digits.
hex4 : U16 -> Str
hex4 = |code| {
	digits = "0123456789ABCDEF".to_utf8()
	digit = |shift| digits.get(((code // shift) % 16).to_u64()) ?? '0'
	Str.from_utf8([digit(4096), digit(256), digit(16), digit(1)]) ?? "0000"
}

# An inline picture's drawing with its extent and its image's relationship
# as the model has them: the first `wp:extent` of its `wp:inline` takes the
# size, and the first `a:blip` in it embeds the relationship.
sized_drawing : XmlTree.Node, { width : U64, height : U64 }, Str -> XmlTree.Node
sized_drawing = |drawing, size, id|
	match drawing {
		Element(outer) => {
			children = outer.children.map(
				|child|
					match child {
						Element(placed) if placed.name.local == "inline" and placed.name.namespace == Uri(drawing_namespace) => {
							var $sized = List.with_capacity(placed.children.len())
							var $done = Bool.False
							for inner in placed.children {
								match inner {
									Element(extent) if !$done and extent.name.local == "extent" and extent.name.namespace == Uri(drawing_namespace) => {
										attributes = with_attribute(with_attribute(extent.attributes, unqualified("cx"), size.width.to_str()), unqualified("cy"), size.height.to_str())
										$sized = List.append($sized, Element({ name: extent.name, bindings: extent.bindings, attributes, children: extent.children }))
										$done = Bool.True
									}

									_ => {
										$sized = List.append($sized, inner)
									}
								}
							}
							embedded = with_embed(Element({ name: placed.name, bindings: placed.bindings, attributes: placed.attributes, children: $sized }), id)
							embedded.node
						}

						_ => child
					},
			)
			Element({ name: outer.name, bindings: outer.bindings, attributes: outer.attributes, children })
		}

		Text(_) => drawing
	}

# A tree whose first `a:blip` embeds the relationship `id`.
with_embed : XmlTree.Node, Str -> { node : XmlTree.Node, done : Bool }
with_embed = |node, id|
	match node {
		Element(blip) if blip.name.local == "blip" and blip.name.namespace == Uri(drawingml) => {
			embedded : XmlTree.Node
			embedded = Element({ name: blip.name, bindings: blip.bindings, attributes: with_attribute(blip.attributes, relationship_name("embed"), id), children: blip.children })
			{ node: embedded, done: Bool.True }
		}

		Element(parent) => {
			var $children = List.with_capacity(parent.children.len())
			var $done = Bool.False
			for child in parent.children {
				if $done {
					$children = List.append($children, child)
				} else {
					inner = with_embed(child, id)
					$children = List.append($children, inner.node)
					$done = inner.done
				}
			}
			rebuilt : XmlTree.Node
			rebuilt = Element({ name: parent.name, bindings: parent.bindings, attributes: parent.attributes, children: $children })
			{ node: rebuilt, done: $done }
		}

		Text(_) => { node, done: Bool.False }
	}

# Attributes with `name` set to `value`, in its place if it is there and
# last if it is not.
with_attribute : List(XmlTree.Attribute), XmlTree.Name, Str -> List(XmlTree.Attribute)
with_attribute = |attributes, name, value|
	if attributes.any(|existing| existing.name.local == name.local and existing.name.namespace == name.namespace) {
		attributes.map(|existing| if (existing.name.local == name.local and existing.name.namespace == name.namespace) { name: existing.name, value } else existing)
	} else {
		List.append(attributes, { name, value })
	}

table_node : Document.Table, State -> Written
table_node = |table, state| {
	changed = property_change("tblPrChange", "tblPr", table.properties.change, |previous| ordered(table_order, table_properties(previous), previous.preserved), state)
	properties = element("tblPr", [], ordered(table_order, followed_by(table_properties(table.properties), changed.nodes), table.properties.preserved))
	grid = element(
		"tblGrid",
		[],
		table.grid.map(
			|column|
				match column {
					Column(width) => element("gridCol", [attribute("w", width.to_str())], [])
					Preserved(node) => node
				},
		),
	)
	out = table.content.fold({ nodes: List.concat([properties, grid], List.with_capacity(table.content.len())), state: changed.state }, table_content)
	{ node: element("tbl", [], out.nodes), state: out.state }
}

table_content : Out, Document.TableContent -> Out
table_content = |out, item|
	match item {
		Row(row) => {
			written = row_node(row, out.state)
			{ nodes: List.append(out.nodes, written.node), state: written.state }
		}

		CommentStart(place) => { ..out, nodes: List.append(out.nodes, comment_node("commentRangeStart", place, out.state)) }
		CommentEnd(place) => { ..out, nodes: List.append(out.nodes, comment_node("commentRangeEnd", place, out.state)) }
		Container({ element: kept, content }) => {
			inner = content.fold({ nodes: List.with_capacity(content.len()), state: out.state }, table_content)
			{ nodes: List.append(out.nodes, with_children(kept, inner.nodes)), state: inner.state }
		}

		Preserved(node) => { ..out, nodes: List.append(out.nodes, node) }
	}

# A row: the table property exceptions it begins with, which the schema puts
# before its properties, then its properties and the rest of its content.
row_node : Document.Row, State -> Written
row_node = |row, state| {
	var $leading = 0.U64
	var $exceptions = List.with_capacity(1)
	var $leading_done = Bool.False
	for item in row.content {
		if !$leading_done {
			match item {
				Preserved(Element(exceptions)) if exceptions.name.local == "tblPrEx" and is_w(exceptions.name, "tblPrEx") => {
					$exceptions = List.append($exceptions, Element(exceptions))
					$leading = $leading + 1
				}

				_ => {
					$leading_done = Bool.True
				}
			}
		}
	}
	inserted = tracked_node("ins", row.properties.inserted, state)
	deleted = tracked_node("del", row.properties.deleted, inserted.state)
	changed = property_change("trPrChange", "trPr", row.properties.change, |previous| ordered(row_order, row_properties(previous), previous.preserved), deleted.state)
	properties = ordered(row_order, followed_by(followed_by(followed_by(row_properties(row.properties), inserted.nodes), deleted.nodes), changed.nodes), row.properties.preserved)
	start = if (properties.is_empty()) $exceptions else List.append($exceptions, element("trPr", [], properties))
	rest = List.drop_first(row.content, $leading)
	out = rest.fold({ nodes: List.concat(start, List.with_capacity(rest.len())), state: changed.state }, row_content)
	{ node: element("tr", [], out.nodes), state: out.state }
}

row_content : Out, Document.RowContent -> Out
row_content = |out, item|
	match item {
		Cell(cell) => {
			revised = match cell.properties.revision {
				Inserted(change) => tracked_node("cellIns", Tracked(change), out.state)
				Deleted(change) => tracked_node("cellDel", Tracked(change), out.state)
				Merged(merged) => {
					vertical = |local, merge|
						match merge {
							Continue => [attribute(local, "cont")]
							Restart => [attribute(local, "rest")]
							Unset => []
						}
					written = change_node("cellMerge", { author: merged.author, date: merged.date, preserved: merged.preserved }, List.concat(vertical("vMerge", merged.merge), vertical("vMergeOrig", merged.previous)), out.state)
					{ nodes: [written.node], state: written.state }
				}

				Unset => { nodes: [], state: out.state }
			}
			changed = property_change("tcPrChange", "tcPr", cell.properties.change, |previous| ordered(cell_order, cell_properties(previous), previous.preserved), revised.state)
			properties = ordered(cell_order, followed_by(followed_by(cell_properties(cell.properties), revised.nodes), changed.nodes), cell.properties.preserved)
			inner = blocks(cell.content, Cell, changed.state)
			nodes = if (properties.is_empty()) inner.nodes else List.prepend(inner.nodes, element("tcPr", [], properties))
			{ nodes: List.append(out.nodes, element("tc", [], nodes)), state: inner.state }
		}

		CommentStart(place) => { ..out, nodes: List.append(out.nodes, comment_node("commentRangeStart", place, out.state)) }
		CommentEnd(place) => { ..out, nodes: List.append(out.nodes, comment_node("commentRangeEnd", place, out.state)) }
		Container({ element: kept, content }) => {
			inner = content.fold({ nodes: List.with_capacity(content.len()), state: out.state }, row_content)
			{ nodes: List.append(out.nodes, with_children(kept, inner.nodes)), state: inner.state }
		}

		Preserved(node) => { ..out, nodes: List.append(out.nodes, node) }
	}

section_node : Document.Section, State -> Written
section_node = |section, state| {
	headers = references("headerReference", header_relationship, section.headers, state)
	footers = references("footerReference", footer_relationship, section.footers, headers.state)
	changed = property_change("sectPrChange", "sectPr", section.change, |previous| ordered(section_order, section_properties(previous), previous.preserved), footers.state)
	typed = followed_by(List.join([headers.nodes, footers.nodes, section_properties(section)]), changed.nodes)
	{ node: element("sectPr", [], ordered(section_order, typed, section.preserved)), state: changed.state }
}

# Typed properties followed by tracked changes, which most properties have
# none of, without copying the properties when there are none.
followed_by : List(XmlTree.Node), List(XmlTree.Node) -> List(XmlTree.Node)
followed_by = |typed, changes| if (changes.is_empty()) typed else List.concat(typed, changes)

# A tracked insertion or deletion of a row or cell, with a fresh identifier,
# where there is one.
tracked_node : Str, Document.Tracked, State -> Out
tracked_node = |local, tracked, state|
	match tracked {
		Tracked(change) => {
			written = change_node(local, change, [], state)
			{ nodes: [written.node], state: written.state }
		}

		Unset => { nodes: [], state }
	}

# References to headers or footers, each through a relationship of `kind`
# to its part.
references : Str, Str, List(Document.HeaderFooter), State -> Out
references = |local, kind, listed, state|
	listed.fold(
		{ nodes: List.with_capacity(listed.len()), state },
		|out, reference| {
			found = related(out.state, kind, reference.part, Internal, |relationship| relationship.mode == Internal and relationship.kind == kind and relationship.target == reference.part)
			which = match reference.kind {
				Default => "default"
				First => "first"
				Even => "even"
			}
			{ nodes: List.append(out.nodes, element(local, [attribute("type", which), relationship_attribute("id", found.id)], [])), state: found.state }
		},
	)

# The relationship to an address outside the package.
external : State, Str -> { id : Str, state : State }
external = |state, url| related(state, hyperlink_relationship, url, External, |relationship| relationship.mode == External and relationship.target == url)

# The first of the part's relationships `accepts` takes, or one added of
# `kind` to `target`.
related : State, Str, Str, [Internal, External], (Opc.Relationship -> Bool) -> { id : Str, state : State }
related = |state, kind, target, mode, accepts|
	match state.relationships.find_first(accepts) {
		Ok(found) => { id: found.id, state }
		Err(_) => {
			var $number = state.relationships.len() + 1
			while state.relationships.any(|relationship| relationship.id == "rId${$number.to_str()}") {
				$number = $number + 1
			}
			id = "rId${$number.to_str()}"
			{ id, state: { ..state, relationships: List.append(state.relationships, { id, kind, target, mode }) } }
		}
	}

# A container's element around its written content.
with_children : XmlTree.Node, List(XmlTree.Node) -> XmlTree.Node
with_children = |kept, children|
	match kept {
		Element(container) => Element({ name: container.name, bindings: container.bindings, attributes: container.attributes, children })
		Text(_) => kept
	}

# Property elements in the order of the schema's sequence `order`: modelled
# ones, which come in that order, first where both kinds share a place, kept
# ones in the order they were read. A kept element the sequence does not
# name, such as an extension, stays after the kept element before it.
ordered : List(Str), List(XmlTree.Node), List(XmlTree.Node) -> List(XmlTree.Node)
ordered = |order, typed, preserved| {
	if preserved.is_empty() {
		return typed
	}
	var $entries = List.with_capacity(typed.len() + preserved.len())
	var $seq = 0.U64
	for node in typed {
		$entries = List.append($entries, { rank: rank(order, node) ?? 0, seq: $seq, node })
		$seq = $seq + 1
	}
	var $previous = 0.U64
	for node in preserved {
		$previous = rank(order, node) ?? $previous
		$entries = List.append($entries, { rank: $previous, seq: $seq, node })
		$seq = $seq + 1
	}
	$entries
		.sort_with(|a, b| if (a.rank < b.rank or (a.rank == b.rank and a.seq < b.seq)) Before else if (a.rank == b.rank and a.seq == b.seq) Same else After)
		.map(|entry| entry.node)
}

# A WordprocessingML element's place in a sequence; a header and a footer
# reference share theirs.
rank : List(Str), XmlTree.Node -> Try(U64, [NotInSequence])
rank = |order, node|
	match node {
		Element(found) => {
			local = if (found.name.local == "footerReference") "headerReference" else found.name.local
			var $index = 0.U64
			for name in order {
				if name == local {
					return if (found.name.namespace == Uri(wordprocessingml)) Ok($index) else Err(NotInSequence)
				}
				$index = $index + 1
			}
			Err(NotInSequence)
		}

		Text(_) => Err(NotInSequence)
	}

paragraph_order : List(Str)
paragraph_order = ["pStyle", "keepNext", "keepLines", "pageBreakBefore", "framePr", "widowControl", "numPr", "suppressLineNumbers", "pBdr", "shd", "tabs", "suppressAutoHyphens", "kinsoku", "wordWrap", "overflowPunct", "topLinePunct", "autoSpaceDE", "autoSpaceDN", "bidi", "adjustRightInd", "snapToGrid", "spacing", "ind", "contextualSpacing", "mirrorIndents", "suppressOverlap", "jc", "textDirection", "textAlignment", "textboxTightWrap", "outlineLvl", "divId", "cnfStyle", "rPr", "sectPr", "pPrChange"]

run_order : List(Str)
run_order = ["rStyle", "rFonts", "b", "bCs", "i", "iCs", "caps", "smallCaps", "strike", "dstrike", "outline", "shadow", "emboss", "imprint", "noProof", "snapToGrid", "vanish", "webHidden", "color", "spacing", "w", "kern", "position", "sz", "szCs", "highlight", "u", "effect", "bdr", "shd", "fitText", "vertAlign", "rtl", "cs", "em", "lang", "eastAsianLayout", "specVanish", "oMath", "rPrChange"]

table_order : List(Str)
table_order = ["tblStyle", "tblpPr", "tblOverlap", "bidiVisual", "tblStyleRowBandSize", "tblStyleColBandSize", "tblW", "jc", "tblCellSpacing", "tblInd", "tblBorders", "shd", "tblLayout", "tblCellMar", "tblLook", "tblCaption", "tblDescription", "tblPrChange"]

row_order : List(Str)
row_order = ["cnfStyle", "divId", "gridBefore", "gridAfter", "wBefore", "wAfter", "cantSplit", "trHeight", "tblHeader", "tblCellSpacing", "jc", "hidden", "ins", "del", "trPrChange"]

cell_order : List(Str)
cell_order = ["cnfStyle", "tcW", "gridSpan", "hMerge", "vMerge", "tcBorders", "shd", "noWrap", "tcMar", "textDirection", "tcFitText", "vAlign", "hideMark", "headers", "cellIns", "cellDel", "cellMerge", "tcPrChange"]

section_order : List(Str)
section_order = ["headerReference", "footnotePr", "endnotePr", "type", "pgSz", "pgMar", "paperSrc", "pgBorders", "lnNumType", "pgNumType", "cols", "formProt", "vAlign", "noEndnote", "titlePg", "textDirection", "bidi", "rtlGutter", "docGrid", "printerSettings", "sectPrChange"]

# The edges of borders in the schema's order, which is the order of every
# borders element that has them.
edge_order : List(Str)
edge_order = ["top", "start", "left", "bottom", "end", "right", "insideH", "insideV", "tl2br", "tr2bl", "between", "bar"]

paragraph_properties : Document.ParagraphPropertiesOf(c) -> List(XmlTree.Node)
paragraph_properties = |properties| {
	numbering = List.concat(
		match properties.numbering.level {
			Level(level) => [value("ilvl", level.to_str())]
			Unset => []
		},
		match properties.numbering.instance {
			Instance(instance) => [value("numId", instance.to_str())]
			Unset => []
		},
	)
	indentation = List.join([
		signed_twips("left", properties.indentation.left),
		signed_twips("right", properties.indentation.right),
		match properties.indentation.first_line {
			Hanging(amount) => [attribute("hanging", amount.to_str())]
			FirstLine(amount) => [attribute("firstLine", amount.to_str())]
			Unset => []
		},
	])
	line = match properties.spacing.line {
		Auto(amount) => [attribute("line", amount.to_str()), attribute("lineRule", "auto")]
		Exact(amount) => [attribute("line", amount.to_str()), attribute("lineRule", "exact")]
		AtLeast(amount) => [attribute("line", amount.to_str()), attribute("lineRule", "atLeast")]
		Unset => []
	}
	spacing = List.join([unsigned_twips("before", properties.spacing.before), unsigned_twips("after", properties.spacing.after), line])
	List.join([
		match properties.style {
			Style(id) => [value("pStyle", id)]
			Unset => []
		},
		on_off("keepNext", properties.keep_next),
		on_off("keepLines", properties.keep_lines),
		on_off("pageBreakBefore", properties.page_break_before),
		on_off("widowControl", properties.widow_control),
		if (numbering.is_empty()) [] else [element("numPr", [], numbering)],
		borders("pBdr", properties.borders),
		shading(properties.shading),
		match properties.tabs {
			Tabs(stops) => [element("tabs", [], stops.map(tab_stop))]
			Unset => []
		},
		if (spacing.is_empty()) [] else [element("spacing", spacing, [])],
		if (indentation.is_empty()) [] else [element("ind", indentation, [])],
		match properties.alignment {
			Aligned(alignment) => [value("jc", alignment_name(alignment))]
			Unset => []
		},
		match properties.outline_level {
			Level(level) => [value("outlineLvl", level.to_str())]
			Unset => []
		},
	])
}

signed_twips : Str, [Unset, Twips(I32)] -> List(XmlTree.Attribute)
signed_twips = |local, amount|
	match amount {
		Twips(number) => [attribute(local, number.to_str())]
		Unset => []
	}

unsigned_twips : Str, [Unset, Twips(U32)] -> List(XmlTree.Attribute)
unsigned_twips = |local, amount|
	match amount {
		Twips(number) => [attribute(local, number.to_str())]
		Unset => []
	}

tab_stop : Document.TabStop -> XmlTree.Node
tab_stop = |stop| {
	kind = match stop.kind {
		Clear => "clear"
		Start => "start"
		End => "end"
		Left => "left"
		Right => "right"
		Center => "center"
		Decimal => "decimal"
		Bar => "bar"
		Num => "num"
	}
	leader = match stop.leader {
		Unset => []
		NoLeader => [attribute("leader", "none")]
		Dot => [attribute("leader", "dot")]
		Hyphen => [attribute("leader", "hyphen")]
		Underscore => [attribute("leader", "underscore")]
		Heavy => [attribute("leader", "heavy")]
		MiddleDot => [attribute("leader", "middleDot")]
	}
	element("tab", List.join([[attribute("val", kind)], leader, [attribute("pos", stop.position.to_str())]]), [])
}

alignment_name : Document.Alignment -> Str
alignment_name = |alignment|
	match alignment {
		Start => "start"
		End => "end"
		Left => "left"
		Right => "right"
		Center => "center"
		Both => "both"
		Distribute => "distribute"
		MediumKashida => "mediumKashida"
		HighKashida => "highKashida"
		LowKashida => "lowKashida"
		ThaiDistribute => "thaiDistribute"
		NumTab => "numTab"
	}

run_properties : Document.RunPropertiesOf(c) -> List(XmlTree.Node)
run_properties = |properties| {
	fonts = properties.fonts
	font_attributes = List.join([
		named("ascii", fonts.ascii),
		named("hAnsi", fonts.high_ansi),
		named("eastAsia", fonts.east_asia),
		named("cs", fonts.complex),
		theme_font("asciiTheme", fonts.ascii_theme),
		theme_font("hAnsiTheme", fonts.high_ansi_theme),
		theme_font("eastAsiaTheme", fonts.east_asia_theme),
		theme_font("cstheme", fonts.complex_theme),
	])
	language = List.join([tag("val", properties.language.latin), tag("eastAsia", properties.language.east_asia), tag("bidi", properties.language.complex)])
	List.join([
		match properties.style {
			Style(id) => [value("rStyle", id)]
			Unset => []
		},
		if (font_attributes.is_empty()) [] else [element("rFonts", font_attributes, [])],
		on_off("b", properties.bold),
		on_off("i", properties.italic),
		on_off("caps", properties.caps),
		on_off("smallCaps", properties.small_caps),
		on_off("strike", properties.strike),
		on_off("dstrike", properties.double_strike),
		on_off("vanish", properties.hidden),
		match properties.color {
			Color(color) => {
				shown = match color.value {
					Auto => "auto"
					Rgb(rgb) => rgb
				}
				theme = match color.theme {
					Theme(name) => [attribute("themeColor", name)]
					Unset => []
				}
				tint = match color.tint {
					Tint(amount) => [attribute("themeTint", amount)]
					Unset => []
				}
				shade = match color.shade {
					Shade(amount) => [attribute("themeShade", amount)]
					Unset => []
				}
				[element("color", List.join([[attribute("val", shown)], theme, tint, shade]), [])]
			}

			Unset => []
		},
		match properties.size {
			HalfPoints(size) => [value("sz", size.to_str())]
			Unset => []
		},
		match properties.highlight {
			Highlight(highlight) => [value("highlight", highlight_name(highlight))]
			Unset => []
		},
		match properties.underline {
			Underline(line) => [value("u", underline_name(line))]
			Unset => []
		},
		match properties.vertical_align {
			Baseline => [value("vertAlign", "baseline")]
			Superscript => [value("vertAlign", "superscript")]
			Subscript => [value("vertAlign", "subscript")]
			Unset => []
		},
		if (language.is_empty()) [] else [element("lang", language, [])],
	])
}

named : Str, [Unset, Named(Str)] -> List(XmlTree.Attribute)
named = |local, font|
	match font {
		Named(name) => [attribute(local, name)]
		Unset => []
	}

tag : Str, [Unset, Tag(Str)] -> List(XmlTree.Attribute)
tag = |local, language|
	match language {
		Tag(name) => [attribute(local, name)]
		Unset => []
	}

theme_font : Str, [Unset, Theme(Document.ThemeFont)] -> List(XmlTree.Attribute)
theme_font = |local, font|
	match font {
		Theme(theme) => {
			name = match theme {
				MajorEastAsia => "majorEastAsia"
				MajorBidi => "majorBidi"
				MajorAscii => "majorAscii"
				MajorHighAnsi => "majorHAnsi"
				MinorEastAsia => "minorEastAsia"
				MinorBidi => "minorBidi"
				MinorAscii => "minorAscii"
				MinorHighAnsi => "minorHAnsi"
			}
			[attribute(local, name)]
		}

		Unset => []
	}

highlight_name : Document.Highlight -> Str
highlight_name = |highlight|
	match highlight {
		Black => "black"
		Blue => "blue"
		Cyan => "cyan"
		Green => "green"
		Magenta => "magenta"
		Red => "red"
		Yellow => "yellow"
		White => "white"
		DarkBlue => "darkBlue"
		DarkCyan => "darkCyan"
		DarkGreen => "darkGreen"
		DarkMagenta => "darkMagenta"
		DarkRed => "darkRed"
		DarkYellow => "darkYellow"
		DarkGray => "darkGray"
		LightGray => "lightGray"
		NoHighlight => "none"
	}

underline_name : Document.Underline -> Str
underline_name = |line|
	match line {
		Single => "single"
		Words => "words"
		Double => "double"
		Thick => "thick"
		Dotted => "dotted"
		DottedHeavy => "dottedHeavy"
		Dash => "dash"
		DashedHeavy => "dashedHeavy"
		DashLong => "dashLong"
		DashLongHeavy => "dashLongHeavy"
		DotDash => "dotDash"
		DashDotHeavy => "dashDotHeavy"
		DotDotDash => "dotDotDash"
		DashDotDotHeavy => "dashDotDotHeavy"
		Wave => "wave"
		WavyHeavy => "wavyHeavy"
		WavyDouble => "wavyDouble"
		NoUnderline => "none"
	}

table_properties : Document.TablePropertiesOf(c) -> List(XmlTree.Node)
table_properties = |properties|
	List.join([
		match properties.style {
			Style(id) => [value("tblStyle", id)]
			Unset => []
		},
		width("tblW", properties.width),
		borders("tblBorders", properties.borders),
		shading(properties.shading),
	])

row_properties : Document.RowPropertiesOf(c) -> List(XmlTree.Node)
row_properties = |properties|
	List.join([
		columns("gridBefore", properties.grid_before),
		columns("gridAfter", properties.grid_after),
		on_off("tblHeader", properties.header),
	])

cell_properties : Document.CellPropertiesOf(c) -> List(XmlTree.Node)
cell_properties = |properties|
	List.join([
		width("tcW", properties.width),
		columns("gridSpan", properties.span),
		match properties.merge {
			Restart => [value("vMerge", "restart")]
			Continue => [element("vMerge", [], [])]
			Unset => []
		},
		borders("tcBorders", properties.borders),
		shading(properties.shading),
		match properties.alignment {
			Top => [value("vAlign", "top")]
			Center => [value("vAlign", "center")]
			Bottom => [value("vAlign", "bottom")]
			Both => [value("vAlign", "both")]
			Unset => []
		},
	])

columns : Str, [Unset, Columns(U64)] -> List(XmlTree.Node)
columns = |local, count|
	match count {
		Columns(number) => [value(local, number.to_str())]
		Unset => []
	}

width : Str, Document.Width -> List(XmlTree.Node)
width = |local, preferred|
	match preferred {
		Auto => [element(local, [attribute("w", "0"), attribute("type", "auto")], [])]
		Nil => [element(local, [attribute("w", "0"), attribute("type", "nil")], [])]
		Twips(amount) => [element(local, [attribute("w", amount.to_str()), attribute("type", "dxa")], [])]
		Fiftieths(amount) => [element(local, [attribute("w", amount.to_str()), attribute("type", "pct")], [])]
		Unset => []
	}

# Borders, their edges in the schema's order whatever the order they were
# read in.
borders : Str, List(Document.Border) -> List(XmlTree.Node)
borders = |local, edges|
	if edges.is_empty() {
		[]
	} else {
		written = edges.map(
			|border| {
				size = match border.size {
					Eighths(eighths) => [attribute("sz", eighths.to_str())]
					Unset => []
				}
				space = match border.space {
					Points(points) => [attribute("space", points.to_str())]
					Unset => []
				}
				element(edge_name(border.edge), List.join([[attribute("val", border.line)], color("color", border.color), size, space]), [])
			},
		)
		[element(local, [], ordered(edge_order, [], written))]
	}

edge_name : [Top, Left, Start, Bottom, Right, End, InsideHorizontal, InsideVertical, DiagonalDown, DiagonalUp, Between, Bar] -> Str
edge_name = |edge|
	match edge {
		Top => "top"
		Left => "left"
		Start => "start"
		Bottom => "bottom"
		Right => "right"
		End => "end"
		InsideHorizontal => "insideH"
		InsideVertical => "insideV"
		DiagonalDown => "tl2br"
		DiagonalUp => "tr2bl"
		Between => "between"
		Bar => "bar"
	}

shading : Document.Shading -> List(XmlTree.Node)
shading = |shade|
	match shade {
		Shading({ pattern, color: pattern_color, fill }) => [element("shd", List.join([[attribute("val", pattern)], color("color", pattern_color), color("fill", fill)]), [])]
		Unset => []
	}

color : Str, Document.Color -> List(XmlTree.Attribute)
color = |local, chosen|
	match chosen {
		Auto => [attribute(local, "auto")]
		Rgb(rgb) => [attribute(local, rgb)]
		Unset => []
	}

section_properties : Document.SectionOf(c) -> List(XmlTree.Node)
section_properties = |section|
	List.join([
		match section.start {
			NextPage => [value("type", "nextPage")]
			Continuous => [value("type", "continuous")]
			EvenPage => [value("type", "evenPage")]
			OddPage => [value("type", "oddPage")]
			NextColumn => [value("type", "nextColumn")]
			Unset => []
		},
		match section.page_size {
			Size({ width: across, height, orientation }) => {
				oriented = match orientation {
					Landscape => [attribute("orient", "landscape")]
					Portrait => []
				}
				[element("pgSz", List.concat([attribute("w", across.to_str()), attribute("h", height.to_str())], oriented), [])]
			}

			Unset => []
		},
		match section.margins {
			Margins(margins) => {
				attributes = [
					attribute("top", margins.top.to_str()),
					attribute("right", margins.right.to_str()),
					attribute("bottom", margins.bottom.to_str()),
					attribute("left", margins.left.to_str()),
					attribute("header", margins.header.to_str()),
					attribute("footer", margins.footer.to_str()),
					attribute("gutter", margins.gutter.to_str()),
				]
				[element("pgMar", attributes, [])]
			}

			Unset => []
		},
		match section.page_numbers {
			PageNumbers({ format, start }) => {
				formatted = match format {
					Format(name) => [attribute("fmt", name)]
					Unset => []
				}
				started = match start {
					Start(number) => [attribute("start", number.to_str())]
					Unset => []
				}
				[element("pgNumType", List.concat(formatted, started), [])]
			}

			Unset => []
		},
		match section.columns {
			Equal({ count, space, separator }) => {
				attributes = List.join([
					if (space == 720) [] else [attribute("space", space.to_str())],
					if (count == 1) [] else [attribute("num", count.to_str())],
					separated(separator),
				])
				[element("cols", attributes, [])]
			}

			Unequal({ widths, separator }) => {
				listed = widths.map(|column| element("col", List.concat([attribute("w", column.width.to_str())], if (column.space == 0) [] else [attribute("space", column.space.to_str())]), []))
				[element("cols", List.concat([attribute("equalWidth", "0")], separated(separator)), listed)]
			}

			Unset => []
		},
		on_off("titlePg", section.title_page),
	])

separated : [NoLine, Line] -> List(XmlTree.Attribute)
separated = |separator|
	match separator {
		Line => [attribute("sep", "1")]
		NoLine => []
	}

# An on or off property: on is the element alone, off says `w:val="0"`.
on_off : Str, [Unset, On, Off] -> List(XmlTree.Node)
on_off = |local, state|
	match state {
		On => [element(local, [], [])]
		Off => [value(local, "0")]
		Unset => []
	}

value : Str, Str -> XmlTree.Node
value = |local, text| element(local, [attribute("val", text)], [])

element : Str, List(XmlTree.Attribute), List(XmlTree.Node) -> XmlTree.Node
element = |local, attributes, children| Element({ name: { namespace: Uri(wordprocessingml), local, prefix: Prefix("w") }, bindings: [], attributes, children })

attribute : Str, Str -> XmlTree.Attribute
attribute = |local, text| { name: { namespace: Uri(wordprocessingml), local, prefix: Prefix("w") }, value: text }

relationship_name : Str -> XmlTree.Name
relationship_name = |local| { namespace: Uri(relationships_namespace), local, prefix: Prefix("r") }

relationship_attribute : Str, Str -> XmlTree.Attribute
relationship_attribute = |local, text| { name: relationship_name(local), value: text }

unqualified : Str -> XmlTree.Name
unqualified = |local| { namespace: NoNamespace, local, prefix: Unprefixed }

is_w : XmlTree.Name, Str -> Bool
is_w = |name, local| name.local == local and name.namespace == Uri(wordprocessingml)

wordprocessingml : Str
wordprocessingml = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

relationships_namespace : Str
relationships_namespace = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

drawing_namespace : Str
drawing_namespace = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"

drawingml : Str
drawingml = "http://schemas.openxmlformats.org/drawingml/2006/main"

xml_namespace : Str
xml_namespace = "http://www.w3.org/XML/1998/namespace"

# Word's extension that identifies paragraphs, and those of the extended
# comments and comment identifiers parts, from MS-DOCX.
word_2010 : Str
word_2010 = "http://schemas.microsoft.com/office/word/2010/wordml"

word_2012 : Str
word_2012 = "http://schemas.microsoft.com/office/word/2012/wordml"

word_2016_cid : Str
word_2016_cid = "http://schemas.microsoft.com/office/word/2016/wordml/cid"

hyperlink_relationship : Str
hyperlink_relationship = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink"

image_relationship : Str
image_relationship = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"

header_relationship : Str
header_relationship = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/header"

footer_relationship : Str
footer_relationship = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer"

styles_tree : { defaults : { paragraph : Document.ParagraphProperties, run : Document.RunProperties }, styles : List(Styles.Style) } -> XmlTree.Node
styles_tree = |part| {
	var $state = { ..blank_state, used: WmlWrite.taken(part.styles.map(|style| element("style", [], List.join([style.preserved, style.paragraph.preserved, style.run.preserved])))).ids }
	run_default = run_properties_node(part.defaults.run, $state)
	paragraph_default = paragraph_properties_node(part.defaults.paragraph, run_default.state)
	$state = paragraph_default.state
	defaults = List.join([
		if (run_default.nodes.is_empty()) [] else [element("rPrDefault", [], run_default.nodes)],
		if (paragraph_default.nodes.is_empty()) [] else [element("pPrDefault", [], paragraph_default.nodes)],
	])
	var $children = List.with_capacity(part.styles.len() + 1)
	if !defaults.is_empty() {
		$children = List.append($children, element("docDefaults", [], defaults))
	}
	for style in part.styles {
		written = style_node(style, $state)
		$children = List.append($children, written.node)
		$state = written.state
	}
	element("styles", [], $children)
}

# A style as a `w:style`.
style_node : Styles.Style, State -> Written
style_node = |style, state| {
	paragraph_written = paragraph_properties_node(style.paragraph, state)
	run_written = run_properties_node(style.run, paragraph_written.state)
	kind = match style.kind {
		Paragraph => "paragraph"
		Character => "character"
		Table => "table"
		Numbering => "numbering"
	}
	usage = if (style.usage == KindDefault) [attribute("default", "1")] else []
	origin = if (style.origin == Custom) [attribute("customStyle", "1")] else []
	attributes = List.join([[attribute("type", kind)], usage, origin, [attribute("styleId", style.id)]])
	typed = List.join([
		match style.name {
			Named(name) => [value("name", name)]
			Unnamed => []
		},
		match style.based_on {
			BasedOn(base) => [value("basedOn", base)]
			NoBase => []
		},
		match style.next {
			Next(next) => [value("next", next)]
			NoNext => []
		},
		match style.link {
			Linked(link) => [value("link", link)]
			NoLink => []
		},
		paragraph_written.nodes,
		run_written.nodes,
	])
	{ node: element("style", attributes, ordered(style_order, typed, style.preserved)), state: run_written.state }
}

numbering_tree : { definitions : List({ id : U32, definition : Numbering.Definition }), instances : List({ id : U32, instance : Numbering.Instance }) } -> XmlTree.Node
numbering_tree = |part| {
	kept_levels = |levels| levels.map(|level| element("lvl", [], kept_in_level(level)))
	kept = List.join([
		part.definitions.map(|entry| element("abstractNum", [], List.concat(entry.definition.preserved, kept_levels(entry.definition.levels)))),
		part.instances.map(|entry| element("num", [], List.concat(entry.instance.preserved, kept_levels(entry.instance.overrides.keep_oks(replaced))))),
	])
	var $state = { ..blank_state, used: WmlWrite.taken(kept).ids }
	var $children = List.with_capacity(part.definitions.len() + part.instances.len())
	for entry in part.definitions {
		written = definition_node(entry.id, entry.definition, $state)
		$children = List.append($children, written.node)
		$state = written.state
	}
	for entry in part.instances {
		written = instance_node(entry.id, entry.instance, $state)
		$children = List.append($children, written.node)
		$state = written.state
	}
	element("numbering", [], $children)
}

# A numbering definition as a `w:abstractNum`.
definition_node : U32, Numbering.Definition, State -> Written
definition_node = |id, definition, state| {
	levels = definition.levels.fold(
		{ nodes: List.with_capacity(definition.levels.len()), state },
		|out, level| {
			written = level_node(level, out.state)
			{ nodes: List.append(out.nodes, written.node), state: written.state }
		},
	)
	typed = List.join([
		match definition.kind {
			SingleLevel => [value("multiLevelType", "singleLevel")]
			Multilevel => [value("multiLevelType", "multilevel")]
			HybridMultilevel => [value("multiLevelType", "hybridMultilevel")]
			Unset => []
		},
		match definition.style {
			Style(style) => [value("styleLink", style)]
			Unset => []
		},
		match definition.uses_style {
			Style(style) => [value("numStyleLink", style)]
			Unset => []
		},
		levels.nodes,
	])
	{ node: element("abstractNum", List.prepend(definition.preserved_attributes, attribute("abstractNumId", id.to_str())), ordered(definition_order, typed, definition.preserved)), state: levels.state }
}

# A numbering instance as a `w:num`, each override a `w:lvlOverride`.
instance_node : U32, Numbering.Instance, State -> Written
instance_node = |id, instance, state| {
	Definition(definition) = instance.definition
	overrides = instance.overrides.fold(
		{ nodes: List.with_capacity(instance.overrides.len()), state },
		|out, override| {
			start = match override.start {
				Start(number) => [value("startOverride", number.to_str())]
				Unset => []
			}
			replacement = match override.replacement {
				Replaced(level) => {
					written = level_node({ ..level, level: override.level }, out.state)
					{ nodes: [written.node], state: written.state }
				}

				Unset => { nodes: [], state: out.state }
			}
			{ nodes: List.append(out.nodes, element("lvlOverride", [attribute("ilvl", override.level.to_str())], List.concat(start, replacement.nodes))), state: replacement.state }
		},
	)
	typed = List.prepend(overrides.nodes, value("abstractNumId", definition.to_str()))
	{ node: element("num", List.prepend(instance.preserved_attributes, attribute("numId", id.to_str())), ordered(instance_order, typed, instance.preserved)), state: overrides.state }
}

core_properties_tree : Document.CoreProperties -> XmlTree.Node
core_properties_tree = |properties| {
	text = |namespace, local, given|
		match given {
			Text(content) => [in_namespace(namespace, local, [], [Text(content)])]
			Unset => []
		}
	date = |local, given|
		match given {
			Date(written) => [in_namespace(dc_terms, local, [{ name: { namespace: Uri(schema_instance), local: "type", prefix: Prefix("xsi") }, value: "dcterms:W3CDTF" }], [Text(written)])]
			Unset => []
		}
	children = List.join([
		text(dublin_core, "title", properties.title),
		text(dublin_core, "subject", properties.subject),
		text(dublin_core, "creator", properties.creator),
		text(core_namespace, "keywords", properties.keywords),
		text(dublin_core, "description", properties.description),
		text(core_namespace, "lastModifiedBy", properties.last_modified_by),
		match properties.revision {
			Number(number) => [in_namespace(core_namespace, "revision", [], [Text(number.to_str())])]
			Unset => []
		},
		date("created", properties.created),
		date("modified", properties.modified),
		properties.preserved,
	])
	Element({ name: { namespace: Uri(core_namespace), local: "coreProperties", prefix: Prefix("cp") }, bindings: [{ prefix: Prefix("dcterms"), namespace: Uri(dc_terms) }, { prefix: Prefix("xsi"), namespace: Uri(schema_instance) }], attributes: [], children })
}

# The state of writing a part that holds no body: no relationships, notes,
# comments or bookmarks, and identifiers from 0 up.
blank_state : State
blank_state = { relationships: [], footnotes: [], endnotes: [], comments: [], bookmarks: Dict.empty(), kept_bookmarks: Dict.empty(), started: Set.empty(), used: Set.empty(), next: 0, move_sources: Dict.empty(), move_destinations: Dict.empty(), deleted: Bool.False }

# A style's, level's or the defaults' paragraph properties as a `w:pPr`,
# with the tracked change of them, or nothing where they state nothing.
paragraph_properties_node : Document.ParagraphProperties, State -> Out
paragraph_properties_node = |properties, state| {
	changed = property_change("pPrChange", "pPr", properties.change, |previous| ordered(paragraph_order, paragraph_properties(previous), previous.preserved), state)
	nodes = ordered(paragraph_order, followed_by(paragraph_properties(properties), changed.nodes), properties.preserved)
	{ nodes: if (nodes.is_empty()) [] else [element("pPr", [], nodes)], state: changed.state }
}

# A style's, level's or the defaults' run properties as a `w:rPr`, as
# [paragraph_properties_node] writes paragraph properties.
run_properties_node : Document.RunProperties, State -> Out
run_properties_node = |properties, state| {
	changed = property_change("rPrChange", "rPr", properties.change, |previous| ordered(run_order, run_properties(previous), previous.preserved), state)
	nodes = ordered(run_order, followed_by(run_properties(properties), changed.nodes), properties.preserved)
	{ nodes: if (nodes.is_empty()) [] else [element("rPr", [], nodes)], state: changed.state }
}

# A list level as a `w:lvl`.
level_node : Numbering.Level, State -> Written
level_node = |level, state| {
	paragraph_written = paragraph_properties_node(level.paragraph, state)
	run_written = run_properties_node(level.run, paragraph_written.state)
	typed = List.join([
		match level.start {
			Start(number) => [value("start", number.to_str())]
			Unset => []
		},
		match level.format {
			Bullet => [value("numFmt", "bullet")]
			NoNumber => [value("numFmt", "none")]
			Number(format) => [value("numFmt", format)]
			Unset => []
		},
		match level.paragraph_style {
			Style(style) => [value("pStyle", style)]
			Unset => []
		},
		match level.text {
			Text(shown) => [value("lvlText", shown)]
			Unset => []
		},
		match level.alignment {
			Aligned(alignment) => [value("lvlJc", alignment_name(alignment))]
			Unset => []
		},
		paragraph_written.nodes,
		run_written.nodes,
	])
	{ node: element("lvl", List.prepend(level.preserved_attributes, attribute("ilvl", level.level.to_str())), ordered(level_order, typed, level.preserved)), state: run_written.state }
}

# What a level keeps as it was read, whose identifiers a written change of
# its properties avoids.
kept_in_level : Numbering.Level -> List(XmlTree.Node)
kept_in_level = |level| List.join([level.preserved, level.paragraph.preserved, level.run.preserved])

# The level an override replaces the definition's with, where it has one.
replaced : Numbering.Override -> Try(Numbering.Level, [NotReplaced])
replaced = |override|
	match override.replacement {
		Replaced(level) => Ok(level)
		Unset => Err(NotReplaced)
	}

# An element in a package-level namespace, written with its fixed prefix.
in_namespace : Str, Str, List(XmlTree.Attribute), List(XmlTree.Node) -> XmlTree.Node
in_namespace = |namespace, local, attributes, children| Element({ name: { namespace: Uri(namespace), local, prefix: Unprefixed }, bindings: [], attributes, children })

style_order : List(Str)
style_order = ["name", "aliases", "basedOn", "next", "link", "autoRedefine", "hidden", "uiPriority", "semiHidden", "unhideWhenUsed", "qFormat", "locked", "personal", "personalCompose", "personalReply", "rsid", "pPr", "rPr", "tblPr", "trPr", "tcPr", "tblStylePr"]

definition_order : List(Str)
definition_order = ["nsid", "multiLevelType", "tmpl", "name", "styleLink", "numStyleLink", "lvl"]

level_order : List(Str)
level_order = ["start", "numFmt", "lvlRestart", "pStyle", "isLgl", "suff", "lvlText", "lvlPicBulletId", "legacy", "lvlJc", "pPr", "rPr"]

instance_order : List(Str)
instance_order = ["abstractNumId", "lvlOverride"]

core_namespace : Str
core_namespace = "http://schemas.openxmlformats.org/package/2006/metadata/core-properties"

dublin_core : Str
dublin_core = "http://purl.org/dc/elements/1.1/"

dc_terms : Str
dc_terms = "http://purl.org/dc/terms/"

schema_instance : Str
schema_instance = "http://www.w3.org/2001/XMLSchema-instance"

# A main document part with no body.
shell : XmlTree.Node
shell = XmlTree.parse("<w:document xmlns:w='${wordprocessingml}'/>".to_utf8(), {}) ?? Text("")

no_context : WmlWrite.Context
no_context = { relationships: [], footnotes: [], endnotes: [], comments: [] }

# The written part's text after its root's start tag, or what went wrong.
written : List(Document.Block), WmlWrite.Context -> Str
written = |content, context|
	match WmlWrite.document(shell, content, context) {
		Ok({ tree, relationships: _, next: _ }) =>
			match XmlTree.render(tree) {
				Ok(bytes) =>
					match (Str.from_utf8(bytes) ?? "").split_first("<w:body") {
						Ok({ before: _, after }) => "<w:body${after}"
						Err(_) => "no body"
					}

				Err(_) => "unrenderable"
			}

		Err(MissingNote(_)) => "missing note"
		Err(MissingComment(_)) => "missing comment"
		Err(CommentWithoutParagraph(_)) => "comment without paragraph"
	}

run : List(Document.RunContent) -> Document.Inline
run = |content| Run({ properties: Document.no_run_properties, content })

paragraph : List(Document.Inline) -> Document.Block
paragraph = |content| Paragraph({ properties: Document.no_paragraph_properties, content })

## Properties are written in the schema's order whatever order the model
## lists kept ones in, on as the element alone and off with `w:val="0"`,
## borders edge by edge in the schema's order, and text keeps its whitespace
## only where reading would take it as layout.
expect {
	kept = XmlTree.parse("<w:pPr xmlns:w='${wordprocessingml}'><w:rPr><w:b/></w:rPr><w:suppressAutoHyphens/></w:pPr>".to_utf8(), {}) ?? Text("")
	preserved = match kept {
		Element(found) => found.children
		Text(_) => []
	}
	border = |edge| { edge, line: "single", size: Eighths(4), space: Unset, color: Auto }
	properties = { ..Document.no_paragraph_properties, style: Style("Body"), alignment: Aligned(Both), keep_next: On, widow_control: Off, borders: [border(Bottom), border(Top)], preserved }
	content = [Run({ properties: { ..Document.no_run_properties, italic: On, bold: Off, size: HalfPoints(24) }, content: [Text("a b"), Text(" lead"), Text("tab\there"), Tab] })]
	expected_properties = "<w:pPr><w:pStyle w:val=\"Body\"/><w:keepNext/><w:widowControl w:val=\"0\"/><w:pBdr><w:top w:val=\"single\" w:color=\"auto\" w:sz=\"4\"/><w:bottom w:val=\"single\" w:color=\"auto\" w:sz=\"4\"/></w:pBdr><w:suppressAutoHyphens/><w:jc w:val=\"both\"/><w:rPr><w:b/></w:rPr></w:pPr>"
	expected_run = "<w:r><w:rPr><w:b w:val=\"0\"/><w:i/><w:sz w:val=\"24\"/></w:rPr><w:t>a b</w:t><w:t xml:space=\"preserve\"> lead</w:t><w:t xml:space=\"preserve\">tab\there</w:t><w:tab/></w:r>"
	written([Paragraph({ properties, content })], no_context) == "<w:body><w:p>${expected_properties}${expected_run}</w:p></w:body></w:document>"
}

## A section after a paragraph is written in its properties, the body's
## last is the body's own, and one in a table cell stands where it is.
expect {
	section = { start: NextPage, page_size: Unset, margins: Unset, columns: Equal({ count: 2, space: 720, separator: Line }), page_numbers: Unset, title_page: Unset, headers: [], footers: [], preserved: [], change: [] }
	cell = Cell({ properties: { width: Twips(2000), span: Unset, merge: Continue, borders: [], shading: Unset, alignment: Unset, preserved: [], revision: Unset, change: [] }, content: [paragraph([]), Section(section)] })
	table = Table({ properties: { style: Unset, width: Unset, borders: [], shading: Unset, preserved: [], change: [] }, grid: [Column(2000)], content: [Row({ properties: { header: On, grid_before: Unset, grid_after: Unset, preserved: [], inserted: Unset, deleted: Unset, change: [] }, content: [cell] })] })
	ended = "<w:sectPr><w:type w:val=\"nextPage\"/><w:cols w:num=\"2\" w:sep=\"1\"/></w:sectPr>"
	expected_table = "<w:tbl><w:tblPr/><w:tblGrid><w:gridCol w:w=\"2000\"/></w:tblGrid><w:tr><w:trPr><w:tblHeader/></w:trPr><w:tc><w:tcPr><w:tcW w:w=\"2000\" w:type=\"dxa\"/><w:vMerge/></w:tcPr><w:p/>${ended}</w:tc></w:tr></w:tbl>"
	written([paragraph([]), Section(section), table, paragraph([]), Section(section)], no_context)
		== "<w:body><w:p><w:pPr>${ended}</w:pPr></w:p>${expected_table}<w:p/>${ended}</w:body></w:document>"
}

## Bookmarks take the lowest identifiers kept content and comments do not
## use, an end its start's; a hyperlink reuses the part's relationship to its
## address and adds one for a new address; note and comment references take
## their note's and comment's identifiers, and one naming a missing note
## cannot be written.
expect {
	comment = XmlTree.parse("<w:commentRangeStart xmlns:w='${wordprocessingml}' w:id='0'/>".to_utf8(), {}) ?? Text("")
	links = [{ id: "rId1", kind: hyperlink_relationship, target: "https://example.org/a", mode: External }]
	context : WmlWrite.Context
	context = { relationships: links, footnotes: ["-1", "0", "7"], endnotes: [], comments: ["3"] }
	content = [
		paragraph([
			Preserved(comment),
			BookmarkEnd("later"),
			BookmarkStart("first"),
			Hyperlink({ target: External("https://example.org/a"), preserved: [], content: [] }),
			Hyperlink({ target: ExternalAt({ url: "https://example.org/b", location: "x" }), preserved: [], content: [] }),
			BookmarkEnd("first"),
			BookmarkStart("later"),
			run([NoteReference({ kind: Footnote, note: 2 }), CommentReference(0)]),
		]),
	]
	text = written(content, context)
	relationships = WmlWrite.document(shell, content, context).map_ok(|out| out.relationships.map(|relationship| (relationship.id, relationship.target)))
	expected = "<w:body><w:p><w:commentRangeStart w:id=\"0\"/><w:bookmarkEnd w:id=\"2\"/><w:bookmarkStart w:id=\"1\" w:name=\"first\"/><w:hyperlink r:id=\"rId1\"/><w:hyperlink r:id=\"rId2\" w:anchor=\"x\"/><w:bookmarkEnd w:id=\"1\"/><w:bookmarkStart w:id=\"2\" w:name=\"later\"/><w:r><w:footnoteReference w:id=\"7\"/><w:commentReference w:id=\"3\"/></w:r></w:p></w:body></w:document>"
	text == expected
		and relationships == Ok([("rId1", "https://example.org/a"), ("rId2", "https://example.org/b")])
		and written([paragraph([run([NoteReference({ kind: Endnote, note: 0 })])])], context) == "missing note"
}

## Tracked changes and moves' ranges take the lowest identifiers left after
## the bookmarks', in the order they are written, a range's end its start's;
## a change keeps its date as written and its other attributes, and deleted
## text and field code are written as deleted inside a deletion only.
expect {
	stamp = Date({ written: "2026-05-07T09:00:00Z", utc_seconds: 1778144400 })
	change = |kind, content| Revision({ kind, author: "Ada", date: stamp, content, preserved: [] })
	content = [
		paragraph([
			BookmarkStart("b"),
			MoveStart({ side: Source, name: "m", author: "Ada", date: { written: "2026-05-07T09:00:00Z", utc_seconds: 1778144400 }, preserved: [] }),
			change(MoveSource, [run([Text("away")])]),
			MoveEnd({ side: Source, name: "m" }),
			change(Deletion, [run([FieldCode(" PAGE "), Text("old")]), change(Insertion, [run([Text("x")])])]),
			Revision({ kind: Insertion, author: "Lin", date: Unset, content: [run([Text("new")])], preserved: [] }),
			BookmarkEnd("b"),
		]),
	]
	moved = "<w:moveFromRangeStart w:id=\"1\" w:name=\"m\" w:author=\"Ada\" w:date=\"2026-05-07T09:00:00Z\"/><w:moveFrom w:id=\"2\" w:author=\"Ada\" w:date=\"2026-05-07T09:00:00Z\"><w:r><w:t>away</w:t></w:r></w:moveFrom><w:moveFromRangeEnd w:id=\"1\"/>"
	deleted = "<w:del w:id=\"3\" w:author=\"Ada\" w:date=\"2026-05-07T09:00:00Z\"><w:r><w:delInstrText xml:space=\"preserve\"> PAGE </w:delInstrText><w:delText>old</w:delText></w:r><w:ins w:id=\"4\" w:author=\"Ada\" w:date=\"2026-05-07T09:00:00Z\"><w:r><w:delText>x</w:delText></w:r></w:ins></w:del>"
	inserted = "<w:ins w:id=\"5\" w:author=\"Lin\"><w:r><w:t>new</w:t></w:r></w:ins>"
	written(content, no_context) == "<w:body><w:p><w:bookmarkStart w:id=\"0\" w:name=\"b\"/>${moved}${deleted}${inserted}<w:bookmarkEnd w:id=\"0\"/></w:p></w:body></w:document>"
}

## A change that covers a hyperlink is written around the content beside it
## and inside the hyperlink, where the schema allows a change, a change it
## holds distributed first; a change of an empty hyperlink stays inside it.
expect {
	change = |kind, content| Revision({ kind, author: "Ada", date: Unset, content, preserved: [] })
	link = |content| Hyperlink({ target: Internal("b"), preserved: [], content })
	content = [paragraph([change(Deletion, [run([Text("a")]), change(Insertion, [link([run([Text("l")])])])]), change(Insertion, [link([])])])]
	deleted = "<w:del w:id=\"0\" w:author=\"Ada\"><w:r><w:delText>a</w:delText></w:r></w:del><w:hyperlink w:anchor=\"b\"><w:del w:id=\"1\" w:author=\"Ada\"><w:ins w:id=\"2\" w:author=\"Ada\"><w:r><w:delText>l</w:delText></w:r></w:ins></w:del></w:hyperlink>"
	inserted = "<w:hyperlink w:anchor=\"b\"><w:ins w:id=\"3\" w:author=\"Ada\"/></w:hyperlink>"
	written(content, no_context) == "<w:body><w:p>${deleted}${inserted}</w:p></w:body></w:document>"
}

## A paragraph mark's changes are written first in its kept character
## properties, or in their own; a change of properties holds the properties
## before it, without their own mark; rows' and cells' changes are written in
## their properties' order; and every change takes the lowest identifier
## left in the order it is written.
expect {
	by = |author| { author, date: Unset, preserved: [] }
	stamp = Date({ written: "2026-05-07T09:00:00Z", utc_seconds: 1778144400 })
	kept_mark = XmlTree.parse("<w:rPr xmlns:w='${wordprocessingml}'><w:b/></w:rPr>".to_utf8(), {}) ?? Text("")
	before_paragraph = { ..Document.paragraph_properties_with(Unset), alignment: Aligned(Left), mark: [{ kind: Insertion, author: "X", date: Unset, preserved: [] }] }
	marked = { ..Document.no_paragraph_properties, preserved: [kept_mark], mark: [{ kind: Deletion, author: "B", date: Unset, preserved: [] }, { kind: Insertion, author: "A", date: stamp, preserved: [] }], change: [{ author: "C", date: Unset, preserved: [], previous: before_paragraph }] }
	formatted = Run({ properties: { ..Document.no_run_properties, italic: On, change: [{ author: "D", date: Unset, preserved: [], previous: { ..Document.run_properties_with(Unset), bold: On } }] }, content: [Text("x")] })
	moved_here = { ..Document.no_paragraph_properties, mark: [{ kind: MoveDestination, author: "E", date: Unset, preserved: [] }] }
	plain_cell = |change| { width: Unset, span: Unset, merge: Unset, borders: [], shading: Unset, alignment: Unset, preserved: [], revision: Unset, change }
	cell = |properties| Cell({ properties, content: [paragraph([])] })
	plain_row = |change| { header: Unset, grid_before: Unset, grid_after: Unset, preserved: [], inserted: Unset, deleted: Unset, change }
	row_properties_written = { ..plain_row([{ author: "H", date: Unset, preserved: [], previous: { ..plain_row(Unset), header: On } }]), inserted: Tracked(by("F")), deleted: Tracked(by("G")) }
	cells = [cell({ ..plain_cell([{ author: "J", date: Unset, preserved: [], previous: { ..plain_cell(Unset), width: Auto } }]), revision: Merged({ author: "I", date: Unset, preserved: [], merge: Continue, previous: Unset }) }), cell({ ..plain_cell([]), revision: Inserted(by("K")) })]
	plain_table = |change| { style: Unset, width: Unset, borders: [], shading: Unset, preserved: [], change }
	table = Table({ properties: plain_table([{ author: "L", date: Unset, preserved: [], previous: { ..plain_table(Unset), style: Style("Grid") } }]), grid: [], content: [Row({ properties: row_properties_written, content: cells })] })
	plain_section = |change| { start: Unset, page_size: Unset, margins: Unset, columns: Unset, page_numbers: Unset, title_page: Unset, headers: [], footers: [], preserved: [], change }
	ending = plain_section([{ author: "M", date: Unset, preserved: [], previous: { ..plain_section(Unset), start: Continuous } }])
	content = [Paragraph({ properties: marked, content: [formatted] }), Paragraph({ properties: moved_here, content: [] }), table, Section(ending)]
	first = "<w:p><w:pPr><w:rPr><w:ins w:id=\"0\" w:author=\"A\" w:date=\"2026-05-07T09:00:00Z\"/><w:del w:id=\"1\" w:author=\"B\"/><w:b/></w:rPr><w:pPrChange w:id=\"2\" w:author=\"C\"><w:pPr><w:jc w:val=\"left\"/></w:pPr></w:pPrChange></w:pPr><w:r><w:rPr><w:i/><w:rPrChange w:id=\"3\" w:author=\"D\"><w:rPr><w:b/></w:rPr></w:rPrChange></w:rPr><w:t>x</w:t></w:r></w:p>"
	second = "<w:p><w:pPr><w:rPr><w:moveTo w:id=\"4\" w:author=\"E\"/></w:rPr></w:pPr></w:p>"
	table_properties_written = "<w:tblPr><w:tblPrChange w:id=\"5\" w:author=\"L\"><w:tblPr><w:tblStyle w:val=\"Grid\"/></w:tblPr></w:tblPrChange></w:tblPr><w:tblGrid/>"
	row_written = "<w:trPr><w:ins w:id=\"6\" w:author=\"F\"/><w:del w:id=\"7\" w:author=\"G\"/><w:trPrChange w:id=\"8\" w:author=\"H\"><w:trPr><w:tblHeader/></w:trPr></w:trPrChange></w:trPr>"
	merged = "<w:tc><w:tcPr><w:cellMerge w:id=\"9\" w:author=\"I\" w:vMerge=\"cont\"/><w:tcPrChange w:id=\"10\" w:author=\"J\"><w:tcPr><w:tcW w:w=\"0\" w:type=\"auto\"/></w:tcPr></w:tcPrChange></w:tcPr><w:p/></w:tc>"
	inserted = "<w:tc><w:tcPr><w:cellIns w:id=\"11\" w:author=\"K\"/></w:tcPr><w:p/></w:tc>"
	section_written = "<w:sectPr><w:sectPrChange w:id=\"12\" w:author=\"M\"><w:sectPr><w:type w:val=\"continuous\"/></w:sectPr></w:sectPrChange></w:sectPr>"
	written(content, no_context) == "<w:body>${first}${second}<w:tbl>${table_properties_written}<w:tr>${row_written}${merged}${inserted}</w:tr></w:tbl>${section_written}</w:body></w:document>"
}

## A part whose root is not a WordprocessingML document is not a main
## document and is written as it is.
expect {
	other = XmlTree.parse("<w:styles xmlns:w='${wordprocessingml}'/>".to_utf8(), {}) ?? Text("")
	WmlWrite.document(other, [paragraph([])], no_context) == Ok({ tree: other, relationships: [], next: 0 })
}

## Notes take the place, identifier and attributes of the shell's note at
## their place, with their kind and content from the model: a note beyond
## the shell's takes the lowest identifier no note uses, and a shell's note
## beyond the model's is not written. A header's content is its blocks.
expect {
	notes_shell = XmlTree.parse("<w:footnotes xmlns:w='${wordprocessingml}'><w:footnote w:type='normal' w:id='0'/><w:footnote w:id='1' w:type='separator'/></w:footnotes>".to_utf8(), {}) ?? Text("")
	notes = [{ kind: Separator, content: [paragraph([])] }, { kind: Note, content: [paragraph([run([Text("a")])])] }, { kind: ContinuationNotice, content: [] }]
	header_shell = XmlTree.parse("<w:hdr xmlns:w='${wordprocessingml}'><w:p/></w:hdr>".to_utf8(), {}) ?? Text("")
	rendered = |result|
		match result {
			Ok({ tree, relationships: _, next: _ }) => Str.from_utf8(XmlTree.render(tree) ?? []) ?? ""
			Err(_) => "not written"
		}
	rendered(WmlWrite.notes(notes_shell, notes, no_context)).ends_with("<w:footnotes xmlns:w=\"${wordprocessingml}\"><w:footnote w:type=\"separator\" w:id=\"0\"><w:p/></w:footnote><w:footnote w:id=\"1\"><w:p><w:r><w:t>a</w:t></w:r></w:p></w:footnote><w:footnote w:id=\"2\" w:type=\"continuationNotice\"/></w:footnotes>")
		and rendered(WmlWrite.notes(notes_shell, notes.take_first(1), no_context)).ends_with("<w:footnote w:type=\"separator\" w:id=\"0\"><w:p/></w:footnote></w:footnotes>")
		and rendered(WmlWrite.header_footer(header_shell, [paragraph([run([Tab])]), paragraph([])], no_context)).ends_with("<w:hdr xmlns:w=\"${wordprocessingml}\"><w:p><w:r><w:tab/></w:r></w:p><w:p/></w:hdr>")
}

## Comments take the lowest identifiers no kept content uses and the body's
## bookmarks the next; in the comments part, bookmarks avoid every identifier
## the other parts and the comments use, and each comment's last paragraph,
## inside a table too, takes the lowest paragraph identifier no other part
## uses, a comment without a paragraph none; a reply without a paragraph
## cannot be written.
expect {
	kept = XmlTree.parse("<w:ins xmlns:w='${wordprocessingml}' w:id='0'/>".to_utf8(), {}) ?? Text("")
	identified = XmlTree.parse("<w:p xmlns:w='${wordprocessingml}' xmlns:w14='${word_2010}' w14:paraId='00000001'/>".to_utf8(), {}) ?? Text("")
	comment = |content| { author: "Ada Reviewer", initials: Initials("AR"), date: Unset, content, preserved: [], parent: Unset, resolved: Bool.False, durable_id: Unset, utc_date: Unset }
	cell = Cell({ properties: { width: Unset, span: Unset, merge: Unset, borders: [], shading: Unset, alignment: Unset, preserved: [], revision: Unset, change: [] }, content: [paragraph([run([Text("in")])])] })
	table = Table({ properties: { style: Unset, width: Unset, borders: [], shading: Unset, preserved: [], change: [] }, grid: [], content: [Row({ properties: { header: Unset, grid_before: Unset, grid_after: Unset, preserved: [], inserted: Unset, deleted: Unset, change: [] }, content: [cell] })] })
	listed = [comment([paragraph([BookmarkStart("b"), BookmarkEnd("b"), run([Text("one")])]), paragraph([run([Text("two")])])]), comment([table]), comment([])]
	body = [paragraph([Preserved(kept), CommentStart(0), BookmarkStart("a"), BookmarkEnd("a"), CommentEnd(0), run([CommentReference(0)])])]
	ids = WmlWrite.comment_ids(listed.fold(WmlWrite.kept_ids(Set.with_capacity(8), body), |found, one| WmlWrite.kept_ids(found, one.content)), listed)
	context : WmlWrite.Context
	context = { relationships: [], footnotes: [], endnotes: [], comments: ids }
	main = WmlWrite.document(shell, body, context)?
	part = WmlWrite.comments(Text(""), listed, context, WmlWrite.taken([main.tree, identified]))?
	rendered = Str.from_utf8(XmlTree.render(part.tree)?) ?? ""
	comments = match rendered.split_first("<w:comment ") {
		Ok({ before: _, after }) => "<w:comment ${after}"
		Err(_) => rendered
	}
	start = |id| "<w:comment w:id=\"${id}\" w:author=\"Ada Reviewer\" w:initials=\"AR\">"
	first = "${start("1")}<w:p><w:bookmarkStart w:id=\"5\" w:name=\"b\"/><w:bookmarkEnd w:id=\"5\"/><w:r><w:t>one</w:t></w:r></w:p><w:p w14:paraId=\"00000002\"><w:r><w:t>two</w:t></w:r></w:p></w:comment>"
	second = "${start("2")}<w:tbl><w:tblPr/><w:tblGrid/><w:tr><w:tc><w:p w14:paraId=\"00000003\"><w:r><w:t>in</w:t></w:r></w:p></w:tc></w:tr></w:tbl></w:comment>"
	third = "<w:comment w:id=\"3\" w:author=\"Ada Reviewer\" w:initials=\"AR\"/>"
	ids == ["1", "2", "3"]
		and written(body, context) == "<w:body><w:p><w:ins w:id=\"0\"/><w:commentRangeStart w:id=\"1\"/><w:bookmarkStart w:id=\"4\" w:name=\"a\"/><w:bookmarkEnd w:id=\"4\"/><w:commentRangeEnd w:id=\"1\"/><w:r><w:commentReference w:id=\"1\"/></w:r></w:p></w:body></w:document>"
		and part.paragraphs == ["00000002", "00000003", ""]
		and comments == "${first}${second}${third}</w:comments>"
		and WmlWrite.comments(Text(""), [comment([paragraph([])]), { ..comment([]), parent: Parent(0) }], { relationships: [], footnotes: [], endnotes: [], comments: ["0", "1"] }, WmlWrite.taken([])).map_ok(|_| {}) == Err(CommentWithoutParagraph(1))
}

## A part written as one of a document's takes its bookmarks' and tracked
## changes' identifiers from the context's `from` up, avoiding the
## comments' and those the context reserves, and gives the number after the
## last it took as `next`; the identifiers kept content uses are reserved.
expect {
	kept = XmlTree.parse("<w:permStart xmlns:w='${wordprocessingml}' w:id='4'/>".to_utf8(), {}) ?? Text("")
	content = [paragraph([BookmarkStart("b"), BookmarkEnd("b"), Revision({ kind: Insertion, author: "Ada", date: Unset, content: [run([Text("x")])], preserved: [] })])]
	context : WmlWrite.Context
	context = { relationships: [], footnotes: [], endnotes: [], comments: ["3"], reserved: WmlWrite.kept_ids(Set.with_capacity(1), [paragraph([Preserved(kept)])]), from: 2 }
	written(content, context) == "<w:body><w:p><w:bookmarkStart w:id=\"2\" w:name=\"b\"/><w:bookmarkEnd w:id=\"2\"/><w:ins w:id=\"5\" w:author=\"Ada\"><w:r><w:t>x</w:t></w:r></w:ins></w:p></w:body></w:document>"
		and WmlWrite.document(shell, content, context).map_ok(|out| out.next) == Ok(6)
		and WmlWrite.header_footer(XmlTree.parse("<w:hdr xmlns:w='${wordprocessingml}'/>".to_utf8(), {}) ?? Text(""), content, { ..context, from: 6 }).map_ok(|out| out.next) == Ok(8)
}

## Turning tracking on puts `w:trackRevisions` after the settings the schema
## puts before it and before the rest, replacing one there was; turning it
## off removes it; a document without settings gets settings that track.
expect {
	settings = |inner| XmlTree.parse("<w:settings xmlns:w='${wordprocessingml}'>${inner}</w:settings>".to_utf8(), {}) ?? Text("")
	rendered = |tree| Str.from_utf8(XmlTree.render(tree) ?? []) ?? ""
	open = "<w:settings xmlns:w=\"${wordprocessingml}\">"
	rendered(WmlWrite.tracking(settings("<w:zoom w:percent='100'/><w:trackRevisions w:val='false'/><w:defaultTabStop w:val='720'/>"), On)).ends_with("${open}<w:zoom w:percent=\"100\"/><w:trackRevisions/><w:defaultTabStop w:val=\"720\"/></w:settings>")
		and rendered(WmlWrite.tracking(settings("<w:defaultTabStop w:val='720'/>"), On)).ends_with("${open}<w:trackRevisions/><w:defaultTabStop w:val=\"720\"/></w:settings>")
		and rendered(WmlWrite.tracking(settings("<w:trackRevisions/><w:defaultTabStop w:val='720'/>"), Off)).ends_with("${open}<w:defaultTabStop w:val=\"720\"/></w:settings>")
		and rendered(WmlWrite.tracking(Text(""), On)).ends_with("${open}<w:trackRevisions/></w:settings>")
}

## Different odd and even pages put `w:evenAndOddHeaders` after the
## settings the schema puts before it, such as the default tab stop, and
## before the rest, such as compatibility settings; turning them off
## removes it.
expect {
	settings = |inner| XmlTree.parse("<w:settings xmlns:w='${wordprocessingml}'>${inner}</w:settings>".to_utf8(), {}) ?? Text("")
	rendered = |tree| Str.from_utf8(XmlTree.render(tree) ?? []) ?? ""
	open = "<w:settings xmlns:w=\"${wordprocessingml}\">"
	on = WmlWrite.different_odd_and_even(settings("<w:trackRevisions/><w:defaultTabStop w:val='720'/><w:evenAndOddHeaders w:val='0'/><w:compat/>"), On)
	rendered(on).ends_with("${open}<w:trackRevisions/><w:defaultTabStop w:val=\"720\"/><w:evenAndOddHeaders/><w:compat/></w:settings>")
		and rendered(WmlWrite.different_odd_and_even(on, Off)).ends_with("${open}<w:trackRevisions/><w:defaultTabStop w:val=\"720\"/><w:compat/></w:settings>")
		and rendered(WmlWrite.different_odd_and_even(settings("<w:compat/>"), On)).ends_with("${open}<w:evenAndOddHeaders/><w:compat/></w:settings>")
}
