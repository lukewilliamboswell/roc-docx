app [target] {
	docx: "../../package/main.roc",
	fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.5.0/9WT86CuwM7ZJBSs8iTd1jLyrUFTTiGp5hcJE63TwswGE.tar.zst",
	zip: "https://github.com/lukewilliamboswell/roc-zip/releases/download/0.3.0-rc1/3vvx2cPVp1vjjVgrXcugJqqfrp55ZrURYQUcSArAUHdr.tar.zst",
}

import fuzz.Fuzz
import docx.Docx
import docx.Document
import docx.Opc
import zip.Zip
import "../../tests/fixtures/gdocs/resume.docx" as gdocs_resume : List(U8)
import "../../tests/fixtures/pandoc/basics.docx" as pandoc_basics : List(U8)
import "../../tests/fixtures/libreoffice/basics.docx" as libreoffice_basics : List(U8)
import "../../tests/fixtures/word/report.docx" as word_report : List(U8)

## Any bytes parse to `Ok` or a structured `Err`, never a crash, and parsing
## the same bytes twice gives the same result, which is the body and
## diagnostics that reading the main document as a whole tree gives. A document that parses passes
## through: it writes, writing it twice gives the same bytes, the written
## bytes parse to a document `Docx.equivalent` finds equivalent, with
## nothing left to drop, and writing that gives the same bytes again.
##
## Inputs are arbitrary bytes, or packages generated from a small program of
## bytes whose main document mixes WordprocessingML with an extension
## namespace, declared ignorable or not, spelled with prefixes that collide
## with the writer's table, alternative content, the content reading drops
## and, as Google Docs exports write them, measures written with a fraction
## and page margins without a gutter, which reading repairs.
##
## Allocation ratchets, which only ever move down: parsing and writing each
## allocate at most linearly in the archive and the bytes it inflates, and
## each declared example parses and writes with no more allocations than it
## did when its ceilings were set. Each large declared example, the largest
## fixture and the generated document sixteen times the small one, costs
## at most what its small one, a one-paragraph document and the small
## generated one, costs in the same run plus a share for each further byte,
## in allocations, bytes requested and bytes held live, parsing and writing
## alike: the small one is mostly a package's and a DEFLATE compressor's
## constant cost, so the share bounds the growth above it. Raising a ceiling
## needs a cause recorded in the pull request.
test! : Input => Fuzz.Outcome
test! = |input| {
	bytes = match input {
		Bytes(raw) => raw
		Generated(program) => generated_package(program)
		Fixture(index) =>
			match fixtures.get(index) {
				Ok(fixture) => fixture.bytes
				Err(_) => return Fuzz.reject
			}
	}
	size = bytes.len() + inflated(bytes)
	measured = Fuzz.measure!("docx-parse", || Docx.parse(bytes))
	parse_stats = measured.stats
	parsed : Try({ document : Document, diagnostics : List(Document.Diagnostic) }, Docx.ParseError)
	parsed = measured.value
	check_linear(parse_stats, size, "parsing")
	if Docx.parse(bytes).map_ok(|again| again.diagnostics) != parsed.map_ok(|first| first.diagnostics) {
		crash "parsing the same bytes twice disagreed"
	}
	check_blockwise(bytes, parsed)
	match parsed {
		Ok({ document, diagnostics: _ }) => {
			{ value: first, stats: write_stats } = Fuzz.measure!("docx-to-bytes", || Docx.to_bytes(document))
			check_linear(write_stats, size, "writing")
			written = first ?? crash "a parsed document did not write"
			if Docx.to_bytes(document) != Ok(written) {
				crash "writing a document twice gave different bytes"
			}
			again = Docx.parse(written) ?? crash "a written document did not parse"
			if !Docx.equivalent(document, again.document) {
				crash "a written document is not equivalent to the one written"
			}
			if !again.diagnostics.is_empty() {
				crash "a written document still had content to drop"
			}
			if Docx.to_bytes(again.document) != Ok(written) {
				crash "writing a written document gave different bytes"
			}
			match exact_ceiling(input) {
				Ok(ceiling) => {
					if allocations(parse_stats) > ceiling.parse {
						crash "parsing a declared example allocated more than its ceiling"
					}
					if allocations(write_stats) > ceiling.write {
						crash "writing a declared example allocated more than its ceiling"
					}
				}

				Err(NotDeclared) => {}
			}
			match small_of(input) {
				Ok(pair) => check_pair(cost!(pair.small), { parse: parse_stats, write: write_stats, size }, pair.shares)
				Err(NotLarge) => {}
			}
			Fuzz.keep
		}

		Err(_) =>
			match input {
				Bytes(_) => Fuzz.keep
				_ => crash "a generated package or a fixture did not parse"
			}
	}
}

