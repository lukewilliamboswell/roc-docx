app [target] {
	docx: "../../package/main.roc",
	fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.5.0/9WT86CuwM7ZJBSs8iTd1jLyrUFTTiGp5hcJE63TwswGE.tar.zst",
	zip: "https://github.com/lukewilliamboswell/roc-zip/releases/download/0.3.0-rc1/3vvx2cPVp1vjjVgrXcugJqqfrp55ZrURYQUcSArAUHdr.tar.zst",
}

import fuzz.Fuzz
import docx.Build
import docx.Comments
import docx.Docx
import docx.Document
import zip.Zip

## A document built by the builders writes and reads back as built, and
## building it costs what its content costs.
##
## A program of bytes describes a document chapter by chapter: headings,
## paragraphs of formatted text, list items, tables, links, footnotes and
## page number fields, the final section's page and the document's
## properties, and chapter ends, each a section break to a new page setup
## with a header and a footer of its own. Each chapter's footnotes are
## added by `Build.footnote`, its blocks made by the constructors and
## appended one at a time by `Build.append`, its page set by
## `Build.page_setup` and its properties by `Build.properties`, and a
## chapter end is `Build.new_section`, `Build.header` and `Build.footer`.
## The document is written by `Docx.to_bytes` and must read back
## equivalent to what was built, with a footnote for every footnote step
## and a section for every chapter. The example gallery's letter,
## agreement, minutes and report, built step for step as `examples/`
## builds them, must too.
##
## Allocation ratchets, which only ever move down: each entry point's
## calls together, the constructors', `Build.append`'s, `Build.footnote`'s,
## `Build.page_setup`'s, `Build.properties`', `Build.new_section`'s,
## `Build.header`'s and `Build.footer`'s, and writing, allocate at most
## linearly many times and hold at most linearly many bytes live in the
## size of the written document's parts, and each declared example
## allocates no more than it did when its ceiling was set. The gallery's
## documents are declared examples within the same linear ceilings. The
## long document, sixteen times as many chapters as the short one, measures
## the short one again in the same run and fails if any entry point
## allocates more than sixteen times as often, or requests or holds live
## more than `byte_ratio` says. Raising a ceiling needs a
## cause recorded in the pull request.
test! : Input => Fuzz.Outcome
test! = |input| {
	{ costs, size } = match input {
		Program(program) => {
			made = built!(program)
			written!(made.document, made.costs, made.expected)
		}

		Gallery(name) => {
			made = gallery!(name)
			written!(made.document, made.costs, Unchecked)
		}
	}
	for cost in costs {
		if allocations(cost.stats) > linear_allocation_ceiling(cost.region, cost.calls, size) {
			crash "${cost.region} allocated ${allocations(cost.stats).to_str()} times, more than linearly in its ${cost.calls.to_str()} calls and the written document's ${size.to_str()} bytes"
		}
		if held(cost.stats) > linear_memory_ceiling(cost.region, cost.calls, size) {
			crash "${cost.region} held ${held(cost.stats).to_str()} bytes live, more than linearly many in its ${cost.calls.to_str()} calls and the written document's ${size.to_str()} bytes"
		}
	}
	match exact_ceilings(input) {
		Ok(ceilings) =>
			for (region, ceiling) in ceilings {
				match costs.find_first(|cost| cost.region == region) {
					Ok(cost) =>
						if allocations(cost.stats) > ceiling {
							crash "a declared example allocated more than its ceiling in ${region}"
						}

					Err(_) => crash "a declared example did not measure ${region}"
				}
			}

		Err(NotDeclared) => {}
	}
	if input == Program(long_document) {
		short = built!(short_document)
		small = written!(short.document, short.costs, short.expected).costs
		for cost in costs {
			match small.find_first(|one| one.region == cost.region) {
				Ok(base) =>
					if allocations(cost.stats) > 16 * allocations(base.stats) + growth or cost.stats.requested_bytes > byte_ratio(cost.region) * base.stats.requested_bytes or held(cost.stats) > byte_ratio(cost.region) * held(base.stats) {
						crash "the long document cost more than the short one allows in ${cost.region}"
					}

				Err(_) => crash "the short document did not measure ${cost.region}"
			}
		}
	}
	Fuzz.keep
}

Input : [Program(List(U8)), Gallery([Letter, Agreement, Minutes, Report])]

