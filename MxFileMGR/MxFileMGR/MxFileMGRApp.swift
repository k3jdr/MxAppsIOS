//
//  MxFileMGRApp.swift
//  MxFileMGR
//
//  Dual-pane file manager in the spirit of ForkLift and Total Commander.
//  Each main window is a Workspace (left and right pane, each with tabs);
//  tools such as Search, Multi-Rename, Synchronize, the viewer and the
//  file comparison open in their own windows.
//

import SwiftUI

@main
struct MxFileMGRApp: App {
    init() {
        LegacySettings.migrate()
    }

    var body: some Scene {
        WindowGroup("MxFileMGR", id: "main") {
            MainView()
        }
        .defaultSize(width: 1280, height: 780)
        .commands {
            MainCommands()
            SidebarCommands()
            QuickHelpCommands()
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

        WindowGroup("SFTP", for: SFTPRequest.self) { $request in
            if let request { SFTPView(request: request) }
        }
        .defaultSize(width: 900, height: 600)
        .restorationBehavior(.disabled)
        .commandsRemoved()

        Window("Google Cloud Storage", id: "gcs") {
            GCSView()
        }
        .defaultSize(width: 1050, height: 680)
        .restorationBehavior(.disabled)
        .commandsRemoved()

        Settings {
            SettingsView()
        }
    }
}

/// The app was called MxDeskMGR (bundle com.k3jdr.MxDeskMGR) until 2026-10-16. On the first launch
/// under the new name, its preferences (favorites, session tabs, recent servers, S3 profile, column
/// layouts and window frames) are copied over; keys naming the old module are renamed to match.
enum LegacySettings {
    static let oldDomain = "com.k3jdr.MxDeskMGR"
    private static let doneKey = "migratedFromMxDeskMGR"

    static func migrate() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defer { defaults.set(true, forKey: doneKey) }
        guard let old = defaults.persistentDomain(forName: oldDomain) else { return }
        for (key, value) in old {
            let newKey = key.replacingOccurrences(of: "MxDeskMGR", with: "MxFileMGR")
            if defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[newKey] == nil {
                defaults.set(value, forKey: newKey)
            }
        }
    }
}

// Window payloads (Codable + Hashable so SwiftUI can route them to a WindowGroup).
struct SearchRequest: Codable, Hashable { var root: URL }
struct RenameRequest: Codable, Hashable { var urls: [URL] }
struct SyncRequest: Codable, Hashable { var left: URL; var right: URL }
struct ViewerRequest: Codable, Hashable { var url: URL }
struct DiffRequest: Codable, Hashable { var left: URL; var right: URL }
