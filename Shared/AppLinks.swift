//
//  AppLinks.swift
//  Shared by MxDataHUB, MxJobsMGR and MxAcctMGR (MxAppsIOS/Shared)
//
//  How the apps hand work to each other:
//
//    MxDataHUB  — the data: securities, benchmarks, portfolios, and refreshing each category of market data.
//    MxJobsMGR  — the processes: repeatable, scheduled, approved workflows over that data.
//    MxAcctMGR  — the personal accounts: My Portfolio, kept in the security master with its tax lots; and Secure
//                 Accounts, which keeps the API keys MxJobsMGR's subscriptions send.
//
//    mxjobsmgr://sample/<sample id>?portfolio=CODE&benchmark=CODE   new jobspace from a sample, for a portfolio
//    (mxjobswms:// — the app's scheme before it was renamed from MxJobsWMS — still opens it.)
//    mxdatahub://portfolio/<CODE>    mxdatahub://benchmark/<CODE>    mxdatahub://data-refresh    mxdatahub://services
//    mxacctmgr://my-portfolio/<CODE>   My Portfolio, opened from the security-master account CODE (no code: as it is)
//    mxacctmgr://secure-accounts/<id>   Banking ▸ Secure Accounts, with that account's Edit Service Details open
//    mxacctmgr://secure-accounts/new?name=…&api=…&url=…   New Secure Account, filled in (MxJobsMGR's API Subscriptions)
//    (mxportmgr:// — the app's scheme before it was renamed from MxPortMGR — still opens it.)
//

import AppKit

nonisolated enum AppLink: Equatable, Sendable {
    /// MxJobsMGR: a new jobspace from a sample, optionally for a portfolio and benchmark.
    case sample(id: String, portfolio: String?, benchmark: String?)
    /// MxDataHUB screens.
    case portfolio(String)
    case benchmark(String)
    case dataRefresh
    case services
    /// MxAcctMGR: My Portfolio, optionally the security-master account with this code.
    case myPortfolio(String?)
    /// MxAcctMGR: Secure Accounts, optionally with this account open.
    case secureAccount(Int?)
    /// MxAcctMGR: New Secure Account, filled in with a product name, service API and service URL.
    case newSecureAccount(name: String, api: String?, url: String?)

    static let jobsScheme = "mxjobsmgr"
    static let hubScheme = "mxdatahub"
    static let jobsBundleID = "com.k3jdr.MxJobsMGR"
    static let hubBundleID = "com.k3jdr.MxDataHUB"
    static let acctScheme = "mxacctmgr"
    static let acctBundleID = "com.k3jdr.MxAcctMGR"
    /// MxAcctMGR's scheme while it was MxPortMGR, for links saved before the rename.
    static let legacyAcctScheme = "mxportmgr"
    /// MxJobsMGR's scheme while it was MxJobsWMS, for links saved before the rename.
    static let legacyJobsScheme = "mxjobswms"

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
            c.scheme = Self.acctScheme; c.host = "my-portfolio"
            if let code, !code.isEmpty { c.path = "/" + code }
        case let .secureAccount(id):
            c.scheme = Self.acctScheme; c.host = "secure-accounts"
            if let id { c.path = "/\(id)" }
        case let .newSecureAccount(name, api, url):
            c.scheme = Self.acctScheme; c.host = "secure-accounts"; c.path = "/new"
            c.queryItems = [URLQueryItem(name: "name", value: name)]
                + [("api", api), ("url", url)].compactMap { k, v in v.flatMap { $0.isEmpty ? nil : URLQueryItem(name: k, value: $0) } }
        }
        return c.url!
    }

    init?(url: URL) {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = c.host else { return nil }
        let value = c.path.split(separator: "/").first.map(String.init) ?? ""
        let query = { (name: String) in c.queryItems?.first { $0.name == name }?.value }
        switch (c.scheme, host) {
        case (Self.jobsScheme, "sample") where !value.isEmpty, (Self.legacyJobsScheme, "sample") where !value.isEmpty:
            self = .sample(id: value, portfolio: query("portfolio"), benchmark: query("benchmark"))
        case (Self.hubScheme, "portfolio") where !value.isEmpty: self = .portfolio(value)
        case (Self.hubScheme, "benchmark") where !value.isEmpty: self = .benchmark(value)
        case (Self.hubScheme, "data-refresh"): self = .dataRefresh
        case (Self.hubScheme, "services"): self = .services
        case (Self.acctScheme, "my-portfolio"), (Self.legacyAcctScheme, "my-portfolio"): self = .myPortfolio(value.isEmpty ? nil : value)
        case (Self.acctScheme, "secure-accounts") where value == "new":
            self = .newSecureAccount(name: query("name") ?? "", api: query("api"), url: query("url"))
        case (Self.acctScheme, "secure-accounts"): self = .secureAccount(Int(value))
        default: return nil
        }
    }

    /// The app this link opens.
    var appName: String {
        switch self {
        case .sample: "MxJobsMGR"
        case .myPortfolio, .secureAccount, .newSecureAccount: "MxAcctMGR"
        default: "MxDataHUB"
        }
    }

    /// Opens the link in the other app; returns false when that app is not installed.
    @MainActor @discardableResult
    func open() -> Bool {
        let bundleID = appName == "MxJobsMGR" ? Self.jobsBundleID : appName == "MxAcctMGR" ? Self.acctBundleID : Self.hubBundleID
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
                || NSWorkspace.shared.urlForApplication(toOpen: url) != nil else { return false }
        return NSWorkspace.shared.open(url)
    }
}
