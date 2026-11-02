//
//  TargetAccounts.swift
//  MxAcctMGR
//
//  Banking ▸ Target Categories ▸ Merchants: each merchant's details (srm.payee, V033) and the editor for a new one — its name,
//  nickname, description, status and identifier; its bank or company, last four digits, category and usual amount;
//  the next payment due; where to log on and the user name; the address and phone; the note the registers show on
//  hover; and its funding sources, the registers whose target lists offer it: recipients of checking account payments,
//  of credit card payments, or both. The password and user keys are kept in this Mac's Keychain (TargetSecrets), never
//  in the security master, so they are known only on the Mac they were entered on. Remove Merchant… (a row's
//  context menu) takes one off once nothing files under it — its entries consolidated into another merchant.
//

import AppKit
import Security
import SwiftUI

/// The registers a merchant is paid from: their target lists offer it (srm.payee.funding_sources).
enum FundingSource: String, CaseIterable {
    case checking, card

    var title: String { self == .checking ? "Recipient of checking account payments" : "Recipient of credit card payments" }
    var register: String { self == .checking ? "Checking Accounts register" : "card registers" }
    var symbol: String { self == .checking ? "checkmark.rectangle.stack" : "creditcard" }
}

/// What saving a merchant answered: its id (a new one's too), or why it couldn't.
struct PayeeSaved {
    var id: Int?
    var error: String?
}

