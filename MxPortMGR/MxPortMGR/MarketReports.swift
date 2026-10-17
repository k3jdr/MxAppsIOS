//
//  MarketReports.swift
//  MxPortMGR
//
//  Three walkthroughs of the reports that move markets day to day — the monthly jobs report, a company's earnings
//  report, and a yield-curve / bond-market report. Each is an illustrative report (made-up numbers in the shape of
//  real ones), a guide to reading it, the day's market move it caused, what that move does to the selected account,
//  the reactions people commonly have, and the takeaways. The move is expressed in the factor model (market, rates,
//  sectors, one company), so it lands on any sample account through its own holdings.
//

import Foundation

nonisolated struct ReportLine: Hashable, Sendable, Identifiable {
    var id: String { label }
    var label: String
    var value: String
    var expected: String
    var meaning: String
}

nonisolated struct ReportTerm: Hashable, Sendable, Identifiable {
    var id: String { term }
    var term: String
    var definition: String
}

nonisolated struct MarketMove: Hashable, Sendable, Identifiable {
    var id: String { asset }
    var asset: String
    var move: String
    var why: String
}

/// What a report tells the market about: the four primary determinants of asset prices, plus positioning.
nonisolated enum Driver: String, CaseIterable, Hashable, Sendable {
    case growth = "Growth", inflation = "Inflation", rates = "Interest rates", profits = "Corporate profits", sentiment = "Sentiment & positioning"
    var symbol: String {
        switch self {
        case .growth: "chart.line.uptrend.xyaxis"
        case .inflation: "flame"
        case .rates: "percent"
        case .profits: "dollarsign.circle"
        case .sentiment: "person.3.sequence"
        }
    }
}

nonisolated struct ReportPoint: Hashable, Sendable, Identifiable {
    var id: String { label }
    var label: String
    var value: Double
}

/// A small history that puts the report in context (core CPI by month, ISM with its 50 line, weekly flows…).
nonisolated struct ReportSeries: Hashable, Sendable {
    enum Kind: Hashable, Sendable { case line, bar }
    var title: String
    var unit: String
    var kind: Kind = .line
    var points: [ReportPoint]
    var reference: Double? = nil
    var referenceLabel: String = ""
    var note: String = ""

    init(_ title: String, unit: String, kind: Kind = .line, _ values: [(String, Double)], reference: Double? = nil, referenceLabel: String = "", note: String = "") {
        self.title = title
        self.unit = unit
        self.kind = kind
        points = values.map { ReportPoint(label: $0.0, value: $0.1) }
        self.reference = reference
        self.referenceLabel = referenceLabel
        self.note = note
    }
}

nonisolated struct ReportTier: Identifiable, Hashable, Sendable {
    var id: Int
    var title: String
    var summary: String

    static let all: [ReportTier] = [
        ReportTier(id: 1, title: "Tier 1 · Market-Moving Economic Reports", summary: "Released on a fixed schedule and priced within seconds: jobs, inflation and the Federal Reserve set expectations for growth, inflation and interest rates."),
        ReportTier(id: 2, title: "Tier 2 · Economic Growth Reports", summary: "Whether the economy is accelerating or slowing: output, purchasing managers' surveys and consumer spending."),
        ReportTier(id: 3, title: "Tier 3 · Corporate Reports", summary: "Stock prices ultimately follow earnings: results, guidance, and how analysts revise their estimates."),
        ReportTier(id: 4, title: "Tier 4 · Market Positioning Reports", summary: "Who owns what and where money is moving: crowded trades and investor sentiment."),
        ReportTier(id: 5, title: "Tier 5 · Fixed Income Reports", summary: "Demand for government debt and the shape of the yield curve: the price of money across maturities."),
        ReportTier(id: 6, title: "Tier 6 · Industry Reports", summary: "Sector-specific data that specialists follow: semiconductors, banks, housing, energy."),
    ]
}

