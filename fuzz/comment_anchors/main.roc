app [target] {
	docx: "../../package/main.roc",
	fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.0/6uc3YKGydgEnS2nrCimSYWDNfT6drYcgU52VAwqrb6DS.tar.zst",
}

import fuzz.Fuzz
import docx.Comments
import docx.Docx
import docx.Document
import docx.Mce
import docx.Opc
import docx.WmlRead
import docx.WmlWrite
import docx.XmlTree

## Generated comment threads write and read back as the same threads, with
## every range balanced and every identifier unique.
##
## A program of bytes describes a body and its comments: comments whose
## ranges start in a paragraph or between blocks and end later, comments
## shown at a point, comments the body does not anchor, replies to earlier
## comments, resolved comments, durable identifiers and UTC dates, comment
## content of one or two paragraphs, a bookmark or a table, bookmarks in the
## body, tracked insertions, and kept permission ranges whose identifiers
## the allocated ones must avoid; and a header and a footnote, each of
## paragraphs holding a comment's range and reference around a bookmark and
## a tracked insertion after a kept permission range. The body is written by
## `WmlWrite.document` with the identifiers `WmlWrite.comment_ids` allocates
## avoiding those `WmlWrite.kept_ids` finds in every part, the footnote by
## `WmlWrite.notes` and the header by `WmlWrite.header_footer`, each taking
## its numbers after the part before it, the comments part by
## `WmlWrite.comments`, the extended comments, comment identifiers and
## extensible comments parts by `Comments.split` and the people part by
## `Comments.people_part`, each with its content type and its relationship
## from the main document. `Docx.parse` must read back the body, header,
## footnote and the comments, threads, anchors and people as they were
## written, with no entry left unapplied; across the written parts every
## range that starts ends, and the comments', bookmarks' and tracked
## changes' identifiers and the comments' paragraph identifiers are unique
## and avoid the kept ones. `Docx.to_bytes` must then give the same bytes
## twice, with its identifiers unique across its parts as well, and bytes
## that read back as an equivalent document that writes the same bytes
## again.
##
## For a program of at most 1,024 bytes, the document read back, or for a
## program of odd length the same document packaged without the parts beside
## the comments part, as pandoc writes one, is then edited: `Docx.add_comment` over a span of its text,
## `Docx.reply` to a comment, `Docx.resolve` of a thread and
## `Docx.remove_comment`, each chosen by the program's first bytes. No edit
## changes the text; the added comment is anchored to its span, the reply
## replies to its parent with its parent's anchor, resolving resolves exactly
## the thread, and removing removes exactly the comment and its replies; and
## every edited document writes with its ranges balanced and its identifiers
## unique across the body, header, footnotes and comments, and reads back
## as the same comments.
##
## Allocation ratchets, which only ever move down: `WmlWrite.comments`,
## `Comments.split` with `Comments.people_part`, `Docx.comments`, which joins
## the comments with the body and their threads, and each of the four edits
## allocate at most linearly in the trees' nodes and attributes and keep at
## most linearly many bytes live, and each declared example allocates no
## more than it did when its ceiling was set. Two pairs bound growth: the
## threads above, sixteen times as many in the large document as in the
## small one, and many short comments, 256 against 16, each a range over a
## few words with a reply. Running a large example runs its small one again
## and fails if any region allocates more than sixteen times as often, or
## requests or holds live more than eighteen times as many bytes, as
## `byte_ratio` explains. A fifth example, the small threads with comments
## in a header and a footnote, runs the identifiers' law across parts in
## every smoke run. Raising a ceiling needs a cause recorded in the pull
## request.
test! : List(U8) => Fuzz.Outcome
test! = |program| {
	costs = round_trip!(program)
	match exact_ceilings(program) {
		Ok(ceilings) =>
			for (region, ceiling) in ceilings {
				match costs.find_first(|(name, _)| name == region) {
					Ok((_, stats)) =>
						if stats.allocs + stats.reallocs > ceiling {
							crash "a declared document allocated more than its ceiling in ${region}"
						}

					Err(_) => crash "a declared document did not measure ${region}"
				}
			}

		Err(NotDeclared) => {}
	}
	match small_of(program) {
		Ok(small_program) => {
			small = round_trip!(small_program)
			for (region, stats) in costs {
				match small.find_first(|(name, _)| name == region) {
					Ok((_, base)) =>
						if stats.allocs + stats.reallocs > 16 * (base.allocs + base.reallocs) or stats.requested_bytes > byte_ratio * base.requested_bytes or held(stats) > byte_ratio * held(base) {
							crash "a large document cost more than its small one allows in ${region}"
						}

					Err(_) => crash "a small document did not measure ${region}"
				}
			}
		}

		Err(NotAPair) => {}
	}
	Fuzz.keep
}

