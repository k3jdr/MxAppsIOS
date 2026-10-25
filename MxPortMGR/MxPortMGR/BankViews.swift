//
//  BankViews.swift
//  MxPortMGR
//
//  Banking ▸ Checking Accounts: the paper check book register, kept in the security master so everyone who writes
//  checks on the account enters them in one register (accounts service /bank, V027). The bank's side comes from its
//  downloads (PNC Online Banking QFX / CSV, srm.py load pnc-bank): its lines are matched to the entries — same amount
//  and check number, or same amount within a week — and mark them cleared; the lines left over are the bank's entries
//  the register doesn't have yet, to accept or match.
//
//  Banking ▸ External Accounts: where the money goes to or comes from — a utility, a card, a brokerage, a person —
//  each with its bank or company, last four digits, category (an expense account: Utilities, Insurance …), usual
//  amount and a note. They are the register's targets, not books MxPortMGR keeps: a new entry's target is picked with
//  its last four digits showing, and the register shows the target's note on hover and edits it in place.
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

struct Payee: Decodable, Identifiable, Hashable {
    var id: Int
    var name: String
    var expenseAccountId: Int?
    var defaultAmount: Double?
    var address: String?
    var reference: String?
    var phone: String?
    var website: String?
    var bankNames: [String]
    var notes: String?
    var active: Bool
    var version: Int
    var institution: String?
    var last4: String?
    var yearTotal: Double
    var lastPaid: String?
}

