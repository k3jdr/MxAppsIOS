//
//  NotebookDragDrop.swift
//  MxNoteONE
//
//  Drag and drop in the sidebar and the pages list. Sections and section groups drag to a new place — before or
//  after another (a line shows where), or into a group (it's highlighted); onto the notebook's name puts one last.
//  Pages drag to a new place in the list, and onto a section in the sidebar to move there (any notebook); a page's
//  subpages go with it. What's dragged is its link, so dropped into a note it becomes a link to it.
//

import SwiftUI
import UniformTypeIdentifiers

extension NotebookStore {
    enum DropPosition: Equatable { case before, after, inside }

    /// Whether a section or group can go there (the same notebook; not into itself or a group inside it).
    func canMoveNode(_ ref: SectionRef, to target: SectionRef, position: DropPosition) -> Bool {
        guard ref.notebookID == target.notebookID, ref.sectionID != target.sectionID, let nb = notebook(ref.notebookID),
              let node = nb.manifest.sections.find(ref.sectionID), let t = nb.manifest.sections.find(target.sectionID),
              node.children?.find(target.sectionID) == nil else { return false }
        return position == .inside ? t.isGroup : true
    }

    /// A section or group before or after another, or into a group (opened, so it shows).
    func moveNode(_ ref: SectionRef, to target: SectionRef, position: DropPosition) {
        guard canMoveNode(ref, to: target, position: position), let nb = notebook(ref.notebookID) else { return NSSound.beep() }
        if position == .inside {
            moveNode(ref, toGroup: target.sectionID)
            expandedGroups.insert(target.sectionID)
            return
        }
        guard let removed = nb.manifest.sections.removeNode(ref.sectionID) else { return }
        if !nb.manifest.sections.insert(removed, beside: target.sectionID, after: position == .after) {
            nb.manifest.sections.append(removed)
        }
        saveManifest(nb)
    }

    /// A page and its subpages, in order.
    func family(_ ref: PageRef) -> [PageMeta] {
        guard let pages = pages(in: ref.section), let i = pages.firstIndex(where: { $0.id == ref.pageID }) else { return [] }
        var end = i + 1
        while end < pages.count, pages[end].level > pages[i].level { end += 1 }
        return Array(pages[i..<end])
    }

    /// The page after another's subpages (where a drop just after it goes); nil at the end.
    func page(after id: UUID, in section: SectionRef) -> UUID? {
        guard let pages = pages(in: section), let i = pages.firstIndex(where: { $0.id == id }) else { return nil }
        var end = i + 1
        while end < pages.count, pages[end].level > pages[i].level { end += 1 }
        return end < pages.count ? pages[end].id : nil
    }

    /// Whether a page (and its subpages) can be dropped there: not onto itself or one of its subpages, nor to or
    /// from a locked section.
    func canMovePage(_ ref: PageRef, to dest: SectionRef, near target: UUID?) -> Bool {
        guard !isLocked(ref.section), !isLocked(dest), notebook(dest.notebookID)?.sections[dest.sectionID] != nil else { return false }
        if let target, ref.section == dest, family(ref).contains(where: { $0.id == target }) { return false }
        return true
    }

    /// A page and its subpages dropped before a page of a section (nil: at its end), at `level` (the page dropped
    /// next to's). From another section (or notebook) they're moved there.
    func movePageTree(_ ref: PageRef, to dest: SectionRef, before targetID: UUID?, level: Int = 0) {
        guard canMovePage(ref, to: dest, near: targetID) else { return NSSound.beep() }
        let family = family(ref)
        guard let first = family.first else { return }
        let relative = family.map { $0.level - first.level }
        if ref.section != dest {
            for meta in family {
                movePage(PageRef(notebookID: ref.notebookID, sectionID: ref.sectionID, pageID: meta.id), to: dest, copy: false)
            }
        }
        guard let nb = notebook(dest.notebookID), var pages = nb.sections[dest.sectionID]?.pages else { return }
        let ids = family.map(\.id)
        var moving = ids.compactMap { id in pages.first { $0.id == id } }
        guard moving.count == ids.count else { return }   // one couldn't be moved (reported already)
        pages.removeAll { ids.contains($0.id) }
        let insertAt = targetID.flatMap { t in pages.firstIndex { $0.id == t } } ?? pages.count
        for k in moving.indices { moving[k].level = min(2, max(0, level) + relative[k]) }
        pages.insert(contentsOf: moving, at: insertAt)
        nb.sections[dest.sectionID]!.pages = normalizedLevels(pages)
        saveSection(nb, dest.sectionID)
    }
}

