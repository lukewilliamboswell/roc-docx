import docx.Docx
import docx.Document
import docx.Opc
import docx.XmlTree

Streaming := [].{}

main : Str
main = "/word/document.xml"

comments : Str
comments = "/word/comments.xml"

relay : Str
relay = "/custom/relay.xml"

payload : Str
payload = "/custom/payload.bin"

extension : Str
extension = "application/vnd.openxmlformats-officedocument.wordprocessingml."

relationship : Str
relationship = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

w : Str
w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

w15 : Str
w15 = "http://schemas.microsoft.com/office/word/2012/wordml"

w16cid : Str
w16cid = "http://schemas.microsoft.com/office/word/2016/wordml/cid"

w16cex : Str
w16cex = "http://schemas.microsoft.com/office/word/2018/wordml/cex"

timestamp : Str
timestamp = "2026-05-04T09:15:00Z"

Choice : { option : Docx.ExtensionPart, part : Str, content_type : Str, link : Opc.Relationship, xml : Str }

choices : List(Choice)
choices = [
	{
		option: ExtendedComments,
		part: "/word/commentsExtended.xml",
		content_type: "${extension}commentsExtended+xml",
		link: { id: "rId2", kind: "http://schemas.microsoft.com/office/2011/relationships/commentsExtended", target: "/word/COMMENTSEXTENDED.XML", mode: Internal },
		xml: "<w15:commentsEx xmlns:w15='${w15}'><w15:commentEx w15:paraId='0000000A' w15:done='1'/></w15:commentsEx>",
	},
	{
		option: CommentIdentifiers,
		part: "/word/commentsIds.xml",
		content_type: "${extension}commentsIds+xml",
		link: { id: "rId3", kind: "http://schemas.microsoft.com/office/2016/09/relationships/commentsIds", target: "/word/COMMENTSIDS.XML", mode: Internal },
		xml: "<w16cid:commentsIds xmlns:w16cid='${w16cid}'><w16cid:commentId w16cid:paraId='0000000A' w16cid:durableId='0000ABCD'/></w16cid:commentsIds>",
	},
	{
		option: ExtensibleComments,
		part: "/word/commentsExtensible.xml",
		content_type: "${extension}commentsExtensible+xml",
		link: { id: "rId4", kind: "http://schemas.microsoft.com/office/2018/08/relationships/commentsExtensible", target: "/word/COMMENTSEXTENSIBLE.XML", mode: Internal },
		xml: "<w16cex:commentsExtensible xmlns:w16cex='${w16cex}'><w16cex:commentExtensible w16cex:durableId='0000ABCD' w16cex:dateUtc='${timestamp}'/></w16cex:commentsExtensible>",
	},
	{
		option: People,
		part: "/word/people.xml",
		content_type: "${extension}people+xml",
		link: { id: "rId5", kind: "http://schemas.microsoft.com/office/2011/relationships/people", target: "/word/PEOPLE.XML", mode: Internal },
		xml: "<w15:people xmlns:w15='${w15}'><w15:person w15:author='Ada Reviewer'/></w15:people>",
	},
]

relay_internal : Opc.Relationship
relay_internal = { id: "rId1", kind: "urn:example:people", target: "/word/PeOpLe.xml", mode: Internal }

relay_external : Opc.Relationship
relay_external = { ..relay_internal, id: "rId2", mode: External }

# Derive the expected graph from the option labels and their wire data.
# In particular, the external link survives regardless of options.
graph : List(Choice) -> Opc.Graph
graph = |selected| {
	has_people = selected.any(|choice| choice.option == People)
	base_links = [
		{ id: "rId1", kind: "${relationship}/comments", target: comments, mode: Internal },
		{ id: "rId6", kind: "urn:example:relay", target: relay, mode: Internal },
		{ id: "rId7", kind: "urn:example:blob", target: payload, mode: Internal },
	]
	{
		relationships: [{ id: "rId1", kind: Opc.officedocument_relationship, target: main, mode: Internal }],
		parts: [
			{ name: main, content_type: "${extension}document.main+xml", relationships: base_links.concat(selected.map(|choice| choice.link)) },
			{ name: comments, content_type: "${extension}comments+xml", relationships: [] },
			{ name: relay, content_type: "application/xml", relationships: if (has_people) [relay_internal, relay_external] else [relay_external] },
			{ name: payload, content_type: "application/octet-stream", relationships: [] },
		].concat(selected.map(|choice| { name: choice.part, content_type: choice.content_type, relationships: [] })),
	}
}

source : {} -> Try(List(U8), Opc.WriteError)
source = |{}| Opc.to_bytes(
	graph(choices),
	|name|
		match name {
			"/word/document.xml" => Bytes("<w:document xmlns:w='${w}'><w:body><w:p><w:r><w:t>Terms</w:t></w:r></w:p></w:body></w:document>".to_utf8())
			"/word/comments.xml" => Bytes("<w:comments xmlns:w='${w}' xmlns:w14='http://schemas.microsoft.com/office/word/2010/wordml'><w:comment w:id='5' w:author='Ada Reviewer'><w:p w14:paraId='0000000A'><w:r><w:t>Read the terms.</w:t></w:r></w:p></w:comment></w:comments>".to_utf8())
			"/custom/relay.xml" => Bytes("<relay/>".to_utf8())
			"/custom/payload.bin" => Bytes(List.repeat(17.U8, 160))
			_ => Bytes((choices.find_first(|choice| choice.part == name).map_ok(|choice| choice.xml) ?? "").to_utf8())
		},
)

