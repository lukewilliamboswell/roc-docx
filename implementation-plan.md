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
- **Read before writing.** `AGENTS.md`, `architecture.md`, the gate the slice
  belongs to, and the roc-automation manual chapters the slice touches.
- **Evidence in the description.** The pull request body has four parts:
  *Slice* (the identifier and deliverable), *Change* (what was built, in
  prose), *Evidence* (commands and their results, including oracle lane
  summaries and fuzz `check` output), *Follow-ups* (anything discovered and
  deliberately not done, each as an issue).
- **Stop and ask** before: changing `architecture.md`; adding or upgrading a
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
| `roc-zip` 0.2.2, `roc-xml` 2.0.5, `roc-parser` 4.0.0 | Compile together as package dependencies on that nightly; a combined render → zip → unzip → parse probe passes `roc test` |
| `basic-cli` | 0.26.0 fails on that nightly (16 type errors in the platform); 0.27.0 (released 2026-11-07, requires nightly ≥ 2026-11-06) passes. Examples and scripts use 0.27.0 |
| `roc-fuzz` 0.5.0 | Bundle `9WT86CuwM7ZJBSs8iTd1jLyrUFTTiGp5hcJE63TwswGE.tar.zst`, SHA-256 `aed4032105af1cc910604949f43636b7bff6aec4a82184631213153b8e2dd23f`, 2,242,328 bytes; `roc build --fuzz` and `check`/`run` work on the nightly |
| Error vocabulary | `roc-xml` and `roc-parser` both export an `InvalidXml` tag with different payloads; the package must map errors at its boundaries |
| ECMA-376 schemas | Part 4 Transitional XSDs compile in `xmllint` once a wrapper schema imports the W3C `xml.xsd`; validating a part takes about 40 ms. Digests are in the ledger |
| pandoc 3.9.0.2 | Writes `w:ins`, `w:del`, `w:delText`, comment ranges and `comments.xml`; reads them back with `--track-changes=all`; its parts validate against the schema; output is byte-identical under `SOURCE_DATE_EPOCH` |
| LibreOffice 26.2.3 | Headless conversion to Flat ODT preserves tracked changes and annotations with creators; `.docx` round trip keeps `w:ins`, `w:del` and comments; its parts validate only after MCE preprocessing (`mc:Ignorable`) |
| Word and Google Docs output | A Google Docs export uses `w14:paraId` without declaring it ignorable and omits the required `w:gutter` on `w:pgMar`; both must be accepted on read and neither is produced on write |
| Blueprint | CLI 0.8.0 installed locally; platform 0.8.0 is what roc-automation's example and roc-pdf use; 0.11.0 is the latest release |
| roc-automation | `main` at `8f0bb2254540fcdd746bdb4ed10851b4c34c8203`; shared tools release `tools-0.10.0` provides `release-package` and `roc-docs` for Linux and Apple Silicon |
| Repository | `lukewilliamboswell/roc-docx` exists on GitHub, public, empty, no licence, no rulesets |
| Check task | `blueprint run check` completes locally in about half a minute; the fuzz target build takes 22 s and schema validation of 180 parts takes 5 s |
| First ratchet | `Opc.open` on the minimal package: 60 allocations, 7 reallocations, 14,395 bytes peak live, 44,291 bytes requested, mostly the ZIP layer's decode tables; ceiling set at 67 allocations and reallocations |
| Streaming analysis | roc-deflate is a whole-buffer port (no incremental inflate or compress); `roc-zip` has no entry index or single-entry extraction and `Zip.create` needs every entry at once; roc-parser's tree parser is already an explicit-stack event loop, so a pull reader is a refactor; every LibreOffice fixture entry uses a data descriptor, pandoc's none; corpus parts decompress 5.5 to 7.9 times |

## Gate 0: scaffold, oracles and test infrastructure

**Goal.** A repository in which a slice can be developed with confidence
before any WordprocessingML code exists: pinned tooling, provisioned and
verified oracles, a fixture corpus with provenance, a snapshot contract that
two independent oracles already agree on, and CI that runs it all.

