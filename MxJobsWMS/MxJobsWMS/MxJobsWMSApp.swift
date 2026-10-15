//
//  MxJobsWMSApp.swift
//  MxJobsWMS
//
//  Document-based app: each window is a jobspace (*.jobspace JSON) describing a
//  three-layer financial data gathering operation. DocumentGroup provides the
//  File menu (New, Open, Open Recent, Save, Save As, Duplicate, Rename, Revert);
//  JobspaceCommands adds New Sample Jobspace, Export, and the Diagram menu.
//

import SwiftUI
import UniformTypeIdentifiers

@main
struct MxJobsWMSApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: JobspaceDocument()) { file in
            ContentView(document: file.$document)
        }
        .defaultSize(width: 1560, height: 920)
        .commands {
            JobspaceCommands()
        }
    }
}

struct JobspaceCommands: Commands {
    @FocusedValue(\.editor) private var editor
    @Environment(\.newDocument) private var newDocument

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Sample Jobspace") {
                newDocument(JobspaceDocument(space: .sample()))
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
        }
        CommandGroup(after: .importExport) {
            Button("Export Diagram as PNG…") {
                if let editor { DiagramExport.exportPNG(editor: editor) }
            }
            .disabled(editor == nil)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Duplicate Nodes") { editor?.duplicateSelection() }
                .keyboardShortcut("d")
                .disabled(editor?.selectedNodes.isEmpty ?? true)
            Button("Delete Selection") { editor?.deleteSelection() }
                .disabled(!(editor?.hasSelection ?? false))
            Button("Select All Nodes") { editor?.selectAll() }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(editor == nil)
        }
        CommandMenu("Diagram") {
            Menu("Add Node") {
                ForEach(Layer.allCases) { layer in
                    Section("Layer \(layer.rawValue) · \(layer.title)") {
                        ForEach(NodeKind.kinds(in: layer)) { kind in
                            Button(kind.title) { editor?.add(kind) }
                        }
                    }
                }
            }
            .disabled(editor == nil)
            Divider()
            Button("Zoom In") { editor?.zoomIn() }
                .keyboardShortcut("+")
                .disabled(editor == nil)
            Button("Zoom Out") { editor?.zoomOut() }
                .keyboardShortcut("-")
                .disabled(editor == nil)
            Button("Actual Size") { editor?.zoom = 1 }
                .keyboardShortcut("0")
                .disabled(editor == nil)
            Divider()
            Button("Show Problems") { editor?.showIssues = true }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(editor == nil)
            Button("API Subscriptions…") { editor?.showSubscriptions = true }
                .keyboardShortcut("k", modifiers: [.command, .option])
                .disabled(editor == nil)
            Button(editor?.showInspector == true ? "Hide Inspector" : "Show Inspector") {
                editor?.showInspector.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(editor == nil)
        }
    }
}

enum DiagramExport {
    /// Renders the whole diagram (no selection) to a PNG chosen with a save panel.
    static func exportPNG(editor: EditorState) {
        guard let space = editor.document?.wrappedValue.space else { return }
        let size = Metrics.canvasSize(for: space)
        let content = DiagramContent(
            space: space, selectedNodes: [], selectedLink: nil, issues: [], size: size,
            position: { CGPoint(x: $0.x, y: $0.y) }, dropTargetLayer: nil, rubberBand: nil,
            nodeGesture: { _ in TapGesture() }, handleGesture: { _ in TapGesture() }, onNodeTap: { _ in },
            interactive: false)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(space.name).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? png.write(to: url)
    }
}
