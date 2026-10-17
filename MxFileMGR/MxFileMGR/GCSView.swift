//
//  GCSView.swift
//  MxFileMGR
//
//  Google Cloud Storage browser. Like the S3 and Azure windows it works through
//  a CLI, here the Google Cloud CLI (`gcloud storage`) after `gcloud auth login`,
//  so the app never stores keys. Pick a project and bucket, browse folders,
//  download to and upload from the active pane (also by drag and drop), new
//  folder, rename, delete, and copy gs:// URIs or authenticated browser links.
//

import AppKit
import SwiftUI

nonisolated enum GCloudCLI {
    static var path: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return CLITool.find([
            "/opt/homebrew/bin/gcloud", "/usr/local/bin/gcloud",
            "/opt/homebrew/share/google-cloud-sdk/bin/gcloud",
            "/opt/homebrew/Caskroom/google-cloud-sdk/latest/google-cloud-sdk/bin/gcloud",
            "/usr/local/Caskroom/google-cloud-sdk/latest/google-cloud-sdk/bin/gcloud",
            home + "/google-cloud-sdk/bin/gcloud",
        ])
    }

    static func environment(prompts: Bool = false) -> [String: String] {
        var extra = ["CLOUDSDK_CORE_DISABLE_COLOR": "1"]
        if !prompts { extra["CLOUDSDK_CORE_DISABLE_PROMPTS"] = "1" }
        return CLITool.environment(extra)
    }

    static func run(_ args: [String], prompts: Bool = false) async throws -> Data {
        guard let path else { throw CLIToolError(message: "The Google Cloud CLI isn't installed.") }
        return try await CLITool.run(path, args, environment: environment(prompts: prompts))
    }

    @discardableResult
    static func runJob(_ args: [String], reporter: ProgressReporter) -> Bool {
        guard let path else { reporter.error("The Google Cloud CLI isn't installed."); return false }
        return CLITool.runJob(path, args, environment: environment(), reporter: reporter)
    }

    static func needsLogin(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("gcloud auth login") || m.contains("no active account") || m.contains("do not currently have an active account")
            || m.contains("reauthentication") || m.contains("invalid_grant")
    }

    /// Parses `gcloud storage ls --long gs://bucket/prefix/` output:
    /// "      1234  2024-05-01T12:34:56Z  gs://bucket/prefix/file" for objects,
    /// "                                 gs://bucket/prefix/sub/" for folders, and a closing "TOTAL:" line.
    static func parseListing(_ text: String, bucket: String, prefix: String) -> [RemoteEntry] {
        let base = "gs://\(bucket)/"
        var result: [RemoteEntry] = []
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let start = line.range(of: base) else { continue }
            let key = String(line[start.upperBound...])
            guard key.hasPrefix(prefix), key != prefix else { continue }
            let name = String(key.dropFirst(prefix.count))
            if key.hasSuffix("/") {
                result.append(RemoteEntry(key: key, name: String(name.dropLast()), isFolder: true,
                                          size: 0, modified: .distantPast, storageClass: ""))
            } else {
                let fields = line[..<start.lowerBound].split(separator: " ")
                result.append(RemoteEntry(key: key, name: name, isFolder: false,
                                          size: fields.first.flatMap { Int64($0) } ?? 0,
                                          modified: CLITool.parseISODate(fields.count > 1 ? String(fields[1]) : nil),
                                          storageClass: ""))
            }
        }
        return result
    }
}

struct GCloudProject: Identifiable, Hashable {
    let id: String
    let name: String
}

@Observable
final class GCSModel {
    private(set) var projects: [GCloudProject] = []
    var projectID = "" {
        didSet {
            guard projectID != oldValue else { return }
            UserDefaults.standard.set(projectID, forKey: "gcsProject")
            Task { await loadBuckets() }
        }
    }
    private(set) var buckets: [String] = []
    var bucket: String? {
        didSet { if bucket != oldValue { prefix = ""; selection = []; Task { await list() } } }
    }
    private(set) var prefix = ""
    private(set) var entries: [RemoteEntry] = []
    private(set) var loading = false
    private(set) var errorText: String?
    private(set) var needsLogin = false
    private(set) var signingIn = false
    var selection: Set<String> = []
    var filter = ""

