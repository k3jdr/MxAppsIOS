//
//  PathViews.swift
//  MxAcctMGR
//
//  The Investments screens, active and passive alike, and the active approach's own: the holdings and the benchmark,
//  today's risk, the active optimizer, the trades and their taxes, and attribution.
//

import Charts
import AppKit
import SwiftUI

private func isPassive(_ store: PortStore) -> Bool { store.passiveContext }

// MARK: - My Holdings / My Benchmark

struct PortfolioView: View {
    enum Part { case holdings, benchmark }
    @Bindable var store: PortStore
    var part: Part

    var body: some View {
        let p = store.portfolio
        let passive = isPassive(store)
        StepPage(store: store, subtitle: subtitle, lesson: lesson(p, passive)) {
            if part == .holdings {
                // The account's holdings first, as tall as they need.
                if p.id == "mine" { addRow }
                HoldingsTable(store: store)
            }
            if part != .benchmark {
                HStack(spacing: 10) {
                    MetricTile(title: "Value", value: money(p.total), caption: p.account.rawValue, help: "Market value of the account's holdings.")
                    MetricTile(title: "Holdings", value: "\(p.holdings.count)", caption: "\(p.lookThrough.count) securities by look-through", help: "Positions as held, and the number of different securities once funds are replaced by what they hold.")
                    MetricTile(title: "Weighted fee", value: pct(p.weightedFee, 2), caption: "a year, from fund fees", help: "Fund expense ratios weighted by position size. Single stocks have no fee.")
                    MetricTile(title: "Unrealised gain", value: money(p.holdings.reduce(0) { $0 + $1.unrealizedGain }), caption: p.account.isTaxable ? "taxed when sold" : "no tax in this account type",
                               tint: Color.signed(p.holdings.reduce(0) { $0 + $1.unrealizedGain }), help: "Value minus cost basis across tax lots. In a taxable account, selling realises it.")
                }
            }
            if part != .holdings { benchmarkBox(p) }
            if !p.issues.isEmpty && part != .benchmark {
                CollapsibleBox(store: store, id: "checks-\(store.screen.rawValue)", title: "Check before you go on",
                               summary: issueSummary(p.issues), symbol: "checklist",
                               help: "Problems in the account's data and concentration that change what the tools can tell you. Click the title to show or hide them.") {
                    ForEach(p.issues) { IssueRow(issue: $0) }
                }
            }
            if part == .holdings {
                Box(title: "Asset mix", symbol: "chart.pie", help: "Stocks, bonds and cash by look-through.") {
                    let mine = p.classWeights()
                    HBars(series: [.init(name: "Account", color: .accentColor)],
                          rows: AssetClass.allCases.map { c in .init(label: c.rawValue, values: [(mine[c] ?? 0) * 100]) }, labelWidth: 50)
                }
            } else {
                HStack(alignment: .top, spacing: 14) {
                    Box(title: "Sectors: account vs benchmark (look-through)", symbol: "chart.bar", help: "Each sector's weight in the account (funds looked through) beside its weight in the benchmark. The gaps are the account's sector bets.") {
                        SectorChart(account: p.sectorWeights(), benchmark: Portfolio.sectors(of: p.benchmarkInfo.weights))
                    }
                    Box(title: "Asset mix", symbol: "chart.pie", help: "Stocks, bonds and cash by look-through, against the benchmark's mix.") {
                        let mine = p.classWeights(), bench = Portfolio.classes(of: p.benchmarkInfo.weights)
                        HBars(series: [.init(name: "Account", color: .accentColor), .init(name: "Benchmark", color: .gray.opacity(0.6))],
                              rows: AssetClass.allCases.map { c in .init(label: c.rawValue, values: [(mine[c] ?? 0) * 100, (bench[c] ?? 0) * 100]) },
                              labelWidth: 50)
                    }
                    .frame(width: 340)
                }
                constituents(p)
            }
        }
        .task(id: p.benchmark) { if p.isSRM { await store.useSRMBenchmark(p.benchmark) } }
    }

    private func issueSummary(_ issues: [Portfolio.Issue]) -> String {
        let counts = [(Portfolio.Issue.Level.error, "error"), (.warning, "warning"), (.note, "note")].compactMap { level, name -> String? in
            let n = issues.filter { $0.level == level }.count
            return n == 0 ? nil : "\(n) \(name)\(n == 1 ? "" : "s")"
        }
        return counts.joined(separator: " · ")
    }

    private var subtitle: String {
        switch part {
        case .holdings: store.portfolio.isSRM ? "What the account holds, from the security master: real securities, prices and tax lots." : "What the account holds: positions, values and tax lots."
        case .benchmark: "The portfolio the account is measured against — choose the one that matches your plan."
        }
    }

    private func lesson(_ p: Portfolio, _ passive: Bool) -> [String] {
        switch part {
        case .holdings: return [
            "Start with what you actually own: each position, what it is worth today and what you paid for it (tax lots).",
            "Look through funds to what they hold — an index fund plus a few single stocks may double up on the same names.",
            "Fix the data first. A holding without a price can't be valued, tracked or rebalanced reliably.",
        ]
        case .benchmark: return [
            "A benchmark is the portfolio you would hold with no opinions; every difference from it is a bet — and a risk.",
            "Choose one that matches the plan: an all-stock index for an all-stock account; a blend for an account that also holds bonds and cash. Measured against the wrong one, sensible holdings look like big bets.",
            passive ? "For a passive account the benchmark is the index to follow; the next steps measure and close the gap." : "For an active account the benchmark is the starting point the optimizer departs from within a risk budget.",
        ]
        }
    }

    private func benchmarkBox(_ p: Portfolio) -> some View {
        Box(title: "Benchmark", symbol: "target", help: "The portfolio this account is measured against. Choose the one that matches your plan's stock / bond mix.") {
            Picker("Benchmark", selection: Binding(get: { p.benchmark }, set: { var q = p; q.benchmark = $0; store.portfolio = q })) {
                if p.isSRM {
                    ForEach(store.srmBenchmarks) { b in Text("\(b.code) — \(b.name)\(b.members.map { " (\($0) members)" } ?? "")").tag(b.code) }
                } else {
                    ForEach(Universe.benchmarks) { Text("\($0.code) — \($0.name)").tag($0.code) }
                }
            }
            .frame(maxWidth: 480)
            .help(p.isSRM ? "Benchmarks loaded in the security master" : "The benchmark the account is compared with")
            if p.id == "mine" {
                Button("Policy Benchmarks…") { store.showPolicyEditor = true }
                    .help("Define your own benchmark: index funds standing in for asset classes, with the mix you aim for and when it took effect (Portfolio ▸ Policy Benchmarks…)")
            }
            Text(p.benchmarkInfo.code == p.benchmark ? p.benchmarkInfo.summary : "Loading \(p.benchmark) from the security master…")
                .font(.callout).foregroundStyle(.secondary)
            if part == .benchmark {
                let w = p.lookThrough, b = p.benchmarkInfo.weights
                let overlap = Set(w.keys).union(b.keys).reduce(0) { $0 + min(w[$1] ?? 0, b[$1] ?? 0) }
                HStack(spacing: 10) {
                    MetricTile(title: "Members", value: "\(b.count)", help: "Securities in the benchmark.")
                    MetricTile(title: "Overlap", value: pct(overlap), caption: "weight held in common", help: "The sum over securities of the smaller of the account's and the benchmark's weight.")
                    MetricTile(title: "Active share", value: pct(1 - overlap), help: PortHelp.terms["Active share"]!)
                    MetricTile(title: "Names you hold in it", value: "\(w.keys.filter { b[$0] != nil }.count) of \(w.count)", help: "How many of the account's securities are benchmark members.")
                }
            }
        }
    }