nonisolated struct MarketReport: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var symbol: String
    var source: String
    var headline: String
    var lines: [ReportLine]
    var reading: [String]
    var terms: [ReportTerm]
    var moves: [MarketMove]
    /// The day's move in the factor model.
    var marketMove: Double
    var rateMove: Double
    var sectorMoves: [String: Double] = [:]
    var companyMoves: [String: Double] = [:]
    /// The company whose report it is: held directly it becomes the single-stock sleeve in the lab.
    var single: String? = nil
    var reactions: [Reaction]
    var takeaways: [String]
    var suggestedSample: String
    var tier: Int = 1
    var publisher: String = ""
    var frequency: String = ""
    var keyMetrics: [String] = []
    var whyCare: [String] = []
    var drivers: [Driver] = []
    /// How much it typically moves markets on the day: 1 low, 2 medium, 3 high.
    var impact: Int = 2
    /// Its rank among the five reports with the greatest impact on a diversified U.S. equity portfolio.
    var topFive: Int? = nil
    var context: ReportSeries? = nil
    /// The industry, for Tier 6.
    var industry: String? = nil

    static let steps = ["The Report", "Reading It", "The Market's Move", "Your Account", "Your Reaction", "The Long Run", "Takeaways"]

    /// The day's return of a security under this report.
    func shock(_ s: Security) -> Double {
        MarketReport.move(s, market: marketMove, rate: rateMove, sectors: sectorMoves, companies: companyMoves)
    }

    /// A security's return for a market move, a change in yields, sector and company moves (funds by look-through).
    static func move(_ s: Security, market: Double, rate: Double, sectors: [String: Double] = [:], companies: [String: Double] = [:]) -> Double {
        if let parts = s.lookThrough {
            return parts.reduce(0) { $0 + $1.value * (Universe.security($1.key).map { move($0, market: market, rate: rate, sectors: sectors, companies: companies) } ?? 0) }
        }
        if let c = companies[s.ticker] { return c }
        switch s.assetClass {
        case .cash: return 0
        case .bond: return s.rateBeta * rate + s.beta * market
        case .equity: return s.beta * market + s.rateBeta * rate * 0.5 + (sectors[s.sector] ?? 0)
        }
    }

    /// The account's change in dollars for such a move.
    static func accountMove(_ p: Portfolio, market: Double, rate: Double, sectors: [String: Double] = [:], companies: [String: Double] = [:]) -> Double {
        p.holdings.reduce(0) { acc, h in acc + h.value * (h.security.map { move($0, market: market, rate: rate, sectors: sectors, companies: companies) } ?? 0) }
    }

    /// Today's move of each sleeve of the account (the lab's starting shock).
    func sleeveShock(_ p: Portfolio) -> [Double] {
        var move = [Double](repeating: 0, count: 4), weight = move
        for h in p.holdings {
            guard let s = h.security else { continue }
            let w = p.weight(h)
            if let single, s.ticker == single {
                move[Sleeve.single.rawValue] += w * shock(s); weight[Sleeve.single.rawValue] += w
                continue
            }
            let classes = s.lookThrough.map { parts -> [(Sleeve, Double, Double)] in
                var byClass: [AssetClass: (Double, Double)] = [:]
                for (k, x) in parts { if let u = Universe.security(k) { byClass[u.assetClass, default: (0, 0)].0 += x; byClass[u.assetClass, default: (0, 0)].1 += x * shock(u) } }
                return byClass.map { c, v in (c == .equity ? .stocks : c == .bond ? .bonds : .cash, v.0, v.0 > 0 ? v.1 / v.0 : 0) }
            } ?? [(s.assetClass == .equity ? .stocks : s.assetClass == .bond ? .bonds : .cash, 1, shock(s))]
            for (sleeve, x, r) in classes {
                move[sleeve.rawValue] += w * x * r
                weight[sleeve.rawValue] += w * x
            }
        }
        return move.indices.map { weight[$0] > 0 ? move[$0] / weight[$0] : 0 }
    }

    // MARK: The reports

    static let jobs = MarketReport(
        id: "jobs", title: "Jobs Report", symbol: "person.3",
        source: "Employment Situation — illustrative, in the shape of the monthly U.S. report (first Friday of the month, 8:30 a.m. ET)",
        headline: "Hiring slows sharply: 48,000 jobs added vs 150,000 expected; unemployment rises to 4.6%",
        lines: [
            ReportLine(label: "Nonfarm payrolls", value: "+48,000", expected: "+150,000", meaning: "Jobs added last month across the economy outside farming. The headline number; a big miss suggests the economy is slowing."),
            ReportLine(label: "Unemployment rate", value: "4.6%", expected: "4.3%", meaning: "Share of people looking for work who can't find it. Comes from a separate household survey, so it can disagree with payrolls."),
            ReportLine(label: "Revisions (prior 2 months)", value: "−62,000", expected: "—", meaning: "Earlier months are re-estimated as more data arrives. Large downward revisions mean the slowdown started earlier than thought."),
            ReportLine(label: "Average hourly earnings", value: "+0.2% m/m · +3.4% y/y", expected: "+0.3% · +3.6%", meaning: "Wage growth. Slower wages mean less inflation pressure — which makes interest-rate cuts more likely."),
            ReportLine(label: "Participation rate", value: "62.4%", expected: "62.5%", meaning: "Share of adults working or looking. Changes slowly; demographics (retirement) matter more than the month's news."),
            ReportLine(label: "Average weekly hours", value: "34.2", expected: "34.3", meaning: "Employers cut hours before they cut jobs, so falling hours can lead a slowdown."),
        ],
        reading: [
            "Start with the surprise, not the level: markets have already priced in the forecast (+150,000). What moves prices is the difference — here −102,000.",
            "Check the revisions: a weak month after strong ones may be noise; a weak month plus downward revisions is a trend.",
            "Read the two surveys together: payrolls (businesses) and unemployment (households) usually agree over several months, not always in one.",
            "Ask what it means for interest rates: weak jobs and slower wages make central-bank rate cuts more likely — good for bonds, mixed for stocks (slower growth but cheaper money).",
            "One report is one data point in a noisy series with a typical sampling error of around ±100,000 jobs. Economists look at three-month averages.",
        ],
        terms: [
            ReportTerm(term: "Consensus", definition: "The average forecast of economists surveyed before the release; the market's expectation."),
            ReportTerm(term: "Sampling error", definition: "The report is a survey estimate; a month's change of under about 100,000 is not statistically different from zero."),
            ReportTerm(term: "Soft landing", definition: "Inflation falls back without a recession — the hoped-for outcome of a slowdown."),
            ReportTerm(term: "Rate-cut expectations", definition: "Futures markets price how likely the central bank is to cut rates; weak jobs data raises those odds and lowers short-term yields."),
        ],
        moves: [
            MarketMove(asset: "Stocks (MX Equity Market 36)", move: "−2.4%", why: "Slower growth means lower expected profits; fear of recession."),
            MarketMove(asset: "Smaller and cyclical companies", move: "−3.5%", why: "Most sensitive to the economy (consumer discretionary, industrials, materials)."),
            MarketMove(asset: "2-year Treasury yield", move: "−0.22 points", why: "Traders expect the central bank to cut rates sooner."),
            MarketMove(asset: "Aggregate bond fund", move: "+0.8%", why: "Bond prices rise when yields fall."),
            MarketMove(asset: "Utilities, staples, health care", move: "−0.5% to −1%", why: "Defensive: people buy groceries and power in any economy."),
        ],
        marketMove: -0.022, rateMove: -0.0013,
        sectorMoves: ["Consumer Discretionary": -0.010, "Industrials": -0.008, "Materials": -0.008, "Financials": -0.006, "Utilities": 0.012, "Consumer Staples": 0.010, "Health Care": 0.008],
        reactions: [
            Reaction(id: "sell-all", title: "Sell all stocks, buy back later", symbol: "arrow.down.to.line",
                     summary: "Move every stock to cash today and buy back after the months you set below, when things feel calmer.",
                     moves: [Move(from: .stocks, to: .cash, fraction: 1), Move(from: .single, to: .cash, fraction: 1)], after: .revert),
            Reaction(id: "sell-half", title: "Sell half until it calms down", symbol: "circle.lefthalf.filled",
                     summary: "Halve the stocks today and return to the plan after the months set below.",
                     moves: [Move(from: .stocks, to: .cash, fraction: 0.5), Move(from: .single, to: .cash, fraction: 0.5)], after: .revert),
            Reaction(id: "rotate-bonds", title: "Rotate into bonds for good", symbol: "arrow.triangle.swap",
                     summary: "Move half the stocks into bonds and keep the new, safer mix as the plan.",
                     moves: [Move(from: .stocks, to: .bonds, fraction: 0.5), Move(from: .single, to: .bonds, fraction: 0.5)], after: .permanent),
            Reaction(id: "buy-dip", title: "Buy the dip", symbol: "cart.badge.plus",
                     summary: "Put the cash and a fifth of the bonds into stocks today; the yearly rebalance takes the account back to the plan.",
                     moves: [Move(from: .cash, to: .stocks, fraction: 1), Move(from: .bonds, to: .stocks, fraction: 0.2)], after: .rebalanceToPlan),
            Reaction(id: "every-time", title: "React to every scary headline", symbol: "exclamationmark.bubble",
                     summary: "Sell all stocks today and every time they later fall 15% from a high; buy back each time after the months set below.",
                     moves: [Move(from: .stocks, to: .cash, fraction: 1), Move(from: .single, to: .cash, fraction: 1)], after: .revert, repeatOnDrawdown: 0.15),
        ],
        takeaways: [
            "A jobs report changes expectations for interest rates and growth for weeks; your plan was built for decades of such reports.",
            "The market reacts within seconds of 8:30 a.m. — by the time you read the headline, the news is in the price.",
            "Selling after a fall locks in the loss, and the best days often come within weeks of the worst: being out for them is what does the long-term damage.",
            "If a weak report makes you want to sell, the plan may hold more risk than you are comfortable with. The fix is a calmer plan, chosen on a calm day — not a trade on a scary one.",
        ],
        suggestedSample: "cash-heavy",
        tier: 1, publisher: "U.S. Bureau of Labor Statistics (BLS)", frequency: "Monthly, first Friday, 8:30 a.m. ET",
        keyMetrics: ["Nonfarm payroll growth", "Unemployment rate", "Average hourly earnings", "Labor force participation rate"],
        whyCare: ["Strong jobs numbers can signal economic strength — but also inflation pressure.", "Weak numbers raise expectations of Federal Reserve rate cuts."],
        drivers: [.growth, .inflation, .rates], impact: 3, topFive: 2,
        context: ReportSeries("Payrolls, monthly change", unit: "thousand jobs", kind: .bar,
                              [("Nov", 212), ("Dec", 186), ("Jan", 175), ("Feb", 151), ("Mar", 168), ("Apr", 142), ("May", 128), ("Jun", 110), ("Jul", 96), ("Aug", 74), ("Sep", 61), ("Oct", 48)],
                              note: "Illustrative: hiring has slowed for months — one weak report continues a trend rather than starting one."))

    static let earnings = MarketReport(
        id: "earnings", title: "Earnings Report", symbol: "chart.bar.doc.horizontal",
        source: "Quarterly results of Northwind Devices (NWD) — a fictional company; illustrative numbers in the shape of a real earnings release",
        headline: "Northwind Devices misses on revenue and cuts guidance; shares fall 18% after hours",
        lines: [
            ReportLine(label: "Revenue", value: "$41.2bn", expected: "$43.0bn", meaning: "Total sales. A 4% miss: demand for its main device line was weaker than analysts forecast."),
            ReportLine(label: "Earnings per share (EPS)", value: "$1.42", expected: "$1.61", meaning: "Profit per share. The number most headlines lead with; compare it with the consensus, not with last quarter."),
            ReportLine(label: "Gross margin", value: "41.0%", expected: "44.0%", meaning: "Share of revenue left after the cost of making the products. Falling margins mean price cuts or higher costs."),
            ReportLine(label: "Next-quarter guidance", value: "$39–41bn", expected: "$44.5bn", meaning: "Management's own forecast. Often moves the stock more than the quarter just reported, because prices look forward."),
            ReportLine(label: "Share buyback", value: "$10bn authorised", expected: "—", meaning: "The company will buy back its own shares, returning cash to shareholders."),
            ReportLine(label: "Free cash flow", value: "$9.8bn", expected: "$10.5bn", meaning: "Cash left after investment; harder to flatter with accounting choices than earnings."),
        ],
        reading: [
            "Compare with expectations: a 'record quarter' can still be a miss, and a loss can be a beat. The surprise moves the price.",
            "Guidance often matters most: here the forecast for next quarter is 10% below what analysts expected.",
            "Listen to the call: management's explanation (a product cycle? lost customers? a one-off?) decides whether the miss is temporary.",
            "Think about the business, not the share price: a good company can have a bad quarter; is the long-term story broken?",
            "Check your exposure: if you hold an index fund you already own some — here NWD is about 13% of the MX Equity Market 36.",
        ],
        terms: [
            ReportTerm(term: "Beat / miss", definition: "Results above / below the consensus estimate of analysts."),
            ReportTerm(term: "Guidance", definition: "The company's own forecast for the next quarter or year."),
            ReportTerm(term: "After-hours trading", definition: "Most companies report after the close; the first price reaction happens in thin after-hours trading and can overshoot."),
            ReportTerm(term: "Idiosyncratic risk", definition: "Risk specific to one company. Diversification removes most of it; a concentrated holding keeps all of it."),
        ],
        moves: [
            MarketMove(asset: "Northwind Devices (NWD)", move: "−18%", why: "Lower expected profits for several quarters; the price resets to the new outlook."),
            MarketMove(asset: "Technology suppliers and peers", move: "−3% to −5%", why: "Weak device demand may mean weak orders for suppliers."),
            MarketMove(asset: "Stocks (MX Equity Market 36)", move: "−2.6%", why: "NWD is about 13% of the index; the rest of the market is down only 0.4%."),
            MarketMove(asset: "Bonds", move: "≈ 0%", why: "One company's news rarely moves interest rates."),
        ],
        marketMove: -0.004, rateMove: 0,
        sectorMoves: ["Technology": -0.035],
        companyMoves: ["NWD": -0.18],
        single: "NWD",
        reactions: [
            Reaction(id: "sell-single", title: "Sell the company, buy the index", symbol: "arrow.triangle.branch",
                     summary: "Sell all NWD today and put the money in the broad stock index — a lasting change to a diversified plan.",
                     moves: [Move(from: .single, to: .stocks, fraction: 1)], after: .permanent),
            Reaction(id: "sell-wait", title: "Sell the company, wait in cash, buy it back", symbol: "hourglass",
                     summary: "Sell NWD to cash today and buy it back after the months set below, 'once it has bottomed'.",
                     moves: [Move(from: .single, to: .cash, fraction: 1)], after: .revert),
            Reaction(id: "double-down", title: "Double down", symbol: "plus.circle",
                     summary: "Buy more NWD with all the cash and a fifth of the other stocks: 'it's on sale'. The new mix becomes the plan.",
                     moves: [Move(from: .cash, to: .single, fraction: 1), Move(from: .stocks, to: .single, fraction: 0.2)], after: .permanent),
            Reaction(id: "sell-everything", title: "Sell all stocks", symbol: "arrow.down.to.line",
                     summary: "Stocks feel too risky: sell every stock and buy back after the months set below.",
                     moves: [Move(from: .single, to: .cash, fraction: 1), Move(from: .stocks, to: .cash, fraction: 1)], after: .revert),
        ],
        takeaways: [
            "One company's report is a reason to review a concentrated position, not the whole plan.",
            "Selling a concentrated stock to diversify can lower risk for good — it's a plan change, best done on a schedule (and, in a taxable account, with the tax cost in view), not in the hour after a miss.",
            "Selling to wait for the bottom and buying back later is market timing: the rebound often comes on news you can't predict.",
            "Doubling down raises the stakes on the one risk diversification would remove. Compare the 10th-percentile outcomes, not just the medians.",
        ],
        suggestedSample: "employer-stock",
        tier: 3, publisher: "The company (press release, 10-Q filing, conference call)", frequency: "Quarterly, mostly in the four 'earnings seasons'",
        keyMetrics: ["Revenue", "Earnings per share (EPS)", "Margins", "Guidance"],
        whyCare: ["Ultimately stock prices follow earnings.", "Guidance often matters more than the current quarter's results."],
        drivers: [.profits], impact: 3, topFive: 4,
        context: ReportSeries("NWD earnings per share: reported vs expected", unit: "$", kind: .bar,
                              [("Q4 ’25", 1.58), ("Q1 ’26", 1.49), ("Q2 ’26", 1.55), ("Q3 ’26", 1.42)], reference: 1.61, referenceLabel: "expected this quarter",
                              note: "Illustrative: the first miss after three quarters of meeting expectations."))

    static let yieldCurve = MarketReport(
        id: "yield-curve", title: "Yield Curve Report", symbol: "chart.line.uptrend.xyaxis",
        source: "Treasury market wrap — illustrative, in the shape of a weekly bond-market report",
        headline: "Long-term yields jump: 10-year at 4.55% (+0.28), 30-year at 4.95%; the curve steepens as deficit and inflation worries mount",
        lines: [
            ReportLine(label: "3-month bill", value: "4.20%", expected: "4.20%", meaning: "Tracks the central bank's policy rate; barely moved."),
            ReportLine(label: "2-year note", value: "4.10% (−0.05)", expected: "4.15%", meaning: "Reflects where rates are expected to be over the next two years."),
            ReportLine(label: "10-year note", value: "4.55% (+0.28)", expected: "4.27%", meaning: "The benchmark long rate: drives mortgage rates and the value of long-lived assets."),
            ReportLine(label: "30-year bond", value: "4.95% (+0.30)", expected: "4.65%", meaning: "Most sensitive to long-run inflation and government borrowing."),
            ReportLine(label: "10-year minus 2-year", value: "+0.45 points", expected: "+0.12", meaning: "The slope of the curve. Negative (inverted) has often preceded recessions; it turned positive again recently."),
            ReportLine(label: "10-year inflation breakeven", value: "2.55%", expected: "2.40%", meaning: "The inflation rate the bond market expects; rising breakevens push yields up."),
        ],
        reading: [
            "Yields and prices move in opposite directions: a bond fund with a duration of 6 loses about 6% when its yields rise 1 point — here about 1.7%.",
            "Look at the shape: short yields fell slightly while long yields jumped (a 'bear steepener'), so long bonds lost most.",
            "Inversion is a warning, not a timer: the curve inverted for about two years in 2022–24, and stocks rose through much of it. Recessions that followed inversions came 6 to 24 months later — or not at all.",
            "Higher yields are also good news for the future: new bonds and cash now pay more, so a bond investor who holds on earns the higher yield from here.",
            "Stocks that behave like bonds — utilities, real estate, high-dividend payers — tend to fall with long bonds.",
        ],
        terms: [
            ReportTerm(term: "Yield curve", definition: "Yields of government bonds plotted by maturity, from 3 months to 30 years."),
            ReportTerm(term: "Duration", definition: "Roughly how much a bond's price falls (in %) when its yield rises 1 point."),
            ReportTerm(term: "Inversion", definition: "Short yields above long yields; markets expect rates to fall, often because they expect a slowdown."),
            ReportTerm(term: "Term premium", definition: "The extra yield investors demand to lock money up for longer; it rises with uncertainty about inflation and deficits."),
        ],
        moves: [
            MarketMove(asset: "Long Treasury fund (20+ yr)", move: "−4.6%", why: "Duration about 16.5 × a 0.28-point rise."),
            MarketMove(asset: "Aggregate bond fund", move: "−1.7%", why: "Duration about 6."),
            MarketMove(asset: "Short Treasury fund (1–3 yr)", move: "−0.5%", why: "Short duration: barely affected, and now yields more."),
            MarketMove(asset: "Real estate and utilities", move: "−3%", why: "Their dividends compete with higher bond yields; they borrow a lot."),
            MarketMove(asset: "Stocks (MX Equity Market 36)", move: "−1.5%", why: "Future profits are worth less when discounted at higher rates."),
        ],
        marketMove: -0.012, rateMove: 0.0028,
        sectorMoves: ["Real Estate": -0.018, "Utilities": -0.015, "Financials": 0.008],
        reactions: [
            Reaction(id: "sell-bonds", title: "Sell the bonds, sit in cash", symbol: "arrow.down.to.line",
                     summary: "Bonds 'don't work any more': sell them all to cash and return to the plan after the months set below.",
                     moves: [Move(from: .bonds, to: .cash, fraction: 1)], after: .revert),
            Reaction(id: "sell-stocks-recession", title: "Sell stocks before the recession", symbol: "cloud.bolt.rain",
                     summary: "The curve is a recession signal: sell all stocks and buy back after the months set below.",
                     moves: [Move(from: .stocks, to: .cash, fraction: 1), Move(from: .single, to: .cash, fraction: 1)], after: .revert),
            Reaction(id: "chase-yield", title: "Chase the higher yields", symbol: "arrow.up.right",
                     summary: "Long bonds now yield almost 5%: move a third of the stocks into bonds for good.",
                     moves: [Move(from: .stocks, to: .bonds, fraction: 0.33)], after: .permanent),
            Reaction(id: "every-time", title: "React to every scary headline", symbol: "exclamationmark.bubble",
                     summary: "Sell all stocks today and every time they later fall 15% from a high; buy back after the months set below.",
                     moves: [Move(from: .stocks, to: .cash, fraction: 1), Move(from: .single, to: .cash, fraction: 1)], after: .revert, repeatOnDrawdown: 0.15),
        ],
        takeaways: [
            "A bond fund's loss when rates rise is the other side of its higher yield from now on: over a period longer than its duration, the higher yield usually makes up the loss.",
            "Match bonds to when you'll need the money: short bonds for money needed soon, longer bonds only for long horizons.",
            "The yield curve has a poor record as a timing tool: acting on it means guessing both whether and when a recession comes — and how markets will have moved by then.",
            "Owning both stocks and bonds is a plan for many kinds of years, including the rare ones when both fall together.",
        ],
        suggestedSample: "income",
        tier: 5, publisher: "U.S. Treasury market (daily yields from the Treasury Department)", frequency: "Continuous; most watched spreads: 2Y–10Y and 3M–10Y",
        keyMetrics: ["2-year, 10-year and 30-year yields", "2Y–10Y spread", "3M–10Y spread", "Inflation breakevens"],
        whyCare: ["An inverted curve has preceded many recessions.", "The slope influences sector allocation: banks, utilities, real estate and long-duration growth stocks all depend on it."],
        drivers: [.rates, .growth, .inflation], impact: 2,
        context: ReportSeries("10-year minus 2-year spread", unit: "points",
                              [("2022", 0.20), ("’22 H2", -0.55), ("2023", -0.80), ("’23 H2", -0.35), ("2024", -0.40), ("’24 H2", 0.10), ("2025", 0.25), ("’25 H2", 0.15), ("2026", 0.12), ("Now", 0.45)],
                              reference: 0, referenceLabel: "inverted below 0",
                              note: "Shaped like the real curve: inverted from mid-2022 to late 2024, positive since. Stocks rose through much of the inversion."))

    /// Every walkthrough, in tier order.
    static let all: [MarketReport] = [jobs, cpi, ppi, fomc, gdp, ismManufacturing, ismServices, retailSales,
                                      earnings, revisions, cot, fundFlows, auctions, yieldCurve,
                                      semiconductors, banks, housing, energy]
    static func report(_ id: String) -> MarketReport { all.first { $0.id == id } ?? jobs }
    static var topFive: [MarketReport] { all.filter { $0.topFive != nil }.sorted { $0.topFive! < $1.topFive! } }

    /// Yields by maturity (years) before and after the yield-curve report, for its chart.
    static let curveBefore: [(Double, Double)] = [(0.25, 4.20), (2, 4.15), (5, 4.12), (10, 4.27), (30, 4.65)]
    static let curveAfter: [(Double, Double)] = [(0.25, 4.20), (2, 4.10), (5, 4.28), (10, 4.55), (30, 4.95)]
    static let curveInverted: [(Double, Double)] = [(0.25, 5.45), (2, 4.95), (5, 4.35), (10, 4.10), (30, 4.25)]
}
