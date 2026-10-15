//
//  TableConditional.swift
//  MxNoteONE
//
//  Conditional formatting for table cells, as in Excel: rules on a block of
//  cells (or whole columns) that colour, embolden, bar or shade cells by
//  their values — greater / less than, between, equal, text contains,
//  blank, top / bottom N, above / below average, duplicates, data bars and
//  colour scales. Rules follow inserted and deleted rows and columns.
//

import AppKit
import SwiftUI

struct ConditionalRule: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case greater, less, between, equal, notEqual, contains, blank, notBlank
        case top, bottom, aboveAverage, belowAverage, duplicate, unique, dataBar, colorScale
        var id: String { rawValue }

        var title: String {
            switch self {
            case .greater: "Greater Than"
            case .less: "Less Than"
            case .between: "Between"
            case .equal: "Equal To"
            case .notEqual: "Not Equal To"
            case .contains: "Text That Contains"
            case .blank: "Blank"
            case .notBlank: "Not Blank"
            case .top: "Top Items"
            case .bottom: "Bottom Items"
            case .aboveAverage: "Above Average"
            case .belowAverage: "Below Average"
            case .duplicate: "Duplicate Values"
            case .unique: "Unique Values"
            case .dataBar: "Data Bars"
            case .colorScale: "Color Scale"
            }
        }

        /// Values the rule needs (0, 1 or 2).
        var valueCount: Int {
            switch self {
            case .between: 2
            case .greater, .less, .equal, .notEqual, .contains, .top, .bottom: 1
            default: 0
            }
        }

        /// Data bars and colour scales draw their own colours.
        var isGraphic: Bool { self == .dataBar || self == .colorScale }
    }

    var id = UUID()
    var kind: Kind
    var firstRow: Int
    /// nil = to the table's last row (rules made on whole columns grow with the table).
    var lastRow: Int?
    var firstColumn: Int
    var lastColumn: Int
    var value1 = ""
    var value2 = ""
    var fill: RGBA?
    var textColor: RGBA?
    var bold = false
    /// Data bar colour, or a colour scale's low and high colours.
    var low: RGBA?
    var high: RGBA?

    func covers(_ cell: CellRef, rowCount: Int) -> Bool {
        cell.row >= firstRow && cell.row <= (lastRow ?? rowCount - 1) && cell.column >= firstColumn && cell.column <= lastColumn
    }

    /// The range as Excel names it (B2:B9).
    func rangeName(rowCount: Int) -> String {
        let last = (lastRow ?? rowCount - 1) + 1
        return "\(TableData.columnName(firstColumn))\(firstRow + 1):\(TableData.columnName(lastColumn))\(last)"
    }

    var summary: String {
        switch kind {
        case .greater: "Value > \(value1)"
        case .less: "Value < \(value1)"
        case .between: "Value between \(value1) and \(value2)"
        case .equal: "Value = \(value1)"
        case .notEqual: "Value ≠ \(value1)"
        case .contains: "Text contains “\(value1)”"
        case .top: "Top \(value1)"
        case .bottom: "Bottom \(value1)"
        default: kind.title
        }
    }
}

/// A cell's look from its rules.
struct ConditionalStyle {
    var fill: NSColor?
    var textColor: NSColor?
    var bold = false
    /// Data bar: fraction of the cell's width, and colour.
    var bar: (fraction: CGFloat, color: NSColor)?
}

/// Styles offered for highlighting rules (Excel's presets).
struct HighlightStyle: Identifiable, Hashable {
    let name: String
    let fill: RGBA?
    let text: RGBA?
    let bold: Bool
    var id: String { name }

