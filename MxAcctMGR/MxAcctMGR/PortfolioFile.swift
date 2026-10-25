//
//  PortfolioFile.swift
//  MxAcctMGR
//
//  One portfolio open at a time, kept in the security master like a document (File ▸ New Portfolio…, Open Portfolio…,
//  Open Recent, Close Portfolio, Save, Revert to Saved). The portfolio carries its preferences — the optimizer's limits,
//  the tracker's budget, tax rates, lot order, rebalance band, attribution method, approach — in srm.portfolio.settings
//  (V022), so they travel with it rather than with this Mac. Edits wait for Save: each save is the portfolio's next
//  version, refused when someone saved it since it was opened. Leaving a portfolio with unsaved changes — opening
//  another, closing it, quitting — first asks to Save, Discard or Cancel, listing what is unsaved.
//

import AppKit
import SwiftUI

/// The portfolio's preferences, as saved in srm.portfolio.settings. Every field is optional so an account saved
/// before V022 (settings {}) reads as "use what the app has".
nonisolated struct PortfolioSettings: Codable, Equatable, Sendable {
    var schema: Int? = 1
    var active: ActiveSettings?
    var tracking: TrackingSettings?
    var lotOrder: String?
    var longTermRate: Double?
    var shortTermRate: Double?
    var bandWidth: Double?
    var attributionMethod: String?

    init() { schema = nil }

    init(schema: Int?, active: ActiveSettings?, tracking: TrackingSettings?, lotOrder: String?, longTermRate: Double?,
         shortTermRate: Double?, bandWidth: Double?, attributionMethod: String?) {
        self.schema = schema
        self.active = active
        self.tracking = tracking
        self.lotOrder = lotOrder
        self.longTermRate = longTermRate
        self.shortTermRate = shortTermRate
        self.bandWidth = bandWidth
        self.attributionMethod = attributionMethod
    }
}

/// Leaving a portfolio with unsaved changes: what is unsaved, and what to do once it is saved or discarded.
struct LeavePrompt: Identifiable {
    let id = UUID()
    /// "open SAMPLE_X", "close the portfolio", "quit"
    var action: String
    var looseEnds: [String]
    var proceed: @MainActor () async -> Void
}

extension PortStore {
    /// The preferences as the screens have them now.
    var currentSettings: PortfolioSettings {
        PortfolioSettings(schema: 1, active: activeSettings, tracking: trackingSettings, lotOrder: lotOrder.rawValue,
                          longTermRate: longTermRate, shortTermRate: shortTermRate, bandWidth: bandWidth,
                          attributionMethod: attributionMethod.rawValue)
    }

    /// Takes a portfolio's saved preferences (the ones it has; the rest stay as they are).
    func apply(_ s: PortfolioSettings) {
        if let v = s.active { activeSettings = v }
        if let v = s.tracking { trackingSettings = v }
        if let v = s.lotOrder.flatMap(LotOrder.init(rawValue:)) { lotOrder = v }
        if let v = s.longTermRate { longTermRate = v }
        if let v = s.shortTermRate { shortTermRate = v }
        if let v = s.bandWidth { bandWidth = v }
        if let v = s.attributionMethod.flatMap(AttributionEngine.Method.init(rawValue:)) { attributionMethod = v }
    }

    /// The open portfolio (nil when none is open).
    var openPortfolio: Portfolio? {
        guard mineLoadedCode != nil else { return nil }
        return portfolios.first { $0.id == "mine" }
    }

    /// Records `mine` as the saved state of the open portfolio (after Open, Save or Revert).
    func markSaved(_ mine: Portfolio, version: Int) {
        openVersion = version
        savedHoldings = mine.holdings
        savedBenchmark = mine.benchmark
        savedAccountType = mine.account
        savedName = mine.name
        savedApproach = myApproach
        savedSettings = currentSettings
        if let data = try? JSONEncoder().encode(mine) { UserDefaults.standard.set(data, forKey: "myPortfolioSRM") }
    }

    /// What differs from the saved portfolio, in words (empty: nothing to save).
    var looseEnds: [String] {
        guard let p = openPortfolio else { return [] }
        var out: [String] = []
        if p.holdings != savedHoldings {
            let before = Set(savedHoldings.map(\.ticker)), now = Set(p.holdings.map(\.ticker))
            let added = now.subtracting(before).count, removed = before.subtracting(now).count
            let changed = p.holdings.filter { h in savedHoldings.first { $0.ticker == h.ticker }.map { $0 != h } ?? false }.count
            out.append("Holdings: " + [added > 0 ? "\(added) added" : nil, removed > 0 ? "\(removed) removed" : nil,
                                       changed > 0 ? "\(changed) changed" : nil].compactMap { $0 }.joined(separator: ", "))
        }
        if p.name != savedName { out.append("Name: \(savedName) → \(p.name)") }
        if p.benchmark != savedBenchmark { out.append("Benchmark: \(savedBenchmark) → \(p.benchmark)") }
        if p.account != savedAccountType { out.append("Account type: \(savedAccountType.rawValue) → \(p.account.rawValue)") }
        if myApproach != savedApproach { out.append("Approach: \(savedApproach.rawValue) → \(myApproach.rawValue)") }
        if currentSettings != savedSettings { out.append("Preferences (optimizer, tracker, taxes, lots, bands or attribution)") }
        return out
    }