struct ExpenseBook: Decodable {
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
    @State private var draft = EntryDraft()
    @State private var noteFor: RegisterEntry?
    /// Show only entries on or after a date (yyyy-MM-dd), to focus on this week's or this month's payments.
    @AppStorage("registerFocusOn") private var focusOn = false
    @AppStorage("registerFocusFrom") private var focusFrom = ""

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
                EntryForm(draft: $draft, payees: activePayees, expenseAccounts: book?.expenseAccounts ?? [], nextCheck: nextCheck(r)) {
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

    private var activePayees: [Payee] { (book?.payees ?? []).filter(\.active) }

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

    private func registerTable(_ r: CheckRegister) -> some View {
        let shown = focusOn ? r.entries.filter { $0.date >= focusDay } : r.entries
        let hidden = r.entries.count - shown.count
        return Box(title: "Register", symbol: "list.bullet.rectangle", help: "Every entry, oldest first, with the running balance (over the whole register, also when earlier entries are hidden). Double-click to change one (the register is shared: a change made from an older copy is refused). Void keeps a check's number accounted for.") {
            focusBar(hidden: hidden)
            Table(shown, selection: $selection) {
                TableColumn("Date") { e in Text(shortDay(e.date)).monospacedDigit().help(entryHelp(e)) }.width(min: 70, ideal: 84)
                TableColumn("Num") { e in Text(e.checkNo ?? kindLabel(e.kind)).monospacedDigit().foregroundStyle(e.checkNo == nil ? .secondary : .primary) }.width(min: 40, ideal: 60)
                TableColumn("Target") { e in
                    TargetCell(entry: e) { id, note in await saveNote(id, note) }
                }.width(min: 140, ideal: 190)
                TableColumn("Category") { e in Text(e.expenseAccount ?? "").foregroundStyle(.secondary) }.width(min: 80, ideal: 120)
                TableColumn("Memo") { e in Text(e.memo ?? "").foregroundStyle(.secondary) }.width(min: 60, ideal: 110)
                TableColumn("Payment") { e in Text(e.amount < 0 ? money2(-e.amount) : "").monospacedDigit() }.width(min: 60, ideal: 90)
                TableColumn("Deposit") { e in Text(e.amount > 0 ? money2(e.amount) : "").monospacedDigit() }.width(min: 60, ideal: 90)
                TableColumn("✓") { e in statusMark(e) }.width(28)
                TableColumn("Balance") { e in Text(e.status == "void" ? "" : money2(e.balance)).monospacedDigit().foregroundStyle(e.balance < 0 ? .red : .primary) }.width(min: 70, ideal: 100)
            }
            .contextMenu(forSelectionType: RegisterEntry.ID.self) { ids in
                let chosen = r.entries.filter { ids.contains($0.id) }
                if chosen.count == 1, let e = chosen.first {
                    Button("Edit Entry…") { editing = e }
                    if e.payeeId != nil { Button("Edit Note on \(e.payee ?? "the Target")…") { noteFor = e } }
                    Divider()
                    if e.status == "open" { Button("Mark Cleared") { Task { await setStatus(e, "cleared") } } }
                    if e.status == "cleared" || e.status == "reconciled" { Button("Mark Not Cleared") { Task { await setStatus(e, "open") } } }
                    if e.status != "void" { Button("Void") { Task { await setStatus(e, "void") } } } else { Button("Restore") { Task { await setStatus(e, "open") } } }
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
                let chosen = r.entries.filter { selection.contains($0.id) }
                return chosen.isEmpty ? [] : [NSItemProvider(object: Self.text(chosen) as NSString)]
            }
            .frame(minHeight: CGFloat(min(max(shown.count, 6), 22)) * 24 + 30)
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
            let keep = draft.date
            draft = EntryDraft()
            draft.date = keep
            if let r = register { draft.checkNo = nextCheck(r) }
        }
        return error
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

// MARK: - Entering a check

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
    var expenseAccounts: [ExpenseAccount]
    var nextCheck: String
    var save: () async -> String?
    @State private var error: String?
    @State private var saving = false

    static let kinds = [("check", "Check"), ("debit", "Debit / card"), ("deposit", "Deposit"), ("transfer", "Transfer"),
                        ("fee", "Bank fee"), ("interest", "Interest")]

    var body: some View {
        Box(title: "New entry", symbol: "square.and.pencil", help: "Write it as on the check book's paper register: the date, the check number (or the kind of entry), its target — the external account the money goes to or comes from, picked with its last four digits showing — what it is for and the amount. Picking a known target fills in its category and usual amount.") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                DatePicker("", selection: $draft.date, displayedComponents: .date).labelsHidden().fixedSize()
                Picker("", selection: $draft.kind) {
                    ForEach(Self.kinds, id: \.0) { Text($0.1).tag($0.0) }
                }
                .labelsHidden().frame(width: 120)
                .onChange(of: draft.kind) { if draft.kind == "check", draft.checkNo.isEmpty { draft.checkNo = nextCheck } }
                if draft.kind == "check" {
                    TextField("Check #", text: $draft.checkNo).frame(width: 70)
                }
                TargetPicker(target: $draft.payee, payees: payees, prompt: draft.kind == "deposit" ? "From" : "Pay to") {
                    fillFromPayee()
                }
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
                    .disabled(saving || (draft.amount ?? 0) == 0 || (draft.kind == "check" && draft.checkNo.isEmpty))
                    .help("Add it to the register (⌘↩)")
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
        }
        .onAppear { if draft.kind == "check", draft.checkNo.isEmpty { draft.checkNo = nextCheck } }
        // After an entry is added the register's next check number moves on: offer it.
        .onChange(of: nextCheck) { if draft.kind == "check", draft.checkNo.isEmpty { draft.checkNo = nextCheck } }
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

/// The entry's target: an external account picked from the list (name, bank or company, last four digits), or a new
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
                .help("Choose the target from External Accounts (with each account's last four digits)")
                .disabled(payees.isEmpty)
        }
    }

    static func title(_ p: Payee) -> String {
        var t = p.name
        if let l4 = p.last4 { t += "  ···\(l4)" }
        if let i = p.institution, !i.isEmpty { t += "  (\(i))" }
        return t
    }
}

/// A register entry's target with its last four digits; its note shows on hover, and the pencil (on hover) edits it.
struct TargetCell: View {
    let entry: RegisterEntry
    var saveNote: (Int, String) async -> String?
    @State private var hovering = false
    @State private var editing = false

