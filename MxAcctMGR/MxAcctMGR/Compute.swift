//
//  Compute.swift
//  MxAcctMGR
//
//  Knowledge Library ▸ Compute: AI compute as an asset theme, followed through the money the hyperscalers spend on it.
//  Their quarterly capital expenditure (data centres, chips, networking, power) — each company's and combined, its
//  growth, how much of their revenue and operating cash flow it takes, and depreciation catching up — beside the
//  revenue of the companies that money goes to (chips, memory, networking, power and cooling, data-centre space), and
//  how much of My Portfolio sits in the theme.
//
//  Data: FMP's quarterly cash-flow and income statements through the accounts service (GET /fundamentals/quarters):
//  the security master's copy when MxDataHUB keeps it current (srm.fundamental_quarter, srm.py load fmp-fundamentals),
//  else FMP itself with SRM's key — real reported figures, kept 12 hours by the service.
//

import Charts
import SwiftUI

// MARK: - Data

/// A company in the compute theme.
nonisolated struct ComputeCompany: Identifiable, Hashable, Sendable {
    var symbol: String
    var name: String
    /// What it does in the theme.
    var role: String
    var id: String { symbol }

    /// The hyperscalers: the cloud and AI platforms whose capex builds the compute.
    static let hyperscalers: [ComputeCompany] = [
        .init(symbol: "MSFT", name: "Microsoft", role: "Azure; fiscal year ends in June"),
        .init(symbol: "GOOGL", name: "Alphabet", role: "Google Cloud, Search and DeepMind"),
        .init(symbol: "AMZN", name: "Amazon", role: "AWS"),
        .init(symbol: "META", name: "Meta Platforms", role: "AI for its own apps"),
        .init(symbol: "ORCL", name: "Oracle", role: "Oracle Cloud Infrastructure; fiscal year ends in May"),
    ]

    /// Where the money goes: the suppliers of compute.
    static let suppliers: [ComputeCompany] = [
        .init(symbol: "NVDA", name: "Nvidia", role: "GPUs and AI systems"),
        .init(symbol: "AVGO", name: "Broadcom", role: "Custom AI chips and networking"),
        .init(symbol: "AMD", name: "AMD", role: "GPUs and server CPUs"),
        .init(symbol: "MU", name: "Micron", role: "High-bandwidth memory"),
        .init(symbol: "ANET", name: "Arista Networks", role: "Data-centre networking"),
        .init(symbol: "VRT", name: "Vertiv", role: "Power and cooling"),
        .init(symbol: "EQIX", name: "Equinix", role: "Data-centre space"),
    ]

    static let all = hyperscalers + suppliers
}

/// One reported quarter (amounts in dollars; capex positive).
nonisolated struct ComputeQuarter: Decodable, Sendable {
    var date: String
    var fiscalYear: String?
    var period: String?
    var revenue: Double?
    var operatingCashFlow: Double?
    var capex: Double?
    var depreciation: Double?
    var freeCashFlow: Double?

    /// The calendar quarter the fiscal quarter ended in (fiscal years differ: Microsoft's ends in June, Oracle's in May).
    var calendarQuarter: CalendarQuarter? { CalendarQuarter(date) }
    var fiscalLabel: String { [period, fiscalYear.map { "FY\($0)" }].compactMap { $0 }.joined(separator: " ") }
}

nonisolated struct CalendarQuarter: Hashable, Comparable, Sendable {
    var year: Int
    var quarter: Int

    init?(_ isoDate: String) {
        let p = isoDate.split(separator: "-")
        guard p.count >= 2, let y = Int(p[0]), let m = Int(p[1]), (1...12).contains(m) else { return nil }
        year = y
        quarter = (m - 1) / 3 + 1
    }

    init(year: Int, quarter: Int) {
        self.year = year
        self.quarter = quarter
    }

    var label: String { "Q\(quarter) ’\(String(format: "%02d", year % 100))" }
    var yearEarlier: CalendarQuarter { CalendarQuarter(year: year - 1, quarter: quarter) }
    static func < (a: Self, b: Self) -> Bool { (a.year, a.quarter) < (b.year, b.quarter) }
}

private nonisolated struct FundamentalsPage: Decodable, Sendable {
    var symbol: String
    /// Where the service read them: the security master, or FMP.
    var source: String?
    var rows: [ComputeQuarter]
}

