//
//  MarketMove.swift
//  MxAcctMGR
//
//  Today's Market Move (Investments ▸ Today's Market Move, under Morning Briefing; Reports ▸ Today's Market Move ⌥⌘T): a measured,
//  sector-first read of one trading day — what moved and how unusual it was, never why or what to do about it — from
//  the accounts service's GET /market/day (Services/accounts/market_move.py):
//
//    1. Breadth: how many stocks fell, up vs. down volume, new 52-week lows — a broad sell-off or a narrow one
//    2. Sectors: the 11 sector SPDRs' returns, relative volume, moves in their own volatility (z) and contributions to
//       the S&P 500's move; flagged only beyond both thresholds (Settings ▸ Market)
//    3. Concentration: cap- vs. equal-weighted, the ten largest contributors
//    4. Cross-asset: 2- and 10-year yields, the VIX, the dollar, oil, gold, credit — and the descriptive patterns a down
//       day resembles, with the conditions met
//    5. Style: growth vs. value, small vs. large, equal vs. cap weight
//    6. The noise filter's rules, as used
//    7. Your exposure: My Portfolio's funds through the ETFs tracking the same indexes, the U.S. stock fund's holdings
//       by sector
//
//  MarketMoveStore.shared keeps the latest day current while the app runs — every five minutes while the market is
//  open, every half hour otherwise — for the banner on the Investments pages (MarketMoveBanner) when the S&P 500's move
//  crosses Settings ▸ Market's thresholds.
//

import SwiftUI

// MARK: - The service's answer

nonisolated struct MarketDay: Decodable, Sendable {
    struct ETF: Decodable, Sendable, Hashable, Identifiable {
        var id: String { ticker }
        var ticker: String
        var name: String
        var close: Double?
        var previousClose: Double?
        var ret: Double?
        var z: Double?
        var relativeVolume: Double?
        var volume: Int?
    }

    struct Sector: Decodable, Sendable, Hashable, Identifiable {
        var id: String { ticker }
        var ticker: String
        var sector: String
        var ret: Double?
        var z: Double?
        var relativeVolume: Double?
        var weight: Double?
        var contribution: Double?
        var membersReturn: Double?
        var members: Int
        var down: Int
        var flagged: Bool
    }

    struct Count: Decodable, Sendable, Hashable {
        var up: Int
        var down: Int
        var unchanged: Int
        var stocks: Int
        var newLows: Int
        var newHighs: Int
        var closedBelowLow: Int
        var closedAboveHigh: Int
        var withYear: Int
        var downShare: Double?
        var upShare: Double?
        var downVolumeShare: Double?
        var upVolumeShare: Double?
    }

    struct SP500: Decodable, Sendable, Hashable {
        var members: Int
        var down: Int
        var up: Int
        var downShare: Double?
    }

    struct YearWindow: Decodable, Sendable, Hashable {
        var days: Int
        var securityMasterThrough: String?
        var daysFromMassive: Int
    }

    struct Breadth: Decodable, Sendable {
        var all: Count
        var nyse: Count
        var nasdaq: Count
        var sp500: SP500
        var reading: String
        var yearWindow: YearWindow
        enum CodingKeys: String, CodingKey { case all, nyse = "XNYS", nasdaq = "XNAS", sp500, reading, yearWindow }
    }

    struct Member: Decodable, Sendable, Hashable, Identifiable {
        var id: String { ticker }
        var ticker: String
        var name: String
        var sector: String
        var weight: Double
        var ret: Double
        var contribution: Double
    }

    struct Concentration: Decodable, Sendable {
        var capWeighted: Double?
        var equalWeighted: Double?
        var spread: Double?
        var membersMove: Double?
        var top: [Member]
        var topShare: Double?
        var weightsAsOf: String?
        var membersPriced: Int
    }

    struct YieldPoint: Decodable, Sendable, Hashable, Identifiable {
        var id: String { key }
        var maturity: String
        var key: String
        var yield: Double?
        var previous: Double?
        var changeBp: Double?
    }

    struct Yields: Decodable, Sendable {
        var available: Bool
        var source: String?
        var date: String?
        var previousDate: String?
        var curve: [YieldPoint]?
        var tenYearZ: Double?
        var note: String?

        func point(_ key: String) -> YieldPoint? { curve?.first { $0.key == key } }
    }

    struct VIX: Decodable, Sendable {
        var available: Bool
        var level: Double?
        var previous: Double?
        var change: Double?
        var z: Double?
        var regime: String?
        var previousRegime: String?
        var source: String?
    }

    struct CrossAsset: Decodable, Sendable {
        var yields: Yields
        var vix: VIX
        var assets: [ETF]
    }

    struct Spread: Decodable, Sendable, Hashable, Identifiable {
        var id: String { key }
        var key: String
        var name: String
        var long: String
        var short: String
        var spread: Double?
        var z: Double?
        var positiveMeans: String
    }

    struct Condition: Decodable, Sendable, Hashable {
        var text: String
        var met: Bool?
    }

    struct Pattern: Decodable, Sendable, Hashable, Identifiable {
        var id: String { name }
        var name: String
        var summary: String
        var conditions: [Condition]
        var met: Int
        var of: Int
        var resembles: Bool
    }

    struct History: Decodable, Sendable {
        var days: Int
        var asLarge: Int
        var lastAsLarge: String?
        var from: String?
    }

    struct Window: Decodable, Sendable {
        var days: Int
        var from: String?
        var to: String?
    }

    struct Thresholds: Decodable, Sendable {
        var sectorZ: Double
        var relativeVolume: Double
    }

    struct Holding: Decodable, Sendable, Hashable, Identifiable {
        var id: String { (ticker ?? "") + (name ?? "") }
        var ticker: String?
        var name: String?
        var value: Double
        var lookThrough: String?
        var proxy: String?
        var ret: Double?
        var change: Double?
        var kind: String?
        var lookThroughAsOf: String?
        var lookThroughPriced: Double?
    }

    struct ExposureSector: Decodable, Sendable, Hashable, Identifiable {
        var id: String { sector }
        var sector: String
        var us: Double
        var intl: Double
        var usChange: Double
        var usCovered: Double
        var total: Double
    }

    struct Exposure: Decodable, Sendable {
        var account: String
        var name: String?
        var value: Double?
        var cash: Double?
        var change: Double?
        var ret: Double?
        var pricedThrough: String?
        var holdings: [Holding]?
        var sectors: [ExposureSector]?
        var unpriced: [String]?
        var problem: String?
    }

    var date: String
    var previousDate: String?
    var nextDate: String?
    var live: Bool
    var session: String
    var asOf: String
    var delayedMinutes: Int
    var indexes: [ETF]
    var history: History
    var breadth: Breadth
    var sectors: [Sector]
    var concentration: Concentration
    var crossAsset: CrossAsset
    var spreads: [Spread]
    var patterns: [Pattern]
    var baseline: Window
    var thresholds: Thresholds
    var notes: [String]
    var exposure: Exposure?
    var sources: [String]
    var seconds: Double?

    var spy: ETF? { indexes.first { $0.ticker == "SPY" } }
    var falling: Bool { (spy?.ret ?? 0) < 0 }

    /// The share of stocks, and of volume, on the side the index moved.
    var sideShare: Double? { falling ? breadth.all.downShare : breadth.all.upShare }
    var sideVolumeShare: Double? { falling ? breadth.all.downVolumeShare : breadth.all.upVolumeShare }
}