// MARK: - What's dragged

@MainActor
enum NotebookDrag {
    enum Item: Equatable {
        case page(PageRef)
        case node(SectionRef)
    }

    /// The drag in progress (from this window), for the drop targets' feedback while it's over them.
    static var current: Item?

    /// Starts a drag: the item's link, as text.
    static func provider(for item: Item) -> NSItemProvider {
        current = item
        let store = NotebookStore.shared
        let url = switch item {
        case .page(let ref): store.link(for: ref)
        case .node(let ref): store.sectionLink(ref)
        }
        return NSItemProvider(object: url.absoluteString as NSString)
    }

    /// The page or section a dropped link stands for.
    static func item(from string: String) -> Item? {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == NotebookStore.linkScheme else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch url.host() {
        case "page":
            return NotebookStore.shared.resolve(url).map(Item.page)
        case "section":
            guard parts.count >= 2, let nb = UUID(uuidString: parts[0]), let id = UUID(uuidString: parts[1]) else { return nil }
            return .node(SectionRef(notebookID: nb, sectionID: id))
        default:
            return nil
        }
    }

    static let types: [UTType] = [.plainText]

    /// Reads what was dropped, then acts on it.
    static func load(_ info: DropInfo, _ body: @escaping @MainActor @Sendable (Item) -> Void) -> Bool {
        guard let provider = info.itemProviders(for: types).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            let text = (object as? NSString).map { $0 as String } ?? ""
            Task { @MainActor in
                if let item = item(from: text) { body(item) }
                current = nil
            }
        }
        return true
    }

    // MARK: Where a drop goes (also what the drop targets show)

    /// Onto a section or group row in the sidebar: a page goes into a section; a section or group before or
    /// after the row (the upper or lower half), or into a group (its middle).
    static func sidebarDrop(_ item: Item, onto target: SectionRef, isGroup: Bool, y: CGFloat, height: CGFloat) -> NotebookStore.DropPosition? {
        let store = NotebookStore.shared
        switch item {
        case .page(let ref):
            return !isGroup && ref.section != target && store.canMovePage(ref, to: target, near: nil) ? .inside : nil
        case .node(let ref):
            let h = max(1, height)
            let position: NotebookStore.DropPosition = isGroup && y > h * 0.28 && y < h * 0.72 ? .inside : (y < h / 2 ? .before : .after)
            return store.canMoveNode(ref, to: target, position: position) ? position : nil
        }
    }

    /// Onto a page row: before or after it.
    static func pageDrop(_ item: Item, onto target: PageRef, y: CGFloat, height: CGFloat) -> NotebookStore.DropPosition? {
        guard case .page(let ref) = item, ref.pageID != target.pageID,
              NotebookStore.shared.canMovePage(ref, to: target.section, near: target.pageID) else { return nil }
        return y < max(1, height) / 2 ? .before : .after
    }

    static func performSidebarDrop(_ item: Item, onto target: SectionRef, position: NotebookStore.DropPosition) {
        let store = NotebookStore.shared
        switch item {
        case .page(let ref): store.movePageTree(ref, to: target, before: nil)
        case .node(let ref): store.moveNode(ref, to: target, position: position)
        }
    }

    static func performPageDrop(_ item: Item, onto target: PageRef, position: NotebookStore.DropPosition) {
        guard case .page(let ref) = item else { return }
        let store = NotebookStore.shared
        let level = store.meta(target)?.level ?? 0
        let before = position == .before ? target.pageID : store.page(after: target.pageID, in: target.section)
        store.movePageTree(ref, to: target.section, before: before, level: level)
    }
}

// MARK: - Drop targets

/// Where a drop would go, shown on the row: a line above or below, or the row highlighted.
private struct DropMark: View {
    let position: NotebookStore.DropPosition?

    var body: some View {
        GeometryReader { geo in
            switch position {
            case .before:
                Rectangle().fill(Color.accentColor).frame(height: 2).offset(y: -1)
            case .after:
                Rectangle().fill(Color.accentColor).frame(height: 2).offset(y: geo.size.height - 1)
            case .inside:
                RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.22))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.accentColor, lineWidth: 1.5))
            case nil:
                EmptyView()
            }
        }
        .allowsHitTesting(false)
    }
}

/// A row things can be dropped on.
private enum DropTarget: Sendable {
    case node(SectionRef, isGroup: Bool)
    case page(PageRef)

    var item: NotebookDrag.Item {
        switch self {
        case .node(let ref, _): .node(ref)
        case .page(let ref): .page(ref)
        }
    }

