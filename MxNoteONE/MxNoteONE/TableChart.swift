//
//  TableChart.swift
//  MxNoteONE
//
//  Charts from table data, as in Excel: select columns in a table and insert
//  a Column, Bar, Line, Area, Pie or Donut chart. The first column gives the
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
        case column, bar, line, area, pie, donut
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .column: "chart.bar"
            case .bar: "chart.bar.xaxis"
            case .line: "chart.xyaxis.line"
            case .area: "chart.line.uptrend.xyaxis"
            case .pie: "chart.pie"
            case .donut: "circle.circle"
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
}

struct ChartContent: View {
    let spec: ChartSpec

    private var points: [ChartPoint] {
        var result: [ChartPoint] = []
        for series in spec.series {
            for (i, category) in spec.categories.enumerated() where i < series.values.count {
                guard let value = series.values[i] else { continue }
                // Repeated category names stay separate bars.
                let label = spec.categories[..<i].contains(category) ? "\(category) (\(i + 1))" : (category.isEmpty ? "(\(i + 1))" : category)
                result.append(ChartPoint(id: result.count, category: label, series: series.name, value: value))
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
        menu.addItem(ClosureMenuItem("Legend", state: spec.legend) { [weak self] in
            self?.update({ $0.legend.toggle() }, actionName: "Legend")
        })
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
