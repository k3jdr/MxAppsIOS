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
//  column border to resize, drag a picture's side or corner to resize it
//  (pictures on a line of their own follow the cell). Right-click or the Table ribbon tab: shading
//  for cells, rows, columns, banded rows, header row, insert / delete,
//  sort, borders.
//

import AppKit
import SwiftUI

extension NSAttributedString.Key {
    /// Marks text whose colour was chosen automatically for the cell's shading (never saved).
    static let mxAutoColor = NSAttributedString.Key("MxAutoColor")
    /// On a picture shown smaller to fit its cell: the saved picture it stands for (never saved).
    static let mxShownPicture = NSAttributedString.Key("MxShownPicture")
}

/// Pictures in cells. A picture wider than its cell is shown as a scaled copy, so the saved
/// picture keeps the size it was given (and grows back when the cell gets wider).
enum CellPictures {
    /// Decoded pictures, by their file (decoded once, not on every draw).
    private static let images = NSMapTable<FileWrapper, NSImage>(keyOptions: [.weakMemory, .objectPointerPersonality],
                                                                  valueOptions: .strongMemory)
    /// The scaled copy last made of each picture.
    private static let copies = NSMapTable<NSTextAttachment, NSTextAttachment>(keyOptions: [.weakMemory, .objectPointerPersonality],
                                                                               valueOptions: .strongMemory)

    private static func image(_ attachment: NSTextAttachment) -> NSImage? {
        guard let wrapper = attachment.fileWrapper else { return (attachment.attachmentCell as? NSTextAttachmentCell)?.image }
        if let image = images.object(forKey: wrapper) { return image }
        guard let data = wrapper.regularFileContents, let image = NSImage(data: data) else { return nil }
        images.setObject(image, forKey: wrapper)
        return image
    }

    /// True for a picture (not a file shown as an icon).
    static func isPicture(_ attachment: NSTextAttachment) -> Bool { image(attachment) != nil }