    static let presets: [HighlightStyle] = [
        HighlightStyle(name: "Light Red Fill with Dark Red Text", fill: hex(0xFFC7CE), text: hex(0x9C0006), bold: false),
        HighlightStyle(name: "Yellow Fill with Dark Yellow Text", fill: hex(0xFFEB9C), text: hex(0x9C5700), bold: false),
        HighlightStyle(name: "Green Fill with Dark Green Text", fill: hex(0xC6EFCE), text: hex(0x006100), bold: false),
        HighlightStyle(name: "Light Red Fill", fill: hex(0xFFC7CE), text: nil, bold: false),
        HighlightStyle(name: "Light Blue Fill", fill: hex(0xDDEBF7), text: nil, bold: false),
        HighlightStyle(name: "Red Text", fill: nil, text: hex(0xC00000), bold: false),
        HighlightStyle(name: "Bold Text", fill: nil, text: nil, bold: true),
        HighlightStyle(name: "Bold Red Text", fill: nil, text: hex(0xC00000), bold: true),
    ]

    static func hex(_ v: UInt32) -> RGBA {
        RGBA(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255)
    }

    static let barColors: [(String, RGBA)] = [("Blue", hex(0x638EC6)), ("Green", hex(0x63BE7B)), ("Red", hex(0xF8696B)),
                                              ("Orange", hex(0xFFB628)), ("Purple", hex(0xA977D1))]
    static let scales: [(String, RGBA, RGBA)] = [
        ("White – Green", hex(0xFFFFFF), hex(0x63BE7B)), ("Red – Green", hex(0xF8696B), hex(0x63BE7B)),
        ("Green – Red", hex(0x63BE7B), hex(0xF8696B)), ("White – Red", hex(0xFFFFFF), hex(0xF8696B)),
        ("White – Blue", hex(0xFFFFFF), hex(0x5A8AC6)),
    ]
}

// MARK: - Data

extension TableData {
    /// Keeps rules on their cells when a row (rows: true) or column is inserted (+1) or removed (-1).
    mutating func shiftConditionalRules(rows: Bool, at index: Int, by delta: Int) {
        guard let rules = conditionalRules else { return }
        let rowLimit = self.rows.count
        let moved: [ConditionalRule] = rules.compactMap { rule in
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
            }
            return r
        }
        conditionalRules = moved.isEmpty ? nil : moved
    }
}

// MARK: - Model

extension TableModel {
    var hasConditionalRules: Bool { !(data.conditionalRules ?? []).isEmpty }

    func addConditionalRule(_ rule: ConditionalRule) {
        data.conditionalRules = (data.conditionalRules ?? []) + [rule]
        changed()
    }

    func removeConditionalRule(_ id: UUID) {
        let rest = (data.conditionalRules ?? []).filter { $0.id != id }
        data.conditionalRules = rest.isEmpty ? nil : rest
        changed()
    }

    /// Removes rules touching the cells (all of them when nil).
    func clearConditionalRules(in cells: Set<CellRef>?) {
        guard let cells else {
            data.conditionalRules = nil
            return changed()
        }
        let rest = (data.conditionalRules ?? []).filter { rule in !cells.contains { rule.covers($0, rowCount: rowCount) } }
        data.conditionalRules = rest.isEmpty ? nil : rest
        changed()
    }

    /// Numbers (and dates) in a rule's cells (worked out once per change).
    private func numbers(in rule: ConditionalRule) -> [Double] {
        if let cached = conditionalNumbers[rule.id] { return cached }
        let list = cells(of: rule).compactMap { cell -> Double? in
            switch value(cell) {
            case .number(let d), .date(let d): return d
            default: return nil
            }
        }
        conditionalNumbers[rule.id] = list
        return list
    }

    /// How often each shown value appears in a rule's cells (for duplicates).
    private func counts(in rule: ConditionalRule) -> [String: Int] {
        if let cached = conditionalCounts[rule.id] { return cached }
        var counts: [String: Int] = [:]
        for cell in cells(of: rule) {
            let key = shownString(cell).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !key.isEmpty { counts[key, default: 0] += 1 }
        }
        conditionalCounts[rule.id] = counts
        return counts
    }

