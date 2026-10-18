//
//  AppLinks.swift
//  Shared by MxDataHUB, MxJobsWMS and MxPortMGR (MXcodeIDE/Shared)
//
//  How the apps hand work to each other:
//
//    MxDataHUB  — the data: securities, benchmarks, portfolios, and refreshing each category of market data.
//    MxJobsWMS  — the processes: repeatable, scheduled, approved workflows over that data.
//    MxPortMGR  — the personal accounts: My Portfolio, kept in the security master with its tax lots.
//
//    mxjobswms://sample/<sample id>?portfolio=CODE&benchmark=CODE   new jobspace from a sample, for a portfolio
//    mxdatahub://portfolio/<CODE>    mxdatahub://benchmark/<CODE>    mxdatahub://data-refresh    mxdatahub://services
//    mxportmgr://my-portfolio/<CODE>   My Portfolio, opened from the security-master account CODE (no code: as it is)
//

import AppKit

nonisolated enum AppLink: Equatable, Sendable {
    /// MxJobsWMS: a new jobspace from a sample, optionally for a portfolio and benchmark.
    case sample(id: String, portfolio: String?, benchmark: String?)
    /// MxDataHUB screens.
    case portfolio(String)
    case benchmark(String)
    case dataRefresh
    case services
    /// MxPortMGR: My Portfolio, optionally the security-master account with this code.
    case myPortfolio(String?)

    static let jobsScheme = "mxjobswms"
    static let hubScheme = "mxdatahub"
    static let jobsBundleID = "com.k3jdr.MxJobsWMS"
    static let hubBundleID = "com.k3jdr.MxDataHUB"
    static let portScheme = "mxportmgr"
    static let portBundleID = "com.k3jdr.MxPortMGR"

    var url: URL {
        var c = URLComponents()
        switch self {
        case let .sample(id, portfolio, benchmark):
            c.scheme = Self.jobsScheme
            c.host = "sample"
            c.path = "/" + id
            var items: [URLQueryItem] = []
            if let portfolio, !portfolio.isEmpty { items.append(URLQueryItem(name: "portfolio", value: portfolio)) }
            if let benchmark, !benchmark.isEmpty { items.append(URLQueryItem(name: "benchmark", value: benchmark)) }
            c.queryItems = items.isEmpty ? nil : items
        case let .portfolio(code):
            c.scheme = Self.hubScheme; c.host = "portfolio"; c.path = "/" + code
        case let .benchmark(code):
            c.scheme = Self.hubScheme; c.host = "benchmark"; c.path = "/" + code
        case .dataRefresh:
            c.scheme = Self.hubScheme; c.host = "data-refresh"
        case .services:
            c.scheme = Self.hubScheme; c.host = "services"
        case let .myPortfolio(code):
            c.scheme = Self.portScheme; c.host = "my-portfolio"
            if let code, !code.isEmpty { c.path = "/" + code }
        }
        return c.url!
    }

    init?(url: URL) {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = c.host else { return nil }
        let value = c.path.split(separator: "/").first.map(String.init) ?? ""
        let query = { (name: String) in c.queryItems?.first { $0.name == name }?.value }
        switch (c.scheme, host) {
        case (Self.jobsScheme, "sample") where !value.isEmpty:
            self = .sample(id: value, portfolio: query("portfolio"), benchmark: query("benchmark"))
        case (Self.hubScheme, "portfolio") where !value.isEmpty: self = .portfolio(value)
        case (Self.hubScheme, "benchmark") where !value.isEmpty: self = .benchmark(value)
        case (Self.hubScheme, "data-refresh"): self = .dataRefresh
        case (Self.hubScheme, "services"): self = .services
        case (Self.portScheme, "my-portfolio"): self = .myPortfolio(value.isEmpty ? nil : value)
        default: return nil
        }
    }

    /// The app this link opens.
    var appName: String {
        switch self {
        case .sample: "MxJobsWMS"
        case .myPortfolio: "MxPortMGR"
        default: "MxDataHUB"
        }
    }

    /// Opens the link in the other app; returns false when that app is not installed.
    @MainActor @discardableResult
    func open() -> Bool {
        let bundleID = appName == "MxJobsWMS" ? Self.jobsBundleID : appName == "MxPortMGR" ? Self.portBundleID : Self.hubBundleID
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
                || NSWorkspace.shared.urlForApplication(toOpen: url) != nil else { return false }
        return NSWorkspace.shared.open(url)
    }
}
