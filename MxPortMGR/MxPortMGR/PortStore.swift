//
//  PortStore.swift
//  MxPortMGR
//
//  The window's state: the screen shown, the account selected, the settings and results of each step, and the
//  walkthroughs' progress. Optimizations and simulations run off the main thread; the built-in engine is always
//  available, the Layer 3 services when they are running.
//

import Foundation
import Observation

enum Screen: String, CaseIterable, Identifiable {
    case welcome, choosePath
    case whyOptimize, whyAttribution, activeVsPassive
    case myPortfolio, myRisk, myImprove, myTrades, myAttribution
    case activePortfolio, activeRisk, activeOptimize, activeTrades, activeAttribution
    case passivePortfolio, passiveDrift, passiveTrack, passiveBands, passiveAttribution
    case reportLibrary, morningBriefing, reportWalkthrough
    case samples, services

    var id: String { rawValue }

    enum Group: String, CaseIterable {
        case start = "Start Here", learn = "Learn the Why", mine = "My Portfolio", active = "Active Portfolio", passive = "Passive Index Portfolio"
        case reports = "Market Reports", library = "Library"
    }

    var group: Group {
        switch self {
        case .welcome, .choosePath: .start
        case .whyOptimize, .whyAttribution, .activeVsPassive: .learn
        case .myPortfolio, .myRisk, .myImprove, .myTrades, .myAttribution: .mine
        case .activePortfolio, .activeRisk, .activeOptimize, .activeTrades, .activeAttribution: .active
        case .passivePortfolio, .passiveDrift, .passiveTrack, .passiveBands, .passiveAttribution: .passive
        case .reportLibrary, .morningBriefing, .reportWalkthrough: .reports
        case .samples, .services: .library
        }
    }

    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .choosePath: "Choose Your Path"
        case .whyOptimize: "Why Optimize?"
        case .whyAttribution: "Why Attribution?"
        case .activeVsPassive: "Active vs Passive"
        case .myPortfolio: "My Holdings & Benchmark"
        case .myRisk: "Risk Today"
        case .myImprove: "Optimize or Track"
        case .myTrades: "Trades & Rebalancing"
        case .myAttribution: "Attribution"
        case .activePortfolio: "Portfolio & Benchmark"
        case .activeRisk: "Risk Today"
        case .activeOptimize: "Optimize"
        case .activeTrades: "Trades & Taxes"
        case .activeAttribution: "Attribution"
        case .passivePortfolio: "Portfolio & Index"
        case .passiveDrift: "Tracking Error & Drift"
        case .passiveTrack: "Build the Tracker"
        case .passiveBands: "Rebalance Bands"
        case .passiveAttribution: "Attribution"
        case .reportLibrary: "Report Library"
        case .morningBriefing: "Morning Briefing"
        case .reportWalkthrough: "Report Walkthrough"
        case .samples: "Sample Portfolios"
        case .services: "Layer 3 Services"
        }
    }

    /// The title with its group where the title alone is ambiguous (window title, Quick Help).
    var fullTitle: String {
        switch group {
        case .mine: "My Portfolio · \(step!). \(title)"
        case .active: "Active · \(step!). \(title)"
        case .passive: "Passive · \(step!). \(title)"
        default: title
        }
    }

    var systemImage: String {
        switch self {
        case .welcome: "hand.wave"
        case .choosePath: "signpost.right.and.left"
        case .whyOptimize: "slider.horizontal.below.square.and.square.filled"
        case .whyAttribution: "chart.bar.xaxis"
        case .activeVsPassive: "scalemass"
        case .myPortfolio: "person.crop.circle"
        case .myRisk: "waveform.path.ecg"
        case .myImprove: "slider.horizontal.3"
        case .myTrades: "arrow.left.arrow.right"
        case .myAttribution: "chart.bar.doc.horizontal"
        case .activePortfolio, .passivePortfolio: "briefcase"
        case .activeRisk: "waveform.path.ecg"
        case .activeOptimize: "wand.and.stars"
        case .activeTrades: "list.bullet.rectangle"
        case .activeAttribution, .passiveAttribution: "chart.bar.doc.horizontal"
        case .passiveDrift: "arrow.left.and.right.righttriangle.left.righttriangle.right"
        case .passiveTrack: "scope"
        case .passiveBands: "rectangle.split.3x1"
        case .reportLibrary: "books.vertical"
        case .morningBriefing: "sunrise"
        case .reportWalkthrough: "newspaper"
        case .samples: "square.grid.2x2"
        case .services: "server.rack"
        }
    }

    /// The step number on a path.
    var step: Int? {
        let path = Screen.myPath.firstIndex(of: self) ?? Screen.activePath.firstIndex(of: self) ?? Screen.passivePath.firstIndex(of: self)
        return path.map { $0 + 1 }
    }

    static let myPath: [Screen] = [.myPortfolio, .myRisk, .myImprove, .myTrades, .myAttribution]
    static let activePath: [Screen] = [.activePortfolio, .activeRisk, .activeOptimize, .activeTrades, .activeAttribution]
    static let passivePath: [Screen] = [.passivePortfolio, .passiveDrift, .passiveTrack, .passiveBands, .passiveAttribution]

    /// The next and previous screens in the guide's order.
    var next: Screen? { Screen.allCases.firstIndex(of: self).flatMap { $0 + 1 < Screen.allCases.count ? Screen.allCases[$0 + 1] : nil } }
    var previous: Screen? { Screen.allCases.firstIndex(of: self).flatMap { $0 > 0 ? Screen.allCases[$0 - 1] : nil } }
}

