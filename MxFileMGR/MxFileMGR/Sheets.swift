//
//  Sheets.swift
//  MxFileMGR
//
//  Sheets shown over the main window: copy/move target, name prompts,
//  select by pattern, properties (permissions and dates) and Connect to Server.
//

import AppKit
import NetFS
import SwiftUI

struct WorkspaceSheetView: View {
    let workspace: Workspace
    let sheet: WorkspaceSheet

    var body: some View {
        switch sheet {
        case .transfer(let request): TransferSheet(workspace: workspace, request: request)
        case .name(let prompt): NamePromptSheet(prompt: prompt)
        case .pattern(let select): PatternSheet(workspace: workspace, select: select)
        case .properties(let urls): PropertiesSheet(urls: urls)
        case .connect(let prefill): ConnectServerSheet(workspace: workspace, address: prefill)
        case .webDAV(let account): WebDAVSheet(workspace: workspace, account: account)
        case .sftp(let account): SFTPSheet(workspace: workspace, account: account)
        case .mediaMetadata(let url): MediaMetadataSheet(workspace: workspace, url: url)
        }
    }
}

// MARK: - Copy / move

private struct TransferSheet: View {
    let workspace: Workspace
    let request: TransferRequest
    @State private var destination = ""
    @State private var policy = ConflictPolicy.ask
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let verb = request.move ? "Move" : "Copy"
        VStack(alignment: .leading, spacing: 12) {
            Text(request.sources.count == 1
                 ? "\(verb) “\(request.sources[0].lastPathComponent)” to:"
                 : "\(verb) \(request.sources.count) items to:")
                .font(.headline)
            TextField("Destination", text: $destination)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 460)
            Text("A folder, or for a single item a new path to \(verb.lowercased()) it under another name.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("If an item already exists:", selection: $policy) {
                ForEach(ConflictPolicy.allCases) { Text($0.title).tag($0) }
            }
            .fixedSize()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(verb) {
                    workspace.performTransfer(request, destination: destination, policy: policy)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(destination.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .onAppear { destination = request.destination }
    }
}

// MARK: - Name prompt

private struct NamePromptSheet: View {
    let prompt: NamePrompt
    @State private var text = ""
    @State private var selection: TextSelection?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(prompt.title).font(.headline)
            if !prompt.message.isEmpty { Text(prompt.message) }
            TextField("Name", text: $text, selection: $selection)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 380)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(prompt.okTitle, action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(20)
        .onAppear {
            text = prompt.initial
            if prompt.selectStem, let dot = text.lastIndex(of: "."), dot != text.startIndex {
                selection = TextSelection(range: text.startIndex..<dot)
            }
        }
    }

    private var isValid: Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && (prompt.title == "Go to Folder" || !t.contains("/"))
    }

    private func commit() {
        guard isValid else { return }
        let value = text.trimmingCharacters(in: .whitespaces)
        dismiss()
        // Let the sheet close before the action, which may show an alert.
        DispatchQueue.main.async { prompt.action(value) }
    }
}

// MARK: - Select by pattern

private struct PatternSheet: View {
    let workspace: Workspace
    let select: Bool
    @AppStorage("lastSelectPattern") private var pattern = "*.*"
    @AppStorage("selectPatternFolders") private var includeFolders = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(select ? "Select Group" : "Deselect Group").font(.headline)
            TextField("Pattern", text: $pattern)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 320)
            Text("Wildcards * and ?; separate several patterns with ;  e.g.  *.jpg;*.png")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Include folders", isOn: $includeFolders)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(select ? "Select" : "Deselect") {
                    workspace.selectPattern(pattern, select: select, includeFolders: includeFolders)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}

// MARK: - Properties

private struct PropertiesSheet: View {
    let urls: [URL]
    @State private var permissions = 0o644
    @State private var originalPermissions = 0o644
    @State private var modified = Date()
    @State private var originalModified = Date()
    @State private var created = Date.distantPast
    @State private var owner = ""
    @State private var kind = ""
    @State private var sizeText = "Calculating…"
    @State private var recursive = false
    @Environment(\.dismiss) private var dismiss