# One chunk for each supplied part plus a last ZIP directory chunk.
collect : Docx.Encoder, U64 -> Try(List(U8), [UnexpectedChunkCount])
collect = |encoder, count| {
	var $state = encoder
	var $out = List.with_capacity(4096)
	var $remaining = count
	while $remaining > 0 {
		match Docx.next_chunk($state) {
			Emit(bytes, next) if !bytes.is_empty() => {
				$state = next
				$out = $out.concat(bytes)
				$remaining = $remaining - 1
			}
			_ => return Err(UnexpectedChunkCount)
		}
	}
	match Docx.next_chunk($state) {
		Done => Ok($out)
		Emit(_, _) => Err(UnexpectedChunkCount)
	}
}

# An option independently controls the graph. UTC dates additionally need
# the identity part to join them to a comment, even if their part remains.
comment_matches : Document, List(Docx.ExtensionPart) -> Bool
comment_matches = |document, kept| {
	people = Docx.people(document).people.map(|person| person.author)
	id = if (kept.contains(CommentIdentifiers)) DurableId(0xABCD) else Unset
	date = if (kept.contains(CommentIdentifiers) and kept.contains(ExtensibleComments)) Ok(timestamp) else Err(Unset)
	match Docx.comments(document).comments {
		[{ comment, .. }] =>
			Docx.text(document) == "Terms\n"
				and comment.author == "Ada Reviewer"
				and comment.resolved == kept.contains(ExtendedComments)
				and comment.durable_id == id
				and (
					match comment.utc_date {
						Date(stamp) => Ok(stamp.written)
						Unset => Err(Unset)
					}
				) == date
				and people == (if (kept.contains(People)) ["Ada Reviewer"] else [])
		_ => Bool.False
	}
}

check_options = |document, original, selected, compression| {
	options : Docx.WriteOptions
	options = { compression, extension_parts: selected.map(|choice| choice.option) }
	expected = graph(selected)
	buffered = Docx.to_bytes_with(document, options)?
	streamed = collect(Docx.to_chunks(document, options)?, expected.parts.len() + 1)?
	archive = Opc.open(streamed, {})?
	actual = Opc.graph(archive)?
	reopened = Docx.parse(streamed)?
	if actual.relationships != expected.relationships or actual.parts.len() != expected.parts.len() or !actual.parts.all(|part| expected.parts.contains(part)) {
		crash "wrong graph for ${Str.inspect(options.extension_parts)}. Expected ${Str.inspect(expected)}, found ${Str.inspect(actual)}"
	}
	Ok(streamed == buffered and Opc.stored(archive, payload) == original and comment_matches(reopened.document, options.extension_parts))
}

## Every subset of extension parts, at every compression level, gives the
## same streamed and buffered archive and removes both parts and inbound
## internal links. OPC compares names without regard to ASCII case; retained
## targets keep their spelling and the external target stays external.
expect {
	bytes = source({})?
	original = Opc.stored(Opc.open(bytes, {})?, payload)
	document = Docx.parse(bytes)?.document
	subsets = choices.fold([[]], |sets, choice| sets.concat(sets.map(|one| one.append(choice))))
	var $agrees = Bool.True
	for selected in subsets {
		for compression in [Fastest, Balanced, Smallest] {
			$agrees = check_options(document, original, selected, compression)? and $agrees
		}
	}
	$agrees
}

## A malformed tree in a retained extension yields a located preflight
## error before a chunk exists. Omitting that extension leaves it outside
## the archive's render checks.
expect {
	bytes = source({})?
	document = Docx.parse(bytes)?.document
	part = Document.xml_part(document, "/word/people.xml")?
	malformed : XmlTree.Node
	malformed = match part.tree {
		Element(root) => Element({ ..root, attributes: root.attributes.append({ name: { namespace: NoNamespace, local: "invalid", prefix: Unprefixed }, value: Str.from_utf8([0])? }) })
		Text(_) => crash "the source People part should be an element"
	}
	invalid = Document.with_part(document, part.name, malformed, part.relationships)
	failure = Docx.to_bytes_with(invalid, {}).map_ok(|_| {})
	preflight = Docx.to_chunks(invalid, {}).map_ok(|_| {})
	selected = choices.drop_if(|choice| choice.option == People)
	match failure {
		Err(XmlPartUnwritable({ part: "/word/people.xml", problem: _ })) =>
			preflight == failure and check_options(invalid, Opc.stored(Opc.open(bytes, {})?, payload), selected, Balanced)?
		_ => Bool.False
	}
}

## Direct part removal also compares names without regard to ASCII case.
## Requesting a name absent from the graph leaves the document alone,
## including relationships in a graph still being assembled.
expect {
	bytes = source({})?
	document = Docx.parse(bytes)?.document
	removed = Document.without_part(document, "/WORD/pEOPLE.xml")
	original_graph = graph(choices)
	unbuilt = Document.from_trees({ ..original_graph, parts: original_graph.parts.drop_if(|part| part.name == "/word/people.xml") }, Dict.empty(), [])
	expected = graph(choices.drop_if(|choice| choice.option == People))
	actual = Opc.graph(Opc.open(Document.to_bytes(removed)?, {})?)?
	!Document.has_part(removed, "/word/people.xml")
		and actual.parts.len() == expected.parts.len()
		and actual.parts.all(|part| expected.parts.contains(part))
		and Document.equivalent(unbuilt, Document.without_part(unbuilt, "/word/PEOPLE.XML"))
}
