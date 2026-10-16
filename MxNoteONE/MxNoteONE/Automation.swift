//
//  Automation.swift
//  MxNoteONE
//
//  Notebook scripts: Python that works on the notebook's tables.
//
//  • Scripts are ordinary .py files in the notebook's "scripts" folder (with a
//    requirements.txt for the packages they need), so they stay plain Python and
//    travel with the notebook — they belong to the notebook, not to a page.
//  • Each notebook gets its own Python environment (a virtual environment in
//    Application Support, made from the Python found on the Mac), where missing
//    packages are installed with one click.
//  • A run gets a snapshot of every table in the notebook (names, tags, rows,
//    values); the script's changes come back as it runs and are put into the
//    tables — the page on screen at once, other pages in the background.
//    Revert Last Run puts every page it touched back.
//

import AppKit
import Observation

// MARK: - Processes

/// A child process whose output arrives line by line (standard output and standard error).
final class StreamingProcess: @unchecked Sendable {
    let process = Process()
    private let output = Pipe(), errors = Pipe(), input = Pipe()
    private var pending: [Bool: Data] = [false: Data(), true: Data()]
    private let lock = NSLock()
    private var onLine: (@MainActor (String, Bool) -> Void)?

    init(_ executable: URL, _ arguments: [String], environment: [String: String] = [:], directory: URL? = nil) {
        process.executableURL = executable
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        for (k, v) in environment { env[k] = v }
        env["PYTHONIOENCODING"] = "utf-8"
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env
        if let directory { process.currentDirectoryURL = directory }
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = input
    }

    func start(onLine: @escaping @MainActor (String, Bool) -> Void, onExit: @escaping @MainActor (Int32) -> Void) throws {
        self.onLine = onLine
        for (pipe, isError) in [(output, false), (errors, true)] {
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                self?.take(handle.availableData, isError: isError)
            }
        }
        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            // What's left in the pipes, then the end.
            for (pipe, isError) in [(self.output, false), (self.errors, true)] {
                pipe.fileHandleForReading.readabilityHandler = nil
                self.take(pipe.fileHandleForReading.readDataToEndOfFile(), isError: isError)
                self.flush(isError: isError)
            }
            let status = proc.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { onExit(status) } }
        }
        try process.run()
    }

    private func take(_ data: Data, isError: Bool) {
        guard !data.isEmpty else { return }
        lock.lock()
        var buffer = pending[isError, default: Data()] + data
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
            buffer = Data(buffer[buffer.index(after: newline)...])
        }
        pending[isError] = buffer
        lock.unlock()
        deliver(lines, isError: isError)
    }

    private func flush(isError: Bool) {
        lock.lock()
        let rest = pending[isError] ?? Data()
        pending[isError] = Data()
        lock.unlock()
        if !rest.isEmpty { deliver([String(decoding: rest, as: UTF8.self)], isError: isError) }
    }

    private func deliver(_ lines: [String], isError: Bool) {
        guard !lines.isEmpty, let onLine else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { for line in lines { onLine(line, isError) } } }
    }

    /// A line to the process's standard input.
    func send(_ line: String) {
        try? input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
    }

    func stop() {
        if process.isRunning { process.interrupt() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { [process] in
            if process.isRunning { process.terminate() }
        }
    }

    /// Runs a short command to the end: its exit status and output.
    static func run(_ executable: URL, _ arguments: [String], environment: [String: String] = [:],
                    onLine: (@MainActor (String, Bool) -> Void)? = nil) async -> (status: Int32, output: String) {
        await withCheckedContinuation { continuation in
            let p = StreamingProcess(executable, arguments, environment: environment)
            var text = ""
            do {
                try p.start(onLine: { line, isError in
                    if !isError { text += line + "\n" }
                    onLine?(line, isError)
                }, onExit: { status in
                    // Lines delivered before the exit (same queue, in order).
                    continuation.resume(returning: (status, text))
                    _ = p
                })
            } catch {
                continuation.resume(returning: (-1, error.localizedDescription))
            }
        }
    }
}

