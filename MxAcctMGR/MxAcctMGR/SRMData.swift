//
//  SRMData.swift
//  MxAcctMGR
//
//  My Portfolio in the security master (MxDataHUB's PostgreSQL schema srm on 192.168.0.223), through the Layer 3
//  accounts service (Services/accounts, port 8774): search securities, read benchmark weights, load and save the
//  account with its tax lots. Securities and benchmarks read from it are registered here so the rest of the app —
//  which looks securities up by ticker — sees them. Every security the app shows comes from here. A ticker two
//  securities share (or the reserved CASH) is registered as TICKER:MIC.
//

import Foundation

/// A security as the accounts service returns it.
nonisolated struct SRMSecurity: Codable, Hashable, Sendable, Identifiable {
    var id: Int { securityId }
    var securityId: Int
    var ticker: String
    var mic: String?
    var name: String
    var securityType: String?
    var assetClass: String?
    var sector: String?
    var industry: String?
    var isin: String?
    var cusip: String?
    /// stock, fund or bond (a bond or other fixed-income fund).
    var kind: String
    var price: Double?
    var priceDate: String?
    var beta: Double?
    var marketCap: Double?
    var weight: Double?
    /// A fund's yearly expense ratio as a fraction (srm.fund_profile: Vanguard's funds and ETFs).
    var expenseRatio: Double?

    // Non-optional sort keys for the table's sortable columns (the service does the sorting).
    var typeKey: String { securityType ?? "" }
    var sectorKey: String { sector ?? "" }
    var micKey: String { mic ?? "" }
    var priceKey: Double { price ?? -1 }
    var asOfKey: String { priceDate ?? "" }
    var marketCapKey: Double { marketCap ?? -1 }

    var kindTitle: String {
        switch kind {
        case "bond": "Bond fund"
        case "fund": "Fund"
        default: securityType ?? "Stock"
        }
    }
}

nonisolated struct SRMLot: Codable, Hashable, Sendable {
    var securityId: Int
    var ticker: String
    var mic: String?
    var name: String
    var securityType: String?
    var assetClass: String?
    var sector: String?
    var industry: String?
    var kind: String
    var price: Double?
    var priceDate: String?
    var beta: Double?
    var marketCap: Double?
    var expenseRatio: Double?
    var lotId: Int?
    var acquired: String
    var quantity: Double
    var costBasis: Double
    var note: String?
    var marketValue: Double?

    var security: SRMSecurity {
        SRMSecurity(securityId: securityId, ticker: ticker, mic: mic, name: name, securityType: securityType, assetClass: assetClass,
                    sector: sector, industry: industry, isin: nil, cusip: nil, kind: kind, price: price, priceDate: priceDate,
                    beta: beta, marketCap: marketCap, expenseRatio: expenseRatio)
    }
}

nonisolated struct SRMAccount: Codable, Sendable {
    var code: String
    var name: String
    var accountType: String?
    var approach: String?
    var managedBy: String?
    var benchmark: String?
    var cash: Double
    var lots: [SRMLot]
    var investedValue: Double
    var totalValue: Double
    var unpriced: [String]
    /// Saves so far (V022): a save names the version it was made from.
    var version: Int?
    /// The portfolio's preferences as MxAcctMGR saved them (empty for an account saved before V022).
    var settings: PortfolioSettings?
    var updatedBy: String?
    var closedDate: String?
}

/// A decision recorded for a portfolio (srm.portfolio_decision, V023).
nonisolated struct SRMDecision: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var decidedOn: String
    var category: String
    var title: String
    var rationale: String?
    var portfolioVersion: Int?
    var createdAt: String?
    var createdBy: String?
}

/// A policy benchmark: dated mixes of securities (srm.benchmark_policy, V023).
nonisolated struct SRMPolicyBenchmark: Codable, Sendable, Identifiable, Hashable {
    var id: String { code }
    var code: String
    var name: String
    var description: String?
    var mixes: [Mix]

    struct Mix: Codable, Sendable, Hashable {
        var effectiveFrom: String
        var components: [Component]
    }
    struct Component: Codable, Sendable, Hashable {
        var securityId: Int?
        var ticker: String
        var name: String?
        var weight: Double
    }
}