/// A merchant's password and user keys, in this Mac's login Keychain — never in the security master. Each app
/// build keeps its own (the service is named after the bundle), so a test build never reads the real app's.
nonisolated enum TargetSecrets {
    enum Kind: String { case password, keys = "user keys" }

    private static var service: String { (Bundle.main.bundleIdentifier ?? "com.k3jdr.MxAcctMGR") + ".target-accounts" }
    /// Where the app kept them while it was MxPortMGR: moved here the first time one is read.
    private static var legacyService: String { service.replacingOccurrences(of: "MxAcctMGR", with: "MxPortMGR") }

    private static func match(_ kind: Kind, _ payee: Int, in service: String = service) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "\(payee) \(kind.rawValue)"]
    }

    static func get(_ kind: Kind, _ payee: Int) -> String? {
        if let value = read(match(kind, payee)) { return value }
        // Saved before the rename: move it under this app's service.
        guard let value = read(match(kind, payee, in: legacyService)) else { return nil }
        var add = match(kind, payee)
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrLabel as String] = "MxAcctMGR: \(payee) (\(kind.rawValue))"
        if SecItemAdd(add as CFDictionary, nil) == errSecSuccess { SecItemDelete(match(kind, payee, in: legacyService) as CFDictionary) }
        return value
    }

    private static func read(_ match: [String: Any]) -> String? {
        var query = match
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Saves it (empty or nil removes it); answers whether the Keychain took it.
    @discardableResult
    static func set(_ value: String?, _ kind: Kind, _ payee: Int, account name: String) -> Bool {
        guard let value, !value.isEmpty else {
            SecItemDelete(match(kind, payee, in: legacyService) as CFDictionary)
            let status = SecItemDelete(match(kind, payee) as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(value.utf8)
        let update = [kSecValueData as String: data, kSecAttrLabel as String: "MxAcctMGR: \(name) (\(kind.rawValue))"] as [String: Any]
        var status = SecItemUpdate(match(kind, payee) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = match(kind, payee)
            add.merge(update) { a, _ in a }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        return status == errSecSuccess
    }
}

// MARK: - The editor

/// Renames a merchant (a row's context menu). Names are unique whatever their case: one another account already
/// has can't be saved (the security master refuses it too, for a name taken since). Save closes the dialog.
struct TargetNameSheet: View {
    let payee: Payee
    /// Every merchant's name, to say before saving when the new one is taken.
    let names: [String]
    var save: (String) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var error: String?
    @State private var saving = false

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Another account with this name (in any case), if there is one.
    private var taken: String? {
        guard trimmed.lowercased() != payee.name.lowercased() else { return nil }
        return names.first { $0.lowercased() == trimmed.lowercased() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Merchant Name").heading(.heading)
            Form {
                TextField("Account name", text: $name)
                    .onSubmit { if canSave { Task { await finish() } } }
            }
            if let taken {
                Label("There is already a merchant named \(taken): names are unique, whatever their case.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.callout)
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
            } else {
                Text("The registers show the new name for every entry with this name.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { Task { await finish() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(18)
        .frame(width: 420)
        .onAppear { name = payee.name }
    }

    private var canSave: Bool { !trimmed.isEmpty && trimmed != payee.name && taken == nil && !saving }

    private func finish() async {
        saving = true
        error = await save(trimmed)
        saving = false
        if error == nil { dismiss() }
    }
}

// MARK: - Add from Card Registers

/// A name the card registers' entries carry without a merchant (as the card company gives it).
struct CardTarget: Decodable, Identifiable, Hashable {
    var name: String
    var entries: Int
    var total: Double
    var first: String?
    var last: String?
    var kinds: [String]
    /// False for the card company's own lines (payments, interest, fees, adjustments).
    var merchant: Bool
    var id: String { name }
}

struct CardTargets: Decodable {
    var targets: [CardTarget]
    var added: Int?
    var linked: Int?
}

/// Merchants ▸ Add from Card Registers…: the card registers' targets that aren't merchants yet — the
/// merchants ticked, the card company's own lines not — added as merchants that the card registers offer, each
/// in the category its entries mostly have, with its entries linked to it.
struct AddCardTargetsSheet: View {
    var added: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var targets: [CardTarget]?
    @State private var chosen = Set<String>()
    @State private var problem: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add from Card Registers").heading(.heading)
            Text("The names on credit card entries that aren't merchants yet, as the card company names them. Those ticked become merchants that the card registers offer, each in the category the card company's categories of its entries mostly map to, with those entries linked to it; a card line with the same name later is filed to it too. The card company's own lines (payments, interest, fees, adjustments) start unticked.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let targets {
                if targets.isEmpty {
                    ContentUnavailableView("Every card name is a merchant", systemImage: "checkmark.circle",
                                           description: Text("The card registers' entries all have merchants."))
                } else {
                    HStack {
                        Button("Select All") { chosen = Set(targets.map(\.name)) }
                        Button("Select None") { chosen = [] }
                        Spacer()
                        Text("\(chosen.count) of \(targets.count) selected").foregroundStyle(.secondary)
                    }
                    Table(targets) {
                        TableColumn("") { t in
                            Toggle("", isOn: Binding(get: { chosen.contains(t.name) },
                                                     set: { if $0 { chosen.insert(t.name) } else { chosen.remove(t.name) } }))
                                .labelsHidden()
                        }
                        .width(24)
                        TableColumn("Name (as the card company gives it)") { t in
                            Text(t.name).foregroundStyle(t.merchant ? .primary : .secondary)
                        }
                        TableColumn("Entries") { t in Text("\(t.entries)").monospacedDigit() }.width(54)
                        TableColumn("Total") { t in Text(money2(t.total)).monospacedDigit() }.width(90)
                        TableColumn("Last") { t in Text(shortDay(t.last)).monospacedDigit().foregroundStyle(.secondary) }.width(84)
                        TableColumn("Kind") { t in Text(t.kinds.joined(separator: ", ")).foregroundStyle(.secondary) }.width(min: 60, ideal: 90)
                    }
                    .tableText()
                    .textSelection(.disabled)
                    .frame(minHeight: 320)
                }
            } else if problem == nil {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            }
            if let problem { Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
            HStack {
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(chosen.count == 1 ? "Add 1 Merchant" : "Add \(chosen.count) Merchants") { Task { await add() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty || saving)
            }
        }
        .padding(18)
        .frame(width: 640, height: 600)
        .task { await load() }
    }

    private func load() async {
        do {
            let found = try await CardClient.targets()
            targets = found
            chosen = Set(found.filter(\.merchant).map(\.name))
            problem = nil
        } catch {
            problem = describe(error)
        }
    }

    private func add() async {
        saving = true
        defer { saving = false }
        do {
            _ = try await CardClient.addTargets(targets?.map(\.name).filter(chosen.contains) ?? [])
            await added()
            dismiss()
        } catch {
            problem = describe(error)
        }
    }
}

// MARK: - Remove Merchant

/// What still files under a merchant (GET /payees/<id>/usage), before it is removed.
struct PayeeUsage: Decodable {
    var id: Int
    var name: String
    /// checking entries, card entries, cash-ledger entries, card accounts paid as it, cash ledgers funded through it,
    /// tax items → how many.
    var uses: [String: Int]
    var inUse: Int
    var spendingRule: Bool
    var link: Bool
}

extension BankClient {
    static func payeeUsage(_ id: Int) async throws -> PayeeUsage {
        try await AccountsClient.request("GET", "/payees/\(id)/usage", as: PayeeUsage.self)
    }
    /// Removes a merchant nothing files under (the accounts service refuses one still in use).
    static func deletePayee(_ id: Int) async throws -> TargetBook {
        try await AccountsClient.request("DELETE", "/payees/\(id)", as: TargetBook.self)
    }
}

/// Remove Merchant… (a row's context menu): once its entries are consolidated into another merchant,
/// nothing files under it and it can go. While anything still does — a checking, card or cash-ledger entry, a card
/// account paid as it, a cash ledger funded through it, a tax item — the sheet says what, and Remove stays off: those
/// would lose their target. Its link and spending rule go with it, and its password and user keys leave this Mac's
/// Keychain.
struct RemoveTargetAccountSheet: View {
    let payee: Payee
    var removed: (TargetBook) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var usage: PayeeUsage?
    @State private var error: String?
    @State private var working = false

    private static let order = ["checking entries", "card entries", "cash-ledger entries", "card accounts paid as it",
                                "cash ledgers funded through it", "tax items"]
    private static let one = ["checking entries": "checking entry", "card entries": "card entry", "cash-ledger entries": "cash-ledger entry",
                              "card accounts paid as it": "card account paid as it", "cash ledgers funded through it": "cash ledger funded through it",
                              "tax items": "tax item"]

    /// What still files under it, as a list ("3 card entries, 1 tax item").
    private static func filed(_ u: PayeeUsage) -> String {
        order.compactMap { w in u.uses[w].flatMap { $0 > 0 ? "\($0) \($0 == 1 ? one[w] ?? w : w)" : nil } }.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remove \u{201C}\(payee.name)\u{201D}?").heading(.heading)
            if let u = usage {
                if u.inUse == 0 {
                    let goes = [u.link ? "its link" : nil, u.spendingRule ? "its spending rule" : nil].compactMap { $0 }
                    Text("Nothing files under it, so it can go for good: it leaves the registers' name lists and the Merchants list"
                         + (goes.isEmpty ? "" : ", and \(goes.joined(separator: " and ")) with it")
                         + ". Its password and user keys leave this Mac's Keychain.")
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Label("Still filed under it: \(Self.filed(u)). Consolidate them into another merchant first — change each entry's name in its register — then remove this one.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            } else if error == nil {
                ProgressView().controlSize(.small)
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Remove", role: .destructive) { Task { await remove() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || usage == nil || (usage?.inUse ?? 0) > 0)
            }
        }
        .padding(18)
        .frame(width: 460)
        .task {
            do { usage = try await BankClient.payeeUsage(payee.id) } catch { self.error = describe(error) }
        }
    }

    private func remove() async {
        working = true
        defer { working = false }
        do {
            let book = try await BankClient.deletePayee(payee.id)
            // The security master no longer knows it: its secrets on this Mac go too.
            TargetSecrets.set(nil, .password, payee.id, account: payee.name)
            TargetSecrets.set(nil, .keys, payee.id, account: payee.name)
            removed(book)
            dismiss()
        } catch { self.error = describe(error) }
    }
}