// MARK: - Python

enum PythonLocator {
    static let key = "pythonPath"

    /// A Python chosen in Settings (else the first one found).
    static var custom: String? {
        guard let path = UserDefaults.standard.string(forKey: key), !path.isEmpty else { return nil }
        return path
    }

    /// Where Python is usually installed: Homebrew, python.org, pyenv, conda, and Apple's (with the developer tools).
    static var candidates: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var list = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3",
                    "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
                    home + "/.pyenv/shims/python3", home + "/miniconda3/bin/python3", home + "/anaconda3/bin/python3",
                    "/opt/anaconda3/bin/python3", "/opt/miniconda3/bin/python3"]
        // Apple's /usr/bin/python3 only works once the developer tools are installed (else it asks to install them).
        if hasDeveloperTools { list.append("/usr/bin/python3") }
        return list
    }

    static var hasDeveloperTools: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: "/Library/Developer/CommandLineTools/usr/bin/python3")
            || fm.fileExists(atPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/python3")
    }

    /// The Python scripts are run with (to make each notebook's environment from).
    static func find() -> URL? {
        let fm = FileManager.default
        let paths = (custom.map { [$0] } ?? []) + candidates
        return paths.first { fm.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// Every Python found (for Settings).
    static func all() -> [String] {
        candidates.filter { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// A notebook's own Python environment: its packages, kept apart from other notebooks and the system.
@MainActor
final class NotebookPython {
    let notebookID: UUID
    let scriptsFolder: URL

    init(notebook: Notebook) {
        notebookID = notebook.id
        scriptsFolder = ScriptLibrary.folder(notebook)
    }

    var environment: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "MxNoteONE/environments/\(notebookID.uuidString)")
    }
    var python: URL { environment.appending(path: "bin/python3") }
    var requirements: URL { scriptsFolder.appending(path: "requirements.txt") }
    var isReady: Bool { FileManager.default.isExecutableFile(atPath: python.path) }

    /// Makes the environment (first run), and installs what requirements.txt lists.
    func prepare(log: @escaping @MainActor (String, Bool) -> Void) async -> Bool {
        if isReady { return true }
        guard let base = PythonLocator.find() else { return false }
        log("Setting up this notebook's Python environment (once) with \(base.path)…", false)
        try? FileManager.default.createDirectory(at: environment.deletingLastPathComponent(), withIntermediateDirectories: true)
        let made = await StreamingProcess.run(base, ["-m", "venv", environment.path], onLine: log)
        guard made.status == 0, isReady else {
            log("Couldn't make the Python environment (\(base.path) -m venv).", true)
            return false
        }
        if !requiredPackages().isEmpty {
            _ = await install(requiredPackages(), log: log, remember: false)
        }
        return true
    }

    /// The packages requirements.txt lists.
    func requiredPackages() -> [String] {
        guard let text = try? String(contentsOf: requirements, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    struct Check {
        var missing: [String] = []
        var syntaxError: (line: Int, message: String)?
        var version = ""
    }

    /// The script's syntax, and the modules it imports that aren't installed.
    func check(_ script: URL) async -> Check {
        let result = await StreamingProcess.run(python, [PythonSupport.folder.appending(path: "mxcheck.py").path, script.path])
        var check = Check()
        guard let json = result.output.split(separator: "\n").last,
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return check }
        check.missing = object["missing"] as? [String] ?? []
        check.version = object["version"] as? String ?? ""
        if let error = object["syntaxError"] as? [String: Any] {
            check.syntaxError = ((error["line"] as? Int) ?? 1, (error["message"] as? String) ?? "Syntax error")
        }
        return check
    }

    /// Installs packages with pip (and adds them to requirements.txt, so the notebook remembers what it needs).
    func install(_ packages: [String], log: @escaping @MainActor (String, Bool) -> Void, remember: Bool = true) async -> Bool {
        guard !packages.isEmpty else { return true }
        log("pip install \(packages.joined(separator: " "))", false)
        let result = await StreamingProcess.run(python, ["-m", "pip", "install", "--disable-pip-version-check", "--no-input"] + packages,
                                                onLine: log)
        guard result.status == 0 else {
            log("pip couldn't install \(packages.joined(separator: ", ")) (see above). Check the name on pypi.org, or your internet connection.", true)
            return false
        }
        if remember {
            var listed = requiredPackages()
            for p in packages where !listed.contains(where: { $0.lowercased() == p.lowercased() }) { listed.append(p) }
            try? FileManager.default.createDirectory(at: scriptsFolder, withIntermediateDirectories: true)
            try? (listed.joined(separator: "\n") + "\n").write(to: requirements, atomically: true, encoding: .utf8)
        }
        return true
    }

    func uninstall(_ package: String, log: @escaping @MainActor (String, Bool) -> Void) async {
        _ = await StreamingProcess.run(python, ["-m", "pip", "uninstall", "-y", package], onLine: log)
        let listed = requiredPackages().filter { $0.lowercased() != package.lowercased() }
        try? (listed.joined(separator: "\n") + (listed.isEmpty ? "" : "\n")).write(to: requirements, atomically: true, encoding: .utf8)
    }

    /// What's installed: name and version.
    func installed() async -> [(name: String, version: String)] {
        guard isReady else { return [] }
        let result = await StreamingProcess.run(python, ["-m", "pip", "list", "--format=json", "--disable-pip-version-check"])
        guard let list = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [[String: String]] else { return [] }
        return list.compactMap { item in item["name"].map { ($0, item["version"] ?? "") } }
            .filter { !["pip", "setuptools"].contains($0.name.lowercased()) }
    }

    /// The package that gives a module (they're mostly the same name).
    static func package(for module: String) -> String {
        let names = ["cv2": "opencv-python", "PIL": "Pillow", "sklearn": "scikit-learn", "yaml": "PyYAML", "bs4": "beautifulsoup4",
                     "dateutil": "python-dateutil", "docx": "python-docx", "pptx": "python-pptx", "dotenv": "python-dotenv",
                     "Crypto": "pycryptodome", "jwt": "PyJWT", "serial": "pyserial", "fitz": "PyMuPDF", "attr": "attrs",
                     "OpenSSL": "pyOpenSSL", "googleapiclient": "google-api-python-client", "Levenshtein": "python-Levenshtein",
                     "skimage": "scikit-image", "lxml": "lxml", "openpyxl": "openpyxl", "xlrd": "xlrd", "tabulate": "tabulate"]
        return names[module] ?? module
    }
}

// MARK: - The notebook's tables

/// A table somewhere in the notebook.
struct NotebookTable: Identifiable {
    let id: UUID          // the table's element on its page
    let ref: PageRef
    var data: TableData
    let width: Double
    let page: String
    let section: String
}

@MainActor
enum NotebookTables {
    /// Every table in a notebook (sections that are locked are left out — and counted).
    static func all(in notebook: Notebook) -> (tables: [NotebookTable], locked: Int) {
        let store = NotebookStore.shared
        store.canvas?.flush()
        var found: [NotebookTable] = [], locked = 0
        for node in notebook.manifest.sections.flattenedSections {
            let section = SectionRef(notebookID: notebook.id, sectionID: node.id)
            if store.isLocked(section) { locked += 1; continue }
            for meta in notebook.sections[node.id]?.pages ?? [] {
                let ref = PageRef(notebookID: notebook.id, sectionID: node.id, pageID: meta.id)
                guard let content = store.loadPageWithTables(ref) else { continue }
                for element in content.elements where element.kind == .table {
                    guard let table = element.table else { continue }
                    found.append(NotebookTable(id: element.id, ref: ref, data: table, width: element.width,
                                               page: meta.displayTitle, section: node.name))
                }
            }
        }
        return (found, locked)
    }

    /// What a script sees: every table with its name, tags, texts, what each cell shows and its number.
    static func snapshot(_ tables: [NotebookTable], notebook: Notebook) -> Data {
        var list: [[String: Any]] = []
        for t in tables {
            let model = TableModel(data: t.data, width: CGFloat(t.width))
            var shown: [[String]] = [], numbers: [[Any]] = []
            for r in 0..<model.rowCount {
                var s: [String] = [], n: [Any] = []
                for c in 0..<model.columnCount {
                    let cell = CellRef(row: r, column: c)
                    s.append(model.shownText(cell).string)
                    if case .number(let d) = model.value(cell), d.isFinite { n.append(d) } else { n.append(NSNull()) }
                }
                shown.append(s)
                numbers.append(n)
            }
            var item: [String: Any] = ["id": t.id.uuidString, "page": t.page, "section": t.section, "headerRow": t.data.headerRow,
                                       "rows": t.data.rows, "shown": shown, "numbers": numbers, "tags": t.data.tags ?? []]
            if let name = t.data.name { item["name"] = name }
            item["rowTags"] = Dictionary(uniqueKeysWithValues: (t.data.rowTags ?? [:]).map { ("\($0.key)", $0.value) })
            item["cellTags"] = t.data.cellTags ?? [:]
            list.append(item)
        }
        let root: [String: Any] = ["notebook": ["name": notebook.name, "id": notebook.id.uuidString], "tables": list]
        return (try? JSONSerialization.data(withJSONObject: root)) ?? Data()
    }

    /// Other tables in the notebook with this name (names should be unique, for scripts to find).
    static func others(named name: String, except id: UUID, in notebook: Notebook) -> [NotebookTable] {
        all(in: notebook).tables.filter { $0.id != id && ($0.data.name ?? "").lowercased() == name.lowercased() }
    }
}

// MARK: - Putting a script's changes into the tables

@MainActor
final class TableApplier {
    let notebook: Notebook
    private let locations: [UUID: PageRef]
    /// Pages changed in the background (saved as the run goes), and every touched page as it was before.
    private var pages: [PageRef: PageContent] = [:]
    private(set) var backups: [PageRef: PageContent] = [:]
    private var liveModels: [UUID: TableModel] = [:]
    private var saveTask: Task<Void, Never>?
    private(set) var changes = 0
    private(set) var touchedTables = Set<UUID>()
    private var store: NotebookStore { .shared }

    init(notebook: Notebook, tables: [NotebookTable]) {
        self.notebook = notebook
        locations = Dictionary(tables.map { ($0.id, $0.ref) }, uniquingKeysWith: { a, _ in a })
    }

    /// The table on the page on screen, if that's where it is.
    private func liveModel(_ id: UUID, _ ref: PageRef) -> TableModel? {
        guard store.canvas?.ref == ref, pages[ref] == nil else { return nil }
        return store.canvas?.canvas.elementViews.compactMap { $0 as? TableElementView }.first { $0.element.id == id }?.model
    }

    private func backUp(_ ref: PageRef) {
        guard backups[ref] == nil else { return }
        if store.canvas?.ref == ref { store.canvas?.flush() }
        if let content = store.loadPage(ref) { backups[ref] = content }
    }

    /// One change from the script.
    func apply(_ op: [String: Any]) {
        guard let tid = op["t"] as? String, let id = UUID(uuidString: tid), let ref = locations[id] else { return }
        backUp(ref)
        if let model = liveModel(id, ref) {
            perform(op, on: model, live: true)
            liveModels[id] = model
        } else {
            guard var content = pages[ref] ?? store.loadPage(ref),
                  let i = content.elements.firstIndex(where: { $0.id == id }), let table = content.elements[i].table else { return }
            let model = TableModel(data: table, width: CGFloat(content.elements[i].width))
            perform(op, on: model, live: false)
            content.elements[i].table = model.data
            content.elements[i].width = Double(model.width)
            pages[ref] = content
            scheduleSave()
        }
        changes += 1
        touchedTables.insert(id)
    }

    private func perform(_ op: [String: Any], on model: TableModel, live: Bool) {
        func int(_ key: String) -> Int { (op[key] as? Int) ?? (op[key] as? NSNumber)?.intValue ?? 0 }
        func put(_ text: String, _ cell: CellRef) {
            guard model.contains(cell) else { return }
            model.store(NSAttributedString(string: text, attributes: model.typingAttributes(cell)), in: cell)
        }
        switch op["op"] as? String {
        case "set":
            put(op["text"] as? String ?? "", CellRef(row: int("r"), column: int("c")))
        case "insertRow":
            let at = max(0, min(int("at"), model.rowCount))
            model.insertRow(at: at)
            for (c, text) in (op["texts"] as? [String] ?? []).enumerated() where !text.isEmpty { put(text, CellRef(row: at, column: c)) }
        case "deleteRow":
            if model.rowCount > 1, int("r") < model.rowCount { model.deleteRow(int("r")) }
        case "insertColumn":
            let at = max(0, min(int("at"), model.columnCount))
            if live { model.addColumn(at: at) } else {
                let extra = model.width / CGFloat(max(model.columnCount, 1))
                model.insertColumn(at: at)
                model.width += extra
            }
            for (r, text) in (op["texts"] as? [String] ?? []).enumerated() where !text.isEmpty { put(text, CellRef(row: r, column: at)) }
        case "deleteColumn":
            if live { model.removeColumn(int("c")) } else if model.columnCount > 1 { model.deleteColumn(int("c")) }
        case "rowTags":
            let tags = op["tags"] as? [String] ?? []
            var all = model.data.rowTags ?? [:]
            all[int("r")] = tags.isEmpty ? nil : tags
            model.data.rowTags = all.isEmpty ? nil : all
        case "cellTags":
            let tags = op["tags"] as? [String] ?? []
            var all = model.data.cellTags ?? [:]
            all[TableData.key(CellRef(row: int("r"), column: int("c")))] = tags.isEmpty ? nil : tags
            model.data.cellTags = all.isEmpty ? nil : all
        case "table":
            if let name = op["name"] as? String { model.data.name = name.isEmpty ? nil : name }
            if let tags = op["tags"] as? [String] { model.data.tags = tags.isEmpty ? nil : tags }
        default:
            return
        }
        model.changed()
    }

    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            self?.saveTask = nil
            self?.saveBackground()
        }
    }

    /// Writes the pages changed in the background.
    func saveBackground() {
        for (ref, content) in pages {
            let index = PageIndexer.index(elements: content.elements)
            store.savePage(content, ref: ref, plainText: index.text, tags: index.tags)
        }
        pages.removeAll()
    }

    /// The end of the run: one Undo step on the page on screen, everything else saved.
    func finish() {
        saveTask?.cancel()
        saveTask = nil
        saveBackground()
        for model in liveModels.values { model.checkpoint("Run Script") }
        store.canvas?.flush()
    }

    var touchedPages: Int { backups.count }
}

// MARK: - The scripts folder

@MainActor
enum ScriptLibrary {
    static func folder(_ notebook: Notebook) -> URL { notebook.url.appending(path: "scripts") }

    /// The notebook's scripts, by name.
    static func scripts(_ notebook: Notebook) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder(notebook), includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension == "py" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// A new script from a template (named so it doesn't replace another).
    static func create(in notebook: Notebook, name: String, code: String) -> URL? {
        let dir = folder(notebook)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".py", with: "")
        var url = dir.appending(path: base + ".py"), n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appending(path: "\(base) \(n).py")
            n += 1
        }
        do {
            try code.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            NotebookStore.shared.showAlert("Couldn't make the script", error.localizedDescription)
            return nil
        }
    }

    static let templates: [(name: String, summary: String, code: String)] = [
        ("Untitled", "An empty script", """
        import mxnote as mx

        # Every table in the notebook: mx.tables()  ·  one by name or tag: mx.table("Inventory")
        # Rows and cells by tag, anywhere: mx.rows("late")  mx.cell("grand-total")
        for t in mx.tables():
            print(t)

        """),
        ("Total tagged tables", "Adds up a column in every table tagged #expenses into the cell tagged grand-total", """
        import mxnote as mx

        # Tag the tables to add up #expenses (Table ▸ Name & Tags), and the cell for the answer grand-total.
        total = 0
        for t in mx.tables(tag="expenses"):
            amount = t.column("Amount").sum()
            print(f"{t.page}: {amount:,.2f}")
            total += amount

        mx.cell("grand-total").value = round(total, 2)
        print(f"Grand total: {total:,.2f}")

        """),
        ("Flag low stock", "Marks rows of the Inventory table whose Qty is under 5", """
        import mxnote as mx

        LOW = 5
        inventory = mx.table("Inventory")          # name a table "Inventory" (Table ▸ Name & Tags)

        for row in inventory.rows:
            if isinstance(row["Qty"], (int, float)) and row["Qty"] < LOW:
                row["Status"] = "Reorder"
                row.tags.add("low")
            else:
                row.tags.remove("low")

        print(len(mx.rows("low")), "items to reorder")

        """),
        ("Tables to CSV", "Saves every named table as a CSV file in Downloads", """
        import csv
        import os
        import mxnote as mx

        folder = os.path.expanduser("~/Downloads")
        for t in mx.tables():
            if not t.name:
                continue
            path = os.path.join(folder, f"{t.name}.csv")
            with open(path, "w", newline="", encoding="utf-8") as f:
                writer = csv.writer(f)
                writer.writerow(t.headers)
                writer.writerows(t.values())
            print("Saved", path)

        """),
        ("Summary with pandas", "Describes a table with pandas (installs pandas the first time)", """
        import pandas as pd
        import mxnote as mx

        df = mx.table("Inventory").to_pandas()
        print(df.describe(include="all"))

        """),
    ]
}

