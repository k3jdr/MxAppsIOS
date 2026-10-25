# MxDataSQL

A macOS app (SwiftUI and AppKit) for browsing and editing PostgreSQL tables. Each
document is a **workspace** (`*.mxworkspace`, a small JSON file).

Open `MxDataSQL.xcodeproj` in Xcode, then Run. The PostgresNIO Swift package is fetched automatically.

## Workspace forms

| Form | What it does |
|------|--------------|
| **DB Connection** | Host, port, user, database, password, SSL mode (`disable` / `prefer` / `require`, with no certificate verification, like libpq). |
| **DB Table Selection** | Lists tables with a row count (`~` = planner estimate; **Count Rows** replaces it with `count(*)`) and size. The panel on the right shows a psql `\d` style description: columns, indexes, check constraints, foreign keys and "referenced by". Double-click a table or press **Open Table** to load it. With **Open in New Window** checked, the table opens in its own window instead (see below). |
| **DB Table** | SQL box with **Run SQL** (see below) above an editable grid that fills the form and resizes with the window. *Columns* (default **3**) are sized to span its width, except columns you resize by dragging, which keep their width (saved per table in the workspace; right-click the header ▸ **Reset Column Widths** to undo); *rows* (default **10**) set its minimum height. Scroll bars reach the rest of the fetched rows (default 1000). Edited cells are highlighted until you run **Update…**. Cells can be selected and copied (see **Selecting and copying cells**). |

### Switching databases

While connected, a **Database** drop-down sits to the left of the three form buttons. It lists the databases on
the server that your user may connect to. Choosing one reconnects to that database on the **same server, with the
same user and password**, then refreshes DB Table Selection (schema, table, rows, size) and the `\d` description
on the right: the same schema.table stays highlighted when the new database has it, otherwise the first table is.

- The workspace remembers the chosen database (save it to keep it).
- The open table closes; pending grid edits are confirmed first. The SQL box keeps its text.
- If the new database can't be reached, the previous one is reconnected and the error is shown.
- Table windows opened with **Open in New Window** keep their own connection and database.

## Run SQL

Above the grid on the DB Table form is an SQL box. Opening a table fills it with the statement that loads
the grid, e.g. `SELECT * FROM public.customers ORDER BY id`. Edit it and click **Run SQL** (⌘↩).
The grid then shows the results, up to the **Rows to fetch** limit (default 1000; Table ▸ View…).

Pre-flight checks run before anything executes. Problems are shown in red above the SQL box, psql style,
with the line and a caret under the error position:

1. The statement is not empty and is a SELECT, WITH, VALUES, TABLE, INSERT, UPDATE, DELETE, MERGE, CALL,
   CREATE, ALTER or DROP. Other commands (TRUNCATE, GRANT, BEGIN / COMMIT, ...) are refused.
2. There are no pending grid edits, which the new results would replace.
3. The server parses and analyses the statement with `PREPARE` without running it. This catches syntax
   errors, unknown tables or columns, several statements, and `$1` parameters.

Queries run in a **read-only transaction**. A statement that changes data, whether it is an
INSERT/UPDATE/DELETE or a query that writes, asks for confirmation first. It then runs in its own
transaction and is committed if it succeeds. After a write without `RETURNING`, the opened table is reloaded.

**CALL** runs a stored procedure, e.g. `CALL refresh_master_lei_country_count()`. PostgreSQL can't `PREPARE`
a CALL, so check 3 is skipped and errors are reported when it runs. It always asks for confirmation, then
runs outside an explicit transaction, so a procedure may `COMMIT` or `ROLLBACK` itself; otherwise its work
is committed when the CALL succeeds. OUT/INOUT values the procedure returns are not shown.

**CREATE**, **ALTER** and **DROP** (tables, columns, views, indexes, functions, schemas, databases, ...) can also be run. PostgreSQL
can't `PREPARE` them, so check 3 is skipped and errors are reported when the statement runs, psql style.
They always ask for confirmation first; DROP warns that it permanently deletes the objects and their data,
and ALTER that some changes (such as dropping a column) delete data.
The statement then runs as its own transaction, so one that fails leaves nothing behind; statements that
can't run inside a transaction block work too (CREATE / DROP DATABASE, CREATE INDEX CONCURRENTLY, ALTER SYSTEM). Run one
statement at a time. Afterwards the table list, the `\d` description and the **Database** drop-down are
refreshed; the open table is reloaded with its new columns, or closed if it was dropped or renamed.

