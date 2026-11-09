# roc-docx implementation plan

This plan turns the [architecture](docs/architecture.adoc) into ordered,
checkable work. It is the living document: slices are added, split and closed
here, and every pull request that completes a slice updates its status in the
same change. The architecture changes only when a requirement changes; this
plan changes whenever the work does.

**This file is development scaffolding.** It exists to coordinate the work up
to the first release and is deleted in the release pull request (G6.3).
Anything in it that must outlive the release, such as a decision or a
verified fact, is moved into the manual under `docs/` or into
`conformance/ledger.json` before then. Nothing in the manual links here.

## How the plan works

Work is organised in **gates**. A gate is a capability boundary with exit
criteria that are observable in CI; gates are dependency-ordered, not
scheduled. Inside a gate, **slices** are units of work small enough for one
pull request and one reviewer, each with a deliverable and the evidence that
closes it.

Status markers: `[ ]` not started, `[~]` in progress (link the PR), `[x]`
closed (link the merged PR). A slice is closed when all of the following hold:

- The code, tests, fixtures and documentation named in the slice are merged.
- `blueprint run check` and the LibreOffice lane are green on the merged
  commit.
- No new skipped test, accepted deviation or dropped-class rule was added
  without an issue link and a one-line cause.
- The pull request description records the evidence: the commands run and
  what they reported, and for oracle work the fixture inventory covered.
- Any claim the slice enables is stated in the user documentation only if
  this plan marks its gate evidence complete.

A capability is **claimed** (in the README, manual or release notes) only when
its gate's exit criteria are met. Partial implementations are described as
such or not at all.

## Working model for agents

Development is done by coding agents coordinated by the maintainer. The rules
that keep that safe:

- **Branches.** `main` is release quality and protected. `integration` is the
  landing branch for slices and carries the same required checks. An agent
  works on `agent/<slice-id>-<short-name>` and opens a pull request into
  `integration`. The maintainer merges `integration` into `main` at gate
  boundaries or when a release is cut. Agent pull requests are squash-merged;
  GitHub signs the resulting commit, which satisfies signed-commit rules on
  the protected branches without agents holding keys.
- **One slice per pull request.** A pull request implements one slice from
  this plan, names it in the title, and does nothing else. Refactors that a
  slice needs are part of that slice; refactors it does not need are a
  separate slice proposed here first.
- **Read before writing.** `AGENTS.md`, `docs/architecture.adoc`, the gate the slice
  belongs to, and the roc-automation manual chapters the slice touches.
- **Evidence in the description.** The pull request body has four parts:
  *Slice* (the identifier and deliverable), *Change* (what was built, in
  prose), *Evidence* (commands and their results, including oracle lane
  summaries and fuzz `check` output), *Follow-ups* (anything discovered and
  deliberately not done, each as an issue).
- **Stop and ask** before: changing `docs/architecture.adoc`; adding or upgrading a
  dependency; adding an accepted oracle deviation; adding a dropped-class
  rule; skipping a test; adding a tool to `Blueprint.roc`; or when a slice
  turns out to need more than one pull request. Open a draft pull request or
  an issue with the question and the recommendation.
- **Ratchets, not baselines.** Allocation ceilings live in the fuzz target's
  source and only move down. A slice that needs a higher ceiling records the
  cause in the pull request beside the new value. Snapshot and fixture updates
  are reviewed as diffs; CI never updates them.
- **Pull-request CI stays lean.** `check`, the LibreOffice lane and the manual
  build, and nothing heavier. No sustained fuzz campaigns and no benchmarks;
  if either is wanted later it is separate scheduled work, proposed here
  first.
- **Mechanical before guidance.** When a rule can be checked, add it to
  `scripts/src/Lint.roc` with its `expect`s in the same slice rather than
  writing it down for people to remember.
- **The manual moves with the code.** A slice that changes behaviour an
  application author or contributor can see updates the chapter in `docs/`
  in the same pull request.

## Verified baseline (2026-11-09)

These facts were established by running the tools; they are the starting
conditions of Gate 0 and are superseded by the ledger and the lock once those
exist.

| Item | Observation |
| --- | --- |
| Roc compiler | Latest nightly `nightly-2026-11-07-ad3a5d2` builds and runs everything below; CI uses the latest nightly through `roc-lang/setup-roc` |
| `roc-zip` 0.2.2, `roc-parser` 4.0.0 | The pins of the first kernel; they compile together on that nightly. `roc-xml` 2.0.5 was pinned beside them but never imported, and was removed once roc-parser gained a renderer |
| Release candidates | `roc-zip` 0.3.0-rc1 (bundle `3vvx2cPVp1vjjVgrXcugJqqfrp55ZrURYQUcSArAUHdr`, 21,277 bytes), `roc-deflate` 0.6.0-rc1 (`2VEuxTntQvoRYzwwhGU22yHUiiC3cAgR1XyKajLw2Gpy`, 68,370 bytes) and `roc-parser` 6.0.0-rc.1 (`73WRCGdN4doPdfzqKAHBkwKQksAxmtoAr4Fu3dzDMvTC`, 412,899 bytes) were built by the maintainer with the same nightly; roc-zip pins roc-deflate itself. A probe package depending on all three passes ten `roc test` expectations on that nightly: `Zip.entries` indexes an archive without inflating; `Zip.extract_entry` returns `EntryTooLarge` for a bound below the declared size and the content within it; the writer's chunks equal `Zip.create`; entries copied with `Zip.compressed` rebuild a byte-identical archive; `XmlNs.parse_str` resolves a `w:` document and `XmlNs.render` reproduces its source; `Xml.reader` reports one start per element; `Xml.parse` fails a two-element budget with `LimitExceeded`; `Deflate.decompress` stops at `max_output` and pre-sizes from `Declared` |
| Kernel against the candidates | `package/` fails to compile against them only because `Zip.extract` and `Zip.create` now return `DuplicatePath`, `EntryTooLarge` and `SizeMismatch`, which `OpenError` and `sample_archive` do not list; G1.1a adds the arms |
| `basic-cli` | 0.26.0 fails on that nightly (16 type errors in the platform); 0.27.0 (released 2026-11-07, requires nightly ≥ 2026-11-06) passes. Examples and scripts use 0.27.0 |
| `roc-fuzz` 0.5.0 | Bundle `9WT86CuwM7ZJBSs8iTd1jLyrUFTTiGp5hcJE63TwswGE.tar.zst`, SHA-256 `aed4032105af1cc910604949f43636b7bff6aec4a82184631213153b8e2dd23f`, 2,242,328 bytes; `roc build --fuzz` and `check`/`run` work on the nightly |
| Error vocabulary | In the candidates, roc-zip's `ExtractError` and `CreateError` share `DuplicatePath(Str)`, and roc-parser's `Xml.ReadError` and `XmlNs.ReadError` share `InvalidXml` and `LimitExceeded`; the package maps every dependency error to its own vocabulary at the boundary, as the architecture requires |
| ECMA-376 schemas | Part 4 Transitional XSDs compile in `xmllint` once a wrapper schema imports the W3C `xml.xsd`; validating a part takes about 40 ms. Digests are in the ledger |
| pandoc 3.9.0.2 | Writes `w:ins`, `w:del`, `w:delText`, comment ranges and `comments.xml`; reads them back with `--track-changes=all`; its parts validate against the schema; output is byte-identical under `SOURCE_DATE_EPOCH` |
| LibreOffice 26.2.3 | Headless conversion to Flat ODT preserves tracked changes and annotations with creators; `.docx` round trip keeps `w:ins`, `w:del` and comments; its parts validate only after MCE preprocessing (`mc:Ignorable`) |
| Word and Google Docs output | A Google Docs export uses `w14:paraId` without declaring it ignorable and omits the required `w:gutter` on `w:pgMar`; both must be accepted on read and neither is produced on write |
| Blueprint | CLI 0.8.0 installed locally; platform 0.8.0 is what roc-automation's example and roc-pdf use; 0.11.0 is the latest release |
| roc-automation | `main` at `8f0bb2254540fcdd746bdb4ed10851b4c34c8203`; shared tools release `tools-0.10.0` provides `release-package` and `roc-docs` for Linux and Apple Silicon |
| Repository | `lukewilliamboswell/roc-docx` exists on GitHub, public, empty, no licence, no rulesets |
| Check task | `blueprint run check` completes locally in about half a minute; the fuzz target build takes 22 s and schema validation of 180 parts takes 5 s |
| First ratchet | `Opc.open` on the minimal package: 60 allocations, 7 reallocations, 14,395 bytes peak live, 44,291 bytes requested, mostly the ZIP layer's decode tables; ceiling set at 67 allocations and reallocations |
| Streaming analysis | Against the first kernel's pins: roc-deflate is a whole-buffer port (no incremental inflate or compress); `roc-zip` had no entry index or single-entry extraction and `Zip.create` needed every entry at once; roc-parser's tree parser was already an explicit-stack event loop. The release candidates close every gap except incremental DEFLATE, which the architecture rejects. Every LibreOffice fixture entry uses a data descriptor, pandoc's none; corpus parts decompress 5.5 to 7.9 times |

