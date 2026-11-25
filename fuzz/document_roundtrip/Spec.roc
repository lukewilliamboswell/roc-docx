import docx.Docx
import docx.Opc
import fuzz.Solve
import Streaming
import FieldHistories

Spec := [].{}

## Transitional CT_PageSz and the unsigned CT_PageMar attributes use
## ST_TwipsMeasure, whose decimal arm is unsignedLong. Both signed margins
## use ST_SignedTwipsMeasure, whose integer arm is unbounded. Exercise the
## typed model's U64 and I64 limits and preservation of a larger signed
## margin through the public document round trip.
expect {
	part = "/word/document.xml"
	size = "<w:pgSz w:w='18446744073709551615' w:h='1000000000000000' w:orient='landscape'/>"
	margins = "<w:pgMar w:top='-9223372036854775808' w:right='18446744073709551615' w:bottom='9223372036854775807' w:left='1000000000000000' w:header='18446744073709551615' w:footer='9223372036854775808' w:gutter='18446744073709551615'/>"
	outside = "<w:pgMar w:top='9223372036854775808' w:right='1' w:bottom='0' w:left='2' w:header='3' w:footer='4' w:gutter='5'/>"
	xml = "<w:document xmlns:w='http://schemas.openxmlformats.org/wordprocessingml/2006/main'><w:body><w:p><w:pPr><w:sectPr>${size}${margins}</w:sectPr></w:pPr></w:p><w:sectPr>${outside}</w:sectPr></w:body></w:document>"
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
	main = Str.from_utf8(Opc.part_bytes(Opc.open(written, {})?, part)?)?
	same = |document| match Docx.sections(document) {
		[held, beyond] =>
			held.page_size == Size({ width: U64.highest, height: 1_000_000_000_000_000, orientation: Landscape })
				and held.margins == Margins({ top: I64.lowest, right: U64.highest, bottom: I64.highest, left: 1_000_000_000_000_000, header: U64.highest, footer: 9_223_372_036_854_775_808, gutter: U64.highest })
				and held.preserved == []
				and beyond.margins == Unset
				and beyond.preserved.len() == 1
		_ => Bool.False
	}
	same(first.document)
		and same(reopened.document)
		and first.diagnostics == []
		and reopened.diagnostics == []
		and main.contains("w:w=\"18446744073709551615\"")
		and main.contains("w:top=\"-9223372036854775808\"")
		and main.contains("w:bottom=\"9223372036854775807\"")
		and main.contains("w:top=\"9223372036854775808\"")
}

## At the signed long boundary, the last decimal digit can be seven
## for a positive value and eight for a negative magnitude. The
## quotient/remainder guard agrees with checking the entire magnitude.
expect Solve.prove_within(
	{
		prefix: Solve.u64_in(922_337_203_685_477_578, 922_337_203_685_477_582),
		digit: Solve.u64_in(0, 9),
		negative: Solve.bool,
	}.Solve,
	|v| {
		extra = Solve.if_else(v.negative, Solve.num(1), Solve.num(0))
		limit = Solve.num(9_223_372_036_854_775_807) + extra
		prefix_limit = limit // 10
		admitted = Solve.any([v.prefix.lt(prefix_limit), Solve.all([v.prefix.eq(prefix_limit), v.digit.lte(limit % 10)])])
		within = (v.prefix * 10 + v.digit).lte(limit)
		Solve.all([admitted.implies(within), within.implies(admitted)])
	},
	5_000,
) == Ok(Proved)

# An independent corpus of decimal spellings and the intersection of their
# Transitional variant carrier with the I64 custom property model.
IntegerCase : { kind : Str, spelling : Str, expected : [Integer(I64), Preserved] }