Results stay **editable** when every column comes from one table and either:

- the result has the **table's full column layout**, as `SELECT * FROM table WHERE ...` (with any WHERE,
  ORDER BY or LIMIT) gives. Such a statement is run with each row's physical row ID (`ctid`) as well, so
  rows can be updated even when the table has **no primary key**, e.g.
  `SELECT * FROM public.avt_form_code WHERE legal_form_name_en ILIKE '%liability%'`; or
- the table's **primary key** is among the columns, e.g. `SELECT id, name FROM customers WHERE balance > 20`.

Anything else is read-only: a subset of columns without the key, joins, views, subqueries, expressions and
aggregates. Running the table's unchanged default statement reloads the whole table, with row IDs and an
exact row count. A row ID changes when the row is updated; the grid reloads after **Update…**, so it always
holds the current ones.

## SQL box: colours and size

The SQL box colours SQL as VS Code does (Light+ and Dark+ colours, following the system appearance):
keywords, data types (also after `::`), function calls, strings (including `E'...'` and `$$ ... $$`),
numbers, comments (`--` and nested `/* */`), "quoted identifiers" and `$1` parameters.

The bar between the SQL box and the grid can be **dragged** to give the SQL box more or less of the form's
height; **double-click** it to go back to the default. The height is remembered (for all windows) and is
limited so the grid always keeps its minimum rows and its buttons.

## SQL files

Right-click in the SQL box to save and recall `.sql` files. These items appear above the usual
Cut / Copy / Paste:

| Item | Does |
|------|------|
| **Run SQL** | Same as the Run SQL button (⌘↩) |
| **New SQL** | Empties the SQL box (not tied to a file) |
| **Open SQL File…** | Opens a `.sql` file into the SQL box |
| **Open Recent ▸** | The last 10 SQL files opened or saved; **Clear Menu** |
| **SQL Folder ▸** | Every `.sql` file in your SQL folder, to open with one click; **Show SQL Folder in Finder**; **Choose / Change SQL Folder…** |
| **Save SQL** / **Save SQL As…** | Saves the SQL box (UTF-8). Save and Open panels start in the SQL folder |
| **Revert to Saved** | Discards changes since the file was opened or saved |
| **Show in Finder** | Reveals the current file |

Under the SQL box, the current file's name is shown, with **— Edited** when it has unsaved changes. Opening
another file, **New SQL**, or opening a table (which puts that table's SELECT in the box) first asks whether
to save them. The SQL folder and recent files are remembered across launches for the whole app (as sandbox
bookmarks, see `MxDataSQL.entitlements`). The current file is per window and is not saved in the workspace.

## Viewing JSON cells

Right-click a cell that holds JSON (a `json` / `jsonb` column, or text that is a JSON object or array) and choose
**View JSON…**. A resizable sheet shows the value formatted like VS Code's **Format Document** (each member on
its own line, `"key": value`, empty `{}` / `[]` kept together; key order and number spellings unchanged) and
coloured with VS Code's JSON colours (Light+ / Dark+): property keys, string values, numbers and
`true` / `false` / `null`.

- The text can be edited; it is re-coloured as you type. **Format** re-indents it (2 or 4 spaces, remembered),
  and invalid JSON is reported with its line and column. **Copy** copies it.
- On editable grids, **Apply to Cell** checks the JSON and makes it the cell's pending edit (written to the table
  with **Update…**, like any other edit). Read-only results only show the JSON.
- `jsonb` values come back from PostgreSQL with its own key order (shorter keys first); `json` and text keep theirs.

## Sorting and filtering

Each column header has an Excel-style **▾** button. It opens a panel with:

- **Sort** ascending or descending ("A to Z", "Smallest to Largest" or "Oldest to Newest", by column type), and
  **Clear Sort**. The sorted column shows an arrow in its header.
- **Filter by Values**: a checklist of the column's distinct values with row counts, a search box, **(Select All)**
  and **(NULL)**. It honours the other columns' filters, as Excel does, and shows the first 1,000 values.
- **Filter by Condition**: equals, does not equal, contains, does not contain, begins with, ends with, greater /
  less than (or equal), between, is empty, is not empty. Text conditions ignore case; greater, less and between
  compare as the column's type (numbers as numbers, dates as dates).

Filtered columns show a funnel in their header. The line above the grid shows the sort and filters, e.g.
"Rows 1–28 of 28 (filtered from 40)", with **Clear Filters**. Right-click a header for **Clear Sort**,
**Clear All Filters** and **Reset Column Widths**.

