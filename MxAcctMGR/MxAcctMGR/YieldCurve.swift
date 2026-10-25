//
//  YieldCurve.swift
//  MxAcctMGR
//
//  The real Treasury yield curve, in the Yield Curve Report walkthrough (its first step, after The real report): the
//  curve today against 1 month, 1 year, 5 and 10 years before; the slope (10-year minus 2-year and minus 3-month)
//  over 1, 5 or 10 years or since 1977, with recessions shaded; the yields themselves over the same periods; and every
//  inversion since 1981 with when the next recession began.
//
//  Data: the Treasury's daily constant-maturity yields as FRED publishes them (DGS1MO … DGS30, back to 1962) and the
//  NBER recession months (USREC) — free CSV files, no key — from the security master when MxDataHUB keeps them current
//  there (srm.py load fred-yields, through the accounts service), else from FRED. Read at most hourly; the copies kept
//  in the app's Caches folder are used when neither can be reached.
//

import Charts
import SwiftUI

// MARK: - Data

nonisolated enum Maturity: String, CaseIterable, Identifiable, Sendable {
    case m1 = "DGS1MO", m3 = "DGS3MO", m6 = "DGS6MO", y1 = "DGS1", y2 = "DGS2", y3 = "DGS3", y5 = "DGS5", y7 = "DGS7",
         y10 = "DGS10", y20 = "DGS20", y30 = "DGS30"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .m1: "1M"
        case .m3: "3M"
        case .m6: "6M"
        case .y1: "1Y"
        case .y2: "2Y"
        case .y3: "3Y"
        case .y5: "5Y"
        case .y7: "7Y"
        case .y10: "10Y"
        case .y20: "20Y"
        case .y30: "30Y"
        }
    }

    var name: String {
        switch self {
        case .m1: "1-month bill"
        case .m3: "3-month bill"
        case .m6: "6-month bill"
        case .y1: "1-year"
        case .y2: "2-year note"
        case .y3: "3-year note"
        case .y5: "5-year note"
        case .y7: "7-year note"
        case .y10: "10-year note"
        case .y20: "20-year bond"
        case .y30: "30-year bond"
        }
    }

    var index: Int { Maturity.allCases.firstIndex(of: self)! }
}

/// One day's yields (percent), by Maturity.index; nil where the Treasury had no such issue then.
nonisolated struct YieldDay: Identifiable, Sendable {
    let date: Date
    let yields: [Double?]
    var id: Date { date }
    subscript(_ m: Maturity) -> Double? { yields[m.index] }
    func spread(_ long: Maturity, _ short: Maturity) -> Double? {
        guard let l = self[long], let s = self[short] else { return nil }
        return l - s
    }
}

nonisolated struct Recession: Identifiable, Sendable {
    let start: Date
    let end: Date
    var id: Date { start }
}

/// A run of days with the 10-year below the 3-month.
nonisolated struct Inversion: Identifiable, Sendable {
    let start: Date
    let end: Date
    let days: Int
    let deepest: Double
    /// The first recession that began after the inversion did (within three years), and the months between.
    let recession: Date?
    let leadMonths: Int?
    var id: Date { start }
}

