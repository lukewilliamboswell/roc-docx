app [target] {
	docx: "../package/main.roc",
	fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.8.0/BUNcJDHxCd7xLVSe3WBioyXqR6tm1MqXwzwGgtnmqK43.tar.zst",
	zip: "https://github.com/lukewilliamboswell/roc-zip/releases/download/0.3.0-rc3/8Cpaf9qGq5aA38zeGsUG91Bmk8u5pbcV9jnYUZv7d4RD.tar.zst",
}

import fuzz.Fuzz
import opc_open/Property as OpcOpen
import zip_opc_roundtrip/Property as ZipOpcRoundtrip
import xml_namespace_roundtrip/Property as XmlNamespaceRoundtrip
import mce_processing/Property as MceProcessing

# roc test runs these specifications with the suite.
import opc_open/Spec as OpcOpenSpec
import zip_opc_roundtrip/Spec as ZipOpcRoundtripSpec
import mce_processing/Spec as MceProcessingSpec

target = Fuzz.suite([
	OpcOpen.target,
	ZipOpcRoundtrip.target,
	XmlNamespaceRoundtrip.target,
	MceProcessing.target,
])
