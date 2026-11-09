## A document as the package holds it, the typed model of its body, and what
## it means for two documents to be the same.
##
## A document is its package and the namespaced XML tree of each of its XML
## parts. Reading parses every XML part and drops the editor state the
## architecture's fidelity rules name, with a diagnostic; writing renders each
## tree in the canonical form of [XmlTree.render] and copies every other part
## exactly as its archive stored it. A document therefore holds the archive's
## bytes and the trees of its XML parts, and while it is read or written, one
## part's bytes beyond them.
##
## The body's model, [Document.Block] and what it holds, is read from the
## main document's tree by [Docx.body], its notes from the footnotes and
## endnotes parts by [Docx.footnotes] and [Docx.endnotes], and its comments
## from the comments part by [Docx.comments]. [Docx.to_bytes] writes the main
## document from that model and every other part from its tree, so the model
## is a reading of the trees rather than a copy kept beside them.
import Lenient
import Limits
import Mce
import Opc
import XmlTree

Document :: { pkg : Opc.Package, graph : Opc.Graph, trees : Dict(Str, XmlTree.Node), body : [Whole, Blocks({ part : Str, body : Body })] }.{

	## A block of the body, in reading order: a paragraph; a table; the end
	## of a section, with the section's properties, after the paragraph whose
	## mark ends it or at the end of the body; the start or end of a comment's
	## range between blocks, naming the comment as [Document.Inline] does; an
	## element the model does not represent whose content is still read as
	## blocks, kept without its children in `element` (a content control and
	## its content, custom XML); or any other element, kept whole as it was
	## read.
	Block := [
		Paragraph(Paragraph),
		Table(Table),
		Section(Section),
		CommentStart(U64),
		CommentEnd(U64),
		Container({ element : XmlTree.Node, content : List(Block) }),
		Preserved(XmlTree.Node),
	].{

		## Compare two blocks structurally.
		is_eq : _
	}

	## A paragraph: its properties and its content in order.
	Paragraph : { properties : ParagraphProperties, content : List(Inline) }

	## A paragraph's own properties, as the document states them directly on
	## the paragraph or in a style; what its styles and the document's
	## defaults contribute is [Styles.effective_paragraph]'s answer. Each
	## property is `Unset` where nothing is stated, so a property left to
	## the styles differs from one set to the value a style would give:
	##
	## * `style`, the paragraph style's identifier;
	## * `alignment`, how lines are aligned between the indents;
	## * `indentation` and `spacing`, in twentieths of a point;
	## * `keep_next`, `keep_lines`, `page_break_before` and `widow_control`;
	## * `outline_level`, from 0 for the top level, 9 being body text;
	## * `borders`, the edges stated, and `shading`;
	## * `tabs`, the tab stops set or cleared;
	## * `numbering`, the reference to a numbering instance and level that
	##   makes a paragraph a list item.
	##
	## A property element the model does not hold, or one whose attributes it
	## cannot represent (a theme colour on a border, spacing in lines), is kept
	## in `preserved` as it was read, in order, and so is a repeated element.
	ParagraphProperties : {
		style : [Unset, Style(Str)],
		alignment : [Unset, Aligned(Alignment)],
		indentation : Indentation,
		spacing : Spacing,
		keep_next : OnOff,
		keep_lines : OnOff,
		page_break_before : OnOff,
		widow_control : OnOff,
		outline_level : [Unset, Level(U8)],
		borders : List(Border),
		shading : Shading,
		tabs : [Unset, Tabs(List(TabStop))],
		numbering : Numbering,
		preserved : List(XmlTree.Node),
	}

	## A paragraph's properties when nothing is stated.
	no_paragraph_properties : ParagraphProperties
	no_paragraph_properties = {
		style: Unset,
		alignment: Unset,
		indentation: { left: Unset, right: Unset, first_line: Unset },
		spacing: { before: Unset, after: Unset, line: Unset },
		keep_next: Unset,
		keep_lines: Unset,
		page_break_before: Unset,
		widow_control: Unset,
		outline_level: Unset,
		borders: [],
		shading: Unset,
		tabs: Unset,
		numbering: { instance: Unset, level: Unset },
		preserved: [],
	}

	## A property that is on or off, or `Unset` where nothing is stated.
	OnOff : [Unset, On, Off]

	## Paragraph alignment, as the schema names it: `Left` and `Right` are the
	## transitional spellings of `Start` and `End`, kept apart so a document
	## writes back as it was read; `Both` is justified.
	Alignment : [Start, End, Left, Right, Center, Both, Distribute, MediumKashida, HighKashida, LowKashida, ThaiDistribute, NumTab]

	## Indents in twentieths of a point: from the left and right margins, and
	## the first line's indent from the left one, either further in or, for a
	## hanging indent, back out.
	Indentation : {
		left : [Unset, Twips(I32)],
		right : [Unset, Twips(I32)],
		first_line : [Unset, FirstLine(I32), Hanging(I32)],
	}

	## Space before and after a paragraph in twentieths of a point, and the
	## spacing of its lines: `Auto` in 240ths of a line, `Exact` and `AtLeast`
	## in twentieths of a point.
	Spacing : {
		before : [Unset, Twips(U32)],
		after : [Unset, Twips(U32)],
		line : [Unset, Auto(I32), Exact(I32), AtLeast(I32)],
	}

	## A tab stop at a position in twentieths of a point, or the clearing of
	## one a style set there.
	TabStop : { kind : [Clear, Start, End, Left, Right, Center, Decimal, Bar, Num], position : I32, leader : [Unset, NoLeader, Dot, Hyphen, Underscore, Heavy, MiddleDot] }

	## The numbering a paragraph belongs to: a numbering instance by its
	## identifier, 0 meaning none, and a level from 0.
	Numbering : { instance : [Unset, Instance(U32)], level : [Unset, Level(U8)] }

	## A paragraph's content, in order: a run; a hyperlink; a simple field; a
	## bookmark's start or end; the start or end of a comment's range; a
	## tracked change and the content it covers; the start or end of a move's
	## range; an element the model does not represent whose content is still
	## read as paragraph content, kept without its children in `element` (a
	## content control and its content, a smart tag, custom XML, a
	## bidirectional embedding, a hyperlink whose target cannot be resolved,
	## or a tracked change without the author the schema requires); or any
	## other element kept whole in its place.
	##
	## A tracked change, a [Document.Revision], is identified by its place
	## among the body's tracked changes in reading order, as
	## [Revisions.list] gives it, not by the identifier the document wrote.
	## A move's range marks where moved content left, its source, or where
	## it arrived, its destination; the source's and destination's ranges
	## share the move's name, which pairs them.
	##
	## A hyperlink holds its target, the attributes the model does not
	## represent (a tooltip, a target frame, whether it was visited) and its
	## content. A simple field holds its field code, the attributes the model
	## does not represent (whether it is locked or must be updated) and its
	## content, which is the field's result as last calculated. A bookmark's
	## start and end both name the bookmark by its name, which is unique in a
	## document. A comment's range covers the content between its start and
	## its end, which may be in different paragraphs or blocks; both name the
	## comment by its place among the comments of the document's comments
	## part, as [Docx.comments] gives each comment's `id`.
	Inline := [
		Run(Run),
		Hyperlink({ target : LinkTarget, preserved : List(XmlTree.Attribute), content : List(Inline) }),
		SimpleField({ code : Str, preserved : List(XmlTree.Attribute), content : List(Inline) }),
		BookmarkStart(Str),
		BookmarkEnd(Str),
		CommentStart(U64),
		CommentEnd(U64),
		Revision(Revision),
		MoveStart(MoveRange),
		MoveEnd({ side : MoveSide, name : Str }),
		Container({ element : XmlTree.Node, content : List(Inline) }),
		Preserved(XmlTree.Node),
	].{

		## Compare two inlines structurally.
		is_eq : _
	}

	## A tracked change to paragraph content: what kind of change it is; who
	## made it and when, as [Document.Timestamp] holds a date; and the
	## content it covers. An insertion's content was added and a deletion's
	## removed; a move's source is content moved away from here and its
	## destination the same content arriving elsewhere. Every attribute the
	## model does not hold, and a date that is not a date and time, is kept
	## in `preserved` as it was read.
	Revision : { kind : RevisionKind, author : Str, date : [Unset, Date(Timestamp)], content : List(Inline), preserved : List(XmlTree.Attribute) }

	## The kinds of tracked change to paragraph content.
	RevisionKind : [Insertion, Deletion, MoveSource, MoveDestination]

	## The start of a move's range: which side of the move it is, the move's
	## name, who moved the content and when, and every attribute the model
	## does not hold.
	MoveRange : { side : MoveSide, name : Str, author : Str, date : [Unset, Date(Timestamp)], preserved : List(XmlTree.Attribute) }

	## Where a move's range is: where the content was, or where it went.
	MoveSide : [Source, Destination]

	## A run: text with one set of character properties.
	Run : { properties : RunProperties, content : List(RunContent) }

	## A run's own character properties, as the document states them directly
	## on the run or in a style; what its styles and the document's defaults
	## contribute is [Styles.effective_run]'s answer. Each property is
	## `Unset` where nothing is stated:
	##
	## * `style`, the character style's identifier;
	## * `bold`, `italic`, `caps`, `small_caps`, `strike`, `double_strike` and
	##   `hidden`, which in a style toggle what the styles before it say;
	## * `underline`, `vertical_align` (superscript and subscript), `color`,
	##   `highlight`, `size` in half-points, `fonts` and `language`.
	##
	## A property element the model does not hold, or one whose attributes it
	## cannot represent (an underline with its own colour, a font hint), is
	## kept in `preserved` as it was read, in order, and so is a repeated
	## element.
	RunProperties : {
		style : [Unset, Style(Str)],
		bold : OnOff,
		italic : OnOff,
		caps : OnOff,
		small_caps : OnOff,
		strike : OnOff,
		double_strike : OnOff,
		hidden : OnOff,
		underline : [Unset, Underline(Underline)],
		vertical_align : [Unset, Baseline, Superscript, Subscript],
		color : [Unset, Color(TextColor)],
		highlight : [Unset, Highlight(Highlight)],
		size : [Unset, HalfPoints(U32)],
		fonts : Fonts,
		language : Language,
		preserved : List(XmlTree.Node),
	}

	## A run's properties when nothing is stated.
	no_run_properties : RunProperties
	no_run_properties = {
		style: Unset,
		bold: Unset,
		italic: Unset,
		caps: Unset,
		small_caps: Unset,
		strike: Unset,
		double_strike: Unset,
		hidden: Unset,
		underline: Unset,
		vertical_align: Unset,
		color: Unset,
		highlight: Unset,
		size: Unset,
		fonts: { ascii: Unset, high_ansi: Unset, east_asia: Unset, complex: Unset, ascii_theme: Unset, high_ansi_theme: Unset, east_asia_theme: Unset, complex_theme: Unset },
		language: { latin: Unset, east_asia: Unset, complex: Unset },
		preserved: [],
	}

	## An underline's line, as the schema names it; `NoUnderline` removes one
	## a style sets.
	Underline : [Single, Words, Double, Thick, Dotted, DottedHeavy, Dash, DashedHeavy, DashLong, DashLongHeavy, DotDash, DashDotHeavy, DotDotDash, DashDotDotHeavy, Wave, WavyHeavy, WavyDouble, NoUnderline]

	## A text colour: automatic or a hexadecimal RGB value as written, and
	## the theme colour it was chosen from, kept as written and not resolved
	## against the theme.
	TextColor : { value : [Auto, Rgb(Str)], theme : [Unset, Theme(Str)], tint : [Unset, Tint(Str)], shade : [Unset, Shade(Str)] }

	## A highlighting colour; `NoHighlight` removes one a style sets.
	Highlight : [Black, Blue, Cyan, Green, Magenta, Red, Yellow, White, DarkBlue, DarkCyan, DarkGreen, DarkMagenta, DarkRed, DarkYellow, DarkGray, LightGray, NoHighlight]

	## The fonts of a run's text by script: Latin text below U+0080 (`ascii`),
	## other Latin text (`high_ansi`), East Asian and complex-script text,
	## each by name and by theme font. A theme font is kept as written and
	## not resolved against the theme; where both are stated, the theme font
	## is the one that applies.
	Fonts : {
		ascii : [Unset, Named(Str)],
		high_ansi : [Unset, Named(Str)],
		east_asia : [Unset, Named(Str)],
		complex : [Unset, Named(Str)],
		ascii_theme : [Unset, Theme(ThemeFont)],
		high_ansi_theme : [Unset, Theme(ThemeFont)],
		east_asia_theme : [Unset, Theme(ThemeFont)],
		complex_theme : [Unset, Theme(ThemeFont)],
	}

	## A theme font: the theme's major (headings) or minor (body) font for a
	## script.
	ThemeFont : [MajorEastAsia, MajorBidi, MajorAscii, MajorHighAnsi, MinorEastAsia, MinorBidi, MinorAscii, MinorHighAnsi]

	## The languages of a run's text by script, as BCP 47 tags such as
	## `en-US`.
	Language : { latin : [Unset, Tag(Str)], east_asia : [Unset, Tag(Str)], complex : [Unset, Tag(Str)] }

	## What a run holds, in order: text; a tab; a line, page or column break,
	## a line break saying which floating objects the next line clears; a
	## symbol, a character `code` in a named `font`; a soft hyphen, shown only
	## where a line breaks; a hyphen at which a line never breaks; a reference
	## to a footnote or endnote; the mark that numbers a note, inside the note
	## itself; a reference to a comment, where the comment is shown, named by
	## its place as a comment's range names it; a complex field's mark or a
	## piece of its field code; an inline picture; or any other element, such
	## as a floating drawing or the mark a comment's content begins with, kept
	## whole in its place. Deleted text is text and a deleted piece of field
	## code is field code: in a deletion or a move's source they are what its
	## content holds.
	##
	## A note reference names its note by its place among the document's
	## footnotes or endnotes, as [Docx.footnotes] and [Docx.endnotes] list
	## them. A complex field is spread over runs, and over paragraphs, in the
	## order it was written: its beginning, its code, a separator, the runs of
	## its result as last calculated, and its end. Each mark keeps its
	## `element` as it was read, with what the model does not represent, such
	## as a lock or form field data; [Document.fields] gathers each field's
	## code and result. A picture is opaque: the `media` part holding its
	## image, which is never decoded, its `size` on the page in English Metric
	## Units (914,400 to the inch), and the `drawing` as it was read.
	RunContent : [
		Text(Str),
		Tab,
		Break({ kind : [Line, Page, Column], clear : [NoClear, Left, Right, All] }),
		Symbol({ font : Str, code : U16 }),
		SoftHyphen,
		NonBreakingHyphen,
		NoteReference({ kind : NoteKind, note : U64 }),
		NoteMark(NoteKind),
		CommentReference(U64),
		FieldMark({ kind : [Begin, Separate, End], element : XmlTree.Node }),
		FieldCode(Str),
		Picture({ media : Str, size : { width : U64, height : U64 }, drawing : XmlTree.Node }),
		Preserved(XmlTree.Node),
	]

	## A table: its properties, its grid of columns, and its content in
	## order.
	Table : { properties : TableProperties, grid : List(GridColumn), content : List(TableContent) }

	## A table's properties as the table states them, without what its style
	## contributes: the identifier of its table style in the document's
	## styles, its preferred width, its borders and its shading. Every other
	## property element is kept as it was read, in order, and so is a
	## property element whose attributes the model cannot hold.
	TableProperties : { style : [Unset, Style(Str)], width : Width, borders : List(Border), shading : Shading, preserved : List(XmlTree.Node) }

	## A column of a table's grid, its width in twips; any other element of
	## the grid, such as a column without a width or a revision of the grid,
	## is kept in its place as it was read.
	GridColumn : [Column(U64), Preserved(XmlTree.Node)]

	## A table's content, in order: a row; the start or end of a comment's
	## range between rows; an element the model does not represent whose
	## content is still read as rows, kept without its children in `element`
	## (a content control and its content, custom XML); or any other element,
	## such as a bookmark boundary, kept whole in its place.
	TableContent := [
		Row(Row),
		CommentStart(U64),
		CommentEnd(U64),
		Container({ element : XmlTree.Node, content : List(TableContent) }),
		Preserved(XmlTree.Node),
	].{

		## Compare two pieces of table content structurally.
		is_eq : _
	}

	## A row: its properties and its content in order.
	Row : { properties : RowProperties, content : List(RowContent) }

	## A row's properties: whether it is a header row, repeated at the top of
	## each page the table spans, and how many grid columns come before its
	## first cell and after its last. Every other property element is kept as
	## it was read, in order.
	RowProperties : { header : [Unset, On, Off], grid_before : [Unset, Columns(U64)], grid_after : [Unset, Columns(U64)], preserved : List(XmlTree.Node) }

	## A row's content, in order: a cell; the start or end of a comment's
	## range between cells; an element the model does not represent whose
	## content is still read as cells, kept without its children in `element`
	## (a content control and its content, custom XML); or any other element,
	## such as the table property exceptions of the row or a bookmark
	## boundary, kept whole in its place.
	RowContent := [
		Cell(Cell),
		CommentStart(U64),
		CommentEnd(U64),
		Container({ element : XmlTree.Node, content : List(RowContent) }),
		Preserved(XmlTree.Node),
	].{

		## Compare two pieces of row content structurally.
		is_eq : _
	}

	## A cell: its properties and its blocks, which may hold further tables.
	Cell : { properties : CellProperties, content : List(Block) }

	## A cell's properties: its preferred width, how many grid columns it
	## spans, whether it starts or continues a vertical merge with the cell
	## above, its borders, its shading and the vertical alignment of its
	## content. Every other property element is kept as it was read, in
	## order, and so is a property element whose attributes the model cannot
	## hold.
	CellProperties : {
		width : Width,
		span : [Unset, Columns(U64)],
		merge : [Unset, Restart, Continue],
		borders : List(Border),
		shading : Shading,
		alignment : [Unset, Top, Center, Bottom, Both],
		preserved : List(XmlTree.Node),
	}

	## A preferred width: automatic, zero, in twips, or a share of the
	## available width in fiftieths of a per cent.
	Width : [Unset, Auto, Nil, Twips(I64), Fiftieths(I64)]

	## One edge of a table's, cell's or paragraph's borders: the line, by its
	## name in the schema (`single`, `double`, `dotted`, `nil` and so on), its
	## width in eighths of a point, its distance from the content in points,
	## and its colour. `Left` and `Start`, `Right` and `End` are the two
	## spellings the schema has for the same edges; `Between` separates
	## paragraphs of one border group and `Bar` is drawn beside a paragraph.
	Border : {
		edge : [Top, Left, Start, Bottom, Right, End, InsideHorizontal, InsideVertical, DiagonalDown, DiagonalUp, Between, Bar],
		line : Str,
		size : [Unset, Eighths(U64)],
		space : [Unset, Points(U64)],
		color : Color,
	}

	## A shading: its pattern, by its name in the schema (`clear`, `solid`,
	## `pct25` and so on), the pattern's colour and the fill behind it.
	Shading : [Unset, Shading({ pattern : Str, color : Color, fill : Color })]

	## A colour: automatic, or red, green and blue as six hexadecimal digits
	## as the document writes them.
	Color : [Unset, Auto, Rgb(Str)]

	## Where a hyperlink leads: an address outside the document, an address
	## with a location in what it addresses, or a bookmark of the document by
	## its name.
	LinkTarget : [External(Str), ExternalAt({ url : Str, location : Str }), Internal(Str)]

	## Whether a note is a footnote or an endnote.
	NoteKind : [Footnote, Endnote]

	## A footnote or endnote: what kind of note it is, and its content. Most
	## notes are `Note`s; the others are the line separating notes from the
	## body, the longer one above notes continued from the previous page, and
	## the notice that notes continue on the next.
	Note : { kind : [Note, Separator, ContinuationSeparator, ContinuationNotice], content : List(Block) }

	## A comment: who wrote it, by name and by initials as the document gives
	## them; when, as [Document.Timestamp] holds a date; and its content,
	## paragraphs and tables read as a body's blocks are. A comment's `w:id`
	## is how the document's ranges and references name it, which the model
	## replaces by the comment's place; every other attribute, and a date
	## that is not a date and time, is kept in `preserved` as it was read.
	##
	## A comment is a node of a thread: `parent` is the comment it replies
	## to, by its place among the comments, and `resolved` whether the
	## comment is marked done. `durable_id` is the identifier that stays with
	## the comment across editing sessions, and `utc_date` when it was
	## written in UTC, where the document records them.
	Comment : {
		author : Str,
		initials : [Unset, Initials(Str)],
		date : [Unset, Date(Timestamp)],
		content : List(Block),
		preserved : List(XmlTree.Attribute),
		parent : [Unset, Parent(U64)],
		resolved : Bool,
		durable_id : [Unset, DurableId(U32)],
		utc_date : [Unset, Date(Timestamp)],
	}

	## Someone who wrote comments or tracked changes, as the people part
	## records them: the name the document's comments and changes give as
	## their author, and, where the document says, the identity provider
	## that knows them and their identifier there.
	Person : { author : Str, presence : [Unset, Presence({ provider : Str, user : Str })] }

	## A date and time as the document writes it, in the XML Schema
	## `dateTime` form such as `2026-05-04T09:15:00Z`, and the instant it
	## names in seconds since 1970-01-01T00:00:00Z, fractions of a second
	## left out. A time with an offset from UTC is converted; a time without
	## one is taken as UTC, as LibreOffice and pandoc take it.
	Timestamp : { written : Str, utc_seconds : I64 }

	## A field as written: its field code, every piece joined, and its result
	## as last calculated, as text. Fields are never evaluated.
	Field : { code : Str, result : Str }

	## A section's properties as the section states them: where it starts
	## (on the next page, continuing the page, on the next even or odd page,
	## or in the next column); its page's size in twips and orientation; its
	## margins in twips, from the page's edges to the body, from the top and
	## bottom edges to the header and footer, and the gutter kept for
	## binding, the top and bottom negative when the body may run into the
	## header or footer; its columns of text, of equal width with the space
	## between them or each with its own width and the space after it, with
	## or without a line between them; its page numbers' format, by its name
	## in the schema (`decimal`, `lowerRoman` and so on), and the number its
	## first page starts from; whether its first page has its own header and
	## footer; and its headers and footers. Every other property element is
	## kept as it was read, in order, and so is a property element whose
	## attributes the model cannot hold.
	Section : {
		start : [Unset, NextPage, Continuous, EvenPage, OddPage, NextColumn],
		page_size : [Unset, Size({ width : U64, height : U64, orientation : [Portrait, Landscape] })],
		margins : [Unset, Margins({ top : I64, right : U64, bottom : I64, left : U64, header : U64, footer : U64, gutter : U64 })],
		columns : [Unset, Equal({ count : U64, space : U64, separator : [NoLine, Line] }), Unequal({ widths : List({ width : U64, space : U64 }), separator : [NoLine, Line] })],
		page_numbers : [Unset, PageNumbers({ format : [Unset, Format(Str)], start : [Unset, Start(U64)] })],
		title_page : [Unset, On, Off],
		headers : List(HeaderFooter),
		footers : List(HeaderFooter),
		preserved : List(XmlTree.Node),
	}

	## A section's header or footer: which pages it is for, every page, the
	## section's first page or even pages, and the part holding its content,
	## which [Docx.header_footer] reads. A section without one of a kind has
	## the previous section's.
	HeaderFooter : { kind : [Default, First, Even], part : Str }

	## A document's core properties: its title, subject, author (`creator`),
	## keywords, description, who last modified it, its revision number and
	## when it was created and last modified, each date as the document
	## writes it in the W3C date and time format, such as
	## `2026-11-09T11:03:00Z`. A property the document does not give is
	## `Unset`. Every other property, such as its category or language, is
	## kept as it was read, in order, and so is one the model cannot hold.
	CoreProperties : {
		title : [Unset, Text(Str)],
		subject : [Unset, Text(Str)],
		creator : [Unset, Text(Str)],
		keywords : [Unset, Text(Str)],
		description : [Unset, Text(Str)],
		last_modified_by : [Unset, Text(Str)],
		revision : [Unset, Number(U64)],
		created : [Unset, Date(Str)],
		modified : [Unset, Date(Str)],
		preserved : List(XmlTree.Node),
	}

	## A document's extended properties, which the application that saved it
	## writes: the application and its version, the company and manager, the
	## template it was based on, and the statistics the application counted
	## when it saved it, with the total editing time in minutes. A property
	## the document does not give is `Unset`; every other property, such as
	## the titles of its parts, is kept as it was read, in order, and so is
	## one the model cannot hold.
	ExtendedProperties : {
		application : [Unset, Text(Str)],
		app_version : [Unset, Text(Str)],
		company : [Unset, Text(Str)],
		manager : [Unset, Text(Str)],
		template : [Unset, Text(Str)],
		pages : [Unset, Count(U64)],
		words : [Unset, Count(U64)],
		characters : [Unset, Count(U64)],
		characters_with_spaces : [Unset, Count(U64)],
		lines : [Unset, Count(U64)],
		paragraphs : [Unset, Count(U64)],
		total_time : [Unset, Count(U64)],
		preserved : List(XmlTree.Node),
	}

	## A custom property, which an application or person adds to a document:
	## its name and its value, which is text, a whole number, true or false,
	## or a date in the W3C date and time format. A property whose value is
	## of another type, or that links to content, is kept as it was read.
	CustomProperty : [Property({ name : Str, value : [Text(Str), Integer(I64), Boolean(Bool), Date(Str)] }), Preserved(XmlTree.Node)]

	## The target a `HYPERLINK` field code names, as Word and LibreOffice
	## write links in fields: its first argument is the address, and its `\l`
	## switch a location in it, or a bookmark of the document when there is
	## no address. Its other switches (`\o` a tooltip, `\t` a target frame,
	## `\m` and `\n`) are not targets. This reads the code; it does not
	## evaluate the field, whose result stays as last calculated.
	field_target : Str -> Try(LinkTarget, [NotAHyperlink])
	field_target = |code| {
		tokens = field_tokens(code)
		match tokens.first() {
			Ok({ text, quoted: Bool.False }) if is_hyperlink(text) => {}
			_ => return Err(NotAHyperlink)
		}
		var $address = Err(Missing)
		var $location = Err(Missing)
		var $pending = Err(Missing)
		for token in List.drop_first(tokens, 1) {
			if !token.quoted and token.text.starts_with("\\") {
				$pending = if (token.text == "\\l" or token.text == "\\o" or token.text == "\\t") Ok(token.text) else Err(Missing)
			} else {
				match $pending {
					Ok("\\l") => {
						$location = Ok(token.text)
					}

					Ok(_) => {}
					Err(_) => {
						$address = match $address {
							Ok(found) => Ok(found)
							Err(_) => Ok(token.text)
						}
					}
				}
				$pending = Err(Missing)
			}
		}
		match ($address, $location) {
			(Ok(url), Ok(location)) => Ok(ExternalAt({ url, location }))
			(Ok(url), Err(_)) => Ok(External(url))
			(Err(_), Ok(name)) => Ok(Internal(name))
			(Err(_), Err(_)) => Err(NotAHyperlink)
		}
	}

	## An inline's text, as [Document.paragraph_text] counts it.
	inline_text : Inline -> Str
	inline_text = |inline| Str.from_utf8(inline_text_bytes(List.with_capacity(16), inline)) ?? ""

	## The fields of blocks in the order they begin, through containers,
	## hyperlinks and other fields: each simple field, with its content's text
	## as its result, and each complex field, with the code between its
	## beginning and its separator and the text between its separator and its
	## end, where a paragraph's end is a line feed. A field nested in
	## another's result is part of that result too, and a complex field that
	## never ends ends with the blocks.
	fields : List(Block) -> List(Field)
	fields = |blocks| {
		var $state = { open: List.with_capacity(4), done: List.with_capacity(8), begun: 0.U64 }
		for block in blocks {
			$state = block_fields($state, block)
		}
		List.concat($state.done, $state.open)
			.sort_with(|a, b| if (a.order < b.order) Before else if (a.order > b.order) After else Same)
			.map(|field| { code: Str.from_utf8(field.code) ?? "", result: Str.from_utf8(field.result) ?? "" })
	}

	## The sections that end in blocks, in order, through containers.
	sections : List(Block) -> List(Section)
	sections = |blocks| blocks.fold(List.with_capacity(2), sections_of)

	## A paragraph's current text, its tracked changes as they stand: every
	## run's text, inserted and moved-in text included, deleted and moved-away
	## text not, and nothing from the content the model keeps without
	## reading, so field instructions and note references contribute none. A
	## tab is a tab character, a break of any kind a line feed, a symbol its
	## character, a soft hyphen U+00AD and a non-breaking hyphen U+2011.
	paragraph_text : Paragraph -> Str
	paragraph_text = |paragraph| {
		var $text = List.with_capacity(64)
		for inline in paragraph.content {
			$text = inline_text_bytes($text, inline)
		}
		Str.from_utf8($text) ?? ""
	}

	## A table's rows in order, through the content controls and custom XML
	## that hold them.
	table_rows : Table -> List(Row)
	table_rows = |table| table.content.fold(List.with_capacity(table.content.len()), rows_of)

	## A row's cells in order, through the content controls and custom XML
	## that hold them.
	row_cells : Row -> List(Cell)
	row_cells = |row| row.content.fold(List.with_capacity(row.content.len()), cells_of)

	## Whether a paragraph's mark is deleted or moved away under tracking, so
	## that in the current text the paragraph runs on into the next one.
	joins_next : Paragraph -> Bool
	joins_next = |paragraph|
		paragraph.properties.preserved.any(
			|property|
				match property {
					Element(element) if is_w_in(element.name, ["rPr"]) => element.children.any(is_removal)
					_ => Bool.False
				},
		)

	## The tree of the main document part, the target of the package's
	## `officeDocument` relationship, as reading left it: without the body's
	## content when [Document.from_package_with_body] read the body as
	## blocks.
	main_document : Document -> Try(XmlTree.Node, [NoMainDocument])
	main_document = |document| {
		relationship = document.graph.relationships.find_first(|rel| rel.kind == Opc.officedocument_relationship and rel.mode == Internal) ? |_| NoMainDocument
		part = Opc.part(document.pkg, relationship.target) ? |_| NoMainDocument
		Ok(document.trees.get(part.name) ? |_| NoMainDocument)
	}

	## The document with the XML part named `name` holding `tree` and the
	## relationships whose source it is, as a writer gives them; every other
	## part stays as it is, and a body read as blocks from that part is
	## replaced by the tree. A name that is not a part of the document changes
	## nothing.
	with_part : Document, Str, XmlTree.Node, List(Opc.Relationship) -> Document
	with_part = |document, name, tree, relationships| {
		if document.trees.get(name).is_err() {
			return document
		}
		parts = document.graph.parts.map(|part| if (part.name == name) { name: part.name, content_type: part.content_type, relationships: relationships } else part)
		body = match document.body {
			Blocks(read) if read.part == name => Whole
			other => other
		}
		{ pkg: document.pkg, graph: { relationships: document.graph.relationships, parts }, trees: document.trees.insert(name, tree), body }
	}

	## An XML part as reading left it: its name, its tree, and the
	## relationships whose source it is.
	XmlPart : { name : Str, tree : XmlTree.Node, relationships : List(Opc.Relationship) }

	## The XML part that the first internal relationship of type `kind` whose
	## source is the part named `source`, or the package itself when `source`
	## is `/`, targets. Parts are found by relationship type, never by name.
	related : Document, Str, Str -> Try(XmlPart, [NotFound])
	related = |document, source, kind| {
		relationships = if source == "/" {
			document.graph.relationships
		} else {
			(document.graph.parts.find_first(|candidate| candidate.name == source) ? |_| NotFound).relationships
		}
		relationship = relationships.find_first(|rel| rel.kind == kind and rel.mode == Internal) ? |_| NotFound
		Document.xml_part(document, relationship.target)
	}

	## The XML part named `name`, the target of a relationship as the package
	## resolved it.
	xml_part : Document, Str -> Try(XmlPart, [NotFound])
	xml_part = |document, name| {
		part = Opc.part(document.pkg, name) ? |_| NotFound
		tree = document.trees.get(part.name) ? |_| NotFound
		target = document.graph.parts.find_first(|candidate| candidate.name == part.name) ? |_| NotFound
		Ok({ name: part.name, tree, relationships: target.relationships })
	}

	## Something reading did to a document that writing it back shows: a part
	## lost `count` occurrences of editor state that carries no document
	## meaning; or an attribute the schema does not allow as the part wrote
	## it was repaired, as [Lenient.repair] repairs it: a number the schema
	## wants whole, written with a fraction, `Rounded` to the nearest whole
	## number, with `value` as the part wrote it, or a required attribute the
	## element left out `Defaulted` with `value`. `element` and `attribute` are
	## WordprocessingML local names, and a repair is reported where it is
	## made, in document order.
	Diagnostic : [
		Dropped({ part : Str, content : Dropped, count : U64 }),
		Rounded({ part : Str, element : Str, attribute : Str, value : Str }),
		Defaulted({ part : Str, element : Str, attribute : Str, value : Str }),
	]

	## The editor state that is dropped, each by a rule of the architecture:
	## revision save identifiers (`w:rsid` and every other WordprocessingML
	## attribute whose name begins with `rsid`), rendered page breaks
	## (`w:lastRenderedPageBreak`), proofing marks (`w:proofErr`), and the
	## bookmark named `_GoBack` with its end.
	Dropped : [RevisionSaveIds, RenderedPageBreaks, ProofingMarks, GoBackBookmark]

	## Why an opened package cannot be read as a document: a relationship part
	## that cannot be read, an XML part whose stored data is damaged, or one
	## that is not namespace-well-formed XML within the limits.
	ReadError : [
		MissingPart(Str),
		RelationshipsNotXml({ part : Str, problem : XmlTree.ReadError }),
		MissingAttribute(Opc.AttributeLocation),
		TruncatedArchive,
		CompressionNotSupported(U16),
		CrcMismatch({ path : Str, expected : U32, actual : U32 }),
		InvalidCompressedData(Str),
		PartSizeMismatch({ name : Str, declared : U64 }),
		XmlPartUnreadable({ part : Str, problem : XmlTree.ReadError }),
	]

	## Why a document cannot be written: the package writer's errors, or a
	## tree that cannot be written as XML.
	WriteError : [
		InvalidPartName(Str),
		DuplicatePart(Str),
		InvalidContentType(Str),
		InvalidRelationship({ source : Str, id : Str }),
		DuplicateRelationshipId({ source : Str, id : Str }),
		NothingPending,
		NotWritten(Str),
		MissingPart(Str),
		TruncatedArchive,
		PartSizeMismatch({ name : Str, declared : U64 }),
		XmlPartUnwritable({ part : Str, problem : XmlTree.WriteError }),
	]

	## Read an opened package as a document: its part graph, and every part
	## whose content type is XML (`application/xml`, `text/xml` or a type
	## ending in `+xml`) parsed within the XML bounds of `limits`, with the
	## dropped content removed and its attributes repaired. The diagnostics
	## list each part's dropped content by kind and then its repairs, parts
	## in graph order.
	from_package : Opc.Package, Limits -> Try({ document : Document, diagnostics : List(Diagnostic) }, ReadError)
	from_package = |pkg, limits| {
		graph = Opc.graph(pkg)?
		var $trees = Dict.with_capacity(graph.parts.len())
		var $diagnostics = List.with_capacity(4)
		for part in graph.parts {
			if is_xml(part.content_type) {
				read = read_part(pkg, part.name, limits)?
				$trees = $trees.insert(part.name, read.tree)
				$diagnostics = List.concat($diagnostics, read.diagnostics)
			}
		}
		Ok({ document: { pkg, graph, trees: $trees, body: Whole }, diagnostics: $diagnostics })
	}

	## A main document's body as the model: its blocks in reading order, and
	## what reading them noticed that the schema does not allow, in document
	## order, as [WmlRead.read_body] gives them.
	Body : { blocks : List(Block), diagnostics : List([Rounded({ element : Str, attribute : Str, value : Str }), Defaulted({ element : Str, attribute : Str })]) }

	## How [Document.from_package_with_body] has a main document's body read
	## one block at a time. Two passes read the part. The first gives `scan`
	## each element's start and end from the `scanned` state, without the
	## content reading drops, so a reader can learn what the whole part names
	## before it reads a block, such as its bookmarks; `start` makes the
	## second pass's state of what it learned. The second gives `block` each
	## child of the body in order, without its dropped content, as its
	## subtree is read; `finish` gives the body.
	BodyReader(p, s) : { scanned : p, scan : p, XmlTree.Event -> p, start : p -> s, block : s, XmlTree.Node -> s, finish : s -> Body }

	## Read an opened package as [Document.from_package] does, except the
	## main document's body, the content of the first `w:body` of a
	## `w:document` root, which `reader` reads one block at a time and the
	## document keeps as its model, so that no tree of the whole body is held:
	## the part's tree is the rest of the part, the shell the body is written
	## into. `reader` is asked for once every other part is read, with the
	## document so far and the main document's name and relationships. The
	## main document's diagnostics are those [Document.from_package] gives,
	## in the same place. A package without a main document that is XML is
	## read as [Document.from_package] reads it.
	from_package_with_body : Opc.Package, Limits, (Document, { name : Str, relationships : List(Opc.Relationship) } -> BodyReader(p, s)) -> Try({ document : Document, diagnostics : List(Diagnostic) }, ReadError)
	from_package_with_body = |pkg, limits, reader_for| {
		graph = Opc.graph(pkg)?
		main = match graph.relationships.find_first(|rel| rel.kind == Opc.officedocument_relationship and rel.mode == Internal) {
			Ok(relationship) =>
				match graph.parts.find_first(|part| part.name == relationship.target and is_xml(part.content_type)) {
					Ok(part) => part
					Err(_) => return Document.from_package(pkg, limits)
				}

			Err(_) => return Document.from_package(pkg, limits)
		}
		var $trees = Dict.with_capacity(graph.parts.len())
		var $before = List.with_capacity(4)
		var $after = List.with_capacity(4)
		var $passed = Bool.False
		for part in graph.parts {
			if part.name == main.name {
				$passed = Bool.True
			} else if is_xml(part.content_type) {
				read = read_part(pkg, part.name, limits)?
				$trees = $trees.insert(part.name, read.tree)
				if $passed {
					$after = List.concat($after, read.diagnostics)
				} else {
					$before = List.concat($before, read.diagnostics)
				}
			}
		}
		reader = reader_for({ pkg, graph, trees: $trees, body: Whole }, { name: main.name, relationships: main.relationships })
		read = read_body(Opc.part_bytes(pkg, main.name)?, limits, reader) ? |problem| XmlPartUnreadable({ part: main.name, problem })
		diagnostics = List.join([$before, dropped_diagnostics(main.name, read.dropped), $after])
		Ok({ document: { pkg, graph, trees: $trees.insert(main.name, read.shell), body: Blocks({ part: main.name, body: read.body }) }, diagnostics })
	}

	## The main document's body as [Document.from_package_with_body] read it,
	## or `Whole` when the main document's tree holds it.
	body : Document -> Try(Body, [Whole])
	body = |document|
		match document.body {
			Blocks(read) => Ok(read.body)
			Whole => Err(Whole)
		}

	## Write a document as a package, in the order and form of [Opc.writer]:
	## each XML part rendered by [XmlTree.render] with its extension
	## namespaces declared ignorable by [Mce.declare_extensions], every other
	## part copied with its stored bytes. The same document always gives the
	## same bytes, and either the whole package is written or an error names
	## the reason.
	to_bytes : Document -> Try(List(U8), WriteError)
	to_bytes = |document| {
		var $writer = Opc.writer(document.graph)?
		var $out = List.with_capacity(0)
		for name in Opc.pending($writer) {
			content = match document.trees.get(name) {
				Ok(tree) => Bytes(XmlTree.render(Mce.declare_extensions(tree)) ? |problem| XmlPartUnwritable({ part: name, problem }))
				Err(_) => Copied(document.pkg)
			}
			added = Opc.add($writer, content)?
			$out = List.concat($out, added.chunk)
			$writer = added.writer
		}
		Ok(List.concat($out, Opc.finish($writer)?))
	}

	## Two documents are equivalent when they have the same package
	## relationships and the same parts by name, each with the same content
	## type and relationships, every XML part's tree equivalent by
	## [Document.equivalent_xml], every other part's content byte for byte
	## the same, and the same body where it was read as blocks. This is the equivalence a document keeps when it is written
	## and read again.
	equivalent : Document, Document -> Bool
	equivalent = |one, other| {
		if one.graph.relationships != other.graph.relationships or one.graph.parts.len() != other.graph.parts.len() or one.body != other.body {
			return Bool.False
		}
		var $counterparts = Dict.with_capacity(other.graph.parts.len())
		for part in other.graph.parts {
			$counterparts = $counterparts.insert(part.name, part)
		}
		for part in one.graph.parts {
			same = match $counterparts.get(part.name) {
				Ok(counterpart) =>
					counterpart == part and match (one.trees.get(part.name), other.trees.get(part.name)) {
						(Ok(tree), Ok(other_tree)) => Document.equivalent_xml(tree, other_tree)
						(Err(_), Err(_)) => same_content(one.pkg, other.pkg, part.name)
						_ => Bool.False
					}

				Err(_) => Bool.False
			}
			if !same {
				return Bool.False
			}
		}
		Bool.True
	}

	## Two trees of a part are equivalent when they are equal after these
	## normalizations, which are the architecture's round-trip equivalence:
	##
	## * Names compare by namespace and local name; prefixes and declarations
	##   are ignored, and so are the prefixes in attribute values that name
	##   namespaces, as [XmlTree.unprefixed] resolves them.
	## * Attribute order is ignored.
	## * Text that is only whitespace, beside an element among an element's
	##   children, is ignored unless `xml:space="preserve"` applies there; all
	##   other text compares exactly, adjacent runs of text joined.
	## * The dropped content of [Document.Dropped] is removed from both, and
	##   the attributes [Lenient.repair] repairs are compared repaired, so a
	##   width written as `10470.0` equals one written as `10470`.
	## * An extension namespace used without being declared ignorable compares
	##   as declared, as [Mce.declare_extensions] declares it when writing.
	equivalent_xml : XmlTree.Node, XmlTree.Node -> Bool
	equivalent_xml = |one, other| normalized(one) == normalized(other)
}

