//
//  VIX.swift
//  MxAcctMGR
//
//  Knowledge Library ▸ VIX: the Cboe Volatility Index, real data. Today's close and where it stands against 1990 to now,
//  its history with the calm-to-panic regimes shaded, the term structure (the 9-day, 30-day, 3-month and 6-month
//  indexes), and every spike above 35 with how long the VIX took to come back under 20 — the lesson being that fear
//  peaks when selling feels most urgent, and passes.
//
//  Data: Cboe's daily history files (cdn.cboe.com, free, no key), the same series FRED republishes as VIXCLS — from
//  the security master when MxDataHUB keeps them current there (srm.py load cboe-vix, through the accounts service),
//  else from Cboe. Kept in the app's Caches folder and read again after an hour; the copy kept is used when neither
//  can be reached.
//

import Charts
import SwiftUI

// MARK: - Data

nonisolated struct VIXPoint: Identifiable, Sendable {
    let date: Date
    let open, high, low, close: Double
    var id: Date { date }
}

/// Cboe's volatility indexes on the S&P 500, by horizon.
nonisolated enum VIXSeries: String, CaseIterable, Identifiable, Sendable {
    case vix9d = "VIX9D", vix = "VIX", vix3m = "VIX3M", vix6m = "VIX6M"
    var id: String { rawValue }

    var horizon: String {
        switch self {
        case .vix9d: "9 days"
        case .vix: "30 days"
        case .vix3m: "3 months"
        case .vix6m: "6 months"
        }
    }

    var url: URL { URL(string: "https://cdn.cboe.com/api/global/us_indices/daily_prices/\(rawValue)_History.csv")! }
}

/// What a VIX level usually means.
nonisolated enum VIXRegime: Int, CaseIterable, Identifiable, Sendable {
    case calm, normal, elevated, stress, panic
    var id: Int { rawValue }

    init(_ level: Double) {
        self = level < 15 ? .calm : level < 20 ? .normal : level < 30 ? .elevated : level < 40 ? .stress : .panic
    }

    var title: String {
        switch self {
        case .calm: "Calm"
        case .normal: "Normal"
        case .elevated: "Elevated"
        case .stress: "Stress"
        case .panic: "Panic"
        }
    }

    var range: ClosedRange<Double> {
        switch self {
        case .calm: 0...15
        case .normal: 15...20
        case .elevated: 20...30
        case .stress: 30...40
        case .panic: 40...100
        }
    }

    var rangeText: String {
        switch self {
        case .calm: "under 15"
        case .normal: "15–20"
        case .elevated: "20–30"
        case .stress: "30–40"
        case .panic: "40 and over"
        }
    }

    var meaning: String {
        switch self {
        case .calm: "Small daily moves expected; complacency is common near market highs."
        case .normal: "Around the long-run median: ordinary ups and downs."
        case .elevated: "Bigger swings expected — often after a sell-off or ahead of a known risk."
        case .stress: "Large daily moves; investors are paying up for protection."
        case .panic: "Crisis-level fear. Historically these readings came close to market lows."
        }
    }

    var color: Color {
        switch self {
        case .calm: .green
        case .normal: .teal
        case .elevated: .yellow
        case .stress: .orange
        case .panic: .red
        }
    }
}

/// A spike: the closes from the first above `threshold` until the VIX closed under 20 again.
nonisolated struct VIXSpike: Identifiable, Sendable {
    let began: Date
    let peakDate: Date
    let peak: Double
    /// The first close under 20 after the peak, and the trading days from the peak to it (nil: not yet).
    let backUnder20: Date?
    let tradingDays: Int?
    var id: Date { began }
}

