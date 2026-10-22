//
//  AzureView.swift
//  MxFileMGR
//
//  Azure Blob Storage browser. Like the S3 window it works through a CLI,
//  here the Azure CLI (az) after `az login`, so the app never stores account
//  keys. Pick a subscription, storage account and container, browse folders,
//  download to and upload from the active pane (also by drag and drop),
//  rename files, delete, and copy blob URLs or read-only SAS links.
//
//  Data access uses your Microsoft Entra sign-in (--auth-mode login). If that
//  is refused because the account lacks a "Storage Blob Data" role, the window
//  retries with the account key (--auth-mode key), which az looks up when your
//  role allows it.
//

import AppKit
import SwiftUI

nonisolated enum AzureCLI {
    static var path: String? {
        CLITool.find(["/opt/homebrew/bin/az", "/usr/local/bin/az", "/usr/bin/az"])
    }

    static func environment() -> [String: String] {
        CLITool.environment(["AZURE_CORE_NO_COLOR": "true", "AZURE_CORE_ONLY_SHOW_ERRORS": "true",
                             "AZURE_CORE_SURVEY_MESSAGE": "false"])
    }

    static func run(_ args: [String]) async throws -> Data {
        guard let path else { throw CLIToolError(message: "The Azure CLI isn't installed.") }
        return try await CLITool.run(path, args + ["--only-show-errors"], environment: environment())
    }

    @discardableResult
    static func runJob(_ args: [String], reporter: ProgressReporter) -> Bool {
        guard let path else { reporter.error("The Azure CLI isn't installed."); return false }
        return CLITool.runJob(path, args + ["--only-show-errors"], environment: environment(), reporter: reporter)
    }

    static func json(_ data: Data) -> Any? { try? JSONSerialization.jsonObject(with: data) }

    static func needsLogin(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("az login") || m.contains("please run 'az login'") || m.contains("aadsts")
            || m.contains("refresh token") && m.contains("expired")
    }

    /// Signed in with an Entra identity that has no data role on the account.
    static func isPermissionMismatch(_ message: String) -> Bool {
        message.contains("AuthorizationPermissionMismatch") || message.contains("This request is not authorized")
    }
}

struct AzureSubscription: Identifiable, Hashable {
    let id: String
    let name: String
}

