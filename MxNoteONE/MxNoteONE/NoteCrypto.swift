//
//  NoteCrypto.swift
//  MxNoteONE
//
//  Password protection for sections: a 256-bit key is derived from the
//  password with PBKDF2-SHA256, and files are sealed with AES-GCM.
//

import CommonCrypto
import CryptoKit
import Foundation

enum NoteCrypto {
    static let rounds: UInt32 = 200_000

    static func randomSalt() -> Data {
        Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    }

    static func deriveKey(password: String, salt: Data) -> SymmetricKey {
        var derived = [UInt8](repeating: 0, count: 32)
        let passwordBytes = Array(password.utf8)
        salt.withUnsafeBytes { saltBuffer in
            passwordBytes.withUnsafeBufferPointer { pw in
                pw.baseAddress!.withMemoryRebound(to: CChar.self, capacity: max(pw.count, 1)) { pwChars in
                    _ = CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwChars, pw.count,
                        saltBuffer.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds,
                        &derived, derived.count)
                }
            }
        }
        return SymmetricKey(data: derived)
    }

    /// A value stored next to the salt that tells whether a password is right.
    static func verifier(for key: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("MxNoteONE section key".utf8), using: key))
    }

    static func makeProtection(password: String, hint: String) -> (Protection, SymmetricKey) {
        let salt = randomSalt()
        let key = deriveKey(password: password, salt: salt)
        return (Protection(salt: salt, verifier: verifier(for: key), hint: hint), key)
    }

    /// The key for the password, or nil if the password is wrong.
    static func unlock(_ protection: Protection, password: String) -> SymmetricKey? {
        let key = deriveKey(password: password, salt: protection.salt)
        return verifier(for: key) == protection.verifier ? key : nil
    }

    static func seal(_ data: Data, key: SymmetricKey) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: key).combined else {
            throw CocoaError(.fileWriteUnknown)
        }
        return combined
    }

    static func open(_ data: Data, key: SymmetricKey) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key)
    }
}
