//
//  SecureAccounts.swift
//  MxJobsMGR
//
//  The secure accounts an API subscription can send the key of: MxAcctMGR ▸ Banking ▸ Secure Accounts, read through
//  the accounts service (Services/accounts, 127.0.0.1:8774) — or, while it isn't running, from the Keychain items that
//  hold their service keys (SecureKeys.stored). API Subscriptions picks one; MxAcctMGR adds, edits and removes the keys.
//

import SwiftUI

nonisolated struct SecureAccountRef: Decodable, Identifiable, Hashable, Sendable {
    var id: Int
    var name: String
    var status = "active"
    var serviceApi: String?
}

/// The accounts service's secure-account endpoints (Services/accounts/secure.py).
nonisolated enum SecureAccountsClient {
    struct Failure: LocalizedError {
        var errorDescription: String?
    }
    private struct List: Decodable {
        var secureAccounts: [SecureAccountRef]
        var id: Int?
    }

    static let base: String = {
        #if DEBUG
        // Self-tests: a test instance of the service (-accountsPort 18774).
        if let port = UserDefaults.standard.string(forKey: "accountsPort") { return "http://127.0.0.1:\(port)" }
        #endif
        return "http://127.0.0.1:8774"
    }()

    static func list() async throws -> [SecureAccountRef] {
        try await request("GET", "/secure-accounts", body: nil).secureAccounts
    }

    /// Makes a secure account; answers its id and the list after it.
    static func create(name: String, serviceApi: String, serviceUrl: String, description: String) async throws -> (id: Int, accounts: [SecureAccountRef]) {
        let body: [String: Any] = ["name": name, "serviceApi": serviceApi, "serviceUrl": serviceUrl, "description": description,
                                   "status": "active", "by": "MxJobsMGR"]
        let answer = try await request("PUT", "/secure-accounts/0", body: body)
        guard let id = answer.id else { throw Failure(errorDescription: "The accounts service made “\(name)” but didn't say its id.") }
        return (id, answer.secureAccounts)
    }

    private static func request(_ method: String, _ path: String, body: [String: Any]?) async throws -> List {
        var r = URLRequest(url: URL(string: base + path)!, timeoutInterval: 20)
        r.httpMethod = method
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: r)
        } catch {
            throw Failure(errorDescription: "The accounts service (127.0.0.1:8774) isn't answering: start it from MxDataHUB ▸ Services "
                          + "or with python3 Services/mxservices.py start.")
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let error = json["error"] as? String {
            throw Failure(errorDescription: "Secure Accounts: \(error)")
        }
        do {
            return try JSONDecoder().decode(List.self, from: data)
        } catch {
            throw Failure(errorDescription: "The accounts service answered in an unexpected form (\(error.localizedDescription)).")
        }
    }
}

/// MxAcctMGR's secure accounts, read again each time MxJobsMGR becomes active (KeychainChanges).
@Observable
final class SecureAccountsList {
    static let shared = SecureAccountsList()
    /// nil until read.
    private(set) var accounts: [SecureAccountRef]?
    /// Why the accounts service couldn't be read; the list then holds only the accounts that have a service key.
    private(set) var problem: String?
    private var loadedAt = -1

    func loadIfNeeded() async {
        let revision = KeychainChanges.shared.revision
        guard loadedAt != revision else { return }
        loadedAt = revision
        do {
            accounts = try await SecureAccountsClient.list()
            problem = nil
        } catch {
            accounts = SecureKeys.stored().map { SecureAccountRef(id: $0.key, name: $0.value) }.sorted { $0.name.lowercased() < $1.name.lowercased() }
            problem = error.localizedDescription
        }
    }

    func replace(_ accounts: [SecureAccountRef]) {
        self.accounts = accounts
        problem = nil
    }

    func account(_ id: Int?) -> SecureAccountRef? {
        guard let id else { return nil }
        return accounts?.first { $0.id == id }
    }

    func named(_ name: String) -> SecureAccountRef? {
        let name = name.trimmingCharacters(in: .whitespaces).lowercased()
        return name.isEmpty ? nil : accounts?.first { $0.name.lowercased() == name }
    }