/// A personal account as the Open Portfolio list shows it (srm.v_personal_account).
nonisolated struct SRMAccountSummary: Decodable, Sendable, Identifiable, Hashable {
    var id: String { code }
    var code: String
    var name: String
    var accountType: String?
    var approach: String?
    var managedBy: String?
    var benchmark: String?
    var lots: Int?
    var investedValue: Double?
    var costBasis: Double?
    var cashBalance: Double?
    var updatedAt: String?
    var version: Int?
    var updatedBy: String?
    var closedDate: String?
    /// (Still "MxPortMGR samples" until migration V034 renames the value.)
    var isSample: Bool { managedBy == "MxAcctMGR samples" || managedBy == "MxPortMGR samples" }

    enum CodingKeys: String, CodingKey {
        case code, name, approach, benchmark, lots, version
        case accountType = "account_type", managedBy = "managed_by", investedValue = "invested_value",
             costBasis = "cost_basis", cashBalance = "cash_balance", updatedAt = "updated_at",
             updatedBy = "updated_by", closedDate = "closed_date"
    }
}

nonisolated struct SRMBenchmarkInfo: Codable, Hashable, Sendable, Identifiable {
    var id: String { code }
    var code: String
    var name: String
    var members: Int?
}

nonisolated struct SRMBenchmarkWeights: Codable, Sendable {
    var code: String
    var name: String
    var asOf: String?
    var members: Int
    var weights: [SRMSecurity]
}

/// Security-master securities and benchmarks, by the keys the app uses.
nonisolated final class SRMRegistry: @unchecked Sendable {
    static let shared = SRMRegistry()
    private let lock = NSLock()
    private var securities: [String: Security] = [:]
    private var keyByID: [Int: String] = [:]
    private var keyByTicker: [String: String] = [:]
    private var benchmarks: [String: Benchmark] = [:]
    private var _riskFree: Double?
    private var _marketVol: Double?

    /// The latest 3-month Treasury yield and the market proxy's volatility, from the last analytics inputs read.
    var riskFree: Double? { lock.lock(); defer { lock.unlock() }; return _riskFree }
    var marketVol: Double? { lock.lock(); defer { lock.unlock() }; return _marketVol }

    /// The analytics service's numbers for these securities (by key): market beta, rate beta, volatility, alpha.
    func applyRisk(keys: [String], betas: [Double]?, rateBetas: [Double]?, vols: [Double], alphas: [Double]?,
                   riskFree: Double?, marketVol: Double?) {
        lock.lock(); defer { lock.unlock() }
        if let riskFree { _riskFree = riskFree }
        if let marketVol { _marketVol = marketVol }
        for (i, key) in keys.enumerated() {
            guard var sec = securities[key] else { continue }
            if let b = betas, i < b.count { sec.beta = b[i] }
            if let r = rateBetas, i < r.count { sec.rateBeta = r[i] }
            if i < vols.count { sec.volatility = vols[i] }
            if let a = alphas, i < a.count { sec.alpha = a[i] }
            sec.hasRisk = true
            securities[key] = sec
        }
    }

    func security(_ key: String) -> Security? {
        lock.lock(); defer { lock.unlock() }
        return securities[key.uppercased()] ?? keyByTicker[key.uppercased()].flatMap { securities[$0] }
    }

    func key(id: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        return keyByID[id]
    }

    func key(ticker: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return keyByTicker[ticker.uppercased()]
    }

    /// Drops a benchmark's weights (a policy benchmark just redefined): the next use reads them again.
    func forgetBenchmark(_ code: String) {
        lock.lock(); defer { lock.unlock() }
        benchmarks[code.uppercased()] = nil
    }

    func benchmark(_ code: String) -> Benchmark? {
        lock.lock(); defer { lock.unlock() }
        return benchmarks[code.uppercased()]
    }

    var benchmarkCodes: [String] {
        lock.lock(); defer { lock.unlock() }
        return benchmarks.keys.sorted()
    }

    /// Registers a security and returns its key: the ticker, or TICKER:MIC when another security already has it.
    @discardableResult
    func register(_ s: SRMSecurity) -> String {
        lock.lock(); defer { lock.unlock() }
        if let key = keyByID[s.securityId] {
            securities[key] = Self.make(s, key: key, keeping: securities[key])
            return key
        }
        let plain = s.ticker.uppercased()
        var key = plain
        if plain == "CASH" || (securities[plain] != nil && securities[plain]?.srmID != s.securityId) {
            key = "\(plain):\(s.mic ?? "SRM\(s.securityId)")"
        }
        securities[key] = Self.make(s, key: key, keeping: nil)
        keyByID[s.securityId] = key
        if keyByTicker[plain] == nil { keyByTicker[plain] = key }
        return key
    }

    func register(benchmark w: SRMBenchmarkWeights) -> Benchmark {
        var weights: [String: Double] = [:]
        for s in w.weights { weights[register(s), default: 0] += s.weight ?? 0 }
        let b = Benchmark(code: w.code, name: w.name,
                          summary: "\(w.name): \(w.members) members on \(w.asOf ?? "—"), from the security master (srm).", weights: weights)
        lock.lock(); benchmarks[w.code.uppercased()] = b; lock.unlock()
        return b
    }

    /// A Security for the app's tools: what the security master says about it, and — once the analytics service's
    /// inputs have covered it — its estimated betas, volatility and alpha (kept when it is registered again).
    private static func make(_ s: SRMSecurity, key: String, keeping old: Security?) -> Security {
        let bond = s.kind == "bond" || s.securityType == "Bond" || s.securityType == "Listed Note"
        let fund = s.kind == "fund"
        var sec = Security(ticker: key, name: s.name,
                           sector: bond ? Universe.fixedIncome : s.sector ?? (fund ? "Diversified Fund" : "Unclassified"),
                           assetClass: bond ? .bond : .equity,
                           price: s.price ?? old?.price ?? 0, beta: s.beta ?? 0, rateBeta: 0, volatility: nil,
                           marketCap: s.marketCap.map { $0 / 1e9 } ?? old?.marketCap ?? 0, alpha: 0,
                           srmID: s.securityId, srmTicker: s.ticker, priceDate: s.priceDate ?? old?.priceDate,
                           securityType: s.securityType)
        sec.fee = s.expenseRatio ?? old?.fee ?? 0
        if let old, old.hasRisk {
            sec.beta = old.beta
            sec.rateBeta = old.rateBeta
            sec.volatility = old.volatility
            sec.alpha = old.alpha
            sec.hasRisk = true
        }
        return sec
    }
}

