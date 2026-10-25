//
//  ExpenseViews.swift
//  MxAcctMGR
//
//  Banking ▸ Expense Accounts: funded ledgers of purpose spending kept in the security master (accounts service
//  /expense-ledgers, V030) — a Mac and its software, a home office build-out, subscriptions, training, travel. Each
//  item is entered on a budget line (with its kind, budget and colour); transfers from a funding account (an external
//  account of the check register) fund it, and the balance is what was spent and not funded yet. What the spending
//  buys is tracked too: equipment as assets (depreciation, warranty), training as records (hours, completion,
//  certificates), trips with their per-diem allowances, and subscriptions with what they cost a year and when they
//  renew. An entry can wait for approval, as an enterprise expense would.
//

import SwiftUI

// MARK: - Model and client

struct ExpenseLedger: Decodable, Identifiable, Hashable {
    var code: String
    var name: String
    var purpose: String?
    var owner: String
    var costCenter: String?
    var openingDate: String
    var openingBalance: Double
    var budget: Double?
    var fundingPayees: [Int]
    var fundingAmount: Double?
    var fundingDay: Int?
    var closedDate: String?
    var version: Int
    var spent: Double
    var funded: Double
    var scheduled: Double
    var balance: Double
    var projected: Double
    var pendingApproval: Int
    var id: String { code }
}

struct ExpenseLine: Decodable, Identifiable, Hashable {
    var id: Int
    var name: String
    var kind: String
    var budget: Double?
    var expenseAccountId: Int?
    var expenseAccount: String?
    var color: String?
    var sortOrder: Int
    var active: Bool
    var spent: Double
    var spentThisYear: Double
    var entries: Int
    var remaining: Double?
}

struct ExpenseEntry: Decodable, Identifiable, Hashable {
    var id: Int
    var date: String
    var kind: String
    var description: String
    var vendor: String?
    var lineId: Int?
    var line: String?
    var lineColor: String?
    var tripId: Int?
    var trip: String?
    var payeeId: Int?
    var payee: String?
    var amount: Double
    var recurrence: String
    var status: String
    var approval: String
    var approvedBy: String?
    var approvedAt: String?
    var url: String?
    var notes: String?
    var cardTxnId: Int?
    var cardAccount: String?
    var bankTxnId: Int?
    var bankAccount: String?
    var bankDate: String?
    var version: Int
    var enteredBy: String?
    var updatedBy: String?
    var balance: Double
}

struct ExpenseSubscription: Decodable, Identifiable, Hashable {
    var entryId: Int
    var description: String
    var vendor: String?
    var line: String?
    var recurrence: String
    var amount: Double
    var lastCharged: String
    var annualCost: Double
    var nextRenewal: String
    var unrecorded: Bool
    var charges: Int
    var url: String?
    var id: Int { entryId }
}

struct ExpenseAsset: Decodable, Identifiable, Hashable {
    var id: Int
    var entryId: Int?
    var tag: String?
    var name: String
    var serialNo: String?
    var location: String?
    var assignedTo: String?
    var inService: String?
    var cost: Double
    var usefulLifeMonths: Int?
    var salvage: Double
    var method: String
    var warrantyEnd: String?
    var warrantyEntryId: Int?
    var warrantyPlan: String?
    var status: String
    var disposedDate: String?
    var disposalProceeds: Double?
    var notes: String?
    var version: Int
    var purchase: String?
    var url: String?
    var monthly: Double?
    var accumulated: Double
    var bookValue: Double
    var monthsInService: Int
    var fullyDepreciated: Bool
}

struct TrainingRecord: Decodable, Identifiable, Hashable {
    var id: Int
    var entryId: Int?
    var person: String?
    var course: String
    var provider: String?
    var kind: String
    var startDate: String?
    var endDate: String?
    var hours: Double?
    var status: String
    var certificateExpires: String?
    var notes: String?
    var version: Int
    var cost: Double?
    var purchase: String?
}

struct ExpenseTrip: Decodable, Identifiable, Hashable {
    var id: Int
    var name: String
    var traveler: String?
    var destination: String?
    var purpose: String?
    var departDate: String?
    var returnDate: String?
    var perDiemMeals: Double?
    var perDiemLodging: Double?
    var status: String
    var notes: String?
    var version: Int
    var spent: Double
    var entries: Int
    var days: Int?
    var allowance: Double?
}

struct ExpenseAlert: Decodable, Hashable {
    var level: String
    var text: String
}

struct ExpenseBookData: Decodable {
    var ledger: ExpenseLedger
    var lines: [ExpenseLine]
    var entries: [ExpenseEntry]
    var subscriptions: [ExpenseSubscription]
    var assets: [ExpenseAsset]
    var training: [TrainingRecord]
    var trips: [ExpenseTrip]
    var alerts: [ExpenseAlert]
    var subscriptionsAnnual: Double
}

struct CardCharge: Decodable, Identifiable, Hashable {
    var id: Int
    var cardAccount: String
    var card: String
    var date: String
    var payee: String?
    var memo: String?
    var amount: Double
    var expenseAccount: String?
}

nonisolated enum ExpenseClient {
    private struct Ledgers: Decodable { var ledgers: [ExpenseLedger] }
    private struct Charges: Decodable { var charges: [CardCharge] }
    private static func signed(_ body: [String: Any]) -> [String: Any] { body.merging(["by": BankClient.by]) { a, _ in a } }

    static func ledgers() async throws -> [ExpenseLedger] {
        try await AccountsClient.request("GET", "/expense-ledgers", as: Ledgers.self).ledgers
    }
    static func saveLedger(_ code: String, _ body: [String: Any]) async throws -> [ExpenseLedger] {
        try await AccountsClient.request("PUT", "/expense-ledgers/\(code)", body: signed(body), as: Ledgers.self).ledgers
    }
    static func book(_ code: String) async throws -> ExpenseBookData {
        try await AccountsClient.request("GET", "/expense-ledgers/\(code)", as: ExpenseBookData.self)
    }
    static func add(_ code: String, _ body: [String: Any]) async throws -> ExpenseBookData {
        try await AccountsClient.request("POST", "/expense-ledgers/\(code)/entries", body: signed(body), as: ExpenseBookData.self)
    }
    static func update(_ id: Int, _ body: [String: Any]) async throws -> ExpenseBookData {
        try await AccountsClient.request("PUT", "/expense-entries/\(id)", body: signed(body), as: ExpenseBookData.self)
    }
    static func approve(_ id: Int, _ approval: String) async throws -> ExpenseBookData {
        try await AccountsClient.request("POST", "/expense-entries/\(id)/approve", body: signed(["approval": approval]), as: ExpenseBookData.self)
    }
    static func renew(_ id: Int) async throws -> ExpenseBookData {
        try await AccountsClient.request("POST", "/expense-entries/\(id)/renew", body: signed([:]), as: ExpenseBookData.self)
    }
    static func fund(_ code: String, _ body: [String: Any]) async throws -> ExpenseBookData {
        try await AccountsClient.request("POST", "/expense-ledgers/\(code)/fund", body: signed(body), as: ExpenseBookData.self)
    }
    /// Saves a budget line, asset, training record or trip (`part`: lines, assets, training, trips); id 0 adds one.
    static func save(_ code: String, _ part: String, _ id: Int, _ body: [String: Any]) async throws -> ExpenseBookData {
        try await AccountsClient.request("PUT", "/expense-ledgers/\(code)/\(part)/\(id)", body: signed(body), as: ExpenseBookData.self)
    }
    static func cardCharges(_ code: String) async throws -> [CardCharge] {
        try await AccountsClient.request("GET", "/expense-ledgers/\(code)/card-charges", as: Charges.self).charges
    }
}