generator : Fuzz.Generator(Input)
generator = Fuzz.map(Fuzz.bytes, |bytes| Program(bytes))

# What each entry point's calls cost together, by region, and how many
# calls, or blocks made or appended, they were.
Costs : List({ region : Str, calls : U64, stats : Fuzz.Stats })

# The allocations and reallocations a region made.
allocations : Fuzz.Stats -> U64
allocations = |stats| stats.allocs + stats.reallocs

# The bytes a region held live beyond those live when it began.
held : Fuzz.Stats -> U64
held = |stats| stats.peak_live_bytes - stats.entry_live_bytes

# The costs with more calls added to their region's: calls, counts and
# bytes requested summed, the most held live beyond entry kept.
merged : Costs, Str, U64, Fuzz.Stats -> Costs
merged = |costs, region, calls, stats|
	match costs.find_first_index(|cost| cost.region == region) {
		Ok(index) =>
			match costs.get(index) {
				Ok(before) => {
					sum = { ..before.stats, allocs: before.stats.allocs + stats.allocs, reallocs: before.stats.reallocs + stats.reallocs, requested_bytes: before.stats.requested_bytes + stats.requested_bytes, entry_live_bytes: 0, peak_live_bytes: held(before.stats).max(held(stats)) }
					List.set(costs, index, { region, calls: before.calls + calls, stats: sum }) ?? []
				}

				Err(_) => costs
			}

		Err(_) => List.append(costs, { region, calls, stats: { ..stats, entry_live_bytes: 0, peak_live_bytes: held(stats) } })
	}

# How many footnotes and sections a program's document has.
Expected : [Counted({ footnotes : U64, sections : U64 }), Unchecked]

# Write a built document, measured, and check that it reads back as built;
# the costs with writing's, and the size of the written parts.
written! : Document, Costs, Expected => { costs : Costs, size : U64 }
written! = |document, costs, expected| {
	{ value: writing, stats } = Fuzz.measure!("docx-to-bytes", || Docx.to_bytes(document))
	bytes = writing ?? crash "a built document did not write"
	read = (Docx.parse(bytes) ?? crash "a written document did not parse").document
	if !Docx.equivalent(document, read) {
		crash "a written document read back differently from what was built"
	}
	match expected {
		Counted(counted) =>
			if Docx.footnotes(read).keep_if(|note| note.kind == Note).len() != counted.footnotes or Docx.sections(read).len() != counted.sections {
				crash "a written document has other footnotes or sections than its program built"
			}

		Unchecked => {}
	}
	size = match Zip.entries(bytes) {
		Ok(entries) => entries.fold(0, |total, entry| total.plus_saturated(entry.uncompressed_size))
		Err(_) => crash "a written document's archive did not list its entries"
	}
	{ costs: List.append(costs, { region: "docx-to-bytes", calls: 1, stats }), size }
}

# ---- Programs -------------------------------------------------------------

# A chapter as a program gives it: its steps that make blocks, in order;
# the variants of its page setups and of its properties; and how it ends.
Chapter : { steps : List(U8), pages : List(U8), properties : List(U8), ending : [Ending(U8), Last] }

