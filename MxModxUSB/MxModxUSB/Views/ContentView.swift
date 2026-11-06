//
//  ContentView.swift — MxModxUSB
//

import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case overview, performance, liveSet, system, userData, workspace, connection, activity

    var id: String { rawValue }

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
        }
    }
}

struct ContentView: View {
    let model: ModxModel
    @State private var section: AppSection? = .overview

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $section) { item in
                Label(item.title, systemImage: item.icon).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .safeAreaInset(edge: .bottom) { ConnectionBadge(model: model).padding(10) }
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
                }
            }
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
    }
}