enum EngineChoice: String, CaseIterable, Identifiable {
    case builtIn = "Built-in (Swift)", services = "Layer 3 services"
    var id: String { rawValue }
}

enum LotOrder: String, CaseIterable, Identifiable {
    case fifo = "First in, first out", hifo = "Highest cost first"
    var id: String { rawValue }
}

struct ReportState {
    var step = 0
    var reaction: String?
    var settings = SimSettings()
    var result: SimResult?
    var running = false
}

nonisolated struct TaxEstimate: Sendable {
    nonisolated struct Line: Hashable, Sendable, Identifiable {
        var id: String { ticker + acquired }
        var ticker: String
        var acquired: String
        var sold: Double
        var gain: Double
        var shortTerm: Bool
    }
    var lines: [Line]
    var shortTermGain: Double { lines.filter(\.shortTerm).reduce(0) { $0 + $1.gain } }
    var longTermGain: Double { lines.filter { !$0.shortTerm }.reduce(0) { $0 + $1.gain } }
    var tax: Double
    var viaFunds: [String]
}

@MainActor
@Observable
final class PortStore {
    var screen: Screen = .welcome {
        didSet {
            UserDefaults.standard.set(screen.rawValue, forKey: "screen")
            // The My Portfolio path always works on the user's own account.
            if screen.group == .mine, selectedID != "mine" { selectedID = "mine" }
        }
    }
    /// How the user runs My Portfolio: active (optimize, trades & taxes) or passive (track, rebalance bands).
    var myApproach: PortfolioStyle = UserDefaults.standard.string(forKey: "myApproach") == PortfolioStyle.active.rawValue ? .active : .passive {
        didSet { UserDefaults.standard.set(myApproach.rawValue, forKey: "myApproach") }
    }
    /// The passive reading of a shared screen: the passive path, or My Portfolio run passively.
    var passiveContext: Bool { screen.group == .passive || (screen.group == .mine && myApproach == .passive) }

