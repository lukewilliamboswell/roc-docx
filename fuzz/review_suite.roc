app [target] {
	docx: "../package/main.roc",
	fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.8.0/BUNcJDHxCd7xLVSe3WBioyXqR6tm1MqXwzwGgtnmqK43.tar.zst",
}

import fuzz.Fuzz
import RevisionAlgebraTarget
import CommentAnchorsTarget

# roc test runs these specifications with the suite.
import RevisionAlgebraSpec
import CommentAnchorsSpec

target = Fuzz.suite([
	RevisionAlgebraTarget.target,
	CommentAnchorsTarget.target,
])
