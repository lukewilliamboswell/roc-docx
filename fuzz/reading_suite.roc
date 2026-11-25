app [target] {
	docx: "../package/main.roc",
	fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.8.0/BUNcJDHxCd7xLVSe3WBioyXqR6tm1MqXwzwGgtnmqK43.tar.zst",
	zip: "https://github.com/lukewilliamboswell/roc-zip/releases/download/0.3.0-rc3/8Cpaf9qGq5aA38zeGsUG91Bmk8u5pbcV9jnYUZv7d4RD.tar.zst",
}

import fuzz.Fuzz
import parse_never_crashes/Property as ParseNeverCrashes
import table_reading/Property as TableReading
import style_resolution/Property as StyleResolution
import numbering_resolution/Property as NumberingResolution

# roc test runs these specifications with the suite.
import table_reading/Spec as TableReadingSpec
import numbering_resolution/Spec as NumberingResolutionSpec

target = Fuzz.suite([
	ParseNeverCrashes.target,
	TableReading.target,
	StyleResolution.target,
	NumberingResolution.target,
])