# The content a part holds, read from each package: the same when both
# inflate to the same bytes, or, when either cannot be inflated, when both
# are stored identically.
same_content : Opc.Package, Opc.Package, Str -> Bool
same_content = |one, other, name|
	match (Opc.part_bytes(one, name), Opc.part_bytes(other, name)) {
		(Ok(bytes), Ok(other_bytes)) => bytes == other_bytes
		_ => Opc.stored(one, name) == Opc.stored(other, name)
	}

# An inline's text, as [Document.paragraph_text] defines it, appended as UTF-8.
inline_text_bytes : List(U8), Document.Inline -> List(U8)
inline_text_bytes = |text, inline|
	match inline {
		Run(run) => run.content.fold(text, run_content_text)
		Container({ element: _, content }) => content.fold(text, inline_text_bytes)
		Hyperlink({ target: _, preserved: _, content }) => content.fold(text, inline_text_bytes)
		SimpleField({ code: _, preserved: _, content }) => content.fold(text, inline_text_bytes)
		Revision({ kind: Deletion, author: _, date: _, content: _, preserved: _ }) => text
		Revision({ kind: MoveSource, author: _, date: _, content: _, preserved: _ }) => text
		Revision({ kind: _, author: _, date: _, content, preserved: _ }) => content.fold(text, inline_text_bytes)
		BookmarkStart(_) => text
		BookmarkEnd(_) => text
		CommentStart(_) => text
		CommentEnd(_) => text
		MoveStart(_) => text
		MoveEnd(_) => text
		Preserved(_) => text
	}

