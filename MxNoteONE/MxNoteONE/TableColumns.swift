//
//  TableColumns.swift
//  MxNoteONE
//
//  Excel-style columns for tables: a column header bar (A, B, C…) above the
//  table while you work in it — click a letter to select the column, ⇧-click
//  or drag to select several, right-click for column commands — hiding and
//  showing columns, and filters: buttons on the first row with sorting, a
//  search box and a checklist of the column's values. A row number bar on the
//  left does the same for rows: select, hide and show them.
//

import AppKit
import SwiftUI

// MARK: - Data

extension TableData {
    /// Keeps hidden columns and filters on their columns when a column is inserted (+1) or removed (-1).
    mutating func shiftColumns(at index: Int, by delta: Int) {
        shiftFormulas(rows: false, at: index, by: delta)
        moveNumberFormats(rows: false, at: index, by: delta)
        moveTags(rows: false, at: index, by: delta)
        shiftConditionalRules(rows: false, at: index, by: delta)
        shiftValidationRules(rows: false, at: index, by: delta)
        if var hidden = hiddenColumns {
            if delta < 0 { hidden.removeAll { $0 == index } }
            hidden = hidden.map { $0 >= index + (delta < 0 ? 1 : 0) ? $0 + delta : $0 }
            hiddenColumns = hidden.isEmpty ? nil : hidden
        }
        if var list = filters {
            if delta < 0 { list.removeAll { $0.column == index } }
            list = list.map { var f = $0; if f.column >= index + (delta < 0 ? 1 : 0) { f.column += delta }; return f }
            filters = list.isEmpty ? nil : list
        }
    }

    /// Formulas' references follow a row or column inserted (+1) or removed (-1), as in Excel.
    mutating func shiftFormulas(rows: Bool, at index: Int, by delta: Int) {
        for r in self.rows.indices {
            for c in self.rows[r].indices where Formula.isFormula(self.rows[r][c]) {
                setFormula(Formula.shift(self.rows[r][c], rows: rows, at: index, by: delta), r, c)
            }
        }
    }

    /// After rows are put in a new order, formulas that moved take their relative row references along.
    mutating func offsetMovedFormulas(_ order: [Int]) {
        for (new, old) in order.enumerated() where new != old && rows.indices.contains(new) {
            for c in rows[new].indices where Formula.isFormula(rows[new][c]) {
                setFormula(Formula.offset(rows[new][c], rows: new - old), new, c)
            }
        }
    }

    /// Replaces a formula's text, keeping the cell's formatting.
    private mutating func setFormula(_ formula: String, _ r: Int, _ c: Int) {
        guard formula != rows[r][c] else { return }
        rows[r][c] = formula
        if let data = richData(r, c), let text = TableData.attributedCell(data) {
            let attrs = text.length > 0 ? text.attributes(at: 0, effectiveRange: nil) : [:]
            rich![r][c] = TableData.cellData(NSAttributedString(string: formula, attributes: attrs))
        }
    }

    static func key(_ cell: CellRef) -> String { "\(cell.row),\(cell.column)" }

    static func cell(_ key: String) -> CellRef? {
        let parts = key.split(separator: ",").compactMap { Int($0) }
        return parts.count == 2 ? CellRef(row: parts[0], column: parts[1]) : nil
    }

    /// Keeps number formats on their cells when a row or column is inserted (+1) or removed (-1).
    mutating func moveNumberFormats(rows: Bool, at index: Int, by delta: Int) {
        guard let formats = numberFormats else { return }
        var moved: [String: NumberFormat] = [:]
        for (key, format) in formats {
            guard var cell = Self.cell(key) else { continue }
            let value = rows ? cell.row : cell.column
            if delta < 0 && value == index { continue }
            if value >= index + (delta < 0 ? 1 : 0) {
                if rows { cell.row += delta } else { cell.column += delta }
            }
            moved[Self.key(cell)] = format
        }
        numberFormats = moved.isEmpty ? nil : moved
    }

    /// Keeps filtered and hidden rows hidden when a row is inserted (+1) or removed (-1).
    mutating func shiftRows(at index: Int, by delta: Int) {
        shiftFormulas(rows: true, at: index, by: delta)
        func shifted(_ list: [Int]?) -> [Int]? {
            guard var rows = list else { return nil }
            if delta < 0 { rows.removeAll { $0 == index } }
            rows = rows.map { $0 >= index + (delta < 0 ? 1 : 0) ? $0 + delta : $0 }
            return rows.isEmpty ? nil : rows
        }
        filteredRows = shifted(filteredRows)
        hiddenRows = shifted(hiddenRows)
        moveNumberFormats(rows: true, at: index, by: delta)
        moveTags(rows: true, at: index, by: delta)
        shiftConditionalRules(rows: true, at: index, by: delta)
        shiftValidationRules(rows: true, at: index, by: delta)
        if let heights = rowHeightOverrides {
            var moved: [Int: Double] = [:]
            for (r, h) in heights where !(delta < 0 && r == index) {
                moved[r >= index + (delta < 0 ? 1 : 0) ? r + delta : r] = h
            }
            rowHeightOverrides = moved.isEmpty ? nil : moved
        }
    }