// MARK: - Reading it from the accounts service

nonisolated enum MarketMoveClient {
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// "return" is a Swift keyword: the models call it `ret`.
    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .custom { path in
            let key = path.last!.stringValue
            return Key(stringValue: key == "return" ? "ret" : key)
        }
        return d
    }

    static func day(_ date: String?, sectorZ: Double, relativeVolume: Double) async throws -> MarketDay {
        var parts = ["sectorZ=\(sectorZ)", "relativeVolume=\(relativeVolume)"]
        if let date { parts.append("date=\(date)") }
        let url = URL(string: AccountsClient.base + "/market/day?" + parts.joined(separator: "&"))!
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 600))
        } catch {
            throw ServiceClient.Failure.notRunning(AccountsClient.service)
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let error = json["error"] as? String {
            if error.hasPrefix("no such endpoint") {
                throw ServiceClient.Failure.rejected("The accounts service has no market read yet — restart it: python3 Services/mxservices.py restart accounts")
            }
            throw ServiceClient.Failure.rejected(error)
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ServiceClient.Failure.rejected("The accounts service answered HTTP \(http.statusCode).")
        }
        do {
            return try decoder().decode(MarketDay.self, from: data)
        } catch {
            throw ServiceClient.Failure.rejected("The market read couldn't be read: \(error)")
        }
    }
}

// MARK: - Settings ▸ Market

@MainActor
@Observable
final class MarketMoveSettings {
    static let shared = MarketMoveSettings()

    /// The S&P 500's day move (a fraction) that shows the banner, and the one that makes it red.
    var notable: Double { didSet { save("marketMoveNotable", notable) } }
    var major: Double { didSet { save("marketMoveMajor", major) } }
    /// A sector is flagged only beyond both.
    var sectorZ: Double { didSet { save("marketMoveSectorZ", sectorZ) } }
    var relativeVolume: Double { didSet { save("marketMoveRelativeVolume", relativeVolume) } }
    var showsBanner: Bool { didSet { UserDefaults.standard.set(showsBanner, forKey: "marketMoveBanner") } }

    static let standard = (notable: 0.01, major: 0.02, sectorZ: 1.5, relativeVolume: 1.5)

    private init() {
        let d = UserDefaults.standard
        notable = d.object(forKey: "marketMoveNotable") as? Double ?? Self.standard.notable
        major = d.object(forKey: "marketMoveMajor") as? Double ?? Self.standard.major
        sectorZ = d.object(forKey: "marketMoveSectorZ") as? Double ?? Self.standard.sectorZ
        relativeVolume = d.object(forKey: "marketMoveRelativeVolume") as? Double ?? Self.standard.relativeVolume
        showsBanner = d.object(forKey: "marketMoveBanner") as? Bool ?? true
    }

    private func save(_ key: String, _ value: Double) { UserDefaults.standard.set(value, forKey: key) }

    func restore() {
        (notable, major, sectorZ, relativeVolume) = Self.standard
        showsBanner = true
    }

    enum Level { case notable, major }

    /// How big the day is by these thresholds: major past `major`, or past `notable` with breadth of 80% or more on
    /// the index's side or a 2.5σ index move; notable past `notable`, a VIX up 20% or more, or a 10-bp 10-year move.
    func level(_ d: MarketDay) -> Level? {
        let move = abs(d.spy?.ret ?? 0), z = abs(d.spy?.z ?? 0)
        if move >= major || (move >= notable && ((d.sideShare ?? 0) >= 0.8 || z >= 2.5)) { return .major }
        if move >= notable || (d.crossAsset.vix.change ?? 0) >= 0.2
            || abs(d.crossAsset.yields.point("year10")?.changeBp ?? 0) >= 10 { return .notable }
        return nil
    }
}

