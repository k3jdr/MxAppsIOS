//
//  KeyMove.swift
//  MxJobsMGR
//
//  Move Keys to Secure Accounts: the API keys MxJobsMGR kept in its own Keychain items before MxAcctMGR ▸ Secure
//  Accounts took them over (service com.k3jdr.MxJobsMGR, or com.k3jdr.MxJobsWMS from before the rename). Each goes to
//  the secure account of its subscription's name — made through the accounts service when there is none — as that
//  account's service key; the subscription is linked to the account and the old item is deleted when MxJobsMGR may
//  (an item MxJobsWMS made can only be deleted by it, or in Keychain Access). Offered once per window when the open
//  jobspace has such keys, and from API Subscriptions.
//

import SwiftUI

enum KeyMove {
    /// The subscriptions whose key is still in MxJobsMGR's own Keychain items.
    static func pending(_ space: Jobspace) -> [ApiSubscription] {
        space.subscriptions.filter { $0.auth != .none && $0.secureAccountID == nil && SecureKeys.hasLegacyKey($0) }
    }
}

struct KeyMoveSheet: View {
    @Binding var space: Jobspace
    @Environment(\.dismiss) private var dismiss
    @State private var subscriptions: [ApiSubscription] = []
    /// What happened to each subscription's key.
    @State private var results: [UUID: String] = [:]
    @State private var moving = false
    @State private var done = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Move API Keys to Secure Accounts").font(.title3.bold())
            Text("MxAcctMGR ▸ Banking ▸ Secure Accounts keeps the API keys now. These subscriptions still have theirs in "
                 + "MxJobsMGR's own Keychain items: each key becomes the service key of the secure account with the "
                 + "subscription's name (made if there is none), the subscription is linked to that account, and the old "
                 + "item is deleted where MxJobsMGR may (MxJobsWMS's own items stay until you remove them in Keychain Access; "
                 + "they are no longer used). macOS may ask once for each old item.")
                .fixedSize(horizontal: false, vertical: true)
            List(subscriptions) { sub in
                VStack(alignment: .leading, spacing: 2) {
                    Text(sub.name.isEmpty ? "Untitled" : sub.name)
                    if let result = results[sub.id] {
                        Text(result).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(minHeight: 140)
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if moving { ProgressView().controlSize(.small) }
                Spacer()
                if done {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Later") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Move Keys") { Task { await move() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(moving || subscriptions.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 520, height: 420)
        .onAppear { subscriptions = KeyMove.pending(space) }
    }

    private func move() async {
        moving = true
        defer { moving = false }
        var accounts: [SecureAccountRef]
        do {
            accounts = try await SecureAccountsClient.list()
        } catch {
            problem = error.localizedDescription
            return
        }
        problem = nil
        for sub in subscriptions {
            guard let key = SecureKeys.legacyKey(sub) else {
                results[sub.id] = "Its old key couldn't be read, so it was left where it is."
                continue
            }
            let name = sub.name.trimmingCharacters(in: .whitespaces).isEmpty ? "API subscription" : sub.name.trimmingCharacters(in: .whitespaces)
            var account = accounts.first { $0.name.lowercased() == name.lowercased() }
            if account == nil {
                do {
                    let made = try await SecureAccountsClient.create(
                        name: name, serviceApi: sub.baseURL, serviceUrl: sub.docsURL,
                        description: [sub.provider, sub.plan].filter { !$0.isEmpty }.joined(separator: " · "))
                    accounts = made.accounts
                    account = accounts.first { $0.id == made.id } ?? SecureAccountRef(id: made.id, name: name)
                } catch {
                    results[sub.id] = error.localizedDescription
                    continue
                }
            }
            guard let account else { continue }
            if let existing = SecureKeys.key(account.id) {
                link(sub, account)
                if existing == key {
                    results[sub.id] = "Linked to “\(account.name)”, which already had this key." + leftBehind(sub)
                } else {
                    results[sub.id] = "Linked to “\(account.name)”, which already has a different service key: that one is sent "
                        + "now, and the old key was left in MxJobsMGR's Keychain item."
                }
                continue
            }
            guard SecureKeys.store(key, account: account.id, name: account.name) else {
                results[sub.id] = "The Keychain didn't take the key, so it was left where it is."
                continue
            }
            link(sub, account)
            results[sub.id] = "Moved to “\(account.name)”." + leftBehind(sub)
        }
        SecureAccountsList.shared.replace(accounts)
        KeychainChanges.shared.bump()
        done = true
    }

    /// Deletes the old item; says so when it stays.
    private func leftBehind(_ sub: ApiSubscription) -> String {
        SecureKeys.deleteLegacyKey(sub) ? ""
            : " Its old Keychain item was made by MxJobsWMS, which alone may delete it: remove it in Keychain Access when you like."
    }

    private func link(_ sub: ApiSubscription, _ account: SecureAccountRef) {
        guard let i = space.subscriptions.firstIndex(where: { $0.id == sub.id }) else { return }
        space.subscriptions[i].secureAccountID = account.id
        space.subscriptions[i].secureAccountName = account.name
    }
}