generator : Fuzz.Generator(List(U8))
generator = Fuzz.bytes

# The bytes a region held live beyond those live when it began.
held : Fuzz.Stats -> U64
held = |stats| stats.peak_live_bytes - stats.entry_live_bytes

# What a program's regions cost, by region.
Costs : List((Str, Fuzz.Stats))

# Write a program's document, measuring the writing of its comments, and
# check the round trip, measuring the join; then edit it, measuring each
# edit.
round_trip! : List(U8) => Costs
round_trip! = |program| {
	built = build(program)
	kept = List.concat([built.header, built.note], built.comments.map(|comment| comment.content)).fold(WmlWrite.kept_ids(Set.with_capacity(8), built.body), WmlWrite.kept_ids)
	ids = WmlWrite.comment_ids(kept, built.comments)
	context : WmlWrite.Context
	context = { relationships: [], footnotes: [], endnotes: [], comments: ids, reserved: kept }
	main = WmlWrite.document(shell, built.body, context) ?? crash "a generated body did not write"
	notes = WmlWrite.notes(w_element("footnotes", [], []), [{ kind: Note, content: built.note }], { ..context, from: main.next }) ?? crash "a generated footnote did not write"
	header = WmlWrite.header_footer(w_element("hdr", [], []), built.header, { ..context, from: notes.next }) ?? crash "a generated header did not write"
	stories = List.concat(if (built.note.is_empty()) [] else [("/word/footnotes.xml", notes.tree)], if (built.header.is_empty()) [] else [("/word/header1.xml", header.tree)])
	taken = WmlWrite.taken(List.prepend(stories.map(|(_, tree)| tree), main.tree))
	{ value: written, stats: write } = Fuzz.measure!("wml-write-comments", || WmlWrite.comments(Text(""), built.comments, context, taken))
	comments = written ?? crash "generated comments did not write"
	{ value: split, stats: splitting } = Fuzz.measure!(
		"comments-split",
		|| { threads: Comments.split(built.comments, comments.paragraphs, { extended: Text(""), ids: Text(""), extensible: Text("") }, { extended: [], ids: [], extensible: [], diagnostics: [] }), people: Comments.people_part(Text(""), built.people) },
	)
	beside = [split.threads.extended, split.threads.ids, split.threads.extensible, split.people].fold(0, |total, tree| total + size(tree))
	check_linear("writing comments", write, size(comments.tree))
	check_linear("splitting threads", splitting, beside)
	check_identifiers(List.concat([main.tree, comments.tree], stories.map(|(_, tree)| tree)))
	trees = List.concat(
		[
			("/word/document.xml", main.tree),
			("/word/comments.xml", comments.tree),
			("/word/commentsExtended.xml", split.threads.extended),
			("/word/commentsIds.xml", split.threads.ids),
			("/word/commentsExtensible.xml", split.threads.extensible),
			("/word/people.xml", split.people),
		],
		stories,
	)
	nodes = stories.fold(size(main.tree) + size(comments.tree), |total, (_, tree)| total + size(tree))
	bytes = Opc.to_bytes(graph(main.relationships, stories.map(|(name, _)| name)), |name| Bytes(rendered(trees, name))) ?? crash "a written document did not package"
	parsed = Docx.parse(bytes) ?? crash "a written document did not parse"
	if Docx.body(parsed.document) != built.body {
		crash "a written body read back differently"
	}
	if Docx.header_footer(parsed.document, "/word/header1.xml") != built.header or Docx.footnotes(parsed.document).map(|note| note.content) != (if (built.note.is_empty()) [] else [built.note]) {
		crash "a written header or footnote read back differently"
	}
	{ value: joined, stats: join } = Fuzz.measure!("docx-comments", || Docx.comments(parsed.document))
	if joined != { comments: Comments.anchored(built.body, built.comments), diagnostics: [] } {
		crash "written comments read back as different threads or anchors"
	}
	if join.allocs + join.reallocs > join_allocation_ceiling(nodes + beside) {
		crash "joining comments allocated more than linearly in the parts' nodes"
	}
	if held(join) > join_memory_ceiling(nodes + beside) {
		crash "joining comments held more than linearly many bytes live"
	}
	if Docx.people(parsed.document) != { people: built.people, diagnostics: [] } {
		crash "written people read back differently"
	}
	first = Docx.to_bytes(parsed.document) ?? crash "a read document did not write"
	check_identifiers(written_parts(first))
	if Docx.to_bytes(parsed.document) != Ok(first) {
		crash "writing a document twice gave different bytes"
	}
	again = Docx.parse(first) ?? crash "a rewritten document did not parse"
	if !Docx.equivalent(parsed.document, again.document) {
		crash "a rewritten document is not equivalent to the one written"
	}
	if Docx.to_bytes(again.document) != Ok(first) {
		crash "writing a rewritten document gave different bytes"
	}
	measured = [("wml-write-comments", write), ("comments-split", splitting), ("docx-comments", join)]
	if program.len() > edited_program_bytes {
		return measured
	}
	edited = if (program.len() % 2 == 0) parsed.document else without_threads(trees, graph(main.relationships, stories.map(|(name, _)| name)))
	List.concat(measured, operate!(program, edited, nodes))
}

