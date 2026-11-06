//
//  LogTable.swift — MxMidiPRO
//
//  The message screen: an AppKit table (tens of thousands of rows, appended 30 times a second) drawn as MMM's dark
//  log. It follows the newest message while it's scrolled to the bottom; scroll up and it stays where you are.
//  Click, ⇧-click or ⌘-click rows, ⌘A for all, then ⌘C (or right-click) to copy them as text.
//

import AppKit
import SwiftUI

struct LogHeader: View {
    let showRaw: Bool

    var body: some View {
        HStack(spacing: 6) {
            ForEach(LogColumn.allCases.filter { $0 != .raw || showRaw }, id: \.self) { column in
                Text(column.title)
                    .frame(width: column == .data ? nil : column.width,
                           alignment: column == .seq ? .trailing : .leading)
                    .frame(minWidth: column == .data ? 120 : nil, maxWidth: column == .data ? .infinity : nil,
                           alignment: .leading)
            }
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(Panel.screenDim)
        .padding(.horizontal, 3)
        .padding(.top, 4)
        .padding(.bottom, 3)
        .overlay(alignment: .bottom) { Panel.screenLine.frame(height: 1) }
    }
}

struct LogTable: NSViewRepresentable {
    let store: MonitorStore

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = LogTableView()
        table.style = .plain
        table.headerView = nil
        table.backgroundColor = Panel.nsScreen
        table.gridStyleMask = []
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.rowHeight = 15
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = false
        table.allowsColumnResizing = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.focusRingType = .none
        for column in LogColumn.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.width = column.width
            tableColumn.minWidth = column == .data ? 120 : column.width
            tableColumn.maxWidth = column == .data ? 10_000 : column.width
            tableColumn.resizingMask = column == .data ? .autoresizingMask : []
            table.addTableColumn(tableColumn)
        }
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.coordinator = context.coordinator
        table.menu = context.coordinator.makeMenu()

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.scrollerKnobStyle = .light
        scroll.drawsBackground = true
        scroll.backgroundColor = Panel.nsScreen
        scroll.borderType = .noBorder
        context.coordinator.table = table
        context.coordinator.scroll = scroll
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(append: store.appendRevision, reload: store.reloadRevision,
                                   format: store.formatRevision, showRaw: store.showRaw)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let store: MonitorStore
        weak var table: NSTableView?
        weak var scroll: NSScrollView?
        private var formatter = MIDIFormatter()
        private var shownCount = 0
        private var lastReload = -1
        private var lastFormat = -1

        init(store: MonitorStore) { self.store = store }

        func update(append: Int, reload: Int, format: Int, showRaw: Bool) {
            guard let table else { return }
            table.tableColumns.first { $0.identifier.rawValue == LogColumn.raw.rawValue }?.isHidden = !showRaw
            let follow = isAtBottom
            let count = store.events.count
            if reload != lastReload || format != lastFormat || count < shownCount {
                formatter = store.formatter
                lastReload = reload
                lastFormat = format
                table.reloadData()
            } else if count > shownCount {
                if formatter.portNames.count != store.ports.count { formatter = store.formatter }
                table.noteNumberOfRowsChanged()
            }
            shownCount = count
            if follow, count > 0 { table.scrollRowToVisible(count - 1) }
        }

        private var isAtBottom: Bool {
            guard let scroll, let table else { return true }
            let visible = scroll.contentView.bounds
            return visible.maxY >= table.bounds.height - table.rowHeight * 1.5
        }

        func numberOfRows(in tableView: NSTableView) -> Int { store.events.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, row < store.events.count,
                  let column = LogColumn(rawValue: tableColumn.identifier.rawValue) else { return nil }
            let field = (tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? NSTextField)
                ?? makeField(tableColumn.identifier, column)
            let event = store.events[row]
            field.stringValue = formatter.text(event, column)
            field.textColor = color(event, column)
            return field
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            LogRowView()
        }

        private func makeField(_ identifier: NSUserInterfaceItemIdentifier, _ column: LogColumn) -> NSTextField {
            let field = NSTextField(labelWithString: "")
            field.identifier = identifier
            field.font = Panel.logFont
            field.lineBreakMode = .byTruncatingTail
            field.alignment = column == .seq ? .right : .left
            field.cell?.usesSingleLineMode = true
            return field
        }

        private func color(_ e: MIDIEvent, _ column: LogColumn) -> NSColor {
            switch column {
            case .dir: e.direction == .input ? Panel.nsIn : Panel.nsOut
            case .seq, .time, .raw: Panel.nsDim
            default: e.kind == .clock || e.kind == .activeSensing ? Panel.nsDim : Panel.nsText
            }
        }

        // MARK: Copy

        func copySelection(rawBytesOnly: Bool = false) {
            guard let table else { return }
            var rows = table.selectedRowIndexes
            if rows.isEmpty, table.clickedRow >= 0 { rows = [table.clickedRow] }
            guard !rows.isEmpty else { return }
            let text: String
            if rawBytesOnly {
                text = rows.compactMap { $0 < store.events.count ? store.events[$0] : nil }
                    .map { $0.bytes.map { String(format: "%02X", $0) }.joined(separator: " ") }
                    .joined(separator: "\n")
            } else {
                text = store.copyText(rows: rows)
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            let copy = NSMenuItem(title: "Copy", action: #selector(menuCopy), keyEquivalent: "")
            copy.target = self
            let copyBytes = NSMenuItem(title: "Copy Bytes (hex)", action: #selector(menuCopyBytes), keyEquivalent: "")
            copyBytes.target = self
            menu.items = [copy, copyBytes]
            return menu
        }

        @objc private func menuCopy() { copySelection() }
        @objc private func menuCopyBytes() { copySelection(rawBytesOnly: true) }
    }
}

final class LogTableView: NSTableView, NSMenuItemValidation {
    weak var coordinator: LogTable.Coordinator?

    @objc func copy(_ sender: Any?) {
        coordinator?.copySelection()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copy(_:)) { return !selectedRowIndexes.isEmpty }
        return true
    }
}

final class LogRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        Panel.nsSelection.setFill()
        bounds.fill()
    }

    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}
