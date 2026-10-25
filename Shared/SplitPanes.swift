//
//  SplitPanes.swift
//  Shared by MxDataHUB and MxAcctMGR (MxAppsIOS/Shared)
//
//  Two panes side by side with a divider to drag, in place of HSplitView. The AppKit split view behind HSplitView
//  laid panes out at about their ideal widths and kept them there when the window narrowed or the sidebar came
//  back, so a screen grew wider than its column and was centred in the window: the sidebar fell off the left edge
//  and the screen's right side was cut off. Here the leading pane has the width the divider sets (remembered per
//  screen, kept within its range and to what leaves the trailing pane its minimum) and the trailing pane takes the
//  rest. Neither pane's content can change the window's minimum size.
//

import AppKit
import SwiftUI

struct SplitPanes<Leading: View, Trailing: View>: View {
    private let widths: ClosedRange<Double>
    private let trailingMinimum: Double
    private let leading: Leading
    private let trailing: Trailing
    @AppStorage private var width: Double
    /// The width while the divider is dragged; saved to `width` when the drag ends.
    @State private var dragWidth: Double?

    /// `id` names the remembered width; `widths` is the leading pane's minimum and maximum, `ideal` its first width.
    init(id: String, widths: ClosedRange<Double>, ideal: Double, trailingMinimum: Double,
         @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.widths = widths
        self.trailingMinimum = trailingMinimum
        self.leading = leading()
        self.trailing = trailing()
        _width = AppStorage(wrappedValue: ideal, "split." + id)
    }

    var body: some View {
        GeometryReader { geometry in
            let upper = max(widths.lowerBound,
                            min(widths.upperBound, Double(geometry.size.width) - trailingMinimum - SplitHandle.width))
            let range = widths.lowerBound...upper
            let shown = min(max(dragWidth ?? width, range.lowerBound), range.upperBound)
            HStack(spacing: 0) {
                leading
                    .frame(width: shown)
                    .frame(maxHeight: .infinity)
                    .clipped()
                SplitHandle(width: shown, range: range) { dragWidth = $0 } ended: {
                    if let dragWidth { width = dragWidth }
                    dragWidth = nil
                }
                trailing
                    // A constant minimum (as MxDataHUB's fixedColumnMinimum): one taken from the content changed with it and
                    // made AppKit loop on updating constraints.
                    .frame(minWidth: trailingMinimum, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                    .clipped()
            }
        }
    }
}

/// The divider between two panes: drag it to give either more room. The drag is measured in window coordinates:
/// measured in the divider's own, which moves with every step, the width see-sawed and the panes flickered.
struct SplitHandle: View {
    static let width = 7.0

    var width: Double
    var range: ClosedRange<Double>
    var changed: (Double) -> Void
    var ended: () -> Void
    @State private var dragStart: Double?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .padding(.horizontal, (Self.width - 1) / 2)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    let start = dragStart ?? width
                    dragStart = start
                    changed(min(max(start + drag.translation.width, range.lowerBound), range.upperBound))
                }
                .onEnded { _ in
                    dragStart = nil
                    ended()
                })
    }
}
