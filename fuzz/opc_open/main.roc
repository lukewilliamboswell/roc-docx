app [target] {
	docx: "../../package/main.roc",
	fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.0/6uc3YKGydgEnS2nrCimSYWDNfT6drYcgU52VAwqrb6DS.tar.zst",
	zip: "https://github.com/lukewilliamboswell/roc-zip/releases/download/0.3.0-rc1/3vvx2cPVp1vjjVgrXcugJqqfrp55ZrURYQUcSArAUHdr.tar.zst",
}

import fuzz.Fuzz
import docx.Limits
import docx.Opc
import zip.Zip

## Any bytes open to `Ok` or a structured `Err`, never a crash; opening the
## same bytes twice gives the same result; an opened package labels every
## part with a name within the name limit and a content type, and every part
## reads back as the size it declares or as an error. A part name over the
## limit is refused before anything is inflated.
##
## Opening runs under lowered limits so that the declared bombs are bombs. It
## holds at most a constant plus multiples of the archive and of the parts it
## inflates, `[Content_Types].xml` and the relationship parts; reading a part
## holds at most a constant plus the part's declared size beyond what was live
## before. Allocation counts, of opening and of each part read, are linear in
## the input.
##
## Allocation ratchets, which only ever move down: the declared examples
## allocate no more than they did when their ceilings were set. Raising a
## ceiling needs a cause recorded in the pull request.
test! : List(U8) => Fuzz.Outcome
test! = |bytes| {
	example = declared_example(bytes)
	{ value: first, stats } = Fuzz.measure!("opc-open", || Opc.open(bytes, limits))
	allocations = stats.allocs + stats.reallocs
	if allocations > allocation_ceiling(example, bytes.len()) {
		crash "Opc.open allocated more than its ceiling"
	}
	if stats.peak_live_bytes > open_memory_ceiling(bytes.len(), inflated_at_open(bytes)) {
		crash "Opc.open held more than its archive and the parts it inflates allow"
	}
	opened = first.map_ok(Opc.parts)
	if opened != Opc.open(bytes, limits).map_ok(Opc.parts) {
		crash "opening the same bytes twice disagreed"
	}
	match example {
		TruthfulBomb =>
			if opened != Err(PartTooLarge({ name: "word/document.xml", bytes: bomb_bytes })) or stats.peak_live_bytes > bytes.len() + limits.max_part_bytes {
				crash "the truthful bomb was not refused by its declared size within the archive and the part limit"
			}
		LongPartName =>
			if opened != Err(PartNameTooLong({ name: long_part_name, bytes: long_part_name.count_utf8_bytes() })) or stats.peak_live_bytes > bytes.len() + limits.max_part_bytes {
				crash "the long part name was not refused before anything was inflated"
			}

		_ => {}
	}
	match first {
		Ok(pkg) => {
			var $read_allocations = 0.U64
			for part in Opc.parts(pkg) {
				if !part.name.starts_with("/") or part.content_type.is_empty() {
					crash "an opened part lacks an absolute name or a content type"
				}
				if part.name.count_utf8_bytes() > limits.max_part_name_bytes + 1 {
					crash "an opened part's name is longer than the limit"
				}
				{ value: read, stats: read_stats } = Fuzz.measure!("opc-part-bytes", || Opc.part_bytes(pkg, part.name))
				if read_stats.peak_live_bytes - read_stats.entry_live_bytes > read_memory_ceiling(part.size) {
					crash "Opc.part_bytes held more than the part's declared size"
				}
				if read_stats.allocs + read_stats.reallocs > allocation_ceiling(Generated, bytes.len()) {
					crash "Opc.part_bytes allocated more than linearly in the archive"
				}
				$read_allocations = $read_allocations + read_stats.allocs + read_stats.reallocs
				match read {
					Ok(content) =>
						if content.len() != part.size {
							crash "a part read back at a size other than it declares"
						}
					Err(_) =>
						if example == MinimalPackage or example == CompressiblePackage {
							crash "a part of a declared package did not read"
						}
				}
				if example == LyingBomb and part.name == "/word/document.xml" {
					if read != Err(PartSizeMismatch({ name: part.name, declared: lying_size })) or read_stats.peak_live_bytes > bytes.len() + limits.max_part_bytes {
						crash "the lying bomb was not stopped at its declared size within the archive and the part limit"
					}
				}
			}
			match read_allocation_ceiling(example) {
				Ok(ceiling) =>
					if $read_allocations > ceiling {
						crash "reading a declared package's parts allocated more than its ceiling"
					}

				Err(NotDeclared) => {}
			}
			Fuzz.keep
		}
		Err(_) =>
			if example == LyingBomb or example == CompressiblePackage or example == MinimalPackage {
				crash "a declared package failed to open"
			} else {
				Fuzz.keep
			}
	}
}

