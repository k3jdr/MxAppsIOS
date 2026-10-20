//
//  NotebookDragDrop.swift
//  MxNoteONE
//
//  The moves behind drag and drop in the sidebar and the pages list (NotebookOutlines.swift has the lists): sections
//  and groups to a new place or into a group; pages to a new place, or onto a section in any notebook, their
//  subpages with them.
//

import AppKit

extension NotebookStore {
    enum DropPosition: Equatable { case before, after, inside }

    /// Whether a section or group can go there (the same notebook; not into itself or a group inside it).
    func canMoveNode(_ ref: SectionRef, to target: SectionRef, position: DropPosition) -> Bool {
        guard ref.notebookID == target.notebookID, ref.sectionID != target.sectionID, let nb = notebook(ref.notebookID),
              let node = nb.manifest.sections.find(ref.sectionID), let t = nb.manifest.sections.find(target.sectionID),
              node.children?.find(target.sectionID) == nil else { return false }
        return position == .inside ? t.isGroup : true
    }

    /// A section or group into a group (nil: the notebook's top level) at a position among its new siblings —
    /// as the sidebar's outline reports a drop.
    func moveNode(_ ref: SectionRef, toGroup groupID: UUID?, at index: Int) {
        guard let nb = notebook(ref.notebookID), let node = nb.manifest.sections.find(ref.sectionID) else { return }
        if let groupID, groupID == node.id || node.children?.find(groupID) != nil { return NSSound.beep() }
        if let groupID, nb.manifest.sections.find(groupID)?.isGroup != true { return NSSound.beep() }
        // The position once the node is out of its old place (moving down among the same siblings).
        let oldParent = nb.manifest.sections.parentGroup(of: ref.sectionID)?.id
        let siblings = groupID.flatMap { nb.manifest.sections.find($0)?.children } ?? nb.manifest.sections
        var i = index
        if oldParent == groupID, let old = siblings.firstIndex(where: { $0.id == ref.sectionID }), old < index { i -= 1 }
        guard let removed = nb.manifest.sections.removeNode(ref.sectionID) else { return }
        if let groupID {
            nb.manifest.sections.modify(groupID) { g in
                var kids = g.children ?? []
                kids.insert(removed, at: min(max(0, i), kids.count))
                g.children = kids
            }
            expandedGroups.insert(groupID)
        } else {
            nb.manifest.sections.insert(removed, at: min(max(0, i), nb.manifest.sections.count))
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
