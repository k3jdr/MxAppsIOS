//
//  Keychain.swift
//  MxJobsWMS
//
//  Stores API subscription keys as generic passwords in the login Keychain,
//  keyed by "subscription-<uuid>". Keys are never written to jobspace files.
//

import Foundation
import Observation
import Security

/// Bumped whenever a key is saved or removed. Views that show key status read it, so they redraw
/// (the Keychain itself is not observable).
@Observable
final class KeychainChanges {
    static let shared = KeychainChanges()
    private(set) var revision = 0
    func bump() { revision += 1 }
}

enum Keychain {
    private static let service = "com.k3jdr.MxJobsWMS"

    static func secret(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func hasSecret(for account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func setSecret(_ secret: String, for account: String, label: String) -> Bool {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(secret.utf8)
        var status = SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = match
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "MxJobsWMS: \(label)"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status == errSecSuccess { KeychainChanges.shared.bump() }
        return status == errSecSuccess
    }

    static func deleteSecret(for account: String) {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(match as CFDictionary)
        KeychainChanges.shared.bump()
    }
}
