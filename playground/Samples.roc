import "../tests/fixtures/word/revisions.docx" as revisions : List(U8)
import "../tests/fixtures/word/comments.docx" as comments : List(U8)
import "../tests/fixtures/word/tables.docx" as tables : List(U8)
import "../tests/fixtures/gdocs/resume.docx" as resume : List(U8)

## Documents to explore without one of your own: fixtures from the test
## corpus, each written for it by the producer it names, with fictional
## people (see `tests/fixtures/provenance.json`).
Samples := [].{

	Sample : { key : Str, title : Str, producer : Str, about : Str, file : Str, bytes : List(U8) }

	all : List(Sample)
	all = [
		{ key: "revisions", title: "Tracked changes", producer: "Microsoft Word", about: "Tracked insertions, deletions and moves by several reviewers.", file: "revisions.docx", bytes: revisions },
		{ key: "comments", title: "Comment threads", producer: "Microsoft Word", about: "Comments by several authors, anchored to the text they discuss.", file: "comments.docx", bytes: comments },
		{ key: "tables", title: "Tables", producer: "Microsoft Word", about: "Tables, their rows and their cells.", file: "tables.docx", bytes: tables },
		{ key: "resume", title: "Résumé", producer: "Google Docs", about: "A Google Docs export with two comments and the markup Google Docs writes.", file: "resume.docx", bytes: resume },
	]

	find : Str -> Try(Sample, [NotFound])
	find = |key| Samples.all.find_first(|s| s.key == key)
}

## Every sample is a ZIP archive.
expect Samples.all.all(|s| s.bytes.take_first(2) == ['P', 'K'])
