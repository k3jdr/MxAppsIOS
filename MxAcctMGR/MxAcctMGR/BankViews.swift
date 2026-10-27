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
//  Each entry names who it paid (or was paid by) in its own words, as the bank's downloads do: there are no target
//  accounts (V048). A new entry's expense account is the one the latest entry paid to the same name has, unless picked.
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
    var payee: String?
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
}

struct BankLine: Decodable, Identifiable, Hashable {
    var id: Int
    var date: String
    var amount: Double
    var type: String?
    var checkNo: String?
    var name: String?
    var memo: String?
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

struct ExpenseBook: Decodable {
    /// The expense account just saved (PUT /expense-accounts/<id>).
    var id: Int?
    var year: Int
    var expenseAccounts: [ExpenseAccount]
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
                EntryForm(draft: $draft, known: knownPayees(r), nextCheck: nextCheck(r)) {
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
            EditEntrySheet(entry: e, known: register.map(knownPayees) ?? [], expenseAccounts: book?.expenseAccounts ?? []) { body in
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
        .sheet(item: $matching) { line in
            MatchSheet(line: line, entries: (register?.entries ?? []).filter { $0.bankLineId == nil && $0.status == "open" }) { txn in
                await run { try await BankClient.match(line.id, to: txn) }
            }
        }
    }

    /// The names this register has paid or been paid by, for a new entry.
    private func knownPayees(_ r: CheckRegister) -> [KnownPayee] {
        KnownPayee.list(r.entries.filter { $0.status != "void" }.map { ($0.payee, $0.date, $0.expenseAccountId) })
    }

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
        "Payee": .text { $0.payee },
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
                TableColumn("Payee") { e in
                    Text(e.payee ?? "—").strikethrough(e.status == "void").help([e.memo, e.expenseAccount].compactMap { $0 }.joined(separator: "\n"))
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
                    Text(l.name ?? "—")
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
        let head = ["Date", "Num", "Payee", "Category", "Memo", "Payment", "Deposit", "Status", "Balance"].joined(separator: "\t")
        let lines = entries.map { e -> String in
            let pay = e.amount < 0 ? String(format: "%.2f", -e.amount) : ""
            let dep = e.amount > 0 ? String(format: "%.2f", e.amount) : ""
            let cells: [String] = [e.date, e.checkNo ?? e.kind, e.payee ?? "", e.expenseAccount ?? "", e.memo ?? "", pay, dep, e.status,
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
    var known: [KnownPayee]
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
        Box(title: "New entry", symbol: "square.and.pencil", help: "Write it as on the check book's paper register: the date, the check number (or the kind of entry), who it pays (or the deposit is from) — typed, or a name the register has had before — and the amount. A name the register has had files the entry under the category its latest entry has; Edit Entry adds a memo or changes the category.") {
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
                PayeePicker(name: $draft.payee, known: known, prompt: draft.kind == "deposit" ? "From" : "Pay to") {
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
        guard let p = KnownPayee.named(draft.payee, in: known) else { return }
        draft.payee = p.name
        if draft.expenseAccountId == nil { draft.expenseAccountId = p.expenseAccountId }
    }

    private func enter() async {
        fillFromPayee()
        saving = true
        error = await save()
        saving = false
    }
}

/// A name a register has paid (or been paid by) before, with the expense account the latest entry with it has: the
/// New Entry's choices, and its default expense account (there are no target accounts, V048).
struct KnownPayee: Identifiable, Hashable {
    var name: String
    var expenseAccountId: Int?
    var id: String { name.lowercased() }

    /// The names these entries have, each once (as the latest spells it), with the latest expense account it had.
    static func list(_ entries: [(name: String?, date: String, expenseAccountId: Int?)]) -> [KnownPayee] {
        var known: [String: KnownPayee] = [:]
        for e in entries.sorted(by: { $0.date < $1.date }) {
            guard let n = e.name?.trimmingCharacters(in: .whitespaces), !n.isEmpty else { continue }
            known[n.lowercased(), default: KnownPayee(name: n)].name = n
            if let a = e.expenseAccountId { known[n.lowercased()]?.expenseAccountId = a }
        }
        return known.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func named(_ name: String, in known: [KnownPayee]) -> KnownPayee? {
        known.first { $0.name.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespaces)) == .orderedSame }
    }
}

/// Who an entry paid (or was paid by): typed, or picked from the names the register has had before.
struct PayeePicker: View {
    @Binding var name: String
    var known: [KnownPayee]
    var prompt: String
    var label: String = ""
    var picked: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            TextField(label, text: $name, prompt: Text(prompt)).frame(minWidth: 150)
                .onSubmit(picked)
            Menu {
                ForEach(known) { p in Button(p.name) { name = p.name; picked() } }
            } label: { Image(systemName: "clock.arrow.circlepath") }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Pick a name this register has had before: the entry takes the expense account its latest entry has")
                .disabled(known.isEmpty)
        }
    }
}

struct EditEntrySheet: View {
    let entry: RegisterEntry
    var known: [KnownPayee]
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
                PayeePicker(name: $draft.payee, known: known, prompt: draft.kind == "deposit" ? "From" : "Pay to", label: "Payee") {}
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
