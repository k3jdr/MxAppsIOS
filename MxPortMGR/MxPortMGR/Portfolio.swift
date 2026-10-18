//
//  Portfolio.swift
//  MxPortMGR
//
//  A personal account's holdings — each a security or fund with its market value and, in a taxable account, its tax
//  lots — and what can be read from them: look-through weights over the base securities, sector and asset-class
//  weights, and the problems worth fixing before optimizing (weights that don't add up, unpriced or unknown
//  holdings, concentration, idle cash).
//

import Foundation

nonisolated enum AccountType: String, Codable, Sendable, CaseIterable {
    case taxable = "Taxable brokerage"
    case retirement = "Retirement (tax-deferred)"
    case roth = "Roth (tax-free)"
    var isTaxable: Bool { self == .taxable }
}

nonisolated enum PortfolioStyle: String, Codable, Sendable {
    case active = "Active", passive = "Passive", either = "Either"
}

nonisolated struct TaxLot: Codable, Hashable, Sendable, Identifiable {
    var id: String { acquired + String(costBasis) }
    /// yyyy-MM-dd
    var acquired: String
    /// Share of the holding's value in this lot (the lots add up to 1).
    var share: Double
    /// What this lot cost, in dollars.
    var costBasis: Double
}

nonisolated struct Holding: Codable, Hashable, Sendable, Identifiable {
    var id: String { ticker }
    var ticker: String
    var value: Double
    var lots: [TaxLot] = []
    /// A price is missing for this holding (stale or delisted): it can't be valued reliably.
    var unpriced = false
    /// Shares (or units) held, when known — always for a security-master account.
    var quantity: Double? = nil

    var security: Security? { Universe.security(ticker) }
    var costBasis: Double { lots.isEmpty ? value : lots.reduce(0) { $0 + $1.costBasis } }
    var unrealizedGain: Double { value - costBasis }
}