nonisolated enum VIXStats {
    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/New_York")
        f.dateFormat = "MM/dd/yyyy"
        return f
    }()

    /// Cboe's history file: DATE,OPEN,HIGH,LOW,CLOSE with dates as MM/DD/YYYY, oldest first.
    static func parse(_ csv: String) -> [VIXPoint] {
        csv.split(whereSeparator: \.isNewline).dropFirst().compactMap { line in
            let f = line.split(separator: ",")
            guard f.count >= 5, let date = dateFormat.date(from: String(f[0])),
                  let o = Double(f[1]), let h = Double(f[2]), let l = Double(f[3]), let c = Double(f[4]), c > 0 else { return nil }
            return VIXPoint(date: date, open: o, high: h, low: l, close: c)
        }
    }

    /// Every spike above `threshold`: from its first close over it to the first close under 20 after the peak.
    static func spikes(_ points: [VIXPoint], threshold: Double = 35) -> [VIXSpike] {
        var spikes: [VIXSpike] = []
        var i = 0
        while i < points.count {
            guard points[i].close >= threshold else { i += 1; continue }
            let start = i
            var peak = i
            var j = i
            // The episode lasts until the VIX closes under 20.
            while j < points.count, points[j].close >= 20 {
                if points[j].close > points[peak].close { peak = j }
                j += 1
            }
            let back = j < points.count ? j : nil
            spikes.append(VIXSpike(began: points[start].date, peakDate: points[peak].date, peak: points[peak].close,
                                   backUnder20: back.map { points[$0].date }, tradingDays: back.map { $0 - peak }))
            i = j + 1
        }
        return spikes
    }

    /// The share of closes at or below `value`.
    static func percentile(_ value: Double, in closes: [Double]) -> Double {
        guard !closes.isEmpty else { return 0 }
        return Double(closes.filter { $0 <= value }.count) / Double(closes.count)
    }

    static func median(_ values: [Double]) -> Double {
        let s = values.sorted()
        guard !s.isEmpty else { return 0 }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// The S&P 500's typical one-month move (one standard deviation) the VIX implies: VIX / √12, in percent.
    static func monthlyMove(_ vix: Double) -> Double { vix / 12.0.squareRoot() }
    /// …and its typical daily move: VIX / √252 (the "rule of 16").
    static func dailyMove(_ vix: Double) -> Double { vix / 252.0.squareRoot() }
}

/// One file downloaded or read from the cache (a struct, not a tuple: concurrent children returning tuples lose their
/// results in this toolchain).
private nonisolated struct VIXFetch: Sendable {
    var series: VIXSeries
    var points: [VIXPoint]
    var fromCache: Bool
    var problem: String?
    var fromSecurityMaster = false
}

@MainActor
@Observable
final class VIXStore {
    static let shared = VIXStore()

    private(set) var series: [VIXSeries: [VIXPoint]] = [:]
    private(set) var loading = false
    private(set) var problem: String?
    /// When the data was read from Cboe (nil: from the copy kept on this Mac, or not yet).
    private(set) var fetchedAt: Date?
    private(set) var fromCache = false
    /// Read from the security master's copy rather than from Cboe.
    private(set) var fromSecurityMaster = false
    @ObservationIgnored private var lastLoad = Date.distantPast

    var vix: [VIXPoint] { series[.vix] ?? [] }

    /// Reads the four indexes from Cboe — at most once an hour unless `force` — or the copies kept on this Mac.
    func load(force: Bool = false) async {
        guard !loading, force || series.isEmpty || Date().timeIntervalSince(lastLoad) > 3600 else { return }
        loading = true
        problem = nil
        async let a = Self.fetch(.vix9d)
        async let b = Self.fetch(.vix)
        async let c = Self.fetch(.vix3m)
        async let d = Self.fetch(.vix6m)
        let results = await [a, b, c, d]
        for r in results where !r.points.isEmpty { series[r.series] = r.points }
        let failed = results.filter { $0.problem != nil }
        fromCache = results.contains { $0.fromCache }
        fromSecurityMaster = results.contains { $0.fromSecurityMaster }
        if (series[.vix] ?? []).isEmpty {
            problem = failed.first(where: { $0.series == .vix })?.problem ?? "No VIX data."
        } else if !failed.isEmpty {
            problem = "Cboe couldn't be reached; showing the copy kept on this Mac."
        }
        if failed.isEmpty { fetchedAt = Date() }
        lastLoad = Date()
        loading = false
    }

    private nonisolated static func cacheURL(_ s: VIXSeries) -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("\(s.rawValue)_History.csv")
    }

    private nonisolated static func fetch(_ s: VIXSeries) async -> VIXFetch {
        // The security master's copy first, when it has the last few trading days.
        if let text = await SecurityMasterSeries.csv([s.rawValue], format: "ohlc") {
            let points = VIXStats.parse(text)
            if SecurityMasterSeries.isCurrent(points.last?.date, days: 5) {
                if let url = cacheURL(s), let data = text.data(using: .utf8) { try? data.write(to: url, options: .atomic) }
                return VIXFetch(series: s, points: points, fromCache: false, fromSecurityMaster: true)
            }
        }
        var request = URLRequest(url: s.url, timeoutInterval: 30)
        request.setValue("MxAcctMGR (educational)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let text = String(data: data, encoding: .utf8) else {
                throw URLError(.badServerResponse)
            }
            let points = VIXStats.parse(text)
            guard !points.isEmpty else { throw URLError(.cannotParseResponse) }
            if let url = cacheURL(s) { try? data.write(to: url, options: .atomic) }
            return VIXFetch(series: s, points: points, fromCache: false)
        } catch {
            if let url = cacheURL(s), let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) {
                let points = VIXStats.parse(text)
                if !points.isEmpty { return VIXFetch(series: s, points: points, fromCache: true, problem: error.localizedDescription) }
            }
            return VIXFetch(series: s, points: [], fromCache: false, problem: "Cboe's \(s.rawValue) history couldn't be read: \(error.localizedDescription)")
        }
    }
}

