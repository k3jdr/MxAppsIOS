//
//  ScriptsWindow.swift
//  MxNoteONE
//
//  Window ▸ Notebook Scripts (⌥⌘P): a small Python IDE for the notebook.
//  Its scripts on the left; the editor (line numbers — click one for a
//  breakpoint — Python colouring, auto-indent) with the console under it;
//  an inspector with the debugger's variables, the notebook's tables (names,
//  tags, where they are — click to put a reference into the script), the
//  notebook's Python packages, and the mxnote reference. The toolbar runs and
//  debugs: Run ⌘R, Debug ⇧⌘R, Stop ⌘., Continue ⌃⌘Y, Step Over F6, Step Into
//  F7, Step Out F8, and Revert Last Run.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class ScriptsIDE {
    static let shared = ScriptsIDE()

    enum InspectorTab: String, CaseIterable, Identifiable {
        case variables = "Variables", tables = "Tables", packages = "Packages", help = "Help"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .variables: "ladybug"
            case .tables: "tablecells"
            case .packages: "shippingbox"
            case .help: "questionmark.circle"
            }
        }
    }

    /// The notebook whose scripts are shown (the one in use, unless another is picked).
    var notebookID: UUID?
    private(set) var files: [URL] = []
    private(set) var selected: URL?
    var text = "" {
        didSet { if text != oldValue { scheduleSave() } }
    }
    private(set) var savedText = ""
    var dirty: Bool { text != savedText }
    private(set) var breakpoints: [String: Set<Int>] = (UserDefaults.standard.dictionary(forKey: "scriptBreakpoints") as? [String: [Int]] ?? [:])
        .mapValues(Set.init)
    let session = ScriptSession()
    var inspector: InspectorTab = .tables
    var showInspector = true
    /// The notebook's tables (for the Tables tab), packages (Packages tab).
    private(set) var tables: [NotebookTable] = []
    private(set) var packages: [(name: String, version: String)] = []
    private(set) var packagesLoading = false
    weak var window: NSWindow?
    weak var editor: NSTextView?
    private var saveTask: Task<Void, Never>?

    var notebook: Notebook? {
        let store = NotebookStore.shared
        return notebookID.flatMap { store.notebook($0) } ?? store.currentNotebook ?? store.notebooks.first
    }

    var currentBreakpoints: Set<Int> { selected.map { breakpoints[$0.path] ?? [] } ?? [] }

    // MARK: Files

    func refresh() {
        guard let nb = notebook else { files = []; return }
        files = ScriptLibrary.scripts(nb)
        if selected == nil || !files.contains(selected!) { open(files.first) }
    }

    func open(_ url: URL?) {
        saveNow()
        selected = url
        let content = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        savedText = content
        text = content
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Writes the script being edited (the file is plain Python).
    func saveNow() {
        saveTask?.cancel()
        guard let selected, dirty else { return }
        do {
            try text.write(to: selected, atomically: true, encoding: .utf8)
            savedText = text
        } catch {
            session.log("Couldn't save \(selected.lastPathComponent): \(error.localizedDescription)", .error)
        }
    }

    func newScript(_ template: (name: String, summary: String, code: String)) {
        guard let nb = notebook, let url = ScriptLibrary.create(in: nb, name: template.name, code: template.code) else { return }
        refresh()
        open(url)
    }

    func rename(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = "Rename Script"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = url.deletingPathExtension().lastPathComponent
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        guard !name.isEmpty else { return }
        saveNow()
        let target = url.deletingLastPathComponent().appending(path: name + ".py")
        do {
            try FileManager.default.moveItem(at: url, to: target)
            if let marks = breakpoints.removeValue(forKey: url.path) { breakpoints[target.path] = marks; saveBreakpoints() }
            refresh()
            open(target)
        } catch {
            NotebookStore.shared.showAlert("Couldn't rename the script", error.localizedDescription)
        }
    }

    /// Moves a script to the Trash (it can be put back from there).
    func delete(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = "Move “\(url.lastPathComponent)” to the Trash?"
        alert.informativeText = "You can put it back from the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if selected == url { selected = nil; text = ""; savedText = "" }
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        refresh()
    }

    func importScripts() {
        guard let nb = notebook else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "py") ?? .plainText]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let dir = ScriptLibrary.folder(nb)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for url in panel.urls { try? FileManager.default.copyItem(at: url, to: dir.appending(path: url.lastPathComponent)) }
        refresh()
    }

    func revealFolder() {
        guard let nb = notebook else { return }
        let dir = ScriptLibrary.folder(nb)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([selected ?? dir])
    }

    // MARK: Breakpoints

    func toggleBreakpoint(_ line: Int) {
        guard let selected else { return }
        var marks = breakpoints[selected.path] ?? []
        if marks.contains(line) { marks.remove(line) } else { marks.insert(line) }
        breakpoints[selected.path] = marks.isEmpty ? nil : marks
        saveBreakpoints()
        session.updateBreakpoints(Array(marks))
    }

    func clearBreakpoints() {
        guard let selected else { return }
        breakpoints[selected.path] = nil
        saveBreakpoints()
        session.updateBreakpoints([])
    }

    private func saveBreakpoints() {
        UserDefaults.standard.set(breakpoints.mapValues { Array($0).sorted() }, forKey: "scriptBreakpoints")
    }

    // MARK: Running

    func run(debug: Bool) {
        guard let nb = notebook, let script = selected else { return NSSound.beep() }
        saveNow()
        let marks = Array(currentBreakpoints)
        Task { await session.run(script, notebook: nb, debug: debug, breakpoints: marks) }
    }

    /// Runs a script of the notebook (from a menu), showing its output here.
    func run(_ script: URL) {
        open(script)
        run(debug: false)
    }

    // MARK: Inspector data

    func loadTables() {
        guard let nb = notebook else { tables = []; return }
        tables = NotebookTables.all(in: nb).tables
    }

    func loadPackages() {
        guard let nb = notebook else { return }
        let env = NotebookPython(notebook: nb)
        packagesLoading = true
        Task {
            packages = await env.installed()
            packagesLoading = false
        }
    }

    func install(_ names: [String]) {
        guard let nb = notebook, !names.isEmpty else { return }
        let env = NotebookPython(notebook: nb)
        packagesLoading = true
        Task {
            if !env.isReady { _ = await env.prepare(log: { [weak self] t, e in self?.session.log(t, e ? .error : .info) }) }
            let ok = await env.install(names, log: { [weak self] t, e in self?.session.log(t, e ? .error : .info) })
            if ok { session.log("Installed \(names.joined(separator: ", ")).", .success) }
            packages = await env.installed()
            packagesLoading = false
        }
    }

    func uninstall(_ name: String) {
        guard let nb = notebook else { return }
        let env = NotebookPython(notebook: nb)
        packagesLoading = true
        Task {
            await env.uninstall(name, log: { [weak self] t, e in self?.session.log(t, e ? .error : .info) })
            packages = await env.installed()
            packagesLoading = false
        }
    }

    /// The window's keys (taken before the app's menus while the Scripts window is in front):
    /// ⌘R run, ⇧⌘R debug, ⌘. stop, ⌃⌘Y continue, F6 step over, F7 step into, F8 step out.
    func handleKey(_ event: NSEvent) -> Bool {
        guard let window, NSApp.keyWindow === window else { return false }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad, .capsLock])
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let paused = session.state == .paused
        switch (event.keyCode, mods) {
        case (97, []) where paused: session.command("next")
        case (98, []) where paused: session.command("step")
        case (100, []) where paused: session.command("return")
        case (97, []), (98, []), (100, []): return true   // not stopped: nothing to step (and no spell check here)
        default:
            switch (chars, mods) {
            case ("r", [.command]): if !session.state.busy { run(debug: false) }
            case ("r", [.command, .shift]): if !session.state.busy { run(debug: true) }
            case (".", [.command]): session.stop()
            case ("y", [.command, .control]): if paused { session.command("continue") }
            case ("s", [.command]): saveNow()
            default: return false
            }
        }
        return true
    }

    /// Puts code in at the caret (a reference from the Tables tab).
    func insert(_ code: String) {
        guard let editor else { text += code; return }
        editor.window?.makeFirstResponder(editor)
        editor.insertText(code, replacementRange: editor.selectedRange())
    }
}

