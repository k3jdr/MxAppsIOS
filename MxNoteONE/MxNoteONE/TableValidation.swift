//
//  TableValidation.swift
//  MxNoteONE
//
//  Data validation for table cells, as in Excel: a rule on a block of cells
//  (or whole columns) allows a List of values — typed, or taken from a range
//  such as =E2:E9, picked from an in-cell dropdown — or whole numbers,
//  decimals, dates or text lengths within limits. Entries that break the
//  rule get Excel's Stop, Warning or Information alert, and Circle Invalid
//  Data marks values already in the table that break it.
//

import AppKit
import SwiftUI

struct ValidationRule: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case list, wholeNumber, decimal, date, textLength
        var id: String { rawValue }
        var title: String {
            switch self {
            case .list: "List"
            case .wholeNumber: "Whole Number"
            case .decimal: "Decimal"
            case .date: "Date"
            case .textLength: "Text Length"
            }
        }
    }

    enum ErrorStyle: String, Codable, CaseIterable, Identifiable {
        case stop, warning, information
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    var id = UUID()
    var kind: Kind
    var firstRow: Int
    /// nil = to the table's last row (rules made on whole columns grow with the table).
    var lastRow: Int?
    var firstColumn: Int
    var lastColumn: Int
    /// List: values separated by commas, or a range such as =E2:E9.
    var source = ""
    var minimum = ""
    var maximum = ""
    var allowBlank = true
    var dropdown = true
    var errorStyle: ErrorStyle = .stop
    var errorTitle = ""
    var errorMessage = ""

    func covers(_ cell: CellRef, rowCount: Int) -> Bool {
        cell.row >= firstRow && cell.row <= (lastRow ?? rowCount - 1) && cell.column >= firstColumn && cell.column <= lastColumn
    }

    /// What the rule allows, for messages.
    var explanation: String {
        func limits(_ unit: String) -> String {
            switch (minimum.isEmpty, maximum.isEmpty) {
            case (false, false): return "\(unit) between \(minimum) and \(maximum)"
            case (false, true): return "\(unit) of at least \(minimum)"
            case (true, false): return "\(unit) of at most \(maximum)"
            default: return unit
            }
        }
        switch kind {
        case .list: return "a value from the list"
        case .wholeNumber: return limits("a whole number")
        case .decimal: return limits("a number")
        case .date: return limits("a date")
        case .textLength: return limits("text with a length")
        }
    }
}

// MARK: - Data

extension TableData {
    /// Keeps validation on its cells when a row (rows: true) or column is inserted (+1) or removed (-1).
    mutating func shiftValidationRules(rows: Bool, at index: Int, by delta: Int) {
        guard let rules = validationRules else { return }
        let rowLimit = self.rows.count
        let moved: [ValidationRule] = rules.compactMap { rule in
            var r = rule
            func move(_ v: Int, isEnd: Bool) -> Int {
                if delta > 0 { return v >= index ? v + 1 : v }
                if v > index { return v - 1 }
                if v == index && isEnd { return v - 1 }
                return v
            }
            if rows {
                r.firstRow = move(r.firstRow, isEnd: false)
                if let last = r.lastRow { r.lastRow = move(last, isEnd: true) }
                if (r.lastRow ?? rowLimit) < r.firstRow { return nil }
            } else {
                r.firstColumn = move(r.firstColumn, isEnd: false)
                r.lastColumn = move(r.lastColumn, isEnd: true)
                if r.lastColumn < r.firstColumn { return nil }
                // A list taken from a range follows inserted and deleted columns and rows too.
            }
            if r.kind == .list, r.source.hasPrefix("=") {
                r.source = Formula.shift(r.source, rows: rows, at: index, by: delta)
            }
            return r
        }
        validationRules = moved.isEmpty ? nil : moved
    }
}

// MARK: - Model

extension TableModel {
    var hasValidation: Bool { !(data.validationRules ?? []).isEmpty }

    /// The rule for a cell (the last one set on it).
    func validationRule(_ cell: CellRef) -> ValidationRule? {
        data.validationRules?.last { $0.covers(master(cell), rowCount: rowCount) }
    }

    /// Replaces the rules on the cells with a new one (nil clears them).
    func setValidation(_ rule: ValidationRule?, replacing cells: Set<CellRef>) {
        var rules = (data.validationRules ?? []).filter { r in !cells.contains { r.covers($0, rowCount: rowCount) } }
        if let rule { rules.append(rule) }
        data.validationRules = rules.isEmpty ? nil : rules
        changed()
    }

