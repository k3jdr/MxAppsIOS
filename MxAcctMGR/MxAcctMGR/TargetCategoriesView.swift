//
//  TargetCategoriesView.swift
//  MxAcctMGR
//
//  Banking ▸ Target Categories: the one list of spending categories across every account, the card companies' categories
//  mapped to them, the spending drivers, and a guide to how spending is allocated. The year is Spending Analysis's; the
//  figures count every register, as nothing here compares one year with another.
//
//  * Spending categories (V047, V061): every one with what each checking account and credit card spent in it this year
//    and what sets it, to add, edit, remove or put in order (SpendingCategoriesDrivers.swift's sheets). Right-click one
//    for the transactions behind it.
//  * Card company categories (V061): what a new card line's target account takes when it has no category.
//  * Spending drivers (V047): the same for why spending changed.
//  * Driver and category: two dimensions on every dollar, allocated on target accounts (V052) and overridden by an
//    entry's own tag. The Category × Driver table shows this year's spending in both; a click on a cell shows which
//    target accounts put its entries there, with Allocate… to change one.
//

import SwiftUI

struct TargetCategoriesView: View {
    @Bindable var store: PortStore
    @AppStorage("spendingYear") private var year = Calendar.current.component(.year, from: .now)
    @AppStorage("spendingYTD") private var yearToDate = true
    /// The Spending Analysis tab the guide's buttons open.
    @AppStorage("spendingTab") private var spendingTab = "attribution"
    @State private var setup: SpendingSetup?
    @State private var data: SpendingAnalysisData?
    @State private var cardCategories: [CardCategory] = []
    @State private var problem: String?
    @State private var busy = false

    private static let thisYear = Calendar.current.component(.year, from: .now)

    var body: some View {
        StepPage(store: store, subtitle: "One list of categories across every checking account, credit card and cash ledger: what the money bought, with the drivers of why it changed.", lesson: [
            "Every payment to a target account takes the target account's category, set on Target Accounts or Spending Analysis ▸ Allocation, unless the entry has a tag of its own. So a category adds up the same on every register, here and on Spending Analysis.",
            "Each category follows a consumer price index, which decides how much of its change is inflation. Removing one moves what is in it to another. A card company's own category gives a new target account its category until you choose one.",
        ], scrollsHorizontally: true, widest: .infinity) {
            HStack(spacing: 12) {
                Picker("Year", selection: $year) {
                    ForEach((Self.thisYear - 5)...Self.thisYear, id: \.self) { y in Text(verbatim: "\(y)").tag(y) }
                }
                .frame(maxWidth: 140)
                Toggle("Year to date", isOn: $yearToDate).toggleStyle(.checkbox)
                    .help("January 1 to today's date; off, the whole year. The same choices as on Spending Analysis")
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Read the registers again")
            }
            .onChange(of: year) { Task { await reload() } }
            .onChange(of: yearToDate) { Task { await reload() } }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
            }
            if let setup, let data {
                CategoriesAdmin(setup: setup, data: data, entries: data.entries, store: store, saved: { applied($0) })
                CardCategoriesAdmin(setup: setup, categories: $cardCategories) { Task { await reload() } }
                DriversAdmin(setup: setup, data: data, entries: data.entries, saved: { applied($0) })
                DriverCategoryGuide(setup: setup, data: data, entries: data.entries,
                                    openTab: { spendingTab = $0; store.go(.spending) }, go: { store.go($0) }, ruleSaved: { applied($0) })
            } else if busy {
                ProgressView("Reading the registers…").frame(maxWidth: .infinity)
            }
        }
        .task { await reload() }
        .quickHelpArea(PortHelp.about(.targetCategories))
    }

    private func reload() async {
        busy = true
        defer { busy = false }
        let p = SpendingAnalysisView.periods(year: year, yearToDate: yearToDate)
        do {
            async let s = SpendingClient.setup()
            async let d = SpendingClient.analysis(start: p.start, end: p.end, priorStart: p.priorStart, priorEnd: p.priorEnd)
            async let c = SpendingClient.cardCategories()
            (setup, data, cardCategories) = try await (s, d, c)
            problem = nil
        } catch {
            problem = describe(error)
        }
    }

    /// A category or driver saved: the entries are resolved again with it.
    private func applied(_ s: SpendingSetup) {
        setup = s
        Task { await reload() }
    }
}

// MARK: - Card company categories

/// A card company's own category and the one of ours it maps to (srm.card_category, V061).
struct CardCategory: Decodable, Identifiable, Hashable {
    var issuerCategory: String
    var category: String?
    var lines: Int
    var id: String { issuerCategory }
}