# The longest program whose document is edited. Each edit writes the whole
# document and the checks write and read each edited one again, so a program
# of 1,348 bytes took longer than the smoke run's ten seconds on a loaded
# machine; the large declared program, 832 bytes, is within it.
edited_program_bytes : U64
edited_program_bytes = 1024

# The document packaged with its main document and comments part only, as
# pandoc and LibreOffice write one: without the parts that make threads.
without_threads : List((Str, XmlTree.Node)), Opc.Graph -> Document
without_threads = |trees, full| {
	dropped = ["/word/commentsExtended.xml", "/word/commentsIds.xml", "/word/commentsExtensible.xml", "/word/people.xml"]
	parts = full.parts
		.drop_if(|part| dropped.contains(part.name))
		.map(|part| { ..part, relationships: part.relationships.drop_if(|relationship| dropped.contains(relationship.target)) })
	bytes = Opc.to_bytes({ relationships: full.relationships, parts }, |name| Bytes(rendered(trees, name))) ?? crash "a document without threads did not package"
	(Docx.parse(bytes) ?? crash "a document without threads did not parse").document
}

# Add a comment, reply to one, resolve one and remove one, as the program's
# first bytes choose them, measuring each edit, and check each: the text
# never changes; the new comment is anchored to its span; the reply replies
# to its parent and shares its anchor; the resolved comment's thread is
# resolved and nothing else changes; the removed comment goes with its
# replies and the others stay; and the written document's ranges are
# balanced and its identifiers unique, and it reads back as the same
# comments.
operate! : List(U8), Document, U64 => Costs
operate! = |program, document, nodes| {
	text = Docx.text(document)
	length = text.to_utf8().len()
	choose = |index, range| (program.get(index) ?? 0).to_u64() * 37 % range
	start = choose(1, length)
	end = start + choose(2, length - start + 1)
	new : Str -> Comments.New
	new = |author| { author: author, content: Text("Edited by ${author}") }
	{ value: adding, stats: add } = Fuzz.measure!("docx-add-comment", || Docx.add_comment(document, { start, end }, new("Ada Reviewer")))
	added_to = adding ?? crash "adding a comment failed"
	count = added_to.id + 1
	to = choose(3, count)
	{ value: replying, stats: reply } = Fuzz.measure!("docx-reply", || Docx.reply(added_to.document, to, new("Lin Editor")))
	replied_to = replying ?? crash "replying to a comment failed"
	resolve_at = choose(4, count + 1)
	{ value: resolving, stats: resolve } = Fuzz.measure!("docx-resolve", || Docx.resolve(replied_to.document, resolve_at))
	resolved_document = resolving ?? crash "resolving a comment failed"
	remove_at = choose(5, count + 1)
	{ value: removing, stats: remove } = Fuzz.measure!("docx-remove-comment", || Docx.remove_comment(resolved_document, remove_at))
	removed_document = removing ?? crash "removing a comment failed"
	costs = [("docx-add-comment", add), ("docx-reply", reply), ("docx-resolve", resolve), ("docx-remove-comment", remove)]
	for (region, stats) in costs {
		if stats.allocs + stats.reallocs > edit_allocation_ceiling(nodes) {
			crash "${region} allocated more than linearly in the document's nodes"
		}
		if held(stats) > edit_memory_ceiling(nodes) {
			crash "${region} held more than linearly many bytes live"
		}
	}
	edited = [added_to.document, replied_to.document, resolved_document, removed_document]
	if edited.any(|one| Docx.text(one) != text) {
		crash "a comment operation changed the text"
	}
	before = listed(document)
	added = listed(added_to.document)
	expected = Str.from_utf8(text.to_utf8().sublist({ start, len: end - start })) ?? ""
	if anchor_of(added, added_to.id) != Ok(Range(Str.drop_suffix(expected, "\n"))) or added.len() != before.len() + 1 {
		crash "an added comment is not anchored to its span"
	}
	replied = listed(replied_to.document)
	reply_entry = replied.find_first(|entry| entry.id == replied_to.id) ?? crash "a reply is missing"
	if reply_entry.comment.parent != Parent(to) or Ok(reply_entry.anchor) != anchor_of(added, to) {
		crash "a reply does not reply to its parent with its parent's anchor"
	}
	resolved = listed(resolved_document)
	thread = Comments.thread(comments_of(replied), resolve_at)
	if resolved.any(|entry| entry.comment.resolved != (thread.contains(entry.id) or replied.any(|other| other.id == entry.id and other.comment.resolved))) {
		crash "resolving resolved more or less than the thread"
	}
	gone = Comments.replies(comments_of(resolved), remove_at)
	remaining = sorted_by_id(resolved).keep_if(|entry| !gone.contains(entry.id)).map(|entry| entry.comment.content)
	if sorted_by_id(listed(removed_document)).map(|entry| entry.comment.content) != remaining {
		crash "removing a comment removed more or less than it and its replies"
	}
	for one in edited {
		bytes = Docx.to_bytes(one) ?? crash "an edited document did not write"
		check_identifiers(written_parts(bytes))
		if listed((Docx.parse(bytes) ?? crash "an edited document did not parse").document) != listed(one) {
			crash "an edited document read back as different comments"
		}
	}
	costs
}

