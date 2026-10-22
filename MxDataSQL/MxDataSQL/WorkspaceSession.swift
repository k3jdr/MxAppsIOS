//
//  WorkspaceSession.swift
//  MxDataSQL
//
//  Live, unsaved state of one workspace window: the open connection, the
//  table list, the loaded grid and its pending edits. What should survive
//  a save (connection parameters, selected table, view settings) lives in
//  the WorkspaceDocument instead.
//

import SwiftUI

enum WorkspaceForm: String, CaseIterable, Identifiable {
    case connection = "DB Connection"
    case tableSelection = "DB Table Selection"
    case table = "DB Table"
    var id: String { rawValue }
}

enum ConnectionStatus: Equatable {
    case disconnected
    case connecting
    case connected(serverVersion: String)
    case failed(String)
}

@Observable
final class WorkspaceSession {
    var form: WorkspaceForm = .connection
    var password = ""
    var status: ConnectionStatus = .disconnected

    /// Tables, views and materialized views (TableSummary.isView).
    var tables: [TableSummary] = []
    /// Functions and procedures, listed after the tables and views in DB Table Selection.
    var routines: [RoutineSummary] = []
    /// Databases on the connected server (for the Database picker); the connected one is `connectedDatabase`.
    var databases: [String] = []
    private(set) var connectedDatabase: String?
    var tableFilter = ""
    /// DB Table Selection lists everything, or only the tables, views, functions or procedures.
    var catalogKind: CatalogKind = .all
    /// The highlighted table's or routine's CatalogEntry.id.
    var highlightedID: CatalogEntry.ID?
    var highlightedDescription: TableDescription?
    /// The highlighted function's or procedure's code; nil once a table is described.
    var highlightedRoutine: RoutineDefinition?
    var countingRows = false
    /// DB Table Selection: open tables in their own window instead of the DB Table form.
    var openInNewWindow = false

    var grid: GridData?
    /// Excel-style sorting and filters of the loaded grid (applied on the server). Kept by
    /// paging, Reload and Update; cleared when a table is opened or new SQL is run.
    var gridOptions: GridQueryOptions { grid?.options ?? GridQueryOptions() }
    var edits: [CellKey: CellEdit] = [:]
    /// Bumped whenever `grid` is replaced or edits are discarded, so the grid view reloads.
    private(set) var gridVersion = 0

    var busy = false
    var errorMessage: String?
    var infoMessage: String?

    var showViewDialog = false
    var showUpdateDialog = false

    /// Contents of the SQL box above the grid.
    var sqlText = ""
    /// The .sql file the SQL box was opened from or saved to (see SQLFiles.swift).
    var sqlFileURL: URL?
    /// The SQL box's text when it was last opened or saved, to tell whether it has been edited.
    var sqlSavedText: String?
    /// Pre-flight or execution error for the SQL box, shown in red above it.
    var sqlError: String?
    /// A statement that changes data, waiting for the user to confirm it.
    var pendingWriteSQL: String?
    var runningSQL = false
    /// Table last opened from DB Table Selection. Running its unchanged default SQL
    /// reloads it as a whole table (editable, with row IDs and an exact row count).
    private(set) var openedTable: TableDescription?

    private var service: PostgresService?
    /// The open connection, for features in other files (CSV export).
    var currentService: PostgresService? { service }

    var isConnected: Bool {
        if case .connected = status { true } else { false }
    }

    /// The list's rows: tables, views, functions, then procedures, of the chosen kind and whose
    /// schema.name contains the filter.
    var filteredEntries: [CatalogEntry] {
        let shownTables = catalogKind == .all || catalogKind == .tables ? tables.filter { !$0.isView } : []
        let shownViews = catalogKind == .all || catalogKind == .views ? tables.filter(\.isView) : []
        let shownRoutines = routines.filter { r in
            switch catalogKind {
            case .all: true
            case .tables, .views: false
            case .functions: !r.isProcedure
            case .procedures: r.isProcedure
            }
        }
        let entries = (shownTables + shownViews).map(CatalogEntry.table) + shownRoutines.map(CatalogEntry.routine)
        let filter = tableFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !filter.isEmpty else { return entries }
        return entries.filter { entry in
            let name = entry.routine.map { "\($0.schema).\($0.name)" } ?? "\(entry.schema).\(entry.name)"
            return name.lowercased().contains(filter)
        }
    }

    var highlightedEntry: CatalogEntry? {
        if let table = tables.first(where: { $0.id == highlightedID }) { return .table(table) }
        return routines.first { $0.id == highlightedID }.map(CatalogEntry.routine)
    }

