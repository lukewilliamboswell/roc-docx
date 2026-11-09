app [target] {
	docx: "../../package/main.roc",
	fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.5.0/9WT86CuwM7ZJBSs8iTd1jLyrUFTTiGp5hcJE63TwswGE.tar.zst",
	zip: "https://github.com/lukewilliamboswell/roc-zip/releases/download/0.3.0-rc1/3vvx2cPVp1vjjVgrXcugJqqfrp55ZrURYQUcSArAUHdr.tar.zst",
}

import fuzz.Fuzz
import docx.Opc
import zip.Zip

## Any bytes open to `Ok` or a structured `Err`, never a crash; opening the
## same bytes twice gives the same result; an opened package labels every
## part with a name and a content type.
##
## Allocation ratchets, which only ever move down: opening allocates at most
## linearly in the input, and the declared minimal package allocates no more
## than it did when the ceiling was set. Raising a ceiling needs a cause
## recorded in the pull request.
test! : List(U8) => Fuzz.Outcome
test! = |bytes| {
	{ value: first, stats } = Fuzz.measure!("opc-open", || Opc.open(bytes, {}))
	allocations = stats.allocs + stats.reallocs
	if allocations > linear_allocation_ceiling(bytes.len()) {
		crash "Opc.open allocated more than linearly in its input"
	}
	if stats.peak_live_bytes > linear_memory_ceiling(bytes.len()) {
		crash "Opc.open held more than linearly many bytes live"
	}
	if bytes == minimal_package() and allocations > minimal_package_allocation_ceiling {
		crash "Opc.open allocated more on the minimal package than its ceiling"
	}
	if first != Opc.open(bytes, {}) {
		crash "opening the same bytes twice disagreed"
	}
	match first {
		Ok(pkg) => {
			if pkg.parts.any(|part| !part.name.starts_with("/") or part.content_type.is_empty()) {
				crash "an opened part lacks an absolute name or a content type"
			}
			Fuzz.keep
		}
		Err(_) => Fuzz.keep
	}
}

# Measured 52 allocations and 5 reallocations on nightly-2026-11-07 with
# roc-zip 0.3.0-rc1; the fixed part is the ZIP layer's decode tables.
minimal_package_allocation_ceiling : U64
minimal_package_allocation_ceiling = 57

linear_allocation_ceiling : U64 -> U64
linear_allocation_ceiling = |input_bytes| 16 + input_bytes

linear_memory_ceiling : U64 -> U64
linear_memory_ceiling = |input_bytes| 16_384 + 32 * input_bytes

# The smallest package `Opc.main_document` resolves: content types, the
# package relationships and a main document part.
minimal_package : () -> List(U8)
minimal_package = || {
	content_types = "<Types xmlns='http://schemas.openxmlformats.org/package/2006/content-types'><Default Extension='rels' ContentType='application/vnd.openxmlformats-package.relationships+xml'/><Default Extension='xml' ContentType='application/xml'/><Override PartName='/word/document.xml' ContentType='application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml'/></Types>"
	rels = "<Relationships xmlns='http://schemas.openxmlformats.org/package/2006/relationships'><Relationship Id='rId1' Type='http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument' Target='word/document.xml'/></Relationships>"
	document = "<w:document xmlns:w='http://schemas.openxmlformats.org/wordprocessingml/2006/main'><w:body><w:p/></w:body></w:document>"
	Zip.create(
		[
			{ path: "[Content_Types].xml", content: content_types.to_utf8() },
			{ path: "_rels/.rels", content: rels.to_utf8() },
			{ path: "word/document.xml", content: document.to_utf8() },
		],
		Fastest,
	) ?? crash "minimal_package: the paths are valid"
}

target = Fuzz.target_with!({
	name: "opc-open-never-crashes",
	examples: [
		Fuzz.example({ name: "empty", revision: "1", make: || [] }),
		Fuzz.example({ name: "zip-signature-only", revision: "1", make: || [0x50, 0x4B, 0x03, 0x04] }),
		Fuzz.example({ name: "minimal-package", revision: "1", make: minimal_package }),
	],
	generator: Fuzz.bytes,
	test!,
	show: |bytes| Str.inspect(bytes),
})