    /// Keeps filtered and hidden rows hidden when rows are put in a new order (new index of each old row).
    mutating func remapRows(_ newIndex: [Int]) {
        func mapped(_ list: [Int]?) -> [Int]? {
            list.map { $0.compactMap { newIndex.indices.contains($0) ? newIndex[$0] : nil }.sorted() }
        }
        filteredRows = mapped(filteredRows)
        hiddenRows = mapped(hiddenRows)
        if let formats = numberFormats {
            var moved: [String: NumberFormat] = [:]
            for (key, format) in formats {
                guard let cell = Self.cell(key), newIndex.indices.contains(cell.row) else { continue }
                moved[Self.key(CellRef(row: newIndex[cell.row], column: cell.column))] = format
            }
            numberFormats = moved.isEmpty ? nil : moved
        }
        if let heights = rowHeightOverrides {
            var moved: [Int: Double] = [:]
            for (r, h) in heights where newIndex.indices.contains(r) { moved[newIndex[r]] = h }
            rowHeightOverrides = moved.isEmpty ? nil : moved
        }
        // Tags go with their rows when rows are sorted or moved.
        if let tags = rowTags {
            var moved: [Int: [String]] = [:]
            for (r, t) in tags where newIndex.indices.contains(r) { moved[newIndex[r]] = t }
            rowTags = moved.isEmpty ? nil : moved
        }
        if let tags = cellTags {
            var moved: [String: [String]] = [:]
            for (key, t) in tags {
                guard let cell = Self.cell(key), newIndex.indices.contains(cell.row) else { continue }
                moved[Self.key(CellRef(row: newIndex[cell.row], column: cell.column))] = t
            }
            cellTags = moved.isEmpty ? nil : moved
        }
    }

    /// Keeps row and cell tags on their rows and cells when a row or column is inserted (+1) or removed (-1).
    mutating func moveTags(rows: Bool, at index: Int, by delta: Int) {
        if rows, let tags = rowTags {
            var moved: [Int: [String]] = [:]
            for (r, t) in tags where !(delta < 0 && r == index) {
                moved[r >= index + (delta < 0 ? 1 : 0) ? r + delta : r] = t
            }
            rowTags = moved.isEmpty ? nil : moved
        }
        guard let tags = cellTags else { return }
        var moved: [String: [String]] = [:]
        for (key, t) in tags {
            guard var cell = Self.cell(key) else { continue }
            let value = rows ? cell.row : cell.column
            if delta < 0 && value == index { continue }
            if value >= index + (delta < 0 ? 1 : 0) {
                if rows { cell.row += delta } else { cell.column += delta }
            }
            moved[Self.key(cell)] = t
        }
        cellTags = moved.isEmpty ? nil : moved
    }

    /// Tags written as typed: "#Weekly, totals  q3" → ["weekly", "totals", "q3"].
    static func parseTags(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" }).map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "#").union(.whitespaces)).lowercased()
        }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Spreadsheet-style column name: A…Z, AA, AB…
    static func columnName(_ index: Int) -> String {
        var n = index + 1
        var name = ""
        while n > 0 {
            let r = (n - 1) % 26
            name = String(UnicodeScalar(65 + r)!) + name
            n = (n - 1) / 26
        }
        return name
    }
}

// MARK: - Model

extension TableModel {
    // MARK: Number formats

    func numberFormat(_ cell: CellRef) -> NumberFormat? { data.numberFormats?[TableData.key(master(cell))] }

    func setNumberFormat(_ format: NumberFormat?, cells: Set<CellRef>) {
        var formats = data.numberFormats ?? [:]
        for cell in cells { formats[TableData.key(master(cell))] = format }
        data.numberFormats = formats.isEmpty ? nil : formats
        changed()
    }

    /// A number as the cell's format shows it (nil for General).
    func formatted(_ number: Double, in cell: CellRef) -> String? {
        numberFormat(cell)?.string(number)
    }

    var hasFormulas: Bool { data.rows.contains { $0.contains(where: Formula.isFormula) } }

    func isColumnHidden(_ column: Int) -> Bool { data.hiddenColumns?.contains(column) ?? false }
    /// Hidden by a filter or with Hide Row.
    func isRowHidden(_ row: Int) -> Bool {
        (data.filteredRows?.contains(row) ?? false) || (data.hiddenRows?.contains(row) ?? false)
    }

