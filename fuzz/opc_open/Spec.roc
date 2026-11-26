import docx.Docx
import docx.Document
import docx.Opc
import docx.XmlTree
import zip.Zip

Spec := [].{}

main_part = "/manuscript/body.xml"

main_type = "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"

main_xml = "<w:document xmlns:w='http://schemas.openxmlformats.org/wordprocessingml/2006/main'><w:body><w:p><w:r><w:t>Internal body</w:t></w:r></w:p></w:body></w:document>"

office_document = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"

external_target = "drafts/review.xml"

external : Opc.Relationship
external = { id: "rId1", kind: office_document, target: external_target, mode: External }

internal : Opc.Relationship
internal = { id: "rId2", kind: office_document, target: main_part, mode: Internal }

external_xml = "<Relationship Id='rId1' Type='${office_document}' Target='${external_target}' TargetMode='External'/>"

internal_xml = "<Relationship Id='rId2' Type='${office_document}' Target='manuscript/body.xml'/>"

expected_main : Opc.Part
expected_main = { name: main_part, content_type: main_type, size: main_xml.to_utf8().len() }

package_with = |relations|
	Zip.create(
		[
			{
				path: "[Content_Types].xml",
				content: "<Types xmlns='http://schemas.openxmlformats.org/package/2006/content-types'><Default Extension='rels' ContentType='application/vnd.openxmlformats-package.relationships+xml'/><Override PartName='${main_part}' ContentType='${main_type}'/></Types>".to_utf8(),
			},
			{
				path: "_rels/.rels",
				content: "<Relationships xmlns='http://schemas.openxmlformats.org/package/2006/relationships'>${relations}</Relationships>".to_utf8(),
			},
			{ path: "manuscript/body.xml", content: main_xml.to_utf8() },
		],
		None,
	)

## ECMA-376 Part 1 §11.3.10 requires the Main Document part to be inside
## the package. An external-only relationship remains in the part graph.
expect {
	bytes = package_with(external_xml)?
	pkg = Opc.open(bytes, {})?
	parsed = Docx.parse(bytes)?
	Opc.graph(pkg)?.relationships == [external]
		and Opc.main_document(pkg) == Err(NoMainDocument)
		and Docx.body(parsed.document).is_empty()
}

## An external relationship listed first cannot mask the internal main
## document. Both relationships retain their target, mode and order.
expect {
	bytes = package_with("${external_xml}${internal_xml}")?
	pkg = Opc.open(bytes, {})?
	parsed = Docx.parse(bytes)?
	Opc.relationships(pkg, "/")? == [external, internal]
		and Opc.main_document(pkg) == Ok(expected_main)
		and Docx.text(parsed.document) == "Internal body\n"
}

## A normal root relationship defaults to Internal and can name a main
## part at a producer-chosen path.
expect {
	bytes = package_with(internal_xml)?
	pkg = Opc.open(bytes, {})?
	Opc.relationships(pkg, "/")? == [internal]
		and Opc.main_document(pkg) == Ok(expected_main)
}

## ECMA-376 Part 2 §6.2.2.3 compares part names without ASCII case.
## A case-only spelling of a part already present cannot add a second part
## or a relationship, even when the requested source is the package root.
expect {
	parsed = Docx.parse(package_with(internal_xml)?)?
	original = Docx.to_bytes(parsed.document)?
	tree = XmlTree.parse("<note>New note</note>".to_utf8(), {})?
	attempt = Document.with_new_part(parsed.document, { source: "/", kind: "urn:review:note", name: "/Manuscript/BODY.XML", content_type: "application/xml" }, tree)
	Docx.to_bytes(attempt) == Ok(original)
}

## New parts keep their spelling and can be relationship sources before
## saving. A second spelling of a staged part and an absent source make
## no change. The root uses its first free relationship ID.
expect {
	parsed = Docx.parse(package_with(internal_xml)?)?
	index = "/manuscript/Index.xml"
	details = "/manuscript/details.xml"
	kind = "urn:review:note"
	tree = XmlTree.parse("<note>Review notes</note>".to_utf8(), {})?
	created = Document.with_new_part(parsed.document, { source: "/", kind, name: index, content_type: "application/xml" }, tree)
	linked = Document.with_new_part(created, { source: index, kind, name: details, content_type: "application/xml" }, tree)
	collision = Document.with_new_part(linked, { source: index, kind, name: "/MANUSCRIPT/index.XML", content_type: "application/xml" }, tree)
	missing = Document.with_new_part(collision, { source: "/manuscript/missing.xml", kind, name: "/manuscript/unlinked.xml", content_type: "application/xml" }, tree)
	bytes = Docx.to_bytes(linked)?
	reopened = Opc.open(bytes, {})?
	root_link = { id: "rId1", kind, target: index, mode: Internal }
	child_link = { id: "rId1", kind, target: details, mode: Internal }
	Docx.to_bytes(missing) == Ok(bytes)
		and Opc.relationships(reopened, "/")? == [internal, root_link]
		and Opc.relationships(reopened, index)? == [child_link]
		and (Opc.part(reopened, index)?).name == index
		and Str.from_utf8(Opc.part_bytes(reopened, details)?)?.ends_with("<note>Review notes</note>")
}
