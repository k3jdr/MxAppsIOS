//
//  TableUpdate.swift
//  MxDataSQL
//
//  Turns the pending cell edits of the grid into parameterized UPDATE
//  statements. Values are always sent as text and cast to the column type
//  on the server ($1::text::integer), so any type with a text input form works.
//

import Foundation

nonisolated enum RowKeyMode: String, CaseIterable, Identifiable, Sendable {
    case primaryKey = "Primary key"
    case rowID = "Row ID (ctid)"
    case columns = "Match columns"
    var id: String { rawValue }
}

nonisolated struct UpdateOptions: Sendable {
    var keyMode: RowKeyMode = .primaryKey
    /// Columns whose loaded values identify the row when keyMode == .columns.
    var matchColumns: Set<String> = []
    /// An edited cell left empty is written as NULL instead of ''.
    var emptyAsNull = false
    /// Only update a row if the edited columns still hold the values that were loaded.
    var checkOriginalValues = true
    /// Apply all rows in one transaction (all or nothing) instead of row by row.
    var singleTransaction = true
}

nonisolated struct PlannedUpdate: Sendable {
    var row: Int
    var sql: String
    var binds: [String?]
    /// Human-readable description of the row key, e.g. "id = 42".
    var rowLabel: String
}

nonisolated enum UpdatePlanError: LocalizedError {
    case readOnly
    case noPrimaryKey
    case noRowIDs
    case noMatchColumns

    var errorDescription: String? {
        switch self {
        case .readOnly: "These rows are a read-only query result."
        case .noPrimaryKey: "The table has no primary key. Choose Row ID (ctid) or Match columns."
        case .noRowIDs: "Row IDs are only available when the whole table is loaded. Choose another row key."
        case .noMatchColumns: "Select at least one column to match rows on."
        }
    }
}

nonisolated func planUpdates(grid: GridData, edits: [CellKey: CellEdit], options: UpdateOptions) throws -> [PlannedUpdate] {
    guard let description = grid.description else { throw UpdatePlanError.readOnly }
    let columns = grid.columns
    let keyColumns: [String]
    switch options.keyMode {
    case .primaryKey:
        keyColumns = description.primaryKey
        if keyColumns.isEmpty { throw UpdatePlanError.noPrimaryKey }
    case .rowID:
        keyColumns = []
        if grid.rowIDs.isEmpty { throw UpdatePlanError.noRowIDs }
    case .columns:
        keyColumns = columns.map(\.name).filter { options.matchColumns.contains($0) }
        if keyColumns.isEmpty { throw UpdatePlanError.noMatchColumns }
    }

    let byRow = Dictionary(grouping: edits, by: { $0.key.row })
    return byRow.keys.sorted().map { row in
        let rowEdits = byRow[row]!.sorted { $0.key.column < $1.key.column }
        let original = grid.rows[row]
        var binds: [String?] = []
        func param(_ value: String?) -> String {
            binds.append(value)
            return "$\(binds.count)"
        }

        let assignments = rowEdits.map { key, edit -> String in
            let col = columns[key.column]
            var value = edit.value
            if options.emptyAsNull, value == "" { value = nil }
            return "\(quoteIdent(col.name)) = \(param(value))::text::\(col.type)"
        }

        var conditions: [String] = []
        var labelParts: [String] = []
        switch options.keyMode {
        case .primaryKey:
            for name in keyColumns {
                let index = columns.firstIndex { $0.name == name }!
                let col = columns[index]
                conditions.append("\(quoteIdent(name)) = \(param(original[index]))::text::\(col.type)")
                labelParts.append("\(name) = \(original[index] ?? "NULL")")
            }
        case .rowID:
            conditions.append("ctid = \(param(grid.rowIDs[row]))::text::tid")
            labelParts.append("ctid = \(grid.rowIDs[row])")
        case .columns:
            for name in keyColumns {
                let index = columns.firstIndex { $0.name == name }!
                conditions.append("\(quoteIdent(name))::text IS NOT DISTINCT FROM \(param(original[index]))")
                labelParts.append("\(name) = \(original[index] ?? "NULL")")
            }
        }
        if options.checkOriginalValues {
            for (key, _) in rowEdits {
                let name = columns[key.column].name
                conditions.append("\(quoteIdent(name))::text IS NOT DISTINCT FROM \(param(original[key.column]))")
            }
        }

        let sql = "UPDATE \(description.summary.ref.qualifiedSQL) SET " + assignments.joined(separator: ", ")
            + " WHERE " + conditions.joined(separator: " AND ") + " RETURNING 1"
        return PlannedUpdate(row: row, sql: sql, binds: binds, rowLabel: labelParts.joined(separator: ", "))
    }
}