    var hasHiddenRows: Bool { !(data.hiddenRows ?? []).isEmpty }

    /// A row's height set by dragging its border (nil = fits its content).
    func manualHeight(_ row: Int) -> CGFloat? { data.rowHeightOverrides?[row].map { CGFloat($0) } }

    func setManualHeight(_ height: CGFloat?, row: Int) {
        var heights = data.rowHeightOverrides ?? [:]
        heights[row] = height.map(Double.init)
        data.rowHeightOverrides = heights.isEmpty ? nil : heights
    }

    /// Rows inside a block merged across rows can't be hidden, and one row must stay.
    func canHideRows(_ rows: [Int]) -> Bool {
        let shown = (0..<rowCount).filter { !isRowHidden($0) }
        guard !rows.isEmpty, shown.count > Set(rows).intersection(shown).count else { return false }
        return !(data.merges ?? []).contains { span in span.rows > 1 && rows.contains { span.row <= $0 && $0 < span.row + span.rows } }
    }

    func hideRows(_ rows: [Int]) {
        guard canHideRows(rows) else { return NSSound.beep() }
        data.hiddenRows = Array(Set(data.hiddenRows ?? []).union(rows)).sorted()
        changed()
    }

    /// Shows rows hidden with Hide Row again (all of them when nil).
    func unhideRows(_ rows: [Int]? = nil) {
        guard let hidden = data.hiddenRows else { return }
        let rest = rows.map { r in hidden.filter { !r.contains($0) } } ?? []
        data.hiddenRows = rest.isEmpty ? nil : rest
        changed()
    }

    /// Whether a cell shows (its row and column aren't hidden).
    func isShown(_ cell: CellRef) -> Bool { !isRowHidden(cell.row) && !isColumnHidden(cell.column) }

    var hasHiddenColumns: Bool { !(data.hiddenColumns ?? []).isEmpty }
    var shownColumns: [Int] { (0..<columnCount).filter { !isColumnHidden($0) } }

    /// The nearest shown row from a row, going up (-1) or down (+1); nil past the table's top or bottom.
    func shownRow(from row: Int, step: Int) -> Int? {
        var r = row
        while r >= 0, r < rowCount {
            if !isRowHidden(r) { return r }
            r += step
        }
        return nil
    }

    /// The nearest shown column from a column, going left (-1) or right (+1).
    func shownColumn(from column: Int, step: Int) -> Int? {
        var c = column
        while c >= 0, c < columnCount {
            if !isColumnHidden(c) { return c }
            c += step
        }
        return nil
    }

    /// Columns inside a block merged across columns can't be hidden.
    func canHide(_ columns: [Int]) -> Bool {
        guard !columns.isEmpty, shownColumns.count > Set(columns).count else { return false }
        return !(data.merges ?? []).contains { span in span.columns > 1 && columns.contains { span.column <= $0 && $0 < span.column + span.columns } }
    }

    /// Hides columns; the table gets narrower by their width.
    func hideColumns(_ columns: [Int]) {
        let columns = columns.filter { !isColumnHidden($0) }
        guard canHide(columns) else { return NSSound.beep() }
        let removed = columns.reduce(0) { $0 + columnWidth($1) }
        freezeColumnWidths()
        data.hiddenColumns = Array(Set(data.hiddenColumns ?? []).union(columns)).sorted()
        onWidthChange?(-removed)
        changed()
    }

    /// Shows hidden columns again (all of them when nil); the table gets wider by their width.
    func unhideColumns(_ columns: [Int]? = nil) {
        let hidden = data.hiddenColumns ?? []
        let showing = columns.map { Set($0).intersection(hidden) } ?? Set(hidden)
        guard !showing.isEmpty else { return }
        freezeColumnWidths()
        let added = showing.reduce(0) { $0 + CGFloat(data.columnWidths.indices.contains($1) ? data.columnWidths[$1] : 80) }
        let rest = hidden.filter { !showing.contains($0) }
        data.hiddenColumns = rest.isEmpty ? nil : rest
        onWidthChange?(added)
        changed()
    }

    // MARK: Filters

    var filterOn: Bool { data.autoFilter ?? false }

    func filter(for column: Int) -> ColumnFilter? { data.filters?.first { $0.column == column } }

    func isFiltered(_ column: Int) -> Bool {
        filter(for: column)?.isActive ?? false
    }

    /// Filter buttons on the first row (turning them off shows every row again).
    func toggleAutoFilter() {
        if filterOn {
            data.autoFilter = nil
            data.filters = nil
            data.filteredRows = nil
        } else {
            data.autoFilter = true
        }
        changed()
    }

    /// The first row is the header the filters sit on; it's never filtered.
    var filterRows: Range<Int> { min(1, rowCount)..<rowCount }