nonisolated struct Portfolio: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var account: AccountType
    var benchmark: String
    var style: PortfolioStyle
    var holdings: [Holding]
    /// The edge case the sample teaches, in a sentence or two.
    var lesson: String
    /// What to look for in the results.
    var lookFor: [String]
    /// How the holdings changed through the attribution year: "buyAndHold" drifts with returns, "trader" changes them every month.
    var trading: String = "buyAndHold"
    /// Base securities with no returns from the given month on (0-based), for the missing-data case.
    var missingFrom: [String: Int] = [:]
    var symbol: String = "briefcase"
    /// "srm" when the account lives in the security master (MxPortMGR My Portfolio ▸ Security master), with its code.
    var source: String? = nil
    var srmCode: String? = nil
    var isSRM: Bool { source == "srm" }

    var total: Double { holdings.reduce(0) { $0 + $1.value } }

    /// Weight of each holding as entered.
    func weight(_ h: Holding) -> Double { total > 0 ? h.value / total : 0 }

    /// Weights over the base securities: funds are replaced by what they hold. Unknown tickers are left out.
    var lookThrough: [String: Double] {
        var out: [String: Double] = [:]
        let t = total
        guard t > 0 else { return out }
        for h in holdings {
            guard let s = h.security else { continue }
            let w = h.value / t
            if let parts = s.lookThrough {
                for (k, v) in parts { out[k, default: 0] += w * v }
            } else {
                out[s.ticker, default: 0] += w
            }
        }
        return out
    }

    func sectorWeights() -> [String: Double] { Portfolio.sectors(of: lookThrough) }
    func classWeights() -> [AssetClass: Double] { Portfolio.classes(of: lookThrough) }

    static func sectors(of weights: [String: Double]) -> [String: Double] {
        var out: [String: Double] = [:]
        for (k, w) in weights { out[Universe.security(k)?.sector ?? "Unknown", default: 0] += w }
        return out
    }

    static func classes(of weights: [String: Double]) -> [AssetClass: Double] {
        var out: [AssetClass: Double] = [:]
        for (k, w) in weights { if let s = Universe.security(k) { out[s.assetClass, default: 0] += w } }
        return out
    }

    var benchmarkInfo: Benchmark { Universe.benchmark(benchmark) }

    /// Fees a year, weighted.
    var weightedFee: Double {
        holdings.reduce(0) { $0 + weight($1) * ($1.security?.fee ?? 0) }
    }

    // MARK: Checks

    nonisolated struct Issue: Hashable, Sendable, Identifiable {
        enum Level: String, Sendable { case error, warning, note }
        var id: String { title }
        var level: Level
        var title: String
        var detail: String
    }

    /// What to fix or understand before optimizing.
    var issues: [Issue] {
        var out: [Issue] = []
        for h in holdings where h.security == nil {
            out.append(Issue(level: .error, title: "Unknown security \(h.ticker)",
                             detail: "\(h.ticker) isn't in the security master, so it has no sector, risk or returns. It is left out of every calculation — \(pct(weight(h))) of the account is invisible to the optimizer."))
        }
        for h in holdings where h.unpriced {
            out.append(Issue(level: .error, title: "No current price for \(h.ticker)",
                             detail: "The last price is stale (a halted or delisted security). Its value — and so every weight — may be wrong. Attribution marks the months without a return as a data gap."))
        }
        for h in holdings where h.security?.lookThrough == nil && h.security != nil && weight(h) > 0.20 && h.security?.assetClass == .equity {
            out.append(Issue(level: .warning, title: "\(h.ticker) is \(pct(weight(h))) of the account",
                             detail: "A single company over 20%: one earnings report, lawsuit or product failure can move the whole account. Its own risk is not diversified away."))
        }
        let b = Portfolio.sectors(of: benchmarkInfo.weights)
        for (sector, w) in sectorWeights().sorted(by: { $0.value > $1.value }) where sector != Universe.fixedIncome && sector != Universe.cashSector {
            let bw = b[sector] ?? 0
            if w > 0.15, w > 2 * bw {
                out.append(Issue(level: .warning, title: "\(sector) is \(pct(w)) vs \(pct(bw)) in \(benchmark)",
                                 detail: "More than twice the benchmark's weight in one sector: the account's results will follow that sector's news far more than the market's."))
            }
        }
        let classes = classWeights(), benchClasses = Portfolio.classes(of: benchmarkInfo.weights)
        let outsideBenchmark = AssetClass.allCases.filter { (benchClasses[$0] ?? 0) == 0 }.reduce(0) { $0 + (classes[$1] ?? 0) }
        if outsideBenchmark > 0.05 {
            out.append(Issue(level: .warning, title: "\(pct(outsideBenchmark)) is in asset classes \(benchmark) doesn't hold",
                             detail: "The benchmark has no \(AssetClass.allCases.filter { (benchClasses[$0] ?? 0) == 0 }.map { $0.rawValue.lowercased() }.joined(separator: " or ")). Measured against it, those holdings are pure active risk and an optimizer will sell them. If they are part of your plan, choose a benchmark that includes them (MX6040 or MX3070)."))
        }
        let cash = classes[.cash] ?? 0
        if cash > 0.10 {
            out.append(Issue(level: .note, title: "\(pct(cash)) in cash",
                             detail: "Cash is safe from market falls but earns less than stocks or bonds over long periods; waiting for a 'better time' to invest is market timing."))
        }
        let missing = missingFrom.keys.sorted()
        if !missing.isEmpty {
            out.append(Issue(level: .warning, title: "Returns missing for \(missing.joined(separator: ", "))",
                             detail: "Part of the year has no returns for these securities, so attribution can't explain all of the active return: its result is marked 'review'."))
        }
        return out
    }
}

nonisolated func pct(_ x: Double, _ digits: Int = 1) -> String {
    String(format: "%.\(digits)f%%", 100 * x)
}

nonisolated func signedPct(_ x: Double, _ digits: Int = 2) -> String {
    String(format: "%+.\(digits)f%%", 100 * x)
}

nonisolated func money(_ x: Double) -> String {
    let x = abs(x) < 0.005 ? 0 : x   // no "-$0.00" from rounding
    let f = NumberFormatter()
    f.numberStyle = .currency
    f.currencyCode = "USD"
    f.maximumFractionDigits = abs(x) >= 1000 ? 0 : 2
    return f.string(from: NSNumber(value: x)) ?? String(format: "$%.0f", x)
}
