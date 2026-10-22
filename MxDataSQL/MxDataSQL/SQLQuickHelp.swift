//
//  SQLQuickHelp.swift
//  MxDataSQL
//
//  What Quick Help (Shared/QuickHelp) says in MxDataSQL: the three forms and their dialogs, the table or
//  grid that's selected, and — like MxNoteONE's table cells — the grid cell or column header under the pointer.
//

import AppKit
import SwiftUI

enum SQLHelp {
    /// Height of Quick Help docked above the status bar; the window's minimum height grows by it.
    static let dockHeight: CGFloat = 106

    static var dockedHeight: CGFloat { QuickHelp.shared.isDocked ? dockHeight : 0 }

    // MARK: Screens

    /// The window's screen: its form, or the dialog open over it.
    static func screen(_ session: WorkspaceSession) -> (name: String, item: QuickHelpItem) {
        if session.showUpdateDialog { return ("Update", update) }
        if session.showViewDialog { return ("Table View", tableView) }
        let form = session.form
        if form != .connection, !session.isConnected {
            return (form.rawValue, QuickHelpItem(title: "\(form.rawValue): Not Connected",
                                                 detail: "Connect in the DB Connection form first: \(form == .table ? "the grid shows" : "the list shows") the tables of the database you connect to.",
                                                 symbol: "cable.connector.slash"))
        }
        return (form.rawValue, about(form))
    }

    static func about(_ form: WorkspaceForm) -> QuickHelpItem {
        switch form {
        case .connection:
            return QuickHelpItem(title: "DB Connection",
                                 detail: "The PostgreSQL server this workspace works with: host, port, user, database, password and SSL mode. "
                                    + "The fields are saved in the workspace file; the password isn't — Save password in Keychain keeps it in your Keychain. "
                                    + "Connect (↩) lists the tables in DB Table Selection; once connected, the Database drop-down above switches databases.",
                                 symbol: "cylinder.split.1x2")
        case .tableSelection:
            return QuickHelpItem(title: "DB Table Selection",
                                 detail: "The database's tables with their rows (~ means estimated from the planner's statistics, until Count Rows) and sizes, "
                                    + "then its views, functions and procedures. Select a table or view for its \\d description on the right — columns, keys, indexes, "
                                    + "references, a view's definition; double-click it or Open Table (↩) to open it in DB Table, or in a window of its own with "
                                    + "Open in New Window (views open read-only). Select a function or procedure for its code.",
                                 symbol: "list.bullet.rectangle")
        case .table:
            return QuickHelpItem(title: "DB Table",
                                 detail: "An SQL box over the rows in a grid. The box holds the statement that loaded the grid: change it and Run SQL (⌘↩); queries run read-only, "
                                    + "statements that change data ask before they run. Edit cells in the grid, then Update… (⌥⌘U) writes them. "
                                    + "Previous / Next page through the rows; View… (⌥⌘L) sets how many show; Export CSV… (⇧⌘E) saves them.",
                                 symbol: "tablecells")
        }
    }

    /// A table window ("Open in New Window"): the DB Table form on its own.
    static func tableWindowScreen(_ session: WorkspaceSession) -> (name: String, item: QuickHelpItem) {
        if session.showUpdateDialog { return ("Update", update) }
        if session.showViewDialog { return ("Table View", tableView) }
        var item = about(.table)
        item.detail += "\nThis window has its own connection, so its transactions never mix with the workspace's."
        return ("DB Table", item)
    }

    static let tableView = QuickHelpItem(title: "Table View",
                                         detail: "How many rows and columns the grid shows (the window sizes itself to fit them) and how many rows are fetched per page. "
                                            + "Changing the fetch limit reloads the table and discards pending edits.",
                                         shortcut: "⌥⌘L", symbol: "rectangle.split.3x3")

    static let update = QuickHelpItem(title: "Update",
                                      detail: "The pending edits, old and new values. Each row is found by its primary key, by its physical row ID (ctid, whole-table loads), "
                                        + "or by the loaded values of columns you choose. Options: only update rows whose edited columns still hold the loaded values, "
                                        + "write empty cells as NULL, and all rows in one transaction. Apply Updates writes them; Discard Edits drops them.",
                                      shortcut: "⌥⌘U", symbol: "square.and.pencil")

