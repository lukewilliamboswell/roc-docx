app [main] {
	docx: "../package/main.roc",
	pf: platform "https://github.com/lukewilliamboswell/roc-signals/releases/download/0.4.0/7vs4uMWvwXDKDpHQ9DjH4no5SMqhDyohbZ9tGKHfZocr.tar.zst",
}

import pf.Engine
import Playground

## The roc-docx playground, served at /playground/ beside the manual.
## `blueprint run playground` builds playground/dist with the matching
## roc-signals runtime and worker. The manual's fonts belong at
## ../_roc-docs/fonts/ relative to the served playground.
main : Engine.Program
main = Playground.program
