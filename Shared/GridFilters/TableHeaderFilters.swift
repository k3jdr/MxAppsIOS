//
//  TableHeaderFilters.swift
//  Shared (MxDataHUB's Securities list)
//
//  Excel-style filter buttons on the column headers of a SwiftUI Table, drawn like MxDataSQL's grid
//  headers: a chevron, or a funnel on an accent disc when the column is filtered, with an arrow beside
//  it when the rows are sorted by it. A button opens ColumnFilterPopover. The buttons are SwiftUI views
//  laid over the Table; their places come from the NSTableView behind it (column widths, order and
//  horizontal scrolling), which a background view finds and watches.
//

import AppKit
import SwiftUI

extension View {
    /// Puts a sort and filter button on the header of each column of this Table named in `types`
    /// (column title → SQL type). `options` is the current sorting and filters; `apply` receives new ones.
    func columnHeaderFilters(types: [String: String], options: GridQueryOptions,
                             loadValues: @escaping (String) async throws -> (values: [DistinctValue], truncated: Bool),
                             apply: @escaping (GridQueryOptions) -> Void) -> some View {
        modifier(ColumnHeaderFilters(types: types, options: options, loadValues: loadValues, apply: apply))
    }
}

private struct ColumnHeaderFilters: ViewModifier {
    var types: [String: String]
    var options: GridQueryOptions
    var loadValues: (String) async throws -> (values: [DistinctValue], truncated: Bool)
    var apply: (GridQueryOptions) -> Void

    /// Header rectangle of each listed column, in the Table's coordinates.
    @State private var headers: [String: CGRect] = [:]
    @State private var openColumn: String?

    func body(content: Content) -> some View {
        content
            .background(HeaderGeometry(titles: Set(types.keys)) { headers = $0 })
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    ForEach(headers.keys.sorted(), id: \.self) { title in
                        if let rect = headers[title] { button(title, in: rect) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()   // columns scrolled out of view
            }
    }

    private func button(_ title: String, in rect: CGRect) -> some View {
        let filtered = options.filters[title] != nil
        let sort = options.sort?.column == title ? options.sort : nil
        return HStack(spacing: 1) {
            if let sort {
                Image(systemName: sort.ascending ? "arrow.up" : "arrow.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            Button {
                openColumn = title
            } label: {
                Image(systemName: filtered ? "line.3.horizontal.decrease.circle.fill" : "chevron.down.square")
                    .font(.system(size: filtered ? 12 : 11, weight: .semibold))
                    .foregroundStyle(filtered ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary),
                                     filtered ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Sort and filter \(title)")
            .accessibilityLabel("Sort and filter \(title)")
            .popover(isPresented: Binding(get: { openColumn == title }, set: { if !$0 { openColumn = nil } }),
                     arrowEdge: .bottom) {
                ColumnFilterPopover(name: title, type: types[title] ?? "text", current: options, pendingEdits: 0,
                                    loadValues: { try await loadValues(title) },
                                    apply: apply,
                                    close: { openColumn = nil })
            }
        }
        .fixedSize()
        .frame(width: max(0, rect.width - 2), height: rect.height, alignment: .trailing)
        .offset(x: rect.minX, y: rect.minY)
    }
}

/// Finds the NSTableView behind the Table (this view is the Table's background, so it has the Table's
/// frame) and reports the listed columns' header rectangles whenever columns resize, move or scroll.
private struct HeaderGeometry: NSViewRepresentable {
    var titles: Set<String>
    var report: ([String: CGRect]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = FlippedView()
        context.coordinator.probe = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.parent = self
        // The Table's NSTableView is laid out after this view; measure on the next turn of the run loop.
        DispatchQueue.main.async { context.coordinator.update() }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
        coordinator.stopWatchingMouse()
    }

    final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: HeaderGeometry?
        weak var probe: NSView?
        private weak var tableView: NSTableView?
        private weak var header: NSTableHeaderView?
        private var reported: [String: CGRect] = [:]
        /// Watches for the mouse button let go in the table's window (the end of a column drag).
        private var mouseUps: Any?

        func update() {
            guard let probe, probe.window != nil else { return }
            if tableView?.window == nil || tableView?.headerView == nil || tableView?.headerView !== header {
                attach(findTable(covering: probe))
            }
            measure()
        }

        private func attach(_ table: NSTableView?) {
            let center = NotificationCenter.default
            center.removeObserver(self)
            tableView = table
            header = table?.headerView
            guard let table, let header else { return }
            center.addObserver(self, selector: #selector(changed(_:)), name: NSTableView.columnDidResizeNotification, object: table)
            center.addObserver(self, selector: #selector(changed(_:)), name: NSTableView.columnDidMoveNotification, object: table)
            header.postsFrameChangedNotifications = true
            center.addObserver(self, selector: #selector(changed(_:)), name: NSView.frameDidChangeNotification, object: header)
            if let clip = header.superview as? NSClipView {
                clip.postsBoundsChangedNotifications = true
                center.addObserver(self, selector: #selector(changed(_:)), name: NSView.boundsDidChangeNotification, object: clip)
            }
            // After a column is dragged wider or narrower, measure again once the button is let go — and report
            // even unchanged rectangles, in case the report made during the drag didn't reach the buttons.
            if mouseUps == nil {
                mouseUps = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                    MainActor.assumeIsolated {
                        if let self, event.window != nil, event.window === self.tableView?.window {
                            DispatchQueue.main.async { [weak self] in self?.measure(force: true) }
                        }
                    }
                    return event
                }
            }
        }

        func stopWatchingMouse() {
            if let mouseUps { NSEvent.removeMonitor(mouseUps) }
            mouseUps = nil
        }

        /// The table whose scroll view covers the middle of `probe`.
        private func findTable(covering probe: NSView) -> NSTableView? {
            guard let root = probe.window?.contentView else { return nil }
            let target = probe.convert(probe.bounds, to: nil)
            let middle = CGPoint(x: target.midX, y: target.midY)
            var best: (table: NSTableView, area: CGFloat)?
            var stack = [root]
            while let view = stack.popLast() {
                if let table = view as? NSTableView, table.headerView != nil, let scroll = table.enclosingScrollView {
                    let frame = scroll.convert(scroll.bounds, to: nil)
                    let area = frame.width * frame.height
                    if frame.contains(middle), area < best?.area ?? .infinity { best = (table, area) }
                }
                stack.append(contentsOf: view.subviews)
            }
            return best?.table
        }

        /// A column resized or moved, or the header scrolled: measure on the next turn of the run loop. A column
        /// dragged with the mouse reports its width while SwiftUI is updating the window, when a change to the
        /// buttons' places can be lost; measured after, it isn't.
        @objc private func changed(_ notification: Notification) {
            DispatchQueue.main.async { [weak self] in self?.measure() }
        }

        private func measure(force: Bool = false) {
            guard let probe, let parent, let tableView, let header else { return }
            var rects: [String: CGRect] = [:]
            for (index, column) in tableView.tableColumns.enumerated() where !column.isHidden {
                let title = column.title.isEmpty ? column.headerCell.stringValue : column.title
                guard parent.titles.contains(title) else { continue }
                rects[title] = probe.convert(header.headerRect(ofColumn: index), from: header)
            }
            guard force || rects != reported else { return }
            reported = rects
            parent.report(rects)
        }
    }
}
