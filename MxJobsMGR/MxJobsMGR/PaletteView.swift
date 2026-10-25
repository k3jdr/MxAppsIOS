//
//  PaletteView.swift
//  MxJobsMGR
//
//  The sidebar: node kinds grouped by layer. Drag one onto the canvas, or double-click
//  it to add it at the end of its lane.
//

import SwiftUI

struct PaletteView: View {
    var editor: EditorState
    @Environment(\.openWindow) private var openWindow
    @State private var running: [String: Bool] = [:]

    var body: some View {
        List {
            ForEach(Layer.allCases) { layer in
                Section {
                    ForEach(NodeKind.kinds(in: layer)) { kind in
                        PaletteRow(kind: kind)
                            .draggable(kind.rawValue) {
                                Label(kind.title, systemImage: kind.symbol)
                                    .padding(8)
                                    .background(kind.color.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
                            }
                            .onTapGesture(count: 2) { editor.add(kind) }
                            .contextMenu {
                                Button("Add to Layer \(layer.rawValue)") { editor.add(kind) }
                            }
                            .quickHelpArea(JobsHelp.paletteKind(kind))
                    }
                } header: {
                    Text("Layer \(layer.rawValue) · \(layer.title)")
                        .foregroundStyle(layer.color)
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
        .quickHelpArea(JobsHelp.palette)
        .task { running = await ServiceCatalog.probeAll() }
    }
}

private struct PaletteRow: View {
    var kind: NodeKind
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: kind.symbol)
                .foregroundStyle(kind.color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.title)
                Text(kind.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .help("Drag onto the canvas, or double-click to add")
    }
}