// MARK: - The window

struct ScriptsWindowView: View {
    @Bindable private var ide = ScriptsIDE.shared
    @Bindable private var store = NotebookStore.shared

    var body: some View {
        let session = ide.session
        HSplitView {
            ScriptListView()
                .frame(minWidth: 170, idealWidth: 210, maxWidth: 320, maxHeight: .infinity)
            VSplitView {
                VStack(spacing: 0) {
                    if session.pythonMissing { PythonMissingBanner() }
                    if !session.missing.isEmpty { MissingPackagesBanner() }
                    if ide.selected != nil {
                        CodeEditor(text: $ide.text, breakpoints: ide.currentBreakpoints, pausedLine: session.pausedLine,
                                   errorLine: session.errorLine) { ide.toggleBreakpoint($0) }
                    } else {
                        ContentUnavailableView("No Script", systemImage: "chevron.left.forwardslash.chevron.right",
                                               description: Text("Make one with + (choose a template), or import a .py file."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minHeight: 200, idealHeight: 480, maxHeight: .infinity)
                ConsoleView()
                    .frame(minHeight: 110, idealHeight: 200, maxHeight: .infinity)
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
            if ide.showInspector {
                InspectorView()
                    .frame(minWidth: 250, idealWidth: 300, maxWidth: 460, maxHeight: .infinity)
            }
        }
        // Every pane fills the window (no empty bands above and below).
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar { toolbar }
        .navigationTitle(ide.notebook.map { "Scripts — \($0.name)" } ?? "Notebook Scripts")
        .navigationSubtitle(statusText)
        .background(WindowAccessor { ide.window = $0 })
        .onAppear { ide.refresh(); ide.loadTables() }
        .onChange(of: ide.notebookID) { ide.selected.map { _ in ide.open(nil) }; ide.refresh(); ide.loadTables(); ide.loadPackages() }
        .onDisappear { ide.saveNow() }
    }

    private var statusText: String {
        switch ide.session.state {
        case .idle: ide.selected?.lastPathComponent ?? ""
        case .preparing(let what): what
        case .running: "Running…"
        case .paused: "Paused at line \(ide.session.pausedLine ?? 0)"
        case .finished(let how): how
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        let session = ide.session
        let busy = session.state.busy, paused = session.state == .paused
        ToolbarItemGroup(placement: .navigation) {
            Menu {
                ForEach(store.notebooks) { nb in
                    Button { ide.notebookID = nb.id } label: {
                        if nb.id == ide.notebook?.id { Label(nb.name, systemImage: "checkmark") } else { Text(nb.name) }
                    }
                }
            } label: {
                Label(ide.notebook?.name ?? "Notebook", systemImage: "book.closed")
            }
            .help("The notebook whose scripts and tables these are")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { ide.run(debug: false) } label: { Label("Run", systemImage: "play.fill") }
                .disabled(busy || ide.selected == nil)
                .help("Run (⌘R)")
            Button { ide.run(debug: true) } label: { Label("Debug", systemImage: "ladybug") }
                .disabled(busy || ide.selected == nil)
                .help("Debug (⇧⌘R) — stops at breakpoints (click a line number), or at the first line")
            Button { session.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                .disabled(!busy)
                .help("Stop (⌘.)")
            Divider()
            Button { session.command("continue") } label: { Label("Continue", systemImage: "forward.frame") }
                .disabled(!paused)
                .help("Continue (⌃⌘Y)")
            Button { session.command("next") } label: { Label("Step Over", systemImage: "arrow.turn.down.right") }
                .disabled(!paused)
                .help("Step Over (F6)")
            Button { session.command("step") } label: { Label("Step Into", systemImage: "arrow.down.to.line") }
                .disabled(!paused)
                .help("Step Into (F7)")
            Button { session.command("return") } label: { Label("Step Out", systemImage: "arrow.up.to.line") }
                .disabled(!paused)
                .help("Step Out (F8)")
            Divider()
            Button { session.revert() } label: { Label("Revert Last Run", systemImage: "arrow.uturn.backward.circle") }
                .disabled(!session.canRevert || busy)
                .help("Revert Last Run — puts every page the last run changed back as it was")
            Button { ide.showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                .help("Show or hide the inspector (variables, tables, packages, help)")
        }
    }
}

/// Hands back the window a view is in.
struct WindowAccessor: NSViewRepresentable {
    let found: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { found(view.window) }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { found(nsView.window) }
    }
}

// MARK: - Scripts list

struct ScriptListView: View {
    @Bindable private var ide = ScriptsIDE.shared

    var body: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { ide.selected }, set: { ide.open($0) })) {
                Section("Scripts") {
                    ForEach(ide.files, id: \.self) { url in
                        Label(url.deletingPathExtension().lastPathComponent, systemImage: "doc.text")
                            .tag(url)
                            .contextMenu {
                                Button("Run") { ide.run(url) }
                                Button("Rename…") { ide.rename(url) }
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                Divider()
                                Button("Move to Trash…") { ide.delete(url) }
                            }
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack(spacing: 6) {
                Menu {
                    ForEach(ScriptLibrary.templates, id: \.name) { template in
                        Button { ide.newScript(template) } label: {
                            Text(template.name)
                            Text(template.summary)
                        }
                    }
                    Divider()
                    Button("Import .py Files…") { ide.importScripts() }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("New script (from a template), or import .py files")
                Spacer()
                Button { ide.revealFolder() } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless)
                    .help("Show the notebook's scripts folder in Finder — the scripts are plain .py files")
            }
            .padding(8)
        }
    }
}

// MARK: - Banners: Python, packages

struct MissingPackagesBanner: View {
    @Bindable private var ide = ScriptsIDE.shared

    var body: some View {
        let session = ide.session
        let packages = session.missing.map(NotebookPython.package(for:))
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "shippingbox").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("This script needs \(packages.joined(separator: ", "))")
                    .font(.headline)
                Text("They aren't installed in this notebook's Python environment yet. Install downloads them from the Python Package Index (pypi.org) with pip — this needs the internet — and adds them to the notebook's requirements.txt, so another Mac can install the same.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("pip install \(packages.joined(separator: " "))")
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Button("Install and Run") {
                    guard let nb = ide.notebook else { return }
                    Task { await session.installMissing(notebook: nb, thenRun: true) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.state.busy)
                Button("Install") {
                    guard let nb = ide.notebook else { return }
                    Task { await session.installMissing(notebook: nb, thenRun: false) }
                }
                .disabled(session.state.busy)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.1))
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct PythonMissingBanner: View {
    @Bindable private var ide = ScriptsIDE.shared
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Python 3 is needed to run scripts", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("MxNoteONE didn't find Python on this Mac. Install it one of these ways, then click Check Again:")
                .font(.callout)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("1.").bold()
                    Text("Apple's Command Line Tools (includes Python 3):")
                    Button("Install…") { runXcodeSelect() }
                }
                HStack {
                    Text("2.").bold()
                    Text("The installer from python.org:")
                    Button("Open python.org") { WebBrowser.open(URL(string: "https://www.python.org/downloads/macos/")!) }
                }
                HStack {
                    Text("3.").bold()
                    Text("With Homebrew, in Terminal:")
                    Text("brew install python").font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("brew install python", forType: .string)
                        copied = true
                    }
                }
                HStack {
                    Text("4.").bold()
                    Text("Already have one somewhere else?")
                    Button("Choose Python…") { choosePython() }
                }
            }
            .font(.callout)
            HStack {
                Spacer()
                Button("Check Again") { ide.session.pythonMissing = PythonLocator.find() == nil }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.1))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func runXcodeSelect() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        p.arguments = ["--install"]
        try? p.run()
    }

    private func choosePython() {
        let panel = NSOpenPanel()
        panel.message = "Choose a python3 program (for example /opt/homebrew/bin/python3)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: PythonLocator.key)
        ide.session.pythonMissing = PythonLocator.find() == nil
    }
}

// MARK: - Console

struct ConsoleView: View {
    @Bindable private var ide = ScriptsIDE.shared
    @State private var entry = ""

