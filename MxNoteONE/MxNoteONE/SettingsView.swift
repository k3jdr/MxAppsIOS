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
    @AppStorage(DeviceUnlock.appLockKey) private var appLock = false
    @State private var useOfficeFonts = OfficeFonts.enabled
    @AppStorage(WebBrowser.key) private var browserID = ""
    @State private var browsers = WebBrowser.installed()

    private var officeFontsStatus: String {
        let available = OfficeFonts.fontFiles()
        if available.files.isEmpty {
            return "Microsoft Office isn't installed. Its fonts (Calibri, Consolas, Cambria…) come with Word, Excel, PowerPoint, OneNote or Outlook."
        }
        if !OfficeFonts.loaded.isEmpty && !useOfficeFonts {
            return "Office fonts will be removed the next time you open MxNoteONE. Text in those fonts then shows in a similar Mac font."
        }
        if !OfficeFonts.loaded.isEmpty {
            return "\(OfficeFonts.loaded.count) Office font files (Calibri, Consolas, Cambria, Aptos…) from \(OfficeFonts.sources.joined(separator: ", ")) are available in MxNoteONE. They're used from the Office apps — nothing is copied or installed, and other apps aren't affected."
        }
        return "Calibri, Consolas, Cambria and the other fonts that come with \(available.apps.joined(separator: ", ")) can be used in MxNoteONE."
    }

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
                    ForEach(FontLibrary.shared.families, id: \.self) { Text($0).tag($0) }
                }
                Stepper("Default size: \(Int(fontSize)) pt", value: $fontSize, in: 8...48)
                Text("The quick brown fox jumps over the lazy dog.")
                    .font(Font(Prefs.defaultFont as CTFont))
                    .foregroundStyle(.secondary)
            }
            Section("Fonts") {
                Toggle("Use fonts from Microsoft Office", isOn: Binding(
                    get: { useOfficeFonts },
                    set: { on in
                        OfficeFonts.setEnabled(on)
                        useOfficeFonts = on
                    }))
                .disabled(OfficeFonts.fontFiles().files.isEmpty)
                Text(officeFontsStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Web Links") {
                Picker("Open web links in:", selection: $browserID) {
                    Text("Mac default (\(WebBrowser.systemDefault?.name ?? "Safari"))").tag("")
                    Divider()
                    ForEach(browsers) { app in
                        Label { Text(app.name) } icon: { Image(nsImage: app.icon) }.tag(app.id)
                    }
                    // A browser chosen before that has since been removed.
                    if !browserID.isEmpty, !browsers.contains(where: { $0.id == browserID }) {
                        Text("\(browserID) (not installed)").tag(browserID)
                    }
                }
                .onAppear { browsers = WebBrowser.installed() }
                Text(browserID.isEmpty
                     ? "Links in your notes open in the browser the Mac uses for everything."
                     : "Links in your notes (text, tables, the link card) open in \(browsers.first { $0.id == browserID }?.name ?? "the chosen browser") — other apps still use the Mac's default. Email and page links open as usual.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
            Section("Security") {
                if DeviceUnlock.isAvailable {
                    Toggle("Require \(DeviceUnlock.methodName) to open MxNoteONE", isOn: Binding(
                        get: { appLock },
                        set: { on in
                            // Turning it on or off is confirmed by the Mac first.
                            DeviceUnlock.authenticate(reason: on ? "require Touch ID to open MxNoteONE" : "stop requiring Touch ID") { ok in
                                if ok { appLock = on }
                            }
                        }))
                    Text("MxNoteONE also locks after the time chosen above. Protected sections can open with \(DeviceUnlock.methodName) too — choose “Use \(DeviceUnlock.methodName) to unlock next time” when you unlock one, or right-click the section.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("This Mac can't confirm its owner (no Touch ID, Apple Watch or login password check is available).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
