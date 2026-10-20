//
//  FileListView.swift
//  MxFileMGR
//
//  The file list of a pane: an NSTableView with sortable columns, a ".." row,
//  keyboard navigation (Return, Backspace, Tab, Space for Quick Look),
//  type-to-select, drag and drop, copy/paste of files and a context menu.
//

import AppKit
import Quartz
import SwiftUI

struct FileListView: NSViewRepresentable {
    let workspace: Workspace
    let side: Side
    let tab: BrowserTab
    // Passed in so SwiftUI re-runs updateNSView when they change.
    let version: Int
    let selection: Set<URL>
    let isActive: Bool
    let focusToken: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let table = FileTableView()
        table.coordinator = coordinator
        table.style = .plain
        table.rowHeight = 20
        table.intercellSpacing = NSSize(width: 6, height: 1)
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.allowsTypeSelect = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        for key in SortKey.allCases {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key.rawValue))
            column.title = key.title
            column.sortDescriptorPrototype = NSSortDescriptor(key: key.rawValue, ascending: true)
            switch key {
            case .name: column.width = 260; column.minWidth = 120
            case .ext: column.width = 50; column.minWidth = 30
            case .size: column.width = 80; column.minWidth = 50
                column.headerCell.alignment = .right
            case .modified: column.width = 130; column.minWidth = 80
            case .kind: column.width = 120; column.minWidth = 50
            }
            table.addTableColumn(column)
        }
        table.autosaveName = "MxFileMGR.FileList.\(side.rawValue)"
        table.autosaveTableColumns = true

        table.dataSource = coordinator
        table.delegate = coordinator
        table.target = coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: false)
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.workspace = workspace
        coordinator.side = side
        coordinator.update(tab: tab)
        coordinator.applyFocus(active: isActive, token: focusToken)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        enum Row {
            case parent(URL)
            case item(FileItem)
        }

        weak var table: FileTableView?
        weak var workspace: Workspace?
        var side: Side = .left
        private(set) weak var tab: BrowserTab?
        private var version = -1
        private var shownURL: URL?
        private var rows: [Row] = []
        private var updating = false
        private var focusToken = 0
        private var icons: [URL: NSImage] = [:]

        func item(at row: Int) -> FileItem? {
            guard rows.indices.contains(row), case .item(let item) = rows[row] else { return nil }
            return item
        }

        private func selectedURLs() -> Set<URL> {
            guard let table else { return [] }
            return Set(table.selectedRowIndexes.compactMap { item(at: $0)?.url })
        }

        var previewURLs: [URL] {
            guard let table else { return [] }
            return table.selectedRowIndexes.compactMap { item(at: $0)?.url }
        }

        // MARK: Updates from the model

        func update(tab newTab: BrowserTab) {
            guard let table else { return }
            let tabChanged = newTab !== tab
            if tabChanged || newTab.version != version {
                let folderChanged = tabChanged || newTab.url != shownURL
                tab = newTab
                version = newTab.version
                shownURL = newTab.url
                if folderChanged { icons.removeAll() }
                rows = (newTab.parentURL.map { [Row.parent($0)] } ?? []) + newTab.items.map { Row.item($0) }

                updating = true
                let descriptor = NSSortDescriptor(key: newTab.sort.key.rawValue, ascending: newTab.sort.ascending)
                if table.sortDescriptors != [descriptor] { table.sortDescriptors = [descriptor] }
                table.reloadData()
                applySelection(newTab.selection)
                if folderChanged, newTab.selection.isEmpty, !rows.isEmpty {
                    // Put the cursor on the first row (usually "..") so the keyboard works at once.
                    table.selectRowIndexes([0], byExtendingSelection: false)
                }
                updating = false

                if let target = newTab.scrollTarget {
                    newTab.scrollTarget = nil
                    if let row = rows.firstIndex(where: { if case .item(let it) = $0 { it.url == target } else { false } }) {
                        table.scrollRowToVisible(row)
                    }
                } else if folderChanged {
                    table.scrollRowToVisible(0)
                }
                refreshQuickLook()
            } else if newTab.selection != selectedURLs() {
                updating = true
                applySelection(newTab.selection)
                updating = false
            }
        }

        private func applySelection(_ urls: Set<URL>) {
            guard let table else { return }
            var indexes = IndexSet()
            for (i, row) in rows.enumerated() {
                if case .item(let it) = row, urls.contains(it.url) { indexes.insert(i) }
            }
            if indexes != table.selectedRowIndexes, !(indexes.isEmpty && selectedURLs().isEmpty) {
                table.selectRowIndexes(indexes, byExtendingSelection: false)
            }
            if let first = indexes.first, !urls.isEmpty, table.visibleRect.height > 0 {
                let visible = table.rows(in: table.visibleRect)
                if !NSLocationInRange(first, visible) { table.scrollRowToVisible(first) }
            }
        }

        func applyFocus(active: Bool, token: Int) {
            guard token != focusToken else { return }
            focusToken = token
            guard active else { return }
            DispatchQueue.main.async { [weak table] in
                guard let table, let window = table.window, window.firstResponder !== table else { return }
                window.makeFirstResponder(table)
            }
        }

        // MARK: User actions

        func didBecomeFirstResponder() {
            guard let workspace else { return }
            if workspace.activeSide != side { workspace.activeSide = side }
            Workspace.current = workspace
        }

        @objc func doubleClicked(_ sender: Any?) {
            guard let table, table.clickedRow >= 0 else { return }
            open(row: table.clickedRow)
        }

        func open(row: Int) {
            guard let tab, let workspace, rows.indices.contains(row) else { return }
            switch rows[row] {
            case .parent: tab.goUp()
            case .item(let item): workspace.open(item, in: tab)
            }
        }

        func openCurrent() {
            guard let table else { return }
            if table.selectedRowIndexes.count > 1 {
                workspace?.openSelection()
            } else if table.selectedRow >= 0 {
                open(row: table.selectedRow)
            }
        }

        func goUp() { tab?.goUp() }
        func switchPane() { workspace?.switchPane() }

        func clearFilter() -> Bool {
            guard let tab, !tab.filterText.isEmpty else { return false }
            tab.filterText = ""
            return true
        }

        func copyToPasteboard() { workspace?.copyToPasteboard() }
        func paste() { workspace?.pasteFromPasteboard(move: false) }
        func moveToTrash() { workspace?.moveToTrash() }

        private func refreshQuickLook() {
            if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible,
               panel.dataSource === table {
                panel.reloadData()
            }
        }

        // MARK: Data source

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let key = SortKey(rawValue: tableColumn.identifier.rawValue),
                  rows.indices.contains(row) else { return nil }
            let cell = (tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? FileCell)
                ?? FileCell(identifier: tableColumn.identifier, withIcon: key == .name, rightAligned: key == .size)
            cell.alphaValue = 1
            switch rows[row] {
            case .parent:
                cell.set(text: key == .name ? ".." : (key == .size ? "<UP>" : ""),
                         icon: key == .name ? NSImage(systemSymbolName: "arrow.turn.left.up", accessibilityDescription: "Parent folder") : nil)
            case .item(let item):
                let text: String
                switch key {
                case .name: text = item.name
                case .ext: text = item.ext
                case .size:
                    if item.isDirectory {
                        text = tab?.folderSizes[item.url].map(Fmt.size) ?? "<DIR>"
                    } else {
                        text = item.isPackage ? "—" : Fmt.size(item.size)
                    }
                case .modified: text = Fmt.date(item.modified)
                case .kind: text = item.kind
                }
                cell.set(text: text, icon: key == .name ? icon(for: item.url) : nil, italic: item.isSymlink && key == .name)
                if item.isHidden { cell.alphaValue = 0.55 }
            }
            return cell
        }

        private func icon(for url: URL) -> NSImage {
            if let cached = icons[url] { return cached }
            let image = NSWorkspace.shared.icon(forFile: url.path)
            image.size = NSSize(width: 16, height: 16)
            icons[url] = image
            return image
        }

        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            guard tableColumn?.identifier.rawValue == SortKey.name.rawValue else { return nil }
            return item(at: row)?.name
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !updating, let tab, let descriptor = tableView.sortDescriptors.first,
                  let key = SortKey(rawValue: descriptor.key ?? "") else { return }
            tab.sort = SortOrder(key: key, ascending: descriptor.ascending)
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let tab else { return }
            let urls = selectedURLs()
            if tab.selection != urls { tab.selection = urls }
            refreshQuickLook()
        }

        // MARK: Drag and drop

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            item(at: row)?.url as NSURL?
        }

        private func draggedURLs(_ info: NSDraggingInfo) -> [URL] {
            info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        }

        private func dropFolder(row: Int, operation: NSTableView.DropOperation) -> URL? {
            guard let tab else { return nil }
            if operation == .on, rows.indices.contains(row) {
                switch rows[row] {
                case .parent(let url): return url
                case .item(let item) where item.isDirectory: return item.url
                default: break
                }
            }
            return tab.url
        }

        private func operation(for info: NSDraggingInfo, urls: [URL], into folder: URL) -> NSDragOperation {
            let mask = info.draggingSourceOperationMask
            if mask.contains(.move), mask != .copy, let first = urls.first, FileOps.sameVolume(first, folder) {
                return .move
            }
            if mask.contains(.copy) { return .copy }
            if mask.contains(.move) { return .move }
            return []
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                       proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            let urls = draggedURLs(info)
            guard !urls.isEmpty, let folder = dropFolder(row: row, operation: dropOperation) else { return [] }
            if folder == tab?.url { tableView.setDropRow(-1, dropOperation: .on) }
            let target = folder.standardizedFileURL
            // Dropping items back into their own folder, or a folder onto itself, does nothing.
            if urls.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == target })
                || urls.contains(where: { $0.standardizedFileURL == target }) {
                return []
            }
            return operation(for: info, urls: urls, into: folder)
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
            let urls = draggedURLs(info)
            guard !urls.isEmpty, let workspace, let folder = dropFolder(row: row, operation: dropOperation) else { return false }
            let op = operation(for: info, urls: urls, into: folder)
            guard !op.isEmpty else { return false }
            workspace.transfer(urls, to: folder, move: op == .move)
            return true
        }

        // MARK: Context menu

        func contextMenu(forRow row: Int) -> NSMenu? {
            guard let workspace, let tab else { return nil }
            let menu = NSMenu()
            let marked = tab.selectedItems
            let urls = marked.map(\.url)

            if !marked.isEmpty {
                menu.addItem(ActionMenuItem("Open") { workspace.openSelection() })
                if marked.count == 1, marked[0].isDirectory {
                    menu.addItem(ActionMenuItem("Open in New Tab") { workspace.openInNewTab() })
                    menu.addItem(ActionMenuItem("Open in Other Pane") { workspace.openInOtherPane() })
                }
                if marked.count == 1, marked[0].isPackage {
                    menu.addItem(ActionMenuItem("Show Package Contents") { workspace.showPackageContents() })
                }
                if let first = urls.first, !marked[0].isDirectory {
                    let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
                    let sub = NSMenu()
                    for app in NSWorkspace.shared.urlsForApplications(toOpen: first).prefix(20) {
                        let item = ActionMenuItem(FileManager.default.displayName(atPath: app.path)) {
                            workspace.open(urls, with: app)
                        }
                        let image = NSWorkspace.shared.icon(forFile: app.path)
                        image.size = NSSize(width: 16, height: 16)
                        item.image = image
                        sub.addItem(item)
                    }
                    if !sub.items.isEmpty { sub.addItem(.separator()) }
                    sub.addItem(ActionMenuItem("Other…") { workspace.chooseApplicationAndOpen(urls) })
                    openWith.submenu = sub
                    menu.addItem(openWith)
                }
                menu.addItem(.separator())
                menu.addItem(ActionMenuItem("Quick Look") { [weak self] in self?.table?.toggleQuickLook(nil) })
                menu.addItem(ActionMenuItem("View") { workspace.view() })
                menu.addItem(ActionMenuItem("Edit") { workspace.edit() })
                menu.addItem(.separator())
                menu.addItem(ActionMenuItem("Copy to Other Pane…") { workspace.copyOrMoveToOtherPane(move: false) })
                menu.addItem(ActionMenuItem("Move to Other Pane…") { workspace.copyOrMoveToOtherPane(move: true) })
                menu.addItem(ActionMenuItem("Rename…") { workspace.rename() })
                menu.addItem(ActionMenuItem("Duplicate") { workspace.duplicate() })
                menu.addItem(ActionMenuItem("Compress") { workspace.compress() })
                if marked.count == 1, !marked[0].isDirectory, FFmpegTool.supports(marked[0].url) {
                    menu.addItem(ActionMenuItem("ffmpeg Meta-data…") { workspace.editMediaMetadata() })
                }
                if urls.contains(where: FileOps.isArchive) {
                    menu.addItem(ActionMenuItem("Extract to Other Pane") { workspace.extract() })
                }
                menu.addItem(.separator())
                menu.addItem(ActionMenuItem("Copy") { workspace.copyToPasteboard() })
                menu.addItem(ActionMenuItem("Copy Path") { workspace.copyPaths() })
                menu.addItem(ActionMenuItem("Show in Finder") { workspace.revealInFinder() })
                menu.addItem(ActionMenuItem("Properties…") { workspace.showProperties() })
                menu.addItem(.separator())
                menu.addItem(ActionMenuItem("Move to Trash") { workspace.moveToTrash() })
                menu.addItem(.separator())
            }
            menu.addItem(ActionMenuItem("New Folder…") { workspace.newFolder() })
            menu.addItem(ActionMenuItem("New File…") { workspace.newFile() })
            menu.addItem(ActionMenuItem("Paste") { workspace.pasteFromPasteboard(move: false) })
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem("Open Terminal Here") { workspace.openTerminal() })
            menu.addItem(ActionMenuItem("Add to Favorites") { workspace.addToFavorites() })
            return menu
        }
    }
}