    /// The id, in the reloaded list, of the entry whose CatalogEntry.key is `key`.
    private func entryID(forKey key: String?) -> CatalogEntry.ID? {
        guard let key else { return nil }
        return (tables.map(CatalogEntry.table) + routines.map(CatalogEntry.routine)).first { $0.key == key }?.id
    }

    // MARK: Connection

    func loadSavedPassword(for settings: ConnectionSettings) {
        if password.isEmpty, settings.savePasswordInKeychain,
           let saved = Keychain.password(for: settings.keychainAccount) {
            password = saved
        }
    }

    func connect(_ settings: ConnectionSettings) async {
        await disconnect()
        status = .connecting
        do {
            let service = try await PostgresService.connect(settings, password: password)
            self.service = service
            status = .connected(serverVersion: try await service.serverVersion())
            if settings.savePasswordInKeychain, !password.isEmpty {
                Keychain.setPassword(password, for: settings.keychainAccount)
            }
            connectedDatabase = settings.database
            let list = (try? await service.databases()) ?? []
            databases = list.contains(settings.database) ? list : (list + [settings.database]).sorted()
            await refreshTables()
        } catch {
            status = .failed(DatabaseError.from(error).message)
        }
    }

    func disconnect() async {
        if let service { await service.close() }
        service = nil
        status = .disconnected
        connectedDatabase = nil
        tables = []
        routines = []
        highlightedDescription = nil
        highlightedRoutine = nil
        grid = nil
        edits = [:]
        gridVersion += 1
        openedTable = nil
        sqlError = nil
    }

