//
//  CADSketchView.swift
//  MxNoteONE
//
//  Drawing a sketch: lines (click from point to point; back on the first closes the outline), arcs through three
//  points, circles, rectangles and polygons (click and click, or drag). Points snap to the ends and centres already
//  there, then to the grid; lengths and radii show as you draw. Select, then drag a handle to change a shape;
//  Delete removes it. Closed outlines are shaded (holes left clear) — they're what Extrude and Revolve use.
//

import AppKit
import simd

enum CADSketchTool: String, CaseIterable, Identifiable {
    case select = "Select", line = "Line", arc = "Arc", circle = "Circle", rectangle = "Rectangle", polygon = "Polygon"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .line: "line.diagonal"
        case .arc: "point.topleft.down.to.point.bottomright.curvepath"
        case .circle: "circle"
        case .rectangle: "rectangle"
        case .polygon: "hexagon"
        }
    }
    var hint: String {
        switch self {
        case .select: "Click a shape to select it; drag its handles to change it. Delete removes it."
        case .line: "Click point to point. Click the first point to close the outline; Return or Esc ends."
        case .arc: "Click where the arc starts, where it ends, then a point it passes through."
        case .circle: "Click the centre, then the edge (or drag)."
        case .rectangle: "Click one corner, then the opposite one (or drag)."
        case .polygon: "Click the centre, then a corner (or drag)."
        }
    }
}

final class CADSketchView: NSView {
    var sketch = CADSketch() { didSet { needsDisplay = true } }
    var tool: CADSketchTool = .line { didSet { pending = []; needsDisplay = true } }
    var polygonSides = 6
    private(set) var selectedEntity: UUID? { didSet { onSelect?(selectedEntity); needsDisplay = true } }
    var onAdd: ((CADSketchEntity) -> Void)?
    var onUpdate: ((CADSketchEntity) -> Void)?
    var onRemove: ((UUID) -> Void)?
    var onSelect: ((UUID?) -> Void)?

    /// Points per millimetre, and where the sketch's origin is in the view.
    private var scale: CGFloat = 4
    private var origin: CGPoint?
    private var pending: [SIMD2<Double>] = []
    private var chainStart: SIMD2<Double>?
    private var hover: SIMD2<Double>?
    private var snappedToPoint = false
    private var dragHandle: (entity: UUID, index: Int)?
    private var downAt: SIMD2<Double>?
    private var tracking: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    func select(_ id: UUID?) { selectedEntity = id }

    // MARK: Coordinates

    private var o: CGPoint { origin ?? CGPoint(x: bounds.midX, y: bounds.midY) }
    private func toView(_ q: SIMD2<Double>) -> NSPoint { NSPoint(x: o.x + CGFloat(q.x) * scale, y: o.y + CGFloat(q.y) * scale) }
    private func toSketch(_ p: NSPoint) -> SIMD2<Double> { SIMD2(Double((p.x - o.x) / scale), Double((p.y - o.y) / scale)) }

    /// Grid spacing (mm) that keeps lines at least 12 points apart.
    private var gridStep: Double {
        let steps = [0.1, 0.25, 0.5, 1, 2, 5, 10, 20, 50, 100, 200, 500]
        return steps.first { CGFloat($0) * scale >= 12 } ?? 1000
    }

    /// Fits the sketch's shapes in view.
    func fit() {
        let pts = sketch.entities.flatMap(\.points)
        guard let minX = pts.map(\.x).min(), let maxX = pts.map(\.x).max(), let minY = pts.map(\.y).min(), let maxY = pts.map(\.y).max() else {
            scale = 4; origin = nil; needsDisplay = true; return
        }
        let r = sketch.entities.filter { $0.kind == .circle || $0.kind == .polygon }.map(\.radius).max() ?? 0
        let w = max(10, maxX - minX + 2 * r), h = max(10, maxY - minY + 2 * r)
        scale = max(0.05, min(60, min(bounds.width / CGFloat(w), bounds.height / CGFloat(h)) * 0.7))
        let c = SIMD2((minX + maxX) / 2, (minY + maxY) / 2)
        origin = CGPoint(x: bounds.midX - CGFloat(c.x) * scale, y: bounds.midY - CGFloat(c.y) * scale)
        needsDisplay = true
    }

