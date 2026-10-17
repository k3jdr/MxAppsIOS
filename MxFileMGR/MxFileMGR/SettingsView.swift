//
//  SettingsView.swift
//  MxFileMGR
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("File Lists") {
                Toggle("Show hidden files", isOn: $settings.showHidden)
                Toggle("Folders before files", isOn: $settings.foldersFirst)
                Toggle("Show function key bar", isOn: $settings.showFunctionKeyBar)
                Toggle("Ask before moving items to the Trash", isOn: $settings.confirmTrash)
            }
            Section("Applications") {
                appRow("Editor (F4):", path: $settings.editorPath)
                appRow("Terminal:", path: $settings.terminalPath)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
    }

    private func appRow(_ title: String, path: Binding<String>) -> some View {
        LabeledContent(title) {
            HStack {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path.wrappedValue))
                    .resizable().frame(width: 18, height: 18)
                Text(FileManager.default.displayName(atPath: path.wrappedValue))
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.directoryURL = URL(fileURLWithPath: "/Applications")
                    panel.allowedContentTypes = [.application]
                    if panel.runModal() == .OK, let url = panel.url { path.wrappedValue = url.path }
                }
            }
        }
    }
}