    var body: some View {
        HStack(spacing: 4) {
            Text(entry.payee ?? "—").strikethrough(entry.status == "void")
            if let l4 = entry.payeeLast4 { Text("···\(l4)").foregroundStyle(.secondary).monospacedDigit() }
            if entry.payeeNote?.isEmpty == false { Image(systemName: "note.text").font(.caption).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
            if entry.payeeId != nil, hovering || editing {
                Button { editing = true } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                    .help("Edit the note on \(entry.payee ?? "this target")")
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(hoverText)
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
        if let n = entry.payeeNote, !n.isEmpty { lines.append(n) }
        if entry.payeeId != nil { lines.append(lines.isEmpty ? "No note yet: the pencil (or the row's context menu) adds one" : "(the pencil or the row's context menu edits the note)") }
        return lines.joined(separator: "\n")
    }
}

/// Edits the note on a register entry's target (the external account): the hover text every entry with it shows.
struct TargetNoteEditor: View {
    let entry: RegisterEntry
    @State var initial: String
    var save: (String) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    static func subtitle(_ entry: RegisterEntry) -> String? {
        let parts = [entry.payeeInstitution, entry.payeeLast4.map { "account ending \($0)" }].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.payee ?? "").font(.headline)
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
            Text("Edit Entry").font(.title2.weight(.semibold))
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
            Text(account == nil ? "New Checking Account" : "Edit \(account!.name)").font(.title2.weight(.semibold))
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
            Text("Match PNC's Line").font(.title2.weight(.semibold))
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

// MARK: - External Accounts

struct ExternalAccountsView: View {
    @Bindable var store: PortStore
    @State private var book: ExpenseBook?
    @State private var problem: String?
    @State private var account: Int?           // nil: every external account
    @State private var editing: Payee?
    @State private var adding = false
    @State private var newAccount = false
    @State private var showInactive = false

    var body: some View {
        StepPage(store: store, subtitle: "Where the checking account's money goes to or comes from — a utility, a card, a brokerage, a person: the register's targets, not books MxPortMGR keeps.", lesson: [
            "Each external account has its bank or company and its last four digits, so picking a register entry's target shows which account the money went to — and a note, shown on hover in the register and edited there.",
            "Each is in a category (Utilities, Insurance, Housing …): the register files every entry under its target's category, so a year's spending adds up by category. Its usual amount fills in the register too.",
            "PNC's downloads name them their own way (\"DUKE ENERGY PAYMENT\"): accepting a bank line under an external account remembers that name, so the next one is filed to it.",
        ]) {
            if let problem { Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
            if let book {
                HStack(alignment: .top, spacing: 14) {
                    accountsList(book).frame(width: 260)
                    payeesTable(book)
                }
            }
        }
        .task { await load() }
        .sheet(item: $editing) { p in
            PayeeSheet(payee: p, expenseAccounts: book?.expenseAccounts ?? []) { body in await save(p.id, body) }
        }
        .sheet(isPresented: $adding) {
            PayeeSheet(payee: nil, expenseAccounts: book?.expenseAccounts ?? [], defaultAccount: account) { body in await save(0, body) }
        }
        .sheet(isPresented: $newAccount) {
            ExpenseAccountSheet { body in
                do { book = try await BankClient.saveExpenseAccount(0, body); return nil } catch { return describe(error) }
            }
        }
    }

    private func accountsList(_ b: ExpenseBook) -> some View {
        Box(title: "Categories", symbol: "tray.2", help: "What the register's money is for. Choose one to see its external accounts; the totals are this year's register entries.") {
            VStack(alignment: .leading, spacing: 2) {
                row(nil, "All external accounts", "\(b.payees.filter { $0.active || showInactive }.count)", total: nil)
                ForEach(["expense", "income", "transfer"], id: \.self) { kind in
                    let accts = b.expenseAccounts.filter { $0.kind == kind }
                    if !accts.isEmpty {
                        Text(kind == "expense" ? "Expenses" : kind == "income" ? "Income" : "Transfers")
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                        ForEach(accts) { a in
                            row(a.id, a.name, "\(b.payees.filter { $0.expenseAccountId == a.id && ($0.active || showInactive) }.count)",
                                total: kind == "income" ? -a.yearTotal : a.yearTotal)
                        }
                    }
                }
                Button("New Category…") { newAccount = true }.buttonStyle(.link).padding(.top, 6)
            }
        }
    }

    private func row(_ id: Int?, _ name: String, _ count: String, total: Double?) -> some View {
        Button { account = id } label: {
            HStack {
                Text(name)
                Spacer()
                if let total, total != 0 { Text(money2(total)).monospacedDigit().foregroundStyle(.secondary) }
                Text(count).font(.caption).foregroundStyle(.secondary).frame(minWidth: 20, alignment: .trailing)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(account == id ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .plainButton()
    }

    private func payeesTable(_ b: ExpenseBook) -> some View {
        let names = Dictionary(uniqueKeysWithValues: b.expenseAccounts.map { ($0.id, $0.name) })
        let shown = b.payees.filter { (account == nil || $0.expenseAccountId == account) && ($0.active || showInactive) }
        return Box(title: account.flatMap { names[$0] } ?? "All external accounts", symbol: "arrow.left.arrow.right.square", help: "Where the money goes to or comes from, with this year's payments and the last one. Double-click to edit one.") {
            HStack {
                Button("New External Account…") { adding = true }
                Toggle("Show inactive", isOn: $showInactive).toggleStyle(.checkbox)
                Spacer()
                Text("Paid in \(String(b.year)): \(money2(shown.reduce(0) { $0 + max(0, $1.yearTotal) }))").monospacedDigit().foregroundStyle(.secondary)
            }
            Table(shown) {
                TableColumn("External account") { p in
                    Text(p.name).foregroundStyle(p.active ? .primary : .secondary).help(p.notes ?? "")
                }.width(min: 100)
                TableColumn("Bank / company") { p in Text(p.institution ?? "").foregroundStyle(.secondary) }.width(min: 60, ideal: 100)
                TableColumn("Last 4") { p in Text(p.last4.map { "···\($0)" } ?? "").monospacedDigit().foregroundStyle(.secondary) }.width(min: 44, ideal: 56)
                TableColumn("Category") { p in Text(p.expenseAccountId.flatMap { names[$0] } ?? "—").foregroundStyle(.secondary) }.width(min: 70, ideal: 110)
                TableColumn("Usual") { p in Text(p.defaultAmount.map(money2) ?? "").monospacedDigit() }.width(min: 50, ideal: 70)
                TableColumn("This year") { p in Text(p.yearTotal == 0 ? "" : money2(abs(p.yearTotal))).monospacedDigit().foregroundStyle(p.yearTotal < 0 ? .green : .primary) }.width(min: 60, ideal: 84)
                TableColumn("Last paid") { p in Text(shortDay(p.lastPaid)).monospacedDigit().foregroundStyle(.secondary) }.width(min: 60, ideal: 80)
            }
            .contextMenu(forSelectionType: Payee.ID.self) { ids in
                if ids.count == 1, let p = b.payees.first(where: { ids.contains($0.id) }) {
                    Button("Edit External Account…") { editing = p }
                }
            } primaryAction: { ids in
                if ids.count == 1, let p = b.payees.first(where: { ids.contains($0.id) }) { editing = p }
            }
            .frame(minHeight: CGFloat(min(max(shown.count, 6), 22)) * 24 + 30)
        }
    }

    private func load() async {
        do { book = try await BankClient.book(); problem = nil } catch { problem = describe(error) }
    }

    private func save(_ id: Int, _ body: [String: Any]) async -> String? {
        do { book = try await BankClient.savePayee(id, body); return nil } catch {
            await load()
            return describe(error)
        }
    }
}

struct PayeeSheet: View {
    let payee: Payee?
    var expenseAccounts: [ExpenseAccount]
    var defaultAccount: Int? = nil
    var save: ([String: Any]) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var expenseAccountId: Int?
    @State private var defaultAmount: Double?
    @State private var address = ""
    @State private var reference = ""
    @State private var phone = ""
    @State private var website = ""
    @State private var bankNames = ""
    @State private var notes = ""
    @State private var institution = ""
    @State private var last4 = ""
    @State private var active = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(payee == nil ? "New External Account" : "Edit \(payee!.name)").font(.title2.weight(.semibold))
            Form {
                TextField("Name", text: $name)
                TextField("Bank / company", text: $institution)
                TextField("Last four digits", text: $last4)
                    .help("Shown when this is picked as a register entry's target. Never the whole account number.")
                Picker("Category", selection: $expenseAccountId) {
                    Text("None").tag(Int?.none)
                    ForEach(expenseAccounts) { Text($0.name).tag(Optional($0.id)) }
                }
                TextField("Usual amount", value: $defaultAmount, format: .number.precision(.fractionLength(2)))
                TextField("Reference (your account with them)", text: $reference)
                TextField("Address", text: $address, axis: .vertical).lineLimit(2...4)
                TextField("Phone", text: $phone)
                TextField("Website", text: $website)
                TextField("Bank's names for it", text: $bankNames)
                    .help("How PNC's downloads name this account, separated by semicolons: accepting a bank line remembers these")
                TextField("Note (shown on hover in the register)", text: $notes, axis: .vertical).lineLimit(1...4)
                Toggle("Active", isOn: $active)
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(payee == nil ? "Add" : "Save") {
                    Task {
                        var body: [String: Any] = ["name": name, "address": address, "reference": reference, "phone": phone,
                                                   "website": website, "notes": notes, "active": active,
                                                   "institution": institution, "last4": last4,
                                                   "bankNames": bankNames.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }]
                        body["expenseAccountId"] = expenseAccountId ?? NSNull()
                        body["defaultAmount"] = defaultAmount ?? NSNull()
                        if let payee { body["version"] = payee.version }
                        if let e = await save(body) { error = e } else { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction).disabled(name.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 460)
        .onAppear {
            guard let p = payee else { expenseAccountId = defaultAccount; return }
            name = p.name; expenseAccountId = p.expenseAccountId; defaultAmount = p.defaultAmount
            address = p.address ?? ""; reference = p.reference ?? ""; phone = p.phone ?? ""; website = p.website ?? ""
            bankNames = p.bankNames.joined(separator: "; "); notes = p.notes ?? ""; active = p.active
            institution = p.institution ?? ""; last4 = p.last4 ?? ""
        }
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
            Text("New Category").font(.title2.weight(.semibold))
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
