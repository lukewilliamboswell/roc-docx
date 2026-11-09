#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.27.0/9yjxqdGTP4xSpSEmDazwTmRsehfRZzA19pwEKkR6fj1g.tar.zst",
	roc: "nightly-2026-11-07-ad3a5d2",
}

import cli.Cmd
import cli.Duration
import cli.Monotonic
import cli.OsStr
import cli.Stderr
import cli.Stdout

## Everything a pull request must pass, as one task:
##
##     blueprint run check
##
## Each check is a command run in the repository root with inherited output.
## `roc` is the host's latest nightly; `roc-stable`, `pandoc` and
## `release-package` are the programs Blueprint fetched for the `dev`
## environment; `python3` and `xmllint` come from the machine. Every check
## runs even after a failure, so one run reports everything that is wrong.
checks : List({ name : Str, argv : List(Str) })
checks = [
	# The schema oracle's standards corpus, verified against the ledger.
	{ name: "oracle-provision", argv: ["python3", "-I", "oracle/provision.py"] },
	{ name: "fmt", argv: ["roc", "fmt", "--check", "package", "examples", "fuzz"] },
	{ name: "fmt-scripts", argv: ["roc-stable", "fmt", "--check", "scripts"] },
	# The mechanical checks in scripts/src/Lint.roc, and that module's own expects.
	{ name: "lint", argv: ["scripts/lint.roc"] },
	{ name: "scripts-test", argv: ["roc-stable", "test", "scripts/src/Lint.roc"] },
	{ name: "test", argv: ["roc", "test", "package/main.roc"] },
	# Every example against its recorded output in tests/spec.json.
	{ name: "examples", argv: ["release-package", "test-examples"] },
	# Every fuzz target: build, declared examples, a one-second bounded exploration.
	{ name: "fuzz-smoke", argv: ["scripts/fuzz_smoke.roc"] },
	# Committed pandoc fixtures match regeneration and every fixture has provenance.
	{ name: "fixtures-check", argv: ["python3", "-I", "oracle/make_fixtures.py", "--check"] },
	# Every XML part of every fixture validates against the ECMA-376 schemas.
	{ name: "oracle-schema", argv: ["python3", "-I", "oracle/validate_schema.py", "tests/fixtures"] },
	# pandoc's snapshot of every fixture conforms to the snapshot contract.
	{ name: "oracle-snapshot", argv: ["python3", "-I", "oracle/compare_snapshots.py", "--lane", "pandoc", "tests/fixtures"] },
]

main! = |_args| {
	Stdout.line!("Running ${checks.len().to_str()} checks")?
	var $failed = List.with_capacity(8)
	var $position = 0.U64
	for check in checks {
		$position = $position + 1
		Stdout.line!("\n== [${$position.to_str()}/${checks.len().to_str()}] ${check.name}: ${Str.join_with(check.argv, " ")}")?
		started = Monotonic.now!()
		ok = run!(check.argv)?
		elapsed = Duration.to_millis(Monotonic.elapsed!(started))
		Stdout.line!("${if (ok) "PASS" else "FAIL"} ${check.name} ${elapsed.to_str()}ms")?
		if !ok {
			$failed = List.append($failed, check.name)
		}
	}
	Stdout.line!("\nSummary: ${(checks.len() - $failed.len()).to_str()} passed, ${$failed.len().to_str()} failed")?
	if $failed.is_empty() {
		Ok({})
	} else {
		Stderr.line!("Failed: ${Str.join_with($failed, ", ")}")?
		Err(Exit(1))
	}
}

# Run a command with inherited output and report whether it succeeded.
run! : List(Str) => Try(Bool, _)
run! = |argv| {
	program = argv.first().map_err(|_| EmptyCommand)?
	match Cmd.new(OsStr.from_str(program)).args(List.drop_first(argv, 1).map(OsStr.from_str)).call!() {
		Ok({}) => Ok(Bool.True)
		Err(BadExitStatus(_)) => Ok(Bool.False)
		Err(CmdErr(err)) => {
			Stderr.line!("error: cannot run ${program}: ${Str.inspect(err)}")?
			Ok(Bool.False)
		}
		Err(Interrupted) => Err(Interrupted)
	}
}
