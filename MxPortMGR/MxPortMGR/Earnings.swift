//
//  Earnings.swift
//  MxPortMGR
//
//  Real earnings reports for Market Reports ▸ Earnings by Day and Earnings Calendar, from two sources merged by symbol:
//
//  * Nasdaq.com's earnings calendar (api.nasdaq.com, free, no key): every U.S.-listed company reporting on a day —
//    symbol, company, market cap, before the open or after the close, fiscal quarter, the consensus EPS forecast
//    (Zacks) with its number of estimates and last year's EPS — and, once the day has passed, the actual EPS and the
//    surprise. Past listings leave out the time of day, so each listing is kept on this Mac and a later one keeps the
//    times seen before. Per company: the last four quarters' surprises and this quarter's forecast range and revisions.
//  * FMP's earnings calendar through the accounts service (Services/accounts, which holds SRM's FMP key): revenue,
//    estimated and actual, and FMP's own EPS figures for every listing FMP covers (also OTC, foreign and preferred
//    shares), 12 months back and a few months ahead; and each company's reports back decades.
//

import Foundation
import Observation

// MARK: - Model

/// When a company reports: before the U.S. market opens, after it closes, or not said.
nonisolated enum ReportTime: String, Codable, Sendable, CaseIterable, Identifiable {
    case beforeOpen, afterClose, notGiven

    var id: String { rawValue }

    var title: String {
        switch self {
        case .beforeOpen: "Before the open"
        case .afterClose: "After the close"
        case .notGiven: "Not given"
        }
    }

    /// For narrow places (the table's Time column).
    var shortTitle: String {
        switch self {
        case .beforeOpen: "Before open"
        case .afterClose: "After close"
        case .notGiven: "Not given"
        }
    }

    var symbol: String {
        switch self {
        case .beforeOpen: "sunrise"
        case .afterClose: "moon.stars"
        case .notGiven: "clock"
        }
    }

    var order: Int {
        switch self {
        case .beforeOpen: 0
        case .afterClose: 1
        case .notGiven: 2
        }
    }

    init(nasdaq: String?) {
        switch nasdaq {
        case "time-pre-market": self = .beforeOpen
        case "time-after-hours": self = .afterClose
        default: self = .notGiven
        }
    }
}

/// One row of Nasdaq.com's earnings calendar as published (strings such as "$1.89", "($0.28)", "N/A").
nonisolated struct NasdaqEarningsRow: Codable, Hashable, Sendable {
    var symbol: String
    var name: String?
    var time: String?
    var marketCap: String?
    var fiscalQuarterEnding: String?
    var epsForecast: String?
    var noOfEsts: String?
    var lastYearRptDt: String?
    var lastYearEPS: String?
    var eps: String?
    var surprise: String?
    /// The time of day (and last year's figures) came from an earlier listing of the same day.
    var keptFromEarlier: Bool?
}

/// One report in FMP's earnings calendar or in a company's history.
nonisolated struct FMPEarningsRow: Codable, Hashable, Sendable {
    var symbol: String?
    var date: String
    var epsActual: Double?
    var epsEstimated: Double?
    var revenueActual: Double?
    var revenueEstimated: Double?
    var lastUpdated: String?
}

/// A day as kept on this Mac: each source's rows and when they were fetched.
nonisolated struct EarningsDayFile: Codable, Sendable {
    var date: String
    var nasdaq: [NasdaqEarningsRow]?
    var nasdaqFetched: Date?
    var fmp: [FMPEarningsRow]?
    var fmpFetched: Date?
}

