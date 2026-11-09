## WordprocessingML trees read as the typed model.
##
## The reader is lenient and loses nothing: an element it models becomes a
## typed value, and every other element is kept, in its place, as the
## [XmlTree.Node] it was read as. Elements whose content is itself blocks or
## paragraph content, such as a table or a hyperlink, are kept without their
## children and their content is read, so text inside them is still text.
## Whitespace-only text between elements is not content and is not kept.
import Document
import Mce
import XmlTree

WmlRead :: [].{

	## The body of a main document part, block by block in reading order, from
	## the part's tree as [Docx.parse] read it. The tree is interpreted by
	## [Mce.process] first, so extensions are skipped and each alternative is
	## read as the branch the package understands. A tree whose root is not a
	## WordprocessingML document, or that has no body, has no blocks.
	##
	## A paragraph's first `w:pPr` holds its properties and a run's first
	## `w:rPr` its properties. In a run, `w:t` is text, `w:tab` a tab, `w:br`
	## a break (`w:cr` a line break), `w:sym` a symbol, `w:softHyphen` and
	## `w:noBreakHyphen` hyphens. An element whose attributes are not ones
	## the model can hold, such as a break of an unknown type or a symbol
	## without a character code, is kept as it was read.
	##
	## A table's first `w:tblPr` holds its properties and its first
	## `w:tblGrid` its grid, a row's first `w:trPr` and a cell's first
	## `w:tcPr` theirs. Each property the model holds is read from the first
	## element that gives it in a form the model can hold; every other
	## property element stays in `preserved`, in order.
	body : XmlTree.Node -> List(Document.Block)
	body = |tree| WmlRead.read_body(tree).blocks

	## The body as [WmlRead.body] reads it, with what reading it noticed, in
	## document order.
	read_body : XmlTree.Node -> { blocks : List(Document.Block), diagnostics : List(WmlRead.Diagnostic) }
	read_body = |tree|
		match Mce.process(tree).interpreted {
			Element(root) if is_w(root.name, "document") =>
				match root.children.find_first(|child| is_element(child, "body")) {
					Ok(Element(element)) => blocks(element.children, [])
					_ => { blocks: [], diagnostics: [] }
				}

			_ => { blocks: [], diagnostics: [] }
		}

	## Something the reader accepted that the schema does not allow: a number
	## the schema wants whole written with a fraction, such as the width
	## `w:w="10470.0"` that Google Docs exports write, or a percentage finer
	## than the fiftieths of a per cent the model holds, read rounded to the
	## nearest, halves away from zero. `element` and `attribute` are the local
	## names of the WordprocessingML element and attribute, and `value` is the
	## value as the document wrote it.
	Diagnostic : [Rounded({ element : Str, attribute : Str, value : Str })]
}

# Elements whose content is blocks, read as containers in a block's place.
block_containers : List(Str)
block_containers = ["sdt", "sdtContent", "customXml"]

# Elements whose content is paragraph content, read as containers in an
# inline's place.
inline_containers : List(Str)
inline_containers = ["hyperlink", "ins", "del", "moveFrom", "moveTo", "fldSimple", "sdt", "sdtContent", "smartTag", "customXml", "dir", "bdo"]

# Block reading carries what it has noticed so far and gives it back with
# what it read.
blocks : List(XmlTree.Node), List(WmlRead.Diagnostic) -> { blocks : List(Document.Block), diagnostics : List(WmlRead.Diagnostic) }
blocks = |nodes, diagnostics| {
	var $out = List.with_capacity(nodes.len())
	var $diagnostics = diagnostics
	for node in nodes {
		if is_content(node) {
			read = block(node, $diagnostics)
			$out = List.append($out, read.block)
			$diagnostics = read.diagnostics
		}
	}
	{ blocks: $out, diagnostics: $diagnostics }
}

block : XmlTree.Node, List(WmlRead.Diagnostic) -> { block : Document.Block, diagnostics : List(WmlRead.Diagnostic) }
block = |node, diagnostics|
	match node {
		Element(element) if is_w(element.name, "p") => { block: Paragraph(paragraph(element.children)), diagnostics: diagnostics }
		Element(element) if is_w(element.name, "tbl") => {
			read = table(element.children, diagnostics)
			{ block: Table(read.table), diagnostics: read.diagnostics }
		}

		Element(element) if is_w_in(element.name, block_containers) => {
			read = blocks(element.children, diagnostics)
			{ block: Container({ element: without_children(element), content: read.blocks }), diagnostics: read.diagnostics }
		}

		_ => { block: Preserved(node), diagnostics: diagnostics }
	}

table : List(XmlTree.Node), List(WmlRead.Diagnostic) -> { table : Document.Table, diagnostics : List(WmlRead.Diagnostic) }
table = |children, diagnostics| {
	var $properties = Err(Missing)
	var $grid = Err(Missing)
	var $content = List.with_capacity(children.len())
	var $diagnostics = diagnostics
	for child in children {
		match ($properties, $grid, child) {
			(Err(Missing), _, Element(element)) if is_w(element.name, "tblPr") => {
				read = table_properties(element.children, $diagnostics)
				$properties = Ok(read.properties)
				$diagnostics = read.diagnostics
			}

			(_, Err(Missing), Element(element)) if is_w(element.name, "tblGrid") => {
				read = grid(element.children, $diagnostics)
				$grid = Ok(read.grid)
				$diagnostics = read.diagnostics
			}

			_ => {
				if is_content(child) {
					read = table_content(child, $diagnostics)
					$content = List.append($content, read.content)
					$diagnostics = read.diagnostics
				}
			}
		}
	}
	properties = $properties ?? { style: Unset, width: Unset, borders: [], shading: Unset, preserved: [] }
	{ table: { properties, grid: $grid ?? [], content: $content }, diagnostics: $diagnostics }
}

