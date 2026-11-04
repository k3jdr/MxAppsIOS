//
//  SpendingBaseline.swift
//  MxAcctMGR
//
//  Spending Analysis ▸ Retirement: the baseline retirement spending is compared with (V062). The household statement
//  says where the year's money came from and went, and ties to the change in checking; the living costs then split by
//  what each does in retirement. A category says that for its spending and a merchant can override it, both on
//  Target Categories. The accounts service works it all out, as the family page shows the same figures. Everyday
//  spending opens by category; right-click it, a category, Big bills or their tiles for the transactions behind them.
//

import SwiftUI

/// What a living cost does in retirement (srm.spending_category.retirement, srm.payee.retirement).
enum RetirementLabel {
    static let all = [("continues", "Continues"), ("house", "Depends on the house"), ("kids", "Ends with the kids"),
                      ("work", "Ends with work"), ("one_time", "One-time")]
    static func title(_ code: String?) -> String { all.first { $0.0 == code }?.1 ?? "Continues" }
}

/// Where a merchant goes on the household statement when its role doesn't say (srm.payee.statement_line), and the role
/// that goes with it.
enum StatementLine {
    static let all = [("earned", "Earned income", "income"), ("tax_refund", "Tax refund", "income"),
                      ("other_income", "Other money in", "income"), ("improvement", "Home improvement", "spending")]
    static func title(_ code: String?) -> String? {
        code == "card_payment" ? "Card payment" : all.first { $0.0 == code }?.1
    }
}

struct SpendingBaseline: Decodable {
    struct Summary: Decodable {
        var earned, incomeTax, afterTax, living, leftOver, improvement, principal: Double
        var principalEstimated: Int
        var taxRefunds, otherIncome, cardsUnpaid, moved, change, difference, cardUnallocated, monthlyLiving, allMoneyOut: Double
        /// Living costs split into each bill under bigBillLimit and the big ones, so far and a month.
        var everyday, everydayMonthly, bigBills, bigBillsMonthly, bigBillLimit: Double
    }
    /// An entry and the part of it that is a living cost (a mortgage payment's interest).
    struct EntryKey: Decodable {
        var source: String
        var entryId: Int
        var amount: Double
    }
    /// A living cost of bigBillLimit or more in one entry.
    struct Bill: Decodable {
        var source: String?
        var entryId: Int?
        var date: String
        var name: String
        var register: String
        var category: String
        var retirement: String?
        var amount: Double
    }
    struct Merchant: Decodable, Identifiable {
        var name: String
        var amount: Double
        var entries: Int
        var id: String { name }
    }
    struct Line: Decodable {
        var key: String
        var title: String
        var amount: Double
        var merchants: [Merchant]
    }
    struct Category: Decodable, Identifiable {
        var code: String?
        var name: String
        var amount: Double
        var monthly: Double
        var merchants: [Merchant]
        var id: String { code ?? "" }
    }
    struct Label: Decodable, Identifiable {
        var code: String
        var title: String
        var help: String
        var amount: Double
        var monthly: Double
        var share: Double
        var categories: [Category]
        var id: String { code }
    }
    struct Partial: Decodable {
        var register: String
        var first: String?
    }
    var year: Int
    var through: String
    var months: Double
    var checkingThrough: String?
    var cardsThrough: String?
    /// The months a monthly figure divides each register's spending by.
    var checkingMonths: Double?
    var cardMonths: Double?
    var summary: Summary
    var bills: [Bill]
    /// Each everyday entry (asked for with entries=1).
    var everydayEntries: [EntryKey]?
    var lines: [Line]
    var moneyBack: [Merchant]
    var retirement: [Label]
    var partial: [Partial]

    func merchants(_ key: String) -> [Merchant] { lines.first { $0.key == key }?.merchants ?? [] }
}