    var body: some View {
        let session = ide.session
        VStack(spacing: 0) {
            HStack {
                Text("Console").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { session.clearConsole() } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Clear the console")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(session.console) { line in
                            Text(line.text.isEmpty ? " " : line.text)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(color(line.kind))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: session.console.count) {
                    if let last = session.console.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            if session.state == .paused || session.state == .running {
                Divider()
                HStack {
                    Image(systemName: session.state == .paused ? "magnifyingglass" : "keyboard").foregroundStyle(.secondary)
                    TextField(session.state == .paused ? "Evaluate an expression (e.g. len(rows), row.values)" : "Input for the script (input())",
                              text: $entry)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5, design: .monospaced))
                        .onSubmit {
                            if session.state == .paused { session.evaluate(entry) } else { session.input(entry) }
                            entry = ""
                        }
                }
                .padding(6)
            }
        }
    }

    private func color(_ kind: ScriptSession.Line.Kind) -> Color {
        switch kind {
        case .output: .primary
        case .error: .red
        case .info: .secondary
        case .success: .green
        case .command: .accentColor
        }
    }
}

// MARK: - Inspector

struct InspectorView: View {
    @Bindable private var ide = ScriptsIDE.shared

    var body: some View {
        VStack(spacing: 0) {
            // Icon tabs with the tab's name beside the selected one — they fit the narrowest pane.
            HStack(spacing: 2) {
                ForEach(ScriptsIDE.InspectorTab.allCases) { tab in
                    Button { ide.inspector = tab } label: {
                        HStack(spacing: 4) {
                            Image(systemName: tab.symbol)
                            if ide.inspector == tab { Text(tab.rawValue).lineLimit(1) }
                        }
                        .font(.system(size: 12, weight: ide.inspector == tab ? .semibold : .regular))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .frame(maxWidth: ide.inspector == tab ? .infinity : nil)
                        .background(ide.inspector == tab ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(tab.rawValue)
                }
            }
            .padding(8)
            Divider()
            switch ide.inspector {
            case .variables: VariablesPane()
            case .tables: TablesPane()
            case .packages: PackagesPane()
            case .help: HelpPane()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: ide.session.state) { if ide.session.state == .paused { ide.inspector = .variables } }
    }
}

struct VariablesPane: View {
    @Bindable private var ide = ScriptsIDE.shared

    var body: some View {
        let session = ide.session
        if session.state == .paused {
            List {
                Section("Stopped at line \(session.pausedLine ?? 0)") {
                    ForEach(Array(session.stack.enumerated()), id: \.offset) { _, frame in
                        Label("\(frame.function == "<module>" ? "script" : frame.function)() — line \(frame.line)", systemImage: "list.bullet.indent")
                            .font(.caption)
                    }
                }
                Section("Variables") {
                    if session.variables.isEmpty { Text("None yet").foregroundStyle(.secondary) }
                    ForEach(session.variables) { v in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(v.name).font(.system(size: 12, weight: .semibold, design: .monospaced))
                                Text(v.type).font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(v.value).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(4)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        } else {
            ContentUnavailableView("Not Debugging", systemImage: "ladybug",
                                   description: Text("Click a line number to set a breakpoint, then Debug (⇧⌘R). The script stops there and its variables show here; step with F6, F7, F8."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct TablesPane: View {
    @Bindable private var ide = ScriptsIDE.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(ide.tables.count) table\(ide.tables.count == 1 ? "" : "s") in the notebook").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { ide.loadTables() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Read the notebook's tables again")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            List {
                ForEach(ide.tables) { t in
                    DisclosureGroup {
                        Text("Columns: " + headers(t).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                        ForEach(Array((t.data.rowTags ?? [:]).sorted { $0.key < $1.key }), id: \.key) { row, tags in
                            Button { ide.insert(reference(t) + ".row(tag=\"\(tags[0])\")") } label: {
                                Label("Row \(row + 1): " + tags.map { "#" + $0 }.joined(separator: " "), systemImage: "line.3.horizontal")
                            }
                            .buttonStyle(.plain)
                        }
                        ForEach(Array((t.data.cellTags ?? [:]).sorted { $0.key < $1.key }), id: \.key) { key, tags in
                            Button { ide.insert("mx.cell(\"\(tags[0])\")") } label: {
                                Label(cellName(key) + ": " + tags.map { "#" + $0 }.joined(separator: " "), systemImage: "square.dashed")
                            }
                            .buttonStyle(.plain)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(t.data.name ?? "Unnamed table").font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(t.data.name == nil ? .secondary : .primary)
                                ForEach(t.data.tags ?? [], id: \.self) { tag in
                                    Text("#" + tag).font(.caption2).padding(.horizontal, 4).background(Color.accentColor.opacity(0.15), in: Capsule())
                                }
                            }
                            Text("\(t.section) › \(t.page) · \(t.data.rows.count)×\(t.data.columnCount)").font(.caption).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { ide.insert(reference(t)) }
                        .help("Double-click to put \(reference(t)) into the script")
                    }
                }
            }
            Text("Name tables and tag rows and cells in the notebook: select a table ▸ Table tab ▸ Name & Tags. Double-click to insert a reference.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(8)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { if ide.tables.isEmpty { ide.loadTables() } }
    }

    private func headers(_ t: NotebookTable) -> [String] {
        guard t.data.headerRow, let first = t.data.rows.first else { return [] }
        return first.enumerated().map { $0.element.isEmpty ? TableData.columnName($0.offset) : $0.element }
    }

    private func reference(_ t: NotebookTable) -> String {
        if let name = t.data.name { return "mx.table(\"\(name)\")" }
        if let tag = t.data.tags?.first { return "mx.tables(tag=\"\(tag)\")[0]" }
        return "mx.tables(page=\"\(t.page)\")[0]"
    }

    private func cellName(_ key: String) -> String {
        guard let cell = TableData.cell(key) else { return key }
        return TableData.columnName(cell.column) + "\(cell.row + 1)"
    }
}

struct PackagesPane: View {
    @Bindable private var ide = ScriptsIDE.shared
    @State private var name = ""

    var body: some View {
        let python = PythonLocator.find()
        VStack(alignment: .leading, spacing: 8) {
            Group {
                LabeledContent("Python", value: python?.path ?? "not found")
                if let nb = ide.notebook {
                    let env = NotebookPython(notebook: nb)
                    LabeledContent("Environment", value: env.isReady ? "ready" : "made on the first run")
                    Text("Packages installed here are this notebook's own; requirements.txt (in the scripts folder) lists them so they can be installed again on another Mac.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.caption)
            HStack {
                TextField("Package (e.g. pandas, requests)", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(install)
                Button("Install", action: install)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || ide.packagesLoading)
            }
            HStack {
                if ide.packagesLoading { ProgressView().controlSize(.small) }
                Text("Installed").font(.caption.bold())
                Spacer()
                Button("Install requirements.txt") {
                    guard let nb = ide.notebook else { return }
                    ide.install(NotebookPython(notebook: nb).requiredPackages())
                }
                .font(.caption)
                .disabled(ide.packagesLoading)
            }
            List(ide.packages, id: \.name) { p in
                HStack {
                    Text(p.name).font(.system(size: 12, design: .monospaced))
                    Spacer()
                    Text(p.version).font(.caption).foregroundStyle(.secondary)
                    Button { ide.uninstall(p.name) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Uninstall \(p.name)")
                }
            }
            .frame(minHeight: 120)
        }
        .padding(10)
        .onAppear { ide.loadPackages() }
    }

    private func install() {
        let names = name.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        name = ""
        ide.install(names)
    }
}

struct HelpPane: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("mxnote").font(.headline)
                Text("Scripts are Python files kept with the notebook. Start them with **import mxnote as mx** to work with the notebook's tables — every page, every section (locked sections aside). Changes appear in the notebook as the script runs; **Revert Last Run** puts them back.")
                    .fixedSize(horizontal: false, vertical: true)
                Text(PythonSupport.mxnote.components(separatedBy: "\"\"\"").dropFirst().first ?? "")
                    .font(.system(size: 10.5, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Debugging").font(.headline)
                Text("Click a line number for a breakpoint (again to remove it). **Debug** (⇧⌘R) runs to the first breakpoint — or stops at the first line when there are none. Then **Step Over** (F6) runs the line, **Step Into** (F7) goes into a function of the script, **Step Out** (F8) finishes the function, **Continue** (⌃⌘Y) runs to the next breakpoint. While stopped, type an expression in the console to see its value.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Packages").font(.headline)
                Text("Each notebook has its own Python environment. When a script imports something that isn't installed (pandas, requests…), a banner offers **Install and Run** — pip downloads it and it's added to requirements.txt. The Packages tab lists, installs and uninstalls packages.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)
            .padding(12)
        }
    }
}

// MARK: - The code editor

/// The Python editor: line numbers (click for a breakpoint), colouring, auto-indent, and the debugger's line.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    let breakpoints: Set<Int>
    let pausedLine: Int?
    let errorLine: Int?
    let toggle: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = EditorScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        let theme = CodeTheme.current
        let tv = PythonTextView(frame: .zero)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.font = PythonTextView.font
        tv.backgroundColor = theme.background
        tv.insertionPointColor = theme.text
        tv.textColor = theme.text
        tv.textContainerInset = NSSize(width: 6, height: 6)
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.string = text
        tv.delegate = context.coordinator
        scroll.documentView = tv
        scroll.backgroundColor = theme.background
        let ruler = LineNumberRuler(textView: tv)
        ruler.toggle = toggle
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        context.coordinator.textView = tv
        context.coordinator.ruler = ruler
        ScriptsIDE.shared.editor = tv
        context.coordinator.highlight()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let tv = c.textView else { return }
        if tv.string != text {
            tv.string = text
            c.highlight()
        }
        c.ruler?.breakpoints = breakpoints
        c.ruler?.pausedLine = pausedLine
        c.ruler?.toggle = toggle
        c.ruler?.needsDisplay = true
        c.markLines(paused: pausedLine, error: errorLine)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        weak var textView: PythonTextView?
        weak var ruler: LineNumberRuler?
        private var pending: DispatchWorkItem?

        init(_ parent: CodeEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
            ruler?.needsDisplay = true
            pending?.cancel()
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.highlight() } }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }

        /// Python colouring (the code theme's colours).
        func highlight() {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let theme = CodeTheme.current
            let all = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes([.font: PythonTextView.font, .foregroundColor: theme.text], range: all)
            for (range, kind) in CodeHighlighter.tokens(storage.string, language: .python) {
                if let color = theme.colors[kind], NSMaxRange(range) <= storage.length {
                    storage.addAttribute(.foregroundColor, value: color, range: range)
                }
            }
            storage.endEditing()
            markLines(paused: parent.pausedLine, error: parent.errorLine)
        }

        /// The debugger's line (yellow) and the line an error came from (red).
        func markLines(paused: Int?, error: Int?) {
            guard let tv = textView, let lm = tv.layoutManager else { return }
            let ns = tv.string as NSString
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: ns.length))
            func range(of line: Int) -> NSRange? {
                var index = 0, current = 1
                while current < line, index < ns.length {
                    let r = ns.lineRange(for: NSRange(location: index, length: 0))
                    index = NSMaxRange(r)
                    current += 1
                }
                guard current == line, index <= ns.length else { return nil }
                return ns.lineRange(for: NSRange(location: min(index, ns.length), length: 0))
            }
            if let error, let r = range(of: error) {
                lm.addTemporaryAttribute(.backgroundColor, value: NSColor.systemRed.withAlphaComponent(0.28), forCharacterRange: r)
            }
            if let paused, let r = range(of: paused) {
                lm.addTemporaryAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.35), forCharacterRange: r)
                tv.scrollRangeToVisible(r)
            }
        }
    }
}

/// The editor's scroll view: the line numbers beside the text, never over it.
final class EditorScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard rulersVisible, let ruler = verticalRulerView else { return }
        let width = ruler.requiredThickness
        var clip = contentView.frame
        if clip.minX < width {
            clip.size.width -= width - clip.minX
            clip.origin.x = width
            contentView.frame = clip
        }
        ruler.frame = NSRect(x: 0, y: clip.minY, width: width, height: clip.height)
    }
}

/// Typing Python: Tab is four spaces, Return keeps the indent (and adds one after a colon), ⌘/ comments lines.
final class PythonTextView: NSTextView {
    static let font = NSFont(name: "Menlo", size: 12.5) ?? .monospacedSystemFont(ofSize: 12.5, weight: .regular)

    override func mouseMoved(with event: NSEvent) { if pointerInside(event) { super.mouseMoved(with: event) } }
    override func cursorUpdate(with event: NSEvent) { if pointerInside(event) { super.cursorUpdate(with: event) } }

    override func insertTab(_ sender: Any?) {
        insertText("    ", replacementRange: selectedRange())
    }

    override func insertBacktab(_ sender: Any?) {
        let ns = string as NSString
        let line = ns.lineRange(for: NSRange(location: selectedRange().location, length: 0))
        let leading = ns.substring(with: line).prefix { $0 == " " }.count
        let remove = min(4, leading)
        guard remove > 0 else { return }
        let range = NSRange(location: line.location, length: remove)
        if shouldChangeText(in: range, replacementString: "") {
            replaceCharacters(in: range, with: "")
            didChangeText()
        }
    }

    override func insertNewline(_ sender: Any?) {
        let ns = string as NSString
        let caret = selectedRange().location
        let line = ns.lineRange(for: NSRange(location: caret, length: 0))
        let before = ns.substring(with: NSRange(location: line.location, length: caret - line.location))
        var indent = String(before.prefix { $0 == " " })
        if before.trimmingCharacters(in: .whitespaces).hasSuffix(":") { indent += "    " }
        insertText("\n" + indent, replacementRange: selectedRange())
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "/" {
            toggleComment()
            return
        }
        super.keyDown(with: event)
    }

    /// ⌘/: comments the selected lines out (or back in).
    func toggleComment() {
        let ns = string as NSString
        let lines = ns.lineRange(for: selectedRange())
        let text = ns.substring(with: lines)
        var parts = text.components(separatedBy: "\n")
        let trailing = parts.last == ""
        if trailing { parts.removeLast() }
        let commented = parts.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        let changed = parts.map { line -> String in
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
            let indent = line.prefix { $0 == " " }
            let rest = line.dropFirst(indent.count)
            if commented {
                return String(indent) + (rest.hasPrefix("# ") ? String(rest.dropFirst(2)) : String(rest.dropFirst()))
            }
            return String(indent) + "# " + rest
        }.joined(separator: "\n") + (trailing ? "\n" : "")
        if shouldChangeText(in: lines, replacementString: changed) {
            replaceCharacters(in: lines, with: changed)
            didChangeText()
            setSelectedRange(NSRange(location: lines.location, length: (changed as NSString).length))
        }
    }
}

/// Line numbers down the left of the editor; a click sets or clears a breakpoint (a red marker).
final class LineNumberRuler: NSRulerView {
    weak var textView: NSTextView?
    var breakpoints: Set<Int> = []
    var pausedLine: Int?
    var toggle: ((Int) -> Void)?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSView.boundsDidChangeNotification,
                                               object: textView.enclosingScrollView?.contentView)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func redraw() { needsDisplay = true }

    override var isFlipped: Bool { true }

    /// Each line's first character and its y in the ruler.
    private func visibleLines() -> [(line: Int, y: CGFloat, height: CGFloat)] {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer, let scroll = scrollView else { return [] }
        let ns = tv.string as NSString
        let visible = scroll.contentView.bounds
        let glyphs = lm.glyphRange(forBoundingRect: visible, in: tc)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        // Line number of the first visible character.
        var line = 1
        ns.enumerateSubstrings(in: NSRange(location: 0, length: chars.location), options: [.byLines, .substringNotRequired]) { _, _, _, _ in line += 1 }
        var result: [(Int, CGFloat, CGFloat)] = []
        var index = chars.location
        repeat {
            let lineRange = ns.lineRange(for: NSRange(location: min(index, max(0, ns.length)), length: 0))
            let glyph = lm.glyphIndexForCharacter(at: min(lineRange.location, max(0, ns.length - 1)))
            var rect = ns.length == 0 ? NSRect(x: 0, y: 0, width: 0, height: PythonTextView.font.boundingRectForFont.height)
                : lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            rect.origin.y += tv.textContainerInset.height - visible.minY
            result.append((line, rect.minY, rect.height))
            line += 1
            index = NSMaxRange(lineRange)
            if index >= ns.length || rect.minY > visible.height { break }
        } while index < NSMaxRange(chars) + 1
        // The empty line after a final newline.
        if ns.length > 0, ns.hasSuffix("\n"), let last = result.last, last.1 + last.2 <= visible.height {
            result.append((line, last.1 + last.2, last.2))
        }
        return result
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        let theme = CodeTheme.current
        theme.background.blended(withFraction: 0.06, of: theme.text)?.setFill()
        bounds.fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular),
                                                    .foregroundColor: theme.text.withAlphaComponent(0.5)]
        for (line, y, height) in visibleLines() {
            if breakpoints.contains(line) {
                let marker = NSBezierPath()
                let r = NSRect(x: 3, y: y + 1, width: ruleThickness - 8, height: max(12, height - 2))
                marker.move(to: NSPoint(x: r.minX, y: r.minY))
                marker.line(to: NSPoint(x: r.maxX - 5, y: r.minY))
                marker.line(to: NSPoint(x: r.maxX, y: r.midY))
                marker.line(to: NSPoint(x: r.maxX - 5, y: r.maxY))
                marker.line(to: NSPoint(x: r.minX, y: r.maxY))
                marker.close()
                NSColor.systemBlue.withAlphaComponent(0.85).setFill()
                marker.fill()
            }
            if line == pausedLine {
                let arrow = NSBezierPath()
                arrow.move(to: NSPoint(x: 2, y: y + 2))
                arrow.line(to: NSPoint(x: 9, y: y + height / 2))
                arrow.line(to: NSPoint(x: 2, y: y + height - 2))
                NSColor.systemYellow.setFill()
                arrow.fill()
            }
            let label = "\(line)" as NSString
            var a = attrs
            if breakpoints.contains(line) { a[.foregroundColor] = NSColor.white }
            let size = label.size(withAttributes: a)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y + (height - size.height) / 2), withAttributes: a)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let hit = visibleLines().first(where: { p.y >= $0.y && p.y < $0.y + $0.height }) else { return }
        toggle?(hit.line)
        needsDisplay = true
    }
}
