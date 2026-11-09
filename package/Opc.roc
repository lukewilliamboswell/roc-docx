## Open Packaging Conventions (ECMA-376 Part 2): the parts, content types and
## relationships of a package, read from a ZIP archive within explicit limits
## and written to one a part at a time.
##
## Part names are absolute, such as `/word/document.xml`, and compare without
## regard to ASCII case, as the conventions require. An opened package keeps
## the archive and an index of its parts, and inflates a part when it is asked
## for. Relationships are parsed from the source part's `_rels` part on demand
## and their targets are resolved against the source part. Both kinds of
## package part are read as namespaced XML within the XML bounds of `Limits`,
## and their elements are matched by namespace and local name, whatever
## prefix a producer wrote them with.
import zip.Zip
import Limits
import XmlTree

Opc :: [].{

	## A part of the package: its name as the archive spells it, its content
	## type, and the decompressed size its entry declares, which opening
	## checked against the limits.
	Part : { name : Str, content_type : Str, size : U64 }

	## An opened package: the archive bytes and its parts with an index by
	## name, the relationship parts inflated and the rest as they are stored,
	## and the limits it was opened with, which bound reading its
	## relationships. `[Content_Types].xml` is consumed to label the parts and
	## is not one of them.
	Package :: {
		archive : List(U8),
		parts : List(Located),
		index : Dict(Str, U64),
		limits : Limits,
	}

	## One relationship of a source part. An internal target is an absolute
	## part name; an external target is kept as written.
	Relationship : { id : Str, kind : Str, target : Str, mode : [Internal, External] }

	## How a part's bytes are stored in the archive: as they are, DEFLATE
	## compressed, or with another method, named by its ZIP method number,
	## that the package cannot inflate but can still copy.
	Method : [Stored, Deflated, Other(U16)]

	## A part's bytes exactly as the archive stores them, with the method, CRC
	## and sizes needed to write them into another archive unchanged.
	StoredPart : { name : Str, method : Method, crc : U32, compressed_size : U64, uncompressed_size : U64, bytes : List(U8) }

	## The part graph of a package to write: the package's own relationships,
	## and each part with its content type and the relationships whose source
	## it is. `[Content_Types].xml` and the relationship parts are not in the
	## graph; the writer generates them from it.
	Graph : { relationships : List(Relationship), parts : List(GraphPart) }

	## A part of a graph. An internal relationship's target is an absolute
	## part name, as `relationships` reads it.
	GraphPart : { name : Str, content_type : Str, relationships : List(Relationship) }

	## A part's bytes for the writer: `Bytes` to compress, or `Copied` from the
	## part of the same name in an opened package, whose stored bytes, method,
	## CRC and sizes are written unchanged.
	Content : [Bytes(List(U8)), Copied(Package)]

	## A package being written one part at a time: the archive's central
	## directory so far and the steps still to write, never a part's content.
	Writer :: { zip : Zip.Writer, steps : List(Step), next : U64 }

	## Why a package cannot be written: a part name the conventions do not
	## allow, two parts that would share a name, text XML cannot carry, or a
	## relationship whose identifier is not an XML name or repeats one of its
	## source. The rest are mistakes in driving a writer, or a copied part its
	## package cannot supply.
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
	]

	## An attribute a package part must have and does not.
	AttributeLocation : { part : Str, element : Str, attribute : Str }

	## Why a package cannot be opened: the ZIP layer's own archive errors, two
	## parts with the same name, a part whose content is not the size its
	## entry declares, the limit that was exceeded, or what is wrong with
	## `[Content_Types].xml`: XML that cannot be read, from bytes that are not
	## UTF-8 to an exceeded XML bound, a root that is not the content types
	## namespace's `Types`, or an entry without its attributes.
	OpenError : [
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
		MissingAttribute(AttributeLocation),
		NoContentType(Str),
	]

	## Why a part's bytes cannot be read: no part has the name, or its stored
	## data is damaged, in a method the package cannot inflate, or not the
	## size its entry declares.
	PartError : [
		MissingPart(Str),
		TruncatedArchive,
		CompressionNotSupported(U16),
		CrcMismatch({ path : Str, expected : U32, actual : U32 }),
		InvalidCompressedData(Str),
		PartSizeMismatch({ name : Str, declared : U64 }),
	]

	## Why a part's relationships cannot be read: their relationship part is
	## missing, its XML cannot be read, or a relationship lacks an attribute.
	RelationshipsError : [
		MissingPart(Str),
		RelationshipsNotXml({ part : Str, problem : XmlTree.ReadError }),
		MissingAttribute(AttributeLocation),
	]

	## The relationship type that names a package's main document part.
	officedocument_relationship : Str
	officedocument_relationship = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"

	## Open a package within the limits. The checks run in this order, and the
	## first that fails is the error:
	##
	## 1. The archive's own size against `max_total_bytes`.
	## 2. The central directory, which is read without inflating anything;
	##    two entries with byte-equal names are a `DuplicatePart`.
	## 3. The entry count against `max_entries`.
	## 4. Each entry's declared decompressed size against `max_part_bytes`,
	##    and their running total against `max_total_bytes`, in archive order.
	## 5. Part names that differ only in ASCII case, as a `DuplicatePart`.
	## 6. `[Content_Types].xml`, inflated and parsed.
	## 7. A content type for every part, and each relationship part inflated.
	##
	## Nothing is inflated before step 6, and a part is inflated into a buffer
	## of the size its entry declares and no further: content that runs past
	## it, or ends short of it, is a `PartSizeMismatch`. Every other part stays
	## compressed until `part_bytes` asks for it.
	open : List(U8), Limits -> Try(Package, OpenError)
	open = |bytes, limits| {
		if bytes.len() > limits.max_total_bytes {
			return Err(PackageTooLarge(bytes.len()))
		}
		entries = Zip.entries(bytes) ? from_zip
		if entries.len() > limits.max_entries {
			return Err(TooManyEntries(entries.len()))
		}
		var $total = 0.U64
		for entry in entries {
			if entry.uncompressed_size > limits.max_part_bytes {
				return Err(PartTooLarge({ name: entry.path, bytes: entry.uncompressed_size }))
			}
			$total = $total.plus_saturated(entry.uncompressed_size)
			if $total > limits.max_total_bytes {
				return Err(PackageTooLarge($total))
			}
		}
		var $names = Set.with_capacity(entries.len())
		for entry in entries {
			key = ascii_lowercase(entry.path)
			if $names.contains(key) {
				return Err(DuplicatePart(entry.path))
			}
			$names = $names.insert(key)
		}
		types_entry = entries.find_first(|entry| ascii_lowercase(entry.path) == content_types_key) ? |_| MissingContentTypes
		types = parse_content_types(inflate(bytes, types_entry) ? from_zip, limits)?
		var $parts = List.with_capacity(entries.len())
		var $index = Dict.with_capacity(entries.len())
		for entry in entries {
			name = "/${entry.path}"
			key = ascii_lowercase(name)
			if !name.ends_with("/") and ascii_lowercase(entry.path) != content_types_key {
				content_type = content_type_for(types, name, key)?
				content = if (is_relationships_part(key)) Inflated(inflate(bytes, entry) ? from_zip) else Deferred
				$index = $index.insert(key, $parts.len())
				$parts = List.append($parts, { part: { name, content_type, size: entry.uncompressed_size }, entry, content })
			}
		}
		Ok({ archive: bytes, parts: $parts, index: $index, limits })
	}

	## Every part, in archive order.
	parts : Package -> List(Part)
	parts = |pkg| pkg.parts.map(|located| located.part)

	## The part with this absolute name, compared without regard to ASCII case.
	part : Package, Str -> Try(Part, [MissingPart(Str)])
	part = |pkg, name|
		Ok(find(pkg, name)?.part)

	## A part's decompressed bytes. A relationship part was inflated when the
	## package was opened; any other part is inflated now, into a buffer of
	## the size its entry declares, and inflation stops there.
	part_bytes : Package, Str -> Try(List(U8), PartError)
	part_bytes = |pkg, name| {
		located = find(pkg, name)?
		match located.content {
			Inflated(content) => Ok(content)
			Deferred => Ok(inflate(pkg.archive, located.entry) ? |err| from_entry(located.part.name, err))
		}
	}

	## A part's bytes as the archive stores them, neither inflated nor checked
	## against their CRC, for writing the part into another archive unchanged.
	## A stored part whose two sizes differ is a `PartSizeMismatch`, since
	## writing it again would make an invalid archive.
	stored : Package, Str -> Try(StoredPart, [MissingPart(Str), PartSizeMismatch({ name : Str, declared : U64 })])
	stored = |pkg, name| {
		located = find(pkg, name)?
		entry = located.entry
		if entry.method == Stored and entry.compressed_size != entry.uncompressed_size {
			return Err(PartSizeMismatch({ name: located.part.name, declared: entry.uncompressed_size }))
		}
		Ok({
			name: located.part.name,
			method: entry.method,
			crc: entry.crc,
			compressed_size: entry.compressed_size,
			uncompressed_size: entry.uncompressed_size,
			bytes: pkg.archive.sublist({ start: entry.data_offset, len: entry.compressed_size }),
		})
	}

	## The relationships of a source part, or of the package itself for `/`.
	relationships : Package, Str -> Try(List(Relationship), RelationshipsError)
	relationships = |pkg, source| {
		rels_name = relationships_part_name(source)
		bytes = match find(pkg, rels_name)?.content {
			Inflated(content) => content
			Deferred => return Err(MissingPart(rels_name))
		}
		root = XmlTree.parse(bytes, pkg.limits) ? |problem| RelationshipsNotXml({ part: rels_name, problem })
		var $found = List.with_capacity(8)
		for node in children_of(root) {
			if is_named(node, relationships_namespace, "Relationship") {
				id = attribute(node, { part: rels_name, element: "Relationship", attribute: "Id" })?
				kind = attribute(node, { part: rels_name, element: "Relationship", attribute: "Type" })?
				target = attribute(node, { part: rels_name, element: "Relationship", attribute: "Target" })?
				mode = match attribute(node, { part: rels_name, element: "Relationship", attribute: "TargetMode" }) {
					Ok("External") => External
					_ => Internal
				}
				resolved = match mode {
					External => target
					Internal => resolve_target(source, target)
				}
				$found = List.append($found, { id, kind, target: resolved, mode })
			}
		}
		Ok($found)
	}

	## The main document part: the target of the package's `officeDocument`
	## relationship, wherever the producer placed it.
	main_document : Package -> Try(Part, [MissingPart(Str), RelationshipsNotXml({ part : Str, problem : XmlTree.ReadError }), MissingAttribute(AttributeLocation), NoMainDocument])
	main_document = |pkg| {
		rels = Opc.relationships(pkg, "/")?
		rel = rels.find_first(|candidate| candidate.kind == Opc.officedocument_relationship) ? |_| NoMainDocument
		Opc.part(pkg, rel.target)
	}

	## The part graph of an opened package: every part in archive order with
	## the relationships read from it, and the package's own. A relationship
	## part becomes its source's relationships, which the writer generates
	## again, unless it has none or its source is not in the package: then it
	## stays an ordinary part, so writing the graph still keeps it.
	graph : Package -> Try(Graph, RelationshipsError)
	graph = |pkg| {
		package_relationships = relationships_of(pkg, "/")?
		var $parts = List.with_capacity(pkg.parts.len())
		for located in pkg.parts {
			name = located.part.name
			generated = match source_of(name) {
				Ok(source) => (source == "/" or pkg.index.contains(ascii_lowercase(source))) and !relationships_of(pkg, source)?.is_empty()
				Err(NotRelationships) => Bool.False
			}
			if !generated {
				rels = relationships_of(pkg, name)?
				$parts = List.append($parts, { name, content_type: located.part.content_type, relationships: rels })
			}
		}
		Ok({ relationships: package_relationships, parts: $parts })
	}

	## Start writing a package. Every check on the graph runs here, and the
	## archive order is fixed:
	##
	## 1. `[Content_Types].xml`, generated from the parts' content types.
	## 2. `_rels/.rels`, the package's relationships.
	## 3. The main document, the target of the package's `officeDocument`
	##    relationship; then the other parts the package's relationships
	##    reach, breadth first in relationship order; then the parts nothing
	##    reaches, in graph order. Each part is followed by its relationship
	##    part, and parts whose content type is not XML, such as images, come
	##    after all the others, in the same order among themselves.
	##
	## A relationship part is written only for a source with relationships.
	## An internal target inside its source part's directory is written
	## relative to it, and any other as an absolute part name.
	writer : Graph -> Try(Writer, WriteError)
	writer = |package_graph| {
		check_graph(package_graph)?
		order = write_order(package_graph)
		var $steps = List.with_capacity(2 * order.len() + 2)
		$steps = List.append($steps, Generated({ path: content_types_path, content: content_types_xml(order).to_utf8() }))
		if !package_graph.relationships.is_empty() {
			$steps = List.append($steps, Relationships({ source: "/", relationships: package_graph.relationships }))
		}
		for planned in order {
			$steps = List.append($steps, Part(planned.name))
			if !planned.relationships.is_empty() {
				$steps = List.append($steps, Relationships({ source: planned.name, relationships: planned.relationships }))
			}
		}
		Ok({ zip: Zip.writer({ compression: Balanced }), steps: $steps, next: 0 })
	}

	## The parts still to add, in the order `add` takes them.
	pending : Writer -> List(Str)
	pending = |w|
		w.steps.drop_first(w.next).keep_oks(
			|step|
				match step {
					Part(name) => Ok(name)
					_ => Err(Generated)
				},
		)

	## Write the next pending part from its content, preceded by any generated
	## part due before it, and return the archive's next chunk. `Bytes` are
	## compressed with DEFLATE at one fixed level, or stored when that is not
	## smaller; a `Copied` part keeps its stored bytes, method, CRC and sizes.
	add : Writer, Content -> Try({ writer : Writer, chunk : List(U8) }, WriteError)
	add = |w, content| {
		var $zip = w.zip
		var $chunk = List.with_capacity(0)
		var $at = w.next
		var $added = Bool.False
		while !$added {
			step = w.steps.get($at) ? |_| NothingPending
			written = Zip.add($zip, entry_for(step, Ok(content))?) ? from_create
			$zip = written.writer
			$chunk = List.concat($chunk, written.chunk)
			$at = $at + 1
			$added = is_part(step)
		}
		Ok({ writer: { zip: $zip, steps: w.steps, next: $at }, chunk: $chunk })
	}

	## The archive's last chunk: the generated parts still due and the central
	## directory. A part that was never added is `NotWritten`.
	finish : Writer -> Try(List(U8), WriteError)
	finish = |w| {
		var $zip = w.zip
		var $chunk = List.with_capacity(0)
		for step in w.steps.drop_first(w.next) {
			written = Zip.add($zip, entry_for(step, Err(NoContent))?) ? from_create
			$zip = written.writer
			$chunk = List.concat($chunk, written.chunk)
		}
		Ok(List.concat($chunk, Zip.finish($zip)))
	}

	## Write a whole package: `writer`, then `add` for each pending part with
	## the content `content_of` gives for its name, then `finish`. The bytes
	## are the writer's chunks, concatenated.
	to_bytes : Graph, (Str -> Content) -> Try(List(U8), WriteError)
	to_bytes = |package_graph, content_of| {
		var $w = Opc.writer(package_graph)?
		var $out = List.with_capacity(0)
		for name in Opc.pending($w) {
			added = Opc.add($w, content_of(name))?
			$out = append_chunk($out, added.chunk)
			$w = added.writer
		}
		Ok(append_chunk($out, Opc.finish($w)?))
	}
}