    /// What's selected: the highlighted table, or the grid's table or query.
    static func selection(_ session: WorkspaceSession) -> QuickHelpItem? {
        guard session.isConnected else { return nil }
        switch session.form {
        case .tableSelection:
            if let r = session.highlightedEntry?.routine {
                return QuickHelpItem(title: r.displayName,
                                     detail: r.facts + " Its code is on the right"
                                        + (r.isProcedure ? "; run it with CALL in DB Table's SQL box." : "."),
                                     symbol: r.isProcedure ? "gearshape" : "function")
            }
            guard let t = session.highlightedEntry?.table else { return nil }
            if t.isView {
                let rows = t.exactRows.map { "\($0.formatted()) rows" }
                    ?? (t.isPlainView ? "rows not counted yet" : "about \(t.displayRows.formatted()) rows")
                let size = t.totalSize.isEmpty ? "" : ", \(t.totalSize)"
                return QuickHelpItem(title: "\(t.schema).\(t.name)",
                                     detail: "\(t.kind.prefix(1).uppercased() + t.kind.dropFirst()), \(rows)\(size). Its columns and definition are on the right; "
                                        + "double-click or Open View (↩) opens its rows, read-only.",
                                     symbol: t.isPlainView ? "eye" : "square.stack.3d.up")
            }
            let rows = (t.exactRows == nil ? "about " : "") + t.displayRows.formatted() + " rows"
            let key = session.highlightedDescription.map { $0.primaryKey.isEmpty ? " No primary key." : " Key: \($0.primaryKey.joined(separator: ", "))." } ?? ""
            return QuickHelpItem(title: "\(t.schema).\(t.name)",
                                 detail: "\(t.kind.prefix(1).uppercased() + t.kind.dropFirst()), \(rows), \(t.totalSize).\(key) Its description is on the right; double-click or Open Table (↩) opens it.",
                                 symbol: "tablecells")
        case .table:
            guard let grid = session.grid else { return nil }
            var facts = ["\(grid.rows.count.formatted()) rows loaded", "\(grid.columns.count) columns"]
            if !session.edits.isEmpty { facts.append("\(session.edits.count) pending edit\(session.edits.count == 1 ? "" : "s") — Update… writes them") }
            return QuickHelpItem(title: grid.title,
                                 detail: facts.joined(separator: " · ") + ".\n"
                                    + (grid.isEditable ? "Editable: double-click a cell or press Return to change it."
                                       : grid.description?.summary.isView == true ? "Read-only: a view's rows change with the tables it reads from."
                                       : "Read-only: query one table with SELECT * (any WHERE / ORDER BY), or include its primary key columns, to edit rows."),
                                 symbol: "tablecells")
        case .connection:
            return nil
        }
    }

    // MARK: Areas

    static let sqlBox = QuickHelpItem(title: "SQL Box",
                                      detail: "SQL to run against the database, coloured as you type. Run SQL (⌘↩) runs it: a query fills the grid, read-only; INSERT, UPDATE, DELETE, "
                                        + "CREATE, ALTER, DROP and CALL ask before they run and commit. Right-click to open or save .sql files.",
                                      shortcut: "⌘↩", symbol: "chevron.left.forwardslash.chevron.right")

    static let resizeBar = QuickHelpItem(title: "Resize Bar", detail: "Drag to give the SQL box more or less room; double-click to reset it.", symbol: "arrow.up.and.down")

    static let tableList = QuickHelpItem(title: "Tables, Views, Functions and Procedures",
                                         detail: "The tables (partitioned ones too) by schema with their rows and size, then the views (materialized ones too), then the functions "
                                            + "and procedures with their arguments (not aggregates, nor the functions extensions install). Select a table or view for its "
                                            + "description, a function or procedure for its code; double-click a table or view to open it.",
                                         symbol: "list.bullet")

    static let describe = QuickHelpItem(title: "Description",
                                        detail: "The highlighted table as psql's \\d shows it: columns with types, collation, nullability and defaults, then indexes, checks, foreign keys and the tables that reference it. "
                                            + "For a view, its columns and its definition (psql's \\d+), coloured like the SQL box. Select text to copy it.",
                                        symbol: "doc.plaintext")

    static let routineCode = QuickHelpItem(title: "Code",
                                           detail: "The highlighted function or procedure as psql's \\sf shows it: its CREATE OR REPLACE statement, coloured like the SQL box. "
                                            + "Select text to copy it; paste it in DB Table's SQL box to change the function.",
                                           symbol: "function")

    // MARK: Grid cells and headers (AppKit)

    /// Lets Quick Help describe the grid's cells and column headers; called when a window appears.
    static func install() {
        let help = QuickHelp.shared
        guard help.describeView == nil else { return }
        help.describeView = { view, point in
            switch view {
            case let table as GridTableView: table.quickHelp(at: point)
            case let header as GridHeaderView: header.quickHelp(at: point)
            default: nil
            }
        }
        help.describeFocus = { responder in
            (responder as? GridTableView)?.quickHelpForSelection()
        }
    }

