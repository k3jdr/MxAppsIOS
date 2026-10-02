# MxDataSRM

A macOS app (SwiftUI and AppKit) for browsing and editing PostgreSQL tables. Each
document is a **workspace** (`*.mxworkspace`, a small JSON file).

Open `MxDataSRM.xcodeproj` in Xcode, then Run. The PostgresNIO Swift package is fetched automatically.

## Workspace forms

| Form | What it does |
|------|--------------|
| **DB Connection** | Host, port, user, database, password, SSL mode (`disable` / `prefer` / `require`, with no certificate verification, like libpq). |
| **DB Table Selection** | Lists tables with a row count (`~` = planner estimate; **Count Rows** replaces it with `count(*)`) and size. The panel on the right shows a psql `\d` style description: columns, indexes, check constraints, foreign keys and "referenced by". Double-click a table or press **Open Table** to load it. With **Open in New Window** checked, the table opens in its own window instead (see below). |
| **DB Table** | SQL box with **Run SQL** (see below) above an editable grid that fills the form and resizes with the window. *Columns* (default **3**) are sized to span its width, except columns you resize by dragging, which keep their width (saved per table in the workspace; right-click the header ▸ **Reset Column Widths** to undo); *rows* (default **10**) set its minimum height. Scroll bars reach the rest of the fetched rows (default 1000). Edited cells are highlighted until you run **Update…**. Cells can be selected and copied (see **Selecting and copying cells**). |

## Run SQL

Above the grid on the DB Table form is an SQL box. Opening a table fills it with the statement that loads
the grid, e.g. `SELECT * FROM public.customers ORDER BY id`. Edit it and click **Run SQL** (⌘↩).
The grid then shows the results, up to the **Rows to fetch** limit (default 1000; Table ▸ View…).

Pre-flight checks run before anything executes. Problems are shown in red above the SQL box, psql style,
with the line and a caret under the error position:

1. The statement is not empty and is a SELECT, WITH, VALUES, TABLE, INSERT, UPDATE, DELETE or MERGE.
   DDL and transaction commands are refused.
2. There are no pending grid edits, which the new results would replace.
3. The server parses and analyses the statement with `PREPARE` without running it. This catches syntax
   errors, unknown tables or columns, several statements, and `$1` parameters.

Queries run in a **read-only transaction**. A statement that changes data, whether it is an
INSERT/UPDATE/DELETE or a query that writes, asks for confirmation first. It then runs in its own
transaction and is committed if it succeeds. After a write without `RETURNING`, the opened table is reloaded.

Results stay **editable** when every column comes from one table and its primary key is included, e.g.
`SELECT id, name FROM customers WHERE balance > 20`. Joins, expressions and aggregates give a read-only
grid. Running the table's unchanged default statement reloads the whole table, with row IDs and an
exact row count.

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

## Menus

- **File**: New, Open, Save (plus the standard Save As, Duplicate, Revert and Open Recent). Files are workspaces.
- **Table ▸ View…** (⌥⌘L): columns fitted across the grid, rows guaranteed visible, and how many rows to fetch.
- **Table ▸ Update…** (⌥⌘U): the same dialog as the **Update…** button on the DB Table form. It:
  - lists every changed cell (old value → new value);
  - asks how to identify each row: the **primary key**, the **physical row ID** (`ctid`, used by default for tables with no primary key), or the **loaded values of columns you pick**;
  - has options to update a row only if the edited columns still hold the loaded values (optimistic check), to write empty cells as NULL, and to apply all rows in **one transaction** or row by row;
  - shows a preview of the SQL before you apply it.

## What a workspace saves

The connection parameters, the last opened table, the view settings and the column widths you set. The **password is not saved in
the file**. When "Save password in Keychain" is on, it is kept in the login Keychain under
`MxDataSRM: user@host:port/database`.

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
| `MxDataSRMApp.swift` | `DocumentGroup` and the **Table** menu |
| `WorkspaceDocument.swift` | Workspace file format (`FileDocument`, UTType `com.k3jdr.mxdatasrm.workspace`) |
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
| `SQLTextView.swift` | Plain-text SQL editor (no smart quotes or autocorrect) |

The document type is declared in `Info.plist`, which is merged with the Info.plist that Xcode generates.