/// Each card company category with a menu of ours; those with none first.
private struct CardCategoriesAdmin: View {
    var setup: SpendingSetup
    @Binding var categories: [CardCategory]
    /// A change can give target accounts a category: the figures again.
    var changed: () -> Void
    @State private var problem: String?
    @State private var open = false

    var body: some View {
        let missing = categories.filter { $0.category == nil }.count
        return Box(title: "Card Company Categories", symbol: "creditcard", help: "The card companies' downloads give each line a category of their own. When a line's target account has no category yet, it takes the one that company category maps to here. Choosing one also gives it to the target accounts with no category whose card lines have it.") {
            HStack {
                Text(missing > 0 ? "\(missing) of \(categories.count) have no category" : "All \(categories.count) are mapped")
                    .foregroundStyle(missing > 0 ? .orange : .secondary)
                Spacer()
                Button(open ? "Hide" : "Show") { open.toggle() }
            }
            if let problem { Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
            if open || missing > 0 {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow {
                        Text("Card company category").fillsGridColumn(); Text("Lines").gridColumnAlignment(.trailing); Text("Category")
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(categories.filter { open || $0.category == nil }) { c in
                        GridRow {
                            Text(c.issuerCategory).fillsGridColumn()
                            Text("\(c.lines)").monospacedDigit().foregroundStyle(.secondary)
                            Picker("", selection: Binding(get: { c.category }, set: { save(c, $0) })) {
                                Text("None").tag(String?.none)
                                ForEach(setup.categories) { Text($0.name).tag(Optional($0.code)) }
                            }
                            .labelsHidden().frame(width: 180)
                        }
                    }
                }
                .font(.callout)
            }
        }
    }

    private func save(_ c: CardCategory, _ code: String?) {
        Task {
            do {
                categories = try await SpendingClient.saveCardCategory(c.issuerCategory, category: code)
                problem = nil
                changed()
            } catch { problem = describe(error) }
        }
    }
}

// MARK: - Categories and drivers

/// This year's spending and entries by a code (a category's or a driver's; "" for none).
private func thisYear(_ entries: [SpendingEntry], _ data: SpendingAnalysisData, by key: (SpendingEntry) -> String?) -> [String: (amount: Double, count: Int)] {
    var now: [String: (amount: Double, count: Int)] = [:]
    for e in entries where e.date >= data.start && e.date <= data.end {
        now[key(e) ?? "", default: (0, 0)].amount += e.amount
        now[key(e) ?? "", default: (0, 0)].count += 1
    }
    return now
}

/// The spending categories in their order, with what each register spent in them, Edit… and Remove… on each, New
/// Category…, and arrows to reorder. Right-click one for its transactions.
private struct CategoriesAdmin: View {
    var setup: SpendingSetup
    var data: SpendingAnalysisData
    var entries: [SpendingEntry]
    var store: PortStore
    var saved: (SpendingSetup) -> Void
    /// New (.some(nil)) or Edit (.some(category)).
    @State private var editing: SpendingCategory??
    @State private var removing: SpendingCategory?
    @State private var moving = false
    @State private var problem: String?