    fileprivate static func columnFacts(_ column: ColumnInfo) -> String {
        var facts = [column.type]
        if column.notNull { facts.append("not null") }
        if !column.defaultExpr.isEmpty { facts.append("default \(column.defaultExpr)") }
        if !column.collation.isEmpty { facts.append("collation \(column.collation)") }
        if column.attnum == 0 { facts.append("computed by the query") }
        return facts.joined(separator: ", ")
    }

    fileprivate static func preview(_ value: String?) -> String {
        guard let value else { return "NULL" }
        if value.isEmpty { return "empty" }
        let line = value.replacingOccurrences(of: "\n", with: " ")
        return "“" + (line.count > 80 ? String(line.prefix(80)) + "…" : line) + "”"
    }
}

extension GridTableView {
    /// The cell (or row number) under the pointer, in words.
    func quickHelp(at point: NSPoint) -> QuickHelpItem? {
        guard let session = coordinator?.session, let grid = session.grid else { return nil }
        let row = row(at: point), tableColumn = column(at: point)
        guard row >= 0, row < grid.rows.count, tableColumn >= 0 else { return nil }
        if tableColumn == 0 {
            return QuickHelpItem(title: "Row \((grid.offset + row + 1).formatted())",
                                 detail: "Click to select the whole row, shift-click to extend; ⌘C copies it as tab-separated values.",
                                 symbol: "number")
        }
        return describe(CellKey(row: row, column: tableColumn - 1), in: grid, session: session)
    }

    /// The selected cell or cells.
    func quickHelpForSelection() -> QuickHelpItem? {
        guard let session = coordinator?.session, let grid = session.grid, let selection = coordinator?.selection else { return nil }
        if selection.anchor != selection.cursor {
            let count = selection.rows.count * selection.columns.count
            return QuickHelpItem(title: "\(count.formatted()) cells selected",
                                 detail: "⌘C copies them (Copy with Column Names from the right-click menu adds a header)"
                                    + (grid.isEditable ? "; ⌘V pastes over them, Delete clears them as pending edits." : "."),
                                 symbol: "tablecells")
        }
        return describe(selection.cursor, in: grid, session: session)
    }

    private func describe(_ key: CellKey, in grid: GridData, session: WorkspaceSession) -> QuickHelpItem? {
        guard grid.columns.indices.contains(key.column), grid.rows.indices.contains(key.row) else { return nil }
        let column = grid.columns[key.column]
        var facts = ["Row \((grid.offset + key.row + 1).formatted())", SQLHelp.columnFacts(column)]
        if let edit = session.edits[key] {
            facts.append("edited: \(SQLHelp.preview(grid.rows[key.row][key.column])) → \(SQLHelp.preview(edit.value)) (Update… writes it)")
        } else {
            facts.append(SQLHelp.preview(grid.rows[key.row][key.column]))
        }
        let how = grid.isEditable
            ? "Double-click or Return to edit; right-click for View JSON…, Copy, Paste, Set to NULL and Revert."
            : "Read-only result: ⌘C copies; right-click for View JSON…."
        return QuickHelpItem(title: column.name, detail: facts.joined(separator: " · ") + ".\n" + how, symbol: "tablecell")
    }
}

extension GridHeaderView {
    /// The column header under the pointer, or its sort and filter button.
    func quickHelp(at point: NSPoint) -> QuickHelpItem? {
        guard let session = coordinator?.session, let grid = session.grid, let tableView else { return nil }
        let index = column(at: point)
        guard index > 0, grid.columns.indices.contains(index - 1) else {
            return index == 0 ? QuickHelpItem(title: "Row Numbers", detail: "Click a row number to select the row.", symbol: "number") : nil
        }
        let column = grid.columns[index - 1]
        if let cell = tableView.tableColumns[index].headerCell as? GridHeaderCell, cell.showsFilterButton,
           cell.buttonRect(forBounds: headerRect(ofColumn: index)).insetBy(dx: -2, dy: 0).contains(point) {
            return QuickHelpItem(title: "Sort & Filter \(column.name)",
                                 detail: "Sort ascending or descending, or filter by values (a checklist with counts) or by a condition, as in Excel. "
                                    + "The database does the sorting and filtering, so it covers every row, not just this page.",
                                 symbol: "line.3.horizontal.decrease.circle")
        }
        var detail = SQLHelp.columnFacts(column) + "."
        if grid.description?.primaryKey.contains(column.name) == true { detail += " Part of the primary key." }
        if let sort = grid.options.sort, sort.column == column.name { detail += " The rows are sorted by it, \(sort.ascending ? "ascending" : "descending")." }
        if grid.options.filters[column.name] != nil { detail += " Filtered." }
        detail += "\nClick to select the column; drag its edge to resize it (the width is saved in the workspace)."
        return QuickHelpItem(title: column.name, detail: detail, symbol: "tablecells")
    }
}