extension Color {
    /// A colour from #rrggbb (a budget line's), else nil.
    init?(hex: String?) {
        guard let hex, hex.count == 7, hex.hasPrefix("#"), let v = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

private func day(_ s: String?) -> Date? { s.flatMap { isoDay.date(from: String($0.prefix(10))) } }
private func iso(_ d: Date?) -> Any { d.map { isoDay.string(from: $0) } ?? NSNull() }

// MARK: - Expense Accounts

struct ExpenseLedgersView: View {
    @Bindable var store: PortStore
    @AppStorage("expenseLedger") private var selected = ""
    @AppStorage("expenseTab") private var tab = "register"
    @AppStorage("expenseLineShown") private var lineShown = 0
    /// How many of the register's rows show at once.
    @AppStorage("expenseRegisterRows") private var registerRows = 26
    @State private var ledgers: [ExpenseLedger] = []
    @State private var data: ExpenseBookData?
    @State private var book: ExpenseBook?
    @State private var message: String?
    @State private var problem: String?
    @State private var busy = false
    @State private var selection = Set<ExpenseEntry.ID>()
    @State private var draft = ExpenseDraft()
    @State private var ledgerSheet: ExpenseLedger??
    @State private var editing: ExpenseEntry?
    @State private var funding = false
    @State private var fromCard = false
    @State private var lineSheet: ExpenseLine??
    @State private var assetSheet: ExpenseAsset??
    @State private var trainingSheet: TrainingRecord??
    @State private var tripSheet: ExpenseTrip??
    /// The register's Excel-style sorting and column filters (the header buttons).
    @State private var grid = GridQueryOptions()

    static let tabs = [("register", "Register"), ("budget", "Budget"), ("subscriptions", "Subscriptions"), ("assets", "Assets"),
                       ("training", "Training"), ("travel", "Travel")]

    var body: some View {
        StepPage(store: store, subtitle: "Ledgers of what is bought for a purpose — equipment and software, a home office, subscriptions, training, travel — each item on a budget line, and the transfers that fund it.", lesson: [
            "Enter each item on its budget line (Mac & Software, Home Office Desk Buildout, Subscriptions …): the line shows what was spent against its budget. A monthly or yearly item is a subscription: its yearly cost and next renewal show on Subscriptions, and Renew records the next charge.",
            "Transfers from the funding account fund the ledger: the balance is what was spent and not funded yet (green when funded ahead). Fund… plans a monthly transfer; the ones still to come are scheduled and count toward the projected balance only. A transfer in the check register links to its entry by itself.",
            "What the money buys is kept too: equipment as assets (where it is, who has it, its depreciation and warranty), training (hours, completion, certificates) and trips (dates and per-diem allowances against what was spent). An entry can wait for approval by someone other than who entered it.",
        ]) {
            accountBar
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
            }
            if let d = data {
                tiles(d)
                if !d.alerts.isEmpty { alerts(d) }
                Picker("", selection: $tab) { ForEach(Self.tabs, id: \.0) { Text($0.1).tag($0.0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 640)
                switch tab {
                case "budget": budget(d)
                case "subscriptions": subscriptions(d)
                case "assets": assets(d)
                case "training": training(d)
                case "travel": travel(d)
                default:
                    ExpenseEntryForm(draft: $draft, lines: d.lines.filter(\.active), trips: d.trips) { await add() }
                    register(d)
                }
            } else if ledgers.isEmpty && problem == nil && !busy {
                ContentUnavailableView {
                    Label("No expense account yet", systemImage: "briefcase")
                } description: {
                    Text("Add one for a purpose — a computer and its software, a home office, training, travel — with the account that funds it.")
                } actions: {
                    Button("New Expense Account…") { ledgerSheet = .some(nil) }
                }
            }
        }
        .task { await reload() }
        .task(id: selected) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if editing == nil, !busy { await refresh() }
            }
        }
        .sheet(isPresented: Binding(get: { ledgerSheet != nil }, set: { if !$0 { ledgerSheet = nil } })) {
            LedgerSheet(ledger: ledgerSheet ?? nil, payees: book?.payees ?? []) { code, body in
                do {
                    ledgers = try await ExpenseClient.saveLedger(code, body)
                    selected = code.uppercased()
                    await refresh()
                    return nil
                } catch { return describe(error) }
            }
        }
        .sheet(item: $editing) { e in
            ExpenseEntrySheet(entry: e, lines: data?.lines ?? [], trips: data?.trips ?? [], payees: book?.payees ?? []) { body in
                await run { try await ExpenseClient.update(e.id, body) }
            }
        }
        .sheet(isPresented: $funding) {
            if let l = data?.ledger {
                FundSheet(ledger: l, payees: book?.payees ?? []) { body in await run { try await ExpenseClient.fund(l.code, body) } }
            }
        }
        .sheet(isPresented: $fromCard) {
            if let d = data {
                CardChargesSheet(code: d.ledger.code, lines: d.lines.filter(\.active)) { body in
                    await run { try await ExpenseClient.add(d.ledger.code, body) }
                }
            }
        }
        .sheet(isPresented: Binding(get: { lineSheet != nil }, set: { if !$0 { lineSheet = nil } })) {
            LineSheet(line: lineSheet ?? nil, expenseAccounts: book?.expenseAccounts ?? []) { body in
                await savePart("lines", (lineSheet ?? nil)?.id ?? 0, body)
            }
        }
        .sheet(isPresented: Binding(get: { assetSheet != nil }, set: { if !$0 { assetSheet = nil } })) {
            AssetSheet(asset: assetSheet ?? nil, entries: data?.entries ?? []) { body in
                await savePart("assets", (assetSheet ?? nil)?.id ?? 0, body)
            }
        }
        .sheet(isPresented: Binding(get: { trainingSheet != nil }, set: { if !$0 { trainingSheet = nil } })) {
            TrainingSheet(record: trainingSheet ?? nil, entries: data?.entries ?? []) { body in
                await savePart("training", (trainingSheet ?? nil)?.id ?? 0, body)
            }
        }
        .sheet(isPresented: Binding(get: { tripSheet != nil }, set: { if !$0 { tripSheet = nil } })) {
            TripSheet(trip: tripSheet ?? nil) { body in
                await savePart("trips", (tripSheet ?? nil)?.id ?? 0, body)
            }
        }
    }

    private var accountBar: some View {
        HStack(spacing: 10) {
            Picker("Expense account", selection: $selected) {
                ForEach(ledgers) { l in Text(l.name).tag(l.code) }
            }
            .frame(maxWidth: 380)
            .disabled(ledgers.isEmpty)
            Button("New…") { ledgerSheet = .some(nil) }
            Button("Edit…") { ledgerSheet = .some(data?.ledger) }.disabled(data == nil)
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            if let message { Text(message).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
            Button { fromCard = true } label: { Label("From Card…", systemImage: "creditcard") }
                .disabled(data == nil || busy)
                .help("Add charges from Credit Card Accounts to this expense account (each charge once, in one expense account)")
            Button { funding = true } label: { Label("Fund…", systemImage: "arrow.down.circle") }
                .disabled(data == nil || busy)
                .help("Enter funding transfers: one, or one a month (those still to come are scheduled)")
            Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Show what others entered since")
        }
        .onChange(of: selected) { lineShown = 0; Task { await refresh() } }
    }

    private func tiles(_ d: ExpenseBookData) -> some View {
        let l = d.ledger
        return HStack(spacing: 10) {
            MetricTile(title: "Spent", value: money2(l.spent),
                       caption: l.budget.map { "of a \(money2($0)) budget" } ?? "\(d.lines.count) budget line\(d.lines.count == 1 ? "" : "s")",
                       tint: l.budget.map { l.spent > $0 ? .red : .primary } ?? .primary,
                       help: "Every item bought, less refunds (not void, not scheduled).")
            MetricTile(title: "Funded", value: money2(l.funded),
                       caption: l.scheduled > 0 ? "\(money2(l.scheduled)) more scheduled" : "no transfers scheduled",
                       help: "The funding transfers made so far; the scheduled ones are still to come.")
            balanceTile(title: "Balance today", value: l.balance,
                        help: "Spent and not funded yet (red), or funded ahead (green): the opening balance plus every entry made so far.")
            balanceTile(title: "Projected", value: l.projected,
                        help: "The balance once the scheduled transfers are made.")
            MetricTile(title: "Subscriptions", value: money2(d.subscriptionsAnnual), caption: "a year, \(d.subscriptions.count) recurring",
                       help: "What the monthly and yearly items cost a year, at their latest charge.")
        }
    }

    private func balanceTile(title: String, value: Double, help: String) -> some View {
        MetricTile(title: title, value: money2(abs(value)), caption: value > 0.005 ? "spent, not funded" : value < -0.005 ? "funded ahead" : "even",
                   tint: value > 0.005 ? .red : .green, help: help)
    }

    private func alerts(_ d: ExpenseBookData) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(d.alerts, id: \.self) { a in
                Label(a.text, systemImage: a.level == "warning" ? "exclamationmark.triangle.fill" : "bell")
                    .foregroundStyle(a.level == "warning" ? .orange : .secondary).font(.callout)
            }
        }
    }

