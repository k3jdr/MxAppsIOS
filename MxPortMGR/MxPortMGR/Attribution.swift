//
//  Attribution.swift
//  MxPortMGR
//
//  Performance attribution over an illustrative market year, by the method of the analytics service's
//  POST /attribution (Services/analytics): monthly sector Brinson-Fachler (or Brinson-Hood-Beebower) effects —
//  allocation, selection, interaction — linked over the year with Carino factors so they add up to the compounded
//  active return. Holdings drift with their returns month by month (a trader's are replaced each month); a
//  security without a return in a month is a data gap: its weight is left out of that month and reported.
//

import Foundation

/// Twelve months of illustrative security returns from the factor model: a scripted market path (a spring sell-off
/// and recovery), scripted interest-rate moves, and seeded sector and company surprises.
nonisolated enum MarketHistory {
    static let months = ["2025-11", "2025-12", "2026-01", "2026-02", "2026-03", "2026-04",
                         "2026-05", "2026-06", "2026-07", "2026-08", "2026-09", "2026-10"]
    static let market: [Double] = [0.021, -0.014, 0.030, -0.065, -0.032, 0.048, 0.025, 0.012, -0.020, 0.036, 0.019, 0.008]
    /// Change in yields each month, in decimal (0.0015 = 0.15 points).
    static let rates: [Double] = [0.0010, 0.0015, -0.0005, 0.0020, 0.0025, -0.0010, -0.0020, 0, 0.0005, -0.0015, -0.0010, 0.0005]

    /// returns[month][base index]
    static let returns: [[Double]] = {
        var rng = SeededRandom(seed: 2026)
        let sectorShock = months.map { _ in Dictionary(uniqueKeysWithValues: Universe.sectors.map { ($0, rng.normal() * Universe.sectorVol / 12.0.squareRoot()) }) }
        return months.indices.map { t in
            Universe.base.map { s in
                let own = rng.normal() * s.idioVol / 12.0.squareRoot()
                switch s.assetClass {
                case .cash: return Universe.riskFree / 12
                case .bond: return s.yield / 12 + s.rateBeta * rates[t] + s.beta * market[t] + own
                case .equity:
                    return Universe.riskFree / 12 + s.beta * (market[t] - Universe.riskFree / 12) + s.rateBeta * rates[t]
                        + (sectorShock[t][s.sector] ?? 0) + own
                }
            }
        }
    }()
}

nonisolated struct AttributionResult: Sendable {
    nonisolated struct Group: Hashable, Sendable, Identifiable {
        var id: String { group }
        var group: String
        var portfolioWeight, benchmarkWeight, activeWeight: Double
        var allocation, selection, interaction: Double
        var total: Double { allocation + selection + interaction }
    }
    nonisolated struct Period: Hashable, Sendable, Identifiable {
        var id: String { month }
        var month: String
        var portfolioReturn, benchmarkReturn: Double
        var allocation, selection, interaction: Double
        var activeReturn: Double { portfolioReturn - benchmarkReturn }
    }
    nonisolated struct Contributor: Hashable, Sendable, Identifiable {
        var id: String { ticker }
        var ticker: String
        var sector: String
        var portfolioWeight, benchmarkWeight, contribution: Double
    }

    var engine: String
    var method: String
    var portfolioReturn, benchmarkReturn: Double
    var activeReturn: Double { portfolioReturn - benchmarkReturn }
    var allocation, selection, interaction, residual: Double
    var groups: [Group]
    var periods: [Period]
    var top: [Contributor]
    var bottom: [Contributor]
    var dataGap: Double
    var recommendation: String
    var reasons: [String]
    var highlight: String
    var assumptions: [String]
}

