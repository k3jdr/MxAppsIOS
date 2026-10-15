//
//  TableChart.swift
//  MxNoteONE
//
//  Charts from table data, as in Excel: select columns in a table and insert
//  a Column, Bar, Line, Area, Pie, Donut or Scatter chart (with a trendline),
//  with axis titles. The first column gives the
//  categories and the others the series (named by the header row). A chart
//  is its own container on the page; it follows its table as you type
//  (hidden and filtered rows are left out, as in Excel) and keeps the last
//  data it drew, so it still shows if the table goes away.
//

import AppKit
import Charts
import SwiftUI

extension Notification.Name {
    /// A table's cells changed (object: its TableModel).
    static let mxTableChanged = Notification.Name("MxTableChanged")
}

struct ChartSpec: Codable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case column, bar, line, area, pie, donut, scatter
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        /// Pie and donut charts have no axes.
        var hasAxes: Bool { self != .pie && self != .donut }
        var symbol: String {
            switch self {
            case .column: "chart.bar"
            case .bar: "chart.bar.xaxis"
            case .line: "chart.xyaxis.line"
            case .area: "chart.line.uptrend.xyaxis"
            case .pie: "chart.pie"
            case .donut: "circle.circle"
            case .scatter: "chart.dots.scatter"
            }
        }
    }

    struct Series: Codable, Hashable {
        var name: String
        var values: [Double?]
    }

    /// The source table (its element on the page), and its fields by header text (found again by name).
    var source: UUID
    var categoryField: String
    var categoryColumn: Int
    var seriesFields: [String]
    var seriesColumns: [Int]
    var kind: Kind
    var title: String
    var legend = true
    /// The data last drawn.
    var categories: [String] = []
    var series: [Series] = []
    /// The first column as numbers (scatter charts), and whether they're dates.
    var xValues: [Double?]?
    var xIsDate: Bool?
    /// Axis titles (nil or empty = none).
    var xTitle: String?
    var yTitle: String?
    /// A straight trendline (least squares) through each series of a scatter chart.
    var trendline: Bool?
    /// Colours chosen for series (pie and donut: for categories), by name.
    var colors: [String: RGBA]?
    /// How the value axis shows numbers (nil = as the table's value column does).
    var valueFormat: AxisFormat?
    /// The table's number formats of the first series and of the first column (for automatic axes).
    var sourceFormat: NumberFormat?
    var sourceXFormat: NumberFormat?

    /// Number formats for chart axes.
    enum AxisFormat: Codable, Hashable {
        case general
        case compact
        case format(NumberFormat)

        static let choices: [(String, AxisFormat)] = [
            ("General", .general), ("Number  1,234", .format(NumberFormat(kind: .number, decimals: 0))),
            ("Number  1,234.00", .format(NumberFormat(kind: .number, decimals: 2))),
            ("Currency  $1,234", .format(NumberFormat(kind: .currency, decimals: 0, symbol: "$"))),
            ("Currency  $1,234.00", .format(NumberFormat(kind: .currency, decimals: 2, symbol: "$"))),
            ("Currency  €1,234", .format(NumberFormat(kind: .currency, decimals: 0, symbol: "€"))),
            ("Currency  £1,234", .format(NumberFormat(kind: .currency, decimals: 0, symbol: "£"))),
            ("Percent  12%", .format(NumberFormat(kind: .percent, decimals: 0))),
            ("Percent  12.5%", .format(NumberFormat(kind: .percent, decimals: 1))),
            ("Compact  1.2K, 3.4M", .compact),
        ]

        func string(_ value: Double) -> String {
            switch self {
            case .general: return Formula.format(value)
            case .format(let f): return f.string(value)
            case .compact:
                let a = abs(value)
                let (div, suffix): (Double, String) = a >= 1e12 ? (1e12, "T") : a >= 1e9 ? (1e9, "B") : a >= 1e6 ? (1e6, "M") : a >= 1e3 ? (1e3, "K") : (1, "")
                let scaled = value / div
                let text = scaled == scaled.rounded() ? String(format: "%.0f", scaled) : String(format: "%.1f", scaled)
                return text + suffix
            }
        }
    }

    /// The value axis's format in use.
    var effectiveValueFormat: AxisFormat? {
        valueFormat ?? sourceFormat.map { .format($0) }
    }

    /// Default series colours (as Excel's).
    static let defaultColors: [RGBA] = [0x4472C4, 0xED7D31, 0xA5A5A5, 0xFFC000, 0x5B9BD5, 0x70AD47, 0x264478, 0x9E480E, 0x636363, 0x997300]
        .map(HighlightStyle.hex)

    /// Names the colours go with: series, or categories for pie and donut charts.
    var colorNames: [String] {
        kind == .pie || kind == .donut ? Self.labels(categories) : series.map(\.name)
    }

    func color(at index: Int, name: String) -> RGBA {
        colors?[name] ?? Self.defaultColors[index % Self.defaultColors.count]
    }

    /// Category labels as drawn (repeats and blanks numbered so each is its own bar or slice).
    static func labels(_ categories: [String]) -> [String] {
        categories.enumerated().map { i, category in
            categories[..<i].contains(category) ? "\(category) (\(i + 1))" : (category.isEmpty ? "(\(i + 1))" : category)
        }
    }
}