# A part of an opened package with the archive entry that holds it and, for
# a relationship part, its content.
Located : { part : Opc.Part, entry : Zip.Entry, content : [Inflated(List(U8)), Deferred] }

find : Opc.Package, Str -> Try(Located, [MissingPart(Str)])
find = |pkg, name| {
	at = pkg.index.get(ascii_lowercase(name)) ? |_| MissingPart(name)
	Ok(pkg.parts.get(at) ? |_| MissingPart(name))
}

# Inflate an entry whose declared size opening has checked: the limit is that
# size, so the buffer is reserved at it and inflation stops there.
inflate : List(U8), Zip.Entry -> Try(List(U8), Zip.ExtractError)
inflate = |archive, entry|
	Zip.extract_entry(archive, entry, { max_bytes: entry.uncompressed_size })

# The ZIP layer's errors in the package's words.
from_zip : Zip.ExtractError -> Opc.OpenError
from_zip = |err|
	match err {
		InvalidSignature => InvalidSignature
		TruncatedArchive => TruncatedArchive
		InvalidFilename => InvalidFilename
		CompressionNotSupported(method) => CompressionNotSupported(method)
		CrcMismatch(mismatch) => CrcMismatch(mismatch)
		InvalidCompressedData(message) => InvalidCompressedData(message)
		DuplicatePath(name) => DuplicatePart(name)
		EntryTooLarge({ path, declared, max_bytes: _ }) => PartTooLarge({ name: path, bytes: declared })
		SizeMismatch({ path, declared }) => PartSizeMismatch({ name: path, declared })
	}

