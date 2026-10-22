//
//  DiagramWindow.swift
//  MxDataSQL
//
//  A Diagram window (Diagram ▸ Write DBML / Open DBML): the canvas (the shared DBML canvas, as in
//  MxNoteONE), a toolbar (relationship curve, add note, arrange, zoom, save) and a status line.
//  Closing it with unsaved changes asks whether to save them into the .dbml file.
//

import AppKit
import SwiftUI

struct DiagramWindowView: View {
    let id: DiagramWindowID?
    @State private var model: DiagramModel?

    var body: some View {
        Group {
            if let model {
                DiagramContent(model: model)
            } else {
                ContentUnavailableView("No Diagram", systemImage: "rectangle.connected.to.line.below",
                                       description: Text("Open a .dbml file with Diagram ▸ Open DBML…"))
                    .frame(minWidth: 500, minHeight: 300)
            }
        }
        .onAppear {
            if model == nil, let id { model = DiagramWindows.take(id) }
        }
    }
}

private struct DiagramContent: View {
    @Bindable var model: DiagramModel

    var body: some View {
        VStack(spacing: 0) {
            DiagramCanvas(model: model)
            Divider()
            statusLine
        }
        .frame(minWidth: 760, minHeight: 480)
        .navigationTitle(model.title)
        .focusedSceneValue(\.diagramModel, model)
        .background(WindowAccessor { window in DiagramCloseGuard.install(on: window, model: model) })
        .toolbar { toolbar }
        .alert("Diagram", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var selectedRef: DBMLSchema.Ref? { model.selectedRef }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("Curve", selection: Binding(
                get: { selectedRef.map { model.diagram.style($0) } ?? .automatic },
                set: { style in if let ref = selectedRef { model.setStyle(style, for: ref.id) } })
            ) {
                ForEach(DBMLCurveStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .disabled(selectedRef == nil)
            .help(selectedRef == nil
                  ? "Select a relationship to change its curve"
                  : "How the selected relationship is drawn; Bézier curves show control points to drag")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Add Note", systemImage: "note.text.badge.plus") { model.addNoteAtVisibleCenter() }
                .help("Add a sticky note (or double-click empty canvas)")
            Button("Arrange", systemImage: "square.grid.3x2") { model.autoArrange() }
                .help("Arrange the tables by schema, related tables together (resets curves). Right-click a schema to select, copy or export it.")
            Button("Zoom Out", systemImage: "minus.magnifyingglass") { model.zoom = max(0.2, model.zoom / 1.25) }
            Text("\(Int((model.zoom * 100).rounded()))%")
                .monospacedDigit()
                .frame(minWidth: 44)
                .onTapGesture { model.zoom = 1 }
                .help("Click for 100%")
            Button("Zoom In", systemImage: "plus.magnifyingglass") { model.zoom = min(3, model.zoom * 1.25) }
            Button("Save", systemImage: "square.and.arrow.down") { _ = model.save() }
                .keyboardShortcut("s", modifiers: .command)
                .help("Save the notes and layout into \(model.title)")
        }
    }

    private var statusLine: some View {
        HStack(spacing: 10) {
            Text("\(model.schema.tables.count) tables · \(model.schema.refs.count) relationships · \(model.diagram.notes.count + model.schema.notes.count) notes")
            if let selection = selectionText { Text("— \(selection)").foregroundStyle(.secondary).lineLimit(1) }
            Spacer()
            if model.dirty { Text("Edited").foregroundStyle(.secondary) }
            else if let info = model.infoMessage { Text(info).foregroundStyle(.secondary) }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var selectionText: String? {
        let s = model.selection
        if s.tables.count == 1, let id = s.tables.first {
            let n = model.refs(touching: id)
            return "\(id): \(model.schema.table(id)?.columns.count ?? 0) columns, \(n) relationship\(n == 1 ? "" : "s")"
        }
        if s.tables.count > 1 { return "\(s.tables.count) tables selected (drag one to move them all)" }
        if let r = model.selectedRef { return "\(r.text) (\(model.diagram.style(r).title))" }
        if let id = s.note { return "note \(id)" }
        return "Drag tables and notes; click a relationship to reshape it; double-click empty space for a note; right-click a schema to select, copy or export it"
    }
}

/// Calls back with the hosting NSWindow once the view is in one.
struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = AccessorView()
        view.onWindow = onWindow
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class AccessorView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}

/// Stands in front of SwiftUI's window delegate to ask about unsaved changes before closing,
/// and forwards every other delegate message to it.
final class DiagramCloseGuard: NSObject, NSWindowDelegate {
    weak var model: DiagramModel?
    weak var original: NSWindowDelegate?

    static func install(on window: NSWindow, model: DiagramModel) {
        guard !(window.delegate is DiagramCloseGuard) else { return }
        let guardian = DiagramCloseGuard()
        guardian.model = model
        guardian.original = window.delegate
        model.closeGuard = guardian
        window.delegate = guardian
        model.window = window
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let model, model.dirty {
            let alert = NSAlert()
            alert.messageText = "Save the diagram changes to \(model.title)?"
            alert.informativeText = "Table positions, curves and notes are saved into the .dbml file."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Don't Save")
            switch alert.runModal() {
            case .alertFirstButtonReturn: if !model.save() { return false }
            case .alertSecondButtonReturn: return false
            default: break
            }
        }
        return original?.windowShouldClose?(sender) ?? true
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        original?.responds(to: aSelector) == true ? original : super.forwardingTarget(for: aSelector)
    }
}