    /// A screen's title as shown: My Portfolio's steps 3 and 4 follow the approach; the walkthrough shows its report.
    func title(_ s: Screen, full: Bool = true) -> String {
        let short: String
        switch s {
        case .myImprove: short = myApproach == .active ? "Optimize" : "Build the Tracker"
        case .myTrades: short = myApproach == .active ? "Trades & Taxes" : "Rebalance Bands"
        case .reportWalkthrough: return currentReport.title
        default: return full ? s.fullTitle : (s.step.map { "\($0). \(s.title)" } ?? s.title)
        }
        return full ? "My Portfolio · \(s.step!). \(short)" : "\(s.step!). \(short)"
    }

    var portfolios: [Portfolio]
    var selectedID: String {
        didSet {
            UserDefaults.standard.set(selectedID, forKey: "sample")
            clearResults()
        }
    }
    var engine: EngineChoice = .builtIn {
        didSet { clearResults() }
    }

    var activeSettings = ActiveSettings() { didSet { if activeSettings != oldValue { activeResult = nil } } }
    var trackingSettings = TrackingSettings() { didSet { if trackingSettings != oldValue { trackResult = nil } } }
    var activeResult: OptimizationResult?
    var trackResult: OptimizationResult?
    var trackCurve: [(names: Int, te: Double)] = []
    var attribution: AttributionResult?
    var attributionMethod: AttributionEngine.Method = .brinsonFachler { didSet { attribution = nil } }
    /// A portfolio code in the security master (MxDataHUB) to attribute with the analytics service instead of the sample.
    var masterPortfolio = UserDefaults.standard.string(forKey: "masterPortfolio") ?? "DEMO_GROWTH" {
        didSet { UserDefaults.standard.set(masterPortfolio, forKey: "masterPortfolio") }
    }
    var attributeMaster = false { didSet { attribution = nil } }

    var lotOrder: LotOrder = .hifo
    var longTermRate = 0.15
    var shortTermRate = 0.32
    var bandWidth = 0.05

    var reports: [String: ReportState] = [:]
    /// The report the walkthrough shows.
    var reportID = UserDefaults.standard.string(forKey: "report") ?? "jobs" {
        didSet { UserDefaults.standard.set(reportID, forKey: "report") }
    }
    var currentReport: MarketReport { MarketReport.report(reportID) }

