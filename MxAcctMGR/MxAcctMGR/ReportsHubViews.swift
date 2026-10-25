//
//  ReportsHubViews.swift
//  MxAcctMGR
//
//  Knowledge Library ▸ Report Library — the hierarchy of reports portfolio managers watch, by tier, with what each
//  measures, why PMs care, which price drivers it moves, and the five with the greatest impact — and Knowledge Library ▸
//  Morning Briefing, the ten things many institutional PMs review before the open, on an illustrative morning.
//

import Charts
import SwiftUI

// MARK: - Report Library

struct ReportLibraryView: View {
    @Bindable var store: PortStore

    var body: some View {
        StepPage(store: store, subtitle: "The reports portfolio managers watch — some move markets in seconds, others shape positioning over weeks or months.", lesson: [
            "Asset prices rest on four things: economic growth, inflation, interest rates and corporate profits. Every report here is news about one or more of them; positioning reports add how investors are already placed.",
            "Professionals watch them because their mandates and horizons are short. For a long-term personal plan they explain why prices moved — they are rarely a reason to change the plan.",
            "Each report has a seven-step walkthrough: read it, see the market's move on your account, choose a reaction, and simulate the long run against staying with the plan.",
        ]) {
            topFive
            driverMatrix
            ForEach(ReportTier.all) { tier in
                VStack(alignment: .leading, spacing: 8) {
                    Text(tier.title).heading(.heading)
                    Text(tier.summary).foregroundStyle(.secondary)
                    AdaptiveColumns(minimum: 340, spacing: 12, rowSpacing: 12) {
                        ForEach(MarketReport.all.filter { $0.tier == tier.id }) { reportCard($0).copyBlock() }
                    }
                }
                .padding(.top, 6)
            }
            Box(title: "Daily morning reading", symbol: "sunrise", help: "The ten things many institutional PMs review before the open.") {
                Text("Many institutional PMs start the day with overnight markets, Treasury yields, the economic calendar, economic surprise indexes, Fed funds futures, analyst upgrades and downgrades, earnings releases, fund flows, credit spreads and the VIX.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open the Morning Briefing") { store.go(.morningBriefing) }.buttonStyle(.borderedProminent)
                    Button("The VIX, real data") { store.go(.vix) }
                        .help("The Cboe Volatility Index from Cboe: today, its history, term structure and past spikes")
                    Button("Compute Hyperscalers Tracking: capex") { store.go(.compute) }
                        .help("What Microsoft, Alphabet, Amazon, Meta and Oracle spend on AI compute, and their suppliers' revenue — reported figures")
                }
            }
        }
    }

    private var topFive: some View {
        Box(title: "If you had to pick five", symbol: "5.circle", help: "For a diversified U.S. equity portfolio, the reports with the greatest impact are usually these five. Together they drive expectations for growth, inflation, interest rates and profits.") {
            HStack(alignment: .top, spacing: 10) {
                ForEach(MarketReport.topFive) { r in
                    Button { store.openReport(r.id) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("\(r.topFive!)").font(.title.weight(.bold)).foregroundStyle(Color.accentColor)
                                Image(systemName: r.symbol)
                            }
                            Text(r.title).font(.callout.weight(.semibold))
                            Text(r.drivers.map(\.rawValue).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                    }
                    .plainButton()
                    .help("Open the \(r.title) walkthrough")
                    .quickHelp(r.title, (r.whyCare + ["Open its walkthrough."]).joined(separator: " "))
                }
            }
            Text("These five collectively drive expectations for economic growth, inflation, interest rates and corporate profits — the four primary determinants of asset prices.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var driverMatrix: some View {
        Box(title: "Which drivers each report moves", symbol: "square.grid.3x3", help: "A dot where a report is news about that driver of asset prices. Right-click a report for your own notes on it; rest the pointer on its name to read them.") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                GridRow {
                    Text("Report").bold()
                    ForEach(Driver.allCases, id: \.self) { d in Label(d.rawValue, systemImage: d.symbol).font(.caption.weight(.semibold)).gridColumnAlignment(.center) }
                    Text("Impact").bold()
                }
                Divider().gridCellColumns(Driver.allCases.count + 2)
                ForEach(Array(MarketReport.all.enumerated()), id: \.element.id) { i, r in
                    GridRow {
                        // Right-click: your notes on it, shown on its hover card (ReportNotes.swift).
                        ReportLink(report: r) { store.openReport(r.id) }
                            .anchorPreference(key: ReportRowBounds.self, value: .bounds) { [i: $0] }
                        ForEach(Driver.allCases, id: \.self) { d in
                            Image(systemName: r.drivers.contains(d) ? "circle.fill" : "circle").font(.caption2)
                                .foregroundStyle(r.drivers.contains(d) ? Color.accentColor : Color.secondary.opacity(0.3))
                                .copyText(r.drivers.contains(d) ? "✓" : "")
                        }
                        ImpactDots(level: r.impact)
                    }
                }
            }
            // Banded rows, so the eye can follow a report across to its impact: every other row gets a band the
            // width of the table, placed from the row's bounds (a cell's own background leaves gaps between columns).
            .backgroundPreferenceValue(ReportRowBounds.self) { rows in
                GeometryReader { g in
                    ZStack(alignment: .topLeading) {
                        ForEach(rows.keys.sorted().filter { $0 % 2 == 1 }, id: \.self) { i in
                            if let anchor = rows[i] {
                                let row = g[anchor]
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.primary.opacity(0.06))
                                    .frame(width: g.size.width + 12, height: row.height + 3)
                                    .offset(x: -6, y: row.minY - 1.5)
                            }
                        }
                    }
                    .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
                }
            }
        }
    }

    private func reportCard(_ r: MarketReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Image(systemName: r.symbol).font(.title2).foregroundStyle(Color.accentColor).frame(width: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.title).heading(.name)
                    Text(r.publisher).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Text(r.frequency).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    if let n = r.topFive {
                        Text("Top five · #\(n)").font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2), in: Capsule())
                    }
                    ImpactDots(level: r.impact)
                }
            }
            Text("Key metrics: " + r.keyMetrics.joined(separator: " · ")).font(.caption).fixedSize(horizontal: false, vertical: true)
            ForEach(r.whyCare, id: \.self) { Label($0, systemImage: "eye").font(.caption).foregroundStyle(.secondary) }
            HStack(spacing: 4) {
                ForEach(r.drivers, id: \.self) { d in
                    Text(d.rawValue).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary.opacity(0.6), in: Capsule())
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Button("Open Walkthrough") { store.openReport(r.id) }
                    .help("Read this report and simulate your reaction")
                if let source = r.sources.first {
                    Link(destination: source.url) {
                        Label("\(source.publisher): \(source.title)", systemImage: "arrow.up.right.square").lineLimit(1)
                    }
                    .font(.callout)
                    .help("The real report, from \(source.publisher): \(source.address)")
                    .quickHelp("Official Source", "Opens the real \(r.title) — \(source.title), from \(source.publisher) — in your browser. The walkthrough's numbers are illustrative; its first step lists every official page (release, schedule, history).", symbol: "arrow.up.right.square")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 210, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .quickHelpArea(QuickHelpItem(title: r.title, detail: "\(r.publisher). \(r.frequency). Key metrics: \(r.keyMetrics.joined(separator: ", ")). Why PMs care: \(r.whyCare.joined(separator: " "))", symbol: r.symbol))
    }
}