Sorting and filtering run **on the server**, as a WHERE and ORDER BY on the grid's query, so they cover the
whole table or query, not just the loaded page. Paging, row counts and Export CSV (all rows) follow them.
Values are always sent as parameters.

- **Editing still works.** Rows are still identified by their key, so cells can be edited, pasted and updated
  as usual. After **Update…** the grid reloads with the same sorting, filters and page.
- Pending edits must be applied or discarded before changing the sort or a filter.
- Opening a table or running new SQL clears the sort and filters; Reload, paging and Update keep them.
- Not available on results of a statement that changed data (it would run again), or on a query column
  whose name appears twice (e.g. two `id` columns from a join).

## Selecting and copying cells

The grid selects cells like a spreadsheet:

- **Click** a cell; **shift-click** or **drag** to select a range; **arrow keys** move the selection
  (shift extends it) and **Tab** moves across. Click a **#** row number for the whole row, a **column header**
  for the whole column, or press **⌘A** for every cell on the page.
- **Copy** (⌘C, Edit ▸ Copy, or right-click ▸ Copy): one cell copies as its plain value; a range copies as
  tab-separated rows, so it pastes into Numbers or Excel as cells. NULL copies as an empty value.
  Right-click ▸ **Copy with Column Names** adds a header line.
- **Paste** (⌘V) puts the clipboard into the grid as pending edits, starting at the top-left selected cell; a
  single value fills every selected cell. Paste is **only enabled on editable grids**. On read-only results,
  such as joins, expressions and aggregates, it stays disabled because their cells do not map back to one table.
- **Edit** a cell in place with a double-click or **Return**. Right-click ▸ **Set to NULL** and **Revert**
  apply to every selected cell.

## Pages

The grid shows one page of rows. A page is **Rows to fetch** long (Table ▸ View…, default 1000). **Previous**
and **Next**, in the button row under the grid, load the page before or after. The header shows which rows
are on screen, e.g. "Rows 1,001–2,000 of 5,432", and the `#` column numbers rows across pages.

- **Previous** is disabled on the first page. **Next** is disabled on the last page. Each re-enables when you
  move to a page that has one before or after it.
- Opening a table or running new SQL starts at page 1. **Reload** and **Update…** reload the current page.
- Tables page in primary-key order (row ID order if there is no primary key). Custom SQL is paged with
  `OFFSET`/`LIMIT`, so give it an `ORDER BY` for stable pages.
- Pending edits must be applied or discarded before changing page.
- Results of a statement that changed data (e.g. `UPDATE … RETURNING`) are not paged: that would run it again.

## Export CSV

**Export CSV…** on the DB Table form (also **Table ▸ Export CSV…**, ⇧⌘E) saves the grid as a CSV file:
UTF-8, a header row of column names, comma-separated, with CRLF line ends (RFC 4180). A NULL is an empty
field and an empty string is `""`. Values containing commas, quotes or line breaks are quoted.

- **Loaded rows**: exactly what the grid shows, including edits you haven't applied yet.
- **All rows**: offered in the Save panel when the table or query has more rows than were fetched. The
  grid's query runs again, read-only, and is streamed to the file, so large tables do not need to fit in
  memory. It is not offered for results of a statement that changed data.

## Table windows

With **Open in New Window** checked on DB Table Selection, **Open Table** (or a double-click) opens the
table in a separate window. That window is the full DB Table form: SQL box and Run SQL, the editable grid,
Reload, View… and Update…. The **Table** menu acts on whichever window is in front.

- Each table window has **its own database connection**, so its transactions never mix with another window's.
  It keeps working if the workspace window is closed.
- Its view settings (rows, columns, fetch limit, column widths) start as a copy of the workspace's.
  **Column widths** you set in a table window are saved to the workspace while its window is open (save the
  workspace to keep them). Rows, columns and fetch limit changed in a table window apply to that window only.
- Table windows are not reopened when the app relaunches. The password is handed to them in memory only
  and is never written to window state.

## Schema diagrams (Diagram menu)

