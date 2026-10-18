//
//  Optimizer.swift
//  MxPortMGR
//
//  The built-in engines, written to the same contracts as the Layer 3 services (Services/contracts/README.md) so
//  their answers can be compared:
//    active  — portfolio-java POST /optimize/active: maximise αᵀw − λ/2·(w−b)ᵀΣ(w−b) − ρ/2·Σₛ max(0, |aₛ|−m)²,
//              long-only, fully invested, wᵢ ≤ maxWeight, |wᵢ−bᵢ| ≤ maxActiveWeight; λ by bisection on log λ to meet
//              a tracking-error target; accelerated projected gradient (FISTA).
//    track   — portfolio-cpp POST /optimize/tracking: the ≤ N-name portfolio with the smallest tracking error
//              (full replication, largest weights, or sector-stratified selection).
//    risk    — portfolio-cpp POST /risk: volatility, VaR and expected shortfall, tracking error, beta, risk contributions.
//

import Foundation

/// Assets, their benchmark and current weights, alpha and covariance: mxjobs.inputs/1 in Swift.
nonisolated struct OptimizationInputs: Sendable {
    var assets: [String]
    var sectors: [String]
    var benchmark: [Double]
    var current: [Double]
    var alpha: [Double]
    /// Row-major n × n, annualised.
    var cov: [Double]
    var n: Int { assets.count }

    init(assets: [String], sectors: [String], benchmark: [Double], current: [Double], alpha: [Double], cov: [Double]) {
        self.assets = assets
        self.sectors = sectors
        self.benchmark = benchmark
        self.current = current
        self.alpha = alpha
        self.cov = cov
    }

    static let empty = OptimizationInputs(assets: [], sectors: [], benchmark: [], current: [], alpha: [], cov: [])

    /// The benchmark's members and the account's look-through holdings (unknown tickers left out).
    init(portfolio: Portfolio) {
        let b = portfolio.benchmarkInfo.weights
        let c = portfolio.lookThrough
        let names = Set(b.keys).union(c.keys)
        let ordered = Universe.base.map(\.ticker).filter { names.contains($0) }
        assets = ordered
        sectors = ordered.map { Universe.security($0)?.sector ?? "Unknown" }
        benchmark = ordered.map { b[$0] ?? 0 }
        let cs = c.values.reduce(0, +)
        current = ordered.map { cs > 0 ? (c[$0] ?? 0) / cs : 0 }
        alpha = ordered.map { Universe.security($0)?.alpha ?? 0 }
        let idx = ordered.map { Universe.baseIndex[$0]! }
        let n = ordered.count
        var m = [Double](repeating: 0, count: n * n)
        for i in 0..<n { for j in 0..<n { m[i * n + j] = Universe.covariance[idx[i]][idx[j]] } }
        cov = m
    }

    func mul(_ x: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: n)
        cov.withUnsafeBufferPointer { c in
            for i in 0..<n {
                var s = 0.0
                let row = i * n
                for j in 0..<n { s += c[row + j] * x[j] }
                out[i] = s
            }
        }
        return out
    }

    func quad(_ x: [Double]) -> Double { zip(x, mul(x)).reduce(0) { $0 + $1.0 * $1.1 } }

    /// Largest eigenvalue of Σ (60 power iterations from the ones vector, as in the services).
    var maxEigenvalue: Double {
        var v = [Double](repeating: 1 / Double(max(n, 1)).squareRoot(), count: n)
        var lambda = 0.0
        for _ in 0..<60 {
            let w = mul(v)
            let norm = w.reduce(0) { $0 + $1 * $1 }.squareRoot()
            guard norm > 0 else { return 0 }
            lambda = norm
            v = w.map { $0 / norm }
        }
        return lambda
    }
}

nonisolated struct Trade: Hashable, Sendable, Identifiable {
    var id: String { asset }
    var asset: String
    var from: Double
    var to: Double
    var change: Double { to - from }
    var side: String { change > 0 ? "Buy" : "Sell" }
}

nonisolated struct Decision: Hashable, Sendable {
    /// rebalance, rebalance_partially, hold, rerun_relaxed, escalate (the services' vocabulary).
    var recommendation: String
    var reason: String

    var title: String {
        switch recommendation {
        case "rebalance": "The plan suggests rebalancing"
        case "rebalance_partially": "The plan suggests rebalancing part of the way"
        case "hold": "The plan suggests holding"
        case "rerun_relaxed": "The limits can't all be met — relax one"
        default: "Review before acting"
        }
    }
}

