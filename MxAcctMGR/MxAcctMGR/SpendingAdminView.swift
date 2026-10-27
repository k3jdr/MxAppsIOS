//
//  SpendingAdminView.swift
//  MxAcctMGR
//
//  Spending Analysis ▸ Admin: the expense accounts, and guidance and tools for the two relationships the analysis
//  rests on.
//
//  * Expense accounts: every one with its description, its rule and this year's spending, to add, edit, re-rule or
//    remove (SpendingExpenseAccounts.swift's sheets, as on Rules).
//  * Driver and category: two dimensions on every dollar, set by the same rules. The guide says what each means, where
//    they come from and what each driver counts as; the Category × Driver table shows this year's spending in both, a
//    click on a cell shows what put its entries there, with Rule… to change it.
//  * Target accounts and expense ledgers: who was paid, and what it was for. One purchase can be in both — a card
//    charge to a target account and an entry in a ledger — and counts twice unless the entry is linked to the charge.
//    The overlap finder lists the ledger entries that match an unlinked card charge or check (the accounts service's
//    GET /spending/overlaps) and links them (POST /expense-entries/<id>/link).
//

import SwiftUI

struct SpendingAdminTab: View {
    var setup: SpendingSetup
    var data: SpendingAnalysisData
    /// Both periods' entries, of the registers in the analysis.
    var entries: [SpendingEntry]
    /// Opens another Spending Analysis tab (rules, entries, sources).
    var openTab: (String) -> Void
    /// Opens another screen (Expense Ledgers, Target Accounts).
    var go: (Screen) -> Void
    var ruleSaved: (SpendingSetup) -> Void
    /// A ledger entry was linked: the analysis is read again.
    var linked: () -> Void

    var body: some View {
        ExpenseAccountsAdmin(setup: setup, data: data, entries: entries, ruleSaved: ruleSaved)
        DriverCategoryGuide(setup: setup, data: data, entries: entries, openTab: openTab, ruleSaved: ruleSaved)
        LedgerTargetGuide(entries: entries, openTab: openTab, go: go, linked: linked)
    }
}

// MARK: - Expense accounts

/// The expense accounts with Edit…, Rule… and Remove… on each, and New Expense Account….
private struct ExpenseAccountsAdmin: View {
    var setup: SpendingSetup
    var data: SpendingAnalysisData
    var entries: [SpendingEntry]
    var ruleSaved: (SpendingSetup) -> Void
    /// New (.some(nil)) or Edit (.some(account)).
    @State private var editing: SpendingSetup.Named??
    @State private var removing: SpendingSetup.Named?
    @State private var ruleFor: RuleTarget?

    var body: some View {
        var now: [Int: (amount: Double, count: Int)] = [:]
        for e in entries where e.date >= data.start && e.date <= data.end {
            guard let id = e.expenseAccountId else { continue }
            now[id, default: (0, 0)].amount += e.amount
            now[id, default: (0, 0)].count += 1
        }
        return Box(title: "Expense Accounts", symbol: "folder", help: "The bookkeeping categories the card and checking registers, target accounts and expense-ledger lines file entries under. Each has a rule that puts its entries in a spending category (Rule…). Edit… renames one or changes its description; Remove… moves what files under it to another first.") {
            HStack {
                Button("New Expense Account…") { editing = .some(nil) }
                Spacer()
                Text("\(setup.expenseAccounts.count) expense accounts").foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                GridRow {
                    Text("Expense account"); Text("Its rule"); Text("This year").gridColumnAlignment(.trailing)
                    Text("Entries").gridColumnAlignment(.trailing); Text("")
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(setup.expenseAccounts) { a in
                    let spent = now[a.id]
                    GridRow {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(a.name)
                            if let d = a.description, !d.isEmpty { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        Text(ruleText(a)).foregroundStyle(setup.rule(expenseAccount: a.id)?.category == nil ? .orange : .secondary).lineLimit(1)
                        Text(money(spent?.amount ?? 0)).monospacedDigit()
                        Text("\(spent?.count ?? 0)").monospacedDigit().foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            Button("Edit…") { editing = .some(a) }
                            Button("Rule…") { ruleFor = RuleTarget(expenseAccountId: a.id, name: a.name) }
                            Button("Remove…") { removing = a }
                        }
                        .controlSize(.small)
                    }
                }
            }
            .font(.callout)
        }
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            ExpenseAccountEditor(setup: setup, account: editing ?? nil) { ruleSaved($0) }
        }
        .sheet(item: $removing) { a in RemoveExpenseAccountSheet(setup: setup, account: a) { ruleSaved($0) } }
        .sheet(item: $ruleFor) { t in SpendingRuleSheet(setup: setup, target: t, entries: entries) { ruleSaved($0) } }
    }