// MARK: - The screen

struct VIXView: View {
    @Bindable var store: PortStore
    @State private var vixStore = VIXStore.shared
    @State private var period: Period = .oneYear
    @State private var spikeSelection = Set<VIXSpike.ID>()

    enum Period: String, CaseIterable, Identifiable {
        case oneMonth = "1M", sixMonths = "6M", oneYear = "1Y", fiveYears = "5Y", all = "Since 1990"
        var id: String { rawValue }
        var days: Int? {
            switch self {
            case .oneMonth: 31
            case .sixMonths: 183
            case .oneYear: 366
            case .fiveYears: 1827
            case .all: nil
            }
        }
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private static let spikesText = TableText<VIXSpike>(
        titles: ["Began", "Peak on", "Peak close", "Back under 20 on", "Trading days from peak"]) { s in
        [day.string(from: s.began), day.string(from: s.peakDate), String(format: "%.2f", s.peak),
         s.backUnder20.map { day.string(from: $0) } ?? "not yet", s.tradingDays.map(String.init) ?? "—"]
    }

    var body: some View {
        StepPage(store: store, subtitle: "The Cboe Volatility Index — the market's \"fear gauge\" — with real data from Cboe.", lesson: [
            "The VIX is the volatility the market expects for the S&P 500 over the next 30 days, worked out from S&P 500 option prices. It is quoted as an annual percentage: 20 means about a 5.8% move up or down in a typical month, about 1.3% in a day.",
            "It jumps when stocks fall fast and then drifts back. Every spike above 35 since 1990 came back under 20 — some within weeks, some only after a year or more.",
            "The highest readings came close to market lows, when selling felt most urgent. For a long-term plan the VIX explains why prices are swinging; it isn't a signal to change the plan.",
        ]) {
            if vixStore.vix.isEmpty {
                loadingBox
            } else {
                today
                history
                termStructure
                spikes
                reading
                sources
            }
        }
        .task { await vixStore.load() }
    }

    // MARK: Parts

    private var loadingBox: some View {
        Box(title: "VIX", symbol: "waveform.path.ecg.rectangle") {
            if vixStore.loading {
                HStack { ProgressView().controlSize(.small); Text("Reading the VIX history from Cboe…").foregroundStyle(.secondary) }
            } else {
                Text(vixStore.problem ?? "No data yet.").foregroundStyle(.secondary)
                Button("Try Again") { Task { await vixStore.load(force: true) } }
            }
        }
    }

