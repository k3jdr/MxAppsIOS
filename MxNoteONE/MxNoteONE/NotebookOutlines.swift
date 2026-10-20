//
//  NotebookOutlines.swift
//  MxNoteONE
//
//  The sidebar and the pages list as AppKit's outline and table views (their rows are still the SwiftUI views,
//  context menus and all) — for drag and drop that works like the Finder's: drag from any row, a line where it will
//  go, the row highlighted when it'll go into it, closed groups springing open as you hover. Sections and groups move
//  within their notebook and into groups; pages move within the list (subpages with them) and onto any section.
//

import AppKit
import SwiftUI

extension NSPasteboard.PasteboardType {
    static let mxSection = NSPasteboard.PasteboardType("com.k3jdr.mxnoteone.section")
    static let mxPage = NSPasteboard.PasteboardType("com.k3jdr.mxnoteone.page")
}

/// What a drag carries: the link (text, for notes and other apps) and which section or page it is (for the lists).
@MainActor
enum ListDrag {
    static func item(_ ref: SectionRef) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(NotebookStore.shared.sectionLink(ref).absoluteString, forType: .string)
        item.setString("\(ref.notebookID.uuidString)|\(ref.sectionID.uuidString)", forType: .mxSection)
        return item
    }

    static func item(_ ref: PageRef) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(NotebookStore.shared.link(for: ref).absoluteString, forType: .string)
        item.setString("\(ref.notebookID.uuidString)|\(ref.pageID.uuidString)", forType: .mxPage)
        return item
    }

    static func section(_ info: NSDraggingInfo) -> SectionRef? {
        guard let s = info.draggingPasteboard.string(forType: .mxSection) else { return nil }
        let parts = s.split(separator: "|").compactMap { UUID(uuidString: String($0)) }
        return parts.count == 2 ? SectionRef(notebookID: parts[0], sectionID: parts[1]) : nil
    }

    /// The dragged page where it is now.
    static func page(_ info: NSDraggingInfo) -> PageRef? {
        guard let s = info.draggingPasteboard.string(forType: .mxPage) else { return nil }
        let parts = s.split(separator: "|").compactMap { UUID(uuidString: String($0)) }
        return parts.count == 2 ? NotebookStore.shared.findPage(parts[1], in: parts[0]) : nil
    }
}

/// A row showing a SwiftUI view.
private final class HostedRow: NSTableCellView {
    let host = NSHostingView(rootView: AnyView(EmptyView()))

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor), host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor), host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// Clicks select and drag (the table's); right-clicks go to the row's SwiftUI context menu, and a click on a
/// row's own control (a subpage chevron) to the control.
private class HostedTableBehaviour {
    static func passes(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        return event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
    }
}

// MARK: - The sidebar

final class SidebarItemNode: NSObject {
    enum Kind {
        case notebook(Notebook)
        case node(SectionRef, SectionNode, Notebook)
    }
    var kind: Kind
    var children: [SidebarItemNode] = []

    init(_ kind: Kind) { self.kind = kind }

    var id: UUID {
        switch kind {
        case .notebook(let nb): nb.id
        case .node(let ref, _, _): ref.sectionID
        }
    }
    var isGroup: Bool { if case .node(_, let n, _) = kind { return n.isGroup }; return false }
}

private final class SidebarOutlineView: NSOutlineView {
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        HostedTableBehaviour.passes(event) || super.validateProposedFirstResponder(responder, for: event)
    }
}

struct SidebarOutline: NSViewRepresentable {
    /// Changes whenever what's shown does (notebooks, sections, names, colours).
    let signature: Int
    /// Changes whenever what's open does.
    let expansion: Int
    let selection: SidebarItem?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = SidebarOutlineView()
        outline.headerView = nil
        outline.style = .sourceList
        outline.usesAutomaticRowHeights = true
        outline.indentationPerLevel = 12
        outline.allowsMultipleSelection = false
        outline.allowsEmptySelection = true
        outline.backgroundColor = .clear
        outline.autoresizesOutlineColumn = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebar"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.registerForDraggedTypes([.mxSection, .mxPage])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        outline.draggingDestinationFeedbackStyle = .sourceList
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        context.coordinator.outline = outline
        context.coordinator.update(signature: signature, expansion: expansion)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(signature: signature, expansion: expansion)
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        weak var outline: NSOutlineView?
        private(set) var roots: [SidebarItemNode] = []
        private var signature: Int?
        private var expansion: Int?
        private var updating = false
        /// The rows' items by id, kept from one rebuild to the next (the outline knows its rows by them).
        private var items: [UUID: SidebarItemNode] = [:]
        private var store: NotebookStore { .shared }

