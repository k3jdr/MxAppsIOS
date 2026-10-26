//
//  Components.swift
//  MxAcctMGR
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

    /// The points as one selectable text, a bullet before each.
    static func text(_ points: [String]) -> NSAttributedString {
        var lines = RichLines()
        lines.bullets(points, font: RichLines.calloutFont)
        return lines.result
    }

    private var collapsed: Bool { store.collapsedLessons.contains(id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if collapsed { store.collapsedLessons.remove(id) } else { store.collapsedLessons.insert(id) }
            } label: {
                HStack {
                    Image(systemName: symbol).foregroundStyle(.yellow)
                    Text(title).heading(.name)
                    Spacer()
                    Image(systemName: collapsed ? "chevron.down" : "chevron.up").font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .plainButton()
            .help(collapsed ? "Show why this step matters" : "Hide the lesson")
            if !collapsed {
                // One text, so a drag selects across the points (Shared/Copy/SelectableText.swift).
                SelectableText(text: Self.text(points))
            }
        }
        .padding(12)
        .background(Color.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.yellow.opacity(0.25)))
        .quickHelpArea(QuickHelpItem(title: title, detail: points.joined(separator: " "), symbol: symbol))
        .copySection(title)
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
            Text(value).heading(.figure).foregroundStyle(tint)
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
                Text(title).heading(.name)
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .quickHelpArea(help.map { QuickHelpItem(title: title, detail: $0, symbol: symbol ?? "rectangle.dashed") })
        .copySection(title)
    }
}

extension View {
    /// A button drawn as its label alone (a card, a day, a heading that folds): the screens' text is selectable, but
    /// not a button's, so a click on its words still presses it.
    func plainButton() -> some View {
        buttonStyle(.plain).textSelection(.disabled)
    }
}

/// How many of a table's rows show at once — the rest scroll inside it: fewer leave room for the rest of the page, so
/// it needs less scrolling. One choice for every table (the registers, statements, Target and Secure Accounts), kept
/// under `key`: changing it in one changes them all.
struct RowsStepper: View {
    static let key = "tableRows"
    static let standard = 22
    @Binding var rows: Int
    var range: ClosedRange<Int> = 6...40
    var what = "table"

    var body: some View {
        Stepper("Rows: \(rows)", value: $rows, in: range)
            .monospacedDigit()
            .fixedSize()
            .help("How many of the \(what)'s rows show at once — the same for every table; the rest scroll inside it. Fewer leave room for the rest of the page.")
    }
}

/// Back and Next along the guide, with where they lead.
struct StepFooter: View {
    @Bindable var store: PortStore

    var body: some View {
        HStack {
            if let prev = previous {
                Button { store.go(prev) } label: { Label(label(prev), systemImage: "chevron.left") }
                    .help("Previous step: \(prev.fullTitle) (⌥⌘↑)")
                    .quickHelp("Previous Step", "Back to \(prev.fullTitle), the step before this one in the guide. (⌘[ goes back to where you were, as in a browser.)", shortcut: "⌥⌘↑")
            }
            Spacer()
            if let next = next {
                Button { store.go(next) } label: {
                    HStack { Text("Next: \(label(next))"); Image(systemName: "chevron.right") }
                }
                .buttonStyle(.borderedProminent)
                .help("Next step: \(next.fullTitle) (⌥⌘↓)")
                .quickHelp("Next Step", "On to \(next.fullTitle), the next step in the guide.", shortcut: "⌥⌘↓")
            }
        }
        .padding(.top, 8)
    }

    private var next: Screen? { store.screen.next }

    private func label(_ s: Screen) -> String { store.title(s) }
    private var previous: Screen? { store.screen.previous }
}


