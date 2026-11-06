//
//  WorkspaceView.swift — MxModxUSB
//
//  MODX7 workspace files: save everything from the MODX, open one (with or without the MODX), see what it holds and
//  how it compares with the MODX, and send chosen parts of it back.
//

import SwiftUI

struct WorkspaceView: View {
    @Bindable var model: ModxModel
    @State private var chosen: Set<String> = []
    @State private var confirmSend = false
    @State private var report: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Button { model.saveWorkspace() } label: { Label("Save Workspace from MODX…", systemImage: "square.and.arrow.down") }
                        .disabled(!model.connected || model.workspaceBusy != nil)
                        .help("Reads everything from the MODX afresh — System, the Performance with all 16 Parts, the Live Set, curves, micro-tuning — and saves it (⌘S)")
                    Button { model.openWorkspace() } label: { Label("Open Workspace…", systemImage: "folder") }
                        .help("Opens a .modxworkspace file (⌘O); no MODX needed to look at it")
                    if let busy = model.workspaceBusy {
                        ProgressView().controlSize(.small)
                        Text(busy).foregroundStyle(.secondary)
                    }
                }
                if let file = model.workspace {
                    header(file)
                    sendCard(file)
                    ForEach(file.summary) { group in
                        Card(title: group.title) {
                            ForEach(Array(group.rows.enumerated()), id: \.offset) { _, row in
                                ValueRow(name: row.dropLast().joined(separator: " · "), value: row.last ?? "")
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("No workspace open", systemImage: "doc.richtext",
                                           description: Text("A MODX7 workspace keeps everything the MODX makes available over USB — System and Sequencer settings, the current Performance with all 16 Parts, the Live Set bank, the user curves and the micro-tuning tables — as the MODX's own data, so it can be sent back exactly."))
                        .padding(.top, 40)
                }
            }
            .padding(18)
        }
        .alert("Send to the MODX?", isPresented: $confirmSend) {
            Button("Send") {
                Task { report = await model.sendWorkspace(groups: chosen) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(sendWarning)
        }
        .alert("Workspace sent", isPresented: Binding(get: { report != nil }, set: { if !$0 { report = nil } })) {
            Button("OK") { report = nil }
        } message: {
            Text(report ?? "")
        }
    }

    private func header(_ file: ModxWorkspaceFile) -> some View {
        Card(title: model.workspaceURL?.lastPathComponent ?? "Workspace", systemImage: "doc.richtext") {
            ValueRow(name: "Saved", value: file.savedAt.formatted(date: .abbreviated, time: .shortened))
            ValueRow(name: "From", value: [file.model, file.firmware.isEmpty ? "" : "firmware \(file.firmware)"]
                .filter { !$0.isEmpty }.joined(separator: ", "))
            ValueRow(name: "Performance", value: file.performance)
            ValueRow(name: "Live Set bank", value: file.liveSetBank)
            ValueRow(name: "Blocks", value: "\(file.sections.reduce(0) { $0 + $1.blocks.count }) in \(file.sections.count) sections")
            if let identity = model.identity, !file.model.isEmpty, identity.model != file.model || identity.firmware != file.firmware {
                Label("Saved from \(file.model) \(file.firmware); this MODX is \(identity.model) \(identity.firmware). Its data may not suit this one.",
                      systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
            }
        }
    }

    private func sendCard(_ file: ModxWorkspaceFile) -> some View {
        Card(title: "Send to the MODX", systemImage: "square.and.arrow.up") {
            ForEach(ModxWorkspaceFile.groups, id: \.id) { group in
                let sections = file.sections.filter { group.sections($0.id) }
                if !sections.isEmpty {
                    HStack {
                        Toggle(group.title, isOn: Binding(get: { chosen.contains(group.id) },
                                                          set: { if $0 { chosen.insert(group.id) } else { chosen.remove(group.id) } }))
                            .toggleStyle(.checkbox)
                        Spacer()
                        Text(comparison(sections)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Button("Send Selected to MODX…") { confirmSend = true }
                    .disabled(chosen.isEmpty || !model.connected || !model.editsUnlocked || model.workspaceBusy != nil)
                if !model.editsUnlocked { Text("Unlock changes first (the lock in the toolbar).").font(.caption).foregroundStyle(.secondary) }
                else if !model.connected { Text("Connect the MODX first.").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func comparison(_ sections: [ModxWorkspaceFile.Section]) -> String {
        let states = sections.map { model.sameAsMODX($0) }
        let blocks = sections.reduce(0) { $0 + $1.blocks.count }
        if states.allSatisfy({ $0 == true }) { return "\(blocks) blocks · same as the MODX" }
        if states.contains(false) { return "\(blocks) blocks · differs from the MODX" }
        return "\(blocks) blocks"
    }

    private var sendWarning: String {
        var lines: [String] = []
        if chosen.contains("system") { lines.append("System settings change at once.") }
        if chosen.contains("performance") { lines.append("The Performance goes to the MODX's edit buffer: the one you're playing is replaced; store it on the MODX to keep it.") }
        if chosen.contains("liveSet") { lines.append("The Live Set goes to its edit buffer: store the Live Set on the MODX to keep it.") }
        if chosen.contains("curves") || chosen.contains("microTuning") { lines.append("User curves and micro-tuning tables are replaced.") }
        lines.append("Everything sent is read back and compared.")
        return lines.joined(separator: "\n")
    }
}
