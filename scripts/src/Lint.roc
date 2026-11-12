## The repository's mechanical checks, as pure rules over source text.
##
## `scripts/lint.roc` reads the files and prints what these rules return as
## `path:line: message`. A rule lives here so that it has `expect`s of its
## own and so that a reviewer can read what is enforced in one place.
Lint :: [].{

	## A text source as the driver found it, with a repository-relative path.
	Source : { path : Str, text : Str }

	## A binary source, for the fixture-identity rule.
	Binary : { path : Str, bytes : List(U8) }

	## One rule violation.
	Violation : { path : Str, line : U64, message : Str }

	## Every violation across the repository.
	check : { sources : List(Source), binaries : List(Binary), stable_tag : Str } -> List(Violation)
	check = |{ sources, binaries, stable_tag }| {
		per_source = sources.fold(
			[],
			|found, source|
				[
					Lint.roc_pin(source, stable_tag),
					Lint.relative_package(source),
					Lint.no_crash_in_package(source),
					Lint.no_dbg(source),
					Lint.fuzz_target_shape(source),
					Lint.todo_has_issue(source),
					Lint.expect_doc(source),
				].fold(found, |acc, more| List.concat(acc, more)),
		)
		[
			per_source,
			Lint.consistent_urls(sources),
			Lint.chapters_included(sources),
			Lint.fuzz_inventory(sources),
			Lint.manual_snippets(sources),
			Lint.owned_loop_state(sources),
			Lint.docx_identity(binaries),
		].fold([], |acc, more| List.concat(acc, more))
	}

	## The tooling compiler `Blueprint.roc` names with `Recipes.roc_nightly("...")`.
	stable_tag : Str -> Try(Str, [NoStableCompiler])
	stable_tag = |blueprint| {
		{ before: _, after } = blueprint.split_first("Recipes.roc_nightly(\"") ? |_| NoStableCompiler
		{ before, after: _ } = after.split_first("\")") ? |_| NoStableCompiler
		Ok(before)
	}

	## Only scripts pin a compiler, and they pin the tooling compiler.
	roc_pin : Source, Str -> List(Violation)
	roc_pin = |source, tag|
		if source.path.starts_with("scripts/") {
			if is_app(source.text) and !source.text.contains("roc: \"${tag}\"") {
				[{ path: source.path, line: 1, message: "scripts pin the tooling compiler: roc: \"${tag}\"" }]
			} else {
				[]
			}
		} else {
			matching_lines(source, |line| line.contains("roc: \""), "only scripts under scripts/ pin a compiler")
		}

	## Examples and fuzz targets depend on the package by relative path.
	relative_package : Source -> List(Violation)
	relative_package = |source|
		if (source.path.starts_with("examples/") or source.path.starts_with("fuzz/")) and is_app(source.text) {
			by_url = matching_lines(source, |line| line.contains("roc-docx/releases/download"), "depend on the package by relative path, not a release URL")
			has_relative = source.text.split_on("\n").any(|line| line.contains("docx: \"../") and line.contains("package/main.roc\""))
			if has_relative {
				by_url
			} else {
				List.append(by_url, { path: source.path, line: 1, message: "an application depends on the package as docx: \"../../package/main.roc\"" })
			}
		} else {
			[]
		}

	## One release URL per dependency, everywhere it is named.
	consistent_urls : List(Source) -> List(Violation)
	consistent_urls = |sources| {
		mentions = sources.fold([], |found, source| if (is_this_module(source)) found else List.concat(found, release_urls(source)))
		mentions.fold(
			[],
			|found, mention| {
				first = mentions.find_first(|other| other.dependency == mention.dependency) ?? mention
				if first.url == mention.url {
					found
				} else {
					List.append(found, { path: mention.path, line: mention.line, message: "${mention.dependency} is also pinned as ${first.url} in ${first.path}" })
				}
			},
		)
	}

	## The never-crash invariant: nothing under package/ may crash.
	no_crash_in_package : Source -> List(Violation)
	no_crash_in_package = |source|
		if source.path.starts_with("package/") {
			matching_lines(source, |line| !is_comment(line) and line.contains("crash"), "package code never crashes; return an error")
		} else {
			[]
		}

	## No debugging output is committed.
	no_dbg : Source -> List(Violation)
	no_dbg = |source|
		if is_this_module(source) {
			[]
		} else {
			matching_lines(source, |line| !is_comment(line) and (line.trim().starts_with("dbg ") or line.contains(" dbg ") or line.contains("dbg(")), "remove dbg before committing")
		}

	## Every fuzz target declares examples and carries a measurement or ceiling.
	fuzz_target_shape : Source -> List(Violation)
	fuzz_target_shape = |source|
		if source.path.starts_with("fuzz/") and source.path.ends_with("/main.roc") {
			examples = if !source.text.contains("examples: [") or source.text.contains("examples: []") {
				[{ path: source.path, line: 1, message: "a fuzz target declares at least one example" }]
			} else {
				[]
			}
			if source.text.contains("Fuzz.measure!(") or source.text.contains("Fuzz.expect_allocs_at_most!(") {
				examples
			} else {
				List.append(examples, { path: source.path, line: 1, message: "a fuzz target measures allocations or asserts a ceiling" })
			}
		} else {
			[]
		}

	## A TODO in Roc source names the issue that tracks it.
	todo_has_issue : Source -> List(Violation)
	todo_has_issue = |source|
		if source.path.ends_with(".roc") and !is_this_module(source) {
			matching_lines(source, |line| (line.contains("TODO") or line.contains("FIXME")) and !line.contains("/issues/"), "a TODO links the GitHub issue that tracks it")
		} else {
			[]
		}

	## Every top-level expect in the package has a doc comment naming it.
	expect_doc : Source -> List(Violation)
	expect_doc = |source|
		if source.path.starts_with("package/") and source.path.ends_with(".roc") {
			lines = source.text.split_on("\n")
			lines.fold_with_index(
				[],
				|found, line, index| {
					previous = if (index == 0) "" else (lines.get(index - 1) ?? "")
					if line.starts_with("expect") and !previous.starts_with("##") {
						List.append(found, { path: source.path, line: index + 1, message: "a top-level expect has a ## doc comment that names it" })
					} else {
						found
					}
				},
			)
		} else {
			[]
		}

	## Every manual chapter opens with a title and is included by the index;
	## every release note under docs/releases/ is included by the releases chapter.
	chapters_included : List(Source) -> List(Violation)
	chapters_included = |sources| {
		text_of = |path| (sources.find_first(|source| source.path == path) ?? { path: "", text: "" }).text
		index_text = text_of("docs/index.adoc")
		releases_text = text_of("docs/releases.adoc")
		sources.fold(
			[],
			|found, source|
				if source.path.starts_with("docs/") and source.path.ends_with(".adoc") and source.path != "docs/index.adoc" {
					file = source.path.drop_prefix("docs/")
					titled = if source.text.starts_with("= ") {
						[]
					} else {
						[{ path: source.path, line: 1, message: "a chapter opens with a single = Title" }]
					}
					{ includer, included } = if file.starts_with("releases/") {
						{ includer: "docs/releases.adoc", included: releases_text.contains("include::${file}[") }
					} else {
						{ includer: "docs/index.adoc", included: index_text.contains("include::${file}[") }
					}
					if included {
						List.concat(found, titled)
					} else {
						List.append(List.concat(found, titled), { path: source.path, line: 1, message: "${includer} includes every chapter" })
					}
				} else {
					found
				},
		)
	}

	## The architecture's fuzz inventory names every fuzz target, a
	## `fuzz/<name>/main.roc`, in a row of its own, and names no other.
	fuzz_inventory : List(Source) -> List(Violation)
	fuzz_inventory = |sources| {
		architecture = "docs/architecture.adoc"
		text = (sources.find_first(|source| source.path == architecture) ?? { path: "", text: "" }).text
		inventory = match text.split_first("|Target |Property\n") {
			Ok({ before: _, after }) =>
				match after.split_first("|===") {
					Ok({ before, after: _ }) => before
					Err(NotFound) => after
				}

			Err(NotFound) => ""
		}
		rows = inventory.split_on("\n").keep_oks(
			|line|
				match line.drop_prefix("|`").split_first("` |") {
					Ok({ before, after: _ }) if line.starts_with("|`") => Ok(before)
					_ => Err(NotARow)
				},
		)
		found_targets = sources.keep_oks(
			|source|
				if source.path.starts_with("fuzz/") and source.path.ends_with("/main.roc") {
					Ok(source.path.drop_prefix("fuzz/").drop_suffix("/main.roc"))
				} else {
					Err(NotATarget)
				},
		)
		missing = found_targets.drop_if(|name| rows.contains(name)).map(|name| { path: "fuzz/${name}/main.roc", line: 1, message: "${architecture}'s fuzz inventory names every fuzz target" })
		stale = rows.drop_if(|name| found_targets.contains(name)).map(|name| { path: architecture, line: 1, message: "the fuzz inventory names `${name}`, which is not a target under fuzz/" })
		List.concat(missing, stale)
	}

	## Every Roc listing in a manual chapter is included from a program that
	## `check` compiles and runs: a tagged region of `tests/manual.roc`, or an
	## example. The region must exist. Release notes are exempt, because the
	## release fills in their package URL.
	manual_snippets : List(Source) -> List(Violation)
	manual_snippets = |sources|
		sources.fold(
			[],
			|found, source|
				if source.path.starts_with("docs/") and source.path.ends_with(".adoc") and !source.path.starts_with("docs/releases/") {
					lines = source.text.split_on("\n")
					lines.fold_with_index(
						found,
						|acc, line, index|
							if line.trim() == "[source,roc]" {
								at = |offset| lines.get(index + offset) ?? ""
								problem = if at(1) != "----" or at(3) != "----" {
									Err("a Roc listing is one include between ---- lines")
								} else {
									included_region(sources, at(2))
								}
								match problem {
									Ok({}) => acc
									Err(message) => List.append(acc, { path: source.path, line: index + 1, message })
								}
							} else {
								acc
							},
					)
				} else {
					found
				},
		)

	## A loop in the package does not start from a parameter as it was given
	## when the parameter's type is a record holding a list, set, dictionary or
	## string: such a loop can copy those collections at every update instead
	## of updating them in place. It starts from an owned copy, a record update
	## of the parameter. The record types are those the package declares.
	owned_loop_state : List(Source) -> List(Violation)
	owned_loop_state = |sources| {
		modules = sources.keep_if(|source| source.path.starts_with("package/") and source.path.ends_with(".roc"))
		carrying = modules.fold([], |names, source| List.concat(names, collection_records(source.text)))
		modules.fold(
			[],
			|found, source| {
				lines = source.text.split_on("\n")
				lines.fold_with_index(
					found,
					|acc, line, index|
						match loop_start(line) {
							Ok(name) =>
								match parameter_type(lines, index, name) {
									Ok(type) if (type.starts_with("{") and holds_collection(type)) or carrying.any(|record| record == unqualified(type)) =>
										List.append(acc, { path: source.path, line: index + 1, message: "a loop starting from the parameter ${name} as given can copy its collections at every update; start from an owned copy, a record update such as { ..${name}, field: ${name}.field }" })

									_ => acc
								}

							Err(_) => acc
						},
				)
			},
		)
	}

	## A .docx outside the fixture corpus is a fixture's bytes, so it has that
	## fixture's provenance.
	docx_identity : List(Binary) -> List(Violation)
	docx_identity = |binaries| {
		fixtures = binaries.keep_if(|binary| binary.path.starts_with("tests/fixtures/"))
		binaries.fold(
			[],
			|found, binary|
				if binary.path.starts_with("tests/fixtures/") or fixtures.any(|fixture| fixture.bytes == binary.bytes) {
					found
				} else {
					List.append(found, { path: binary.path, line: 1, message: "a .docx outside tests/fixtures is byte-identical to a fixture" })
				},
		)
	}
}

