//
//  S3View.swift
//  MxFileMGR
//
//  Amazon S3 browser. S3 has no local folder, so this window works through
//  the installed AWS CLI with the profiles in ~/.aws (including IAM Identity
//  Center / SSO sign-in); the app never reads or stores access keys.
//  Browse buckets and folders; download to and upload from the active pane
//  (also by drag and drop); new folder, rename, delete; copy S3 URIs and
//  presigned links.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// An object or folder in S3 or Azure Blob Storage.
nonisolated struct RemoteEntry: Identifiable, Hashable, Sendable {
    /// Full key / blob name; folders (common prefixes) end with "/".
    let key: String
    let name: String
    let isFolder: Bool
    let size: Int64
    let modified: Date
    let storageClass: String
    var id: String { key }
}

nonisolated struct AWSCLIError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }

    /// The SSO session for the profile has expired or never started.
    var needsLogin: Bool {
        let m = message.lowercased()
        return (m.contains("sso") && (m.contains("expired") || m.contains("error loading") || m.contains("token")))
            || m.contains("aws sso login")
    }
}

/// Runs the AWS CLI. Output is JSON; the pager is disabled.
nonisolated enum AWSCLI {
    static var path: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["/opt/homebrew/bin/aws", "/usr/local/bin/aws", "/usr/bin/aws",
                          home + "/.local/bin/aws", "/usr/local/aws-cli/aws"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Profile names from ~/.aws/config and ~/.aws/credentials (section headers only).
    static var profiles: [String] {
        let aws = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".aws")
        var names: [String] = []
        for file in ["config", "credentials"] {
            guard let text = try? String(contentsOf: aws.appendingPathComponent(file), encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("["), t.hasSuffix("]") else { continue }
                var name = String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                if name.hasPrefix("sso-session") || name.hasPrefix("services") { continue }
                if name.hasPrefix("profile ") { name = String(name.dropFirst("profile ".count)).trimmingCharacters(in: .whitespaces) }
                if !names.contains(name) { names.append(name) }
            }
        }
        return names
    }

    static var isAvailable: Bool { path != nil && !profiles.isEmpty }

    static func environment() -> [String: String] { CLITool.environment(["AWS_PAGER": ""]) }

    /// Runs `aws <args> --profile <profile>` and returns stdout.
    static func run(_ args: [String], profile: String) async throws -> Data {
        guard let path else { throw AWSCLIError(message: "The AWS CLI isn't installed.") }
        do {
            return try await CLITool.run(path, args + ["--profile", profile, "--no-cli-pager"], environment: environment())
        } catch let error as CLIToolError {
            throw AWSCLIError(message: error.message)
        }
    }

    /// Runs a transfer command in a job, turning "Completed 1.2 MiB/10.0 MiB" output into progress.
    @discardableResult
    static func runTransfer(_ args: [String], profile: String, reporter: ProgressReporter) -> Bool {
        guard let path else { reporter.error("The AWS CLI isn't installed."); return false }
        return CLITool.runJob(path, args + ["--profile", profile, "--no-cli-pager"], environment: environment(),
                              reporter: reporter) { line in
            if let (done, total) = parseProgress(line) { reporter.progress(done: done, of: total, line) }
        }
    }

    /// "Completed 1.2 MiB/~10.0 MiB (3.1 MiB/s) with 2 file(s) remaining" -> (done, total) bytes.
    static func parseProgress(_ line: String) -> (Int64, Int64)? {
        guard let range = line.range(of: #"Completed ([\d.]+) (\w+)/~?([\d.]+) (\w+)"#, options: .regularExpression) else { return nil }
        let parts = line[range].dropFirst("Completed ".count).split(separator: "/")
        guard parts.count == 2 else { return nil }
        func bytes(_ s: Substring) -> Int64? {
            let p = s.replacingOccurrences(of: "~", with: "").split(separator: " ")
            guard p.count == 2, let v = Double(p[0]) else { return nil }
            let units = ["Bytes": 1.0, "KiB": 1024.0, "MiB": 1_048_576.0, "GiB": 1_073_741_824.0, "TiB": 1_099_511_627_776.0]
            return Int64(v * (units[String(p[1])] ?? 1))
        }
        guard let done = bytes(parts[0]), let total = bytes(parts[1]) else { return nil }
        return (done, total)
    }

    static func parseDate(_ text: String?) -> Date { CLITool.parseISODate(text) }
}

@Observable
final class S3Model {
    let profiles = AWSCLI.profiles
    var profile: String {
        didSet {
            guard profile != oldValue else { return }
            UserDefaults.standard.set(profile, forKey: "s3Profile")
            Task { await loadBuckets() }
        }
    }
    private(set) var buckets: [String] = []
    var bucket: String? {
        didSet { if bucket != oldValue { prefix = ""; selection = []; Task { await list() } } }
    }
    private(set) var prefix = ""
    private(set) var entries: [RemoteEntry] = []
    private(set) var truncated = false
    private(set) var loading = false
    private(set) var errorText: String?
    private(set) var needsLogin = false
    private(set) var signingIn = false
    var selection: Set<String> = []
    var filter = ""

    static let maxItems = 10_000

    init() {
        let saved = UserDefaults.standard.string(forKey: "s3Profile")
        let names = AWSCLI.profiles
        profile = saved.flatMap { names.contains($0) ? $0 : nil } ?? names.first ?? "default"
    }

    var visibleEntries: [RemoteEntry] {
        let f = filter.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty else { return entries }
        let matcher = NameMatcher(f, substringIfPlain: true)
        return entries.filter { matcher.matches($0.name) }
    }

    var selectedEntries: [RemoteEntry] { entries.filter { selection.contains($0.key) } }

    func uri(_ key: String = "") -> String { "s3://\(bucket ?? "")/\(key)" }

    // MARK: Listing

    func loadBuckets() async {
        loading = true
        defer { loading = false }
        do {
            let data = try await AWSCLI.run(["s3api", "list-buckets", "--output", "json"], profile: profile)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let names = (json?["Buckets"] as? [[String: Any]] ?? []).compactMap { $0["Name"] as? String }
            buckets = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            errorText = nil
            needsLogin = false
            if bucket == nil || !buckets.contains(bucket!) { bucket = buckets.first } else { await list() }
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
            var args = ["s3api", "list-objects-v2", "--bucket", bucket, "--delimiter", "/",
                        "--max-items", String(Self.maxItems), "--output", "json"]
            if !prefix.isEmpty { args += ["--prefix", prefix] }
            let data = try await AWSCLI.run(args, profile: profile)
            guard requested == (self.bucket ?? "", self.prefix) else { return }
            let json = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            var result: [RemoteEntry] = []
            for p in json["CommonPrefixes"] as? [[String: Any]] ?? [] {
                guard let key = p["Prefix"] as? String else { continue }
                let name = String(key.dropFirst(prefix.count).dropLast())
                result.append(RemoteEntry(key: key, name: name, isFolder: true, size: 0, modified: .distantPast, storageClass: ""))
            }
            for o in json["Contents"] as? [[String: Any]] ?? [] {
                guard let key = o["Key"] as? String, key != prefix else { continue }   // skip the folder marker itself
                result.append(RemoteEntry(key: key, name: String(key.dropFirst(prefix.count)), isFolder: false,
                                      size: (o["Size"] as? NSNumber)?.int64Value ?? 0,
                                      modified: AWSCLI.parseDate(o["LastModified"] as? String),
                                      storageClass: o["StorageClass"] as? String ?? ""))
            }
            entries = result.sorted { a, b in
                a.isFolder != b.isFolder ? a.isFolder : a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            truncated = json["NextToken"] != nil
            selection.formIntersection(Set(entries.map(\.key)))
            errorText = nil
            needsLogin = false
        } catch {
            report(error)
        }
    }

    func open(_ entry: RemoteEntry) {
        guard entry.isFolder else { return }
        go(to: entry.key)
    }

    func go(to newPrefix: String) {
        prefix = newPrefix
        selection = []
        filter = ""
        Task { await list() }
    }

    func goUp() {
        guard !prefix.isEmpty else { return }
        var parts = prefix.split(separator: "/", omittingEmptySubsequences: false).dropLast()   // trailing ""
        parts = parts.dropLast()
        go(to: parts.isEmpty ? "" : parts.joined(separator: "/") + "/")
    }

    private func report(_ error: Error) {
        let cliError = error as? AWSCLIError
        needsLogin = cliError?.needsLogin ?? false
        errorText = error.localizedDescription
    }

    // MARK: Sign in

    /// Starts `aws sso login`, which opens the browser to approve the sign-in.
    func signIn() {
        signingIn = true
        let profile = profile
        Task {
            do {
                _ = try await AWSCLI.run(["sso", "login"], profile: profile)
                signingIn = false
                await loadBuckets()
            } catch {
                signingIn = false
                report(error)
            }
        }
    }

    // MARK: Transfers (background jobs)

    /// Downloads the selection into `folder` (folders recursively).
    func download(_ items: [RemoteEntry], to folder: URL) {
        guard !items.isEmpty, bucket != nil else { return }
        let profile = profile
        let jobs: [(String, URL, Bool)] = items.map { item in
            let stem = item.isFolder ? item.name : (item.name as NSString).deletingPathExtension
            let ext = item.isFolder ? "" : (item.name as NSString).pathExtension
            return (uri(item.key), FileOps.availableURL(in: folder, stem: stem, ext: ext), item.isFolder)
        }
        TransferManager.shared.start("Downloading \(Fmt.count(items.count, "item")) from S3") { reporter in
            for (source, dest, recursive) in jobs where !reporter.isCancelled {
                reporter.begin(dest.lastPathComponent)
                var args = ["s3", "cp", source, dest.path]
                if recursive { args.append("--recursive") }
                AWSCLI.runTransfer(args, profile: profile, reporter: reporter)
            }
        }
    }

    /// Uploads local files and folders into the current folder, replacing objects of the same name after asking.
    func upload(_ urls: [URL]) {
        guard !urls.isEmpty, bucket != nil else { return }
        let existing = Set(entries.map(\.name))
        let clashes = urls.map(\.lastPathComponent).filter { existing.contains($0) }
        if !clashes.isEmpty, !Alerts.confirm("Replace \(Fmt.count(clashes.count, "item")) in \(uri(prefix))?",
                                             info: clashes.prefix(10).joined(separator: "\n"), ok: "Replace") {
            return
        }
        let profile = profile
        let jobs: [(URL, String, Bool)] = urls.map { url in
            let isDir = FileOps.isRealDirectory(url)
            return (url, uri(prefix + url.lastPathComponent + (isDir ? "/" : "")), isDir)
        }
        TransferManager.shared.start("Uploading \(Fmt.count(urls.count, "item")) to S3") { [weak self] reporter in
            for (source, dest, recursive) in jobs where !reporter.isCancelled {
                reporter.begin(source.lastPathComponent)
                var args = ["s3", "cp", source.path, dest]
                if recursive { args.append("--recursive") }
                AWSCLI.runTransfer(args, profile: profile, reporter: reporter)
            }
            await self?.list()
        }
    }

    // MARK: Changes

    func newFolder() async {
        guard let bucket, let name = Alerts.prompt("New Folder", info: "Create a folder in \(uri(prefix))", initial: "untitled folder",
                                                   ok: "Create"), !name.contains("/") else { return }
        do {
            _ = try await AWSCLI.run(["s3api", "put-object", "--bucket", bucket, "--key", prefix + name + "/"], profile: profile)
            await list()
            selection = [prefix + name + "/"]
        } catch { report(error) }
    }

    func rename(_ item: RemoteEntry) async {
        guard let name = Alerts.prompt("Rename", info: uri(item.key), initial: item.name, ok: "Rename"),
              name != item.name, !name.contains("/") else { return }
        if entries.contains(where: { $0.name == name }) {
            Alerts.message("“\(name)” already exists in this folder.")
            return
        }
        let target = prefix + name + (item.isFolder ? "/" : "")
        var args = ["s3", "mv", uri(item.key), uri(target), "--only-show-errors"]
        if item.isFolder { args.append("--recursive") }
        do {
            _ = try await AWSCLI.run(args, profile: profile)
            await list()
            selection = [target]
        } catch { report(error) }
    }

    /// Deletes objects (folders with everything in them). S3 has no trash, so this asks first.
    func delete(_ items: [RemoteEntry]) async {
        guard !items.isEmpty else { return }
        let folders = items.filter(\.isFolder).count
        let what = items.count == 1 ? "“\(items[0].name)”" : Fmt.count(items.count, "item")
        guard Alerts.confirm("Delete \(what) from S3?",
                             info: (folders > 0 ? "Folders are deleted with everything in them. " : "")
                                + "This can't be undone unless the bucket has versioning turned on.",
                             ok: "Delete", destructive: true) else { return }
        let profile = profile
        let targets = items.map { (uri($0.key), $0.isFolder) }
        TransferManager.shared.start("Deleting \(what) from S3") { [weak self] reporter in
            for (i, (target, recursive)) in targets.enumerated() where !reporter.isCancelled {
                reporter.step(i, of: targets.count, target)
                var args = ["s3", "rm", target, "--only-show-errors"]
                if recursive { args.append("--recursive") }
                AWSCLI.runTransfer(args, profile: profile, reporter: reporter)
            }
            await self?.list()
        }
        selection = []
    }

    func copyURIs(_ items: [RemoteEntry]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(items.map { uri($0.key) }.joined(separator: "\n"), forType: .string)
    }

    /// Copies a presigned HTTPS link (valid 7 days) for each selected file.
    func copyPresignedLinks(_ items: [RemoteEntry]) async {
        var links: [String] = []
        for item in items where !item.isFolder {
            do {
                let data = try await AWSCLI.run(["s3", "presign", uri(item.key), "--expires-in", "604800"], profile: profile)
                links.append(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            } catch { report(error); return }
        }
        guard !links.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(links.joined(separator: "\n"), forType: .string)
    }
}

struct S3View: View {
    @State private var model = S3Model()
    @State private var dropTargeted = false

    var body: some View {
        Group {
            if AWSCLI.path == nil || model.profiles.isEmpty {
                ContentUnavailableView {
                    Label("AWS CLI Not Set Up", systemImage: "server.rack")
                } description: {
                    Text(AWSCLI.path == nil
                         ? "Install the AWS CLI (for example: brew install awscli), then set up a profile with aws configure or aws configure sso."
                         : "Set up a profile with aws configure or aws configure sso, then reopen this window.")
                }
            } else {
                browser
            }
        }
        .navigationTitle("Amazon S3")
        .quickHelpScreen("Amazon S3", FileHelp.s3Screen, selection: FileHelp.remoteSelection(model.selectedEntries))
        .navigationSubtitle(model.bucket == nil ? "" : model.uri(model.prefix))
        .task { await model.loadBuckets() }
    }

    private var browser: some View {
        HSplitView {
            VStack(spacing: 0) {
                Picker("Profile", selection: $model.profile) {
                    ForEach(model.profiles, id: \.self) { Text($0).tag($0) }
                }
                .padding(8)
                List(model.buckets, id: \.self, selection: $model.bucket) { name in
                    Label(name, systemImage: "archivebox").tag(Optional(name))
                }
                .listStyle(.sidebar)
            }
            .frame(minWidth: 180, idealWidth: 220, maxWidth: 340)

            VStack(spacing: 0) {
                header
                Divider()
                if model.needsLogin {
                    ContentUnavailableView {
                        Label("Sign In to AWS", systemImage: "person.badge.key")
                    } description: {
                        Text("The sign-in for profile “\(model.profile)” has expired or hasn't started. Signing in opens your browser to approve it.")
                    } actions: {
                        Button(model.signingIn ? "Waiting for the browser…" : "Sign In") { model.signIn() }
                            .disabled(model.signingIn)
                    }
                } else {
                    if let error = model.errorText {
                        Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    table
                }
                Divider()
                footer
            }
            .frame(minWidth: 520)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button { model.goUp() } label: { Image(systemName: "arrow.up") }
                .disabled(model.prefix.isEmpty).help("Enclosing Folder")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    if let bucket = model.bucket {
                        Button(bucket) { model.go(to: "") }
                        let parts = model.prefix.split(separator: "/").map(String.init)
                        ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                            Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
                            Button(part) { model.go(to: parts[0...index].joined(separator: "/") + "/") }
                                .fontWeight(index == parts.count - 1 ? .semibold : .regular)
                        }
                    }
                }
            }
            .defaultScrollAnchor(.trailing)
            .frame(maxWidth: .infinity)
            if model.loading { ProgressView().controlSize(.small) }
            Button { Task { await model.list() } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
            TextField("Filter", text: $model.filter)
                .textFieldStyle(.roundedBorder).frame(width: 130)
        }
        .buttonStyle(.borderless)
        .padding(8)
    }

    private var table: some View {
        Table(model.visibleEntries, selection: $model.selection) {
            TableColumn("Name") { entry in
                Label(entry.name, systemImage: entry.isFolder ? "folder" : "doc")
            }
            TableColumn("Size") { Text($0.isFolder ? "" : Fmt.size($0.size)).foregroundStyle(.secondary) }
                .width(80)
            TableColumn("Modified") { Text(Fmt.date($0.modified)).foregroundStyle(.secondary) }
                .width(140)
            TableColumn("Storage") { Text($0.storageClass).foregroundStyle(.secondary) }
                .width(110)
        }
        .contextMenu(forSelectionType: String.self) { keys in
            let items = model.entries.filter { keys.contains($0.key) }
            if let pane = Workspace.current?.activeTab.url {
                Button("Download to “\(BrowserTab.displayName(of: pane))”") { model.download(items, to: pane) }
            }
            Button("Copy S3 URI") { model.copyURIs(items) }
            Button("Copy Presigned Link (7 days)") { Task { await model.copyPresignedLinks(items) } }
                .disabled(items.allSatisfy(\.isFolder))
            Divider()
            Button("Rename…") { if let item = items.first { Task { await model.rename(item) } } }
                .disabled(items.count != 1)
            Button("Delete…", role: .destructive) { Task { await model.delete(items) } }
        } primaryAction: { keys in
            guard let entry = model.entries.first(where: { keys.contains($0.key) }) else { return }
            if entry.isFolder {
                model.open(entry)
            } else if let pane = Workspace.current?.activeTab.url {
                model.download([entry], to: pane)
            }
        }
        .onDeleteCommand { Task { await model.delete(model.selectedEntries) } }
        .quickHelpArea(FileHelp.remoteList("S3"))
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            model.upload(files)
            return !files.isEmpty
        } isTargeted: { dropTargeted = $0 }
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
            Button("New Folder…") { Task { await model.newFolder() } }
                .disabled(model.bucket == nil)
            Button("Upload from “\(paneName ?? "Pane")”") { model.upload(marked) }
                .disabled(model.bucket == nil || marked.isEmpty)
                .quickHelp("Upload", FileHelp.uploadDetail)
                .help("Upload the items marked in the active pane into this S3 folder")
            Button("Delete…", role: .destructive) { Task { await model.delete(model.selectedEntries) } }
                .disabled(model.selection.isEmpty)
                .quickHelp("Delete", "Deletes the selected items, and folders with everything in them, after asking. There is no trash.", shortcut: "⌫")
            Button("Download to “\(paneName ?? "Pane")”") {
                if let url = pane?.url { model.download(model.selectedEntries, to: url) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.selection.isEmpty || pane == nil)
        }
        .padding(10)
    }

    private var status: String {
        var text = "\(Fmt.count(model.entries.count, "item"))"
        if !model.selection.isEmpty {
            let bytes = model.selectedEntries.reduce(Int64(0)) { $0 + $1.size }
            text = "\(model.selection.count) of \(text) selected, \(Fmt.size(bytes))"
        }
        if model.truncated { text += " · first \(S3Model.maxItems.formatted()) shown" }
        return text
    }
}
