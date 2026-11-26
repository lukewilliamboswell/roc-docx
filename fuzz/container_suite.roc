app [target] {
	docx: "../package/main.roc",
	fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.8.0/BUNcJDHxCd7xLVSe3WBioyXqR6tm1MqXwzwGgtnmqK43.tar.zst",
	zip: "https://github.com/lukewilliamboswell/roc-zip/releases/download/0.3.0-rc3/8Cpaf9qGq5aA38zeGsUG91Bmk8u5pbcV9jnYUZv7d4RD.tar.zst",
}

import fuzz.Fuzz
import OpcOpenTarget
import ZipOpcRoundtripTarget
import XmlNamespaceRoundtripTarget
import MceProcessingTarget

# roc test runs these specifications with the suite.
import OpcOpenSpec
import ZipOpcRoundtripSpec
import MceProcessingSpec

target = Fuzz.suite([
	OpcOpenTarget.target,
	ZipOpcRoundtripTarget.target,
	XmlNamespaceRoundtripTarget.target,
	MceProcessingTarget.target,
])
