//
//  TableViews.swift
//  MxNoteONE
//
//  OneNote-style tables. The table draws its own cells; one rich-text
//  editor moves to the cell being typed in, so the Home ribbon (fonts,
//  bold, colours, highlight, alignment…) formats cell text, and with
//  several cells selected it formats all of them at once.
//
//  Keys: Tab next cell (adds a column while the table has one row, adds a
//  row at the end), Shift-Tab back, Return next row (adds a row at the
//  end), ⌘Return insert row, ⌥Return new line in the cell, Backspace in an
//  empty extra column / row removes it, Escape selects the cell.
//  Mouse: click to type, drag / ⇧-click / ⌘-click to select cells, drag a
//  column border to resize. Right-click or the Table ribbon tab: shading
//  for cells, rows, columns, banded rows, header row, insert / delete,
//  sort, borders.
//

import AppKit

extension NSAttributedString.Key {
    /// Marks text whose colour was chosen automatically for the cell's shading (never saved).
    static let mxAutoColor = NSAttributedString.Key("MxAutoColor")
}

/// A table cell (row, column).
struct CellRef: Hashable {
    var row: Int
    var column: Int
}

// MARK: - Table data

extension TableData {
    static func padded<T>(_ grid: [[T?]]?, rows: Int, columns: Int) -> [[T?]] {
        var result = Array((grid ?? []).prefix(rows))
        while result.count < rows { result.append([]) }
        for r in result.indices {
            result[r] = Array(result[r].prefix(columns))
            while result[r].count < columns { result[r].append(nil) }
        }
        return result
    }

    /// Makes the shading, rich-text and width arrays match the table's size.
    mutating func normalize() {
        let columns = columnCount
        for r in rows.indices where rows[r].count != columns {
            rows[r] = Array(rows[r].prefix(columns)) + Array(repeating: "", count: max(0, columns - rows[r].count))
        }
        if shading != nil { shading = Self.padded(shading, rows: rows.count, columns: columns) }
        if rich != nil { rich = Self.padded(rich, rows: rows.count, columns: columns) }
        if columnWidths.count != columns {
            let average = columnWidths.isEmpty ? 120 : columnWidths.reduce(0, +) / Double(columnWidths.count)
            columnWidths = Array(columnWidths.prefix(columns))
            while columnWidths.count < columns { columnWidths.append(average) }
        }
    }

    /// Formatted cell text from stored data (RTFD, which can hold pictures; older tables used RTF).
    static func attributedCell(_ data: Data) -> NSAttributedString? {
        NSAttributedString(rtfd: data, documentAttributes: nil) ?? NSAttributedString(rtf: data, documentAttributes: nil)
    }

    static func cellData(_ text: NSAttributedString) -> Data? {
        text.rtfd(from: NSRange(location: 0, length: text.length), documentAttributes: [:])
    }

    func richData(_ row: Int, _ column: Int) -> Data? {
        guard let rich, rich.indices.contains(row), rich[row].indices.contains(column) else { return nil }
        return rich[row][column]
    }

    mutating func insertRow(at index: Int) {
        normalize()
        let i = min(max(index, 0), rows.count)
        let columns = columnCount
        rows.insert(Array(repeating: "", count: columns), at: i)
        shading?.insert(Array(repeating: nil, count: columns), at: i)
        rich?.insert(Array(repeating: nil, count: columns), at: i)
        merges = merges?.map { span in
            var s = span
            if s.row >= i { s.row += 1 } else if i < s.row + s.rows { s.rows += 1 }
            return s
        }
    }

    /// Inserts a column; it takes the shading of the column beside it.
    mutating func insertColumn(at index: Int) {
        normalize()
        let i = min(max(index, 0), columnCount)
        let neighbor = i > 0 ? i - 1 : i
        for r in rows.indices { rows[r].insert("", at: i) }
        if shading != nil {
            for r in shading!.indices {
                let color = shading![r].indices.contains(neighbor) ? shading![r][neighbor] : nil
                shading![r].insert(color, at: i)
            }
        }
        if rich != nil { for r in rich!.indices { rich![r].insert(nil, at: i) } }
        let average = columnWidths.isEmpty ? 120 : columnWidths.reduce(0, +) / Double(columnWidths.count)
        columnWidths.insert(average, at: min(i, columnWidths.count))
        merges = merges?.map { span in
            var s = span
            if s.column >= i { s.column += 1 } else if i < s.column + s.columns { s.columns += 1 }
            return s
        }
    }

    mutating func removeRow(at index: Int) {
        normalize()
        guard rows.count > 1, rows.indices.contains(index) else { return }
        // A merged cell starting on the removed row keeps its text in the row below.
        for span in merges ?? [] where span.row == index && span.rows > 1 {
            rows[index + 1][span.column] = rows[index][span.column]
            if rich != nil { rich![index + 1][span.column] = rich![index][span.column] }
            if shading != nil { shading![index + 1][span.column] = shading![index][span.column] }
        }
        rows.remove(at: index)
        _ = shading?.remove(at: index)
        _ = rich?.remove(at: index)
        merges = merges?.compactMap { span in
            var s = span
            if s.row > index { s.row -= 1 } else if index < s.row + s.rows { s.rows -= 1 }
            return s.rows * s.columns > 1 ? s : nil
        }
        if merges?.isEmpty == true { merges = nil }
    }

    mutating func removeColumn(at index: Int) {
        normalize()
        guard columnCount > 1, index < columnCount else { return }
        for span in merges ?? [] where span.column == index && span.columns > 1 {
            rows[span.row][index + 1] = rows[span.row][index]
            if rich != nil { rich![span.row][index + 1] = rich![span.row][index] }
            if shading != nil { shading![span.row][index + 1] = shading![span.row][index] }
        }
        for r in rows.indices { rows[r].remove(at: index) }
        merges = merges?.compactMap { span in
            var s = span
            if s.column > index { s.column -= 1 } else if index < s.column + s.columns { s.columns -= 1 }
            return s.rows * s.columns > 1 ? s : nil
        }
        if merges?.isEmpty == true { merges = nil }
        if shading != nil { for r in shading!.indices { shading![r].remove(at: index) } }
        if rich != nil { for r in rich!.indices { rich![r].remove(at: index) } }
        columnWidths.remove(at: index)
    }

    /// The merged block a cell belongs to.
    func span(_ row: Int, _ column: Int) -> CellSpan? {
        merges?.first { $0.contains(row, column) }
    }

    /// The cell that holds the text of a (possibly merged) cell.
    func master(_ row: Int, _ column: Int) -> (row: Int, column: Int) {
        if let s = span(row, column) { return (s.row, s.column) }
        return (row, column)
    }

    /// True for cells hidden inside a merged block.
    func isCovered(_ row: Int, _ column: Int) -> Bool {
        guard let s = span(row, column) else { return false }
        return s.row != row || s.column != column
    }

    /// Puts the rows in a new order (indices of the old rows).
    mutating func reorderRows(_ order: [Int]) {
        normalize()
        rows = order.map { rows[$0] }
        if let shading { self.shading = order.map { shading[$0] } }
        if let rich { self.rich = order.map { rich[$0] } }
    }
}

// MARK: - Model

final class TableModel {
    var data: TableData
    var width: CGFloat
    /// Cell to continue editing in after a Tab / Return / Backspace command.
    var focusRequest: CellRef?
    /// Called when the table needs a wider (+) or narrower (-) container.
    var onWidthChange: ((CGFloat) -> Void)?
    var onChange: (() -> Void)?
    private var storedCache: [CellRef: NSAttributedString] = [:]

    init(data: TableData, width: CGFloat) {
        self.data = data
        self.data.normalize()
        self.width = width
    }

    var rowCount: Int { data.rows.count }
    var columnCount: Int { data.columnCount }

    func columnWidth(_ column: Int) -> CGFloat {
        let total = data.columnWidths.reduce(0, +)
        guard column < data.columnWidths.count, total > 0 else { return 80 }
        return max(30, width * data.columnWidths[column] / total)
    }

    func contains(_ cell: CellRef) -> Bool {
        data.rows.indices.contains(cell.row) && cell.column >= 0 && cell.column < columnCount
    }

