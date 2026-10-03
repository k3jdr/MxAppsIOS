//
//  SidebarView.swift
//  MxNoteONE
//
//  Open notebooks, each with its sections and section groups. Right-click
//  a notebook, section or group for everything you can do with it.
//

import SwiftUI

struct SidebarView: View {
    @Bindable private var store = NotebookStore.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        List(selection: Binding(get: { store.sidebarSelection }, set: { store.selectSidebar($0) })) {
            ForEach(store.notebooks) { notebook in
                Section(isExpanded: expandedBinding(notebook.id)) {
                    OutlineGroup(notebook.manifest.sections, children: \.children) { node in
                        let ref = SectionRef(notebookID: notebook.id, sectionID: node.id)
                        SectionRow(notebook: notebook, node: node)
                            .tag(node.isGroup ? SidebarItem.group(ref) : SidebarItem.section(ref))
                    }
                } header: {
                    NotebookHeader(notebook: notebook)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 12) {
                Menu {
                    Button("New Section") { store.addSectionToCurrentNotebook() }
                    Button("New Section Group") {
                        if let nb = store.currentNotebook { store.addSectionGroup(to: nb.id) }
                    }
                    Divider()
                    Button("New Notebook…") { store.sheet = .newNotebook }
                    Button("Open Notebook…") { store.openNotebookPanel() }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("New section, section group or notebook")
                Spacer()
                Button {
                    openWindow(id: "tags")
                } label: {
                    Image(systemName: "tag")
                }
                .buttonStyle(.borderless)
                .help("Tag Summary")
                Button {
                    store.recycleBinNotebookID = store.currentNotebook?.id
                    openWindow(id: "trash")
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Recycle Bin")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func expandedBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { store.expandedNotebooks.contains(id) },
            set: { expanded in
                if expanded { store.expandedNotebooks.insert(id) } else { store.expandedNotebooks.remove(id) }
            })
    }
}

struct NotebookHeader: View {
    let notebook: Notebook
    @Bindable private var store = NotebookStore.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "book.closed.fill")
                .foregroundStyle(notebook.manifest.color.color)
            Text(notebook.name)
                .lineLimit(1)
        }
        .contextMenu {
            Button("New Section") { store.addSection(to: notebook.id) }
            Button("New Section Group") { store.addSectionGroup(to: notebook.id) }
            Divider()
            Button("Rename Notebook…") { store.sheet = .renameNotebook(notebook.id) }
            Menu("Notebook Color") {
                ForEach(NoteColor.allCases) { color in
                    Button {
                        store.setNotebookColor(notebook.id, color)
                    } label: {
                        Label { Text(color.title) } icon: { Image(nsImage: Palette.swatch(color.nsColor)) }
                    }
                }
            }
            Button("Show in Finder") { store.showInFinder(notebook.id) }
            Button("Recycle Bin") {
                store.recycleBinNotebookID = notebook.id
                openWindow(id: "trash")
            }
            Divider()
            Button("Close Notebook") { store.closeNotebook(notebook.id) }
        }
    }
}

struct SectionRow: View {
    let notebook: Notebook
    let node: SectionNode
    @Bindable private var store = NotebookStore.shared

    private var ref: SectionRef { SectionRef(notebookID: notebook.id, sectionID: node.id) }

    var body: some View {
        Label {
            HStack(spacing: 4) {
                Text(node.name).lineLimit(1)
                Spacer(minLength: 0)
                if node.isProtected {
                    Image(systemName: store.isLocked(ref) ? "lock.fill" : "lock.open")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            if node.isGroup {
                Image(systemName: "folder.fill").foregroundStyle(node.color.color)
            } else {
                RoundedRectangle(cornerRadius: 3)
                    .fill(node.color.color)
                    .frame(width: 11, height: 15)
            }
        }
        .contextMenu { menu }
    }

    @ViewBuilder private var menu: some View {
        if node.isGroup {
            Button("New Section in Group") { store.addSection(to: notebook.id, inGroup: node.id) }
            Button("New Section Group in Group") { store.addSectionGroup(to: notebook.id, inGroup: node.id) }
            Divider()
            Button("Rename Section Group…") { store.sheet = .renameNode(ref) }
        } else {
            Button("New Page") {
                store.selectSidebar(.section(ref))
                store.addPageToCurrentSection()
            }
            Divider()
            Button("Rename Section…") { store.sheet = .renameNode(ref) }
        }
        Menu(node.isGroup ? "Group Color" : "Section Color") {
            ForEach(NoteColor.allCases) { color in
                Button {
                    store.setColor(ref, color)
                } label: {
                    Label { Text(color.title) } icon: { Image(nsImage: Palette.swatch(color.nsColor)) }
                }
            }
        }
        if !node.isGroup {
            Divider()
            if node.isProtected {
                if store.isLocked(ref) {
                    Button("Unlock Section…") { store.sheet = .password(ref, .unlock) }
                } else {
                    Button("Lock Section") { store.lock(ref) }
                    Button("Change Password…") { store.sheet = .password(ref, .change) }
                    Button("Remove Password…") { store.sheet = .password(ref, .remove) }
                }
            } else {
                Button("Password Protect Section…") { store.sheet = .password(ref, .set) }
            }
        }
        Divider()
        Button("Move Up") { store.moveNode(ref, by: -1) }
        Button("Move Down") { store.moveNode(ref, by: 1) }
        Menu("Move to Group") {
            Button("Top Level of Notebook") { store.moveNode(ref, toGroup: nil) }
            let groups = notebook.manifest.sections.flattenedGroups.filter {
                $0.id != node.id && node.children?.find($0.id) == nil
            }
            if !groups.isEmpty { Divider() }
            ForEach(groups) { group in
                Button(group.name) { store.moveNode(ref, toGroup: group.id) }
            }
        }
        if !node.isGroup {
            Divider()
            Button("Export Section as PDF…") { PageExporter.exportSectionPDF(ref) }
                .disabled(store.isLocked(ref))
        }
        Divider()
        Button(node.isGroup ? "Delete Section Group" : "Delete Section", role: .destructive) {
            store.deleteNode(ref)
        }
    }
}
