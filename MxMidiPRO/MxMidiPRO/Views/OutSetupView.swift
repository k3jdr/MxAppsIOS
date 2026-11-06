//
//  OutSetupView.swift — MxMidiPRO
//
//  Setting up OUT: the two ways to see what Logic Pro sends to a device, and the spy driver's controls (also in
//  Settings).
//

import AppKit
import SwiftUI

struct OutSetupView: View {
    @Bindable var store: MonitorStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Monitor what Logic Pro sends (OUT)").font(.title2.weight(.semibold))
            Text("Any app can hear what a device sends (IN): CoreMIDI gives every app its own copy. What an app sends to a device goes from the app straight to the device's driver, so MxMidiPRO needs one of these to see it:")
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("A small MIDI driver, MxMidiPRO Spy, that the MIDI server loads the way it loads Roland's and Yamaha's. It asks the server for a copy of every message sent to every device and passes the copies to MxMidiPRO on a private port that Logic Pro never sees. Nothing changes in Logic Pro or its projects.")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("It installs in ~/Library/Audio/MIDI Drivers (no password). The MIDI server loads drivers when it starts, so it has to restart once — quit Logic Pro first.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    SpyDriverControls(store: store)
                }
                .padding(6)
            } label: {
                Label("1 · Spy driver (recommended)", systemImage: "eye")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("MxMidiPRO makes a port called “MxMidiPRO ▸ device” for each USB, Bluetooth or network destination and passes whatever arrives on it straight to the device. In Logic Pro, choose that port as the MIDI output of the track or External Instrument. Only what goes through these ports is seen.")
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("Make thru ports", isOn: $store.thruEnabled)
                    if store.thruEnabled {
                        if store.thruPortNames.isEmpty {
                            Text("No hardware destinations are connected.").font(.callout).foregroundStyle(.secondary)
                        } else {
                            Text(store.thruPortNames.joined(separator: "\n"))
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(6)
            } label: {
                Label("2 · Thru ports (no driver)", systemImage: "arrow.right.arrow.left")
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { store.updateSpyState() }
    }
}

struct SpyDriverControls: View {
    @Bindable var store: MonitorStore
    @State private var confirmRestart = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SquareLamp(on: store.spyState == .active, tint: Panel.inTint, size: 16)
                Text(stateText)
            }
            HStack {
                Button(installTitle) { store.installSpyDriver() }
                    .disabled(store.spyState != .notInstalled && store.spyIsCurrent && SpyDriverInstall.isInstalled)
                Button("Restart MIDI Server…") { confirmRestart = true }
                Button("Uninstall") { store.uninstallSpyDriver() }
                    .disabled(!SpyDriverInstall.isInstalled)
                Button("Show in Finder") {
                    let url = SpyDriverInstall.isInstalled ? SpyDriverInstall.installed : SpyDriverInstall.folder
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            if store.logicRunning {
                Label("Logic Pro is running. Restarting the MIDI server cuts its MIDI until you quit and reopen it.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = store.spyMessage {
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog("Restart the MIDI server?", isPresented: $confirmRestart) {
            Button("Restart MIDI Server", role: .destructive) { store.restartMIDIServer() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(store.logicRunning
                 ? "Logic Pro is running and will lose its MIDI ports until you quit and reopen it. Every other MIDI app is affected too. MxMidiPRO reopens itself."
                 : "Every open MIDI app loses its connections and needs reopening. MxMidiPRO reopens itself.")
        }
    }

    private var installTitle: String {
        if !SpyDriverInstall.isInstalled { return "Install Driver" }
        return store.spyIsCurrent ? "Installed" : "Update Driver"
    }

    private var stateText: String {
        switch store.spyState {
        case .active: store.spyIsCurrent ? "Active" : "Active — an older version; update it and restart the MIDI server"
        case .installedNotLoaded: "Installed, not loaded yet — restart the MIDI server"
        case .notInstalled: "Not installed"
        }
    }
}
