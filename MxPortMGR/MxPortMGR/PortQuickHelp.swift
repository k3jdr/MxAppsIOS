//
//  PortQuickHelp.swift
//  MxPortMGR
//
//  What Quick Help (Shared/QuickHelp) says in MxPortMGR: each screen in the sidebar, the account selected, and the
//  terms and controls the pointer can rest on.
//

import SwiftUI

enum PortHelp {
    static func about(_ screen: Screen) -> QuickHelpItem {
        let detail: String
        switch screen {
        case .welcome: detail = "What MxPortMGR teaches, how the guide is laid out, and how Quick Help works. Everything runs on an illustrative market of fictional companies, except the earnings screens, which show real companies' reports."
        case .choosePath: detail = "The questions that separate an actively managed portfolio from a passive index one — and a start button for each path. It doesn't choose for you."
        case .whyOptimize: detail = "Why a portfolio needs more than good picks: diversification, the risk–return trade-off, and what an optimizer does with forecasts, a risk model and limits. Two live demos."
        case .whyAttribution: detail = "Why results need explaining: was it being in the right sectors (allocation) or picking the right companies (selection)? A two-sector demo you can change."
        case .activeVsPassive: detail = "Costs, tracking error and the odds of beating an index: what you sign up for with each approach. A fee-compounding demo."
        case .myPortfolio: detail = "My Portfolio, step 1: your own holdings — from the illustrative universe or the security master (srm) — with shares, values and tax lots; add, edit and remove them, and fix the checks first."
        case .myBenchmark: detail = "My Portfolio, step 2: the benchmark that matches your plan — illustrative, or an index loaded in the security master — with sector and asset-mix comparisons, overlap, active share and its largest members."
        case .myRisk: detail = "My Portfolio, step 3: how much your account can move, where its risk comes from, and how far it sits from your benchmark."
        case .myImprove: detail = "My Portfolio, step 4: with an active approach, optimize within a risk budget (built-in or portfolio-java); with a passive approach, build the tracker with the fewest names or compare one index fund (built-in or portfolio-cpp)."
        case .myTrades: detail = "My Portfolio, step 5: active — the trades, their cost and the taxes by lot; passive — the stock / bond / cash mix against its rebalance bands and the trades to return."
        case .myAttribution: detail = "My Portfolio, step 6: last year's difference from your benchmark split into allocation, selection and interaction by sector, month by month."
        case .activePortfolio: detail = "Model Portfolio (active), step 1: the account's holdings, look-through sector weights against its benchmark, and the problems to fix first."
        case .activeRisk: detail = "Model Portfolio (active), step 2: how much the account can move, where the risk comes from, and how far it is from the benchmark (tracking error, beta, VaR)."
        case .activeOptimize: detail = "Model Portfolio (active), step 3: turn forecasts into weights within a risk budget — tracking-error target, weight limits, sector bands — with the built-in engine or portfolio-java."
        case .activeTrades: detail = "Model Portfolio (active), step 4: the trades the optimizer proposes, their turnover and cost, and (in a taxable account) the realised gains by tax lot."
        case .activeAttribution: detail = "Model Portfolio (active), step 5: last year's active return split into allocation, selection and interaction by sector, month by month, Carino-linked."
        case .passivePortfolio: detail = "Model Portfolio (passive), step 1: the account against the index it should follow, with the problems that make tracking harder."
        case .passiveDrift: detail = "Model Portfolio (passive), step 2: tracking error today and how it grew as holdings drifted through the year."
        case .passiveTrack: detail = "Model Portfolio (passive), step 3: the fewest names that track the index within budget, the tracking-error curve, and the one-fund alternative — built-in or portfolio-cpp."
        case .passiveBands: detail = "Model Portfolio (passive), step 4: the stock / bond / cash mix against its targets and rebalance bands, when the bands were crossed, and the trades to return."
        case .passiveAttribution: detail = "Model Portfolio (passive), step 5: attribution for an index portfolio — small effects everywhere is success; any large effect is drift or a mistake."
        case .reportLibrary: detail = "The reports portfolio managers watch, in six tiers — market-moving economic reports, growth, corporate, positioning, fixed income and industry — with what each measures, why PMs care, the price drivers it moves, and the five with the greatest impact. Open any one's walkthrough."
        case .morningBriefing: detail = "An illustrative morning: overnight markets, Treasury yields, the economic calendar, the economic surprise index, Fed funds futures, analyst rating changes, earnings releases, fund flows, credit spreads and the VIX — with what the account would be worth if it opened with the futures."
        case .earningsCalendar: detail = "Real earnings reports by month or week: for past days how many U.S.-listed companies beat or missed the consensus EPS, for upcoming days who reports and what analysts expect, with the companies you hold marked. Select a day for its full list. Nasdaq.com's calendar, with revenue from FMP through the accounts service."
        case .earningsDay: detail = "Every company reporting on a day — symbol, company, before the open or after the close, consensus and actual EPS with the surprise (Nasdaq.com), revenue estimate and actual (FMP) — sortable and filterable, with the selected company's history. Real data."
        case .reportWalkthrough: detail = "A report walkthrough in seven steps: the report, how to read it, the market's move, what it did to the account, your reaction, its long-run consequences against the plan, and the takeaways. Choose another report with the Report menu at the top."
        case .samples: detail = "Every sample account, the edge case it teaches and what to look for. Select one to use it everywhere; copy one into My Portfolio to edit."
        case .services: detail = "The shared Layer 3 services (MXcodeIDE/Services) — portfolio-java for active optimization, portfolio-cpp for tracking and risk, analytics for attribution — whether they run and how to start them."
        }
        return QuickHelpItem(title: screen.fullTitle, detail: detail, symbol: screen.systemImage)
    }

