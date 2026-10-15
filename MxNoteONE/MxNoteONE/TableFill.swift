//
//  TableFill.swift
//  MxNoteONE
//
//  Fill Down and Fill Right, as in Excel: the first row (or column) of the
//  selected block is copied into the rest — formulas with their relative
//  references moved along (=B2*C2 becomes =B3*C3; $ parts stay), with the
//  cells' formatting, number formats and shading. Dragging the fill handle
//  (the square at the selection's corner) continues number and date series
//  (1, 2 → 3, 4…) as well.
//

import AppKit

extension TableModel {
    /// Fills along rows (down) or columns (right): `targets` get the `sources` (repeated in turn), at each `lanes`
    /// position (the columns of a fill down, the rows of a fill right). `series` continues evenly spaced numbers.
    func fill(down: Bool, sources: [Int], targets: [Int], lanes: [Int], series: Bool) {
        guard !sources.isEmpty else { return }
        func cell(_ position: Int, _ lane: Int) -> CellRef {
            down ? CellRef(row: position, column: lane) : CellRef(row: lane, column: position)
        }
        for lane in lanes {
            // A series: the sources hold evenly spaced numbers (or dates).
            var step: Double?, first: Double?, isDate = false
            if series, sources.count >= 2 {
                let values = sources.map { value(cell($0, lane)) }
                let numbers = values.compactMap { v -> Double? in
                    switch v {
                    case .number(let d): return d
                    case .date(let d): isDate = true; return d
                    default: return nil
                    }
                }
                let typed = sources.allSatisfy { !Formula.isFormula(text(cell($0, lane))) }
                if typed, numbers.count == sources.count {
                    let d = (numbers.last! - numbers.first!) / Double(numbers.count - 1)
                    if zip(numbers, numbers.dropFirst()).allSatisfy({ abs(($1 - $0) - d) < 1e-9 * max(1, abs(d)) }) {
                        step = d
                        first = numbers.first
                    }
                }
            }
            for (k, position) in targets.enumerated() {
                let target = cell(position, lane)
                let sourcePosition = sources[k % sources.count]
                let source = cell(sourcePosition, lane)
                guard contains(target), master(target) == target, master(source) == source else { continue }
                let stored = storedText(source)
                let attrs = stored.length > 0 ? stored.attributes(at: 0, effectiveRange: nil) : typingAttributes(target)
                let raw = stored.string
                let newText: NSAttributedString
                if let step, let first {
                    let n = Double(sources.count + k)
                    let v = first + step * n
                    newText = NSAttributedString(string: isDate ? Formula.generalDate(v) : Formula.format(v), attributes: attrs)
                } else if Formula.isFormula(raw) {
                    let moved = down ? Formula.offset(raw, rows: position - sourcePosition, columns: 0)
                                     : Formula.offset(raw, rows: 0, columns: position - sourcePosition)
                    newText = NSAttributedString(string: moved, attributes: attrs)
                } else {
                    newText = stored
                }
                store(newText, in: target)
                // Formatting goes with the copy: number format and shading.
                var formats = data.numberFormats ?? [:]
                formats[TableData.key(target)] = numberFormat(source)
                data.numberFormats = formats.isEmpty ? nil : formats
                if let shading = data.shading, shading.indices.contains(source.row), shading[source.row].indices.contains(source.column) {
                    data.padShading()
                    data.shading![target.row][target.column] = shading[source.row][source.column]
                }
            }
        }
        changed()
    }

    /// Whether a block can be filled (not across cells merged with others).
    func canFill(rows: ClosedRange<Int>, columns: ClosedRange<Int>) -> Bool {
        !(data.merges ?? []).contains { m in
            m.row <= rows.upperBound && rows.lowerBound < m.row + m.rows && m.column <= columns.upperBound && columns.lowerBound < m.column + m.columns
        }
    }
}
