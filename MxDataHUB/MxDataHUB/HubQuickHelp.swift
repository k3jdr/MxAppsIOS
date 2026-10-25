//
//  HubQuickHelp.swift
//  MxDataHUB
//
//  What Quick Help (Shared/QuickHelp) says in MxDataHUB: each screen in the sidebar, what's selected on it,
//  and the controls and panels the pointer can rest on.
//

import SwiftUI

enum HubHelp {
    // MARK: Screens

    /// What a screen is for (the sidebar rows, and the screen itself when connected).
    static func about(_ section: SRMSection) -> QuickHelpItem {
        let detail: String
        switch section {
        case .connection:
            detail = "The PostgreSQL server and database that hold the security master (schema srm): host, port, user, database, password and SSL mode — the same screen as MxDataSQL's. "
                + "The fields are remembered; the password only in the Keychain. Once connected, the Database drop-down in the toolbar switches databases."
        case .securities:
            detail = "Search the security master by name or any identifier — ticker, TICKER:MIC, ISIN, CUSIP, SEDOL, FIGI, CIK or LEI — and filter by type, benchmark and active only. "
                + "Select a security for its prices, identifiers with their history, issuer, listings, classification, benchmark weights and corporate actions."
        case .portfolios:
            detail = "Portfolios and their dated holdings snapshots. Add holdings by any identifier as shares or a target weight, paste a list, or copy a benchmark's weights. "
                + "Each snapshot is valued with the latest prices, checked (weights add up, every holding priced) and compared with the portfolio's benchmark."
        case .benchmarks:
            detail = "Loaded benchmarks: constituents and weights, sector weights and the index level. Build custom benchmarks from another's members, "
                + "see which benchmarks the data sources can supply, and track one with a portfolio in MxJobsMGR."
        case .refresh:
            detail = "Every category of market data in the security master: how fresh it is, when it was last loaded, and Refresh to run its srm.py loaders now through "
                + "the SRM loader service on this Mac (127.0.0.1:8770). Refresh All runs them in dependency order; Preview only shows the commands. "
                + "Automate in MxJobsMGR… opens the scheduled, checked and approved SRM Daily Refresh. "
                + "Activity, on the right, streams what the loaders print as they run — from here or from MxJobsMGR — with warnings and errors marked."
        case .loads:
            detail = "Where the data came from: how many securities have each identifier and from which sources, the data sources with their plan limits, "
                + "the dated benchmark and portfolio weight snapshots attribution uses (a gap over a month shows in orange), and every load run with its row counts."
        case .services:
            detail = "Workflows: the MxJobsMGR samples built on this data — portfolio workflows open for the portfolio selected in Portfolios. "
                + "Layer 3 Services: the shared services (Services/) that refresh and analyse the security master, what each is for and how to start it."
        }
        return QuickHelpItem(title: section.rawValue, detail: detail, symbol: section.systemImage)
    }

    /// The screen shown: what it's for, or why it's empty (not connected, no srm schema).
    static func screen(_ store: SRMStore) -> QuickHelpItem {
        let section = store.section
        if section.needsConnection, !store.isConnected {
            return QuickHelpItem(title: "\(section.rawValue): Not Connected",
                                 detail: "\(section.rawValue) reads the security master, so it needs a connection to its database. "
                                    + "Set it up in DB Connection (⌘1) and Connect (⇧⌘K).",
                                 shortcut: "⇧⌘K", symbol: "cable.connector.slash")
        }
        if section.needsConnection, store.available != true {
            return QuickHelpItem(title: "\(section.rawValue): No Security Master",
                                 detail: "Database \(store.connectedSettings?.database ?? "") has no srm schema. Pick the database that has it in the Database drop-down, "
                                    + "or create it with SRM/srm.py migrate and load it with SRM/srm.py load all.",
                                 symbol: "building.columns")
        }
        return about(section)
    }