table_content : XmlTree.Node, List(WmlRead.Diagnostic) -> { content : Document.TableContent, diagnostics : List(WmlRead.Diagnostic) }
table_content = |node, diagnostics|
	match node {
		Element(element) if is_w(element.name, "tr") => {
			read = row(element.children, diagnostics)
			{ content: Row(read.row), diagnostics: read.diagnostics }
		}

		Element(element) if is_w_in(element.name, block_containers) => {
			var $content = List.with_capacity(element.children.len())
			var $diagnostics = diagnostics
			for child in element.children {
				if is_content(child) {
					read = table_content(child, $diagnostics)
					$content = List.append($content, read.content)
					$diagnostics = read.diagnostics
				}
			}
			{ content: Container({ element: without_children(element), content: $content }), diagnostics: $diagnostics }
		}

		_ => { content: Preserved(node), diagnostics: diagnostics }
	}

row : List(XmlTree.Node), List(WmlRead.Diagnostic) -> { row : Document.Row, diagnostics : List(WmlRead.Diagnostic) }
row = |children, diagnostics| {
	var $properties = Err(Missing)
	var $content = List.with_capacity(children.len())
	var $diagnostics = diagnostics
	for child in children {
		match ($properties, child) {
			(Err(Missing), Element(element)) if is_w(element.name, "trPr") => {
				read = row_properties(element.children, $diagnostics)
				$properties = Ok(read.properties)
				$diagnostics = read.diagnostics
			}

			_ => {
				if is_content(child) {
					read = row_content(child, $diagnostics)
					$content = List.append($content, read.content)
					$diagnostics = read.diagnostics
				}
			}
		}
	}
	properties = $properties ?? { header: Unset, grid_before: Unset, grid_after: Unset, preserved: [] }
	{ row: { properties, content: $content }, diagnostics: $diagnostics }
}

row_content : XmlTree.Node, List(WmlRead.Diagnostic) -> { content : Document.RowContent, diagnostics : List(WmlRead.Diagnostic) }
row_content = |node, diagnostics|
	match node {
		Element(element) if is_w(element.name, "tc") => {
			read = cell(element.children, diagnostics)
			{ content: Cell(read.cell), diagnostics: read.diagnostics }
		}

		Element(element) if is_w_in(element.name, block_containers) => {
			var $content = List.with_capacity(element.children.len())
			var $diagnostics = diagnostics
			for child in element.children {
				if is_content(child) {
					read = row_content(child, $diagnostics)
					$content = List.append($content, read.content)
					$diagnostics = read.diagnostics
				}
			}
			{ content: Container({ element: without_children(element), content: $content }), diagnostics: $diagnostics }
		}

		_ => { content: Preserved(node), diagnostics: diagnostics }
	}

cell : List(XmlTree.Node), List(WmlRead.Diagnostic) -> { cell : Document.Cell, diagnostics : List(WmlRead.Diagnostic) }
cell = |children, diagnostics| {
	var $properties = Err(Missing)
	var $content = List.with_capacity(children.len())
	var $diagnostics = diagnostics
	for child in children {
		match ($properties, child) {
			(Err(Missing), Element(element)) if is_w(element.name, "tcPr") => {
				read = cell_properties(element.children, $diagnostics)
				$properties = Ok(read.properties)
				$diagnostics = read.diagnostics
			}

			_ => {
				if is_content(child) {
					read = block(child, $diagnostics)
					$content = List.append($content, read.block)
					$diagnostics = read.diagnostics
				}
			}
		}
	}
	properties = $properties ?? { width: Unset, span: Unset, merge: Unset, borders: [], shading: Unset, alignment: Unset, preserved: [] }
	{ cell: { properties, content: $content }, diagnostics: $diagnostics }
}

# A grid column is a `w:gridCol` whose only attribute is its width.
grid : List(XmlTree.Node), List(WmlRead.Diagnostic) -> { grid : List(Document.GridColumn), diagnostics : List(WmlRead.Diagnostic) }
grid = |children, diagnostics| {
	var $columns = List.with_capacity(children.len())
	var $diagnostics = diagnostics
	for child in kept(children) {
		read = match child {
			Element(element) if is_w(element.name, "gridCol") and holds(element, ["w"]) => unsigned(element, "w")
			_ => Err(CannotHold)
		}
		match read {
			Ok({ value, noticed }) => {
				$columns = List.append($columns, Column(value))
				$diagnostics = List.concat($diagnostics, noticed)
			}

			Err(CannotHold) => {
				$columns = List.append($columns, Preserved(child))
			}
		}
	}
	{ grid: $columns, diagnostics: $diagnostics }
}

table_properties : List(XmlTree.Node), List(WmlRead.Diagnostic) -> { properties : Document.TableProperties, diagnostics : List(WmlRead.Diagnostic) }
table_properties = |children, diagnostics| {
	var $properties = { style: Unset, width: Unset, borders: [], shading: Unset, preserved: List.with_capacity(children.len()) }
	var $diagnostics = diagnostics
	for child in kept(children) {
		match child {
			Element(element) if is_w(element.name, "tblStyle") and $properties.style == Unset and holds(element, ["val"]) =>
				match value_of(element, "val") {
					Ok(id) => {
						$properties = { ..$properties, style: Style(id) }
					}

					Err(NotFound) => {
						$properties = { ..$properties, preserved: List.append($properties.preserved, child) }
					}
				}

			Element(element) if is_w(element.name, "tblW") and $properties.width == Unset =>
				match width(element) {
					Ok({ value, noticed }) => {
						$properties = { ..$properties, width: value }
						$diagnostics = List.concat($diagnostics, noticed)
					}

					Err(CannotHold) => {
						$properties = { ..$properties, preserved: List.append($properties.preserved, child) }
					}
				}

			Element(element) if is_w(element.name, "tblBorders") and $properties.borders.is_empty() =>
				match borders(element, table_edges) {
					Ok({ value, noticed }) => {
						$properties = { ..$properties, borders: value }
						$diagnostics = List.concat($diagnostics, noticed)
					}

					Err(CannotHold) => {
						$properties = { ..$properties, preserved: List.append($properties.preserved, child) }
					}
				}

			Element(element) if is_w(element.name, "shd") and $properties.shading == Unset =>
				match shading(element) {
					Ok(value) => {
						$properties = { ..$properties, shading: value }
					}

					Err(CannotHold) => {
						$properties = { ..$properties, preserved: List.append($properties.preserved, child) }
					}
				}

			_ => {
				$properties = { ..$properties, preserved: List.append($properties.preserved, child) }
			}
		}
	}
	{ properties: $properties, diagnostics: $diagnostics }
}