**Diagram ▸ Write DBML…** (⌥⌘D, while connected) writes the connected database's schema as
[DBML](https://dbml.dbdiagram.io), the text format read by dbdiagram.io and its VS Code extension. A Save panel asks
where; under it, tick the **schemas** to include (all user schemas with tables are ticked) and whether to **open the
diagram after writing**. The file has:

- every table with its columns (type, `pk`, `increment`, `not null`, `unique`, defaults) and the table and column
  comments as notes; tables in `public` unqualified, others as `schema.table`;
- indexes (expression indexes in backticks; GIN / GiST and partial indexes say so in a note); check and
  exclusion constraints as comments;
- every foreign key as a `Ref` (with its `ON DELETE` action), and one `TableGroup` per schema when there are several.

Writing over a diagram you have already arranged keeps its table positions, curves and notes.

**Diagram ▸ Open DBML…** (⌥⌘O) opens any `.dbml` file in a **Diagram window** (no connection needed). The diagram is
the shared DBML library (`Shared/DBML`), the same as MxNoteONE's DBML diagrams: they read the same files and look and
work the same.

- Tables are drawn with their columns and types (🔑 primary key, 🔗 foreign key; hover a column for its constraints and
  note); each schema has its own header colour and a dashed panel. Enums are drawn too. Relationships run from column
  to column, with a crow's foot at the "many" end and a bar at the "one" end. Tables are arranged by schema with
  related tables together; **Arrange** does it again.
- **Drag a table** to move it. Click a table to highlight its relationships; ⇧- or ⌘-click to select more tables, or
  click a schema panel's name to select all its tables — dragging one of them moves them all. Arrow keys nudge the
  selection, ⌘A selects every table.
- **Schemas** (right-click a table or a schema panel, or **Diagram ▸ Export Schema**): **Select Schema**,
  **Copy Schema** (its DBML with its layout, and a picture of it) and **Export Schema…** — the schema to a `.dbml`
  file of its own: its tables and enums as written (refs to tables in other schemas taken off), the relationships
  among them, its table group, and where they sit (with their curves and the notes over them).
- **Click a relationship** to select it, then choose its curve in the toolbar (or right-click it): **Automatic**,
  **Straight Line**, **Quadratic Bézier** (one control point) or **Cubic Bézier** (two). Bézier curves show their
  control points; **drag the round handles** to reshape the curve. Control points move with the tables. Delete
  sets a selected relationship back to Automatic. The right-click menu also chooses which **side** of each table a
  line leaves and meets, and its **colour**; **All Lines** draws every relationship one way.
- **Notes**: **Add Note** (toolbar or Diagram menu), or double-click empty canvas. Drag a note to move it, drag its
  corner to resize it, double-click it to edit; right-click for its colour, or ▸ Delete Note (or select it and press
  Delete). Sticky notes that came with the file (written by another tool) are shown in grey and are read-only.
- **Zoom** with the toolbar or Diagram ▸ Zoom In / Zoom Out / Actual Size (⌘+, ⌘−, ⌘0).
- **Save** (⌘S in the diagram window, or Diagram ▸ Save Diagram / Save Diagram As…) writes the notes and layout into the
  same `.dbml` file. Closing a diagram with unsaved changes asks first.

The layout lives at the end of the file, after a `// ===== MxDataSQL diagram …` line: the notes as standard DBML sticky
notes, and the positions and curves as one `// @mxdatasql-layout {…}` comment that other DBML tools ignore. The rest of
the file is never rewritten, so a hand-written DBML file keeps its enums, settings and comments.

## Quick Help

**View ▸ Quick Help** (⌥⌘/) shows a panel above the status bar, as in MxNoteONE, telling what's under the pointer in
a sentence or two, with its shortcut: a form's buttons and fields, the SQL box, a grid cell (its column's type,
nullability and default, its value or pending edit) or column header (and its sort and filter button), the table
list and the `\d` description. Over nothing it can describe, it tells about the selected cell or cells, the
highlighted table or the grid, and then the form or dialog in front. **View ▸ Float Quick Help** (or the panel's
float button) puts it in a small window of its own; closing that window docks it again. Both choices are
remembered. While it's docked, the window's minimum height grows by the panel's, so the forms keep their room.

## Menus

