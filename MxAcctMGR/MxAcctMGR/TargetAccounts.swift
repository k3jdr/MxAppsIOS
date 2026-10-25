//
//  TargetAccounts.swift
//  MxAcctMGR
//
//  Banking ▸ Target Accounts: each target account's details (srm.payee, V033) and the editor for a new one — its name,
//  nickname, description, status and identifier; its bank or company, last four digits, category and usual amount;
//  the next payment due; where to log on and the user name; the address and phone; the note the registers show on
//  hover; and its funding sources, the registers whose target lists offer it: recipients of checking account payments,
//  of credit card payments, or both. The password and user keys are kept in this Mac's Keychain (TargetSecrets), never
//  in the security master, so they are known only on the Mac they were entered on.
//

import AppKit
import Security
import SwiftUI

/// The registers a target account is paid from: their target lists offer it (srm.payee.funding_sources).
enum FundingSource: String, CaseIterable {
    case checking, card

    var title: String { self == .checking ? "Recipient of checking account payments" : "Recipient of credit card payments" }
    var register: String { self == .checking ? "Checking Accounts register" : "card registers" }
    var symbol: String { self == .checking ? "checkmark.rectangle.stack" : "creditcard" }
}

/// What saving a target account answered: its id (a new one's too), or why it couldn't.
struct PayeeSaved {
    var id: Int?
    var error: String?
}

/// A target account's password and user keys, in this Mac's login Keychain — never in the security master. Each app
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