@Observable
final class AzureModel {
    private(set) var subscriptions: [AzureSubscription] = []
    var subscriptionID = "" {
        didSet {
            guard subscriptionID != oldValue else { return }
            UserDefaults.standard.set(subscriptionID, forKey: "azureSubscription")
            Task { await loadAccounts() }
        }
    }
    private(set) var accounts: [String] = []
    var account: String? {
        didSet {
            guard account != oldValue else { return }
            if let account { UserDefaults.standard.set(account, forKey: "azureAccount") }
            Task { await loadContainers() }
        }
    }
    private(set) var containers: [String] = []
    var container: String? {
        didSet { if container != oldValue { prefix = ""; selection = []; Task { await list() } } }
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
    /// Accounts where Entra data access was refused, so the account key is used instead.
    @ObservationIgnored private var keyModeAccounts: Set<String> = []

    static let maxItems = 10_000

    var visibleEntries: [RemoteEntry] {
        let f = filter.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty else { return entries }
        let matcher = NameMatcher(f, substringIfPlain: true)
        return entries.filter { matcher.matches($0.name) }
    }

    var selectedEntries: [RemoteEntry] { entries.filter { selection.contains($0.key) } }

    func url(_ name: String = "") -> String {
        "https://\(account ?? "").blob.core.windows.net/\(container ?? "")/\(name)"
    }

    private var authMode: String { keyModeAccounts.contains(account ?? "") ? "key" : "login" }

    /// Arguments that address the current account (and subscription).
    private var accountArgs: [String] {
        var args = ["--account-name", account ?? "", "--auth-mode", authMode]
        if !subscriptionID.isEmpty { args += ["--subscription", subscriptionID] }
        return args
    }

    /// Runs a data-plane command, switching this account to key auth once if Entra access is refused.
    private func runData(_ args: @escaping () -> [String]) async throws -> Data {
        do {
            return try await AzureCLI.run(args())
        } catch let error as CLIToolError where AzureCLI.isPermissionMismatch(error.message) && authMode == "login" {
            keyModeAccounts.insert(account ?? "")
            return try await AzureCLI.run(args())
        }
    }

    // MARK: Loading

    func start() async {
        loading = true
        defer { loading = false }
        do {
            let data = try await AzureCLI.run(["account", "list", "-o", "json"])
            let list = AzureCLI.json(data) as? [[String: Any]] ?? []
            subscriptions = list.compactMap { s in
                guard let id = s["id"] as? String else { return nil }
                return AzureSubscription(id: id, name: s["name"] as? String ?? id)
            }
            guard !subscriptions.isEmpty else {
                needsLogin = true
                return
            }
            needsLogin = false
            errorText = nil
            let saved = UserDefaults.standard.string(forKey: "azureSubscription")
            let defaultID = list.first { $0["isDefault"] as? Bool == true }?["id"] as? String
            let chosen = [saved, defaultID].compactMap { $0 }.first { id in subscriptions.contains { $0.id == id } }
                ?? subscriptions[0].id
            if chosen == subscriptionID { await loadAccounts() } else { subscriptionID = chosen }
        } catch {
            report(error)
        }
    }

    func loadAccounts() async {
        loading = true
        defer { loading = false }
        do {
            let data = try await AzureCLI.run(["storage", "account", "list", "--subscription", subscriptionID,
                                               "--query", "[].name", "-o", "json"])
            accounts = (AzureCLI.json(data) as? [String] ?? []).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            errorText = nil
            let saved = UserDefaults.standard.string(forKey: "azureAccount")
            let chosen = saved.flatMap { accounts.contains($0) ? $0 : nil } ?? accounts.first
            if chosen == account { await loadContainers() } else { account = chosen }
            if accounts.isEmpty { containers = []; entries = [] }
        } catch {
            report(error)
        }
    }

    func loadContainers() async {
        guard account != nil else { containers = []; return }
        loading = true
        defer { loading = false }
        do {
            let data = try await runData { ["storage", "container", "list", "--num-results", "*", "--query", "[].name", "-o", "json"]
                + self.accountArgs }
            containers = (AzureCLI.json(data) as? [String] ?? []).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            errorText = nil
            if container == nil || !containers.contains(container!) { container = containers.first } else { await list() }
        } catch {
            report(error)
            containers = []
            entries = []
        }
    }

    func list() async {
        guard let container, account != nil else { entries = []; return }
        loading = true
        defer { loading = false }
        let requested = (container, prefix)
        do {
            let data = try await runData {
                var args = ["storage", "blob", "list", "--container-name", container, "--delimiter", "/",
                            "--num-results", String(Self.maxItems), "-o", "json"]
                if !self.prefix.isEmpty { args += ["--prefix", self.prefix] }
                return args + self.accountArgs
            }
            guard requested == (self.container ?? "", self.prefix) else { return }
            var result: [RemoteEntry] = []
            for blob in AzureCLI.json(data) as? [[String: Any]] ?? [] {
                guard let name = blob["name"] as? String, name != prefix else { continue }
                let props = blob["properties"] as? [String: Any]
                let size = (props?["contentLength"] as? NSNumber)?.int64Value
                if name.hasSuffix("/"), size == nil || size == 0 {
                    // A virtual folder (blob name prefix).
                    result.append(RemoteEntry(key: name, name: String(name.dropFirst(prefix.count).dropLast()), isFolder: true,
                                              size: 0, modified: .distantPast, storageClass: ""))
                } else {
                    result.append(RemoteEntry(key: name, name: String(name.dropFirst(prefix.count)), isFolder: false,
                                              size: size ?? 0, modified: CLITool.parseISODate(props?["lastModified"] as? String),
                                              storageClass: props?["blobTier"] as? String ?? ""))
                }
            }
            entries = result.sorted { a, b in
                a.isFolder != b.isFolder ? a.isFolder : a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            truncated = result.count >= Self.maxItems
            selection.formIntersection(Set(entries.map(\.key)))
            errorText = nil
            needsLogin = false
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
        needsLogin = AzureCLI.needsLogin(message)
        errorText = message
    }

    /// `az login` opens the browser to sign in.
    func signIn() {
        signingIn = true
        Task {
            do {
                _ = try await AzureCLI.run(["login", "-o", "none"])
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
        guard !items.isEmpty, let container else { return }
        let base = accountArgs
        let jobs: [(RemoteEntry, URL)] = items.map { item in
            let stem = item.isFolder ? item.name : (item.name as NSString).deletingPathExtension
            let ext = item.isFolder ? "" : (item.name as NSString).pathExtension
            return (item, FileOps.availableURL(in: folder, stem: stem, ext: ext))
        }
        TransferManager.shared.start("Downloading \(Fmt.count(items.count, "item")) from Azure") { reporter in
            for (item, dest) in jobs where !reporter.isCancelled {
                reporter.begin(dest.lastPathComponent)
                if item.isFolder {
                    // download-batch keeps the full blob path, so download to a temporary folder and move the folder out.
                    let temp = folder.appendingPathComponent(".mxazure-\(UUID().uuidString)")
                    try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
                    if AzureCLI.runJob(["storage", "blob", "download-batch", "--source", container, "--destination", temp.path,
                                        "--pattern", item.key + "*"] + base, reporter: reporter) {
                        do { try FileManager.default.moveItem(at: temp.appendingPathComponent(item.key), to: dest) }
                        catch { reporter.error("\(item.name): \(error.localizedDescription)") }
                    }
                    try? FileManager.default.removeItem(at: temp)
                } else {
                    AzureCLI.runJob(["storage", "blob", "download", "--container-name", container, "--name", item.key,
                                     "--file", dest.path] + base, reporter: reporter)
                }
            }
        }
    }

    func upload(_ urls: [URL]) {
        guard !urls.isEmpty, let container else { return }
        let existing = Set(entries.map(\.name))
        let clashes = urls.map(\.lastPathComponent).filter { existing.contains($0) }
        if !clashes.isEmpty, !Alerts.confirm("Replace \(Fmt.count(clashes.count, "item")) in \(container)/\(prefix)?",
                                             info: clashes.prefix(10).joined(separator: "\n"), ok: "Replace") {
            return
        }
        let base = accountArgs
        let prefix = prefix
        TransferManager.shared.start("Uploading \(Fmt.count(urls.count, "item")) to Azure") { [weak self] reporter in
            for url in urls where !reporter.isCancelled {
                reporter.begin(url.lastPathComponent)
                if FileOps.isRealDirectory(url) {
                    AzureCLI.runJob(["storage", "blob", "upload-batch", "--destination", container,
                                     "--destination-path", prefix + url.lastPathComponent, "--source", url.path,
                                     "--overwrite"] + base, reporter: reporter)
                } else {
                    AzureCLI.runJob(["storage", "blob", "upload", "--container-name", container,
                                     "--name", prefix + url.lastPathComponent, "--file", url.path, "--overwrite"] + base,
                                    reporter: reporter)
                }
            }
            await self?.list()
        }
    }

    // MARK: Changes

    /// Blob storage has no real folders: a new folder is a name prefix that exists once something is uploaded into it.
    func newFolder() {
        guard let name = Alerts.prompt("New Folder",
                                       info: "Blob Storage has no empty folders. The folder opens now and is kept once you upload into it.",
                                       initial: "untitled folder", ok: "Open"), !name.contains("/") else { return }
        prefix += name + "/"
        selection = []
        entries = []
    }

    /// Renames a file (copy to the new name, then delete the old blob). Folders can't be renamed here.
    func rename(_ item: RemoteEntry) async {
        guard !item.isFolder, let container else { return }
        guard let name = Alerts.prompt("Rename", info: url(item.key), initial: item.name, ok: "Rename"),
              name != item.name, !name.contains("/") else { return }
        if entries.contains(where: { $0.name == name }) {
            Alerts.message("“\(name)” already exists in this folder.")
            return
        }
        let target = prefix + name
        loading = true
        defer { loading = false }
        do {
            _ = try await runData {
                ["storage", "blob", "copy", "start", "--destination-container", container, "--destination-blob", target,
                 "--source-container", container, "--source-blob", item.key, "-o", "none"] + self.accountArgs
            }
            // Same-account copies are usually immediate; wait for completion before deleting the original.
            for _ in 0..<120 {
                let data = try await runData {
                    ["storage", "blob", "show", "--container-name", container, "--name", target,
                     "--query", "properties.copy.status", "-o", "json"] + self.accountArgs
                }
                let status = (AzureCLI.json(data) as? String) ?? "success"
                if status == "success" { break }
                if status == "failed" || status == "aborted" { throw CLIToolError(message: "The copy to “\(name)” \(status).") }
                try await Task.sleep(for: .seconds(1))
            }
            _ = try await runData {
                ["storage", "blob", "delete", "--container-name", container, "--name", item.key] + self.accountArgs
            }
            await list()
            selection = [target]
        } catch {
            report(error)
        }
    }

    func delete(_ items: [RemoteEntry]) async {
        guard !items.isEmpty, let container else { return }
        let folders = items.filter(\.isFolder).count
        let what = items.count == 1 ? "“\(items[0].name)”" : Fmt.count(items.count, "item")
        guard Alerts.confirm("Delete \(what) from Azure?",
                             info: (folders > 0 ? "Folders are deleted with everything in them. " : "")
                                + "This can't be undone unless soft delete is turned on for the storage account.",
                             ok: "Delete", destructive: true) else { return }
        let base = accountArgs
        TransferManager.shared.start("Deleting \(what) from Azure") { [weak self] reporter in
            for (i, item) in items.enumerated() where !reporter.isCancelled {
                reporter.step(i, of: items.count, item.name)
                if item.isFolder {
                    AzureCLI.runJob(["storage", "blob", "delete-batch", "--source", container, "--pattern", item.key + "*"] + base,
                                    reporter: reporter)
                } else {
                    AzureCLI.runJob(["storage", "blob", "delete", "--container-name", container, "--name", item.key] + base,
                                    reporter: reporter)
                }
            }
            await self?.list()
        }
        selection = []
    }

    func copyURLs(_ items: [RemoteEntry]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(items.map { url($0.key) }.joined(separator: "\n"), forType: .string)
    }

    /// Copies a read-only SAS link valid for 7 days (a user delegation SAS when signed in with Entra).
    func copySASLinks(_ items: [RemoteEntry]) async {
        guard let container else { return }
        let expiry = Date().addingTimeInterval(7 * 86_400 - 300)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"
        var links: [String] = []
        for item in items where !item.isFolder {
            do {
                let data = try await runData {
                    var args = ["storage", "blob", "generate-sas", "--container-name", container, "--name", item.key,
                                "--permissions", "r", "--expiry", f.string(from: expiry), "--full-uri", "-o", "tsv"]
                    if self.authMode == "login" { args.append("--as-user") }
                    return args + self.accountArgs
                }
                links.append(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            } catch { report(error); return }
        }
        guard !links.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(links.joined(separator: "\n"), forType: .string)
    }
}

struct AzureView: View {
    @State private var model = AzureModel()
    @State private var dropTargeted = false

    var body: some View {
        Group {
            if AzureCLI.path == nil {
                ContentUnavailableView {
                    Label("Azure CLI Not Installed", systemImage: "cylinder.split.1x2")
                } description: {
                    Text("Install the Azure CLI (for example: brew install azure-cli), sign in with az login, then reopen this window.")
                }
            } else if model.needsLogin {
                ContentUnavailableView {
                    Label("Sign In to Azure", systemImage: "person.badge.key")
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
        .navigationTitle("Azure Blob Storage")
        .quickHelpScreen("Azure Blob Storage", FileHelp.azureScreen, selection: FileHelp.remoteSelection(model.selectedEntries))
        .navigationSubtitle(model.container == nil ? "" : model.url(model.prefix))
        .task { await model.start() }
    }

    private var browser: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Subscription", selection: $model.subscriptionID) {
                    ForEach(model.subscriptions) { Text($0.name).tag($0.id) }
                }
                Picker("Account", selection: Binding(get: { model.account ?? "" }, set: { model.account = $0.isEmpty ? nil : $0 })) {
                    if model.accounts.isEmpty { Text("No storage accounts").tag("") }
                    ForEach(model.accounts, id: \.self) { Text($0).tag($0) }
                }
                List(model.containers, id: \.self, selection: $model.container) { name in
                    Label(name, systemImage: "shippingbox").tag(Optional(name))
                }
                .listStyle(.sidebar)
            }
            .padding(.top, 8).padding(.horizontal, 8)
            .frame(minWidth: 200, idealWidth: 240, maxWidth: 360)

            VStack(spacing: 0) {
                header
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

    private var header: some View {
        HStack(spacing: 6) {
            Button { model.goUp() } label: { Image(systemName: "arrow.up") }
                .disabled(model.prefix.isEmpty).help("Enclosing Folder")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    if let container = model.container {
                        Button(container) { model.go(to: "") }
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
            TableColumn("Tier") { Text($0.storageClass).foregroundStyle(.secondary) }
                .width(70)
        }
        .contextMenu(forSelectionType: String.self) { keys in
            let items = model.entries.filter { keys.contains($0.key) }
            if let pane = Workspace.current?.activeTab.url {
                Button("Download to “\(BrowserTab.displayName(of: pane))”") { model.download(items, to: pane) }
            }
            Button("Copy URL") { model.copyURLs(items) }
            Button("Copy SAS Link (7 days, read-only)") { Task { await model.copySASLinks(items) } }
                .disabled(items.allSatisfy(\.isFolder))
            Divider()
            Button("Rename…") { if let item = items.first { Task { await model.rename(item) } } }
                .disabled(items.count != 1 || items.first?.isFolder == true)
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
        .quickHelpArea(FileHelp.remoteList("Blob Storage"))
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            model.upload(files)
            return !files.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 3).padding(2)
            } else if model.entries.isEmpty, !model.loading, model.errorText == nil, model.container != nil {
                ContentUnavailableView("Empty Folder", systemImage: "folder",
                                       description: Text("Drop files here, or use Upload, to add them."))
            } else if model.container == nil, !model.loading, model.errorText == nil {
                ContentUnavailableView("No Container", systemImage: "shippingbox",
                                       description: Text("Choose a storage account with a container."))
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
                .disabled(model.container == nil)
            Button("Upload from “\(paneName ?? "Pane")”") { model.upload(marked) }
                .disabled(model.container == nil || marked.isEmpty)
                .quickHelp("Upload", FileHelp.uploadDetail)
                .help("Upload the items marked in the active pane into this folder")
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
        if model.truncated { text += " · first \(AzureModel.maxItems.formatted()) shown" }
        return text
    }
}