/// One company's quarters, or why they couldn't be read (a struct, not a tuple: concurrent child tasks returning
/// tuples lose their results in this toolchain).
private nonisolated struct ComputeFetch: Sendable {
    var symbol: String
    var rows: [ComputeQuarter]
    var problem: String?
    var source: String?
}

/// Figures over the last four reported quarters of one company.
nonisolated struct ComputeTTM: Sendable {
    var capex = 0.0, revenue = 0.0, operatingCashFlow = 0.0, depreciation = 0.0, freeCashFlow = 0.0
    var capexYearEarlier: Double?
    var revenueYearEarlier: Double?

    init(_ rows: [ComputeQuarter]) {
        // Newest first: the last four, and the four before them a year earlier.
        let now = Array(rows.prefix(4)), before = Array(rows.dropFirst(4).prefix(4))
        capex = now.compactMap(\.capex).reduce(0, +)
        revenue = now.compactMap(\.revenue).reduce(0, +)
        operatingCashFlow = now.compactMap(\.operatingCashFlow).reduce(0, +)
        depreciation = now.compactMap(\.depreciation).reduce(0, +)
        freeCashFlow = now.compactMap(\.freeCashFlow).reduce(0, +)
        if before.count == 4 {
            capexYearEarlier = before.compactMap(\.capex).reduce(0, +)
            revenueYearEarlier = before.compactMap(\.revenue).reduce(0, +)
        }
    }

    var capexGrowth: Double? { capexYearEarlier.flatMap { $0 > 0 ? capex / $0 - 1 : nil } }
    var revenueGrowth: Double? { revenueYearEarlier.flatMap { $0 > 0 ? revenue / $0 - 1 : nil } }
    var capexToRevenue: Double? { revenue > 0 ? capex / revenue : nil }
    var capexToCashFlow: Double? { operatingCashFlow > 0 ? capex / operatingCashFlow : nil }
}

@MainActor
@Observable
final class ComputeStore {
    static let shared = ComputeStore()

    /// By symbol, newest quarter first.
    private(set) var quarters: [String: [ComputeQuarter]] = [:]
    private(set) var problems: [String: String] = [:]
    /// By symbol: where its quarters came from (the service's `source`).
    private(set) var sources: [String: String] = [:]
    private(set) var loading = false
    private(set) var loadedAt: Date?

    func rows(_ symbol: String) -> [ComputeQuarter] { quarters[symbol] ?? [] }

    /// Reads every company's quarters through the accounts service (it keeps FMP's answers 12 hours).
    func load(force: Bool = false) async {
        guard !loading, force || quarters.isEmpty || Date().timeIntervalSince(loadedAt ?? .distantPast) > 3600 else { return }
        loading = true
        let results = await withTaskGroup(of: ComputeFetch.self) { group in
            for c in ComputeCompany.all { group.addTask { await Self.fetch(c.symbol) } }
            var out: [ComputeFetch] = []
            for await r in group { out.append(r) }
            return out
        }
        for r in results {
            if !r.rows.isEmpty { quarters[r.symbol] = r.rows }
            problems[r.symbol] = r.problem
            sources[r.symbol] = r.source
        }
        loadedAt = Date()
        loading = false
    }

    private nonisolated static func fetch(_ symbol: String) async -> ComputeFetch {
        guard let url = URL(string: AccountsClient.base + "/fundamentals/quarters?symbol=\(symbol)&limit=40") else {
            return ComputeFetch(symbol: symbol, rows: [], problem: "bad symbol")
        }
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 90))
        } catch {
            return ComputeFetch(symbol: symbol, rows: [], problem: "The accounts service isn't running: python3 Services/mxservices.py start accounts")
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let error = json["error"] as? String {
            let missing = error.contains("no such endpoint")
            return ComputeFetch(symbol: symbol, rows: [], problem: missing
                ? "The accounts service has no fundamentals endpoint yet — restart it: python3 Services/mxservices.py restart accounts"
                : "FMP through the accounts service: \(error)")
        }
        guard let page = try? JSONDecoder().decode(FundamentalsPage.self, from: data) else {
            return ComputeFetch(symbol: symbol, rows: [], problem: "The accounts service's answer couldn't be read.")
        }
        return ComputeFetch(symbol: symbol, rows: page.rows.sorted { $0.date > $1.date }, source: page.source)
    }
}

// MARK: - The screen

