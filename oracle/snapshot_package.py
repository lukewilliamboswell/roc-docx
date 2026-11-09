"""Collect the package's own roc-docx-snapshot/1 documents for comparison with the oracles'.

    snapshot_package.py DOCX                 print the package's snapshot of one document
    snapshot_package.py PATH... --out DIR    write DIR/<document>.json for every .docx under PATH

The package is the subject of the comparison, not an oracle: its snapshots
are written by the snapshot cases of the test driver (`roc tests/main.roc`)
under .roc-docx/snapshots/, and this adapter only finds the one whose
`document` names each requested .docx and copies it unchanged. It reads no
.docx and runs no package code, so the comparison sees exactly what the
package wrote. A document without a snapshot fails the run: run the cases
first.
"""

import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SNAPSHOTS = ROOT / ".roc-docx" / "snapshots"


def label(document):
    resolved = document.resolve()
    return resolved.relative_to(ROOT).as_posix() if resolved.is_relative_to(ROOT) else str(document)


def documents(paths):
    for raw in paths:
        path = pathlib.Path(raw)
        yield from (sorted(path.rglob("*.docx")) if path.is_dir() else [path])


def written():
    """The package's snapshots by the document they name."""
    found = {}
    for path in sorted(SNAPSHOTS.rglob("*.json")) if SNAPSHOTS.exists() else []:
        text = path.read_text()
        found[json.loads(text)["document"]] = text
    return found


def main(argv):
    out = None
    if "--out" in argv:
        out = pathlib.Path(argv[argv.index("--out") + 1])
        argv = argv[:argv.index("--out")] + argv[argv.index("--out") + 2:]
    if not argv or (out is None and len(argv) != 1):
        sys.exit(__doc__)
    snapshots = written()
    failed = 0
    for document in documents(argv):
        name = label(document)
        if name not in snapshots:
            print(f"FAIL {name}: no package snapshot under {SNAPSHOTS.relative_to(ROOT)}; run `roc tests/main.roc`", file=sys.stderr)
            failed += 1
        elif out is None:
            sys.stdout.write(snapshots[name])
        else:
            target = out / (name + ".json")
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(snapshots[name])
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
