//
//  PassiveViews.swift
//  MxPortMGR
//
//  The passive path's own screens: tracking error and how it drifts, building a tracker with fewer names (or one
//  fund), and rebalance bands for the stock / bond / cash mix.
//

import Charts
import SwiftUI

// MARK: - Tracking error & drift

struct DriftView: View {
    @Bindable var store: PortStore
    @State private var trackerDrift: [Double] = []

    var body: some View {
        let p = store.portfolio
        let drift = AttributionEngine.drift(p)
        let te = zip(drift.account, drift.benchmark).map { AttributionEngine.trackingError($0, $1) }
        let months = ["Today"] + MarketHistory.months.map { "+" + String(MarketHistory.months.firstIndex(of: $0)! + 1) + "m" }
        let base = Universe.base
        let endActive = base.indices.map { drift.account.last![$0] - drift.benchmark.last![$0] }
        let movers = base.indices.sorted { abs(endActive[$0]) > abs(endActive[$1]) }.prefix(6)
        StepPage(store: store, subtitle: "How far the account is from its index today — and how far it drifts if left alone.", lesson: [
            "Tracking error measures how differently the account can behave from its index in a year. A broad index fund is around 0.05–0.2%; a sampled portfolio of a few dozen names 0.5–2%.",
            "Even a perfect copy drifts: prices move, dividends arrive as cash, companies join and leave the index, and you add or withdraw money. A cap-weighted index rebalances itself as prices move; a fixed list of names does not keep up with changes in the index.",
            "So passive is not 'do nothing': it is 'do little, by rule'. The next two steps set the rule — how many names, and when to trade back.",
        ]) {
            HStack(spacing: 10) {
                MetricTile(title: "Tracking error today", value: pct(te.first!, 2), help: PortHelp.terms["Tracking error"]!)
                MetricTile(title: "After a year untouched", value: pct(te.last!, 2), caption: "through the illustrative year", tint: te.last! > te.first! ? .orange : .green, help: "The account's tracking error after holding today's positions through the year without trading.")
                MetricTile(title: "Active share today", value: pct(drift.account[0].indices.reduce(0) { $0 + abs(drift.account[0][$1] - drift.benchmark[0][$1]) / 2 }), help: PortHelp.terms["Active share"]!)
                MetricTile(title: "Benchmark", value: p.benchmark, caption: p.benchmarkInfo.name, help: p.benchmarkInfo.summary)
            }
            HStack(alignment: .top, spacing: 14) {
                Box(title: "Tracking error, month by month", symbol: "chart.line.uptrend.xyaxis", help: "Ex-ante tracking error of the account as its holdings drift, and of a 20-name tracker set up today and left alone; the dashed line is a 2% budget.") {
                    Chart {
                        ForEach(Array(te.enumerated()), id: \.offset) { i, v in
                            LineMark(x: .value("Month", months[i]), y: .value("TE %", v * 100), series: .value("Who", "This account"))
                                .foregroundStyle(by: .value("Who", "This account"))
                        }
                        ForEach(Array(trackerDrift.enumerated()), id: \.offset) { i, v in
                            LineMark(x: .value("Month", months[i]), y: .value("TE %", v * 100), series: .value("Who", "20-name tracker from today"))
                                .foregroundStyle(by: .value("Who", "20-name tracker from today"))
                        }
                        RuleMark(y: .value("Budget", 2)).lineStyle(StrokeStyle(dash: [4, 3])).foregroundStyle(.secondary)
                    }
                    .chartYAxisLabel("tracking error %")
                    .frame(height: 280)
                }
                Box(title: "Where the drift goes", symbol: "arrow.up.and.down", help: "Active weight (account minus index) of the six names that drift most over the year.") {
                    Chart {
                        ForEach(Array(movers), id: \.self) { i in
                            ForEach(Array(drift.account.indices), id: \.self) { t in
                                LineMark(x: .value("Month", months[t]), y: .value("Active %", (drift.account[t][i] - drift.benchmark[t][i]) * 100), series: .value("Name", base[i].ticker))
                                    .foregroundStyle(by: .value("Name", base[i].ticker))
                            }
                        }
                    }
                    .chartYAxisLabel("active weight %")
                    .frame(height: 280)
                }
            }
            Box(title: "Why it drifts", symbol: "wind", help: "The usual sources of tracking error in an index portfolio.") {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow { Text("Missing names").bold(); Text("Holding fewer names than the index: their returns are missing. The biggest source for a direct-index portfolio.") }
                    GridRow { Text("Price drift").bold(); Text("Fixed weights fall out of line as prices move unless the portfolio holds every name in proportion.") }
                    GridRow { Text("Cash").bold(); Text("Dividends and deposits sitting uninvested.") }
                    GridRow { Text("Index changes").bold(); Text("Companies join and leave; the index trades, you don't.") }
                    GridRow { Text("Costs").bold(); Text("Fees and trading costs: a steady small shortfall every year.") }
                }
                .font(.callout)
            }
        }
        .task(id: store.selectedID) {
            let inputs = store.inputs
            let tracker = await Task.detached { Engine.track(inputs, TrackingSettings()) }.value
            var q = p
            q.holdings = tracker.weights.map { Holding(ticker: $0.key, value: $0.value * 100_000) }
            q.trading = "buyAndHold"
            let d = AttributionEngine.drift(q)
            trackerDrift = zip(d.account, d.benchmark).map { AttributionEngine.trackingError($0, $1) }
        }
    }
}