        func update(signature s: Int, expansion e: Int) {
            if s != signature {
                signature = s
                expansion = e
                reload()
            } else if e != expansion {
                expansion = e
                syncExpansion()
                syncSelection()
            } else {
                syncSelection()
            }
        }

        private func reuse(_ kind: SidebarItemNode.Kind, _ id: UUID, _ seen: inout [UUID: SidebarItemNode]) -> SidebarItemNode {
            let item = items[id] ?? SidebarItemNode(kind)
            item.kind = kind
            seen[id] = item
            return item
        }

        private func build(_ node: SectionNode, _ nb: Notebook, _ seen: inout [UUID: SidebarItemNode]) -> SidebarItemNode {
            let item = reuse(.node(SectionRef(notebookID: nb.id, sectionID: node.id), node, nb), node.id, &seen)
            item.children = (node.children ?? []).map { build($0, nb, &seen) }
            return item
        }

        func reload() {
            guard let outline else { return }
            updating = true
            defer { updating = false }
            var seen: [UUID: SidebarItemNode] = [:]
            roots = store.notebooks.map { nb in
                let root = reuse(.notebook(nb), nb.id, &seen)
                root.children = nb.manifest.sections.map { build($0, nb, &seen) }
                return root
            }
            items = seen
            outline.reloadData()
            syncExpansion()
            syncSelection()
        }

        /// Opens and closes rows to match the store.
        private func syncExpansion() {
            guard let outline else { return }
            updating = true
            defer { updating = false }
            func sync(_ items: [SidebarItemNode]) {
                for item in items {
                    let open: Bool
                    switch item.kind {
                    case .notebook(let nb): open = store.expandedNotebooks.contains(nb.id)
                    case .node(_, let n, _): open = n.isGroup && store.expandedGroups.contains(n.id)
                    }
                    if open {
                        if !outline.isItemExpanded(item) { outline.expandItem(item) }
                        sync(item.children)
                    } else if outline.isItemExpanded(item) {
                        outline.collapseItem(item)
                    }
                }
            }
            sync(roots)
        }

        private func find(_ id: UUID, in items: [SidebarItemNode]) -> SidebarItemNode? {
            for item in items {
                if item.id == id { return item }
                if let found = find(id, in: item.children) { return found }
            }
            return nil
        }

        func syncSelection() {
            guard let outline else { return }
            let wanted: UUID? = switch store.sidebarSelection {
            case .section(let ref)?, .group(let ref)?: ref.sectionID
            case nil: nil
            }
            let current = outline.selectedRow >= 0 ? (outline.item(atRow: outline.selectedRow) as? SidebarItemNode)?.id : nil
            guard wanted != current else { return }
            updating = true
            defer { updating = false }
            if let wanted, let item = find(wanted, in: roots) {
                let row = outline.row(forItem: item)
                if row >= 0 {
                    outline.selectRowIndexes([row], byExtendingSelection: false)
                    outline.scrollRowToVisible(row)
                }
            } else {
                outline.deselectAll(nil)
            }
        }

