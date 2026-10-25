//
//  SRMStore.swift
//  MxDataHUB
//
//  Security reference master (schema srm, see SRM/README.md): the database connection, row
//  types and the queries behind every screen. Every write is a single statement (autocommit).
//

import Foundation
import SwiftUI

enum SRMSection: String, CaseIterable, Identifiable {
    case connection = "DB Connection"
    case securities = "Securities"
    case portfolios = "Portfolios"
    case benchmarks = "Benchmarks"
    case refresh = "Data Refresh"
    case loads = "Load History"
    case services = "Services & Workflows"
    var id: String { rawValue }

    /// Screens that work through the Layer 3 services, without the app's own database connection.
    var needsConnection: Bool { !(self == .connection || self == .refresh || self == .services) }

    var systemImage: String {
        switch self {
        case .connection: "cylinder.split.1x2"
        case .securities: "magnifyingglass"
        case .portfolios: "briefcase"
        case .benchmarks: "chart.pie"
        case .refresh: "arrow.triangle.2.circlepath"
        case .loads: "tray.and.arrow.down"
        case .services: "flowchart"
        }
    }
}

enum ConnectionStatus: Equatable {
    case disconnected
    case connecting
    case connected(serverVersion: String)
    case failed(String)
}

// MARK: Rows

struct SecurityRow: Identifiable, Hashable {
    var id: Int64
    var ticker: String
    var name: String
    var type: String
    var isin: String
    var cusip: String
    var figi: String
    var sector: String
    var mic: String
    var isActive: Bool
}

struct IdentifierRow: Identifiable, Hashable {
    var id: String { "\(type)|\(value)|\(mic)|\(from)" }
    var type: String
    var value: String
    var mic: String
    var from: String
    var to: String
    var source: String
    var lastSeen: String
    var isCurrent: Bool
}

struct ListingRow: Identifiable, Hashable {
    var id: String { "\(mic)|\(ticker)|\(from)" }
    var mic: String
    var exchange: String
    var ticker: String
    var isPrimary: Bool
    var from: String
    var to: String
}

struct NameValue: Identifiable, Hashable {
    var id: String { name + "|" + value }
    var name: String
    var value: String
}

struct ActionRow: Identifiable, Hashable {
    var id: String { "\(type)|\(exDate)|\(source)" }
    var type: String
    var exDate: String
    var detail: String
    var source: String
}

struct PricePoint: Identifiable, Hashable {
    var id: Date { date }
    var date: Date
    var close: Double
}

struct SecurityDetail {
    var security: SecurityRow
    var facts: [NameValue]
    var identifiers: [IdentifierRow]
    var listings: [ListingRow]
    var classifications: [NameValue]
    var memberships: [NameValue]
    var actions: [ActionRow]
    var prices: [PricePoint]
}

struct PortfolioRow: Identifiable, Hashable {
    var id: Int
    var code: String
    var name: String
    var currency: String
    var benchmarkID: Int?
    var benchmarkCode: String
    var description: String
    var snapshots: Int
    var lastSnapshot: String
    /// Personal account fields (V011): empty for model portfolios.
    var accountType = ""
    var approach = ""
    var managedBy = ""
    var cash = 0.0
    var isPersonal: Bool { !accountType.isEmpty }
}

/// An open tax lot of a personal account (srm.v_portfolio_tax_lot).
struct TaxLotRow: Identifiable, Hashable {
    var id: Int64
    var ticker: String
    var name: String
    var acquired: String
    var quantity: Double
    var costBasis: Double
    var price: Double?
    var marketValue: Double?
    var gain: Double?
    var longTerm: Bool
}

struct HoldingRow: Identifiable, Hashable {
    var id: Int64 { securityID }
    var securityID: Int64
    var ticker: String
    var name: String
    var input: String
    var inputType: String
    var quantity: Double?
    var targetWeight: Double?
    var price: Double?
    var priceDate: String
    var marketValue: Double?
    var weight: Double?
    /// srm.security_type (for the Link dialog's pages about the security).
    var type: String = ""
}

struct ValidationIssue: Identifiable, Hashable {
    var id = UUID()
    var severity: String
    var message: String
}

struct ActiveWeightRow: Identifiable, Hashable {
    var id: Int64
    var ticker: String
    var name: String
    var portfolio: Double
    var benchmark: Double
    var active: Double
}

struct ResolveMatch: Identifiable, Hashable {
    var id: Int64
    var matchedType: String
    var matchedValue: String
    var name: String
    var ticker: String
    var isin: String
    var type: String
}

struct BenchmarkRow: Identifiable, Hashable {
    var id: Int
    var code: String
    var name: String
    var provider: String
    var method: String
    var isProxy: Bool
    var source: String
    var proxyNote: String
    var asOf: String
    var members: Int
    var weightSum: Double
    var snapshots: Int
    var lastLevel: String
    var parent: String
    var isCustom: Bool { provider == "MxDataHUB" }
}

struct ConstituentRow: Identifiable, Hashable {
    var id: Int64
    var ticker: String
    var name: String
    var sector: String
    var weight: Double
    var shares: Double?
}

struct SectorWeight: Identifiable, Hashable {
    var id: String { sector }
    var sector: String
    var weight: Double
    var count: Int
}

struct LoadRow: Identifiable, Hashable {
    var id: Int64
    var source: String
    var loader: String
    var started: String
    var duration: String
    var status: String
    var read: Int
    var inserted: Int
    var updated: Int
    var rejected: Int
    var apiCalls: Int
    var message: String
}

struct CoverageRow: Identifiable, Hashable {
    var id: String { type }
    var type: String
    var name: String
    var securities: Int
    var total: Int
    var percent: Double
    var sources: String
}

