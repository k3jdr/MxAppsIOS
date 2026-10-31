//
//  EconomicCalendar.swift
//  MxAcctMGR
//
//  The Morning Briefing's economic calendar: the high-impact U.S. releases from today on, with the estimate and the
//  prior reading (the actual once it's out), from FMP's economic calendar through the accounts service (Services/accounts,
//  GET /economic/calendar). It's read when the page opens and again every 15 minutes while it shows, so nothing has to
//  be loaded by hand. Times are U.S. Eastern, as the releases are scheduled.
//

import SwiftUI

/// One row of GET /economic/calendar.
nonisolated struct EconomicRelease: Decodable, Hashable, Sendable {
    var at: String
    var date: String
    var event: String
    var allDay: Bool
    var estimate: Double?
    var previous: Double?
    var actual: Double?
    var unit: String?
    var impact: String?
}

/// A row of the panel.
nonisolated struct EconomicEvent: Identifiable, Hashable, Sendable {
    var id: String { day + name }
    /// U.S. Eastern, yyyy-MM-dd.
    var day: String
    /// When it's scheduled; nil for an event with no time of day (an election).
    var at: Date?
    var name: String
    /// The walkthrough it's news for (MarketReport.id).
    var report: String?
    var estimate: String?
    var previous: String?
    var actual: String?

    /// "Today", "Tomorrow" or "Mon Nov 2".
    func dayTitle(today: String) -> String {
        if day == today { return "Today" }
        if day == EconomicEvents.add(today, days: 1) { return "Tomorrow" }
        return EconomicEvents.date(day).map { EconomicEvents.title.string(from: $0) } ?? day
    }

    var timeTitle: String { at.map { EconomicEvents.clock.string(from: $0) } ?? "" }

    /// Its name without the period it covers: "ISM Manufacturing PMI (Oct)" is "ISM Manufacturing PMI".
    var shortName: String { name.components(separatedBy: " (")[0] }

    /// "est 54.7 · prior 54.5", or "actual 54.9 · est 54.7" once it's out.
    var figures: String {
        let parts = actual != nil ? [("actual", actual), ("est", estimate)] : [("est", estimate), ("prior", previous)]
        return parts.compactMap { label, value in value.map { "\(label) \($0)" } }.joined(separator: " · ")
    }
}