# Parsing reads the body block by block to the blocks and diagnostics that
# reading every part as a tree, the main document's included, and then its
# body gives, and fails exactly where that does.
check_blockwise : List(U8), Try({ document : Document, diagnostics : List(Document.Diagnostic) }, Docx.ParseError) -> {}
check_blockwise = |bytes, parsed|
	match Opc.open(bytes, {}) {
		Ok(pkg) =>
			match (parsed, Document.from_package(pkg, {})) {
				(Ok(read), Ok(whole)) =>
					if read.diagnostics != whole.diagnostics or Docx.read_body(read.document) != Docx.read_body(whole.document) {
						crash "reading the body block by block differed from reading its tree"
					} else {
						{}
					}

				(Err(_), Err(_)) => {}
				_ => crash "reading the body block by block failed where reading its tree did not, or the reverse"
			}

		Err(_) => {}
	}

# Exploration gives arbitrary bytes or a generated package by the first
# byte; the fixtures are declared examples.
Input : [Bytes(List(U8)), Generated(List(U8)), Fixture(U64)]

generator : Fuzz.Generator(Input)
generator = Fuzz.map(
	Fuzz.bytes,
	|bytes|
		if (bytes.first() ?? 0) % 2 == 0 {
			Bytes(bytes.drop_first(1))
		} else {
			Generated(bytes.drop_first(1))
		},
)

# A measured operation allocates at most linearly in the archive and the
# bytes it inflates, and holds at most linearly many bytes beyond its input.
check_linear : Fuzz.Stats, U64, Str -> {}
check_linear = |stats, size, operation| {
	if stats.allocs + stats.reallocs > linear_allocation_ceiling(size) {
		crash "${operation} allocated more than linearly in the document's bytes"
	}
	if stats.peak_live_bytes - stats.entry_live_bytes > linear_memory_ceiling(size) {
		crash "${operation} held more than linearly many bytes live"
	}
	{}
}

# Measured on the fixtures: parsing takes at most 0.15 allocations and 11
# bytes live per byte of archive and inflated parts, writing fewer of both;
# the constants cover a package's fixed parts and one DEFLATE compressor's
# state, about 288 KiB.
linear_allocation_ceiling : U64 -> U64
linear_allocation_ceiling = |size| 1_024 + 2 * size

linear_memory_ceiling : U64 -> U64
linear_memory_ceiling = |size| 524_288 + 320 * size

# The declared sizes of every entry; nothing when the central directory does
# not read.
inflated : List(U8) -> U64
inflated = |bytes|
	match Zip.entries(bytes) {
		Ok(entries) => entries.fold(0, |total, entry| total.plus_saturated(entry.uncompressed_size))
		Err(_) => 0
	}

# The allocations and reallocations of a measured operation.
allocations : Fuzz.Stats -> U64
allocations = |stats| stats.allocs + stats.reallocs

# Parse and write the small example of a pair, measured as the test measures
# its input.
cost! : List(U8) => { parse : Fuzz.Stats, write : Fuzz.Stats, size : U64 }
cost! = |bytes| {
	{ value: parsed, stats: parse } = Fuzz.measure!("docx-parse", || Docx.parse(bytes))
	read = parsed ?? crash "the small example of a pair did not parse"
	{ value: _, stats: write } = Fuzz.measure!("docx-to-bytes", || Docx.to_bytes(read.document))
	{ parse, write, size: bytes.len() + inflated(bytes) }
}