    private func cells(of rule: ConditionalRule) -> [CellRef] {
        let last = min(rule.lastRow ?? rowCount - 1, rowCount - 1)
        guard rule.firstRow <= last, rule.firstColumn < columnCount else { return [] }
        var result: [CellRef] = []
        for r in rule.firstRow...last {
            for c in rule.firstColumn...min(rule.lastColumn, columnCount - 1) {
                let cell = CellRef(row: r, column: c)
                if master(cell) == cell { result.append(cell) }
            }
        }
        return result
    }

    /// A cell's look from the rules that apply (the first rule to set something wins, as in Excel).
    func conditionalStyle(_ cell: CellRef) -> ConditionalStyle? {
        guard let rules = data.conditionalRules, !rules.isEmpty else { return nil }
        var style = ConditionalStyle()
        var matched = false
        let v = value(cell)
        let number: Double? = { switch v { case .number(let d), .date(let d): return d; default: return nil } }()
        let shown = shownString(cell).trimmingCharacters(in: .whitespacesAndNewlines)
        for rule in rules where rule.covers(cell, rowCount: rowCount) {
            let hit: Bool
            switch rule.kind {
            case .greater: hit = number.map { $0 > (Formula.numeric(rule.value1) ?? .infinity) } ?? false
            case .less: hit = number.map { $0 < (Formula.numeric(rule.value1) ?? -.infinity) } ?? false
            case .between:
                let a = Formula.numeric(rule.value1) ?? .nan, b = Formula.numeric(rule.value2) ?? .nan
                hit = number.map { $0 >= min(a, b) && $0 <= max(a, b) } ?? false
            case .equal, .notEqual:
                let same: Bool
                if let x = number, let y = Formula.numeric(rule.value1) { same = x == y } else {
                    same = shown.caseInsensitiveCompare(rule.value1.trimmingCharacters(in: .whitespaces)) == .orderedSame
                }
                hit = rule.kind == .equal ? same : !same && !shown.isEmpty
            case .contains: hit = !rule.value1.isEmpty && shown.localizedCaseInsensitiveContains(rule.value1)
            case .blank: hit = shown.isEmpty
            case .notBlank: hit = !shown.isEmpty
            case .top, .bottom:
                guard let x = number else { hit = false; break }
                let n = max(1, Int(Formula.numeric(rule.value1) ?? 10))
                let sorted = numbers(in: rule).sorted(by: rule.kind == .top ? (>) : (<))
                guard !sorted.isEmpty else { hit = false; break }
                let threshold = sorted[min(n, sorted.count) - 1]
                hit = rule.kind == .top ? x >= threshold : x <= threshold
            case .aboveAverage, .belowAverage:
                let list = numbers(in: rule)
                guard let x = number, !list.isEmpty else { hit = false; break }
                let average = list.reduce(0, +) / Double(list.count)
                hit = rule.kind == .aboveAverage ? x > average : x < average
            case .duplicate, .unique:
                guard !shown.isEmpty else { hit = false; break }
                let count = counts(in: rule)[shown.lowercased()] ?? 0
                hit = rule.kind == .duplicate ? count > 1 : count == 1
            case .dataBar, .colorScale:
                let list = numbers(in: rule)
                guard let x = number, let lo = list.min(), let hi = list.max() else { hit = false; break }
                if rule.kind == .dataBar {
                    // Bars start at zero for positive numbers (as in Excel).
                    let base = min(0, lo)
                    let fraction = hi > base ? (x - base) / (hi - base) : 1
                    if style.bar == nil {
                        style.bar = (CGFloat(max(0.02, min(1, fraction))), (rule.low ?? HighlightStyle.barColors[0].1).nsColor)
                    }
                } else if style.fill == nil {
                    let t = hi > lo ? (x - lo) / (hi - lo) : 0.5
                    let a = rule.low ?? HighlightStyle.scales[0].1, b = rule.high ?? HighlightStyle.scales[0].2
                    style.fill = RGBA(r: a.r + (b.r - a.r) * t, g: a.g + (b.g - a.g) * t, b: a.b + (b.b - a.b) * t).nsColor
                }
                matched = true
                continue
            }
            guard hit else { continue }
            matched = true
            if style.fill == nil, let fill = rule.fill { style.fill = fill.nsColor }
            if style.textColor == nil, let text = rule.textColor { style.textColor = text.nsColor }
            if rule.bold { style.bold = true }
        }
        return matched ? style : nil
    }
}

