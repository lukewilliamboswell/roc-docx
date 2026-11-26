#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
	roc: "nightly-2026-11-25-d5a4f1e",
}

import cli.Cmd
import cli.Duration
import cli.Monotonic
import cli.OsStr
import cli.Path
import cli.Stderr
import cli.Stdout

## Build every fuzz suite, run its deterministic specifications, then check
## every member's examples and allocation ceilings and explore for at most
## one second and 64 inputs per member.
##
##     blueprint run fuzz-smoke
##
## Suite apps are named fuzz/*_suite.roc. The executable lists its members.
## Each member has its own corpus and reports under .roc-docx/fuzz/.
main! = |_args| {
	names = suite_names!()?
	if names.is_empty() {
		return fail!("no fuzz suites under fuzz/")
	}
	Stdout.line!("Running ${names.len().to_str()} fuzz suites, building up to ${concurrent_builds.to_str()} at once")?
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
		spec_ok = step!(["roc", "test", "fuzz/${name}_suite.roc"])?
		ok = if built {
			run_suite!(name)?
		} else {
			Bool.False
		}
		elapsed = Duration.to_millis(Monotonic.elapsed!(started))
		passed = ok and spec_ok
		Stdout.line!(" [${$position.to_str()}/${names.len().to_str()}] ${name} ${if (passed) "PASS" else "FAIL"} ${elapsed.to_str()}ms")?
		if !passed {
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

# Suites compile several properties at once. Limit concurrent LLVM
# builds to leave memory for the tests and the runner.
concurrent_builds : U64
concurrent_builds = 2

# The build command of a suite, without the program name.
build_args : Str -> List(Str)
build_args = |name| ["build", "--fuzz", "fuzz/${name}_suite.roc", "--output=.roc-docx/fuzz/${name}"]

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
					match output.status {
						Exited(0) => Ok(Bool.True)
						status => {
							Stderr.line!("error: roc build for ${name} ended with ${Str.inspect(status)}")?
							Ok(Bool.False)
						}
					}
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

# Every suite app under fuzz/, by file name.
suite_names! : () => Try(List(Str), _)
suite_names! = || {
	var $names = List.with_capacity(4)
	for entry in Path.list!(Path.utf8("fuzz"))? {
		name = Path.display(entry).split_on("/").last() ?? ""
		if name.ends_with("_suite.roc") {
			$names = List.append($names, name.drop_suffix("_suite.roc"))
		}
	}
	Ok($names)
}

run_suite! : Str => Try(Bool, _)
run_suite! = |suite| {
	executable = ".roc-docx/fuzz/${suite}"
	Stdout.line!("+ ${executable} --list-targets")?
	child = Cmd.new(OsStr.from_str(executable)).args([OsStr.from_str("--list-targets")]).stdout(Capture).spawn!()?
	output = child.wait!()?
	if output.status != Exited(0) {
		Stderr.line!("error: listing ${suite} members ended with ${Str.inspect(output.status)}")?
		return Ok(Bool.False)
	}
	inventory = Str.from_utf8(output.stdout_bytes)?
	members = inventory.split_on("\n").drop_if(Str.is_empty)
	if members.is_empty() {
		Stderr.line!("error: no targets in suite ${suite}")?
		return Ok(Bool.False)
	}
	var $passed = Bool.True
	for member in members {
		ok = run_member!(suite, executable, member)?
		$passed = $passed and ok
	}
	Ok($passed)
}

run_member! : Str, Str, Str => Try(Bool, _)
run_member! = |suite, executable, member| {
	selected = "--target=${member}"
	corpus = ".roc-docx/fuzz/corpus/${suite}/${member}"
	report = ".roc-docx/fuzz/reports/${suite}/${member}"
	check_report = "${report}-check"
	# Each bounded exploration starts from an empty corpus.
	for stale in [corpus, report, check_report] {
		match Path.delete_all!(Path.utf8(stale)) {
			_ => {}
		}
	}
	Path.create_all!(Path.utf8(corpus))?
	if !(step!([executable, selected, "check", "--report-dir=${check_report}"])?) {
		return Ok(Bool.False)
	}
	step!([executable, selected, "run", corpus, "--time=1", "--runs=64", "--max-input-size=4096", "--timeout=10", "--report-dir=${report}"])
}

# Print a command, run it with inherited output, and report whether it succeeded.
step! : List(Str) => Try(Bool, _)
step! = |argv| {
	Stdout.line!("+ ${Str.join_with(argv, " ")}")?
	match argv {
		[program, .. as rest] =>
			match Cmd.call!(OsStr.from_str(program), rest.map(OsStr.from_str)) {
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