row_properties : List(XmlTree.Node), List(WmlRead.Diagnostic) -> { properties : Document.RowProperties, diagnostics : List(WmlRead.Diagnostic) }
row_properties = |children, diagnostics| {
	var $properties = { header: Unset, grid_before: Unset, grid_after: Unset, preserved: List.with_capacity(children.len()) }
	var $diagnostics = diagnostics
	for child in kept(children) {
		match child {
			Element(element) if is_w(element.name, "tblHeader") and $properties.header == Unset =>
				match on_off(element) {
					Ok(value) => {
						$properties = { ..$properties, header: value }
					}

					Err(CannotHold) => {
						$properties = { ..$properties, preserved: List.append($properties.preserved, child) }
					}
				}

			Element(element) if is_w(element.name, "gridBefore") and $properties.grid_before == Unset =>
				match columns(element) {
					Ok({ value, noticed }) => {
						$properties = { ..$properties, grid_before: value }
						$diagnostics = List.concat($diagnostics, noticed)
					}

					Err(CannotHold) => {
						$properties = { ..$properties, preserved: List.append($properties.preserved, child) }
					}
				}

			Element(element) if is_w(element.name, "gridAfter") and $properties.grid_after == Unset =>
				match columns(element) {
					Ok({ value, noticed }) => {
						$properties = { ..$properties, grid_after: value }
						$diagnostics = List.concat($diagnostics, noticed)
					}

					Err(CannotHold) => {
						$properties = { ..$properties, preserved: List.append($properties.preserved, child) }
					}
				}

			_ => {
				$properties = { ..$properties, preserved: List.append($properties.preserved, child) }
			}
		}
	}
	{ properties: $properties, diagnostics: $diagnostics }
}

cell_properties : List(XmlTree.Node), List(WmlRead.Diagnostic) -> { properties : Document.CellProperties, diagnostics : List(WmlRead.Diagnostic) }
cell_properties = |children, diagnostics| {
	var $properties = { width: Unset, span: Unset, merge: Unset, borders: [], shading: Unset, alignment: Unset, preserved: List.with_capacity(children.len()) }
	var $diagnostics = diagnostics
	for child in kept(children) {
		match child {
			Element(element) if is_w(element.name, "tcW") and $properties.width == Unset =>
				match width(element) {
					Ok({ value, noticed }) => {
						$properties = { ..$properties, width: value }
						$diagnostics = List.concat($diagnostics, noticed)
					}

					Err(CannotHold) => {
						$properties = { ..$properties, preserved: List.append($properties.preserved, child) }
					}
				}

			Element(element) if is_w(element.name, "gridSpan") and $properties.span == Unset =>
				match columns(element) {
					Ok({ value, noticed }) => {
						$properties = { ..$properties, span: value }
						$diagnostics = List.concat($diagnostics, noticed)
					}

					Err(CannotHold) => {
						$properties = { ..$properties, preserved: List.append($properties.preserved, child) }
					}
				}

			Element(element) if is_w(element.name, "vMerge") and $properties.merge == Unset =>
				match merge(element) {
					Ok(value) => {
						$properties = { ..$properties, merge: value }
					}

					Err(CannotHold) => {
						$properties = { ..$properties, preserved: List.append($properties.preserved, child) }
					}
				}

			Element(element) if is_w(element.name, "tcBorders") and $properties.borders.is_empty() =>
				match borders(element, cell_edges) {
					Ok({ value, noticed }) => {
						$properties = { ..$properties, borders: value }
						$diagnostics = List.concat($diagnostics, noticed)
					}

					Err(CannotHold) => {
						$properties = { ..$properties, preserved: List.append($properties.preserved, child) }
					}
				}

			Element(element) if is_w(element.name, "shd") and $properties.shading == Unset =>
				match shading(element) {
					Ok(value) => {
						$properties = { ..$properties, shading: value }
					}

					Err(CannotHold) => {
						$properties = { ..$properties, preserved: List.append($properties.preserved, child) }
					}
				}

			Element(element) if is_w(element.name, "vAlign") and $properties.alignment == Unset =>
				match alignment(element) {
					Ok(value) => {
						$properties = { ..$properties, alignment: value }
					}

					Err(CannotHold) => {
						$properties = { ..$properties, preserved: List.append($properties.preserved, child) }
					}
				}

			_ => {
				$properties = { ..$properties, preserved: List.append($properties.preserved, child) }
			}
		}
	}
	{ properties: $properties, diagnostics: $diagnostics }
}

# A value read from a property element, with what reading it noticed.
Read(a) : { value : a, noticed : List(WmlRead.Diagnostic) }

