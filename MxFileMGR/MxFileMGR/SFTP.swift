//
//  SFTP.swift
//  MxFileMGR
//
//  SFTP accounts in Favorites. macOS can't mount SFTP (that needs macFUSE and
//  sshfs), so an account opens a browser window driven by the system's
//  /usr/bin/sftp in batch mode: browse, download to and upload from the active
//  pane, new folder, rename, delete, copy sftp:// links.
//
//  Sign-in is whatever ssh would use: keys, ssh-agent and ~/.ssh/config
//  (aliases, ProxyJump/ProxyCommand, ports), or a password saved in the login
//  Keychain, handed to ssh through SSH_ASKPASS. New host keys are accepted the
//  first time (StrictHostKeyChecking=accept-new); a changed key is refused.
//

import AppKit
import SwiftUI

nonisolated struct SFTPAccount: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    /// Host name, address or ~/.ssh/config alias.
    var host: String
    /// Empty: ssh's default (22, or the config's Port).
    var port: String = ""
    /// Empty: ssh's default (your login name, or the config's User).
    var user: String = ""
    /// Folder to start in; empty: the account's home folder.
    var path: String = ""
    var usesPassword = false

    var destination: String { user.isEmpty ? host : "\(user)@\(host)" }

    func link(_ remotePath: String) -> String {
        let portPart = port.isEmpty ? "" : ":\(port)"
        let encoded = remotePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? remotePath
        return "sftp://\(destination)\(portPart)\(encoded.hasPrefix("/") ? "" : "/")\(encoded)"
    }
}

struct SFTPRequest: Codable, Hashable { var accountID: UUID }

