//
//  SearchView.swift
//  MxFileMGR
//
//  Find Files (Alt-F7 in Total Commander): name wildcards or regex, text
//  contained in the file, size and date limits, recursive. Results can be
//  revealed in the active pane, opened, or copied as paths.
//

import AppKit
import SwiftUI

nonisolated struct SearchHit: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let folder: String
    let size: Int64
    let modified: Date
    let isDirectory: Bool
    var id: URL { url }
}

nonisolated struct SearchCriteria: Sendable {
    var root: URL
    var names: NameMatcher
    var contains: String
    var caseSensitive: Bool
    var recursive: Bool
    var includeHidden: Bool
    var includeFolders: Bool
    var minSize: Int64?
    var maxSize: Int64?
    var modifiedAfter: Date?
}

nonisolated enum SearchEngine {
    static let maxHits = 20_000

    /// Walks the tree, calling `emit(batch, scannedCount, finished)` every so often.
    static func run(_ c: SearchCriteria, flag: CancelFlag, emit: @Sendable ([SearchHit], Int, Bool) -> Void) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !c.includeHidden { options.insert(.skipsHiddenFiles) }
        if !c.recursive { options.insert(.skipsSubdirectoryDescendants) }
        guard let e = FileManager.default.enumerator(at: c.root, includingPropertiesForKeys: keys, options: options,
                                                     errorHandler: { _, _ in true }) else {
            emit([], 0, true)
            return
        }
        let needle = c.contains
        var batch: [SearchHit] = []
        var scanned = 0, found = 0
        var lastEmit = Date()
        while let url = e.nextObject() as? URL {
            if flag.isCancelled { break }
            scanned += 1
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let isDir = v.isDirectory ?? false
            if isDir && (!c.includeFolders || !needle.isEmpty) { continue }
            if !c.names.matches(url.lastPathComponent) { continue }
            let size = Int64(v.fileSize ?? 0)
            if let min = c.minSize, isDir || size < min { continue }
            if let max = c.maxSize, isDir || size > max { continue }
            let date = v.contentModificationDate ?? .distantPast
            if let after = c.modifiedAfter, date < after { continue }
            if !needle.isEmpty {
                guard v.isRegularFile == true, fileContains(url, needle, caseSensitive: c.caseSensitive) else { continue }
            }
            batch.append(SearchHit(url: url, name: url.lastPathComponent, folder: url.deletingLastPathComponent().path,
                                   size: size, modified: date, isDirectory: isDir))
            found += 1
            if found >= maxHits { break }
            if batch.count >= 300 || Date().timeIntervalSince(lastEmit) > 0.25 {
                emit(batch, scanned, false)
                batch = []
                lastEmit = Date()
            }
        }
        emit(batch, scanned, true)
    }

    /// Byte search (ASCII case folding when not case-sensitive). Files over 200 MB are skipped.
    static func fileContains(_ url: URL, _ needle: String, caseSensitive: Bool) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), data.count < 200_000_000 else { return false }
        if caseSensitive { return data.range(of: Data(needle.utf8)) != nil }
        let pattern = Array(needle.lowercased().utf8)
        guard let first = pattern.first else { return true }
        @inline(__always) func lower(_ b: UInt8) -> UInt8 { (b >= 65 && b <= 90) ? b + 32 : b }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            let bytes = raw.bindMemory(to: UInt8.self)
            let n = bytes.count, m = pattern.count
            guard n >= m else { return false }
            var i = 0
            while i <= n - m {
                if lower(bytes[i]) == first {
                    var j = 1
                    while j < m && lower(bytes[i + j]) == pattern[j] { j += 1 }
                    if j == m { return true }
                }
                i += 1
            }
            return false
        }
    }
}

@Observable
final class SearchModel {
    var rootPath: String
    var namePattern = "*"
    var useRegex = false
    var contains = ""
    var caseSensitive = false
    var recursive = true
    var includeHidden = false
    var includeFolders = true
    var minKB = ""
    var maxKB = ""
    var withinDays = ""

    private(set) var results: [SearchHit] = []
    private(set) var scanned = 0
    private(set) var running = false
    @ObservationIgnored private var flag: CancelFlag?

    init(root: URL) { rootPath = root.path }

    func start() {
        cancel()
        results = []
        scanned = 0
        running = true
        let flag = CancelFlag()
        self.flag = flag
        let pattern = namePattern.trimmingCharacters(in: .whitespaces)
        let criteria = SearchCriteria(
            root: URL(fileURLWithPath: (rootPath as NSString).expandingTildeInPath),
            names: NameMatcher(pattern.isEmpty ? "*" : pattern, regex: useRegex, caseSensitive: caseSensitive),
            contains: contains, caseSensitive: caseSensitive, recursive: recursive,
            includeHidden: includeHidden, includeFolders: includeFolders,
            minSize: Int64(minKB).map { $0 * 1024 }, maxSize: Int64(maxKB).map { $0 * 1024 },
            modifiedAfter: Double(withinDays).map { Date().addingTimeInterval(-$0 * 86_400) })
        Task.detached(priority: .userInitiated) { [weak self] in
            let model = self
            SearchEngine.run(criteria, flag: flag) { hits, scanned, done in
                Task { @MainActor in model?.receive(hits, scanned: scanned, done: done, flag: flag) }
            }
        }
    }