# Errors from inflating an indexed part. Inflation reads no headers, so the
# signature, file name and duplicate errors cannot occur, and its limit is the
# part's own declared size, so neither can `EntryTooLarge`; each maps to the
# nearest error that can.
from_entry : Str, Zip.ExtractError -> Opc.PartError
from_entry = |name, err|
	match err {
		CompressionNotSupported(method) => CompressionNotSupported(method)
		CrcMismatch(mismatch) => CrcMismatch(mismatch)
		InvalidCompressedData(message) => InvalidCompressedData(message)
		SizeMismatch({ path: _, declared }) => PartSizeMismatch({ name, declared })
		EntryTooLarge({ path: _, declared, max_bytes: _ }) => PartSizeMismatch({ name, declared })
		InvalidSignature => TruncatedArchive
		TruncatedArchive => TruncatedArchive
		InvalidFilename => TruncatedArchive
		DuplicatePath(_) => TruncatedArchive
	}

# A source's relationships; none when it has no relationship part.
relationships_of : Opc.Package, Str -> Try(List(Opc.Relationship), Opc.RelationshipsError)
relationships_of = |pkg, source|
	if pkg.index.contains(ascii_lowercase(relationships_part_name(source))) {
		Opc.relationships(pkg, source)
	} else {
		Ok([])
	}

# The source a relationship part belongs to, spelled as the part is: `/_rels/.rels`
# to `/` and `/word/_rels/document.xml.rels` to `/word/document.xml`.
source_of : Str -> Try(Str, [NotRelationships])
source_of = |name| {
	{ directory, file } = split_name(name)
	if is_relationships_part(ascii_lowercase(name)) {
		Ok("${drop_last_bytes(directory, 6)}${drop_last_bytes(file, 5)}")
	} else {
		Err(NotRelationships)
	}
}

# ASCII suffixes only, so the rest stays valid UTF-8.
drop_last_bytes : Str, U64 -> Str
drop_last_bytes = |text, count| Str.from_utf8_lossy(text.to_utf8().drop_last(count))

# One step of a writer: a generated part, the relationship part of a source,
# or the next part the caller adds.
Step : [Generated(Zip.ZipEntry), Relationships({ source : Str, relationships : List(Opc.Relationship) }), Part(Str)]

is_part : Step -> Bool
is_part = |step|
	match step {
		Part(_) => Bool.True
		_ => Bool.False
	}

# The archive entry a step writes. A part's entry comes from its content,
# which `finish` does not have.
entry_for : Step, Try(Opc.Content, [NoContent]) -> Try([Content(Zip.ZipEntry), Copied(Zip.Compressed)], Opc.WriteError)
entry_for = |step, content|
	match step {
		Generated(entry) => Ok(Content(entry))
		Relationships({ source, relationships }) =>
			Ok(Content({ path: zip_path(relationships_part_name(source)), content: relationships_xml(source, relationships).to_utf8() }))
		Part(name) =>
			match content {
				Ok(Bytes(bytes)) => Ok(Content({ path: zip_path(name), content: bytes }))
				Ok(Copied(pkg)) => {
					located = find(pkg, name)?
					Ok(Copied(Zip.compressed(pkg.archive, located.entry) ? |err| from_copy(name, err)))
				}
				Err(NoContent) => Err(NotWritten(name))
			}
	}

# A part's path in the archive is its name without the leading slash.
zip_path : Str -> Str
zip_path = |name| Str.drop_prefix(name, "/")

# Names were checked when the writer started, so the ZIP layer refuses none;
# each refusal maps to the check that covers it.
from_create : Zip.CreateError -> Opc.WriteError
from_create = |err|
	match err {
		EmptyPath(path) => InvalidPartName(path)
		PathTooLong(path) => InvalidPartName(path)
		DuplicatePath(path) => DuplicatePart(path)
	}