    static func filterValue(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The column's different values, sorted ("" for blank cells).
    func values(in column: Int) -> [String] {
        let all = Set(filterRows.map { Self.filterValue(shownString(master(CellRef(row: $0, column: column)))) })
        return all.sorted { $0.isEmpty != $1.isEmpty ? !$0.isEmpty : $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func setFilter(_ filter: ColumnFilter) {
        var list = (data.filters ?? []).filter { $0.column != filter.column }
        if filter.isActive { list.append(filter) }
        data.filters = list.isEmpty ? nil : list
        data.autoFilter = true
        applyFilters()
        changed()
    }

    func clearFilter(_ column: Int) {
        setFilter(ColumnFilter(column: column))
    }

    func clearAllFilters() {
        data.filters = nil
        data.filteredRows = nil
        changed()
    }

    // MARK: Colours (sort and filter by colour)

    /// A cell's fill as shown — conditional formatting, else its shading — as hex ("none" without one).
    func fillHex(_ cell: CellRef) -> String {
        let color = conditionalStyle(cell)?.fill ?? data.shading.flatMap { s in
            s.indices.contains(cell.row) && s[cell.row].indices.contains(cell.column) ? s[cell.row][cell.column]?.nsColor : nil
        }
        return color.map(RecentColors.hex) ?? "none"
    }

    /// A cell's font colour — conditional formatting, else its text's own colour — as hex ("auto" when automatic).
    func fontHex(_ cell: CellRef) -> String {
        if let color = conditionalStyle(cell)?.textColor { return RecentColors.hex(color) }
        let text = storedText(cell)
        guard text.length > 0, let color = text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
              !Self.isBlack(color) else { return "auto" }
        return RecentColors.hex(color)
    }

    /// The fill (or font) colours used in a column's rows below the header, in the order they appear.
    func colors(in column: Int, fill: Bool) -> [String] {
        var seen: [String] = []
        for r in filterRows {
            let hex = fill ? fillHex(master(CellRef(row: r, column: column))) : fontHex(master(CellRef(row: r, column: column)))
            if !seen.contains(hex) { seen.append(hex) }
        }
        return seen
    }

    static func color(hex: String) -> NSColor? {
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    /// Sort by Color: rows whose cell has the colour go to the top (or bottom), the rest keep their order.
    func sort(byColor hex: String, column: Int, fill: Bool, onTop: Bool) {
        guard canSort else { return NSSound.beep() }
        let skip = firstRowIsHeader && rowCount > 1 ? 1 : 0
        let all = Array(skip..<rowCount)
        let pinned = Set(all.filter { r in data.rows[r].contains { Formula.isFormula($0) && $0.contains(":") } })
        let body = all.filter { !pinned.contains($0) }
        let matches = { (r: Int) -> Bool in
            let cell = self.master(CellRef(row: r, column: column))
            return (fill ? self.fillHex(cell) : self.fontHex(cell)) == hex
        }
        let sorted = onTop ? body.filter(matches) + body.filter { !matches($0) } : body.filter { !matches($0) } + body.filter(matches)
        var rest = sorted.makeIterator()
        data.reorderRows(Array(0..<skip) + all.map { pinned.contains($0) ? $0 : rest.next()! })
        applyFilters()
        changed()
    }

    /// Works out which rows the filters hide.
    func applyFilters() {
        guard let filters = data.filters, !filters.isEmpty else {
            data.filteredRows = nil
            return
        }
        let hidden = filterRows.filter { r in
            filters.contains { f in
                guard f.column < columnCount else { return false }
                let value = Self.filterValue(shownString(master(CellRef(row: r, column: f.column))))
                if f.excluded.contains(value) { return true }
                if let needle = f.contains, !needle.isEmpty, !value.localizedCaseInsensitiveContains(needle) { return true }
                let cell = master(CellRef(row: r, column: f.column))
                if let fill = f.fillColor, fillHex(cell) != fill { return true }
                if let font = f.fontColor, fontHex(cell) != font { return true }
                return false
            }
        }
        data.filteredRows = hidden.isEmpty ? nil : hidden
    }
}

// MARK: - Column header bar

/// The A, B, C… bar shown above a table while you work in it.
final class TableColumnBar: NSView {
    static let height: CGFloat = 18
    weak var grid: TableGridView?
    private var anchorColumn: Int?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let grid else { return }
        let lefts = grid.columnEdges
        NSColor(srgbRed: 0.95, green: 0.95, blue: 0.95, alpha: 1).setFill()
        bounds.fill()
        let selected = grid.selectedWholeColumns
        let font = NSFont.systemFont(ofSize: 10, weight: .medium)
        for c in 0..<grid.model.columnCount where !grid.model.isColumnHidden(c) && c + 1 < lefts.count {
            let rect = NSRect(x: lefts[c], y: 0, width: lefts[c + 1] - lefts[c], height: bounds.height)
            let isSelected = selected.contains(c)
            if isSelected {
                NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
                rect.fill()
            }
            NSColor(white: 0.75, alpha: 1).setFill()
            NSRect(x: rect.maxX - 0.5, y: 0, width: 0.5, height: rect.height).fill()
            var name = TableData.columnName(c)
            if grid.model.isFiltered(c) { name += " ⏷" }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: isSelected ? NSFont.systemFont(ofSize: 10, weight: .bold) : font,
                .foregroundColor: isSelected ? NSColor.controlAccentColor : NSColor(white: 0.35, alpha: 1),
            ]
            let size = (name as NSString).size(withAttributes: attrs)
            if size.width < rect.width - 2 {
                (name as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
            }
        }
        // The frozen first column's letter stays with the column.
        if grid.stickyColumnActive, let c = grid.frozenColumn {
            let rect = NSRect(x: grid.stickyLeft, y: 0, width: grid.frozenWidth, height: bounds.height)
            let isSelected = selected.contains(c)
            NSColor(srgbRed: 0.95, green: 0.95, blue: 0.95, alpha: 1).setFill()
            rect.fill()
            if isSelected {
                NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
                rect.fill()
            }
            NSColor(white: 0.6, alpha: 1).setFill()
            NSRect(x: rect.maxX - 1, y: 0, width: 1, height: rect.height).fill()
            let name = TableData.columnName(c) + (grid.model.isFiltered(c) ? " ⏷" : "")
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: isSelected ? .bold : .medium),
                .foregroundColor: isSelected ? NSColor.controlAccentColor : NSColor(white: 0.35, alpha: 1),
            ]
            let size = (name as NSString).size(withAttributes: attrs)
            (name as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
        }
        // Hidden columns: a double line where they are (click it to show them).
        for edge in hiddenEdges() {
            NSColor(white: 0.45, alpha: 1).setFill()
            NSRect(x: edge.x - 2, y: 2, width: 1, height: bounds.height - 4).fill()
            NSRect(x: edge.x + 1, y: 2, width: 1, height: bounds.height - 4).fill()
        }
        NSColor(white: 0.75, alpha: 1).setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 0.25, dy: 0.25)).stroke()
    }