// MARK: - Build the tracker

struct TrackView: View {
    @Bindable var store: PortStore

    var body: some View {
        StepPage(store: store, subtitle: "The fewest names that follow the index closely enough — or one fund that does it for you.", lesson: [
            "Full replication holds every name at index weight: no tracking error from missing names, but many small positions.",
            "Sampling holds fewer names, chosen and weighted to keep tracking error small. Stratified sampling spreads them across sectors so no sector is missing; largest-weight sampling holds the biggest names.",
            "The curve shows diminishing returns: the first names cut tracking error fast, the last ones barely. For most personal accounts one low-cost index fund does all of this — the comparison below shows what each choice costs, including taxes on switching.",
        ]) {
            settings
            if let r = store.trackResult {
                ResultSummary(result: r, active: false)
                HStack(alignment: .top, spacing: 14) {
                    Box(title: "Tracking error vs names held", symbol: "chart.line.downtrend.xyaxis", help: "Tracking error of the best tracker with each number of names (the selected method); the dashed line is your budget.") {
                        Chart {
                            ForEach(store.trackCurve, id: \.names) { c in
                                LineMark(x: .value("Names", c.names), y: .value("TE %", c.te * 100))
                                PointMark(x: .value("Names", c.names), y: .value("TE %", c.te * 100)).symbolSize(c.names == store.trackingSettings.maxNames ? 90 : 20)
                            }
                            RuleMark(y: .value("Budget", store.trackingSettings.trackingErrorBudget * 100)).lineStyle(StrokeStyle(dash: [4, 3])).foregroundStyle(.orange)
                        }
                        .chartXAxisLabel("names held")
                        .chartYAxisLabel("tracking error %")
                        .frame(height: 280)
                    }
                    Box(title: "Sector gaps", symbol: "chart.bar", help: "Tracker weight minus index weight by sector. Stratified selection keeps every sector represented.") {
                        HBars(series: [.init(name: "Active", color: .accentColor)],
                              rows: r.sectorActive.filter { abs($0.value) > 1e-6 }.sorted { $0.value > $1.value }.map { .init(label: $0.key, values: [$0.value * 100], colors: [Color.signed($0.value)]) })
                    }
                    .frame(width: 360)
                }
                options(r)
                Box(title: "Trades to the tracker", symbol: "list.bullet.rectangle", help: "From today's look-through weights to the tracker's, largest first.") {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 3) {
                        GridRow { Text("Side").bold(); Text("Security").bold(); Text("Today").bold(); Text("Tracker").bold(); Text("Amount").bold() }
                        ForEach(r.trades.prefix(14)) { t in
                            GridRow {
                                Text(t.side).foregroundStyle(t.change > 0 ? .green : .red)
                                Text("\(t.asset) — \(Universe.security(t.asset)?.name ?? "")")
                                Text(pct(t.from, 2)).monospacedDigit()
                                Text(pct(t.to, 2)).monospacedDigit()
                                Text(money(t.change * store.portfolio.total)).monospacedDigit()
                            }
                        }
                    }
                    .font(.callout)
                }
            } else {
                ContentUnavailableView {
                    Label("No Tracker Yet", systemImage: "scope")
                } description: { Text("Build the tracker (⇧⌘R).") }
                .frame(height: 200)
            }
        }
        .task(id: store.selectedID) {
            if store.trackResult == nil, store.engine == .builtIn { await store.buildTracker() }
        }
    }

    private var settings: some View {
        let members = store.inputs.benchmark.filter { $0 > 0 }.count
        return Box(title: "Tracker", symbol: "slider.horizontal.3", help: "How many names, chosen how, and the tracking-error budget.") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Text("Names to hold")
                    Slider(value: Binding(get: { Double(store.trackingSettings.maxNames) }, set: { store.trackingSettings.maxNames = Int($0) }), in: 3...Double(members), step: 1).frame(width: 260)
                    Text(store.trackingSettings.maxNames >= members ? "all \(members) (full replication)" : "\(store.trackingSettings.maxNames) of \(members)").monospacedDigit()
                }
                .help("At most this many names; \(members) is every name in the index")
                GridRow {
                    Text("Choose names")
                    Picker("", selection: $store.trackingSettings.selection) {
                        Text("Stratified by sector").tag(TrackingSettings.Selection.stratified)
                        Text("Largest weights").tag(TrackingSettings.Selection.largest)
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 260)
                    Text("")
                }
                .quickHelpArea("Choose Names", "Stratified: names in every sector in proportion to its weight, largest first in each. Largest: the biggest names in the index, whatever their sector.", symbol: "list.number")
                GridRow {
                    Text("Tracking-error budget")
                    Slider(value: $store.trackingSettings.trackingErrorBudget, in: 0.0025...0.03, step: 0.0025).frame(width: 260)
                    Text(pct(store.trackingSettings.trackingErrorBudget, 2)).monospacedDigit()
                }
                .term("Tracking error")
            }
            HStack {
                Button { Task { await store.buildTracker() } } label: { Label("Build Tracker", systemImage: "scope") }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.busy)
                    .quickHelp("Build Tracker", "Finds the weights with the smallest tracking error using at most this many names — built-in, or portfolio-cpp when Engine is Layer 3 services.", shortcut: "⇧⌘R")
                Text("Engine: \(store.engine.rawValue)").font(.caption).foregroundStyle(.secondary)
                if store.busy { ProgressView().controlSize(.small) }
            }
        }
    }

    private func options(_ r: OptimizationResult) -> some View {
        let p = store.portfolio
        let trackerTax = store.taxEstimate(r.trades)
        let fundTax = store.sellAllTaxEstimate()
        let fund = p.benchmark == "MXEQ" ? "MXTM" : "MXTM + MXBD at \(p.benchmark)'s mix"
        let fundFee = p.benchmark == "MXEQ" ? 0.0003 : 0.00034
        return Box(title: "Three ways to be passive", symbol: "scalemass", help: "Today's account, the tracker, and one index fund side by side: tracking error, cost and the tax of switching (illustrative).") {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow { Text("").bold(); Text("Tracking error").bold(); Text("Yearly fee").bold(); Text("Trades").bold(); Text("Tax to switch").bold(); Text("Notes").bold() }
                Divider().gridCellColumns(6)
                GridRow {
                    Text("Today's account")
                    Text(pct(r.currentTrackingError ?? 0, 2)).monospacedDigit()
                    Text(pct(p.weightedFee, 2)).monospacedDigit()
                    Text("0")
                    Text("—")
                    Text("Keeps drifting unless rebalanced.").foregroundStyle(.secondary)
                }
                GridRow {
                    Text("\(r.names)-name tracker")
                    Text(pct(r.trackingError, 2)).monospacedDigit()
                    Text("0.00%").monospacedDigit()
                    Text("\(r.trades.count)")
                    Text(p.account.isTaxable ? money(trackerTax.tax) : "none").monospacedDigit()
                    Text("Direct indexing: own the names, harvest losses name by name; needs upkeep.").foregroundStyle(.secondary)
                }
                GridRow {
                    Text("One index fund (\(fund))")
                    Text("≈ 0.05%").monospacedDigit()
                    Text(pct(fundFee, 2)).monospacedDigit()
                    Text("\(p.holdings.count + 1)")
                    Text(p.account.isTaxable ? money(fundTax.tax) : "none").monospacedDigit()
                    Text("Simplest; the fund rebalances itself. Switching in a taxable account can be done gradually.").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }
    }
}

