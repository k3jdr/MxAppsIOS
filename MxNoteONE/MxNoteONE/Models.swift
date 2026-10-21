//
//  Models.swift
//  MxNoteONE
//
//  The notebook data model. A notebook is a folder (Name.mxnotebook) holding
//  notebook.json (the section tree and recycle bin), one sections/<id>.json
//  per section (its page list and search index), one pages/<id>.json per page
//  (the free-form page content) and an assets/ folder for pictures, file
//  attachments and audio recordings. Password-protected sections keep their
//  section, page and asset files encrypted.
//

import AppKit
import SwiftUI

// MARK: - Colours

/// Colour of a notebook or section tab.
enum NoteColor: String, Codable, CaseIterable, Identifiable {
    case blue, teal, green, yellow, orange, red, pink, purple, indigo, gray

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var nsColor: NSColor {
        switch self {
        case .blue: NSColor(srgbRed: 0.22, green: 0.46, blue: 0.84, alpha: 1)
        case .teal: NSColor(srgbRed: 0.10, green: 0.60, blue: 0.62, alpha: 1)
        case .green: NSColor(srgbRed: 0.30, green: 0.62, blue: 0.27, alpha: 1)
        case .yellow: NSColor(srgbRed: 0.88, green: 0.70, blue: 0.10, alpha: 1)
        case .orange: NSColor(srgbRed: 0.93, green: 0.48, blue: 0.16, alpha: 1)
        case .red: NSColor(srgbRed: 0.84, green: 0.24, blue: 0.24, alpha: 1)
        case .pink: NSColor(srgbRed: 0.86, green: 0.36, blue: 0.62, alpha: 1)
        case .purple: NSColor(srgbRed: 0.47, green: 0.30, blue: 0.70, alpha: 1)
        case .indigo: NSColor(srgbRed: 0.30, green: 0.32, blue: 0.70, alpha: 1)
        case .gray: NSColor(srgbRed: 0.50, green: 0.52, blue: 0.56, alpha: 1)
        }
    }

    var color: Color { Color(nsColor: nsColor) }
}

/// A colour that can be stored in JSON.
struct RGBA: Codable, Hashable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? .black
        r = c.redComponent; g = c.greenComponent; b = c.blueComponent; a = c.alphaComponent
    }

    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }

    static let black = RGBA(r: 0, g: 0, b: 0)
}

/// Background colour of a page.
enum PageColor: String, Codable, CaseIterable, Identifiable {
    case none, cream, yellow, green, blue, purple, pink, orange, gray

    var id: String { rawValue }
    var title: String { self == .none ? "No Color" : rawValue.capitalized }

    var nsColor: NSColor {
        switch self {
        case .none: .white
        case .cream: NSColor(srgbRed: 1.00, green: 0.98, blue: 0.92, alpha: 1)
        case .yellow: NSColor(srgbRed: 1.00, green: 0.97, blue: 0.78, alpha: 1)
        case .green: NSColor(srgbRed: 0.90, green: 0.97, blue: 0.88, alpha: 1)
        case .blue: NSColor(srgbRed: 0.88, green: 0.94, blue: 1.00, alpha: 1)
        case .purple: NSColor(srgbRed: 0.94, green: 0.91, blue: 0.99, alpha: 1)
        case .pink: NSColor(srgbRed: 1.00, green: 0.91, blue: 0.94, alpha: 1)
        case .orange: NSColor(srgbRed: 1.00, green: 0.93, blue: 0.86, alpha: 1)
        case .gray: NSColor(srgbRed: 0.94, green: 0.94, blue: 0.95, alpha: 1)
        }
    }
}

/// Rule lines or grid drawn on a page.
enum RuleLines: String, Codable, CaseIterable, Identifiable {
    case none, narrow, college, wide, smallGrid, mediumGrid, largeGrid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .narrow: "Narrow Ruled"
        case .college: "College Ruled"
        case .wide: "Wide Ruled"
        case .smallGrid: "Small Grid"
        case .mediumGrid: "Medium Grid"
        case .largeGrid: "Large Grid"
        }
    }

    var spacing: CGFloat? {
        switch self {
        case .none: nil
        case .narrow: 18
        case .college: 24
        case .wide: 32
        case .smallGrid: 12
        case .mediumGrid: 24
        case .largeGrid: 40
        }
    }

    var isGrid: Bool { self == .smallGrid || self == .mediumGrid || self == .largeGrid }
}

