app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.27.0/9yjxqdGTP4xSpSEmDazwTmRsehfRZzA19pwEKkR6fj1g.tar.zst",
	docx: "../../package/main.roc",
}

import cli.OsStr
import cli.Path
import cli.Stdout
import docx.Build
import docx.Docx
import docx.Document

# Write a report with tables, a header and a footer: a title in the header,
# the page number and count in the footer, a footnote, a table with a header
# row and a total, and a landscape section after a section break for a wide
# table, with a header of its own.
#
#     cd examples/report && roc main.roc              # writes report.docx
#     cd examples/report && roc main.roc out.docx
main! : List([Utf8(Str), UnixBytes(List(U8)), WindowsU16s(List(U16))]) => Try({}, _)
main! = |args| {
	output = match args {
		[to] => Path.from_os_str(OsStr.from_raw(to))
		_ => Path.utf8("report.docx")
	}
	document = report()?
	Path.write_bytes!(output, Docx.to_bytes(document)?)?

	Stdout.line!("Sections of ${Path.display(output)}:")?
	for section in Docx.sections(document) {
		page = match section.page_size {
			Size({ width, height, orientation }) => "${width.to_str()} by ${height.to_str()} twips, ${Str.inspect(orientation)}"
			Unset => "unset"
		}
		Stdout.line!("  ${page}; header ${region(document, section.headers)}; footer ${region(document, section.footers)}")?
	}
	Ok({})
}

# The text of a section's own header or footer for every page.
region : Document, List(Document.HeaderFooter) -> Str
region = |document, references|
	match references.find_first(|reference| reference.kind == Default) {
		Ok(reference) => {
			texts = Docx.header_footer(document, reference.part).map(
				|block|
					match block {
						Paragraph(paragraph) => Document.paragraph_text(paragraph)
						_ => ""
					},
			)
			"\"${Str.join_with(texts, " ")}\""
		}

		Err(_) => "as before"
	}

# The report: the first section's header and footer are given before the
# section break, so the landscape section shows its footer and its own
# header.
report : () -> Try(Document, _)
report = || {
	created = Docx.new_document({ title: Text("Quarterly sales"), creator: Text("Iris Cole"), created: Date("2026-10-05T09:00:00Z") })?
	described = Build.properties(created, { subject: Text("Sales from July to September 2026"), keywords: Text("sales, quarterly") })?
	headed = Build.header(described, {}, [Build.paragraph({ alignment: Right }, [Build.text("Harbour Lane Bakery: quarterly sales", { italic: On })])])?
	footed = Build.footer(headed, {}, [Build.paragraph({ alignment: Center }, [Build.text("Page ", {}), Build.page_number, Build.text(" of ", {}), Build.page_count])])?
	noted = Build.footnote(footed, [Build.text("Wholesale orders are left out.", {})])?
	# A row of a table: a label, then figures aligned right, all in bold or none.
	row = |weight, label, figures| {
		text = |words| Build.text(words, { bold: if (weight == Bold) On else Unset })
		List.prepend(figures.map(|figure| Build.cell({}, [Build.paragraph({ alignment: Right }, [text(figure)])])), Build.cell({}, [Build.paragraph({}, [text(label)])]))
	}
	summary = Build.append(
		noted.document,
		[
			Build.paragraph({ style: Heading(1) }, [Build.text("Quarterly sales", {})]),
			Build.paragraph({}, [Build.text("Sales at both shops peaked in August", {}), noted.reference, Build.text(", led by the Quay Street shop.", {})]),
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
	detail = Build.append(
		Build.new_section(summary, { orientation: Landscape }),
		[
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
	Build.header(detail, {}, [Build.paragraph({ alignment: Right }, [Build.text("Harbour Lane Bakery: sales by product", { italic: On })])])
}
