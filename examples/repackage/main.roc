app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.0/2yhxoR7cZPSYbyUzPWULFw8AA6QEcdsgFNRmzu7pZbst.tar.zst",
	docx: "../../package/main.roc",
}

import cli.File
import cli.OsStr
import cli.Path
import cli.Stdout
import docx.Opc

# Write a Word document's parts into a new package, one part at a time.
#
# `Opc.graph` reads the document's part graph: every part with its content
# type and the relationships from it. `Opc.writer` fixes the order of the new
# archive and generates `[Content_Types].xml` and the relationship parts from
# that graph. Each `Opc.add` then writes the next part and returns the next
# chunk of the archive, which goes straight to the file, so only one part is
# in memory at a time.
#
# `Copied(pkg)` copies a part's stored bytes unchanged, without decompressing
# them. To replace a part, give `Bytes(content)` for its name instead; it is
# compressed as it is written.
#
#     cd examples/repackage && roc main.roc                    # review.docx to repackaged.docx
#     cd examples/repackage && roc main.roc in.docx out.docx
main! : List([Utf8(Str), UnixBytes(List(U8)), WindowsU16s(List(U16))]) => Try({}, _)
main! = |args| {
	{ input, output } = match args {
		[from, to] => { input: Path.from_os_str(OsStr.from_raw(from)), output: Path.from_os_str(OsStr.from_raw(to)) }
		_ => { input: Path.utf8("review.docx"), output: Path.utf8("repackaged.docx") }
	}
	pkg = Opc.open(Path.read_bytes!(input)?, {})?
	started = Opc.writer(Opc.graph(pkg)?)?

	File.with_writer!(
		output,
		Truncate,
		{},
		|file| {
			var $writer = started
			for _name in Opc.pending(started) {
				added = Opc.add($writer, Copied(pkg))?
				file.write_bytes!(added.chunk)?
				$writer = added.writer
			}
			# The last chunk is the archive's directory of entries.
			file.write_bytes!(Opc.finish($writer)?)
		},
	)?

	# Open the new package to show the order its parts were written in, and
	# which hold exactly the bytes the original stored.
	written = Opc.open(Path.read_bytes!(output)?, {})?
	Stdout.line!("Wrote ${Path.display(output)}:")?
	for part in Opc.parts(written) {
		origin = if (Opc.stored(written, part.name) == Opc.stored(pkg, part.name)) "copied" else "generated"
		Stdout.line!("  ${part.name}  (${origin})")?
	}
	Ok({})
}
