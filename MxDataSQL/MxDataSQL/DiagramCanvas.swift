//
//  DiagramCanvas.swift
//  MxDataSQL
//
//  The drawing in a Diagram window: the shared DBML canvas (Shared/DBML — the same as in MxNoteONE)
//  in a scroll view. Tables (several at once, or a whole schema) and notes are moved by dragging, a
//  relationship's curve is picked and its control points dragged, a note is resized from its corner
//  and edited with a double-click; double-clicking empty canvas adds a note. Right-click a schema to
//  select it, copy it, or export it to a .dbml file of its own.
//

import AppKit
import SwiftUI

struct DiagramCanvas: NSViewRepresentable {
    @Bindable var model: DiagramModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.borderType = .noBorder
        let canvas = DBMLCanvasView(diagram: model.diagram)
        canvas.host = context.coordinator
        canvas.zoom = CGFloat(model.zoom)
        scroll.documentView = canvas
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.scrolled(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        context.coordinator.canvas = canvas
        context.coordinator.scroll = scroll
        context.coordinator.resize()
        DispatchQueue.main.async { scroll.window?.makeFirstResponder(canvas) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.model = model
        guard let canvas = c.canvas else { return }
        if canvas.diagram != model.diagram { canvas.diagram = model.diagram }
        if abs(canvas.zoom - CGFloat(model.zoom)) > 0.0001 { canvas.zoom = CGFloat(model.zoom) }
        if canvas.selection != model.selection { canvas.selection = model.selection }
        if let id = model.editNoteRequest {
            DispatchQueue.main.async {
                model.editNoteRequest = nil
                canvas.editNote(id)
            }
        }
        c.resize()
    }

    final class Coordinator: NSObject, DBMLCanvasHost {
        var model: DiagramModel
        weak var canvas: DBMLCanvasView?
        weak var scroll: NSScrollView?

        init(model: DiagramModel) { self.model = model }

        /// The canvas: everything plus a margin, at least a screenful.
        func resize() {
            guard let canvas, let scroll else { return }
            let z = canvas.zoom
            let size = canvas.contentSize(margin: 400, minimum: CGSize(width: max(1200 * z, scroll.contentSize.width),
                                                                       height: max(800 * z, scroll.contentSize.height)))
            if canvas.frame.size != size { canvas.setFrameSize(size) }
        }

        @objc func scrolled(_ note: Notification) {
            if let scroll { model.visibleRect = scroll.contentView.bounds }
        }

        func canvas(_ canvas: DBMLCanvasView, didChange old: DBMLDiagram, name: String) {
            model.diagram = canvas.diagram
            model.changed()
            resize()
        }

        func canvasDidChangeLive(_ canvas: DBMLCanvasView) {
            model.diagram = canvas.diagram
            resize()
        }

        func canvasSelectionDidChange(_ canvas: DBMLCanvasView) {
            if model.selection != canvas.selection { model.selection = canvas.selection }
        }

        var schemaExportTitle: String { "Export Schema…" }

        var diagramTitle: String? { model.fileURL?.deletingPathExtension().lastPathComponent }

        func canvas(_ canvas: DBMLCanvasView, export part: DBMLDiagram, schema: String) {
            model.exportSchema(part, schema: schema)
        }

        func canvasMenuItems(_ canvas: DBMLCanvasView, at point: CGPoint, hit: DBMLHit?) -> [NSMenuItem] {
            [DBMLMenuItem("Save Diagram") { [weak self] in _ = self?.model.save() }]
        }
    }
}
