//
//  SecureAccounts.swift
//  MxAcctMGR
//
//  Banking ▸ Secure Accounts, modeled on Target Accounts: the products and services you hold an account with
//  (srm.secure_account, V035) — each product's name and description; its service's address, API and status; your user
//  name; and its subscription, the last payment and the renewal (auto-renew, renew by hand, or decline). The product
//  key, the service key and the password are kept in this Mac's Keychain (SecureSecrets), never in the security master.
//  The table's rows are read-only: their context menu renames one (names are unique) or edits its details.
//
//  The service key is also the API key MxJobsMGR's subscriptions send: a subscription names its secure account and
//  MxJobsMGR reads the key from this Mac's Keychain (both apps are signed by the same team, so it isn't asked). Its
//  API Subscriptions opens mxacctmgr://secure-accounts/<id> (Edit Service Details) or /new?name=…&api=…&url=…
//  (New Secure Account, filled in) — Shared/AppLinks.swift.
//

import AppKit
import Security
import SwiftUI

struct SecureAccount: Decodable, Identifiable, Hashable {
    var id: Int
    var name: String
    var description: String?
    var serviceUrl: String?
    var serviceApi: String?
    /// active, inactive or closed.
    var status: String
    var ownerUserName: String?
    var paymentDate: String?
    var paymentAmount: Double?
    var renewalDate: String?
    var renewalAmount: Double?
    /// auto (renews on its own), renew (renewed by hand) or decline (left to lapse at the renewal date).
    var renewalStatus: String
    var version: Int
    var updatedBy: String?

    var active: Bool { status == "active" }
}

/// How a subscription is renewed (srm.secure_account.renewal_status).
enum RenewalStatus: String, CaseIterable {
    case auto, renew, decline

    var title: String {
        switch self {
        case .auto: "Auto-renew"
        case .renew: "Renew"
        case .decline: "Decline"
        }
    }

    var help: String {
        switch self {
        case .auto: "Renews on its own at the renewal date"
        case .renew: "Renewed by hand at the renewal date"
        case .decline: "Left to lapse at the renewal date"
        }
    }

    static func title(_ raw: String) -> String { RenewalStatus(rawValue: raw)?.title ?? raw }
}

nonisolated enum SecureClient {
    struct List: Decodable {
        var secureAccounts: [SecureAccount]
        /// The account a save made or changed.
        var id: Int?
    }

    static func list() async throws -> List {
        try await AccountsClient.request("GET", "/secure-accounts", as: List.self)
    }
    static func save(_ id: Int, _ body: [String: Any]) async throws -> List {
        try await AccountsClient.request("PUT", "/secure-accounts/\(id)", body: body.merging(["by": BankClient.by]) { a, _ in a }, as: List.self)
    }
}

