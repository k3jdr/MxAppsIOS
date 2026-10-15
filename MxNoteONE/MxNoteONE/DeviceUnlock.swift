//
//  DeviceUnlock.swift
//  MxNoteONE
//
//  Unlocking with the Mac's own security: Touch ID, an Apple Watch, or the
//  Mac's login password (LocalAuthentication). A protected section's key can
//  be kept in the Keychain so the section opens with Touch ID instead of its
//  password; the key is released only after the Mac confirms it's you. The
//  same check can lock MxNoteONE itself (Settings ▸ Security).
//

import CryptoKit
import Foundation
import LocalAuthentication
import Security

enum DeviceUnlock {
    private static let service = "com.k3jdr.MxNoteONE.section-key"
    private static let enrolledKey = "deviceUnlockSections"
    static let appLockKey = "requireDeviceUnlockToOpen"

    /// Whether this Mac can confirm its owner (Touch ID, Apple Watch or the login password).
    static var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// "Touch ID", "Optic ID", or "your Mac password" — what the user will be asked for.
    static var methodName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "your Mac password"
        }
    }

    /// SF Symbol for the method.
    static var symbol: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType == .touchID ? "touchid" : context.biometryType == .opticID ? "opticid" : "lock.shield"
    }

    // MARK: Asking the Mac

    /// Asks for Touch ID / Apple Watch / the Mac password. Calls back on the main queue.
    static func authenticate(reason: String, context: LAContext = LAContext(), completion: @escaping @MainActor (Bool) -> Void) {
        #if DEBUG
        if let bypass = testBypass { return DispatchQueue.main.async { MainActor.assumeIsolated { completion(bypass) } } }
        #endif
        context.localizedCancelTitle = "Use Password"
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(success) } }
        }
    }

    #if DEBUG
    /// Self-tests answer the prompt (true = confirmed, false = cancelled).
    nonisolated(unsafe) static var testBypass: Bool?
    #endif

    // MARK: Section keys

    /// Sections that open with Touch ID.
    static func isEnrolled(_ section: UUID) -> Bool {
        (UserDefaults.standard.stringArray(forKey: enrolledKey) ?? []).contains(section.uuidString)
    }

    private static func setEnrolled(_ section: UUID, _ on: Bool) {
        var list = Set(UserDefaults.standard.stringArray(forKey: enrolledKey) ?? [])
        if on { list.insert(section.uuidString) } else { list.remove(section.uuidString) }
        UserDefaults.standard.set(list.sorted(), forKey: enrolledKey)
    }

    private static func query(_ section: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: section.uuidString]
    }

    /// Keeps a section's key in the Keychain (only this app can read it, on this Mac, while it's unlocked).
    @discardableResult
    static func save(_ key: SymmetricKey, for section: UUID) -> Bool {
        SecItemDelete(query(section) as CFDictionary)
        var item = query(section)
        item[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecAttrLabel as String] = "MxNoteONE section key"
        let status = SecItemAdd(item as CFDictionary, nil)
        setEnrolled(section, status == errSecSuccess)
        return status == errSecSuccess
    }

    static func remove(_ section: UUID) {
        SecItemDelete(query(section) as CFDictionary)
        setEnrolled(section, false)
    }

    /// The section's key, after the Mac confirms it's you (nil when cancelled or not kept).
    static func key(for section: UUID, reason: String, completion: @escaping @MainActor (SymmetricKey?) -> Void) {
        guard isEnrolled(section) else { return DispatchQueue.main.async { MainActor.assumeIsolated { completion(nil) } } }
        authenticate(reason: reason) { confirmed in
            guard confirmed else { return completion(nil) }
            var item = query(section)
            item[kSecReturnData as String] = true
            item[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: AnyObject?
            guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
                setEnrolled(section, false)
                return completion(nil)
            }
            completion(SymmetricKey(data: data))
        }
    }

    // MARK: App lock

    /// Require Touch ID / the Mac password to open MxNoteONE (and after it auto-locks).
    static var appLockEnabled: Bool {
        UserDefaults.standard.bool(forKey: appLockKey) && isAvailable
    }
}