    /// Where runs of hidden columns are, and which columns they are.
    private func hiddenEdges() -> [(x: CGFloat, columns: [Int])] {
        guard let grid else { return [] }
        let lefts = grid.columnEdges
        var result: [(CGFloat, [Int])] = []
        var run: [Int] = []
        for c in 0..<grid.model.columnCount {
            if grid.model.isColumnHidden(c) {
                run.append(c)
            } else if !run.isEmpty {
                result.append((lefts[c], run))
                run = []
            }
        }
        if !run.isEmpty { result.append((lefts.last ?? 0, run)) }
        return result
    }

    /// The column whose right border is at x (shown columns only).
    func border(at x: CGFloat) -> Int? {
        guard let grid else { return nil }
        let lefts = grid.columnEdges
        return (0..<grid.model.columnCount).first { c in
            !grid.model.isColumnHidden(c) && c + 1 < lefts.count && abs(lefts[c + 1] - x) <= 3
        }
    }

    /// The hidden columns whose mark is at x.
    func hiddenColumns(atX x: CGFloat) -> [Int]? {
        hiddenEdges().first { abs($0.x - x) <= 4 }?.columns
    }

    private func column(at x: CGFloat) -> Int? {
        guard let grid else { return nil }
        if grid.stickyColumnActive, x >= grid.stickyLeft, x < grid.stickyLeft + grid.frozenWidth { return grid.frozenColumn }
        let lefts = grid.columnEdges
        for c in 0..<grid.model.columnCount where !grid.model.isColumnHidden(c) && c + 1 < lefts.count {
            if x >= lefts[c] && x < lefts[c + 1] { return c }
        }
        return grid.model.shownColumns.last
    }

    override func mouseDown(with event: NSEvent) {
        guard let grid, let window else { return }
        let p = convert(event.locationInWindow, from: nil)
        if let columns = hiddenColumns(atX: p.x) {
            grid.unhideColumns(columns)
            return
        }
        // Column borders: drag to resize, double-click to fit the contents.
        if let border = border(at: p.x) {
            if event.clickCount == 2 { grid.autoFitColumns(near: border) } else { grid.beginColumnResize(border, from: event) }
            return
        }
        guard let start = column(at: p.x) else { return }
        let from = event.modifierFlags.contains(.shift) ? (anchorColumn ?? start) : start
        if !event.modifierFlags.contains(.shift) { anchorColumn = start }
        grid.selectColumns(from, start)
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: NSEvent.foreverDuration,
                           mode: .eventTracking) { ev, stop in
            guard let ev, ev.type == .leftMouseDragged else {
                stop.pointee = true
                return
            }
            if let c = self.column(at: self.convert(ev.locationInWindow, from: nil).x) { grid.selectColumns(from, c) }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let grid, let c = column(at: convert(event.locationInWindow, from: nil).x) else { return nil }
        if !grid.selectedWholeColumns.contains(c) {
            anchorColumn = c
            grid.selectColumns(c, c)
        }
        return grid.columnMenu(for: c)
    }