/// The accounts service (Services/accounts, 127.0.0.1:8774).
nonisolated enum AccountsClient {
    static let base: String = {
        #if DEBUG
        // Self-tests: a test instance of the service (-accountsPort 18774).
        if let port = UserDefaults.standard.string(forKey: "accountsPort") { return "http://127.0.0.1:\(port)" }
        #endif
        return "http://127.0.0.1:8774"
    }()
    static let service = "accounts (Python, port 8774)"

    static func request<T: Decodable>(_ method: String, _ path: String, body: [String: Any]? = nil, timeout: Double = 60, as: T.Type) async throws -> T {
        var r = URLRequest(url: URL(string: base + path)!, timeoutInterval: timeout)
        r.httpMethod = method
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: r)
        } catch {
            throw ServiceClient.Failure.from(error, service)
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let error = json["error"] as? String {
            if (response as? HTTPURLResponse)?.statusCode == 409 { throw ServiceClient.Failure.conflict(error) }
            throw ServiceClient.Failure.rejected("Security master: \(error)")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ServiceClient.Failure.rejected("The accounts service answered in an unexpected form (\(error.localizedDescription)).")
        }
    }

    private struct Securities: Decodable { var securities: [SRMSecurity]; var total: Int?; var facets: [String: [Facet]]? }
    struct Facet: Decodable, Hashable { var value: String; var count: Int }

    /// A search request: text, kind, column filters (the service's parameter names), sort column and order.
    struct Search: Equatable {
        var text = ""
        var kind = "all"
        var filters: [String: String] = [:]
        var sort = "relevance"
        var descending = false
    }
    private struct Benchmarks: Decodable { var benchmarks: [SRMBenchmarkInfo] }
    private struct Accounts: Decodable { var accounts: [SRMAccountSummary] }
    struct PriceLoad: Decodable { var loaded: [String]; var status: String?; var message: String?; var account: SRMAccount }

    /// One page of matching securities, how many match in all, and (with `facets`) each filterable column's values.
    static func search(_ s: Search, offset: Int = 0, limit: Int = 200, facets: Bool = false) async throws
        -> (securities: [SRMSecurity], total: Int, facets: [String: [Facet]]?) {
        var c = URLComponents()
        c.queryItems = [URLQueryItem(name: "q", value: s.text), URLQueryItem(name: "kind", value: s.kind),
                        URLQueryItem(name: "sort", value: s.sort), URLQueryItem(name: "dir", value: s.descending ? "desc" : "asc"),
                        URLQueryItem(name: "offset", value: String(offset)), URLQueryItem(name: "limit", value: String(limit))]
            + s.filters.filter { !$0.value.isEmpty }.map { URLQueryItem(name: $0.key, value: $0.value) }
            + (facets ? [URLQueryItem(name: "facets", value: "1")] : [])
        let query = (c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        let r = try await request("GET", "/securities?" + query, as: Securities.self)
        return (r.securities, r.total ?? r.securities.count, r.facets)
    }

    static func benchmarks() async throws -> [SRMBenchmarkInfo] {
        try await request("GET", "/benchmarks", as: Benchmarks.self).benchmarks
    }

    static func benchmarkWeights(_ code: String) async throws -> SRMBenchmarkWeights {
        try await request("GET", "/benchmarks/\(code)/weights", as: SRMBenchmarkWeights.self)
    }

    static func accounts() async throws -> [String] {
        try await accountList().map(\.code)
    }

    /// Every personal account with its value, version and who saved it last (File ▸ Open Portfolio…).
    static func accountList() async throws -> [SRMAccountSummary] {
        try await request("GET", "/accounts", as: Accounts.self).accounts
    }

    private struct Decisions: Decodable { var decisions: [SRMDecision] }
    private struct Policies: Decodable { var benchmarks: [SRMPolicyBenchmark] }
    private struct Resolved: Decodable { var securities: [String: SRMSecurity]; var unknown: [String] }

    /// A portfolio's decisions, newest first.
    static func decisions(_ code: String) async throws -> [SRMDecision] {
        try await request("GET", "/accounts/\(code)/decisions", as: Decisions.self).decisions
    }

    /// Records a decision; returns them all.
    static func addDecision(_ code: String, title: String, rationale: String, category: String, decidedOn: String) async throws -> [SRMDecision] {
        try await request("POST", "/accounts/\(code)/decisions",
                          body: ["title": title, "rationale": rationale, "category": category, "decidedOn": decidedOn, "by": "MxAcctMGR"],
                          as: Decisions.self).decisions
    }

    /// A new portfolio from the saved version of `code`.
    static func duplicate(_ code: String, to newCode: String, name: String) async throws -> SRMAccount {
        try await request("POST", "/accounts/\(code)/duplicate", body: ["code": newCode, "name": name, "by": "MxAcctMGR"], as: SRMAccount.self)
    }

    static func policyBenchmarks() async throws -> [SRMPolicyBenchmark] {
        try await request("GET", "/benchmarks/policy", as: Policies.self).benchmarks
    }

    /// Defines a policy benchmark's mixes; the service then has the srm-loader write its snapshots.
    static func savePolicy(_ p: SRMPolicyBenchmark) async throws -> SRMPolicyBenchmark {
        let body: [String: Any] = ["name": p.name, "by": "MxAcctMGR",
                                   "mixes": p.mixes.map { m in ["effectiveFrom": m.effectiveFrom,
                                                                "components": m.components.map { ["ticker": $0.ticker, "weight": $0.weight] }] }]
        return try await request("PUT", "/benchmarks/policy/\(p.code)", body: body, timeout: 300, as: SRMPolicyBenchmark.self)
    }

    /// Each ticker's security with its latest price (Import Holdings), and the tickers the security master lacks.
    static func resolve(_ tickers: [String]) async throws -> (found: [String: SRMSecurity], unknown: [String]) {
        let r = try await request("POST", "/securities/resolve", body: ["tickers": tickers], as: Resolved.self)
        return (r.securities, r.unknown)
    }

    static func account(_ code: String) async throws -> SRMAccount {
        try await request("GET", "/accounts/\(code)", as: SRMAccount.self)
    }

    static func save(_ code: String, _ body: [String: Any]) async throws -> SRMAccount {
        try await request("PUT", "/accounts/\(code)", body: body, as: SRMAccount.self)
    }

    private struct MonthlyPage: Decodable {
        var prices: [String: [MonthClose]]
    }
    struct MonthClose: Decodable, Sendable { var date: String; var close: Double }

    /// Month-end closes over the last `months` months, by the security master's ticker.
    static func monthlyPrices(_ tickers: [String], months: Int = 12) async throws -> [String: [MonthClose]] {
        try await request("POST", "/prices/monthly", body: ["tickers": tickers, "months": months], as: MonthlyPage.self).prices
    }

    static func loadPrices(_ code: String) async throws -> PriceLoad {
        try await request("POST", "/accounts/\(code)/load-prices", timeout: 600, as: PriceLoad.self)
    }
}

