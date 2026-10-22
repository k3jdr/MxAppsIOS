//
//  DiagramCommands.swift
//  MxDataSQL
//
//  The Diagram menu: Write DBML… (the connected database's schema to a .dbml file) and
//  Open DBML… (a .dbml file in a Diagram window).
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum DBMLFile {
    /// The type macOS gives .dbml files. No app declares one, so it is a dynamic type; asking for one that
    /// conforms to plain text would make a different dynamic type that no .dbml file has, and the Open
    /// panel would grey them all out.
    static let type = UTType(filenameExtension: "dbml") ?? .plainText
}

/// Identifies a Diagram window; the model is handed over in memory (DiagramWindows).
nonisolated struct DiagramWindowID: Codable, Hashable {
    var id = UUID()
}

@MainActor
enum DiagramWindows {
    private static var pending: [UUID: DiagramModel] = [:]

    static func register(_ model: DiagramModel) -> DiagramWindowID {
        let id = DiagramWindowID()
        pending[id.id] = model
        return id
    }

    static func take(_ id: DiagramWindowID) -> DiagramModel? {
        pending.removeValue(forKey: id.id)
    }
}

struct DiagramCommands: Commands {
    @FocusedValue(\.workspaceSession) private var session
    @FocusedValue(\.diagramModel) private var diagram
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Diagram") {
            Button("Write DBML…") {
                if let session { DBMLExport.begin(for: session) { openWindow(value: DiagramWindows.register($0)) } }
            }
            .keyboardShortcut("d", modifiers: [.command, .option])
            .disabled(!(session?.isConnected ?? false))

            Button("Open DBML…") {
                if let model = DBMLExport.open() { openWindow(value: DiagramWindows.register(model)) }
            }
            .keyboardShortcut("o", modifiers: [.command, .option])

            Divider()

            Button("Save Diagram") { _ = diagram?.save() }
                .disabled(diagram == nil)
            Button("Save Diagram As…") { _ = diagram?.saveAs() }
                .disabled(diagram == nil)

            Divider()

            Button("Add Note") { diagram?.addNoteAtVisibleCenter() }
                .disabled(diagram == nil)
            Button("Arrange Tables") { diagram?.autoArrange() }
                .disabled(diagram == nil)
            Menu("Export Schema") {
                ForEach(diagram?.schema.schemas ?? [], id: \.self) { name in
                    Button(name) { diagram?.exportSchema(name) }
                }
            }
            .disabled(diagram == nil)

            Divider()

            Button("Zoom In") { diagram?.zoom = min(3, (diagram?.zoom ?? 1) * 1.25) }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(diagram == nil)
            Button("Zoom Out") { diagram?.zoom = max(0.2, (diagram?.zoom ?? 1) / 1.25) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(diagram == nil)
            Button("Actual Size") { diagram?.zoom = 1 }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(diagram == nil)
        }
    }
}

extension FocusedValues {
    @Entry var diagramModel: DiagramModel?
}

/// Write DBML… and Open DBML…
@MainActor
enum DBMLExport {
    /// Options shown under the Save panel.
    @Observable
    final class Options {
        var schemas: [String] = []
        var chosen = Set<String>()
        var openAfterWriting = true
    }