/// Weight history of a benchmark or portfolio (srm.v_snapshot_coverage).
struct SnapshotCoverageRow: Identifiable, Hashable {
    var id: String { kind + ":" + code }
    var kind: String
    var code: String
    var snapshots: Int
    var first: String
    var last: String
    var months: Int
    var drifted: Int
    var maxGapDays: Int?
}

struct SourceRow: Identifiable, Hashable {
    var id: String { code }
    var code: String
    var name: String
    var url: String
    var note: String
    var lastLoad: String
}

// MARK: Store

@MainActor
@Observable
final class SRMStore {
    var section: SRMSection = .connection
    /// nil until checked; false when the database has no srm schema.
    var available: Bool?
    var errorMessage: String?
    var busy = false

    // Back and Forward through the places visited, as in a browser (Navigation.swift).
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    /// Bumped whenever the Back / Forward lists change (their menus redraw).
    private(set) var historyVersion = 0
    @ObservationIgnored var backStack: [Visit] = [] { didSet { historyChanged() } }
    @ObservationIgnored var forwardStack: [Visit] = [] { didSet { historyChanged() } }
    /// The place the history is at (set before Back or Forward shows it, so it isn't recorded again).
    @ObservationIgnored var historyCurrent: Visit?
    /// When the place last changed.
    @ObservationIgnored var historyStamp = Date.distantPast

    private func historyChanged() {
        canGoBack = !backStack.isEmpty
        canGoForward = !forwardStack.isEmpty
        historyVersion += 1
    }

    // Securities
    var query = ""
    var typeFilter = "All"
    var benchmarkFilter = ""
    var activeOnly = true
    var securityTypes: [String] = []
    var results: [SecurityRow] = []
    /// Excel-style sorting and column filters of the results, keyed by column title (securityColumns); run on the server.
    var securityOptions = GridQueryOptions()
    /// Securities before the page shown; a page is `securityPageSize` rows.
    var securityOffset = 0
    /// Securities matching the search and filters, on all pages.
    var securityTotal = 0
    var selectedSecurityID: Int64?
    var detail: SecurityDetail?

    // Portfolios
    var portfolios: [PortfolioRow] = []
    var selectedPortfolioID: Int?
    var snapshotDates: [String] = []
    var snapshotDate: String?
    var holdings: [HoldingRow] = []
    var selectedHoldingIDs = Set<Int64>()

    /// What Edit ▸ Link… (⌘K) links: the security selected on the Securities page, or the (first) holding selected.
    var linkSelection: LinkTarget? {
        switch section {
        case .securities: results.first { $0.id == selectedSecurityID }.map { LinkTarget.security($0) }
        case .portfolios: holdings.first { selectedHoldingIDs.contains($0.id) }.map { LinkTarget.holding($0) }
        default: nil
        }
    }
    var issues: [ValidationIssue] = []
    var activeWeights: [ActiveWeightRow] = []

    // Benchmarks
    var benchmarks: [BenchmarkRow] = []
    var selectedBenchmarkID: Int?
    var constituents: [ConstituentRow] = []
    var sectorWeights: [SectorWeight] = []
    var levels: [PricePoint] = []
    var sectors: [String] = []

    // Loads
    var loads: [LoadRow] = []
    var coverage: [CoverageRow] = []
    var sources: [SourceRow] = []
    var snapshotCoverage: [SnapshotCoverageRow] = []

    // Connection
    /// The DB Connection screen's fields (saved in the app's defaults; the password in the Keychain).
    var settings = ConnectionSettings.load()
    var password = ""
    var status: ConnectionStatus = .disconnected
    /// Settings of the live connection (the screen's fields may be edited afterwards).
    private(set) var connectedSettings: ConnectionSettings?
    /// Databases on the connected server, for the Database drop-down.
    var databases: [String] = []

    private var service: PostgresService?

    var isConnected: Bool {
        if case .connected = status { true } else { false }
    }

    // MARK: Connection

    func loadSavedPassword() {
        if password.isEmpty, settings.savePasswordInKeychain,
           let saved = Keychain.password(for: settings.keychainAccount) {
            password = saved
        }
    }

    /// Connects with the DB Connection fields, then checks for the srm schema and loads the lists.
    func connect() async {
        await connect(to: settings)
    }

    private func connect(to target: ConnectionSettings) async {
        await disconnect()
        status = .connecting
        do {
            let service = try await PostgresService.connect(target, password: password)
            self.service = service
            status = .connected(serverVersion: try await service.serverVersion())
            connectedSettings = target
            target.save()
            if target.savePasswordInKeychain, !password.isEmpty {
                Keychain.setPassword(password, for: target.keychainAccount)
            }
            let list = (try? await service.databases()) ?? []
            databases = list.contains(target.database) ? list : (list + [target.database]).sorted()
            let exists = try await scalar("SELECT (to_regclass('srm.security') IS NOT NULL)::text")
            available = exists == "true"
            // Links on tickers and names: srm.security_link (V014), shared with MxAcctMGR.
            SecurityLinks.shared.use(available == true ? HubLinkBackend(service: service) : nil)
            if available == true {
                securityTypes = try await column("SELECT security_type FROM srm.security_type ORDER BY 1")
                results = []
                detail = nil
                await refreshBenchmarks()
                await refreshPortfolios()
            }
        } catch {
            status = .failed(DatabaseError.from(error).message)
        }
    }

    func disconnect() async {
        if let service { await service.close() }
        service = nil
        SecurityLinks.shared.use(nil)
        status = .disconnected
        connectedSettings = nil
        available = nil
    }