/// A row of the hyperscalers' table.
private struct SpenderRow: Identifiable {
    var company: ComputeCompany
    var latest: ComputeQuarter
    var latestYoY: Double?
    var ttm: ComputeTTM
    var id: String { company.symbol }
}

/// A row of the suppliers' table.
private struct SupplierRow: Identifiable {
    var company: ComputeCompany
    var latest: ComputeQuarter
    var ttm: ComputeTTM
    var id: String { company.symbol }
}

/// One bar segment / point: a company's amount in a calendar quarter.
private struct QuarterAmount: Identifiable {
    var quarter: CalendarQuarter
    var name: String
    var amount: Double
    var id: String { "\(quarter.label)|\(name)" }
}

struct ComputeView: View {
    @Bindable var store: PortStore
    @State private var compute = ComputeStore.shared
    @State private var span = 12
    @State private var spenderSelection = Set<String>()
    @State private var supplierSelection = Set<String>()

    private static func billions(_ x: Double) -> String { String(format: "$%.1fB", x / 1e9) }
    private static func signed(_ x: Double?) -> String { x.map { String(format: "%+.0f%%", $0 * 100) } ?? "—" }
    private static func share(_ x: Double?) -> String { x.map { String(format: "%.0f%%", $0 * 100) } ?? "—" }

    private static let spendersText = TableText<SpenderRow>(
        titles: ["Company", "Latest quarter", "Ended", "Capex", "vs a year earlier", "Capex, last 4 quarters", "Growth",
                 "Capex / revenue", "Capex / operating cash flow", "Depreciation, last 4 quarters", "Free cash flow, last 4 quarters"]) { r in
        [r.company.name, r.latest.fiscalLabel, r.latest.date, billions(r.latest.capex ?? 0), signed(r.latestYoY), billions(r.ttm.capex),
         signed(r.ttm.capexGrowth), share(r.ttm.capexToRevenue), share(r.ttm.capexToCashFlow), billions(r.ttm.depreciation), billions(r.ttm.freeCashFlow)]
    }

    private static let suppliersText = TableText<SupplierRow>(
        titles: ["Company", "Role", "Latest quarter", "Ended", "Revenue, last 4 quarters", "Growth"]) { r in
        [r.company.name, r.company.role, r.latest.fiscalLabel, r.latest.date, billions(r.ttm.revenue), signed(r.ttm.revenueGrowth)]
    }

    var body: some View {
        StepPage(store: store, subtitle: "AI compute as an asset theme, followed through what the hyperscalers spend to build it — real reported figures.", lesson: [
            "Compute — data centres, AI chips, memory, networking, power — is being built mostly by five companies: Microsoft, Alphabet, Amazon, Meta and Oracle. Their capital expenditure (capex) is the best public measure of how fast it is growing.",
            "Their capex is their suppliers' revenue: when the hyperscalers spend more, chip, memory, networking and power companies sell more. Watching capex, and what the hyperscalers say about it on their earnings calls, is how professionals follow the theme.",
            "Building ahead of demand has happened before: telecom companies laid far more fibre around 2000 than was used for years, and their suppliers' shares fell 80–90%. Spending rising faster than revenue, and depreciation catching up, are what to watch.",
            "An S&P 500 index fund already holds these companies, and in large weights. Check how much of your account is in the theme before adding more.",
        ]) {
            let spenders = spenderRows
            if spenders.isEmpty {
                loadingBox
            } else {
                combined(spenders)
                spendersBox(spenders)
                intensity
                suppliersBox
                exposure
                reading
                dataBox
            }
        }
        .task { await compute.load() }
    }

    // MARK: Rows

    private var spenderRows: [SpenderRow] {
        ComputeCompany.hyperscalers.compactMap { c in
            let rows = compute.rows(c.symbol)
            guard let latest = rows.first else { return nil }
            let yoy: Double? = rows.count > 4 ? rows[4].capex.flatMap { prior in latest.capex.map { $0 / prior - 1 } } : nil
            return SpenderRow(company: c, latest: latest, latestYoY: yoy, ttm: ComputeTTM(rows))
        }
    }

    private var supplierRows: [SupplierRow] {
        ComputeCompany.suppliers.compactMap { c in
            let rows = compute.rows(c.symbol)
            guard let latest = rows.first else { return nil }
            return SupplierRow(company: c, latest: latest, ttm: ComputeTTM(rows))
        }
    }

