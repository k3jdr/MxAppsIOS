//
//  SpendingExpenseAccounts.swift
//  MxAcctMGR
//
//  Adding, editing and removing expense accounts from Spending Analysis ▸ Rules: the bookkeeping categories the card
//  and checking registers, target accounts and expense-ledger lines file entries under (Home Office, Studio …). A new
//  one can get its spending rule at once. Removing one in use moves what files under it to another expense account
//  first (the accounts service's DELETE /expense-accounts/<id>?moveTo=).
//

import SwiftUI

/// What files under an expense account, before it is removed.
struct ExpenseAccountUsage: Decodable {
    var id: Int
    var name: String
    var kind: String
    /// card entries, checking entries, target accounts, expense-ledger lines, card categories → how many.
    var uses: [String: Int]
    var inUse: Int
    var spendingRule: Bool
}

extension BankClient {
    static func expenseAccountUsage(_ id: Int) async throws -> ExpenseAccountUsage {
        try await AccountsClient.request("GET", "/expense-accounts/\(id)/usage", as: ExpenseAccountUsage.self)
    }
    /// Removes an expense account; what files under it moves to `moveTo` first.
    static func deleteExpenseAccount(_ id: Int, moveTo: Int?) async throws -> ExpenseBook {
        let who = by.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return try await AccountsClient.request("DELETE", "/expense-accounts/\(id)?moveTo=\(moveTo ?? 0)&by=\(who)", as: ExpenseBook.self)
    }
}

/// New Expense Account… and Edit Expense Account…
struct ExpenseAccountEditor: View {
    var setup: SpendingSetup
    /// The one changed; nil adds one.
    var account: SpendingSetup.Named?
    var saved: (SpendingSetup) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var category = ""
    @State private var driver = ""
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(account == nil ? "New Expense Account" : "Edit Expense Account").heading(.heading)
            Text("An expense account is the bookkeeping category the card and checking registers, target accounts and expense-ledger lines file entries under. Spending Analysis puts its entries in a spending category with its rule.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Name", text: $name, prompt: Text("Home Office, Studio"))
                TextField("Description", text: $description, prompt: Text("What files here"))
                if account == nil {
                    Section("Its rule in Spending Analysis") {
                        Picker("Category", selection: $category) {
                            Text("None").tag("")
                            ForEach(setup.categories) { c in Text(c.name).tag(c.code) }
                        }
                        Picker("Driver", selection: $driver) {
                            Text("None").tag("")
                            ForEach(SpendingDriver.allCases) { d in Text(d.title).help(d.help).tag(d.rawValue) }
                        }
                    }
                }
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
            HStack {
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(account == nil ? "Add" : "Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 460)
        .onAppear { name = account?.name ?? ""; description = account?.description ?? "" }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let book = try await BankClient.saveExpenseAccount(account?.id ?? 0, ["name": name, "kind": "expense", "description": description])
            if account == nil, let id = book.id, !(category.isEmpty && driver.isEmpty) {
                _ = try await SpendingClient.saveRule(["expenseAccountId": id, "category": category, "driver": driver,
                                                      "memberId": NSNull(), "notes": NSNull()])
            }
            saved(try await SpendingClient.setup())
            dismiss()
        } catch { self.error = describe(error) }
    }
}

/// Remove Expense Account…: says what files under it and, when anything does, where it moves.
struct RemoveExpenseAccountSheet: View {
    var setup: SpendingSetup
    var account: SpendingSetup.Named
    var saved: (SpendingSetup) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var usage: ExpenseAccountUsage?
    @State private var moveTo = 0
    @State private var error: String?
    @State private var working = false

    private static let order = ["card entries", "checking entries", "target accounts", "expense-ledger lines", "card categories"]
    private static let one = ["card entries": "card entry", "checking entries": "checking entry", "target accounts": "target account",
                              "expense-ledger lines": "expense-ledger line", "card categories": "card category"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remove \u{201C}\(account.name)\u{201D}?").heading(.heading)
            if let u = usage {
                if u.inUse == 0 {
                    Text("Nothing files under it." + (u.spendingRule ? " Its spending rule goes with it." : ""))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Filed under it: " + Self.order.compactMap { w in u.uses[w].flatMap { $0 > 0 ? "\($0) \($0 == 1 ? Self.one[w] ?? w : w)" : nil } }
                        .joined(separator: ", ") + ". They move to the expense account you choose, and follow its rule from then on"
                         + (u.spendingRule ? "; this one's spending rule goes." : "."))
                        .fixedSize(horizontal: false, vertical: true)
                    Picker("Move them to", selection: $moveTo) {
                        Text("Choose…").tag(0)
                        ForEach(setup.expenseAccounts.filter { $0.id != account.id }) { a in Text(a.name).tag(a.id) }
                    }
                }
            } else if error == nil {
                ProgressView().controlSize(.small)
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
            HStack {
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Remove", role: .destructive) { Task { await remove() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || usage == nil || ((usage?.inUse ?? 0) > 0 && moveTo == 0))
            }
        }
        .padding(18)
        .frame(width: 460)
        .task {
            do { usage = try await BankClient.expenseAccountUsage(account.id) } catch { self.error = describe(error) }
        }
    }

    private func remove() async {
        working = true
        defer { working = false }
        do {
            _ = try await BankClient.deleteExpenseAccount(account.id, moveTo: moveTo == 0 ? nil : moveTo)
            saved(try await SpendingClient.setup())
            dismiss()
        } catch { self.error = describe(error) }
    }
}
