//
//  ReportView.swift
//  MxPortMGR
//
//  A market-report walkthrough in seven steps: the report, how to read it, the market's move, what it did to the
//  account, your reaction, its long-run consequences against staying with the plan, and the takeaways.
//

import Charts
import SwiftUI

struct ReportView: View {
    @Bindable var store: PortStore
    var report: MarketReport

    private var state: ReportState { store.reportState(report) }

    var body: some View {
        StepPage(store: store, subtitle: report.headline, lessonTitle: "What this walkthrough shows", lesson: [
            "How to read the \(report.title) — what each number means and what the market watches.",
            "What the day's move does to the account selected in the toolbar, holding by holding.",
            "Then you choose a reaction and the Behaviour Lab simulates it against staying with the plan over many possible futures: missed recovery days, trading costs, taxes and tracking error.",
        ], title: report.title) {
            header
            stepBar
            Group {
                switch state.step {
                case 0: theReport
                case 1: reading
                case 2: marketMove
                case 3: yourAccount
                case 4: yourReaction
                case 5: longRun
                default: takeaways
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                if state.step > 0 {
                    Button { store.updateReport(report) { $0.step -= 1 } } label: { Label(MarketReport.steps[state.step - 1], systemImage: "chevron.backward") }
                        .help("Previous step of the walkthrough")
                }
                Spacer()
                if state.step < MarketReport.steps.count - 1 {
                    Button {
                        store.updateReport(report) { $0.step += 1 }
                        if state.step == 5, state.result == nil { Task { await store.simulate(report) } }
                    } label: { HStack { Text(MarketReport.steps[state.step + 1]); Image(systemName: "chevron.forward") } }
                    .buttonStyle(.bordered)
                    .help("Next step of the walkthrough")
                }
            }
        }
    }

    /// The report's tier and drivers, and a menu of every report by tier.
    private var header: some View {
        HStack(spacing: 8) {
            Text(ReportTier.all[report.tier - 1].title).font(.callout.weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 3).background(Color.accentColor.opacity(0.15), in: Capsule())
            if let n = report.topFive {
                Text("Top five · #\(n)").font(.callout.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 3).background(Color.orange.opacity(0.2), in: Capsule())
            }
            ForEach(report.drivers, id: \.self) { d in Label(d.rawValue, systemImage: d.symbol).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Menu {
                ForEach(ReportTier.all) { tier in
                    Section(tier.title) {
                        ForEach(MarketReport.all.filter { $0.tier == tier.id }) { r in Button(r.title) { store.openReport(r.id) } }
                    }
                }
            } label: { Label("Report", systemImage: "newspaper") }
            .fixedSize()
            .help("Choose another report to walk through")
            Button("Report Library") { store.go(.reportLibrary) }
        }
        .quickHelpArea(QuickHelpItem(title: ReportTier.all[report.tier - 1].title, detail: ReportTier.all[report.tier - 1].summary + " This report moves expectations for: " + report.drivers.map(\.rawValue).joined(separator: ", ") + ".", symbol: "books.vertical"))
    }

    private var stepBar: some View {
        HStack(spacing: 4) {
            ForEach(Array(MarketReport.steps.enumerated()), id: \.offset) { i, title in
                Button {
                    store.updateReport(report) { $0.step = i }
                    if i == 5, state.result == nil, !state.running { Task { await store.simulate(report) } }
                } label: {
                    Text("\(i + 1). \(title)")
                        .font(.callout.weight(i == state.step ? .semibold : .regular))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(i == state.step ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Go to step \(i + 1): \(title)")
            }
        }
        .quickHelpArea("Walkthrough Steps", "Read the report, learn to read it, see the market's move and what it did to the account, choose a reaction, and see its long-run consequences. Click any step.", symbol: "list.number")
    }

    // MARK: Steps

    private var theReport: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: report.symbol).font(.title)
                    VStack(alignment: .leading) {
                        Text(report.title.uppercased()).font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        Text(report.headline).font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text(report.source).font(.caption).foregroundStyle(.secondary)
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                    GridRow { Text("").bold(); Text("Reported").bold(); Text("Expected").bold() }
                    ForEach(report.lines) { line in
                        GridRow {
                            Text(line.label).font(.body.weight(.medium))
                            Text(line.value).font(.body.monospacedDigit().weight(.semibold))
                            Text(line.expected).font(.body.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .help(line.meaning)
                        .quickHelpArea(QuickHelpItem(title: line.label, detail: line.meaning + " Reported \(line.value), expected \(line.expected).", symbol: "number"))
                    }
                }
            }
            .padding(16)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .topTrailing) {
                Text("ILLUSTRATIVE").font(.caption2.weight(.heavy)).foregroundStyle(.orange).padding(8)
            }
            Box(title: "About this report", symbol: "info.circle", help: "Who publishes it, when, what it measures and why portfolio managers watch it.") {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                    GridRow { Text("Published by").foregroundStyle(.secondary); Text(report.publisher) }
                    GridRow { Text("When").foregroundStyle(.secondary); Text(report.frequency) }
                    GridRow { Text("Key metrics").foregroundStyle(.secondary); Text(report.keyMetrics.joined(separator: " · ")) }
                    GridRow { Text("Why PMs care").foregroundStyle(.secondary); Text(report.whyCare.joined(separator: " ")) }
                    GridRow { Text("Typical impact").foregroundStyle(.secondary); ImpactDots(level: report.impact) }
                }
                .font(.callout)
            }
            RealReportBox(store: store, report: report)
            Text("Read it the way the market does: point at each line for what it measures, then go on to Reading It.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private var reading: some View {
        VStack(alignment: .leading, spacing: 12) {
            Box(title: "How to read it", symbol: "text.magnifyingglass", help: "The questions analysts ask of this report, in order.") {
                ForEach(Array(report.reading.enumerated()), id: \.offset) { i, r in
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(i + 1).").bold().frame(width: 20)
                        Text(r).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Box(title: "Terms", symbol: "character.book.closed", help: "Words the report and the commentary on it use.") {
                ForEach(report.terms) { t in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.term).font(.callout.weight(.semibold))
                        Text(t.definition).font(.callout).foregroundStyle(.secondary)
                    }
                    .quickHelpArea(QuickHelpItem(title: t.term, detail: t.definition, symbol: "character.book.closed"))
                }
            }
        }
    }

    private var marketMove: some View {
        VStack(alignment: .leading, spacing: 12) {
            Box(title: "What markets did that day", symbol: "chart.line.downtrend.xyaxis", help: "The illustrative day's moves and why each market reacted the way it did.") {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                    GridRow { Text("Market").bold(); Text("Move").bold(); Text("Why").bold() }
                    ForEach(report.moves) { m in
                        GridRow {
                            Text(m.asset)
                            Text(m.move).monospacedDigit().foregroundStyle(m.move.hasPrefix("−") || m.move.hasPrefix("-") ? .red : .green)
                            Text(m.why).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if let c = report.context {
                Box(title: c.title, symbol: "chart.xyaxis.line", help: "Recent history that puts the report in context." + (c.note.isEmpty ? "" : " " + c.note)) {
                    Chart {
                        ForEach(c.points) { p in
                            if c.kind == .bar {
                                BarMark(x: .value("When", p.label), y: .value(c.unit, p.value), width: .ratio(0.6))
                                    .foregroundStyle(p.id == c.points.last?.id ? Color.orange : Color.accentColor.opacity(0.7))
                            } else {
                                LineMark(x: .value("When", p.label), y: .value(c.unit, p.value))
                                PointMark(x: .value("When", p.label), y: .value(c.unit, p.value))
                                    .foregroundStyle(p.id == c.points.last?.id ? Color.orange : Color.accentColor)
                            }
                        }
                        if let ref = c.reference {
                            RuleMark(y: .value("Reference", ref)).foregroundStyle(.secondary).lineStyle(StrokeStyle(dash: [4, 3]))
                                .annotation(position: .top, alignment: .leading) { Text(c.referenceLabel).font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                    .chartYAxisLabel(c.unit)
                    .frame(height: 200)
                    if !c.note.isEmpty { Text(c.note).font(.caption).foregroundStyle(.secondary) }
                }
            }
            if report.id == "yield-curve" {
                Box(title: "The yield curve", symbol: "chart.xyaxis.line", help: "Yields by maturity before and after the report, and an inverted curve for comparison (short yields above long ones, as in 2022–24).") {
                    Chart {
                        ForEach(MarketReport.curveBefore, id: \.0) { p in LineMark(x: .value("Years", p.0), y: .value("Yield", p.1), series: .value("Curve", "Last week")).foregroundStyle(by: .value("Curve", "Last week")) }
                        ForEach(MarketReport.curveAfter, id: \.0) { p in LineMark(x: .value("Years", p.0), y: .value("Yield", p.1), series: .value("Curve", "Today")).foregroundStyle(by: .value("Curve", "Today")) }
                        ForEach(MarketReport.curveInverted, id: \.0) { p in LineMark(x: .value("Years", p.0), y: .value("Yield", p.1), series: .value("Curve", "An inverted curve")).foregroundStyle(by: .value("Curve", "An inverted curve")).lineStyle(StrokeStyle(dash: [4, 3])) }
                    }
                    .chartXScale(type: .log)
                    .chartXAxisLabel("maturity (years, log scale)")
                    .chartYAxisLabel("yield %")
                    .chartYScale(domain: 3.8...5.6)
                    .frame(height: 260)
                }
            }
            Text("By the time most people read the headline, prices have already moved: the news is in the price.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private var yourAccount: some View {
        let p = store.portfolio
        let rows = p.holdings.compactMap { h -> (Holding, Double)? in h.security.map { (h, report.shock($0)) } }
        let total = rows.reduce(0) { $0 + $1.0.value * $1.1 }
        return VStack(alignment: .leading, spacing: 12) {
            if p.id != report.suggestedSample, let s = Samples.all.first(where: { $0.id == report.suggestedSample }) {
                HStack {
                    Image(systemName: "lightbulb").foregroundStyle(.yellow)
                    Text("This report hits “\(s.name)” hardest. You can try it with any account, or:")
                    Button("Use “\(s.name)”") { store.selectedID = s.id }
                }
                .font(.callout)
            }
            HStack(spacing: 10) {
                MetricTile(title: "The account today", value: money(total), caption: signedPct(total / max(p.total, 1)) + " of \(money(p.total))", tint: Color.signed(total), help: "The day's change in value of the account selected in the toolbar, from the report's market move.")
                let shock = report.sleeveShock(p)
                ForEach([Sleeve.stocks, .single, .bonds], id: \.self) { s in
                    if shock[s.rawValue] != 0 {
                        MetricTile(title: s == .single ? (report.single ?? "Single stock") : s.title, value: signedPct(shock[s.rawValue]), tint: Color.signed(shock[s.rawValue]), help: "The day's move of the account's \(s.title.lowercased()).")
                    }
                }
            }
            Box(title: "Holding by holding", symbol: "tablecells", help: "Each holding's illustrative move today and its dollar change; funds move with what they hold.") {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 4) {
                    GridRow { Text("Holding").bold(); Text("Value").bold(); Text("Today").bold(); Text("Change").bold() }
                    ForEach(rows.sorted { $0.0.value * $0.1 < $1.0.value * $1.1 }, id: \.0.ticker) { h, r in
                        GridRow {
                            Text("\(h.ticker) — \(h.security?.name ?? "")")
                            Text(money(h.value)).monospacedDigit()
                            Text(signedPct(r)).monospacedDigit().foregroundStyle(Color.signed(r))
                            Text(money(h.value * r)).monospacedDigit().foregroundStyle(Color.signed(r))
                        }
                    }
                }
                .font(.callout)
            }
            Text("A loss on paper only becomes permanent if you sell. Next: what would you do?").font(.callout).foregroundStyle(.secondary)
        }
    }

    private var yourReaction: some View {
        VStack(alignment: .leading, spacing: 12) {
            Box(title: "What would you do?", symbol: "hand.raised", help: "Choose the reaction to simulate. All of them are simulated against staying with the plan; the chart follows the one chosen.") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 10)], alignment: .leading, spacing: 10) {
                    ForEach([Reaction.plan] + report.reactions) { r in
                        let chosen = (state.reaction ?? report.reactions.first!.id) == r.id
                        Button { store.updateReport(report) { $0.reaction = r.id } } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: chosen ? "largecircle.fill.circle" : "circle").foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Label(r.title, systemImage: r.symbol).font(.callout.weight(.semibold))
                                    Text(r.summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading)
                            .background(chosen ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .quickHelp(r.title, r.summary)
                    }
                }
            }
            Box(title: "The simulation", symbol: "gearshape.2", help: "How the futures are drawn and what each trade costs.") {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        Text("Back to the plan after")
                        Stepper("\(state.settings.monthsOut) months", value: Binding(get: { state.settings.monthsOut }, set: { v in store.updateReport(report) { $0.settings.monthsOut = v; $0.result = nil } }), in: 1...36)
                    }
                    .help("For reactions that sell and buy back later: how long until you buy back")
                    GridRow {
                        Text("Futures")
                        Picker("", selection: Binding(get: { state.settings.scenario }, set: { v in store.updateReport(report) { $0.settings.scenario = v; $0.result = nil } })) {
                            ForEach(Scenario.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden().frame(width: 380)
                    }
                    .help(state.settings.scenario.detail)
                    .quickHelpArea(QuickHelpItem(title: "Futures", detail: Scenario.allCases.map { "\($0.rawValue): \($0.detail)" }.joined(separator: " "), symbol: "dice"))
                    GridRow {
                        Text("Horizon")
                        Picker("", selection: Binding(get: { state.settings.years }, set: { v in store.updateReport(report) { $0.settings.years = v; $0.result = nil } })) {
                            Text("10 years").tag(10); Text("20 years").tag(20); Text("30 years").tag(30)
                        }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 300)
                    }
                    GridRow {
                        Text("Number of futures")
                        Picker("", selection: Binding(get: { state.settings.paths }, set: { v in store.updateReport(report) { $0.settings.paths = v; $0.result = nil } })) {
                            Text("100").tag(100); Text("300").tag(300); Text("1,000").tag(1000)
                        }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 300)
                    }
                    GridRow {
                        Text("Trading cost")
                        Stepper(pct(state.settings.costRate, 2) + " per dollar traded", value: Binding(get: { state.settings.costRate }, set: { v in store.updateReport(report) { $0.settings.costRate = v; $0.result = nil } }), in: 0...0.01, step: 0.0005)
                    }
                    GridRow {
                        Text("Taxes")
                        Text(store.portfolio.account.isTaxable ? "Taxable account: gains taxed when sold at \(pct(store.longTermRate, 0)) long-term / \(pct(store.shortTermRate, 0)) short-term (set in Trades & Taxes)" : "\(store.portfolio.account.rawValue): no tax on trades")
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    store.updateReport(report) { $0.step = 5 }
                    Task { await store.simulate(report) }
                } label: { Label("Simulate the Long Run", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent)
                .help("Simulate every reaction against the plan (⌘↩)")
            }
        }
    }

    @ViewBuilder
    private var longRun: some View {
        if state.running {
            ProgressView("Simulating \(state.settings.paths) futures of \(state.settings.years) years…").frame(maxWidth: .infinity, minHeight: 240)
        } else if let result = state.result {
            LongRunView(store: store, report: report, result: result, chosen: state.reaction ?? report.reactions.first!.id)
        } else {
            ContentUnavailableView {
                Label("Not Simulated Yet", systemImage: "chart.xyaxis.line")
            } description: {
                Text("Choose a reaction, then simulate.")
            } actions: {
                Button("Simulate the Long Run") { Task { await store.simulate(report) } }
            }
            .frame(height: 220)
        }
    }

    private var takeaways: some View {
        VStack(alignment: .leading, spacing: 12) {
            Box(title: "Takeaways", symbol: "checkmark.seal", help: "What this walkthrough is meant to leave you with.") {
                ForEach(report.takeaways, id: \.self) { Label($0, systemImage: "checkmark").fixedSize(horizontal: false, vertical: true) }
            }
            Box(title: "A plan you can keep on a bad day", symbol: "doc.plaintext", help: "Questions to write down answers to on a calm day.") {
                Text("Write down, on a calm day: what the account is for and when you'll need the money; the stock / bond mix and the band you'll rebalance at; what you will do when stocks fall 20% (most plans: rebalance, nothing more); and who you will talk to before changing the plan.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if let i = MarketReport.all.firstIndex(where: { $0.id == report.id }), i + 1 < MarketReport.all.count {
                    let next = MarketReport.all[i + 1]
                    Button("Next walkthrough: \(next.title)") { store.openReport(next.id) }.buttonStyle(.borderedProminent)
                }
                Button("Report Library") { store.go(.reportLibrary) }
                Button("Morning Briefing") { store.go(.morningBriefing) }
            }
        }
    }
}

struct LongRunView: View {
    var store: PortStore
    var report: MarketReport
    var result: SimResult
    var chosen: String

    var body: some View {
        let plan = result.plan
        let pick = result.outcomes.first { $0.reaction.id == chosen } ?? plan
        let gap = pick.medianEnd - plan.medianEnd
        let years = Double(result.settings.years)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: gap < 0 ? "arrow.down.right.circle.fill" : "arrow.up.right.circle.fill").font(.title).foregroundStyle(gap < 0 ? .red : .green)
                VStack(alignment: .leading, spacing: 3) {
                    Text(pick.reaction.isPlan ? "Staying with the plan: \(money(plan.medianEnd)) in the median future after \(result.settings.years) years."
                         : "“\(pick.reaction.title)”: \(money(pick.medianEnd)) vs \(money(plan.medianEnd)) for the plan in the median future — \(gap < 0 ? "" : "+")\(money(gap)) (\(signedPct(gap / plan.medianEnd, 1))).")
                        .font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    if !pick.reaction.isPlan {
                        Text("It came out ahead of the plan in \(pct(pick.aheadOfPlan, 0)) of the futures. \(pick.aheadOfPlan > 0.5 ? "In these futures the reaction usually helped — check its worse outcomes and its risk below, and remember you can't know in advance which future you are in." : "Reacting sometimes works, but you can't know in advance which future you're in.")")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Starting value \(money(result.start)) before today's move. \(result.settings.scenario.rawValue); \(result.settings.paths) futures. Illustrative model, nominal dollars, not a forecast.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            Box(title: "The account over the years: plan vs “\(pick.reaction.title)”", symbol: "chart.xyaxis.line",
                help: "Median account value month by month (lines) and the range from the 10th to the 90th percentile of futures (shaded), for the plan and the chosen reaction.") {
                Chart {
                    ForEach(Array(plan.path.enumerated()), id: \.offset) { i, v in
                        AreaMark(x: .value("Year", Double(i) / 12), yStart: .value("low", plan.low[i]), yEnd: .value("high", plan.high[i]), series: .value("Who", "Plan range"))
                            .foregroundStyle(.blue.opacity(0.10))
                        LineMark(x: .value("Year", Double(i) / 12), y: .value("Value", v), series: .value("Who", "Plan"))
                            .foregroundStyle(.blue)
                    }
                    if !pick.reaction.isPlan {
                        ForEach(Array(pick.path.enumerated()), id: \.offset) { i, v in
                            LineMark(x: .value("Year", Double(i) / 12), y: .value("Value", v), series: .value("Who", "Reaction"))
                                .foregroundStyle(.orange)
                            LineMark(x: .value("Year", Double(i) / 12), y: .value("Value", pick.low[i]), series: .value("Who", "Reaction 10th"))
                                .foregroundStyle(.orange.opacity(0.4)).lineStyle(StrokeStyle(dash: [3, 3]))
                        }
                    }
                }
                .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(money(d)) } } } }
                .chartXAxisLabel("years from today")
                .frame(height: 300)
                HStack(spacing: 14) {
                    Label("Plan (median, shaded 10th–90th)", systemImage: "line.diagonal").foregroundStyle(.blue)
                    if !pick.reaction.isPlan { Label("Reaction (median, dashed 10th percentile)", systemImage: "line.diagonal").foregroundStyle(.orange) }
                }
                .font(.caption)
            }
            Box(title: "Every reaction, same futures", symbol: "tablecells", help: "Each reaction against the plan on exactly the same simulated futures: median ending value, the bad (10th percentile) and good (90th) outcomes, how often it beat the plan, and what it cost.") {
                Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 5) {
                    GridRow {
                        Text("Reaction").bold().gridColumnAlignment(.leading)
                        Text("Median end").bold(); Text("vs plan").bold(); Text("Bad 10%").bold(); Text("Good 10%").bold()
                        Text("Beat plan").bold(); Text("Missed best days").bold(); Text("Taxes").bold(); Text("Costs").bold(); Text("Tracking error").bold(); Text("Worst drop").bold()
                    }
                    Divider().gridCellColumns(11)
                    ForEach(result.outcomes) { o in
                        GridRow {
                            Label(o.reaction.title, systemImage: o.reaction.symbol).fontWeight(o.reaction.id == chosen ? .semibold : .regular)
                            Text(money(o.medianEnd))
                            Text(o.reaction.isPlan ? "—" : signedPct(o.medianEnd / plan.medianEnd - 1, 1)).foregroundStyle(Color.signed(o.medianEnd - plan.medianEnd))
                            Text(money(o.p10End))
                            Text(money(o.p90End))
                            Text(o.reaction.isPlan ? "—" : pct(o.aheadOfPlan, 0))
                            Text(String(format: "%.1f of 10", o.missedBestDays))
                            Text(money(o.medianTaxes))
                            Text(money(o.medianCosts))
                            Text(o.reaction.isPlan ? "—" : pct(o.trackingError, 1))
                            Text(pct(o.medianMaxDrawdown, 0))
                        }
                        .monospacedDigit()
                        .quickHelpArea(QuickHelpItem(title: o.reaction.title, detail: o.reaction.summary + " Median annual return \(pct(o.annualReturn)) over \(result.settings.years) years; about \(String(format: "%.0f", o.trades)) trades.", symbol: o.reaction.symbol))
                    }
                }
                .font(.callout)
                Text("Missed best days: of the ten best days for stocks in each future, how many the account spent mostly out of the market. Tracking error: how differently the reaction's account moved from the plan's, a year. Worst drop: the median of each future's largest fall from a high.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 14) {
                Box(title: "Missing the best days", symbol: "calendar.badge.exclamationmark", help: "Average annual return of stocks over these futures if the best N days are missed — they cluster near the worst days, just when selling feels right.") {
                    Chart(result.missingBest, id: \.days) { m in
                        BarMark(x: .value("Missed", m.days == 0 ? "None" : "Best \(m.days)"), y: .value("Annual %", m.annual * 100))
                            .foregroundStyle(m.days == 0 ? Color.blue : Color.orange)
                            .annotation(position: .top) { Text(pct(m.annual)).font(.caption2) }
                    }
                    .chartYAxisLabel("annual return %")
                    .frame(height: 220)
                    Text("Over \(Int(years)) years — about \(Int(years) * 252) trading days — missing just the 10 best costs roughly \(pct((result.missingBest.first?.annual ?? 0) - (result.missingBest.first { $0.days == 10 }?.annual ?? 0))) a year.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                Box(title: "Where the difference comes from", symbol: "list.bullet.indent", help: "The channels through which an emotional reaction costs over time.") {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Missed recovery: out of the market when the rebound comes. Rebounds often start on bad news.", systemImage: "arrow.uturn.up")
                        Label("Turnover cost: the spread on every sale and buy-back (\(money(pick.medianCosts)) median for this reaction).", systemImage: "arrow.left.arrow.right")
                        Label("Tax drag: selling realises gains that would otherwise compound untaxed (\(money(pick.medianTaxes)) median).", systemImage: "building.columns")
                        Label("Tracking error: the account no longer follows the plan (\(pct(pick.trackingError, 1)) a year), so its results stop being the ones the plan was built on.", systemImage: "arrow.left.and.right")
                        Label("Behaviour repeats: someone who sells on one scary report tends to sell on the next — compare “React to every scary headline”.", systemImage: "repeat")
                    }
                    .font(.callout)
                }
            }
        }
    }
}

/// The real report behind the illustrative one: the publisher's latest release, its schedule and its history — and,
/// for the earnings reports, MxPortMGR's own screens with real companies.
struct RealReportBox: View {
    @Bindable var store: PortStore
    var report: MarketReport

