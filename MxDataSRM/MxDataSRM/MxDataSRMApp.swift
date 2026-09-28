//
//  MxDataSRMApp.swift
//  MxDataSRM
//
//  Document-based app: each window is a workspace (*.mxworkspace).
//  DocumentGroup provides the File menu (New, Open, Save, ...);
//  TableCommands adds the Table menu.
//

import SwiftUI

@main
struct MxDataSRMApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: WorkspaceDocument()) { file in
            ContentView(document: file.$document)
        }
        .commands {
            TableCommands()
        }
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
            .disabled(session?.grid == nil)
        }
    }
}
