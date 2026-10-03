//
//  MxDeskMGRApp.swift
//  MxDeskMGR
//
//  Dual-pane file manager in the spirit of ForkLift and Total Commander.
//  Each main window is a Workspace (left and right pane, each with tabs);
//  tools such as Search, Multi-Rename, Synchronize, the viewer and the
//  file comparison open in their own windows.
//

import SwiftUI

@main
struct MxDeskMGRApp: App {
    var body: some Scene {
        WindowGroup("MxDeskMGR", id: "main") {
            MainView()
        }
        .defaultSize(width: 1280, height: 780)
        .commands {
            MainCommands()
            SidebarCommands()
        }

        WindowGroup("Find Files", for: SearchRequest.self) { $request in
            if let request { SearchView(request: request) }
        }
        .defaultSize(width: 860, height: 560)
        .restorationBehavior(.disabled)
        .commandsRemoved()

        WindowGroup("Multi-Rename", for: RenameRequest.self) { $request in
            if let request { MultiRenameView(request: request) }
        }
        .defaultSize(width: 860, height: 600)
        .restorationBehavior(.disabled)
        .commandsRemoved()

        WindowGroup("Synchronize Folders", for: SyncRequest.self) { $request in
            if let request { SyncView(request: request) }
        }
        .defaultSize(width: 1000, height: 620)
        .restorationBehavior(.disabled)
        .commandsRemoved()

        WindowGroup("Viewer", for: ViewerRequest.self) { $request in
            if let request { ViewerView(request: request) }
        }
        .defaultSize(width: 900, height: 700)
        .restorationBehavior(.disabled)
        .commandsRemoved()

        WindowGroup("Compare Files", for: DiffRequest.self) { $request in
            if let request { DiffView(request: request) }
        }
        .defaultSize(width: 1000, height: 700)
        .restorationBehavior(.disabled)
        .commandsRemoved()

        Window("iCloud Photos", id: "photos") {
            PhotosView()
        }
        .defaultSize(width: 1000, height: 700)
        .restorationBehavior(.disabled)
        .commandsRemoved()

        Window("Amazon S3", id: "s3") {
            S3View()
        }
        .defaultSize(width: 1050, height: 680)
        .restorationBehavior(.disabled)
        .commandsRemoved()

        Window("Azure Blob Storage", id: "azure") {
            AzureView()
        }
        .defaultSize(width: 1050, height: 680)
        .restorationBehavior(.disabled)
        .commandsRemoved()

        Settings {
            SettingsView()
        }
    }
}

// Window payloads (Codable + Hashable so SwiftUI can route them to a WindowGroup).
struct SearchRequest: Codable, Hashable { var root: URL }
struct RenameRequest: Codable, Hashable { var urls: [URL] }
struct SyncRequest: Codable, Hashable { var left: URL; var right: URL }
struct ViewerRequest: Codable, Hashable { var url: URL }
struct DiffRequest: Codable, Hashable { var left: URL; var right: URL }
