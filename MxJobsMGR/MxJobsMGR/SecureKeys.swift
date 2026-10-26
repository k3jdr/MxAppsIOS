//
//  SecureKeys.swift
//  MxJobsMGR
//
//  API subscription keys live in MxAcctMGR ▸ Banking ▸ Secure Accounts: a subscription names a secure account
//  (srm.secure_account) and its calls send that account's service key, which MxAcctMGR keeps in the login Keychain
//  (service com.k3jdr.MxAcctMGR.secure-accounts, account "<id> service key"), made trusting both apps
//  (Shared/SharedKeys.swift) so MxJobsMGR reads them without a password prompt. Keys are never written to jobspace
//  files, and MxJobsMGR has no place to type one.
//
//  The keys MxJobsMGR kept itself before (service com.k3jdr.MxJobsMGR, earlier com.k3jdr.MxJobsWMS, account
//  subscription-<uuid>) are read once more by Move Keys to Secure Accounts (KeyMove.swift), which then deletes them —
//  the ones it can: only the app that made an item may delete it, so items MxJobsWMS made stay until removed in
//  Keychain Access (unused once the subscription has a secure account).
//

import AppKit
import Observation
import Security

/// Bumped when keys may have changed: each time MxJobsMGR becomes active (they are edited in MxAcctMGR) and after a
/// key move. Views that show key status read it, so they redraw (the Keychain itself is not observable).
@Observable
final class KeychainChanges {
    static let shared = KeychainChanges()
    private(set) var revision = 0
    func bump() { revision += 1 }

    private init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { KeychainChanges.shared.bump() }
        }
    }
}

nonisolated enum SecureKeys {
    /// MxAcctMGR's Secure Accounts items. Self-tests read a test build's instead
    /// (-secureAccountsService com.k3jdr.MxAcctMGR.earningstest.secure-accounts).
    static var service: String {
        #if DEBUG
        if let service = UserDefaults.standard.string(forKey: "secureAccountsService") { return service }
        #endif
        return AppLink.acctBundleID + ".secure-accounts"
    }

    private static func account(_ id: Int) -> String { "\(id) service key" }

    private static func match(_ account: String, in service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private static func read(_ account: String, in service: String) -> String? {
        var query = match(account, in: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func exists(_ account: String, in service: String) -> Bool {
        SecItemCopyMatching(match(account, in: service) as CFDictionary, nil) == errSecSuccess
    }

    /// The service key of the subscription's secure account, sent with its calls.
    static func key(for sub: ApiSubscription) -> String? {
        sub.secureAccountID.flatMap(key)
    }

    static func hasKey(for sub: ApiSubscription) -> Bool {
        sub.secureAccountID.map(hasKey) ?? false
    }

    static func key(_ id: Int) -> String? { read(account(id), in: service) }

    static func hasKey(_ id: Int) -> Bool { exists(account(id), in: service) }

    /// The secure accounts that have a service key, with their names as the items' labels give them ("MxAcctMGR:
    /// <name> (service key)"): the picker's list when the accounts service isn't running.
    static func stored() -> [Int: String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess, let all = items as? [[String: Any]] else { return [:] }
        var names: [Int: String] = [:]
        for item in all {
            guard let account = item[kSecAttrAccount as String] as? String, account.hasSuffix(" service key"),
                  let id = Int(account.dropLast(" service key".count)) else { continue }
            var name = item[kSecAttrLabel as String] as? String ?? "#\(id)"
            if name.hasPrefix("MxAcctMGR: ") { name.removeFirst("MxAcctMGR: ".count) }
            if name.hasSuffix(" (service key)") { name.removeLast(" (service key)".count) }
            names[id] = name
        }
        return names
    }

    /// Puts a key in a secure account, labeled as MxAcctMGR labels them. Only Move Keys does this: MxAcctMGR edits them.
    @discardableResult
    static func store(_ key: String, account id: Int, name: String) -> Bool {
        SharedKeys.save(key, label: "MxAcctMGR: \(name) (service key)", match: match(account(id), in: service), partner: AppLink.acctBundleID)
    }

    // MARK: Keys MxJobsMGR kept itself, before Secure Accounts

    /// Its own service, then the one it had while it was MxJobsWMS.
    private static let legacyServices = ["com.k3jdr.MxJobsMGR", "com.k3jdr.MxJobsWMS"]

    private static func legacyAccount(_ sub: ApiSubscription) -> String { "subscription-\(sub.id.uuidString)" }

    static func hasLegacyKey(_ sub: ApiSubscription) -> Bool {
        legacyServices.contains { exists(legacyAccount(sub), in: $0) }
    }

    static func legacyKey(_ sub: ApiSubscription) -> String? {
        legacyServices.lazy.compactMap { read(legacyAccount(sub), in: $0) }.first
    }

    /// Answers whether none is left (an item another app made answers errSecInvalidOwnerEdit and stays).
    @discardableResult
    static func deleteLegacyKey(_ sub: ApiSubscription) -> Bool {
        legacyServices.map { SecItemDelete(match(legacyAccount(sub), in: $0) as CFDictionary) }
            .allSatisfy { $0 == errSecSuccess || $0 == errSecItemNotFound }
    }
}
