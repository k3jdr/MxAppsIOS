//
//  Universe.swift
//  MxPortMGR
//
//  The illustrative market every sample works in: 36 fictional companies in eleven sectors, six bond funds, cash and
//  three index funds (held by look-through), with a factor-model covariance — market, sector and interest-rate factors
//  plus each security's own risk — and three cap-weighted benchmarks. The companies, prices and forecasts are made up
//  for teaching; none of it is real market data.
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
    /// Sensitivity to the equity-market factor.
    let beta: Double
    /// Sensitivity of return to a 1-point rise in yields (≈ −duration for a bond).
    let rateBeta: Double
    /// Annual volatility of the security's own (diversifiable) risk.
    let idioVol: Double
    /// Market value in $bn, for cap weights.
    let marketCap: Double
    /// Illustrative annual alpha forecast (what an active manager believes, not a prediction).
    let alpha: Double
    let yield: Double
    /// A fund's holdings (weights adding up to 1); nil for a single security.
    var lookThrough: [String: Double]? = nil
    var fee: Double = 0
    /// An individual bond's coupon, maturity, credit rating and issuer type.
    var coupon: Double? = nil
    var maturity: String? = nil
    var rating: String? = nil
    var issuer: String? = nil
    /// A security from the security master (srm): its security_id, plain ticker and latest price date.
    var srmID: Int? = nil
    var srmTicker: String? = nil
    var priceDate: String? = nil
    var securityType: String? = nil

    var isFund: Bool { lookThrough != nil || (assetClass == .bond && coupon == nil) }
    /// Annual volatility under the factor model (base securities only).
    var volatility: Double? { srmID == nil ? Universe.baseIndex[ticker].map { Universe.covariance[$0][$0].squareRoot() } : nil }
    /// The ticker to show: the security master's own for srm securities (their key may carry a :MIC suffix).
    var displayTicker: String { srmTicker ?? ticker }
    /// ≈ duration for a bond (the price change for a 1-point move in yields, with the sign flipped).
    var duration: Double { -rateBeta }
}

nonisolated struct Benchmark: Identifiable, Hashable, Sendable {
    var id: String { code }
    let code: String
    let name: String
    let summary: String
    /// Weights over base securities, adding up to 1.
    let weights: [String: Double]
}

