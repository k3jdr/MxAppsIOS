//
//  Keychain.swift
//  MxDataSQL
//
//  Stores database passwords as generic passwords in the login Keychain,
//  keyed by "user@host:port/database".
//

import Foundation
import Security

enum Keychain {
    private static let service = "com.k3jdr.MxDataSQL"
    /// The service passwords were saved under before the app was renamed. A password still there is
    /// moved to `service` the first time it is needed (macOS asks once to let this app read it).
    private static let legacyService = "com.k3jdr.MxDataSRM"

    static func password(for account: String) -> String? {
        if let password = read(service, account) { return password }
        guard let password = read(legacyService, account) else { return nil }
        setPassword(password, for: account)
        if read(service, account) != nil {
            SecItemDelete(match(legacyService, account) as CFDictionary)
        }
        return password
    }

    static func setPassword(_ password: String, for account: String) {
        let data = Data(password.utf8)
        let status = SecItemUpdate(match(service, account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = match(service, account)
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "MxDataSQL: \(account)"
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func deletePassword(for account: String) {
        SecItemDelete(match(service, account) as CFDictionary)
        SecItemDelete(match(legacyService, account) as CFDictionary)
    }

    private static func match(_ service: String, _ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func read(_ service: String, _ account: String) -> String? {
        var query = match(service, account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
