//
//  HubLinks.swift
//  MxDataHUB
//
//  MxDataHUB's side of the links on tickers and names (Shared/Links): the securities of the Securities page and of a
//  portfolio's Holdings, and where their links are kept — srm.security_link (migration V014), through the app's own
//  database connection. MxAcctMGR reads and writes the same rows through the accounts service, so a link made in one
//  app shows in the other.
//

import Foundation

extension LinkTarget {
    /// A security on the Securities page.
    static func security(_ r: SecurityRow, _ field: Field = .symbol) -> LinkTarget {
        hub(id: r.id, ticker: r.ticker, name: r.name, type: r.type, field: field)
    }

    /// A security in a portfolio's Holdings.
    static func holding(_ h: HoldingRow, _ field: Field = .symbol) -> LinkTarget {
        hub(id: h.securityID, ticker: h.ticker, name: h.name, type: h.type, field: field)
    }

    private static func hub(id: Int64, ticker: String, name: String, type: String, field: Field) -> LinkTarget {
        let kind: Kind = switch type {
        case "ETF", "ETN": .etf
        case "Mutual Fund", "Closed-End Fund": .mutualFund
        case "Collective Investment Trust": .other
        default: .stock
        }
        return LinkTarget(security: ticker.isEmpty ? "id:\(id)" : LinkTarget.key(ticker), securityID: id, symbol: ticker.isEmpty ? "—" : ticker,
                          name: name, field: field, columns: ["Ticker", "Name"], kind: kind)
    }
}

/// srm.security_link through MxDataHUB's connection.
nonisolated struct HubLinkBackend: SecurityLinkBackend {
    let service: PostgresService

    var name: String { "MxDataHUB's database connection" }

    /// A PostgreSQL array literal ({"a","b"}) for a text parameter cast to an array.
    private static func array<T>(_ values: [T]) -> String {
        "{" + values.map { "\"" + "\($0)".replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }.joined(separator: ",") + "}"
    }

    func links(securityIDs: [Int64], tickers: [String]) async throws -> (resolved: [String: Int64], links: [Int64: [LinkTarget.Field: SecurityLink]]) {
        var resolved: [String: Int64] = [:]
        if !tickers.isEmpty {
            for row in try await service.rows("SELECT t, srm.us_security(t)::text FROM unnest($1::text::text[]) t", [Self.array(tickers)]) {
                if let t = row[0], let id = row[1].flatMap({ Int64($0) }) { resolved[t] = id }
            }
        }
        let ids = Array(Set(securityIDs).union(resolved.values))
        var links: [Int64: [LinkTarget.Field: SecurityLink]] = [:]
        guard !ids.isEmpty else { return (resolved, links) }
        let rows = try await service.rows("""
            SELECT security_id::text, field, address, display_text, hover_rtf, link_title
              FROM srm.security_link WHERE security_id = ANY($1::text::bigint[])
            """, [Self.array(ids)])
        for row in rows {
            guard let id = row[0].flatMap({ Int64($0) }), let field = row[1].flatMap(LinkTarget.Field.init(column:)), let address = row[2] else { continue }
            links[id, default: [:]][field] = SecurityLink(address: address, text: row[3], tip: row[4].map { Data($0.utf8) }, title: row[5])
        }
        return (resolved, links)
    }

    func save(_ link: SecurityLink, securityID: Int64, field: LinkTarget.Field) async throws {
        _ = try await service.rows("""
            INSERT INTO srm.security_link (security_id, field, address, display_text, hover_text, hover_rtf, link_title, updated_at, updated_by)
            VALUES ($1::text::bigint, $2, $3, $4, $5, $6, $7, now(), 'MxDataHUB')
            ON CONFLICT (security_id, field) DO UPDATE SET address = excluded.address, display_text = excluded.display_text,
                hover_text = excluded.hover_text, hover_rtf = excluded.hover_rtf, link_title = excluded.link_title,
                updated_at = now(), updated_by = excluded.updated_by
            RETURNING security_id::text
            """, [String(securityID), field.column, link.address, link.text, link.tipPlain,
                  link.tip.flatMap { String(data: $0, encoding: .utf8) }, link.title])
    }

    func delete(securityID: Int64, field: LinkTarget.Field) async throws {
        _ = try await service.rows("DELETE FROM srm.security_link WHERE security_id = $1::text::bigint AND field = $2 RETURNING field",
                                   [String(securityID), field.column])
    }
}