| Slice | Deliverable | Evidence |
| --- | --- | --- |
| `[x]` G0.1 Repository scaffold | `LICENSE` (UPL-1.0), `README.md`, `.gitignore`, `.gitattributes`, `SECURITY.md`, `AGENTS.md`, `architecture.md`, this plan, `Blueprint.roc` and `Blueprint.lock`, `conformance/ledger.json` | `blueprint check` and `blueprint update` succeed; the lock names every fetched tool for both systems |
| `[x]` G0.2 Schema oracle | `oracle/provision.py` fetches ECMA-376 Parts 2 and 4, the W3C `xml.xsd` and the Dublin Core schemas by URL (Parts 1 and 3 with `--all`), verifies the ledger digests and sizes, unpacks the Transitional and OPC schemas and writes the wrapper schemas and XML catalog under `.roc-docx/oracle/`; `oracle/mce_strip.py` implements Part 3 removal of ignorable content and alternate-content selection; `oracle/validate_schema.py` validates every XML part of a `.docx` or directory against the schema its root namespace selects, after MCE preprocessing or raw with `--raw`, consults the accepted deviations and reports per part | All 180 parts of the 14 fixtures validate after preprocessing; raw validation fails exactly the 19 LibreOffice parts that carry `mc:Ignorable`; a deliberately misordered `w:rPr` fails with the schema's message and a nonzero exit; a maintainer's Google Docs export showed the undeclared `w14:paraId` and missing `w:gutter` deviations the reader must accept |
| `[~]` G0.3 Fixture corpus v1 | `tests/fixtures/sources/*.md` pandoc sources covering headings, inline formatting, lists, tables, links, footnotes, comments, insertions and deletions; `oracle/make_fixtures.py` regenerates them with `SOURCE_DATE_EPOCH`; a check fails when a committed fixture differs from regeneration; LibreOffice round-trip fixtures and maintainer-produced Word and Google Docs fixtures committed with `tests/fixtures/provenance.json` | Regeneration is byte-stable; every fixture has a provenance entry; no third-party content. Done: seven pandoc and seven LibreOffice fixtures with provenance, all 180 parts schema-valid. Open: Word fixtures with threaded and resolved comments and every revision kind, and a Google Docs export, produced by the maintainer |
| `[ ]` G0.4 Snapshot contract and adapters | `oracle/snapshot_schema.json` (`roc-docx-snapshot/1`); `oracle/snapshot_pandoc.py` from pandoc JSON; `oracle/snapshot_libreoffice.py` from Flat ODT; `oracle/compare_snapshots.py` comparing declared-key intersections and consulting `conformance/accepted-deviations.json` | pandoc and LibreOffice snapshots agree on every fixture for their common keys, before any Roc parser exists; disagreements are either adapter bugs fixed or deviations recorded with causes |
| `[~]` G0.5 CI and repository settings | `.github/workflows/ci.yml` (the `check` task and the `docs` build, later a `libreoffice` job) and `release.yml` as the thin caller of the shared release workflow with `check-task: check`; rulesets on `main` and `integration` per the roc-automation settings chapter; `integration` branch created | A failing check blocks a test pull request; the release dry run passes; the settings are confirmed against the manual. Done: both workflows, pinned to roc-automation `8f0bb225`; on the first pull request `check`, `docs` and the release dry run including the release-candidate test all pass on the Linux runner. Open: the `integration` branch, rulesets and the `release` environment (maintainer), and the LibreOffice job once G0.4 gives it an adapter to run |
| `[x]` G0.6 Check task and fuzz smoke driver | `blueprint run check` runs `scripts/check_all.roc`: schema provisioning, `roc fmt --check`, `roc-stable fmt --check scripts`, the lint, the lint module's tests, `roc test package/main.roc`, `release-package test-examples`, `scripts/fuzz_smoke.roc` (build each `fuzz/*/main.roc`, run its examples and ceilings, explore for one second and 64 inputs), the fixture regeneration check and `oracle/validate_schema.py` over the fixtures. The shared release workflow runs the same task | Green locally with G1.1 present. A deliberately invalid part and a tampered fixture each fail their check; the same ten checks pass in CI on Linux. Open: validating example outputs and the pandoc snapshot comparison join the task with G0.4 |
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
| `[ ]` G1.1b Bounded open | Index parts by name (today lookups are linear and content-type resolution is parts times overrides) and check the ZIP central directory against the limits before any entry is inflated, inflate each part into a buffer sized from its checked declared size, and stop at the part limit. Needs either upstream additions to `roc-zip` (an entry index, single-entry extraction with a byte bound) and `roc-deflate` (`decompress_into` with an output bound) or an in-package central-directory reader, which is a stop-and-ask dependency decision. Reject duplicate part names, which OPC compares without regard to ASCII case. `fuzz/opc_open` gains declared examples for a compression bomb (with lowered limits) and a highly compressible legitimate package, and its memory ceiling becomes a function of the archive and `[Content_Types].xml` sizes rather than the whole input | The bomb example fails with `PartTooLarge` while peak live bytes stay within the part limit; the compressible example passes; `Opc.open` documents the order of checks truthfully (today it does not: limits are checked after `Zip.extract` has inflated everything) |
| `[ ]` G1.2 OPC writer | `Opc.Writer`: one part at a time (`writer`, `add`, `finish`) emitting chunks, with `Opc.to_bytes` defined as a loop over it; fixed part order; DEFLATE at a fixed level for generated parts; parts read from an archive written with their stored bytes, method and CRC unchanged; no data descriptors; content types and relationships generated from the part graph; `fuzz/zip_opc_roundtrip` | Written `[Content_Types].xml` and `.rels` parts validate against the OPC schemas; concatenated chunks equal `to_bytes` and both equal `Zip.create` for generated parts; writing twice gives identical bytes; the round-trip target's ceilings bound the peak by the largest part |
| `[ ]` G1.3 Namespaced XML | `XmlNs`: scoped prefix resolution to `{ namespace, local }`, undeclared-prefix diagnostics, the canonical prefix table and writer; dependency error mapping; `fuzz/xml_namespace_roundtrip`. Decide here whether a pull reader (`Xml.reader`, `next`, `element`) is contributed to `roc-parser` so the namespaced tree is built in one pass without a raw tree beside it; the agent's streaming analysis recommends it and estimates it halves the per-part peak. The analysis also noted three places where roc-parser's text decoding issues one `concat` per character or per run (CDATA, non-ASCII attribute characters, text after its first reference); `List.concat` has grown geometrically since the compiler fix of 2026-09-29, so measure before assuming a defect, and fix upstream only if a ceiling shows super-linear growth | Every XML part of every fixture resolves without error; generated trees round-trip under the architecture's equivalence; the `xml-tree` ceiling is a stated multiple of the part's bytes with a two-size pair |
| `[ ]` G1.4 MCE processing | `Mce`: understood-namespace constant, `Ignorable`, `AlternateContent`, `ProcessContent`, `PreserveElements`, `PreserveAttributes`; interpreted and preserved trees; `fuzz/mce_processing` against a small reference implementation inside the target | LibreOffice and Word fixtures process to trees free of extension content while preserving it; the fuzz target passes |
| `[ ]` G1.5 Pass-through fidelity | `Document.equivalent` for XML parts as the architecture defines; a `parse` then `write` pass-through that preserves every part and tree without a WordprocessingML model yet; the test driver's first data-driven case family: pass-through of every fixture | Every fixture passes through equivalently; LibreOffice's snapshot of the written file equals its snapshot of the input; the schema oracle accepts every written part |

