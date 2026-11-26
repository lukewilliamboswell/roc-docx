# The open complex fields in one story as seen in one revision view.
# Ordinary text is outside the nearest field's instruction. An enclosing
# instruction can still prevent it from reaching an enclosing result.
Mode : [Outside, Instruction, Result]

FieldPhase := { mode : Mode, suspended : List(Mode) }.{
	empty : FieldPhase
	empty = { mode: Outside, suspended: [] }

	step : FieldPhase, [Begin, Separate, End] -> FieldPhase
	step = |phase, mark|
		match (phase.mode, mark) {
			(Outside, Begin) => { ..phase, mode: Instruction }
			(mode, Begin) => { mode: Instruction, suspended: phase.suspended.append(mode) }
			(Instruction, Separate) => { ..phase, mode: Result }
			(Outside, End) => phase
			(_, End) => {
				mode: phase.suspended.last() ?? Outside,
				suspended: phase.suspended.drop_last(1),
			}
			(_, Separate) => phase
		}

	is_open : FieldPhase -> Bool
	is_open = |phase| phase.mode != Outside

	is_instruction : FieldPhase -> Bool
	is_instruction = |phase| phase.mode == Instruction
}
