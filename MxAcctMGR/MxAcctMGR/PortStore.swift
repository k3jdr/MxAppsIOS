//
//  PortStore.swift
//  MxAcctMGR
//
//  The window's state: the screen shown, the account selected, the settings and results of each step, and the
//  walkthroughs' progress. Optimizations and simulations run off the main thread; the built-in engine is always
//  available, the Layer 3 services when they are running.
//

import Foundation
import Observation

enum Screen: String, CaseIterable, Identifiable {
    // In the sidebar's order (Back and Next follow it). Welcome and Choose Your Path aren't in the sidebar: the Guide
    // menu opens them.
    case checking, cards, expenseLedgers, expenses, secureAccounts
    case welcome, choosePath
    case myPortfolio, myBenchmark, myRisk, myImprove, myTrades, myAttribution
    case reportLibrary, morningBriefing, earningsCalendar, earningsDay, vix, compute, reportWalkthrough
    case whyOptimize, whyAttribution, activeVsPassive, samples
    case securities, services

    var id: String { rawValue }

    enum Group: String, CaseIterable {
        case accounts = "Banking", start = "Start Here", mine = "Investments", reports = "Knowledge Library",
             library = "Data Library"

        /// The sidebar's sections (Start Here's screens are in the Guide menu only).
        static let sidebar: [Group] = [.accounts, .mine, .reports, .library]
    }

    var group: Group {
        switch self {
        case .checking, .cards, .expenseLedgers, .expenses, .secureAccounts: .accounts
        case .welcome, .choosePath: .start
        case .myPortfolio, .myBenchmark, .myRisk, .myImprove, .myTrades, .myAttribution: .mine
        case .reportLibrary, .morningBriefing, .earningsCalendar, .earningsDay, .vix, .compute, .reportWalkthrough,
             .whyOptimize, .whyAttribution, .activeVsPassive, .samples: .reports
        case .securities, .services: .library
        }
    }

    var title: String {
        switch self {
        case .checking: "Checking Accounts"
        case .cards: "Credit Card Accounts"
        case .expenseLedgers: "Expense Accounts"
        case .expenses: "Target Accounts"
        case .secureAccounts: "Secure Accounts"
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
        case .vix: "CBOE Volatility Index (VIX)"
        case .compute: "Compute Hyperscalers Tracking"
        case .reportWalkthrough: "Report Walkthrough"
        case .securities: "Securities"
        case .samples: "Sample Portfolios"
        case .services: "Layer 3 Services"
        }
    }

    /// The title with its group where the title alone is ambiguous (window title, Quick Help).
    var fullTitle: String {
        switch group {
        case .mine: "Investments · \(step!). \(title)"
        default: title
        }
    }

    var systemImage: String {
        switch self {
        case .checking: "checkmark.rectangle.stack"
        case .cards: "creditcard"
        case .expenseLedgers: "briefcase"
        case .expenses: "arrow.left.arrow.right.square"
        case .secureAccounts: "lock.shield"
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
        case .vix: "waveform.path.ecg.rectangle"
        case .compute: "cpu"
        case .reportWalkthrough: "newspaper"
        case .securities: "doc.text.magnifyingglass"
        case .samples: "square.grid.2x2"
        case .services: "server.rack"
        }
    }

    /// The step number on the Investments path.
    var step: Int? { Screen.myPath.firstIndex(of: self).map { $0 + 1 } }

    static let myPath: [Screen] = [.myPortfolio, .myBenchmark, .myRisk, .myImprove, .myTrades, .myAttribution]

    /// The next and previous screens in the guide's order.
    /// The screens Back and Next step through: the sidebar's, in its order (less those Settings ▸ Guidance hides).
    static var guide: [Screen] { allCases.filter { Group.sidebar.contains($0.group) && PortSettings.shared.shows($0) } }
    var next: Screen? { Screen.guide.firstIndex(of: self).flatMap { $0 + 1 < Screen.guide.count ? Screen.guide[$0 + 1] : nil } }
    var previous: Screen? { Screen.guide.firstIndex(of: self).flatMap { $0 > 0 ? Screen.guide[$0 - 1] : nil } }
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
    var screen: Screen = .myPortfolio {
        didSet {
            // A lesson-only page that Settings ▸ Guidance hides opens My Portfolio instead.
            if !PortSettings.shared.shows(screen) { screen = .myPortfolio; return }
            UserDefaults.standard.set(screen.rawValue, forKey: "screen")
            // The Investments path always works on the user's own account (My Portfolio).
            if screen.group == .mine, selectedID != "mine" { selectedID = "mine" }
        }
    }
    /// How the user runs My Portfolio: active (optimize, trades & taxes) or passive (track, rebalance bands).
    var myApproach: PortfolioStyle = UserDefaults.standard.string(forKey: "myApproach") == PortfolioStyle.active.rawValue ? .active : .passive {
        didSet { UserDefaults.standard.set(myApproach.rawValue, forKey: "myApproach") }
    }