    /// What's selected on the screen.
    static func selection(_ store: SRMStore) -> QuickHelpItem? {
        guard store.isConnected else { return nil }
        switch store.section {
        case .securities:
            guard store.selectedSecurityID != nil, let s = store.detail?.security else { return nil }
            let facts = [s.ticker, s.mic, s.type, s.sector, s.isActive ? "" : "inactive"].filter { !$0.isEmpty }.joined(separator: " · ")
            return QuickHelpItem(title: s.name,
                                 detail: facts + "\nOn the right: its price history, identifiers (grey values are past ones, with the dates they were valid), "
                                    + "issuer facts, listings, classification, the benchmarks it's in with its weight, and corporate actions. Select a value to copy it.",
                                 symbol: "building.2")
        case .portfolios:
            guard let p = store.selectedPortfolio else { return nil }
            let valid = store.holdings.isEmpty ? "No holdings on this date yet."
                : store.issues.isEmpty ? "Valid: weights add up and every holding is priced."
                : "\(store.issues.count) problem\(store.issues.count == 1 ? "" : "s") under the holdings."
            return QuickHelpItem(title: "\(p.code) — \(p.name)",
                                 detail: "\(store.holdings.count) holdings on \(store.snapshotDate ?? "–")"
                                    + (p.benchmarkCode.isEmpty ? ", no benchmark. " : " against \(p.benchmarkCode). ") + valid
                                    + " Holdings on picks another date; vs Benchmark shows active weights; Workflows opens it in MxJobsMGR.",
                                 symbol: "briefcase")
        case .benchmarks:
            guard let b = store.selectedBenchmark else { return nil }
            return QuickHelpItem(title: "\(b.code) — \(b.name)",
                                 detail: "\(b.method.replacingOccurrences(of: "_", with: " "))-weighted, from \(b.source)"
                                    + (b.asOf.isEmpty ? "; no constituents loaded." : "; \(b.members) members on \(b.asOf).")
                                    + (b.isProxy ? " A proxy: \(b.proxyNote)" : "")
                                    + " Its sector weights, index level and constituents are on the right; Track… builds a tracking portfolio in MxJobsMGR.",
                                 symbol: "chart.pie")
        default:
            return nil
        }
    }

    // MARK: Securities

    static let search = QuickHelpItem(title: "Security Search",
                                      detail: "Type a name or any identifier — AAPL, AAPL:XNAS, US0378331005, 037833100, 2046251, BBG000B9XRY4, a CIK or LEI — and press Return. "
                                        + "Type, In (benchmark) and Active only narrow the results, 1,000 to a page.",
                                      shortcut: "↩", symbol: "magnifyingglass")
    static let results = QuickHelpItem(title: "Results",
                                       detail: "The matching securities with their main identifiers, sector and MIC, 1,000 to a page (Previous / Next below). "
                                        + "A column header's ▾ button sorts the column or filters it by values or a condition, as in Excel; the database does the work, so it covers every page. "
                                        + "Select a security to see everything about it on the right.",
                                       symbol: "list.bullet.rectangle")
    static let securityDetail = QuickHelpItem(title: "Security Detail",
                                              detail: "Prices, then identifiers with their history (From / To; grey ones are past values), issuer and security facts, listings, classification, "
                                                + "benchmark membership with weights, and corporate actions.",
                                              symbol: "doc.text.magnifyingglass")

    // MARK: Portfolios

    static let portfolioList = QuickHelpItem(title: "Portfolios",
                                             detail: "Your portfolios with their benchmarks. Select one for its holdings; double-click to edit its code, name, currency and benchmark.",
                                             symbol: "briefcase")
    static let holdings = QuickHelpItem(title: "Holdings",
                                        detail: "The snapshot's holdings: what you entered and how (ticker, ISIN…), shares, target weight, the latest price, market value and weight. "
                                            + "Select rows and Remove to take them out. A problem shows under the table: weights that don't add up, an unpriced holding.",
                                        symbol: "tablecells")
    static let activeWeights = QuickHelpItem(title: "vs Benchmark",
                                             detail: "Each security's weight in the portfolio and in the benchmark and the difference (active weight), largest first, "
                                                + "with the overlap and active share (1 − overlap).",
                                             symbol: "plusminus")

    // MARK: Benchmarks

    static let benchmarkList = QuickHelpItem(title: "Benchmarks",
                                             detail: "The benchmarks loaded, with their members and the date of their latest constituents. Select one for its weights on the right.",
                                             symbol: "chart.pie")
    static let constituents = QuickHelpItem(title: "Constituents",
                                            detail: "The benchmark's members on its latest date with their sector, weight and shares. Type in Filter constituents to find a ticker, name or sector.",
                                            symbol: "tablecells")

    // MARK: Services & Workflows

    static let servicesTabs = QuickHelpItem(title: "Workflows / Layer 3 Services",
                                            detail: "Workflows lists the MxJobsMGR samples built on this data; Layer 3 Services lists the shared services they call.",
                                            symbol: "flowchart")
}
