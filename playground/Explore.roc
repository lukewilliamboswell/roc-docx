import pf.Wire
import pf.Worker
import docx.Comments
import docx.Document
import docx.Docx
import docx.Limits
import docx.Mce
import docx.Opc
import docx.Revisions
import docx.Styles
import docx.XmlTree
import Base64

## What the playground shows of a document. One worker run reads the whole
## document into a [Model] of plain records, so the page navigates it
## without asking again; the XML of a part and the round trip are runs of
## their own because only some visits want them.
Explore := [].{

	## A piece of a paragraph's text and the marks it is shown with, as CSS
	## class names: `b`, `i`, `u`, `s`, `sup`, `sub`, `link`, `field`, `ins`,
	## `del`, `move-from`, `move-to` and `preserved`.
	Segment : { text : Str, marks : Str }

	## A body block as the structure view shows it.
	Block : {
		index : U64,
		kind : Str,
		level : U64,
		style : Str,
		style_chain : List(Str),
		segments : List(Segment),
		rows : List(List(Str)),
		comments : List(U64),
		stated : List((Str, Str)),
		source : Str,
		model : Str,
	}

	## A comment, with the key of the block its range begins in, if any.
	Comment : { id : U64, author : Str, date : Str, parent : U64, reply : Bool, resolved : Bool, anchor : Str, text : Str, block : Str }

	Change : { id : U64, kind : Str, subject : Str, author : Str, date : Str, text : Str }

	Entry : { name : Str, method : Str, compressed : U64, size : U64, crc : Str }

	Relationship : { id : Str, kind : Str, target : Str, external : Bool }

	Part : { name : Str, content_type : Str, size : U64, relationships : List(Relationship) }

	Bound : { name : Str, used : U64, limit : U64 }

	Diagnostic : { stage : Str, text : Str }

	## The document, every layer of it.
	Model : {
		zip : List(Entry),
		bounds : List(Bound),
		package_relationships : List(Relationship),
		parts : List(Part),
		xml_parts : List(Str),
		properties : List((Str, Str)),
		blocks : List(Block),
		comments : List(Comment),
		changes : List(Change),
		diagnostics : List(Diagnostic),
		text : Str,
		final_text : Str,
		original_text : Str,
		tracking : Bool,
	}

	## One line of a part's XML: its depth, then the element's name and
	## attributes, or a text node; what reading does with it (`understood`,
	## `extension`, `mce` or `dropped`), and the attributes it drops.
	XmlLine : { depth : U64, tag : Str, attributes : Str, dropped : Str, text : Str, class : Str }

	## A part of the round trip: how the written part compares with the read
	## one (`identical`, `rewritten`, `added` or `removed`) and both sizes.
	Compared : { name : Str, outcome : Str, before : U64, after : U64 }

	## The document written back.
	Written : { compared : List(Compared), size : U64, equivalent : Bool, base64 : Str }

	## Why a run could not read the document.
	Problem : [Unreadable(Str)]

	model : Worker.Task(Wire.Bytes, Model, Problem)
	model = Worker.task({ name: "roc-docx/playground/model", run!: |doc| Explore.read(doc.to_list()) })

	part_xml : Worker.Task({ doc : Wire.Bytes, part : Str }, List(XmlLine), Problem)
	part_xml = Worker.task({ name: "roc-docx/playground/part-xml", run!: |{ doc, part }| Explore.xml_lines(doc.to_list(), part) })

	round_trip : Worker.Task(Wire.Bytes, Written, Problem)
	round_trip = Worker.task({ name: "roc-docx/playground/round-trip", run!: |doc| Explore.written(doc.to_list()) })

	## Read a parsed document into a [Model]. [Review] and [Generate] call it
	## on the documents they make.
	of_document : List(U8), Document, List(Document.Diagnostic) -> Try(Model, Problem)
	of_document = |bytes, document, read_diagnostics| {
		pkg = Opc.open(bytes, {}) ? |e| Unreadable(Str.inspect(e))
		parts = Opc.parts(pkg)
		main = Opc.main_document(pkg) ? |e| Unreadable(Str.inspect(e))
		blocks = Docx.body(document)
		styles = Docx.styles(document)
		comments = Docx.comments(document)
		numbering = Docx.numbering(document)
		sources = Explore.body_children(pkg, main.name)
		shown = Explore.blocks(blocks, styles.styles, sources)
		limits : Limits
		limits = {}
		total = parts.fold(0, |sum, p| sum + p.size)
		largest = parts.fold(0, |most, p| if (p.size > most) p.size else most)
		Ok({
			zip: parts.map(|p| Explore.entry(pkg, p)),
			bounds: [
				{ name: "Entries", used: parts.len(), limit: limits.max_entries },
				{ name: "Largest part (bytes)", used: largest, limit: limits.max_part_bytes },
				{ name: "All parts (bytes)", used: total, limit: limits.max_total_bytes },
			],
			package_relationships: Explore.relationships(Opc.relationships(pkg, "/") ?? []),
			parts: parts.map(|p| { name: p.name, content_type: p.content_type, size: p.size, relationships: Explore.relationships(Opc.relationships(pkg, p.name) ?? []) }),
			xml_parts: parts.keep_if(|p| Explore.is_xml(p.content_type)).map(|p| p.name),
			properties: Explore.core(Docx.core_properties(document)),
			blocks: shown,
			comments: comments.comments.map(|c| Explore.comment(c, shown)),
			changes: Docx.revisions(document).map(Explore.change),
			diagnostics: read_diagnostics.map(|d| { stage: "Model", text: Str.inspect(d) })
				.concat(comments.diagnostics.map(|d| { stage: "Comments", text: Str.inspect(d) }))
				.concat(styles.diagnostics.map(|d| { stage: "Styles", text: Str.inspect(d) }))
				.concat(numbering.diagnostics.map(|d| { stage: "Numbering", text: Str.inspect(d) })),
			text: Docx.text(document),
			final_text: Docx.final_text(document),
			original_text: Docx.original_text(document),
			tracking: Docx.tracks_revisions(document),
		})
	}

	read : List(U8) -> Try(Model, Problem)
	read = |bytes| {
		parsed = Docx.parse(bytes) ? |e| Unreadable(Str.inspect(e))
		Explore.of_document(bytes, parsed.document, parsed.diagnostics)
	}

	entry : Opc.Package, Opc.Part -> Entry
	entry = |pkg, part|
		match Opc.stored(pkg, part.name) {
			Ok(s) => { name: part.name, method: Explore.method(s.method), compressed: s.compressed_size, size: s.uncompressed_size, crc: Explore.hex(s.crc.to_u64(), 8) }
			Err(_) => { name: part.name, method: "?", compressed: 0, size: part.size, crc: "" }
		}

	method : Opc.Method -> Str
	method = |m|
		match m {
			Stored => "stored"
			Deflated => "deflate"
			Other(n) => "method ${n.to_str()}"
		}

	hex : U64, U64 -> Str
	hex = |n, width| {
		digits = "0123456789abcdef".to_utf8()
		var $out = []
		var $rest = n
		var $left = width
		while $left > 0 {
			$out = List.prepend($out, digits.get($rest % 16) ?? '0')
			$rest = $rest // 16
			$left = $left - 1
		}
		Str.from_utf8($out) ?? ""
	}

	relationships : List(Opc.Relationship) -> List(Relationship)
	relationships = |rels| rels.map(|r| { id: r.id, kind: Explore.short_kind(r.kind), target: r.target, external: r.mode == External })

	## The last segment of a relationship type URI, which names it.
	short_kind : Str -> Str
	short_kind = |kind|
		match kind.split_last("/") {
			Ok({ before: _, after }) => after
			Err(_) => kind
		}

	## The main document's body children, for showing each block's source.
	body_children : Opc.Package, Str -> List(XmlTree.Node)
	body_children = |pkg, name|
		match Opc.part_bytes(pkg, name) {
			Ok(xml) =>
				match XmlTree.parse(xml, {}) {
					Ok(Element({ children, .. })) => {
						body = children.keep_if(|c| Explore.local(c) == "body").first() ?? Text("")
						match body {
							Element(b) => b.children.keep_if(|c| Explore.local(c) != "" and Explore.local(c) != "proofErr")
							Text(_) => []
						}
					}
					_ => []
				}
			Err(_) => []
		}

	local : XmlTree.Node -> Str
	local = |node|
		match node {
			Element({ name, .. }) => name.local
			Text(_) => ""
		}

	## Pair each block with the body child it was read from: a section
	## break stated in a paragraph comes from that paragraph, and the body's
	## own last `w:sectPr` from itself.
	blocks : List(Document.Block), Styles, List(XmlTree.Node) -> List(Block)
	blocks = |body, styles, sources| {
		var $out = List.with_capacity(body.len())
		var $at = 0.U64
		var $previous = Text("")
		for b in body {
			source = match b {
				Section(_) =>
					match sources.get($at) {
						Ok(node) =>
							if Explore.local(node) == "sectPr" {
								$at = $at + 1
								node
							} else {
								$previous
							}
						Err(_) => $previous
					}
				_ => {
					node = sources.get($at) ?? Text("")
					$at = $at + 1
					node
				}
			}
			$previous = source
			$out = List.append($out, Explore.block($out.len(), b, styles, source))
		}
		$out
	}

	block : U64, Document.Block, Styles, XmlTree.Node -> Block
	block = |index, b, styles, source| {
		base = { index, kind: "", level: 0, style: "", style_chain: [], segments: [], rows: [], comments: [], stated: [], source: Explore.snippet(source), model: Explore.clipped(Str.inspect(b), 6000) }
		match b {
			Paragraph(p) => {
				style = match p.properties.style {
					Style(s) => s
					Unset => ""
				}
				chain = Explore.chain(styles, style)
				heading = Explore.heading_level(styles, chain)
				list_level = match (p.properties.numbering.instance, p.properties.numbering.level) {
					(Instance(_), Level(l)) => l.to_u64() + 1
					(Instance(_), Unset) => 1
					_ => 0
				}
				kind = if (heading > 0) "heading" else if (list_level > 0) "list" else "paragraph"
				{
					..base,
					kind,
					level: if (heading > 0) heading else list_level,
					style,
					style_chain: chain,
					segments: Explore.segments(p.content, "", List.with_capacity(4)),
					comments: Explore.comment_ids(p.content, []),
					stated: Explore.stated(p.properties),
				}
			}
			Table(t) => { ..base, kind: "table", rows: Explore.table_rows(t) }
			Section(_) => { ..base, kind: "section" }
			CommentStart(id) => { ..base, kind: "marker", segments: [{ text: "comment ${id.to_str()} begins", marks: "" }] }
			CommentEnd(id) => { ..base, kind: "marker", segments: [{ text: "comment ${id.to_str()} ends", marks: "" }] }
			Container({ element, .. }) => { ..base, kind: "preserved", segments: [{ text: Explore.qname_of(element), marks: "" }] }
			Preserved(node) => { ..base, kind: "preserved", segments: [{ text: Explore.qname_of(node), marks: "" }] }
		}
	}

	## A paragraph style and the styles it is based on, nearest first.
	chain : Styles, Str -> List(Str)
	chain = |styles, id| {
		var $out = []
		var $next = id
		while $next != "" and $out.len() < 16 and !$out.contains($next) {
			$out = List.append($out, $next)
			$next = match Styles.get(styles, $next) {
				Ok(s) =>
					match s.based_on {
						BasedOn(b) => b
						NoBase => ""
					}
				Err(_) => ""
			}
		}
		$out
	}

	## The heading level a style chain gives: a style named "heading N" or
	## "Title", or with an identifier of that form.
	heading_level : Styles, List(Str) -> U64
	heading_level = |styles, ids|
		ids.fold(
			0,
			|found, id|
				if found > 0 {
					found
				} else {
					name = match Styles.get(styles, id) {
						Ok({ name: Named(n), .. }) => n
						_ => id
					}
					Explore.heading_of(name)
				},
		)

	heading_of : Str -> U64
	heading_of = |name| {
		lower = Str.from_utf8(name.to_utf8().map(|c| if (c >= 'A' and c <= 'Z') c + 32 else c)) ?? name
		if lower == "title" {
			1
		} else {
			digits = lower.drop_prefix("heading").trim()
			if digits == lower {
				0
			} else {
				match U64.from_str(digits) {
					Ok(n) if n >= 1 and n <= 9 => n
					_ => 0
				}
			}
		}
	}

	segments : List(Document.Inline), Str, List(Segment) -> List(Segment)
	segments = |inlines, marks, out|
		inlines.fold(
			out,
			|acc, inline|
				match inline {
					Run(r) => {
						marked = Explore.marks(marks, r.properties)
						r.content.fold(
							acc,
							|so_far, c|
								match c {
									Text(t) => List.append(so_far, { text: t, marks: marked })
									Tab => List.append(so_far, { text: "\t", marks: marked })
									Break(_) => List.append(so_far, { text: "\n", marks: marked })
									_ => so_far
								},
						)
					}
					Hyperlink({ content, .. }) => Explore.segments(content, Explore.join(marks, "link"), acc)
					SimpleField({ content, .. }) => Explore.segments(content, Explore.join(marks, "field"), acc)
					Revision(rev) => {
						kind = match rev.kind {
							Insertion => "ins"
							Deletion => "del"
							MoveSource => "move-from"
							MoveDestination => "move-to"
						}
						Explore.segments(rev.content, Explore.join(marks, kind), acc)
					}
					Container({ content, .. }) => Explore.segments(content, marks, acc)
					Preserved(node) => List.append(acc, { text: "⟨${Explore.qname_of(node)}⟩", marks: Explore.join(marks, "preserved") })
					_ => acc
				},
		)

	marks : Str, Document.RunProperties -> Str
	marks = |outer, p| {
		on = |v, name|
			match v {
				On => [name]
				_ => []
			}
		underline = match p.underline {
			Underline(_) => ["u"]
			Unset => []
		}
		vertical = match p.vertical_align {
			Superscript => ["sup"]
			Subscript => ["sub"]
			_ => []
		}
		own = on(p.bold, "b").concat(on(p.italic, "i")).concat(underline).concat(on(p.strike, "s")).concat(vertical)
		own.fold(outer, |acc, m| Explore.join(acc, m))
	}

	join : Str, Str -> Str
	join = |a, b| if (a == "") b else "${a} ${b}"

	comment_ids : List(Document.Inline), List(U64) -> List(U64)
	comment_ids = |inlines, out|
		inlines.fold(
			out,
			|acc, inline|
				match inline {
					CommentStart(id) => List.append(acc, id)
					Hyperlink({ content, .. }) => Explore.comment_ids(content, acc)
					SimpleField({ content, .. }) => Explore.comment_ids(content, acc)
					Revision(rev) => Explore.comment_ids(rev.content, acc)
					Container({ content, .. }) => Explore.comment_ids(content, acc)
					_ => acc
				},
		)

	## The paragraph properties stated on the paragraph itself.
	stated : Document.ParagraphProperties -> List((Str, Str))
	stated = |p| {
		alignment = match p.alignment {
			Aligned(a) => [("Alignment", Str.inspect(a))]
			Unset => []
		}
		numbering = match p.numbering.instance {
			Instance(n) => [("List", "numbering ${n.to_str()}, level ${Str.inspect(p.numbering.level)}")]
			Unset => []
		}
		toggle = |name, v|
			match v {
				On => [(name, "on")]
				Off => [(name, "off")]
				Unset => []
			}
		outline = match p.outline_level {
			Level(l) => [("Outline level", l.to_str())]
			Unset => []
		}
		alignment
			.concat(numbering)
			.concat(outline)
			.concat(toggle("Keep with next", p.keep_next))
			.concat(toggle("Keep lines together", p.keep_lines))
			.concat(toggle("Page break before", p.page_break_before))
			.concat(if (p.preserved.is_empty()) [] else [("Preserved elements", p.preserved.len().to_str())])
	}

	table_rows : Document.Table -> List(List(Str))
	table_rows = |t|
		t.content.fold(
			[],
			|rows, c|
				match c {
					Row(r) =>
						List.append(
							rows,
							r.content.fold(
								[],
								|cells, rc|
									match rc {
										Cell(cell) => List.append(cells, Str.join_with(cell.content.map(Explore.block_text), "\n"))
										_ => cells
									},
							),
						)
					_ => rows
				},
		)

	block_text : Document.Block -> Str
	block_text = |b|
		match b {
			Paragraph(p) => Document.paragraph_text(p)
			Table(t) => Str.join_with(Explore.table_rows(t).map(|r| Str.join_with(r, " | ")), "\n")
			_ => ""
		}

	comment : Comments.Anchored, List(Block) -> Comment
	comment = |{ id, comment: c, anchor }, shown| {
		parent = match c.parent {
			Parent(p) => p
			Unset => 0
		}
		{
			id,
			author: c.author,
			date: Explore.date(c.date),
			parent,
			reply: c.parent != Unset,
			resolved: c.resolved,
			anchor: match anchor {
				Range(text) => text
				Point => ""
				Unanchored => ""
			},
			text: Str.join_with(c.content.map(Explore.block_text), "\n"),
			block: match shown.find_first(|b| b.comments.contains(id)) {
				Ok(b) => b.index.to_str()
				Err(_) => ""
			},
		}
	}

	change : Revisions.Listed -> Change
	change = |r| {
		kind = match r.kind {
			Insertion => "Inserted"
			Deletion => "Deleted"
			MoveSource => "Moved away"
			MoveDestination => "Moved here"
			Merge => "Merged"
			Formatting => "Formatted"
		}
		subject = match r.of {
			Content => "text"
			ParagraphMark => "paragraph mark"
			Run => "run properties"
			Paragraph => "paragraph properties"
			Section => "section properties"
			Table => "table properties"
			Row => "row"
			Cell => "cell"
		}
		{ id: r.id, kind, subject, author: r.author, date: Explore.date(r.date), text: r.text }
	}

	date : [Unset, Date(Document.Timestamp)] -> Str
	date = |d|
		match d {
			Date(t) => t.written
			Unset => ""
		}

	core : Document.CoreProperties -> List((Str, Str))
	core = |p| {
		text = |name, v|
			match v {
				Text(s) => [(name, s)]
				Unset => []
			}
		dated = |name, v|
			match v {
				Date(s) => [(name, s)]
				Unset => []
			}
		numbered = match p.revision {
			Number(n) => [("Revision", n.to_str())]
			Unset => []
		}
		text("Title", p.title)
			.concat(text("Subject", p.subject))
			.concat(text("Creator", p.creator))
			.concat(text("Keywords", p.keywords))
			.concat(text("Description", p.description))
			.concat(text("Last modified by", p.last_modified_by))
			.concat(numbered)
			.concat(dated("Created", p.created))
			.concat(dated("Modified", p.modified))
	}

	is_xml : Str -> Bool
	is_xml = |content_type| content_type.ends_with("+xml") or content_type.ends_with("/xml")

	written : List(U8) -> Try(Written, Problem)
	written = |bytes| {
		parsed = Docx.parse(bytes) ? |e| Unreadable(Str.inspect(e))
		out = Docx.to_bytes(parsed.document) ? |e| Unreadable("Writing failed: ${Str.inspect(e)}")
		again = Docx.parse(out) ? |e| Unreadable("The written document does not read: ${Str.inspect(e)}")
		before = Opc.open(bytes, {}) ? |e| Unreadable(Str.inspect(e))
		after = Opc.open(out, {}) ? |e| Unreadable(Str.inspect(e))
		Ok({ compared: Explore.compare(before, after), size: out.len(), equivalent: Docx.equivalent(parsed.document, again.document), base64: Base64.encode(out) })
	}

	compare : Opc.Package, Opc.Package -> List(Compared)
	compare = |before, after| {
		kept = Opc.parts(before).map(
			|p|
				match Opc.part(after, p.name) {
					Ok(q) => {
						same = (Opc.part_bytes(before, p.name) ?? []) == (Opc.part_bytes(after, p.name) ?? [])
						{ name: p.name, outcome: if (same) "identical" else "rewritten", before: p.size, after: q.size }
					}
					Err(_) => { name: p.name, outcome: "removed", before: p.size, after: 0 }
				},
		)
		added = Opc.parts(after).keep_if(|q| Opc.part(before, q.name).is_err()).map(|q| { name: q.name, outcome: "added", before: 0, after: q.size })
		kept.concat(added)
	}

	xml_lines : List(U8), Str -> Try(List(XmlLine), Problem)
	xml_lines = |bytes, part| {
		pkg = Opc.open(bytes, {}) ? |e| Unreadable(Str.inspect(e))
		xml = Opc.part_bytes(pkg, part) ? |e| Unreadable(Str.inspect(e))
		tree = XmlTree.parse(xml, {}) ? |e| Unreadable(Str.inspect(e))
		Ok(Explore.lines(tree, 0, "", List.with_capacity(256)))
	}

	## The most lines of XML the page shows of one part.
	max_lines : U64
	max_lines = 5000

	## A part's XML as lines; `inherited` is the class an `mc:` or dropped
	## ancestor gives its content.
	lines : XmlTree.Node, U64, Str, List(XmlLine) -> List(XmlLine)
	lines = |node, depth, inherited, out|
		if out.len() >= Explore.max_lines {
			out
		} else {
			match node {
				Text(text) => {
					trimmed = text.trim()
					if trimmed.is_empty() {
						out
					} else {
						List.append(out, { depth, tag: "", attributes: "", dropped: "", text: Explore.clipped(trimmed, 400), class: if (inherited == "") "understood" else inherited })
					}
				}
				Element({ name, attributes, children, .. }) => {
					class = Explore.classify(name, attributes, inherited)
					kept = attributes.drop_if(Explore.is_dropped_attribute).map(Explore.attribute)
					gone = attributes.keep_if(Explore.is_dropped_attribute).map(Explore.attribute)
					line = { depth, tag: Explore.qname(name), attributes: Str.join_with(kept, ""), dropped: Str.join_with(gone, ""), text: "", class }
					child_class = if (class == "understood") inherited else class
					children.fold(List.append(out, line), |acc, child| Explore.lines(child, depth + 1, child_class, acc))
				}
			}
		}

	## What reading does with an element: editor state the architecture
	## drops, markup compatibility that is resolved, content in a namespace
	## the package does not understand that is kept as an extension, or
	## content it understands.
	classify : XmlTree.Name, List(XmlTree.Attribute), Str -> Str
	classify = |name, attributes, inherited|
		if inherited != "" {
			inherited
		} else if Explore.is_dropped(name, attributes) {
			"dropped"
		} else {
			match name.namespace {
				Uri(uri) =>
					if uri == "http://schemas.openxmlformats.org/markup-compatibility/2006" {
						"mce"
					} else if Mce.understood.contains(uri) {
						"understood"
					} else {
						"extension"
					}
				NoNamespace => "understood"
			}
		}

	is_dropped : XmlTree.Name, List(XmlTree.Attribute) -> Bool
	is_dropped = |name, attributes|
		name.local == "proofErr"
			or name.local == "lastRenderedPageBreak"
			or (name.local == "bookmarkStart" and attributes.any(|a| a.name.local == "name" and a.value == "_GoBack"))

	is_dropped_attribute : XmlTree.Attribute -> Bool
	is_dropped_attribute = |a| a.name.local.starts_with("rsid")

	attribute : XmlTree.Attribute -> Str
	attribute = |a| " ${Explore.qname(a.name)}=\"${Explore.clipped(a.value, 120)}\""

	qname : XmlTree.Name -> Str
	qname = |name|
		match name.prefix {
			Prefix(p) => "${p}:${name.local}"
			Unprefixed => name.local
		}

	qname_of : XmlTree.Node -> Str
	qname_of = |node|
		match node {
			Element({ name, .. }) => Explore.qname(name)
			Text(_) => "text"
		}

	## A block's source element as indented lines, at most 60.
	snippet : XmlTree.Node -> Str
	snippet = |node| {
		rendered = Explore.lines(node, 0, "", List.with_capacity(16)).map(
			|l| {
				indent = Str.repeat("  ", l.depth)
				if (l.tag == "") "${indent}${l.text}" else "${indent}<${l.tag}${l.attributes}>"
			},
		)
		shown = Str.join_with(rendered.take_first(60), "\n")
		if (rendered.len() > 60) "${shown}\n…" else shown
	}

	clipped : Str, U64 -> Str
	clipped = |s, most| {
		bytes = s.to_utf8()
		if bytes.len() <= most {
			s
		} else {
			# Back off to a character boundary.
			var $end = most
			while $end > 0 and ((bytes.get($end) ?? 0) >= 128 and (bytes.get($end) ?? 0) < 192) {
				$end = $end - 1
			}
			(Str.from_utf8(bytes.take_first($end)) ?? "").concat("…")
		}
	}
}

## A relationship type is named by its last segment.
expect Explore.short_kind("http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles") == "styles"

## Headings are recognised by style name, and "Title" is a first-level one.
expect Explore.heading_of("heading 2") == 2 and Explore.heading_of("Title") == 1 and Explore.heading_of("Normal") == 0

## A CRC prints as eight hexadecimal digits.
expect Explore.hex(255, 8) == "000000ff"

## Clipping keeps whole characters.
expect Explore.clipped("aé", 2) == "a…"
