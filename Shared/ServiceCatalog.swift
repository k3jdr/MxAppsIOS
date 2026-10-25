//
//  ServiceCatalog.swift
//  Shared by MxDataHUB, MxJobsMGR and MxAcctMGR (MxAppsIOS/Shared)
//
//  The Layer 3 services both apps rely on (MxAppsIOS/Services): what each is for, why it is written in its
//  language, which use cases and samples it serves, and whether it is running now. The built-in entries mirror
//  each service's GET /describe, so the apps can explain a service and how to start it while it is stopped.
//

import Foundation

nonisolated struct ServiceEndpoint: Codable, Hashable, Sendable {
    var method: String
    var path: String
    var summary: String
    var contract: String?
}

nonisolated enum ServiceUseCase: String, Codable, CaseIterable, Identifiable, Sendable {
    case dataRefresh = "data-refresh", dataQuality = "data-quality"
    case active, passive, attribution, risk, absolute
    case templates, testing
    var id: String { rawValue }

    var title: String {
        switch self {
        case .dataRefresh: "Data refresh"
        case .dataQuality: "Data quality"
        case .active: "Active management"
        case .passive: "Passive / index"
        case .attribution: "Attribution"
        case .risk: "Risk"
        case .absolute: "Absolute optimization"
        case .templates: "Templates"
        case .testing: "Testing"
        }
    }

    /// When a portfolio team reaches for this use case.
    var whenToUse: String {
        switch self {
        case .dataRefresh: "Bring a category of market data up to date — reference data, universe, constituents, identifiers, prices, corporate actions."
        case .dataQuality: "Check freshness and completeness before data feeds optimization or reporting."
        case .active: "Beat a benchmark: turn alpha forecasts into overweights and underweights within a tracking-error budget and sector bands."
        case .passive: "Match a benchmark: hold it in full or sample it with fewer names at the smallest tracking error, and rebalance when it drifts."
        case .attribution: "Explain past performance against the benchmark: allocation, selection and interaction by sector, linked over months."
        case .risk: "Measure risk now: volatility, VaR and expected shortfall, tracking error and beta, and which positions and sectors drive active risk."
        case .absolute: "Allocate without a benchmark: max-Sharpe or mean-variance over a small set of assets."
        case .templates: "Start a new Layer 3 service for your own data source."
        case .testing: "Build and test jobspaces without data subscriptions."
        }
    }
}

nonisolated struct ServiceInfo: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var language: String
    var port: Int
    var purpose: String
    var whyThisLanguage: String
    var useCases: [String]
    var endpoints: [ServiceEndpoint]
    var samples: [String]
    /// Folder under MxAppsIOS/Services.
    var folder: String = ""
    var developIn: String = ""

    var baseURL: String { "http://127.0.0.1:\(port)" }
    var projectPath: String { "\(ServiceCatalog.repository)/Services/\(folder)" }
    var cases: [ServiceUseCase] { useCases.compactMap(ServiceUseCase.init(rawValue:)) }

    enum CodingKeys: String, CodingKey {
        case id, name, language, port, purpose, whyThisLanguage, useCases, endpoints, samples
    }
}