// MARK: - Tags

/// Note tags, written as a symbol at the start of a paragraph (⌘1 – ⌘9).
enum TagKind: String, Codable, CaseIterable, Identifiable {
    case todo, important, question, critical, idea, remember, definition, contact, discuss

    var id: String { rawValue }

    var title: String {
        switch self {
        case .todo: "To Do"
        case .important: "Important"
        case .question: "Question"
        case .critical: "Critical"
        case .idea: "Idea"
        case .remember: "Remember for Later"
        case .definition: "Definition"
        case .contact: "Phone Number"
        case .discuss: "Discuss with Team"
        }
    }

    /// Symbol written into the text. To Do uses ☐ / ☑.
    var symbol: String {
        switch self {
        case .todo: "☐"
        case .important: "⭐"
        case .question: "❓"
        case .critical: "❗"
        case .idea: "💡"
        case .remember: "📌"
        case .definition: "📖"
        case .contact: "📞"
        case .discuss: "💬"
        }
    }

    static let todoDone = "☑"

    /// Every symbol that marks this tag, with whether it means "done".
    var symbols: [(String, Bool)] {
        self == .todo ? [(symbol, false), (Self.todoDone, true)] : [(symbol, false)]
    }

    /// ⌘ digit shortcut.
    var shortcutDigit: Character {
        Character(String((TagKind.allCases.firstIndex(of: self) ?? 0) + 1))
    }
}

struct TagItem: Codable, Hashable {
    var kind: TagKind
    var text: String
    var done: Bool = false
}

// MARK: - Notebook structure

/// Password protection of a section: PBKDF2 salt and a key verifier.
struct Protection: Codable, Hashable {
    var salt: Data
    var verifier: Data
    var hint: String = ""
}

/// A section or a section group in a notebook's section tree.
struct SectionNode: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case section, group }

    var id = UUID()
    var kind: Kind
    var name: String
    var color: NoteColor = .blue
    /// Members of a section group (nil for sections).
    var children: [SectionNode]?
    var protection: Protection?

    var isGroup: Bool { kind == .group }
    var isProtected: Bool { protection != nil }
}

struct NotebookManifest: Codable {
    var formatVersion = 1
    var id = UUID()
    var name: String
    var color: NoteColor
    var created = Date()
    var sections: [SectionNode] = []
    var trash: [TrashedItem] = []
    /// Set when the notebook is synced with a OneNote notebook on OneDrive.
    var oneNote: OneNoteLink?
}

/// How a notebook maps onto a OneNote notebook on OneDrive.
struct OneNoteLink: Codable {
    var notebookID: String
    var name: String
    var account: String = ""
    var clientURL: String?
    var webURL: String?
    /// Local section / section group ID → OneNote section / section group ID.
    var nodes: [String: String] = [:]
    /// Local page ID → its OneNote page.
    var pages: [String: SyncedPage] = [:]
    var lastSync: Date?
}

struct SyncedPage: Codable {
    var remoteID: String
    var remoteSectionID: String
    /// OneNote's lastModifiedDateTime when last uploaded or downloaded.
    var remoteModified: Date
    /// The local page's modified date at that time.
    var localModified: Date
}

/// A page in a section's page list, with the search index for the page.
struct PageMeta: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String = ""
    /// 0 = page, 1 = subpage, 2 = sub-subpage.
    var level: Int = 0
    var created = Date()
    var modified = Date()
    /// Subpages hidden in the page list.
    var collapsed = false
    var plainText: String = ""
    var tags: [TagItem] = []

    var displayTitle: String { title.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled Page" : title }
}

struct SectionContent: Codable {
    var pages: [PageMeta] = []
}

/// A deleted page or section, kept in the notebook's Recycle Bin for 60 days.
struct TrashedItem: Codable, Identifiable {
    enum Kind: String, Codable { case page, section }