# A preferred width: `w:type` is `auto`, `nil`, `dxa` (twips, the default)
# or `pct`, fiftieths of a per cent or a percentage written with `%`. An
# automatic or zero width with a non-zero `w:w` cannot be held.
width : Element -> Try(Read(Document.Width), [CannotHold])
width = |element| {
	if !holds(element, ["w", "type"]) {
		return Err(CannotHold)
	}
	match value_of(element, "type") {
		Ok("auto") => if (zero_or_absent(element)) Ok({ value: Auto, noticed: [] }) else Err(CannotHold)
		Ok("nil") => if (zero_or_absent(element)) Ok({ value: Nil, noticed: [] }) else Err(CannotHold)
		Ok("pct") => {
			text = value_of(element, "w") ? |_| CannotHold
			if text.ends_with("%") {
				read = decimal(Str.drop_suffix(text, "%"), 50) ? |_| CannotHold
				Ok({ value: Fiftieths(read.value), noticed: if (read.exact) [] else [rounded(element, "w", text)] })
			} else {
				read = whole(element, "w")?
				Ok({ value: Fiftieths(read.value), noticed: read.noticed })
			}
		}

		Ok("dxa") | Err(NotFound) => {
			read = whole(element, "w")?
			Ok({ value: Twips(read.value), noticed: read.noticed })
		}

		Ok(_) => Err(CannotHold)
	}
}

zero_or_absent : Element -> Bool
zero_or_absent = |element|
	match value_of(element, "w") {
		Ok(text) => decimal(text, 1).map_ok(|read| read.value) == Ok(0)
		Err(NotFound) => Bool.True
	}

# A count of grid columns in `w:val`.
columns : Element -> Try(Read([Unset, Columns(U64)]), [CannotHold])
columns = |element| {
	if !holds(element, ["val"]) {
		return Err(CannotHold)
	}
	read = unsigned(element, "val")?
	Ok({ value: Columns(read.value), noticed: read.noticed })
}

# An on or off property: no `w:val` is on.
on_off : Element -> Try([Unset, On, Off], [CannotHold])
on_off = |element| {
	if !holds(element, ["val"]) {
		return Err(CannotHold)
	}
	match value_of(element, "val") {
		Err(NotFound) | Ok("true") | Ok("1") | Ok("on") => Ok(On)
		Ok("false") | Ok("0") | Ok("off") => Ok(Off)
		Ok(_) => Err(CannotHold)
	}
}

# A vertical merge: no `w:val` continues the merge above.
merge : Element -> Try([Unset, Restart, Continue], [CannotHold])
merge = |element| {
	if !holds(element, ["val"]) {
		return Err(CannotHold)
	}
	match value_of(element, "val") {
		Ok("restart") => Ok(Restart)
		Err(NotFound) | Ok("continue") => Ok(Continue)
		Ok(_) => Err(CannotHold)
	}
}

alignment : Element -> Try([Unset, Top, Center, Bottom, Both], [CannotHold])
alignment = |element| {
	if !holds(element, ["val"]) {
		return Err(CannotHold)
	}
	match value_of(element, "val") {
		Ok("top") => Ok(Top)
		Ok("center") => Ok(Center)
		Ok("bottom") => Ok(Bottom)
		Ok("both") => Ok(Both)
		_ => Err(CannotHold)
	}
}

table_edges : List(Str)
table_edges = ["top", "left", "start", "bottom", "right", "end", "insideH", "insideV"]

cell_edges : List(Str)
cell_edges = ["top", "left", "start", "bottom", "right", "end", "insideH", "insideV", "tl2br", "tr2bl"]

# Borders the model holds only whole: an element with no edges, an edge it
# does not allow, or an edge with attributes beyond its line, width, space
# and colour, such as a theme colour, is kept as it was read.
borders : Element, List(Str) -> Try(Read(List(Document.Border)), [CannotHold])
borders = |element, allowed| {
	if !element.attributes.is_empty() {
		return Err(CannotHold)
	}
	var $borders = List.with_capacity(element.children.len())
	var $noticed = List.with_capacity(0)
	for child in kept(element.children) {
		match child {
			Element(edge_element) if is_w_in(edge_element.name, allowed) and holds(edge_element, ["val", "sz", "space", "color"]) => {
				line = value_of(edge_element, "val") ? |_| CannotHold
				size = match value_of(edge_element, "sz") {
					Ok(_) => {
						read = unsigned(edge_element, "sz")?
						$noticed = List.concat($noticed, read.noticed)
						Eighths(read.value)
					}

					Err(NotFound) => Unset
				}
				space = match value_of(edge_element, "space") {
					Ok(_) => {
						read = unsigned(edge_element, "space")?
						$noticed = List.concat($noticed, read.noticed)
						Points(read.value)
					}

					Err(NotFound) => Unset
				}
				$borders = List.append($borders, { edge: edge(edge_element.name.local), line, size, space, color: color(edge_element, "color")? })
			}

			_ => {
				return Err(CannotHold)
			}
		}
	}
	if $borders.is_empty() {
		Err(CannotHold)
	} else {
		Ok({ value: $borders, noticed: $noticed })
	}
}

edge : Str -> [Top, Left, Start, Bottom, Right, End, InsideHorizontal, InsideVertical, DiagonalDown, DiagonalUp]
edge = |local|
	match local {
		"left" => Left
		"start" => Start
		"bottom" => Bottom
		"right" => Right
		"end" => End
		"insideH" => InsideHorizontal
		"insideV" => InsideVertical
		"tl2br" => DiagonalDown
		"tr2bl" => DiagonalUp
		_ => Top
	}

# A shading with its pattern and, if it gives them, its colour and fill;
# theme colours cannot be held.
shading : Element -> Try(Document.Shading, [CannotHold])
shading = |element| {
	if !holds(element, ["val", "color", "fill"]) {
		return Err(CannotHold)
	}
	pattern = value_of(element, "val") ? |_| CannotHold
	Ok(Shading({ pattern, color: color(element, "color")?, fill: color(element, "fill")? }))
}

