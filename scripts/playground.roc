#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
	roc: "nightly-2026-11-25-d5a4f1e",
}

import cli.Cmd
import cli.OsStr

## Run the playground against the host compiler.
main! = |args| Cmd.call!("sh", ["-c", launch, "playground"].map(OsStr.from_str).concat(args))

launch =
	\\set -eu
	\\cd playground
	\\case "$1" in
	\\    expects) roc test main.roc ;;
	\\    check-build) roc signals.roc build ;;
	\\    build|serve|test) roc signals.roc "$@" ;;
	\\    *) exit 2 ;;
	\\esac