    /// Points to snap to: every shape's ends, corners and centre.
    private var snapPoints: [SIMD2<Double>] {
        sketch.entities.flatMap { e -> [SIMD2<Double>] in
            switch e.kind {
            case .rectangle where e.points.count >= 2:
                let a = e.points[0], b = e.points[1]
                return [a, b, SIMD2(a.x, b.y), SIMD2(b.x, a.y), (a + b) / 2]
            default: return e.points
            }
        } + [SIMD2(0, 0)]
    }

    private func snap(_ p: NSPoint) -> SIMD2<Double> {
        let q = toSketch(p)
        if let near = snapPoints.min(by: { simd_distance($0, q) < simd_distance($1, q) }), CGFloat(simd_distance(near, q)) * scale < 8 {
            snappedToPoint = true
            return near
        }
        snappedToPoint = false
        let s = gridStep
        return SIMD2((q.x / s).rounded() * s, (q.y / s).rounded() * s)
    }

    // MARK: Drawing

    static func outline(_ e: CADSketchEntity, segments: Int = 64) -> [SIMD2<Double>] {
        switch e.kind {
        case .line: return e.points.count >= 2 ? [e.points[0], e.points[1]] : []
        case .arc: return e.points.count >= 3 ? CADSketch.arcPoints(e.points[0], e.points[1], through: e.points[2], segments: segments) : []
        case .circle:
            guard e.points.count >= 2 else { return [] }
            return (0...segments).map { k in e.points[0] + e.radius * SIMD2(cos(2 * .pi * Double(k) / Double(segments)), sin(2 * .pi * Double(k) / Double(segments))) }
        case .rectangle:
            guard e.points.count >= 2 else { return [] }
            let a = e.points[0], b = e.points[1]
            return [a, SIMD2(b.x, a.y), b, SIMD2(a.x, b.y), a]
        case .polygon:
            guard e.points.count >= 2 else { return [] }
            let n = max(3, e.sides ?? 6)
            let start = atan2(e.points[1].y - e.points[0].y, e.points[1].x - e.points[0].x)
            return (0...n).map { k in e.points[0] + e.radius * SIMD2(cos(start + 2 * .pi * Double(k) / Double(n)), sin(start + 2 * .pi * Double(k) / Double(n))) }
        }
    }