    // MARK: Register

    /// The register's columns for sorting and filtering, by their titles.
    static let columns: [String: LocalGridColumn<ExpenseEntry>] = [
        "Date": .date({ $0.date }, display: { shortDay($0.date) }),
        "Line": .text { $0.kind == "funding" ? "Funding" : $0.line },
        "Item": .text { $0.description },
        "Vendor": .text { $0.vendor ?? $0.payee },
        "Spent": .number({ $0.amount > 0 ? $0.amount : nil }, display: { $0.amount > 0 ? money2($0.amount) : nil }),
        "Funded": .number({ $0.amount < 0 ? -$0.amount : nil }, display: { $0.amount < 0 ? money2(-$0.amount) : nil }),
        "✓": .text { e in
            var s = [e.status == "scheduled" ? "Scheduled" : e.status == "void" ? "Void" : "Made"]
            if e.approval != "none" { s.append(e.approval.capitalized) }
            return s.joined(separator: ", ")
        },
        "Balance": .number({ $0.status == "void" ? nil : $0.balance }, display: { $0.status == "void" ? nil : money2(abs($0.balance)) }),
    ]

    private func register(_ d: ExpenseBookData) -> some View {
        let byLine = lineShown == 0 ? d.entries : d.entries.filter { $0.lineId == lineShown }
        let rows = LocalGrid.rows(byLine, grid, Self.columns)
        return Box(title: "Register", symbol: "list.bullet.rectangle", help: "Every entry in date order with the running balance (over the whole ledger, also when one line is shown or the rows are filtered or sorted otherwise). Each column header's button sorts and filters it, as in Excel. Double-click to change one; the ledger is shared, so a change made from an older copy is refused.") {
            HStack {
                Picker("Show", selection: $lineShown) {
                    Text("Every line").tag(0)
                    ForEach(d.lines) { l in Text(l.name).tag(l.id) }
                }
                .fixedSize()
                DateOrderToggle(options: $grid, key: "expenseRegisterNewestFirst")
                Spacer()
                if lineShown != 0 || !grid.filters.isEmpty {
                    Text("\(rows.count) entries · \(money2(rows.filter { $0.status == "actual" }.reduce(0) { $0 + $1.amount }))")
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                        .help("The entries shown, and what they add up to (made, not scheduled; funding counts negative)")
                }
                RowsStepper(rows: $registerRows, range: 8...40, what: "register")
            }
            GridFilterStatus(shown: rows.count, of: byLine.count, options: $grid)
            Table(rows, selection: $selection) {
                TableColumn("Date") { e in Text(shortDay(e.date)).monospacedDigit().foregroundStyle(e.status == "scheduled" ? .secondary : .primary).help(entryHelp(e)) }.width(min: 70, ideal: 84)
                TableColumn("Line") { e in lineLabel(e) }.width(min: 90, ideal: 160)
                TableColumn("Item") { e in itemLabel(e) }.width(min: 140, ideal: 240)
                TableColumn("Vendor") { e in Text(e.vendor ?? e.payee ?? "").foregroundStyle(.secondary) }.width(min: 60, ideal: 100)
                TableColumn("Spent") { e in Text(e.amount > 0 ? money2(e.amount) : "").monospacedDigit() }.width(min: 60, ideal: 90)
                TableColumn("Funded") { e in Text(e.amount < 0 ? money2(-e.amount) : "").monospacedDigit().foregroundStyle(.green) }.width(min: 60, ideal: 90)
                TableColumn("✓") { e in statusMark(e) }.width(56)
                TableColumn("Balance") { e in
                    Text(e.status == "void" ? "" : money2(abs(e.balance))).monospacedDigit()
                        .foregroundStyle(e.balance > 0.005 ? .red : .primary)
                }.width(min: 70, ideal: 100)
            }
            .tableText()
            .contextMenu(forSelectionType: ExpenseEntry.ID.self) { ids in entryMenu(d.entries.filter { ids.contains($0.id) }) }
            primaryAction: { ids in
                if ids.count == 1, let e = d.entries.first(where: { ids.contains($0.id) }) { editing = e }
            }
            .textSelection(.disabled)
            .onCopyCommand {
                let chosen = rows.filter { selection.contains($0.id) }
                return chosen.isEmpty ? [] : [NSItemProvider(object: Self.text(chosen) as NSString)]
            }
            .columnHeaderFilters(types: LocalGrid.types(Self.columns), options: grid,
                                 loadValues: { (LocalGrid.values(byLine, column: $0, grid, Self.columns), false) },
                                 apply: { grid = $0 })
            .frame(minHeight: PortSettings.shared.tableHeight(rows: min(max(rows.count, 8), registerRows)))
        }
    }

    private func lineLabel(_ e: ExpenseEntry) -> some View {
        HStack(spacing: 6) {
            Circle().fill(Color(hex: e.lineColor) ?? .secondary.opacity(e.kind == "funding" ? 0 : 0.4)).frame(width: 9, height: 9)
            Text(e.kind == "funding" ? "Funding" : (e.line ?? "—")).foregroundStyle(e.kind == "funding" ? .secondary : .primary)
        }
    }

    private func itemLabel(_ e: ExpenseEntry) -> some View {
        HStack(spacing: 4) {
            Text(e.description).strikethrough(e.status == "void").italic(e.recurrence != "none")
            if e.recurrence != "none" { Text(e.recurrence == "monthly" ? "/ mo" : "/ yr").font(.caption).foregroundStyle(.secondary) }
            if let t = e.trip { Image(systemName: "airplane").font(.caption).foregroundStyle(.secondary).help("Trip: \(t)") }
            if let u = e.url, let link = URL(string: u) {
                Link(destination: link) { Image(systemName: "link").font(.caption) }.help(u)
            }
            if e.notes?.isEmpty == false { Image(systemName: "note.text").font(.caption).foregroundStyle(.secondary).help(e.notes ?? "") }
        }
    }

    private func statusMark(_ e: ExpenseEntry) -> some View {
        HStack(spacing: 3) {
            switch e.approval {
            case "pending": Image(systemName: "hourglass").foregroundStyle(.orange).help("Waiting for approval")
            case "approved": Image(systemName: "checkmark.seal").foregroundStyle(.green).help("Approved by \(e.approvedBy ?? "—")")
            case "rejected": Image(systemName: "xmark.seal").foregroundStyle(.red).help("Rejected by \(e.approvedBy ?? "—")")
            default: EmptyView()
            }
            if e.status == "scheduled" { Image(systemName: "calendar").foregroundStyle(.secondary).help("Scheduled: not made yet") }
            if e.status == "void" { Image(systemName: "xmark").foregroundStyle(.secondary).help("Void") }
            if e.bankTxnId != nil { Image(systemName: "building.columns").font(.caption).foregroundStyle(.secondary).help("In \(e.bankAccount ?? "checking") on \(shortDay(e.bankDate))") }
            if e.cardTxnId != nil { Image(systemName: "creditcard").font(.caption).foregroundStyle(.secondary).help("Charged to \(e.cardAccount ?? "a card")") }
        }
    }