nonisolated struct OptimizationResult: Sendable {
    var engine: String
    var status: String
    var weights: [String: Double]
    var trackingError: Double
    var currentTrackingError: Double?
    var activeAlpha: Double?
    var informationRatio: Double?
    var activeShare: Double
    var turnover: Double
    var names: Int
    var bindingConstraints: [String]
    var sectorActive: [String: Double]
    var trades: [Trade]
    var decision: Decision
    var riskAversion: Double?
    var method: String?
    var benchmarkCovered: Double?
    var milliseconds: Double
}

nonisolated struct ActiveSettings: Sendable, Equatable {
    var maxWeight = 0.10
    var maxActiveWeight = 0.03
    var sectorBand: Double? = 0.05
    var trackingErrorTarget: Double? = 0.03
    var riskAversion = 10.0
    var maxTurnover: Double? = 0.25
}

nonisolated struct TrackingSettings: Sendable, Equatable {
    enum Selection: String, CaseIterable, Sendable { case stratified, largest }
    var maxNames = 20
    var selection: Selection = .stratified
    var maxWeight = 1.0
    var trackingErrorBudget = 0.02
    var maxTurnover: Double? = 0.30
}

nonisolated enum Engine {
    // MARK: Projection and solver

    /// wᵢ = clip(vᵢ − τ, loᵢ, hiᵢ) with τ chosen so the weights add up to 1 — the services find τ by bisection;
    /// here exactly, from the sorted breakpoints of the piecewise-linear sum (same answer, far fewer passes).
    static func project(_ v: [Double], lo: [Double], hi: [Double]) -> [Double] {
        let n = v.count
        func sum(_ tau: Double) -> Double {
            var s = 0.0
            for i in 0..<n { s += min(max(v[i] - tau, lo[i]), hi[i]) }
            return s
        }
        var points = [Double]()
        points.reserveCapacity(2 * n)
        for i in 0..<n { points.append(v[i] - hi[i]); points.append(v[i] - lo[i]) }
        points.sort()
        // sum(τ) falls as τ rises; find neighbouring breakpoints around 1 and interpolate (linear between them).
        var a = 0, b = points.count - 1
        guard sum(points[a]) >= 1, sum(points[b]) <= 1 else {
            let tau = sum(points[a]) < 1 ? points[a] : points[b]
            return (0..<n).map { min(max(v[$0] - tau, lo[$0]), hi[$0]) }
        }
        while b - a > 1 {
            let m = (a + b) / 2
            if sum(points[m]) >= 1 { a = m } else { b = m }
        }
        let sa = sum(points[a]), sb = sum(points[b])
        let tau = sa == sb ? points[a] : points[a] + (sa - 1) / (sa - sb) * (points[b] - points[a])
        return (0..<n).map { min(max(v[$0] - tau, lo[$0]), hi[$0]) }
    }

    /// FISTA ascent of a concave objective given its gradient, step 1/L, over the projected set.
    static func fista(start: [Double], lo: [Double], hi: [Double], lipschitz: Double, maxIterations: Int = 20_000,
                      gradient: ([Double]) -> [Double]) -> (w: [Double], iterations: Int, converged: Bool) {
        var x = project(start, lo: lo, hi: hi), y = x
        var t = 1.0
        let step = 1 / max(lipschitz, 1e-12)
        for k in 1...maxIterations {
            let g = gradient(y)
            let next = project(y.indices.map { y[$0] + step * g[$0] }, lo: lo, hi: hi)
            let tNext = (1 + (1 + 4 * t * t).squareRoot()) / 2
            var delta = 0.0
            for i in x.indices { delta = max(delta, abs(next[i] - x[i])) }
            y = next.indices.map { next[$0] + (t - 1) / tNext * (next[$0] - x[$0]) }
            x = next
            t = tNext
            if delta < 1e-8 { return (x, k, true) }
        }
        return (x, maxIterations, false)
    }

    // MARK: Active

    static func active(_ inputs: OptimizationInputs, _ s: ActiveSettings) -> OptimizationResult {
        let started = Date()
        let n = inputs.n, b = inputs.benchmark
        var lo = [Double](repeating: 0, count: n), hi = lo
        for i in 0..<n {
            lo[i] = max(0, b[i] - s.maxActiveWeight)
            hi[i] = min(s.maxWeight, b[i] + s.maxActiveWeight)
            if hi[i] < lo[i] { hi[i] = lo[i] }
        }
        if lo.reduce(0, +) > 1 + 1e-12 || hi.reduce(0, +) < 1 - 1e-12 {
            return failed("infeasible", inputs, Decision(recommendation: "rerun_relaxed",
                          reason: "The weight limits can't add up to 100%: raise the largest weight or the active weight allowed."), started)
        }
        let sectorNames = Array(Set(inputs.sectors)).sorted()
        let sectorOf = inputs.sectors.map { sectorNames.firstIndex(of: $0)! }
        let largest = sectorNames.indices.map { k in sectorOf.filter { $0 == k }.count }.max() ?? 1
        let lmax = inputs.maxEigenvalue

        func solve(_ lambda: Double, warm: [Double]?) -> (w: [Double], iterations: Int, converged: Bool) {
            let rho = s.sectorBand == nil ? 0 : 20 * lambda * lmax
            let L = lambda * lmax + rho * Double(largest)
            return fista(start: warm ?? b, lo: lo, hi: hi, lipschitz: L) { w in
                let act = w.indices.map { w[$0] - b[$0] }
                let sa = inputs.mul(act)
                var g = w.indices.map { inputs.alpha[$0] - lambda * sa[$0] }
                if let band = s.sectorBand {
                    var sums = [Double](repeating: 0, count: sectorNames.count)
                    for i in 0..<n { sums[sectorOf[i]] += act[i] }
                    for i in 0..<n {
                        let a = sums[sectorOf[i]]
                        let excess = max(0, abs(a) - band)
                        g[i] -= rho * excess * (a >= 0 ? 1 : -1)
                    }
                }
                return g
            }
        }

        var lambda = s.riskAversion
        var result: (w: [Double], iterations: Int, converged: Bool)
        if let target = s.trackingErrorTarget {
            var a = -1.0, hiL = 3.0
            var best: (w: [Double], iterations: Int, converged: Bool, lambda: Double)?
            var warm: [Double]?
            for _ in 0..<14 {
                let mid = (a + hiL) / 2
                let t = solve(pow(10, mid), warm: warm)
                warm = t.w
                let te = inputs.quad(t.w.indices.map { t.w[$0] - b[$0] }).squareRoot()
                if te > target { a = mid } else { hiL = mid; best = (t.w, t.iterations, t.converged, pow(10, mid)) }
            }
            if let best { result = (best.w, best.iterations, best.converged); lambda = best.lambda } else {
                lambda = pow(10, hiL)
                result = solve(lambda, warm: warm)
            }
        } else {
            result = solve(lambda, warm: nil)
        }

        let w = result.w
        let act = w.indices.map { w[$0] - b[$0] }
        let te = max(0, inputs.quad(act)).squareRoot()
        let alpha = zip(inputs.alpha, act).reduce(0) { $0 + $1.0 * $1.1 }
        let ir = te > 1e-9 ? alpha / te : 0
        let turnover = w.indices.reduce(0) { $0 + abs(w[$1] - inputs.current[$1]) / 2 }
        var sectorActive: [String: Double] = [:]
        for i in 0..<n { sectorActive[inputs.sectors[i], default: 0] += act[i] }
        let worst = sectorActive.values.map(abs).max() ?? 0
        var binding: [String] = []
        if w.indices.contains(where: { w[$0] >= s.maxWeight - 1e-6 }) && s.maxWeight < 1 { binding.append("max_weight") }
        if act.contains(where: { abs($0) >= s.maxActiveWeight - 1e-6 }) { binding.append("max_active_weight") }
        if let band = s.sectorBand, worst >= band - 5e-4 { binding.append("max_sector_active") }
        if let target = s.trackingErrorTarget, te >= target - 1e-4 { binding.append("tracking_error_target") }
        if let mt = s.maxTurnover, turnover > mt { binding.append("max_turnover") }

        let decision: Decision
        if !result.converged {
            decision = Decision(recommendation: "escalate", reason: "The solver did not converge; review before acting.")
        } else if let band = s.sectorBand, worst > band + 0.002 {
            decision = Decision(recommendation: "rerun_relaxed", reason: "A sector is \(pct(worst, 2)) active, beyond the \(pct(band, 2)) band: widen the band or the active-weight limit.")
        } else if let target = s.trackingErrorTarget, te > target * 1.05 {
            decision = Decision(recommendation: "rerun_relaxed", reason: "Tracking error \(pct(te, 2)) is above the \(pct(target, 2)) target even at the highest risk aversion.")
        } else if turnover < 0.02 {
            decision = Decision(recommendation: "hold", reason: "Turnover of \(pct(turnover)) is too small to be worth the trading cost.")
        } else if let mt = s.maxTurnover, turnover > mt {
            decision = Decision(recommendation: "rebalance_partially", reason: "Reaching the target means trading \(pct(turnover)) of the account, more than the \(pct(mt, 0)) turnover limit: move part of the way now.")
        } else {
            decision = Decision(recommendation: "rebalance", reason: "Information ratio \(String(format: "%.2f", ir)) at \(pct(te, 2)) tracking error with \(pct(turnover)) turnover.")
        }
        return OptimizationResult(engine: "Built-in (Swift)", status: result.converged ? "optimal" : "max_iterations",
                                  weights: weightMap(inputs.assets, w), trackingError: te,
                                  currentTrackingError: inputs.quad(inputs.current.indices.map { inputs.current[$0] - b[$0] }).squareRoot(),
                                  activeAlpha: alpha, informationRatio: ir,
                                  activeShare: act.reduce(0) { $0 + abs($1) / 2 }, turnover: turnover,
                                  names: w.filter { $0 > 1e-6 }.count, bindingConstraints: binding, sectorActive: sectorActive,
                                  trades: trades(inputs, w), decision: decision, riskAversion: lambda, method: "active_mean_variance",
                                  benchmarkCovered: nil, milliseconds: Date().timeIntervalSince(started) * 1000)
    }

    // MARK: Index tracking

    /// Which names a ≤ N-name tracker holds: the largest weights, or names spread across sectors in proportion to them.
    static func selectNames(_ inputs: OptimizationInputs, maxNames: Int, method: TrackingSettings.Selection) -> [Int] {
        let members = inputs.benchmark.indices.filter { inputs.benchmark[$0] > 0 }
        guard maxNames > 0, maxNames < members.count else { return members }
        let byWeight = members.sorted { inputs.benchmark[$0] > inputs.benchmark[$1] }
        if method == .largest { return Array(byWeight.prefix(maxNames)) }
        // As portfolio-cpp: one name per sector, heaviest sectors first; then, one at a time, a name for the sector
        // furthest below its proportional share that still has names to add.
        var groups: [String: [Int]] = [:]
        for i in byWeight { groups[inputs.sectors[i], default: []].append(i) }
        let weight = groups.mapValues { $0.reduce(0) { $0 + inputs.benchmark[$1] } }
        let bySize = groups.keys.sorted { weight[$0]! != weight[$1]! ? weight[$0]! > weight[$1]! : $0 > $1 }
        var quota: [String: Int] = [:]
        for g in bySize.prefix(maxNames) { quota[g] = 1 }
        var used = quota.count
        while used < maxNames {
            var pick: String?, gap = -Double.infinity
            for g in bySize where (quota[g] ?? 0) < groups[g]!.count {
                let x = weight[g]! * Double(maxNames) - Double(quota[g] ?? 0)
                if x > gap { gap = x; pick = g }
            }
            guard let g = pick else { break }
            quota[g, default: 0] += 1
            used += 1
        }
        return groups.keys.sorted().flatMap { Array(groups[$0]!.prefix(quota[$0] ?? 0)) }
    }

    static func track(_ inputs: OptimizationInputs, _ s: TrackingSettings) -> OptimizationResult {
        let started = Date()
        let n = inputs.n, b = inputs.benchmark
        let members = b.filter { $0 > 0 }.count
        let chosen = selectNames(inputs, maxNames: s.maxNames, method: s.selection)
        let method = chosen.count >= members ? "full_replication" : "sampled_\(s.selection.rawValue)"
        if Double(chosen.count) * s.maxWeight < 1 {
            return failed("infeasible", inputs, Decision(recommendation: "rerun_relaxed", reason: "Too few names for the weight cap: raise the number of names or the largest weight."), started)
        }
        // Names outside the selection are held at zero.
        let lo = [Double](repeating: 0, count: n)
        var hi = lo
        for i in chosen { hi[i] = s.maxWeight }
        let w: [Double], converged: Bool
        if method == "full_replication" {
            (w, converged) = (b, true)
        } else {
            let r = fista(start: b, lo: lo, hi: hi, lipschitz: inputs.maxEigenvalue) { w in
                inputs.mul(w.indices.map { w[$0] - b[$0] }).map { -$0 }
            }
            (w, converged) = (r.w, r.converged)
        }
        let act = w.indices.map { w[$0] - b[$0] }
        let te = max(0, inputs.quad(act)).squareRoot()
        let currentTE = inputs.quad(inputs.current.indices.map { inputs.current[$0] - b[$0] }).squareRoot()
        let turnover = w.indices.reduce(0) { $0 + abs(w[$1] - inputs.current[$1]) / 2 }
        var sectorActive: [String: Double] = [:]
        for i in 0..<n { sectorActive[inputs.sectors[i], default: 0] += act[i] }
        let covered = chosen.reduce(0) { $0 + b[$1] }
        let decision: Decision
        if !converged {
            decision = Decision(recommendation: "escalate", reason: "The solver did not converge; review before acting.")
        } else if te > s.trackingErrorBudget {
            decision = Decision(recommendation: "rerun_relaxed", reason: "\(chosen.count) names track with \(pct(te, 2)) error, above the \(pct(s.trackingErrorBudget, 2)) budget: hold more names.")
        } else if currentTE <= s.trackingErrorBudget && turnover < 0.02 {
            decision = Decision(recommendation: "hold", reason: "The account already tracks within budget (\(pct(currentTE, 2))).")
        } else if let mt = s.maxTurnover, turnover > mt {
            decision = Decision(recommendation: "rebalance_partially", reason: "The tracker is \(pct(turnover)) away from today's holdings, more than the \(pct(mt, 0)) turnover limit.")
        } else {
            decision = Decision(recommendation: "rebalance", reason: "Today's tracking error \(pct(currentTE, 2)) → \(pct(te, 2)) with \(chosen.count) names and \(pct(turnover)) turnover.")
        }
        return OptimizationResult(engine: "Built-in (Swift)", status: converged ? "optimal" : "max_iterations",
                                  weights: weightMap(inputs.assets, w), trackingError: te, currentTrackingError: currentTE,
                                  activeAlpha: nil, informationRatio: nil, activeShare: act.reduce(0) { $0 + abs($1) / 2 },
                                  turnover: turnover, names: w.filter { $0 > 1e-6 }.count, bindingConstraints: [],
                                  sectorActive: sectorActive, trades: trades(inputs, w), decision: decision, riskAversion: nil,
                                  method: method, benchmarkCovered: covered, milliseconds: Date().timeIntervalSince(started) * 1000)
    }

    /// Tracking error for each number of names, to show the diminishing return of holding more.
    static func trackingCurve(_ inputs: OptimizationInputs, selection: TrackingSettings.Selection) -> [(names: Int, te: Double)] {
        let members = inputs.benchmark.filter { $0 > 0 }.count
        return [3, 5, 8, 10, 12, 15, 20, 25, 30, members].filter { $0 <= members }.map { k in
            var s = TrackingSettings()
            s.maxNames = k
            s.selection = selection
            return (k, track(inputs, s).trackingError)
        }
    }

    // MARK: Helpers

    static func weightMap(_ assets: [String], _ w: [Double]) -> [String: Double] {
        var out: [String: Double] = [:]
        for (a, x) in zip(assets, w) where x > 1e-6 { out[a] = (x * 1e6).rounded() / 1e6 }
        return out
    }

    static func trades(_ inputs: OptimizationInputs, _ w: [Double]) -> [Trade] {
        inputs.assets.indices.compactMap { i in
            abs(w[i] - inputs.current[i]) > 1e-4 ? Trade(asset: inputs.assets[i], from: inputs.current[i], to: w[i]) : nil
        }.sorted { abs($0.change) > abs($1.change) }
    }

    private static func failed(_ status: String, _ inputs: OptimizationInputs, _ decision: Decision, _ started: Date) -> OptimizationResult {
        OptimizationResult(engine: "Built-in (Swift)", status: status, weights: [:], trackingError: 0, currentTrackingError: nil,
                           activeAlpha: nil, informationRatio: nil, activeShare: 0, turnover: 0, names: 0, bindingConstraints: [],
                           sectorActive: [:], trades: [], decision: decision, riskAversion: nil, method: nil, benchmarkCovered: nil,
                           milliseconds: Date().timeIntervalSince(started) * 1000)
    }
}