    /// The visible cell for any cell (a merged block's top-left cell).
    func master(_ cell: CellRef) -> CellRef {
        let m = data.master(cell.row, cell.column)
        return CellRef(row: m.row, column: m.column)
    }

    func span(_ cell: CellRef) -> CellSpan {
        data.span(cell.row, cell.column) ?? CellSpan(row: cell.row, column: cell.column, rows: 1, columns: 1)
    }

    /// Visible cells in reading order.
    var visibleCells: [CellRef] {
        (0..<rowCount).flatMap { r in (0..<columnCount).compactMap { c in data.isCovered(r, c) ? nil : CellRef(row: r, column: c) } }
    }

    func text(_ cell: CellRef) -> String {
        contains(cell) ? data.rows[cell.row][cell.column] : ""
    }

    func isHeader(_ row: Int) -> Bool { data.headerRow && row == 0 }

    func baseFont(_ row: Int) -> NSFont {
        isHeader(row) ? NSFontManager.shared.convert(Prefs.defaultFont, toHaveTrait: .boldFontMask) : Prefs.defaultFont
    }

    /// Black, or white on dark shading.
    func autoColor(_ cell: CellRef) -> NSColor {
        data.textIsLight(cell.row, cell.column) ? .white : .black
    }

    /// Attributes for new text in the cell.
    func typingAttributes(_ cell: CellRef) -> [NSAttributedString.Key: Any] {
        [.font: baseFont(cell.row), .foregroundColor: autoColor(cell), .mxAutoColor: true]
    }

    /// The cell's text as saved (no automatic colour).
    func storedText(_ cell: CellRef) -> NSAttributedString {
        if let cached = storedCache[cell] { return cached }
        let result: NSAttributedString
        if let rtf = data.richData(cell.row, cell.column), let text = TableData.attributedCell(rtf) {
            result = text
        } else {
            result = NSAttributedString(string: text(cell), attributes: [.font: baseFont(cell.row)])
        }
        storedCache[cell] = result
        return result
    }