struct MarketMoveSettingsView: View {
    @Bindable private var settings = MarketMoveSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle("Show the banner on the Investments pages", isOn: $settings.showsBanner)
                LabeledContent("Notable move") { percentField($settings.notable) }
                LabeledContent("Major move") { percentField($settings.major) }
            } header: {
                Text("Today's Market Move ▸ Banner")
            } footer: {
                Text("The banner shows when the S&P 500 moves by the notable amount or more in a day, or the VIX rises 20% or more, or the 10-year yield moves 10 basis points. It turns red past the major amount, or past the notable amount with 80% or more of stocks moving the same way. It closes for the day with its ✕.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Move in its own volatility (|z|) of at least") {
                    Stepper(String(format: "%.1fσ", settings.sectorZ), value: $settings.sectorZ, in: 0.5...5, step: 0.1)
                }
                LabeledContent("Volume against its 20-day average of at least") {
                    Stepper(String(format: "%.1f×", settings.relativeVolume), value: $settings.relativeVolume, in: 0.5...5, step: 0.1)
                }
            } header: {
                Text("Today's Market Move ▸ Noise filter")
            } footer: {
                Text("A sector is flagged only when both are true: an unusual move for that sector on heavy volume. The others are listed plainly.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Restore Defaults") { settings.restore() }
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.sectorZ) { MarketMoveStore.shared.thresholdsChanged() }
        .onChange(of: settings.relativeVolume) { MarketMoveStore.shared.thresholdsChanged() }
    }

    private func percentField(_ value: Binding<Double>) -> some View {
        Stepper(String(format: "%.1f%% in a day", value.wrappedValue * 100), value: value, in: 0.0025...0.1, step: 0.0025)
    }
}

// MARK: - The store

@MainActor
@Observable
final class MarketMoveStore {
    static let shared = MarketMoveStore()

    /// Today's read once the market has opened, else the last trading day's: the banner's and the screen's default.
    private(set) var latest: MarketDay?
    private(set) var latestProblem: String?
    private(set) var latestUpdated: Date?
    /// The day the screen shows when it isn't the latest.
    private(set) var picked: String?
    private(set) var pickedDay: MarketDay?
    private(set) var pickedProblem: String?
    private(set) var loading = false
    /// The day whose banner was closed (✕).
    var dismissed: String? = UserDefaults.standard.string(forKey: "marketMoveDismissed") {
        didSet { UserDefaults.standard.set(dismissed, forKey: "marketMoveDismissed") }
    }

    private var poller: Task<Void, Never>?

    private init() {}

    var shown: MarketDay? { picked == nil ? latest : pickedDay }
    var problem: String? { picked == nil ? latestProblem : pickedProblem }