    /// The passive reading of a shared screen: My Portfolio run passively.
    var passiveContext: Bool { screen.group == .mine && myApproach == .passive }

    /// A screen's title as shown: Investments' steps 3 and 4 follow the approach; the walkthrough shows its report.
    func title(_ s: Screen, full: Bool = true) -> String {
        let short: String
        switch s {
        case .myImprove: short = myApproach == .active ? "Optimize" : "Build the Tracker"
        case .myTrades: short = myApproach == .active ? "Trades & Taxes" : "Rebalance Bands"
        case .reportWalkthrough: return currentReport.title
        default: return full ? s.fullTitle : (s.step.map { "\($0). \(s.title)" } ?? s.title)
        }
        return full ? "Investments · \(s.step!). \(short)" : "\(s.step!). \(short)"
    }

    var portfolios: [Portfolio]
    /// Bumped when the registry's risk numbers change outside srmInputs (SRMRegistry isn't observable).
    var riskStamp = 0
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
    /// The open report, with its company (if it is about one) taken from the selected account.
    var currentReport: MarketReport { MarketReport.report(reportID).resolved(for: portfolio) }

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

    // Back and Forward through the places visited, as in a browser (Navigation.swift).
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    /// Bumped whenever the Back / Forward lists change (their menus redraw).
    private(set) var historyVersion = 0
    @ObservationIgnored var backStack: [Place] = [] { didSet { historyChanged() } }
    @ObservationIgnored var forwardStack: [Place] = [] { didSet { historyChanged() } }
    /// The place the history is at (set before Back or Forward shows it, so it isn't recorded again).
    @ObservationIgnored var historyCurrent: Place?

    private func historyChanged() {
        canGoBack = !backStack.isEmpty
        canGoForward = !forwardStack.isEmpty
        historyVersion += 1
    }

    /// The holdings selected in My Holdings (⌘-click, ⇧-click, ⌘A).
    var holdingSelection: Set<Holding.ID> = []
    /// The selected holding when exactly one is.
    var selectedHolding: Holding.ID? { holdingSelection.count == 1 ? holdingSelection.first : nil }

    /// What Edit ▸ Link… (⌘K) links on this screen: the company selected in Earnings by Day, or the holding selected in
    /// My Holdings.
    var linkSelection: LinkTarget? {
        switch screen {
        case .earningsDay:
            earnings.selection.flatMap { key in earnings.days[earnings.date]?.entries.first { $0.key == key } }.map { LinkTarget.earnings($0) }
        case .myPortfolio:
            selectedHolding.flatMap { t in portfolio.holdings.first { $0.ticker == t } }.flatMap { LinkTarget.holding($0) }
        default:
            nil
        }
    }

    /// Security-master symbols in the selected account.
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
    /// Investments ▸ Add Securities… is open.
    var addingSecurities = false
    /// The row selected in Add Securities, for Edit ▸ Link… while that dialog is open.
    var addSecuritiesLink: LinkTarget?
    var message: String?
    var errorMessage: String?

