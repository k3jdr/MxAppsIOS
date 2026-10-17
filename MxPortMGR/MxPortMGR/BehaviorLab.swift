//
//  BehaviorLab.swift
//  MxPortMGR
//
//  The long-horizon simulator behind the market-report walkthroughs: what happens over the following years if you
//  act on a report — sell, buy, rotate — compared with staying with the plan, on the same simulated futures (common
//  random numbers, so the only difference is the decision).
//
//  The account is four sleeves — broad stocks, one single stock, bonds, cash — with the weights, cost basis and
//  holding periods of the sample. Stocks follow a daily model with volatility clustering and fat tails (GARCH(1,1)),
//  so calm and stormy stretches alternate and the best days tend to come right after the worst ones; bonds and the
//  single stock are tied to it. Optional stress paths shaped like past episodes start the future with a fast crash
//  and recovery, a long bear market, or stocks and bonds falling together. Every trade pays a spread; in a taxable
//  account every sale realises gains, taxed short- or long-term by how long the sleeve was held (losses carry
//  forward). Illustrative only: nominal dollars, no dividends or inflation modelled separately, not a forecast.
//

import Foundation

nonisolated enum Sleeve: Int, CaseIterable, Sendable {
    case stocks, single, bonds, cash
    var title: String {
        switch self {
        case .stocks: "Stocks"
        case .single: "Single stock"
        case .bonds: "Bonds"
        case .cash: "Cash"
        }
    }
}

nonisolated struct Move: Hashable, Sendable {
    var from: Sleeve
    var to: Sleeve
    var fraction: Double
}

nonisolated struct Reaction: Identifiable, Hashable, Sendable {
    enum After: String, Sendable {
        /// Back to the plan's weights after the months set in the lab.
        case revert
        /// The new weights become the plan.
        case permanent
        /// A one-off tilt the yearly rebalance takes back to the plan.
        case rebalanceToPlan
    }
    var id: String
    var title: String
    var symbol: String
    var summary: String
    var moves: [Move] = []
    var after: After = .rebalanceToPlan
    /// Repeats the moves every time stocks fall this far from their high (and reverts after the months set).
    var repeatOnDrawdown: Double? = nil
    var isPlan: Bool { moves.isEmpty }

    static let plan = Reaction(id: "plan", title: "Stay with the plan", symbol: "checkmark.seal",
                               summary: "Do nothing today; rebalance to the plan's weights once a year.")
}

nonisolated enum Scenario: String, CaseIterable, Identifiable, Sendable {
    case random = "Random futures"
    case fastCrash = "Fast crash and recovery (shaped like 2020)"
    case longBear = "Long bear market (shaped like 2007–09)"
    case bothFall = "Stocks and bonds fall together (shaped like 2022)"
    var id: String { rawValue }

    var detail: String {
        switch self {
        case .random: "Each future starts from today's report and is drawn from the model: about 7.5% a year from stocks on average, with calm and stormy years."
        case .fastCrash: "Stocks fall about a third in five weeks, then regain the old high within about five months — the shape of early 2020."
        case .longBear: "Stocks fall about half over eighteen months and take about four more years to regain the old high — the shape of 2007–09."
        case .bothFall: "Stocks fall a quarter and bonds about 15% over ten months as rates rise, then recover over a year — the shape of 2022."
        }
    }
}

nonisolated struct SimSettings: Sendable, Equatable {
    var years = 20
    var paths = 300
    var monthsOut = 6
    /// Spread and commission per dollar traded.
    var costRate = 0.0015
    var taxable = true
    var longTermRate = 0.15
    var shortTermRate = 0.32
    var scenario: Scenario = .random
    var seed: UInt64 = 1
}