## Gate 0: scaffold, oracles and test infrastructure

**Goal.** A repository in which a slice can be developed with confidence
before any WordprocessingML code exists: pinned tooling, provisioned and
verified oracles, a fixture corpus with provenance, a snapshot contract that
two independent oracles already agree on, and CI that runs it all.

| Slice | Deliverable | Evidence |
| --- | --- | --- |
| `[x]` G0.1 Repository scaffold | `LICENSE` (UPL-1.0), `README.md`, `.gitignore`, `.gitattributes`, `SECURITY.md`, `AGENTS.md`, `architecture.md`, this plan, `Blueprint.roc` and `Blueprint.lock`, `conformance/ledger.json` | `blueprint check` and `blueprint update` succeed; the lock names every fetched tool for both systems |
| `[x]` G0.2 Schema oracle | `oracle/provision.py` fetches ECMA-376 Parts 2 and 4, the W3C `xml.xsd` and the Dublin Core schemas by URL (Parts 1 and 3 with `--all`), verifies the ledger digests and sizes, unpacks the Transitional and OPC schemas and writes the wrapper schemas and XML catalog under `.roc-docx/oracle/`; `oracle/mce_strip.py` implements Part 3 removal of ignorable content and alternate-content selection; `oracle/validate_schema.py` validates every XML part of a `.docx` or directory against the schema its root namespace selects, after MCE preprocessing or raw with `--raw`, consults the accepted deviations and reports per part | All 180 parts of the 14 fixtures validate after preprocessing; raw validation fails exactly the 19 LibreOffice parts that carry `mc:Ignorable`; a deliberately misordered `w:rPr` fails with the schema's message and a nonzero exit; a maintainer's Google Docs export showed the undeclared `w14:paraId` and missing `w:gutter` deviations the reader must accept |
| `[~]` G0.3 Fixture corpus v1 | `tests/fixtures/sources/*.md` pandoc sources covering headings, inline formatting, lists, tables, links, footnotes, comments, insertions and deletions; `oracle/make_fixtures.py` regenerates them with `SOURCE_DATE_EPOCH`; a check fails when a committed fixture differs from regeneration; LibreOffice round-trip fixtures and maintainer-produced Word and Google Docs fixtures committed with `tests/fixtures/provenance.json` | Regeneration is byte-stable; every fixture has a provenance entry; no third-party content. Done: seven pandoc and seven LibreOffice fixtures with provenance, all 180 parts schema-valid. Word fixtures by G0.3b. Open: a Google Docs export, which only the maintainer can produce (no local means) |
| `[x]` G0.3b Word fixtures produced by scripted Word | `oracle/make_word_fixtures.py` (macOS, maintainer-run, not in `check` or CI) writes seed packages with fictional authors, has Microsoft Word open and save each through AppleScript, checks every seeded construct survived and no part names the machine's user or account, and replaces only Word's account-stamped `cp:lastModifiedBy`, copying every other entry's stored bytes; `tests/fixtures/word/` with provenance; the contributing chapter says how to run it | Done: Word 16.114.4 wrote `comments` (a comment with two replies, a resolved thread, a rangeless comment, which Word writes as an empty range, a two-paragraph comment; all five comment parts), `revisions` (run insertion and deletion, a move with range markers, paragraph-mark insertion and deletion, run, paragraph, section, row and cell property changes, row insertion and deletion, cell insertion, deletion and merge revisions, a deleted field instruction, `trackRevisions`), `tables` (header row, shading, vertical and horizontal merges, a nested table) and `report` (headers and footers with PAGE and NUMPAGES over two sections, footnote, endnote, external and internal links, bookmark, two-level lists, an inline PNG). Word drops a seeded `tblPrChange` wherever it stands and writes its own `tblPrExChange` and `tblGridChange` for the cell revisions. Every part of every fixture was searched for the user's names, login, home directory and `@`: none. 48 parts PASS, 5 UNSCHEMED; four pass-through expectations; the pandoc adapter now follows nested comment ends, covers row-spanned cells and joins a paragraph whose mark is deleted, and the LibreOffice adapter restores the order of comments that start together, reads `UnknownChange` as a format change, field results and comment initials; `blueprint run libreoffice`: 36 snapshots, 14 agree, 12 accepted (four new pandoc deviations with causes), 0 fail; 18 written documents agree |
| `[x]` G0.4 Snapshot contract and adapters | `oracle/snapshot_schema.json` (`roc-docx-snapshot/1`); `oracle/snapshot_pandoc.py` from pandoc JSON; `oracle/snapshot_libreoffice.py` from Flat ODT; `oracle/compare_snapshots.py` comparing declared-key intersections and consulting `conformance/accepted-deviations.json` | pandoc and LibreOffice snapshots agree on every fixture for their common keys, before any Roc parser exists; disagreements are either adapter bugs fixed or deviations recorded with causes. Done: the contract with every field always present and `keys` naming what each reader is authoritative for (pandoc: blocks, runs, note text, comments without threads or resolution, revisions; LibreOffice: those plus note kinds, resolution, sections and four core properties); `blueprint run libreoffice` on LibreOffice 26.2.3.2 and pandoc 3.9.0.2: 14 pairs, 12 agree, 2 agree apart from one accepted pandoc deviation (note text loses the space after the reference mark), 0 fail; check runs the pandoc lane as `oracle-snapshot`; a tampered run, an invalid snapshot and a CR LF edit each fail, a date in another zone compares equal |
| `[~]` G0.5 CI and repository settings | `.github/workflows/ci.yml` (the `check` task and the `docs` build, later a `libreoffice` job) and `release.yml` as the thin caller of the shared release workflow with `check-task: check`; rulesets on `main` and `integration` per the roc-automation settings chapter; `integration` branch created | A failing check blocks a test pull request; the release dry run passes; the settings are confirmed against the manual. Done: both workflows, pinned to roc-automation `8f0bb225`; on the first pull request `check`, `docs` and the release dry run including the release-candidate test all pass on the Linux runner. The `libreoffice` job installs Ubuntu's `libreoffice-writer` and runs `blueprint run libreoffice`, which prints the version it compared against. Open: the `integration` branch, rulesets and the `release` environment (maintainer), and the `libreoffice` job's first green run in CI |
| `[x]` G0.6 Check task and fuzz smoke driver | `blueprint run check` runs `scripts/check_all.roc`: schema provisioning, `roc fmt --check`, `roc-stable fmt --check scripts`, the lint, the lint module's tests, `roc test package/main.roc`, `release-package test-examples`, `scripts/fuzz_smoke.roc` (build each `fuzz/*/main.roc`, run its examples and ceilings, explore for one second and 64 inputs), the fixture regeneration check and `oracle/validate_schema.py` over the fixtures. The shared release workflow runs the same task | Green locally with G1.1 present. A deliberately invalid part and a tampered fixture each fail their check; the same ten checks pass in CI on Linux. The pandoc snapshot lane joined as `oracle-snapshot` with G0.4. Open: validating example outputs |
| `[x]` G0.7 Mechanical checks | `scripts/src/Lint.roc` (pure rules with `expect`s) and `scripts/lint.roc`: compiler pin only in scripts and equal to the tooling compiler; relative package paths in examples and fuzz targets; one release URL per dependency; no `crash` in `package/`; no `dbg`; every fuzz target has examples and a measurement or ceiling; `TODO`s name issues; every package `expect` has a doc comment; manual chapters titled and included; `.docx` files outside the corpus identical to a fixture | Every rule has a positive and a negative `expect`; the lint passes on the tree and runs in `check` |
| `[x]` G0.8 Manual skeleton | `docs/index.adoc` with chapters: what roc-docx is, read the parts of a document, the architecture (moved from the repository root) and contributing. Rendered by the shared renderer in the `docs` task and a CI job | `blueprint run docs` renders without warnings; the lint confirms every chapter is included |