# A colour attribute: `auto` or six hexadecimal digits.
color : Element, Str -> Try(Document.Color, [CannotHold])
color = |element, local|
	match value_of(element, local) {
		Err(NotFound) => Ok(Unset)
		Ok("auto") => Ok(Auto)
		Ok(text) =>
			if text.to_utf8().len() == 6 and text.to_utf8().all(|byte| hex_digit(byte).is_ok()) {
				Ok(Rgb(text))
			} else {
				Err(CannotHold)
			}
	}

# Whether every attribute of an element is a WordprocessingML one of these.
holds : Element, List(Str) -> Bool
holds = |element, locals| element.attributes.all(|attribute| is_w_in(attribute.name, locals))

# A whole number in an attribute, read leniently: a value written with a
# fraction is rounded, and noticed.
whole : Element, Str -> Try(Read(I64), [CannotHold])
whole = |element, local| {
	text = value_of(element, local) ? |_| CannotHold
	read = decimal(text, 1) ? |_| CannotHold
	Ok({ value: read.value, noticed: if (text.contains(".")) [rounded(element, local, text)] else [] })
}

unsigned : Element, Str -> Try(Read(U64), [CannotHold])
unsigned = |element, local| {
	read = whole(element, local)?
	if read.value < 0 {
		Err(CannotHold)
	} else {
		Ok({ value: read.value.to_u64_wrap(), noticed: read.noticed })
	}
}

rounded : Element, Str, Str -> WmlRead.Diagnostic
rounded = |element, local, text| Rounded({ element: element.name.local, attribute: local, value: text })

# A decimal number, an optional sign, digits and an optional fraction,
# multiplied by `factor` and rounded to the nearest whole number, halves away
# from zero; `exact` says nothing was rounded away. At most fifteen digits
# are read, so the value cannot overflow.
decimal : Str, U64 -> Try({ value : I64, exact : Bool }, [NotNumber])
decimal = |text, factor| {
	bytes = text.to_utf8()
	negative = bytes.first() == Ok('-')
	start = if (negative or bytes.first() == Ok('+')) 1 else 0
	var $mantissa = 0.U64
	var $scale = 1.U64
	var $digits = 0.U64
	var $point = Bool.False
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
	Ok({ value: if (negative) -value else value, exact: scaled % $scale == 0 })
}

paragraph : List(XmlTree.Node) -> Document.Paragraph
paragraph = |children| {
	var $properties = Err(Missing)
	var $content = List.with_capacity(children.len())
	for child in children {
		match ($properties, child) {
			(Err(Missing), Element(element)) if is_w(element.name, "pPr") => {
				$properties = Ok({ preserved: kept(element.children) })
			}

			_ => {
				if is_content(child) {
					$content = List.append($content, inline(child))
				}
			}
		}
	}
	{ properties: $properties ?? { preserved: [] }, content: $content }
}

inlines : List(XmlTree.Node) -> List(Document.Inline)
inlines = |nodes| {
	var $out = List.with_capacity(nodes.len())
	for node in nodes {
		if is_content(node) {
			$out = List.append($out, inline(node))
		}
	}
	$out
}

inline : XmlTree.Node -> Document.Inline
inline = |node|
	match node {
		Element(element) if is_w(element.name, "r") => Run(run(element.children))
		Element(element) if is_w_in(element.name, inline_containers) => Container({ element: without_children(element), content: inlines(element.children) })
		_ => Preserved(node)
	}

run : List(XmlTree.Node) -> Document.Run
run = |children| {
	var $properties = Err(Missing)
	var $content = List.with_capacity(children.len())
	for child in children {
		match ($properties, child) {
			(Err(Missing), Element(element)) if is_w(element.name, "rPr") => {
				$properties = Ok({ preserved: kept(element.children) })
			}

			_ => {
				if is_content(child) {
					$content = List.append($content, run_content(child))
				}
			}
		}
	}
	{ properties: $properties ?? { preserved: [] }, content: $content }
}

run_content : XmlTree.Node -> Document.RunContent
run_content = |node|
	match node {
		Element(element) if element.name.namespace == Uri(wordprocessingml) =>
			match element.name.local {
				"t" => text(element) ?? Preserved(node)
				"tab" => Tab
				"br" => break_of(element) ?? Preserved(node)
				"cr" => Break({ kind: Line, clear: NoClear })
				"sym" => symbol(element) ?? Preserved(node)
				"softHyphen" => SoftHyphen
				"noBreakHyphen" => NonBreakingHyphen
				_ => Preserved(node)
			}

		_ => Preserved(node)
	}

# The text of `w:t`, which holds only character data. Unless the element
# says `xml:space="preserve"`, its whitespace is the producer's layout, as
# Word and LibreOffice read it: leading and trailing whitespace is removed,
# and each tab, carriage return and line feed left is a space.
text : Element -> Try(Document.RunContent, [NotText])
text = |element| {
	var $value = List.with_capacity(16)
	for child in element.children {
		match child {
			Text(content) => {
				$value = List.concat($value, content.to_utf8())
			}

			Element(_) => {
				return Err(NotText)
			}
		}
	}
	preserve = element.attributes.any(|attribute| attribute.name.namespace == Uri(xml_namespace) and attribute.name.local == "space" and attribute.value == "preserve")
	value = if preserve {
		$value
	} else {
		var $start = 0.U64
		while $start < $value.len() and is_space($value.get($start) ?? 0) {
			$start = $start + 1
		}
		var $end = $value.len()
		while $end > $start and is_space($value.get($end - 1) ?? 0) {
			$end = $end - 1
		}
		$value.sublist({ start: $start, len: $end - $start }).map(|byte| if (is_space(byte)) 32 else byte)
	}
	Ok(Text(Str.from_utf8(value) ?? ""))
}

is_space : U8 -> Bool
is_space = |byte| byte == 32 or byte == 9 or byte == 10 or byte == 13