    private var hasFolders: Bool { urls.contains(where: FileOps.isRealDirectory) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: urls[0].path))
                    .resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading) {
                    Text(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items")
                        .font(.headline)
                    Text(urls.count == 1 ? urls[0].deletingLastPathComponent().path : urls[0].deletingLastPathComponent().path)
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow { Text("Kind:").foregroundStyle(.secondary); Text(kind) }
                GridRow { Text("Size:").foregroundStyle(.secondary); Text(sizeText) }
                if urls.count == 1 {
                    GridRow { Text("Created:").foregroundStyle(.secondary); Text(Fmt.date(created)) }
                    GridRow { Text("Owner:").foregroundStyle(.secondary); Text(owner) }
                }
                GridRow {
                    Text("Modified:").foregroundStyle(.secondary)
                    DatePicker("", selection: $modified, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                }
            }
            GroupBox("Permissions") {
                Grid(alignment: .center, horizontalSpacing: 18, verticalSpacing: 6) {
                    GridRow {
                        Text("")
                        Text("Read"); Text("Write"); Text("Execute")
                    }
                    .foregroundStyle(.secondary)
                    permissionRow("Owner", shift: 6)
                    permissionRow("Group", shift: 3)
                    permissionRow("Others", shift: 0)
                }
                .padding(6)
                HStack {
                    Text("Octal:").foregroundStyle(.secondary)
                    Text(String(permissions, radix: 8)).monospaced()
                    Spacer()
                    if hasFolders {
                        Toggle("Apply to enclosed items", isOn: $recursive)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    apply()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 440)
        .task { await load() }
    }

    private func permissionRow(_ title: String, shift: Int) -> some View {
        GridRow {
            Text(title).gridColumnAlignment(.leading)
            ForEach([2, 1, 0], id: \.self) { bit in
                let mask = 1 << (shift + bit)
                Toggle("", isOn: Binding(
                    get: { permissions & mask != 0 },
                    set: { permissions = $0 ? (permissions | mask) : (permissions & ~mask) }))
                    .labelsHidden()
            }
        }
    }

    private func load() async {
        let first = urls[0]
        if let attrs = try? FileManager.default.attributesOfItem(atPath: first.path) {
            permissions = (attrs[.posixPermissions] as? Int) ?? 0o644
            originalPermissions = permissions
            modified = (attrs[.modificationDate] as? Date) ?? Date()
            originalModified = modified
            created = (attrs[.creationDate] as? Date) ?? .distantPast
            owner = "\(attrs[.ownerAccountName] as? String ?? "?") : \(attrs[.groupOwnerAccountName] as? String ?? "?")"
        }
        kind = urls.count == 1
            ? ((try? first.resourceValues(forKeys: [.localizedTypeDescriptionKey]))?.localizedTypeDescription ?? "")
            : "Multiple items"
        let list = urls
        let totals = await Task.detached { FileOps.totals(of: list) }.value
        sizeText = "\(Fmt.size(totals.bytes)) (\(totals.bytes.formatted()) bytes), \(Fmt.count(totals.count, "item"))"
    }

    private func apply() {
        let fm = FileManager.default
        var failures: [String] = []
        func set(_ attrs: [FileAttributeKey: Any], on url: URL) {
            do { try fm.setAttributes(attrs, ofItemAtPath: url.path) } catch { failures.append(url.lastPathComponent) }
        }
        let permsChanged = permissions != originalPermissions
        let dateChanged = abs(modified.timeIntervalSince(originalModified)) >= 1
        for url in urls {
            var attrs: [FileAttributeKey: Any] = [:]
            if permsChanged { attrs[.posixPermissions] = permissions }
            if dateChanged { attrs[.modificationDate] = modified }
            if !attrs.isEmpty { set(attrs, on: url) }
            if permsChanged, recursive, FileOps.isRealDirectory(url),
               let e = fm.enumerator(at: url, includingPropertiesForKeys: nil) {
                while let child = e.nextObject() as? URL {
                    // Folders keep their execute (search) bits so they stay openable.
                    let isDir = FileOps.isRealDirectory(child)
                    let mode = isDir ? (permissions | ((permissions & 0o444) >> 2)) : permissions
                    set([.posixPermissions: mode], on: child)
                }
            }
        }
        if !failures.isEmpty {
            Alerts.message("Some items couldn't be changed.", info: failures.prefix(20).joined(separator: "\n"))
        }
        NotificationCenter.default.post(name: .mxFilesChanged, object: nil)
    }
}

// MARK: - Connect to server

/// Mounts SMB, AFP, NFS, WebDAV (http/https) or FTP (read-only) shares with NetFS;
/// the share then appears under Locations and opens in the active pane.
struct ConnectServerSheet: View {
    let workspace: Workspace
    @State var address: String
    @State private var user = ""
    @State private var password = ""
    @State private var connecting = false
    @State private var errorText: String?
    @Environment(\.dismiss) private var dismiss
    private var settings = AppSettings.shared

    init(workspace: Workspace, address: String) {
        self.workspace = workspace
        _address = State(initialValue: address.isEmpty ? "smb://" : address)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect to Server").font(.headline)
            TextField("Server address", text: $address, prompt: Text("smb://server/share"))
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 420)
            Text("smb://, afp://, nfs://, ftp:// (read-only), http:// or https:// (WebDAV)")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("User (optional)", text: $user).textFieldStyle(.roundedBorder)
                SecureField("Password", text: $password).textFieldStyle(.roundedBorder)
            }
            if !settings.recentServers.isEmpty {
                Picker("Recent:", selection: $address) {
                    if !settings.recentServers.contains(address) { Text(address).tag(address) }
                    ForEach(settings.recentServers, id: \.self) { Text($0).tag($0) }
                }
            }
            if let errorText {
                Text(errorText).foregroundStyle(.red).font(.callout)
            }
            HStack {
                if connecting { ProgressView().controlSize(.small); Text("Connecting…") }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect", action: connect)
                    .keyboardShortcut(.defaultAction)
                    .disabled(connecting || URL(string: address)?.host() == nil)
            }
        }
        .padding(20)
    }

    private func connect() {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespaces)) else { return }
        connecting = true
        errorText = nil
        var requestID: AsyncRequestID?
        let status = NetFSMountURLAsync(
            url as CFURL, nil,
            user.isEmpty ? nil : user as CFString,
            password.isEmpty ? nil : password as CFString,
            nil, nil, &requestID, DispatchQueue.main
        ) { status, _, mountpoints in
            connecting = false
            if status == 0, let paths = mountpoints as? [String], let first = paths.first {
                settings.addRecentServer(address)
                VolumeMonitor.shared.refresh()
                workspace.go(to: URL(fileURLWithPath: first))
                dismiss()
            } else if status == Int32(ECANCELED) || status == -128 {
                errorText = nil
            } else {
                errorText = "Couldn't connect (\(status)): \(String(cString: strerror(status)))"
            }
        }
        if status != 0 {
            connecting = false
            errorText = "Couldn't connect (\(status)): \(String(cString: strerror(status)))"
        }
    }
}
