//
//  BankViews.swift
//  MxAcctMGR
//
//  Banking ▸ Checking Accounts: the paper check book register, kept in the security master so everyone who writes
//  checks on the account enters them in one register (accounts service /bank, V027). The bank's side comes from its
//  downloads (PNC Online Banking QFX / CSV, srm.py load pnc-bank): its lines are matched to the entries — same amount
//  and check number, or same amount within a week — and mark them cleared; the lines left over are the bank's entries
//  the register doesn't have yet, to accept or match.
//
//  Banking ▸ Target Accounts: where the money goes to or comes from — a utility, a card, a brokerage, a person —
//  each with its bank or company, last four digits, category (an expense account: Utilities, Insurance …), usual
//  amount and a note, and the details kept for it (TargetAccounts.swift: nickname, status, identifier, next payment,
//  logon, address, and which registers pay it). They are the registers' targets, not books MxAcctMGR keeps: a new
//  entry's target is picked from the accounts that register pays (its funding sources), with their last four digits
//  showing, and the register shows the target's note on hover and edits it in place. A target account can carry a
//  link — a web page, an email address, a page in MxNoteONE — with words and hover text of its own
//  (TargetAccountLinks.swift): its name shows as that link here and in every register it is a target in.
//

import SwiftUI

// MARK: - Model and client

struct BankAccount: Decodable, Identifiable, Hashable {
    var code: String
    var name: String
    var institution: String
    var last4: String?
    var openingDate: String
    var openingBalance: Double
    var bankBalance: Double?
    var bankBalanceAsOf: String?
    var closedDate: String?
    var balance: Double
    var clearedBalance: Double
    var openEntries: Int
    var bankOnly: Int
    var id: String { code }
}

struct RegisterEntry: Decodable, Identifiable, Hashable {
    var id: Int
    var date: String
    var kind: String
    var checkNo: String?
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
    var bankLineId: Int?
    var bankDate: String?
    var bankName: String?
    var version: Int
    var enteredBy: String?
    var updatedBy: String?
    var balance: Double
    /// The entry's line in the register (1, 2, 3 …), as on the paper register; changed only by Move Up / Move Down.
    var line: Int
    /// The target's link (TargetAccountLinks.swift), shown on its name.
    var payeeLink: TargetLink? = nil
    /// The target account's nickname and next payment, for its hover text.
    var payeeNickname: String? = nil
    var payeeNextDate: String? = nil
    var payeeNextAmount: Double? = nil
}

struct BankLine: Decodable, Identifiable, Hashable {
    var id: Int
    var date: String
    var amount: Double
    var type: String?
    var checkNo: String?
    var name: String?
    var memo: String?
    var payee: String?
}

struct CheckRegister: Decodable {
    struct Load: Decodable { var status: String?; var message: String? }
    var account: BankAccount
    var entries: [RegisterEntry]
    var bankOnly: [BankLine]
    var load: Load?
}

struct ExpenseAccount: Decodable, Identifiable, Hashable {
    var id: Int
    var name: String
    var kind: String
    var description: String?
    var yearTotal: Double
    var yearEntries: Int
}

/// A target account (srm.payee): where a register's money goes to or comes from (TargetAccounts.swift edits it).
struct Payee: Decodable, Identifiable, Hashable {
    var id: Int
    var name: String
    var nickname: String?
    var description: String?
    /// active, inactive (kept, not offered in the registers) or closed.
    var status: String
    var expenseAccountId: Int?
    var defaultAmount: Double?
    /// Its identifier: the account or customer number it knows you by.
    var reference: String?
    var nextPaymentDate: String?
    var nextPaymentAmount: Double?
    var logonUrl: String?
    var userName: String?
    var address1: String?
    var address2: String?
    var city: String?
    var state: String?
    var zipCode: String?
    var phone: String?
    var bankNames: [String]
    var notes: String?
    var active: Bool
    var version: Int
    var institution: String?
    var last4: String?
    /// The registers whose target lists offer it (FundingSource).
    var fundingSources: [String]
    var yearTotal: Double
    /// Every payment with it as the target, in all registers and years (`yearTotal` is this year's alone).
    var totalPaid: Double?
    var lastPaid: String?
    /// Its link (TargetAccountLinks.swift), shown on its name wherever it is a target.
    var link: TargetLink?

    /// Offered as a target by this register's list: active, and the register is one of its funding sources.
    func offered(in source: FundingSource) -> Bool { active && fundingSources.contains(source.rawValue) }
}

struct ExpenseBook: Decodable {
    /// The expense account just saved (PUT /expense-accounts/<id>).
    var id: Int?
    var year: Int
    var expenseAccounts: [ExpenseAccount]
    var payees: [Payee]
}

nonisolated enum BankClient {
    private struct Accounts: Decodable { var accounts: [BankAccount] }

    /// Who an entry was made by, as the register shows it.
    static var by: String { "\(NSFullUserName()) (\(Host.current().localizedName ?? "Mac"))" }

    static func accounts() async throws -> [BankAccount] {
        try await AccountsClient.request("GET", "/bank/accounts", as: Accounts.self).accounts
    }
    static func saveAccount(_ code: String, _ body: [String: Any]) async throws -> [BankAccount] {
        try await AccountsClient.request("PUT", "/bank/accounts/\(code)", body: body, as: Accounts.self).accounts
    }
    static func register(_ code: String) async throws -> CheckRegister {
        try await AccountsClient.request("GET", "/bank/accounts/\(code)/register", as: CheckRegister.self)
    }
    static func add(_ code: String, _ body: [String: Any]) async throws -> CheckRegister {
        try await AccountsClient.request("POST", "/bank/accounts/\(code)/transactions", body: body.merging(["by": by]) { a, _ in a }, as: CheckRegister.self)
    }
    /// Marks several entries cleared or not cleared at once: all or none (refused when one changed since it was read).
    static func setStatus(_ code: String, _ entries: [RegisterEntry], _ status: String) async throws -> CheckRegister {
        try await AccountsClient.request("POST", "/bank/accounts/\(code)/status",
                                         body: ["entries": entries.map { ["id": $0.id, "version": $0.version] }, "status": status, "by": by],
                                         as: CheckRegister.self)
    }
    /// Moves an entry one line up or down in its register (the only way its line changes).
    static func move(_ id: Int, down: Bool) async throws -> CheckRegister {
        try await AccountsClient.request("POST", "/bank/transactions/\(id)/move", body: ["direction": down ? "down" : "up", "by": by], as: CheckRegister.self)
    }
    static func update(_ id: Int, _ body: [String: Any]) async throws -> CheckRegister {
        try await AccountsClient.request("PUT", "/bank/transactions/\(id)", body: body.merging(["by": by]) { a, _ in a }, as: CheckRegister.self)
    }
    static func accept(_ line: Int, _ body: [String: Any] = [:]) async throws -> CheckRegister {
        try await AccountsClient.request("POST", "/bank/lines/\(line)/accept", body: body.merging(["by": by]) { a, _ in a }, as: CheckRegister.self)
    }
    static func match(_ line: Int, to txn: Int) async throws -> CheckRegister {
        try await AccountsClient.request("POST", "/bank/lines/\(line)/match", body: ["txnId": txn, "by": by], as: CheckRegister.self)
    }
    static func importDownloads(_ code: String) async throws -> CheckRegister {
        try await AccountsClient.request("POST", "/bank/accounts/\(code)/import", body: [:], timeout: 300, as: CheckRegister.self)
    }
    static func book() async throws -> ExpenseBook {
        try await AccountsClient.request("GET", "/expense-accounts", as: ExpenseBook.self)
    }
    static func savePayee(_ id: Int, _ body: [String: Any]) async throws -> ExpenseBook {
        try await AccountsClient.request("PUT", "/payees/\(id)", body: body.merging(["by": by]) { a, _ in a }, as: ExpenseBook.self)
    }
    struct Note: Decodable { var id: Int; var note: String?; var version: Int }
    static func savePayeeNote(_ id: Int, _ note: String) async throws -> Note {
        try await AccountsClient.request("PUT", "/payees/\(id)/note", body: ["note": note, "by": by], as: Note.self)
    }
    private struct LinkAnswer: Decodable { var id: Int; var link: TargetLink? }
    /// Saves a target account's link, or with nil takes it off (srm.payee_link, V032).
    static func savePayeeLink(_ id: Int, _ link: SecurityLink?) async throws {
        if let link {
            let body: [String: Any] = ["address": link.address, "text": link.text ?? "", "hoverText": link.tipPlain ?? "",
                                       "hoverRtf": link.tip.flatMap { String(data: $0, encoding: .utf8) } ?? "",
                                       "title": link.title ?? "", "by": by]
            _ = try await AccountsClient.request("PUT", "/payees/\(id)/link", body: body, as: LinkAnswer.self)
        } else {
            _ = try await AccountsClient.request("DELETE", "/payees/\(id)/link", as: LinkAnswer.self)
        }
    }
    static func saveExpenseAccount(_ id: Int, _ body: [String: Any]) async throws -> ExpenseBook {
        try await AccountsClient.request("PUT", "/expense-accounts/\(id)", body: body, as: ExpenseBook.self)
    }
}

