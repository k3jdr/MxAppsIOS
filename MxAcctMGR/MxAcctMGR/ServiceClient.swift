//
//  ServiceClient.swift
//  MxAcctMGR
//
//  The same optimizations through the Layer 3 services (MxAppsIOS/Services, started with
//  `python3 Services/mxservices.py start`): the account's inputs from the analytics service go inline (assets,
//  sectors, benchmarkWeights, currentWeights, expectedReturns as alpha, covariance), so portfolio-java's
//  /optimize/active and portfolio-cpp's /optimize/tracking work on exactly what the built-in engine sees, and the two
//  answers can be compared. The analytics service's /attribution reads the account from the security master by code.
//

import Foundation

nonisolated enum ServiceClient {
    enum Failure: LocalizedError {
        case notRunning(String), rejected(String)
        /// The account changed in the security master since it was opened (HTTP 409): the save was refused.
        case conflict(String)

        /// What a failed request to a service means: a request cancelled because its screen went away (moving on from
        /// Holdings to Benchmark cancels Holdings' request) is a CancellationError, which no alert shows; a timeout
        /// says the service is slow; only a refused or lost connection says it isn't running.
        static func from(_ error: Error, _ service: String) -> Error {
            if error is CancellationError || Task.isCancelled { return CancellationError() }
            guard let e = error as? URLError else { return Failure.notRunning(service) }
            switch e.code {
            case .cancelled: return CancellationError()
            case .timedOut: return Failure.rejected("\(service) is running but didn't answer in time — it may still be computing; try again.")
            default: return Failure.notRunning(service)
            }
        }
        var errorDescription: String? {
            switch self {
            case .notRunning(let s): "\(s) isn't running. Start the Layer 3 services with python3 Services/mxservices.py start (see Layer 3 Services)."
            case .rejected(let s): s
            case .conflict(let s): s
            }
        }
    }

    static func post(_ base: String, _ path: String, _ body: [String: Any], service: String) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: base + path)!, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure.from(error, service)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.rejected("\(service) answered with something that isn't JSON.")
        }
        if let error = json["error"] as? String, json["weights"] == nil, json["portfolioReturn"] == nil {
            throw Failure.rejected("\(service): \(error)")
        }
        return json
    }

    private static func inputsBody(_ inputs: OptimizationInputs) -> [String: Any] {
        let n = inputs.n
        return [
            "assets": inputs.assets,
            "sectors": inputs.sectors,
            "benchmarkWeights": inputs.benchmark,
            "currentWeights": Dictionary(uniqueKeysWithValues: inputs.assets.indices.filter { inputs.current[$0] > 0 }.map { (inputs.assets[$0], inputs.current[$0]) }),
            "expectedReturns": inputs.alpha,
            "covariance": (0..<n).map { i in Array(inputs.cov[(i * n)..<(i * n + n)]) },
        ]
    }

    static func active(_ inputs: OptimizationInputs, _ s: ActiveSettings) async throws -> OptimizationResult {
        var body = inputsBody(inputs)
        body["maxWeight"] = s.maxWeight
        body["maxActiveWeight"] = s.maxActiveWeight
        body["riskAversion"] = s.riskAversion
        if let band = s.sectorBand { body["maxSectorActive"] = band }
        if let te = s.trackingErrorTarget { body["trackingErrorTarget"] = te }
        if let t = s.maxTurnover { body["maxTurnover"] = t }
        let json = try await post("http://127.0.0.1:8766", "/optimize/active", body, service: "portfolio-java (Java, port 8766)")
        return result(json, inputs, engine: "portfolio-java service")
    }

    static func track(_ inputs: OptimizationInputs, _ s: TrackingSettings) async throws -> OptimizationResult {
        var body = inputsBody(inputs)
        body["maxNames"] = s.maxNames
        body["selection"] = s.selection.rawValue
        body["maxWeight"] = s.maxWeight
        body["trackingErrorBudget"] = s.trackingErrorBudget
        if let t = s.maxTurnover { body["maxTurnover"] = t }
        let json = try await post("http://127.0.0.1:8767", "/optimize/tracking", body, service: "portfolio-cpp (C++, port 8767)")
        return result(json, inputs, engine: "portfolio-cpp service")
    }

    private static func result(_ json: [String: Any], _ inputs: OptimizationInputs, engine: String) -> OptimizationResult {
        func num(_ k: String) -> Double? { (json[k] as? NSNumber)?.doubleValue }
        let weights = (json["weights"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
        let w = inputs.assets.map { weights[$0] ?? 0 }
        let dc = json["decisionContext"] as? [String: Any] ?? [:]
        let sectorActive = (json["sectorActiveWeights"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
        let diagnostics = json["diagnostics"] as? [String: Any] ?? [:]
        return OptimizationResult(
            engine: engine, status: json["solverStatus"] as? String ?? "unknown", weights: weights,
            trackingError: num("trackingError") ?? 0, currentTrackingError: num("currentTrackingError"),
            activeAlpha: num("activeAlpha"), informationRatio: num("informationRatio"),
            activeShare: num("activeShare") ?? w.indices.reduce(0) { $0 + abs(w[$1] - inputs.benchmark[$1]) / 2 },
            turnover: num("turnover") ?? 0, names: weights.count,
            bindingConstraints: json["bindingConstraints"] as? [String] ?? [], sectorActive: sectorActive,
            trades: Engine.trades(inputs, w),
            decision: Decision(recommendation: dc["recommendation"] as? String ?? "escalate", reason: dc["reason"] as? String ?? ""),
            riskAversion: num("riskAversion"), method: json["method"] as? String ?? json["objective"] as? String,
            benchmarkCovered: num("benchmarkWeightCovered"),
            milliseconds: (diagnostics["ms"] as? NSNumber)?.doubleValue ?? 0)
    }

    /// Attribution of a security-master portfolio (MxDataHUB ▸ Portfolios) by the analytics service.
    static func attribution(portfolio code: String, method: AttributionEngine.Method) async throws -> AttributionResult {
        let json = try await post("http://127.0.0.1:8772", "/attribution", ["portfolio": code, "method": method.rawValue],
                                  service: "analytics (Python, port 8772)")
        return attributionResult(json, method: method, engine: "analytics service · \(code) vs \(json["benchmark"] as? String ?? "")")
    }

    private static func attributionResult(_ json: [String: Any], method: AttributionEngine.Method, engine: String) -> AttributionResult {
        func num(_ d: [String: Any], _ k: String) -> Double { (d[k] as? NSNumber)?.doubleValue ?? 0 }
        let effects = json["effects"] as? [String: Any] ?? [:]
        let groups = (json["byGroup"] as? [[String: Any]] ?? []).map { g in
            AttributionResult.Group(group: g["group"] as? String ?? "", portfolioWeight: num(g, "portfolioWeight"),
                                    benchmarkWeight: num(g, "benchmarkWeight"), activeWeight: num(g, "activeWeight"),
                                    allocation: num(g, "allocation"), selection: num(g, "selection"), interaction: num(g, "interaction"))
        }
        let periods = (json["periods"] as? [[String: Any]] ?? []).map { p in
            AttributionResult.Period(month: p["period"] as? String ?? String((p["end"] as? String ?? "").prefix(7)), portfolioReturn: num(p, "portfolioReturn"),
                                     benchmarkReturn: num(p, "benchmarkReturn"), allocation: num(p, "allocation"),
                                     selection: num(p, "selection"), interaction: num(p, "interaction"))
        }
        func contributors(_ key: String) -> [AttributionResult.Contributor] {
            (json[key] as? [[String: Any]] ?? []).map { c in
                AttributionResult.Contributor(ticker: c["ticker"] as? String ?? "", sector: c["sector"] as? String ?? "",
                                              portfolioWeight: num(c, "portfolioWeight"), benchmarkWeight: num(c, "benchmarkWeight"),
                                              contribution: num(c, "activeContribution"))
            }
        }
        let dc = json["decisionContext"] as? [String: Any] ?? [:]
        let gaps = json["dataGaps"] as? [String: Any] ?? [:]
        return AttributionResult(
            engine: engine, method: method.title,
            portfolioReturn: num(json, "portfolioReturn"), benchmarkReturn: num(json, "benchmarkReturn"),
            allocation: num(effects, "allocation"), selection: num(effects, "selection"), interaction: num(effects, "interaction"),
            residual: num(effects, "residual"), groups: groups, periods: periods,
            top: contributors("topContributors"), bottom: contributors("bottomContributors"),
            dataGap: max(num(gaps, "portfolio"), num(gaps, "benchmark")),
            recommendation: dc["recommendation"] as? String ?? "review", reasons: dc["reasons"] as? [String] ?? [],
            highlight: dc["highlight"] as? String ?? "", assumptions: json["assumptions"] as? [String] ?? [])
    }
}
