//
//  SecurityLinkTargets.swift
//  MxAcctMGR
//
//  MxAcctMGR's side of the links on tickers and names (Shared/Links): which security a row of Earnings by Day or My
//  Holdings is, and where its link is kept — in the security master through the accounts service (Services/accounts,
//  /links), so it shows in MxDataHUB too. A company in Earnings by Day is looked up by its ticker; a holding, or a
//  security in Add Securities, by its security-master id.
//

import Foundation

extension LinkTarget {
    /// A company in Earnings by Day.
    static func earnings(_ e: EarningsEntry, _ field: Field = .symbol) -> LinkTarget {
        LinkTarget(security: e.key, symbol: e.symbol, name: e.name, field: field, columns: ["Symbol", "Company"], kind: .stock)
    }

    /// A security in Add Securities: the same link as on the Securities page and in MxDataHUB (by its id).
    static func srm(_ s: SRMSecurity, _ field: Field = .symbol) -> LinkTarget {
        let kind: Kind = switch s.securityType {
        case "ETF", "ETN": .etf
        case "Mutual Fund", "Closed-End Fund": .mutualFund
        case "Collective Investment Trust": .other
        default: .stock
        }
        return LinkTarget(security: LinkTarget.key(s.ticker), securityID: Int64(s.securityId), symbol: s.ticker, name: s.name,
                          field: field, columns: ["Ticker", "Name"], kind: kind)
    }

    /// A holding in My Holdings (none for cash).
    static func holding(_ h: Holding, _ field: Field = .symbol) -> LinkTarget? {
        guard h.ticker != "CASH" else { return nil }
        let s = h.security
        let symbol = s?.displayTicker ?? h.ticker
        let name = s?.name ?? "Unknown — not in the security master"
        guard let s, let id = s.srmID, id > 0 else {
            return LinkTarget(security: "mx:" + h.ticker, symbol: symbol, name: name, field: field, columns: ["Ticker", "Name"], kind: nil)
        }
        let kind: Kind = switch s.securityType {
        case "ETF", "ETN": .etf
        case "Mutual Fund", "Closed-End Fund": .mutualFund
        case "Collective Investment Trust": .other
        default: .stock
        }
        return LinkTarget(security: LinkTarget.key(symbol), securityID: Int64(id), symbol: symbol, name: name, field: field,
                          columns: ["Ticker", "Name"], kind: kind)
    }
}

/// The links in the security master, through the accounts service (127.0.0.1:8774): POST /links/query,
/// PUT and DELETE /links/<securityId>/<ticker|name>.
nonisolated struct AccountsLinkBackend: SecurityLinkBackend {
    var name: String { AccountsClient.service }

    private func call(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> [String: Any] {
        var r = URLRequest(url: URL(string: AccountsClient.base + path)!, timeoutInterval: 30)
        r.httpMethod = method
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: r)
        } catch {
            throw ServiceClient.Failure.notRunning(AccountsClient.service)
        }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if let error = json["error"] as? String { throw ServiceClient.Failure.rejected("Links in the security master: \(error)") }
        return json
    }

    func links(securityIDs: [Int64], tickers: [String]) async throws -> (resolved: [String: Int64], links: [Int64: [LinkTarget.Field: SecurityLink]]) {
        let json = try await call("POST", "/links/query", ["securityIds": securityIDs, "tickers": tickers])
        var resolved: [String: Int64] = [:]
        for (ticker, id) in json["resolved"] as? [String: Any] ?? [:] { if let id = (id as? NSNumber)?.int64Value { resolved[ticker] = id } }
        var links: [Int64: [LinkTarget.Field: SecurityLink]] = [:]
        for row in json["links"] as? [[String: Any]] ?? [] {
            guard let id = (row["securityId"] as? NSNumber)?.int64Value, let field = (row["field"] as? String).flatMap(LinkTarget.Field.init(column:)),
                  let address = row["address"] as? String else { continue }
            links[id, default: [:]][field] = SecurityLink(address: address, text: row["text"] as? String,
                                                          tip: (row["hoverRtf"] as? String).map { Data($0.utf8) }, title: row["title"] as? String)
        }
        return (resolved, links)
    }

    func save(_ link: SecurityLink, securityID: Int64, field: LinkTarget.Field) async throws {
        var body: [String: Any] = ["address": link.address, "by": "MxAcctMGR"]
        if let text = link.text { body["text"] = text }
        if let tip = link.tip, let rtf = String(data: tip, encoding: .utf8) { body["hoverRtf"] = rtf }
        if let plain = link.tipPlain { body["hoverText"] = plain }
        if let title = link.title { body["title"] = title }
        _ = try await call("PUT", "/links/\(securityID)/\(field.column)", body)
    }

    func delete(securityID: Int64, field: LinkTarget.Field) async throws {
        _ = try await call("DELETE", "/links/\(securityID)/\(field.column)")
    }
}
