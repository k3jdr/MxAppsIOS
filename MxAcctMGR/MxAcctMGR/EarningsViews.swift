//
//  EarningsViews.swift
//  MxAcctMGR
//
//  Knowledge Library ▸ Earnings Calendar and Earnings by Day: real companies' reports (sources in Earnings.swift). The
//  calendar shows a month or a week — past days with how many companies beat or missed the consensus, upcoming days
//  with who reports and what analysts expect — and a day opens Earnings by Day: every company reporting that day,
//  with its time, EPS and revenue estimates and results, and the selected company's history.
//

import AppKit
import Charts
import SwiftUI

// MARK: - Formatting

nonisolated enum EarningsFormat {
    static func eps(_ x: Double?) -> String {
        guard let x else { return "—" }
        return x < 0 ? String(format: "−$%.2f", -x) : String(format: "$%.2f", x)
    }

    /// $1.23T, $113.3B, $2.6M, $950K.
    static func dollars(_ x: Double?) -> String {
        guard let x else { return "—" }
        let a = abs(x), sign = x < 0 ? "−" : ""
        if a >= 1e12 { return sign + String(format: "$%.2fT", a / 1e12) }
        if a >= 1e9 { return sign + String(format: "$%.1fB", a / 1e9) }
        if a >= 1e6 { return sign + String(format: "$%.1fM", a / 1e6) }
        if a >= 1e3 { return sign + String(format: "$%.0fK", a / 1e3) }
        return sign + String(format: "$%.0f", a)
    }

    static func surprise(_ x: Double?) -> String {
        guard let x else { return "—" }
        return String(format: "%+.1f%%", 100 * x).replacingOccurrences(of: "-", with: "−")
    }

    /// Companies as lines of tab-separated columns under the table's column titles (they paste into a spreadsheet).
    static func rows(_ entries: [EarningsEntry]) -> String {
        let titles = ["Symbol", "Company", "Time", "Mkt cap", "Ests", "EPS est.", "EPS actual", "Surprise", "Rev. est.", "Rev. actual", "Rev. surprise"]
        let lines = entries.map { r in
            [r.symbol, r.name, r.time.shortTitle, dollars(r.marketCap), r.estimates.map(String.init) ?? "",
             eps(r.epsEstimate) + (r.epsFromFMP ? " (FMP)" : ""), eps(r.epsActual), surprise(r.epsSurprise),
             dollars(r.revenueEstimate), dollars(r.revenueActual), surprise(r.revenueSurprise)].joined(separator: "\t")
        }
        return ([titles.joined(separator: "\t")] + lines).joined(separator: "\n")
    }

    static func color(_ o: EarningsEntry.Outcome) -> Color {
        switch o {
        case .beat: .green
        case .missed: .red
        case .inLine, .noEstimate: .secondary
        case .upcoming: .primary
        }
    }
}

/// Beat / in line / missed shares of a day's reports as one bar.
struct OutcomeBar: View {
    var entries: [EarningsEntry]

    var body: some View {
        let beat = entries.filter { $0.outcome == .beat }.count
        let missed = entries.filter { $0.outcome == .missed }.count
        let other = entries.count - beat - missed
        GeometryReader { g in
            let total = CGFloat(max(entries.count, 1))
            HStack(spacing: 0) {
                Rectangle().fill(Color.green.opacity(0.75)).frame(width: g.size.width * CGFloat(beat) / total)
                Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: g.size.width * CGFloat(other) / total)
                Rectangle().fill(Color.red.opacity(0.75)).frame(width: g.size.width * CGFloat(missed) / total)
            }
        }
        .frame(height: 5)
        .clipShape(Capsule())
        .help("\(beat) beat the consensus EPS, \(missed) missed, \(other) in line or without an estimate")
    }
}

// MARK: - Earnings by Day

struct EarningsDayView: View {
    @Bindable var store: PortStore
    @State private var sortOrder = [KeyPathComparator(\EarningsEntry.capKey, order: .reverse)]

    var body: some View {
        @Bindable var e = store.earnings
        let day = e.days[e.date]
        let held = store.heldEarningsKeys
        let rows = filtered(day, held)
        StepPage(store: store, subtitle: "Every company reporting on a day: U.S.-listed companies from Nasdaq.com's earnings calendar, with revenue from FMP. Real data.", lessonTitle: "How to read an earnings list", lesson: [
            "Companies report each quarter, most of them in four earnings seasons that begin about two weeks after a quarter ends. Before the open (around 7–8 a.m. Eastern) or after the close (around 4–5 p.m.): either way the stock reacts at the next trading session.",
            "The consensus is the average analyst forecast, and prices already reflect it. The market reacts to the surprise — and often more to what the company says about the coming quarters (guidance) than to the quarter just reported.",
            "In recent years roughly three in four large U.S. companies have beaten the EPS consensus in a typical quarter, partly because companies steer analysts toward numbers they can beat. A beat is ordinary; a miss stands out.",
            "Through an index fund each of these companies is a small part of an account. For a long-term plan, a single report is rarely a reason to trade.",
        ]) {
            dayBar(e)
            notes(e, day)
            tiles(day, held)
            filterBar(e, shown: rows.count)
            Box(title: "Companies reporting", symbol: "list.bullet.rectangle", help: "Every company reporting on the day. Click a column header to sort; select a company for its history below.") {
                if day == nil {
                    ProgressView("Loading \(EarningsDates.title(e.date, weekday: false))…").frame(maxWidth: .infinity).frame(height: 440)
                } else {
                    table(rows, held: held, selection: $e.selection)
                        .frame(height: 440)
                }
            }
            if let key = e.selection, let entry = day?.entries.first(where: { $0.key == key }) {
                CompanyEarningsBox(store: store, entry: entry, held: held.contains(key))
            }
            EarningsSourcesBox(store: store)
        }
        .task(id: e.date) {
            show(await e.load([e.date], weekends: true))
            await e.loadSecurityNames(e.date)
            await SecurityLinks.shared.load(tickers: e.days[e.date]?.listed.map(\.symbol) ?? [])
        }
    }