    var body: some View {
        let now = thisYear(entries, data) { $0.category }
        let last = setup.categories.count - 1
        let year = entries.filter { $0.date >= data.start && $0.date <= data.end }
        let registers = Array(Set(year.map(registerOf))).sorted()
        var byRegister: [String: Double] = [:]
        for e in year { byRegister[(e.category ?? "") + "|" + registerOf(e), default: 0] += e.amount }
        return Box(title: "Spending Categories", symbol: "cart", help: "What the money bought, across every checking account and credit card (a column each). Each follows a consumer price index (or an assumed rate), which decides how much of its change is inflation; the CPI series and the rate can also be changed on Spending Analysis ▸ Family & Lifecycle. Right-click one for the transactions behind it. The arrows set the order the page lists them in. Remove… moves the target accounts, tags and lifecycle triggers allocated to a category to another first.") {
            HStack {
                Button("New Category…") { editing = .some(nil) }
                Spacer()
                if moving { ProgressView().controlSize(.small) }
                Text("\(setup.categories.count) categories").foregroundStyle(.secondary)
            }
            if let problem { Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                GridRow {
                    Text(""); Text("Category").fillsGridColumn(); Text("CPI series"); Text("Assumed").gridColumnAlignment(.trailing)
                    ForEach(registers, id: \.self) { Text($0).gridColumnAlignment(.trailing) }
                    Text("This year").gridColumnAlignment(.trailing); Text("Entries").gridColumnAlignment(.trailing)
                    Text("Set by").gridColumnAlignment(.trailing); Text("")
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Array(setup.categories.enumerated()), id: \.element.id) { i, c in
                    let spent = now[c.code]
                    let rules = setup.payees.filter { $0.category == c.code }.count
                    let triggers = setup.triggers.filter { $0.category == c.code }.count
                    GridRow {
                        OrderButtons(up: i > 0 ? { move(i, -1) } : nil, down: i < last ? { move(i, 1) } : nil).disabled(moving)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(c.name)
                            if let d = c.description, !d.isEmpty { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(d) }
                        }
                        .fillsGridColumn()
                        .modifier(ShowsTransactions(name: c.name, entries: year.filter { $0.category == c.code }, data: data, setup: setup, store: store))
                        Text(c.cpiName ?? "—").foregroundStyle(.secondary).lineLimit(1)
                        Text(pct(c.assumedInflation, 1)).monospacedDigit().foregroundStyle(.secondary)
                        ForEach(registers, id: \.self) { r in amount(byRegister[c.code + "|" + r]) }
                        Text(money(spent?.amount ?? 0)).monospacedDigit()
                        Text("\(spent?.count ?? 0)").monospacedDigit().foregroundStyle(.secondary)
                        Text(setBy(rules: rules, triggers: triggers)).foregroundStyle(.secondary)
                            .help("Target accounts allocated to it and lifecycle triggers in it (single entries' tags not counted)")
                        HStack(spacing: 4) {
                            Button("Edit…") { editing = .some(c) }
                            Button("Remove…") { removing = c }.disabled(setup.categories.count <= 1)
                        }
                        .controlSize(.small)
                    }
                }
                if let spent = now[""] {
                    GridRow {
                        Text("")
                        Text("Not assigned").foregroundStyle(.orange)
                            .modifier(ShowsTransactions(name: "Not assigned", entries: year.filter { $0.category == nil }, data: data, setup: setup, store: store))
                        Text(""); Text("")
                        ForEach(registers, id: \.self) { r in amount(byRegister["|" + r]) }
                        Text(money(spent.amount)).monospacedDigit().foregroundStyle(.orange)
                        Text("\(spent.count)").monospacedDigit().foregroundStyle(.secondary)
                        Text(""); Text("")
                    }
                    .help("Entries whose target account has no category and no tag gives one")
                }
            }
            .font(.callout)
        }
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            CategoryEditor(setup: setup, category: editing ?? nil) { saved($0) }
        }
        .sheet(item: $removing) { c in RemoveCategorySheet(setup: setup, category: c) { saved($0) } }
    }

    private func registerOf(_ e: SpendingEntry) -> String { e.register ?? e.sourceTitle }

    private func amount(_ a: Double?) -> some View {
        Text(abs(a ?? 0) < 0.5 ? "" : money(a ?? 0)).monospacedDigit().foregroundStyle(.secondary)
    }

    private func setBy(rules: Int, triggers: Int) -> String {
        let parts = [rules > 0 ? "\(rules) target\(rules == 1 ? "" : "s")" : nil, triggers > 0 ? "\(triggers) trigger\(triggers == 1 ? "" : "s")" : nil]
        return parts.compactMap { $0 }.joined(separator: ", ")
    }

    private func move(_ i: Int, _ by: Int) {
        var codes = setup.categories.map(\.code)
        codes.swapAt(i, i + by)
        Task {
            moving = true
            defer { moving = false }
            do { saved(try await SpendingClient.orderCategories(codes)); problem = nil } catch { problem = describe(error) }
        }
    }
}

/// The spending drivers in their order with the effect each counts as, Edit… and Remove… on each, New Driver…, and
/// arrows to reorder.
private struct DriversAdmin: View {
    var setup: SpendingSetup
    var data: SpendingAnalysisData
    var entries: [SpendingEntry]
    var saved: (SpendingSetup) -> Void
    /// New (.some(nil)) or Edit (.some(driver)).
    @State private var editing: SpendingDriver??
    @State private var removing: SpendingDriver?
    @State private var moving = false
    @State private var problem: String?

