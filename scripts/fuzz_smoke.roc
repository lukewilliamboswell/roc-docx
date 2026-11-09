#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.27.0/9yjxqdGTP4xSpSEmDazwTmRsehfRZzA19pwEKkR6fj1g.tar.zst",
	roc: "nightly-2026-11-07-ad3a5d2",
}

import cli.Cmd
import cli.Duration
import cli.Monotonic
import cli.OsStr
import cli.Path
import cli.Stderr
import cli.Stdout

## The smoke run of every fuzz target: build it with the host `roc`, run its
## declared examples with their allocation ceilings, then explore for at most
## one second and 64 inputs so the target keeps building and exercising its
## property. This is the only fuzzing pull-request CI does.
##
##     blueprint run fuzz-smoke
##
## A target is `fuzz/<name>/main.roc`. Executables, corpora and reports go
## under `.roc-docx/fuzz/`. A build failure, failed example, exceeded ceiling,
## finding or inconclusive exploration fails the run. Targets keep no baseline
## files; roc-fuzz reports them as unbaselined, which is expected.
main! = |_args| {
	names = target_names!()?
	if names.is_empty() {
		return fail!("no fuzz targets under fuzz/")
	}
	Stdout.line!("Running ${names.len().to_str()} fuzz targets")?
	Path.create_all!(Path.utf8(".roc-docx/fuzz/reports"))?
	var $failed = 0.U64
	var $position = 0.U64
	for name in names {
		$position = $position + 1
		started = Monotonic.now!()
		executable = ".roc-docx/fuzz/${name}"
		corpus = ".roc-docx/fuzz/corpus/${name}"
		report = ".roc-docx/fuzz/reports/${name}"
		Path.create_all!(Path.utf8(corpus))?
		match Path.delete_all!(Path.utf8(report)) {
			_ => {}
		}
		steps = [
			["roc", "build", "--fuzz", "fuzz/${name}/main.roc", "--output=${executable}"],
			[executable, "check"],
			[executable, "run", corpus, "--time=1", "--runs=64", "--max-input-size=4096", "--timeout=10", "--report-dir=${report}"],
		]
		var $ok = Bool.True
		for argv in steps {
			if $ok {
				$ok = step!(argv)?
			}
		}
		elapsed = Duration.to_millis(Monotonic.elapsed!(started))
		Stdout.line!(" [${$position.to_str()}/${names.len().to_str()}] ${name} ${if ($ok) "PASS" else "FAIL"} ${elapsed.to_str()}ms")?
		if !$ok {
			$failed = $failed + 1
		}
	}
	Stdout.line!("Summary: ${(names.len() - $failed).to_str()} passed, ${$failed.to_str()} failed")?
	if $failed > 0 {
		Err(Exit(1))
	} else {
		Ok({})
	}
}

# Every directory under fuzz/ that holds a main.roc, by name, in order.
target_names! : () => Try(List(Str), _)
target_names! = || {
	var $names = List.with_capacity(8)
	for entry in Path.list!(Path.utf8("fuzz"))? {
		if Path.is_file!(Path.join(entry, "main.roc"))? {
			$names = match Path.display(entry).split_on("/").last() {
				Ok(name) => List.append($names, name)
				Err(_) => $names
			}
		}
	}
	Ok($names)
}

# Print a command, run it with inherited output, and report whether it succeeded.
step! : List(Str) => Try(Bool, _)
step! = |argv| {
	Stdout.line!("+ ${Str.join_with(argv, " ")}")?
	match argv {
		[program, .. as rest] =>
			match Cmd.new(OsStr.from_str(program)).args(rest.map(OsStr.from_str)).call!() {
				Ok({}) => Ok(Bool.True)
				Err(BadExitStatus(_)) => Ok(Bool.False)
				Err(CmdErr(err)) => {
					Stderr.line!("error: cannot run ${program}: ${Str.inspect(err)}")?
					Ok(Bool.False)
				}
				Err(Interrupted) => Err(Interrupted)
			}
		[] => Ok(Bool.False)
	}
}

fail! = |message| {
	Stderr.line!("error: ${message}")?
	Err(Exit(1))
}