/// The account at the start: sleeve weights, unrealised gain as a share of value, and how many days each sleeve has been held.
nonisolated struct SimAccount: Sendable, Equatable {
    var value: Double
    var weights: [Double]
    var gainShare: [Double]
    var heldDays: [Double]
    var singleTicker: String?

    init(portfolio p: Portfolio, single: String?, today: Date = Date()) {
        value = p.total
        var w = [Double](repeating: 0, count: 4), gains = w, basis = w, held = w, values = w
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        for h in p.holdings {
            guard let s = h.security else { continue }
            let share = p.weight(h)
            var parts: [(Sleeve, Double)] = []
            if let single, s.ticker == single {
                parts = [(.single, 1)]
            } else {
                let classes = s.lookThrough.map { Portfolio.classes(of: $0) } ?? [s.assetClass: 1]
                for (c, x) in classes { parts.append((c == .equity ? .stocks : c == .bond ? .bonds : .cash, x)) }
            }
            let days = h.lots.isEmpty ? 400.0 : h.lots.reduce(0.0) { acc, lot in
                let d = formatter.date(from: lot.acquired).map { today.timeIntervalSince($0) / 86400 } ?? 400
                return acc + lot.share * d
            }
            for (sleeve, x) in parts {
                let i = sleeve.rawValue
                w[i] += share * x
                values[i] += h.value * x
                basis[i] += h.costBasis * x
                held[i] += h.value * x * days * 252 / 365
            }
        }
        for i in 0..<4 where values[i] > 0 {
            gains[i] = 1 - basis[i] / values[i]
            held[i] /= values[i]
        }
        let total = w.reduce(0, +)
        weights = total > 0 ? w.map { $0 / total } : [1, 0, 0, 0]
        gainShare = p.account.isTaxable ? gains : [0, 0, 0, 0]
        heldDays = held
        singleTicker = single
    }
}

nonisolated struct SimOutcome: Identifiable, Sendable {
    var id: String { reaction.id }
    var reaction: Reaction
    var medianEnd: Double
    var p10End: Double
    var p90End: Double
    var annualReturn: Double
    /// Monthly medians and 10th / 90th percentiles of the account value.
    var path: [Double]
    var low: [Double]
    var high: [Double]
    var medianTaxes: Double
    var medianCosts: Double
    var trackingError: Double
    var missedBestDays: Double
    var aheadOfPlan: Double
    var medianMaxDrawdown: Double
    var trades: Double
}

nonisolated struct SimResult: Sendable {
    var settings: SimSettings
    var start: Double
    var outcomes: [SimOutcome]
    /// Annualised stock return when the best N days are missed (averaged over futures): (N, return).
    var missingBest: [(days: Int, annual: Double)]
    var plan: SimOutcome { outcomes.first { $0.reaction.isPlan }! }
}

