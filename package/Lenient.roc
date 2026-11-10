## Attribute values that real producers write and the schema does not allow,
## and the values the package holds and writes in their place.
##
## A Google Docs export writes table widths as `w:w="10470.0"` and page
## margins as `w:left="863.9999999999999"` where the schema wants whole
## numbers, and leaves out a page margin's required `w:gutter`. Reading
## repairs each such attribute and says so, so that what a document holds,
## and therefore what it writes, is schema-valid.
##
## The attributes repaired are named in a table grounded in the ECMA-376
## Transitional schema: an attribute is rounded only where every element of
## its name types it as a whole number (`ST_TwipsMeasure`,
## `ST_SignedTwipsMeasure`, `ST_MeasurementOrPercent`, `ST_DecimalNumber`),
## and only a plain decimal number with a fraction is rounded, so a
## percentage (`50%`) or a universal measure (`1.5in`), which those types
## also allow, is kept as written.
import XmlTree

Lenient :: [].{

	## A repair reading made to an element's attributes: a number the schema
	## wants whole, written with a fraction, rounded to the nearest whole
	## number, halves away from zero, with `value` as the document wrote it;
	## or a required attribute the element left out, supplied with `value`.
	## `element` and `attribute` are the WordprocessingML local names.
	Repair : [
		Rounded({ element : Str, attribute : Str, value : Str }),
		Defaulted({ element : Str, attribute : Str, value : Str }),
	]

	## An element's attributes as the package holds them, with the repairs
	## made, in attribute order and then supplied attributes in table order.
	## The page, paragraph and table measures of [Lenient.whole_attributes]
	## are rounded, and a page margin without a gutter gets `w:gutter="0"`,
	## the gutter Word and LibreOffice assume. Any other element's attributes
	## are returned as they are.
	repair : XmlTree.Name, List(XmlTree.Attribute) -> { attributes : List(XmlTree.Attribute), repairs : List(Repair) }
	repair = |name, attributes| {
		# Most elements need nothing, and finding that allocates nothing: the
		# table, whose lists are built when asked for, and the namespace,
		# whose comparison builds a value, are looked at last.
		required = supplied(name.local)
		if !(required.len() > 0 or attributes.any(|attribute| attribute.value.contains("."))) {
			return { attributes, repairs: [] }
		}
		whole = Lenient.whole_attributes(name.local)
		if (required.is_empty() and whole.is_empty()) or name.namespace != Uri(wordprocessingml) {
			return { attributes, repairs: [] }
		}
		missing = required.keep_if(|entry| !attributes.any(|attribute| is_w(attribute.name, entry.attribute)))
		if missing.is_empty() and !attributes.any(|attribute| rounded(whole, attribute).is_ok()) {
			return { attributes, repairs: [] }
		}
		var $attributes = List.with_capacity(attributes.len() + missing.len())
		var $repairs = List.with_capacity(missing.len() + 1)
		for attribute in attributes {
			match rounded(whole, attribute) {
				Ok(value) => {
					$attributes = List.append($attributes, { name: attribute.name, value })
					$repairs = List.append($repairs, Rounded({ element: name.local, attribute: attribute.name.local, value: attribute.value }))
				}

				Err(_) => {
					$attributes = List.append($attributes, attribute)
				}
			}
		}
		for entry in missing {
			$attributes = List.append($attributes, { name: { namespace: Uri(wordprocessingml), local: entry.attribute, prefix: Prefix("w") }, value: entry.value })
			$repairs = List.append($repairs, Defaulted({ element: name.local, attribute: entry.attribute, value: entry.value }))
		}
		{ attributes: $attributes, repairs: $repairs }
	}

	## The attributes of a WordprocessingML element, by local name, that the
	## schema types as whole numbers and that reading rounds: page size and
	## margins (`CT_PageSz`, `CT_PageMar`), paragraph indentation and spacing
	## (`CT_Ind`, `CT_Spacing`), a tab stop's position (`CT_TabStop`), a run's
	## character spacing (`CT_SignedTwipsMeasure`), every table, cell and
	## margin width (`CT_TblWidth`), a grid column's width (`CT_TblGridCol`)
	## and a row's height (`CT_Height`). Other whole-number attributes, such
	## as border widths, font sizes and identifiers, are not repaired yet.
	whole_attributes : Str -> List(Str)
	whole_attributes = |local|
		match local {
			"pgSz" => ["w", "h"]
			"pgMar" => ["top", "right", "bottom", "left", "header", "footer", "gutter"]
			"ind" => ["start", "end", "left", "right", "hanging", "firstLine", "startChars", "endChars", "leftChars", "rightChars", "hangingChars", "firstLineChars"]
			"spacing" => ["before", "after", "line", "beforeLines", "afterLines", "val"]
			"tab" => ["pos"]
			"tblW" | "tcW" | "tblInd" | "tblCellSpacing" | "wBefore" | "wAfter" | "top" | "left" | "bottom" | "right" | "start" | "end" | "gridCol" => ["w"]
			"trHeight" => ["val"]
			_ => []
		}

	## A decimal number, an optional sign, digits and an optional fraction,
	## multiplied by `factor` and rounded to the nearest whole number, halves
	## away from zero; `exact` says nothing was rounded away. At most fifteen
	## digits are read, so the value cannot overflow: a number with more
	## before its point is not one, and digits past the fifteenth that follow
	## the point only make the value inexact; with a factor of one the value
	## is rounded as the full fraction would be (`863.9999999999999` is 864).
	decimal : Str, U64 -> Try({ value : I64, exact : Bool }, [NotNumber])
	decimal = |text, factor| {
		bytes = text.to_utf8()
		negative = bytes.first() == Ok('-')
		start = if (negative or bytes.first() == Ok('+')) 1 else 0
		var $mantissa = 0.U64
		var $scale = 1.U64
		var $digits = 0.U64
		var $point = Bool.False
		var $dropped = Bool.False
		var $index = start
		while $index < bytes.len() {
			byte = bytes.get($index) ?? 0
			if byte == '.' and !$point {
				$point = Bool.True
			} else if byte >= '0' and byte <= '9' and $digits < 15 {
				$mantissa = $mantissa * 10 + (byte - '0').to_u64()
				$digits = $digits + 1
				if $point {
					$scale = $scale * 10
				}
			} else if byte >= '0' and byte <= '9' and $point {
				$dropped = $dropped or byte != '0'
			} else {
				return Err(NotNumber)
			}
			$index = $index + 1
		}
		if $digits == 0 or factor > 1_000 {
			return Err(NotNumber)
		}
		scaled = $mantissa * factor
		magnitude = scaled // $scale + (if (2 * (scaled % $scale) >= $scale) 1 else 0)
		value = magnitude.to_i64_wrap()
		Ok({ value: if (negative) -value else value, exact: scaled % $scale == 0 and !$dropped })
	}
}

