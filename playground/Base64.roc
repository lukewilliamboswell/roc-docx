## Base64 (RFC 4648, with padding). The page's file input hands a file over
## as base64 text, because a handler receives its payload as a `Str`, and a
## download link carries the written document as a `data:` URL.
Base64 := [].{

	encode : List(U8) -> Str
	encode = |bytes| {
		var $out = List.with_capacity((bytes.len() + 2) // 3 * 4)
		var $at = 0.U64
		n = bytes.len()
		while $at + 2 < n {
			a = Base64.byte(bytes, $at)
			b = Base64.byte(bytes, $at + 1)
			c = Base64.byte(bytes, $at + 2)
			$out = List.append($out, Base64.digit(a // 4))
			$out = List.append($out, Base64.digit((a % 4) * 16 + b // 16))
			$out = List.append($out, Base64.digit((b % 16) * 4 + c // 64))
			$out = List.append($out, Base64.digit(c % 64))
			$at = $at + 3
		}
		if $at + 1 == n {
			a = Base64.byte(bytes, $at)
			$out = List.append($out, Base64.digit(a // 4))
			$out = List.append($out, Base64.digit((a % 4) * 16))
			$out = List.append($out, '=')
			$out = List.append($out, '=')
		} else if $at + 2 == n {
			a = Base64.byte(bytes, $at)
			b = Base64.byte(bytes, $at + 1)
			$out = List.append($out, Base64.digit(a // 4))
			$out = List.append($out, Base64.digit((a % 4) * 16 + b // 16))
			$out = List.append($out, Base64.digit((b % 16) * 4))
			$out = List.append($out, '=')
		}
		Str.from_utf8($out) ?? ""
	}

	decode : Str -> Try(List(U8), [InvalidBase64])
	decode = |text| {
		chars = text.to_utf8().drop_if(|c| c == '=')
		var $out = List.with_capacity(chars.len() * 3 // 4)
		var $acc = 0.U32
		var $bits = 0.U32
		for c in chars {
			v = Base64.value(c)?
			$acc = ($acc * 64 + v) % 16777216
			$bits = $bits + 6
			if $bits >= 8 {
				$bits = $bits - 8
				$out = List.append($out, ($acc // Base64.power($bits) % 256).to_u8_wrap())
			}
		}
		Ok($out)
	}

	byte : List(U8), U64 -> U32
	byte = |bytes, at| (bytes.get(at) ?? 0).to_u32()

	digit : U32 -> U8
	digit = |v|
		if v < 26 {
			'A' + v.to_u8_wrap()
		} else if v < 52 {
			'a' + (v - 26).to_u8_wrap()
		} else if v < 62 {
			'0' + (v - 52).to_u8_wrap()
		} else if v == 62 {
			'+'
		} else {
			'/'
		}

	value : U8 -> Try(U32, [InvalidBase64])
	value = |c|
		if c >= 'A' and c <= 'Z' {
			Ok((c - 'A').to_u32())
		} else if c >= 'a' and c <= 'z' {
			Ok((c - 'a').to_u32() + 26)
		} else if c >= '0' and c <= '9' {
			Ok((c - '0').to_u32() + 52)
		} else if c == '+' {
			Ok(62)
		} else if c == '/' {
			Ok(63)
		} else {
			Err(InvalidBase64)
		}

	power : U32 -> U32
	power = |bits| if (bits == 0) 1 else 2 * Base64.power(bits - 1)
}

## Encoding pads to whole groups of four.
expect Base64.encode([77, 97]) == "TWE="

## Decoding inverts encoding.
expect Base64.decode(Base64.encode([0, 1, 2, 253, 254, 255, 7])) == Ok([0, 1, 2, 253, 254, 255, 7])
