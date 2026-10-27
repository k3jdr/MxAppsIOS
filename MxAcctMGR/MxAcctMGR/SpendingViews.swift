//
//  SpendingViews.swift
//  MxAcctMGR
//
//  Reporting ▸ Spending Analysis (SpendingModel.swift): why the family's spending changed from one year to the next
//  — the attribution table and charts — and the forward curve of what the children's ages bring, with the entries,
//  rules, family and lifecycle model they are made from, and the sources they come from with how fresh each is.
//

import Charts
import SwiftUI
import UniformTypeIdentifiers

struct SpendingAnalysisView: View {
    @Bindable var store: PortStore
    @AppStorage("spendingTab") private var tab = "attribution"
    /// The category the Deep Dive tab shows.
    @AppStorage("spendingDeepDive") private var deepDive = "HEALTHCARE"
    @AppStorage("spendingYear") private var year = Calendar.current.component(.year, from: .now)
    @AppStorage("spendingYTD") private var yearToDate = true
    @AppStorage("spendingFullCoverage") private var fullCoverage = true
    @State private var setup: SpendingSetup?
    @State private var data: SpendingAnalysisData?
    @State private var sources: SpendingSources?
    /// Notes from the read-only web page (Feedback tab).
    @State private var notes: [SpendingFeedback] = []
    @State private var problem: String?
    @State private var busy = false
    /// Link and Recipients… (the family page's link and whom Email… and Message… address).
    @State private var linkSettings = false

    static let tabs = [("attribution", "Overview"), ("deepdive", "Deep Dive"), ("curve", "Forward Curve"), ("tax", "Year-End Tax"), ("entries", "Entries"), ("rules", "Rules"),
                       ("family", "Family & Lifecycle"), ("sources", "Sources"), ("admin", "Admin")]
    private static let thisYear = Calendar.current.component(.year, from: .now)

    var body: some View {
        StepPage(store: store, subtitle: "Household spending attribution: like portfolio attribution, for the family's spending — why it changed from last year (prices, more of the same, the children's ages, habits, one-time events) and what the children's ages bring in the next ten years.", lesson: [
            "Every dollar the check register, the credit cards and the expense ledgers spend has two dimensions: a spending category (Food, Housing, Transportation, Education, Activities, Technology, Healthcare, Clothing, Travel) and a primary driver (inflation, family growth, a new activity, a lifecycle transition, a preference change, a one-time event). Rules on expense and target accounts set them; tag a single entry (Philmont as a one-time event) on Entries.",
            "Each category's change splits as in performance attribution: change = inflation + usage + lifecycle + behavior + one-time + taxes. Inflation is last year's spending times the category's CPI change (FRED, in the security master); each driver's effect is what its spending grew beyond inflation. Inflation and lifecycle are the unavoidable part; behavior is habit.",
            "The forward curve stacks each child's lifecycle costs — club sports at 10, a phone at 12, a laptop at 13, tutors at 14, driving at 16, college visits and applications at 16–17, college at 18 — so the waves show three to five years ahead.",
        ], scrollsHorizontally: true) {
            periodBar
            if let sources { sourcesStrip(sources) }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
            }
            HStack(alignment: .center) {
                SpendingTabBar(tabs: Self.tabs + [("feedback", newNotes > 0 ? "Feedback (\(newNotes))" : "Feedback")], selection: $tab)
                Spacer(minLength: 12)
                Menu {
                    Button("Email…") { send(.composeEmail) }
                    Button("Message…") { send(.composeMessage) }
                    Divider()
                    Button("Link and Recipients…") { linkSettings = true }
                } label: {
                    Label("Send Family Link", systemImage: "paperplane")
                }
                .fixedSize()
                .help("Send the family's read-only web page (its link stays the same) by Mail or Messages")
            }
            .sheet(isPresented: $linkSettings) { FamilyLinkSheet() }
            if let setup {
                switch tab {
                case "curve": SpendingCurveTab(setup: setup, data: data) { tab = "family" }
                case "deepdive":
                    if let data {
                        SpendingDeepDiveTab(setup: setup, data: data, entries: shownEntries(data), code: $deepDive,
                                            changed: { replace($0) }, ruleSaved: { applied($0) }, back: { tab = "attribution" })
                    }
                case "entries":
                    if let data { SpendingEntriesTab(setup: setup, data: data, entries: shownEntries(data), changed: { replace($0) }, ruleSaved: { applied($0) }) }
                case "rules":
                    if let data { SpendingRulesTab(setup: setup, data: data, entries: shownEntries(data)) { applied($0) } }
                case "family": SpendingFamilyTab(setup: setup, data: data) { applied($0) }
                case "admin":
                    if let data {
                        SpendingAdminTab(setup: setup, data: data, entries: shownEntries(data), openTab: { tab = $0 }, go: { store.go($0) },
                                         ruleSaved: { applied($0) }, linked: { Task { await reload() } })
                    }
                case "tax": SpendingTaxTab(setup: setup)
                case "feedback":
                    SpendingFeedbackTab(setup: setup, data: data, notes: notes, changed: { notes = $0 }, entryChanged: { replace($0) },
                                        openDeepDive: { openDeepDive($0) }, reload: { Task { await reload() } })
                case "sources":
                    if let sources {
                        SpendingSourcesTab(sources: sources, data: data, yearToDate: yearToDate, fullCoverage: fullCoverage) { updated in
                            self.sources = updated
                            Task { await reload() }
                        }
                    }
                default:
                    if let data { attribution(data, setup) }
                }
            } else if busy {
                ProgressView("Reading the registers…").frame(maxWidth: .infinity)
            }
        }
        .task { await reload() }
        // A target account's link saved here (the Rules tab) or on Banking: the setup brings it.
        .onChange(of: PayeeLinks.shared.version) { Task { await reload() } }
        .quickHelpArea(PortHelp.about(.spending))
    }

    // MARK: Period

    private var periods: (start: String, end: String, priorStart: String, priorEnd: String) {
        let today = Date.now, cal = Calendar.current
        let md = cal.dateComponents([.month, .day], from: today)
        func day(_ y: Int, _ m: Int, _ d: Int) -> String {
            let days = cal.range(of: .day, in: .month, for: cal.date(from: DateComponents(year: y, month: m, day: 1)) ?? today)?.count ?? 28
            return String(format: "%04d-%02d-%02d", y, m, min(d, days))
        }
        let (m, d) = yearToDate ? (md.month ?? 12, md.day ?? 31) : (12, 31)
        return (day(year, 1, 1), day(year, m, d), day(year - 1, 1, 1), day(year - 1, m, d))
    }

    /// The year and its options, and the dates compared with Refresh: on one line, or two when the page is narrow.
    private var periodBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { periodControls; Spacer(); periodStatus }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) { periodControls; Spacer() }
                HStack(spacing: 12) { periodStatus; Spacer() }
            }
        }
        .onChange(of: year) { Task { await reload() } }
        .onChange(of: yearToDate) { Task { await reload() } }
    }

    @ViewBuilder
    private var periodControls: some View {
        Picker("Year", selection: $year) {
            ForEach((Self.thisYear - 5)...Self.thisYear, id: \.self) { y in Text(verbatim: "\(y) vs \(y - 1)").tag(y) }
        }
        .frame(maxWidth: 200)
        Toggle("Year to date", isOn: $yearToDate).toggleStyle(.checkbox)
            .help("Compare January 1 to today's date in both years; off, the whole years")
        Toggle("Only registers covering both years", isOn: $fullCoverage).toggleStyle(.checkbox)
            .help("Leave out the registers whose entries start after the earlier year does: comparing them would count all their spending as growth")
    }

    @ViewBuilder
    private var periodStatus: some View {
        if busy { ProgressView().controlSize(.small) }
        if let data { Text("\(shortDay(data.start)) – \(shortDay(data.end)) vs \(shortDay(data.priorStart)) – \(shortDay(data.priorEnd))").font(.callout).foregroundStyle(.secondary) }
        Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
            .help("Read the registers again")
    }

    private func reload() async {
        busy = true
        defer { busy = false }
        let p = periods
        do {
            async let s = SpendingClient.setup()
            async let d = SpendingClient.analysis(start: p.start, end: p.end, priorStart: p.priorStart, priorEnd: p.priorEnd)
            async let o = SpendingClient.sources(start: p.start, end: p.end, priorStart: p.priorStart, priorEnd: p.priorEnd)
            (setup, data, sources) = try await (s, d, o)
            problem = nil
            // An accounts service from before V039 has no feedback: the rest of the page works without it.
            notes = (try? await SpendingClient.feedback()) ?? notes
        } catch {
            problem = describe(error)
        }
    }

    /// What the analysis reads and how fresh it is, on every tab: the sources included, the newest spending, the last
    /// downloads read and the CPI's last month. Orange when a download or the CPI is overdue.
    private func sourcesStrip(_ o: SpendingSources) -> some View {
        let used = o.sources.filter(\.included)
        let newest = used.compactMap(\.spendingLast).filter { (Freshness.days($0) ?? 0) >= 0 }.max()
        let cards = o.run("card_downloads"), bank = o.run("pnc_bank")
        let cpi = o.table("srm.market_series_value")?.newest
        let stale = Freshness.isStale(newest) || Freshness.isStale(cpi, days: Freshness.staleCPIDays)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: stale ? "exclamationmark.triangle.fill" : "tray.full").foregroundStyle(stale ? .orange : .secondary)
            Text(([
                "Sources: " + (used.isEmpty ? "none" : used.map(\.name).joined(separator: ", "))
                    + (used.count < o.sources.count ? " (\(o.sources.count - used.count) left out)" : ""),
                newest.map { "spending through \(shortDay($0)) (\(Freshness.age($0)))" },
                cards?.finishedAt.map { "cards read \(Freshness.when($0))" },
                bank?.finishedAt.map { "checking downloads read \(Freshness.when($0))" },
                o.amazon?.lastOrder.map { "Amazon orders to \(shortDay($0))" },
                cpi.map { "CPI through \(Freshness.date($0)?.formatted(.dateTime.month(.abbreviated).year()) ?? $0)" },
            ] as [String?]).compactMap { $0 }.joined(separator: " · "))
                .font(.callout).foregroundStyle(stale ? Color.orange : .secondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Sources…") { tab = "sources" }
                .help("Which accounts feed the analysis, where their data comes from, the time window, and how fresh each SRM table is")
        }
        .quickHelpArea(QuickHelpItem(title: "Spending Sources", detail: "The registers the analysis adds up, how recent their spending is, when the card and checking downloads were last read into the security master, and the CPI's latest month. Orange when a register's newest spending is more than \(Freshness.staleDays) days old or the CPI more than \(Freshness.staleCPIDays). Sources… shows each source's folders, files, tables and dates.", symbol: "tray.full"))
    }

    /// A rule, category or family change saved: the entries are resolved again with it.
    private func applied(_ s: SpendingSetup) {
        setup = s
        Task { await reload() }
    }

    private func excluded(_ data: SpendingAnalysisData) -> Set<String> {
        fullCoverage ? Set(SpendingEngine.partialRegisters(data).map { $0.source + ($0.register ?? "") }) : []
    }

    private func shownEntries(_ data: SpendingAnalysisData) -> [SpendingEntry] {
        let out = excluded(data)
        return out.isEmpty ? data.entries : data.entries.filter { !out.contains($0.source + ($0.register ?? "")) }
    }

    private func inCurrent(_ e: SpendingEntry, _ data: SpendingAnalysisData) -> Bool { e.date >= data.start && e.date <= data.end }

    /// An entry tagged on Entries, as the service now resolves it.
    private func replace(_ e: SpendingEntry) {
        guard let i = data?.entries.firstIndex(where: { $0.id == e.id }) else { return }
        data?.entries[i] = e
    }

    private var newNotes: Int { notes.filter { $0.status == "new" }.count }

    /// Opens Mail or Messages with the family page's link and a short note; asks for the link first when it isn't set.
    private func send(_ service: NSSharingService.Name) {
        if let problem = FamilyLink.send(service) {
            if FamilyLink.url == nil { linkSettings = true } else { self.problem = problem }
        }
    }

    /// Opens the Deep Dive tab on a category, by its code or by its name as the charts show it.
    private func openDeepDive(_ nameOrCode: String) {
        guard let setup else { return }
        let code = setup.categories.first { $0.name == nameOrCode || $0.code == nameOrCode }?.code
            ?? (nameOrCode == "Not assigned" || nameOrCode == SpendingEngine.unassigned ? SpendingEngine.unassigned : nil)
        guard let code else { return }
        deepDive = code
        tab = "deepdive"
    }

    // MARK: Attribution

    @ViewBuilder
    private func attribution(_ data: SpendingAnalysisData, _ setup: SpendingSetup) -> some View {
        let rows = SpendingEngine.attribute(data, entries: shownEntries(data), categories: setup.categories)
        let total = SpendingEngine.total(rows)
        let partial = SpendingEngine.partialRegisters(data)
        if !partial.isEmpty {
            Label(partial.map { "\($0.register ?? $0.source) starts \(shortDay($0.first))" }.joined(separator: "; ")
                  + (fullCoverage ? ": left out, as it doesn't cover the earlier year." : ": its earlier-year spending is missing, so its whole spending counts as growth."),
                  systemImage: fullCoverage ? "info.circle" : "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(fullCoverage ? Color.secondary : Color.orange)
        }
        tiles(total)
        if rows.isEmpty {
            ContentUnavailableView("No spending in these periods", systemImage: "chart.bar.xaxis",
                                   description: Text("The check register, credit cards and expense ledgers have no spending entries in either year."))
        } else {
            metricsTable(rows, total)
            HStack(alignment: .top, spacing: 14) {
                waterfall(total)
                effectsChart(rows)
            }
            twoDimensions(data, setup)
            inflationBox(data, setup)
        }
    }

    private func tiles(_ t: CategoryAttribution) -> some View {
        HStack(spacing: 10) {
            MetricTile(title: "Earlier year", value: money(t.prior), help: "Spending in the earlier period, every category.")
            MetricTile(title: "This year", value: money(t.current), help: "Spending in the later period, every category.")
            MetricTile(title: "Change", value: money(t.change), caption: t.growth.map { signedPct($0, 1) } ?? "",
                       tint: t.change > 0 ? .red : .green, help: "This year less the earlier year.")
            MetricTile(title: "Inflation", value: money(t.effect(.inflation)), caption: t.share(.inflation).map { "\(pct($0, 0)) of the change" } ?? "",
                       help: SpendingEffect.inflation.help)
            MetricTile(title: "Lifecycle", value: money(t.effect(.lifecycle)), caption: t.share(.lifecycle).map { "\(pct($0, 0)) of the change" } ?? "",
                       help: SpendingEffect.lifecycle.help)
            MetricTile(title: "Behavior", value: money(t.effect(.behavior)), caption: t.share(.behavior).map { "\(pct($0, 0)) of the change" } ?? "",
                       help: SpendingEffect.behavior.help)
            // Once something is tagged Taxes.
            if abs(t.effect(.taxes)) >= 0.5 {
                MetricTile(title: "Taxes", value: money(t.effect(.taxes)), caption: t.share(.taxes).map { "\(pct($0, 0)) of the change" } ?? "",
                           help: SpendingEffect.taxes.help)
            }
        }
    }

    private func metricsTable(_ rows: [CategoryAttribution], _ total: CategoryAttribution) -> some View {
        Box(title: "Key Metrics by Category", symbol: "tablecells", help: "Each category's spending growth and how much of its change each effect explains (the contributions add to 100% of the change). Inflation and lifecycle are the unavoidable, age-related part; behavior is habit; one-time won't repeat; taxes is what changed with taxes. Usage is more or less of the same things, including spending with no driver assigned.") {
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 5) {
                GridRow {
                    Text("Category").gridColumnAlignment(.leading)
                    Text("Earlier"); Text("This year"); Text("Change"); Text("Growth")
                    ForEach(SpendingEffect.allCases) { e in Text(e.rawValue).foregroundStyle(e.color).help(e.help) }
                    Text("CPI"); Text("Reading").gridColumnAlignment(.leading)
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Divider()
                ForEach(rows) { r in metricsRow(r) }
                Divider()
                metricsRow(total).fontWeight(.semibold)
            }
            .monospacedDigit()
            Text("Contributions are shares of the change: a category whose spending fell shows how much each effect took off. CPI is the category's price change between the years (FRED in the security master; \"assumed\" where it has no values yet).")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func metricsRow(_ r: CategoryAttribution) -> some View {
        GridRow {
            Group {
                if r.code == "TOTAL" {
                    Text(r.name)
                } else {
                    Button(r.name) { openDeepDive(r.code) }
                        .buttonStyle(.link)
                        .foregroundStyle(r.code == SpendingEngine.unassigned ? .secondary : .primary)
                        .help("Deep dive into \(r.name): its entries, the rules and tags that put them here, and what changed")
                        .contextMenu { Button("Deep Dive into \(r.name)") { openDeepDive(r.code) } }
                }
            }
            .gridColumnAlignment(.leading)
            Text(money(r.prior)); Text(money(r.current))
            Text(money(r.change)).foregroundStyle(r.change > 0.5 ? .red : r.change < -0.5 ? .green : .secondary)
            Text(r.growth.map { signedPct($0, 0) } ?? (r.prior.magnitude < 0.005 && r.current > 0 ? "new" : "—"))
            ForEach(SpendingEffect.allCases) { e in Text(r.share(e).map { pct($0, 0) } ?? "—").help(money(r.effect(e))) }
            Text(r.code == "TOTAL" ? signedPct(r.inflationRate, 1) : "\(signedPct(r.inflationRate, 1))\(r.basis == "CPI" ? "" : "*")")
                .foregroundStyle(.secondary).help(r.basis == "CPI" ? "From the CPI" : "Assumed: the CPI series has no values for these months")
            Text(r.reading).gridColumnAlignment(.leading).foregroundStyle(.secondary)
        }
    }

    private func waterfall(_ t: CategoryAttribution) -> some View {
        AttributionWaterfall(t: t, title: "From Last Year to This Year")
    }

    private func effectsChart(_ rows: [CategoryAttribution]) -> some View {
        Box(title: "What Changed Each Category", symbol: "chart.bar.doc.horizontal", help: "Each category's change in dollars, split into its effects: bars to the right added spending, to the left took it off. Right-click (or double-click) a category's bars or name for a deep dive into it.") {
            Chart {
                ForEach(rows) { r in
                    ForEach(SpendingEffect.allCases) { e in
                        BarMark(x: .value("Dollars", r.effect(e)), y: .value("Category", r.name))
                            .foregroundStyle(by: .value("Effect", e.rawValue))
                    }
                }
            }
            .chartForegroundStyleScale(domain: SpendingEffect.allCases.map(\.rawValue), range: SpendingEffect.allCases.map(\.color))
            .chartXAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(money(d)) } } } }
            .chartOverlay { proxy in CategoryChartMenu(proxy: proxy, axis: .vertical) { openDeepDive($0) } }
            .frame(height: max(220, CGFloat(rows.count) * 26 + 40))
        }
    }

    private struct Slice: Identifiable { var category: String; var driver: String; var amount: Double; var id: String { category + driver } }

    private func twoDimensions(_ data: SpendingAnalysisData, _ setup: SpendingSetup) -> some View {
        var sums: [String: Double] = [:]
        for e in shownEntries(data) where inCurrent(e, data) {
            sums[(setup.category(e.category)?.name ?? "Not assigned") + "|" + SpendingDriver.title(e.driver), default: 0] += e.amount
        }
        let slices = sums.map { k, v in
            let p = k.split(separator: "|", maxSplits: 1).map(String.init)
            return Slice(category: p[0], driver: p[1], amount: v)
        }
        let order = setup.categories.map(\.name) + ["Not assigned"]
        let drivers = SpendingDriver.allCases.map(\.title) + ["Not assigned"]
        return Box(title: "This Year by Category and Driver", symbol: "square.stack.3d.up", help: "Both dimensions of every dollar this year: the category it was spent on and its primary driver. Assign drivers with rules (Rules) and tags on single entries (Entries). Right-click (or double-click) a category's bar or its name under the chart for a deep dive into it.") {
            Chart(slices) { s in
                BarMark(x: .value("Category", s.category), y: .value("Dollars", s.amount))
                    .foregroundStyle(by: .value("Driver", s.driver))
            }
            .chartXScale(domain: order.filter { n in slices.contains { $0.category == n } })
            .chartForegroundStyleScale(domain: drivers, range: [Color.orange, .blue, .cyan, .purple, .pink, .indigo, .teal, .brown, .gray.opacity(0.5)])
            .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(money(d)) } } } }
            .chartOverlay { proxy in CategoryChartMenu(proxy: proxy, axis: .horizontal) { openDeepDive($0) } }
            .frame(height: 260)
        }
    }

    private func inflationBox(_ data: SpendingAnalysisData, _ setup: SpendingSetup) -> some View {
        Box(title: "Inflation by Category", symbol: "percent", help: "Each category's price change from the earlier year to this one: the CPI series' months in this period over the same months a year before (FRED, loaded into the security master by srm.py load fred-yields), else the category's assumed rate. Change the series or the assumption on Family & Lifecycle.") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow { Text("Category"); Text("Change"); Text("Basis"); Text("Series") }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(data.inflation, id: \.category) { i in
                    GridRow {
                        Text(setup.category(i.category)?.name ?? i.category)
                        Text(signedPct(i.rate, 1)).monospacedDigit().gridColumnAlignment(.trailing)
                        Text(i.basis == "CPI" ? "CPI, \(i.months) month\(i.months == 1 ? "" : "s") to \(shortDay(i.through))" : "assumed \(pct(i.assumed, 1)) a year")
                            .foregroundStyle(i.basis == "CPI" ? .primary : .secondary)
                        Text(setup.category(i.category)?.cpiName ?? "—").foregroundStyle(.secondary)
                    }
                }
            }
            .font(.callout)
        }
    }
}