sections_of : List(Document.Section), Document.Block -> List(Document.Section)
sections_of = |sections, block|
	match block {
		Section(section) => List.append(sections, section)
		Container({ element: _, content }) => content.fold(sections, sections_of)
		_ => sections
	}

rows_of : List(Document.Row), Document.TableContent -> List(Document.Row)
rows_of = |rows, content|
	match content {
		Row(row) => List.append(rows, row)
		Container({ element: _, content: inner }) => inner.fold(rows, rows_of)
		CommentStart(_) => rows
		CommentEnd(_) => rows
		Preserved(_) => rows
	}

cells_of : List(Document.Cell), Document.RowContent -> List(Document.Cell)
cells_of = |cells, content|
	match content {
		Cell(cell) => List.append(cells, cell)
		Container({ element: _, content: inner }) => inner.fold(cells, cells_of)
		CommentStart(_) => cells
		CommentEnd(_) => cells
		Preserved(_) => cells
	}

# Whether an element marks content deleted or moved away under tracking.
is_removal : XmlTree.Node -> Bool
is_removal = |node|
	match node {
		Element(element) => is_w_in(element.name, ["del", "moveFrom"])
		Text(_) => Bool.False
	}

is_w_in : XmlTree.Name, List(Str) -> Bool
is_w_in = |name, locals| name.namespace == Uri(wordprocessingml) and locals.contains(name.local)