    var visibleEntries: [RemoteEntry] {
        let f = filter.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty else { return entries }
        let matcher = NameMatcher(f, substringIfPlain: true)
        return entries.filter { matcher.matches($0.name) }
    }

    var selectedEntries: [RemoteEntry] { entries.filter { selection.contains($0.key) } }

    func uri(_ key: String = "") -> String { "gs://\(bucket ?? "")/\(key)" }

    // MARK: Loading

    func start() async {
        loading = true
        defer { loading = false }
        do {
            let data = try await GCloudCLI.run(["projects", "list", "--format=json(projectId,name)"])
            let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
            projects = list.compactMap { p in
                guard let id = p["projectId"] as? String else { return nil }
                return GCloudProject(id: id, name: p["name"] as? String ?? id)
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            needsLogin = false
            errorText = projects.isEmpty ? "No projects are visible to the signed-in account." : nil
            guard !projects.isEmpty else { return }
            let saved = UserDefaults.standard.string(forKey: "gcsProject")
            let configured = try? await GCloudCLI.run(["config", "get-value", "project"])
            let current = configured.map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
            let chosen = [saved, current].compactMap { $0 }.first { id in projects.contains { $0.id == id } } ?? projects[0].id
            if chosen == projectID { await loadBuckets() } else { projectID = chosen }
        } catch {
            report(error)
        }
    }

    func loadBuckets() async {
        loading = true
        defer { loading = false }
        do {
            let data = try await GCloudCLI.run(["storage", "buckets", "list", "--project", projectID, "--format=value(name)"])
            buckets = String(decoding: data, as: UTF8.self).split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            errorText = nil
            if bucket == nil || !buckets.contains(bucket!) { bucket = buckets.first } else { await list() }
            if buckets.isEmpty { entries = [] }
        } catch {
            report(error)
            buckets = []
            entries = []
        }
    }

    func list() async {
        guard let bucket else { entries = []; return }
        loading = true
        defer { loading = false }
        let requested = (bucket, prefix)
        do {
            let data = try await GCloudCLI.run(["storage", "ls", "--long", uri(prefix)])
            guard requested == (self.bucket ?? "", self.prefix) else { return }
            entries = GCloudCLI.parseListing(String(decoding: data, as: UTF8.self), bucket: bucket, prefix: prefix)
                .sorted { a, b in a.isFolder != b.isFolder ? a.isFolder : a.name.localizedStandardCompare(b.name) == .orderedAscending }
            selection.formIntersection(Set(entries.map(\.key)))
            errorText = nil
            needsLogin = false
        } catch let error as CLIToolError where error.message.contains("One or more URLs matched no objects") {
            // An empty folder (or a new virtual one).
            entries = []
            errorText = nil
        } catch {
            report(error)
        }
    }

    func go(to newPrefix: String) {
        prefix = newPrefix
        selection = []
        filter = ""
        Task { await list() }
    }

    func goUp() {
        guard !prefix.isEmpty else { return }
        let parts = prefix.split(separator: "/").dropLast()
        go(to: parts.isEmpty ? "" : parts.joined(separator: "/") + "/")
    }

    private func report(_ error: Error) {
        let message = (error as? CLIToolError)?.message ?? error.localizedDescription
        needsLogin = GCloudCLI.needsLogin(message)
        errorText = message
    }

    /// `gcloud auth login` opens the browser to sign in.
    func signIn() {
        signingIn = true
        Task {
            do {
                _ = try await GCloudCLI.run(["auth", "login", "--brief"], prompts: true)
                signingIn = false
                await start()
            } catch {
                signingIn = false
                report(error)
            }
        }
    }

    // MARK: Transfers (background jobs)

    func download(_ items: [RemoteEntry], to folder: URL) {
        guard !items.isEmpty, bucket != nil else { return }
        let jobs: [(String, URL, Bool)] = items.map { item in
            let stem = item.isFolder ? item.name : (item.name as NSString).deletingPathExtension
            let ext = item.isFolder ? "" : (item.name as NSString).pathExtension
            return (uri(item.key), FileOps.availableURL(in: folder, stem: stem, ext: ext), item.isFolder)
        }
        TransferManager.shared.start("Downloading \(Fmt.count(items.count, "item")) from Google Cloud") { reporter in
            for (source, dest, isFolder) in jobs where !reporter.isCancelled {
                reporter.begin(dest.lastPathComponent)
                if isFolder {
                    // Copy the folder's contents into a new local folder of the chosen name.
                    try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                    GCloudCLI.runJob(["storage", "cp", "-r", source + "*", dest.path + "/"], reporter: reporter)
                } else {
                    GCloudCLI.runJob(["storage", "cp", source, dest.path], reporter: reporter)
                }
            }
        }
    }

    func upload(_ urls: [URL]) {
        guard !urls.isEmpty, bucket != nil else { return }
        let existing = Set(entries.map(\.name))
        let clashes = urls.map(\.lastPathComponent).filter { existing.contains($0) }
        if !clashes.isEmpty, !Alerts.confirm("Replace \(Fmt.count(clashes.count, "item")) in \(uri(prefix))?",
                                             info: clashes.prefix(10).joined(separator: "\n"), ok: "Replace") {
            return
        }
        let target = uri(prefix)
        TransferManager.shared.start("Uploading \(Fmt.count(urls.count, "item")) to Google Cloud") { [weak self] reporter in
            for url in urls where !reporter.isCancelled {
                reporter.begin(url.lastPathComponent)
                if FileOps.isRealDirectory(url) {
                    GCloudCLI.runJob(["storage", "cp", "-r", url.path, target], reporter: reporter)
                } else {
                    GCloudCLI.runJob(["storage", "cp", url.path, target + url.lastPathComponent], reporter: reporter)
                }
            }
            await self?.list()
        }
    }

    // MARK: Changes

    /// Without hierarchical namespace a bucket has no empty folders: a new folder opens now and is kept
    /// once something is uploaded into it.
    func newFolder() {
        guard let name = Alerts.prompt("New Folder",
                                       info: "Cloud Storage keeps a folder once something is in it. The folder opens now; upload into it to keep it.",
                                       initial: "untitled folder", ok: "Open"), !name.contains("/") else { return }
        prefix += name + "/"
        selection = []
        entries = []
    }

    func rename(_ item: RemoteEntry) async {
        guard let name = Alerts.prompt("Rename", info: uri(item.key), initial: item.name, ok: "Rename"),
              name != item.name, !name.contains("/") else { return }
        if entries.contains(where: { $0.name == name }) {
            Alerts.message("“\(name)” already exists in this folder.")
            return
        }
        let source = item.isFolder ? String(uri(item.key).dropLast()) : uri(item.key)
        let target = uri(prefix + name)
        loading = true
        defer { loading = false }
        do {
            _ = try await GCloudCLI.run(["storage", "mv", source, target])
            await list()
            selection = [prefix + name + (item.isFolder ? "/" : "")]
        } catch {
            report(error)
        }
    }

    func delete(_ items: [RemoteEntry]) async {
        guard !items.isEmpty else { return }
        let folders = items.filter(\.isFolder).count
        let what = items.count == 1 ? "“\(items[0].name)”" : Fmt.count(items.count, "item")
        guard Alerts.confirm("Delete \(what) from Google Cloud?",
                             info: (folders > 0 ? "Folders are deleted with everything in them. " : "")
                                + "This can't be undone unless the bucket has soft delete or versioning turned on.",
                             ok: "Delete", destructive: true) else { return }
        let targets = items.map { (uri($0.key), $0.isFolder) }
        TransferManager.shared.start("Deleting \(what) from Google Cloud") { [weak self] reporter in
            for (i, (target, recursive)) in targets.enumerated() where !reporter.isCancelled {
                reporter.step(i, of: targets.count, target)
                GCloudCLI.runJob(["storage", "rm"] + (recursive ? ["-r"] : []) + [target], reporter: reporter)
            }
            await self?.list()
        }
        selection = []
    }

    func copyURIs(_ items: [RemoteEntry]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(items.map { uri($0.key) }.joined(separator: "\n"), forType: .string)
    }

    /// Links that open the object in a browser for anyone signed in with access (storage.cloud.google.com).
    func copyBrowserLinks(_ items: [RemoteEntry]) {
        let links = items.filter { !$0.isFolder }.map { item in
            "https://storage.cloud.google.com/\(bucket ?? "")/"
                + (item.key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? item.key)
        }
        guard !links.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(links.joined(separator: "\n"), forType: .string)
    }
}

struct GCSView: View {
    @State private var model = GCSModel()
    @State private var dropTargeted = false