extension ServiceClient {
    /// Optimization inputs for a security-master account from the analytics service: POST /inputs, then the full
    /// matrices from its inputsUrl, with each asset mapped to the app's key for it.
    static func srmInputs(portfolio code: String, benchmark: String?, mode: String) async throws -> (OptimizationInputs, String) {
        var body: [String: Any] = ["portfolio": code, "mode": mode]
        if let benchmark { body["benchmark"] = benchmark }
        return try await riskInputs(body)
    }

    /// Risk inputs for securities by ticker (Learn, stress tests, Add Securities): covariance, betas, rate betas.
    static func riskInputs(securities tickers: [String], benchmark: String? = nil) async throws -> (OptimizationInputs, String) {
        var body: [String: Any] = ["securities": tickers, "mode": benchmark == nil ? "risk" : "absolute", "alpha": "none"]
        if let benchmark { body["benchmark"] = benchmark }
        return try await riskInputs(body)
    }

    /// POST /inputs, then the full matrices; registers every asset and gives it the service's betas, rate betas,
    /// volatility and alpha (Universe.security then carries them), and the risk-free rate.
    static func riskInputs(_ body: [String: Any]) async throws -> (OptimizationInputs, String) {
        let summary = try await post("http://127.0.0.1:8772", "/inputs", body, service: "analytics (Python, port 8772)")
        guard let url = (summary["inputsUrl"] as? String).flatMap(URL.init(string:)) else {
            throw Failure.rejected("analytics: no inputsUrl in the answer")
        }
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(from: url)
        } catch {
            throw ServiceClient.Failure.from(error, "analytics (Python, port 8772)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = json["assets"] as? [String], let cov = json["covariance"] as? [[Double]] else {
            throw Failure.rejected("analytics: the inputs could not be read")
        }
        let names = json["names"] as? [String] ?? assets
        let sectors = json["sectors"] as? [String] ?? assets.map { _ in "Unclassified" }
        let keys = assets.enumerated().map { i, t in
            SRMRegistry.shared.key(ticker: t) ?? SRMRegistry.shared.register(SRMSecurity(securityId: -1 - i, ticker: t, name: names[i], sector: sectors[i], kind: "stock"))
        }
        let current = (json["currentWeights"] as? [String: Double]) ?? [:]
        let vols = cov.indices.map { cov[$0][$0].squareRoot() }
        let marketIndex = (json["marketProxy"] as? String).flatMap { assets.firstIndex(of: $0) }
        SRMRegistry.shared.applyRisk(keys: keys, betas: json["betas"] as? [Double], rateBetas: json["rateBetas"] as? [Double],
                                     vols: vols, alphas: body["mode"] as? String == "active" ? json["expectedReturns"] as? [Double] : nil,
                                     riskFree: json["riskFree"] as? Double,
                                     marketVol: json["marketVol"] as? Double ?? marketIndex.map { vols[$0] })
        let inputs = OptimizationInputs(assets: keys, sectors: keys.map { Universe.security($0)?.sector ?? "Unclassified" },
                                        benchmark: json["benchmarkWeights"] as? [Double] ?? assets.map { _ in 0 },
                                        current: assets.map { current[$0] ?? 0 },
                                        alpha: json["expectedReturns"] as? [Double] ?? assets.map { _ in 0 },
                                        cov: cov.flatMap { $0 })
        let excluded = (summary["excluded"] as? [String]) ?? []
        let note = "\(assets.count) securities, \(json["statistics"].flatMap { ($0 as? [String: Any])?["observations"] as? Int } ?? 0) days of prices"
            + (excluded.isEmpty ? "" : "; left out for lack of price history: \(excluded.joined(separator: ", "))")
        return (inputs, note)
    }
}
