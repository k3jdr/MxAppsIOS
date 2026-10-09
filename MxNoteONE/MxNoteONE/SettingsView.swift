//
//  SettingsView.swift
//  MxNoteONE
//
//  MxNoteONE ▸ Settings (⌘,).
//

import SwiftUI

struct SettingsView: View {
    @AppStorage(Prefs.fontNameKey) private var fontName = "Helvetica Neue"
    @AppStorage(Prefs.fontSizeKey) private var fontSize = 14.0
    @AppStorage(Prefs.pageColorKey) private var pageColor = PageColor.none.rawValue
    @AppStorage(Prefs.ruleLinesKey) private var ruleLines = RuleLines.none.rawValue
    @AppStorage(Prefs.notebooksFolderKey) private var notebooksFolder = ""
    @AppStorage(Prefs.autoLockKey) private var autoLockMinutes = 10

    var body: some View {
        TabView {
            general
                .tabItem { Label("General", systemImage: "gearshape") }
            OneDriveSettingsView()
                .tabItem { Label("OneDrive", systemImage: "cloud") }
        }
        .frame(width: 580)
    }

    private var general: some View {
        Form {
            Section("New Text") {
                Picker("Default font:", selection: $fontName) {
                    ForEach(NSFontManager.shared.availableFontFamilies, id: \.self) { Text($0).tag($0) }
                }
                Stepper("Default size: \(Int(fontSize)) pt", value: $fontSize, in: 8...48)
                Text("The quick brown fox jumps over the lazy dog.")
                    .font(Font(Prefs.defaultFont as CTFont))
                    .foregroundStyle(.secondary)
            }
            Section("New Pages") {
                Picker("Page color:", selection: $pageColor) {
                    ForEach(PageColor.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker("Rule lines:", selection: $ruleLines) {
                    ForEach(RuleLines.allCases) { Text($0.title).tag($0.rawValue) }
                }
            }
            Section("Notebooks") {
                LabeledContent("New notebooks in:") {
                    HStack {
                        Text(Prefs.notebooksFolder.path(percentEncoded: false))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { chooseFolder() }
                    }
                }
                Picker("Lock protected sections:", selection: $autoLockMinutes) {
                    Text("Never automatically").tag(0)
                    Text("After 1 minute away").tag(1)
                    Text("After 5 minutes away").tag(5)
                    Text("After 10 minutes away").tag(10)
                    Text("After 30 minutes away").tag(30)
                    Text("After 1 hour away").tag(60)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = Prefs.notebooksFolder
        if panel.runModal() == .OK, let url = panel.url { notebooksFolder = url.path }
    }
}
