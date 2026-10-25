//
//  Universe.swift
//  MxAcctMGR
//
//  The securities and benchmarks the app works with — all from the security master (MxDataHUB's PostgreSQL schema
//  srm, through the accounts service), registered in SRMRegistry as they are read. Their risk numbers — market beta,
//  rate beta, volatility, momentum alpha, the covariance between them — come from the analytics service's inputs,
//  estimated from real daily prices; the risk-free rate is the latest 3-month Treasury yield from the same inputs.
//  The one number that isn't data is the equity premium, an assumption the screens label as one.
//

import Foundation

nonisolated enum AssetClass: String, Codable, Sendable, CaseIterable {
    case equity = "Stocks", bond = "Bonds", cash = "Cash"
}

nonisolated struct Security: Identifiable, Hashable, Sendable {
    var id: String { ticker }
    let ticker: String
    let name: String
    let sector: String
    let assetClass: AssetClass
    let price: Double
    /// Market beta (against VTI), from the analytics service once its inputs cover the security.
    var beta: Double
    /// Return for a 1.00 rise in the 10-year Treasury yield (≈ −duration for a bond fund), from the analytics service.
    var rateBeta: Double
    /// Annual volatility from the analytics service's covariance; nil until its inputs cover the security.
    var volatility: Double?
    /// Market value in $bn, for cap weights.
    let marketCap: Double
    /// The analytics service's momentum alpha (12-1 month), when its inputs include one.
    var alpha: Double
    /// A fund's holdings (weights adding up to 1): the security master has no fund holdings, so always nil.
    var lookThrough: [String: Double]? = nil
    var fee: Double = 0
    /// A bond's coupon, maturity, issuer (Treasuries from TreasuryDirect).
    var coupon: Double? = nil
    var maturity: String? = nil
    var rating: String? = nil
    var issuer: String? = nil
    /// The security master's security_id, plain ticker, latest price date and type.
    var srmID: Int? = nil
    var srmTicker: String? = nil
    var priceDate: String? = nil
    var securityType: String? = nil
    /// The risk numbers above are the analytics service's (not placeholders).
    var hasRisk = false

    var isFund: Bool { securityType.map { ["ETF", "ETN", "Mutual Fund", "Closed-End Fund"].contains($0) } ?? false }
    /// The ticker to show: the security master's own (the key may carry a :MIC suffix).
    var displayTicker: String { srmTicker ?? ticker }
    /// ≈ duration for a bond (the price change for a 1-point move in yields, with the sign flipped).
    var duration: Double { -rateBeta }
    /// Own (diversifiable) volatility: total volatility less the market part.
    var idioVol: Double {
        guard let v = volatility else { return 0 }
        return max(v * v - beta * beta * Universe.marketVol * Universe.marketVol, 0).squareRoot()
    }
}

nonisolated struct Benchmark: Identifiable, Hashable, Sendable {
    var id: String { code }
    let code: String
    let name: String
    let summary: String
    /// Weights over securities, adding up to 1.
    let weights: [String: Double]
}

nonisolated enum Universe {
    /// The sectors the security master classifies stocks into (FMP's), for pickers and sector shocks.
    static let sectors = ["Technology", "Healthcare", "Financial Services", "Consumer Cyclical", "Consumer Defensive",
                          "Industrials", "Energy", "Utilities", "Real Estate", "Basic Materials", "Communication Services"]
    static let fixedIncome = "Fixed Income", cashSector = "Cash", fundSector = "Fund"

    /// The latest 3-month Treasury yield, from the analytics service's inputs (srm market series DGS3MO).
    static var riskFree: Double { SRMRegistry.shared.riskFree ?? 0 }
    /// An assumption, not data: the extra return expected from stocks over Treasury bills, a year.
    static let equityPremium = 0.05
    /// The market proxy's (VTI's) annual volatility from the analytics service's inputs.
    static var marketVol: Double { SRMRegistry.shared.marketVol ?? 0 }

    static func security(_ ticker: String) -> Security? { SRMRegistry.shared.security(ticker) }

    /// The security-master benchmarks read so far (S&P 500, Dow, Nasdaq-100, the blended BAL6040 / BAL3070, …).
    static var benchmarks: [Benchmark] { SRMRegistry.shared.benchmarkCodes.compactMap { SRMRegistry.shared.benchmark($0) } }

    /// A benchmark by code; an empty one (no members yet) until the security master's is read.
    static func benchmark(_ code: String) -> Benchmark {
        SRMRegistry.shared.benchmark(code)
            ?? Benchmark(code: code, name: code, summary: "\(code): not read from the security master yet.", weights: [:])
    }

    /// Expected annual return, CAPM-style: the risk-free rate plus beta times the (assumed) equity premium.
    static func expectedReturn(_ s: Security) -> Double {
        s.assetClass == .cash ? riskFree : riskFree + s.beta * equityPremium
    }
}

/// A small, fast, seedable random-number generator (SplitMix64), so every simulation is repeatable.
nonisolated struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }

    /// A standard normal draw (Box–Muller).
    mutating func normal() -> Double {
        let u1 = max(uniform(), 1e-12), u2 = uniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}