| `[ ]` G1.P Performance | Every Gate 1 fuzz target measures its operation in a named region and asserts linear ceilings for generated inputs and exact ceilings for its declared examples; `zip_opc_roundtrip` and `xml_namespace_roundtrip` declare a small and a large example whose ceilings encode a linear ratio | Ceilings pass in the smoke run; a deliberately quadratic copy in a scratch branch fails the large example |

**Exit.** All of the above green, with every kernel target carrying its
ceilings.

## Gate 2: WordprocessingML reading and writing

**Goal.** The typed model for the supported subset, read from and written to
XML with canonical form, agreeing with both oracles on every fixture.

| Slice | Deliverable | Evidence |
| --- | --- | --- |
| `[ ]` G2.1 Body, paragraphs, runs | Model core; `WmlRead` for body, paragraphs, runs, text, tabs, breaks, symbols, hyphens; `Snapshot` text keys; `Docx.text` | Snapshot text agreement with LibreOffice and pandoc on every fixture |
| `[ ]` G2.2 Styles and effective properties | Style table, inheritance, toggle semantics, `Styles.effective_paragraph` and `effective_run`; formatting keys in the snapshot; headings recognised through styles | Agreement on formatting and heading keys; `fuzz/style_resolution` passes |
| `[ ]` G2.3 Numbering | Abstract definitions, instances, overrides, list membership and level | Agreement on list keys |
| `[ ]` G2.4 Tables | Tables, rows, cells, grid, spans, merges, properties, nested tables | Agreement on table keys; the pandoc table fixtures and a Word table fixture |
| `[ ]` G2.5 Sections and properties | Sections, page geometry, headers and footers, core and app properties | Agreement with LibreOffice on section keys; properties round-trip |
| `[ ]` G2.6 References and images | Hyperlinks, bookmarks, footnotes, endnotes, fields exposed as code and cached result, inline images as opaque media with extent | Agreement on footnote and link keys; image parts preserved byte-identically |
| `[ ]` G2.7 Writer | `WmlWrite` for everything above with canonical element and attribute order and identifier allocation; `fuzz/document_roundtrip`; `fuzz/structure_oracle` | Every written part validates against the schema; model round-trips; LibreOffice reads written fixtures to the same snapshot; writing twice gives identical bytes |
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

## Preliminary upstream changes

The streaming and bounded-memory analysis of 2026-11-09 found that the
dependency APIs as released cannot honour the architecture's resource bounds.
The features roc-docx needs are tracked upstream, or in forks that stage work
to be offered upstream. roc-docx keeps pinning the upstream releases until a
release includes each feature; a fork becomes a pinned dependency only as the
architecture's dependency section allows, with its exit condition recorded.

