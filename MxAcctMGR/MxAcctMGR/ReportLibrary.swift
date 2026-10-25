//
//  ReportLibrary.swift
//  MxAcctMGR
//
//  The rest of the reports portfolio managers watch, by tier (MarketReports.swift has the jobs, earnings and
//  yield-curve walkthroughs): CPI, PPI and the FOMC (Tier 1); GDP, the two ISM surveys and retail sales (Tier 2);
//  earnings revisions (Tier 3); CFTC Commitments of Traders and fund flows (Tier 4); Treasury auctions (Tier 5); and
//  semiconductor sales, bank earnings and credit, housing and the EIA petroleum report (Tier 6). Every report is
//  illustrative — made-up numbers in the shape of the real release — and lands on the account through each holding's
//  market and rate betas (MarketReport.move). Where a report is about one company it is the account's own stock in
//  the report's sector (MarketReport.resolved), and the text says its numbers are invented.
//

import Foundation

/// The reactions people commonly have, reused across reports.
nonisolated enum Reactions {
    static let sellAll = Reaction(id: "sell-all", title: "Sell all stocks, buy back later", symbol: "arrow.down.to.line",
                                  summary: "Move every stock to cash today and buy back after the months you set below, when things feel calmer.",
                                  moves: [Move(from: .stocks, to: .cash, fraction: 1), Move(from: .single, to: .cash, fraction: 1)], after: .revert)
    static let sellHalf = Reaction(id: "sell-half", title: "Sell half until it calms down", symbol: "circle.lefthalf.filled",
                                   summary: "Halve the stocks today and return to the plan after the months set below.",
                                   moves: [Move(from: .stocks, to: .cash, fraction: 0.5), Move(from: .single, to: .cash, fraction: 0.5)], after: .revert)
    static let rotateBonds = Reaction(id: "rotate-bonds", title: "Rotate into bonds for good", symbol: "arrow.triangle.swap",
                                      summary: "Move half the stocks into bonds and keep the new, safer mix as the plan.",
                                      moves: [Move(from: .stocks, to: .bonds, fraction: 0.5), Move(from: .single, to: .bonds, fraction: 0.5)], after: .permanent)
    static let buyDip = Reaction(id: "buy-dip", title: "Buy the dip", symbol: "cart.badge.plus",
                                 summary: "Put the cash and a fifth of the bonds into stocks today; the yearly rebalance takes the account back to the plan.",
                                 moves: [Move(from: .cash, to: .stocks, fraction: 1), Move(from: .bonds, to: .stocks, fraction: 0.2)], after: .rebalanceToPlan)
    static let everyTime = Reaction(id: "every-time", title: "React to every scary headline", symbol: "exclamationmark.bubble",
                                    summary: "Sell all stocks today and every time they later fall 15% from a high; buy back each time after the months set below.",
                                    moves: [Move(from: .stocks, to: .cash, fraction: 1), Move(from: .single, to: .cash, fraction: 1)], after: .revert, repeatOnDrawdown: 0.15)
    static let goAllIn = Reaction(id: "all-in", title: "Go all in on the good news", symbol: "bolt.fill",
                                  summary: "Move all the cash and half the bonds into stocks and keep the bolder mix as the plan.",
                                  moves: [Move(from: .cash, to: .stocks, fraction: 1), Move(from: .bonds, to: .stocks, fraction: 0.5)], after: .permanent)
    static let takeProfits = Reaction(id: "take-profits", title: "Take profits and wait for a pullback", symbol: "banknote",
                                      summary: "Sell a third of the stocks after the rally and buy back after the months set below.",
                                      moves: [Move(from: .stocks, to: .cash, fraction: 0.33), Move(from: .single, to: .cash, fraction: 0.33)], after: .revert)
    static let sellBonds = Reaction(id: "sell-bonds", title: "Sell the bonds, sit in cash", symbol: "arrow.down.to.line.compact",
                                    summary: "Bonds 'don't work any more': sell them all to cash and return to the plan after the months set below.",
                                    moves: [Move(from: .bonds, to: .cash, fraction: 1)], after: .revert)
    static let chaseYield = Reaction(id: "chase-yield", title: "Chase the higher yields", symbol: "arrow.up.right",
                                     summary: "Move a third of the stocks into bonds for good to lock in today's yields.",
                                     moves: [Move(from: .stocks, to: .bonds, fraction: 0.33)], after: .permanent)
    static let fadeCrowd = Reaction(id: "fade-crowd", title: "Bet against the crowd", symbol: "arrow.uturn.down",
                                    summary: "Positioning looks crowded: sell half the stocks and buy back after the months set below.",
                                    moves: [Move(from: .stocks, to: .cash, fraction: 0.5), Move(from: .single, to: .cash, fraction: 0.5)], after: .revert)
    static let joinCrowd = Reaction(id: "join-crowd", title: "Follow the money", symbol: "arrow.right.circle",
                                    summary: "Do what the flows are doing: move the cash and a third of the bonds into stocks for good.",
                                    moves: [Move(from: .cash, to: .stocks, fraction: 1), Move(from: .bonds, to: .stocks, fraction: 0.33)], after: .permanent)

    static let followFlows = Reaction(id: "follow-flows", title: "Follow the money into cash", symbol: "arrow.right.circle",
                                      summary: "Do what the flows are doing: move half the stocks into a money-market fund and keep it there.",
                                      moves: [Move(from: .stocks, to: .cash, fraction: 0.5), Move(from: .single, to: .cash, fraction: 0.5)], after: .permanent)

    static func sellSingle(_ t: String) -> Reaction {
        Reaction(id: "sell-single", title: "Sell \(t), buy the index", symbol: "arrow.triangle.branch",
                 summary: "Sell all \(t) today and put the money in the broad stock index — a lasting change to a more diversified plan.",
                 moves: [Move(from: .single, to: .stocks, fraction: 1)], after: .permanent)
    }

    static func doubleDown(_ t: String) -> Reaction {
        Reaction(id: "double-down", title: "Double down on \(t)", symbol: "plus.circle",
                 summary: "Buy more \(t) with all the cash and a fifth of the other stocks: 'it's on sale'. The new mix becomes the plan.",
                 moves: [Move(from: .cash, to: .single, fraction: 1), Move(from: .stocks, to: .single, fraction: 0.2)], after: .permanent)
    }

    static func chaseWinner(_ t: String) -> Reaction {
        Reaction(id: "chase-winner", title: "Buy more of the winner (\(t))", symbol: "flame",
                 summary: "Estimates are rising, so buy more \(t) with the cash and a tenth of the other stocks, and keep it.",
                 moves: [Move(from: .cash, to: .single, fraction: 1), Move(from: .stocks, to: .single, fraction: 0.1)], after: .permanent)
    }

    static func sellSingleWait(_ t: String) -> Reaction {
        Reaction(id: "sell-wait", title: "Sell \(t), wait in cash, buy it back", symbol: "hourglass",
                 summary: "Sell \(t) to cash today and buy it back after the months set below, 'once it has bottomed'.",
                 moves: [Move(from: .single, to: .cash, fraction: 1)], after: .revert)
    }
}

