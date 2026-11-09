app [target] {
	docx: "../../package/main.roc",
	fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.5.0/9WT86CuwM7ZJBSs8iTd1jLyrUFTTiGp5hcJE63TwswGE.tar.zst",
	parser: "https://github.com/lukewilliamboswell/roc-parser/releases/download/6.0.0-rc.1/73WRCGdN4doPdfzqKAHBkwKQksAxmtoAr4Fu3dzDMvTC.tar.zst",
	zip: "https://github.com/lukewilliamboswell/roc-zip/releases/download/0.3.0-rc1/3vvx2cPVp1vjjVgrXcugJqqfrp55ZrURYQUcSArAUHdr.tar.zst",
}

import fuzz.Fuzz
import docx.Docx
import parser.XmlNs
import zip.Zip
import "../../tests/fixtures/gdocs/resume.docx" as gdocs_resume : List(U8)
import "../../tests/fixtures/libreoffice/basics.docx" as libreoffice_basics : List(U8)
import "../../tests/fixtures/libreoffice/comments.docx" as libreoffice_comments : List(U8)
import "../../tests/fixtures/libreoffice/lists.docx" as libreoffice_lists : List(U8)
import "../../tests/fixtures/libreoffice/notes.docx" as libreoffice_notes : List(U8)
import "../../tests/fixtures/libreoffice/review.docx" as libreoffice_review : List(U8)
import "../../tests/fixtures/libreoffice/revisions.docx" as libreoffice_revisions : List(U8)
import "../../tests/fixtures/libreoffice/tables.docx" as libreoffice_tables : List(U8)
import "../../tests/fixtures/pandoc/basics.docx" as pandoc_basics : List(U8)
import "../../tests/fixtures/pandoc/comments.docx" as pandoc_comments : List(U8)
import "../../tests/fixtures/pandoc/lists.docx" as pandoc_lists : List(U8)
import "../../tests/fixtures/pandoc/notes.docx" as pandoc_notes : List(U8)
import "../../tests/fixtures/pandoc/review.docx" as pandoc_review : List(U8)
import "../../tests/fixtures/pandoc/revisions.docx" as pandoc_revisions : List(U8)
import "../../tests/fixtures/pandoc/tables.docx" as pandoc_tables : List(U8)
import "../../tests/fixtures/word/comments.docx" as word_comments : List(U8)
import "../../tests/fixtures/word/report.docx" as word_report : List(U8)
import "../../tests/fixtures/word/revisions.docx" as word_revisions : List(U8)
import "../../tests/fixtures/word/tables.docx" as word_tables : List(U8)

