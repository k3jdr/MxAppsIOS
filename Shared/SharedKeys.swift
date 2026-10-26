//
//  SharedKeys.swift
//  Shared by MxDataHUB, MxJobsMGR and MxAcctMGR (MxAppsIOS/Shared)
//
//  Keychain items MxAcctMGR and MxJobsMGR both read: Secure Accounts' service keys, which are the API keys MxJobsMGR's
//  subscriptions send. An item trusts only the app that made it, so the other app would ask for the login keychain
//  password to read it; these are made trusting both (each by its bundle id and signing certificate, so rebuilds and
//  re-signing keep matching).
//

import AppKit
import Security

nonisolated enum SharedKeys {
    /// Access for a new item: this app and `partner` as installed (only this app when it isn't). Self-tests name a test
    /// build instead (-secureAccountsPartner /path/to/the/other.app).
    static func access(label: String, partner bundleID: String) -> SecAccess? {
        var mine: SecTrustedApplication?
        guard SecTrustedApplicationCreateFromPath(nil, &mine) == errSecSuccess, let mine else { return nil }
        // The sandbox reads only /Applications among these: a copy Launch Services knows elsewhere (a build folder) is
        // passed over for the installed one. The trust is by bundle id and certificate, so either copy gives the same.
        var paths = [NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path,
                     "/Applications/\(bundleID.split(separator: ".").last ?? "").app"].compactMap { $0 }
        #if DEBUG
        if let path = UserDefaults.standard.string(forKey: "secureAccountsPartner") { paths = [path] }
        #endif
        let partner: SecTrustedApplication? = paths.lazy.compactMap { path in
            var app: SecTrustedApplication?
            return SecTrustedApplicationCreateFromPath(path, &app) == errSecSuccess ? app : nil
        }.first
        var access: SecAccess?
        return SecAccessCreate(label as CFString, ([mine] + (partner.map { [$0] } ?? [])) as CFArray, &access) == errSecSuccess ? access : nil
    }

    /// Saves a generic password under `match` (service and account) trusting both apps; answers whether the Keychain
    /// took it. An item the other app made keeps its own access (only its maker may change that).
    static func save(_ value: String, label: String, match: [String: Any], partner bundleID: String) -> Bool {
        var update: [String: Any] = [kSecValueData as String: Data(value.utf8), kSecAttrLabel as String: label]
        let access = Self.access(label: label, partner: bundleID)
        var status = errSecItemNotFound
        if let access {
            update[kSecAttrAccess as String] = access
            status = SecItemUpdate(match as CFDictionary, update as CFDictionary)
            update[kSecAttrAccess as String] = nil
        }
        if status == errSecInvalidOwnerEdit || (access == nil && status == errSecItemNotFound) {
            status = SecItemUpdate(match as CFDictionary, update as CFDictionary)
        }
        if status == errSecItemNotFound {
            var add = match.merging(update) { a, _ in a }
            if let access { add[kSecAttrAccess as String] = access }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        return status == errSecSuccess
    }
}
