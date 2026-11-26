app [target] {
	docx: "../package/main.roc",
	fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.8.0/BUNcJDHxCd7xLVSe3WBioyXqR6tm1MqXwzwGgtnmqK43.tar.zst",
	zip: "https://github.com/lukewilliamboswell/roc-zip/releases/download/0.3.0-rc3/8Cpaf9qGq5aA38zeGsUG91Bmk8u5pbcV9jnYUZv7d4RD.tar.zst",
}

import fuzz.Fuzz
import ParseNeverCrashesTarget
import TableReadingTarget
import StyleResolutionTarget
import NumberingResolutionTarget

# roc test runs these specifications with the suite.
import TableReadingSpec
import NumberingResolutionSpec

target = Fuzz.suite([
	ParseNeverCrashesTarget.target,
	TableReadingTarget.target,
	StyleResolutionTarget.target,
	NumberingResolutionTarget.target,
])
