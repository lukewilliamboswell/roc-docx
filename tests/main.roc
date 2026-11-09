app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.27.0/9yjxqdGTP4xSpSEmDazwTmRsehfRZzA19pwEKkR6fj1g.tar.zst",
	docx: "../package/main.roc",
}

import cli.Duration
import cli.Monotonic
import cli.Path
import cli.Stderr
import cli.Stdout
import docx.Docx
import docx.Document
import docx.Opc
import docx.Snapshot

## The data-driven cases, built once and run together from the repository
## root:
##
##     roc tests/main.roc            # every case against its expectation
##     roc tests/main.roc --update   # rewrite the expectations, to review as a diff
##
## Each family runs once for every `.docx` under `tests/fixtures/`, writes
## its output under `.roc-docx/<family>/` at the fixture's own path, and
## compares a report with the expectation under `tests/<family>/`.
##
## Pass-through: the fixture is parsed and written, and the written document
## must parse to a document equivalent to the original, without anything
## left to drop; writing it twice, and writing what was written, must give
## the same bytes. The expectation records what reading dropped and the
## written package's parts and digest, so a change in what the writer
## produces is a reviewed diff. The written documents are what the schema
## and LibreOffice oracles read.
##
## Snapshots: the fixture's semantic snapshot, which is its own expectation
## and what `oracle/compare_snapshots.py` compares with the oracles' readings
## as the `package` adapter.
main! : List([Utf8(Str), UnixBytes(List(U8)), WindowsU16s(List(U16))]) => Try({}, _)
main! = |args| {
	update = args.any(|arg| is_update(arg))
	fixtures = sorted(files_under!(Path.utf8("tests/fixtures"))?.map(Path.display).keep_if(|path| path.ends_with(".docx")))
	var $failed = 0.U64
	for family in families {
		$failed = $failed + run_family!(family, fixtures, update)?
	}
	if $failed > 0 {
		Err(Exit(1))
	} else {
		Ok({})
	}
}

# A family of cases: what one fixture's case writes, and the report its
# expectation, `tests/<name>/<fixture><extension>`, records.
Family : {
	name : Str,
	extension : Str,
	run : Str, List(U8) -> Try({ output : List(U8), output_extension : Str, report : Str }, Str),
}

families : List(Family)
families = [
	{ name: "passthrough", extension: ".txt", run: |_, bytes| pass_through(bytes).map_ok(|{ written, report }| { output: written, output_extension: "", report }) },
	{ name: "snapshots", extension: ".json", run: |fixture, bytes| snapshot(fixture, bytes).map_ok(|json| { output: json.to_utf8(), output_extension: ".json", report: json }) },
]

# Run a family's case for every fixture and report each; the number that failed.
run_family! : Family, List(Str), Bool => Try(U64, _)
run_family! = |family, fixtures, update| {
	output_root = ".roc-docx/${family.name}"
	match Path.delete_all!(Path.utf8(output_root)) {
		_ => {}
	}
	Stdout.line!("${family.name}: ${fixtures.len().to_str()} cases${if (update) ", updating expectations" else ""}")?
	var $failed = 0.U64
	var $updated = 0.U64
	var $position = 0.U64
	for fixture in fixtures {
		$position = $position + 1
		started = Monotonic.now!()
		document = Str.drop_prefix(fixture, "tests/fixtures/")
		outcome = (family.run)(fixture, Path.read_bytes!(Path.utf8(fixture))?)
		status = match outcome {
			Ok({ output, output_extension, report }) => {
				written = "${output_root}/${document}${output_extension}"
				Path.create_all!(Path.utf8(directory_of(written)))?
				Path.write_bytes!(Path.utf8(written), output)?
				expectation = Path.utf8("tests/${family.name}/${Str.drop_suffix(document, ".docx")}${family.extension}")
				expected = Path.read_utf8!(expectation) ?? ""
				if expected == report {
					"PASS"
				} else if update {
					Path.create_all!(Path.utf8(directory_of(Path.display(expectation))))?
					Path.write_utf8!(expectation, report)?
					$updated = $updated + 1
					"UPDATED"
				} else {
					$failed = $failed + 1
					Stderr.line!("${Path.display(expectation)} expects:\n${expected}but the case reports:\n${report}")?
					"FAIL"
				}
			}

			Err(problem) => {
				$failed = $failed + 1
				Stderr.line!("${fixture}: ${problem}")?
				"FAIL"
			}
		}
		elapsed = Duration.to_millis(Monotonic.elapsed!(started))
		Stdout.line!(" [${$position.to_str()}/${fixtures.len().to_str()}] ${document} ${status} ${elapsed.to_str()}ms")?
	}
	Stdout.line!("Summary: ${fixtures.len().to_str()} cases, ${(fixtures.len() - $failed - $updated).to_str()} passed, ${$updated.to_str()} updated, ${$failed.to_str()} failed, 0 skipped")?
	Ok($failed)
}