/// A company reporting on a day: Nasdaq.com's row and FMP's, merged.
nonisolated struct EarningsEntry: Identifiable, Hashable, Sendable {
    nonisolated enum Outcome: String, Sendable {
        case beat = "Beat", missed = "Missed", inLine = "In line", noEstimate = "Reported", upcoming = "Upcoming"
    }

    var id: String { key }
    /// The symbol both sources match on (Nasdaq.com's TAP.A is FMP's TAP-A).
    var key: String
    var symbol: String
    /// Empty when only FMP lists the symbol.
    var name: String
    var time: ReportTime
    var timeFromEarlier = false
    var marketCap: Double?
    var fiscalQuarter: String?
    /// Consensus EPS: Nasdaq.com's (Zacks), or FMP's (with FMP's actual) where Nasdaq.com has no result yet.
    var epsEstimate: Double?
    var epsActual: Double?
    /// The EPS surprise as a fraction: Nasdaq.com's own, or worked out from the estimate.
    var epsSurprise: Double?
    var epsFromFMP = false
    /// Nasdaq.com's consensus, kept when FMP's pair is shown instead.
    var nasdaqEPSEstimate: Double?
    var estimates: Int?
    var lastYearDate: String?
    var lastYearEPS: Double?
    var revenueEstimate: Double?
    var revenueActual: Double?
    var fmpEPSEstimate: Double?
    var fmpEPSActual: Double?
    var onNasdaq = false
    var onFMP = false

    var reported: Bool { epsActual != nil || revenueActual != nil }

    var revenueSurprise: Double? { EarningsEntry.surprise(revenueActual, revenueEstimate) }

    var outcome: Outcome {
        guard epsActual != nil || revenueActual != nil else { return .upcoming }
        guard let s = epsSurprise else { return .noEstimate }
        return s > 0.0005 ? .beat : s < -0.0005 ? .missed : .inLine
    }

    var revenueOutcome: Outcome {
        guard revenueActual != nil else { return .upcoming }
        guard let s = revenueSurprise else { return .noEstimate }
        return s > 0.0005 ? .beat : s < -0.0005 ? .missed : .inLine
    }

    /// How large the company is, for ordering: market cap, else (for FMP-only rows) revenue.
    var size: Double { marketCap ?? (revenueEstimate ?? revenueActual ?? 0) / 1e3 }

    // Non-optional sort keys for the table (missing values sort first, or last when descending).
    var nameKey: String { name.isEmpty ? "~" + symbol : name }
    var timeKey: Int { time.order }
    var capKey: Double { marketCap ?? -1 }
    var epsEstimateKey: Double { epsEstimate ?? -1e18 }
    var epsActualKey: Double { epsActual ?? -1e18 }
    var epsSurpriseKey: Double { epsSurprise ?? -1e18 }
    var revenueEstimateKey: Double { revenueEstimate ?? -1e18 }
    var revenueActualKey: Double { revenueActual ?? -1e18 }
    var revenueSurpriseKey: Double { revenueSurprise ?? -1e18 }
    var estimatesKey: Int { estimates ?? -1 }

    static func surprise(_ actual: Double?, _ estimate: Double?) -> Double? {
        guard let a = actual, let e = estimate, abs(e) > 1e-9 else { return nil }
        return (a - e) / abs(e)
    }

    /// A listing whose results aren't in yet: the day after, Nasdaq.com fills "EPS" with last year's EPS and gives no
    /// surprise for anyone. In a finished listing most companies with a forecast have a surprise (all but those exactly
    /// in line, at most about a fifth in the listings probed).
    static func isInterim(_ nasdaq: [NasdaqEarningsRow]) -> Bool {
        let forecast = nasdaq.filter { EarningsParse.number($0.epsForecast) != nil && EarningsParse.number($0.eps) != nil }
        let noSurprise = forecast.filter { EarningsParse.number($0.surprise) == nil }.count
        return forecast.count >= 5 && Double(noSurprise) >= 0.9 * Double(forecast.count)
    }

    /// Nasdaq.com's rows, then FMP's: one entry per company, in Nasdaq.com's order (largest first), FMP-only last.
    static func merge(nasdaq: [NasdaqEarningsRow], fmp: [FMPEarningsRow]) -> [EarningsEntry] {
        var byKey: [String: EarningsEntry] = [:]
        var order: [String] = []
        let interim = isInterim(nasdaq)
        for r in nasdaq {
            let key = EarningsParse.key(r.symbol)
            guard byKey[key] == nil else { continue }
            var e = EarningsEntry(key: key, symbol: r.symbol, name: (r.name ?? "").trimmingCharacters(in: .whitespaces),
                                  time: ReportTime(nasdaq: r.time))
            e.timeFromEarlier = r.keptFromEarlier ?? false
            e.marketCap = EarningsParse.number(r.marketCap)
            e.fiscalQuarter = r.fiscalQuarterEnding.flatMap { $0.isEmpty ? nil : $0.replacingOccurrences(of: "/", with: " ") }
            e.epsEstimate = EarningsParse.number(r.epsForecast)
            e.nasdaqEPSEstimate = e.epsEstimate
            e.epsActual = interim ? nil : EarningsParse.number(r.eps)
            e.epsSurprise = e.epsActual == nil ? nil : EarningsParse.number(r.surprise).map { $0 / 100 } ?? surprise(e.epsActual, e.epsEstimate)
            e.estimates = EarningsParse.number(r.noOfEsts).map { Int($0) }
            e.lastYearDate = EarningsParse.usDate(r.lastYearRptDt)
            e.lastYearEPS = EarningsParse.number(r.lastYearEPS)
            e.onNasdaq = true
            byKey[key] = e
            order.append(key)
        }
        for r in fmp {
            guard let symbol = r.symbol, !symbol.isEmpty else { continue }
            let key = EarningsParse.key(symbol)
            var e = byKey[key] ?? EarningsEntry(key: key, symbol: symbol, name: "", time: .notGiven)
            if byKey[key] == nil { order.append(key) }
            e.onFMP = true
            e.revenueEstimate = r.revenueEstimated
            e.revenueActual = r.revenueActual
            e.fmpEPSEstimate = r.epsEstimated
            e.fmpEPSActual = r.epsActual
            // FMP's estimate and actual as a pair (EPS definitions differ between the sources) where Nasdaq.com has
            // no figures, or no result yet when FMP has one: Nasdaq.com posts results a day or so later.
            if (e.epsEstimate == nil && e.epsActual == nil && (r.epsEstimated != nil || r.epsActual != nil))
                || (e.epsActual == nil && r.epsActual != nil) {
                e.epsEstimate = r.epsEstimated
                e.epsActual = r.epsActual
                e.epsSurprise = surprise(r.epsActual, r.epsEstimated)
                e.epsFromFMP = true
            }
            byKey[key] = e
        }
        return order.map { byKey[$0]! }
    }
}