    var body: some View {
        let now = thisYear(entries, data) { $0.driver }
        let last = setup.drivers.count - 1
        return Box(title: "Spending Drivers", symbol: "arrow.up.right", help: "Why spending changed. Each driver's growth beyond inflation counts toward one effect — the attribution's terms: change = inflation + usage + lifecycle + behavior + one-time + taxes. Spending with no driver counts as Usage. The arrows set the order menus and tables list them in. Remove… moves the rules and tags that set a driver to another (or none) first.") {
            HStack {
                Button("New Driver…") { editing = .some(nil) }
                Spacer()
                if moving { ProgressView().controlSize(.small) }
                Text("\(setup.drivers.count) drivers").foregroundStyle(.secondary)
            }
            if let problem { Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                GridRow {
                    Text(""); Text("Driver").fillsGridColumn(); Text("Counts as")
                    Text("This year").gridColumnAlignment(.trailing); Text("Entries").gridColumnAlignment(.trailing)
                    Text("Set by").gridColumnAlignment(.trailing); Text("")
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Array(setup.drivers.enumerated()), id: \.element.id) { i, d in
                    let spent = now[d.code]
                    let rules = setup.payees.filter { $0.driver == d.code }.count
                    GridRow {
                        OrderButtons(up: i > 0 ? { move(i, -1) } : nil, down: i < last ? { move(i, 1) } : nil).disabled(moving)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(d.title)
                            if let h = d.help, !h.isEmpty { Text(h).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(h) }
                        }
                        .fillsGridColumn()
                        Text(d.effect.rawValue).foregroundStyle(d.effect.color).help(d.effect.help)
                        Text(money(spent?.amount ?? 0)).monospacedDigit()
                        Text("\(spent?.count ?? 0)").monospacedDigit().foregroundStyle(.secondary)
                        Text(rules > 0 ? "\(rules) target\(rules == 1 ? "" : "s")" : "").foregroundStyle(.secondary)
                            .help("Target accounts whose spending this driver is allocated to (single entries' tags not counted)")
                        HStack(spacing: 4) {
                            Button("Edit…") { editing = .some(d) }
                            Button("Remove…") { removing = d }
                        }
                        .controlSize(.small)
                    }
                }
                GridRow {
                    Text("")
                    Text("No driver").foregroundStyle(.secondary)
                    Text(SpendingEffect.usage.rawValue).foregroundStyle(SpendingEffect.usage.color)
                    Text(money(now[""]?.amount ?? 0)).monospacedDigit().foregroundStyle((now[""]?.amount ?? 0) >= 0.5 ? .orange : .secondary)
                    Text("\(now[""]?.count ?? 0)").monospacedDigit().foregroundStyle(.secondary)
                    Text(""); Text("")
                }
                .help("Entries whose target account has no driver and no tag gives one: their growth counts as Usage")
            }
            .font(.callout)
        }
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            DriverEditor(setup: setup, driver: editing ?? nil) { saved($0) }
        }
        .sheet(item: $removing) { d in RemoveDriverSheet(setup: setup, driver: d) { saved($0) } }
    }

    private func move(_ i: Int, _ by: Int) {
        var codes = setup.drivers.map(\.code)
        codes.swapAt(i, i + by)
        Task {
            moving = true
            defer { moving = false }
            do { saved(try await SpendingClient.orderDrivers(codes)); problem = nil } catch { problem = describe(error) }
        }
    }
}

/// A right-click on a category: the entries behind it, in a window of their own.
private struct ShowsTransactions: ViewModifier {
    var name: String
    var entries: [SpendingEntry]
    var data: SpendingAnalysisData
    var setup: SpendingSetup
    var store: PortStore

    func body(content: Content) -> some View {
        // Selectable text would open the text's own menu instead.
        content.textSelection(.disabled).contextMenu {
            Button("Show \(entries.count) \(entries.count == 1 ? "Transaction" : "Transactions")…") {
                SpendingTransactionsWindow.open(name, period: "\(shortDay(data.start)) – \(shortDay(data.end))", entries: entries, setup: setup, store: store)
            }
            .disabled(entries.isEmpty)
        }
    }
}

/// Move up and Move down, for a row of a list kept in order.
private struct OrderButtons: View {
    var up: (() -> Void)?
    var down: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            Button { up?() } label: { Image(systemName: "chevron.up") }.disabled(up == nil).help("Move up")
            Button { down?() } label: { Image(systemName: "chevron.down") }.disabled(down == nil).help("Move down")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }
}

// MARK: - Driver and category