# Reading stored bytes fails only when the archive ends early or a stored
# entry's sizes disagree.
from_copy : Str, Zip.ExtractError -> Opc.WriteError
from_copy = |name, err|
	match err {
		SizeMismatch({ path: _, declared }) => PartSizeMismatch({ name, declared })
		_ => TruncatedArchive
	}

# Every check that can fail on a graph: names the conventions allow, text XML
# can carry, valid relationships, and no two written parts, generated or not,
# whose names differ only in ASCII case.
check_graph : Opc.Graph -> Try({}, Opc.WriteError)
check_graph = |package_graph| {
	check_relationships("/", package_graph.relationships)?
	var $names = Set.with_capacity(2 * package_graph.parts.len() + 2)
	$names = $names.insert(ascii_lowercase("/${content_types_path}"))
	if !package_graph.relationships.is_empty() {
		$names = $names.insert(relationships_part_name("/"))
	}
	for part in package_graph.parts {
		if !is_part_name(part.name) {
			return Err(InvalidPartName(part.name))
		}
		if part.content_type.is_empty() or !is_xml_text(part.content_type) {
			return Err(InvalidContentType(part.name))
		}
		check_relationships(part.name, part.relationships)?
		$names = claim($names, part.name)?
		if !part.relationships.is_empty() {
			$names = claim($names, relationships_part_name(part.name))?
		}
	}
	Ok({})
}

claim : Set(Str), Str -> Try(Set(Str), Opc.WriteError)
claim = |names, name| {
	key = ascii_lowercase(name)
	if names.contains(key) {
		Err(DuplicatePart(name))
	} else {
		Ok(names.insert(key))
	}
}

# Identifiers are XML names, unique within their source; types and targets
# are text XML can carry, and an internal target is a part name.
check_relationships : Str, List(Opc.Relationship) -> Try({}, Opc.WriteError)
check_relationships = |source, relationships| {
	var $ids = Set.with_capacity(relationships.len())
	for rel in relationships {
		target_ok = match rel.mode {
			Internal => is_part_name(rel.target)
			External => !rel.target.is_empty() and is_xml_text(rel.target)
		}
		if !is_ncname(rel.id) or !is_xml_text(rel.kind) or !target_ok {
			return Err(InvalidRelationship({ source, id: rel.id }))
		}
		if $ids.contains(rel.id) {
			return Err(DuplicateRelationshipId({ source, id: rel.id }))
		}
		$ids = $ids.insert(rel.id)
	}
	Ok({})
}

# A part name the conventions allow and a ZIP entry can hold: absolute, with
# segments that are not empty and do not end in a dot, and no control
# characters or backslashes.
is_part_name : Str -> Bool
is_part_name = |name| {
	bytes = name.to_utf8()
	segments = name.split_on("/").drop_first(1)
	name.starts_with("/")
		and bytes.len() <= 65_536
		and bytes.all(|byte| byte >= 0x20 and byte != '\\')
		and segments.all(|segment| !segment.is_empty() and !segment.ends_with("."))
}

# XML 1.0 carries no control characters other than tab, line feed and
# carriage return.
is_xml_text : Str -> Bool
is_xml_text = |text| text.to_utf8().all(|byte| byte >= 0x20 or byte == '\t' or byte == '\n' or byte == '\r')

# An XML name without a colon, as relationship identifiers must be. Every
# byte of a non-ASCII character is taken as a name character.
is_ncname : Str -> Bool
is_ncname = |text| {
	bytes = text.to_utf8()
	match bytes.first() {
		Ok(first) => is_name_start(first) and bytes.drop_first(1).all(|byte| is_name_start(byte) or (byte >= '0' and byte <= '9') or byte == '-' or byte == '.')
		Err(_) => Bool.False
	}
}

