app [target] {
	docx: "../package/main.roc",
	fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.8.0/BUNcJDHxCd7xLVSe3WBioyXqR6tm1MqXwzwGgtnmqK43.tar.zst",
	parser: "https://github.com/lukewilliamboswell/roc-parser/releases/download/6.0.0-rc.3.1/BBUDV8ak5oBCYRjWbQ3zNDBjXFVZydTdMPswovVkMUsT.tar.zst",
	zip: "https://github.com/lukewilliamboswell/roc-zip/releases/download/0.3.0-rc3/8Cpaf9qGq5aA38zeGsUG91Bmk8u5pbcV9jnYUZv7d4RD.tar.zst",
}

import fuzz.Fuzz
import document_roundtrip/Property as DocumentRoundtrip
import structure_oracle/Property as StructureOracle
import build_document/Property as BuildDocument

# roc test runs these specifications with the suite.
import document_roundtrip/Spec as DocumentRoundtripSpec
import build_document/Spec as BuildDocumentSpec

target = Fuzz.suite([
	DocumentRoundtrip.target,
	StructureOracle.target,
	BuildDocument.target,
])
