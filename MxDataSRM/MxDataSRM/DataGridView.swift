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

        let scroll = NSScrollView()
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
        context.coordinator.reloadIfNeeded(version: version)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation {
        let session: WorkspaceSession
        weak var tableView: NSTableView?
        private var loadedVersion: Int?

        private static let rowNumberID = NSUserInterfaceItemIdentifier("rownum")
        private static let cellID = NSUserInterfaceItemIdentifier("cell")

        init(session: WorkspaceSession) {
            self.session = session
        }

        private var grid: GridData? { session.grid }

        func reloadIfNeeded(version: Int) {
            guard let tableView, version != loadedVersion else { return }
            loadedVersion = version
            tableView.tableColumns.forEach(tableView.removeTableColumn)

            let rowNumber = NSTableColumn(identifier: Self.rowNumberID)
            rowNumber.title = "#"
            rowNumber.width = GridMetrics.rowNumberWidth
            rowNumber.resizingMask = []
            tableView.addTableColumn(rowNumber)

            for (index, column) in (grid?.columns ?? []).enumerated() {
                let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(index)"))
                tableColumn.title = column.name
                tableColumn.headerToolTip = column.type + (column.notNull ? " not null" : "")
                tableColumn.width = GridMetrics.columnWidth
                tableColumn.minWidth = 40
                tableColumn.resizingMask = .userResizingMask
                tableView.addTableColumn(tableColumn)
            }
            tableView.reloadData()
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
            let edit = session.edits[CellKey(row: row, column: column)]
            let value = edit.map(\.value) ?? grid.rows[row][column]
            field.isEditable = true
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