# A field code's words and quoted arguments, in order.
field_tokens : Str -> List({ text : Str, quoted : Bool })
field_tokens = |code| {
	var $tokens = List.with_capacity(8)
	var $current = List.with_capacity(32)
	var $state = Between
	for byte in code.to_utf8() {
		match $state {
			Between => {
				if byte == '"' {
					$state = InQuotes
				} else if byte != ' ' and byte != 9 and byte != 10 and byte != 13 {
					$current = List.append($current, byte)
					$state = InWord
				}
			}

			InWord => {
				if byte == ' ' or byte == 9 or byte == 10 or byte == 13 {
					$tokens = List.append($tokens, { text: Str.from_utf8($current) ?? "", quoted: Bool.False })
					$current = List.with_capacity(32)
					$state = Between
				} else {
					$current = List.append($current, byte)
				}
			}

			InQuotes => {
				if byte == '"' {
					$tokens = List.append($tokens, { text: Str.from_utf8($current) ?? "", quoted: Bool.True })
					$current = List.with_capacity(32)
					$state = Between
				} else {
					$current = List.append($current, byte)
				}
			}
		}
	}
	match $state {
		Between => $tokens
		InWord => List.append($tokens, { text: Str.from_utf8($current) ?? "", quoted: Bool.False })
		InQuotes => List.append($tokens, { text: Str.from_utf8($current) ?? "", quoted: Bool.True })
	}
}