struct EducationalBanner: View {
    /// The earnings screens: real companies' reports as published.
    var realData = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "graduationcap")
            Text(realData ? "Educational use: real earnings reports from Nasdaq.com and FMP, as published — not investment advice and not a recommendation to buy or sell anything."
                 : "Educational: real securities and prices from the security master; scenarios and simulations are labelled as such — not investment advice, not a forecast, and not a recommendation to buy or sell anything.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.quaternary.opacity(0.4), in: Capsule())
        .help("MxAcctMGR teaches how portfolio tools work. Talk to a licensed adviser about your own situation.")
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
    /// Scrolls sideways when the content is wider than the window gives it, from its left edge, instead of making
    /// the page wider than its column (which pushes it under the sidebar or past the window's edge).
    var scrollsHorizontally = false
    @ViewBuilder var content: Content

    var body: some View {
        if scrollsHorizontally {
            // The reader is flexible, so the page never asks the window for more width than it has.
            GeometryReader { geo in
                ScrollView([.vertical, .horizontal]) {
                    PageWidth(available: geo.size.width, widest: 1180) { column }
                }
            }
        } else {
            ScrollView {
                column
                    .frame(maxWidth: 1180, alignment: .leading)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title ?? store.title(store.screen)).heading(.pageTitle)
                // Settings ▸ Guidance ▸ Minimal hides the introduction, Brief and Minimal the lesson.
                if PortSettings.shared.showsIntroductions {
                    Text(subtitle).heading(.pageSubtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if store.screen.group == .mine { MyPortfolioBar(store: store) }
            if !lesson.isEmpty, PortSettings.shared.showsLessons {
                LessonCard(store: store, id: store.screen.rawValue, title: lessonTitle, points: lesson)
            }
            content
            StepFooter(store: store)
        }
        .padding(20)
    }
}

/// A page column laid out at the width available (at most `widest`, centered when the window is wider), or wider
/// when its content can't fit in that: then it is as wide as the content needs, from the left edge, and the scroll
/// view around it scrolls sideways. A frame would keep the width and let the content spill out of it instead.
private struct PageWidth: Layout {
    var available: CGFloat
    var widest: CGFloat

    private var target: CGFloat { min(available, widest) }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews.first?.sizeThatFits(ProposedViewSize(width: target, height: proposal.height)) ?? .zero
        return CGSize(width: max(available, size.width), height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let page = subviews.first else { return }
        let width = max(target, page.sizeThatFits(ProposedViewSize(width: target, height: bounds.height)).width)
        page.place(at: CGPoint(x: bounds.minX + max(0, (bounds.width - width) / 2), y: bounds.minY), anchor: .topLeading,
                   proposal: ProposedViewSize(width: width, height: bounds.height))
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


/// At the top of every Investments step: whose account this is, how it is run, and where to start it from.
struct MyPortfolioBar: View {
    @Bindable var store: PortStore

    var body: some View {
        Group {
            if store.openPortfolio != nil { openBar } else { noneOpen }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .quickHelpArea("My Portfolio", "The open portfolio, kept in the security master (MxDataHUB's srm database) through the accounts service: holdings, tax lots, preferences and every saved version. One is open at a time — File ▸ New Portfolio…, Open Portfolio…, Save (⌘S), Revert to Saved, Close Portfolio. Edits wait for Save; leaving a portfolio with unsaved changes asks to Save or Discard. Choose how you run it — active or passive index — and steps 4 and 5 follow.", symbol: "person.crop.circle")
    }

    private var noneOpen: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.questionmark").font(.title2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("No portfolio open").heading(.name)
                Text("Open one from the security master or create a new one; the steps then work on it.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("New Portfolio…") { store.showNewPortfolio = true }
            Button("Open Portfolio…") { store.showOpenPortfolio = true }.keyboardShortcut(.defaultAction)
        }
    }

    private var openBar: some View {
        let p = store.portfolio
        let dirty = store.isDirty
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("\(p.name) · \(p.srmCode ?? "")").heading(.name)
                        Text(store.openVersion == 0 ? "not saved yet" : "version \(store.openVersion)")
                            .font(.caption).foregroundStyle(.secondary)
                        if dirty {
                            Text("Edited").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Color.orange.opacity(0.2), in: Capsule())
                                .help("Not saved: " + store.looseEnds.joined(separator: "; "))
                        }
                    }
                    Text("\(p.account.rawValue) · \(money(p.total)) · \(p.holdings.count) holdings · vs \(p.benchmark)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
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
                Button { Task { await store.saveSRMAccount() } } label: { Label("Save", systemImage: "square.and.arrow.down") }
                    .disabled(!dirty)
                    .help("Save the portfolio — holdings, lots, benchmark, approach and preferences — as its next version (⌘S)")
                Button("Revert") { store.resetMyPortfolio() }
                    .disabled(!dirty)
                    .help("Drop the unsaved changes and read the saved version again (File ▸ Revert to Saved)")
                Button("Open…") { store.showOpenPortfolio = true }
                    .help("Open another portfolio (File ▸ Open Portfolio…, ⌘O)")
                Button("New…") { store.showNewPortfolio = true }
                    .help("Create a portfolio in the security master (File ▸ New Portfolio…, ⌘N)")
                Button("Decisions…") { store.showDecisions = true }
                    .help("What was decided for this portfolio and why (Portfolio ▸ Decisions…, ⌥⌘D)")
                if p.holdings.contains(where: \.unpriced) {
                    Button { Task { await store.loadSRMPrices() } } label: { Label("Load Prices", systemImage: "arrow.down.circle") }
                        .help("Ask the srm-loader service to load prices for holdings without them (srm.py load nasdaq-prices: Nasdaq.com, free, no API key)")
                }
                if store.srmBusy { ProgressView().controlSize(.small) }
                Text(store.srmStatus ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
                Menu("Start From a Sample") {
                    ForEach(store.portfolios.filter { $0.id != "mine" }) { s in Button(s.name) { store.copyToMine(s) } }
                }
                .fixedSize()
                .disabled(!store.accountsLoaded)
                .help("Replace the open portfolio's holdings with a copy of a sample account's holdings, lots and benchmark (saved when you save)")
            }
        }
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
                    Text(title).heading(.name)
                    if !summary.isEmpty { Text(summary).font(.callout).foregroundStyle(.secondary) }
                    Spacer()
                    Text(collapsed ? "Show" : "Hide").font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .plainButton()
            .help(collapsed ? "Show \(title.lowercased())" : "Hide \(title.lowercased())")
            if !collapsed { content }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .quickHelpArea(QuickHelpItem(title: title, detail: help, symbol: symbol))
        .copySection(title)
    }
}

/// Cards in as many columns as fit (each at least `minimum` wide), row after row — what LazyVGrid with an adaptive
/// column does, but not lazy: every card exists, also those scrolled out of sight, so Edit ▸ Copy Page Text and Copy
/// Section (Shared/Copy/PageText.swift) copy all of them, not just the ones on screen. For a handful of cards.
struct AdaptiveColumns: Layout {
    var minimum: CGFloat
    var spacing: CGFloat
    var rowSpacing: CGFloat

    private func columns(_ width: CGFloat) -> (count: Int, width: CGFloat) {
        let n = max(1, Int((width + spacing) / (minimum + spacing)))
        return (n, max(0, (width - spacing * CGFloat(n - 1)) / CGFloat(n)))
    }

    /// Each row's height (its tallest card) at this width.
    private func rowHeights(_ subviews: Subviews, width: CGFloat) -> [CGFloat] {
        let c = columns(width)
        return stride(from: 0, to: subviews.count, by: c.count).map { start in
            subviews[start..<min(start + c.count, subviews.count)]
                .map { $0.sizeThatFits(ProposedViewSize(width: c.width, height: nil)).height }.max() ?? 0
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minimum
        let heights = rowHeights(subviews, width: width)
        return CGSize(width: width, height: heights.reduce(0, +) + rowSpacing * CGFloat(max(0, heights.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let c = columns(bounds.width)
        let heights = rowHeights(subviews, width: bounds.width)
        var y = bounds.minY
        for (row, height) in heights.enumerated() {
            for column in 0..<c.count {
                let i = row * c.count + column
                guard i < subviews.count else { break }
                subviews[i].place(at: CGPoint(x: bounds.minX + CGFloat(column) * (c.width + spacing), y: y),
                                  anchor: .topLeading, proposal: ProposedViewSize(width: c.width, height: nil))
            }
            y += height + rowSpacing
        }
    }
}
