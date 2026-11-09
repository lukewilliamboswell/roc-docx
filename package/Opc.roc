## Open Packaging Conventions (ECMA-376 Part 2): the parts, content types and
## relationships of a package, read from a ZIP archive within explicit limits.
##
## Part names are absolute, such as `/word/document.xml`. Relationships are
## read from the source part's `_rels` part on demand and their targets are
## resolved against the source part. Element names in the package parts are
## matched as written and unprefixed, which is how every producer writes
## them; namespace-aware matching arrives with the XML kernel slice.
import zip.Zip
import parser.Xml
import Limits

Opc :: [].{

	## A part of the package with its content type and decompressed bytes.
	Part : { name : Str, content_type : Str, bytes : List(U8) }

	## An opened package: every part except `[Content_Types].xml`, which is
	## consumed to label the rest.
	Package : { parts : List(Part) }

	## One relationship of a source part. An internal target is an absolute
	## part name; an external target is kept as written.
	Relationship : { id : Str, kind : Str, target : Str, mode : [Internal, External] }

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

	RelationshipsError : [
		MissingPart(Str),
		RelationshipsNotUtf8(Str),
		RelationshipsNotXml({ part : Str, problem : XmlProblem }),
		MissingAttribute(AttributeLocation),
	]

	## The relationship type that names a package's main document part.
	officedocument_relationship : Str
	officedocument_relationship = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"

	## Open a package within the limits. The archive size is checked before
	## anything is decompressed. The ZIP layer then inflates every entry, and
	## the entry count and decompressed sizes are checked immediately after, so
	## a hostile archive that inflates far beyond its size is rejected only
	## once it has been inflated. Checking declared sizes before inflating each
	## entry needs a central-directory reader and is not yet implemented.
	open : List(U8), Limits -> Try(Package, OpenError)
	open = |bytes, limits| {
		if bytes.len() > limits.max_total_bytes {
			return Err(PackageTooLarge(bytes.len()))
		}
		entries = Zip.extract(bytes) ? |err| match err {
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
		if entries.len() > limits.max_entries {
			return Err(TooManyEntries(entries.len()))
		}
		var $total = 0.U64
		for entry in entries {
			if entry.content.len() > limits.max_part_bytes {
				return Err(PartTooLarge({ name: entry.path, bytes: entry.content.len() }))
			}
			$total = $total + entry.content.len()
			if $total > limits.max_total_bytes {
				return Err(PackageTooLarge($total))
			}
		}
		types_entry = entries.find_first(|entry| entry.path == content_types_path) ? |_| MissingContentTypes
		types = parse_content_types(types_entry.content)?
		var $parts = List.with_capacity(entries.len())
		for entry in entries {
			if entry.path != content_types_path and !entry.path.ends_with("/") {
				name = "/${entry.path}"
				content_type = content_type_for(types, name)?
				$parts = List.append($parts, { name, content_type, bytes: entry.content })
			}
		}
		Ok({ parts: $parts })
	}

	## The part with this absolute name.
	part : Package, Str -> Try(Part, [MissingPart(Str)])
	part = |pkg, name|
		Ok(pkg.parts.find_first(|candidate| candidate.name == name) ? |_| MissingPart(name))

	## The relationships of a source part, or of the package itself for `/`.
	relationships : Package, Str -> Try(List(Relationship), RelationshipsError)
	relationships = |pkg, source| {
		rels_name = relationships_part_name(source)
		rels = Opc.part(pkg, rels_name)?
		text = Str.from_utf8(rels.bytes) ? |_| RelationshipsNotUtf8(rels_name)
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

content_types_path : Str
content_types_path = "[Content_Types].xml"

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

# An override names the part exactly; otherwise its extension, compared
# without regard to case, selects a default.
content_type_for : ContentTypes, Str -> Try(Str, Opc.OpenError)
content_type_for = |types, name|
	match types.overrides.find_first(|override| override.part_name == name) {
		Ok(override) => Ok(override.content_type)
		Err(_) => {
			extension = ascii_lowercase(extension_of(name))
			match types.defaults.find_first(|default| default.extension == extension) {
				Ok(default) => Ok(default.content_type)
				Err(_) => Err(NoContentType(name))
			}
		}
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
# builtins have no case mapping.
ascii_lowercase : Str -> Str
ascii_lowercase = |text|
	Str.from_utf8_lossy(text.to_utf8().map(|byte| if (byte >= 'A' and byte <= 'Z') byte + 32 else byte))

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

# A minimal package: the three parts every WordprocessingML document has.
sample_archive : Try(List(U8), [EmptyPath(Str), PathTooLong(Str), DuplicatePart(Str)])
sample_archive = match Zip.create(
	[
		{ path: content_types_path, content: sample_content_types.to_utf8() },
		{ path: "_rels/.rels", content: sample_rels.to_utf8() },
		{ path: "word/document.xml", content: sample_document.to_utf8() },
	],
	None,
) {
	Ok(archive) => Ok(archive)
	Err(EmptyPath(path)) => Err(EmptyPath(path))
	Err(PathTooLong(path)) => Err(PathTooLong(path))
	Err(DuplicatePath(path)) => Err(DuplicatePart(path))
}

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
		\\parts: ${pkg.parts.len().to_str()}
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
expect Opc.open(sample_archive?, { max_entries: 2, max_part_bytes: 10_000, max_total_bytes: 10_000 }) == Err(TooManyEntries(3))

## The part limit names the first part that exceeds it.
expect Opc.open(sample_archive?, { max_entries: 10, max_part_bytes: 10, max_total_bytes: 10_000 }) == Err(PartTooLarge({ name: content_types_path, bytes: sample_content_types.to_utf8().len() }))

## The total limit applies to the archive before anything is decompressed.
expect {
	archive = sample_archive?
	Opc.open(archive, { max_entries: 10, max_part_bytes: 10_000, max_total_bytes: 100 }) == Err(PackageTooLarge(archive.len()))
}