# A large example costs at most its small one's cost, measured in the same
# run, and the pair's shares for each further byte of archive and inflated
# parts, parsing and writing each.
check_pair : { parse : Fuzz.Stats, write : Fuzz.Stats, size : U64 }, { parse : Fuzz.Stats, write : Fuzz.Stats, size : U64 }, { parse : Share, write : Share } -> {}
check_pair = |small, large, shares| {
	further = large.size - small.size
	if !within_share(small.parse, large.parse, further, shares.parse) {
		crash "parsing the large example cost more than the small one and its further bytes"
	}
	if !within_share(small.write, large.write, further, shares.write) {
		crash "writing the large example cost more than the small one and its further bytes"
	}
	{}
}

# What a pair allows its large example for each further byte: allocations a
# KiB, and bytes requested and held live a byte.
Share : { allocations_per_kib : U64, requested_per_byte : U64, held_per_byte : U64 }

within_share : Fuzz.Stats, Fuzz.Stats, U64, Share -> Bool
within_share = |small, large, further, share|
	allocations(large) <= allocations(small) + further * share.allocations_per_kib // 1_024
		and large.requested_bytes <= small.requested_bytes + further * share.requested_per_byte
		and held(large) <= held(small) + further * share.held_per_byte

# The most a measured operation held live beyond what was live at its entry.
held : Fuzz.Stats -> U64
held = |stats| stats.peak_live_bytes - stats.entry_live_bytes

# The small example of a large one and the pair's shares, each the measured
# share rounded up. The largest fixture, `word/report.docx`, reads 103,428
# bytes more than the one-paragraph document; parsing and writing it take
# 99.7 and 99.4 more allocations a KiB of them, request 36.7 and 80.1 more
# bytes a byte and hold 7.3 and 2.4 more bytes live a byte. The large
# generated document reads 23,841 bytes more than the small one, denser in
# elements: 203.8 and 139.9 more allocations a KiB, 23.1 and 34.7 more bytes
# requested and 9.1 and 4.1 more held a byte. Both small ones cost mostly a
# package's and a DEFLATE compressor's constant, which the shares leave out.
small_of : Input -> Try({ small : List(U8), shares : { parse : Share, write : Share } }, [NotLarge])
small_of = |input|
	match input {
		Generated(program) if program == large_program => {
			parse = { allocations_per_kib: 204, requested_per_byte: 24, held_per_byte: 10 }
			write = { allocations_per_kib: 140, requested_per_byte: 35, held_per_byte: 5 }
			Ok({ small: generated_package(small_program), shares: { parse, write } })
		}

		Fixture(index) if fixtures.get(index).map_ok(|fixture| fixture.name) == Ok("word-report") => {
			parse = { allocations_per_kib: 100, requested_per_byte: 37, held_per_byte: 8 }
			write = { allocations_per_kib: 100, requested_per_byte: 81, held_per_byte: 3 }
			Ok({ small: generated_package(one_paragraph_program), shares: { parse, write } })
		}

		_ => Err(NotLarge)
	}

# Exact ceilings: the allocations and reallocations of parsing and of
# writing each declared document, as measured on nightly-2026-11-07 with
# roc-zip 0.3.0-rc1 and roc-parser 6.0.0-rc.1 when the ceiling was set.
# Writing comments and their threads from the model (G3.3) looks for the
# comments part and its threads on every write, 3 more for each example's
# writing, and writes the comments part and the parts beside it, reading
# which entries the model does not hold and scanning every other part for
# the identifiers comments must avoid: 37 more for the pandoc document,
# whose comments part is empty, and 572 for the Google Docs export's two
# comments. Reading comments as written, without processing them for
# compatibility first, lowered parsing them by 5 and 337.
exact_ceiling : Input -> Try({ parse : U64, write : U64 }, [NotDeclared])
exact_ceiling = |input|
	match input {
		Generated(program) if program == one_paragraph_program => Ok({ parse: 292, write: 454 })
		Generated(program) if program == small_program => Ok({ parse: 579, write: 654 })
		Generated(program) if program == large_program => Ok({ parse: 5_324, write: 3_911 })
		Generated(program) if program == undeclared_program => Ok({ parse: 578, write: 764 })
		Generated(program) if program == repaired_program => Ok({ parse: 753, write: 739 })
		Fixture(index) => fixtures.get(index).map_ok(|fixture| { parse: fixture.parse, write: fixture.write }).map_err(|_| NotDeclared)
		_ => Err(NotDeclared)
	}

