import fuzz.Solve
import docx.Lenient
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