// MARK: - Popover

/// Conditional Formatting: a new rule for the selected cells, and the table's rules.
struct ConditionalFormatView: View {
    let rangeName: String
    let rules: [ConditionalRule]
    let rowCount: Int
    let add: (ConditionalRule.Kind, String, String, HighlightStyle?, RGBA?, RGBA?) -> Void
    let delete: (UUID) -> Void
    let close: () -> Void

    @State private var kind: ConditionalRule.Kind = .greater
    @State private var value1 = ""
    @State private var value2 = ""
    @State private var style = HighlightStyle.presets[0]
    @State private var bar = 0
    @State private var scale = 0
    @State private var list: [ConditionalRule]

    init(rangeName: String, rules: [ConditionalRule], rowCount: Int,
         add: @escaping (ConditionalRule.Kind, String, String, HighlightStyle?, RGBA?, RGBA?) -> Void,
         delete: @escaping (UUID) -> Void, close: @escaping () -> Void) {
        self.rangeName = rangeName
        self.rules = rules
        self.rowCount = rowCount
        self.add = add
        self.delete = delete
        self.close = close
        _list = State(initialValue: rules)
    }

    private var ready: Bool {
        switch kind.valueCount {
        case 2: !value1.isEmpty && !value2.isEmpty
        case 1: !value1.isEmpty
        default: true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Conditional Formatting — \(rangeName)").font(.headline)
            Picker("Format cells:", selection: $kind) {
                ForEach(ConditionalRule.Kind.allCases) { Text($0.title).tag($0) }
            }
            if kind.valueCount > 0 {
                HStack {
                    TextField(kind == .top || kind == .bottom ? "Number of items (10)" : kind == .contains ? "Text" : "Value",
                              text: $value1)
                    if kind.valueCount == 2 {
                        Text("and")
                        TextField("Value", text: $value2)
                    }
                }
                .textFieldStyle(.roundedBorder)
            }
            switch kind {
            case .dataBar:
                Picker("Bar color:", selection: $bar) {
                    ForEach(HighlightStyle.barColors.indices, id: \.self) { Text(HighlightStyle.barColors[$0].0).tag($0) }
                }
            case .colorScale:
                Picker("Colors:", selection: $scale) {
                    ForEach(HighlightStyle.scales.indices, id: \.self) { Text(HighlightStyle.scales[$0].0).tag($0) }
                }
            default:
                Picker("With:", selection: $style) {
                    ForEach(HighlightStyle.presets) { Text($0.name).tag($0) }
                }
            }
            HStack {
                Spacer()
                Button("Close", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Rule") {
                    switch kind {
                    case .dataBar: add(kind, "", "", nil, HighlightStyle.barColors[bar].1, nil)
                    case .colorScale: add(kind, "", "", nil, HighlightStyle.scales[scale].1, HighlightStyle.scales[scale].2)
                    default: add(kind, value1, value2, style, nil, nil)
                    }
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!ready)
            }
            if !list.isEmpty {
                Divider()
                Text("Rules in this table").font(.subheadline.weight(.semibold))
                ForEach(list) { rule in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(rule.summary)
                            Text(rule.rangeName(rowCount: rowCount)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            delete(rule.id)
                            list.removeAll { $0.id == rule.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Delete Rule")
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}