nonisolated enum BehaviorLab {
    static let days = 252

    private struct Market {
        var stocks: [Double]
        var single: [Double]
        var bonds: [Double]
        var cash: Double
    }

    /// One simulated future of daily returns, starting the day after the report.
    private static func market(_ settings: SimSettings, _ rng: inout SeededRandom, singleBeta: Double, singleVol: Double) -> Market {
        let n = settings.years * days
        var stocks = [Double](repeating: 0, count: n), single = stocks, bonds = stocks
        let target = 0.17 * 0.17 / Double(days)
        let a = 0.09, b = 0.89, omega = target * (1 - a - b)
        var variance = target * 2.2       // just after a scary report volatility is high
        let mean = 0.075 / Double(days), bondMean = 0.040 / Double(days), bondVol = 0.055 / Double(days).squareRoot()
        let ownVol = singleVol / Double(days).squareRoot()
        var drift = [Double](repeating: 0, count: n), bondDrift = drift
        func episode(_ into: inout [Double], _ start: Int, _ length: Int, _ total: Double) {
            let d = log(total) / Double(length)
            for t in start..<min(n, start + length) { into[t] += d }
        }
        switch settings.scenario {
        case .random: break
        case .fastCrash:
            episode(&drift, 0, 23, 0.66); episode(&drift, 23, 105, 1 / 0.66)
            variance = target * 6
        case .longBear:
            episode(&drift, 0, 360, 0.50); episode(&drift, 360, 1000, 2.0)
            variance = target * 3
        case .bothFall:
            episode(&drift, 0, 200, 0.75); episode(&drift, 200, 280, 1 / 0.75)
            episode(&bondDrift, 0, 200, 0.85); episode(&bondDrift, 200, 500, 1 / 0.92)
            variance = target * 3
        }
        for t in 0..<n {
            var z = rng.normal()
            if rng.uniform() < 0.04 { z *= 2.2 }
            z /= 1.074
            let r = (drift[t] != 0 ? drift[t] : mean) + variance.squareRoot() * z
            variance = omega + a * r * r + b * variance
            stocks[t] = r
            bonds[t] = (bondDrift[t] != 0 ? bondDrift[t] : bondMean) + bondVol * (-0.10 * z + 0.995 * rng.normal())
            var own = ownVol * rng.normal()
            if t % 63 == 62 { own += 0.06 * rng.normal() }   // an earnings day every quarter
            single[t] = singleBeta * r + own + (mean - singleBeta * mean)
        }
        return Market(stocks: stocks, single: single, bonds: bonds, cash: 0.03 / Double(days))
    }

    private struct Book {
        var value: [Double]
        var basis: [Double]
        var held: [Double]
        var lossCarry = 0.0
        var taxes = 0.0
        var costs = 0.0
        var trades = 0

        var total: Double { value.reduce(0, +) }

        mutating func trade(_ from: Int, _ to: Int, _ amount: Double, _ s: SimSettings) {
            let amount = min(amount, value[from])
            guard amount > 1 else { return }
            trades += 1
            let cost = amount * s.costRate
            var tax = 0.0
            if s.taxable && from != Sleeve.cash.rawValue {
                let soldBasis = value[from] > 0 ? basis[from] * amount / value[from] : 0
                basis[from] -= soldBasis
                var gain = amount - soldBasis
                if gain > 0 {
                    let used = min(gain, lossCarry)
                    lossCarry -= used
                    gain -= used
                    tax = gain * (held[from] < 252 ? s.shortTermRate : s.longTermRate)
                } else {
                    lossCarry -= gain
                }
            } else if from != Sleeve.cash.rawValue {
                basis[from] -= value[from] > 0 ? basis[from] * amount / value[from] : 0
            }
            value[from] -= amount
            let received = amount - cost - tax
            // The holding period of what's bought starts now; mixed with what was there by value.
            held[to] = value[to] + received > 0 ? (held[to] * value[to]) / (value[to] + received) : 0
            value[to] += received
            basis[to] += received
            costs += cost
            taxes += tax
        }

        /// Trades to the given weights, sells first.
        mutating func rebalance(to w: [Double], _ s: SimSettings) {
            let t = total
            var excess = value.indices.map { value[$0] - w[$0] * t }
            for i in excess.indices where excess[i] > t * 0.002 {
                for j in excess.indices where excess[j] < -t * 0.002 && excess[i] > 1 {
                    let amount = min(excess[i], -excess[j])
                    trade(i, j, amount, s)
                    excess[i] -= amount
                    excess[j] += amount
                }
            }
        }

        mutating func apply(_ moves: [Move], _ s: SimSettings) {
            let start = value
            for m in moves { trade(m.from.rawValue, m.to.rawValue, start[m.from.rawValue] * m.fraction, s) }
        }
    }

    /// Simulates the plan and every reaction on the same futures. `shock` is today's move of each sleeve (already
    /// happened when you decide).
    static func run(account: SimAccount, shock: [Double], reactions: [Reaction], settings: SimSettings,
                    singleBeta: Double = 1.25, singleVol: Double = 0.30) -> SimResult {
        let strategies = [Reaction.plan] + reactions.filter { !$0.isPlan }
        let n = settings.years * days
        let months = n / 21
        var ends = [[Double]](repeating: [], count: strategies.count)
        var taxes = ends, costs = ends, te = ends, missed = ends, drawdowns = ends, tradeCounts = ends
        var paths = [[[Double]]](repeating: [[Double]](repeating: [], count: months + 1), count: strategies.count)
        var ahead = [Double](repeating: 0, count: strategies.count)
        var missingBest: [Int: Double] = [0: 0, 5: 0, 10: 0, 20: 0, 30: 0]

        for p in 0..<settings.paths {
            var rng = SeededRandom(seed: settings.seed &* 1_000_003 &+ UInt64(p))
            let m = market(settings, &rng, singleBeta: singleBeta, singleVol: singleVol)
            let best = Array(m.stocks.indices.sorted { m.stocks[$0] > m.stocks[$1] }.prefix(10))
            let bestSet = Set(best)
            // Missing the best days of the stock market itself.
            let sortedReturns = m.stocks.sorted(by: >)
            for k in missingBest.keys {
                let logSum = m.stocks.reduce(0) { $0 + log1p($1) } - sortedReturns.prefix(k).reduce(0) { $0 + log1p($1) }
                missingBest[k]! += (exp(logSum / Double(settings.years)) - 1) / Double(settings.paths)
            }
            var planDaily = [Double](repeating: 0, count: n)
            var planEnd = 0.0
            for (k, reaction) in strategies.enumerated() {
                let startValue = account.value
                let w0 = account.weights
                var book = Book(value: w0.map { $0 * startValue },
                                basis: w0.indices.map { w0[$0] * startValue * (1 - account.gainShare[$0]) },
                                held: account.heldDays)
                for i in 0..<4 { book.value[i] *= 1 + shock[i] }
                var target = w0
                book.apply(reaction.moves, settings)
                if reaction.after == .permanent { let t = book.total; target = book.value.map { $0 / t } }
                var outUntil: Int? = reaction.after == .revert && !reaction.isPlan ? settings.monthsOut * 21 : nil
                var level = 1.0, peak = 1.0
                var exposurePlan = w0[0] + w0[1]
                var missedDays = 0.0
                var prev = book.total, maxValue = prev, maxDD = 0.0
                var diffSum = 0.0, diffSq = 0.0
                paths[k][0].append(prev)
                for t in 0..<n {
                    let r = [m.stocks[t], m.single[t], m.bonds[t], m.cash]
                    let exposure = book.total > 0 ? (book.value[0] + book.value[1]) / book.total : 0
                    if bestSet.contains(t), exposure < 0.5 * exposurePlan { missedDays += 1 }
                    for i in 0..<4 { book.value[i] *= 1 + r[i]; book.held[i] += 1 }
                    level *= 1 + m.stocks[t]
                    peak = max(peak, level)
                    if let until = outUntil, t >= until {
                        book.rebalance(to: target, settings)
                        outUntil = nil
                        peak = level
                    } else if outUntil == nil, let dd = reaction.repeatOnDrawdown, level < peak * (1 - dd) {
                        book.apply(reaction.moves, settings)
                        outUntil = t + settings.monthsOut * 21
                    } else if outUntil == nil, t % days == days - 1 {
                        book.rebalance(to: target, settings)
                    }
                    let v = book.total
                    let daily = v / prev - 1
                    if reaction.isPlan {
                        planDaily[t] = daily
                        exposurePlan = book.total > 0 ? (book.value[0] + book.value[1]) / book.total : exposurePlan
                    } else {
                        let d = daily - planDaily[t]
                        diffSum += d; diffSq += d * d
                    }
                    prev = v
                    maxValue = max(maxValue, v)
                    maxDD = max(maxDD, 1 - v / maxValue)
                    if (t + 1) % 21 == 0, (t + 1) / 21 <= months { paths[k][(t + 1) / 21].append(v) }
                }
                let end = book.total
                if reaction.isPlan { planEnd = end } else if end > planEnd { ahead[k] += 1 }
                ends[k].append(end)
                taxes[k].append(book.taxes)
                costs[k].append(book.costs)
                missed[k].append(missedDays)
                drawdowns[k].append(maxDD)
                tradeCounts[k].append(Double(book.trades))
                let meanDiff = diffSum / Double(n)
                te[k].append(((diffSq / Double(n) - meanDiff * meanDiff) * Double(days)).squareRoot())
            }
        }

        func quantile(_ x: [Double], _ q: Double) -> Double {
            guard !x.isEmpty else { return 0 }
            let s = x.sorted()
            return s[min(s.count - 1, max(0, Int(q * Double(s.count - 1))))]
        }
        func mean(_ x: [Double]) -> Double { x.isEmpty ? 0 : x.reduce(0, +) / Double(x.count) }
        let outcomes = strategies.enumerated().map { k, reaction in
            let med = quantile(ends[k], 0.5)
            return SimOutcome(reaction: reaction, medianEnd: med, p10End: quantile(ends[k], 0.1), p90End: quantile(ends[k], 0.9),
                              annualReturn: pow(med / account.value, 1 / Double(settings.years)) - 1,
                              path: paths[k].map { quantile($0, 0.5) }, low: paths[k].map { quantile($0, 0.1) },
                              high: paths[k].map { quantile($0, 0.9) },
                              medianTaxes: quantile(taxes[k], 0.5), medianCosts: quantile(costs[k], 0.5),
                              trackingError: reaction.isPlan ? 0 : quantile(te[k], 0.5), missedBestDays: mean(missed[k]),
                              aheadOfPlan: reaction.isPlan ? 0 : ahead[k] / Double(settings.paths),
                              medianMaxDrawdown: quantile(drawdowns[k], 0.5), trades: mean(tradeCounts[k]))
        }
        return SimResult(settings: settings, start: account.value, outcomes: outcomes,
                         missingBest: missingBest.keys.sorted().map { ($0, missingBest[$0]!) })
    }
}