// MARK: - Forward curve

private struct SpendingCurveTab: View {
    var setup: SpendingSetup
    var data: SpendingAnalysisData?
    var addChildren: () -> Void
    @AppStorage("spendingCurveBy") private var by = "child"
    @AppStorage("spendingCurveInflate") private var inflate = true
    private let start = Calendar.current.component(.year, from: .now)

    var body: some View {
        if setup.children.isEmpty {
            ContentUnavailableView {
                Label("No children yet", systemImage: "figure.and.child.holdinghands")
            } description: {
                Text("Add the children with their birth years: their ages decide what the lifecycle model brings each year.")
            } actions: {
                Button("Add Children…") { addChildren() }
            }
        } else {
            let rates = Dictionary(uniqueKeysWithValues: (data?.inflation ?? []).map { ($0.category, $0.rate) })
            let points = SpendingEngine.forwardCurve(children: setup.children, triggers: setup.triggers, rates: rates, start: start, inflate: inflate)
            controls
            chart(points)
            waves(points)
            yearTable(points)
            timeline
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Stack by", selection: $by) {
                Text("Child").tag("child"); Text("Category").tag("category")
            }
            .pickerStyle(.segmented).frame(maxWidth: 260)
            Toggle("Grow with inflation", isOn: $inflate).toggleStyle(.checkbox)
                .help("Grow each cost by its category's inflation (this year's CPI change, else the assumption); peak events — high-adventure trips, test prep, application fees — stay in today's dollars, as distance and participation drive them, not prices. Off: everything in today's dollars.")
            Spacer()
        }
    }

    private func chart(_ points: [SpendingEngine.CurvePoint]) -> some View {
        Box(title: "Family Spending Forward Curve", symbol: "chart.bar.fill", help: "The children's lifecycle costs for the next ten years, stacked, from the triggers on Family & Lifecycle: each costs its yearly amount in the years a child is of age for it (a replacement once every few years). The waves are the middle-to-high-school, driving-age and college-prep transitions.") {
            Chart(points) { p in
                BarMark(x: .value("Year", String(p.year)), y: .value("Dollars", p.amount))
                    .foregroundStyle(by: .value(by == "child" ? "Child" : "Category", by == "child" ? p.member : (setup.category(p.category)?.name ?? p.category)))
            }
            .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(money(d)) } } } }
            .frame(height: 300)
        }
    }

    private func waves(_ points: [SpendingEngine.CurvePoint]) -> some View {
        let all = SpendingEngine.waves(points, start: start)
        let soon = all.filter { $0.year >= start + 3 && $0.year <= start + 5 }
        return Box(title: "Waves Ahead", symbol: "water.waves", help: "The years whose lifecycle costs rise most over the year before, and what starts in them. The ones three to five years out are the ones to save for now.") {
            if all.isEmpty {
                Text("No year's costs rise over the year before in the next ten years.").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    if !soon.isEmpty {
                        Text("Three to five years out").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(soon, id: \.year) { w in waveRow(w) }
                        Divider()
                    }
                    Text("Largest rises in the next ten years").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(all.prefix(3), id: \.year) { w in waveRow(w) }
                }
            }
        }
    }

    private func waveRow(_ w: (year: Int, total: Double, rise: Double, starting: [String])) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: "\(w.year)").font(.callout.weight(.semibold)).frame(width: 44, alignment: .leading)
            Text("+\(money(w.rise))").monospacedDigit().foregroundStyle(.red).frame(width: 90, alignment: .trailing)
            Text("to \(money(w.total))").monospacedDigit().foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
            Text(w.starting.isEmpty ? "more of what's already under way" : w.starting.joined(separator: "; "))
                .font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func yearTable(_ points: [SpendingEngine.CurvePoint]) -> some View {
        let kids = setup.children
        return Box(title: "Year by Year", symbol: "calendar", help: "Each year's lifecycle cost per child (with the child's age that year) and in all.") {
            Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Text("Year").gridColumnAlignment(.leading)
                    ForEach(kids) { k in Text(k.name) }
                    Text("Total")
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(start..<(start + 10), id: \.self) { y in
                    let rows = points.filter { $0.year == y }
                    GridRow {
                        Text(verbatim: "\(y)").gridColumnAlignment(.leading)
                        ForEach(kids) { k in
                            let mine = rows.filter { $0.member == k.name }
                            Text("\(money(mine.map(\.amount).reduce(0, +))) (\(k.age(in: y)))")
                                .help(mine.map { "\($0.trigger): \(money($0.amount))" }.joined(separator: "\n"))
                        }
                        Text(money(rows.map(\.amount).reduce(0, +))).fontWeight(.semibold)
                    }
                }
            }
            .monospacedDigit().font(.callout)
        }
    }

    private struct Span: Identifiable { var name: String; var from: Int; var to: Int; var category: String; var id: String { name } }

    private var timeline: some View {
        let spans = setup.triggers.filter(\.active).map { Span(name: $0.name, from: $0.ageFrom, to: $0.ageTo + 1, category: setup.category($0.category)?.name ?? $0.category) }
        return Box(title: "Child Lifecycle Model", symbol: "figure.and.child.holdinghands", help: "What each age brings: the lifecycle triggers by age, with each child's age today marked. Change them on Family & Lifecycle.") {
            Chart {
                ForEach(spans) { s in
                    BarMark(xStart: .value("From age", s.from), xEnd: .value("To age", s.to), y: .value("Trigger", s.name))
                        .foregroundStyle(by: .value("Category", s.category))
                }
                ForEach(setup.children) { k in
                    RuleMark(x: .value("Age", Double(k.age(in: start)) + 0.5))
                        .foregroundStyle(.red)
                        .annotation(position: .top) { Text("\(k.name) \(k.age(in: start))").font(.caption2).foregroundStyle(.red) }
                }
            }
            .chartXScale(domain: 4...23)
            .chartXAxisLabel("Age")
            .frame(height: max(240, CGFloat(spans.count) * 20 + 50))
        }
    }
}

// MARK: - Entries

private struct SpendingEntriesTab: View {
    var setup: SpendingSetup
    var data: SpendingAnalysisData
    var entries: [SpendingEntry]
    var changed: (SpendingEntry) -> Void
    var ruleSaved: (SpendingSetup) -> Void
    /// The one category shown (Deep Dive), without the category picker.
    var lockedCategory: String? = nil
    var title = "Spending Entries"
    @AppStorage("spendingEntriesPeriod") private var period = "current"
    @AppStorage(RowsStepper.key) private var tableRows = RowsStepper.standard
    @State private var onlyUnassigned = false
    @State private var category = ""
    @State private var search = ""
    @State private var selected = Set<SpendingEntry.ID>()
    @State private var tagging: [SpendingEntry]?
    @State private var ruleFor: RuleTarget?
    /// The entries Change Expense Account… is open for.
    @State private var refiling: [SpendingEntry]?
    /// The columns' widths (drag a header's edge), order and visibility, kept across reloads and launches: the Deep
    /// Dive builds a new table for each category, which would otherwise start from the standard widths.
    @AppStorage("spendingEntriesColumns") private var columnsStore = Data()
    @State private var columns = TableColumnCustomization<SpendingEntry>()

    private var shown: [SpendingEntry] {
        let q = search.lowercased()
        return entries.filter { e in
            (period == "both" || (period == "current") == (e.date >= data.start && e.date <= data.end))
                && (!onlyUnassigned || e.driver == nil)
                && ((lockedCategory ?? category).isEmpty || (e.category ?? SpendingEngine.unassigned) == (lockedCategory ?? category))
                && (q.isEmpty || [e.payee, e.description, e.expenseAccount, e.event, e.register, e.amazonItems?.map(\.name).joined(separator: "\n")]
                    .contains { ($0 ?? "").lowercased().contains(q) })
        }
        .sorted { $0.date > $1.date }
    }

    static let text = TableText<SpendingEntry>(
        titles: ["Date", "From", "Payee", "Description", "Bought", "Expense account", "Amount", "Category", "Driver", "Family member", "Event"],
        cells: { e in [e.date, e.register ?? e.sourceTitle, e.payee ?? "", e.description ?? "",
                       (e.amazonItems ?? []).map(\.label).joined(separator: "; "), e.expenseAccount ?? "",
                       String(format: "%.2f", e.amount), e.category ?? "", SpendingDriver.title(e.driver), e.memberId.map(String.init) ?? "", e.event ?? ""] })

    var body: some View {
        let rows = shown
        Box(title: title, symbol: "list.bullet.rectangle", help: "Every spending dollar in the period: checks and debits in an expense account, card charges and credits, and expense-ledger items not already a card or check entry. Each shows its category and driver and where they came from (the entry's own tag, its target account's rule, a statement text rule, its expense account's rule). An Amazon charge matched to its order (Amazon's order export, Sources) shows what was bought. Double-click an entry, or select several and right-click, to tag them — a category, a driver, a family member, an event — to set the rule for their target account, statement text or expense account, or to file them under another expense account (Change Expense Account…), with the charges to come.") {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { entryFilters; Spacer(); entryCount(rows) }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) { entryFilters; Spacer() }
                    HStack(spacing: 10) { Spacer(); entryCount(rows) }
                }
            }
            Table(rows, selection: $selected, columnCustomization: $columns) {
                TableColumn("Date") { e in Text(shortDay(e.date)).monospacedDigit() }.width(min: 70, ideal: 80).customizationID("date")
                TableColumn("From") { e in Text(e.register ?? e.sourceTitle).foregroundStyle(.secondary).help(e.sourceTitle) }.width(min: 60, ideal: 100).customizationID("from")
                TableColumn("Payee") { e in Text(e.payee ?? "").help([e.payee, e.description, e.boughtDetail].compactMap { $0 }.joined(separator: "\n")) }
                    .width(min: 80, ideal: 220, max: 900).customizationID("payee")
                TableColumn("Bought") { e in boughtCell(e) }.width(min: 60, ideal: 200, max: 900).customizationID("bought")
                TableColumn("Expense account") { e in Text(e.expenseAccount ?? "").foregroundStyle(.secondary) }.width(min: 80, ideal: 130).customizationID("account")
                TableColumn("Amount") { e in Text(money2(e.amount)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing) }.width(min: 70, ideal: 90).customizationID("amount")
                TableColumn("Category") { e in
                    Text(setup.category(e.category)?.name ?? "Not assigned").foregroundStyle(e.category == nil ? .secondary : .primary)
                        .help(e.categoryFrom.map { $0 == "statement text" ? "From the statement text rule \"\(e.rulePattern ?? "")\"" : "From the \($0)" } ?? "No rule or tag")
                }.width(min: 80, ideal: 110).customizationID("category")
                TableColumn("Driver") { e in
                    Text(SpendingDriver.title(e.driver)).foregroundStyle(e.driver == nil ? .secondary : .primary)
                        .help(e.driverFrom.map { "From the \($0)" } ?? "No rule or tag: counts as usage")
                }.width(min: 80, ideal: 130).customizationID("driver")
                TableColumn("Family member") { e in Text(setup.member(e.memberId)?.name ?? "").foregroundStyle(.secondary) }.width(min: 60, ideal: 110).customizationID("member")
                TableColumn("Event") { e in
                    HStack(spacing: 3) {
                        if e.tagged { Image(systemName: "tag.fill").font(.caption2).foregroundStyle(.secondary) }
                        Text(e.event ?? "")
                    }
                    .help(e.notes ?? "")
                }.width(min: 60, ideal: 110).customizationID("event")
            }
            .onAppear {
                columns = (try? JSONDecoder().decode(TableColumnCustomization<SpendingEntry>.self, from: columnsStore)) ?? columns
                #if DEBUG
                if lockedCategory == nil, !Self.amazonTestDone, let ids = UserDefaults.standard.string(forKey: "amazonLookupTest") {
                    let wanted = Set(ids.split(separator: ",").map { $0.replacingOccurrences(of: ":", with: "-") })
                    let picked = entries.filter { wanted.contains($0.id) }
                    if !picked.isEmpty { Self.amazonTestDone = true; lookUp(picked, scan: !UserDefaults.standard.bool(forKey: "amazonLookupBrowse")) }
                }
                #endif
            }
            .onChange(of: columns) { columnsStore = (try? JSONEncoder().encode(columns)) ?? columnsStore }
            .tableText()
            .copiesSelectedRows(rows, selected: selected, as: Self.text)
            .contextMenu(forSelectionType: SpendingEntry.ID.self) { ids in
                let picked = rows.filter { ids.contains($0.id) }
                Button(picked.count > 1 ? "Tag \(picked.count) Entries…" : "Tag Entry…") { tagging = picked }.disabled(picked.isEmpty)
                if picked.contains(where: \.tagged) {
                    Button("Clear Tags") { Task { await clear(picked.filter(\.tagged)) } }
                }
                Button(picked.count > 1 ? "Change Expense Account of \(picked.count) Entries…" : "Change Expense Account…") { refiling = picked }
                    .disabled(!picked.contains { $0.source != "ledger" })
                if picked.contains(where: \.isAmazonLookupCharge) {
                    Button(picked.count == 1 ? "Look Up Amazon Order…" : "Look Up Amazon Orders…") { lookUp(picked) }
                        .help("Find what these Amazon charges bought on amazon.com, in a window where you sign in yourself")
                    Button(picked.count == 1 ? "Attach an Amazon Order…" : "Attach Amazon Orders One by One…") { lookUp(picked, scan: false) }
                        .help("Type or paste an order number for a charge, or open the order in the window and attach it")
                }
                if picked.contains(where: { $0.amazonItems != nil }) {
                    Button("Take Amazon Orders Off") { Task { for e in picked where e.amazonItems != nil { await unlink(e) } } }
                }
                if picked.count == 1, let e = picked.first {
                    Divider()
                    if let id = e.payeeId { Button("Rule for Target Account \(e.payee ?? "")…") { ruleFor = RuleTarget(payeeId: id, name: e.payee ?? "") } }
                    if let text = e.rulePattern {
                        Button("Rule for Statement Text \(text)…") { ruleFor = RuleTarget(pattern: text, ruleId: setup.rule(pattern: text)?.id, name: text) }
                    } else {
                        Button("Rule for Statement Text…") { ruleFor = RuleTarget(pattern: e.statementKey, name: e.statementKey) }
                    }
                    if let id = e.expenseAccountId { Button("Rule for Expense Account \(e.expenseAccount ?? "")…") { ruleFor = RuleTarget(expenseAccountId: id, name: e.expenseAccount ?? "") } }
                    if !e.amazonOrderIds.isEmpty {
                        Divider()
                        ForEach(e.amazonOrderIds, id: \.self) { o in
                            Button("Open Amazon Order \(o)") { if let url = AmazonItem.orderURL(o) { NSWorkspace.shared.open(url) } }
                        }
                    }
                }
                Divider()
                CopyRowsButton(rows: rows, ids: ids, text: Self.text)
            } primaryAction: { ids in
                tagging = rows.filter { ids.contains($0.id) }
            }
            .frame(minHeight: PortSettings.shared.tableHeight(rows: min(max(rows.count, 8), tableRows)))
            // The page's width, not the columns' preferred widths: the table narrows its columns (and scrolls them)
            // rather than widening the page.
            .frame(minWidth: 0, maxWidth: .infinity)
        }
        .sheet(isPresented: Binding(get: { tagging != nil }, set: { if !$0 { tagging = nil } })) {
            if let picked = tagging { SpendingTagSheet(setup: setup, entries: picked) { body in await tag(picked, body) } }
        }
        .sheet(item: $ruleFor) { target in
            SpendingRuleSheet(setup: setup, target: target, entries: entries) { ruleSaved($0) }
        }
        .sheet(isPresented: Binding(get: { refiling != nil }, set: { if !$0 { refiling = nil } })) {
            if let picked = refiling { RefileSheet(setup: setup, entries: picked) { ruleSaved($0) } }
        }
    }

    @ViewBuilder
    private var entryFilters: some View {
        Picker("", selection: $period) {
            Text("This year").tag("current"); Text("Earlier year").tag("prior"); Text("Both").tag("both")
        }
        .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 280)
        if lockedCategory == nil {
            Picker("Category", selection: $category) {
                Text("All").tag("")
                ForEach(setup.categories) { c in Text(c.name).tag(c.code) }
                Text("Not assigned").tag(SpendingEngine.unassigned)
            }
            .frame(maxWidth: 220)
        }
        Toggle("No driver yet", isOn: $onlyUnassigned).toggleStyle(.checkbox)
        TextField("Search payee, item bought, event", text: $search).textFieldStyle(.roundedBorder).frame(minWidth: 160, maxWidth: 240)
    }

    @ViewBuilder
    private func entryCount(_ rows: [SpendingEntry]) -> some View {
        Text("\(rows.count) entries, \(money(rows.map(\.amount).reduce(0, +)))").monospacedDigit().foregroundStyle(.secondary)
        RowsStepper(rows: $tableRows)
    }

    private func tag(_ picked: [SpendingEntry], _ body: [String: Any]) async -> String? {
        do {
            for e in picked { if let updated = try await SpendingClient.tag(e, body) { changed(updated) } }
            return nil
        } catch { return describe(error) }
    }

    private func clear(_ picked: [SpendingEntry]) async {
        _ = await tag(picked, [:])
    }

    /// What an Amazon charge bought, as a link to its order on amazon.com: the items and their costs on hover. Edit
    /// Link… looks the charge up again; Remove Link takes its orders off (for good: the export won't match it again).
    @ViewBuilder
    private func boughtCell(_ e: SpendingEntry) -> some View {
        if let bought = e.bought, let order = e.amazonOrderIds.first, let url = AmazonItem.orderURL(order) {
            LinkedWords(link: SecurityLink(address: url.absoluteString, text: bought,
                                           tip: LinkRichText.data(NSAttributedString(string: e.boughtDetail ?? "")),
                                           title: "Amazon order \(e.amazonOrderIds.joined(separator: ", "))"),
                        words: bought, testID: "bought:\(e.id)",
                        edit: { lookUp([e]) }, remove: { Task { await unlink(e) } })
        } else {
            Text("")
        }
    }

    #if DEBUG
    /// Self-tests (-amazonLookupTest card:3601,card:3592): the lookup opens once.
    static var amazonTestDone = false
    #endif

    /// The Amazon Order Lookup for these charges, in its own window; what it attaches comes back to the table.
    private func lookUp(_ picked: [SpendingEntry], scan: Bool = true) {
        AmazonLookupWindow.open(picked, scan: scan) { found in for e in found { changed(e) } }
    }

    private func unlink(_ e: SpendingEntry) async {
        do { if let updated = try await SpendingClient.unlinkAmazon(e) { changed(updated) } } catch { NSSound.beep() }
    }
}