# One paragraph with one run of text, in the generated package's other
# parts.
one_paragraph_program : List(U8)
one_paragraph_program = [0, 7, 3]

# The small and large generated examples repeat one program, the large one
# sixteen times as often.
small_program : List(U8)
small_program = List.join(List.repeat(program_unit, 4))

large_program : List(U8)
large_program = List.join(List.repeat(program_unit, 64))

# The small program with the extension namespace spelled `w14` and not
# declared ignorable, as Google Docs exports write paragraph identifiers.
undeclared_program : List(U8)
undeclared_program = List.concat([8], small_program.drop_first(1))

# The small program with every paragraph indented by measures written with a
# fraction and the section's page margins written as a Google Docs export
# writes them, with a fraction and without a gutter.
repaired_program : List(U8)
repaired_program = List.concat([23], small_program.drop_first(1))

# A paragraph with save identifiers and an extension attribute holding a
# proofing mark, a run with text and a rendered page break, an extension
# element and an alternative; then whitespace.
program_unit : List(U8)
program_unit = [7, 4, 3, 5, 1, 2, 6, 2, 0]

# The largest fixture, the one with the largest body, which is almost all
# one table, and one from each of pandoc and LibreOffice.
fixtures : List({ name : Str, bytes : List(U8), parse : U64, write : U64 })
fixtures = [
	{ name: "word-report", bytes: word_report, parse: 10_357, write: 10_492 },
	{ name: "gdocs-resume", bytes: gdocs_resume, parse: 20_466, write: 17_793 },
	{ name: "pandoc-basics", bytes: pandoc_basics, parse: 9_160, write: 8_339 },
	{ name: "libreoffice-basics", bytes: libreoffice_basics, parse: 8_025, write: 7_543 },
]

wordprocessingml : Str
wordprocessingml = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

