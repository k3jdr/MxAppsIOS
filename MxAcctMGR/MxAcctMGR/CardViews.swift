//
//  CardViews.swift
//  MxAcctMGR
//
//  Banking ▸ Credit Card Accounts: each card kept as a register in the security master (accounts service /cards,
//  V029) — its charges, credits, payments, fees and interest with the balance owed, the credit left, and its
//  statement periods (statement balance, minimum due, due date, paid or not). The card company's side comes from its
//  downloads (Chase CSV / QFX, Discover and Capital One CSV; srm.py load card-downloads): Import File… saves one in
//  the card's drop folder and reads it; each line is read once, also when downloads overlap, and posts to the
//  register — matching a charge entered by hand, else as a new entry with its target and category. A card's payments
//  link to the checking entries that paid them (Pay… writes both).
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Model and client

struct CardAccount: Decodable, Identifiable, Hashable {
    var code: String
    var name: String
    var issuer: String
    var last4: String?
    var creditLimit: Double?
    var apr: Double?
    var closeDay: Int?
    var dueDay: Int?
    var openingDate: String
    var openingBalance: Double
    var payeeId: Int?
    var payee: String?
    var issuerBalance: Double?
    var issuerAvailable: Double?
    var issuerBalanceAsOf: String?
    var closedDate: String?
    var balance: Double
    var postedBalance: Double
    var pendingEntries: Int
    var lastDownload: String?
    var available: Double?
    var id: String { code }
}

struct CardEntry: Decodable, Identifiable, Hashable {
    var id: Int
    var date: String
    var postedDate: String?
    var kind: String
    var payeeId: Int?
    var payee: String?
    var payeeLast4: String?
    var payeeInstitution: String?
    var payeeNote: String?
    var expenseAccountId: Int?
    var expenseAccount: String?
    var memo: String?
    var amount: Double
    var status: String
    var cardLineId: Int?
    var issuerName: String?
    var issuerCategory: String?
    var fileFormat: String?
    var bankTxnId: Int?
    var bankAccount: String?
    var bankDate: String?
    var version: Int
    var enteredBy: String?
    var updatedBy: String?
    var balance: Double
    /// The target's link (TargetAccountLinks.swift), nickname and next payment.
    var payeeLink: TargetLink?
    var payeeNickname: String?
    var payeeNextDate: String?
    var payeeNextAmount: Double?

    /// The entry as the check register's target cell shows it (target, last four digits, note on hover).
    var target: RegisterEntry {
        RegisterEntry(id: id, date: date, kind: kind, checkNo: nil, payeeId: payeeId, payee: payee, payeeLast4: payeeLast4,
                      payeeInstitution: payeeInstitution, payeeNote: payeeNote, expenseAccountId: expenseAccountId,
                      expenseAccount: expenseAccount, memo: memo, amount: amount, status: status, bankLineId: cardLineId,
                      bankDate: postedDate, bankName: issuerName, version: version, enteredBy: enteredBy,
                      updatedBy: updatedBy, balance: balance, line: 0, payeeLink: payeeLink, payeeNickname: payeeNickname,
                      payeeNextDate: payeeNextDate, payeeNextAmount: payeeNextAmount)
    }
}

struct CardStatement: Decodable, Identifiable, Hashable {
    var closingDate: String
    var periodStart: String
    var dueDate: String
    var previousBalance: Double
    var charges: Double
    var credits: Double
    var payments: Double
    var fees: Double
    var interest: Double
    var adjustments: Double
    var registerBalance: Double
    var statementBalance: Double?
    var minimumDue: Double
    var minimumEstimated: Bool
    var paid: Double
    var state: String
    var notes: String?
    var version: Int
    var entries: Int
    var id: String { closingDate }
    /// What is owed for the period: the statement's own figure once entered, else the register's.
    var owed: Double { statementBalance ?? registerBalance }
}

struct CheckingPayment: Decodable, Identifiable, Hashable {
    var id: Int
    var bankAccount: String
    var date: String
    var kind: String
    var checkNo: String?
    var amount: Double
    var memo: String?
    var status: String
}

struct CardRegister: Decodable {
    struct Load: Decodable { var status: String?; var message: String?; var file: String? }
    var account: CardAccount
    var entries: [CardEntry]
    var statements: [CardStatement]
    var unlinkedPayments: [CheckingPayment]
    var load: Load?
}

