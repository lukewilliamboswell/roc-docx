app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
	docx: "../../package/main.roc",
}

import cli.OsStr
import cli.Path
import cli.Stdout
import docx.Opc

# List the parts of a Word document, then the relationships of its main part.
#
# A .docx is a ZIP package of XML parts. `Opc.open` reads the package within
# the default resource limits and labels every part with its content type and
# size without inflating it; `Opc.main_document` follows the package's
# officeDocument relationship to the WordprocessingML body, wherever the
# producer put it.
#
#     cd examples/inspect && roc main.roc            # inspects review.docx beside this file
#     cd examples/inspect && roc main.roc other.docx
main! : List(OsStr) => Try({}, _)
main! = |args| {
	file = match args.first() {
		Ok(path) => Path.from_os_str(path)
		Err(_) => Path.utf8("review.docx")
	}
	bytes = Path.read_bytes!(file)?
	pkg = Opc.open(bytes, {})?

	Stdout.line!("Parts of ${Path.display(file)}:")?
	for part in Opc.parts(pkg) {
		Stdout.line!("  ${part.name}  (${part.content_type}, ${part.size.to_str()} bytes)")?
	}

	document = Opc.main_document(pkg)?
	Stdout.line!("\nMain document: ${document.name}")?
	for rel in Opc.relationships(pkg, document.name)? {
		Stdout.line!("  ${rel.id}  ${rel.kind}  ${rel.target}")?
	}
	Ok({})
}