nonisolated enum ServiceCatalog {
    static let repository = "~/MyCodeGIT/MxAppsIOS"
    static let startCommand = "python3 ~/MyCodeGIT/MxAppsIOS/Services/mxservices.py start"
    static let statusCommand = "python3 ~/MyCodeGIT/MxAppsIOS/Services/mxservices.py status"
    static let agentsCommand = "python3 ~/MyCodeGIT/MxAppsIOS/Services/mxservices.py install-agents"

    static func service(_ id: String) -> ServiceInfo? { all.first { $0.id == id } }

    /// How to choose a language for a Layer 3 service.
    static let languageGuide: [(language: String, use: String)] = [
        ("Python", "Data work: loading and cleaning sources, database queries, statistics (numpy, pandas), reports. "
            + "Quickest to write and change; slower in tight numeric loops."),
        ("Java", "Long-running business services with many rules: portfolio construction constraints, compliance, "
            + "order-management integration. Typed, unit-tested, stable for months."),
        ("C++", "Numerically heavy, latency-sensitive loops: large covariance matrices, tracking and risk recomputed "
            + "for every scenario or rebalance."),
    ]

    static let all: [ServiceInfo] = [
        ServiceInfo(
            id: "srm-loader", name: "Security master loaders", language: "Python", port: 8770,
            purpose: "Refreshes the security master (MxDataHUB/SRM) by category — reference data, the listed universe and issuers, benchmark constituents, identifiers, prices and index levels, corporate actions, market series (VIX, Treasury yields) and company fundamentals — by running srm.py's loaders one at a time, and reports data freshness and quality.",
            whyThisLanguage: "Loading is I/O: downloading files and API pages, parsing CSV / XML / JSON, upserting into PostgreSQL. Python does that with the least code, and the loaders are the same scripts you run from the command line.",
            useCases: ["data-refresh", "data-quality"],
            endpoints: [
                ServiceEndpoint(method: "GET", path: "/categories", summary: "Data categories with their loaders, freshness and last load"),
                ServiceEndpoint(method: "POST", path: "/refresh/{category}", summary: "Run every loader of a category in order"),
                ServiceEndpoint(method: "POST", path: "/load/{loader}", summary: "Run one srm.py loader (X-SRM-Dry-Run: 1 to preview)"),
                ServiceEndpoint(method: "GET", path: "/status", summary: "Coverage, benchmarks, price freshness, recent loads, quality checks"),
            ],
            samples: ["srm-daily-refresh"], folder: "srm-loader", developIn: "VS Code or PyCharm"),
        ServiceInfo(
            id: "analytics", name: "Portfolio analytics", language: "Python", port: 8772,
            purpose: "Data and statistics for portfolio work: builds optimization inputs from the security master (universe, sectors, benchmark and current weights, Ledoit-Wolf covariance, momentum alpha) and runs performance attribution (Brinson-Fachler by sector, monthly, Carino-linked).",
            whyThisLanguage: "Python with numpy is the quickest way to query the database, align price histories, estimate statistics and shape reports. The heavy optimization loops go to Java and C++.",
            useCases: ["active", "passive", "attribution", "risk"],
            endpoints: [
                ServiceEndpoint(method: "POST", path: "/inputs", summary: "Optimization inputs for a portfolio / benchmark; returns inputsUrl", contract: "mxjobs.inputs/1"),
                ServiceEndpoint(method: "POST", path: "/attribution", summary: "Sector attribution of a portfolio against its benchmark", contract: "mxjobs.attribution/1"),
                ServiceEndpoint(method: "GET", path: "/portfolios", summary: "Portfolios with their benchmark and latest snapshot"),
            ],
            samples: ["active-optimization", "passive-tracking", "attribution"], folder: "analytics", developIn: "VS Code or PyCharm"),
        ServiceInfo(
            id: "accounts", name: "Personal accounts", language: "Python", port: 8774,
            purpose: "Keeps MxAcctMGR's My Portfolio in the security master: searches securities to add, serves benchmark weights, and stores each personal account — type, approach, benchmark, cash and open tax lots — writing the day's holdings snapshot from the lots, so MxDataHUB ▸ Portfolios and the analytics service see it like any other portfolio.",
            whyThisLanguage: "Python and psycopg2 are the shortest path from an HTTP request to a PostgreSQL transaction, with srm.py's own connection settings — so MxAcctMGR, a sandboxed app, needs no database credentials.",
            useCases: ["data-quality", "active", "passive"],
            endpoints: [
                ServiceEndpoint(method: "GET", path: "/securities?q=&kind=", summary: "Search securities (ticker, name, ISIN, CUSIP) with the latest price"),
                ServiceEndpoint(method: "GET", path: "/benchmarks/{code}/weights", summary: "A benchmark's latest weights with sectors"),
                ServiceEndpoint(method: "GET", path: "/accounts/{code}", summary: "A personal account with its open tax lots, valued"),
                ServiceEndpoint(method: "PUT", path: "/accounts/{code}", summary: "Create or replace an account and its lots; rewrites today's holdings"),
                ServiceEndpoint(method: "POST", path: "/accounts/{code}/load-prices", summary: "Load prices for unpriced holdings (srm-loader: nasdaq-prices, no key needed)"),
            ],
            samples: [], folder: "accounts", developIn: "VS Code or PyCharm"),
        ServiceInfo(
            id: "portfolio-java", name: "Active portfolio construction", language: "Java", port: 8766,
            purpose: "Builds active (benchmark-relative) portfolios: maximise alpha for a tracking-error budget, long-only, with per-name, active-weight and sector-band limits, and a trade list against the current holdings. Also absolute max-Sharpe / mean-variance optimization.",
            whyThisLanguage: "Java suits rule-heavy, long-running services: constraints and business rules stay readable and unit-tested (JUnit), it runs for months without restarts, and it connects easily to order-management and compliance systems.",
            useCases: ["active", "absolute"],
            endpoints: [
                ServiceEndpoint(method: "POST", path: "/optimize/active", summary: "Active mean-variance against a benchmark (inputsUrl from analytics)", contract: "mxjobs.active-optimization/1"),
                ServiceEndpoint(method: "POST", path: "/optimize", summary: "Absolute max-Sharpe / mean-variance / min-variance", contract: "mxjobs.optimization/1"),
            ],
            samples: ["active-optimization", "market-refresh"], folder: "portfolio-java", developIn: "IntelliJ IDEA"),
        ServiceInfo(
            id: "portfolio-cpp", name: "Index tracking & risk", language: "C++", port: 8767,
            purpose: "Passive index tracking — the long-only portfolio of at most N names with the smallest ex-ante tracking error against a benchmark (full replication or sampling by largest weights or sector strata) — and portfolio risk: VaR, expected shortfall, risk contributions, and tracking error, beta and active-risk contributions against a benchmark.",
            whyThisLanguage: "C++ is for the numerically heavy loops: thousands of iterations over a 500 × 500 covariance finish in milliseconds, so tracking portfolios and risk can be recomputed for every rebalance, scenario or intraday check.",
            useCases: ["passive", "risk", "absolute"],
            endpoints: [
                ServiceEndpoint(method: "POST", path: "/optimize/tracking", summary: "Minimum tracking error with at most maxNames securities", contract: "mxjobs.tracking/1"),
                ServiceEndpoint(method: "POST", path: "/risk", summary: "VaR / ES / risk contributions; tracking error and active risk vs a benchmark", contract: "mxjobs.risk/1"),
                ServiceEndpoint(method: "POST", path: "/optimize", summary: "Absolute max-Sharpe / mean-variance / min-variance", contract: "mxjobs.optimization/1"),
            ],
            samples: ["passive-tracking", "attribution", "market-refresh"], folder: "portfolio-cpp", developIn: "CLion or VS Code"),
        ServiceInfo(
            id: "market-sample", name: "Market data sample", language: "Python", port: 8765,
            purpose: "Synthetic quotes, price history and indicators (SMA, EMA, RSI) — repeatable per symbol — for building and testing jobspaces without a data subscription. Replace history() with a real source to go live.",
            whyThisLanguage: "A standard-library Python service is the quickest way to stand up a JSON endpoint for a new data source; it is the template for wrapping your own feeds.",
            useCases: ["templates", "testing"],
            endpoints: [
                ServiceEndpoint(method: "GET", path: "/quote?symbol=", summary: "Latest quote"),
                ServiceEndpoint(method: "GET", path: "/indicators?symbol=&window=", summary: "SMA, EMA, RSI"),
            ],
            samples: ["market-refresh"], folder: "market-sample", developIn: "VS Code or PyCharm"),
    ]

    /// Whether a service answers on its port now.
    static func isRunning(_ service: ServiceInfo) async -> Bool {
        guard let url = URL(string: service.baseURL + "/health") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 1.5)
        request.httpMethod = "GET"
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// The running/stopped state of every service.
    static func probeAll() async -> [String: Bool] {
        await withTaskGroup(of: (String, Bool).self) { group in
            for service in all { group.addTask { (service.id, await isRunning(service)) } }
            var out: [String: Bool] = [:]
            for await (id, up) in group { out[id] = up }
            return out
        }
    }
}