    /// Links each subscription that needs a key but has no secure account yet to the account of the name it was given
    /// (a sample's, or New in MxAcctMGR…'s), or else of its own name; and keeps linked ones' names as MxAcctMGR has them
    /// now. Subscriptions whose key is still to be moved are left to Move Keys. Answers whether it changed any.
    @discardableResult
    func link(_ space: inout Jobspace) -> Bool {
        guard accounts != nil else { return false }
        var changed = false
        for i in space.subscriptions.indices {
            let sub = space.subscriptions[i]
            if sub.secureAccountID == nil, sub.auth != .none, !SecureKeys.hasLegacyKey(sub),
               let a = named(sub.secureAccountName.isEmpty ? sub.name : sub.secureAccountName) {
                space.subscriptions[i].secureAccountID = a.id
                space.subscriptions[i].secureAccountName = a.name
                changed = true
            } else if let a = account(sub.secureAccountID), a.name != sub.secureAccountName, problem == nil {
                space.subscriptions[i].secureAccountName = a.name
                changed = true
            }
        }
        return changed
    }
}

/// API Subscriptions ▸ Key: the secure account whose service key the calls send, its status, Test Key, and the way to
/// MxAcctMGR, where keys are entered and changed.
struct SecureAccountSection: View {
    @Binding var subscription: ApiSubscription
    var list = SecureAccountsList.shared
    @State private var message: String?
    @State private var testing = false
    @State private var testResult: KeyTestResult?

    var body: some View {
        let _ = KeychainChanges.shared.revision  // redraw when MxAcctMGR may have changed a key
        let accounts = list.accounts ?? []
        Picker("Secure account", selection: $subscription.secureAccountID) {
            Text("None").tag(Int?.none)
            ForEach(accounts.filter { $0.status == "active" || $0.id == subscription.secureAccountID }) { a in
                Text(a.name + (SecureKeys.hasKey(a.id) ? "" : " — no service key")).tag(Int?.some(a.id))
            }
            if let id = subscription.secureAccountID, !accounts.contains(where: { $0.id == id }) {
                Text(subscription.secureAccountName.isEmpty ? "Secure account \(id)" : subscription.secureAccountName).tag(Int?.some(id))
            }
        }
        .onChange(of: subscription.secureAccountID) { _, id in
            if let a = list.account(id) { subscription.secureAccountName = a.name } else if id == nil { subscription.secureAccountName = "" }
            testResult = nil
        }
        .help("The account in MxAcctMGR ▸ Secure Accounts whose service key this subscription's calls send")
        if let problem = list.problem {
            Text(problem + " Only the secure accounts that already have a service key are listed.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        HStack {
            if subscription.secureAccountID == nil {
                Label(subscription.secureAccountName.isEmpty ? "No secure account chosen" : "Links to “\(subscription.secureAccountName)” once it is in Secure Accounts",
                      systemImage: "key.slash").foregroundStyle(.orange)
            } else if SecureKeys.hasKey(for: subscription) {
                Label("Service key in Secure Accounts", systemImage: "key.fill").foregroundStyle(.green)
            } else {
                Label("No service key in “\(subscription.secureAccountName)” yet", systemImage: "key.slash").foregroundStyle(.orange)
            }
            Spacer()
            if SecureKeys.hasKey(for: subscription) {
                Button { runKeyTest() } label: { Label("Test Key", systemImage: "checkmark.shield") }
                    .disabled(testing)
            }
        }
        HStack {
            Spacer()
            if let id = subscription.secureAccountID {
                Button("Open in MxAcctMGR") { open(.secureAccount(id)) }
                    .help("Show this secure account in MxAcctMGR ▸ Secure Accounts, where its service key is entered and changed")
            } else {
                Button("New in MxAcctMGR…") {
                    if subscription.secureAccountName.isEmpty { subscription.secureAccountName = subscription.name }
                    open(.newSecureAccount(name: subscription.secureAccountName, api: subscription.baseURL, url: subscription.docsURL))
                }
                .help("Make a secure account for this subscription in MxAcctMGR ▸ Secure Accounts and put its key there; "
                      + "back here, the subscription links to it by name")
            }
        }
        .controlSize(.small)
        if let message {
            Text(message).font(.caption).foregroundStyle(.secondary)
        }
        if testing {
            HStack { ProgressView().controlSize(.small); Text("Testing the key…").font(.caption) }
        } else if let testResult {
            Label(testResult.message, systemImage: testResult.symbol)
                .font(.caption)
                .foregroundStyle(testResult.color)
                .textSelection(.enabled)
        }
    }

    private func open(_ link: AppLink) {
        message = link.open() ? nil : "MxAcctMGR is not installed: it keeps the API keys (Banking ▸ Secure Accounts)."
    }

    private func runKeyTest() {
        testing = true
        testResult = nil
        let sub = subscription
        Task {
            testResult = await KeyTester.test(sub)
            testing = false
        }
    }
}