/// A day's merged list and what each source said about it.
struct EarningsDay {
    var date: String
    var entries: [EarningsEntry]
    /// nil: Nasdaq.com's listing hasn't been loaded (or couldn't be).
    var nasdaqFetched: Date?
    var nasdaqCount: Int?
    var fmpFetched: Date?
    var fmpCount: Int?

    init(_ f: EarningsDayFile) {
        date = f.date
        entries = EarningsEntry.merge(nasdaq: f.nasdaq ?? [], fmp: f.fmp ?? [])
        nasdaqFetched = f.nasdaq == nil ? nil : f.nasdaqFetched
        nasdaqCount = f.nasdaq?.count
        fmpFetched = f.fmp == nil ? nil : f.fmpFetched
        fmpCount = f.fmp?.count
    }

    /// The companies shown by default: those Nasdaq.com lists (U.S.-listed); FMP's where Nasdaq.com's listing
    /// couldn't be loaded, or for a weekday further ahead than Nasdaq.com schedules. (FMP's other rows are mostly OTC,
    /// foreign and preferred listings.)
    var listed: [EarningsEntry] {
        if let n = nasdaqCount, n > 0 { return entries.filter(\.onNasdaq) }
        if nasdaqCount == nil || (date > EarningsDates.today() && !EarningsDates.isWeekend(date)) { return entries }
        return []
    }
    /// The default list is FMP's: Nasdaq.com has none for the day.
    var listedFromFMP: Bool { (nasdaqCount ?? 0) == 0 && !listed.isEmpty }
    var fmpOnly: [EarningsEntry] { entries.filter { !$0.onNasdaq } }
}

