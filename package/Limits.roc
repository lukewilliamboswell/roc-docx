## Resource bounds for reading untrusted packages.
##
## A document can be hostile: a small archive that inflates to gigabytes,
## thousands of parts, or XML nested thousands of elements deep. Every reader
## checks these bounds and fails with a named limit error rather than
## exhausting memory. The defaults are generous for
## business documents. `Opc.open(bytes, {})` takes them all;
## `Opc.open(bytes, { max_entries: 64 })` names only what differs.
Limits := {
	## Most ZIP entries a package may contain.
	max_entries : U64 ?? 4096,

	## Most bytes a part name may have, as the archive spells it. Word,
	## LibreOffice, Google Docs and pandoc write names of a few dozen bytes;
	## the ZIP format allows 65,535, so a name of more than a kilobyte is
	## refused before it is indexed, compared or resolved against.
	max_part_name_bytes : U64 ?? 1024,

	## Most decompressed bytes a single part may hold.
	max_part_bytes : U64 ?? 67_108_864,

	## Most decompressed bytes all parts may hold together, and the most bytes
	## an archive itself may have.
	max_total_bytes : U64 ?? 268_435_456,

	## Most elements an XML part may nest inside one another.
	max_xml_depth : U64 ?? 1024,

	## Most elements an XML part may contain.
	max_xml_elements : U64 ?? 4_194_304,

	## Most attributes, namespace declarations included, one XML element may carry.
	max_xml_attributes : U64 ?? 1024,
}

## The defaults keep a single part within the package total.
expect {
	limits : Limits
	limits = {}
	limits.max_part_bytes <= limits.max_total_bytes
}