## Written bytes satisfy a structural check that shares no code with the
## writer: the check reads the archive with roc-zip and each part with
## roc-parser's namespaced reader, never with the package, and holds:
##
## * every part has a content type, by an override or by its extension's
##   default, and every override names a part;
## * every relationship has its required attributes and an identifier no
##   other relationship of its source has, its source is a part, every
##   internal target is a part, and every attribute in the relationships
##   namespace names a relationship of its own part;
## * in every WordprocessingML part, bookmark identifiers are unique and
##   every bookmark and comment range that starts ends, and ends once; notes
##   and comments have unique identifiers, and every note reference, comment
##   range and comment reference names a note or comment the main document's
##   parts have;
## * every element of a table grounded in the Transitional schema carries
##   the attributes the schema requires of it.
##
## Inputs are every fixture and a new document from the default document
## kit, written as `Docx.to_bytes` writes what `Docx.parse` reads, and
## packages generated from a program of bytes whose
## main document, footnotes, header and comments hold bookmarks whose
## identifiers collide across parts and with comments', links, note references, comment ranges, pictures,
## insertions, tables and sections, which the writer gives identifiers and
## relationships.
##
## Allocation ratchets, which only ever move down: the check allocates and
## holds at most linearly many bytes in the bytes it reads, and each declared
## example allocates no more than it did when its ceiling was set. The large
## generated example costs at most what the small one costs in the same run
## plus a share for each further byte read, in allocations, bytes requested
## and bytes held live. Raising a ceiling needs a cause recorded in the pull
## request.
test! : Input => Fuzz.Outcome
test! = |input| {
	source = match input {
		Generated(program) => generated_package(program)
		Fixture(index) =>
			match fixtures.get(index) {
				Ok(fixture) => fixture.bytes
				Err(_) => return Fuzz.reject
			}

		New => new_document
	}
	cost = check!(source)
	allocations = cost.stats.allocs + cost.stats.reallocs
	if allocations > 1_024 + 4 * cost.size {
		crash "the check allocated more than linearly in the bytes it read"
	}
	# The large generated example holds 12.3 bytes live for each byte read,
	# the most of any declared example; the fixtures hold 330 to 440 KB.
	if held(cost.stats) > 262_144 + 16 * cost.size {
		crash "the check held more than linearly many bytes live"
	}
	match input {
		Generated(program) if program == large_program => {
			small = check!(generated_package(small_program))
			further = cost.size - small.size
			if allocations > small.stats.allocs + small.stats.reallocs + further * allocations_per_kib // 1_024 {
				crash "the large example allocated more than the small one and its further bytes"
			}
			if cost.stats.requested_bytes > small.stats.requested_bytes + further * requested_per_byte {
				crash "the large example requested more than the small one and its further bytes"
			}
			if held(cost.stats) > held(small.stats) + further * held_per_byte {
				crash "the large example held more than the small one and its further bytes"
			}
		}

		_ => {}
	}
	match exact_ceiling(input) {
		Ok(ceiling) =>
			if allocations > ceiling {
				crash "a declared example allocated more than its ceiling"
			}

		Err(NotDeclared) => {}
	}
	Fuzz.keep
}

# Write what a document reads to, and check the written bytes, measured.
check! : List(U8) => { stats : Fuzz.Stats, size : U64 }
check! = |source| {
	parsed = Docx.parse(source) ?? crash "a generated package or a fixture did not parse"
	written = Docx.to_bytes(parsed.document) ?? crash "a parsed document did not write"
	{ value: checked, stats } = Fuzz.measure!("structure-check", || check(written))
	match checked {
		Ok({}) => { stats, size: written.len() + inflated(written) }
		Err(problem) => crash "written bytes break a structural rule: ${problem}"
	}
}

# The most a measured operation held live beyond what was live at its entry.
held : Fuzz.Stats -> U64
held = |stats| stats.peak_live_bytes - stats.entry_live_bytes

Input : [Generated(List(U8)), Fixture(U64), New]

generator : Fuzz.Generator(Input)
generator = Fuzz.map(Fuzz.bytes, |bytes| Generated(bytes))

# The declared sizes of every entry.
inflated : List(U8) -> U64
inflated = |bytes|
	match Zip.entries(bytes) {
		Ok(entries) => entries.fold(0, |total, entry| total.plus_saturated(entry.uncompressed_size))
		Err(_) => 0
	}

# Exact ceilings: the allocations and reallocations of checking each
# declared example, as measured on nightly-2026-11-07 when the ceiling was
# set. Writing comments from their threads (G3.3) gives each comment's last
# paragraph an identifier in Word's `w14` namespace, declared ignorable on
# the comments part, which the check reads: 15 more for the generated
# examples, 18 for pandoc's comments and 15 for its review; the Word
# comments and Google Docs documents lost the identifiers on every other
# paragraph and fell by 19 and 6. The new document from the default
# document kit (G5.1) takes 2,028, set when it was declared.
exact_ceiling : Input -> Try(U64, [NotDeclared])
exact_ceiling = |input|
	match input {
		Generated(program) if program == small_program => Ok(1_348)
		Generated(program) if program == large_program => Ok(9_117)
		Fixture(index) => fixtures.get(index).map_ok(|fixture| fixture.allocations).map_err(|_| NotDeclared)
		New => Ok(2_028)
		_ => Err(NotDeclared)
	}

# The large generated example reads 55,893 bytes more than the small one's
# 12,339, of archive and inflated parts, and its check takes 142.3 more
# allocations a KiB of them, requests 37.6 more bytes a byte and holds 13.7
# more bytes live a byte.
allocations_per_kib : U64
allocations_per_kib = 143

