//
//  MarketSeries.swift
//  MxAcctMGR
//
//  The market series MxDataHUB keeps in the security master (srm.market_series, V015: the VIX family from Cboe,
//  Treasury yields and NBER recessions from FRED — srm.py load cboe-vix / fred-yields, scheduled in MxJobsMGR's SRM
//  Daily Refresh), through the accounts service's GET /market/series. It answers in the sources' own CSV layouts, so
//  the VIX and Yield Curve screens parse it as they parse Cboe's and FRED's files — and read those directly when the
//  security master can't be reached or hasn't been refreshed lately.
//

import Foundation

nonisolated enum SecurityMasterSeries {
    /// The series' values as CSV — format "csv": FRED's fredgraph.csv layout; "ohlc" (one id): Cboe's history file —
    /// or nil when the accounts service or the database can't give them.
    static func csv(_ ids: [String], format: String = "csv") async -> String? {
        var c = URLComponents(string: AccountsClient.base + "/market/series")
        c?.queryItems = [URLQueryItem(name: "ids", value: ids.joined(separator: ",")), URLQueryItem(name: "format", value: format)]
        guard let url = c?.url else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 20))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    /// Whether data whose newest value is on `last` is current enough to show instead of reading the source:
    /// within `days` calendar days (a long weekend, and the day the source takes to publish).
    static func isCurrent(_ last: Date?, days: Int) -> Bool {
        guard let last else { return false }
        return Date().timeIntervalSince(last) < Double(days) * 86_400
    }
}