    /// The cell's text as shown: text without a chosen colour is black, or white on dark shading.
    func displayText(_ cell: CellRef) -> NSAttributedString {
        let text = NSMutableAttributedString(attributedString: storedText(cell))
        let auto = autoColor(cell)
        text.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if value == nil || Self.isBlack(value as? NSColor) {
                text.addAttributes([.foregroundColor: auto, .mxAutoColor: true], range: range)
            }
        }
        return text
    }

    /// Display text with pictures scaled down to fit the cell's width.
    func displayText(_ cell: CellRef, fitting width: CGFloat) -> NSAttributedString {
        let text = displayText(cell)
        guard text.containsAttachments(in: NSRange(location: 0, length: text.length)) else { return text }
        let fitted = NSMutableAttributedString(attributedString: text)
        fitted.enumerateAttribute(.attachment, in: NSRange(location: 0, length: fitted.length)) { value, _, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            let size = OneNoteImport.displaySize(attachment)
            if size.width > width + 0.5, width > 10 {
                OneNoteImport.resize(attachment, to: NSSize(width: width, height: size.height * width / size.width))
            }
        }
        return fitted
    }

    /// Saves edited cell text: automatic colours are dropped; rich text is kept only when there is formatting.
    func store(_ edited: NSAttributedString, in cell: CellRef) {
        guard contains(cell) else { return }
        let text = NSMutableAttributedString(attributedString: edited)
        let all = NSRange(location: 0, length: text.length)
        text.enumerateAttribute(.mxAutoColor, in: all) { value, range, _ in
            if value != nil {
                text.removeAttribute(.foregroundColor, range: range)
                text.removeAttribute(.mxAutoColor, range: range)
            }
        }
        data.rows[cell.row][cell.column] = text.string
        let rtf = Self.isPlain(text, header: isHeader(cell.row)) ? nil : TableData.cellData(text)
        if rtf != nil || data.rich != nil {
            data.rich = TableData.padded(data.rich, rows: rowCount, columns: columnCount)
            data.rich![cell.row][cell.column] = rtf
            if data.rich!.allSatisfy({ $0.allSatisfy { $0 == nil } }) { data.rich = nil }
        }
        storedCache[cell] = text
    }

    static func isBlack(_ color: NSColor?) -> Bool {
        guard let c = color?.usingColorSpace(.sRGB) else { return false }
        return c.redComponent < 0.02 && c.greenComponent < 0.02 && c.blueComponent < 0.02 && c.alphaComponent > 0.98
    }

    /// True when the text has no formatting beyond the table's default font.
    static func isPlain(_ text: NSAttributedString, header: Bool) -> Bool {
        let base = Prefs.defaultFont
        let bold = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
        let same: (NSFont, NSFont) -> Bool = { $0.fontName == $1.fontName && abs($0.pointSize - $1.pointSize) < 0.01 }
        var plain = true
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attrs, _, stop in
            for (key, value) in attrs {
                switch key {
                case .font:
                    if let font = value as? NSFont, !(same(font, base) || (header && same(font, bold))) { plain = false }
                case .foregroundColor:
                    if !isBlack(value as? NSColor) { plain = false }
                case .paragraphStyle:
                    if let style = value as? NSParagraphStyle,
                       !(style.alignment == .natural || style.alignment == .left) || style.headIndent != 0
                        || style.firstLineHeadIndent != 0 || style.lineHeightMultiple > 1.001 { plain = false }
                case .mxAutoColor:
                    break
                default:
                    plain = false
                }
            }
            if !plain { stop.pointee = true }
        }
        return plain
    }

    private func changed() {
        storedCache.removeAll()
        onChange?()
    }

    // MARK: Rows and columns

    func insertRow(at index: Int) {
        data.insertRow(at: index)
        changed()
    }

    func insertColumn(at index: Int) {
        data.insertColumn(at: index)
        changed()
    }

    func deleteRow(_ index: Int) {
        data.removeRow(at: index)
        changed()
    }

    func deleteColumn(_ index: Int) {
        data.removeColumn(at: index)
        changed()
    }

    /// Inserts a column and widens the container by one average column, so the other columns keep their size.
    func addColumn(at index: Int) {
        let extra = width / CGFloat(max(columnCount, 1))
        insertColumn(at: index)
        onWidthChange?(extra)
    }

    /// Deletes a column and narrows the container by its width.
    func removeColumn(_ index: Int) {
        guard columnCount > 1, index < columnCount else { return }
        let removed = columnWidth(index)
        deleteColumn(index)
        onWidthChange?(-removed)
    }

    /// Column widths as points (so one column can change without the others).
    func freezeColumnWidths() {
        data.columnWidths = (0..<columnCount).map { Double(columnWidth($0)) }
    }

    // MARK: OneNote-style keys

    /// Tab: next cell. In a one-row table, Tab in the filled last cell adds a column;
    /// Tab in the last cell of the last row adds a row. Shift-Tab goes back.
    func tab(from cell: CellRef, backward: Bool) {
        let rows = rowCount, columns = columnCount
        let cell = master(cell)
        let order = visibleCells
        let position = order.firstIndex(of: cell) ?? 0
        if backward {
            if position > 0 { focusRequest = order[position - 1] }
            return
        }
        let last = span(cell)
        if last.column + last.columns < columns {
            focusRequest = order[min(position + 1, order.count - 1)]
        } else if rows == 1, !text(cell).trimmingCharacters(in: .whitespaces).isEmpty {
            addColumn(at: columns)
            focusRequest = CellRef(row: 0, column: columns)
        } else if position + 1 < order.count {
            focusRequest = order[position + 1]
        } else {
            insertRow(at: rows)
            focusRequest = CellRef(row: rows, column: 0)
        }
    }

    /// Return: in the last row adds a row; elsewhere moves down. ⌘Return inserts a row below.
    func newline(from cell: CellRef, insertBelow: Bool) {
        let block = span(master(cell))
        let below = block.row + block.rows
        if insertBelow || below >= rowCount {
            insertRow(at: below)
            focusRequest = CellRef(row: below, column: insertBelow ? cell.column : 0)
        } else {
            focusRequest = master(CellRef(row: below, column: cell.column))
        }
    }


    /// Backspace in an empty cell takes back an extra Tab or Return: removes the empty last column, or the
    /// empty last row. Returns the cell to continue in, or nil if nothing was removed.
    func removeEmpty(at cell: CellRef) -> CellRef? {
        let isEmpty: (String) -> Bool = { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let lastColumn = columnCount - 1, lastRow = rowCount - 1
        if cell.column == lastColumn, lastColumn > 0, data.rows.allSatisfy({ isEmpty($0[lastColumn]) }) {
            removeColumn(lastColumn)
            return CellRef(row: cell.row, column: lastColumn - 1)
        }
        if cell.row == lastRow, lastRow > 0, data.rows[lastRow].allSatisfy(isEmpty) {
            deleteRow(lastRow)
            return CellRef(row: lastRow - 1, column: columnCount - 1)
        }
        return nil
    }

    func toggleHeaderRow() {
        data.headerRow.toggle()
        changed()
    }

    func toggleBorders() {
        data.hideBorders = !(data.hideBorders ?? false)
        changed()
    }

    /// Tables with cells merged across rows can't be sorted.
    var canSort: Bool { !(data.merges ?? []).contains { $0.rows > 1 } }

    func sort(byColumn column: Int, ascending: Bool) {
        guard canSort else { return NSSound.beep() }
        let skip = data.headerRow && rowCount > 0 ? 1 : 0
        var body = Array(skip..<rowCount)
        body.sort {
            let order = data.rows[$0][column].localizedStandardCompare(data.rows[$1][column])
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
        data.reorderRows(Array(0..<skip) + body)
        changed()
    }

    func clear(_ cells: Set<CellRef>) {
        for cell in cells where contains(cell) {
            data.rows[cell.row][cell.column] = ""
            if data.rich != nil { data.rich![cell.row][cell.column] = nil }
        }
        changed()
    }

    // MARK: Merge and split

    /// Merges the block covering the cells into one cell; the texts are joined in the top-left cell.
    func merge(_ cells: Set<CellRef>) {
        let block = bounds(of: cells)
        guard block.rows * block.columns > 1 else { return }
        let combined = NSMutableAttributedString()
        for r in block.row..<(block.row + block.rows) {
            for c in block.column..<(block.column + block.columns) where !data.isCovered(r, c) {
                let text = storedText(CellRef(row: r, column: c))
                guard !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                if combined.length > 0 { combined.append(NSAttributedString(string: "\n", attributes: [.font: baseFont(block.row)])) }
                combined.append(text)
            }
        }
        let top = CellRef(row: block.row, column: block.column)
        for r in block.row..<(block.row + block.rows) {
            for c in block.column..<(block.column + block.columns) where (r, c) != (top.row, top.column) {
                data.rows[r][c] = ""
                if data.rich != nil { data.rich![r][c] = nil }
            }
        }
        storedCache.removeAll()
        store(combined, in: top)
        var merges = (data.merges ?? []).filter { !(block.contains($0.row, $0.column)) }
        merges.append(block)
        data.merges = merges
        changed()
    }

    /// The smallest block holding the cells and every merged block they touch.
    func bounds(of cells: Set<CellRef>) -> CellSpan {
        guard let first = cells.first else { return CellSpan(row: 0, column: 0, rows: 0, columns: 0) }
        var top = first.row, left = first.column, bottom = first.row, right = first.column
        for cell in cells {
            let s = span(cell)
            top = min(top, s.row); left = min(left, s.column)
            bottom = max(bottom, s.row + s.rows - 1); right = max(right, s.column + s.columns - 1)
        }
        var changed = true
        while changed {
            changed = false
            for s in data.merges ?? [] where s.row <= bottom && s.row + s.rows - 1 >= top
                && s.column <= right && s.column + s.columns - 1 >= left {
                let (t, l, b, r) = (min(top, s.row), min(left, s.column),
                                    max(bottom, s.row + s.rows - 1), max(right, s.column + s.columns - 1))
                if (t, l, b, r) != (top, left, bottom, right) {
                    (top, left, bottom, right) = (t, l, b, r)
                    changed = true
                }
            }
        }
        return CellSpan(row: top, column: left, rows: bottom - top + 1, columns: right - left + 1)
    }

    /// Unmerges a merged cell (its text stays in the top-left cell).
    func unmerge(_ cell: CellRef) {
        let s = span(master(cell))
        data.merges = data.merges?.filter { $0 != s }
        if data.merges?.isEmpty == true { data.merges = nil }
        changed()
    }

    /// Splits a cell in two side by side: a column is added and the other rows keep one cell across both.
    func splitIntoColumns(_ cell: CellRef) {
        let cell = master(cell)
        let block = span(cell)
        let new = block.column + block.columns
        let half = Double(columnWidth(block.column + block.columns - 1)) / 2
        freezeColumnWidths()
        data.insertColumn(at: new)
        data.columnWidths[new - 1] = max(half, 30)
        data.columnWidths[new] = max(half, 30)
        var merges = data.merges ?? []
        var handled: Set<CellSpan> = []
        for r in 0..<rowCount where !(r >= block.row && r < block.row + block.rows) {
            if let i = merges.firstIndex(where: { $0.contains(r, new - 1) }) {
                if merges[i].contains(r, new) || handled.contains(merges[i]) { continue }
                merges[i].columns += 1
                handled.insert(merges[i])
            } else {
                merges.append(CellSpan(row: r, column: new - 1, rows: 1, columns: 2))
            }
        }
        data.merges = merges.isEmpty ? nil : merges
        changed()
    }

    /// Splits a cell in two, one above the other: a row is added and the other columns keep one cell across both.
    func splitIntoRows(_ cell: CellRef) {
        let cell = master(cell)
        let block = span(cell)
        let new = block.row + block.rows
        data.insertRow(at: new)
        var merges = data.merges ?? []
        var handled: Set<CellSpan> = []
        for c in 0..<columnCount where !(c >= block.column && c < block.column + block.columns) {
            if let i = merges.firstIndex(where: { $0.contains(new - 1, c) }) {
                if merges[i].contains(new, c) || handled.contains(merges[i]) { continue }
                merges[i].rows += 1
                handled.insert(merges[i])
            } else {
                merges.append(CellSpan(row: new - 1, column: c, rows: 2, columns: 1))
            }
        }
        data.merges = merges.isEmpty ? nil : merges
        changed()
    }

    // MARK: Shading

    enum ShadingScope {
        case cell, row, column, headerRow, table
    }

    /// Sets the background colour of the cell, its row, its column, the header row or the whole table (nil clears it).
    func setShading(_ color: NSColor?, scope: ShadingScope, at cell: CellRef) {
        var cells: Set<CellRef> = []
        for r in 0..<rowCount {
            for c in 0..<columnCount {
                let hit: Bool
                switch scope {
                case .cell: hit = r == cell.row && c == cell.column
                case .row: hit = r == cell.row
                case .column: hit = c == cell.column
                case .headerRow: hit = r == 0
                case .table: hit = true
                }
                if hit { cells.insert(CellRef(row: r, column: c)) }
            }
        }
        setShading(color, cells: cells)
    }

    /// Sets the background colour of the given cells (nil clears it).
    func setShading(_ color: NSColor?, cells: Set<CellRef>) {
        data.padShading()
        let value = color.map { RGBA($0) }
        for cell in cells where contains(cell) { data.shading![cell.row][cell.column] = value }
        if data.shading!.allSatisfy({ $0.allSatisfy { $0 == nil } }) { data.shading = nil }
        changed()
    }

    /// Banded rows: every other row below the header gets the colour, the rows between are cleared.
    func bandRows(_ color: NSColor?) {
        data.padShading()
        let first = data.headerRow ? 1 : 0
        for r in first..<max(first, rowCount) {
            let value: RGBA? = (r - first) % 2 == 1 ? color.map { RGBA($0) } : nil
            for c in 0..<columnCount { data.shading![r][c] = value }
        }
        if data.shading!.allSatisfy({ $0.allSatisfy { $0 == nil } }) { data.shading = nil }
        changed()
    }
}

// MARK: - Grid view

/// The editable table. Cells are drawn here; one rich-text editor moves to the cell being typed in.
final class TableGridView: NSView, NSTextViewDelegate {
    static let padX: CGFloat = 6
    static let padY: CGFloat = 4
    static let minRowHeight: CGFloat = 24
    private static let borderColor = NSColor(srgbRed: 0.64, green: 0.64, blue: 0.64, alpha: 1)

    /// The table being edited or with selected cells (the Table ribbon and cell formatting act on it).
    static weak var active: TableGridView? {
        didSet { NotebookStore.shared.editor.tableActive = active != nil }
    }

    weak var owner: TableElementView?
    let model: TableModel
    var isExport = false
    private(set) var selection: Set<CellRef> = [] {
        didSet {
            guard selection != oldValue, editing == nil, !selection.isEmpty, !isExport else { return }
            reportCellFormatting()
        }
    }

    /// Shows the selected cells' font in the ribbon.
    func reportCellFormatting() {
        TextFormatter.reportFormatting(of: selection.sorted { ($0.row, $0.column) < ($1.row, $1.column) }
            .map { model.displayText($0) })
    }
    private var anchor: CellRef?
    /// The moving corner of a ⇧-extended selection.
    private var extent: CellRef?
    private(set) var editing: CellRef?
    private let editor = NoteTextView(usingTextLayoutManager: false)
    private var editorUndo = UndoManager()
    private var rowHeights: [CGFloat] = []
    private var rowTops: [CGFloat] = [0]
    private var columnLefts: [CGFloat] = [0]
    private var heightCache: [CellRef: CGFloat] = [:]
    private var measuredWidth: CGFloat = -1
    private var relayingOut = false

    init(model: TableModel) {
        self.model = model
        super.init(frame: .zero)
        editor.isRichText = true
        editor.importsGraphics = true
        editor.allowsImageEditing = true
        editor.drawsBackground = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = true
        editor.allowsUndo = true
        editor.usesFindBar = false
        editor.usesFontPanel = true
        editor.isContinuousSpellCheckingEnabled = true
        editor.focusRingType = .none
        editor.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { !isExport }

    // MARK: Geometry

    /// The rectangle of a cell — the whole block for a merged cell.
    func cellRect(_ cell: CellRef) -> NSRect {
        let block = model.span(model.master(cell))
        let lastRow = block.row + block.rows, lastColumn = block.column + block.columns
        guard lastRow < rowTops.count, lastColumn < columnLefts.count else { return .zero }
        return NSRect(x: columnLefts[block.column], y: rowTops[block.row],
                      width: columnLefts[lastColumn] - columnLefts[block.column],
                      height: rowTops[lastRow] - rowTops[block.row])
    }

    private func blockWidth(_ cell: CellRef) -> CGFloat {
        let block = model.span(model.master(cell))
        return (block.column..<(block.column + block.columns)).reduce(0) { $0 + model.columnWidth($1) }
    }

    // MARK: Frozen header row

    /// How far the pinned header row is drawn below the table's top (0 = not pinned).
    var stickyOffset: CGFloat = 0 {
        didSet { if oldValue != stickyOffset { needsDisplay = true } }
    }

    var headerHeight: CGFloat { rowHeights.first ?? 0 }
    var tableHeight: CGFloat { rowTops.last ?? 0 }
    private var stickyActive: Bool { stickyOffset > 0 && model.data.headerRow && model.rowCount > 1 }

    /// A point on the pinned header counts as a point in the real header row.
    private func unpinned(_ point: NSPoint) -> NSPoint {
        guard stickyActive, point.y >= stickyOffset, point.y < stickyOffset + headerHeight else { return point }
        return NSPoint(x: point.x, y: point.y - stickyOffset)
    }

    private func drawStickyHeader() {
        guard stickyActive else { return }
        let width = columnLefts.last ?? 0
        let band = NSRect(x: 0, y: stickyOffset, width: width, height: headerHeight)
        NSColor.white.setFill()
        band.fill()
        let shadow = NSRect(x: 0, y: band.maxY, width: width, height: 4)
        NSGradient(starting: NSColor(white: 0, alpha: 0.18), ending: NSColor(white: 0, alpha: 0))?.draw(in: shadow, angle: 90)
        let grid = NSBezierPath()
        for c in 0..<model.columnCount where !model.data.isCovered(0, c) {
            let cell = CellRef(row: 0, column: c)
            var rect = cellRect(cell)
            rect.origin.y = stickyOffset
            rect.size.height = headerHeight
            if let shade = model.data.shade(0, c) {
                shade.nsColor.setFill()
                rect.fill()
            }
            model.displayText(cell, fitting: rect.width - 2 * Self.padX)
                .draw(with: rect.insetBy(dx: Self.padX, dy: Self.padY), options: [.usesLineFragmentOrigin, .usesFontLeading])
            grid.appendRect(rect)
        }
        grid.lineWidth = 0.75
        Self.borderColor.setStroke()
        if !(model.data.hideBorders ?? false) { grid.stroke() }
    }

    /// Starts typing in a row at an x position (in this view), on the cell's first or last line.
    private func enterRow(_ row: Int, atX x: CGFloat, lastLine: Bool) {
        let column = max(0, min(model.columnCount - 1, (columnLefts.lastIndex { $0 <= x } ?? 0)))
        let cell = model.master(CellRef(row: row, column: column))
        beginEditing(cell)
        let rect = cellRect(cell).insetBy(dx: Self.padX, dy: Self.padY)
        let y = lastLine ? rect.maxY - 2 : rect.minY + 2
        let index = editor.characterIndexForInsertion(at: editor.convert(NSPoint(x: x, y: y), from: self))
        editor.setSelectedRange(NSRange(location: min(index, (editor.string as NSString).length), length: 0))
    }

    /// Arrow keys coming from another container: the first row (from above) or last row (from below), at a page x.
    func enter(fromAbove: Bool, pageX: CGFloat) {
        guard model.rowCount > 0, let owner else { return }
        enterRow(fromAbove ? 0 : model.rowCount - 1, atX: pageX - owner.frame.minX, lastLine: !fromAbove)
    }

    /// Selects a cell and scrolls it into view (paragraph links).
    func reveal(_ cell: CellRef) {
        let cell = model.master(cell)
        guard model.contains(cell) else { return }
        endEditing()
        selection = [cell]
        anchor = cell
        becameActive()
        window?.makeFirstResponder(self)
        scrollToVisible(cellRect(cell).insetBy(dx: 0, dy: -24))
        needsDisplay = true
    }

    private func cell(at point: NSPoint) -> CellRef? {
        let point = unpinned(point)
        guard model.rowCount > 0, model.columnCount > 0 else { return nil }
        let row = max(0, min(model.rowCount - 1, (rowTops.lastIndex { $0 <= point.y } ?? 0)))
        let column = max(0, min(model.columnCount - 1, (columnLefts.lastIndex { $0 <= point.x } ?? 0)))
        return model.master(CellRef(row: row, column: column))
    }

    /// Index of the column whose right border is under the point (for resizing).
    private func columnBorder(at point: NSPoint) -> Int? {
        guard !isExport else { return nil }
        for c in 0..<model.columnCount where abs(columnLefts[c + 1] - point.x) <= 3 { return c }
        return nil
    }

    private func measure(_ cell: CellRef) -> CGFloat {
        if editing != cell, let cached = heightCache[cell] { return cached }
        let width = max(blockWidth(cell) - 2 * Self.padX, 10)
        let text = editing == cell ? (editor.textStorage ?? NSAttributedString()) : model.displayText(cell, fitting: width)
        var height = text.length == 0 ? model.baseFont(cell.row).boundingRectForFont.height
            : text.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        if text.string.hasSuffix("\n") { height += model.baseFont(cell.row).pointSize * 1.25 }
        height = ceil(height)
        heightCache[cell] = height
        return height
    }

    func invalidateLayout() {
        heightCache.removeAll()
    }

    /// Measures rows, resizes the container to fit and repositions the editor.
    func relayout() {
        guard !relayingOut else { return }
        relayingOut = true
        defer { relayingOut = false }
        if model.width != measuredWidth {
            heightCache.removeAll()
            measuredWidth = model.width
        }
        selection = selection.filter(model.contains)
        if let editing, !model.contains(editing) { stopEditing(commit: false) }
        columnLefts = [0]
        for c in 0..<model.columnCount { columnLefts.append(columnLefts[c] + model.columnWidth(c)) }
        rowHeights = (0..<model.rowCount).map { r in
            let tallest = (0..<model.columnCount).compactMap { c -> CGFloat? in
                let cell = CellRef(row: r, column: c)
                guard !model.data.isCovered(r, c), model.span(cell).rows == 1 else { return nil }
                return measure(cell)
            }.max() ?? 0
            return max(Self.minRowHeight, tallest + 2 * Self.padY)
        }
        // A merged cell taller than its rows makes its last row taller.
        for block in model.data.merges ?? [] where block.rows > 1 && block.row + block.rows <= rowHeights.count {
            let needed = measure(CellRef(row: block.row, column: block.column)) + 2 * Self.padY
            let have = rowHeights[block.row..<(block.row + block.rows)].reduce(0, +)
            if needed > have { rowHeights[block.row + block.rows - 1] += needed - have }
        }
        rowTops = [0]
        for height in rowHeights { rowTops.append(rowTops.last! + height) }
        owner?.fitTableHeight(rowTops.last ?? 0)
        owner?.controller?.updateStickyHeaders()
        positionEditor()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    // MARK: Cursors

    private var cursorTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTracking { removeTrackingArea(cursorTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        cursorTracking = area
    }

    /// True on the table's top, left or bottom edge (drag there to move the table).
    private func onOuterEdge(_ p: NSPoint) -> Bool {
        let width = columnLefts.last ?? 0, height = rowTops.last ?? 0
        guard p.x >= -3, p.x <= width + 3, p.y >= -3, p.y <= height + 3 else { return false }
        return abs(p.y) <= 3 || abs(p.x) <= 3 || abs(p.y - height) <= 3
    }

    /// The link under a point in a cell that isn't being typed in.
    func link(at p: NSPoint) -> URL? {
        guard let cell = cell(at: p), cell != editing else { return nil }
        let rect = cellRect(cell).insetBy(dx: Self.padX, dy: Self.padY)
        guard rect.contains(p) else { return nil }
        let text = model.displayText(cell, fitting: rect.width)
        guard text.length > 0 else { return nil }
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: rect.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        let local = NSPoint(x: p.x - rect.minX, y: p.y - rect.minY)
        let glyph = layout.glyphIndex(for: local, in: container, fractionOfDistanceThroughGlyph: nil)
        guard layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(local) else { return nil }
        let index = layout.characterIndexForGlyph(at: glyph)
        guard index < storage.length else { return nil }
        let value = storage.attribute(.link, at: index, effectiveRange: nil)
        return value as? URL ?? (value as? String).flatMap { URL(string: $0) }
    }

    /// Resize on column borders, move on the outer edges, pointing hand on links, text cursor in cells.
    func cursor(at p: NSPoint) -> NSCursor {
        if columnBorder(at: p) != nil { return .resizeLeftRight }
        if onOuterEdge(p) { return .openHand }
        if link(at: p) != nil { return .pointingHand }
        return .iBeam
    }

    private func updateCursor(_ event: NSEvent) {
        guard !isExport, NotebookStore.shared.editor.tool == .type else { return }
        let p = convert(event.locationInWindow, from: nil)
        // While typing in a cell, the editor shows its own cursor (and links) inside the cell.
        if let editing, cellRect(editing).insetBy(dx: Self.padX, dy: Self.padY).contains(p) { return }
        cursor(at: p).set()
    }

    override func mouseMoved(with event: NSEvent) { updateCursor(event) }
    override func cursorUpdate(with event: NSEvent) { updateCursor(event) }

    private func open(_ url: URL) {
        if url.scheme == NotebookStore.linkScheme {
            NotebookStore.shared.openLink(url)
        } else if url.scheme == OneNoteImport.missingScheme {
            ImportActivity.shared.locateMissingPictures()
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let showSelection = !isExport && (selection.count > 1 || (editing == nil && !selection.isEmpty))
        let hideBorders = model.data.hideBorders ?? false
        let visible = model.visibleCells
        for cell in visible {
            do {
                let (r, c) = (cell.row, cell.column)
                let rect = cellRect(cell)
                guard rect.intersects(dirtyRect) else { continue }
                if let shade = model.data.shade(r, c) {
                    shade.nsColor.setFill()
                    rect.fill()
                }
                if showSelection && selection.contains(cell) {
                    NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
                    rect.fill(using: .sourceOver)
                }
                if editing != cell {
                    model.displayText(cell, fitting: rect.width - 2 * Self.padX).draw(with: rect.insetBy(dx: Self.padX, dy: Self.padY),
                                                 options: [.usesLineFragmentOrigin, .usesFontLeading])
                }
            }
        }
        let grid = NSBezierPath()
        for cell in visible { grid.appendRect(cellRect(cell)) }
        defer { drawStickyHeader() }
        if hideBorders {
            guard !isExport, editing != nil || !selection.isEmpty else { return drawSelectionOutline(showSelection) }
            grid.lineWidth = 0.5
            grid.setLineDash([2, 2], count: 2, phase: 0)
            NSColor(white: 0.75, alpha: 1).setStroke()
        } else {
            grid.lineWidth = 0.75
            Self.borderColor.setStroke()
        }
        grid.stroke()
        drawSelectionOutline(showSelection)
    }

    private func drawSelectionOutline(_ show: Bool) {
        guard show else { return }
        NSColor.controlAccentColor.setStroke()
        for cell in selection {
            let path = NSBezierPath(rect: cellRect(cell).insetBy(dx: 1, dy: 1))
            path.lineWidth = 1.5
            path.stroke()
        }
    }

    // MARK: Active table

    private var responderObservation: NSKeyValueObservation?

    /// This table receives the ribbon's formatting and table commands. It stays that way while focus is in the
    /// ribbon, menus or other controls outside the page, and lets go when something else on the page gets focus.
    private func becameActive() {
        TableGridView.active = self
        guard responderObservation == nil, let window else { return }
        responderObservation = window.observe(\.firstResponder, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.firstResponderChanged() }
        }
    }

    private func deactivate() {
        responderObservation = nil
        if TableGridView.active === self { TableGridView.active = nil }
    }

    private func firstResponderChanged() {
        guard let window, let canvas = owner?.canvas else { return deactivate() }
        let responder = window.firstResponder
        if responder === self || responder === editor { return }
        // Focus went to the ribbon or another control off the page: keep the selection and any cell being typed in.
        guard let view = responder as? NSView, view.isDescendant(of: canvas) else { return }
        if editing != nil {
            stopEditing(commit: true)
            relayout()
        }
        selection = []
        needsDisplay = true
        deactivate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            if editing != nil { stopEditing(commit: true) }
            selection = []
            deactivate()
        }
    }

    override func becomeFirstResponder() -> Bool {
        becameActive()
        return true
    }

    /// The cells commands act on: the selection, or the cell being typed in.
    var targetCells: Set<CellRef> {
        if !selection.isEmpty { return selection }
        if let editing { return [editing] }
        return []
    }

    private var targetCell: CellRef {
        editing ?? anchor ?? selection.min { ($0.row, $0.column) < ($1.row, $1.column) } ?? CellRef(row: 0, column: 0)
    }

    // MARK: Editing

    func beginEditing(_ cell: CellRef, at point: NSPoint? = nil, caretAtEnd: Bool = true) {
        let cell = model.master(cell)
        guard model.contains(cell), !isExport else { return }
        if editing != nil { stopEditing(commit: true) }
        editing = cell
        selection = [cell]
        anchor = cell
        extent = nil
        editorUndo = UndoManager()
        editor.textStorage?.setAttributedString(model.displayText(cell, fitting: blockWidth(cell) - 2 * Self.padX))
        editor.typingAttributes = editor.textStorage?.length ?? 0 > 0
            ? editor.textStorage!.attributes(at: 0, effectiveRange: nil) : model.typingAttributes(cell)
        editor.insertionPointColor = model.autoColor(cell)
        if editor.superview !== self { addSubview(editor) }
        becameActive()
        relayout()
        // Typing in a header cell while it's pinned: bring the real header row into view.
        if stickyActive, cell.row == 0 { scrollToVisible(cellRect(cell).insetBy(dx: 0, dy: -12)) }
        window?.makeFirstResponder(editor)
        if let point {
            let index = editor.characterIndexForInsertion(at: editor.convert(point, from: self))
            editor.setSelectedRange(NSRange(location: index, length: 0))
        } else {
            editor.setSelectedRange(NSRange(location: caretAtEnd ? (editor.string as NSString).length : 0, length: 0))
        }
        needsDisplay = true
    }

    private func positionEditor() {
        guard let editing, model.contains(editing) else { return }
        let rect = cellRect(editing).insetBy(dx: Self.padX, dy: Self.padY)
        editor.textContainer?.containerSize = NSSize(width: rect.width, height: .greatestFiniteMagnitude)
        editor.frame = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(rect.height, 14))
    }

    /// Stops typing in the cell (keeping the text) and leaves the cell selected.
    func endEditing() {
        guard editing != nil else { return }
        let editorWasFocused = window?.firstResponder === editor
        stopEditing(commit: true)
        if editorWasFocused { window?.makeFirstResponder(self) }
        relayout()
    }

    private func stopEditing(commit: Bool) {
        guard let cell = editing else { return }
        if commit, let storage = editor.textStorage {
            model.store(storage, in: cell)
            owner?.controller?.markDirty()
        }
        heightCache[cell] = nil
        editing = nil
        editor.removeFromSuperview()
        needsDisplay = true
    }

    private func continueAtFocusRequest() {
        guard let next = model.focusRequest else { return }
        model.focusRequest = nil
        beginEditing(next)
    }

    func textDidChange(_ notification: Notification) {
        guard let cell = editing, let storage = editor.textStorage else { return }
        model.store(storage, in: cell)
        owner?.controller?.markDirty()
        relayout()
    }

    func textDidEndEditing(_ notification: Notification) {
        // Typing in the cell ends when something else on the page gets focus (see firstResponderChanged).
        if let cell = editing, let storage = editor.textStorage { model.store(storage, in: cell) }
    }

    func undoManager(for view: NSTextView) -> UndoManager? { editorUndo }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap { URL(string: $0) }
        if let url, url.scheme == NotebookStore.linkScheme {
            NotebookStore.shared.openLink(url)
            return true
        }
        if url?.scheme == OneNoteImport.missingScheme {
            endEditing()
            ImportActivity.shared.locateMissingPictures()
            return true
        }
        return false
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard let cell = editing else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            stopEditing(commit: true)
            model.tab(from: cell, backward: commandSelector == #selector(NSResponder.insertBacktab(_:)))
            if model.focusRequest == nil { beginEditing(cell) } else { continueAtFocusRequest() }
            return true
        case #selector(NSResponder.insertNewline(_:)):
            // OneNote: Enter is a new line in the cell; in the last row it adds a row; ⌘Enter inserts a row below.
            let insertBelow = NSApp.currentEvent?.modifierFlags.contains(.command) == true
            let block = model.span(cell)
            guard insertBelow || block.row + block.rows >= model.rowCount else { return false }
            stopEditing(commit: true)
            model.newline(from: cell, insertBelow: insertBelow)
            continueAtFocusRequest()
            return true
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)):
            let up = commandSelector == #selector(NSResponder.moveUp(_:))
            let line = TextFormatter.caretLine(textView)
            guard up ? line.first : line.last else { return false }
            let block = model.span(cell)
            let x = cellRect(cell).minX + TableGridView.padX + TextFormatter.caretX(textView)
            let row = up ? block.row - 1 : block.row + block.rows
            if row >= 0, row < model.rowCount {
                enterRow(row, atX: x, lastLine: up)
            } else if let owner {
                endEditing()
                let pageX = owner.frame.minX + x
                if owner.controller?.moveFocus(from: owner, up: up, x: pageX) != true { beginEditing(cell) }
            }
            return true
        case #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveRight(_:)):
            let left = commandSelector == #selector(NSResponder.moveLeft(_:))
            let selection = textView.selectedRange()
            let length = (textView.string as NSString).length
            guard selection.length == 0, left ? selection.location == 0 : selection.location >= length else { return false }
            let order = model.visibleCells
            guard let index = order.firstIndex(of: cell) else { return false }
            let next = left ? index - 1 : index + 1
            guard order.indices.contains(next) else { return true }
            beginEditing(order[next], caretAtEnd: left)
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), #selector(NSResponder.insertLineBreak(_:)):
            textView.insertText("\n", replacementRange: textView.selectedRange())
            return true
        case #selector(NSResponder.deleteBackward(_:)):
            guard textView.string.isEmpty else { return false }
            stopEditing(commit: true)
            beginEditing(model.removeEmpty(at: cell) ?? cell)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endEditing()
            selection = [cell]
            anchor = cell
            needsDisplay = true
            return true
        default:
            return false
        }
    }

    /// Right-click while typing: the table commands come first, then the usual text commands.
    func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        guard let cell = editing else { return menu }
        let table = tableMenu(for: cell)
        var items = table.items
        table.removeAllItems()
        if let owner, let ref = owner.controller?.ref {
            let ns = view.string as NSString
            let index = min(max(charIndex, 0), max(ns.length - 1, 0))
            let range = ns.length == 0 ? NSRange(location: 0, length: 0) : ns.paragraphRange(for: NSRange(location: index, length: 0))
            let paragraph = ns.substring(to: range.location).components(separatedBy: "\n").count - 1
            let text = ns.substring(with: range)
            let elementID = owner.element.id
            items.insert(ClosureMenuItem("Copy Link to this Paragraph") {
                NotebookStore.shared.copyParagraphLink(ref, element: elementID, paragraph: paragraph, cell: cell, text: text)
            }, at: 0)
            items.insert(.separator(), at: 1)
        }
        for (i, item) in items.enumerated() { menu.insertItem(item, at: i) }
        menu.insertItem(.separator(), at: items.count)
        return menu
    }

    // MARK: Formatting selected cells

    /// Runs a text-formatting command (from the ribbon or menus) on every selected cell's text.
    func applyToSelection(_ body: (NoteTextView) -> Void) -> Bool {
        let cells = targetCells
        guard !cells.isEmpty, editing == nil, window != nil else { return false }
        let scratch = NoteTextView(usingTextLayoutManager: false)
        scratch.isRichText = true
        for cell in cells.sorted(by: { ($0.row, $0.column) < ($1.row, $1.column) }) {
            scratch.textStorage?.setAttributedString(model.displayText(cell))
            scratch.typingAttributes = model.typingAttributes(cell)
            scratch.setSelectedRange(NSRange(location: 0, length: scratch.textStorage?.length ?? 0))
            body(scratch)
            if let storage = scratch.textStorage { model.store(storage, in: cell) }
            heightCache[cell] = nil
        }
        owner?.controller?.markDirty()
        relayout()
        reportCellFormatting()
        return true
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        guard !isExport, let owner, let window else { return }
        let p = convert(event.locationInWindow, from: nil)
        if let column = columnBorder(at: p) {
            resizeColumn(column, from: event)
            return
        }
        if onOuterEdge(p) {
            endEditing()
            owner.beginMove(with: event)
            return
        }
        // A click on a link follows it (⌥-click to type in the cell instead).
        if !event.modifierFlags.contains(.option), !event.modifierFlags.contains(.shift),
           !event.modifierFlags.contains(.command), let url = link(at: p) {
            open(url)
            return
        }
        guard let start = cell(at: p) else { return }
        owner.canvas?.selectedElement = nil
        becameActive()
        if event.modifierFlags.contains(.shift), let anchor {
            endEditing()
            extent = start
            selectRange(anchor, start)
            window.makeFirstResponder(self)
            return
        }
        if event.modifierFlags.contains(.command) {
            endEditing()
            if selection.contains(start) { selection.remove(start) } else { selection.insert(start) }
            anchor = start
            window.makeFirstResponder(self)
            needsDisplay = true
            return
        }
        var current = start
        var dragged = false
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: NSEvent.foreverDuration,
                           mode: .eventTracking) { ev, stop in
            guard let ev, ev.type == .leftMouseDragged else {
                stop.pointee = true
                return
            }
            guard let cell = self.cell(at: self.convert(ev.locationInWindow, from: nil)) else { return }
            if cell != current || dragged {
                if !dragged { self.endEditing() }
                dragged = true
                current = cell
                self.selectRange(start, cell)
            }
        }
        if dragged {
            anchor = start
            extent = current
            window.makeFirstResponder(self)
        } else if editing == start {
            let index = editor.characterIndexForInsertion(at: editor.convert(p, from: self))
            editor.setSelectedRange(NSRange(location: index, length: 0))
        } else {
            beginEditing(start, at: p)
        }
    }

    /// Drag a column border: that column gets wider or narrower and the table follows.
    private func resizeColumn(_ column: Int, from event: NSEvent) {
        guard let window else { return }
        endEditing()
        model.freezeColumnWidths()
        let startX = convert(event.locationInWindow, from: nil).x
        let startWidth = model.data.columnWidths[column]
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: NSEvent.foreverDuration,
                           mode: .eventTracking) { ev, stop in
            guard let ev, ev.type == .leftMouseDragged else {
                stop.pointee = true
                return
            }
            let x = self.convert(ev.locationInWindow, from: nil).x
            let newWidth = max(30, startWidth + Double(x - startX))
            let delta = newWidth - self.model.data.columnWidths[column]
            guard abs(delta) >= 0.5 else { return }
            self.model.data.columnWidths[column] = newWidth
            self.model.onWidthChange?(CGFloat(delta))
            self.heightCache.removeAll()
            self.relayout()
        }
        owner?.controller?.markDirty()
    }

    private func selectRange(_ a: CellRef, _ b: CellRef) {
        let block = model.bounds(of: [a, b])
        var cells: Set<CellRef> = []
        for r in block.row..<(block.row + block.rows) {
            for c in block.column..<(block.column + block.columns) { cells.insert(model.master(CellRef(row: r, column: c))) }
        }
        selection = cells
        needsDisplay = true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard !isExport, let cell = cell(at: convert(event.locationInWindow, from: nil)) else { return nil }
        if !selection.contains(cell) {
            endEditing()
            selection = [cell]
            anchor = cell
            needsDisplay = true
        }
        becameActive()
        return tableMenu(for: cell)
    }

    // MARK: Keys (cells selected, not typing)

    override func keyDown(with event: NSEvent) {
        let anchor = self.anchor ?? selection.first ?? CellRef(row: 0, column: 0)
        switch event.keyCode {
        case 36, 76:
            beginEditing(anchor)
        case 51, 117:
            model.clear(selection)
            heightCache.removeAll()
            relayout()
            owner?.controller?.markDirty()
        case 48:
            model.tab(from: anchor, backward: event.modifierFlags.contains(.shift))
            continueAtFocusRequest()
        case 53:
            selection = []
            needsDisplay = true
            owner?.canvas?.selectedElement = owner
            window?.makeFirstResponder(owner?.canvas)
        case 123, 124, 125, 126:
            let shift = event.modifierFlags.contains(.shift)
            let from = shift ? (extent ?? anchor) : anchor
            var next = from
            let block = model.span(model.master(from))
            switch event.keyCode {
            case 123: next.column = block.column - 1
            case 124: next.column = block.column + block.columns
            case 125: next.row = block.row + block.rows
            default: next.row = block.row - 1
            }
            guard model.contains(next) else { return }
            next = model.master(next)
            if shift {
                extent = next
                selectRange(anchor, next)
            } else {
                selection = [next]
                self.anchor = next
                extent = nil
                needsDisplay = true
            }
        default:
            if let characters = event.characters, !characters.isEmpty,
               characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
               !event.modifierFlags.contains(.command) {
                model.clear([anchor])
                beginEditing(anchor)
                editor.insertText(characters, replacementRange: editor.selectedRange())
            } else {
                super.keyDown(with: event)
            }
        }
    }

    @objc func copy(_ sender: Any?) {
        guard !selection.isEmpty else { return }
        let rows = selection.map(\.row), columns = selection.map(\.column)
        let text = (rows.min()!...rows.max()!).map { r in
            (columns.min()!...columns.max()!).map { c in
                selection.contains(CellRef(row: r, column: c)) ? model.text(CellRef(row: r, column: c)) : ""
            }.joined(separator: "\t")
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func cut(_ sender: Any?) {
        copy(sender)
        model.clear(selection)
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string),
              let start = selection.min(by: { ($0.row, $0.column) < ($1.row, $1.column) }) else { return }
        for (r, line) in text.components(separatedBy: "\n").enumerated() {
            for (c, value) in line.components(separatedBy: "\t").enumerated() {
                let cell = CellRef(row: start.row + r, column: start.column + c)
                if model.contains(cell) { model.store(NSAttributedString(string: value, attributes: model.typingAttributes(cell)), in: cell) }
            }
        }
        heightCache.removeAll()
        model.onChange?()
    }

    @objc override func selectAll(_ sender: Any?) {
        endEditing()
        selectRange(CellRef(row: 0, column: 0), CellRef(row: model.rowCount - 1, column: model.columnCount - 1))
        window?.makeFirstResponder(self)
    }

    // MARK: Commands (right-click menu and the Table ribbon tab)

    private func run(_ body: () -> Void) {
        endEditing()
        body()
        heightCache.removeAll()
        relayout()
    }

    private var selectedRows: [Int] { Set(targetCells.map(\.row)).sorted() }
    private var selectedColumns: [Int] { Set(targetCells.map(\.column)).sorted() }

    func insertRowAbove() { run { model.insertRow(at: selectedRows.first ?? targetCell.row) } }
    func insertRowBelow() { run { model.insertRow(at: (selectedRows.last ?? targetCell.row) + 1) } }
    func insertColumnLeft() { run { model.addColumn(at: selectedColumns.first ?? targetCell.column) } }
    func insertColumnRight() { run { model.addColumn(at: (selectedColumns.last ?? targetCell.column) + 1) } }

    func deleteRows() {
        let rows = selectedRows.isEmpty ? [targetCell.row] : selectedRows
        run { for r in rows.reversed() where model.rowCount > 1 { model.deleteRow(r) } }
        selection = []
    }

    func deleteColumns() {
        let columns = selectedColumns.isEmpty ? [targetCell.column] : selectedColumns
        run { for c in columns.reversed() where model.columnCount > 1 { model.removeColumn(c) } }
        selection = []
    }

    func deleteTable() {
        guard let owner else { return }
        endEditing()
        owner.controller?.removeElement(owner)
    }

    func shadeCells(_ color: NSColor?) {
        let cells = targetCells.isEmpty ? [targetCell] : targetCells
        run { model.setShading(color, cells: cells) }
    }

    func shadeRows(_ color: NSColor?) {
        let rows = selectedRows.isEmpty ? [targetCell.row] : selectedRows
        let cells = Set(rows.flatMap { r in (0..<model.columnCount).map { CellRef(row: r, column: $0) } })
        run { model.setShading(color, cells: cells) }
    }

    func shadeColumns(_ color: NSColor?) {
        let columns = selectedColumns.isEmpty ? [targetCell.column] : selectedColumns
        let cells = Set(columns.flatMap { c in (0..<model.rowCount).map { CellRef(row: $0, column: c) } })
        run { model.setShading(color, cells: cells) }
    }

    func shadeHeaderRow(_ color: NSColor?) { run { model.setShading(color, scope: .headerRow, at: targetCell) } }
    func shadeTable(_ color: NSColor?) { run { model.setShading(color, scope: .table, at: targetCell) } }
    func bandRows(_ color: NSColor?) { run { model.bandRows(color) } }
    func toggleHeaderRow() { run { model.toggleHeaderRow() } }
    func toggleBorders() { run { model.toggleBorders() } }
    func sort(ascending: Bool) { let column = targetCell.column; run { model.sort(byColumn: column, ascending: ascending) } }
    func clearCells() { let cells = targetCells; run { model.clear(cells) } }

    func mergeCells() {
        let cells = targetCells
        guard cells.count > 1 else { return NSSound.beep() }
        run { model.merge(cells) }
        let top = model.master(CellRef(row: model.bounds(of: cells).row, column: model.bounds(of: cells).column))
        selection = [top]
        anchor = top
    }

    func unmergeCell() { let cell = targetCell; run { model.unmerge(cell) } }
    func splitIntoColumns() { let cell = targetCell; run { model.splitIntoColumns(cell) } }
    func splitIntoRows() { let cell = targetCell; run { model.splitIntoRows(cell) } }
    var targetIsMerged: Bool { model.data.span(targetCell.row, targetCell.column) != nil }

    func selectTable() {
        selectAll(nil)
        becameActive()
    }

    private func paletteItem(_ title: String, _ apply: @escaping (NSColor?) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        for (name, color) in Palette.shading {
            let entry = ClosureMenuItem(name) { apply(color) }
            entry.image = Palette.swatch(color)
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("No Color") { apply(nil) })
        item.submenu = menu
        return item
    }

    func tableMenu(for cell: CellRef) -> NSMenu {
        let menu = NSMenu()
        if editing == nil, let owner, let ref = owner.controller?.ref {
            let text = model.text(model.master(cell))
            let first = text.components(separatedBy: "\n").first ?? ""
            let elementID = owner.element.id
            let target = model.master(cell)
            menu.addItem(ClosureMenuItem("Copy Link to this Paragraph") {
                NotebookStore.shared.copyParagraphLink(ref, element: elementID, paragraph: 0, cell: target, text: first)
            })
            menu.addItem(.separator())
        }
        let count = targetCells.count
        menu.addItem(paletteItem(count > 1 ? "Shade Selected Cells (\(count))" : "Cell Shading") { [weak self] in self?.shadeCells($0) })
        if model.data.headerRow || cell.row == 0 {
            menu.addItem(paletteItem("Header Row Shading") { [weak self] in self?.shadeHeaderRow($0) })
        }
        menu.addItem(paletteItem("Row Shading") { [weak self] in self?.shadeRows($0) })
        menu.addItem(paletteItem("Column Shading") { [weak self] in self?.shadeColumns($0) })
        menu.addItem(paletteItem("Banded Rows") { [weak self] in self?.bandRows($0) })
        menu.addItem(paletteItem("Table Shading") { [weak self] in self?.shadeTable($0) })
        let textColor = NSMenuItem(title: "Text Color", action: nil, keyEquivalent: "")
        let colors = NSMenu()
        for (name, color) in Palette.text {
            let entry = ClosureMenuItem(name) { TextFormatter.setTextColor(color) }
            entry.image = Palette.swatch(color)
            colors.addItem(entry)
        }
        textColor.submenu = colors
        menu.addItem(textColor)
        menu.addItem(.separator())
        menu.autoenablesItems = false
        let merge = ClosureMenuItem(count > 1 ? "Merge \(count) Cells" : "Merge Cells") { [weak self] in self?.mergeCells() }
        merge.isEnabled = count > 1
        menu.addItem(merge)
        let split = NSMenuItem(title: "Split Cell", action: nil, keyEquivalent: "")
        let splitMenu = NSMenu()
        if targetIsMerged { splitMenu.addItem(ClosureMenuItem("Unmerge Cells") { [weak self] in self?.unmergeCell() }) }
        splitMenu.addItem(ClosureMenuItem("Into 2 Columns") { [weak self] in self?.splitIntoColumns() })
        splitMenu.addItem(ClosureMenuItem("Into 2 Rows") { [weak self] in self?.splitIntoRows() })
        split.submenu = splitMenu
        menu.addItem(split)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Insert Row Above") { [weak self] in self?.insertRowAbove() })
        menu.addItem(ClosureMenuItem("Insert Row Below") { [weak self] in self?.insertRowBelow() })
        menu.addItem(ClosureMenuItem("Insert Column Left") { [weak self] in self?.insertColumnLeft() })
        menu.addItem(ClosureMenuItem("Insert Column Right") { [weak self] in self?.insertColumnRight() })
        menu.addItem(.separator())
        let rows = selectedRows.count, columns = selectedColumns.count
        menu.addItem(ClosureMenuItem(rows > 1 ? "Delete \(rows) Rows" : "Delete Row") { [weak self] in self?.deleteRows() })
        menu.addItem(ClosureMenuItem(columns > 1 ? "Delete \(columns) Columns" : "Delete Column") { [weak self] in self?.deleteColumns() })
        menu.addItem(ClosureMenuItem(count > 1 ? "Clear Selected Cells" : "Clear Cell") { [weak self] in self?.clearCells() })
        menu.addItem(ClosureMenuItem("Delete Table") { [weak self] in self?.deleteTable() })
        menu.addItem(.separator())
        for (title, ascending) in [("Sort Ascending by This Column", true), ("Sort Descending by This Column", false)] {
            let item = ClosureMenuItem(title) { [weak self] in self?.sort(ascending: ascending) }
            item.isEnabled = model.canSort
            menu.addItem(item)
        }
        menu.addItem(ClosureMenuItem("Header Row", state: model.data.headerRow) { [weak self] in self?.toggleHeaderRow() })
        menu.addItem(ClosureMenuItem("Hide Borders", state: model.data.hideBorders ?? false) { [weak self] in self?.toggleBorders() })
        menu.addItem(ClosureMenuItem("Select Entire Table") { [weak self] in self?.selectTable() })
        return menu
    }
}