limits : Limits
limits = { max_entries: 64, max_part_name_bytes: 64, max_part_bytes: 65_536, max_total_bytes: 1_048_576 }

# The declared sizes of the parts opening inflates; nothing when the central
# directory does not read.
inflated_at_open : List(U8) -> U64
inflated_at_open = |bytes|
	match Zip.entries(bytes) {
		Ok(entries) =>
			entries
				.keep_if(|entry| entry.path == "[Content_Types].xml" or entry.path.ends_with(".rels"))
				.fold(0, |total, entry| total.plus_saturated(entry.uncompressed_size))
		Err(_) => 0
	}

open_memory_ceiling : U64, U64 -> U64
open_memory_ceiling = |input_bytes, inflated_bytes| 16_384 + 32 * input_bytes + 32 * inflated_bytes

read_memory_ceiling : U64 -> U64
read_memory_ceiling = |part_bytes| 16_384 + part_bytes

# Exact allocation ceilings measured on nightly-2026-11-10-f7d1f19
# with roc-fuzz 0.6.0, roc-zip 0.3.0-rc1 and roc-parser 6.0.0-rc.1.
# Other inputs use the linear bound.
allocation_ceiling : [MinimalPackage, TruthfulBomb, LyingBomb, CompressiblePackage, LongPartName, Generated], U64 -> U64
allocation_ceiling = |example, input_bytes|
	match example {
		MinimalPackage => 66
		TruthfulBomb => 3
		LongPartName => 3
		LyingBomb => 66
		CompressiblePackage => 66
		Generated => 16 + input_bytes
	}

# Exact ceilings on reading every part of a declared package that opens,
# measured with the ceilings above: the document part takes 12 allocations
# and reallocations, its inflater's tables and output, and the relationship
# part, kept inflated from opening, 1.
read_allocation_ceiling : [MinimalPackage, TruthfulBomb, LyingBomb, CompressiblePackage, LongPartName, Generated] -> Try(U64, [NotDeclared])
read_allocation_ceiling = |example|
	match example {
		MinimalPackage | LyingBomb | CompressiblePackage => Ok(13)
		TruthfulBomb | LongPartName | Generated => Err(NotDeclared)
	}

declared_example : List(U8) -> [MinimalPackage, TruthfulBomb, LyingBomb, CompressiblePackage, LongPartName, Generated]
declared_example = |bytes|
	if bytes == minimal_package() {
		MinimalPackage
	} else if bytes == truthful_bomb() {
		TruthfulBomb
	} else if bytes == lying_bomb() {
		LyingBomb
	} else if bytes == compressible_package() {
		CompressiblePackage
	} else if bytes == long_part_name_package() {
		LongPartName
	} else {
		Generated
	}

content_types : Str
content_types = "<Types xmlns='http://schemas.openxmlformats.org/package/2006/content-types'><Default Extension='rels' ContentType='application/vnd.openxmlformats-package.relationships+xml'/><Default Extension='xml' ContentType='application/xml'/><Override PartName='/word/document.xml' ContentType='application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml'/></Types>"

package_rels : Str
package_rels = "<Relationships xmlns='http://schemas.openxmlformats.org/package/2006/relationships'><Relationship Id='rId1' Type='http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument' Target='word/document.xml'/></Relationships>"

# A package of content types, the package relationships and this main
# document part.
package_with : List(U8) -> List(U8)
package_with = |document|
	Zip.create(
		[
			{ path: "[Content_Types].xml", content: content_types.to_utf8() },
			{ path: "_rels/.rels", content: package_rels.to_utf8() },
			{ path: "word/document.xml", content: document },
		],
		Fastest,
	) ?? crash "package_with: the paths are valid"

# The smallest package `Opc.main_document` resolves.
minimal_package : () -> List(U8)
minimal_package = || package_with("<w:document xmlns:w='http://schemas.openxmlformats.org/wordprocessingml/2006/main'><w:body><w:p/></w:body></w:document>".to_utf8())

