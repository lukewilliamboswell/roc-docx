import fuzz.Solve
import docx.Docx
import docx.Document
import docx.Lenient
import docx.Opc
import docx.WmlRead
import docx.XmlTree

## A carry produced by scaling a fractional digit cannot overflow, and taking
## its tens leaves a carry of at most 999 for the next digit. The factor and
## incoming carry are bounded independently by their largest values.
expect Solve.prove_within(
	{ digit: Solve.u32_in(0, 9), factor: Solve.u32_in(0, 1_000), carry: Solve.u32_in(0, 999) }.Solve,
	|v| (v.digit * v.factor + v.carry).lt(10_000),
	5_000,
) == Ok(Proved)

## The four-digit carry uses the same invariant as one digit. The
## maximum factor bounds every smaller nonnegative factor.
expect Solve.prove_within(
	{ group: Solve.u32_in(0, 9_999), carry: Solve.u32_in(0, 999) }.Solve,
	|v| (v.group * 1_000 + v.carry).lt(10_000_000),
	5_000,
) == Ok(Proved)

## Fifteen whole digits and a factor of at most 1000 bound the scaled integer.
## Even with the largest fractional carry and the increment for rounding up,
## the magnitude fits I64, so applying either sign is safe.
expect Solve.prove_within(
	Solve.u64_in(0, 999_999_999_999_999),
	|mantissa| (mantissa * 1_000 + 999 + 1).lt(9_223_372_036_854_775_808),
	5_000,
) == Ok(Proved)

## Signs and the maximum whole prefix reach the decimal parser. The factor is
## tested at zero, at its upper bound, and with a recurring halfway
## threshold (1/6 at factor 3) that cannot be decided by a fixed prefix.
expect {
	Lenient.decimal("-999999999999999.5", 1) == Ok({ value: -1_000_000_000_000_000, exact: Bool.False })
		and Lenient.decimal("999999999999999.999", 1_000) == Ok({ value: 999_999_999_999_999_999, exact: Bool.True })
		and Lenient.decimal("999999999999999.5x", 1) == Err(NotNumber)
		and Lenient.decimal("999999999999999", 1_001) == Err(NotNumber)
		and Lenient.decimal("999999999999999.999", 0) == Ok({ value: 0, exact: Bool.True })
		and Lenient.decimal("0.1666666666666666666666", 3) == Ok({ value: 0, exact: Bool.False })
		and Lenient.decimal("0.1666666666666666666667", 3) == Ok({ value: 1, exact: Bool.False })
}

## ECMA-376 Part 4 types gridCol/@w as ST_TwipsMeasure. Repair its
## unitless fractional spelling at the halfway point. For the table and
## cell CT_TblWidth/@w percentage arm of ST_MeasurementOrPercent, .00999...
## and .01 straddle a half-unit, and .02 converts to fiftieths exactly.
expect {
	pct_tie = "10000000000000.01%"
	pct_below = "10000000000000.0099999999999999%"
	pct_exact = "10000000000000.02%"
	grid_tie = "999999999999998.5"
	table_width = "<w:tblPr><w:tblW w:w='${pct_tie}' w:type='pct'/></w:tblPr>"
	grid_width = "<w:tblGrid><w:gridCol w:w='${grid_tie}'/></w:tblGrid>"
	cell = |pct| "<w:tc><w:tcPr><w:tcW w:w='${pct}' w:type='pct'/></w:tcPr><w:p/></w:tc>"
	xml = "<w:document xmlns:w='http://schemas.openxmlformats.org/wordprocessingml/2006/main'><w:body><w:tbl>${table_width}${grid_width}<w:tr>${cell(pct_below)}${cell(pct_exact)}</w:tr></w:tbl></w:body></w:document>"
	tree = XmlTree.parse(xml.to_utf8(), {}) ?? Text("")
	result = WmlRead.read_body(tree, { relationships: [], footnotes: [], endnotes: [], comments: [] })
	match result.blocks {
		[Table({ properties, grid, content: [Row({ content: [Cell(below), Cell(exact)], .. })] })] =>
			properties.width == Fiftieths(500_000_000_000_001)
				and grid == [Column(999_999_999_999_999)]
				and below.properties.width == Fiftieths(500_000_000_000_000)
				and exact.properties.width == Fiftieths(500_000_000_000_001)
				and result.diagnostics == [
					Rounded({ element: "tblW", attribute: "w", value: pct_tie }),
					Rounded({ element: "gridCol", attribute: "w", value: grid_tie }),
					Rounded({ element: "tcW", attribute: "w", value: pct_below }),
				]

		_ => Bool.False
	}
}