    /// Keeps the latest day current while the app runs: every five minutes while the market is open, every half hour
    /// otherwise, ten minutes after a failure.
    func start() {
        guard poller == nil else { return }
        poller = Task {
            while !Task.isCancelled {
                await refreshLatest()
                let wait: Double = latestProblem != nil ? 600 : (latest?.live == true && latest?.session == "open") ? 300 : 1800
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    /// Reads the latest day; callers that ask while a read is under way wait for that one.
    func refreshLatest() async {
        if let reading { return await reading.value }
        let task = Task {
            let s = MarketMoveSettings.shared
            loading = picked == nil
            defer { loading = false }
            do {
                latest = try await MarketMoveClient.day(nil, sectorZ: s.sectorZ, relativeVolume: s.relativeVolume)
                latestProblem = nil
                latestUpdated = Date()
            } catch {
                latestProblem = error.localizedDescription
            }
        }
        reading = task
        await task.value
        reading = nil
    }
    private var reading: Task<Void, Never>?

    /// Shows a day (nil: the latest).
    func pick(_ date: String?) async {
        if date == nil || date == latest?.date {
            picked = nil
            if latest == nil { await refreshLatest() }
            return
        }
        picked = date
        pickedDay = nil
        pickedProblem = nil
        loading = true
        defer { loading = false }
        let s = MarketMoveSettings.shared
        do {
            let day = try await MarketMoveClient.day(date, sectorZ: s.sectorZ, relativeVolume: s.relativeVolume)
            guard picked == date else { return }
            if day.date == latest?.date { picked = nil; latest = day } else { pickedDay = day; picked = day.date }
        } catch {
            guard picked == date else { return }
            pickedProblem = error.localizedDescription
        }
    }

    func refresh() async {
        if let picked { await pick(picked) } else { await refreshLatest() }
    }

    func thresholdsChanged() {
        Task {
            await reading?.value      // a read under way has the old thresholds: read again after it
            await refreshLatest()
            if let picked { await pick(picked) }
        }
    }
}

// MARK: - Formatting

nonisolated enum MoveFormat {
    private static let eastern = TimeZone(identifier: "America/New_York")!
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = eastern
        f.dateFormat = format
        return f
    }
    private static let day = formatter("yyyy-MM-dd")
    private static let long = formatter("EEEE, MMMM d, yyyy")
    private static let short = formatter("MMM d, yyyy")
    private static let clock = formatter("h:mm a")

    static func longDay(_ s: String) -> String { day.date(from: s).map { long.string(from: $0) } ?? s }
    static func shortDay(_ s: String) -> String { day.date(from: s).map { short.string(from: $0) } ?? s }
    static func date(_ s: String) -> Date? { day.date(from: s) }
    static func string(_ d: Date) -> String { day.string(from: d) }
    static func time(_ iso: String) -> String {
        guard let d = try? Date(iso, strategy: .iso8601) else { return iso }
        return clock.string(from: d) + " ET"
    }

    static func r(_ x: Double?, _ digits: Int = 2) -> String { x.map { signedPct($0, digits) } ?? "—" }
    static func share(_ x: Double?) -> String { x.map { pct($0, 0) } ?? "—" }
    static func z(_ x: Double?) -> String { x.map { String(format: "%+.1fσ", $0) } ?? "—" }
    static func rv(_ x: Double?) -> String { x.map { String(format: "%.1f×", $0) } ?? "—" }
    /// Percentage points of the index's move.
    static func pts(_ x: Double?) -> String { x.map { String(format: "%+.2f pts", $0 * 100) } ?? "—" }
    static func bp(_ x: Double?) -> String { x.map { String(format: "%+.0f bp", $0) } ?? "—" }
    static func dollars(_ x: Double?) -> String {
        guard let x else { return "—" }
        return (x > 0 ? "+" : x < 0 ? "−" : "") + money(abs(x)).replacingOccurrences(of: ".00", with: "")
    }
    static func whole(_ x: Double) -> String { money(x).components(separatedBy: ".")[0] }
}

// MARK: - The banner on the Investments pages

struct MarketMoveBanner: View {
    @Bindable var store: PortStore
    private var move = MarketMoveStore.shared
    private var settings = MarketMoveSettings.shared

    init(store: PortStore) { self.store = store }

    var body: some View {
        if settings.showsBanner, let d = move.latest, move.dismissed != d.date, let level = settings.level(d) {
            let tint: Color = level == .major ? .red : .orange
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: d.falling ? "arrow.down.right.circle.fill" : "arrow.up.right.circle.fill").foregroundStyle(tint)
                Text(summary(d)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Read the Move") { store.go(.marketMove) }
                    .help("Open Today's Market Move: breadth, sectors, concentration, cross-asset, style and your exposure, measured")
                Button { move.dismissed = d.date } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Close the banner for \(MoveFormat.shortDay(d.date))")
            }
            .font(.callout)
            .padding(10)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tint.opacity(0.4)))
            .quickHelpArea(QuickHelpItem(title: "Today's Market Move", detail: "A large move by Settings ▸ Market's thresholds: the S&P 500's move and how unusual it is, how many stocks moved with it, the sectors flagged by the noise filter and your account's estimated change. Read the Move opens the measured read; ✕ closes the banner for the day.", symbol: "chart.line.downtrend.xyaxis"))
        }
    }

    private func summary(_ d: MarketDay) -> String {
        var parts: [String] = []
        let when = d.live ? (d.session == "open" ? "today so far" : "today") : "on " + MoveFormat.shortDay(d.date)
        parts.append("S&P 500 \(MoveFormat.r(d.spy?.ret, 1)) \(when) (\(MoveFormat.z(d.spy?.z)))")
        if let s = d.sideShare { parts.append("\(MoveFormat.share(s)) of stocks \(d.falling ? "down" : "up")") }
        let flagged = d.sectors.filter(\.flagged).map(\.sector)
        if !flagged.isEmpty {
            parts.append(flagged.count > 3 ? "\(flagged.count) sectors flagged" : flagged.joined(separator: ", ") + " flagged")
        }
        if let e = d.exposure, let c = e.change, let r = e.ret { parts.append("your account ≈ \(MoveFormat.dollars(c)) (\(MoveFormat.r(r, 1)))") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - The screen

struct MarketMoveView: View {
    @Bindable var store: PortStore
    private var move = MarketMoveStore.shared
    @State private var pickerDate = Date()

    init(store: PortStore) { self.store = store }

    var body: some View {
        StepPage(store: store, subtitle: "One trading day measured: what moved, how broadly, which sectors, and how unusual it was against each one's own recent history — with your account's exposure.", lessonTitle: "Reading a big day", lesson: [
            "Start with breadth. When 80–90% of stocks fall on heavy volume, the selling is broad; when the index falls but most stocks hold up, a few large companies are doing most of it.",
            "Then the sectors, in their own terms. A 2% drop is ordinary for semiconductors and rare for utilities, so each sector's move is divided by its own recent volatility (z), and only unusual moves on heavy volume are flagged.",
            "Cross-asset moves tell different kinds of days apart: rising yields hit bonds and long-duration stocks together; a flight to safety sends yields down and gold up while defensive sectors hold; across-the-board selling takes even the shelters down. These are descriptions of what moved together, not causes.",
            "Days like this are part of owning stocks. The page reports what moved and by how much; it doesn't say what will happen next or what to do.",
        ]) {
            controls
            if let d = move.shown {
                if !d.notes.isEmpty {
                    Text(d.notes.joined(separator: " ")).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                headline(d)
                breadth(d)
                sectors(d)
                concentration(d)
                crossAsset(d)
                style(d)
                noiseFilter(d)
                exposure(d)
                sources(d)
            } else {
                Box(title: "Today's Market Move", symbol: "chart.line.downtrend.xyaxis") {
                    if let problem = move.problem {
                        Text(problem).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Try Again") { Task { await move.refresh() } }
                    } else {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Reading the day from Massive and the security master… The first read of a day downloads its history and can take a minute.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .task {
            if let date = UserDefaults.standard.string(forKey: "marketDate"), move.picked == nil, move.pickedDay == nil {
                await move.pick(date)
            } else if move.latest == nil {
                await move.refreshLatest()
            }
            MarketMoveStore.shared.start()
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 10) {
            let d = move.shown
            Button { if let p = d?.previousDate { Task { await move.pick(p) } } } label: { Image(systemName: "chevron.left") }
                .disabled(d?.previousDate == nil || move.loading)
                .help("The trading day before")
            Text(d.map { MoveFormat.longDay($0.date) } ?? "—").heading(.name)
            Button { if let n = d?.nextDate { Task { await move.pick(n) } } } label: { Image(systemName: "chevron.right") }
                .disabled(d?.nextDate == nil || move.loading)
                .help("The trading day after")
            Button("Latest") { Task { await move.pick(nil) } }
                .disabled(move.picked == nil || move.loading)
                .help("Today once the market has opened, else the last trading day")
            DatePicker("", selection: $pickerDate, in: ...Date(), displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.field)
                .frame(width: 110)
                .help("Any trading day in the last two years (the trading day before, if it wasn't one)")
                .onSubmit { Task { await move.pick(MoveFormat.string(pickerDate)) } }
            Button("Show") { Task { await move.pick(MoveFormat.string(pickerDate)) } }
                .disabled(move.loading)
            Spacer()
            if move.loading { ProgressView().controlSize(.small) }
            if let d {
                Text(d.live ? "As of \(MoveFormat.time(d.asOf)) · quotes \(d.delayedMinutes) min delayed" + (d.session == "open" ? " · market open" : "")
                     : "At the close")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await move.refresh() } }
                .disabled(move.loading)
                .help("Read the day again (today's read also refreshes every five minutes while the market is open)")
        }
    }

    // MARK: The move

    private func headline(_ d: MarketDay) -> some View {
        Box(title: "The move", symbol: "chart.xyaxis.line", help: "The major indexes through the ETFs that track them: each day's return, the move in its own 20-day volatility (z), and volume against its 20-day average.") {
            HStack(spacing: 10) {
                MetricTile(title: "S&P 500 (SPY)", value: MoveFormat.r(d.spy?.ret), caption: "\(MoveFormat.z(d.spy?.z)) · volume \(MoveFormat.rv(d.spy?.relativeVolume))",
                           tint: Color.signed(d.spy?.ret ?? 0), help: "SPY's return from the previous close, the move divided by its own 20-day volatility, and its volume against its 20-day average.")
                MetricTile(title: "Stocks \(d.falling ? "down" : "up")", value: MoveFormat.share(d.sideShare), caption: "\(MoveFormat.share(d.sideVolumeShare)) of volume · \(d.breadth.reading.components(separatedBy: ":")[0])",
                           tint: .primary, help: "The share of U.S.-listed stocks (common stocks, REITs, ADRs) that moved with the index, and the share of their volume.")
                if let top = d.sectors.first {
                    MetricTile(title: "Largest sector contribution", value: top.sector, caption: "\(MoveFormat.pts(top.contribution)) of the S&P 500's \(MoveFormat.pts(d.concentration.membersMove))",
                               tint: Color.signed(top.contribution ?? 0), help: "The sector whose members added most to the S&P 500's move: each member's weight at the previous close times its return.")
                }
                MetricTile(title: "VIX", value: d.crossAsset.vix.level.map { String(format: "%.1f", $0) } ?? "—",
                           caption: "\(MoveFormat.r(d.crossAsset.vix.change, 0)) · \(d.crossAsset.vix.regime ?? "")", tint: .orange,
                           help: "The Cboe Volatility Index: the S&P 500's expected volatility over 30 days, from option prices, and its regime.")
                if let e = d.exposure, let c = e.change {
                    MetricTile(title: "Your account (estimate)", value: MoveFormat.dollars(c), caption: MoveFormat.r(e.ret),
                               tint: Color.signed(c), help: "\(e.name ?? e.account)'s holdings at their latest prices, each moved by its own return or its fund's tracking ETF's. An estimate: the funds' own prices come at the end of the day.")
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
                GridRow {
                    ForEach(["Index", "ETF", "Return", "z", "Volume vs. 20-day"], id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
                ForEach(d.indexes) { i in
                    GridRow {
                        Text(i.name)
                        Text(i.ticker).foregroundStyle(.secondary)
                        Text(MoveFormat.r(i.ret)).monospacedDigit().foregroundStyle(Color.signed(i.ret ?? 0))
                        Text(MoveFormat.z(i.z)).monospacedDigit()
                        Text(MoveFormat.rv(i.relativeVolume)).monospacedDigit()
                    }
                }
            }
            .font(.callout)
            Text(historyLine(d)).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func historyLine(_ d: MarketDay) -> String {
        let h = d.history
        let verb = d.falling ? "fell" : "rose"
        let since = h.from.map { " since \(MoveFormat.shortDay($0))" } ?? ""
        if h.asLarge == 0 {
            return "SPY hadn't \(d.falling ? "fallen" : "risen") this much in a day in the \(h.days) trading days\(since)."
        }
        return "SPY \(verb) this much or more on \(h.asLarge) of the \(h.days) trading days\(since)"
            + (h.lastAsLarge.map { "; the last time was \(MoveFormat.shortDay($0))." } ?? ".")
    }

    // MARK: 1. Breadth

    private func breadth(_ d: MarketDay) -> some View {
        let b = d.breadth
        return Box(title: "1. Breadth: broad, or a few large stocks?", symbol: "chart.bar.xaxis", help: "How many stocks rose and fell, and their volume: computed from every U.S.-listed common stock, REIT and ADR that traded (Massive's bars), not the exchanges' official statistics. New 52-week lows and highs use each day's low and high against the 251 trading days before; 'closed beyond' counts those that ended the day there.") {
            Text(breadthLine(d)).font(.callout).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
                GridRow {
                    ForEach(["", "Stocks", "Down", "Up", "Volume in decliners", "New 52-week lows", "closed below", "New 52-week highs", "closed above"], id: \.self) {
                        Text($0).font(.caption).foregroundStyle(.secondary)
                    }
                }
                breadthRow("All U.S.-listed stocks", b.all)
                breadthRow("NYSE-listed", b.nyse)
                breadthRow("Nasdaq-listed", b.nasdaq)
                GridRow {
                    Text("S&P 500 members")
                    Text("\(b.sp500.members)").monospacedDigit()
                    Text(MoveFormat.share(b.sp500.downShare)).monospacedDigit()
                    Text(MoveFormat.share(b.sp500.members > 0 ? Double(b.sp500.up) / Double(b.sp500.members) : nil)).monospacedDigit()
                    Text("—").foregroundStyle(.secondary)
                    Text("")
                    Text("")
                    Text("")
                    Text("")
                }
            }
            .font(.callout)
            Text("How to read it: 80% or more of stocks down with 90% or more of volume in decliners is a broad sell-off (a \"90% down day\"); an index down 1% or more with under 60% of its members down is narrow — a few large companies doing most of it. New highs can appear on a down day when stocks open at a high and fall from there.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func breadthRow(_ title: String, _ c: MarketDay.Count) -> some View {
        GridRow {
            Text(title)
            Text("\(c.stocks)").monospacedDigit()
            Text(MoveFormat.share(c.downShare)).monospacedDigit()
            Text(MoveFormat.share(c.upShare)).monospacedDigit()
            Text(MoveFormat.share(c.downVolumeShare)).monospacedDigit()
            Text("\(c.newLows)").monospacedDigit()
            Text("\(c.closedBelowLow)").monospacedDigit().foregroundStyle(.secondary)
            Text("\(c.newHighs)").monospacedDigit()
            Text("\(c.closedAboveHigh)").monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private func breadthLine(_ d: MarketDay) -> String {
        let a = d.breadth.all
        let side = d.falling ? "down" : "up"
        var s = "\(MoveFormat.share(d.sideShare)) of \(a.stocks) stocks \(d.falling ? "fell" : "rose"), with \(MoveFormat.share(d.sideVolumeShare)) of their volume; "
        s += "\(MoveFormat.share(d.falling ? d.breadth.sp500.downShare : 1 - (d.breadth.sp500.downShare ?? 0))) of S&P 500 members were \(side). "
        s += "Reading: \(d.breadth.reading)."
        return s
    }

    // MARK: 2. Sectors

    private func sectors(_ d: MarketDay) -> some View {
        Box(title: "2. Sectors, in their own terms", symbol: "square.grid.3x3", help: "The 11 Select Sector SPDRs: return, the move divided by the sector's own 20-day volatility (z), volume against its 20-day average (during the session, against the share of a day's volume normally traded by now), and the sector's contribution to the S&P 500's move — its members' weights at the previous close times their returns, by the security master's (FMP's) sectors. Flagged: both thresholds met.") {
            Text(sectorLine(d)).font(.callout).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                GridRow {
                    ForEach(["", "Sector", "ETF", "Return", "z", "Volume vs. 20-day", "Weight in S&P 500", "Contribution", "Members down"], id: \.self) {
                        Text($0).font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(d.sectors) { s in
                    GridRow {
                        Image(systemName: s.flagged ? "flag.fill" : "circle").font(.caption2)
                            .foregroundStyle(s.flagged ? Color.orange : Color.secondary.opacity(0.4))
                            .help(s.flagged ? "Flagged: an unusual move for this sector on heavy volume" : "Not flagged")
                        Text(s.sector).fontWeight(s.flagged ? .semibold : .regular)
                        Text(s.ticker).foregroundStyle(.secondary)
                        Text(MoveFormat.r(s.ret)).monospacedDigit().foregroundStyle(Color.signed(s.ret ?? 0))
                        Text(MoveFormat.z(s.z)).monospacedDigit()
                        Text(MoveFormat.rv(s.relativeVolume)).monospacedDigit()
                        Text(MoveFormat.share(s.weight)).monospacedDigit()
                        Text(MoveFormat.pts(s.contribution)).monospacedDigit().foregroundStyle(Color.signed(s.contribution ?? 0))
                        Text("\(s.down) of \(s.members)").monospacedDigit().foregroundStyle(.secondary)
                    }
                    .foregroundStyle(s.flagged ? Color.primary : Color.secondary)
                }
            }
            .font(.callout)
            HBars(series: [.init(name: "Contribution to the S&P 500 (points)", color: .accentColor)],
                  rows: d.sectors.map { HBars.Row(label: $0.sector, values: [($0.contribution ?? 0) * 100], colors: [Color.signed($0.contribution ?? 0)]) },
                  unit: " pts", labelWidth: 170)
            Text("Flagged: |z| ≥ \(String(format: "%.1f", d.thresholds.sectorZ)) and volume ≥ \(String(format: "%.1f", d.thresholds.relativeVolume))× its 20-day average (Settings ▸ Market). Contributions add each member's weight × return; a sector ETF caps its largest names, so its return can differ from its members'.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sectorLine(_ d: MarketDay) -> String {
        let flagged = d.sectors.filter(\.flagged)
        let total = d.concentration.membersMove ?? 0
        var s = flagged.isEmpty ? "No sector moved unusually on heavy volume. "
            : "\(flagged.count) of 11 sectors flagged: \(flagged.map(\.sector).joined(separator: ", ")). "
        if let top = d.sectors.first, let c = top.contribution, abs(total) > 0.001 {
            s += "\(top.sector) contributed \(MoveFormat.pts(c)) of the S&P 500's \(MoveFormat.pts(total)) (\(pct(c / total, 0)))."
        }
        return s
    }

    // MARK: 3. Concentration

    private func concentration(_ d: MarketDay) -> some View {
        let c = d.concentration
        return Box(title: "3. Concentration", symbol: "chart.pie", help: "The cap-weighted S&P 500 (SPY) against the equal-weighted (RSP): when the cap-weighted index falls more, the largest companies led. The ten members that contributed most in the index's direction, with their weight at the previous close.") {
            HStack(spacing: 10) {
                MetricTile(title: "Cap-weighted (SPY)", value: MoveFormat.r(c.capWeighted), tint: Color.signed(c.capWeighted ?? 0), help: "The S&P 500 as it's usually quoted: each company by its market value.")
                MetricTile(title: "Equal-weighted (RSP)", value: MoveFormat.r(c.equalWeighted), tint: Color.signed(c.equalWeighted ?? 0), help: "Every S&P 500 company at the same weight: the average stock.")
                MetricTile(title: "Equal − cap", value: MoveFormat.r(c.spread), caption: (c.spread ?? 0) > 0 ? "the largest stocks did worse" : "the largest stocks did better", help: "Positive: the average stock beat the index, so the largest companies pulled it.")
                if let share = c.topShare, abs(c.membersMove ?? 0) >= 0.005 {
                    MetricTile(title: "Ten largest contributors", value: pct(share, 0), caption: "of the index's move", help: "The ten members below added together, as a share of the S&P 500's move from all its members.")
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                GridRow {
                    ForEach(["Ticker", "Company", "Sector", "Weight", "Return", "Contribution"], id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
                ForEach(c.top) { m in
                    GridRow {
                        Text(m.ticker).fontWeight(.semibold)
                        Text(m.name).lineLimit(1)
                        Text(m.sector).foregroundStyle(.secondary)
                        Text(pct(m.weight, 2)).monospacedDigit()
                        Text(MoveFormat.r(m.ret)).monospacedDigit().foregroundStyle(Color.signed(m.ret))
                        Text(MoveFormat.pts(m.contribution)).monospacedDigit().foregroundStyle(Color.signed(m.contribution))
                    }
                }
            }
            .font(.callout)
            Text("Weights: SPY's holdings on \(c.weightsAsOf.map(MoveFormat.shortDay) ?? "—") (State Street, in the security master), \(c.membersPriced) members priced.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: 4. Cross-asset

    private func crossAsset(_ d: MarketDay) -> some View {
        let y = d.crossAsset.yields, v = d.crossAsset.vix
        return Box(title: "4. Cross-asset context", symbol: "arrow.triangle.branch", help: "Rates, volatility, the dollar, commodities and credit on the same day: they tell a rate-driven day from a flight to safety, a commodity shock or across-the-board selling.") {
            HStack(spacing: 10) {
                ForEach(["year2", "year10"], id: \.self) { key in
                    let p = y.point(key)
                    MetricTile(title: "\(p?.maturity ?? key) Treasury", value: p?.yield.map { String(format: "%.2f%%", $0) } ?? "—",
                               caption: MoveFormat.bp(p?.changeBp) + (key == "year10" ? " · \(MoveFormat.z(y.tenYearZ))" : ""),
                               tint: .primary, help: "The Treasury's daily par yield and its change from the trading day before, in basis points (1 bp = 0.01%).")
                }
                MetricTile(title: "VIX", value: v.level.map { String(format: "%.1f", $0) } ?? "—",
                           caption: "from \(v.previous.map { String(format: "%.1f", $0) } ?? "—") · \(MoveFormat.r(v.change, 0)) · \(MoveFormat.z(v.z))",
                           tint: .orange, help: "The VIX, its close the day before, its daily change and that change in its own 20-day volatility. Regime: \(v.regime ?? "—") (calm under 15, normal 15–20, elevated 20–30, stress 30–40, panic 40+).")
            }
            if let note = y.note { Text(note).font(.caption).foregroundStyle(.secondary) }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                GridRow {
                    ForEach(["Asset", "ETF", "Return", "z", "Volume vs. 20-day"], id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
                ForEach(d.crossAsset.assets) { a in
                    GridRow {
                        Text(a.name)
                        Text(a.ticker).foregroundStyle(.secondary)
                        Text(MoveFormat.r(a.ret)).monospacedDigit().foregroundStyle(Color.signed(a.ret ?? 0))
                        Text(MoveFormat.z(a.z)).monospacedDigit()
                        Text(MoveFormat.rv(a.relativeVolume)).monospacedDigit()
                    }
                }
            }
            .font(.callout)
            patterns(d)
        }
    }

    @ViewBuilder
    private func patterns(_ d: MarketDay) -> some View {
        Divider()
        Text("Which pattern the day resembles").heading(.subheading)
        if d.patterns.isEmpty {
            Text("The patterns describe down days; the S&P 500 rose on this one.").font(.callout).foregroundStyle(.secondary)
        } else {
            let resembles = d.patterns.filter(\.resembles).map(\.name)
            Text(resembles.isEmpty ? "None of the five clearly: the conditions each meets are below."
                 : "It resembles \(resembles.joined(separator: " and ")). That describes what moved together; it doesn't say what caused it.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            AdaptiveColumns(minimum: 340, spacing: 12, rowSpacing: 12) {
                ForEach(d.patterns) { p in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(p.name).fontWeight(.semibold)
                            Spacer()
                            Text("\(p.met) of \(p.of)").monospacedDigit()
                                .foregroundStyle(p.resembles ? Color.orange : Color.secondary)
                        }
                        Text(p.summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        ForEach(p.conditions, id: \.self) { c in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: c.met == true ? "checkmark.circle.fill" : c.met == false ? "circle" : "questionmark.circle")
                                    .foregroundStyle(c.met == true ? Color.orange : Color.secondary)
                                Text(c.text).font(.caption).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(10)
                    .background((p.resembles ? Color.orange : Color.secondary).opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    // MARK: 5. Style

    private func style(_ d: MarketDay) -> some View {
        Box(title: "5. Style rotation", symbol: "arrow.left.arrow.right.square", help: "Return differences between pairs of ETFs, and each difference in its own 20-day volatility: growth vs. value (IWF − IWD), small vs. large (IWM − SPY), equal vs. cap weight (RSP − SPY), and credit (HYG against IEF and LQD).") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                GridRow {
                    ForEach(["Pair", "ETFs", "Difference", "z", "Positive means"], id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
                ForEach(d.spreads) { s in
                    GridRow {
                        Text(s.name)
                        Text("\(s.long) − \(s.short)").foregroundStyle(.secondary)
                        Text(MoveFormat.r(s.spread)).monospacedDigit().foregroundStyle(Color.signed(s.spread ?? 0))
                        Text(MoveFormat.z(s.z)).monospacedDigit()
                            .fontWeight(abs(s.z ?? 0) >= 1.5 ? .semibold : .regular)
                        Text(s.positiveMeans).foregroundStyle(.secondary)
                    }
                }
            }
            .font(.callout)
        }
    }

    // MARK: 6. The noise filter

    private func noiseFilter(_ d: MarketDay) -> some View {
        Box(title: "6. How the noise is filtered", symbol: "line.3.horizontal.decrease.circle", help: "The rules this page follows, so what it highlights is measured rather than picked.") {
            SelectableText(text: {
                var l = RichLines()
                l.bullets([
                    "A sector is flagged only when its move is unusual for that sector — |z| of \(String(format: "%.1f", d.thresholds.sectorZ)) or more against its last \(d.baseline.days) trading days — and its volume is \(String(format: "%.1f", d.thresholds.relativeVolume))× its 20-day average or more. The others are listed without emphasis.",
                    "Every comparison is against the security's own recent history: the \(d.baseline.days) trading days \(d.baseline.from.map { "from \(MoveFormat.shortDay($0))" } ?? "") \(d.baseline.to.map { "to \(MoveFormat.shortDay($0))" } ?? "before").",
                    "Patterns are descriptions of what moved together, with each condition shown. The page never names a cause: headlines and releases aren't matched to the move here.",
                    "During the session, volume is compared with the share of a day's volume SPY normally trades by that minute (its last five sessions), so morning volume isn't read as light; it's final after the close.",
                    "Nothing here is a forecast or a recommendation to buy or sell.",
                ], font: RichLines.calloutFont)
                return l.result
            }())
        }
    }

    // MARK: 7. Your exposure

    @ViewBuilder
    private func exposure(_ d: MarketDay) -> some View {
        if let e = d.exposure {
            Box(title: "7. Your exposure: \(e.name ?? e.account)", symbol: "person.crop.circle", help: "My Portfolio in the security master at its latest prices. An index fund is moved by the ETF that tracks the same index (Vanguard's VTI, BND, VXUS, BNDX); the U.S. stock fund's holdings (Vanguard's published holdings, month-end) give its sectors and each sector's part of today's change; the international fund's sectors are shown, its change is VXUS's (foreign markets aren't in the U.S. bars).") {
                if let problem = e.problem {
                    Text(problem).font(.callout).foregroundStyle(.secondary)
                } else {
                    exposureBody(e)
                }
            }
        }
    }

    @ViewBuilder
    private func exposureBody(_ e: MarketDay.Exposure) -> some View {
        Text("\(MoveFormat.whole(e.value ?? 0)) at prices of \(e.pricedThrough.map(MoveFormat.shortDay) ?? "—"); estimated change \(MoveFormat.dollars(e.change)) (\(MoveFormat.r(e.ret))).")
            .font(.callout)
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
            GridRow {
                ForEach(["Holding", "", "Value", "Moved with", "Return", "Change"], id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            }
            ForEach(e.holdings ?? []) { h in
                GridRow {
                    Text(h.ticker ?? "—").fontWeight(.semibold)
                    Text(h.name ?? "").lineLimit(1).foregroundStyle(.secondary)
                    Text(MoveFormat.whole(h.value)).monospacedDigit()
                    Text(h.proxy ?? "no same-day price").foregroundStyle(.secondary)
                    Text(MoveFormat.r(h.ret)).monospacedDigit().foregroundStyle(Color.signed(h.ret ?? 0))
                    Text(MoveFormat.dollars(h.change)).monospacedDigit().foregroundStyle(Color.signed(h.change ?? 0))
                }
            }
        }
        .font(.callout)
        if let sectors = e.sectors, !sectors.isEmpty {
            Divider()
            Text("By sector (stock funds, through their holdings)").heading(.subheading)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                GridRow {
                    ForEach(["Sector", "U.S. fund", "International fund", "Your total", "U.S. fund's change today"], id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
                ForEach(sectors) { s in
                    GridRow {
                        Text(s.sector)
                        Text(MoveFormat.whole(s.us)).monospacedDigit()
                        Text(MoveFormat.whole(s.intl)).monospacedDigit()
                        Text(MoveFormat.whole(s.total)).monospacedDigit().fontWeight(.semibold)
                        Text(s.usCovered > 0 ? MoveFormat.dollars(s.usChange) : "—").monospacedDigit().foregroundStyle(Color.signed(s.usChange))
                    }
                }
            }
            .font(.callout)
            Text("The international fund's sectors are from its holdings; about a third of them have no sector in the security master (Unclassified). Its change today is VXUS's, shown above.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if let unpriced = e.unpriced, !unpriced.isEmpty {
            Text("No same-day price for \(unpriced.joined(separator: ", ")): left out of the estimate.").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Data

    private func sources(_ d: MarketDay) -> some View {
        Box(title: "Data", symbol: "arrow.up.right.square", help: "Where each number comes from.") {
            SelectableText(text: {
                var l = RichLines()
                l.bullets(d.sources, font: RichLines.calloutFont)
                l.paragraph("Read through the accounts service (GET /market/day)" + (d.seconds.map { String(format: " in %.1f s", $0) } ?? "")
                            + ". Massive's Stocks Starter plan delays quotes 15 minutes; a day's history is read once and kept on this Mac.",
                            font: RichLines.calloutFont, color: .secondaryLabelColor, spacing: 8)
                return l.result
            }())
        }
    }
}
