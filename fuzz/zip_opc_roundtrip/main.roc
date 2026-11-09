app [target] {
	docx: "../../package/main.roc",
	fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.5.0/9WT86CuwM7ZJBSs8iTd1jLyrUFTTiGp5hcJE63TwswGE.tar.zst",
	zip: "https://github.com/lukewilliamboswell/roc-zip/releases/download/0.3.0-rc1/3vvx2cPVp1vjjVgrXcugJqqfrp55ZrURYQUcSArAUHdr.tar.zst",
}

import fuzz.Fuzz
import docx.Limits
import docx.Opc
import zip.Zip

## A part set packages and unpacks to the same parts. Bytes that open as a
## package are written back with every part copied; any other bytes become a
## generated part set, each part's content a slice of them. Either way:
##
## - the chunks of `writer`, `add` and `finish`, concatenated, are the bytes
##   of `to_bytes`, and writing twice gives the same bytes;
## - `[Content_Types].xml` is the first entry, `_rels/.rels` the second when
##   the package has relationships, and no XML part follows a part that is
##   not XML;
## - the written package opens to every part with its content type, its
##   relationships and its content: a copied part's stored bytes, method, CRC
##   and sizes unchanged, a generated part's bytes as given;
## - writing the written package back with every part copied gives the same
##   bytes again.
##
## Writing chunk by chunk holds at most a constant plus multiples of the
## largest part and of the number of parts beyond what was live before; the
## archive itself is never held. Allocation counts are linear in the number
## of parts.
##
## Allocation ratchets, which only ever move down: the declared examples
## allocate no more than they did when their ceilings were set. Raising a
## ceiling needs a cause recorded in the pull request.
test! : List(U8) => Fuzz.Outcome
test! = |bytes| {
	example = declared_example(bytes)
	match Opc.open(bytes, limits) {
		Ok(pkg) =>
			match Opc.graph(pkg) {
				Ok(graph) => check_write!(example, graph, |_| Copied(pkg), Copied(pkg))
				Err(_) =>
					if example == Generated {
						Fuzz.keep
					} else {
						crash "a declared package has no part graph"
					}
			}
		Err(_) => {
			graph = generated_graph(bytes)
			check_write!(example, graph, |name| Bytes(content_of(bytes, graph, name)), Generated(bytes))
		}
	}
}

check_write! : [Small, Large, Generated], Opc.Graph, (Str -> Opc.Content), [Copied(Opc.Package), Generated(List(U8))] => Fuzz.Outcome
check_write! = |example, graph, content_for, source| {
	{ value: streamed, stats } = Fuzz.measure!("opc-writer", || stream_length(graph, content_for))
	{ value: first, stats: buffered_stats } = Fuzz.measure!("opc-to-bytes", || Opc.to_bytes(graph, content_for))
	parts = graph.parts.len()
	if stats.allocs + stats.reallocs > allocation_ceiling(Writer, example, parts) {
		crash "writing chunk by chunk allocated more than its ceiling"
	}
	if buffered_stats.allocs + buffered_stats.reallocs > allocation_ceiling(ToBytes, example, parts) {
		crash "to_bytes allocated more than its ceiling"
	}
	if stats.peak_live_bytes - stats.entry_live_bytes > writer_memory_ceiling(largest_part(graph, content_for), parts) {
		crash "writing chunk by chunk held more than the largest part allows"
	}
	match first {
		Err(_) =>
			if example == Generated {
				Fuzz.keep
			} else {
				crash "a declared package did not write"
			}
		Ok(written) => {
			if streamed != Ok(written.len()) or chunks(graph, content_for) != Ok(written) {
				crash "the chunks are not the bytes of to_bytes"
			}
			if Opc.to_bytes(graph, content_for) != Ok(written) {
				crash "writing the same graph twice disagreed"
			}
			paths = Zip.entries(written).map_ok(|entries| entries.map(|entry| entry.path)) ?? []
			if paths.first() != Ok("[Content_Types].xml") or (!graph.relationships.is_empty() and paths.get(1) != Ok("_rels/.rels")) {
				crash "the generated parts are not first"
			}
			match Opc.open(written, limits) {
				Ok(reopened) => {
					if !xml_before_media(reopened, graph) {
						crash "an XML part follows a part that is not XML"
					}
					if !same_parts(reopened, graph, source) {
						crash "the written package does not open to the same parts"
					}
					rewritten = match Opc.graph(reopened) {
						Ok(copied) => Opc.to_bytes(copied, |_| Copied(reopened))
						Err(_) => Err(NothingPending)
					}
					if rewritten != Ok(written) {
						crash "writing the written package back changed its bytes"
					}
					Fuzz.keep
				}
				Err(_) => crash "a written package does not open"
			}
		}
	}
}