wordprocessingml : Str
wordprocessingml = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

# The required attributes of a WordprocessingML element, by local name, that
# producers leave out, with the value reading supplies.
supplied : Str -> List({ attribute : Str, value : Str })
supplied = |local|
	match local {
		"pgMar" => [{ attribute: "gutter", value: "0" }]
		_ => []
	}

is_w : XmlTree.Name, Str -> Bool
is_w = |name, local| name.namespace == Uri(wordprocessingml) and name.local == local

# The whole number an attribute of `whole` written with a fraction rounds to.
rounded : List(Str), XmlTree.Attribute -> Try(Str, [Kept])
rounded = |whole, attribute|
	if attribute.name.namespace == Uri(wordprocessingml) and whole.contains(attribute.name.local) and attribute.value.contains(".") {
		match Lenient.decimal(attribute.value, 1) {
			Ok(read) => Ok(read.value.to_str())
			Err(NotNumber) => Err(Kept)
		}
	} else {
		Err(Kept)
	}

## Numbers are read leniently and rounded halves away from zero, digits past
## the fifteenth after the point make a value inexact, and what is not a
## number, or has more digits before its point than are read, is not one.
expect {
	Lenient.decimal("12", 1) == Ok({ value: 12, exact: Bool.True })
		and Lenient.decimal("-2.5", 1) == Ok({ value: -3, exact: Bool.False })
		and Lenient.decimal("+.25", 50) == Ok({ value: 13, exact: Bool.False })
		and Lenient.decimal("1.5", 50) == Ok({ value: 75, exact: Bool.True })
		and Lenient.decimal("863.9999999999999", 1) == Ok({ value: 864, exact: Bool.False })
		and Lenient.decimal("0.4999999999999999", 1) == Ok({ value: 0, exact: Bool.False })
		and Lenient.decimal("10470.00000000000000", 1) == Ok({ value: 10470, exact: Bool.True })
		and Lenient.decimal("1.0000000000000000", 1) == Ok({ value: 1, exact: Bool.True })
		and Lenient.decimal("", 1) == Err(NotNumber)
		and Lenient.decimal("1.2.3", 1) == Err(NotNumber)
		and Lenient.decimal("1e3", 1) == Err(NotNumber)
		and Lenient.decimal("1234567890123456", 1) == Err(NotNumber)
}

## Measures written with a fraction are rounded, a missing gutter is
## supplied, and a percentage, a universal measure, an attribute outside the
## table and an element outside WordprocessingML are kept as written.
expect {
	w = |local| { namespace: Uri(wordprocessingml), local, prefix: Prefix("w") }
	margins = [{ name: w("top"), value: "576" }, { name: w("left"), value: "863.9999999999999" }, { name: w("right"), value: "-0.5" }]
	repaired = Lenient.repair(w("pgMar"), margins)
	kept_width = [{ name: w("w"), value: "33.5%" }, { name: w("type"), value: "pct" }]
	measure = [{ name: w("w"), value: "1.5in" }]
	foreign = [{ name: { namespace: Uri("urn:example:x"), local: "w", prefix: Prefix("x") }, value: "1.5" }]
	repaired.attributes == [{ name: w("top"), value: "576" }, { name: w("left"), value: "864" }, { name: w("right"), value: "-1" }, { name: w("gutter"), value: "0" }]
		and repaired.repairs == [
			Rounded({ element: "pgMar", attribute: "left", value: "863.9999999999999" }),
			Rounded({ element: "pgMar", attribute: "right", value: "-0.5" }),
			Defaulted({ element: "pgMar", attribute: "gutter", value: "0" }),
		]
		and Lenient.repair(w("tblW"), kept_width) == { attributes: kept_width, repairs: [] }
		and Lenient.repair(w("tcW"), measure) == { attributes: measure, repairs: [] }
		and Lenient.repair(w("tcW"), foreign) == { attributes: foreign, repairs: [] }
		and Lenient.repair(w("jc"), [{ name: w("val"), value: "1.5" }]).repairs == []
		and Lenient.repair({ namespace: Uri("urn:example:x"), local: "pgMar", prefix: Prefix("x") }, []).repairs == []
}
