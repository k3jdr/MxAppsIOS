//
//  LocalGridFilters.swift
//  Shared (MxAcctMGR's banking registers)
//
//  Excel-style sorting and filtering of rows held in memory, with the same GridQueryOptions, header
//  buttons (columnHeaderFilters) and ColumnFilterPopover as the server-side grids. Each column says how it
//  shows a row's value (what the value checklist lists and matches) and how it compares (a number, a
//  yyyy-MM-dd date or text), so sorting and greater / less / between use the value, not its display.
//  Empty values sort last both ways, as NULLS LAST does on the server.
//

import Foundation

struct LocalGridColumn<Row> {
    enum Kind: String { case text, number = "numeric", date }

    var kind: Kind
    /// The value as the column shows it; nil or "" is empty.
    var display: (Row) -> String?
    /// A number column's value (date columns compare their yyyy-MM-dd text, text columns their display).
    var number: ((Row) -> Double?)?
    var isoDate: ((Row) -> String?)?

    static func text(_ display: @escaping (Row) -> String?) -> Self {
        Self(kind: .text, display: display)
    }
    static func number(_ value: @escaping (Row) -> Double?, display: @escaping (Row) -> String?) -> Self {
        Self(kind: .number, display: display, number: value)
    }
    static func date(_ iso: @escaping (Row) -> String?, display: @escaping (Row) -> String?) -> Self {
        Self(kind: .date, display: display, isoDate: { iso($0).map { String($0.prefix(10)) } })
    }
}

enum LocalGrid {
    private enum Key: Comparable {
        case number(Double)
        case text(String)
    }

    /// Column title → the type ColumnFilterPopover names its sort buttons by.
    static func types<Row>(_ columns: [String: LocalGridColumn<Row>]) -> [String: String] {
        columns.mapValues(\.kind.rawValue)
    }

    /// The rows that pass every filter (but `except`'s), sorted as the options say (else in their order).
    static func rows<Row>(_ rows: [Row], _ options: GridQueryOptions, _ columns: [String: LocalGridColumn<Row>],
                          except: String? = nil) -> [Row] {
        let filters = options.filters.filter { $0.key != except && columns[$0.key] != nil }
        var kept = rows.filter { row in filters.allSatisfy { matches(row, $0.value, columns[$0.key]!) } }
        if let sort = options.sort, let column = columns[sort.column] {
            let keyed = kept.enumerated().map { (index: $0.offset, key: key(of: $0.element, column), row: $0.element) }
            kept = keyed.sorted { a, b in
                switch (a.key, b.key) {
                case (nil, nil): return a.index < b.index
                case (nil, _): return false          // empty values last, both ways
                case (_, nil): return true
                case let (x?, y?): return x == y ? a.index < b.index : (sort.ascending ? x < y : x > y)
                }
            }.map(\.row)
        }
        return kept
    }

    /// The column's distinct values with their counts among the rows the other columns' filters keep, in the
    /// column's order (numbers and dates by value), for the popover's checklist.
    static func values<Row>(_ rows: [Row], column name: String, _ options: GridQueryOptions,
                            _ columns: [String: LocalGridColumn<Row>]) -> [DistinctValue] {
        guard let column = columns[name] else { return [] }
        var counts: [String?: (count: Int, key: Key?)] = [:]
        for row in Self.rows(rows, GridQueryOptions(filters: options.filters, sort: nil), columns, except: name) {
            let shown = display(row, column)
            counts[shown, default: (0, key(of: row, column))].count += 1
        }
        return counts.sorted { a, b in
            switch (a.value.key, b.value.key) {
            case (nil, _): return false
            case (_, nil): return true
            case let (x?, y?): return x < y
            }
        }
        .map { DistinctValue(value: $0.key, count: $0.value.count) }
    }

    // MARK: Matching

    private static func display<Row>(_ row: Row, _ column: LocalGridColumn<Row>) -> String? {
        guard let s = column.display(row)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        return s
    }

    private static func key<Row>(of row: Row, _ column: LocalGridColumn<Row>) -> Key? {
        switch column.kind {
        case .number: return column.number?(row).map(Key.number)
        case .date: return column.isoDate?(row).map(Key.text)
        case .text: return display(row, column).map { .text($0.lowercased()) }
        }
    }

    /// What the user typed, as the column compares it: a number ($ and commas allowed), a date (MM/dd/yyyy,
    /// MM/dd/yy or yyyy-MM-dd) or lower-cased text.
    private static func key<Row>(typed: String, _ column: LocalGridColumn<Row>) -> Key? {
        let t = typed.trimmingCharacters(in: .whitespaces)
        switch column.kind {
        case .number:
            let clean = t.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")
            let negative = clean.hasPrefix("(") && clean.hasSuffix(")")
            return Double(clean.trimmingCharacters(in: CharacterSet(charactersIn: "()"))).map { .number(negative ? -$0 : $0) }
        case .date:
            return isoDay(t).map(Key.text)
        case .text:
            return .text(t.lowercased())
        }
    }

    private static func isoDay(_ s: String) -> String? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.isLenient = false
        // A two-digit year is this century's (3/13/26 is 2026, not the year 26).
        let parts = s.split(separator: "/")
        f.dateFormat = s.contains("-") ? "yyyy-MM-dd" : (parts.count == 3 && parts[2].count == 2 ? "M/d/yy" : "M/d/yyyy")
        f.twoDigitStartDate = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2000, month: 1, day: 1).date
        guard let d = f.date(from: s) else { return nil }
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    private static func matches<Row>(_ row: Row, _ filter: ColumnFilter, _ column: LocalGridColumn<Row>) -> Bool {
        let shown = display(row, column)
        switch filter {
        case .values(let set):
            return set.contains(shown)
        case .condition(let op, let v1, let v2):
            let text = shown?.lowercased() ?? ""
            let needle = v1.trimmingCharacters(in: .whitespaces).lowercased()
            switch op {
            case .isEmpty: return shown == nil
            case .isNotEmpty: return shown != nil
            case .contains: return text.contains(needle)
            case .notContains: return !text.contains(needle)
            case .beginsWith: return text.hasPrefix(needle)
            case .endsWith: return text.hasSuffix(needle)
            case .equals, .notEquals:
                // Numbers and dates by value (12.5 equals $12.50); text ignores case.
                let same: Bool
                if column.kind == .text { same = text == needle } else {
                    same = key(of: row, column) != nil && key(of: row, column) == key(typed: v1, column)
                }
                return op == .equals ? same : !same
            case .greater, .greaterOrEqual, .less, .lessOrEqual, .between:
                guard let value = key(of: row, column), let a = key(typed: v1, column) else { return false }
                switch op {
                case .greater: return value > a
                case .greaterOrEqual: return value >= a
                case .less: return value < a
                case .lessOrEqual: return value <= a
                default:
                    guard let b = key(typed: v2, column) else { return false }
                    return min(a, b) <= value && value <= max(a, b)
                }
            }
        }
    }
}