    private func constituents(_ p: Portfolio) -> some View {
        let w = p.lookThrough
        let rows = p.benchmarkInfo.weights.sorted { $0.value > $1.value }.prefix(25)
        return Box(title: "Largest members", symbol: "list.number", help: "The benchmark's 25 largest members with the account's weight in each.") {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 3) {
                GridRow { Text("Security").bold(); Text("Sector").bold(); Text("Benchmark").bold(); Text("Account").bold(); Text("Active").bold() }
                ForEach(Array(rows), id: \.key) { k, v in
                    let s = Universe.security(k)
                    GridRow {
                        Text("\(s?.displayTicker ?? k) — \(s?.name ?? "")").lineLimit(1)
                        Text(s?.sector ?? "").foregroundStyle(.secondary)
                        Text(pct(v, 2)).monospacedDigit()
                        Text(pct(w[k] ?? 0, 2)).monospacedDigit()
                        Text(signedPct((w[k] ?? 0) - v)).monospacedDigit().foregroundStyle(Color.signed((w[k] ?? 0) - v))
                    }
                }
            }
            .textKind(.results)
        }
    }

    private var addRow: some View {
        HStack {
            Button { store.addingSecurities = true } label: { Label("Add Securities…", systemImage: "plus.circle.fill") }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .help("Find and add stocks, individual bonds, funds or cash (⇧⌘N)")
            Text(store.portfolio.isSRM ? "Double-click a holding (or its pencil) to edit its tax lots — purchase date, shares, cost — or the cash; edit shares in the table to resize a position (its lots scale); the trash button removes it. Changes are kept when you save (File ▸ Save, ⌘S)." : "Edit a value in the table to resize a holding; the trash button removes it.").font(.callout).foregroundStyle(.secondary)
            Spacer()
            if !store.portfolio.isSRM { Button("Reset My Portfolio") { store.resetMyPortfolio() } }
        }
        .sheet(isPresented: $store.addingSecurities) { AddSecuritiesSheet(store: store) }
        .quickHelpArea("Add Securities", "Opens a dialog to find companies, individual bonds (Treasuries, TIPS, corporates, high yield, municipal), funds and cash, see what each is and how it behaves, and add it by amount, shares or face value — with a tax lot for a taxable account.", shortcut: "⇧⌘N", symbol: "plus.circle")
    }
}

struct SectorChart: View {
    var account: [String: Double]
    var benchmark: [String: Double]

    var body: some View {
        let sectors = Array(Set(account.keys).union(benchmark.keys)).sorted { (account[$0] ?? 0) + (benchmark[$0] ?? 0) > (account[$1] ?? 0) + (benchmark[$1] ?? 0) }
        HBars(series: [.init(name: "Account", color: .accentColor), .init(name: "Benchmark", color: .gray.opacity(0.6))],
              rows: sectors.map { .init(label: $0, values: [(account[$0] ?? 0) * 100, (benchmark[$0] ?? 0) * 100]) })
    }
}

struct HoldingsTable: View {
    @Bindable var store: PortStore
    /// The holding whose lots are being edited (Edit Holding…).
    @State private var editing: EditTarget?
    struct EditTarget: Identifiable { let id: String }
    /// Column widths as the user drags them, kept for the window. Columns can be resized only: not hidden or moved.
    @SceneStorage("HoldingsTable.columns") private var columns = TableColumnCustomization<Holding>()