// MARK: - A run

@MainActor
@Observable
final class ScriptSession {
    enum State: Equatable {
        case idle, preparing(String), running, paused, finished(String)
        var busy: Bool {
            switch self {
            case .preparing, .running, .paused: true
            default: false
            }
        }
    }

    struct Line: Identifiable {
        enum Kind { case output, error, info, success, command }
        let id = UUID()
        let text: String
        let kind: Kind
    }

    struct Variable: Identifiable, Hashable {
        var id: String { name }
        let name: String
        let type: String
        let value: String
    }

    private(set) var state: State = .idle
    private(set) var console: [Line] = []
    private(set) var debugging = false
    /// Where the debugger stopped, its variables and stack; where an error came from.
    private(set) var pausedLine: Int?
    private(set) var variables: [Variable] = []
    private(set) var stack: [(function: String, line: Int)] = []
    private(set) var errorLine: Int?
    /// Modules the script imports that aren't installed (offered to install).
    private(set) var missing: [String] = []
    private(set) var script: URL?
    private(set) var canRevert = false
    var pythonMissing = false

    private var process: StreamingProcess?
    private var applier: TableApplier?
    private var lastBackups: [PageRef: PageContent] = [:]
    private var lastRun: (script: URL, debug: Bool, breakpoints: [Int], notebook: Notebook)?
    private var started = Date()

