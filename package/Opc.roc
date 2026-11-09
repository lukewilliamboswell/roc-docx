## Open Packaging Conventions (ECMA-376 Part 2): the parts, content types and
## relationships of a package, read from a ZIP archive within explicit limits.
##
## Part names are absolute, such as `/word/document.xml`, and compare without
## regard to ASCII case, as the conventions require. An opened package keeps
## the archive and an index of its parts, and inflates a part when it is asked
## for. Relationships are parsed from the source part's `_rels` part on demand
## and their targets are resolved against the source part. Element names in
## the package parts are matched as written and unprefixed, which is how every
## producer writes them; namespace-aware matching arrives with the XML kernel
## slice.
import zip.Zip
import parser.Xml
import Limits

Opc :: [].{

	## A part of the package: its name as the archive spells it, its content
	## type, and the decompressed size its entry declares, which opening
	## checked against the limits.
	Part : { name : Str, content_type : Str, size : U64 }

	## An opened package: the archive bytes and its parts with an index by
	## name, the relationship parts inflated and the rest as they are stored.
	## `[Content_Types].xml` is consumed to label the parts and is not one of
	## them.
	Package :: {
		archive : List(U8),
		parts : List(Located),
		index : Dict(Str, U64),
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

	## Where a part's XML is malformed: one-based line and column, and the
	## parser's message.
	XmlProblem : { line : U64, column : U64, message : Str }

	## An attribute a package part must have and does not.
	AttributeLocation : { part : Str, element : Str, attribute : Str }

	## Why a package cannot be opened: the ZIP layer's own archive errors, two
	## parts with the same name, a part whose content is not the size its
	## entry declares, the limit that was exceeded, or what is wrong with
	## `[Content_Types].xml`.
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
		ContentTypesNotUtf8,
		ContentTypesNotXml(XmlProblem),
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

	RelationshipsError : [
		MissingPart(Str),
		RelationshipsNotUtf8(Str),
		RelationshipsNotXml({ part : Str, problem : XmlProblem }),
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
		types = index_content_types(parse_content_types(inflate(bytes, types_entry) ? from_zip)?)
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
		Ok({ archive: bytes, parts: $parts, index: $index })
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
		text = Str.from_utf8(bytes) ? |_| RelationshipsNotUtf8(rels_name)
		xml = Xml.parse_str(text) ? |err| match err {
			InvalidXml(problem) => RelationshipsNotXml({ part: rels_name, problem })
		}
		var $found = List.with_capacity(8)
		for node in xml.root.children_named("Relationship") {
			id = attribute(node, { part: rels_name, element: "Relationship", attribute: "Id" })?
			kind = attribute(node, { part: rels_name, element: "Relationship", attribute: "Type" })?
			target = attribute(node, { part: rels_name, element: "Relationship", attribute: "Target" })?
			mode = match node.attribute("TargetMode") {
				Ok("External") => External
				_ => Internal
			}
			resolved = match mode {
				External => target
				Internal => resolve_target(source, target)
			}
			$found = List.append($found, { id, kind, target: resolved, mode })
		}
		Ok($found)
	}

	## The main document part: the target of the package's `officeDocument`
	## relationship, wherever the producer placed it.
	main_document : Package -> Try(Part, [MissingPart(Str), RelationshipsNotUtf8(Str), RelationshipsNotXml({ part : Str, problem : XmlProblem }), MissingAttribute(AttributeLocation), NoMainDocument])
	main_document = |pkg| {
		rels = Opc.relationships(pkg, "/")?
		rel = rels.find_first(|candidate| candidate.kind == Opc.officedocument_relationship) ? |_| NoMainDocument
		Opc.part(pkg, rel.target)
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

# [Content_Types].xml: defaults by extension, overrides by part name.
ContentTypes : {
	defaults : List({ extension : Str, content_type : Str }),
	overrides : List({ part_name : Str, content_type : Str }),
}

parse_content_types : List(U8) -> Try(ContentTypes, Opc.OpenError)
parse_content_types = |bytes| {
	text = Str.from_utf8(bytes) ? |_| ContentTypesNotUtf8
	xml = Xml.parse_str(text) ? |err| match err {
		InvalidXml(problem) => ContentTypesNotXml(problem)
	}
	if xml.root.name() != Ok("Types") {
		return Err(ContentTypesRootIsNotTypes)
	}
	var $defaults = List.with_capacity(8)
	for node in xml.root.children_named("Default") {
		extension = attribute(node, { part: content_types_path, element: "Default", attribute: "Extension" })?
		content_type = attribute(node, { part: content_types_path, element: "Default", attribute: "ContentType" })?
		$defaults = List.append($defaults, { extension: ascii_lowercase(extension), content_type })
	}
	var $overrides = List.with_capacity(8)
	for node in xml.root.children_named("Override") {
		part_name = attribute(node, { part: content_types_path, element: "Override", attribute: "PartName" })?
		content_type = attribute(node, { part: content_types_path, element: "Override", attribute: "ContentType" })?
		$overrides = List.append($overrides, { part_name, content_type })
	}
	Ok({ defaults: $defaults, overrides: $overrides })
}

# The content types keyed for lookup: overrides by part name and defaults by
# extension, both in lower case, with the first of any repeated key winning.
IndexedContentTypes : { defaults : Dict(Str, Str), overrides : Dict(Str, Str) }

index_content_types : ContentTypes -> IndexedContentTypes
index_content_types = |types| {
	var $defaults = Dict.with_capacity(types.defaults.len())
	for default in types.defaults {
		if !$defaults.contains(default.extension) {
			$defaults = $defaults.insert(default.extension, default.content_type)
		}
	}
	var $overrides = Dict.with_capacity(types.overrides.len())
	for override in types.overrides {
		key = ascii_lowercase(override.part_name)
		if !$overrides.contains(key) {
			$overrides = $overrides.insert(key, override.content_type)
		}
	}
	{ defaults: $defaults, overrides: $overrides }
}

# An override names the part; otherwise its extension selects a default. The
# key is the part name in lower case.
content_type_for : IndexedContentTypes, Str, Str -> Try(Str, Opc.OpenError)
content_type_for = |types, name, key|
	match types.overrides.get(key) {
		Ok(content_type) => Ok(content_type)
		Err(_) => Ok(types.defaults.get(extension_of(key)) ? |_| NoContentType(name))
	}

attribute : Xml.Node, Opc.AttributeLocation -> Try(Str, [MissingAttribute(Opc.AttributeLocation)])
attribute = |node, location|
	Ok(node.attribute(location.attribute) ? |_| MissingAttribute(location))

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