# Whether a word is `HYPERLINK`, in any case.
is_hyperlink : Str -> Bool
is_hyperlink = |word| word.to_utf8().map(|byte| if (byte >= 'a' and byte <= 'z') byte - 32 else byte) == "HYPERLINK".to_utf8()

# The fields begun so far, as [Document.fields] gathers them: those still
# open, innermost last, those ended, and how many have begun.
FieldState : { open : List(OpenField), done : List(OpenField), begun : U64 }

OpenField : { order : U64, code : List(U8), result : List(U8), in_result : Bool }

block_fields : FieldState, Document.Block -> FieldState
block_fields = |state, block|
	match block {
		Paragraph(paragraph) => to_results(paragraph.content.fold(state, inline_fields), [10])
		Table(table) => Document.table_rows(table).fold(state, |by_row, row| Document.row_cells(row).fold(by_row, |by_cell, cell| cell.content.fold(by_cell, block_fields)))
		Container({ element: _, content }) => content.fold(state, block_fields)
		Section(_) => state
		CommentStart(_) => state
		CommentEnd(_) => state
		Preserved(_) => state
	}

inline_fields : FieldState, Document.Inline -> FieldState
inline_fields = |state, inline|
	match inline {
		Run(run) => run.content.fold(state, run_content_fields)
		Hyperlink({ target: _, preserved: _, content }) => content.fold(state, inline_fields)
		SimpleField({ code, preserved: _, content }) => {
			inner = content.fold({ open: state.open, done: state.done, begun: state.begun + 1 }, inline_fields)
			field = { order: state.begun, code: code.to_utf8(), result: inline_text_bytes([], inline), in_result: Bool.True }
			{ open: inner.open, done: List.append(inner.done, field), begun: inner.begun }
		}

		Container({ element: _, content }) => content.fold(state, inline_fields)
		Revision({ kind: _, author: _, date: _, content, preserved: _ }) => content.fold(state, inline_fields)
		BookmarkStart(_) => state
		BookmarkEnd(_) => state
		CommentStart(_) => state
		CommentEnd(_) => state
		MoveStart(_) => state
		MoveEnd(_) => state
		Preserved(_) => state
	}

run_content_fields : FieldState, Document.RunContent -> FieldState
run_content_fields = |state, content|
	match content {
		FieldMark({ kind: Begin, element: _ }) => {
			field = { order: state.begun, code: [], result: [], in_result: Bool.False }
			{ open: List.append(state.open, field), done: state.done, begun: state.begun + 1 }
		}

		FieldMark({ kind: Separate, element: _ }) =>
			match state.open.last() {
				Ok(field) => { open: List.append(List.drop_last(state.open, 1), { order: field.order, code: field.code, result: field.result, in_result: Bool.True }), done: state.done, begun: state.begun }
				Err(_) => state
			}

		FieldMark({ kind: End, element: _ }) =>
			match state.open.last() {
				Ok(field) => { open: List.drop_last(state.open, 1), done: List.append(state.done, field), begun: state.begun }
				Err(_) => state
			}

		FieldCode(code) =>
			match state.open.last() {
				Ok(field) => { open: List.append(List.drop_last(state.open, 1), { order: field.order, code: List.concat(field.code, code.to_utf8()), result: field.result, in_result: field.in_result }), done: state.done, begun: state.begun }
				Err(_) => state
			}

		_ => to_results(state, run_content_text([], content))
	}