    @ViewBuilder
    private func entryMenu(_ chosen: [ExpenseEntry]) -> some View {
        if chosen.count == 1, let e = chosen.first {
            Button("Edit Entry…") { editing = e }
            if let u = e.url, let link = URL(string: u) { Button("Open Link") { NSWorkspace.shared.open(link) } }
            Divider()
            if e.approval == "pending" {
                Button("Approve") { Task { await run { try await ExpenseClient.approve(e.id, "approved") } } }
                Button("Reject") { Task { await run { try await ExpenseClient.approve(e.id, "rejected") } } }
            } else if e.approval == "none" && e.kind != "funding" {
                Button("Ask for Approval") { Task { await run { try await ExpenseClient.approve(e.id, "pending") } } }
            }
            if e.recurrence != "none" { Button("Renew (Record the Next Charge)") { Task { await run { try await ExpenseClient.renew(e.id) } } } }
            if e.status == "scheduled" { Button("Mark Made") { Task { await setStatus(e, "actual") } } }
            Divider()
            if e.status != "void" { Button("Void") { Task { await setStatus(e, "void") } } }
            else { Button("Restore") { Task { await setStatus(e, "actual") } } }
            Divider()
        }
        if !chosen.isEmpty {
            Button(chosen.count == 1 ? "Copy Entry" : "Copy \(chosen.count) Entries") { copy(Self.text(chosen)) }
        }
    }

    // MARK: Budget

    private func budget(_ d: ExpenseBookData) -> some View {
        Box(title: "Budget lines", symbol: "chart.bar.doc.horizontal", help: "What the spending is for: each line with its kind, budget, what was spent and what is left. Click one to change it; its colour marks its entries in the register.") {
            HStack {
                Button("New Line…") { lineSheet = .some(nil) }
                Spacer()
                Text("Total \(money2(d.lines.reduce(0) { $0 + $1.spent }))").monospacedDigit().foregroundStyle(.secondary)
            }
            ForEach(d.lines) { l in
                Button { lineSheet = .some(l) } label: { lineRow(l) }.plainButton()
            }
        }
    }