requested_per_byte : U64
requested_per_byte = 38

held_per_byte : U64
held_per_byte = 14

# The small and large generated examples repeat one program, the large one
# sixteen times as often; checking them takes 1,348 and 9,117 allocations,
# the small one mostly the constant cost of a package's parts.
small_program : List(U8)
small_program = List.join(List.repeat(program_unit, 4))

large_program : List(U8)
large_program = List.join(List.repeat(program_unit, 64))

# Every kind of step once: text, a bookmark and its end, a link, a note
# reference, a comment, a picture, an insertion, a table, a section.
program_unit : List(U8)
program_unit = [1, 2, 18, 3, 19, 4, 5, 6, 7, 9, 8, 10, 0]

# A new document from the default document kit, as it is written.
new_document : List(U8)
new_document =
	match Docx.new_document({}) {
		Ok(created) => Docx.to_bytes(created) ?? []
		Err(_) => []
	}

fixtures : List({ name : Str, bytes : List(U8), allocations : U64 })
fixtures = [
	{ name: "gdocs-resume", bytes: gdocs_resume, allocations: 8_378 },
	{ name: "libreoffice-basics", bytes: libreoffice_basics, allocations: 5_397 },
	{ name: "libreoffice-comments", bytes: libreoffice_comments, allocations: 5_322 },
	{ name: "libreoffice-lists", bytes: libreoffice_lists, allocations: 8_106 },
	{ name: "libreoffice-notes", bytes: libreoffice_notes, allocations: 5_345 },
	{ name: "libreoffice-review", bytes: libreoffice_review, allocations: 7_182 },
	{ name: "libreoffice-revisions", bytes: libreoffice_revisions, allocations: 5_114 },
	{ name: "libreoffice-tables", bytes: libreoffice_tables, allocations: 7_848 },
	{ name: "pandoc-basics", bytes: pandoc_basics, allocations: 6_274 },
	{ name: "pandoc-comments", bytes: pandoc_comments, allocations: 6_101 },
	{ name: "pandoc-lists", bytes: pandoc_lists, allocations: 7_034 },
	{ name: "pandoc-notes", bytes: pandoc_notes, allocations: 5_962 },
	{ name: "pandoc-review", bytes: pandoc_review, allocations: 6_764 },
	{ name: "pandoc-revisions", bytes: pandoc_revisions, allocations: 5_954 },
	{ name: "pandoc-tables", bytes: pandoc_tables, allocations: 6_425 },
	{ name: "word-comments", bytes: word_comments, allocations: 6_556 },
	{ name: "word-report", bytes: word_report, allocations: 7_432 },
	{ name: "word-revisions", bytes: word_revisions, allocations: 6_814 },
	{ name: "word-tables", bytes: word_tables, allocations: 6_057 },
]

# ---- The check ----------------------------------------------------------

w : Str
w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

relationships_namespace : Str
relationships_namespace = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

package_relationships : Str
package_relationships = "http://schemas.openxmlformats.org/package/2006/relationships"

content_types_namespace : Str
content_types_namespace = "http://schemas.openxmlformats.org/package/2006/content-types"

# A relationship as its part states it.
Link : { id : Str, kind : Str, target : Str, external : Bool }

# What a WordprocessingML part names: its bookmark and comment range
# boundaries, its references, and the notes and comments it defines.
Names : {
	bookmark_starts : List(Str),
	bookmark_ends : List(Str),
	comment_starts : List(Str),
	comment_ends : List(Str),
	comment_references : List(Str),
	footnote_references : List(Str),
	endnote_references : List(Str),
	notes : List(Str),
	comments : List(Str),
}

no_names : Names
no_names = { bookmark_starts: [], bookmark_ends: [], comment_starts: [], comment_ends: [], comment_references: [], footnote_references: [], endnote_references: [], notes: [], comments: [] }