/// One company's earnings history: FMP's reports (with revenue), Nasdaq.com's last four surprises and this quarter's forecasts.
struct CompanyEarnings {
    var history: [FMPEarningsRow] = []
    var historyNote: String?
    var surprises: [NasdaqEarningsClient.Surprise] = []
    var forecasts: [NasdaqEarningsClient.Forecast] = []
    var nasdaqNote: String?
    var loading = true
}

// MARK: - Parsing and dates

nonisolated enum EarningsParse {
    /// "$1.89" → 1.89, "($0.28)" → −0.28, "$370,328,666,000" → 3.7e11, "-9.76" → −9.76; "", "N/A" → nil.
    static func number(_ s: String?) -> Double? {
        guard var t = s?.trimmingCharacters(in: .whitespaces), !t.isEmpty, t != "N/A", t != "--" else { return nil }
        var negative = false
        if t.hasPrefix("("), t.hasSuffix(")") {
            negative = true
            t = String(t.dropFirst().dropLast())
        }
        t = t.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "%", with: "")
        guard let v = Double(t) else { return nil }
        return negative ? -v : v
    }

    static func number(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        return number(any as? String)
    }

    static func string(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return nil
    }

    static func key(_ symbol: String) -> String {
        symbol.trimmingCharacters(in: .whitespaces).uppercased()
            .replacingOccurrences(of: ".", with: "-").replacingOccurrences(of: "/", with: "-")
    }

    /// "10/24/2025" → "2025-10-24".
    static func usDate(_ s: String?) -> String? {
        let parts = (s ?? "").split(separator: "/").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return String(format: "%04d-%02d-%02d", parts[2], parts[0], parts[1])
    }
}

/// Days as "yyyy-MM-dd" in the Mac's calendar (U.S. reporting dates; noon avoids daylight-saving edges).
nonisolated enum EarningsDates {
    static func string(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func today() -> String { string(Date()) }

    static func date(_ s: String) -> Date {
        let p = s.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return Date() }
        return Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12)) ?? Date()
    }

    static func add(_ s: String, days: Int) -> String {
        string(Calendar.current.date(byAdding: .day, value: days, to: date(s)) ?? date(s))
    }

    static func add(_ s: String, months: Int) -> String {
        string(Calendar.current.date(byAdding: .month, value: months, to: date(s)) ?? date(s))
    }

    /// 1 = Sunday … 7 = Saturday.
    static func weekday(_ s: String) -> Int { Calendar.current.component(.weekday, from: date(s)) }

    static func isWeekend(_ s: String) -> Bool { [1, 7].contains(weekday(s)) }

    static func day(_ s: String) -> Int { Calendar.current.component(.day, from: date(s)) }

    static func sameMonth(_ a: String, _ b: String) -> Bool { a.prefix(7) == b.prefix(7) }

    /// Every day of `s`'s month.
    static func month(_ s: String) -> [String] {
        let first = String(s.prefix(7)) + "-01"
        let count = Calendar.current.range(of: .day, in: .month, for: date(first))?.count ?? 30
        return (0..<count).map { add(first, days: $0) }
    }

    /// Monday to Sunday of `s`'s week.
    static func week(_ s: String) -> [String] {
        let monday = add(s, days: -((weekday(s) + 5) % 7))
        return (0..<7).map { add(monday, days: $0) }
    }

    /// The month grid: whole weeks, Monday first, covering `s`'s month.
    static func monthGrid(_ s: String) -> [String] {
        let days = month(s)
        let start = week(days[0])[0]
        let end = week(days[days.count - 1])[6]
        var out: [String] = []
        var d = start
        while d <= end {
            out.append(d)
            d = add(d, days: 1)
        }
        return out
    }

    /// The weekday before or after, skipping weekends.
    static func nextWeekday(_ s: String, _ step: Int) -> String {
        var d = add(s, days: step)
        while isWeekend(d) { d = add(d, days: step) }
        return d
    }

    static func title(_ s: String, weekday: Bool = true) -> String {
        weekday ? date(s).formatted(.dateTime.weekday(.wide).month(.wide).day().year())
            : date(s).formatted(.dateTime.month(.abbreviated).day().year())
    }
}