    var body: some View {
        let p = store.portfolio
        Box(title: "Holdings", symbol: "tablecells", help: "Each position: what it is, its value and weight, and in a taxable account its cost basis, gain and tax lots. In My Portfolio the values can be edited. ⌘K (Edit ▸ Link…) or a row's context menu adds a link to the ticker or name, with its own hover text.") {
            Table(p.holdings, selection: $store.holdingSelection, columnCustomization: $columns) {
                TableColumn("Ticker") { h in
                    if let t = LinkTarget.holding(h) {
                        LinkedCell(target: t, font: PortSettings.shared.font(.ids), color: h.security == nil || h.unpriced ? .red : .primary,
                                   help: h.unpriced ? "No price in the security master yet: valued at cost" : h.security?.priceDate.map { "Priced \($0)" })
                    } else {
                        Text(h.ticker).textKind(.ids)
                    }
                }
                .width(min: 50, ideal: 70)
                .customizationID("ticker").disabledCustomizationBehavior(Self.fixed)
                TableColumn("Name") { h in
                    if let t = LinkTarget.holding(h, .name) {
                        LinkedCell(target: t, color: h.security == nil ? .red : .primary)
                    } else {
                        Text(h.security?.name ?? "Cash")
                    }
                }
                .width(min: 80)
                .customizationID("name").disabledCustomizationBehavior(Self.fixed)
                TableColumn("Sector / class") { h in Text(h.security.map { $0.lookThrough != nil ? "Fund · \($0.assetClass.rawValue)" : $0.issuer.map { "Bond · \($0)" } ?? $0.sector } ?? "—") }
                    .width(min: 70, ideal: 170)
                    .customizationID("sector").disabledCustomizationBehavior(Self.fixed)
                TableColumn("Shares") { h in
                    if p.isSRM, h.ticker != "CASH" {
                        TextField("", value: Binding(get: { h.quantity ?? 0 }, set: { v in
                            var q = store.portfolio
                            if let i = q.holdings.firstIndex(where: { $0.ticker == h.ticker }) {
                                let old = max(q.holdings[i].quantity ?? 0, 1e-9)
                                q.holdings[i].value *= max(0, v) / old
                                q.holdings[i].lots = q.holdings[i].lots.map { var l = $0; l.costBasis *= max(0, v) / old; return l }
                                q.holdings[i].quantity = max(0, v)
                            }
                            q.holdings.removeAll { $0.value <= 0 || ($0.quantity ?? 1) <= 0 }
                            store.portfolio = q
                        }), format: .number.precision(.fractionLength(0...4)))
                        .help("Shares held; changing them scales the lots")
                    } else {
                        Text(h.quantity.map { String(format: "%.4g", $0) } ?? "—").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .width(min: 50, ideal: 80)
                .customizationID("shares").disabledCustomizationBehavior(Self.fixed)
                TableColumn("Value") { h in
                    if p.id == "mine" && (!p.isSRM || h.ticker == "CASH") {
                        TextField("", value: Binding(get: { h.value }, set: { v in
                            var q = store.portfolio
                            if let i = q.holdings.firstIndex(where: { $0.ticker == h.ticker }) { q.holdings[i].value = max(0, v) }
                            q.holdings.removeAll { $0.value <= 0 }
                            store.portfolio = q
                        }), format: .number.precision(.fractionLength(0)))
                    } else {
                        Text(money(h.value)).monospacedDigit()
                    }
                }
                .width(min: 60, ideal: 100)
                .customizationID("value").disabledCustomizationBehavior(Self.fixed)
                TableColumn("Weight") { h in Text(pct(p.weight(h))).monospacedDigit() }
                    .width(min: 40, ideal: 60)
                    .customizationID("weight").disabledCustomizationBehavior(Self.fixed)
                TableColumn("Cost basis") { h in Text(h.lots.isEmpty ? "—" : money(h.costBasis)).monospacedDigit() }
                    .width(min: 60, ideal: 100)
                    .customizationID("cost").disabledCustomizationBehavior(Self.fixed)
                TableColumn("Gain") { h in
                    Text(h.lots.isEmpty ? "—" : money(h.unrealizedGain)).monospacedDigit().foregroundStyle(h.lots.isEmpty ? .secondary : Color.signed(h.unrealizedGain))
                }
                .width(min: 60, ideal: 100)
                .customizationID("gain").disabledCustomizationBehavior(Self.fixed)
                TableColumn("Lots") { h in
                    Text(h.lots.map { "\($0.acquired) (\(pct($0.share, 0)))" }.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                        .help(h.lots.map { "\($0.acquired): \(pct($0.share, 0)) of the position, cost \(money($0.costBasis))" + ($0.note.map { " — \($0)" } ?? "") }.joined(separator: "\n"))
                }
                .width(min: 80)
                .customizationID("lots").disabledCustomizationBehavior(Self.fixed)
                TableColumn("") { h in
                    if p.id == "mine" {
                        HStack(spacing: 6) {
                            Button { editing = EditTarget(id: h.ticker) } label: { Image(systemName: "pencil") }
                                .buttonStyle(.borderless)
                                .help("Edit \(h.ticker == "CASH" ? "the cash" : "\(h.ticker)'s tax lots: purchase date, shares and cost") (or double-click the row)")
                            Button { store.removeFromMine(h.ticker) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .help("Remove \(h.ticker) from My Portfolio")
                        }
                    }
                }
                .width(48)
                .customizationID("actions").disabledCustomizationBehavior(.all)
            }
            .tableText()
            .contextMenu(forSelectionType: Holding.ID.self) { tickers in
                let chosen = p.holdings.filter { tickers.contains($0.ticker) }
                if chosen.count == 1, let h = chosen.first {
                    if p.id == "mine" {
                        Button("Edit Holding…") { editing = EditTarget(id: h.ticker) }
                        Divider()
                    }
                    if let t = LinkTarget.holding(h) {
                        linkMenu(t)
                        Divider()
                    }
                }
                if !chosen.isEmpty {
                    Button(chosen.count == 1 ? "Copy Row" : "Copy \(chosen.count) Rows") { copy(Self.rows(chosen, of: p)) }
                    Menu(chosen.count == 1 ? "Copy Column" : "Copy Column of \(chosen.count) Rows") {
                        ForEach(Self.titles.indices, id: \.self) { c in
                            Button(Self.titles[c]) { copy(Self.rows(chosen, of: p, columns: [c])) }
                        }
                    }
                }
            } primaryAction: { tickers in
                if p.id == "mine", tickers.count == 1, let ticker = tickers.first { editing = EditTarget(id: ticker) }
            }
            .sheet(item: $editing) { EditHoldingSheet(store: store, ticker: $0.id) }
            // Rows are selected, not their words: ⌘-click and ⇧-click select several, ⌘A all; Edit ▸ Copy (⌘C) copies
            // the selected rows with the columns' titles, and a row's context menu copies one column of them.
            .textSelection(.disabled)
            .onCopyCommand {
                let chosen = p.holdings.filter { store.holdingSelection.contains($0.ticker) }
                return chosen.isEmpty ? [] : [NSItemProvider(object: Self.rows(chosen, of: p) as NSString)]
            }
            // Every row visible, up to 40.
            .frame(minHeight: CGFloat(max(min(p.holdings.count, 40), 6)) * 26 + 34)
            // The links on the holdings, kept in the security master.
            .task(id: p.holdings.map(\.ticker)) {
                await SecurityLinks.shared.load(securityIDs: p.holdings.compactMap { LinkTarget.holding($0)?.securityID })
            }
        }
    }
}

extension HoldingsTable {
    /// The columns that can only be resized.
    static let fixed: TableColumnCustomizationBehavior = [.visibility, .reorder]
    static let titles = ["Ticker", "Name", "Sector / class", "Shares", "Value", "Weight", "Cost basis", "Gain", "Lots"]

    /// Holdings as lines of tab-separated columns under the columns' titles (they paste into a spreadsheet as a table);
    /// `columns` picks some of them (indexes into `titles`).
    static func rows(_ holdings: [Holding], of p: Portfolio, columns: [Int]? = nil) -> String {
        let pick = columns ?? Array(titles.indices)
        let lines = holdings.map { h in
            let sector: String = h.security.map { s -> String in
                s.lookThrough != nil ? "Fund · \(s.assetClass.rawValue)" : (s.issuer.map { "Bond · \($0)" } ?? s.sector)
            } ?? "—"
            let shares: String = h.quantity.map { $0.formatted(.number.precision(.fractionLength(0...6)).grouping(.never)) } ?? "—"
            let cost: String = h.lots.isEmpty ? "—" : money(h.costBasis)
            let gain: String = h.lots.isEmpty ? "—" : money(h.unrealizedGain)
            let lots: String = h.lots.map { "\($0.acquired) (\(pct($0.share, 0)))" }.joined(separator: ", ")
            let cells: [String] = [h.ticker, h.security?.name ?? "Cash", sector, shares, money(h.value), pct(p.weight(h)),
                                   cost, gain, lots]
            return pick.map { cells[$0] }.joined(separator: "\t")
        }
        return ([pick.map { titles[$0] }.joined(separator: "\t")] + lines).joined(separator: "\n")
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Risk today

struct RiskView: View {
    @Bindable var store: PortStore

    var body: some View {
        if store.portfolio.isSRM && store.inputs.n == 0 {
            SRMInputsPending(store: store)
        } else {
            report
        }
    }

    @ViewBuilder private var report: some View {
        let inputs = store.inputs
        let r = Engine.risk(inputs, weights: inputs.current)
        let value = store.portfolio.total
        StepPage(store: store, subtitle: "How much the account can move, where that risk comes from, and how far it sits from the benchmark.", lesson: [
            "Before changing anything, measure: an optimizer moves risk around, so you need to know where it is now.",
            "Risk is not shared out like weight. A volatile or concentrated holding can be a small part of the value and a large part of the risk — the contribution chart shows both.",
            "Tracking error is the risk of being different from the benchmark. It is what an active manager spends to try to beat it, and what a passive manager tries to keep near zero.",
        ]) {
            if store.portfolio.isSRM, let note = store.srmInputsNote {
                Label("Risk model from the analytics service and the security master's prices: \(note). Cash is not in the risk model.", systemImage: "cylinder.split.1x2")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                MetricTile(title: "Volatility", value: pct(r.volatility), caption: "benchmark \(pct(r.benchmarkVolatility))", help: PortHelp.terms["Volatility"]!)
                    .term("Volatility")
                MetricTile(title: "Tracking error", value: pct(r.trackingError, 2), caption: r.trackingError < 0.01 ? "index-like" : r.trackingError < 0.04 ? "moderately active" : "very active", help: PortHelp.terms["Tracking error"]!)
                MetricTile(title: "Beta", value: String(format: "%.2f", r.beta), caption: r.beta < 0.9 ? "more defensive" : r.beta > 1.1 ? "more aggressive" : "market-like", help: PortHelp.terms["Beta"]!)
                MetricTile(title: "VaR (95%, 1 month)", value: money(r.var95Month * value), caption: pct(r.var95Month) + " of the account", tint: .orange, help: PortHelp.terms["VaR (95%, 1 month)"]!)
                MetricTile(title: "Expected shortfall", value: money(r.es95Month * value), caption: "average of the worst 1 month in 20", tint: .red, help: PortHelp.terms["Expected shortfall"]!)
                MetricTile(title: "Rates +1 point", value: signedPct(r.rateSensitivity), caption: money(r.rateSensitivity * value), tint: Color.signed(r.rateSensitivity),
                           help: "The model's change in value if interest rates rose 1 point at once: mostly the bonds' duration, plus rate-sensitive stocks.")
            }
            HStack(alignment: .top, spacing: 14) {
                Box(title: "Weight vs share of risk (top 10)", symbol: "chart.bar.xaxis", help: "For the ten largest contributors: their share of the account's value and of its variance. A bar for risk much longer than for weight is a concentration of risk.") {
                    HBars(series: [.init(name: "Weight", color: .gray.opacity(0.6)), .init(name: "Share of risk", color: .orange)],
                          rows: r.contributions.prefix(10).map { .init(label: $0.name, values: [$0.weight * 100, $0.share * 100]) }, labelWidth: 60)
                    if let top = r.contributions.first {
                        Text("\(top.name) is \(pct(top.weight)) of the value and \(pct(top.share)) of the risk.").font(.callout)
                    }
                }
                Box(title: "Risk by sector", symbol: "square.stack.3d.up", help: "Each sector's share of the account's variance (funds looked through).") {
                    HBars(series: [.init(name: "Share of risk", color: .orange)],
                          rows: r.sectorContributions.map { .init(label: $0.name, values: [$0.share * 100]) })
                }
            }
            Box(title: "What drives the tracking error", symbol: "arrow.left.and.right", help: "The positions whose difference from the benchmark adds most to tracking error: active weight and share of active variance.") {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                    GridRow { Text("Security").bold(); Text("Active weight").bold(); Text("Share of tracking-error variance").bold() }
                    ForEach(r.activeContributions.prefix(8)) { c in
                        GridRow {
                            Text("\(c.name) — \(Universe.security(c.name)?.name ?? "")")
                            Text(signedPct(c.weight)).foregroundStyle(Color.signed(c.weight)).monospacedDigit()
                            Text(pct(c.share)).monospacedDigit()
                        }
                    }
                }
                .textKind(.results)
            }
        }
    }
}

// MARK: - Optimize

struct OptimizeView: View {
    @Bindable var store: PortStore

    var body: some View {
        StepPage(store: store, subtitle: "Turn forecasts into position sizes, inside limits you choose.", lesson: [
            "The optimizer maximises forecast active return minus a penalty for active risk, starting from the benchmark. Here the forecasts are the analytics service's momentum alpha for each company (12-1 month price momentum, scaled by an information coefficient) — a simple, transparent stand-in for the view a manager or a research service provides.",
            "The tracking-error target is your risk budget: how far from the benchmark you are willing to be. The weight, active-weight and sector limits stop the optimizer from betting everything on its favourite forecast.",
            "Read the result as a conversation: which limits bind tell you what is holding the portfolio back; the decision says whether the improvement is worth the trading.",
        ]) {
            settings
            if let r = store.activeResult {
                ResultSummary(result: r, active: true)
                HStack(alignment: .top, spacing: 14) {
                    Box(title: "Largest changes: today vs optimized", symbol: "arrow.left.arrow.right", help: "The fifteen positions that change most, with today's look-through weight, the optimized weight and the benchmark's.") {
                        WeightsChart(store: store, result: r)
                    }
                    Box(title: "Sector active weights", symbol: "chart.bar", help: "Optimized weight minus benchmark weight for each sector. The sector band keeps these within ± the band.") {
                        HBars(series: [.init(name: "Active", color: .accentColor)],
                              rows: r.sectorActive.sorted { $0.value > $1.value }.map { .init(label: $0.key, values: [$0.value * 100], colors: [Color.signed($0.value)]) })
                    }
                    .frame(width: 380)
                }
                HStack {
                    Spacer()
                    Button("Review the Trades and Taxes") { store.go(.myTrades) }.buttonStyle(.borderedProminent)
                }
            } else {
                ContentUnavailableView {
                    Label("Not Optimized Yet", systemImage: "wand.and.stars")
                } description: {
                    Text("Set the limits above and Optimize (⌘R).")
                }
                .frame(height: 200)
            }
        }
        .task(id: store.selectedID) {
            if store.activeResult == nil, store.engine == .builtIn { await store.optimize() }
        }
    }

    private var settings: some View {
        Box(title: "Limits", symbol: "slider.horizontal.3", help: "The optimizer's risk budget and limits. Change one and Optimize again to see what it does.") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                optionalRow("Tracking-error target", "Tracking error", value: $store.activeSettings.trackingErrorTarget, range: 0.005...0.08, step: 0.0025, default: 0.03,
                            explain: "Off: the risk aversion below sets the balance instead.")
                if store.activeSettings.trackingErrorTarget == nil {
                    GridRow {
                        Text("Risk aversion")
                        Slider(value: $store.activeSettings.riskAversion, in: 1...100, step: 1).frame(width: 260)
                        Text(String(format: "%.0f", store.activeSettings.riskAversion)).monospacedDigit()
                    }
                    .help("Higher: closer to the benchmark; lower: bigger bets")
                }
                row("Largest position", value: $store.activeSettings.maxWeight, range: 0.03...0.40, step: 0.01, help: "No security above this weight (unless the benchmark itself holds more, less the active-weight limit).")
                row("Largest active weight", value: $store.activeSettings.maxActiveWeight, range: 0.005...0.15, step: 0.005, help: "No security more than this far from its benchmark weight, over or under.")
                optionalRow("Sector band", "Active weight", value: $store.activeSettings.sectorBand, range: 0.01...0.20, step: 0.01, default: 0.05,
                            explain: "Keeps each sector within ± this of the benchmark's weight.")
                optionalRow("Turnover limit", "Turnover", value: $store.activeSettings.maxTurnover, range: 0.05...1, step: 0.05, default: 0.25,
                            explain: "Above it the decision is to rebalance part of the way.")
            }
            HStack {
                Button {
                    Task { await store.optimize() }
                } label: { Label("Optimize", systemImage: "wand.and.stars") }
                .buttonStyle(.borderedProminent)
                .disabled(store.busy)
                .help("Run the active optimizer (⌘R)")
                .quickHelp("Optimize", "Runs the active optimizer on this account with these limits — built-in, or portfolio-java when Engine is Layer 3 services.", shortcut: "⌘R")
                Text("Engine: \(store.engine.rawValue)").font(.caption).foregroundStyle(.secondary)
                if store.busy { ProgressView().controlSize(.small) }
            }
        }
    }

    private func row(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, help: String) -> some View {
        GridRow {
            Text(title)
            Slider(value: value, in: range, step: step).frame(width: 260)
            Text(pct(value.wrappedValue)).monospacedDigit()
        }
        .help(help)
        .quickHelpArea(QuickHelpItem(title: title, detail: help, symbol: "slider.horizontal.3"))
    }

    private func optionalRow(_ title: String, _ term: String, value: Binding<Double?>, range: ClosedRange<Double>, step: Double, default d: Double, explain: String) -> some View {
        GridRow {
            Toggle(title, isOn: Binding(get: { value.wrappedValue != nil }, set: { value.wrappedValue = $0 ? d : nil }))
            Slider(value: Binding(get: { value.wrappedValue ?? d }, set: { value.wrappedValue = $0 }), in: range, step: step)
                .frame(width: 260).disabled(value.wrappedValue == nil)
            Text(value.wrappedValue.map { pct($0, 2) } ?? "off").monospacedDigit()
        }
        .help(explain)
        .quickHelpArea(QuickHelpItem(title: title, detail: (PortHelp.terms[term] ?? "") + " " + explain, symbol: "slider.horizontal.3"))
    }
}

/// The decision and headline numbers of an optimization or tracker.
struct ResultSummary: View {
    var result: OptimizationResult
    var active: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon).font(.title).foregroundStyle(color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.decision.title).heading(.subheading)
                    Text(result.decision.reason).fixedSize(horizontal: false, vertical: true)
                    Text("\(result.engine) · \(result.status)\(result.method.map { " · " + $0.replacingOccurrences(of: "_", with: " ") } ?? "") · \(String(format: "%.0f", result.milliseconds)) ms")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .quickHelpArea(QuickHelpItem(title: "Decision: \(result.decision.recommendation.replacingOccurrences(of: "_", with: " "))",
                                         detail: "The same decision rules the Layer 3 services hand to MxJobsMGR agents: hold when turnover is under 2%, rebalance part of the way above the turnover limit, relax a limit that can't be met, otherwise rebalance. A rule of thumb for learning, not advice.",
                                         symbol: icon))
            HStack(spacing: 10) {
                MetricTile(title: "Tracking error", value: pct(result.trackingError, 2), caption: result.currentTrackingError.map { "today \(pct($0, 2))" } ?? "", help: PortHelp.terms["Tracking error"]!)
                if active {
                    MetricTile(title: "Information ratio", value: String(format: "%.2f", result.informationRatio ?? 0), caption: "forecast", help: PortHelp.terms["Information ratio"]!)
                    MetricTile(title: "Forecast active return", value: signedPct(result.activeAlpha ?? 0), caption: "a year, if the forecasts are right", help: "Alpha forecasts times active weights. Real results will differ: forecasts are uncertain.")
                } else {
                    MetricTile(title: "Index weight covered", value: pct(result.benchmarkCovered ?? 1), caption: "by the names held", help: "Share of the index's weight in the names the tracker holds.")
                }
                MetricTile(title: "Active share", value: pct(result.activeShare), help: PortHelp.terms["Active share"]!)
                MetricTile(title: "Turnover", value: pct(result.turnover), caption: "to get there", help: PortHelp.terms["Turnover"]!)
                MetricTile(title: "Names", value: "\(result.names)", help: "Securities held after the change.")
            }
            if !result.bindingConstraints.isEmpty {
                HStack(spacing: 6) {
                    Text("Limits that bind:").font(.callout.weight(.semibold))
                    ForEach(result.bindingConstraints, id: \.self) { c in
                        Text(c.replacingOccurrences(of: "_", with: " ")).font(.callout).padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15), in: Capsule())
                            .help(bindingHelp(c))
                            .quickHelpArea(QuickHelpItem(title: "Binding: \(c.replacingOccurrences(of: "_", with: " "))", detail: bindingHelp(c), symbol: "lock"))
                    }
                }
            }
        }
    }

    private func bindingHelp(_ c: String) -> String {
        switch c {
        case "max_weight": "Some position is at the largest weight allowed: the optimizer would like more of it."
        case "max_active_weight": "Some position is as far from its benchmark weight as allowed: the forecasts want a bigger bet."
        case "max_sector_active": "A sector is at the edge of its band: the bets are being held back by the sector limit."
        case "tracking_error_target": "The portfolio uses the whole risk budget."
        case "max_turnover": "Getting all the way there trades more than the turnover limit."
        default: c
        }
    }

    private var icon: String {
        switch result.decision.recommendation {
        case "hold": "pause.circle.fill"
        case "rebalance": "arrow.triangle.2.circlepath.circle.fill"
        case "rebalance_partially": "circle.lefthalf.filled"
        default: "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch result.decision.recommendation {
        case "hold", "rebalance": .green
        case "rebalance_partially": .blue
        default: .orange
        }
    }
}