| Dependency | Where | Features | Unblocks |
| --- | --- | --- | --- |
| roc-parser | [lukewilliamboswell/roc-parser#112](https://github.com/lukewilliamboswell/roc-parser/issues/112) (the maintainer's own package) | A pull reader under `parse_str`; namespace processing; depth and element budgets as defaulted props; linear text decoding confirmed by a measured ceiling; optionally an XML serializer so roc-xml can be dropped | G1.3, G1.4, per-block reading in Gate 2 |
| roc-deflate | [lukewilliamboswell/roc-deflate#6](https://github.com/lukewilliamboswell/roc-deflate/issues/6), a staging issue in the existing fork of niclas-ahden/roc-deflate | `decompress_into` with an output bound that fails before the copy that would exceed it; pre-sizing the output from a declared size; optionally reusable coder state | G1.1b |
| roc-zip | [lukewilliamboswell/roc-zip#1](https://github.com/lukewilliamboswell/roc-zip/issues/1), a staging issue in a new fork of niclas-ahden/roc-zip | An entry index read from the central directory; bounded single-entry extraction; access to stored bytes; a part-at-a-time writer with `create` as a fold over it; duplicate-name detection | G1.1b, G1.2 |

The roc-deflate fork's default branch is behind upstream and carries older
branches; it was not synced. Nothing was changed in either fork beyond
enabling issues.

## Later expansions

Each is independently justified and gated; none blocks 0.1.0.

- Strict-namespace input by namespace mapping.
- `Docx.compare`: produce tracked changes from two documents.
- Image authoring with PNG and JPEG dimension sniffing.
- Theme font and colour resolution.
- Content controls and form fields as modelled constructs.
- Per-block reading of the document body and a `Docx.blocks` fold for extraction, search and indexing, once the pull reader exists.
- `Docx.to_chunks` and `next_chunk`: writing one part per step for callers that stream to a file or socket, byte-identical to `to_bytes`.
- Reusable inflate and compress state upstream, to remove the per-part decode-table and matchfinder allocations.
- Microsoft's Open XML SDK validator as an additional lane (see open decisions).
- Windows CI for the examples.
- Dedicated fuzz campaigns or benchmarks in CI, as separate scheduled work.

## Risks

| Risk | Mitigation |
| --- | --- |
| Nightly compiler churn breaks the package or a dependency between releases | Dependencies' own nightly CI; the package floats on the latest nightly as the roc-automation model prescribes; upgrades land as small slices with compat evidence |
| Dependency lag: `roc-zip`, `roc-xml`, `roc-parser` are maintained by others | Contribute fixes upstream; the architecture names in-package replacement as the fallback and forking as a last resort |
| LibreOffice version variance produces spurious snapshot differences | Pin the installed version in the lane, record it in reports, compare only declared keys, and use accepted deviations with causes |
| Schema validity does not imply Word acceptance | Maintainer Word acceptance recorded on examples; the first schema-pass-Word-fail case triggers the Open XML SDK decision |
| No XSDs for Microsoft extension parts | Structural checks in `fuzz/structure_oracle`, LibreOffice reading, Word acceptance; revisit when a reviewed schema source is available |
| Agents widen scope or weaken checks to go green | `AGENTS.md` rules, one slice per pull request, required checks on `integration`, review of every accepted deviation and baseline |
| Fixture content licensing | Self-authored or generated content only; provenance for every file |
| Tree-per-part memory on very large documents | Limits with named errors; per-gate ceilings; the streaming analysis (2026-11-09) recommends a pull reader under per-part trees and per-block reading of the body in Gate 2, which it estimates cuts the peak for a 5 MB body from roughly 14–22× to 2–4× of the part's bytes; a whole-document event stream is not pursued because the model is whole-document by design |
| Compression bombs | `Opc.open` today inflates every entry before checking decompressed limits; G1.1b moves the checks before inflation and adds bomb examples to the fuzz target |

## Open decisions for the maintainer

1. **Blueprint release.** Start on platform 0.8.0, matching the installed CLI,
   roc-automation's example and roc-pdf, and upgrade to 0.11.0 as a Gate 0
   follow-up once the shared actions are verified against it.
2. **LibreOffice provisioning in CI.** Recommended: install the distribution
   package on the Ubuntu runner and record the version in the lane's report,
   accepting version drift as a documented variance; alternative: pin a
   LibreOffice release archive by digest.
3. **Open XML SDK lane.** Not adopted now; adopt when a written document passes
   both oracles and Word rejects it, or when a gate needs Word-specific
   semantics that LibreOffice does not exercise.
4. **Repository settings.** Rulesets, the `release` environment and private
   vulnerability reporting need administrator rights and are a maintainer task
   in G0.5.
5. **ECMA schema distribution.** Fetched by digest at provisioning, not
   committed, to avoid redistributing ECMA text; revisit if provisioning
   proves unreliable.