nonisolated enum SFTPCLI {
    static let path = "/usr/bin/sftp"

    /// Host aliases from ~/.ssh/config (no wildcards), for adding accounts quickly.
    static var configHosts: [String] {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var hosts: [String] = []
        for line in text.split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count > 1, parts[0].lowercased() == "host" else { continue }
            for alias in parts.dropFirst() where !alias.contains("*") && !alias.contains("?") && !alias.hasPrefix("!") {
                if !hosts.contains(String(alias)) { hosts.append(String(alias)) }
            }
        }
        return hosts
    }

    /// Quotes an argument for an sftp batch file.
    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// A small script ssh runs to read the password (SSH_ASKPASS); the password itself only travels in the environment.
    static func askpassScript() -> String? {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MxFileMGR")
        let script = dir.appendingPathComponent("sftp-askpass.sh")
        if !FileManager.default.isExecutableFile(atPath: script.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let body = "#!/bin/sh\nprintf '%s\\n' \"$MXFILEMGR_SFTP_SECRET\"\n"
            guard (try? body.write(to: script, atomically: true, encoding: .utf8)) != nil else { return nil }
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        }
        return script.path
    }

    static func arguments(_ account: SFTPAccount, password: String?, batch: String) -> [String] {
        var args = ["-o", "ConnectTimeout=15", "-o", "StrictHostKeyChecking=accept-new", "-o", "ServerAliveInterval=15"]
        // With no password, never prompt (keys and the agent only); with one, ssh asks SSH_ASKPASS.
        args += password == nil ? ["-o", "BatchMode=yes"] : ["-o", "NumberOfPasswordPrompts=1", "-o", "PreferredAuthentications=publickey,keyboard-interactive,password"]
        if !account.port.isEmpty { args += ["-P", account.port] }
        return args + ["-b", batch, account.destination]
    }

    static func environment(password: String?) -> [String: String] {
        var extra: [String: String] = [:]
        if let password, let askpass = askpassScript() {
            extra = ["SSH_ASKPASS": askpass, "SSH_ASKPASS_REQUIRE": "force", "DISPLAY": ":0", "MXFILEMGR_SFTP_SECRET": password]
        }
        return CLITool.environment(extra)
    }

    private static func batchFile(_ commands: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mxfilemgr-sftp-\(UUID().uuidString).txt")
        try (commands.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Runs batch commands in one connection and returns sftp's output.
    static func run(_ account: SFTPAccount, password: String?, _ commands: [String]) async throws -> String {
        let batch = try batchFile(commands)
        defer { try? FileManager.default.removeItem(at: batch) }
        let data = try await CLITool.run(path, arguments(account, password: password, batch: batch.path),
                                         environment: environment(password: password))
        return String(decoding: data, as: UTF8.self)
    }

    @discardableResult
    static func runJob(_ account: SFTPAccount, password: String?, _ commands: [String], reporter: ProgressReporter) -> Bool {
        guard let batch = try? batchFile(commands) else { reporter.error("Couldn't write the sftp batch file."); return false }
        defer { try? FileManager.default.removeItem(at: batch) }
        return CLITool.runJob(path, arguments(account, password: password, batch: batch.path),
                              environment: environment(password: password), reporter: reporter)
    }

    /// "Remote working directory: /home/me" from `pwd`.
    static func parsePWD(_ output: String) -> String? {
        for line in output.split(separator: "\n") {
            if let r = line.range(of: "Remote working directory: ") {
                return String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Parses `ls -la` output after cd: "drwxr-xr-x  2 me staff  64 Oct 16 12:00 name" (or "... Sep  1  2025 name").
    static func parseListing(_ output: String, folder: String) -> [RemoteEntry] {
        var result: [RemoteEntry] = []
        let base = folder.hasSuffix("/") ? folder : folder + "/"
        for raw in output.split(separator: "\n") {
            let line = String(raw)
            if line.hasPrefix("sftp>") { continue }
            let fields = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
            guard fields.count == 9, let type = fields[0].first, "-dlbcps".contains(type), fields[0].count >= 10 else { continue }
            var name = String(fields[8])
            if type == "l", let arrow = name.range(of: " -> ") { name = String(name[..<arrow.lowerBound]) }
            if name == "." || name == ".." { continue }
            let isFolder = type == "d"
            result.append(RemoteEntry(key: base + name + (isFolder ? "/" : ""), name: name, isFolder: isFolder,
                                      size: Int64(fields[4]) ?? 0,
                                      modified: parseDate(month: String(fields[5]), day: String(fields[6]), timeOrYear: String(fields[7])),
                                      storageClass: String(fields[0])))
        }
        return result
    }

    private static func parseDate(month: String, day: String, timeOrYear: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        if timeOrYear.contains(":") {
            f.dateFormat = "MMM d yyyy HH:mm"
            let year = Calendar.current.component(.year, from: Date())
            guard var date = f.date(from: "\(month) \(day) \(year) \(timeOrYear)") else { return .distantPast }
            // ls shows the time for the last six months; a date "ahead" of now is from last year.
            if date > Date().addingTimeInterval(86_400) { date = Calendar.current.date(byAdding: .year, value: -1, to: date) ?? date }
            return date
        }
        f.dateFormat = "MMM d yyyy"
        return f.date(from: "\(month) \(day) \(timeOrYear)") ?? .distantPast
    }
}

@Observable
final class SFTPStore {
    static let shared = SFTPStore()
    private static let key = "sftpAccounts"
    private(set) var accounts: [SFTPAccount] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let list = try? JSONDecoder().decode([SFTPAccount].self, from: data) {
            accounts = list
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(accounts) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    func account(_ id: UUID) -> SFTPAccount? { accounts.first { $0.id == id } }

    func upsert(_ account: SFTPAccount) {
        if let i = accounts.firstIndex(where: { $0.id == account.id }) { accounts[i] = account } else { accounts.append(account) }
        save()
    }

    func remove(_ account: SFTPAccount) {
        accounts.removeAll { $0.id == account.id }
        PasswordKeychain.sftp.delete(for: account.id)
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        accounts.move(fromOffsets: source, toOffset: destination)
        save()
    }
}

// MARK: - Browser

@Observable
final class SFTPModel {
    let account: SFTPAccount
    private(set) var folder = ""
    private(set) var entries: [RemoteEntry] = []
    private(set) var loading = false
    private(set) var errorText: String?
    var selection: Set<String> = []
    var filter = ""
    @ObservationIgnored private let password: String?

    init(account: SFTPAccount) {
        self.account = account
        password = account.usesPassword ? PasswordKeychain.sftp.password(for: account.id) : nil
    }

    var visibleEntries: [RemoteEntry] {
        let f = filter.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty else { return entries }
        let matcher = NameMatcher(f, substringIfPlain: true)
        return entries.filter { matcher.matches($0.name) }
    }

    var selectedEntries: [RemoteEntry] { entries.filter { selection.contains($0.key) } }

    /// The path of an entry without the trailing "/" folders carry in their key.
    nonisolated static func remotePath(_ entry: RemoteEntry) -> String { entry.isFolder ? String(entry.key.dropLast()) : entry.key }

    func start() async {
        if account.usesPassword, password == nil {
            errorText = "No password is saved for this account. Edit it (right-click it in Favorites) to enter one."
            return
        }
        await list(account.path.isEmpty ? nil : account.path)
    }

    /// Lists `path` (nil: the home folder).
    func list(_ path: String? = nil) async {
        loading = true
        defer { loading = false }
        let target = path ?? (folder.isEmpty ? nil : folder)
        do {
            let output = try await SFTPCLI.run(account, password: password,
                                               (target.map { ["cd \(SFTPCLI.quote($0))"] } ?? []) + ["pwd", "ls -la"])
            let current = SFTPCLI.parsePWD(output) ?? target ?? "/"
            folder = current
            entries = SFTPCLI.parseListing(output, folder: current)
                .sorted { a, b in a.isFolder != b.isFolder ? a.isFolder : a.name.localizedStandardCompare(b.name) == .orderedAscending }
            selection.formIntersection(Set(entries.map(\.key)))
            errorText = nil
        } catch {
            errorText = (error as? CLIToolError)?.message ?? error.localizedDescription
        }
    }

    func go(to path: String) {
        selection = []
        filter = ""
        Task { await list(path) }
    }

    func goUp() {
        guard folder != "/", !folder.isEmpty else { return }
        let parent = (folder as NSString).deletingLastPathComponent
        go(to: parent.isEmpty ? "/" : parent)
    }

    /// A symlink may point to a folder (sftp's listing can't tell): open it as one, or download it if it isn't.
    func openLink(_ entry: RemoteEntry) async {
        let target = Self.remotePath(entry)
        do {
            _ = try await SFTPCLI.run(account, password: password, ["cd \(SFTPCLI.quote(target))"])
            go(to: target)
        } catch {
            if let pane = Workspace.current?.activeTab.url { download([entry], to: pane) }
        }
    }

    // MARK: Transfers

    func download(_ items: [RemoteEntry], to local: URL) {
        guard !items.isEmpty else { return }
        let commands = items.map { item -> String in
            let stem = item.isFolder ? item.name : (item.name as NSString).deletingPathExtension
            let ext = item.isFolder ? "" : (item.name as NSString).pathExtension
            let dest = FileOps.availableURL(in: local, stem: stem, ext: ext)
            return "get \(item.isFolder ? "-r " : "")\(SFTPCLI.quote(Self.remotePath(item))) \(SFTPCLI.quote(dest.path))"
        }
        let account = account, password = password
        TransferManager.shared.start("Downloading \(Fmt.count(items.count, "item")) from \(account.name)") { reporter in
            reporter.begin(items.count == 1 ? items[0].name : "\(items.count) items")
            SFTPCLI.runJob(account, password: password, commands, reporter: reporter)
        }
    }

    func upload(_ urls: [URL]) {
        guard !urls.isEmpty, !folder.isEmpty else { return }
        let existing = Set(entries.map(\.name))
        let clashes = urls.map(\.lastPathComponent).filter { existing.contains($0) }
        if !clashes.isEmpty, !Alerts.confirm("Replace \(Fmt.count(clashes.count, "item")) in \(folder)?",
                                             info: clashes.prefix(10).joined(separator: "\n"), ok: "Replace") {
            return
        }
        let base = folder.hasSuffix("/") ? folder : folder + "/"
        let commands = urls.map { url in
            "put \(FileOps.isRealDirectory(url) ? "-r " : "")\(SFTPCLI.quote(url.path)) \(SFTPCLI.quote(base + url.lastPathComponent))"
        }
        let account = account, password = password
        TransferManager.shared.start("Uploading \(Fmt.count(urls.count, "item")) to \(account.name)") { [weak self] reporter in
            reporter.begin(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items")
            SFTPCLI.runJob(account, password: password, commands, reporter: reporter)
            await self?.list()
        }
    }

    // MARK: Changes

    func newFolder() async {
        guard let name = Alerts.prompt("New Folder", info: "Create a folder in \(folder)", initial: "untitled folder", ok: "Create"),
              !name.contains("/") else { return }
        await perform(["mkdir \(SFTPCLI.quote((folder as NSString).appendingPathComponent(name)))"])
        selection = [(folder as NSString).appendingPathComponent(name) + "/"]
    }

    func rename(_ item: RemoteEntry) async {
        guard let name = Alerts.prompt("Rename", info: Self.remotePath(item), initial: item.name, ok: "Rename"),
              name != item.name, !name.contains("/") else { return }
        if entries.contains(where: { $0.name == name }) {
            Alerts.message("“\(name)” already exists in this folder.")
            return
        }
        let target = (folder as NSString).appendingPathComponent(name)
        await perform(["rename \(SFTPCLI.quote(Self.remotePath(item))) \(SFTPCLI.quote(target))"])
        selection = [target + (item.isFolder ? "/" : "")]
    }

    /// Deletes files, and folders with everything in them (sftp only removes empty folders, so their trees are listed first).
    func delete(_ items: [RemoteEntry]) async {
        guard !items.isEmpty else { return }
        let folders = items.filter(\.isFolder).count
        let what = items.count == 1 ? "“\(items[0].name)”" : Fmt.count(items.count, "item")
        guard Alerts.confirm("Delete \(what) from \(account.name)?",
                             info: (folders > 0 ? "Folders are deleted with everything in them. " : "") + "This can't be undone.",
                             ok: "Delete", destructive: true) else { return }
        let account = account, password = password
        TransferManager.shared.start("Deleting \(what) from \(account.name)") { [weak self] reporter in
            var commands: [String] = []
            for item in items where !reporter.isCancelled {
                reporter.begin(item.name)
                if item.isFolder {
                    var files: [String] = [], dirs: [String] = []
                    await Self.collect(Self.remotePath(item), account: account, password: password,
                                       files: &files, dirs: &dirs, reporter: reporter)
                    commands += files.map { "rm \(SFTPCLI.quote($0))" }
                    commands += dirs.reversed().map { "rmdir \(SFTPCLI.quote($0))" }
                } else {
                    commands.append("rm \(SFTPCLI.quote(Self.remotePath(item)))")
                }
            }
            if !reporter.isCancelled, !commands.isEmpty {
                SFTPCLI.runJob(account, password: password, commands, reporter: reporter)
            }
            await self?.list()
        }
        selection = []
    }

    /// Every file and folder under `dir` (folders parent-first, `dir` included).
    nonisolated private static func collect(_ dir: String, account: SFTPAccount, password: String?,
                                files: inout [String], dirs: inout [String], reporter: ProgressReporter) async {
        dirs.append(dir)
        guard !reporter.isCancelled else { return }
        do {
            let output = try await SFTPCLI.run(account, password: password, ["cd \(SFTPCLI.quote(dir))", "ls -la"])
            for entry in SFTPCLI.parseListing(output, folder: dir) {
                if entry.isFolder {
                    await collect(remotePath(entry), account: account, password: password, files: &files, dirs: &dirs, reporter: reporter)
                } else {
                    files.append(entry.key)
                }
            }
        } catch {
            reporter.error("\(dir): \((error as? CLIToolError)?.message ?? error.localizedDescription)")
        }
    }

    private func perform(_ commands: [String]) async {
        loading = true
        defer { loading = false }
        do {
            _ = try await SFTPCLI.run(account, password: password, commands)
            await list()
        } catch {
            errorText = (error as? CLIToolError)?.message ?? error.localizedDescription
        }
    }

    func copyLinks(_ items: [RemoteEntry]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(items.map { account.link(Self.remotePath($0)) }.joined(separator: "\n"), forType: .string)
    }
}

struct SFTPView: View {
    let request: SFTPRequest
    @State private var model: SFTPModel?
    @State private var dropTargeted = false

    var body: some View {
        Group {
            if let model {
                SFTPBrowser(model: model, dropTargeted: $dropTargeted)
            } else {
                ContentUnavailableView("Account Not Found", systemImage: "questionmark.folder",
                                       description: Text("This SFTP account was removed."))
            }
        }
        .onAppear {
            if model == nil, let account = SFTPStore.shared.account(request.accountID) { model = SFTPModel(account: account) }
        }
    }
}

private struct SFTPBrowser: View {
    @Bindable var model: SFTPModel
    @Binding var dropTargeted: Bool

    var body: some View {
        VStack(spacing: 0) {
            RemoteHeader(root: model.account.destination, prefix: String(model.folder.drop(while: { $0 == "/" })) + (model.folder.count > 1 ? "/" : ""),
                         loading: model.loading, filter: $model.filter,
                         goUp: model.goUp, go: { model.go(to: "/" + $0) }, refresh: { Task { await model.list() } })
            Divider()
            if let error = model.errorText {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            table
            Divider()
            footer
        }
        .frame(minWidth: 620, minHeight: 360)
        .navigationTitle(model.account.name)
        .navigationSubtitle(model.folder.isEmpty ? model.account.destination : model.account.link(model.folder))
        .quickHelpScreen("SFTP · \(model.account.name)", FileHelp.sftpScreen, selection: FileHelp.remoteSelection(model.selectedEntries))
        .task { await model.start() }
    }

    private var table: some View {
        Table(model.visibleEntries, selection: $model.selection) {
            TableColumn("Name") { entry in
                Label(entry.name, systemImage: entry.isFolder ? "folder" : (entry.storageClass.hasPrefix("l") ? "link" : "doc"))
            }
            TableColumn("Size") { Text($0.isFolder ? "" : Fmt.size($0.size)).foregroundStyle(.secondary) }
                .width(80)
            TableColumn("Modified") { Text(Fmt.date($0.modified)).foregroundStyle(.secondary) }
                .width(140)
            TableColumn("Permissions") { Text($0.storageClass).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary) }
                .width(100)
        }
        .contextMenu(forSelectionType: String.self) { keys in
            let items = model.entries.filter { keys.contains($0.key) }
            if let pane = Workspace.current?.activeTab.url {
                Button("Download to “\(BrowserTab.displayName(of: pane))”") { model.download(items, to: pane) }
            }
            Button("Copy sftp:// Link") { model.copyLinks(items) }
            Divider()
            Button("Rename…") { if let item = items.first { Task { await model.rename(item) } } }
                .disabled(items.count != 1)
            Button("Delete…", role: .destructive) { Task { await model.delete(items) } }
        } primaryAction: { keys in
            guard let entry = model.entries.first(where: { keys.contains($0.key) }) else { return }
            if entry.isFolder {
                model.go(to: SFTPModel.remotePath(entry))
            } else if entry.storageClass.hasPrefix("l") {
                Task { await model.openLink(entry) }
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
        .quickHelpArea(FileHelp.remoteList("SFTP"))
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 3).padding(2)
            } else if model.entries.isEmpty, !model.loading, model.errorText == nil, !model.folder.isEmpty {
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
                .disabled(model.folder.isEmpty)
                .quickHelp("New Folder", "Creates a folder here on the server.")
            Button("Upload from “\(paneName ?? "Pane")”") { model.upload(marked) }
                .disabled(model.folder.isEmpty || marked.isEmpty)
                .quickHelp("Upload", FileHelp.uploadDetail)
            Button("Delete…", role: .destructive) { Task { await model.delete(model.selectedEntries) } }
                .disabled(model.selection.isEmpty)
                .quickHelp("Delete", "Deletes the selected items, and folders with everything in them, after asking. There is no trash.", shortcut: "⌫")
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

// MARK: - Account sheet

struct SFTPSheet: View {
    let workspace: Workspace
    @State private var account: SFTPAccount
    @State private var password = ""
    @State private var testing = false
    @State private var resultText: String?
    @State private var resultOK = false
    private let isNew: Bool
    private let configHosts = SFTPCLI.configHosts
    @Environment(\.dismiss) private var dismiss

    init(workspace: Workspace, account: SFTPAccount?) {
        self.workspace = workspace
        isNew = account == nil
        _account = State(initialValue: account ?? SFTPAccount(name: "", host: ""))
        _password = State(initialValue: account.flatMap { PasswordKeychain.sftp.password(for: $0.id) } ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "Add SFTP Account" : "Edit SFTP Account").font(.headline)
            if !configHosts.isEmpty {
                Picker("From ~/.ssh/config:", selection: Binding(get: { "" }, set: { host in
                    guard !host.isEmpty else { return }
                    account.host = host
                    if account.name.isEmpty { account.name = host }
                    account.user = ""
                    account.port = ""
                })) {
                    Text("Choose a host…").tag("")
                    ForEach(configHosts, id: \.self) { Text($0).tag($0) }
                }
                .fixedSize()
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow { Text("Name:"); TextField("e.g. Web server", text: $account.name) }
                GridRow { Text("Host:"); TextField("server.example.com or a ~/.ssh/config alias", text: $account.host) }
                GridRow {
                    Text("User:")
                    HStack {
                        TextField("Optional", text: $account.user)
                        Text("Port:")
                        TextField("22", text: $account.port).frame(width: 60)
                    }
                }
                GridRow { Text("Folder:"); TextField("Optional — the home folder if empty", text: $account.path) }
                GridRow {
                    Text("Sign in:")
                    Picker("", selection: $account.usesPassword) {
                        Text("SSH key or agent").tag(false)
                        Text("Password").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                if account.usesPassword {
                    GridRow { Text("Password:"); SecureField("Kept in your login Keychain", text: $password) }
                }
            }
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 500)
            Text(account.usesPassword
                 ? "The password is saved in your login Keychain and given to ssh only while it connects."
                 : "Uses your SSH keys, ssh-agent and ~/.ssh/config (aliases, ports, ProxyJump) exactly as ssh in Terminal does.")
                .font(.caption).foregroundStyle(.secondary)
            if let resultText {
                Text(resultText).font(.callout).foregroundStyle(resultOK ? .green : .red).textSelection(.enabled)
                    .lineLimit(6)
            }
            HStack {
                Button("Test Connection") { test() }
                    .disabled(!isValid || testing)
                if testing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save(); dismiss() }
                    .disabled(!isValid)
                Button("Save and Open") {
                    save()
                    dismiss()
                    workspace.openSFTP(account)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(20)
        .quickHelpScreen(isNew ? "Add SFTP Account" : "Edit SFTP Account", FileHelp.sftpSheet)
    }

    private var isValid: Bool {
        !account.host.trimmingCharacters(in: .whitespaces).isEmpty && (account.port.isEmpty || Int(account.port) != nil)
            && (!account.usesPassword || !password.isEmpty)
    }

    private func save() {
        account.host = account.host.trimmingCharacters(in: .whitespaces)
        if account.name.trimmingCharacters(in: .whitespaces).isEmpty { account.name = account.host }
        SFTPStore.shared.upsert(account)
        if account.usesPassword, !password.isEmpty {
            PasswordKeychain.sftp.save(password, for: account.id, label: "MxFileMGR SFTP: \(account.name)")
        } else {
            PasswordKeychain.sftp.delete(for: account.id)
        }
    }

    private func test() {
        testing = true
        resultText = nil
        let account = account, secret = account.usesPassword ? password : nil
        Task {
            do {
                let output = try await SFTPCLI.run(account, password: secret,
                                                   (account.path.isEmpty ? [] : ["cd \(SFTPCLI.quote(account.path))"]) + ["pwd"])
                resultOK = true
                resultText = "Connected. Folder: " + (SFTPCLI.parsePWD(output) ?? "?")
            } catch {
                resultOK = false
                resultText = (error as? CLIToolError)?.message ?? error.localizedDescription
            }
            testing = false
        }
    }
}