    var id = UUID()
    var kind: Kind
    var deleted = Date()
    var name: String
    /// Deleted page and the section it came from.
    var page: PageMeta?
    var fromSectionID: UUID?
    var fromSectionName: String = ""
    /// The page file is encrypted with its section's key.
    var encrypted = false
    /// Deleted section or section group (its files stay on disk until emptied).
    var section: SectionNode?
}

// MARK: - Page content

struct PageStyle: Codable, Hashable {
    var color: PageColor = .none
    var rules: RuleLines = .none
}

struct TableData: Codable, Hashable {
    var rows: [[String]]
    var columnWidths: [Double]
    var headerRow: Bool = true

    init(rows: Int, columns: Int, width: Double = 480) {
        self.rows = Array(repeating: Array(repeating: "", count: columns), count: rows)
        columnWidths = Array(repeating: width / Double(columns), count: columns)
    }

    var columnCount: Int { rows.first?.count ?? 0 }

    /// Cell shading (background colours), row by row; nil = none.
    var shading: [[RGBA?]]?
    /// Formatted text (RTF) of cells that have formatting, row by row; nil = plain text in `rows`.
    var rich: [[Data?]]?
    /// Each cell's own alignment ("center", "right"; nil = left), row by row — kept when the cell is emptied, and
    /// taken by text typed into it.
    var align: [[String?]]?
    /// Table borders hidden (OneNote: Hide Borders).
    var hideBorders: Bool?
    /// Merged cells: each span is drawn as one cell, its text kept in the top-left cell.
    var merges: [CellSpan]?
    /// Hidden columns (Excel: Hide / Unhide); they keep their text and width.
    var hiddenColumns: [Int]?
    /// Filter buttons on the first row (Excel: Filter).
    var autoFilter: Bool?
    /// Column filters. The rows they hide are worked out when a filter changes (as in Excel), so a row
    /// being typed in doesn't vanish.
    var filters: [ColumnFilter]?
    /// Rows hidden by the filters.
    var filteredRows: [Int]?
    /// Rows hidden with Hide Row (row number bar); they keep their text.
    var hiddenRows: [Int]?
    /// The first column stays in view while the page scrolls sideways (Excel: Freeze First Column).
    var freezeFirstColumn: Bool?
    /// The header row stays in view while the page scrolls (nil = on, as before this option existed).
    var freezeHeaderRow: Bool?
    /// Row numbers and column letters always show (Excel: Headings), not only while the table is in use.
    var showHeadings: Bool?
    /// Rows given a height by dragging their border (row index → points); other rows fit their content.
    var rowHeightOverrides: [Int: Double]?
    /// Number formats of cells ("row,column" → format); other cells show numbers as typed (General).
    var numberFormats: [String: NumberFormat]?
    /// Conditional formatting rules, applied in order.
    var conditionalRules: [ConditionalRule]?
    /// Data validation rules (the last one on a cell applies).
    var validationRules: [ValidationRule]?
    /// A pivot table: how it summarises its source table (Refresh Pivot Table works it out again).
    var pivot: PivotSpec?
    /// The table's name in the notebook (scripts find it by name: mx.table("Inventory")), and its tags.
    var name: String?
    var tags: [String]?
    /// Tags on rows (row index → tags) and on cells ("row,column" → tags), for scripts to find them by.
    var rowTags: [Int: [String]]?
    var cellTags: [String: [String]]?

    /// Background of a cell: its shading, else light gray for the header row, else nil (white).
    func shade(_ row: Int, _ column: Int) -> RGBA? {
        if let shading, shading.indices.contains(row), shading[row].indices.contains(column), let color = shading[row][column] {
            return color
        }
        return headerRow && row == 0 ? RGBA(r: 0.91, g: 0.91, b: 0.91) : nil
    }

    /// Black or white text, whichever reads better on the cell's shading.
    func textIsLight(_ row: Int, _ column: Int) -> Bool {
        guard let c = shade(row, column) else { return false }
        return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b < 0.5
    }

    /// Shading grid sized to the table.
    mutating func padShading() {
        var grid = shading ?? []
        let columns = columnCount
        grid = Array(grid.prefix(rows.count))
        while grid.count < rows.count { grid.append([]) }
        for r in grid.indices {
            grid[r] = Array(grid[r].prefix(columns))
            while grid[r].count < columns { grid[r].append(nil) }
        }
        shading = grid
    }
}