struct ImpactDots: View {
    var level: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...3, id: \.self) { i in
                Circle().fill(i <= level ? Color.orange : Color.secondary.opacity(0.25)).frame(width: 7, height: 7)
            }
        }
        .help(["", "Usually a small market reaction on the day", "Can move markets on a surprise", "Moves markets within seconds of release"][level])
        .copyText(["", "low", "medium", "high"][level])
    }
}

// MARK: - Morning Briefing

/// An illustrative morning's data for the ten items.
nonisolated enum Briefing {
    static let date = "Wednesday 2026-10-21 (illustrative)"

    static let overnight: [(String, Double)] = [
        ("Nikkei 225 (Tokyo)", -0.8), ("Hang Seng (Hong Kong)", -1.2), ("Euro Stoxx 50", -0.4), ("FTSE 100 (London)", -0.2),
        ("S&P 500 futures", -0.5), ("Nasdaq-100 futures", -0.7), ("Crude oil (WTI)", -1.1), ("Gold", 0.4), ("U.S. dollar index", 0.2),
    ]
    static let futuresMove = -0.005, futuresRate = 0.0001

    static let yields: [(String, Double, Double)] = [("3-month", 4.20, 0.00), ("2-year", 4.08, -0.02), ("5-year", 4.18, 0.00), ("10-year", 4.51, 0.01), ("30-year", 4.92, 0.02)]

    struct Event: Identifiable {
        var id: String { day + time + name }
        var day: String
        var time: String
        var name: String
        var consensus: String
        var prior: String
        var report: String?
        var impact: Int
    }
    static let calendar: [Event] = [
        Event(day: "Today", time: "8:30", name: "CPI (core, m/m)", consensus: "+0.3%", prior: "+0.3%", report: "cpi", impact: 3),
        Event(day: "Today", time: "10:30", name: "EIA crude inventories", consensus: "−1.2m bbl", prior: "+0.4m", report: "energy", impact: 1),
        Event(day: "Today", time: "1:00", name: "10-year note auction ($42bn)", consensus: "4.58% WI", prior: "0.6bp tail", report: "auctions", impact: 2),
        Event(day: "Thu", time: "8:30", name: "PPI final demand (m/m)", consensus: "+0.2%", prior: "+0.3%", report: "ppi", impact: 2),
        Event(day: "Thu", time: "8:30", name: "Retail sales (m/m)", consensus: "+0.3%", prior: "+0.5%", report: "retail-sales", impact: 2),
        Event(day: "Fri", time: "8:30", name: "Housing starts", consensus: "1.34m", prior: "1.36m", report: "housing", impact: 1),
        Event(day: "Fri", time: "3:30", name: "CFTC Commitments of Traders", consensus: "—", prior: "—", report: "cot", impact: 1),
        Event(day: "Next Wed", time: "2:00", name: "FOMC decision and projections", consensus: "Hold", prior: "Hold", report: "fomc", impact: 3),
    ]

    static let surprise: [Double] = [8, 6, 9, 4, 2, 3, -1, -4, -3, -6, -8, -7, -10, -9, -12, -11, -14, -13, -12, -15]
    static let vix: [Double] = [15.2, 14.8, 15.5, 16.1, 15.9, 16.8, 17.4, 16.9, 18.2, 19.5, 18.8, 17.6, 18.4, 19.9, 21.0, 20.2, 19.4, 18.6, 18.6, 21.4]

    static let fedOdds: [(String, Double)] = [("Cut 0.50", 4), ("Cut 0.25", 58), ("Hold", 36), ("Hike 0.25", 2)]

    static let flows: [(String, Double)] = [("U.S. equity", -8.2), ("International equity", 1.0), ("Emerging markets", -0.6), ("Bonds", 3.1), ("Money market", 21.4)]

    static let credit: [(String, Double, Double)] = [("Investment-grade spread", 0.92, 0.03), ("High-yield spread", 3.18, 0.12)]
}