    init() {
        // Every account comes from the security master (loadAccounts): until it answers, the samples are empty
        // placeholders and My Portfolio is the last copy kept on this Mac.
        var list = Samples.lessons.map { l in
            Portfolio(id: l.code, name: Samples.placeholderName(l.code), account: .taxable, benchmark: "SP500", style: l.style,
                      holdings: [], lesson: l.lesson, lookFor: l.lookFor, trading: l.trading, symbol: l.symbol,
                      source: "srm", srmCode: l.code)
        }
        if UserDefaults.standard.string(forKey: "srmAccount") == "" {
            // Closed (File ▸ Close Portfolio) when the app last quit.
            var none = Samples.myPortfolio
            none.srmCode = nil
            none.name = "No portfolio open"
            list.append(none)
        } else if let data = UserDefaults.standard.data(forKey: "myPortfolioSRM"), let mine = try? JSONDecoder().decode(Portfolio.self, from: data),
           mine.isSRM {
            list.append(mine)
        } else {
            list.append(Samples.myPortfolio)
        }
        portfolios = list
        let saved = UserDefaults.standard.string(forKey: "sample") ?? ""
        selectedID = list.contains { $0.id == saved } ? saved : "SAMPLE_CORE_SATELLITE"
        if let s = UserDefaults.standard.string(forKey: "screen").flatMap(Screen.init(rawValue:)) { screen = s }
    }

    /// Why the accounts couldn't be read (accounts service or database down), shown instead of any data.
    var dataProblem: String?
    var accountsLoaded = false

    /// Reads every account from the security master: the samples and My Portfolio, with their benchmarks.
    func loadAccounts() async {
        do {
            srmBenchmarks = try await AccountsClient.benchmarks()
            for l in Samples.lessons {
                let a = try await AccountsClient.account(l.code)
                var p = Samples.portfolio(a, lesson: l)
                apply(a, to: &p)
                if let i = portfolios.firstIndex(where: { $0.id == l.code }) { portfolios[i] = p }
                await useSRMBenchmark(p.benchmark)
            }
            dataProblem = nil
            accountsLoaded = true
        } catch {
            dataProblem = "The sample accounts are in the security master: " + error.localizedDescription
                + " Start the services (python3 Services/mxservices.py start) and make sure the database is reachable."
        }
        await openSRMAccount(srmCode)
        clearResults()
        srmInputs = nil
    }

    var portfolio: Portfolio {
        get { portfolios.first { $0.id == selectedID } ?? portfolios[0] }
        set {
            guard let i = portfolios.firstIndex(where: { $0.id == newValue.id }) else { return }
            portfolios[i] = newValue
            // My Portfolio's edits wait for File ▸ Save (or the Save / Discard check before switching or quitting).
            clearResults()
            srmInputs = nil
        }
    }

    // MARK: Security master (srm) account

    /// The code of the open portfolio in the security master ("" when none is open).
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
    /// The security-master account My Portfolio was read from this session. Nothing is saved before it is read: the
    /// placeholder My Portfolio (no holdings) saved over the real account would delete its lots — a screen that saves
    /// before computing (Risk Today's inputs) did that when it opened before the account had loaded.
    var mineLoadedCode: String?

    // The open portfolio as last read or saved (PortfolioFile.swift: File ▸ New, Open, Save, Revert, Close).
    /// Its version in the security master (0: new, not saved yet); a save names it and is refused when it moved on.
    var openVersion = 0
    var savedHoldings: [Holding] = []
    var savedBenchmark = ""
    var savedAccountType: AccountType = .taxable
    var savedApproach: PortfolioStyle = .active
    var savedName = ""
    var savedSettings = PortfolioSettings()
    /// Save / Discard / Cancel before leaving a portfolio with unsaved changes.
    var leavePrompt: LeavePrompt?
    /// A save refused because the portfolio changed in the security master since it was opened.
    var saveConflict: String?
    var showOpenPortfolio = false
    var showNewPortfolio = false
    var showDecisions = false
    var showDuplicate = false
    var showRename = false
    var showPolicyEditor = false
    /// Holdings read from a CSV file, waiting for Add or Replace (File ▸ Import Holdings…).
    var importPreview: ImportPreview?

