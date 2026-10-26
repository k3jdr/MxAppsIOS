//
//  SpendingViews.swift
//  MxAcctMGR
//
//  Reporting ▸ Spending Analysis (SpendingModel.swift): why the family's spending changed from one year to the next
//  — the attribution table and charts — and the forward curve of what the children's ages bring, with the entries,
//  rules, family and lifecycle model they are made from.
//

import Charts
import SwiftUI

struct SpendingAnalysisView: View {
    @Bindable var store: PortStore
    @AppStorage("spendingTab") private var tab = "attribution"
    @AppStorage("spendingYear") private var year = Calendar.current.component(.year, from: .now)
    @AppStorage("spendingYTD") private var yearToDate = true
    @AppStorage("spendingFullCoverage") private var fullCoverage = true
    @State private var setup: SpendingSetup?
    @State private var data: SpendingAnalysisData?
    @State private var problem: String?
    @State private var busy = false

    static let tabs = [("attribution", "Attribution"), ("curve", "Forward Curve"), ("entries", "Entries"), ("rules", "Rules"),
                       ("family", "Family & Lifecycle")]
    private static let thisYear = Calendar.current.component(.year, from: .now)

    var body: some View {
        StepPage(store: store, subtitle: "Household spending attribution: like portfolio attribution, for the family's spending — why it changed from last year (prices, more of the same, the children's ages, habits, one-time events) and what the children's ages bring in the next ten years.", lesson: [
            "Every dollar the check register, the credit cards and the expense ledgers spend has two dimensions: a spending category (Food, Housing, Transportation, Education, Activities, Technology, Healthcare, Clothing, Travel) and a primary driver (inflation, family growth, a new activity, a lifecycle transition, a preference change, a one-time event). Rules on expense and target accounts set them; tag a single entry (Philmont as a one-time event) on Entries.",
            "Each category's change splits as in performance attribution: change = inflation + usage + lifecycle + behavior + one-time. Inflation is last year's spending times the category's CPI change (FRED, in the security master); each driver's effect is what its spending grew beyond inflation. Inflation and lifecycle are the unavoidable part; behavior is habit.",
            "The forward curve stacks each child's lifecycle costs — club sports at 10, a phone at 12, a laptop at 13, tutors at 14, driving at 16, college visits and applications at 16–17, college at 18 — so the waves show three to five years ahead.",
        ]) {
            periodBar
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
            }
            Picker("", selection: $tab) { ForEach(Self.tabs, id: \.0) { Text($0.1).tag($0.0) } }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 720)
            if let setup {
                switch tab {
                case "curve": SpendingCurveTab(setup: setup, data: data) { tab = "family" }
                case "entries":
                    if let data { SpendingEntriesTab(setup: setup, data: data, entries: shownEntries(data), changed: { replace($0) }, ruleSaved: { applied($0) }) }
                case "rules":
                    if let data { SpendingRulesTab(setup: setup, entries: shownEntries(data).filter { inCurrent($0, data) }) { applied($0) } }
                case "family": SpendingFamilyTab(setup: setup, data: data) { applied($0) }
                default:
                    if let data { attribution(data, setup) }
                }
            } else if busy {
                ProgressView("Reading the registers…").frame(maxWidth: .infinity)
            }
        }
        .task { await reload() }
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

    private var periodBar: some View {
        HStack(spacing: 12) {
            Picker("Year", selection: $year) {
                ForEach((Self.thisYear - 5)...Self.thisYear, id: \.self) { y in Text(verbatim: "\(y) vs \(y - 1)").tag(y) }
            }
            .frame(maxWidth: 200)
            Toggle("Year to date", isOn: $yearToDate).toggleStyle(.checkbox)
                .help("Compare January 1 to today's date in both years; off, the whole years")
            Toggle("Only registers covering both years", isOn: $fullCoverage).toggleStyle(.checkbox)
                .help("Leave out the registers whose entries start after the earlier year does: comparing them would count all their spending as growth")
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            if let data { Text("\(shortDay(data.start)) – \(shortDay(data.end)) vs \(shortDay(data.priorStart)) – \(shortDay(data.priorEnd))").font(.callout).foregroundStyle(.secondary) }
            Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Read the registers again")
        }
        .onChange(of: year) { Task { await reload() } }
        .onChange(of: yearToDate) { Task { await reload() } }
    }

    private func reload() async {
        busy = true
        defer { busy = false }
        let p = periods
        do {
            async let s = SpendingClient.setup()
            async let d = SpendingClient.analysis(start: p.start, end: p.end, priorStart: p.priorStart, priorEnd: p.priorEnd)
            (setup, data) = try await (s, d)
            problem = nil
        } catch {
            problem = describe(error)
        }
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
        }
    }

    private func metricsTable(_ rows: [CategoryAttribution], _ total: CategoryAttribution) -> some View {
        Box(title: "Key Metrics by Category", symbol: "tablecells", help: "Each category's spending growth and how much of its change each effect explains (the contributions add to 100% of the change). Inflation and lifecycle are the unavoidable, age-related part; behavior is habit; one-time won't repeat. Usage is more or less of the same things, including spending with no driver assigned.") {
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
            Text(r.name).gridColumnAlignment(.leading).foregroundStyle(r.code == SpendingEngine.unassigned ? .secondary : .primary)
            Text(money(r.prior)); Text(money(r.current))
            Text(money(r.change)).foregroundStyle(r.change > 0.5 ? .red : r.change < -0.5 ? .green : .secondary)
            Text(r.growth.map { signedPct($0, 0) } ?? (r.prior.magnitude < 0.005 && r.current > 0 ? "new" : "—"))
            ForEach(SpendingEffect.allCases) { e in Text(r.share(e).map { pct($0, 0) } ?? "—").help(money(r.effect(e))) }
            Text(r.code == "TOTAL" ? signedPct(r.inflationRate, 1) : "\(signedPct(r.inflationRate, 1))\(r.basis == "CPI" ? "" : "*")")
                .foregroundStyle(.secondary).help(r.basis == "CPI" ? "From the CPI" : "Assumed: the CPI series has no values for these months")
            Text(r.reading).gridColumnAlignment(.leading).foregroundStyle(.secondary)
        }
    }

    private struct Step: Identifiable { var label: String; var from: Double; var to: Double; var color: Color; var id: String { label } }

    private func waterfall(_ t: CategoryAttribution) -> some View {
        var steps = [Step(label: "Earlier", from: 0, to: t.prior, color: .gray)]
        var level = t.prior
        for e in SpendingEffect.allCases {
            steps.append(Step(label: e.rawValue, from: level, to: level + t.effect(e), color: e.color))
            level += t.effect(e)
        }
        steps.append(Step(label: "This year", from: 0, to: t.current, color: .gray))
        return Box(title: "From Last Year to This Year", symbol: "chart.bar.xaxis", help: "The attribution formula as a waterfall: the earlier year's spending, each effect added (or taken off), and this year's spending.") {
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

    private func effectsChart(_ rows: [CategoryAttribution]) -> some View {
        Box(title: "What Changed Each Category", symbol: "chart.bar.doc.horizontal", help: "Each category's change in dollars, split into its effects: bars to the right added spending, to the left took it off.") {
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
        return Box(title: "This Year by Category and Driver", symbol: "square.stack.3d.up", help: "Both dimensions of every dollar this year: the category it was spent on and its primary driver. Assign drivers with rules (Rules) and tags on single entries (Entries).") {
            Chart(slices) { s in
                BarMark(x: .value("Category", s.category), y: .value("Dollars", s.amount))
                    .foregroundStyle(by: .value("Driver", s.driver))
            }
            .chartXScale(domain: order.filter { n in slices.contains { $0.category == n } })
            .chartForegroundStyleScale(domain: drivers, range: [Color.orange, .blue, .cyan, .purple, .pink, .teal, .gray.opacity(0.5)])
            .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(money(d)) } } } }
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
    @AppStorage("spendingEntriesPeriod") private var period = "current"
    @AppStorage(RowsStepper.key) private var tableRows = RowsStepper.standard
    @State private var onlyUnassigned = false
    @State private var category = ""
    @State private var search = ""
    @State private var selected = Set<SpendingEntry.ID>()
    @State private var tagging: [SpendingEntry]?
    @State private var ruleFor: RuleTarget?

    private var shown: [SpendingEntry] {
        let q = search.lowercased()
        return entries.filter { e in
            (period == "both" || (period == "current") == (e.date >= data.start && e.date <= data.end))
                && (!onlyUnassigned || e.driver == nil)
                && (category.isEmpty || (e.category ?? SpendingEngine.unassigned) == category)
                && (q.isEmpty || [e.payee, e.description, e.expenseAccount, e.event, e.register].contains { ($0 ?? "").lowercased().contains(q) })
        }
        .sorted { $0.date > $1.date }
    }

    static let text = TableText<SpendingEntry>(
        titles: ["Date", "From", "Payee", "Description", "Expense account", "Amount", "Category", "Driver", "Member", "Event"],
        cells: { e in [e.date, e.register ?? e.sourceTitle, e.payee ?? "", e.description ?? "", e.expenseAccount ?? "",
                       String(format: "%.2f", e.amount), e.category ?? "", SpendingDriver.title(e.driver), e.memberId.map(String.init) ?? "", e.event ?? ""] })

    var body: some View {
        let rows = shown
        Box(title: "Spending Entries", symbol: "list.bullet.rectangle", help: "Every spending dollar in the period: checks and debits in an expense account, card charges and credits, and expense-ledger items not already a card or check entry. Each shows its category and driver and where they came from (the entry's own tag, its target account's rule, its expense account's rule). Double-click an entry, or select several and right-click, to tag them — a category, a driver, a family member, an event — or to set the rule for their target or expense account.") {
            HStack(spacing: 10) {
                Picker("", selection: $period) {
                    Text("This year").tag("current"); Text("Earlier year").tag("prior"); Text("Both").tag("both")
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 280)
                Picker("Category", selection: $category) {
                    Text("All").tag("")
                    ForEach(setup.categories) { c in Text(c.name).tag(c.code) }
                    Text("Not assigned").tag(SpendingEngine.unassigned)
                }
                .frame(maxWidth: 220)
                Toggle("No driver yet", isOn: $onlyUnassigned).toggleStyle(.checkbox)
                TextField("Search payee, description, event", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                Spacer()
                Text("\(rows.count) entries, \(money(rows.map(\.amount).reduce(0, +)))").monospacedDigit().foregroundStyle(.secondary)
                RowsStepper(rows: $tableRows)
            }
            Table(rows, selection: $selected) {
                TableColumn("Date") { e in Text(shortDay(e.date)).monospacedDigit() }.width(min: 70, ideal: 80)
                TableColumn("From") { e in Text(e.register ?? e.sourceTitle).foregroundStyle(.secondary).help(e.sourceTitle) }.width(min: 60, ideal: 100)
                TableColumn("Payee") { e in Text(e.payee ?? "").help(e.description ?? "") }.width(min: 100, ideal: 180)
                TableColumn("Expense account") { e in Text(e.expenseAccount ?? "").foregroundStyle(.secondary) }.width(min: 80, ideal: 130)
                TableColumn("Amount") { e in Text(money2(e.amount)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing) }.width(min: 70, ideal: 90)
                TableColumn("Category") { e in
                    Text(setup.category(e.category)?.name ?? "Not assigned").foregroundStyle(e.category == nil ? .secondary : .primary)
                        .help(e.categoryFrom.map { "From the \($0)" } ?? "No rule or tag")
                }.width(min: 80, ideal: 110)
                TableColumn("Driver") { e in
                    Text(SpendingDriver.title(e.driver)).foregroundStyle(e.driver == nil ? .secondary : .primary)
                        .help(e.driverFrom.map { "From the \($0)" } ?? "No rule or tag: counts as usage")
                }.width(min: 80, ideal: 130)
                TableColumn("Member") { e in Text(setup.member(e.memberId)?.name ?? "").foregroundStyle(.secondary) }.width(min: 50, ideal: 80)
                TableColumn("Event") { e in
                    HStack(spacing: 3) {
                        if e.tagged { Image(systemName: "tag.fill").font(.caption2).foregroundStyle(.secondary) }
                        Text(e.event ?? "")
                    }
                    .help(e.notes ?? "")
                }.width(min: 60, ideal: 110)
            }
            .tableText()
            .copiesSelectedRows(rows, selected: selected, as: Self.text)
            .contextMenu(forSelectionType: SpendingEntry.ID.self) { ids in
                let picked = rows.filter { ids.contains($0.id) }
                Button(picked.count > 1 ? "Tag \(picked.count) Entries…" : "Tag Entry…") { tagging = picked }.disabled(picked.isEmpty)
                if picked.contains(where: \.tagged) {
                    Button("Clear Tags") { Task { await clear(picked.filter(\.tagged)) } }
                }
                if picked.count == 1, let e = picked.first {
                    Divider()
                    if let id = e.payeeId { Button("Rule for Target Account \(e.payee ?? "")…") { ruleFor = RuleTarget(payeeId: id, name: e.payee ?? "") } }
                    if let id = e.expenseAccountId { Button("Rule for Expense Account \(e.expenseAccount ?? "")…") { ruleFor = RuleTarget(expenseAccountId: id, name: e.expenseAccount ?? "") } }
                }
                Divider()
                CopyRowsButton(rows: rows, ids: ids, text: Self.text)
            } primaryAction: { ids in
                tagging = rows.filter { ids.contains($0.id) }
            }
            .frame(minHeight: PortSettings.shared.tableHeight(rows: min(max(rows.count, 8), tableRows)))
        }
        .sheet(isPresented: Binding(get: { tagging != nil }, set: { if !$0 { tagging = nil } })) {
            if let picked = tagging { SpendingTagSheet(setup: setup, entries: picked) { body in await tag(picked, body) } }
        }
        .sheet(item: $ruleFor) { target in
            SpendingRuleSheet(setup: setup, target: target) { ruleSaved($0) }
        }
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
}

/// What a rule is for: an expense account or a target account.
struct RuleTarget: Identifiable {
    var expenseAccountId: Int? = nil
    var payeeId: Int? = nil
    var name: String
    var id: String { "\(expenseAccountId ?? -1)-\(payeeId ?? -1)" }
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
            Form {
                DimensionPickers(setup: setup, category: $category, driver: $driver, member: $member)
                TextField("Event", text: $event, prompt: Text("Philmont 2026, a wedding, a roof repair"))
                TextField("Notes", text: $notes)
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
            else { Text("What is set here overrides the target and expense accounts' rules for these entries; what is left as the rule's follows them. Nothing set takes the tag off.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
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

private struct SpendingRuleSheet: View {
    var setup: SpendingSetup
    var target: RuleTarget
    var saved: (SpendingSetup) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var category = ""
    @State private var driver = ""
    @State private var member = 0
    @State private var error: String?

    private var rule: SpendingRule? {
        target.payeeId.flatMap { setup.rule(payee: $0) } ?? target.expenseAccountId.flatMap { setup.rule(expenseAccount: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rule for \(target.name)").heading(.heading)
            Text(target.payeeId != nil ? "Every entry with this target account, unless the entry has a tag of its own. Left blank, the expense account's rule decides."
                 : "Every entry in this expense account, unless its target account's rule or its own tag says otherwise.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form { DimensionPickers(setup: setup, category: $category, driver: $driver, member: $member, blank: "None") }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    Task {
                        do {
                            saved(try await SpendingClient.saveRule(["expenseAccountId": null(target.expenseAccountId), "payeeId": null(target.payeeId),
                                                                    "category": category, "driver": driver,
                                                                    "memberId": member == 0 ? NSNull() : member, "notes": null(rule?.notes)]))
                            dismiss()
                        } catch { self.error = describe(error) }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 460)
        .onAppear { category = rule?.category ?? ""; driver = rule?.driver ?? ""; member = rule?.memberId ?? 0 }
    }
}

// MARK: - Rules

private struct SpendingRulesTab: View {
    var setup: SpendingSetup
    /// This year's entries, for each account's spending.
    var entries: [SpendingEntry]
    var saved: (SpendingSetup) -> Void
    @State private var search = ""
    @State private var showAll = false
    @State private var problem: String?

    var body: some View {
        let byAccount = Dictionary(grouping: entries.filter { $0.expenseAccountId != nil }, by: { $0.expenseAccountId! }).mapValues { $0.map(\.amount).reduce(0, +) }
        let byPayee = Dictionary(grouping: entries.filter { $0.payeeId != nil }, by: { $0.payeeId! }).mapValues { $0.map(\.amount).reduce(0, +) }
        if let problem { Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
        Box(title: "Expense Account Rules", symbol: "briefcase", help: "The category, primary driver and family member of each expense account's spending: the default for every entry in it. A target account's rule, or an entry's own tag, overrides it. Changes save as you pick, and the entries and attribution follow them.") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                header
                ForEach(setup.expenseAccounts) { a in
                    ruleRow(name: a.name, spent: byAccount[a.id] ?? 0, rule: setup.rule(expenseAccount: a.id),
                            target: ["expenseAccountId": a.id], blank: "None")
                }
            }
        }
        let q = search.lowercased()
        let payees = setup.payees.filter { p in
            (byPayee[p.id] != nil || setup.rule(payee: p.id) != nil) && (q.isEmpty || p.name.lowercased().contains(q))
        }
        .sorted { (byPayee[$0.id] ?? 0) > (byPayee[$1.id] ?? 0) }
        Box(title: "Target Account Rules", symbol: "arrow.left.arrow.right.square", help: "Rules for single target accounts — a tutoring service as Education, Lifecycle Transition, for one child; a scout council as Activities — overriding their expense account's. Listed: the target accounts with spending this year or a rule, most spent first. \"Account's\" leaves the expense account's rule in charge.") {
            HStack {
                TextField("Search target accounts", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Spacer()
                Text("\(payees.count) target accounts").foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                header
                ForEach(showAll ? payees : Array(payees.prefix(40))) { p in
                    ruleRow(name: p.name, spent: byPayee[p.id] ?? 0, rule: setup.rule(payee: p.id), target: ["payeeId": p.id], blank: "Account's")
                }
            }
            if payees.count > 40 {
                Button(showAll ? "Show the 40 most spent" : "Show all \(payees.count)") { showAll.toggle() }
            }
        }
    }

    private var header: some View {
        GridRow {
            Text("Account"); Text("This year").gridColumnAlignment(.trailing); Text("Category"); Text("Driver"); Text("Member")
        }
        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }

    private func ruleRow(name: String, spent: Double, rule: SpendingRule?, target: [String: Any], blank: String) -> some View {
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
            Text(name).lineLimit(1)
            Text(money(spent)).monospacedDigit().foregroundStyle(.secondary)
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
