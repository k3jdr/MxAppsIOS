# MxNoteONE

A digital notebook for macOS (SwiftUI and AppKit), in the spirit of **Microsoft OneNote**.

Open `MxNoteONE.xcodeproj` in Xcode, then Run. There are no package dependencies. The first launch creates
**My Notebook** with a **Quick Notes** section and a Welcome page in `~/Documents/MxNoteONE Notebooks`
(change the folder in Settings).

## Window


| Part          | What it does                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| --------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Sidebar**   | Open notebooks, each with its**sections** (coloured tabs) and **section groups** (folders, can nest). Right-click a notebook, section or group to rename, recolour, move up/down or into a group, password protect, export or delete it. **+** adds a section, section group or notebook; the tag and trash buttons open the Tag Summary and Recycle Bin. The search field searches every open notebook.                                                                                                                                                             |
| **Page list** | Pages of the selected section with date and first line. Subpages are indented (two levels) and can be collapsed; drag to reorder (subpages move with their page). Right-click for New Page / Subpage, Make Subpage, Promote, Move or Copy…, Duplicate, Copy Link to Page, Export as PDF / Markdown, Print, Delete. While the search field has text, this column shows the search results instead.                                                                                                                                                                   |
| **Ribbon**    | **Home**: font and size boxes showing the selected text's font and size ("Mixed" / "–" when the selection mixes several; with table cells selected, the cells' font), bold / italic / underline / strikethrough buttons lit when the selection has them, then font, size, bold, italic, underline, strikethrough, superscript/subscript, highlight and font colours, clear formatting, bullets, numbering, indent, alignment, line spacing, styles (Heading 1–4, Title, Quote, Code), tags. **Insert**: table, picture, file attachment, screen clipping, audio recording, link, date / time stamps, page templates. **Draw**: type, pen, highlighter, eraser, line, arrow, rectangle, ellipse, pen colours and thickness. **View**: page colour, rule lines and grids, zoom, full page view, Tag Summary, Recycle Bin. |
| **Page**      | A title, and under it the date and time the page was created │ **Updated** and when it was last changed (hover for both in words), then a free-form canvas: click anywhere to start a text container there. Drag a container by its top bar, resize it from its right edge, right-click the bar for Cut / Copy / Delete / Bring to Front / Send to Back. Click a container's bar (or press Escape while typing) to select it; then Delete removes it and the arrow keys nudge it. Drop pictures and files onto the page. Pinch or use View ▸ Zoom. The page is always drawn as light paper.                                                                                 |

## Pages

Right-click the empty space in the pages list for **Add New**: New Page, New Subpage, New Page from Template, New
Section and New Section Group. Right-click a page for its own menu.

- **Text containers** hold rich text (fonts, colours, highlights, lists, inline pictures). Typing grows the container.
- **Bullets and numbering**: Return continues the list, Return on an empty item ends it, Tab / Shift-Tab indent items.
- **Tags**: ☐ To Do, ⭐ Important, ❓ Question, ❗ Critical, 💡 Idea, 📌 Remember for Later, 📖 Definition, 📞 Phone Number,
  💬 Discuss with Team (⌘1 – ⌘9, ⌘0 removes). Click ☐ to check it off; Return after a To Do starts another.
- **Tables, OneNote style**: type some text and press **Tab** — the paragraph becomes a table with your text in the
  first cell. While the table has one row, **Tab** in a filled last cell adds a column; **Return** in the last row adds
  a row; **Tab** in the last cell of the last row adds a row; **⌘Return** inserts a row below; **⇧Tab** goes back;
  **⌥Return** starts a new line inside a cell; **⌥Tab** types a real tab in text. Pressed Tab or Return once too
  often? **Backspace** in the empty new cell removes the empty column (or row) again. Text after the paragraph moves
  below the table, and a growing table (or text container) pushes the container right under it down.
- **Selecting cells**: click a cell to type in it; **drag** across cells, **⇧-click**, or **⇧-arrow keys** to select a
  block, **⌘-click** to add single cells; selected cells are highlighted. With cells selected (press Escape while
  typing to get there): typing replaces the cell, Delete clears the cells, Return edits, ⌘C / ⌘X / ⌘V copy, cut and
  paste cells as tab-separated text, ⌘A selects the whole table; Escape again selects the table container.
- **Formatting cells**: cell text is rich text — the Home ribbon (font, size, bold, italic, underline, colours,
  highlight, alignment…) formats the text you're typing, or every selected cell at once (select a column, then
  Bold or a colour).
- **Table ribbon tab**: appears whenever you're in a table — insert rows above/below and columns left/right, delete
  rows, columns or the table, shading for cells, rows, columns, the header row and **banded rows**, cell text
  bold / italic / colour / alignment, header row, **hide borders**, sort, select table.
- **Shading and table commands by right-click** (also while typing in a cell): Shade Selected Cells, Header Row,
  Row, Column, Banded Rows and Table Shading (colour palette or No Color), Text Color, insert / delete rows and
  columns, clear cells, delete table, sort, header row, hide borders. Text turns white on dark shades unless you
  gave it a colour. Shading moves with its row when sorting; new columns take the shading of the column beside them.
- **Columns, Excel style**: while you work in a table a bar of column letters (A, B, C…) sits on its top edge. Click
  a letter to select the column, ⇧-click or drag across letters for several. Right-click a letter for Sort A to Z /
  Z to A, Filter…, Hide / Unhide Columns, insert, delete, clear and Column Shading.
- **Hide and show columns**: Hide Column (column bar, right-click a cell, or the Table ribbon). Hidden columns keep
  their text; the table gets narrower, and a double line in the column bar marks where they are — click it to show
  them again, or use Unhide Columns.
- **Rows, Excel style**: row numbers (1, 2, 3…) run down the table's left side next to the column letters; the
  corner where they meet selects the whole table. When the page scrolls sideways the row numbers stay at the left edge
  of the view (a frozen first column sits just to their right); when it scrolls down the column letters and the
  corner stay at the top of the view, with a frozen header row (numbered 1) just below them.
  The numbers and letters show while you work in the table; **Always Show Headings** (right-click, or the Table
  ribbon's Headings) keeps them showing — and frozen while you scroll — even when you're elsewhere on the page. Click a number to select the row, ⇧-click or drag for several.
  Right-click a number for insert / delete / clear, Hide / Unhide Rows, Move Up / Down and Row Shading.
- **Hide and show rows**: Hide Row (row numbers, right-click a cell, or the Table ribbon). Hidden rows keep their
  text and are skipped by the arrow keys and by Move Row Up / Down; the numbers jump past them and a double line
  marks where they are — click it to show them again, or use Unhide Rows. Rows hidden this way stay hidden when
  Filter is turned off. While a filter hides rows the row numbers turn blue.
- **Filter** (Table ribbon, right-click, or Filter… on a column letter): filter buttons appear in the first row.
  A button opens Sort A to Z / Z to A, Clear Filter, a search box and a checklist of the column's values (with
  Select All and Blanks); OK hides the other rows. Filtered columns show a filter icon and "▾" by their letter.
  Like Excel, filters apply when you choose them — rows you edit afterwards stay visible until you filter again.
  Turning Filter off shows every row.