    /// Reconnects to another database on the same server with the same user and password.
    /// On failure the previous database is reconnected and the error shown.
    func switchDatabase(to name: String) async {
        guard let current = connectedSettings, name != current.database else { return }
        var target = current
        target.database = name
        await connect(to: target)
        if isConnected {
            settings.database = name
        } else {
            let reason: String
            if case .failed(let message) = status { reason = message } else { reason = "unknown error" }
            await connect(to: current)
            errorMessage = "Could not connect to database \(name).\n\n\(reason)"
        }
    }

    private func rows(_ sql: String, _ binds: [String?] = []) async throws -> [[String?]] {
        guard let service else { throw DatabaseError(message: "Not connected.") }
        return try await service.rows(sql, binds)
    }

    private func scalar(_ sql: String, _ binds: [String?] = []) async throws -> String? {
        try await rows(sql, binds).first?.first ?? nil
    }

    private func column(_ sql: String, _ binds: [String?] = []) async throws -> [String] {
        try await rows(sql, binds).compactMap { $0.first ?? nil }
    }

    /// Runs `work`, showing failures in the alert.
    private func perform(_ work: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await work()
        } catch {
            errorMessage = DatabaseError.from(error).message
        }
    }

    // MARK: Securities

    static let securityPageSize = 1000

    /// The results' columns that sort and filter: column title → v_security column.
    static let securityColumns = ["Ticker": "v.ticker", "Name": "v.name", "Type": "v.security_type", "ISIN": "v.isin",
                                  "CUSIP": "v.cusip", "Composite FIGI": "v.composite_figi", "Sector": "v.sector", "MIC": "v.mic"]
    /// Their types for the filter panel: all compare as text.
    static let securityColumnTypes = securityColumns.mapValues { _ in "text" }

    private static let resolvedMatches = "WITH m AS (SELECT security_id, min(rank) AS rank FROM srm.resolve_identifier($1) GROUP BY 1)"

    /// $1–$4 of the search queries: the search box, Type, In (benchmark) and Active only.
    private var securitySearchBinds: SQLBinds {
        SQLBinds([query.trimmingCharacters(in: .whitespaces), typeFilter, benchmarkFilter, activeOnly ? "true" : "false"])
    }

    /// FROM and WHERE of the search: the search fields and the column filters, except `exceptColumn`'s
    /// (its filter panel lists the values the other filters leave).
    private func securitySource(except exceptColumn: String? = nil, binds: inout SQLBinds) -> String {
        let filters = GridSQL.conditions(securityOptions, types: Self.securityColumnTypes, except: exceptColumn,
                                         expr: { Self.securityColumns[$0] ?? "v.name" }, binds: &binds)
        return """
              FROM srm.v_security v
              LEFT JOIN m ON m.security_id = v.security_id
             WHERE ($1 = '' OR m.security_id IS NOT NULL OR v.name ILIKE '%' || $1 || '%'
                    OR v.issuer_name ILIKE '%' || $1 || '%')
               AND ($2 = 'All' OR v.security_type = $2)
               AND ($3 = '' OR v.security_id IN (
                    SELECT w.security_id FROM srm.benchmark b, srm.benchmark_weights(b.benchmark_id) w WHERE b.code = $3))
               AND (NOT $4::bool OR v.is_active)
            """ + (filters.isEmpty ? "" : "\n   AND \(filters)")
    }

    var hasPreviousSecurityPage: Bool { securityOffset > 0 }
    var hasNextSecurityPage: Bool { securityOffset + results.count < securityTotal }

    /// Runs the search from its first page.
    func search() async {
        securityOffset = 0
        await loadSecurities()
    }

    /// Previous or Next: the neighbouring page of securities.
    func showSecurityPage(next: Bool) async {
        guard next ? hasNextSecurityPage : hasPreviousSecurityPage else { return }
        securityOffset = next ? securityOffset + Self.securityPageSize : max(0, securityOffset - Self.securityPageSize)
        await loadSecurities()
    }

    /// New sorting or column filters from a column header's panel; the search runs again from its first page.
    func applySecurityOptions(_ options: GridQueryOptions) async {
        securityOptions = options
        await search()
    }

    /// One page of the results: the column sort first, then the best identifier matches, an exact ticker, the name.
    private func loadSecurities() async {
        await perform {
            var binds = securitySearchBinds
            let source = securitySource(binds: &binds)
            let order = [GridSQL.orderTerm(securityOptions, expr: { Self.securityColumns[$0] ?? "v.name" })].compactMap { $0 }
                + ["m.rank NULLS LAST", "(v.ticker = upper($1)) DESC NULLS LAST", "v.name", "v.security_id"]
            let r = try await rows("""
                \(Self.resolvedMatches)
                SELECT v.security_id::text, coalesce(v.ticker, ''), v.name, v.security_type, coalesce(v.isin, ''),
                       coalesce(v.cusip, ''), coalesce(v.composite_figi, ''), coalesce(v.sector, ''),
                       coalesce(v.mic::text, ''), v.is_active::text, count(*) OVER ()::text
                \(source)
                 ORDER BY \(order.joined(separator: ", "))
                 LIMIT \(Self.securityPageSize) OFFSET \(securityOffset)
                """, binds.values)
            securityTotal = r.first.flatMap { Int($0[10] ?? "") } ?? 0
            results = r.map(Self.securityRow)
            if let first = results.first, results.count == 1 || selectedSecurityID == nil
                || !results.contains(where: { $0.id == selectedSecurityID }) {
                selectedSecurityID = first.id
            }
        }
    }

    /// A column's distinct values with their counts, for its filter panel (the other columns' filters applied).
    func securityValues(column: String) async throws -> (values: [DistinctValue], truncated: Bool) {
        guard let expr = Self.securityColumns[column] else { return ([], false) }
        var binds = securitySearchBinds
        let source = securitySource(except: column, binds: &binds)
        let r = try await rows("""
            \(Self.resolvedMatches)
            SELECT \(expr)::text, count(*)::text
            \(source)
             GROUP BY 1 ORDER BY 1 NULLS FIRST LIMIT 1001
            """, binds.values)
        return (r.prefix(1000).map { DistinctValue(value: $0[0], count: Int($0[1] ?? "") ?? 0) }, r.count > 1000)
    }

    private static func securityRow(_ r: [String?]) -> SecurityRow {
        SecurityRow(id: Int64(r[0] ?? "") ?? 0, ticker: r[1] ?? "", name: r[2] ?? "", type: r[3] ?? "",
                    isin: r[4] ?? "", cusip: r[5] ?? "", figi: r[6] ?? "", sector: r[7] ?? "",
                    mic: r[8] ?? "", isActive: r[9] == "true")
    }

    func loadDetail() async {
        guard let id = selectedSecurityID else { detail = nil; return }
        let sid = [String(id)] as [String?]
        await perform {
            guard let head = try await rows("""
                SELECT v.security_id::text, coalesce(v.ticker, ''), v.name, v.security_type, coalesce(v.isin, ''),
                       coalesce(v.cusip, ''), coalesce(v.composite_figi, ''), coalesce(v.sector, ''),
                       coalesce(v.mic::text, ''), v.is_active::text
                  FROM srm.v_security v WHERE v.security_id = $1::text::bigint
                """, sid).first else { detail = nil; return }
            let security = Self.securityRow(head)
            let factRows = try await rows("""
                SELECT k, v FROM srm.security s
                LEFT JOIN srm.issuer i USING (issuer_id)
                LEFT JOIN srm.exchange e ON e.mic = s.primary_mic
                CROSS JOIN LATERAL (VALUES
                    (1, 'Issuer', i.name), (2, 'LEI', i.lei), (3, 'CIK', i.cik),
                    (4, 'Entity status', i.entity_status), (5, 'Legal form (ELF)', i.legal_form),
                    (6, 'Country', coalesce(s.country_code, i.country_code)), (7, 'Incorporation', i.incorporation),
                    (8, 'SIC', i.sic_code || ' ' || coalesce(i.sic_description, '')), (9, 'EIN', i.ein),
                    (10, 'Primary exchange', s.primary_mic || ' ' || coalesce(e.name, '')),
                    (11, 'Currency', s.currency_code), (12, 'Website', i.website),
                    (13, 'Last price', (SELECT to_char(lp.close, 'FM999,999,990.00') || ' on ' || lp.price_date
                                          FROM srm.last_price(s.security_id) lp)),
                    (14, 'Market cap', (SELECT to_char(md.market_cap, 'FM999,999,999,999,990') || ' (' || md.as_of_date || ')'
                                          FROM srm.security_market_data md WHERE md.security_id = s.security_id
                                         ORDER BY md.as_of_date DESC LIMIT 1)),
                    (15, 'Status', CASE WHEN s.is_active THEN 'Active' ELSE 'Inactive since ' || coalesce(s.inactive_date::text, '?') END),
                    (16, 'Updated', to_char(s.updated_at, 'YYYY-MM-DD HH24:MI'))) AS f(n, k, v)
                WHERE s.security_id = $1::text::bigint AND v IS NOT NULL ORDER BY n
                """, sid)
            let identifiers = try await rows("""
                SELECT si.id_type, si.id_value, coalesce(si.mic::text, ''), si.valid_from::text,
                       CASE WHEN si.valid_to = 'infinity' THEN '' ELSE si.valid_to::text END, ds.code,
                       to_char(si.last_seen, 'YYYY-MM-DD'),
                       (current_date >= si.valid_from AND current_date < si.valid_to)::text
                  FROM srm.security_identifier si JOIN srm.data_source ds USING (source_id)
                  JOIN srm.identifier_type it USING (id_type)
                 WHERE si.security_id = $1::text::bigint
                 ORDER BY it.sort_order, si.valid_to DESC, si.mic
                """, sid).map {
                IdentifierRow(type: $0[0] ?? "", value: $0[1] ?? "", mic: $0[2] ?? "", from: $0[3] ?? "",
                              to: $0[4] ?? "", source: $0[5] ?? "", lastSeen: $0[6] ?? "", isCurrent: $0[7] == "true")
            }
            let listings = try await rows("""
                SELECT l.mic::text, coalesce(e.name, ''), l.ticker, l.is_primary::text, l.valid_from::text,
                       CASE WHEN l.valid_to = 'infinity' THEN '' ELSE l.valid_to::text END
                  FROM srm.listing l LEFT JOIN srm.exchange e USING (mic)
                 WHERE l.security_id = $1::text::bigint ORDER BY l.valid_to DESC, l.is_primary DESC
                """, sid).map {
                ListingRow(mic: $0[0] ?? "", exchange: $0[1] ?? "", ticker: $0[2] ?? "", isPrimary: $0[3] == "true",
                           from: $0[4] ?? "", to: $0[5] ?? "")
            }
            let classifications = try await rows("""
                SELECT sc.scheme_code || ' ' || n.level_name, n.name
                       || CASE WHEN sc.valid_to <> 'infinity' THEN ' (until ' || sc.valid_to || ')' ELSE '' END
                  FROM srm.security_classification sc JOIN srm.classification_node n USING (node_id)
                 WHERE sc.security_id = $1::text::bigint ORDER BY sc.scheme_code, sc.level, sc.valid_to DESC
                """, sid).map { NameValue(name: $0[0] ?? "", value: $0[1] ?? "") }
            let memberships = try await rows("""
                SELECT b.code || ' — ' || b.name, to_char(w.weight * 100, 'FM990.0000') || '% on ' || w.as_of_date
                  FROM srm.benchmark b CROSS JOIN LATERAL srm.benchmark_weights(b.benchmark_id) w
                 WHERE w.security_id = $1::text::bigint ORDER BY w.weight DESC
                """, sid).map { NameValue(name: $0[0] ?? "", value: $0[1] ?? "") }
            let actions = try await rows("""
                SELECT ca.action_type, ca.ex_date::text,
                       CASE ca.action_type
                            WHEN 'CASH_DIVIDEND' THEN coalesce(ca.amount::text, '?') || coalesce(' ' || ca.currency_code, '')
                                 || coalesce(', paid ' || ca.pay_date, '')
                            WHEN 'SPLIT' THEN ca.ratio_new::float8 || ' for ' || ca.ratio_old::float8
                            WHEN 'SYMBOL_CHANGE' THEN ca.old_value || ' → ' || ca.new_value
                            ELSE coalesce(ca.new_value, '') END,
                       ds.code
                  FROM srm.corporate_action ca JOIN srm.data_source ds USING (source_id)
                 WHERE ca.security_id = $1::text::bigint ORDER BY ca.ex_date DESC LIMIT 40
                """, sid).map { ActionRow(type: $0[0] ?? "", exDate: $0[1] ?? "", detail: $0[2] ?? "", source: $0[3] ?? "") }
            let prices = try await rows("""
                SELECT p.price_date::text, p.close::float8::text
                  FROM srm.listing l JOIN srm.price p USING (listing_id)
                 WHERE l.security_id = $1::text::bigint AND p.price_date > current_date - 400
                 ORDER BY p.price_date
                """, sid).compactMap(Self.point)
            detail = SecurityDetail(security: security,
                                    facts: factRows.map { NameValue(name: $0[0] ?? "", value: $0[1] ?? "") },
                                    identifiers: identifiers, listings: listings, classifications: classifications,
                                    memberships: memberships, actions: actions, prices: prices)
        }
    }

    nonisolated static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static func point(_ r: [String?]) -> PricePoint? {
        guard let d = r[0].flatMap(dayFormat.date(from:)), let c = r[1].flatMap(Double.init) else { return nil }
        return PricePoint(date: d, close: c)
    }

    // MARK: Portfolios

    func refreshPortfolios() async {
        await perform {
            portfolios = try await rows("""
                SELECT p.portfolio_id::text, p.code, p.name, p.base_currency, p.benchmark_id::text, coalesce(b.code, ''),
                       coalesce(p.description, ''),
                       (SELECT count(DISTINCT as_of_date) FROM srm.portfolio_holding h WHERE h.portfolio_id = p.portfolio_id)::text,
                       coalesce((SELECT max(as_of_date)::text FROM srm.portfolio_holding h WHERE h.portfolio_id = p.portfolio_id), ''),
                       coalesce(to_jsonb(p) ->> 'account_type', ''), coalesce(to_jsonb(p) ->> 'approach', ''),
                       coalesce(to_jsonb(p) ->> 'managed_by', ''), coalesce(to_jsonb(p) ->> 'cash_balance', '0')
                  FROM srm.portfolio p LEFT JOIN srm.benchmark b USING (benchmark_id) ORDER BY p.code
                """).map {
                PortfolioRow(id: Int($0[0] ?? "") ?? 0, code: $0[1] ?? "", name: $0[2] ?? "", currency: $0[3] ?? "",
                             benchmarkID: $0[4].flatMap { Int($0) }, benchmarkCode: $0[5] ?? "",
                             description: $0[6] ?? "", snapshots: Int($0[7] ?? "") ?? 0, lastSnapshot: $0[8] ?? "",
                             accountType: $0[9] ?? "", approach: $0[10] ?? "", managedBy: $0[11] ?? "", cash: Double($0[12] ?? "") ?? 0)
            }
            if selectedPortfolioID == nil || !portfolios.contains(where: { $0.id == selectedPortfolioID }) {
                selectedPortfolioID = portfolios.first?.id
            }
        }
    }

    var selectedPortfolio: PortfolioRow? { portfolios.first { $0.id == selectedPortfolioID } }

    var taxLots: [TaxLotRow] = []

    /// The selected personal account's open tax lots (V011's srm.v_portfolio_tax_lot).
    func loadTaxLots() async {
        guard let p = selectedPortfolio, p.isPersonal else { taxLots = []; return }
        await perform {
            taxLots = try await rows("""
                SELECT lot_id::text, ticker, coalesce(name, ''), acquired_date::text, quantity::float8::text, cost_basis::float8::text,
                       price::float8::text, market_value::float8::text, unrealized_gain::float8::text, long_term::text
                  FROM srm.v_portfolio_tax_lot WHERE portfolio_id = $1::text::int ORDER BY ticker, acquired_date
                """, [String(p.id)]).map {
                TaxLotRow(id: Int64($0[0] ?? "") ?? 0, ticker: $0[1] ?? "", name: $0[2] ?? "", acquired: $0[3] ?? "",
                          quantity: Double($0[4] ?? "") ?? 0, costBasis: Double($0[5] ?? "") ?? 0,
                          price: $0[6].flatMap { Double($0) }, marketValue: $0[7].flatMap { Double($0) },
                          gain: $0[8].flatMap { Double($0) }, longTerm: $0[9] == "true")
            }
        }
    }

    /// Creates or updates a portfolio; returns its id.
    @discardableResult
    func savePortfolio(id: Int?, code: String, name: String, currency: String, benchmarkID: Int?,
                       description: String) async -> Bool {
        var ok = false
        await perform {
            let binds: [String?] = [code, name, currency, benchmarkID.map(String.init), description.isEmpty ? nil : description]
            if let id {
                _ = try await rows("""
                    UPDATE srm.portfolio SET code = $1, name = $2, base_currency = $3, benchmark_id = $4::text::int,
                           description = $5 WHERE portfolio_id = $6::text::int
                    """, binds + [String(id)])
            } else {
                let newID = try await scalar("""
                    INSERT INTO srm.portfolio (code, name, base_currency, benchmark_id, description, inception_date)
                    VALUES ($1, $2, $3, $4::text::int, $5, current_date) RETURNING portfolio_id::text
                    """, binds)
                selectedPortfolioID = newID.flatMap { Int($0) }
            }
            ok = true
        }
        if ok { await refreshPortfolios() }
        return ok
    }

    func deletePortfolio(_ id: Int) async {
        await perform {
            _ = try await rows("DELETE FROM srm.portfolio WHERE portfolio_id = $1::text::int", [String(id)])
            selectedPortfolioID = nil
        }
        await refreshPortfolios()
    }

    /// Snapshot dates of the selected portfolio; keeps `snapshotDate` when it still exists.
    func loadSnapshots() async {
        guard let id = selectedPortfolioID else { snapshotDates = []; snapshotDate = nil; holdings = []; return }
        await perform {
            snapshotDates = try await column("""
                SELECT DISTINCT as_of_date::text FROM srm.portfolio_holding WHERE portfolio_id = $1::text::int ORDER BY 1 DESC
                """, [String(id)])
            if snapshotDate == nil || !snapshotDates.contains(snapshotDate!) {
                snapshotDate = snapshotDates.first ?? Self.dayFormat.string(from: Date())
            }
        }
        await loadHoldings()
    }

    func loadHoldings() async {
        guard let id = selectedPortfolioID, let date = snapshotDate else { holdings = []; return }
        let binds: [String?] = [String(id), date]
        await perform {
            holdings = try await rows("""
                SELECT v.security_id::text, coalesce(s.ticker, ''), coalesce(s.name, ''), coalesce(h.input_identifier, ''),
                       coalesce(h.input_type, ''), v.quantity::float8::text, v.target_weight::float8::text,
                       v.price::float8::text, coalesce(v.price_date::text, ''), v.market_value::float8::text,
                       v.weight::float8::text, coalesce(s.security_type, '')
                  FROM srm.portfolio_valuation($1::text::int, $2::text::date) v
                  LEFT JOIN srm.v_security s USING (security_id)
                  LEFT JOIN srm.portfolio_holding h ON h.portfolio_id = $1::text::int AND h.as_of_date = $2::text::date
                       AND h.security_id = v.security_id
                 ORDER BY v.weight DESC NULLS LAST, s.name
                """, binds).map {
                HoldingRow(securityID: Int64($0[0] ?? "") ?? 0, ticker: $0[1] ?? "", name: $0[2] ?? "",
                           input: $0[3] ?? "", inputType: $0[4] ?? "", quantity: $0[5].flatMap(Double.init),
                           targetWeight: $0[6].flatMap(Double.init), price: $0[7].flatMap(Double.init),
                           priceDate: $0[8] ?? "", marketValue: $0[9].flatMap(Double.init),
                           weight: $0[10].flatMap(Double.init), type: $0[11] ?? "")
            }
            issues = try await rows("SELECT severity, message FROM srm.portfolio_validate($1::text::int, $2::text::date) ORDER BY 1, 2",
                                    binds).map { ValidationIssue(severity: $0[0] ?? "", message: $0[1] ?? "") }
            if let benchmark = selectedPortfolio?.benchmarkID {
                activeWeights = try await rows("""
                    SELECT a.security_id::text, coalesce(s.ticker, ''), coalesce(s.name, ''), a.portfolio_weight::float8::text,
                           a.benchmark_weight::float8::text, a.active_weight::float8::text
                      FROM srm.portfolio_active_weights($1::text::int, $3::text::int, $2::text::date) a
                      LEFT JOIN srm.v_security s USING (security_id)
                     ORDER BY abs(a.active_weight) DESC LIMIT 200
                    """, binds + [String(benchmark)]).map {
                    ActiveWeightRow(id: Int64($0[0] ?? "") ?? 0, ticker: $0[1] ?? "", name: $0[2] ?? "",
                                    portfolio: Double($0[3] ?? "") ?? 0, benchmark: Double($0[4] ?? "") ?? 0,
                                    active: Double($0[5] ?? "") ?? 0)
                }
            } else {
                activeWeights = []
            }
        }
    }

    /// Securities an identifier could mean (for the Add Holding preview).
    func resolve(_ text: String, type: String) async -> [ResolveMatch] {
        let value = text.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, service != nil else { return [] }
        do {
            return try await rows("""
                SELECT r.security_id::text, r.matched_type, r.matched_value, r.name, coalesce(v.ticker, ''),
                       coalesce(v.isin, ''), coalesce(v.security_type, '')
                  FROM srm.resolve_identifier($1, nullif($2, 'Auto')) r LEFT JOIN srm.v_security v USING (security_id)
                 ORDER BY r.rank, r.name LIMIT 20
                """, [value, type]).map {
                ResolveMatch(id: Int64($0[0] ?? "") ?? 0, matchedType: $0[1] ?? "", matchedValue: $0[2] ?? "",
                             name: $0[3] ?? "", ticker: $0[4] ?? "", isin: $0[5] ?? "", type: $0[6] ?? "")
            }
        } catch {
            return []
        }
    }

    /// Adds or replaces holdings in the selected snapshot. Each line of `entries` is
    /// (identifier, identifier type or "Auto", shares, weight in percent). Returns error lines.
    func addHoldings(_ entries: [(identifier: String, type: String, shares: Double?, weightPercent: Double?)]) async -> [String] {
        guard let id = selectedPortfolioID, let date = snapshotDate else { return ["Select a portfolio first."] }
        var failures: [String] = []
        busy = true
        for entry in entries {
            do {
                _ = try await rows("""
                    SELECT srm.add_holding($1::text::int, $2::text::date, $3, $4::text::numeric,
                                           $5::text::numeric / 100, nullif($6, 'Auto'))
                    """, [String(id), date, entry.identifier, entry.shares.map { String($0) },
                          entry.weightPercent.map { String($0) }, entry.type])
            } catch {
                failures.append("\(entry.identifier): \(DatabaseError.from(error).message.components(separatedBy: "\n").first ?? "")")
            }
        }
        busy = false
        await loadSnapshots()
        await refreshPortfolios()
        return failures
    }

    func removeHoldings(_ ids: Set<Int64>) async {
        guard let id = selectedPortfolioID, let date = snapshotDate, !ids.isEmpty else { return }
        await perform {
            _ = try await rows("""
                DELETE FROM srm.portfolio_holding WHERE portfolio_id = $1::text::int AND as_of_date = $2::text::date
                   AND security_id = ANY(string_to_array($3, ',')::bigint[])
                """, [String(id), date, ids.map(String.init).joined(separator: ",")])
        }
        selectedHoldingIDs = []
        await loadSnapshots()
    }

    /// Scales the snapshot's target weights to add up to 100%.
    func normalizeWeights() async {
        guard let id = selectedPortfolioID, let date = snapshotDate else { return }
        await perform {
            _ = try await rows("""
                UPDATE srm.portfolio_holding h SET weight = h.weight / t.total, updated_at = now()
                  FROM (SELECT sum(weight) AS total FROM srm.portfolio_holding
                         WHERE portfolio_id = $1::text::int AND as_of_date = $2::text::date) t
                 WHERE h.portfolio_id = $1::text::int AND h.as_of_date = $2::text::date AND h.weight IS NOT NULL AND t.total > 0
                """, [String(id), date])
        }
        await loadHoldings()
    }

    /// Starts a snapshot on `date`, copying the latest earlier one (or empty).
    func newSnapshot(on date: Date) async {
        guard let id = selectedPortfolioID else { return }
        let day = Self.dayFormat.string(from: date)
        await perform {
            _ = try await rows("""
                INSERT INTO srm.portfolio_holding (portfolio_id, as_of_date, security_id, quantity, weight, cost_price,
                                                   input_identifier, input_type, note)
                SELECT portfolio_id, $2::text::date, security_id, quantity, weight, cost_price, input_identifier, input_type, note
                  FROM srm.portfolio_holding
                 WHERE portfolio_id = $1::text::int
                   AND as_of_date = (SELECT max(as_of_date) FROM srm.portfolio_holding
                                      WHERE portfolio_id = $1::text::int AND as_of_date < $2::text::date)
                ON CONFLICT DO NOTHING
                """, [String(id), day])
            snapshotDate = day
        }
        await loadSnapshots()
        if !snapshotDates.contains(day) { snapshotDates.insert(day, at: 0); snapshotDate = day }
    }

    /// Fills the snapshot from a benchmark's weights (a starting point for an index-tracking portfolio).
    func copyBenchmark(_ benchmarkID: Int) async {
        guard let id = selectedPortfolioID, let date = snapshotDate else { return }
        await perform {
            _ = try await rows("""
                INSERT INTO srm.portfolio_holding (portfolio_id, as_of_date, security_id, weight, input_identifier, input_type)
                SELECT $1::text::int, $2::text::date, w.security_id, w.weight, b.code, 'BENCHMARK'
                  FROM srm.benchmark b, srm.benchmark_weights(b.benchmark_id, $2::text::date) w
                 WHERE b.benchmark_id = $3::text::int
                ON CONFLICT (portfolio_id, as_of_date, security_id) DO UPDATE SET weight = excluded.weight, updated_at = now()
                """, [String(id), date, String(benchmarkID)])
        }
        await loadSnapshots()
        await refreshPortfolios()
    }

    // MARK: Benchmarks

    func refreshBenchmarks() async {
        await perform {
            benchmarks = try await rows("""
                SELECT benchmark_id::text, code, name, coalesce(provider, ''), weighting_method, is_proxy::text,
                       coalesce(constituent_source, ''), coalesce(proxy_note, ''), coalesce(as_of_date::text, ''),
                       members::text, coalesce(weight_sum, 0)::float8::text, snapshots::text,
                       coalesce(last_level_date::text, ''), coalesce(parent_code, '')
                  FROM srm.v_benchmark_summary ORDER BY parent_code IS NOT NULL, code
                """).map {
                BenchmarkRow(id: Int($0[0] ?? "") ?? 0, code: $0[1] ?? "", name: $0[2] ?? "", provider: $0[3] ?? "",
                             method: $0[4] ?? "", isProxy: $0[5] == "true", source: $0[6] ?? "", proxyNote: $0[7] ?? "",
                             asOf: $0[8] ?? "", members: Int($0[9] ?? "") ?? 0, weightSum: Double($0[10] ?? "") ?? 0,
                             snapshots: Int($0[11] ?? "") ?? 0, lastLevel: $0[12] ?? "", parent: $0[13] ?? "")
            }
            sectors = try await column("""
                SELECT DISTINCT name FROM srm.classification_node WHERE scheme_code = 'FMP' AND level = 1 ORDER BY 1
                """)
            if selectedBenchmarkID == nil || !benchmarks.contains(where: { $0.id == selectedBenchmarkID }) {
                selectedBenchmarkID = benchmarks.first?.id
            }
        }
    }

    var selectedBenchmark: BenchmarkRow? { benchmarks.first { $0.id == selectedBenchmarkID } }

    func loadBenchmark() async {
        guard let id = selectedBenchmarkID else { constituents = []; sectorWeights = []; levels = []; return }
        let bid = [String(id)] as [String?]
        await perform {
            constituents = try await rows("""
                SELECT w.security_id::text, coalesce(v.ticker, ''), v.name,
                       coalesce(v.sector, (SELECT n.name FROM srm.security_classification sc
                                            JOIN srm.classification_node n USING (node_id)
                                           WHERE sc.security_id = w.security_id AND sc.scheme_code = 'SSGA'
                                             AND current_date < sc.valid_to LIMIT 1), ''),
                       w.weight::float8::text, w.shares::float8::text
                  FROM srm.benchmark_weights($1::text::int) w JOIN srm.v_security v USING (security_id)
                 ORDER BY w.weight DESC
                """, bid).map {
                ConstituentRow(id: Int64($0[0] ?? "") ?? 0, ticker: $0[1] ?? "", name: $0[2] ?? "", sector: $0[3] ?? "",
                               weight: Double($0[4] ?? "") ?? 0, shares: $0[5].flatMap(Double.init))
            }
            var bySector: [String: (Double, Int)] = [:]
            for c in constituents {
                let key = c.sector.isEmpty ? "Unclassified" : c.sector
                bySector[key, default: (0, 0)].0 += c.weight
                bySector[key, default: (0, 0)].1 += 1
            }
            sectorWeights = bySector.map { SectorWeight(sector: $0.key, weight: $0.value.0, count: $0.value.1) }
                .sorted { $0.weight > $1.weight }
            levels = try await rows("""
                SELECT level_date::text, close::float8::text FROM srm.benchmark_level
                 WHERE benchmark_id = $1::text::int AND level_date > current_date - 800 ORDER BY level_date
                """, bid).compactMap(Self.point)
        }
    }

    /// Builds a custom benchmark with srm.build_benchmark; returns whether it worked.
    func buildBenchmark(code: String, name: String, parent: String, method: String, sector: String?) async -> Bool {
        var ok = false
        await perform {
            let count = try await scalar("SELECT srm.build_benchmark($1, $2, $3, $4, $5)::text",
                                         [code, name, parent, method, sector])
            infoMessage = "\(code.uppercased()): \(count ?? "0") constituents"
            ok = true
        }
        if ok {
            await refreshBenchmarks()
            selectedBenchmarkID = benchmarks.first { $0.code == code.uppercased() }?.id
        }
        return ok
    }

    var infoMessage: String?

    func deleteBenchmark(_ id: Int) async {
        await perform {
            _ = try await rows("DELETE FROM srm.benchmark WHERE benchmark_id = $1::text::int AND provider = 'MxDataHUB'", [String(id)])
            selectedBenchmarkID = nil
        }
        await refreshBenchmarks()
    }

    // MARK: Loads

    func loadAudit() async {
        await perform {
            loads = try await rows("""
                SELECT load_id::text, source, loader, to_char(started_at, 'YYYY-MM-DD HH24:MI:SS'),
                       coalesce(to_char(duration, 'HH24:MI:SS'), 'running'), status, rows_read::text, rows_inserted::text,
                       rows_updated::text, rows_rejected::text, api_calls::text, coalesce(message, '')
                  FROM srm.v_load_history ORDER BY load_id DESC LIMIT 300
                """).map {
                LoadRow(id: Int64($0[0] ?? "") ?? 0, source: $0[1] ?? "", loader: $0[2] ?? "", started: $0[3] ?? "",
                        duration: $0[4] ?? "", status: $0[5] ?? "", read: Int($0[6] ?? "") ?? 0,
                        inserted: Int($0[7] ?? "") ?? 0, updated: Int($0[8] ?? "") ?? 0, rejected: Int($0[9] ?? "") ?? 0,
                        apiCalls: Int($0[10] ?? "") ?? 0, message: $0[11] ?? "")
            }
            coverage = try await rows("""
                SELECT id_type, name, securities::text, total_securities::text, coalesce(pct, 0)::text, coalesce(sources, '')
                  FROM srm.v_identifier_coverage ORDER BY sort_order
                """).map {
                CoverageRow(type: $0[0] ?? "", name: $0[1] ?? "", securities: Int($0[2] ?? "") ?? 0,
                            total: Int($0[3] ?? "") ?? 0, percent: Double($0[4] ?? "") ?? 0, sources: $0[5] ?? "")
            }
            sources = try await rows("""
                SELECT ds.code, ds.name, coalesce(ds.url, ''), concat_ws(' ', ds.licence_note, ds.plan_note),
                       coalesce((SELECT to_char(max(started_at), 'YYYY-MM-DD HH24:MI') FROM srm.load_run r
                                  WHERE r.source_id = ds.source_id), '')
                  FROM srm.data_source ds ORDER BY ds.code
                """).map {
                SourceRow(code: $0[0] ?? "", name: $0[1] ?? "", url: $0[2] ?? "", note: $0[3] ?? "", lastLoad: $0[4] ?? "")
            }
            // srm.v_snapshot_coverage arrived with migration V010.
            if try await scalar("SELECT (to_regclass('srm.v_snapshot_coverage') IS NOT NULL)::text") == "true" {
                snapshotCoverage = try await rows("""
                    SELECT kind, code, snapshots::text, coalesce(first_date::text, ''), coalesce(last_date::text, ''),
                           months::text, drifted_snapshots::text, max_gap_days::text
                      FROM srm.v_snapshot_coverage ORDER BY kind, code
                    """).map {
                    SnapshotCoverageRow(kind: $0[0] ?? "", code: $0[1] ?? "", snapshots: Int($0[2] ?? "") ?? 0,
                                        first: $0[3] ?? "", last: $0[4] ?? "", months: Int($0[5] ?? "") ?? 0,
                                        drifted: Int($0[6] ?? "") ?? 0, maxGapDays: $0[7].flatMap { Int($0) })
                }
            } else {
                snapshotCoverage = []
            }
        }
    }
}