**Exit.** `blueprint run check`, the LibreOffice job and the manual build are
required checks and green; the oracle adapters agree with each other on the
corpus; a contributor can run every lane locally with the commands in the
manual's contributing chapter.

## Gate 1: container and XML kernel

**Goal.** Read any `.docx` into parts and namespaced XML trees, write it back
with everything preserved, and prove both with fuzzing and the oracles.

| Slice | Deliverable | Evidence |
| --- | --- | --- |
| `[x]` G1.1 OPC reader | `Limits` and `Opc.open`/`open_with`: entries within limits, content types (defaults and overrides), relationships per source part with target resolution, main document by relationship type, unknown parts as bytes; `examples/inspect` lists a document's parts and main-part relationships; `fuzz/opc_open` is the OPC-stage form of the `parse_never_crashes` property (any bytes open to `Ok` or `Err`, deterministically, with labelled parts). The error vocabulary module arrives with the dependency error mapping in G1.3 | 19 `expect`s pass; the example's output is recorded in `tests/spec.json`; the target's `check` passes with examples for empty bytes, a bare ZIP signature and a minimal package, and a 500-input exploration accepts 405. Open: an example per fixture needs `Fuzz.saved` witnesses, which the smoke budget does not yet cover |
| `[x]` G1.1a Adopt the release candidates | Pin `roc-zip` 0.3.0-rc1 (which pins `roc-deflate` 0.6.0-rc1 itself) and `roc-parser` 6.0.0-rc.1 in `package/main.roc` and `fuzz/opc_open`; give the new `Zip.extract` and `Zip.create` tags their arms in `OpenError` and `sample_archive`, in the package's words: `DuplicatePart(Str)`, the existing `PartTooLarge` and `PartSizeMismatch({ name, declared })`; nothing else changes | `blueprint run check` green on the current nightly; `tests/spec.json` unchanged; the `opc_open` ceilings hold or move down, with the measured figures in the pull request. The upgrade is a stop-and-ask item that the maintainer has already decided by publishing the candidates for this purpose. Done: Opc needed no roc-parser change; `EntryTooLarge`, which `Zip.extract` never returns, maps to `PartTooLarge` with the declared size. The minimal package now takes 52 allocations, 5 reallocations and 14,930 bytes peak live (was 59, 7 and 14,395 on the same input), and its ceiling moves down from 67 to 57 |
| `[x]` G1.1b Bounded open | `Opc.open` reads the central directory with `Zip.entries`, checks the entry count, each declared size and the declared total against `Limits` before inflating anything, rejects part names that differ only in ASCII case (roc-zip already rejects byte-equal duplicates), and keeps the archive bytes with an index of parts by name instead of their inflated contents (today lookups are linear and content-type resolution is parts times overrides). `[Content_Types].xml` and the relationship parts are inflated at open with `Zip.extract_entry` under the part limit; every other part is inflated on demand by `Opc.part_bytes`, into a buffer sized from its checked declared size and stopping there; `Opc.stored` gives a part's stored bytes with method, CRC and sizes in the package's own record, for the writer. `fuzz/opc_open` gains declared examples, with lowered limits, for a compression bomb that declares its true size, one that lies about its size, and a highly compressible legitimate package; its memory ceiling becomes a constant plus multiples of the archive size and the `[Content_Types].xml` size rather than of the inflated total | The truthful bomb fails with `PartTooLarge` before anything is allocated for it and the lying one with `PartSizeMismatch` at its declared size, and in both the measured peak live bytes stay within the archive size plus the part limit; the compressible example passes; `Opc.open` documents its order of checks, and the docstring's admission that limits are checked after inflation is gone. Done: `Package` is opaque (archive, parts with their entries, a name index), read through `Opc.parts`, `part`, `part_bytes` and `stored`; `Part` carries the declared `size` instead of bytes, and `tests/spec.json` is unchanged. Case-equal names are `DuplicatePart`. Under limits of 65,536 bytes per part and 1 MiB in total, the truthful bomb (1 MiB of zeros in a 1,900-byte archive) is refused in 3 allocations at 2,252 bytes peak; the lying one (declaring 4,096) opens and its read fails at 20,445 bytes peak; the compressible package (58 KB in 1,033 bytes) opens in 51 allocations and 5 reallocations and reads its document at 73,595 bytes peak. The minimal package opens in 51 and 5 at 15,555 bytes peak (was 52 and 5 at 14,930, inflating every part); its ceiling moves down from 57 to 56. Part reads are bounded by 16 KiB plus the declared size beyond what was live |
| `[x]` G1.2 OPC writer | `Opc.Writer` over `Zip.writer`, `Zip.add` and `Zip.finish`: one part at a time (`writer`, `add`, `finish`) emitting chunks, with `Opc.to_bytes` defined as a loop over it; fixed part order; generated parts compressed at one fixed level; parts read from an archive written from their stored bytes with `Copied`, so method, CRC and sizes are unchanged and nothing is recompressed; no data descriptors and zeroed timestamps, which roc-zip guarantees; content types and relationships generated from the part graph; `fuzz/zip_opc_roundtrip` | Written `[Content_Types].xml` and `.rels` parts validate against the OPC schemas; concatenated chunks equal `to_bytes`; a package opened and written unchanged is byte-identical in its preserved parts; writing twice gives identical bytes; the round-trip target's ceilings bound the peak by the largest part, not by the archive. Done: `Opc.graph` reads an opened package's part graph (`Graph`, `GraphPart`); `Opc.writer` checks the graph and fixes the order, `pending`, `add` with `Bytes` or `Copied(pkg)` and `finish` emit the chunks, and `to_bytes` loops over them; generated parts use `Balanced`. A relationship part with no relationships or no source part stays an ordinary part and is copied. `examples/repackage` writes its fixture part by part and reports each part as copied or generated in `tests/spec.json`. Every fixture repackaged validates (180 parts PASS), writes back byte-identical, and gives LibreOffice snapshots identical to the originals'. `fuzz/zip_opc_roundtrip` round-trips generated part sets and opened packages; the chunked writer takes 212 allocations for the small package and 695 for the large one (12 more copied parts), `to_bytes` 213 and 698, and holds about 288 KiB beyond what was live, one DEFLATE compressor's state, whatever the archive size; an 8,000-input exploration passes. CI validates written packages through the G1.5 cases |
| `[x]` G1.3 Namespaced XML | The XML boundary on roc-parser's `XmlNs`: `Limits` gains the XML depth, element and attribute bounds and passes them as `Xml.ReaderProps`; a part parses to an `XmlNs` tree or to the package's located error, mapped from `InvalidXml`, `LimitExceeded` and `InvalidNamespace`; the canonical prefix table is the `Table` given to `XmlNs.render`, with `SortedBy` fixing attribute order where the architecture's canonical form needs it; `fuzz/xml_namespace_roundtrip` round-trips generated namespaced trees through the renderer and the reader. The pull-reader question is settled: `XmlNs.reader` has `next` and `element` (`element_with` exists only on the unresolved `Xml.Reader`), so Gate 2 reads the body one block at a time with no raw tree beside the namespaced one. roc-parser holds its text decoding linear with its own `xml-ceilings` target; this slice measures the `xml-tree` region on OOXML parts rather than assuming it | Every XML part of every fixture resolves without error; generated trees round-trip under the architecture's equivalence; the ceiling is a stated multiple of the part's bytes with a two-size pair, and the pull request records `XmlNs.parse_str` against `Xml.parse_str` on the largest fixture part. Done: `package/XmlTree.roc` (the dependency's module name is taken), with its own `Node`, names and errors (`MalformedXml`, `NamespaceError`, `XmlTooDeep`, `TooManyXmlElements`, `TooManyXmlAttributes`, `XmlNotUtf8`; `XmlUnwritable` on write), so no roc-parser type is public; `parse` builds the tree from `XmlNs.reader` events in one pass and `render` converts to `XmlNs.Node` for `XmlNs.render` with `Table`; attributes keep the order given, which the WordprocessingML writer fixes per element, so `SortedBy` is not used; content-types, relationships and properties parts keep their namespace as the default. Errors stay in the module that raises them, as in `Opc`, rather than in a separate `Error` module. `fuzz/xml_namespace_roundtrip` checks generated trees and, as declared examples, every XML part of all 14 fixtures (read, write, read back, write again byte-identical); ceilings `64 + 2n` allocations and `16 KiB + 320n` bytes beyond the input per read or write of an `n`-byte part (dense generated trees reach 286 times; real parts 13), exact per-example ceilings, small/large pair 233 and 2,470. On the 27,124-byte pandoc `styles.xml`: `Xml.parse_str` 1,108 allocations and reallocations, 171,912 bytes peak; `XmlNs.parse_str` 1,612 and 352,576; `XmlTree.parse` 1,437 and 355,464. Follow-up: `Opc` still reads content types and relationships with `Xml.parse_str`, closed by G1.3a |
| `[x]` G1.3a Package parts through the XML boundary | `Opc` reads `[Content_Types].xml` and relationship parts with `XmlTree.parse` under the XML bounds of `Limits`, matching elements by the content-types and relationships namespaces and local name rather than by prefix as written, and no longer imports roc-parser; `XmlTree.ReadError` becomes the payload of `ContentTypesNotXml` and `RelationshipsNotXml` | `blueprint run check` green; a content-types part and a relationship part with producer-chosen prefixes (`ct:Types`, `pr:Relationships`) open; the three fuzz targets pass, with any ceiling that rises explained. Done: `Package` keeps its `Limits` for `relationships`; `ContentTypesNotUtf8`, `RelationshipsNotUtf8` and `XmlProblem` are gone, since `XmlNotUtf8` and the located errors arrive in the payload; content types go straight into the lookup dictionaries in one pass over the root's children. Opening the minimal, lying-bomb and compressible packages takes 59 allocations and 4 reallocations at 16,307 bytes peak for the minimal one (was 51, 5 and 15,555): namespace resolution keeps a scope and resolved names per start tag, which `Xml.parse_str` did not, so their ceilings rise from 56 to 63; the truthful bomb stays at 3. The writer is unchanged, so `zip_opc_roundtrip` holds at 200+12 and 676+19 (`to_bytes` 201+12 and 677+21). The generated content types and relationships stay on Opc's own escaped writer: `XmlTree.render` would put a line feed after the declaration, changing every generated part's bytes, and would build two trees per part for no gain: the generated parts already validate against the OPC schemas |
| `[x]` G1.4 MCE processing | `Mce`: understood-namespace constant, `Ignorable`, `AlternateContent`, `ProcessContent`, `PreserveElements`, `PreserveAttributes`; interpreted and preserved trees; `fuzz/mce_processing` against a small reference implementation inside the target | LibreOffice and Word fixtures process to trees free of extension content while preserving it; the fuzz target passes. Done: `package/Mce.roc`, `Mce.process : XmlTree.Node -> { interpreted, diagnostics }` over one explicit work list; the input is the preserved tree. `Mce.understood` lists the ECMA-376 namespaces of a WordprocessingML package (Parts 1, 2 and 4's VML), Dublin Core, `xsi`, `xml` and `mc`; `w14`, `w15`, `wps` and the other Microsoft namespaces are extensions. Prefix lists resolve through the declarations in scope; the root is always kept; `PreserveElements` and `PreserveAttributes` need nothing since the preserved tree keeps everything; the content of an `extLst` in an understood namespace is kept unprocessed, because pandoc's theme carries `thm15` there without `mc:Ignorable`. Diagnostics `UndeclaredExtension` (once per namespace and part), `RequiredExtension`, `UnboundPrefix` and `InvalidCompatibilityMarkup`, each located by element name and document-order position, which costs constant space where a path would cost the depth. Every XML part of all 14 fixtures processes without a diagnostic to an interpreted tree with no extension or compatibility markup, agreeing with the reference, while the preserved trees keep it (LibreOffice: 14, 3, 3, 3, 4, 2 and 2 elements and attributes; pandoc none outside `extLst`); `libreoffice/basics` resolves a `wps` shape to its VML fallback. Ceilings `64 + 2n` allocations and `16 KiB + 1,024n` bytes per tree of `n` nodes and attributes (real parts reach 1.5 and 270, a 64-deep chain about 820 bytes), small/large pair 104 and 1,550, exact per-fixture ceilings; 700,000 explored inputs agreed with the reference, and a mutant that ignores `ProcessContent` was found in 60 seconds from an empty corpus. The four Word fixtures are declared examples (3,627, 4,158, 4,066 and 3,599 allocations; 131, 70, 106 and 65 preserved extension elements and attributes); a part whose root is in an extension namespace, such as `people.xml`, interprets to its bare root, which Mce always keeps |
| `[x]` G1.5 Pass-through fidelity | `Document.equivalent` for XML parts as the architecture defines; a `parse` then `write` pass-through that preserves every part and tree without a WordprocessingML model yet; the test driver's first data-driven case family: pass-through of every fixture | Every fixture passes through equivalently; LibreOffice's snapshot of the written file equals its snapshot of the input; the schema oracle accepts every written part. Done: `package/Docx.roc` (`parse`, `to_bytes`) over `package/Document.roc`, an opaque document of the opened package, its part graph and the tree of every XML part (`from_package`, `to_bytes`, `equivalent`, `equivalent_xml`); other parts are `Copied`. Reading drops the four dropped-class kinds with one `Dropped({ part, content, count })` diagnostic per part and kind; an unreadable XML part is `XmlPartUnreadable`. `XmlTree.render` now writes any namespace: outside the table with its read prefix unless taken, unprefixed or `xml`-reserved, else `ns1`, `ns2`, declared after the table's in first-use order; the prefixes named by `mc:Ignorable`, `mc:MustUnderstand`, `Requires`, `mc:ProcessContent`, `mc:PreserveElements`, `mc:PreserveAttributes` and `xsi:type` are resolved in their source scope, rewritten, and their namespaces declared even when no name uses them (LibreOffice's `mc:Ignorable="w14 wp14 w15"` named undeclared prefixes after the old render). `XmlTree.unprefixed` is the namespace half of the equivalence. `tests/main.roc` runs the cases (`cases`, `cases-update`) with expectations in `tests/passthrough/` (dropped content, size, FNV-1a digest, parts) and writes to `.roc-docx/passthrough/`; check runs it and `oracle-schema-written` (180 written parts PASS); the `libreoffice` task runs it and `compare_snapshots.py --written libreoffice` (14 AGREE; a tampered output fails). `fuzz/parse_never_crashes`: arbitrary bytes or generated packages with colliding prefixes, alternatives and dropped content; exact ceilings 1,184 and 9,266 for the small/large pair, 16,281 and 14,287 for pandoc and LibreOffice `basics`, linear `1,024 + 2n` allocations and `512 KiB + 320n` bytes; 60-second explorations of 11,585 and 8,206 inputs pass. `xml_namespace_roundtrip` ceilings rose about 8 per cent for the fixtures (pandoc `basics` 11,344 to 12,229) and from 2,470 to 2,704 for the large tree, the cost of the planning pass and the rewritten values; the small tree's fell from 233 to 223 |
| `[x]` G1.5a Written extensions are declared ignorable | Writing declares on each part's root every extension namespace the part uses without declaring it ignorable, as the architecture's MCE rule requires; a Google Docs export's `w14:paraId` on `w:p` was written back undeclared and failed the schema oracle | A Google-Docs-style package passes through with `mc:Ignorable` naming `w14` and its written parts validate. Done: `Mce.declare_extensions` adds the namespaces `Mce.process` reports as `UndeclaredExtension` to the root's `mc:Ignorable`, after what is there, by the root's prefix or the first free `nsN`; packaging parts and roots outside `Mce.understood` (custom XML) are left alone, VML counts as understood, the content is kept. A scan gates the processing so a part without an undeclared extension outside its extension lists costs one allocation. `Document.to_bytes` applies it before `XmlTree.render`; `Document.equivalent_xml` compares undeclared as declared (architecture equivalence rule added). `expect`s in `Mce` and `Docx`; `fuzz/parse_never_crashes` generates undeclared extensions and declares an `undeclared-extension` example (`w14` undeclared, ceiling 1,298); ceilings rose by the scan: small 1,184 to 1,189, large 9,266 to 9,273, pandoc `basics` 16,281 to 16,296, LibreOffice `basics` 14,287 to 14,643 (its main part offers `wps` shapes undeclared inside alternatives, so it is processed). No fixture had an undeclared extension; pass-through expectations unchanged. A synthetic Google-Docs-style variant of pandoc `comments` (not committed) fails the schema oracle on `document.xml` and `comments.xml` as read and passes 15 of 15 parts as written |

