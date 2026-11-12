import pf.Engine exposing [Elem, State, Val]
import pf.Html
import pf.Wire
import pf.Worker
import Base64
import Explore
import Generate
import Review
import Samples

## The roc-docx playground. Explore a document stage by stage, from its ZIP
## archive to the typed model; review its tracked changes and comments; or
## generate a letter. Every document is read, edited and written in Web
## Workers by roc-docx compiled to WebAssembly; nothing leaves the page.
Playground := [].{

	Mode : [Explore, Review, Generate]

	## The stages of reading, in pipeline order, and what follows them.
	Stage : [Zip, Package, Xml, Document, Annotations, Text, RoundTrip, Problems]

	## What the inspector shows of the selected block.
	Pane : [Properties, Model, Source, Roc]

	File : [Empty, Loaded({ name : Str, doc : Wire.Bytes }), BadFile(Str)]

	S : {
		mode : Mode,
		file : File,
		sample : Str,
		stage : Stage,
		selected : Str,
		pane : Pane,
		part : Str,
		edits : List(Review.Edit),
		reviewer : Str,
		now : Str,
		replying : Str,
		reply : Str,
		letter : Generate.Letter,
	}

	program : Engine.Program
	program =
		Engine.program_boot({ storage_keys: [], max_inflight: 32 }, |boot| Engine.state(Playground.initial(boot.url), Playground.view))
			.with_workers([
				Explore.model.registration(),
				Explore.part_xml.registration(),
				Explore.round_trip.registration(),
				Review.review.registration(),
				Generate.letter.registration(),
			])

	stages : List(Stage)
	stages = [Zip, Package, Xml, Document, Annotations, Text, RoundTrip, Problems]

	panes : List(Pane)
	panes = [Properties, Model, Source, Roc]

	# ── State ──────────────────────────────────────────────────────────────

	empty : S
	empty = {
		mode: Explore,
		file: Empty,
		sample: "",
		stage: Document,
		selected: "0",
		pane: Properties,
		part: "/word/document.xml",
		edits: [],
		reviewer: "Playground Reviewer",
		now: "2026-01-01T00:00:00Z",
		replying: "",
		reply: "",
		letter: Generate.example,
	}

	## The state a URL asks for: `#mode=…&sample=…&stage=…&block=…`.
	initial : Str -> S
	initial = |url| {
		hash = match url.split_first("#") {
			Ok({ before: _, after }) => after
			Err(_) => ""
		}
		pairs = hash.split_on("&").map(
			|pair|
				match pair.split_first("=") {
					Ok({ before, after }) => (before, after)
					Err(_) => (pair, "")
				},
		)
		get = |key| pairs.find_first(|(k, _)| k == key).map_ok(|(_, v)| v) ?? ""
		loaded = match Samples.find(get("sample")) {
			Ok(sample) => Playground.with_sample(Playground.empty, sample)
			Err(_) => Playground.empty
		}
		mode = Playground.mode_named(get("mode")) ?? Explore
		stage = Playground.stages.find_first(|s| Playground.slug(s) == get("stage")) ?? loaded.stage
		block = get("block")
		{ ..loaded, mode, stage, selected: if (block == "") loaded.selected else block }
	}

	## The URL fragment that shows this state again.
	fragment : S -> Str
	fragment = |s| {
		mode = "mode=${Playground.mode_slug(s.mode)}"
		sample = if (s.sample == "") "" else "&sample=${s.sample}"
		place = if (s.mode == Explore and s.sample != "") "&stage=${Playground.slug(s.stage)}&block=${s.selected}" else ""
		"#${mode}${sample}${place}"
	}

	mode_named : Str -> Try(Mode, [NotFound])
	mode_named = |name|
		match name {
			"explore" => Ok(Explore)
			"review" => Ok(Review)
			"generate" => Ok(Generate)
			_ => Err(NotFound)
		}

	mode_slug : Mode -> Str
	mode_slug = |m|
		match m {
			Explore => "explore"
			Review => "review"
			Generate => "generate"
		}

	with_sample : S, Samples.Sample -> S
	with_sample = |s, sample| { ..Playground.with_file(s, sample.file, sample.bytes), sample: sample.key }

	with_file : S, Str, List(U8) -> S
	with_file = |s, name, bytes| { ..s, file: Loaded({ name, doc: Wire.Bytes.from_list(bytes) }), sample: "", stage: Document, selected: "0", part: "/word/document.xml", edits: [], replying: "" }

	## The `<docx-file>` element's payload: the file name, a line feed and
	## the file's bytes as base64.
	dropped : S, Str -> S
	dropped = |s, payload|
		match payload.split_first("\n") {
			Ok({ before: name, after }) =>
				match Base64.decode(after) {
					Ok(bytes) => Playground.with_file(s, name, bytes)
					Err(_) => { ..s, file: BadFile(name), sample: "" }
				}
			Err(_) => { ..s, file: BadFile(""), sample: "" }
		}

	## A document the page made, as base64, opened in Explore.
	opened : S, Str, Str -> S
	opened = |s, name, base64|
		match Base64.decode(base64) {
			Ok(bytes) if !bytes.is_empty() => { ..Playground.with_file(s, name, bytes), mode: Explore }
			_ => s
		}

	document_of : S -> [Run(Wire.Bytes), Skip]
	document_of = |s|
		match s.file {
			Loaded({ doc, .. }) => Run(doc)
			_ => Skip
		}

	is_loaded : S -> Bool
	is_loaded = |s|
		match s.file {
			Loaded(_) => Bool.True
			_ => Bool.False
		}

	# ── Page ───────────────────────────────────────────────────────────────

	view : State(ctx, S) -> Elem(ctx)
	view = |st| {
		v = st.val()
		Html.div(
			"app",
			[
				Engine.element("now-clock", [Engine.on("change", st.set_value(|s, now| { ..s, now, letter: { ..s.letter, created: now } }))], []),
				Engine.watch(v.map(Playground.fragment), |f| [Replace(f)], st.on_result(|s, _, _| s)),
				Playground.top_bar(st),
				Engine.switch(
					v.map(|s| s.mode),
					[Explore, Review, Generate],
					|mode|
						match mode {
							Explore => Playground.explore(st)
							Review => Playground.review(st)
							Generate => Playground.generate(st)
						},
				),
			],
		)
	}

	top_bar : State(ctx, S) -> Elem(ctx)
	top_bar = |st|
		Engine.element(
			"header",
			[Engine.class("top-bar")],
			[
				Engine.element("a", [Engine.class("brand"), Engine.attr("href", "../")], [Engine.text("roc-docx"), Engine.element("span", [], [Engine.text("playground")])]),
				Engine.element(
					"nav",
					[Engine.class("modes"), Html.aria_label("Mode")],
					[Playground.mode_button(st, Explore, "Explore"), Playground.mode_button(st, Review, "Review"), Playground.mode_button(st, Generate, "Generate")],
				),
				Engine.element(
					"nav",
					[Engine.class("links"), Html.aria_label("Elsewhere")],
					[
						Html.link("Manual", "../", []),
						Html.link("API", "../api/", []),
						Html.link("GitHub", "https://github.com/lukewilliamboswell/roc-docx", []),
					],
				),
			],
		)

	mode_button : State(ctx, S), Mode, Str -> Elem(ctx)
	mode_button = |st, mode, label|
		Engine.element(
			"button",
			[
				Engine.attr("type", "button"),
				Engine.class_v(st.val().map(|s| if (s.mode == mode) "mode current" else "mode")),
				Engine.on("click", st.update(|s| { ..s, mode })),
			],
			[Engine.text(label)],
		)

	# ── Loading ────────────────────────────────────────────────────────────

	## Where a document comes from: a drop, the file picker or a sample.
	welcome : State(ctx, S), Str, Str -> Elem(ctx)
	welcome = |st, heading, lede|
		Engine.element(
			"section",
			[Engine.class("welcome")],
			[
				Engine.element("h1", [], [Engine.text(heading)]),
				Engine.element("p", [Engine.class("lede")], [Engine.text(lede)]),
				Engine.element("docx-file", [Html.aria_label("Word document"), Engine.on("change", st.set_value(Playground.dropped))], []),
				Html.p_v(
					st.val().map(
						|s|
							match s.file {
								BadFile(name) => "${name} is not a document roc-docx can read as base64; try another file."
								_ => ""
							},
					),
					[Engine.class("problem")],
				),
				Engine.element("h2", [], [Engine.text("Or start with a sample")]),
				Engine.element("div", [Engine.class("samples")], Samples.all.map(|sample| Playground.sample_card(st, sample))),
				Engine.element(
					"p",
					[Engine.class("privacy")],
					[Engine.text("Your document never leaves this page: roc-docx, compiled to WebAssembly, reads it in your browser.")],
				),
			],
		)

	sample_card : State(ctx, S), Samples.Sample -> Elem(ctx)
	sample_card = |st, sample|
		Engine.element(
			"button",
			[Engine.attr("type", "button"), Engine.class("sample"), Engine.on("click", st.update(|s| Playground.with_sample(s, sample)))],
			[
				Engine.element("strong", [], [Engine.text(sample.title)]),
				Engine.element("span", [Engine.class("producer")], [Engine.text("${sample.producer} · ${sample.file}")]),
				Engine.element("span", [], [Engine.text(sample.about)]),
			],
		)

	## The loaded document's name, and a way back to choose another.
	file_bar : State(ctx, S) -> Elem(ctx)
	file_bar = |st|
		Engine.element(
			"div",
			[Engine.class("file-bar")],
			[
				Html.span_v(
					st.val().map(
						|s|
							match s.file {
								Loaded({ name, doc }) => "${name} · ${Playground.bytes(doc.to_list().len())}"
								_ => ""
							},
					),
					[Engine.class("file-name")],
				),
				Html.button("Open another document", [Engine.class("quiet")], st.update(|s| { ..s, file: Empty, sample: "", edits: [] })),
			],
		)

	# ── Explore ────────────────────────────────────────────────────────────

	explore : State(ctx, S) -> Elem(ctx)
	explore = |st|
		Engine.when(
			st.val().map(Playground.is_loaded),
			||
				Engine.element(
					"main",
					[Engine.class("explore")],
					[
						Playground.file_bar(st),
						Worker.derive_when(Explore.model, st.val().map(Playground.document_of), |remote| Playground.explored(st.lift(), remote)),
					],
				),
			|| Engine.element("main", [], [Playground.welcome(st, "See inside a Word document", "Drop a .docx to follow it through roc-docx: the ZIP archive, the package of parts, the XML, and the typed document an application works with.")]),
		)

	explored : State(ctx, S), Val(ctx, Engine.Remote(Explore.Model, Worker.Error(Explore.Problem))) -> Elem(ctx)
	explored = |st, remote| {
		m = remote.map(Playground.model_of)
		Html.div(
			"explored",
			[
				Html.p_v(remote.map(Playground.status), [Engine.class("status")]),
				Playground.rail(st, m),
				Engine.switch(
					st.val().map(|s| s.stage),
					Playground.stages,
					|stage|
						Engine.element(
							"section",
							[Engine.class("stage")],
							[
								Playground.stage_header(stage),
								match stage {
									Zip => Playground.zip(m)
									Package => Playground.parts(m)
									Xml => Playground.xml(st, m)
									Document => Playground.document(st, m)
									Annotations => Playground.annotations(st, m)
									Text => Playground.texts(m)
									RoundTrip => Playground.round_trip(st)
									Problems => Playground.problems(m)
								},
							],
						),
				),
			],
		)
	}

	model_of : Engine.Remote(Explore.Model, Worker.Error(Explore.Problem)) -> Explore.Model
	model_of = |r|
		match r.answer {
			Answered(m) => m
			_ => Playground.no_model
		}

	no_model : Explore.Model
	no_model = { zip: [], bounds: [], package_relationships: [], parts: [], xml_parts: [], properties: [], blocks: [], comments: [], changes: [], diagnostics: [], text: "", final_text: "", original_text: "", tracking: Bool.False }

	status : Engine.Remote(a, Worker.Error(Explore.Problem)) -> Str
	status = |{ request, answer }|
		match answer {
			Unanswered => if (request == Pending) "Reading…" else ""
			Answered(_) => if (request == Pending) "Reading…" else ""
			Failed(error) => Playground.problem(error)
		}

	problem : Worker.Error(Explore.Problem) -> Str
	problem = |error|
		match error {
			Failed(Unreadable(why)) => "roc-docx could not read this document: ${why}"
			Timeout => "This took too long."
			Refused => "Too much is running; try again."
			Lost(fault) => "The worker stopped: ${Str.inspect(fault)}."
		}

	## The pipeline, one button per stage, each with what it found.
	rail : State(ctx, S), Val(ctx, Explore.Model) -> Elem(ctx)
	rail = |st, m|
		Engine.element(
			"nav",
			[Engine.class("rail"), Html.aria_label("Stages")],
			Playground.stages.map(
				|stage|
					Engine.element(
						"button",
						[
							Engine.attr("type", "button"),
							Engine.class_v(st.val().map(|s| if (s.stage == stage) "step current" else "step")),
							Engine.on("click", st.update(|s| { ..s, stage })),
						],
						[
							Engine.element("span", [Engine.class("step-name")], [Engine.text(Playground.stage_name(stage))]),
							Html.span_v(m.map(|model| Playground.found(model, stage)), [Engine.class("step-found")]),
						],
					),
			),
		)

	slug : Stage -> Str
	slug = |stage|
		match stage {
			Zip => "zip"
			Package => "package"
			Xml => "xml"
			Document => "document"
			Annotations => "annotations"
			Text => "text"
			RoundTrip => "round-trip"
			Problems => "diagnostics"
		}

	stage_name : Stage -> Str
	stage_name = |stage|
		match stage {
			Zip => "ZIP"
			Package => "Package"
			Xml => "XML"
			Document => "Document"
			Annotations => "Comments & changes"
			Text => "Text"
			RoundTrip => "Round trip"
			Problems => "Diagnostics"
		}

	found : Explore.Model, Stage -> Str
	found = |m, stage|
		match stage {
			Zip => Playground.count(m.zip.len(), "entry", "entries")
			Package => Playground.count(m.parts.len(), "part", "parts")
			Xml => Playground.count(m.xml_parts.len(), "XML part", "XML parts")
			Document => Playground.count(m.blocks.len(), "block", "blocks")
			Annotations => "${m.comments.len().to_str()} · ${m.changes.len().to_str()}"
			Text => "3 readings"
			RoundTrip => "write back"
			Problems => Playground.count(m.diagnostics.len(), "diagnostic", "diagnostics")
		}

	count : U64, Str, Str -> Str
	count = |n, one, many| if (n == 1) "1 ${one}" else "${n.to_str()} ${many}"

	stage_header : Stage -> Elem(ctx)
	stage_header = |stage| {
		{ title, about, call } = Playground.explained(stage)
		Engine.element(
			"header",
			[Engine.class("stage-header")],
			[
				Engine.element("h2", [], [Engine.text(title)]),
				Engine.element("p", [], [Engine.text(about)]),
				Engine.element("pre", [Engine.class("call")], [Engine.element("code", [], [Engine.text(call)])]),
			],
		)
	}

	explained : Stage -> { title : Str, about : Str, call : Str }
	explained = |stage|
		match stage {
			Zip => {
				title: "The ZIP archive",
				about: "A .docx is a ZIP archive. roc-docx reads its central directory first and checks every entry against the limits before it inflates anything, so a hostile archive fails with a named error instead of exhausting memory.",
				call: "pkg = Opc.open(bytes, {})?",
			}
			Package => {
				title: "The package of parts",
				about: "Each entry is a part with a content type, and relationships connect the parts. roc-docx finds the main document, its styles and its comments by following relationships, never by file name.",
				call: "Opc.parts(pkg)\nOpc.relationships(pkg, \"/word/document.xml\")?",
			}
			Xml => {
				title: "The XML of each part",
				about: "Each XML part becomes a namespaced tree. The colours show what reading does with every element: content in a namespace roc-docx understands, an extension it keeps in place, markup compatibility it resolves, and editor state it drops by a documented rule.",
				call: "XmlTree.parse(Opc.part_bytes(pkg, name)?, {})?",
			}
			Document => {
				title: "The document",
				about: "The typed model an application works with: blocks of paragraphs, tables and section breaks, their runs and tracked changes, and the styles they use. Select a block to see its properties, its Roc value, the XML it was read from and the Roc that reaches it.",
				call: "parsed = Docx.parse(bytes)?\nDocx.body(parsed.document)",
			}
			Annotations => {
				title: "Comments and tracked changes",
				about: "Comments are threads joined from five parts, each anchored to the text it discusses; tracked changes carry their author and date. Select a comment to find its block.",
				call: "Docx.comments(document).comments\nDocx.revisions(document)",
			}
			Text => {
				title: "The text, three ways",
				about: "The text as it stands with changes shown, with every change accepted, and with every change rejected. Paragraphs end with a line feed.",
				call: "Docx.text(document)\nDocx.final_text(document)\nDocx.original_text(document)",
			}
			RoundTrip => {
				title: "Write it back",
				about: "roc-docx writes the document and reads the result again. Every XML part is written in roc-docx's canonical form, with its fixed prefixes, attribute order and element order, so its bytes differ from the producer's; the documents compare equal under the equivalence the package defines. Parts that are not XML, such as images, are copied as they were stored.",
				call: "written = Docx.to_bytes(document)?\nDocx.equivalent(document, Docx.parse(written)?.document)",
			}
			Problems => {
				title: "Diagnostics",
				about: "Everything reading did not take exactly as written: a default it applied, a value it rounded, editor state it dropped. Diagnostics are data returned beside the document, never printed and never silent.",
				call: "parsed = Docx.parse(bytes)?\nparsed.diagnostics",
			}
		}

	# ── ZIP and package ────────────────────────────────────────────────────

	zip : Val(ctx, Explore.Model) -> Elem(ctx)
	zip = |m|
		Html.div(
			"columns",
			[
				Playground.table(
					["Entry", "Method", "Stored", "Inflated", "CRC-32"],
					[
						Engine.each(
							m.map(|x| x.zip),
							|e| e.name,
							|row|
								Engine.element(
									"tr",
									[],
									[
										Playground.cell(row.field(|e| e.name), "mono"),
										Playground.cell(row.field(|e| e.method), ""),
										Playground.cell(row.field(|e| Playground.bytes(e.compressed)), "num"),
										Playground.cell(row.field(|e| Playground.bytes(e.size)), "num"),
										Playground.cell(row.field(|e| e.crc), "mono"),
									],
								),
						),
					],
				),
				Engine.element(
					"aside",
					[Engine.class("bounds")],
					[
						Engine.element("h3", [], [Engine.text("Limits checked")]),
						Engine.each(
							m.map(|x| x.bounds),
							|b| b.name,
							|row|
								Engine.element(
									"div",
									[Engine.class("bound")],
									[
										Html.p_v(row.field(|b| b.name), []),
										Engine.element("div", [Engine.class("meter")], [Engine.element("span", [Engine.attr_v("style", row.field(Playground.meter))], [])]),
										Html.p_v(row.field(|b| "${b.used.to_str()} of ${b.limit.to_str()}"), [Engine.class("muted")]),
									],
								),
						),
					],
				),
			],
		)

	meter : Explore.Bound -> Str
	meter = |b| {
		share = if (b.limit == 0) 0 else (b.used * 100 + b.limit - 1) // b.limit
		percent = if (share > 100) 100 else if (share < 1) 1 else share
		"width: ${percent.to_str()}%"
	}

	parts : Val(ctx, Explore.Model) -> Elem(ctx)
	parts = |m|
		Html.div(
			"package",
			[
				Engine.element("h3", [], [Engine.text("The package's own relationships")]),
				Playground.relationships(m.map(|x| x.package_relationships)),
				Engine.element("h3", [], [Engine.text("Parts")]),
				Engine.element(
					"ul",
					[Engine.class("parts")],
					[
						Engine.each(
							m.map(|x| x.parts),
							|p| p.name,
							|row|
								Engine.element(
									"li",
									[Engine.class("part")],
									[
										Html.p_v(row.field(|p| p.name), [Engine.class("mono strong")]),
										Html.p_v(row.field(|p| "${p.content_type} · ${Playground.bytes(p.size)}"), [Engine.class("muted")]),
										Playground.relationships(row.field(|p| p.relationships)),
									],
								),
						),
					],
				),
			],
		)

	relationships : Val(ctx, List(Explore.Relationship)) -> Elem(ctx)
	relationships = |rels|
		Engine.element(
			"ul",
			[Engine.class("relationships")],
			[
				Engine.each(
					rels,
					|r| r.id,
					|row|
						Engine.element(
							"li",
							[],
							[
								Html.span_v(row.field(|r| r.kind), [Engine.class("kind")]),
								Html.span_v(row.field(|r| if (r.external) "→ ${r.target} (external)" else "→ ${r.target}"), [Engine.class("mono")]),
								Html.span_v(row.field(|r| r.id), [Engine.class("muted")]),
							],
						),
				),
			],
		)

	# ── XML ────────────────────────────────────────────────────────────────

	xml : State(ctx, S), Val(ctx, Explore.Model) -> Elem(ctx)
	xml = |st, m|
		Html.div(
			"xml-stage",
			[
				Engine.element(
					"nav",
					[Engine.class("part-list"), Html.aria_label("XML parts")],
					[
						Engine.each(
							m.map(|x| x.xml_parts),
							|name| name,
							|row|
								Engine.element(
									"button",
									[
										Engine.attr("type", "button"),
										Engine.class_v(row.select(Engine.keyed(st.val().map(|s| s.part), "part-name current", "part-name"))),
										Engine.on("click", st.lift_row().update_by(row.key(), |s, part| { ..s, part })),
									],
									[Engine.text_v(row.key())],
								),
						),
					],
				),
				Html.div(
					"xml-pane",
					[
						Engine.element(
							"p",
							[Engine.class("legend")],
							[
								Engine.element("span", [Engine.class("x understood")], [Engine.text("understood")]),
								Engine.element("span", [Engine.class("x extension")], [Engine.text("extension, kept in place")]),
								Engine.element("span", [Engine.class("x mce")], [Engine.text("markup compatibility, resolved")]),
								Engine.element("span", [Engine.class("x dropped")], [Engine.text("editor state, dropped")]),
							],
						),
						Worker.derive_when(
							Explore.part_xml,
							st.val().map(
								|s|
									match s.file {
										Loaded({ doc, .. }) => Run({ doc, part: s.part })
										_ => Skip
									},
							),
							|remote|
								Html.div(
									"xml-lines",
									[
										Html.p_v(remote.map(Playground.status), [Engine.class("status")]),
										Engine.each(
											remote.map(Playground.keyed_lines),
											|l| l.key,
											|row|
												Engine.element(
													"div",
													[Engine.class_v(row.field(|l| "x ${l.class}")), Engine.attr_v("style", row.field(|l| "padding-left: ${(l.depth * 14 + 6).to_str()}px"))],
													[
														Html.span_v(row.field(|l| if (l.tag == "") "" else "<${l.tag}"), [Engine.class("tag")]),
														Html.span_v(row.field(|l| l.attributes), [Engine.class("attributes")]),
														Html.span_v(row.field(|l| l.dropped), [Engine.class("gone")]),
														Html.span_v(row.field(|l| if (l.tag == "") "" else ">"), [Engine.class("tag")]),
														Html.span_v(row.field(|l| l.text), [Engine.class("text")]),
													],
												),
										),
									],
								),
						),
					],
				),
			],
		)

	keyed_lines : Engine.Remote(List(Explore.XmlLine), Worker.Error(Explore.Problem)) -> List({ key : Str, depth : U64, tag : Str, attributes : Str, dropped : Str, text : Str, class : Str })
	keyed_lines = |r|
		match r.answer {
			Answered(lines) => lines.map_with_index(|l, i| { key: i.to_str(), depth: l.depth, tag: l.tag, attributes: l.attributes, dropped: l.dropped, text: l.text, class: l.class })
			_ => []
		}

	# ── Document ───────────────────────────────────────────────────────────

	document : State(ctx, S), Val(ctx, Explore.Model) -> Elem(ctx)
	document = |st, m|
		Html.div(
			"document",
			[
				Engine.element("div", [Engine.class("page")], [Playground.properties(m), Playground.structure(st, m.map(|x| x.blocks), Bool.True)]),
				Playground.inspector(st, m),
			],
		)

	properties : Val(ctx, Explore.Model) -> Elem(ctx)
	properties = |m|
		Engine.element(
			"dl",
			[Engine.class("properties")],
			[
				Engine.each(
					m.map(|x| x.properties),
					|(k, _)| k,
					|row| Engine.element("div", [], [Engine.element("dt", [], [Engine.text_v(row.field(|(k, _)| k))]), Engine.element("dd", [], [Engine.text_v(row.field(|(_, v)| v))])]),
				),
			],
		)

	## The blocks as roc-docx reads them: an outline of the document's
	## structure, not a page layout.
	structure : State(ctx, S), Val(ctx, List(Explore.Block)), Bool -> Elem(ctx)
	structure = |st, blocks, selectable|
		Engine.element(
			"ol",
			[Engine.class("blocks")],
			[
				Engine.each(
					blocks,
					|b| b.index.to_str(),
					|row|
						Engine.element(
							"li",
							(
								if selectable {
									[
										Engine.class_v(row.select(Engine.keyed(st.val().map(|s| s.selected), "block selected", "block"))),
										Engine.on("click", st.lift_row().update_by(row.key(), |s, selected| { ..s, selected })),
									]
								} else {
									[Engine.class("block")]
								}
							),
							[
								Engine.element(
									"div",
									[Engine.class_v(row.field(Playground.block_class))],
									[
										Engine.switch(
											row.field(|b| if (b.kind == "table") 1.U8 else if (b.segments.is_empty() and b.kind != "paragraph") 2 else 0),
											[0, 1, 2],
											|shape|
												if shape == 1 {
													Playground.grid(row.field(|b| b.rows))
												} else if shape == 2 {
													Html.span_v(row.field(Playground.block_label), [Engine.class("label")])
												} else {
													Engine.each(
														row.field(|b| b.segments.map_with_index(|s, i| { key: i.to_str(), text: s.text, marks: s.marks })),
														|s| s.key,
														|seg| Engine.element("span", [Engine.class_v(seg.field(|s| s.marks))], [Engine.text_v(seg.field(|s| s.text))]),
													)
												},
										),
									],
								),
								Html.span_v(row.field(|b| if (b.comments.is_empty()) "" else "💬 ${b.comments.len().to_str()}"), [Engine.class("badge")]),
							],
						),
				),
			],
		)

	block_class : Explore.Block -> Str
	block_class = |b|
		if b.kind == "heading" {
			"content heading h${b.level.to_str()}"
		} else if b.kind == "list" {
			"content list l${b.level.to_str()}"
		} else {
			"content ${b.kind}"
		}

	block_label : Explore.Block -> Str
	block_label = |b|
		if b.kind == "section" {
			"Section break"
		} else if b.kind == "paragraph" {
			""
		} else {
			Str.join_with(b.segments.map(|s| s.text), "")
		}

	grid : Val(ctx, List(List(Str))) -> Elem(ctx)
	grid = |rows|
		Engine.element(
			"table",
			[Engine.class("grid")],
			[
				Engine.element(
					"tbody",
					[],
					[
						Engine.each(
							rows.map(|rs| rs.map_with_index(|cells, i| { key: i.to_str(), cells: cells.map_with_index(|c, j| (j.to_str(), c)) })),
							|r| r.key,
							|row| Engine.element("tr", [], [Engine.each(row.field(|r| r.cells), |(k, _)| k, |c| Engine.element("td", [], [Engine.text_v(c.field(|(_, t)| t))]))]),
						),
					],
				),
			],
		)

	## The selected block, four ways.
	inspector : State(ctx, S), Val(ctx, Explore.Model) -> Elem(ctx)
	inspector = |st, m| {
		b = Val.map2(m, st.val(), |model, s| Playground.block_at(model, s.selected))
		Engine.element(
			"aside",
			[Engine.class("inspector")],
			[
				Html.p_v(b.map(|x| "Block ${x.index.to_str()} · ${Playground.kind_name(x)}"), [Engine.class("inspector-title")]),
				Engine.element(
					"div",
					[Engine.class("panes"), Engine.attr("role", "tablist")],
					Playground.panes.map(
						|pane|
							Engine.element(
								"button",
								[
									Engine.attr("type", "button"),
									Engine.class_v(st.val().map(|s| if (s.pane == pane) "pane current" else "pane")),
									Engine.on("click", st.update(|s| { ..s, pane })),
								],
								[Engine.text(Playground.pane_name(pane))],
							),
					),
				),
				Engine.switch(
					st.val().map(|s| s.pane),
					Playground.panes,
					|pane|
						match pane {
							Properties =>
								Html.div(
									"facts",
									[
										Engine.element(
											"dl",
											[],
											[
												Engine.each(
													b.map(Playground.facts),
													|(k, _)| k,
													|row| Engine.element("div", [], [Engine.element("dt", [], [Engine.text_v(row.field(|(k, _)| k))]), Engine.element("dd", [], [Engine.text_v(row.field(|(_, v)| v))])]),
												),
											],
										),
										Playground.block_comments(Val.map2(m, b, |model, x| model.comments.keep_if(|c| x.comments.contains(c.id)))),
									],
								)
							Model => Playground.code_pane("The Document.Block value roc-docx made of this block, as Str.inspect prints it.", b.map(|x| x.model))
							Source => Playground.code_pane("The element of the body this block was read from, matched by position. Revision save identifiers (rsid) are left out, as reading drops them.", b.map(|x| x.source))
							Roc => Playground.code_pane("How an application reaches this block.", b.map(Playground.roc_for))
						},
				),
			],
		)
	}

	block_at : Explore.Model, Str -> Explore.Block
	block_at = |model, key|
		match U64.from_str(key) {
			Ok(i) => model.blocks.get(i) ?? Playground.no_block
			Err(_) => Playground.no_block
		}

	no_block : Explore.Block
	no_block = { index: 0, kind: "", level: 0, style: "", style_chain: [], segments: [], rows: [], comments: [], stated: [], source: "", model: "" }

	kind_name : Explore.Block -> Str
	kind_name = |b|
		if b.kind == "heading" {
			"Heading, level ${b.level.to_str()}"
		} else if b.kind == "list" {
			"List item, level ${b.level.to_str()}"
		} else if b.kind == "table" {
			"Table"
		} else if b.kind == "section" {
			"Section break"
		} else if b.kind == "marker" {
			"Comment range"
		} else if b.kind == "preserved" {
			"Preserved content"
		} else {
			"Paragraph"
		}

	pane_name : Pane -> Str
	pane_name = |pane|
		match pane {
			Properties => "Properties"
			Model => "Model"
			Source => "Source XML"
			Roc => "Roc"
		}

	facts : Explore.Block -> List((Str, Str))
	facts = |b| {
		style = if (b.style_chain.is_empty()) [] else [("Style", Str.join_with(b.style_chain, " → "))]
		table = if (b.kind == "table") [("Rows", b.rows.len().to_str()), ("Cells", b.rows.fold(0.U64, |n, r| n + r.len()).to_str())] else []
		comments = if (b.comments.is_empty()) [] else [("Comments", Str.join_with(b.comments.map(|id| id.to_str()), ", "))]
		[("Kind", Playground.kind_name(b))].concat(style).concat(b.stated).concat(table).concat(comments)
	}

	block_comments : Val(ctx, List(Explore.Comment)) -> Elem(ctx)
	block_comments = |comments|
		Engine.element(
			"ul",
			[Engine.class("thread")],
			[Engine.each(comments, |c| c.id.to_str(), |row| Playground.comment_card(row.field(|c| c)))],
		)

	code_pane : Str, Val(ctx, Str) -> Elem(ctx)
	code_pane = |about, code|
		Html.div("code-pane", [Engine.element("p", [Engine.class("muted")], [Engine.text(about)]), Engine.element("pre", [], [Engine.element("code", [], [Engine.text_v(code)])])])

	roc_for : Explore.Block -> Str
	roc_for = |b| {
		reach = "parsed = Docx.parse(bytes)?\nblock = Docx.body(parsed.document).get(${b.index.to_str()}) ?? crash \"no such block\""
		use =
			if b.kind == "table" {
				"match block {\n\tTable(table) => table.content # rows, each a list of cells\n\t_ => []\n}"
			} else if b.kind == "section" {
				"match block {\n\tSection(section) => section.page # size, margins, orientation\n\t_ => crash \"not a section\"\n}"
			} else if b.kind == "heading" or b.kind == "paragraph" or b.kind == "list" {
				style = if (b.style == "") "" else "\n\n# Its style, with what the style chain contributes:\nstyles = Docx.styles(parsed.document).styles\nStyles.get(styles, \"${b.style}\")"
				"match block {\n\tParagraph(paragraph) => Document.paragraph_text(paragraph)\n\t_ => \"\"\n}${style}"
			} else {
				"Str.inspect(block)"
			}
		"${reach}\n${use}"
	}

	# ── Comments and changes ───────────────────────────────────────────────

	annotations : State(ctx, S), Val(ctx, Explore.Model) -> Elem(ctx)
	annotations = |st, m|
		Html.div(
			"columns",
			[
				Html.div(
					"column",
					[
						Engine.element("h3", [], [Engine.text("Comments")]),
						Html.p_v(m.map(|x| if (x.comments.is_empty()) "This document has no comments." else ""), [Engine.class("muted")]),
						Engine.element(
							"ul",
							[Engine.class("thread")],
							[
								Engine.each(
									m.map(|x| x.comments),
									|c| c.id.to_str(),
									|row|
										Engine.element(
											"li",
											[Engine.class("link-card"), Engine.on("click", st.lift_row().update_by(row.field(|c| c.block), |s, block| if (block == "") s else { ..s, stage: Document, selected: block }))],
											[Playground.comment_body(row.field(|c| c))],
										),
								),
							],
						),
					],
				),
				Html.div(
					"column",
					[
						Engine.element("h3", [], [Engine.text("Tracked changes")]),
						Html.p_v(m.map(|x| if (x.changes.is_empty()) "This document has no tracked changes." else ""), [Engine.class("muted")]),
						Engine.element("ul", [Engine.class("changes")], [Engine.each(m.map(|x| x.changes), |c| c.id.to_str(), |row| Playground.change_card(row.field(|c| c)))]),
					],
				),
			],
		)

	comment_card : Val(ctx, Explore.Comment) -> Elem(ctx)
	comment_card = |c| Engine.element("li", [], [Playground.comment_body(c)])

	comment_body : Val(ctx, Explore.Comment) -> Elem(ctx)
	comment_body = |c|
		Engine.element(
			"article",
			[Engine.class_v(c.map(|x| if (x.reply) "comment reply" else "comment"))],
			[
				Html.p_v(c.map(|x| "${x.author}${if (x.resolved) " · resolved" else ""}"), [Engine.class("who")]),
				Html.p_v(c.map(|x| Playground.when_line(x.date, if (x.reply) "reply to ${x.parent.to_str()}" else "comment ${x.id.to_str()}")), [Engine.class("muted")]),
				Html.p_v(c.map(|x| if (x.anchor == "") "" else "“${x.anchor}”"), [Engine.class("anchor")]),
				Html.p_v(c.map(|x| x.text), []),
			],
		)

	change_card : Val(ctx, Explore.Change) -> Elem(ctx)
	change_card = |c|
		Engine.element(
			"li",
			[Engine.class("change")],
			[
				Html.p_v(c.map(|x| "${x.kind} ${x.subject}"), [Engine.class_v(c.map(|x| "kind ${Playground.change_class(x.kind)}"))]),
				Html.p_v(c.map(|x| Playground.when_line(x.date, "${x.author} · change ${x.id.to_str()}")), [Engine.class("muted")]),
				Html.p_v(c.map(|x| x.text), [Engine.class_v(c.map(|x| "changed ${Playground.change_class(x.kind)}"))]),
			],
		)

	change_class : Str -> Str
	change_class = |kind|
		match kind {
			"Inserted" => "ins"
			"Deleted" => "del"
			"Moved away" => "move-from"
			"Moved here" => "move-to"
			_ => "format"
		}

	when_line : Str, Str -> Str
	when_line = |date, rest| if (date == "") rest else "${rest} · ${date}"

	# ── Text, round trip and diagnostics ──────────────────────────────────

	texts : Val(ctx, Explore.Model) -> Elem(ctx)
	texts = |m|
		Html.div(
			"texts",
			[
				Playground.reading("As it stands", "Docx.text", m.map(|x| x.text)),
				Playground.reading("Every change accepted", "Docx.final_text", m.map(|x| x.final_text)),
				Playground.reading("Every change rejected", "Docx.original_text", m.map(|x| x.original_text)),
			],
		)

	reading : Str, Str, Val(ctx, Str) -> Elem(ctx)
	reading = |title, call, text|
		Html.div(
			"reading",
			[
				Engine.element("h3", [], [Engine.text(title), Engine.element("code", [], [Engine.text(call)])]),
				Engine.element("pre", [Engine.class("prose")], [Engine.text_v(text)]),
			],
		)

	round_trip : State(ctx, S) -> Elem(ctx)
	round_trip = |st|
		Worker.derive_when(
			Explore.round_trip,
			st.val().map(Playground.document_of),
			|remote| {
				w = remote.map(
					|r|
						match r.answer {
							Answered(written) => written
							_ => { compared: [], size: 0, equivalent: Bool.False, base64: "" }
						},
				)
				Html.div(
					"round-trip",
					[
						Html.p_v(remote.map(Playground.status), [Engine.class("status")]),
						Html.p_v(w.map(|x| if (x.size == 0) "" else if (x.equivalent) "✓ Written in ${Playground.bytes(x.size)}, and it reads as the same document." else "✗ Written in ${Playground.bytes(x.size)}, but it reads differently."), [Engine.class_v(w.map(|x| if (x.equivalent) "verdict good" else "verdict"))]),
						Playground.download(w.map(|x| x.base64), "written.docx", "Download the written document"),
						Playground.table(
							["Part", "After writing", "Read", "Written"],
							[
								Engine.each(
									w.map(|x| x.compared),
									|c| c.name,
									|row|
										Engine.element(
											"tr",
											[],
											[
												Playground.cell(row.field(|c| c.name), "mono"),
												Engine.element("td", [], [Html.span_v(row.field(|c| c.outcome), [Engine.class_v(row.field(|c| "outcome ${c.outcome}"))])]),
												Playground.cell(row.field(|c| if (c.before == 0) "—" else Playground.bytes(c.before)), "num"),
												Playground.cell(row.field(|c| if (c.after == 0) "—" else Playground.bytes(c.after)), "num"),
											],
										),
								),
							],
						),
					],
				)
			},
		)

	download : Val(ctx, Str), Str, Str -> Elem(ctx)
	download = |base64, name, label|
		Engine.element(
			"a",
			[
				Engine.class_v(base64.map(|b| if (b == "") "button hidden" else "button")),
				Engine.attr("download", name),
				Engine.attr_v("href", base64.map(|b| if (b == "") "#" else "data:application/vnd.openxmlformats-officedocument.wordprocessingml.document;base64,${b}")),
			],
			[Engine.text(label)],
		)

	problems : Val(ctx, Explore.Model) -> Elem(ctx)
	problems = |m|
		Html.div(
			"diagnostics",
			[
				Html.p_v(m.map(|x| if (x.diagnostics.is_empty()) "Reading took everything exactly as written." else ""), [Engine.class("muted")]),
				Engine.element(
					"ul",
					[],
					[
						Engine.each(
							m.map(|x| x.diagnostics.map_with_index(|d, i| { key: i.to_str(), stage: d.stage, text: d.text })),
							|d| d.key,
							|row| Engine.element("li", [], [Html.span_v(row.field(|d| d.stage), [Engine.class("kind")]), Html.span_v(row.field(|d| d.text), [Engine.class("mono")])]),
						),
					],
				),
			],
		)

	# ── Review ─────────────────────────────────────────────────────────────

	review : State(ctx, S) -> Elem(ctx)
	review = |st|
		Engine.when(
			st.val().map(Playground.is_loaded),
			||
				Engine.element(
					"main",
					[Engine.class("review")],
					[
						Playground.file_bar(st),
						Worker.derive_when(
							Review.review,
							st.val().map(
								|s|
									match s.file {
										Loaded({ doc, .. }) => Run({ doc, edits: s.edits, author: s.reviewer, date: s.now })
										_ => Skip
									},
							),
							|remote| Playground.reviewing(st.lift(), remote),
						),
					],
				),
			|| Engine.element("main", [], [Playground.welcome(st, "Review a document", "Accept and reject tracked changes, reply to and resolve comments, and download the result. Start with the tracked changes sample, or drop a document of your own.")]),
		)

	reviewing : State(ctx, S), Val(ctx, Engine.Remote(Review.Reviewed, Worker.Error(Explore.Problem))) -> Elem(ctx)
	reviewing = |st, remote| {
		r = remote.map(
			|x|
				match x.answer {
					Answered(reviewed) => reviewed
					_ => { model: Playground.no_model, base64: "", size: 0 }
				},
		)
		m = r.map(|x| x.model)
		v = st.val()
		Html.div(
			"reviewing",
			[
				Engine.element(
					"div",
					[Engine.class("toolbar")],
					[
						Html.text_input(Engine.const("Reviewer"), "text", v.map(|s| s.reviewer), [Engine.class("reviewer")], st.set_value(|s, reviewer| { ..s, reviewer })),
						Html.button("Accept all", [], st.update(|s| { ..s, edits: List.append(s.edits, AcceptAll) })),
						Html.button("Reject all", [], st.update(|s| { ..s, edits: List.append(s.edits, RejectAll) })),
						Html.button_v(m.map(|x| if (x.tracking) "Stop tracking changes" else "Track changes"), [], st.update_by(m.map(|x| x.tracking), |s, on| { ..s, edits: List.append(s.edits, Tracking(!on)) })),
						Html.action_button(Engine.const("Undo"), v.map(|s| s.edits.is_empty()), [], st.update(|s| { ..s, edits: s.edits.drop_last(1) })),
						Playground.download(r.map(|x| x.base64), "reviewed.docx", "Download"),
						Html.button("Explore this version", [Engine.class("quiet")], st.update_by(r.map(|x| x.base64), |s, b| Playground.opened(s, "reviewed.docx", b))),
					],
				),
				Html.p_v(remote.map(Playground.status), [Engine.class("status")]),
				Html.p_v(v.map(|s| if (s.edits.is_empty()) "No edits yet. Each edit is applied by roc-docx in a worker, and the document below is the written result read back." else Str.join_with(s.edits.map(Review.describe), " · ")), [Engine.class("edits")]),
				Html.div(
					"review-grid",
					[
						Engine.element("div", [Engine.class("page")], [Playground.structure(st, m.map(|x| x.blocks), Bool.False)]),
						Engine.element(
							"aside",
							[Engine.class("review-side")],
							[
								Engine.element("h3", [], [Engine.text("Tracked changes")]),
								Html.p_v(m.map(|x| if (x.changes.is_empty()) "No tracked changes remain." else ""), [Engine.class("muted")]),
								Engine.element(
									"ul",
									[Engine.class("changes")],
									[
										Engine.each(
											m.map(|x| x.changes),
											|c| c.id.to_str(),
											|row|
												Engine.element(
													"li",
													[Engine.class("change")],
													[
														Playground.change_card(row.field(|c| c)),
														Engine.element(
															"div",
															[Engine.class("actions")],
															[
																Html.button("Accept", [], st.lift_row().update_by(row.field(|c| c.id), |s, id| { ..s, edits: List.append(s.edits, Accept(id)) })),
																Html.button("Reject", [], st.lift_row().update_by(row.field(|c| c.id), |s, id| { ..s, edits: List.append(s.edits, Reject(id)) })),
															],
														),
													],
												),
										),
									],
								),
								Engine.element("h3", [], [Engine.text("Comments")]),
								Html.p_v(m.map(|x| if (x.comments.is_empty()) "No comments." else ""), [Engine.class("muted")]),
								Engine.element(
									"ul",
									[Engine.class("thread")],
									[
										Engine.each(
											m.map(|x| x.comments),
											|c| c.id.to_str(),
											|row| {
												rs = st.lift_row()
												Engine.element(
													"li",
													[],
													[
														Playground.comment_body(row.field(|c| c)),
														Engine.element(
															"div",
															[Engine.class("actions")],
															[
																Html.action_button(Engine.const("Resolve"), row.field(|c| c.resolved or c.reply), [], rs.update_by(row.field(|c| c.id), |s, id| { ..s, edits: List.append(s.edits, Resolve(id)) })),
																Html.button("Reply", [], rs.update_by(row.key(), |s, key| { ..s, replying: key, reply: "" })),
															],
														),
														Engine.when(
															row.select(Engine.keyed(st.val().map(|s| s.replying), Bool.True, Bool.False)),
															||
																Engine.element(
																	"div",
																	[Engine.class("reply-form")],
																	[
																		Html.text_input(Engine.const("Reply"), "text", rs.val().map(|s| s.reply), [], rs.set_value(|s, reply| { ..s, reply })),
																		Html.button("Send", [], rs.update(Playground.sent)),
																		Html.button("Cancel", [Engine.class("quiet")], rs.update(|s| { ..s, replying: "" })),
																	],
																),
															|| Engine.text(""),
														),
													],
												)
											},
										),
									],
								),
							],
						),
					],
				),
			],
		)
	}

	sent : S -> S
	sent = |s|
		match U64.from_str(s.replying) {
			Ok(to) if !s.reply.trim().is_empty() => { ..s, edits: List.append(s.edits, Reply({ to, text: s.reply.trim() })), replying: "", reply: "" }
			_ => s
		}

	# ── Generate ───────────────────────────────────────────────────────────

	generate : State(ctx, S) -> Elem(ctx)
	generate = |st| {
		v = st.val()
		letter = v.map(|s| s.letter)
		Engine.element(
			"main",
			[Engine.class("generate")],
			[
				Engine.element(
					"header",
					[Engine.class("stage-header")],
					[
						Engine.element("h2", [], [Engine.text("Generate a letter")]),
						Engine.element("p", [], [Engine.text("A new document from roc-docx's default kit, built with Build as examples/letter does. Edit the form: each change builds the document again in a worker, writes it and reads it back.")]),
					],
				),
				Html.div(
					"generate-grid",
					[
						Engine.element(
							"form",
							[Engine.class("letter-form")],
							[
								Playground.letter_field(st, Bool.True, "From", |l| l.sender, |l, x| { ..l, sender: x }),
								Playground.letter_field(st, Bool.False, "Date", |l| l.date, |l, x| { ..l, date: x }),
								Playground.letter_field(st, Bool.True, "To", |l| l.recipient, |l, x| { ..l, recipient: x }),
								Playground.letter_field(st, Bool.False, "Subject", |l| l.subject, |l, x| { ..l, subject: x }),
								Playground.letter_field(st, Bool.True, "Letter (a blank line between paragraphs)", |l| l.body, |l, x| { ..l, body: x }),
								Playground.letter_field(st, Bool.False, "Closing", |l| l.closing, |l, x| { ..l, closing: x }),
								Playground.letter_field(st, Bool.True, "Signature", |l| l.signature, |l, x| { ..l, signature: x }),
								Playground.letter_field(st, Bool.False, "A reviewer's comment on the subject", |l| l.note, |l, x| { ..l, note: x }),
							],
						),
						Worker.derive(
							Generate.letter,
							letter,
							|remote| {
								r = remote.map(
									|x|
										match x.answer {
											Answered(made) => made
											_ => { model: Playground.no_model, base64: "", size: 0 }
										},
								)
								Html.div(
									"generated",
									[
										Engine.element(
											"div",
											[Engine.class("toolbar")],
											[
												Playground.download(r.map(|x| x.base64), "letter.docx", "Download letter.docx"),
												Html.button("Explore this document", [Engine.class("quiet")], st.lift().update_by(r.map(|x| x.base64), |s, b| Playground.opened(s, "letter.docx", b))),
												Html.span_v(remote.map(|x| if (x.request == Pending) "Building…" else ""), [Engine.class("muted")]),
											],
										),
										Html.p_v(remote.map(Playground.status), [Engine.class("status")]),
										Engine.element("div", [Engine.class("page")], [Playground.structure(st.lift(), r.map(|x| x.model.blocks), Bool.False)]),
										Engine.element("h3", [], [Engine.text("The Roc that builds it")]),
										Engine.element("pre", [], [Engine.element("code", [], [Engine.text_v(st.lift().val().map(|s| Generate.source(s.letter)))])]),
									],
								)
							},
						),
					],
				),
			],
		)
	}

	## One labelled field of the letter's form.
	letter_field : State(ctx, S), Bool, Str, (Generate.Letter -> Str), (Generate.Letter, Str -> Generate.Letter) -> Elem(ctx)
	letter_field = |st, multiline, label, get, set| {
		value = st.val().map(|s| get(s.letter))
		changed = st.set_value(|s, text| { ..s, letter: set(s.letter, text) })
		input = if (multiline) Html.textarea(Engine.const(label), value, [], changed) else Html.text_input(Engine.const(label), "text", value, [], changed)
		Engine.element("label", [], [Engine.text(label), input])
	}

	# ── Pieces ─────────────────────────────────────────────────────────────

	table : List(Str), List(Elem(ctx)) -> Elem(ctx)
	table = |headings, rows|
		Engine.element(
			"div",
			[Engine.class("table-scroll")],
			[
				Engine.element(
					"table",
					[],
					[
						Engine.element("thead", [], [Engine.element("tr", [], headings.map(|h| Engine.element("th", [], [Engine.text(h)])))]),
						Engine.element("tbody", [], rows),
					],
				),
			],
		)

	cell : Val(ctx, Str), Str -> Elem(ctx)
	cell = |text, class| Engine.element("td", [Engine.class(class)], [Engine.text_v(text)])

	bytes : U64 -> Str
	bytes = |n|
		if n < 1024 {
			"${n.to_str()} B"
		} else if n < 1024 * 1024 {
			"${((n * 10 + 512) // 1024 // 10).to_str()}.${((n * 10 + 512) // 1024 % 10).to_str()} KB"
		} else {
			"${((n * 10) // (1024 * 1024) // 10).to_str()}.${((n * 10) // (1024 * 1024) % 10).to_str()} MB"
		}
}

## A URL names a sample, a stage and a block.
expect {
	s = Playground.initial("https://example.org/playground/#mode=explore&sample=revisions&stage=xml&block=3")
	s.stage == Xml and s.selected == "3" and s.sample == "revisions" and Playground.fragment(s) == "#mode=explore&sample=revisions&stage=xml&block=3"
}

## A drop names the file before its bytes.
expect Playground.dropped(Playground.empty, "a.docx\nTWE=").file == Loaded({ name: "a.docx", doc: Wire.Bytes.from_list([77, 97]) })

## Sizes read as people write them.
expect Playground.bytes(512) == "512 B" and Playground.bytes(1536) == "1.5 KB"