xml_namespace : Str
xml_namespace = "http://www.w3.org/XML/1998/namespace"

break_of : Element -> Try(Document.RunContent, [Unknown])
break_of = |element| {
	kind = match value_of(element, "type") {
		Err(NotFound) => Line
		Ok("textWrapping") => Line
		Ok("page") => Page
		Ok("column") => Column
		Ok(_) => return Err(Unknown)
	}
	clear = match value_of(element, "clear") {
		Err(NotFound) => NoClear
		Ok("none") => NoClear
		Ok("left") => Left
		Ok("right") => Right
		Ok("all") => All
		Ok(_) => return Err(Unknown)
	}
	Ok(Break({ kind, clear }))
}

# A symbol: `w:char` is four hexadecimal digits, and a symbol without a
# font is in the run's font, which the model names as "".
symbol : Element -> Try(Document.RunContent, [Unknown])
symbol = |element| {
	digits = (value_of(element, "char") ? |_| Unknown).to_utf8()
	if digits.len() != 4 {
		return Err(Unknown)
	}
	code = digits.fold(Ok(0.U16), |sum, digit| Ok((sum?) * 16 + (hex_digit(digit)?))) ? |_| Unknown
	Ok(Symbol({ font: value_of(element, "font") ?? "", code }))
}

hex_digit : U8 -> Try(U16, [NotHex])
hex_digit = |digit|
	if digit >= '0' and digit <= '9' {
		Ok((digit - '0').to_u16())
	} else if digit >= 'a' and digit <= 'f' {
		Ok((digit - 'a' + 10).to_u16())
	} else if digit >= 'A' and digit <= 'F' {
		Ok((digit - 'A' + 10).to_u16())
	} else {
		Err(NotHex)
	}

Element : { name : XmlTree.Name, bindings : List(XmlTree.Binding), attributes : List(XmlTree.Attribute), children : List(XmlTree.Node) }

wordprocessingml : Str
wordprocessingml = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

is_w : XmlTree.Name, Str -> Bool
is_w = |name, local| name.namespace == Uri(wordprocessingml) and name.local == local

is_w_in : XmlTree.Name, List(Str) -> Bool
is_w_in = |name, locals| name.namespace == Uri(wordprocessingml) and locals.contains(name.local)

is_element : XmlTree.Node, Str -> Bool
is_element = |node, local|
	match node {
		Element(element) => is_w(element.name, local)
		Text(_) => Bool.False
	}

# An element, or text that is not only whitespace.
is_content : XmlTree.Node -> Bool
is_content = |node|
	match node {
		Element(_) => Bool.True
		Text(content) => !content.to_utf8().all(|byte| byte == 32 or byte == 9 or byte == 10 or byte == 13)
	}

kept : List(XmlTree.Node) -> List(XmlTree.Node)
kept = |nodes| nodes.keep_if(is_content)

without_children : Element -> XmlTree.Node
without_children = |element| Element({ name: element.name, bindings: element.bindings, attributes: element.attributes, children: [] })

# The value of a WordprocessingML attribute of an element.
value_of : Element, Str -> Try(Str, [NotFound])
value_of = |element, local|
	element.attributes.find_first(|attribute| is_w(attribute.name, local)).map_ok(|attribute| attribute.value)

# The blocks of a main document part with this body content.
read : Str -> List(Document.Block)
read = |content| {
	tree = XmlTree.parse("<w:document xmlns:w='${wordprocessingml}'><w:body>${content}</w:body></w:document>".to_utf8(), {}) ?? Text("")
	WmlRead.body(tree)
}

## A run's text, tab, breaks, symbol and hyphens are read in order.
expect {
	run_xml = "<w:r><w:rPr><w:b/></w:rPr><w:t xml:space='preserve'>a </w:t><w:tab/><w:br/><w:br w:type='page'/><w:br w:type='column'/><w:br w:clear='all'/><w:cr/><w:sym w:font='Wingdings' w:char='F0E0'/><w:softHyphen/><w:noBreakHyphen/></w:r>"
	expected : List(Document.RunContent)
	expected = [
		Text("a "),
		Tab,
		Break({ kind: Line, clear: NoClear }),
		Break({ kind: Page, clear: NoClear }),
		Break({ kind: Column, clear: NoClear }),
		Break({ kind: Line, clear: All }),
		Break({ kind: Line, clear: NoClear }),
		Symbol({ font: "Wingdings", code: 0xF0E0 }),
		SoftHyphen,
		NonBreakingHyphen,
	]
	match read("<w:p>${run_xml}</w:p>") {
		[Paragraph({ properties, content: [Run(r)] })] => properties == { preserved: [] } and r.content == expected and r.properties.preserved.len() == 1
		_ => Bool.False
	}
}

## Text keeps its whitespace where `xml:space="preserve"` says so; elsewhere
## leading and trailing whitespace is removed and tabs and line ends are
## spaces.
expect {
	match read("<w:p><w:r><w:t xml:space='preserve'> a\tb </w:t><w:t>  c  d\n\te  </w:t><w:t> </w:t></w:r></w:p>") {
		[Paragraph({ properties: _, content: [Run(r)] })] => r.content == [Text(" a\tb "), Text("c  d  e"), Text("")]
		_ => Bool.False
	}
}

## Run content the model cannot hold is kept as it was read, in its place:
## a break of an unknown type, a symbol without a code, text holding an
## element, and elements the model does not represent.
expect {
	odd = ["<w:br w:type='sideways'/>", "<w:sym w:font='Symbol'/>", "<w:t>a<w:b/></w:t>", "<w:footnoteReference w:id='1'/>", "<w:delText>gone</w:delText>"]
	match read("<w:p><w:r>${Str.join_with(odd, "<w:tab/>")}</w:r></w:p>") {
		[Paragraph({ properties: _, content: [Run(r)] })] =>
			r.content.len() == 9
				and r.content.get(1) == Ok(Tab)
				and r.content.keep_if(|content| content != Tab).all(
					|content|
						match content {
							Preserved(_) => Bool.True
							_ => Bool.False
						},
				)

		_ => Bool.False
	}
}