/// How a table cell shows numbers (Excel: Number, Currency, Percent).
struct NumberFormat: Codable, Hashable {
    enum Kind: String, Codable { case number, currency, percent, date }
    var kind: Kind
    var decimals: Int
    var thousands = true
    /// Currency symbol ($, €, £, ¥).
    var symbol: String?
    /// Date pattern (Unicode date format, as in DateFormatter).
    var pattern: String?

    /// Date formats offered (pattern, name).
    static let datePatterns: [(String, String)] = [
        ("M/d/yyyy", "Short Date"), ("EEEE, MMMM d, yyyy", "Long Date"), ("yyyy-MM-dd", "ISO Date"),
        ("d-MMM-yyyy", "Day-Month-Year"), ("MMM d, yyyy", "Month Day, Year"), ("MMMM yyyy", "Month and Year"),
        ("h:mm a", "Time"), ("M/d/yyyy h:mm a", "Date and Time"),
    ]

    static let currencySymbols = ["$", "€", "£", "¥"]

    /// A number as this format shows it (1,234.50 · $1,234.50 · -$5.00 · 12.5%).
    func string(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = thousands
        formatter.groupingSeparator = ","
        formatter.groupingSize = 3
        formatter.decimalSeparator = "."
        formatter.minimumFractionDigits = decimals
        formatter.maximumFractionDigits = decimals
        formatter.roundingMode = .halfUp
        switch kind {
        case .date:
            return Formula.formatDate(value, pattern: pattern ?? "M/d/yyyy")
        case .number:
            return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
        case .currency:
            let digits = formatter.string(from: NSNumber(value: abs(value))) ?? "\(abs(value))"
            let shown = (symbol ?? "$") + digits
            return value < 0 && digits.contains(where: { $0 != "0" && $0 != "." && $0 != "," }) ? "-" + shown : shown
        case .percent:
            return (formatter.string(from: NSNumber(value: value * 100)) ?? "\(value * 100)") + "%"
        }
    }
}

/// A table column filter: values not shown, and optionally text the cell must contain.
struct ColumnFilter: Codable, Hashable {
    var column: Int
    var excluded: [String] = []
    var contains: String?
    /// Filter by Color: show only rows whose cell has this fill ("none" = no fill) or font colour ("auto" = automatic).
    var fillColor: String?
    var fontColor: String?

    var isActive: Bool { !excluded.isEmpty || !(contains ?? "").isEmpty || fillColor != nil || fontColor != nil }
}

/// A block of merged table cells, starting at its top-left cell.
struct CellSpan: Codable, Hashable {
    var row: Int
    var column: Int
    var rows: Int
    var columns: Int

    func contains(_ r: Int, _ c: Int) -> Bool {
        r >= row && r < row + rows && c >= column && c < column + columns
    }
}

/// A container placed anywhere on the page.
struct PageElement: Codable, Identifiable {
    enum Kind: String, Codable { case text, image, file, audio, table, chart, score, diagram, model, map, dbml }

    var id = UUID()
    var kind: Kind
    var x: Double
    var y: Double
    var width: Double
    var height: Double = 0
    /// Rich text (RTFD) of a text container.
    var rtfd: Data?
    /// File name in the notebook's assets folder (image, file, audio).
    var asset: String?
    /// Original name of an attached file or recording.
    var fileName: String?
    var table: TableData?
    /// A chart of a table's data.
    var chart: ChartSpec?
    /// A music score.
    var score: ScoreData?
    /// A draw.io diagram: `asset` is its .drawio.svg; `preview` a PNG of it; `linkedPath` an outside .drawio.svg
    /// file it's kept in step with; `diagramText` its labels (for search).
    var preview: String?
    var linkedPath: String?
    var diagramText: String?
    /// A 3D model: its parameters and features (built by the CAD kernel when shown).
    var cad: CADModel?
    /// A map: where it looks, its style, and its pins (`preview` a picture of it, for printing and exports).
    var map: MapData?
    /// A DBML database diagram: its DBML, where its tables were dragged, its lines' curves and its notes.
    var dbml: DBMLData?

    var frame: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// Ink: pen and highlighter strokes and shapes.
struct InkStroke: Codable, Identifiable, Hashable {
    enum Tool: String, Codable { case pen, highlighter, line, arrow, rectangle, ellipse }