# A main document of a mebibyte of zeros, which compresses to a 1,900-byte
# archive, declaring its true size: over the part limit.
truthful_bomb : () -> List(U8)
truthful_bomb = || package_with(List.repeat(0, bomb_bytes))

bomb_bytes : U64
bomb_bytes = 1_048_576

# The same bomb with its central directory declaring a size within the part
# limit, so that only inflating it can find the lie.
lying_bomb : () -> List(U8)
lying_bomb = || declare_size(truthful_bomb(), "word/document.xml", lying_size)

lying_size : U64
lying_size = 4_096

# A legitimate package whose main document is 58 KB of repeated paragraphs,
# within the part limit, in a 1,033-byte archive.
compressible_package : () -> List(U8)
compressible_package = || {
	paragraph = "<w:p><w:r><w:t>The same sentence, again.</w:t></w:r></w:p>"
	package_with("<w:document xmlns:w='http://schemas.openxmlformats.org/wordprocessingml/2006/main'><w:body>${Str.repeat(paragraph, 1_000)}</w:body></w:document>".to_utf8())
}

# The minimal package with a part whose name is over the name limit, ahead
# of the others and over the part limit too, so that only its name can be
# what refuses it first.
long_part_name_package : () -> List(U8)
long_part_name_package = || {
	parts = [
		{ path: long_part_name, content: List.repeat(0, bomb_bytes) },
		{ path: "[Content_Types].xml", content: content_types.to_utf8() },
		{ path: "_rels/.rels", content: package_rels.to_utf8() },
	]
	Zip.create(parts, Fastest) ?? crash "long_part_name_package: the paths are valid"
}

long_part_name : Str
long_part_name = "word/${Str.repeat("a", 96)}.xml"

# Rewrite the uncompressed size that the central directory declares for one
# entry. The archive has no comment and no ZIP64 records, as `Zip.create`
# writes it for these sizes.
declare_size : List(U8), Str, U64 -> List(U8)
declare_size = |archive, path, size| {
	directory_offset = read_u32(archive, archive.len() - 22 + 16)
	var $offset = directory_offset
	var $patched = archive
	while $offset + 46 <= archive.len() and read_u32(archive, $offset) == 0x02014B50 {
		name_len = read_u16(archive, $offset + 28)
		extra_len = read_u16(archive, $offset + 30)
		comment_len = read_u16(archive, $offset + 32)
		name = archive.sublist({ start: $offset + 46, len: name_len })
		if name == path.to_utf8() {
			$patched = write_u32($patched, $offset + 24, size)
		}
		$offset = $offset + 46 + name_len + extra_len + comment_len
	}
	$patched
}

read_u16 : List(U8), U64 -> U64
read_u16 = |bytes, at|
	byte_at(bytes, at) + 256 * byte_at(bytes, at + 1)

read_u32 : List(U8), U64 -> U64
read_u32 = |bytes, at|
	read_u16(bytes, at) + 65_536 * read_u16(bytes, at + 2)

byte_at : List(U8), U64 -> U64
byte_at = |bytes, at| bytes.get(at).map_ok(|byte| byte.to_u64()) ?? 0

write_u32 : List(U8), U64, U64 -> List(U8)
write_u32 = |bytes, at, value|
	bytes
		.sublist({ start: 0, len: at })
		.concat([1, 256, 65_536, 16_777_216].map(|unit| ((value // unit) % 256).to_u8_wrap()))
		.concat(bytes.drop_first(at + 4))

target = Fuzz.target_with!({
	name: "opc-open-never-crashes",
	examples: [
		Fuzz.example({ name: "empty", revision: "1", make: || [] }),
		Fuzz.example({ name: "zip-signature-only", revision: "1", make: || [0x50, 0x4B, 0x03, 0x04] }),
		Fuzz.example({ name: "minimal-package", revision: "1", make: minimal_package }),
		Fuzz.example({ name: "truthful-bomb", revision: "1", make: truthful_bomb }),
		Fuzz.example({ name: "lying-bomb", revision: "1", make: lying_bomb }),
		Fuzz.example({ name: "compressible-package", revision: "1", make: compressible_package }),
		Fuzz.example({ name: "long-part-name", revision: "1", make: long_part_name_package }),
	],
	generator: Fuzz.bytes,
	test!,
	show: |bytes| Str.inspect(bytes),
})