## Hyperlinks, revisions and content controls keep their element and have
## their content read; bookmarks and comment ranges stay in their place.
expect {
	content = "<w:pPr><w:pStyle w:val='Body'/></w:pPr><w:bookmarkStart w:id='1' w:name='b'/><w:hyperlink w:anchor='b'><w:r><w:t>link</w:t></w:r></w:hyperlink><w:ins w:id='2' w:author='A'><w:r><w:t>new</w:t></w:r></w:ins><w:del w:id='3' w:author='A'><w:r><w:delText>old</w:delText></w:r></w:del><w:sdt><w:sdtPr/><w:sdtContent><w:r><w:t>field</w:t></w:r></w:sdtContent></w:sdt><w:bookmarkEnd w:id='1'/>"
	match read("<w:p>${content}</w:p>") {
		[Paragraph({ properties, content: [Preserved(_), Container(link), Container(ins), Container(del), Container(sdt), Preserved(_)] })] =>
			properties.preserved.len() == 1
				and link.content.len() == 1
				and ins.content.len() == 1
				and del.content.len() == 1
				and match sdt.content {
					[Preserved(_), Container(inner)] => inner.content.len() == 1
					_ => Bool.False
				}
				and match link.element {
					Element(element) => element.children.is_empty() and element.attributes.len() == 1
					Text(_) => Bool.False
				}

		_ => Bool.False
	}
}

## A table holds its properties, grid, rows and cells, a cell holds its
## paragraphs, and the section properties after it are kept as they were
## read.
expect {
	table_xml = "<w:tbl><w:tblPr/><w:tr><w:tc><w:tcPr/><w:p><w:r><w:t>cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>"
	match read("<w:p/>\n  ${table_xml}\n  <w:sectPr/>") {
		[Paragraph(empty), Table({ properties, grid: [], content: [Row({ properties: row_properties_read, content: [Cell({ properties: cell_properties_read, content: [Paragraph(in_cell)] })] })] }), Preserved(_)] =>
			empty == { properties: { preserved: [] }, content: [] }
				and properties == { style: Unset, width: Unset, borders: [], shading: Unset, preserved: [] }
				and row_properties_read == { header: Unset, grid_before: Unset, grid_after: Unset, preserved: [] }
				and cell_properties_read == { width: Unset, span: Unset, merge: Unset, borders: [], shading: Unset, alignment: Unset, preserved: [] }
				and in_cell.content.len() == 1

		_ => Bool.False
	}
}

## Table, row and cell properties the model holds are read and the rest are
## kept in order: a style, widths, borders, shading, a header row, grid
## columns skipped, a span, a merge and a vertical alignment.
expect {
	border = "w:val='single' w:sz='4' w:space='0' w:color='auto'"
	table_xml = "<w:tblPr><w:tblStyle w:val='Grid'/><w:tblW w:w='5000' w:type='pct'/><w:jc w:val='center'/><w:tblBorders><w:top ${border}/><w:insideV w:val='nil'/></w:tblBorders><w:shd w:val='clear' w:color='auto' w:fill='D9E2F3'/></w:tblPr>"
	grid_xml = "<w:tblGrid><w:gridCol w:w='2000'/><w:gridCol/></w:tblGrid>"
	row_xml = "<w:trPr><w:cantSplit/><w:gridBefore w:val='1'/><w:tblHeader/><w:gridAfter w:val='2'/></w:trPr>"
	cell_xml = "<w:tcPr><w:tcW w:w='0' w:type='auto'/><w:gridSpan w:val='2'/><w:vMerge w:val='restart'/><w:tcBorders><w:tl2br w:val='double' w:color='FF0000'/></w:tcBorders><w:shd w:val='pct25' w:fill='auto'/><w:noWrap/><w:vAlign w:val='center'/></w:tcPr>"
	match read("<w:tbl>${table_xml}${grid_xml}<w:tr>${row_xml}<w:tc>${cell_xml}<w:p/></w:tc></w:tr></w:tbl>") {
		[Table({ properties, grid: [Column(2000), Preserved(_)], content: [Row({ properties: row_read, content: [Cell({ properties: cell_read, content: [Paragraph(_)] })] })] })] =>
			properties.style == Style("Grid")
				and properties.width == Fiftieths(5000)
				and properties.borders == [
					{ edge: Top, line: "single", size: Eighths(4), space: Points(0), color: Auto },
					{ edge: InsideVertical, line: "nil", size: Unset, space: Unset, color: Unset },
				]
				and properties.shading == Shading({ pattern: "clear", color: Auto, fill: Rgb("D9E2F3") })
				and properties.preserved.len() == 1
				and row_read.header == On
				and row_read.grid_before == Columns(1)
				and row_read.grid_after == Columns(2)
				and row_read.preserved.len() == 1
				and cell_read.width == Auto
				and cell_read.span == Columns(2)
				and cell_read.merge == Restart
				and cell_read.borders == [{ edge: DiagonalDown, line: "double", size: Unset, space: Unset, color: Rgb("FF0000") }]
				and cell_read.shading == Shading({ pattern: "pct25", color: Unset, fill: Auto })
				and cell_read.alignment == Center
				and cell_read.preserved.len() == 1

		_ => Bool.False
	}
}

