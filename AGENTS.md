# AGENTS.md

Guardrails for everyone who changes this repository, human or agent. Read
`docs/architecture.adoc` and `implementation-plan.md` before changing
anything; the architecture is the enduring source of truth and the plan is
where work is chosen, tracked and closed until the first release, when the
plan is deleted.

## Principles

1. **Commit only what earns its place.** Every file, sentence, test and
   abstraction in this repository has a reader or a job. No placeholders, no
   scaffolding "for later", no commented-out code, no duplicated explanations,
   no speculative generality. If something is not needed by the slice you are
   closing, it does not land with it.
2. **Enduring versus living.** `docs/architecture.adoc` changes only when a
   requirement changes, in the same pull request as the code, with the new
   requirement stated. `implementation-plan.md` changes with every slice and
   is scaffolding that does not survive the first release. Never work around
   an architectural decision in code; change the decision or keep the
   constraint.
3. **Pure Roc product, independent oracles.** Nothing under `package/` invokes
   or links a native tool. Oracle adapters under `oracle/` are deliberately
   written in another language and must not import or reimplement package
   logic; their value is that they cannot share the package's mistakes.
4. **Parse leniently, write strictly, lose nothing silently.** The reader
   accepts what real producers write and records a diagnostic for every
   deviation. The writer emits schema-valid Transitional markup only. Every
   input construct is modelled, preserved or dropped by an explicit rule in
   `docs/architecture.adoc`; there is no fourth category.
5. **Deterministic.** No clock, no randomness, no host state in the package.
   Dates and authors come from the caller. The same model writes the same
   bytes everywhere.
6. **Evidence over claims.** A capability is claimed only when its gate
   evidence in the plan is complete. A pull request states what was run and
   what it reported. "Should work" is not evidence; a green check that did not
   exercise the behaviour is not evidence either.
7. **Every program runs in CI.** Examples, fuzz targets, scripts and oracle
   adapters all execute on every pull request, if only briefly. A skipped case
   carries a reason and an issue link where it is skipped and is printed by the
   harness. A heavy run lives in a scheduled workflow, never in `check`.
8. **Oracles are authorities, not obstacles.** When an oracle disagrees with
   the package, find the cause. Record an accepted deviation only with the
   oracle, the rule, the fixture, an upstream reference and the cause, in
   `conformance/accepted-deviations.json`. Never edit an adapter or a snapshot
   to make a comparison pass without explaining why the previous result was
   wrong.
9. **Ratchets, not baselines.** Every fuzz target measures its operation and
   asserts allocation ceilings in its source: linear ceilings for generated
   inputs, exact ceilings for declared examples. A ceiling only moves down;
   raising one needs its cause in the pull request. Snapshot expectations and
   fixture regenerations are reviewed as diffs; CI never updates anything.
10. **Fixtures are self-authored with provenance.** Only documents we wrote or
    generated enter `tests/fixtures/`, each with a provenance entry naming the
    producer, version, steps and purpose. No third-party documents, no personal
    data, fictional authors only. Treat fixture bytes as untrusted input.
11. **Small, complete slices.** One slice per pull request, named by its plan
    identifier. Finish the slice: code, tests, fixtures, fuzz property where a
    rule exists, documentation and plan status together. Scope that grows
    becomes a new slice proposed in the plan, not a larger pull request.
12. **Dependencies are pinned and evidenced.** Immutable release URLs only.
    Upgrading one is its own slice with the full check green on the current
    nightly. The package carries no compiler pin; only `scripts/` pin their
    tooling compiler, as the roc-automation manual prescribes.
13. **The manual is the documentation.** `docs/` is written for application
    authors and contributors, with care, and changes in the same pull request
    as the behaviour it describes. It is release-neutral and free of branch
    names, agent coordination, gate numbers and commit narratives, which
    belong in the plan and in pull requests. Name things by what they mean in
    a document, not by their XML spelling.
14. **Mechanical before guidance.** A rule that can be checked by a program
    goes into `scripts/src/Lint.roc` with its `expect`s; a check is more
    reliable than a sentence anyone can forget. Never weaken or skip a check
    to go green; fix the cause or change the rule with its reason.
15. **Roc the way the style guide says.** Follow
    https://gist.github.com/lukewilliamboswell/241a4e8adb7c89c7e0e02f1d303a8fa1:
    a module's type block is its public surface, configuration is a props
    record of defaulted fields beside the subject, closed sets are tags,
    failures are `Try` with structured tags that merge through `?`, and every
    top-level `expect` has a `##` doc comment. Keep accumulators uniquely
    owned so updates stay in place; the ceilings tell you when they do not.
16. **Lean pull-request CI.** `check`, the LibreOffice lane and the manual
    build, nothing heavier. No fuzz campaigns and no benchmarks in CI; if
    wanted later they are separate scheduled work proposed in the plan first.
17. **Untrusted input.** Every limit in `Limits` exists because a document can
    be hostile. Do not raise a limit, skip a bound or interpret document
    content as a path, URL or code to make a fixture pass.

## Before opening a pull request

- `blueprint run check` is green locally and the LibreOffice lane was run where
  the slice touches reading or writing.
- The manual chapter that describes the changed behaviour is updated.
- The plan's slice row is updated with status and the pull request link.
- The description has *Slice*, *Change*, *Evidence* and *Follow-ups*.
- Anything in the "stop and ask" list of the plan was asked before it was done.