    static func selection(_ store: PortStore) -> QuickHelpItem {
        let p = store.portfolio
        return QuickHelpItem(title: p.name,
                             detail: "\(p.account.rawValue), \(money(p.total)), benchmark \(p.benchmarkInfo.name). \(p.lesson)",
                             symbol: p.symbol)
    }

    static let disclaimer = QuickHelpItem(
        title: "Educational Use Only",
        detail: "The companies, prices, reports and futures in MxPortMGR are made up, in the shape of real ones, to show how the tools work and what choices cost. Nothing here is a recommendation for your own accounts.",
        symbol: "graduationcap")

    static let samplePicker = QuickHelpItem(
        title: "Account",
        detail: "The sample account every screen works on. Each sample is an edge case — concentrated, sector-heavy, income, cash-heavy, frequent trading, a drifted tracker, tax lots, a band breach, messy data — or My Portfolio, which you can edit.",
        symbol: "briefcase")

    static let engine = QuickHelpItem(
        title: "Engine",
        detail: "Built-in runs the optimizers inside MxPortMGR. Layer 3 services sends the same inputs to portfolio-java (active, port 8766) and portfolio-cpp (tracking, port 8767), the engines MxJobsWMS and MxDataHUB use, so you can compare. Start them with python3 Services/mxservices.py start.",
        symbol: "cpu")

    // MARK: Terms

    static let terms: [String: String] = [
        "Tracking error": "How much the account's return is expected to differ from the benchmark's in a typical year (standard deviation of the difference). 1% is index-like; 3–6% is a typical active fund.",
        "Active weight": "Account weight minus benchmark weight. Positive: overweight (a bet it does better); negative: underweight.",
        "Active share": "Half the sum of the absolute active weights: the share of the account that differs from the benchmark. 0% is the index; above 60% is very active.",
        "Information ratio": "Forecast active return divided by tracking error — reward per unit of active risk. Above 0.5 is good for a forecast; realised ratios are usually lower.",
        "Beta": "How much the account tends to move when the benchmark moves 1%. Below 1 is more defensive; above 1 more aggressive.",
        "Volatility": "The typical size of a year's ups and downs (standard deviation of annual return).",
        "VaR (95%, 1 month)": "A month's loss the account should not exceed 19 months in 20 under the risk model. Not the worst case.",
        "Expected shortfall": "The average loss in the worst 1 month in 20: what a bad month looks like when it comes.",
        "Allocation effect": "Return from weighting sectors differently from the benchmark: overweight a sector that beat the benchmark → positive.",
        "Selection effect": "Return from holding different companies within a sector: your sector holdings beat the benchmark's in that sector → positive.",
        "Interaction effect": "Return from overweighting the sectors where your selection also worked (or underweighting where it didn't).",
        "Turnover": "Half the sum of absolute weight changes: the share of the account bought (and sold) to reach the target.",
        "Rebalance band": "How far a weight may drift from its target before you trade back. Wider bands trade less (cheaper, fewer taxes) but allow more drift.",
        "Look-through": "A fund replaced by what it holds, so an index fund plus a single stock shows the stock's true total weight.",
        "Tax lot": "Shares bought at one time and price. Selling a specific lot decides the gain: highest-cost-first usually realises the least gain.",
        "Carino linking": "Monthly effects scaled so that, over a year, they add up exactly to the compounded active return.",
    ]

    static func term(_ t: String) -> QuickHelpItem { QuickHelpItem(title: t, detail: terms[t] ?? "", symbol: "character.book.closed") }
}

extension View {
    /// Quick Help and a tooltip for a glossary term.
    func term(_ t: String) -> some View {
        help(PortHelp.terms[t] ?? t).quickHelpArea(PortHelp.term(t))
    }
}
