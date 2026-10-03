//
//  ToolWindows.swift
//  MxNoteONE
//
//  Tag Summary (tagged notes from all open notebooks) and the Recycle Bin.
//

import SwiftUI

struct TagSummaryView: View {
    enum Grouping: String, CaseIterable, Identifiable {
        case tag = "Tag Name", section = "Section", page = "Page"
        var id: String { rawValue }
    }

    @Bindable private var store = NotebookStore.shared
    @Environment(\.openWindow) private var openWindow
    @State private var grouping: Grouping = .tag
    @State private var kind: TagKind?
    @State private var hideDone = false
    @State private var query = ""

    private var hits: [TagHit] {
        store.allTags().filter { hit in
            (kind == nil || hit.item.kind == kind)
                && !(hideDone && hit.item.done)
                && (query.isEmpty || hit.item.text.localizedCaseInsensitiveContains(query)
                    || hit.pageTitle.localizedCaseInsensitiveContains(query))
        }
    }

    private var groups: [(String, [TagHit])] {
        let hits = hits
        switch grouping {
        case .tag:
            return TagKind.allCases.compactMap { kind in
                let items = hits.filter { $0.item.kind == kind }
                return items.isEmpty ? nil : ("\(kind.symbol)  \(kind.title)", items)
            }
        case .section:
            return Dictionary(grouping: hits, by: \.location).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        case .page:
            return Dictionary(grouping: hits, by: { $0.pageTitle + " — " + $0.location })
                .sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        }
    }

    var body: some View {
        let groups = groups
        List {
            ForEach(groups, id: \.0) { title, items in
                Section(title) {
                    ForEach(items) { hit in
                        Button {
                            openWindow(id: "main")
                            store.open(hit.ref, find: hit.item.text.isEmpty ? nil : String(hit.item.text.prefix(60)))
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(hit.item.kind == .todo ? (hit.item.done ? TagKind.todoDone : TagKind.todo.symbol) : hit.item.kind.symbol)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(hit.item.text.isEmpty ? "(no text)" : hit.item.text)
                                        .strikethrough(hit.item.done)
                                        .foregroundStyle(hit.item.done ? .secondary : .primary)
                                    Text("\(hit.pageTitle) — \(hit.location)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .overlay {
            if groups.isEmpty {
                ContentUnavailableView("No Tagged Notes", systemImage: "tag",
                                       description: Text("Tag a paragraph with ⌘1 – ⌘9 and it shows up here."))
            }
        }
        .searchable(text: $query, prompt: "Filter")
        .toolbar {
            ToolbarItemGroup {
                Picker("Group By", selection: $grouping) {
                    ForEach(Grouping.allCases) { Text($0.rawValue).tag($0) }
                }
                .help("Group by")
                Picker("Tag", selection: $kind) {
                    Text("All Tags").tag(TagKind?.none)
                    Divider()
                    ForEach(TagKind.allCases) { Text("\($0.symbol) \($0.title)").tag(Optional($0)) }
                }
                Toggle("Hide Completed", isOn: $hideDone)
            }
        }
        .navigationTitle("Tag Summary")
        .frame(minWidth: 480, minHeight: 320)
    }
}

struct RecycleBinView: View {
    @Bindable private var store = NotebookStore.shared
    @State private var selection: Set<UUID> = []
    @State private var confirmEmpty = false
    @State private var confirmDelete = false

    private var notebook: Notebook? {
        store.notebook(store.recycleBinNotebookID) ?? store.notebooks.first
    }

    var body: some View {
        let items = notebook?.manifest.trash ?? []
        VStack(spacing: 0) {
            Table(items, selection: $selection) {
                TableColumn("Name") { item in
                    Label(item.name, systemImage: item.kind == .page ? "doc.text" : "rectangle.stack")
                }
                TableColumn("From") { item in
                    Text(item.kind == .page ? item.fromSectionName : (item.section?.isGroup == true ? "Section group" : "Section"))
                        .foregroundStyle(.secondary)
                }
                TableColumn("Deleted") { item in
                    Text(item.deleted.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(.secondary)
                }
                .width(150)
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                Button("Restore") { restore(ids) }
                Button("Delete Permanently", role: .destructive) {
                    selection = ids
                    confirmDelete = true
                }
            } primaryAction: { ids in
                restore(ids)
            }
            Divider()
            HStack {
                Text("Items are deleted permanently after 60 days.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Restore") { restore(selection) }
                    .disabled(selection.isEmpty)
                Button("Delete") { confirmDelete = true }
                    .disabled(selection.isEmpty)
                Button("Empty Recycle Bin") { confirmEmpty = true }
                    .disabled(items.isEmpty)
            }
            .padding(10)
        }
        .toolbar {
            ToolbarItem {
                Picker("Notebook", selection: Binding(get: { notebook?.id }, set: { store.recycleBinNotebookID = $0 })) {
                    ForEach(store.notebooks) { Text($0.name).tag(Optional($0.id)) }
                }
            }
        }
        .navigationTitle("Recycle Bin")
        .confirmationDialog("Delete the selected items permanently?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                guard let notebook else { return }
                for item in notebook.manifest.trash where selection.contains(item.id) {
                    store.deletePermanently(item, in: notebook)
                }
                selection = []
            }
        } message: {
            Text("This can't be undone.")
        }
        .confirmationDialog("Empty the Recycle Bin?", isPresented: $confirmEmpty) {
            Button("Empty", role: .destructive) {
                if let notebook { store.emptyTrash(notebook) }
                selection = []
            }
        } message: {
            Text("Everything in this notebook's Recycle Bin is deleted permanently.")
        }
        .frame(minWidth: 560, minHeight: 300)
    }

    private func restore(_ ids: Set<UUID>) {
        guard let notebook else { return }
        for item in notebook.manifest.trash where ids.contains(item.id) {
            store.restore(item, in: notebook)
        }
        selection = []
    }
}