- **File**: New, Open, Save (plus the standard Save As, Duplicate, Revert and Open Recent). Files are workspaces.
- **View ▸ Quick Help** (⌥⌘/) and **Float / Dock Quick Help**.
- **Diagram ▸ Write DBML…** (⌥⌘D), **Open DBML…** (⌥⌘O), Save Diagram / Save Diagram As…, Add Note, Arrange Tables and
  zoom (see [Schema diagrams](#schema-diagrams-diagram-menu)).
- **Table ▸ View…** (⌥⌘L): columns fitted across the grid, rows guaranteed visible, and how many rows to fetch.
- **Table ▸ Update…** (⌥⌘U): the same dialog as the **Update…** button on the DB Table form. It:
  - lists every changed cell (old value → new value);
  - asks how to identify each row: the **primary key**, the **physical row ID** (`ctid`, used by default for tables with no primary key), or the **loaded values of columns you pick**;
  - has options to update a row only if the edited columns still hold the loaded values (optimistic check), to write empty cells as NULL, and to apply all rows in **one transaction** or row by row;
  - shows a preview of the SQL before you apply it.

## What a workspace saves

The connection parameters, the last opened table, the view settings and the column widths you set. The **password is not saved in
the file**. When "Save password in Keychain" is on, it is kept in the login Keychain under
`MxDataSQL: user@host:port/database` (service `com.k3jdr.MxDataSQL`). A password saved before the app was renamed
is moved there the first time its workspace needs it; macOS asks once to let MxDataSQL read it.

## How updates work

Every value is read as text (`col::text`) and written back with a parameterized, typed cast:

```sql
UPDATE "public"."customers"
SET "balance" = $1::text::numeric(10,2)
WHERE "id" = $2::text::integer
  AND "balance"::text IS NOT DISTINCT FROM $3   -- optimistic check
RETURNING 1
```

Each statement must affect exactly one row. If a row is missing, was changed by someone else, or the
chosen key matches more than one row, that row's transaction is rolled back. In one-transaction
mode, the whole batch is rolled back. After an update, the grid reloads from the database.

## Source layout

| File | Purpose |
|------|---------|
| `MxDataSQLApp.swift` | `DocumentGroup` and the **Table** menu |
| `WorkspaceDocument.swift` | Workspace file format (`FileDocument`, UTType `com.k3jdr.mxdatasql.workspace`) |
| `WorkspaceSession.swift` | Per-window live state (connection, table list, grid, pending edits) |
| `PostgresService.swift` | PostgresNIO connection, catalog queries, grid fetch, applying updates |
| `TableUpdate.swift` | Builds UPDATE statements from the pending edits |
| `DatabaseModels.swift` | Table, column and grid value types; psql-style `\d` formatting |
| `ConnectionForm.swift`, `TableSelectionForm.swift`, `TableGridForm.swift` | The three forms |
| `DataGridView.swift` | Editable `NSTableView` grid with always-visible scroll bars, cell selection, copy and paste, header filter buttons |
| `GridFilters.swift`, `ColumnFilterPopover.swift` | Sorting and filters: SQL for them, and the header panel |
| `ViewSettingsDialog.swift`, `UpdateDialog.swift` | Table ▸ View… and Table ▸ Update… |
| `TableWindow.swift` | Table opened with **Open in New Window** (own window and connection) |
| `CSVExport.swift` | Export CSV… (Save panel, CSV formatting) |
| `SQLTextView.swift` | Plain-text SQL editor (no smart quotes or autocorrect) with an extensible right-click menu |
| `JSONFormatter.swift`, `JSONViewer.swift` | View JSON…: formatting and colouring like VS Code, and the sheet |
| `SQLHighlighter.swift` | SQL syntax colouring (PostgreSQL-aware scanner, VS Code colours) |
| `SQLFiles.swift` | SQL files: folder and recent files (bookmarks), open / save / revert, the SQL box's right-click menu |
| `DBMLWriter.swift` | Diagram ▸ Write DBML: catalog query and DBML text |
| `../Shared/DBML/` | The DBML library shared with MxNoteONE: the parser, MxDataSQL's diagram section (notes and layout), layout and arranging, drawing and pictures, the diagram canvas (dragging, curves, notes, the Schema menu) |
| `DiagramModel.swift` | A Diagram window's state: the diagram, the selection, saving, Export Schema |
| `DiagramCanvas.swift`, `DiagramWindow.swift` | The shared canvas in the window (toolbar, status line, close prompt) |
| `DiagramCommands.swift` | The Diagram menu, the Write DBML Save panel and Open DBML |
| `SQLQuickHelp.swift` | What Quick Help says: the forms and dialogs, the selection, grid cells and column headers |
| `../Shared/QuickHelp/` | The Quick Help panel, shared with MxDataHUB and MxJobsMGR (the only part of `../Shared` this app compiles) |

The document type is declared in `Info.plist`, which is merged with the Info.plist that Xcode generates.