    func log(_ text: String, _ kind: Line.Kind = .info) {
        console.append(Line(text: text, kind: kind))
        if console.count > 5000 { console.removeFirst(console.count - 5000) }
    }

    func clearConsole() { console = [] }

    /// Runs (or debugs) a script on its notebook's tables.
    func run(_ script: URL, notebook: Notebook, debug: Bool, breakpoints: [Int]) async {
        guard !state.busy else { return }
        self.script = script
        lastRun = (script, debug, breakpoints, notebook)
        errorLine = nil
        pausedLine = nil
        variables = []
        missing = []
        debugging = debug
        do { try PythonSupport.install() } catch {
            log("Couldn't write the Python helpers: \(error.localizedDescription)", .error)
            return
        }
        guard PythonLocator.find() != nil else {
            pythonMissing = true
            log("Python 3 isn't installed — see the instructions to install it.", .error)
            return
        }
        pythonMissing = false
        let env = NotebookPython(notebook: notebook)
        state = .preparing("Getting Python ready…")
        guard await env.prepare(log: { [weak self] text, isError in self?.log(text, isError ? .error : .info) }) else {
            state = .finished("Python isn't ready")
            return
        }
        state = .preparing("Checking the script…")
        let check = await env.check(script)
        if let error = check.syntaxError {
            errorLine = error.line
            log("Line \(error.line): \(error.message)", .error)
            state = .finished("Syntax error")
            return
        }
        if !check.missing.isEmpty {
            missing = check.missing
            log("This script imports \(check.missing.joined(separator: ", ")), not installed in this notebook's Python yet. "
                + "Install \(check.missing.count == 1 ? "it" : "them") above, then run again.", .error)
            state = .finished("Needs packages")
            return
        }
        state = .preparing("Reading the notebook's tables…")
        let found = NotebookTables.all(in: notebook)
        let snapshotURL = FileManager.default.temporaryDirectory.appending(path: "mxnote-\(UUID().uuidString).json")
        do {
            try NotebookTables.snapshot(found.tables, notebook: notebook).write(to: snapshotURL)
        } catch {
            log("Couldn't write the tables for the script: \(error.localizedDescription)", .error)
            state = .finished("Failed")
            return
        }
        if found.locked > 0 { log("\(found.locked) locked section\(found.locked == 1 ? "" : "s") left out (unlock to include).", .info) }
        applier = TableApplier(notebook: notebook, tables: found.tables)
        let p = StreamingProcess(env.python, ["-u", PythonSupport.folder.appending(path: "mxrunner.py").path, script.path], environment: [
            "PYTHONPATH": PythonSupport.folder.path + ":" + script.deletingLastPathComponent().path,
            "MXNOTE_SNAPSHOT": snapshotURL.path,
            "MXNOTE_DEBUG": debug ? "1" : "0",
            "MXNOTE_BREAKPOINTS": "[" + breakpoints.sorted().map(String.init).joined(separator: ",") + "]",
        ], directory: script.deletingLastPathComponent())
        process = p
        started = Date()
        log("▶ \(debug ? "Debugging" : "Running") \(script.lastPathComponent) — \(found.tables.count) table\(found.tables.count == 1 ? "" : "s") in \(notebook.name), Python \(check.version)", .command)
        state = .running
        do {
            try p.start(onLine: { [weak self] line, isError in self?.receive(line, isError: isError) },
                        onExit: { [weak self] status in self?.ended(status, snapshot: snapshotURL) })
        } catch {
            log("Couldn't start Python: \(error.localizedDescription)", .error)
            state = .finished("Failed")
        }
    }