# Whether an include line names a compiled program and, with a tag, a region
# that program has.
included_region : List(Lint.Source), Str -> Try({}, Str)
included_region = |sources, line| {
	{ before: _, after } = line.split_first("include::../") ? |_| "a Roc listing includes a region of tests/manual.roc or an example, so that check compiles it"
	{ before: path, after: attributes } = after.split_first("[") ? |_| "an include names its attributes in brackets"
	if path != "tests/manual.roc" and !path.starts_with("examples/") {
		return Err("a Roc listing includes a region of tests/manual.roc or an example, so that check compiles it")
	}
	text = (sources.find_first(|source| source.path == path) ? |_| "${path} does not exist").text
	match attributes.split_first("tag=") {
		Ok({ before: _, after: rest }) => {
			tag = (rest.split_first(",") ?? (rest.split_first("]") ?? { before: rest, after: "" })).before
			if text.contains("# tag::${tag}[]") and text.contains("# end::${tag}[]") {
				Ok({})
			} else {
				Err("${path} has no region tagged ${tag}")
			}
		}

		Err(_) => Ok({})
	}
}

is_app : Str -> Bool
is_app = |text| text.split_on("\n").any(|line| line.starts_with("app ["))

# The rules' own source quotes the patterns it looks for.
is_this_module : Lint.Source -> Bool
is_this_module = |source| source.path == "scripts/src/Lint.roc"