enum ChartBuilder {
    /// The chart's data from its table (shown rows below the header; a pivot table's grand total row is left out).
    static func refresh(_ spec: inout ChartSpec, from source: TableModel) {
        let names = PivotBuilder.fields(source)
        func column(_ name: String, _ was: Int) -> Int? { names.firstIndex(of: name) ?? (names.indices.contains(was) ? was : nil) }
        guard let categoryColumn = column(spec.categoryField, spec.categoryColumn) else { return }
        let seriesColumns = zip(spec.seriesFields, spec.seriesColumns).compactMap { column($0, $1) }
        var rows = (1..<max(1, source.rowCount)).filter { !source.isRowHidden($0) }
        if let pivot = source.data.pivot, pivot.grandTotals, let last = rows.last, last == source.rowCount - 1 { rows.removeLast() }
        spec.categoryColumn = categoryColumn
        spec.seriesColumns = seriesColumns
        spec.categories = rows.map { source.shownString(CellRef(row: $0, column: categoryColumn)) }
        var dates = true, anyX = false
        spec.xValues = rows.map { r in
            switch source.value(CellRef(row: r, column: categoryColumn)) {
            case .number(let d): dates = false; anyX = true; return d
            case .date(let d): anyX = true; return d
            default: return nil
            }
        }
        spec.xIsDate = anyX && dates
        spec.sourceFormat = seriesColumns.first.flatMap { c in rows.lazy.compactMap { source.numberFormat(CellRef(row: $0, column: c)) }.first }
        spec.sourceXFormat = rows.lazy.compactMap { source.numberFormat(CellRef(row: $0, column: categoryColumn)) }.first
        spec.series = seriesColumns.map { c in
            ChartSpec.Series(name: names[c], values: rows.map { r in
                switch source.value(CellRef(row: r, column: c)) {
                case .number(let d), .date(let d): return d
                default: return nil
                }
            })
        }
    }
}

// MARK: - Drawing

private struct ChartPoint: Identifiable {
    let id: Int
    let category: String
    let series: String
    let value: Double
    /// The x value (scatter charts).
    var x: Double?
}

struct ChartContent: View {
    let spec: ChartSpec

    private var points: [ChartPoint] {
        var result: [ChartPoint] = []
        let labels = ChartSpec.labels(spec.categories)
        for series in spec.series {
            for i in spec.categories.indices where i < series.values.count {
                guard let value = series.values[i] else { continue }
                // Repeated category names stay separate bars.
                let label = labels[i]
                let x = spec.xValues.flatMap { i < $0.count ? $0[i] : nil }
                result.append(ChartPoint(id: result.count, category: label, series: series.name, value: value, x: x))
            }
        }
        return result
    }

    private var multiSeries: Bool { spec.series.count > 1 }

    var body: some View {
        VStack(spacing: 6) {
            if !spec.title.isEmpty {
                Text(spec.title).font(.headline).foregroundStyle(.black)
            }
            if points.isEmpty {
                Text("No numbers to chart").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                chart
                    .chartLegend(spec.legend ? .visible : .hidden)
                    .modifier(AxisTitles(x: spec.kind.hasAxes ? spec.xTitle : nil, y: spec.kind.hasAxes ? spec.yTitle : nil))
                    // Series (or slice) colours: chosen ones, else Excel's.
                    .chartForegroundStyleScale(domain: spec.colorNames,
                                               range: spec.colorNames.enumerated().map { spec.color(at: $0.offset, name: $0.element).nsColor.swiftUI })
                    .modifier(ValueAxis(spec: spec))
                    // Scatter axes fit the data (as in Excel) rather than starting at zero.
                    .modifier(ScatterScale(on: spec.kind == .scatter))
                    // A fresh chart when its titles change (Swift Charts keeps an axis label's space otherwise).
                    .id("\(spec.xTitle ?? "")|\(spec.yTitle ?? "")|\(spec.kind)")
            }
        }
        .padding(10)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }

