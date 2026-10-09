//
//  OneDriveAuth.swift
//  MxNoteONE
//
//  Microsoft account sign-in for OneDrive / OneNote: OAuth 2.0
//  authorization code flow with PKCE (a public client, no secret) in the
//  system web sign-in sheet. The refresh token is kept in the Keychain.
//
//  Needs a free app registration in the Azure portal (Settings ▸ OneDrive
//  has the steps): platform "iOS / macOS" with bundle ID
//  com.k3jdr.MxNoteONE, which gives the redirect URI below, and the
//  delegated Microsoft Graph permissions Notes.ReadWrite and User.Read.
//

import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import Security

enum OneDriveError: LocalizedError {
    case noClientID
    case notSignedIn
    case signInCancelled
    case server(String)

    var errorDescription: String? {
        switch self {
        case .noClientID:
            "Enter your Microsoft app (client) ID in Settings ▸ OneDrive first."
        case .notSignedIn:
            "Sign in to OneDrive first (File ▸ OneDrive ▸ Sign In…)."
        case .signInCancelled:
            "Sign-in was cancelled."
        case .server(let message):
            message
        }
    }
}

@Observable
final class OneDriveAuth: NSObject {
    static let shared = OneDriveAuth()

    static let clientIDKey = "oneDriveClientID"
    static let tenantKey = "oneDriveTenant"
    static let accountKey = "oneDriveAccount"
    static let redirectURI = "msauth.com.k3jdr.MxNoteONE://auth"
    static let callbackScheme = "msauth.com.k3jdr.MxNoteONE"
    static let scopes = "offline_access User.Read Notes.ReadWrite"

    /// "Name (user@example.com)" of the signed-in account.
    private(set) var account: String? = UserDefaults.standard.string(forKey: OneDriveAuth.accountKey)
    private(set) var isSignedIn = Keychain.read() != nil

    @ObservationIgnored private var accessToken: String?
    @ObservationIgnored private var expiry = Date.distantPast
    @ObservationIgnored private var session: ASWebAuthenticationSession?

    var clientID: String {
        (UserDefaults.standard.string(forKey: Self.clientIDKey) ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// "common" (personal and work/school accounts), "consumers", "organizations" or a tenant ID.
    var tenant: String {
        let value = (UserDefaults.standard.string(forKey: Self.tenantKey) ?? "").trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? "common" : value
    }

    private var authority: String { "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0" }

    // MARK: Sign in and out

    func signIn() async throws {
        guard !clientID.isEmpty else { throw OneDriveError.noClientID }
        let verifier = Self.randomURLSafe(48)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomURLSafe(16)
        var components = URLComponents(string: authority + "/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: components.url!, callbackURLScheme: Self.callbackScheme) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: OneDriveError.signInCancelled)
                } else {
                    continuation.resume(throwing: error ?? OneDriveError.signInCancelled)
                }
            }
            session.presentationContextProvider = self
            self.session = session
            session.start()
        }
        session = nil
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error_description" })?.value ?? items.first(where: { $0.name == "error" })?.value {
            throw OneDriveError.server(error)
        }
        guard items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value else {
            throw OneDriveError.server("Microsoft sign-in returned an unexpected response.")
        }
        try await requestToken([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "code_verifier": verifier,
        ])
        await loadAccount()
    }

    func signOut() {
        Keychain.delete()
        accessToken = nil
        expiry = .distantPast
        account = nil
        isSignedIn = false
        UserDefaults.standard.removeObject(forKey: Self.accountKey)
    }

    /// A valid access token, refreshed when needed.
    func token(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let accessToken, expiry > Date().addingTimeInterval(60) { return accessToken }
        guard let refresh = Keychain.read() else { throw OneDriveError.notSignedIn }
        guard !clientID.isEmpty else { throw OneDriveError.noClientID }
        try await requestToken(["grant_type": "refresh_token", "refresh_token": refresh])
        guard let accessToken else { throw OneDriveError.notSignedIn }
        return accessToken
    }

    private func requestToken(_ fields: [String: String]) async throws {
        var request = URLRequest(url: URL(string: authority + "/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var all = fields
        all["client_id"] = clientID
        all["scope"] = Self.scopes
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = all.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&").data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let access = json["access_token"] as? String else {
            let message = json["error_description"] as? String ?? json["error"] as? String ?? "Microsoft sign-in failed."
            if (json["error"] as? String) == "invalid_grant" { signOut() }
            throw OneDriveError.server(message.components(separatedBy: "\r\n").first ?? message)
        }
        accessToken = access
        expiry = Date().addingTimeInterval(TimeInterval(json["expires_in"] as? Int ?? 3600))
        if let refresh = json["refresh_token"] as? String { Keychain.save(refresh) }
        isSignedIn = true
    }

    private func loadAccount() async {
        guard let me = try? await GraphClient.shared.json("GET", "/me?$select=displayName,userPrincipalName") else { return }
        let name = me["displayName"] as? String ?? ""
        let email = me["userPrincipalName"] as? String ?? ""
        account = email.isEmpty ? name : (name.isEmpty ? email : "\(name) (\(email))")
        UserDefaults.standard.set(account, forKey: Self.accountKey)
    }

    // MARK: Helpers

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func randomURLSafe(_ bytes: Int) -> String {
        base64URL(Data((0..<bytes).map { _ in UInt8.random(in: 0...255) }))
    }
}

extension OneDriveAuth: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}

/// The OneDrive refresh token in the login Keychain.
enum Keychain {
    private static let service = "com.k3jdr.MxNoteONE.onedrive"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "refresh_token"]
    }

    static func save(_ value: String) {
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    static func read() -> String? {
        var item = query
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
