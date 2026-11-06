//
//  MxModxUSBApp.swift — MxModxUSB
//
//  An overview of a Yamaha MODX7 (and MODX6/8) and everything it reports over USB: the instrument and its
//  firmware, the current Performance and its Parts, the Live Set, System settings, user data, the USB device and
//  its MIDI and audio interfaces, and what its keyboard and controllers are doing. With changes unlocked it edits
//  those settings on the MODX, and MODX7 workspace files save them all and send them back. FM Synthesis and AWM2
//  Synthesis teach both engines on the MODX itself; Quick Help (the shared MxAppsIOS pane) docks at the bottom left.
//

import AppKit
import SwiftUI

@main
struct MxModxUSBApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = ModxModel()

    var body: some Scene {
        Window("MxModxUSB", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 1100, minHeight: 680)
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(width: 1320, height: 860)
        .commands {
            QuickHelpCommands()
            CommandGroup(replacing: .newItem) {
                Button("Open MODX7 Workspace…") { model.openWorkspace() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save MODX7 Workspace…") { model.saveWorkspace() }
                    .keyboardShortcut("s")
                    .disabled(!model.connected)
            }
            CommandGroup(after: .undoRedo) {
                Button(model.undoTitle.map { "\($0) on the MODX" } ?? "Undo Change on the MODX") { model.undoLastEdit() }
                    .keyboardShortcut("z", modifiers: [.command, .option])
                    .disabled(model.undoTitle == nil || !model.editsUnlocked)
            }
            CommandGroup(after: .toolbar) {
                Button("Read the MODX Again") { model.readEverything() }
                    .keyboardShortcut("r")
                    .disabled(!model.connected)
            }
        }
        Settings {
            ModxSettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: ModxModel? {
        didSet {
            guard let model, let url = waiting.first else { return }
            waiting.removeAll()
            MainActor.assumeIsolated { model.openWorkspace(url) }
        }
    }
    private var waiting: [URL] = []

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// A .modxworkspace opened from Finder.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        MainActor.assumeIsolated {
            if let model { model.openWorkspace(url) } else { waiting.append(url) }
        }
    }
}
