//
//  MxDataSQLApp.swift
//  MxDataSQL
//
//  Document-based app: each window is a workspace (*.mxworkspace).
//  DocumentGroup provides the File menu (New, Open, Save, ...);
//  TableCommands adds the Table menu, DiagramCommands the Diagram menu.
//

import SwiftUI

@main
struct MxDataSQLApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: WorkspaceDocument()) { file in
            ContentView(document: file.$document)
        }
        // The window cannot be made smaller than its content needs, so the form buttons,
        // the SQL box and the grid's command buttons always stay visible.
        .windowResizability(.contentMinSize)
        .commands {
            TableCommands()
            DiagramCommands()
            QuickHelpCommands()
        }

        // Tables opened with "Open in New Window". Not restored at launch: they need the
        // workspace's connection and password, which are only handed over in memory.
        WindowGroup("Table", for: TableWindowID.self) { $id in
            TableWindowView(id: id)
        }
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)
        .commandsRemoved()

        // Diagram ▸ Write DBML / Open DBML. Not restored at launch: the diagram is handed over in memory.
        WindowGroup("Diagram", for: DiagramWindowID.self) { $id in
            DiagramWindowView(id: id)
        }
        .defaultSize(width: 1300, height: 860)
        .restorationBehavior(.disabled)
        .commandsRemoved()
    }
}

struct TableCommands: Commands {
    @FocusedValue(\.workspaceSession) private var session

    var body: some Commands {
        CommandMenu("Table") {
            Button("View…") {
                session?.showViewDialog = true
            }
            .keyboardShortcut("l", modifiers: [.command, .option])
            .disabled(session == nil)

            Button("Update…") {
                session?.form = .table
                session?.showUpdateDialog = true
            }
            .keyboardShortcut("u", modifiers: [.command, .option])
            .disabled(!(session?.grid?.isEditable ?? false))

            Divider()

            Button("Export CSV…") {
                if let session { CSVExport.begin(for: session) }
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(session?.grid == nil)
        }
    }
}
