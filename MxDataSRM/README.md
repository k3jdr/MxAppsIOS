# MxDataSRM

A macOS app (SwiftUI and AppKit) for browsing and editing PostgreSQL tables. Each
document is a **workspace** (`*.mxworkspace`, a small JSON file).

Open `MxDataSRM.xcodeproj` in Xcode, then Run. The PostgresNIO Swift package is fetched automatically.

## Workspace forms

| Form | What it does |
|------|--------------|
| **DB Connection** | Host, port, user, database, password, SSL mode (`disable` / `prefer` / `require`, with no certificate verification, like libpq). |
| **DB Table Selection** | Lists tables with a row count (`~` = planner estimate; **Count Rows** replaces it with `count(*)`) and size. The panel on the right shows a psql `\d` style description: columns, indexes, check constraints, foreign keys and "referenced by". Double-click a table or press **Open Table** to load it. |
| **DB Table** | Editable grid that fills the form and resizes with the window. *Columns* (default **3**) are sized to span its width, except columns you resize by dragging, which keep their width (saved per table in the workspace; right-click the header ▸ **Reset Column Widths** to undo); *rows* (default **10**) set its minimum height. Scroll bars reach the rest of the fetched rows (default 1000). Edited cells are highlighted until you run **Update…**. Right-click a cell to set it to NULL or revert it. |

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
| `DataGridView.swift` | Editable `NSTableView` grid with always-visible scroll bars |
| `ViewSettingsDialog.swift`, `UpdateDialog.swift` | Table ▸ View… and Table ▸ Update… |

The document type is declared in `Info.plist`, which is merged with the Info.plist that Xcode generates.
