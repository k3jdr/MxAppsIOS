//
//  WebDAV.swift
//  MxFileMGR
//
//  WebDAV accounts in Favorites: a saved server (name, address, user), with the
//  password kept in the login Keychain if you choose. Clicking one mounts the
//  share with NetFS — or finds it already mounted — and opens it in the active
//  pane like any folder. Mounted shares also show under Locations.
//

import AppKit
import NetFS
import Security
import SwiftUI

struct WebDAVAccount: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    /// http:// or https:// address of the share, e.g. https://cloud.example.com/remote.php/dav/files/me
    var address: String
    var user: String

    var url: URL? { URL(string: address.trimmingCharacters(in: .whitespaces)) }

    /// Scheme, host, port and path without a trailing slash, for matching against mounted volumes.
    static func normalized(_ url: URL) -> String {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false) ?? URLComponents()
        c.user = nil
        c.password = nil
        c.query = nil
        c.fragment = nil
        var path = c.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        c.percentEncodedPath = path
        return (c.string ?? url.absoluteString).lowercased()
    }
}

/// Saved passwords in the login Keychain (generic passwords, one per account id), for WebDAV and SFTP accounts.
nonisolated struct PasswordKeychain {
    let service: String

    static let webDAV = PasswordKeychain(service: "com.k3jdr.MxFileMGR.webdav")
    static let sftp = PasswordKeychain(service: "com.k3jdr.MxFileMGR.sftp")

    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }

    func password(for id: UUID) -> String? {
        var q = query(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ password: String, for id: UUID, label: String) {
        let data = Data(password.utf8)
        let q = query(id)
        if SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = label
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    func delete(for id: UUID) {
        SecItemDelete(query(id) as CFDictionary)
    }
}

@Observable
final class WebDAVStore {
    static let shared = WebDAVStore()
    private static let key = "webDAVAccounts"

    private(set) var accounts: [WebDAVAccount] = []
    /// Accounts being mounted right now.
    private(set) var connecting: Set<UUID> = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let list = try? JSONDecoder().decode([WebDAVAccount].self, from: data) {
            accounts = list
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(accounts) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    func upsert(_ account: WebDAVAccount) {
        if let i = accounts.firstIndex(where: { $0.id == account.id }) { accounts[i] = account } else { accounts.append(account) }
        save()
    }

    func remove(_ account: WebDAVAccount) {
        accounts.removeAll { $0.id == account.id }
        PasswordKeychain.webDAV.delete(for: account.id)
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        accounts.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// Where the account's share is mounted now, found from the volumes' remount URLs.
    func mountPoint(for account: WebDAVAccount) -> URL? {
        guard let url = account.url else { return nil }
        let wanted = WebDAVAccount.normalized(url)
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeURLForRemountingKey],
                                                            options: [.skipHiddenVolumes]) ?? []
        return volumes.first { volume in
            guard let remount = (try? volume.resourceValues(forKeys: [.volumeURLForRemountingKey]))?.volumeURLForRemounting
            else { return false }
            return WebDAVAccount.normalized(remount) == wanted
        }
    }

    /// Opens the account's share in the workspace, mounting it first if needed. `password` overrides the Keychain.
    func connect(_ account: WebDAVAccount, password: String? = nil, in workspace: Workspace?,
                 completion: ((String?) -> Void)? = nil) {
        if let mounted = mountPoint(for: account) {
            workspace?.go(to: mounted)
            completion?(nil)
            return
        }
        guard let url = account.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            let message = "“\(account.address)” isn't an http:// or https:// address."
            if let completion { completion(message) } else { Alerts.message("Couldn't connect to “\(account.name)”.", info: message) }
            return
        }
        let secret = password ?? PasswordKeychain.webDAV.password(for: account.id)
        connecting.insert(account.id)
        var requestID: AsyncRequestID?
        // Without a password NetFS shows macOS's own sign-in dialog.
        let status = NetFSMountURLAsync(
            url as CFURL, nil,
            account.user.isEmpty ? nil : account.user as CFString,
            secret.flatMap { $0.isEmpty ? nil : $0 as CFString },
            nil, nil, &requestID, DispatchQueue.main
        ) { [weak self] status, _, mountpoints in
            self?.connecting.remove(account.id)
            if status == 0, let paths = mountpoints as? [String], let first = paths.first {
                VolumeMonitor.shared.refresh()
                workspace?.go(to: URL(fileURLWithPath: first))
                completion?(nil)
            } else if status == Int32(ECANCELED) || status == -128 {
                completion?(nil)
            } else {
                let message = Self.describe(status)
                if let completion { completion(message) } else { Alerts.message("Couldn't connect to “\(account.name)”.", info: message) }
            }
        }
        if status != 0 {
            connecting.remove(account.id)
            let message = Self.describe(status)
            if let completion { completion(message) } else { Alerts.message("Couldn't connect to “\(account.name)”.", info: message) }
        }
    }

    func disconnect(_ account: WebDAVAccount) {
        guard let mounted = mountPoint(for: account) else { return }
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: mounted)
            VolumeMonitor.shared.refresh()
        } catch {
            Alerts.message("Couldn't disconnect “\(account.name)”.", info: error.localizedDescription)
        }
    }

    private static func describe(_ status: Int32) -> String {
        switch status {
        case Int32(EAUTH), Int32(EPERM), Int32(EACCES): "The server refused the user name or password (\(status))."
        case Int32(ENOENT): "The address wasn't found on the server (\(status))."
        case Int32(ETIMEDOUT), Int32(EHOSTUNREACH), Int32(ECONNREFUSED): "The server didn't answer (\(status))."
        default: "Error \(status): \(String(cString: strerror(status)))"
        }
    }
}