/// A secure account's product key, service key and password, in this Mac's login Keychain — never in the security
/// master. Each app build keeps its own (the service is named after the bundle), so a test build never reads the real
/// app's. Items are made trusting MxJobsMGR too (Shared/SharedKeys.swift), which reads the service keys as the API keys
/// its subscriptions send.
nonisolated enum SecureSecrets {
    enum Kind: String { case productKey = "product key", serviceKey = "service key", password }

    private static var service: String { (Bundle.main.bundleIdentifier ?? "com.k3jdr.MxAcctMGR") + ".secure-accounts" }

    private static func match(_ kind: Kind, _ id: Int) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "\(id) \(kind.rawValue)"]
    }

    static func get(_ kind: Kind, _ id: Int) -> String? {
        var query = match(kind, id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Whether it is stored, without reading it.
    static func has(_ kind: Kind, _ id: Int) -> Bool {
        SecItemCopyMatching(match(kind, id) as CFDictionary, nil) == errSecSuccess
    }

    /// Saves it (empty or nil removes it); answers whether the Keychain took it.
    @discardableResult
    static func set(_ value: String?, _ kind: Kind, _ id: Int, product name: String) -> Bool {
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(match(kind, id) as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        return SharedKeys.save(value, label: "MxAcctMGR: \(name) (\(kind.rawValue))", match: match(kind, id), partner: AppLink.jobsBundleID)
    }
}

// MARK: - The page

struct SecureAccountsView: View {
    @Bindable var store: PortStore
    @State private var accounts: [SecureAccount]?
    @State private var problem: String?
    @State private var adding = false
    /// The table's Excel-style sorting and column filters (the header buttons).
    @State private var grid = GridQueryOptions()
    /// Edit Service Details or Edit Service Name (a row's context menu) is open for this account.
    @State private var details: SecureAccount?
    @State private var renaming: SecureAccount?
    @State private var showInactive = false
    /// How many of the table's rows show at once.
    @AppStorage(RowsStepper.key) private var tableRows = RowsStepper.standard
    /// Import Passwords and Keys… is open.
    @State private var importing = false
    /// The table's rows are read-only: their context menu edits the account.
    @State private var selected: SecureAccount.ID?
    /// New Secure Account filled in from an mxacctmgr://secure-accounts/new link.
    @State private var draft: SecureDraft?
    /// Which of each account's keys and password the Keychain holds, read when the list loads.
    @State private var stored: [Int: String] = [:]

    var body: some View {
        StepPage(store: store, subtitle: "The products and services you hold an account with — software, data services, APIs — with their service, your logon and the subscription's payment and renewal.", lesson: [
            "Each secure account is a product: its name and description, its service's web address and API, and whether the service is active. Your user name is kept with it; its product key, service key and password stay in this Mac's Keychain, never in the security master.",
            "Its subscription has the last payment (date and amount) and the renewal: when, how much, and whether it renews on its own, you renew it by hand, or you decline it and let it lapse — in Edit Service Details.",
            "The service key is also the API key: MxJobsMGR's API subscriptions each name a secure account and send its service key, so this is the one place API keys are entered and changed.",
        ]) {
            if let problem { Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
            if let accounts { accountsTable(accounts) }
        }
        .task { await load() }
        // MxJobsMGR's Move Keys may have added service keys meanwhile.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in readStored() }
        #if DEBUG
        // Self-tests, once the list is loaded: open New Secure Account (-secureAccountNew YES), Import Passwords and Keys
        // (-secureImport YES), or a row's Edit Service Details (-secureDetailsEdit ID) or Edit Service Name
        // (-secureNameEdit ID).
        .task(id: accounts == nil) {
            guard let accounts else { return }
            let defaults = UserDefaults.standard
            if defaults.bool(forKey: "secureAccountNew") { adding = true }
            if defaults.bool(forKey: "secureImport") { importing = true }
            if defaults.object(forKey: "secureDetailsEdit") != nil {
                details = accounts.first { $0.id == defaults.integer(forKey: "secureDetailsEdit") }
            }
            if defaults.object(forKey: "secureNameEdit") != nil {
                renaming = accounts.first { $0.id == defaults.integer(forKey: "secureNameEdit") }
            }
        }
        #endif
        // An mxacctmgr://secure-accounts link from MxJobsMGR, once the list is loaded.
        .task(id: TaskKey(loaded: accounts != nil, request: store.secureRequest)) {
            guard let accounts, let request = store.secureRequest else { return }
            store.secureRequest = nil
            switch request {
            case let .secureAccount(id?):
                if let a = accounts.first(where: { $0.id == id }) {
                    if !a.active { showInactive = true }
                    selected = a.id
                    details = a
                } else {
                    problem = "There is no secure account \(id) any more: choose another for the subscription in MxJobsMGR."
                }
            case let .newSecureAccount(name, api, url):
                if let a = accounts.first(where: { $0.name.lowercased() == name.lowercased() }) {
                    selected = a.id
                    details = a
                } else {
                    draft = SecureDraft(name: name, serviceApi: api ?? "", serviceUrl: url ?? "")
                    adding = true
                }
            default:
                break
            }
        }
        .sheet(isPresented: $adding, onDismiss: { draft = nil; readStored() }) {
            SecureAccountSheet(account: nil, draft: draft) { body in await save(0, body) }
        }
        .sheet(isPresented: $importing) {
            SecureImportSheet(accounts: accounts ?? [], save: { id, body in await save(id, body) }, done: { await load() })
        }
        .sheet(item: $details, onDismiss: readStored) { a in
            SecureAccountSheet(account: a) { body in await save(a.id, body) }
        }
        .sheet(item: $renaming) { a in
            SecureNameSheet(account: a, names: accounts?.map(\.name) ?? []) { name in
                await save(a.id, ["version": a.version, "name": name]).error
            }
        }
    }

    /// The table's columns for sorting and filtering, by their titles.
    static let columns: [String: LocalGridColumn<SecureAccount>] = [
        "Product": .text { $0.name },
        "Status": .text { $0.status.capitalized },
        "Service": .text { $0.serviceUrl.flatMap(Self.host) },
        "User name": .text { $0.ownerUserName },
    ]

    /// What the Keys column lists for an account: which of its keys and password this Mac's Keychain holds.
    static func storedKeys(_ id: Int) -> String {
        [SecureSecrets.Kind.serviceKey, .productKey, .password].filter { SecureSecrets.has($0, id) }.map(\.rawValue).joined(separator: ", ")
    }

    /// A service address's host, as the table shows it.
    static func host(_ address: String) -> String? {
        LinkRichText.url(fromAddress: address)?.host() ?? (address.isEmpty ? nil : address)
    }

    private func accountsTable(_ all: [SecureAccount]) -> some View {
        let listed = all.filter { $0.active || showInactive }
        let shown = LocalGrid.rows(listed, grid, Self.columns)
        let renewing = listed.filter { $0.renewalStatus != RenewalStatus.decline.rawValue }.compactMap(\.renewalAmount).reduce(0, +)
        return Box(title: "Service Product Table", symbol: "lock.shield", help: "The products and services you hold an account with: the product, its status, the service and your user name. Each column header's button sorts and filters it, as in Excel. Right-click a row (anywhere on it) for Edit Service Name… (names are unique) and Edit Service Details… — description, service address and API, status, your logon, the product and service keys, the subscription's payment and renewal. Keys and passwords stay in this Mac's Keychain; Keys lists which are stored. A service key is also the API key MxJobsMGR's subscriptions linked to the account send.") {
            HStack {
                Button("New Secure Account…") { adding = true }
                Button("Import Passwords and Keys…") { importing = true }
                    .help("Read a credentials worksheet from its Excel workbook and put each row's password and keys in this Mac's Keychain")
                Toggle("Show inactive and closed", isOn: $showInactive).toggleStyle(.checkbox)
                Spacer()
                Text("Renewing: \(money2(renewing))").monospacedDigit().foregroundStyle(.secondary)
                    .help("The renewal amounts of the accounts listed that aren't declined")
                RowsStepper(rows: $tableRows)
            }
            GridFilterStatus(shown: shown.count, of: listed.count, options: $grid)
            Table(shown, selection: $selected) {
                TableColumn("Product") { a in
                    HStack(spacing: 4) {
                        Text(a.name).foregroundStyle(a.active ? .primary : .secondary).help(a.description ?? "")
                        if !a.active { Text(a.status).font(.caption).foregroundStyle(.secondary) }
                    }
                }.width(min: 110, ideal: 170)
                TableColumn("Status") { a in Text(a.status.capitalized).foregroundStyle(a.active ? .primary : .secondary) }.width(min: 50, ideal: 64)
                TableColumn("Service") { a in
                    Text(a.serviceUrl.flatMap(Self.host) ?? "").foregroundStyle(.secondary).help(a.serviceUrl ?? "")
                }.width(min: 80, ideal: 140)
                TableColumn("User name") { a in Text(a.ownerUserName ?? "").foregroundStyle(.secondary) }.width(min: 70, ideal: 120)
                TableColumn("Keys") { a in
                    Text(stored[a.id] ?? "").foregroundStyle(.secondary)
                        .help("Kept in this Mac's Keychain. The service key is the API key MxJobsMGR's subscriptions linked to this account send.")
                }.width(min: 70, ideal: 150)
            }
            .tableText()
            // One menu on the whole row: its words aren't selectable text, so a right-click on them doesn't bring up
            // the text menu (Edit commands, Services) instead.
            .textSelection(.disabled)
            // Each column header's button sorts and filters it, as in Excel.
            .columnHeaderFilters(types: LocalGrid.types(Self.columns), options: grid,
                                 loadValues: { (LocalGrid.values(listed, column: $0, grid, Self.columns), false) },
                                 apply: { grid = $0 })
            .contextMenu(forSelectionType: SecureAccount.ID.self) { ids in
                if ids.count == 1, let a = all.first(where: { ids.contains($0.id) }) {
                    Button("Edit Service Name…") { renaming = a }
                    Button("Edit Service Details…") { details = a }
                    if let url = a.serviceUrl.flatMap(LinkRichText.url(fromAddress:)) {
                        Divider()
                        Button("Open the Service Page") { LinkInfo.follow(url) }
                    }
                }
            } primaryAction: { ids in
                if ids.count == 1, let a = all.first(where: { ids.contains($0.id) }) { details = a }
            }
            .frame(minHeight: PortSettings.shared.tableHeight(rows: min(max(shown.count, 6), tableRows)))
        }
    }

    private func load() async {
        do { accounts = try await SecureClient.list().secureAccounts; problem = nil } catch { problem = describe(error) }
        readStored()
    }

    private func readStored() {
        stored = Dictionary(uniqueKeysWithValues: (accounts ?? []).map { ($0.id, Self.storedKeys($0.id)) })
    }

    /// Saves a new account (id 0), its details or its name; answers its id, or why it couldn't.
    private func save(_ id: Int, _ body: [String: Any]) async -> PayeeSaved {
        do {
            let answer = try await SecureClient.save(id, body)
            accounts = answer.secureAccounts
            return PayeeSaved(id: answer.id ?? id)
        } catch {
            await load()
            return PayeeSaved(error: describe(error))
        }
    }
}

/// What the link task waits on: the list loaded, and a link to act on.
private struct TaskKey: Equatable {
    var loaded: Bool
    var request: AppLink?
}

/// New Secure Account's starting values, from MxJobsMGR's New in MxAcctMGR… (a subscription's name, base URL and
/// documentation address).
struct SecureDraft: Equatable {
    var name: String
    var serviceApi: String
    var serviceUrl: String
}

// MARK: - The editor

/// New Secure Account, or a row's Edit Service Details: the product, its service, your logon and the
/// subscription. The product key, service key and password are saved in this Mac's Keychain once the security master
/// has the account (a new one needs its id first).
struct SecureAccountSheet: View {
    let account: SecureAccount?
    /// A new account's starting values (an mxacctmgr://secure-accounts/new link).
    var draft: SecureDraft? = nil
    var save: ([String: Any]) async -> PayeeSaved
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var details = ""
    @State private var serviceUrl = ""
    @State private var serviceApi = ""
    @State private var status = "active"
    @State private var userName = ""
    @State private var productKey = ""
    @State private var serviceKey = ""
    @State private var password = ""
    /// As the Keychain had them when the editor opened (saved again only when changed).
    @State private var saved: [SecureSecrets.Kind: String] = [:]
    @State private var showSecrets = false
    @State private var hasPayment = false
    @State private var paymentDate = Date()
    @State private var paymentAmount: Double?
    @State private var hasRenewal = false
    @State private var renewalDate = Date()
    @State private var renewalAmount: Double?
    @State private var renewalStatus = RenewalStatus.auto.rawValue
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(account == nil ? "New Secure Account" : "Edit Service Details")
                .heading(.heading)
                .padding([.horizontal, .top], 18)
            if let account {
                Text(account.name).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.top, 2)
            }
            Form {
                Section("Product") {
                    if account == nil { TextField("Product name", text: $name) }
                    TextField("Description", text: $details, axis: .vertical).lineLimit(1...3)
                    secretRow("Product key", text: $productKey)
                }
                Section("Service") {
                    HStack {
                        TextField("Service URL", text: $serviceUrl, prompt: Text("https://…"))
                        Button { if let url = LinkRichText.url(fromAddress: serviceUrl) { LinkInfo.follow(url) } } label: { Image(systemName: "arrow.up.right.square") }
                            .buttonStyle(.borderless).disabled(LinkRichText.url(fromAddress: serviceUrl) == nil)
                            .help("Open the service's page in your browser")
                    }
                    TextField("Service API", text: $serviceApi, prompt: Text("Its base URL or endpoint"))
                    secretRow("Service key", text: $serviceKey)
                        .help("Also the API key MxJobsMGR sends for the API subscriptions linked to this account")
                    Picker("Service status", selection: $status) {
                        Text("Active").tag("active")
                        Text("Inactive").tag("inactive")
                        Text("Closed").tag("closed")
                    }
                    .help("Inactive and closed accounts are listed only with Show inactive and closed")
                }
                Section {
                    HStack {
                        TextField("User name", text: $userName)
                        copyButton("user name", userName)
                    }
                    secretRow("Password", text: $password)
                    Toggle("Show the keys and password", isOn: $showSecrets)
                } header: {
                    Text("Owner (your user account)")
                } footer: {
                    Text("The product key, service key and password are kept in this Mac's Keychain, never in the security master: other Macs don't see them.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Subscription payment") {
                    Toggle("A payment was made", isOn: $hasPayment)
                    if hasPayment {
                        DatePicker("Payment date", selection: $paymentDate, displayedComponents: .date)
                        TextField("Payment amount", value: $paymentAmount, format: .number.precision(.fractionLength(2)))
                    }
                }
                Section("Subscription renewal") {
                    Toggle("It renews", isOn: $hasRenewal)
                    if hasRenewal {
                        DatePicker("Renewal date", selection: $renewalDate, displayedComponents: .date)
                        TextField("Renewal amount", value: $renewalAmount, format: .number.precision(.fractionLength(2)))
                    }
                    Picker("Renewal status", selection: $renewalStatus) {
                        ForEach(RenewalStatus.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                    }
                    .help(RenewalStatus(rawValue: renewalStatus)?.help ?? "")
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
                Button(account == nil ? "Add" : "Save") { Task { await finish() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled((account == nil && name.trimmingCharacters(in: .whitespaces).isEmpty) || saving)
            }
            .padding(18)
        }
        .frame(width: 540, height: 720)
        .onAppear(perform: load)
    }

    /// A key or password field with a copy button, masked unless shown.
    private func secretRow(_ title: String, text: Binding<String>) -> some View {
        HStack {
            if showSecrets { TextField(title, text: text) } else { SecureField(title, text: text) }
            copyButton(title.lowercased(), text.wrappedValue)
        }
    }

    private func copyButton(_ what: String, _ value: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        } label: { Image(systemName: "doc.on.doc") }
            .buttonStyle(.borderless).disabled(value.isEmpty)
            .help("Copy the \(what)")
    }

    private func load() {
        if account == nil, let draft {
            name = draft.name; serviceApi = draft.serviceApi; serviceUrl = draft.serviceUrl
        }
        guard let a = account else { return }
        name = a.name; details = a.description ?? ""; serviceUrl = a.serviceUrl ?? ""; serviceApi = a.serviceApi ?? ""
        status = a.status; userName = a.ownerUserName ?? ""
        hasPayment = a.paymentDate != nil || a.paymentAmount != nil
        paymentDate = a.paymentDate.flatMap { isoDay.date(from: String($0.prefix(10))) } ?? Date()
        paymentAmount = a.paymentAmount
        hasRenewal = a.renewalDate != nil || a.renewalAmount != nil
        renewalDate = a.renewalDate.flatMap { isoDay.date(from: String($0.prefix(10))) } ?? Date()
        renewalAmount = a.renewalAmount
        renewalStatus = a.renewalStatus
        for kind in [SecureSecrets.Kind.productKey, .serviceKey, .password] { saved[kind] = SecureSecrets.get(kind, a.id) ?? "" }
        productKey = saved[.productKey] ?? ""; serviceKey = saved[.serviceKey] ?? ""; password = saved[.password] ?? ""
    }

    /// Saves the details in the security master, then the keys and password in this Mac's Keychain.
    private func finish() async {
        saving = true
        defer { saving = false }
        var body: [String: Any] = [
            "description": details, "serviceUrl": serviceUrl, "serviceApi": serviceApi, "status": status,
            "ownerUserName": userName, "renewalStatus": renewalStatus,
            "paymentDate": hasPayment ? isoDay.string(from: paymentDate) : "",
            "renewalDate": hasRenewal ? isoDay.string(from: renewalDate) : "",
        ]
        body["paymentAmount"] = hasPayment ? (paymentAmount.map { $0 as Any } ?? NSNull()) : NSNull()
        body["renewalAmount"] = hasRenewal ? (renewalAmount.map { $0 as Any } ?? NSNull()) : NSNull()
        // Details leave the name as saved (Edit Service Name changes it).
        if let account { body["version"] = account.version } else { body["name"] = name }
        let answer = await save(body)
        if let e = answer.error { error = e; return }
        guard let id = answer.id else {
            error = "Saved, but its keys and password weren't: open it again to enter them."
            return
        }
        let product = account?.name ?? name
        let kept = [(SecureSecrets.Kind.productKey, productKey), (.serviceKey, serviceKey), (.password, password)].allSatisfy { kind, value in
            value == (saved[kind] ?? "") || SecureSecrets.set(value, kind, id, product: product)
        }
        if !kept {
            error = "Saved, but the Keychain didn't take a key or the password."
            return
        }
        dismiss()
    }
}

// MARK: - Edit Service Name

/// Renames a secure account (a row's context menu). Names are unique whatever their case: one another account already
/// has can't be saved (the security master refuses it too, for a name taken since). Save closes the dialog.
struct SecureNameSheet: View {
    let account: SecureAccount
    /// Every secure account's name, to say before saving when the new one is taken.
    let names: [String]
    var save: (String) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var error: String?
    @State private var saving = false

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Another account with this name (in any case), if there is one.
    private var taken: String? {
        guard trimmed.lowercased() != account.name.lowercased() else { return nil }
        return names.first { $0.lowercased() == trimmed.lowercased() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Service Name").heading(.heading)
            Form {
                TextField("Product name", text: $name)
                    .onSubmit { if canSave { Task { await finish() } } }
            }
            if let taken {
                Label("There is already a service named \(taken): names are unique, whatever their case.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.callout)
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
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
        .onAppear { name = account.name }
    }

    private var canSave: Bool { !trimmed.isEmpty && trimmed != account.name && taken == nil && !saving }

    private func finish() async {
        saving = true
        error = await save(trimmed)
        saving = false
        if error == nil { dismiss() }
    }
}
