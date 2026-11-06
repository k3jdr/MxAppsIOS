//
//  SettingsView.swift — MxMidiPRO
//

import SwiftUI

struct SettingsView: View {
    @Bindable var store: MonitorStore

    var body: some View {
        Form {
            Section("Log") {
                Picker("Note names", selection: $store.middleCOctave) {
                    Text("Middle C is C3 (Logic Pro, Yamaha)").tag(3)
                    Text("Middle C is C4 (Roland, scientific)").tag(4)
                }
                Picker("Time column", selection: $store.timeDisplay) {
                    ForEach(TimeDisplay.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Show raw bytes", isOn: $store.showRaw)
                Picker("Keep up to", selection: $store.keep) {
                    ForEach(MonitorStore.keepChoices, id: \.self) { Text("\($0.formatted()) messages").tag($0) }
                }
                .help("The oldest messages are dropped past this; Export Log saves what's kept")
            }
            Section("OUT monitoring") {
                SpyDriverControls(store: store)
                Toggle("Thru ports for Logic Pro (MxMidiPRO ▸ device)", isOn: $store.thruEnabled)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onAppear { store.updateSpyState() }
    }
}