let isoDay: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
}()

func shortDay(_ s: String?) -> String {
    guard let s, let d = isoDay.date(from: String(s.prefix(10))) else { return s ?? "" }
    return d.formatted(.dateTime.month(.twoDigits).day(.twoDigits).year())
}

func describe(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
}

// MARK: - Checking Accounts

struct CheckingView: View {
    @Bindable var store: PortStore
    @AppStorage("checkingAccount") private var selected = ""
    @State private var accounts: [BankAccount] = []
    @State private var register: CheckRegister?
    @State private var book: ExpenseBook?
    @State private var message: String?
    @State private var problem: String?
    @State private var busy = false
    @State private var editing: RegisterEntry?
    @State private var accountSheet: BankAccount??
    @State private var matching: BankLine?
    @State private var selection = Set<RegisterEntry.ID>()
    @State private var draft = EntryDraft.newEntry()
    @State private var noteFor: RegisterEntry?
    /// The register's Excel-style sorting and column filters (the header buttons).
    @State private var grid = GridQueryOptions()
    /// Show only entries on or after a date (yyyy-MM-dd), to focus on this week's or this month's payments.
    @AppStorage("registerFocusOn") private var focusOn = false
    @AppStorage("registerFocusFrom") private var focusFrom = ""
    /// How many of the register's rows show at once (more scroll inside it): fewer leave room for the rest of the page.
    @AppStorage(RowsStepper.key) private var registerRows = RowsStepper.standard