nonisolated enum YieldData {
    static let yieldsURL = URL(string: "https://fred.stlouisfed.org/graph/fredgraph.csv?id=" + Maturity.allCases.map(\.rawValue).joined(separator: ","))!
    static let recessionsURL = URL(string: "https://fred.stlouisfed.org/graph/fredgraph.csv?id=USREC")!

    static func date(_ iso: String) -> Date? { isoDay.date(from: iso) }

    private static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/New_York")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// FRED's CSV: observation_date, then one column per maturity in Maturity's order; empty or "." when missing.
    static func parseYields(_ csv: String) -> [YieldDay] {
        csv.split(whereSeparator: \.isNewline).dropFirst().compactMap { line in
            let f = line.split(separator: ",", omittingEmptySubsequences: false)
            guard f.count >= Maturity.allCases.count + 1, let date = isoDay.date(from: String(f[0])) else { return nil }
            let values = f[1...Maturity.allCases.count].map { Double($0) }
            guard values.contains(where: { $0 != nil }) else { return nil }   // holidays: all empty
            return YieldDay(date: date, yields: values)
        }
    }

    /// FRED's USREC: one row a month, 1 in a recession; consecutive 1s make a recession (to the end of its last month).
    static func parseRecessions(_ csv: String) -> [Recession] {
        var out: [Recession] = []
        var start: Date?
        var last: Date?
        for line in csv.split(whereSeparator: \.isNewline).dropFirst() {
            let f = line.split(separator: ",")
            guard f.count >= 2, let date = isoDay.date(from: String(f[0])) else { continue }
            if f[1] == "1" {
                if start == nil { start = date }
                last = date
            } else if let s = start, let l = last {
                out.append(Recession(start: s, end: Calendar.current.date(byAdding: .month, value: 1, to: l)!))
                start = nil
            }
        }
        if let s = start, let l = last { out.append(Recession(start: s, end: Calendar.current.date(byAdding: .month, value: 1, to: l)!)) }
        return out
    }

    /// Runs of the 10-year below the 3-month (from 1981, when the 3-month series starts): breaks shorter than 60
    /// trading days join one inversion; inversions shorter than 10 days are left out.
    static func inversions(_ days: [YieldDay], recessions: [Recession]) -> [Inversion] {
        var runs: [(Int, Int)] = []
        var start: Int?
        for (i, d) in days.enumerated() {
            guard let s = d.spread(.y10, .m3) else { continue }
            if s < 0 {
                if start == nil { start = i }
            } else if let st = start {
                runs.append((st, i - 1))
                start = nil
            }
        }
        if let st = start { runs.append((st, days.count - 1)) }
        var merged: [(Int, Int)] = []
        for r in runs {
            if let last = merged.last, r.0 - last.1 < 60 { merged[merged.count - 1].1 = r.1 } else { merged.append(r) }
        }
        return merged.compactMap { a, b in
            let negative = days[a...b].compactMap { $0.spread(.y10, .m3) }.filter { $0 < 0 }
            guard negative.count >= 10 else { return nil }
            let begin = days[a].date
            let next = recessions.first { $0.start > begin && $0.start < Calendar.current.date(byAdding: .year, value: 3, to: begin)! }
            let months = next.map { Calendar.current.dateComponents([.month], from: begin, to: $0.start).month ?? 0 }
            return Inversion(start: begin, end: days[b].date, days: negative.count, deepest: negative.min() ?? 0,
                             recession: next?.start, leadMonths: months)
        }
    }
}

/// One file read (a struct, not a tuple: concurrent child tasks returning tuples lose their results in this toolchain).
private nonisolated struct FREDFetch: Sendable {
    var text: String?
    var fromCache: Bool
    var problem: String?
    var fromSecurityMaster = false
}

@MainActor
@Observable
final class YieldStore {
    static let shared = YieldStore()

    private(set) var days: [YieldDay] = []
    private(set) var recessions: [Recession] = []
    private(set) var loading = false
    private(set) var problem: String?
    private(set) var fetchedAt: Date?
    /// The yields were read from the security master's copy rather than from FRED.
    private(set) var fromSecurityMaster = false
    @ObservationIgnored private var lastLoad = Date.distantPast

    func load(force: Bool = false) async {
        guard !loading, force || days.isEmpty || Date().timeIntervalSince(lastLoad) > 3600 else { return }
        loading = true
        problem = nil
        // FRED posts a day's yields the next business day; USREC's months come a month or two late.
        async let y = Self.fetch(YieldData.yieldsURL, series: Maturity.allCases.map(\.rawValue), currentDays: 6, cache: "treasury-yields.csv")
        async let r = Self.fetch(YieldData.recessionsURL, series: ["USREC"], currentDays: 120, cache: "usrec.csv")
        let (yields, rec) = (await y, await r)
        fromSecurityMaster = yields.fromSecurityMaster
        if let t = yields.text { days = YieldData.parseYields(t) }
        if let t = rec.text { recessions = YieldData.parseRecessions(t) }
        if days.isEmpty {
            problem = yields.problem ?? "No Treasury yields."
        } else if yields.fromCache || rec.fromCache {
            problem = "FRED couldn't be reached; showing the copy kept on this Mac."
        } else {
            fetchedAt = Date()
        }
        lastLoad = Date()
        loading = false
    }

