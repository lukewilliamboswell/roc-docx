import pf.Wire
import pf.Worker
import docx.Docx
import docx.Document
import Base64
import Explore

## Review a document: accept and reject its tracked changes, reply to and
## resolve its comments, and turn tracking on or off. The page keeps the
## edits as a list; each run applies them in order to the document as it was
## loaded, writes the result and reads that back, so what the page shows is
## exactly what a download holds.
Review := [].{

	Edit : [Accept(U64), Reject(U64), AcceptAll, RejectAll, Resolve(U64), Reply({ to : U64, text : Str }), Tracking(Bool)]

	Request : { doc : Wire.Bytes, edits : List(Edit), author : Str, date : Str }

	Reviewed : { model : Explore.Model, base64 : Str, size : U64 }

	review : Worker.Program(Request, Try(Reviewed, Explore.Problem))
	review = Worker.fallible("roc-docx/playground/review", Review.reviewed)

	reviewed : Request -> Try(Reviewed, Explore.Problem)
	reviewed = |{ doc, edits, author, date }| {
		parsed = Docx.parse(doc.to_list()) ? |e| Unreadable(Str.inspect(e))
		edited = edits.fold_try(parsed.document, |d, edit| Review.apply(d, edit, author, date)) ? |e| Unreadable("An edit failed: ${Str.inspect(e)}")
		bytes = Docx.to_bytes(edited) ? |e| Unreadable("Writing failed: ${Str.inspect(e)}")
		again = Docx.parse(bytes) ? |e| Unreadable("The written document does not read: ${Str.inspect(e)}")
		model = Explore.of_document(bytes, again.document, again.diagnostics)?
		Ok({ model, base64: Base64.encode(bytes), size: bytes.len() })
	}

	apply : Document, Edit, Str, Str -> Try(Document, Docx.EditError)
	apply = |d, edit, author, date|
		match edit {
			Accept(id) => Docx.accept(d, Ids([id]))
			Reject(id) => Docx.reject(d, Ids([id]))
			AcceptAll => Docx.accept_all(d)
			RejectAll => Docx.reject_all(d)
			Resolve(id) => Docx.resolve(d, id)
			Reply({ to, text }) => Docx.reply(d, to, { author: author, content: Text(text), date: Date(date) }).map_ok(|r| r.document)
			Tracking(on) => Docx.set_tracking(d, if (on) On else Off)
		}

	## How the edit list reads to a person.
	describe : Edit -> Str
	describe = |edit|
		match edit {
			Accept(id) => "Accepted change ${id.to_str()}"
			Reject(id) => "Rejected change ${id.to_str()}"
			AcceptAll => "Accepted every change"
			RejectAll => "Rejected every change"
			Resolve(id) => "Resolved comment ${id.to_str()}"
			Reply({ to, .. }) => "Replied to comment ${to.to_str()}"
			Tracking(on) => if (on) "Turned tracking on" else "Turned tracking off"
		}
}

## Every edit describes itself.
expect Review.describe(Reply({ to: 3, text: "Agreed." })) == "Replied to comment 3"