nonisolated enum EconomicEvents {
    private static let eastern = TimeZone(identifier: "America/New_York")!

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = eastern
        f.dateFormat = format
        return f
    }
    private static let dayFormat = formatter("yyyy-MM-dd")
    fileprivate static let title = formatter("EEE MMM d")
    fileprivate static let clock = formatter("h:mm")

    /// FMP's wording for a release's lines, one list per release, the line to show first: its lines at FMP are
    /// separate events (four for CPI, four for the jobs report), and the panel has one row for each release on a day.
    private static let releases: [(report: String?, events: [String])] = [
        ("jobs", ["Non Farm Payrolls", "Nonfarm Payrolls Private", "Unemployment Rate", "U-6 Unemployment Rate", "Average Hourly Earnings"]),
        ("cpi", ["Core Inflation Rate MoM", "Core Inflation Rate YoY", "Inflation Rate MoM", "Inflation Rate YoY"]),
        ("ppi", ["Producer Price Index MoM", "Producer Price Index YoY", "Core PPI"]),
        ("fomc", ["Fed Interest Rate Decision", "FOMC Economic Projections", "Press Conference", "FOMC Minutes"]),
        ("gdp", ["GDP Growth Rate", "GDP Price Index"]),
        ("ism-manufacturing", ["ISM Manufacturing PMI"]),
        ("ism-services", ["ISM Services PMI"]),
        ("retail-sales", ["Retail Sales MoM"]),
        ("housing", ["Housing Starts (", "Housing Starts", "Building Permits"]),
        ("housing", ["Existing Home Sales (", "Existing Home Sales"]),
        ("housing", ["New Home Sales (", "New Home Sales"]),
        (nil, ["Initial Jobless Claims", "Continuing Jobless Claims", "Jobless Claims 4-Week Average"]),
        (nil, ["Core PCE Price Index", "PCE Price Index", "Personal Income", "Personal Spending"]),
    ]

    static func today(_ now: Date = Date()) -> String { dayFormat.string(from: now) }

    fileprivate static func date(_ day: String) -> Date? { dayFormat.date(from: day) }

    static func add(_ day: String, days: Int) -> String {
        guard let d = date(day) else { return day }
        // Noon, so a day that's 23 or 25 hours long still moves one date.
        return dayFormat.string(from: d.addingTimeInterval(Double(days) * 86400 + 43200))
    }

    /// "1,704K", "4.2%", "54.7".
    static func figure(_ value: Double?, unit: String?) -> String? {
        guard let value else { return nil }
        let number = value.formatted(.number.precision(.fractionLength(0...3)).locale(Locale(identifier: "en_US")))
        switch unit {
        case nil, "": return number
        case "%", "K", "M", "B", "T": return number + unit!
        default: return number + " " + unit!
        }
    }

    /// The high-impact releases from `today` on, soonest first, one row for each release on a day.
    static func upcoming(_ rows: [EconomicRelease], today: String) -> [EconomicEvent] {
        var events: [(key: String, rank: Int, event: EconomicEvent)] = []
        for r in rows where r.impact == "High" {
            let at = r.allDay ? nil : (try? Date(r.at, strategy: .iso8601))
            let day = at.map { dayFormat.string(from: $0) } ?? r.date
            guard day >= today else { continue }
            var release: String? = nil, rank = 0, report: String? = nil
            for (i, group) in releases.enumerated() {
                if let n = group.events.firstIndex(where: { r.event.hasPrefix($0) }) {
                    (release, rank, report) = (String(i), n, group.report)
                    break
                }
            }
            let event = EconomicEvent(day: day, at: at, name: r.event, report: report,
                                      estimate: figure(r.estimate, unit: r.unit), previous: figure(r.previous, unit: r.unit),
                                      actual: figure(r.actual, unit: r.unit))
            let key = day + "|" + (release ?? r.event)
            if let i = events.firstIndex(where: { $0.key == key }) {
                if rank < events[i].rank { events[i] = (key, rank, event) }
            } else {
                events.append((key, rank, event))
            }
        }
        return events.map(\.event).sorted { ($0.day, $0.at ?? .distantPast) < ($1.day, $1.at ?? .distantPast) }
    }
}

@MainActor
@Observable
final class EconomicCalendar {
    static let shared = EconomicCalendar()

    /// How often it's read again while the page shows; the accounts service keeps FMP's answer as long.
    static let every: TimeInterval = 900
    /// How far ahead: a month always has the next few high-impact releases.
    static let days = 30

    private(set) var rows: [EconomicRelease] = []
    /// Why the last request failed, until one doesn't.
    private(set) var problem: String?
    private(set) var updated: Date?

    private init() {}

    var events: [EconomicEvent] { EconomicEvents.upcoming(rows, today: EconomicEvents.today()) }

    /// The next release still to come; an event with no time of day (an election) has no figure to wait for.
    var next: EconomicEvent? {
        let now = Date()
        return events.first { $0.actual == nil && ($0.at ?? .distantPast) > now }
    }

    /// Reads it now if it's older than `every`, then every `every`, until the task is cancelled (the page went).
    func keepCurrent() async {
        while !Task.isCancelled {
            let wait = updated.map { Self.every - Date().timeIntervalSince($0) } ?? 0
            if wait > 0 {
                try? await Task.sleep(for: .seconds(wait))
                continue
            }
            await refresh()
            if problem != nil { try? await Task.sleep(for: .seconds(60)) }
        }
    }

    private func refresh() async {
        let from = EconomicEvents.today()
        do {
            rows = try await FMPEarningsClient.economicCalendar(from: from, to: EconomicEvents.add(from, days: Self.days)).rows
            problem = nil
            updated = Date()
        } catch {
            guard !Task.isCancelled else { return }
            problem = error.localizedDescription.contains("no such endpoint")
                ? "The accounts service has no economic calendar yet — restart it: python3 Services/mxservices.py restart accounts"
                : error.localizedDescription
        }
    }
}