| `[x]` G1.P Performance | Every Gate 1 fuzz target measures its operation in a named region and asserts linear ceilings for generated inputs and exact ceilings for its declared examples; `zip_opc_roundtrip` and `xml_namespace_roundtrip` declare a small and a large example whose ceilings encode a linear ratio | Ceilings pass in the smoke run; a deliberately quadratic copy in a scratch branch fails the large example  Done: an audit of the five targets against the architecture; every exact ceiling already equalled its measured count, so none moved. Regions are named after their entry points (`xml-read` and `xml-render` became `xml-tree-parse` and `xml-tree-render`). The pairs' ratios are asserted, not only commented: running the large example measures the small one again in the same run and fails above sixteen times its allocations or requested bytes (`xml_namespace_roundtrip`, 12.1 and 10.6 measured; `mce_processing`, 14.9 and 12.6), or above its allocations plus 41 for each of the twelve further parts (`zip_opc_roundtrip`, 40.25 measured), so a quadratic cost cannot be ratcheted in by raising both exact ceilings. `opc-to-bytes` gained a peak ceiling (the chunked writer's plus twice the archive) and `opc-part-bytes` allocation ceilings (linear, and 13 for each declared package). The chunked writer's memory ceiling was unsound beyond the generated graphs' eight parts: copied packages with 24 further parts hold about 750 bytes a part, so the per-part term rises from 256 to 1,024 bytes and generated graphs now reach 32 parts. `parse_never_crashes` rejects a mutated `Fixture` index out of range instead of crashing (found by a 60-second exploration). Its pair keeps exact ceilings only: a constant compressor dominates it, which G2.P addresses. Quadratic copies in a scratch branch (`XmlTree.parse` copying its node list per element, `Mce.process` likewise, `Opc.add` copying its steps per part) fail every declared example's exact ceiling; with the exact checks disabled, the small examples pass and each large one fails its ratio check. 60-second explorations of every target pass |

