# Development environment and tasks for roc-docx, realised by roc-blueprint.
#
#     blueprint run check              # everything a pull request must pass
#     blueprint run <task>             # one of the checks on its own; `blueprint tasks` lists them
#     blueprint update                 # refresh Blueprint.lock after changing a recipe
#
# The package compiler is the latest nightly, supplied as bare `roc` by CI and
# by a contributor's PATH; nothing here fetches it. `roc-stable` is a fixed
# nightly for the repository's own scripts, and the oracle adapters run on the
# host's python3 and xmllint with a fetched pandoc.
app [config] { pf: platform "https://github.com/lukewilliamboswell/roc-blueprint/releases/download/0.8.0/FbJymjYdCxx9vqMcau7r4tQfeAbnVGqqJoYrLGqPCqKu.tar.zst" }

import pf.Config
import pf.Recipes
import pf.System

config = [
	Name("roc-docx"),
	Systems(["x86_64-linux", "aarch64-darwin"]),
	# The package, examples and fuzz targets: checked with the host's latest nightly.
	Environment("package", [Expect(["roc"])]),
	# Repository scripts run on a fixed compiler so they keep working while the package is broken.
	Environment("tools", [Extend("package"), Programs([Fetch("roc-stable", Recipes.roc_nightly("nightly-2026-11-07-ad3a5d2"))]), RocPackages(["https://github.com/roc-lang/basic-cli/releases/download/0.27.0/9yjxqdGTP4xSpSEmDazwTmRsehfRZzA19pwEKkR6fj1g.tar.zst"])]),
	# Oracle adapters: pandoc is fetched; xmllint and python3 come from the host.
	Environment("oracle", [Programs([Fetch("pandoc", pandoc)]), Expect(["python3", "xmllint"])]),
	# The LibreOffice lane: LibreOffice is found through SOFFICE or PATH by the adapter that needs it.
	# It runs the cases first, with the host's latest nightly, to write the documents LibreOffice reads back and the package's snapshots.
	Environment("libreoffice", [Programs([Fetch("pandoc", pandoc)]), Expect(["python3", "roc", "sh"])]),
	# Everything the check driver runs: the scripts' compiler, the oracle programs and the release utility.
	Environment("dev", [Extend("tools"), Programs([Fetch("pandoc", pandoc), Fetch("release-package", release_package)]), Expect(["python3", "xmllint"])]),
	# The manual and its API reference, which `roc docs` generates with the host's latest nightly.
	Environment("docs", [Extend("package"), Programs([Fetch("roc-docs", Recipes.file("https://github.com/lukewilliamboswell/roc-automation/releases/download/tools-0.10.0/roc-docs-{system}"))]), Expect(["realpath", "sh"])]),
	Environment("release", [Programs([Fetch("release-package", release_package)]), Expect(["roc", "git", "gh", "tar", "unzip", "zip", "chmod", "touch", "env"])]),
	Environment("release-test", [Programs([Fetch("release-package", release_package)]), Expect(["roc"])]),
	Shell("default", [Use("dev")]),
	# Everything a pull request must pass; the shared release workflow runs it too.
	Task("check", [Use("dev"), Run(["scripts/check_all.roc"])]),
	Task("fmt", [Use("package"), Run(["roc", "fmt", "--check", "package", "examples", "fuzz", "tests", "playground"])]),
	Task("fmt-scripts", [Use("tools"), Run(["roc-stable", "fmt", "--check", "scripts"])]),
	Task("lint", [Use("tools"), Run(["scripts/lint.roc"])]),
	Task("scripts-test", [Use("tools"), Run(["roc-stable", "test", "scripts/src/Lint.roc"])]),
	Task("test", [Use("package"), Run(["roc", "test", "package/main.roc"])]),
	Task("playground", [Use("package"), Run(["sh", "scripts/playground.sh"])]),
	Task("playground-test", [Use("package"), Run(["roc", "test", "playground/main.roc"])]),
	Task("cases", [Use("package"), Run(["roc", "tests/main.roc"])]),
	Task("manual", [Use("package"), Run(["roc", "tests/manual.roc"])]),
	Task("cases-update", [Use("package"), Run(["roc", "tests/main.roc", "--update"])]),
	Task("examples", [Use("release-test"), Run(["release-package", "test-examples"])]),
	Task("fuzz-smoke", [Use("tools"), Run(["scripts/fuzz_smoke.roc"])]),
	Task("oracle-provision", [Use("oracle"), Run(["python3", "-I", "oracle/provision.py"])]),
	Task("oracle-schema", [Use("oracle"), Run(["python3", "-I", "oracle/validate_schema.py", "tests/fixtures"])]),
	Task("oracle-schema-written", [Use("oracle"), Run(["python3", "-I", "oracle/validate_schema.py", ".roc-docx/passthrough", ".roc-docx/generated", ".roc-docx/review", ".roc-docx/redline"])]),
	Task("oracle-snapshot", [Use("oracle"), Run(["python3", "-I", "oracle/compare_snapshots.py", "--lane", "pandoc,package", "tests/fixtures"])]),
	# pandoc, LibreOffice and the package agree on every fixture, LibreOffice reads every passed-through fixture as it reads the
	# original, and LibreOffice and the package agree on every generated document and every reviewed and redlined fixture: a CI job of its
	# own, because check does not need LibreOffice.
	Task("libreoffice", [Use("libreoffice"), Run(["sh", "-c", libreoffice_lane])]),
	Task("fixtures", [Use("oracle"), Run(["python3", "-I", "oracle/make_fixtures.py"])]),
	Task("fixtures-check", [Use("oracle"), Run(["python3", "-I", "oracle/make_fixtures.py", "--check"])]),
	Task("docs", [Use("docs"), Run(["roc-docs", "build", "--workspace", ".", "--pdf-filename", "roc-docx.pdf", "--api-entrypoint", "package/main.roc"])]),
	Task("docs-path", [Use("docs"), Run(["sh", "-c", "realpath \"$(command -v roc-docs)\""])]),
	Task("release-package", [Use("release"), Run(["release-package"])]),
	Task("release-test", [Use("release-test"), Run(["release-package"])]),
]

libreoffice_lane : Str
libreoffice_lane = "roc tests/main.roc && python3 -I oracle/compare_snapshots.py --lane pandoc,libreoffice,package tests/fixtures && python3 -I oracle/compare_snapshots.py --written libreoffice tests/fixtures .roc-docx/passthrough && python3 -I oracle/compare_snapshots.py --lane libreoffice,package .roc-docx/generated && python3 -I oracle/compare_snapshots.py --lane libreoffice,package .roc-docx/review && python3 -I oracle/compare_snapshots.py --lane libreoffice,package .roc-docx/redline"

release_package : System -> Config.Download
release_package = Recipes.file("https://github.com/lukewilliamboswell/roc-automation/releases/download/tools-0.10.0/release-package-{system}")

# pandoc produces the regenerable fixtures and reads documents as a semantic oracle.
pandoc : System -> Config.Download
pandoc = |system| {
	base = "https://github.com/jgm/pandoc/releases/download/3.9.0.2"
	match system {
		"x86_64-linux" => Archive("${base}/pandoc-3.9.0.2-linux-amd64.tar.gz", TarGz, "pandoc-3.9.0.2/bin/pandoc")
		"aarch64-darwin" => Archive("${base}/pandoc-3.9.0.2-arm64-macOS.zip", Zip, "pandoc-3.9.0.2-arm64/bin/pandoc")
		_ => Unavailable
	}
}