        // MARK: Data

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? SidebarItemNode)?.children.count ?? roots.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            (item as? SidebarItemNode)?.children[index] ?? roots[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let item = item as? SidebarItemNode else { return false }
            if case .notebook = item.kind { return true }
            return item.isGroup
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let item = item as? SidebarItemNode else { return nil }
            let id = NSUserInterfaceItemIdentifier("sidebarRow")
            let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? HostedRow ?? HostedRow(identifier: id)
            switch item.kind {
            case .notebook(let nb):
                cell.host.rootView = AnyView(NotebookHeader(notebook: nb).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3))
            case .node(_, let node, let nb):
                cell.host.rootView = AnyView(SectionRow(notebook: nb, node: node).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 2))
            }
            return cell
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            guard let item = item as? SidebarItemNode, case .node = item.kind else { return false }
            return true
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let outline, outline.selectedRow >= 0,
                  let item = outline.item(atRow: outline.selectedRow) as? SidebarItemNode, case .node(let ref, let node, _) = item.kind else { return }
            store.selectSidebar(node.isGroup ? .group(ref) : .section(ref))
        }

        func outlineViewItemDidExpand(_ notification: Notification) { expanded(notification, true) }
        func outlineViewItemDidCollapse(_ notification: Notification) { expanded(notification, false) }

        private func expanded(_ notification: Notification, _ open: Bool) {
            guard !updating, let item = notification.userInfo?["NSObject"] as? SidebarItemNode else { return }
            switch item.kind {
            case .notebook(let nb):
                if open { store.expandedNotebooks.insert(nb.id) } else { store.expandedNotebooks.remove(nb.id) }
            case .node(_, let node, _):
                if open { store.expandedGroups.insert(node.id) } else { store.expandedGroups.remove(node.id) }
            }
        }

        // MARK: Drag and drop

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let item = item as? SidebarItemNode, case .node(let ref, _, _) = item.kind else { return nil }
            return ListDrag.item(ref)
        }

        /// Where a drop would go: a page onto a section; a section or group between rows of its notebook, onto a
        /// group (into it), or onto the notebook's row (last).
        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            let target = item as? SidebarItemNode
            if let page = ListDrag.page(info) {
                guard let target, case .node(let ref, let node, _) = target.kind, !node.isGroup, index == NSOutlineViewDropOnItemIndex,
                      ref != page.section, store.canMovePage(page, to: ref, near: nil) else { return [] }
                return .move
            }
            guard let dragged = ListDrag.section(info), let target else { return [] }
            switch target.kind {
            case .notebook(let nb):
                guard nb.id == dragged.notebookID else { return [] }
                if index == NSOutlineViewDropOnItemIndex { outlineView.setDropItem(target, dropChildIndex: target.children.count) }
                return .move
            case .node(let ref, let node, _):
                guard ref.notebookID == dragged.notebookID else { return [] }
                if node.isGroup {
                    return store.canMoveNode(dragged, to: ref, position: .inside) ? .move : []
                }
                // Onto a section: just above it.
                guard ref.sectionID != dragged.sectionID, let parent = outlineView.parent(forItem: target) as? SidebarItemNode,
                      let position = parent.children.firstIndex(of: target), store.canMoveNode(dragged, to: ref, position: .before) else { return [] }
                outlineView.setDropItem(parent, dropChildIndex: position)
                return .move
            }
        }

        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
            let target = item as? SidebarItemNode
            if let page = ListDrag.page(info) {
                guard case .node(let ref, let node, _)? = target?.kind, !node.isGroup else { return false }
                store.movePageTree(page, to: ref, before: nil)
                return true
            }
            guard let dragged = ListDrag.section(info) else { return false }
            let at = index == NSOutlineViewDropOnItemIndex ? Int.max : index
            switch target?.kind {
            case .notebook(let nb)?:
                guard nb.id == dragged.notebookID else { return false }
                store.moveNode(dragged, toGroup: nil, at: at)
            case .node(let ref, let node, _)? where node.isGroup:
                store.moveNode(dragged, toGroup: ref.sectionID, at: at)
            default:
                return false
            }
            return true
        }
    }
}

// MARK: - The pages list

private final class PagesTableView: NSTableView {
    /// Whether x (from the row's cell's left) is on its subpage chevron (where a click goes to the chevron
    /// rather than the table).
    var chevron: ((Int, CGFloat) -> Bool)?
    var onDelete: (() -> Void)?

    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        if HostedTableBehaviour.passes(event) { return true }
        if let event, event.type == .leftMouseDown {
            let p = convert(event.locationInWindow, from: nil)
            let r = row(at: p)
            let left = r >= 0 ? view(atColumn: 0, row: r, makeIfNecessary: false)?.frame.minX ?? rect(ofRow: r).minX : 0
            if r >= 0, chevron?(r, p.x - left) == true { return true }
        }
        return super.validateProposedFirstResponder(responder, for: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117, let onDelete { return onDelete() }
        super.keyDown(with: event)
    }
}

