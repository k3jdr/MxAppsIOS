//
//  WorkspaceSession.swift
//  MxDataSRM
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

    var tables: [TableSummary] = []
    var tableFilter = ""
    var highlightedTableID: TableSummary.ID?
    var highlightedDescription: TableDescription?
    var countingRows = false
    /// DB Table Selection: open tables in their own window instead of the DB Table form.
    var openInNewWindow = false

    var grid: GridData?
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

    var filteredTables: [TableSummary] {
        let filter = tableFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !filter.isEmpty else { return tables }
        return tables.filter { $0.ref.displayName.lowercased().contains(filter) }
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
            await refreshTables()
        } catch {
            status = .failed(DatabaseError.from(error).message)
        }
    }

    func disconnect() async {
        if let service { await service.close() }
        service = nil
        status = .disconnected
        tables = []
        highlightedDescription = nil
        grid = nil
        edits = [:]
        gridVersion += 1
        openedTable = nil
        sqlError = nil
    }

    // MARK: DB Table Selection

    func refreshTables() async {
        guard let service else { return }
        await run {
            let counted = Dictionary(uniqueKeysWithValues: self.tables.compactMap { t in t.exactRows.map { (t.oid, $0) } })
            self.tables = try await service.listTables().map { t in
                var t = t
                t.exactRows = counted[t.oid]
                return t
            }
        }
    }

    func describeHighlighted() async {
        guard let service, let id = highlightedTableID, let summary = tables.first(where: { $0.id == id }) else {
            highlightedDescription = nil
            return
        }
        await run { self.highlightedDescription = try await service.describe(summary) }
    }

    /// Replaces the estimates in the table list with exact count(*) values.
    func countAllRows() async {
        guard let service else { return }
        countingRows = true
        defer { countingRows = false }
        for index in tables.indices {
            do {
                tables[index].exactRows = try await service.exactRowCount(tables[index].ref)
            } catch {
                errorMessage = "\(tables[index].ref.displayName): \(DatabaseError.from(error).message)"
                return
            }
        }
    }

    // MARK: DB Table

    /// Loads the whole table into the grid. `resetSQL` puts the table's default SELECT in the SQL box.
    func openTable(_ ref: TableRef, limit: Int, resetSQL: Bool = true) async {
        guard let service else { return }
        if tables.isEmpty { await refreshTables() }
        guard let summary = tables.first(where: { $0.ref == ref }) else {
            errorMessage = "Table \(ref.displayName) was not found."
            return
        }
        await run {
            let description = try await service.describe(summary)
            self.setGrid(try await service.fetchGrid(description, limit: limit))
            self.openedTable = description
            self.infoMessage = nil
            if resetSQL {
                self.sqlText = description.defaultSQL
                self.sqlError = nil
            }
            self.form = .table
        }
    }

    func reloadGrid(limit: Int) async {
        if let sql = grid?.customSQL {
            await runSQL(sql, limit: limit)
        } else if let ref = grid?.ref {
            await openTable(ref, limit: limit, resetSQL: false)
        }
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
    func runSQL(_ sql: String? = nil, limit: Int, confirmedWrite: Bool = false) async {
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
            await openTable(table.summary.ref, limit: limit, resetSQL: false)
            return
        }

        runningSQL = true
        defer { runningSQL = false }
        do {
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
            let result: QueryResult
            do {
                result = try await service.runQuery(sql, limit: limit, allowWrites: confirmedWrite)
            } catch is WriteNotAllowed {
                pendingWriteSQL = sql
                return
            }
            setGrid(try await queryGrid(result, sql: sql, service: service))
            form = .table
            infoMessage = "Query returned \(result.rows.count.formatted()) row\(result.rows.count == 1 ? "" : "s")"
                + (result.hasMore ? " (fetch limit reached)." : ".")
        } catch {
            sqlError = Self.describeSQLError(DatabaseError.from(error), in: sql)
        }
    }

    /// Grid for a query result. It is editable when every column is a plain column of
    /// one table and the table's primary key is among them; otherwise it is read-only.
    private func queryGrid(_ result: QueryResult, sql: String, service: PostgresService) async throws -> GridData {
        var grid = GridData(description: nil, title: "Query result",
                            columns: result.columns.map { ColumnInfo(name: $0.name, type: $0.type.lowercased()) },
                            rows: result.rows, hasMore: result.hasMore, customSQL: sql)
        let oids = Set(result.columns.map(\.tableOID))
        guard oids.count == 1, let oid = oids.first, oid != 0, result.columns.allSatisfy({ $0.attnum > 0 }),
              let summary = tables.first(where: { $0.oid == String(oid) }) else { return grid }
        let description = try await service.describe(summary)
        let columns = result.columns.compactMap { column in description.columns.first { $0.attnum == column.attnum } }
        guard columns.count == result.columns.count, !description.primaryKey.isEmpty,
              description.primaryKey.allSatisfy({ key in columns.contains { $0.name == key } }) else { return grid }
        grid.description = description
        grid.columns = columns
        grid.title = "\(summary.ref.displayName) (query)"
        return grid
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

    private static let runnableKeywords: Set = ["select", "with", "values", "table", "insert", "update", "delete", "merge"]

    /// Checks made before asking the server (which then parses the statement with PREPARE).
    static func localPreflight(_ sql: String) -> String? {
        if sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a SQL statement to run."
        }
        guard let keyword = leadingKeyword(sql) else {
            return "The statement must start with a SQL keyword such as SELECT."
        }
        guard runnableKeywords.contains(keyword) else {
            return "\(keyword.uppercased()) statements cannot be run here. Use SELECT, WITH, VALUES, TABLE, INSERT, UPDATE, DELETE or MERGE."
        }
        return nil
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