// MARK: - Sources

/// Nasdaq.com's public JSON API (the same one srmlib's Nasdaq loaders use, with a browser-like User-Agent).
nonisolated enum NasdaqEarningsClient {
    static let base = "https://api.nasdaq.com/api/"
    static let headers = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 Chrome/130 Safari/537.36",
                          "Accept": "application/json"]

    enum Failure: LocalizedError {
        case unreachable(String), unexpected(String)
        var errorDescription: String? {
            switch self {
            case .unreachable(let why): "Nasdaq.com couldn't be reached (\(why))."
            case .unexpected(let why): "Nasdaq.com answered in an unexpected form (\(why))."
            }
        }
    }

    private static func json(_ path: String) async throws -> [String: Any] {
        var r = URLRequest(url: URL(string: base + path)!, timeoutInterval: 30)
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: r)
        } catch {
            throw Failure.unreachable(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw Failure.unexpected("HTTP \(http.statusCode)") }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.unexpected("not JSON") }
        return json
    }

    /// Every company Nasdaq.com lists for `date` — [] when it lists none ("No record found").
    static func day(_ date: String) async throws -> [NasdaqEarningsRow] {
        let json = try await json("calendar/earnings?date=\(date)")
        guard let data = json["data"] as? [String: Any], let rows = data["rows"] as? [[String: Any]] else { return [] }
        return rows.compactMap { r in
            guard let symbol = EarningsParse.string(r["symbol"])?.trimmingCharacters(in: .whitespaces), !symbol.isEmpty else { return nil }
            let s = { (k: String) in EarningsParse.string(r[k]) }
            return NasdaqEarningsRow(symbol: symbol, name: s("name"), time: s("time"), marketCap: s("marketCap"),
                                     fiscalQuarterEnding: s("fiscalQuarterEnding"), epsForecast: s("epsForecast"),
                                     noOfEsts: s("noOfEsts"), lastYearRptDt: s("lastYearRptDt"), lastYearEPS: s("lastYearEPS"),
                                     eps: s("eps"), surprise: s("surprise"))
        }
    }

    /// One day's rows, or why they couldn't be fetched. (A struct: with Swift 6.4 at -O, a task group whose children
    /// returned the same fields as a tuple lost every result.)
    struct DayResult: Sendable {
        var date: String
        var rows: [NasdaqEarningsRow]?
        var problem: String?
    }

    /// Several days at once.
    static func days(_ dates: [String]) async -> [DayResult] {
        await withTaskGroup(of: DayResult.self) { group in
            for d in dates {
                group.addTask {
                    do { return DayResult(date: d, rows: try await day(d)) } catch { return DayResult(date: d, problem: error.localizedDescription) }
                }
            }
            var out: [DayResult] = []
            for await r in group { out.append(r) }
            return out
        }
    }

    struct Surprise: Hashable, Sendable {
        var quarter: String
        var reported: String?
        var eps: Double?
        var consensus: Double?
        var surprise: Double?
    }

    struct Forecast: Hashable, Sendable {
        var quarter: String
        var consensus: Double?
        var high: Double?
        var low: Double?
        var estimates: Int?
        var up: Int?
        var down: Int?
    }

    private static func path(_ symbol: String) -> String {
        symbol.lowercased().addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? symbol
    }

    /// The company's last four reports against the consensus.
    static func surprises(_ symbol: String) async throws -> [Surprise] {
        let json = try await json("company/\(path(symbol))/earnings-surprise")
        let rows = ((json["data"] as? [String: Any])?["earningsSurpriseTable"] as? [String: Any])?["rows"] as? [[String: Any]] ?? []
        return rows.map { r in
            Surprise(quarter: EarningsParse.string(r["fiscalQtrEnd"]) ?? "", reported: EarningsParse.usDate(EarningsParse.string(r["dateReported"])),
                     eps: EarningsParse.number(r["eps"]), consensus: EarningsParse.number(r["consensusForecast"]),
                     surprise: EarningsParse.number(r["percentageSurprise"]).map { $0 / 100 })
        }
    }

    /// Analysts' EPS forecasts for the next quarters: consensus, range, number and the last four weeks' revisions.
    static func forecasts(_ symbol: String) async throws -> [Forecast] {
        let json = try await json("analyst/\(path(symbol))/earnings-forecast")
        let rows = ((json["data"] as? [String: Any])?["quarterlyForecast"] as? [String: Any])?["rows"] as? [[String: Any]] ?? []
        return rows.map { r in
            Forecast(quarter: EarningsParse.string(r["fiscalEnd"]) ?? "", consensus: EarningsParse.number(r["consensusEPSForecast"]),
                     high: EarningsParse.number(r["highEPSForecast"]), low: EarningsParse.number(r["lowEPSForecast"]),
                     estimates: EarningsParse.number(r["noOfEstimates"]).map { Int($0) },
                     up: EarningsParse.number(r["up"]).map { Int($0) }, down: EarningsParse.number(r["down"]).map { Int($0) })
        }
    }
}