check_custom_integers = |cases| {
	main = "/word/document.xml"
	custom = "/docProps/custom.xml"
	custom_ns = "http://schemas.openxmlformats.org/officeDocument/2006/custom-properties"
	variant_ns = "http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"
	rows = cases.map_with_index(|case, index| "<property fmtid='{D5CDD505-2E9C-101B-9397-08002B2CF9AE}' pid='${(index + 2).to_str()}' name='Count ${index.to_str()}'><vt:${case.kind}>${case.spelling}</vt:${case.kind}></property>")
	xml = "<Properties xmlns='${custom_ns}' xmlns:vt='${variant_ns}'>${Str.join_with(rows, "")}</Properties>"
	source = Opc.to_bytes(
		{
			relationships: [
				{ id: "rId1", kind: Opc.officedocument_relationship, target: main, mode: Internal },
				{ id: "rId2", kind: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/custom-properties", target: custom, mode: Internal },
			],
			parts: [
				{ name: main, content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml", relationships: [] },
				{ name: custom, content_type: "application/vnd.openxmlformats-officedocument.custom-properties+xml", relationships: [] },
			],
		},
		|name|
			if name == main {
				Bytes("<w:document xmlns:w='http://schemas.openxmlformats.org/wordprocessingml/2006/main'><w:body><w:p/></w:body></w:document>".to_utf8())
			} else {
				Bytes(xml.to_utf8())
			},
	)?
	first = Docx.parse(source)?
	written = Docx.to_bytes(first.document)?
	reopened = Docx.parse(written)?
	observed = Docx.custom_properties(first.document)
	Ok(
		observed.len() == cases.len()
			and List.map2(
				observed,
				cases,
				|property, case| match (property, case.expected) {
					(Property({ name: _, value: Integer(value) }), Integer(expected)) => value == expected
					(Preserved(_), Preserved) => Bool.True
					_ => Bool.False
				},
			).all(|matches| matches)
			and Docx.custom_properties(reopened.document) == observed,
	)
}

## The Transitional Variant Types schema declares signed byte, short, int and
## long, and their unsigned counterparts. All representable endpoints survive
## the custom properties query and a package round trip.
expect {
	cases : List(IntegerCase)
	cases = [
		{ kind: "i1", spelling: "-128", expected: Integer(-128) },
		{ kind: "i1", spelling: "127", expected: Integer(127) },
		{ kind: "i2", spelling: "-32768", expected: Integer(-32_768) },
		{ kind: "i2", spelling: "32767", expected: Integer(32_767) },
		{ kind: "i4", spelling: "-2147483648", expected: Integer(-2_147_483_648) },
		{ kind: "int", spelling: "2147483647", expected: Integer(2_147_483_647) },
		{ kind: "i8", spelling: "-9223372036854775808", expected: Integer(I64.lowest) },
		{ kind: "i8", spelling: "+00000000000009223372036854775807", expected: Integer(I64.highest) },
		{ kind: "ui1", spelling: "255", expected: Integer(255) },
		{ kind: "ui2", spelling: "65535", expected: Integer(65_535) },
		{ kind: "ui4", spelling: "4294967295", expected: Integer(4_294_967_295) },
		{ kind: "uint", spelling: "0", expected: Integer(0) },
		{ kind: "uint", spelling: "4294967295", expected: Integer(4_294_967_295) },
		{ kind: "ui8", spelling: "9223372036854775807", expected: Integer(I64.highest) },
		{ kind: "ui8", spelling: "9223372036854775808", expected: Preserved },
		{ kind: "ui8", spelling: "18446744073709551615", expected: Preserved },
	]
	check_custom_integers(cases)?
}

## Integer whitespace is collapsed only at XML whitespace boundaries.
## Out-of-carrier numbers and malformed spellings stay as preserved properties.
expect {
	cases : List(IntegerCase)
	cases = [
		{ kind: "i4", spelling: "\n\t+00045&#13; ", expected: Integer(45) },
		{ kind: "i1", spelling: "128", expected: Preserved },
		{ kind: "i1", spelling: "-129", expected: Preserved },
		{ kind: "i2", spelling: "-32769", expected: Preserved },
		{ kind: "i4", spelling: "2147483648", expected: Preserved },
		{ kind: "int", spelling: "-2147483649", expected: Preserved },
		{ kind: "i8", spelling: "-9223372036854775809", expected: Preserved },
		{ kind: "i8", spelling: "9223372036854775808", expected: Preserved },
		{ kind: "ui1", spelling: "-1", expected: Preserved },
		{ kind: "ui1", spelling: "256", expected: Preserved },
		{ kind: "ui2", spelling: "65536", expected: Preserved },
		{ kind: "ui4", spelling: "4294967296", expected: Preserved },
		{ kind: "uint", spelling: "-1", expected: Preserved },
		{ kind: "uint", spelling: "4294967296", expected: Preserved },
		{ kind: "ui8", spelling: "-1", expected: Preserved },
		{ kind: "i4", spelling: "2 3", expected: Preserved },
		{ kind: "i4", spelling: "&#160;3", expected: Preserved },
		{ kind: "i4", spelling: "0x10", expected: Preserved },
		{ kind: "i4", spelling: "1e2", expected: Preserved },
		{ kind: "i4", spelling: "1_0", expected: Preserved },
		{ kind: "i4", spelling: "2.0", expected: Preserved },
		{ kind: "i4", spelling: "+", expected: Preserved },
	]
	check_custom_integers(cases)?
}