    /// Connects to another database on the same server with the same user and password, then
    /// refreshes the table list and the highlighted entry's description (the same schema.table or
    /// function when the new database has it, else the first table). On failure the previous
    /// database is reconnected. Returns whether the switch happened.
    func switchDatabase(to name: String, settings: ConnectionSettings) async -> Bool {
        guard isConnected, name != connectedDatabase else { return false }
        if !edits.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Discard \(edits.count) pending edit\(edits.count == 1 ? "" : "s")?"
            alert.informativeText = "Switching to database \(name) closes the open table, and edits not applied with Update… are lost."
            alert.addButton(withTitle: "Switch Database")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }
        let previous = highlightedEntry?.key
        var target = settings
        target.database = name
        await connect(target)
        guard isConnected else {
            let reason: String
            if case .failed(let message) = status { reason = message } else { reason = "unknown error" }
            await connect(settings)
            highlightedID = entryID(forKey: previous) ?? tables.first?.id
            await describeHighlighted()
            errorMessage = "Could not connect to database \(name).\n\n\(reason)"
            return false
        }
        highlightedDescription = nil
        highlightedRoutine = nil
        highlightedID = entryID(forKey: previous) ?? tables.first?.id
        await describeHighlighted()
        infoMessage = "Switched to database \(name)."
        return true
    }

    // MARK: DB Table Selection

    /// Lists the tables, views, functions and procedures again.
    func refreshTables() async {
        guard let service else { return }
        await run {
            let counted = Dictionary(uniqueKeysWithValues: self.tables.compactMap { t in t.exactRows.map { (t.oid, $0) } })
            self.tables = try await service.listTables().map { t in
                var t = t
                t.exactRows = counted[t.oid]
                return t
            }
            // Servers before PostgreSQL 11 (no pg_proc.prokind) list tables only.
            self.routines = (try? await service.listRoutines()) ?? []
        }
    }

    /// Loads the right panel: the highlighted table's or view's \d description, or the function's or procedure's code.
    func describeHighlighted() async {
        guard let service, let entry = highlightedEntry else {
            highlightedDescription = nil
            highlightedRoutine = nil
            return
        }
        await run {
            switch entry {
            case .table(let summary):
                let description = try await service.describe(summary)
                // A slower load must not replace the entry clicked after it.
                guard self.highlightedID == entry.id else { return }
                self.highlightedDescription = description
                self.highlightedRoutine = nil
            case .routine(let routine):
                let code = try await service.routineCode(routine)
                    ?? "-- \(routine.displayName) no longer exists; Refresh lists the database's functions again.\n"
                guard self.highlightedID == entry.id else { return }
                let sqlBody = ["sql", "plpgsql"].contains(routine.language)
                self.highlightedRoutine = RoutineDefinition(summary: routine, code: code,
                                                            colored: SQLHighlighter.attributed(code, sqlBodies: sqlBody))
                self.highlightedDescription = nil
            }
        }
    }

    /// Replaces the estimates in the table list with exact count(*) values.
    func countAllRows() async {
        guard let service else { return }
        countingRows = true
        defer { countingRows = false }
        // A view runs its whole query to be counted; it is counted when opened instead.
        for index in tables.indices where !tables[index].isPlainView {
            do {
                tables[index].exactRows = try await service.exactRowCount(tables[index].ref)
            } catch {
                errorMessage = "\(tables[index].ref.displayName): \(DatabaseError.from(error).message)"
                return
            }
        }
    }

    // MARK: DB Table

    /// Loads the table into the grid, one page of `limit` rows from `offset`.
    /// `resetSQL` puts the table's default SELECT in the SQL box.
    func openTable(_ ref: TableRef, limit: Int, offset: Int = 0, resetSQL: Bool = true,
                   options: GridQueryOptions? = nil) async {
        guard let service else { return }
        // Opening a table replaces the SQL box; offer to save unsaved changes to its file first.
        if resetSQL && !confirmReplacingSQL() { return }
        if tables.isEmpty { await refreshTables() }
        guard let summary = tables.first(where: { $0.ref == ref }) else {
            errorMessage = "Table \(ref.displayName) was not found."
            return
        }
        await run {
            let description = try await service.describe(summary)
            let options = options ?? (resetSQL ? GridQueryOptions() : self.gridOptions)
            self.setGrid(try await service.fetchGrid(description, limit: limit, offset: offset, options: options))
            self.openedTable = description
            self.infoMessage = nil
            if resetSQL {
                self.sqlText = description.defaultSQL
                self.sqlFileURL = nil
                self.sqlSavedText = nil
                self.sqlError = nil
            }
            self.form = .table
        }
    }

    /// Loads the current page again.
    func reloadGrid(limit: Int) async {
        let offset = grid?.offset ?? 0
        if let sql = grid?.customSQL {
            await runSQL(sql, limit: limit, offset: offset)
        } else if let ref = grid?.ref {
            await openTable(ref, limit: limit, offset: offset, resetSQL: false)
        }
    }

    /// Next or Previous: loads the neighbouring page of `limit` rows (View ▸ Rows to fetch).
    func showPage(next: Bool, limit: Int) async {
        guard let grid, next ? grid.hasNextPage : grid.hasPreviousPage else { return }
        guard edits.isEmpty else {
            errorMessage = "\(edits.count) pending edit\(edits.count == 1 ? "" : "s") on this page. Apply with Update… or use Discard Edits before changing page."
            return
        }
        let offset = next ? grid.offset + grid.rows.count : max(0, grid.offset - limit)
        if let sql = grid.customSQL {
            await runSQL(sql, limit: limit, offset: offset)
        } else if let ref = grid.ref {
            await openTable(ref, limit: limit, offset: offset, resetSQL: false)
        }
    }

    /// Applies new sorting / filters to the grid and reloads it from its first page.
    func applyGridOptions(_ options: GridQueryOptions, limit: Int) async {
        guard let grid, options != gridOptions else { return }
        guard edits.isEmpty else {
            errorMessage = "\(edits.count) pending edit\(edits.count == 1 ? "" : "s"). Apply with Update… or use Discard Edits before sorting or filtering."
            return
        }
        if let sql = grid.customSQL {
            await runSQL(sql, limit: limit, offset: 0, options: options)
        } else if let ref = grid.ref {
            await openTable(ref, limit: limit, offset: 0, resetSQL: false, options: options)
        }
    }

    /// Distinct values of a grid column for its filter checklist (other columns' filters applied).
    func distinctValues(column index: Int) async throws -> (values: [DistinctValue], truncated: Bool) {
        guard let service, let grid, let source = grid.source, grid.columns.indices.contains(index) else {
            return ([], false)
        }
        return try await service.distinctValues(source: source, column: grid.columns[index].name,
                                                columns: grid.columns, options: gridOptions)
    }

    private func setGrid(_ data: GridData) {
        grid = data
        edits = [:]
        gridVersion += 1
        if let total = data.totalRows, let index = tables.firstIndex(where: { $0.ref == data.ref }) {
            tables[index].exactRows = total
        }
    }

    /// Records an edit from the grid; editing a cell back to its loaded value removes the edit.
    func setCell(row: Int, column: Int, to value: String?) {
        guard let grid, grid.rows.indices.contains(row), grid.rows[row].indices.contains(column) else { return }
        let key = CellKey(row: row, column: column)
        if grid.rows[row][column] == value {
            edits[key] = nil
        } else {
            edits[key] = CellEdit(value: value)
        }
    }

    func discardEdits() {
        edits = [:]
        gridVersion += 1
    }

    func applyUpdates(options: UpdateOptions, limit: Int) async -> Bool {
        guard let service, let grid, let table = grid.ref else { return false }
        var ran = false
        var succeeded = false
        var message: String?
        await run {
            let planned = try planUpdates(grid: grid, edits: self.edits, options: options)
            let outcome = try await service.apply(planned, singleTransaction: options.singleTransaction)
            ran = true
            if outcome.failures.isEmpty {
                message = "Updated \(outcome.applied) row\(outcome.applied == 1 ? "" : "s") in \(table.displayName)."
                succeeded = true
            } else {
                self.errorMessage = "Updated \(outcome.applied) of \(planned.count) rows.\n\n"
                    + outcome.failures.joined(separator: "\n")
            }
        }
        if ran {
            // Show the rows as they are now: reload the table, or re-run the query that loaded the grid.
            edits = [:]
            await reloadGrid(limit: limit)
            if let message { infoMessage = message }
        }
        return succeeded
    }

    // MARK: Run SQL

    /// Pre-flights and runs `sql` (default: the SQL box), then shows its rows in the grid.
    /// Statements that change data wait in `pendingWriteSQL` until the user confirms.
    func runSQL(_ sql: String? = nil, limit: Int, offset: Int = 0, confirmedWrite: Bool = false,
                options: GridQueryOptions? = nil) async {
        // New SQL from the box, or a confirmed write, starts without sorting and filters.
        let options = options ?? ((sql == nil || confirmedWrite) ? GridQueryOptions() : gridOptions)
        let sql = Self.statementBody(sql ?? sqlText)
        sqlError = nil
        infoMessage = nil
        guard let service else {
            sqlError = "Not connected. Connect in the DB Connection form first."
            return
        }
        if let problem = Self.localPreflight(sql) {
            sqlError = problem
            return
        }
        if !edits.isEmpty {
            sqlError = "\(edits.count) pending edit\(edits.count == 1 ? "" : "s") in the grid. Apply with Update… or use Discard Edits before running SQL."
            return
        }
        if let table = openedTable, Self.normalized(sql) == Self.normalized(table.defaultSQL) {
            await openTable(table.summary.ref, limit: limit, offset: offset, resetSQL: false, options: options)
            return
        }

        runningSQL = true
        defer { runningSQL = false }
        do {
            // PREPARE can't take a CALL, so a CALL skips the server pre-flight; like any write it
            // waits for confirmation, then runs as sent (errors still come back psql style).
            if Self.isCall(sql) {
                guard confirmedWrite else {
                    pendingWriteSQL = sql
                    return
                }
                try await service.call(sql)
                infoMessage = "Procedure executed."
                if let table = openedTable {
                    await openTable(table.summary.ref, limit: limit, resetSQL: false)
                }
                return
            }
            // PREPARE can't take CREATE, ALTER or DROP either: confirm, run the statement as its own
            // transaction, then refresh what may have changed (tables, databases, the open table).
            if Self.isDDL(sql) {
                guard confirmedWrite else {
                    pendingWriteSQL = sql
                    return
                }
                try await service.runDDL(sql)
                let keyword = (Self.leadingKeyword(sql) ?? "").uppercased()
                await afterSchemaChange(limit: limit)
                infoMessage = "\(keyword) statement completed."
                return
            }
            let preflight = try await service.preflight(sql)
            guard preflight.returnsRows else {
                guard confirmedWrite else {
                    pendingWriteSQL = sql
                    return
                }
                try await service.execute(sql)
                infoMessage = "Statement executed and committed."
                if let table = openedTable {
                    await openTable(table.summary.ref, limit: limit, resetSQL: false)
                }
                return
            }
            var result: QueryResult
            var rowIDs: [String]?
            do {
                // "SELECT * ..." is run with each row's ctid too, so a result with a table's full column
                // layout can be edited even when the table has no primary key. Statements where PostgreSQL
                // rejects the ctid (joins, views, subqueries) simply run as written.
                if !confirmedWrite, let withRowID = Self.addingRowID(sql),
                   let r = try? await service.runQuery(withRowID, limit: limit, offset: offset, allowWrites: false,
                                                       options: options, columns: grid?.columns ?? []),
                   r.columns.first?.name == Self.rowIDColumn {
                    rowIDs = r.rows.map { $0[0] ?? "" }
                    result = QueryResult(columns: Array(r.columns.dropFirst()), rows: r.rows.map { Array($0.dropFirst()) },
                                         hasMore: r.hasMore)
                } else {
                    result = try await service.runQuery(sql, limit: limit, offset: offset, allowWrites: confirmedWrite,
                                                        options: options, columns: grid?.columns ?? [])
                }
            } catch is WriteNotAllowed {
                pendingWriteSQL = sql
                return
            }
            var grid = try await queryGrid(result, sql: sql, rowIDs: rowIDs, service: service)
            grid.offset = offset
            grid.isWriteResult = confirmedWrite
            grid.options = options
            setGrid(grid)
            form = .table
            infoMessage = "Query returned \(result.rows.count.formatted()) row\(result.rows.count == 1 ? "" : "s")"
                + (offset > 0 ? " from row \((offset + 1).formatted())" : "")
                + (result.hasMore ? " (more on the next page)." : ".")
        } catch {
            var error = DatabaseError.from(error)
            if error.message.contains("cannot insert multiple commands into a prepared statement") {
                error.message = "Only one statement can be run at a time. Run each statement separately."
            }
            sqlError = Self.describeSQLError(error, in: sql)
        }
    }

    /// After CREATE / ALTER / DROP: reloads the database list, the table, function and procedure list and the
    /// highlighted entry's description or code; reloads the open table, or closes it when it no longer exists.
    private func afterSchemaChange(limit: Int) async {
        guard let service else { return }
        if let list = try? await service.databases() {
            databases = list.contains(connectedDatabase ?? "") ? list : (list + [connectedDatabase].compactMap { $0 }).sorted()
        }
        let highlighted = highlightedEntry?.key
        await refreshTables()
        highlightedID = entryID(forKey: highlighted)
        await describeHighlighted()
        guard let table = openedTable else { return }
        if tables.contains(where: { $0.ref == table.summary.ref }) {
            if grid?.customSQL == nil {
                await openTable(table.summary.ref, limit: limit, resetSQL: false)
            }
        } else {
            openedTable = nil
            if grid?.ref == table.summary.ref || grid?.customSQL == nil {
                grid = nil
                edits = [:]
                gridVersion += 1
            }
        }
    }

    /// Grid for a query result. It is editable when every column is a plain column of one table (not a
    /// view) and either the table's primary key is among them, or the result has the table's full column
    /// layout (as SELECT * gives) and `rowIDs` (ctid of each row) identify the rows. Otherwise it is read-only.
    private func queryGrid(_ result: QueryResult, sql: String, rowIDs: [String]? = nil,
                           service: PostgresService) async throws -> GridData {
        var grid = GridData(description: nil, title: "Query result",
                            columns: result.columns.map { ColumnInfo(name: $0.name, type: $0.type.lowercased()) },
                            rows: result.rows, hasMore: result.hasMore, customSQL: sql)
        let oids = Set(result.columns.map(\.tableOID))
        guard oids.count == 1, let oid = oids.first, oid != 0, result.columns.allSatisfy({ $0.attnum > 0 }),
              let summary = tables.first(where: { $0.oid == String(oid) }), !summary.isView else { return grid }
        let description = try await service.describe(summary)
        let columns = result.columns.compactMap { column in description.columns.first { $0.attnum == column.attnum } }
        guard columns.count == result.columns.count else { return grid }
        let hasKey = !description.primaryKey.isEmpty
            && description.primaryKey.allSatisfy({ key in columns.contains { $0.name == key } })
        let fullLayout = columns.map(\.attnum) == description.columns.map(\.attnum)
        if fullLayout, let rowIDs, rowIDs.count == result.rows.count { grid.rowIDs = rowIDs }
        guard hasKey || !grid.rowIDs.isEmpty else { return grid }
        grid.description = description
        grid.columns = columns
        grid.title = "\(summary.ref.displayName) (query)"
        return grid
    }

    static let rowIDColumn = "mx_row_ctid"

    /// "SELECT * FROM t WHERE ..." -> "SELECT ctid::text AS mx_row_ctid, * FROM t WHERE ...";
    /// nil for any statement that does not start with SELECT * (after comments).
    static func addingRowID(_ sql: String) -> String? {
        var rest = Substring(sql)
        while true {
            rest = rest.drop { $0.isWhitespace }
            if rest.hasPrefix("--") {
                rest = rest.drop { $0 != "\n" }
            } else if rest.hasPrefix("/*") {
                guard let end = rest.range(of: "*/") else { return nil }
                rest = rest[end.upperBound...]
            } else {
                break
            }
        }
        guard rest.prefix(6).lowercased() == "select" else { return nil }
        let afterSelect = rest.dropFirst(6)
        guard afterSelect.first?.isWhitespace == true else { return nil }
        let star = afterSelect.drop { $0.isWhitespace }
        guard star.first == "*", star.dropFirst().first.map({ $0.isWhitespace || $0 == "\n" }) ?? true else { return nil }
        return String(sql[sql.startIndex..<rest.startIndex]) + "SELECT ctid::text AS \(rowIDColumn), *" + String(star.dropFirst())
    }

    /// The statement without trailing whitespace and semicolons.
    static func statementBody(_ text: String) -> String {
        var body = Substring(text)
        while let last = body.last, last.isWhitespace || last == ";" { body = body.dropLast() }
        return String(body)
    }

    private static func normalized(_ sql: String) -> String {
        sql.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static let runnableKeywords: Set = ["select", "with", "values", "table", "insert", "update", "delete", "merge", "call",
                                                "create", "drop", "alter"]

    /// Checks made before asking the server (which then parses the statement with PREPARE).
    static func localPreflight(_ sql: String) -> String? {
        if sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a SQL statement to run."
        }
        guard let keyword = leadingKeyword(sql) else {
            return "The statement must start with a SQL keyword such as SELECT."
        }
        guard runnableKeywords.contains(keyword) else {
            return "\(keyword.uppercased()) statements cannot be run here. Use SELECT, WITH, VALUES, TABLE, INSERT, UPDATE, DELETE, MERGE, CALL, CREATE, ALTER or DROP."
        }
        return nil
    }

    /// CREATE, ALTER or DROP (DDL): no PREPARE pre-flight, confirmation, then runs as its own transaction.
    static func isDDL(_ sql: String) -> Bool {
        ["create", "alter", "drop"].contains(leadingKeyword(sql) ?? "")
    }

    static func isAlter(_ sql: String) -> Bool {
        leadingKeyword(sql) == "alter"
    }

    static func isDrop(_ sql: String) -> Bool {
        leadingKeyword(sql) == "drop"
    }

    static func isCall(_ sql: String) -> Bool {
        leadingKeyword(sql) == "call"
    }

    /// First word of the statement, skipping whitespace, comments and opening parentheses.
    private static func leadingKeyword(_ sql: String) -> String? {
        var rest = Substring(sql)
        while true {
            rest = rest.drop { $0.isWhitespace || $0 == "(" }
            if rest.hasPrefix("--") {
                rest = rest.drop { $0 != "\n" }
            } else if rest.hasPrefix("/*") {
                guard let end = rest.range(of: "*/") else { return nil }
                rest = rest[end.upperBound...]
            } else {
                break
            }
        }
        let word = rest.prefix { $0.isLetter }
        return word.isEmpty ? nil : word.lowercased()
    }

    /// psql-style error text: the message, then the offending line with a caret under the error position.
    static func describeSQLError(_ error: DatabaseError, in sql: String) -> String {
        var lines = error.message.components(separatedBy: "\n")
        let first = "ERROR:  " + lines.removeFirst()
        let scalars = Array(sql.unicodeScalars)
        guard let position = error.position, position >= 1, position <= scalars.count + 1 else {
            return ([first] + lines).joined(separator: "\n")
        }
        let offset = position - 1
        let before = scalars[..<offset]
        let lineNumber = before.filter { $0 == "\n" }.count + 1
        let lineStart = before.lastIndex(of: "\n").map { $0 + 1 } ?? 0
        let lineEnd = scalars[lineStart...].firstIndex(of: "\n") ?? scalars.count
        var lineText = String(String.UnicodeScalarView(scalars[lineStart..<lineEnd]))
        lineText = lineText.replacingOccurrences(of: "\t", with: " ")
        let label = "LINE \(lineNumber): "
        let caret = String(repeating: " ", count: label.count + offset - lineStart) + "^"
        return ([first, label + lineText, caret] + lines).joined(separator: "\n")
    }

    private func run(_ work: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await work()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? DatabaseError.from(error).message
        }
    }
}

// Lets the Table menu reach the session of the frontmost workspace window.
extension FocusedValues {
    @Entry var workspaceSession: WorkspaceSession?
    @Entry var workspaceDocument: Binding<WorkspaceDocument>?
}