## A property element whose attributes the model cannot hold is kept as it
## was read, and the first one the model can hold gives the property: an
## automatic width with a size, an unknown merge and theme colours are kept.
expect {
	cell_xml = "<w:tcPr><w:tcW w:w='100' w:type='auto'/><w:tcW w:w='100' w:type='dxa'/><w:tcW w:w='200' w:type='dxa'/><w:vMerge w:val='sideways'/><w:shd w:val='clear' w:themeFill='accent1'/><w:tcBorders><w:top w:val='single' w:themeColor='text1'/></w:tcBorders></w:tcPr>"
	match read("<w:tbl><w:tr><w:tc>${cell_xml}<w:p/></w:tc></w:tr></w:tbl>") {
		[Table({ properties: _, grid: _, content: [Row({ properties: _, content: [Cell({ properties, content: _ })] })] })] =>
			properties.width == Twips(100)
				and properties.merge == Unset
				and properties.shading == Unset
				and properties.borders == []
				and properties.preserved.len() == 5

		_ => Bool.False
	}
}

## Widths written with a fraction, as Google Docs exports write them, are
## rounded with a diagnostic, and so is a percentage finer than the model
## holds; a whole percentage and a vertical merge without a value are read
## as they are.
expect {
	xml = "<w:tbl><w:tblPr><w:tblW w:w='33.3333%' w:type='pct'/></w:tblPr><w:tblGrid><w:gridCol w:w='10470.0'/><w:gridCol w:w='99.5'/></w:tblGrid><w:tr><w:tc><w:tcPr><w:tcW w:w='50%' w:type='pct'/><w:vMerge/></w:tcPr><w:p/></w:tc></w:tr></w:tbl>"
	tree = XmlTree.parse("<w:document xmlns:w='${wordprocessingml}'><w:body>${xml}</w:body></w:document>".to_utf8(), {}) ?? Text("")
	result = WmlRead.read_body(tree)
	match result.blocks {
		[Table({ properties, grid: columns_read, content: [Row({ properties: _, content: [Cell(cell_read)] })] })] =>
			properties.width == Fiftieths(1667)
				and columns_read == [Column(10470), Column(100)]
				and cell_read.properties.width == Fiftieths(2500)
				and cell_read.properties.merge == Continue
				and result.diagnostics == [
					Rounded({ element: "tblW", attribute: "w", value: "33.3333%" }),
					Rounded({ element: "gridCol", attribute: "w", value: "10470.0" }),
					Rounded({ element: "gridCol", attribute: "w", value: "99.5" }),
				]

		_ => Bool.False
	}
}

## Tables nest in cells, and rows and cells in content controls are read
## through them, with bookmarks and row property exceptions in their place.
expect {
	inner = "<w:tbl><w:tr><w:tc><w:p><w:r><w:t>inner</w:t></w:r></w:p></w:tc></w:tr></w:tbl>"
	cell_control = "<w:sdt><w:sdtPr/><w:sdtContent><w:tc><w:p/></w:tc></w:sdtContent></w:sdt>"
	row_control = "<w:sdt><w:sdtContent><w:tr><w:tblPrEx/><w:tc>${inner}<w:p/></w:tc>${cell_control}</w:tr></w:sdtContent></w:sdt>"
	match read("<w:tbl><w:bookmarkStart w:id='1' w:name='b'/>${row_control}</w:tbl>") {
		[Table(outer)] =>
			match (outer.content, Document.table_rows(outer)) {
				([Preserved(_), Container(_)], [only_row]) =>
					match (only_row.content, Document.row_cells(only_row)) {
						([Preserved(_), Cell(_), Container(_)], [first, second]) =>
							second.content.len() == 1 and match first.content {
								[Table(nested), Paragraph(_)] => Document.table_rows(nested).len() == 1
								_ => Bool.False
							}

						_ => Bool.False
					}

				_ => Bool.False
			}

		_ => Bool.False
	}
}

## Numbers are read leniently and rounded halves away from zero, and what is
## not a number, or has more digits than are read, is not one.
expect {
	decimal("12", 1) == Ok({ value: 12, exact: Bool.True })
		and decimal("-2.5", 1) == Ok({ value: -3, exact: Bool.False })
		and decimal("+.25", 50) == Ok({ value: 13, exact: Bool.False })
		and decimal("1.5", 50) == Ok({ value: 75, exact: Bool.True })
		and decimal("", 1) == Err(NotNumber)
		and decimal("1.2.3", 1) == Err(NotNumber)
		and decimal("1e3", 1) == Err(NotNumber)
		and decimal("1234567890123456", 1) == Err(NotNumber)
}

## Markup compatibility is applied first: an alternative is read as the
## branch the package understands and ignorable extensions are skipped.
expect {
	mc = "xmlns:mc='http://schemas.openxmlformats.org/markup-compatibility/2006' xmlns:x='urn:example:x' mc:Ignorable='x'"
	choice = "<mc:AlternateContent><mc:Choice Requires='x'><x:shape/></mc:Choice><mc:Fallback><w:t>fallback</w:t></mc:Fallback></mc:AlternateContent>"
	xml = "<w:document xmlns:w='${wordprocessingml}' ${mc}><w:body><x:block/><w:p x:id='1'><w:r>${choice}</w:r></w:p></w:body></w:document>"
	tree = XmlTree.parse(xml.to_utf8(), {}) ?? Text("")
	match WmlRead.body(tree) {
		[Paragraph({ properties: _, content: [Run(r)] })] => r.content == [Text("fallback")]
		_ => Bool.False
	}
}

## A tree that is not a WordprocessingML document, or has no body, has no
## blocks.
expect {
	other = XmlTree.parse("<w:styles xmlns:w='${wordprocessingml}'><w:body><w:p/></w:body></w:styles>".to_utf8(), {}) ?? Text("")
	bare = XmlTree.parse("<w:document xmlns:w='${wordprocessingml}'/>".to_utf8(), {}) ?? Text("")
	WmlRead.body(other) == [] and WmlRead.body(bare) == []
}
