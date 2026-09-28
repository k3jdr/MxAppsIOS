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

    var grid: GridData?
    var edits: [CellKey: CellEdit] = [:]
    /// Bumped whenever `grid` is replaced or edits are discarded, so the grid view reloads.
    private(set) var gridVersion = 0

    var busy = false
    var errorMessage: String?
    var infoMessage: String?

    var showViewDialog = false
    var showUpdateDialog = false

    private var service: PostgresService?

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

    func openTable(_ ref: TableRef, limit: Int) async {
        guard let service else { return }
        if tables.isEmpty { await refreshTables() }
        guard let summary = tables.first(where: { $0.ref == ref }) else {
            errorMessage = "Table \(ref.displayName) was not found."
            return
        }
        await run {
            let description = try await service.describe(summary)
            self.setGrid(try await service.fetchGrid(description, limit: limit))
            self.form = .table
        }
    }

    func reloadGrid(limit: Int) async {
        guard let ref = grid?.ref else { return }
        await openTable(ref, limit: limit)
    }

    private func setGrid(_ data: GridData) {
        grid = data
        edits = [:]
        gridVersion += 1
        if let index = tables.firstIndex(where: { $0.ref == data.ref }) {
            tables[index].exactRows = data.totalRows
        }
    }

    /// Records an edit from the grid; editing a cell back to its loaded value removes the edit.
    func setCell(row: Int, column: Int, to value: String?) {
        guard let grid else { return }
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
        guard let service, let grid else { return false }
        var succeeded = false
        await run {
            let planned = try planUpdates(grid: grid, edits: self.edits, options: options)
            let outcome = try await service.apply(planned, singleTransaction: options.singleTransaction)
            let fresh = try await service.fetchGrid(grid.description, limit: limit)
            self.setGrid(fresh)
            if outcome.failures.isEmpty {
                self.infoMessage = "Updated \(outcome.applied) row\(outcome.applied == 1 ? "" : "s") in \(grid.ref.displayName)."
                succeeded = true
            } else {
                self.errorMessage = "Updated \(outcome.applied) of \(planned.count) rows.\n\n"
                    + outcome.failures.joined(separator: "\n")
            }
        }
        return succeeded
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