// MARK: - Rebalance bands

struct BandsView: View {
    @Bindable var store: PortStore
    @State private var relative = false
    @State private var toEdge = false

    var body: some View {
        let p = store.portfolio
        let targets = Portfolio.classes(of: p.benchmarkInfo.weights)
        let now = p.classWeights()
        let band: (AssetClass) -> Double = { c in relative ? (targets[c] ?? 0) * 0.25 : store.bandWidth }
        let outside = AssetClass.allCases.filter { abs((now[$0] ?? 0) - (targets[$0] ?? 0)) > band($0) + 1e-9 }
        let drift = AttributionEngine.drift(p).account.map { Portfolio.classes(of: Dictionary(uniqueKeysWithValues: zip(Universe.base.map(\.ticker), $0))) }
        let trades = rebalanceTrades(p, targets: targets, band: band, toEdge: toEdge)
        let estimate = store.taxEstimate(trades)
        StepPage(store: store, subtitle: "When to trade back to the plan's mix — by rule, not by mood.", lesson: [
            "The stock / bond / cash mix sets most of the account's risk. As prices move it drifts: after a rally stocks become a larger share, so the account takes more risk than planned.",
            "A rebalance band is the rule: trade back only when a weight leaves target ± band. Calendar rebalancing (every year) is the other common rule; bands trade only when needed.",
            "Wider bands mean fewer trades, lower costs and taxes, but more drift. In a taxable account rebalance with new deposits and dividends first, and in tax-deferred accounts where possible.",
        ]) {
            Box(title: "Band", symbol: "rectangle.split.3x1", help: "The band around each target: a fixed number of points, or a quarter of the target (the '5/25' rule: 5 points or 25% of the target).") {
                HStack(spacing: 18) {
                    Picker("Band", selection: $relative) {
                        Text("± points").tag(false)
                        Text("± 25% of target").tag(true)
                    }
                    .pickerStyle(.segmented).frame(width: 260)
                    if !relative {
                        Slider(value: $store.bandWidth, in: 0.01...0.15, step: 0.01) { Text("± \(Int(store.bandWidth * 100)) points") }.frame(width: 320)
                    }
                    Picker("Trade back to", selection: $toEdge) {
                        Text("the target").tag(false)
                        Text("the band's edge").tag(true)
                    }
                    .pickerStyle(.segmented).frame(width: 300)
                    .help("All the way to the target, or only back inside the band (less trading)")
                }
                .term("Rebalance band")
            }
            HStack(alignment: .top, spacing: 14) {
                Box(title: outside.isEmpty ? "Inside every band" : "Outside the band: \(outside.map(\.rawValue).joined(separator: ", "))", symbol: outside.isEmpty ? "checkmark.circle" : "exclamationmark.triangle",
                    help: "Each class's target (line), band (shaded) and today's weight (dot).") {
                    ForEach(AssetClass.allCases, id: \.self) { c in
                        BandTrack(label: c.rawValue, target: targets[c] ?? 0, band: band(c), now: now[c] ?? 0)
                    }
                }
                Box(title: "Stocks through the year, untouched", symbol: "chart.line.uptrend.xyaxis", help: "The stock share month by month if the account is left alone through the illustrative year, with the band shaded.") {
                    let t = (targets[.equity] ?? 0) * 100, b = band(.equity) * 100
                    Chart {
                        RectangleMark(xStart: .value("m", 0), xEnd: .value("m", 12), yStart: .value("lo", t - b), yEnd: .value("hi", t + b)).foregroundStyle(.green.opacity(0.15))
                        ForEach(Array(drift.enumerated()), id: \.offset) { i, w in
                            LineMark(x: .value("Month", i), y: .value("Stocks %", (w[.equity] ?? 0) * 100))
                            PointMark(x: .value("Month", i), y: .value("Stocks %", (w[.equity] ?? 0) * 100))
                                .foregroundStyle(abs((w[.equity] ?? 0) * 100 - t) > b ? .red : .accentColor)
                        }
                    }
                    .chartXAxisLabel("months from today")
                    .chartYAxisLabel("stocks %")
                    .frame(height: 220)
                }
            }
            Box(title: trades.isEmpty ? "No trades needed" : "Trades to rebalance", symbol: "list.bullet.rectangle", help: "Sells of the overweight class (in proportion to its holdings) and buys of the underweight class (its holdings, or an index fund).") {
                if trades.isEmpty {
                    Text("Every class is inside its band: the rule says leave it alone — no cost, no tax.").font(.callout)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 3) {
                        GridRow { Text("Side").bold(); Text("Holding").bold(); Text("Today").bold(); Text("After").bold(); Text("Amount").bold() }
                        ForEach(trades) { t in
                            GridRow {
                                Text(t.side).foregroundStyle(t.change > 0 ? .green : .red)
                                Text("\(t.asset) — \(Universe.security(t.asset)?.name ?? "")")
                                Text(pct(t.from)).monospacedDigit()
                                Text(pct(t.to)).monospacedDigit()
                                Text(money(t.change * p.total)).monospacedDigit()
                            }
                        }
                    }
                    .font(.callout)
                }
            }
            if !trades.isEmpty { TaxBox(store: store, estimate: estimate) }
        }
    }

    /// Holding-level trades back to the target mix (or the band's edge) for every class outside its band.
    private func rebalanceTrades(_ p: Portfolio, targets: [AssetClass: Double], band: (AssetClass) -> Double, toEdge: Bool) -> [Trade] {
        let now = p.classWeights()
        var goal: [AssetClass: Double] = [:]
        for c in AssetClass.allCases {
            let w = now[c] ?? 0, t = targets[c] ?? 0, b = band(c)
            goal[c] = abs(w - t) > b + 1e-9 ? (toEdge ? (w > t ? t + b : t - b) : t) : w
        }
        guard goal.contains(where: { abs($0.value - (now[$0.key] ?? 0)) > 1e-9 }) else { return [] }
        // Classes inside their band absorb the difference in proportion to their size.
        let moved = AssetClass.allCases.reduce(0) { $0 + (goal[$1]! - (now[$1] ?? 0)) }
        let inside = AssetClass.allCases.filter { abs(goal[$0]! - (now[$0] ?? 0)) < 1e-9 }
        let insideTotal = inside.reduce(0) { $0 + (now[$1] ?? 0) }
        if abs(moved) > 1e-9 {
            if insideTotal > 0 { for c in inside { goal[c]! -= moved * (now[c] ?? 0) / insideTotal } } else {
                let changed = AssetClass.allCases.filter { !inside.contains($0) }
                for c in changed { goal[c]! -= moved / Double(changed.count) }
            }
        }
        func classOf(_ h: Holding) -> AssetClass? {
            guard let s = h.security else { return nil }
            return s.lookThrough.map { Portfolio.classes(of: $0).max { $0.value < $1.value }!.key } ?? s.assetClass
        }
        var trades: [Trade] = []
        for c in AssetClass.allCases {
            let have = now[c] ?? 0, want = goal[c]!
            guard abs(want - have) > 1e-6 else { continue }
            let members = p.holdings.filter { classOf($0) == c }
            if members.isEmpty {
                let fund = c == .equity ? "MXTM" : c == .bond ? "MXBD" : "CASH"
                trades.append(Trade(asset: fund, from: 0, to: want))
            } else {
                let total = members.reduce(0) { $0 + p.weight($1) }
                for h in members {
                    let w = p.weight(h)
                    trades.append(Trade(asset: h.ticker, from: w, to: w * want / max(total, 1e-9)))
                }
            }
        }
        return trades.filter { abs($0.change) > 1e-5 }.sorted { $0.change < $1.change }
    }
}

