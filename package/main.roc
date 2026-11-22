## Read and write Word documents (`.docx`) in pure Roc: their text,
## structure, formatting, comments and tracked changes.
##
## [Docx] is where an application starts: it parses a document, answers
## queries about it, edits its comments, tracked changes and text, and writes
## it back. [Build] and [Kit] make new documents, [Document] is the model the
## queries give, and [Limits] bounds what an untrusted document may consume.
package
	[Build, Comments, Document, Docx, Kit, Lenient, Limits, Mce, Numbering, Opc, Revisions, Snapshot, Styles, WmlRead, WmlWrite, XmlTree]
	{
		parser: "https://github.com/lukewilliamboswell/roc-parser/releases/download/6.0.0-rc.3.1/BBUDV8ak5oBCYRjWbQ3zNDBjXFVZydTdMPswovVkMUsT.tar.zst",
		zip: "https://github.com/lukewilliamboswell/roc-zip/releases/download/0.3.0-rc3/8Cpaf9qGq5aA38zeGsUG91Bmk8u5pbcV9jnYUZv7d4RD.tar.zst",
	}