    private var today: some View {
        let points = vixStore.vix
        let last = points.last!
        let previous = points.count > 1 ? points[points.count - 2].close : last.close
        let closes = points.map(\.close)
        let yearAgo = Calendar.current.date(byAdding: .day, value: -365, to: last.date)!
        let year = points.filter { $0.date >= yearAgo }.map(\.close)
        let regime = VIXRegime(last.close)
        return Box(title: "Today", symbol: "waveform.path.ecg.rectangle",
                   help: "The latest daily close, how it compares with every close since January 1990, and what it implies for the S&P 500.") {
            HStack(spacing: 10) {
                MetricTile(title: "VIX close · \(Self.day.string(from: last.date))", value: String(format: "%.2f", last.close),
                           caption: String(format: "%+.2f (%+.1f%%) from the day before", last.close - previous, (last.close / previous - 1) * 100),
                           tint: regime.color, help: "The VIX's closing level on its latest trading day, and the change from the close before.")
                MetricTile(title: "Regime", value: regime.title, caption: "\(regime.rangeText): \(regime.meaning)", tint: regime.color,
                           help: "Rough bands: under 15 calm, 15–20 normal, 20–30 elevated, 30–40 stress, 40 and over panic.")
                MetricTile(title: "Higher than", value: pct(VIXStats.percentile(last.close, in: closes), 0),
                           caption: "of all closes since 1990", help: "The share of daily closes since January 1990 at or below today's.")
                MetricTile(title: "52-week range", value: String(format: "%.1f – %.1f", year.min() ?? 0, year.max() ?? 0),
                           caption: "daily closes", help: "The lowest and highest close over the last year.")
                MetricTile(title: "Long-run average", value: String(format: "%.1f", closes.reduce(0, +) / Double(closes.count)),
                           caption: String(format: "median %.1f, since 1990", VIXStats.median(closes)),
                           help: "The average and the median close since January 1990. Spikes pull the average above the median.")
            }
            Text(String(format: "At %.1f the options market is pricing a typical S&P 500 move of about ±%.1f%% over the next month, ±%.1f%% in a day (one standard deviation: about two months in three stay within it).",
                        last.close, VIXStats.monthlyMove(last.close), VIXStats.dailyMove(last.close)))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let problem = vixStore.problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var shown: [VIXPoint] {
        let points = vixStore.vix
        guard let last = points.last else { return [] }
        guard let days = period.days else {
            // Since 1990: every fifth day is plenty for the shape (and keeps the chart quick).
            return points.enumerated().filter { $0.offset % 5 == 0 || $0.offset == points.count - 1 }.map(\.element)
        }
        let from = Calendar.current.date(byAdding: .day, value: -days, to: last.date)!
        return points.filter { $0.date >= from }
    }

    private var history: some View {
        let points = shown
        let top = max(40, (points.map(\.close).max() ?? 40) + 5)
        let average = vixStore.vix.map(\.close).reduce(0, +) / Double(max(vixStore.vix.count, 1))
        return Box(title: "History", symbol: "chart.xyaxis.line",
                   help: "Daily closes, with the regimes shaded and the long-run average dashed. Pick a period.") {
            Picker("Period", selection: $period) {
                ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420)
            Chart {
                ForEach(VIXRegime.allCases) { r in
                    RectangleMark(yStart: .value("From", r.range.lowerBound), yEnd: .value("To", min(r.range.upperBound, top)))
                        .foregroundStyle(r.color.opacity(0.09))
                }
                ForEach(points) { p in
                    LineMark(x: .value("Date", p.date), y: .value("VIX", p.close))
                        .foregroundStyle(.orange)
                        .interpolationMethod(.linear)
                }
                RuleMark(y: .value("Long-run average", average))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .leading) {
                        Text(String(format: "long-run average %.1f", average)).font(.caption2).foregroundStyle(.secondary)
                    }
            }
            .chartYScale(domain: 0...top)
            .chartYAxisLabel("VIX")
            .frame(height: 300)
            HStack(spacing: 12) {
                ForEach(VIXRegime.allCases) { r in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(r.color.opacity(0.35)).frame(width: 12, height: 9)
                        Text("\(r.title) \(r.rangeText)").font(.caption).foregroundStyle(.secondary)
                    }
                    .help(r.meaning)
                }
            }
        }
    }

    private var termStructure: some View {
        let latest = VIXSeries.allCases.compactMap { s in vixStore.series[s]?.last.map { (s, $0.close) } }
        let vix9d = vixStore.series[.vix9d]?.last?.close, vix3m = vixStore.series[.vix3m]?.last?.close
        let inverted = (vix9d ?? 0) > (vixStore.vix.last?.close ?? 0) || (vixStore.vix.last?.close ?? 0) > (vix3m ?? .infinity)
        return Box(title: "Term structure", symbol: "chart.line.uptrend.xyaxis",
                   help: "The volatility expected over 9 days, 30 days (the VIX), 3 months and 6 months, from the same S&P 500 options.") {
            HStack(alignment: .top, spacing: 16) {
                Chart(latest, id: \.0) { s, v in
                    LineMark(x: .value("Horizon", s.horizon), y: .value("Volatility", v)).foregroundStyle(.orange)
                    PointMark(x: .value("Horizon", s.horizon), y: .value("Volatility", v)).foregroundStyle(.orange)
                        .annotation(position: .top) { Text(String(format: "%.1f", v)).font(.caption2.monospacedDigit()) }
                }
                .chartYScale(domain: 0...max(30, (latest.map(\.1).max() ?? 30) + 5))
                .frame(width: 340, height: 170)
                SelectableText(text: {
                    var l = RichLines()
                    l.paragraph(inverted
                        ? "Inverted: near-term volatility is priced above longer-term. That is the shape of stress — the market expects the turbulence to be worst now and to ease later."
                        : "Upward sloping (contango): longer horizons are priced higher than the next few days. That is the usual shape in calm or ordinary markets.",
                        font: RichLines.calloutFont, spacing: 8)
                    l.paragraph("Most of the time the curve slopes upward; it inverts during sell-offs and returns to normal as they pass. The shape is about expectations, not a forecast of returns.",
                                font: RichLines.calloutFont, color: .secondaryLabelColor)
                    return l.result
                }())
            }
        }
    }