nonisolated enum CardClient {
    private struct Accounts: Decodable { var accounts: [CardAccount] }
    private static func signed(_ body: [String: Any]) -> [String: Any] { body.merging(["by": BankClient.by]) { a, _ in a } }

    static func accounts() async throws -> [CardAccount] {
        try await AccountsClient.request("GET", "/cards/accounts", as: Accounts.self).accounts
    }
    static func saveAccount(_ code: String, _ body: [String: Any]) async throws -> [CardAccount] {
        try await AccountsClient.request("PUT", "/cards/accounts/\(code)", body: body, as: Accounts.self).accounts
    }
    static func register(_ code: String) async throws -> CardRegister {
        try await AccountsClient.request("GET", "/cards/accounts/\(code)/register", as: CardRegister.self)
    }
    /// The card registers' targets that aren't target accounts yet (Target Accounts ▸ Add from Card Registers…).
    static func targets() async throws -> [CardTarget] {
        try await AccountsClient.request("GET", "/cards/targets", as: CardTargets.self).targets
    }
    /// Makes these card targets target accounts (recipients of credit card payments), their entries linked to them.
    static func addTargets(_ names: [String]) async throws -> CardTargets {
        try await AccountsClient.request("POST", "/cards/targets", body: signed(["names": names]), as: CardTargets.self)
    }
    static func add(_ code: String, _ body: [String: Any]) async throws -> CardRegister {
        try await AccountsClient.request("POST", "/cards/accounts/\(code)/transactions", body: signed(body), as: CardRegister.self)
    }
    static func update(_ id: Int, _ body: [String: Any]) async throws -> CardRegister {
        try await AccountsClient.request("PUT", "/cards/transactions/\(id)", body: signed(body), as: CardRegister.self)
    }
    static func link(_ id: Int, to bankTxn: Int?) async throws -> CardRegister {
        try await AccountsClient.request("POST", "/cards/transactions/\(id)/link", body: signed(["bankTxnId": bankTxn ?? NSNull()]), as: CardRegister.self)
    }
    static func pay(_ code: String, _ body: [String: Any]) async throws -> CardRegister {
        try await AccountsClient.request("POST", "/cards/accounts/\(code)/pay", body: signed(body), as: CardRegister.self)
    }
    static func saveStatement(_ code: String, _ closing: String, _ body: [String: Any]) async throws -> CardRegister {
        try await AccountsClient.request("PUT", "/cards/accounts/\(code)/statements/\(closing)", body: signed(body), as: CardRegister.self)
    }
    /// Saves a download in the card's drop folder and reads it; with no file, reads the drop folders now.
    static func importFile(_ code: String, filename: String? = nil, text: String? = nil) async throws -> CardRegister {
        var body: [String: Any] = [:]
        if let filename, let text { body = ["filename": filename, "text": text] }
        return try await AccountsClient.request("POST", "/cards/accounts/\(code)/import", body: body, timeout: 300, as: CardRegister.self)
    }
}

// MARK: - Credit Card Accounts

struct CardsView: View {
    @Bindable var store: PortStore
    @AppStorage("cardAccount") private var selected = ""
    /// The statement period the register shows (its closing date), or all of it.
    @AppStorage("cardStatementShown") private var period = ""
    /// How many of the register's and the statements' rows show at once.
    @AppStorage("cardRegisterRows") private var registerRows = 22
    @AppStorage("cardStatementRows") private var statementRows = 12
    @State private var accounts: [CardAccount] = []
    @State private var register: CardRegister?
    @State private var book: ExpenseBook?
    @State private var checking: [BankAccount] = []
    @State private var message: String?
    @State private var problem: String?
    @State private var busy = false
    @State private var editing: CardEntry?
    @State private var accountSheet: CardAccount??
    @State private var paying = false
    @State private var linking: CardEntry?
    @State private var statement: CardStatement?
    @State private var selection = Set<CardEntry.ID>()
    @State private var draft = CardDraft()
    /// The register's Excel-style sorting and column filters (the header buttons).
    @State private var grid = GridQueryOptions()