    @ViewBuilder private var chart: some View {
        let data = points
        switch spec.kind {
        case .column:
            Chart(data) { p in
                BarMark(x: .value("Category", p.category), y: .value("Value", p.value))
                    .foregroundStyle(by: .value("Series", p.series))
                    .position(by: .value("Series", p.series))
            }
        case .bar:
            Chart(data) { p in
                BarMark(x: .value("Value", p.value), y: .value("Category", p.category))
                    .foregroundStyle(by: .value("Series", p.series))
                    .position(by: .value("Series", p.series))
            }
        case .line:
            Chart(data) { p in
                LineMark(x: .value("Category", p.category), y: .value("Value", p.value))
                    .foregroundStyle(by: .value("Series", p.series))
                PointMark(x: .value("Category", p.category), y: .value("Value", p.value))
                    .foregroundStyle(by: .value("Series", p.series))
            }
        case .area:
            Chart(data) { p in
                AreaMark(x: .value("Category", p.category), y: .value("Value", p.value))
                    .foregroundStyle(by: .value("Series", p.series))
            }
        case .scatter:
            // Points at (x, y); rows without a number in the first column are left out.
            let plotted = data.filter { $0.x != nil }
            let date = spec.xIsDate == true
            Chart {
                ForEach(plotted) { p in
                    if date {
                        PointMark(x: .value("X", Formula.date(fromSerial: p.x!)), y: .value("Value", p.value))
                            .foregroundStyle(by: .value("Series", p.series))
                    } else {
                        PointMark(x: .value("X", p.x!), y: .value("Value", p.value))
                            .foregroundStyle(by: .value("Series", p.series))
                    }
                }
                if spec.trendline == true {
                    ForEach(Self.trendlines(plotted), id: \.series) { line in
                        ForEach([line.start, line.end], id: \.0) { point in
                            if date {
                                LineMark(x: .value("X", Formula.date(fromSerial: point.0)), y: .value("Value", point.1),
                                         series: .value("Trend", line.series + " trend"))
                                    .foregroundStyle(by: .value("Series", line.series))
                                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                            } else {
                                LineMark(x: .value("X", point.0), y: .value("Value", point.1), series: .value("Trend", line.series + " trend"))
                                    .foregroundStyle(by: .value("Series", line.series))
                                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                            }
                        }
                    }
                }
            }
        case .pie, .donut:
            // One series: slices by category.
            let first = data.filter { $0.series == spec.series.first?.name && $0.value > 0 }
            Chart(first) { p in
                SectorMark(angle: .value("Value", p.value), innerRadius: .ratio(spec.kind == .donut ? 0.55 : 0), angularInset: 1)
                    .foregroundStyle(by: .value("Category", p.category))
            }
        }
    }
}

extension NSColor {
    var swiftUI: Color { Color(nsColor: self) }
}

/// Axis labels in the chosen number format (the value axis; a scatter chart's horizontal axis too).
private struct ValueAxis: ViewModifier {
    let spec: ChartSpec

    func body(content: Content) -> some View {
        let value = spec.effectiveValueFormat
        let across: ChartSpec.AxisFormat? = spec.kind == .scatter && spec.xIsDate != true ? spec.sourceXFormat.map { .format($0) } : nil
        switch spec.kind {
        case .bar:
            if let value {
                content.chartXAxis { AxisMarks { v in
                    AxisGridLine(); AxisTick()
                    AxisValueLabel { if let d = v.as(Double.self) { Text(value.string(d)) } }
                } }
            } else { content }
        case .pie, .donut:
            content
        default:
            let withY = Group {
                if let value {
                    content.chartYAxis { AxisMarks { v in
                        AxisGridLine(); AxisTick()
                        AxisValueLabel { if let d = v.as(Double.self) { Text(value.string(d)) } }
                    } }
                } else { content }
            }
            if let across {
                withY.chartXAxis { AxisMarks { v in
                    AxisGridLine(); AxisTick()
                    AxisValueLabel { if let d = v.as(Double.self) { Text(across.string(d)) } }
                } }
            } else { withY }
        }
    }
}

/// Axis titles, only when there are any.
private struct AxisTitles: ViewModifier {
    let x: String?
    let y: String?

    func body(content: Content) -> some View {
        switch (x?.isEmpty == false ? x : nil, y?.isEmpty == false ? y : nil) {
        case let (x?, y?):
            content
                .chartXAxisLabel(position: .bottom, alignment: .center) { Text(x).font(.caption.weight(.semibold)) }
                .chartYAxisLabel(position: .leading, alignment: .center) { Text(y).font(.caption.weight(.semibold)) }
        case let (x?, nil):
            content.chartXAxisLabel(position: .bottom, alignment: .center) { Text(x).font(.caption.weight(.semibold)) }
        case let (nil, y?):
            content.chartYAxisLabel(position: .leading, alignment: .center) { Text(y).font(.caption.weight(.semibold)) }
        default:
            content
        }
    }
}