    private func lineRow(_ l: ExpenseLine) -> some View {
        let share = l.budget.map { $0 > 0 ? min(l.spent / $0, 1.2) : 0 }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle().fill(Color(hex: l.color) ?? .secondary).frame(width: 10, height: 10)
                Text(l.name).heading(.name).foregroundStyle(l.active ? .primary : .secondary)
                Text(l.kind).font(.caption).foregroundStyle(.secondary)
                if let a = l.expenseAccount { Text("→ \(a)").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Text("\(l.entries) items").font(.caption).foregroundStyle(.secondary)
                Text(money2(l.spent)).monospacedDigit().heading(.name)
                if let b = l.budget {
                    Text("of \(money2(b))").monospacedDigit().foregroundStyle(.secondary)
                    Text(l.remaining.map { $0 >= 0 ? "\(money2($0)) left" : "\(money2(-$0)) over" } ?? "")
                        .monospacedDigit().foregroundStyle((l.remaining ?? 0) < 0 ? .red : .green)
                }
            }
            if let share {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(share > 1 ? Color.red : (Color(hex: l.color) ?? .accentColor)).frame(width: g.size.width * min(share, 1))
                    }
                }
                .frame(height: 6)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .help("Click to change the line: its name, kind, budget, category and colour")
    }

    // MARK: Subscriptions

    private func subscriptions(_ d: ExpenseBookData) -> some View {
        Box(title: "Subscriptions", symbol: "repeat", help: "Every monthly or yearly item at its latest charge: what it costs a year and when it renews. Renew records the next charge (a month or a year after the latest); an orange date has passed with no charge recorded.") {
            Table(d.subscriptions) {
                TableColumn("Item") { s in Text(s.description) }.width(min: 140, ideal: 220)
                TableColumn("Line") { s in Text(s.line ?? "").foregroundStyle(.secondary) }.width(min: 80, ideal: 140)
                TableColumn("Every") { s in Text(s.recurrence == "monthly" ? "month" : "year").foregroundStyle(.secondary) }.width(min: 40, ideal: 56)
                TableColumn("Charge") { s in Text(money2(s.amount)).monospacedDigit() }.width(min: 60, ideal: 80)
                TableColumn("A year") { s in Text(money2(s.annualCost)).monospacedDigit() }.width(min: 60, ideal: 84)
                TableColumn("Last charged") { s in Text(shortDay(s.lastCharged)).monospacedDigit().help("\(s.charges) charge\(s.charges == 1 ? "" : "s") recorded") }.width(min: 70, ideal: 90)
                TableColumn("Renews") { s in Text(shortDay(s.nextRenewal)).monospacedDigit().foregroundStyle(s.unrecorded ? .orange : .primary).help(s.unrecorded ? "It renewed since the last charge recorded" : "") }.width(min: 70, ideal: 90)
                TableColumn("") { s in
                    Button("Renew") { Task { await run { try await ExpenseClient.renew(s.entryId) } } }
                        .controlSize(.small).help("Record the next charge of \(s.description)")
                }.width(64)
            }
            .tableText()
            .frame(minHeight: PortSettings.shared.tableHeight(rows: min(max(d.subscriptions.count, 4), 16)))
        }
    }

    // MARK: Assets

    private func assets(_ d: ExpenseBookData) -> some View {
        Box(title: "Assets", symbol: "desktopcomputer", help: "Equipment the ledger bought: where it is and who has it, its depreciation (straight-line or declining balance over its useful life) and its warranty. Double-click to change one.") {
            HStack {
                Button("New Asset…") { assetSheet = .some(nil) }
                Spacer()
                Text("Cost \(money2(d.assets.reduce(0) { $0 + $1.cost })) · book value \(money2(d.assets.filter { $0.status != "disposed" }.reduce(0) { $0 + $1.bookValue }))")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Table(d.assets) {
                TableColumn("Asset") { a in Text(a.name).help([a.tag, a.serialNo.map { "serial \($0)" }, a.notes].compactMap { $0 }.joined(separator: " · ")) }.width(min: 120, ideal: 170)
                TableColumn("Location") { a in Text([a.location, a.assignedTo].compactMap { $0 }.joined(separator: " · ")).foregroundStyle(.secondary) }.width(min: 80, ideal: 140)
                TableColumn("In service") { a in Text(shortDay(a.inService)).monospacedDigit() }.width(min: 70, ideal: 84)
                TableColumn("Cost") { a in Text(money2(a.cost)).monospacedDigit() }.width(min: 60, ideal: 90)
                TableColumn("Per month") { a in Text(a.monthly.map(money2) ?? "—").monospacedDigit().foregroundStyle(.secondary).help(a.usefulLifeMonths.map { "\(a.method) over \($0) months" } ?? "no useful life set") }.width(min: 60, ideal: 80)
                TableColumn("Book value") { a in Text(money2(a.bookValue)).monospacedDigit().help("Depreciated \(money2(a.accumulated)) over \(a.monthsInService) months\(a.fullyDepreciated ? " (fully)" : "")") }.width(min: 70, ideal: 90)
                TableColumn("Warranty") { a in warrantyLabel(a) }.width(min: 80, ideal: 140)
                TableColumn("Status") { a in Text(a.status).foregroundStyle(a.status == "in service" ? Color.secondary : Color.orange) }.width(min: 60, ideal: 80)
            }
            .tableText()
            .contextMenu(forSelectionType: ExpenseAsset.ID.self) { ids in
                if let a = d.assets.first(where: { ids.contains($0.id) }) { Button("Edit Asset…") { assetSheet = .some(a) } }
            } primaryAction: { ids in
                if let a = d.assets.first(where: { ids.contains($0.id) }) { assetSheet = .some(a) }
            }
            .frame(minHeight: PortSettings.shared.tableHeight(rows: min(max(d.assets.count, 4), 16)))
        }
    }

    private func warrantyLabel(_ a: ExpenseAsset) -> some View {
        let end = day(a.warrantyEnd)
        let soon = end.map { $0.timeIntervalSinceNow < 60 * 86400 } ?? false
        return Text(a.warrantyEnd.map { "to \(shortDay($0))" } ?? "—")
            .monospacedDigit().foregroundStyle(soon ? .orange : .secondary)
            .help(a.warrantyPlan.map { "Covered by \($0)" } ?? "")
    }

    // MARK: Training

    private func training(_ d: ExpenseBookData) -> some View {
        Box(title: "Training", symbol: "graduationcap", help: "Courses, lessons, conferences and certifications the ledger paid for: who, the provider, dates and hours, where they stand and when a certificate expires. Double-click to change one.") {
            HStack {
                Button("New Training…") { trainingSheet = .some(nil) }
                Spacer()
                Text("\(d.training.filter { $0.status == "completed" }.count) completed · \(String(format: "%.1f", d.training.compactMap(\.hours).reduce(0, +))) hours")
                    .foregroundStyle(.secondary)
            }
            Table(d.training) {
                TableColumn("Course") { t in Text(t.course) }.width(min: 140, ideal: 220)
                TableColumn("Provider") { t in Text(t.provider ?? "").foregroundStyle(.secondary) }.width(min: 80, ideal: 140)
                TableColumn("Who") { t in Text(t.person ?? "").foregroundStyle(.secondary) }.width(min: 50, ideal: 80)
                TableColumn("Kind") { t in Text(t.kind).foregroundStyle(.secondary) }.width(min: 60, ideal: 90)
                TableColumn("Dates") { t in Text([t.startDate, t.endDate].compactMap { $0.map(shortDay) }.joined(separator: " – ")).monospacedDigit() }.width(min: 80, ideal: 170)
                TableColumn("Hours") { t in Text(t.hours.map { String(format: "%.1f", $0) } ?? "").monospacedDigit() }.width(min: 40, ideal: 56)
                TableColumn("Cost") { t in Text(t.cost.map(money2) ?? "").monospacedDigit() }.width(min: 60, ideal: 80)
                TableColumn("Status") { t in Text(t.status).foregroundStyle(t.status == "completed" ? .green : .secondary) }.width(min: 60, ideal: 84)
                TableColumn("Certificate") { t in Text(t.certificateExpires.map { "to \(shortDay($0))" } ?? "").monospacedDigit() }.width(min: 60, ideal: 90)
            }
            .tableText()
            .contextMenu(forSelectionType: TrainingRecord.ID.self) { ids in
                if let t = d.training.first(where: { ids.contains($0.id) }) { Button("Edit Training…") { trainingSheet = .some(t) } }
            } primaryAction: { ids in
                if let t = d.training.first(where: { ids.contains($0.id) }) { trainingSheet = .some(t) }
            }
            .frame(minHeight: PortSettings.shared.tableHeight(rows: min(max(d.training.count, 4), 16)))
        }
    }

    // MARK: Travel

    private func travel(_ d: ExpenseBookData) -> some View {
        Box(title: "Trips", symbol: "airplane", help: "Trips the ledger pays for: traveler, destination, dates and per-diem allowances (meals each day, lodging each night) against what was spent on the trip. Enter a trip's items in the register with the trip picked. Double-click to change one.") {
            HStack {
                Button("New Trip…") { tripSheet = .some(nil) }
                Spacer()
            }
            Table(d.trips) {
                TableColumn("Trip") { t in Text(t.name).help(t.purpose ?? "") }.width(min: 120, ideal: 180)
                TableColumn("Traveler") { t in Text(t.traveler ?? "").foregroundStyle(.secondary) }.width(min: 60, ideal: 90)
                TableColumn("Destination") { t in Text(t.destination ?? "").foregroundStyle(.secondary) }.width(min: 80, ideal: 140)
                TableColumn("Dates") { t in Text([t.departDate, t.returnDate].compactMap { $0.map(shortDay) }.joined(separator: " – ")).monospacedDigit() }.width(min: 80, ideal: 170)
                TableColumn("Spent") { t in Text(money2(t.spent)).monospacedDigit().help("\(t.entries) entries") }.width(min: 60, ideal: 84)
                TableColumn("Per diem") { t in
                    Text(t.allowance.map(money2) ?? "—").monospacedDigit()
                        .foregroundStyle(t.allowance.map { t.spent > $0 ? Color.red : Color.secondary } ?? Color.secondary)
                        .help(t.days.map { "\($0) days: meals \(money2(t.perDiemMeals ?? 0)) a day, lodging \(money2(t.perDiemLodging ?? 0)) a night" } ?? "")
                }.width(min: 60, ideal: 84)
                TableColumn("Status") { t in Text(t.status).foregroundStyle(.secondary) }.width(min: 60, ideal: 80)
            }
            .tableText()
            .contextMenu(forSelectionType: ExpenseTrip.ID.self) { ids in
                if let t = d.trips.first(where: { ids.contains($0.id) }) {
                    Button("Edit Trip…") { tripSheet = .some(t) }
                    Button("Enter an Item for This Trip") { draft.tripId = t.id; tab = "register" }
                }
            } primaryAction: { ids in
                if let t = d.trips.first(where: { ids.contains($0.id) }) { tripSheet = .some(t) }
            }
            .frame(minHeight: PortSettings.shared.tableHeight(rows: min(max(d.trips.count, 4), 16)))
        }
    }

    // MARK: Helpers

    private func entryHelp(_ e: ExpenseEntry) -> String {
        var parts = ["Entered by \(e.enteredBy ?? "—")"]
        if let u = e.updatedBy, u != e.enteredBy { parts.append("last changed by \(u)") }
        if let p = e.payee { parts.append(p) }
        return parts.joined(separator: " · ")
    }

    static func text(_ entries: [ExpenseEntry]) -> String {
        let head = ["Date", "Line", "Item", "Vendor", "Spent", "Funded", "Status", "Balance"].joined(separator: "\t")
        let lines = entries.map { e -> String in
            [e.date, e.kind == "funding" ? "Funding" : (e.line ?? ""), e.description, e.vendor ?? "",
             e.amount > 0 ? String(format: "%.2f", e.amount) : "", e.amount < 0 ? String(format: "%.2f", -e.amount) : "",
             e.status, String(format: "%.2f", e.balance)].joined(separator: "\t")
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
            ledgers = try await ExpenseClient.ledgers()
            book = try? await BankClient.book()
            if !ledgers.contains(where: { $0.code == selected }) { selected = ledgers.first?.code ?? "" }
            problem = nil
            await refresh()
        } catch {
            problem = describe(error)
        }
    }

    private func refresh() async {
        guard !selected.isEmpty else { data = nil; return }
        do {
            data = try await ExpenseClient.book(selected)
            problem = nil
        } catch {
            problem = describe(error)
        }
    }

    @discardableResult
    private func run(_ change: () async throws -> ExpenseBookData) async -> String? {
        busy = true
        defer { busy = false }
        do {
            data = try await change()
            message = nil
            return nil
        } catch {
            await refresh()
            message = describe(error)
            return describe(error)
        }
    }

    private func savePart(_ part: String, _ id: Int, _ body: [String: Any]) async -> String? {
        guard let code = data?.ledger.code else { return "Choose an expense account" }
        return await run { try await ExpenseClient.save(code, part, id, body) }
    }

    private func add() async -> String? {
        guard let code = data?.ledger.code else { return "Choose an expense account" }
        let error = await run { try await ExpenseClient.add(code, draft.body) }
        if error == nil {
            let keep = (draft.date, draft.lineId, draft.tripId)
            draft = ExpenseDraft()
            (draft.date, draft.lineId, draft.tripId) = keep
        }
        return error
    }

    private func setStatus(_ e: ExpenseEntry, _ status: String) async {
        await run { try await ExpenseClient.update(e.id, ["version": e.version, "status": status]) }
    }
}

// MARK: - Entering an item

struct ExpenseDraft {
    var date = Date()
    var kind = "expense"
    var description = ""
    var vendor = ""
    var lineId: Int?
    var tripId: Int?
    var amount: Double?
    var recurrence = "none"
    var approval = false

    var body: [String: Any] {
        ["date": isoDay.string(from: date), "kind": kind, "description": description, "vendor": vendor,
         "lineId": lineId ?? NSNull(), "tripId": tripId ?? NSNull(), "amount": amount ?? 0, "recurrence": recurrence,
         "approval": approval ? "pending" : "none"]
    }
}