    private func receive(_ line: String, isError: Bool) {
        guard !isError, line.hasPrefix(PythonSupport.marker) else {
            log(line, isError ? .error : .output)
            return
        }
        let body = line.dropFirst()
        guard let space = body.firstIndex(of: " ") else { return }
        let kind = String(body[..<space])
        guard let object = try? JSONSerialization.jsonObject(with: Data(body[body.index(after: space)...].utf8)) as? [String: Any] else { return }
        switch kind {
        case "MXOP":
            applier?.apply(object)
        case "MXDBG":
            pausedLine = object["line"] as? Int
            let locals = object["locals"] as? [String: [String: String]] ?? [:]
            variables = locals.map { Variable(name: $0.key, type: $0.value["type"] ?? "", value: $0.value["value"] ?? "") }
                .sorted { $0.name < $1.name }
            stack = (object["stack"] as? [[String: Any]] ?? []).map { (($0["function"] as? String) ?? "", ($0["line"] as? Int) ?? 0) }
            state = .paused
        case "MXEVAL":
            let expr = object["expr"] as? String ?? ""
            if let error = object["error"] as? String { log("\(expr) → \(error)", .error) } else { log("\(expr) → \(object["value"] as? String ?? "")", .success) }
        case "MXMISSING":
            if let module = object["module"] as? String, !missing.contains(module) { missing.append(module) }
        case "MXERROR":
            errorLine = object["line"] as? Int
        default:
            break
        }
    }

