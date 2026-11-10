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
##
## A build is single-threaded code generation and dominates the run, so up to
## `concurrent_builds` builds run at once with their output captured. Targets
## are still reported in order: a target's build output is printed when its
## build ends, then its examples and exploration run.
main! = |_args| {
	names = target_names!()?
	if names.is_empty() {
		return fail!("no fuzz targets under fuzz/")
	}
	Stdout.line!("Running ${names.len().to_str()} fuzz targets, building up to ${concurrent_builds.to_str()} at once")?
	Path.create_all!(Path.utf8(".roc-docx/fuzz/reports"))?
	var $builds = List.with_capacity(names.len())
	for name in names.take_first(concurrent_builds) {
		$builds = List.append($builds, start_build!(name))
	}
	var $failed = 0.U64
	var $position = 0.U64
	for name in names {
		started = Monotonic.now!()
		built = match $builds.get($position) {
			Ok(build) => finish_build!(name, build)?
			Err(_) => Bool.False
		}
		match names.get($position + concurrent_builds) {
			Ok(next) => {
				$builds = List.append($builds, start_build!(next))
			}
			Err(_) => {}
		}
		$position = $position + 1
		executable = ".roc-docx/fuzz/${name}"
		corpus = ".roc-docx/fuzz/corpus/${name}"
		report = ".roc-docx/fuzz/reports/${name}"
		check_report = ".roc-docx/fuzz/reports/${name}-check"
		# Every run explores from an empty corpus, as CI does, so inputs kept
		# by an earlier run cannot outgrow the time budget.
		for stale in [corpus, report, check_report] {
			match Path.delete_all!(Path.utf8(stale)) {
				_ => {}
			}
		}
		Path.create_all!(Path.utf8(corpus))?
		steps = [
			[executable, "check", "--report-dir=${check_report}"],
			[executable, "run", corpus, "--time=1", "--runs=64", "--max-input-size=4096", "--timeout=10", "--report-dir=${report}"],
		]
		var $ok = built
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

# The run takes as long as its slowest builds, so the bound admits every
# current target at once; it caps memory as targets are added (eleven builds
# peaked at about 4.6 GB together).
concurrent_builds : U64
concurrent_builds = 12

# The build command of a target, without the program name.
build_args : Str -> List(Str)
build_args = |name| ["build", "--fuzz", "fuzz/${name}/main.roc", "--output=.roc-docx/fuzz/${name}"]

# Start building a target with both output streams captured together.
start_build! = |name|
	Cmd.new("roc").args(build_args(name).map(OsStr.from_str)).stdout(Capture).stderr(MergeWithStdout).spawn!()

# Wait for a target's build, print its command and output, and report whether it succeeded.
finish_build! = |name, build| {
	Stdout.line!("+ roc ${Str.join_with(build_args(name), " ")}")?
	match build {
		Ok(child) =>
			match child.wait!() {
				Ok(output) => {
					Stdout.write_bytes!(output.stdout_bytes)?
					Ok(output.status == Exited(0))
				}
				Err(Interrupted) => Err(Interrupted)
				Err(err) => {
					Stderr.line!("error: cannot build ${name}: ${Str.inspect(err)}")?
					Ok(Bool.False)
				}
			}
		Err(Interrupted) => Err(Interrupted)
		Err(err) => {
			Stderr.line!("error: cannot run roc: ${Str.inspect(err)}")?
			Ok(Bool.False)
		}
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