check : List(U8) -> Try({}, Str)
check = |bytes| {
	entries = Zip.extract(bytes) ? |_| "the archive does not extract"
	var $parts = Dict.with_capacity(entries.len())
	for entry in entries {
		$parts = $parts.insert("/${entry.path}", entry.content)
	}
	parts = $parts
	types = parse(parts.get("/[Content_Types].xml") ?? [], "/[Content_Types].xml")?
	content_types = content_types_of(types)?
	for name in parts.keys() {
		if name != "/[Content_Types].xml" {
			_ = type_of(content_types, name) ? |_| "${name} has no content type"
		}
	}
	for name in content_types.overrides.keys() {
		if !parts.keys().any(|part| lower(part) == name) {
			return Err("an override names ${name}, which is not a part")
		}
	}
	var $links = Dict.with_capacity(8)
	for name in parts.keys() {
		match source_of(name) {
			Ok(source) => {
				if source != "/" and !parts.contains(source) {
					return Err("${name} is the relationships of ${source}, which is not a part")
				}
				links = links_of(parse(parts.get(name) ?? [], name)?, name)?
				for link in links {
					if !link.external and !parts.contains(resolve(source, link.target)) {
						return Err("${name} relationship ${link.id} targets ${link.target}, which is not a part")
					}
				}
				$links = $links.insert(source, links)
			}

			Err(NotRelationships) => {}
		}
	}
	links = $links
	var $named = Dict.with_capacity(8)
	for name in parts.keys() {
		is_xml = (type_of(content_types, name) ?? "").ends_with("xml")
		if is_xml and source_of(name).is_err() and name != "/[Content_Types].xml" {
			root = parse(parts.get(name) ?? [], name)?
			ids = (links.get(name) ?? []).map(|link| link.id)
			$named = $named.insert(name, walk(root, name, ids)?)
		}
	}
	named = $named
	main = (links.get("/") ?? []).find_first(|link| link.kind == "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument")
	match main {
		Ok(link) => cross_check(resolve("/", link.target), links, named)
		Err(_) => Ok({})
	}
}

# Note references and comment ranges and references, wherever they are in
# the main document's parts, name notes and comments the main document's
# notes and comments parts define.
cross_check : Str, Dict(Str, List(Link)), Dict(Str, Names) -> Try({}, Str)
cross_check = |main, links, named| {
	related = |kind|
		(links.get(main) ?? [])
			.keep_if(|link| !link.external and link.kind == "http://schemas.openxmlformats.org/officeDocument/2006/relationships/${kind}")
			.map(|link| resolve(main, link.target))
	defined = |kind, field| related(kind).fold([], |found, part| List.concat(found, field(named.get(part) ?? no_names)))
	footnotes = defined("footnotes", |names| names.notes)
	endnotes = defined("endnotes", |names| names.notes)
	comments = defined("comments", |names| names.comments)
	scope = List.join([[main], related("footnotes"), related("endnotes"), related("comments"), related("header"), related("footer")])
	for part in scope {
		names = named.get(part) ?? no_names
		for id in names.footnote_references {
			if !footnotes.contains(id) {
				return Err("${part} refers to footnote ${id}, which is not defined")
			}
		}
		for id in names.endnote_references {
			if !endnotes.contains(id) {
				return Err("${part} refers to endnote ${id}, which is not defined")
			}
		}
		for id in List.join([names.comment_starts, names.comment_ends, names.comment_references]) {
			if !comments.contains(id) {
				return Err("${part} refers to comment ${id}, which is not defined")
			}
		}
	}
	Ok({})
}

parse : List(U8), Str -> Try(XmlNs.Node, Str)
parse = |bytes, name| {
	text = Str.from_utf8(bytes) ? |_| "${name} is not UTF-8"
	match XmlNs.parse_str(text) {
		Ok(document) => Ok(document.root)
		Err(_) => Err("${name} is not namespace-well-formed XML")
	}
}

ContentTypes : { defaults : Dict(Str, Str), overrides : Dict(Str, Str) }

