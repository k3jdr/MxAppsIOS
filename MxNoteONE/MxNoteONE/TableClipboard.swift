//
//  TableClipboard.swift
//  MxNoteONE
//
//  Copying and pasting table cells the way Excel does: copied cells go on
//  the clipboard as an HTML table (fonts, bold / italic / underline,
//  colours, shading, alignment, merged cells, column widths), which Excel,
//  Numbers and Word read, plus tab-separated text. Pasting reads Excel's
//  HTML (or tab-separated text) back into cells with their formatting.
//

import AppKit

/// Cells read from the clipboard.
struct PastedTable {
    struct Cell {
        var text: NSAttributedString
        var shading: RGBA?
        var rows = 1
        var columns = 1
    }

    /// Cells by position; covered parts of merged cells are absent.
    var cells: [CellRef: Cell] = [:]
    var rowCount = 0
    var columnCount = 0
}

enum TableClipboard {
    // MARK: Copy

    /// Puts cells on the clipboard (rows and columns in order; hidden ones are left out, as Excel does with filters).
    static func write(_ model: TableModel, rows: [Int], columns: [Int]) {
        guard !rows.isEmpty, !columns.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.html, .string], owner: nil)
        pasteboard.setString(html(model, rows: rows, columns: columns), forType: .html)
        pasteboard.setString(tabSeparated(model, rows: rows, columns: columns), forType: .string)
    }

    /// Tab-separated text; cells with tabs, line breaks or quotes are quoted (as Excel writes them).
    static func tabSeparated(_ model: TableModel, rows: [Int], columns: [Int]) -> String {
        rows.map { r in
            columns.map { c -> String in
                let cell = CellRef(row: r, column: c)
                guard model.master(cell) == cell else { return "" }
                let text = model.shownString(cell)
                guard text.contains(where: { $0 == "\t" || $0 == "\n" || $0 == "\"" }) else { return text }
                return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }.joined(separator: "\t")
        }.joined(separator: "\n")
    }

    static func html(_ model: TableModel, rows: [Int], columns: [Int]) -> String {
        let rowSet = Set(rows), columnSet = Set(columns)
        var out = """
        <html xmlns:o="urn:schemas-microsoft-com:office:office" xmlns:x="urn:schemas-microsoft-com:office:excel">
        <head><meta charset="utf-8"><meta name="Generator" content="MxNoteONE">
        <style>td { border: .5pt solid #A3A3A3; vertical-align: top; mso-number-format: General; }</style>
        </head><body><table border="1" cellspacing="0" cellpadding="4" style="border-collapse: collapse">

        """
        for c in columns { out += "<col width=\"\(Int(model.fullColumnWidth(c).rounded()))\">" }
        out += "\n"
        for r in rows {
            out += "<tr>"
            for c in columns {
                let cell = CellRef(row: r, column: c)
                // A merged cell is written once, from its first shown position.
                let master = model.master(cell)
                let span = model.span(master)
                let firstRow = (span.row..<(span.row + span.rows)).first { rowSet.contains($0) }
                let firstColumn = (span.column..<(span.column + span.columns)).first { columnSet.contains($0) }
                guard firstRow == r, firstColumn == c else { continue }
                let rowSpan = (span.row..<(span.row + span.rows)).filter { rowSet.contains($0) }.count
                let colSpan = (span.column..<(span.column + span.columns)).filter { columnSet.contains($0) }.count
                var attrs = ""
                if rowSpan > 1 { attrs += " rowspan=\"\(rowSpan)\"" }
                if colSpan > 1 { attrs += " colspan=\"\(colSpan)\"" }
                let text = model.shownText(master)
                var style = ""
                if let shade = model.data.shade(master.row, master.column) { style += "background:\(hex(shade.nsColor));" }
                if text.length > 0, let paragraph = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle {
                    switch paragraph.alignment {
                    case .center: style += "text-align:center;"
                    case .right: style += "text-align:right;"
                    default: break
                    }
                }
                // Text that looks like a number but must stay as typed (leading zeros) is marked as text.
                let plain = text.string.trimmingCharacters(in: .whitespacesAndNewlines)
                if plain.count > 1, plain.hasPrefix("0"), !plain.hasPrefix("0."), plain.allSatisfy(\.isNumber) {
                    style += "mso-number-format:\"\\@\";"
                }
                if !style.isEmpty { attrs += " style='\(style)'" }
                out += "<td\(attrs)>\(runs(text, header: model.isHeader(master.row)))</td>"
            }
            out += "</tr>\n"
        }
        out += "</table></body></html>"
        return out
    }

    /// A cell's text as HTML spans, one per formatting run.
    private static func runs(_ text: NSAttributedString, header: Bool) -> String {
        guard text.length > 0 else { return "" }
        var out = ""
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attrs, range, _ in
            let piece = (text.string as NSString).substring(with: range)
            var style = ""
            let font = attrs[.font] as? NSFont ?? Prefs.defaultFont
            style += "font-family:'\(font.familyName ?? font.fontName)';font-size:\(formatted(font.pointSize))pt;"
            let traits = font.fontDescriptor.symbolicTraits
            if traits.contains(.bold) || header { style += "font-weight:700;" }
            if traits.contains(.italic) { style += "font-style:italic;" }
            var decorations: [String] = []
            if (attrs[.underlineStyle] as? Int ?? 0) != 0 { decorations.append("underline") }
            if (attrs[.strikethroughStyle] as? Int ?? 0) != 0 { decorations.append("line-through") }
            if !decorations.isEmpty { style += "text-decoration:\(decorations.joined(separator: " "));" }
            if let color = attrs[.foregroundColor] as? NSColor, !TableModel.isBlack(color) { style += "color:\(hex(color));" }
            if let highlight = attrs[.backgroundColor] as? NSColor { style += "background:\(hex(highlight));" }
            // Excel keeps a line break inside its cell only with this style.
            let escaped = escape(piece).replacingOccurrences(of: "\n", with: "<br style='mso-data-placement:same-cell;'>")
            if let link = attrs[.link] {
                let url = (link as? URL)?.absoluteString ?? "\(link)"
                out += "<a href=\"\(escape(url))\" style=\"\(style)\">\(escaped)</a>"
            } else {
                out += "<span style=\"\(style)\">\(escaped)</span>"
            }
        }
        return out
    }

    private static func formatted(_ size: CGFloat) -> String {
        size == size.rounded() ? "\(Int(size))" : String(format: "%.1f", size)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func hex(_ color: NSColor) -> String {
        guard let c = color.usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }

    // MARK: Paste

    /// Whether the clipboard holds cells (an HTML table, or text with tabs or several lines).
    static var hasCells: Bool {
        let pasteboard = NSPasteboard.general
        if let html = pasteboard.string(forType: .html), html.range(of: "<table", options: .caseInsensitive) != nil { return true }
        guard let text = pasteboard.string(forType: .string) else { return false }
        return text.contains("\t")
    }

    /// Cells from the clipboard: Excel's (or any) HTML table with its formatting, else tab-separated text.
    static func read() -> PastedTable? {
        let pasteboard = NSPasteboard.general
        if let html = pasteboard.string(forType: .html), html.range(of: "<table", options: .caseInsensitive) != nil,
           let table = parseHTML(html), !table.cells.isEmpty {
            return table
        }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return nil }
        return parseTabSeparated(text)
    }

    /// Cells to paste onto the page as a new table: an HTML table that is most of what was copied (as Excel,
    /// Numbers and MxNoteONE tables put on the clipboard — a web page with a table inside its text stays text), or
    /// tab-separated text whose lines all have the same number of cells.
    static func readForPage() -> PastedTable? {
        let pasteboard = NSPasteboard.general
        if let html = pasteboard.string(forType: .html), html.range(of: "<table", options: .caseInsensitive) != nil,
           let table = parseHTML(html), table.rowCount * table.columnCount > 1 {
            let tableText = table.cells.values.reduce(0) { $0 + $1.text.string.filter { !$0.isWhitespace }.count }
            let allText = (pasteboard.string(forType: .string) ?? "").filter { !$0.isWhitespace }.count
            if allText == 0 || Double(tableText) >= 0.9 * Double(allText) { return table }
            return nil
        }
        guard let text = pasteboard.string(forType: .string), text.contains("\t") else { return nil }
        let table = parseTabSeparated(text)
        let counts = Set((0..<table.rowCount).map { r in (0..<table.columnCount).filter { table.cells[CellRef(row: r, column: $0)] != nil }.count })
        return counts.count == 1 && table.columnCount > 1 ? table : nil
    }

    /// A new table's data from pasted cells (formatting, fill and merges kept).
    static func tableData(_ pasted: PastedTable) -> TableData {
        var data = TableData(rows: max(pasted.rowCount, 1), columns: max(pasted.columnCount, 1), width: Double(pasted.columnCount) * 120)
        data.headerRow = false
        let model = TableModel(data: data, width: CGFloat(pasted.columnCount) * 120)
        for (cell, item) in pasted.cells where model.contains(cell) {
            var text = item.text
            if text.length > 0, text.attribute(.font, at: 0, effectiveRange: nil) == nil {
                text = NSAttributedString(string: text.string, attributes: model.typingAttributes(cell))
            }
            model.store(text, in: cell)
            if let shade = item.shading {
                model.data.padShading()
                model.data.shading![cell.row][cell.column] = shade
            }
            if item.rows > 1 || item.columns > 1 {
                let span = CellSpan(row: cell.row, column: cell.column, rows: min(item.rows, model.rowCount - cell.row),
                                    columns: min(item.columns, model.columnCount - cell.column))
                model.data.merges = (model.data.merges ?? []) + [span]
            }
        }
        return model.data
    }

    static func parseTabSeparated(_ text: String) -> PastedTable {
        var table = PastedTable()
        var rows: [[String]] = [[]]
        var field = ""
        var quoted = false
        var chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        if chars.last == "\n" { chars.removeLast() }
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if quoted {
                if ch == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 1 } else { quoted = false }
                } else {
                    field.append(ch)
                }
            } else if ch == "\"" && field.isEmpty {
                quoted = true
            } else if ch == "\t" {
                rows[rows.count - 1].append(field)
                field = ""
            } else if ch == "\n" {
                rows[rows.count - 1].append(field)
                field = ""
                rows.append([])
            } else {
                field.append(ch)
            }
            i += 1
        }
        rows[rows.count - 1].append(field)
        for (r, row) in rows.enumerated() {
            for (c, value) in row.enumerated() {
                table.cells[CellRef(row: r, column: c)] = .init(text: NSAttributedString(string: value))
            }
        }
        table.rowCount = rows.count
        table.columnCount = rows.map(\.count).max() ?? 0
        return table
    }

    /// Reads an HTML table: AppKit's HTML import turns it into text-table cells, which carry each cell's position,
    /// spans and shading.
    static func parseHTML(_ html: String) -> PastedTable? {
        guard let data = html.data(using: .utf8),
              let text = NSAttributedString(html: data, options: [.characterEncoding: String.Encoding.utf8.rawValue],
                                            documentAttributes: nil) else { return nil }
        var table = PastedTable()
        var outer: NSTextTable?
        var current: (cell: CellRef, block: NSTextTableBlock)?
        var buffer = NSMutableAttributedString()
        func flush() {
            guard let current else { return }
            while buffer.string.hasSuffix("\n") { buffer.deleteCharacters(in: NSRange(location: buffer.length - 1, length: 1)) }
            var shading: RGBA?
            if let color = current.block.backgroundColor?.usingColorSpace(.sRGB), color.alphaComponent > 0.01,
               !(color.redComponent > 0.99 && color.greenComponent > 0.99 && color.blueComponent > 0.99) {
                shading = RGBA(color)
            }
            table.cells[current.cell] = .init(text: buffer, shading: shading,
                                              rows: current.block.rowSpan, columns: current.block.columnSpan)
            table.rowCount = max(table.rowCount, current.cell.row + current.block.rowSpan)
            table.columnCount = max(table.columnCount, current.cell.column + current.block.columnSpan)
        }
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            // The outermost table only; anything outside it is left out.
            guard let style = value as? NSParagraphStyle,
                  let block = style.textBlocks.first(where: { ($0 as? NSTextTableBlock)?.table === (outer ?? ($0 as? NSTextTableBlock)?.table) })
                    as? NSTextTableBlock else { return }
            if outer == nil { outer = block.table }
            let cell = CellRef(row: block.startingRow, column: block.startingColumn)
            if current?.cell != cell {
                flush()
                current = (cell, block)
                buffer = NSMutableAttributedString()
            }
            buffer.append(cellText(text.attributedSubstring(from: range)))
        }
        flush()
        return table
    }

    /// Cell text without the table's paragraph blocks (only the alignment is kept).
    private static func cellText(_ text: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        result.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: result.length)) { value, range, _ in
            let paragraph = NSMutableParagraphStyle()
            if let style = value as? NSParagraphStyle { paragraph.alignment = style.alignment }
            result.addAttribute(.paragraphStyle, value: paragraph, range: range)
        }
        // HTML import gives CSS sizes in pixels (12pt → 16), and text without a font as Times 12.
        result.enumerateAttribute(.font, in: NSRange(location: 0, length: result.length)) { value, range, _ in
            guard let font = value as? NSFont else { return }
            let fm = NSFontManager.shared
            // Times is also what the import falls back to for fonts it can't see (such as the Office fonts this app
            // loads for itself), so it becomes the default font, keeping bold and italic.
            var converted = font
            if font.familyName == "Times" {
                converted = Prefs.defaultFont
                if font.fontDescriptor.symbolicTraits.contains(.bold) { converted = fm.convert(converted, toHaveTrait: .boldFontMask) }
                if font.fontDescriptor.symbolicTraits.contains(.italic) { converted = fm.convert(converted, toHaveTrait: .italicFontMask) }
            }
            let size = abs(font.pointSize - 12) < 0.01 && font.familyName == "Times"
                ? Prefs.defaultFont.pointSize : max(6, (font.pointSize * 0.75 * 2).rounded() / 2)
            result.addAttribute(.font, value: fm.convert(converted, toSize: size), range: range)
        }
        // HTML import marks plain text black on white; white highlights would hide shading.
        result.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: result.length)) { value, range, _ in
            if let c = (value as? NSColor)?.usingColorSpace(.sRGB), c.redComponent > 0.99, c.greenComponent > 0.99, c.blueComponent > 0.99 {
                result.removeAttribute(.backgroundColor, range: range)
            }
        }
        return result
    }
}
