## Read a Word document from its bytes and write it back.
##
## `Docx.parse` opens the package within the default `Limits` and reads it as
## a [Document]; `Docx.to_bytes` writes a document as a package. What reading
## drops comes back as diagnostics beside the document, never printed.
import Document
import Opc
import XmlTree

Docx :: [].{

	## Why bytes cannot be read as a document: the errors of [Opc.open] and of
	## [Document.from_package].
	ParseError : [
		InvalidSignature,
		TruncatedArchive,
		InvalidFilename,
		CompressionNotSupported(U16),
		CrcMismatch({ path : Str, expected : U32, actual : U32 }),
		InvalidCompressedData(Str),
		DuplicatePart(Str),
		PartSizeMismatch({ name : Str, declared : U64 }),
		TooManyEntries(U64),
		PartTooLarge({ name : Str, bytes : U64 }),
		PackageTooLarge(U64),
		MissingContentTypes,
		ContentTypesNotXml(XmlTree.ReadError),
		ContentTypesRootIsNotTypes,
		MissingAttribute(Opc.AttributeLocation),
		NoContentType(Str),
		MissingPart(Str),
		RelationshipsNotXml({ part : Str, problem : XmlTree.ReadError }),
		XmlPartUnreadable({ part : Str, problem : XmlTree.ReadError }),
	]

	## Read a document from the bytes of a `.docx`, with what reading dropped.
	parse : List(U8) -> Try({ document : Document, diagnostics : List(Document.Diagnostic) }, ParseError)
	parse = |bytes| Ok(Document.from_package(Opc.open(bytes, {})?, {})?)

	## Write a document as the bytes of a `.docx`. The same document always
	## gives the same bytes.
	to_bytes : Document -> Try(List(U8), Document.WriteError)
	to_bytes = |document| Document.to_bytes(document)
}