struct SpendingBaselineTab: View {
    var year: Int
    /// Spending Analysis's entries, for the transactions behind a figure (nil while they load).
    var data: SpendingAnalysisData?
    var setup: SpendingSetup
    var store: PortStore
    @State private var base: SpendingBaseline?
    @State private var problem: String?
    @State private var busy = false
    /// The lines opened to show what's in them.
    @State private var opened = Set<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if let b = base {
                    Text("Today's real spending, the starting point for what retirement will cost: \(String(b.year)) so far, with checking through \(shortDay(b.checkingThrough)) and the cards through \(shortDay(b.cardsThrough)). A month is checking's spending over its \(months(b.checkingMonths ?? b.months)) months plus the cards' over their \(months(b.cardMonths ?? b.months)).")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.help("Read the registers again")
            }
            if let problem { Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
            if let b = base {
                if !b.partial.isEmpty {
                    Label("Not a whole year: " + b.partial.map { p in p.first.map { "\(p.register) starts \(shortDay($0))" } ?? "\(p.register) has nothing this year" }.joined(separator: "; ")
                          + ", so these figures miss what came before.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                }
                tiles(b)
                split(b)
                statement(b)
                retirement(b)
            } else if busy {
                ProgressView("Reading the registers…").frame(maxWidth: .infinity)
            }
        }
        .task(id: year) { await load() }
        #if DEBUG
        // Self-test: -baselineTransactionsTest everyday opens its transactions once both have loaded.
        .task(id: (data?.entries.count ?? 0) + (base?.everydayEntries?.count ?? 0)) {
            guard !testOpened, UserDefaults.standard.string(forKey: "baselineTransactionsTest") == "everyday", let b = base, data != nil else { return }
            testOpened = true
            SpendingTransactionsWindow.open("Everyday spending", period: "\(String(b.year)) so far", entries: everyday(b), setup: setup, store: store)
        }
        #endif
    }

    #if DEBUG
    @State private var testOpened = false
    #endif

    // MARK: Transactions

    /// Spending Analysis's entries for these keys, each with the part of it that is a living cost.
    private func entries(_ keys: [(source: String, entryId: Int, amount: Double)]) -> [SpendingEntry] {
        guard let data else { return [] }
        let byKey = Dictionary(data.entries.map { ("\($0.source):\($0.entryId)", $0) }, uniquingKeysWith: { a, _ in a })
        return keys.compactMap { k in
            guard var e = byKey["\(k.source):\(k.entryId)"] else { return nil }
            e.amount = k.amount
            return e
        }
    }

    private func everyday(_ b: SpendingBaseline) -> [SpendingEntry] {
        entries((b.everydayEntries ?? []).map { ($0.source, $0.entryId, $0.amount) })
    }

    private func bigBills(_ b: SpendingBaseline) -> [SpendingEntry] {
        entries(b.bills.compactMap { x in x.source.flatMap { s in x.entryId.map { (s, $0, x.amount) } } })
    }

    /// Everyday spending by category, the largest first: its entries and a month of it.
    private func byCategory(_ list: [SpendingEntry], _ b: SpendingBaseline) -> [(name: String, entries: [SpendingEntry], amount: Double, monthly: Double)] {
        Dictionary(grouping: list) { setup.category($0.category)?.name ?? "Not assigned" }
            .map { name, v in
                (name, v, v.reduce(0) { $0 + $1.amount },
                 v.reduce(0) { $0 + $1.amount / (($1.source == "card" ? b.cardMonths : b.checkingMonths) ?? b.months) })
            }
            .sorted { $0.amount > $1.amount }
    }

    private func load() async {
        busy = true
        defer { busy = false }
        do { base = try await SpendingClient.baseline(year: year); problem = nil } catch { problem = describe(error) }
    }

    private func tiles(_ b: SpendingBaseline) -> some View {
        let s = b.summary
        return HStack(spacing: 10) {
            MetricTile(title: "After-tax income", value: money(s.afterTax), caption: "take-home pay less income taxes",
                       help: "What was earned, after the income taxes paid from checking. Pay already has its withholding taken out.")
            MetricTile(title: "Living costs", value: money(s.living), caption: "\(money(s.monthlyLiving)) a month, about \(money(s.monthlyLiving * 12)) a year",
                       help: "What it cost to live: not income taxes, home improvements or mortgage principal. A year at this pace is rough until the year is whole.")
            MetricTile(title: "Everyday spending", value: money(s.everydayMonthly), caption: "a month: each bill under \(money(s.bigBillLimit))",
                       help: "Living costs less the big bills: a normal month. Right-click for the transactions.")
                .modifier(ShowsBaselineTransactions(name: "Everyday spending", period: "\(String(b.year)) so far", entries: everyday(b), setup: setup, store: store))
            MetricTile(title: "Big bills", value: money(s.bigBillsMonthly), caption: "a month: \(b.bills.count) bill\(b.bills.count == 1 ? "" : "s") of \(money(s.bigBillLimit)) or more",
                       help: "Taxes, car repairs, insurance, trips and one-off purchases, averaged over the months. Right-click for the transactions.")
                .modifier(ShowsBaselineTransactions(name: "Big bills", period: "\(String(b.year)) so far", entries: bigBills(b), setup: setup, store: store))
            MetricTile(title: "Left over from income", value: money(s.leftOver),
                       caption: s.afterTax > 0 ? "\(pct(s.leftOver / s.afterTax, 0)) of after-tax income" : "", tint: s.leftOver < 0 ? .orange : .primary,
                       help: "After-tax income less living costs.")
        }
    }

    private func months(_ m: Double) -> String { m.formatted(.number.precision(.fractionLength(1))) }

    // MARK: Everyday and big bills

    private func split(_ b: SpendingBaseline) -> some View {
        let s = b.summary
        let period = "\(String(b.year)) so far"
        let daily = everyday(b)
        return Box(title: "Everyday Spending and Big Bills", symbol: "calendar", help: "Living costs split into a normal month and the big, irregular bills. Open Everyday spending for its categories and Big bills for each bill; right-click either, or a category, for the transactions.") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Spacer()
                    Text("So far").frame(width: 90, alignment: .trailing)
                    Text("A month").frame(width: 80, alignment: .trailing)
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                HStack {
                    VStack(alignment: .leading, spacing: 0) {
                        opener("everyday", "Everyday spending")
                        Text("Each bill under \(money(s.bigBillLimit)): groceries, gas, utilities, the phone, shopping, eating out")
                            .font(.caption).foregroundStyle(.secondary).padding(.leading, 16)
                    }
                    Spacer()
                    Text(money(s.everyday)).monospacedDigit().frame(width: 90, alignment: .trailing)
                    Text(money(s.everydayMonthly)).monospacedDigit().frame(width: 80, alignment: .trailing)
                }
                .contentShape(Rectangle())
                .modifier(ShowsBaselineTransactions(name: "Everyday spending", period: period, entries: daily, setup: setup, store: store))
                if opened.contains("everyday") {
                    VStack(alignment: .leading, spacing: 1) {
                        if data == nil { Text("Reading the entries…").foregroundStyle(.tertiary) }
                        ForEach(byCategory(daily, b), id: \.name) { c in
                            HStack {
                                Text("\(c.name) (\(c.entries.count))")
                                Spacer()
                                Text(money(c.amount)).monospacedDigit().frame(width: 90, alignment: .trailing)
                                Text(money(c.monthly)).monospacedDigit().frame(width: 80, alignment: .trailing)
                            }
                            .contentShape(Rectangle())
                            .modifier(ShowsBaselineTransactions(name: "Everyday spending: \(c.name)", period: period, entries: c.entries, setup: setup, store: store))
                        }
                    }
                    .font(.callout).foregroundStyle(.secondary).padding(.leading, 36)
                }
                HStack {
                    VStack(alignment: .leading, spacing: 0) {
                        opener("bills", "Big bills (\(b.bills.count))")
                        Text("Each \(money(s.bigBillLimit)) or more: property and school taxes, car repairs and insurance, trips, one-off purchases")
                            .font(.caption).foregroundStyle(.secondary).padding(.leading, 16)
                    }
                    Spacer()
                    Text(money(s.bigBills)).monospacedDigit().frame(width: 90, alignment: .trailing)
                    Text(money(s.bigBillsMonthly)).monospacedDigit().frame(width: 80, alignment: .trailing)
                }
                .contentShape(Rectangle())
                .modifier(ShowsBaselineTransactions(name: "Big bills", period: period, entries: bigBills(b), setup: setup, store: store))
                if opened.contains("bills") {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(b.bills.enumerated()), id: \.offset) { _, x in
                            HStack {
                                Text("\(shortDay(x.date)) · \(x.name)").lineLimit(1)
                                Text("(\(x.category))").foregroundStyle(.tertiary)
                                Spacer()
                                Text(money(x.amount)).monospacedDigit().frame(width: 90, alignment: .trailing)
                                Text("").frame(width: 80)
                            }
                        }
                    }
                    .font(.callout).foregroundStyle(.secondary).padding(.leading, 36)
                }
                VStack(spacing: 2) {
                    Divider()
                    HStack {
                        Text("Living costs").fontWeight(.semibold)
                        Spacer()
                        Text(money(s.living)).monospacedDigit().fontWeight(.semibold).frame(width: 90, alignment: .trailing)
                        Text(money(s.monthlyLiving)).monospacedDigit().fontWeight(.semibold).frame(width: 80, alignment: .trailing)
                    }
                    Divider()
                }
            }
            .frame(maxWidth: 780, alignment: .leading)
            Text("A normal month is the everyday figure. The big bills come in lumps, but most come back in some form in retirement (taxes, cars, insurance, trips), so a retirement budget needs both: an everyday amount and an allowance for them.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Statement

    private func statement(_ b: SpendingBaseline) -> some View {
        let s = b.summary
        let back = b.moneyBack.filter { $0.amount <= -500 }
        return Box(title: "Household Statement", symbol: "list.bullet.rectangle", help: "Where this year's money came from and went, tied to the change in checking. Open a line to see what's in it. A merchant's line is set on Target Categories ▸ Merchants.") {
            VStack(alignment: .leading, spacing: 3) {
                line("earned", "Take-home pay", s.earned, b)
                line("income_tax", "Income taxes paid from checking", -s.incomeTax, b)
                total("After-tax income", s.afterTax)
                line("living", "Living costs", -s.living, b)
                total("Left over from income", s.leftOver)
                line("improvement", "Home improvements", -s.improvement, b)
                line("principal", "Mortgage principal", -s.principal, b)
                line("tax_refund", "Tax refunds", s.taxRefunds, b)
                line("other_income", "Other money in", s.otherIncome, b)
                amountRow("Card charges not yet paid", s.cardsUnpaid)
                    .help("Charged on the cards this year and counted above, less what checking paid the cards")
                line("moved", "Moved to savings and family accounts, net", -s.moved, b)
                total("Change in checking", s.change)
            }
            .frame(maxWidth: 640, alignment: .leading)
            let tied = abs(s.difference) < 0.01 ? "✓ This ties to checking to the cent." : "⚠︎ This is \(money2(s.difference)) away from checking."
            let estimated = s.principalEstimated > 0 ? " Principal is estimated on \(s.principalEstimated) payment\(s.principalEstimated == 1 ? "" : "s") whose mortgage statement isn't in yet." : ""
            let returned = back.isEmpty ? "" : " Living costs are after money that came back: " + back.map { "\($0.name) \(money(-$0.amount))" }.joined(separator: ", ") + "."
            let unallocated = s.cardUnallocated >= 0.5 ? " \(money(s.cardUnallocated)) of card charges has no merchant, so it isn't counted." : ""
            Text("\(tied) Living costs, income taxes, improvements and principal add up to \(money(s.allMoneyOut)), the All spending figure on the Overview.\(estimated)\(returned)\(unallocated)")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func line(_ key: String, _ title: String, _ amount: Double, _ b: SpendingBaseline) -> some View {
        let list = b.merchants(key)
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                opener(key, title)
                Spacer()
                Text(money(amount)).monospacedDigit()
            }
            if opened.contains(key) { merchants(list, indent: 20) }
        }
    }

    private func amountRow(_ title: String, _ amount: Double) -> some View {
        HStack {
            Text(title).padding(.leading, 16)
            Spacer()
            Text(money(amount)).monospacedDigit()
        }
    }

    private func total(_ title: String, _ amount: Double) -> some View {
        VStack(spacing: 2) {
            Divider()
            HStack {
                Text(title).fontWeight(.semibold)
                Spacer()
                Text(money(amount)).monospacedDigit().fontWeight(.semibold)
            }
            Divider()
        }
    }

    private func opener(_ key: String, _ title: String) -> some View {
        Button {
            if opened.contains(key) { opened.remove(key) } else { opened.insert(key) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: opened.contains(key) ? "chevron.down" : "chevron.right").font(.caption2).frame(width: 12)
                Text(title)
            }
            .contentShape(Rectangle())
        }
        .plainButton()
    }

    private func merchants(_ list: [SpendingBaseline.Merchant], indent: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(list) { m in
                HStack {
                    Text(m.entries > 1 ? "\(m.name) (\(m.entries))" : m.name).lineLimit(1)
                    Spacer()
                    Text(money(m.amount)).monospacedDigit()
                }
            }
        }
        .font(.callout).foregroundStyle(.secondary)
        .padding(.leading, indent)
    }

    // MARK: Retirement

    private func retirement(_ b: SpendingBaseline) -> some View {
        Box(title: "What Carries Into Retirement", symbol: "figure.walk", help: "Each living cost by what it does when work stops. A category says this for its spending; a merchant can override it (Target Categories), and an entry with the One-Time Event driver or for a child counts that way.") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Living costs that…")
                    Spacer()
                    Text("So far").frame(width: 90, alignment: .trailing)
                    Text("Share").frame(width: 50, alignment: .trailing)
                    Text("A month").frame(width: 80, alignment: .trailing)
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(b.retirement.filter { abs($0.amount) >= 0.5 }) { r in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            VStack(alignment: .leading, spacing: 0) {
                                opener("r:" + r.code, r.title)
                                Text(r.help).font(.caption).foregroundStyle(.secondary).padding(.leading, 16)
                            }
                            Spacer()
                            Text(money(r.amount)).monospacedDigit().frame(width: 90, alignment: .trailing)
                            Text(pct(r.share, 0)).monospacedDigit().frame(width: 50, alignment: .trailing)
                            Text(money(r.monthly)).monospacedDigit().frame(width: 80, alignment: .trailing)
                        }
                        if opened.contains("r:" + r.code) {
                            ForEach(r.categories) { c in
                                let key = "c:\(r.code):\(c.id)"
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        opener(key, c.name)
                                        Spacer()
                                        Text(money(c.amount)).monospacedDigit().frame(width: 90, alignment: .trailing)
                                        Text("").frame(width: 50)
                                        Text(money(c.monthly)).monospacedDigit().frame(width: 80, alignment: .trailing)
                                    }
                                    if opened.contains(key) { merchants(c.merchants, indent: 20).padding(.trailing, 146) }
                                }
                                .padding(.leading, 16)
                                .font(.callout)
                            }
                        }
                    }
                }
                total("Living costs", b.summary.living)
            }
            .frame(maxWidth: 780, alignment: .leading)
            Text("Not here: health insurance, retirement contributions and anything else taken out of pay before it reaches checking. Health coverage in retirement is a new cost that today's spending doesn't show.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Right-click: Show N Transactions…, in the window Spending Analysis's other figures open.
private struct ShowsBaselineTransactions: ViewModifier {
    var name: String
    var period: String
    var entries: [SpendingEntry]
    var setup: SpendingSetup
    var store: PortStore

    func body(content: Content) -> some View {
        // Selectable text would open the text's own menu instead.
        content.textSelection(.disabled).contextMenu {
            Button("Show \(entries.count) \(entries.count == 1 ? "Transaction" : "Transactions")…") {
                SpendingTransactionsWindow.open(name, period: period, entries: entries, setup: setup, store: store)
            }
            .disabled(entries.isEmpty)
        }
    }
}
