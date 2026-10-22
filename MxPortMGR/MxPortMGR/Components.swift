//
//  Components.swift
//  MxPortMGR
//
//  Pieces every screen uses: the "Why this step" lesson card, metric tiles, boxed sections, the step footer that
//  walks a path, and the educational-use banner.
//

import SwiftUI

/// "Why this step": the idea behind a screen, before its numbers. Collapsible; remembered per screen.
struct LessonCard: View {
    @Bindable var store: PortStore
    var id: String
    var title: String
    var points: [String]
    var symbol = "lightbulb"

    private var collapsed: Bool { store.collapsedLessons.contains(id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if collapsed { store.collapsedLessons.remove(id) } else { store.collapsedLessons.insert(id) }
            } label: {
                HStack {
                    Image(systemName: symbol).foregroundStyle(.yellow)
                    Text(title).font(.headline)
                    Spacer()
                    Image(systemName: collapsed ? "chevron.down" : "chevron.up").font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(collapsed ? "Show why this step matters" : "Hide the lesson")
            if !collapsed {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(points, id: \.self) { p in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•").foregroundStyle(.secondary)
                            Text(p).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .font(.callout)
                .textSelection(.enabled)
            }
        }
        .padding(12)
        .background(Color.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.yellow.opacity(0.25)))
        .quickHelpArea(QuickHelpItem(title: title, detail: points.joined(separator: " "), symbol: symbol))
    }
}

struct MetricTile: View {
    var title: String
    var value: String
    var caption: String = ""
    var tint: Color = .primary
    var help: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold).monospacedDigit()).foregroundStyle(tint)
            if !caption.isEmpty { Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
        }
        .padding(10)
        .frame(minWidth: 130, maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .help(help)
        .quickHelpArea(QuickHelpItem(title: title, detail: help, symbol: "number"))
    }
}

struct Box<Content: View>: View {
    var title: String
    var symbol: String? = nil
    var help: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).foregroundStyle(.secondary) }
                Text(title).font(.headline)
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .quickHelpArea(help.map { QuickHelpItem(title: title, detail: $0, symbol: symbol ?? "rectangle.dashed") })
    }
}

/// Back and Next along the guide, with where they lead.
struct StepFooter: View {
    @Bindable var store: PortStore

    var body: some View {
        HStack {
            if let prev = previous {
                Button { store.go(prev) } label: { Label(label(prev), systemImage: "chevron.left") }
                    .help("Previous step: \(prev.fullTitle) (⌘[)")
                    .quickHelp("Previous Step", "Back to \(prev.fullTitle).", shortcut: "⌘[")
            }
            Spacer()
            if let next = next {
                Button { store.go(next) } label: {
                    HStack { Text("Next: \(label(next))"); Image(systemName: "chevron.right") }
                }
                .buttonStyle(.borderedProminent)
                .help("Next step: \(next.fullTitle) (⌘])")
                .quickHelp("Next Step", "On to \(next.fullTitle).", shortcut: "⌘]")
            }
        }
        .padding(.top, 8)
    }

    private var next: Screen? { store.screen.next }

    private func label(_ s: Screen) -> String { store.title(s) }
    private var previous: Screen? { store.screen.previous }
}


struct EducationalBanner: View {
    /// The earnings screens show real companies' reports rather than illustrative data.
    var realData = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "graduationcap")
            Text(realData ? "Educational use: real earnings reports from Nasdaq.com and FMP, as published — not investment advice and not a recommendation to buy or sell anything."
                 : "Educational simulation with illustrative data — not investment advice, not a forecast, and not a recommendation to buy or sell anything.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.quaternary.opacity(0.4), in: Capsule())
        .help("MxPortMGR teaches how portfolio tools work. Talk to a licensed adviser about your own situation.")
        .quickHelpArea(PortHelp.disclaimer)
    }
}