struct WeightsChart: View {
    var store: PortStore
    var result: OptimizationResult

    var body: some View {
        let inputs = store.inputs
        let rows = inputs.assets.indices.map { i in (inputs.assets[i], inputs.current[i], result.weights[inputs.assets[i]] ?? 0, inputs.benchmark[i]) }
            .sorted { abs($0.2 - $0.1) > abs($1.2 - $1.1) }.prefix(15)
        HBars(series: [.init(name: "Today", color: .gray.opacity(0.6)), .init(name: "Optimized", color: .accentColor), .init(name: "Benchmark", color: .purple.opacity(0.5))],
              rows: rows.map { .init(label: $0.0, values: [$0.1 * 100, $0.2 * 100, $0.3 * 100]) }, labelWidth: 60)
    }
}

// MARK: - Trades & taxes

struct TradesView: View {
    @Bindable var store: PortStore
    @State private var fraction = 1.0
    @State private var tradeSelection = Set<Trade.ID>()
    private let costRate = 0.0015

    /// How a security is held today: directly, only through a fund, or not at all.
    private func held(_ t: Trade) -> String {
        store.portfolio.holdings.contains { $0.ticker == t.asset } ? "directly" : t.from > 0 ? "through a fund" : "new"
    }

    /// The trades table as text, for ⌘C and Copy Row (Shared/Copy/TableCopy.swift).
    private var tradesText: TableText<Trade> {
        TableText(titles: ["Side", "Security", "Today", "Target", "Change", "Amount", "Held"]) { t in
            [t.side, "\(t.asset) — \(Universe.security(t.asset)?.name ?? "")", pct(t.from, 2), pct(t.to, 2), signedPct(t.change),
             money(t.change * store.portfolio.total), held(t)]
        }
    }