    @MainActor func position(_ item: NotebookDrag.Item, y: CGFloat, height: CGFloat) -> NotebookStore.DropPosition? {
        switch self {
        case .node(let ref, let isGroup): NotebookDrag.sidebarDrop(item, onto: ref, isGroup: isGroup, y: y, height: height)
        case .page(let ref): NotebookDrag.pageDrop(item, onto: ref, y: y, height: height)
        }
    }

    @MainActor func perform(_ item: NotebookDrag.Item, _ position: NotebookStore.DropPosition) {
        switch self {
        case .node(let ref, _): NotebookDrag.performSidebarDrop(item, onto: ref, position: position)
        case .page(let ref): NotebookDrag.performPageDrop(item, onto: ref, position: position)
        }
    }
}

private struct RowDropDelegate: DropDelegate {
    let target: DropTarget
    let height: CGFloat
    @Binding var mark: NotebookStore.DropPosition?

    private func where_(_ info: DropInfo) -> NotebookStore.DropPosition? {
        NotebookDrag.current.flatMap { target.position($0, y: info.location.y, height: height) }
    }

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: NotebookDrag.types) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let p = where_(info)
        if mark != p { mark = p }
        return DropProposal(operation: p == nil ? .forbidden : .move)
    }

    func dropExited(info: DropInfo) { mark = nil }

    func performDrop(info: DropInfo) -> Bool {
        let y = info.location.y, h = height, target = self.target
        mark = nil
        guard where_(info) != nil else { return false }
        return NotebookDrag.load(info) { item in
            // Worked out again from what was dropped (it might have come from another window).
            if let p = target.position(item, y: y, height: h) { target.perform(item, p) }
        }
    }
}

/// A row that can be dragged (as a page or section link) and dropped on.
private struct DragDropRow: ViewModifier {
    let target: DropTarget
    @State private var mark: NotebookStore.DropPosition?
    @State private var height: CGFloat = 24

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .onDrag { NotebookDrag.provider(for: target.item) }
            .onDrop(of: NotebookDrag.types, delegate: RowDropDelegate(target: target, height: height, mark: $mark))
            .overlay(DropMark(position: mark))
    }
}

extension View {
    /// A section or group row in the sidebar.
    func sidebarDragDrop(_ ref: SectionRef, isGroup: Bool) -> some View {
        modifier(DragDropRow(target: .node(ref, isGroup: isGroup)))
    }

    /// A page row in the pages list.
    func pageDragDrop(_ ref: PageRef) -> some View {
        modifier(DragDropRow(target: .page(ref)))
    }

    /// A notebook's name: a section or group dropped there goes last in the notebook (out of any group).
    func notebookDrop(_ notebookID: UUID) -> some View {
        modifier(NotebookDropTarget(notebookID: notebookID))
    }

    /// The empty part of a section's pages list: a page dropped there goes last.
    func pagesEndDrop(_ section: SectionRef) -> some View {
        onDrop(of: NotebookDrag.types, delegate: EndDropDelegate(section: section))
    }
}

private struct EndDropDelegate: DropDelegate {
    let section: SectionRef
    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: NotebookDrag.types) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard case .page(let ref)? = NotebookDrag.current, NotebookStore.shared.canMovePage(ref, to: section, near: nil) else { return DropProposal(operation: .forbidden) }
        return DropProposal(operation: .move)
    }
    func performDrop(info: DropInfo) -> Bool {
        let section = self.section
        return NotebookDrag.load(info) { item in
            if case .page(let ref) = item { NotebookStore.shared.movePageTree(ref, to: section, before: nil) }
        }
    }
}

private struct NotebookDropTarget: ViewModifier {
    let notebookID: UUID
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .onDrop(of: NotebookDrag.types, delegate: NotebookHeaderDropDelegate(notebookID: notebookID, targeted: $targeted))
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(targeted ? 0.22 : 0)))
    }
}

private struct NotebookHeaderDropDelegate: DropDelegate {
    let notebookID: UUID
    @Binding var targeted: Bool

    private var accepts: Bool {
        guard case .node(let ref)? = NotebookDrag.current else { return false }
        return ref.notebookID == notebookID
    }
    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: NotebookDrag.types) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        targeted = accepts
        return DropProposal(operation: accepts ? .move : .forbidden)
    }
    func dropExited(info: DropInfo) { targeted = false }
    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        guard accepts else { return false }
        let notebookID = self.notebookID
        return NotebookDrag.load(info) { item in
            if case .node(let ref) = item, ref.notebookID == notebookID { NotebookStore.shared.moveNode(ref, toGroup: nil) }
        }
    }
}
