//
//  DatabaseModels.swift
//  MxDataSRM
//
//  Value types describing what was read from PostgreSQL: the table list,
//  a psql-style table description (\d) and the rows shown in the grid.
//

import Foundation

nonisolated struct TableSummary: Identifiable, Hashable, Sendable {
    var oid: String
    var ref: TableRef
    var kind: String
    var estimatedRows: Int
    var totalSize: String
    /// Filled in by "Count Rows" (count(*)); nil until counted.
    var exactRows: Int?

    var id: String { oid }
    var schema: String { ref.schema }
    var name: String { ref.name }
    /// Exact count when known, otherwise the planner estimate.
    var displayRows: Int { exactRows ?? estimatedRows }
}

nonisolated struct ColumnInfo: Hashable, Sendable {
    var name: String
    var type: String
    var collation: String = ""
    var notNull: Bool = false
    var defaultExpr: String = ""
    /// pg_attribute.attnum of the table column; 0 for computed query columns.
    var attnum: Int = 0
}

nonisolated struct TableDescription: Sendable {
    var summary: TableSummary
    var columns: [ColumnInfo]
    var primaryKey: [String]
    var indexes: [String]
    var checks: [String]
    var foreignKeys: [String]
    var referencedBy: [String]
    /// `SELECT * FROM schema.table ORDER BY <primary key>`, identifiers quoted by the server.
    var defaultSQL: String

    func column(named name: String) -> ColumnInfo? {
        columns.first { $0.name == name }
    }

    /// Text laid out like the output of psql's `\d table`.
    var psqlText: String {
        let kindTitle = summary.kind == "partitioned table" ? "Partitioned table" : "Table"
        var out = "\(kindTitle) \"\(summary.ref.displayName)\"\n"
        let headers = ["Column", "Type", "Collation", "Nullable", "Default"]
        let body = columns.map { [$0.name, $0.type, $0.collation, $0.notNull ? "not null" : "", $0.defaultExpr] }
        out += formatAligned(headers: headers, rows: body)
        func section(_ title: String, _ lines: [String]) {
            guard !lines.isEmpty else { return }
            out += "\(title):\n" + lines.map { "    " + $0 }.joined(separator: "\n") + "\n"
        }
        section("Indexes", indexes)
        section("Check constraints", checks)
        section("Foreign-key constraints", foreignKeys)
        section("Referenced by", referencedBy)
        return out
    }
}

/// psql-style aligned table: " a | b " with a "---+---" rule under the header.
nonisolated func formatAligned(headers: [String], rows: [[String]]) -> String {
    var widths = headers.map(\.count)
    for row in rows {
        for (i, cell) in row.enumerated() { widths[i] = max(widths[i], cell.count) }
    }
    func pad(_ s: String, _ w: Int) -> String { s + String(repeating: " ", count: w - s.count) }
    func center(_ s: String, _ w: Int) -> String {
        let left = (w - s.count) / 2
        return String(repeating: " ", count: left) + s + String(repeating: " ", count: w - s.count - left)
    }
    var out = " " + headers.enumerated().map { center($1, widths[$0]) }.joined(separator: " | ") + " \n"
    out += widths.map { String(repeating: "-", count: $0 + 2) }.joined(separator: "+") + "\n"
    for row in rows {
        let line = " " + row.enumerated().map { pad($1, widths[$0]) }.joined(separator: " | ")
        out += line.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) + "\n"
    }
    return out
}

/// Rows loaded into the DB Table grid. Every value is its PostgreSQL text
/// representation (`col::text`); nil is SQL NULL.
nonisolated struct GridData: Sendable {
    /// Table the rows can be edited against; nil for read-only query results.
    var description: TableDescription?
    /// Table name, or "Query result".
    var title: String
    var columns: [ColumnInfo]
    var rows: [[String?]]
    /// `ctid` of each row (whole-table loads only), the row key for tables without a primary key.
    var rowIDs: [String] = []
    /// Rows in the table; nil when the rows came from custom SQL.
    var totalRows: Int?
    /// More rows were available than the fetch limit allowed.
    var hasMore = false
    /// The SQL typed by the user, when the rows did not come from opening a table.
    var customSQL: String?
    var loadedAt = Date()

    var ref: TableRef? { description?.summary.ref }
    var isEditable: Bool {
        guard let description else { return false }
        return !description.primaryKey.isEmpty || !rowIDs.isEmpty
    }
    /// Key under which the user's column widths are saved in the workspace.
    var widthKey: String { ref?.displayName ?? "(query)" }
}

nonisolated struct CellKey: Hashable, Sendable {
    var row: Int
    var column: Int
}

/// A pending cell edit made in the grid; `value == nil` means set to NULL.
nonisolated struct CellEdit: Hashable, Sendable {
    var value: String?
}
