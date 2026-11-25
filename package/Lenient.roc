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
		if missing.is_empty() and !attributes.any(|attribute| rounded(name.local, whole, attribute).is_ok()) {
			return { attributes, repairs: [] }
		}
		var $attributes = List.with_capacity(attributes.len() + missing.len())
		var $repairs = List.with_capacity(missing.len() + 1)
		for attribute in attributes {
			match rounded(name.local, whole, attribute) {
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
	## away from zero. The `exact` flag says the scaled value was already whole.
	## Up to fifteen digits before the point and factors up to 1000 are accepted,
	## bounding the result. All fractional digits contribute to rounding.
	decimal : Str, U64 -> Try({ value : I64, exact : Bool }, [NotNumber])
	decimal = |text, factor| signed_decimal(text, factor, Narrow)

	## A signed measure rounded as [Lenient.decimal], covering the full I64
	## model range. A larger magnitude is left for the caller to preserve.
	measure : Str, U64 -> Try({ value : I64, exact : Bool }, [NotNumber])
	measure = |text, factor| signed_decimal(text, factor, Signed)

	## An unsigned twip measure rounded as [Lenient.decimal], covering the
	## full U64 model range. A negative rounded value cannot be held.
	unsigned_measure : Str -> Try(U64, [NotNumber])
	unsigned_measure = |text| {
		read = magnitude(text, 1, Unsigned)?
		if read.negative and read.amount != 0 {
			Err(NotNumber)
		} else {
			Ok(read.amount)
		}
	}
}

MeasureRange : [Narrow, Signed, Unsigned]

signed_decimal : Str, U64, MeasureRange -> Try({ value : I64, exact : Bool }, [NotNumber])
signed_decimal = |text, factor, range| {
	read = magnitude(text, factor, range)?
	# Apply the sign before reinterpreting the bits so I64.lowest does not
	# need to be negated as a signed integer.
	bits = if (read.negative) (0.U64).minus_wrap(read.amount) else read.amount
	Ok({ value: bits.to_i64_wrap(), exact: read.exact })
}

magnitude : Str, U64, MeasureRange -> Try({ amount : U64, negative : Bool, exact : Bool }, [NotNumber])
magnitude = |text, factor, range| {
	bytes = text.to_utf8()
	first = bytes.first() ?? 0
	negative = first == '-'
	start = if (negative or first == '+') 1 else 0
	if factor > 1_000 or start == bytes.len() {
		return Err(NotNumber)
	}
	var $whole = 0.U64
	var $index = start
	var $point = Bool.False
	while $index < bytes.len() and !$point {
		byte = bytes.get($index) ?? 0
		if byte == '.' {
			$point = Bool.True
		} else if byte >= '0' and byte <= '9' {
			digit = (byte - '0').to_u64()
			if $index - start >= 15 and (range == Narrow or $whole > (U64.highest - digit) // 10) {
				return Err(NotNumber)
			}
			$whole = $whole * 10 + digit
		} else {
			return Err(NotNumber)
		}
		$index = $index + 1
	}
	if $point and bytes.len() == start + 1 {
		return Err(NotNumber)
	}
	fraction = match bytes.len() - $index {
		0 => { rounded: 0, exact: Bool.True }
		1 => {
			digit = fraction_digit(bytes, $index)?
			scaled = digit * factor.to_u32_wrap()
			{ rounded: ((scaled + 5) // 10).to_u64(), exact: scaled % 10 == 0 }
		}
		2 => scale_prefix(bytes, $index, factor.to_u32_wrap())?
		_ =>
			if factor == 1 or factor == 50 {
				scale_prefix(bytes, $index, factor.to_u32_wrap())?
			} else {
				scale_fraction(bytes, $index, factor.to_u32_wrap())?
			}
	}
	# At most fifteen whole digits and a factor of at most 1000 fit either
	# range even after rounding. Guard scaling only for wider numbers.
	if range != Narrow and $whole >= 1_000_000_000_000_000 and factor != 0 {
		maximum = if range == Unsigned {
			U64.highest
		} else {
			9_223_372_036_854_775_807 + (if (negative) 1 else 0)
		}
		if $whole > (maximum - fraction.rounded) // factor {
			return Err(NotNumber)
		}
	}
	Ok({ amount: $whole * factor + fraction.rounded, negative, exact: fraction.exact })
}

# A fraction of up to two digits is exact in hundredths. For twips and
# percent, both the integral and halfway boundaries are also multiples of
# .01. Read those digits, then validate the rest in document order, where
# a nonzero digit only changes exactness.
scale_prefix : List(U8), U64, U32 -> Try({ rounded : U64, exact : Bool }, [NotNumber])
scale_prefix = |bytes, start, factor| {
	first = fraction_digit(bytes, start)?
	second = fraction_digit(bytes, start + 1)?
	scaled = (first * 10 + second) * factor
	var $exact = scaled % 100 == 0
	var $index = start + 2
	while $index < bytes.len() {
		digit = fraction_digit(bytes, $index)?
		$exact = $exact and digit == 0
		$index = $index + 1
	}
	Ok({ rounded: ((scaled + 50) // 100).to_u64(), exact: $exact })
}

fraction_digit : List(U8), U64 -> Try(U32, [NotNumber])
fraction_digit = |bytes, index| {
	byte = bytes.get(index) ?? '0'
	if byte < '0' or byte > '9' {
		Err(NotNumber)
	} else {
		Ok((byte - '0').to_u32())
	}
}

# Validate from the point forwards, then multiply from right to left,
# handling groups of four decimal digits until only the leading digits
# remain. Each group adds a carry of at most 999 to at most 9999 * 1000.
scale_fraction : List(U8), U64, U32 -> Try({ rounded : U64, exact : Bool }, [NotNumber])
scale_fraction = |bytes, start, factor| {
	var $front = start
	while $front < bytes.len() {
		_ = fraction_digit(bytes, $front)?
		$front = $front + 1
	}
	var $index = bytes.len()
	var $carry = 0.U32
	var $exact = Bool.True
	while $index - start > 4 {
		$index = $index - 4
		group = decoded_digit(bytes, $index) * 1000 + decoded_digit(bytes, $index + 1) * 100 + decoded_digit(bytes, $index + 2) * 10 + decoded_digit(bytes, $index + 3)
		product = group * factor + $carry
		$carry = product // 10_000
		$exact = $exact and product % 10_000 == 0
	}
	var $tenths = 0.U32
	while $index > start {
		$index = $index - 1
		product = decoded_digit(bytes, $index) * factor + $carry
		$carry = product // 10
		$tenths = product % 10
		$exact = $exact and $tenths == 0
	}
	Ok({ rounded: ($carry + (if ($tenths >= 5) 1 else 0)).to_u64(), exact: $exact })
}

decoded_digit : List(U8), U64 -> U32
decoded_digit = |bytes, index| (bytes.get(index) ?? '0').minus_wrap('0').to_u32()

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
rounded : Str, List(Str), XmlTree.Attribute -> Try(Str, [Kept])
rounded = |element, whole, attribute|
	if attribute.name.namespace == Uri(wordprocessingml) and whole.contains(attribute.name.local) and attribute.value.contains(".") {
		if element == "gridCol" {
			value = Lenient.unsigned_measure(attribute.value) ? |_| Kept
			Ok(value.to_str())
		} else {
			parse = if (element == "tblW" or element == "tcW") Lenient.measure else Lenient.decimal
			read = parse(attribute.value, 1) ? |_| Kept
			Ok(read.value.to_str())
		}
	} else {
		Err(Kept)
	}

## Numbers are read leniently and rounded halves away from zero. Long
## fractions retain their rounding and exactness, and invalid spellings
## or whole parts longer than fifteen digits are rejected.
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
