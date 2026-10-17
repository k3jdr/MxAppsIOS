//
//  Samples.swift
//  MxPortMGR
//
//  Sample accounts chosen for the edge cases a personal investor meets: a concentrated employer stock, a sector bet,
//  an income portfolio, idle cash, a frequent trader, a drifted index tracker, tax lots at gains and losses, a 60/40
//  that has drifted outside its rebalance band, missing data, and an ordinary core-and-satellite active account.
//  Every number is illustrative.
//

import Foundation

nonisolated enum Samples {
    /// (ticker, weight, lots as (acquired, share of the holding, cost as a fraction of today's value))
    typealias Row = (String, Double, [(String, Double, Double)])

    private static func make(_ id: String, _ name: String, _ account: AccountType, _ benchmark: String, _ style: PortfolioStyle,
                             value: Double, symbol: String, _ rows: [Row], lesson: String, lookFor: [String],
                             trading: String = "buyAndHold", missingFrom: [String: Int] = [:], unpriced: Set<String> = []) -> Portfolio {
        let total = rows.reduce(0) { $0 + $1.1 }
        let holdings = rows.map { row -> Holding in
            let v = (value * row.1 / total).rounded()
            let lots = row.2.map { TaxLot(acquired: $0.0, share: $0.1, costBasis: (v * $0.1 * $0.2).rounded()) }
            return Holding(ticker: row.0, value: v, lots: lots, unpriced: unpriced.contains(row.0))
        }
        return Portfolio(id: id, name: name, account: account, benchmark: benchmark, style: style, holdings: holdings,
                         lesson: lesson, lookFor: lookFor, trading: trading, missingFrom: missingFrom, symbol: symbol)
    }

    /// One long-held lot bought at the given fraction of today's value.
    private static func lot(_ date: String, _ cost: Double) -> [(String, Double, Double)] { [(date, 1, cost)] }

    static let all: [Portfolio] = [
        make("core-satellite", "Core & Satellite (active)", .retirement, "MXEQ", .active, value: 180_000, symbol: "circle.hexagongrid", [
            ("MXTM", 0.70, []), ("HLX", 0.05, []), ("QBT", 0.04, []), ("VTA", 0.04, []), ("PYM", 0.04, []),
            ("ATL", 0.03, []), ("SRC", 0.04, []), ("GNM", 0.03, []), ("CSH", 0.03, []),
        ], lesson: "An ordinary active account: an index fund as the core and eight companies you believe in as satellites. The optimizer turns those beliefs into position sizes within a risk budget.",
           lookFor: ["Tracking error: how far from the index the satellites take you.", "Information ratio: forecast reward per unit of active risk.", "Attribution: whether the satellites' sectors or the stock picks drove the result."]),

        make("employer-stock", "Concentrated Employer Stock", .taxable, "MXEQ", .either, value: 420_000, symbol: "building.2", [
            ("NWD", 0.48, [("2012-06-15", 0.55, 0.08), ("2017-03-01", 0.30, 0.35), ("2026-03-15", 0.15, 0.96)]),
            ("MXTM", 0.37, [("2019-01-10", 1, 0.55)]), ("AGB", 0.10, [("2021-08-02", 1, 1.08)]), ("CASH", 0.05, []),
        ], lesson: "Nearly half the account is the company you work for, bought over many years — most of it at a fraction of today's price. Your salary already depends on that company.",
           lookFor: ["Risk: how much of the account's volatility comes from one name.", "Trades & Taxes: the tax cost of diversifying (old lots carry large long-term gains; the newest lot is short-term).", "Earnings Report walkthrough: what one bad quarter does to this account."]),

        make("tech-heavy", "Sector-Heavy Technology", .taxable, "MXEQ", .active, value: 150_000, symbol: "cpu", [
            ("MXTK", 0.25, [("2020-02-03", 1, 0.40)]), ("NWD", 0.12, lot("2021-11-08", 0.62)), ("HLX", 0.12, lot("2019-05-20", 0.38)),
            ("QBT", 0.14, lot("2023-01-12", 0.30)), ("CLD", 0.08, lot("2024-06-03", 1.45)), ("STM", 0.07, lot("2022-09-14", 0.72)),
            ("SRC", 0.07, lot("2020-07-01", 0.50)), ("MXTM", 0.15, [("2018-04-02", 1, 0.48)]),
        ], lesson: "Over 60% in one sector through funds and single names — common after a long run for technology. The fund and the names overlap, so the true weight is only visible by look-through.",
           lookFor: ["Portfolio: the look-through sector weights against the benchmark.", "Optimize: how the sector band pulls technology back toward the index.", "Attribution: allocation (being in technology) vs selection (which tech names)."]),

        make("income", "Retiree Income (bond-heavy)", .retirement, "MX3070", .either, value: 900_000, symbol: "banknote", [
            ("AGB", 0.25, []), ("CRB", 0.14, []), ("MNB", 0.06, []), ("LTB", 0.10, []), ("IPB", 0.06, []), ("STB", 0.05, []),
            ("VLT", 0.04, []), ("GRD", 0.03, []), ("PLX", 0.04, []), ("GRN", 0.03, []), ("CNX", 0.04, []), ("NGS", 0.04, []),
            ("TWR", 0.03, []), ("HAB", 0.03, []), ("CASH", 0.06, []),
        ], lesson: "Income first: 66% bonds and dividend payers in utilities, staples, telecom, pipelines and REITs. These stocks behave a little like bonds — they fall when interest rates rise.",
           lookFor: ["Risk: interest-rate sensitivity shared by the bonds and the high-yield stocks.", "Yield Curve walkthrough: what rising long rates do to this account.", "Attribution against a 30/70 benchmark: the long-bond overweight."]),

        make("cash-heavy", "Cash-Heavy, Waiting to Invest", .taxable, "MX6040", .passive, value: 240_000, symbol: "dollarsign.circle", [
            ("CASH", 0.45, []), ("MXTM", 0.35, [("2016-09-12", 1, 0.45)]), ("MXBD", 0.20, [("2020-03-23", 1, 1.04)]),
        ], lesson: "Nearly half in cash, kept back after selling during a scary month and 'waiting for the dip'. Safe from a fall — but the plan says 60% stocks.",
           lookFor: ["Rebalance Bands: how far outside its band the stock weight is.", "Attribution: the cost of the cash in a rising year (allocation effect).", "Jobs Report walkthrough: the long-run cost of sitting out."]),

        make("trader", "High-Turnover Trader", .taxable, "MXEQ", .active, value: 85_000, symbol: "arrow.left.arrow.right", [
            ("ROV", 0.12, lot("2026-08-20", 1.10)), ("QBT", 0.12, lot("2026-09-02", 0.92)), ("GNM", 0.10, lot("2026-07-15", 1.18)),
            ("SOL", 0.10, lot("2026-09-28", 1.05)), ("CLD", 0.10, lot("2026-06-30", 0.88)), ("GMR", 0.08, lot("2026-09-10", 1.02)),
            ("ADV", 0.08, lot("2026-10-01", 1.04)), ("STM", 0.10, lot("2026-05-11", 0.80)), ("ORE", 0.08, lot("2026-08-04", 1.12)),
            ("CASH", 0.12, []),
        ], lesson: "Positions changed every few weeks, chasing what moved. Every lot is under a year old, so gains are taxed as short-term income, and every trade pays a spread.",
           lookFor: ["Trades & Taxes: short-term gains on almost every sale.", "Attribution: monthly weights change a lot, so selection swings month to month.", "The Behaviour Lab result for 'react to every headline'."],
           trading: "trader"),

        make("drifted-tracker", "Direct-Index Tracker, Drifted", .taxable, "MXEQ", .passive, value: 310_000, symbol: "scope", driftedTracker(),
             lesson: "A hand-built index: 22 of the 36 companies, bought at index weights two years ago and never rebalanced. Winners have grown, the left-out names are missing, and it now tracks the index loosely.",
             lookFor: ["Tracking Error & Drift: how tracking error grew month by month.", "Build the Tracker: how many names it really takes, and the one-fund alternative.", "Attribution: almost no allocation, small selection — what passive should look like."]),

        make("tax-lots", "Tax-Lot Harvesting Case", .taxable, "MX6040", .either, value: 520_000, symbol: "doc.text", [
            ("MXTM", 0.42, [("2013-02-11", 0.40, 0.30), ("2020-03-20", 0.25, 0.55), ("2026-01-15", 0.35, 1.12)]),
            ("STM", 0.08, [("2021-11-01", 0.6, 1.60), ("2024-02-01", 0.4, 0.70)]),
            ("CLD", 0.05, [("2022-01-04", 1, 1.85)]),
            ("PYM", 0.06, [("2015-07-01", 1, 0.25)]),
            ("MXBD", 0.25, [("2021-06-01", 0.7, 1.12), ("2025-12-01", 0.3, 1.01)]),
            ("LTB", 0.08, [("2020-07-15", 1, 1.55)]),
            ("CASH", 0.06, []),
        ], lesson: "The same security bought at different times and prices: some lots are large gains, some are losses. Which lot you sell — and whether you sell at a loss on purpose (tax-loss harvesting) — changes the tax bill for the same trade.",
           lookFor: ["Trades & Taxes: FIFO vs highest-cost-first lot choice.", "The long bond and cloud lots at a loss: harvesting them offsets gains elsewhere.", "Wash-sale caution: buying the same security back within 30 days disallows the loss."]),

        make("6040-drift", "60/40 Outside Its Band", .retirement, "MX6040", .passive, value: 640_000, symbol: "chart.pie", [
            ("MXTM", 0.71, []), ("MXBD", 0.26, []), ("CASH", 0.03, []),
        ], lesson: "Set up as 60% stocks, 40% bonds; after a strong run for stocks it is 71/29. Nothing is wrong with the funds — the mix has drifted, so the account now takes more risk than planned.",
           lookFor: ["Rebalance Bands: the stock weight is outside a ±5-point band.", "Risk: volatility and worst-case loss now vs at 60/40.", "In a retirement account rebalancing has no tax cost."]),

        make("missing-data", "Missing & Messy Data", .taxable, "MXEQ", .active, value: 95_000, symbol: "exclamationmark.triangle", [
            ("HLX", 0.14, lot("2019-03-01", 0.6)), ("OLDCO", 0.06, lot("2018-05-01", 2.5)), ("ROV", 0.08, lot("2022-02-01", 1.6)),
            ("TRX", 0.10, lot("2021-04-01", 0.9)), ("BRW", 0.10, lot("2020-06-01", 0.9)), ("GMR", 0.10, lot("2023-03-01", 0.8)),
            ("MXTM", 0.42, lot("2017-01-03", 0.5)),
        ], lesson: "Real account data is messy: a holding the security master doesn't know (OLDCO, merged away), a stale price on another, and months of missing returns. The tools should say what they could not see.",
           lookFor: ["Portfolio: the errors and warnings under the holdings.", "Optimize: the unknown holding is left out — the trade list doesn't touch it.", "Attribution: the data gap and the 'review' result."],
           missingFrom: ["GMR": 7], unpriced: ["ROV"]),
    ]

    /// 22 of the 36 companies at index weights, then two years of drift.
    private static func driftedTracker() -> [Row] {
        var rng = SeededRandom(seed: 22)
        let picks = Universe.equityIndexWeights.sorted { $0.value > $1.value }.enumerated()
            .filter { $0.offset < 14 || $0.offset % 2 == 0 }.prefix(22).map(\.element)
        return picks.map { (ticker, w) in
            let growth = exp(0.25 * rng.normal() + 0.10)
            return (ticker, w * growth, [("2024-10-15", 1, 1 / growth)])
        }
    }

    /// The user's own editable account, starting from a simple three-fund mix.
    static let myPortfolio = Portfolio(
        id: "mine", name: "My Portfolio", account: .taxable, benchmark: "MX6040", style: .either,
        holdings: [Holding(ticker: "MXTM", value: 60_000), Holding(ticker: "MXBD", value: 30_000), Holding(ticker: "CASH", value: 10_000)],
        lesson: "Your own mix, in the illustrative universe: add the funds and companies that resemble what you hold and see how the tools read it.",
        lookFor: ["Edit the holdings in Portfolio & Benchmark (or Portfolio & Index).", "Choose the benchmark that matches your plan."],
        symbol: "person.crop.circle")
}