/// FMP's earnings data through the accounts service (Services/accounts, port 8774), which holds SRM's FMP key.
nonisolated enum FMPEarningsClient {
    struct CalendarPage: Decodable, Sendable {
        var from: String
        var to: String
        var planStart: String
        var rows: [FMPEarningsRow]
    }

    struct History: Decodable, Sendable {
        var symbol: String
        var rows: [FMPEarningsRow]
    }

    private static func get<T: Decodable>(_ path: String, as: T.Type) async throws -> T {
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: URLRequest(url: URL(string: AccountsClient.base + path)!, timeoutInterval: 90))
        } catch {
            throw ServiceClient.Failure.notRunning(AccountsClient.service)
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let error = json["error"] as? String {
            throw ServiceClient.Failure.rejected("FMP through the accounts service: \(error)")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ServiceClient.Failure.rejected("The accounts service has no earnings endpoints yet — restart it: python3 Services/mxservices.py restart accounts")
        }
    }

    /// FMP's calendar from `from` to `to` (at most 62 days); days before `planStart` are not on the plan.
    static func calendar(from: String, to: String) async throws -> CalendarPage {
        try await get("/earnings/calendar?from=\(from)&to=\(to)", as: CalendarPage.self)
    }

    /// A company's reports, newest first.
    static func history(_ symbol: String, limit: Int = 40) async throws -> History {
        let s = symbol.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? symbol
        return try await get("/earnings/history?symbol=\(s)&limit=\(limit)", as: History.self)
    }
}

// MARK: - Kept on this Mac

/// Each day's listings in Application Support/Earnings (the app's container): past days load at once, and a past
/// listing keeps the times of day an earlier one gave.
nonisolated enum EarningsCache {
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Earnings", isDirectory: true)
    }

    static func read(_ date: String) -> EarningsDayFile? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(date + ".json")) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(EarningsDayFile.self, from: data)
    }

    static func write(_ file: EarningsDayFile) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        if let data = try? e.encode(file) { try? data.write(to: folder.appendingPathComponent(file.date + ".json"), options: .atomic) }
    }

    /// A listing fetched three days or more after its date is final; otherwise it is fetched again after 30 minutes.
    static func nasdaqStale(_ f: EarningsDayFile) -> Bool {
        guard f.nasdaq != nil, let fetched = f.nasdaqFetched else { return true }
        if EarningsDates.string(fetched) >= EarningsDates.add(f.date, days: 3) { return false }
        return Date().timeIntervalSince(fetched) > 1800
    }

    /// FMP's figures settle within a week; days before the plan's window keep what was kept.
    static func fmpStale(_ f: EarningsDayFile, planStart: String) -> Bool {
        guard f.date >= planStart else { return false }
        guard f.fmp != nil, let fetched = f.fmpFetched else { return true }
        if EarningsDates.string(fetched) >= EarningsDates.add(f.date, days: 7) { return false }
        return Date().timeIntervalSince(fetched) > 1800
    }

    /// A past listing leaves out the time of day and last year's report: keep them from the earlier listing.
    static func keepingEarlier(_ rows: [NasdaqEarningsRow], from old: [NasdaqEarningsRow]?) -> [NasdaqEarningsRow] {
        guard let old, !old.isEmpty else { return rows }
        let earlier = Dictionary(old.map { (EarningsParse.key($0.symbol), $0) }, uniquingKeysWith: { a, _ in a })
        return rows.map { r in
            guard let o = earlier[EarningsParse.key(r.symbol)] else { return r }
            var r = r
            if ReportTime(nasdaq: r.time) == .notGiven, ReportTime(nasdaq: o.time) != .notGiven {
                r.time = o.time
                r.keptFromEarlier = true
            }
            if r.lastYearRptDt == nil { r.lastYearRptDt = o.lastYearRptDt }
            if r.lastYearEPS == nil { r.lastYearEPS = o.lastYearEPS }
            if (r.noOfEsts ?? "").isEmpty { r.noOfEsts = o.noOfEsts }
            return r
        }
    }
}