    var isDirty: Bool { !looseEnds.isEmpty }

    /// Runs `proceed` now when the open portfolio has nothing unsaved, else asks to Save, Discard or Cancel first.
    func whenSettled(_ action: String, _ proceed: @escaping @MainActor () async -> Void) {
        let ends = looseEnds
        if ends.isEmpty {
            Task { await proceed() }
        } else {
            leavePrompt = LeavePrompt(action: action, looseEnds: ends, proceed: proceed)
        }
    }

    /// Opens a portfolio from the security master (File ▸ Open Portfolio…, Open Recent), after the open one is settled.
    func requestOpen(_ code: String) {
        let c = code.trimmingCharacters(in: .whitespaces).uppercased()
        guard !c.isEmpty else { return }
        whenSettled("open \(c)") { [self] in
            await openSRMAccount(c)
            selectedID = "mine"
            if !Screen.myPath.contains(screen) { go(.myPortfolio) }
        }
    }

    /// Creates a portfolio in the security master and opens it (File ▸ New Portfolio…). `from` copies a sample's
    /// holdings, lots and benchmark into it.
    func createPortfolio(code: String, name: String, account: AccountType, approach: PortfolioStyle, benchmark: String,
                         from sample: Portfolio?) async -> String? {
        let c = code.trimmingCharacters(in: .whitespaces).uppercased()
        var lots: [[String: Any]] = []
        var cash = 0.0
        if let sample {
            for h in sample.holdings {
                if h.ticker == "CASH" { cash += h.value; continue }
                guard let s = h.security, let id = s.srmID, id > 0, let q = h.quantity, q > 0 else { continue }
                for l in h.lots where l.share > 0 {
                    var lot: [String: Any] = ["securityId": id, "acquired": l.acquired, "quantity": q * l.share, "costBasis": l.costBasis]
                    if let note = l.note, !note.isEmpty { lot["note"] = note }
                    lots.append(lot)
                }
            }
        }
        let body: [String: Any] = ["version": 0, "name": name.isEmpty ? c : name,
                                   "accountType": account == .retirement ? "retirement" : account == .roth ? "roth" : "taxable",
                                   "approach": approach == .active ? "active" : "passive", "benchmark": benchmark,
                                   "cash": cash, "lots": lots, "by": "MxAcctMGR",
                                   "note": sample.map { "New, from the sample \($0.name)" } ?? "New"]
        do {
            _ = try await AccountsClient.save(c, body)
        } catch {
            return error.localizedDescription
        }
        await openSRMAccount(c)
        selectedID = "mine"
        go(.myPortfolio)
        return nil
    }

    /// Closes the open portfolio (File ▸ Close Portfolio): the Investments steps then ask to open or create one.
    func closePortfolio() {
        whenSettled("close \(srmCode)") { [self] in
            var empty = Samples.myPortfolio
            empty.srmCode = nil
            empty.name = "No portfolio open"
            if let i = portfolios.firstIndex(where: { $0.id == "mine" }) { portfolios[i] = empty }
            mineLoadedCode = nil
            openVersion = 0
            srmCode = ""
            srmStatus = nil
            srmInputs = nil
            clearResults()
        }
    }

    /// Recently opened portfolio codes, newest first (File ▸ Open Recent).
    var recentPortfolios: [String] { UserDefaults.standard.stringArray(forKey: "recentPortfolios") ?? [] }

    func noteRecent(_ code: String) {
        var list = recentPortfolios.filter { $0.caseInsensitiveCompare(code) != .orderedSame }
        list.insert(code, at: 0)
        UserDefaults.standard.set(Array(list.prefix(8)), forKey: "recentPortfolios")
    }

    func clearRecent() { UserDefaults.standard.removeObject(forKey: "recentPortfolios") }

    /// Quitting with unsaved changes: Save, Don't Save or Cancel (the app delegate asks).
    func terminateReply() -> NSApplication.TerminateReply {
        let ends = looseEnds
        guard !ends.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Save changes to \(srmCode) before quitting?"
        alert.informativeText = ends.map { "• " + $0 }.joined(separator: "\n")
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { @MainActor in NSApp.reply(toApplicationShouldTerminate: await self.saveSRMAccount()) }
            return .terminateLater
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}

/// Asks the store before the app quits (unsaved portfolio changes).
final class PortAppDelegate: NSObject, NSApplicationDelegate {
    static weak var store: PortStore?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.store?.terminateReply() ?? .terminateNow
    }
}
