app [main] {
	pf: platform "../../roc-signals-workers/platform/main.roc",
	docx: "../package/main.roc",
}

import pf.Engine
import Playground

## The roc-docx playground: `roc build --target=wasm32` gives the browser
## module.
main : Engine.Program
main = Playground.program