// MARK: - Table view

final class FileTableView: NSTableView {
    weak var coordinator: FileListView.Coordinator?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { coordinator?.didBecomeFirstResponder() }
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        switch (event.keyCode, mods) {
        case (36, []), (76, []), (125, [.command]):     // Return, Enter, Cmd-Down
            coordinator?.openCurrent()
        case (51, []), (126, [.command]):               // Backspace, Cmd-Up
            coordinator?.goUp()
        case (48, []), (48, [.shift]):                  // Tab switches panes
            coordinator?.switchPane()
        case (49, []):                                  // Space
            toggleQuickLook(nil)
        case (53, []):                                  // Escape clears the quick filter
            if coordinator?.clearFilter() != true { super.keyDown(with: event) }
        default:
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes([row], byExtendingSelection: false)
        } else if row < 0 {
            deselectAll(nil)
        }
        window?.makeFirstResponder(self)
        return coordinator?.contextMenu(forRow: row)
    }

    // Edit menu (responder chain).
    @objc func copy(_ sender: Any?) { coordinator?.copyToPasteboard() }
    @objc func paste(_ sender: Any?) { coordinator?.paste() }
    @objc func delete(_ sender: Any?) { coordinator?.moveToTrash() }

    // MARK: Quick Look

    @objc func toggleQuickLook(_ sender: Any?) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
}