    var body: some View {
        StepPage(store: store, subtitle: "What it takes to get there: the trades, their cost, and the taxes they trigger.", lesson: [
            "Every trade has a cost: the bid–ask spread and any commission (0.15% of the amount here). Turnover is the share of the account traded.",
            "In a taxable account selling realises gains. Long-held lots are taxed at the lower long-term rate; lots held a year or less at the higher short-term rate. Which lot you sell changes the bill for the same trade.",
            "You don't have to go all the way. Moving part of the way captures much of the improvement for less turnover and tax — the slider below shows how much.",
        ]) {
            if let r = store.activeResult {
                let trades = r.trades.map { Trade(asset: $0.asset, from: $0.from, to: $0.from + fraction * $0.change) }
                let estimate = store.taxEstimate(trades)
                let traded = trades.reduce(0) { $0 + abs($1.change) } * store.portfolio.total
                HStack(spacing: 10) {
                    MetricTile(title: "Turnover", value: pct(trades.reduce(0) { $0 + abs($1.change) } / 2), caption: money(traded / 2) + " bought and sold", help: PortHelp.terms["Turnover"]!)
                    MetricTile(title: "Trading cost", value: money(traded * costRate), caption: "at 0.15% per dollar traded", help: "Spread and commission on every buy and sell.")
                    MetricTile(title: "Realised gains", value: money(estimate.longTermGain + estimate.shortTermGain), caption: "long \(money(estimate.longTermGain)) · short \(money(estimate.shortTermGain))",
                               tint: Color.signed(estimate.longTermGain + estimate.shortTermGain), help: "Gains (and losses) realised by the sells, by lot.")
                    MetricTile(title: "Estimated tax", value: money(estimate.tax), caption: store.portfolio.account.isTaxable ? "at \(pct(store.longTermRate, 0)) / \(pct(store.shortTermRate, 0))" : "none in this account type",
                               tint: estimate.tax > 0 ? .red : .secondary, help: "Net gains taxed at the long- and short-term rates set below; losses offset gains. Illustrative rates, not tax advice.")
                }
                Box(title: "How far to go", symbol: "slider.horizontal.below.rectangle", help: "Trade part of the way to the optimized weights: less turnover, cost and tax, less of the improvement.") {
                    HStack {
                        Slider(value: $fraction, in: 0.1...1, step: 0.05) { Text("Part of the way") }
                            .frame(maxWidth: 420)
                            .help("Share of the way from today's weights to the optimized ones")
                        Text(pct(fraction, 0) + " of the way").monospacedDigit()
                    }
                }
                Box(title: "Trades", symbol: "list.bullet.rectangle", help: "Buys and sells in the securities (funds looked through), largest first. Names held only through a fund are traded by changing the fund or adding the name directly.") {
                    let shown = trades.filter { abs($0.change) > 1e-4 }
                    Table(shown, selection: $tradeSelection) {
                        TableColumn("Side") { t in Text(t.side).foregroundStyle(t.change > 0 ? .green : .red) }.width(50)
                        TableColumn("Security") { t in Text("\(t.asset) — \(Universe.security(t.asset)?.name ?? "")") }
                        TableColumn("Today") { t in Text(pct(t.from, 2)).monospacedDigit() }.width(70)
                        TableColumn("Target") { t in Text(pct(t.to, 2)).monospacedDigit() }.width(70)
                        TableColumn("Change") { t in Text(signedPct(t.change)).monospacedDigit() }.width(70)
                        TableColumn("Amount") { t in Text(money(t.change * store.portfolio.total)).monospacedDigit() }.width(100)
                        TableColumn("Held") { t in Text(held(t)).foregroundStyle(.secondary) }
                        .width(100)
                    }
                    .tableText()
                    // Select rows (⇧ / ⌘ for several, ⌘A for all); ⌘C or Copy Row copies them under the column titles.
                    .copyRowsMenu(shown, as: tradesText)
                    .copiesSelectedRows(shown, selected: tradeSelection, as: tradesText)
                    .frame(minHeight: 260)
                }
                TaxBox(store: store, estimate: estimate)
            } else {
                ContentUnavailableView {
                    Label("No Trades Yet", systemImage: "list.bullet.rectangle")
                } description: {
                    Text("Optimize the account first.")
                } actions: {
                    Button("Optimize…") { store.go(.myImprove) }
                }
                .frame(height: 220)
            }
        }
        .task(id: store.selectedID) {
            if store.activeResult == nil, store.engine == .builtIn { await store.optimize() }
        }
    }
}