private struct DriverCategoryGuide: View {
    var setup: SpendingSetup
    var data: SpendingAnalysisData
    var entries: [SpendingEntry]
    var openTab: (String) -> Void
    var go: (Screen) -> Void
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
                          text: "\(Self.either(setup.categories.map(\.name))). Each category follows its own consumer price index (Spending Analysis ▸ Sources), so the category decides how much of a change is inflation.")
                AdminCard(title: "Driver: why the spending changed", symbol: "arrow.up.right",
                          text: "\(Self.either(setup.drivers.map(\.title))). The driver decides which effect the growth beyond inflation counts as (Spending Drivers, above); with no driver it counts as Usage.")
            }
            Text("They are independent: any category can have any driver. Food can grow with Family Growth, Activities with Lifestyle & Hobbies, Housing with Taxes. Spending is the payments from the checking accounts and credit cards to target accounts whose role is Spending — the providers, merchants and vendors paid — and each gets its category and driver:")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 3) {
                Text("1. From the entry's own tag, when it has one (Spending Analysis ▸ Entries: double-click, or select several and right-click) — a mixed merchant's purchase, a one-time event.")
                Text("2. Else from its target account's allocation (Spending Analysis ▸ Allocation): every payment to it.")
            }
            .font(.callout).padding(.leading, 8)
            Text("Transfers between your own accounts and income aren't spending (Spending Analysis ▸ Sources ▸ Transfers & Income), and a payment no target account matches isn't in the analysis until it is allocated (Spending Analysis ▸ Sources ▸ Unallocated Payments). Cash ledgers are stand-alone project scratch pads: they don't feed the analysis.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open Allocation") { openTab("rules") }
                Button("Open Entries") { openTab("entries") }
                Button("Open Sources") { openTab("sources") }
                Button("Open Target Accounts") { go(.expenses) }
            }
        }
        matrix
            .sheet(item: $ruleFor) { t in TargetAllocationSheet(setup: setup, target: t, entries: entries) { ruleSaved($0) } }
    }

    /// "A, B or C".
    private static func either(_ names: [String]) -> String {
        names.count > 1 ? names.dropLast().joined(separator: ", ") + " or " + names.last! : names.first ?? ""
    }

    // MARK: The matrix

    private var matrix: some View {
        let rows = current
        var sums: [Cell: Double] = [:]
        for e in rows { sums[Cell(category: e.category ?? SpendingEngine.unassigned, driver: e.driver ?? ""), default: 0] += e.amount }
        let codes = setup.categories.map(\.code).filter { c in sums.keys.contains { $0.category == c } }
            + (sums.keys.contains { $0.category == SpendingEngine.unassigned } ? [SpendingEngine.unassigned] : [])
        // A driver taken off since the entries were read still shows, after the others.
        let drivers = setup.drivers.map(\.code) + Set(sums.keys.map(\.driver)).filter { !$0.isEmpty && setup.driver($0) == nil }.sorted() + [""]
        let gaps = rows.filter { $0.driver == nil || $0.category == nil }.map(\.amount).reduce(0, +)
        return Box(title: "This Year: Category × Driver", symbol: "tablecells",
                   help: "This year's spending by category (rows) and driver (columns), in every register. Orange: spending with no driver (it counts as Usage) or no category. Click a cell to see what put its entries there and change it.") {
            Text(gaps > 0.5 ? "\(money(gaps)) of this year's \(money(rows.map(\.amount).reduce(0, +))) has no driver or no category (orange). Click a cell to see why, and Rule… to give it one."
                 : "Every dollar this year has a category and a driver.")
                .font(.callout).foregroundStyle(gaps > 0.5 ? .orange : .secondary)
            ScrollView(.horizontal) {
                Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 3) {
                    GridRow {
                        Text("Category").gridColumnAlignment(.leading)
                        ForEach(drivers, id: \.self) { d in Text(d.isEmpty ? "No driver" : setup.driver(d)?.title ?? d) }
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

    /// What set an entry's category or driver: its target account's allocation or its own tag, and the target account.
    private struct Origin: Hashable {
        var kind: String
        var label: String
        var target: Int?
    }

    private func origin(_ e: SpendingEntry, from kind: String?) -> (Origin, RuleTarget?) {
        let t = e.payeeId.map { RuleTarget(payeeId: $0, name: e.payee ?? "") }
        switch kind {
        case "entry":
            return (Origin(kind: "the entry's own tag", label: "Tagged on the entry", target: nil), nil)
        case "target account":
            return (Origin(kind: "target account", label: e.payee ?? "—", target: t?.id), t)
        default:
            // Its target account allocates nothing for it yet: Allocate… sets it.
            return (Origin(kind: "not allocated", label: e.payee ?? "—", target: t?.id), t)
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
        let driver = setup.driver(c.driver)?.title ?? c.driver
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
                                Button(g.targets.count > 1 ? "Allocate \(t.name.isEmpty ? "it" : t.name)…" : "Allocate…") { ruleFor = t }.controlSize(.small)
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
            Text(o.kind).font(.caption).foregroundStyle(o.kind == "not allocated" ? .orange : .secondary)
        }
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