    /// A list rule's values: typed values, or the shown values of a range (=E2:E9), without blanks or repeats.
    func listValues(_ rule: ValidationRule) -> [String] {
        var values: [String] = []
        let source = rule.source.trimmingCharacters(in: .whitespaces)
        if source.hasPrefix("=") {
            let parts = source.dropFirst().split(separator: ":").map { String($0).trimmingCharacters(in: .whitespaces) }
            guard let a = Formula.parseRef(parts.first ?? ""), let b = Formula.parseRef(parts.last ?? "") else { return [] }
            for r in min(a.row, b.row)...max(a.row, b.row) {
                for c in min(a.column, b.column)...max(a.column, b.column) {
                    let cell = CellRef(row: r, column: c)
                    guard contains(cell) else { continue }
                    values.append(shownString(cell).trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        } else {
            values = source.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// Whether a cell's value keeps its rule (cells without a rule always do).
    func isValid(_ cell: CellRef) -> Bool {
        guard let rule = validationRule(cell) else { return true }
        let cell = master(cell)
        let shown = shownString(cell).trimmingCharacters(in: .whitespacesAndNewlines)
        if shown.isEmpty { return rule.allowBlank }
        let lo = Formula.numeric(rule.minimum), hi = Formula.numeric(rule.maximum)
        func within(_ x: Double) -> Bool { (lo.map { x >= $0 } ?? true) && (hi.map { x <= $0 } ?? true) }
        let v = value(cell)
        switch rule.kind {
        case .list:
            return listValues(rule).contains { $0.caseInsensitiveCompare(shown) == .orderedSame }
        case .wholeNumber:
            guard case .number(let d) = v, d == d.rounded() else { return false }
            return within(d)
        case .decimal:
            guard case .number(let d) = v else { return false }
            return within(d)
        case .date:
            guard case .date(let d) = v else { return false }
            return within(d)
        case .textLength:
            return within(Double(shown.count))
        }
    }
}

// MARK: - Popover

/// Data Validation…: the rule for the selected cells.
struct ValidationView: View {
    let rangeName: String
    let apply: (ValidationRule?) -> Void
    let close: () -> Void

    @State private var allowAny: Bool
    @State private var rule: ValidationRule

    init(rangeName: String, rule: ValidationRule, isNew: Bool, apply: @escaping (ValidationRule?) -> Void,
         close: @escaping () -> Void) {
        self.rangeName = rangeName
        self.apply = apply
        self.close = close
        _rule = State(initialValue: rule)
        _allowAny = State(initialValue: isNew)
    }

    private var minimumLabel: String { rule.kind == .date ? "Start date" : "Minimum" }
    private var maximumLabel: String { rule.kind == .date ? "End date" : "Maximum" }

    private var ready: Bool {
        if allowAny { return true }
        switch rule.kind {
        case .list: return !rule.source.trimmingCharacters(in: .whitespaces).isEmpty
        default: return !rule.minimum.isEmpty || !rule.maximum.isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Data Validation — \(rangeName)").font(.headline)
            Picker("Allow:", selection: Binding(get: { allowAny ? nil : rule.kind }, set: { kind in
                if let kind { rule.kind = kind; allowAny = false } else { allowAny = true }
            })) {
                Text("Any Value").tag(ValidationRule.Kind?.none)
                ForEach(ValidationRule.Kind.allCases) { Text($0.title).tag(ValidationRule.Kind?.some($0)) }
            }
            if !allowAny {
                if rule.kind == .list {
                    TextField("Values, separated by commas — or a range such as =E2:E9", text: $rule.source)
                        .textFieldStyle(.roundedBorder)
                    Toggle("In-cell dropdown", isOn: $rule.dropdown)
                } else {
                    HStack {
                        TextField(minimumLabel, text: $rule.minimum)
                        TextField(maximumLabel, text: $rule.maximum)
                    }
                    .textFieldStyle(.roundedBorder)
                }
                Toggle("Ignore blank", isOn: $rule.allowBlank)
                Divider()
                Picker("When a value breaks the rule:", selection: $rule.errorStyle) {
                    ForEach(ValidationRule.ErrorStyle.allCases) { Text($0.title).tag($0) }
                }
                TextField("Alert title (optional)", text: $rule.errorTitle).textFieldStyle(.roundedBorder)
                TextField("Alert message (optional)", text: $rule.errorMessage).textFieldStyle(.roundedBorder)
            }
            HStack {
                Button("Clear All") {
                    apply(nil)
                    close()
                }
                Spacer()
                Button("Cancel", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                Button("OK") {
                    apply(allowAny ? nil : rule)
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!ready)
            }
        }
        .padding(14)
        .frame(width: 360)
    }
}