    /// The picture's own height over width (sizes are rounded to points; resizing keeps to this, not to them).
    static func aspect(_ attachment: NSTextAttachment) -> CGFloat {
        let own = image(attachment).flatMap { image -> NSSize? in
            let pixels = image.representations.first.map { NSSize(width: $0.pixelsWide, height: $0.pixelsHigh) }
            return pixels.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil } ?? image.size
        }
        let size = own ?? OneNoteImport.displaySize(attachment)
        return size.width > 0 && size.height > 0 ? size.height / size.width : 1
    }

    /// Draws the picture at a new size (the saved picture: it keeps this size).
    static func resize(_ attachment: NSTextAttachment, to size: NSSize) {
        draw(attachment, from: attachment, at: size)
    }

    private static func draw(_ attachment: NSTextAttachment, from picture: NSTextAttachment, at size: NSSize) {
        if let image = image(picture)?.copy() as? NSImage {
            image.size = size
            attachment.attachmentCell = NSTextAttachmentCell(imageCell: image)
        }
        attachment.bounds = CGRect(origin: .zero, size: size)
    }

    /// A copy of the picture drawn at another size (the same picture file).
    private static func copy(_ attachment: NSTextAttachment, size: NSSize) -> NSTextAttachment {
        if let copy = copies.object(forKey: attachment), copy.fileWrapper === attachment.fileWrapper,
           abs(copy.bounds.width - size.width) < 0.25, abs(copy.bounds.height - size.height) < 0.25 { return copy }
        let copy = NSTextAttachment(fileWrapper: attachment.fileWrapper)
        draw(copy, from: attachment, at: size)
        copies.setObject(copy, forKey: attachment)
        return copy
    }

    /// Text with pictures wider than `width` swapped for scaled copies. Marked copies (for typing in the
    /// cell) carry the saved picture, which `restore` puts back.
    static func fitted(_ text: NSAttributedString, width: CGFloat, marking: Bool = false) -> NSAttributedString {
        let all = NSRange(location: 0, length: text.length)
        guard width > 10, text.containsAttachments(in: all) else { return text }
        var result: NSMutableAttributedString?
        text.enumerateAttribute(.attachment, in: all) { value, range, _ in
            guard let attachment = value as? NSTextAttachment, isPicture(attachment) else { return }
            let size = OneNoteImport.displaySize(attachment)
            guard size.width > width + 0.5, size.width > 0 else { return }
            let shown = copy(attachment, size: NSSize(width: width, height: (size.height * width / size.width).rounded()))
            if result == nil { result = NSMutableAttributedString(attributedString: text) }
            result!.addAttribute(.attachment, value: shown, range: range)
            if marking { result!.addAttribute(.mxShownPicture, value: attachment, range: range) }
        }
        return result ?? text
    }

    /// Puts the saved pictures back in place of their scaled copies (text typed in a cell, before it's saved).
    static func restore(_ text: NSMutableAttributedString) {
        let all = NSRange(location: 0, length: text.length)
        text.enumerateAttribute(.mxShownPicture, in: all) { value, range, _ in
            guard let original = value as? NSTextAttachment else { return }
            for i in range.location..<NSMaxRange(range) {
                if let shown = text.attribute(.attachment, at: i, effectiveRange: nil) as? NSTextAttachment,
                   shown.fileWrapper === original.fileWrapper {
                    text.addAttribute(.attachment, value: original, range: NSRange(location: i, length: 1))
                }
            }
        }
        text.removeAttribute(.mxShownPicture, range: all)
    }

    /// The pictures on a line of their own (they follow the cell's width as its column is resized).
    static func ownLinePictures(_ text: NSAttributedString) -> [(index: Int, attachment: NSTextAttachment)] {
        let string = text.string as NSString
        var found: [(Int, NSTextAttachment)] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let attachment = value as? NSTextAttachment, isPicture(attachment), range.length == 1 else { return }
            let line = string.substring(with: string.paragraphRange(for: range)).trimmingCharacters(in: .whitespacesAndNewlines)
            if line == "\u{FFFC}" { found.append((range.location, attachment)) }
        }
        return found
    }

    /// The cell's only content, when that is one picture.
    static func onlyPicture(_ text: NSAttributedString) -> NSTextAttachment? {
        guard text.string.trimmingCharacters(in: .whitespacesAndNewlines) == "\u{FFFC}" else { return nil }
        return ownLinePictures(text).first?.attachment
    }
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
        if align != nil { align = Self.padded(align, rows: rows.count, columns: columns) }
        if columnWidths.count != columns {
            let average = columnWidths.isEmpty ? 120 : columnWidths.reduce(0, +) / Double(columnWidths.count)
            columnWidths = Array(columnWidths.prefix(columns))
            while columnWidths.count < columns { columnWidths.append(average) }
        }
    }

    /// Formatted cell text from stored data (RTFD, which can hold pictures; older tables used RTF).
    static func attributedCell(_ data: Data) -> NSAttributedString? {
        NoteRichText.text(data)
    }

    static func cellData(_ text: NSAttributedString) -> Data? {
        NoteRichText.data(text)
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
        shiftRows(at: i, by: 1)
        shading?.insert(Array(repeating: nil, count: columns), at: i)
        rich?.insert(Array(repeating: nil, count: columns), at: i)
        align?.insert(Array(repeating: nil, count: columns), at: i)
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
        shiftColumns(at: i, by: 1)
        if shading != nil {
            for r in shading!.indices {
                let color = shading![r].indices.contains(neighbor) ? shading![r][neighbor] : nil
                shading![r].insert(color, at: i)
            }
        }
        if rich != nil { for r in rich!.indices { rich![r].insert(nil, at: i) } }
        // A new column is aligned like the one beside it.
        if align != nil {
            for r in align!.indices { align![r].insert(align![r].indices.contains(neighbor) ? align![r][neighbor] : nil, at: i) }
        }
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
            if align != nil { align![index + 1][span.column] = align![index][span.column] }
            if shading != nil { shading![index + 1][span.column] = shading![index][span.column] }
        }
        rows.remove(at: index)
        shiftRows(at: index, by: -1)
        _ = shading?.remove(at: index)
        _ = rich?.remove(at: index)
        _ = align?.remove(at: index)
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
            if align != nil { align![span.row][index + 1] = align![span.row][index] }
            if shading != nil { shading![span.row][index + 1] = shading![span.row][index] }
        }
        for r in rows.indices { rows[r].remove(at: index) }
        shiftColumns(at: index, by: -1)
        merges = merges?.compactMap { span in
            var s = span
            if s.column > index { s.column -= 1 } else if index < s.column + s.columns { s.columns -= 1 }
            return s.rows * s.columns > 1 ? s : nil
        }
        if merges?.isEmpty == true { merges = nil }
        if shading != nil { for r in shading!.indices { shading![r].remove(at: index) } }
        if rich != nil { for r in rich!.indices { rich![r].remove(at: index) } }
        if align != nil { for r in align!.indices { align![r].remove(at: index) } }
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
        if let align { self.align = order.map { align[$0] } }
        var newIndex = Array(repeating: 0, count: order.count)
        for (new, old) in order.enumerated() { newIndex[old] = new }
        remapRows(newIndex)
        offsetMovedFormulas(order)
        if let merges {
            self.merges = merges.map { var m = $0; if m.rows == 1, m.row < newIndex.count { m.row = newIndex[m.row] }; return m }
        }
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

    /// The table as one undo step sees it.
    struct Snapshot {
        var data: TableData
        var width: CGFloat
    }

    /// The table after the last undo step; changes since then become the next step.
    private var undoBase: TableData
    /// Called with the table before a change that should be undoable, and the change's name.
    var onUndoable: ((Snapshot, String) -> Void)?

    init(data: TableData, width: CGFloat) {
        var data = data
        data.normalize()
        self.data = data
        self.undoBase = data
        self.width = width
    }

    var snapshot: Snapshot { Snapshot(data: data, width: width) }

    /// Records the changes since the last step as one undo step (nothing when the table is unchanged).
    func checkpoint(_ name: String, widthBefore: CGFloat? = nil) {
        guard data != undoBase else { return }
        let before = Snapshot(data: undoBase, width: widthBefore ?? width)
        undoBase = data
        onUndoable?(before, name)
    }

    /// Puts the table back as it was (undo / redo).
    func restore(_ snapshot: Snapshot) {
        data = snapshot.data
        undoBase = snapshot.data
        changed()
    }

    var rowCount: Int { data.rows.count }
    var columnCount: Int { data.columnCount }

    /// A column's width on the page (0 when hidden); the shown columns share the table's width.
    func columnWidth(_ column: Int) -> CGFloat {
        isColumnHidden(column) ? 0 : fullColumnWidth(column)
    }

    /// A column's width, also for a hidden column (the width it gets back when shown).
    func fullColumnWidth(_ column: Int) -> CGFloat {
        let total = data.columnWidths.indices.reduce(0) { isColumnHidden($1) ? $0 : $0 + data.columnWidths[$1] }
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
        (0..<rowCount).flatMap { r in
            (0..<columnCount).compactMap { c in data.isCovered(r, c) || !isShown(CellRef(row: r, column: c)) ? nil : CellRef(row: r, column: c) }
        }
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
        var attrs: [NSAttributedString.Key: Any] = [.font: baseFont(cell.row), .foregroundColor: autoColor(cell), .mxAutoColor: true]
        // Text typed into the cell takes the cell's own alignment.
        if let a = cellAlign(cell), a != .left {
            let style = NSMutableParagraphStyle()
            style.alignment = a
            attrs[.paragraphStyle] = style
        }
        return attrs
    }

    // MARK: Cell alignment

    static let alignNames: [(String, NSTextAlignment)] = [("left", .left), ("center", .center), ("right", .right), ("justified", .justified)]

    /// The cell's own alignment (nil: never set).
    func cellAlign(_ cell: CellRef) -> NSTextAlignment? {
        guard let a = data.align, a.indices.contains(cell.row), a[cell.row].indices.contains(cell.column), let name = a[cell.row][cell.column] else { return nil }
        return Self.alignNames.first { $0.0 == name }?.1
    }

    /// Sets cells' own alignment (left clears it).
    func setCellAlign(_ alignment: NSTextAlignment, _ cells: Set<CellRef>) {
        let name = alignment == .left || alignment == .natural ? nil : Self.alignNames.first { $0.1 == alignment }?.0
        guard name != nil || data.align != nil else { return }
        data.align = TableData.padded(data.align, rows: rowCount, columns: columnCount)
        for cell in cells where contains(cell) { data.align![cell.row][cell.column] = name }
        if data.align!.allSatisfy({ $0.allSatisfy { $0 == nil } }) { data.align = nil }
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

    /// The cell's text as shown: a formula's result; text without a chosen colour is black, or white on dark shading.
    func displayText(_ cell: CellRef) -> NSAttributedString {
        autoColored(shownText(cell), cell)
    }

    /// The cell's text as typed (a formula, not its result), for typing in the cell.
    func editingText(_ cell: CellRef) -> NSAttributedString {
        autoColored(storedText(cell), cell)
    }

    /// Stored text, with a formula replaced by its result (in the formula's formatting).
    func shownText(_ cell: CellRef) -> NSAttributedString {
        let stored = storedText(cell)
        let raw = stored.string
        if Formula.isFormula(raw) {
            let attrs = stored.length > 0 ? stored.attributes(at: 0, effectiveRange: nil) : [.font: baseFont(cell.row)]
            return NSAttributedString(string: shownString(cell), attributes: attrs)
        }
        // A number in a formatted cell shows in its format (typing in it shows the number as typed).
        if numberFormat(cell) != nil, let number = Formula.numeric(raw), let shown = formatted(number, in: cell) {
            let attrs = stored.length > 0 ? stored.attributes(at: 0, effectiveRange: nil) : [.font: baseFont(cell.row)]
            return NSAttributedString(string: shown, attributes: attrs)
        }
        // A leading apostrophe keeps text that starts with "=" as text ('=A1 shows =A1).
        if raw.hasPrefix("'="), stored.length > 1 { return stored.attributedSubstring(from: NSRange(location: 1, length: stored.length - 1)) }
        return stored
    }

    /// What the cell shows, as plain text (a formula's result).
    func shownString(_ cell: CellRef) -> String {
        let raw = text(cell)
        if Formula.isFormula(raw) {
            let v = value(cell)
            if case .number(let d) = v, let shown = formatted(d, in: cell) { return shown }
            if case .date(let d) = v, let shown = formatted(d, in: cell) { return shown }
            return v.display
        }
        if numberFormat(cell) != nil, let number = Formula.numeric(raw), let shown = formatted(number, in: cell) { return shown }
        return raw.hasPrefix("'=") ? String(raw.dropFirst()) : raw
    }

    // MARK: Formulas

    private var valueCache: [CellRef: FormulaValue] = [:]
    /// Conditional formatting's numbers and value counts per rule (worked out again after any change).
    var conditionalNumbers: [UUID: [Double]] = [:]
    var conditionalCounts: [UUID: [String: Int]] = [:]
    private var evaluating: Set<CellRef> = []

    /// A cell's value: its formula's result, or its text as a number / logical / text.
    func value(_ cell: CellRef) -> FormulaValue {
        guard contains(cell) else { return .error("#REF!") }
        let cell = master(cell)
        let raw = text(cell)
        guard Formula.isFormula(raw) else {
            return raw.hasPrefix("'=") ? .text(String(raw.dropFirst())) : Formula.value(ofText: raw)
        }
        if let cached = valueCache[cell] { return cached }
        guard !evaluating.contains(cell) else { return .error("#CIRC!") }
        evaluating.insert(cell)
        let result = Formula.evaluate(raw) { [unowned self] ref in
            let target = CellRef(row: ref.row, column: ref.column)
            guard self.contains(target) else { return nil }
            // A covered part of a merged cell is empty, as in Excel.
            if self.master(target) != target { return .empty }
            if self.evaluating.contains(target) { return .error("#CIRC!") }
            let v = self.value(target)
            if case .error("#CIRC!") = v { return v }
            return v
        }
        evaluating.remove(cell)
        valueCache[cell] = result
        return result
    }

    /// Formula results are worked out again after any change.
    func invalidateValues() { valueCache.removeAll() }

    private func autoColored(_ source: NSAttributedString, _ cell: CellRef) -> NSAttributedString {
        let text = NSMutableAttributedString(attributedString: source)
        let auto = autoColor(cell)
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attrs, range, _ in
            let value = attrs[.foregroundColor]
            if value == nil || Self.isBlack(value as? NSColor) && !CodeHighlighter.isCode(attrs) {
                text.addAttributes([.foregroundColor: auto, .mxAutoColor: true], range: range)
            }
        }
        return text
    }

    /// Display text with pictures scaled down to fit the cell's width (shown smaller; saved at their size).
    func displayText(_ cell: CellRef, fitting width: CGFloat) -> NSAttributedString {
        CellPictures.fitted(displayText(cell), width: width)
    }

    /// Saves edited cell text: automatic colours are dropped; rich text is kept only when there is formatting.
    func store(_ edited: NSAttributedString, in cell: CellRef) {
        guard contains(cell) else { return }
        let text = NSMutableAttributedString(attributedString: edited)
        CellPictures.restore(text)
        let all = NSRange(location: 0, length: text.length)
        text.enumerateAttribute(.mxAutoColor, in: all) { value, range, _ in
            if value != nil {
                text.removeAttribute(.foregroundColor, range: range)
                text.removeAttribute(.mxAutoColor, range: range)
            }
        }
        data.rows[cell.row][cell.column] = text.string
        // The cell remembers its text's alignment (an emptied cell keeps it, for what's typed next).
        if text.length > 0 {
            let style = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            setCellAlign(style?.alignment ?? .left, [cell])
        }
        let rtf = Self.isPlain(text, header: isHeader(cell.row)) ? nil : TableData.cellData(text)
        if rtf != nil || data.rich != nil {
            data.rich = TableData.padded(data.rich, rows: rowCount, columns: columnCount)
            data.rich![cell.row][cell.column] = rtf
            if data.rich!.allSatisfy({ $0.allSatisfy { $0 == nil } }) { data.rich = nil }
        }
        storedCache[cell] = text
        valueCache.removeAll()
        NotificationCenter.default.post(name: .mxTableChanged, object: self)
        conditionalNumbers.removeAll()
        conditionalCounts.removeAll()
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

    func changed() {
        defer { NotificationCenter.default.post(name: .mxTableChanged, object: self) }
        storedCache.removeAll()
        valueCache.removeAll()
        conditionalNumbers.removeAll()
        conditionalCounts.removeAll()
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
        data.columnWidths = (0..<columnCount).map { Double(fullColumnWidth($0)) }
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
        let next = shownRow(from: block.row + block.rows, step: 1) ?? rowCount
        let below = insertBelow ? block.row + block.rows : next
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

    /// The header row is pinned while scrolling (Header Row and Freeze Header Row both on).
    var headerRowFrozen: Bool { data.headerRow && data.freezeHeaderRow != false }

    func toggleFreezeHeaderRow() {
        data.freezeHeaderRow = data.freezeHeaderRow == false ? nil : false
        changed()
    }

    func toggleShowHeadings() {
        data.showHeadings = data.showHeadings == true ? nil : true
        changed()
    }

    func toggleFreezeFirstColumn() {
        data.freezeFirstColumn = (data.freezeFirstColumn ?? false) ? nil : true
        changed()
    }

    func toggleBorders() {
        data.hideBorders = !(data.hideBorders ?? false)
        changed()
    }

    /// Tables with cells merged across rows can't be sorted.
    var canSort: Bool { !(data.merges ?? []).contains { $0.rows > 1 } }

    /// Sorting leaves the first row in place (as a header) unless this is on; tables with Header Row on always keep it.
    static let sortIncludesFirstRowKey = "tableSortIncludesFirstRow"
    static var sortIncludesFirstRow: Bool { UserDefaults.standard.bool(forKey: sortIncludesFirstRowKey) }

    /// The first row is kept out of sorting.
    var firstRowIsHeader: Bool { data.headerRow || filterOn || !Self.sortIncludesFirstRow }

    func sort(byColumn column: Int, ascending: Bool) {
        guard canSort else { return NSSound.beep() }
        let skip = firstRowIsHeader && rowCount > 1 ? 1 : 0
        // Rows of totals (formulas over a range, such as =SUM(B2:B9)) stay where they are; the rest are sorted
        // into the other places.
        let all = Array(skip..<rowCount)
        let pinned = Set(all.filter { r in data.rows[r].contains { Formula.isFormula($0) && $0.contains(":") } })
        var body = all.filter { !pinned.contains($0) }
        // Numbers by value (2 before 10, -5 before 1), text ignoring case, blank cells last either way — as in Excel.
        // Numbers and dates sort by value.
        let key = { (r: Int) -> (number: Double?, text: String) in
            let cell = CellRef(row: r, column: column)
            switch self.value(cell) {
            case .number(let d), .date(let d): return (d, "x")
            default: return (nil, Self.filterValue(self.shownString(cell)))
            }
        }
        body.sort {
            let a = key($0), b = key($1)
            let aBlank = a.number == nil && a.text.isEmpty, bBlank = b.number == nil && b.text.isEmpty
            if aBlank != bBlank { return bBlank }
            let order: ComparisonResult
            if let x = a.number, let y = b.number {
                order = x == y ? .orderedSame : x < y ? .orderedAscending : .orderedDescending
            } else if (a.number != nil) != (b.number != nil) {
                order = a.number != nil ? .orderedAscending : .orderedDescending
            } else {
                order = a.text.localizedStandardCompare(b.text)
            }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
        var rest = body.makeIterator()
        data.reorderRows(Array(0..<skip) + all.map { pinned.contains($0) ? $0 : rest.next()! })
        applyFilters()
        changed()
    }

    /// Whether rows can move: the header row stays first, and rows inside a block merged across rows don't move.
    func canMoveRows(_ rows: ClosedRange<Int>, by offset: Int) -> Bool {
        let top = data.headerRow ? 1 : 0
        guard rows.lowerBound + offset >= top, rows.upperBound + offset < rowCount, rows.lowerBound >= top else { return false }
        return !(data.merges ?? []).contains { $0.rows > 1 }
    }

    /// Moves a run of rows up (negative) or down (positive) by a number of rows.
    func moveRows(_ rows: ClosedRange<Int>, by offset: Int) {
        guard offset != 0, canMoveRows(rows, by: offset) else { return }
        var order = Array(0..<rowCount)
        let moving = Array(rows)
        order.removeSubrange(rows)
        order.insert(contentsOf: moving, at: rows.lowerBound + offset)
        data.reorderRows(order)
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
final class TableGridView: NSView, NSTextViewDelegate, SetsOwnPointer {
    static let padX: CGFloat = 6
    static let padY: CGFloat = 4
    static let minRowHeight: CGFloat = 24
    static let minManualHeight: CGFloat = 10
    private static let borderColor = NSColor(srgbRed: 0.64, green: 0.64, blue: 0.64, alpha: 1)

    /// The table being edited or with selected cells (the Table ribbon and cell formatting act on it).
    static weak var active: TableGridView? {
        didSet {
            NotebookStore.shared.editor.tableActive = active != nil
            if oldValue !== active { oldValue?.updateColumnBar() }
            active?.updateColumnBar()
        }
    }

    weak var owner: TableElementView?
    let model: TableModel
    var isExport = false
    private(set) var selection: Set<CellRef> = [] {
        didSet {
            guard selection != oldValue else { return }
            columnBar?.needsDisplay = true
            rowBar?.needsDisplay = true
            if (selection.isEmpty) != (oldValue.isEmpty) { updateColumnBar() }
            guard editing == nil, !selection.isEmpty, !isExport else { return }
            reportCellFormatting()
        }
    }

    /// Shows the selected cells' font in the ribbon.
    func reportCellFormatting() {
        TextFormatter.reportFormatting(of: selection.sorted { ($0.row, $0.column) < ($1.row, $1.column) }
            .map { model.displayText($0) })
    }
    private var anchor: CellRef?
    /// Row boundary where dragged rows would be dropped.
    private var dropLine: Int?
    /// The moving corner of a ⇧-extended selection.
    private var extent: CellRef?
    /// The cell's text before typing began (to put back an entry that breaks its validation rule).
    private var editingOriginal: NSAttributedString?
    /// Circle Invalid Data: values that break their cell's validation rule are circled.
    var circleInvalid = false {
        didSet { needsDisplay = true }
    }
    /// The cell being typed in.
    var editingCell: CellRef? { editing }

    private(set) var editing: CellRef? {
        didSet { if (editing == nil) != (oldValue == nil) { updateColumnBar() } }
    }
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
        editor.pasteHandler = { [weak self] in self?.pasteWhileTyping() ?? false }
        // A picture's edges resize it in the cell being typed in too.
        editor.cursorHandler = { [weak self] event in
            guard let self, let edge = self.picture(at: self.convert(event.locationInWindow, from: nil))?.edge else { return nil }
            return Self.cursor(for: edge)
        }
        editor.mouseDownHandler = { [weak self] event in
            guard let self, let hit = self.picture(at: self.convert(event.locationInWindow, from: nil)), hit.edge != nil else { return false }
            self.resizePicture(hit, from: event)
            return true
        }
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
        didSet { if oldValue != stickyOffset { needsDisplay = true; rowBar?.needsDisplay = true } }
    }

    var headerHeight: CGFloat { rowHeights.first ?? 0 }
    var tableHeight: CGFloat { rowTops.last ?? 0 }
    private var stickyActive: Bool { stickyOffset > 0 && model.headerRowFrozen && model.rowCount > 1 }

    /// Where the pinned header row is drawn (y and height in this view), while it's pinned.
    var pinnedHeaderBand: (y: CGFloat, height: CGFloat)? { stickyActive ? (stickyOffset, headerHeight) : nil }

    /// A point on the pinned header counts as a point in the real header row.
    private func unpinned(_ point: NSPoint) -> NSPoint {
        var point = point
        if stickyColumnActive, point.x >= stickyLeft, point.x < stickyLeft + frozenWidth { point.x -= stickyLeft }
        guard stickyActive, point.y >= stickyOffset, point.y < stickyOffset + headerHeight else { return point }
        return NSPoint(x: point.x, y: point.y - stickyOffset)
    }

    // MARK: Frozen first column

    /// How far the frozen first column is drawn right of its place (0 = not pinned).
    var stickyLeft: CGFloat = 0 {
        didSet {
            guard oldValue != stickyLeft else { return }
            needsDisplay = true
            positionEditor()
            columnBar?.needsDisplay = true
        }
    }

    /// The column that stays in view (the first shown one), when Freeze First Column is on.
    var frozenColumn: Int? {
        guard model.data.freezeFirstColumn == true, model.shownColumns.count > 1 else { return nil }
        return model.shownColumns.first
    }

    var frozenWidth: CGFloat {
        guard let c = frozenColumn, c + 1 < columnLefts.count else { return 0 }
        return columnLefts[c + 1] - columnLefts[c]
    }

    var stickyColumnActive: Bool { stickyLeft > 0 && frozenColumn != nil && !isExport }

    private func drawFrozenColumn(_ showSelection: Bool) {
        guard stickyColumnActive, let column = frozenColumn else { return }
        let width = frozenWidth, height = rowTops.last ?? 0
        let band = NSRect(x: stickyLeft, y: 0, width: width, height: height)
        NSColor.white.setFill()
        band.fill()
        NSGradient(starting: NSColor(white: 0, alpha: 0.18), ending: NSColor(white: 0, alpha: 0))?
            .draw(in: NSRect(x: band.maxX, y: 0, width: 4, height: height), angle: 0)
        NSGraphicsContext.saveGraphicsState()
        band.clip()
        let shift = NSAffineTransform()
        shift.translateX(by: stickyLeft, yBy: 0)
        shift.concat()
        let cells = model.visibleCells.filter { $0.column == column }
        let lines = NSBezierPath()
        for cell in cells {
            drawCell(cell, showSelection: showSelection)
            lines.appendRect(cellRect(cell))
        }
        lines.lineWidth = 0.75
        Self.borderColor.setStroke()
        if !(model.data.hideBorders ?? false) { lines.stroke() }
        if showSelection {
            NSColor.controlAccentColor.setStroke()
            for cell in cells where selection.contains(cell) {
                let path = NSBezierPath(rect: cellRect(cell).insetBy(dx: 1, dy: 1))
                path.lineWidth = 1.5
                path.stroke()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
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
            drawText(model.displayText(cell, fitting: rect.width - 2 * Self.padX), in: rect.insetBy(dx: Self.padX, dy: Self.padY))
            grid.appendRect(rect)
        }
        // Frozen first column too: its header cell stays in the corner.
        if stickyColumnActive, let column = frozenColumn {
            let cell = model.master(CellRef(row: 0, column: column))
            var rect = cellRect(cell)
            rect.origin = NSPoint(x: stickyLeft, y: stickyOffset)
            rect.size = NSSize(width: frozenWidth, height: headerHeight)
            (model.data.shade(0, column)?.nsColor ?? .white).setFill()
            rect.fill()
            drawText(model.displayText(cell, fitting: rect.width - 2 * Self.padX), in: rect.insetBy(dx: Self.padX, dy: Self.padY))
            grid.appendRect(rect)
        }
        grid.lineWidth = 0.75
        Self.borderColor.setStroke()
        if !(model.data.hideBorders ?? false) { grid.stroke() }
    }

    /// Starts typing in a row at an x position (in this view), on the cell's first or last line.
    private func enterRow(_ row: Int, atX x: CGFloat, lastLine: Bool) {
        let row = model.shownRow(from: row, step: lastLine ? -1 : 1) ?? row
        var column = max(0, min(model.columnCount - 1, (columnLefts.lastIndex { $0 <= x } ?? 0)))
        column = model.shownColumn(from: column, step: -1) ?? model.shownColumn(from: column, step: 1) ?? column
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

    /// The cell under a point (for Quick Help).
    func cellRef(at point: NSPoint) -> CellRef? { cell(at: point) }

    private func cell(at point: NSPoint) -> CellRef? {
        let point = unpinned(point)
        guard model.rowCount > 0, model.columnCount > 0 else { return nil }
        var row = max(0, min(model.rowCount - 1, (rowTops.lastIndex { $0 <= point.y } ?? 0)))
        var column = max(0, min(model.columnCount - 1, (columnLefts.lastIndex { $0 <= point.x } ?? 0)))
        // Hidden rows and columns have no size; land on the shown one before them.
        row = model.shownRow(from: row, step: -1) ?? model.shownRow(from: row, step: 1) ?? row
        column = model.shownColumn(from: column, step: -1) ?? model.shownColumn(from: column, step: 1) ?? column
        return model.master(CellRef(row: row, column: column))
    }

    /// Index of the column whose right border is under the point (for resizing).
    private func columnBorder(at point: NSPoint) -> Int? {
        guard !isExport else { return nil }
        for c in 0..<model.columnCount where !model.isColumnHidden(c) && abs(columnLefts[c + 1] - point.x) <= 3 { return c }
        return nil
    }

    private func measure(_ cell: CellRef) -> CGFloat {
        if editing != cell, let cached = heightCache[cell] { return cached }
        let width = max(blockWidth(cell) - 2 * Self.padX, 10)
        let text = editing == cell ? (editor.textStorage ?? NSAttributedString()) : model.displayText(cell, fitting: width)
        var height = text.length == 0 ? model.baseFont(cell.row).boundingRectForFont.height
            : Self.hasBlocks(text) ? blockTextHeight(text, width: width)
            : text.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        if text.string.hasSuffix("\n"), !Self.hasBlocks(text) { height += model.baseFont(cell.row).pointSize * 1.25 }
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
            if model.isRowHidden(r) { return 0 }
            // A height set by dragging stays (text that doesn't fit is cut off), except while typing in the row.
            if let manual = model.manualHeight(r), editing?.row != r { return max(Self.minManualHeight, manual) }
            let tallest = (0..<model.columnCount).compactMap { c -> CGFloat? in
                let cell = CellRef(row: r, column: c)
                guard !model.data.isCovered(r, c), !model.isColumnHidden(c), model.span(cell).rows == 1 else { return nil }
                return measure(cell)
            }.max() ?? 0
            let fit = max(Self.minRowHeight, tallest + 2 * Self.padY)
            return max(fit, model.manualHeight(r) ?? 0)
        }
        // A merged cell taller than its rows makes its last row taller.
        for block in model.data.merges ?? [] where block.rows > 1 && block.row + block.rows <= rowHeights.count
            && !model.isRowHidden(block.row + block.rows - 1) {
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
        updateColumnBar()
    }

    // MARK: Cursors

    private var cursorTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTracking { removeTrackingArea(cursorTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .mouseEnteredAndExited,
                                                         .activeInKeyWindow, .inVisibleRect],
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

    /// Whether the text has a code block (or other text block), which boundingRect and draw(with:) don't handle.
    static func hasBlocks(_ text: NSAttributedString) -> Bool {
        var blocks = false
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            if let style = value as? NSParagraphStyle, !style.textBlocks.isEmpty { blocks = true; stop.pointee = true }
        }
        return blocks
    }

    private func blockTextHeight(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        let (storage, layout, container) = layout(text, width: width)
        layout.ensureLayout(for: container)
        return withExtendedLifetime(storage) { layout.usedRect(for: container).height }
    }

    /// Draws a cell's text; code blocks go through a layout manager, which also paints their shading.
    private func drawText(_ text: NSAttributedString, in rect: NSRect) {
        guard Self.hasBlocks(text) else {
            text.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
            return
        }
        let (storage, layout, container) = layout(text, width: rect.width)
        let glyphs = layout.glyphRange(for: container)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect.insetBy(dx: -Self.padX + 1, dy: -Self.padY + 1)).addClip()
        layout.drawBackground(forGlyphRange: glyphs, at: rect.origin)
        layout.drawGlyphs(forGlyphRange: glyphs, at: rect.origin)
        NSGraphicsContext.restoreGraphicsState()
        withExtendedLifetime(storage) {}
    }

    /// Lays out a drawn cell's text the way draw(_:) shows it.
    private func layout(_ text: NSAttributedString, width: CGFloat) -> (NSTextStorage, NSLayoutManager, NSTextContainer) {
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        return (storage, layout, container)
    }

    /// The character under a point in a cell that isn't being typed in: (cell, text, character index).
    private func character(at p: NSPoint) -> (CellRef, NSAttributedString, Int)? {
        guard let cell = cell(at: p), cell != editing else { return nil }
        let rect = cellRect(cell).insetBy(dx: Self.padX, dy: Self.padY)
        guard rect.contains(unpinned(p)) || rect.contains(p) else { return nil }
        let text = model.displayText(cell, fitting: rect.width)
        guard text.length > 0 else { return nil }
        let (storage, layout, container) = self.layout(text, width: rect.width)
        let point = rect.contains(p) ? p : unpinned(p)
        let local = NSPoint(x: point.x - rect.minX, y: point.y - rect.minY)
        let glyph = layout.glyphIndex(for: local, in: container, fractionOfDistanceThroughGlyph: nil)
        guard layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(local) else { return nil }
        let index = layout.characterIndexForGlyph(at: glyph)
        guard index < storage.length else { return nil }
        return (cell, text, index)
    }

    /// The link under a point in a cell that isn't being typed in.
    func link(at p: NSPoint) -> URL? {
        guard let (_, text, index) = character(at: p) else { return nil }
        let value = text.attribute(.link, at: index, effectiveRange: nil)
        return value as? URL ?? (value as? String).flatMap { URL(string: $0) }
    }

    // MARK: Spelling in cells

    private let spellTag = NSSpellChecker.uniqueSpellDocumentTag()
    private var spellCache: [String: [NSRange]] = [:]

    /// Misspelled words of a cell's text (code is not checked).
    func misspellings(_ text: NSAttributedString) -> [NSRange] {
        let string = text.string
        guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !CodeHighlighter.isCode(text.attributes(at: 0, effectiveRange: nil)) else { return [] }
        if let cached = spellCache[string] { return cached }
        let results = NSSpellChecker.shared.check(string, range: NSRange(location: 0, length: (string as NSString).length),
                                                  types: NSTextCheckingResult.CheckingType.spelling.rawValue, options: nil,
                                                  inSpellDocumentWithTag: spellTag, orthography: nil, wordCount: nil)
        let ranges = results.map(\.range)
        spellCache[string] = ranges
        return ranges
    }

    /// Red dotted underlines under misspelled words of a drawn cell.
    private func drawMisspellings(_ text: NSAttributedString, in rect: NSRect) {
        let ranges = misspellings(text)
        guard !ranges.isEmpty else { return }
        let (storage, layout, container) = layout(text, width: rect.width)
        NSColor.systemRed.setFill()
        for range in ranges {
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                           in: container) { line, _ in
                var x = rect.minX + line.minX + 1
                let y = rect.minY + line.maxY - 1.5
                while x < rect.minX + line.maxX - 1 {
                    NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 2, height: 2)).fill()
                    x += 4
                }
            }
        }
    }

    /// Spelling suggestions for the word under a point (right-click), as menu items.
    private func spellingItems(at p: NSPoint) -> [NSMenuItem] {
        guard let (cell, text, index) = character(at: p),
              let range = misspellings(text).first(where: { NSLocationInRange(index, $0) }) else { return [] }
        let word = (text.string as NSString).substring(with: range)
        let guesses = NSSpellChecker.shared.guesses(forWordRange: range, in: text.string, language: nil,
                                                    inSpellDocumentWithTag: spellTag) ?? []
        var items: [NSMenuItem] = guesses.prefix(6).map { guess in
            let item = ClosureMenuItem(guess) { [weak self] in
                guard let self else { return }
                let updated = NSMutableAttributedString(attributedString: self.model.storedText(cell))
                guard NSMaxRange(range) <= updated.length else { return }
                updated.replaceCharacters(in: range, with: guess)
                self.model.store(updated, in: cell)
                self.invalidateLayout()
                self.relayout()
                self.owner?.controller?.markDirty()
            }
            item.attributedTitle = NSAttributedString(string: guess, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
            return item
        }
        if items.isEmpty {
            let none = NSMenuItem(title: "No Guesses Found", action: nil, keyEquivalent: "")
            none.isEnabled = false
            items.append(none)
        }
        items.append(.separator())
        items.append(ClosureMenuItem("Ignore Spelling") { [weak self] in
            guard let self else { return }
            NSSpellChecker.shared.ignoreWord(word, inSpellDocumentWithTag: self.spellTag)
            self.spellCache.removeAll()
            self.needsDisplay = true
        })
        items.append(ClosureMenuItem("Learn Spelling") { [weak self] in
            NSSpellChecker.shared.learnWord(word)
            self?.spellCache.removeAll()
            self?.needsDisplay = true
        })
        items.append(.separator())
        return items
    }

    /// Resize on column borders, move on the outer edges, pointing hand on links, text cursor in cells.
    func cursor(at p: NSPoint) -> NSCursor {
        if let handle = fillHandleRect, handle.insetBy(dx: -3, dy: -3).contains(p) { return .crosshair }
        if filterButton(at: p) != nil { return .arrow }
        if columnBorder(at: p) != nil { return .resizeLeftRight }
        if rowBorder(at: p) != nil { return .resizeUpDown }
        if onOuterEdge(p) { return .openHand }
        if let edge = picture(at: p)?.edge { return Self.cursor(for: edge) }
        if selectedWholeRows != nil, let cell = cell(at: p), selection.contains(cell) { return .openHand }
        if link(at: p) != nil { return .pointingHand }
        return .iBeam
    }

    private func updateCursor(_ event: NSEvent) {
        guard !isExport, NotebookStore.shared.editor.tool == .type, event.window === window else { return }
        let p = convert(event.locationInWindow, from: nil)
        // As the first responder it hears every move in the window: outside the table the pointer isn't its to set.
        guard bounds.contains(p), visibleRect.contains(p) else { hoveredPicture = nil; return }
        hoveredPicture = picture(at: p)
        if let edge = hoveredPicture?.edge, !onOuterEdge(p) { return Self.cursor(for: edge).set() }
        // A formula cell shows its formula as a tip.
        if let cell = cell(at: p), cell != editing, Formula.isFormula(model.text(cell)) {
            if toolTip != model.text(cell) { toolTip = model.text(cell) }
        } else if toolTip != nil {
            toolTip = nil
        }
        // While typing in a cell, the editor shows its own cursor (and links) inside the cell.
        if let editing, cellRect(editing).insetBy(dx: Self.padX, dy: Self.padY).contains(p) { return }
        cursor(at: p).set()
        hoverLink(at: p)
    }

    /// The hover card for a link in a cell that isn't being typed in: Edit Link and Remove type in the cell.
    private func hoverLink(at p: NSPoint) {
        let hit = character(at: p)
        let found = hit.flatMap { cell, text, index -> (CellRef, URL)? in
            let value = text.attribute(.link, at: index, effectiveRange: nil)
            return (value as? URL ?? (value as? String).flatMap { URL(string: $0) }).map { (cell, $0) }
        }
        // The link's words and hover text.
        var words: String?, tip: NSAttributedString?
        if let (_, text, index) = hit, found != nil {
            var range = NSRange()
            _ = text.attribute(.link, at: index, longestEffectiveRange: &range, in: NSRange(location: 0, length: text.length))
            words = (text.string as NSString).substring(with: range)
            tip = NoteRichText.tip(in: text, at: index)
        }
        let rect = found.map { cellRect($0.0).insetBy(dx: Self.padX, dy: Self.padY) } ?? .zero
        LinkHover.shared.pointer(over: found?.1, rect: rect, in: self) { [weak self] in
            LinkHoverActions(edit: {
                guard let self, let (cell, url) = found, let range = self.typeInLink(url, in: cell) else { return }
                self.editor.setSelectedRange(NSRange(location: range.location, length: 0))
                NotebookStore.shared.beginInsertLink()
            }, remove: {
                guard let self, let (cell, url) = found, let range = self.typeInLink(url, in: cell) else { return }
                self.editor.setSelectedRange(range)
                TextFormatter.removeLink()
            }, tip: tip, text: words)
        }
    }

    /// Starts typing in a cell and finds a link in it.
    private func typeInLink(_ url: URL, in cell: CellRef) -> NSRange? {
        beginEditing(cell)
        guard let storage = editor.textStorage else { return nil }
        var found: NSRange?
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            let u = value as? URL ?? (value as? String).flatMap { URL(string: $0) }
            if u == url { found = range; stop.pointee = true }
        }
        return found
    }

    override func mouseMoved(with event: NSEvent) { updateCursor(event) }
    override func cursorUpdate(with event: NSEvent) { updateCursor(event) }
    override func mouseExited(with event: NSEvent) { hoveredPicture = nil }

    private func open(_ url: URL) {
        if url.scheme == NotebookStore.linkScheme {
            NotebookStore.shared.openLink(url)
        } else if url.scheme == OneNoteImport.missingScheme {
            ImportActivity.shared.locateMissingPictures()
        } else {
            WebBrowser.open(url)
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let showSelection = !isExport && (selection.count > 1 || (editing == nil && !selection.isEmpty))
        let hideBorders = model.data.hideBorders ?? false
        let visible = model.visibleCells
        for cell in visible where cellRect(cell).intersects(dirtyRect) {
            drawCell(cell, showSelection: showSelection)
        }
        let grid = NSBezierPath()
        for cell in visible { grid.appendRect(cellRect(cell)) }
        defer { drawStickyHeader() }
        defer { drawFrozenColumn(showSelection) }
        defer { drawPictureFrame() }
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
        if showSelection || (editing == nil && !selection.isEmpty) { drawFillHandle() }
        if let dropLine, rowTops.indices.contains(dropLine) {
            NSColor.controlAccentColor.setFill()
            NSRect(x: 0, y: rowTops[dropLine] - 1.5, width: columnLefts.last ?? bounds.width, height: 3).fill()
        }
    }

    // MARK: Filter buttons

    static let filterButtonSize: CGFloat = 16

    /// Header-row cells show a filter button while filters are on.
    private func hasFilterButton(_ cell: CellRef) -> Bool {
        !isExport && model.filterOn && cell.row == 0 && model.rowCount > 1
    }

    private func filterButtonRect(_ cell: CellRef) -> NSRect {
        let rect = cellRect(cell)
        let size = Self.filterButtonSize
        return NSRect(x: rect.maxX - size - 3, y: rect.minY + min(4, max(0, (rect.height - size) / 2)), width: size, height: size)
    }

    private func drawFilterButton(_ cell: CellRef) {
        let rect = filterButtonRect(cell)
        let filtered = model.isFiltered(cell.column)
        let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        (filtered ? NSColor.controlAccentColor.withAlphaComponent(0.18) : NSColor.white).setFill()
        path.fill()
        NSColor(white: 0.6, alpha: 1).setStroke()
        path.lineWidth = 0.75
        path.stroke()
        let symbol = filtered ? "line.3.horizontal.decrease" : "chevron.down"
        let config = NSImage.SymbolConfiguration(pointSize: filtered ? 9 : 8, weight: .semibold)
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Filter")?.withSymbolConfiguration(config) {
            let tinted = NSImage(size: image.size, flipped: false) { r in
                image.draw(in: r)
                (filtered ? NSColor.controlAccentColor : NSColor(white: 0.3, alpha: 1)).set()
                r.fill(using: .sourceAtop)
                return true
            }
            let s = tinted.size
            tinted.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    private func filterButton(at p: NSPoint) -> CellRef? {
        guard model.filterOn, model.rowCount > 1 else { return nil }
        let p = unpinned(p)
        for c in model.shownColumns {
            let cell = model.master(CellRef(row: 0, column: c))
            if cell.row == 0, filterButtonRect(cell).insetBy(dx: -2, dy: -2).contains(p) { return cell }
        }
        return nil
    }

    private var filterPopover: NSPopover?

    func closeFilter() {
        filterPopover?.close()
        filterPopover = nil
    }

    /// The filter button's popover: sort, search and pick the values to show.
    func showFilter(_ column: Int) {
        let cell = model.master(CellRef(row: 0, column: column))
        endEditing()
        let header = model.text(cell).trimmingCharacters(in: .whitespacesAndNewlines)
        closeFilter()
        let popover = NSPopover()
        popover.behavior = .transient
        let view = TableFilterView(
            title: header.isEmpty ? "Column \(TableData.columnName(column))" : header,
            values: model.values(in: column),
            filter: model.filter(for: column) ?? ColumnFilter(column: column),
            fillColors: model.colors(in: column, fill: true), fontColors: model.colors(in: column, fill: false),
            sort: { [weak self] ascending in self?.sortColumn(column, ascending: ascending) },
            sortByColor: { [weak self] hex, fill in self?.sortColumn(column, byColor: hex, fill: fill) },
            apply: { [weak self] filter in self?.applyFilter(filter) },
            close: { [weak popover] in popover?.performClose(nil) })
        popover.contentViewController = NSHostingController(rootView: view)
        filterPopover = popover
        popover.show(relativeTo: filterButtonRect(cell), of: self, preferredEdge: .maxY)
    }

    func applyFilter(_ filter: ColumnFilter) {
        guard model.canSort else { return NSSound.beep() }
        run(filter.isActive ? "Filter" : "Clear Filter") { model.setFilter(filter) }
    }

    /// Sort by Color: rows with the fill (or font) colour to the top or bottom.
    func sortColumn(_ column: Int, byColor hex: String, fill: Bool, onTop: Bool = true) {
        run("Sort by Color") { model.sort(byColor: hex, column: column, fill: fill, onTop: onTop) }
    }

    /// Menu items to sort or filter a column by its fill and font colours.
    func colorMenuItems(for column: Int) -> [NSMenuItem] {
        let fills = model.colors(in: column, fill: true), fonts = model.colors(in: column, fill: false)
        func swatch(_ hex: String) -> NSImage? { TableModel.color(hex: hex).map { Palette.swatch($0) } }
        func name(_ hex: String, fill: Bool) -> String { hex == "none" ? "No Fill" : hex == "auto" ? "Automatic" : "#" + hex }
        func submenu(_ title: String, _ action: @escaping (String, Bool) -> Void) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu()
            for (fill, list) in [(true, fills), (false, fonts)] where list.count > 1 || list.first.map({ $0 != "none" && $0 != "auto" }) == true {
                let header = NSMenuItem(title: fill ? "Cell Color" : "Font Color", action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
                for hex in list {
                    let entry = ClosureMenuItem(name(hex, fill: fill)) { action(hex, fill) }
                    entry.image = swatch(hex)
                    menu.addItem(entry)
                }
            }
            if menu.items.isEmpty {
                let none = NSMenuItem(title: "No colours in this column", action: nil, keyEquivalent: "")
                none.isEnabled = false
                menu.addItem(none)
            }
            item.submenu = menu
            return item
        }
        return [
            submenu("Sort by Color") { [weak self] hex, fill in self?.sortColumn(column, byColor: hex, fill: fill) },
            submenu("Filter by Color") { [weak self] hex, fill in
                var f = ColumnFilter(column: column)
                if fill { f.fillColor = hex } else { f.fontColor = hex }
                self?.applyFilter(f)
            },
        ]
    }

    func toggleFilter() {
        guard model.filterOn || model.canSort else { return NSSound.beep() }
        run("Filter") { model.toggleAutoFilter() }
    }

    func clearAllFilters() { run("Clear Filter") { model.clearAllFilters() } }

    func sortColumn(_ column: Int, ascending: Bool) { run("Sort") { model.sort(byColumn: column, ascending: ascending) } }

    // MARK: Columns (Excel style)

    /// Left edges of the columns, and the table's right edge.
    var columnEdges: [CGFloat] { columnLefts }

    /// Columns whose every shown cell is selected.
    var selectedWholeColumns: Set<Int> {
        guard editing == nil, !selection.isEmpty else { return [] }
        let columns = Set(selection.map(\.column))
        return columns.filter { c in
            (0..<model.rowCount).allSatisfy { r in
                let cell = CellRef(row: r, column: c)
                return !model.isShown(cell) || model.data.isCovered(r, c) || selection.contains(cell)
                    || selection.contains(model.master(cell))
            }
        }
    }

    /// Selects whole columns (from the column bar or ⌃Space).
    func selectColumns(_ a: Int, _ b: Int) {
        endEditing()
        becameActive()
        let top = model.shownRow(from: 0, step: 1) ?? 0
        let bottom = model.shownRow(from: model.rowCount - 1, step: -1) ?? model.rowCount - 1
        selectRange(CellRef(row: top, column: min(a, b)), CellRef(row: bottom, column: max(a, b)))
        anchor = CellRef(row: top, column: a)
        extent = CellRef(row: bottom, column: b)
        window?.makeFirstResponder(self)
        columnBar?.needsDisplay = true
    }

    private var targetColumns: [Int] {
        let whole = selectedWholeColumns
        if !whole.isEmpty { return whole.sorted() }
        return selectedColumns.isEmpty ? [targetCell.column] : selectedColumns
    }

    func hideColumns() {
        let columns = targetColumns
        guard model.canHide(columns) else { return NSSound.beep() }
        run(columns.count > 1 ? "Hide Columns" : "Hide Column") { model.hideColumns(columns) }
        selection = []
    }

    func unhideColumns(_ columns: [Int]? = nil) {
        guard model.hasHiddenColumns else { return }
        run("Unhide Columns") { model.unhideColumns(columns) }
    }

    /// The column bar's right-click menu.
    func columnMenu(for column: Int) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let columns = targetColumns
        let n = columns.count
        let sortable = model.canSort
        for (title, ascending) in [("Sort A to Z", true), ("Sort Z to A", false)] {
            let item = ClosureMenuItem(title) { [weak self] in self?.sortColumn(column, ascending: ascending) }
            item.isEnabled = sortable
            menu.addItem(item)
        }
        let filter = ClosureMenuItem("Filter…") { [weak self] in
            guard let self else { return }
            if !self.model.filterOn { self.toggleFilter() }
            self.showFilter(column)
        }
        filter.isEnabled = sortable && model.rowCount > 1
        menu.addItem(filter)
        if model.isFiltered(column) {
            menu.addItem(ClosureMenuItem("Clear Filter") { [weak self] in self?.applyFilter(ColumnFilter(column: column)) })
        }
        for item in colorMenuItems(for: column) {
            item.isEnabled = sortable && model.rowCount > 1
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let hide = ClosureMenuItem(n > 1 ? "Hide \(n) Columns" : "Hide Column") { [weak self] in self?.hideColumns() }
        hide.isEnabled = model.canHide(columns)
        menu.addItem(hide)
        let unhide = ClosureMenuItem("Unhide Columns") { [weak self] in self?.unhideColumns() }
        unhide.isEnabled = model.hasHiddenColumns
        menu.addItem(unhide)
        menu.addItem(.separator())
        menu.addItem(alignmentMenuItem())
        let numbers = NSMenuItem(title: "Number Format", action: nil, keyEquivalent: "")
        numbers.submenu = numberFormatMenu()
        menu.addItem(numbers)
        let conditional = NSMenuItem(title: "Conditional Formatting", action: nil, keyEquivalent: "")
        conditional.submenu = conditionalMenu()
        menu.addItem(conditional)
        let validation = NSMenuItem(title: "Data Validation", action: nil, keyEquivalent: "")
        validation.submenu = validationMenu()
        menu.addItem(validation)
        menu.addItem(ClosureMenuItem(n > 1 ? "Auto-Fit \(n) Columns" : "Auto-Fit Column Width") { [weak self] in
            self?.autoFitColumns(columns)
        })
        menu.addItem(ClosureMenuItem("Auto-Fit All Columns") { [weak self] in
            guard let self else { return }
            self.autoFitColumns(Array(0..<self.model.columnCount))
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(insertCount.columns > 1 ? "Insert \(insertCount.columns) Columns Left" : "Insert Column Left") { [weak self] in self?.insertColumnLeft() })
        menu.addItem(ClosureMenuItem(insertCount.columns > 1 ? "Insert \(insertCount.columns) Columns Right" : "Insert Column Right") { [weak self] in self?.insertColumnRight() })
        menu.addItem(ClosureMenuItem(n > 1 ? "Delete \(n) Columns" : "Delete Column") { [weak self] in self?.deleteColumns() })
        menu.addItem(ClosureMenuItem(n > 1 ? "Clear \(n) Columns" : "Clear Column") { [weak self] in self?.clearCells() })
        menu.addItem(.separator())
        let freezeHeader = ClosureMenuItem("Freeze Header Row", state: model.headerRowFrozen) { [weak self] in self?.toggleFreezeHeaderRow() }
        freezeHeader.isEnabled = model.data.headerRow
        menu.addItem(freezeHeader)
        menu.addItem(ClosureMenuItem("Freeze First Column", state: model.data.freezeFirstColumn ?? false) { [weak self] in
            self?.toggleFreezeFirstColumn()
        })
        menu.addItem(ClosureMenuItem("Always Show Headings", state: model.data.showHeadings ?? false) { [weak self] in
            self?.toggleShowHeadings()
        })
        menu.addItem(paletteItem("Column Shading") { [weak self] in self?.shadeColumns($0) })
        return menu
    }

    // MARK: Rows (row number bar)

    /// Top edges of the rows, and the table's bottom edge.
    var rowEdges: [CGFloat] { rowTops }

    /// Rows whose every shown cell is selected (for the row number bar).
    var selectedWholeRowSet: Set<Int> {
        guard editing == nil, !selection.isEmpty else { return [] }
        let rows = Set(selection.map(\.row))
        return rows.filter { r in
            (0..<model.columnCount).allSatisfy { c in
                let cell = CellRef(row: r, column: c)
                return !model.isShown(cell) || model.data.isCovered(r, c) || selection.contains(cell)
                    || selection.contains(model.master(cell))
            }
        }
    }

    /// Selects whole rows (from the row number bar).
    func selectRowRange(_ a: Int, _ b: Int) {
        endEditing()
        becameActive()
        let left = model.shownColumns.first ?? 0, right = model.shownColumns.last ?? model.columnCount - 1
        selectRange(CellRef(row: min(a, b), column: left), CellRef(row: max(a, b), column: right))
        anchor = CellRef(row: a, column: left)
        extent = CellRef(row: b, column: right)
        window?.makeFirstResponder(self)
        rowBar?.needsDisplay = true
    }

    private var targetRowList: [Int] {
        let whole = selectedWholeRowSet
        if !whole.isEmpty { return whole.sorted() }
        return selectedRows.isEmpty ? [targetCell.row] : selectedRows
    }

    func hideRows() {
        let rows = targetRowList
        guard model.canHideRows(rows) else { return NSSound.beep() }
        run(rows.count > 1 ? "Hide Rows" : "Hide Row") { model.hideRows(rows) }
        selection = []
    }

    func unhideRows(_ rows: [Int]? = nil) {
        guard model.hasHiddenRows else { return }
        run("Unhide Rows") { model.unhideRows(rows) }
    }

    /// The row number bar's right-click menu.
    func rowMenu(for row: Int) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let rows = targetRowList
        let n = rows.count
        menu.addItem(ClosureMenuItem(insertCount.rows > 1 ? "Insert \(insertCount.rows) Rows Above" : "Insert Row Above") { [weak self] in self?.insertRowAbove() })
        menu.addItem(ClosureMenuItem(insertCount.rows > 1 ? "Insert \(insertCount.rows) Rows Below" : "Insert Row Below") { [weak self] in self?.insertRowBelow() })
        menu.addItem(ClosureMenuItem(n > 1 ? "Delete \(n) Rows" : "Delete Row") { [weak self] in self?.deleteRows() })
        menu.addItem(ClosureMenuItem(n > 1 ? "Clear \(n) Rows" : "Clear Row") { [weak self] in self?.clearCells() })
        menu.addItem(.separator())
        let fit = ClosureMenuItem(n > 1 ? "Auto-Fit \(n) Rows" : "Auto-Fit Row Height") { [weak self] in self?.autoFitRows(rows) }
        fit.isEnabled = rows.contains { model.manualHeight($0) != nil }
        menu.addItem(fit)
        let fitAll = ClosureMenuItem("Auto-Fit All Rows") { [weak self] in
            guard let self else { return }
            self.autoFitRows(Array(0..<self.model.rowCount))
        }
        fitAll.isEnabled = model.data.rowHeightOverrides != nil
        menu.addItem(fitAll)
        menu.addItem(.separator())
        let hide = ClosureMenuItem(n > 1 ? "Hide \(n) Rows" : "Hide Row") { [weak self] in self?.hideRows() }
        hide.isEnabled = model.canHideRows(rows)
        menu.addItem(hide)
        let unhide = ClosureMenuItem("Unhide Rows") { [weak self] in self?.unhideRows() }
        unhide.isEnabled = model.hasHiddenRows
        menu.addItem(unhide)
        menu.addItem(.separator())
        let up = ClosureMenuItem(n > 1 ? "Move Rows Up" : "Move Row Up") { [weak self] in self?.moveRows(up: true) }
        up.isEnabled = canMoveRows(up: true)
        menu.addItem(up)
        let down = ClosureMenuItem(n > 1 ? "Move Rows Down" : "Move Row Down") { [weak self] in self?.moveRows(up: false) }
        down.isEnabled = canMoveRows(up: false)
        menu.addItem(down)
        menu.addItem(.separator())
        menu.addItem(paletteItem("Row Shading") { [weak self] in self?.shadeRows($0) })
        return menu
    }

    // MARK: Column bar

    private(set) var columnBar: TableColumnBar?
    private(set) var rowBar: TableRowBar?
    /// The left edge of the visible part of the page (the row number bar stays inside it).
    var pageVisibleLeft: CGFloat = -.greatestFiniteMagnitude
    /// The top edge of the visible part of the page (the column letter bar stays inside it).
    var pageVisibleTop: CGFloat = -.greatestFiniteMagnitude
    var rowBarShown: Bool { rowBar?.superview != nil }

    /// Keeps the column letter bar on the table's top, or at the top of the view while the table's top is scrolled
    /// out of view (it never goes below the table's last row); the row bar's select-all corner follows it.
    func positionColumnBar() {
        guard let bar = columnBar, bar.superview != nil, let canvas = owner?.canvas else { return }
        let top = canvas.convert(NSPoint.zero, from: self).y
        let height = TableColumnBar.height
        let y = max(top - height, min(pageVisibleTop, top + (rowTops.last ?? 0) - height))
        if bar.frame.minY != y {
            bar.setFrameOrigin(NSPoint(x: bar.frame.minX, y: y))
            bar.needsDisplay = true
        }
        if let rows = rowBar { rows.cornerTop = y - rows.frame.minY }
    }

    /// Keeps the row number bar beside the table, or at the visible left edge while the table's left side is
    /// scrolled out of view (it never goes past the table's right side).
    func positionRowBar() {
        guard let bar = rowBar, bar.superview != nil, let canvas = owner?.canvas else { return }
        let left = canvas.convert(NSPoint.zero, from: self).x
        let width = bar.frame.width
        let x = max(left - width, min(pageVisibleLeft, left + (columnLefts.last ?? 0) - width))
        if bar.frame.minX != x {
            bar.setFrameOrigin(NSPoint(x: x, y: bar.frame.minY))
            bar.needsDisplay = true
        }
    }

    /// Shows the A, B, C… bar above the table while it's being worked in (cells selected or typing).
    func updateColumnBar() {
        let inUse = TableGridView.active === self && (editing != nil || !selection.isEmpty)
        let show = !isExport && window != nil && (inUse || model.data.showHeadings == true)
        let barWasShown = rowBarShown
        defer { if rowBarShown != barWasShown { owner?.refreshSticky() } }
        guard show, let owner, let canvas = owner.canvas else {
            columnBar?.removeFromSuperview()
            rowBar?.removeFromSuperview()
            return
        }
        let bar = columnBar ?? TableColumnBar()
        bar.grid = self
        columnBar = bar
        let origin = canvas.convert(NSPoint(x: 0, y: 0), from: self)
        // Right on the table's top (over the container's grip while it shows).
        bar.frame = NSRect(x: origin.x, y: origin.y - TableColumnBar.height,
                           width: columnLefts.last ?? bounds.width, height: TableColumnBar.height)
        if bar.superview !== canvas || canvas.subviews.last !== bar {
            bar.removeFromSuperview()
            canvas.addSubview(bar)
        }
        bar.needsDisplay = true
        window?.invalidateCursorRects(for: bar)
        // Row numbers down the left side, with the select-all corner beside the column letters.
        let rows = rowBar ?? TableRowBar()
        rows.grid = self
        rowBar = rows
        let width = TableRowBar.width(rows: model.rowCount)
        rows.frame = NSRect(x: origin.x - width, y: origin.y - TableColumnBar.height,
                            width: width, height: TableColumnBar.height + (rowTops.last ?? bounds.height))
        if rows.superview !== canvas || canvas.subviews.last !== rows {
            rows.removeFromSuperview()
            canvas.addSubview(rows)
        }
        rows.needsDisplay = true
        positionRowBar()
        positionColumnBar()
        window?.invalidateCursorRects(for: rows)
    }

    /// A cell's shading, selection tint, text and filter button.
    private func drawCell(_ cell: CellRef, showSelection: Bool) {
        let rect = cellRect(cell)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        rect.clip()
        if let shade = model.data.shade(cell.row, cell.column) {
            shade.nsColor.setFill()
            rect.fill()
        }
        // Conditional formatting: a fill or colour scale, then a data bar under the text.
        let conditional = isExport || editing != cell ? model.conditionalStyle(cell) : nil
        if let fill = conditional?.fill {
            fill.setFill()
            rect.fill()
        }
        if let bar = conditional?.bar {
            let barRect = NSRect(x: rect.minX + 2, y: rect.minY + 3, width: (rect.width - 4) * bar.fraction, height: rect.height - 6)
            NSGradient(starting: bar.color.withAlphaComponent(0.85), ending: bar.color.withAlphaComponent(0.25))?.draw(in: barRect, angle: 0)
        }
        if showSelection && selection.contains(cell) {
            NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
            rect.fill(using: .sourceOver)
        }
        drawTagMarks(cell, in: rect)
        var textRect = rect.insetBy(dx: Self.padX, dy: Self.padY)
        if hasFilterButton(cell) || hasDropdown(cell) { textRect.size.width -= Self.filterButtonSize }
        if editing != cell {
            var text = model.displayText(cell, fitting: textRect.width)
            if let conditional, conditional.textColor != nil || conditional.bold {
                let styled = NSMutableAttributedString(attributedString: text)
                let all = NSRange(location: 0, length: styled.length)
                if let color = conditional.textColor { styled.addAttribute(.foregroundColor, value: color, range: all) }
                if conditional.bold {
                    styled.enumerateAttribute(.font, in: all) { value, range, _ in
                        let font = value as? NSFont ?? Prefs.defaultFont
                        styled.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask), range: range)
                    }
                }
                text = styled
            }
            drawText(text, in: textRect)
            if !isExport { drawMisspellings(text, in: textRect) }
        }
        if hasFilterButton(cell) { drawFilterButton(cell) }
        if hasDropdown(cell) { drawDropdownButton(cell) }
        if circleInvalid, !isExport, !model.isValid(cell) {
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2))
            ring.lineWidth = 1.5
            NSColor.systemRed.setStroke()
            ring.stroke()
        }
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
        if window != nil, model.data.showHeadings == true {
            DispatchQueue.main.async { [weak self] in self?.updateColumnBar(); self?.owner?.refreshSticky() }
        }
        if window == nil {
            columnBar?.removeFromSuperview()
            rowBar?.removeFromSuperview()
            closeFilter()
            conditionalPopover?.close()
            validationPopover?.close()
            pivotPopover?.close()
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
        editingOriginal = model.storedText(cell)
        selection = [cell]
        anchor = cell
        extent = nil
        editorUndo = UndoManager()
        // Pictures wider than the cell are typed around as scaled copies (the saved ones keep their size).
        editor.textStorage?.setAttributedString(CellPictures.fitted(model.editingText(cell),
                                                                    width: cellRect(cell).width - 2 * Self.padX, marking: true))
        editor.typingAttributes = editor.textStorage?.length ?? 0 > 0
            ? editor.textStorage!.attributes(at: 0, effectiveRange: nil) : model.typingAttributes(cell)
        editor.typingAttributes[.mxShownPicture] = nil
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
        let shift = stickyColumnActive && editing.column == frozenColumn ? stickyLeft : 0
        editor.frame = NSRect(x: rect.minX + shift, y: rect.minY, width: rect.width, height: max(rect.height, 14))
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
            let typed = NSAttributedString(attributedString: storage)
            let original = editingOriginal
            model.store(storage, in: cell)
            owner?.controller?.markDirty()
            model.checkpoint("Typing")
            // An entry that breaks the cell's validation rule gets Excel's alert (after typing has ended).
            if typed.string != original?.string, model.validationRule(cell) != nil, !model.isValid(cell) {
                DispatchQueue.main.async { [weak self] in self?.entryBreaksRule(cell, typed: typed, original: original) }
            }
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
        CodeHighlighter.recolor(editor)
        guard let cell = editing, let storage = editor.textStorage else { return }
        model.store(storage, in: cell)
        // Formula results elsewhere may have changed size.
        if model.hasFormulas { heightCache = heightCache.filter { $0.key == cell } }
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
        if let url, WebBrowser.isWeb(url) {
            WebBrowser.open(url)
            return true
        }
        return false
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard let cell = editing else { return false }
        switch commandSelector {
        case #selector(NSResponder.moveToEndOfParagraph(_:)) where model.validationRule(cell)?.kind == .list
                && NSApp.currentEvent?.keyCode == 125:
            showList(cell)
            return true
        case #selector(NSResponder.moveParagraphBackwardAndModifySelection(_:)),
             #selector(NSResponder.moveParagraphForwardAndModifySelection(_:)):
            moveRows(up: commandSelector == #selector(NSResponder.moveParagraphBackwardAndModifySelection(_:)))
            return true
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            stopEditing(commit: true)
            model.tab(from: cell, backward: commandSelector == #selector(NSResponder.insertBacktab(_:)))
            if model.focusRequest == nil { beginEditing(cell) } else { continueAtFocusRequest() }
            return true
        case #selector(NSResponder.insertNewline(_:)) where Formula.isFormula(textView.string):
            // Enter finishes a formula and selects the cell below, as in Excel.
            finishFormula(cell)
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
            let row = model.shownRow(from: up ? block.row - 1 : block.row + block.rows, step: up ? -1 : 1) ?? -1
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
        TextFormatter.insertAfterSpelling(TextFormatter.editMenuItems(for: view, at: charIndex) + [.separator()] + items + [.separator()], into: menu)
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
            scratch.textStorage?.setAttributedString(model.editingText(cell))
            scratch.typingAttributes = model.typingAttributes(cell)
            scratch.setSelectedRange(NSRange(location: 0, length: scratch.textStorage?.length ?? 0))
            body(scratch)
            if let storage = scratch.textStorage { model.store(storage, in: cell) }
            heightCache[cell] = nil
        }
        model.checkpoint("Format")
        owner?.controller?.markDirty()
        relayout()
        reportCellFormatting()
        return true
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        guard !isExport, let owner, let window else { return }
        let p = convert(event.locationInWindow, from: nil)
        if let handle = fillHandleRect, handle.insetBy(dx: -3, dy: -3).contains(p) {
            dragFillHandle(event)
            return
        }
        if let cell = dropdownButton(at: p) {
            becameActive()
            showList(cell)
            return
        }
        if let cell = filterButton(at: p) {
            becameActive()
            showFilter(cell.column)
            return
        }
        if let column = columnBorder(at: p) {
            if event.clickCount == 2 { autoFitColumns(near: column) } else { resizeColumn(column, from: event) }
            return
        }
        if let row = rowBorder(at: p) {
            if event.clickCount == 2 { autoFitRows(near: row) } else { resizeRow(row, from: event) }
            return
        }
        if onOuterEdge(p) {
            endEditing()
            owner.beginMove(with: event)
            return
        }
        if let hit = picture(at: p), hit.edge != nil {
            resizePicture(hit, from: event)
            return
        }
        // A click on a link follows it (⌥-click to type in the cell instead).
        if !event.modifierFlags.contains(.option), !event.modifierFlags.contains(.shift),
           !event.modifierFlags.contains(.command), let url = link(at: p) {
            open(url)
            return
        }
        guard let start = cell(at: p) else { return }
        if event.modifierFlags.intersection([.shift, .command, .option]).isEmpty, let rows = selectedWholeRows,
           selection.contains(start), dragRows(rows, from: event) {
            return
        }
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

    // MARK: Pictures in cells

    /// A picture's side or corner, where a handle resizes it.
    enum PictureEdge: CaseIterable {
        case left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight

        /// -1 on the left, 1 on the right, 0 on neither.
        var x: CGFloat {
            switch self {
            case .left, .topLeft, .bottomLeft: -1
            case .right, .topRight, .bottomRight: 1
            case .top, .bottom: 0
            }
        }
        /// -1 at the top, 1 at the bottom, 0 at neither.
        var y: CGFloat {
            switch self {
            case .top, .topLeft, .topRight: -1
            case .bottom, .bottomLeft, .bottomRight: 1
            case .left, .right: 0
            }
        }

        static func at(x: CGFloat, y: CGFloat) -> PictureEdge? { allCases.first { $0.x == x && $0.y == y } }

        var position: NSCursor.FrameResizePosition {
            switch self {
            case .left: .left
            case .right: .right
            case .top: .top
            case .bottom: .bottom
            case .topLeft: .topLeft
            case .topRight: .topRight
            case .bottomLeft: .bottomLeft
            case .bottomRight: .bottomRight
            }
        }
    }

    /// A picture in a cell: its character in the cell's text, where it's drawn, and the edge under the pointer.
    struct PictureHit: Equatable {
        var cell: CellRef
        var index: Int
        var rect: NSRect
        var edge: PictureEdge?
    }

    /// The picture under the pointer (its frame and handles are drawn), or the one being resized.
    private var hoveredPicture: PictureHit? {
        didSet {
            guard oldValue != hoveredPicture else { return }
            for hit in [oldValue, hoveredPicture].compactMap({ $0 }) { setNeedsDisplay(cellRect(hit.cell).insetBy(dx: -2, dy: -2)) }
        }
    }
    /// The size shown while a picture's edge is dragged.
    private var pictureSizeLabel: String?

    static func cursor(for edge: PictureEdge) -> NSCursor {
        .frameResize(position: edge.position, directions: .all)
    }

    /// Where a cell's text is drawn (left of its filter or list button).
    private func textRect(_ cell: CellRef) -> NSRect {
        var rect = cellRect(cell).insetBy(dx: Self.padX, dy: Self.padY)
        if hasFilterButton(cell) || hasDropdown(cell) { rect.size.width -= Self.filterButtonSize }
        return rect
    }

    /// The width a cell's text has, from the column widths (also mid-drag, before the grid is laid out again).
    private func textWidth(_ cell: CellRef) -> CGFloat {
        blockWidth(cell) - 2 * Self.padX - (hasFilterButton(cell) || hasDropdown(cell) ? Self.filterButtonSize : 0)
    }

    /// Where a cell's pictures are drawn (in this view), with their characters in the cell's text.
    private func pictureFrames(_ cell: CellRef) -> [(index: Int, rect: NSRect)] {
        let area = textRect(cell)
        let text = model.displayText(cell, fitting: area.width)
        let all = NSRange(location: 0, length: text.length)
        guard text.length > 0, text.containsAttachments(in: all) else { return [] }
        let (storage, layout, container) = layout(text, width: area.width)
        var frames: [(index: Int, rect: NSRect)] = []
        withExtendedLifetime(storage) {
            layout.ensureLayout(for: container)
            text.enumerateAttribute(.attachment, in: all) { value, range, _ in
                guard let attachment = value as? NSTextAttachment, CellPictures.isPicture(attachment) else { return }
                for index in range.location..<NSMaxRange(range) {
                    let glyph = layout.glyphIndexForCharacter(at: index)
                    guard glyph < layout.numberOfGlyphs else { continue }
                    let size = layout.attachmentSize(forGlyphAt: glyph)
                    guard size.width > 0, size.height > 0 else { continue }
                    // The picture sits on the line's baseline.
                    let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                    let at = layout.location(forGlyphAt: glyph)
                    frames.append((index, NSRect(x: area.minX + line.minX + at.x, y: area.minY + line.minY + at.y - size.height,
                                                 width: size.width, height: size.height)))
                }
            }
        }
        return frames
    }

    /// The picture under a point, and the side or corner it's on (where it's resized).
    func picture(at p: NSPoint) -> PictureHit? {
        guard !isExport, NotebookStore.shared.editor.tool == .type else { return nil }
        // Not where the pinned header row or the frozen column is drawn over the cells.
        if let band = pinnedHeaderBand, p.y >= band.y, p.y < band.y + band.height { return nil }
        if stickyColumnActive, p.x >= stickyLeft, p.x < stickyLeft + frozenWidth { return nil }
        guard let cell = cell(at: p) else { return nil }
        let clip = cellRect(cell)
        let reach: CGFloat = 4
        for (index, rect) in pictureFrames(cell).reversed() {
            let shown = rect.intersection(clip)
            guard !shown.isEmpty, shown.insetBy(dx: -reach, dy: -reach).contains(p) else { continue }
            // A bottom cut off by a row of fixed height can't be dragged.
            let x: CGFloat = abs(p.x - rect.maxX) <= reach ? 1 : abs(p.x - rect.minX) <= reach ? -1 : 0
            let y: CGFloat = abs(p.y - rect.maxY) <= reach && rect.maxY <= clip.maxY + 0.5 ? 1
                : abs(p.y - rect.minY) <= reach && rect.minY >= clip.minY - 0.5 ? -1 : 0
            let edge = PictureEdge.at(x: x, y: y)
            guard edge != nil || shown.contains(p) else { continue }
            return PictureHit(cell: cell, index: index, rect: rect, edge: edge)
        }
        return nil
    }

    /// The hovered picture's frame, with handles where it can be resized (and its size while it's dragged).
    private func drawPictureFrame() {
        guard let hit = hoveredPicture, !isExport, model.contains(hit.cell) else { return }
        let clip = cellRect(hit.cell)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        clip.clip()
        let accent = NSColor.controlAccentColor
        let frame = NSBezierPath(rect: hit.rect.insetBy(dx: -0.5, dy: -0.5))
        frame.lineWidth = 1
        accent.setStroke()
        frame.stroke()
        let shown = hit.rect.intersection(clip)
        // A handle on each side and corner (none along a bottom cut off by the row).
        let bottomShown = hit.rect.maxY <= clip.maxY + 0.5
        let handles = PictureEdge.allCases.compactMap { edge -> NSPoint? in
            guard edge.y != 1 || bottomShown else { return nil }
            return NSPoint(x: edge.x < 0 ? hit.rect.minX : edge.x > 0 ? hit.rect.maxX : hit.rect.midX,
                           y: edge.y < 0 ? hit.rect.minY : edge.y > 0 ? hit.rect.maxY : shown.midY)
        }
        for center in handles {
            let handle = NSRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7)
            NSColor.white.setFill()
            handle.fill()
            accent.setFill()
            handle.frame(withWidth: 1)
        }
        guard let label = pictureSizeLabel else { return }
        let text = NSAttributedString(string: label, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white])
        let size = text.size()
        var box = NSRect(x: shown.maxX - size.width - 18, y: shown.maxY - size.height - 14,
                         width: size.width + 10, height: size.height + 4)
        box.origin.x = max(shown.minX + 2, box.minX)
        box.origin.y = max(shown.minY + 2, box.minY)
        NSColor(white: 0, alpha: 0.65).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        text.draw(at: NSPoint(x: box.minX + 5, y: box.minY + 2))
    }

    /// Dragging a picture's side or corner resizes it, keeping its proportions (it stays in its place in the
    /// text: a left or top handle grows it as it's dragged out). A picture wider than its cell widens the
    /// column; a row of fixed height grows to show it.
    private func resizePicture(_ hit: PictureHit, from event: NSEvent) {
        guard let window else { return }
        endEditing()
        let cell = model.master(hit.cell)
        let stored = model.storedText(cell)
        guard hit.index < stored.length,
              let saved = stored.attribute(.attachment, at: hit.index, effectiveRange: nil) as? NSTextAttachment else { return }
        let widthBefore = model.width
        model.freezeColumnWidths()
        let block = model.span(cell)
        let column = (block.column..<(block.column + block.columns)).last { !model.isColumnHidden($0) } ?? block.column
        let startColumn = model.data.columnWidths[column]
        let startRoom = textWidth(cell)
        let start = hit.rect.size
        let aspect = CellPictures.aspect(saved)
        let origin = convert(event.locationInWindow, from: nil)
        let rows = fixedRows([cell])
        let startSize = OneNoteImport.displaySize(saved)
        var resized = false
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: NSEvent.foreverDuration,
                           mode: .eventTracking) { ev, stop in
            guard let ev, ev.type == .leftMouseDragged else {
                stop.pointee = true
                return
            }
            let p = self.convert(ev.locationInWindow, from: nil)
            let dx = p.x - origin.x, dy = p.y - origin.y
            guard let edge = hit.edge else { return }
            // Across, down, or (at a corner) whichever way the pointer has moved the picture more.
            let across = start.width + edge.x * dx, down = (start.height + edge.y * dy) / aspect
            var width = edge.y == 0 ? across : edge.x == 0 ? down
                : abs(across - start.width) >= abs(down - start.width) ? across : down
            width = max(16, width).rounded()
            let size = NSSize(width: width, height: max(1, (width * aspect).rounded()))
            CellPictures.resize(saved, to: size)
            resized = true
            // Wider than the cell: the column widens (and narrows back, no narrower than it was, as the picture shrinks).
            let columnWidth = startColumn + Double(max(0, width - startRoom))
            let delta = columnWidth - self.model.data.columnWidths[column]
            if abs(delta) >= 0.5 {
                self.model.data.columnWidths[column] = columnWidth
                self.model.onWidthChange?(CGFloat(delta))
            }
            self.heightCache.removeAll()
            self.growFixedRows(rows)
            self.pictureSizeLabel = "\(Int(size.width)) × \(Int(size.height))"
            self.relayout()
            if let frame = self.pictureFrames(cell).first(where: { $0.index == hit.index }) {
                self.hoveredPicture = PictureHit(cell: cell, index: hit.index, rect: frame.rect, edge: hit.edge)
            }
            self.needsDisplay = true
        }
        pictureSizeLabel = nil
        hoveredPicture = picture(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
        needsDisplay = true
        guard resized, OneNoteImport.displaySize(saved) != startSize else { return }
        model.store(model.storedText(cell), in: cell)
        heightCache[cell] = nil
        relayout()
        model.checkpoint("Resize Picture", widthBefore: widthBefore)
        owner?.controller?.markDirty()
    }

    /// A picture that follows its cell's size while a column or row border is dragged.
    private struct PictureFollower {
        var cell: CellRef
        var picture: NSTextAttachment
        /// Height over width.
        var aspect: CGFloat
        /// The picture's share of the cell's width (column drags) or height (row drags) when the drag began, at most 1.
        var share: CGFloat
        var startSize: NSSize
    }

    /// Pictures on a line of their own in the column's cells: they keep their share of the cell's width.
    private func columnFollowers(_ column: Int) -> [PictureFollower] {
        var found: [PictureFollower] = []
        for cell in model.visibleCells {
            let block = model.span(cell)
            guard column >= block.column, column < block.column + block.columns else { continue }
            let room = textWidth(cell)
            guard room > 10 else { continue }
            for (_, picture) in CellPictures.ownLinePictures(model.storedText(cell)) {
                let size = OneNoteImport.displaySize(picture)
                guard size.width > 0, size.height > 0 else { continue }
                found.append(PictureFollower(cell: cell, picture: picture, aspect: CellPictures.aspect(picture),
                                             share: min(1, size.width / room), startSize: size))
            }
        }
        return found
    }

    /// Cells in the row whose only content is a picture: it keeps its share of the cell's height (as wide as the cell at most).
    private func rowFollowers(_ row: Int) -> [PictureFollower] {
        guard row + 1 < rowTops.count else { return [] }
        let height = rowTops[row + 1] - rowTops[row] - 2 * Self.padY
        guard height > 1 else { return [] }
        var found: [PictureFollower] = []
        for c in 0..<model.columnCount where !model.isColumnHidden(c) && !model.data.isCovered(row, c) {
            let cell = CellRef(row: row, column: c)
            guard model.span(cell).rows == 1, let picture = CellPictures.onlyPicture(model.storedText(cell)) else { continue }
            let size = OneNoteImport.displaySize(picture), room = textWidth(cell)
            guard size.width > 0, size.height > 0, room > 10 else { continue }
            let shown = size.width > room ? size.height * room / size.width : size.height
            found.append(PictureFollower(cell: cell, picture: picture, aspect: CellPictures.aspect(picture),
                                         share: min(1, shown / height), startSize: size))
        }
        return found
    }

    /// Sizes the following pictures for their cells' widths (column drag), or for a row height (row drag).
    private func follow(_ followers: [PictureFollower], height: CGFloat?) {
        for follower in followers {
            let room = textWidth(follower.cell)
            var width = follower.share * room
            if let height { width = min(room, follower.share * (height - 2 * Self.padY) / follower.aspect) }
            width = max(16, width.rounded())
            let size = NSSize(width: width, height: max(1, (width * follower.aspect).rounded()))
            guard OneNoteImport.displaySize(follower.picture) != size else { continue }
            CellPictures.resize(follower.picture, to: size)
            heightCache[follower.cell] = nil
        }
        if height != nil { needsDisplay = true }
    }

    /// Saves the cells whose pictures followed a drag (in the drag's undo step).
    private func storeFollowers(_ followers: [PictureFollower]) {
        var cells: [CellRef] = []
        for follower in followers where OneNoteImport.displaySize(follower.picture) != follower.startSize
            && !cells.contains(follower.cell) { cells.append(follower.cell) }
        guard !cells.isEmpty else { return }
        for cell in cells { model.store(model.storedText(cell), in: cell) }
        heightCache.removeAll()
        relayout()
    }

    /// Rows of fixed height holding these cells, with their heights and the cells (for growFixedRows).
    private func fixedRows(_ cells: [CellRef]) -> [(row: Int, height: CGFloat, cells: [CellRef])] {
        var rows: [Int: [CellRef]] = [:]
        for cell in cells where model.span(cell).rows == 1 && model.manualHeight(cell.row) != nil {
            rows[cell.row, default: []].append(cell)
        }
        return rows.sorted { $0.key < $1.key }.map { ($0.key, model.manualHeight($0.key) ?? 0, $0.value) }
    }

    /// A row of fixed height grows to show its cells' pictures as they get bigger (and goes back, no lower than it was).
    private func growFixedRows(_ rows: [(row: Int, height: CGFloat, cells: [CellRef])]) {
        for (row, height, cells) in rows {
            let tallest = cells.map { measure($0) }.max() ?? 0
            let wanted = max(height, (tallest + 2 * Self.padY).rounded(.up))
            if abs((model.manualHeight(row) ?? 0) - wanted) >= 0.5 { model.setManualHeight(wanted, row: row) }
        }
    }

    /// Drag a column border: that column gets wider or narrower and the table follows.
    // MARK: Auto-fit

    /// The width a cell's text needs on one line (its widest paragraph; pictures at their size).
    private func naturalWidth(_ cell: CellRef) -> CGFloat {
        let text = NSMutableAttributedString(attributedString: model.displayText(cell))
        guard text.length > 0, !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || text.containsAttachments(in: NSRange(location: 0, length: text.length)) else { return 0 }
        // Measured left-aligned and outside any code block (whose shading stretches to fill the cell).
        var extra: CGFloat = 0
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let style = value as? NSParagraphStyle else { return }
            let plain = style.mutableCopy() as! NSMutableParagraphStyle
            if !plain.textBlocks.isEmpty { extra = 24 }
            plain.textBlocks = []
            plain.alignment = .left
            text.addAttribute(.paragraphStyle, value: plain, range: range)
        }
        let rect = text.boundingRect(with: NSSize(width: 10_000, height: CGFloat.greatestFiniteMagnitude),
                                     options: [.usesLineFragmentOrigin, .usesFontLeading])
        return ceil(rect.width) + extra
    }

    /// The width that fits a column's widest shown cell on one line.
    func fittingWidth(_ column: Int) -> CGFloat {
        var widest: CGFloat = 0
        for r in 0..<model.rowCount where !model.isRowHidden(r) && !model.data.isCovered(r, column) {
            let cell = CellRef(row: r, column: column)
            guard model.span(cell).columns == 1 else { continue }
            var width = naturalWidth(cell) + 2 * Self.padX + 2
            if hasFilterButton(cell) { width += Self.filterButtonSize }
            widest = max(widest, width)
        }
        return min(max(widest, 40), 900)
    }

    /// Auto-fit: double-click a column border. Fits the selected whole columns when the column is one of them.
    func autoFitColumns(near column: Int) {
        let whole = selectedWholeColumns
        autoFitColumns(whole.contains(column) ? whole.sorted() : [column])
    }

    func autoFitColumns(_ columns: [Int]) {
        let columns = columns.filter { !model.isColumnHidden($0) }
        guard !columns.isEmpty else { return }
        run(columns.count > 1 ? "Auto-Fit Columns" : "Auto-Fit Column") {
            model.freezeColumnWidths()
            var delta: CGFloat = 0
            for c in columns {
                let width = fittingWidth(c)
                delta += width - CGFloat(model.data.columnWidths[c])
                model.data.columnWidths[c] = Double(width)
            }
            if abs(delta) >= 0.5 { model.onWidthChange?(delta) }
            model.changed()
        }
    }

    // MARK: Row heights

    /// The row whose bottom border is under the point (not the table's bottom edge, which moves the table).
    private func rowBorder(at point: NSPoint) -> Int? {
        guard !isExport, point.x >= 0, point.x <= (columnLefts.last ?? 0) else { return nil }
        for r in 0..<max(0, model.rowCount - 1) where !model.isRowHidden(r) && abs(rowTops[r + 1] - point.y) <= 2 { return r }
        return nil
    }

    /// Double-click a row border: the row fits its content again (the selected whole rows when it's one of them).
    func autoFitRows(near row: Int) {
        let whole = selectedWholeRowSet
        autoFitRows(whole.contains(row) ? whole.sorted() : [row])
    }

    func autoFitRows(_ rows: [Int]) {
        guard rows.contains(where: { model.manualHeight($0) != nil }) else { return }
        run(rows.count > 1 ? "Auto-Fit Rows" : "Auto-Fit Row") {
            for r in rows { model.setManualHeight(nil, row: r) }
            model.changed()
        }
    }

    /// Dragging a row border (in the table or the row number bar) sets the row's height.
    func beginRowResize(_ row: Int, from event: NSEvent) { resizeRow(row, from: event) }

    private func resizeRow(_ row: Int, from event: NSEvent) {
        guard let window else { return }
        endEditing()
        let startY = convert(event.locationInWindow, from: nil).y
        let startHeight = rowTops[row + 1] - rowTops[row]
        let followers = rowFollowers(row)
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: NSEvent.foreverDuration,
                           mode: .eventTracking) { ev, stop in
            guard let ev, ev.type == .leftMouseDragged else {
                stop.pointee = true
                return
            }
            let y = self.convert(ev.locationInWindow, from: nil).y
            let height = max(Self.minManualHeight, startHeight + y - startY).rounded()
            self.follow(followers, height: height)
            self.setRowHeight(height, row: row)
        }
        storeFollowers(followers)
        model.checkpoint("Row Height")
        owner?.controller?.markDirty()
    }

    /// Gives a row a fixed height (as dragging its border does).
    func setRowHeight(_ height: CGFloat, row: Int) {
        guard abs((model.manualHeight(row) ?? -1) - height) >= 0.5 else { return }
        model.setManualHeight(height.rounded(), row: row)
        relayout()
    }

    /// Fits every column without its own undo step (a table just pasted onto the page).
    func fitAllColumns(_ name: String = "Paste") {
        model.freezeColumnWidths()
        var delta: CGFloat = 0
        for c in 0..<model.columnCount where !model.isColumnHidden(c) {
            let width = fittingWidth(c)
            delta += width - CGFloat(model.data.columnWidths[c])
            model.data.columnWidths[c] = Double(width)
        }
        if abs(delta) >= 0.5 { model.onWidthChange?(delta) }
        model.changed()
        model.checkpoint(name)
    }

    /// Dragging a column border (also from the column letter bar).
    func beginColumnResize(_ column: Int, from event: NSEvent) { resizeColumn(column, from: event) }

    private func resizeColumn(_ column: Int, from event: NSEvent) {
        guard let window else { return }
        endEditing()
        let widthBefore = model.width
        model.freezeColumnWidths()
        let startX = convert(event.locationInWindow, from: nil).x
        let startWidth = model.data.columnWidths[column]
        let followers = columnFollowers(column)
        let rows = fixedRows(followers.map(\.cell))
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
            self.follow(followers, height: nil)
            self.heightCache.removeAll()
            self.growFixedRows(rows)
            self.relayout()
        }
        storeFollowers(followers)
        model.checkpoint("Resize Column", widthBefore: widthBefore)
        owner?.controller?.markDirty()
    }

    private func selectRange(_ a: CellRef, _ b: CellRef) {
        let block = model.bounds(of: [a, b])
        var cells: Set<CellRef> = []
        for r in block.row..<(block.row + block.rows) {
            for c in block.column..<(block.column + block.columns) where model.isShown(CellRef(row: r, column: c)) {
                cells.insert(model.master(CellRef(row: r, column: c)))
            }
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
        let menu = tableMenu(for: cell)
        for (i, item) in spellingItems(at: convert(event.locationInWindow, from: nil)).enumerated() { menu.insertItem(item, at: i) }
        menu.addItem(.separator())
        menu.addItem(automationMenuItem())
        return menu
    }

    // MARK: Keys (cells selected, not typing)

    override func keyDown(with event: NSEvent) {
        let anchor = self.anchor ?? selection.first ?? CellRef(row: 0, column: 0)
        switch event.keyCode {
        case 36, 76:
            beginEditing(anchor)
        case 51, 117:
            model.clear(selection)
            model.checkpoint("Clear")
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
        case 2 where event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command:
            fillDown()
        case 15 where event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command:
            fillRight()
        case 125 where event.modifierFlags.contains(.option) && !event.modifierFlags.contains(.shift)
                && model.validationRule(anchor)?.kind == .list:
            showList(anchor)
        case 125, 126 where event.modifierFlags.contains([.option, .shift]):
            moveRows(up: event.keyCode == 126)
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
            if next.row != from.row { next.row = model.shownRow(from: next.row, step: next.row < from.row ? -1 : 1) ?? -1 }
            if next.column != from.column { next.column = model.shownColumn(from: next.column, step: next.column < from.column ? -1 : 1) ?? -1 }
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

    // MARK: Pivot tables

    private var pivotPopover: NSPopover?

    /// Pivot Table…: choose the fields; the pivot table goes below this table.
    func showPivot() {
        guard model.rowCount > 1 else { return NSSound.beep() }
        endEditing()
        becameActive()
        let fields = PivotBuilder.fields(model)
        // Suggest the first column of numbers (after the first) as the values.
        let numeric = (1..<model.columnCount).first { c in
            (1..<model.rowCount).contains { r in
                if case .number = model.value(CellRef(row: r, column: c)) { return true }
                return false
            }
        }
        let popover = NSPopover()
        popover.behavior = .transient
        let view = PivotView(fields: fields, suggestedValue: numeric,
            create: { [weak self] row, column, value, summary, totals in
                self?.createPivot(row: row, column: column, value: value, summary: summary, totals: totals)
            },
            close: { [weak popover] in popover?.performClose(nil) })
        popover.contentViewController = NSHostingController(rootView: view)
        pivotPopover = popover
        let cell = targetCell
        popover.show(relativeTo: cellRect(cell), of: self, preferredEdge: .maxY)
    }

    /// Where a new container goes: below this table, and below anything already under it.
    private func placeBelow(width: CGFloat) -> NSPoint? {
        guard let owner, let controller = owner.controller else { return nil }
        let strip = NSRect(x: owner.frame.minX, y: owner.frame.minY, width: max(width, owner.frame.width), height: .greatestFiniteMagnitude)
        let below = controller.canvas.elementViews.filter { $0 !== owner && $0.frame.minY >= owner.frame.minY && $0.frame.intersects(strip) }
        let top = below.map(\.frame.maxY).max().map { max($0, owner.frame.maxY) } ?? owner.frame.maxY
        return NSPoint(x: owner.frame.minX, y: top + 24)
    }

    // MARK: Charts

    /// Insert Chart: the selected columns (the first gives the categories, columns of numbers the series), or the
    /// whole table; the chart goes below the table.
    func insertChart(_ kind: ChartSpec.Kind) {
        guard let owner, let controller = owner.controller, model.rowCount > 1 else { return NSSound.beep() }
        let names = PivotBuilder.fields(model)
        func numeric(_ c: Int) -> Bool {
            (1..<model.rowCount).contains { r in
                switch model.value(CellRef(row: r, column: c)) {
                case .number, .date: return true
                default: return false
                }
            }
        }
        var columns = selectedColumns.filter { !model.isColumnHidden($0) }
        if columns.count < 2 {
            // One column (or a cell): the table's first column against the chosen column, or every column of numbers.
            let chosen = columns.first.flatMap { $0 > 0 && numeric($0) ? $0 : nil }
            columns = [0] + (chosen.map { [$0] } ?? (1..<model.columnCount).filter { !model.isColumnHidden($0) && numeric($0) })
        }
        let category = columns[0]
        let series = columns.dropFirst().filter(numeric)
        // A scatter chart plots the first column's numbers (or dates) across.
        if kind == .scatter, !numeric(category) {
            NotebookStore.shared.showAlert("Scatter charts need numbers across",
                                           "The first selected column (\(names[category])) has no numbers or dates. Select a column of numbers first, then the values to plot against it.")
            return
        }
        guard !series.isEmpty else {
            NotebookStore.shared.showAlert("No numbers to chart", "Select a column of labels and one or more columns of numbers.")
            return
        }
        var spec = ChartSpec(source: owner.element.id, categoryField: names[category], categoryColumn: category,
                             seriesFields: series.map { names[$0] }, seriesColumns: Array(series), kind: kind,
                             title: series.count == 1 ? names[series[0]] : "")
        // Axis titles from the field names (as a start; Axis Titles… changes them).
        if kind == .scatter {
            spec.xTitle = names[category]
            spec.yTitle = series.count == 1 ? names[series[0]] : nil
        }
        ChartBuilder.refresh(&spec, from: model)
        endEditing()
        let width: CGFloat = kind == .pie || kind == .donut ? 360 : 460
        guard let origin = placeBelow(width: width) else { return }
        var element = PageElement(kind: .chart, x: origin.x, y: origin.y, width: width)
        element.chart = spec
        guard let view = controller.addElement(element) else { return }
        controller.undoManager?.setActionName("Insert Chart")
        controller.canvas.selectedElement = view
    }

    func chartMenu() -> NSMenu {
        let menu = NSMenu()
        for kind in ChartSpec.Kind.allCases {
            let item = ClosureMenuItem(kind.title) { [weak self] in self?.insertChart(kind) }
            item.image = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        return menu
    }

    func createPivot(row: Int, column: Int?, value: Int?, summary: PivotSpec.Summary, totals: Bool) {
        guard let owner, let controller = owner.controller else { return }
        let names = PivotBuilder.fields(model)
        let spec = PivotSpec(source: owner.element.id, rowField: names[row], rowColumn: row,
                             columnField: column.map { names[$0] }, columnColumn: column,
                             valueField: value.map { names[$0] }, valueColumn: value, summary: summary, grandTotals: totals)
        guard let data = PivotBuilder.build(spec, from: model) else { return NSSound.beep() }
        endEditing()
        // Below the source, and below anything already under it (earlier pivot tables).
        let width = CGFloat(data.columnCount) * 110
        let strip = NSRect(x: owner.frame.minX, y: owner.frame.minY, width: max(width, owner.frame.width), height: .greatestFiniteMagnitude)
        let below = controller.canvas.elementViews.filter { $0 !== owner && $0.frame.minY >= owner.frame.minY && $0.frame.intersects(strip) }
        let top = below.map(\.frame.maxY).max().map { max($0, owner.frame.maxY) } ?? owner.frame.maxY
        var element = PageElement(kind: .table, x: owner.frame.minX, y: top + 24, width: width)
        element.table = data
        guard let view = controller.addElement(element) as? TableElementView else { return }
        view.grid.fitAllColumns("Pivot Table")
        controller.undoManager?.setActionName("Pivot Table")
        controller.canvas.selectedElement = view
    }

    /// The source table of this pivot table, when it's on the page.
    private var pivotSource: TableElementView? {
        guard let spec = model.data.pivot else { return nil }
        return owner?.controller?.canvas.elementViews.first { $0.element.id == spec.source } as? TableElementView
    }

    /// Refresh Pivot Table: summarises the source table again (its fields are found by name).
    func refreshPivot() {
        guard let spec = model.data.pivot else { return }
        guard let source = pivotSource, let data = PivotBuilder.build(spec, from: source.model) else {
            NotebookStore.shared.showAlert("Can't refresh the pivot table",
                                           pivotSource == nil ? "Its source table isn't on this page any more."
                                                              : "The source table no longer has the fields “\(spec.rowField)”\(spec.valueField.map { " and “\($0)”" } ?? "").")
            return
        }
        run("Refresh Pivot Table") {
            model.data = data
            model.changed()
        }
        fitAllColumns("Refresh Pivot Table")
    }

    // MARK: Data validation

    /// List cells show a dropdown button while selected or being typed in.
    private func hasDropdown(_ cell: CellRef) -> Bool {
        guard !isExport, !hasFilterButton(cell), editing == cell || (editing == nil && selection == [cell]),
              let rule = model.validationRule(cell), rule.kind == .list, rule.dropdown else { return false }
        return true
    }

    private func dropdownRect(_ cell: CellRef) -> NSRect {
        let rect = cellRect(cell)
        let size = Self.filterButtonSize
        return NSRect(x: rect.maxX - size - 3, y: rect.minY + min(4, max(0, (rect.height - size) / 2)), width: size, height: size)
    }

    private func drawDropdownButton(_ cell: CellRef) {
        let rect = dropdownRect(cell)
        let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        NSColor.white.setFill()
        path.fill()
        NSColor(white: 0.6, alpha: 1).setStroke()
        path.lineWidth = 0.75
        path.stroke()
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: rect.midX - 3.5, y: rect.midY - 1.5))
        arrow.line(to: NSPoint(x: rect.midX + 3.5, y: rect.midY - 1.5))
        arrow.line(to: NSPoint(x: rect.midX, y: rect.midY + 2.5))
        arrow.close()
        NSColor(white: 0.3, alpha: 1).setFill()
        arrow.fill()
    }

    private func dropdownButton(at p: NSPoint) -> CellRef? {
        let cell = editing ?? (selection.count == 1 ? selection.first : nil)
        guard let cell, hasDropdown(cell), dropdownRect(cell).insetBy(dx: -2, dy: -2).contains(unpinned(p)) else { return nil }
        return cell
    }

    /// The list's values as menu items (the cell's value is ticked).
    func listMenu(for cell: CellRef) -> NSMenu {
        let menu = NSMenu()
        guard let rule = model.validationRule(cell) else { return menu }
        let current = model.shownString(cell).trimmingCharacters(in: .whitespacesAndNewlines)
        for value in model.listValues(rule) {
            menu.addItem(ClosureMenuItem(value, state: value.caseInsensitiveCompare(current) == .orderedSame) { [weak self] in
                self?.choose(value, in: cell)
            })
        }
        if menu.items.isEmpty {
            let none = NSMenuItem(title: "No values in the list", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        return menu
    }

    /// The dropdown (click its button, or ⌥↓).
    func showList(_ cell: CellRef) {
        let rect = cellRect(cell)
        listMenu(for: cell).popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.maxY + 2), in: self)
    }

    /// A value picked from the list goes into the cell.
    func choose(_ value: String, in cell: CellRef) {
        run("Choose from List") {
            let stored = model.storedText(cell)
            let attrs = stored.length > 0 ? stored.attributes(at: 0, effectiveRange: nil) : model.typingAttributes(cell)
            model.store(NSAttributedString(string: value, attributes: attrs), in: cell)
        }
        selection = [cell]
        anchor = cell
        window?.makeFirstResponder(self)
    }

    #if DEBUG
    /// Self-tests answer the validation alert (first, second or third button).
    nonisolated(unsafe) static var testAlertAnswer: NSApplication.ModalResponse?
    #endif

    /// Excel's alert for an entry that breaks the rule: Stop (Retry / Cancel), Warning (continue? Yes / No / Cancel),
    /// Information (OK / Cancel). Retry and No go back to typing; Cancel puts the old value back.
    private func entryBreaksRule(_ cell: CellRef, typed: NSAttributedString, original: NSAttributedString?) {
        guard let rule = model.validationRule(cell), !model.isValid(cell) else { return }
        let alert = NSAlert()
        alert.messageText = rule.errorTitle.isEmpty ? "This value doesn't match the data validation rules for this cell." : rule.errorTitle
        alert.informativeText = rule.errorMessage.isEmpty ? "The cell needs \(rule.explanation)." : rule.errorMessage
        switch rule.errorStyle {
        case .stop:
            alert.alertStyle = .critical
            alert.addButton(withTitle: "Retry")
            alert.addButton(withTitle: "Cancel")
        case .warning:
            alert.alertStyle = .warning
            alert.informativeText += "\n\nContinue?"
            alert.addButton(withTitle: "Yes")
            alert.addButton(withTitle: "No")
            alert.addButton(withTitle: "Cancel")
        case .information:
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
        }
        #if DEBUG
        let answer = Self.testAlertAnswer ?? alert.runModal()
        #else
        let answer = alert.runModal()
        #endif
        let keep = rule.errorStyle != .stop && answer == .alertFirstButtonReturn
        guard !keep else { return }
        // Put the old value back.
        run("Cancel Entry") { model.store(original ?? NSAttributedString(), in: cell) }
        let retry = (rule.errorStyle == .stop && answer == .alertFirstButtonReturn)
            || (rule.errorStyle == .warning && answer == .alertSecondButtonReturn)
        if retry {
            // Back to typing, with the entry selected to type over.
            becameActive()
            beginEditing(cell)
            editor.textStorage?.setAttributedString(typed)
            editor.setSelectedRange(NSRange(location: 0, length: typed.length))
            window?.makeFirstResponder(editor)
        } else {
            selection = [cell]
            anchor = cell
            needsDisplay = true
        }
    }

    private var validationPopover: NSPopover?

    /// Data Validation…: the rule for the selected cells.
    func showValidation() {
        let target = conditionalTarget
        let cells = Set(targetCells.isEmpty ? [targetCell] : targetCells)
        endEditing()
        becameActive()
        var rule = ValidationRule(kind: .list, firstRow: target.firstRow, lastRow: target.lastRow,
                                  firstColumn: target.firstColumn, lastColumn: target.lastColumn)
        let existing = cells.compactMap { model.validationRule($0) }.first
        if let existing {
            rule = existing
            rule.id = UUID()
            rule.firstRow = target.firstRow
            rule.lastRow = target.lastRow
            rule.firstColumn = target.firstColumn
            rule.lastColumn = target.lastColumn
        }
        let popover = NSPopover()
        popover.behavior = .transient
        let view = ValidationView(rangeName: target.rangeName(rowCount: model.rowCount), rule: rule, isNew: existing == nil,
            apply: { [weak self] newRule in
                self?.run(newRule == nil ? "Clear Validation" : "Data Validation") { self?.model.setValidation(newRule, replacing: cells) }
            },
            close: { [weak popover] in popover?.performClose(nil) })
        popover.contentViewController = NSHostingController(rootView: view)
        validationPopover = popover
        let anchor = cells.map { cellRect($0) }.reduce(NSRect.null) { $0.union($1) }
        popover.show(relativeTo: anchor.isNull ? bounds : anchor, of: self, preferredEdge: .maxY)
    }

    func clearValidation() {
        let cells = Set(targetCells.isEmpty ? [targetCell] : targetCells)
        run("Clear Validation") { model.setValidation(nil, replacing: cells) }
    }

    func validationMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ClosureMenuItem("Data Validation…") { [weak self] in self?.showValidation() })
        if let cell = targetCells.count == 1 ? targetCells.first : editing, model.validationRule(cell)?.kind == .list {
            let pick = NSMenuItem(title: "Choose from List", action: nil, keyEquivalent: "")
            pick.submenu = listMenu(for: cell)
            menu.addItem(pick)
        }
        let circle = ClosureMenuItem("Circle Invalid Data", state: circleInvalid) { [weak self] in self?.circleInvalid.toggle() }
        circle.isEnabled = model.hasValidation
        menu.addItem(circle)
        let clear = ClosureMenuItem("Clear Validation from Selected Cells") { [weak self] in self?.clearValidation() }
        clear.isEnabled = model.hasValidation
        menu.addItem(clear)
        return menu
    }

    // MARK: Conditional formatting

    private var conditionalPopover: NSPopover?

    /// The block of cells new rules apply to: the selection (whole columns run to the table's end, below a header).
    private var conditionalTarget: ConditionalRule {
        let cells = targetCells.isEmpty ? [targetCell] : Array(targetCells)
        var rows: [Int] = [], columns: [Int] = []
        for cell in cells {
            let span = model.span(cell)
            rows += Array(span.row..<(span.row + span.rows))
            columns += Array(span.column..<(span.column + span.columns))
        }
        let wholeColumns = !selectedWholeColumns.isEmpty && Set(columns).isSubset(of: selectedWholeColumns)
        let header = model.data.headerRow || model.filterOn ? 1 : 0
        return ConditionalRule(kind: .greater, firstRow: wholeColumns ? min(header, model.rowCount - 1) : rows.min()!,
                               lastRow: wholeColumns ? nil : rows.max()!, firstColumn: columns.min()!, lastColumn: columns.max()!)
    }

    /// Conditional Formatting…: a popover to add a rule for the selected cells and manage the table's rules.
    func showConditionalFormatting() {
        let target = conditionalTarget
        endEditing()
        becameActive()
        let popover = NSPopover()
        popover.behavior = .transient
        let view = ConditionalFormatView(
            rangeName: target.rangeName(rowCount: model.rowCount), rules: model.data.conditionalRules ?? [], rowCount: model.rowCount,
            add: { [weak self] kind, v1, v2, style, low, high in
                var rule = target
                rule.kind = kind
                rule.value1 = v1
                rule.value2 = v2
                rule.fill = style?.fill
                rule.textColor = style?.text
                rule.bold = style?.bold ?? false
                rule.low = low
                rule.high = high
                self?.run("Conditional Formatting") { self?.model.addConditionalRule(rule) }
            },
            delete: { [weak self] id in self?.run("Delete Rule") { self?.model.removeConditionalRule(id) } },
            close: { [weak popover] in popover?.performClose(nil) })
        popover.contentViewController = NSHostingController(rootView: view)
        conditionalPopover = popover
        let cells = targetCells.isEmpty ? [targetCell] : targetCells
        let anchor = cells.map { cellRect($0) }.reduce(NSRect.null) { $0.union($1) }
        popover.show(relativeTo: anchor.isNull ? bounds : anchor, of: self, preferredEdge: .maxY)
    }

    func clearConditionalRules(table: Bool) {
        let cells = table ? nil : Set(targetCells.isEmpty ? [targetCell] : targetCells)
        run("Clear Rules") { model.clearConditionalRules(in: cells) }
    }

    func conditionalMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ClosureMenuItem("New Rule…") { [weak self] in self?.showConditionalFormatting() })
        let clearCells = ClosureMenuItem("Clear Rules from Selected Cells") { [weak self] in self?.clearConditionalRules(table: false) }
        clearCells.isEnabled = model.hasConditionalRules
        menu.addItem(clearCells)
        let clearTable = ClosureMenuItem("Clear Rules from Table") { [weak self] in self?.clearConditionalRules(table: true) }
        clearTable.isEnabled = model.hasConditionalRules
        menu.addItem(clearTable)
        return menu
    }

    // MARK: Number formats

    /// The cells number formats apply to: the selection (whole columns included), or the cell being typed in.
    private var formatTargets: Set<CellRef> {
        let cells = targetCells.isEmpty ? [targetCell] : targetCells
        return Set(cells.map { model.master($0) })
    }

    /// The number shown in a cell now, and its decimals (for a General cell switching to a format).
    private func currentDecimals(_ cell: CellRef) -> Int {
        if let format = model.numberFormat(cell) { return format.decimals }
        let shown = model.shownString(cell)
        guard Formula.number(from: shown) != nil, let dot = shown.firstIndex(of: ".") else { return 0 }
        return shown[shown.index(after: dot)...].prefix { $0.isNumber }.count
    }

    func setNumberFormat(_ kind: NumberFormat.Kind?, symbol: String? = nil) {
        let cells = formatTargets
        run("Number Format") {
            guard let kind else { return model.setNumberFormat(nil, cells: cells) }
            for cell in cells {
                let old = model.numberFormat(cell)
                let decimals = kind == .percent ? (old?.kind == .percent ? old!.decimals : 0) : (old?.kind == kind ? old!.decimals : 2)
                model.setNumberFormat(NumberFormat(kind: kind, decimals: decimals, thousands: old?.thousands ?? true,
                                                   symbol: kind == .currency ? (symbol ?? old?.symbol ?? "$") : nil), cells: [cell])
            }
        }
    }

    func setDateFormat(_ pattern: String) {
        let cells = formatTargets
        run("Date Format") {
            model.setNumberFormat(NumberFormat(kind: .date, decimals: 0, thousands: false, pattern: pattern), cells: cells)
        }
    }

    /// Increase / Decrease Decimal (a General cell becomes Number with one more or fewer decimal than it shows).
    func changeDecimals(by delta: Int) {
        let cells = formatTargets
        run(delta > 0 ? "Increase Decimal" : "Decrease Decimal") {
            for cell in cells where model.numberFormat(cell)?.kind != .date {
                var format = model.numberFormat(cell) ?? NumberFormat(kind: .number, decimals: currentDecimals(cell), thousands: false)
                format.decimals = min(10, max(0, currentDecimals(cell) + delta))
                model.setNumberFormat(format, cells: [cell])
            }
        }
    }

    /// Thousands separator on or off (a General cell becomes Number with it).
    func toggleThousands() {
        let cells = formatTargets
        let on = !(cells.allSatisfy { model.numberFormat($0)?.thousands == true && model.numberFormat($0) != nil })
        run("Thousands Separator") {
            for cell in cells {
                var format = model.numberFormat(cell) ?? NumberFormat(kind: .number, decimals: currentDecimals(cell))
                format.thousands = on
                model.setNumberFormat(format, cells: [cell])
            }
        }
    }

    /// The Number Format menu.
    func numberFormatMenu() -> NSMenu {
        let menu = NSMenu()
        let current = formatTargets.first.flatMap { model.numberFormat($0) }
        menu.addItem(ClosureMenuItem("General", state: current == nil) { [weak self] in self?.setNumberFormat(nil) })
        menu.addItem(ClosureMenuItem("Number  1,234.50", state: current?.kind == .number) { [weak self] in self?.setNumberFormat(.number) })
        let currency = NSMenuItem(title: "Currency", action: nil, keyEquivalent: "")
        currency.state = current?.kind == .currency ? .on : .off
        let symbols = NSMenu()
        for symbol in NumberFormat.currencySymbols {
            symbols.addItem(ClosureMenuItem("\(symbol)1,234.50", state: current?.kind == .currency && current?.symbol == symbol) { [weak self] in
                self?.setNumberFormat(.currency, symbol: symbol)
            })
        }
        currency.submenu = symbols
        menu.addItem(currency)
        menu.addItem(ClosureMenuItem("Percent  12%", state: current?.kind == .percent) { [weak self] in self?.setNumberFormat(.percent) })
        let dates = NSMenuItem(title: "Date", action: nil, keyEquivalent: "")
        dates.state = current?.kind == .date ? .on : .off
        let dateMenu = NSMenu()
        let today = Formula.serial(Date())
        for (pattern, name) in NumberFormat.datePatterns {
            dateMenu.addItem(ClosureMenuItem("\(name)  \(Formula.formatDate(today, pattern: pattern))",
                                             state: current?.kind == .date && current?.pattern == pattern) { [weak self] in
                self?.setDateFormat(pattern)
            })
        }
        dates.submenu = dateMenu
        menu.addItem(dates)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Increase Decimal") { [weak self] in self?.changeDecimals(by: 1) })
        menu.addItem(ClosureMenuItem("Decrease Decimal") { [weak self] in self?.changeDecimals(by: -1) })
        menu.addItem(ClosureMenuItem("Thousands Separator", state: current?.thousands == true) { [weak self] in self?.toggleThousands() })
        return menu
    }

    // MARK: Formulas

    /// Enter in a formula: keeps it and selects the cell below (the next shown row).
    private func finishFormula(_ cell: CellRef) {
        endEditing()
        let below = model.shownRow(from: model.span(cell).row + model.span(cell).rows, step: 1)
        let next = below.map { model.master(CellRef(row: $0, column: cell.column)) } ?? cell
        selection = [next]
        anchor = next
        needsDisplay = true
    }

    /// AutoSum (Σ): a SUM of the numbers just above the cell, else just left of it.
    func autoSum() {
        let cell = editing ?? targetCell
        let column = TableData.columnName(cell.column)
        func isNumber(_ r: Int, _ c: Int) -> Bool {
            if case .number = model.value(CellRef(row: r, column: c)) { return true }
            return false
        }
        var formula = "=SUM()"
        var top = cell.row
        while top - 1 >= 0, isNumber(top - 1, cell.column) { top -= 1 }
        if top < cell.row {
            formula = "=SUM(\(column)\(top + 1):\(column)\(cell.row))"
        } else {
            var left = cell.column
            while left - 1 >= 0, isNumber(cell.row, left - 1) { left -= 1 }
            if left < cell.column {
                formula = "=SUM(\(TableData.columnName(left))\(cell.row + 1):\(TableData.columnName(cell.column - 1))\(cell.row + 1))"
            }
        }
        startFormula(formula, in: cell, caretBack: formula == "=SUM()" ? 1 : 0)
    }

    /// Insert Function: in a formula being typed it goes in at the caret, otherwise the cell gets "=NAME()".
    func insertFunction(_ name: String) {
        let call = name + "()"
        let back = ["TODAY", "NOW", "PI"].contains(name) ? 0 : 1
        if editing != nil, Formula.isFormula(editor.string) || editor.string == "=" {
            editor.insertText(call, replacementRange: editor.selectedRange())
            let caret = editor.selectedRange().location - back
            editor.setSelectedRange(NSRange(location: max(0, caret), length: 0))
            return
        }
        startFormula("=" + call, in: editing ?? targetCell, caretBack: back)
    }

    /// Types a formula into a cell (replacing its text), leaving the caret near the end to adjust it; Enter finishes.
    private func startFormula(_ formula: String, in cell: CellRef, caretBack: Int) {
        becameActive()
        beginEditing(cell)
        let storage = editor.textStorage!
        let attrs = storage.length > 0 ? storage.attributes(at: 0, effectiveRange: nil) : model.typingAttributes(cell)
        editor.insertText(NSAttributedString(string: formula, attributes: attrs), replacementRange: NSRange(location: 0, length: storage.length))
        editor.setSelectedRange(NSRange(location: (formula as NSString).length - caretBack, length: 0))
        window?.makeFirstResponder(editor)
    }

    /// The Formulas menu: AutoSum and the common functions.
    func formulasMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("AutoSum (Σ)") { [weak self] in self?.autoSum() })
        menu.addItem(.separator())
        for (name, about) in Formula.menuFunctions {
            menu.addItem(ClosureMenuItem("\(name) — \(about)") { [weak self] in self?.insertFunction(name) })
        }
        return menu
    }

    // MARK: Copy and paste (Excel-compatible)

    /// Copy: the selected block (shown rows and columns) as an HTML table with its formatting, and as
    /// tab-separated text — Excel, Numbers and Word paste it as cells.
    @objc func copy(_ sender: Any?) {
        guard !selection.isEmpty else { return }
        var rows: [Int] = [], columns: [Int] = []
        for cell in selection {
            let span = model.span(cell)
            rows += Array(span.row..<(span.row + span.rows))
            columns += Array(span.column..<(span.column + span.columns))
        }
        TableClipboard.write(model, rows: (rows.min()!...rows.max()!).filter { !model.isRowHidden($0) },
                             columns: (columns.min()!...columns.max()!).filter { !model.isColumnHidden($0) })
    }

    @objc func cut(_ sender: Any?) {
        copy(sender)
        model.clear(selection)
        model.checkpoint("Cut")
        heightCache.removeAll()
        relayout()
    }

    /// Paste as Plain Text with cells selected: tab-separated text only (no formatting or shading).
    func pastePlain() {
        guard let text = NSPasteboard.general.string(forType: .string),
              let start = selection.min(by: { ($0.row, $0.column) < ($1.row, $1.column) }) else { return }
        pasteCells(TableClipboard.parseTabSeparated(text), at: start)
    }

    /// Paste: cells from Excel (with their formatting and shading) or tab-separated text, starting at the selected
    /// cell; the table grows to fit. One copied cell fills every selected cell.
    @objc func paste(_ sender: Any?) {
        guard let table = TableClipboard.read(),
              let start = selection.min(by: { ($0.row, $0.column) < ($1.row, $1.column) }) else { return }
        pasteCells(table, at: start)
    }

    /// Paste while typing in a cell: copied cells go into the table from this cell; one copied cell's text goes in
    /// at the caret. Other text pastes as usual.
    private func pasteWhileTyping() -> Bool {
        guard let cell = editing, TableClipboard.hasCells, let table = TableClipboard.read() else { return false }
        if table.rowCount == 1, table.columnCount == 1, let only = table.cells[CellRef(row: 0, column: 0)] {
            editor.insertText(styled(only.text, for: cell), replacementRange: editor.selectedRange())
            return true
        }
        endEditing()
        selection = [cell]
        pasteCells(table, at: cell)
        return true
    }

    /// Pasted text in the cell's own font when it came without formatting.
    private func styled(_ text: NSAttributedString, for cell: CellRef) -> NSAttributedString {
        guard text.length > 0, text.attribute(.font, at: 0, effectiveRange: nil) == nil else { return text }
        return NSAttributedString(string: text.string, attributes: model.typingAttributes(cell))
    }

    func pasteCells(_ table: PastedTable, at start: CellRef) {
        let single = table.rowCount == 1 && table.columnCount == 1
        let fillSelection = single && selection.count > 1 ? selection : nil
        run("Paste") {
            if let targets = fillSelection, let only = table.cells[CellRef(row: 0, column: 0)] {
                for cell in targets { place(only, at: cell) }
                return
            }
            while model.rowCount < start.row + table.rowCount { model.insertRow(at: model.rowCount) }
            while model.columnCount < start.column + table.columnCount { model.addColumn(at: model.columnCount) }
            for (offset, pasted) in table.cells {
                let target = CellRef(row: start.row + offset.row, column: start.column + offset.column)
                place(pasted, at: target)
                // Merged cells come across merged, where the cells are free.
                if pasted.rows > 1 || pasted.columns > 1 {
                    let span = CellSpan(row: target.row, column: target.column,
                                        rows: min(pasted.rows, model.rowCount - target.row),
                                        columns: min(pasted.columns, model.columnCount - target.column))
                    let overlaps = (model.data.merges ?? []).contains { m in
                        m.row < span.row + span.rows && span.row < m.row + m.rows
                            && m.column < span.column + span.columns && span.column < m.column + m.columns
                    }
                    if !overlaps, span.rows * span.columns > 1 { model.data.merges = (model.data.merges ?? []) + [span] }
                }
            }
            model.changed()
        }
        let end = CellRef(row: min(model.rowCount - 1, start.row + max(table.rowCount, 1) - 1),
                          column: min(model.columnCount - 1, start.column + max(table.columnCount, 1) - 1))
        if fillSelection == nil { selectRange(start, end) }
        anchor = start
        window?.makeFirstResponder(self)
    }

    private func place(_ pasted: PastedTable.Cell, at target: CellRef) {
        guard model.contains(target), model.master(target) == target else { return }
        model.store(styled(pasted.text, for: target), in: target)
        if let shade = pasted.shading {
            model.data.padShading()
            model.data.shading![target.row][target.column] = shade
        }
    }

    @objc override func selectAll(_ sender: Any?) {
        endEditing()
        selectRange(CellRef(row: 0, column: 0), CellRef(row: model.rowCount - 1, column: model.columnCount - 1))
        window?.makeFirstResponder(self)
    }

    // MARK: Commands (right-click menu and the Table ribbon tab)

    private func run(_ name: String = "Table Change", _ body: () -> Void) {
        endEditing()
        let widthBefore = model.width
        body()
        model.checkpoint(name, widthBefore: widthBefore)
        heightCache.removeAll()
        relayout()
    }

    // MARK: Undo

    /// Table changes are undo steps of the page (Edit ▸ Undo, ⌘Z), next to moving and deleting containers.
    func registerUndo(restoring snapshot: TableModel.Snapshot, _ name: String) {
        guard let undo = owner?.controller?.undoManager else { return }
        undo.registerUndo(withTarget: self) { grid in grid.restore(snapshot, name) }
        undo.setActionName(name)
    }

    private func restore(_ snapshot: TableModel.Snapshot, _ name: String) {
        if editing != nil { stopEditing(commit: true) }
        let current = model.snapshot
        let delta = snapshot.width - model.width
        model.restore(snapshot)
        if abs(delta) > 0.5 { model.onWidthChange?(delta) }
        registerUndo(restoring: current, name)
        selection = selection.filter(model.contains)
        heightCache.removeAll()
        relayout()
    }

    // MARK: Moving rows

    /// The selected rows (or the row being typed in) as one run.
    private var targetRows: ClosedRange<Int> {
        let rows = selectedRows.isEmpty ? [targetCell.row] : selectedRows
        return rows.min()!...rows.max()!
    }

    /// How far the rows move to pass the next shown row (hidden rows are stepped over).
    private func moveOffset(up: Bool) -> Int? {
        let rows = targetRows
        if up { return model.shownRow(from: rows.lowerBound - 1, step: -1).map { $0 - rows.lowerBound } }
        return model.shownRow(from: rows.upperBound + 1, step: 1).map { $0 - rows.upperBound }
    }

    func canMoveRows(up: Bool) -> Bool { moveOffset(up: up).map { model.canMoveRows(targetRows, by: $0) } ?? false }

    /// Move Row Up / Down (⌥⇧↑ / ⌥⇧↓): the selected rows, or the row being typed in, keeping the caret.
    func moveRows(up: Bool) {
        guard let offset = moveOffset(up: up) else { return NSSound.beep() }
        moveRows(targetRows, by: offset)
    }

    private func moveRows(_ rows: ClosedRange<Int>, by offset: Int) {
        guard model.canMoveRows(rows, by: offset) else { return NSSound.beep() }
        let typing = editing.map { ($0, editor.selectedRange()) }
        let selected = selection
        run(rows.count > 1 ? "Move Rows" : "Move Row") { model.moveRows(rows, by: offset) }
        if let (cell, caret) = typing {
            beginEditing(CellRef(row: cell.row + offset, column: cell.column))
            if caret.location <= editor.string.utf16.count { editor.setSelectedRange(caret) }
        } else {
            selection = Set(selected.map { CellRef(row: $0.row + offset, column: $0.column) }.filter(model.contains))
            anchor = anchor.map { CellRef(row: $0.row + offset, column: $0.column) }
            extent = extent.map { CellRef(row: $0.row + offset, column: $0.column) }
            needsDisplay = true
        }
    }

    /// Whole rows are selected (every cell of each selected row).
    private var selectedWholeRows: ClosedRange<Int>? {
        guard editing == nil, !selection.isEmpty else { return nil }
        let rows = selectedRows
        let span = (rows.first!...rows.last!).filter { !model.isRowHidden($0) }
        guard span.count == rows.count else { return nil }
        for r in rows {
            for c in 0..<model.columnCount where !model.data.isCovered(r, c) && !model.isColumnHidden(c) {
                if !selection.contains(CellRef(row: r, column: c)) { return nil }
            }
        }
        return rows.first!...rows.last!
    }

    func selectRows() {
        let rows = targetRows
        endEditing()
        selectRange(CellRef(row: rows.lowerBound, column: 0), CellRef(row: rows.upperBound, column: model.columnCount - 1))
        anchor = CellRef(row: rows.lowerBound, column: 0)
        window?.makeFirstResponder(self)
    }

    /// Where dragged rows would go: the row boundary nearest the pointer.
    private func dropBoundary(at y: CGFloat) -> Int {
        var best = 0
        for (i, top) in rowTops.enumerated() where abs(top - y) < abs(rowTops[best] - y) { best = i }
        return best
    }

    /// Dragging selected whole rows moves them; a line shows where they'll go.
    private func dragRows(_ rows: ClosedRange<Int>, from event: NSEvent) -> Bool {
        guard let window else { return false }
        let startY = convert(event.locationInWindow, from: nil).y
        var moved = false
        var boundary: Int?
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: NSEvent.foreverDuration,
                           mode: .eventTracking) { ev, stop in
            guard let ev, ev.type == .leftMouseDragged else {
                stop.pointee = true
                return
            }
            let y = self.convert(ev.locationInWindow, from: nil).y
            if !moved, abs(y - startY) < 4 { return }
            moved = true
            NSCursor.closedHand.set()
            let b = self.dropBoundary(at: y)
            let offset = b <= rows.lowerBound ? b - rows.lowerBound : b - rows.upperBound - 1
            boundary = offset != 0 && self.model.canMoveRows(rows, by: offset) ? b : nil
            self.dropLine = boundary
            self.needsDisplay = true
        }
        dropLine = nil
        needsDisplay = true
        guard moved else { return false }
        if let b = boundary {
            moveRows(rows, by: b <= rows.lowerBound ? b - rows.lowerBound : b - rows.upperBound - 1)
        }
        return true
    }

    private var selectedRows: [Int] { Set(targetCells.map(\.row)).sorted() }
    private var selectedColumns: [Int] { Set(targetCells.map(\.column)).sorted() }

    /// Insert Row Above / Below: as many rows as are selected (as in Excel), next to the selection.
    func insertRowAbove() { insertRows(below: false) }
    func insertRowBelow() { insertRows(below: true) }
    func insertColumnLeft() { insertColumns(right: false) }
    func insertColumnRight() { insertColumns(right: true) }

    /// Shown rows (or columns) of the selection, or the cell being typed in.
    private var insertCount: (rows: Int, columns: Int) {
        let rows = Set(targetCells.flatMap { c in (c.row..<(c.row + model.span(c).rows)).filter { !model.isRowHidden($0) } })
        let columns = Set(targetCells.flatMap { c in (c.column..<(c.column + model.span(c).columns)).filter { !model.isColumnHidden($0) } })
        // Whole columns selected: one row at a time (and whole rows: one column), as in Excel.
        let wholeColumns = !selectedWholeColumns.isEmpty && selectedWholeRowSet.isEmpty
        let wholeRows = !selectedWholeRowSet.isEmpty && selectedWholeColumns.isEmpty
        return (wholeColumns ? 1 : max(1, rows.count), wholeRows ? 1 : max(1, columns.count))
    }

    private func insertRows(below: Bool) {
        let n = insertCount.rows
        let top = selectedRows.first ?? targetCell.row
        let bottom = (selectedRows.last ?? targetCell.row) + model.span(model.master(CellRef(row: selectedRows.last ?? targetCell.row, column: targetCell.column))).rows - 1
        let at = below ? bottom + 1 : top
        run(n > 1 ? "Insert \(n) Rows" : "Insert Row") { for _ in 0..<n { model.insertRow(at: at) } }
        // The new rows are selected.
        selectRange(CellRef(row: at, column: 0), CellRef(row: at + n - 1, column: model.columnCount - 1))
        anchor = CellRef(row: at, column: 0)
    }

    private func insertColumns(right: Bool) {
        let n = insertCount.columns
        let left = selectedColumns.first ?? targetCell.column
        let last = selectedColumns.last ?? targetCell.column
        let at = right ? last + 1 : left
        run(n > 1 ? "Insert \(n) Columns" : "Insert Column") { for _ in 0..<n { model.addColumn(at: at) } }
        selectRange(CellRef(row: 0, column: at), CellRef(row: model.rowCount - 1, column: at + n - 1))
        anchor = CellRef(row: 0, column: at)
    }

    // MARK: Fill

    /// The selected block: its shown rows and columns.
    private var selectionBlock: (rows: [Int], columns: [Int])? {
        let cells = targetCells.isEmpty ? [] : Array(targetCells)
        guard !cells.isEmpty else { return nil }
        var rows: [Int] = [], columns: [Int] = []
        for cell in cells {
            let span = model.span(cell)
            rows += Array(span.row..<(span.row + span.rows))
            columns += Array(span.column..<(span.column + span.columns))
        }
        return ((rows.min()!...rows.max()!).filter { !model.isRowHidden($0) },
                (columns.min()!...columns.max()!).filter { !model.isColumnHidden($0) })
    }

    /// Fill Down (⌘D): the block's top row goes into the rows below it; with one row selected, the row above comes
    /// down into it. Formulas move their relative references along.
    func fillDown() {
        guard let block = selectionBlock, let top = block.rows.first else { return NSSound.beep() }
        var sources = [top], targets = Array(block.rows.dropFirst())
        if targets.isEmpty {
            guard let above = model.shownRow(from: top - 1, step: -1) else { return NSSound.beep() }
            sources = [above]
            targets = [top]
        }
        fill(down: true, sources: sources, targets: targets, lanes: block.columns, series: false, name: "Fill Down")
    }

    /// Fill Right (⌘R): the block's left column goes into the columns right of it (or the column left comes in).
    func fillRight() {
        guard let block = selectionBlock, let left = block.columns.first else { return NSSound.beep() }
        var sources = [left], targets = Array(block.columns.dropFirst())
        if targets.isEmpty {
            guard let before = model.shownColumn(from: left - 1, step: -1) else { return NSSound.beep() }
            sources = [before]
            targets = [left]
        }
        fill(down: false, sources: sources, targets: targets, lanes: block.rows, series: false, name: "Fill Right")
    }

    private func fill(down: Bool, sources: [Int], targets: [Int], lanes: [Int], series: Bool, name: String) {
        let all = sources + targets
        let rows = down ? (all.min()!...all.max()!) : (lanes.min()!...lanes.max()!)
        let columns = down ? (lanes.min()!...lanes.max()!) : (all.min()!...all.max()!)
        guard model.canFill(rows: rows, columns: columns) else {
            NotebookStore.shared.showAlert("Can't fill merged cells", "Unmerge the cells in the block first.")
            return
        }
        run(name) { model.fill(down: down, sources: sources, targets: targets, lanes: lanes, series: series) }
        selectRange(CellRef(row: rows.lowerBound, column: columns.lowerBound), CellRef(row: rows.upperBound, column: columns.upperBound))
    }

    /// The fill handle: a small square at the selection's bottom-right corner.
    private var fillHandleRect: NSRect? {
        guard !isExport, editing == nil, let block = selectionBlock, let r = block.rows.last, let c = block.columns.last else { return nil }
        let rect = cellRect(model.master(CellRef(row: r, column: c)))
        guard rect.width > 0 else { return nil }
        return NSRect(x: rect.maxX - 3.5, y: rect.maxY - 3.5, width: 7, height: 7)
    }

    /// Where a fill handle drag would fill to.
    private var fillPreview: NSRect? {
        didSet { needsDisplay = true }
    }

    private func drawFillHandle() {
        if let preview = fillPreview {
            let path = NSBezierPath(rect: preview.insetBy(dx: 1, dy: 1))
            path.lineWidth = 1.5
            path.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
        guard let handle = fillHandleRect else { return }
        NSColor.white.setFill()
        handle.insetBy(dx: -1, dy: -1).fill()
        NSColor.controlAccentColor.setFill()
        handle.fill()
    }

    /// Dragging the fill handle down or right fills (continuing number series); double-clicking it fills down as
    /// far as the column beside has data, as in Excel.
    private func dragFillHandle(_ event: NSEvent) {
        guard let window, let block = selectionBlock, let bottom = block.rows.last, let right = block.columns.last,
              let top = block.rows.first, let left = block.columns.first else { return }
        if event.clickCount == 2 {
            // Down to the last row of data in the neighbouring column.
            let neighbour = left > 0 ? left - 1 : right + 1
            guard neighbour < model.columnCount else { return NSSound.beep() }
            var end = bottom
            while end + 1 < model.rowCount, !model.shownString(CellRef(row: end + 1, column: neighbour)).trimmingCharacters(in: .whitespaces).isEmpty {
                end += 1
            }
            guard end > bottom else { return }
            fillHandleTargets(down: true, block: block, to: end)
            return
        }
        var target: (down: Bool, to: Int)?
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: NSEvent.foreverDuration,
                           mode: .eventTracking) { ev, stop in
            guard let ev, ev.type == .leftMouseDragged else {
                stop.pointee = true
                return
            }
            let p = self.convert(ev.locationInWindow, from: nil)
            guard let cell = self.cell(at: p) else { return }
            let span = self.model.span(cell)
            let lastRow = span.row + span.rows - 1, lastColumn = span.column + span.columns - 1
            if lastRow > bottom, lastRow - bottom >= lastColumn - right {
                target = (true, lastRow)
                self.fillPreview = self.cellRect(CellRef(row: top, column: left)).union(self.cellRect(CellRef(row: lastRow, column: right)))
            } else if lastColumn > right {
                target = (false, lastColumn)
                self.fillPreview = self.cellRect(CellRef(row: top, column: left)).union(self.cellRect(CellRef(row: bottom, column: lastColumn)))
            } else {
                target = nil
                self.fillPreview = nil
            }
        }
        fillPreview = nil
        if let target { fillHandleTargets(down: target.down, block: block, to: target.to) }
    }

    /// A fill handle drag down or right to a row or column: the selected block is the source.
    func fillHandleTargets(down: Bool, block: (rows: [Int], columns: [Int]), to end: Int) {
        if down {
            let targets = ((block.rows.last! + 1)...end).filter { !model.isRowHidden($0) }
            fill(down: true, sources: block.rows, targets: targets, lanes: block.columns, series: true, name: "Fill")
        } else {
            let targets = ((block.columns.last! + 1)...end).filter { !model.isColumnHidden($0) }
            fill(down: false, sources: block.columns, targets: targets, lanes: block.rows, series: true, name: "Fill")
        }
    }

    /// The Fill menu.
    func fillMenu() -> NSMenu {
        let menu = NSMenu()
        let down = ClosureMenuItem("Fill Down") { [weak self] in self?.fillDown() }
        down.keyEquivalent = "d"
        down.keyEquivalentModifierMask = .command
        menu.addItem(down)
        let right = ClosureMenuItem("Fill Right") { [weak self] in self?.fillRight() }
        right.keyEquivalent = "r"
        right.keyEquivalentModifierMask = .command
        menu.addItem(right)
        return menu
    }

    func deleteRows() {
        let rows = selectedRows.isEmpty ? [targetCell.row] : selectedRows
        run(rows.count > 1 ? "Delete Rows" : "Delete Row") { for r in rows.reversed() where model.rowCount > 1 { model.deleteRow(r) } }
        selection = []
    }

    func deleteColumns() {
        let columns = selectedColumns.isEmpty ? [targetCell.column] : selectedColumns
        run(columns.count > 1 ? "Delete Columns" : "Delete Column") { for c in columns.reversed() where model.columnCount > 1 { model.removeColumn(c) } }
        selection = []
    }

    func deleteTable() {
        guard let owner else { return }
        endEditing()
        owner.controller?.removeElement(owner)
    }

    func shadeCells(_ color: NSColor?) {
        let cells = targetCells.isEmpty ? [targetCell] : targetCells
        run("Shading") { model.setShading(color, cells: cells) }
    }

    func shadeRows(_ color: NSColor?) {
        let rows = selectedRows.isEmpty ? [targetCell.row] : selectedRows
        let cells = Set(rows.flatMap { r in (0..<model.columnCount).map { CellRef(row: r, column: $0) } })
        run("Shading") { model.setShading(color, cells: cells) }
    }

    func shadeColumns(_ color: NSColor?) {
        let columns = selectedColumns.isEmpty ? [targetCell.column] : selectedColumns
        let cells = Set(columns.flatMap { c in (0..<model.rowCount).map { CellRef(row: $0, column: c) } })
        run("Shading") { model.setShading(color, cells: cells) }
    }

    func shadeHeaderRow(_ color: NSColor?) { run("Shading") { model.setShading(color, scope: .headerRow, at: targetCell) } }
    func shadeTable(_ color: NSColor?) { run("Shading") { model.setShading(color, scope: .table, at: targetCell) } }
    func bandRows(_ color: NSColor?) { run("Shading") { model.bandRows(color) } }
    func toggleHeaderRow() { run("Header Row") { model.toggleHeaderRow() } }
    func toggleBorders() { run("Borders") { model.toggleBorders() } }
    /// Headings: keep the row numbers and column letters showing (they stay in view while the page scrolls).
    func toggleShowHeadings() {
        run("Headings") { model.toggleShowHeadings() }
        updateColumnBar()
        owner?.refreshSticky()
    }

    func toggleFreezeHeaderRow() {
        guard model.data.headerRow else { return NSSound.beep() }
        run("Freeze Header Row") { model.toggleFreezeHeaderRow() }
        owner?.controller?.updateStickyHeaders()
    }

    func toggleFreezeFirstColumn() {
        run("Freeze First Column") { model.toggleFreezeFirstColumn() }
        owner?.controller?.updateStickyHeaders()
    }
    func sort(ascending: Bool) { let column = targetCell.column; run("Sort") { model.sort(byColumn: column, ascending: ascending) } }
    func clearCells() { let cells = targetCells; run("Clear") { model.clear(cells) } }

    func mergeCells() {
        let cells = targetCells
        guard cells.count > 1 else { return NSSound.beep() }
        run("Merge Cells") { model.merge(cells) }
        let top = model.master(CellRef(row: model.bounds(of: cells).row, column: model.bounds(of: cells).column))
        selection = [top]
        anchor = top
    }

    func unmergeCell() { let cell = targetCell; run("Unmerge Cells") { model.unmerge(cell) } }
    func splitIntoColumns() { let cell = targetCell; run("Split Cell") { model.splitIntoColumns(cell) } }
    func splitIntoRows() { let cell = targetCell; run("Split Cell") { model.splitIntoRows(cell) } }
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
        for entry in Palette.customItems(title, isValid: { [weak self] in self?.window != nil }, apply: { apply($0) }) {
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("No Color") { apply(nil) })
        item.submenu = menu
        return item
    }

    // MARK: Alignment

    /// The alignment the cells share (left for cells never aligned), or nil when they differ.
    var cellAlignment: NSTextAlignment? {
        let values = Set(targetCells.map { cell -> Int in
            let text = model.editingText(cell)
            let a = text.length > 0 ? (text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.alignment ?? .natural
                                    : model.cellAlign(cell) ?? .left
            return (a == .natural ? NSTextAlignment.left : a).rawValue
        })
        return values.count == 1 ? values.first.flatMap(NSTextAlignment.init(rawValue:)) : nil
    }

    /// Right-click ▸ Alignment: the selected cells' text (all of it) to the left, centre or right — one undo step.
    func alignCells(_ alignment: NSTextAlignment) {
        let cells = targetCells
        guard !cells.isEmpty else { return NSSound.beep() }
        // A cell being typed in is aligned as a whole, like the others.
        if editing != nil {
            endEditing()
            if selection.isEmpty { selection = cells }
        }
        becameActive()
        // Empty cells keep it for what's typed into them; the text of the others is aligned (one undo step).
        model.setCellAlign(alignment, cells)
        TextFormatter.setAlignment(alignment)
        needsDisplay = true
    }

    /// The Alignment submenu: Left, Center, Right (the cells' own alignment ticked).
    func alignmentMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Alignment", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let current = cellAlignment
        for (title, alignment, symbol) in [("Left", NSTextAlignment.left, "text.alignleft"), ("Center", .center, "text.aligncenter"),
                                           ("Right", .right, "text.alignright")] {
            let option = ClosureMenuItem(title, state: current == alignment) { [weak self] in self?.alignCells(alignment) }
            option.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            sub.addItem(option)
        }
        item.submenu = sub
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
        let formulas = NSMenuItem(title: "Formulas", action: nil, keyEquivalent: "")
        formulas.submenu = formulasMenu()
        menu.addItem(formulas)
        menu.addItem(alignmentMenuItem())
        let numbers = NSMenuItem(title: "Number Format", action: nil, keyEquivalent: "")
        numbers.submenu = numberFormatMenu()
        menu.addItem(numbers)
        let conditional = NSMenuItem(title: "Conditional Formatting", action: nil, keyEquivalent: "")
        conditional.submenu = conditionalMenu()
        menu.addItem(conditional)
        let validation = NSMenuItem(title: "Data Validation", action: nil, keyEquivalent: "")
        validation.submenu = validationMenu()
        menu.addItem(validation)
        let fills = NSMenuItem(title: "Fill", action: nil, keyEquivalent: "")
        fills.submenu = fillMenu()
        menu.addItem(fills)
        let charts = NSMenuItem(title: "Insert Chart", action: nil, keyEquivalent: "")
        charts.submenu = chartMenu()
        menu.addItem(charts)
        menu.addItem(ClosureMenuItem("Create Pivot Table…") { [weak self] in self?.showPivot() })
        if model.data.pivot != nil {
            menu.addItem(ClosureMenuItem("Refresh Pivot Table") { [weak self] in self?.refreshPivot() })
        }
        menu.addItem(.separator())
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
        for entry in Palette.customItems("Text Color", isValid: { [weak self] in self?.window != nil },
                                         apply: { TextFormatter.setTextColor($0) }) {
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
        menu.addItem(ClosureMenuItem(insertCount.rows > 1 ? "Insert \(insertCount.rows) Rows Above" : "Insert Row Above") { [weak self] in self?.insertRowAbove() })
        menu.addItem(ClosureMenuItem(insertCount.rows > 1 ? "Insert \(insertCount.rows) Rows Below" : "Insert Row Below") { [weak self] in self?.insertRowBelow() })
        menu.addItem(ClosureMenuItem(insertCount.columns > 1 ? "Insert \(insertCount.columns) Columns Left" : "Insert Column Left") { [weak self] in self?.insertColumnLeft() })
        menu.addItem(ClosureMenuItem(insertCount.columns > 1 ? "Insert \(insertCount.columns) Columns Right" : "Insert Column Right") { [weak self] in self?.insertColumnRight() })
        menu.addItem(.separator())
        let rows = selectedRows.count, columns = selectedColumns.count
        menu.addItem(ClosureMenuItem(rows > 1 ? "Delete \(rows) Rows" : "Delete Row") { [weak self] in self?.deleteRows() })
        menu.addItem(ClosureMenuItem(columns > 1 ? "Delete \(columns) Columns" : "Delete Column") { [weak self] in self?.deleteColumns() })
        menu.addItem(ClosureMenuItem("Auto-Fit Column Width") { [weak self] in
            guard let self else { return }
            self.autoFitColumns(self.targetColumns)
        })
        let hide = ClosureMenuItem(columns > 1 ? "Hide \(columns) Columns" : "Hide Column") { [weak self] in self?.hideColumns() }
        hide.isEnabled = model.canHide(targetColumns)
        menu.addItem(hide)
        if model.hasHiddenColumns {
            menu.addItem(ClosureMenuItem("Unhide Columns") { [weak self] in self?.unhideColumns() })
        }
        menu.addItem(ClosureMenuItem(count > 1 ? "Clear Selected Cells" : "Clear Cell") { [weak self] in self?.clearCells() })
        menu.addItem(ClosureMenuItem("Delete Table") { [weak self] in self?.deleteTable() })
        menu.addItem(.separator())
        let up = ClosureMenuItem(rows > 1 ? "Move Rows Up" : "Move Row Up") { [weak self] in self?.moveRows(up: true) }
        up.isEnabled = canMoveRows(up: true)
        menu.addItem(up)
        let down = ClosureMenuItem(rows > 1 ? "Move Rows Down" : "Move Row Down") { [weak self] in self?.moveRows(up: false) }
        down.isEnabled = canMoveRows(up: false)
        menu.addItem(down)
        menu.addItem(ClosureMenuItem(rows > 1 ? "Select Rows" : "Select Row") { [weak self] in self?.selectRows() })
        if model.data.rowHeightOverrides != nil {
            menu.addItem(ClosureMenuItem("Auto-Fit Row Height") { [weak self] in
                guard let self else { return }
                self.autoFitRows(self.targetRowList)
            })
        }
        let hideRow = ClosureMenuItem(rows > 1 ? "Hide \(rows) Rows" : "Hide Row") { [weak self] in self?.hideRows() }
        hideRow.isEnabled = model.canHideRows(targetRowList)
        menu.addItem(hideRow)
        if model.hasHiddenRows {
            menu.addItem(ClosureMenuItem("Unhide Rows") { [weak self] in self?.unhideRows() })
        }
        menu.addItem(.separator())
        for (title, ascending) in [("Sort Ascending by This Column", true), ("Sort Descending by This Column", false)] {
            let item = ClosureMenuItem(title) { [weak self] in self?.sort(ascending: ascending) }
            item.isEnabled = model.canSort
            menu.addItem(item)
        }
        if !model.data.headerRow && !model.filterOn {
            menu.addItem(ClosureMenuItem("Sort Includes First Row", state: TableModel.sortIncludesFirstRow) {
                UserDefaults.standard.set(!TableModel.sortIncludesFirstRow, forKey: TableModel.sortIncludesFirstRowKey)
            })
        }
        let filterItem = ClosureMenuItem("Filter", state: model.filterOn) { [weak self] in self?.toggleFilter() }
        filterItem.isEnabled = model.filterOn || model.canSort
        menu.addItem(filterItem)
        if model.data.filteredRows != nil || model.data.filters != nil {
            menu.addItem(ClosureMenuItem("Clear All Filters") { [weak self] in self?.clearAllFilters() })
        }
        menu.addItem(ClosureMenuItem("Header Row", state: model.data.headerRow) { [weak self] in self?.toggleHeaderRow() })
        let freezeHeader = ClosureMenuItem("Freeze Header Row", state: model.headerRowFrozen) { [weak self] in self?.toggleFreezeHeaderRow() }
        freezeHeader.isEnabled = model.data.headerRow
        menu.addItem(freezeHeader)
        menu.addItem(ClosureMenuItem("Freeze First Column", state: model.data.freezeFirstColumn ?? false) { [weak self] in
            self?.toggleFreezeFirstColumn()
        })
        menu.addItem(ClosureMenuItem("Always Show Headings", state: model.data.showHeadings ?? false) { [weak self] in
            self?.toggleShowHeadings()
        })
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
        model.onUndoable = { [weak self] before, name in self?.grid.registerUndo(restoring: before, name) }
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

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        if grid.columnBar?.superview != nil { grid.updateColumnBar() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if grid.columnBar?.superview != nil { grid.updateColumnBar() }
    }

    override func removeFromSuperview() {
        grid.columnBar?.removeFromSuperview()
        grid.rowBar?.removeFromSuperview()
        super.removeFromSuperview()
    }

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

    /// Pins the header row while the table's top is above the visible area and some of its body is still in view,
    /// and the frozen first column while the table's left is scrolled out of view.
    func updateStickyHeader(visible: NSRect) {
        lastVisible = visible
        grid.pageVisibleLeft = visible.minX
        grid.pageVisibleTop = visible.minY
        grid.positionRowBar()
        grid.positionColumnBar()
        if grid.frozenColumn != nil {
            // The frozen column sits right of the row number bar when that's showing.
            let barWidth = grid.rowBarShown ? TableRowBar.width(rows: model.rowCount) : 0
            let offset = visible.minX + barWidth - frame.minX
            let room = max(0, (grid.columnEdges.last ?? 0) - grid.frozenWidth)
            grid.stickyLeft = offset > 0 ? min(offset, room) : 0
        } else {
            grid.stickyLeft = 0
        }
        guard model.headerRowFrozen, model.rowCount > 1 else {
            grid.stickyOffset = 0
            return
        }
        // The frozen header row sits below the column letters when they're showing.
        let barHeight = grid.rowBarShown ? TableColumnBar.height : 0
        let offset = visible.minY + barHeight - (frame.minY + Self.gripHeight)
        grid.stickyOffset = offset > 0 ? min(offset, max(0, grid.tableHeight - grid.headerHeight)) : 0
    }

    private var lastVisible: NSRect?

    /// Re-pins the header row, first column and row number bar for the last visible area.
    func refreshSticky() {
        if let lastVisible { updateStickyHeader(visible: lastVisible) }
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
        table.columnWidths = (0..<table.columnCount).map { Double(model.fullColumnWidth($0)) }
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
