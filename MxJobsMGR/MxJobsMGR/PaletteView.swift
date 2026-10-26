//
//  PaletteView.swift
//  MxJobsMGR
//
//  The sidebar: node kinds grouped by layer. Drag one onto the canvas, or double-click
//  it to add it at the end of its lane. Right-click an element to rename it or give it a link,
//  a layer's header to give it a link (PaletteEdits.swift).
//

import SwiftUI

struct PaletteView: View {
    var editor: EditorState
    @Environment(\.openWindow) private var openWindow
    @State private var running: [String: Bool] = [:]
    /// The selected element (Return edits it).
    @State private var selection: PaletteItem?
    /// A click on a row selects it without focusing the list (the row is draggable); focus it so Return reaches it.
    @FocusState private var focused: Bool
    /// Edit Element… is open for this element, the Link dialog for this item (PaletteEdits.swift).
    @State private var editingElement: NodeKind?
    @State private var editingLink: PaletteItem?

    private var edits: PaletteEdits { .shared }

    var body: some View {
        List(selection: $selection) {
            ForEach(Layer.allCases) { layer in
                Section {
                    ForEach(NodeKind.kinds(in: layer)) { kind in
                        PaletteRow(kind: kind, linked: edits.link(.kind(kind)) != nil)
                            .paletteLink(.kind(kind)) { editingLink = .kind(kind) }
                            .draggable(kind.rawValue) {
                                Label(edits.title(kind), systemImage: kind.symbol)
                                    .padding(8)
                                    .background(kind.color.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
                            }
                            // Simultaneous, so a single click still selects the row.
                            .simultaneousGesture(TapGesture(count: 2).onEnded { editor.add(kind) })
                            .contextMenu {
                                Button("Add to Layer \(layer.rawValue)") { editor.add(kind) }
                                Divider()
                                Button("Edit Element…") { editingElement = kind }
                                if edits.isEdited(kind) {
                                    Button("Reset to \(kind.title)") { edits.reset(kind) }
                                }
                                Divider()
                                paletteLinkMenu(.kind(kind)) { editingLink = .kind(kind) }
                            }
                            .quickHelpArea(JobsHelp.paletteKind(kind))
                            .tag(PaletteItem.kind(kind))
                    }
                } header: {
                    Text("Layer \(layer.rawValue) · \(layer.title)")
                        .foregroundStyle(layer.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .paletteLink(.layer(layer)) { editingLink = .layer(layer) }
                        .contextMenu { paletteLinkMenu(.layer(layer)) { editingLink = .layer(layer) } }
                        .quickHelpArea(JobsHelp.paletteLayer(layer))
                }
            }

            // The shared Layer 3 services (Services/): what each is for, and a step for it on double-click.
            Section {
                ForEach(ServiceCatalog.all) { service in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(running[service.id] == true ? Color.green : Color.secondary.opacity(0.4))
                            .frame(width: 7, height: 7)
                            .padding(.top, 5)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Text(service.name)
                                Text(service.language).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            }
                            Text(service.cases.map(\.title).joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { editor.addServiceStep(service, nil) }
                    .contextMenu {
                        ForEach(service.endpoints, id: \.self) { endpoint in
                            Button("Add Step: \(endpoint.method) \(endpoint.path)") { editor.addServiceStep(service, endpoint) }
                        }
                        Divider()
                        Button("About \(service.name)…") { openWindow(id: "services") }
                    }
                    .help(service.purpose + "\n\nDouble-click to add a step; right-click for each endpoint.")
                    .quickHelpArea(JobsHelp.paletteService(service, running: running[service.id] == true))
                }
                Button("Layer 3 Services…") { openWindow(id: "services") }
                    .quickHelp("Layer 3 Services…", JobsHelp.services.detail, shortcut: "⌥⌘L")
                Button("New from Sample…") { openWindow(id: "samples") }
                    .quickHelp("New from Sample…", JobsHelp.samples.detail, shortcut: "⌥⌘N")
            } header: {
                Text("Layer 3 Services").foregroundStyle(Layer.data.color)
            }
        }
        .listStyle(.sidebar)
        .focused($focused)
        .onChange(of: selection) { if selection != nil { focused = true } }
        .onKeyPress(.return) {
            guard case .kind(let kind) = selection else { return .ignored }
            editingElement = kind
            return .handled
        }
        .sheet(item: $editingElement) { PaletteElementSheet(kind: $0) }
        .sheet(item: $editingLink) { PaletteLinkSheet(item: $0) }
        .quickHelpArea(JobsHelp.palette)
        .task { running = await ServiceCatalog.probeAll() }
    }
}

private struct PaletteRow: View {
    var kind: NodeKind
    /// Has a link: its mark sits at the trailing edge, and its hover card takes the place of the tooltip.
    var linked: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: kind.symbol)
                .foregroundStyle(kind.color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(PaletteEdits.shared.title(kind))
                Text(PaletteEdits.shared.summary(kind))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.trailing, linked ? 16 : 0)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .help(linked ? "" : "Drag onto the canvas, or double-click to add; right-click to edit it or give it a link")
    }
}