/// A screen's scrolling body with its title, lesson and footer.
struct StepPage<Content: View>: View {
    @Bindable var store: PortStore
    var subtitle: String
    var lessonTitle: String = "Why this step"
    var lesson: [String]
    /// The page title, when it isn't the screen's (a report walkthrough's report).
    var title: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title ?? store.title(store.screen)).font(.largeTitle.weight(.semibold))
                    Text(subtitle).font(.title3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if store.screen.group == .mine { MyPortfolioBar(store: store) }
                if !lesson.isEmpty {
                    LessonCard(store: store, id: store.screen.rawValue, title: lessonTitle, points: lesson)
                }
                content
                StepFooter(store: store)
            }
            .padding(20)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

extension Color {
    static func signed(_ x: Double) -> Color { x > 1e-9 ? .green : x < -1e-9 ? .red : .secondary }
}

struct IssueRow: View {
    var issue: Portfolio.Issue

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.title).font(.callout.weight(.semibold))
                Text(issue.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .quickHelpArea(QuickHelpItem(title: issue.title, detail: issue.detail, symbol: icon))
    }

    private var icon: String {
        switch issue.level {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .note: "info.circle.fill"
        }
    }

    private var color: Color {
        switch issue.level {
        case .error: .red
        case .warning: .orange
        case .note: .blue
        }
    }
}

/// Horizontal bars, one row per label and one bar per series in it; negative values grow left of a centre line.
/// (Drawn directly rather than with Swift Charts so labels and bars always line up.)
struct HBars: View {
    struct Series: Hashable {
        var name: String
        var color: Color
    }
    struct Row: Identifiable {
        var id: String { label }
        var label: String
        var values: [Double]
        /// Per-bar colour overriding the series colour (signed charts: green / red).
        var colors: [Color]? = nil
    }
    var series: [Series]
    var rows: [Row]
    var unit = "%"
    var labelWidth: CGFloat = 150

    var body: some View {
        let all = rows.flatMap(\.values)
        let hi = max(all.max() ?? 0, 0), lo = min(all.min() ?? 0, 0)
        let span = max(hi - lo, 1e-9)
        VStack(alignment: .leading, spacing: 6) {
            if series.count > 1 {
                HStack(spacing: 12) {
                    ForEach(series, id: \.self) { s in
                        HStack(spacing: 4) { Circle().fill(s.color).frame(width: 8, height: 8); Text(s.name).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            ForEach(rows) { row in
                HStack(spacing: 8) {
                    Text(row.label).font(.caption).lineLimit(1).frame(width: labelWidth, alignment: .trailing)
                    GeometryReader { g in
                        let w = g.size.width, zero = w * CGFloat(-lo / span)
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(row.values.enumerated()), id: \.offset) { k, v in
                                let len = w * CGFloat(abs(v) / span)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(row.colors?[k] ?? series[min(k, series.count - 1)].color)
                                    .frame(width: max(len, v == 0 ? 0 : 1))
                                    .offset(x: v >= 0 ? zero : zero - len)
                            }
                        }
                        .frame(width: w, height: g.size.height, alignment: .leading)
                        .overlay(alignment: .leading) {
                            if lo < 0 { Rectangle().fill(.secondary.opacity(0.5)).frame(width: 1).offset(x: zero) }
                        }
                    }
                    .frame(height: CGFloat(max(row.values.count, 1)) * 7 + 4)
                    Text(row.values.map { String(format: "%.1f", $0) }.joined(separator: " / ") + unit)
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: CGFloat(52 * row.values.count), alignment: .leading)
                }
                .help("\(row.label): " + zip(series.map(\.name), row.values).map { "\($0) \(String(format: "%.2f", $1))\(unit)" }.joined(separator: ", "))
            }
        }
    }
}


/// At the top of every My Portfolio step: whose account this is, how it is run, and where to start it from.
struct MyPortfolioBar: View {
    @Bindable var store: PortStore
    @State private var code = ""

