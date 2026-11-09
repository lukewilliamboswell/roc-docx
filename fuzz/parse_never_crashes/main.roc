app [target] {
	docx: "../../package/main.roc",
	fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.5.0/9WT86CuwM7ZJBSs8iTd1jLyrUFTTiGp5hcJE63TwswGE.tar.zst",
	zip: "https://github.com/lukewilliamboswell/roc-zip/releases/download/0.3.0-rc1/3vvx2cPVp1vjjVgrXcugJqqfrp55ZrURYQUcSArAUHdr.tar.zst",
}

import fuzz.Fuzz
import docx.Docx
import docx.Document
import zip.Zip
import "../../tests/fixtures/pandoc/basics.docx" as pandoc_basics : List(U8)
import "../../tests/fixtures/libreoffice/basics.docx" as libreoffice_basics : List(U8)

## Any bytes parse to `Ok` or a structured `Err`, never a crash, and parsing
## the same bytes twice gives the same result. A document that parses passes
## through: it writes, writing it twice gives the same bytes, the written
## bytes parse to an equivalent document with nothing left to drop, and
## writing that gives the same bytes again.
##
## Inputs are arbitrary bytes, or packages generated from a small program of
## bytes whose main document mixes WordprocessingML with an extension
## namespace, declared ignorable or not, spelled with prefixes that collide
## with the writer's table, alternative content and the content reading drops.
##
## Allocation ratchets, which only ever move down: parsing and writing each
## allocate at most linearly in the archive and the bytes it inflates, and
## each declared example allocates no more than it did when its ceiling was
## set. Raising a ceiling needs a cause recorded in the pull request.
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
	match parsed {
		Ok({ document, diagnostics: _ }) => {
			{ value: first, stats: write_stats } = Fuzz.measure!("docx-to-bytes", || Docx.to_bytes(document))
			check_linear(write_stats, size, "writing")
			written = first ?? crash "a parsed document did not write"
			if Docx.to_bytes(document) != Ok(written) {
				crash "writing a document twice gave different bytes"
			}
			again = Docx.parse(written) ?? crash "a written document did not parse"
			if !Document.equivalent(document, again.document) {
				crash "a written document is not equivalent to the one written"
			}
			if !again.diagnostics.is_empty() {
				crash "a written document still had content to drop"
			}
			if Docx.to_bytes(again.document) != Ok(written) {
				crash "writing a written document gave different bytes"
			}
			allocations = parse_stats.allocs + parse_stats.reallocs + write_stats.allocs + write_stats.reallocs
			match exact_ceiling(input) {
				Ok(ceiling) =>
					if allocations > ceiling {
						crash "a declared example allocated more than its ceiling"
					}

				Err(NotDeclared) => {}
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

# Exact ceilings: the allocations and reallocations of parsing and writing
# each declared document, as measured on nightly-2026-11-07 with roc-zip
# 0.3.0-rc1 and roc-parser 6.0.0-rc.1 when the ceiling was set.
# Reading the package's own parts through the namespaced reader (G1.3a)
# added a constant 47 to 87 to each when both slices met. Declaring
# undeclared extensions when writing (G1.5a) added 5 to 15 to each, the scan
# of every part for extension namespaces, and 356 to the LibreOffice
# document, whose main part offers shapes in a namespace it does not declare
# ignorable as an alternative and so is processed to find it needs nothing
# declared. The undeclared example costs the small one's and processing its
# main part.
exact_ceiling : Input -> Try(U64, [NotDeclared])
exact_ceiling = |input|
	match input {
		Generated(program) if program == small_program => Ok(1_189)
		Generated(program) if program == large_program => Ok(9_273)
		Generated(program) if program == undeclared_program => Ok(1_298)
		Fixture(index) => fixtures.get(index).map_ok(|fixture| fixture.allocations).map_err(|_| NotDeclared)
		_ => Err(NotDeclared)
	}

# The small and large generated examples repeat one program, the large one
# sixteen times as often; their ceilings, 1,189 and 9,273, keep the growth
# linear, the small one mostly the constant cost of a package and of one
# DEFLATE compressor.
small_program : List(U8)
small_program = List.join(List.repeat(program_unit, 4))

large_program : List(U8)
large_program = List.join(List.repeat(program_unit, 64))

# The small program with the extension namespace spelled `w14` and not
# declared ignorable, as Google Docs exports write paragraph identifiers.
undeclared_program : List(U8)
undeclared_program = List.concat([8], small_program.drop_first(1))

# A paragraph with save identifiers and an extension attribute holding a
# proofing mark, a run with text and a rendered page break, an extension
# element and an alternative; then whitespace.
program_unit : List(U8)
program_unit = [7, 4, 3, 5, 1, 2, 6, 2, 0]

fixtures : List({ name : Str, bytes : List(U8), allocations : U64 })
fixtures = [
	{ name: "pandoc-basics", bytes: pandoc_basics, allocations: 16_296 },
	{ name: "libreoffice-basics", bytes: libreoffice_basics, allocations: 14_643 },
]

wordprocessingml : Str
wordprocessingml = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

# A package whose main document a program describes, with a picture beside
# it. The first byte chooses the prefixes the document is written with:
# WordprocessingML as `w` or `q`, and the extension namespace as `x`, `w14`
# or `ns1`, which the writer's table or its own numbering also use; and
# whether the extension namespace is declared ignorable, which Google Docs
# exports leave out.
generated_package : List(U8) -> List(U8)
generated_package = |program| {
	choice = (program.first() ?? 0).to_u64()
	w = pick(["w", "q"], choice)
	x = pick(["x", "w14", "ns1"], choice // 2)
	ignorable = if ((choice // 8) % 2 == 0) " mc:Ignorable='${x}'" else ""
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
			_ => { text: "<${w}:p ${w}:rsidR='00A1' ${x}:mark='1'>", open: ["${w}:p"] }
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
	document = List.join(["<${w}:document ${declarations}><${w}:body>".to_utf8(), $body, "</${w}:body></${w}:document>".to_utf8()])
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
		Fuzz.example({ name: "small-document", revision: "1", make: || Generated(small_program) }),
		Fuzz.example({ name: "large-document", revision: "1", make: || Generated(large_program) }),
		Fuzz.example({ name: "undeclared-extension", revision: "1", make: || Generated(undeclared_program) }),
	].concat(fixtures.map_with_index(|fixture, index| Fuzz.example({ name: fixture.name, revision: "1", make: || Fixture(index) }))),
	generator,
	test!,
	show: |input| Str.inspect(input),
})
