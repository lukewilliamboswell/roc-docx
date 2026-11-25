import docx.Build
import docx.Docx
import docx.Document
import fuzz.Model
import NoteOwnership

Spec := [].{}

Page : [Default, Even, First]

Region : [Header, Footer]

Slot : { region : Region, page : Page }

Action : [Put(Slot), NewSection, SameOddAndEven]

Section : List({ slot : Slot, text : Str })

Reference : { sections : List(Section), writes : U64, different_odd_and_even : Bool }

World : { document : Document, reference : Reference }

# The body may be held separately from its main XML shell. Keep both, and
# keep every XML part and relationship read by the builders.
Key := { reference : Reference, body : List(Document.Block), parts : List(Document.XmlPart) }.{
	is_eq : _
	to_hash = |{ reference, .. }, hasher| reference.to_hash(hasher)
}

actions : World -> List(Action)
actions = |{ reference, .. }| {
	writes = if reference.writes < 3 {
		List.join([Header, Footer].map(|region| [Default, Even, First].map(|page| Put({ region, page }))))
	} else {
		[]
	}
	with_section = if (reference.sections.len() == 1) writes.append(NewSection) else writes
	if (reference.different_odd_and_even) with_section.append(SameOddAndEven) else with_section
}

step : World, Action -> World
step = |{ document, reference }, action| match action {
	Put(slot) => {
		text = "Region ${(reference.writes + 1).to_str()}"
		content = [Build.paragraph({}, [Build.text(text, {})])]
		edited = match slot.region {
			Header => Build.header(document, { kind: slot.page }, content)
			Footer => Build.footer(document, { kind: slot.page }, content)
		}
		before = reference.sections.last() ?? []
		section = before.drop_if(|entry| entry.slot == slot).append({ slot, text })
		{
			document: edited ?? crash "a region builder failed",
			reference: {
				sections: reference.sections.drop_last(1).append(section),
				writes: reference.writes + 1,
				different_odd_and_even: reference.different_odd_and_even or slot.page == Even,
			},
		}
	}
	NewSection => {
		document: Build.new_section(document, {}),
		reference: { ..reference, sections: reference.sections.append([]) },
	}
	SameOddAndEven => {
		document: Docx.set_different_odd_and_even(document, Off) ?? crash "setting odd and even pages alike failed",
		reference: { ..reference, different_odd_and_even: Bool.False },
	}
}

# This projection describes section-owned references. An inherited region
# has no reference in the receiving section; layout consumes that absence.
part_for : Document.Section, Slot -> Try(Str, [Absent])
part_for = |section, slot| {
	parts = match slot.region {
		Header => section.headers
		Footer => section.footers
	}
	parts.find_first(|part| part.kind == slot.page).map_ok(|part| part.part).map_err(|_| Absent)
}

has_page : Section, Page -> Bool
has_page = |section, page| section.any(|entry| entry.slot.page == page)

matches : Document, Reference -> Bool
matches = |document, reference| {
	sections = Docx.sections(document)
	if sections.len() != reference.sections.len() or Docx.different_odd_and_even(document) != reference.different_odd_and_even {
		return Bool.False
	}
	var $at = 0.U64
	var $owned = Set.empty()
	for one in reference.sections {
		actual = sections.get($at) ?? return Bool.False
		title = if (has_page(one, First)) On else Unset
		if actual.title_page != title or actual.headers.len() + actual.footers.len() != one.len() {
			return Bool.False
		}
		for entry in one {
			part = part_for(actual, entry.slot) ?? return Bool.False
			if $owned.contains(part) {
				return Bool.False
			}
			$owned = $owned.insert(part)
			match Docx.header_footer(document, part) {
				[Paragraph(paragraph)] if Document.paragraph_text(paragraph) == entry.text => {}
				_ => return Bool.False
			}
		}
		$at = $at + 1
	}
	Bool.True
}

reuses_part : Model.Transition(World, Action) -> Bool
reuses_part = |{ before, action, after }| match action {
	Put(slot) => {
		old = Docx.sections(before.document).last().map_ok(|section| part_for(section, slot))
		match old {
			Ok(Ok(part)) => Docx.sections(after.document).last().map_ok(|section| part_for(section, slot)) == Ok(Ok(part))
			_ => Bool.True
		}
	}
	_ => Bool.True
}

split_with_both : Str
split_with_both = "a new section follows a title page while odd and even pages differ"

machine : Model.Machine(World, Action)
machine = {
	init: {
		document: Docx.new_document({}) ?? crash "the header model document could not be built",
		reference: { sections: [[]], writes: 0, different_odd_and_even: Bool.False },
	},
	actions,
	step,
	rules: [
		Model.always("each section has exactly its own headers, footers and title-page setting", |world| matches(world.document, world.reference)),
		Model.always_step("editing the same role and page reuses its part", reuses_part),
		Model.sometimes_step(split_with_both, |{ before, action, after: _ }| action == NewSection and has_page(before.reference.sections.last() ?? [], First) and before.reference.different_odd_and_even),
		Model.sometimes_step(
			"a first-page region survives an even-page edit in the same section",
			|{ before, action, after: _ }| match action {
				Put({ page: Even, .. }) => has_page(before.reference.sections.last() ?? [], First)
				_ => Bool.False
			},
		),
		Model.sometimes_step(
			"an even-page edit re-enables different pages after they were disabled",
			|{ before, action, after }| match action {
				Put({ page: Even, .. }) => !before.reference.different_odd_and_even and before.reference.sections.any(|one| has_page(one, Even)) and after.reference.different_odd_and_even
				_ => Bool.False
			},
		),
		Model.sometimes_step(
			"a first-page region is replaced",
			|{ before, action, after: _ }| match action {
				Put(slot) => slot.page == First and (before.reference.sections.last() ?? []).any(|entry| entry.slot == slot)
				_ => Bool.False
			},
		),
	],
}

## Exhaust three writes across at most two sections. Preserve the complete
## parts and body in the search key, and also check steps that revisit a state.
## Save and reopen a section split after both page settings were enabled.
expect {
	report = Model.explore(machine, { depth: 10, key: |world| Key.{ reference: world.reference, body: Docx.body(world.document), parts: Document.xml_parts(world.document) }, verify: EveryStep })
	match report.verdict {
		Holds(Exhausted) => {
			trace = Model.witness(report, split_with_both)?
			final = trace.fold(machine.init, step)
			parsed = Docx.parse(Docx.to_bytes(final.document)?)?
			matches(parsed.document, final.reference)
		}
		_ => crash "${Model.explain(report)} ${Str.inspect(report.verdict)}"
	}
}