content_types_of : XmlNs.Node -> Try(ContentTypes, Str)
content_types_of = |root| {
	var $defaults = Dict.with_capacity(4)
	for node in root.children_named(Uri(content_types_namespace), "Default") {
		extension = node.attribute(NoNamespace, "Extension") ? |_| "a default has no extension"
		kind = node.attribute(NoNamespace, "ContentType") ? |_| "a default has no content type"
		$defaults = $defaults.insert(lower(extension), kind)
	}
	var $overrides = Dict.with_capacity(16)
	for node in root.children_named(Uri(content_types_namespace), "Override") {
		part = node.attribute(NoNamespace, "PartName") ? |_| "an override has no part name"
		kind = node.attribute(NoNamespace, "ContentType") ? |_| "an override has no content type"
		$overrides = $overrides.insert(lower(part), kind)
	}
	Ok({ defaults: $defaults, overrides: $overrides })
}

type_of : ContentTypes, Str -> Try(Str, [NoType])
type_of = |types, name|
	match types.overrides.get(lower(name)) {
		Ok(kind) => Ok(kind)
		Err(_) =>
			match name.split_last(".") {
				Ok({ before: _, after }) => types.defaults.get(lower(after)).map_err(|_| NoType)
				Err(_) => Err(NoType)
			}
	}

# The part a relationships part belongs to: `/` for the package's own.
source_of : Str -> Try(Str, [NotRelationships])
source_of = |name| {
	if !name.ends_with(".rels") {
		return Err(NotRelationships)
	}
	{ before: directory, after: file } = name.split_last("/_rels/") ? |_| NotRelationships
	source : Str
	source = "${directory}/${file.drop_suffix(".rels")}"
	Ok(source)
}

links_of : XmlNs.Node, Str -> Try(List(Link), Str)
links_of = |root, name| {
	var $links = List.with_capacity(8)
	for node in root.children_named(Uri(package_relationships), "Relationship") {
		id = node.attribute(NoNamespace, "Id") ? |_| "${name} has a relationship without an identifier"
		kind = node.attribute(NoNamespace, "Type") ? |_| "${name} relationship ${id} has no type"
		target = node.attribute(NoNamespace, "Target") ? |_| "${name} relationship ${id} has no target"
		if $links.any(|link| link.id == id) {
			return Err("${name} has two relationships ${id}")
		}
		$links = List.append($links, { id, kind, target, external: node.attribute(NoNamespace, "TargetMode") == Ok("External") })
	}
	Ok($links)
}

# A relationship's target as a part name, resolved against its source's
# folder.
resolve : Str, Str -> Str
resolve = |source, target| {
	base = if (target.starts_with("/")) [] else (source.split_on("/").drop_last(1))
	var $segments = List.with_capacity(8)
	for segment in List.concat(base, target.split_on("/")) {
		if segment == ".." {
			$segments = List.drop_last($segments, 1)
		} else if segment != "" and segment != "." {
			$segments = List.append($segments, segment)
		}
	}
	"/${Str.join_with($segments, "/")}"
}

lower : Str -> Str
lower = |text| Str.from_utf8(text.to_utf8().map(|byte| if (byte >= 'A' and byte <= 'Z') byte + 32 else byte)) ?? text

# One element of a walk with its parent's local name.
Visit : { node : XmlNs.Node, parent : Str }

