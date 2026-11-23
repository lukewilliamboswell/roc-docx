#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
	roc: "nightly-2026-11-18-a520eed",
}

import cli.Cmd
import cli.OsStr

## Run the playground against the host compiler. The November 22 nightly
## needs specialization for nested record defaults in the Signals platform
## and its markup dependency (roc-lang/roc#13372). Use the dev Wasm backend
## for the browser smoke build on this nightly so fuzz smoke can finish
## within the release job.
main! = |args| Cmd.call!("sh", ["-c", launch, "playground"].map(OsStr.from_str).concat(args))

launch =
	\\set -eu
	\\case "$(roc version)" in
	\\    *nightly-2026-11-22-3350b1c*)
	\\        compiler=$(command -v roc)
	\\        compiler=$(cd "$(dirname "$compiler")" && pwd)/$(basename "$compiler")
	\\        export ROC_DOCX_PLAYGROUND_COMPILER="$compiler"
	\\        export ROC_DOCX_PLAYGROUND_TASK="$1"
	\\        shim=$(mktemp -d)
	\\        trap 'rm -f "$shim/roc"; rmdir "$shim"' EXIT
	\\        cat > "$shim/roc" <<'EOF'
	\\#!/bin/sh
	\\case "$1" in
	\\    build|test)
	\\        command=$1
	\\        shift
	\\        if [ "$ROC_DOCX_PLAYGROUND_TASK" = check-build ] && [ "$command" = build ] &&
	\\           [ "$1" = --target=wasm32 ] && [ "$2" = --opt=size ]; then
	\\            shift 2
	\\            exec "$ROC_DOCX_PLAYGROUND_COMPILER" build --target=wasm32 --opt=dev --specialize=yes "$@"
	\\        fi
	\\        exec "$ROC_DOCX_PLAYGROUND_COMPILER" "$command" --specialize=yes "$@"
	\\        ;;
	\\    *) exec "$ROC_DOCX_PLAYGROUND_COMPILER" "$@" ;;
	\\esac
	\\EOF
	\\        chmod +x "$shim/roc"
	\\        if [ "$1" = check-build ]; then
	\\            printf "%s\n" "Using the dev Wasm backend for the playground smoke build."
	\\        fi
	\\        export PATH="$shim:$PATH"
	\\        ;;
	\\esac
	\\cd playground
	\\case "$1" in
	\\    expects) roc test main.roc ;;
	\\    check-build) roc signals.roc build ;;
	\\    build|serve|test) roc signals.roc "$@" ;;
	\\    *) exit 2 ;;
	\\esac