    private func path(_ pts: [SIMD2<Double>]) -> NSBezierPath {
        let p = NSBezierPath()
        for (i, q) in pts.enumerated() { i == 0 ? p.move(to: toView(q)) : p.line(to: toView(q)) }
        return p
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.985, alpha: 1).setFill()
        bounds.fill()
        // The grid, every fifth line darker; the axes.
        let s = gridStep
        let lo = toSketch(NSPoint(x: bounds.minX, y: bounds.minY)), hi = toSketch(NSPoint(x: bounds.maxX, y: bounds.maxY))
        var x = (lo.x / s).rounded(.down) * s
        while x <= hi.x {
            let major = abs((x / s).rounded().truncatingRemainder(dividingBy: 5)) < 0.5
            NSColor(white: 0, alpha: major ? 0.11 : 0.05).setFill()
            NSRect(x: toView(SIMD2(x, 0)).x - 0.25, y: bounds.minY, width: 0.5, height: bounds.height).fill()
            x += s
        }
        var y = (lo.y / s).rounded(.down) * s
        while y <= hi.y {
            let major = abs((y / s).rounded().truncatingRemainder(dividingBy: 5)) < 0.5
            NSColor(white: 0, alpha: major ? 0.11 : 0.05).setFill()
            NSRect(x: bounds.minX, y: toView(SIMD2(0, y)).y - 0.25, width: bounds.width, height: 0.5).fill()
            y += s
        }
        NSColor.systemRed.withAlphaComponent(0.6).setFill()
        NSRect(x: bounds.minX, y: o.y - 0.5, width: bounds.width, height: 1).fill()
        NSColor.systemGreen.withAlphaComponent(0.6).setFill()
        NSRect(x: o.x - 0.5, y: bounds.minY, width: 1, height: bounds.height).fill()
        // Closed outlines shaded (holes clear).
        let loops = sketch.loops(segments: 64)
        if !loops.isEmpty {
            let fill = NSBezierPath()
            fill.windingRule = .evenOdd
            for loop in loops {
                for (i, q) in loop.points.enumerated() { i == 0 ? fill.move(to: toView(q)) : fill.line(to: toView(q)) }
                fill.close()
            }
            NSColor.systemBlue.withAlphaComponent(0.12).setFill()
            fill.fill()
        }
        // The shapes.
        for e in sketch.entities {
            let p = path(Self.outline(e))
            let selected = e.id == selectedEntity
            (selected ? NSColor.controlAccentColor : NSColor(white: 0.12, alpha: 1)).setStroke()
            p.lineWidth = selected ? 2.2 : 1.4
            p.stroke()
            for q in e.points {
                let v = toView(q)
                (selected ? NSColor.controlAccentColor : NSColor(white: 0.3, alpha: 1)).setFill()
                NSBezierPath(rect: NSRect(x: v.x - (selected ? 3.5 : 2), y: v.y - (selected ? 3.5 : 2), width: selected ? 7 : 4, height: selected ? 7 : 4)).fill()
            }
        }
        // What's being drawn, and its size.
        if let h = hover {
            if let preview = previewEntity(to: h) {
                let p = path(Self.outline(preview))
                NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke()
                p.lineWidth = 1.4
                p.setLineDash([5, 3], count: 2, phase: 0)
                p.stroke()
                label(measure(preview), at: toView(h))
            }
            let v = toView(h)
            (snappedToPoint ? NSColor.systemOrange : NSColor.controlAccentColor).setStroke()
            let mark = NSBezierPath(ovalIn: NSRect(x: v.x - 4, y: v.y - 4, width: 8, height: 8))
            mark.lineWidth = 1.2
            mark.stroke()
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        (tool.hint as NSString).draw(at: NSPoint(x: 10, y: bounds.maxY - 20), withAttributes: attrs)
        let where_ = hover.map { String(format: "%.2f, %.2f mm", $0.x, $0.y) } ?? ""
        ("\(sketch.plane.title) · grid \(gridStep.formatted()) mm   \(where_)" as NSString).draw(at: NSPoint(x: 10, y: 8), withAttributes: attrs)
    }

    private func label(_ text: String, at p: NSPoint) {
        guard !text.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        let r = NSRect(x: p.x + 12, y: p.y + 10, width: size.width + 10, height: size.height + 4)
        NSColor.controlAccentColor.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
        (text as NSString).draw(at: NSPoint(x: r.minX + 5, y: r.minY + 2), withAttributes: attrs)
    }

    private func measure(_ e: CADSketchEntity) -> String {
        switch e.kind {
        case .line: return String(format: "L %.2f", simd_distance(e.points[0], e.points[1]))
        case .circle: return String(format: "R %.2f", e.radius)
        case .polygon: return String(format: "R %.2f · %d sides", e.radius, e.sides ?? 6)
        case .rectangle: return String(format: "%.2f × %.2f", abs(e.points[1].x - e.points[0].x), abs(e.points[1].y - e.points[0].y))
        case .arc: return e.points.count >= 3 ? "arc" : String(format: "chord %.2f", simd_distance(e.points[0], e.points[1]))
        }
    }

    /// The shape the next click would make.
    private func previewEntity(to h: SIMD2<Double>) -> CADSketchEntity? {
        guard let first = pending.first else { return nil }
        switch tool {
        case .line: return CADSketchEntity(kind: .line, points: [pending.last!, h])
        case .circle: return CADSketchEntity(kind: .circle, points: [first, h])
        case .rectangle: return CADSketchEntity(kind: .rectangle, points: [first, h])
        case .polygon: return CADSketchEntity(kind: .polygon, points: [first, h], sides: polygonSides)
        case .arc: return pending.count >= 2 ? CADSketchEntity(kind: .arc, points: [pending[0], pending[1], h]) : CADSketchEntity(kind: .line, points: [first, h])
        case .select: return nil
        }
    }

    // MARK: Mouse and keys