struct TaxBox: View {
    @Bindable var store: PortStore
    var estimate: TaxEstimate

    var body: some View {
        Box(title: "Taxes by lot", symbol: "doc.text", help: "Which tax lots the sells come from, the gain on each and whether it is short- or long-term. Choose the lot order and the illustrative tax rates.") {
            HStack(spacing: 16) {
                Picker("Sell lots", selection: $store.lotOrder) {
                    ForEach(LotOrder.allCases) { Text($0.rawValue).tag($0) }
                }
                .frame(width: 280)
                .help("Which lots are sold first: the oldest, or those that cost most (usually the smallest gain)")
                .term("Tax lot")
                Stepper("Long-term rate \(pct(store.longTermRate, 0))", value: $store.longTermRate, in: 0...0.4, step: 0.01)
                Stepper("Short-term rate \(pct(store.shortTermRate, 0))", value: $store.shortTermRate, in: 0...0.5, step: 0.01)
            }
            if !store.portfolio.account.isTaxable {
                Label("This is a \(store.portfolio.account.rawValue.lowercased()) account: selling realises no tax today, so the lots don't matter here.", systemImage: "checkmark.shield")
                    .font(.callout)
            }
            if estimate.lines.isEmpty {
                Text("No sells from directly held positions.").foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 3) {
                    GridRow { Text("Security").bold(); Text("Lot bought").bold(); Text("Sold").bold(); Text("Gain").bold(); Text("Term").bold() }
                    ForEach(estimate.lines) { l in
                        GridRow {
                            Text(l.ticker)
                            Text(l.acquired)
                            Text(money(l.sold)).monospacedDigit()
                            Text(money(l.gain)).monospacedDigit().foregroundStyle(Color.signed(l.gain))
                            Text(l.shortTerm ? "short-term" : "long-term").foregroundStyle(l.shortTerm ? .orange : .secondary)
                        }
                    }
                }
                .textKind(.results)
            }
            if estimate.lines.contains(where: { $0.gain < 0 }) {
                Label("A sale at a loss can offset gains (tax-loss harvesting). Buying the same security back within 30 days before or after makes it a wash sale and the loss is disallowed — a similar, not identical, fund keeps the exposure.",
                      systemImage: "leaf").font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if !estimate.viaFunds.isEmpty {
                Text("Held only through funds, not estimated: \(estimate.viaFunds.prefix(12).joined(separator: ", "))\(estimate.viaFunds.count > 12 ? "…" : ""). Reducing them means selling part of a fund (its own lots) or simply not adding to them.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Illustrative tax arithmetic, not tax advice: real rules (state taxes, net investment income tax, carry-forwards) differ.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Attribution

struct AttributionView: View {
    @Bindable var store: PortStore

    var body: some View {
        let passive = isPassive(store)
        StepPage(store: store, subtitle: passive ? "Did the account do what an index portfolio should — follow the index?" : "Where last year's difference from the benchmark came from.",
                 lesson: passive ? [
                    "For a passive account attribution is a check-up: allocation and selection should both be close to zero. A large effect means drift (a sector grew away from the index) or a mistake (a missing name, idle cash).",
                    "Cash shows as allocation: in a rising year, money not invested costs return.",
                    "Small but steady negative selection is often fees and sampling: the price of holding fewer names than the index.",
                 ] : [
                    "Attribution splits the active return into allocation (sector weights), selection (companies within sectors) and interaction, month by month, linked over the year.",
                    "Compare it with the plan: if the plan was 'pick better companies' but allocation dominates, the result came from sector bets you may not have meant to make.",
                    "One year is a small sample. A good process can have a bad year; attribution over several years is what separates skill from luck.",
                 ]) {
            controls
            if let a = store.attribution {
                AttributionResultView(result: a, passive: passive)
            } else {
                ContentUnavailableView {
                    Label("No Attribution Yet", systemImage: "chart.bar.doc.horizontal")
                } description: {
                    Text("Run Attribution (⇧⌘A).")
                }
                .frame(height: 200)
            }
        }
        .task(id: "\(store.selectedID)\(store.attributionMethod.rawValue)\(store.attributeMaster)") {
            if store.attribution == nil, !store.attributeMaster { await store.attribute() }
        }
    }

    private var controls: some View {
        Box(title: "Attribute", symbol: "slider.horizontal.3", help: "What to attribute — the selected account, or another portfolio in the security master — with the analytics service, over its real holdings history and returns, and the method.") {
            HStack(spacing: 14) {
                Picker("Source", selection: $store.attributeMaster) {
                    Text("This account").tag(false)
                    Text("Another security-master portfolio").tag(true)
                }
                .frame(width: 420)
                .help("Attribute the account selected in the toolbar, or another portfolio from MxDataHUB, with the analytics service on port 8772")
                if store.attributeMaster {
                    TextField("Portfolio code", text: $store.masterPortfolio).frame(width: 160)
                        .help("A portfolio code from MxDataHUB ▸ Portfolios, e.g. DEMO_GROWTH")
                }
                Picker("Method", selection: $store.attributionMethod) {
                    ForEach(AttributionEngine.Method.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .frame(width: 280)
                .help("Brinson-Fachler measures allocation against the whole benchmark's return; Brinson-Hood-Beebower against zero")
                Button {
                    Task { await store.attribute() }
                } label: { Label("Run Attribution", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent)
                .disabled(store.busy)
                .quickHelp("Run Attribution", "Attributes the active return by sector, month by month, Carino-linked.", shortcut: "⇧⌘A")
            }
        }
    }
}

struct AttributionResultView: View {
    var result: AttributionResult
    var passive: Bool
    @State private var groupSelection = Set<AttributionResult.Group.ID>()

    /// The sector table as text, for ⌘C and Copy Row (Shared/Copy/TableCopy.swift).
    private static let groupsText = TableText<AttributionResult.Group>(
        titles: ["Sector", "Account", "Benchmark", "Active", "Allocation", "Selection", "Interaction", "Total"]) { g in
        [g.group, pct(g.portfolioWeight), pct(g.benchmarkWeight), signedPct(g.activeWeight, 1), signedPct(g.allocation),
         signedPct(g.selection), signedPct(g.interaction), signedPct(g.total)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                MetricTile(title: "Account", value: signedPct(result.portfolioReturn), help: "The account's compounded return over the period.")
                MetricTile(title: "Benchmark", value: signedPct(result.benchmarkReturn), help: "The benchmark's compounded return.")
                MetricTile(title: "Active return", value: signedPct(result.activeReturn), tint: Color.signed(result.activeReturn), help: "Account minus benchmark.")
                MetricTile(title: "Allocation", value: signedPct(result.allocation), tint: Color.signed(result.allocation), help: PortHelp.terms["Allocation effect"]!)
                MetricTile(title: "Selection", value: signedPct(result.selection), tint: Color.signed(result.selection), help: PortHelp.terms["Selection effect"]!)
                MetricTile(title: "Interaction", value: signedPct(result.interaction), tint: Color.signed(result.interaction), help: PortHelp.terms["Interaction effect"]!)
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: result.recommendation == "publish" ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(result.recommendation == "publish" ? .green : .orange).font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.highlight).heading(.name)
                    Text((result.recommendation == "publish" ? "Complete: " : "Review: ") + result.reasons.joined(separator: "; ") + ".")
                    Text(interpretation).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("\(result.engine) · \(result.method), monthly, Carino-linked").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            .quickHelpArea(QuickHelpItem(title: "Reading the result", detail: interpretation, symbol: "text.magnifyingglass"))
            HStack(alignment: .top, spacing: 14) {
                Box(title: "Effects by sector", symbol: "chart.bar.xaxis", help: "Allocation, selection and interaction in each sector, linked over the period. They add up to the active return.") {
                    HBars(series: [.init(name: "Allocation", color: .blue), .init(name: "Selection", color: .orange), .init(name: "Interaction", color: .purple)],
                          rows: result.groups.map { .init(label: $0.group, values: [$0.allocation * 100, $0.selection * 100, $0.interaction * 100]) }, unit: "pp")
                }
                Box(title: "Month by month", symbol: "calendar", help: "Each month's active return (bars), with its allocation (blue) and selection (orange) effects.") {
                    Chart {
                        ForEach(Array(result.periods.enumerated()), id: \.offset) { i, p in
                            BarMark(x: .value("Month", i + 1), y: .value("Active", p.activeReturn * 100), width: .fixed(14)).foregroundStyle(Color.signed(p.activeReturn).opacity(0.7))
                            LineMark(x: .value("Month", i + 1), y: .value("pp", p.allocation * 100), series: .value("Effect", "Allocation")).foregroundStyle(.blue)
                            LineMark(x: .value("Month", i + 1), y: .value("pp", p.selection * 100), series: .value("Effect", "Selection")).foregroundStyle(.orange)
                        }
                    }
                    .chartXScale(domain: 0.5...Double(result.periods.count) + 0.5)
                    .chartXAxis {
                        AxisMarks(values: Array(1...max(result.periods.count, 1))) { v in
                            AxisValueLabel { if let i = v.as(Int.self), i >= 1, i <= result.periods.count { Text(result.periods[i - 1].month.suffix(5)) } }
                        }
                    }
                    .chartYAxisLabel("percentage points")
                    .frame(height: 320)
                }
            }
            Box(title: "By sector", symbol: "tablecells", help: "Average weights over the period and each effect, largest total first.") {
                Table(result.groups, selection: $groupSelection) {
                    TableColumn("Sector", value: \.group)
                    TableColumn("Account") { g in Text(pct(g.portfolioWeight)).monospacedDigit() }.width(70)
                    TableColumn("Benchmark") { g in Text(pct(g.benchmarkWeight)).monospacedDigit() }.width(80)
                    TableColumn("Active") { g in Text(signedPct(g.activeWeight, 1)).monospacedDigit() }.width(70)
                    TableColumn("Allocation") { g in Text(signedPct(g.allocation)).monospacedDigit().foregroundStyle(Color.signed(g.allocation)) }.width(80)
                    TableColumn("Selection") { g in Text(signedPct(g.selection)).monospacedDigit().foregroundStyle(Color.signed(g.selection)) }.width(80)
                    TableColumn("Interaction") { g in Text(signedPct(g.interaction)).monospacedDigit().foregroundStyle(Color.signed(g.interaction)) }.width(80)
                    TableColumn("Total") { g in Text(signedPct(g.total)).monospacedDigit().bold() }.width(70)
                }
                .tableText()
                .copyRowsMenu(result.groups, as: Self.groupsText)
                .copiesSelectedRows(result.groups, selected: groupSelection, as: Self.groupsText)
                .frame(minHeight: CGFloat(result.groups.count) * 26 + 34)
            }
            HStack(alignment: .top, spacing: 14) {
                contributors("Helped most", result.top)
                contributors("Hurt most", result.bottom)
            }
            Box(title: "Assumptions", symbol: "info.circle", help: "How the numbers were computed; read them before trusting the result.") {
                SelectableText(text: { var l = RichLines(); l.bullets(result.assumptions, font: RichLines.calloutFont); return l.result }())
            }
        }
    }

    private var interpretation: String {
        let biggest = abs(result.allocation) > abs(result.selection) ? "allocation (sector weights)" : "selection (companies within sectors)"
        if passive {
            return abs(result.activeReturn) < 0.005
                ? "Within half a point of the index: the account did what a passive portfolio should."
                : "\(signedPct(result.activeReturn)) from the index is large for a passive account; most came from \(biggest). Look for drift, idle cash or missing names."
        }
        return "Most of the active return came from \(biggest). Ask whether that was the bet you meant to make."
    }

    private func contributors(_ title: String, _ rows: [AttributionResult.Contributor]) -> some View {
        Box(title: title, symbol: title == "Helped most" ? "arrow.up.circle" : "arrow.down.circle", help: "Securities with the largest contribution to active return: active weight times return, summed over the months.") {
            ForEach(rows) { c in
                HStack {
                    Text(c.ticker).textKind(.ids).frame(width: 60, alignment: .leading)
                    Text(c.sector).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(pct(c.portfolioWeight)) vs \(pct(c.benchmarkWeight))").font(.caption).foregroundStyle(.secondary)
                    Text(signedPct(c.contribution)).monospacedDigit().foregroundStyle(Color.signed(c.contribution)).frame(width: 70, alignment: .trailing)
                }
            }
        }
    }
}


/// Shown while a security-master account's risk inputs come from the analytics service.
struct SRMInputsPending: View {
    @Bindable var store: PortStore

    var body: some View {
        StepPage(store: store, subtitle: "Risk inputs for your account come from the analytics service: a covariance estimated from the security master's prices.", lesson: []) {
            VStack(spacing: 10) {
                if store.srmBusy || store.busy { ProgressView("Saving the account and estimating its covariance…") }
                Text(store.srmInputsNote ?? "The account is saved to the security master, then the analytics service (port 8772) estimates a Ledoit-Wolf covariance from two years of prices for its holdings and its benchmark.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 640)
                Button("Load Risk Inputs") { Task { await store.loadSRMInputs() } }
            }
            .frame(maxWidth: .infinity, minHeight: 260)
        }
        .task { if store.srmInputs == nil { await store.loadSRMInputs() } }
    }
}
