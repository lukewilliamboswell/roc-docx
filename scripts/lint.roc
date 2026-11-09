#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.27.0/9yjxqdGTP4xSpSEmDazwTmRsehfRZzA19pwEKkR6fj1g.tar.zst",
	roc: "nightly-2026-11-07-ad3a5d2",
}

import cli.Path
import cli.Stderr
import cli.Stdout
import src/Lint

## The repository's mechanical checks:
##
##     blueprint run lint
##
## Reads every Roc and AsciiDoc source and every .docx under the checked
## directories, runs the rules in scripts/src/Lint.roc, and prints each
## violation as `path:line: message`. Any violation fails the run.
main! : List([Utf8(Str), UnixBytes(List(U8)), WindowsU16s(List(U16))]) => Try({}, _)
main! = |_args| {
	stable_tag = Lint.stable_tag(Path.read_utf8!(Path.utf8("Blueprint.roc"))?) ? |_| BlueprintNamesNoStableCompiler
	var $sources = List.with_capacity(64)
	var $binaries = List.with_capacity(16)
	for root in ["package", "examples", "fuzz", "scripts", "docs", "tests"] {
		for file in files_under!(Path.utf8(root))? {
			path = Path.display(file)
			if path.ends_with(".roc") or path.ends_with(".adoc") {
				$sources = List.append($sources, { path, text: Path.read_utf8!(file)? })
			} else if path.ends_with(".docx") {
				$binaries = List.append($binaries, { path, bytes: Path.read_bytes!(file)? })
			}
		}
	}
	violations = Lint.check({ sources: $sources, binaries: $binaries, stable_tag })
	for violation in violations {
		Stderr.line!("${violation.path}:${violation.line.to_str()}: ${violation.message}")?
	}
	Stdout.line!("lint: ${$sources.len().to_str()} text sources, ${$binaries.len().to_str()} documents, ${violations.len().to_str()} violations")?
	if violations.is_empty() {
		Ok({})
	} else {
		Err(Exit(1))
	}
}

# Every file below a directory, in listing order.
files_under! : Path => Try(List(Path), _)
files_under! = |directory| {
	var $files = List.with_capacity(32)
	for entry in Path.list!(directory)? {
		if Path.is_dir!(entry)? {
			$files = List.concat($files, files_under!(entry)?)
		} else {
			$files = List.append($files, entry)
		}
	}
	Ok($files)
}
