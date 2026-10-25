//
//  LearnViews.swift
//  MxAcctMGR
//
//  Start Here and Learn the Why: the welcome, choosing a path, and three lessons with live demos — why optimize
//  (diversification and the stock / bond trade-off), why attribution (allocation vs selection in two sectors), and
//  active vs passive (what fees compound to).
//

import Charts
import SwiftUI

// MARK: - Welcome

struct WelcomeView: View {
    @Bindable var store: PortStore

    var body: some View {
        StepPage(store: store, subtitle: "A portfolio-management IDE that explains why before it shows how.", lessonTitle: "Before you start", lesson: [
            "MxAcctMGR teaches how professional portfolio tools — optimization, risk, index tracking and attribution — apply to personal accounts, and what everyday decisions cost over the long run.",
            "Everything runs on real data from the security master: real securities, prices and benchmarks, sample accounts built from real purchases, and risk estimated from real daily prices. The market-report walkthroughs are scenarios in the shape of real releases, and the futures are simulations.",
            "It is educational. It never tells you what to buy or sell for your own accounts; talk to a licensed adviser about your situation.",
        ]) {
            HStack(alignment: .top, spacing: 14) {
                card("1. Choose a Path", "signpost.right.and.left", "Active: beat a benchmark within a risk budget. Passive: match an index cheaply and stay matched. Then work through My Portfolio.", .choosePath)
                card("2. Read the News", "newspaper", "Eighteen reports portfolio managers watch — jobs, CPI, the Fed, earnings, the yield curve and more — a morning briefing, and real earnings by day and month. Simulate your reaction to each over twenty years.", .reportLibrary)
                card("3. Learn the Why", "lightbulb", "Why a portfolio needs optimizing, why results need attributing, and what active and passive cost — in Knowledge Library.", .whyOptimize)
            }
            Box(title: "How to use it", symbol: "questionmark.circle", help: "How the window is laid out and how Quick Help works.") {
                VStack(alignment: .leading, spacing: 6) {
                    Label("The sidebar is the guide: My Portfolio has six steps; ⌥⌘↓ and ⌥⌘↑ move to the next and previous screen, and ⌘[ and ⌘] go back and forward, as in a browser.", systemImage: "sidebar.left")
                    Label("Quick Help, under the sidebar, explains whatever is under the pointer — a number, a column, a button. ⌥⌘/ shows or hides it; its ⧉ button floats it in its own window.", systemImage: "questionmark.bubble")
                    Label("Investments, in the sidebar, walks your own account (My Portfolio) through six steps — active or passive, your choice.", systemImage: "person.crop.circle")
                    Label("Pick a sample account in the toolbar for the report walkthroughs and the Morning Briefing: each teaches an edge case. Library ▸ Sample Portfolios describes them all; copy one into My Portfolio to work through it.", systemImage: "briefcase")
                    Label("Engine in the toolbar: the built-in optimizers, or the shared Layer 3 services (portfolio-java, portfolio-cpp, analytics) that MxDataHUB and MxJobsMGR use.", systemImage: "cpu")
                }
                .font(.callout)
            }
            Box(title: "The account now selected", symbol: store.portfolio.symbol) {
                Text(store.portfolio.name).heading(.subheading)
                Text(store.portfolio.lesson).fixedSize(horizontal: false, vertical: true)
                Button("See All Sample Portfolios") { store.go(.samples) }
            }
        }
    }

    private func card(_ title: String, _ symbol: String, _ text: String, _ target: Screen) -> some View {
        Button { store.go(target) } label: {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol).font(.largeTitle).foregroundStyle(Color.accentColor)
                Text(title).heading(.subheading)
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .plainButton()
        .help("Go to \(target.fullTitle)")
        .quickHelp(title, text)
    }
}

// MARK: - Choose your path

struct ChoosePathView: View {
    @Bindable var store: PortStore

    private let questions: [(String, String, String)] = [
        ("Do you believe you (or a manager) can pick winners consistently, after costs?", "Active needs a real, repeatable edge — most professionals fail to beat their index after fees over long periods.", "Passive accepts the market's return and spends its effort on cost and discipline."),
        ("How much do you want results to differ from the market's?", "Active means accepting tracking error: some years well ahead, some well behind.", "Passive keeps you close to the index — in good years and bad."),
        ("How much time will you spend?", "Active needs research, monitoring and an honest review (attribution) every year.", "Passive needs a rebalance rule and the patience to follow it."),
        ("Is the account taxable?", "Frequent active trading realises gains, often short-term.", "Index funds and wide rebalance bands defer taxes."),
    ]

