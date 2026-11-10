import pf.Engine exposing [Elem, In, Root, State, Val]
import pf.Html
import pf.Wire
import pf.Worker
import Base64
import Explore

## The roc-docx playground: load a Word document and explore it layer by
## layer. Everything is computed in workers from the document's bytes.
Playground := [].{

	Tab : [Package, Document, Review, Xml, Diagnostics, RoundTrip]

	File : [Empty, Loaded({ name : Str, doc : Wire.Bytes }), BadFile(Str)]

	S : { file : File, tab : Tab, part : Str }

	Ctx : In(Root, S)

	program : Engine.Program
	program =
		Engine.program(|| Engine.state({ file: Empty, tab: Package, part: "/word/document.xml" }, Playground.view))
			.with_workers([Explore.explore.registration(), Explore.part_xml.registration(), Explore.round_trip.registration()])

	tabs : List(Tab)
	tabs = [Package, Document, Review, Xml, Diagnostics, RoundTrip]

	view : State(Ctx, S) -> Elem(Ctx)
	view = |st| {
		v = st.val()
		Html.div(
			"playground",
			[
				Html.h1("roc-docx playground", "title"),
				Html.p("Drop a .docx file below, or choose one. It is read in your browser by roc-docx compiled to WebAssembly; nothing is uploaded.", "hint"),
				Engine.element("docx-file", [Html.aria_label("Word document"), Engine.on("change", st.set_value(Playground.loaded))], []),
				Html.p_v(v.map(Playground.file_line), [Engine.test_id("file")]),
				Html.div("tabs", Playground.tabs.map(|tab| Playground.tab_button(st, tab))),
				Worker.derive_when(Explore.explore, v.map(Playground.document_of), |remote| Playground.results(st.lift(), remote)),
			],
		)
	}

	## The custom element's payload: the file name, a line feed, and the
	## file's bytes as base64.
	loaded : S, Str -> S
	loaded = |s, payload|
		match payload.split_first("\n") {
			Ok({ before: name, after }) =>
				match Base64.decode(after) {
					Ok(bytes) => { ..s, file: Loaded({ name, doc: Wire.Bytes.from_list(bytes) }), part: "/word/document.xml" }
					Err(_) => { ..s, file: BadFile(name) }
				}
			Err(_) => { ..s, file: BadFile("") }
		}

	file_line : S -> Str
	file_line = |s|
		match s.file {
			Empty => "No document loaded."
			Loaded({ name, doc }) => "${name} · ${doc.to_list().len().to_str()} bytes"
			BadFile(name) => "Could not read ${name}."
		}

	document_of : S -> [Run(Wire.Bytes), Skip]
	document_of = |s|
		match s.file {
			Loaded({ doc, .. }) => Run(doc)
			_ => Skip
		}

	tab_button : State(Ctx, S), Tab -> Elem(Ctx)
	tab_button = |st, tab|
		Html.button(
			Playground.tab_name(tab),
			[Engine.class_v(st.val().map(|s| if (s.tab == tab) "tab selected" else "tab"))],
			st.update(|s| { ..s, tab }),
		)

	tab_name : Tab -> Str
	tab_name = |tab|
		match tab {
			Package => "Package"
			Document => "Document"
			Review => "Comments and changes"
			Xml => "XML"
			Diagnostics => "Diagnostics"
			RoundTrip => "Round trip"
		}

	results : State(In(Ctx, Worker.Remote(Try(Explore.Explored, Explore.Problem))), S), Val(In(Ctx, Worker.Remote(Try(Explore.Explored, Explore.Problem))), Worker.Remote(Try(Explore.Explored, Explore.Problem))) -> Elem(In(Ctx, Worker.Remote(Try(Explore.Explored, Explore.Problem))))
	results = |st, remote| {
		e = remote.map(Playground.explored_of)
		Html.div(
			"results",
			[
				Html.p_v(remote.map(Playground.status), [Engine.class("status"), Engine.test_id("status")]),
				Engine.switch(
					st.val().map(|s| s.tab),
					Playground.tabs,
					|tab|
						match tab {
							Package => Html.div("panel", [Playground.section("Parts", e.map(|x| x.parts)), Playground.section("Relationships of the main document", e.map(|x| x.relationships))])
							Document => Html.div("panel", [Playground.section("Core properties", e.map(|x| x.properties)), Playground.section("Body", e.map(|x| x.blocks))])
							Review =>
								Html.div(
									"panel",
									[
										Playground.section("Comments", e.map(|x| x.comments)),
										Playground.section("Tracked changes", e.map(|x| x.revisions)),
										Html.div(
											"texts",
											[
												Html.div("text", [Html.h2("Original text", ""), Html.pre_v(e.map(|x| x.original_text), [])]),
												Html.div("text", [Html.h2("Final text", ""), Html.pre_v(e.map(|x| x.final_text), [])]),
											],
										),
									],
								)
							Xml => Playground.xml(st, e)
							Diagnostics => Html.div("panel", [Playground.section("Diagnostics", e.map(|x| x.diagnostics))])
							RoundTrip => Playground.round_trip(st)
						},
				),
			],
		)
	}

	explored_of : Worker.Remote(Try(Explore.Explored, Explore.Problem)) -> Explore.Explored
	explored_of = |r|
		match r.answer {
			Done(Ok(e)) => e
			_ => { summary: "", parts: [], relationships: [], properties: [], blocks: [], comments: [], revisions: [], diagnostics: [], final_text: "", original_text: "", xml_parts: [] }
		}

	status : Worker.Remote(Try(Explore.Explored, Explore.Problem)) -> Str
	status = |{ running, answer }|
		match answer {
			Nothing => if (running) "Reading the document…" else ""
			Done(Ok(e)) => if (running) "${e.summary} (reading…)" else e.summary
			Done(Err(Unreadable(why))) => "roc-docx could not read this document: ${why}"
			Failed(error) => Playground.problem(error)
		}

	problem : Worker.Error -> Str
	problem = |error|
		match error {
			Timeout => "This took too long."
			Refused => "Too much is running; try again."
			Lost(fault) => "The worker failed: ${Str.inspect(fault)}"
		}

	section : Str, Val(ctx, List(Explore.Card)) -> Elem(ctx)
	section = |title, cards|
		Html.section(
			title,
			"section",
			[
				Html.h2(title, ""),
				Html.p_v(cards.map(|c| if (c.is_empty()) "None." else "${c.len().to_str()} items"), [Engine.class("hint")]),
				Html.ul(
					[Engine.class("cards")],
					[
						Engine.each(
							cards,
							|c| c.key,
							|row|
								Html.li(
									[Engine.class("card")],
									[
										Html.p_v(row.field(|c| c.title), [Engine.class("card-title")]),
										Html.p_v(row.field(|c| c.detail), [Engine.class("card-detail")]),
										Html.pre_v(row.field(|c| c.body), [Engine.class("card-body")]),
									],
								),
						),
					],
				),
			],
		)

	xml : State(ctx, S), Val(ctx, Explore.Explored) -> Elem(ctx)
	xml = |st, e| {
		v = st.val()
		Html.div(
			"panel",
			[
				Html.select(
					Engine.const("Part"),
					v.map(|s| s.part),
					[],
					[Engine.each(e.map(|x| x.xml_parts), |n| n, |row| Html.option_v(row.field(|n| n)))],
					st.set_value(|s, part| { ..s, part }),
				),
				Worker.derive_when(
					Explore.part_xml,
					v.map(|s| match s.file {
						Loaded({ doc, .. }) => Run({ doc, part: s.part })
						_ => Skip
					}),
					|remote| Html.pre_v(remote.map(Playground.show_xml), [Engine.class("xml")]),
				),
			],
		)
	}

	show_xml : Worker.Remote(Try(Str, Explore.Problem)) -> Str
	show_xml = |{ running, answer }|
		match answer {
			Nothing => if (running) "Reading the part…" else ""
			Done(Ok(text)) => text
			Done(Err(Unreadable(why))) => "This part could not be read: ${why}"
			Failed(error) => Playground.problem(error)
		}

	round_trip : State(ctx, S) -> Elem(ctx)
	round_trip = |st|
		Worker.derive_when(
			Explore.round_trip,
			st.val().map(Playground.document_of),
			|remote|
				Html.div(
					"panel",
					[
						Html.p_v(remote.map(Playground.show_written), [Engine.test_id("round-trip")]),
						Engine.element(
							"a",
							[Engine.attr_v("href", remote.map(Playground.download_url)), Engine.attr("download", "roundtrip.docx"), Engine.class("button")],
							[Engine.text("Download the written document")],
						),
					],
				),
		)

	show_written : Worker.Remote(Try(Explore.Written, Explore.Problem)) -> Str
	show_written = |{ running, answer }|
		match answer {
			Nothing => if (running) "Writing the document back…" else ""
			Done(Ok(w)) => w.summary
			Done(Err(Unreadable(why))) => why
			Failed(error) => Playground.problem(error)
		}

	download_url : Worker.Remote(Try(Explore.Written, Explore.Problem)) -> Str
	download_url = |r|
		match r.answer {
			Done(Ok(w)) => "data:application/vnd.openxmlformats-officedocument.wordprocessingml.document;base64,${w.base64}"
			_ => "#"
		}
}

## The payload names the file before its bytes.
expect {
	s = Playground.loaded({ file: Empty, tab: Package, part: "" }, "a.docx\nTWE=")
	Playground.file_line(s) == "a.docx · 2 bytes"
}