    func openReport(_ id: String) {
        reportID = id
        screen = .reportWalkthrough
    }
    var collapsedLessons: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "collapsedLessons") ?? []) {
        didSet { UserDefaults.standard.set(Array(collapsedLessons), forKey: "collapsedLessons") }
    }

    var busy = false
    var message: String?
    var errorMessage: String?

    init() {
        var list = Samples.all
        if let data = UserDefaults.standard.data(forKey: "myPortfolio"), let mine = try? JSONDecoder().decode(Portfolio.self, from: data) {
            list.append(mine)
        } else {
            list.append(Samples.myPortfolio)
        }
        portfolios = list
        let saved = UserDefaults.standard.string(forKey: "sample") ?? ""
        selectedID = list.contains { $0.id == saved } ? saved : "core-satellite"
        if let s = UserDefaults.standard.string(forKey: "screen").flatMap(Screen.init(rawValue:)) { screen = s }
    }

    var portfolio: Portfolio {
        get { portfolios.first { $0.id == selectedID } ?? portfolios[0] }
        set {
            guard let i = portfolios.firstIndex(where: { $0.id == newValue.id }) else { return }
            portfolios[i] = newValue
            if newValue.id == "mine", let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "myPortfolio")
            }
            clearResults()
        }
    }

    func resetMyPortfolio() {
        UserDefaults.standard.removeObject(forKey: "myPortfolio")
        if let i = portfolios.firstIndex(where: { $0.id == "mine" }) { portfolios[i] = Samples.myPortfolio }
        clearResults()
    }

    /// Copies a sample's holdings into My Portfolio to edit.
    func copyToMine(_ p: Portfolio) {
        var mine = Samples.myPortfolio
        mine.holdings = p.holdings.filter { $0.security != nil }
        mine.benchmark = p.benchmark
        mine.account = p.account
        portfolio = mine
        selectedID = "mine"
    }

    func clearResults() {
        activeResult = nil
        trackResult = nil
        trackCurve = []
        attribution = nil
        for k in reports.keys { reports[k]?.result = nil }
    }

    var inputs: OptimizationInputs { OptimizationInputs(portfolio: portfolio) }

    func go(_ s: Screen) { screen = s }

    // MARK: Runs

    func optimize() async {
        let inputs = inputs, settings = activeSettings
        busy = true
        defer { busy = false }
        do {
            if engine == .services {
                activeResult = try await ServiceClient.active(inputs, settings)
            } else {
                activeResult = await Task.detached { Engine.active(inputs, settings) }.value
            }
            message = "Optimized with \(activeResult!.engine) in \(String(format: "%.0f", activeResult!.milliseconds)) ms"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func buildTracker() async {
        let inputs = inputs, settings = trackingSettings
        busy = true
        defer { busy = false }
        do {
            if engine == .services {
                trackResult = try await ServiceClient.track(inputs, settings)
            } else {
                trackResult = await Task.detached { Engine.track(inputs, settings) }.value
            }
            let selection = settings.selection
            trackCurve = await Task.detached { Engine.trackingCurve(inputs, selection: selection) }.value
            message = "Tracker built with \(trackResult!.engine) in \(String(format: "%.0f", trackResult!.milliseconds)) ms"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func attribute() async {
        let p = portfolio, method = attributionMethod
        busy = true
        defer { busy = false }
        do {
            if attributeMaster {
                attribution = try await ServiceClient.attribution(portfolio: masterPortfolio, method: method)
                message = "Attribution: \(attribution!.engine)"
            } else if engine == .services {
                // The sample's monthly inputs go to the analytics service inline; the built-in engine checks its numbers.
                var service = try await ServiceClient.attribution(sample: p, method: method)
                let builtIn = await Task.detached { AttributionEngine.run(p, method: method) }.value
                let gap = Self.attributionDifference(service, builtIn)
                service.assumptions = builtIn.assumptions.dropLast() + service.assumptions
                service.reasons += builtIn.reasons.filter { $0.hasSuffix("not in the security master") }
                attribution = service
                message = gap < 1e-5
                    ? "Attribution: \(service.engine) — matches the built-in engine (largest difference \(String(format: "%.1e", gap)))"
                    : "Attribution: \(service.engine) — differs from the built-in engine by up to \(String(format: "%.2e", gap))"
            } else {
                attribution = await Task.detached { AttributionEngine.run(p, method: method) }.value
                message = "Attribution: \(attribution!.engine)"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The largest difference between two attributions' returns and effects: totals, by sector and by month.
    nonisolated static func attributionDifference(_ a: AttributionResult, _ b: AttributionResult) -> Double {
        var d = [a.portfolioReturn - b.portfolioReturn, a.benchmarkReturn - b.benchmarkReturn,
                 a.allocation - b.allocation, a.selection - b.selection, a.interaction - b.interaction]
        let bGroups = Dictionary(uniqueKeysWithValues: b.groups.map { ($0.group, $0) })
        for g in a.groups {
            guard let h = bGroups[g.group] else { d.append(g.total); continue }
            d += [g.portfolioWeight - h.portfolioWeight, g.benchmarkWeight - h.benchmarkWeight,
                  g.allocation - h.allocation, g.selection - h.selection, g.interaction - h.interaction]
        }
        for h in b.groups where !a.groups.contains(where: { $0.group == h.group }) { d.append(h.total) }
        if a.periods.count != b.periods.count { return .infinity }
        for (x, y) in zip(a.periods, b.periods) {
            d += [x.portfolioReturn - y.portfolioReturn, x.benchmarkReturn - y.benchmarkReturn,
                  x.allocation - y.allocation, x.selection - y.selection, x.interaction - y.interaction]
        }
        return d.map(abs).max() ?? 0
    }

    func reportState(_ r: MarketReport) -> ReportState {
        reports[r.id] ?? ReportState(reaction: r.reactions.first?.id)
    }

    func updateReport(_ r: MarketReport, _ change: (inout ReportState) -> Void) {
        var s = reportState(r)
        change(&s)
        reports[r.id] = s
    }

    func simulate(_ r: MarketReport) async {
        var settings = reportState(r).settings
        settings.taxable = portfolio.account.isTaxable
        settings.longTermRate = longTermRate
        settings.shortTermRate = shortTermRate
        let held = r.single.flatMap { t in portfolio.holdings.contains { $0.ticker == t } ? t : nil }
        let account = SimAccount(portfolio: portfolio, single: held)
        let shock = r.sleeveShock(portfolio)
        let reactions = r.reactions
        let single = held.flatMap(Universe.security)
        updateReport(r) { $0.running = true; $0.settings = settings }
        let result = await Task.detached {
            BehaviorLab.run(account: account, shock: shock, reactions: reactions, settings: settings,
                            singleBeta: single?.beta ?? 1.25, singleVol: single?.idioVol ?? 0.30)
        }.value
        updateReport(r) { $0.running = false; $0.result = result }
        message = "Simulated \(settings.paths) futures of \(settings.years) years"
    }

    // MARK: Taxes

    /// Realised gains and tax of selling down to the target weights: sells come from directly held positions,
    /// lot by lot in the chosen order. Names held only through a fund are listed but not estimated.
    func taxEstimate(_ trades: [Trade]) -> TaxEstimate {
        let p = portfolio
        let total = p.total
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let yearAgo = Calendar.current.date(byAdding: .year, value: -1, to: Date())!
        var lines: [TaxEstimate.Line] = []
        var via: [String] = []
        for t in trades where t.change < 0 && t.asset != "CASH" {
            var toSell = -t.change * total
            guard let h = p.holdings.first(where: { $0.ticker == t.asset }) else {
                via.append(t.asset)
                continue
            }
            toSell = min(toSell, h.value)
            let lots = h.lots.isEmpty ? [TaxLot(acquired: "—", share: 1, costBasis: h.value)] : h.lots
            let ordered = lotOrder == .fifo ? lots.sorted { $0.acquired < $1.acquired }
                : lots.sorted { $0.costBasis / max($0.share, 1e-9) > $1.costBasis / max($1.share, 1e-9) }
            for lot in ordered where toSell > 0.5 {
                let lotValue = h.value * lot.share
                let sold = min(lotValue, toSell)
                let gain = sold - lot.costBasis * sold / max(lotValue, 1e-9)
                let short = formatter.date(from: lot.acquired).map { $0 > yearAgo } ?? false
                lines.append(.init(ticker: h.ticker, acquired: lot.acquired, sold: sold, gain: gain, shortTerm: short))
                toSell -= sold
            }
        }
        var tax = 0.0
        if p.account.isTaxable {
            let st = lines.filter(\.shortTerm).reduce(0) { $0 + $1.gain }
            let lt = lines.filter { !$0.shortTerm }.reduce(0) { $0 + $1.gain }
            // Losses offset gains of the same kind first, then the other kind.
            var stNet = st, ltNet = lt
            if stNet < 0 { ltNet += stNet; stNet = 0 }
            if ltNet < 0 { stNet = max(0, stNet + ltNet); ltNet = 0 }
            tax = stNet * shortTermRate + ltNet * longTermRate
        }
        return TaxEstimate(lines: lines, tax: tax, viaFunds: via)
    }

    /// Selling every holding (to move into one index fund).
    func sellAllTaxEstimate() -> TaxEstimate {
        let p = portfolio
        let trades = p.holdings.filter { $0.security != nil && $0.ticker != "CASH" }.map { Trade(asset: $0.ticker, from: p.weight($0), to: 0) }
        return taxEstimate(trades)
    }
}
