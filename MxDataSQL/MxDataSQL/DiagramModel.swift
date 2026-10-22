//
//  DiagramModel.swift
//  MxDataSQL
//
//  A Diagram window's state: the diagram (the shared DBML library's — Shared/DBML, as in MxNoteONE:
//  the DBML, where each table and note is, how each relationship is drawn), what is selected, and
//  saving it all back into the .dbml file. Exporting a schema writes it to a .dbml file of its own.
//

import AppKit
import SwiftUI

@MainActor
@Observable
final class DiagramModel {
    var diagram: DBMLDiagram
    var selection = DBMLSelection()
    var fileURL: URL?
    var zoom: Double
    var dirty = false
    var errorMessage: String?
    var infoMessage: String?
    /// A note to start typing in (the canvas takes it).
    var editNoteRequest: String?
    /// What the scroll view shows, in zoomed coordinates (for Add Note).
    var visibleRect = CGRect.zero
    /// Keeps the window's close prompt alive (see DiagramWindow.swift).
    @ObservationIgnored var closeGuard: AnyObject?
    /// Shows unsaved changes in the close button, as documents do.
    @ObservationIgnored weak var window: NSWindow?

    init(diagram: DBMLDiagram, fileURL: URL?) {
        var d = diagram
        d.placeMissing()
        self.diagram = d
        self.fileURL = fileURL
        self.zoom = d.zoom ?? 1
    }

    /// A .dbml file's diagram: its DBML, notes and layout.
    convenience init(fileText: String, fileURL: URL?) {
        self.init(diagram: DBMLDiagram(fileText: fileText), fileURL: fileURL)
    }

    var title: String { fileURL?.lastPathComponent ?? "Untitled.dbml" }
    var schema: DBMLSchema { diagram.schema }

    // MARK: Relationships

    var selectedRef: DBMLSchema.Ref? { selection.ref.flatMap { id in schema.refs.first { $0.id == id } } }

    func setStyle(_ style: DBMLCurveStyle, for refID: String) {
        diagram.setStyle(style, for: refID)
        changed()
    }

    func refs(touching table: String) -> Int {
        schema.refs.filter { $0.from.table == table || $0.to.table == table }.count
    }

    // MARK: Notes

    func addNote(at point: CGPoint) {
        let id = diagram.addNote(at: point, text: "Note")
        selection = DBMLSelection(note: id)
        editNoteRequest = id
        changed()
    }

    func addNoteAtVisibleCenter() {
        let z = max(zoom, 0.01)
        let center = visibleRect.isEmpty ? CGPoint(x: 200, y: 200)
            : CGPoint(x: visibleRect.midX / z - 110, y: visibleRect.midY / z - 60)
        addNote(at: center)
    }

    // MARK: Arrangement

    /// The tables arranged by schema, related tables together (resets curves).
    func autoArrange() {
        diagram.arrange()
        changed()
    }

    // MARK: Saving

    func changed() {
        dirty = true
        window?.isDocumentEdited = true
    }

    /// Writes the diagram (notes and layout) back into the file; the rest of the file is kept as is.
    func save() -> Bool {
        guard let url = fileURL else { return saveAs() }
        diagram.zoom = zoom
        do {
            try diagram.fileText().write(to: url, atomically: true, encoding: .utf8)
            dirty = false
            window?.isDocumentEdited = false
            infoMessage = "Saved \(url.lastPathComponent)"
            return true
        } catch {
            errorMessage = "Could not save \(url.lastPathComponent): \(error.localizedDescription)"
            return false
        }
    }

    func saveAs() -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [DBMLFile.type]
        panel.nameFieldStringValue = fileURL?.lastPathComponent ?? "diagram.dbml"
        panel.title = "Save Diagram As"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        fileURL = url
        return save()
    }

    // MARK: Schemas

    /// A schema to a .dbml file of its own: its tables and enums, the relationships among them, its table group,
    /// and where they sit (with their curves and the notes over them).
    func exportSchema(_ name: String) {
        exportSchema(diagram.subset(schema: name, from: fileURL?.deletingPathExtension().lastPathComponent), schema: name)
    }

    func exportSchema(_ part: DBMLDiagram, schema name: String) {
        let panel = NSSavePanel()
        panel.title = "Export Schema"
        panel.message = "Where to write the \(name) schema as a .dbml file of its own (with its layout and notes)."
        panel.prompt = "Export"
        panel.allowedContentTypes = [DBMLFile.type]
        let base = fileURL?.deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = (base.map { $0 + "-" } ?? "") + name + ".dbml"
        panel.canCreateDirectories = true
        let write: (URL) -> Void = { [weak self] url in
            var part = part
            part.zoom = self?.zoom
            do {
                try part.fileText().write(to: url, atomically: true, encoding: .utf8)
                let tables = part.schema.tables.count
                self?.infoMessage = "Exported \(name) to \(url.lastPathComponent): \(tables) table\(tables == 1 ? "" : "s")"
            } catch {
                self?.errorMessage = "Could not export \(name): \(error.localizedDescription)"
            }
        }
        if let window {
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let url = panel.url { write(url) }
            }
        } else if panel.runModal() == .OK, let url = panel.url {
            write(url)
        }
    }
}
