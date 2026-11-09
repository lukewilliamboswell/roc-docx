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
	body : XmlTree.Node -> List(Document.Block)
	body = |tree|
		match Mce.process(tree).interpreted {
			Element(root) if is_w(root.name, "document") =>
				match root.children.find_first(|child| is_element(child, "body")) {
					Ok(Element(element)) => blocks(element.children)
					_ => []
				}

			_ => []
		}
}

# Elements whose content is blocks, read as containers in a block's place.
block_containers : List(Str)
block_containers = ["tbl", "tr", "tc", "sdt", "sdtContent", "customXml"]

# Elements whose content is paragraph content, read as containers in an
# inline's place.
inline_containers : List(Str)
inline_containers = ["hyperlink", "ins", "del", "moveFrom", "moveTo", "fldSimple", "sdt", "sdtContent", "smartTag", "customXml", "dir", "bdo"]

blocks : List(XmlTree.Node) -> List(Document.Block)
blocks = |nodes| {
	var $out = List.with_capacity(nodes.len())
	for node in nodes {
		if is_content(node) {
			$out = List.append($out, block(node))
		}
	}
	$out
}

block : XmlTree.Node -> Document.Block
block = |node|
	match node {
		Element(element) if is_w(element.name, "p") => Paragraph(paragraph(element.children))
		Element(element) if is_w_in(element.name, block_containers) => Container({ element: without_children(element), content: blocks(element.children) })
		_ => Preserved(node)
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

## A table is a container of rows, cells and their paragraphs, and the
## section properties are kept as they were read.
expect {
	table = "<w:tbl><w:tblPr/><w:tr><w:tc><w:tcPr/><w:p><w:r><w:t>cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>"
	match read("<w:p/>\n  ${table}\n  <w:sectPr/>") {
		[Paragraph(empty), Container({ element: _, content: [Preserved(_), Container({ element: _, content: [Container({ element: _, content: [Preserved(_), Paragraph(cell)] })] })] }), Preserved(_)] =>
			empty == { properties: { preserved: [] }, content: [] } and cell.content.len() == 1

		_ => Bool.False
	}
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