private struct ScatterScale: ViewModifier {
    let on: Bool

    func body(content: Content) -> some View {
        if on {
            content
                .chartXScale(domain: .automatic(includesZero: false))
                .chartYScale(domain: .automatic(includesZero: false))
        } else {
            content
        }
    }
}

extension ChartContent {
    struct Trend {
        let series: String
        let start: (Double, Double)
        let end: (Double, Double)
    }

    /// Least-squares lines through each series' points, from its smallest to largest x.
    fileprivate static func trendlines(_ points: [ChartPoint]) -> [Trend] {
        Dictionary(grouping: points, by: \.series).compactMap { series, list in
            let xs = list.compactMap(\.x), ys = list.map(\.value)
            guard xs.count >= 2, let lo = xs.min(), let hi = xs.max(), hi > lo else { return nil }
            let n = Double(xs.count)
            let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
            let sxy = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
            let sxx = xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
            let slope = sxy / sxx, intercept = my - slope * mx
            return Trend(series: series, start: (lo, intercept + slope * lo), end: (hi, intercept + slope * hi))
        }
        .sorted { $0.series < $1.series }
    }
}

/// The chart's drawing doesn't take clicks (the container handles them: select, move, right-click).
final class ChartHostingView: NSHostingView<ChartContent> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Container

final class ChartElementView: ElementView {
    private(set) var spec: ChartSpec
    private let host: ChartHostingView
    private var reloadPending = false