# Text added to the result of every open field that has reached its result.
to_results : FieldState, List(U8) -> FieldState
to_results = |state, text|
	if text.is_empty() or state.open.is_empty() {
		state
	} else {
		open = state.open.map(|field| if (field.in_result) { order: field.order, code: field.code, result: List.concat(field.result, text), in_result: Bool.True } else field)
		{ open, done: state.done, begun: state.begun }
	}

run_content_text : List(U8), Document.RunContent -> List(U8)
run_content_text = |text, content|
	match content {
		Text(value) => List.concat(text, value.to_utf8())
		Tab => List.append(text, 9)
		Break(_) => List.append(text, 10)
		Symbol({ font: _, code }) => List.concat(text, utf8(code))
		SoftHyphen => List.concat(text, [0xC2, 0xAD])
		NonBreakingHyphen => List.concat(text, [0xE2, 0x80, 0x91])
		NoteReference(_) => text
		NoteMark(_) => text
		CommentReference(_) => text
		FieldMark(_) => text
		FieldCode(_) => text
		Picture(_) => text
		Preserved(_) => text
	}

# A character code as UTF-8; a surrogate, which is no character, is U+FFFD.
utf8 : U16 -> List(U8)
utf8 = |code|
	if code < 0x80 {
		[code.to_u8_wrap()]
	} else if code < 0x800 {
		[(0xC0 + code // 64).to_u8_wrap(), (0x80 + code % 64).to_u8_wrap()]
	} else if code >= 0xD800 and code < 0xE000 {
		[0xEF, 0xBF, 0xBD]
	} else {
		[(0xE0 + code // 4096).to_u8_wrap(), (0x80 + (code // 64) % 64).to_u8_wrap(), (0x80 + code % 64).to_u8_wrap()]
	}

is_xml : Str -> Bool
is_xml = |content_type| content_type.ends_with("+xml") or content_type == "application/xml" or content_type == "text/xml"

wordprocessingml : Str
wordprocessingml = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

xml_namespace : Str
xml_namespace = "http://www.w3.org/XML/1998/namespace"

Element : { name : XmlTree.Name, bindings : List(XmlTree.Binding), attributes : List(XmlTree.Attribute), children : List(XmlTree.Node) }

# A walk over a tree with an explicit work list, so a deep tree cannot
# exhaust the call stack: an element is visited, then its children, then left.
Step : [Visit(XmlTree.Node), Leave]

# A tree without its dropped content and with its attributes repaired, with
# how much of each kind it lost, in the order of `Dropped`, and the repairs in
# document order. The root is always kept.
drop : XmlTree.Node -> { tree : XmlTree.Node, dropped : List({ content : Document.Dropped, count : U64 }), repairs : List(Lenient.Repair) }
drop = |root| {
	kept = dropping(root, go_back_ids(root), Bool.True)
	{ tree: kept.nodes.last() ?? root, dropped: counted(kept.counts), repairs: kept.repairs }
}

# How much of each kind of dropped content a tree lost.
Counts : { save_ids : U64, page_breaks : U64, proofing : U64, bookmarks : U64 }

no_counts : Counts
no_counts = { save_ids: 0, page_breaks: 0, proofing: 0, bookmarks: 0 }

add_counts : Counts, Counts -> Counts
add_counts = |one, other| { save_ids: one.save_ids + other.save_ids, page_breaks: one.page_breaks + other.page_breaks, proofing: one.proofing + other.proofing, bookmarks: one.bookmarks + other.bookmarks }

# The kinds a tree lost content of, in the order of `Dropped`.
counted : Counts -> List({ content : Document.Dropped, count : U64 })
counted = |counts| {
	all = [
		{ content: RevisionSaveIds, count: counts.save_ids },
		{ content: RenderedPageBreaks, count: counts.page_breaks },
		{ content: ProofingMarks, count: counts.proofing },
		{ content: GoBackBookmark, count: counts.bookmarks },
	]
	all.keep_if(|entry| entry.count > 0)
}

# A tree without its dropped content, `go_back` naming the `_GoBack`
# bookmarks whose ends go with them: the tree, or nothing when its root is
# dropped, which only a root that is not `kept` can be.
dropping : XmlTree.Node, List(Str), Bool -> { nodes : List(XmlTree.Node), counts : Counts, repairs : List(Lenient.Repair) }
dropping = |root, go_back, kept| {
	var $counts = no_counts
	var $repairs = List.with_capacity(0)
	var $pending = [Visit(root)]
	var $frames = List.with_capacity(16)
	var $nodes = List.with_capacity(16)
	while !$pending.is_empty() {
		next = $pending.last() ?? Leave
		$pending = List.drop_last($pending, 1)
		match next {
			Visit(Text(content)) => {
				text : XmlTree.Node
				text = Text(content)
				$nodes = List.append($nodes, text)
			}

			Visit(Element(element)) => {
				kind = if ($frames.is_empty() and kept) Kept else dropped_kind(element, go_back)
				match kind {
					Kept => {
						kept_attributes = element.attributes.drop_if(is_save_id)
						$counts = { ..$counts, save_ids: $counts.save_ids + element.attributes.len() - kept_attributes.len() }
						repaired_attributes = Lenient.repair(element.name, kept_attributes)
						if !repaired_attributes.repairs.is_empty() {
							$repairs = List.concat($repairs, repaired_attributes.repairs)
						}
						$frames = List.append($frames, { name: element.name, bindings: element.bindings, attributes: repaired_attributes.attributes, first_child: $nodes.len() })
						$pending = push_children(List.append($pending, Leave), element.children)
					}

					RenderedPageBreak => {
						$counts = { ..$counts, page_breaks: $counts.page_breaks + 1 }
					}

					ProofingMark => {
						$counts = { ..$counts, proofing: $counts.proofing + 1 }
					}

					GoBackStart => {
						$counts = { ..$counts, bookmarks: $counts.bookmarks + 1 }
					}

					GoBackEnd => {}
				}
			}

			Leave =>
				match $frames.last() {
					Ok(frame) => {
						$frames = List.drop_last($frames, 1)
						node : XmlTree.Node
						node = Element({ name: frame.name, bindings: frame.bindings, attributes: frame.attributes, children: copy_from($nodes, frame.first_child) })
						$nodes = List.append(truncate($nodes, frame.first_child), node)
					}

					Err(_) => {}
				}
		}
	}
	{ nodes: $nodes, counts: $counts, repairs: $repairs }
}

# A part read as a tree without its dropped content, with what reading it
# dropped and repaired as diagnostics.
read_part : Opc.Package, Str, Limits -> Try({ tree : XmlTree.Node, diagnostics : List(Document.Diagnostic) }, Document.ReadError)
read_part = |pkg, name, limits| {
	bytes = Opc.part_bytes(pkg, name)?
	tree = XmlTree.parse(bytes, limits) ? |problem| XmlPartUnreadable({ part: name, problem })
	kept = drop(tree)
	Ok({ tree: kept.tree, diagnostics: dropped_diagnostics(name, { dropped: kept.dropped, repairs: kept.repairs }) })
}

# What a part lost, by kind, then its repairs, as diagnostics of the part.
dropped_diagnostics : Str, { dropped : List({ content : Document.Dropped, count : U64 }), repairs : List(Lenient.Repair) } -> List(Document.Diagnostic)
dropped_diagnostics = |part, kept| List.concat(kept.dropped.map(|entry| Dropped({ part, content: entry.content, count: entry.count })), kept.repairs.map(|repair| repaired(part, repair)))

# What the first pass over a main document carries: the reader's state, the
# `_GoBack` bookmarks' identifiers, the depth of the element being read and
# that of the dropped element whose content is being passed over, if any.
Scanning(p) : { inner : p, go_back : List(Str), depth : U64, skip : U64 }

# A main document read as `reader` reads its body: the part's tree without
# the body's content, the body, and what the part lost, by kind, and its
# repairs in document order, as [drop] gives them for the whole part.
read_body : List(U8), Limits, Document.BodyReader(p, s) -> Try({ shell : XmlTree.Node, body : Document.Body, dropped : { dropped : List({ content : Document.Dropped, count : U64 }), repairs : List(Lenient.Repair) } }, XmlTree.ReadError)
read_body = |bytes, limits, reader| {
	first : Scanning(_)
	first = { inner: reader.scanned, go_back: List.with_capacity(1), depth: 0, skip: 0 }
	scanned = XmlTree.scan(bytes, limits, first, |state, event| scan_kept(state, event, reader.scan))?
	go_back = scanned.go_back
	split = XmlTree.parse_split(
		bytes,
		limits,
		is_body,
		{ inner: (reader.start)(scanned.inner), counts: no_counts, repairs: List.with_capacity(0) },
		|state, node| {
			kept = dropping(node, go_back, Bool.False)
			{ inner: kept.nodes.fold(state.inner, reader.block), counts: add_counts(state.counts, kept.counts), repairs: List.concat(state.repairs, kept.repairs) }
		},
	)?
	shell = dropping(split.tree, go_back, Bool.True)
	after = after_body(split.tree).fold(List.with_capacity(0), |found, child| List.concat(found, dropping(child, go_back, Bool.False).repairs))
	before = shell.repairs.take_first(shell.repairs.len() - after.len())
	repairs = List.join([before, split.state.repairs, after])
	Ok({ shell: shell.nodes.last() ?? split.tree, body: (reader.finish)(split.state.inner), dropped: { dropped: counted(add_counts(shell.counts, split.state.counts)), repairs } })
}

# The first pass over a main document: each element's start and end goes to
# the reader's `scan` unless reading drops the element or it is inside one
# that is dropped, and every `_GoBack` bookmark's identifier is noted, as
# [go_back_ids] notes them. The end of a `_GoBack` bookmark is dropped only
# once its start is known, so it is passed on.
scan_kept : Scanning(p), XmlTree.Event, (p, XmlTree.Event -> p) -> Scanning(p)
scan_kept = |state, event, scan|
	match event {
		Start(start) => {
			depth = state.depth + 1
			go_back_start = start.name.local == "bookmarkStart" and start.name.namespace == Uri(wordprocessingml) and value_in(start.attributes, "name") == Ok("_GoBack")
			go_back = if (go_back_start) List.append(state.go_back, value_in(start.attributes, "id") ?? "") else state.go_back
			if state.skip > 0 {
				{ ..state, depth, go_back }
			} else if depth > 1 and (go_back_start or is_dropped_mark(start.name)) {
				{ ..state, depth, go_back, skip: depth }
			} else {
				{ ..state, depth, go_back, inner: scan(state.inner, event) }
			}
		}

		End =>
			if state.skip == state.depth {
				{ ..state, depth: state.depth - 1, skip: 0 }
			} else if state.skip > 0 {
				{ ..state, depth: state.depth - 1 }
			} else {
				{ ..state, depth: state.depth - 1, inner: scan(state.inner, event) }
			}
	}

# Whether a name is a rendered page break's or a proofing mark's, which
# reading drops wherever they are.
is_dropped_mark : XmlTree.Name -> Bool
is_dropped_mark = |name| (name.local == "lastRenderedPageBreak" or name.local == "proofErr") and name.namespace == Uri(wordprocessingml)

# Whether a root's child is the body [WmlRead.read_body] reads: a `w:body`
# of a `w:document`.
is_body : XmlTree.Name, XmlTree.Name -> Bool
is_body = |root, child| root.local == "document" and child.local == "body" and root.namespace == Uri(wordprocessingml) and child.namespace == Uri(wordprocessingml)

# The root's children after the body, in a main document's tree without the
# body's content.
after_body : XmlTree.Node -> List(XmlTree.Node)
after_body = |tree|
	match tree {
		Element(root) => {
			index = root.children.find_first_index(
				|child|
					match child {
						Element(element) => is_body(root.name, element.name)
						Text(_) => Bool.False
					},
			)
			match index {
				Ok(at) => root.children.drop_first(at + 1)
				Err(_) => []
			}
		}

		Text(_) => []
	}

# A repair as a diagnostic of the part it was made in.
repaired : Str, Lenient.Repair -> Document.Diagnostic
repaired = |part, repair|
	match repair {
		Rounded({ element, attribute, value }) => Rounded({ part, element, attribute, value })
		Defaulted({ element, attribute, value }) => Defaulted({ part, element, attribute, value })
	}

# Whether an element below the root is dropped, and by which rule.
dropped_kind : Element, List(Str) -> [Kept, RenderedPageBreak, ProofingMark, GoBackStart, GoBackEnd]
dropped_kind = |element, go_back|
	if element.name.namespace != Uri(wordprocessingml) {
		Kept
	} else if element.name.local == "lastRenderedPageBreak" {
		RenderedPageBreak
	} else if element.name.local == "proofErr" {
		ProofingMark
	} else if element.name.local == "bookmarkStart" and value_of(element, "name") == Ok("_GoBack") {
		GoBackStart
	} else if element.name.local == "bookmarkEnd" and go_back.contains(value_of(element, "id") ?? "") {
		GoBackEnd
	} else {
		Kept
	}

# The identifiers of the `_GoBack` bookmarks, whose ends are dropped with them.
go_back_ids : XmlTree.Node -> List(Str)
go_back_ids = |root| {
	var $ids = List.with_capacity(1)
	var $pending = [root]
	while !$pending.is_empty() {
		match $pending.last() {
			Ok(Element(element)) => {
				$pending = List.concat(List.drop_last($pending, 1), element.children)
				if element.name.namespace == Uri(wordprocessingml) and element.name.local == "bookmarkStart" and value_of(element, "name") == Ok("_GoBack") {
					$ids = List.append($ids, value_of(element, "id") ?? "")
				}
			}

			_ => {
				$pending = List.drop_last($pending, 1)
			}
		}
	}
	$ids
}

# The value of a WordprocessingML attribute of an element.
value_of : Element, Str -> Try(Str, [NotFound])
value_of = |element, local| value_in(element.attributes, local)

value_in : List(XmlTree.Attribute), Str -> Try(Str, [NotFound])
value_in = |attributes, local|
	attributes.find_first(|attribute| attribute.name.namespace == Uri(wordprocessingml) and attribute.name.local == local).map_ok(|attribute| attribute.value)

is_save_id : XmlTree.Attribute -> Bool
is_save_id = |attribute| attribute.name.namespace == Uri(wordprocessingml) and attribute.name.local.starts_with("rsid")

# The form two trees are compared in: dropped content removed, undeclared
# extensions declared, prefixes resolved, attributes sorted by namespace and
# local name, adjacent text joined and whitespace between elements removed
# where it is insignificant.
normalized : XmlTree.Node -> XmlTree.Node
normalized = |tree| {
	root = XmlTree.unprefixed(Mce.declare_extensions(drop(tree).tree))
	var $pending = [Visit(root)]
	var $frames = List.with_capacity(16)
	var $nodes = List.with_capacity(16)
	while !$pending.is_empty() {
		next = $pending.last() ?? Leave
		$pending = List.drop_last($pending, 1)
		match next {
			Visit(Text(content)) => {
				text : XmlTree.Node
				text = Text(content)
				$nodes = List.append($nodes, text)
			}

			Visit(Element(element)) => {
				inherited = match $frames.last() {
					Ok(frame) => frame.preserve
					Err(_) => Bool.False
				}
				preserve = match element.attributes.find_first(|attribute| attribute.name.namespace == Uri(xml_namespace) and attribute.name.local == "space") {
					Ok(attribute) => attribute.value == "preserve"
					Err(_) => inherited
				}
				attributes = element.attributes.sort_with(|a, b| by_name(a.name, b.name))
				$frames = List.append($frames, { name: element.name, attributes, preserve, first_child: $nodes.len() })
				$pending = push_children(List.append($pending, Leave), element.children)
			}

			Leave =>
				match $frames.last() {
					Ok(frame) => {
						$frames = List.drop_last($frames, 1)
						node : XmlTree.Node
						node = Element({ name: frame.name, bindings: [], attributes: frame.attributes, children: tidy(copy_from($nodes, frame.first_child), frame.preserve) })
						$nodes = List.append(truncate($nodes, frame.first_child), node)
					}

					Err(_) => {}
				}
		}
	}
	$nodes.last() ?? root
}

# An element's children with adjacent text joined and, among element
# children, whitespace-only text removed unless whitespace is preserved.
tidy : List(XmlTree.Node), Bool -> List(XmlTree.Node)
tidy = |children, preserve| {
	var $joined = List.with_capacity(children.len())
	var $has_element = Bool.False
	for child in children {
		match (child, $joined.last()) {
			(Text(content), Ok(Text(previous))) => {
				joined : XmlTree.Node
				joined = Text(Str.concat(previous, content))
				$joined = List.append(List.drop_last($joined, 1), joined)
			}

			(Element(_), _) => {
				$has_element = Bool.True
				$joined = List.append($joined, child)
			}

			_ => {
				$joined = List.append($joined, child)
			}
		}
	}
	if $has_element and !preserve {
		$joined.drop_if(
			|child|
				match child {
					Text(content) => is_whitespace(content)
					Element(_) => Bool.False
				},
		)
	} else {
		$joined
	}
}

is_whitespace : Str -> Bool
is_whitespace = |text| text.to_utf8().all(|byte| byte == 32 or byte == 9 or byte == 10 or byte == 13)

# Names ordered by namespace, no namespace first, then by local name, byte by
# byte.
by_name : XmlTree.Name, XmlTree.Name -> [Before, Same, After]
by_name = |one, other| {
	namespace = |name|
		match name.namespace {
			Uri(uri) => uri
			NoNamespace => ""
		}
	match by_bytes(namespace(one), namespace(other)) {
		Same => by_bytes(one.local, other.local)
		order => order
	}
}

by_bytes : Str, Str -> [Before, Same, After]
by_bytes = |one, other| {
	left = one.to_utf8()
	right = other.to_utf8()
	var $index = 0.U64
	while $index < left.len() and $index < right.len() {
		a = left.get($index) ?? 0
		b = right.get($index) ?? 0
		if a < b {
			return Before
		}
		if a > b {
			return After
		}
		$index = $index + 1
	}
	if left.len() < right.len() {
		Before
	} else if left.len() > right.len() {
		After
	} else {
		Same
	}
}

# Children are pushed last first, so the first is visited next.
push_children : List(Step), List(XmlTree.Node) -> List(Step)
push_children = |pending, children| {
	var $out = pending
	var $index = children.len()
	while $index > 0 {
		$index = $index - 1
		match children.get($index) {
			Ok(child) => {
				$out = List.append($out, Visit(child))
			}

			Err(_) => {}
		}
	}
	$out
}

# An element's children are the nodes after the place its start left, copied
# into a list of their own when it ends, so every node is copied once.
copy_from : List(a), U64 -> List(a)
copy_from = |nodes, start| {
	var $out = List.with_capacity(nodes.len() - start)
	var $index = start
	while $index < nodes.len() {
		match nodes.get($index) {
			Ok(node) => {
				$out = List.append($out, node)
			}

			Err(_) => {}
		}
		$index = $index + 1
	}
	$out
}

truncate : List(a), U64 -> List(a)
truncate = |nodes, len| {
	var $out = nodes
	while $out.len() > len {
		$out = List.drop_last($out, 1)
	}
	$out
}

w_declaration : Str
w_declaration = "xmlns:w='${wordprocessingml}'"

parse : Str -> XmlTree.Node
parse = |text| XmlTree.parse(text.to_utf8(), {}) ?? Text("unreadable")

## Dropped content is removed below the root, counted by kind, and a `_GoBack`
## bookmark's end goes with it while other bookmarks stay.
expect {
	body = "<w:p w:rsidR='00A1' w:rsidRDefault='00A1' w:val='1'><w:proofErr w:type='spellStart'/><w:bookmarkStart w:id='0' w:name='_GoBack'/><w:bookmarkStart w:id='1' w:name='keep'/><w:r><w:lastRenderedPageBreak/><w:t>a</w:t></w:r><w:bookmarkEnd w:id='0'/><w:bookmarkEnd w:id='1'/></w:p>"
	kept = drop(parse("<w:document ${w_declaration} w:rsidRoot='1'>${body}</w:document>"))
	expected = parse("<w:document ${w_declaration}><w:p w:val='1'><w:bookmarkStart w:id='1' w:name='keep'/><w:r><w:t>a</w:t></w:r><w:bookmarkEnd w:id='1'/></w:p></w:document>")
	counts = [{ content: RevisionSaveIds, count: 3 }, { content: RenderedPageBreaks, count: 1 }, { content: ProofingMarks, count: 1 }, { content: GoBackBookmark, count: 1 }]
	kept.tree == expected and kept.dropped == counts
}

## Prefixes, declarations, attribute order, whitespace between elements and
## dropped content do not make trees different.
expect {
	one = parse("<w:document ${w_declaration}>\n  <w:p w:a='1' w:b='2' w:rsidR='1'><w:proofErr/><w:r><w:t xml:space='preserve'> x </w:t></w:r></w:p>\n</w:document>")
	other = parse("<v:document xmlns:v='${wordprocessingml}'><v:p v:b='2' v:a='1'><v:r><v:t xml:space='preserve'> x </v:t></v:r></v:p></v:document>")
	Document.equivalent_xml(one, other)
}

## Text, attribute values and whitespace that `xml:space` preserves make
## trees different.
expect {
	base = parse("<w:document ${w_declaration}><w:p w:a='1'><w:t>a</w:t></w:p></w:document>")
	!Document.equivalent_xml(base, parse("<w:document ${w_declaration}><w:p w:a='1'><w:t>b</w:t></w:p></w:document>"))
		and !Document.equivalent_xml(base, parse("<w:document ${w_declaration}><w:p w:a='2'><w:t>a</w:t></w:p></w:document>"))
		and !Document.equivalent_xml(base, parse("<w:document ${w_declaration}><w:p w:a='1' xml:space='preserve'> <w:t>a</w:t></w:p></w:document>"))
		and !Document.equivalent_xml(base, parse("<w:document ${w_declaration}><w:p w:a='1'><w:t>a </w:t></w:p></w:document>"))
}

## Reading repairs the attributes a Google Docs export writes that the
## schema does not allow and reports each repair; the written part holds the
## repaired values, reads without a diagnostic, and is equivalent to the
## part as it was read.
expect {
	part = "/word/document.xml"
	main = "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"
	graph = {
		relationships: [{ id: "rId1", kind: Opc.officedocument_relationship, target: part, mode: Internal }],
		parts: [{ name: part, content_type: main, relationships: [] }],
	}
	xml = "<w:document ${w_declaration}><w:body><w:tbl><w:tblPr><w:tblW w:w='10470.0' w:type='dxa'/></w:tblPr></w:tbl><w:sectPr><w:pgMar w:top='576' w:left='863.9999999999999'/></w:sectPr></w:body></w:document>"
	read = Document.from_package(Opc.open(Opc.to_bytes(graph, |_| Bytes(xml.to_utf8()))?, {})?, {})?
	written = Document.to_bytes(read.document)?
	again = Document.from_package(Opc.open(written, {})?, {})?
	text = Str.from_utf8(Opc.part_bytes(Opc.open(written, {})?, part)?) ?? ""
	read.diagnostics
		== [
			Rounded({ part, element: "tblW", attribute: "w", value: "10470.0" }),
			Rounded({ part, element: "pgMar", attribute: "left", value: "863.9999999999999" }),
			Defaulted({ part, element: "pgMar", attribute: "gutter", value: "0" }),
		]
		and again.diagnostics == []
		and Document.equivalent(read.document, again.document)
		and text.contains("<w:tblW w:w=\"10470\" w:type=\"dxa\"/>")
		and text.contains("<w:pgMar w:top=\"576\" w:left=\"864\" w:gutter=\"0\"/>")
}

## A width written with a fraction is equivalent to the whole number it
## rounds to, and to no other.
expect {
	width = |value| parse("<w:document ${w_declaration}><w:tblW w:w='${value}' w:type='dxa'/></w:document>")
	Document.equivalent_xml(width("10470.0"), width("10470")) and !Document.equivalent_xml(width("10470.5"), width("10470"))
}

## A paragraph's text takes each kind of run content as its character, reads
## through containers, and skips preserved content.
expect {
	preserved = parse("<w:delText xmlns:w='${wordprocessingml}'>gone</w:delText>")
	run = |content| Run({ properties: Document.no_run_properties, content })
	paragraph : Document.Paragraph
	paragraph = {
		properties: Document.no_paragraph_properties,
		content: [
			run([Text("a"), Tab, Break({ kind: Line, clear: NoClear }), Break({ kind: Page, clear: NoClear }), Symbol({ font: "Symbol", code: 0x3B1 }), SoftHyphen, NonBreakingHyphen, Preserved(preserved)]),
			Container({ element: preserved, content: [run([Text("b"), Symbol({ font: "", code: 0xD800 }), Symbol({ font: "", code: 0x41 }), Symbol({ font: "Wingdings", code: 0xF0E0 })])] }),
			Preserved(preserved),
		],
	}
	Document.paragraph_text(paragraph) == "a\t\n\n\u(3B1)\u(AD)\u(2011)b\u(FFFD)A\u(F0E0)"
}

## Fields are listed in the order they begin with their code and result: a
## result spans paragraphs, a field nested in another's result is part of
## it, a simple field's result is its content, and a field that never ends
## ends with the blocks.
expect {
	mark = |kind| FieldMark({ kind, element: Text("") })
	run = |content| Run({ properties: Document.no_run_properties, content })
	paragraph = |content| Paragraph({ properties: Document.no_paragraph_properties, content })
	simple = SimpleField({ code: "DATE", preserved: [], content: [run([Text("today")])] })
	blocks = [
		paragraph([run([mark(Begin), FieldCode(" TOC "), FieldCode("\\o"), mark(Separate), Text("One")])]),
		paragraph([run([Text("Two "), mark(Begin), FieldCode("PAGEREF x"), mark(Separate), Text("2"), mark(End)]), simple]),
		paragraph([run([mark(End), Text("after"), mark(Begin), FieldCode("NUMPAGES")])]),
	]
	Document.fields(blocks) == [{ code: " TOC \\o", result: "One\nTwo 2today\n" }, { code: "PAGEREF x", result: "2" }, { code: "DATE", result: "today" }, { code: "NUMPAGES", result: "" }]
}

## A `HYPERLINK` field code names an address, an address and a location, or
## a bookmark, whatever its case, quoting and other switches; any other code
## names no target.
expect {
	Document.field_target(" HYPERLINK \"https://example.org/rates\" \\l \"q1\"") == Ok(ExternalAt({ url: "https://example.org/rates", location: "q1" }))
		and Document.field_target("hyperlink https://example.org/a \\o \"Tip\" \\t _blank") == Ok(External("https://example.org/a"))
		and Document.field_target("HYPERLINK \\l \"_Toc1\" \\h") == Ok(Internal("_Toc1"))
		and Document.field_target("HYPERLINK \"a b") == Ok(External("a b"))
		and Document.field_target(" PAGEREF _Toc1 \\h ") == Err(NotAHyperlink)
		and Document.field_target("HYPERLINK \\o \"Tip\"") == Err(NotAHyperlink)
		and Document.field_target("\"HYPERLINK\" x") == Err(NotAHyperlink)
		and Document.field_target("") == Err(NotAHyperlink)
}

# A package of a main document with an extension, a style part and a picture.
sample : List(U8) -> Try(List(U8), Opc.WriteError)
sample = |picture| {
	relationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
	graph = {
		relationships: [{ id: "rId1", kind: Opc.officedocument_relationship, target: "/word/document.xml", mode: Internal }],
		parts: [
			{
				name: "/word/document.xml",
				content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml",
				relationships: [
					{ id: "rId1", kind: "${relationships}/styles", target: "/word/styles.xml", mode: Internal },
					{ id: "rId2", kind: "${relationships}/image", target: "/word/media/picture.png", mode: Internal },
				],
			},
			{ name: "/word/styles.xml", content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml", relationships: [] },
			{ name: "/word/media/picture.png", content_type: "image/png", relationships: [] },
		],
	}
	mc = "xmlns:mc='http://schemas.openxmlformats.org/markup-compatibility/2006' xmlns:x='urn:example:extension' mc:Ignorable='x'"
	document = "<w:document ${w_declaration} ${mc}><w:body><w:p w:rsidR='00A1' x:mark='1'><w:r><w:t>Hello</w:t></w:r></w:p></w:body></w:document>"
	Opc.to_bytes(
		graph,
		|name|
			if name == "/word/document.xml" {
				Bytes(document.to_utf8())
			} else if name == "/word/styles.xml" {
				Bytes("<w:styles ${w_declaration}/>".to_utf8())
			} else {
				Bytes(picture)
			},
	)
}

## A package read and written passes through equivalently, without its
## dropped content and with an extension namespace outside the prefix table,
## and writing twice gives the same bytes.
expect {
	picture = [0x89, 0x50, 0x4E, 0x47, 1, 2, 3]
	pkg = Opc.open(sample(picture)?, {})?
	read = Document.from_package(pkg, {})?
	written = Document.to_bytes(read.document)?
	again = Document.from_package(Opc.open(written, {})?, {})?
	document = Opc.part_bytes(Opc.open(written, {})?, "/word/document.xml")?
	extension = "xmlns:mc=\"http://schemas.openxmlformats.org/markup-compatibility/2006\" xmlns:x=\"urn:example:extension\" mc:Ignorable=\"x\""
	read.diagnostics == [Dropped({ part: "/word/document.xml", content: RevisionSaveIds, count: 1 })]
		and Document.equivalent(read.document, again.document)
		and Document.to_bytes(read.document) == Ok(written)
		and Document.to_bytes(again.document) == Ok(written)
		and Str.from_utf8(document) == Ok("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<w:document xmlns:w=\"${wordprocessingml}\" ${extension}><w:body><w:p x:mark=\"1\"><w:r><w:t>Hello</w:t></w:r></w:p></w:body></w:document>")
		and Opc.part_bytes(Opc.open(written, {})?, "/word/media/picture.png") == Ok(picture)
}

## A changed part makes documents different.
expect {
	read = Document.from_package(Opc.open(sample([1])?, {})?, {})?
	other = Document.from_package(Opc.open(sample([2])?, {})?, {})?
	Document.equivalent(read.document, read.document) and !Document.equivalent(read.document, other.document)
}
