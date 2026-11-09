app [target] {
	docx: "../../package/main.roc",
	fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.5.0/9WT86CuwM7ZJBSs8iTd1jLyrUFTTiGp5hcJE63TwswGE.tar.zst",
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
## the allocated ones must avoid. The body is written by `WmlWrite.document` with the identifiers
## `WmlWrite.comment_ids` allocates, the comments part by
## `WmlWrite.comments`, the extended comments, comment identifiers and
## extensible comments parts by `Comments.split` and the people part by
## `Comments.people_part`, each with its content type and its relationship
## from the main document. `Docx.parse` must read back the body and the
## comments, threads, anchors and people as they were written, with no entry
## left unapplied; in the written parts
## every range that starts ends, and the comments' and bookmarks'
## identifiers and the comments' paragraph identifiers are unique and avoid
## the kept ones. `Docx.to_bytes` must then give the same bytes twice, and
## bytes that read back as an equivalent document that writes the same bytes
## again.
##
## Allocation ratchets, which only ever move down: writing the comments and
## their threads allocates at most linearly in the written trees' nodes and
## attributes and keeps at most linearly many bytes live, and each declared
## example allocates no more than it did when its ceiling was set. The large
## declared document, sixteen times the small one, allocates at most sixteen
## times as often as the small one does in the same run. The bytes it
## requests are bounded by the linear ceiling instead: measured at 4, 16, 64
## and 256 repetitions they run 29.7, 29.5, 31.0 and 31.9 KiB a repetition,
## within the ceiling but not within an exact sixteen-fold. Raising a ceiling
## needs a cause recorded in the pull request.
test! : List(U8) => Fuzz.Outcome
test! = |program| {
	cost = round_trip!(program)
	match exact_ceiling(program) {
		Ok(ceiling) =>
			if cost.allocations > ceiling {
				crash "a declared document allocated more than its ceiling"
			}

		Err(NotDeclared) => {}
	}
	if program == large_program {
		small = round_trip!(small_program)
		if cost.allocations > 16 * small.allocations {
			crash "the large document allocated more than sixteen times the small one"
		}
	}
	Fuzz.keep
}

generator : Fuzz.Generator(List(U8))
generator = Fuzz.bytes

# Write a program's document, measuring the writing of its comments, and
# check the round trip. Returns the allocations and reallocations writing
# the comments made.
round_trip! : List(U8) => { allocations : U64 }
round_trip! = |program| {
	built = build(program)
	ids = WmlWrite.comment_ids(built.body, built.comments)
	context = { relationships: [], footnotes: [], endnotes: [], comments: ids }
	main = WmlWrite.document(shell, built.body, context) ?? crash "a generated body did not write"
	taken = WmlWrite.taken([main.tree])
	{ value: written, stats } = Fuzz.measure!(
		"comments-write",
		|| {
			part = WmlWrite.comments(Text(""), built.comments, context, taken)
			match part {
				Ok(comments) => Ok({ comments, split: Comments.split(built.comments, comments.paragraphs, { extended: Text(""), ids: Text(""), extensible: Text("") }, { extended: [], ids: [], extensible: [], diagnostics: [] }), people: Comments.people_part(Text(""), built.people) })
				Err(problem) => Err(problem)
			}
		},
	)
	parts = written ?? crash "generated comments did not write"
	check_linear(stats, [parts.comments.tree, parts.split.extended, parts.split.ids, parts.split.extensible, parts.people].fold(0, |total, tree| total + size(tree)))
	check_identifiers(main.tree, parts.comments.tree)
	trees = [
		("/word/document.xml", main.tree),
		("/word/comments.xml", parts.comments.tree),
		("/word/commentsExtended.xml", parts.split.extended),
		("/word/commentsIds.xml", parts.split.ids),
		("/word/commentsExtensible.xml", parts.split.extensible),
		("/word/people.xml", parts.people),
	]
	bytes = Opc.to_bytes(graph(main.relationships), |name| Bytes(rendered(trees, name))) ?? crash "a written document did not package"
	parsed = Docx.parse(bytes) ?? crash "a written document did not parse"
	if Docx.body(parsed.document) != built.body {
		crash "a written body read back differently"
	}
	if Docx.comments(parsed.document) != { comments: Comments.anchored(built.body, built.comments), diagnostics: [] } {
		crash "written comments read back as different threads or anchors"
	}
	if Docx.people(parsed.document) != { people: built.people, diagnostics: [] } {
		crash "written people read back differently"
	}
	first = Docx.to_bytes(parsed.document) ?? crash "a read document did not write"
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
	{ allocations: stats.allocs + stats.reallocs }
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
# parts beside it.
graph : List(Opc.Relationship) -> Opc.Graph
graph = |relationships| {
	related = [
		("comments", "/word/comments.xml", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/comments"),
		("commentsExtended", "/word/commentsExtended.xml", "http://schemas.microsoft.com/office/2011/relationships/commentsExtended"),
		("commentsIds", "/word/commentsIds.xml", "http://schemas.microsoft.com/office/2016/09/relationships/commentsIds"),
		("commentsExtensible", "/word/commentsExtensible.xml", "http://schemas.microsoft.com/office/2018/08/relationships/commentsExtensible"),
		("people", "/word/people.xml", "http://schemas.microsoft.com/office/2011/relationships/people"),
	]
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

# Every range that starts ends once and names a comment; the comments'
# paragraph identifiers are unique; the comments', bookmarks' and tracked
# changes' identifiers are unique together and apart from the kept
# permission ranges'; and each bookmark that ends has started.
check_identifiers : XmlTree.Node, XmlTree.Node -> {}
check_identifiers = |main, comments| {
	empty = { starts: [], ends: [], comments: [], paragraphs: [], bookmarks: [], bookmark_ends: [], revisions: [], kept: [] }
	names = names_in(names_in(empty, main), comments)
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
check_linear : Fuzz.Stats, U64 -> {}
check_linear = |stats, nodes| {
	if stats.allocs + stats.reallocs > linear_allocation_ceiling(nodes) {
		crash "writing comments allocated more than linearly in the written trees' nodes"
	}
	if stats.peak_live_bytes - stats.entry_live_bytes > linear_memory_ceiling(nodes) {
		crash "writing comments held more than linearly many bytes live"
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

# Exact ceilings: the allocations and reallocations of writing each declared
# document's comments, as measured on nightly-2026-11-07 when the ceiling
# was set.
exact_ceiling : List(U8) -> Try(U64, [NotDeclared])
exact_ceiling = |program|
	if program == small_program {
		Ok(577)
	} else if program == large_program {
		Ok(8_873)
	} else {
		Err(NotDeclared)
	}

# The small and large declared documents repeat one program, the large one
# sixteen times as often. Writing their comments takes 577 and 8,873
# allocations, a ratio of 15.4 against the sixteen the test allows.
small_program : List(U8)
small_program = List.join(List.repeat(program_unit, 4))

large_program : List(U8)
large_program = List.join(List.repeat(program_unit, 64))

# A comment whose range starts in a paragraph, with two paragraphs of
# content and a durable identifier and date; text; a reply shown at a point;
# a bookmark; the range's end; a resolved comment with a table, a range
# between blocks and a tracked insertion; then an unanchored comment.
program_unit : List(U8)
program_unit = [0x12, 0x01, 0x36, 0x08, 0x03, 0x00, 0xBA, 0x07, 0x29, 0x01, 0x03, 0x45, 0x00]

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
Building : { blocks : List(Document.Block), content : List(Document.Inline), comments : List(Document.Comment), open : List(U64), position : U64 }

build : List(U8) -> { body : List(Document.Block), comments : List(Document.Comment), people : List(Document.Person) }
build = |program| {
	var $state = { blocks: List.with_capacity(program.len()), content: List.with_capacity(8), comments: List.with_capacity(8), open: List.with_capacity(4), position: 0 }
	for byte in program {
		$state = step($state, byte % 16, (byte // 16).to_u64())
		$state = { ..$state, position: $state.position + 1 }
	}
	closed = $state.open.fold($state, |state, place| with_inline(state, CommentEnd(place)))
	ended = end_paragraph(closed)
	people = authors.map(|author| { author, presence: if (author == "Lin Editor") Unset else Presence({ provider: "None", user: author }) })
	{ body: ended.blocks, comments: ended.comments, people }
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
	],
	generator,
	test!,
	show: |program| Str.inspect(program),
})