    override func resetCursorRects() {
        guard let grid else { return }
        let lefts = grid.columnEdges
        for c in 0..<grid.model.columnCount where !grid.model.isColumnHidden(c) && c + 1 < lefts.count {
            addCursorRect(NSRect(x: lefts[c + 1] - 3, y: 0, width: 6, height: bounds.height), cursor: .resizeLeftRight)
        }
    }
}

// MARK: - Row number bar

/// The 1, 2, 3… bar on a table's left while you work in it; its top corner selects the whole table.
final class TableRowBar: NSView {
    weak var grid: TableGridView?
    private var anchorRow: Int?

    override var isFlipped: Bool { true }

    static func width(rows: Int) -> CGFloat { 14 + CGFloat(String(rows).count) * 7 }

    /// The corner square above the numbers (as tall as the column bar).
    private var cornerHeight: CGFloat { TableColumnBar.height }
    /// Where the corner is drawn: lower than the top while the column letters are pinned to the top of the view.
    var cornerTop: CGFloat = 0 {
        didSet { if oldValue != cornerTop { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let grid else { return }
        let tops = grid.rowEdges
        NSColor(srgbRed: 0.95, green: 0.95, blue: 0.95, alpha: 1).setFill()
        bounds.fill()
        defer { drawCorner() }
        let selected = grid.selectedWholeRowSet
        let filtered = grid.model.data.filters != nil
        for r in 0..<grid.model.rowCount where !grid.model.isRowHidden(r) && r + 1 < tops.count {
            let rect = NSRect(x: 0, y: cornerHeight + tops[r], width: bounds.width, height: tops[r + 1] - tops[r])
            let isSelected = selected.contains(r)
            if isSelected {
                NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
                rect.fill()
            }
            NSColor(white: 0.75, alpha: 1).setFill()
            NSRect(x: 0, y: rect.maxY - 0.5, width: rect.width, height: 0.5).fill()
            let name = "\(r + 1)"
            // Row numbers turn blue while a filter hides rows (as in Excel).
            let color = isSelected ? NSColor.controlAccentColor : filtered && r > 0 ? NSColor.systemBlue : NSColor(white: 0.35, alpha: 1)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: isSelected ? .bold : .medium), .foregroundColor: color,
            ]
            let size = (name as NSString).size(withAttributes: attrs)
            if size.height < rect.height {
                (name as NSString).draw(at: NSPoint(x: (rect.width - size.width) / 2, y: rect.minY + min(4, (rect.height - size.height) / 2)),
                                        withAttributes: attrs)
            }
        }
        for edge in hiddenEdges() {
            NSColor(white: 0.45, alpha: 1).setFill()
            NSRect(x: 2, y: edge.y - 2, width: bounds.width - 4, height: 1).fill()
            NSRect(x: 2, y: edge.y + 1, width: bounds.width - 4, height: 1).fill()
        }
        NSColor(white: 0.75, alpha: 1).setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 0.25, dy: 0.25)).stroke()
    }

    /// The select-all corner: a small triangle, as in Excel. A pinned header row gets its row number beside it.
    private func drawCorner() {
        if let grid, let band = grid.pinnedHeaderBand {
            let rect = NSRect(x: 0, y: cornerHeight + band.y, width: bounds.width, height: band.height)
            let isSelected = grid.selectedWholeRowSet.contains(0)
            NSColor(srgbRed: 0.95, green: 0.95, blue: 0.95, alpha: 1).setFill()
            rect.fill()
            if isSelected {
                NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
                rect.fill()
            }
            NSColor(white: 0.6, alpha: 1).setFill()
            NSRect(x: 0, y: rect.maxY - 1, width: rect.width, height: 1).fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: isSelected ? .bold : .medium),
                .foregroundColor: isSelected ? NSColor.controlAccentColor : NSColor(white: 0.35, alpha: 1),
            ]
            let size = ("1" as NSString).size(withAttributes: attrs)
            ("1" as NSString).draw(at: NSPoint(x: (rect.width - size.width) / 2, y: rect.minY + min(4, (rect.height - size.height) / 2)),
                                   withAttributes: attrs)
        }
        let top = cornerTop
        NSColor(srgbRed: 0.95, green: 0.95, blue: 0.95, alpha: 1).setFill()
        NSRect(x: 0, y: top, width: bounds.width, height: cornerHeight).fill()
        let corner = NSBezierPath()
        corner.move(to: NSPoint(x: bounds.width - 3, y: top + cornerHeight - 3))
        corner.line(to: NSPoint(x: bounds.width - 3, y: top + 4))
        corner.line(to: NSPoint(x: bounds.width - cornerHeight + 4, y: top + cornerHeight - 3))
        corner.close()
        NSColor(white: 0.7, alpha: 1).setFill()
        corner.fill()
        NSColor(white: 0.75, alpha: 1).setFill()
        NSRect(x: 0, y: top + cornerHeight - 0.5, width: bounds.width, height: 0.5).fill()
        if top > 0 {
            NSRect(x: 0, y: top, width: bounds.width, height: 0.5).fill()
        }
    }

    /// Where runs of rows hidden with Hide Row are (in bar coordinates), and which rows they are.
    private func hiddenEdges() -> [(y: CGFloat, rows: [Int])] {
        guard let grid else { return [] }
        let tops = grid.rowEdges
        let hidden = Set(grid.model.data.hiddenRows ?? [])
        var result: [(CGFloat, [Int])] = []
        var run: [Int] = []
        for r in 0..<grid.model.rowCount {
            if hidden.contains(r) {
                run.append(r)
            } else if !grid.model.isRowHidden(r), !run.isEmpty {
                result.append((cornerHeight + tops[r], run))
                run = []
            }
        }
        if !run.isEmpty { result.append((cornerHeight + (tops.last ?? 0), run)) }
        return result
    }

    /// The row whose bottom border is at y (bar coordinates; shown rows only).
    func border(at y: CGFloat) -> Int? {
        guard let grid else { return nil }
        let tops = grid.rowEdges
        return (0..<grid.model.rowCount).first { r in
            !grid.model.isRowHidden(r) && r + 1 < tops.count && abs(cornerHeight + tops[r + 1] - y) <= 3
        }
    }

    /// The hidden rows whose mark is at y (bar coordinates).
    func hiddenRows(atY y: CGFloat) -> [Int]? {
        hiddenEdges().first { abs($0.y - y) <= 4 }?.rows
    }

    private func row(at y: CGFloat) -> Int? {
        guard let grid else { return nil }
        let tops = grid.rowEdges
        let y = y - cornerHeight
        for r in 0..<grid.model.rowCount where !grid.model.isRowHidden(r) && r + 1 < tops.count {
            if y >= tops[r] && y < tops[r + 1] { return r }
        }
        return y < 0 ? nil : (0..<grid.model.rowCount).last { !grid.model.isRowHidden($0) }
    }

    override func mouseDown(with event: NSEvent) {
        guard let grid, let window else { return }
        let p = convert(event.locationInWindow, from: nil)
        if p.y >= cornerTop, p.y < cornerTop + cornerHeight {
            grid.selectTable()
            return
        }
        if let rows = hiddenRows(atY: p.y) {
            grid.unhideRows(rows)
            return
        }
        // Row borders: drag to set the height, double-click to fit the contents.
        if let border = border(at: p.y) {
            if event.clickCount == 2 { grid.autoFitRows(near: border) } else { grid.beginRowResize(border, from: event) }
            return
        }
        var pinnedHeader: Int?
        if let band = grid.pinnedHeaderBand, p.y >= cornerHeight + band.y, p.y < cornerHeight + band.y + band.height { pinnedHeader = 0 }
        guard let start = pinnedHeader ?? row(at: p.y) else { return }
        let from = event.modifierFlags.contains(.shift) ? (anchorRow ?? start) : start
        if !event.modifierFlags.contains(.shift) { anchorRow = start }
        grid.selectRowRange(from, start)
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: NSEvent.foreverDuration,
                           mode: .eventTracking) { ev, stop in
            guard let ev, ev.type == .leftMouseDragged else {
                stop.pointee = true
                return
            }
            if let r = self.row(at: self.convert(ev.locationInWindow, from: nil).y) { grid.selectRowRange(from, r) }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let grid, let r = row(at: convert(event.locationInWindow, from: nil).y) else { return nil }
        if !grid.selectedWholeRowSet.contains(r) {
            anchorRow = r
            grid.selectRowRange(r, r)
        }
        return grid.rowMenu(for: r)
    }

    override func resetCursorRects() {
        guard let grid else { return }
        let tops = grid.rowEdges
        for r in 0..<grid.model.rowCount where !grid.model.isRowHidden(r) && r + 1 < tops.count {
            addCursorRect(NSRect(x: 0, y: cornerHeight + tops[r + 1] - 3, width: bounds.width, height: 6), cursor: .resizeUpDown)
        }
    }
}