    var body: some View {
        StepPage(store: store, subtitle: "Two ways to run a portfolio. The questions help you see the trade-offs; the choice is yours.", lesson: [
            "An active portfolio tries to beat a benchmark by holding different weights from it — overweighting what you expect to do well. It takes active risk to do so, measured by tracking error.",
            "A passive portfolio tries to match an index as closely and cheaply as possible, and to stay matched as prices move.",
            "Many people combine them: a passive core with a small active satellite. The samples include both; copy one into My Portfolio to try it.",
        ]) {
            Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text("Question").heading(.name)
                    Label("Active", systemImage: "wand.and.stars").heading(.name)
                    Label("Passive", systemImage: "scope").heading(.name)
                }
                Divider().gridCellColumns(3)
                ForEach(questions, id: \.0) { q in
                    GridRow {
                        Text(q.0).font(.callout.weight(.semibold)).frame(width: 300, alignment: .leading)
                        Text(q.1).font(.callout).fixedSize(horizontal: false, vertical: true)
                        Text(q.2).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                    .quickHelpArea(QuickHelpItem(title: q.0, detail: "Active: \(q.1) Passive: \(q.2)", symbol: "questionmark.circle"))
                }
            }
            .padding(12)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.fill").font(.largeTitle).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ready to work on your own account?").heading(.subheading)
                    Text("Investments walks your own holdings (My Portfolio) through six steps: choose Active or Passive index there, and steps 4 and 5 follow your choice. To learn on a sample first, copy one into My Portfolio (Library ▸ Sample Portfolios, or Start From a Sample).")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Start My Portfolio") { store.go(.myPortfolio) }.buttonStyle(.borderedProminent)
            }
            .padding(14)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .quickHelpArea("Investments", "The six steps on your own account: My Holdings, My Benchmark, Risk Today, Optimize or Build the Tracker, Trades & Taxes or Rebalance Bands, Attribution.", symbol: "person.crop.circle")
        }
    }
}

// MARK: - Why optimize

struct WhyOptimizeView: View {
    @Bindable var store: PortStore
    @State private var names = 5.0
    @State private var stockShare = 0.6
    /// Volatility of an equal-weighted portfolio of n S&P 500 members (the average over random draws).
    @State private var diversification: [(Int, Double)] = []
    /// Every mix of VTI (stocks) and BND (bonds): expected return and volatility.
    @State private var mixes: [(stocks: Double, ret: Double, vol: Double)] = []
    @State private var problem: String?

    private static let maxNames = 50

    /// Both charts from the analytics service: the S&P 500 members' covariance (Ledoit-Wolf on two years of real
    /// prices) and VTI / BND's, with their betas and the 3-month Treasury yield.
    private func load() async {
        do {
            let (sp, _) = try await ServiceClient.riskInputs(securities: [], benchmark: "SP500")
            var rng = SeededRandom(seed: 5)
            let n = sp.n
            diversification = n < 2 ? [] : (1...min(Self.maxNames, n)).map { k in
                var total = 0.0
                for _ in 0..<40 {
                    let picks = Array((0..<n).shuffled(using: &rng).prefix(k))
                    var v = 0.0
                    for i in picks { for j in picks { v += sp.cov[i * n + j] } }
                    total += (v / Double(k * k)).squareRoot()
                }
                return (k, total / 40)
            }
            let (two, _) = try await ServiceClient.riskInputs(securities: ["VTI", "BND"])
            guard let iv = two.assets.firstIndex(where: { Universe.security($0)?.displayTicker == "VTI" }),
                  let ib = two.assets.firstIndex(where: { Universe.security($0)?.displayTicker == "BND" }) else {
                throw ServiceClient.Failure.rejected("VTI or BND isn't in the security master with prices")
            }
            let rv = Universe.security(two.assets[iv]).map(Universe.expectedReturn) ?? 0
            let rb = Universe.security(two.assets[ib]).map(Universe.expectedReturn) ?? 0
            let c = { (i: Int, j: Int) in two.cov[i * two.n + j] }
            mixes = stride(from: 0.0, through: 1.0001, by: 0.05).map { x in
                let v = x * x * c(iv, iv) + (1 - x) * (1 - x) * c(ib, ib) + 2 * x * (1 - x) * c(iv, ib)
                return (x, x * rv + (1 - x) * rb, v.squareRoot())
            }
            problem = nil
        } catch {
            if !(error is CancellationError) { problem = error.localizedDescription }
        }
    }

