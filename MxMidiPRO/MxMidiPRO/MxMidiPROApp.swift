//
//  MxMidiPROApp.swift — MxMidiPRO
//
//  A MIDI message monitor for the MIDI travelling between Logic Pro and external USB MIDI devices, modelled on
//  MMM — MIDI Message Monitor by Tim Shoebridge (soundmangling.com).
//

import AppKit
import SwiftUI

@main
struct MxMidiPROApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = MonitorStore()

    var body: some Scene {
        Window("MxMidiPRO", id: "monitor") {
            MonitorView(store: store)
                .frame(minWidth: 1200, minHeight: 480)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1340, height: 640)
        .commands { MonitorCommands(store: store) }

        Settings {
            SettingsView(store: store)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct MonitorCommands: Commands {
    let store: MonitorStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(after: .saveItem) {
            Button("Export Log…") { store.exportLog() }
                .keyboardShortcut("e")
        }
        CommandMenu("Monitor") {
            Button(store.paused ? "Resume" : "Pause") { store.paused.toggle() }
                .keyboardShortcut(".", modifiers: .command)
            Button("Reset Log") { store.reset() }
                .keyboardShortcut("k")
            Divider()
            Toggle("Show IN (Devices → Logic Pro)", isOn: binding(\.showIn))
                .keyboardShortcut("1")
            Toggle("Show OUT (Logic Pro → Devices)", isOn: binding(\.showOut))
                .keyboardShortcut("2")
            Toggle("Show Raw Bytes", isOn: binding(\.showRaw))
                .keyboardShortcut("r", modifiers: [.command, .option])
            Divider()
            Button("Set Up OUT Monitoring…") { store.showOutSetup = true }
            Toggle("Thru Ports for Logic Pro", isOn: binding(\.thruEnabled))
            Button("Rescan MIDI Devices") { store.rescan() }
        }
    }

    private func binding(_ keyPath: ReferenceWritableKeyPath<MonitorStore, Bool>) -> Binding<Bool> {
        Binding(get: { store[keyPath: keyPath] }, set: { store[keyPath: keyPath] = $0 })
    }
}