/// What a rule is for: an expense account, a target account or a piece of statement text (V042).
struct RuleTarget: Identifiable {
    var expenseAccountId: Int? = nil
    var payeeId: Int? = nil
    /// Statement text: the rule's, or what a new rule starts from.
    var pattern: String? = nil
    /// The statement text rule being changed, when there is one.
    var ruleId: Int? = nil
    var name: String
    var id: String { "\(expenseAccountId ?? -1)-\(payeeId ?? -1)-\(ruleId ?? -1)-\(pattern ?? "")" }
}

extension PayeeLinkTarget {
    /// A target account on the Rules tab, for its link and the Link dialog.
    init(_ p: SpendingSetup.Named) {
        payeeId = p.id; name = p.name; last4 = p.last4; institution = p.institution; website = p.logonUrl; link = p.link?.link
    }
}

private func null(_ v: Any?) -> Any { v ?? NSNull() }

/// The category, driver and member pickers every rule and tag sheet shows.
private struct DimensionPickers: View {
    var setup: SpendingSetup
    @Binding var category: String
    @Binding var driver: String
    @Binding var member: Int
    var blank = "Keep the rule's"

    var body: some View {
        Picker("Category", selection: $category) {
            Text(blank).tag("")
            ForEach(setup.categories) { c in Text(c.name).tag(c.code) }
        }
        Picker("Driver", selection: $driver) {
            Text(blank).tag("")
            ForEach(SpendingDriver.allCases) { d in Text(d.title).help(d.help).tag(d.rawValue) }
        }
        Picker("Family member", selection: $member) {
            Text(blank).tag(0)
            ForEach(setup.members.filter(\.active)) { m in Text(m.name).tag(m.id) }
        }
    }
}

private struct SpendingTagSheet: View {
    var setup: SpendingSetup
    var entries: [SpendingEntry]
    var save: ([String: Any]) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var category = ""
    @State private var driver = ""
    @State private var member = 0
    @State private var event = ""
    @State private var notes = ""
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(entries.count == 1 ? "Tag Entry" : "Tag \(entries.count) Entries").heading(.heading)
            Text(entries.count == 1 ? "\(shortDay(entries[0].date)) \(entries[0].payee ?? "") \(money2(entries[0].amount))"
                 : "\(entries.count) entries, \(money2(entries.map(\.amount).reduce(0, +)))").foregroundStyle(.secondary)
            if entries.count == 1, let bought = entries[0].boughtDetail {
                Text(bought).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            Form {
                DimensionPickers(setup: setup, category: $category, driver: $driver, member: $member)
                TextField("Event", text: $event, prompt: Text("Philmont 2026, a wedding, a roof repair"))
                TextField("Notes", text: $notes)
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
            else { Text("What is set here overrides the rules for these entries; what is left as the rule's follows them. Nothing set takes the tag off.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    Task {
                        saving = true
                        error = await save(["category": category, "driver": driver, "memberId": member == 0 ? NSNull() : member,
                                            "event": event, "notes": notes])
                        saving = false
                        if error == nil { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction).disabled(saving)
            }
        }
        .padding(18)
        .frame(width: 460)
        .onAppear {
            // One entry's own tag, to change it; several start blank.
            if entries.count == 1, let e = entries.first, e.tagged {
                if e.categoryFrom == "entry" { category = e.category ?? "" }
                if e.driverFrom == "entry" { driver = e.driver ?? "" }
                event = e.event ?? ""; notes = e.notes ?? ""
            }
        }
    }
}

struct SpendingRuleSheet: View {
    var setup: SpendingSetup
    var target: RuleTarget
    /// Both periods' entries, to show what a statement text matches.
    var entries: [SpendingEntry] = []
    var saved: (SpendingSetup) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var category = ""
    @State private var driver = ""
    @State private var member = 0
    @State private var text = ""
    @State private var error: String?

    private var isText: Bool { target.pattern != nil }

    private var rule: SpendingRule? {
        if isText { return target.ruleId.flatMap { id in setup.rules.first { $0.id == id } } ?? target.pattern.flatMap { setup.rule(pattern: $0) } }
        return target.payeeId.flatMap { setup.rule(payee: $0) } ?? target.expenseAccountId.flatMap { setup.rule(expenseAccount: $0) }
    }

