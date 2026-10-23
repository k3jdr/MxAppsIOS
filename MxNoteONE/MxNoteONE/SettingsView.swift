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
    @AppStorage(Prefs.newTextBoxKey) private var newTextBox = Prefs.NewTextBox.click.rawValue
    @AppStorage(LineSpacing.lineBreakKey) private var lineBreakSpacing = 1.0
    @AppStorage(DeviceUnlock.appLockKey) private var appLock = false
    @State private var useOfficeFonts = OfficeFonts.enabled
    @AppStorage(WebBrowser.key) private var browserID = ""
    @AppStorage(PythonLocator.key) private var pythonPath = ""
    @AppStorage(DrawioSource.modeKey) private var drawioOffline = false
    @AppStorage(DrawioSource.themeKey) private var drawioTheme = "kennedy"
    @Bindable private var drawioDownload = DrawioDownload.shared
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
                Picker("Line breaks (⇧↩):", selection: $lineBreakSpacing) {
                    ForEach(LineSpacing.lineBreakChoices, id: \.1) { Text($0.0).tag($0.1) }
                }
                .onChange(of: lineBreakSpacing) { LineSpacing.relayoutOpenPage() }
                Text("Shift-Return breaks the line inside a paragraph (its bullet or tag carries on); Return starts a new paragraph. Format ▸ Line Spacing spaces a paragraph's lines.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Page") {
                Picker("Clicking an empty part of a page:", selection: $newTextBox) {
                    ForEach(Prefs.NewTextBox.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Text("Right-click the page any time for New Text Box Here, Paste Here, and Insert Here (a table, picture, map, score, 3D model, diagram…).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
            Section("Page Navigation") {
                LabeledContent("Back:", value: "⌃←  or  ⌘[  or a mouse's back button")
                LabeledContent("Forward:", value: "⌃→  or  ⌘]  or a mouse's forward button")
                if NotebookStore.shared.navigationKeysTaken {
                    HStack {
                        Label("⌃← and ⌃→ are Mission Control's (Move left / right a space) until you turn those off.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open Keyboard Settings") { NavigationKeys.openKeyboardSettings() }
                    }
                    Text("System Settings ▸ Keyboard ▸ Keyboard Shortcuts… ▸ Mission Control: turn off “Move left a space” and “Move right a space”, or give them other keys. MxNoteONE notices when you come back.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Every page you open joins the history, as in a browser. Hold the Back or Forward button (or use Go ▸ History) to jump several pages.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .onAppear { NotebookStore.shared.refreshNavigationKeys() }
            Section("Diagrams (draw.io)") {
                Picker("Editor:", selection: $drawioOffline) {
                    Text("Online (embed.diagrams.net)").tag(false)
                    Text(DrawioSource.offlineInstalled ? "Offline (the copy on this Mac)" : "Offline (download first)").tag(true)
                        .disabled(!DrawioSource.offlineInstalled)
                }
                Picker("Theme:", selection: $drawioTheme) {
                    ForEach(DrawioSource.themes, id: \.0) { Text($0.1).tag($0.0) }
                }
                HStack {
                    if DrawioSource.offlineInstalled {
                        Button("Remove Offline Copy") { drawioDownload.remove() }
                    } else {
                        Button("Download for Offline Use (about 50 MB)") { drawioDownload.start() }
                            .disabled(drawioDownload.progress != nil)
                    }
                    if drawioDownload.progress != nil { ProgressView().controlSize(.small) }
                    Spacer()
                }
                Text(drawioDownload.message.isEmpty
                     ? "Diagrams are draw.io's own editor — the one VS Code's draw.io extension uses — saved as .drawio.svg. Online needs the internet while editing; the offline copy (draw.io's web app from github.com/jgraph/drawio) doesn't."
                     : drawioDownload.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Python (Notebook Scripts)") {
                Picker("Run scripts with:", selection: $pythonPath) {
                    Text("Automatic (\(PythonLocator.candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "none found"))").tag("")
                    Divider()
                    ForEach(PythonLocator.all(), id: \.self) { Text($0).tag($0) }
                    if !pythonPath.isEmpty, !PythonLocator.all().contains(pythonPath) { Text(pythonPath).tag(pythonPath) }
                }
                HStack {
                    Button("Choose Python…") {
                        let panel = NSOpenPanel()
                        panel.message = "Choose a python3 program"
                        panel.canChooseDirectories = false
                        if panel.runModal() == .OK, let url = panel.url { pythonPath = url.path }
                    }
                    Spacer()
                }
                Text(PythonLocator.find() == nil
                     ? "No Python 3 found. Install Apple's Command Line Tools (xcode-select --install), the installer from python.org, or Homebrew (brew install python). Each notebook then gets its own environment for the packages its scripts need."
                     : "Each notebook's scripts run in the notebook's own environment, made from this Python; packages scripts need are installed there (Notebook Scripts ▸ Packages).")
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