# A document's comments, as `Docx.comments` gives them.
listed : Document -> List(Comments.Anchored)
listed = |document| Docx.comments(document).comments

anchor_of : List(Comments.Anchored), U64 -> Try(Comments.Anchor, [Missing])
anchor_of = |entries, id|
	match entries.find_first(|entry| entry.id == id) {
		Ok(entry) => Ok(entry.anchor)
		Err(_) => Err(Missing)
	}

# The comments in their places.
comments_of : List(Comments.Anchored) -> List(Document.Comment)
comments_of = |entries| sorted_by_id(entries).map(|entry| entry.comment)

sorted_by_id : List(Comments.Anchored) -> List(Comments.Anchored)
sorted_by_id = |entries| entries.sort_with(|a, b| if (a.id < b.id) Before else if (a.id > b.id) After else Same)

# The trees of a written package's parts that hold comments' ranges,
# bookmarks and tracked changes.
written_parts : List(U8) -> List(XmlTree.Node)
written_parts = |bytes| ["/word/document.xml", "/word/footnotes.xml", "/word/header1.xml", "/word/comments.xml"].map(|name| part_tree(bytes, name))

# A written part's tree, or an empty one where the package has no such part.
part_tree : List(U8), Str -> XmlTree.Node
part_tree = |bytes, name| {
	pkg = Opc.open(bytes, {}) ?? crash "a written document did not open"
	match Opc.part_bytes(pkg, name) {
		Ok(content) => XmlTree.parse(content, {}) ?? crash "a written part is not XML"
		Err(_) => Text("")
	}
}

# A part's tree rendered as the package writes it, its extension namespaces
# declared ignorable.
rendered : List((Str, XmlTree.Node)), Str -> List(U8)
rendered = |trees, name|
	match trees.find_first(|(candidate, _)| candidate == name) {
		Ok((_, tree)) => XmlTree.render(Mce.declare_extensions(tree)) ?? crash "a written part did not render"
		Err(_) => crash "the package asked for a part that was not written"
	}