struct ExpenseEntryForm: View {
    @Binding var draft: ExpenseDraft
    var lines: [ExpenseLine]
    var trips: [ExpenseTrip]
    var save: () async -> String?
    @State private var error: String?
    @State private var saving = false

    static let kinds = [("expense", "Item bought"), ("refund", "Refund"), ("adjustment", "Adjustment")]
    static let recurrences = [("none", "Once"), ("monthly", "Monthly"), ("yearly", "Yearly")]

    var body: some View {
        Box(title: "New item", symbol: "square.and.pencil", help: "What was bought: the date, its budget line, the item, where from and what it cost. Monthly or yearly makes it a subscription; a trip files it under that trip; Needs approval waits for someone else to approve it. Funding transfers go in with Fund….") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                DatePicker("", selection: $draft.date, displayedComponents: .date).labelsHidden().fixedSize()
                Picker("", selection: $draft.kind) { ForEach(Self.kinds, id: \.0) { Text($0.1).tag($0.0) } }
                    .labelsHidden().frame(width: 110)
                Picker("", selection: $draft.lineId) {
                    Text("Line").tag(Int?.none)
                    ForEach(lines) { Text($0.name).tag(Optional($0.id)) }
                }
                .labelsHidden().frame(width: 170)
                TextField("Item", text: $draft.description).frame(minWidth: 140)
                TextField("Vendor", text: $draft.vendor).frame(width: 110)
                TextField("Amount", value: $draft.amount, format: .number.precision(.fractionLength(2))).frame(width: 90)
                    .onSubmit { Task { await enter() } }
                Picker("", selection: $draft.recurrence) { ForEach(Self.recurrences, id: \.0) { Text($0.1).tag($0.0) } }
                    .labelsHidden().frame(width: 90)
                Button("Enter") { Task { await enter() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(saving || (draft.amount ?? 0) == 0 || draft.description.isEmpty)
                    .help("Add it to the ledger (⌘↩)")
            }
            HStack(spacing: 12) {
                if !trips.isEmpty {
                    Picker("Trip", selection: $draft.tripId) {
                        Text("None").tag(Int?.none)
                        ForEach(trips) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .fixedSize()
                }
                Toggle("Needs approval", isOn: $draft.approval).toggleStyle(.checkbox)
                    .help("The entry waits for someone other than you to approve it")
                if let error { Text(error).font(.callout).foregroundStyle(.red) }
            }
        }
    }

    private func enter() async {
        saving = true
        error = await save()
        saving = false
    }
}

struct ExpenseEntrySheet: View {
    let entry: ExpenseEntry
    var lines: [ExpenseLine]
    var trips: [ExpenseTrip]
    var payees: [Payee]
    var save: ([String: Any]) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var kind = "expense"
    @State private var description = ""
    @State private var vendor = ""
    @State private var lineId: Int?
    @State private var tripId: Int?
    @State private var payeeId: Int?
    @State private var amount: Double?
    @State private var recurrence = "none"
    @State private var status = "actual"
    @State private var url = ""
    @State private var notes = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Entry").heading(.heading)
            Text("Entered by \(entry.enteredBy ?? "—")\(entry.updatedBy.map { " · last changed by \($0)" } ?? "") · version \(entry.version)")
                .font(.caption).foregroundStyle(.secondary)
            Form {
                DatePicker("Date", selection: $date, displayedComponents: .date)
                Picker("Kind", selection: $kind) {
                    Text("Item bought").tag("expense"); Text("Refund").tag("refund"); Text("Funding").tag("funding"); Text("Adjustment").tag("adjustment")
                }
                TextField("Item", text: $description)
                if kind == "funding" {
                    Picker("From", selection: $payeeId) {
                        Text("—").tag(Int?.none)
                        ForEach(payees) { Text(TargetPicker.title($0)).tag(Optional($0.id)) }
                    }
                } else {
                    TextField("Vendor", text: $vendor)
                    Picker("Line", selection: $lineId) {
                        Text("None").tag(Int?.none)
                        ForEach(lines) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Picker("Trip", selection: $tripId) {
                        Text("None").tag(Int?.none)
                        ForEach(trips) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Picker("Recurs", selection: $recurrence) { ForEach(ExpenseEntryForm.recurrences, id: \.0) { Text($0.1).tag($0.0) } }
                }
                TextField("Amount", value: $amount, format: .number.precision(.fractionLength(2)))
                Picker("Status", selection: $status) { Text("Made").tag("actual"); Text("Scheduled").tag("scheduled"); Text("Void").tag("void") }
                TextField("Link", text: $url, prompt: Text("https://… (the product, the plan)"))
                TextField("Notes", text: $notes, axis: .vertical).lineLimit(2...5)
            }
            if entry.approval != "none" {
                Label("Approval: \(entry.approval)\(entry.approvedBy.map { " by \($0)" } ?? "") — approve or reject from the register's context menu.", systemImage: "checkmark.seal")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    Task {
                        let body: [String: Any] = [
                            "version": entry.version, "date": isoDay.string(from: date), "kind": kind, "description": description,
                            "vendor": vendor, "lineId": lineId ?? NSNull(), "tripId": tripId ?? NSNull(), "payeeId": payeeId ?? NSNull(),
                            "amount": amount ?? 0, "recurrence": recurrence, "status": status, "url": url, "notes": notes]
                        if let e = await save(body) { error = e } else { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 480)
        .onAppear {
            date = day(entry.date) ?? Date(); kind = entry.kind; description = entry.description; vendor = entry.vendor ?? ""
            lineId = entry.lineId; tripId = entry.tripId; payeeId = entry.payeeId
            amount = entry.kind == "adjustment" ? entry.amount : abs(entry.amount)
            recurrence = entry.recurrence; status = entry.status; url = entry.url ?? ""; notes = entry.notes ?? ""
        }
    }
}

// MARK: - Sheets

struct LedgerSheet: View {
    let ledger: ExpenseLedger?
    var payees: [Payee]
    var save: (String, [String: Any]) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var name = ""
    @State private var purpose = ""
    @State private var owner = "Personal"
    @State private var costCenter = ""
    @State private var openingDate = Date()
    @State private var openingBalance = 0.0
    @State private var budget: Double?
    @State private var fundingPayees = Set<Int>()
    @State private var fundingAmount: Double?
    @State private var fundingDay: Int?
    @State private var closed = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ledger == nil ? "New Expense Account" : "Edit \(ledger!.name)").heading(.heading)
            Form {
                TextField("Code", text: $code).disabled(ledger != nil).help("A short name for it: letters, digits, _ or - (TECH_2026)")
                TextField("Name", text: $name)
                TextField("Purpose", text: $purpose, axis: .vertical).lineLimit(1...3)
                TextField("Whose books", text: $owner).help("Personal, or the company it is kept for")
                TextField("Cost center", text: $costCenter, prompt: Text("the department it is charged to"))
                TextField("Budget", value: $budget, format: .number.precision(.fractionLength(2)))
                DatePicker("Starts", selection: $openingDate, displayedComponents: .date)
                TextField("Unfunded then", value: $openingBalance, format: .number.precision(.fractionLength(2)))
                Section("Funding") {
                    Text("The target accounts whose transfers in the check register fund it: they link to its funding entries.")
                        .font(.caption).foregroundStyle(.secondary)
                    List(payees.filter(\.active)) { p in
                        Toggle(TargetPicker.title(p), isOn: Binding(get: { fundingPayees.contains(p.id) },
                                                                     set: { if $0 { fundingPayees.insert(p.id) } else { fundingPayees.remove(p.id) } }))
                    }
                    .frame(height: 110)
                    TextField("Planned transfer", value: $fundingAmount, format: .number.precision(.fractionLength(2)))
                    TextField("On day", value: $fundingDay, format: .number)
                }
                if ledger != nil { Toggle("Closed", isOn: $closed) }
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(ledger == nil ? "Add" : "Save") {
                    Task {
                        var body: [String: Any] = [
                            "name": name, "purpose": purpose, "owner": owner, "costCenter": costCenter,
                            "openingDate": isoDay.string(from: openingDate), "openingBalance": openingBalance,
                            "budget": budget ?? NSNull(), "fundingPayees": Array(fundingPayees),
                            "fundingAmount": fundingAmount ?? NSNull(), "fundingDay": fundingDay ?? NSNull(),
                            "closedDate": closed ? (ledger?.closedDate ?? isoDay.string(from: Date())) : NSNull()]
                        if let v = ledger?.version { body["version"] = v }
                        if let e = await save(code, body) { error = e } else { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(code.isEmpty || name.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 500)
        .onAppear {
            guard let l = ledger else { return }
            code = l.code; name = l.name; purpose = l.purpose ?? ""; owner = l.owner; costCenter = l.costCenter ?? ""
            openingDate = day(l.openingDate) ?? Date(); openingBalance = l.openingBalance; budget = l.budget
            fundingPayees = Set(l.fundingPayees); fundingAmount = l.fundingAmount; fundingDay = l.fundingDay; closed = l.closedDate != nil
        }
    }
}

struct FundSheet: View {
    let ledger: ExpenseLedger
    var payees: [Payee]
    var fund: ([String: Any]) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var payeeId: Int?
    @State private var date = Date()
    @State private var amount: Double?
    @State private var months = 1
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fund \(ledger.name)").heading(.heading)
            Form {
                Picker("From", selection: $payeeId) {
                    ForEach(payees.filter { ledger.fundingPayees.contains($0.id) || $0.active }) { Text(TargetPicker.title($0)).tag(Optional($0.id)) }
                }
                DatePicker("First transfer", selection: $date, displayedComponents: .date)
                TextField("Amount", value: $amount, format: .number.precision(.fractionLength(2)))
                Stepper("\(months) transfer\(months == 1 ? "" : "s"), a month apart", value: $months, in: 1...36)
            }
            Text("Transfers after today are scheduled: they count toward the projected balance until made. A transfer already in the check register links to its entry by itself.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Fund") {
                    Task {
                        var body: [String: Any] = ["date": isoDay.string(from: date), "amount": amount ?? 0, "months": months]
                        if let payeeId { body["payeeId"] = payeeId }
                        if let e = await fund(body) { error = e } else { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction).disabled((amount ?? 0) <= 0)
            }
        }
        .padding(18)
        .frame(width: 440)
        .onAppear {
            payeeId = ledger.fundingPayees.first
            amount = ledger.fundingAmount
            if let d = ledger.fundingDay {
                var c = Calendar.current.dateComponents([.year, .month], from: Date())
                c.day = d
                if let next = Calendar.current.date(from: c) {
                    date = next < Calendar.current.startOfDay(for: Date()) ? Calendar.current.date(byAdding: .month, value: 1, to: next)! : next
                }
            }
        }
    }
}

struct CardChargesSheet: View {
    let code: String
    var lines: [ExpenseLine]
    var add: ([String: Any]) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var charges: [CardCharge] = []
    @State private var chosen = Set<CardCharge.ID>()
    @State private var lineId: Int?
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Card Charges").heading(.heading)
            Text("Charges from Credit Card Accounts in the last year that no expense account has yet. Each is added once, linked to its charge.")
                .font(.callout).foregroundStyle(.secondary)
            if loading { ProgressView() }
            Table(charges, selection: $chosen) {
                TableColumn("Date") { c in Text(shortDay(c.date)).monospacedDigit() }.width(min: 70, ideal: 84)
                TableColumn("Card") { c in Text(c.card).foregroundStyle(.secondary) }.width(min: 80, ideal: 120)
                TableColumn("Payee") { c in Text(c.payee ?? "—") }.width(min: 120, ideal: 200)
                TableColumn("Category") { c in Text(c.expenseAccount ?? "").foregroundStyle(.secondary) }.width(min: 60, ideal: 110)
                TableColumn("Amount") { c in Text(money2(c.amount)).monospacedDigit() }.width(min: 60, ideal: 80)
            }
            .tableText()
            .frame(height: 280)
            Picker("On line", selection: $lineId) {
                Text("None").tag(Int?.none)
                ForEach(lines) { Text($0.name).tag(Optional($0.id)) }
            }
            .fixedSize()
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add \(chosen.count)") {
                    Task {
                        for c in charges where chosen.contains(c.id) {
                            let body: [String: Any] = ["date": c.date, "kind": c.amount < 0 ? "refund" : "expense",
                                                       "description": c.payee ?? c.memo ?? "Card charge", "vendor": c.payee ?? "",
                                                       "lineId": lineId ?? NSNull(), "amount": abs(c.amount), "cardTxnId": c.id]
                            if let e = await add(body) { error = e; return }
                        }
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction).disabled(chosen.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 640)
        .task {
            do { charges = try await ExpenseClient.cardCharges(code) } catch { self.error = describe(error) }
            loading = false
        }
    }
}

struct LineSheet: View {
    let line: ExpenseLine?
    var expenseAccounts: [ExpenseAccount]
    var save: ([String: Any]) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind = "other"
    @State private var budget: Double?
    @State private var expenseAccountId: Int?
    @State private var color = Color.accentColor
    @State private var sortOrder = 100
    @State private var active = true
    @State private var error: String?

    static let kinds = ["equipment", "software", "facilities", "training", "travel", "subscriptions", "other"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(line == nil ? "New Budget Line" : "Edit \(line!.name)").heading(.heading)
            Form {
                TextField("Name", text: $name)
                Picker("Kind", selection: $kind) { ForEach(Self.kinds, id: \.self) { Text($0).tag($0) } }
                TextField("Budget", value: $budget, format: .number.precision(.fractionLength(2)))
                Picker("Category", selection: $expenseAccountId) {
                    Text("None").tag(Int?.none)
                    ForEach(expenseAccounts) { Text($0.name).tag(Optional($0.id)) }
                }
                .help("The expense account (category) the line rolls up to")
                ColorPicker("Colour", selection: $color, supportsOpacity: false)
                TextField("Order", value: $sortOrder, format: .number)
                Toggle("Active", isOn: $active)
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(line == nil ? "Add" : "Save") {
                    Task {
                        let body: [String: Any] = ["name": name, "kind": kind, "budget": budget ?? NSNull(),
                                                   "expenseAccountId": expenseAccountId ?? NSNull(), "color": hex(color),
                                                   "sortOrder": sortOrder, "active": active]
                        if let e = await save(body) { error = e } else { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction).disabled(name.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 420)
        .onAppear {
            guard let l = line else { return }
            name = l.name; kind = l.kind; budget = l.budget; expenseAccountId = l.expenseAccountId
            color = Color(hex: l.color) ?? .accentColor; sortOrder = l.sortOrder; active = l.active
        }
    }

    private func hex(_ c: Color) -> String {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? .gray
        return String(format: "#%02X%02X%02X", Int(n.redComponent * 255), Int(n.greenComponent * 255), Int(n.blueComponent * 255))
    }
}

struct AssetSheet: View {
    let asset: ExpenseAsset?
    var entries: [ExpenseEntry]
    var save: ([String: Any]) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var tag = ""
    @State private var serialNo = ""
    @State private var location = ""
    @State private var assignedTo = ""
    @State private var entryId: Int?
    @State private var inService: Date?
    @State private var cost: Double?
    @State private var life: Int?
    @State private var salvage = 0.0
    @State private var method = "straight-line"
    @State private var warrantyEnd: Date?
    @State private var warrantyEntryId: Int?
    @State private var status = "in service"
    @State private var notes = ""
    @State private var error: String?

    private var purchases: [ExpenseEntry] { entries.filter { $0.kind == "expense" && $0.status != "void" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(asset == nil ? "New Asset" : "Edit \(asset!.name)").heading(.heading)
            Form {
                TextField("Name", text: $name)
                Picker("Bought as", selection: $entryId) {
                    Text("None").tag(Int?.none)
                    ForEach(purchases) { e in Text("\(shortDay(e.date))  \(e.description)  \(money2(e.amount))").tag(Optional(e.id)) }
                }
                .onChange(of: entryId) {
                    guard let e = purchases.first(where: { $0.id == entryId }) else { return }
                    if name.isEmpty { name = e.description }
                    if cost == nil { cost = e.amount }
                    if inService == nil { inService = day(e.date) }
                }
                TextField("Tag", text: $tag)
                TextField("Serial number", text: $serialNo)
                TextField("Location", text: $location)
                TextField("Assigned to", text: $assignedTo)
                OptionalDate(label: "In service", date: $inService)
                TextField("Cost", value: $cost, format: .number.precision(.fractionLength(2)))
                TextField("Useful life (months)", value: $life, format: .number)
                TextField("Salvage value", value: $salvage, format: .number.precision(.fractionLength(2)))
                Picker("Depreciation", selection: $method) { Text("Straight-line").tag("straight-line"); Text("Declining balance").tag("declining-balance") }
                OptionalDate(label: "Warranty ends", date: $warrantyEnd)
                Picker("Warranty plan", selection: $warrantyEntryId) {
                    Text("None").tag(Int?.none)
                    ForEach(purchases) { e in Text("\(shortDay(e.date))  \(e.description)").tag(Optional(e.id)) }
                }
                Picker("Status", selection: $status) { ForEach(["in service", "in repair", "retired", "disposed"], id: \.self) { Text($0).tag($0) } }
                TextField("Notes", text: $notes, axis: .vertical).lineLimit(1...4)
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(asset == nil ? "Add" : "Save") {
                    Task {
                        var body: [String: Any] = [
                            "name": name, "tag": tag, "serialNo": serialNo, "location": location, "assignedTo": assignedTo,
                            "entryId": entryId ?? NSNull(), "inService": iso(inService), "cost": cost ?? 0,
                            "usefulLifeMonths": life ?? NSNull(), "salvage": salvage, "method": method,
                            "warrantyEnd": iso(warrantyEnd), "warrantyEntryId": warrantyEntryId ?? NSNull(), "status": status,
                            "disposedDate": status == "disposed" ? (asset?.disposedDate ?? isoDay.string(from: Date())) : NSNull(),
                            "notes": notes]
                        if let v = asset?.version { body["version"] = v }
                        if let e = await save(body) { error = e } else { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction).disabled(name.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 480)
        .onAppear {
            guard let a = asset else { return }
            name = a.name; tag = a.tag ?? ""; serialNo = a.serialNo ?? ""; location = a.location ?? ""; assignedTo = a.assignedTo ?? ""
            entryId = a.entryId; inService = day(a.inService); cost = a.cost; life = a.usefulLifeMonths; salvage = a.salvage
            method = a.method; warrantyEnd = day(a.warrantyEnd); warrantyEntryId = a.warrantyEntryId; status = a.status; notes = a.notes ?? ""
        }
    }
}

struct TrainingSheet: View {
    let record: TrainingRecord?
    var entries: [ExpenseEntry]
    var save: ([String: Any]) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var course = ""
    @State private var provider = ""
    @State private var person = ""
    @State private var kind = "course"
    @State private var entryId: Int?
    @State private var start: Date?
    @State private var end: Date?
    @State private var hours: Double?
    @State private var status = "enrolled"
    @State private var certificate: Date?
    @State private var notes = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(record == nil ? "New Training" : "Edit \(record!.course)").heading(.heading)
            Form {
                TextField("Course", text: $course)
                TextField("Provider", text: $provider)
                TextField("Who", text: $person)
                Picker("Kind", selection: $kind) { ForEach(["course", "subscription", "lessons", "conference", "certification"], id: \.self) { Text($0).tag($0) } }
                Picker("Paid as", selection: $entryId) {
                    Text("None").tag(Int?.none)
                    ForEach(entries.filter { $0.kind == "expense" && $0.status != "void" }) { e in Text("\(shortDay(e.date))  \(e.description)  \(money2(e.amount))").tag(Optional(e.id)) }
                }
                OptionalDate(label: "Starts", date: $start)
                OptionalDate(label: "Ends", date: $end)
                TextField("Hours", value: $hours, format: .number.precision(.fractionLength(1)))
                Picker("Status", selection: $status) { ForEach(["planned", "enrolled", "in progress", "completed", "dropped"], id: \.self) { Text($0).tag($0) } }
                OptionalDate(label: "Certificate expires", date: $certificate)
                TextField("Notes", text: $notes, axis: .vertical).lineLimit(1...4)
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(record == nil ? "Add" : "Save") {
                    Task {
                        var body: [String: Any] = [
                            "course": course, "provider": provider, "person": person, "kind": kind, "entryId": entryId ?? NSNull(),
                            "startDate": iso(start), "endDate": iso(end), "hours": hours ?? NSNull(), "status": status,
                            "certificateExpires": iso(certificate), "notes": notes]
                        if let v = record?.version { body["version"] = v }
                        if let e = await save(body) { error = e } else { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction).disabled(course.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 460)
        .onAppear {
            guard let t = record else { return }
            course = t.course; provider = t.provider ?? ""; person = t.person ?? ""; kind = t.kind; entryId = t.entryId
            start = day(t.startDate); end = day(t.endDate); hours = t.hours; status = t.status; certificate = day(t.certificateExpires); notes = t.notes ?? ""
        }
    }
}

struct TripSheet: View {
    let trip: ExpenseTrip?
    var save: ([String: Any]) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var traveler = ""
    @State private var destination = ""
    @State private var purpose = ""
    @State private var depart: Date?
    @State private var back: Date?
    @State private var meals: Double?
    @State private var lodging: Double?
    @State private var status = "planned"
    @State private var notes = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(trip == nil ? "New Trip" : "Edit \(trip!.name)").heading(.heading)
            Form {
                TextField("Trip", text: $name)
                TextField("Traveler", text: $traveler)
                TextField("Destination", text: $destination)
                TextField("Purpose", text: $purpose, axis: .vertical).lineLimit(1...3)
                OptionalDate(label: "Departs", date: $depart)
                OptionalDate(label: "Returns", date: $back)
                TextField("Meals & incidentals a day", value: $meals, format: .number.precision(.fractionLength(2)))
                TextField("Lodging a night", value: $lodging, format: .number.precision(.fractionLength(2)))
                Picker("Status", selection: $status) { ForEach(["planned", "booked", "completed", "cancelled"], id: \.self) { Text($0).tag($0) } }
                TextField("Notes", text: $notes, axis: .vertical).lineLimit(1...4)
            }
            Text("Per-diem rates as your policy sets them (the GSA's CONUS rates are a common choice).").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(trip == nil ? "Add" : "Save") {
                    Task {
                        var body: [String: Any] = [
                            "name": name, "traveler": traveler, "destination": destination, "purpose": purpose,
                            "departDate": iso(depart), "returnDate": iso(back), "perDiemMeals": meals ?? NSNull(),
                            "perDiemLodging": lodging ?? NSNull(), "status": status, "notes": notes]
                        if let v = trip?.version { body["version"] = v }
                        if let e = await save(body) { error = e } else { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction).disabled(name.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 460)
        .onAppear {
            guard let t = trip else { return }
            name = t.name; traveler = t.traveler ?? ""; destination = t.destination ?? ""; purpose = t.purpose ?? ""
            depart = day(t.departDate); back = day(t.returnDate); meals = t.perDiemMeals; lodging = t.perDiemLodging
            status = t.status; notes = t.notes ?? ""
        }
    }
}

/// A date that may be left empty: a checkbox turns it on.
struct OptionalDate: View {
    var label: String
    @Binding var date: Date?

    var body: some View {
        HStack {
            Toggle(label, isOn: Binding(get: { date != nil }, set: { date = $0 ? (date ?? Date()) : nil }))
            if date != nil {
                DatePicker("", selection: Binding(get: { date ?? Date() }, set: { date = $0 }), displayedComponents: .date)
                    .labelsHidden().fixedSize()
            }
        }
    }
}