    private func ended(_ status: Int32, snapshot: URL) {
        try? FileManager.default.removeItem(at: snapshot)
        process = nil
        pausedLine = nil
        let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
        if let applier {
            applier.finish()
            if applier.changes > 0 {
                lastBackups = applier.backups
                canRevert = true
                log("\(applier.changes) change\(applier.changes == 1 ? "" : "s") to \(applier.touchedTables.count) table\(applier.touchedTables.count == 1 ? "" : "s") on \(applier.touchedPages) page\(applier.touchedPages == 1 ? "" : "s") — Revert Last Run puts them back.", .success)
            }
        }
        applier = nil
        let ok = status == 0 && errorLine == nil
        let stopped = status == 2 || status == 15 || status == -2 || status == -15
        log(ok ? "✓ Done in \(seconds) s" : stopped ? "■ Stopped" : "✗ Ended with an error" + (errorLine.map { " at line \($0)" } ?? (status != 0 ? " (exit \(status))" : "")),
            ok ? .success : .error)
        state = .finished(ok ? "Done" : "Error")
        if !missing.isEmpty {
            log("Missing: \(missing.joined(separator: ", ")) — Install above, then run again.", .error)
        }
    }

    // MARK: Debugging

    func command(_ c: String) {
        guard state == .paused, let process else { return }
        if c != "eval" { state = .running; pausedLine = nil }
        process.send(c)
    }