    private func hit(_ p: NSPoint) -> UUID? {
        var best: (UUID, CGFloat)?
        for e in sketch.entities {
            let pts = Self.outline(e).map(toView)
            for i in 0..<max(0, pts.count - 1) {
                let a = pts[i], b = pts[i + 1]
                let ab = CGPoint(x: b.x - a.x, y: b.y - a.y), ap = CGPoint(x: p.x - a.x, y: p.y - a.y)
                let t = max(0, min(1, (ab.x * ap.x + ab.y * ap.y) / max(1e-9, ab.x * ab.x + ab.y * ab.y)))
                let d = hypot(a.x + ab.x * t - p.x, a.y + ab.y * t - p.y)
                if d < 6, best == nil || d < best!.1 { best = (e.id, d) }
            }
        }
        return best?.0
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        if tool == .select {
            // A handle of the selected shape, else a shape.
            if let id = selectedEntity, let e = sketch.entities.first(where: { $0.id == id }),
               let k = e.points.firstIndex(where: { hypot(toView($0).x - p.x, toView($0).y - p.y) < 7 }) {
                dragHandle = (id, k)
                return
            }
            selectedEntity = hit(p)
            return
        }
        let q = snap(p)
        downAt = q
        if event.clickCount == 2, tool == .line { endChain(); return }
        click(q)
    }

    private func click(_ q: SIMD2<Double>) {
        switch tool {
        case .line:
            if let last = pending.last {
                guard simd_distance(last, q) > 1e-9 else { return }
                onAdd?(CADSketchEntity(kind: .line, points: [last, q]))
                if let start = chainStart, simd_distance(start, q) < 1e-9 { endChain(); return }
                pending = [q]
            } else {
                pending = [q]
                chainStart = q
            }
        case .arc:
            pending.append(q)
            if pending.count == 3 {
                onAdd?(CADSketchEntity(kind: .arc, points: pending))
                pending = []
            }
        case .circle, .rectangle, .polygon:
            if let first = pending.first {
                guard simd_distance(first, q) > 1e-9 else { return }
                let kind: CADSketchEntity.Kind = tool == .circle ? .circle : tool == .rectangle ? .rectangle : .polygon
                onAdd?(CADSketchEntity(kind: kind, points: [first, q], sides: tool == .polygon ? polygonSides : nil))
                pending = []
            } else {
                pending = [q]
            }
        case .select:
            break
        }
        needsDisplay = true
    }

    private func endChain() {
        pending = []
        chainStart = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let drag = dragHandle, var e = sketch.entities.first(where: { $0.id == drag.entity }) {
            e.points[drag.index] = snap(p)
            if let i = sketch.entities.firstIndex(where: { $0.id == drag.entity }) { sketch.entities[i] = e }
            return
        }
        hover = snap(p)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { downAt = nil }
        let p = convert(event.locationInWindow, from: nil)
        if let drag = dragHandle {
            dragHandle = nil
            if let e = sketch.entities.first(where: { $0.id == drag.entity }) { onUpdate?(e) }
            return
        }
        // Dragged out: the shape ends where the mouse went up.
        if let start = downAt, [.circle, .rectangle, .polygon].contains(tool), pending.count == 1 {
            let q = snap(p)
            if CGFloat(simd_distance(start, q)) * scale > 4 { click(q) }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        hover = tool == .select ? nil : snap(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hover = nil
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) || !event.hasPreciseScrollingDeltas {
            zoom(by: exp(Double(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.01 : 0.08)), at: convert(event.locationInWindow, from: nil))
            return
        }
        origin = CGPoint(x: o.x + event.scrollingDeltaX, y: o.y - event.scrollingDeltaY)
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) { zoom(by: 1 + Double(event.magnification), at: convert(event.locationInWindow, from: nil)) }

    private func zoom(by factor: Double, at p: NSPoint) {
        let q = toSketch(p)
        scale = max(0.05, min(80, scale * CGFloat(factor)))
        origin = CGPoint(x: p.x - CGFloat(q.x) * scale, y: p.y - CGFloat(q.y) * scale)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53, 36, 76: endChain()   // Esc, Return, Enter
        case 51, 117:                  // Delete
            if let id = selectedEntity { onRemove?(id); selectedEntity = nil } else { NSSound.beep() }
        default: super.keyDown(with: event)
        }
    }
}