    var body: some View {
        Group {
            if GCloudCLI.path == nil {
                ContentUnavailableView {
                    Label("Google Cloud CLI Not Installed", systemImage: "cloud")
                } description: {
                    Text("Install the Google Cloud CLI (for example: brew install --cask google-cloud-sdk), sign in with gcloud auth login, then reopen this window.")
                }
            } else if model.needsLogin {
                ContentUnavailableView {
                    Label("Sign In to Google Cloud", systemImage: "person.badge.key")
                } description: {
                    Text((model.errorText.map { "\($0)\n\n" } ?? "") + "Signing in opens your browser.")
                } actions: {
                    Button(model.signingIn ? "Waiting for the browser…" : "Sign In") { model.signIn() }
                        .disabled(model.signingIn)
                }
            } else {
                browser
            }
        }
        .navigationTitle("Google Cloud Storage")
        .navigationSubtitle(model.bucket == nil ? "" : model.uri(model.prefix))
        .quickHelpScreen("Google Cloud Storage", FileHelp.gcs, selection: FileHelp.remoteSelection(model.selectedEntries))
        .task { await model.start() }
    }

    private var browser: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Project", selection: $model.projectID) {
                    ForEach(model.projects) { Text($0.name).tag($0.id) }
                }
                .quickHelp("Project", "The Google Cloud project whose buckets are listed below. The choice is remembered.")
                List(model.buckets, id: \.self, selection: $model.bucket) { name in
                    Label(name, systemImage: "archivebox").tag(Optional(name))
                }
                .listStyle(.sidebar)
                .quickHelpArea("Buckets", "The project's Cloud Storage buckets. Select one to browse it.", symbol: "archivebox")
            }
            .padding(.top, 8).padding(.horizontal, 8)
            .frame(minWidth: 200, idealWidth: 240, maxWidth: 360)

            VStack(spacing: 0) {
                RemoteHeader(root: model.bucket, prefix: model.prefix, loading: model.loading, filter: $model.filter,
                             goUp: model.goUp, go: model.go, refresh: { Task { await model.list() } })
                Divider()
                if let error = model.errorText {
                    Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                table
                Divider()
                footer
            }
            .frame(minWidth: 520)
        }
    }

    private var table: some View {
        Table(model.visibleEntries, selection: $model.selection) {
            TableColumn("Name") { entry in
                Label(entry.name, systemImage: entry.isFolder ? "folder" : "doc")
            }
            TableColumn("Size") { Text($0.isFolder ? "" : Fmt.size($0.size)).foregroundStyle(.secondary) }
                .width(80)
            TableColumn("Modified") { Text(Fmt.date($0.modified)).foregroundStyle(.secondary) }
                .width(150)
        }
        .contextMenu(forSelectionType: String.self) { keys in
            let items = model.entries.filter { keys.contains($0.key) }
            if let pane = Workspace.current?.activeTab.url {
                Button("Download to “\(BrowserTab.displayName(of: pane))”") { model.download(items, to: pane) }
            }
            Button("Copy gs:// URI") { model.copyURIs(items) }
            Button("Copy Browser Link") { model.copyBrowserLinks(items) }
                .disabled(items.allSatisfy(\.isFolder))
            Divider()
            Button("Rename…") { if let item = items.first { Task { await model.rename(item) } } }
                .disabled(items.count != 1)
            Button("Delete…", role: .destructive) { Task { await model.delete(items) } }
        } primaryAction: { keys in
            guard let entry = model.entries.first(where: { keys.contains($0.key) }) else { return }
            if entry.isFolder {
                model.go(to: entry.key)
            } else if let pane = Workspace.current?.activeTab.url {
                model.download([entry], to: pane)
            }
        }
        .onDeleteCommand { Task { await model.delete(model.selectedEntries) } }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            model.upload(files)
            return !files.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .quickHelpArea(FileHelp.remoteList("Cloud Storage"))
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 3).padding(2)
            } else if model.entries.isEmpty, !model.loading, model.errorText == nil, model.bucket != nil {
                ContentUnavailableView("Empty Folder", systemImage: "folder",
                                       description: Text("Drop files here, or use Upload, to add them."))
            }
        }
    }

    private var footer: some View {
        let pane = Workspace.current?.activeTab
        let paneName = pane.map { BrowserTab.displayName(of: $0.url) }
        let marked = pane?.selectedItems.map(\.url) ?? []
        return HStack {
            Text(status).foregroundStyle(.secondary)
            Spacer()
            Button("New Folder…") { model.newFolder() }
                .disabled(model.bucket == nil)
                .quickHelp("New Folder", "Opens a new, empty folder here. Cloud Storage keeps a folder once something is uploaded into it.")
            Button("Upload from “\(paneName ?? "Pane")”") { model.upload(marked) }
                .disabled(model.bucket == nil || marked.isEmpty)
                .quickHelp("Upload", FileHelp.uploadDetail)
            Button("Delete…", role: .destructive) { Task { await model.delete(model.selectedEntries) } }
                .disabled(model.selection.isEmpty)
                .quickHelp("Delete", "Deletes the selected objects, and folders with everything in them, after asking. Permanent unless the bucket keeps deleted objects.", shortcut: "⌫")
            Button("Download to “\(paneName ?? "Pane")”") {
                if let url = pane?.url { model.download(model.selectedEntries, to: url) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.selection.isEmpty || pane == nil)
            .quickHelp("Download", FileHelp.downloadDetail, shortcut: "↩")
        }
        .padding(10)
    }

    private var status: String {
        var text = "\(Fmt.count(model.entries.count, "item"))"
        if !model.selection.isEmpty {
            let bytes = model.selectedEntries.reduce(Int64(0)) { $0 + $1.size }
            text = "\(model.selection.count) of \(text) selected, \(Fmt.size(bytes))"
        }
        return text
    }
}

