//
//  MxDataHUBApp.swift
//  MxDataHUB
//
//  The security reference master hub: one window with a sidebar — DB Connection, Securities,
//  Portfolios, Benchmarks, Data Refresh, Load History, and Services & Workflows — over the PostgreSQL schema srm (see SRM/README.md).
//

import SwiftUI

@main
struct MxDataHUBApp: App {
    @State private var store = SRMStore()

    var body: some Scene {
        Window("MxDataHUB", id: "main") {
            ContentView(store: store)
        }
        .defaultSize(width: 1560, height: 900)
        // The window cannot be made smaller than its content needs.
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu("Hub") {
                ForEach(Array(SRMSection.allCases.enumerated()), id: \.element) { index, section in
                    Button(section.rawValue) { store.section = section }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                }
                Divider()
                Button(store.isConnected ? "Reconnect" : "Connect") {
                    Task { await store.connect() }
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(store.status == .connecting || store.settings.host.isEmpty)
                Button("Disconnect") {
                    Task { await store.disconnect() }
                }
                .disabled(!store.isConnected)
            }
            QuickHelpCommands()
        }
    }
}