    override init(element: PageElement) {
        spec = element.chart ?? ChartSpec(source: UUID(), categoryField: "", categoryColumn: 0, seriesFields: [], seriesColumns: [],
                                          kind: .column, title: "")
        host = ChartHostingView(rootView: ChartContent(spec: spec))
        super.init(element: element)
        addSubview(host)
        finishSetup()
        setWidth(frame.width)
        NotificationCenter.default.addObserver(self, selector: #selector(tableChanged(_:)), name: .mxTableChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var minWidth: CGFloat { 160 }

    override func setWidth(_ width: CGFloat) {
        let w = max(minWidth, width)
        setFrameSize(NSSize(width: w, height: Self.gripHeight + (w * 0.62).rounded()))
    }

    override func layoutContent() {
        host.frame = contentFrame
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { DispatchQueue.main.async { [weak self] in self?.reload() } }
    }

    override func makeElement() -> PageElement {
        var e = super.makeElement()
        e.chart = spec
        return e
    }

    override func indexText() -> String? { spec.title.isEmpty ? nil : spec.title }

    /// The table the chart draws from, when it's on the page.
    var sourceTable: TableElementView? {
        controller?.canvas.elementViews.first { $0.element.id == spec.source } as? TableElementView
    }

    @objc private func tableChanged(_ note: Notification) {
        guard let model = note.object as? TableModel, sourceTable?.model === model, !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.async { [weak self] in
            self?.reloadPending = false
            self?.reload()
        }
    }

    /// Draws the table's data again (keeps the last data when the table isn't on the page).
    func reload() {
        guard let source = sourceTable else { return }
        var updated = spec
        ChartBuilder.refresh(&updated, from: source.model)
        guard updated != spec else { return }
        spec = updated
        host.rootView = ChartContent(spec: spec)
        controller?.markDirty()
    }

    func update(_ change: (inout ChartSpec) -> Void, actionName: String) {
        let old = spec
        change(&spec)
        host.rootView = ChartContent(spec: spec)
        controller?.markDirty()
        controller?.undoManager?.registerUndo(withTarget: self) { view in
            view.update({ $0 = old }, actionName: actionName)
        }
        controller?.undoManager?.setActionName(actionName)
    }

    override func contextMenu() -> NSMenu {
        let menu = super.contextMenu()
        menu.addItem(.separator())
        let types = NSMenuItem(title: "Chart Type", action: nil, keyEquivalent: "")
        let typeMenu = NSMenu()
        for kind in ChartSpec.Kind.allCases {
            let item = ClosureMenuItem(kind.title, state: spec.kind == kind) { [weak self] in
                self?.update({ $0.kind = kind }, actionName: "Chart Type")
            }
            item.image = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil)
            typeMenu.addItem(item)
        }
        types.submenu = typeMenu
        menu.addItem(types)
        menu.addItem(ClosureMenuItem("Chart Title…") { [weak self] in self?.editTitle() })
        let axes = ClosureMenuItem("Axis Titles…") { [weak self] in self?.editAxisTitles() }
        axes.isEnabled = spec.kind.hasAxes
        menu.addItem(axes)
        if spec.kind == .scatter {
            menu.addItem(ClosureMenuItem("Trendline", state: spec.trendline == true) { [weak self] in
                self?.update({ $0.trendline = !($0.trendline ?? false) }, actionName: "Trendline")
            })
        }
        menu.addItem(ClosureMenuItem("Legend", state: spec.legend) { [weak self] in
            self?.update({ $0.legend.toggle() }, actionName: "Legend")
        })
        menu.addItem(colorsItem())
        if spec.kind.hasAxes {
            let format = NSMenuItem(title: "Value Axis Format", action: nil, keyEquivalent: "")
            let formats = NSMenu()
            formats.addItem(ClosureMenuItem("Automatic (as in the table)", state: spec.valueFormat == nil) { [weak self] in
                self?.update({ $0.valueFormat = nil }, actionName: "Axis Format")
            })
            formats.addItem(.separator())
            for (title, choice) in ChartSpec.AxisFormat.choices {
                formats.addItem(ClosureMenuItem(title, state: spec.valueFormat == choice) { [weak self] in
                    self?.update({ $0.valueFormat = choice }, actionName: "Axis Format")
                })
            }
            format.submenu = formats
            menu.addItem(format)
        }
        let refresh = ClosureMenuItem("Refresh Chart") { [weak self] in self?.reload() }
        refresh.isEnabled = sourceTable != nil
        menu.addItem(refresh)
        let copy = ClosureMenuItem("Copy Chart as Picture") { [weak self] in self?.copyPicture() }
        menu.addItem(copy)
        return menu
    }

    private func editTitle() {
        let alert = NSAlert()
        alert.messageText = "Chart Title"
        let field = NSTextField(string: spec.title)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let title = field.stringValue
        update({ $0.title = title }, actionName: "Chart Title")
    }

    /// Colors: a colour for each series (pie and donut charts: each slice).
    private func colorsItem() -> NSMenuItem {
        let item = NSMenuItem(title: spec.kind == .pie || spec.kind == .donut ? "Slice Colors" : "Series Colors", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        for (i, name) in spec.colorNames.enumerated() {
            let entry = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            entry.image = Palette.swatch(spec.color(at: i, name: name).nsColor)
            let colors = NSMenu()
            for (j, color) in ChartSpec.defaultColors.enumerated() {
                let choice = ClosureMenuItem("Color \(j + 1)") { [weak self] in self?.setColor(color, for: name) }
                choice.image = Palette.swatch(color.nsColor)
                colors.addItem(choice)
            }
            for extra in Palette.customItems("\(name) Color", isValid: { [weak self] in self?.window != nil },
                                             apply: { [weak self] in self?.setColor(RGBA($0), for: name) }) {
                colors.addItem(extra)
            }
            colors.addItem(.separator())
            colors.addItem(ClosureMenuItem("Automatic") { [weak self] in self?.setColor(nil, for: name) })
            entry.submenu = colors
            menu.addItem(entry)
        }
        item.submenu = menu
        return item
    }

    func setColor(_ color: RGBA?, for name: String) {
        update({ spec in
            var colors = spec.colors ?? [:]
            colors[name] = color
            spec.colors = colors.isEmpty ? nil : colors
        }, actionName: "Chart Color")
    }

    /// Axis Titles…: the horizontal and vertical axes' titles.
    private func editAxisTitles() {
        let alert = NSAlert()
        alert.messageText = "Axis Titles"
        let horizontal = NSTextField(string: spec.xTitle ?? "")
        horizontal.placeholderString = spec.kind == .bar ? "Horizontal (values)" : "Horizontal (\(spec.categoryField))"
        let vertical = NSTextField(string: spec.yTitle ?? "")
        vertical.placeholderString = spec.kind == .bar ? "Vertical (\(spec.categoryField))" : "Vertical (values)"
        let stack = NSStackView(views: [horizontal, vertical])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 280, height: 56)
        for field in [horizontal, vertical] { field.widthAnchor.constraint(equalToConstant: 280).isActive = true }
        alert.accessoryView = stack
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = horizontal
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let x = horizontal.stringValue, y = vertical.stringValue
        update({ $0.xTitle = x.isEmpty ? nil : x; $0.yTitle = y.isEmpty ? nil : y }, actionName: "Axis Titles")
    }

    /// The chart as a picture.
    func image() -> NSImage? {
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    private func copyPicture() {
        guard let image = image() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }
}
