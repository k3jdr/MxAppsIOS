//
//  TableColumns.swift
//  MxNoteONE
//
//  Excel-style columns for tables: a column header bar (A, B, C…) above the
//  table while you work in it — click a letter to select the column, ⇧-click
//  or drag to select several, right-click for column commands — hiding and
//  showing columns, and filters: buttons on the first row with sorting, a
//  search box and a checklist of the column's values.
//

import AppKit
import SwiftUI

// MARK: - Data

extension TableData {
    /// Keeps hidden columns and filters on their columns when a column is inserted (+1) or removed (-1).
    mutating func shiftColumns(at index: Int, by delta: Int) {
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

    /// Keeps filtered rows hidden when a row is inserted (+1) or removed (-1).
    mutating func shiftRows(at index: Int, by delta: Int) {
        guard var rows = filteredRows else { return }
        if delta < 0 { rows.removeAll { $0 == index } }
        rows = rows.map { $0 >= index + (delta < 0 ? 1 : 0) ? $0 + delta : $0 }
        filteredRows = rows.isEmpty ? nil : rows
    }

    /// Keeps filtered rows hidden when rows are put in a new order (new index of each old row).
    mutating func remapRows(_ newIndex: [Int]) {
        guard let rows = filteredRows else { return }
        filteredRows = rows.compactMap { newIndex.indices.contains($0) ? newIndex[$0] : nil }.sorted()
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
    func isColumnHidden(_ column: Int) -> Bool { data.hiddenColumns?.contains(column) ?? false }
    func isRowHidden(_ row: Int) -> Bool { data.filteredRows?.contains(row) ?? false }

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
        guard let f = filter(for: column) else { return false }
        return !f.excluded.isEmpty || !(f.contains ?? "").isEmpty
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
        let all = Set(filterRows.map { Self.filterValue(text(master(CellRef(row: $0, column: column)))) })
        return all.sorted { $0.isEmpty != $1.isEmpty ? !$0.isEmpty : $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func setFilter(_ filter: ColumnFilter) {
        var list = (data.filters ?? []).filter { $0.column != filter.column }
        if !filter.excluded.isEmpty || !(filter.contains ?? "").isEmpty { list.append(filter) }
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

    /// Works out which rows the filters hide.
    func applyFilters() {
        guard let filters = data.filters, !filters.isEmpty else {
            data.filteredRows = nil
            return
        }
        let hidden = filterRows.filter { r in
            filters.contains { f in
                guard f.column < columnCount else { return false }
                let value = Self.filterValue(text(master(CellRef(row: r, column: f.column))))
                if f.excluded.contains(value) { return true }
                if let needle = f.contains, !needle.isEmpty, !value.localizedCaseInsensitiveContains(needle) { return true }
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

    /// The hidden columns whose mark is at x.
    func hiddenColumns(atX x: CGFloat) -> [Int]? {
        hiddenEdges().first { abs($0.x - x) <= 4 }?.columns
    }

    private func column(at x: CGFloat) -> Int? {
        guard let grid else { return nil }
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
        for edge in hiddenEdges() {
            addCursorRect(NSRect(x: edge.x - 4, y: 0, width: 8, height: bounds.height), cursor: .resizeLeftRight)
        }
    }
}

// MARK: - Filter popover

/// The filter button's popover: sorting, a search box and the column's values to show.
struct TableFilterView: View {
    let title: String
    let values: [String]
    let filter: ColumnFilter
    let sort: (Bool) -> Void
    let apply: (ColumnFilter) -> Void
    let close: () -> Void

    @State private var search = ""
    @State private var shown: Set<String> = []

    init(title: String, values: [String], filter: ColumnFilter, sort: @escaping (Bool) -> Void,
         apply: @escaping (ColumnFilter) -> Void, close: @escaping () -> Void) {
        self.title = title
        self.values = values
        self.filter = filter
        self.sort = sort
        self.apply = apply
        self.close = close
        _shown = State(initialValue: Set(values).subtracting(filter.excluded))
        _search = State(initialValue: filter.contains ?? "")
    }

    private var matching: [String] {
        search.isEmpty ? values : values.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    private func label(_ value: String) -> String { value.isEmpty ? "(Blanks)" : value }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { sort(true); close() } label: { Label("Sort A to Z", systemImage: "arrow.up") }
                .buttonStyle(.borderless)
            Button { sort(false); close() } label: { Label("Sort Z to A", systemImage: "arrow.down") }
                .buttonStyle(.borderless)
            Divider()
            Button {
                apply(ColumnFilter(column: filter.column))
                close()
            } label: {
                Label("Clear Filter from “\(title)”", systemImage: "line.3.horizontal.decrease.circle")
            }
            .buttonStyle(.borderless)
            .disabled(filter.excluded.isEmpty && (filter.contains ?? "").isEmpty)
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