# A fixture's snapshot, naming it by its path from the repository root as the
# oracle adapters do.
snapshot : Str, List(U8) -> Try(Str, Str)
snapshot = |fixture, bytes| {
	parsed = Docx.parse(bytes) ? |problem| "the fixture does not parse: ${Str.inspect(problem)}"
	Ok(Snapshot.json(parsed.document, { path: fixture, version: "working tree" }))
}

# Parse a document, write it, and check the pass-through properties; the
# written bytes and the report its expectation records, or what went wrong.
pass_through : List(U8) -> Try({ written : List(U8), report : Str }, Str)
pass_through = |bytes| {
	parsed = Docx.parse(bytes) ? |problem| "the fixture does not parse: ${Str.inspect(problem)}"
	written = Docx.to_bytes(parsed.document) ? |problem| "the document does not write: ${Str.inspect(problem)}"
	if Docx.to_bytes(parsed.document) != Ok(written) {
		return Err("writing the document twice gave different bytes")
	}
	again = Docx.parse(written) ? |problem| "the written document does not parse: ${Str.inspect(problem)}"
	if !Document.equivalent(parsed.document, again.document) {
		return Err("the written document is not equivalent to the fixture")
	}
	if !again.diagnostics.is_empty() {
		return Err("the written document still has content to drop: ${Str.inspect(again.diagnostics)}")
	}
	if Docx.to_bytes(again.document) != Ok(written) {
		return Err("writing the written document gave different bytes")
	}
	parts = Opc.parts(Opc.open(written, {}) ? |problem| "the written package does not open: ${Str.inspect(problem)}")
	lines = List.join([
		["written: ${written.len().to_str()} bytes, FNV-1a 64 ${hex(fnv1a(written))}"],
		parsed.diagnostics.map(describe),
		parts.map(|part| "part: ${part.name} ${part.size.to_str()} bytes ${part.content_type}"),
	])
	Ok({ written, report: Str.join_with(lines.map(|line| "${line}\n"), "") })
}

describe : Document.Diagnostic -> Str
describe = |diagnostic|
	match diagnostic {
		Dropped({ part, content, count }) => {
			kind = match content {
				RevisionSaveIds => "revision save identifiers"
				RenderedPageBreaks => "rendered page breaks"
				ProofingMarks => "proofing marks"
				GoBackBookmark => "_GoBack bookmarks"
			}
			"dropped: ${part} ${count.to_str()} ${kind}"
		}
	}

fnv1a : List(U8) -> U64
fnv1a = |bytes| bytes.fold(14_695_981_039_346_656_037, |hash, byte| hash.bitwise_xor(byte.to_u64()).times_wrap(1_099_511_628_211))

hex : U64 -> Str
hex = |value| {
	digits = "0123456789abcdef".to_utf8()
	var $out = List.with_capacity(16)
	var $rest = value
	for _ in List.repeat(0, 16) {
		$out = List.prepend($out, digits.get(($rest % 16)) ?? '0')
		$rest = $rest // 16
	}
	Str.from_utf8($out) ?? ""
}

is_update : [Utf8(Str), UnixBytes(List(U8)), WindowsU16s(List(U16))] -> Bool
is_update = |arg|
	match arg {
		Utf8(text) => text == "--update"
		UnixBytes(bytes) => bytes == "--update".to_utf8()
		WindowsU16s(units) => units == "--update".to_utf8().map(|byte| byte.to_u16())
	}

directory_of : Str -> Str
directory_of = |path|
	match path.split_last("/") {
		Ok({ before, after: _ }) => before
		Err(_) => "."
	}

# Paths in byte order, so the cases run in the same order on every host.
sorted : List(Str) -> List(Str)
sorted = |paths|
	paths.sort_with(
		|a, b| {
			left = a.to_utf8()
			right = b.to_utf8()
			var $index = 0.U64
			while $index < left.len() and $index < right.len() {
				x = left.get($index) ?? 0
				y = right.get($index) ?? 0
				if x != y {
					return if (x < y) Before else After
				}
				$index = $index + 1
			}
			if (left.len() < right.len()) Before else if (left.len() > right.len()) After else Same
		},
	)

# Every file below a directory.
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