// MARK: - Filter popover

/// The filter button's popover: sorting, a search box and the column's values to show.
struct TableFilterView: View {
    let title: String
    let values: [String]
    let filter: ColumnFilter
    /// The column's cell fill and font colours (hex; "none" / "auto" for none).
    let fillColors: [String]
    let fontColors: [String]
    let sort: (Bool) -> Void
    let sortByColor: (String, Bool) -> Void
    let apply: (ColumnFilter) -> Void
    let close: () -> Void

    @State private var search = ""
    @State private var shown: Set<String> = []

    init(title: String, values: [String], filter: ColumnFilter, fillColors: [String] = [], fontColors: [String] = [],
         sort: @escaping (Bool) -> Void, sortByColor: @escaping (String, Bool) -> Void = { _, _ in },
         apply: @escaping (ColumnFilter) -> Void, close: @escaping () -> Void) {
        self.title = title
        self.values = values
        self.filter = filter
        self.fillColors = fillColors
        self.fontColors = fontColors
        self.sort = sort
        self.sortByColor = sortByColor
        self.apply = apply
        self.close = close
        _shown = State(initialValue: Set(values).subtracting(filter.excluded))
        _search = State(initialValue: filter.contains ?? "")
    }

    private var matching: [String] {
        search.isEmpty ? values : values.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    private func label(_ value: String) -> String { value.isEmpty ? "(Blanks)" : value }

    /// Whether a list of colours is worth offering (more than one, or one real colour).
    private func useful(_ list: [String]) -> Bool { list.count > 1 || list.first.map { $0 != "none" && $0 != "auto" } == true }

    /// A row of colour swatches; clicking one runs the action.
    private func swatches(_ list: [String], fill: Bool, selected: String?, _ action: @escaping (String) -> Void) -> some View {
        HStack(spacing: 5) {
            Text(fill ? "Cell" : "Font").font(.caption).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
            ForEach(list, id: \.self) { hex in
                Button { action(hex) } label: {
                    Group {
                        if let color = TableModel.color(hex: hex) {
                            RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: color))
                        } else {
                            RoundedRectangle(cornerRadius: 3).strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [2]))
                                .overlay(Text(hex == "none" ? "∅" : "A").font(.system(size: 9)))
                        }
                    }
                    .frame(width: 18, height: 18)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(selected == hex ? Color.accentColor : .clear, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .help(hex == "none" ? "No Fill" : hex == "auto" ? "Automatic" : "#" + hex)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { sort(true); close() } label: { Label("Sort A to Z", systemImage: "arrow.up") }
                .buttonStyle(.borderless)
            Button { sort(false); close() } label: { Label("Sort Z to A", systemImage: "arrow.down") }
                .buttonStyle(.borderless)
            if useful(fillColors) || useful(fontColors) {
                Text("Sort by Color").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if useful(fillColors) { swatches(fillColors, fill: true, selected: nil) { sortByColor($0, true); close() } }
                if useful(fontColors) { swatches(fontColors, fill: false, selected: nil) { sortByColor($0, false); close() } }
                Text("Filter by Color").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if useful(fillColors) {
                    swatches(fillColors, fill: true, selected: filter.fillColor) {
                        var f = ColumnFilter(column: filter.column)
                        f.fillColor = $0
                        apply(f)
                        close()
                    }
                }
                if useful(fontColors) {
                    swatches(fontColors, fill: false, selected: filter.fontColor) {
                        var f = ColumnFilter(column: filter.column)
                        f.fontColor = $0
                        apply(f)
                        close()
                    }
                }
            }
            Divider()
            Button {
                apply(ColumnFilter(column: filter.column))
                close()
            } label: {
                Label("Clear Filter from “\(title)”", systemImage: "line.3.horizontal.decrease.circle")
            }
            .buttonStyle(.borderless)
            .disabled(!filter.isActive)
            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
            List {
                Toggle("(Select All)", isOn: Binding(
                    get: { matching.allSatisfy(shown.contains) },
                    set: { on in
                        if on { shown.formUnion(matching) } else { shown.subtract(matching) }
                    }))
                ForEach(matching, id: \.self) { value in
                    Toggle(label(value), isOn: Binding(
                        get: { shown.contains(value) },
                        set: { on in if on { shown.insert(value) } else { shown.remove(value) } }))
                }
            }
            .listStyle(.bordered)
            .frame(height: 180)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                Button("OK") {
                    // Search text keeps only the matching values (as in Excel).
                    let excluded = values.filter { !shown.contains($0) || (!search.isEmpty && !$0.localizedCaseInsensitiveContains(search)) }
                    apply(ColumnFilter(column: filter.column, excluded: excluded, contains: nil))
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!values.contains { shown.contains($0) && (search.isEmpty || $0.localizedCaseInsensitiveContains(search)) })
            }
        }
        .toggleStyle(.checkbox)
        .padding(12)
        .frame(width: 250)
    }
}
