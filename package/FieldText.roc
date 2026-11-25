import Document
import FieldPhase

# Appended UTF-8 text and the field phase of the next piece of the story.
State : { bytes : List(U8), phase : FieldPhase }

View : [Current, Final, Original, Shown]

FieldText := [].{
	paragraph : Document.Paragraph, FieldPhase -> { text : Str, phase : FieldPhase }
	paragraph = |value, phase| {
		read = value.content.fold({ bytes: List.with_capacity(64), phase }, |state, item| inline(state, item, Current))
		{ text: Str.from_utf8(read.bytes) ?? "", phase: read.phase }
	}

	inline : State, Document.Inline, View -> State
	inline = |state, item, view|
		match item {
			Run(run) => run.content.fold(state, content)
			Revision(revision) if hidden(revision.kind, view) => state
			Revision(revision) => revision.content.fold(state, |read, child| inline(read, child, view))
			Hyperlink({ target: _, preserved: _, content: children }) => children.fold(state, |read, child| inline(read, child, view))
			SimpleField({ code: _, preserved: _, content: children }) => {
				read = children.fold({ ..state, phase: FieldPhase.empty }, |walk, child| inline(walk, child, view))
				{ ..read, phase: state.phase }
			}
			Container({ element: _, content: children }) => children.fold(state, |read, child| inline(read, child, view))
			_ => state
		}
}

content : State, Document.RunContent -> State
content = |state, item| {
	append = |value| { ..state, bytes: value.iter_utf8().fold(state.bytes, |bytes, byte| bytes.append(byte)) }
	match item {
		Text(value) => append(value)
		FieldMark({ kind, element: _ }) => { ..state, phase: FieldPhase.step(state.phase, kind) }
		FieldCode(value) => if (FieldPhase.is_instruction(state.phase)) state else append(value)
		_ => { ..state, bytes: Document.append_inline_text(state.bytes, Run({ properties: Document.no_run_properties, content: [item] })) }
	}
}

hidden : Document.RevisionKind, View -> Bool
hidden = |kind, view|
	match view {
		Current | Final => kind == Deletion or kind == MoveSource
		Original => kind == Insertion or kind == MoveDestination
		Shown => Bool.False
	}
