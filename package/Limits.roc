## Resource bounds for reading untrusted packages.
##
## A document can be hostile: a small archive that inflates to gigabytes, or
## thousands of parts. Every reader checks these bounds and fails with a named
## limit error rather than exhausting memory. The defaults are generous for
## business documents. `Opc.open(bytes, {})` takes them all;
## `Opc.open(bytes, { max_entries: 64 })` names only what differs.
Limits := {
	## Most ZIP entries a package may contain.
	max_entries : U64 ?? 4096,

	## Most decompressed bytes a single part may hold.
	max_part_bytes : U64 ?? 67_108_864,

	## Most decompressed bytes all parts may hold together, and the most bytes
	## an archive itself may have.
	max_total_bytes : U64 ?? 268_435_456,
}

## The defaults keep a single part within the package total.
expect {
	limits : Limits
	limits = {}
	limits.max_part_bytes <= limits.max_total_bytes
}