    private func show(_ message: String) { if !message.isEmpty { store.message = message } }

    private func filtered(_ day: EarningsDay?, _ held: Set<String>) -> [EarningsEntry] {
        guard let day else { return [] }
        let e = store.earnings
        var rows = e.includeFMPOnly ? day.entries : day.listed
        if let t = e.timeFilter { rows = rows.filter { $0.time == t } }
        if e.onlyHeld { rows = rows.filter { held.contains($0.key) } }
        let q = e.search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { rows = rows.filter { $0.symbol.localizedCaseInsensitiveContains(q) || $0.name.localizedCaseInsensitiveContains(q) } }
        return rows.sorted(using: sortOrder)
    }

    private func dayBar(_ e: EarningsStore) -> some View {
        let today = EarningsDates.today()
        return HStack(spacing: 10) {
            Button { e.date = EarningsDates.nextWeekday(e.date, -1) } label: { Image(systemName: "chevron.left") }
                .help("The weekday before")
                .quickHelp("Previous Day", "The weekday before this one.")
            DatePicker("Day", selection: Binding(get: { EarningsDates.date(e.date) }, set: { e.date = EarningsDates.string($0) }), displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.field)
                .fixedSize()
                .help("Any day: past days show results, upcoming days the expectations")
                .quickHelp("Day", "Pick any day. Past days show each company's results against the consensus; upcoming days what analysts expect. Nasdaq.com's history goes back years; FMP's revenue figures 12 months.")
            Button { e.date = EarningsDates.nextWeekday(e.date, 1) } label: { Image(systemName: "chevron.right") }
                .help("The next weekday")
                .quickHelp("Next Day", "The next weekday.")
            Text(EarningsDates.title(e.date)).heading(.subheading)
            Button("Today") { e.date = today }
                .disabled(e.date == today)
                .help("Today's reports")
            Spacer()
            if e.isLoading(e.date) {
                ProgressView().controlSize(.small)
                Text("Loading…").foregroundStyle(.secondary)
            }
            Button { Task { show(await e.load([e.date], force: true, weekends: true)) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(e.isLoading(e.date))
                .help("Fetch the day again from Nasdaq.com and FMP")
                .quickHelp("Refresh", "Fetches the day again from both sources. Past days otherwise load from what is kept on this Mac.")
            Button { e.anchor = e.date; store.go(.earningsCalendar) } label: { Label("Calendar", systemImage: "calendar") }
                .help("This day's month in the Earnings Calendar")
        }
    }

    @ViewBuilder
    private func notes(_ e: EarningsStore, _ day: EarningsDay?) -> some View {
        let past = e.date < EarningsDates.today()
        VStack(alignment: .leading, spacing: 4) {
            if let p = e.nasdaqProblem, day?.nasdaqFetched == nil {
                Label(p, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            if let day, day.fmpFetched == nil, !e.isLoading(e.date) {
                if e.date < e.planStart {
                    Label("No revenue figures: FMP's plan reaches back 12 months (to \(EarningsDates.title(e.planStart, weekday: false))), and this day wasn't kept on this Mac before then.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                } else if let p = e.fmpProblem {
                    HStack {
                        Label("No revenue figures: \(p)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Button("Layer 3 Services…") { store.go(.services) }.buttonStyle(.link)
                    }
                }
            }
            if let day, day.listedFromFMP {
                Label(day.nasdaqFetched == nil ? "Nasdaq.com's listing couldn't be loaded: these are FMP's reports, without company names or times."
                      : "Nasdaq.com doesn't list this day yet: these are the reports FMP has scheduled, without company names or times.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
            if let day, day.nasdaqFetched != nil, day.listed.isEmpty {
                Label("Nasdaq.com lists no reports for this day\(EarningsDates.isWeekend(e.date) ? " (a weekend)" : "")" + (day.fmpOnly.isEmpty ? "." : "; FMP lists \(day.fmpOnly.count) other listings (“Also FMP-only listings”)."), systemImage: "calendar.badge.exclamationmark")
                    .foregroundStyle(.secondary)
            }
            if past, let day, day.listed.contains(where: { $0.timeFromEarlier || ($0.onNasdaq && !$0.epsFromFMP && $0.epsActual != nil && $0.time == .notGiven) }) {
                Label("Nasdaq.com leaves out the time of day once a day has passed; times kept from an earlier listing on this Mac are marked ↺.", systemImage: "clock")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    @ViewBuilder
    private func tiles(_ day: EarningsDay?, _ held: Set<String>) -> some View {
        let listed = day?.listed ?? []
        let reported = listed.filter(\.reported)
        let beat = reported.filter { $0.outcome == .beat }.count, missed = reported.filter { $0.outcome == .missed }.count
        let withEstimate = reported.filter { $0.epsSurprise != nil }.count
        let revenue = reported.filter { $0.revenueSurprise != nil }
        let revenueBeat = revenue.filter { $0.revenueOutcome == .beat }.count
        let mine = listed.filter { held.contains($0.key) }
        HStack(spacing: 10) {
            MetricTile(title: "Companies reporting", value: day == nil ? "…" : listed.count.formatted(),
                       caption: day.map { d in d.listedFromFMP ? "FMP's schedule" : d.fmpOnly.isEmpty ? "" : "+\(d.fmpOnly.count) listings only on FMP" } ?? "",
                       help: "U.S.-listed companies Nasdaq.com lists for the day. FMP also lists OTC, foreign and preferred-share symbols: tick “Also FMP-only listings” to see them.")
            let timed = listed.contains { $0.time != .notGiven }
            MetricTile(title: "Before the open", value: timed ? listed.filter { $0.time == .beforeOpen }.count.formatted() : "—",
                       caption: timed ? "after the close: \(listed.filter { $0.time == .afterClose }.count)" : "times not given",
                       help: "Reports before the U.S. market opens move the stock that day; reports after the close move it the next morning. Past days' times are known only if this Mac saw the day's listing before it happened.")
            if reported.isEmpty {
                MetricTile(title: "With a consensus EPS", value: listed.filter { $0.epsEstimate != nil }.count.formatted(), caption: "analysts' average forecast",
                           help: "Companies with a consensus EPS forecast. The surprise against it is what moves the stock.")
                MetricTile(title: "Revenue expected", value: EarningsFormat.dollars(listed.compactMap(\.revenueEstimate).reduce(0, +)), caption: "sum of FMP's estimates",
                           help: "The day's total expected revenue, from FMP's estimates (where FMP has them).")
            } else {
                MetricTile(title: "EPS beat / missed", value: "\(beat) / \(missed)", caption: withEstimate > 0 ? "\(pct(Double(beat) / Double(withEstimate), 0)) of \(withEstimate) beat" : "",
                           tint: beat >= missed ? .green : .red,
                           help: "Of the companies that reported against a consensus: how many beat it and how many missed. The rest were in line.")
                MetricTile(title: "Revenue beat / missed", value: revenue.isEmpty ? "—" : "\(revenueBeat) / \(revenue.filter { $0.revenueOutcome == .missed }.count)",
                           caption: revenue.isEmpty ? "no FMP revenue figures" : "\(pct(Double(revenueBeat) / Double(revenue.count), 0)) of \(revenue.count) beat",
                           help: "Revenue against FMP's estimate. Revenue is harder to flatter than EPS, so beating on both is a stronger result.")
            }
            MetricTile(title: "In your account", value: store.portfolio.isSRM ? mine.count.formatted() : "—",
                       caption: store.portfolio.isSRM ? mine.prefix(4).map(\.symbol).joined(separator: " ") : "My Portfolio in the security master",
                       tint: mine.isEmpty ? .primary : .accentColor,
                       help: "Companies held directly in the account selected in the toolbar (My Portfolio or a sample), from the security master.")
        }
    }

    private func filterBar(_ e: EarningsStore, shown: Int) -> some View {
        @Bindable var e = e
        return HStack(spacing: 10) {
            TextField("Symbol or company", text: $e.search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .help("Show only companies whose symbol or name contains this")
            Picker("Time", selection: $e.timeFilter) {
                Text("Any time").tag(ReportTime?.none)
                ForEach(ReportTime.allCases) { Text($0.title).tag(Optional($0)) }
            }
            .fixedSize()
            .help("Before the open, after the close, or not given")
            Toggle("Also FMP-only listings", isOn: $e.includeFMPOnly)
                .help("Add the symbols only FMP lists: mostly OTC and foreign listings and preferred shares, without names or times")
                .quickHelp("FMP-only Listings", "FMP's calendar also lists OTC, foreign and preferred-share symbols that Nasdaq.com's list of U.S.-listed companies leaves out. They have no company name or time of day.")
            Toggle("Only my holdings", isOn: $e.onlyHeld)
                .disabled(!store.portfolio.isSRM)
                .help(store.portfolio.isSRM ? "Only companies you hold in My Portfolio" : "Needs My Portfolio in the security master (real tickers)")
            Spacer()
            Text("\(shown.formatted()) shown").foregroundStyle(.secondary)
        }
    }

    private func table(_ rows: [EarningsEntry], held: Set<String>, selection: Binding<String?>) -> some View {
        Table(rows, selection: selection, sortOrder: $sortOrder) {
            companyColumns(held)
            figureColumns
        }
        .tableText()
        .contextMenu(forSelectionType: EarningsEntry.ID.self) { keys in
            if let key = keys.first, let entry = rows.first(where: { $0.key == key }) {
                linkMenu(LinkTarget.earnings(entry))
                Divider()
                Button("Copy Row") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(EarningsFormat.rows([entry]), forType: .string)
                }
            }
        }
        // Rows are selected, not their words: Edit ▸ Copy (⌘C) copies the selected row, with the columns' titles.
        .textSelection(.disabled)
        .onCopyCommand {
            guard let entry = rows.first(where: { $0.key == selection.wrappedValue }) else { return [] }
            return [NSItemProvider(object: EarningsFormat.rows([entry]) as NSString)]
        }
        .quickHelpArea("Companies Reporting", "One row per company: its symbol (briefcase: you hold it), name, when it reports, market cap and number of analysts' estimates; consensus and actual EPS with the surprise (Nasdaq.com; ᶠ marks FMP's estimate and actual, used where Nasdaq.com has no result yet); FMP's revenue estimate, actual and surprise. Green beat, red missed. Click a header to sort; select a row for the company's history. ⌘K (Edit ▸ Link…) or the row's context menu adds a link to the symbol or company name, with its own hover text: the pointer resting on a linked name shows its card, a click opens it.", symbol: "list.bullet.rectangle")
    }

    @TableColumnBuilder<EarningsEntry, KeyPathComparator<EarningsEntry>>
    private func companyColumns(_ held: Set<String>) -> some TableColumnContent<EarningsEntry, KeyPathComparator<EarningsEntry>> {
        TableColumn("Symbol", value: \.symbol) { r in SymbolCell(entry: r, held: held.contains(r.key)) }
            .width(min: 60, ideal: 72)
        TableColumn("Company", value: \.nameKey) { r in
            if r.name.isEmpty {
                Text("— only FMP lists it").foregroundStyle(.secondary).lineLimit(1)
            } else {
                LinkedCell(target: .earnings(r, .name))
            }
        }
        .width(min: 130, ideal: 190)
        TableColumn("Time", value: \.timeKey) { r in TimeCell(entry: r) }
            .width(min: 92, ideal: 106)
        TableColumn("Mkt cap", value: \.capKey) { r in FigureCell(text: EarningsFormat.dollars(r.marketCap), color: .secondary) }
            .width(min: 56, ideal: 66)
        TableColumn("Ests", value: \.estimatesKey) { r in FigureCell(text: r.estimates.map(String.init) ?? "", color: .secondary) }
            .width(min: 30, ideal: 34)
    }

    @TableColumnBuilder<EarningsEntry, KeyPathComparator<EarningsEntry>>
    private var figureColumns: some TableColumnContent<EarningsEntry, KeyPathComparator<EarningsEntry>> {
        TableColumn("EPS est.", value: \.epsEstimateKey) { r in
            FigureCell(text: EarningsFormat.eps(r.epsEstimate) + (r.epsFromFMP ? "ᶠ" : ""), color: .primary,
                       help: r.epsFromFMP ? "FMP's estimate and actual: Nasdaq.com has no result for \(r.symbol) yet" : "Consensus (Zacks, via Nasdaq.com)")
        }
        .width(min: 56, ideal: 64)
        TableColumn("EPS actual", value: \.epsActualKey) { r in FigureCell(text: EarningsFormat.eps(r.epsActual), color: EarningsFormat.color(r.outcome)) }
            .width(min: 56, ideal: 66)
        TableColumn("Surprise", value: \.epsSurpriseKey) { r in FigureCell(text: EarningsFormat.surprise(r.epsSurprise), color: EarningsFormat.color(r.outcome)) }
            .width(min: 52, ideal: 64)
        TableColumn("Rev. est.", value: \.revenueEstimateKey) { r in FigureCell(text: EarningsFormat.dollars(r.revenueEstimate), color: .primary) }
            .width(min: 56, ideal: 70)
        TableColumn("Rev. actual", value: \.revenueActualKey) { r in
            FigureCell(text: EarningsFormat.dollars(r.revenueActual), color: EarningsFormat.color(r.revenueOutcome))
        }
        .width(min: 56, ideal: 74)
        TableColumn("Rev. surprise", value: \.revenueSurpriseKey) { r in
            FigureCell(text: EarningsFormat.surprise(r.revenueSurprise), color: EarningsFormat.color(r.revenueOutcome))
        }
        .width(min: 52, ideal: 72)
    }
}

private struct SymbolCell: View {
    var entry: EarningsEntry
    var held: Bool

    var body: some View {
        HStack(spacing: 4) {
            LinkedCell(target: .earnings(entry), font: PortSettings.shared.font(.ids), bold: held,
                       help: held ? "You hold \(entry.symbol)" : entry.onNasdaq ? entry.symbol
                           : entry.nameFromSecurityMaster ? "Only FMP's calendar lists \(entry.symbol); its name is the security master's"
                           : "Only FMP lists \(entry.symbol)")
            if held { Image(systemName: "briefcase.fill").font(.caption2).foregroundStyle(Color.accentColor).help("You hold \(entry.symbol)") }
        }
    }
}

private struct TimeCell: View {
    var entry: EarningsEntry

    var body: some View {
        let t = entry.time
        HStack(spacing: 4) {
            Image(systemName: t.symbol).foregroundStyle(.secondary)
            Text(t.shortTitle + (entry.timeFromEarlier ? " ↺" : "")).foregroundStyle(t == .notGiven ? Color.secondary : Color.primary)
        }
        .help(entry.timeFromEarlier ? "From the day's earlier listing, kept on this Mac" : t == .notGiven ? "The source gives no time" : t.title)
    }
}

private struct FigureCell: View {
    var text: String
    var color: Color
    var help = ""

    var body: some View {
        Text(text).monospacedDigit().foregroundStyle(color).help(help)
    }
}

/// The selected company: this report in detail and its history.
struct CompanyEarningsBox: View {
    @Bindable var store: PortStore
    var entry: EarningsEntry
    var held: Bool

    var body: some View {
        let c = store.earnings.companies[entry.symbol]
        let forecast = c?.forecasts.first { q in
            entry.fiscalQuarter.map { q.quarter.replacingOccurrences(of: "/", with: " ") == $0 } ?? false
        } ?? (entry.reported ? nil : c?.forecasts.first)
        Box(title: "\(entry.symbol) — \(entry.name.isEmpty ? "only FMP lists it" : entry.name)" + (held ? " (you hold it)" : ""), symbol: "building.2",
            help: "The selected company's report and its history: FMP's past reports with revenue, Nasdaq.com's last four surprises and this quarter's forecast range.") {
            HStack(alignment: .top, spacing: 20) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    line("Reports", EarningsDates.title(store.earnings.date, weekday: false) + " · " + entry.time.title + (entry.timeFromEarlier ? " (earlier listing)" : ""))
                    line("Fiscal quarter", entry.fiscalQuarter ?? "—")
                    if entry.epsFromFMP {
                        line("FMP's EPS estimate", EarningsFormat.eps(entry.epsEstimate))
                        if let n = entry.nasdaqEPSEstimate {
                            line("Nasdaq.com consensus", EarningsFormat.eps(n) + (entry.estimates.map { " · \($0) estimates" } ?? ""))
                        }
                    } else {
                        line("Consensus EPS", EarningsFormat.eps(entry.epsEstimate) + (entry.estimates.map { " · \($0) estimates" } ?? ""))
                    }
                    if let f = forecast {
                        line("Range of estimates", "\(EarningsFormat.eps(f.low)) to \(EarningsFormat.eps(f.high))")
                        line("Revisions, 4 weeks", "\(f.up ?? 0) up · \(f.down ?? 0) down")
                    }
                    if entry.reported {
                        line(entry.epsFromFMP ? "FMP's actual EPS" : "Actual EPS", EarningsFormat.eps(entry.epsActual) + " · " + EarningsFormat.surprise(entry.epsSurprise),
                             color: EarningsFormat.color(entry.outcome))
                    }
                    line("Revenue estimate", EarningsFormat.dollars(entry.revenueEstimate))
                    if entry.revenueActual != nil {
                        line("Actual revenue", EarningsFormat.dollars(entry.revenueActual) + " · " + EarningsFormat.surprise(entry.revenueSurprise), color: EarningsFormat.color(entry.revenueOutcome))
                    }
                    if entry.onFMP, !entry.epsFromFMP, entry.fmpEPSEstimate != nil || entry.fmpEPSActual != nil {
                        line("FMP's EPS", "\(EarningsFormat.eps(entry.fmpEPSEstimate)) estimate · \(EarningsFormat.eps(entry.fmpEPSActual)) actual")
                    }
                    if let y = entry.lastYearEPS {
                        line("A year earlier", EarningsFormat.eps(y) + (entry.lastYearDate.map { " on " + EarningsDates.title($0, weekday: false) } ?? ""))
                    }
                    line("Market cap", EarningsFormat.dollars(entry.marketCap))
                }
                .frame(width: 360, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) {
                    Text("EPS by report: estimate and actual (FMP)").font(.subheadline.weight(.semibold))
                    if c == nil || c!.loading {
                        ProgressView().controlSize(.small)
                    } else if c!.history.isEmpty {
                        Text(c!.historyNote ?? "FMP has no history for \(entry.symbol).").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        historyChart(c!.history)
                        revenueTable(c!.history)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let c, !c.surprises.isEmpty {
                Divider()
                Text("Last four reports against the consensus (Nasdaq.com)").font(.subheadline.weight(.semibold))
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 3) {
                    GridRow {
                        Text("Quarter").bold(); Text("Reported").bold(); Text("EPS").bold(); Text("Consensus").bold(); Text("Surprise").bold()
                    }
                    ForEach(c.surprises, id: \.self) { s in
                        GridRow {
                            Text(s.quarter)
                            Text(s.reported.map { EarningsDates.title($0, weekday: false) } ?? "—")
                            Text(EarningsFormat.eps(s.eps)).monospacedDigit()
                            Text(EarningsFormat.eps(s.consensus)).monospacedDigit()
                            Text(EarningsFormat.surprise(s.surprise)).monospacedDigit().foregroundStyle(Color.signed(s.surprise ?? 0))
                        }
                    }
                }
                .textKind(.results)
            } else if let note = c?.nasdaqNote {
                Text("Nasdaq.com history: \(note)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: entry.symbol) { await store.earnings.loadCompany(entry.symbol) }
    }

    private func line(_ label: String, _ value: String, color: Color = .primary) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).foregroundStyle(color).monospacedDigit().textSelection(.enabled)
        }
    }

    /// The last twelve reports and the next one, oldest first.
    private func recent(_ rows: [FMPEarningsRow]) -> [FMPEarningsRow] {
        let reported = rows.filter { $0.epsActual != nil }.prefix(12)
        let next = rows.filter { $0.epsActual == nil && $0.date >= EarningsDates.today() }.last
        return (Array(reported) + (next.map { [$0] } ?? [])).sorted { $0.date < $1.date }
    }

    private struct Point: Identifiable {
        var series: String
        var date: String
        var eps: Double
        var id: String { series + date }
    }

    private func historyChart(_ rows: [FMPEarningsRow]) -> some View {
        let points = recent(rows).flatMap { r in
            [("Estimate", r.epsEstimated), ("Actual", r.epsActual)].compactMap { s, v in v.map { Point(series: s, date: r.date, eps: $0) } }
        }
        return Chart(points) { p in
            BarMark(x: .value("Report", String(p.date.prefix(7))), y: .value("EPS", p.eps), width: .ratio(0.8))
                .foregroundStyle(by: .value("Series", p.series))
                .position(by: .value("Series", p.series))
        }
        .chartForegroundStyleScale(["Estimate": Color.secondary.opacity(0.45), "Actual": Color.accentColor])
        .chartXAxis { AxisMarks { _ in AxisValueLabel().font(.caption2) } }
        .frame(height: 170)
        .quickHelpArea("EPS by Report", "Each report's consensus EPS (grey) and actual EPS (blue) from FMP, the last twelve and the next one. A run of beats is common; what matters is the trend and the size of the surprises. FMP's EPS can differ from Nasdaq.com's (another consensus; for some companies GAAP rather than adjusted EPS).", symbol: "chart.bar")
    }

    private func revenueTable(_ rows: [FMPEarningsRow]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 2) {
            GridRow {
                Text("Report").bold(); Text("Revenue est.").bold(); Text("Actual").bold(); Text("Surprise").bold()
            }
            ForEach(Array(rows.filter { $0.revenueActual != nil || $0.date >= EarningsDates.today() }.prefix(5)), id: \.date) { r in
                let s = EarningsEntry.surprise(r.revenueActual, r.revenueEstimated)
                GridRow {
                    Text(EarningsDates.title(r.date, weekday: false))
                    Text(EarningsFormat.dollars(r.revenueEstimated)).monospacedDigit()
                    Text(EarningsFormat.dollars(r.revenueActual)).monospacedDigit()
                    Text(EarningsFormat.surprise(s)).monospacedDigit().foregroundStyle(Color.signed(s ?? 0))
                }
            }
        }
        .textKind(.results, 10)
    }
}

/// Where each figure comes from and its limits.
struct EarningsSourcesBox: View {
    @Bindable var store: PortStore

    var body: some View {
        Box(title: "Sources and their limits", symbol: "info.circle", help: "Where each figure comes from, how far back and ahead it reaches, and what it leaves out.") {
            VStack(alignment: .leading, spacing: 6) {
                source("Nasdaq.com earnings calendar", "Companies, times, market cap (today's, also for past days), consensus EPS (Zacks) and estimates, actual EPS and surprise — free, no key. U.S.-listed companies only; schedules a few weeks ahead and history back years. The time of day is left out once a day has passed, so times show only where this Mac saw the day's listing beforehand (marked ↺). An unofficial public API, fetched three days at a time.")
                source("FMP earnings calendar (accounts service, port 8774)", "Revenue estimates and actuals, FMP's own EPS figures, and OTC, foreign and preferred listings. The plan reaches back 12 months (to \(EarningsDates.title(store.earnings.planStart, weekday: false))) and several months ahead; no company names or times. FMP's EPS can differ from Nasdaq.com's: another consensus, and for some companies GAAP EPS.")
                source("Company history", "FMP's reports with revenue (decades back); Nasdaq.com's last four surprises and this quarter's forecast range and revisions.")
                source("Kept on this Mac", "Each day's listings are kept in MxAcctMGR's Application Support/Earnings folder, so past days open at once and keep their times; a listing is fetched again until three days after its date (FMP's: a week).")
            }
            Text("Real companies and their reports, shown to learn how an earnings calendar reads — not investment advice and not a recommendation to buy or sell anything.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func source(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.callout.weight(.semibold))
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Earnings Calendar

struct EarningsCalendarView: View {
    @Bindable var store: PortStore

    var body: some View {
        @Bindable var e = store.earnings
        let held = store.heldEarningsKeys
        let days = e.calendarDays
        StepPage(store: store, subtitle: "Real earnings reports by month or week: past days with how many companies beat or missed, upcoming days with who reports and what analysts expect. Select a day for its full list.", lessonTitle: "Reading an earnings season", lesson: [
            "Earnings seasons peak three to six weeks after each quarter ends: from mid-January, mid-April, mid-July and mid-October into the following month. The large banks report first; the busiest days list several hundred companies.",
            "Past days show how many companies beat or missed the consensus EPS (green, red); upcoming days show the largest companies to report and, in the week view, what analysts expect.",
            "The share that beats says less than by how much, and what companies say about the next quarters. Select a day for every company, its revenue and its history.",
        ]) {
            bar(e, days: days)
            notes(e, days: days)
            if e.mode == .month { monthGrid(e, held: held) } else { weekColumns(e, held: held) }
            summary(e, days: days, held: held)
            EarningsSourcesBox(store: store)
        }
        .task(id: e.mode.rawValue + (days.first ?? "")) { show(await e.load(days)) }
    }

    private func bar(_ e: EarningsStore, days: [String]) -> some View {
        @Bindable var e = e
        let today = EarningsDates.today()
        let title = e.mode == .month ? EarningsDates.date(e.anchor).formatted(.dateTime.month(.wide).year())
            : "Week of " + EarningsDates.title(EarningsDates.week(e.anchor)[0], weekday: false)
        return HStack(spacing: 10) {
            Picker("View", selection: $e.mode) {
                ForEach(EarningsStore.Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("A month at a glance, or a week with each day's largest reports")
            .quickHelp("Month or Week", "Month: each day's number of reports, how many beat or missed, and the largest names. Week: each weekday's largest reports with their EPS estimate or result.")
            Button { step(e, -1) } label: { Image(systemName: "chevron.left") }
                .help(e.mode == .month ? "The month before" : "The week before")
            Text(title).heading(.heading).frame(minWidth: 240)
            Button { step(e, 1) } label: { Image(systemName: "chevron.right") }
                .help(e.mode == .month ? "The next month" : "The next week")
            Button("Today") { e.anchor = today }
                .disabled(days.contains(today))
                .help("Back to this \(e.mode == .month ? "month" : "week")")
            Spacer()
            if let p = e.progress {
                ProgressView(value: Double(p.done), total: Double(max(p.total, 1))).frame(width: 110)
                Text("Nasdaq.com: \(p.done) of \(p.total) days").font(.callout).foregroundStyle(.secondary)
            } else if days.contains(where: e.isLoading) {
                ProgressView().controlSize(.small)
            }
            Button { Task { show(await e.load(days, force: true)) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(days.contains(where: e.isLoading))
                .help("Fetch every day shown again from Nasdaq.com and FMP")
        }
    }

    private func show(_ message: String) { if !message.isEmpty { store.message = message } }

    private func step(_ e: EarningsStore, _ n: Int) {
        e.anchor = e.mode == .month ? EarningsDates.add(String(e.anchor.prefix(7)) + "-01", months: n) : EarningsDates.add(e.anchor, days: 7 * n)
    }

    @ViewBuilder
    private func notes(_ e: EarningsStore, days: [String]) -> some View {
        if let first = days.first, first < e.planStart, !days.contains(where: { e.days[$0]?.fmpFetched != nil }) {
            Label("No revenue figures before \(EarningsDates.title(e.planStart, weekday: false)): FMP's plan reaches back 12 months. Beat and miss here are Nasdaq.com's EPS results.", systemImage: "info.circle")
                .foregroundStyle(.secondary).font(.callout)
        }
        if let p = e.nasdaqProblem {
            Label(p, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
        }
        if let p = e.fmpProblem {
            HStack {
                Label("No revenue figures: \(p)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Button("Layer 3 Services…") { store.go(.services) }.buttonStyle(.link)
            }
            .font(.callout)
        }
    }

    private func monthGrid(_ e: EarningsStore, held: Set<String>) -> some View {
        let grid = EarningsDates.monthGrid(e.anchor)
        let columns = (0..<7).map { i in
            i < 5 ? GridItem(.flexible(minimum: 110), spacing: 5, alignment: .top) : GridItem(.flexible(minimum: 56, maximum: 90), spacing: 5, alignment: .top)
        }
        return LazyVGrid(columns: columns, spacing: 5) {
            ForEach(["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"], id: \.self) { d in
                Text(d).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
            ForEach(grid, id: \.self) { d in
                EarningsMonthCell(store: store, date: d, inMonth: EarningsDates.sameMonth(d, e.anchor), held: held)
            }
        }
        .quickHelpArea("Month", "Each day: the number of U.S.-listed companies reporting; for past days a bar of how many beat (green), were in line (grey) or missed (red) the consensus EPS; the largest names (green beat, red missed, plain still to come) and, with a briefcase, the ones you hold. Click a day for its full list.", symbol: "calendar")
    }

    private func weekColumns(_ e: EarningsStore, held: Set<String>) -> some View {
        let week = EarningsDates.week(e.anchor).filter { !EarningsDates.isWeekend($0) || !(e.days[$0]?.listed.isEmpty ?? true) }
        return HStack(alignment: .top, spacing: 8) {
            ForEach(week, id: \.self) { d in EarningsWeekColumn(store: store, date: d, held: held) }
        }
        .quickHelpArea("Week", "Each weekday's largest reports, before the open (sunrise) or after the close (moon): past reports with the actual EPS against the consensus, upcoming ones with the consensus. Click a company to open the day with it selected, or the day's header for the whole list.", symbol: "calendar.day.timeline.left")
    }

    @ViewBuilder
    private func summary(_ e: EarningsStore, days: [String], held: Set<String>) -> some View {
        let all = days.flatMap { d in (e.days[d]?.listed ?? []).map { DatedEntry(date: d, entry: $0) } }
        let reported = all.filter { $0.entry.reported }
        let withEstimate = reported.filter { $0.entry.epsSurprise != nil }
        let beat = withEstimate.filter { $0.entry.outcome == .beat }.count
        let missed = withEstimate.filter { $0.entry.outcome == .missed }.count
        let revenue = reported.filter { $0.entry.revenueSurprise != nil }
        let revenueBeat = revenue.filter { $0.entry.revenueOutcome == .beat }.count
        let today = EarningsDates.today()
        let upcoming = all.filter { !$0.entry.reported && $0.date >= today }
        let mine = all.filter { held.contains($0.entry.key) }
        Box(title: e.mode == .month ? "This month" : "This week", symbol: "sum", help: "Totals over the days shown, from the listings loaded so far.") {
            HStack(spacing: 10) {
                MetricTile(title: "Reports listed", value: all.count.formatted(), caption: "\(Set(days.filter { !(e.days[$0]?.listed.isEmpty ?? true) }).count) days with reports",
                           help: "U.S.-listed companies reporting on the days shown (Nasdaq.com).")
                MetricTile(title: "EPS beat", value: withEstimate.isEmpty ? "—" : pct(Double(beat) / Double(withEstimate.count), 0),
                           caption: withEstimate.isEmpty ? "nothing reported yet" : "\(beat) beat, \(missed) missed of \(withEstimate.count)", tint: .green,
                           help: "Of the companies that reported against a consensus EPS, the share that beat it.")
                MetricTile(title: "Revenue beat", value: revenue.isEmpty ? "—" : pct(Double(revenueBeat) / Double(revenue.count), 0),
                           caption: revenue.isEmpty ? "no FMP revenue figures" : "\(revenueBeat) of \(revenue.count) (FMP)", tint: .green,
                           help: "Of the companies that reported revenue against FMP's estimate, the share that beat it.")
                MetricTile(title: "Still to come", value: upcoming.count.formatted(), caption: upcoming.max { $0.entry.size < $1.entry.size }.map { "largest: \($0.entry.symbol)" } ?? "",
                           help: "Companies scheduled from today on that haven't reported yet.")
                if store.portfolio.isSRM {
                    MetricTile(title: "In your account", value: mine.count.formatted(), caption: mine.prefix(4).map { $0.entry.symbol }.joined(separator: " "), tint: .accentColor,
                               help: "Companies you hold in My Portfolio (security master) reporting on the days shown.")
                }
            }
            HStack(alignment: .top, spacing: 16) {
                notable("Largest still to come", upcoming.sorted { $0.entry.size > $1.entry.size }.prefix(8), held: held)
                notable("Largest that reported", reported.sorted { $0.entry.size > $1.entry.size }.prefix(8), held: held)
            }
        }
    }

    private struct DatedEntry: Identifiable {
        var date: String
        var entry: EarningsEntry
        var id: String { date + " " + entry.key }
    }

    private func notable(_ title: String, _ rows: ArraySlice<DatedEntry>, held: Set<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).textKind(.calendar, 11, weight: .semibold)
            if rows.isEmpty { Text("None in the days shown.").textKind(.calendar).foregroundStyle(.secondary) }
            ForEach(Array(rows)) { r in
                Button { store.openEarningsDay(r.date, select: r.entry.key) } label: {
                    HStack(spacing: 6) {
                        Text(EarningsDates.date(r.date).formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                            .foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
                        Image(systemName: r.entry.time.symbol).foregroundStyle(.secondary).frame(width: 16)
                        Text(r.entry.symbol).fontDesign(.monospaced).fontWeight(held.contains(r.entry.key) ? .bold : nil).frame(width: 56, alignment: .leading)
                        Text(r.entry.name).lineLimit(1)
                        Spacer()
                        if r.entry.reported {
                            Text("\(EarningsFormat.eps(r.entry.epsActual)) vs \(EarningsFormat.eps(r.entry.epsEstimate))").monospacedDigit()
                                .foregroundStyle(EarningsFormat.color(r.entry.outcome))
                        } else {
                            Text("est. \(EarningsFormat.eps(r.entry.epsEstimate))").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    .textKind(.calendar)
                    .contentShape(Rectangle())
                }
                .plainButton()
                .help("Open \(EarningsDates.title(r.date)) with \(r.entry.symbol) selected")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A day in the month grid.
struct EarningsMonthCell: View {
    let store: PortStore
    var date: String
    var inMonth: Bool
    var held: Set<String>

    var body: some View {
        let e = store.earnings
        let listed = inMonth ? e.days[date]?.listed ?? [] : []
        let reported = listed.filter(\.reported)
        let weekend = EarningsDates.isWeekend(date)
        let today = date == EarningsDates.today()
        let past = date < EarningsDates.today()
        let pending = listed.count - reported.count
        let cellScale = PortSettings.shared.scale(.calendar)
        let names = (listed.filter { held.contains($0.key) } + listed.filter { !held.contains($0.key) }.sorted { $0.size > $1.size })
            .prefix(weekend ? 2 : !reported.isEmpty && pending > 0 ? 3 : 4)
        Button { store.openEarningsDay(date) } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text("\(EarningsDates.day(date))")
                        .textKind(.calendar, weight: today ? .bold : nil)
                        .foregroundStyle(today ? Color.white : .primary)
                        .padding(.horizontal, today ? 5 : 0)
                        .background(today ? Capsule().fill(Color.accentColor) : nil)
                    Spacer(minLength: 0)
                    if inMonth, e.isLoading(date), e.days[date]?.nasdaqFetched == nil {
                        ProgressView().controlSize(.mini)
                    } else if !listed.isEmpty {
                        Text(listed.count.formatted()).monospacedDigit().textKind(.calendar, 10, weight: .semibold).foregroundStyle(.secondary)
                    }
                }
                if !reported.isEmpty {
                    OutcomeBar(entries: reported)
                    if !weekend {
                        Text("\(reported.filter { $0.outcome == .beat }.count) beat · \(reported.filter { $0.outcome == .missed }.count) missed")
                            .textKind(.calendar, 10).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                ForEach(Array(names), id: \.key) { n in
                    HStack(spacing: 3) {
                        if held.contains(n.key) { Image(systemName: "briefcase.fill").font(.system(size: 8)).foregroundStyle(Color.accentColor) }
                        Text(n.symbol).textKind(.calendar, 10).fontDesign(.monospaced).fontWeight(held.contains(n.key) ? .bold : nil)
                            .foregroundStyle(n.reported ? EarningsFormat.color(n.outcome) : .primary)
                        if !weekend, !n.reported, n.time != .notGiven {
                            Image(systemName: n.time.symbol).font(.system(size: 8)).foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                }
                if pending > 0, !reported.isEmpty, !weekend {
                    Text(past ? "\(pending) without a result" : "\(pending) to come").textKind(.calendar, 10).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(6)
            // As tall as the calendar's text needs (Settings ▸ Text ▸ Calendar).
            .frame(maxWidth: .infinity, minHeight: 134 * cellScale, maxHeight: 134 * cellScale, alignment: .topLeading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(date == e.date ? Color.accentColor : Color.secondary.opacity(inMonth ? 0.15 : 0.05), lineWidth: date == e.date ? 2 : 1))
            .opacity(inMonth ? 1 : 0.4)
            .contentShape(Rectangle())
        }
        .plainButton()
        .disabled(!inMonth)
        .help(listed.isEmpty ? EarningsDates.title(date) : "\(EarningsDates.title(date)): \(listed.count) reports — open the day's list")
    }
}

/// A weekday in the week view: its largest reports.
struct EarningsWeekColumn: View {
    let store: PortStore
    var date: String
    var held: Set<String>

    var body: some View {
        let e = store.earnings
        let listed = e.days[date]?.listed ?? []
        let reported = listed.filter(\.reported)
        let rows = (listed.filter { held.contains($0.key) } + listed.filter { !held.contains($0.key) }.sorted { $0.size > $1.size }).prefix(16)
        VStack(alignment: .leading, spacing: 4) {
            Button { store.openEarningsDay(date) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(EarningsDates.date(date).formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                        .textKind(.calendar, 13, weight: .bold).foregroundStyle(date == EarningsDates.today() ? Color.accentColor : .primary)
                    HStack {
                        Text(listed.count == 1 ? "1 report" : "\(listed.count) reports").textKind(.calendar, 10).foregroundStyle(.secondary)
                        if e.isLoading(date), e.days[date]?.nasdaqFetched == nil { ProgressView().controlSize(.mini) }
                    }
                    if !reported.isEmpty { OutcomeBar(entries: reported) }
                }
                .contentShape(Rectangle())
            }
            .plainButton()
            .help("Open \(EarningsDates.title(date))")
            Divider()
            ForEach(Array(rows), id: \.key) { r in
                Button { store.openEarningsDay(date, select: r.key) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: r.time.symbol).textKind(.calendar, 10).foregroundStyle(.secondary).frame(width: 14)
                        Text(r.symbol).textKind(.calendar).fontDesign(.monospaced).fontWeight(held.contains(r.key) ? .bold : nil)
                            .foregroundStyle(held.contains(r.key) ? Color.accentColor : .primary)
                        Spacer(minLength: 2)
                        if r.reported {
                            Text(EarningsFormat.eps(r.epsActual)).monospacedDigit().textKind(.calendar, 10).foregroundStyle(EarningsFormat.color(r.outcome))
                        } else {
                            Text(EarningsFormat.eps(r.epsEstimate)).monospacedDigit().textKind(.calendar, 10).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .plainButton()
                .help("\(r.name.isEmpty ? r.symbol : r.name) · \(r.time.title) · " + (r.reported ? "EPS \(EarningsFormat.eps(r.epsActual)) vs \(EarningsFormat.eps(r.epsEstimate)) expected (\(EarningsFormat.surprise(r.epsSurprise)))" : "consensus EPS \(EarningsFormat.eps(r.epsEstimate))"))
            }
            if listed.count > rows.count {
                Button("+\(listed.count - rows.count) more") { store.openEarningsDay(date) }
                    .buttonStyle(.link).textKind(.calendar, 10)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 300, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(date == e.date ? Color.accentColor : .clear, lineWidth: 2))
    }
}