extension FileTableView: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        coordinator?.previewURLs.count ?? 0
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        guard let urls = coordinator?.previewURLs, urls.indices.contains(index) else { return nil }
        return urls[index] as NSURL
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        // Arrow keys in the panel move through the list.
        if event.type == .keyDown, [125, 126].contains(event.keyCode) {
            keyDown(with: event)
            return true
        }
        return false
    }
}

// MARK: - Cell

final class FileCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let iconView = NSImageView()

    init(identifier: NSUserInterfaceItemIdentifier, withIcon: Bool, rightAligned: Bool) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.lineBreakMode = .byTruncatingMiddle
        label.alignment = rightAligned ? .right : .left
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = rightAligned ? .secondaryLabelColor : .labelColor
        addSubview(label)
        textField = label
        if withIcon {
            iconView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(iconView)
            imageView = iconView
            NSLayoutConstraint.activate([
                iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: 16),
                iconView.heightAnchor.constraint(equalToConstant: 16),
                label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 5),
            ])
        } else {
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2).isActive = true
        }
        NSLayoutConstraint.activate([
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func set(text: String, icon: NSImage?, italic: Bool = false) {
        label.stringValue = text
        let size = NSFont.systemFontSize
        label.font = italic ? NSFontManager.shared.convert(.systemFont(ofSize: size), toHaveTrait: .italicFontMask)
                            : .systemFont(ofSize: size)
        iconView.image = icon
    }
}

/// An NSMenuItem that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { handler() }
}