    var body: some View {
        StepPage(store: store, subtitle: "The check book register, shared: everyone who writes checks enters them here, and the bank's own lines (PNC downloads) clear them.", lesson: [
            "Enter each check, debit and deposit when it is written — the register is shared, so whoever writes the next check sees the balance you left.",
            "Download the account's activity from PNC Online Banking (Quicken .qfx, or CSV) into the drop folder: the daily refresh — or Check PNC Downloads here — matches the bank's lines to your entries by amount and check number and marks them cleared.",
            "The bank's lines left over are entries the register doesn't have (fees, card debits, automatic payments): accept each into the register, or match it to the entry it is. Register, cleared and bank balances agree when the account is reconciled.",
        ]) {
            accountBar
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
            }
            if let r = register {
                tiles(r.account)
                EntryForm(draft: $draft, payees: activePayees, nextCheck: nextCheck(r)) {
                    await add()
                }
                registerTable(r)
                if !r.bankOnly.isEmpty { bankOnly(r) }
            } else if accounts.isEmpty && problem == nil && !busy {
                ContentUnavailableView {
                    Label("No checking account yet", systemImage: "checkmark.rectangle.stack")
                } description: {
                    Text("Add the account the paper check book is for: its name and the last four digits of its number (how PNC's downloads name it).")
                } actions: {
                    Button("New Checking Account…") { accountSheet = .some(nil) }
                }
            }
        }
        .task { await reload() }
        // The register is shared: pick up what others entered while it is open.
        .task(id: selected) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if editing == nil, !busy { await refresh() }
            }
        }
        // A target's link changed (here or in Target Accounts): every entry with that target shows it.
        .onChange(of: PayeeLinks.shared.version) { Task { await reload() } }
        .sheet(item: $editing) { e in
            EditEntrySheet(entry: e, payees: activePayees, expenseAccounts: book?.expenseAccounts ?? []) { body in
                await run { try await BankClient.update(e.id, body) }
            }
        }
        .sheet(isPresented: Binding(get: { accountSheet != nil }, set: { if !$0 { accountSheet = nil } })) {
            AccountSheet(account: accountSheet ?? nil) { code, body in
                do {
                    accounts = try await BankClient.saveAccount(code, body)
                    selected = code.uppercased()
                    await refresh()
                    return nil
                } catch { return describe(error) }
            }
        }
        .sheet(item: $noteFor) { e in
            TargetNoteEditor(entry: e, initial: e.payeeNote ?? "") { note in
                guard let id = e.payeeId else { return nil }
                return await saveNote(id, note)
            }
            .padding(6)
        }
        .sheet(item: $matching) { line in
            MatchSheet(line: line, entries: (register?.entries ?? []).filter { $0.bankLineId == nil && $0.status == "open" }) { txn in
                await run { try await BankClient.match(line.id, to: txn) }
            }
        }
    }

    /// The targets this register offers: active target accounts with checking among their funding sources.
    private var activePayees: [Payee] { (book?.payees ?? []).filter { $0.offered(in: .checking) } }

    private var accountBar: some View {
        HStack(spacing: 10) {
            Picker("Account", selection: $selected) {
                ForEach(accounts) { a in Text("\(a.name)\(a.last4.map { " ···\($0)" } ?? "")").tag(a.code) }
            }
            .frame(maxWidth: 340)
            .disabled(accounts.isEmpty)
            Button("New…") { accountSheet = .some(nil) }
            Button("Edit…") { accountSheet = .some(register?.account) }.disabled(register == nil)
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            if let message { Text(message).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
            Button { Task { await importDownloads() } } label: { Label("Check PNC Downloads", systemImage: "arrow.down.doc") }
                .disabled(register == nil || busy)
                .help("Read the account's downloads from PNC Online Banking now (srm.py load pnc-bank) and match them to the register")
            Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Show what others entered since")
        }
        .onChange(of: selected) { Task { await refresh() } }
    }

    private func tiles(_ a: BankAccount) -> some View {
        HStack(spacing: 10) {
            MetricTile(title: "Register balance", value: money2(a.balance), caption: "\(a.openEntries) entr\(a.openEntries == 1 ? "y" : "ies") not cleared yet",
                       help: "The opening balance plus every entry not void: what the account holds once everything written has cleared.")
            MetricTile(title: "Cleared balance", value: money2(a.clearedBalance), caption: "entries the bank has shown",
                       help: "The opening balance plus the entries the bank's downloads have matched: it should equal the bank's balance.")
            MetricTile(title: "Bank balance", value: a.bankBalance.map(money2) ?? "—",
                       caption: a.bankBalanceAsOf.map { "PNC, as of \(shortDay($0))" } ?? "no PNC download read yet",
                       tint: a.bankBalance.map { abs($0 - a.clearedBalance) < 0.005 ? .green : .orange } ?? .secondary,
                       help: "The ledger balance in PNC's latest download. Green when it equals the cleared balance (reconciled).")
            MetricTile(title: "From the bank", value: "\(a.bankOnly)", caption: "lines not in the register",
                       tint: a.bankOnly > 0 ? .orange : .primary,
                       help: "The bank's lines no register entry matches yet: accept them into the register, or match each to its entry.")
        }
    }

    /// The register's columns for sorting and filtering, by their titles.
    static let columns: [String: LocalGridColumn<RegisterEntry>] = [
        "Line": .number({ Double($0.line) }, display: { String($0.line) }),
        "Date": .date({ $0.date }, display: { shortDay($0.date) }),
        "Num": .text { $0.checkNo ?? $0.kind },
        "Target": .text { $0.payee },
        "Payment": .number({ $0.amount < 0 ? -$0.amount : nil }, display: { $0.amount < 0 ? money2(-$0.amount) : nil }),
        "Deposit": .number({ $0.amount > 0 ? $0.amount : nil }, display: { $0.amount > 0 ? money2($0.amount) : nil }),
        "✓": .text { ["cleared": "Cleared", "reconciled": "Reconciled", "void": "Void"][$0.status] ?? "Not cleared" },
        "Balance": .number({ $0.status == "void" ? nil : $0.balance }, display: { $0.status == "void" ? nil : money2($0.balance) }),
    ]

    private func registerTable(_ r: CheckRegister) -> some View {
        let focused = focusOn ? r.entries.filter { $0.date >= focusDay } : r.entries
        let hidden = r.entries.count - focused.count
        let shown = LocalGrid.rows(focused, grid, Self.columns)
        return Box(title: "Register", symbol: "list.bullet.rectangle", help: "Every entry in the register's own order — the paper register's, line by line (Move Up / Move Down) — with the running balance in that order (over the whole register, also when earlier entries are hidden, filtered or sorted otherwise). Each column header's button sorts and filters it, as in Excel. Double-click to change one (the register is shared: a change made from an older copy is refused). Void keeps a check's number accounted for.") {
            focusBar(hidden: hidden)
            GridFilterStatus(shown: shown.count, of: focused.count, options: $grid)
            moveBar(r)
            Table(shown, selection: $selection) {
                TableColumn("Line") { e in Text("\(e.line)").monospacedDigit().foregroundStyle(.secondary) }.width(min: 36, ideal: 48)
                TableColumn("Date") { e in Text(shortDay(e.date)).monospacedDigit().help(entryHelp(e)) }.width(min: 70, ideal: 84)
                TableColumn("Num") { e in Text(e.checkNo ?? kindLabel(e.kind)).monospacedDigit().foregroundStyle(e.checkNo == nil ? .secondary : .primary) }.width(min: 40, ideal: 60)
                TableColumn("Target") { e in
                    TargetCell(entry: e, website: website(e)) { id, note in await saveNote(id, note) }
                }.width(min: 140, ideal: 190)
                TableColumn("Payment") { e in Text(e.amount < 0 ? money2(-e.amount) : "").monospacedDigit() }.width(min: 60, ideal: 90)
                TableColumn("Deposit") { e in Text(e.amount > 0 ? money2(e.amount) : "").monospacedDigit() }.width(min: 60, ideal: 90)
                TableColumn("✓") { e in statusMark(e) }.width(44)
                TableColumn("Balance") { e in Text(e.status == "void" ? "" : money2(e.balance)).monospacedDigit().foregroundStyle(e.balance < 0 ? .red : .primary) }.width(min: 70, ideal: 100)
            }
            .tableText()
            .contextMenu(forSelectionType: RegisterEntry.ID.self) { ids in
                let chosen = r.entries.filter { ids.contains($0.id) }
                if chosen.count == 1, let e = chosen.first {
                    Button("Edit Entry…") { editing = e }
                    if e.payeeId != nil { Button("Edit Note on \(e.payee ?? "the Target")…") { noteFor = e } }
                    payeeLinkMenu(PayeeLinkTarget(e, website: website(e)))
                    Divider()
                    Button("Move Up") { Task { await move(e, down: false) } }
                        .disabled(!grid.isEmpty || e.line <= 1)
                    Button("Move Down") { Task { await move(e, down: true) } }
                        .disabled(!grid.isEmpty || e.line >= r.entries.count)
                    Divider()
                    if e.status == "open" { Button("Mark Cleared") { Task { await setStatus(e, "cleared") } } }
                    if e.status == "cleared" || e.status == "reconciled" { Button("Mark Not Cleared") { Task { await setStatus(e, "open") } } }
                    if e.status != "void" { Button("Void") { Task { await setStatus(e, "void") } } } else { Button("Restore") { Task { await setStatus(e, "open") } } }
                    Divider()
                }
                if chosen.count > 1 {
                    let live = chosen.filter { $0.status != "void" }
                    let open = live.filter { $0.status == "open" }
                    Button("Mark \(open.count) Cleared") { Task { await setCleared(open, true) } }.disabled(open.isEmpty)
                    Button("Mark \(live.count - open.count) Not Cleared") { Task { await setCleared(live.filter { $0.status != "open" }, false) } }
                        .disabled(live.count == open.count)
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
                let chosen = shown.filter { selection.contains($0.id) }
                return chosen.isEmpty ? [] : [NSItemProvider(object: Self.text(chosen) as NSString)]
            }
            .columnHeaderFilters(types: LocalGrid.types(Self.columns), options: grid,
                                 loadValues: { (LocalGrid.values(focused, column: $0, grid, Self.columns), false) },
                                 apply: { grid = $0 })
            // An entry not cleared yet is shaded light yellow, as a pencilled line on the paper register, until the
            // bank clears it; cleared, reconciled and void entries keep the table's banded rows.
            .background(RowShading(marked: shown.map { $0.status == "open" }))
            .frame(minHeight: PortSettings.shared.tableHeight(rows: min(max(shown.count, 6), registerRows)))
        }
    }

    private func bankOnly(_ r: CheckRegister) -> some View {
        Box(title: "From PNC, not in the register", symbol: "building.columns", help: "Lines in the bank's downloads that no register entry matches: fees, card debits, automatic payments, or an entry written with a different amount. Accept adds the line to the register (cleared); Match… ties it to the entry it is.") {
            ForEach(r.bankOnly) { l in
                HStack(spacing: 10) {
                    Text(shortDay(l.date)).monospacedDigit().frame(width: 84, alignment: .leading)
                    Text(l.checkNo.map { "#\($0)" } ?? (l.type ?? "")).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(l.name ?? "—")
                        if let p = l.payee, p.lowercased() != (l.name ?? "").lowercased() { Text("target \(p)").font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Text(money2(l.amount)).monospacedDigit().foregroundStyle(Color.signed(l.amount))
                    Button("Accept") { Task { await run { try await BankClient.accept(l.id) } } }
                        .help("Add this line to the register as a cleared entry (its target found by the bank's name for it)")
                    Button("Match…") { matching = l }
                        .help("Tie this line to the register entry it is (an amount or date written differently)")
                }
                .font(.callout)
            }
        }
    }

    private func statusMark(_ e: RegisterEntry) -> some View {
        Group {
            switch e.status {
            case "cleared": Image(systemName: "checkmark").foregroundStyle(.green).help("Cleared: the bank shows it\(e.bankDate.map { " (\(shortDay($0)))" } ?? "")")
            case "reconciled": Image(systemName: "checkmark.seal").foregroundStyle(.green).help("Reconciled")
            case "void": Image(systemName: "xmark").foregroundStyle(.secondary).help("Void")
            default: Text("")
            }
        }
    }

    /// The day the register shows from when earlier entries are hidden (a month back until one is chosen).
    private var focusDay: String {
        focusFrom.isEmpty ? isoDay.string(from: Calendar.current.date(byAdding: .month, value: -1, to: Date())!) : focusFrom
    }

    private func focusBar(hidden: Int) -> some View {
        HStack(spacing: 8) {
            Toggle("Hide entries before", isOn: $focusOn).toggleStyle(.checkbox)
                .help("Show only the recent entries — this week's or this month's payments; the balances still count every entry")
            DatePicker("", selection: Binding(get: { isoDay.date(from: focusDay) ?? Date() },
                                              set: { focusFrom = isoDay.string(from: $0); focusOn = true }),
                       displayedComponents: .date)
                .labelsHidden().fixedSize().disabled(!focusOn)
            Menu("Recent") {
                Button("Last 7 Days") { focus(days: 7) }
                Button("Last 30 Days") { focus(days: 30) }
                Button("Last 90 Days") { focus(days: 90) }
                Button("This Month") { focus(from: Calendar.current.dateInterval(of: .month, for: Date())!.start) }
                Button("This Year") { focus(from: Calendar.current.dateInterval(of: .year, for: Date())!.start) }
                Divider()
                Button("Show All") { focusOn = false }
            }
            .menuStyle(.borderlessButton).fixedSize()
            Spacer()
            if focusOn, hidden > 0 {
                Text("\(hidden) earlier entr\(hidden == 1 ? "y" : "ies") hidden").font(.callout).foregroundStyle(.secondary)
            }
            RowsStepper(rows: $registerRows, what: "register")
        }
    }

    private func focus(days: Int) { focus(from: Calendar.current.date(byAdding: .day, value: -days, to: Date())!) }
    private func focus(from day: Date) { focusFrom = isoDay.string(from: day); focusOn = true }

    /// Saves a target's note (its hover text) and shows it in every entry with that target.
    private func saveNote(_ payee: Int, _ note: String) async -> String? {
        do {
            _ = try await BankClient.savePayeeNote(payee, note)
            await refresh()
            book = try? await BankClient.book()
            return nil
        } catch { return describe(error) }
    }

    private func kindLabel(_ k: String) -> String {
        ["debit": "DEB", "deposit": "DEP", "transfer": "XFR", "fee": "FEE", "interest": "INT"][k] ?? k.uppercased()
    }

    private func entryHelp(_ e: RegisterEntry) -> String {
        var parts = ["Entered by \(e.enteredBy ?? "—")"]
        if let u = e.updatedBy, u != e.enteredBy { parts.append("last changed by \(u)") }
        if let b = e.bankName { parts.append("PNC: \(b)") }
        return parts.joined(separator: " · ")
    }

    private func nextCheck(_ r: CheckRegister) -> String {
        let numbers = r.entries.compactMap { $0.checkNo.flatMap(Int.init) }
        return numbers.max().map { String($0 + 1) } ?? ""
    }

    static func text(_ entries: [RegisterEntry]) -> String {
        let head = ["Date", "Num", "Target", "Category", "Memo", "Payment", "Deposit", "Status", "Balance"].joined(separator: "\t")
        let lines = entries.map { e -> String in
            let pay = e.amount < 0 ? String(format: "%.2f", -e.amount) : ""
            let dep = e.amount > 0 ? String(format: "%.2f", e.amount) : ""
            let target = (e.payee ?? "") + (e.payeeLast4.map { " ···\($0)" } ?? "")
            let cells: [String] = [e.date, e.checkNo ?? e.kind, target, e.expenseAccount ?? "", e.memo ?? "", pay, dep, e.status,
                                   String(format: "%.2f", e.balance)]
            return cells.joined(separator: "\t")
        }
        return ([head] + lines).joined(separator: "\n")
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The entry's target's logon page (Target Accounts), offered as a page in the Link dialog.
    private func website(_ e: RegisterEntry) -> String? {
        e.payeeId.flatMap { id in book?.payees.first { $0.id == id }?.logonUrl }
    }

    // MARK: Loading and saving

    private func reload() async {
        busy = true
        defer { busy = false }
        do {
            accounts = try await BankClient.accounts()
            book = try? await BankClient.book()
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
            register = try await BankClient.register(selected)
            problem = nil
        } catch {
            problem = describe(error)
        }
    }

    /// Runs a change that answers with the register; a refusal (someone changed it since) reloads it and says why.
    @discardableResult
    private func run(_ change: () async throws -> CheckRegister) async -> String? {
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

    private func add() async -> String? {
        guard let code = register?.account.code else { return "Choose an account" }
        let error = await run { try await BankClient.add(code, draft.body) }
        if error == nil {
            draft = EntryDraft.newEntry(after: draft.date)
            if let r = register, draft.kind == "check", PortSettings.shared.newEntryCheckNumber == .next { draft.checkNo = nextCheck(r) }
        }
        return error
    }

    /// Above the register: Move Up and Move Down for the selected entry (⌥⌘↑ / ⌥⌘↓), so the register's order can be
    /// made the paper register's. Only in the register's own order: sorted or filtered, the neighbours aren't the lines.
    private func moveBar(_ r: CheckRegister) -> some View {
        let chosen = selection.count == 1 ? r.entries.first { selection.contains($0.id) } : nil
        let why = !grid.isEmpty ? "Clear the sort and filters to move entries: moves follow the register's own order"
            : chosen == nil ? "Select one entry to move it" : nil
        return HStack(spacing: 8) {
            Button { if let e = chosen { Task { await move(e, down: false) } } } label: { Label("Move Up", systemImage: "arrow.up") }
                .keyboardShortcut(.upArrow, modifiers: [.option, .command])
                .disabled(why != nil || (chosen?.line ?? 1) <= 1 || busy)
            Button { if let e = chosen { Task { await move(e, down: true) } } } label: { Label("Move Down", systemImage: "arrow.down") }
                .keyboardShortcut(.downArrow, modifiers: [.option, .command])
                .disabled(why != nil || (chosen?.line ?? r.entries.count) >= r.entries.count || busy)
            Text(why ?? (chosen.map { "Line \($0.line) of \(r.entries.count): ⌥⌘↑ and ⌥⌘↓ move it, to match the paper register" } ?? ""))
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            clearedToggle(r)
        }
        .controlSize(.small)
        .help("The register keeps the paper register's order, not the dates': move an entry one line at a time. Its line is kept by the application — nothing else changes it.")
    }

    /// Marks the selected entries cleared — or, when every one of them is cleared already, not cleared (⌥⌘K), as
    /// the paper register's ticks are checked off against the statement. Void entries are left as they are.
    private func clearedToggle(_ r: CheckRegister) -> some View {
        let live = r.entries.filter { selection.contains($0.id) && $0.status != "void" }
        let open = live.filter { $0.status == "open" }
        let clearing = !open.isEmpty
        let title = live.isEmpty ? "Mark Cleared" : clearing ? "Mark \(open.count) Cleared" : "Mark \(live.count) Not Cleared"
        return Button { Task { await setCleared(clearing ? open : live, clearing) } } label: {
            Label(title, systemImage: clearing || live.isEmpty ? "checkmark.circle" : "arrow.uturn.backward.circle")
        }
        .keyboardShortcut("k", modifiers: [.option, .command])
        .disabled(live.isEmpty || busy)
        .help("Select entries (⌘-click or ⇧-click for several) and mark them cleared; when they all are, this marks them not cleared again (⌥⌘K)")
    }

    private func setCleared(_ entries: [RegisterEntry], _ cleared: Bool) async {
        guard let code = register?.account.code, !entries.isEmpty else { return }
        await run { try await BankClient.setStatus(code, entries, cleared ? "cleared" : "open") }
    }

    private func move(_ e: RegisterEntry, down: Bool) async {
        await run { try await BankClient.move(e.id, down: down) }
    }

    private func setStatus(_ e: RegisterEntry, _ status: String) async {
        await run { try await BankClient.update(e.id, ["version": e.version, "status": status]) }
    }

    private func importDownloads() async {
        guard let code = register?.account.code else { return }
        busy = true
        defer { busy = false }
        do {
            let r = try await BankClient.importDownloads(code)
            register = r
            message = r.load?.message.map { "PNC downloads: \($0)" }
        } catch {
            message = describe(error)
        }
    }
}

func money2(_ x: Double) -> String { x.formatted(.currency(code: "USD")) }

/// Shades the rows of the Table it sits behind: rows marked true light yellow (a check register entry not cleared
/// yet), the others in the table's own banded colours. It sets the background of the NSTableView's row views (so the
/// band runs edge to edge and the selection still draws over it) whenever the marks change and as rows scroll in.
struct RowShading: NSViewRepresentable {
    var marked: [Bool]

    static let yellow = NSColor(name: nil) { look in
        look.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(red: 0.42, green: 0.37, blue: 0.08, alpha: 0.55)
            : NSColor(red: 1.0, green: 0.965, blue: 0.74, alpha: 1)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { let v = NSView(); context.coordinator.probe = v; return v }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.marked = marked
        DispatchQueue.main.async { context.coordinator.apply() }   // after the Table lays out its rows
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var probe: NSView?
        weak var table: NSTableView?
        var marked: [Bool] = []

        func apply() {
            if table?.window == nil { attach() }
            guard let table else { return }
            let bands = NSColor.alternatingContentBackgroundColors
            table.enumerateAvailableRowViews { rowView, row in
                let yellow = row < marked.count && marked[row]
                rowView.backgroundColor = yellow ? RowShading.yellow
                    : (table.usesAlternatingRowBackgroundColors ? bands[row % bands.count] : .clear)
            }
        }

        /// The table whose scroll view covers the middle of this view, watched as it scrolls.
        private func attach() {
            guard let probe, let root = probe.window?.contentView else { return }
            let target = probe.convert(probe.bounds, to: nil)
            let middle = CGPoint(x: target.midX, y: target.midY)
            var best: (table: NSTableView, area: CGFloat)?
            var stack = [root]
            while let view = stack.popLast() {
                if let t = view as? NSTableView, let scroll = t.enclosingScrollView {
                    let frame = scroll.convert(scroll.bounds, to: nil)
                    if frame.contains(middle), frame.width * frame.height < best?.area ?? .infinity { best = (t, frame.width * frame.height) }
                }
                stack.append(contentsOf: view.subviews)
            }
            table = best?.table
            NotificationCenter.default.removeObserver(self)
            if let clip = table?.enclosingScrollView?.contentView {
                clip.postsBoundsChangedNotifications = true
                NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: clip)
            }
        }

        @objc private func scrolled() { apply() }
    }
}

/// Above a register: its Date column's order, oldest or newest first — the register's own order or the Date
/// column sorted newest first, as the column's sort buttons would — remembered (under `key`) for next time.
struct DateOrderToggle: View {
    @Binding var options: GridQueryOptions
    @AppStorage private var newestFirst: Bool

    init(options: Binding<GridQueryOptions>, key: String) {
        _options = options
        _newestFirst = AppStorage(wrappedValue: false, key)
    }

    private static let newest = GridSort(column: "Date", ascending: false)

    var body: some View {
        Picker("Date", selection: Binding(get: { options.sort == Self.newest }, set: { newest in
            if newest { options.sort = Self.newest } else if options.sort?.column == "Date" || options.sort == nil { options.sort = nil }
            newestFirst = newest
        })) {
            Label("Oldest first", systemImage: "arrow.up").tag(false)
            Label("Newest first", systemImage: "arrow.down").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Show the register oldest first (its own order) or newest first, by date; the running balance stays each entry's place in the register")
        .onAppear { if newestFirst, options.sort == nil { options.sort = Self.newest } }
        // A sort picked from a column's header button: newest first only while it is the Date column, newest first.
        .onChange(of: options.sort) { newestFirst = options.sort == Self.newest }
    }
}

/// Above a register: how many entries its column filters show, and a button that clears its sorting and filters.
struct GridFilterStatus: View {
    var shown: Int
    var of: Int
    @Binding var options: GridQueryOptions

    var body: some View {
        if !options.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle.fill").foregroundStyle(Color.accentColor)
                Text(summary).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Clear Sort & Filters") { options = GridQueryOptions() }
                    .help("Show every entry in the register's own order")
            }
        }
    }

    private var summary: String {
        var parts: [String] = []
        if !options.filters.isEmpty {
            parts.append("\(shown) of \(of) entries · filtered by \(options.filters.keys.sorted().joined(separator: ", "))")
        }
        if let sort = options.sort { parts.append("sorted by \(sort.column) \(sort.ascending ? "ascending" : "descending")") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Entering a check

/// A new entry as Settings ▸ Banking starts it: its kind, and the date of the entry before (`previous`) or today.
extension EntryDraft {
    static func newEntry(after previous: Date? = nil) -> EntryDraft {
        var draft = EntryDraft()
        draft.kind = PortSettings.shared.newEntryKind
        if let previous, PortSettings.shared.newEntryDate == .previous { draft.date = previous }
        return draft
    }
}

struct EntryDraft {
    var date = Date()
    var kind = "check"
    var checkNo = ""
    var payee = ""
    var expenseAccountId: Int?
    var memo = ""
    var amount: Double?

    var body: [String: Any] {
        var b: [String: Any] = ["date": isoDay.string(from: date), "kind": kind, "payee": payee, "memo": memo, "amount": amount ?? 0]
        if !checkNo.isEmpty { b["checkNo"] = checkNo }
        if let expenseAccountId { b["expenseAccountId"] = expenseAccountId }
        return b
    }
}

struct EntryForm: View {
    @Binding var draft: EntryDraft
    var payees: [Payee]
    var nextCheck: String
    var save: () async -> String?
    @State private var error: String?
    @State private var saving = false
    @AppStorage(PortSettingsView.tabKey) private var settingsTab = "text"
    @Environment(\.openSettings) private var openSettings

    /// A check's number starts as the register's next one only when Settings ▸ Banking says so.
    private var fillsCheckNumber: Bool { PortSettings.shared.newEntryCheckNumber == .next }

    static let kinds = [("check", "Check"), ("debit", "Debit / card"), ("deposit", "Deposit"), ("transfer", "Transfer"),
                        ("fee", "Bank fee"), ("interest", "Interest")]

    var body: some View {
        Box(title: "New entry", symbol: "square.and.pencil", help: "Write it as on the check book's paper register: the date, the check number (or the kind of entry), its target — the target account the money goes to or comes from, picked from those the checking register pays, with its last four digits showing — and the amount. Picking a known target fills in its usual amount and files the entry under its category; Edit Entry adds a memo or changes the category.") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                DatePicker("", selection: $draft.date, displayedComponents: .date).labelsHidden().fixedSize()
                Picker("", selection: $draft.kind) {
                    ForEach(Self.kinds, id: \.0) { Text($0.1).tag($0.0) }
                }
                .labelsHidden().frame(width: 120)
                .onChange(of: draft.kind) {
                    if draft.kind != "check" { draft.checkNo = "" }
                    else if fillsCheckNumber, draft.checkNo.isEmpty { draft.checkNo = nextCheck }
                }
                if draft.kind == "check" {
                    TextField("Check #", text: $draft.checkNo).frame(width: 70)
                }
                TargetPicker(target: $draft.payee, payees: payees, prompt: draft.kind == "deposit" ? "From" : "Pay to") {
                    fillFromPayee()
                }
                TextField("Amount", value: $draft.amount, format: .number.precision(.fractionLength(2))).frame(width: 100)
                    .onSubmit { Task { await enter() } }
                Button("Enter") { Task { await enter() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(saving || (draft.amount ?? 0) == 0 || (draft.kind == "check" && draft.checkNo.isEmpty))
                    .help("Add it to the register (⌘↩)")
                Button {
                    settingsTab = "banking"
                    openSettings()
                } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("New Entry Defaults")
                    .help("What a new entry starts with — its kind, check number and date (Settings ▸ Banking)")
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
        }
        .onAppear { if fillsCheckNumber, draft.kind == "check", draft.checkNo.isEmpty { draft.checkNo = nextCheck } }
        // After an entry is added the register's next check number moves on: offer it.
        .onChange(of: nextCheck) { if fillsCheckNumber, draft.kind == "check", draft.checkNo.isEmpty { draft.checkNo = nextCheck } }
        // A new default kind applies to an entry not started yet.
        .onChange(of: PortSettings.shared.newEntryKind) {
            if draft.payee.isEmpty, draft.amount == nil { draft.kind = PortSettings.shared.newEntryKind }
        }
    }

    private func fillFromPayee() {
        guard let p = payees.first(where: { $0.name.caseInsensitiveCompare(draft.payee) == .orderedSame }) else { return }
        draft.payee = p.name
        if draft.expenseAccountId == nil { draft.expenseAccountId = p.expenseAccountId }
        if draft.amount == nil, let a = p.defaultAmount { draft.amount = a }
    }

    private func enter() async {
        fillFromPayee()
        saving = true
        error = await save()
        saving = false
    }
}

/// The entry's target: a target account picked from the list (name, bank or company, last four digits), or a new
/// name typed in; the chosen account's last four digits show beside it.
struct TargetPicker: View {
    @Binding var target: String
    var payees: [Payee]
    var prompt: String
    var label: String = ""
    var picked: () -> Void

    private var chosen: Payee? { payees.first { $0.name.caseInsensitiveCompare(target) == .orderedSame } }

    var body: some View {
        HStack(spacing: 4) {
            TextField(label, text: $target, prompt: Text(prompt)).frame(minWidth: 150)
                .onSubmit(picked)
            if let l4 = chosen?.last4 {
                Text("···\(l4)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    .help([chosen?.institution, "account ending \(l4)"].compactMap { $0 }.joined(separator: " · "))
            }
            Menu {
                ForEach(payees) { p in
                    Button(TargetPicker.title(p)) { target = p.name; picked() }
                }
            } label: { Image(systemName: "arrow.left.arrow.right.square") }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Choose the target from the Target Accounts this register pays (with each account's last four digits); a name typed here that isn't one becomes a new target account")
                .disabled(payees.isEmpty)
        }
    }

    static func title(_ p: Payee) -> String {
        var t = p.name
        if let l4 = p.last4 { t += "  ···\(l4)" }
        if let n = p.nickname, !n.isEmpty { t += "  (\(n))" } else if let i = p.institution, !i.isEmpty { t += "  (\(i))" }
        return t
    }
}

/// A register entry's target with its last four digits; its note shows on hover, and the pencil (on hover) edits it.
/// A target with a link shows its name as the link — a click opens it, the pointer resting on it shows its hover card —
/// and the link button (on hover) adds or edits it.
struct TargetCell: View {
    let entry: RegisterEntry
    /// The target's logon page (Target Accounts), offered as a page in the Link dialog.
    var website: String? = nil
    var saveNote: (Int, String) async -> String?
    @State private var hovering = false
    @State private var editing = false

    var body: some View {
        let target = PayeeLinkTarget(entry, website: website)
        HStack(spacing: 4) {
            if let target, let link = target.link {
                PayeeLinks.shared.words(target, link: link, struck: entry.status == "void", testID: "entry:\(entry.id)")
            } else {
                Text(entry.payee ?? "—").strikethrough(entry.status == "void")
            }
            Group {
                if let l4 = entry.payeeLast4 { Text("···\(l4)").foregroundStyle(.secondary).monospacedDigit() }
                if entry.payeeNote?.isEmpty == false { Image(systemName: "note.text").font(.caption).foregroundStyle(.secondary) }
            }
            // With a link, its words show the hover card; the rest of the cell keeps the note's tooltip.
            .help(target?.link == nil ? "" : hoverText)
            Spacer(minLength: 0)
            if let target, hovering || editing {
                Button { PayeeLinks.shared.beginEdit(target) } label: { Image(systemName: "link") }
                    .buttonStyle(.borderless)
                    .help(target.link == nil ? "Add a link to \(target.name): a web page, an email address or a page in MxNoteONE, with its own words and hover text"
                                             : "Edit the link on \(target.name)")
                Button { editing = true } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                    .help("Edit the note on \(entry.payee ?? "this target")")
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(target?.link == nil ? hoverText : "")
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            TargetNoteEditor(entry: entry, initial: entry.payeeNote ?? "") { note in
                guard let id = entry.payeeId else { return nil }
                return await saveNote(id, note)
            }
        }
    }

    private var subtitle: String? { TargetNoteEditor.subtitle(entry) }

    private var hoverText: String {
        var lines: [String] = []
        if let sub = subtitle { lines.append(sub) }
        if let next = TargetNoteEditor.nextPayment(entry) { lines.append(next) }
        if let n = entry.payeeNote, !n.isEmpty { lines.append(n) }
        if entry.payeeId != nil { lines.append(lines.isEmpty ? "No note yet: the pencil (or the row's context menu) adds one" : "(the pencil or the row's context menu edits the note)") }
        return lines.joined(separator: "\n")
    }
}

/// Edits the note on a register entry's target (the target account): the hover text every entry with it shows.
struct TargetNoteEditor: View {
    let entry: RegisterEntry
    @State var initial: String
    var save: (String) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    static func subtitle(_ entry: RegisterEntry) -> String? {
        let parts = [entry.payeeNickname, entry.payeeInstitution, entry.payeeLast4.map { "account ending \($0)" }].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The target account's next payment, when one is set.
    static func nextPayment(_ entry: RegisterEntry) -> String? {
        guard entry.payeeNextDate != nil || entry.payeeNextAmount != nil else { return nil }
        return "Next payment: " + [entry.payeeNextDate.map(shortDay), entry.payeeNextAmount.map(money2)].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.payee ?? "").heading(.name)
            if let sub = Self.subtitle(entry) { Text(sub).font(.caption).foregroundStyle(.secondary) }
            TextEditor(text: $initial).font(.body).frame(width: 300, height: 90)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
            Text("Where the money flows: shown on hover for every entry with this target.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    Task {
                        error = await save(initial)
                        if error == nil { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
    }
}

struct EditEntrySheet: View {
    let entry: RegisterEntry
    var payees: [Payee]
    var expenseAccounts: [ExpenseAccount]
    var save: ([String: Any]) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var draft = EntryDraft()
    @State private var status = "open"
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Entry").heading(.heading)
            Text("Entered by \(entry.enteredBy ?? "—")\(entry.updatedBy.map { " · last changed by \($0)" } ?? "") · version \(entry.version)")
                .font(.caption).foregroundStyle(.secondary)
            Form {
                DatePicker("Date", selection: $draft.date, displayedComponents: .date)
                Picker("Kind", selection: $draft.kind) { ForEach(EntryForm.kinds, id: \.0) { Text($0.1).tag($0.0) } }
                if draft.kind == "check" { TextField("Check #", text: $draft.checkNo) }
                TargetPicker(target: $draft.payee, payees: payees, prompt: draft.kind == "deposit" ? "From" : "Pay to", label: "Target") {}
                Picker("Category", selection: $draft.expenseAccountId) {
                    Text("None").tag(Int?.none)
                    ForEach(expenseAccounts) { Text($0.name).tag(Optional($0.id)) }
                }
                TextField("Memo", text: $draft.memo)
                TextField("Amount", value: $draft.amount, format: .number.precision(.fractionLength(2)))
                Picker("Status", selection: $status) {
                    Text("Not cleared").tag("open"); Text("Cleared").tag("cleared"); Text("Reconciled").tag("reconciled"); Text("Void").tag("void")
                }
            }
            if let b = entry.bankName {
                Label("Matched to PNC's line \"\(b)\" of \(shortDay(entry.bankDate)). Marking it not cleared or void unmatches it.", systemImage: "building.columns")
                    .font(.callout).foregroundStyle(.secondary)
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
                        if let e = await save(body) { error = e } else { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 460)
        .onAppear {
            draft.date = isoDay.date(from: entry.date) ?? Date()
            draft.kind = entry.kind
            draft.checkNo = entry.checkNo ?? ""
            draft.payee = entry.payee ?? ""
            draft.expenseAccountId = entry.expenseAccountId
            draft.memo = entry.memo ?? ""
            draft.amount = abs(entry.amount)
            status = entry.status
        }
    }
}

struct AccountSheet: View {
    let account: BankAccount?
    var save: (String, [String: Any]) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var name = ""
    @State private var institution = "PNC"
    @State private var last4 = ""
    @State private var openingDate = Date()
    @State private var openingBalance = 0.0
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(account == nil ? "New Checking Account" : "Edit \(account!.name)").heading(.heading)
            Form {
                TextField("Code", text: $code).disabled(account != nil)
                    .help("A short name for it: letters, digits, _ or - (PNC_CHECKING)")
                TextField("Name", text: $name)
                TextField("Bank", text: $institution)
                TextField("Last four digits", text: $last4)
                    .help("How PNC's downloads name the account. Never the whole account number.")
                DatePicker("Register starts", selection: $openingDate, displayedComponents: .date)
                TextField("Balance then", value: $openingBalance, format: .number.precision(.fractionLength(2)))
            }
            Text("The register starts on that day with that balance: entries and bank lines before it are left out of the balances.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(account == nil ? "Add" : "Save") {
                    Task {
                        let body: [String: Any] = ["name": name, "institution": institution, "last4": last4,
                                                   "openingDate": isoDay.string(from: openingDate), "openingBalance": openingBalance]
                        if let e = await save(code, body) { error = e } else { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(code.isEmpty || name.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 420)
        .onAppear {
            guard let a = account else { code = "PNC_CHECKING"; name = "PNC Checking"; return }
            code = a.code; name = a.name; institution = a.institution; last4 = a.last4 ?? ""
            openingDate = isoDay.date(from: a.openingDate) ?? Date(); openingBalance = a.openingBalance
        }
    }
}

struct MatchSheet: View {
    let line: BankLine
    var entries: [RegisterEntry]
    var match: (Int) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var choice: Int?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Match PNC's Line").heading(.heading)
            Text("\(shortDay(line.date)) · \(line.name ?? "—") · \(money2(line.amount))").foregroundStyle(.secondary)
            Text("The register entry it is (entries not cleared yet, closest amount first):").font(.callout)
            List(selection: $choice) {
                ForEach(entries.sorted { abs($0.amount - line.amount) < abs($1.amount - line.amount) }) { e in
                    HStack {
                        Text(shortDay(e.date)).monospacedDigit().frame(width: 84, alignment: .leading)
                        Text(e.checkNo ?? e.kind).frame(width: 60, alignment: .leading).foregroundStyle(.secondary)
                        Text(e.payee ?? "—")
                        Spacer()
                        Text(money2(e.amount)).monospacedDigit()
                    }
                    .tag(e.id)
                }
            }
            .frame(height: 220)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Match") {
                    Task { if let c = choice { if let e = await match(c) { error = e } else { dismiss() } } }
                }
                .keyboardShortcut(.defaultAction).disabled(choice == nil)
            }
        }
        .padding(18)
        .frame(width: 520)
    }
}

// MARK: - Target Accounts

struct TargetAccountsView: View {
    @Bindable var store: PortStore
    @State private var book: ExpenseBook?
    @State private var problem: String?
    @State private var adding = false
    /// Add from Card Registers… is open.
    @State private var addingFromCards = false
    /// The table's Excel-style sorting and column filters (the header buttons).
    @State private var grid = GridQueryOptions()
    /// Edit Target Details or Edit Target Account Name (a row's context menu) is open for this account.
    @State private var details: Payee?
    @State private var renaming: Payee?
    @State private var newAccount = false
    @State private var showInactive = false
    /// How many of the table's rows show at once.
    @AppStorage(RowsStepper.key) private var tableRows = RowsStepper.standard
    /// The table's rows are read-only: their context menu edits the account's details and its link.
    @State private var selected: Payee.ID?

    var body: some View {
        StepPage(store: store, subtitle: "Where the registers' money goes to or comes from — a utility, a card, a brokerage, a person: their targets, not books MxAcctMGR keeps.", lesson: [
            "Each target account has its bank or company and its last four digits, so picking a register entry's target shows which account the money went to — and a note, shown on hover in the register and edited there. Its funding sources say which registers offer it: recipients of checking account payments, of credit card payments, or both.",
            "Each is in a category (Utilities, Insurance, Housing …): the registers file every entry under its target's category, so a year's spending adds up by category. Its usual amount fills in the register; its next payment, nickname, identifier, logon and address are kept with it (New Target Account…). Its password and user keys stay in this Mac's Keychain, never in the security master.",
            "PNC's downloads name them their own way (\"DUKE ENERGY PAYMENT\"): accepting a bank line under a target account remembers that name, so the next one is filed to it.",
        ]) {
            if let problem { Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
            if let book { payeesTable(book) }
        }
        .task { await load() }
        // A link changed (here or on a register's target): the table shows it.
        .onChange(of: PayeeLinks.shared.version) { Task { await load() } }
        #if DEBUG
        // Self-tests, once the list is loaded: open New Target Account (-targetAccountNew YES), Add from Card Registers
        // (-targetAccountsFromCards YES), or a row's Edit Target
        // Details (-targetDetailsEdit PAYEE_ID) or Edit Target Account Name (-targetNameEdit PAYEE_ID).
        .task(id: book == nil) {
            guard let book else { return }
            let defaults = UserDefaults.standard
            if defaults.bool(forKey: "targetAccountNew") { adding = true }
            if defaults.bool(forKey: "targetAccountsFromCards") { addingFromCards = true }
            if defaults.object(forKey: "targetDetailsEdit") != nil {
                details = book.payees.first { $0.id == defaults.integer(forKey: "targetDetailsEdit") }
            }
            if defaults.object(forKey: "targetNameEdit") != nil {
                renaming = book.payees.first { $0.id == defaults.integer(forKey: "targetNameEdit") }
            }
        }
        #endif
        .sheet(isPresented: $adding) {
            TargetAccountSheet(payee: nil, expenseAccounts: book?.expenseAccounts ?? []) { body in await saveNew(body) }
        }
        .sheet(isPresented: $addingFromCards) {
            AddCardTargetsSheet { await load() }
        }
        .sheet(item: $details) { p in
            TargetAccountSheet(payee: p, expenseAccounts: book?.expenseAccounts ?? [], detailsOnly: true) { body in await saveDetails(p.id, body) }
        }
        .sheet(item: $renaming) { p in
            TargetNameSheet(payee: p, names: book?.payees.map(\.name) ?? []) { name in
                await saveDetails(p.id, ["version": p.version, "name": name]).error
            }
        }
        .sheet(isPresented: $newAccount) {
            ExpenseAccountSheet { body in
                do { book = try await BankClient.saveExpenseAccount(0, body); return nil } catch { return describe(error) }
            }
        }
    }

    /// The table's columns for sorting and filtering, by their titles.
    static func columns(_ categories: [Int: String]) -> [String: LocalGridColumn<Payee>] {
        [
            "Target account": .text { $0.name },
            "Category": .text { p in p.expenseAccountId.flatMap { categories[$0] } },
            "Funding": .text { p in
                let sources = FundingSource.allCases.filter { p.fundingSources.contains($0.rawValue) }
                return sources.isEmpty ? "None" : sources.map { $0 == .checking ? "Checking" : "Credit card" }.joined(separator: ", ")
            },
            "This year": .number({ $0.yearTotal == 0 ? nil : abs($0.yearTotal) }, display: { $0.yearTotal == 0 ? nil : money2(abs($0.yearTotal)) }),
            "Total paid": .number({ p in p.totalPaid.flatMap { $0 == 0 ? nil : abs($0) } },
                                  display: { p in p.totalPaid.flatMap { $0 == 0 ? nil : money2(abs($0)) } }),
            "Last paid": .date({ $0.lastPaid }, display: { $0.lastPaid.map(shortDay) }),
        ]
    }

    private func payeesTable(_ b: ExpenseBook) -> some View {
        let names = Dictionary(uniqueKeysWithValues: b.expenseAccounts.map { ($0.id, $0.name) })
        let columns = Self.columns(names)
        let listed = b.payees.filter { $0.active || showInactive }
        let shown = LocalGrid.rows(listed, grid, columns)
        return Box(title: "Target accounts", symbol: "arrow.left.arrow.right.square", help: "Where the money goes to or comes from: its category, the registers that pay it (Funding: checking, credit card), this year's payments, every payment in all years (Total paid) and the last one. Each column header's button sorts and filters it, as in Excel. Right-click a row (anywhere on it) for Edit Target Account Name… (names are unique), Edit Target Details… — nickname, status, identifier, next payment, logon, notes, address, funding sources — and its link. This year and Last paid are calculated from the registers.") {
            HStack {
                Button("New Target Account…") { adding = true }
                Button("Add from Card Registers…") { addingFromCards = true }
                    .help("Make the credit card entries' targets (as the card company names them) target accounts the card registers offer")
                Button("New Category…") { newAccount = true }
                    .help("A category the registers file entries under (Utilities, Insurance …): each target account is in one")
                Toggle("Show inactive and closed", isOn: $showInactive).toggleStyle(.checkbox)
                Spacer()
                Text("Paid in \(String(b.year)): \(money2(shown.reduce(0) { $0 + max(0, $1.yearTotal) }))").monospacedDigit().foregroundStyle(.secondary)
                RowsStepper(rows: $tableRows)
            }
            GridFilterStatus(shown: shown.count, of: listed.count, options: $grid)
            Table(shown, selection: $selected) {
                TableColumn("Target account") { p in
                    HStack(spacing: 4) {
                        if let link = p.link?.link {
                            PayeeLinks.shared.words(PayeeLinkTarget(p), link: link, testID: "payee:\(p.id)")
                        } else {
                            Text(p.name).foregroundStyle(p.active ? .primary : .secondary).help(p.notes ?? "")
                        }
                        if p.status != "active" { Text(p.status).font(.caption).foregroundStyle(.secondary) }
                    }
                }.width(min: 100)
                TableColumn("Category") { p in Text(p.expenseAccountId.flatMap { names[$0] } ?? "—").foregroundStyle(.secondary) }.width(min: 70, ideal: 110)
                TableColumn("Funding") { p in FundingMarks(sources: p.fundingSources) }.width(min: 44, ideal: 56)
                // The registers' own sums.
                TableColumn("This year") { p in
                    Text(p.yearTotal == 0 ? "" : money2(abs(p.yearTotal))).monospacedDigit().foregroundStyle(p.yearTotal < 0 ? .green : .primary)
                        .help("Calculated by MxAcctMGR from this year's check, card and expense entries with this target")
                }.width(min: 60, ideal: 84)
                TableColumn("Total paid") { p in
                    let total = p.totalPaid ?? 0
                    Text(total == 0 ? "" : money2(abs(total))).monospacedDigit().foregroundStyle(total < 0 ? .green : .primary)
                        .help("Every check, card and expense entry with this target, in all years (green: money that came in)")
                }.width(min: 70, ideal: 90)
                TableColumn("Last paid") { p in
                    Text(shortDay(p.lastPaid)).monospacedDigit().foregroundStyle(.secondary)
                        .help("The latest entry with this target, from the registers")
                }.width(min: 60, ideal: 80)
            }
            .tableText()
            // One menu on the whole row: its words aren't selectable text, so a right-click on them doesn't bring up
            // the text menu (Edit commands, Services) instead.
            .textSelection(.disabled)
            // Each column header's button sorts and filters it, as in Excel.
            .columnHeaderFilters(types: LocalGrid.types(columns), options: grid,
                                 loadValues: { (LocalGrid.values(listed, column: $0, grid, columns), false) },
                                 apply: { grid = $0 })
            .contextMenu(forSelectionType: Payee.ID.self) { ids in
                if ids.count == 1, let p = b.payees.first(where: { ids.contains($0.id) }) {
                    Button("Edit Target Account Name…") { renaming = p }
                    Button("Edit Target Details…") { details = p }
                    Divider()
                    payeeLinkMenu(PayeeLinkTarget(p))
                }
            }
            .frame(minHeight: PortSettings.shared.tableHeight(rows: min(max(shown.count, 6), tableRows)))
        }
    }

    private func load() async {
        do { book = try await BankClient.book(); problem = nil } catch { problem = describe(error) }
    }

    /// Saves Edit Target Details; answers the account's id, or why it couldn't.
    private func saveDetails(_ id: Int, _ body: [String: Any]) async -> PayeeSaved {
        do { book = try await BankClient.savePayee(id, body); return PayeeSaved(id: id) } catch {
            await load()
            return PayeeSaved(error: describe(error))
        }
    }

    /// Adds the New Target Account editor's account; answers its id, or why it couldn't.
    private func saveNew(_ body: [String: Any]) async -> PayeeSaved {
        do { book = try await BankClient.savePayee(0, body) } catch {
            await load()
            return PayeeSaved(error: describe(error))
        }
        let name = (body["name"] as? String ?? "").lowercased()
        return PayeeSaved(id: book?.payees.first { $0.name.lowercased() == name }?.id)
    }
}

/// The registers a target account's funding sources name, as marks.
struct FundingMarks: View {
    var sources: [String]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(FundingSource.allCases, id: \.self) { f in
                Image(systemName: f.symbol).foregroundStyle(sources.contains(f.rawValue) ? Color.accentColor : Color.secondary.opacity(0.25))
                    .help(sources.contains(f.rawValue) ? "\(f.title): offered in the \(f.register)" : "Not \(f.title.lowercased())")
            }
        }
        .font(.caption)
    }
}

struct ExpenseAccountSheet: View {
    var save: ([String: Any]) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind = "expense"
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Category").heading(.heading)
            Form {
                TextField("Name", text: $name)
                Picker("Kind", selection: $kind) { Text("Expense").tag("expense"); Text("Income").tag("income"); Text("Transfer").tag("transfer") }
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { Task { if let e = await save(["name": name, "kind": kind]) { error = e } else { dismiss() } } }
                    .keyboardShortcut(.defaultAction).disabled(name.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 360)
    }
}