is_comment : Str -> Bool
is_comment = |line| line.trim().starts_with("#")

# The name a line's loop variable starts from, when the line is
# `var $variable = name` with a bare name.
loop_start : Str -> Try(Str, [NotALoopStart])
loop_start = |line| {
	{ before: _, after } = line.trim().split_first("var $") ? |_| NotALoopStart
	{ before: variable, after: name } = after.split_first(" = ") ? |_| NotALoopStart
	if (line.trim().starts_with("var $") and is_name(variable) and is_name(name)) Ok(name) else Err(NotALoopStart)
}

# A lowercase identifier: letters, digits and underscores, first a letter.
is_name : Str -> Bool
is_name = |text| {
	bytes = text.to_utf8()
	match bytes.first() {
		Ok(first) => first >= 'a' and first <= 'z' and bytes.all(|byte| (byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9') or byte == '_')
		Err(_) => Bool.False
	}
}

# The tabs a line begins with.
indent : Str -> U64
indent = |line| {
	var $count = 0.U64
	var $leading = Bool.True
	for byte in line.to_utf8() {
		if $leading and byte == '\t' {
			$count = $count + 1
		} else {
			$leading = Bool.False
		}
	}
	$count
}

# The annotated type of `name` as a parameter of the function around line
# `index`: the nearest line above, indented less, that starts a function
# `f = |...|` taking `name`, whose line before is the annotation `f : ...`.
parameter_type : List(Str), U64, Str -> Try(Str, [NotAParameter])
parameter_type = |lines, index, name| {
	depth = indent(lines.get(index) ?? "")
	var $at = index
	while $at > 0 {
		$at = $at - 1
		line = lines.get($at) ?? ""
		if indent(line) < depth and line.contains(" = |") {
			{ before: function, after } = line.split_first(" = |") ? |_| NotAParameter
			{ before: listed, after: _ } = after.split_first("|") ? |_| NotAParameter
			parameters = listed.split_on(",").map(|parameter| parameter.trim())
			match parameters.find_first_index(|parameter| parameter == name) {
				Ok(position) => {
					annotation = (lines.get($at - 1) ?? "").trim()
					{ before: _, after: signature } = annotation.split_first("${function.trim()} : ") ? |_| NotAParameter
					return Ok(parameter_types(signature).get(position) ? |_| NotAParameter)
				}

				Err(_) => {}
			}
		}
	}
	Err(NotAParameter)
}

# The parameter types of a function's signature, split at the commas outside
# brackets before its arrow.
parameter_types : Str -> List(Str)
parameter_types = |signature| {
	var $types = List.with_capacity(4)
	var $current = List.with_capacity(signature.count_utf8_bytes())
	var $depth = 0.U64
	var $previous = 0.U8
	var $done = Bool.False
	for byte in signature.to_utf8() {
		if !$done {
			if byte == '(' or byte == '[' or byte == '{' {
				$depth = $depth + 1
			} else if (byte == ')' or byte == ']' or byte == '}') and $depth > 0 {
				$depth = $depth - 1
			}
			if $depth == 0 and $previous == '-' and byte == '>' {
				$current = $current.drop_last(1)
				$done = Bool.True
			} else if $depth == 0 and byte == ',' {
				$types = List.append($types, (Str.from_utf8($current) ?? "").trim())
				$current = List.with_capacity(signature.count_utf8_bytes())
			} else {
				$current = List.append($current, byte)
			}
			$previous = byte
		}
	}
	List.append($types, (Str.from_utf8($current) ?? "").trim())
}

# The records a source declares whose fields hold a list, set, dictionary or
# string, by name.
collection_records : Str -> List(Str)
collection_records = |text| {
	lines = text.split_on("\n")
	lines.fold_with_index(
		[],
		|found, line, index|
			match line.trim().split_first(" : {") {
				Ok({ before: name, after: rest }) if is_type_name(name) => {
					body = if rest.trim().ends_with("}") {
						rest
					} else {
						lines.drop_first(index + 1).take_first(lines.drop_first(index + 1).find_first_index(|inner| inner.trim() == "}") ?? 0).fold("", |joined, inner| Str.concat(joined, inner))
					}
					if (holds_collection(body)) List.append(found, name) else found
				}

				_ => found
			},
	)
}

# An uppercase identifier, as a type alias is named.
is_type_name : Str -> Bool
is_type_name = |text| {
	bytes = text.to_utf8()
	match bytes.first() {
		Ok(first) => first >= 'A' and first <= 'Z' and bytes.all(|byte| (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or (byte >= '0' and byte <= '9'))
		Err(_) => Bool.False
	}
}

# Whether a type's text names a list, set, dictionary or string.
holds_collection : Str -> Bool
holds_collection = |type| type.contains("List(") or type.contains("Set(") or type.contains("Dict(") or type.contains(": Str")

# A type's name without its module.
unqualified : Str -> Str
unqualified = |type|
	match type.split_last(".") {
		Ok({ before: _, after }) => after
		Err(_) => type
	}

# Every line of a source that satisfies `select`, as a violation with `message`.
matching_lines : Lint.Source, (Str -> Bool), Str -> List(Lint.Violation)
matching_lines = |source, select, message|
	source.text.split_on("\n").fold_with_index(
		[],
		|found, line, index| if select(line) {
			List.append(found, { path: source.path, line: index + 1, message })
		} else {
			found
		},
	)

# Every GitHub release URL in a source, keyed by its owner/repo.
release_urls : Lint.Source -> List({ dependency : Str, url : Str, path : Str, line : U64 })
release_urls = |source|
	source.text.split_on("\n").fold_with_index(
		[],
		|found, line, index|
			match line.split_first("https://github.com/") {
				Ok({ before: _, after }) =>
					match after.split_first("/releases/download/") {
						Ok({ before: dependency, after: rest }) => {
							tail = (rest.split_first("\"") ?? { before: rest, after: "" }).before
							List.append(found, { dependency, url: "https://github.com/${dependency}/releases/download/${tail}", path: source.path, line: index + 1 })
						}
						Err(_) => found
					}
				Err(_) => found
			},
	)

## The tooling compiler is read from the Blueprint recipe.
expect Lint.stable_tag("Programs([Fetch(\"roc-stable\", Recipes.roc_nightly(\"nightly-2026-11-07-ad3a5d2\"))])") == Ok("nightly-2026-11-07-ad3a5d2")

## A Blueprint without the recipe has no tooling compiler.
expect Lint.stable_tag("Name(\"x\")") == Err(NoStableCompiler)

## Scripts must pin the tooling compiler and nothing else may.
expect {
	violations = Lint.check({
		sources: [
			{ path: "scripts/a.roc", text: "app [main!] { cli: platform \"x\" }\n" },
			{ path: "scripts/b.roc", text: "app [main!] { roc: \"nightly-1\" }\n" },
			{ path: "package/Opc.roc", text: "Opc :: [].{}\n" },
			{ path: "examples/e/main.roc", text: "app [main!] {\n\tdocx: \"../../package/main.roc\",\n\troc: \"nightly-1\",\n}\n" },
		],
		binaries: [],
		stable_tag: "nightly-1",
	})
	violations.map(|violation| "${violation.path}:${violation.line.to_str()}: ${violation.message}") == [
		"scripts/a.roc:1: scripts pin the tooling compiler: roc: \"nightly-1\"",
		"examples/e/main.roc:3: only scripts under scripts/ pin a compiler",
	]
}

## Applications depend on the package by relative path, never by release URL.
expect {
	violations = Lint.relative_package({ path: "fuzz/t/main.roc", text: "app [target] {\n\tdocx: \"https://github.com/lukewilliamboswell/roc-docx/releases/download/0.1.0/x.tar.zst\",\n}\n" })
	violations.map(|violation| violation.message) == [
		"depend on the package by relative path, not a release URL",
		"an application depends on the package as docx: \"../../package/main.roc\"",
	]
}

## A dependency pinned twice with different URLs is reported where it differs.
expect {
	sources = [
		{ path: "package/main.roc", text: "zip: \"https://github.com/niclas-ahden/roc-zip/releases/download/0.2.2/A.tar.zst\",\n" },
		{ path: "fuzz/t/main.roc", text: "zip: \"https://github.com/niclas-ahden/roc-zip/releases/download/0.2.1/B.tar.zst\",\n" },
	]
	Lint.consistent_urls(sources).map(|violation| "${violation.path}: ${violation.message}") == [
		"fuzz/t/main.roc: niclas-ahden/roc-zip is also pinned as https://github.com/niclas-ahden/roc-zip/releases/download/0.2.2/A.tar.zst in package/main.roc",
	]
}

## Package code never crashes, but a comment may say so.
expect {
	source = { path: "package/A.roc", text: "## never a crash\nx = crash \"no\"\n" }
	Lint.no_crash_in_package(source).map(|violation| violation.line) == [2]
}

## Fuzz targets declare examples and measure or ratchet allocations.
expect {
	bare = { path: "fuzz/t/main.roc", text: "examples: [],\n" }
	measured = { path: "fuzz/t/main.roc", text: "examples: [a],\nFuzz.measure!(\"r\", || x)\n" }
	Lint.fuzz_target_shape(bare).len() == 2 and Lint.fuzz_target_shape(measured) == []
}

## A top-level expect in the package needs a doc comment; one with it passes.
expect {
	source = { path: "package/A.roc", text: "## Named.\nexpect 1 == 1\n\nexpect 2 == 2\n" }
	Lint.expect_doc(source).map(|violation| violation.line) == [4]
}

## Chapters open with a title and are included by the index; release notes by the releases chapter.
expect {
	sources = [
		{ path: "docs/index.adoc", text: "= Manual\n\ninclude::overview.adoc[leveloffset=+1]\ninclude::releases.adoc[leveloffset=+1]\n" },
		{ path: "docs/overview.adoc", text: "= Overview\n" },
		{ path: "docs/orphan.adoc", text: "Untitled\n" },
		{ path: "docs/releases.adoc", text: "= Release notes\n\ninclude::releases/0.1.0.adoc[leveloffset=+1]\n" },
		{ path: "docs/releases/0.1.0.adoc", text: "= roc-docx 0.1.0\n" },
		{ path: "docs/releases/0.2.0.adoc", text: "= roc-docx 0.2.0\n" },
	]
	Lint.chapters_included(sources).map(|violation| "${violation.path}: ${violation.message}") == [
		"docs/orphan.adoc: a chapter opens with a single = Title",
		"docs/orphan.adoc: docs/index.adoc includes every chapter",
		"docs/releases/0.2.0.adoc: docs/releases.adoc includes every chapter",
	]
}

## The fuzz inventory names every target under fuzz/ and no other.
expect {
	architecture = { path: "docs/architecture.adoc", text: "[cols=\"1,3\"]\n|===\n|Target |Property\n|`listed` |A rule\n|`gone` |Another\n|===\n" }
	sources = [architecture, { path: "fuzz/listed/main.roc", text: "" }, { path: "fuzz/unlisted/main.roc", text: "" }]
	Lint.fuzz_inventory(sources).map(|violation| "${violation.path}: ${violation.message}") == [
		"fuzz/unlisted/main.roc: docs/architecture.adoc's fuzz inventory names every fuzz target",
		"docs/architecture.adoc: the fuzz inventory names `gone`, which is not a target under fuzz/",
	]
}

## Roc listings in chapters include a region of the snippet program or an example; release notes may write theirs out.
expect {
	listing = |body| "= Chapter\n\n[source,roc]\n----\n${body}\n----\n"
	sources = [
		{ path: "tests/manual.roc", text: "f = |x| {\n\t# tag::text[]\n\ty = x\n\t# end::text[]\n\ty\n}\n" },
		{ path: "examples/inspect/main.roc", text: "app [main!] {}\n" },
		{ path: "docs/included.adoc", text: listing("include::../tests/manual.roc[tag=text,indent=0]") },
		{ path: "docs/example.adoc", text: listing("include::../examples/inspect/main.roc[]") },
		{ path: "docs/inline.adoc", text: listing("x = 1") },
		{ path: "docs/untagged.adoc", text: listing("include::../tests/manual.roc[tag=missing,indent=0]") },
		{ path: "docs/elsewhere.adoc", text: listing("include::../package/Docx.roc[]") },
		{ path: "docs/releases/0.1.0.adoc", text: listing("app [main!] { docx: \"{package-url}\" }") },
	]
	Lint.manual_snippets(sources).map(|violation| "${violation.path}:${violation.line.to_str()}: ${violation.message}") == [
		"docs/inline.adoc:3: a Roc listing includes a region of tests/manual.roc or an example, so that check compiles it",
		"docs/untagged.adoc:3: tests/manual.roc has no region tagged missing",
		"docs/elsewhere.adoc:3: a Roc listing includes a region of tests/manual.roc or an example, so that check compiles it",
	]
}

## A .docx outside the corpus must be one of the fixtures byte for byte.
expect {
	binaries = [
		{ path: "tests/fixtures/pandoc/a.docx", bytes: [1, 2, 3] },
		{ path: "examples/a/a.docx", bytes: [1, 2, 3] },
		{ path: "examples/b/b.docx", bytes: [9] },
	]
	Lint.docx_identity(binaries).map(|violation| violation.path) == ["examples/b/b.docx"]
}

## A loop starting from a parameter whose record holds a collection is reported, in a match arm too; an owned copy, a number and a record of scalars are not, nor is code outside the package.
expect {
	text = Str.join_with(
		[
			"State : {",
			"\tnext : U64,",
			"\tseen : Set(Str),",
			"}",
			"Counts : { at : U64, joining : Bool }",
			"walk : List(U8), State, U64 -> State",
			"walk = |bytes, state, start| {",
			"\tvar $state = state",
			"\tvar $owned = { ..state, next: state.next }",
			"\tvar $index = start",
			"\t$state",
			"}",
			"count : Counts, { out : List(U8), at : U64 } -> U64",
			"count = |counts, walk|",
			"\tmatch counts {",
			"\t\t_ => {",
			"\t\t\tvar $counts = counts",
			"\t\t\tvar $walk = walk",
			"\t\t\t$walk.at",
			"\t\t}",
			"\t}",
		],
		"\n",
	)
	sources = [{ path: "package/A.roc", text }, { path: "scripts/b.roc", text }]
	Lint.owned_loop_state(sources).map(|violation| violation.line) == [8, 18]
}

## A record is recognised by its name in another module, qualified or not.
expect {
	sources = [
		{ path: "package/A.roc", text: "A :: [].{\n\tState : { names : List(Str) }\n}\n" },
		{ path: "package/B.roc", text: "walk : A.State -> A.State\nwalk = |state| {\n\tvar $state = state\n\t$state\n}\n" },
	]
	Lint.owned_loop_state(sources).map(|violation| violation.line) == [3]
}