    var body: some View {
        StepPage(store: store, subtitle: "Each card's register: what was charged and paid, the balance owed and the credit left, statement by statement. The card company's downloads post to it.", lesson: [
            "Download the card's activity — Chase: Spreadsheet (CSV) or Quicken (QFX); Discover and Capital One: CSV — and Import File… it here. Downloads that overlap are fine: each line is read once.",
            "Each line posts to the register with its target (found by the name the card company uses, once you have picked a target for it) and category (the target's, else the card company's). Enter a charge by hand from a receipt and the download's line matches it.",
            "Pay… writes the checking entry and the card's payment together, linked; a payment already in the check register links by itself (same amount within a week). A statement is paid when the payments by its due date cover its balance.",
        ]) {
            accountBar
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
            }
            if let r = register {
                tiles(r)
                CardEntryForm(draft: $draft, payees: activePayees, expenseAccounts: book?.expenseAccounts ?? []) { await add() }
                registerTable(r)
                if !r.unlinkedPayments.isEmpty { unlinked(r) }
                statements(r)
            } else if accounts.isEmpty && problem == nil && !busy {
                ContentUnavailableView {
                    Label("No credit card account yet", systemImage: "creditcard")
                } description: {
                    Text("Add a card: its name, issuer, the last four digits of its number (how the downloads name it), its credit limit and the days its statement closes and its payment is due.")
                } actions: {
                    Button("New Credit Card Account…") { accountSheet = .some(nil) }
                }
            }
        }
        .task { await reload() }
        // A target's link changed (here, in Checking or in Target Accounts): the register shows it.
        .onChange(of: PayeeLinks.shared.version) { Task { await reload() } }
        .task(id: selected) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if editing == nil, !busy { await refresh() }
            }
        }
        .sheet(item: $editing) { e in
            CardEditSheet(entry: e, payees: activePayees, expenseAccounts: book?.expenseAccounts ?? []) { body in
                await run { try await CardClient.update(e.id, body) }
            }
        }
        .sheet(isPresented: Binding(get: { accountSheet != nil }, set: { if !$0 { accountSheet = nil } })) {
            CardAccountSheet(account: accountSheet ?? nil, payees: book?.payees ?? []) { code, body in
                do {
                    accounts = try await CardClient.saveAccount(code, body)
                    selected = code.uppercased()
                    await refresh()
                    return nil
                } catch { return describe(error) }
            }
        }
        .sheet(isPresented: $paying) {
            if let a = register?.account {
                PayCardSheet(card: a, checking: checking, statement: register?.statements.first) { body in
                    await run { try await CardClient.pay(a.code, body) }
                }
            }
        }
        .sheet(item: $linking) { e in
            LinkPaymentSheet(entry: e, payments: register?.unlinkedPayments ?? []) { bankTxn in
                await run { try await CardClient.link(e.id, to: bankTxn) }
            }
        }
        .sheet(item: $statement) { s in
            StatementSheet(statement: s) { body in
                guard let code = register?.account.code else { return nil }
                return await run { try await CardClient.saveStatement(code, s.closingDate, body) }
            }
        }
    }

    /// The targets this register offers: active target accounts with credit card among their funding sources.
    private var activePayees: [Payee] { (book?.payees ?? []).filter { $0.offered(in: .card) } }

    private var accountBar: some View {
        HStack(spacing: 10) {
            Picker("Card", selection: $selected) {
                ForEach(accounts) { a in Text("\(a.name)\(a.last4.map { " ···\($0)" } ?? "")").tag(a.code) }
            }
            .frame(maxWidth: 340)
            .disabled(accounts.isEmpty)
            Button("New…") { accountSheet = .some(nil) }
            Button("Edit…") { accountSheet = .some(register?.account) }.disabled(register == nil)
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            if let message { Text(message).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
            Button { importFile() } label: { Label("Import File…", systemImage: "arrow.down.doc") }
                .disabled(register == nil || busy)
                .help("Read a download from the card company (Chase CSV / QFX / OFX, Discover or Capital One CSV): it is saved in the card's drop folder, and lines already read are skipped")
            Button { paying = true } label: { Label("Pay…", systemImage: "arrow.right.circle") }
                .disabled(register == nil || busy)
                .help("Pay the card from a checking account: the checking entry and the card's payment, linked")
            Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Show what others entered since")
        }
        .onChange(of: selected) { period = ""; Task { await refresh() } }
    }

    private func tiles(_ r: CardRegister) -> some View {
        let a = r.account
        let s = r.statements.first
        return HStack(spacing: 10) {
            MetricTile(title: "Balance owed", value: money2(a.balance),
                       caption: a.pendingEntries > 0 ? "\(a.pendingEntries) entr\(a.pendingEntries == 1 ? "y" : "ies") not posted yet" : "every entry posted",
                       tint: a.balance > 0 ? .primary : .green,
                       help: "The opening balance plus every entry not void: charges, fees and interest add to it; payments and credits lower it.")
            MetricTile(title: "Available credit", value: a.available.map(money2) ?? "—",
                       caption: a.creditLimit.map { "of \(money2($0))" + (a.apr.map { String(format: " · %.2f%% APR", $0) } ?? "") } ?? "set the credit limit in Edit…",
                       tint: (a.available ?? 1) < 0 ? .red : .primary,
                       help: "The credit limit less the balance owed.")
            MetricTile(title: "Statement", value: s.map { money2($0.owed) } ?? "—",
                       caption: s.map { "closed \(shortDay($0.closingDate)) · min \(money2($0.minimumDue))\($0.minimumEstimated ? " (est.)" : "") · due \(shortDay($0.dueDate)) · \($0.state)" }
                           ?? (a.closeDay == nil ? "set the closing day in Edit…" : "no statement closed yet"),
                       tint: s.map { stateColor($0.state) } ?? .secondary,
                       help: "The latest statement: its balance (the statement's own once entered, else the register's), minimum due (estimated until entered), due date and whether the payments by then cover it. Green when paid.")
            MetricTile(title: a.issuer, value: a.issuerBalance.map(money2) ?? "—",
                       caption: a.issuerBalanceAsOf.map { "owed per its download of \(shortDay($0))" }
                           ?? (a.lastDownload.map { "lines read through \(shortDay($0))" } ?? "no download read yet"),
                       tint: a.issuerBalance.map { abs($0 - a.postedBalance) < 0.005 ? .green : .orange } ?? .secondary,
                       help: "The balance in the card company's latest QFX / OFX download (CSV files have none). Green when it equals the register's posted balance.")
        }
    }

    private func stateColor(_ state: String) -> Color {
        switch state {
        case "paid", "nothing due": .green
        case "late": .red
        case "minimum paid": .orange
        default: .primary
        }
    }

    private func shown(_ r: CardRegister) -> [CardEntry] {
        guard let s = r.statements.first(where: { $0.closingDate == period }) else { return r.entries }
        return r.entries.filter { let d = $0.postedDate ?? $0.date; return d >= s.periodStart && d <= s.closingDate }
    }

    /// The register's columns for sorting and filtering, by their titles.
    static let columns: [String: LocalGridColumn<CardEntry>] = [
        "Date": .date({ $0.date }, display: { shortDay($0.date) }),
        "Kind": .text { ["charge": "Charge", "credit": "Credit", "payment": "Payment", "fee": "Fee", "interest": "Interest", "adjustment": "Adjust"][$0.kind] ?? $0.kind },
        "Target": .text { $0.payee },
        "Category": .text { $0.expenseAccount },
        "Memo": .text { $0.memo },
        "Charge": .number({ $0.amount > 0 ? $0.amount : nil }, display: { $0.amount > 0 ? money2($0.amount) : nil }),
        "Credit": .number({ $0.amount < 0 ? -$0.amount : nil }, display: { $0.amount < 0 ? money2(-$0.amount) : nil }),
        "✓": .text { ["posted": "Posted", "reconciled": "Reconciled", "void": "Void"][$0.status] ?? "Not posted" },
        "Owed": .number({ $0.status == "void" ? nil : $0.balance }, display: { $0.status == "void" ? nil : money2($0.balance) }),
    ]

    private func registerTable(_ r: CardRegister) -> some View {
        let period = shown(r)
        let rows = LocalGrid.rows(period, grid, Self.columns)
        return Box(title: "Register", symbol: "creditcard", help: "Every entry in posting order with the running balance owed (over the whole register, also when one statement is shown or the rows are filtered or sorted otherwise). Each column header's button sorts and filters it, as in Excel. Double-click to change one; the register is shared, so a change made from an older copy is refused. Picking a target for a card company's line maps its name there to that target from now on.") {
            HStack(spacing: 8) {
                Picker("Show", selection: $period) {
                    Text("All entries").tag("")
                    ForEach(r.statements) { s in Text("Statement closing \(shortDay(s.closingDate))").tag(s.closingDate) }
                }
                .fixedSize()
                DateOrderToggle(options: $grid, key: "cardRegisterNewestFirst")
                Spacer()
                if period.count < r.entries.count {
                    Text("\(period.count) of \(r.entries.count) entries").font(.callout).foregroundStyle(.secondary)
                }
                RowsStepper(rows: $registerRows, what: "register")
            }
            GridFilterStatus(shown: rows.count, of: period.count, options: $grid)
            Table(rows, selection: $selection) {
                TableColumn("Date") { e in Text(shortDay(e.date)).monospacedDigit().help(entryHelp(e)) }.width(min: 70, ideal: 84)
                TableColumn("Kind") { e in Text(kindLabel(e.kind)).foregroundStyle(.secondary) }.width(min: 50, ideal: 64)
                TableColumn("Target") { e in
                    TargetCell(entry: e.target, website: e.payeeId.flatMap { id in book?.payees.first { $0.id == id }?.logonUrl }) { id, note in await saveNote(id, note) }
                }.width(min: 140, ideal: 200)
                TableColumn("Category") { e in Text(e.expenseAccount ?? "").foregroundStyle(.secondary).help(e.issuerCategory.map { "\(r.account.issuer): \($0)" } ?? "") }.width(min: 80, ideal: 130)
                TableColumn("Memo") { e in Text(e.memo ?? "").foregroundStyle(.secondary) }.width(min: 50, ideal: 90)
                TableColumn("Charge") { e in Text(e.amount > 0 ? money2(e.amount) : "").monospacedDigit() }.width(min: 60, ideal: 90)
                TableColumn("Credit") { e in Text(e.amount < 0 ? money2(-e.amount) : "").monospacedDigit().foregroundStyle(.green) }.width(min: 60, ideal: 90)
                TableColumn("✓") { e in statusMark(e) }.width(40)
                TableColumn("Owed") { e in Text(e.status == "void" ? "" : money2(e.balance)).monospacedDigit() }.width(min: 70, ideal: 100)
            }
            .tableText()
            .contextMenu(forSelectionType: CardEntry.ID.self) { ids in
                let chosen = r.entries.filter { ids.contains($0.id) }
                if chosen.count == 1, let e = chosen.first {
                    Button("Edit Entry…") { editing = e }
                    if e.kind == "payment" {
                        if e.bankTxnId == nil { Button("Link to Checking Payment…") { linking = e }.disabled(r.unlinkedPayments.isEmpty) }
                        else { Button("Unlink from \(e.bankAccount ?? "Checking")") { Task { await run { try await CardClient.link(e.id, to: nil) } } } }
                    }
                    Divider()
                    if e.status != "void" { Button("Void") { Task { await setStatus(e, "void") } } }
                    else { Button("Restore") { Task { await setStatus(e, "pending") } } }
                    Divider()
                }
                if !chosen.isEmpty {
                    Button(chosen.count == 1 ? "Copy Entry" : "Copy \(chosen.count) Entries") { copy(Self.text(chosen)) }
                }
            } primaryAction: { ids in
                if ids.count == 1, let e = r.entries.first(where: { ids.contains($0.id) }) { editing = e }
            }
            .textSelection(.disabled)
            .onCopyCommand {
                let chosen = rows.filter { selection.contains($0.id) }
                return chosen.isEmpty ? [] : [NSItemProvider(object: Self.text(chosen) as NSString)]
            }
            .columnHeaderFilters(types: LocalGrid.types(Self.columns), options: grid,
                                 loadValues: { (LocalGrid.values(period, column: $0, grid, Self.columns), false) },
                                 apply: { grid = $0 })
            .frame(minHeight: PortSettings.shared.tableHeight(rows: min(max(rows.count, 6), registerRows)))
        }
    }

    private func unlinked(_ r: CardRegister) -> some View {
        Box(title: "Checking payments to \(r.account.payee ?? "this card"), not linked", symbol: "link.badge.plus", help: "Entries in a check register paid to this card's target account that no card payment is linked to yet — the card company's line for them hasn't been read, or its amount or date differs. Link… ties one to the card's payment it is.") {
            ForEach(r.unlinkedPayments) { p in
                HStack(spacing: 10) {
                    Text(shortDay(p.date)).monospacedDigit().frame(width: 84, alignment: .leading)
                    Text(p.bankAccount).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                    Text(p.memo ?? (p.checkNo.map { "check \($0)" } ?? p.kind)).foregroundStyle(.secondary)
                    Spacer()
                    Text(money2(-p.amount)).monospacedDigit()
                    Menu("Link…") {
                        let payments = r.entries.filter { $0.kind == "payment" && $0.bankTxnId == nil && $0.status != "void" }
                        ForEach(payments.sorted { abs($0.amount - p.amount) < abs($1.amount - p.amount) }) { e in
                            Button("\(shortDay(e.date))  \(money2(-e.amount))  \(e.payee ?? "")") {
                                Task { await run { try await CardClient.link(e.id, to: p.id) } }
                            }
                        }
                        if payments.isEmpty { Text("No card payment to link it to yet") }
                    }
                    .fixedSize()
                }
                .font(.callout)
            }
        }
    }

    private func statements(_ r: CardRegister) -> some View {
        Box(title: "Statements", symbol: "doc.text", help: "Each statement period, newest first, from the closing day: what the register adds up to, and what the statement itself says once entered (double-click a period to enter its balance, minimum due and due date from the statement). Paid when the payments after it closed, by its due date, cover its balance.") {
            if r.statements.isEmpty {
                Text(r.account.closeDay == nil ? "Set the statement closing day (Edit…) to see the periods." : "No statement has closed since the register starts.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                HStack {
                    Spacer()
                    RowsStepper(rows: $statementRows, range: 3...30, what: "statements table")
                }
                Table(r.statements) {
                    TableColumn("Closed") { s in Text(shortDay(s.closingDate)).monospacedDigit().help("\(shortDay(s.periodStart)) – \(shortDay(s.closingDate)), \(s.entries) entries") }.width(min: 70, ideal: 84)
                    TableColumn("Previous") { s in Text(money2(s.previousBalance)).monospacedDigit() }.width(min: 70, ideal: 90)
                    TableColumn("Charges") { s in Text(money2(s.charges + s.fees + s.interest + s.adjustments)).monospacedDigit().help("Charges \(money2(s.charges)) · fees \(money2(s.fees)) · interest \(money2(s.interest))\(s.adjustments != 0 ? " · adjustments \(money2(s.adjustments))" : "")") }.width(min: 70, ideal: 90)
                    TableColumn("Credits") { s in Text(money2(0 - (s.payments + s.credits) + 0)).monospacedDigit().help("Payments \(money2(-s.payments)) · credits \(money2(-s.credits))") }.width(min: 70, ideal: 90)
                    TableColumn("Balance") { s in
                        HStack(spacing: 4) {
                            Text(money2(s.owed)).monospacedDigit()
                            if let sb = s.statementBalance, abs(sb - s.registerBalance) >= 0.005 {
                                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                                    .help("The statement says \(money2(sb)); the register adds up to \(money2(s.registerBalance))")
                            }
                        }
                    }.width(min: 80, ideal: 100)
                    TableColumn("Minimum") { s in Text(money2(s.minimumDue) + (s.minimumEstimated ? " est." : "")).monospacedDigit().foregroundStyle(s.minimumEstimated ? .secondary : .primary) }.width(min: 70, ideal: 100)
                    TableColumn("Due") { s in Text(shortDay(s.dueDate)).monospacedDigit() }.width(min: 70, ideal: 84)
                    TableColumn("Paid") { s in Text(money2(s.paid)).monospacedDigit() }.width(min: 70, ideal: 90)
                    TableColumn("") { s in Text(s.state).foregroundStyle(stateColor(s.state)) }.width(min: 70, ideal: 100)
                }
                .tableText()
                .contextMenu(forSelectionType: CardStatement.ID.self) { ids in
                    if let s = r.statements.first(where: { ids.contains($0.id) }) {
                        Button("Enter What the Statement Says…") { statement = s }
                        Button("Show Its Entries") { period = s.closingDate }
                    }
                } primaryAction: { ids in
                    if let s = r.statements.first(where: { ids.contains($0.id) }) { statement = s }
                }
                .frame(minHeight: PortSettings.shared.tableHeight(rows: min(max(r.statements.count, 3), statementRows)))
            }
        }
    }

    private func statusMark(_ e: CardEntry) -> some View {
        HStack(spacing: 2) {
            switch e.status {
            case "posted": Image(systemName: "checkmark").foregroundStyle(.green).help("Posted by the card company\(e.postedDate.map { " on \(shortDay($0))" } ?? "")\(e.issuerName.map { ": \($0)" } ?? "")")
            case "reconciled": Image(systemName: "checkmark.seal").foregroundStyle(.green).help("Reconciled")
            case "void": Image(systemName: "xmark").foregroundStyle(.secondary).help("Void")
            default: Image(systemName: "clock").foregroundStyle(.secondary).help("Not posted yet: the card company's download hasn't shown it")
            }
            if e.bankTxnId != nil {
                Image(systemName: "link").foregroundStyle(.secondary).font(.caption)
                    .help("Paid from \(e.bankAccount ?? "checking")\(e.bankDate.map { " on \(shortDay($0))" } ?? "")")
            }
        }
    }

    private func kindLabel(_ k: String) -> String {
        ["charge": "Charge", "credit": "Credit", "payment": "Payment", "fee": "Fee", "interest": "Interest", "adjustment": "Adjust"][k] ?? k
    }

    private func entryHelp(_ e: CardEntry) -> String {
        var parts = ["Entered by \(e.enteredBy ?? "—")"]
        if let u = e.updatedBy, u != e.enteredBy { parts.append("last changed by \(u)") }
        if let n = e.issuerName { parts.append("\(register?.account.issuer ?? "Card"): \(n)\(e.fileFormat.map { " (\($0))" } ?? "")") }
        return parts.joined(separator: " · ")
    }

    static func text(_ entries: [CardEntry]) -> String {
        let head = ["Date", "Posted", "Kind", "Target", "Category", "Memo", "Charge", "Credit", "Status", "Owed"].joined(separator: "\t")
        let lines = entries.map { e -> String in
            let cells: [String] = [e.date, e.postedDate ?? "", e.kind, e.payee ?? "", e.expenseAccount ?? "", e.memo ?? "",
                                   e.amount > 0 ? String(format: "%.2f", e.amount) : "", e.amount < 0 ? String(format: "%.2f", -e.amount) : "",
                                   e.status, String(format: "%.2f", e.balance)]
            return cells.joined(separator: "\t")
        }
        return ([head] + lines).joined(separator: "\n")
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Loading and saving

    private func reload() async {
        busy = true
        defer { busy = false }
        do {
            accounts = try await CardClient.accounts()
            book = try? await BankClient.book()
            checking = (try? await BankClient.accounts()) ?? []
            if !accounts.contains(where: { $0.code == selected }) { selected = accounts.first?.code ?? "" }
            problem = nil
            await refresh()
        } catch {
            problem = describe(error)
        }
    }

    private func refresh() async {
        guard !selected.isEmpty else { register = nil; return }
        do {
            register = try await CardClient.register(selected)
            problem = nil
        } catch {
            problem = describe(error)
        }
    }

    @discardableResult
    private func run(_ change: () async throws -> CardRegister) async -> String? {
        busy = true
        defer { busy = false }
        do {
            register = try await change()
            book = try? await BankClient.book()
            message = nil
            return nil
        } catch {
            await refresh()
            message = describe(error)
            return describe(error)
        }
    }

    private func saveNote(_ payee: Int, _ note: String) async -> String? {
        do {
            _ = try await BankClient.savePayeeNote(payee, note)
            await refresh()
            book = try? await BankClient.book()
            return nil
        } catch { return describe(error) }
    }

    private func add() async -> String? {
        guard let code = register?.account.code else { return "Choose a card" }
        let error = await run { try await CardClient.add(code, draft.body) }
        if error == nil {
            let keep = draft.date
            draft = CardDraft()
            draft.date = keep
        }
        return error
    }

    private func setStatus(_ e: CardEntry, _ status: String) async {
        await run { try await CardClient.update(e.id, ["version": e.version, "status": status]) }
    }

    private func importFile() {
        guard let code = register?.account.code else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText] + ["qfx", "ofx"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsOtherFileTypes = true
        panel.message = "A download of the card's activity: Chase CSV or QFX / OFX, Discover or Capital One CSV"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else {
            message = "\(url.lastPathComponent) could not be read."
            return
        }
        Task {
            busy = true
            defer { busy = false }
            do {
                let r = try await CardClient.importFile(code, filename: url.lastPathComponent, text: text)
                register = r
                message = r.load?.message.map { "\(r.load?.file ?? "Downloads"): \($0)" }
            } catch {
                message = describe(error)
            }
        }
    }
}

// MARK: - Entering a charge

struct CardDraft {
    var date = Date()
    var kind = "charge"
    var payee = ""
    var expenseAccountId: Int?
    var memo = ""
    var amount: Double?

    var body: [String: Any] {
        var b: [String: Any] = ["date": isoDay.string(from: date), "kind": kind, "payee": payee, "memo": memo, "amount": amount ?? 0]
        if let expenseAccountId { b["expenseAccountId"] = expenseAccountId }
        return b
    }
}

struct CardEntryForm: View {
    @Binding var draft: CardDraft
    var payees: [Payee]
    var expenseAccounts: [ExpenseAccount]
    var save: () async -> String?
    @State private var error: String?
    @State private var saving = false

    static let kinds = [("charge", "Charge"), ("credit", "Credit / refund"), ("payment", "Payment"), ("fee", "Fee"),
                        ("interest", "Interest"), ("adjustment", "Adjustment")]

    var body: some View {
        Box(title: "New entry", symbol: "square.and.pencil", help: "A charge from a receipt (or a credit, fee …) before the card company's download shows it: the date, its target, what it is for and the amount. When the download's line comes — the same amount within a week — it posts this entry instead of adding another.") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                DatePicker("", selection: $draft.date, displayedComponents: .date).labelsHidden().fixedSize()
                Picker("", selection: $draft.kind) { ForEach(Self.kinds, id: \.0) { Text($0.1).tag($0.0) } }
                    .labelsHidden().frame(width: 130)
                TargetPicker(target: $draft.payee, payees: payees, prompt: draft.kind == "credit" ? "From" : "Paid to") { fill() }
                Picker("", selection: $draft.expenseAccountId) {
                    Text("Category").tag(Int?.none)
                    ForEach(expenseAccounts) { Text($0.name).tag(Optional($0.id)) }
                }
                .labelsHidden().frame(width: 170)
                TextField("Memo", text: $draft.memo).frame(minWidth: 100)
                TextField("Amount", value: $draft.amount, format: .number.precision(.fractionLength(2))).frame(width: 100)
                    .onSubmit { Task { await enter() } }
                Button("Enter") { Task { await enter() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(saving || (draft.amount ?? 0) == 0)
                    .help("Add it to the register (⌘↩)")
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
        }
    }

    private func fill() {
        guard let p = payees.first(where: { $0.name.caseInsensitiveCompare(draft.payee) == .orderedSame }) else { return }
        draft.payee = p.name
        if draft.expenseAccountId == nil { draft.expenseAccountId = p.expenseAccountId }
        if draft.amount == nil, let a = p.defaultAmount { draft.amount = a }
    }

    private func enter() async {
        fill()
        saving = true
        error = await save()
        saving = false
    }
}

struct CardEditSheet: View {
    let entry: CardEntry
    var payees: [Payee]
    var expenseAccounts: [ExpenseAccount]
    var save: ([String: Any]) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var draft = CardDraft()
    @State private var status = "pending"
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Entry").heading(.heading)
            Text("Entered by \(entry.enteredBy ?? "—")\(entry.updatedBy.map { " · last changed by \($0)" } ?? "") · version \(entry.version)")
                .font(.caption).foregroundStyle(.secondary)
            Form {
                DatePicker("Date", selection: $draft.date, displayedComponents: .date)
                Picker("Kind", selection: $draft.kind) { ForEach(CardEntryForm.kinds, id: \.0) { Text($0.1).tag($0.0) } }
                TargetPicker(target: $draft.payee, payees: payees, prompt: "Paid to", label: "Target") {}
                Picker("Category", selection: $draft.expenseAccountId) {
                    Text("None").tag(Int?.none)
                    ForEach(expenseAccounts) { Text($0.name).tag(Optional($0.id)) }
                }
                .disabled(draft.kind == "payment")
                TextField("Memo", text: $draft.memo)
                TextField("Amount", value: $draft.amount, format: .number.precision(.fractionLength(2)))
                Picker("Status", selection: $status) {
                    Text("Not posted").tag("pending"); Text("Posted").tag("posted"); Text("Reconciled").tag("reconciled"); Text("Void").tag("void")
                }
            }
            if let n = entry.issuerName {
                Label("The card company's line \"\(n)\"\(entry.issuerCategory.map { " (\($0))" } ?? "") of \(shortDay(entry.postedDate)). A target picked here is used for that name from now on; marking it not posted or void unmatches the line.", systemImage: "creditcard")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    Task {
                        var body = draft.body
                        body["version"] = entry.version
                        body["status"] = status
                        if draft.payee.isEmpty { body.removeValue(forKey: "payee") }
                        if let e = await save(body) { error = e } else { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 480)
        .onAppear {
            draft.date = isoDay.date(from: entry.date) ?? Date()
            draft.kind = entry.kind
            draft.payee = entry.payee ?? ""
            draft.expenseAccountId = entry.expenseAccountId
            draft.memo = entry.memo ?? ""
            draft.amount = entry.kind == "adjustment" ? entry.amount : abs(entry.amount)
            status = entry.status
        }
    }
}

struct CardAccountSheet: View {
    let account: CardAccount?
    var payees: [Payee]
    var save: (String, [String: Any]) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var name = ""
    @State private var issuer = "Chase"
    @State private var last4 = ""
    @State private var creditLimit: Double?
    @State private var apr: Double?
    @State private var closeDay: Int?
    @State private var dueDay: Int?
    @State private var openingDate = Date()
    @State private var openingBalance = 0.0
    @State private var payeeId: Int?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(account == nil ? "New Credit Card Account" : "Edit \(account!.name)").heading(.heading)
            Form {
                TextField("Code", text: $code).disabled(account != nil)
                    .help("A short name for it: letters, digits, _ or - (CHASE_VISA)")
                TextField("Name", text: $name)
                Picker("Issuer", selection: $issuer) {
                    ForEach(["Chase", "Discover", "Capital One", "Citi", "American Express", "Other"], id: \.self) { Text($0).tag($0) }
                }
                TextField("Last four digits", text: $last4)
                    .help("How the card company's downloads name the card. Never the whole card number.")
                TextField("Credit limit", value: $creditLimit, format: .number.precision(.fractionLength(2)))
                TextField("Purchase APR %", value: $apr, format: .number.precision(.fractionLength(2)))
                TextField("Statement closes on day", value: $closeDay, format: .number)
                    .help("The day of the month the statement closes (the last day when the month is shorter)")
                TextField("Payment due on day", value: $dueDay, format: .number)
                    .help("The day of the month the payment is due: in the month after the statement closes when it comes before the closing day")
                Picker("Paid from checking as", selection: $payeeId) {
                    Text("None").tag(Int?.none)
                    // A recipient of checking account payments (and the one chosen, whatever it is now).
                    ForEach(payees.filter { $0.offered(in: .checking) || $0.id == payeeId }) { p in Text(TargetPicker.title(p)).tag(Optional(p.id)) }
                }
                .help("The target account the check register pays this card as (Chase Card, Discover …): its payments there link to the card's")
                DatePicker("Register starts", selection: $openingDate, displayedComponents: .date)
                    .help("Best a statement's closing date: the first period is the next full one")
                TextField("Owed then", value: $openingBalance, format: .number.precision(.fractionLength(2)))
            }
            Text("The register starts on that day owing that balance (the statement balance, when it is a closing date): entries and downloaded lines before it are left out of the balances.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(account == nil ? "Add" : "Save") {
                    Task {
                        var body: [String: Any] = ["name": name, "issuer": issuer, "last4": last4,
                                                   "openingDate": isoDay.string(from: openingDate), "openingBalance": openingBalance]
                        body["creditLimit"] = creditLimit ?? NSNull()
                        body["apr"] = apr ?? NSNull()
                        body["closeDay"] = closeDay ?? NSNull()
                        body["dueDay"] = dueDay ?? NSNull()
                        body["payeeId"] = payeeId ?? NSNull()
                        if let c = account?.closedDate { body["closedDate"] = c }
                        if let e = await save(code, body) { error = e } else { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(code.isEmpty || name.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 460)
        .onAppear {
            guard let a = account else { code = "CHASE_VISA"; name = "Chase Visa"; return }
            code = a.code; name = a.name; issuer = a.issuer; last4 = a.last4 ?? ""
            creditLimit = a.creditLimit; apr = a.apr; closeDay = a.closeDay; dueDay = a.dueDay; payeeId = a.payeeId
            openingDate = isoDay.date(from: a.openingDate) ?? Date(); openingBalance = a.openingBalance
        }
    }
}

struct PayCardSheet: View {
    let card: CardAccount
    var checking: [BankAccount]
    var statement: CardStatement?
    var pay: ([String: Any]) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var from = ""
    @State private var date = Date()
    @State private var amount: Double?
    @State private var memo = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pay \(card.name)").heading(.heading)
            if card.payeeId == nil {
                Label("Set how the check register pays this card first (Edit… ▸ Paid from checking as).", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).font(.callout)
            }
            Form {
                Picker("From", selection: $from) {
                    ForEach(checking.filter { $0.closedDate == nil }) { a in Text("\(a.name)\(a.last4.map { " ···\($0)" } ?? "")").tag(a.code) }
                }
                DatePicker("Date", selection: $date, displayedComponents: .date)
                TextField("Amount", value: $amount, format: .number.precision(.fractionLength(2)))
                HStack {
                    if let s = statement, s.owed > s.paid {
                        Button("Statement \(money2(s.owed - s.paid))") { amount = s.owed - s.paid }
                        Button("Minimum \(money2(max(0, s.minimumDue - s.paid)))") { amount = max(0, s.minimumDue - s.paid) }
                    }
                    Button("Balance \(money2(card.balance))") { amount = card.balance }.disabled(card.balance <= 0)
                }
                .buttonStyle(.link).font(.callout)
                TextField("Memo", text: $memo, prompt: Text("\(card.name) payment"))
            }
            Text("Writes a transfer in the checking register to \(card.payee ?? "the card's target account") and the card's payment, linked. The card company's line for it posts the payment when its download is read.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Pay") {
                    Task {
                        var body: [String: Any] = ["fromAccount": from, "date": isoDay.string(from: date), "amount": amount ?? 0]
                        if !memo.isEmpty { body["memo"] = memo }
                        if let e = await pay(body) { error = e } else { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(from.isEmpty || (amount ?? 0) <= 0 || card.payeeId == nil)
            }
        }
        .padding(18)
        .frame(width: 440)
        .onAppear {
            from = checking.first(where: { $0.closedDate == nil })?.code ?? ""
            if let s = statement, s.owed > s.paid { amount = ((s.owed - s.paid) * 100).rounded() / 100 }
        }
    }
}

struct LinkPaymentSheet: View {
    let entry: CardEntry
    var payments: [CheckingPayment]
    var link: (Int) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var choice: Int?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Link to a Checking Payment").heading(.heading)
            Text("\(shortDay(entry.date)) · \(entry.payee ?? "Payment") · \(money2(-entry.amount))").foregroundStyle(.secondary)
            Text("The checking entry that paid it (closest amount first):").font(.callout)
            List(selection: $choice) {
                ForEach(payments.sorted { abs($0.amount - entry.amount) < abs($1.amount - entry.amount) }) { p in
                    HStack {
                        Text(shortDay(p.date)).monospacedDigit().frame(width: 84, alignment: .leading)
                        Text(p.bankAccount).frame(width: 130, alignment: .leading).foregroundStyle(.secondary)
                        Text(p.memo ?? (p.checkNo.map { "check \($0)" } ?? p.kind))
                        Spacer()
                        Text(money2(-p.amount)).monospacedDigit()
                    }
                    .tag(p.id)
                }
            }
            .frame(height: 200)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Link") {
                    Task { if let c = choice { if let e = await link(c) { error = e } else { dismiss() } } }
                }
                .keyboardShortcut(.defaultAction).disabled(choice == nil)
            }
        }
        .padding(18)
        .frame(width: 520)
    }
}

struct StatementSheet: View {
    let statement: CardStatement
    var save: ([String: Any]) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var balance: Double?
    @State private var minimum: Double?
    @State private var due = Date()
    @State private var notes = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Statement Closing \(shortDay(statement.closingDate))").heading(.heading)
            Text("\(shortDay(statement.periodStart)) – \(shortDay(statement.closingDate)) · the register adds up to \(money2(statement.registerBalance))")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                TextField("Statement balance", value: $balance, format: .number.precision(.fractionLength(2)), prompt: Text(String(format: "%.2f", statement.registerBalance)))
                TextField("Minimum payment due", value: $minimum, format: .number.precision(.fractionLength(2)), prompt: Text(String(format: "%.2f (est.)", statement.minimumDue)))
                DatePicker("Payment due", selection: $due, displayedComponents: .date)
                TextField("Notes", text: $notes)
            }
            Text("As printed on the statement. Left empty, the register's balance and the estimated minimum are used.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    Task {
                        let body: [String: Any] = ["statementBalance": balance ?? NSNull(), "minimumDue": minimum ?? NSNull(),
                                                   "dueDate": isoDay.string(from: due), "notes": notes, "version": statement.version]
                        if let e = await save(body) { error = e } else { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 440)
        .onAppear {
            balance = statement.statementBalance
            minimum = statement.minimumEstimated ? nil : statement.minimumDue
            due = isoDay.date(from: statement.dueDate) ?? Date()
            notes = statement.notes ?? ""
        }
    }
}
