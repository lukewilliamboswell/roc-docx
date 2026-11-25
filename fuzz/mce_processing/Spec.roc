import docx.Mce
import docx.XmlTree

Spec := [].{}

wordprocessingml : Str
wordprocessingml = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

declarations : Str
declarations = "xmlns:w='${wordprocessingml}' xmlns:mc='http://schemas.openxmlformats.org/markup-compatibility/2006' xmlns:x='urn:scope:outer'"

# Compare canonical markup since branch splicing carries the selected
# expanded names into a new location, without requiring their old prefixes.
output : Str -> Try({ bytes : List(U8), diagnostics : List(Mce.Diagnostic) }, _)
output = |source| {
	processed = Mce.process(XmlTree.parse(source.to_utf8(), {})?)
	Ok({ bytes: XmlTree.render(processed.interpreted)?, diagnostics: processed.diagnostics })
}

## ECMA-376 Part 3 §§7.5, 9.2 and 9.4. An ignored child of AlternateContent
## is allowed. Neither it nor an unselected branch imposes MustUnderstand.
## The second Choice's rebound prefix selects it and its own ProcessContent
## unwraps a child. A later sibling sees the outer binding again. Locations
## count the elements of every skipped subtree.
expect {
	source = Str.join_with(
		[
			"<w:r ${declarations} mc:Ignorable='x'>",
			"<mc:AlternateContent>",
			"<p:metadata xmlns:p='urn:scope:metadata' mc:Ignorable='p' mc:MustUnderstand='p absent' mc:ProcessContent='other:wrap'><w:t>metadata</w:t></p:metadata>",
			"<mc:Choice xmlns:x='urn:scope:rejected' Requires='x' mc:MustUnderstand='x'><w:t>rejected</w:t></mc:Choice>",
			"<mc:Choice xmlns:x='${wordprocessingml}' xmlns:p='urn:scope:chosen' Requires='  x&#x9;w&#xA;&#xD; ' mc:Ignorable='p' mc:ProcessContent='p:wrap' mc:MustUnderstand='p'>",
			"<p:wrap><w:t>chosen</w:t></p:wrap>",
			"</mc:Choice><mc:Fallback mc:MustUnderstand='x'><w:t>fallback</w:t></mc:Fallback>",
			"</mc:AlternateContent>",
			"<q:ignored xmlns:q='urn:scope:local' mc:MustUnderstand='q absent' mc:ProcessContent='broken:wrap' mc:Ignorable='q'><w:t>ignored</w:t></q:ignored>",
			"<w:t mc:MustUnderstand='x'>after</w:t>",
			"</w:r>",
		],
		"",
	)
	expected = "<w:r xmlns:w='${wordprocessingml}'><w:t>chosen</w:t><w:t>after</w:t></w:r>"
	result = output(source)?
	result.bytes == XmlTree.render(XmlTree.parse(expected.to_utf8(), {})?)?
		and result.diagnostics == [
			UnboundPrefix({ prefix: "other", at: { element: "p:metadata", position: 3 } }),
			RequiredExtension({ namespace: "urn:scope:chosen", at: { element: "mc:Choice", position: 7 } }),
			UnboundPrefix({ prefix: "broken", at: { element: "q:ignored", position: 12 } }),
			RequiredExtension({ namespace: "urn:scope:outer", at: { element: "w:t", position: 14 } }),
		]
}

## ECMA-376 Part 3 §9.4 item 3(a). AlternateContent rejects a non-branch
## child marked unwrapped by ProcessContent while selecting the Choice.
expect {
	source = "<w:r ${declarations} mc:Ignorable='x' mc:ProcessContent='x:wrap'><mc:AlternateContent><x:wrap><w:t>misplaced</w:t></x:wrap><mc:Choice Requires='w'><w:t>chosen</w:t></mc:Choice></mc:AlternateContent></w:r>"
	expected = "<w:r xmlns:w='${wordprocessingml}'><w:t>chosen</w:t></w:r>"
	result = output(source)?
	result.bytes == XmlTree.render(XmlTree.parse(expected.to_utf8(), {})?)?
		and result.diagnostics == [InvalidCompatibilityMarkup({ at: { element: "x:wrap", position: 3 } })]
}