nonisolated enum Universe {
    static let sectors = ["Technology", "Health Care", "Financials", "Consumer Discretionary", "Consumer Staples",
                          "Industrials", "Energy", "Utilities", "Real Estate", "Materials", "Communication Services"]
    static let fixedIncome = "Fixed Income", cashSector = "Cash", fundSector = "Fund"

    static let riskFree = 0.03
    static let equityPremium = 0.05
    static let marketVol = 0.16, sectorVol = 0.07, rateVol = 0.009

    // ticker, name, sector, price, beta, rate beta, own vol, cap $bn, alpha, yield
    private static let equityRows: [(String, String, String, Double, Double, Double, Double, Double, Double, Double)] = [
        ("NWD", "Northwind Devices", "Technology", 182.40, 1.25, -1.0, 0.30, 2400, 0.020, 0.006),
        ("HLX", "Helix Software", "Technology", 311.20, 1.15, -1.2, 0.26, 2100, 0.030, 0.008),
        ("QBT", "Qubitron Semiconductor", "Technology", 96.75, 1.55, -1.5, 0.40, 1300, 0.035, 0.002),
        ("CLD", "Cumulus Cloud Systems", "Technology", 54.10, 1.30, -1.4, 0.36, 600, -0.020, 0.000),
        ("VTA", "Vitara Health", "Health Care", 141.60, 0.75, -0.6, 0.20, 900, 0.010, 0.016),
        ("GNM", "Genomix Therapeutics", "Health Care", 64.30, 1.05, -1.0, 0.38, 350, 0.025, 0.000),
        ("MDL", "Medline Instruments", "Health Care", 210.90, 0.85, -0.5, 0.20, 480, -0.010, 0.012),
        ("FBK", "Fairbank Financial", "Financials", 58.20, 1.10, 0.8, 0.22, 700, 0.010, 0.028),
        ("ASR", "Assura Insurance", "Financials", 121.40, 0.85, 0.5, 0.18, 420, 0.015, 0.022),
        ("PYM", "Paymint Networks", "Financials", 268.50, 1.05, -0.6, 0.22, 950, 0.020, 0.007),
        ("TRX", "Trailex Outfitters", "Consumer Discretionary", 87.60, 1.20, -0.8, 0.30, 380, -0.015, 0.010),
        ("ROV", "Rover Motors", "Consumer Discretionary", 39.80, 1.60, -1.0, 0.48, 520, -0.030, 0.000),
        ("CSH", "Casahome Retail", "Consumer Discretionary", 152.30, 1.00, -0.6, 0.22, 610, 0.010, 0.014),
        ("GRN", "Greenfield Foods", "Consumer Staples", 66.40, 0.55, -0.5, 0.15, 410, 0.000, 0.030),
        ("PLX", "Pantrix Household", "Consumer Staples", 148.70, 0.50, -0.6, 0.14, 520, 0.005, 0.026),
        ("BRW", "Brewster Beverages", "Consumer Staples", 59.90, 0.60, -0.5, 0.16, 300, -0.005, 0.029),
        ("ATL", "Atlas Machinery", "Industrials", 233.10, 1.10, -0.4, 0.22, 420, 0.015, 0.016),
        ("SKY", "Skyward Aerospace", "Industrials", 178.20, 1.05, -0.3, 0.24, 380, 0.010, 0.012),
        ("RLW", "Railway Logistics", "Industrials", 92.50, 0.95, -0.4, 0.20, 260, 0.000, 0.020),
        ("PTR", "Petra Energy", "Energy", 104.60, 0.95, 0.4, 0.28, 450, 0.000, 0.036),
        ("SOL", "Solace Renewables", "Energy", 27.30, 1.35, -1.2, 0.45, 120, 0.020, 0.000),
        ("NGS", "Northgas Pipelines", "Energy", 41.20, 0.80, -0.8, 0.20, 160, 0.005, 0.058),
        ("VLT", "Voltline Electric", "Utilities", 71.80, 0.45, -1.8, 0.14, 180, 0.000, 0.034),
        ("AQA", "Aquaria Water", "Utilities", 128.40, 0.40, -1.6, 0.13, 90, 0.005, 0.025),
        ("GRD", "Gridstone Power", "Utilities", 63.90, 0.50, -1.7, 0.15, 130, -0.005, 0.038),
        ("TWR", "Towerline REIT", "Real Estate", 196.20, 0.80, -2.2, 0.20, 150, 0.000, 0.032),
        ("HAB", "Habitat Residential REIT", "Real Estate", 48.60, 0.85, -2.5, 0.22, 110, -0.010, 0.041),
        ("WHS", "Warehouse Logistics REIT", "Real Estate", 112.70, 0.90, -2.0, 0.21, 140, 0.010, 0.030),
        ("ORE", "Oreline Mining", "Materials", 45.30, 1.20, 0.2, 0.32, 140, 0.005, 0.024),
        ("CHM", "Chemtex Materials", "Materials", 88.20, 1.00, -0.3, 0.22, 170, 0.000, 0.021),
        ("PKG", "Packright Containers", "Materials", 52.10, 0.85, -0.4, 0.20, 90, -0.005, 0.027),
        ("STM", "Streamly Media", "Communication Services", 412.80, 1.20, -1.2, 0.32, 900, 0.015, 0.000),
        ("CNX", "Connexa Telecom", "Communication Services", 36.70, 0.60, -0.9, 0.16, 280, -0.005, 0.052),
        ("SRC", "Searchly Internet", "Communication Services", 168.40, 1.10, -1.1, 0.26, 1500, 0.025, 0.004),
        ("GMR", "Gamerise Interactive", "Communication Services", 77.90, 1.25, -1.0, 0.34, 220, -0.010, 0.000),
        ("ADV", "Adverto Holdings", "Communication Services", 23.40, 1.30, -0.8, 0.38, 80, -0.020, 0.000),
    ]

    // ticker, name, price, beta, rate beta (≈ −duration), own vol, yield
    private static let bondRows: [(String, String, Double, Double, Double, Double, Double)] = [
        ("STB", "Short Treasury Bond Fund (1–3 yr)", 50.10, 0.00, -1.9, 0.004, 0.038),
        ("AGB", "Aggregate Bond Fund", 98.40, 0.03, -6.1, 0.010, 0.044),
        ("LTB", "Long Treasury Bond Fund (20+ yr)", 88.20, -0.05, -16.5, 0.020, 0.047),
        ("IPB", "Inflation-Protected Bond Fund", 107.60, 0.02, -6.8, 0.018, 0.021),
        ("CRB", "Investment-Grade Corporate Bond Fund", 104.90, 0.12, -7.2, 0.016, 0.051),
        ("MNB", "Municipal Bond Fund", 106.30, 0.05, -5.8, 0.012, 0.031),
    ]

    // ticker, name, issuer type, coupon, maturity, rating, price per 100, beta, rate beta (≈ −duration), own vol, yield
    private static let individualBonds: [(String, String, String, Double, String, String, Double, Double, Double, Double, Double)] = [
        ("T-2028", "U.S. Treasury 4.25% note 2028", "U.S. Treasury", 0.0425, "2028-11-15", "AA+", 100.3, 0.00, -1.9, 0.002, 0.041),
        ("T-2031", "U.S. Treasury 4.375% note 2031", "U.S. Treasury", 0.04375, "2031-10-31", "AA+", 100.6, 0.00, -4.5, 0.003, 0.042),
        ("T-2036", "U.S. Treasury 4.50% note 2036", "U.S. Treasury", 0.045, "2036-08-15", "AA+", 99.7, -0.02, -8.0, 0.004, 0.045),
        ("T-2056", "U.S. Treasury 4.75% bond 2056", "U.S. Treasury", 0.0475, "2056-05-15", "AA+", 96.8, -0.05, -16.5, 0.008, 0.050),
        ("TIPS-2035", "U.S. Treasury Inflation-Protected 2.00% 2035", "U.S. Treasury (TIPS)", 0.02, "2035-07-15", "AA+", 101.2, 0.02, -7.6, 0.012, 0.020),
        ("NWD-2033", "Northwind Devices 5.10% senior notes 2033", "Corporate", 0.051, "2033-03-01", "A", 99.1, 0.12, -5.8, 0.012, 0.053),
        ("FBK-2030", "Fairbank Financial 5.60% senior notes 2030", "Corporate", 0.056, "2030-06-15", "BBB+", 100.4, 0.18, -3.6, 0.015, 0.055),
        ("PTR-2035", "Petra Energy 6.25% notes 2035", "Corporate", 0.0625, "2035-09-01", "BBB-", 101.8, 0.25, -6.9, 0.022, 0.060),
        ("ROV-2029", "Rover Motors 7.875% notes 2029 (high yield)", "Corporate (high yield)", 0.07875, "2029-04-01", "BB-", 98.5, 0.40, -2.8, 0.040, 0.084),
        ("CA-GO-2034", "State of California 4.00% general obligation 2034", "Municipal (tax-exempt)", 0.04, "2034-10-01", "AA-", 104.2, 0.03, -6.6, 0.008, 0.034),
    ]

    static let base: [Security] = {
        var list: [Security] = equityRows.map { r in
            Security(ticker: r.0, name: r.1, sector: r.2, assetClass: .equity, price: r.3, beta: r.4, rateBeta: r.5,
                     idioVol: r.6, marketCap: r.7, alpha: r.8, yield: r.9)
        }
        list += bondRows.map { r in
            Security(ticker: r.0, name: r.1, sector: fixedIncome, assetClass: .bond, price: r.2, beta: r.3, rateBeta: r.4,
                     idioVol: r.5, marketCap: 0, alpha: 0, yield: r.6, fee: 0.0005)
        }
        list += individualBonds.map { r in
            Security(ticker: r.0, name: r.1, sector: fixedIncome, assetClass: .bond, price: r.6, beta: r.7, rateBeta: r.8,
                     idioVol: r.9, marketCap: 0, alpha: 0, yield: r.10, coupon: r.3, maturity: r.4, rating: r.5, issuer: r.2)
        }
        list.append(Security(ticker: "CASH", name: "Cash & Money Market", sector: cashSector, assetClass: .cash, price: 1,
                             beta: 0, rateBeta: 0, idioVol: 0.0005, marketCap: 0, alpha: 0, yield: riskFree))
        return list
    }()

    static let equityIndexWeights: [String: Double] = {
        let eq = base.filter { $0.assetClass == .equity }
        let total = eq.reduce(0) { $0 + $1.marketCap }
        return Dictionary(uniqueKeysWithValues: eq.map { ($0.ticker, $0.marketCap / total) })
    }()

    static let bondIndexWeights: [String: Double] = ["AGB": 0.50, "STB": 0.15, "CRB": 0.15, "LTB": 0.10, "IPB": 0.10]

    static let funds: [Security] = [
        Security(ticker: "MXTM", name: "MX Total Market Index Fund", sector: fundSector, assetClass: .equity, price: 268.30,
                 beta: 1, rateBeta: 0, idioVol: 0, marketCap: 0, alpha: 0, yield: 0.013, lookThrough: equityIndexWeights, fee: 0.0003),
        Security(ticker: "MXBD", name: "MX Total Bond Index Fund", sector: fundSector, assetClass: .bond, price: 72.40,
                 beta: 0, rateBeta: 0, idioVol: 0, marketCap: 0, alpha: 0, yield: 0.042, lookThrough: bondIndexWeights, fee: 0.0004),
        Security(ticker: "MXTK", name: "MX Technology Sector Fund", sector: fundSector, assetClass: .equity, price: 205.10,
                 beta: 1.3, rateBeta: 0, idioVol: 0, marketCap: 0, alpha: 0, yield: 0.005,
                 lookThrough: sectorWeights("Technology"), fee: 0.0009),
    ]

    static let all: [Security] = base + funds
    static let bySymbol: [String: Security] = Dictionary(uniqueKeysWithValues: all.map { ($0.ticker, $0) })
    static let baseIndex: [String: Int] = Dictionary(uniqueKeysWithValues: base.enumerated().map { ($1.ticker, $0) })
    static func security(_ ticker: String) -> Security? { bySymbol[ticker.uppercased()] ?? SRMRegistry.shared.security(ticker) }

    static func sectorWeights(_ sector: String) -> [String: Double] {
        let members = base.filter { $0.sector == sector }
        let total = members.reduce(0) { $0 + $1.marketCap }
        return Dictionary(uniqueKeysWithValues: members.map { ($0.ticker, $0.marketCap / total) })
    }

    static let benchmarks: [Benchmark] = [
        Benchmark(code: "MXEQ", name: "MX Equity Market 36", summary: "All 36 companies, weighted by market value (cap-weighted), like a total stock market index.",
                  weights: equityIndexWeights),
        Benchmark(code: "MX6040", name: "MX Balanced 60/40", summary: "60% MX Equity Market 36 and 40% a bond index (aggregate, short and long Treasuries, corporates, inflation-protected).",
                  weights: blend([(equityIndexWeights, 0.6), (bondIndexWeights, 0.4)])),
        Benchmark(code: "MX3070", name: "MX Income 30/70", summary: "30% stocks and 70% bonds — a conservative, income-oriented mix.",
                  weights: blend([(equityIndexWeights, 0.3), (bondIndexWeights, 0.7)])),
    ]
    static func benchmark(_ code: String) -> Benchmark {
        benchmarks.first { $0.code == code } ?? SRMRegistry.shared.benchmark(code) ?? benchmarks[0]
    }

    static func blend(_ parts: [([String: Double], Double)]) -> [String: Double] {
        var out: [String: Double] = [:]
        for (weights, share) in parts { for (k, v) in weights { out[k, default: 0] += v * share } }
        return out
    }

    /// Expected annual return under the illustrative model (CAPM-style for stocks, yield for bonds), before any alpha.
    static func expectedReturn(_ s: Security) -> Double {
        switch s.assetClass {
        case .equity: riskFree + s.beta * equityPremium
        case .bond: s.yield
        case .cash: riskFree
        }
    }

    /// Annualised covariance of the base securities: market, sector and rate factors plus own risk.
    static let covariance: [[Double]] = {
        let n = base.count
        var c = Array(repeating: Array(repeating: 0.0, count: n), count: n)
        for i in 0..<n {
            for j in 0..<n {
                let a = base[i], b = base[j]
                var v = a.beta * b.beta * marketVol * marketVol + a.rateBeta * b.rateBeta * rateVol * rateVol
                if a.assetClass == .equity, a.sector == b.sector { v += sectorVol * sectorVol }
                if i == j { v += a.idioVol * a.idioVol }
                c[i][j] = v
            }
        }
        return c
    }()
}

/// A small, fast, seedable random-number generator (SplitMix64), so every sample and simulation is repeatable.
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
