//
//  PortQuickHelp.swift
//  MxAcctMGR
//
//  What Quick Help (Shared/QuickHelp) says in MxAcctMGR: each screen in the sidebar, the account selected, and the
//  terms and controls the pointer can rest on.
//

import SwiftUI

enum PortHelp {
    static func about(_ screen: Screen) -> QuickHelpItem {
        let detail: String
        switch screen {
        case .checking: detail = "The check book register, shared: everyone who writes checks on the account enters them here, kept in the security master. The bank's own lines (PNC downloads) are matched to the entries and mark them cleared; the ones left over are the bank's entries to accept."
        case .cards: detail = "Each credit card kept as a register in the security master: charges, credits, payments, fees and interest with the balance owed and the credit left, and its statements — balance, minimum due, due date, paid or not. The card company's downloads (Chase CSV / QFX, Discover and Capital One CSV) post to it, each line once; its payments link to the checking entries that paid them."
        case .expenseLedgers: detail = "Funded ledgers of purpose spending — equipment and software, a home office, subscriptions, training, travel — kept in the security master: each item on a budget line with its budget, the transfers that fund it and the balance not funded yet. Equipment is tracked as assets (depreciation, warranty), training as records (hours, certificates), trips against their per-diem allowances, and subscriptions by what they cost a year and when they renew. Entries can wait for approval."
        case .expenses: detail = "The target accounts your registers pay or are paid by — a utility, a card, a brokerage, a person — with the bank or company, the last four digits, a category, a note, a nickname, status, identifier, next payment, logon and address, and the registers that pay them (funding sources: checking account payments, credit card payments), which decide where each is offered as a target. The password and user keys stay in this Mac's Keychain. They are the registers' targets: not books MxAcctMGR keeps."
        case .secureAccounts: detail = "The products and services you hold an account with — software, data services, APIs — with the service's address and API, its status, your user name, and the subscription's last payment and renewal (auto-renew, renew by hand, or decline). The product key, service key and password stay in this Mac's Keychain (Keys lists which are stored); the service key is the API key MxJobsMGR's API subscriptions send for the account. Right-click a row to rename it or edit its details."
        case .welcome: detail = "What MxAcctMGR teaches, how the guide is laid out, and how Quick Help works. Everything runs on real data from the security master (accounts, securities, prices, benchmarks) and the analytics service (risk); the report walkthroughs are scenarios in the shape of real releases."
        case .choosePath: detail = "The questions that separate an actively managed portfolio from a passive index one, and a start button for My Portfolio. It doesn't choose for you."
        case .whyOptimize: detail = "Why a portfolio needs more than good picks: diversification, the risk–return trade-off, and what an optimizer does with forecasts, a risk model and limits. Two live demos."
        case .whyAttribution: detail = "Why results need explaining: was it being in the right sectors (allocation) or picking the right companies (selection)? A two-sector demo you can change."
        case .activeVsPassive: detail = "Costs, tracking error and the odds of beating an index: what you sign up for with each approach. A fee-compounding demo."
        case .myPortfolio: detail = "Investments, step 1: your own holdings in the security master (srm) — with shares, values and tax lots; add, edit and remove them, and fix the checks first. ⌘K links a holding's ticker or name to a page, with hover text of its own."
        case .myBenchmark: detail = "Investments, step 2: the benchmark that matches your plan — an index loaded in the security master (S&P 500, Dow, Nasdaq-100, or the VTI / BND 60/40 and 30/70 blends) — with sector and asset-mix comparisons, overlap, active share and its largest members."
        case .myRisk: detail = "Investments, step 3: how much your account can move, where its risk comes from, and how far it sits from your benchmark."
        case .myImprove: detail = "Investments, step 4: with an active approach, optimize within a risk budget (built-in or portfolio-java); with a passive approach, build the tracker with the fewest names or compare one index fund (built-in or portfolio-cpp)."
        case .myTrades: detail = "Investments, step 5: active — the trades, their cost and the taxes by lot; passive — the stock / bond / cash mix against its rebalance bands and the trades to return."
        case .myAttribution: detail = "Investments, step 6: last year's difference from your benchmark split into allocation, selection and interaction by sector, month by month."
        case .reportLibrary: detail = "The reports portfolio managers watch, in six tiers — market-moving economic reports, growth, corporate, positioning, fixed income and industry — with what each measures, why PMs care, the price drivers it moves, and the five with the greatest impact. Open any one's walkthrough, or its real report at the publisher (BLS, the Fed, BEA, ISM, Census…)."
        case .morningBriefing: detail = "A morning briefing: overnight markets, Treasury yields, the economic calendar, the economic surprise index, Fed funds futures, fund flows, credit spreads and the VIX as an illustrative morning; today's real earnings list; and what the account would be worth if it opened with the futures."
        case .earningsCalendar: detail = "Real earnings reports by month or week: for past days how many U.S.-listed companies beat or missed the consensus EPS, for upcoming days who reports and what analysts expect, with the companies you hold marked. Select a day for its full list. Nasdaq.com's calendar, with revenue from FMP through the accounts service."
        case .earningsDay: detail = "Every company reporting on a day — symbol, company, before the open or after the close, consensus and actual EPS with the surprise (Nasdaq.com), revenue estimate and actual (FMP) — sortable and filterable, with the selected company's history. ⌘K links a company's symbol or name to a page, with hover text of its own. Real data."
        case .vix: detail = "The Cboe Volatility Index, real data from Cboe: today's close, its regime and percentile since 1990, its history with calm-to-panic bands, the term structure (9-day to 6-month), and every spike above 35 with how long the VIX took to come back under 20."
        case .compute: detail = "AI compute as an asset theme, followed through the hyperscalers' capex (Microsoft, Alphabet, Amazon, Meta, Oracle): quarterly and combined, its growth, its share of their revenue and cash flow, and depreciation — beside their suppliers' revenue (Nvidia, Broadcom, AMD, Micron, Arista, Vertiv, Equinix) and how much of My Portfolio is in the theme. Reported figures from FMP through the accounts service."
        case .reportWalkthrough: detail = "A report walkthrough in seven steps: the report, how to read it, the market's move, what it did to the account, your reaction, its long-run consequences against the plan, and the takeaways. Choose another report with the Report menu at the top. Its first step links to the real report: the publisher's latest release, release schedule and history."
        case .securities: detail = "The security master's securities, as on MxDataHUB's Securities page: search by name or any identifier (ticker, ISIN, CUSIP, SEDOL, FIGI, CIK, LEI), filter by type, benchmark and activity or by any column's header, and see the selected one's prices, identifiers, issuer and security facts, listings, classification, benchmark membership and corporate actions. Through the accounts service."
        case .samples: detail = "Every sample account, the edge case it teaches and what to look for. Use one in the report walkthroughs and the Morning Briefing; copy one into My Portfolio to work through its steps."
        case .services: detail = "The shared Layer 3 services (MxAppsIOS/Services) — portfolio-java for active optimization, portfolio-cpp for tracking and risk, analytics for attribution — whether they run and how to start them."
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
        detail: "The accounts, securities and prices in MxAcctMGR are real, from the security master; the report walkthroughs are scenarios in the shape of real releases and the futures are simulations, to show how the tools work and what choices cost. Nothing here is a recommendation for your own accounts.",
        symbol: "graduationcap")

    static let samplePicker = QuickHelpItem(
        title: "Account",
        detail: "The account the report walkthroughs and the Morning Briefing work on (the Investments steps always use My Portfolio). Each sample is an edge case — concentrated, sector-heavy, income, cash-heavy, frequent trading, a drifted tracker, tax lots, a band breach, messy data — or My Portfolio, which you can edit.",
        symbol: "briefcase")

    static let engine = QuickHelpItem(
        title: "Engine",
        detail: "Built-in runs the optimizers inside MxAcctMGR. Layer 3 services sends the same inputs to portfolio-java (active, port 8766) and portfolio-cpp (tracking, port 8767), the engines MxJobsMGR and MxDataHUB use, so you can compare. Start them with python3 Services/mxservices.py start.",
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