limits : Limits
limits = { max_entries: 64, max_part_bytes: 65_536, max_total_bytes: 1_048_576 }

# The length of the archive, written chunk by chunk with each chunk dropped
# once counted, as a caller streaming to a file would.
stream_length : Opc.Graph, (Str -> Opc.Content) -> Try(U64, Opc.WriteError)
stream_length = |graph, content_for| {
	var $writer = Opc.writer(graph)?
	var $length = 0.U64
	for name in Opc.pending($writer) {
		added = Opc.add($writer, content_for(name))?
		$length = $length + added.chunk.len()
		$writer = added.writer
	}
	Ok($length + Opc.finish($writer)?.len())
}

# The chunks, concatenated.
chunks : Opc.Graph, (Str -> Opc.Content) -> Try(List(U8), Opc.WriteError)
chunks = |graph, content_for| {
	var $writer = Opc.writer(graph)?
	var $out = List.with_capacity(4096)
	for name in Opc.pending($writer) {
		added = Opc.add($writer, content_for(name))?
		$out = List.concat($out, added.chunk)
		$writer = added.writer
	}
	Ok(List.concat($out, Opc.finish($writer)?))
}

# Among the graph's parts, in archive order, no XML part follows one that is
# not XML. A relationship part follows its source, whatever that is.
xml_before_media : Opc.Package, Opc.Graph -> Bool
xml_before_media = |pkg, graph| {
	names = Set.from_list(graph.parts.map(|part| part.name))
	kinds = Opc.parts(pkg).keep_if(|part| names.contains(part.name)).map(|part| is_xml(part.content_type))
	first_other = kinds.find_first_index(|xml| !xml) ?? kinds.len()
	kinds.drop_first(first_other).all(|xml| !xml)
}

is_xml : Str -> Bool
is_xml = |content_type| Str.from_utf8_lossy(content_type.to_utf8().map(|byte| if (byte >= 'A' and byte <= 'Z') byte + 32 else byte)).ends_with("xml")

# The written package's graph has every part of the graph, with its content
# type and relationships, and each part has its content.
same_parts : Opc.Package, Opc.Graph, [Copied(Opc.Package), Generated(List(U8))] -> Bool
same_parts = |reopened, graph, source|
	match Opc.graph(reopened) {
		Ok(written) =>
			written.relationships == graph.relationships
				and written.parts.len() == graph.parts.len()
				and graph.parts.all(
					|part|
						written.parts.contains(part)
							and match source {
								Copied(pkg) => Opc.stored(reopened, part.name).is_ok() and Opc.stored(reopened, part.name) == Opc.stored(pkg, part.name)
								Generated(bytes) => Opc.part_bytes(reopened, part.name) == Ok(content_of(bytes, graph, part.name))
							},
				)
		Err(_) => Bool.False
	}

# The bytes a part's archive entry holds: its compressed size when copied.
largest_part : Opc.Graph, (Str -> Opc.Content) -> U64
largest_part = |graph, content_for|
	graph.parts.fold(
		0,
		|largest, part| {
			size = match content_for(part.name) {
				Bytes(bytes) => bytes.len()
				Copied(pkg) => Opc.stored(pkg, part.name).map_ok(|stored| stored.compressed_size) ?? 0
			}
			largest.max(size)
		},
	)

# Beyond what was live: one DEFLATE compressor's state, which is the
# constant, a part's chunk beside its content, and the central directory and
# the generated parts, which grow with the number of parts.
writer_memory_ceiling : U64, U64 -> U64
writer_memory_ceiling = |largest, parts| 296_960 + 2 * largest + 256 * parts

# Exact ceilings for the declared examples, as allocations plus
# reallocations measured on nightly-2026-11-07 with roc-zip 0.3.0-rc1, and a
# linear one in the number of parts for every other input. Most of a
# generated part's allocations are its compressor's; a copied part takes
# about 40. `to_bytes` takes a few more than the chunked writer, to grow its
# output.
allocation_ceiling : [Writer, ToBytes], [Small, Large, Generated], U64 -> U64
allocation_ceiling = |region, example, parts|
	match (region, example) {
		(Writer, Small) => 212
		(ToBytes, Small) => 213
		(Writer, Large) => 695
		(ToBytes, Large) => 698
		(_, Generated) => 96 * (parts + 3)
	}

declared_example : List(U8) -> [Small, Large, Generated]
declared_example = |bytes|
	if bytes == small_package() {
		Small
	} else if bytes == large_package() {
		Large
	} else {
		Generated
	}