    private var spikes: some View {
        let rows = VIXStats.spikes(vixStore.vix).reversed().map { $0 }
        let median = VIXStats.median(rows.compactMap(\.tradingDays).map(Double.init))
        return Box(title: "Every spike above 35 since 1990", symbol: "bolt.heart",
                   help: "Each episode from its first close above 35 to the first close under 20 after its peak; trading days counted from the peak.") {
            Text(String(format: "%d spikes. From the peak the VIX took a median %.0f trading days (about %.0f months) to close under 20 again — and it always has.",
                        rows.count, median, median / 21))
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Table(rows, selection: $spikeSelection) {
                TableColumn("Began") { s in Text(Self.day.string(from: s.began)) }
                TableColumn("Peak on") { s in Text(Self.day.string(from: s.peakDate)) }
                TableColumn("Peak close") { s in Text(String(format: "%.2f", s.peak)).monospacedDigit().foregroundStyle(VIXRegime(s.peak).color) }
                TableColumn("Back under 20 on") { s in Text(s.backUnder20.map { Self.day.string(from: $0) } ?? "not yet") }
                TableColumn("Trading days from peak") { s in Text(s.tradingDays.map(String.init) ?? "—").monospacedDigit() }
            }
            .tableText()
            .copyRowsMenu(rows, as: Self.spikesText)
            .copiesSelectedRows(rows, selected: spikeSelection, as: Self.spikesText)
            .frame(minHeight: CGFloat(rows.count) * 24 + 34)
        }
    }

    private var reading: some View {
        Box(title: "Reading the VIX", symbol: "text.magnifyingglass", help: "What the number is and isn't.") {
            SelectableText(text: {
                var l = RichLines()
                l.bullets([
                    "It is a forecast of how much prices will move, in either direction — not of which way. A high VIX says big moves are expected, up and down.",
                    "Divide by 16 for the typical daily S&P 500 move (20 → about 1.25%), by 3.5 for the typical month (20 → about 5.8%).",
                    "It mean-reverts: very high readings don't last, and very low ones don't either. The median since 1990 is under 20.",
                    "Investors pay up for protection after a fall, so the VIX is usually highest near the bottom of a sell-off — the moment acting on fear does the most damage to a long-term plan.",
                    "You can't invest in the VIX itself; VIX futures and the funds built on them lose value over time in calm markets and are tools for traders, not for a long-term plan.",
                ], font: RichLines.calloutFont)
                return l.result
            }())
        }
    }

    private var sources: some View {
        Box(title: "Data", symbol: "arrow.up.right.square", help: "Where the numbers come from.") {
            SelectableText(text: {
                var l = RichLines()
                l.paragraph(vixStore.fetchedAt.map { "Daily closes from Cboe Global Markets" + (vixStore.fromSecurityMaster ? ", kept in the security master (MxDataHUB, srm.py load cboe-vix)" : "")
                                + ", read \(Self.day.string(from: $0)); the latest close is the last full trading day's." }
                            ?? "Daily closes from Cboe Global Markets (the copy kept on this Mac).",
                            font: RichLines.calloutFont, color: .secondaryLabelColor, spacing: 8)
                l.cells([
                    [RichLines.Cell(text: "Index", font: RichLines.captionFont, color: .secondaryLabelColor),
                     RichLines.Cell(text: "Cboe: VIX Index", font: RichLines.calloutFont, color: .linkColor, link: URL(string: "https://www.cboe.com/tradable_products/vix/"))],
                    [RichLines.Cell(text: "History", font: RichLines.captionFont, color: .secondaryLabelColor),
                     RichLines.Cell(text: "Cboe: VIX historical data", font: RichLines.calloutFont, color: .linkColor, link: URL(string: "https://www.cboe.com/tradable_products/vix/vix_historical_data/"))],
                    [RichLines.Cell(text: "Also", font: RichLines.captionFont, color: .secondaryLabelColor),
                     RichLines.Cell(text: "FRED: CBOE Volatility Index (VIXCLS)", font: RichLines.calloutFont, color: .linkColor, link: URL(string: "https://fred.stlouisfed.org/series/VIXCLS"))],
                ])
                return l.result
            }())
            HStack {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await vixStore.load(force: true) } }
                    .disabled(vixStore.loading)
                    .help("Read the latest closes again: from the security master when it is current, else from Cboe")
                if vixStore.loading { ProgressView().controlSize(.small) }
            }
        }
    }
}