# A package whose main document a program describes, with a picture beside
# it. The first byte chooses the prefixes the document is written with:
# WordprocessingML as `w` or `q`, and the extension namespace as `x`, `w14`
# or `ns1`, which the writer's table or its own numbering also use; and
# whether the extension namespace is declared ignorable, which Google Docs
# exports leave out; and whether paragraphs and the section carry measures
# written with a fraction and page margins without a gutter, as Google Docs
# exports write them.
generated_package : List(U8) -> List(U8)
generated_package = |program| {
	choice = (program.first() ?? 0).to_u64()
	w = pick(["w", "q"], choice)
	x = pick(["x", "w14", "ns1"], choice // 2)
	ignorable = if ((choice // 8) % 2 == 0) " mc:Ignorable='${x}'" else ""
	repaired = (choice // 16) % 2 == 1
	paragraph = if (repaired) "<${w}:p ${w}:rsidR='00A1' ${x}:mark='1'><${w}:pPr><${w}:ind ${w}:left='359.9999999999999' ${w}:hanging='0.5'/></${w}:pPr>" else "<${w}:p ${w}:rsidR='00A1' ${x}:mark='1'>"
	section = if (repaired) "<${w}:sectPr><${w}:pgMar ${w}:top='1440' ${w}:right='1440.0' ${w}:bottom='1440' ${w}:left='863.9999999999999' ${w}:header='720' ${w}:footer='720'/></${w}:sectPr>" else ""
	declarations = "xmlns:${w}='${wordprocessingml}' xmlns:${x}='urn:example:extension' xmlns:mc='http://schemas.openxmlformats.org/markup-compatibility/2006'${ignorable}"
	var $body = List.with_capacity(program.len())
	var $open = List.with_capacity(16)
	for byte in program.drop_first(1) {
		step = match byte % 8 {
			0 => { text: "\n  ", open: [] }
			1 => { text: "<${x}:ext ${x}:k='v'>", open: ["${x}:ext"] }
			2 => { text: "", open: [] }
			3 => { text: "<${w}:r><${w}:t xml:space='preserve'> a &amp; b </${w}:t><${w}:lastRenderedPageBreak/></${w}:r>", open: [] }
			4 => { text: "<${w}:proofErr ${w}:type='spellStart'/><${w}:bookmarkStart ${w}:id='0' ${w}:name='_GoBack'/><${w}:bookmarkEnd ${w}:id='0'/>", open: [] }
			5 => { text: "<${w}:t>é</${w}:t>", open: [] }
			6 => { text: "<mc:AlternateContent><mc:Choice Requires='${x}'><${x}:shape/></mc:Choice><mc:Fallback><${w}:t>f</${w}:t></mc:Fallback></mc:AlternateContent>", open: [] }
			_ => { text: paragraph, open: ["${w}:p"] }
		}
		if byte % 8 == 2 {
			match $open.last() {
				Ok(name) => {
					$body = List.concat($body, "</${name}>".to_utf8())
					$open = List.drop_last($open, 1)
				}

				Err(_) => {}
			}
		} else if $open.len() < 64 or step.open.is_empty() {
			$body = List.concat($body, step.text.to_utf8())
			$open = List.concat($open, step.open)
		}
	}
	while !$open.is_empty() {
		$body = List.concat($body, "</${$open.last() ?? ""}>".to_utf8())
		$open = List.drop_last($open, 1)
	}
	document = List.join(["<${w}:document ${declarations}><${w}:body>".to_utf8(), $body, section.to_utf8(), "</${w}:body></${w}:document>".to_utf8()])
	Zip.create(
		[
			{ path: "[Content_Types].xml", content: content_types.to_utf8() },
			{ path: "_rels/.rels", content: package_rels.to_utf8() },
			{ path: "word/document.xml", content: document },
			{ path: "word/_rels/document.xml.rels", content: document_rels.to_utf8() },
			{ path: "word/media/picture.png", content: program },
		],
		Fastest,
	) ?? crash "generated_package: the paths are valid"
}

pick : List(Str), U64 -> Str
pick = |choices, index| choices.get(index % choices.len()) ?? ""

content_types : Str
content_types = "<Types xmlns='http://schemas.openxmlformats.org/package/2006/content-types'><Default Extension='rels' ContentType='application/vnd.openxmlformats-package.relationships+xml'/><Default Extension='png' ContentType='image/png'/><Override PartName='/word/document.xml' ContentType='application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml'/></Types>"

package_rels : Str
package_rels = "<Relationships xmlns='http://schemas.openxmlformats.org/package/2006/relationships'><Relationship Id='rId1' Type='http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument' Target='word/document.xml'/></Relationships>"

document_rels : Str
document_rels = "<Relationships xmlns='http://schemas.openxmlformats.org/package/2006/relationships'><Relationship Id='rId1' Type='http://schemas.openxmlformats.org/officeDocument/2006/relationships/image' Target='media/picture.png'/></Relationships>"

target = Fuzz.target_with!({
	name: "parse-never-crashes",
	examples: [
		Fuzz.example({ name: "empty", revision: "1", make: || Bytes([]) }),
		Fuzz.example({ name: "zip-signature-only", revision: "1", make: || Bytes([0x50, 0x4B, 0x03, 0x04]) }),
		Fuzz.example({ name: "one-paragraph", revision: "1", make: || Generated(one_paragraph_program) }),
		Fuzz.example({ name: "small-document", revision: "1", make: || Generated(small_program) }),
		Fuzz.example({ name: "large-document", revision: "1", make: || Generated(large_program) }),
		Fuzz.example({ name: "undeclared-extension", revision: "1", make: || Generated(undeclared_program) }),
		Fuzz.example({ name: "repaired-measures", revision: "1", make: || Generated(repaired_program) }),
	].concat(fixtures.map_with_index(|fixture, index| Fuzz.example({ name: fixture.name, revision: "1", make: || Fixture(index) }))),
	generator,
	test!,
	show: |input| Str.inspect(input),
})