// MARK: - Risk

nonisolated struct RiskReport: Sendable {
    nonisolated struct Contribution: Hashable, Sendable, Identifiable {
        var id: String { name }
        var name: String
        var weight: Double
        var share: Double
    }
    var volatility: Double
    var benchmarkVolatility: Double
    var trackingError: Double
    var beta: Double
    /// One-month loss not exceeded with 95% confidence, and the average loss beyond it, as fractions of the account.
    var var95Month: Double
    var es95Month: Double
    var expectedReturn: Double
    /// Return change for a 1-point rise in yields (≈ −duration of the whole account).
    var rateSensitivity: Double
    var diversificationRatio: Double
    var concentration: Double
    var contributions: [Contribution]
    var sectorContributions: [Contribution]
    var activeContributions: [Contribution]
}

extension Engine {
    static func risk(_ inputs: OptimizationInputs, weights w: [Double]) -> RiskReport {
        let b = inputs.benchmark
        let sw = inputs.mul(w)
        let variance = max(zip(w, sw).reduce(0) { $0 + $1.0 * $1.1 }, 1e-16)
        let vol = variance.squareRoot()
        let bVar = max(inputs.quad(b), 1e-16)
        let act = w.indices.map { w[$0] - b[$0] }
        let sa = inputs.mul(act)
        let aVar = max(zip(act, sa).reduce(0) { $0 + $1.0 * $1.1 }, 1e-16)
        let beta = zip(w, inputs.mul(b)).reduce(0) { $0 + $1.0 * $1.1 } / bVar
        let mu = inputs.assets.indices.reduce(0) { $0 + w[$1] * (Universe.security(inputs.assets[$1]).map(Universe.expectedReturn) ?? 0) }
        let h = 21.0 / 252, z = 1.6449
        let sigmaH = vol * h.squareRoot(), muH = mu * h
        let phi = exp(-z * z / 2) / (2 * Double.pi).squareRoot()
        let rate = inputs.assets.indices.reduce(0) { $0 + w[$1] * (Universe.security(inputs.assets[$1])?.rateBeta ?? 0) }
        let dr = inputs.assets.indices.reduce(0) { $0 + w[$1] * inputs.cov[$1 * inputs.n + $1].squareRoot() } / vol
        var contributions: [RiskReport.Contribution] = []
        var bySector: [String: (Double, Double)] = [:]
        var active: [RiskReport.Contribution] = []
        var activeSector: [String: Double] = [:]
        for i in inputs.assets.indices {
            let share = w[i] * sw[i] / variance
            if w[i] > 1e-6 { contributions.append(.init(name: inputs.assets[i], weight: w[i], share: share)) }
            bySector[inputs.sectors[i], default: (0, 0)].0 += w[i]
            bySector[inputs.sectors[i], default: (0, 0)].1 += share
            let ashare = act[i] * sa[i] / aVar
            if abs(act[i]) > 1e-6 { active.append(.init(name: inputs.assets[i], weight: act[i], share: ashare)) }
            activeSector[inputs.sectors[i], default: 0] += ashare
        }
        return RiskReport(volatility: vol, benchmarkVolatility: bVar.squareRoot(), trackingError: aVar.squareRoot(), beta: beta,
                          var95Month: max(0, z * sigmaH - muH), es95Month: max(0, sigmaH * phi / 0.05 - muH),
                          expectedReturn: mu, rateSensitivity: rate * 0.01, diversificationRatio: dr,
                          concentration: w.reduce(0) { $0 + $1 * $1 },
                          contributions: contributions.sorted { $0.share > $1.share },
                          sectorContributions: bySector.map { .init(name: $0.key, weight: $0.value.0, share: $0.value.1) }
                            .filter { $0.weight > 1e-6 }.sorted { $0.share > $1.share },
                          activeContributions: active.sorted { $0.share > $1.share })
    }
}
