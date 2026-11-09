# roc-docx

Read and write Word documents (`.docx`) in pure [Roc](https://www.roc-lang.org),
including their comments and tracked changes.

roc-docx is for applications that handle business documents: read what Word,
LibreOffice or Google Docs produced, change it without losing anything, and
generate new documents that open cleanly. It is under construction; the gates
in [implementation-plan.md](implementation-plan.md) say what is verified.

**Comments.** roc-docx reads the comments Word, LibreOffice, Google Docs and
pandoc write: each comment's author, date and content, the text it is anchored
to, and, where the document records them, its replies and whether its thread
is resolved. It writes them back with their threads, which LibreOffice reads
as the same comments, replies and resolution, and which Word for Mac opens
with its threads intact. It adds a comment over a span of the text, replies to
one, resolves a thread and removes a comment with its replies, leaving the
text unchanged; LibreOffice reads each edited document as edited. See
[Comments](docs/comments.adoc) in the manual.

- [The manual](docs/index.adoc), for application authors and contributors:
  what the package is, how to use it, the enduring
  [architecture](docs/architecture.adoc) and how to
  [contribute](docs/contributing.adoc).
- [implementation-plan.md](implementation-plan.md): the development plan
  until the first release, after which it is removed.
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