    var body: some View {
        Box(title: "The real report", symbol: "arrow.up.right.square",
            help: "The publisher's own pages for the actual \(report.title): the latest release, when the next one comes out, and its history. This walkthrough's numbers are made up to teach.") {
            Text("This walkthrough uses illustrative numbers. Read the actual \(report.title) at its source:")
                .font(.callout).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(report.sources) { s in
                    GridRow {
                        Label(s.kind.rawValue, systemImage: s.kind.symbol).font(.caption).foregroundStyle(.secondary)
                        Link(s.title, destination: s.url)
                            .help(s.address)
                            .quickHelp(s.title, "\(s.kind.rawValue) from \(s.publisher) — opens \(s.address) in your browser.", symbol: s.kind.symbol)
                        Text(s.publisher).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .font(.callout)
            if report.id == "earnings" || report.id == "revisions" {
                HStack(spacing: 10) {
                    Button { store.openEarningsDay(EarningsDates.today()) } label: { Label("Earnings by Day", systemImage: "list.bullet.rectangle") }
                        .help("Every company reporting today, with estimates and results (Nasdaq.com and FMP)")
                    Button { store.go(.earningsCalendar) } label: { Label("Earnings Calendar", systemImage: "calendar") }
                        .help("Real earnings reports by month or week")
                    Text("Real companies' reports, in MxPortMGR.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

