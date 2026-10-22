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
    // In the sidebar's order (Back and Next follow it).
    case welcome, choosePath
    case myPortfolio, myBenchmark, myRisk, myImprove, myTrades, myAttribution
    case reportLibrary, morningBriefing, earningsCalendar, earningsDay, reportWalkthrough
    case whyOptimize, whyAttribution, activeVsPassive
    case samples, services

    var id: String { rawValue }

    enum Group: String, CaseIterable {
        case start = "Start Here", mine = "My Portfolio", reports = "Market Reports", learn = "Learn the Why", library = "Library"
    }

    var group: Group {
        switch self {
        case .welcome, .choosePath: .start
        case .whyOptimize, .whyAttribution, .activeVsPassive: .learn
        case .myPortfolio, .myBenchmark, .myRisk, .myImprove, .myTrades, .myAttribution: .mine
        case .reportLibrary, .morningBriefing, .earningsCalendar, .earningsDay, .reportWalkthrough: .reports
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
        case .myPortfolio: "My Holdings"
        case .myBenchmark: "My Benchmark"
        case .myRisk: "Risk Today"
        case .myImprove: "Optimize or Track"
        case .myTrades: "Trades & Rebalancing"
        case .myAttribution: "Attribution"
        case .reportLibrary: "Report Library"
        case .morningBriefing: "Morning Briefing"
        case .earningsCalendar: "Earnings Calendar"
        case .earningsDay: "Earnings by Day"
        case .reportWalkthrough: "Report Walkthrough"
        case .samples: "Sample Portfolios"
        case .services: "Layer 3 Services"
        }
    }

    /// The title with its group where the title alone is ambiguous (window title, Quick Help).
    var fullTitle: String {
        switch group {
        case .mine: "My Portfolio · \(step!). \(title)"
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
        case .myBenchmark: "target"
        case .myRisk: "waveform.path.ecg"
        case .myImprove: "slider.horizontal.3"
        case .myTrades: "arrow.left.arrow.right"
        case .myAttribution: "chart.bar.doc.horizontal"
        case .reportLibrary: "books.vertical"
        case .morningBriefing: "sunrise"
        case .earningsCalendar: "calendar"
        case .earningsDay: "list.bullet.rectangle"
        case .reportWalkthrough: "newspaper"
        case .samples: "square.grid.2x2"
        case .services: "server.rack"
        }
    }

    /// The step number on the My Portfolio path.
    var step: Int? { Screen.myPath.firstIndex(of: self).map { $0 + 1 } }

    static let myPath: [Screen] = [.myPortfolio, .myBenchmark, .myRisk, .myImprove, .myTrades, .myAttribution]

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

    /// The passive reading of a shared screen: My Portfolio run passively.
    var passiveContext: Bool { screen.group == .mine && myApproach == .passive }

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

    /// Real earnings reports (Earnings by Day, Earnings Calendar).
    let earnings = EarningsStore()

    func openEarningsDay(_ date: String, select symbol: String? = nil) {
        earnings.date = date
        earnings.selection = symbol
        screen = .earningsDay
    }

    /// The holding selected in My Holdings.
    var holdingSelection: Holding.ID?

    /// What Edit ▸ Link… (⌘K) links on this screen: the company selected in Earnings by Day, or the holding selected in
    /// My Holdings.
    var linkSelection: LinkTarget? {
        switch screen {
        case .earningsDay:
            earnings.selection.flatMap { key in earnings.days[earnings.date]?.entries.first { $0.key == key } }.map { LinkTarget.earnings($0) }
        case .myPortfolio:
            holdingSelection.flatMap { t in portfolio.holdings.first { $0.ticker == t } }.flatMap { LinkTarget.holding($0) }
        default:
            nil
        }
    }

    /// Security-master symbols in the selected account (illustrative tickers are made up, so they never match).
    var heldEarningsKeys: Set<String> {
        guard portfolio.isSRM else { return [] }
        return Set(portfolio.holdings.compactMap { h in
            h.ticker == "CASH" ? nil : EarningsParse.key(Universe.security(h.ticker)?.srmTicker ?? h.ticker)
        })
    }
    var collapsedLessons: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "collapsedLessons") ?? []) {
        didSet { UserDefaults.standard.set(Array(collapsedLessons), forKey: "collapsedLessons") }
    }

    var busy = false
    /// My Portfolio ▸ Add Securities… is open.
    var addingSecurities = false
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
                UserDefaults.standard.set(data, forKey: newValue.isSRM ? "myPortfolioSRM" : "myPortfolio")
                if newValue.isSRM { scheduleSRMSave() }
            }
            clearResults()
            srmInputs = nil
        }
    }

    // MARK: Security master (srm) account

    /// The code of My Portfolio's account in the security master.
    var srmCode = UserDefaults.standard.string(forKey: "srmAccount") ?? "MY_PORTFOLIO" {
        didSet { UserDefaults.standard.set(srmCode, forKey: "srmAccount") }
    }
    var srmBenchmarks: [SRMBenchmarkInfo] = []
    var srmAccountCodes: [String] = []
    var srmStatus: String?
    var srmBusy = false
    /// Optimization inputs of the srm account from the analytics service, and what they cover.
    var srmInputs: OptimizationInputs?
    var srmInputsNote: String?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// Switches My Portfolio between the illustrative universe and the security master; each keeps its own holdings.
    func setMySource(srm: Bool) async {
        guard let i = portfolios.firstIndex(where: { $0.id == "mine" }), portfolios[i].isSRM != srm else { return }
        UserDefaults.standard.set(srm ? "srm" : "illustrative", forKey: "mySource")
        if srm {
            await openSRMAccount(srmCode)
        } else {
            let data = UserDefaults.standard.data(forKey: "myPortfolio")
            portfolios[i] = data.flatMap { try? JSONDecoder().decode(Portfolio.self, from: $0) } ?? Samples.myPortfolio
            clearResults()
        }
    }

    /// Loads (or starts) the account `code` from the security master as My Portfolio.
    func openSRMAccount(_ code: String) async {
        srmBusy = true
        defer { srmBusy = false }
        do {
            srmBenchmarks = try await AccountsClient.benchmarks()
            srmAccountCodes = (try? await AccountsClient.accounts()) ?? []
            var mine = Samples.myPortfolio
            mine.source = "srm"
            mine.srmCode = code
            mine.holdings = []
            mine.benchmark = srmBenchmarks.first { $0.code == "SP500" }?.code ?? srmBenchmarks.first?.code ?? "MXEQ"
            mine.lesson = "Your account in the security master (srm on 192.168.0.223): real securities and prices, tax lots, and risk inputs from the analytics service."
            if srmAccountCodes.contains(where: { $0.caseInsensitiveCompare(code) == .orderedSame }) {
                let account = try await AccountsClient.account(code)
                apply(account, to: &mine)
                srmStatus = "Loaded \(account.code) from the security master: \(account.lots.count) lots, \(money(account.totalValue))."
            } else {
                srmStatus = "New account \(code): add securities and it is saved to the security master."
            }
            srmCode = code
            await useSRMBenchmark(mine.benchmark)
            if let i = portfolios.firstIndex(where: { $0.id == "mine" }) { portfolios[i] = mine }
            if let data = try? JSONEncoder().encode(mine) { UserDefaults.standard.set(data, forKey: "myPortfolioSRM") }
            clearResults()
            srmInputs = nil
        } catch {
            errorMessage = error.localizedDescription + " My Portfolio in the security master needs the accounts service: python3 Services/mxservices.py start accounts"
        }
    }

    /// Holdings and lots from the service's account.
    private func apply(_ a: SRMAccount, to p: inout Portfolio) {
        p.srmCode = a.code
        p.name = "My Portfolio"
        p.account = a.accountType == "retirement" ? .retirement : a.accountType == "roth" ? .roth : .taxable
        if let b = a.benchmark { p.benchmark = b }
        if a.approach == "active" { myApproach = .active } else if a.approach == "passive" { myApproach = .passive }
        var byKey: [String: [SRMLot]] = [:]
        var order: [String] = []
        for lot in a.lots {
            let key = SRMRegistry.shared.register(lot.security)
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(lot)
        }
        p.holdings = order.map { key in
            let lots = byKey[key]!
            let quantity = lots.reduce(0) { $0 + $1.quantity }
            let price = lots.first?.price
            let value = price.map { quantity * $0 } ?? lots.reduce(0) { $0 + $1.costBasis }
            return Holding(ticker: key, value: value,
                           lots: lots.map { TaxLot(acquired: $0.acquired, share: $0.quantity / max(quantity, 1e-9), costBasis: $0.costBasis) },
                           unpriced: price == nil, quantity: quantity)
        }
        if a.cash > 0 { p.holdings.append(Holding(ticker: "CASH", value: a.cash)) }
    }

    /// Registers a security-master benchmark's members so sector and look-through views can use it.
    func useSRMBenchmark(_ code: String) async {
        guard SRMRegistry.shared.benchmark(code) == nil, srmBenchmarks.contains(where: { $0.code == code }) else { return }
        do {
            _ = SRMRegistry.shared.register(benchmark: try await AccountsClient.benchmarkWeights(code))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Saves My Portfolio to the security master a moment after the last edit.
    private func scheduleSRMSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await self?.saveSRMAccount()
        }
    }

    func saveSRMAccount() async {
        guard let mine = portfolios.first(where: { $0.id == "mine" }), mine.isSRM, let code = mine.srmCode else { return }
        var lots: [[String: Any]] = []
        let today = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date()) }()
        for h in mine.holdings {
            guard let s = h.security, let id = s.srmID, id > 0 else { continue }
            let quantity = h.quantity ?? (s.price > 0 ? h.value / s.price : 0)
            guard quantity > 0 else { continue }
            let parts = h.lots.isEmpty ? [TaxLot(acquired: today, share: 1, costBasis: h.value)] : h.lots
            for l in parts where l.share > 0 {
                lots.append(["securityId": id, "acquired": l.acquired.count == 10 ? l.acquired : today,
                             "quantity": quantity * l.share, "costBasis": l.costBasis])
            }
        }
        let cash = mine.holdings.filter { $0.ticker == "CASH" }.reduce(0) { $0 + $1.value }
        let body: [String: Any] = ["name": "My Portfolio", "accountType": mine.account == .retirement ? "retirement" : mine.account == .roth ? "roth" : "taxable",
                                   "approach": myApproach == .active ? "active" : "passive", "benchmark": mine.benchmark,
                                   "cash": cash, "lots": lots]
        srmBusy = true
        defer { srmBusy = false }
        do {
            let saved = try await AccountsClient.save(code, body)
            let f = DateFormatter(); f.timeStyle = .short
            srmStatus = "Saved \(saved.code) to the security master at \(f.string(from: Date())): \(saved.lots.count) lots, \(money(saved.totalValue))"
                + (saved.unpriced.isEmpty ? "." : ". No prices yet for \(saved.unpriced.joined(separator: ", ")).")
            if !srmAccountCodes.contains(saved.code) { srmAccountCodes.append(saved.code) }
            srmInputs = nil
        } catch {
            srmStatus = "Not saved: \(error.localizedDescription)"
        }
    }

    /// Asks the security master to load prices for the account's unpriced holdings, then reloads it.
    func loadSRMPrices() async {
        guard let code = portfolio.srmCode else { return }
        srmBusy = true
        defer { srmBusy = false }
        do {
            await saveSRMAccount()
            let r = try await AccountsClient.loadPrices(code)
            if r.status == "failed" {
                srmStatus = "Prices could not be loaded: \(r.message ?? "the srm-loader reported a failure")."
            } else {
                srmStatus = r.loaded.isEmpty ? "Every holding already has prices." : "Loaded prices for \(r.loaded.joined(separator: ", "))."
                await openSRMAccount(code)
            }
        } catch {
            srmStatus = error.localizedDescription
        }
    }

    /// Adds a security-master security to My Portfolio: shares, and a tax lot when a cost is given.
    func addSRMHolding(_ s: SRMSecurity, quantity: Double, cost: Double?, acquired: Date?) {
        guard var mine = portfolios.first(where: { $0.id == "mine" }), mine.isSRM, quantity > 0 else { return }
        let key = SRMRegistry.shared.register(s)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let costBasis = cost ?? (s.price.map { $0 * quantity } ?? 0)
        let lotDate = f.string(from: acquired ?? Date())
        let value = s.price.map { $0 * quantity } ?? costBasis
        if let i = mine.holdings.firstIndex(where: { $0.ticker == key }) {
            var h = mine.holdings[i]
            let oldQ = h.quantity ?? 0, newQ = oldQ + quantity
            if h.lots.isEmpty { h.lots = [TaxLot(acquired: lotDate, share: 1, costBasis: h.value)] }
            h.lots = h.lots.map { var l = $0; l.share *= oldQ / newQ; return l }
            h.lots.append(TaxLot(acquired: lotDate, share: quantity / newQ, costBasis: costBasis))
            h.quantity = newQ
            h.value += value
            mine.holdings[i] = h
        } else {
            mine.holdings.append(Holding(ticker: key, value: value, lots: [TaxLot(acquired: lotDate, share: 1, costBasis: costBasis)],
                                         unpriced: s.price == nil, quantity: quantity))
        }
        portfolio = mine
    }

    /// Analytics-service inputs for the srm account (saved first, so the service sees the latest lots).
    func loadSRMInputs() async {
        let p = portfolio
        guard p.isSRM, let code = p.srmCode else { return }
        saveTask?.cancel()
        await saveSRMAccount()
        do {
            let mode = myApproach == .active ? "active" : "tracking"
            let (inputs, note) = try await ServiceClient.srmInputs(portfolio: code, benchmark: p.benchmark, mode: mode)
            srmInputs = inputs
            srmInputsNote = note
        } catch {
            srmInputsNote = error.localizedDescription
            errorMessage = error.localizedDescription
        }
    }

    /// Adds a security to My Portfolio (to the position if already held), with a tax lot when a cost is given.
    func addToMine(_ ticker: String, value: Double, cost: Double?, acquired: Date?) {
        guard var mine = portfolios.first(where: { $0.id == "mine" }), value > 0 else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let lot = cost.map { TaxLot(acquired: formatter.string(from: acquired ?? Date()), share: 0, costBasis: $0) }
        if let i = mine.holdings.firstIndex(where: { $0.ticker == ticker }) {
            var h = mine.holdings[i]
            let old = h.value, total = old + value
            if h.lots.isEmpty, lot != nil { h.lots = [TaxLot(acquired: "—", share: 1, costBasis: old)] }
            if !h.lots.isEmpty {
                h.lots = h.lots.map { var l = $0; l.share *= old / total; return l }
                var l = lot ?? TaxLot(acquired: formatter.string(from: Date()), share: 0, costBasis: value)
                l.share = value / total
                h.lots.append(l)
            }
            h.value = total
            mine.holdings[i] = h
        } else {
            var h = Holding(ticker: ticker, value: value)
            if var l = lot { l.share = 1; h.lots = [l] }
            mine.holdings.append(h)
        }
        portfolio = mine
    }

    func removeFromMine(_ ticker: String) {
        guard var mine = portfolios.first(where: { $0.id == "mine" }) else { return }
        mine.holdings.removeAll { $0.ticker == ticker }
        portfolio = mine
    }

    func resetMyPortfolio() {
        UserDefaults.standard.removeObject(forKey: "myPortfolio")
        UserDefaults.standard.set("illustrative", forKey: "mySource")
        if let i = portfolios.firstIndex(where: { $0.id == "mine" }) { portfolios[i] = Samples.myPortfolio }
        clearResults()
    }

    /// Copies a sample's holdings into My Portfolio to edit.
    func copyToMine(_ p: Portfolio) {
        var mine = Samples.myPortfolio
        mine.holdings = p.holdings.filter { $0.security != nil }
        mine.benchmark = p.benchmark
        mine.account = p.account
        UserDefaults.standard.set("illustrative", forKey: "mySource")
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

    /// The optimizers' inputs: the illustrative factor model, or for a security-master account the analytics service's.
    var inputs: OptimizationInputs { portfolio.isSRM ? srmInputs ?? .empty : OptimizationInputs(portfolio: portfolio) }

    func go(_ s: Screen) { screen = s }

    // MARK: Runs

    func optimize() async {
        if portfolio.isSRM, srmInputs == nil { await loadSRMInputs() }
        guard inputs.n > 0 else { return }
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
        if portfolio.isSRM, srmInputs == nil { await loadSRMInputs() }
        guard inputs.n > 0 else { return }
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
            if p.isSRM, let code = p.srmCode {
                await saveSRMAccount()
                attribution = try await ServiceClient.attribution(portfolio: code, method: method)
                message = "Attribution: \(attribution!.engine)"
            } else if attributeMaster {
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