/// New Target Account: every detail kept for it, its funding sources, and its password and user keys (this Mac's
/// Keychain). With `detailsOnly` it is a row's Edit Target Details: the details alone — nickname, description, status,
/// identifier, next payment, logon (URL, user name, password, user keys), user notes, address and funding sources —
/// while the account's name, bank, last four digits, category, usual amount and bank names stay as saved.
struct TargetAccountSheet: View {
    let payee: Payee?
    var expenseAccounts: [ExpenseAccount]
    var defaultAccount: Int? = nil
    var detailsOnly = false
    var save: ([String: Any]) async -> PayeeSaved
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var nickname = ""
    @State private var details = ""
    @State private var status = "active"
    @State private var reference = ""
    @State private var institution = ""
    @State private var last4 = ""
    @State private var expenseAccountId: Int?
    @State private var defaultAmount: Double?
    @State private var hasNextPayment = false
    @State private var nextPaymentDate = Date()
    @State private var nextPaymentAmount: Double?
    @State private var logonUrl = ""
    @State private var userName = ""
    @State private var password = ""
    @State private var keys = ""
    /// As the Keychain had them when the editor opened (saved again only when changed).
    @State private var savedPassword = ""
    @State private var savedKeys = ""
    @State private var showSecrets = false
    @State private var address1 = ""
    @State private var address2 = ""
    @State private var city = ""
    @State private var state = ""
    @State private var zipCode = ""
    @State private var phone = ""
    @State private var notes = ""
    @State private var bankNames = ""
    @State private var sources: Set<String> = Set(FundingSource.allCases.map(\.rawValue))
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(payee == nil ? "New Target Account" : detailsOnly ? "Edit Target Details" : "Edit \(payee!.name)")
                .heading(.heading)
                .padding([.horizontal, .top], 18)
            if detailsOnly, let p = payee {
                // Its name, the bank when it isn't the name too, and the last four digits.
                Text([p.name, p.institution == p.name ? nil : p.institution, p.last4.map { "···\($0)" }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 18).padding(.top, 2)
            }
            Form {
                Section("Account") {
                    if !detailsOnly { TextField("Account name", text: $name) }
                    TextField("Nickname", text: $nickname)
                        .help("A short name of your own: the registers' target lists show it beside the name")
                    TextField("Description", text: $details, axis: .vertical).lineLimit(1...3)
                    Picker("Status", selection: $status) {
                        Text("Active").tag("active")
                        Text("Inactive").tag("inactive")
                        Text("Closed").tag("closed")
                    }
                    .help("Inactive and closed accounts keep their entries, but no register offers them as a target")
                    TextField("Identifier", text: $reference, prompt: Text("Your account or customer number with them"))
                    if !detailsOnly {
                        TextField("Bank / company", text: $institution)
                        TextField("Last four digits", text: $last4)
                            .help("Shown when this is picked as a register entry's target")
                        Picker("Category", selection: $expenseAccountId) {
                            Text("None").tag(Int?.none)
                            ForEach(expenseAccounts) { Text($0.name).tag(Optional($0.id)) }
                        }
                        TextField("Usual amount", value: $defaultAmount, format: .number.precision(.fractionLength(2)))
                            .help("Filled in when it is picked as a register entry's target")
                    }
                }
                Section("Next payment") {
                    Toggle("A payment is due", isOn: $hasNextPayment)
                    if hasNextPayment {
                        DatePicker("Date", selection: $nextPaymentDate, displayedComponents: .date)
                        TextField("Amount", value: $nextPaymentAmount, format: .number.precision(.fractionLength(2)))
                    }
                }
                Section {
                    HStack {
                        TextField("Logon URL", text: $logonUrl, prompt: Text("https://…"))
                        Button { if let url = LinkRichText.url(fromAddress: logonUrl) { LinkInfo.follow(url) } } label: { Image(systemName: "arrow.up.right.square") }
                            .buttonStyle(.borderless).disabled(LinkRichText.url(fromAddress: logonUrl) == nil)
                            .help("Open the logon page in your browser")
                    }
                    secretRow("User name", text: $userName, secret: false)
                    secretRow("Password", text: $password, secret: true)
                    if showSecrets {
                        TextField("User keys", text: $keys, axis: .vertical).lineLimit(2...5)
                            .help("Security questions' answers, recovery codes, PINs: kept in this Mac's Keychain")
                    } else {
                        LabeledContent("User keys") {
                            Text(keys.isEmpty ? "None" : "\(keys.split(whereSeparator: \.isNewline).count) line(s), hidden")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Toggle("Show the password and user keys", isOn: $showSecrets)
                } header: {
                    Text("Logon")
                } footer: {
                    Text("The password and user keys are kept in this Mac's Keychain, never in the security master: other Macs, and others using the registers, don't see them.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Notes") {
                    TextField("User notes", text: $notes, prompt: Text("Shown on hover in the registers"), axis: .vertical).lineLimit(2...5)
                    if !detailsOnly {
                        TextField("Bank's names for it", text: $bankNames)
                            .help("How the bank's and card companies' downloads name this account, separated by semicolons: accepting a line remembers these")
                    }
                }
                Section("Address") {
                    TextField("Address 1", text: $address1)
                    TextField("Address 2", text: $address2)
                    TextField("City", text: $city)
                    TextField("State", text: $state)
                    TextField("Zip code", text: $zipCode)
                    TextField("Phone number", text: $phone)
                }
                Section {
                    ForEach(FundingSource.allCases, id: \.self) { f in
                        Toggle(isOn: Binding(get: { sources.contains(f.rawValue) },
                                             set: { if $0 { sources.insert(f.rawValue) } else { sources.remove(f.rawValue) } })) {
                            Label(f.title, systemImage: f.symbol)
                        }
                    }
                } header: {
                    Text("Funding sources")
                } footer: {
                    Text(sources.isEmpty ? "With neither, no register offers it as a target."
                         : "Offered as a target in the \(FundingSource.allCases.filter { sources.contains($0.rawValue) }.map(\.register).joined(separator: " and ")).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                    .padding(.horizontal, 18)
            }
            HStack {
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(payee == nil ? "Add" : "Save") { Task { await finish() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || saving)
            }
            .padding(18)
        }
        .frame(width: 540, height: 720)
        .onAppear(perform: load)
    }

    /// A logon field with a copy button (the password masked unless shown).
    private func secretRow(_ title: String, text: Binding<String>, secret: Bool) -> some View {
        HStack {
            if secret && !showSecrets { SecureField(title, text: text) } else { TextField(title, text: text) }
            Button { copy(text.wrappedValue) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).disabled(text.wrappedValue.isEmpty)
                .help("Copy the \(title.lowercased())")
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func load() {
        guard let p = payee else {
            expenseAccountId = defaultAccount
            return
        }
        name = p.name; nickname = p.nickname ?? ""; details = p.description ?? ""; status = p.status
        reference = p.reference ?? ""; institution = p.institution ?? ""; last4 = p.last4 ?? ""
        expenseAccountId = p.expenseAccountId; defaultAmount = p.defaultAmount
        hasNextPayment = p.nextPaymentDate != nil || p.nextPaymentAmount != nil
        nextPaymentDate = p.nextPaymentDate.flatMap { isoDay.date(from: String($0.prefix(10))) } ?? Date()
        nextPaymentAmount = p.nextPaymentAmount
        logonUrl = p.logonUrl ?? ""; userName = p.userName ?? ""
        address1 = p.address1 ?? ""; address2 = p.address2 ?? ""; city = p.city ?? ""; state = p.state ?? ""
        zipCode = p.zipCode ?? ""; phone = p.phone ?? ""; notes = p.notes ?? ""
        bankNames = p.bankNames.joined(separator: "; "); sources = Set(p.fundingSources)
        savedPassword = TargetSecrets.get(.password, p.id) ?? ""; password = savedPassword
        savedKeys = TargetSecrets.get(.keys, p.id) ?? ""; keys = savedKeys
    }

    /// Saves the details in the security master, then the password and user keys in this Mac's Keychain.
    private func finish() async {
        saving = true
        defer { saving = false }
        var body: [String: Any] = [
            "name": name, "nickname": nickname, "description": details, "status": status, "reference": reference,
            "logonUrl": logonUrl, "userName": userName,
            "address1": address1, "address2": address2, "city": city, "state": state, "zipCode": zipCode, "phone": phone,
            "notes": notes, "fundingSources": FundingSource.allCases.map(\.rawValue).filter(sources.contains),
            "nextPaymentDate": hasNextPayment ? isoDay.string(from: nextPaymentDate) : "",
        ]
        body["nextPaymentAmount"] = hasNextPayment ? (nextPaymentAmount.map { $0 as Any } ?? NSNull()) : NSNull()
        // The details alone leave the account's name, bank, last four, category, usual amount and bank names as saved.
        if !detailsOnly {
            body["institution"] = institution
            body["last4"] = last4
            body["bankNames"] = bankNames.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            body["expenseAccountId"] = expenseAccountId ?? NSNull()
            body["defaultAmount"] = defaultAmount ?? NSNull()
        }
        if let payee { body["version"] = payee.version }
        let saved = await save(body)
        if let e = saved.error { error = e; return }
        guard let id = saved.id else {
            error = "Saved, but its password and user keys weren't: open it again to enter them."
            return
        }
        let kept = (password == savedPassword || TargetSecrets.set(password, .password, id, account: name))
            && (keys == savedKeys || TargetSecrets.set(keys, .keys, id, account: name))
        if !kept {
            error = "Saved, but the Keychain didn't take the password or user keys."
            return
        }
        dismiss()
    }
}

// MARK: - Edit Target Account Name

/// Renames a target account (a row's context menu). Names are unique whatever their case: one another account already
/// has can't be saved (the security master refuses it too, for a name taken since). Save closes the dialog.
struct TargetNameSheet: View {
    let payee: Payee
    /// Every target account's name, to say before saving when the new one is taken.
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
            Text("Edit Target Account Name").heading(.heading)
            Form {
                TextField("Account name", text: $name)
                    .onSubmit { if canSave { Task { await finish() } } }
            }
            if let taken {
                Label("There is already a target account named \(taken): names are unique, whatever their case.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.callout)
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
            } else {
                Text("The registers show the new name for every entry with this target.").font(.caption).foregroundStyle(.secondary)
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

/// A name the card registers' entries carry without a target account (as the card company gives it).
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

/// Target Accounts ▸ Add from Card Registers…: the card registers' targets that aren't target accounts yet — the
/// merchants ticked, the card company's own lines not — added as target accounts that the card registers offer, each
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
            Text("The targets of credit card entries that aren't target accounts yet, as the card company names them. Those ticked become target accounts that the card registers offer, each in the category its entries mostly have, with those entries linked to it; a card line with the same name later is filed to it too. The card company's own lines (payments, interest, fees, adjustments) start unticked.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let targets {
                if targets.isEmpty {
                    ContentUnavailableView("Every card target is a target account", systemImage: "checkmark.circle",
                                           description: Text("The card registers' entries all have target accounts."))
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
                        TableColumn("Target (as the card company names it)") { t in
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
                Button(chosen.count == 1 ? "Add 1 Target Account" : "Add \(chosen.count) Target Accounts") { Task { await add() } }
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