officedocument : Str
officedocument = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"

# A part set from bytes: up to eight parts, the main document last, the
# others XML parts and images the document links to unless a byte says
# otherwise, and an external hyperlink from the document. Each part's
# content is a slice of the bytes.
generated_graph : List(U8) -> Opc.Graph
generated_graph = |bytes| {
	count = 1 + byte_at(bytes, 0) % 8
	var $parts = List.with_capacity(count)
	var $links = List.with_capacity(count)
	var $index = 1.U64
	while $index < count {
		part = if $index % 2 == 1 {
			{ name: "/word/part${$index.to_str()}.xml", content_type: "application/vnd.example.part${$index.to_str()}+xml", relationships: [] }
		} else {
			{ name: "/word/media/image${$index.to_str()}.png", content_type: "image/png", relationships: [] }
		}
		$parts = List.append($parts, part)
		if byte_at(bytes, $index) % 3 != 0 {
			$links = List.append($links, { id: "rId${$index.to_str()}", kind: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/custom", target: part.name, mode: Internal })
		}
		$index = $index + 1
	}
	links = List.append($links, { id: "rIdLink", kind: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink", target: "https://example.com/?q=${byte_at(bytes, 1).to_str()}&r=<1>", mode: External })
	document = { name: "/word/document.xml", content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml", relationships: links }
	{
		relationships: [{ id: "rId1", kind: officedocument, target: document.name, mode: Internal }],
		parts: List.append($parts, document),
	}
}

# A generated part's content: its share of the bytes, by position in the
# graph, the last part taking the remainder.
content_of : List(U8), Opc.Graph, Str -> List(U8)
content_of = |bytes, graph, name| {
	count = graph.parts.len()
	position = graph.parts.find_first_index(|part| part.name == name) ?? 0
	share = bytes.len() // count
	len = if (position + 1 == count) bytes.len() - share * position else share
	bytes.sublist({ start: share * position, len })
}

byte_at : List(U8), U64 -> U64
byte_at = |bytes, at| bytes.get(at).map_ok(|byte| byte.to_u64()) ?? 0

# The smallest package with a main document.
small_package : () -> List(U8)
small_package = || package_of(0)

# A package of the same shape whose main document links to twelve parts.
large_package : () -> List(U8)
large_package = || package_of(12)

package_of : U64 -> List(U8)
package_of = |items| {
	content_types = "<Types xmlns='http://schemas.openxmlformats.org/package/2006/content-types'><Default Extension='rels' ContentType='application/vnd.openxmlformats-package.relationships+xml'/><Default Extension='xml' ContentType='application/xml'/><Override PartName='/word/document.xml' ContentType='application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml'/></Types>"
	package_rels = "<Relationships xmlns='http://schemas.openxmlformats.org/package/2006/relationships'><Relationship Id='rId1' Type='${officedocument}' Target='word/document.xml'/></Relationships>"
	document = "<w:document xmlns:w='http://schemas.openxmlformats.org/wordprocessingml/2006/main'><w:body><w:p/></w:body></w:document>"
	var $entries = List.with_capacity(items + 4)
	$entries = List.append($entries, { path: "[Content_Types].xml", content: content_types.to_utf8() })
	$entries = List.append($entries, { path: "_rels/.rels", content: package_rels.to_utf8() })
	$entries = List.append($entries, { path: "word/document.xml", content: document.to_utf8() })
	var $links = List.with_capacity(items)
	var $item = 1.U64
	while $item <= items {
		$entries = List.append($entries, { path: "word/item${$item.to_str()}.xml", content: "<item n='${$item.to_str()}'/>".to_utf8() })
		$links = List.append($links, "<Relationship Id='rId${$item.to_str()}' Type='urn:example:item' Target='item${$item.to_str()}.xml'/>")
		$item = $item + 1
	}
	if items > 0 {
		$entries = List.append($entries, { path: "word/_rels/document.xml.rels", content: "<Relationships xmlns='http://schemas.openxmlformats.org/package/2006/relationships'>${Str.join_with($links, "")}</Relationships>".to_utf8() })
	}
	Zip.create($entries, Fastest) ?? crash "package_of: the paths are valid"
}

target = Fuzz.target_with!({
	name: "zip-opc-roundtrip",
	examples: [
		Fuzz.example({ name: "empty", revision: "1", make: || [] }),
		Fuzz.example({ name: "small-package", revision: "1", make: small_package }),
		Fuzz.example({ name: "large-package", revision: "1", make: large_package }),
	],
	generator: Fuzz.bytes,
	test!,
	show: |bytes| Str.inspect(bytes),
})