    /// Loads (or starts) the account `code` from the security master as My Portfolio.
    func openSRMAccount(_ code: String) async {
        guard !code.isEmpty else { return }
        srmBusy = true
        defer { srmBusy = false }
        do {
            srmBenchmarks = try await AccountsClient.benchmarks()
            srmAccountCodes = (try? await AccountsClient.accounts()) ?? []
            var mine = Samples.myPortfolio
            mine.srmCode = code
            mine.benchmark = srmBenchmarks.first { $0.code == "SP500" }?.code ?? srmBenchmarks.first?.code ?? "SP500"
            var version = 0
            if srmAccountCodes.contains(where: { $0.caseInsensitiveCompare(code) == .orderedSame }) {
                let account = try await AccountsClient.account(code)
                apply(account, to: &mine)
                version = account.version ?? 1
                if let settings = account.settings, settings != PortfolioSettings() { apply(settings) }
                srmStatus = "Opened \(account.code) (version \(version)): \(account.lots.count) lots, \(money(account.totalValue))."
            } else {
                srmStatus = "New portfolio \(code): add securities, then File ▸ Save."
            }
            srmCode = code
            mineLoadedCode = code
            markSaved(mine, version: version)
            noteRecent(code)
            await useSRMBenchmark(mine.benchmark)
            if let i = portfolios.firstIndex(where: { $0.id == "mine" }) { portfolios[i] = mine }
            if let data = try? JSONEncoder().encode(mine) { UserDefaults.standard.set(data, forKey: "myPortfolioSRM") }
            clearResults()
            srmInputs = nil
        } catch {
            dataProblem = dataProblem ?? ("My Portfolio is in the security master: " + error.localizedDescription
                + " Start the accounts service: python3 Services/mxservices.py start accounts")
        }
    }