# Every element of a part: its relationship attributes name relationships
# of the part, its required attributes are present, and the part's
# identifiers are unique and its ranges balanced.
walk : XmlNs.Node, Str, List(Str) -> Try(Names, Str)
walk = |root, part, link_ids| {
	var $names = no_names
	var $pending = [{ node: root, parent: "" }]
	while !$pending.is_empty() {
		visit = $pending.last() ?? { node: root, parent: "" }
		$pending = List.drop_last($pending, 1)
		match visit.node {
			Element(element) => {
				for attribute in element.attributes {
					if attribute.name.namespace == Uri(relationships_namespace) and !link_ids.contains(attribute.value) {
						return Err("${part} ${element.name.local} names relationship ${attribute.value}, which the part does not have")
					}
				}
				if element.name.namespace == Uri(w) {
					for required in required_attributes(element.name.local, visit.parent) {
						present = element.attributes.any(|attribute| attribute.name.local == required.local and attribute.name.namespace == Uri(required.namespace))
						if !present {
							return Err("${part} ${element.name.local} has no ${required.local}")
						}
					}
					id = visit.node.attribute(Uri(w), "id") ?? ""
					$names = match element.name.local {
						"bookmarkStart" => { ..$names, bookmark_starts: List.append($names.bookmark_starts, id) }
						"bookmarkEnd" => { ..$names, bookmark_ends: List.append($names.bookmark_ends, id) }
						"commentRangeStart" => { ..$names, comment_starts: List.append($names.comment_starts, id) }
						"commentRangeEnd" => { ..$names, comment_ends: List.append($names.comment_ends, id) }
						"commentReference" => { ..$names, comment_references: List.append($names.comment_references, id) }
						"footnoteReference" => { ..$names, footnote_references: List.append($names.footnote_references, id) }
						"endnoteReference" => { ..$names, endnote_references: List.append($names.endnote_references, id) }
						"footnote" | "endnote" if visit.parent == "footnotes" or visit.parent == "endnotes" => { ..$names, notes: List.append($names.notes, id) }
						"comment" if visit.parent == "comments" => { ..$names, comments: List.append($names.comments, id) }
						_ => $names
					}
				}
				for child in element.children {
					$pending = List.append($pending, { node: child, parent: element.name.local })
				}
			}

			Text(_) => {}
		}
	}
	names = $names
	unique(names.bookmark_starts, "${part} bookmark")?
	unique(names.bookmark_ends, "${part} bookmark end")?
	balanced(names.bookmark_starts, names.bookmark_ends, "${part} bookmark")?
	unique(names.comment_starts, "${part} comment range")?
	unique(names.comment_ends, "${part} comment range end")?
	balanced(names.comment_starts, names.comment_ends, "${part} comment range")?
	unique(names.notes, "${part} note")?
	unique(names.comments, "${part} comment")?
	Ok(names)
}

unique : List(Str), Str -> Try({}, Str)
unique = |ids, what| {
	var $seen = Set.with_capacity(ids.len())
	for id in ids {
		if $seen.contains(id) {
			return Err("${what} ${id} is not unique")
		}
		$seen = $seen.insert(id)
	}
	Ok({})
}

balanced : List(Str), List(Str), Str -> Try({}, Str)
balanced = |starts, ends, what| {
	for id in starts {
		if !ends.contains(id) {
			return Err("${what} ${id} starts and never ends")
		}
	}
	for id in ends {
		if !starts.contains(id) {
			return Err("${what} ${id} ends and never starts")
		}
	}
	Ok({})
}

# The attributes the Transitional schema requires of a WordprocessingML
# element, where every type the schema gives an element of that name, under
# that parent, requires them.
required_attributes : Str, Str -> List({ namespace : Str, local : Str })
required_attributes = |local, parent| {
	of = |names| names.map(|name| { namespace: w, local: name })
	border_lists = ["pBdr", "tblBorders", "tcBorders", "pgBorders"]
	match local {
		"bookmarkStart" => of(["id", "name"])
		"bookmarkEnd" | "commentRangeStart" | "commentRangeEnd" | "commentReference" | "footnoteReference" | "endnoteReference" => of(["id"])
		"footnote" | "endnote" => of(["id"])
		"comment" => of(["id", "author"])
		"ins" | "del" | "moveFrom" | "moveTo" => of(["id", "author"])
		"fldChar" => of(["fldCharType"])
		"headerReference" | "footerReference" => List.append(of(["type"]), { namespace: relationships_namespace, local: "id" })
		"pgMar" => of(["top", "right", "bottom", "left", "header", "footer", "gutter"])
		"pStyle" | "rStyle" | "tblStyle" | "jc" | "numId" | "ilvl" | "sz" | "szCs" | "color" | "shd" | "highlight" | "vertAlign" | "outlineLvl" | "gridSpan" | "vAlign" | "gridBefore" | "gridAfter" => of(["val"])
		"tab" if parent == "tabs" => of(["val", "pos"])
		"top" | "left" | "bottom" | "right" | "start" | "end" | "between" | "bar" | "insideH" | "insideV" | "tl2br" | "tr2bl" if border_lists.contains(parent) => of(["val"])
		_ => []
	}
}