    var id = UUID()
    var tool: Tool
    var color: RGBA
    var width: Double
    var points: [CGPoint]
}

struct PageContent: Codable {
    var id: UUID
    var title: String
    var created: Date
    var style = PageStyle()
    var elements: [PageElement] = []
    var strokes: [InkStroke] = []
}

// MARK: - References

struct SectionRef: Hashable, Codable, Sendable {
    var notebookID: UUID
    var sectionID: UUID
}

struct PageRef: Hashable, Codable, Sendable {
    var notebookID: UUID
    var sectionID: UUID
    var pageID: UUID

    var section: SectionRef { SectionRef(notebookID: notebookID, sectionID: sectionID) }
}

enum SidebarItem: Hashable {
    case section(SectionRef)
    case group(SectionRef)
}

// MARK: - Section tree helpers

extension Array where Element == SectionNode {
    func find(_ id: UUID) -> SectionNode? {
        for node in self {
            if node.id == id { return node }
            if let found = node.children?.find(id) { return found }
        }
        return nil
    }

    @discardableResult
    mutating func modify(_ id: UUID, _ body: (inout SectionNode) -> Void) -> Bool {
        for i in indices {
            if self[i].id == id { body(&self[i]); return true }
            if self[i].children != nil, self[i].children!.modify(id, body) { return true }
        }
        return false
    }

    mutating func removeNode(_ id: UUID) -> SectionNode? {
        if let i = firstIndex(where: { $0.id == id }) { return remove(at: i) }
        for i in indices where self[i].children != nil {
            if let removed = self[i].children!.removeNode(id) { return removed }
        }
        return nil
    }

    /// Sections (not groups), in display order.
    var flattenedSections: [SectionNode] {
        flatMap { $0.isGroup ? ($0.children ?? []).flattenedSections : [$0] }
    }

    /// Section groups, in display order.
    var flattenedGroups: [SectionNode] {
        flatMap { $0.isGroup ? [$0] + ($0.children ?? []).flattenedGroups : [] }
    }

    /// Sections and groups as the sidebar shows them: depth-first, skipping the insides of closed groups.
    func visibleRows(expanded: Set<UUID>, depth: Int = 0) -> [(node: SectionNode, depth: Int)] {
        flatMap { node -> [(node: SectionNode, depth: Int)] in
            guard let children = node.children, expanded.contains(node.id) else { return [(node, depth)] }
            return [(node, depth)] + children.visibleRows(expanded: expanded, depth: depth + 1)
        }
    }

    @discardableResult
    mutating func moveSibling(_ id: UUID, by delta: Int) -> Bool {
        if let i = firstIndex(where: { $0.id == id }) {
            let j = i + delta
            if indices.contains(j) { swapAt(i, j) }
            return true
        }
        for i in indices where self[i].children != nil {
            if self[i].children!.moveSibling(id, by: delta) { return true }
        }
        return false
    }

    /// Puts a node just before or after another (in whatever group that one is in); false if it isn't here.
    @discardableResult
    mutating func insert(_ node: SectionNode, beside target: UUID, after: Bool) -> Bool {
        if let i = firstIndex(where: { $0.id == target }) {
            insert(node, at: after ? i + 1 : i)
            return true
        }
        for i in indices where self[i].children != nil {
            if self[i].children!.insert(node, beside: target, after: after) { return true }
        }
        return false
    }

    mutating func append(_ node: SectionNode, toGroup groupID: UUID?) {
        if let groupID, modify(groupID, { $0.children = ($0.children ?? []) + [node] }) { return }
        append(node)
    }

    /// Names of the groups leading to a node.
    func path(to id: UUID) -> [String]? {
        for node in self {
            if node.id == id { return [] }
            if let sub = node.children?.path(to: id) { return [node.name] + sub }
        }
        return nil
    }

    /// The group whose children contain the node (nil at top level).
    func parentGroup(of id: UUID) -> SectionNode? {
        for node in self where node.isGroup {
            if node.children?.contains(where: { $0.id == id }) == true { return node }
            if let found = node.children?.parentGroup(of: id) { return found }
        }
        return nil
    }
}
