//
//  DataGridView.swift
//  MxDataSRM
//
//  Editable data grid backed by NSTableView, with always-visible vertical
//  and horizontal scroll bars. Edits are recorded in the session as pending
//  changes and highlighted until they are applied with Table ▸ Update.
//
//  Cells are selected like a spreadsheet (click, shift-click, drag, arrow keys;
//  # selects rows, a header selects a column). Copy works on every grid; Paste
//  only on editable grids, since read-only results (joins, expressions) do not
//  map back to one table.
//

import AppKit
import SwiftUI

enum GridMetrics {
    static let rowNumberWidth: CGFloat = 56
    static let columnWidth: CGFloat = 160
    static let minColumnWidth: CGFloat = 60
    static let rowHeight: CGFloat = 22
    static let intercell = NSSize(width: 3, height: 2)
    static let headerHeight: CGFloat = 28
    static let scrollerWidth: CGFloat = 15

    /// Size of a viewport that shows exactly `rows` × `columns` data cells.
    static func viewport(rows: Int, columns: Int) -> CGSize {
        CGSize(width: rowNumberWidth + intercell.width
                   + CGFloat(columns) * (columnWidth + intercell.width) + scrollerWidth + 2,
               height: headerHeight + CGFloat(rows) * (rowHeight + intercell.height) + scrollerWidth + 2)
    }
}