# The chapters of a program, at most `most_chapters`: each byte's low four
# bits choose its step and the rest its variant. A chapter end beyond the
# last chapter allowed ends nothing.
chapters : List(U8) -> List(Chapter)
chapters = |program| {
	empty = { steps: [], pages: [], properties: [], ending: Last }
	var $found = List.with_capacity(most_chapters)
	var $current = empty
	for byte in program {
		kind = byte % 16
		if kind == 7 and $found.len() + 1 < most_chapters {
			$found = List.append($found, { ..$current, ending: Ending(byte // 16) })
			$current = empty
		} else if kind == 8 {
			$current = { ..$current, pages: List.append($current.pages, byte // 16) }
		} else if kind == 9 {
			$current = { ..$current, properties: List.append($current.properties, byte // 16) }
		} else if kind != 7 {
			$current = { ..$current, steps: List.append($current.steps, byte) }
		}
	}
	List.append($found, $current)
}

# The most chapters a program has: each measures up to eight regions, and
# the long document's run measures the short one's too, within the 512
# regions roc-fuzz records for an input.
most_chapters : U64
most_chapters = 52

# Build a program's document, chapter by chapter, measuring each entry
# point; and what the document must read back with.
built! : List(U8) => { document : Document, costs : Costs, expected : Expected }
built! = |program| {
	# The document starts with the properties a properties step sets and
	# with different odd and even pages, so that every properties step and
	# every even page's header and footer changes what is there alike.
	created = Docx.new_document({}) ?? crash "the default document kit did not build"
	var $document = Docx.set_different_odd_and_even(with_properties(created, 0), On) ?? crash "different odd and even pages were refused"
	var $costs = List.with_capacity(16)
	var $footnotes = 0.U64
	var $sections = 1.U64
	var $number = 0.U64
	for chapter in chapters(program) {
		noting = chapter.steps.keep_if(|byte| byte % 16 == 5)
		var $references = List.with_capacity(noting.len())
		if !noting.is_empty() {
			measuring = Fuzz.start_measure!("build-footnote")
			for byte in noting {
				{ document: noted, reference } = Build.footnote($document, [Build.text("Figures for step ${(byte // 16).to_str()} are rounded.", {})]) ?? crash "a footnote was refused"
				$document = noted
				$references = List.append($references, reference)
			}
			$costs = merged($costs, "build-footnote", noting.len(), measuring.finish!())
			$footnotes = $footnotes + noting.len()
		}
		constructing = Fuzz.start_measure!("build-constructors")
		var $blocks = List.with_capacity(chapter.steps.len())
		var $noted = 0.U64
		for byte in chapter.steps {
			$number = $number + 1
			reference = if (byte % 16 == 5) ($references.get($noted) ?? Build.page_number) else Build.page_number
			$noted = if (byte % 16 == 5) $noted + 1 else $noted
			$blocks = List.append($blocks, step(byte % 16, byte // 16, $number, reference))
		}
		blocks = $blocks
		$costs = merged($costs, "build-constructors", blocks.len(), constructing.finish!())
		appending = Fuzz.start_measure!("build-append")
		for block in blocks {
			$document = Build.append($document, [block])
		}
		$costs = merged($costs, "build-append", blocks.len(), appending.finish!())
		if !chapter.pages.is_empty() {
			paging = Fuzz.start_measure!("build-page-setup")
			for variant in chapter.pages {
				$document = Build.page_setup($document, page(variant))
			}
			$costs = merged($costs, "build-page-setup", chapter.pages.len(), paging.finish!())
		}
		if !chapter.properties.is_empty() {
			describing = Fuzz.start_measure!("build-properties")
			for variant in chapter.properties {
				$document = with_properties($document, variant)
			}
			$costs = merged($costs, "build-properties", chapter.properties.len(), describing.finish!())
		}
		match chapter.ending {
			Ending(variant) => {
				sectioning = Fuzz.start_measure!("build-new-section")
				$document = Build.new_section($document, page(variant))
				$costs = merged($costs, "build-new-section", 1, sectioning.finish!())
				$sections = $sections + 1
				pages = { kind: pages_of(variant) }
				heading = Fuzz.start_measure!("build-header")
				$document = Build.header($document, pages, [Build.paragraph({ alignment: Right }, [Build.text("Chapter ${$sections.to_str()}", { italic: On })])]) ?? crash "a header was refused"
				$costs = merged($costs, "build-header", 1, heading.finish!())
				footing = Fuzz.start_measure!("build-footer")
				$document = Build.footer($document, pages, [Build.paragraph({ alignment: Center }, [Build.text("Page ", {}), Build.page_number, Build.text(" of ", {}), Build.page_count])]) ?? crash "a footer was refused"
				$costs = merged($costs, "build-footer", 1, footing.finish!())
			}

			Last => {}
		}
	}
	{ document: $document, costs: $costs, expected: Counted({ footnotes: $footnotes, sections: $sections }) }
}

# The document with the properties a properties step's variant sets.
with_properties : Document, U8 -> Document
with_properties = |document, variant| Build.properties(document, { title: Text("Annual report ${variant.to_str()}"), creator: Text("Iris Cole"), revision: Number(variant.to_u64()), modified: Date("2026-11-10T09:00:00Z") }) ?? crash "properties were refused"

# The block a step makes: a heading, a paragraph of plain, bold and italic
# text, a list item, a table, a paragraph with a link, one ending with a
# footnote's reference, one with the page number and count, or a paragraph
# of sized and coloured text.
step : U8, U8, U64, Document.Inline -> Document.Block
step = |kind, variant, number, reference| {
	said = "Paragraph ${number.to_str()} sets out the figures of the quarter for each shop and product, as the tables give them."
	match kind {
		0 => Build.paragraph({ style: Heading(1 + variant % 3) }, [Build.text("Section ${number.to_str()}", {})])
		1 => Build.paragraph({ alignment: Justified }, [Build.text(said, {}), Build.text(" Sales rose", { bold: On }), Build.text(" in every month but one.", { italic: On })])
		2 => Build.list_item({ list: if (variant % 2 == 0) Bulleted else Numbered, level: variant // 2 % 3 }, [Build.text("Item ${number.to_str()} of the list", {})])
		3 => {
			cell = |text| Build.cell({}, [Build.paragraph({ alignment: Right }, [Build.text(text, {})])])
			count = 2 + (variant % 8).to_u64()
			var $rows = List.with_capacity(count)
			var $row = 0.U64
			while $row < count {
				$rows = List.append($rows, [cell("Row ${$row.to_str()}"), cell((number * 100 + $row).to_str()), cell("${(number + $row).to_str()}%")])
				$row = $row + 1
			}
			Build.table({ widths: if (variant >= 8) [3026, 3000, 3000] else [], header_rows: 1 }, $rows)
		}

		4 => Build.paragraph({}, [Build.text("The full figures are at ", {}), Build.link("https://example.org/figures/${number.to_str()}", [Build.text("the bakery's site", {})]), Build.text(".", {})])
		5 => Build.paragraph({}, [Build.text(said, {}), reference])
		6 => Build.paragraph({ page_break_before: if (variant % 2 == 0) On else Unset }, [Build.text("This is page ", {}), Build.page_number, Build.text(" of ", {}), Build.page_count, Build.text(".", {})])
		_ => Build.paragraph({}, [Build.text(said, { size: HalfPoints(20 + 2 * variant.to_u32()), color: Rgb({ red: variant * 16, green: 64, blue: 32 }) })])
	}
}

# Which pages a chapter's header and footer are for, as a variant chooses:
# every page, even pages or the first page.
pages_of : U8 -> [Default, Even, First]
pages_of = |variant|
	match variant % 3 {
		0 => Default
		1 => Even
		_ => First
	}

# A page as a variant sets it: its paper, orientation and margins.
page : U8 -> Build.PageSetup
page = |variant| {
	size = match variant % 3 {
		0 => A4
		1 => Letter
		_ => Legal
	}
	margin = 720 + 180 * variant.to_u64()
	{ size, orientation: if (variant // 3 % 2 == 0) Portrait else Landscape, top: margin, right: margin, bottom: margin, left: margin }
}

# The short and long documents: three chapters, and forty-eight, many
# pages of paragraphs and tables.
short_document : List(U8)
short_document = chapters_unit

long_document : List(U8)
long_document = List.join(List.repeat(chapters_unit, 16))

# Three chapters, each a heading, paragraphs of formatted text, a bulleted
# and a numbered list, tables of nine and three rows, a link, two
# footnotes, the page number and count, the page set and the properties,
# ending with a section break to a landscape page whose header and footer
# are for even pages, every page and the first page.
chapters_unit : List(U8)
chapters_unit = List.join([chapter, [0x47], chapter, [0x37], chapter, [0x57]])

chapter : List(U8)
chapter = [0x00, 0x01, 0x01, 0x02, 0x12, 0x22, 0x01, 0x73, 0x01, 0x05, 0x01, 0x13, 0x0F, 0x04, 0x01, 0x15, 0x03, 0x03, 0x05, 0x06, 0x01, 0x0F, 0x08, 0x09]

# ---- The gallery ----------------------------------------------------------

# A gallery document, built as its example builds it, each builder's call
# measured; its comments and tracked changes are made unmeasured.
gallery! : [Letter, Agreement, Minutes, Report] => { document : Document, costs : Costs }
gallery! = |name|
	match name {
		Letter => letter!()
		Agreement => agreement!()
		Minutes => minutes!()
		Report => report!()
	}

# A builder's call measured into its region, as many calls as `calls` says:
# one, or for the constructors the blocks they make.
call! : Costs, Str, U64, (() => a) => { value : a, costs : Costs }
call! = |costs, region, calls, made!| {
	{ value, stats } = Fuzz.measure!(region, made!)
	{ value, costs: merged(costs, region, calls, stats) }
}

# The letter of `examples/letter`.
letter! : () => { document : Document, costs : Costs }
letter! = || {
	created = Docx.new_document({ title: Text("Winter deliveries"), creator: Text("Nora Quill"), created: Date("2026-11-10T09:00:00Z") }) ?? crash "the kit refused the letter's properties"
	content = call!(
		[],
		"build-constructors",
		9,
		|| {
			plain = |text| Build.paragraph({}, [Build.text(text, {})])
			[
				Build.paragraph({ alignment: Right }, [Build.text("Harbour Lane Bakery\n14 Quay Street\nPortwen", {})]),
				Build.paragraph({ alignment: Right }, [Build.text("10 November 2026", {})]),
				plain("Odile Fenwick\nOrchard Mill Supplies\n2 Mill Row\nAshcombe"),
				plain("Dear Ms Fenwick,"),
				Build.paragraph({}, [Build.text("Flour deliveries for the winter", { bold: On })]),
				Build.paragraph(
					{ alignment: Justified },
					[
						Build.text("Thank you for a year of reliable deliveries. From December we bake on Sundays too, so we would like ", {}),
						Build.text("two deliveries a week", { bold: On }),
						Build.text(", on Mondays and Thursdays, until the end of February.", {}),
					],
				),
				Build.paragraph({ alignment: Justified }, [Build.text("Our agreement for the new year follows separately. ", {}), Build.text("Please let me know by Friday", { italic: On }), Build.text(" whether the new days suit you.", {})]),
				plain("Yours sincerely,"),
				plain("Nora Quill\nOwner, Harbour Lane Bakery"),
			]
		},
	)
	appended = call!(content.costs, "build-append", 1, || Build.append(created, content.value))
	{ document: appended.value, costs: appended.costs }
}

# The agreement of `examples/agreement`: the buyer's draft, the supplier's
# two comments and the buyer's reply to the first.
agreement! : () => { document : Document, costs : Costs }
agreement! = || {
	created = Docx.new_document({ title: Text("Supply agreement"), creator: Text("Nora Quill"), created: Date("2026-11-10T09:00:00Z") }) ?? crash "the kit refused the agreement's properties"
	content = call!(
		[],
		"build-constructors",
		6,
		|| {
			clause = |text| Build.list_item({ list: Numbered }, [Build.text(text, {})])
			cell = |text| Build.cell({}, [Build.paragraph({}, [Build.text(text, {})])])
			[
				Build.paragraph({ style: Heading(1) }, [Build.text("Supply agreement", {})]),
				Build.paragraph({}, [Build.text("This agreement is made between ", {}), Build.text("Harbour Lane Bakery", { bold: On }), Build.text(", the buyer, and ", {}), Build.text("Orchard Mill Supplies", { bold: On }), Build.text(", the supplier.", {})]),
				clause("The supplier delivers flour to the bakery every Monday."),
				clause("The buyer pays each invoice within thirty days."),
				clause("Either party may end this agreement with sixty days' notice."),
				Build.table({ header_rows: 1 }, [[cell("For the buyer"), cell("For the supplier")], [cell("Nora Quill"), cell("Odile Fenwick")]]),
			]
		},
	)
	appended = call!(content.costs, "build-append", 1, || Build.append(created, content.value))
	document = appended.value
	text = Docx.text(document)
	odile = |date, said| { author: "Odile Fenwick", initials: Initials("OF"), date: Date(date), content: Text(said) }
	payment = Docx.add_comment(document, span_of(text, "within thirty days"), odile("2026-11-12T14:00:00Z", "We ask for payment within fourteen days.")) ?? crash "the agreement's first comment was refused"
	delivery = Docx.add_comment(payment.document, span_of(text, "every Monday"), odile("2026-11-12T14:05:00Z", "Could deliveries move to Tuesdays?")) ?? crash "the agreement's second comment was refused"
	replied = Docx.reply(delivery.document, payment.id, { author: "Nora Quill", initials: Initials("NQ"), date: Date("2026-11-13T09:30:00Z"), content: Text("Twenty-one days would suit us both.") }) ?? crash "the agreement's reply was refused"
	{ document: replied.document, costs: appended.costs }
}

# The minutes of `examples/minutes`: the secretary's draft, then the
# chair's corrections as tracked changes, each found in the text as it
# stands before it.
minutes! : () => { document : Document, costs : Costs }
minutes! = || {
	created = Docx.new_document({ title: Text("Staff meeting minutes"), creator: Text("Iris Cole"), created: Date("2026-11-03T17:00:00Z") }) ?? crash "the kit refused the minutes' properties"
	content = call!(
		[],
		"build-constructors",
		12,
		|| {
			heading = |text| Build.paragraph({ style: Heading(2) }, [Build.text(text, {})])
			item = |options, text| Build.list_item(options, [Build.text(text, {})])
			[
				Build.paragraph({ style: Heading(1) }, [Build.text("Staff meeting", {})]),
				Build.paragraph({}, [Build.text("Held on 3 November 2026 at the Quay Street shop.", {})]),
				heading("Present"),
				item({}, "Nora Quill, chair"),
				item({}, "Iris Cole, secretary"),
				item({}, "Tomas Reed"),
				heading("Decisions"),
				item({ list: Numbered }, "The shop opens at 7 a.m. from December."),
				item({ list: Numbered }, "Weekend shifts rotate monthly."),
				item({ list: Numbered }, "The old oven is sold."),
				heading("Next meeting"),
				Build.paragraph({}, [Build.text("The next meeting is on 1 December 2026.", {})]),
			]
		},
	)
	appended = call!(content.costs, "build-append", 1, || Build.append(created, content.value))
	nora = Tracked({ author: "Nora Quill", date: Date("2026-11-04T08:30:00Z") })
	tracking = Docx.set_tracking(appended.value, On) ?? crash "tracking was refused"
	earlier = Docx.replace_text(tracking, span_of(Docx.text(tracking), "7 a.m."), "6.30 a.m.", nora) ?? crash "a replacement was refused"
	paired = Docx.insert_text(earlier, span_of(Docx.text(earlier), "monthly").end, ", in pairs", nora) ?? crash "an insertion was refused"
	van = call!(appended.costs, "build-constructors", 1, || [Build.list_item({ list: Numbered }, [Build.text("A second delivery van is leased.", {})])])
	leased = Docx.insert_blocks(paired, span_of(Docx.text(paired), "Next meeting").start, van.value, nora) ?? crash "a block insertion was refused"
	{ document: Docx.delete_blocks(leased, span_of(Docx.text(leased), "The old oven is sold.\n"), nora) ?? crash "a block deletion was refused", costs: van.costs }
}

# The report of `examples/report`.
report! : () => { document : Document, costs : Costs }
report! = || {
	created = Docx.new_document({ title: Text("Quarterly sales"), creator: Text("Iris Cole"), created: Date("2026-10-05T09:00:00Z") }) ?? crash "the kit refused the report's properties"
	described = call!([], "build-properties", 1, || Build.properties(created, { subject: Text("Sales from July to September 2026"), keywords: Text("sales, quarterly") }))
	top = call!(described.costs, "build-constructors", 1, || [Build.paragraph({ alignment: Right }, [Build.text("Harbour Lane Bakery: quarterly sales", { italic: On })])])
	headed = call!(top.costs, "build-header", 1, || Build.header(described.value ?? crash "the report's properties were refused", {}, top.value))
	bottom = call!(headed.costs, "build-constructors", 1, || [Build.paragraph({ alignment: Center }, [Build.text("Page ", {}), Build.page_number, Build.text(" of ", {}), Build.page_count])])
	footed = call!(bottom.costs, "build-footer", 1, || Build.footer(headed.value ?? crash "the report's header was refused", {}, bottom.value))
	said = call!(footed.costs, "build-constructors", 1, || [Build.text("Wholesale orders are left out.", {})])
	noted = call!(said.costs, "build-footnote", 1, || Build.footnote(footed.value ?? crash "the report's footer was refused", said.value))
	note = noted.value ?? crash "the report's footnote was refused"
	row = |weight, label, figures| {
		text = |words| Build.text(words, { bold: if (weight == Bold) On else Unset })
		List.prepend(figures.map(|figure| Build.cell({}, [Build.paragraph({ alignment: Right }, [text(figure)])])), Build.cell({}, [Build.paragraph({}, [text(label)])]))
	}
	summary_content = call!(
		noted.costs,
		"build-constructors",
		7,
		|| [
			Build.paragraph({ style: Heading(1) }, [Build.text("Quarterly sales", {})]),
			Build.paragraph({}, [Build.text("Sales at both shops peaked in August", {}), note.reference, Build.text(", led by the Quay Street shop.", {})]),
			Build.paragraph({ style: Heading(2) }, [Build.text("Sales by shop", {})]),
			Build.table(
				{ widths: [3026, 2000, 2000, 2000], header_rows: 1 },
				[
					row(Bold, "Shop", ["July", "August", "September"]),
					row(Plain, "Quay Street", ["12,400", "13,150", "11,900"]),
					row(Plain, "Mill Row", ["8,300", "8,750", "8,100"]),
					row(Bold, "Total", ["20,700", "21,900", "20,000"]),
				],
			),
			Build.paragraph({ style: Heading(2) }, [Build.text("Highlights", {})]),
			Build.list_item({}, [Build.text("August was the best month of the quarter.", {})]),
			Build.list_item({}, [Build.text("Sunday baking starts in December.", {})]),
		],
	)
	summary = call!(summary_content.costs, "build-append", 1, || Build.append(note.document, summary_content.value))
	sectioned = call!(summary.costs, "build-new-section", 1, || Build.new_section(summary.value, { orientation: Landscape }))
	detail_content = call!(
		sectioned.costs,
		"build-constructors",
		2,
		|| [
			Build.paragraph({ style: Heading(2) }, [Build.text("Sales by product", {})]),
			Build.table(
				{ widths: [3958, 2000, 2000, 2000, 2000, 2000], header_rows: 1 },
				[
					row(Bold, "Product", ["Quay Street", "Mill Row", "Total", "Share", "Change"]),
					row(Plain, "Bread", ["21,000", "14,200", "35,200", "56%", "+4%"]),
					row(Plain, "Pastries", ["11,250", "7,600", "18,850", "30%", "+9%"]),
					row(Plain, "Cakes", ["5,200", "3,350", "8,550", "14%", "-2%"]),
				],
			),
		],
	)
	detail = call!(detail_content.costs, "build-append", 1, || Build.append(sectioned.value, detail_content.value))
	wide = call!(detail.costs, "build-constructors", 1, || [Build.paragraph({ alignment: Right }, [Build.text("Harbour Lane Bakery: sales by product", { italic: On })])])
	landscape = call!(wide.costs, "build-header", 1, || Build.header(detail.value, {}, wide.value))
	{ document: landscape.value ?? crash "the landscape header was refused", costs: landscape.costs }
}

# The span of the first `phrase` in `text`.
span_of : Str, Str -> Comments.Span
span_of = |text, phrase|
	match text.split_first(phrase) {
		Ok({ before, after: _ }) => {
			start = before.to_utf8().len()
			{ start, end: start + phrase.to_utf8().len() }
		}

		Err(NotFound) => crash "a gallery document's text does not hold \"${phrase}\""
	}

# ---- Ceilings -------------------------------------------------------------

# Linear ceilings on a region's allocations: each call of a builder costs at
# most a constant, a constructor's for each block it makes, so that a call
# whose cost grew with the document would exceed them; writing costs at most
# linearly in the written size. Measured on nightly-2026-11-07 (G5.4a), the
# most a chapter's two footnotes took is 157, and 222 for a document's first
# two, as the first reads the footnotes part's separators into the model; a
# call took at most 68 for properties, 63 for a footer, 52 for a header and
# 20 for a block on average
# with tables of up to nine rows; appending takes a reallocation now and
# then; page setups and section breaks change the body in place and allocate
# nothing; writing takes 0.31 to 0.45 a byte of the written parts.
linear_allocation_ceiling : Str, U64, U64 -> U64
linear_allocation_ceiling = |region, calls, size|
	match region {
		"docx-to-bytes" => 8192 + size
		"build-constructors" => 64 + 256 * calls
		"build-footnote" => 64 + 256 * calls
		"build-append" | "build-page-setup" | "build-new-section" => 16 + 8 * calls
		_ => 64 + 128 * calls
	}

# Linear ceilings on the bytes a region held live beyond its entry, in its
# calls and the written size. Every builder that may grow the body holds
# the old list and the new while it doubles: the long document's body,
# about 290 bytes a block, peaks at 594,736 bytes, 0.84 a byte of its
# parts, and a block's model is larger than its markup, so a body of short
# blocks holds several bytes a byte; sixteen allows them. The constructors
# hold a chapter's blocks, each with its content, up to 30 KB a block with a
# table. A footnote holds its note's model, which the document keeps, as
# appending holds the blocks it adds, and the list of notes while it
# doubles: 3,460 bytes a note for a chapter of 78 footnotes, beside a
# constant for writing the note once to check it. A header or footer holds
# its part's tree and, as the table of parts doubles, the old table and the
# new: at most 23,787 bytes for the long document, 0.03 a byte of its
# parts. Properties hold a constant. Writing holds 21 bytes a byte of the
# long document and the default document kit's parts beside it, 337 KB for
# the letter.
linear_memory_ceiling : Str, U64, U64 -> U64
linear_memory_ceiling = |region, calls, size|
	match region {
		"docx-to-bytes" => 1_048_576 + 32 * size
		"build-append" | "build-page-setup" | "build-new-section" => 65_536 + 16 * size
		"build-constructors" => 262_144 + 65_536 * calls
		"build-footnote" => 65_536 + 4096 * calls
		_ => 65_536 + size
	}

# Exact ceilings: the allocations and reallocations of each region of each
# declared example, as measured on nightly-2026-11-07 when the ceiling was
# set.
exact_ceilings : Input -> Try(List((Str, U64)), [NotDeclared])
exact_ceilings = |input|
	match input {
		Program(program) if program == short_document => Ok([("build-footnote", 535), ("build-constructors", 1440), ("build-append", 74), ("build-page-setup", 0), ("build-properties", 204), ("build-new-section", 0), ("build-header", 99), ("build-footer", 172), ("docx-to-bytes", 23_760)])
		Program(program) if program == long_document => Ok([("build-footnote", 7559), ("build-constructors", 23_040), ("build-append", 1070), ("build-page-setup", 0), ("build-properties", 3264), ("build-new-section", 0), ("build-header", 1586), ("build-footer", 2704), ("docx-to-bytes", 313_659)])
		Gallery(Letter) => Ok([("build-constructors", 72), ("build-append", 1), ("docx-to-bytes", 4518)])
		Gallery(Agreement) => Ok([("build-constructors", 65), ("build-append", 1), ("docx-to-bytes", 6181)])
		Gallery(Minutes) => Ok([("build-constructors", 59), ("build-append", 1), ("docx-to-bytes", 5494)])
		Gallery(Report) => Ok([("build-properties", 70), ("build-constructors", 300), ("build-header", 52), ("build-footer", 45), ("build-footnote", 110), ("build-append", 1), ("build-new-section", 0), ("docx-to-bytes", 8910)])
		_ => Err(NotDeclared)
	}

# The reallocations a large example may make beyond sixteen times its small
# one's allocations: the doublings of the lists that grow with it, one for
# each doubling of their length, as the long document's headers make two
# more than sixteen times the short one's 102.
growth : U64
growth = 16

# How many times its short example's bytes the long one may request and
# hold live in a region: eighteen, an eighth over the sixteen of the count,
# as sets, dictionaries and lists that grow by doubling cross their
# capacities, but for appending. Appending grows the body, a list that
# requests up to about twice its final size as it grows and holds the old
# and the new while it moves, so the long document's body, sixteen times
# the short one's, holds 20.4 times as many bytes at its peak: thirty-two,
# twice the count, as `fuzz/revision_algebra` allows its list of changes.
# Footnotes are held as the model and added to in place, and headers and
# footers add their parts without copying the table of parts: footnotes
# request 14.8 and headers 16.1 times the short example's bytes.
byte_ratio : Str -> U64
byte_ratio = |region|
	match region {
		"build-append" => 32
		_ => 18
	}

target = Fuzz.target_with!({
	name: "build-document",
	examples: [
		Fuzz.example({ name: "short-document", revision: "1", make: || Program(short_document) }),
		Fuzz.example({ name: "long-document", revision: "1", make: || Program(long_document) }),
		Fuzz.example({ name: "letter", revision: "1", make: || Gallery(Letter) }),
		Fuzz.example({ name: "agreement", revision: "1", make: || Gallery(Agreement) }),
		Fuzz.example({ name: "minutes", revision: "1", make: || Gallery(Minutes) }),
		Fuzz.example({ name: "report", revision: "1", make: || Gallery(Report) }),
	],
	generator,
	test!,
	show: |input| Str.inspect(input),
})