    static func begin(for session: WorkspaceSession, open: @escaping (DiagramModel) -> Void) {
        guard let service = session.currentService, let database = session.connectedDatabase else { return }
        Task {
            let schemas: [String]
            do {
                schemas = try await service.rows(DBMLWriter.schemasSQL).compactMap { $0.first ?? nil }
            } catch {
                session.errorMessage = DatabaseError.from(error).message
                return
            }
            guard !schemas.isEmpty else {
                session.errorMessage = "Database \(database) has no tables to diagram."
                return
            }
            let options = Options()
            options.schemas = schemas
            options.chosen = Set(schemas)

            let panel = NSSavePanel()
            panel.title = "Write DBML"
            panel.message = "Where to write the schema diagram of \(database)."
            panel.prompt = "Write"
            panel.allowedContentTypes = [DBMLFile.type]
            panel.nameFieldStringValue = "\(database).dbml"
            panel.canCreateDirectories = true
            let accessory = NSHostingView(rootView: SaveOptionsView(options: options))
            accessory.frame.size = accessory.fittingSize
            panel.accessoryView = accessory

            let handler: (NSApplication.ModalResponse) -> Void = { response in
                guard response == .OK, let url = panel.url else { return }
                let chosen = options.schemas.filter { options.chosen.contains($0) }
                guard !chosen.isEmpty else {
                    session.errorMessage = "Choose at least one schema to write."
                    return
                }
                Task { await write(session: session, service: service, database: database, schemas: chosen,
                                   to: url, openAfter: options.openAfterWriting, open: open) }
            }
            if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: handler) }
            else { handler(panel.runModal()) }
        }
    }

    static func write(session: WorkspaceSession, service: PostgresService, database: String, schemas: [String],
                      to url: URL, openAfter: Bool, open: (DiagramModel) -> Void) async {
        session.busy = true
        defer { session.busy = false }
        do {
            let catalog = try await DBMLWriter.read(service, schemas: schemas)
            let source = "\(database)"
            let result = DBMLWriter.generate(catalog, source: source, schemas: schemas)
            // Rewriting a diagram that was already arranged keeps its notes and layout.
            var text = result.text
            if let old = try? String(contentsOf: url, encoding: .utf8), DBMLFileLayout.split(old).section != nil {
                var previous = DBMLDiagram(fileText: old)
                previous.source = text
                text = previous.fileText()
            }
            try text.write(to: url, atomically: true, encoding: .utf8)
            session.infoMessage = "Wrote \(url.lastPathComponent): \(result.tables) tables, \(result.refs) relationships"
            if openAfter { open(DiagramModel(fileText: text, fileURL: url)) }
        } catch {
            session.errorMessage = "Could not write the DBML file.\n\n\(DatabaseError.from(error).message)"
        }
    }

    static func open() -> DiagramModel? {
        let panel = NSOpenPanel()
        panel.title = "Open DBML"
        panel.prompt = "Open"
        panel.allowedContentTypes = [DBMLFile.type, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let model = DiagramModel(fileText: text, fileURL: url)
            guard !model.schema.tables.isEmpty else {
                showError("\(url.lastPathComponent) has no tables." + (model.schema.problems.first.map { "\n\nLine \($0.line): \($0.message)" } ?? ""))
                return nil
            }
            return model
        } catch {
            showError("Could not open \(url.lastPathComponent).\n\n\(error.localizedDescription)")
            return nil
        }
    }

    private static func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Open DBML"
        alert.informativeText = message
        alert.runModal()
    }
}

private struct SaveOptionsView: View {
    @Bindable var options: DBMLExport.Options

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Schemas").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(options.schemas, id: \.self) { schema in
                        Toggle(schema, isOn: Binding(
                            get: { options.chosen.contains(schema) },
                            set: { if $0 { options.chosen.insert(schema) } else { options.chosen.remove(schema) } }))
                            .toggleStyle(.checkbox)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: min(CGFloat(options.schemas.count) * 20 + 4, 120))
            Toggle("Open the diagram after writing", isOn: $options.openAfterWriting)
                .toggleStyle(.checkbox)
        }
        .padding(12)
        .frame(width: 360, alignment: .leading)
    }
}

#if DEBUG
/// `-diagramDemo YES` (debug builds): connects (Keychain password, or PGPASSWORD), writes every schema
/// to the app's temporary folder through Write DBML's own code, shapes two relationships as Bézier
/// curves, adds a note and opens the diagram — for checking the Diagram window without the Save panel.
@MainActor
enum DiagramDemo {
    static func run(session: WorkspaceSession, settings: ConnectionSettings, open: @escaping (DiagramModel) -> Void) async {
        guard UserDefaults.standard.bool(forKey: "diagramDemo") else { return }
        if session.password.isEmpty, let env = ProcessInfo.processInfo.environment["PGPASSWORD"] { session.password = env }
        if !session.isConnected { await session.connect(settings) }
        guard session.isConnected, let service = session.currentService, let database = session.connectedDatabase,
              let schemas = try? await service.rows(DBMLWriter.schemasSQL).compactMap({ $0.first ?? nil }) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(database)-demo.dbml")
        try? FileManager.default.removeItem(at: url)
        await DBMLExport.write(session: session, service: service, database: database, schemas: schemas,
                               to: url, openAfter: true) { model in
            // Two relationships near the top left, one per Bézier kind, the cubic one selected.
            let geometry = DBMLGeometry(model.diagram)
            let near = model.schema.refs.filter {
                guard let a = geometry.box($0.from.table)?.rect, let b = geometry.box($0.to.table)?.rect else { return false }
                return a.maxX < 1100 && b.maxX < 1100 && a.minY < 700 && b.minY < 700 && $0.from.table != $0.to.table
            }
            if near.count >= 2 {
                model.setStyle(.quadratic, for: near[0].id)
                model.setStyle(.cubic, for: near[1].id)
                if let line = DBMLGeometry(model.diagram).line(near[1].id) {
                    model.diagram.moveControl(0, of: near[1].id, to: CGPoint(x: line.controls[0].x + 40, y: line.controls[0].y - 90))
                }
                model.selection = DBMLSelection(ref: near[1].id)
            }
            model.addNote(at: CGPoint(x: 40, y: 8))
            if let i = model.diagram.notes.indices.last {
                model.diagram.notes[i].text = "Diagram demo: drag tables, click a relationship to pick its curve, drag the round handles; right-click a schema to export it."
            }
            model.editNoteRequest = nil
            open(model)
        }
    }
}
#endif
