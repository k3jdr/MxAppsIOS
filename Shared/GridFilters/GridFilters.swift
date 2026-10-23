//
//  GridFilters.swift
//  Shared (MxDataSQL's DB Table grid, MxDataHUB's Securities list)
//
//  Excel-style sorting and filtering for a grid of PostgreSQL rows. They run on
//  the server: the grid's query gets a WHERE and ORDER BY, so paging, row counts,
//  Export CSV (all rows) and Update all see the same rows. Filter values are
//  always sent as parameters, never pasted into the SQL.
//

import Foundation

nonisolated enum FilterOperator: String, CaseIterable, Identifiable, Sendable {
    case equals = "equals"
    case notEquals = "does not equal"
    case contains = "contains"
    case notContains = "does not contain"
    case beginsWith = "begins with"
    case endsWith = "ends with"
    case greater = "is greater than"
    case greaterOrEqual = "is greater than or equal to"
    case less = "is less than"
    case lessOrEqual = "is less than or equal to"
    case between = "is between"
    case isEmpty = "is empty"
    case isNotEmpty = "is not empty"

    var id: String { rawValue }
    var needsValue: Bool { self != .isEmpty && self != .isNotEmpty }
    var needsSecondValue: Bool { self == .between }
}

nonisolated enum ColumnFilter: Equatable, Sendable {
    /// Keep rows whose value is one of these (nil = NULL), compared as displayed text.
    case values(Set<String?>)
    /// Keep rows matching a condition; text operators ignore case, comparisons use the column type.
    case condition(FilterOperator, String, String)
}

nonisolated struct GridSort: Equatable, Sendable {
    var column: String
    var ascending: Bool
}

/// Sorting and filters of one grid, keyed by column name.
nonisolated struct GridQueryOptions: Equatable, Sendable {
    var filters: [String: ColumnFilter] = [:]
    var sort: GridSort?

    var isEmpty: Bool { filters.isEmpty && sort == nil }
}

/// Parameter list shared by the pieces of one statement ($1, $2, ...).
nonisolated struct SQLBinds: Sendable {
    private(set) var values: [String?] = []

    init(_ initial: [String?] = []) { values = initial }

    mutating func add(_ value: String?) -> String {
        values.append(value)
        return "$\(values.count)"
    }
}

nonisolated enum GridSQL {
    /// `col > $1::text::<type>` only for type names that are safe to paste; otherwise compare as text.
    private static func typedParam(_ param: String, type: String) -> String? {
        let t = type.lowercased()
        guard !t.isEmpty, t.range(of: #"^[a-z0-9_ \[\](),."]+$"#, options: .regularExpression) != nil,
              !t.hasPrefix("oid ") else { return nil }
        return "\(param)::text::\(t)"
    }

    /// One filter as a condition on the column expression `expr`.
    static func condition(_ filter: ColumnFilter, expr: String, type: String, binds: inout SQLBinds) -> String {
        let text = "\(expr)::text"
        switch filter {
        case .values(let set):
            var parts: [String] = []
            let nonNull = set.compactMap { $0 }.sorted()
            if !nonNull.isEmpty {
                parts.append("\(text) IN (" + nonNull.map { binds.add($0) }.joined(separator: ", ") + ")")
            }
            if set.contains(nil) { parts.append("\(expr) IS NULL") }
            return parts.isEmpty ? "false" : "(" + parts.joined(separator: " OR ") + ")"
        case .condition(let op, let v1, let v2):
            switch op {
            case .isEmpty:
                return "(\(expr) IS NULL OR \(text) = '')"
            case .isNotEmpty:
                return "(\(expr) IS NOT NULL AND \(text) <> '')"
            case .equals:
                return "\(text) = \(binds.add(v1))"
            case .notEquals:
                return "(\(expr) IS NULL OR \(text) <> \(binds.add(v1)))"
            case .contains:
                return "strpos(lower(\(text)), lower(\(binds.add(v1)))) > 0"
            case .notContains:
                return "(\(expr) IS NULL OR strpos(lower(\(text)), lower(\(binds.add(v1)))) = 0)"
            case .beginsWith:
                return "starts_with(lower(\(text)), lower(\(binds.add(v1))))"
            case .endsWith:
                let p = binds.add(v1)
                return "right(lower(\(text)), length(\(p))) = lower(\(p))"
            case .greater, .greaterOrEqual, .less, .lessOrEqual:
                let sign = [.greater: ">", .greaterOrEqual: ">=", .less: "<", .lessOrEqual: "<="][op]!
                let p = binds.add(v1)
                if let typed = typedParam(p, type: type) { return "\(expr) \(sign) \(typed)" }
                return "\(text) \(sign) \(p)"
            case .between:
                let a = binds.add(v1), b = binds.add(v2)
                if let ta = typedParam(a, type: type), let tb = typedParam(b, type: type) {
                    return "\(expr) BETWEEN \(ta) AND \(tb)"
                }
                return "\(text) BETWEEN \(a) AND \(b)"
            }
        }
    }

    /// The filters' conditions joined with AND (empty when there are none). `types` gives each column's
    /// SQL type (filters on other names are ignored); `expr` maps a column name to its SQL expression.
    static func conditions(_ options: GridQueryOptions, types: [String: String], except: String? = nil,
                           expr: (String) -> String, binds: inout SQLBinds) -> String {
        options.filters.keys.sorted().compactMap { name -> String? in
            guard name != except, let filter = options.filters[name], let type = types[name] else { return nil }
            return condition(filter, expr: expr(name), type: type, binds: &binds)
        }
        .joined(separator: " AND ")
    }

    /// " WHERE ..." for the filters (empty when there are none).
    static func whereClause(_ options: GridQueryOptions, types: [String: String], except: String? = nil,
                            expr: (String) -> String, binds: inout SQLBinds) -> String {
        let sql = conditions(options, types: types, except: except, expr: expr, binds: &binds)
        return sql.isEmpty ? "" : " WHERE " + sql
    }

    /// "<expr> ASC NULLS LAST" for the sort column, or nil.
    static func orderTerm(_ options: GridQueryOptions, expr: (String) -> String) -> String? {
        guard let sort = options.sort else { return nil }
        return "\(expr(sort.column)) \(sort.ascending ? "ASC" : "DESC") NULLS LAST"
    }
}

/// A distinct value of a column for the filter checklist (value nil = NULL).
nonisolated struct DistinctValue: Hashable, Sendable {
    var value: String?
    var count: Int
}