// MARK: - Container

final class TableElementView: ElementView {
    let model: TableModel
    let grid: TableGridView

    override init(element: PageElement) {
        model = TableModel(data: element.table ?? TableData(rows: 2, columns: 2), width: element.width)
        grid = TableGridView(model: model)
        super.init(element: element)
        grid.owner = self
        model.onChange = { [weak self] in
            self?.controller?.markDirty()
            self?.grid.invalidateLayout()
            self?.grid.relayout()
        }
        model.onWidthChange = { [weak self] delta in
            guard let self else { return }
            self.setWidth(self.frame.width + delta)
            self.canvas?.updateSize()
        }
        addSubview(grid)
        finishSetup()
        grid.relayout()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var minWidth: CGFloat { 60 }

    override func prepareForExport() {
        super.prepareForExport()
        grid.isExport = true
        grid.relayout()
    }

    override func layoutContent() {
        let content = contentFrame
        grid.frame = NSRect(x: 0, y: Self.gripHeight, width: content.width, height: content.height)
        if model.width != content.width {
            model.width = content.width
            grid.relayout()
        }
    }

    /// Pins the header row while the table's top is above the visible area and some of its body is still in view.
    func updateStickyHeader(visibleTop: CGFloat) {
        guard model.data.headerRow, model.rowCount > 1 else {
            grid.stickyOffset = 0
            return
        }
        let offset = visibleTop - (frame.minY + Self.gripHeight)
        grid.stickyOffset = offset > 0 ? min(offset, max(0, grid.tableHeight - grid.headerHeight)) : 0
    }

    func fitTableHeight(_ height: CGFloat) {
        let target = Self.gripHeight + ceil(height)
        guard abs(frame.height - target) > 0.5 else { return }
        let oldHeight = frame.height
        setFrameSize(NSSize(width: frame.width, height: target))
        heightChanged(from: oldHeight)
        canvas?.updateSize()
    }

    func beginEditing(_ cell: CellRef) {
        grid.beginEditing(cell)
    }

    override func makeElement() -> PageElement {
        var e = super.makeElement()
        var table = model.data
        table.columnWidths = (0..<table.columnCount).map { Double(model.columnWidth($0)) }
        e.table = table
        return e
    }

    override func indexText() -> String? {
        model.data.rows.map { $0.joined(separator: " ") }.joined(separator: "\n")
    }

    override func contextMenu() -> NSMenu {
        let menu = super.contextMenu()
        menu.addItem(.separator())
        let table = grid.tableMenu(for: CellRef(row: 0, column: 0))
        let items = table.items
        table.removeAllItems()
        for item in items { menu.addItem(item) }
        return menu
    }
}