    /// Each hyperscaler's capex by calendar quarter.
    private var capexByQuarter: [QuarterAmount] {
        ComputeCompany.hyperscalers.flatMap { c in
            compute.rows(c.symbol).compactMap { q -> QuarterAmount? in
                guard let cq = q.calendarQuarter, let capex = q.capex else { return nil }
                return QuarterAmount(quarter: cq, name: c.name, amount: capex)
            }
        }
    }

    /// The calendar quarters every hyperscaler has reported, oldest first.
    private var completeQuarters: [CalendarQuarter] {
        let byCompany = Dictionary(grouping: capexByQuarter, by: \.name).mapValues { Set($0.map(\.quarter)) }
        guard byCompany.count == ComputeCompany.hyperscalers.count else { return [] }
        return byCompany.values.dropFirst().reduce(byCompany.values.first!) { $0.intersection($1) }.sorted()
    }

    // MARK: Parts

    private var loadingBox: some View {
        Box(title: "Compute Hyperscalers Tracking", symbol: "cpu") {
            if compute.loading {
                HStack { ProgressView().controlSize(.small); Text("Reading the hyperscalers' statements (FMP, through the accounts service)…").foregroundStyle(.secondary) }
            } else {
                Text(compute.problems.values.first ?? "No data yet.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { Task { await compute.load(force: true) } }
            }
        }
    }

    private func combined(_ spenders: [SpenderRow]) -> some View {
        let byQuarter = Dictionary(grouping: capexByQuarter, by: \.quarter).mapValues { $0.reduce(0) { $0 + $1.amount } }
        let complete = completeQuarters
        let last = complete.last
        let lastAmount = last.flatMap { byQuarter[$0] } ?? 0
        let yearEarlier = last.flatMap { byQuarter[$0.yearEarlier] }
        let ttm = spenders.reduce(0) { $0 + $1.ttm.capex }
        let ttmPrior = spenders.compactMap(\.ttm.capexYearEarlier)
        let ttmGrowth = ttmPrior.count == spenders.count ? ttm / ttmPrior.reduce(0, +) - 1 : nil
        let cash = spenders.reduce(0) { $0 + $1.ttm.operatingCashFlow }
        let revenue = spenders.reduce(0) { $0 + $1.ttm.revenue }
        let shown = Array(byQuarter.keys.sorted().suffix(span))
        let bars = capexByQuarter.filter { shown.contains($0.quarter) }.sorted { $0.quarter < $1.quarter }
        return Box(title: "The hyperscalers' capex", symbol: "building.2",
                   help: "Capital expenditure of Microsoft, Alphabet, Amazon, Meta and Oracle, each quarter by the calendar quarter it ended in.") {
            HStack(spacing: 10) {
                MetricTile(title: "Combined, \(last?.label ?? "latest quarter")", value: Self.billions(lastAmount),
                           caption: "\(Self.signed(yearEarlier.map { lastAmount / $0 - 1 })) from a year earlier",
                           tint: .accentColor, help: "The five hyperscalers' capex in the latest calendar quarter all of them have reported.")
                MetricTile(title: "Last four quarters", value: Self.billions(ttm), caption: "\(Self.signed(ttmGrowth)) from the four before",
                           help: "The sum of each company's last four reported quarters, against the four before them.")
                MetricTile(title: "Of their operating cash flow", value: Self.share(cash > 0 ? ttm / cash : nil),
                           caption: "last four quarters", tint: cash > 0 && ttm / cash > 0.75 ? .orange : .primary,
                           help: "Capex as a share of the cash their businesses produce. Near or above 100% means the build-out uses all of it.")
                MetricTile(title: "Of their revenue", value: Self.share(revenue > 0 ? ttm / revenue : nil), caption: "last four quarters",
                           help: "Capex as a share of revenue: capital intensity. Software companies used to run near 10%.")
            }
            Picker("Quarters", selection: $span) {
                Text("3 years").tag(12)
                Text("5 years").tag(20)
                Text("10 years").tag(40)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)
            Chart(bars) { b in
                BarMark(x: .value("Quarter", b.quarter.label), y: .value("Capex ($B)", b.amount / 1e9))
                    .foregroundStyle(by: .value("Company", b.name))
            }
            .chartYAxisLabel("capex, $ billions")
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 12)) }
            .frame(height: 280)
            Text("Each company's quarter is placed by the calendar quarter it ended in; Microsoft's and Oracle's fiscal years end in June and May. The latest bar can be missing companies that haven't reported yet.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func spendersBox(_ rows: [SpenderRow]) -> some View {
        Box(title: "Company by company", symbol: "tablecells", help: "Each hyperscaler's latest quarter and last four quarters. Select rows and ⌘C to copy.") {
            Table(rows, selection: $spenderSelection) {
                TableColumn("Company") { r in Text(r.company.name).help(r.company.role) }.width(min: 90, ideal: 110)
                TableColumn("Latest") { r in Text("\(r.latest.fiscalLabel) · \(r.latest.date)").foregroundStyle(.secondary) }.width(min: 120, ideal: 150)
                TableColumn("Capex") { r in Text(Self.billions(r.latest.capex ?? 0)).monospacedDigit() }.width(70)
                TableColumn("vs yr ago") { r in Text(Self.signed(r.latestYoY)).monospacedDigit().foregroundStyle(Color.signed(r.latestYoY ?? 0)) }.width(70)
                TableColumn("Last 4 qtrs") { r in Text(Self.billions(r.ttm.capex)).monospacedDigit() }.width(80)
                TableColumn("Growth") { r in Text(Self.signed(r.ttm.capexGrowth)).monospacedDigit() }.width(60)
                TableColumn("/ revenue") { r in Text(Self.share(r.ttm.capexToRevenue)).monospacedDigit() }.width(70)
                TableColumn("/ cash flow") { r in
                    Text(Self.share(r.ttm.capexToCashFlow)).monospacedDigit()
                        .foregroundStyle((r.ttm.capexToCashFlow ?? 0) > 0.9 ? .orange : .primary)
                }.width(75)
                TableColumn("Depreciation") { r in Text(Self.billions(r.ttm.depreciation)).monospacedDigit() }.width(85)
                TableColumn("Free cash flow") { r in Text(Self.billions(r.ttm.freeCashFlow)).monospacedDigit().foregroundStyle(Color.signed(r.ttm.freeCashFlow)) }.width(95)
            }
            .tableText()
            .copyRowsMenu(rows, as: Self.spendersText)
            .copiesSelectedRows(rows, selected: spenderSelection, as: Self.spendersText)
            .frame(minHeight: CGFloat(rows.count) * 26 + 34)
            Text("Last 4 qtrs, growth, / revenue, / cash flow, depreciation and free cash flow are over each company's last four reported quarters. Cash flow is operating cash flow; capex above it means borrowing or savings fund the rest.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Capex as a share of revenue over the last four quarters, quarter by quarter.
    private var intensity: some View {
        let points: [QuarterAmount] = ComputeCompany.hyperscalers.flatMap { c -> [QuarterAmount] in
            let rows = compute.rows(c.symbol)
            return rows.indices.compactMap { i -> QuarterAmount? in
                guard i + 4 <= rows.count, let cq = rows[i].calendarQuarter else { return nil }
                let ttm = ComputeTTM(Array(rows[i...]))
                return ttm.capexToRevenue.map { QuarterAmount(quarter: cq, name: c.name, amount: $0 * 100) }
            }
        }
        let quarters = Set(Set(points.map(\.quarter)).sorted().suffix(span))
        let shown = points.filter { quarters.contains($0.quarter) }.sorted { $0.quarter < $1.quarter }
        return Box(title: "Capital intensity", symbol: "chart.line.uptrend.xyaxis",
                   help: "Capex as a share of revenue, over each company's last four quarters at each point.") {
            Chart(shown) { p in
                LineMark(x: .value("Quarter", p.quarter.label), y: .value("Capex / revenue (%)", p.amount))
                    .foregroundStyle(by: .value("Company", p.name))
                    .interpolationMethod(.monotone)
            }
            .chartYAxisLabel("capex as % of revenue")
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 12)) }
            .frame(height: 240)
            Text("Rising intensity means each dollar of sales carries more build-out. It pays off if the new capacity earns revenue; if it doesn't, depreciation on it weighs on profits for years.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var suppliersBox: some View {
        let rows = supplierRows
        let supplierTTM = rows.reduce(0) { $0 + $1.ttm.revenue }
        let supplierPrior = rows.compactMap(\.ttm.revenueYearEarlier)
        return Box(title: "Where the money goes", symbol: "arrow.triangle.branch",
                   help: "Revenue of the companies the hyperscalers buy compute from, over their last four quarters.") {
            Text(String(format: "Together these suppliers sold %@ over their last four quarters, %@ from the four before — much of it to the five hyperscalers above.",
                        Self.billions(supplierTTM), Self.signed(supplierPrior.count == rows.count && !rows.isEmpty ? supplierTTM / supplierPrior.reduce(0, +) - 1 : nil)))
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Table(rows, selection: $supplierSelection) {
                TableColumn("Company") { r in Text(r.company.name) }.width(min: 100, ideal: 120)
                TableColumn("Role") { r in Text(r.company.role).foregroundStyle(.secondary) }.width(min: 150, ideal: 200)
                TableColumn("Latest") { r in Text("\(r.latest.fiscalLabel) · \(r.latest.date)").foregroundStyle(.secondary) }.width(min: 120, ideal: 150)
                TableColumn("Revenue, last 4 qtrs") { r in Text(Self.billions(r.ttm.revenue)).monospacedDigit() }.width(120)
                TableColumn("Growth") { r in Text(Self.signed(r.ttm.revenueGrowth)).monospacedDigit().foregroundStyle(Color.signed(r.ttm.revenueGrowth ?? 0)) }.width(70)
            }
            .tableText()
            .copyRowsMenu(rows, as: Self.suppliersText)
            .copiesSelectedRows(rows, selected: supplierSelection, as: Self.suppliersText)
            .frame(minHeight: CGFloat(rows.count) * 26 + 34)
        }
    }

    private var exposure: some View {
        let p = store.portfolio
        let symbols = Set(ComputeCompany.all.map(\.symbol) + ["GOOG"])
        let held = p.holdings.filter { symbols.contains($0.ticker.uppercased()) }
        let weight = held.reduce(0) { $0 + p.weight($1) }
        return Box(title: "Your exposure", symbol: "person.crop.circle",
                   help: "How much of the account selected in the toolbar is in the compute companies directly.") {
            if p.isSRM {
                if held.isEmpty {
                    Text("\(p.name) holds none of these companies directly. Index funds in it may still hold them: an S&P 500 fund has a large share in them.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("\(pct(weight)) of \(p.name) is in these companies directly: " + held.map { "\($0.ticker) \(pct(p.weight($0)))" }.joined(separator: ", ") + ". Index funds in it add more.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("\(p.name) hasn't been read from the security master yet.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var reading: some View {
        Box(title: "Reading the capex", symbol: "text.magnifyingglass", help: "What to look for, and what the numbers don't tell you.") {
            SelectableText(text: {
                var l = RichLines()
                l.bullets([
                    "Guidance moves markets more than the reported quarter: listen for next year's capex plans on the hyperscalers' earnings calls (Earnings Calendar, Earnings by Day).",
                    "Capex growing faster than revenue for long means the payoff is still ahead; operating cash flow is the limit before borrowing starts.",
                    "Depreciation follows capex by a few years: servers and chips wear out in about five, buildings in decades. Rising depreciation lowers reported profits even while cash flow is fine.",
                    "The suppliers' revenue depends on a handful of customers. A pause by one hyperscaler shows up in their results within a quarter or two.",
                    "Power and permits are now limits too: some capex goes to electricity and cooling, not only chips.",
                    "This is a theme, not a forecast. For a long-term plan, knowing how much you hold matters more than predicting the next quarter.",
                ], font: RichLines.calloutFont)
                return l.result
            }())
        }
    }

    private var dataBox: some View {
        Box(title: "Data", symbol: "arrow.up.right.square", help: "Where the figures come from.") {
            let missing = compute.problems.filter { $0.value.isEmpty == false }
            let kept = compute.sources.filter { $0.value.hasPrefix("security master") }.keys.sorted()
            Text("Quarterly cash-flow and income statements as reported, from Financial Modeling Prep through the accounts service (port 8774), kept 12 hours"
                 + (kept.isEmpty ? "" : kept.count == compute.sources.count
                    ? " — all read from the security master's copy (MxDataHUB, srm.py load fmp-fundamentals)"
                    : " — from the security master's copy for " + kept.joined(separator: ", ") + ", from FMP for the rest")
                 + ". Capex is purchases of property, plant and equipment.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !missing.isEmpty {
                Label("Not read: " + missing.keys.sorted().joined(separator: ", ") + " — " + (missing.values.first ?? ""), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await compute.load(force: true) } }
                    .disabled(compute.loading)
                    .help("Read the statements again")
                if compute.loading { ProgressView().controlSize(.small) }
            }
        }
    }
}
