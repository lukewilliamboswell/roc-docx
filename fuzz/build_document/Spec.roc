import docx.Build
import docx.Docx
import docx.Document
import docx.Opc
import fuzz.Model
import fuzz.Solve
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

## Build.table uses this saturated addition both for its whole-grid budget
## and for individual spans when the grid exceeds I64. Each step fits
## exactly when the next width fits in the remaining signed budget. Once a
## prefix exceeds it, nonnegative widths keep that result outside the budget.
## When the whole grid fits, every span fits by the same nonnegativity.
expect Solve.prove_within(
	{ subtotal: Solve.u64, column: Solve.u64 }.Solve,
	|v| {
		cap = Solve.num(9_223_372_036_854_775_807)
		sum = Solve.if_else(v.subtotal.plus_overflows(v.column), Solve.num(U64.highest), v.subtotal + v.column)
		fits = sum.lte(cap)
		room = Solve.all([v.subtotal.lte(cap), v.column.lte(cap - v.subtotal)])
		Solve.all([
			fits.implies(room),
			room.implies(fits),
			room.implies(sum.eq(v.subtotal + v.column)),
		])
	},
	5_000,
) == Ok(Proved)

# The grid and cell preferences are independent WML fields. Read them
# back through the facade to exercise both widths that are written and the
# schema's absent preferred width.
table_widths = |columns, cells| {
	table = Build.table({ widths: columns }, [cells])
	document = Build.append(Docx.new_document({})?, [table])
	written = Docx.to_bytes(document)?
	read = Docx.parse(written)?
	part = Opc.part_bytes(Opc.open(written, {})?, "/word/document.xml")?
	xml = Str.from_utf8(part)?
	preferred_count = xml.split_on("<w:tcW").len() - 1
	Ok(
		match Docx.body(read.document).first() {
			Ok(Table(reopened)) => {
				grid: reopened.grid,
				widths: Document.table_rows(reopened).map(|row| Document.row_cells(row).map(|cell| cell.properties.width)),
				preferred_count,
			}
			_ => { grid: [], widths: [], preferred_count }
		},
	)
}

## A preferred cell width at the signed boundary is exact. Larger column
## widths and larger spanning sums stay in the grid, with no preferred
## cell width. ECMA-376 Part 4 makes that property optional in CT_TcPrBase.
expect {
	cap = 9_223_372_036_854_775_807.U64
	exact = [cap - 1, 1]
	merged = Build.cell({ span: 2 }, [])
	columns = [cap - 1, 1, cap + 1, cap, 1]
	cells = [merged, Build.cell({}, []), merged]
	table_widths(exact, [merged])? == { grid: exact.map(|width| Column(width)), widths: [[Twips(I64.highest)]], preferred_count: 1 }
		and table_widths(columns, cells)?
			== { grid: columns.map(|width| Column(width)), widths: [[Twips(I64.highest), Unset, Unset]], preferred_count: 1 }
}

## A spanning cell can exceed even U64. Once its preferred width is
## unrepresentable, later columns and cells still follow the grid.
expect {
	columns = [U64.highest, 1, 0, 37]
	cells = [Build.cell({ span: 3 }, []), Build.cell({}, [])]
	table_widths(columns, cells)?
		== { grid: columns.map(|width| Column(width)), widths: [[Unset, Twips(37)]], preferred_count: 1 }
}
