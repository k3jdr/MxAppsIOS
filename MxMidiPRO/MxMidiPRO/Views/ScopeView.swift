//
//  ScopeView.swift — MxMidiPRO
//
//  MMM's oscilloscope-style display: the last few seconds of the log's messages plotted 0 … 127, newest at the
//  right. Velocity is a step line holding each note-on's velocity; pressures, pitch bend and the chosen controller
//  are joined point to point. Every trace holds its last value to the right edge. It follows the log's filters and
//  freezes with Pause.
//

import SwiftUI

struct ScopeView: View {
    let store: MonitorStore

    var body: some View {
        // Read so a filter change while paused still redraws.
        let _ = (store.reloadRevision, store.traces, store.controllerNumber, store.scopeSeconds)
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: store.paused)) { _ in
            Canvas { context, size in
                ScopeRenderer(store: store).draw(in: &context, size: size)
            }
        }
        .accessibilityLabel("Scope of the last \(Int(store.scopeSeconds)) seconds")
    }
}

@MainActor
struct ScopeRenderer {
    let store: MonitorStore

    func draw(in context: inout GraphicsContext, size: CGSize) {
        let window = store.scopeSeconds
        let now = store.paused ? store.pausedAt : HostClock.now
        let plot = CGRect(x: 0, y: 6, width: size.width, height: max(1, size.height - 12))

        func y(_ value: Double) -> CGFloat { plot.maxY - CGFloat(value / 127) * plot.height }
        func x(_ time: UInt64) -> CGFloat {
            let age = HostClock.interval(from: time, to: now)
            return min(size.width, max(0, size.width * CGFloat(1 - age / window)))
        }

        // Grid: quarter lines across, a tick every second (every 5 s on the 30 s scope).
        for value in [32.0, 64.0, 96.0] {
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y(value)))
            line.addLine(to: CGPoint(x: size.width, y: y(value)))
            context.stroke(line, with: .color(Panel.screenLine), style: StrokeStyle(lineWidth: 1, dash: value == 64 ? [] : [2, 4]))
        }
        let elapsed = HostClock.interval(from: store.startTime, to: now)
        let step = window > 15 ? 5.0 : 1.0
        var tick = (floor(elapsed / step)) * step
        while tick > elapsed - window {
            let px = size.width * CGFloat(1 - (elapsed - tick) / window)
            var line = Path()
            line.move(to: CGPoint(x: px, y: plot.maxY - 6))
            line.addLine(to: CGPoint(x: px, y: plot.maxY + 6))
            context.stroke(line, with: .color(Panel.screenLine), lineWidth: 1)
            tick -= step
        }

        let events = store.events
        let enabled = Trace.allCases.filter { store.traces.contains($0) }
        guard !enabled.isEmpty else { return }

        // Messages in the window, found from the newest back; stop after a run of older ones (arrival order isn't
        // strictly time order: Logic Pro schedules some output ahead).
        let windowTicks = HostClock.ticks(window)
        let start = now > windowTicks ? now - windowTicks : 0
        var first = events.count
        var older = 0
        var i = events.count - 1
        while i >= 0 && older < 64 {
            if events[i].hostTime >= start { first = i; older = 0 } else { older += 1 }
            i -= 1
        }

        if events.isEmpty {
            context.draw(Text("Play a controller, or press Play in Logic Pro")
                .font(.system(size: 12)).foregroundStyle(Panel.screenDim),
                         at: CGPoint(x: size.width / 2, y: size.height / 2))
        }

        let cc = store.controllerNumber
        for trace in enabled {
            var path = Path()
            var lastY: CGFloat?
            // The value the trace had when the window starts.
            var j = first - 1
            var looked = 0
            while j >= 0 && looked < 20_000 {
                if let value = trace.value(of: events[j], controller: cc) {
                    lastY = y(value)
                    path.move(to: CGPoint(x: 0, y: y(value)))
                    break
                }
                j -= 1
                looked += 1
            }
            if first < events.count {
                for k in first..<events.count {
                    guard let value = trace.value(of: events[k], controller: cc) else { continue }
                    let point = CGPoint(x: x(events[k].hostTime), y: y(value))
                    if let previous = lastY {
                        if trace == .velocity { path.addLine(to: CGPoint(x: point.x, y: previous)) }
                        path.addLine(to: point)
                    } else {
                        path.move(to: point)
                    }
                    lastY = point.y
                }
            }
            guard let lastY else { continue }
            path.addLine(to: CGPoint(x: size.width, y: lastY))
            context.stroke(path, with: .color(trace.color), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
        }
    }
}
