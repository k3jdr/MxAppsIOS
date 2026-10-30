//
//  TableFill.swift
//  MxNoteONE
//
//  Fill Down, Up, Right and Left, as in Excel: the first row (or column) of the
//  selected block is copied into the rest — formulas with their relative
//  references moved along (=B2*C2 becomes =B3*C3; $ parts stay), with the
//  cells' formatting, number formats, shading, validation and conditional
//  formatting. Dragging the fill handle (the square at the selection's corner)
//  continues series as well (see TableFillSeries.swift), and Auto Fill Options
//  redoes that fill another way.
//

import AppKit

/// A rule that covers a block of cells.
protocol CellRangeRule {
    var firstRow: Int { get set }
    var lastRow: Int? { get set }
    var firstColumn: Int { get set }
    var lastColumn: Int { get set }
}

extension ValidationRule: CellRangeRule {}
extension ConditionalRule: CellRangeRule {}

extension TableModel {
    /// Fills along rows (down or up) or columns (right or left): `targets` get the `sources` (repeated in turn), at
    /// each `lanes` position (the columns of a fill down, the rows of a fill right). Both run in the fill's direction,
    /// so a fill up lists its sources and targets from the bottom. `content` and `formatting` choose what goes across.
    /// Returns whether a series was continued.
    @discardableResult
    func fill(down: Bool, sources: [Int], targets: [Int], lanes: [Int], series: FillSeries.Level, content: Bool = true, formatting: Bool = true) -> Bool {
        guard !sources.isEmpty else { return false }
        func cell(_ position: Int, _ lane: Int) -> CellRef {
            down ? CellRef(row: position, column: lane) : CellRef(row: lane, column: position)
        }
        var continued = false
        for lane in lanes {
            let continuation = content ? FillSeries.continuation(of: sources.map { text(cell($0, lane)) },
                                                                 values: sources.map { value(cell($0, lane)) }, level: series,
                                                                 backward: (targets.first ?? 0) < (sources.first ?? 0)) : nil
            if continuation != nil { continued = true }
            for (k, position) in targets.enumerated() {
                let target = cell(position, lane)
                let sourcePosition = sources[k % sources.count]
                let source = cell(sourcePosition, lane)
                guard contains(target), master(target) == target, master(source) == source else { continue }
                let stored = storedText(source)
                let attrs = stored.length > 0 ? stored.attributes(at: 0, effectiveRange: nil) : typingAttributes(target)
                let raw = stored.string
                let own = storedText(target)
                var newText: NSAttributedString
                if !content {
                    // Formatting only: the target's text in the source's look.
                    let restyled = NSMutableAttributedString(attributedString: own)
                    let all = NSRange(location: 0, length: restyled.length)
                    restyled.removeAttribute(.foregroundColor, range: all)
                    restyled.addAttributes(attrs, range: all)
                    newText = restyled
                } else if let continuation {
                    newText = NSAttributedString(string: continuation(k), attributes: attrs)
                } else if Formula.isFormula(raw) {
                    let moved = down ? Formula.offset(raw, rows: position - sourcePosition, columns: 0)
                                     : Formula.offset(raw, rows: 0, columns: position - sourcePosition)
                    newText = NSAttributedString(string: moved, attributes: attrs)
                } else {
                    newText = stored
                }
                if !formatting {
                    newText = NSAttributedString(string: newText.string, attributes: own.length > 0 ? own.attributes(at: 0, effectiveRange: nil) : typingAttributes(target))
                }
                store(newText, in: target)
                guard formatting else { continue }
                // Formatting goes with the copy: font and alignment (an empty source has them too), number format
                // and shading.
                setCellFont(cellFont(source), [target])
                setCellAlign(cellAlign(source) ?? .left, [target])
                var formats = data.numberFormats ?? [:]
                formats[TableData.key(target)] = numberFormat(source)
                data.numberFormats = formats.isEmpty ? nil : formats
                if data.shading != nil {
                    data.padShading()
                    data.shading![target.row][target.column] = data.shading![source.row][source.column]
                }
            }
        }
        if formatting {
            data.validationRules = extended(data.validationRules, down: down, sources: sources, targets: targets, lanes: lanes)
            data.conditionalRules = extended(data.conditionalRules, down: down, sources: sources, targets: targets, lanes: lanes)
        }
        changed()
        return continued
    }

    /// Rules on the source cells reach as far as the fill went (a rule also on cells outside the filled lanes stays).
    private func extended<Rule: CellRangeRule>(_ rules: [Rule]?, down: Bool, sources: [Int], targets: [Int], lanes: [Int]) -> [Rule]? {
        guard let low = lanes.min(), let high = lanes.max(), let from = (sources + targets).min(), let to = (sources + targets).max() else { return rules }
        return rules?.map { original in
            var rule = original
            let lastRow = rule.lastRow ?? rowCount - 1
            if down {
                guard rule.firstColumn >= low, rule.lastColumn <= high, sources.contains(where: { $0 >= rule.firstRow && $0 <= lastRow }) else { return rule }
                rule.firstRow = min(rule.firstRow, from)
                if rule.lastRow != nil { rule.lastRow = max(lastRow, to) }
            } else {
                guard rule.firstRow >= low, lastRow <= high, sources.contains(where: { $0 >= rule.firstColumn && $0 <= rule.lastColumn }) else { return rule }
                rule.firstColumn = min(rule.firstColumn, from)
                rule.lastColumn = max(rule.lastColumn, to)
            }
            return rule
        }
    }

    /// Whether a block can be filled (not across cells merged with others).
    func canFill(rows: ClosedRange<Int>, columns: ClosedRange<Int>) -> Bool {
        !(data.merges ?? []).contains { m in
            m.row <= rows.upperBound && rows.lowerBound < m.row + m.rows && m.column <= columns.upperBound && columns.lowerBound < m.column + m.columns
        }
    }
}
