//
//  ContentView.swift — MxModxUSB
//

import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case overview, performance, liveSet, system, userData, workspace, connection, activity
    case fmTutorial, awmTutorial, songs

    var id: String { rawValue }

    static let instrument: [AppSection] = [.overview, .performance, .liveSet, .system, .userData, .workspace, .connection, .activity]
    static let learn: [AppSection] = [.fmTutorial, .awmTutorial, .songs]

    var title: String {
        switch self {
        case .overview: "Overview"
        case .performance: "Performance"
        case .liveSet: "Live Set"
        case .system: "System Settings"
        case .userData: "User Data"
        case .workspace: "Workspace"
        case .connection: "USB · MIDI · Audio"
        case .activity: "MIDI Activity"
        case .fmTutorial: "FM Synthesis"
        case .awmTutorial: "AWM2 Synthesis"
        case .songs: "MIDI Songs"
        }
    }

    /// What Quick Help says about the screen.
    var detail: String {
        switch self {
        case .overview: "The MODX at a glance: the current Performance, its Parts, what the keyboard, wheels and knobs are doing, and the main settings."
        case .performance: "The current Performance: its Common settings, effects and knobs, and its 16 Parts. Unlocked, they can be changed; double-click a Part for all its settings."
        case .liveSet: "The Live Set as the MODX shows it: bank and page drop-downs, Refresh, and 16 slots named by their Performances. Click a slot to play it on the MODX."
        case .system: "Every System and Sequencer setting, grouped; unlocked, each can be changed (System changes take effect at once)."
        case .userData: "The 32 user curves and 8 micro-tuning tables."
        case .workspace: "MODX7 workspace files: save everything from the MODX, open a file, compare it with the MODX and send parts of it back."
        case .connection: "The USB device, its MIDI ports with every CoreMIDI property, and the USB audio interface."
        case .activity: "What the MODX sends on each port, and every request the app has sent with what came back."
        case .fmTutorial: "Lessons in FM synthesis played on the MODX7's FM-X engine, at the instruction level in Settings ▸ Guidance."
        case .awmTutorial: "Lessons in AWM2 (sample-based) synthesis played on the MODX7's AWM2 engine, at the instruction level in Settings ▸ Guidance."
        case .songs: "MIDI songs on the MODX7: open, edit and save Standard MIDI Files with tracks, a piano roll, a mixer, mute and solo — every note played by the MODX, with lessons at the Guidance level."
        }
    }

    var icon: String {
        switch self {
        case .overview: "pianokeys"
        case .performance: "square.stack.3d.up"
        case .liveSet: "square.grid.4x3.fill"
        case .system: "gearshape.2"
        case .userData: "point.topleft.down.to.point.bottomright.curvepath"
        case .workspace: "doc.richtext"
        case .connection: "cable.connector"
        case .activity: "waveform.path.ecg"
        case .fmTutorial: "dot.radiowaves.left.and.right"
        case .awmTutorial: "waveform"
        case .songs: "music.note.list"
        }
    }
}

struct ContentView: View {
    let model: ModxModel
    @State private var section: AppSection? = .overview

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                Section("MODX7") {
                    ForEach(AppSection.instrument) { item in
                        Label(item.title, systemImage: item.icon).tag(item).quickHelp(item.title, item.detail, symbol: item.icon)
                    }
                }
                Section("Learn") {
                    ForEach(AppSection.learn) { item in
                        Label(item.title, systemImage: item.icon).tag(item).quickHelp(item.title, item.detail, symbol: item.icon)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
            .safeAreaInset(edge: .bottom) { ConnectionBadge(model: model).padding(10) }
            // Quick Help at the bottom left, under the connection; its ⧉ floats it in a window of its own.
            .quickHelpDock()
        } detail: {
            VStack(spacing: 0) {
                EditBanner(model: model)
                switch section ?? .overview {
                case .overview: OverviewView(model: model)
                case .performance: PerformanceView(model: model)
                case .liveSet: LiveSetView(model: model)
                case .system: SystemView(model: model)
                case .userData: UserDataView(model: model)
                case .workspace: WorkspaceView(model: model)
                case .connection: ConnectionView(model: model)
                case .activity: ActivityView(model: model)
                case .fmTutorial: TutorialView(model: model, engine: .fmx)
                case .awmTutorial: TutorialView(model: model, engine: .awm2)
                case .songs: SongView(model: model)
                }
            }
            .quickHelpScreen((section ?? .overview).title,
                             QuickHelpItem(title: (section ?? .overview).title, detail: (section ?? .overview).detail,
                                           symbol: (section ?? .overview).icon))
            .navigationTitle((section ?? .overview).title)
            .toolbar {
                ToolbarItemGroup {
                    Toggle(isOn: Binding(get: { model.editsUnlocked }, set: { model.editsUnlocked = $0 })) {
                        Label(model.editsUnlocked ? "Changes Unlocked" : "Changes Locked",
                              systemImage: model.editsUnlocked ? "lock.open.fill" : "lock.fill")
                    }
                    .toggleStyle(.button)
                    .tint(model.editsUnlocked ? .orange : nil)
                    .help(model.editsUnlocked ? "Lock: stop sending changes to the MODX"
                          : "Unlock to change the MODX's settings from here (they go to the MODX as you make them)")
                    .quickHelp(model.editsUnlocked ? "Changes Unlocked" : "Changes Locked",
                               "While locked the app only reads the MODX (and plays Live Set slots you click). Unlocked, every setting it shows can be changed, each change going to the MODX as you make it and read back; the tutorials need it to set up their sounds. It's locked at every launch.",
                               symbol: model.editsUnlocked ? "lock.open.fill" : "lock.fill")
                    if model.loading { ProgressView().controlSize(.small) }
                    if model.problems > 0 {
                        Button { section = .activity } label: {
                            Label("\(model.problems) unanswered", systemImage: "exclamationmark.triangle.fill")
                        }
                        .foregroundStyle(.orange)
                        .help("The MODX didn't answer some requests. MIDI Activity ▸ Requests to the MODX lists them with their times.")
                    }
                    Text(model.status).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    Button { model.readEverything() } label: { Label("Read Again", systemImage: "arrow.clockwise") }
                        .disabled(!model.connected || model.loading)
                        .help("Read everything from the MODX again (⌘R)")
                        .quickHelp("Read Again", "Reads everything from the MODX again: identity, System, the Performance and its Parts, the Live Set, curves and micro-tuning.", shortcut: "⌘R", symbol: "arrow.clockwise")
                }
            }
        }
    }
}

private struct ConnectionBadge: View {
    let model: ModxModel

    var body: some View {
        HStack(spacing: 8) {
            Lamp(on: model.connected, color: .green, size: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.identity?.model ?? (model.connected ? "MODX" : "Not connected")).font(.callout.weight(.semibold))
                Text(model.identity.map { "Firmware \($0.firmware)" } ?? (model.connected ? "USB" : "Connect the MODX by USB"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .quickHelp(model.connected ? "Connected" : "Not connected",
                   model.connected ? "The MODX on USB, with its model and firmware (from its Identity Reply)." : "Connect the MODX by USB (TO HOST) and turn it on; the app finds it by itself.",
                   symbol: "cable.connector")
    }
}