## At the U64 digit boundary, the last digit may be at most five
## after 1844674407370955161. The subtraction/division guard agrees
## with this decimal boundary and prevents either multiply or add overflow.
expect Solve.prove_within(
	{ prefix: Solve.u64_in(1_844_674_407_370_955_159, 1_844_674_407_370_955_163), digit: Solve.u64_in(0, 9) }.Solve,
	|v| {
		limit = Solve.num(U64.highest)
		admitted = v.prefix.lte((limit - v.digit) // 10)
		expected = Solve.any([
			v.prefix.lt(1_844_674_407_370_955_161),
			Solve.all([v.prefix.eq(1_844_674_407_370_955_161), v.digit.lte(5)]),
		])
		Solve.all([expected.implies(admitted), admitted.implies(expected), admitted.implies((v.prefix * 10 + v.digit).lte(limit))])
	},
	5_000,
) == Ok(Proved)

## The factor-50 width guard includes the fractional carry and the extra
## magnitude for the signed minimum. At the last admissible whole value,
## the remaining capacity is seven fiftieths, or eight for a negative width.
expect Solve.prove_within(
	{
		whole: Solve.u64_in(184_467_440_737_095_514, 184_467_440_737_095_518),
		fraction: Solve.u64_in(0, 50),
		negative: Solve.bool,
	}.Solve,
	|v| {
		extra = Solve.if_else(v.negative, Solve.num(1), Solve.num(0))
		limit = Solve.num(9_223_372_036_854_775_807) + extra
		admitted = v.whole.lte((limit - v.fraction) // 50)
		expected = Solve.any([
			v.whole.lt(184_467_440_737_095_516),
			Solve.all([v.whole.eq(184_467_440_737_095_516), v.fraction.lte(7 + extra)]),
		])
		Solve.all([expected.implies(admitted), admitted.implies(expected), admitted.implies((v.whole * 50 + v.fraction).lte(limit))])
	},
	5_000,
) == Ok(Proved)

## Checked accumulation accepts the last U64 digit and the signed minimum,
## rejects overflow from the whole digits, scaling or the rounding carry,
## and validates the remaining lexical digits on either side of the point.
expect {
	Lenient.unsigned_measure("+0000000000000000000018446744073709551615.49") == Ok(U64.highest)
		and Lenient.unsigned_measure("18446744073709551615.5") == Err(NotNumber)
		and Lenient.unsigned_measure("18446744073709551616") == Err(NotNumber)
		and Lenient.unsigned_measure("-0.49") == Ok(0)
		and Lenient.unsigned_measure("-0.5") == Err(NotNumber)
		and Lenient.measure("9223372036854775807.49", 1) == Ok({ value: I64.highest, exact: Bool.False })
		and Lenient.measure("9223372036854775807.5", 1) == Err(NotNumber)
		and Lenient.measure("-9223372036854775808.49", 1) == Ok({ value: I64.lowest, exact: Bool.False })
		and Lenient.measure("-9223372036854775808.5", 1) == Err(NotNumber)
		and Lenient.measure("184467440737095516.14999999999999999", 50) == Ok({ value: I64.highest, exact: Bool.False })
		and Lenient.measure("184467440737095516.15", 50) == Err(NotNumber)
		and Lenient.measure("-184467440737095516.15", 50) == Ok({ value: I64.lowest, exact: Bool.False })
		and Lenient.measure("-184467440737095516.17", 50) == Err(NotNumber)
		and Lenient.measure("368934881474191032.31", 50) == Err(NotNumber)
		and Lenient.measure("123.0x000000000000000000000000000000", 50) == Err(NotNumber)
		and Lenient.measure("123.0x000000000000000000000000000000", 3) == Err(NotNumber)
		and Lenient.measure("0.00800000000000000000001", 125) == Ok({ value: 1, exact: Bool.False })
		and Lenient.measure("0.00800000000000000000000", 125) == Ok({ value: 1, exact: Bool.True })
		and Lenient.measure("123.120000000000000000000000000001", 50) == Ok({ value: 6156, exact: Bool.False })
		and Lenient.measure("123.120000000000000000000000000000", 50) == Ok({ value: 6156, exact: Bool.True })
}

## The CT_TblWidth decimal arm can exceed the model's I64. Grid twips
## use the U64 arm of ST_TwipsMeasure. Read the written package through
## the facade to check canonical values at both bounds and preservation
## of schema-valid widths that exceed the model's range.
expect {
	part = "/word/document.xml"
	grid_tie = "999999999999999.5"
	grid_high = "18446744073709551614.5"
	pct_tie = "999999999999999.01%"
	twips_low = "-9223372036854775807.5"
	pct_high = "184467440737095516.14%"
	pct_outside = "9223372036854775808"
	scaled_outside = "184467440737095516.15%"
	properties = "<w:tblPr><w:tblW w:w='${pct_tie}' w:type='pct'/></w:tblPr>"
	grid = "<w:tblGrid><w:gridCol w:w='${grid_tie}'/><w:gridCol w:w='${grid_high}'/></w:tblGrid>"
	cell = |width, kind| "<w:tc><w:tcPr><w:tcW w:w='${width}' w:type='${kind}'/></w:tcPr><w:p/></w:tc>"
	row = "<w:tr>${cell(twips_low, "dxa")}${cell(pct_high, "pct")}</w:tr>"
	outside_row = "<w:tr>${cell(pct_outside, "pct")}${cell(scaled_outside, "pct")}</w:tr>"
	xml = "<w:document xmlns:w='http://schemas.openxmlformats.org/wordprocessingml/2006/main'><w:body><w:tbl>${properties}${grid}${row}${outside_row}</w:tbl></w:body></w:document>"
	source = Opc.to_bytes(
		{
			relationships: [{ id: "rId1", kind: Opc.officedocument_relationship, target: part, mode: Internal }],
			parts: [{ name: part, content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml", relationships: [] }],
		},
		|_| Bytes(xml.to_utf8()),
	)?
	first = Docx.parse(source)?
	written = Docx.to_bytes(first.document)?
	reopened = Docx.parse(written)?
	main = Str.from_utf8(Opc.part_bytes(Opc.open(written, {})?, part)?) ?? ""
	same = |document| match Docx.body(document) {
		[Table(table)] =>
			match Document.table_rows(table).map(|cells| Document.row_cells(cells).map(|c| c.properties)) {
				[[low, high], [outside, scaled]] =>
					table.properties.width == Fiftieths(49_999_999_999_999_951)
						and table.grid == [Column(1_000_000_000_000_000), Column(U64.highest)]
						and low.width == Twips(I64.lowest)
						and high.width == Fiftieths(I64.highest)
						and outside.width == Unset
						and outside.preserved.len() == 1
						and scaled.width == Unset
						and scaled.preserved.len() == 1
				_ => Bool.False
			}
		_ => Bool.False
	}
	same(first.document)
		and same(reopened.document)
		and reopened.diagnostics == []
		and Docx.read_body(reopened.document).diagnostics == []
		and main.contains("w:w=\"1000000000000000\"")
		and main.contains("w:w=\"18446744073709551615\"")
		and main.contains("w:w=\"49999999999999951\" w:type=\"pct\"")
		and main.contains("w:w=\"-9223372036854775808\" w:type=\"dxa\"")
		and main.contains("w:w=\"9223372036854775807\" w:type=\"pct\"")
		and main.contains("w:w=\"9223372036854775808\" w:type=\"pct\"")
		and main.contains("w:w=\"${scaled_outside}\" w:type=\"pct\"")
}