/// Adds or edits a WebDAV account; Connect saves it and opens the share.
struct WebDAVSheet: View {
    let workspace: Workspace
    @State private var account: WebDAVAccount
    @State private var password = ""
    @State private var remember = true
    @State private var working = false
    @State private var errorText: String?
    private let isNew: Bool
    @Environment(\.dismiss) private var dismiss

    init(workspace: Workspace, account: WebDAVAccount?) {
        self.workspace = workspace
        isNew = account == nil
        let start = account ?? WebDAVAccount(name: "", address: "https://", user: "")
        _account = State(initialValue: start)
        let saved = account.flatMap { PasswordKeychain.webDAV.password(for: $0.id) }
        _password = State(initialValue: saved ?? "")
        _remember = State(initialValue: account == nil || saved != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "Add WebDAV Account" : "Edit WebDAV Account").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Name:")
                    TextField("e.g. Nextcloud", text: $account.name)
                }
                GridRow {
                    Text("Address:")
                    TextField("https://server/remote.php/dav/files/user", text: $account.address)
                }
                GridRow {
                    Text("User:")
                    TextField("Optional", text: $account.user)
                }
                GridRow {
                    Text("Password:")
                    SecureField("Optional — asked when connecting if left empty", text: $password)
                }
                GridRow {
                    Text("")
                    Toggle("Remember password in Keychain", isOn: $remember)
                }
            }
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 480)
            Text("Nextcloud, ownCloud, Synology, QNAP, Box, SharePoint (DAV) and other WebDAV servers. Use https:// whenever the server supports it.")
                .font(.caption).foregroundStyle(.secondary)
            if let errorText {
                Text(errorText).foregroundStyle(.red).font(.callout)
            }
            HStack {
                if working { ProgressView().controlSize(.small); Text("Connecting…") }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save(); dismiss() }
                    .disabled(!isValid)
                Button("Connect") { connect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid || working)
            }
        }
        .padding(20)
        .quickHelpScreen(isNew ? "Add WebDAV Account" : "Edit WebDAV Account", FileHelp.webDAVSheet)
    }

    private var isValid: Bool {
        guard let url = account.url, let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https"].contains(scheme) && url.host() != nil
    }

    private func save() {
        if account.name.trimmingCharacters(in: .whitespaces).isEmpty {
            account.name = account.url?.host() ?? "WebDAV"
        }
        WebDAVStore.shared.upsert(account)
        if remember, !password.isEmpty {
            PasswordKeychain.webDAV.save(password, for: account.id, label: "MxFileMGR WebDAV: \(account.name)")
        } else {
            PasswordKeychain.webDAV.delete(for: account.id)
        }
    }

    private func connect() {
        save()
        working = true
        errorText = nil
        WebDAVStore.shared.connect(account, password: password, in: workspace) { error in
            working = false
            if let error { errorText = error } else { dismiss() }
        }
    }
}