struct DataGridView: NSViewRepresentable {
    let session: WorkspaceSession
    /// Changes whenever the grid data is replaced or edits are discarded.
    let version: Int
    /// Number of data columns sized to span the visible width.
    let visibleColumns: Int
    /// Widths the user set for this table's columns (column name → width); these are not re-fitted.
    let savedWidths: [String: Double]
    /// Called (debounced) with all user-set widths for the table after a column is resized or reset.
    let onWidthsChanged: ([String: Double]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = GridTableView()
        table.coordinator = context.coordinator
        table.selectionHighlightStyle = .none
        table.allowsColumnSelection = false
        table.allowsEmptySelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsColumnReordering = false
        table.allowsMultipleSelection = false
        table.gridStyleMask = [.solidVerticalGridLineMask, .solidHorizontalGridLineMask]
        table.rowHeight = GridMetrics.rowHeight
        table.intercellSpacing = GridMetrics.intercell
        table.style = .plain
        table.dataSource = context.coordinator
        table.delegate = context.coordinator

        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(Coordinator.copyCells(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Copy with Column Names", action: #selector(Coordinator.copyCellsWithNames(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Paste", action: #selector(Coordinator.pasteCells(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Set to NULL", action: #selector(Coordinator.setNull(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Revert", action: #selector(Coordinator.revertCell(_:)), keyEquivalent: "")
        menu.items.forEach { $0.target = context.coordinator }
        table.menu = menu

        let headerMenu = NSMenu()
        headerMenu.addItem(withTitle: "Reset Column Widths", action: #selector(Coordinator.resetColumnWidths(_:)), keyEquivalent: "")
        headerMenu.items.forEach { $0.target = context.coordinator }
        table.headerView?.menu = headerMenu

        let scroll = GridScrollView()
        scroll.onResize = { [weak coordinator = context.coordinator] in coordinator?.fitColumns() }
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = false
        scroll.scrollerStyle = .legacy
        scroll.borderType = .bezelBorder
        context.coordinator.tableView = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.visibleColumns = visibleColumns
        context.coordinator.onWidthsChanged = onWidthsChanged
        context.coordinator.reloadIfNeeded(version: version, savedWidths: savedWidths)
        context.coordinator.fitColumns()
    }

    /// Scroll view that reports size changes so the columns can be re-fitted.
    final class GridScrollView: NSScrollView {
        var onResize: (() -> Void)?

        override func setFrameSize(_ newSize: NSSize) {
            let changed = newSize.width != frame.width
            super.setFrameSize(newSize)
            if changed { onResize?() }
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation {
        let session: WorkspaceSession
        weak var tableView: NSTableView?
        var visibleColumns = 3
        var onWidthsChanged: ([String: Double]) -> Void = { _ in }
        private var loadedVersion: Int?
        private var loadedWidthKey: String?
        /// Widths of columns the user resized, by column name. Never overwritten by fitColumns().
        private var userWidths: [String: CGFloat] = [:]
        /// Set while widths are changed in code, so only user drags count as resizes.
        private var adjustingWidths = false
        private var pendingSave: DispatchWorkItem?

        private static let rowNumberID = NSUserInterfaceItemIdentifier("rownum")
        private static let cellID = NSUserInterfaceItemIdentifier("cell")

        init(session: WorkspaceSession) {
            self.session = session
        }

        /// The rows the table view is showing. It is replaced only here, together with
        /// reloadData(), so the table view never asks for rows or columns that the data lacks,
        /// even if it redraws after `session.grid` changed and before SwiftUI calls updateNSView.
        private var grid: GridData?

        func reloadIfNeeded(version: Int, savedWidths: [String: Double]) {
            guard let tableView, version != loadedVersion else { return }
            loadedVersion = version
            let fresh = session.grid
            if fresh?.widthKey != loadedWidthKey {
                loadedWidthKey = fresh?.widthKey
                userWidths = savedWidths.mapValues { CGFloat($0) }
            }
            adjustingWidths = true
            defer { adjustingWidths = false }

            // A cell being edited belongs to the old rows; drop it rather than commit it to the new ones.
            tableView.abortEditing()
            selection = nil
            // Empty the table before changing columns: column changes redraw the visible rows.
            grid = nil
            tableView.reloadData()
            tableView.tableColumns.forEach(tableView.removeTableColumn)

            let rowNumber = NSTableColumn(identifier: Self.rowNumberID)
            rowNumber.title = "#"
            rowNumber.width = GridMetrics.rowNumberWidth
            rowNumber.resizingMask = []
            tableView.addTableColumn(rowNumber)

            for (index, column) in (fresh?.columns ?? []).enumerated() {
                let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(index)"))
                tableColumn.title = column.name
                tableColumn.headerToolTip = column.type + (column.notNull ? " not null" : "")
                tableColumn.minWidth = 40
                tableColumn.width = userWidths[column.name] ?? GridMetrics.columnWidth
                tableColumn.resizingMask = .userResizingMask
                tableView.addTableColumn(tableColumn)
            }
            grid = fresh
            tableView.reloadData()
        }

        /// Sizes the columns the user has not resized so that the first `visibleColumns`
        /// columns span the visible width; user-resized columns keep their width.
        func fitColumns() {
            guard let tableView, let clipWidth = tableView.enclosingScrollView?.contentView.bounds.width,
                  clipWidth > 0 else { return }
            let dataColumns = tableView.tableColumns.filter { $0.identifier != Self.rowNumberID }
            guard !dataColumns.isEmpty else { return }
            let spacing = GridMetrics.intercell.width
            let available = clipWidth - GridMetrics.rowNumberWidth - spacing
            let visible = dataColumns.prefix(max(1, visibleColumns))
            let fixed = visible.compactMap { userWidths[$0.title] }
            let flexibleCount = visible.count - fixed.count
            let width = flexibleCount > 0
                ? (available - fixed.reduce(0, +) - CGFloat(visible.count) * spacing) / CGFloat(flexibleCount)
                : available / CGFloat(visible.count) - spacing
            let fitted = max(GridMetrics.minColumnWidth, width.rounded(.down))

            adjustingWidths = true
            defer { adjustingWidths = false }
            for column in dataColumns {
                let target = userWidths[column.title] ?? fitted
                if column.width != target { column.width = target }
            }
        }

        func tableViewColumnDidResize(_ notification: Notification) {
            guard !adjustingWidths,
                  let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
                  column.identifier != Self.rowNumberID else { return }
            userWidths[column.title] = column.width
            fitColumns()
            saveWidthsSoon()
        }

        @objc func resetColumnWidths(_ sender: Any?) {
            userWidths = [:]
            fitColumns()
            saveWidthsSoon()
        }

        /// Writes the widths to the workspace once a drag settles, not on every pixel.
        private func saveWidthsSoon() {
            pendingSave?.cancel()
            let widths = userWidths.mapValues { Double($0) }
            let work = DispatchWorkItem { [weak self] in self?.onWidthsChanged(widths) }
            pendingSave = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }

        // MARK: Data source / delegate

        func numberOfRows(in tableView: NSTableView) -> Int {
            grid?.rows.count ?? 0
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let grid else { return nil }
            let field = (tableView.makeView(withIdentifier: Self.cellID, owner: self) as? NSTextField) ?? makeField()

            if tableColumn.identifier == Self.rowNumberID {
                field.isEditable = false
                field.stringValue = "\(grid.offset + row + 1)"
                field.alignment = .right
                field.textColor = .secondaryLabelColor
                field.placeholderString = nil
                field.drawsBackground = false
                return field
            }

            let column = columnIndex(of: tableColumn)
            guard grid.rows.indices.contains(row), grid.columns.indices.contains(column) else { return nil }
            let edit = session.edits[CellKey(row: row, column: column)]
            let value = edit.map(\.value) ?? grid.rows[row][column]
            field.isEditable = grid.isEditable
            field.alignment = .left
            field.textColor = .labelColor
            field.stringValue = value ?? ""
            field.placeholderString = value == nil ? "NULL" : nil
            let selected = selection?.contains(CellKey(row: row, column: column)) ?? false
            field.drawsBackground = edit != nil || selected
            field.backgroundColor = selected
                ? NSColor.controlAccentColor.withAlphaComponent(0.28)
                : NSColor.systemYellow.withAlphaComponent(0.35)
            field.toolTip = edit != nil ? "Was: \(grid.rows[row][column] ?? "NULL")" : nil
            return field
        }

        private func makeField() -> NSTextField {
            let field = NSTextField()
            field.identifier = Self.cellID
            field.isBordered = false
            field.lineBreakMode = .byTruncatingTail
            field.cell?.usesSingleLineMode = true
            (field.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = true
            field.target = self
            field.action = #selector(cellEdited(_:))
            return field
        }

        private func columnIndex(of tableColumn: NSTableColumn) -> Int {
            Int(tableColumn.identifier.rawValue.dropFirst())!
        }

        // MARK: Editing

        @objc func cellEdited(_ sender: NSTextField) {
            guard let tableView, let grid else { return }
            let row = tableView.row(for: sender)
            let tableColumnIndex = tableView.column(for: sender)
            guard row >= 0, tableColumnIndex > 0 else { return }
            let column = columnIndex(of: tableView.tableColumns[tableColumnIndex])
            guard grid.rows.indices.contains(row), grid.columns.indices.contains(column) else { return }
            let key = CellKey(row: row, column: column)
            let current = session.edits[key].map(\.value) ?? grid.rows[row][column]
            // An empty field on a NULL cell means "left alone", not ''.
            if current == nil && sender.stringValue.isEmpty { return }
            if current == sender.stringValue { return }
            session.setCell(row: row, column: column, to: sender.stringValue)
            reload(row: row, tableColumn: tableColumnIndex)
            refocusAfterKeyboardEdit()
        }

        /// After Return or Tab ends an edit, keep keyboard focus in the grid for arrow keys.
        private func refocusAfterKeyboardEdit() {
            guard NSApp.currentEvent?.type == .keyDown, let tableView else { return }
            DispatchQueue.main.async { tableView.window?.makeFirstResponder(tableView) }
        }

        func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
            switch menuItem.action {
            case #selector(resetColumnWidths(_:)): !userWidths.isEmpty
            case #selector(copyCells(_:)), #selector(copyCellsWithNames(_:)): canCopy
            case #selector(pasteCells(_:)): canPaste
            case #selector(setNull(_:)): grid?.isEditable == true && selection != nil
            case #selector(revertCell(_:)): selectedKeys.contains { session.edits[$0] != nil }
            default: true
            }
        }

        @objc func setNull(_ sender: Any?) {
            guard grid?.isEditable == true else { return }
            for key in selectedKeys { session.setCell(row: key.row, column: key.column, to: nil) }
            reloadSelection()
        }

        @objc func revertCell(_ sender: Any?) {
            for key in selectedKeys { session.edits[key] = nil }
            reloadSelection()
        }

        // MARK: Cell selection

        /// Selected cells: the rectangle between the anchor (first click) and the cursor.
        private(set) var selection: CellSelection?

        private var selectedKeys: [CellKey] { selection?.keys ?? [] }

        private var lastRow: Int { (grid?.rows.count ?? 0) - 1 }
        private var lastColumn: Int { (grid?.columns.count ?? 0) - 1 }

        func select(_ key: CellKey, extend: Bool) {
            guard grid != nil, (0...max(0, lastRow)).contains(key.row), (0...max(0, lastColumn)).contains(key.column),
                  lastRow >= 0, lastColumn >= 0 else { return }
            if extend, let anchor = selection?.anchor {
                setSelection(CellSelection(anchor: anchor, cursor: key))
            } else {
                setSelection(CellSelection(anchor: key, cursor: key))
            }
        }

        /// Click on a # cell: the whole row (shift extends from the anchor row).
        func selectRow(_ row: Int, extend: Bool) {
            guard lastColumn >= 0, row >= 0, row <= lastRow else { return }
            let anchorRow = extend ? (selection?.anchor.row ?? row) : row
            setSelection(CellSelection(anchor: CellKey(row: anchorRow, column: 0),
                                       cursor: CellKey(row: row, column: lastColumn)))
        }

        /// Click on a column header: the whole column (shift extends from the anchor column).
        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            guard tableColumn.identifier != Self.rowNumberID, lastRow >= 0 else { return }
            let column = columnIndex(of: tableColumn)
            let extend = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            let anchorColumn = extend ? (selection?.anchor.column ?? column) : column
            tableView.window?.makeFirstResponder(tableView)
            setSelection(CellSelection(anchor: CellKey(row: 0, column: anchorColumn),
                                       cursor: CellKey(row: lastRow, column: column)))
        }

        func selectAll() {
            guard lastRow >= 0, lastColumn >= 0 else { return }
            setSelection(CellSelection(anchor: CellKey(row: 0, column: 0),
                                       cursor: CellKey(row: lastRow, column: lastColumn)))
        }

        func clearSelection() { setSelection(nil) }

        /// Right-click: select the clicked cell unless it is already selected.
        func prepareContextMenu(row: Int, tableColumn: Int) {
            guard row >= 0, tableColumn > 0 else { return }
            let key = CellKey(row: row, column: tableColumn - 1)
            if !(selection?.contains(key) ?? false) { select(key, extend: false) }
        }

        private func setSelection(_ new: CellSelection?) {
            let old = selection
            selection = new
            if let cursor = new?.cursor {
                tableView?.scrollRowToVisible(cursor.row)
                tableView?.scrollColumnToVisible(cursor.column + 1)
            }
            reloadCells(in: [old, new].compactMap { $0 })
        }

        /// Redraws the cells of the given selections that are on screen.
        private func reloadCells(in selections: [CellSelection]) {
            guard let tableView, !selections.isEmpty else { return }
            let visible = tableView.rows(in: tableView.visibleRect)
            var rows = IndexSet(), columns = IndexSet()
            for s in selections {
                rows.insert(integersIn: s.rows.clamped(to: visible.location...max(visible.location, visible.location + visible.length - 1)))
                columns.insert(integersIn: (s.columns.lowerBound + 1)...(s.columns.upperBound + 1))
            }
            guard !rows.isEmpty else { return }
            tableView.reloadData(forRowIndexes: rows, columnIndexes: columns)
        }

        private func reloadSelection() {
            reloadCells(in: [selection].compactMap { $0 })
        }

        // MARK: Keyboard

        /// Arrow keys move (shift extends), Tab/Shift-Tab move across, Return edits.
        func handleKey(_ event: NSEvent) -> Bool {
            guard grid != nil, lastRow >= 0, lastColumn >= 0 else { return false }
            let extend = event.modifierFlags.contains(.shift)
            let cursor = selection?.cursor ?? CellKey(row: 0, column: 0)
            func move(_ dr: Int, _ dc: Int, extend: Bool) {
                if selection == nil { select(CellKey(row: 0, column: 0), extend: false); return }
                select(CellKey(row: min(max(cursor.row + dr, 0), lastRow),
                               column: min(max(cursor.column + dc, 0), lastColumn)), extend: extend)
            }
            switch event.keyCode {
            case 123: move(0, -1, extend: extend)
            case 124: move(0, 1, extend: extend)
            case 125: move(1, 0, extend: extend)
            case 126: move(-1, 0, extend: extend)
            case 48: move(0, extend ? -1 : 1, extend: false)       // Tab / Shift-Tab
            case 36, 76:                                           // Return / Enter
                guard selection != nil else { return false }
                beginEditing(cursor)
            default: return false
            }
            return true
        }

        /// Double-click or Return: edit the cell in place (editable grids only).
        func beginEditing(_ key: CellKey) {
            select(key, extend: false)
            guard let tableView, grid?.isEditable == true else { return }
            guard let field = tableView.view(atColumn: key.column + 1, row: key.row, makeIfNecessary: true) as? NSTextField,
                  field.isEditable else { return }
            tableView.window?.makeFirstResponder(field)
        }

        // MARK: Copy and paste

        var canCopy: Bool { selection != nil }

        var canPaste: Bool {
            grid?.isEditable == true && selection != nil
                && NSPasteboard.general.string(forType: .string) != nil
        }

        @objc func copyCells(_ sender: Any?) { copySelection(withNames: false) }
        @objc func copyCellsWithNames(_ sender: Any?) { copySelection(withNames: true) }
        @objc func pasteCells(_ sender: Any?) { pasteIntoSelection() }

        /// One cell copies as its plain value; several copy as tab-separated rows
        /// (pastes into Numbers or Excel as cells). NULL copies as an empty value.
        func copySelection(withNames: Bool) {
            guard let grid, let selection else { return }
            let columns = Array(selection.columns)
            var lines: [String] = []
            if withNames {
                lines.append(tsvLine(columns.map { grid.columns[$0].name }))
            }
            for row in selection.rows {
                lines.append(tsvLine(columns.map { displayed(row: row, column: $0) ?? "" }))
            }
            let single = !withNames && selection.rows.count == 1 && columns.count == 1
            let text = single ? (displayed(row: selection.rows.lowerBound, column: columns[0]) ?? "") : lines.joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        /// Pastes tab-separated text as pending edits, starting at the top-left selected cell.
        /// A single value fills every selected cell. Editable grids only.
        func pasteIntoSelection() {
            guard canPaste, let grid, let selection,
                  let text = NSPasteboard.general.string(forType: .string) else { return }
            let values = parseTSV(text)
            guard !values.isEmpty else { return }
            var pasted: CellSelection
            if values.count == 1, values[0].count == 1 {
                for key in selection.keys { session.setCell(row: key.row, column: key.column, to: values[0][0]) }
                pasted = selection
            } else {
                let top = CellKey(row: selection.rows.lowerBound, column: selection.columns.lowerBound)
                var bottom = top
                for (r, line) in values.enumerated() where top.row + r < grid.rows.count {
                    for (c, value) in line.enumerated() where top.column + c < grid.columns.count {
                        session.setCell(row: top.row + r, column: top.column + c, to: value)
                        bottom = CellKey(row: max(bottom.row, top.row + r), column: max(bottom.column, top.column + c))
                    }
                }
                pasted = CellSelection(anchor: top, cursor: bottom)
            }
            setSelection(pasted)
        }

        /// The value shown in a cell: the pending edit if there is one, else the loaded value.
        private func displayed(row: Int, column: Int) -> String? {
            if let edit = session.edits[CellKey(row: row, column: column)] { return edit.value }
            return grid?.rows[row][column]
        }

        private func reload(row: Int, tableColumn: Int) {
            tableView?.reloadData(forRowIndexes: [row], columnIndexes: [tableColumn])
        }
    }
}

/// The rectangle of selected cells between `anchor` and `cursor` (inclusive).
nonisolated struct CellSelection: Equatable, Sendable {
    var anchor: CellKey
    var cursor: CellKey

    var rows: ClosedRange<Int> { min(anchor.row, cursor.row)...max(anchor.row, cursor.row) }
    var columns: ClosedRange<Int> { min(anchor.column, cursor.column)...max(anchor.column, cursor.column) }

    func contains(_ key: CellKey) -> Bool { rows.contains(key.row) && columns.contains(key.column) }

    var keys: [CellKey] { rows.flatMap { r in columns.map { CellKey(row: r, column: $0) } } }
}

/// NSTableView with spreadsheet-style cell selection instead of row selection.
/// Edit ▸ Copy / Paste / Select All reach it through the responder chain.
final class GridTableView: NSTableView {
    weak var coordinator: DataGridView.Coordinator?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let coordinator else { return super.mouseDown(with: event) }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point), tableColumn = column(at: point)
        let extend = event.modifierFlags.contains(.shift)
        guard row >= 0, tableColumn >= 0 else {
            coordinator.clearSelection()
            return
        }
        if tableColumn == 0 {
            coordinator.selectRow(row, extend: extend)
            return
        }
        let key = CellKey(row: row, column: tableColumn - 1)
        if event.clickCount == 2 {
            coordinator.beginEditing(key)
            return
        }
        coordinator.select(key, extend: extend)
        // Drag to extend the selection, scrolling when the pointer leaves the visible area.
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
            autoscroll(with: next)
            let p = convert(next.locationInWindow, from: nil)
            let r = self.row(at: p), c = self.column(at: p)
            if r >= 0, c > 0 { coordinator.select(CellKey(row: r, column: c - 1), extend: true) }
        }
    }

    override func keyDown(with event: NSEvent) {
        if !(coordinator?.handleKey(event) ?? false) { super.keyDown(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        coordinator?.prepareContextMenu(row: row(at: point), tableColumn: column(at: point))
        return super.menu(for: event)
    }

    @IBAction func copy(_ sender: Any?) { coordinator?.copySelection(withNames: false) }
    @IBAction func paste(_ sender: Any?) { coordinator?.pasteIntoSelection() }
    override func selectAll(_ sender: Any?) { coordinator?.selectAll() }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): coordinator?.canCopy ?? false
        case #selector(paste(_:)): coordinator?.canPaste ?? false
        case #selector(selectAll(_:)): (numberOfRows > 0)
        default: super.validateUserInterfaceItem(item)
        }
    }
}

/// One line of tab-separated values; fields with a tab, line break or quote are quoted.
nonisolated func tsvLine(_ fields: [String]) -> String {
    fields.map { field in
        field.contains(where: { $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "\"" })
            ? "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            : field
    }.joined(separator: "\t")
}

/// Parses tab-separated text (as copied from this grid or a spreadsheet) into rows of fields.
/// Quoted fields may contain tabs, line breaks and doubled quotes. A trailing line break is ignored.
nonisolated func parseTSV(_ text: String) -> [[String]] {
    var rows: [[String]] = []
    var row: [String] = []
    var field = ""
    var chars = Array(text)[...]
    var atFieldStart = true
    while let c = chars.first {
        chars.removeFirst()
        if atFieldStart, c == "\"" {
            atFieldStart = false
            while let q = chars.first {
                chars.removeFirst()
                if q == "\"" {
                    if chars.first == "\"" { chars.removeFirst(); field.append("\"") } else { break }
                } else {
                    field.append(q)
                }
            }
            continue
        }
        atFieldStart = false
        switch c {
        case "\t":
            row.append(field); field = ""; atFieldStart = true
        case "\n", "\r\n", "\r":
            row.append(field); field = ""; atFieldStart = true
            rows.append(row); row = []
        default:
            field.append(c)
        }
    }
    if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
    return rows
}
