//
//  TablePivot.swift
//  MxNoteONE
//
//  Pivot tables, as in Excel: a summary of a table (its first row naming
//  the fields) by one field down the rows and optionally another across the
//  columns — Sum, Count, Average, Min, Max or Count Distinct of a value
//  field, with grand totals. The pivot is a new table on the page that
//  remembers its source, so Refresh Pivot Table brings it up to date.
//

import AppKit
import SwiftUI

struct PivotSpec: Codable, Hashable {
    enum Summary: String, Codable, CaseIterable, Identifiable {
        case sum, count, average, min, max, countDistinct
        var id: String { rawValue }
        var title: String {
            switch self {
            case .sum: "Sum"
            case .count: "Count"
            case .average: "Average"
            case .min: "Min"
            case .max: "Max"
            case .countDistinct: "Count Distinct"
            }
        }
    }

    /// The source table (its element on the page).
    var source: UUID
    /// Fields by their header text (columns are found again by name when refreshing), with their column then.
    var rowField: String
    var rowColumn: Int
    var columnField: String?
    var columnColumn: Int?
    /// nil = count the rows.
    var valueField: String?
    var valueColumn: Int?
    var summary: Summary
    var grandTotals = true
}

enum PivotBuilder {
    /// The source's field names (its first row; empty headers are named by their column letter).
    static func fields(_ source: TableModel) -> [String] {
        (0..<source.columnCount).map { c in
            let name = source.shownString(CellRef(row: 0, column: c)).trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? "Column \(TableData.columnName(c))" : name
        }
    }

    /// The column of a field: by name, else where it was.
    private static func column(named name: String, was index: Int, in fields: [String]) -> Int? {
        fields.firstIndex(of: name) ?? (fields.indices.contains(index) ? index : nil)
    }

    private struct Key: Hashable, Comparable {
        let number: Double?
        let text: String

        static func < (a: Key, b: Key) -> Bool {
            // Blanks last, numbers and dates by value, then text.
            if a.text.isEmpty != b.text.isEmpty { return b.text.isEmpty }
            switch (a.number, b.number) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.text.localizedStandardCompare(b.text) == .orderedAscending
            }
        }