// MARK: - Store

@MainActor
@Observable
final class EarningsStore {
    enum Mode: String, CaseIterable, Identifiable {
        case month = "Month", week = "Week"
        var id: String { rawValue }
    }

    /// The day Earnings by Day shows.
    var date = EarningsDates.today() {
        didSet { if date != oldValue { selection = nil } }
    }
    var mode = Mode(rawValue: UserDefaults.standard.string(forKey: "earningsMode") ?? "") ?? .month {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "earningsMode") }
    }
    /// A day in the month or week the calendar shows.
    var anchor = EarningsDates.today()

    var days: [String: EarningsDay] = [:]
    var loading: Set<String> = []
    /// Nasdaq.com listings fetched so far in the current load, of how many.
    var progress: (done: Int, total: Int)?
    /// The first day FMP's plan reaches (12 months back), as the accounts service last said.
    var planStart = EarningsDates.add(EarningsDates.today(), days: -364)
    var nasdaqProblem: String?
    var fmpProblem: String?
    var companies: [String: CompanyEarnings] = [:]

    // Earnings by Day: filters and the selected company.
    var search = ""
    var timeFilter: ReportTime?
    var includeFMPOnly = UserDefaults.standard.bool(forKey: "earningsIncludeFMPOnly") {
        didSet { UserDefaults.standard.set(includeFMPOnly, forKey: "earningsIncludeFMPOnly") }
    }
    var onlyHeld = false
    var selection: String?

    /// The calendar's days: the month's (or week's) days, and the grid around them.
    var calendarDays: [String] { mode == .month ? EarningsDates.month(anchor) : EarningsDates.week(anchor) }

    func isLoading(_ date: String) -> Bool { loading.contains(date) }

    /// Loads days: FMP's calendar for their span in one request, then Nasdaq.com's listings, three at a time. What is
    /// kept on this Mac shows at once; only stale listings are fetched (all of them with `force`).
    /// `weekends` asks Nasdaq.com for Saturdays and Sundays too (otherwise only where FMP lists reports).
    func load(_ dates: [String], force: Bool = false, weekends: Bool = false) async -> String {
        // Another load of these days (the calendar's) finishes first; this one then finds them fresh.
        while dates.contains(where: loading.contains) {
            try? await Task.sleep(for: .milliseconds(150))
            if Task.isCancelled { return "" }
        }
        guard !dates.isEmpty else { return "" }
        loading.formUnion(dates)
        defer { loading.subtract(dates) }

        var files = await Task.detached {
            Dictionary(uniqueKeysWithValues: dates.map { ($0, EarningsCache.read($0) ?? EarningsDayFile(date: $0)) })
        }.value
        for (d, f) in files where days[d] == nil && (f.nasdaq != nil || f.fmp != nil) { days[d] = EarningsDay(f) }
        var changed: Set<String> = []

        let today = EarningsDates.today()
        let fmpDates = dates.filter { force ? $0 >= planStart : EarningsCache.fmpStale(files[$0]!, planStart: planStart) }
        if let lo = fmpDates.min(), let hi = fmpDates.max() {
            do {
                let cal = try await FMPEarningsClient.calendar(from: lo, to: hi)
                planStart = cal.planStart
                let byDate = Dictionary(grouping: cal.rows, by: \.date)
                for d in fmpDates where d >= cal.planStart {
                    files[d]!.fmp = byDate[d] ?? []
                    files[d]!.fmpFetched = Date()
                    changed.insert(d)
                }
                fmpProblem = nil
            } catch {
                if !Task.isCancelled { fmpProblem = error.localizedDescription }
            }
        }

        let nasdaqDates = dates.filter { d in
            (force || EarningsCache.nasdaqStale(files[d]!)) && (weekends || !EarningsDates.isWeekend(d) || !(files[d]!.fmp ?? []).isEmpty)
                && d <= EarningsDates.add(today, days: 120)
        }
        progress = nasdaqDates.isEmpty ? nil : (0, nasdaqDates.count)
        var failures = 0
        var published: Set<String> = []
        for start in stride(from: 0, to: nasdaqDates.count, by: 3) {
            if Task.isCancelled { break }
            let batch = Array(nasdaqDates[start..<min(start + 3, nasdaqDates.count)])
            let results = await NasdaqEarningsClient.days(batch)
            for r in results {
                let d = r.date
                if let rows = r.rows {
                    files[d]!.nasdaq = EarningsCache.keepingEarlier(rows, from: files[d]!.nasdaq)
                    files[d]!.nasdaqFetched = Date()
                    changed.insert(d)
                    days[d] = EarningsDay(files[d]!)
                    published.insert(d)
                } else if !Task.isCancelled {
                    failures += 1
                    nasdaqProblem = r.problem
                }
                progress?.done += 1
            }
        }
        if failures == 0, !nasdaqDates.isEmpty { nasdaqProblem = nil }
        progress = nil

        let toWrite = changed.map { files[$0]! }
        await Task.detached { for f in toWrite { EarningsCache.write(f) } }.value
        // Each day is published once per change: a table that is laying out its rows shouldn't see them twice.
        for d in changed.subtracting(published) { days[d] = EarningsDay(files[d]!) }
        for d in dates where days[d] == nil { days[d] = EarningsDay(files[d]!) }

        let listed = dates.compactMap { days[$0] }.reduce(0) { $0 + $1.listed.count }
        let withRevenue = dates.compactMap { days[$0] }.reduce(0) { $0 + $1.listed.filter(\.onFMP).count }
        let what = dates.count == 1 ? EarningsDates.title(dates[0], weekday: false) : "\(EarningsDates.title(dates.min()!, weekday: false)) – \(EarningsDates.title(dates.max()!, weekday: false))"
        return "Earnings \(what): \(listed.formatted()) reports" + (withRevenue > 0 ? ", revenue from FMP for \(withRevenue.formatted())" : "")
            + (nasdaqDates.isEmpty && fmpDates.isEmpty ? " (kept on this Mac)" : "")
    }

    /// The selected company's history from FMP (through the accounts service) and Nasdaq.com.
    func loadCompany(_ symbol: String) async {
        guard companies[symbol] == nil else { return }
        companies[symbol] = CompanyEarnings()
        async let history = attempt { try await FMPEarningsClient.history(symbol) }
        async let surprises = attempt { try await NasdaqEarningsClient.surprises(symbol) }
        async let forecasts = attempt { try await NasdaqEarningsClient.forecasts(symbol) }
        var c = CompanyEarnings()
        switch await history {
        case .success(let h): c.history = h.rows
        case .failure(let e): c.historyNote = e.localizedDescription
        }
        switch await surprises {
        case .success(let s): c.surprises = s
        case .failure(let e): c.nasdaqNote = e.localizedDescription
        }
        if case .success(let f) = await forecasts { c.forecasts = f }
        c.loading = false
        companies[symbol] = c
    }
}

/// The result of an async throwing call.
nonisolated func attempt<T>(_ body: () async throws -> T) async -> Result<T, any Error> {
    do { return .success(try await body()) } catch { return .failure(error) }
}