    /// The newest observation_date in a FRED-layout CSV.
    private nonisolated static func lastDate(_ csv: String) -> Date? {
        guard let line = csv.split(whereSeparator: \.isNewline).last, let field = line.split(separator: ",").first else { return nil }
        return YieldData.date(String(field))
    }

    private nonisolated static func fetch(_ url: URL, series: [String], currentDays: Int, cache name: String) async -> FREDFetch {
        let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent(name)
        // The security master's copy first (the same layout as FRED's file), when it is current.
        if let text = await SecurityMasterSeries.csv(series), text.hasPrefix("observation_date"),
           SecurityMasterSeries.isCurrent(lastDate(text), days: currentDays) {
            if let file, let data = text.data(using: .utf8) { try? data.write(to: file, options: .atomic) }
            return FREDFetch(text: text, fromCache: false, fromSecurityMaster: true)
        }
        do {
            var request = URLRequest(url: url, timeoutInterval: 60)
            request.setValue("MxAcctMGR (educational)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let text = String(data: data, encoding: .utf8),
                  text.hasPrefix("observation_date") else { throw URLError(.badServerResponse) }
            if let file { try? data.write(to: file, options: .atomic) }
            return FREDFetch(text: text, fromCache: false)
        } catch {
            if let file, let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) {
                return FREDFetch(text: text, fromCache: true, problem: error.localizedDescription)
            }
            return FREDFetch(text: nil, fromCache: false, problem: "FRED couldn't be reached: \(error.localizedDescription)")
        }
    }
}

// MARK: - The views

/// A point on a chart: a series' value at an x (a date or a maturity).
private struct SeriesPoint: Identifiable {
    var series: String
    var date: Date
    var value: Double
    var id: String { "\(series)|\(date.timeIntervalSince1970)" }
}

private struct CurvePoint: Identifiable {
    var curve: String
    var maturity: Maturity
    var value: Double
    var id: String { "\(curve)|\(maturity.rawValue)" }
}

/// The real yield curve, its slope and its yields over time.
struct RealYieldCurve: View {
    @State private var yields = YieldStore.shared
    @State private var compare: Set<Int> = [12, 60]
    @State private var period: Period = .tenYears
    @State private var inversionSelection = Set<Date>()

    enum Period: String, CaseIterable, Identifiable {
        case oneYear = "1Y", fiveYears = "5Y", tenYears = "10Y", twentyFive = "25Y", all = "Since 1977"
        var id: String { rawValue }
        var years: Int? {
            switch self {
            case .oneYear: 1
            case .fiveYears: 5
            case .tenYears: 10
            case .twentyFive: 25
            case .all: nil
            }
        }
    }

    /// The curves to compare with today's, in months back.
    private static let comparisons: [(months: Int, title: String)] = [(1, "1 month ago"), (12, "1 year ago"), (60, "5 years ago"), (120, "10 years ago")]

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    private static let inversionsText = TableText<Inversion>(
        titles: ["Inverted from", "to", "Days inverted", "Deepest (10Y − 3M)", "Next recession began", "Months later"]) { i in
        [day.string(from: i.start), day.string(from: i.end), String(i.days), String(format: "%.2f", i.deepest),
         i.recession.map { day.string(from: $0) } ?? "none yet", i.leadMonths.map(String.init) ?? "—"]
    }

    var body: some View {
        Group {
            if let today = yields.days.last {
                todayBox(today)
                curveBox(today)
                slopeBox
                yieldsBox
                inversionsBox
            } else {
                Box(title: "The real yield curve", symbol: "chart.line.uptrend.xyaxis") {
                    if yields.loading {
                        HStack { ProgressView().controlSize(.small); Text("Reading Treasury yields from FRED…").foregroundStyle(.secondary) }
                    } else {
                        Text(yields.problem ?? "No data yet.").foregroundStyle(.secondary)
                        Button("Try Again") { Task { await yields.load(force: true) } }
                    }
                }
            }
        }
        .task { await yields.load() }
    }

