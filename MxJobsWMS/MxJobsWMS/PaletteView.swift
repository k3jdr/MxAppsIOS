//
//  PaletteView.swift
//  MxJobsWMS
//
//  The sidebar: node kinds grouped by layer. Drag one onto the canvas, or double-click
//  it to add it at the end of its lane.
//

import SwiftUI

struct PaletteView: View {
    var editor: EditorState

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
                    }
                } header: {
                    Text("Layer \(layer.rawValue) · \(layer.title)")
                        .foregroundStyle(layer.color)
                }
            }
        }
        .listStyle(.sidebar)
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
