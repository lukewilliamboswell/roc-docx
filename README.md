# roc-docx

Read and write Word documents (`.docx`) in pure [Roc](https://www.roc-lang.org),
including their comments and tracked changes.

roc-docx is for applications that handle business documents: read what Word,
LibreOffice or Google Docs produced, change it without losing anything, and
generate new documents that open cleanly. Each capability below is claimed
because the tests, the oracles and the fuzz targets in this repository check it.

**Comments.** roc-docx reads the comments Word, LibreOffice, Google Docs and
pandoc write: each comment's author, date and content, the text it is anchored
to, and, where the document records them, its replies and whether its thread
is resolved. It writes them back with their threads, which LibreOffice reads
as the same comments, replies and resolution, and which Word for Mac opens
with its threads intact. It adds a comment over a span of the text, replies to
one, resolves a thread and removes a comment with its replies, leaving the
text unchanged; LibreOffice reads each edited document as edited. See
[Comments](docs/comments.adoc) in the manual.

**Tracked changes.** roc-docx reads the tracked changes in a document's
body: inserted, deleted and moved text, inserted, deleted and moved paragraph
marks, changed formatting of text, paragraphs, sections, tables, rows and
cells, and inserted, deleted and merged rows and cells, each with its author
and date, and gives the text as it would read with every change accepted or
every change rejected. It agrees with LibreOffice and pandoc on the changes
in the documents Word, LibreOffice and pandoc write, apart from recorded
differences. It writes every kind back schema-valid: LibreOffice reads the
written changes it lists as the same changes, and Word for Mac opens and
saves the written documents with every kind kept. It accepts or rejects
every change, an author's or those made in a period, in the body, notes,
headers, footers and comments, or chosen changes of the body, and, silently
or as tracked changes by a named author, replaces, inserts and deletes
text, across paragraphs too, and inserts and deletes paragraphs and tables;
LibreOffice reads the edited documents as the package does, and Word for
Mac's *Accept All* and *Reject All* give the same text as the package on the
documents it was tried on. See [Tracked changes](docs/tracked-changes.adoc) in the manual.

**Generating.** roc-docx makes new documents from a default kit of styles,
lists and properties: paragraphs, formatted text, lists, tables, links,
footnotes, headers and footers with page numbers, page setups, section breaks
and properties. Every generated document validates against the schemas and
LibreOffice reads it as the package built it; Word for Mac opens the example
gallery's letter, agreement, minutes and report without repair. Building a
long document a paragraph, footnote or chapter at a time costs a constant
number of allocations a call. See [Generate a document](docs/generating.adoc)
in the manual.

- [The documentation site](https://lukewilliamboswell.github.io/roc-docx/):
  the latest release's package URL, examples and API reference.
- [The browser playground](https://lukewilliamboswell.github.io/roc-docx/playground/):
  explore a document, review comments and tracked changes, or generate a letter locally in your browser.
- [The manual](docs/index.adoc), for application authors and contributors:
  what the package is, how to use it, the enduring
  [architecture](docs/architecture.adoc) and how to
  [contribute](docs/contributing.adoc).
- [AGENTS.md](AGENTS.md): the principles everyone changing this repository
  follows.

## Develop

Install [`blueprint`](https://lukewilliamboswell.github.io/roc-blueprint/getting-started.html)
and put the latest Roc nightly on your `PATH` as `roc`. Then:

```sh
blueprint run check      # everything a pull request must pass
blueprint tasks          # each check on its own, and the fixture and release tasks
```

The first run fetches and verifies the ECMA-376 schemas named in
`conformance/ledger.json`. The schema oracle needs `xmllint` (libxml2) and
`python3` on the machine; `pandoc` and the repository's fixed tooling are
fetched by Blueprint. The LibreOffice lane finds `soffice` through `SOFFICE`
or `PATH`.

[Universal Permissive License](LICENSE)