    private func ruleText(_ a: SpendingSetup.Named) -> String {
        guard let r = setup.rule(expenseAccount: a.id) else { return "No rule: its entries are Not assigned" }
        return [setup.category(r.category)?.name ?? "No category", r.driver.map { SpendingDriver.title($0) }, setup.member(r.memberId)?.name]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - Driver and category

private struct DriverCategoryGuide: View {
    var setup: SpendingSetup
    var data: SpendingAnalysisData
    var entries: [SpendingEntry]
    var openTab: (String) -> Void
    var ruleSaved: (SpendingSetup) -> Void
    @State private var cell: Cell?
    @State private var ruleFor: RuleTarget?

    /// A Category × Driver cell: a category code (or Not assigned) and a driver (or "" for none).
    struct Cell: Hashable {
        var category: String
        var driver: String
    }

    private var current: [SpendingEntry] { entries.filter { $0.date >= data.start && $0.date <= data.end } }

    var body: some View {
        Box(title: "Driver & Category", symbol: "square.grid.3x3", help: "How the two dimensions of every dollar relate, and where they are set.") {
            HStack(alignment: .top, spacing: 14) {
                AdminCard(title: "Category: what the money bought", symbol: "cart",
                          text: "Food, Housing, Transportation, Education, Activities, Technology, Healthcare, Clothing, Travel or Other. Each category follows its own consumer price index (Sources), so the category decides how much of a change is inflation.")
                AdminCard(title: "Driver: why the spending changed", symbol: "arrow.up.right",
                          text: "Family Growth, New Activity, Lifecycle Transition, Preference Change, Lifestyle & Hobbies, One-Time Event, Taxes or Inflation. The driver decides which effect the growth beyond inflation counts as; with no driver it counts as Usage.")
            }
            Text("They are independent: any category can have any driver. Food can grow with Family Growth, Activities with Lifestyle & Hobbies, Housing with Taxes. Each entry gets its category and its driver separately, from the first of these that sets it:")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 3) {
                Text("1. The entry's own tag (Entries: double-click, or select several and right-click).")
                Text("2. Its target account's rule (Rules ▸ Target Account Rules).")
                Text("3. The longest statement text rule its payee or description contains (Rules ▸ Statement Text Rules).")
                Text("4. Its expense account's rule (Rules ▸ Expense Account Rules): the default for everything filed there.")
            }
            .font(.callout).padding(.leading, 8)
            Text("So a target account's rule can set only the driver and leave the category to the expense account's rule, or the other way round.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            driverTable
            HStack {
                Button("Open Rules") { openTab("rules") }
                Button("Open Entries") { openTab("entries") }
            }
        }
        matrix
            .sheet(item: $ruleFor) { t in SpendingRuleSheet(setup: setup, target: t, entries: entries) { ruleSaved($0) } }
    }

    private var driverTable: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
            GridRow { Text("Driver"); Text("Counts as"); Text("For") }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(SpendingDriver.allCases) { d in
                GridRow {
                    Text(d.title)
                    Text(d.effect.rawValue).foregroundStyle(d.effect.color)
                    Text(d.help).foregroundStyle(.secondary).lineLimit(1).help(d.help)
                }
            }
            GridRow {
                Text("No driver").foregroundStyle(.secondary)
                Text(SpendingEffect.usage.rawValue).foregroundStyle(SpendingEffect.usage.color)
                Text("No rule or tag gives it one").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    // MARK: The matrix

    private static let short: [SpendingDriver: String] = [.inflation: "Inflation", .familyGrowth: "Family Growth", .newActivity: "New Activity",
                                                         .lifecycle: "Lifecycle", .preference: "Preference", .lifestyle: "Lifestyle",
                                                         .oneTime: "One-Time", .taxes: "Taxes"]

    private var matrix: some View {
        let rows = current
        var sums: [Cell: Double] = [:]
        for e in rows { sums[Cell(category: e.category ?? SpendingEngine.unassigned, driver: e.driver ?? ""), default: 0] += e.amount }
        let codes = setup.categories.map(\.code).filter { c in sums.keys.contains { $0.category == c } }
            + (sums.keys.contains { $0.category == SpendingEngine.unassigned } ? [SpendingEngine.unassigned] : [])
        let drivers = SpendingDriver.allCases.map(\.rawValue) + [""]
        let gaps = rows.filter { $0.driver == nil || $0.category == nil }.map(\.amount).reduce(0, +)
        return Box(title: "This Year: Category × Driver", symbol: "tablecells",
                   help: "This year's spending by category (rows) and driver (columns), in the registers the analysis includes. Orange: spending with no driver (it counts as Usage) or no category. Click a cell to see what put its entries there and change it.") {
            Text(gaps > 0.5 ? "\(money(gaps)) of this year's \(money(rows.map(\.amount).reduce(0, +))) has no driver or no category (orange). Click a cell to see why, and Rule… to give it one."
                 : "Every dollar this year has a category and a driver.")
                .font(.callout).foregroundStyle(gaps > 0.5 ? .orange : .secondary)
            ScrollView(.horizontal) {
                Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 3) {
                    GridRow {
                        Text("Category").gridColumnAlignment(.leading)
                        ForEach(drivers, id: \.self) { d in Text(SpendingDriver(rawValue: d).flatMap { Self.short[$0] } ?? "No driver") }
                        Text("Total")
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(codes, id: \.self) { code in
                        GridRow {
                            Text(setup.category(code)?.name ?? "Not assigned").foregroundStyle(code == SpendingEngine.unassigned ? .orange : .primary)
                            ForEach(drivers, id: \.self) { d in cellButton(Cell(category: code, driver: d), sums[Cell(category: code, driver: d)] ?? 0) }
                            Text(money(drivers.map { sums[Cell(category: code, driver: $0)] ?? 0 }.reduce(0, +))).foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.callout).monospacedDigit()
                .padding(.bottom, 4)
            }
            if let cell { cellDetail(cell) }
        }
    }

    private func cellButton(_ c: Cell, _ amount: Double) -> some View {
        let gap = c.driver.isEmpty || c.category == SpendingEngine.unassigned
        return Button { cell = cell == c ? nil : c } label: {
            Text(abs(amount) < 0.5 ? "" : money(amount))
                .foregroundStyle(gap && abs(amount) >= 0.5 ? .orange : .primary)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(cell == c ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(abs(amount) < 0.5)
        .help(abs(amount) < 0.5 ? "" : "Show what put these entries here")
    }

    // MARK: A cell's entries

    /// What set an entry's category or driver: the kind of rule (or tag), its name, and the rule to open.
    private struct Origin: Hashable {
        var kind: String
        var label: String
        var target: String?
    }

    private func origin(_ e: SpendingEntry, from kind: String?) -> (Origin, RuleTarget?) {
        switch kind {
        case "expense account":
            let t = e.expenseAccountId.map { RuleTarget(expenseAccountId: $0, name: e.expenseAccount ?? "") }
            return (Origin(kind: "expense account rule", label: e.expenseAccount ?? "—", target: t?.id), t)
        case "target account":
            let t = e.payeeId.map { RuleTarget(payeeId: $0, name: e.payee ?? "") }
            return (Origin(kind: "target account rule", label: e.payee ?? "—", target: t?.id), t)
        case "statement text":
            let text = e.rulePattern ?? ""
            let t = RuleTarget(pattern: text, ruleId: setup.rule(pattern: text)?.id, name: text)
            return (Origin(kind: "statement text rule", label: text, target: t.id), t)
        case "entry":
            return (Origin(kind: "the entry's own tag", label: "Tagged on the entry", target: nil), nil)
        default:
            // Nothing sets it: offer the rule most likely to — the expense account's, else the target account's,
            // else a statement text rule for its words.
            let t = e.expenseAccountId.map { RuleTarget(expenseAccountId: $0, name: e.expenseAccount ?? "") }
                ?? e.payeeId.map { RuleTarget(payeeId: $0, name: e.payee ?? "") }
                ?? RuleTarget(pattern: e.statementKey, name: e.statementKey)
            return (Origin(kind: "no rule or tag", label: e.expenseAccount.map { "\($0) (its rule sets none)" } ?? "Nothing sets it", target: t.id), t)
        }
    }

    private func cellDetail(_ c: Cell) -> some View {
        let mine = current.filter { ($0.category ?? SpendingEngine.unassigned) == c.category && ($0.driver ?? "") == c.driver }
        var groups: [String: (cat: Origin, drv: Origin, targets: [RuleTarget], entries: [SpendingEntry])] = [:]
        for e in mine {
            let (co, ct) = origin(e, from: e.categoryFrom), (dO, dt) = origin(e, from: e.driverFrom)
            let key = "\(co.kind)|\(co.label)|\(dO.kind)|\(dO.label)"
            var g = groups[key] ?? (co, dO, [], [])
            for t in [ct, dt].compactMap({ $0 }) where !g.targets.contains(where: { $0.id == t.id }) { g.targets.append(t) }
            g.entries.append(e)
            groups[key] = g
        }
        let list = groups.values.sorted { $0.entries.map(\.amount).reduce(0, +) > $1.entries.map(\.amount).reduce(0, +) }
        let name = setup.category(c.category)?.name ?? "Not assigned"
        let driver = SpendingDriver.title(c.driver.isEmpty ? nil : c.driver)
        return VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("\(name) × \(c.driver.isEmpty ? "No driver" : driver): \(money(mine.map(\.amount).reduce(0, +))) in \(mine.count) \(mine.count == 1 ? "entry" : "entries") this year")
                .heading(.name)
            if c.driver.isEmpty {
                Text("No rule or tag gives these a driver, so their growth counts as Usage. Rule… opens the rule that put them here: pick a driver there, or tag single entries on Entries.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    Text("Category from"); Text("Driver from"); Text("This year").gridColumnAlignment(.trailing); Text("Entries").gridColumnAlignment(.trailing); Text("")
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Array(list.enumerated()), id: \.offset) { _, g in
                    GridRow {
                        originText(g.cat)
                        originText(g.drv)
                        Text(money(g.entries.map(\.amount).reduce(0, +))).monospacedDigit()
                        Text("\(g.entries.count)").monospacedDigit().foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            ForEach(g.targets) { t in
                                Button(g.targets.count > 1 ? "Rule for \(t.name.isEmpty ? "it" : t.name)…" : "Rule…") { ruleFor = t }.controlSize(.small)
                            }
                        }
                    }
                }
            }
            .font(.callout)
            let top = mine.sorted { $0.amount > $1.amount }.prefix(8)
            Text("Largest").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                ForEach(Array(top)) { e in
                    GridRow {
                        Text(shortDay(e.date)).monospacedDigit().foregroundStyle(.secondary)
                        Text(e.payee ?? e.description ?? "—").lineLimit(1)
                        Text(e.register ?? e.sourceTitle).foregroundStyle(.secondary)
                        Text(money2(e.amount)).monospacedDigit().gridColumnAlignment(.trailing)
                    }
                }
            }
            .font(.callout)
        }
    }

    private func originText(_ o: Origin) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(o.label).lineLimit(1)
            Text(o.kind).font(.caption).foregroundStyle(o.kind == "no rule or tag" ? .orange : .secondary)
        }
    }
}

// MARK: - Target accounts and expense ledgers

private struct LedgerTargetGuide: View {
    var entries: [SpendingEntry]
    var openTab: (String) -> Void
    var go: (Screen) -> Void
    var linked: () -> Void
    @State private var overlaps: [SpendingOverlap]?
    /// The match picked for each entry (index into its matches); the nearest by default.
    @State private var picked: [Int: Int] = [:]
    @State private var busy = false
    @State private var confirmAll = false
    @State private var problem: String?

    var body: some View {
        Box(title: "Target Accounts & Expense Ledgers", symbol: "arrow.triangle.branch", help: "How a purchase is recorded as a payment to someone and as an item bought for a purpose, and how to keep it from counting twice.") {
            HStack(alignment: .top, spacing: 14) {
                AdminCard(title: "Target account: who was paid", symbol: "arrow.left.arrow.right.square",
                          text: "Every check and card charge names the account the money went to (Banking ▸ Target Accounts), filed under an expense account. Discover's charges carry only the statement's words (APPLE.COM/US 800-692-7753) and have no target account.")
                AdminCard(title: "Expense ledger: what it was for", symbol: "briefcase",
                          text: "A funded budget for a purpose (Banking ▸ Expense Ledgers): Mac, Software & Home Office 2026, each item on a budget line (Mac & Software, Home Office Desk Buildout), with the transfers that fund it.")
            }
            Text("One purchase can be in both: the MacBook charged on Discover to APPLE.COM/US is also the ledger's \u{201C}Mac Book Pro\u{201D}. When the ledger entry is linked to the charge or check that paid it (Add from Card Charges on the ledger, or Link below), Spending Analysis counts the purchase once, as the charge, with the charge's rules. A ledger entry with no link is spending of its own, so while its ledger is in the analysis (Sources) the purchase counts twice.")
                .fixedSize(horizontal: false, vertical: true)
            Text("A linked entry shows a card or bank mark in the ledger's register. Linking changes nothing in the ledger's balance: the item is still bought on its budget line.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open Expense Ledgers") { go(.expenseLedgers) }
                Button("Open Target Accounts") { go(.expenses) }
                Button("Open Sources") { openTab("sources") }
            }
        }
        finder
            .task { await load() }
    }

    // MARK: The overlap finder

    private var finder: some View {
        let list = overlaps ?? []
        let inAnalysis = Set(entries.filter { $0.source == "ledger" }.compactMap(\.register))
        let twiceNow = list.filter { inAnalysis.contains($0.ledger) }
        return Box(title: "Counted Twice: Ledger Entries That Match a Card Charge or Check", symbol: "link",
                   help: "Expense-ledger entries not linked to a card charge or check that match one: the same amount within a week, the charge or check linked to no entry yet. Link counts the purchase once, as the charge; check the match first — the same amount can be a different purchase.") {
            if let problem { Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
            if overlaps == nil {
                ProgressView().controlSize(.small)
            } else if list.isEmpty {
                Text("No ledger entry matches an unlinked card charge or check: nothing counts twice.").foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("\(list.count) \(list.count == 1 ? "entry" : "entries"), \(money(list.map(\.amount).reduce(0, +))): "
                         + (twiceNow.isEmpty ? "their ledgers are left out of the analysis now, so they count twice only once included."
                            : "\(money(twiceNow.map(\.amount).reduce(0, +))) of it counts twice in the analysis now."))
                        .foregroundStyle(twiceNow.isEmpty ? Color.secondary : .orange)
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    Button("Link All \(list.count)…") { confirmAll = true }.disabled(busy)
                }
                .font(.callout)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("Ledger"); Text("Date"); Text("Item"); Text("Amount").gridColumnAlignment(.trailing); Text("Matches"); Text("")
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(list) { o in row(o) }
                }
                .font(.callout)
            }
        }
        .confirmationDialog("Link \(list.count) ledger entries to their card charges and checks?", isPresented: $confirmAll, titleVisibility: .visible) {
            Button("Link All \(list.count)") { Task { await linkAll(list) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Each entry is linked to the match shown on its row. Linked, each purchase counts once in Spending Analysis, as the card charge or check. To undo a link, Void the ledger entry and Restore it.")
        }
    }

    private func row(_ o: SpendingOverlap) -> some View {
        let i = min(picked[o.entryId] ?? 0, o.matches.count - 1)
        return GridRow {
            Text(o.ledger).foregroundStyle(.secondary)
            Text(shortDay(o.date)).monospacedDigit()
            Text([o.vendor, o.description].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")).lineLimit(1)
            Text(money2(o.amount)).monospacedDigit()
            if o.matches.count > 1 {
                Picker("", selection: Binding(get: { i }, set: { picked[o.entryId] = $0 })) {
                    ForEach(Array(o.matches.enumerated()), id: \.offset) { n, m in Text(matchText(m)).tag(n) }
                }
                .labelsHidden().frame(maxWidth: 360)
            } else {
                Text(matchText(o.matches[i])).lineLimit(1).foregroundStyle(.secondary)
            }
            Button("Link") { Task { await link(o, o.matches[i]) } }.controlSize(.small).disabled(busy)
                .help("Link this entry to \(o.matches[i].payee ?? "the charge"): the purchase counts once")
        }
    }

    private func matchText(_ m: SpendingOverlap.Match) -> String {
        let when = m.days == 0 ? "same day" : "\(m.days) day\(m.days == 1 ? "" : "s") apart"
        return "\(m.register) \(shortDay(m.txnDate)) \(m.payee ?? "—") (\(when))"
    }

    private func load() async {
        do { overlaps = try await SpendingClient.overlaps(); problem = nil } catch { problem = describe(error) }
    }

    private func link(_ o: SpendingOverlap, _ m: SpendingOverlap.Match) async {
        busy = true
        defer { busy = false }
        do {
            try await SpendingClient.link(o, to: m)
            problem = nil
        } catch { problem = describe(error) }
        await load()
        linked()
    }

    private func linkAll(_ list: [SpendingOverlap]) async {
        busy = true
        defer { busy = false }
        var failed: [String] = []
        for o in list {
            let m = o.matches[min(picked[o.entryId] ?? 0, o.matches.count - 1)]
            do { try await SpendingClient.link(o, to: m) } catch { failed.append("\(o.description): \(describe(error))") }
        }
        problem = failed.isEmpty ? nil : "Not linked — " + failed.joined(separator: "; ")
        await load()
        linked()
    }
}

// MARK: - Shared

/// One side of a relationship: a title with its symbol and what it means.
private struct AdminCard: View {
    var title: String
    var symbol: String
    var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(.callout.weight(.semibold))
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}