is_name_start : U8 -> Bool
is_name_start = |byte| (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or byte == '_' or byte >= 0x80

# The parts in the order `Opc.writer` documents: the package's relationship
# targets breadth first from the main document, then the parts nothing
# reaches, with the parts that are not XML moved after the rest.
write_order : Opc.Graph -> List(Opc.GraphPart)
write_order = |package_graph| {
	parts = package_graph.parts
	var $index = Dict.with_capacity(parts.len())
	var $position = 0.U64
	for part in parts {
		$index = $index.insert(ascii_lowercase(part.name), $position)
		$position = $position + 1
	}
	main = package_graph.relationships.keep_if(|rel| rel.kind == Opc.officedocument_relationship and rel.mode == Internal)
	var $reached = reach({ order: List.with_capacity(parts.len()), seen: Set.with_capacity(parts.len()) }, $index, main.concat(package_graph.relationships))
	var $at = 0.U64
	while $at < $reached.order.len() {
		relationships = match $reached.order.get($at) {
			Ok(found) =>
				match parts.get(found) {
					Ok(part) => part.relationships
					Err(_) => []
				}
			Err(_) => []
		}
		$reached = reach($reached, $index, relationships)
		$at = $at + 1
	}
	var $order = $reached.order
	var $unreached = 0.U64
	for _part in parts {
		if !$reached.seen.contains($unreached) {
			$order = List.append($order, $unreached)
		}
		$unreached = $unreached + 1
	}
	ordered = $order.keep_oks(|found| parts.get(found))
	ordered.keep_if(|part| is_xml_type(part.content_type)).concat(ordered.drop_if(|part| is_xml_type(part.content_type)))
}

# Parts reached so far, by position in the graph, in the order reached.
Reached : { order : List(U64), seen : Set(U64) }

reach : Reached, Dict(Str, U64), List(Opc.Relationship) -> Reached
reach = |reached, index, relationships|
	relationships.fold(
		reached,
		|so_far, rel|
			if rel.mode == External {
				so_far
			} else {
				match index.get(ascii_lowercase(rel.target)) {
					Ok(found) =>
						if so_far.seen.contains(found) {
							so_far
						} else {
							{ order: List.append(so_far.order, found), seen: so_far.seen.insert(found) }
						}
					Err(_) => so_far
				}
			},
	)

# XML content types end in `xml`: `application/xml`, `text/xml` and the
# `+xml` types.
is_xml_type : Str -> Bool
is_xml_type = |content_type| ascii_lowercase(content_type).ends_with("xml")

relationships_content_type : Str
relationships_content_type = "application/vnd.openxmlformats-package.relationships+xml"

xml_declaration : Str
xml_declaration = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"

# `[Content_Types].xml` for parts in archive order: defaults for `rels` and
# `xml`, then one for each other extension, taken from the first part that
# has it; an override for every part its extension's default does not
# describe.
content_types_xml : List(Opc.GraphPart) -> Str
content_types_xml = |order| {
	var $defaults = List.with_capacity(8)
	$defaults = List.append($defaults, { extension: "rels", content_type: relationships_content_type })
	$defaults = List.append($defaults, { extension: "xml", content_type: "application/xml" })
	var $lookup = Dict.with_capacity(8)
	$lookup = $lookup.insert("rels", relationships_content_type)
	$lookup = $lookup.insert("xml", "application/xml")
	for part in order {
		extension = extension_of(ascii_lowercase(part.name))
		if is_extension(extension) and !$lookup.contains(extension) {
			$defaults = List.append($defaults, { extension, content_type: part.content_type })
			$lookup = $lookup.insert(extension, part.content_type)
		}
	}
	var $xml = Str.with_capacity(256 + 160 * order.len())
	$xml = Str.concat($xml, "${xml_declaration}<Types xmlns=\"${content_types_namespace}\">")
	for default in $defaults {
		$xml = Str.concat($xml, "<Default Extension=\"${escape(default.extension)}\" ContentType=\"${escape(default.content_type)}\"/>")
	}
	for part in order {
		extension = extension_of(ascii_lowercase(part.name))
		if !is_extension(extension) or $lookup.get(extension) != Ok(part.content_type) {
			$xml = Str.concat($xml, "<Override PartName=\"${escape(part.name)}\" ContentType=\"${escape(part.content_type)}\"/>")
		}
	}
	Str.concat($xml, "</Types>")
}

# An extension a default can name: not empty, and only the characters the
# content types schema allows in one.
is_extension : Str -> Bool
is_extension = |extension|
	!extension.is_empty()
		and extension.to_utf8().all(|byte| (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or (byte >= '0' and byte <= '9') or "!$&'()*+,:=@-_~%".to_utf8().contains(byte))

# A relationship part: the source's relationships in the order given.
relationships_xml : Str, List(Opc.Relationship) -> Str
relationships_xml = |source, relationships| {
	var $xml = Str.with_capacity(160 + 200 * relationships.len())
	$xml = Str.concat($xml, "${xml_declaration}<Relationships xmlns=\"${relationships_namespace}\">")
	for rel in relationships {
		{ target, mode } = match rel.mode {
			Internal => { target: relative_target(source, rel.target), mode: "" }
			External => { target: rel.target, mode: " TargetMode=\"External\"" }
		}
		$xml = Str.concat($xml, "<Relationship Id=\"${escape(rel.id)}\" Type=\"${escape(rel.kind)}\" Target=\"${escape(target)}\"${mode}/>")
	}
	Str.concat($xml, "</Relationships>")
}

# An internal target inside the source part's directory, relative to it; any
# other, or one whose first segment would read as a URI scheme, absolute.
relative_target : Str, Str -> Str
relative_target = |source, target| {
	directory = split_name(source).directory
	relative = Str.drop_prefix(target, directory)
	if target.starts_with(directory) and !relative.is_empty() and !relative.contains(":") {
		relative
	} else {
		target
	}
}

# Text in a double-quoted attribute value. Tab, line feed and carriage return
# are written as references, so that attribute normalization keeps them.
escape : Str -> Str
escape = |text|
	text
		.replace_each("&", "&amp;")
		.replace_each("<", "&lt;")
		.replace_each(">", "&gt;")
		.replace_each("\"", "&quot;")
		.replace_each("\t", "&#9;")
		.replace_each("\n", "&#10;")
		.replace_each("\r", "&#13;")

# Append a chunk, at least doubling the capacity when the output must grow,
# so that a package of many parts is not copied once per part.
append_chunk : List(U8), List(U8) -> List(U8)
append_chunk = |out, chunk| {
	room = if (out.capacity() - out.len() >= chunk.len()) out else out.reserve(chunk.len().max(out.len()))
	List.concat(room, chunk)
}

# A relationship part sits in a `_rels` directory and has the `.rels` extension.
is_relationships_part : Str -> Bool
is_relationships_part = |key| {
	{ directory, file } = split_name(key)
	directory.ends_with("/_rels/") and file.ends_with(".rels")
}

content_types_path : Str
content_types_path = "[Content_Types].xml"

content_types_key : Str
content_types_key = "[content_types].xml"

# [Content_Types].xml keyed for lookup: overrides by part name and defaults
# by extension, both in lower case, with the first of any repeated key
# winning.
IndexedContentTypes : { defaults : Dict(Str, Str), overrides : Dict(Str, Str) }

parse_content_types : List(U8), Limits -> Try(IndexedContentTypes, Opc.OpenError)
parse_content_types = |bytes, limits| {
	root = XmlTree.parse(bytes, limits) ? ContentTypesNotXml
	if !is_named(root, content_types_namespace, "Types") {
		return Err(ContentTypesRootIsNotTypes)
	}
	var $defaults = Dict.with_capacity(8)
	var $overrides = Dict.with_capacity(8)
	for node in children_of(root) {
		if is_named(node, content_types_namespace, "Default") {
			extension = ascii_lowercase(attribute(node, { part: content_types_path, element: "Default", attribute: "Extension" })?)
			content_type = attribute(node, { part: content_types_path, element: "Default", attribute: "ContentType" })?
			if !$defaults.contains(extension) {
				$defaults = $defaults.insert(extension, content_type)
			}
		} else if is_named(node, content_types_namespace, "Override") {
			key = ascii_lowercase(attribute(node, { part: content_types_path, element: "Override", attribute: "PartName" })?)
			content_type = attribute(node, { part: content_types_path, element: "Override", attribute: "ContentType" })?
			if !$overrides.contains(key) {
				$overrides = $overrides.insert(key, content_type)
			}
		}
	}
	Ok({ defaults: $defaults, overrides: $overrides })
}

# An override names the part; otherwise its extension selects a default. The
# key is the part name in lower case.
content_type_for : IndexedContentTypes, Str, Str -> Try(Str, Opc.OpenError)
content_type_for = |types, name, key|
	match types.overrides.get(key) {
		Ok(content_type) => Ok(content_type)
		Err(_) => Ok(types.defaults.get(extension_of(key)) ? |_| NoContentType(name))
	}

content_types_namespace : Str
content_types_namespace = "http://schemas.openxmlformats.org/package/2006/content-types"

relationships_namespace : Str
relationships_namespace = "http://schemas.openxmlformats.org/package/2006/relationships"

# An element of the namespace with the local name, whatever its prefix.
is_named : XmlTree.Node, Str, Str -> Bool
is_named = |node, namespace, local|
	match node {
		Element(element) => element.name.namespace == Uri(namespace) and element.name.local == local
		Text(_) => Bool.False
	}

# An element's children in document order; text has none.
children_of : XmlTree.Node -> List(XmlTree.Node)
children_of = |node|
	match node {
		Element(element) => element.children
		Text(_) => []
	}

# An unprefixed attribute of an element, which is in no namespace.
attribute : XmlTree.Node, Opc.AttributeLocation -> Try(Str, [MissingAttribute(Opc.AttributeLocation)])
attribute = |node, location|
	match node {
		Element(element) =>
			match element.attributes.find_first(|candidate| candidate.name.namespace == NoNamespace and candidate.name.local == location.attribute) {
				Ok(found) => Ok(found.value)
				Err(_) => Err(MissingAttribute(location))
			}

		Text(_) => Err(MissingAttribute(location))
	}

# `/word/document.xml` has its relationships in `/word/_rels/document.xml.rels`;
# the package itself has them in `/_rels/.rels`.
relationships_part_name : Str -> Str
relationships_part_name = |source|
	if source == "/" {
		"/_rels/.rels"
	} else {
		{ directory, file } = split_name(source)
		"${directory}_rels/${file}.rels"
	}

# Resolve a relationship target against its source part's directory and
# collapse `.` and `..` segments, so a target never escapes the package.
resolve_target : Str, Str -> Str
resolve_target = |source, target| {
	base = if (target.starts_with("/")) target else "${split_name(source).directory}${target}"
	var $segments = List.with_capacity(8)
	for segment in base.split_on("/") {
		if segment == "" or segment == "." {
			{}
		} else if segment == ".." {
			$segments = List.drop_last($segments, 1)
		} else {
			$segments = List.append($segments, segment)
		}
	}
	"/${Str.join_with($segments, "/")}"
}

# The directory of a part name, with its trailing slash, and the file name.
split_name : Str -> { directory : Str, file : Str }
split_name = |name|
	match name.split_last("/") {
		Ok({ before, after }) => { directory: "${before}/", file: after }
		Err(NotFound) => { directory: "", file: name }
	}

# The extension of a part name's file name, without the dot; empty when there is none.
extension_of : Str -> Str
extension_of = |name|
	match split_name(name).file.split_last(".") {
		Ok({ before: _, after }) => after
		Err(NotFound) => ""
	}

# Part names and extensions compare without regard to ASCII case; the
# builtins have no case mapping. Text already in lower case, as most part
# names are, is returned without a copy.
ascii_lowercase : Str -> Str
ascii_lowercase = |text| {
	bytes = text.to_utf8()
	if bytes.any(|byte| byte >= 'A' and byte <= 'Z') {
		Str.from_utf8_lossy(bytes.map(|byte| if (byte >= 'A' and byte <= 'Z') byte + 32 else byte))
	} else {
		text
	}
}

## Extensions follow the file name's last dot and are empty without one.
expect {
	actual =
		\\${extension_of("/word/document.xml")}
		\\${extension_of("/_rels/.rels")}
		\\${extension_of("/word/media/image1")}
		\\${ascii_lowercase("XML.Rels")}
	expected =
		\\xml
		\\rels
		\\
		\\xml.rels
	actual == expected
}

## The content types part is found by its name in lower case.
expect ascii_lowercase(content_types_path) == content_types_key

## Relationship parts sit in a `_rels` directory beside their source.
expect relationships_part_name("/") == "/_rels/.rels"

## Relationship parts take the source's file name with a `.rels` suffix.
expect relationships_part_name("/word/document.xml") == "/word/_rels/document.xml.rels"

## Targets resolve against the source directory and never escape the root.
expect {
	actual =
		\\${resolve_target("/word/document.xml", "styles.xml")}
		\\${resolve_target("/word/document.xml", "../docProps/core.xml")}
		\\${resolve_target("/", "word/document.xml")}
		\\${resolve_target("/word/document.xml", "/word/media/image1.png")}
		\\${resolve_target("/word/document.xml", "../../../etc/passwd")}
	expected =
		\\/word/styles.xml
		\\/docProps/core.xml
		\\/word/document.xml
		\\/word/media/image1.png
		\\/etc/passwd
	actual == expected
}

# A minimal package: the three parts every WordprocessingML document has,
# with the main document's content given.
sample_with : Str, Zip.Compression -> Try(List(U8), [EmptyPath(Str), PathTooLong(Str), DuplicatePart(Str)])
sample_with = |document, compression|
	archive_of(
		[
			{ path: content_types_path, content: sample_content_types.to_utf8() },
			{ path: "_rels/.rels", content: sample_rels.to_utf8() },
			{ path: "word/document.xml", content: document.to_utf8() },
		],
		compression,
	)

sample_archive : Try(List(U8), [EmptyPath(Str), PathTooLong(Str), DuplicatePart(Str)])
sample_archive = sample_with(sample_document, None)

archive_of : List(Zip.ZipEntry), Zip.Compression -> Try(List(U8), [EmptyPath(Str), PathTooLong(Str), DuplicatePart(Str)])
archive_of = |entries, compression|
	match Zip.create(entries, compression) {
		Ok(archive) => Ok(archive)
		Err(EmptyPath(path)) => Err(EmptyPath(path))
		Err(PathTooLong(path)) => Err(PathTooLong(path))
		Err(DuplicatePath(path)) => Err(DuplicatePart(path))
	}

# Opening with the package reduced to its parts, which compare.
open_parts : List(U8), Limits -> Try(List(Opc.Part), Opc.OpenError)
open_parts = |bytes, limits| Opc.open(bytes, limits).map_ok(Opc.parts)

# A document that inflates to far more than it compresses to.
compressible_document : Str
compressible_document = "<w:document xmlns:w='http://schemas.openxmlformats.org/wordprocessingml/2006/main'><w:body>${Str.repeat("<w:p/>", 1000)}</w:body></w:document>"

sample_content_types : Str
sample_content_types = "<?xml version='1.0' encoding='UTF-8'?><Types xmlns='http://schemas.openxmlformats.org/package/2006/content-types'><Default Extension='RELS' ContentType='application/vnd.openxmlformats-package.relationships+xml'/><Default Extension='xml' ContentType='application/xml'/><Override PartName='/word/document.xml' ContentType='application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml'/></Types>"

sample_rels : Str
sample_rels = "<Relationships xmlns='http://schemas.openxmlformats.org/package/2006/relationships'><Relationship Id='rId1' Type='http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument' Target='word/document.xml'/></Relationships>"

sample_document : Str
sample_document = "<w:document xmlns:w='http://schemas.openxmlformats.org/wordprocessingml/2006/main'><w:body><w:p><w:r><w:t>Hello</w:t></w:r></w:p></w:body></w:document>"

## The sample package opens, resolves its main document and labels every part.
expect {
	pkg = Opc.open(sample_archive?, {})?
	main_part = Opc.main_document(pkg)?
	rels = Opc.part(pkg, "/_rels/.rels")?
	actual =
		\\main: ${main_part.name}
		\\main type: ${main_part.content_type}
		\\rels type: ${rels.content_type}
		\\parts: ${Opc.parts(pkg).len().to_str()}
	expected =
		\\main: /word/document.xml
		\\main type: application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml
		\\rels type: application/vnd.openxmlformats-package.relationships+xml
		\\parts: 2
	actual == expected
}

## Package relationships resolve their targets to absolute part names.
expect {
	pkg = Opc.open(sample_archive?, {})?
	Opc.relationships(pkg, "/")? == [{ id: "rId1", kind: Opc.officedocument_relationship, target: "/word/document.xml", mode: Internal }]
}

## Content types and relationships written with prefixes of the producer's
## choosing are read by namespace, just as unprefixed ones are.
expect {
	content_types = "<ct:Types xmlns:ct='${content_types_namespace}'><ct:Default Extension='rels' ContentType='${relationships_content_type}'/><ct:Override PartName='/word/document.xml' ContentType='${main_content_type}'/></ct:Types>"
	rels = "<pr:Relationships xmlns:pr='${relationships_namespace}'><pr:Relationship Id='rId1' Type='${Opc.officedocument_relationship}' Target='word/document.xml'/></pr:Relationships>"
	archive = archive_of([{ path: content_types_path, content: content_types.to_utf8() }, { path: "_rels/.rels", content: rels.to_utf8() }, { path: "word/document.xml", content: sample_document.to_utf8() }], None)?
	pkg = Opc.open(archive, {})?
	Opc.main_document(pkg)? == { name: "/word/document.xml", content_type: main_content_type, size: sample_document.to_utf8().len() }
}

## Elements are matched by namespace: a `Types` root outside the content
## types namespace is not the content types part, and relationships outside
## theirs are not relationships.
expect {
	foreign_types = archive_of([{ path: content_types_path, content: "<Types xmlns='urn:other'/>".to_utf8() }], None)?
	foreign_rels = archive_of([{ path: content_types_path, content: sample_content_types.to_utf8() }, { path: "_rels/.rels", content: "<Relationships xmlns='${relationships_namespace}'><Relationship xmlns='urn:other' Id='rId1' Type='t' Target='a.xml'/></Relationships>".to_utf8() }], None)?
	open_parts(foreign_types, {}) == Err(ContentTypesRootIsNotTypes) and Opc.relationships(Opc.open(foreign_rels, {})?, "/")? == []
}

## Package parts are read within the XML bounds of the limits, and an XML
## error names the part and where reading stopped.
expect {
	opened = Opc.open(sample_archive?, { max_xml_elements: 3 })
	rels = archive_of([{ path: content_types_path, content: sample_content_types.to_utf8() }, { path: "_rels/.rels", content: "<Relationships xmlns='${relationships_namespace}'>\n<Relationship".to_utf8() }], None)?
	broken_at_line_two = match Opc.relationships(Opc.open(rels, {})?, "/") {
		Err(RelationshipsNotXml({ part: "/_rels/.rels", problem: MalformedXml({ message: _, line: 2, column: _ }) })) => Bool.True
		_ => Bool.False
	}
	opened.map_ok(|_| {}) == Err(ContentTypesNotXml(TooManyXmlElements({ max: 3, line: 1, column: 269 }))) and broken_at_line_two
}

## Bytes that are not an archive are an error, never a crash.
expect Opc.open([], {}).is_ok() == Bool.False

## The entry limit is checked before parts are read.
expect open_parts(sample_archive?, { max_entries: 2, max_part_bytes: 10_000, max_total_bytes: 10_000 }) == Err(TooManyEntries(3))

## The part limit names the first part that exceeds it.
expect open_parts(sample_archive?, { max_entries: 10, max_part_bytes: 10, max_total_bytes: 10_000 }) == Err(PartTooLarge({ name: content_types_path, bytes: sample_content_types.to_utf8().len() }))

## The total limit applies to the archive before anything is decompressed.
expect {
	archive = sample_archive?
	open_parts(archive, { max_entries: 10, max_part_bytes: 10_000, max_total_bytes: 100 }) == Err(PackageTooLarge(archive.len()))
}

## A part's declared size is checked against the part limit before it is inflated.
expect {
	archive = sample_with(compressible_document, Balanced)?
	declared = compressible_document.to_utf8().len()
	archive.len() < 1_000 and open_parts(archive, { max_part_bytes: 1_000 }) == Err(PartTooLarge({ name: "word/document.xml", bytes: declared }))
}

## The declared sizes' running total is checked against the total limit before anything is inflated.
expect {
	archive = sample_with(compressible_document, Balanced)?
	total = sample_content_types.to_utf8().len() + sample_rels.to_utf8().len() + compressible_document.to_utf8().len()
	open_parts(archive, { max_total_bytes: 2_000 }) == Err(PackageTooLarge(total))
}

## Part names that differ only in ASCII case name the same part.
expect {
	archive = archive_of(
		[
			{ path: content_types_path, content: sample_content_types.to_utf8() },
			{ path: "word/document.xml", content: sample_document.to_utf8() },
			{ path: "Word/Document.XML", content: sample_document.to_utf8() },
		],
		None,
	)?
	open_parts(archive, {}) == Err(DuplicatePart("Word/Document.XML"))
}

## A part is inflated on demand and found without regard to case.
expect {
	pkg = Opc.open(sample_with(compressible_document, Balanced)?, {})?
	Opc.part_bytes(pkg, "/WORD/document.xml")? == compressible_document.to_utf8() and Opc.part_bytes(pkg, "/word/missing.xml") == Err(MissingPart("/word/missing.xml"))
}

## A part's stored bytes come with the method and sizes they were stored with.
expect {
	pkg = Opc.open(sample_archive?, {})?
	stored = Opc.stored(pkg, "/word/document.xml")?
	size = sample_document.to_utf8().len()
	stored.method == Stored and stored.bytes == sample_document.to_utf8() and stored.compressed_size == size and stored.uncompressed_size == size
}

# A package written back from its own graph with every part copied.
rewrite : Opc.Package -> Try(List(U8), [RewriteFailed])
rewrite = |pkg| {
	package_graph = Opc.graph(pkg) ? |_| RewriteFailed
	Ok(Opc.to_bytes(package_graph, |_| Copied(pkg)) ? |_| RewriteFailed)
}

# The paths of an archive's entries, in archive order.
paths_of : List(U8) -> List(Str)
paths_of = |archive|
	match Zip.entries(archive) {
		Ok(entries) => entries.map(|entry| entry.path)
		Err(_) => []
	}

relationship : Str, Str, Str -> Opc.Relationship
relationship = |id, kind, target| { id, kind, target, mode: Internal }

kind_of : Str -> Str
kind_of = |name| "http://schemas.openxmlformats.org/officeDocument/2006/relationships/${name}"

main_content_type : Str
main_content_type = "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"

# A graph listing its parts out of archive order: an image the document
# links to, a part nothing reaches, the styles and the main document.
scrambled_graph : Opc.Graph
scrambled_graph = {
	relationships: [relationship("rId2", kind_of("extended-properties"), "/docProps/app.xml"), relationship("rId1", Opc.officedocument_relationship, "/word/document.xml")],
	parts: [
		{ name: "/word/media/image1.png", content_type: "image/png", relationships: [] },
		{ name: "/customXml/item1.xml", content_type: "application/xml", relationships: [] },
		{ name: "/docProps/app.xml", content_type: "application/vnd.openxmlformats-officedocument.extended-properties+xml", relationships: [] },
		{ name: "/word/styles.xml", content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml", relationships: [] },
		{
			name: "/word/document.xml",
			content_type: main_content_type,
			relationships: [
				relationship("rId1", kind_of("styles"), "/word/styles.xml"),
				relationship("rId2", kind_of("image"), "/word/media/image1.png"),
				{ id: "rId3", kind: kind_of("hyperlink"), target: "https://example.com/?a=1&b=2", mode: External },
			],
		},
	],
}

# Each part's content is its own name.
named_content : Str -> Opc.Content
named_content = |name| Bytes(name.to_utf8())

## The archive holds the generated parts first, then the main document and
## its relationships, the parts reached from the package, the part nothing
## reaches, and the image last.
expect {
	written = Opc.to_bytes(scrambled_graph, named_content)?
	paths_of(written)
		== [
			"[Content_Types].xml",
			"_rels/.rels",
			"word/document.xml",
			"word/_rels/document.xml.rels",
			"docProps/app.xml",
			"word/styles.xml",
			"customXml/item1.xml",
			"word/media/image1.png",
		]
}

## Content types take defaults for `rels`, `xml` and each other extension's
## first part, and override every part those do not describe.
expect {
	actual = content_types_xml(write_order(scrambled_graph))
	expected = Str.join_with(
		[
			"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>",
			"<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">",
			"<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>",
			"<Default Extension=\"xml\" ContentType=\"application/xml\"/>",
			"<Default Extension=\"png\" ContentType=\"image/png\"/>",
			"<Override PartName=\"/word/document.xml\" ContentType=\"${main_content_type}\"/>",
			"<Override PartName=\"/docProps/app.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.extended-properties+xml\"/>",
			"<Override PartName=\"/word/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\"/>",
			"</Types>",
		],
		"",
	)
	actual == expected
}

## Internal targets are written relative to the source's directory, external
## ones as given, and both escaped.
expect {
	document = scrambled_graph.parts.last()?
	actual = relationships_xml(document.name, document.relationships)
	expected = Str.join_with(
		[
			"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>",
			"<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">",
			"<Relationship Id=\"rId1\" Type=\"${kind_of("styles")}\" Target=\"styles.xml\"/>",
			"<Relationship Id=\"rId2\" Type=\"${kind_of("image")}\" Target=\"media/image1.png\"/>",
			"<Relationship Id=\"rId3\" Type=\"${kind_of("hyperlink")}\" Target=\"https://example.com/?a=1&amp;b=2\" TargetMode=\"External\"/>",
			"</Relationships>",
		],
		"",
	)
	actual == expected
}

## A target outside the source's directory, or one that would read as a URI
## scheme, stays absolute.
expect {
	actual =
		\\${relative_target("/", "/word/document.xml")}
		\\${relative_target("/word/document.xml", "/docProps/core.xml")}
		\\${relative_target("/word/document.xml", "/word/a:b.xml")}
	expected =
		\\word/document.xml
		\\/docProps/core.xml
		\\/word/a:b.xml
	actual == expected
}

## A written package opens to the same parts, contents and relationships.
expect {
	pkg = Opc.open(Opc.to_bytes(scrambled_graph, named_content)?, {})?
	document = Opc.main_document(pkg)?
	Opc.graph(pkg)? == { relationships: scrambled_graph.relationships, parts: write_order(scrambled_graph) }
		and document.content_type == main_content_type
		and Opc.part_bytes(pkg, "/word/media/image1.png")? == "/word/media/image1.png".to_utf8()
}

## The chunks of `add` and `finish`, concatenated, are the bytes of `to_bytes`.
expect {
	started = Opc.writer(scrambled_graph)?
	var $w = started
	var $chunks = List.with_capacity(1024)
	for name in Opc.pending(started) {
		added = Opc.add($w, named_content(name))?
		$chunks = List.concat($chunks, added.chunk)
		$w = added.writer
	}
	List.concat($chunks, Opc.finish($w)?) == Opc.to_bytes(scrambled_graph, named_content)?
}

## Copied parts keep their stored bytes, method, CRC and sizes, and writing
## the same package twice gives the same bytes.
expect {
	source = Opc.open(sample_with(compressible_document, Balanced)?, {})?
	written = rewrite(source)?
	copy = Opc.open(written, {})?
	stored = Opc.stored(copy, "/word/document.xml")?
	stored == Opc.stored(source, "/word/document.xml")? and stored.method == Deflated and rewrite(copy)? == written
}

## A relationship part with no relationships, or with no source part, stays
## an ordinary part and is copied like one.
expect {
	archive = archive_of(
		[
			{ path: content_types_path, content: sample_content_types.to_utf8() },
			{ path: "_rels/.rels", content: sample_rels.to_utf8() },
			{ path: "word/document.xml", content: sample_document.to_utf8() },
			{ path: "word/_rels/document.xml.rels", content: "<Relationships xmlns='http://schemas.openxmlformats.org/package/2006/relationships'/>".to_utf8() },
			{ path: "word/_rels/missing.xml.rels", content: sample_rels.to_utf8() },
		],
		None,
	)?
	source = Opc.open(archive, {})?
	package_graph = Opc.graph(source)?
	copy = Opc.open(rewrite(source)?, {})?
	package_graph.parts.map(|part| part.name) == ["/word/document.xml", "/word/_rels/document.xml.rels", "/word/_rels/missing.xml.rels"]
		and Opc.stored(copy, "/word/_rels/document.xml.rels")? == Opc.stored(source, "/word/_rels/document.xml.rels")?
}

# The result of starting a writer on a graph of one part.
write_one : Opc.GraphPart -> Try({}, Opc.WriteError)
write_one = |part| Opc.writer({ relationships: [], parts: [part] }).map_ok(|_| {})

# An XML part with no relationships.
plain_part : Str -> Opc.GraphPart
plain_part = |name| { name, content_type: "application/xml", relationships: [] }

## Part names must be absolute, with segments that are not empty and do not
## end in a dot.
expect {
	names = ["word/document.xml", "/", "/word//document.xml", "/word/./document.xml", "/word/document.", "/word\\document.xml"]
	names.all(|name| write_one(plain_part(name)) == Err(InvalidPartName(name)))
}

## Relationship identifiers are XML names, unique within their source, and
## internal targets are part names.
expect {
	with_relationships = |rels| write_one({ name: "/a.xml", content_type: "application/xml", relationships: rels })
	with_relationships([relationship("1", "t", "/b.xml")]) == Err(InvalidRelationship({ source: "/a.xml", id: "1" }))
		and with_relationships([relationship("rId1", "t", "/")]) == Err(InvalidRelationship({ source: "/a.xml", id: "rId1" }))
		and with_relationships([relationship("rId1", "t", "/b.xml"), relationship("rId1", "t", "/c.xml")]) == Err(DuplicateRelationshipId({ source: "/a.xml", id: "rId1" }))
}

## Names that written parts would share without regard to case are refused,
## the generated parts' names included.
expect {
	two = Opc.writer({ relationships: [], parts: [plain_part("/a.xml"), plain_part("/A.XML")] }).map_ok(|_| {})
	package_rels = Opc.writer({ relationships: [relationship("rId1", "t", "/a.xml")], parts: [plain_part("/_rels/.rels")] }).map_ok(|_| {})
	two == Err(DuplicatePart("/A.XML"))
		and write_one(plain_part("/[content_types].xml")) == Err(DuplicatePart("/[content_types].xml"))
		and package_rels == Err(DuplicatePart("/_rels/.rels"))
}

## A writer takes exactly its pending parts: finishing before one is added
## and adding past the last are errors.
expect {
	started = Opc.writer({ relationships: [], parts: [plain_part("/a.xml")] })?
	added = Opc.add(started, Bytes([]))?
	Opc.finish(started) == Err(NotWritten("/a.xml"))
		and Opc.add(added.writer, Bytes([])).map_ok(|_| {}) == Err(NothingPending)
		and Opc.pending(started) == ["/a.xml"]
		and Opc.pending(added.writer) == []
}
