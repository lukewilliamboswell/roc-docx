app [target] {
	docx: "../package/main.roc",
	fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.8.0/BUNcJDHxCd7xLVSe3WBioyXqR6tm1MqXwzwGgtnmqK43.tar.zst",
}

import fuzz.Fuzz
import revision_algebra/Property as RevisionAlgebra
import comment_anchors/Property as CommentAnchors

# roc test runs these specifications with the suite.
import revision_algebra/Spec as RevisionAlgebraSpec
import comment_anchors/Spec as CommentAnchorsSpec

target = Fuzz.suite([
	RevisionAlgebra.target,
	CommentAnchors.target,
])