**Exit.** All of the above green, with every kernel target carrying its
ceilings.

## Gate 2: WordprocessingML reading and writing

**Goal.** The typed model for the supported subset, read from and written to
XML with canonical form, agreeing with both oracles on every fixture.

| Slice | Deliverable | Evidence |
| --- | --- | --- |
| `[x]` G2.1 Body, paragraphs, runs | Model core; `WmlRead` for body, paragraphs, runs, text, tabs, breaks, symbols, hyphens; `Snapshot` text keys; `Docx.text` | Snapshot text agreement with LibreOffice and pandoc on every fixture. Done: `Document.Block` (`Paragraph`, `Container`, `Preserved`), `Paragraph` and `Run` with `properties.preserved`, `Document.Inline` (`Run`, `Container`, `Preserved`) and `Document.RunContent` (`Text`, `Tab`, `Break({ kind, clear })`, `Symbol({ font, code })`, `SoftHyphen`, `NonBreakingHyphen`, `Preserved`); an unmodelled element whose content is blocks (table, row, cell, content control, custom XML) or paragraph content (hyperlink, revisions, simple field, content control, smart tag, custom XML, `dir`, `bdo`) is a `Container` with its content read, any other is `Preserved` in place. `WmlRead.body` reads the main part's tree after `Mce.process`; `w:t` without `xml:space="preserve"` is trimmed with tabs and line ends as spaces, as LibreOffice reads it. `Docx.body`, `Docx.text`, `Document.paragraph_text`, `Document.main_document`. The model is a query over the kept trees, which a document still writes, so `Docx.parse` and its fuzz ceilings are unchanged. `Snapshot.json` declares `blocks.text`; the `snapshots` cases write and check one per fixture (`tests/snapshots/`), and `oracle/snapshot_package.py` copies them as the `package` adapter, in `oracle-snapshot` (pandoc) and the `libreoffice` lane: 14 of 14 agree with each oracle. A scratch document with a tab, line break, symbol, both hyphens and unpreserved whitespace agreed with LibreOffice (pandoc turns tabs into spaces and collapses spaces) |
| `[x]` G2.1a Current text honours moves and deleted paragraph marks | `Document.paragraph_text` leaves out moved-away text; a deleted or moved-away paragraph mark joins its paragraph to the next in `Docx.text` and `Snapshot.json` | Snapshot text agreement on `word/revisions.docx`. Done: a `w:del` or `w:moveFrom` container contributes no text (Word writes moved-away text as `w:t`), `ins`/`del` inside a move apply as elsewhere; `Document.joins_next` reads `w:pPr/w:rPr/w:del` or `w:moveFrom`; the snapshot joins such a paragraph into the next block through content controls and stops at a table, `Docx.text` omits its line feed and stops at a table, row or cell boundary. `Docx.text` is the current text, the oracles' view; `final_text` and `original_text` stay with G4.1. `tests/snapshots/word/revisions.json` regenerated: the moved-away sentence left block 2 and the joined paragraphs are one block. `oracle-snapshot` 17 agree, 1 accepted, 0 fail; `libreoffice` lane 49 agree, 13 accepted, 0 fail, written 18 of 18 |
| `[ ]` G2.2 Styles and effective properties | Style table, inheritance, toggle semantics, `Styles.effective_paragraph` and `effective_run`; formatting keys in the snapshot; headings recognised through styles | Agreement on formatting and heading keys; `fuzz/style_resolution` passes |
| `[ ]` G2.3 Numbering | Abstract definitions, instances, overrides, list membership and level | Agreement on list keys |
| `[x]` G2.4 Tables | Tables, rows, cells, grid, spans, merges, properties, nested tables | Agreement on table keys; the pandoc table fixtures and a Word table fixture. Done: `Document.Block` gains `Table({ properties, grid, content })`; `TableContent` (`Row`, `Container`, `Preserved`) and `RowContent` (`Cell`, `Container`, `Preserved`) keep content controls, custom XML, bookmarks and `w:tblPrEx` in place, and a cell's content is blocks, so tables nest; `tbl`, `tr` and `tc` are no longer containers. Properties: table `style` (the identifier G2.2 resolves), `width`, `borders`, `shading`; grid `Column(twips)` or `Preserved`; row `header`, `grid_before`, `grid_after`; cell `width`, `span`, `merge` (`Restart`, `Continue`), `borders`, `shading`, `alignment`; unset is `Unset`, and an element with attributes the model cannot hold (theme colours, an automatic width with a size) stays in `preserved` whole. `Document.table_rows` and `row_cells` read through containers. Fractional numbers (`w:w="10470.0"`) and percentages finer than a fiftieth are rounded half away from zero with a `WmlRead.Diagnostic` `Rounded({ element, attribute, value })`, returned by `WmlRead.read_body` and `Docx.read_body`; `body` is unchanged. `Snapshot` declares `blocks.rows`: a spanned column, a cell continuing a vertical merge and a skipped grid column are empty cells, a cell's snapshot paragraphs join with LF and a nested table is an empty line; `snapshot_schema.json` states the merge and skip rules, and `snapshot_pandoc.py` fills the columns pandoc's row spans leave out of the rows below, which it had dropped, shifting the row's later cells left. 14 of 14 agree with pandoc in check and with both oracles in the `libreoffice` lane (a tampered package row fails); a scratch document with a span, two merges, a nested table, `gridBefore` and `gridAfter` gives identical grids from LibreOffice, pandoc and the snapshot `expect`, while pandoc truncates rows when a `w:gridCol` width has a fraction. `fuzz/table_reading` checks generated tables against what was written (rows, skips, spans, merges, nesting, content controls, one diagnostic per fractional width); ceilings `64 + 4n` allocations and `16 KiB + 512n` bytes per node (3.4 and 350 measured), small/large pair 880 and 13,551 (ratios 15.4 and 14.9 of the 16 allowed); 60 seconds explored 13,872 inputs; reading `gridSpan` as unknown fails both examples. The Word table fixture (header row, shading, vertical merge, span, nested table) agrees with pandoc and LibreOffice on `blocks.rows` |
| `[ ]` G2.5 Sections and properties | Sections, page geometry, headers and footers, core and app properties | Agreement with LibreOffice on section keys; properties round-trip |
| `[x]` G2.6 References and images | Hyperlinks, bookmarks, footnotes, endnotes, fields exposed as code and cached result, inline images as opaque media with extent | Agreement on footnote and link keys; image parts preserved byte-identically. Done: `Document.Inline` gains `Hyperlink({ target, preserved, content })` (`LinkTarget`: `External`, `ExternalAt({ url, location })`, `Internal(name)`), `SimpleField({ code, preserved, content })`, `BookmarkStart(name)`, `BookmarkEnd(name)`; `RunContent` gains `NoteReference({ kind, note })` (the note's index in `Docx.footnotes`/`endnotes`), `NoteMark(kind)`, `FieldMark({ kind: Begin/Separate/End, element })`, `FieldCode(text)` and `Picture({ media, size, drawing })`; `hyperlink` and `fldSimple` are no longer containers. Identifiers are model-level: links hold the relationship's address, bookmark ends the start's name, references the note's place, pictures the media part's name; what does not resolve (missing relationship or note, custom mark, column bookmark, end without start, floating drawing) stays `Container` or `Preserved`. `WmlRead.Context` carries the part's relationships and the note parts' identifiers; `WmlRead.body`/`read_body` take it, `WmlRead.notes` and `note_ids` read note parts (kinds `Note`, `Separator`, `ContinuationSeparator`, `ContinuationNotice`); `Document.related` finds parts by relationship type. `Docx.footnotes`, `endnotes`, `fields`; `Document.fields` gathers `{ code, result }` across runs and paragraphs, nested fields in results; `Document.field_target` reads a `HYPERLINK` code's target, never evaluating. `Snapshot` declares `blocks.runs.link` (runs split at links, `HYPERLINK` field results included, deleted and moved-away content left out), `notes.kind` and `notes.text` (body references' order). `oracle-snapshot` 14 agree, 11 accepted (existing pandoc trimming and bookmark-case deviations), 0 fail; `libreoffice` lane 46 agree, 23 accepted, 0 fail, LibreOffice against package agreeing on all 18 fixtures, written 18 of 18. Scratch documents (pandoc and LibreOffice, with internal and external links, a link with a location LibreOffice writes as a `HYPERLINK` field, footnote, two-paragraph endnote, inline picture) agreed with LibreOffice; pandoc differed only by its paragraph trimming. `word/report.docx`: its picture reads as `/word/media/image1.png` 914400×457200 and the image part is byte-identical after `Docx.parse` and `Docx.to_bytes`, as an `expect` also shows. `fuzz/table_reading` ceilings unchanged (880 and 13,551): the bookmark prescan compares local names before namespaces, since comparing against a namespace constant allocates |
| `[ ]` G2.7 Writer | `WmlWrite` for everything above with canonical element and attribute order and identifier allocation; the document keeps the model instead of the main part's tree, read one block at a time through the namespaced pull reader so no XML tree of the whole body is held beside the model; `fuzz/document_roundtrip`; `fuzz/structure_oracle` | Every written part validates against the schema; model round-trips; LibreOffice reads written fixtures to the same snapshot; writing twice gives identical bytes |
| `[ ]` G2.P Performance | `Docx.parse` and `Docx.to_bytes` measured as named regions with linear ceilings; declared small and large examples (a one-paragraph document and the largest fixture) with exact ceilings; style resolution and table reading declare their own pairs | Ceilings pass; growth between each pair is at most the stated ratio |

**Exit.** The *Reads*, *Preserves* and *Writes valid* claims hold for the
Gate 2 subset on the whole corpus, with fuzz baselines accepted and diagnostics
for every unmodelled construct inventoried.

## Gate 3: comments

**Goal.** Comments as threads: read from every producer, written so that Word
and LibreOffice show replies and resolution, and editable through the facade.

| Slice | Deliverable | Evidence |
| --- | --- | --- |
| `[ ]` G3.1 Comment content and anchors | `comments.xml`, range boundaries, reference runs, comments without ranges; snapshot comment keys | Agreement with LibreOffice and pandoc on author, date, text and anchored text |
| `[ ]` G3.2 Threads and identities | `commentsExtended.xml`, `commentsIds.xml`, `commentsExtensible.xml`, `people.xml`; join by paragraph identifier into the thread model | Word fixtures with replies and resolved comments read as threads; older fixtures read without the parts |
| `[ ]` G3.3 Comment writing | All five parts written from the thread model; shared identifier space; `fuzz/comment_anchors` | Schema validity of `comments.xml`; LibreOffice reads written comments to the same snapshot; the maintainer records Word opening a written document with threads intact |
| `[ ]` G3.4 Comment operations | `Docx.add_comment`, `reply`, `resolve`, `remove_comment`, `comments` queries; `examples/review_contract.roc` | The example's output is recorded and oracle-validated; operations preserve text under fuzzing |

| `[ ]` G3.P Performance | Comment joining and writing measured with ceilings; a declared example with many short comments bounds the join | Ceilings pass |

**Exit.** Comments are claimed in the README.

## Gate 4: tracked changes

**Goal.** Every revision kind read and written; the accept/reject algebra;
tracked editing.

| Slice | Deliverable | Evidence |
| --- | --- | --- |
| `[ ]` G4.1 Run-level revisions | Insertions, deletions, moves, deleted text and instructions; snapshot revision keys; `Docx.final_text`, `original_text` | Agreement with LibreOffice and pandoc on revision kind, author, date and text |
| `[ ]` G4.2 Structural and property revisions | Paragraph-mark revisions, run/paragraph/section/table/row/cell property changes, row and cell insertions, deletions and merges, tracking settings | Word fixtures covering each kind read and round-trip; LibreOffice agreement where it exports the kind |
| `[ ]` G4.3 Revision writing | Writer support for every kind; `fuzz/revision_algebra` | Schema validity; LibreOffice agreement on written revisions; the maintainer records Word acceptance |
| `[ ]` G4.4 Accept, reject, tracked editing | `accept_all`, `reject_all`, filtered forms, tracked edit context on every facade edit | Algebra laws hold under fuzzing; `examples/redline.roc` records and validates a tracked edit session |
| `[ ]` G4.P Performance | `accept_all` and `reject_all` measured with ceilings on a declared example with many revisions; the pair encodes a linear ratio | Ceilings pass |

**Exit.** Tracked changes are claimed in the README; the *Modify* job from the
architecture's product destination is demonstrated end to end on a Word
fixture.

## Gate 5: authoring

**Goal.** Generate complete business documents from application data that
open cleanly in Word and LibreOffice.

| Slice | Deliverable | Evidence |
| --- | --- | --- |
| `[ ]` G5.1 Default document kit | Minimal style set (normal, headings, list paragraph, table grid, hyperlink, comment and footnote styles), numbering definitions, settings, font table, core properties | A generated empty document validates and opens in LibreOffice and Word without repair |
| `[ ]` G5.2 Builders | Paragraphs, runs, lists, tables, hyperlinks, footnotes, page setup, headers and footers with page-number fields, section breaks, metadata | Each builder has a fixture-free unit test and a schema-validated output |
| `[ ]` G5.3 Example gallery | `examples/letter`, `examples/agreement` (with comments), `examples/minutes` (with tracked changes), `examples/report` (with tables and headers) | Every example's output is recorded, schema-valid, LibreOffice-agreed and Word-accepted by the maintainer |
| `[ ]` G5.4 Performance | Builders measured with ceilings; a generated long document (many pages of paragraphs and tables) as the large example of the write pair | Ceilings pass; the example gallery's documents are within the linear ceilings |

**Exit.** The *Generate* job is demonstrated; the gallery is linked from the
README.

## Gate 6: first release

| Slice | Deliverable | Evidence |
| --- | --- | --- |
| `[ ]` G6.1 Manual complete | The manual's chapters cover reading documents, comments, tracked changes, authoring, limits and diagnostics, and releases, beside the existing overview, getting started, architecture and contributing chapters; API reference from `roc docs` | Rendered by the shared renderer without warnings; every snippet is compiled in CI |
| `[ ]` G6.2 Release dry run | Shared release workflow dry run green, examples archive tested against the bundle, release notes with bundle URL and compiler | A `0.1.0-rc1` candidate consumed from its bundle URL by a fresh application |
| `[ ]` G6.3 Publication | `0.1.0` published; nightly compatibility reporting adopted; downstream status registered in roc-automation; this plan deleted and `AGENTS.md` reduced to what outlives the release | The release is immutable; the nightly report runs; nothing in the tree links to the plan |

## Upstream changes

The streaming and bounded-memory analysis of 2026-11-09 found that the
dependency APIs as released could not honour the architecture's resource
bounds. The maintainer implemented the missing operations the same day, in
the forks and in roc-parser, and published them as release candidates for
roc-docx to build on. Gate 1 is designed against these APIs and G1.1a pins
them.

| Dependency | Requested | Delivered | Candidate |
| --- | --- | --- | --- |
| roc-parser | [#112](https://github.com/lukewilliamboswell/roc-parser/issues/112): a pull reader, namespace processing, depth and element budgets as defaulted props, linear text decoding confirmed by a ceiling, and a serializer so roc-xml can be dropped | [PR #113](https://github.com/lukewilliamboswell/roc-parser/pull/113), merged: `Xml.reader` with `next`, `element` and `element_with`; `Xml.parse` and `Xml.ReaderProps` (`max_depth`, `max_elements`, `max_attributes`) failing with `LimitExceeded` before anything is built; `XmlNs` with `parse_str`, `parse`, a resolving reader and `render` with `RenderProps`; text decoding made linear and held there by the `xml-ceilings` target | [6.0.0-rc.1](https://github.com/lukewilliamboswell/roc-parser/releases/tag/6.0.0-rc.1), a hand-built preview without the usual attestations, whose preview APIs may change before the final |
| roc-deflate | [#6](https://github.com/lukewilliamboswell/roc-deflate/issues/6) and [#7](https://github.com/lukewilliamboswell/roc-deflate/issues/7): bounded output that fails before the copy that would exceed it, pre-sizing from a declared size, reusable coder state, input-sized compressor buffers | [PR #8](https://github.com/lukewilliamboswell/roc-deflate/pull/8), merged: `decompress` and `decompress_into` take `Deflate.Bounds` (`max_output`, `expected_size: Declared(n)`) and add `OutputLimitExceeded`; `Deflate.decoder` with `decompress_with` and `Deflate.compressor` with `compress_with` keep their tables between streams; compressor buffers sized to the input; four fuzz targets with ceilings | [0.6.0-rc1](https://github.com/lukewilliamboswell/roc-deflate/releases/tag/0.6.0-rc1), pinned by roc-zip rather than by roc-docx |
| roc-zip | [#1](https://github.com/lukewilliamboswell/roc-zip/issues/1): an entry index from the central directory, bounded single-entry extraction, stored-byte access, a part-at-a-time writer with `create` as a fold over it, duplicate-name detection | [PR #2](https://github.com/lukewilliamboswell/roc-zip/pull/2), merged: `Zip.entries`; `Zip.extract_entry` with `EntryLimits`, failing with `EntryTooLarge` before allocation and `SizeMismatch` when a stream runs long or short; `Zip.compressed` and `Copied` for writing stored bytes unchanged; `Zip.writer`, `add` and `finish`, whose chunks equal `Zip.create`; `DuplicatePath` from reader and writer; `extract` as a loop over the index; four fuzz targets; a ZIP64-locator false positive present since 0.2.2 fixed | [0.3.0-rc1](https://github.com/lukewilliamboswell/roc-zip/releases/tag/0.3.0-rc1) |

roc-docx pins the candidates rather than waiting for final releases so the
kernel is built once, on the APIs the architecture describes. Each final
release is adopted as its own upgrade slice with the full check green. Both
forks exist to be offered upstream; the architecture's dependency section
records the exit condition.

## Later expansions

Each is independently justified and gated; none blocks 0.1.0.

- Strict-namespace input by namespace mapping.
- `Docx.compare`: produce tracked changes from two documents.
- Image authoring with PNG and JPEG dimension sniffing.
- Theme font and colour resolution.
- Content controls and form fields as modelled constructs.
- A `Docx.blocks` fold over the body for extraction, search and indexing, on the per-block reading Gate 2 establishes.
- `Docx.to_chunks` and `next_chunk`: writing one part per step for callers that stream to a file or socket, byte-identical to `to_bytes`.
- One decoder and one compressor across the parts of an archive: roc-deflate 0.6.0-rc1 keeps their tables between streams, and roc-zip does not yet thread them through `extract_entry` and `add`, so the per-part table allocations remain the constant term in the ceilings.
- Microsoft's Open XML SDK validator as an additional lane (see open decisions).
- Windows CI for the examples.
- Dedicated fuzz campaigns or benchmarks in CI, as separate scheduled work.

## Risks

| Risk | Mitigation |
| --- | --- |
| Nightly compiler churn breaks the package or a dependency between releases | Dependencies' own nightly CI; the package floats on the latest nightly as the roc-automation model prescribes; upgrades land as small slices with compat evidence |
| Release-candidate pins: the candidates are previews whose APIs may change before their final releases, and the ZIP and DEFLATE pins are forks | Every dependency type stays behind the `Opc` and XML boundaries, so an API change is a local edit; finals are adopted as upgrade slices; the forks' changes are offered upstream and the architecture records the exit condition |
| LibreOffice version variance produces spurious snapshot differences | Pin the installed version in the lane, record it in reports, compare only declared keys, and use accepted deviations with causes |
| Schema validity does not imply Word acceptance | Maintainer Word acceptance recorded on examples; the first schema-pass-Word-fail case triggers the Open XML SDK decision |
| No XSDs for Microsoft extension parts | Structural checks in `fuzz/structure_oracle`, LibreOffice reading, Word acceptance; revisit when a reviewed schema source is available |
| Agents widen scope or weaken checks to go green | `AGENTS.md` rules, one slice per pull request, required checks on `integration`, review of every accepted deviation and baseline |
| Fixture content licensing | Self-authored or generated content only; provenance for every file |
| Tree-per-part memory on very large documents | Limits with named errors; per-gate ceilings; roc-parser's pull reader under per-part trees and per-block reading of the body in Gate 2, which the streaming analysis (2026-11-09) estimates cuts the peak for a 5 MB body from roughly 14–22× to 2–4× of the part's bytes; `XmlNs` holds about twice the memory of `Xml` for the same part, which the G1.3 ceiling records; a whole-document event stream is not pursued because the model is whole-document by design |
| Compression bombs | `Opc.open` checks the central directory against the limits before inflating anything and inflates each part within its declared size with `Zip.extract_entry` (G1.1b); `fuzz/opc_open` declares a truthful and a lying bomb |

## Open decisions for the maintainer

1. **Blueprint release.** Start on platform 0.8.0, matching the installed CLI,
   roc-automation's example and roc-pdf, and upgrade to 0.11.0 as a Gate 0
   follow-up once the shared actions are verified against it.
2. **LibreOffice provisioning in CI.** Recommended: install the distribution
   package on the Ubuntu runner and record the version in the lane's report,
   accepting version drift as a documented variance; alternative: pin a
   LibreOffice release archive by digest. The `libreoffice` job follows the
   recommendation until this is decided.
3. **Open XML SDK lane.** Not adopted now; adopt when a written document passes
   both oracles and Word rejects it, or when a gate needs Word-specific
   semantics that LibreOffice does not exercise.
4. **Repository settings.** Rulesets, the `release` environment and private
   vulnerability reporting need administrator rights and are a maintainer task
   in G0.5.
5. **ECMA schema distribution.** Fetched by digest at provisioning, not
   committed, to avoid redistributing ECMA text; revisit if provisioning
   proves unreliable.
6. **Candidate pins.** Build Gate 1 on the release candidates (G1.1a) and
   adopt each final release as its own slice. If a candidate's API changes
   before its final, the change is confined to the dependency boundary and
   lands with that slice.