# ---- Generated packages -------------------------------------------------

# A package a program describes: a main document whose body the program
# writes one step a byte, the low four bits the step and the rest its
# variant; footnotes, a header and comments, each with a bookmark and a
# link of its own; and a picture.
generated_package : List(U8) -> List(U8)
generated_package = |program| {
	var $body = List.with_capacity(program.len() * 64)
	var $started = List.with_capacity(3)
	var $ended = List.with_capacity(3)
	var $commented = List.with_capacity(2)
	var $position = 0.U64
	for byte in program {
		variant = (byte // 16).to_u64()
		mark = (variant % 3).to_str()
		name = "mark${mark}"
		text = match byte % 16 {
			0 => "</w:p><w:p>"
			1 => "<w:r><w:t>text ${$position.to_str()}</w:t></w:r>"
			2 => if ($started.contains(name)) "" else "<w:bookmarkStart w:id='${mark}' w:name='${name}'/>"
			3 => if ($started.contains(name) and !$ended.contains(name)) "<w:bookmarkEnd w:id='${mark}'/>" else ""
			4 => "<w:hyperlink r:id='rId${(10 + variant % 2).to_str()}'><w:r><w:t>link</w:t></w:r></w:hyperlink>"
			5 => "<w:r><w:footnoteReference w:id='${(1 + variant % 2).to_str()}'/></w:r>"
			6 => {
				comment = (variant % 2).to_str()
				if ($commented.contains(comment)) "" else "<w:commentRangeStart w:id='${comment}'/><w:r><w:t>noted</w:t></w:r><w:commentRangeEnd w:id='${comment}'/><w:r><w:commentReference w:id='${comment}'/></w:r>"
			}

			7 => "<w:r><w:drawing><wp:inline><wp:extent cx='952500' cy='476250'/><wp:docPr id='1' name='Logo'/><a:graphic><a:graphicData uri='http://schemas.openxmlformats.org/drawingml/2006/picture'><a:blip r:embed='rId12'/></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>"
			8 => "<w:ins w:id='${(100 + $position).to_str()}' w:author='Ada'><w:r><w:t>added</w:t></w:r></w:ins>"
			9 => "</w:p><w:tbl><w:tblPr/><w:tblGrid><w:gridCol w:w='2000'/></w:tblGrid><w:tr><w:tc><w:p><w:bookmarkStart w:id='${(50 + $position).to_str()}' w:name='cell${$position.to_str()}'/><w:r><w:t>cell</w:t></w:r><w:bookmarkEnd w:id='${(50 + $position).to_str()}'/></w:p></w:tc></w:tr></w:tbl><w:p>"
			10 => "</w:p><w:p><w:pPr><w:sectPr><w:headerReference w:type='default' r:id='rId13'/><w:pgMar w:top='1440' w:right='1440' w:bottom='1440' w:left='1440' w:header='720' w:footer='720' w:gutter='0'/></w:sectPr></w:pPr></w:p><w:p>"
			_ => ""
		}
		if byte % 16 == 2 and !$started.contains(name) {
			$started = List.append($started, name)
		}
		if byte % 16 == 3 and $started.contains(name) and !$ended.contains(name) {
			$ended = List.append($ended, name)
		}
		if byte % 16 == 6 {
			$commented = List.append($commented, (variant % 2).to_str())
		}
		$body = List.concat($body, text.to_utf8())
		$position = $position + 1
	}
	ended = $ended
	closing = Str.join_with($started.drop_if(|name| ended.contains(name)).map(|name| "<w:bookmarkEnd w:id='${name.drop_prefix("mark")}'/>"), "")
	document = List.join(["<w:document ${declarations}><w:body><w:p>".to_utf8(), $body, "${closing}</w:p><w:sectPr><w:headerReference w:type='default' r:id='rId13'/></w:sectPr></w:body></w:document>".to_utf8()])
	note = |id| "<w:footnote w:id='${id}'><w:p><w:bookmarkStart w:id='${id}' w:name='note${id}'/><w:r><w:footnoteRef/></w:r><w:hyperlink r:id='rId5'><w:r><w:t>see</w:t></w:r></w:hyperlink><w:bookmarkEnd w:id='${id}'/></w:p></w:footnote>"
	footnotes = "<w:footnotes ${declarations}><w:footnote w:type='separator' w:id='-1'><w:p><w:r><w:separator/></w:r></w:p></w:footnote>${note("1")}${note("2")}</w:footnotes>"
	header = "<w:hdr ${declarations}><w:p><w:bookmarkStart w:id='3' w:name='top'/><w:hyperlink r:id='rId4'><w:r><w:t>Draft</w:t></w:r></w:hyperlink><w:bookmarkEnd w:id='3'/></w:p></w:hdr>"
	comment = |id| "<w:comment w:id='${id}' w:author='Morgan Reviewer'><w:p><w:r><w:t>Comment ${id}</w:t></w:r></w:p></w:comment>"
	comments = "<w:comments ${declarations}>${comment("0")}${comment("1")}</w:comments>"
	link = |id, kind, target, external| "<Relationship Id='${id}' Type='${relationships_namespace}/${kind}' Target='${target}'${if (external) " TargetMode='External'" else ""}/>"
	rels = |content| "<Relationships xmlns='${package_relationships}'>${content}</Relationships>".to_utf8()
	main_rels = Str.join_with(
		[
			link("rId10", "hyperlink", "https://example.org/a", Bool.True),
			link("rId11", "hyperlink", "https://example.org/b", Bool.True),
			link("rId12", "image", "media/image1.png", Bool.False),
			link("rId13", "header", "header1.xml", Bool.False),
			link("rId14", "footnotes", "footnotes.xml", Bool.False),
			link("rId15", "comments", "comments.xml", Bool.False),
		],
		"",
	)
	Zip.create(
		[
			{ path: "[Content_Types].xml", content: generated_types.to_utf8() },
			{ path: "_rels/.rels", content: rels(link("rId1", "officeDocument", "word/document.xml", Bool.False)) },
			{ path: "word/document.xml", content: document },
			{ path: "word/_rels/document.xml.rels", content: rels(main_rels) },
			{ path: "word/footnotes.xml", content: footnotes.to_utf8() },
			{ path: "word/_rels/footnotes.xml.rels", content: rels(link("rId5", "hyperlink", "https://example.org/note", Bool.True)) },
			{ path: "word/header1.xml", content: header.to_utf8() },
			{ path: "word/_rels/header1.xml.rels", content: rels(link("rId4", "hyperlink", "https://example.org/header", Bool.True)) },
			{ path: "word/comments.xml", content: comments.to_utf8() },
			{ path: "word/media/image1.png", content: [0x89, 0x50, 0x4E, 0x47] },
		],
		Fastest,
	) ?? crash "generated_package: the paths are valid"
}

declarations : Str
declarations = "xmlns:w='${w}' xmlns:r='${relationships_namespace}' xmlns:wp='http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing' xmlns:a='http://schemas.openxmlformats.org/drawingml/2006/main'"

generated_types : Str
generated_types = {
	wml = "application/vnd.openxmlformats-officedocument.wordprocessingml"
	override = |part, kind| "<Override PartName='/word/${part}' ContentType='${wml}.${kind}+xml'/>"
	"<Types xmlns='${content_types_namespace}'><Default Extension='rels' ContentType='application/vnd.openxmlformats-package.relationships+xml'/><Default Extension='png' ContentType='image/png'/>${override("document.xml", "document.main")}${override("footnotes.xml", "footnotes")}${override("header1.xml", "header")}${override("comments.xml", "comments")}</Types>"
}

target = Fuzz.target_with!({
	name: "structure-oracle",
	examples: [
		Fuzz.example({ name: "small-document", revision: "1", make: || Generated(small_program) }),
		Fuzz.example({ name: "large-document", revision: "1", make: || Generated(large_program) }),
		Fuzz.example({ name: "new-document", revision: "1", make: || New }),
	].concat(fixtures.map_with_index(|fixture, index| Fuzz.example({ name: fixture.name, revision: "1", make: || Fixture(index) }))),
	generator,
	test!,
	show: |input| Str.inspect(input),
})
