import pf.Wire
import pf.Worker
import docx.Comments
import docx.Document
import docx.Docx
import docx.Opc
import docx.Revisions
import docx.XmlTree
import Base64

## What the playground shows of a document, computed in workers. Each program
## receives the document's bytes and answers plain records the page renders,
## so the page never holds the parsed model.
Explore := [].{

	## One item of a list the page shows: a heading, a line under it and a body.
	Card : { key : Str, title : Str, detail : Str, body : Str }

	## The layers of a document, as cards.
	Explored : {
		summary : Str,
		parts : List(Card),
		relationships : List(Card),
		properties : List(Card),
		blocks : List(Card),
		comments : List(Card),
		revisions : List(Card),
		diagnostics : List(Card),
		final_text : Str,
		original_text : Str,
		xml_parts : List(Str),
	}

	## The document written back: whether it reads as the same document, and
	## the written bytes as base64 for a download link.
	Written : { summary : Str, equivalent : Bool, base64 : Str }

	## Why a program could not read the document.
	Problem : [Unreadable(Str)]

	explore : Worker.Program(Wire.Bytes, Try(Explored, Problem))
	explore = Worker.fallible("roc-docx/playground/explore", |doc| Explore.explored(doc.to_list()))

	## The XML of one part as an indented outline.
	part_xml : Worker.Program({ doc : Wire.Bytes, part : Str }, Try(Str, Problem))
	part_xml = Worker.fallible("roc-docx/playground/part-xml", |{ doc, part }| Explore.outline(doc.to_list(), part))

	## Parse, write and parse again.
	round_trip : Worker.Program(Wire.Bytes, Try(Written, Problem))
	round_trip = Worker.fallible("roc-docx/playground/round-trip", |doc| Explore.written(doc.to_list()))

	explored : List(U8) -> Try(Explored, Problem)
	explored = |bytes| {
		parsed = Docx.parse(bytes) ? |e| Unreadable(Str.inspect(e))
		pkg = Opc.open(bytes, {}) ? |e| Unreadable(Str.inspect(e))
		document = parsed.document
		parts = Opc.parts(pkg)
		relationships = match Opc.main_document(pkg) {
			Ok(main) => Opc.relationships(pkg, main.name) ?? []
			Err(_) => []
		}
		blocks = Docx.body(document)
		comments = Docx.comments(document)
		revisions = Docx.revisions(document)
		diagnostics = parsed.diagnostics.map(Str.inspect).concat(comments.diagnostics.map(Str.inspect))
		Ok(
			{
				summary: Explore.summary(parts.len(), blocks.len(), comments.comments.len(), revisions.len(), diagnostics.len()),
				parts: Explore.cards(parts, |p| { title: p.name, detail: "${p.content_type} · ${p.size.to_str()} bytes", body: "" }),
				relationships: Explore.cards(relationships, |r| { title: "${r.id} → ${r.target}", detail: Explore.mode(r.mode), body: r.kind }),
				properties: Explore.cards(Explore.core(Docx.core_properties(document)), |(name, value)| { title: name, detail: value, body: "" }),
				blocks: Explore.cards(blocks, Explore.block),
				comments: Explore.cards(comments.comments, Explore.comment),
				revisions: Explore.cards(revisions, Explore.revision),
				diagnostics: Explore.cards(diagnostics, |d| { title: d, detail: "", body: "" }),
				final_text: Docx.final_text(document),
				original_text: Docx.original_text(document),
				xml_parts: parts.keep_if(|p| Explore.is_xml(p.content_type)).map(|p| p.name),
			},
		)
	}

	written : List(U8) -> Try(Written, Problem)
	written = |bytes| {
		parsed = Docx.parse(bytes) ? |e| Unreadable(Str.inspect(e))
		out = Docx.to_bytes(parsed.document) ? |e| Unreadable("writing failed: ${Str.inspect(e)}")
		again = Docx.parse(out) ? |e| Unreadable("the written document does not read: ${Str.inspect(e)}")
		equivalent = Docx.equivalent(parsed.document, again.document)
		verdict = if (equivalent) "reads as the same document" else "reads differently"
		Ok({ summary: "Written ${out.len().to_str()} bytes from ${bytes.len().to_str()}; it ${verdict}.", equivalent, base64: Base64.encode(out) })
	}

	outline : List(U8), Str -> Try(Str, Problem)
	outline = |bytes, part| {
		pkg = Opc.open(bytes, {}) ? |e| Unreadable(Str.inspect(e))
		xml = Opc.part_bytes(pkg, part) ? |e| Unreadable(Str.inspect(e))
		tree = XmlTree.parse(xml, {}) ? |e| Unreadable(Str.inspect(e))
		lines = Explore.lines(tree, 0, List.with_capacity(256))
		shown = lines.take_first(Explore.max_lines)
		more = if (lines.len() > Explore.max_lines) "\n… ${(lines.len() - Explore.max_lines).to_str()} more lines" else ""
		Ok(Str.join_with(shown, "\n").concat(more))
	}

	## The most lines of a part's outline the page shows.
	max_lines : U64
	max_lines = 4000

	lines : XmlTree.Node, U64, List(Str) -> List(Str)
	lines = |node, depth, out|
		if out.len() > Explore.max_lines {
			out
		} else {
			indent = Str.repeat("  ", depth)
			match node {
				Text(text) => {
					trimmed = text.trim()
					if (trimmed.is_empty()) out else List.append(out, "${indent}\"${trimmed}\"")
				}
				Element({ name, attributes, children, .. }) => {
					attrs = attributes.map(|a| " ${Explore.qname(a.name)}=\"${a.value}\"")
					children.fold(List.append(out, "${indent}<${Explore.qname(name)}${Str.join_with(attrs, "")}>"), |acc, child| Explore.lines(child, depth + 1, acc))
				}
			}
		}

	qname : XmlTree.Name -> Str
	qname = |name|
		match name.prefix {
			Prefix(p) => "${p}:${name.local}"
			Unprefixed => name.local
		}

	summary : U64, U64, U64, U64, U64 -> Str
	summary = |parts, blocks, comments, revisions, diagnostics|
		"${parts.to_str()} parts · ${blocks.to_str()} blocks · ${comments.to_str()} comments · ${revisions.to_str()} tracked changes · ${diagnostics.to_str()} diagnostics"

	cards : List(a), (a -> { title : Str, detail : Str, body : Str }) -> List(Card)
	cards = |items, card_of|
		items.map_with_index(
			|item, at| {
				c = card_of(item)
				{ key: at.to_str(), title: c.title, detail: c.detail, body: c.body }
			},
		)

	block : Document.Block -> { title : Str, detail : Str, body : Str }
	block = |b|
		match b {
			Paragraph(p) => {
				style = match p.properties.style {
					Style(s) => s
					Unset => ""
				}
				{ title: "Paragraph", detail: style, body: Document.paragraph_text(p) }
			}
			Table(t) => { title: "Table", detail: "${t.grid.len().to_str()} columns · ${t.content.len().to_str()} rows", body: "" }
			Section(_) => { title: "Section break", detail: "", body: "" }
			CommentStart(id) => { title: "Comment ${id.to_str()} begins", detail: "", body: "" }
			CommentEnd(id) => { title: "Comment ${id.to_str()} ends", detail: "", body: "" }
			Container({ element, content }) => { title: "Container", detail: Explore.element_name(element), body: "${content.len().to_str()} blocks" }
			Preserved(node) => { title: "Preserved", detail: Explore.element_name(node), body: "" }
		}

	element_name : XmlTree.Node -> Str
	element_name = |node|
		match node {
			Element({ name, .. }) => Explore.qname(name)
			Text(_) => "text"
		}

	comment : Comments.Anchored -> { title : Str, detail : Str, body : Str }
	comment = |{ id, comment: c, anchor }| {
		reply = match c.parent {
			Parent(p) => " · reply to ${p.to_str()}"
			Unset => ""
		}
		resolved = if (c.resolved) " · resolved" else ""
		on = match anchor {
			Range(text) => "on “${text}”"
			Point => "at a point"
			Unanchored => "unanchored"
		}
		said = Str.join_with(c.content.map(Explore.block_text), "\n")
		{ title: "[${id.to_str()}] ${c.author}${reply}${resolved}", detail: "${Explore.date(c.date)} · ${on}", body: said }
	}

	revision : Revisions.Listed -> { title : Str, detail : Str, body : Str }
	revision = |r| { title: "[${r.id.to_str()}] ${Str.inspect(r.kind)} of ${Str.inspect(r.of)}", detail: "${r.author} · ${Explore.date(r.date)}", body: r.text }

	date : [Unset, Date(Document.Timestamp)] -> Str
	date = |d|
		match d {
			Date(t) => t.written
			Unset => "undated"
		}

	block_text : Document.Block -> Str
	block_text = |b|
		match b {
			Paragraph(p) => Document.paragraph_text(p)
			_ => ""
		}

	mode : [Internal, External] -> Str
	mode = |m|
		match m {
			Internal => "internal"
			External => "external"
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
}

## A relationships part is XML by its content type.
expect Explore.is_xml("application/vnd.openxmlformats-package.relationships+xml")

## A prefixed name shows its prefix.
expect Explore.qname({ namespace: NoNamespace, local: "p", prefix: Prefix("w") }) == "w:p"