    var body: some View {
        StepPage(store: store, subtitle: "Good picks are not a portfolio. How much of each — and how they move together — decides the risk you take.", lesson: [
            "Every holding has risk of its own and risk it shares with the market. Holding more companies diversifies away their own risk — for free — but not the market's.",
            "More return usually needs more risk: the stock / bond mix sets most of an account's risk and long-run return.",
            "An optimizer turns three things into weights: forecasts (what you expect), a risk model (how things move together) and limits (what you won't do). It is only as good as its forecasts, which is why the limits matter.",
        ]) {
            if let problem {
                Box(title: "Needs the analytics service", symbol: "exclamationmark.triangle", help: "These charts are computed from real prices in the security master by the analytics service.") {
                    Text(problem).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Button("Try Again") { Task { await load() } }
                }
            } else if diversification.isEmpty || mixes.isEmpty {
                Box(title: "Diversification and the stock / bond trade-off", symbol: "hourglass", help: "Reading the S&P 500's and VTI / BND's risk from the analytics service.") {
                    HStack { ProgressView().controlSize(.small); Text("Estimating risk from two years of real prices (analytics service)…").foregroundStyle(.secondary) }
                }
            } else {
            HStack(alignment: .top, spacing: 14) {
                Box(title: "Diversification: own risk fades, market risk stays", symbol: "circle.grid.3x3",
                    help: "Volatility of an equal-weighted portfolio of S&P 500 members chosen at random (the average of 40 draws), from two years of real daily prices. The first few names cut risk sharply; then the line flattens near the market's own volatility (VTI's, dashed).") {
                    let selected = diversification[min(Int(names), diversification.count) - 1]
                    Chart {
                        ForEach(diversification, id: \.0) { p in
                            LineMark(x: .value("Companies", p.0), y: .value("Volatility", p.1 * 100))
                        }
                        RuleMark(y: .value("Market", Universe.marketVol * 100))
                            .foregroundStyle(.secondary)
                            .lineStyle(StrokeStyle(dash: [4, 3]))
                            .annotation(position: .top, alignment: .trailing) { Text("market risk").font(.caption2).foregroundStyle(.secondary) }
                        PointMark(x: .value("Companies", selected.0), y: .value("Volatility", selected.1 * 100)).symbolSize(80)
                    }
                    .chartYAxisLabel("Volatility %")
                    .chartXAxisLabel("Companies held (equal weights)")
                    .frame(height: 220)
                    Slider(value: $names, in: 1...Double(diversification.count), step: 1) { Text("Companies") }
                        .help("Number of companies held in equal weights")
                    Text("\(Int(names)) compan\(Int(names) == 1 ? "y" : "ies"): volatility \(pct(selected.1)) a year — in a bad year (about 1 in 6) the account could fall \(pct(selected.1 - 0.08)) or more.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                Box(title: "The trade-off: stocks for growth, bonds for stability", symbol: "chart.xyaxis.line",
                    help: "Every mix of VTI (U.S. stocks) and BND (U.S. bonds), from all bonds (bottom left) to all stocks (top right): volatility from two years of real prices; expected return = the 3-month Treasury yield + beta × an assumed 5% equity premium.") {
                    let m = mixes.min { abs($0.stocks - stockShare) < abs($1.stocks - stockShare) }!
                    Chart {
                        ForEach(mixes, id: \.stocks) { p in
                            LineMark(x: .value("Volatility", p.vol * 100), y: .value("Return", p.ret * 100))
                        }
                        PointMark(x: .value("Volatility", m.vol * 100), y: .value("Return", m.ret * 100)).symbolSize(80)
                            .annotation(position: .leading) { Text("\(Int(m.stocks * 100))/\(100 - Int(m.stocks * 100))").font(.caption) }
                    }
                    .chartXAxisLabel("Volatility %")
                    .chartYAxisLabel("Expected return % (CAPM, assumed premium)")
                    .frame(height: 220)
                    Slider(value: $stockShare, in: 0...1, step: 0.05) { Text("Stocks") }
                        .help("Share of stocks in the mix")
                    Text("\(Int(m.stocks * 100))% VTI / \(100 - Int(m.stocks * 100))% BND: about \(pct(m.ret)) a year expected (the 3-month yield \(pct(Universe.riskFree, 2)) plus beta × a \(pct(Universe.equityPremium, 0)) premium, an assumption) with \(pct(m.vol)) volatility, measured.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
            }
            Box(title: "What an optimizer does", symbol: "wand.and.stars", help: "The optimizer's three inputs and its output.") {
                HStack(alignment: .top, spacing: 12) {
                    step("Forecasts", "Expected returns or alpha: what you believe about each holding. Small errors here produce large errors in weights.")
                    Image(systemName: "plus").foregroundStyle(.secondary)
                    step("Risk model", "How every pair of holdings moves together (a covariance matrix). Here: estimated from two years of real daily prices in the security master, shrunk toward a simpler model (Ledoit-Wolf) so it stays stable.")
                    Image(systemName: "plus").foregroundStyle(.secondary)
                    step("Limits", "Largest position, how far from the benchmark, sector bands, a tracking-error budget, how much to trade.")
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    step("Weights & trades", "The mix with the best forecast reward per unit of risk inside the limits — and the trades to get there.")
                }
                Text("Without limits an optimizer bets heavily on whatever its forecasts like most — 'error maximisation'. Investments' Optimize step (the active approach) lets you change each limit and see what binds.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .task { if diversification.isEmpty || mixes.isEmpty { await load() } }
    }

    private func step(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout.weight(.semibold))
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .quickHelpArea(QuickHelpItem(title: title, detail: text, symbol: "wand.and.stars"))
    }
}

// MARK: - Why attribution

struct WhyAttributionView: View {
    @Bindable var store: PortStore
    @State private var techWeight = 0.45
    @State private var techReturn = 0.14
    @State private var restReturn = 0.09
    private let benchTechWeight = 0.30, benchTech = 0.20, benchRest = 0.08

    var body: some View {
        let wp = [techWeight, 1 - techWeight], wb = [benchTechWeight, 1 - benchTechWeight]
        let rp = [techReturn, restReturn], rbs = [benchTech, benchRest]
        let rb = zip(wb, rbs).reduce(0) { $0 + $1.0 * $1.1 }
        let total = zip(wp, rp).reduce(0) { $0 + $1.0 * $1.1 }
        let alloc = (0..<2).reduce(0) { $0 + (wp[$1] - wb[$1]) * (rbs[$1] - rb) }
        let sel = (0..<2).reduce(0) { $0 + wb[$1] * (rp[$1] - rbs[$1]) }
        let inter = (0..<2).reduce(0) { $0 + (wp[$1] - wb[$1]) * (rp[$1] - rbs[$1]) }
        return StepPage(store: store, subtitle: "A return on its own says little. Attribution says where it came from — so you can tell skill from luck, and a working plan from a broken one.", lesson: [
            "Active return is the account's return minus the benchmark's. It comes from two decisions: how much to put in each sector (allocation) and which companies to hold in it (selection).",
            "Allocation: overweighting a sector that beat the whole benchmark adds return. Selection: your companies in a sector beating the benchmark's companies in that sector adds return. Interaction: overweighting where your selection was good.",
            "For an active account, attribution tests the story: did the bets you meant to make pay, or did something you didn't mean to do (a sector drift) drive the result? For a passive account, every effect should be close to zero.",
        ]) {
            HStack(alignment: .top, spacing: 14) {
                Box(title: "Two sectors: change the account", symbol: "slider.horizontal.3",
                    help: "Move the sliders to change the account's technology weight and the returns of its holdings; the benchmark is 30% technology returning 20% and 70% everything else returning 8%.") {
                    labeled("Technology weight in the account", pct(techWeight, 0), $techWeight, 0...0.9, 0.05)
                    labeled("Your technology holdings returned", pct(techReturn, 0), $techReturn, -0.1...0.4, 0.01)
                    labeled("Your other holdings returned", pct(restReturn, 0), $restReturn, -0.1...0.3, 0.01)
                    Divider()
                    Text("Benchmark: technology \(pct(benchTechWeight, 0)) at \(pct(benchTech, 0)), the rest \(pct(1 - benchTechWeight, 0)) at \(pct(benchRest, 0)) → \(pct(rb)).")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Account: \(pct(total)) → active return \(signedPct(total - rb)).").font(.callout.weight(.semibold))
                }
                Box(title: "Where the active return came from", symbol: "chart.bar.xaxis",
                    help: "Brinson-Fachler effects of the two-sector example: they always add up to the active return.") {
                    Chart {
                        BarMark(x: .value("Effect", "Allocation"), y: .value("%", alloc * 100)).foregroundStyle(Color.signed(alloc))
                        BarMark(x: .value("Effect", "Selection"), y: .value("%", sel * 100)).foregroundStyle(Color.signed(sel))
                        BarMark(x: .value("Effect", "Interaction"), y: .value("%", inter * 100)).foregroundStyle(Color.signed(inter))
                        BarMark(x: .value("Effect", "Active"), y: .value("%", (total - rb) * 100)).foregroundStyle(.blue)
                    }
                    .chartYAxisLabel("percentage points")
                    .frame(height: 200)
                    Text(story(alloc, sel, inter)).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                ForEach(["Allocation effect", "Selection effect", "Interaction effect", "Carino linking"], id: \.self) { t in
                    Text(t).font(.callout).padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                        .term(t)
                }
            }
        }
    }

    private func story(_ a: Double, _ s: Double, _ i: Double) -> String {
        let big = [("allocation (being overweight or underweight technology)", a), ("selection (which companies you held)", s), ("interaction", i)].max { abs($0.1) < abs($1.1) }!
        return "Most of the difference came from \(big.0): \(signedPct(big.1)). " + (techWeight > benchTechWeight
            ? "Being overweight technology helps when technology beats the whole benchmark; it hurts when it doesn't."
            : "Being underweight technology costs return when technology beats the whole benchmark.")
    }

    private func labeled(_ title: String, _ value: String, _ binding: Binding<Double>, _ range: ClosedRange<Double>, _ step: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(title).font(.callout); Spacer(); Text(value).font(.callout.monospacedDigit()) }
            Slider(value: binding, in: range, step: step).help(title)
        }
    }
}

// MARK: - Active vs passive

struct ActiveVsPassiveView: View {
    @Bindable var store: PortStore
    @State private var activeFee = 0.0075
    @State private var alpha = 0.0
    private let passiveFee = 0.0005, gross = 0.065, start = 100_000.0, years = 30

    var body: some View {
        let points = (0...years).flatMap { y -> [(Int, String, Double)] in
            [(y, "Index fund", start * pow(1 + gross - passiveFee, Double(y))),
             (y, "Active fund", start * pow(1 + gross + alpha - activeFee, Double(y)))]
        }
        let endP = start * pow(1 + gross - passiveFee, Double(years)), endA = start * pow(1 + gross + alpha - activeFee, Double(years))
        return StepPage(store: store, subtitle: "What each approach costs and promises, before you commit to one.", lesson: [
            "Passive: the market's return minus a small fee, with almost no tracking error. You give up the chance to beat the market in exchange for near-certainty of not trailing it by much.",
            "Active: the chance to beat the benchmark, paid for with higher fees, trading costs, taxes in a taxable account, and tracking error — years well behind as well as ahead.",
            "In many published studies most actively managed funds trail their index after fees over 10–15 years — often 80–90% of them. An active plan should say why it expects to be in the rest, and attribution should check every year.",
        ]) {
            Box(title: "What fees compound to", symbol: "percent",
                help: "$100,000 over 30 years at an illustrative 6.5% a year before fees. Move the active fee and the alpha the active manager must add to break even.") {
                Chart {
                    ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                        LineMark(x: .value("Year", p.0), y: .value("Value", p.2), series: .value("Fund", p.1))
                            .foregroundStyle(by: .value("Fund", p.1))
                    }
                }
                .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(money(d)) } } } }
                .frame(height: 240)
                HStack(spacing: 20) {
                    VStack(alignment: .leading) {
                        Text("Active fee \(pct(activeFee, 2)) a year").font(.callout)
                        Slider(value: $activeFee, in: 0.001...0.015, step: 0.0005).help("Annual fee of the active fund")
                    }
                    VStack(alignment: .leading) {
                        Text("Active return before fees vs the index: \(signedPct(alpha, 2))").font(.callout)
                        Slider(value: $alpha, in: -0.01...0.02, step: 0.0005).help("How much the manager beats (or trails) the index before fees each year")
                    }
                }
                Text("After \(years) years: index fund \(money(endP)), active fund \(money(endA)) — \(endA >= endP ? "ahead by" : "behind by") \(money(abs(endA - endP))). To break even the active manager must add \(pct(activeFee - passiveFee, 2)) a year, every year, before fees.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow { Text("").bold(); Text("Active").bold(); Text("Passive").bold() }
                Divider().gridCellColumns(3)
                row("Goal", "Beat the benchmark after costs", "Match the index as cheaply as possible")
                row("Typical tracking error", "3–8% a year", "0.05–1% a year")
                row("Typical fees", "0.4–1.2% a year", "0.03–0.20% a year")
                row("Turnover", "30–100%+ a year", "2–10% a year")
                row("Taxes (taxable account)", "Gains realised along the way", "Mostly deferred until you sell")
                row("Main tool here", "Active optimizer (portfolio-java)", "Index tracker (portfolio-cpp)")
                row("Attribution should show", "The bets you meant to make paying", "Effects close to zero")
            }
            .textKind(.results)
            .padding(12)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            .quickHelpArea("Active vs Passive", "Typical ranges for funds and accounts; illustrative, not rules.", symbol: "tablecells")
        }
    }

    private func row(_ a: String, _ b: String, _ c: String) -> some View {
        GridRow { Text(a).foregroundStyle(.secondary); Text(b); Text(c) }
    }
}