        var label: String { text.isEmpty ? "(blank)" : text }
    }

    private static func key(_ model: TableModel, _ cell: CellRef) -> Key {
        let text = model.shownString(cell).trimmingCharacters(in: .whitespacesAndNewlines)
        switch model.value(cell) {
        case .number(let d), .date(let d): return Key(number: d, text: text)
        default: return Key(number: nil, text: text)
        }
    }

    private static func summarize(_ values: [FormulaValue], _ summary: PivotSpec.Summary, countRows: Bool) -> Double? {
        let numbers = values.compactMap { v -> Double? in
            switch v {
            case .number(let d), .date(let d): return d
            default: return nil
            }
        }
        switch summary {
        case .count: return Double(countRows ? values.count : values.filter { $0 != .empty }.count)
        case .countDistinct: return Double(Set(values.filter { $0 != .empty }.map(\.display)).count)
        case .sum: return numbers.isEmpty ? (values.isEmpty ? nil : 0) : numbers.reduce(0, +)
        case .average: return numbers.isEmpty ? nil : numbers.reduce(0, +) / Double(numbers.count)
        case .min: return numbers.min()
        case .max: return numbers.max()
        }
    }

    /// The pivot table's data, or nil when the fields aren't in the source any more.
    static func build(_ spec: PivotSpec, from source: TableModel) -> TableData? {
        let names = fields(source)
        guard source.rowCount > 1, let rowColumn = column(named: spec.rowField, was: spec.rowColumn, in: names) else { return nil }
        let columnColumn = spec.columnField.flatMap { column(named: $0, was: spec.columnColumn ?? -1, in: names) }
        let valueColumn = spec.valueField.flatMap { column(named: $0, was: spec.valueColumn ?? -1, in: names) }
        if spec.valueField != nil && valueColumn == nil { return nil }
        let countRows = valueColumn == nil
        let summary = countRows ? .count : spec.summary

        // Group the source's rows (every row below the header, filtered or not, as in Excel).
        var cells: [Key: [Key: [FormulaValue]]] = [:]
        var rowKeys = Set<Key>(), columnKeys = Set<Key>()
        let all = Key(number: nil, text: "")
        var byRow: [Key: [FormulaValue]] = [:], byColumn: [Key: [FormulaValue]] = [:], everything: [FormulaValue] = []
        for r in 1..<source.rowCount {
            let rowKey = key(source, CellRef(row: r, column: rowColumn))
            let columnKey = columnColumn.map { key(source, CellRef(row: r, column: $0)) } ?? all
            let value = valueColumn.map { source.value(CellRef(row: r, column: $0)) } ?? .number(1)
            rowKeys.insert(rowKey)
            columnKeys.insert(columnKey)
            cells[rowKey, default: [:]][columnKey, default: []].append(value)
            byRow[rowKey, default: []].append(value)
            byColumn[columnKey, default: []].append(value)
            everything.append(value)
        }
        let rows = rowKeys.sorted(), columns = columnColumn == nil ? [all] : columnKeys.sorted()

        // Dates stay dates for Min and Max.
        let dates = valueColumn.map { c in
            (1..<source.rowCount).allSatisfy { r in
                switch source.value(CellRef(row: r, column: c)) {
                case .date, .empty: return true
                default: return false
                }
            }
        } ?? false
        func text(_ number: Double?) -> String {
            guard let number else { return "" }
            if dates, summary == .min || summary == .max { return Formula.generalDate(number) }
            return Formula.format(number)
        }

        let valueTitle = countRows ? "Count" : "\(summary.title) of \(names[valueColumn!])"
        var table: [[String]] = []
        var header = [columnColumn == nil ? names[rowColumn] : "\(names[rowColumn]) ∖ \(names[columnColumn!])"]
        header += columnColumn == nil ? [valueTitle] : columns.map(\.label)
        if columnColumn != nil, spec.grandTotals { header.append("Grand Total") }
        table.append(header)
        for rowKey in rows {
            var line = [rowKey.label]
            for columnKey in columns {
                let values = cells[rowKey]?[columnKey] ?? []
                line.append(values.isEmpty ? "" : text(summarize(values, summary, countRows: countRows)))
            }
            if columnColumn != nil, spec.grandTotals { line.append(text(summarize(byRow[rowKey] ?? [], summary, countRows: countRows))) }
            table.append(line)
        }
        if spec.grandTotals {
            var line = ["Grand Total"]
            for columnKey in columns {
                line.append(text(summarize(byColumn[columnKey] ?? [], summary, countRows: countRows)))
            }
            if columnColumn != nil { line.append(text(summarize(everything, summary, countRows: countRows))) }
            table.append(line)
        }

        var data = TableData(rows: table.count, columns: table[0].count, width: Double(table[0].count) * 110)
        data.rows = table
        data.headerRow = true
        data.pivot = spec
        // Grand totals in bold; the value field's number format carries over (not for counts).
        if spec.grandTotals {
            let bold = NSFontManager.shared.convert(Prefs.defaultFont, toHaveTrait: .boldFontMask)
            data.rich = TableData.padded(nil, rows: table.count, columns: table[0].count)
            for c in table[0].indices {
                let r = table.count - 1
                data.rich![r][c] = TableData.cellData(NSAttributedString(string: table[r][c], attributes: [.font: bold]))
                if columnColumn != nil, r > 0 {
                    for rr in 1..<table.count where c == table[0].count - 1 {
                        data.rich![rr][c] = TableData.cellData(NSAttributedString(string: table[rr][c], attributes: [.font: bold]))
                    }
                }
            }
        }
        if let valueColumn, summary != .count, summary != .countDistinct,
           let format = (1..<source.rowCount).lazy.compactMap({ source.numberFormat(CellRef(row: $0, column: valueColumn)) }).first {
            var formats: [String: NumberFormat] = [:]
            for r in 1..<table.count {
                for c in 1..<table[0].count { formats[TableData.key(CellRef(row: r, column: c))] = format }
            }
            data.numberFormats = formats
        }
        return data
    }
}

// MARK: - Popover

/// Pivot Table…: the fields to summarise.
struct PivotView: View {
    let fields: [String]
    let create: (Int, Int?, Int?, PivotSpec.Summary, Bool) -> Void
    let close: () -> Void

    @State private var rowField = 0
    @State private var columnField = -1
    @State private var valueField: Int
    @State private var summary: PivotSpec.Summary = .sum
    @State private var totals = true

    init(fields: [String], suggestedValue: Int?, create: @escaping (Int, Int?, Int?, PivotSpec.Summary, Bool) -> Void,
         close: @escaping () -> Void) {
        self.fields = fields
        self.create = create
        self.close = close
        _valueField = State(initialValue: suggestedValue ?? -1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pivot Table").font(.headline)
            Text("Summarise this table by its fields (the first row's names) in a new table below it.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Rows:", selection: $rowField) {
                ForEach(fields.indices, id: \.self) { Text(fields[$0]).tag($0) }
            }
            Picker("Columns:", selection: $columnField) {
                Text("None").tag(-1)
                ForEach(fields.indices, id: \.self) { Text(fields[$0]).tag($0) }
            }
            Picker("Values:", selection: $valueField) {
                Text("Count of rows").tag(-1)
                ForEach(fields.indices, id: \.self) { Text(fields[$0]).tag($0) }
            }
            Picker("Summarise by:", selection: $summary) {
                ForEach(PivotSpec.Summary.allCases) { Text($0.title).tag($0) }
            }
            .disabled(valueField < 0)
            Toggle("Grand totals", isOn: $totals)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    create(rowField, columnField < 0 ? nil : columnField, valueField < 0 ? nil : valueField, summary, totals)
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(columnField == rowField)
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}