struct PagesTable: NSViewRepresentable {
    let section: SectionRef
    let pages: [PageMeta]
    let selected: UUID?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = PagesTableView()
        table.headerView = nil
        table.style = .inset
        table.usesAutomaticRowHeights = true
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.backgroundColor = .clear
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pages"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.registerForDraggedTypes([.mxPage])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.draggingDestinationFeedbackStyle = .regular
        let coordinator = context.coordinator
        table.chevron = { [weak coordinator] row, x in coordinator?.isChevron(row: row, x: x) ?? false }
        table.onDelete = { if let ref = NotebookStore.shared.currentPageRef { NotebookStore.shared.deletePage(ref) } }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        coordinator.table = table
        coordinator.update(section: section, pages: pages)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(section: section, pages: pages)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var table: NSTableView?
        private(set) var section: SectionRef?
        private(set) var pages: [PageMeta] = []
        private var updating = false
        private var store: NotebookStore { .shared }

        func update(section: SectionRef, pages: [PageMeta]) {
            guard let table else { return }
            updating = true
            defer { updating = false }
            if section != self.section || pages.map(\.id) != self.pages.map(\.id) {
                self.section = section
                self.pages = pages
                table.reloadData()
            } else if pages != self.pages {
                // The same pages: redraw only those that changed (a title being typed).
                let changed = IndexSet(pages.indices.filter { pages[$0] != self.pages[$0] })
                self.pages = pages
                table.reloadData(forRowIndexes: changed, columnIndexes: [0])
            }
            let wanted = store.selectedPageID.flatMap { id in pages.firstIndex { $0.id == id } }
            if let wanted {
                if table.selectedRow != wanted {
                    table.selectRowIndexes([wanted], byExtendingSelection: false)
                    table.scrollRowToVisible(wanted)
                }
            } else if table.selectedRow >= 0 {
                table.deselectAll(nil)
            }
        }

        private func ref(_ row: Int) -> PageRef? {
            guard let section, pages.indices.contains(row) else { return nil }
            return PageRef(notebookID: section.notebookID, sectionID: section.sectionID, pageID: pages[row].id)
        }

        /// Whether a click at x (from the row's cell's left) is on its subpage chevron (PageRow: 12 wide, after the
        /// level's indent).
        func isChevron(row: Int, x: CGFloat) -> Bool {
            guard let section, pages.indices.contains(row), store.hasSubpages(pages[row].id, in: section) else { return false }
            let start = CGFloat(pages[row].level) * 16
            return x >= start - 6 && x <= start + 18
        }

        func numberOfRows(in tableView: NSTableView) -> Int { pages.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let ref = ref(row), let section else { return nil }
            let id = NSUserInterfaceItemIdentifier("pageRow")
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? HostedRow ?? HostedRow(identifier: id)
            let meta = pages[row]
            let hasSubpages = store.hasSubpages(meta.id, in: section)
            cell.host.rootView = AnyView(
                PageRow(meta: meta, ref: ref, hasSubpages: hasSubpages)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                    .contextMenu { PageMenu(ref: ref, meta: meta, hasSubpages: hasSubpages) }
            )
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table, table.selectedRow >= 0, pages.indices.contains(table.selectedRow) else { return }
            store.selectPage(pages[table.selectedRow].id)
        }

        // MARK: Drag and drop

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            ref(row).map(ListDrag.item)
        }

        /// Between pages (a drop on a page goes above or below it, by which half the pointer's in).
        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
            guard let page = ListDrag.page(info), let section else { return [] }
            var target = row
            if op == .on {
                let p = tableView.convert(info.draggingLocation, from: nil)
                target = p.y > tableView.rect(ofRow: row).midY ? row + 1 : row
                tableView.setDropRow(target, dropOperation: .above)
            }
            let before = pages.indices.contains(target) ? pages[target].id : nil
            return store.canMovePage(page, to: section, near: before) ? .move : []
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard let page = ListDrag.page(info), let section else { return false }
            let target = pages.indices.contains(row) ? pages[row] : nil
            store.movePageTree(page, to: section, before: target?.id, level: target?.level ?? 0)
            return true
        }
    }
}
