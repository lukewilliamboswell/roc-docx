app [main] {
	pf: platform "../../roc-signals-workers/platform/main.roc",
	docx: "../package/main.roc",
}

import pf.Engine
import Playground

## The roc-docx playground, served at /playground/ beside the manual.
## `roc build --opt=size --target=wasm32 --output=app.wasm main.roc` gives the
## browser module; serve it with index.html, playground.css, docx-file.mjs and
## the roc-signals platform's runtime.mjs and worker.mjs, below a site that
## has the manual's fonts at ../_roc-docs/fonts/. `--opt=dev` builds in
## seconds for working on the page.
main : Engine.Program
main = Playground.program