/// The sample jobspaces of MxJobsMGR, as both apps describe them.
nonisolated struct SampleInfo: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var area: String
    var summary: String
    var services: [String]
    /// Takes a portfolio (and benchmark) from MxDataHUB.
    var takesPortfolio: Bool

    static let all: [SampleInfo] = [
        SampleInfo(id: "srm-daily-refresh", title: "SRM Daily Refresh", area: "Data",
                   summary: "Refresh every data category of the security master in dependency order, check data quality, and ask the data steward to approve the report and any backfills.",
                   services: ["srm-loader"], takesPortfolio: false),
        SampleInfo(id: "active-optimization", title: "Active Portfolio Optimization", area: "Active",
                   summary: "Momentum alpha (Python) → benchmark-relative optimization within a tracking-error budget and sector bands (Java) → risk check (C++) → decision, approval and the trade list.",
                   services: ["analytics", "portfolio-java", "portfolio-cpp"], takesPortfolio: true),
        SampleInfo(id: "passive-tracking", title: "Passive Index Tracking", area: "Passive",
                   summary: "Covariance from the security master (Python) → a sampled index portfolio with the smallest tracking error (C++) → rebalance decision against the drift budget, approval and trades.",
                   services: ["analytics", "portfolio-cpp"], takesPortfolio: true),
        SampleInfo(id: "attribution", title: "Performance & Risk Attribution", area: "Analytics",
                   summary: "Brinson-Fachler sector attribution, monthly and Carino-linked (Python), with ex-ante active risk by sector (C++) → commentary, review and publication.",
                   services: ["analytics", "portfolio-cpp"], takesPortfolio: true),
        SampleInfo(id: "market-refresh", title: "Daily Market Data Refresh", area: "Templates",
                   summary: "The original sample: public market data APIs, a Python script step, and the Java and C++ absolute optimizers.",
                   services: ["market-sample", "portfolio-java", "portfolio-cpp"], takesPortfolio: false),
    ]

    static func sample(_ id: String) -> SampleInfo? { all.first { $0.id == id } }
}