    var body: some View {
        let p = store.portfolio
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.isSRM ? "My Portfolio · \(p.srmCode ?? "")" : "My Portfolio").font(.headline)
                    Text("\(p.account.rawValue) · \(money(p.total)) · \(p.holdings.count) holdings · vs \(p.benchmark)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("Data").font(.callout)
                Picker("Data", selection: Binding(get: { p.isSRM }, set: { v in Task { await store.setMySource(srm: v) } })) {
                    Text("Illustrative universe").tag(false)
                    Text("Security master (srm)").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Illustrative: the made-up market every sample uses. Security master: real securities, prices and benchmarks in MxDataHUB's srm database on 192.168.0.223, saved there with your tax lots.")
                Text("My approach").font(.callout)
                Picker("My approach", selection: $store.myApproach) {
                    Text("Active").tag(PortfolioStyle.active)
                    Text("Passive index").tag(PortfolioStyle.passive)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Active: steps 4 and 5 are Optimize and Trades & Taxes. Passive: Build the Tracker and Rebalance Bands.")
                Picker("Account type", selection: Binding(get: { p.account }, set: { var q = store.portfolio; q.account = $0; store.portfolio = q })) {
                    ForEach(AccountType.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .help("Taxable accounts pay tax on realised gains; retirement accounts don't when you trade")
            }
            HStack(spacing: 10) {
                if p.isSRM {
                    Image(systemName: "cylinder.split.1x2").foregroundStyle(.secondary)
                    Text("Account").font(.callout)
                    TextField("Code", text: $code, onCommit: { open() }).frame(width: 150)
                        .help("The account's code in the security master (srm.portfolio.code)")
                    Menu("Open") {
                        ForEach(store.srmAccountCodes, id: \.self) { c in Button(c) { code = c; open() } }
                        if !store.srmAccountCodes.isEmpty { Divider() }
                        Button("Open \(code.isEmpty ? "…" : code)") { open() }.disabled(code.isEmpty)
                    }
                    .fixedSize()
                    Button { Task { await store.saveSRMAccount() } } label: { Label("Save", systemImage: "square.and.arrow.down") }
                        .help("Save the account and its tax lots to the security master now (it also saves a moment after every change)")
                    if p.holdings.contains(where: \.unpriced) {
                        Button { Task { await store.loadSRMPrices() } } label: { Label("Load Prices", systemImage: "arrow.down.circle") }
                            .help("Ask the srm-loader service to load prices for holdings without them (srm.py load nasdaq-prices: Nasdaq.com, free, no API key)")
                    }
                    if store.srmBusy { ProgressView().controlSize(.small) }
                    Text(store.srmStatus ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer(minLength: 0)
                } else {
                    Text("Illustrative universe: fictional companies, bonds and funds — remembered on this Mac.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Menu("Start From a Sample") {
                        ForEach(Samples.all) { p in Button(p.name) { store.copyToMine(p) } }
                        Divider()
                        Button("Reset to the Three-Fund Starter") { store.resetMyPortfolio() }
                    }
                    .fixedSize()
                    .help("Replace My Portfolio with a copy of a sample's holdings, lots and benchmark")
                }
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .onAppear { code = store.srmCode }
        .onChange(of: store.srmCode) { code = store.srmCode }
        .quickHelpArea("My Portfolio", "Your own account. Data: the illustrative universe (remembered on this Mac) or the security master — real securities and prices in MxDataHUB's srm database, saved there as a personal account with tax lots through the accounts service (port 8774). Choose how you run it — active or passive index — and steps 4 and 5 follow.", symbol: "person.crop.circle")
    }

    private func open() {
        let c = code.trimmingCharacters(in: .whitespaces)
        guard !c.isEmpty else { return }
        Task { await store.openSRMAccount(c) }
    }
}


/// A boxed section whose content folds away under its title, remembered per id (like the lesson cards).
struct CollapsibleBox<Content: View>: View {
    @Bindable var store: PortStore
    var id: String
    var title: String
    var summary: String = ""
    var symbol: String
    var help: String
    @ViewBuilder var content: Content

    private var collapsed: Bool { store.collapsedLessons.contains(id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if collapsed { store.collapsedLessons.remove(id) } else { store.collapsedLessons.insert(id) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 12)
                    Image(systemName: symbol).foregroundStyle(.secondary)
                    Text(title).font(.headline)
                    if !summary.isEmpty { Text(summary).font(.callout).foregroundStyle(.secondary) }
                    Spacer()
                    Text(collapsed ? "Show" : "Hide").font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(collapsed ? "Show \(title.lowercased())" : "Hide \(title.lowercased())")
            if !collapsed { content }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .quickHelpArea(QuickHelpItem(title: title, detail: help, symbol: symbol))
    }
}