/// Up button, clickable bucket/container path, refresh and filter, shared by the cloud storage windows.
struct RemoteHeader: View {
    let root: String?
    let prefix: String
    let loading: Bool
    @Binding var filter: String
    let goUp: () -> Void
    let go: (String) -> Void
    let refresh: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: goUp) { Image(systemName: "arrow.up") }
                .disabled(prefix.isEmpty).help("Enclosing Folder")
                .quickHelp("Enclosing Folder", "Goes up one folder.")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    if let root {
                        Button(root) { go("") }
                        let parts = prefix.split(separator: "/").map(String.init)
                        ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                            Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
                            Button(part) { go(parts[0...index].joined(separator: "/") + "/") }
                                .fontWeight(index == parts.count - 1 ? .semibold : .regular)
                        }
                    }
                }
            }
            .defaultScrollAnchor(.trailing)
            .frame(maxWidth: .infinity)
            .quickHelpArea("Path", "Where you are. Click any part to go back to it.", symbol: "point.topleft.down.to.point.bottomright.curvepath")
            if loading { ProgressView().controlSize(.small) }
            Button(action: refresh) { Image(systemName: "arrow.clockwise") }.help("Refresh")
                .quickHelp("Refresh", "Lists this folder again.")
            TextField("Filter", text: $filter)
                .textFieldStyle(.roundedBorder).frame(width: 130)
                .quickHelp("Filter", "Shows only items whose name contains this text, or matches wildcards such as *.csv.")
        }
        .buttonStyle(.borderless)
        .padding(8)
    }
}