struct MorningBriefingView: View {
    @Bindable var store: PortStore

    var body: some View {
        let _ = store.riskStamp
        let p = store.portfolio
        let preMarket = MarketReport.accountMove(p, market: Briefing.futuresMove, rate: Briefing.futuresRate)
        StepPage(store: store, subtitle: "\(Briefing.date): the ten things many institutional PMs review before the open.", lessonTitle: "How to read a morning briefing", lesson: [
            "A briefing answers three questions: what happened overnight, what is scheduled today, and how investors are positioned and feeling.",
            "Professionals use it to manage risk around events in the next hours and days. For a long-term account, it is context — what you'll read about today — not a to-do list.",
            "The market panels are an illustrative morning in the shape of a real one; your account and today's earnings list are real (security master, Nasdaq.com and FMP). Point at a panel for what it measures and how a long-term investor might use it.",
        ]) {
            HStack(spacing: 10) {
                MetricTile(title: "Your account before the open", value: money(preMarket), caption: "if it moved with S&P futures (\(signedPct(Briefing.futuresMove, 1)))",
                           tint: Color.signed(preMarket), help: "An estimate from the futures move and each holding's market and rate betas (analytics service, from real prices): what \(p.name) would be worth at the open if prices followed the futures. It often changes by the close.")
                MetricTile(title: "Next big event", value: "CPI 8:30", caption: "consensus core +0.3% m/m", tint: .orange, help: "The highest-impact release on today's calendar.")
                MetricTile(title: "VIX", value: String(format: "%.1f", Briefing.vix.last!), caption: "+2.8 today, long-run average ≈ 19", tint: .orange, help: "The market's expected 30-day volatility of the S&P 500, from option prices; it rises when investors pay up for protection.")
                MetricTile(title: "Fed: odds of a cut next meeting", value: "62%", caption: "from fed funds futures", help: "Probabilities implied by fed funds futures prices.")
            }
            AdaptiveColumns(minimum: 420, spacing: 14, rowSpacing: 14) {
                panel(1, "Overnight markets", "globe", "Asia and Europe traded while the U.S. slept; U.S. futures show where stocks are likely to open.",
                      "Overnight moves often reverse during the U.S. day; they set the mood, not the result.") {
                    ForEach(Briefing.overnight, id: \.0) { row in
                        HStack { Text(row.0); Spacer(); Text(signedPct(row.1 / 100, 1)).monospacedDigit().foregroundStyle(Color.signed(row.1)) }.font(.callout)
                    }
                }
                panel(2, "Treasury yields", "percent", "Where interest rates stand across maturities and how they changed overnight, with the two most watched spreads.",
                      "Yields drive bond prices, mortgage rates and stock valuations. Watch the trend over months, not the day's basis points.") {
                    ForEach(Briefing.yields, id: \.0) { y in
                        HStack { Text(y.0); Spacer(); Text(String(format: "%.2f%%", y.1)).monospacedDigit(); Text(String(format: "%+.2f", y.2)).monospacedDigit().foregroundStyle(Color.signed(y.2)).frame(width: 50, alignment: .trailing) }.font(.callout)
                    }
                    Divider()
                    Text("2Y–10Y spread +0.43 · 3M–10Y spread +0.31 (positive: not inverted)").font(.caption).foregroundStyle(.secondary)
                }
                panel(3, "Economic calendar", "calendar", "Scheduled releases with the economists' consensus and the prior reading. The surprise versus consensus is what moves prices.",
                      "Knowing what's scheduled explains the day's moves before they happen. Open any report's walkthrough from here.") {
                    ForEach(Briefing.calendar) { e in
                        HStack(spacing: 8) {
                            Text(e.day).font(.caption).foregroundStyle(.secondary).frame(width: 58, alignment: .leading)
                            Text(e.time).font(.caption.monospacedDigit()).frame(width: 38, alignment: .leading)
                            if let id = e.report {
                                Button(e.name) { store.openReport(id) }.buttonStyle(.link).font(.callout).help("Open the walkthrough")
                            } else { Text(e.name).font(.callout) }
                            Spacer()
                            Text(e.consensus).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            ImpactDots(level: e.impact)
                        }
                    }
                }
                panel(4, "Economic surprise index", "chart.line.downtrend.xyaxis", "Whether recent data has come in above (positive) or below (negative) forecasts, like the Bloomberg and Citi surprise indexes.",
                      "A falling index means forecasters have been too optimistic. It tends to mean-revert as forecasts adjust.") {
                    Chart(Array(Briefing.surprise.enumerated()), id: \.offset) { i, v in
                        LineMark(x: .value("Day", i), y: .value("Index", v))
                        RuleMark(y: .value("Zero", 0)).foregroundStyle(.secondary.opacity(0.5))
                    }
                    .chartXAxis(.hidden)
                    .frame(height: 120)
                    Text("−15: data has disappointed for four weeks.").font(.caption).foregroundStyle(.secondary)
                }
                panel(5, "Fed funds futures", "building.columns", "The probabilities markets assign to each outcome at the next FOMC meeting, implied by futures prices.",
                      "They change with every data release — that's why CPI and jobs days move markets. They are odds, not promises.") {
                    Chart(Briefing.fedOdds, id: \.0) { o in
                        BarMark(x: .value("Outcome", o.0), y: .value("%", o.1), width: .fixed(40))
                            .annotation(position: .top) { Text("\(Int(o.1))%").font(.caption2) }
                    }
                    .frame(height: 130)
                }
                panel(6, "Analyst upgrades and downgrades", "arrow.up.arrow.down", "Changes in ratings and price targets from sell-side research, published before the open.",
                      "Single-stock moves on ratings are often short-lived; they matter more for concentrated accounts.") {
                    Text("No source of analyst ratings is loaded in the security master yet, so there is nothing real to show here.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                panel(7, "Earnings releases", "chart.bar.doc.horizontal", "Companies reporting today, before the open or after the close.",
                      "Check whether you hold them directly; through an index fund each is a small part of the account.") {
                    let today = (store.earnings.days[EarningsDates.today()]?.listed ?? []).sorted { $0.capKey > $1.capKey }.prefix(6)
                    if today.isEmpty {
                        Text(store.earnings.isLoading(EarningsDates.today()) ? "Reading today's earnings list…" : "No companies on today's list.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(Array(today)) { e in
                        HStack {
                            Text(e.symbol).textKind(.ids, 12).frame(width: 52, alignment: .leading)
                            Text(e.name).font(.callout).lineLimit(1)
                            Spacer()
                            Text(e.time.title).font(.caption).foregroundStyle(.secondary)
                            if store.heldEarningsKeys.contains(e.key) { Text("you hold").font(.caption2).padding(.horizontal, 5).background(Color.accentColor.opacity(0.15), in: Capsule()) }
                        }
                    }
                    HStack(spacing: 14) {
                        Button("Earnings Report walkthrough") { store.openReport("earnings") }.buttonStyle(.link)
                        Button("Today's real earnings list") { store.openEarningsDay(EarningsDates.today()) }.buttonStyle(.link)
                            .help("Every company reporting today, from Nasdaq.com and FMP")
                    }
                }
                panel(8, "Fund flows (last week)", "arrow.left.arrow.right.circle", "Money moving into and out of fund categories, from providers such as EPFR, Morningstar and Lipper.",
                      "Flows reveal sentiment, usually after prices moved. Following them tends to mean buying high and selling low.") {
                    Chart(Briefing.flows, id: \.0) { f in
                        BarMark(x: .value("Category", f.0), y: .value("$bn", f.1), width: .fixed(36)).foregroundStyle(Color.signed(f.1))
                            .annotation(position: f.1 >= 0 ? .top : .bottom) { Text(String(format: "%+.1f", f.1)).font(.caption2) }
                    }
                    .frame(height: 140)
                }
                panel(9, "Credit spreads", "creditcard", "Extra yield corporate bonds pay over Treasuries. Widening spreads mean investors want more for credit risk.",
                      "High-yield spreads widening quickly is one of the better stress gauges; today's levels are still low by history.") {
                    ForEach(Briefing.credit, id: \.0) { c in
                        HStack { Text(c.0); Spacer(); Text(String(format: "%.2f%%", c.1)).monospacedDigit(); Text(String(format: "%+.2f", c.2)).monospacedDigit().foregroundStyle(c.2 > 0 ? .red : .green).frame(width: 50, alignment: .trailing) }.font(.callout)
                    }
                    Text("Long-run averages roughly 1.3% (investment grade) and 5% (high yield).").font(.caption).foregroundStyle(.secondary)
                }
                panel(10, "VIX volatility index", "waveform.path.ecg", "The market's expected volatility over the next 30 days, from S&P 500 option prices — the 'fear gauge'.",
                      "A high VIX means big daily swings are expected; it has usually been highest near market lows, when selling feels most urgent.") {
                    Chart(Array(Briefing.vix.enumerated()), id: \.offset) { i, v in
                        LineMark(x: .value("Day", i), y: .value("VIX", v)).foregroundStyle(.orange)
                        RuleMark(y: .value("Average", 19)).foregroundStyle(.secondary.opacity(0.5)).lineStyle(StrokeStyle(dash: [3, 3]))
                    }
                    .chartXAxis(.hidden)
                    .chartYScale(domain: 10...25)
                    .frame(height: 120)
                    Button("The real VIX, since 1990") { store.go(.vix) }
                        .buttonStyle(.link)
                        .help("Knowledge Library ▸ VIX: real data from Cboe")
                }
            }
        }
        .task { if store.earnings.days[EarningsDates.today()] == nil { _ = await store.earnings.load([EarningsDates.today()]) } }
        .task(id: store.portfolio.holdings.map(\.ticker)) { await store.ensureHoldingRisk() }
    }


    private func panel<Content: View>(_ n: Int, _ title: String, _ symbol: String, _ what: String, _ use: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("\(n)").font(.caption.weight(.bold)).frame(width: 18, height: 18).background(Color.accentColor.opacity(0.2), in: Circle())
                Image(systemName: symbol).foregroundStyle(.secondary)
                Text(title).heading(.name)
            }
            content()
            Text(use).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 230, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .copyBlock()
        .quickHelpArea(QuickHelpItem(title: title, detail: what + " For a long-term plan: " + use, symbol: symbol))
    }
}

/// Where each row of the report table is (by row number), for its banding.
private struct ReportRowBounds: PreferenceKey {
    static let defaultValue: [Int: Anchor<CGRect>] = [:]
    static func reduce(value: inout [Int: Anchor<CGRect>], nextValue: () -> [Int: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}