/// One class on a 0–100% track: its band (shaded), target (tick) and today's weight (dot, red outside the band).
struct BandTrack: View {
    var label: String
    var target: Double
    var band: Double
    var now: Double

    var body: some View {
        let outside = abs(now - target) > band + 1e-9
        HStack(spacing: 8) {
            Text(label).font(.callout).frame(width: 50, alignment: .trailing)
            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary).frame(height: 6)
                    Rectangle().fill(.green.opacity(0.25))
                        .frame(width: w * CGFloat(min(1, target + band) - max(0, target - band)), height: 18)
                        .offset(x: w * CGFloat(max(0, target - band)))
                    Rectangle().fill(.secondary).frame(width: 2, height: 22).offset(x: w * CGFloat(target) - 1)
                    Circle().fill(outside ? Color.red : Color.green).frame(width: 14, height: 14).offset(x: w * CGFloat(now) - 7)
                }
                .frame(height: g.size.height)
            }
            .frame(height: 24)
            Text("\(pct(now)) vs \(pct(target)) ± \(pct(band))").font(.caption.monospacedDigit()).foregroundStyle(outside ? .red : .secondary).frame(width: 150, alignment: .leading)
        }
        .help("\(label): \(pct(now)) now, target \(pct(target)), band \(pct(max(0, target - band))) to \(pct(target + band))")
    }
}