    // MARK: Today

    private func todayBox(_ today: YieldDay) -> some View {
        let s2 = today.spread(.y10, .y2), s3 = today.spread(.y10, .m3)
        return Box(title: "The real curve today · \(Self.day.string(from: today.date))", symbol: "chart.line.uptrend.xyaxis",
                   help: "The Treasury's constant-maturity yields on the latest day FRED has, and the curve's slope.") {
            HStack(spacing: 10) {
                ForEach([Maturity.m3, .y2, .y10, .y30]) { m in
                    MetricTile(title: m.name, value: today[m].map { String(format: "%.2f%%", $0) } ?? "—",
                               caption: change(m, months: 12).map { String(format: "%+.2f in a year", $0) } ?? "",
                               help: "The \(m.name)'s yield, and its change from a year earlier, in percentage points.")
                }
                MetricTile(title: "10Y − 2Y", value: s2.map { String(format: "%+.2f", $0) } ?? "—",
                           caption: (s2 ?? 0) < 0 ? "inverted" : "upward sloping", tint: (s2 ?? 0) < 0 ? .red : .green,
                           help: "The 10-year yield minus the 2-year, in percentage points. Negative is an inverted curve.")
                MetricTile(title: "10Y − 3M", value: s3.map { String(format: "%+.2f", $0) } ?? "—",
                           caption: (s3 ?? 0) < 0 ? "inverted" : "upward sloping", tint: (s3 ?? 0) < 0 ? .red : .green,
                           help: "The 10-year minus the 3-month: the slope with the longest recession record (the New York Fed's model uses it).")
            }
            Text(statusLine).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let problem = yields.problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    /// Whether the curve is inverted now, and for how long, or since when it hasn't been.
    private var statusLine: String {
        let days = yields.days
        guard let today = days.last, let s = today.spread(.y10, .m3) else { return "" }
        let inverted = s < 0
        var i = days.count - 1
        while i > 0, let x = days[i].spread(.y10, .m3), (x < 0) == inverted { i -= 1 }
        let since = days[min(i + 1, days.count - 1)].date
        let count = days.count - 1 - i
        return inverted
            ? "The 10-year has been below the 3-month for \(count) trading days, since \(Self.day.string(from: since)). Below, every inversion since 1981 and the recession that followed — or didn't."
            : "The 10-year has been above the 3-month since \(Self.day.string(from: since)) (\(count) trading days). Below, every inversion since 1981 and the recession that followed — or didn't."
    }

    /// The change in a maturity's yield over the last `months`.
    private func change(_ m: Maturity, months: Int) -> Double? {
        guard let today = yields.days.last, let now = today[m], let then = day(monthsBack: months)?[m] else { return nil }
        return now - then
    }

    /// The last day on or before `months` before the latest.
    private func day(monthsBack months: Int) -> YieldDay? {
        guard let last = yields.days.last, let target = Calendar.current.date(byAdding: .month, value: -months, to: last.date) else { return nil }
        return yields.days.last { $0.date <= target }
    }

    // MARK: The curve

    private func curveBox(_ today: YieldDay) -> some View {
        var points = Maturity.allCases.compactMap { m in today[m].map { CurvePoint(curve: "Today", maturity: m, value: $0) } }
        for c in Self.comparisons where compare.contains(c.months) {
            if let d = day(monthsBack: c.months) {
                let name = "\(c.title) · \(Self.day.string(from: d.date))"
                points += Maturity.allCases.compactMap { m in d[m].map { CurvePoint(curve: name, maturity: m, value: $0) } }
            }
        }
        return Box(title: "The curve, then and now", symbol: "point.topleft.down.to.point.bottomright.curvepath",
                   help: "Yield by maturity, from 1 month to 30 years: today's curve and the ones you tick, from up to ten years before.") {
            HStack(spacing: 14) {
                Text("Compare with").font(.callout).foregroundStyle(.secondary)
                ForEach(Self.comparisons, id: \.months) { c in
                    Toggle(c.title, isOn: Binding(get: { compare.contains(c.months) },
                                                  set: { on in if on { compare.insert(c.months) } else { compare.remove(c.months) } }))
                        .toggleStyle(.checkbox)
                }
            }
            Chart(points) { p in
                LineMark(x: .value("Maturity", p.maturity.label), y: .value("Yield (%)", p.value))
                    .foregroundStyle(by: .value("Curve", p.curve))
                    .lineStyle(StrokeStyle(lineWidth: p.curve == "Today" ? 3 : 1.5))
                PointMark(x: .value("Maturity", p.maturity.label), y: .value("Yield (%)", p.value))
                    .foregroundStyle(by: .value("Curve", p.curve))
                    .symbolSize(p.curve == "Today" ? 30 : 12)
            }
            .chartXScale(domain: Maturity.allCases.map(\.label))
            .chartYAxisLabel("yield, %")
            .frame(height: 280)
            Text("Maturities are evenly spaced, as the Treasury draws them. An upward slope is normal: lenders want more to lock money up for longer. A curve that slopes down (inverted) means short rates are expected to fall — often because a slowdown is expected.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Over time

    private var periodPicker: some View {
        Picker("Period", selection: $period) {
            ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 420)
    }

    /// The days in the period chosen; every fifth day over long periods (for the shape, and a quick chart).
    private var periodDays: [YieldDay] {
        let all = yields.days
        guard let last = all.last else { return [] }
        let from: Date
        if let years = period.years {
            from = Calendar.current.date(byAdding: .year, value: -years, to: last.date)!
        } else {
            from = Calendar.current.date(from: DateComponents(year: 1977, month: 1, day: 1))!
        }
        let shown = all.filter { $0.date >= from }
        let step = (period.years ?? 50) > 5 ? 5 : 1
        return shown.enumerated().filter { $0.offset % step == 0 || $0.offset == shown.count - 1 }.map(\.element)
    }

    private var periodRecessions: [Recession] {
        guard let first = periodDays.first?.date, let last = periodDays.last?.date else { return [] }
        return yields.recessions.filter { $0.end > first && $0.start < last }.map {
            Recession(start: max($0.start, first), end: min($0.end, last))
        }
    }

    private var slopeBox: some View {
        let days = periodDays
        let points = days.flatMap { d -> [SeriesPoint] in
            [d.spread(.y10, .y2).map { SeriesPoint(series: "10Y − 2Y", date: d.date, value: $0) },
             d.spread(.y10, .m3).map { SeriesPoint(series: "10Y − 3M", date: d.date, value: $0) }].compactMap { $0 }
        }
        return Box(title: "The slope over time", symbol: "chart.xyaxis.line",
                   help: "The 10-year minus the 2-year and minus the 3-month, in percentage points. Below zero the curve is inverted; grey bands are recessions (NBER).") {
            periodPicker
            Chart {
                ForEach(periodRecessions) { r in
                    RectangleMark(xStart: .value("From", r.start), xEnd: .value("To", r.end))
                        .foregroundStyle(.gray.opacity(0.18))
                }
                RuleMark(y: .value("Zero", 0)).foregroundStyle(.red.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                ForEach(points) { p in
                    LineMark(x: .value("Date", p.date), y: .value("Spread", p.value))
                        .foregroundStyle(by: .value("Spread", p.series))
                }
            }
            .chartYAxisLabel("percentage points")
            .frame(height: 260)
            Text("Grey bands are recessions. Below the dashed line the curve is inverted. Inversions have come before every recession since the 1970s — but months or years before, and the longest, which began in 2022, wasn't followed by one in the data so far.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var yieldsBox: some View {
        let days = periodDays
        let shown: [Maturity] = [.m3, .y2, .y10, .y30]
        let points = days.flatMap { d in shown.compactMap { m in d[m].map { SeriesPoint(series: m.label, date: d.date, value: $0) } } }
        return Box(title: "Yields over time", symbol: "chart.line.uptrend.xyaxis",
                   help: "The 3-month, 2-year, 10-year and 30-year yields over the period chosen above; recessions shaded.") {
            Chart {
                ForEach(periodRecessions) { r in
                    RectangleMark(xStart: .value("From", r.start), xEnd: .value("To", r.end))
                        .foregroundStyle(.gray.opacity(0.18))
                }
                ForEach(points) { p in
                    LineMark(x: .value("Date", p.date), y: .value("Yield", p.value))
                        .foregroundStyle(by: .value("Maturity", p.series))
                }
            }
            .chartYScale(domain: 0...max(1, (points.map(\.value).max() ?? 5).rounded(.up) + 0.5))
            .chartYAxisLabel("yield, %")
            .frame(height: 260)
            Text("Short yields follow the Federal Reserve's policy rate; long yields add the market's view of growth, inflation and government borrowing. When short yields rise above long ones, the curve inverts.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Inversions

    private var inversionsBox: some View {
        let rows = YieldData.inversions(yields.days, recessions: yields.recessions).reversed().map { $0 }
        let followed = rows.filter { $0.recession != nil }
        let leads = followed.compactMap(\.leadMonths).sorted()
        return Box(title: "Every inversion since 1981", symbol: "arrow.down.right.and.arrow.up.left",
                   help: "Runs of the 10-year below the 3-month (gaps under three months joined, runs under ten days left out), and the first recession within three years.") {
            Text(rows.isEmpty ? "No inversions in the data." :
                 "\(rows.count) inversions; \(followed.count) were followed by a recession within three years, \(leads.isEmpty ? "" : "after \(leads.first!) to \(leads.last!) months"). A warning, not a timer.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Table(rows, selection: $inversionSelection) {
                TableColumn("Inverted from") { i in Text(Self.day.string(from: i.start)) }
                TableColumn("to") { i in Text(Self.day.string(from: i.end)) }
                TableColumn("Days inverted") { i in Text(String(i.days)).monospacedDigit() }
                TableColumn("Deepest") { i in Text(String(format: "%.2f", i.deepest)).monospacedDigit().foregroundStyle(.red) }
                TableColumn("Next recession began") { i in Text(i.recession.map { Self.day.string(from: $0) } ?? "none yet").foregroundStyle(i.recession == nil ? .secondary : .primary) }
                TableColumn("Months later") { i in Text(i.leadMonths.map(String.init) ?? "—").monospacedDigit() }
            }
            .tableText()
            .copyRowsMenu(rows, as: Self.inversionsText)
            .copiesSelectedRows(rows, selected: inversionSelection, as: Self.inversionsText)
            .frame(minHeight: CGFloat(rows.count) * 24 + 34)
            SelectableText(text: {
                var l = RichLines()
                l.paragraph(yields.fetchedAt.map { "Data: daily Treasury constant-maturity yields and NBER recession months from FRED (Federal Reserve Bank of St. Louis)"
                                + (yields.fromSecurityMaster ? ", kept in the security master (MxDataHUB, srm.py load fred-yields)" : "") + ", read \(Self.day.string(from: $0))." }
                            ?? "Data: daily Treasury constant-maturity yields and NBER recession months from FRED (the copy kept on this Mac).",
                            font: RichLines.captionFont, color: .secondaryLabelColor, spacing: 4)
                l.cells([[RichLines.Cell(text: "FRED: Treasury constant maturity rates", font: RichLines.captionFont, color: .linkColor,
                                         link: URL(string: "https://fred.stlouisfed.org/categories/115")),
                          RichLines.Cell(text: "Treasury: daily par yield curve rates", font: RichLines.captionFont, color: .linkColor,
                                         link: URL(string: "https://home.treasury.gov/resource-center/data-chart-center/interest-rates/TextView?type=daily_treasury_yield_curve"))]])
                return l.result
            }())
        }
    }
}