    func cancel() {
        flag?.cancel()
        running = false
    }

    private func receive(_ hits: [SearchHit], scanned: Int, done: Bool, flag: CancelFlag) {
        guard flag === self.flag else { return }
        results.append(contentsOf: hits)
        self.scanned = scanned
        if done { running = false }
    }
}

struct SearchView: View {
    @State private var model: SearchModel
    @State private var selection = Set<URL>()
    @State private var sortOrder = [KeyPathComparator(\SearchHit.name)]

    init(request: SearchRequest) {
        _model = State(initialValue: SearchModel(root: request.root))
    }

    var body: some View {
        VStack(spacing: 0) {
            form.padding(14)
            Divider()
            Table(sortedResults, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { hit in
                    Label {
                        Text(hit.name)
                    } icon: {
                        Image(systemName: hit.isDirectory ? "folder" : "doc")
                    }
                }
                TableColumn("Folder", value: \.folder) { Text($0.folder).foregroundStyle(.secondary) }
                TableColumn("Size", value: \.size) { Text($0.isDirectory ? "" : Fmt.size($0.size)) }
                    .width(80)
                TableColumn("Modified", value: \.modified) { Text(Fmt.date($0.modified)) }
                    .width(140)
            }
            .contextMenu(forSelectionType: URL.self) { urls in
                Button("Show in Pane") { if let u = urls.first { Workspace.current?.reveal(u) } }
                Button("Open") { urls.forEach { NSWorkspace.shared.open($0) } }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(Array(urls)) }
                Button("Copy Paths") { copyPaths(urls) }
            } primaryAction: { urls in
                if let u = urls.first { Workspace.current?.reveal(u) }
            }
            Divider()
            HStack {
                if model.running { ProgressView().controlSize(.small) }
                Text("\(Fmt.count(model.results.count, "match", "matches")) · \(model.scanned.formatted()) scanned")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Show in Pane") { if let u = selection.first { Workspace.current?.reveal(u) } }
                    .disabled(selection.count != 1)
                Button("Copy Paths") { copyPaths(selection) }
                    .disabled(selection.isEmpty)
            }
            .font(.callout)
            .padding(10)
        }
        .navigationTitle("Find Files")
        .quickHelpScreen("Find Files", FileHelp.search, selection: selection.isEmpty ? nil : QuickHelpItem(title: Fmt.count(selection.count, "Result") + " Selected", detail: "Show in Pane reveals the first one in the active pane; Copy Paths copies their paths.", symbol: "checkmark.circle"))
        .onDisappear { model.cancel() }
    }

    private var sortedResults: [SearchHit] { model.results.sorted(using: sortOrder) }

    @ViewBuilder private var form: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("Search in:")
                HStack {
                    TextField("Folder", text: $model.rootPath).textFieldStyle(.roundedBorder)
                    Button("Choose…") { chooseFolder() }
                }
            }
            GridRow {
                Text("Name:")
                HStack {
                    TextField("*.txt;*.md", text: $model.namePattern).textFieldStyle(.roundedBorder)
                        .onSubmit { model.start() }
                    Toggle("Regular expression", isOn: $model.useRegex)
                }
            }
            GridRow {
                Text("Containing text:")
                HStack {
                    TextField("Optional", text: $model.contains).textFieldStyle(.roundedBorder)
                        .onSubmit { model.start() }
                    Toggle("Case sensitive", isOn: $model.caseSensitive)
                }
            }
            GridRow {
                Text("Limits:")
                HStack {
                    TextField("min KB", text: $model.minKB).frame(width: 70)
                    TextField("max KB", text: $model.maxKB).frame(width: 70)
                    TextField("days", text: $model.withinDays).frame(width: 55)
                        .help("Only items modified within this many days")
                    Toggle("Subfolders", isOn: $model.recursive)
                    Toggle("Hidden items", isOn: $model.includeHidden)
                    Toggle("Folders", isOn: $model.includeFolders)
                    Spacer()
                    if model.running {
                        Button("Stop") { model.cancel() }
                    } else {
                        Button("Find") { model.start() }.keyboardShortcut(.defaultAction)
                            .quickHelp("Find", "Starts the search; results appear as they are found.", shortcut: "↩")
                    }
                }
                .textFieldStyle(.roundedBorder)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: model.rootPath)
        if panel.runModal() == .OK, let url = panel.url { model.rootPath = url.path }
    }

    private func copyPaths(_ urls: Set<URL>) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls.map(\.path).sorted().joined(separator: "\n"), forType: .string)
    }
}