    func evaluate(_ expression: String) {
        guard state == .paused, let process, !expression.isEmpty else { return }
        log("» \(expression)", .command)
        process.send("eval " + expression)
    }

    func updateBreakpoints(_ lines: [Int]) {
        guard state == .paused, let process else { return }
        process.send("break [" + lines.sorted().map(String.init).joined(separator: ",") + "]")
    }

    /// Text for the script's input().
    func input(_ text: String) {
        guard let process, state == .running else { return }
        log(text, .command)
        process.send(text)
    }

    func stop() {
        if state == .paused { process?.send("quit") }
        process?.stop()
    }

    // MARK: Packages, reverting

    func installMissing(notebook: Notebook, thenRun: Bool) async {
        let env = NotebookPython(notebook: notebook)
        let packages = missing.map(NotebookPython.package(for:))
        state = .preparing("Installing \(packages.joined(separator: ", "))…")
        let ok = await env.install(packages, log: { [weak self] text, isError in self?.log(text, isError ? .error : .info) })
        state = .finished(ok ? "Installed" : "Install failed")
        if ok {
            log("Installed \(packages.joined(separator: ", ")) (added to requirements.txt).", .success)
            missing = []
            if thenRun, let last = lastRun { await run(last.script, notebook: last.notebook, debug: last.debug, breakpoints: last.breakpoints) }
        }
    }

    /// Puts every page the last run changed back as it was.
    func revert() {
        guard canRevert else { return }
        let store = NotebookStore.shared
        store.canvas?.flush()
        var current = false
        for (ref, content) in lastBackups {
            let index = PageIndexer.index(elements: content.elements)
            store.savePage(content, ref: ref, plainText: index.text, tags: index.tags)
            if store.canvas?.ref == ref { current = true }
        }
        if current { store.reloadToken += 1 }
        log("Reverted \(lastBackups.count) page\(lastBackups.count == 1 ? "" : "s") to how they were before the last run.", .success)
        lastBackups = [:]
        canRevert = false
    }
}