    /// The text as the service keeps it: trimmed, single spaces.
    private var trimmed: String { text.split(separator: " ").joined(separator: " ") }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isText ? (rule == nil ? "New Statement Text Rule" : "Statement Text Rule") : "Rule for \(target.name)").heading(.heading)
            Text(explanation).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                if isText { TextField("Statement text", text: $text, prompt: Text("APPLE.COM, NETFLIX, Mac Book")) }
                DimensionPickers(setup: setup, category: $category, driver: $driver, member: $member, blank: "None")
            }
            if isText { matches }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
            HStack {
                if rule != nil { Button("Remove Rule", role: .destructive) { save(remove: true) } }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save(remove: false) }
                    .keyboardShortcut(.defaultAction)
                    // A new text rule with nothing set would be no rule at all.
                    .disabled(isText && (trimmed.count < 3 || (rule == nil && category.isEmpty && driver.isEmpty && member == 0)))
            }
        }
        .padding(18)
        .frame(width: 480)
        .onAppear {
            category = rule?.category ?? ""; driver = rule?.driver ?? ""; member = rule?.memberId ?? 0
            text = rule?.pattern ?? target.pattern ?? ""
        }
    }

    private var explanation: String {
        if isText {
            return "Every entry whose payee, statement name or description contains this text, ignoring case: for the card charges and expense-ledger lines with no target account. A target account's rule or the entry's own tag still wins, and when several texts match, the longest does. Left blank, the expense account's rule decides."
        }
        if target.payeeId != nil { return "Every entry with this target account, unless the entry has a tag of its own. Left blank, the expense account's rule decides." }
        return "Every entry in this expense account, unless its target account's rule, a statement text rule or its own tag says otherwise."
    }

    /// What the text matches in the analysis's two periods, as the service will match it.
    @ViewBuilder
    private var matches: some View {
        let t = trimmed
        if t.count < 3 {
            Text("At least 3 characters.").font(.caption).foregroundStyle(.secondary)
        } else {
            let m = Matches(entries.filter { $0.contains(statement: t) })
            VStack(alignment: .leading, spacing: 2) {
                Text(m.summary)
                ForEach(m.top, id: \.name) { n in Text("\(n.name)  \(money(n.amount))").lineLimit(1) }
                if m.more { Text("…") }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// The entries a text matches: how many, how much, and the names spending most.
    private struct Matches {
        var summary: String
        var top: [(name: String, amount: Double)]
        var more: Bool

        init(_ found: [SpendingEntry]) {
            var byName: [String: Double] = [:]
            for e in found { byName[e.payee ?? e.description ?? "", default: 0] += e.amount }
            let total = found.map(\.amount).reduce(0, +)
            summary = found.isEmpty ? "Matches no entry in the analysis."
                : "Matches \(found.count) \(found.count == 1 ? "entry" : "entries") in the analysis, \(money(total)):"
            top = byName.sorted { $0.value > $1.value }.prefix(4).map { (name: $0.key, amount: $0.value) }
            more = byName.count > top.count
        }
    }

    private func save(remove: Bool) {
        var body: [String: Any] = ["category": remove ? "" : category, "driver": remove ? "" : driver,
                                   "memberId": remove || member == 0 ? NSNull() : member, "notes": remove ? NSNull() : null(rule?.notes)]
        if isText {
            body["pattern"] = remove ? (rule?.pattern ?? trimmed) : trimmed
            body["id"] = null(rule?.id)
        } else {
            body["expenseAccountId"] = null(target.expenseAccountId)
            body["payeeId"] = null(target.payeeId)
        }
        Task {
            do {
                saved(try await SpendingClient.saveRule(body))
                dismiss()
            } catch { self.error = describe(error) }
        }
    }
}

/// Change Expense Account…: files card and check entries under another expense account (the bookkeeping category the
/// registers show) and, unless turned off, what comes next with the same target account or statement name too.
private struct RefileSheet: View {
    var setup: SpendingSetup
    var entries: [SpendingEntry]
    var saved: (SpendingSetup) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var account = 0
    @State private var fileFuture = true
    @State private var targetName = ""
    @State private var error: String?
    @State private var saving = false

    private var changeable: [SpendingEntry] { entries.filter { $0.source != "ledger" } }
    private var loose: [SpendingEntry] { changeable.filter { $0.payeeId == nil } }
    private var targets: [String] { Array(Set(changeable.compactMap { $0.payeeId == nil ? nil : $0.payee })).sorted() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(changeable.count == 1 ? "Change Expense Account" : "Change Expense Account of \(changeable.count) Entries").heading(.heading)
            Text(summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                Picker("Expense account", selection: $account) {
                    Text("Choose…").tag(0)
                    ForEach(setup.expenseAccounts) { a in Text(a.name).tag(a.id) }
                }
                Toggle("Also file future charges under it", isOn: $fileFuture)
                if fileFuture && !loose.isEmpty {
                    TextField("Target account", text: $targetName, prompt: Text("NJM Insurance"))
                }
            }
            Text(futureNote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
            HStack {
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Change") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || account == 0 || (fileFuture && !loose.isEmpty && targetName.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
        .padding(18)
        .frame(width: 500)
        .onAppear {
            // Start from the most common statement words of the entries without a target account.
            targetName = loose.first.map { $0.statementKey.capitalized } ?? ""
        }
    }

    private var summary: String {
        let names = Array(Set(changeable.map { $0.payee ?? $0.description ?? "" })).sorted()
        var s = "\(changeable.count) \(changeable.count == 1 ? "entry" : "entries"), \(money2(changeable.map(\.amount).reduce(0, +))): "
            + names.prefix(3).joined(separator: "; ") + (names.count > 3 ? "; …" : "")
        let now = Set(changeable.compactMap(\.expenseAccount))
        if !now.isEmpty { s += ". Filed under \(now.sorted().joined(separator: ", ")) now." }
        let ledger = entries.count - changeable.count
        if ledger > 0 { s += " \(ledger) expense-ledger \(ledger == 1 ? "entry takes" : "entries take") its budget line's expense account and won't change." }
        return s
    }

    private var futureNote: String {
        guard fileFuture else { return "Only these entries change; the next charges come in as before." }
        var parts: [String] = []
        if !targets.isEmpty { parts.append("Their target account\(targets.count == 1 ? "" : "s") (\(targets.joined(separator: ", "))) will be filed under it, so new entries with \(targets.count == 1 ? "it" : "them") are too.") }
        if !loose.isEmpty { parts.append("The entries with no target account get this one, with their statement names, so the card and checking downloads post the next charges to it, under this expense account. It shows on Banking ▸ Target Accounts.") }
        return parts.joined(separator: " ")
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            saved(try await SpendingClient.changeExpenseAccount(changeable, to: account, fileFuture: fileFuture, targetName: targetName))
            dismiss()
        } catch { self.error = describe(error) }
    }
}

// MARK: - Rules

private struct SpendingRulesTab: View {
    var setup: SpendingSetup
    var data: SpendingAnalysisData
    /// Both periods' entries (of the registers shown), for each rule's spending.
    var entries: [SpendingEntry]
    var saved: (SpendingSetup) -> Void
    @State private var search = ""
    @State private var showAll = false
    @AppStorage("spendingOnlyRules") private var onlyRules = false
    @State private var editing: RuleTarget?
    /// The statement text rule whose Link dialog is open.
    @State private var linking: SpendingRule?
    /// New Expense Account… (.some(nil)) or Edit Expense Account… (.some(account)).
    @State private var accountEditing: SpendingSetup.Named??
    @State private var accountRemoving: SpendingSetup.Named?
    @State private var problem: String?

    private var year: String { String(data.start.prefix(4)) }
    private var priorYear: String { String(data.priorStart.prefix(4)) }

    /// Spending in the earlier period and in this one.
    private struct Spent {
        var before = 0.0
        var now = 0.0
        /// Entries in either period.
        var count = 0
        var any: Bool { abs(before) >= 0.005 || abs(now) >= 0.005 }
    }

    private func spent<K: Hashable>(by key: (SpendingEntry) -> K?) -> [K: Spent] {
        var out: [K: Spent] = [:]
        for e in entries {
            guard let k = key(e) else { continue }
            if e.date >= data.start && e.date <= data.end { out[k, default: Spent()].now += e.amount; out[k]!.count += 1 }
            else if e.date >= data.priorStart && e.date <= data.priorEnd { out[k, default: Spent()].before += e.amount; out[k]!.count += 1 }
        }
        return out
    }

    var body: some View {
        if let problem { Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
        let byAccount = spent { $0.expenseAccountId }
        Box(title: "Expense Account Rules", symbol: "briefcase", help: "The category, primary driver and family member of each expense account's spending: the default for every entry in it. A target account's rule, a statement text rule, or an entry's own tag overrides it. Changes save as you pick, and the entries and attribution follow them. New Expense Account… adds one (Home Office, Studio); right-click one to edit or remove it.") {
            HStack {
                Button("New Expense Account…") { accountEditing = .some(nil) }
                Spacer()
                Text("\(setup.expenseAccounts.count) expense accounts").foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                header("Expense account", trailing: false)
                ForEach(setup.expenseAccounts) { a in
                    ruleRow(label: accountLabel(a), spent: byAccount[a.id] ?? Spent(), rule: setup.rule(expenseAccount: a.id),
                            target: ["expenseAccountId": a.id], blank: "None")
                }
            }
        }
        .sheet(isPresented: Binding(get: { accountEditing != nil }, set: { if !$0 { accountEditing = nil } })) {
            ExpenseAccountEditor(setup: setup, account: accountEditing ?? nil) { saved($0) }
        }
        .sheet(item: $accountRemoving) { a in RemoveExpenseAccountSheet(setup: setup, account: a) { saved($0) } }
        targetBox(spent { $0.payeeId })
            .sheet(item: $linking) { r in
                LinkSheet(subject: r.pattern ?? "", detail: "Statement text rule", initial: r.link?.link, words: r.pattern ?? "",
                          whereKept: "Kept in the security master with the statement text rule: it shows on its text on Spending Analysis's Rules tab.") { link in
                    await saveLink(link, for: r)
                }
            }
        textBox(spent { $0.rulePattern?.lowercased() })
            .sheet(item: $editing) { t in SpendingRuleSheet(setup: setup, target: t, entries: entries) { saved($0) } }
    }

    // MARK: Target accounts

    private func targetBox(_ byPayee: [Int: Spent]) -> some View {
        let q = search.lowercased()
        let payees = setup.payees.filter { p in
            let ruled = setup.rule(payee: p.id) != nil
            return (ruled || byPayee[p.id]?.any == true) && (!onlyRules || ruled) && (q.isEmpty || p.name.lowercased().contains(q))
        }
        .sorted { a, b in
            let ra = setup.rule(payee: a.id) != nil, rb = setup.rule(payee: b.id) != nil
            if ra != rb { return ra }
            let sa = byPayee[a.id] ?? Spent(), sb = byPayee[b.id] ?? Spent()
            return sa.now != sb.now ? sa.now > sb.now : sa.before > sb.before
        }
        let ruled = payees.filter { setup.rule(payee: $0.id) != nil }.count
        return Box(title: "Target Account Rules", symbol: "arrow.left.arrow.right.square", help: "Rules for single target accounts — a tutoring service as Education, Lifecycle Transition, for one child; a scout council as Activities — overriding their expense account's rule and any statement text rule. Listed: the target accounts with a rule first (✕ removes one), then those with spending in either year, most spent this year first. Pick a category, driver or member on a row to give it a rule; \"Account's\" leaves the expense account's rule in charge. Only entries linked to a target account have one: Discover's charges and expense-ledger lines don't, so they take Statement Text Rules. A name with a link (made here or on Banking) opens it, and the pointer resting on it shows its hover card; on other names it shows the account's details. Right-click a name to add or edit its link or its rule.") {
            HStack {
                TextField("Search target accounts", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Toggle("Only rules", isOn: $onlyRules).toggleStyle(.checkbox)
                Spacer()
                Text("\(ruled) with a rule · \(payees.count) target accounts").foregroundStyle(.secondary)
            }
            if payees.isEmpty {
                Text(onlyRules && q.isEmpty ? "No target account has a rule yet. Turn off Only rules and pick a category, driver or member on one." : "No target account matches.")
                    .foregroundStyle(.secondary).font(.callout)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    header("Target account", trailing: true)
                    ForEach(showAll ? payees : Array(payees.prefix(40))) { p in
                        let rule = setup.rule(payee: p.id)
                        ruleRow(label: targetLabel(p, rule: rule), spent: byPayee[p.id] ?? Spent(), rule: rule, target: ["payeeId": p.id],
                                blank: "Account's", trailing: true)
                    }
                }
            }
            if payees.count > 40 {
                Button(showAll ? "Show the first 40" : "Show all \(payees.count)") { showAll.toggle() }
            }
        }
    }

    // MARK: Statement text

    private func textBox(_ byText: [String: Spent]) -> some View {
        let rules = setup.textRules.sorted { a, b in
            let sa = byText[a.pattern?.lowercased() ?? ""] ?? Spent(), sb = byText[b.pattern?.lowercased() ?? ""] ?? Spent()
            return sa.now != sb.now ? sa.now > sb.now : (a.pattern ?? "").lowercased() < (b.pattern ?? "").lowercased()
        }
        // Statement names with no target account and no statement text rule, most spent first: where a rule can go.
        var open: [String: Spent] = [:]
        for e in entries where e.payeeId == nil && e.rulePattern == nil {
            if e.date >= data.start && e.date <= data.end { open[e.statementKey, default: Spent()].now += e.amount }
            else if e.date >= data.priorStart && e.date <= data.priorEnd { open[e.statementKey, default: Spent()].before += e.amount }
        }
        let names = open.sorted { $0.value.now + $0.value.before > $1.value.now + $1.value.before }.prefix(15)
        return Box(title: "Statement Text Rules", symbol: "text.magnifyingglass", help: "Rules for a piece of statement text, for the entries with no target account: Discover's charges and expense-ledger lines carry only the statement's words. Every entry whose payee, statement name or description contains the text (ignoring case) takes the rule, unless its target account's rule or its own tag says otherwise; when several texts match, the longest wins. Listed: the rules, most spent this year first (✎ changes the text, ✕ removes the rule), and the largest statement names no rule reaches yet. Right-click a text to add or edit its link (a web page, an email address or a page in MxNoteONE, with hover text of its own) or its rule; with a link, a click opens it and the pointer resting on it shows its hover card.") {
            HStack {
                Button("Add Statement Text Rule…") { editing = RuleTarget(pattern: "", name: "") }
                Spacer()
                Text("\(rules.count) \(rules.count == 1 ? "rule" : "rules")").foregroundStyle(.secondary)
            }
            if rules.isEmpty {
                Text("No statement text rule yet. Discover's charges and expense-ledger lines have no target account, so a rule for their text (APPLE.COM, NETFLIX, Mac Book) is how to give them a category, driver or member of their own.")
                    .foregroundStyle(.secondary).font(.callout).fixedSize(horizontal: false, vertical: true)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    header("Statement text", trailing: true)
                    ForEach(rules) { r in
                        let text = r.pattern ?? "", s = byText[text.lowercased()] ?? Spent()
                        ruleRow(label: textLabel(r, spent: s), spent: s, rule: r, target: ["pattern": text, "id": r.id],
                                blank: "Account's", trailing: true, edit: RuleTarget(pattern: text, ruleId: r.id, name: text))
                    }
                }
            }
            if !names.isEmpty {
                DisclosureGroup("Largest statement names no rule reaches") {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        GridRow {
                            Text("Statement text"); Text(priorYear).gridColumnAlignment(.trailing); Text(year).gridColumnAlignment(.trailing); Text("")
                        }
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(Array(names), id: \.key) { n in
                            GridRow {
                                Text(n.key).lineLimit(1)
                                Text(money(n.value.before)).monospacedDigit().foregroundStyle(.secondary)
                                Text(money(n.value.now)).monospacedDigit().foregroundStyle(.secondary)
                                Button("Add Rule…") { editing = RuleTarget(pattern: n.key, name: n.key) }.controlSize(.small)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    // MARK: Names: links, hover text, right-click

    /// An expense account's name: its description on hover; right-click edits or removes it.
    private func accountLabel(_ a: SpendingSetup.Named) -> some View {
        Text(a.name).lineLimit(1)
            .help([a.description, "Right-click to edit or remove it."].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"))
            .textSelection(.disabled)
            .contextMenu {
                Button("Edit Expense Account…") { accountEditing = .some(a) }
                Button("Remove Expense Account…") { accountRemoving = a }
            }
    }

    /// A target account's name: its link when it has one (a click opens it, the pointer resting on it shows the hover
    /// card), else its details on hover; right-click adds or edits the link and the rule.
    private func targetLabel(_ p: SpendingSetup.Named, rule: SpendingRule?) -> some View {
        let t = PayeeLinkTarget(p)
        return Group {
            if let link = t.link {
                PayeeLinks.shared.words(t, link: link, testID: "rules-payee:\(p.id)")
            } else {
                Text(p.name).lineLimit(1).fontWeight(rule != nil ? .semibold : .regular).help(targetTip(p, rule: rule))
            }
        }
        // Not selectable text (the screen's is): a right-click brings up this menu, not the text menu (Copy, Look Up),
        // as on Banking's target accounts.
        .textSelection(.disabled)
        .contextMenu {
            payeeLinkMenu(t)
            Divider()
            Button(rule == nil ? "Add Rule for \(p.name)…" : "Edit Rule for \(p.name)…") { editing = RuleTarget(payeeId: p.id, name: p.name) }
            if rule != nil { Button("Remove Rule") { remove(["payeeId": p.id]) } }
        }
    }

    private func targetTip(_ p: SpendingSetup.Named, rule: SpendingRule?) -> String {
        var lines = [p.name]
        let bank = [p.institution, p.last4.map { "account ending \($0)" }].compactMap { $0 }.filter { !$0.isEmpty }
        if !bank.isEmpty { lines.append(bank.joined(separator: " · ")) }
        if let n = p.nickname, !n.isEmpty { lines.append("Known as \(n)") }
        if let a = setup.expenseAccounts.first(where: { $0.id == p.expenseAccountId }) { lines.append("Filed under \(a.name)") }
        if let n = p.notes, !n.isEmpty { lines.append(n) }
        lines.append(ruleTip(rule))
        lines.append("Right-click to add a link, with hover text of its own.")
        return lines.joined(separator: "\n")
    }

    /// A statement text: its link when it has one, else what it matches on hover; right-click adds or edits the link
    /// and the rule.
    private func textLabel(_ r: SpendingRule, spent: Spent) -> some View {
        let text = r.pattern ?? ""
        return Group {
            if let link = r.link?.link {
                LinkedWords(link: link, words: text, testID: "rules-text:\(r.id)",
                            edit: { LinkHover.shared.close(); linking = r },
                            remove: { Task { _ = await saveLink(nil, for: r) } })
            } else {
                Text(text).lineLimit(1).fontWeight(.semibold)
                    .help("Every entry whose payee, statement name or description contains \u{201C}\(text)\u{201D}, ignoring case: \(spent.count) \(spent.count == 1 ? "entry" : "entries") in the two years.\n\(ruleTip(r))\nRight-click to add a link, with hover text of its own.")
            }
        }
        .textSelection(.disabled)
        .contextMenu {
            Button(r.link == nil ? "Add Link to \(text)…" : "Edit Link on \(text)…") { linking = r }
            if let url = r.link?.link.url { Button("Open Link") { LinkInfo.follow(url) } }
            Divider()
            Button("Edit Rule…") { editing = RuleTarget(pattern: text, ruleId: r.id, name: text) }
            Button("Remove Rule") { remove(["pattern": text, "id": r.id]) }
        }
    }

    /// What a rule says and who changed it last.
    private func ruleTip(_ rule: SpendingRule?) -> String {
        guard let r = rule else { return "No rule: its expense account's rule decides." }
        let says = [setup.category(r.category)?.name, r.driver.map { SpendingDriver.title($0) }, setup.member(r.memberId)?.name].compactMap { $0 }
        return "Rule: " + (says.isEmpty ? "nothing set" : says.joined(separator: " · ")) + (r.updatedBy.map { ", last changed by \($0)" } ?? "")
    }

    private func saveLink(_ link: SecurityLink?, for r: SpendingRule) async -> String? {
        do {
            saved(try await SpendingClient.saveRuleLink(r.id, link))
            return nil
        } catch { return describe(error) }
    }

    /// Takes a rule off: nothing set removes it.
    private func remove(_ target: [String: Any]) {
        var body = target
        body["category"] = ""; body["driver"] = ""; body["memberId"] = NSNull(); body["notes"] = NSNull()
        Task {
            do { saved(try await SpendingClient.saveRule(body)); problem = nil } catch { problem = describe(error) }
        }
    }

    // MARK: Rows

    private func header(_ title: String, trailing: Bool) -> some View {
        GridRow {
            Text(title); Text(priorYear).gridColumnAlignment(.trailing); Text(year).gridColumnAlignment(.trailing)
            Text("Category"); Text("Driver"); Text("Family member")
            if trailing { Text("") }
        }
        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }

    /// One account's or text's rule, changed as its pickers are; `trailing` adds ✎ (with `edit`) and ✕ (with a rule).
    private func ruleRow<Label: View>(label: Label, spent: Spent, rule: SpendingRule?, target: [String: Any], blank: String,
                                      trailing: Bool = false, edit: RuleTarget? = nil) -> some View {
        func save(category: String? = nil, driver: String? = nil, member: Int?? = nil) {
            var body = target
            body["category"] = category ?? rule?.category ?? ""
            body["driver"] = driver ?? rule?.driver ?? ""
            body["memberId"] = null(member ?? rule?.memberId)
            body["notes"] = null(rule?.notes)
            Task {
                do { saved(try await SpendingClient.saveRule(body)); problem = nil } catch { problem = describe(error) }
            }
        }
        return GridRow {
            label
            Text(money(spent.before)).monospacedDigit().foregroundStyle(.secondary)
            Text(money(spent.now)).monospacedDigit().foregroundStyle(.secondary)
            Picker("", selection: Binding(get: { rule?.category ?? "" }, set: { save(category: $0) })) {
                Text(blank).tag("")
                ForEach(setup.categories) { c in Text(c.name).tag(c.code) }
            }
            .labelsHidden().frame(width: 150)
            Picker("", selection: Binding(get: { rule?.driver ?? "" }, set: { save(driver: $0) })) {
                Text(blank).tag("")
                ForEach(SpendingDriver.allCases) { d in Text(d.title).tag(d.rawValue) }
            }
            .labelsHidden().frame(width: 170)
            Picker("", selection: Binding(get: { rule?.memberId ?? 0 }, set: { save(member: .some($0 == 0 ? nil : $0)) })) {
                Text("—").tag(0)
                ForEach(setup.members.filter(\.active)) { m in Text(m.name).tag(m.id) }
            }
            .labelsHidden().frame(width: 120)
            .help(setup.members.isEmpty ? "No family member yet: add them on Family & Lifecycle" : "The family member this spending is for")
            if trailing {
                HStack(spacing: 2) {
                    if let edit {
                        Button { editing = edit } label: { Image(systemName: "pencil") }
                            .buttonStyle(.borderless).help("Change the text, see what it matches")
                    }
                    if rule != nil {
                        Button { remove(target) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                            .help(edit == nil ? "Remove this rule: its entries follow their statement text and expense account's rules again"
                                  : "Remove this rule: its entries follow their expense account's rule again")
                    }
                }
            }
        }
    }
}

// MARK: - Family & lifecycle

private struct SpendingFamilyTab: View {
    var setup: SpendingSetup
    var data: SpendingAnalysisData?
    var saved: (SpendingSetup) -> Void
    @State private var member: HouseholdMember??
    @State private var trigger: LifecycleTrigger??
    @State private var removingMember: HouseholdMember?
    @State private var removingTrigger: LifecycleTrigger?
    @State private var problem: String?
    private let year = Calendar.current.component(.year, from: .now)

    var body: some View {
        if let problem { Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
        Box(title: "Family", symbol: "person.3", help: "The family, kept in the security master: each child's birth year decides the lifecycle triggers their age brings (the forward curve); any member can be given spending (rules and tags).") {
            HStack {
                Button("Add Family Member…") { member = .some(nil) }
                Spacer()
            }
            if setup.members.isEmpty {
                Text("No one yet. Add the children with their birth years.").foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow { Text("Name"); Text("Relation"); Text("Born"); Text("Age"); Text("Grade"); Text("") }
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(setup.members) { m in
                        GridRow {
                            Text(m.name).foregroundStyle(m.active ? .primary : .secondary)
                            Text(m.relation.capitalized)
                            Text(verbatim: m.birthMonth.map { "\($0)/\(m.birthYear)" } ?? "\(m.birthYear)")
                            Text("\(m.age(in: year))").monospacedDigit()
                            Text(m.isChild ? Self.grade(m.age(in: year)) : "").foregroundStyle(.secondary)
                            HStack {
                                Button("Edit…") { member = .some(m) }
                                Button("Remove…") { removingMember = m }
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
        Box(title: "Lifecycle Triggers", symbol: "figure.and.child.holdinghands", help: "What a child's age brings and costs a year in today's dollars: club sports at 10–12, a phone at 12 (every 3 years), a laptop at 13 (every 4), tutors at 14–16, test prep at 16, driving at 15–18, college visits at 16–17, applications at 17, college from 18. Peak events (high-adventure trips, test prep, applications) are tracked apart: distance, participation and age drive them, not prices. Set the amounts to what your family expects.") {
            HStack {
                Button("Add Trigger…") { trigger = .some(nil) }
                Spacer()
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow { Text("Trigger"); Text("Category"); Text("Kind"); Text("Ages"); Text("A year").gridColumnAlignment(.trailing); Text("") }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(setup.triggers) { t in
                    GridRow {
                        Text(t.name).foregroundStyle(t.active ? .primary : .secondary).help(t.notes ?? "")
                        Text(setup.category(t.category)?.name ?? t.category)
                        Text(t.kind.capitalized).foregroundStyle(.secondary)
                        Text(t.ages)
                        Text(money(t.annualCost)).monospacedDigit()
                        HStack {
                            Button("Edit…") { trigger = .some(t) }
                            Button("Remove…") { removingTrigger = t }
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        Box(title: "Categories and Inflation", symbol: "percent", help: "The CPI series each category's inflation follows (FRED, in the security master) and the rate assumed when the series has no values for the months compared.") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow { Text("Category"); Text("CPI series"); Text("Assumed a year"); Text("This year") }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(setup.categories) { c in
                    GridRow {
                        Text(c.name)
                        Picker("", selection: Binding(get: { c.cpiSeries ?? "" }, set: { v in
                            Task { await run { try await SpendingClient.saveCategory(c.code, ["cpiSeries": v, "assumedInflation": c.assumedInflation]) } }
                        })) {
                            Text("None").tag("")
                            ForEach(setup.cpiSeries) { s in Text(s.name).tag(s.code) }
                        }
                        .labelsHidden().frame(width: 300)
                        AssumedRateField(rate: c.assumedInflation) { v in
                            Task { await run { try await SpendingClient.saveCategory(c.code, ["cpiSeries": c.cpiSeries ?? "", "assumedInflation": v]) } }
                        }
                        let i = data?.inflation.first { $0.category == c.code }
                        Text(i.map { "\(signedPct($0.rate, 1)) (\($0.basis))" } ?? "—").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
        }
        .confirmationDialog("Remove \(removingMember?.name ?? "")?", isPresented: Binding(get: { removingMember != nil }, set: { if !$0 { removingMember = nil } }),
                            presenting: removingMember) { m in
            Button("Remove", role: .destructive) { Task { await run { try await SpendingClient.deleteMember(m.id) } } }
        } message: { _ in
            Text("Their rules and tags keep their category and driver but no longer name a family member, and the forward curve leaves them out. To keep them but leave them out, edit them and turn Active off.")
        }
        .confirmationDialog("Remove the trigger \(removingTrigger?.name ?? "")?", isPresented: Binding(get: { removingTrigger != nil }, set: { if !$0 { removingTrigger = nil } }),
                            presenting: removingTrigger) { t in
            Button("Remove", role: .destructive) { Task { await run { try await SpendingClient.deleteTrigger(t.id) } } }
        } message: { _ in
            Text("The forward curve no longer counts it. To keep it but leave it out, edit it and turn Active off.")
        }
        .sheet(isPresented: Binding(get: { member != nil }, set: { if !$0 { member = nil } })) {
            MemberSheet(member: member ?? nil) { id, body in
                do { saved(try await SpendingClient.saveMember(id, body)); return nil } catch { return describe(error) }
            }
        }
        .sheet(isPresented: Binding(get: { trigger != nil }, set: { if !$0 { trigger = nil } })) {
            TriggerSheet(trigger: trigger ?? nil, categories: setup.categories) { id, body in
                do { saved(try await SpendingClient.saveTrigger(id, body)); return nil } catch { return describe(error) }
            }
        }
    }

    static func grade(_ age: Int) -> String {
        switch age {
        case ..<5: "Preschool"
        case 5: "Kindergarten"
        case 6...17: "Grade \(age - 5)"
        case 18...21: "College year \(age - 17)"
        default: ""
        }
    }

    private func run(_ action: () async throws -> SpendingSetup) async {
        do { saved(try await action()); problem = nil } catch { problem = describe(error) }
    }
}

/// A category's assumed inflation, as a percent; saved when the field is submitted.
private struct AssumedRateField: View {
    var rate: Double
    var save: (Double) -> Void
    @State private var text = ""

    var body: some View {
        TextField("", text: $text)
            .frame(width: 70).multilineTextAlignment(.trailing)
            .onAppear { text = String(format: "%.1f%%", rate * 100) }
            .onSubmit {
                if let v = Double(text.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) { save(v / 100) }
            }
            .help("Type a yearly rate in percent and press Return")
    }
}

private struct MemberSheet: View {
    var member: HouseholdMember?
    var save: (Int, [String: Any]) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var relation = "child"
    @State private var birthYear = Calendar.current.component(.year, from: .now) - 10
    @State private var birthMonth = 0
    @State private var notes = ""
    @State private var active = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(member == nil ? "Add Family Member" : "Edit \(member!.name)").heading(.heading)
            Form {
                TextField("Name", text: $name)
                Picker("Relation", selection: $relation) { Text("Child").tag("child"); Text("Adult").tag("adult") }
                TextField("Birth year", value: $birthYear, format: .number.grouping(.never))
                Picker("Birth month", selection: $birthMonth) {
                    Text("—").tag(0)
                    ForEach(1...12, id: \.self) { m in Text(Calendar.current.monthSymbols[m - 1]).tag(m) }
                }
                TextField("Notes", text: $notes)
                Toggle("Active", isOn: $active)
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
            else { Text("A child's age this year is the year less the birth year: it decides the lifecycle triggers in the forward curve.").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    Task {
                        var body: [String: Any] = ["name": name, "relation": relation, "birthYear": birthYear,
                                                   "birthMonth": birthMonth == 0 ? NSNull() : birthMonth, "notes": notes, "active": active]
                        if let member { body["version"] = member.version }
                        error = await save(member?.id ?? 0, body)
                        if error == nil { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 420)
        .onAppear {
            guard let m = member else { return }
            name = m.name; relation = m.relation; birthYear = m.birthYear; birthMonth = m.birthMonth ?? 0
            notes = m.notes ?? ""; active = m.active
        }
    }
}

private struct TriggerSheet: View {
    var trigger: LifecycleTrigger?
    var categories: [SpendingCategory]
    var save: (Int, [String: Any]) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var category = "EDUCATION"
    @State private var kind = "recurring"
    @State private var ageFrom = 14
    @State private var ageTo = 16
    @State private var everyYears = 0
    @State private var annualCost = 1000.0
    @State private var notes = ""
    @State private var active = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(trigger == nil ? "Add Lifecycle Trigger" : "Edit \(trigger!.name)").heading(.heading)
            Form {
                TextField("Name", text: $name)
                Picker("Category", selection: $category) { ForEach(categories) { c in Text(c.name).tag(c.code) } }
                Picker("Kind", selection: $kind) {
                    Text("Recurring: every year in the ages").tag("recurring")
                    Text("Replacement: once every few years").tag("replacement")
                    Text("Peak event: not inflation-driven").tag("peak")
                    Text("Transition: a new stage").tag("transition")
                }
                Stepper("From age \(ageFrom)", value: $ageFrom, in: 0...30)
                Stepper("To age \(ageTo)", value: $ageTo, in: ageFrom...30)
                Stepper(everyYears <= 1 ? "Every year" : "Every \(everyYears) years", value: $everyYears, in: 0...10)
                TextField("Cost a year (today's dollars)", value: $annualCost, format: .currency(code: "USD"))
                TextField("Notes", text: $notes)
                Toggle("Active", isOn: $active)
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    Task {
                        error = await save(trigger?.id ?? 0, ["name": name, "category": category, "kind": kind, "ageFrom": ageFrom,
                                                             "ageTo": max(ageTo, ageFrom), "everyYears": everyYears <= 1 ? NSNull() : everyYears,
                                                             "annualCost": annualCost, "notes": notes, "active": active])
                        if error == nil { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 460)
        .onAppear {
            guard let t = trigger else { return }
            name = t.name; category = t.category; kind = t.kind; ageFrom = t.ageFrom; ageTo = t.ageTo
            everyYears = t.everyYears ?? 0; annualCost = t.annualCost; notes = t.notes ?? ""; active = t.active
        }
    }
}

// MARK: - Sources

private struct SpendingSourcesTab: View {
    var sources: SpendingSources
    var data: SpendingAnalysisData?
    var yearToDate: Bool
    var fullCoverage: Bool
    var changed: (SpendingSources) -> Void
    @State private var problem: String?
    @State private var saving: String?
    @State private var loadingAmazon = false

    var body: some View {
        if let problem { Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
        window
        Box(title: "Spending Sources", symbol: "tray.full", help: "Each checking account, credit card and expense ledger that can feed the analysis: whether it does (the checkbox, kept in the security master for every Mac), where its data comes from (the drop folder and the downloads in it, or entries made by hand), the SRM tables it lands in, when it was last imported and edited, and what it spent in both periods.") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(sources.sources.enumerated()), id: \.element.id) { i, s in
                    if i > 0 { Divider() }
                    sourceRow(s)
                }
            }
        }
        if let a = sources.amazon { amazonBox(a) }
        tablesBox
        loadsBox
    }

    // MARK: Amazon's order export

    private func amazonBox(_ a: AmazonOrders) -> some View {
        let y = String(sources.start.prefix(4))
        return Box(title: "Amazon Orders", symbol: "shippingbox", help: "What was bought behind the Amazon charges. Amazon has no way for a program to read a personal account's orders, so they come from Amazon's own export: amazon.com ▸ Account ▸ Request Your Data ▸ Your Orders. When Amazon's e-mail arrives, download the zip and import it here (Import Export…), or drop it in the folder below and press Read Again. srm.py load amazon-orders reads its orders, shipments and items (not addresses or gift messages) and matches each Amazon charge to the shipment it paid for — Amazon charges the card when a shipment leaves, for its items and their tax — or to a whole order, and each credit to the item returned, by amount and date. The Entries tab then shows what each charge bought.") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                GridRow {
                    Text("Comes from").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Amazon's Request Your Data ▸ Your Orders export — the zip as downloaded, or its Retail.OrderHistory CSV files — read by srm.py load \(a.loader)\(a.foldersListed ? " from:" : "")")
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(a.dropFolders ?? [], id: \.self) { f in Text("\(f)/").font(.callout.monospaced()).textSelection(.enabled) }
                        if a.foldersListed && a.downloads.isEmpty {
                            Text("No export there now.").foregroundStyle(.secondary)
                        }
                        ForEach(a.downloads.prefix(4), id: \.path) { d in
                            HStack(spacing: 6) {
                                Image(systemName: "doc.zipper").foregroundStyle(.secondary)
                                Text(d.path).font(.callout.monospaced()).textSelection(.enabled)
                                Text("\(Freshness.when(d.modified)) · \(ByteCountFormatter.string(fromByteCount: Int64(d.bytes), countStyle: .file))").foregroundStyle(.secondary)
                            }
                        }
                        if a.downloads.count > 4 { Text("and \(a.downloads.count - 4) older").foregroundStyle(.secondary) }
                    }
                }
                GridRow {
                    Text("Lands in").foregroundStyle(.secondary)
                    Text("srm.amazon_order (\(a.orders.formatted()) orders\(a.firstOrder.map { ", \(shortDay($0)) – \(shortDay(a.lastOrder))" } ?? "")) → srm.amazon_shipment, srm.amazon_item (\(a.items.formatted()) items) → srm.amazon_match (each charge's shipment or order) → srm.v_amazon_charge (what each entry bought)")
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                GridRow {
                    Text("Last import").foregroundStyle(.secondary)
                    if let r = a.lastImport {
                        Text("\(Freshness.when(r.finishedAt)) (\(Freshness.age(r.finishedAt))), load \(r.loadId) \(r.status)\(r.message.map { ": \($0)" } ?? "")")
                            .foregroundStyle(r.status == "succeeded" ? .primary : Color.orange).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Never: request Your Orders at amazon.com ▸ Request Your Data, then Import Export…").foregroundStyle(.orange)
                    }
                }
                GridRow {
                    Text("Orders").foregroundStyle(.secondary)
                    if a.orders == 0 {
                        Text("None yet").foregroundStyle(.secondary)
                    } else {
                        Text("To \(shortDay(a.lastOrder)) (\(Freshness.age(a.lastOrder)))" + (a.afterExport > 0
                             ? "; \(a.afterExport) Amazon charge\(a.afterExport == 1 ? "" : "s") since (newest \(shortDay(a.newestCharge))): request a newer export to match \(a.afterExport == 1 ? "it" : "them")" : ""))
                            .foregroundStyle(a.afterExport > 0 ? .orange : .primary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                GridRow {
                    Text("Matched").foregroundStyle(.secondary)
                    Text("\(y): \(a.matchedNow.formatted()) of \(a.chargesNow.formatted()) Amazon charges, \(money(a.matchedSpentNow)) of \(money(a.spentNow)) · all years: \(a.matched.formatted()) of \(a.charges.formatted())")
                        .monospacedDigit().fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.callout)
            HStack {
                Button("Import Export…") { pickAmazonExport() }
                    .help("Choose the zip Amazon's Request Your Data e-mail links to (or a Retail.OrderHistory CSV): it is saved in the drop folder and read")
                Button("Read Again") { Task { await loadAmazon(nil) } }
                    .help("Read the exports in the drop folder again and match the Amazon charges loaded since")
                if loadingAmazon { ProgressView().controlSize(.small) }
            }
            .disabled(loadingAmazon)
            if !a.unmatchedCharges.isEmpty || !a.unmatchedShipments.isEmpty {
                DisclosureGroup("Not matched in \(y): \(a.unmatchedCharges.count) Amazon charge\(a.unmatchedCharges.count == 1 ? "" : "s"), \(a.unmatchedShipments.count) shipment\(a.unmatchedShipments.count == 1 ? "" : "s")") {
                    unmatchedLists(a)
                }
                .font(.callout)
            }
        }
    }

    @ViewBuilder
    private func unmatchedLists(_ a: AmazonOrders) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !a.unmatchedCharges.isEmpty {
                Text("Charges and credits no order matched: an order outside the export (another account, a gift card, Whole Foods), or a charge for several orders at once")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
                    ForEach(a.unmatchedCharges.prefix(40)) { c in
                        GridRow {
                            Text(shortDay(c.date)).monospacedDigit().foregroundStyle(.secondary)
                            Text(c.register ?? c.source).foregroundStyle(.secondary)
                            Text(c.payee ?? "").lineLimit(1)
                            Text(money2(c.amount)).monospacedDigit().gridColumnAlignment(.trailing)
                        }
                    }
                }
                if a.unmatchedCharges.count > 40 { Text("and \(a.unmatchedCharges.count - 40) more").foregroundStyle(.secondary) }
            }
            if !a.unmatchedShipments.isEmpty {
                Text("Shipments no charge paid: paid by another card, a gift card or points, or charged with others in a way not matched")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
                    ForEach(a.unmatchedShipments.prefix(40)) { s in
                        GridRow {
                            Text(shortDay(s.shipped ?? s.ordered)).monospacedDigit().foregroundStyle(.secondary)
                            Button(s.orderId) { if let url = AmazonItem.orderURL(s.orderId) { NSWorkspace.shared.open(url) } }
                                .buttonStyle(.link).help("Open the order on amazon.com")
                            Text((s.items ?? "").replacingOccurrences(of: "\n", with: "; ")).lineLimit(1).help(s.items ?? "")
                            Text(money2(s.amount)).monospacedDigit().gridColumnAlignment(.trailing)
                            Text(s.payment ?? "").foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                if a.unmatchedShipments.count > 40 { Text("and \(a.unmatchedShipments.count - 40) more").foregroundStyle(.secondary) }
            }
        }
        .padding(.top, 4)
    }

    private func pickAmazonExport() {
        let panel = NSOpenPanel()
        panel.title = "Import Amazon's Order Export"
        panel.message = "Choose the zip from Amazon's Request Your Data ▸ Your Orders e-mail, or a Retail.OrderHistory CSV"
        panel.allowedContentTypes = [.zip, .commaSeparatedText]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await loadAmazon(url) }
    }

    private func loadAmazon(_ file: URL?) async {
        loadingAmazon = true
        defer { loadingAmazon = false }
        do { changed(try await SpendingClient.loadAmazon(file, window: sources)); problem = nil } catch { problem = describe(error) }
    }

    // MARK: Time window

    private var window: some View {
        let days = (Freshness.date(sources.end).flatMap { e in Freshness.date(sources.start).map { Calendar.current.dateComponents([.day], from: $0, to: e).day ?? 0 } } ?? 0) + 1
        let cpi = data?.inflation.first { $0.basis == "CPI" }
        return Box(title: "Time Window", symbol: "calendar", help: "The dates the analysis compares. Change them with the year picker and Year to date above.") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                GridRow {
                    Text("This period").foregroundStyle(.secondary)
                    Text("\(shortDay(sources.start)) – \(shortDay(sources.end)) (\(days) days)").monospacedDigit()
                }
                GridRow {
                    Text("Compared with").foregroundStyle(.secondary)
                    Text("\(shortDay(sources.priorStart)) – \(shortDay(sources.priorEnd)), the same dates a year earlier").monospacedDigit()
                }
                GridRow {
                    Text("Basis").foregroundStyle(.secondary)
                    Text(yearToDate ? "Year to date: January 1 to today's date in both years" : "Whole calendar years")
                }
                GridRow {
                    Text("Partial registers").foregroundStyle(.secondary)
                    Text(fullCoverage ? "Left out when their spending starts after the earlier period does (Only registers covering both years)"
                         : "Kept even when their spending starts after the earlier period does: their whole spending counts as growth")
                }
                GridRow {
                    Text("Inflation").foregroundStyle(.secondary)
                    Text(cpi.map { "CPI: the \($0.months) months of this period with values (to \(shortDay($0.through))) over the same months a year earlier" }
                         ?? "No CPI values for these months: each category's assumed rate")
                }
            }
            .font(.callout)
        }
    }

    // MARK: A source

    private func sourceRow(_ s: SpendingSources.Source) -> some View {
        let partial = fullCoverage && (Freshness.date(s.spendingFirst).map { first in
            Freshness.date(sources.priorStart).map { first > Calendar.current.date(byAdding: .day, value: 31, to: $0)! } ?? false } ?? false)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Toggle(isOn: Binding(get: { s.included }, set: { v in Task { await include(s, v) } })) {
                    Label(s.name, systemImage: s.symbol).font(.body.weight(.semibold))
                }
                .toggleStyle(.checkbox)
                .disabled(saving != nil)
                .help(s.included ? "Included: its spending is in the analysis. Untick to leave it out (for every Mac)." : "Left out of the analysis. Tick to include it.")
                Text([s.kindTitle, s.code, s.institution, s.last4.map { "…\($0)" }].compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
                if s.closedDate != nil { Text("closed").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if saving == s.id { ProgressView().controlSize(.small) }
                if let by = s.choiceBy { Text("\(s.included ? "included" : "left out") by \(by), \(Freshness.when(s.choiceAt))").font(.caption).foregroundStyle(.secondary) }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                GridRow {
                    Text("Comes from").foregroundStyle(.secondary)
                    origin(s)
                }
                GridRow {
                    Text("Lands in").foregroundStyle(.secondary)
                    Text(landsIn(s)).textSelection(.enabled)
                }
                if s.loader != nil {
                    GridRow {
                        Text("Last import").foregroundStyle(.secondary)
                        lastImport(s)
                    }
                }
                GridRow {
                    Text("Register").foregroundStyle(.secondary)
                    Text(register(s)).foregroundStyle(s.source != "ledger" && s.included && Freshness.isStale(s.last) ? .orange : .primary)
                }
                GridRow {
                    Text("In the analysis").foregroundStyle(.secondary)
                    analysisLine(s, partial: partial)
                }
            }
            .font(.callout)
            .padding(.leading, 22)
        }
        .opacity(s.included ? 1 : 0.6)
    }

    @ViewBuilder
    private func origin(_ s: SpendingSources.Source) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            switch s.source {
            case "ledger":
                Text("Entered by hand in \(s.screen); an item that is also a card or check entry counts with that register instead")
            default:
                Text("\(s.source == "bank" ? "Entries made by hand in \(s.screen), cleared by the bank's downloads" : "The card company's downloads, posted to its register in \(s.screen); charges entered by hand are matched to them") — read by srm.py load \(s.loader ?? "") from:")
                ForEach(s.dropFolders, id: \.self) { f in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(f)/\(s.code)/").font(.callout.monospaced()).textSelection(.enabled)
                        Text(s.source == "bank" ? "for CSV downloads; a QFX / OFX anywhere in \(f) that names account …\(s.last4 ?? "")"
                             : (s.institution ?? "").localizedCaseInsensitiveContains("chase")
                                ? "or anywhere in \(f): a QFX / OFX or a Chase CSV (Chase\(s.last4 ?? "")_…) that names card …\(s.last4 ?? "")"
                                : "or anywhere in \(f): a QFX / OFX that names card …\(s.last4 ?? "")")
                            .foregroundStyle(.secondary)
                    }
                }
                if s.downloads.isEmpty {
                    Text("No downloads there now.").foregroundStyle(.secondary)
                } else {
                    ForEach(s.downloads.prefix(4), id: \.path) { d in
                        HStack(spacing: 6) {
                            Image(systemName: "doc").foregroundStyle(.secondary)
                            Text(d.path).font(.callout.monospaced()).textSelection(.enabled)
                            Text("\(Freshness.when(d.modified)) · \(ByteCountFormatter.string(fromByteCount: Int64(d.bytes), countStyle: .file))").foregroundStyle(.secondary)
                        }
                    }
                    if s.downloads.count > 4 { Text("and \(s.downloads.count - 4) older").foregroundStyle(.secondary) }
                }
            }
        }
    }

    private func landsIn(_ s: SpendingSources.Source) -> String {
        var steps: [String] = []
        if let lines = s.linesTable {
            steps.append("\(lines) (\(s.lines ?? 0) line\(s.lines == 1 ? "" : "s")\(s.firstLine.map { ", \(shortDay($0)) – \(shortDay(s.lastLine))" } ?? ""))")
        }
        steps.append("\(s.registerTable) (the register)")
        steps.append("srm.v_spending_entry (spending only, categories and drivers resolved)")
        return steps.joined(separator: " → ")
    }

    @ViewBuilder
    private func lastImport(_ s: SpendingSources.Source) -> some View {
        if let r = s.lastImport {
            Text("\(Freshness.when(r.finishedAt)) (\(Freshness.age(r.finishedAt))), load \(r.loadId) \(r.status)\(r.message.map { ": \($0)" } ?? "")")
                .foregroundStyle(r.status == "succeeded" ? .primary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Never: no line of this \(s.source == "bank" ? "account" : "card") has been read from a download yet").foregroundStyle(.orange)
        }
    }

    private func register(_ s: SpendingSources.Source) -> String {
        guard let n = s.entries, n > 0 else { return "No entries yet" }
        var parts = ["\(n.formatted()) entries, \(shortDay(s.first)) – \(shortDay(s.last))"]
        if let last = s.last { parts[0] += " (newest \(Freshness.age(last)))" }
        if s.source == "card" { parts.append("\((s.fromDownloads ?? 0).formatted()) from downloads, \((n - (s.fromDownloads ?? 0)).formatted()) entered by hand") }
        if s.source == "bank" { parts.append("\((s.fromDownloads ?? 0).formatted()) cleared by the bank's lines") }
        if let e = s.edited { parts.append("last changed \(Freshness.when(e))") }
        return parts.joined(separator: "; ")
    }

    @ViewBuilder
    private func analysisLine(_ s: SpendingSources.Source, partial: Bool) -> some View {
        let y = String(sources.start.prefix(4)), py = String(sources.priorStart.prefix(4))
        VStack(alignment: .leading, spacing: 2) {
            if s.entriesNow + s.entriesBefore == 0 && (s.entries ?? 0) > 0 && s.spendingFirst == nil {
                Text("None of its \((s.entries ?? 0).formatted()) entries counts as spending: none is in an expense account (card payments and transfers are not spending). File an entry in an expense account, or give its target account one, for it to count.")
                    .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("\(y): \(s.entriesNow.formatted()) entries, \(money(s.spentNow)) · \(py): \(s.entriesBefore.formatted()) entries, \(money(s.spentBefore))"
                     + (s.spendingFirst.map { " · spending \(shortDay($0)) – \(shortDay(s.spendingLast))" } ?? ""))
                    .monospacedDigit()
                if !s.included {
                    Text("Left out: none of it is in the analysis.").foregroundStyle(.secondary)
                } else if partial {
                    Text("Its spending starts \(shortDay(s.spendingFirst)), after the earlier period does: left out while Only registers covering both years is on.").foregroundStyle(.orange)
                }
            }
        }
    }

    private func include(_ s: SpendingSources.Source, _ v: Bool) async {
        saving = s.id
        defer { saving = nil }
        do { changed(try await SpendingClient.include(s, v, window: sources)); problem = nil } catch { problem = describe(error) }
    }

    // MARK: Tables

    private var tablesBox: some View {
        Box(title: "SRM Tables in the Aggregation", symbol: "tablecells", help: "Every table and view in the security master (schema srm) the analysis reads. Downloads land in the line tables and post to the registers; srm.v_spending_entry gathers the registers' spending and resolves each entry's category, driver and member from the tags and rules; the app adds them up per category and period and takes inflation from the CPI series. Newest data is the latest transaction, line or observation date; last changed is the latest edit, or the load that wrote the newest rows.") {
            Text("Downloads → line tables → registers → srm.v_spending_entry (with expense accounts, target accounts, rules, tags) → the attribution, with inflation from srm.market_series_value; the family and lifecycle triggers make the forward curve.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("Table or view"); Text("What it gives the analysis"); Text("Rows").gridColumnAlignment(.trailing); Text("Newest data"); Text("Last changed")
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(sources.tables) { t in
                    let limit = t.name == "srm.market_series_value" ? Freshness.staleCPIDays : Freshness.staleDays
                    let dated = ["srm.bank_txn", "srm.card_txn", "srm.card_line", "srm.bank_line", "srm.v_spending_entry", "srm.market_series_value"].contains(t.name)
                    GridRow {
                        Text(t.name).font(.callout.monospaced()).textSelection(.enabled)
                            .help(t.kind == "view" ? "A view: computed from the tables below each time it is read" : "A table")
                        Text(t.role).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 420, alignment: .leading)
                        Text(t.rows.formatted()).monospacedDigit().foregroundStyle(t.rows == 0 ? .secondary : .primary)
                        Text(t.newest.map { "\(shortDay($0)) (\(Freshness.age($0)))" } ?? "—")
                            .foregroundStyle(dated && t.rows > 0 && Freshness.isStale(t.newest, days: limit) ? .orange : .primary)
                        Text(t.changed.map { "\(Freshness.when($0)) (\(Freshness.age($0)))" } ?? "—")
                    }
                    .font(.callout)
                }
            }
        }
    }

    private var loadsBox: some View {
        Box(title: "Last Loads", symbol: "arrow.down.doc", help: "The loaders that bring outside data into these tables, each run through srm-loader and audited in srm.load_run: pnc-bank and card-downloads read the drop folders' downloads, amazon-orders Amazon's order export, fred-yields the CPI from FRED. A run reads every download in the folders and keeps each line once. Banking ▸ Checking Accounts and Credit Card Accounts run them (Import File…), as do MxJobsMGR's and MxDataHUB's refreshes.") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow { Text("Loader"); Text("Last run"); Text("Status"); Text("Result") }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(sources.loaders, id: \.loadId) { r in
                    GridRow {
                        Text(r.loader.replacingOccurrences(of: "_", with: "-")).font(.callout.monospaced())
                        Text("\(Freshness.when(r.finishedAt ?? r.startedAt)) (\(Freshness.age(r.finishedAt ?? r.startedAt)))")
                        Text(r.status).foregroundStyle(r.status == "succeeded" ? .green : .orange)
                        Text(r.message ?? "\(r.rowsInserted ?? 0) new rows of \(r.rowsRead ?? 0) read").foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.callout)
                }
            }
        }
    }
}

// MARK: - Tabs

/// The page's tabs as a row of buttons, each as wide as its name. A segmented picker of seven tabs redrew every
/// segment as wide as the widest name after a tab change; the row then outgrew the page and, centered, slid under
/// the sidebar.
private struct SpendingTabBar: View {
    var tabs: [(String, String)]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs, id: \.0) { id, title in
                Button { selection = id } label: {
                    Text(title)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .foregroundStyle(selection == id ? Color.white : .primary)
                        .background(selection == id ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .plainButton()
                .accessibilityAddTraits(selection == id ? .isSelected : [])
            }
        }
        .padding(2)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .fixedSize()
    }
}

// MARK: - Charts shared by Attribution and Deep Dive

/// The attribution formula as a waterfall: the earlier period's spending, each effect, and this period's.
private struct AttributionWaterfall: View {
    var t: CategoryAttribution
    var title: String

    private struct Step: Identifiable { var label: String; var from: Double; var to: Double; var color: Color; var id: String { label } }

    var body: some View {
        var steps = [Step(label: "Earlier", from: 0, to: t.prior, color: .gray)]
        var level = t.prior
        for e in SpendingEffect.allCases {
            steps.append(Step(label: e.rawValue, from: level, to: level + t.effect(e), color: e.color))
            level += t.effect(e)
        }
        steps.append(Step(label: "This year", from: 0, to: t.current, color: .gray))
        return Box(title: title, symbol: "chart.bar.xaxis", help: "The attribution formula as a waterfall: the earlier year's spending, each effect added (or taken off), and this year's spending.") {
            Chart(steps) { s in
                BarMark(x: .value("Step", s.label), yStart: .value("From", s.from), yEnd: .value("To", s.to))
                    .foregroundStyle(s.color.opacity(0.8))
                    .annotation(position: s.to >= s.from ? .top : .bottom) {
                        Text(s.label == "Earlier" || s.label == "This year" ? money(s.to) : (s.to >= s.from ? "+" : "") + money(s.to - s.from))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
            }
            .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(money(d)) } } } }
            .frame(height: 260)
        }
    }
}

/// Over a chart whose bars are categories: the category under the pointer (its bar, or its name on the axis) gets a
/// right-click menu with Deep Dive into it, and a double-click opens it. The pointer's category is this view's own
/// state, so following the pointer redraws only the overlay.
private struct CategoryChartMenu: View {
    var proxy: ChartProxy
    /// .horizontal: categories along x (bars stand on them); .vertical: along y (bars lie beside them).
    var axis: Axis
    var open: (String) -> Void
    @State private var hovered: String?

    var body: some View {
        GeometryReader { geo in
            Rectangle().fill(.clear).contentShape(Rectangle())
                .onContinuousHover { phase in
                    guard case .active(let p) = phase else { return }
                    hovered = category(at: p, geo)
                }
                .gesture(SpatialTapGesture(count: 2).onEnded { tap in
                    if let c = category(at: tap.location, geo) { open(c) }
                })
                .contextMenu {
                    if let hovered {
                        Button("Deep Dive into \(hovered)") { open(hovered) }
                    } else {
                        Text("Point at a category's bar or name")
                    }
                }
                .help(hovered.map { "Right-click or double-click for a deep dive into \($0)" } ?? "")
        }
    }

    /// The category whose band holds the point — over its bar or its name on the axis.
    private func category(at p: CGPoint, _ geo: GeometryProxy) -> String? {
        guard let plot = proxy.plotFrame else { return nil }
        let origin = geo[plot].origin
        return axis == .horizontal ? proxy.value(atX: p.x - origin.x, as: String.self)
                                   : proxy.value(atY: p.y - origin.y, as: String.self)
    }
}

// MARK: - Deep dive

/// One category taken apart: what it spent in both periods and why it changed (effects, months, drivers), how its
/// entries got into it (the rules and tags), where the money went (expense and target accounts, the largest entries,
/// family members), what the lifecycle model brings to it, and its entries to tag.
private struct SpendingDeepDiveTab: View {
    var setup: SpendingSetup
    var data: SpendingAnalysisData
    /// The entries of every category (Only registers covering both years applied).
    var entries: [SpendingEntry]
    @Binding var code: String
    var changed: (SpendingEntry) -> Void
    var ruleSaved: (SpendingSetup) -> Void
    var back: () -> Void
    @AppStorage("spendingCurveInflate") private var inflate = true
    @State private var ruleFor: RuleTarget?

    private var name: String { code == SpendingEngine.unassigned ? "Not assigned" : setup.category(code)?.name ?? code }
    private var year: String { String(data.start.prefix(4)) }
    private var priorYear: String { String(data.priorStart.prefix(4)) }
    private func isNow(_ e: SpendingEntry) -> Bool { e.date >= data.start && e.date <= data.end }
    private func isBefore(_ e: SpendingEntry) -> Bool { e.date >= data.priorStart && e.date <= data.priorEnd }

    /// Earlier, this year and how many entries this year, for a group of entries.
    private struct Sums { var before = 0.0; var now = 0.0; var count = 0; var countBefore = 0; var change: Double { now - before } }
    private func sums(_ list: [SpendingEntry]) -> Sums {
        var s = Sums()
        for e in list {
            if isNow(e) { s.now += e.amount; s.count += 1 } else if isBefore(e) { s.before += e.amount; s.countBefore += 1 }
        }
        return s
    }

    var body: some View {
        let rows = SpendingEngine.attribute(data, entries: entries, categories: setup.categories)
        let row = rows.first { $0.code == code }
        let mine = entries.filter { ($0.category ?? SpendingEngine.unassigned) == code }
        header(rows, row)
        if let row {
            tiles(row)
            HStack(alignment: .top, spacing: 14) {
                AttributionWaterfall(t: row, title: "\(name): From Last Year to This Year")
                monthly(mine)
            }
            driversBox(mine, row)
            originBox(mine)
                .sheet(item: $ruleFor) { target in SpendingRuleSheet(setup: setup, target: target, entries: entries) { ruleSaved($0) } }
            accountsBox(mine)
            HStack(alignment: .top, spacing: 14) {
                largestBox(mine)
                membersBox(mine)
            }
        } else {
            ContentUnavailableView("No \(name) spending in either period", systemImage: "magnifyingglass",
                                   description: Text("Nothing in \(priorYear) or \(year) is in \(name). Rules (Rules tab) and tags (Entries) put spending in a category."))
        }
        lifecycleBox
        SpendingEntriesTab(setup: setup, data: data, entries: entries, changed: changed, ruleSaved: ruleSaved,
                           lockedCategory: code, title: "\(name) Entries")
            .id(code)
    }

    // MARK: Header and tiles

    private func header(_ rows: [CategoryAttribution], _ row: CategoryAttribution?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Picker("Deep dive into", selection: $code) {
                ForEach(setup.categories) { c in Text(c.name).tag(c.code) }
                Text("Not assigned").tag(SpendingEngine.unassigned)
            }
            .frame(maxWidth: 300)
            if let row {
                Text("\(money(row.prior)) in \(priorYear) → \(money(row.current)) in \(year): \(row.change >= 0 ? "+" : "")\(money(row.change))\(row.growth.map { " (\(signedPct($0, 1)))" } ?? "")")
                    .font(.title3.weight(.semibold)).monospacedDigit()
                Text(row.reading).foregroundStyle(.secondary)
            }
            Spacer()
            Button { back() } label: { Label("Overview", systemImage: "chevron.backward") }
                .help("Back to the Overview: every category's attribution")
        }
    }

    private func tiles(_ r: CategoryAttribution) -> some View {
        HStack(spacing: 10) {
            ForEach(SpendingEffect.allCases) { e in
                MetricTile(title: e.rawValue, value: (r.effect(e) >= 0 ? "+" : "") + money(r.effect(e)),
                           caption: r.share(e).map { "\(pct($0, 0)) of the change" } ?? "", tint: e.color, help: e.help)
            }
            MetricTile(title: "Prices (CPI)", value: signedPct(r.inflationRate, 1),
                       caption: r.basis == "CPI" ? (setup.category(code)?.cpiName ?? "CPI") : "assumed: no CPI values",
                       help: "The category's price change between the periods: its CPI series' months in this period over the same months a year earlier, else its assumed rate.")
        }
    }

    // MARK: When

    private struct MonthBar: Identifiable { var month: Int; var year: String; var amount: Double; var id: String { "\(year)-\(month)" } }

    private func monthly(_ mine: [SpendingEntry]) -> some View {
        var sums: [String: Double] = [:]
        for e in mine {
            guard let m = Int(e.date.dropFirst(5).prefix(2)) else { continue }
            if isNow(e) { sums["\(year)|\(m)", default: 0] += e.amount } else if isBefore(e) { sums["\(priorYear)|\(m)", default: 0] += e.amount }
        }
        let bars = sums.map { k, v in
            let p = k.split(separator: "|")
            return MonthBar(month: Int(p[1]) ?? 1, year: String(p[0]), amount: v)
        }
        let symbols = Calendar.current.shortMonthSymbols
        let months = Set(bars.map(\.month)).sorted().map { symbols[$0 - 1] }
        return Box(title: "Month by Month", symbol: "calendar", help: "\(name) spending in each month of both periods, side by side: when the change happened.") {
            Chart(bars) { b in
                BarMark(x: .value("Month", symbols[b.month - 1]), y: .value("Dollars", b.amount))
                    .foregroundStyle(by: .value("Year", b.year))
                    .position(by: .value("Year", b.year))
            }
            .chartXScale(domain: months)
            .chartForegroundStyleScale(domain: [priorYear, year], range: [Color.gray.opacity(0.6), Color.accentColor])
            .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(money(d)) } } } }
            .frame(height: 260)
        }
    }

    // MARK: Why: drivers

    private func driversBox(_ mine: [SpendingEntry], _ row: CategoryAttribution) -> some View {
        let groups = Dictionary(grouping: mine, by: { $0.driver ?? "" })
        let order = SpendingDriver.allCases.map(\.rawValue) + [""]
        let rate = row.inflationRate
        return Box(title: "By Driver", symbol: "arrow.triangle.branch", help: "\(name) spending by primary driver in both periods. A driver's effect is what its spending grew beyond prices (this year less last year's grown by the category's CPI change); with the price change on last year's spending they add up to the change. Spending with no driver counts as usage.") {
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    Text("Driver").gridColumnAlignment(.leading); Text(priorYear); Text(year); Text("Change"); Text("Beyond prices"); Text("Counts as").gridColumnAlignment(.leading)
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                GridRow {
                    Text("Prices on \(priorYear)'s spending (\(signedPct(rate, 1)))")
                    Text(""); Text(""); Text("")
                    Text(money(row.prior * rate)).foregroundStyle(SpendingEffect.inflation.color)
                    Text("Inflation")
                }
                ForEach(order.filter { groups[$0] != nil }, id: \.self) { d in
                    let s = sums(groups[d] ?? [])
                    let driver = SpendingDriver(rawValue: d)
                    GridRow {
                        Text(driver?.title ?? "No driver yet").foregroundStyle(driver == nil ? .secondary : .primary).help(driver?.help ?? "No rule or tag gives it a driver: it counts as usage")
                        Text(money(s.before)); Text(money(s.now))
                        Text(money(s.change)).foregroundStyle(s.change > 0.5 ? .red : s.change < -0.5 ? .green : .secondary)
                        Text(money(s.now - s.before * (1 + rate))).foregroundStyle((driver?.effect ?? .usage).color)
                        Text((driver?.effect ?? .usage).rawValue)
                    }
                }
                Divider()
                GridRow {
                    Text("Change").fontWeight(.semibold)
                    Text(money(row.prior)); Text(money(row.current)); Text(money(row.change)).fontWeight(.semibold)
                    Text(money(row.change)).fontWeight(.semibold); Text("")
                }
            }
            .font(.callout).monospacedDigit()
        }
    }

    // MARK: How entries got here: rules and tags

    private struct Origin: Identifiable {
        var kind: String          // expense account, target account, statement text, entry
        var label: String
        var target: RuleTarget?
        var rule: SpendingRule?
        var entries: [SpendingEntry]
        var id: String { kind + label }
    }

    private func originBox(_ mine: [SpendingEntry]) -> some View {
        var groups: [String: Origin] = [:]
        for e in mine {
            let kind = e.categoryFrom ?? "none"
            var label = "", target: RuleTarget?, rule: SpendingRule?
            switch kind {
            case "expense account":
                label = e.expenseAccount ?? "—"
                if let id = e.expenseAccountId { target = RuleTarget(expenseAccountId: id, name: label); rule = setup.rule(expenseAccount: id) }
            case "target account":
                label = e.payee ?? "—"
                if let id = e.payeeId { target = RuleTarget(payeeId: id, name: label); rule = setup.rule(payee: id) }
            case "statement text":
                label = e.rulePattern ?? "—"
                rule = setup.rule(pattern: label)
                target = RuleTarget(pattern: label, ruleId: rule?.id, name: label)
            case "entry": label = "Tagged on the entry"
            default: label = e.expenseAccount.map { "\($0) (no rule)" } ?? "No expense account, rule or tag"
            }
            groups[kind + label, default: Origin(kind: kind, label: label, target: target, rule: rule, entries: [])].entries.append(e)
        }
        let list = groups.values.sorted { abs(sums($0.entries).now) + abs(sums($0.entries).before) > abs(sums($1.entries).now) + abs(sums($1.entries).before) }
        return Box(title: "How Entries Got Here", symbol: "point.3.connected.trianglepath.dotted", help: "What put each entry in \(name): an expense account's rule (every entry filed in that expense account), a target account's rule (every entry with that target, overriding its expense account's), a statement text rule (every entry whose statement contains the text), or the entry's own tag. Rule… changes a rule; tag single entries in the table below.") {
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    Text("Put here by").gridColumnAlignment(.leading); Text("Rule says").gridColumnAlignment(.leading)
                    Text(priorYear); Text(year); Text("Change"); Text("Entries"); Text("")
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(list) { o in
                    let s = sums(o.entries)
                    GridRow {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(o.label)
                            Text(o.kind == "none" ? "not assigned" : o.kind == "entry" ? "entry tags" : "\(o.kind) rule").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(o.rule.map { r in
                            [setup.category(r.category)?.name, r.driver.map { SpendingDriver.title($0) }, setup.member(r.memberId)?.name].compactMap { $0 }.joined(separator: " · ")
                        } ?? "").foregroundStyle(.secondary)
                        Text(money(s.before)); Text(money(s.now))
                        Text(money(s.change)).foregroundStyle(s.change > 0.5 ? .red : s.change < -0.5 ? .green : .secondary)
                        Text("\(s.countBefore) → \(s.count)")
                        Group {
                            if let t = o.target { Button("Rule…") { ruleFor = t }.controlSize(.small) } else { Text("") }
                        }
                    }
                }
            }
            .font(.callout).monospacedDigit()
        }
    }

    // MARK: Where the money went

    private func accountsBox(_ mine: [SpendingEntry]) -> some View {
        let byAccount = Dictionary(grouping: mine, by: { $0.expenseAccount ?? "No expense account" })
        let accounts = byAccount.keys.sorted { sums(byAccount[$0]!).now > sums(byAccount[$1]!).now }
        return Box(title: "Where It Went", symbol: "building.2", help: "\(name) spending by expense account, and within each the target accounts (payees) whose spending changed most between the periods.") {
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 3) {
                GridRow {
                    Text("Expense account / target account").gridColumnAlignment(.leading); Text(priorYear); Text(year); Text("Change"); Text("Entries")
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(accounts, id: \.self) { a in
                    let list = byAccount[a]!
                    let s = sums(list)
                    GridRow {
                        Text(a).fontWeight(.semibold)
                        Text(money(s.before)); Text(money(s.now))
                        Text(money(s.change)).foregroundStyle(s.change > 0.5 ? .red : s.change < -0.5 ? .green : .secondary)
                        Text("\(s.countBefore) → \(s.count)")
                    }
                    let byPayee = Dictionary(grouping: list, by: { $0.payee ?? $0.description ?? "—" })
                    let payees = byPayee.keys.sorted { abs(sums(byPayee[$0]!).change) > abs(sums(byPayee[$1]!).change) }
                    ForEach(payees.prefix(6), id: \.self) { p in
                        let ps = sums(byPayee[p]!)
                        GridRow {
                            Text(p).padding(.leading, 16).lineLimit(1).foregroundStyle(.secondary)
                            Text(money(ps.before)); Text(money(ps.now))
                            Text(money(ps.change)).foregroundStyle(ps.change > 0.5 ? .red : ps.change < -0.5 ? .green : .secondary)
                            Text("\(ps.countBefore) → \(ps.count)").foregroundStyle(.secondary)
                        }
                    }
                    if payees.count > 6 {
                        let rest = sums(payees.dropFirst(6).flatMap { byPayee[$0]! })
                        GridRow {
                            Text("\(payees.count - 6) more").padding(.leading, 16).foregroundStyle(.secondary)
                            Text(money(rest.before)); Text(money(rest.now)); Text(money(rest.change)); Text("\(rest.countBefore) → \(rest.count)")
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .font(.callout).monospacedDigit()
        }
    }

    private func largestBox(_ mine: [SpendingEntry]) -> some View {
        let top = mine.filter(isNow).sorted { $0.amount > $1.amount }.prefix(10)
        return Box(title: "Largest This Year", symbol: "arrow.up.right", help: "The ten largest \(name) entries this year, with their driver and any event.") {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                ForEach(Array(top)) { e in
                    GridRow {
                        Text(shortDay(e.date)).monospacedDigit().foregroundStyle(.secondary)
                        Text(e.bought ?? e.payee ?? e.description ?? "—").lineLimit(1)
                            .help([e.payee, e.description, e.boughtDetail].compactMap { $0 }.joined(separator: "\n"))
                        Text(money2(e.amount)).monospacedDigit().gridColumnAlignment(.trailing)
                        Text(e.event ?? SpendingDriver.title(e.driver)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .font(.callout)
        }
    }

    private func membersBox(_ mine: [SpendingEntry]) -> some View {
        let byMember = Dictionary(grouping: mine, by: { $0.memberId ?? 0 })
        return Box(title: "By Family Member", symbol: "person.2", help: "\(name) spending by the family member its rules or tags name.") {
            if byMember.keys.allSatisfy({ $0 == 0 }) {
                Text("None of it names a family member yet: give a rule or a tag a member.").foregroundStyle(.secondary).font(.callout)
            } else {
                Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 3) {
                    GridRow { Text("Member").gridColumnAlignment(.leading); Text(priorYear); Text(year); Text("Change") }
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(byMember.keys.sorted(), id: \.self) { m in
                        let s = sums(byMember[m]!)
                        GridRow {
                            Text(setup.member(m)?.name ?? "No one named").foregroundStyle(m == 0 ? .secondary : .primary)
                            Text(money(s.before)); Text(money(s.now)); Text(money(s.change))
                        }
                    }
                }
                .font(.callout).monospacedDigit()
            }
        }
    }

    // MARK: What's coming

    private var lifecycleBox: some View {
        let triggers = setup.triggers.filter { $0.category == code && $0.active }
        let rates = Dictionary(uniqueKeysWithValues: data.inflation.map { ($0.category, $0.rate) })
        let start = Calendar.current.component(.year, from: .now)
        let points = SpendingEngine.forwardCurve(children: setup.children, triggers: triggers, rates: rates, start: start, inflate: inflate)
        return Box(title: "Lifecycle Triggers and What's Coming", symbol: "figure.and.child.holdinghands", help: "The lifecycle triggers in \(name) and what they bring each child in the next ten years (Family & Lifecycle sets them; Forward Curve shows every category).") {
            if triggers.isEmpty {
                Text("No lifecycle trigger is in \(name).").foregroundStyle(.secondary).font(.callout)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    ForEach(triggers) { t in
                        GridRow {
                            Text(t.name).help(t.notes ?? "")
                            Text("ages \(t.ages)").foregroundStyle(.secondary)
                            Text(t.kind.capitalized).foregroundStyle(.secondary)
                            Text("\(money(t.annualCost)) a year").monospacedDigit().gridColumnAlignment(.trailing)
                        }
                    }
                }
                .font(.callout)
                if setup.children.isEmpty {
                    Text("Add the children on Family & Lifecycle to see what these bring.").foregroundStyle(.secondary).font(.callout)
                } else if points.isEmpty {
                    Text("None of them applies to the children in the next ten years.").foregroundStyle(.secondary).font(.callout)
                } else {
                    Chart(points) { p in
                        BarMark(x: .value("Year", String(p.year)), y: .value("Dollars", p.amount))
                            .foregroundStyle(by: .value("Child", p.member))
                    }
                    .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(money(d)) } } } }
                    .frame(height: 200)
                }
            }
        }
    }
}

// MARK: - Feedback

/// Notes from the read-only web page on the home network (Services/spending-web): set each one's status and reply —
/// the page shows them to whoever sent it — and act on it: tag the entry it is about, or open its category.
private struct SpendingFeedbackTab: View {
    var setup: SpendingSetup
    var data: SpendingAnalysisData?
    var notes: [SpendingFeedback]
    var changed: ([SpendingFeedback]) -> Void
    var entryChanged: (SpendingEntry) -> Void
    var openDeepDive: (String) -> Void
    /// After an undo: the entries and triggers are read again.
    var reload: () -> Void
    @AppStorage("spendingFeedbackShow") private var show = "open"
    @State private var tagging: SpendingEntry?

    private var shown: [SpendingFeedback] {
        notes.filter { show == "all" || (show == "open" ? $0.open : $0.status == show) }
    }

    var body: some View {
        Box(title: "Feedback from the Web Page", symbol: "bubble.left.and.text.bubble.right", help: "Notes sent from Spending Analysis's web page on the home network, and the changes made there (an entry's category or driver, a lifecycle trigger's category or kind: applied at once, Undo puts them back) (Services/spending-web on K3JDR-DSKTOP-11): about the layout, a number, a rule or category, one purchase, an idea or a question, each with where on the page it was made. Set a status and reply: the page shows both next to the note, under My Notes. A note about one purchase can tag it here.") {
            HStack {
                Picker("", selection: $show) {
                    Text("Open").tag("open"); Text("New").tag("new"); Text("Done").tag("done"); Text("Not planned").tag("declined"); Text("All").tag("all")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                Text("\(notes.count) note\(notes.count == 1 ? "" : "s"), \(notes.filter { $0.status == "new" }.count) new").foregroundStyle(.secondary)
            }
            if shown.isEmpty {
                Text(notes.isEmpty ? "No notes yet. They come from the web page's 💬 Note and ⚑ buttons." : "No notes here.")
                    .foregroundStyle(.secondary).padding(.vertical, 6)
            }
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, n in
                if i > 0 { Divider() }
                FeedbackCard(note: n, setup: setup, entry: entry(for: n),
                             save: { status, reply in
                                 do { changed(try await SpendingClient.answer(n.id, status: status, reply: reply)); return nil } catch { return describe(error) }
                             },
                             tag: { tagging = entry(for: n) }, dive: openDeepDive,
                             undo: {
                                 do { changed(try await SpendingClient.undo(n.id)); reload(); return nil } catch { return describe(error) }
                             })
                    .id("\(n.id)-\(n.status)-\(n.reply ?? "")")
            }
        }
        .sheet(item: $tagging) { e in
            SpendingTagSheet(setup: setup, entries: [e]) { body in
                do { if let updated = try await SpendingClient.tag(e, body) { entryChanged(updated) }; return nil } catch { return describe(error) }
            }
        }
    }

    private func entry(for n: SpendingFeedback) -> SpendingEntry? {
        guard let source = n.entrySource, let id = n.entryId else { return nil }
        return data?.entries.first { $0.source == source && $0.entryId == id }
    }
}

private struct FeedbackCard: View {
    var note: SpendingFeedback
    var setup: SpendingSetup
    /// The entry the note is about, when it is in the periods loaded.
    var entry: SpendingEntry?
    var save: (String, String) async -> String?
    var tag: () -> Void
    var dive: (String) -> Void
    var undo: () async -> String?
    @State private var status = ""
    @State private var reply = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(SpendingFeedback.statuses.first { $0.0 == note.status }?.1 ?? note.status)
                    .font(.caption.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 1)
                    .background(note.status == "new" ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.15), in: Capsule())
                Text(note.author).fontWeight(.semibold)
                Text(Freshness.when(note.createdAt)).foregroundStyle(.secondary)
                Text(note.kindTitle).foregroundStyle(.secondary)
                if let section = note.section { Text("· \(section)").foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
            }
            Text(note.message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if let c = note.context, c.payee != nil || c.amount != nil {
                Text("Entry: \(shortDay(c.date)) \(c.payee ?? "") \(c.amount.map(money2) ?? "") — then \(setup.category(c.category)?.name ?? "Not assigned"), \(SpendingDriver.title(c.driver))")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let s = note.suggestion { Text("Suggests: \(s)").font(.callout) }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Picker("Status", selection: $status) {
                    ForEach(SpendingFeedback.statuses, id: \.0) { Text($0.1).tag($0.0) }
                }
                .fixedSize()
                TextField("Reply (shown to \(note.author) on the web page)", text: $reply, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...4)
                Button("Save") { Task { saving = true; error = await save(status, reply); saving = false } }
                    .disabled(saving || (status == note.status && reply == (note.reply ?? "")))
                if note.kind == "change" && note.status != "declined" {
                    Button("Undo") { Task { saving = true; error = await undo(); saving = false } }
                        .disabled(saving)
                        .help("Put back what this change replaced; the note becomes Not planned, \"Undone.\"")
                }
                if entry != nil { Button("Tag Entry…") { tag() }.help("Tag the purchase this note is about") }
                if let c = note.category { Button("Deep Dive") { dive(c) }.help("Open \(setup.category(c)?.name ?? c) on the Deep Dive tab") }
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
            if let by = note.repliedBy, let at = note.repliedAt {
                Text("Answered by \(by), \(Freshness.when(at))").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { status = note.status; reply = note.reply ?? "" }
    }
}

// MARK: - Year-End Tax

/// The tax year's tax-applicable expenses (paid and deductible), tax payments by jurisdiction and quarter, real estate
/// taxes, refunds and the tax savings account, from the tax items (V040) — with the CSV the accountant gets.
private struct SpendingTaxTab: View {
    var setup: SpendingSetup
    @AppStorage("taxYear") private var year = Calendar.current.component(.year, from: .now) - (Calendar.current.component(.month, from: .now) <= 4 ? 1 : 0)
    @State private var report: TaxReport?
    @State private var problem: String?
    @State private var busy = false
    @State private var editing: TaxReport.Item??
    @State private var moving: TaxReport.Entry?
    @State private var removing: TaxReport.Item?
    @State private var message: String?
    private static let thisYear = Calendar.current.component(.year, from: .now)

    var body: some View {
        HStack(spacing: 12) {
            Picker("Tax year", selection: $year) {
                ForEach((Self.thisYear - 5)...Self.thisYear, id: \.self) { y in Text(verbatim: "\(y)").tag(y) }
            }
            .fixedSize()
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
            Button("Copy Summary") { copySummary() }.disabled(report == nil)
                .help("Copy the year's summary as text")
            Button("Export CSV…") { export() }.disabled(report == nil)
                .help("Save every payment and the year's totals as a CSV file for whoever prepares the return")
            Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.help("Read the registers again")
        }
        .task(id: year) { await load() }
        if let problem { Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
        if let r = report {
            if !r.partialRegisters.isEmpty {
                Label("Incomplete for \(String(r.year)): " + r.partialRegisters.map { "\($0.name) starts \(shortDay($0.first))" }.joined(separator: "; ")
                      + ". Payments before then aren't in the registers, so the totals below miss them.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            }
            tiles(r)
            expenses(r)
            payments(r)
            HStack(alignment: .top, spacing: 14) {
                simpleBox(r, section: "real_estate", title: "Real Estate Taxes", symbol: "house", help: "Property taxes paid in the year (deductible, with state and local taxes, up to the SALT limit).")
                simpleBox(r, section: "refund", title: "Refunds Received", symbol: "arrow.down.circle", help: "Refunds deposited in the year after: a refund that arrives in \(r.year + 1) belongs to \(r.year)'s return.")
            }
            savings(r)
            itemsBox(r)
        } else if busy {
            ProgressView("Reading the registers…").frame(maxWidth: .infinity)
        }
        EmptyView()
            .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
                TaxItemSheet(item: editing ?? nil, setup: setup, lines: report?.ledgerLines ?? []) { id, body in
                    await run { try await SpendingClient.saveTaxItem(id, body, year: year) }
                }
            }
            .sheet(item: $moving) { e in
                TaxMoveSheet(entry: e, item: report?.item(e.itemId)) { toYear, quarter, note in
                    await run { try await SpendingClient.move(e, toYear: toYear, quarter: quarter, note: note, year: year) }
                }
            }
            .confirmationDialog("Remove the tax item \(removing?.label ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                presenting: removing) { i in
                Button("Remove", role: .destructive) { Task { _ = await run { try await SpendingClient.deleteTaxItem(i.id, year: year) } } }
            } message: { _ in
                Text("Its payments stay in the registers; the Year-End Tax report stops listing them. To keep it but leave it out, edit it and turn Active off.")
            }
    }

    private func load() async {
        busy = true
        defer { busy = false }
        do { report = try await SpendingClient.tax(year: year); problem = nil } catch { problem = describe(error) }
    }

    @discardableResult
    private func run(_ action: () async throws -> TaxReport) async -> String? {
        do { report = try await action(); problem = nil; return nil } catch { return describe(error) }
    }

    // MARK: Summary

    private func tiles(_ r: TaxReport) -> some View {
        let s = r.summary
        return HStack(spacing: 10) {
            MetricTile(title: "Tax-applicable expenses", value: money(s.expensesPaid), caption: "\(money(s.expensesDeductible)) deductible",
                       help: "What the tax-applicable expenses cost in the year, and the deductible part (each item's share).")
            MetricTile(title: "Tax payments", value: money(s.paymentsTotal),
                       caption: TaxReport.jurisdictions.compactMap { j, t in s.payments[j].flatMap { $0.total > 0 ? "\(t) \(money($0.total))" : nil } }.joined(separator: " · "),
                       help: "Estimated and local tax payments that count toward the year, by quarter below.")
            MetricTile(title: "Real estate taxes", value: money(s.realEstate), help: "Property taxes paid in the year.")
            MetricTile(title: "Refunds received", value: money(s.refunds), caption: "for \(String(r.year))", help: "Refunds for this year's return, received the year after.")
            MetricTile(title: "Tax savings", value: money(s.savingsSetAside - s.savingsTakenOut),
                       caption: "\(money(s.savingsSetAside)) in, \(money(s.savingsTakenOut)) out", help: "Transfers to and from the tax savings account in the year: set aside less taken out.")
        }
    }

    private func copySummary() {
        guard let r = report else { return }
        let s = r.summary
        var lines = ["Year-End Tax \(r.year)", "",
                     "Tax-applicable expenses: \(money2(s.expensesPaid)) paid, \(money2(s.expensesDeductible)) deductible"]
        for i in r.items where i.section == "expense" && i.entries > 0 {
            lines.append("  \(i.label) (\(i.taxCategory)): \(money2(i.paid))" + (i.deductibleShare < 1 ? ", \(pct(i.deductibleShare, 0)) deductible = \(money2(i.deductible ?? 0))" : ""))
        }
        lines.append("Tax payments: \(money2(s.paymentsTotal))")
        for (j, t) in TaxReport.jurisdictions { if let q = s.payments[j], q.total > 0 {
            lines.append("  \(t): Q1 \(money2(q.q1)), Q2 \(money2(q.q2)), Q3 \(money2(q.q3)), Q4 \(money2(q.q4))" + (q.other > 0 ? ", other \(money2(q.other))" : "") + " = \(money2(q.total))")
        } }
        lines += ["Real estate taxes: \(money2(s.realEstate))", "Refunds received: \(money2(s.refunds))",
                  "Tax savings: \(money2(s.savingsSetAside)) set aside, \(money2(s.savingsTakenOut)) taken out"]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        message = "Summary copied"
    }

    private func export() {
        guard let r = report else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Year-End Tax \(r.year).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try r.csv.write(to: url, atomically: true, encoding: .utf8); message = "Saved \(url.lastPathComponent)" }
        catch { problem = describe(error) }
    }

    // MARK: Sections

    private func expenses(_ r: TaxReport) -> some View {
        let items = r.items.filter { $0.section == "expense" && $0.active }
        let byCategory = Dictionary(grouping: items, by: \.taxCategory)
        return Box(title: "Tax-Applicable Expenses", symbol: "doc.text", help: "What each tax-applicable item cost in the year and its deductible part: the share is the business or home-office part (15% for utilities when the office is 15% of the home). Type a share and press Return to save it.") {
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    Text("Item").gridColumnAlignment(.leading); Text("Comes from").gridColumnAlignment(.leading)
                    Text("Payments"); Text("Paid"); Text("Share"); Text("Deductible")
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(byCategory.keys.sorted(), id: \.self) { c in
                    let list = byCategory[c]!
                    GridRow {
                        Text(c).fontWeight(.semibold).gridCellColumns(3).gridColumnAlignment(.leading)
                        Text(money(list.map(\.paid).reduce(0, +))).fontWeight(.semibold); Text("")
                        Text(money(list.compactMap(\.deductible).reduce(0, +))).fontWeight(.semibold)
                    }
                    ForEach(list) { i in
                        GridRow {
                            Text(i.label).padding(.leading, 14).help(i.notes ?? "")
                            Text(i.origin).foregroundStyle(.secondary).lineLimit(1)
                            Text("\(i.entries)").foregroundStyle(.secondary)
                            Text(money(i.paid))
                            ShareField(share: i.deductibleShare) { v in
                                Task { _ = await run { try await SpendingClient.saveTaxItem(i.id, body(i, share: v), year: year) } }
                            }
                            Text(money(i.deductible ?? 0))
                        }
                    }
                }
                Divider()
                GridRow {
                    Text("All tax-applicable expenses").fontWeight(.semibold).gridCellColumns(3).gridColumnAlignment(.leading)
                    Text(money(r.summary.expensesPaid)).fontWeight(.semibold); Text("")
                    Text(money(r.summary.expensesDeductible)).fontWeight(.semibold)
                }
            }
            .monospacedDigit().font(.callout)
        }
    }

    private func payments(_ r: TaxReport) -> some View {
        let list = r.entries(of: "payment")
        return Box(title: "Tax Payments Through the Year", symbol: "building.columns", help: "Estimated and local tax payments that count toward the year, by jurisdiction and quarter. Estimated payments follow their quarter (January counts as Q4 of the year before); Move… puts a payment in another year or quarter (an April payment that settles last year's return).") {
            Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Text("Jurisdiction").gridColumnAlignment(.leading); Text("Q1"); Text("Q2"); Text("Q3"); Text("Q4"); Text("Other"); Text("Total")
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(TaxReport.jurisdictions, id: \.0) { j, title in
                    let q = r.summary.payments[j]
                    GridRow {
                        Text(title)
                        ForEach(Array((q?.all ?? Array(repeating: 0, count: 6)).enumerated()), id: \.offset) { k, v in
                            Text(v == 0 ? "—" : money(v)).fontWeight(k == 5 ? .semibold : .regular).foregroundStyle(v == 0 ? .secondary : .primary)
                        }
                    }
                }
                Divider()
                GridRow { Text("All").fontWeight(.semibold); Text(""); Text(""); Text(""); Text(""); Text(""); Text(money(r.summary.paymentsTotal)).fontWeight(.semibold) }
            }
            .monospacedDigit().font(.callout)
            entryRows(r, list)
        }
    }

    private func simpleBox(_ r: TaxReport, section: String, title: String, symbol: String, help: String) -> some View {
        let list = r.entries(of: section)
        return Box(title: title, symbol: symbol, help: help) {
            if list.isEmpty { Text("None in \(String(r.year)).").foregroundStyle(.secondary).font(.callout) } else { entryRows(r, list, sign: section == "refund" ? -1 : 1) }
        }
    }

    private func savings(_ r: TaxReport) -> some View {
        let list = r.entries(of: "savings")
        return Box(title: "Tax Savings Account", symbol: "banknote", help: "Transfers to the tax savings account (set aside) and from it (taken out to pay taxes) during the year.") {
            Text("\(money(r.summary.savingsSetAside)) set aside, \(money(r.summary.savingsTakenOut)) taken out: \(money(r.summary.savingsSetAside - r.summary.savingsTakenOut)) net.")
                .font(.callout)
            if !list.isEmpty { entryRows(r, list) }
        }
    }

    private func entryRows(_ r: TaxReport, _ list: [TaxReport.Entry], sign: Double = 1) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
            ForEach(list) { e in
                GridRow {
                    Text(shortDay(e.date)).monospacedDigit().foregroundStyle(.secondary)
                    // Tax savings by direction: the registers' names don't always say which way the money went.
                    Text(r.item(e.itemId)?.section == "savings" ? (e.amount >= 0 ? "Set aside" : "Taken out") : r.item(e.itemId)?.label ?? "").lineLimit(1)
                    Text(e.payee ?? e.description ?? "").foregroundStyle(.secondary).lineLimit(1)
                    Text(money2(sign * e.amount)).monospacedDigit().gridColumnAlignment(.trailing)
                    Text(e.moved ? "\(e.period) (moved)" : e.period).foregroundStyle(e.moved ? Color.accentColor : .secondary).help(e.note ?? "")
                    Button("Move…") { moving = e }.controlSize(.small)
                }
            }
        }
        .font(.callout)
    }

    private func itemsBox(_ r: TaxReport) -> some View {
        Box(title: "Tax Items", symbol: "list.bullet.rectangle", help: "What makes a payment a tax item: a target account, an expense-ledger line, or a name the card companies use (when the charge has no target account). Each has its section, category, jurisdiction, deductible share and whether it follows estimated-tax quarters.") {
            HStack { Button("Add Tax Item…") { editing = .some(nil) }; Spacer() }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                GridRow { Text("Item"); Text("Section"); Text("Category"); Text("Comes from"); Text("Share").gridColumnAlignment(.trailing); Text("") }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(r.items) { i in
                    GridRow {
                        Text(i.label).foregroundStyle(i.active ? .primary : .secondary)
                        Text(TaxReport.sections.first { $0.0 == i.section }?.1 ?? i.section).foregroundStyle(.secondary)
                        Text(i.taxCategory + (i.jurisdiction.map { " · \($0)" } ?? "") + (i.quarterly ? " · quarterly" : "")).foregroundStyle(.secondary)
                        Text(i.origin).foregroundStyle(.secondary).lineLimit(1)
                        Text(["expense", "real_estate"].contains(i.section) ? pct(i.deductibleShare, 0) : "").monospacedDigit()
                        HStack {
                            Button("Edit…") { editing = .some(i) }
                            Button("Remove…") { removing = i }
                        }
                        .controlSize(.small)
                    }
                }
            }
            .font(.callout)
        }
    }

    private func body(_ i: TaxReport.Item, share: Double) -> [String: Any] {
        ["payeeId": i.payeeId ?? NSNull(), "ledgerLineId": i.ledgerLineId ?? NSNull(), "namePattern": i.namePattern ?? NSNull(),
         "label": i.label, "section": i.section, "taxCategory": i.taxCategory, "jurisdiction": i.jurisdiction ?? NSNull(),
         "deductibleShare": share, "quarterly": i.quarterly, "notes": i.notes ?? NSNull(), "active": i.active]
    }
}

/// A deductible share as a percent; saved when the field is submitted.
private struct ShareField: View {
    var share: Double
    var save: (Double) -> Void
    @State private var text = ""

    var body: some View {
        TextField("", text: $text)
            .frame(width: 56).multilineTextAlignment(.trailing)
            .onAppear { text = String(format: "%.0f%%", share * 100) }
            .onChange(of: share) { text = String(format: "%.0f%%", share * 100) }
            .onSubmit {
                if let v = Double(text.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)), (0...100).contains(v) { save(v / 100) }
            }
            .help("The deductible part, in percent: type it and press Return")
    }
}

private struct TaxItemSheet: View {
    var item: TaxReport.Item?
    var setup: SpendingSetup
    var lines: [TaxReport.Line]
    var save: (Int, [String: Any]) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var origin = "payee"
    @State private var payeeId = 0
    @State private var lineId = 0
    @State private var pattern = ""
    @State private var label = ""
    @State private var section = "expense"
    @State private var category = ""
    @State private var jurisdiction = ""
    @State private var share = 100.0
    @State private var quarterly = false
    @State private var notes = ""
    @State private var active = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item == nil ? "Add Tax Item" : "Edit \(item!.label)").heading(.heading)
            Form {
                Picker("Payments from", selection: $origin) {
                    Text("A target account").tag("payee"); Text("An expense-ledger line").tag("line"); Text("Card names containing").tag("pattern")
                }
                switch origin {
                case "line":
                    Picker("Ledger line", selection: $lineId) {
                        Text("—").tag(0)
                        ForEach(lines) { l in Text("\(l.ledger): \(l.name)").tag(l.id) }
                    }
                case "pattern":
                    TextField("Name contains", text: $pattern, prompt: Text("TURBOTAX"))
                default:
                    Picker("Target account", selection: $payeeId) {
                        Text("—").tag(0)
                        ForEach(setup.payees) { p in Text(p.name).tag(p.id) }
                    }
                }
                TextField("Label", text: $label, prompt: Text("Peco"))
                Picker("Section", selection: $section) { ForEach(TaxReport.sections, id: \.0) { Text($0.1).tag($0.0) } }
                TextField("Category", text: $category, prompt: Text("Utilities, Phone & internet, Home office …"))
                Picker("Jurisdiction", selection: $jurisdiction) {
                    Text("—").tag("")
                    ForEach(TaxReport.jurisdictions, id: \.0) { Text($0.1).tag($0.0) }
                }
                if section == "expense" || section == "real_estate" {
                    TextField("Deductible share (%)", value: $share, format: .number.precision(.fractionLength(0...1)))
                }
                if section == "payment" { Toggle("Estimated payments: count toward their quarter", isOn: $quarterly) }
                TextField("Notes", text: $notes)
                Toggle("Active", isOn: $active)
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    Task {
                        error = await save(item?.id ?? 0, [
                            "payeeId": origin == "payee" && payeeId != 0 ? payeeId : NSNull(),
                            "ledgerLineId": origin == "line" && lineId != 0 ? lineId : NSNull(),
                            "namePattern": origin == "pattern" ? pattern : NSNull(),
                            "label": label, "section": section, "taxCategory": category, "jurisdiction": jurisdiction.isEmpty ? NSNull() : jurisdiction,
                            "deductibleShare": min(max(share, 0), 100) / 100, "quarterly": section == "payment" && quarterly, "notes": notes, "active": active])
                        if error == nil { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 480)
        .onAppear {
            guard let i = item else { return }
            origin = i.payeeId != nil ? "payee" : i.ledgerLineId != nil ? "line" : "pattern"
            payeeId = i.payeeId ?? 0; lineId = i.ledgerLineId ?? 0; pattern = i.namePattern ?? ""
            label = i.label; section = i.section; category = i.taxCategory; jurisdiction = i.jurisdiction ?? ""
            share = i.deductibleShare * 100; quarterly = i.quarterly; notes = i.notes ?? ""; active = i.active
        }
    }
}

private struct TaxMoveSheet: View {
    var entry: TaxReport.Entry
    var item: TaxReport.Item?
    var save: (Int?, Int?, String) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var year = 2026
    @State private var quarter = 0
    @State private var note = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Move a Payment").heading(.heading)
            Text("\(shortDay(entry.date)) \(entry.payee ?? "") \(money2(entry.amount)) — now counts toward \(entry.period)\(entry.moved ? " (moved)" : "")")
                .foregroundStyle(.secondary)
            Form {
                Stepper("Tax year \(String(year))", value: $year, in: 1990...2100)
                Picker("Quarter", selection: $quarter) {
                    Text("None").tag(0)
                    ForEach(1...4, id: \.self) { Text("Q\($0)").tag($0) }
                }
                TextField("Why", text: $note, prompt: Text("Balance due with the 2025 return"))
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
            HStack {
                if entry.moved {
                    Button("Back to Its Own Period") { Task { error = await save(nil, nil, ""); if error == nil { dismiss() } } }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Move") { Task { error = await save(year, quarter == 0 ? nil : quarter, note); if error == nil { dismiss() } } }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 440)
        .onAppear { year = entry.taxYear; quarter = entry.quarter ?? 0; note = entry.note ?? "" }
    }
}

// MARK: - Family link

/// The family's read-only web page (Services/spending-web on K3JDR-DSKTOP-11): its link, kept in this Mac's Keychain
/// (it carries the page's key), and the email address and phone number Send Family Link addresses. The link itself
/// never changes unless John changes it on the PC.
enum FamilyLink {
    private static var match: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "com.k3jdr.MxAcctMGR") + ".family-link",
         kSecAttrAccount as String: "spending-web"]
    }

    static var url: String? {
        var query = match
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Saves the link (empty removes it); answers whether the Keychain took it.
    @discardableResult
    static func save(_ link: String) -> Bool {
        SecItemDelete(match as CFDictionary)
        guard !link.isEmpty else { return true }
        var add = match
        add[kSecValueData as String] = Data(link.utf8)
        add[kSecAttrLabel as String] = "MxAcctMGR: family Spending Analysis link"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static var email: String {
        get { UserDefaults.standard.string(forKey: "familyLinkEmail") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "familyLinkEmail") }
    }
    static var phone: String {
        get { UserDefaults.standard.string(forKey: "familyLinkPhone") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "familyLinkPhone") }
    }

    static func note(_ link: String) -> String {
        "Here's our family Spending Analysis page: why our spending changed from last year, and what counts at tax time.\n\n"
            + "\(link)\n\nIt opens on our home Wi-Fi. Use 💬 Feedback on the page to tell me what you'd change."
    }

    /// Opens Mail (composeEmail) or Messages (composeMessage) with the link; answers why it couldn't.
    static func send(_ name: NSSharingService.Name) -> String? {
        guard let link = url else { return "Set the family page's link first (Link and Recipients…)." }
        guard let service = NSSharingService(named: name) else { return "This Mac can't open \(name == .composeEmail ? "Mail" : "Messages")." }
        let to = name == .composeEmail ? email : phone
        if !to.isEmpty { service.recipients = [to] }
        if name == .composeEmail { service.subject = "Our family Spending Analysis page" }
        let items: [Any] = [note(link)]
        guard service.canPerform(withItems: items) else { return "\(name == .composeEmail ? "Mail" : "Messages") can't send this from this Mac: set up an account there first." }
        service.perform(withItems: items)
        return nil
    }
}

private struct FamilyLinkSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var email = ""
    @State private var phone = ""
    @State private var error: String?

    private var linkOK: Bool {
        guard let u = URL(string: link.trimmingCharacters(in: .whitespaces)), let scheme = u.scheme else { return link.isEmpty }
        return (scheme == "http" || scheme == "https") && u.path.hasPrefix("/s/")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Family Page Link and Recipients").heading(.heading)
            Text("The family's read-only Spending Analysis page on the home network. Its link (with its key) is kept in this Mac's Keychain, and it stays the same through every release: it changes only when you change it on the PC.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Link", text: $link, prompt: Text("http://192.168.0.223:8780/s/…/"))
                TextField("Email to", text: $email, prompt: Text("For Email…"))
                TextField("Message to", text: $phone, prompt: Text("Phone number or iMessage address, for Message…"))
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
            else if !linkOK { Text("The link is the page's address: http://…:8780/s/<key>/").font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("Open in Browser") { if let u = URL(string: link.trimmingCharacters(in: .whitespaces)) { NSWorkspace.shared.open(u) } }
                    .disabled(link.isEmpty || !linkOK)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    guard FamilyLink.save(link.trimmingCharacters(in: .whitespaces)) else { error = "The Keychain didn't take the link."; return }
                    FamilyLink.email = email.trimmingCharacters(in: .whitespaces)
                    FamilyLink.phone = phone.trimmingCharacters(in: .whitespaces)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!linkOK)
            }
        }
        .padding(18)
        .frame(width: 520)
        .onAppear { link = FamilyLink.url ?? ""; email = FamilyLink.email; phone = FamilyLink.phone }
    }
}