# The package: the main document, related to its comments part and the
# parts beside it, and to the footnotes and header parts named.
graph : List(Opc.Relationship), List(Str) -> Opc.Graph
graph = |relationships, named| {
	stories = [
		("footnotes", "/word/footnotes.xml", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/footnotes"),
		("header", "/word/header1.xml", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/header"),
	]
	related = List.concat(
		[
			("comments", "/word/comments.xml", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/comments"),
			("commentsExtended", "/word/commentsExtended.xml", "http://schemas.microsoft.com/office/2011/relationships/commentsExtended"),
			("commentsIds", "/word/commentsIds.xml", "http://schemas.microsoft.com/office/2016/09/relationships/commentsIds"),
			("commentsExtensible", "/word/commentsExtensible.xml", "http://schemas.microsoft.com/office/2018/08/relationships/commentsExtensible"),
			("people", "/word/people.xml", "http://schemas.microsoft.com/office/2011/relationships/people"),
		],
		stories.keep_if(|(_, name, _)| named.contains(name)),
	)
	to_parts = related.map(|(kind, name, _)| { name, content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.${kind}+xml", relationships: [] })
	links = related.map(|(kind, target, relationship)| { id: "rIdC${kind}", kind: relationship, target, mode: Internal })
	{
		relationships: [{ id: "rId1", kind: Opc.officedocument_relationship, target: "/word/document.xml", mode: Internal }],
		parts: List.prepend(to_parts, { name: "/word/document.xml", content_type: main_type, relationships: List.concat(relationships, links) }),
	}
}

# What the written main document and comments parts name: every comment
# range's start and end, the comments' identifiers and paragraph
# identifiers, the bookmarks' starts and ends, the tracked changes'
# identifiers, and the kept permission ranges'.
Names : { starts : List(Str), ends : List(Str), comments : List(Str), paragraphs : List(Str), bookmarks : List(Str), bookmark_ends : List(Str), revisions : List(Str), kept : List(Str) }

# Across a document's parts: every range that starts ends once and names a
# comment; the comments' paragraph identifiers are unique; the comments',
# bookmarks' and tracked changes' identifiers are unique together and apart
# from the kept permission ranges'; and each bookmark that ends has started.
check_identifiers : List(XmlTree.Node) -> {}
check_identifiers = |trees| {
	empty = { starts: [], ends: [], comments: [], paragraphs: [], bookmarks: [], bookmark_ends: [], revisions: [], kept: [] }
	names = trees.fold(empty, names_in)
	if sorted(names.starts) != sorted(names.ends) or !unique(names.starts) {
		crash "a written comment range is not balanced"
	}
	if !names.starts.all(|id| names.comments.contains(id)) {
		crash "a written comment range names no comment"
	}
	allocated = List.join([names.comments, names.bookmarks, names.revisions])
	if !unique(allocated) or !unique(names.paragraphs) {
		crash "a written identifier repeats"
	}
	if allocated.any(|id| names.kept.contains(id)) {
		crash "a written identifier is one kept content uses"
	}
	if !names.bookmark_ends.all(|id| names.bookmarks.contains(id)) {
		crash "a written bookmark ends without starting"
	}
	{}
}

names_in : Names, XmlTree.Node -> Names
names_in = |names, node|
	match node {
		Element(element) => {
			id = attribute(element, wordprocessingml, "id")
			named = if element.name.namespace != Uri(wordprocessingml) {
				names
			} else {
				match element.name.local {
					"commentRangeStart" => { ..names, starts: List.append(names.starts, id) }
					"commentRangeEnd" => { ..names, ends: List.append(names.ends, id) }
					"comment" => { ..names, comments: List.append(names.comments, id) }
					"bookmarkStart" => { ..names, bookmarks: List.append(names.bookmarks, id) }
					"bookmarkEnd" => { ..names, bookmark_ends: List.append(names.bookmark_ends, id) }
					"ins" => { ..names, revisions: List.append(names.revisions, id) }
					"permStart" => { ..names, kept: List.append(names.kept, id) }
					"p" =>
						match attribute(element, w14, "paraId") {
							"" => names
							identifier => { ..names, paragraphs: List.append(names.paragraphs, identifier) }
						}

					_ => names
				}
			}
			element.children.fold(named, names_in)
		}

		Text(_) => names
	}

attribute : { name : XmlTree.Name, bindings : List(XmlTree.Binding), attributes : List(XmlTree.Attribute), children : List(XmlTree.Node) }, Str, Str -> Str
attribute = |element, namespace, local|
	match element.attributes.find_first(|candidate| candidate.name.local == local and candidate.name.namespace == Uri(namespace)) {
		Ok(found) => found.value
		Err(_) => ""
	}

unique : List(Str) -> Bool
unique = |values| values.fold(Set.with_capacity(values.len()), |found, value| found.insert(value)).len() == values.len()

# Identifiers as numbers in order; every identifier written is a number.
sorted : List(Str) -> List(U64)
sorted = |values| values.map(|value| U64.from_str(value) ?? 0).sort_with(|a, b| if (a < b) Before else if (a > b) After else Same)

# Writing allocates at most linearly in the written trees' nodes and
# attributes, and the bytes it holds live beyond its input grow at most
# linearly.
check_linear : Str, Fuzz.Stats, U64 -> {}
check_linear = |what, stats, nodes| {
	if stats.allocs + stats.reallocs > linear_allocation_ceiling(nodes) {
		crash "${what} allocated more than linearly in the written trees' nodes"
	}
	if held(stats) > linear_memory_ceiling(nodes) {
		crash "${what} held more than linearly many bytes live"
	}
	{}
}

# The nodes and attributes of a tree.
size : XmlTree.Node -> U64
size = |tree|
	match tree {
		Text(_) => 1
		Element(element) => element.children.fold(1 + element.attributes.len(), |total, child| total + size(child))
	}

# The body writer's ceilings, `fuzz/document_roundtrip`'s, which the declared
# documents and a minute of generated ones on nightly-2026-11-07 stay within.
linear_allocation_ceiling : U64 -> U64
linear_allocation_ceiling = |nodes| 64 + 4 * nodes

linear_memory_ceiling : U64 -> U64
linear_memory_ceiling = |nodes| 16_384 + 512 * nodes

# The ceilings of each comment edit in the nodes of the written main
# document and comments parts: each edit reads and writes the whole
# document, about five allocations and 300 bytes held live a node on the
# declared documents.
edit_allocation_ceiling : U64 -> U64
edit_allocation_ceiling = |nodes| 1024 + 8 * nodes

edit_memory_ceiling : U64 -> U64
edit_memory_ceiling = |nodes| 65_536 + 1536 * nodes

# The ceilings of `Docx.comments` in the nodes of the written main document
# and of the comments part and the parts beside it, which it reads into the
# model and joins.
join_allocation_ceiling : U64 -> U64
join_allocation_ceiling = |nodes| 64 + 4 * nodes

join_memory_ceiling : U64 -> U64
join_memory_ceiling = |nodes| 16_384 + 512 * nodes

# Exact ceilings: the allocations and reallocations of each region of each
# declared document, as measured on nightly-2026-11-07 when the ceiling was
# set.
exact_ceilings : List(U8) -> Try(List((Str, U64)), [NotDeclared])
exact_ceilings = |program|
	if program == small_program {
		Ok([("wml-write-comments", 472), ("comments-split", 105), ("docx-comments", 822), ("docx-add-comment", 2097), ("docx-reply", 2750), ("docx-resolve", 2672), ("docx-remove-comment", 2685)])
	} else if program == large_program {
		Ok([("wml-write-comments", 7388), ("comments-split", 1485), ("docx-comments", 12_245), ("docx-add-comment", 30_113), ("docx-reply", 38_812), ("docx-resolve", 37_294), ("docx-remove-comment", 38_748)])
	} else if program == few_comments {
		Ok([("wml-write-comments", 316), ("comments-split", 181), ("docx-comments", 549), ("docx-add-comment", 1664), ("docx-reply", 2133), ("docx-resolve", 2056), ("docx-remove-comment", 2121)])
	} else if program == many_comments {
		Ok([("wml-write-comments", 4891), ("comments-split", 2701), ("docx-comments", 7892), ("docx-add-comment", 23_312), ("docx-reply", 29_062), ("docx-resolve", 27_454), ("docx-remove-comment", 29_073)])
	} else if program == stories_program {
		Ok([("wml-write-comments", 582), ("comments-split", 132), ("docx-comments", 1010), ("docx-add-comment", 2984), ("docx-reply", 3697), ("docx-resolve", 3605), ("docx-remove-comment", 3654)])
	} else {
		Err(NotDeclared)
	}

# The small example of a pair whose large example this is.
small_of : List(U8) -> Try(List(U8), [NotAPair])
small_of = |program|
	if program == large_program {
		Ok(small_program)
	} else if program == many_comments {
		Ok(few_comments)
	} else {
		Err(NotAPair)
	}

# How many times its small example's bytes requested and held live a large
# example may take: sixteen, and an eighth more for the sets, dictionaries
# and lists that grow by doubling, so the bytes a comment costs rise and
# fall as counts cross their capacities. Writing a comment and its reply
# requested between 9.0 and 10.6 KB from 4 to 512 of them, without a trend,
# so the many-comments pair requests 17.6 times as much in writing; a
# quadratic step costs many times more.
byte_ratio : U64
byte_ratio = 18

# The small and large threads repeat one program, the large one sixteen
# times as often.
small_program : List(U8)
small_program = List.join(List.repeat(program_unit, 4))

large_program : List(U8)
large_program = List.join(List.repeat(program_unit, 64))

# Sixteen and 256 short comments: half are ranges over a few words, half
# replies.
few_comments : List(U8)
few_comments = List.join(List.repeat(short_comment, 8))

many_comments : List(U8)
many_comments = List.join(List.repeat(short_comment, 128))

# A comment over a few words, then a reply to the first comment shown at a
# point, each with a durable identifier and a UTC date; then the
# paragraph's end.
short_comment : List(U8)
short_comment = [0x02, 0x01, 0x03, 0x06, 0x00]

# A comment whose range starts in a paragraph, with two paragraphs of
# content and a durable identifier and date; text; a reply shown at a point;
# a bookmark; the range's end; a resolved comment with a table, a range
# between blocks and a tracked insertion; then an unanchored comment.
program_unit : List(U8)
program_unit = [0x12, 0x01, 0x36, 0x08, 0x03, 0x00, 0xBA, 0x07, 0x29, 0x01, 0x03, 0x45, 0x00]

# The threads once more, with comments in a header and a footnote, each
# around a bookmark and a tracked insertion after a kept permission range.
stories_program : List(U8)
stories_program = List.concat(small_program, [0x0B, 0x1B, 0x2B, 0x3B])

main_type : Str
main_type = "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"

wordprocessingml : Str
wordprocessingml = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

w14 : Str
w14 = "http://schemas.microsoft.com/office/word/2010/wordml"

shell : XmlTree.Node
shell = Element({ name: { namespace: Uri(wordprocessingml), local: "document", prefix: Prefix("w") }, bindings: [], attributes: [], children: [] })

w_element : Str, List((Str, Str)), List(XmlTree.Node) -> XmlTree.Node
w_element = |local, attributes, children| {
	w = |name| { namespace: Uri(wordprocessingml), local: name, prefix: Prefix("w") }
	Element({ name: w(local), bindings: [], attributes: attributes.map(|(name, value)| { name: w(name), value }), children })
}

text : Str -> Document.Inline
text = |value| Run({ properties: Document.no_run_properties, content: [Text(value)] })

paragraph : List(Document.Inline) -> Document.Block
paragraph = |content| Paragraph({ properties: Document.no_paragraph_properties, content })

pick : List(a), U64, a -> a
pick = |choices, index, fallback| choices.get(index % choices.len()) ?? fallback

# A document a program describes, one step a byte: the low four bits choose
# the step and the rest its variant. Paragraph content collects until step 0
# ends the paragraph; ranges still open at the end close in the last
# paragraph, which every body has.
Building : { blocks : List(Document.Block), content : List(Document.Inline), comments : List(Document.Comment), open : List(U64), position : U64, header : List(Document.Block), note : List(Document.Block) }

build : List(U8) -> { body : List(Document.Block), comments : List(Document.Comment), people : List(Document.Person), header : List(Document.Block), note : List(Document.Block) }
build = |program| {
	var $state = { blocks: List.with_capacity(program.len()), content: List.with_capacity(8), comments: List.with_capacity(8), open: List.with_capacity(4), position: 0, header: [], note: [] }
	for byte in program {
		$state = step($state, byte % 16, (byte // 16).to_u64())
		$state = { ..$state, position: $state.position + 1 }
	}
	closed = $state.open.fold($state, |state, place| with_inline(state, CommentEnd(place)))
	ended = end_paragraph(closed)
	people = authors.map(|author| { author, presence: if (author == "Lin Editor") Unset else Presence({ provider: "None", user: author }) })
	{ body: ended.blocks, comments: ended.comments, people, header: ended.header, note: ended.note }
}

end_paragraph : Building -> Building
end_paragraph = |state| { ..state, blocks: List.append(state.blocks, paragraph(state.content)), content: List.with_capacity(8) }

with_inline : Building, Document.Inline -> Building
with_inline = |state, item| { ..state, content: List.append(state.content, item) }

# A new comment, the next place among the comments.
with_comment : Building, U64, [Unset, Parent(U64)] -> { state : Building, place : U64 }
with_comment = |state, variant, parent| {
	place = state.comments.len()
	{ state: { ..state, comments: List.append(state.comments, comment(variant, place, parent)) }, place }
}

step : Building, U8, U64 -> Building
step = |state, kind, variant|
	match kind {
		0 => end_paragraph(state)
		1 => with_inline(state, text(pick(["clause ", "  spaced ", "term", ""], variant, "")))
		2 => {
			added = with_comment(state, variant, Unset)
			with_inline({ ..added.state, open: List.append(added.state.open, added.place) }, CommentStart(added.place))
		}

		3 =>
			match added_last(state.open) {
				Ok(place) => {
					ended = with_inline({ ..state, open: List.drop_last(state.open, 1) }, CommentEnd(place))
					with_inline(ended, Run({ properties: Document.no_run_properties, content: [CommentReference(place)] }))
				}

				Err(_) => state
			}

		4 => {
			added = with_comment(state, variant, Unset)
			with_inline(added.state, Run({ properties: Document.no_run_properties, content: [CommentReference(added.place)] }))
		}

		5 => with_comment(state, variant, Unset).state
		6 =>
			if state.comments.is_empty() {
				state
			} else {
				added = with_comment(state, variant, Parent(variant % state.comments.len()))
				with_inline(added.state, Run({ properties: Document.no_run_properties, content: [CommentReference(added.place)] }))
			}

		7 =>
			if state.comments.is_empty() {
				state
			} else {
				place = variant % state.comments.len()
				match state.comments.get(place) {
					Ok(found) => { ..state, comments: List.set(state.comments, place, { ..found, resolved: !found.resolved }) ?? state.comments }
					Err(_) => state
				}
			}

		8 => {
			name = "mark${state.position.to_str()}"
			with_inline(with_inline(with_inline(state, BookmarkStart(name)), text("marked")), BookmarkEnd(name))
		}

		9 => with_inline(with_inline(state, Revision({ kind: Insertion, author: "Ada Reviewer", date: Unset, content: [text("added")], preserved: [] })), Preserved(w_element("permStart", [("id", variant.to_str()), ("edGrp", "everyone")], [])))
		10 => {
			ended = end_paragraph(state)
			added = with_comment(ended, variant, Unset)
			{ ..added.state, blocks: List.append(added.state.blocks, CommentStart(added.place)), open: List.append(added.state.open, added.place) }
		}

		11 => {
			added = with_comment(state, variant, Unset)
			name = "aside${state.position.to_str()}"
			kept = Preserved(w_element("permStart", [("id", variant.to_str()), ("edGrp", "everyone")], []))
			inserted = Revision({ kind: Insertion, author: "Grace Author", date: Unset, content: [text("aside")], preserved: [] })
			aside = paragraph([kept, CommentStart(added.place), BookmarkStart(name), inserted, BookmarkEnd(name), CommentEnd(added.place), Run({ properties: Document.no_run_properties, content: [CommentReference(added.place)] })])
			if variant % 2 == 0 {
				{ ..added.state, header: List.append(added.state.header, aside) }
			} else {
				{ ..added.state, note: List.append(added.state.note, aside) }
			}
		}

		_ => with_inline(state, text("x"))
	}

added_last : List(U64) -> Try(U64, [Empty])
added_last = |open|
	match open.last() {
		Ok(place) => Ok(place)
		Err(_) => Err(Empty)
	}

authors : List(Str)
authors = ["Ada Reviewer", "Grace Author", "Lin Editor"]

# A comment by one of the authors, with content of one or two paragraphs,
# a bookmark or a table; with initials, a date, and a durable identifier
# unique to its place and a UTC date, as the variant says.
comment : U64, U64, [Unset, Parent(U64)] -> Document.Comment
comment = |variant, place, parent| {
	stamp = |day| match WmlRead.date_time("2026-05-0${day}T09:15:00Z") {
		Ok(found) => Date(found)
		Err(_) => Unset
	}
	cell = Cell({ properties: { width: Unset, span: Unset, merge: Unset, borders: [], shading: Unset, alignment: Unset, preserved: [], revision: Unset, change: [] }, content: [paragraph([text("in a cell")])] })
	table = Table({ properties: { style: Unset, width: Unset, borders: [], shading: Unset, preserved: [], change: [] }, grid: [Column(2000)], content: [Row({ properties: { header: Unset, grid_before: Unset, grid_after: Unset, preserved: [], inserted: Unset, deleted: Unset, change: [] }, content: [cell] })] })
	name = "note${place.to_str()}"
	content = pick(
		[
			[paragraph([text("Comment")])],
			[paragraph([text("First")]), paragraph([text("Second")])],
			[paragraph([BookmarkStart(name), text("marked"), BookmarkEnd(name)])],
			[table],
		],
		variant,
		[],
	)
	durable = variant % 2 == 0
	{
		author: pick(authors, variant // 2, ""),
		initials: if (variant % 3 == 0) Unset else Initials("AR"),
		date: if (variant % 5 == 0) Unset else stamp(((variant % 9) + 1).to_str()),
		content,
		preserved: [],
		parent,
		resolved: variant % 7 == 1,
		durable_id: if (durable) DurableId(0x5A000000 + place.to_u32_wrap()) else Unset,
		utc_date: if (durable and variant % 4 == 0) stamp("4") else Unset,
	}
}

target = Fuzz.target_with!({
	name: "comment-anchors",
	examples: [
		Fuzz.example({ name: "small-threads", revision: "1", make: || small_program }),
		Fuzz.example({ name: "large-threads", revision: "1", make: || large_program }),
		Fuzz.example({ name: "few-comments", revision: "1", make: || few_comments }),
		Fuzz.example({ name: "many-comments", revision: "1", make: || many_comments }),
		Fuzz.example({ name: "stories", revision: "1", make: || stories_program }),
	],
	generator,
	test!,
	show: |program| Str.inspect(program),
})