    /// Holdings and lots from the service's account.
    private func apply(_ a: SRMAccount, to p: inout Portfolio) {
        p.srmCode = a.code
        p.account = a.accountType == "retirement" ? .retirement : a.accountType == "roth" ? .roth : .taxable
        if let b = a.benchmark { p.benchmark = b }
        if p.id == "mine" {
            p.name = a.name
            if a.approach == "active" { myApproach = .active } else if a.approach == "passive" { myApproach = .passive }
        }
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
                           lots: lots.map { TaxLot(acquired: $0.acquired, share: $0.quantity / max(quantity, 1e-9), costBasis: $0.costBasis, note: $0.note) },
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
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
        }
    }

    /// Saves the open portfolio as its next version (File ▸ Save). False when nothing was saved: none open, or the
    /// service refused it — a conflict (saved elsewhere since it was opened) shows in saveConflict.
    @discardableResult
    func saveSRMAccount() async -> Bool {
        guard let mine = portfolios.first(where: { $0.id == "mine" }), mine.isSRM, let code = mine.srmCode else { return false }
        guard mineLoadedCode?.caseInsensitiveCompare(code) == .orderedSame else { return false }
        var lots: [[String: Any]] = []
        let today = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date()) }()
        for h in mine.holdings {
            guard let s = h.security, let id = s.srmID, id > 0 else { continue }
            let quantity = h.quantity ?? (s.price > 0 ? h.value / s.price : 0)
            guard quantity > 0 else { continue }
            let parts = h.lots.isEmpty ? [TaxLot(acquired: today, share: 1, costBasis: h.value)] : h.lots
            for l in parts where l.share > 0 {
                var lot: [String: Any] = ["securityId": id, "acquired": l.acquired.count == 10 ? l.acquired : today,
                                          "quantity": quantity * l.share, "costBasis": l.costBasis]
                if let note = l.note, !note.isEmpty { lot["note"] = note }
                lots.append(lot)
            }
        }
        let cash = mine.holdings.filter { $0.ticker == "CASH" }.reduce(0) { $0 + $1.value }
        let settingsJSON = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(currentSettings))) ?? [:]
        let body: [String: Any] = ["name": mine.name, "accountType": mine.account == .retirement ? "retirement" : mine.account == .roth ? "roth" : "taxable",
                                   "approach": myApproach == .active ? "active" : "passive", "benchmark": mine.benchmark,
                                   "cash": cash, "lots": lots, "version": openVersion, "settings": settingsJSON, "by": "MxAcctMGR",
                                   "note": looseEnds.joined(separator: "; ")]
        srmBusy = true
        defer { srmBusy = false }
        do {
            let saved = try await AccountsClient.save(code, body)
            let f = DateFormatter(); f.timeStyle = .short
            srmStatus = "Saved \(saved.code) version \(saved.version ?? 0) at \(f.string(from: Date())): \(saved.lots.count) lots, \(money(saved.totalValue))"
                + (saved.unpriced.isEmpty ? "." : ". No prices yet for \(saved.unpriced.joined(separator: ", ")).")
            if !srmAccountCodes.contains(saved.code) { srmAccountCodes.append(saved.code) }
            markSaved(mine, version: saved.version ?? openVersion + 1)
            srmInputs = nil
            return true
        } catch ServiceClient.Failure.conflict(let message) {
            saveConflict = message
            srmStatus = "Not saved: changed in the security master since it was opened."
            return false
        } catch {
            srmStatus = "Not saved: \(error.localizedDescription)"
            errorMessage = "\(code) was not saved: \(error.localizedDescription)"
            return false
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
            if !(error is CancellationError) { srmStatus = error.localizedDescription }
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

    /// Analytics-service inputs for the selected account (My Portfolio is saved first, so the service sees its lots).
    func loadSRMInputs() async {
        let p = portfolio
        guard let code = p.srmCode else { return }
        do {
            let active = p.id == "mine" ? myApproach == .active : p.style != .passive
            let mode = active ? "active" : "tracking"
            if p.id == "mine" && isDirty {
                // Unsaved edits: the service reads saved holdings, so it gets the securities and the benchmark, and the
                // weights come from the holdings on screen.
                let tickers = p.holdings.compactMap { h in h.ticker == "CASH" ? nil : h.security?.displayTicker }
                var body: [String: Any] = ["securities": tickers, "benchmark": p.benchmark, "mode": mode]
                if !active { body["alpha"] = "none" }
                var (inputs, note) = try await ServiceClient.riskInputs(body)
                let invested = p.holdings.filter { $0.ticker != "CASH" }.reduce(0) { $0 + $1.value }
                inputs.current = inputs.assets.map { key in
                    invested > 0 ? (p.holdings.first { $0.ticker == key }?.value ?? 0) / invested : 0
                }
                srmInputs = inputs
                srmInputsNote = note + " (unsaved holdings)"
            } else {
                let (inputs, note) = try await ServiceClient.srmInputs(portfolio: code, benchmark: p.benchmark, mode: mode)
                srmInputs = inputs
                srmInputsNote = note
            }
        } catch {
            guard !(error is CancellationError) else { return }
            srmInputsNote = error.localizedDescription
            errorMessage = error.localizedDescription
        }
    }

    /// Gives the selected account's holdings their market and rate betas from the analytics service when they don't
    /// have them yet (the report walkthroughs and the Morning Briefing move each holding by them).
    func ensureHoldingRisk() async {
        let missing = portfolio.holdings.compactMap(\.security).filter { !$0.hasRisk && $0.assetClass != .cash }
        guard !missing.isEmpty else { return }
        do {
            _ = try await ServiceClient.riskInputs(securities: missing.map(\.displayTicker))
            riskStamp += 1
        } catch {
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
        }
    }

    func removeFromMine(_ ticker: String) {
        guard var mine = portfolios.first(where: { $0.id == "mine" }) else { return }
        mine.holdings.removeAll { $0.ticker == ticker }
        portfolio = mine
    }

    /// Reads the open portfolio again from the security master, dropping unsaved edits (File ▸ Revert to Saved).
    func resetMyPortfolio() {
        guard !srmCode.isEmpty else { return }
        Task { await openSRMAccount(srmCode) }
    }

    /// Copies a sample's holdings and lots into the open portfolio to edit (saved with File ▸ Save).
    func copyToMine(_ p: Portfolio) {
        guard openPortfolio != nil, var mine = portfolios.first(where: { $0.id == "mine" }) else {
            errorMessage = "No portfolio is open: File ▸ New Portfolio… (it can start from a sample) or Open Portfolio…"
            return
        }
        mine.holdings = p.holdings
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

    /// The optimizers' inputs: the analytics service's for the selected account (empty until loaded).
    var inputs: OptimizationInputs { srmInputs ?? .empty }

    func go(_ s: Screen) { screen = s }

    // MARK: Runs

    func optimize() async {
        if srmInputs == nil { await loadSRMInputs() }
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
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
        }
    }

    func buildTracker() async {
        if srmInputs == nil { await loadSRMInputs() }
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
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
        }
    }

    func attribute() async {
        let p = portfolio, method = attributionMethod
        busy = true
        defer { busy = false }
        do {
            // The analytics service attributes the account from its holdings history in the security master.
            let code = attributeMaster ? masterPortfolio : (p.srmCode ?? "")
            if p.id == "mine", !attributeMaster { await saveSRMAccount() }
            attribution = try await ServiceClient.attribution(portfolio: code, method: method)
            message = "Attribution: \(attribution!.engine)"
        } catch {
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
        }
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