nonisolated enum AttributionEngine {
    enum Method: String, CaseIterable, Sendable {
        case brinsonFachler = "brinson-fachler", brinsonHoodBeebower = "brinson-hood-beebower"
        var title: String { self == .brinsonFachler ? "Brinson-Fachler" : "Brinson-Hood-Beebower" }
    }

    /// A drifting set of positions: each with its value and its inner weights over the base securities.
    private struct Book {
        var values: [Double]
        var inner: [[Double]]
        /// Rebalanced to these shares at each month start (a balanced benchmark); nil drifts.
        var fixedShares: [Double]?

        var weights: [Double] {
            let total = values.reduce(0, +)
            var w = [Double](repeating: 0, count: Universe.base.count)
            guard total > 0 else { return w }
            for (v, u) in zip(values, inner) { for i in u.indices { w[i] += v / total * u[i] } }
            return w
        }

        mutating func grow(_ r: [Double]) {
            for k in values.indices {
                let u = inner[k]
                let ret = u.indices.reduce(0) { $0 + u[$1] * r[$1] }
                values[k] *= 1 + ret
                let grown = u.indices.map { u[$0] * (1 + r[$0]) }
                let s = grown.reduce(0, +)
                inner[k] = s > 0 ? grown.map { $0 / s } : u
            }
            if let fixed = fixedShares {
                let total = values.reduce(0, +)
                values = fixed.map { $0 * total }
            }
        }
    }

    private static func vector(_ weights: [String: Double]) -> [Double] {
        Universe.base.map { weights[$0.ticker] ?? 0 }
    }

    private static func benchmarkBook(_ code: String) -> Book {
        switch code {
        case "MX6040", "MX3070":
            let eq = code == "MX6040" ? 0.6 : 0.3
            return Book(values: [eq, 1 - eq], inner: [vector(Universe.equityIndexWeights), vector(Universe.bondIndexWeights)], fixedShares: [eq, 1 - eq])
        default:
            return Book(values: [1], inner: [vector(Universe.equityIndexWeights)], fixedShares: nil)
        }
    }

    private static func portfolioBook(_ p: Portfolio) -> Book {
        var values: [Double] = [], inner: [[Double]] = []
        for h in p.holdings {
            guard let s = h.security else { continue }
            values.append(h.value)
            inner.append(vector(s.lookThrough ?? [s.ticker: 1]))
        }
        return Book(values: values, inner: inner, fixedShares: nil)
    }

    /// A trader's holdings: each month a different handful of speculative names and some cash.
    private static func traderWeights(month: Int) -> [Double] {
        var rng = SeededRandom(seed: UInt64(700 + month))
        let pool = ["ROV", "QBT", "GNM", "SOL", "CLD", "GMR", "ADV", "STM", "ORE", "TRX", "SRC", "HLX", "NWD", "PTR"]
        var picks = pool.shuffled(using: &rng).prefix(8).map { ($0, 0.5 + rng.uniform()) }
        let s = picks.reduce(0) { $0 + $1.1 }
        picks = picks.map { ($0.0, $0.1 / s * 0.88) }
        return vector(Dictionary(uniqueKeysWithValues: picks + [("CASH", 0.12)]))
    }

    /// Look-through weights of the account and of its benchmark at the start of each month and at the end of the
    /// year (13 snapshots), holding today's positions through the illustrative year without trading.
    static func drift(_ p: Portfolio) -> (account: [[Double]], benchmark: [[Double]]) {
        var pBook = portfolioBook(p), bBook = benchmarkBook(p.benchmark)
        var a = [pBook.weights], b = [bBook.weights]
        for r in MarketHistory.returns {
            pBook.grow(r)
            bBook.grow(r)
            a.append(pBook.weights)
            b.append(bBook.weights)
        }
        return (a, b)
    }

    /// Ex-ante tracking error of weights over the base securities against a benchmark.
    static func trackingError(_ w: [Double], _ b: [Double]) -> Double {
        let d = w.indices.map { w[$0] - b[$0] }
        var v = 0.0
        for i in d.indices where d[i] != 0 { for j in d.indices where d[j] != 0 { v += d[i] * d[j] * Universe.covariance[i][j] } }
        return max(v, 0).squareRoot()
    }

    /// One month of the illustrative year: security returns (nil where missing: a data gap) and the account's and
    /// the benchmark's look-through weights at the start of the month, over the base securities.
    nonisolated struct Month: Sendable {
        var month: String
        var returns: [Double?]
        var portfolio, benchmark: [Double]
    }

    /// The monthly inputs attribution works on — what the analytics service is sent inline.
    static func months(_ p: Portfolio) -> [Month] {
        var pBook = portfolioBook(p), bBook = benchmarkBook(p.benchmark)
        var out: [Month] = []
        for t in MarketHistory.months.indices {
            var r: [Double?] = MarketHistory.returns[t]
            for (ticker, from) in p.missingFrom where t >= from {
                if let i = Universe.baseIndex[ticker] { r[i] = nil }
            }
            out.append(Month(month: MarketHistory.months[t], returns: r,
                             portfolio: p.trading == "trader" ? traderWeights(month: t) : pBook.weights, benchmark: bBook.weights))
            if p.trading != "trader" { pBook.grow(MarketHistory.returns[t]) }
            bBook.grow(MarketHistory.returns[t])
        }
        return out
    }

    static func run(_ p: Portfolio, method: Method = .brinsonFachler) -> AttributionResult {
        let base = Universe.base
        let sectors = Array(Set(base.map(\.sector))).sorted()
        var periods: [(rp: Double, rb: Double, groups: [String: (a: Double, s: Double, i: Double)], wp: [Double], wb: [Double])] = []
        var contrib = [Double](repeating: 0, count: base.count)
        var gap = 0.0
        var sumWp = [Double](repeating: 0, count: base.count), sumWb = sumWp
        for month in months(p) {
            let r = month.returns.map { $0 ?? 0 }, ok = month.returns.map { $0 != nil }
            let rawP = month.portfolio, rawB = month.benchmark
            gap = max(gap, rawP.indices.filter { !ok[$0] }.reduce(0) { $0 + rawP[$1] })
            func clean(_ w: [Double]) -> [Double] {
                let kept = w.indices.map { ok[$0] ? w[$0] : 0 }
                let s = kept.reduce(0, +)
                return s > 0 ? kept.map { $0 / s } : kept
            }
            let wp = clean(rawP), wb = clean(rawB)
            for i in base.indices { sumWp[i] += rawP[i]; sumWb[i] += rawB[i] }     // reported: average start weights, as held
            let rp = zip(wp, r).reduce(0) { $0 + $1.0 * $1.1 }, rb = zip(wb, r).reduce(0) { $0 + $1.0 * $1.1 }
            for i in base.indices { contrib[i] += (wp[i] - wb[i]) * r[i] }
            var groups: [String: (a: Double, s: Double, i: Double)] = [:]
            for g in sectors {
                let m = base.indices.filter { base[$0].sector == g }
                let wpg = m.reduce(0) { $0 + wp[$1] }, wbg = m.reduce(0) { $0 + wb[$1] }
                var rbg = wbg > 0 ? m.reduce(0) { $0 + wb[$1] * r[$1] } / wbg : 0
                let rpg = wpg > 0 ? m.reduce(0) { $0 + wp[$1] * r[$1] } / wpg : rbg
                if wbg == 0 { rbg = rpg }
                let ref = method == .brinsonFachler ? rb : 0
                groups[g] = ((wpg - wbg) * (rbg - ref), wbg * (rpg - rbg), (wpg - wbg) * (rpg - rbg))
            }
            periods.append((rp, rb, groups, wp, wb))
        }

        // Carino linking.
        let rpTotal = periods.reduce(1) { $0 * (1 + $1.rp) } - 1
        let rbTotal = periods.reduce(1) { $0 * (1 + $1.rb) } - 1
        func k(_ rp: Double, _ rb: Double) -> Double {
            abs(rp - rb) > 1e-12 ? (log1p(rp) - log1p(rb)) / (rp - rb) : 1 / (1 + rp)
        }
        let bigK = k(rpTotal, rbTotal)
        var byGroup = Dictionary(uniqueKeysWithValues: sectors.map { ($0, (a: 0.0, s: 0.0, i: 0.0)) })
        var rows: [AttributionResult.Period] = []
        for (t, period) in periods.enumerated() {
            let scale = k(period.rp, period.rb) / bigK
            var e = (a: 0.0, s: 0.0, i: 0.0)
            for (g, x) in period.groups {
                byGroup[g]!.a += x.a * scale
                byGroup[g]!.s += x.s * scale
                byGroup[g]!.i += x.i * scale
                e.a += x.a; e.s += x.s; e.i += x.i
            }
            rows.append(.init(month: MarketHistory.months[t], portfolioReturn: period.rp, benchmarkReturn: period.rb,
                              allocation: e.a, selection: e.s, interaction: e.i))
        }
        let n = Double(periods.count)
        let avgP = sumWp.map { $0 / n }, avgB = sumWb.map { $0 / n }
        var groups: [AttributionResult.Group] = sectors.compactMap { g in
            let m = base.indices.filter { base[$0].sector == g }
            let wp = m.reduce(0) { $0 + avgP[$1] }, wb = m.reduce(0) { $0 + avgB[$1] }
            guard wp > 1e-9 || wb > 1e-9 else { return nil }
            let e = byGroup[g]!
            return .init(group: g, portfolioWeight: wp, benchmarkWeight: wb, activeWeight: wp - wb, allocation: e.a, selection: e.s, interaction: e.i)
        }
        groups.sort { abs($0.total) > abs($1.total) }
        let alloc = groups.reduce(0) { $0 + $1.allocation }, sel = groups.reduce(0) { $0 + $1.selection }, inter = groups.reduce(0) { $0 + $1.interaction }
        let residual = (rpTotal - rbTotal) - (alloc + sel + inter)
        let order = base.indices.filter { avgP[$0] > 1e-9 || avgB[$0] > 1e-9 }.sorted { contrib[$0] > contrib[$1] }
        let row = { (i: Int) in AttributionResult.Contributor(ticker: base[i].ticker, sector: base[i].sector, portfolioWeight: avgP[i], benchmarkWeight: avgB[i], contribution: contrib[i]) }

        var reasons: [String] = []
        if gap > 0.02 { reasons.append("returns missing for up to \(pct(gap)) of the portfolio's weight in a month") }
        if abs(residual) > 1e-6 { reasons.append(String(format: "linking residual %.2e", residual)) }
        let unknown = p.holdings.filter { $0.security == nil }
        if !unknown.isEmpty { reasons.append("\(unknown.map(\.ticker).joined(separator: ", ")) left out: not in the security master") }
        let top = groups.first
        return AttributionResult(
            engine: "Built-in (Swift)", method: method.title, portfolioReturn: rpTotal, benchmarkReturn: rbTotal,
            allocation: alloc, selection: sel, interaction: inter, residual: residual, groups: groups, periods: rows,
            top: order.prefix(5).map(row), bottom: order.reversed().prefix(5).map(row), dataGap: gap,
            recommendation: reasons.isEmpty ? "publish" : "review",
            reasons: reasons.isEmpty ? ["complete returns; the effects add up to the active return"] : reasons,
            highlight: top.map { "\($0.group) drove \(signedPct($0.total)) of the \(signedPct(rpTotal - rbTotal)) active return" } ?? "",
            assumptions: [
                "Illustrative returns for \(MarketHistory.months.first!) to \(MarketHistory.months.last!) from the model market (a spring sell-off and recovery); not real data.",
                p.trading == "trader" ? "The trader's holdings are replaced at the start of every month." : "Holdings start at today's weights and drift with their returns (no trades during the year).",
                p.benchmark == "MXEQ" ? "The benchmark is cap-weighted and drifts with its members." : "The balanced benchmark is rebalanced to its stock / bond mix every month.",
                "Funds are attributed by look-through: what they hold, in its sectors.",
                "\(method.title) effects per month, linked over the year with Carino factors.",
            ])
    }
}