nonisolated extension MarketReport {
    // MARK: - Tier 1

    static let cpi = MarketReport(
        id: "cpi", title: "CPI Inflation Report", symbol: "cart",
        source: "Consumer Price Index — illustrative, in the shape of the monthly U.S. report (mid-month, 8:30 a.m. ET)",
        headline: "Inflation runs hot: core CPI +0.5% in the month, 3.4% over the year — above every forecast",
        lines: [
            ReportLine(label: "Headline CPI, month", value: "+0.4%", expected: "+0.3%", meaning: "Prices of everything consumers buy, including food and energy, versus last month."),
            ReportLine(label: "Headline CPI, year", value: "3.1%", expected: "2.9%", meaning: "The number in the news: prices versus a year ago."),
            ReportLine(label: "Core CPI, month", value: "+0.5%", expected: "+0.3%", meaning: "Excluding food and energy, which swing with weather and oil. The measure markets and the Fed watch most."),
            ReportLine(label: "Core CPI, year", value: "3.4%", expected: "3.2%", meaning: "Underlying inflation over a year. The Fed's target (for a related index) is 2%."),
            ReportLine(label: "Shelter", value: "+0.6%", expected: "+0.4%", meaning: "Rents and owners' equivalent rent: about a third of the index, slow to change."),
            ReportLine(label: "Core services ex-housing", value: "+0.6%", expected: "+0.3%", meaning: "'Supercore': labor-heavy services like insurance, medical care and travel — closely tied to wages."),
        ],
        reading: [
            "Core month-on-month is the market's number: 0.5% instead of 0.3% sounds small, but it is a 6% annualised pace.",
            "Look at what drove it: one-off items (airfares, used cars) fade; shelter and services persist.",
            "Translate it into rates: hot inflation means the Fed is less likely to cut soon, so short-term yields jump.",
            "Higher yields hurt long-duration assets most: growth stocks whose profits lie far in the future, long bonds, real estate.",
            "One month is noisy. Three- and six-month annualised rates show the trend.",
        ],
        terms: [
            ReportTerm(term: "Core inflation", definition: "Inflation excluding food and energy; a steadier read of the underlying trend."),
            ReportTerm(term: "Annualised rate", definition: "A monthly change compounded over twelve months: 0.5% a month ≈ 6.2% a year."),
            ReportTerm(term: "Base effects", definition: "The year-on-year rate also moves because of what happened a year ago dropping out of the comparison."),
            ReportTerm(term: "Real yield", definition: "A bond yield minus expected inflation: what lenders earn after inflation."),
        ],
        moves: [
            MarketMove(asset: "2-year Treasury yield", move: "+0.20 points", why: "Fewer and later rate cuts priced in."),
            MarketMove(asset: "Stocks (S&P 500)", move: "−2.6%", why: "Higher rates lower the value of future profits."),
            MarketMove(asset: "Technology and growth stocks", move: "−4%", why: "Long-duration: most of their value is profits many years out."),
            MarketMove(asset: "Aggregate bond fund", move: "−1.1%", why: "Yields up, prices down."),
            MarketMove(asset: "Banks", move: "−0.5%", why: "Higher rates help lending margins but raise recession worries."),
        ],
        marketMove: -0.020, rateMove: 0.0018,
        sectorMoves: ["Technology": -0.018, "Communication Services": -0.010, "Real Estate": -0.012, "Financials": 0.012, "Energy": 0.010],
        reactions: [Reactions.sellAll, Reactions.rotateBonds, Reactions.buyDip, Reactions.sellBonds, Reactions.everyTime],
        takeaways: [
            "CPI is often the single biggest driver of interest-rate expectations — and so of bond yields and growth-stock valuations.",
            "Inflation surprises hit stocks and bonds at the same time; that is when a 60/40 account has its worst days.",
            "Stocks have historically outpaced inflation over long periods; cash and long bonds held to maturity have not always.",
            "If inflation worries you, the plan's answer is in its mix (inflation-protected bonds, broad stocks), set in advance — not a sale on release day.",
        ],
        suggestedSample: "SAMPLE_TECH_HEAVY",
        tier: 1, publisher: "U.S. Bureau of Labor Statistics (BLS)", frequency: "Monthly, around the 10th–15th, 8:30 a.m. ET",
        keyMetrics: ["Headline CPI", "Core CPI (ex food and energy)", "Monthly and annual inflation rates"],
        whyCare: ["Often the single biggest driver of interest-rate expectations.", "Influences bond yields, growth stocks, banks and consumer sectors."],
        drivers: [.inflation, .rates], impact: 3, topFive: 1,
        context: ReportSeries("Core CPI, year over year", unit: "%",
                              [("Nov", 3.0), ("Dec", 2.9), ("Jan", 3.0), ("Feb", 2.9), ("Mar", 2.8), ("Apr", 2.9), ("May", 3.0), ("Jun", 3.1), ("Jul", 3.1), ("Aug", 3.2), ("Sep", 3.2), ("Oct", 3.4)],
                              reference: 2, referenceLabel: "the Fed's 2% goal", note: "Illustrative: inflation had stopped falling months before this report."))

    static let ppi = MarketReport(
        id: "ppi", title: "PPI Producer Prices", symbol: "shippingbox",
        source: "Producer Price Index for final demand — illustrative, in the shape of the monthly U.S. report",
        headline: "Producer prices jump 0.7%, led by goods and transport costs; margins under pressure",
        lines: [
            ReportLine(label: "PPI final demand, month", value: "+0.7%", expected: "+0.2%", meaning: "Prices businesses receive for what they sell — an early read of costs that may reach consumers."),
            ReportLine(label: "PPI final demand, year", value: "3.3%", expected: "2.7%", meaning: "Versus a year ago."),
            ReportLine(label: "Core PPI (ex food, energy, trade)", value: "+0.4%", expected: "+0.2%", meaning: "Strips out volatile parts and retail and wholesale margins."),
            ReportLine(label: "Goods", value: "+1.1%", expected: "+0.3%", meaning: "Materials and manufactured goods, sensitive to commodities and tariffs."),
            ReportLine(label: "Portfolio management fees", value: "+1.9%", expected: "—", meaning: "Yes, it's in PPI — and it rises with stock prices, a known quirk economists adjust for."),
        ],
        reading: [
            "PPI often gives an early signal of where CPI goes next, because producers pass costs on with a lag.",
            "Some PPI components (medical care, airfares, portfolio management) feed directly into the Fed's preferred inflation gauge, so economists recompute forecasts the same morning.",
            "For companies, the question is who absorbs the cost: if they can't raise prices, margins shrink.",
            "Markets usually react less to PPI than to CPI — unless, as here, the surprise is large.",
        ],
        terms: [
            ReportTerm(term: "Final demand", definition: "Goods, services and construction sold to final users, the headline PPI measure."),
            ReportTerm(term: "Pass-through", definition: "How much of a cost increase a company passes to its customers as higher prices."),
            ReportTerm(term: "Margin pressure", definition: "Costs rising faster than prices: profit per sale falls."),
        ],
        moves: [
            MarketMove(asset: "2-year Treasury yield", move: "+0.10 points", why: "Inflation may stay higher for longer."),
            MarketMove(asset: "Stocks (S&P 500)", move: "−1.3%", why: "Higher costs and rates; margin worries."),
            MarketMove(asset: "Industrials and materials users", move: "−2%", why: "Input costs hit them first."),
            MarketMove(asset: "Energy and materials producers", move: "+1%", why: "Their selling prices are what rose."),
        ],
        marketMove: -0.011, rateMove: 0.0010,
        sectorMoves: ["Industrials": -0.010, "Consumer Discretionary": -0.008, "Consumer Staples": -0.006, "Energy": 0.020, "Materials": 0.012],
        reactions: [Reactions.sellHalf, Reactions.rotateBonds, Reactions.buyDip, Reactions.sellBonds],
        takeaways: [
            "PPI is an early signal for CPI and a margin warning for companies — useful context, rarely a reason to trade.",
            "Rising costs hurt companies without pricing power and help the producers of what got more expensive; a diversified index owns both.",
            "Compare what you'd do on PPI day with the CPI walkthrough: the same fear, a smaller surprise, the same long-run arithmetic.",
        ],
        suggestedSample: "SAMPLE_CORE_SATELLITE",
        tier: 1, publisher: "U.S. Bureau of Labor Statistics (BLS)", frequency: "Monthly, usually the day before or after CPI",
        keyMetrics: ["PPI final demand", "Core PPI", "Goods and services components"],
        whyCare: ["Often an early signal of future CPI trends.", "Important for assessing corporate margin pressure."],
        drivers: [.inflation, .profits, .rates], impact: 2,
        context: ReportSeries("PPI final demand, monthly change", unit: "%", kind: .bar,
                              [("Nov", 0.2), ("Dec", 0.1), ("Jan", 0.3), ("Feb", -0.1), ("Mar", 0.2), ("Apr", 0.3), ("May", 0.1), ("Jun", 0.2), ("Jul", 0.3), ("Aug", 0.2), ("Sep", 0.3), ("Oct", 0.7)],
                              note: "Illustrative: monthly PPI is noisy; one large month matters if the next months confirm it."))

    static let fomc = MarketReport(
        id: "fomc", title: "FOMC Decision & Projections", symbol: "building.columns",
        source: "Federal Open Market Committee statement, Summary of Economic Projections and press conference — illustrative",
        headline: "Fed holds rates at 4.00–4.25%; the dot plot shows one cut next year instead of three",
        lines: [
            ReportLine(label: "Federal funds target", value: "4.00–4.25% (hold)", expected: "Hold (78% odds)", meaning: "The overnight rate the Fed sets; it anchors all other short-term rates."),
            ReportLine(label: "Dot plot: median, end of next year", value: "3.875%", expected: "3.375%", meaning: "Each official's projected rate path. The median moved up: one cut next year, not three."),
            ReportLine(label: "Core inflation projection", value: "2.9%", expected: "2.6%", meaning: "The Fed's own inflation forecast was raised."),
            ReportLine(label: "GDP growth projection", value: "1.8%", expected: "1.7%", meaning: "The Fed sees the economy holding up."),
            ReportLine(label: "Dissents", value: "1 (for a cut)", expected: "0", meaning: "Votes against the decision show how divided the committee is."),
            ReportLine(label: "Press conference tone", value: "'Patient', 'no hurry'", expected: "—", meaning: "The chair's words often move markets more than the statement."),
        ],
        reading: [
            "The decision itself was expected; the surprise is in the projections — 'hawkish hold'.",
            "Compare the dots with what futures markets had priced: the gap is the surprise.",
            "Read the statement against the last one word by word; changes are deliberate.",
            "The press conference can reverse the first reaction within the hour.",
            "Fed projections are often wrong; markets react to the change in expected path, which is why it's so volatile.",
        ],
        terms: [
            ReportTerm(term: "Dot plot", definition: "A chart of each FOMC participant's projected federal funds rate at the end of the next few years."),
            ReportTerm(term: "Hawkish / dovish", definition: "Leaning toward higher rates to fight inflation / toward lower rates to support growth."),
            ReportTerm(term: "Fed funds futures", definition: "Contracts whose prices imply the market's odds of each decision at upcoming meetings."),
            ReportTerm(term: "Quantitative tightening", definition: "The Fed shrinking its bond holdings, which tends to push long yields up."),
        ],
        moves: [
            MarketMove(asset: "2-year Treasury yield", move: "+0.15 points", why: "Fewer cuts priced for next year."),
            MarketMove(asset: "Stocks (S&P 500)", move: "−1.8%", why: "Higher-for-longer rates."),
            MarketMove(asset: "U.S. dollar", move: "+0.8%", why: "Higher U.S. rates attract foreign money."),
            MarketMove(asset: "Long Treasury fund", move: "−1.5%", why: "Long yields rose less than short ones but still rose."),
            MarketMove(asset: "International stocks (in dollars)", move: "−2.2%", why: "A stronger dollar lowers their dollar value."),
        ],
        marketMove: -0.016, rateMove: 0.0011,
        sectorMoves: ["Real Estate": -0.012, "Utilities": -0.008, "Technology": -0.008, "Financials": 0.006],
        reactions: [Reactions.sellAll, Reactions.rotateBonds, Reactions.chaseYield, Reactions.buyDip, Reactions.everyTime],
        takeaways: [
            "Fed decisions can trigger big reallocations between stocks, bonds, cash and international assets by professionals with mandates to do so; a personal plan rarely needs to move.",
            "The Fed meets eight times a year; reacting to each one means up to eight chances a year to be out at the wrong time.",
            "Higher rates for longer also means cash and new bonds pay more — the plan's bond sleeve benefits from here.",
            "Don't fight the Fed is an old saying; neither is forecasting it a plan.",
        ],
        suggestedSample: "SAMPLE_6040_DRIFT",
        tier: 1, publisher: "Federal Reserve (FOMC)", frequency: "8 meetings a year; projections at 4 of them; 2:00 p.m. ET, press conference 2:30",
        keyMetrics: ["Interest-rate decision", "Dot plot", "Economic projections", "Chair's press conference"],
        whyCare: ["Can trigger major portfolio reallocations between equities, bonds, cash and international assets."],
        drivers: [.rates, .inflation, .growth], impact: 3, topFive: 3,
        context: ReportSeries("Cuts priced for next year, before and after", unit: "cuts", kind: .bar,
                              [("Last month", 3.2), ("Last week", 2.7), ("Before 2 p.m.", 2.5), ("After the dots", 1.4), ("After the press conference", 1.6)],
                              note: "Illustrative fed funds futures: what the market expects changed within an hour."))

    // MARK: - Tier 2

    static let gdp = MarketReport(
        id: "gdp", title: "GDP Report", symbol: "chart.bar.xaxis",
        source: "Gross Domestic Product, advance estimate — illustrative, in the shape of the quarterly U.S. report (BEA)",
        headline: "Growth slows to 0.8% annualised as consumers and business investment cool",
        lines: [
            ReportLine(label: "Real GDP, annualised", value: "0.8%", expected: "1.9%", meaning: "Inflation-adjusted output of the economy versus last quarter, at an annual rate."),
            ReportLine(label: "Consumer spending", value: "1.1%", expected: "2.2%", meaning: "About two-thirds of the economy."),
            ReportLine(label: "Business investment", value: "−1.4%", expected: "+1.5%", meaning: "Equipment, structures, software: a sign of confidence."),
            ReportLine(label: "Government spending", value: "+2.1%", expected: "+1.8%", meaning: "Federal, state and local purchases."),
            ReportLine(label: "Net exports and inventories", value: "−0.6 points", expected: "0.0", meaning: "Swing factors that often reverse next quarter."),
            ReportLine(label: "GDP price index", value: "2.9%", expected: "2.6%", meaning: "Inflation inside GDP: slow growth with firm inflation is the uncomfortable mix."),
        ],
        reading: [
            "It's backward-looking: the quarter ended weeks ago, and markets had other data on it already.",
            "Look past the headline at final sales to private buyers (consumers plus business investment) — the core of demand.",
            "The advance estimate is revised twice; revisions can be large.",
            "Two negative quarters are a popular recession rule of thumb, not the official definition (a committee decides, later).",
        ],
        terms: [
            ReportTerm(term: "Annualised", definition: "The quarter's change compounded to a yearly rate: 0.2% in a quarter ≈ 0.8% annualised."),
            ReportTerm(term: "Real vs nominal", definition: "Real is adjusted for inflation; nominal is in today's dollars."),
            ReportTerm(term: "Recession", definition: "A significant, broad decline in activity; in the U.S. dated after the fact by the NBER."),
        ],
        moves: [
            MarketMove(asset: "Stocks (S&P 500)", move: "−1.2%", why: "Slower growth, lower profit expectations."),
            MarketMove(asset: "Cyclical stocks", move: "−2%", why: "Industrials, materials and discretionary depend most on growth."),
            MarketMove(asset: "10-year Treasury yield", move: "−0.08 points", why: "Growth worries outweigh the firm price index."),
            MarketMove(asset: "Aggregate bond fund", move: "+0.5%", why: "Bonds rally on slower growth."),
        ],
        marketMove: -0.011, rateMove: -0.0008,
        sectorMoves: ["Industrials": -0.010, "Materials": -0.010, "Consumer Discretionary": -0.008, "Utilities": 0.008, "Consumer Staples": 0.006, "Health Care": 0.005],
        reactions: [Reactions.sellAll, Reactions.sellHalf, Reactions.rotateBonds, Reactions.buyDip, Reactions.everyTime],
        takeaways: [
            "GDP tells you whether the economy accelerated or slowed — last quarter. Prices already reflect what came after.",
            "Stock returns and GDP growth are only loosely linked year to year; markets often bottom while the economy is still weak.",
            "A plan that holds bonds alongside stocks is built for slowdowns; they are when it does its job.",
        ],
        suggestedSample: "SAMPLE_CORE_SATELLITE",
        tier: 2, publisher: "U.S. Bureau of Economic Analysis (BEA)", frequency: "Quarterly (advance, second and third estimates), 8:30 a.m. ET",
        keyMetrics: ["Real GDP growth", "Consumer spending", "Business investment", "Government spending"],
        whyCare: ["Determines whether the economy is accelerating or slowing."],
        drivers: [.growth, .profits], impact: 2,
        context: ReportSeries("Real GDP growth, annualised by quarter", unit: "%", kind: .bar,
                              [("Q4 ’24", 2.4), ("Q1 ’25", -0.5), ("Q2 ’25", 3.0), ("Q3 ’25", 2.6), ("Q4 ’25", 2.1), ("Q1 ’26", 1.9), ("Q2 ’26", 1.6), ("Q3 ’26", 0.8)],
                              reference: 0, referenceLabel: "contraction below 0",
                              note: "Illustrative. A single negative quarter (here Q1 ’25) is not a recession."))

    static let ismManufacturing = MarketReport(
        id: "ism-manufacturing", title: "ISM Manufacturing PMI", symbol: "gearshape.2",
        source: "ISM Manufacturing Report on Business — illustrative, in the shape of the monthly survey (first business day, 10:00 a.m. ET)",
        headline: "Factory activity contracts for a sixth month: PMI 46.8, new orders 44.1",
        lines: [
            ReportLine(label: "Manufacturing PMI", value: "46.8", expected: "48.9", meaning: "A survey of purchasing managers. Above 50 = expansion, below 50 = contraction."),
            ReportLine(label: "New orders", value: "44.1", expected: "48.0", meaning: "The most forward-looking part: tomorrow's production."),
            ReportLine(label: "Production", value: "47.5", expected: "49.0", meaning: "Output this month."),
            ReportLine(label: "Employment", value: "45.9", expected: "47.0", meaning: "Factory hiring; feeds into the jobs report."),
            ReportLine(label: "Prices paid", value: "58.2", expected: "55.0", meaning: "Input-cost inflation; above 50 means costs are rising."),
            ReportLine(label: "Customers' inventories", value: "41.0", expected: "—", meaning: "Low customer inventories can mean orders recover later."),
        ],
        reading: [
            "It's a diffusion index: the share saying 'better' minus 'worse', centred on 50 — it measures breadth, not size.",
            "New orders minus inventories is a popular leading signal.",
            "Manufacturing is a small share of the U.S. economy but swings most and moves cyclical stocks.",
            "Weak activity with rising prices paid is the stagflation worry.",
            "PMIs often turn before earnings do — which is why cyclical stocks move on them.",
        ],
        terms: [
            ReportTerm(term: "PMI", definition: "Purchasing Managers' Index: a monthly survey-based gauge of activity; 50 separates expansion from contraction."),
            ReportTerm(term: "Diffusion index", definition: "Measures how widespread a change is, not how big."),
            ReportTerm(term: "Cyclical stocks", definition: "Companies whose profits rise and fall with the economy: industrials, materials, discretionary."),
        ],
        moves: [
            MarketMove(asset: "Industrials and materials", move: "−2.5%", why: "Their orders are what the survey measures."),
            MarketMove(asset: "Stocks (S&P 500)", move: "−0.9%", why: "Growth worries."),
            MarketMove(asset: "10-year Treasury yield", move: "−0.06 points", why: "Slower growth."),
            MarketMove(asset: "Defensive sectors", move: "+0.5%", why: "Staples, utilities and health care hold up."),
        ],
        marketMove: -0.008, rateMove: -0.0006,
        sectorMoves: ["Industrials": -0.018, "Materials": -0.018, "Energy": -0.008, "Consumer Staples": 0.010, "Utilities": 0.010, "Health Care": 0.008],
        reactions: [Reactions.sellHalf, Reactions.rotateBonds, Reactions.buyDip, Reactions.everyTime],
        takeaways: [
            "PMIs are early indicators: useful to understand why cyclical stocks moved, too noisy to time a long-term plan.",
            "Sector rotation on PMIs is a professional, short-horizon game with real costs; the index already rotates for you as prices change.",
            "A sixth month below 50 is a slowdown, not necessarily a recession: manufacturing has dipped below 50 many times without one.",
        ],
        suggestedSample: "SAMPLE_CORE_SATELLITE",
        tier: 2, publisher: "Institute for Supply Management (ISM)", frequency: "Monthly, first business day, 10:00 a.m. ET",
        keyMetrics: ["Headline PMI (50 = expansion / contraction)", "New orders", "Employment", "Prices paid"],
        whyCare: ["An early indicator of economic activity.", "Often moves cyclical stocks before earnings reports."],
        drivers: [.growth, .inflation, .profits], impact: 2, topFive: 5,
        context: ReportSeries("ISM Manufacturing PMI", unit: "index",
                              [("Nov", 50.6), ("Dec", 50.1), ("Jan", 49.8), ("Feb", 50.3), ("Mar", 49.4), ("Apr", 48.7), ("May", 49.1), ("Jun", 48.5), ("Jul", 48.0), ("Aug", 47.6), ("Sep", 48.2), ("Oct", 46.8)],
                              reference: 50, referenceLabel: "50: expansion above, contraction below"))

    static let ismServices = MarketReport(
        id: "ism-services", title: "ISM Services PMI", symbol: "person.2.wave.2",
        source: "ISM Services Report on Business — illustrative, in the shape of the monthly survey (third business day, 10:00 a.m. ET)",
        headline: "Services surge: PMI 56.4, highest in two years; prices paid also climb",
        lines: [
            ReportLine(label: "Services PMI", value: "56.4", expected: "52.8", meaning: "Services are most of the economy: above 50 is expansion."),
            ReportLine(label: "Business activity", value: "58.9", expected: "54.0", meaning: "Output of service firms."),
            ReportLine(label: "New orders", value: "57.6", expected: "53.5", meaning: "Demand ahead."),
            ReportLine(label: "Employment", value: "52.1", expected: "50.5", meaning: "Service-sector hiring."),
            ReportLine(label: "Prices paid", value: "64.0", expected: "60.0", meaning: "Service-cost inflation — the part the Fed worries about most."),
        ],
        reading: [
            "Good news for growth can be bad news for rates: strong services and higher prices mean fewer rate cuts.",
            "Markets weigh the two: today stocks rose with growth, while bond yields also rose.",
            "Services employment feeds into Friday's jobs report expectations.",
            "One strong month after weak ones is often noise; watch the trend.",
        ],
        terms: [
            ReportTerm(term: "Services PMI", definition: "The ISM's survey of non-manufacturing businesses: retail, finance, health care, transport and more."),
            ReportTerm(term: "Good news is bad news", definition: "When strong data lowers stock prices because it implies higher interest rates."),
            ReportTerm(term: "FOMO", definition: "Fear of missing out: buying after a rise because others are."),
        ],
        moves: [
            MarketMove(asset: "Stocks (S&P 500)", move: "+1.4%", why: "Stronger growth, stronger profits."),
            MarketMove(asset: "Consumer discretionary and financials", move: "+2.5%", why: "Most sensitive to spending and activity."),
            MarketMove(asset: "10-year Treasury yield", move: "+0.09 points", why: "Fewer rate cuts; firmer inflation."),
            MarketMove(asset: "Aggregate bond fund", move: "−0.6%", why: "Yields up."),
        ],
        marketMove: 0.014, rateMove: 0.0009,
        sectorMoves: ["Consumer Discretionary": 0.012, "Financials": 0.012, "Industrials": 0.006, "Utilities": -0.010, "Real Estate": -0.008],
        reactions: [Reactions.goAllIn, Reactions.takeProfits, Reactions.sellBonds, Reactions.chaseYield],
        takeaways: [
            "Good news triggers reactions too: going all in after a rally is the mirror image of selling after a fall.",
            "Raising the stock share after strong data turns a plan into a forecast; it also raises the drop the account takes in the next bear market (compare 'Worst drop').",
            "Taking profits and waiting for a pullback is market timing in the other direction: the pullback may start from a higher level.",
        ],
        suggestedSample: "SAMPLE_6040_DRIFT",
        tier: 2, publisher: "Institute for Supply Management (ISM)", frequency: "Monthly, third business day, 10:00 a.m. ET",
        keyMetrics: ["Services PMI (50 = expansion / contraction)", "Business activity", "New orders", "Prices paid"],
        whyCare: ["An early indicator of activity in most of the economy.", "Often moves cyclical stocks before earnings reports."],
        drivers: [.growth, .inflation, .rates], impact: 2,
        context: ReportSeries("ISM Services PMI", unit: "index",
                              [("Nov", 52.1), ("Dec", 53.4), ("Jan", 51.8), ("Feb", 52.6), ("Mar", 50.8), ("Apr", 51.6), ("May", 49.9), ("Jun", 51.2), ("Jul", 52.0), ("Aug", 52.4), ("Sep", 53.0), ("Oct", 56.4)],
                              reference: 50, referenceLabel: "50: expansion above, contraction below"))

    static let retailSales = MarketReport(
        id: "retail-sales", title: "Retail Sales", symbol: "bag",
        source: "Advance Monthly Retail Trade report — illustrative, in the shape of the U.S. Census Bureau release (mid-month, 8:30 a.m. ET)",
        headline: "Shoppers pull back: retail sales −0.9%, control group −0.6%",
        lines: [
            ReportLine(label: "Retail sales, month", value: "−0.9%", expected: "+0.3%", meaning: "Nominal spending at stores, restaurants and online — not adjusted for prices."),
            ReportLine(label: "Ex autos and gas", value: "−0.5%", expected: "+0.3%", meaning: "Removes volatile car and fuel sales."),
            ReportLine(label: "Control group", value: "−0.6%", expected: "+0.4%", meaning: "The part that feeds GDP: excludes autos, gas, building materials and food services."),
            ReportLine(label: "Online (non-store)", value: "+0.4%", expected: "+0.6%", meaning: "E-commerce kept growing."),
            ReportLine(label: "Restaurants and bars", value: "−1.6%", expected: "+0.4%", meaning: "Discretionary: cut first when budgets tighten."),
            ReportLine(label: "Prior month (revised)", value: "+0.2% (was +0.5%)", expected: "—", meaning: "Downward revision: weakness started earlier."),
        ],
        reading: [
            "Consumer spending is about two-thirds of U.S. economic activity; the control group goes straight into GDP estimates.",
            "It's in nominal dollars: falling gas prices lower sales without anyone buying less.",
            "Weather, holidays and the timing of paydays can distort a single month.",
            "Watch which categories fell: discretionary (restaurants, apparel, furniture) weakens before staples.",
        ],
        terms: [
            ReportTerm(term: "Control group", definition: "Retail sales excluding autos, gas, building materials and food services; used in GDP."),
            ReportTerm(term: "Consumer discretionary", definition: "Things people want but can postpone: cars, restaurants, travel, furniture."),
            ReportTerm(term: "Consumer staples", definition: "Things people buy in any economy: food, household goods."),
        ],
        moves: [
            MarketMove(asset: "Consumer discretionary stocks", move: "−3%", why: "Their sales are what fell."),
            MarketMove(asset: "Stocks (S&P 500)", move: "−1.0%", why: "Weaker consumer, weaker growth."),
            MarketMove(asset: "Consumer staples", move: "+0.4%", why: "Defensive."),
            MarketMove(asset: "10-year Treasury yield", move: "−0.07 points", why: "Slower growth, more rate cuts."),
        ],
        marketMove: -0.009, rateMove: -0.0007,
        sectorMoves: ["Consumer Discretionary": -0.020, "Communication Services": -0.004, "Consumer Staples": 0.010, "Utilities": 0.006],
        reactions: [Reactions.sellAll, Reactions.sellHalf, Reactions.rotateBonds, Reactions.buyDip],
        takeaways: [
            "Retail sales are critical for the consumer discretionary and retail sectors — and a monthly read of two-thirds of the economy.",
            "Consumer slowdowns hit specific sectors hardest; a diversified account feels a fraction of the sector move.",
            "Single monthly prints are noisy and revised; let the plan's rebalance rule, not the print, decide trades.",
        ],
        suggestedSample: "SAMPLE_MISSING_DATA",
        tier: 2, publisher: "U.S. Census Bureau", frequency: "Monthly, mid-month, 8:30 a.m. ET",
        keyMetrics: ["Headline retail sales", "Ex autos and gas", "Control group", "Category detail"],
        whyCare: ["Consumer spending is roughly two-thirds of U.S. economic activity.", "Critical for the consumer discretionary and retail sectors."],
        drivers: [.growth, .profits], impact: 2,
        context: ReportSeries("Retail sales control group, monthly change", unit: "%", kind: .bar,
                              [("Nov", 0.6), ("Dec", 0.4), ("Jan", -0.3), ("Feb", 0.7), ("Mar", 0.5), ("Apr", 0.2), ("May", 0.3), ("Jun", 0.4), ("Jul", 0.1), ("Aug", 0.3), ("Sep", 0.2), ("Oct", -0.6)],
                              reference: 0))

    // MARK: - Tier 3

    static let revisions = MarketReport(
        id: "revisions", title: "Earnings Revisions", symbol: "arrow.up.arrow.down.circle",
        source: "Consensus-estimate revisions — hypothetical, applied to {company}, this account's largest technology stock; invented numbers in the shape of the weekly data analysts get from FactSet, Bloomberg, Visible Alpha and Refinitiv, not {ticker}'s real estimates",
        headline: "Analysts raise estimates for {company} for a fourth week; the stock is up 11% in a month (hypothetical)",
        lines: [
            ReportLine(label: "{ticker} next-year EPS consensus", value: "+8% in 4 weeks", expected: "flat a month ago", meaning: "The average analyst forecast of next year's earnings per share."),
            ReportLine(label: "Upward / downward revisions", value: "18 up / 2 down", expected: "—", meaning: "How many analysts raised versus cut — the breadth of the change."),
            ReportLine(label: "Price target, median", value: "+7% in a month", expected: "—", meaning: "Where analysts think the stock trades in a year; follows the price as often as it leads."),
            ReportLine(label: "Forward P/E", value: "up 1.2 points", expected: "a month ago", meaning: "Price divided by next year's expected earnings: how much investors pay per dollar of profit."),
            ReportLine(label: "Market revision breadth", value: "+12%", expected: "—", meaning: "Across the whole index, upward minus downward revisions as a share of all."),
        ],
        reading: [
            "Analysts revising estimates up or down often precedes stock moves — and revisions tend to persist for a while ('momentum').",
            "But it's widely known: the stock price may already reflect the revisions, as the rising P/E here suggests.",
            "Breadth matters: many analysts revising a little is more informative than one revising a lot.",
            "Estimates can be wrong together; revisions reverse when results disappoint.",
        ],
        terms: [
            ReportTerm(term: "Consensus estimate", definition: "The average of analysts' forecasts for a company's earnings."),
            ReportTerm(term: "Revision breadth", definition: "Upward minus downward revisions over the total; positive is improving."),
            ReportTerm(term: "Momentum", definition: "The tendency of recent winners to keep winning for a while — and to reverse sharply when they stop."),
        ],
        moves: [
            MarketMove(asset: "{company}", move: "+3.5% today, +11% in a month", why: "Rising expected profits."),
            MarketMove(asset: "Software peers", move: "+1.5%", why: "Read-across: the same demand may help them."),
            MarketMove(asset: "Stocks (S&P 500)", move: "+0.3%", why: "A quiet day for the market."),
        ],
        marketMove: 0.003, rateMove: 0,
        sectorMoves: ["Technology": 0.010],
        companyMoves: [MarketReport.company: 0.035],
        single: MarketReport.company, companySector: "Technology",
        reactions: [Reactions.chaseWinner("{ticker}"), Reactions.sellSingle("{ticker}"), Reactions.takeProfits, Reactions.goAllIn],
        takeaways: [
            "Revisions are a real signal that professionals pay for — and because they pay for it, much of it is in the price quickly.",
            "Chasing a winner raises concentration: compare the bad-outcome column, not only the median.",
            "In an index fund the stocks with rising estimates gain weight automatically as their prices rise.",
        ],
        suggestedSample: "SAMPLE_TECH_HEAVY",
        tier: 3, publisher: "Data providers: FactSet, Bloomberg, Visible Alpha, Refinitiv (LSEG)", frequency: "Continuous; most followed weekly",
        keyMetrics: ["Consensus EPS and revenue", "Up vs down revisions (breadth)", "Price targets", "Forward P/E"],
        whyCare: ["Analysts revising estimates up or down often precede stock movements."],
        drivers: [.profits, .sentiment], impact: 1,
        context: ReportSeries("Hypothetical next-year EPS consensus, weekly (week 1 = 100)", unit: "index",
                              [("W1", 100), ("W2", 100.2), ("W3", 100.1), ("W4", 100.5), ("W5", 102.4), ("W6", 104.5), ("W7", 106.4), ("W8", 108.2)],
                              note: "Invented: four weeks of rising estimates after a product launch."))

    // MARK: - Tier 4

    static let cot = MarketReport(
        id: "cot", title: "CFTC Commitments of Traders", symbol: "person.3.sequence",
        source: "Commitments of Traders — illustrative, in the shape of the weekly CFTC report (Friday 3:30 p.m. ET, positions as of Tuesday)",
        headline: "Speculators hold record net long in stock index futures and record short in 10-year Treasury futures",
        lines: [
            ReportLine(label: "Equity index futures, leveraged funds net", value: "+412,000 contracts (record)", expected: "+290,000 avg", meaning: "Hedge funds' bets on stock futures, long minus short."),
            ReportLine(label: "10-year Treasury futures, leveraged funds net", value: "−1.1 million (record short)", expected: "−0.7 million avg", meaning: "Bets that bond prices fall — partly basis trades, not pure views."),
            ReportLine(label: "Asset managers, equity futures net", value: "+880,000", expected: "+810,000", meaning: "Pension and mutual-fund exposure through futures."),
            ReportLine(label: "Crude oil, managed money net", value: "+145,000", expected: "+210,000", meaning: "Speculators have been cutting oil bets."),
            ReportLine(label: "Positioning percentile (equities)", value: "99th", expected: "—", meaning: "Where today's net long sits against the last five years."),
        ],
        reading: [
            "COT shows who holds futures — hedge funds, asset managers, dealers, commercial hedgers — not why.",
            "Extremes identify crowded trades: when everyone is already long, fewer buyers are left, and an unwind can be sharp.",
            "But crowded trades can stay crowded for months; positioning is a risk warning, not a timing signal.",
            "Some big positions are hedges or arbitrage (the Treasury basis trade), not directional bets.",
            "The data is three days old when released.",
        ],
        terms: [
            ReportTerm(term: "Net long / short", definition: "Contracts betting on a rise minus those betting on a fall."),
            ReportTerm(term: "Crowded trade", definition: "A position held by so many investors that their exit moves the price against them."),
            ReportTerm(term: "Basis trade", definition: "Buying Treasuries and selling futures to earn the small price gap, with leverage."),
            ReportTerm(term: "Contrarian", definition: "Doing the opposite of the crowd — right at turning points, costly in between."),
        ],
        moves: [
            MarketMove(asset: "Stocks (S&P 500)", move: "+0.2%", why: "Released after the close; little immediate effect."),
            MarketMove(asset: "Market commentary", move: "—", why: "Weekend headlines: 'Hedge funds most bullish on record'."),
        ],
        marketMove: 0.002, rateMove: 0,
        reactions: [Reactions.fadeCrowd, Reactions.joinCrowd, Reactions.sellAll, Reactions.everyTime],
        takeaways: [
            "Positioning reports help professionals size risk around crowded trades; for a personal plan they explain why moves can be sudden.",
            "Betting against the crowd and joining it are both forecasts; the simulation shows how often either beats holding the plan.",
            "Your own positioning is the one you control: an account already at its planned stock share has nothing to unwind.",
        ],
        suggestedSample: "SAMPLE_6040_DRIFT",
        tier: 4, publisher: "U.S. Commodity Futures Trading Commission (CFTC)", frequency: "Weekly, Friday 3:30 p.m. ET (as of Tuesday)",
        keyMetrics: ["Hedge-fund (leveraged) positioning", "Commercial hedging", "Speculative activity", "Treasury, equity-index, commodity and currency futures"],
        whyCare: ["Identifies crowded trades."],
        drivers: [.sentiment], impact: 1,
        context: ReportSeries("Leveraged funds, net equity index futures", unit: "thousand contracts",
                              [("Jan", 120), ("Feb", 160), ("Mar", 60), ("Apr", -40), ("May", 80), ("Jun", 150), ("Jul", 210), ("Aug", 260), ("Sep", 330), ("Oct", 412)],
                              reference: 290, referenceLabel: "five-year average"))

    static let fundFlows = MarketReport(
        id: "fund-flows", title: "Fund Flow Report", symbol: "arrow.left.arrow.right.circle",
        source: "Weekly fund flows — illustrative, in the shape of reports from EPFR, Morningstar and Lipper",
        headline: "Investors pull $24 billion from stock funds, the most in a year; money-market funds take in $41 billion",
        lines: [
            ReportLine(label: "U.S. equity funds and ETFs", value: "−$24.1bn", expected: "−$3bn avg", meaning: "Net money leaving stock funds this week."),
            ReportLine(label: "Bond funds", value: "+$6.3bn", expected: "+$5bn avg", meaning: "Steady inflows."),
            ReportLine(label: "Money-market funds", value: "+$41.2bn", expected: "+$10bn avg", meaning: "Cash on the sidelines; total assets at a record."),
            ReportLine(label: "International / emerging equity", value: "+$1.2bn / −$2.0bn", expected: "—", meaning: "Regional rotation."),
            ReportLine(label: "Index ETFs vs active mutual funds", value: "+$3.0bn / −$27.1bn", expected: "—", meaning: "The long shift from active funds to index funds continues."),
        ],
        reading: [
            "Flows reveal sentiment and liquidity: here, fear.",
            "Big outflows have often come near market lows, after prices already fell — investors sell after, not before.",
            "Money-market cash is not necessarily 'waiting to come back': much of it is earning a good yield on purpose.",
            "Active-to-passive flows are structural, not a market call.",
        ],
        terms: [
            ReportTerm(term: "Net flows", definition: "Money invested minus money withdrawn from a fund category."),
            ReportTerm(term: "Behaviour gap", definition: "The difference between a fund's return and its average investor's return, caused by buying high and selling low."),
            ReportTerm(term: "Liquidity", definition: "How easily money moves into and out of a market without moving prices."),
        ],
        moves: [
            MarketMove(asset: "Stocks (S&P 500)", move: "−3.5% over the week", why: "The selling the flows describe."),
            MarketMove(asset: "Money-market yields", move: "4.1%", why: "Cash pays well, which makes waiting feel safe."),
        ],
        marketMove: -0.012, rateMove: -0.0003,
        reactions: [Reactions.followFlows, Reactions.sellAll, Reactions.buyDip, Reactions.everyTime],
        takeaways: [
            "Fund flows show what investors as a group did — usually after the move. Following them means buying high and selling low.",
            "Studies of investor returns find the average fund investor earns less than the fund itself because of badly timed flows: the 'behaviour gap'.",
            "A rebalance rule does the opposite of the crowd automatically, without needing a view.",
        ],
        suggestedSample: "SAMPLE_CORE_SATELLITE",
        tier: 4, publisher: "Data providers: EPFR, Morningstar, LSEG Lipper", frequency: "Weekly (EPFR, Lipper), monthly (Morningstar)",
        keyMetrics: ["Equity, bond and money-market flows", "ETF vs mutual-fund flows", "Regional flows"],
        whyCare: ["Reveals investor sentiment and liquidity trends."],
        drivers: [.sentiment], impact: 1,
        context: ReportSeries("Weekly flows into U.S. equity funds", unit: "$bn", kind: .bar,
                              [("W1", 4.2), ("W2", 2.1), ("W3", -1.5), ("W4", 3.4), ("W5", -2.8), ("W6", -6.0), ("W7", -9.5), ("W8", -24.1)],
                              reference: 0, note: "Illustrative: outflows grew as prices fell — the selling came after the drop."))

    // MARK: - Tier 5

    static let auctions = MarketReport(
        id: "auctions", title: "Treasury Auction Results", symbol: "hammer",
        source: "U.S. Treasury auction results — illustrative, in the shape of a 10-year note auction (1:00 p.m. ET)",
        headline: "Weak 10-year auction: 3.2 basis-point tail, lowest bid-to-cover in two years; long yields jump",
        lines: [
            ReportLine(label: "Size", value: "$42bn 10-year notes", expected: "$42bn", meaning: "Announced the week before; deficits mean larger auctions over time."),
            ReportLine(label: "High yield vs when-issued", value: "4.612% vs 4.580%", expected: "—", meaning: "The 'tail': the auction cleared 3.2 basis points above where the market traded just before — weak demand."),
            ReportLine(label: "Bid-to-cover", value: "2.21×", expected: "2.50× avg", meaning: "Bids divided by the amount sold."),
            ReportLine(label: "Indirect bidders", value: "61%", expected: "68% avg", meaning: "Mostly foreign central banks and funds bidding through dealers."),
            ReportLine(label: "Primary dealers' share", value: "21%", expected: "13% avg", meaning: "Dealers must absorb what others don't buy; a high share is a sign of weak demand."),
        ],
        reading: [
            "Auctions test demand for government debt in real time; a big tail moves rates within minutes.",
            "2-, 5-, 10- and 30-year auctions get the most attention; 30-year results move long rates and mortgage rates.",
            "One weak auction is a data point; a run of them, with rising supply, raises the 'term premium'.",
            "For a bond investor, weak demand means new bonds pay more from here.",
        ],
        terms: [
            ReportTerm(term: "Tail", definition: "How far the auction's yield is above the pre-auction market yield; positive is weak."),
            ReportTerm(term: "Bid-to-cover", definition: "Total bids divided by the amount auctioned."),
            ReportTerm(term: "Basis point", definition: "One hundredth of a percentage point (0.01%)."),
            ReportTerm(term: "Term premium", definition: "Extra yield for holding longer maturities; rises with supply and uncertainty."),
        ],
        moves: [
            MarketMove(asset: "10-year Treasury yield", move: "+0.12 points", why: "Weak demand."),
            MarketMove(asset: "Long Treasury fund", move: "−2.2%", why: "Long duration."),
            MarketMove(asset: "Stocks (S&P 500)", move: "−0.8%", why: "Higher discount rates."),
            MarketMove(asset: "Real estate and utilities", move: "−1.8%", why: "Rate-sensitive."),
        ],
        marketMove: -0.006, rateMove: 0.0012,
        sectorMoves: ["Real Estate": -0.010, "Utilities": -0.008],
        reactions: [Reactions.sellBonds, Reactions.chaseYield, Reactions.sellHalf, Reactions.everyTime],
        takeaways: [
            "Treasury auctions can move interest rates immediately; they matter to anyone who owns bonds or borrows.",
            "A bond fund held for longer than its duration usually earns back a rate rise through higher yields.",
            "Selling bonds after a weak auction sells after the price fell — the same timing problem as selling stocks after a fall.",
        ],
        suggestedSample: "SAMPLE_INCOME",
        tier: 5, publisher: "U.S. Department of the Treasury (TreasuryDirect)", frequency: "Weekly bills; 2-, 5-, 7-year monthly; 10- and 30-year monthly with reopenings",
        keyMetrics: ["High yield vs when-issued (tail)", "Bid-to-cover", "Indirect, direct and dealer shares", "2-, 5-, 10- and 30-year results"],
        whyCare: ["Demand levels can move interest rates immediately."],
        drivers: [.rates], impact: 2,
        context: ReportSeries("10-year auction tails", unit: "basis points", kind: .bar,
                              [("May", -0.8), ("Jun", 0.4), ("Jul", -1.2), ("Aug", 1.1), ("Sep", 0.6), ("Oct", 3.2)],
                              reference: 0, note: "Illustrative: positive = weak (cleared above the market), negative = strong ('stop-through')."))

    // MARK: - Tier 6

    static let semiconductors = MarketReport(
        id: "semiconductors", title: "Semiconductor Sales (Technology)", symbol: "cpu",
        source: "Global semiconductor sales and cloud-spending surveys — illustrative, in the shape of the monthly industry association report and analyst forecasts (e.g. Gartner)",
        headline: "Chip sales fall 6% in the month as cloud providers pause data-center orders; technology stocks slide",
        lines: [
            ReportLine(label: "Global chip sales, 3-month average", value: "−6.1% m/m, +4% y/y", expected: "+1% m/m", meaning: "Industry revenue; the 3-month average smooths shipments."),
            ReportLine(label: "Memory prices", value: "−11%", expected: "−2%", meaning: "The most cyclical part of the industry."),
            ReportLine(label: "Cloud capex survey (next year)", value: "+8%", expected: "+18%", meaning: "Planned data-center spending by the largest cloud providers."),
            ReportLine(label: "Analyst IT-spending forecast", value: "+5.2% (was +7.0%)", expected: "—", meaning: "Research firms' forecasts of enterprise technology budgets."),
            ReportLine(label: "Inventory days at chipmakers", value: "128", expected: "110", meaning: "Unsold chips piling up: a sign of a cycle turning."),
        ],
        reading: [
            "Semiconductors are deeply cyclical: orders boom and bust with inventory, even when long-term demand grows.",
            "A slowdown in cloud spending reaches chipmakers first, then equipment suppliers.",
            "Year-on-year can still look fine while month-on-month turns: the second derivative moves stocks.",
            "Technology is a third of the S&P 500 — sector news is index news.",
        ],
        terms: [
            ReportTerm(term: "Capex", definition: "Capital expenditure: spending on equipment, buildings and data centers."),
            ReportTerm(term: "Inventory cycle", definition: "Customers over-order in shortages and stop ordering in gluts, amplifying swings."),
            ReportTerm(term: "Sector concentration", definition: "When one sector is a large share of the index, its news moves the whole market."),
        ],
        moves: [
            MarketMove(asset: "{company}", move: "−9% (hypothetical)", why: "This account's largest technology stock, assumed directly exposed to the order pause."),
            MarketMove(asset: "Technology sector", move: "−3.5%", why: "Read-across to the whole sector."),
            MarketMove(asset: "Stocks (S&P 500)", move: "−1.4%", why: "Technology's large weight."),
        ],
        marketMove: -0.004, rateMove: -0.0002,
        sectorMoves: ["Technology": -0.028],
        companyMoves: [MarketReport.company: -0.09],
        single: MarketReport.company, companySector: "Technology",
        reactions: [Reactions.sellSingle("{ticker}"), Reactions.doubleDown("{ticker}"), Reactions.sellSingleWait("{ticker}"), Reactions.sellAll],
        takeaways: [
            "Industry reports explain sector moves; specialists use them, generalists see them as noise around a long trend.",
            "A technology-heavy account feels sector cycles fully; the index feels them in proportion.",
            "Cycles are why diversification across sectors matters: one industry's bust is rarely everyone's.",
        ],
        suggestedSample: "SAMPLE_TECH_HEAVY",
        tier: 6, publisher: "Industry association monthly sales data; cloud-spending surveys; research firms such as Gartner", frequency: "Monthly sales; quarterly surveys and forecasts",
        keyMetrics: ["Semiconductor sales", "Cloud spending surveys", "IT spending forecasts", "Inventories"],
        whyCare: ["Early read on the technology cycle, a third of the index."],
        drivers: [.profits, .growth], impact: 1,
        context: ReportSeries("Chip sales, 3-month average, monthly change", unit: "%", kind: .bar,
                              [("May", 2.1), ("Jun", 2.8), ("Jul", 1.9), ("Aug", 0.6), ("Sep", -0.8), ("Oct", -6.1)], reference: 0),
        industry: "Technology")

    static let banks = MarketReport(
        id: "banks", title: "Bank Earnings & Credit (Financials)", symbol: "building.columns.circle",
        source: "Bank earnings, loan growth and credit-quality data — illustrative, in the shape of large-bank results and the Fed's weekly bank data",
        headline: "A large bank sets aside more for bad loans; credit-card charge-offs at a 10-year high",
        lines: [
            ReportLine(label: "Large-bank provision for credit losses", value: "+39% on the quarter", expected: "flat", meaning: "Money set aside for loans expected to go bad; cuts earnings now."),
            ReportLine(label: "Card net charge-off rate", value: "4.6%", expected: "4.1%", meaning: "Share of card balances written off as uncollectable."),
            ReportLine(label: "Loan growth (industry, year)", value: "+1.8%", expected: "+3.0%", meaning: "Banks lending less: tighter standards or weaker demand."),
            ReportLine(label: "Net interest margin", value: "3.05%", expected: "3.10%", meaning: "What banks earn on loans minus what they pay on deposits."),
            ReportLine(label: "CET1 capital ratio", value: "13.2%", expected: "13.0%", meaning: "The capital cushion; well above requirements."),
        ],
        reading: [
            "Credit quality is the early warning: banks see consumers and businesses struggle before the economy data does.",
            "Provisions are estimates; they rise ahead of losses and can be released later.",
            "Look at capital: higher losses with strong capital is a slowdown, not a crisis.",
            "Bank results kick off each earnings season and set the tone.",
        ],
        terms: [
            ReportTerm(term: "Provision", definition: "An expense for expected future loan losses."),
            ReportTerm(term: "Charge-off", definition: "A loan written off as uncollectable."),
            ReportTerm(term: "Net interest margin", definition: "Interest earned on assets minus interest paid, as a share of assets."),
            ReportTerm(term: "CET1", definition: "Common Equity Tier 1 capital as a share of risk-weighted assets — the main measure of bank strength."),
        ],
        moves: [
            MarketMove(asset: "{company}", move: "−7% (hypothetical)", why: "This account's largest financial stock: lower earnings, credit worries."),
            MarketMove(asset: "Financials sector", move: "−2.5%", why: "Read-across to other lenders."),
            MarketMove(asset: "Stocks (S&P 500)", move: "−0.7%", why: "Consumer-credit worries."),
            MarketMove(asset: "Corporate bond spreads", move: "+0.08 points", why: "More credit risk priced."),
        ],
        marketMove: -0.005, rateMove: -0.0004,
        sectorMoves: ["Financials": -0.020, "Consumer Discretionary": -0.006],
        companyMoves: [MarketReport.company: -0.07],
        single: MarketReport.company, companySector: "Financials",
        reactions: [Reactions.sellAll, Reactions.rotateBonds, Reactions.buyDip, Reactions.everyTime],
        takeaways: [
            "Bank earnings and credit data are early signs of stress in household and business finances.",
            "Rising losses in one part of credit are part of every cycle; capital ratios say whether it's a slowdown or a crisis.",
            "Banks are about a tenth of the index here; the account's exposure is the sum of its holdings, not the headline.",
        ],
        suggestedSample: "SAMPLE_CORE_SATELLITE",
        tier: 6, publisher: "Bank quarterly results; Federal Reserve weekly bank data (H.8); credit bureaus", frequency: "Quarterly results; weekly loan data",
        keyMetrics: ["Bank earnings", "Loan growth", "Credit quality (provisions, charge-offs)", "Capital ratios"],
        whyCare: ["Credit quality warns of stress before the economy data does."],
        drivers: [.profits, .growth], impact: 1,
        context: ReportSeries("Credit-card net charge-off rate", unit: "%",
                              [("2019", 3.6), ("2020", 3.4), ("2021", 2.2), ("2022", 2.4), ("2023", 3.5), ("2024", 4.2), ("2025", 4.3), ("2026", 4.6)],
                              note: "Illustrative, shaped like the post-2021 normalisation from unusually low losses."),
        industry: "Financials")

    static let housing = MarketReport(
        id: "housing", title: "Housing Starts & Home Sales (Housing)", symbol: "house",
        source: "New residential construction and existing-home sales — illustrative, in the shape of the Census Bureau and realtors' monthly reports",
        headline: "Housing starts drop 11%; permits at a five-year low as mortgage rates hold near 7%",
        lines: [
            ReportLine(label: "Housing starts (annual rate)", value: "1.21 million (−11%)", expected: "1.34 million", meaning: "New homes on which construction began."),
            ReportLine(label: "Building permits", value: "1.28 million", expected: "1.38 million", meaning: "Leads starts by a month or two."),
            ReportLine(label: "Existing home sales", value: "3.84 million", expected: "3.95 million", meaning: "Resales — most of the market; low when owners are locked into cheap mortgages."),
            ReportLine(label: "Median existing-home price", value: "$412,000 (+1.8% y/y)", expected: "—", meaning: "Prices still rising slowly despite low sales: little supply."),
            ReportLine(label: "30-year mortgage rate", value: "6.9%", expected: "—", meaning: "Moves with the 10-year Treasury yield plus a spread."),
        ],
        reading: [
            "Housing is one of the most interest-rate-sensitive parts of the economy.",
            "Permits lead starts; starts lead construction jobs and spending on furniture and appliances.",
            "Low sales with firm prices means few sellers, not collapsing demand.",
            "Builders, home retailers, building materials and mortgage lenders move on these reports.",
        ],
        terms: [
            ReportTerm(term: "Housing starts", definition: "Residential construction begun in the month, at an annual rate."),
            ReportTerm(term: "Lock-in effect", definition: "Owners with low fixed-rate mortgages don't move, which keeps resale supply low."),
            ReportTerm(term: "Annual rate", definition: "The month's number scaled to a full year."),
        ],
        moves: [
            MarketMove(asset: "Home-related stocks", move: "−2.5%", why: "Home-improvement retailers, residential REITs, builders, materials."),
            MarketMove(asset: "Stocks (S&P 500)", move: "−0.4%", why: "A small share of the index."),
            MarketMove(asset: "10-year Treasury yield", move: "−0.04 points", why: "Slower growth."),
        ],
        marketMove: -0.003, rateMove: -0.0004,
        sectorMoves: ["Real Estate": -0.015, "Materials": -0.010, "Consumer Discretionary": -0.006],
        reactions: [Reactions.sellHalf, Reactions.rotateBonds, Reactions.buyDip, Reactions.everyTime],
        takeaways: [
            "Housing data shows the interest-rate channel at work: higher mortgage rates slow building, then spending.",
            "Your home is probably your largest real-estate exposure; an account's REITs are a small part of the picture.",
            "Sector weakness that hits a few holdings is what diversification is for.",
        ],
        suggestedSample: "SAMPLE_INCOME",
        tier: 6, publisher: "U.S. Census Bureau (new residential construction); realtors' association (existing-home sales)", frequency: "Monthly",
        keyMetrics: ["Housing starts", "Building permits", "Existing home sales", "Prices and mortgage rates"],
        whyCare: ["The most rate-sensitive part of the economy; leads construction and home-related spending."],
        drivers: [.growth, .rates], impact: 1,
        context: ReportSeries("Housing starts, annual rate", unit: "million",
                              [("May", 1.38), ("Jun", 1.35), ("Jul", 1.40), ("Aug", 1.33), ("Sep", 1.36), ("Oct", 1.21)]),
        industry: "Housing")

    static let energy = MarketReport(
        id: "energy", title: "EIA Petroleum Status (Energy)", symbol: "fuelpump",
        source: "Weekly Petroleum Status Report and OPEC monthly report — illustrative, in the shape of the EIA release (Wednesday 10:30 a.m. ET)",
        headline: "Crude inventories jump 9.6 million barrels as OPEC+ signals higher output; oil falls 6%",
        lines: [
            ReportLine(label: "Crude oil inventories", value: "+9.6 million bbl", expected: "−1.2 million", meaning: "Weekly change in U.S. commercial crude stocks; a build means supply exceeds demand."),
            ReportLine(label: "Gasoline inventories", value: "+2.1 million bbl", expected: "−0.5 million", meaning: "Fuel demand softer than expected."),
            ReportLine(label: "Refinery utilisation", value: "86.4%", expected: "89.0%", meaning: "Refiners running below capacity."),
            ReportLine(label: "OPEC+ production plan", value: "+400,000 bbl/day", expected: "+150,000", meaning: "The producer group adding supply."),
            ReportLine(label: "Oil price (WTI)", value: "$64.20 (−6.1%)", expected: "—", meaning: "The U.S. benchmark crude price."),
        ],
        reading: [
            "Weekly inventories are noisy; analysts watch the trend versus the five-year seasonal average.",
            "OPEC's plans and the global economy matter more for prices than any one week.",
            "Cheaper oil hurts energy producers and helps airlines, transport and consumers.",
            "Energy is a small share of the index but swings most with commodity prices.",
        ],
        terms: [
            ReportTerm(term: "Inventory build / draw", definition: "Stocks rising (supply above demand) or falling."),
            ReportTerm(term: "OPEC+", definition: "The oil producers' group and its allies, which coordinate output targets."),
            ReportTerm(term: "WTI", definition: "West Texas Intermediate: the U.S. crude oil benchmark."),
        ],
        moves: [
            MarketMove(asset: "Oil producers", move: "−5.5%", why: "Revenue follows the oil price."),
            MarketMove(asset: "Pipelines", move: "−3%", why: "Pipelines earn fees on volumes, so they fall less than producers."),
            MarketMove(asset: "{company}", move: "−4% (hypothetical)", why: "This account's largest energy stock, assumed to move with the sector."),
            MarketMove(asset: "Energy sector", move: "−4%", why: "Producers, services, renewables mixed."),
            MarketMove(asset: "Transport and consumer stocks", move: "+0.8%", why: "Lower fuel costs."),
            MarketMove(asset: "Stocks (S&P 500)", move: "−0.1%", why: "Energy is a small weight; others gain."),
            MarketMove(asset: "Inflation breakevens", move: "−0.05 points", why: "Cheaper energy lowers expected inflation."),
        ],
        marketMove: -0.001, rateMove: -0.0003,
        sectorMoves: ["Energy": -0.040, "Industrials": 0.006, "Consumer Discretionary": 0.006],
        companyMoves: [MarketReport.company: -0.04],
        single: MarketReport.company, companySector: "Energy",
        reactions: [Reactions.sellSingle("{ticker}"), Reactions.doubleDown("{ticker}"), Reactions.sellSingleWait("{ticker}"), Reactions.sellHalf],
        takeaways: [
            "Energy reports move a small sector a lot and the index a little — in both directions, because energy costs are other companies' revenue.",
            "Commodity-driven stocks are among the most volatile; their weight in an index rises and falls with the price.",
            "Weekly inventory data is for traders; a long-term plan does not need a view on oil.",
        ],
        suggestedSample: "SAMPLE_INCOME",
        tier: 6, publisher: "U.S. Energy Information Administration (EIA); OPEC Monthly Oil Market Report", frequency: "Weekly (EIA, Wednesday); monthly (OPEC)",
        keyMetrics: ["Crude and gasoline inventories", "Refinery utilisation", "OPEC production", "Oil price"],
        whyCare: ["Drives energy stocks, inflation expectations and costs across the economy."],
        drivers: [.inflation, .profits], impact: 1,
        context: ReportSeries("Weekly crude inventory change", unit: "million bbl", kind: .bar,
                              [("W1", -2.4), ("W2", 1.1), ("W3", -3.6), ("W4", 0.8), ("W5", -1.9), ("W6", 2.7), ("W7", 0.4), ("W8", 9.6)], reference: 0),
        industry: "Energy")
}
