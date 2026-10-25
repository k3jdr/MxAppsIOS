//
//  Samples.swift
//  MxAcctMGR
//
//  The sample accounts' lessons. The accounts themselves live in the security master (srm.py load sample-portfolios
//  writes them: real securities, tax lots costed at the real closes on their purchase dates, cash, benchmark) and are
//  read through the accounts service like My Portfolio; this file keeps only what each one teaches, by its code.
//  Every number a screen shows is computed from the account and the market data, never written here.
//

import Foundation

nonisolated struct SampleLesson: Sendable {
    var code: String
    var symbol: String
    var style: PortfolioStyle
    /// How the holdings changed through the year: "buyAndHold", or "trader" (bought and sold every few weeks).
    var trading = "buyAndHold"
    var lesson: String
    var lookFor: [String]
}

nonisolated enum Samples {
    /// In the order the Sample Portfolios screen lists them.
    static let lessons: [SampleLesson] = [
        SampleLesson(code: "SAMPLE_CORE_SATELLITE", symbol: "circle.hexagongrid", style: .active,
                     lesson: "An ordinary active account: a total-market index fund as the core and eight S&P 500 companies you believe in as satellites. The optimizer turns those beliefs into position sizes within a risk budget.",
                     lookFor: ["Tracking error: how far from the index the satellites take you.", "Information ratio: forecast reward per unit of active risk.", "Attribution: whether the satellites' sectors or the stock picks drove the result."]),
        SampleLesson(code: "SAMPLE_EMPLOYER_STOCK", symbol: "building.2", style: .either,
                     lesson: "Nearly half the account is the company you work for, bought over many years — the oldest shares at a small fraction of today's price. Your salary already depends on that company.",
                     lookFor: ["Risk: how much of the account's volatility comes from one name.", "Trades & Taxes: the tax cost of diversifying (old lots carry large long-term gains; the newest lot is short-term).", "Earnings Report walkthrough: what one bad quarter does to this account."]),
        SampleLesson(code: "SAMPLE_TECH_HEAVY", symbol: "cpu", style: .active,
                     lesson: "Most of the account in one sector, through a technology fund and single names — common after a long run for technology. The fund and the names overlap.",
                     lookFor: ["Portfolio: the sector weights against the benchmark.", "Optimize: how the sector band pulls technology back toward the index.", "Attribution: allocation (being in technology) vs selection (which tech names)."]),
        SampleLesson(code: "SAMPLE_INCOME", symbol: "banknote", style: .either,
                     lesson: "Income first: mostly bond funds, plus dividend payers in utilities, staples, telecom, pipelines and REITs. These stocks behave a little like bonds — they fall when interest rates rise.",
                     lookFor: ["Risk: interest-rate sensitivity shared by the bonds and the high-yield stocks.", "Yield Curve walkthrough: what rising long rates do to this account.", "Attribution against a 30/70 benchmark: the long-bond overweight."]),
        SampleLesson(code: "SAMPLE_CASH_HEAVY", symbol: "dollarsign.circle", style: .passive,
                     lesson: "Nearly half in cash, kept back after selling during a scary month and 'waiting for the dip'. Safe from a fall — but the plan says 60% stocks.",
                     lookFor: ["Rebalance Bands: how far outside its band the stock weight is.", "Attribution: the cost of the cash in a rising year (allocation effect).", "Jobs Report walkthrough: the long-run cost of sitting out."]),
        SampleLesson(code: "SAMPLE_TRADER", symbol: "arrow.left.arrow.right", style: .active, trading: "trader",
                     lesson: "Positions changed every few weeks, chasing what moved. Every lot is under a year old, so gains are taxed as short-term income, and every trade pays a spread.",
                     lookFor: ["Trades & Taxes: short-term gains (and losses) on almost every sale.", "Attribution: selection swings month to month.", "The Behaviour Lab result for 'react to every headline'."]),
        SampleLesson(code: "SAMPLE_DRIFTED_TRACKER", symbol: "scope", style: .passive,
                     lesson: "A hand-built index: the S&P 500's largest names, bought at their index weights two years ago and never rebalanced. Winners have grown, the other 478 names are missing, and it now tracks the index loosely.",
                     lookFor: ["Tracking Error & Drift: how far the weights have moved from the index's.", "Build the Tracker: how many names it really takes, and the one-fund alternative.", "Attribution: almost no allocation, small selection — what passive should look like."]),
        SampleLesson(code: "SAMPLE_TAX_LOTS", symbol: "doc.text", style: .either,
                     lesson: "The same security bought at different times and prices: some lots are large gains, some are losses. Which lot you sell — and whether you sell at a loss on purpose (tax-loss harvesting) — changes the tax bill for the same trade.",
                     lookFor: ["Trades & Taxes: FIFO vs highest-cost-first lot choice.", "The bond fund lots at a loss: harvesting them offsets gains elsewhere.", "Wash-sale caution: buying the same security back within 30 days disallows the loss."]),
        SampleLesson(code: "SAMPLE_6040_DRIFT", symbol: "chart.pie", style: .passive,
                     lesson: "Set up as 60% stocks, 40% bonds; after a strong run for stocks the mix has drifted well past 60/40. Nothing is wrong with the funds — the account now takes more risk than planned.",
                     lookFor: ["Rebalance Bands: the stock weight is outside a ±5-point band.", "Risk: volatility now vs at 60/40.", "In a retirement account rebalancing has no tax cost."]),
        SampleLesson(code: "SAMPLE_MISSING_DATA", symbol: "exclamationmark.triangle", style: .active,
                     lesson: "Real account data is messy: a security that was delisted and never priced in the security master, a unit with no trades for weeks, and a newer listing with a short price history. The tools should say what they could not see.",
                     lookFor: ["Portfolio: the errors and warnings under the holdings.", "Optimize: the unpriced holding is left out — the trade list doesn't touch it.", "Attribution: the data gap and the 'review' result."]),
    ]

    static func lesson(_ code: String) -> SampleLesson? { lessons.first { $0.code == code } }

    /// A sample's name before its account is read: SAMPLE_TAX_LOTS → "Tax Lots".
    static func placeholderName(_ code: String) -> String {
        code.replacingOccurrences(of: "SAMPLE_", with: "").replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// My Portfolio before its account is read from the security master.
    static let myPortfolio = Portfolio(
        id: "mine", name: "My Portfolio", account: .taxable, benchmark: "SP500", style: .either, holdings: [],
        lesson: "Your own account in the security master: real securities and prices, tax lots, and risk from the analytics service.",
        lookFor: ["Add the securities you hold (My Holdings ▸ Add Securities…).", "Choose the benchmark that matches your plan."],
        symbol: "person.crop.circle", source: "srm", srmCode: "MY_PORTFOLIO")

    /// A sample account as the app's Portfolio, from its security-master account.
    static func portfolio(_ a: SRMAccount, lesson l: SampleLesson?) -> Portfolio {
        Portfolio(id: a.code, name: a.name,
                  account: a.accountType == "retirement" ? .retirement : a.accountType == "roth" ? .roth : .taxable,
                  benchmark: a.benchmark ?? "SP500", style: l?.style ?? .either, holdings: [],
                  lesson: l?.lesson ?? "", lookFor: l?.lookFor ?? [], trading: l?.trading ?? "buyAndHold",
                  symbol: l?.symbol ?? "briefcase", source: "srm", srmCode: a.code)
    }
}
