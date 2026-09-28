//
//  DataGridView.swift
//  MxDataSRM
//
//  Editable data grid backed by NSTableView, with always-visible vertical
//  and horizontal scroll bars. Edits are recorded in the session as pending
//  changes and highlighted until they are applied with Table ▸ Update.
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
        let table = NSTableView()
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
        menu.addItem(withTitle: "Set Cell to NULL", action: #selector(Coordinator.setNull(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Revert Cell", action: #selector(Coordinator.revertCell(_:)), keyEquivalent: "")
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
                field.stringValue = "\(row + 1)"
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
            field.drawsBackground = edit != nil
            field.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.35)
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
        }

        private func clickedCell() -> (row: Int, column: Int, tableColumn: Int)? {
            guard let tableView else { return nil }
            let row = tableView.clickedRow, tableColumn = tableView.clickedColumn
            guard row >= 0, tableColumn > 0 else { return nil }
            return (row, columnIndex(of: tableView.tableColumns[tableColumn]), tableColumn)
        }

        func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
            if menuItem.action == #selector(resetColumnWidths(_:)) { return !userWidths.isEmpty }
            guard grid?.isEditable == true else { return false }
            guard let cell = clickedCell() else { return false }
            if menuItem.action == #selector(revertCell(_:)) {
                return session.edits[CellKey(row: cell.row, column: cell.column)] != nil
            }
            return true
        }

        @objc func setNull(_ sender: Any?) {
            guard let cell = clickedCell() else { return }
            session.setCell(row: cell.row, column: cell.column, to: nil)
            reload(row: cell.row, tableColumn: cell.tableColumn)
        }

        @objc func revertCell(_ sender: Any?) {
            guard let cell = clickedCell() else { return }
            session.edits[CellKey(row: cell.row, column: cell.column)] = nil
            reload(row: cell.row, tableColumn: cell.tableColumn)
        }

        private func reload(row: Int, tableColumn: Int) {
            tableView?.reloadData(forRowIndexes: [row], columnIndexes: [tableColumn])
        }
    }
}
