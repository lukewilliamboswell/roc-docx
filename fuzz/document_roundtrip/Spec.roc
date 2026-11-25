import docx.Docx
import docx.Opc

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