- **Sort and filter by colour** (a column's filter button, or right-click its letter ▸ Sort by Color / Filter by Color):
  the cell fill and font colours used in the column — conditional formatting's colours included, plus No Fill /
  Automatic — as swatches. Sort by Color brings rows with that colour to the top (the rest keep their order); Filter by
  Color shows only those rows. A colour filter is saved with the table; Clear Filter removes it.
- **Sorting** sorts numbers in order (2 before 10), ignores case and puts blank cells last. It leaves the first row
  in place as a header. For a table without Header Row, right-click ▸
  **Sort Includes First Row** sorts every row.
- **Inserting rows and columns**: Insert Row Above / Below (and Insert Column Left / Right) add as many rows (or columns)
  as are selected — select three rows and the menu says Insert 3 Rows Above — and the new ones are selected.
- **Fill Down / Fill Right** (⌘D / ⌘R, right-click ▸ Fill, or the Table ribbon's Fill menu): the selection's top row
  (or left column) is copied into the rest of it; with one cell selected the cell above (or left) comes in. Formulas
  move their relative references along as in Excel (=B2*C2 → =B3*C3; `$` parts stay), and number formats and shading
  come too. **Fill handle**: drag the small square at the selection's bottom-right corner down or right to fill — two
  or more evenly spaced numbers or dates continue as a series (1, 2 → 3, 4, 5; weekly dates) — or double-click it to
  fill down as far as the column beside has data.
- **Moving rows**: right-click ▸ Move Row Up / Down, the Table ribbon's Row Up / Row Down, or ⌥⇧↑ / ⌥⇧↓ (also while
  typing in a cell). Or select whole rows (right-click ▸ Select Row, or drag across them) and drag them up or down; a
  line shows where they'll go. The header row stays first.
- **Column widths**: drag a column border to resize that column (in the table or in the column letter bar); the table
  grows or shrinks with it. **Double-click a border to auto-fit** the column to its widest shown cell on one line
  (with whole columns selected, all of them fit). Also Auto-Fit Column Width / Auto-Fit All Columns by right-click.
- **Formulas, Excel style**: type `=` in a cell to enter a formula — the cell shows the result, and typing in it shows
  the formula again (hover a formula cell to see it). Enter finishes a formula and selects the cell below. References use
  the column letters and row numbers: `A1`, `$B$2`, `B2:B9`. Operators `+ - * / ^ & %` and `= <> < > <= >=`.
  Functions: SUM, AVERAGE, COUNT, COUNTA, COUNTBLANK, MIN, MAX, MEDIAN, PRODUCT, ROUND / ROUNDUP / ROUNDDOWN, ABS,
  SQRT, INT, MOD, POWER, EXP, LN, LOG10, PI, IF, IFERROR, AND, OR, NOT, SUMIF, COUNTIF, AVERAGEIF (with `">5"`, `"<>x"`,
  `"p*"` criteria), CONCAT / CONCATENATE, LEN, UPPER, LOWER, TRIM, LEFT, RIGHT, MID, and the date functions below. Numbers typed as
  `1,234.50`, `$12` or `15%` count as numbers. Errors show as Excel shows them (#DIV/0!, #REF!, #NAME?, #VALUE!, #NUM!),
  a formula that refers back to itself as #CIRC!, and one that can't be read as #ERROR!. Start with `'=` to type text
  that begins with "=".
  - **AutoSum** (Table ribbon, or right-click ▸ Formulas): sums the numbers just above the cell (else just left of it).
    **Formulas** menu: inserts a function with the caret inside its brackets.
  - References follow inserted and deleted rows and columns (a deleted cell becomes #REF!, a range just shrinks).
    Sorting and moving rows take a formula's relative row references with it; rows of totals (formulas over a range)
    stay in place when sorting. Sorting, filters, auto-fit and copying use the results.
- **Number formats** (Table ribbon's Number menu, Currency / Percent / Increase / Decrease Decimal buttons, or
  right-click ▸ Number Format on a cell or column letter): General, Number (1,234.50), Currency ($ € £ ¥ — $1,234.50,
  -$5.00), Percent (12.5%), with decimal places and a thousands separator. They apply to numbers and formula results
  in the selected cells (whole columns too); text is left alone. Typing in a cell shows the number as typed, and
  formulas use the value. Formats move with their cells when rows and columns are inserted, deleted, sorted or moved,
  and copying to Excel gives the formatted numbers.
- **Dates**: dates typed as `10/14/2026`, `2026-10-14`, `14-Oct-2026`, `Oct 14, 2026`, `October 2026` (and times such as
  `3:45 PM`) are dates, kept as Excel keeps them (serial day numbers). **Date formats** (Number menu ▸ dates, or
  right-click ▸ Number Format ▸ Date): Short Date (10/14/2026), Long Date (Wednesday, October 14, 2026), ISO
  (2026-10-14), 14-Oct-2026, Oct 14, 2026, October 2026, Time (3:45 PM), Date and Time. Typing in a cell shows the date
  as typed. In formulas a date plus or minus days is a date and one date minus another is days; DATE, YEAR, MONTH, DAY,
  WEEKDAY, EDATE, EOMONTH, DAYS, DATEDIF, and TODAY / NOW (dates). MIN / MAX of dates are dates. Dates sort by date.
- **Conditional formatting** (Table ribbon's Conditional menu, or right-click ▸ Conditional Formatting on a cell or column
  letter): rules for the selected cells — whole columns run to the end of the table, below a header — as in Excel:
  Greater Than, Less Than, Between, Equal To, Not Equal To, Text That Contains, Blank, Not Blank, Top / Bottom items,
  Above / Below Average, Duplicate / Unique values (with Excel's fill and text colour presets or bold), **Data Bars**
  and **Color Scales**. The popover lists the table's rules to delete them; Clear Rules from the selected cells or the
  table. Rules follow inserted and deleted rows and columns and are saved with the table.
- **Data validation** (Table ribbon's Validation menu, or right-click ▸ Data Validation on a cell or column letter): a
  rule for the selected cells (whole columns run to the end of the table, below a header) allows a **List** — values
  separated by commas, or a range such as `=E2:E9` — Whole Number, Decimal, Date or Text Length, with a minimum and / or
  maximum, and blanks allowed or not. List cells show a **dropdown button** while selected or being typed in (⌥↓ opens it
  too, or right-click ▸ Data Validation ▸ Choose from List). An entry that breaks the rule gets Excel's alert — **Stop**
  (Retry / Cancel), **Warning** (Continue? Yes / No / Cancel) or **Information** (OK / Cancel) — with your own title and
  message if you like; Cancel puts the old value back, Retry goes back to typing. **Circle Invalid Data** rings values
  already in the table that break their rule. Rules (and range lists) follow inserted and deleted rows and columns and
  are saved with the table. As in Excel, pasting isn't checked.
- **Pivot tables** (Table ribbon's Pivot menu, or right-click ▸ Create Pivot Table…): summarise a table — its first row
  names the fields — by one field down the rows and optionally another across the columns: Sum, Count, Average, Min,
  Max or Count Distinct of a value field (or a count of rows), with grand totals in bold. The pivot is a new table
  below the source (under any earlier ones), keeping the value field's number format; Min / Max of dates are dates.
  Every row of the source counts, filtered or not, as in Excel. **Refresh Pivot Table** (right-click the pivot, or the
  Pivot menu) works it out again from the source, finding the fields by name even if columns moved.
- **Charts** (Table ribbon's Chart menu, or right-click ▸ Insert Chart): **Column, Bar, Line, Area, Pie, Donut, Scatter**. Select
  columns — the first gives the categories, columns of numbers the series (named by the header row) — or one column of
  numbers (labelled by the table's first column), or just a cell for the whole table. The chart is its own container
  below the table; it follows the table as you type, and leaves out hidden and filtered rows (and a pivot table's grand
  total), as Excel does. Right-click a chart for Chart Type, Chart Title…, Legend, Refresh Chart and Copy Chart as
  Picture; resize it from its edge. **Scatter** charts plot the first column's numbers (or dates) across against the
  other columns, with axes fitted to the data and an optional dashed least-squares **Trendline** per series.
  **Axis Titles…** names the horizontal and vertical axes (scatter charts start with the field names).
  **Series Colors** (pie and donut: **Slice Colors**) picks each series' colour — Excel's colours, recent colours or
  More Colors… (the macOS colour picker); Automatic goes back. **Value Axis Format**: Automatic follows the table's
  number format for the values (so currency stays currency), or General, Number (1,234 / 1,234.00), Currency ($ € £),
  Percent (12% / 12.5%) or Compact (1.2K, 3.4M). A scatter chart's horizontal axis follows its column's format. A chart keeps the data it last drew, so it still shows if its table is deleted.
  Markdown export and OneNote sync write a chart as its title and data table.
- **Copy and paste with Excel**: ⌘C / ⌘X on selected cells puts them on the clipboard the way Excel does — an HTML
  table with fonts, bold / italic / underline, colours, shading, alignment, merged cells and column widths, plus
  tab-separated text — so they paste into Excel, Numbers or Word as cells (hidden rows and columns are left out).
  ⌘V reads cells copied from Excel (or any HTML table, or tab-separated text) into the table from the selected cell,
  with their formatting, fill and merges; the table grows to fit. One copied cell fills every selected cell. While
  typing in a cell, pasting several cells fills the table from that cell; one cell's text goes in at the caret.
  Fonts the import can't see (such as Calibri) come in as the notebook's default font.
  Pasting Excel cells onto the page (outside a table) makes a **new table** with their formatting, fill and merges,
  columns fitted to the contents — as do cells copied from another table, and tab-separated text whose lines have the
  same number of cells. (A web page that just contains a table inside its text still pastes as text.)
- **Row heights**: rows fit their content. Drag a row's bottom border (in the table or the row numbers) to give it a
  height of its own — text that doesn't fit is cut off, and the row opens up while you type in it. **Double-click the
  border to auto-fit** the row to its content again (with whole rows selected, all of them). Also Auto-Fit Row Height /
  Auto-Fit All Rows by right-click.
- **Pointer**: ↔ on column borders (resize), open hand on the table's top, left and bottom edges (drag to move the
  table), pointing hand on links (click to follow; ⌥-click to type in the cell instead), text cursor in cells. Links in
  text boxes show the pointing hand as well.
- **Frozen header row**: in a table with a header row, the header stays pinned at the top of the view while you scroll
  through the table, and scrolls away with its last row. Clicking a pinned header cell scrolls back to type in it.
  Turn it off per table with **Freeze Header Row** (right-click a cell or a column letter, or the Table ribbon's
  Freeze Header).
- **Freeze First Column** (right-click a cell or a column letter, or the Table ribbon's Freeze Column): when a wide
  table's left side scrolls out of view, its first column stays pinned at the left edge of the page (with its column
  letter), so each row's label stays visible. You can click and type in the pinned column. With a header row too,
  the header's first cell stays in the corner. It's saved with the table.
- **Any colour**: every shading menu (cells, rows, columns, header row, banded rows, table — right-click or the Table
  ribbon) and Text Color also offer **More Colors…** (the macOS colour picker) and the **Recent Colors** picked there.
- **Formatting selected cells**: with cells selected (not typing), the Home ribbon's font, size, bold, colours and
  alignment apply to the text in every selected cell.
- **Merge and split cells**: select neighbouring cells, then right-click ▸ **Merge Cells** (or Table tab ▸ Merge Cells);
  their texts are joined in the merged cell. **Split Cell** ▸ Unmerge Cells, Into 2 Columns or Into 2 Rows (the
  other rows / columns keep one cell across the new column / row). Tab, Return and the arrow keys step over merged
  cells, and inserting or deleting rows and columns keeps merges intact. A table with cells merged across rows can't
  be sorted. (OneNote itself has no merged cells, so merges sync to OneNote as separate cells.)
- Tables print, export to PDF and sync with OneNote with their shading and cell formatting.
- **Pictures**: double-click to open in a viewer; right-click to copy, save, or reset to original size.
- **Attachments** keep a copy of the file inside the notebook; double-click to open. **Recordings** play in place.
- **Snap to Grid** (View tab or View ▸ Snap to Grid, ⌃⌘G — as in OneNote for Windows): containers, pictures, tables
  and shapes line up on the page grid when you place, drag, resize or nudge them (arrow keys move one grid step). The
  grid is the page's rule lines or grid when it has them, otherwise 12 points (shown as dots while you drag). Hold ⌥
  to place something freely.
- **Ink**: pen and highlighter strokes, lines, arrows, rectangles and ellipses (hold Shift for 45° lines, squares, circles).
- **Lasso Select** (Draw tab): draw a loop around ink and containers to select them — selected ink is highlighted and
  a dashed frame surrounds the selection. Drag inside it to move everything together (it snaps when Snap to Grid is
  on), use the arrow keys to nudge, Delete to remove, Escape to deselect. Moving and deleting undo in one step.
  **⌘C / ⌘X / ⌘V** copy, cut and paste the whole selection — ink and containers with their pictures and files — keeping
  its layout: repeated pastes on the same page step 20 points down and right, on another page they land in the same
  place (or in view). Pasted items arrive selected, ready to drag; one undo removes a paste. The copy also carries the
  text and a picture of the selection, for pasting into other apps.
  The eraser removes whole strokes. Press Escape to go back to typing.
- **Copy links**: right-click a page, section, section group or notebook ▸ **Copy Link to this Page / Section /
  Section Group / Notebook**; right-click text in a text box or a table cell ▸ **Copy Link to this Paragraph**. The
  clipboard gets just the link's address, so its words are yours to choose where it goes: select words and paste to
  link them, paste with nothing selected to put in the target's name as the link, or paste the address into ⌘K's
  Address. Clicking a link opens the place (a paragraph link scrolls to the paragraph and selects it, and still finds
  it after edits move it; a cell link selects the cell). A web address on the clipboard pastes as a link the same way.
- **Links**: type `[[Page Name]]` to link to a page in the notebook (it is created if it doesn't exist), or use ⌘K for
  web links and links to any page. **Edit Link**: with the caret in a link, ⌘K (or right-click the link ▸ Edit Link…)
  opens the dialog with the link's text and address filled in — change either and Update, or Remove Link. Right-click
  a link also offers Open Link, Copy Link Address and Remove Link.
- **Link hover card**: rest the pointer on a link (in a text box or a table cell) and a card shows the link's own
  **hover text** (below), where it goes — a page's title with its notebook › section, the start of the page's text
  and when it was last updated; a web site and its full address; an email address — and the link's words, with
  **Edit Link…** (the Edit Link dialog, filled in), **Copy** (the address) and **Remove Link** (keeps the words). It
  goes away when the pointer moves off the link and the card, or on a click or key press.
- **Hover text** (Word's ScreenTip): in the Link / Edit Link dialog, write your own description for the link's card —
  formatted with bold, italic, underline, strikethrough, size and colour (buttons, or ⌘B ⌘I ⌘U), on several lines —
  and see it in **Hover card preview** before you Insert / Update. It's saved with the text (text boxes and table
  cells), found by search, and goes when the hover text is emptied or the link removed. The dialog's fields and
  buttons explain themselves when you hover over them.
- **Paste options** (Edit menu, or right-click ▸ Paste Options in a text box or table cell): **Paste as Plain Text**
  (⌥⇧⌘V) takes on the style where it goes; **Paste with Formatting** keeps the copied fonts, colours and styles. With
  table cells selected, Paste as Plain Text fills them from tab-separated text without formatting; on the page it makes
  a new text box in the default style.
- **Templates**: To Do List, Meeting Notes, Project Overview, Lecture Notes (Cornell), Daily Journal, Weekly Planner, Decision Log.
- Everything saves automatically. Undo / Redo covers typing, formatting, moving, resizing, inserting, deleting and ink,
  and table changes (sorting, moving rows, inserting / deleting rows and columns, shading, merging, column widths,
  typing in cells). ⌘Z / ⇧⌘Z, or ⌃Z / ⌃Y as in OneNote for Windows.

## Music scores

**Insert ▸ Music Score** (or the Insert ribbon's Score button) puts a staff on the page, like a table: a treble or bass
clef, key signature, time signature and tempo, with a melody of notes and rests laid out in bars that wrap to the
container's width (drag its edge). While a score is being edited the **Score** ribbon tab appears.

| To | Type (as in MuseScore) | or |
| --- | --- | --- |
| Add a note after the cursor | **A–G** (in the octave nearest the note before) | double-click the staff at a pitch |
| Add a rest | **0** | Score tab ▸ Rest |
| Length of the next note — 16th, 8th, quarter, half, whole | **3, 4, 5, 6, 7** (on a selected note: changes it) | Score tab ▸ Notes |
| Dot | **.** | Score tab ▸ Dot |
| Tuplet: duplet, triplet, quadruplet, quintuplet, sextuplet, septuplet, nonuplet (next notes, or the selected run) | **⌃2 ⌃3 ⌃4 ⌃5 ⌃6 ⌃7 ⌃9** | Score tab ▸ Notes ▸ Tuplet, right-click ▸ Tuplet |
| Grace note before the selected note: acciaccatura / appoggiatura | **/  ?** | Score tab ▸ Notes ▸ Grace Note, right-click ▸ Grace Note |
| Write on the staff above / below (or click it) | **⌥⌘↑ / ⌥⌘↓** | Score tab ▸ Staves |
| Add a treble or bass staff; piano grand staff; move, rename, remove a staff | | Score tab ▸ Staves, right-click ▸ Staves |
| Write in voice 1 / voice 2 | **⌥⌘1 / ⌥⌘2** | Score tab ▸ Voice, or click a note of that voice |
| Select a run of notes | **⇧← ⇧→**, or ⇧-click | |
| Slur over the selected notes (one note: to the next); again takes it off | **S** | Score tab ▸ Expression, right-click |
| Crescendo / diminuendo hairpin over them | **<  /  >** | Score tab ▸ Expression, right-click |
| Staccato / tenuto / accent / marcato on the selected notes (again: off) | **⇧S  ⇧N  ⇧V  ⇧O** | Score tab ▸ Articulation, right-click ▸ Articulations & Ornaments |
| Fermata | **⇧H** | Score tab ▸ Articulation |
| Trill, mordent, inverted mordent, turn; staccatissimo | | Score tab ▸ Articulation ▸ Ornament, right-click |
| Dynamic under the selected note (ppp … fff, sfz, fp) | | Score tab ▸ Expression ▸ Dynamic, right-click ▸ Dynamic |
| Tempo from the bar of the selected note: a word (Allegro…), ♩ = n, rit., accel., a tempo, Metronome Mark… | | Score tab ▸ Tempo, right-click ▸ Tempo from Bar *n* |
| Key change from the bar of the selected note (or the cursor) | | Score tab ▸ Bars ▸ Key Change, right-click ▸ Key Change from Bar *n* |
| Start / end repeat on that bar | | Score tab ▸ Bars ▸ Start Repeat \|: / End Repeat :\|, right-click |
| Move the note just typed (or selected) a step / an octave | **↑ ↓** / **⌘↑ ⌘↓** | drag the note up or down |
| Sharp, flat, natural (again takes it off) | **+  -  =** | Score tab ▸ ♯ ♭ ♮ |
| Tie to the next note / note ↔ rest | **T** / **R** | |
| Select notes, move the cursor | **← →**, or click a note | |
| Delete | **Delete** | |
| Play from the selected note (again: stop) | **Space** | Score tab ▸ Play, right-click ▸ Play |
| Add a note to the chord (above its top note) | **⇧A–G** | Score tab ▸ Chord Note |
| Chord symbols above the staff (C, Am7, G/B) | **⌃K**, then Space for the next note, Return to finish | Score tab, right-click |
| Lyrics under the notes | **⌃L**, then Space / Tab for the next note, **-** for the next syllable | Score tab, right-click |
| Move the note to another guitar string | **⌥↑ / ⌥↓** | Score tab |
| Guitar chord diagrams over the chord symbols | | Score tab ▸ Chord Diagrams, right-click |
| Capo (fret 1–9) | | Score tab ▸ Capo, right-click ▸ Capo |

Eighths and sixteenths are beamed by the beat (a dotted quarter in 6/8, 9/8, 12/8); accidentals show only where the key
and the bar don't already give them, and last to the end of the bar; ledger lines, ties and a final bar line are
drawn. Chord notes share a stem (notes a step apart sit side by side) and sound together; lyrics are spaced so words
don't run together, with hyphens between syllables. **Guitar Tab** (Score tab or right-click) adds a six-string TAB
staff under the music with each note's string and fret in standard tuning (treble-clef guitar music sounds an
octave lower), chosen automatically — lowest fret, one string per chord note — unless moved with ⌥↑ / ⌥↓. Clef, key (C to F♯ and G♭ major), time (4/4, 3/4, 2/4, 2/2, 6/8, 3/8, 9/8, 12/8, 5/4), tempo and title are on
the Score tab and the right-click menu, as is Copy Score as Picture. Playback uses the Mac's General MIDI piano, and the
note sounding is shown in orange. Every change can be undone. PDF and print show the score; Markdown export and OneNote
sync write its title, signatures and the notes by name.

**Dynamics and slurs** — dynamics sit under the staff in bold italic, hairpins open (crescendo) or close
(diminuendo) between notes, and slurs curve over the notes they join (under them when the stems go up; with two
voices, voice 1's over and voice 2's under); slurs and hairpins that run onto the next line continue there. Playback
follows them: each level plays louder or softer, a hairpin grows or fades towards the next dynamic (or by two levels),
sfz accents its note and fp plays loud then soft; a second voice without its own dynamics follows voice 1's.

**Articulations and ornaments** — staccato, staccatissimo, tenuto, accent and marcato sit by the note head (with two
voices, past each voice's stems); trills, mordents, inverted mordents, turns and fermatas go outside the staff. They
play: staccato shortens a note to half (staccatissimo to a third), tenuto and slurred notes are held full length,
accents and marcato are louder, a fermata holds its note twice as long while everything after waits, and ornaments
play their quick notes in the key (a trill alternates with the note above; a mordent dips to the note below; an
inverted mordent goes to the note above; a turn goes above, back, below and back).

**Tempo changes and metronome marks** — the score's tempo shows over the first bar as a metronome mark (♩ = 100),
with a tempo word if you give one (**Allegro** (♩ = 132)). A tempo change can start at any bar: pick a word with its
usual speed (Largo 50 … Presto 184), a speed, or **Metronome Mark…** for any speed counted in quarters, dotted quarters
(for 6/8, 9/8, 12/8), halves or eighths, with a word of your own. *rit.* and *accel.* get gradually slower or faster,
with a dashed line, up to the next tempo change (reaching its speed), or over two bars by about a third; **a tempo**
returns to the speed before them. Playback follows every change, smoothly through rit. and accel.

**Key changes** start at a bar: a double bar line, naturals cancelling the old key's sharps or flats, then the new
key; later lines start with the key in effect, and the notes sound in it. In the first bar, Key Change sets the score's
key signature. **Repeat signs** (|: and :|) play the passage twice: an end repeat goes back to the last start repeat,
or to the beginning (or just after the previous repeat) when there isn't one. Key changes and repeats belong to bar
numbers, so adding or deleting notes earlier in the score can move music past them.

**Several staves and the piano grand staff** — **Insert ▸ Piano Score** (or the Insert tab's Piano button, or
Score tab ▸ Staves ▸ Make Piano Grand Staff) gives treble and bass staves joined by a brace, with bar lines running
through both. **Add Staff** puts more treble or bass staves under them (an ensemble: bracketed). Every staff shares the
bars, key, time, tempo, repeats and title; notes that sound together line up across the staves, and they all play
together (a staff without its own dynamics follows the top one). Click a staff, or press ⌥⌘↑ / ⌥⌘↓, to write on it;
each staff has its own clef, two voices, slurs, dynamics, lyrics and the rest. The others show a little lighter while
you write. Staves can be moved up and down, named (the name goes into MusicXML) and removed.

**Chord diagrams and capo** — **Chord Diagrams** draws a guitar diagram under each chord symbol: the usual open
chord where there is one (C, G7, Am7, Dsus4, Gmaj7…), else a barre shape on the 6th or 5th string, whichever sits lower
on the neck (F 133211, Bm x24432, E♭ at the 6th fret) — strings, frets, the nut or "6fr", dots, the barre, ○ open and ×
not played. Extensions are drawn as the nearest shape (A13 as A7). A **Capo** (frets 1–9) is marked "Capo 3" over the
music; chord names show the shape played after the sounding chord — E♭ (C) — the diagrams show that shape, and TAB
counts frets from the capo. The music still sounds as written. MusicXML keeps both (staff-details capo, harmony frames).

**Tuplets beyond triplets** — 2 in the time of 3 (a duplet in 6/8), 4:3, 5:4, 6:4, 7:4 and 9:8 — are numbered and
bracketed like triplets, fill their bar correctly and play in time. **Grace notes** sit small before their note and take
no time in the bar: an **acciaccatura** (slashed) is crushed in just before the beat; an **appoggiatura** takes half of
its note's time. Move a grace note with ↑ ↓ like any other.

**Triplets** — three notes in the time of two (three triplet eighths make a beat) — are marked with a 3, bracketed
unless they're beamed together, and play in time. **Two voices** share the staff, as in MuseScore: voice 1's stems go up
and voice 2's down (rests move up and down out of the way), notes sounding at the same time line up, and both voices
play together. While you write in one voice the other is shown in grey; clicking one of its notes switches to it.

**MusicXML** — the format MuseScore, Finale, Sibelius and Dorico exchange scores in. **Insert ▸ Music Score from
MusicXML…** (or the Insert ribbon's MusicXML button, or drop a `.musicxml` / `.mxl` file on the page) brings in a
score — every part and staff (a piano part's two staves become a grand staff; other parts each a staff, named) —
with title, key, time, clef, tempo, notes, rests, dots, ties, accidentals, chords, chord symbols, lyrics and guitar
strings, grace notes, tuplets of any kind, tempo changes (words, metronome marks, rit. / accel.), dynamics, hairpins, slurs, articulations, ornaments, fermatas, key changes, repeat signs, triplets and a second voice on each staff (rests fill where it's silent) — anything left out (third and later
voices, staves beyond a part's first two, cue notes) is listed. Right-click a score (or the Score tab) ▸ **Export
MusicXML…** saves it as MusicXML 4.0 with all of that: a piano grand staff as one part with two staves, every other
staff as a part of its own.
A tie carries its note's accidental across the bar line.

## Microsoft Office fonts

Office for Mac keeps its fonts (Calibri, Consolas, Cambria, Aptos, Segoe UI…) inside the Office apps, so other apps
can't use them. When Word, Excel, PowerPoint, OneNote or Outlook is installed, MxNoteONE loads those fonts for itself
at launch — nothing is copied or installed and other apps aren't affected. They appear in the ribbon's font box
(Calibri, Aptos, Segoe UI, Cambria and Consolas in the short list), Settings and Notebook Fonts, and imported OneNote
pages keep their Calibri / Consolas text. Turn it off in **Settings ▸ General ▸ Fonts ▸ Use fonts from Microsoft
Office** (takes effect the next time MxNoteONE opens). The fonts are Microsoft's, licensed with Office.

## Notebook fonts

**Notebook ▸ Notebook Fonts…** (also in the Format menu and a notebook's right-click menu) sets one font family and
size for every page of a notebook — text boxes and table cells. Sizes can be scaled (text at the current default size
gets the new size and headings stay proportionally larger), set to one size, or kept. Options: only change text in the
current default font (keep text you set to other fonts), leave code (monospaced) text alone, and also use the font
for new text. Bold, italic, colours and links are kept; page titles keep their style; locked sections are skipped.
It can't be undone.

## Keys in notes (OneNote style)

- **Enter**: lists and To Dos continue; Enter on an empty item steps out one level, then ends the list. A new line keeps
  the paragraph's indent; Enter on an empty indented line steps out. After a heading the next line is Normal text.
  **⇧Enter** starts a new line in the same paragraph.
- **Backspace** at the start of a tagged, bulleted or numbered paragraph removes the tag or marker (the text stays); at
  the start of an indented paragraph it steps out one level.
- **↑ / ↓** on the first / last line of a text box continue into the text box or table directly above / below, as if
  the page were one outline. **⌥⇧↑ / ⌥⇧↓** move the selected paragraphs up or down.
- **In tables**: Enter makes a new line in the cell (in the last row it adds a row; ⌘Enter inserts a row below);
  ↑ / ↓ at the first / last line of a cell go to the cell above / below (and out of the table at the top or bottom);
  ← / → at the start / end of a cell go to the previous / next cell. ⌥⇧↑ / ⌥⇧↓ move the row up or down.

## Code blocks

Select lines of code and choose **Format ▸ Format as Code** (⌥⌘C), or **Home ▸ Code** on the ribbon. The lines become a
shaded block in Menlo, coloured like VS Code: keywords, control flow, types, functions, strings, numbers, comments,
constants, properties, tags and attributes. The language is detected (Swift, Python, JavaScript, TypeScript, Java,
C#, C / C++, Go, Rust, SQL, JSON, HTML / XML, CSS, Shell, YAML), or pick one from **Format as Code in**. **Code Theme**
switches between Dark+ and Light+ (the block at the caret changes; new blocks use the theme).

- The block re-colours as you type.
- Enter keeps the indent and adds a level after `{ [ ( :`; Enter on an empty last line leaves the block.
- Tab types four spaces and ⇧Tab removes them. Backspace in leading spaces steps back to the previous four-space stop.
- Clear Formatting (⇧⌘N) turns a block back into normal text.

## Arranging the toolbar

The ribbon fits the window: its sections wrap onto more rows instead of running off the side (**View ▸ Toolbar ▸ Wrap
Sections onto More Rows**; turn it off to scroll sideways instead). Each section — Font, Format, Notes, Articulation,
Bars… — can be put where it's wanted from **View ▸ Toolbar ▸ *Tab* Sections ▸ *section***, the **⋯** button at the right
of the ribbon tabs, or by right-clicking a section:

- **In the Toolbar** — as usual;
- **Collapsed to a Button** — the section's name with ▾; clicking it shows its tools in a popover;
- **Floating Palette** — the section in a small window of its own that stays over the notes (and doesn't take the
  keyboard). Closing the palette docks the section back into the toolbar; palettes reopen where they were the next
  time MxNoteONE starts. Table and Score palettes work while a table or score is being edited;
- **Hidden**.

**Compact Toolbar** (⌥⇧⌘R) makes every section smaller — no section names, small buttons. **Collapse All**, **Show All
Sections** and **Dock All Palettes** put things back. The arrangement is remembered.

## Notebook scripts (Python automation)

Python scripts can read and change the notebook's tables — every page, every section (locked ones aside).

- **Names and tags.** Select a table ▸ Table tab ▸ **Automation ▸ Name & Tags** to give it a name (unique in the
  notebook — MxNoteONE warns about a clash) and tags (#expenses). **Tag Rows** and **Tag Cells** tag the selection;
  tagged cells show a blue corner and tagged rows a blue mark. Tags stay on their rows and cells when rows are added,
  deleted, sorted or moved. **Copy Reference** copies the Python that gets to the selected cell. The same commands are
  on the right-click menu ▸ Name & Tags, and Quick Help shows a cell's names and tags.
- **Scripts belong to the notebook.** They're plain `.py` files in the notebook's `scripts` folder (with a
  `requirements.txt`), not on any page — open them in any editor, keep them in git, copy them to another notebook.
- **Notebook ▸ Notebook Scripts…** (⌥⌘P) is the editor: the scripts on the left (+ makes one from a template:
  totals across tagged tables, flag low stock, tables to CSV, pandas summary; or import .py files), Python colouring,
  auto-indent, ⌘/ comments, line numbers. **Run** (⌘R) and **Debug** (⇧⌘R): click a line number for a breakpoint;
  the debugger stops there (or at the first line), shows the variables and the call stack, and **Step Over** (F6),
  **Step Into** (F7), **Step Out** (F8), **Continue** (⌃⌘Y), **Stop** (⌘.); type an expression in the console to see its
  value. Output and errors (with the line marked in red) go to the console; input() reads from it. Notebook ▸ Run
  Script runs one straight from the menu.
- **Changes show as the script runs** — on the page on screen at once (one Undo step), on other pages saved in the
  background. **Revert Last Run** puts every page the last run changed back as it was.
- **Python and packages.** Scripts run with the Python on the Mac (Settings ▸ General ▸ Python chooses one; if there's
  none, the window explains how to install it — Apple's Command Line Tools, python.org, or Homebrew). Each notebook
  gets its own environment (a Python virtual environment in Application Support). When a script imports a package
  that isn't installed, a banner says so before it runs and **Install and Run** installs it with pip (and adds it to
  requirements.txt, so another Mac can install the same); the inspector's **Packages** tab lists, installs and removes
  packages.

```python
import mxnote as mx

inv = mx.table("Inventory")                 # a table by name (or tag)
for row in inv.rows:                        # rows after the header
    if row["Qty"] < 5:                      # a cell by heading, letter or number
        row["Status"] = "Reorder"
        row.tags.add("low")
total = sum(t.column("Amount").sum() for t in mx.tables(tag="expenses"))
mx.cell("grand-total").value = total        # a tagged cell, on any page
inv.append({"Item": "Glue", "Qty": 7})
```

The inspector's **Tables** tab lists every table in the notebook with its name, tags, page and tagged rows and cells
(double-click to put a reference into the script); **Help** has the whole mxnote reference.

## Quick Help

**View ▸ Quick Help** (⌥⌘/) shows a panel at the bottom of the sidebar — like Logic Pro's — telling what's under the
pointer in a sentence or two, with its shortcut: any toolbar tool or section; a note in a score (its pitch, length,
bar, voice, dynamics and marks); a table cell (its formula and value, number format, merging); a link (where it goes,
its hover text); a text box, picture, attachment, recording, chart, the page title or the page itself. Over nothing
it can describe, it tells about what's being worked on — the selected notes, the cell being typed in, the text being
typed. Every toolbar tool has a short one- or two-word tooltip; Quick Help has the details.

## Web links

**Settings ▸ General ▸ Web Links ▸ Open web links in:** chooses the browser MxNoteONE opens web links in — for example
DuckDuckGo — while Safari (or whatever the Mac's default is) stays the default for every other app. It applies to
links clicked in text boxes and table cells, Open Link on the right-click menu, and OneNote for the Web; the link's
hover card says which browser it will open in. Email links still open in Mail and page links stay in MxNoteONE. If
the chosen browser is removed, links go back to the Mac's default.

## Spelling

Misspelled words are underlined in text boxes, page titles and table cells. Right-click one for suggestions,
Ignore Spelling and Learn Spelling; in text boxes the app's own items (links, Format as Code) come after them.
Table cells formatted as code aren't checked.

**F7** (fn F7 on a Mac keyboard), or Edit ▸ Check Spelling, checks spelling as in Office: in the text being typed in
from the caret on (in a table, then the cells after it), in the selected table cells, or — with nothing being typed in
— on the whole page, top to bottom. The next misspelt word is selected and the Spelling panel offers corrections,
Ignore and Learn; F7 again goes on to the next one. When there are none, a message says so.

## Keyboard


| Command                                                 | Keys                                       |
| --------------------------------------------------------- | -------------------------------------------- |
| New Page / New Subpage / New Quick Note                 | ⌘N / ⌥⌘N / ⌃⌘N                        |
| New Section                                             | ⌘T                                        |
| Open Notebook…                                         | ⌘O                                        |
| Search All Notebooks / Find on Page                     | ⌘E / ⌘F (⌘G, ⇧⌘G for next / previous) |
| Bold / Italic / Underline / Strikethrough               | ⌘B / ⌘I / ⌘U / ⌃⌘-                    |
| Superscript / Subscript / Highlight                     | ⌃⌘= / ⌃⇧⌘= / ⌃⌘H                    |
| Bigger / Smaller                                        | ⇧⌘> / ⇧⌘<                              |
| Heading 1 – 4 / Normal                                 | ⌥⌘1 – ⌥⌘4 / ⌥⌘0                     |
| Bullets / Numbering                                     | ⌘. / ⌘/                                  |
| Clear Formatting                                        | ⇧⌘N                                      |
| Format as Code                                          | ⌥⌘C                                      |
| Tags / Remove Tag / Tag Summary                         | ⌘1 – ⌘9 / ⌘0 / ⇧⌘T                   |
| Link…                                                  | ⌘K                                        |
| Date / Time / Date & Time                               | ⌥⇧D / ⌥⇧T / ⌥⇧F                      |
| Insert Table / Picture / Screen Clipping / Record Audio | ⌃⌘T / ⌃⌘P / ⌃⇧⌘S / ⌃⌘R            |
| Back / Forward                                          | ⌘[ / ⌘]                                  |
| Previous / Next Page                                    | ⌥⌘↑ / ⌥⌘↓                            |
| Previous / Next Section                                 | ⌥⌘← / ⌥⌘→                            |
| Make Subpage / Promote Subpage                          | ⌥⌘] / ⌥⌘[                              |
| Move or Copy Page…                                     | ⇧⌘M                                      |
| Zoom In / Out / Actual Size                             | ⌘= / ⌘- / ⌃⌘0                          |
| Full Page View / Show Ribbon                            | ⌥⌘F / ⌥⌘R                              |
| Snap to Grid                                            | ⌃⌘G                                      |
| Lock All Protected Sections                             | ⌃⌘L                                      |
| Export Page as PDF… / Print Page…                     | ⇧⌘E / ⌘P                                |
| Reload Notebooks                                        | ⇧⌘R                                      |
| Save Notebook As…                                      | ⇧⌘S                                      |
| Sync All OneDrive Notebooks                             | ⌃⌘S                                      |

## Importing from Microsoft OneNote

**File ▸ Import** reads OneNote's own files:

- **OneNote Package (.onepkg)…** — a notebook exported from OneNote for Windows (File ▸ Export ▸ Notebook) becomes a
  new notebook; its section groups become section groups.
- **OneNote Sections (.one)…** — section files are added to the current notebook.
- **OneNote Notebook Folder…** — a folder of section files (with section-group subfolders), for example a OneNote
  backup folder. When there are several backups of a section ("Name (On 10-3-2026).one"), the newest is used.

What comes in: pages with their titles, subpage levels and dates; text containers at their positions; fonts, sizes,
bold, italic, underline, strikethrough, superscript / subscript, colours, highlights, alignment, headings, bullets,
numbering and indents; hyperlinks; tags (To Do with its check mark, Important, Question…); tables with column widths,
cell shading and formatted cell text (including pictures inside cells); pictures and attached files; section colours.
Not imported: ink (handwriting and drawings) and password-protected sections. Sections are in alphabetical order. The
reader follows Microsoft's published file format ([MS-ONESTORE] and [MS-ONE]).

**Pictures in the `onefiles` folder**: OneNote keeps larger pictures outside the section files, in a `onefiles`
folder (files named after an ID, like `{44382328-6B0E-…}.jpg.onebin`). The importer looks for it next to the
sections. If it isn't there, the import offers **Locate Pictures…**, and a grey note marks where each missing picture
goes — on the page or inside a table cell. Copy the `onefiles` folder from the Windows PC (or OneDrive) later and
choose it with **Notebook ▸ Find Missing OneNote Pictures…**, or click any picture note: the pictures go into place.

## OneDrive and Microsoft OneNote

Notebooks sync with **OneNote notebooks on OneDrive** through Microsoft's OneNote API, so the same notebook opens in
OneNote for Mac, Windows, iPad and the web (OneNote for Mac only opens notebooks kept on OneDrive or SharePoint).

- **File ▸ OneDrive ▸ Save “Notebook” to OneDrive** creates the OneNote notebook and uploads its sections, section
  groups and pages. After that, **Sync** (or ⌃⌘S for all OneDrive notebooks, or automatic sync in Settings) works both ways.
- **File ▸ OneDrive ▸ Open Notebook from OneDrive…** lists your OneNote notebooks and downloads one into a local notebook.
- Right-click a synced notebook (☁︎ in the sidebar) for **Sync**, **Open in OneNote**, **Open in OneNote for the Web**
  and **Stop Syncing**.

Page by page: changed only here → uploaded; changed only in OneNote → downloaded; changed in both → the OneNote
version comes down as a separate “(OneDrive copy)” page and the local version goes up; deleted on one side and
unchanged on the other → deleted on both (locally into the Recycle Bin).

What carries over: page titles, positions of containers, text formatting (fonts, sizes, colours, highlight, bold,
italic, underline, strikethrough, superscript/subscript, alignment), bullets and numbering, links, tags (To Do with
its check mark, Important, Question, Critical, Idea, Remember for Later, Definition, Phone Number, Discuss), tables,
pictures and attached files. Ink is uploaded as a picture. Not possible through the OneNote API: renaming or deleting
sections, setting subpage levels in OneNote, page colours and rule lines. **Password-protected sections stay on this
Mac** and are never uploaded.

**One-time setup** (Settings ▸ OneDrive has the same steps):

1. In the [Azure portal](https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade), App
   registrations ▸ New registration; supported accounts: any organizational directory and personal Microsoft accounts.
2. Authentication ▸ Add a platform ▸ iOS / macOS, bundle ID `com.k3jdr.MxNoteONE` (redirect URI
   `msauth.com.k3jdr.MxNoteONE://auth`).
3. API permissions ▸ Microsoft Graph ▸ Delegated: `Notes.ReadWrite`, `User.Read`.
4. Paste the Application (client) ID into Settings ▸ OneDrive and Sign In. The sign-in is remembered in the Keychain.

## Notebooks on disk

A notebook is a folder named `Name.mxnotebook`, so it can live in iCloud Drive, OneDrive, Google Drive or Dropbox and
be opened on another Mac with **File ▸ Open Notebook…** (⌘O; use **Reload Notebooks** after a sync).
**File ▸ Save Notebook As…** (⇧⌘S) copies a notebook to another place — on this Mac or in your OneDrive folder — and
keeps working with the copy; **New Notebook…** offers your OneDrive folders as locations.

```
Name.mxnotebook/
  notebook.json          section tree, colours, recycle bin
  sections/<id>.json     a section's page list and search index (titles, text, tags)
  pages/<id>.json        a page: title, style, containers (rich text as RTFD, tables), ink
  assets/<id>.<ext>      pictures, attachments and recordings
```

**Password-protected sections** encrypt their section file, pages and assets with AES-GCM using a key derived from the
password (PBKDF2-SHA256, 200,000 rounds). Locked sections are hidden from search and the Tag Summary. Sections lock
again after a time away from the app (Settings). A forgotten password cannot be recovered.

**Touch ID, Apple Watch or your Mac password**: when you unlock a protected section, tick “Use Touch ID to unlock next
time” (or right-click an unlocked section ▸ Unlock with Touch ID). The section's key is kept in your login Keychain —
for this app, on this Mac — and is used only after macOS confirms it's you (Touch ID, an Apple Watch, or your login
password); the section then opens with **Unlock with Touch ID**. Changing the password updates the kept key; removing
the password or turning the option off deletes it. **Settings ▸ Security ▸ Require Touch ID to open MxNoteONE** covers
the window until macOS confirms it's you — at launch and again after the auto-lock time away.

**Recycle Bin**: deleted pages and sections are kept for 60 days per notebook; restore or delete them from
View ▸ Recycle Bin.

## Permissions

The app is not sandboxed, so notebooks can be anywhere. macOS asks once for the **microphone** (audio recordings)
and for **screen recording** (screen clippings, which use the system `screencapture` tool).
