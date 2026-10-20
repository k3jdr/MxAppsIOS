//
//  CADSketchView.swift
//  MxNoteONE
//
//  The Sketcher (as FreeCAD's): points, polylines, arcs (by centre or three points), circles (by centre or three
//  points), rectangles (corner, centred or rounded), regular polygons and slots; fillets at corners and trimming at
//  crossings; construction geometry. Points snap to ends, centres and the origin, onto edges and to the grid; lines
//  near level or upright snap to it — each adding the constraint it implies (coincident, point on object,
//  horizontal, vertical). Constraints are drawn as FreeCAD draws them: symbols beside the geometry, dimensions with
//  their values (double-click one to change it — an expression of the parameters). Dragging a point or an edge
//  moves it with the solver, so everything constrained to it follows. Fully constrained geometry turns green.
//

import AppKit
import simd

enum CADSketchTool: String, CaseIterable, Identifiable {
    case select = "Select", point = "Point", line = "Polyline", arc = "Arc", arc3 = "Arc by 3 Points", circle = "Circle"
    case circle3 = "Circle by 3 Points", rectangle = "Rectangle", centredRectangle = "Centred Rectangle"
    case roundedRectangle = "Rounded Rectangle", polygon = "Polygon", slot = "Slot", fillet = "Fillet", trim = "Trim"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .point: "smallcircle.filled.circle"
        case .line: "line.diagonal"
        case .arc: "circle.bottomhalf.filled"
        case .arc3: "point.topleft.down.to.point.bottomright.curvepath"
        case .circle: "circle"
        case .circle3: "circle.dashed"
        case .rectangle: "rectangle"
        case .centredRectangle: "rectangle.center.inset.filled"
        case .roundedRectangle: "rectangle.roundedtop"
        case .polygon: "hexagon"
        case .slot: "capsule"
        case .fillet: "arrow.turn.down.right"
        case .trim: "scissors"
        }
    }
    var hint: String {
        switch self {
        case .select: "Click points and edges to select them (⇧ for more), then a constraint. Drag to move; Delete removes."
        case .point: "Click to place a point."
        case .line: "Click point to point. Click the first point to close the outline; Return or Esc ends."
        case .arc: "Click the centre, then where the arc starts, then where it ends."
        case .arc3: "Click where the arc starts, where it ends, then a point it passes through."
        case .circle: "Click the centre, then the edge (or drag)."
        case .circle3: "Click three points on the circle."
        case .rectangle: "Click one corner, then the opposite one (or drag)."
        case .centredRectangle: "Click the centre, then a corner (or drag)."
        case .roundedRectangle: "Click one corner, then the opposite one; the corners are rounded."
        case .polygon: "Click the centre, then a corner (or drag)."
        case .slot: "Click the centre of one end, then the other."
        case .fillet: "Click a corner where two lines meet to round it."
        case .trim: "Click the part of an edge to cut away, up to where it crosses others."
        }
    }
    /// Clicks it takes.
    var clicks: Int {
        switch self {
        case .select, .fillet, .trim: 0
        case .point: 1
        case .line: 2
        case .arc, .arc3, .circle3: 3
        case .circle, .rectangle, .centredRectangle, .roundedRectangle, .polygon, .slot: 2
        }
    }
}

final class CADSketchView: NSView, NSTextFieldDelegate {
    var sketch = CADSketch() { didSet { if dragBase == nil { needsDisplay = true } } }
    var status = CADSketchStatus() { didSet { needsDisplay = true } }
    var values: [String: Double] = [:]
    var tool: CADSketchTool = .line { didSet { pending = []; chainStart = nil; needsDisplay = true } }
    var polygonSides = 6
    var filletRadius = 2.0
    /// New geometry is construction geometry.
    var constructionMode = false
    private(set) var selection: [CADSketchRef] = [] { didSet { onSelection?(selection); needsDisplay = true } }
    private(set) var selectedConstraint: UUID? { didSet { onSelectConstraint?(selectedConstraint); needsDisplay = true } }
    /// The whole sketch changed (a shape drawn, dragged, deleted…): one undo step.
    var onCommit: ((CADSketch, String) -> Void)?
    var onSelection: (([CADSketchRef]) -> Void)?
    var onSelectConstraint: ((UUID?) -> Void)?

    /// Points per millimetre, and where the sketch's origin is in the view.
    private var scale: CGFloat = 4
    private var origin: CGPoint?
    private var pending: [SIMD2<Double>] = []
    private var pendingSnaps: [Snap?] = []
    private var chainStart: SIMD2<Double>?
    private var chainStartSnap: Snap?
    private var lastLineEnd: CADSketchRef?
    private var hover: SIMD2<Double>?
    private var hoverSnap: Snap?
    private var preselect: CADSketchRef?
    /// A drag: the sketch as it was, what's dragged and where from.
    private var dragBase: CADSketch?
    private var dragRef: CADSketchRef?
    private var dragFrom: SIMD2<Double>?
    private var dragConstraint: (id: UUID, start: SIMD2<Double>, offset: SIMD2<Double>)?
    private var boxStart: NSPoint?
    private var boxEnd: NSPoint?
    private var downAt: SIMD2<Double>?
    private var tracking: NSTrackingArea?
    private var message: (text: String, until: Date)?
    private var labelRects: [(id: UUID, rect: NSRect)] = []
    private var editor: NSTextField?
    private var editing: UUID?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    func select(_ refs: [CADSketchRef]) { selection = refs }
    func selectConstraint(_ id: UUID?) { selectedConstraint = id }

    /// A note at the top of the view for a few seconds (why a constraint wasn't added…).
    func tell(_ text: String) {
        message = (text, Date().addingTimeInterval(3.5))
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.6) { [weak self] in self?.needsDisplay = true }
    }

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
        let pts = sketch.entities.flatMap { $0.outline(segments: 24) }
        guard let minX = pts.map(\.x).min(), let maxX = pts.map(\.x).max(), let minY = pts.map(\.y).min(), let maxY = pts.map(\.y).max() else {
            scale = 4; origin = nil; needsDisplay = true; return
        }
        let w = max(10, maxX - minX), h = max(10, maxY - minY)
        scale = max(0.05, min(60, min(bounds.width / CGFloat(w), bounds.height / CGFloat(h)) * 0.7))
        let c = SIMD2((minX + maxX) / 2, (minY + maxY) / 2)
        origin = CGPoint(x: bounds.midX - CGFloat(c.x) * scale, y: bounds.midY - CGFloat(c.y) * scale)
        needsDisplay = true
    }

    // MARK: Geometry

    private var reader: CADSketchSolver.Reader {
        CADSketchSolver.Reader(sketch: sketch, layout: CADSketchSolver.Layout(sketch), x: CADSketchSolver.variables(sketch))
    }

    /// Every point that can be picked: ends, corners, centres, the origin.
    private func pointRefs() -> [CADSketchRef] {
        var refs: [CADSketchRef] = [.origin]
        for e in sketch.entities {
            switch e.kind {
            case .point: refs.append(CADSketchRef(entity: e.id, part: 0))
            case .line: refs += [0, 1].map { CADSketchRef(entity: e.id, part: $0) }
            case .arc: refs += [0, 1, CADSketchRef.centre].map { CADSketchRef(entity: e.id, part: $0) }
            case .circle: refs.append(CADSketchRef(entity: e.id, part: CADSketchRef.centre))
            case .rectangle: refs += (0..<4).map { CADSketchRef(entity: e.id, part: $0) }
            case .polygon: refs += ([CADSketchRef.centre] + Array(0..<max(3, e.sides ?? 6))).map { CADSketchRef(entity: e.id, part: $0) }
            }
        }
        return refs
    }

    private func edgeRefs() -> [CADSketchRef] {
        var refs: [CADSketchRef] = [.hAxis, .vAxis]
        for e in sketch.entities {
            switch e.kind {
            case .point: break
            case .line, .arc, .circle: refs.append(CADSketchRef(entity: e.id, part: CADSketchRef.edge(0)))
            case .rectangle: refs += (0..<4).map { CADSketchRef(entity: e.id, part: CADSketchRef.edge($0)) }
            case .polygon: refs += (0..<max(3, e.sides ?? 6)).map { CADSketchRef(entity: e.id, part: CADSketchRef.edge($0)) }
            }
        }
        return refs
    }

    /// An edge's points, for drawing and picking.
    private func polyline(_ r: CADSketchRef, _ g: CADSketchSolver.Reader) -> [SIMD2<Double>] {
        if r.isRoot {
            let lo = toSketch(NSPoint(x: bounds.minX, y: bounds.minY)), hi = toSketch(NSPoint(x: bounds.maxX, y: bounds.maxY))
            return r.part == 1000 ? [SIMD2(lo.x, 0), SIMD2(hi.x, 0)] : [SIMD2(0, lo.y), SIMD2(0, hi.y)]
        }
        guard let e = sketch.entities.first(where: { $0.id == r.entity }) else { return [] }
        switch e.kind {
        case .line, .arc, .circle: return e.outline(segments: 64)
        default:
            if case .segment(let a, let b)? = g.edge(r) { return [a, b] }
            return []
        }
    }

    private func distance(_ p: NSPoint, toPolyline pts: [SIMD2<Double>]) -> CGFloat {
        let v = pts.map(toView)
        var best = CGFloat.infinity
        for i in 0..<max(0, v.count - 1) {
            let a = v[i], b = v[i + 1]
            let ab = CGPoint(x: b.x - a.x, y: b.y - a.y), ap = CGPoint(x: p.x - a.x, y: p.y - a.y)
            let t = max(0, min(1, (ab.x * ap.x + ab.y * ap.y) / max(1e-9, ab.x * ab.x + ab.y * ab.y)))
            best = min(best, hypot(a.x + ab.x * t - p.x, a.y + ab.y * t - p.y))
        }
        return best
    }

    /// The point or edge under the mouse.
    private func pick(_ p: NSPoint) -> CADSketchRef? {
        let g = reader
        if let pt = pointRefs().compactMap({ r -> (CADSketchRef, CGFloat)? in
            guard let q = g.point(r) else { return nil }
            let v = toView(q)
            return (r, hypot(v.x - p.x, v.y - p.y))
        }).filter({ $0.1 < 7 }).min(by: { $0.1 < $1.1 }) { return pt.0 }
        let edges = edgeRefs().map { ($0, distance(p, toPolyline: polyline($0, g))) }.filter { $0.1 < 6 }
        // Real geometry before the axes.
        return (edges.filter { !$0.0.isRoot }.min(by: { $0.1 < $1.1 }) ?? edges.min(by: { $0.1 < $1.1 }))?.0
    }

    // MARK: Snapping

    struct Snap {
        var ref: CADSketchRef
        /// Onto an edge (point on object) rather than a point.
        var onEdge: Bool
    }

    private func snap(_ p: NSPoint) -> (SIMD2<Double>, Snap?) {
        let q = toSketch(p)
        let g = reader
        let near = pointRefs().compactMap { r -> (CADSketchRef, SIMD2<Double>)? in g.point(r).map { (r, $0) } }
            .min { simd_distance($0.1, q) < simd_distance($1.1, q) }
        if let near, CGFloat(simd_distance(near.1, q)) * scale < 8 { return (near.1, Snap(ref: near.0, onEdge: false)) }
        // Onto an edge.
        var best: (CADSketchRef, SIMD2<Double>, CGFloat)?
        for r in edgeRefs() {
            guard let e = g.edge(r) else { continue }
            var foot: SIMD2<Double>
            switch e {
            case .segment(let a, let b):
                let d = b - a, len2 = max(1e-18, simd_length_squared(d))
                var t = simd_dot(q - a, d) / len2
                if !r.isRoot { t = max(0, min(1, t)) }
                foot = a + d * t
            case .circle(let c, let rad):
                let v = q - c
                foot = c + (simd_length(v) > 1e-12 ? simd_normalize(v) : SIMD2(1, 0)) * rad
            }
            let d = CGFloat(simd_distance(foot, q)) * scale
            if d < 6, best == nil || d < best!.2 { best = (r, foot, d) }
        }
        if let best { return (best.1, Snap(ref: best.0, onEdge: true)) }
        let s = gridStep
        return (SIMD2((q.x / s).rounded() * s, (q.y / s).rounded() * s), nil)
    }

    // MARK: Drawing

    private func path(_ pts: [SIMD2<Double>]) -> NSBezierPath {
        let p = NSBezierPath()
        for (i, q) in pts.enumerated() { i == 0 ? p.move(to: toView(q)) : p.line(to: toView(q)) }
        return p
    }

    private static let green = NSColor(red: 0.05, green: 0.6, blue: 0.2, alpha: 1)
    private static let selectionColor = NSColor(red: 0.1, green: 0.75, blue: 0.2, alpha: 1)
    private static let preselectColor = NSColor(red: 0.85, green: 0.7, blue: 0.0, alpha: 1)

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.985, alpha: 1).setFill()
        bounds.fill()
        drawGrid()
        let g = reader
        // Closed outlines shaded (holes clear).
        let loops = sketch.loops(segments: 64)
        if !loops.isEmpty {
            let fill = NSBezierPath()
            fill.windingRule = .evenOdd
            for loop in loops {
                for (i, q) in loop.points.enumerated() { i == 0 ? fill.move(to: toView(q)) : fill.line(to: toView(q)) }
                fill.close()
            }
            NSColor.systemBlue.withAlphaComponent(0.10).setFill()
            fill.fill()
        }
        // The edges.
        for r in edgeRefs() where !r.isRoot {
            guard let e = sketch.entities.first(where: { $0.id == r.entity }) else { continue }
            let p = path(polyline(r, g))
            let selected = selection.contains(r), pre = preselect == r
            let constrained = !status.free.contains(e.id) && !sketch.entities.isEmpty
            var color = e.isConstruction ? NSColor.systemBlue : constrained ? Self.green : NSColor(white: 0.12, alpha: 1)
            if pre { color = Self.preselectColor }
            if selected { color = Self.selectionColor }
            color.setStroke()
            p.lineWidth = selected || pre ? 2.6 : 1.5
            if e.isConstruction { p.setLineDash([6, 4], count: 2, phase: 0) }
            p.stroke()
        }
        if let r = preselect, r.isRoot, r.isEdge { Self.preselectColor.setStroke(); let p = path(polyline(r, g)); p.lineWidth = 2; p.stroke() }
        for r in selection where r.isRoot && r.isEdge { Self.selectionColor.setStroke(); let p = path(polyline(r, g)); p.lineWidth = 2.4; p.stroke() }
        drawConstraints(g)
        // The points.
        for r in pointRefs() {
            guard let q = g.point(r) else { continue }
            let v = toView(q)
            let selected = selection.contains(r), pre = preselect == r
            let free = r.isRoot ? false : status.free.contains(r.entity)
            let size: CGFloat = selected || pre ? 7 : r.isRoot ? 5 : 4.5
            (selected ? Self.selectionColor : pre ? Self.preselectColor : r.isRoot ? NSColor.systemRed : free ? NSColor(white: 0.25, alpha: 1) : Self.green).setFill()
            NSBezierPath(ovalIn: NSRect(x: v.x - size / 2, y: v.y - size / 2, width: size, height: size)).fill()
        }
        // What's being drawn, and its size.
        if let h = hover {
            for preview in previewEntities(to: h) {
                let p = path(preview.outline(segments: 64))
                NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke()
                p.lineWidth = 1.4
                p.setLineDash([5, 3], count: 2, phase: 0)
                p.stroke()
            }
            if let text = measureText(to: h) { label(text, at: toView(h)) }
            let v = toView(h)
            (hoverSnap != nil ? NSColor.systemOrange : NSColor.controlAccentColor).setStroke()
            let mark = NSBezierPath(ovalIn: NSRect(x: v.x - 4, y: v.y - 4, width: 8, height: 8))
            mark.lineWidth = 1.2
            mark.stroke()
            if let s = hoverSnap {
                let glyph = s.onEdge ? "on" : "●"
                (glyph as NSString).draw(at: NSPoint(x: v.x + 7, y: v.y - 16), withAttributes: [.font: NSFont.systemFont(ofSize: 9, weight: .bold), .foregroundColor: NSColor.systemOrange])
            }
        }
        if let a = boxStart, let b = boxEnd {
            let r = NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            NSColor.controlAccentColor.withAlphaComponent(0.08).setFill()
            r.fill()
            NSColor.controlAccentColor.setStroke()
            let p = NSBezierPath(rect: r)
            p.setLineDash([4, 2], count: 2, phase: 0)
            p.stroke()
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        (tool.hint as NSString).draw(at: NSPoint(x: 10, y: bounds.maxY - 20), withAttributes: attrs)
        if let m = message, m.until > Date() {
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
            let size = (m.text as NSString).size(withAttributes: a)
            let r = NSRect(x: bounds.midX - size.width / 2 - 10, y: bounds.maxY - 50, width: size.width + 20, height: size.height + 8)
            NSColor.systemOrange.withAlphaComponent(0.92).setFill()
            NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
            (m.text as NSString).draw(at: NSPoint(x: r.minX + 10, y: r.minY + 4), withAttributes: a)
        }
        let where_ = hover.map { String(format: "%.2f, %.2f mm", $0.x, $0.y) } ?? ""
        let state = status.summary
        ("\(sketch.planeTitle) · grid \(gridStep.formatted()) mm · \(state)   \(where_)" as NSString).draw(at: NSPoint(x: 10, y: 8), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: status.conflicting || status.redundant > 0 ? NSColor.systemRed : status.dof == 0 && !sketch.entities.isEmpty ? Self.green : NSColor.secondaryLabelColor,
        ])
    }

    private func drawGrid() {
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
    }

    // MARK: Constraints drawn

    private func anchor(_ r: CADSketchRef, _ g: CADSketchSolver.Reader) -> SIMD2<Double>? {
        if let p = g.point(r) { return p }
        switch g.edge(r) {
        case .segment(let a, let b)?: return r.isRoot ? (r.part == 1000 ? SIMD2(Double((bounds.maxX - o.x) / scale) * 0.8, 0) : SIMD2(0, Double((bounds.maxY - o.y) / scale) * 0.8)) : (a + b) / 2
        case .circle(let c, let rad)?:
            if let e = sketch.entities.first(where: { $0.id == r.entity }), e.kind == .arc, e.points.count >= 3 { return e.points[2] }
            return c + SIMD2(0, rad)
        case nil: return nil
        }
    }

    private func glyph(_ k: CADConstraint.Kind) -> String {
        switch k {
        case .horizontal: "H"
        case .vertical: "V"
        case .parallel: "∥"
        case .perpendicular: "⊥"
        case .tangent: "T"
        case .equal: "="
        case .symmetric: "⋈"
        case .pointOnObject: "◦"
        case .lock: "🔒"
        case .block: "▣"
        default: ""
        }
    }

    private func valueText(_ c: CADConstraint) -> String {
        let v = c.value.flatMap { try? CADExpression.evaluate($0, values) }
        var text = v.map(CADSketchSolver.format) ?? "?"
        switch c.kind {
        case .radius: text = "R" + text
        case .diameter: text = "⌀" + text
        case .angle: text += "°"
        case .lock:
            let y = c.value2.flatMap { try? CADExpression.evaluate($0, values) }
            text = "(\(text), \(y.map(CADSketchSolver.format) ?? "?"))"
        default: break
        }
        if let s = c.value, Double(s.trimmingCharacters(in: .whitespaces)) == nil { text = "ƒ " + text }
        return text
    }

    private func drawConstraints(_ g: CADSketchSolver.Reader) {
        labelRects = []
        var stacks: [String: Int] = [:]
        let red = NSColor.systemRed
        for c in sketch.constraints ?? [] {
            let selected = c.id == selectedConstraint
            let ink = selected ? Self.selectionColor : status.conflicting ? red : NSColor(red: 0.75, green: 0.2, blue: 0.15, alpha: 1)
            switch c.kind {
            case .coincident:
                // A coincidence is the point drawn a little larger.
                if let q = c.refs.first.flatMap(g.point) {
                    let v = toView(q)
                    ink.withAlphaComponent(0.85).setFill()
                    NSBezierPath(ovalIn: NSRect(x: v.x - 4, y: v.y - 4, width: 8, height: 8)).fill()
                    labelRects.append((c.id, NSRect(x: v.x - 5, y: v.y - 5, width: 10, height: 10)))
                }
            case .distance, .distanceX, .distanceY, .radius, .diameter, .angle, .lock:
                drawDimension(c, g, ink)
            default:
                // Symbols beside each element they hold.
                for r in c.refs.prefix(c.kind == .symmetric ? 3 : 2) {
                    guard let q = anchor(r, g) else { continue }
                    let v = toView(q)
                    let key = "\(Int(v.x / 4)):\(Int(v.y / 4))"
                    let n = stacks[key, default: 0]
                    stacks[key] = n + 1
                    let text = glyph(c.kind)
                    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor.white]
                    let size = (text as NSString).size(withAttributes: attrs)
                    let rect = NSRect(x: v.x + 8 + CGFloat(n) * (size.width + 9), y: v.y + 6, width: size.width + 6, height: size.height + 2)
                    ink.setFill()
                    NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
                    (text as NSString).draw(at: NSPoint(x: rect.minX + 3, y: rect.minY + 1), withAttributes: attrs)
                    labelRects.append((c.id, rect))
                }
            }
        }
    }

    private func drawDimension(_ c: CADConstraint, _ g: CADSketchSolver.Reader, _ ink: NSColor) {
        let text = valueText(c)
        let extra = c.labelOffset.map { NSPoint(x: CGFloat($0.x) * scale, y: CGFloat($0.y) * scale) } ?? .zero
        var labelAt = NSPoint.zero
        ink.setStroke()
        func line(_ a: NSPoint, _ b: NSPoint, width: CGFloat = 1) {
            let p = NSBezierPath()
            p.move(to: a)
            p.line(to: b)
            p.lineWidth = width
            p.stroke()
        }
        func arrow(_ tip: NSPoint, from: NSPoint) {
            let d = hypot(tip.x - from.x, tip.y - from.y)
            guard d > 1 else { return }
            let ux = (tip.x - from.x) / d, uy = (tip.y - from.y) / d
            let p = NSBezierPath()
            p.move(to: tip)
            p.line(to: NSPoint(x: tip.x - ux * 7 - uy * 3, y: tip.y - uy * 7 + ux * 3))
            p.line(to: NSPoint(x: tip.x - ux * 7 + uy * 3, y: tip.y - uy * 7 - ux * 3))
            p.close()
            ink.setFill()
            p.fill()
        }
        let refs = c.refs
        func pt(_ k: Int) -> SIMD2<Double>? { refs.indices.contains(k) ? g.point(refs[k]) : nil }
        func seg(_ k: Int) -> (SIMD2<Double>, SIMD2<Double>)? { if refs.indices.contains(k), case .segment(let a, let b)? = g.edge(refs[k]) { return (a, b) }; return nil }
        func circ(_ k: Int) -> (SIMD2<Double>, Double)? { if refs.indices.contains(k), case .circle(let o, let r)? = g.edge(refs[k]) { return (o, r) }; return nil }
        switch c.kind {
        case .distance, .distanceX, .distanceY:
            var a: SIMD2<Double>?, b: SIMD2<Double>?
            if let p = pt(0), let q = pt(1) { a = p; b = q } else if let p = pt(0), let (s0, s1) = seg(1) {
                let d = s1 - s0, t = simd_dot(p - s0, d) / max(1e-18, simd_length_squared(d))
                a = p; b = s0 + d * t
            } else if let (s0, s1) = seg(0) { a = s0; b = s1 } else if let p = pt(0) { a = .zero; b = p }
            guard let a, let b else { return }
            var va = toView(a), vb = toView(b)
            if c.kind == .distanceX { vb.y = va.y } else if c.kind == .distanceY { vb.x = va.x }
            let dx = vb.x - va.x, dy = vb.y - va.y, len = max(1, hypot(dx, dy))
            let nx = -dy / len * 22 + extra.x, ny = dx / len * 22 + extra.y
            let da = NSPoint(x: va.x + nx, y: va.y + ny), db = NSPoint(x: vb.x + nx, y: vb.y + ny)
            NSColor(white: 0.4, alpha: 0.6).setStroke()
            line(toView(a), da, width: 0.6)
            line(toView(b), db, width: 0.6)
            ink.setStroke()
            line(da, db)
            arrow(da, from: db)
            arrow(db, from: da)
            labelAt = NSPoint(x: (da.x + db.x) / 2, y: (da.y + db.y) / 2)
        case .radius, .diameter:
            guard let (centre, r) = circ(0) else { return }
            let ang = atan2(Double(extra.y) + 1, Double(extra.x) + 1)
            let dir = SIMD2(cos(ang), sin(ang))
            let edge = toView(centre + dir * r), from = c.kind == .diameter ? toView(centre - dir * r) : toView(centre)
            line(from, edge)
            arrow(edge, from: from)
            if c.kind == .diameter { arrow(from, from: edge) }
            labelAt = NSPoint(x: edge.x + CGFloat(dir.x) * 14, y: edge.y + CGFloat(dir.y) * 14)
        case .angle:
            if let (a, b) = seg(0), let (p, q) = seg(1) {
                // Round the lines' crossing (or the first line's start).
                let d1 = b - a, d2 = q - p
                let den = d1.x * d2.y - d1.y * d2.x
                let corner = abs(den) > 1e-12 ? a + d1 * (((p - a).x * d2.y - (p - a).y * d2.x) / den) : a
                let a1 = atan2(d1.y, d1.x), a2 = atan2(d2.y, d2.x)
                drawArc(around: toView(corner), from: a1, to: a2, radius: 30 + extra.x)
                labelAt = NSPoint(x: toView(corner).x + 40 * CGFloat(cos((a1 + a2) / 2)), y: toView(corner).y + 40 * CGFloat(sin((a1 + a2) / 2)))
            } else if let (a, b) = seg(0) {
                let a1 = atan2(b.y - a.y, b.x - a.x)
                drawArc(around: toView(a), from: 0, to: a1, radius: 30 + extra.x)
                labelAt = NSPoint(x: toView(a).x + 42 * CGFloat(cos(a1 / 2)), y: toView(a).y + 42 * CGFloat(sin(a1 / 2)))
            }
        case .lock:
            guard let q = pt(0) else { return }
            labelAt = NSPoint(x: toView(q).x + 30 + extra.x, y: toView(q).y - 14 + extra.y)
        default: return
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: ink]
        let shown = c.kind == .lock ? "🔒 " + text : text
        let size = (shown as NSString).size(withAttributes: attrs)
        let rect = NSRect(x: labelAt.x - size.width / 2 - 3, y: labelAt.y - size.height / 2 - 1, width: size.width + 6, height: size.height + 2)
        NSColor(white: 1, alpha: 0.85).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        (shown as NSString).draw(at: NSPoint(x: rect.minX + 3, y: rect.minY + 1), withAttributes: attrs)
        labelRects.append((c.id, rect))
    }

    private func drawArc(around c: NSPoint, from a1: Double, to a2: Double, radius: CGFloat) {
        let p = NSBezierPath()
        p.appendArc(withCenter: c, radius: max(10, radius), startAngle: CGFloat(a1 * 180 / .pi), endAngle: CGFloat(a2 * 180 / .pi), clockwise: a2 < a1)
        p.lineWidth = 1
        p.stroke()
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

    private func measureText(to h: SIMD2<Double>) -> String? {
        guard let first = pending.first else { return nil }
        switch tool {
        case .line: return String(format: "L %.2f", simd_distance(pending.last!, h))
        case .circle, .polygon: return String(format: "R %.2f", simd_distance(first, h))
        case .rectangle, .roundedRectangle: return String(format: "%.2f × %.2f", abs(h.x - first.x), abs(h.y - first.y))
        case .centredRectangle: return String(format: "%.2f × %.2f", abs(h.x - first.x) * 2, abs(h.y - first.y) * 2)
        case .arc: return pending.count == 1 ? String(format: "R %.2f", simd_distance(first, h)) : nil
        case .slot: return String(format: "L %.2f", simd_distance(first, h))
        default: return nil
        }
    }

    // MARK: Making shapes

    private func entity(_ kind: CADSketchEntity.Kind, _ points: [SIMD2<Double>], sides: Int? = nil) -> CADSketchEntity {
        CADSketchEntity(kind: kind, points: points, sides: sides, construction: constructionMode && kind != .point ? true : nil)
    }

    /// An arc from its centre, start and end (counter-clockwise from start to end).
    static func arc(centre c: SIMD2<Double>, start a: SIMD2<Double>, end b: SIMD2<Double>) -> [SIMD2<Double>]? {
        let r = simd_distance(c, a)
        guard r > 1e-9 else { return nil }
        let t0 = atan2(a.y - c.y, a.x - c.x)
        var t1 = atan2(b.y - c.y, b.x - c.x)
        while t1 <= t0 { t1 += 2 * .pi }
        let mid = (t0 + t1) / 2
        return [a, c + r * SIMD2(cos(t1), sin(t1)), c + r * SIMD2(cos(mid), sin(mid))]
    }

    private func previewEntities(to h: SIMD2<Double>) -> [CADSketchEntity] {
        guard let first = pending.first else { return [] }
        switch tool {
        case .line: return [entity(.line, [pending.last!, h])]
        case .circle: return [entity(.circle, [first, h])]
        case .rectangle, .roundedRectangle: return [entity(.rectangle, [first, h])]
        case .centredRectangle: return [entity(.rectangle, [2 * first - h, h])]
        case .polygon: return [entity(.polygon, [first, h], sides: polygonSides)]
        case .arc3: return pending.count >= 2 ? [entity(.arc, [pending[0], pending[1], h])] : [entity(.line, [first, h])]
        case .arc:
            if pending.count >= 2, let pts = Self.arc(centre: first, start: pending[1], end: h) { return [entity(.arc, pts)] }
            return [entity(.circle, [first, h])]
        case .circle3:
            if pending.count >= 2 {
                let c = CADSketchSolver.Reader.circumcentre(pending[0], pending[1], h)
                return [entity(.circle, [c, c + SIMD2(simd_distance(c, h), 0)])]
            }
            return [entity(.line, [first, h])]
        case .slot: return slotEntities(first, h).0
        default: return []
        }
    }

    private var working: CADSketch { dragBase ?? sketch }

    private func commit(_ s: CADSketch, _ name: String) {
        sketch = s
        onCommit?(s, name)
    }

    /// Adds constraints unless they'd conflict or repeat what's there (auto-constraints are quietly dropped then).
    @discardableResult
    private func addConstraints(_ list: [CADConstraint], to s: inout CADSketch, quiet: Bool) -> Bool {
        var added = false
        for c in list {
            var trial = s
            trial.constraints = (trial.constraints ?? []) + [c]
            let before = CADSketchSolver.solve(s, values: values).1
            let (solved, after) = CADSketchSolver.solve(trial, values: values)
            if after.conflicting {
                if !quiet { tell("That would conflict with the sketch's other constraints.") }
                continue
            }
            if after.redundant > before.redundant {
                if !quiet { tell("That's already held by the other constraints.") }
                continue
            }
            s = solved
            added = true
        }
        return added
    }

    /// Constraints a new point implies: coincident with the point it snapped to, or on the edge.
    private func snapConstraints(_ snap: Snap?, _ ref: CADSketchRef) -> [CADConstraint] {
        guard let snap else { return [] }
        if snap.onEdge { return [CADConstraint(kind: .pointOnObject, refs: [ref, snap.ref])] }
        return [CADConstraint(kind: .coincident, refs: [ref, snap.ref])]
    }

    private func add(_ entities: [CADSketchEntity], constraints: [CADConstraint], auto: [CADConstraint] = [], name: String) {
        var s = working
        s.entities += entities
        if !constraints.isEmpty { s.constraints = (s.constraints ?? []) + constraints }
        addConstraints(auto, to: &s, quiet: true)
        if s.constraints?.isEmpty == false { s = CADSketchSolver.solve(s, values: values, analyse: false).0 }
        commit(s, name)
    }

    private func click(_ q: SIMD2<Double>, _ snap: Snap?) {
        switch tool {
        case .point:
            let e = entity(.point, [q])
            add([e], constraints: [], auto: snapConstraints(snap, CADSketchRef(entity: e.id, part: 0)), name: "Add Point")
        case .line:
            if let last = pending.last {
                guard simd_distance(last, q) > 1e-9 else { return }
                var end = q
                var auto: [CADConstraint] = []
                var e = entity(.line, [last, end])
                // Nearly level or upright: made so (unless it snapped to a point), and constrained.
                let d = end - last
                let edgeRef = CADSketchRef(entity: e.id, part: CADSketchRef.edge(0))
                if abs(d.y) * Double(scale) < 4, abs(d.x) > 1e-9, snap == nil || abs(d.y) < 1e-9 { end.y = last.y; auto.append(CADConstraint(kind: .horizontal, refs: [edgeRef])) }
                else if abs(d.x) * Double(scale) < 4, abs(d.y) > 1e-9, snap == nil || abs(d.x) < 1e-9 { end.x = last.x; auto.append(CADConstraint(kind: .vertical, refs: [edgeRef])) }
                e.points[1] = end
                let start = CADSketchRef(entity: e.id, part: 0), finish = CADSketchRef(entity: e.id, part: 1)
                if let prev = lastLineEnd { auto.append(CADConstraint(kind: .coincident, refs: [start, prev])) } else { auto += snapConstraints(pendingSnaps.first ?? nil, start) }
                let closing = chainStart.map { simd_distance($0, end) < 1e-9 } ?? false
                if closing, let first = chainStartSnapRef { auto.append(CADConstraint(kind: .coincident, refs: [finish, first])) } else { auto += snapConstraints(snap, finish) }
                if chainStartSnapRef == nil { chainStartSnapRef = start }
                add([e], constraints: [], auto: auto, name: "Add Line")
                if closing { endChain(); return }
                pending = [end]
                pendingSnaps = [nil]
                lastLineEnd = finish
            } else {
                pending = [q]
                pendingSnaps = [snap]
                chainStart = q
                chainStartSnapRef = nil
                lastLineEnd = nil
            }
        case .arc3, .arc, .circle3:
            pending.append(q)
            pendingSnaps.append(snap)
            guard pending.count == 3 else { break }
            defer { pending = []; pendingSnaps = [] }
            if tool == .circle3 {
                let c = CADSketchSolver.Reader.circumcentre(pending[0], pending[1], pending[2])
                let e = entity(.circle, [c, c + SIMD2(simd_distance(c, pending[0]), 0)])
                let edge = CADSketchRef(entity: e.id, part: CADSketchRef.edge(0))
                add([e], constraints: [], auto: pendingSnaps.compactMap { $0 }.filter { !$0.onEdge }.map { CADConstraint(kind: .pointOnObject, refs: [$0.ref, edge]) }, name: "Add Circle")
                return
            }
            var pts = pending
            var auto: [CADConstraint] = []
            let e0id = UUID()
            if tool == .arc {
                guard let a = Self.arc(centre: pending[0], start: pending[1], end: pending[2]) else { return }
                pts = a
                auto += snapConstraints(pendingSnaps[0], CADSketchRef(entity: e0id, part: CADSketchRef.centre))
                auto += snapConstraints(pendingSnaps[1], CADSketchRef(entity: e0id, part: 0))
            } else {
                auto += snapConstraints(pendingSnaps[0], CADSketchRef(entity: e0id, part: 0))
                auto += snapConstraints(pendingSnaps[1], CADSketchRef(entity: e0id, part: 1))
            }
            var e = entity(.arc, pts)
            e.id = e0id
            add([e], constraints: [], auto: auto, name: "Add Arc")
        case .circle, .rectangle, .centredRectangle, .roundedRectangle, .polygon, .slot:
            guard let first = pending.first else { pending = [q]; pendingSnaps = [snap]; break }
            guard simd_distance(first, q) > 1e-9 else { return }
            let firstSnap = pendingSnaps.first ?? nil
            pending = []
            pendingSnaps = []
            switch tool {
            case .circle:
                let e = entity(.circle, [first, first + SIMD2(simd_distance(first, q), 0)])
                var auto = snapConstraints(firstSnap, CADSketchRef(entity: e.id, part: CADSketchRef.centre))
                if let s = snap, !s.onEdge { auto.append(CADConstraint(kind: .pointOnObject, refs: [s.ref, CADSketchRef(entity: e.id, part: CADSketchRef.edge(0))])) }
                add([e], constraints: [], auto: auto, name: "Add Circle")
            case .rectangle:
                let e = entity(.rectangle, [first, q])
                add([e], constraints: [], auto: snapConstraints(firstSnap, CADSketchRef(entity: e.id, part: 0)) + snapConstraints(snap, CADSketchRef(entity: e.id, part: 2)), name: "Add Rectangle")
            case .centredRectangle:
                let e = entity(.rectangle, [2 * first - q, q])
                let centre = CADSketchEntity(kind: .point, points: [first])
                let sym = CADConstraint(kind: .symmetric, refs: [CADSketchRef(entity: e.id, part: 0), CADSketchRef(entity: e.id, part: 2), CADSketchRef(entity: centre.id, part: 0)])
                add([e, centre], constraints: [sym], auto: snapConstraints(firstSnap, CADSketchRef(entity: centre.id, part: 0)), name: "Add Centred Rectangle")
            case .roundedRectangle:
                let (es, cs) = roundedRectangle(first, q)
                add(es, constraints: cs, name: "Add Rounded Rectangle")
            case .polygon:
                let e = entity(.polygon, [first, q], sides: polygonSides)
                add([e], constraints: [], auto: snapConstraints(firstSnap, CADSketchRef(entity: e.id, part: CADSketchRef.centre)), name: "Add Polygon")
            case .slot:
                let (es, cs) = slotEntities(first, q)
                add(es, constraints: cs, auto: snapConstraints(firstSnap, CADSketchRef(entity: es[2].id, part: CADSketchRef.centre)), name: "Add Slot")
            default: break
            }
        case .fillet:
            filletCorner(near: q)
        case .trim:
            trim(at: q)
        case .select:
            break
        }
        needsDisplay = true
    }
    private var chainStartSnapRef: CADSketchRef? {
        get { chainStartSnap?.ref }
        set { chainStartSnap = newValue.map { Snap(ref: $0, onEdge: false) } }
    }

    private func endChain() {
        pending = []
        pendingSnaps = []
        chainStart = nil
        chainStartSnap = nil
        lastLineEnd = nil
        needsDisplay = true
    }

    /// Four lines and four quarter arcs, tangent where they meet, the arcs' radii equal.
    private func roundedRectangle(_ a0: SIMD2<Double>, _ b0: SIMD2<Double>) -> ([CADSketchEntity], [CADConstraint]) {
        let lo = simd_min(a0, b0), hi = simd_max(a0, b0)
        let r = max(1e-3, min(hi.x - lo.x, hi.y - lo.y) * 0.2)
        let lines = [
            entity(.line, [SIMD2(lo.x + r, lo.y), SIMD2(hi.x - r, lo.y)]),
            entity(.line, [SIMD2(hi.x, lo.y + r), SIMD2(hi.x, hi.y - r)]),
            entity(.line, [SIMD2(hi.x - r, hi.y), SIMD2(lo.x + r, hi.y)]),
            entity(.line, [SIMD2(lo.x, hi.y - r), SIMD2(lo.x, lo.y + r)]),
        ]
        let centres = [SIMD2(hi.x - r, lo.y + r), SIMD2(hi.x - r, hi.y - r), SIMD2(lo.x + r, hi.y - r), SIMD2(lo.x + r, lo.y + r)]
        var arcs: [CADSketchEntity] = []
        var cs: [CADConstraint] = []
        for k in 0..<4 {
            let c = centres[k]
            let start = lines[k].points[1], end = lines[(k + 1) % 4].points[0]
            let mid = c + simd_normalize((start - c) + (end - c)) * r
            arcs.append(entity(.arc, [start, end, mid]))
        }
        for k in 0..<4 {
            let l = lines[k], next = lines[(k + 1) % 4], a = arcs[k]
            cs.append(CADConstraint(kind: .coincident, refs: [CADSketchRef(entity: l.id, part: 1), CADSketchRef(entity: a.id, part: 0)]))
            cs.append(CADConstraint(kind: .coincident, refs: [CADSketchRef(entity: a.id, part: 1), CADSketchRef(entity: next.id, part: 0)]))
            cs.append(CADConstraint(kind: .tangent, refs: [CADSketchRef(entity: l.id, part: 1), CADSketchRef(entity: a.id, part: 0)], mode: 1))
            cs.append(CADConstraint(kind: .tangent, refs: [CADSketchRef(entity: a.id, part: 1), CADSketchRef(entity: next.id, part: 0)], mode: 1))
            cs.append(CADConstraint(kind: k % 2 == 0 ? .horizontal : .vertical, refs: [CADSketchRef(entity: l.id, part: CADSketchRef.edge(0))]))
            if k > 0 { cs.append(CADConstraint(kind: .equal, refs: [CADSketchRef(entity: arcs[0].id, part: CADSketchRef.edge(0)), CADSketchRef(entity: a.id, part: CADSketchRef.edge(0))])) }
        }
        return (lines + arcs, cs)
    }

    /// Two lines and two half circles round two centres.
    private func slotEntities(_ c1: SIMD2<Double>, _ c2: SIMD2<Double>) -> ([CADSketchEntity], [CADConstraint]) {
        let d = c2 - c1, len = simd_length(d)
        guard len > 1e-9 else { return ([], []) }
        let u = d / len, nrm = SIMD2(-u.y, u.x), r = len / 4
        let top = entity(.line, [c1 + nrm * r, c2 + nrm * r])
        let bottom = entity(.line, [c2 - nrm * r, c1 - nrm * r])
        let end2 = entity(.arc, [c2 - nrm * r, c2 + nrm * r, c2 + u * r])
        let end1 = entity(.arc, [c1 + nrm * r, c1 - nrm * r, c1 - u * r])
        func ref(_ e: CADSketchEntity, _ p: Int) -> CADSketchRef { CADSketchRef(entity: e.id, part: p) }
        var cs: [CADConstraint] = []
        for (a, b) in [(ref(top, 1), ref(end2, 1)), (ref(end2, 0), ref(bottom, 0)), (ref(bottom, 1), ref(end1, 1)), (ref(end1, 0), ref(top, 0))] {
            cs.append(CADConstraint(kind: .coincident, refs: [a, b]))
            cs.append(CADConstraint(kind: .tangent, refs: [a, b], mode: 1))
        }
        cs.append(CADConstraint(kind: .equal, refs: [ref(end1, CADSketchRef.edge(0)), ref(end2, CADSketchRef.edge(0))]))
        return ([top, bottom, end2, end1], cs)
    }

    // MARK: Fillet and trim

    private func filletCorner(near q: SIMD2<Double>) {
        var s = working
        let tol = Double(8 / scale)
        // Two lines with an end at the click.
        var hits: [(Int, Int)] = []
        for (i, e) in s.entities.enumerated() where e.kind == .line && e.points.count >= 2 {
            for k in 0..<2 where simd_distance(e.points[k], q) < tol { hits.append((i, k)) }
        }
        guard hits.count >= 2 else { tell("Click where two lines meet."); return }
        let (i1, k1) = hits[0], (i2, k2) = hits[1]
        let P = s.entities[i1].points[k1]
        guard simd_distance(P, s.entities[i2].points[k2]) < 1e-6 else { tell("Those lines don't meet."); return }
        let far1 = s.entities[i1].points[1 - k1], far2 = s.entities[i2].points[1 - k2]
        let d1 = simd_normalize(far1 - P), d2 = simd_normalize(far2 - P)
        let phi = acos(max(-1, min(1, simd_dot(d1, d2))))
        guard phi > 0.01, phi < .pi - 0.01 else { tell("Those lines are in line."); return }
        let r = filletRadius
        let t = r / tan(phi / 2)
        guard t < simd_distance(P, far1), t < simd_distance(P, far2) else { tell("The fillet is bigger than the lines."); return }
        let T1 = P + d1 * t, T2 = P + d2 * t
        let C = P + simd_normalize(d1 + d2) * (r / sin(phi / 2))
        let through = C + simd_normalize(P - C) * r
        s.entities[i1].points[k1] = T1
        s.entities[i2].points[k2] = T2
        let id1 = s.entities[i1].id, id2 = s.entities[i2].id
        let r1 = CADSketchRef(entity: id1, part: k1), r2 = CADSketchRef(entity: id2, part: k2)
        // The corner's coincidence goes; the arc joins both lines, tangent to them.
        s.constraints = s.constraints?.filter { !($0.kind == .coincident && Set($0.refs) == Set([r1, r2])) }
        let arc = CADSketchEntity(kind: .arc, points: [T1, T2, through], construction: s.entities[i1].construction)
        s.entities.append(arc)
        let a0 = CADSketchRef(entity: arc.id, part: 0), a1 = CADSketchRef(entity: arc.id, part: 1)
        s.constraints = (s.constraints ?? []) + [
            CADConstraint(kind: .coincident, refs: [r1, a0]), CADConstraint(kind: .coincident, refs: [r2, a1]),
            CADConstraint(kind: .tangent, refs: [r1, a0], mode: 1), CADConstraint(kind: .tangent, refs: [r2, a1], mode: 1),
        ]
        commit(CADSketchSolver.solve(s, values: values, analyse: false).0, "Sketch Fillet")
    }

    /// Where an edge crosses the others: the parameters along it (0…1 for lines, angles from the start for arcs and circles).
    private func crossings(_ e: CADSketchEntity, in s: CADSketch) -> [Double] {
        var out: [Double] = []
        let g = CADSketchSolver.Reader(sketch: s, layout: CADSketchSolver.Layout(s), x: CADSketchSolver.variables(s))
        let others = s.entities.filter { $0.id != e.id }.flatMap { o -> [CADSketchSolver.Edge] in
            switch o.kind {
            case .line, .arc, .circle: return [g.edge(CADSketchRef(entity: o.id, part: CADSketchRef.edge(0)))].compactMap { $0 }
            case .rectangle: return (0..<4).compactMap { g.edge(CADSketchRef(entity: o.id, part: CADSketchRef.edge($0))) }
            case .polygon: return (0..<max(3, o.sides ?? 6)).compactMap { g.edge(CADSketchRef(entity: o.id, part: CADSketchRef.edge($0))) }
            case .point: return []
            }
        }
        // Only the visible part of other arcs counts.
        let otherArcs = s.entities.filter { $0.id != e.id && $0.kind == .arc && $0.points.count >= 3 }
        func onOtherArc(_ p: SIMD2<Double>) -> Bool {
            for a in otherArcs {
                let c = CADSketchSolver.Reader.circumcentre(a.points[0], a.points[1], a.points[2])
                if abs(simd_distance(p, c) - simd_distance(a.points[0], c)) < 1e-6 {
                    return Self.arcContains(a, p)
                }
            }
            return true
        }
        let selfEdge = g.edge(CADSketchRef(entity: e.id, part: CADSketchRef.edge(0)))
        for o in others {
            for p in Self.intersect(selfEdge, o) where onOtherArc(p) {
                switch e.kind {
                case .line:
                    let a = e.points[0], b = e.points[1], d = b - a
                    let t = simd_dot(p - a, d) / max(1e-18, simd_length_squared(d))
                    if t > 1e-9, t < 1 - 1e-9 { out.append(t) }
                case .arc, .circle:
                    if e.kind == .arc, !Self.arcContains(e, p) { continue }
                    out.append(Self.angleFromStart(e, p))
                default: break
                }
            }
        }
        return out.sorted()
    }

    static func arcContains(_ a: CADSketchEntity, _ p: SIMD2<Double>) -> Bool {
        let c = CADSketchSolver.Reader.circumcentre(a.points[0], a.points[1], a.points[2])
        let t = sweepAngle(a, to: p, centre: c), end = sweepAngle(a, to: a.points[1], centre: c)
        return t >= -1e-9 && t <= end + 1e-9
    }

    /// The angle from an arc's (or circle's) start round to a point, the way it runs.
    private static func sweepAngle(_ a: CADSketchEntity, to p: SIMD2<Double>, centre c: SIMD2<Double>) -> Double {
        let start = atan2(a.points[0].y - c.y, a.points[0].x - c.x)
        let ccw: Bool
        if a.kind == .arc {
            let m = atan2(a.points[2].y - c.y, a.points[2].x - c.x), e = atan2(a.points[1].y - c.y, a.points[1].x - c.x)
            func norm(_ x: Double) -> Double { var y = x - start; while y < 0 { y += 2 * .pi }; while y >= 2 * .pi { y -= 2 * .pi }; return y }
            ccw = norm(m) < norm(e)
        } else { ccw = true }
        var t = atan2(p.y - c.y, p.x - c.x) - start
        if !ccw { t = -t }
        while t < 0 { t += 2 * .pi }
        while t >= 2 * .pi { t -= 2 * .pi }
        return t
    }

    private static func angleFromStart(_ e: CADSketchEntity, _ p: SIMD2<Double>) -> Double {
        let c = e.kind == .circle ? e.points[0] : CADSketchSolver.Reader.circumcentre(e.points[0], e.points[1], e.points[2])
        if e.kind == .circle { var t = atan2(p.y - c.y, p.x - c.x); if t < 0 { t += 2 * .pi }; return t }
        return sweepAngle(e, to: p, centre: c)
    }

    static func intersect(_ a: CADSketchSolver.Edge?, _ b: CADSketchSolver.Edge?) -> [SIMD2<Double>] {
        guard let a, let b else { return [] }
        func segSeg(_ p: SIMD2<Double>, _ q: SIMD2<Double>, _ r: SIMD2<Double>, _ s: SIMD2<Double>) -> [SIMD2<Double>] {
            let d1 = q - p, d2 = s - r
            let den = d1.x * d2.y - d1.y * d2.x
            guard abs(den) > 1e-12 else { return [] }
            let t = ((r - p).x * d2.y - (r - p).y * d2.x) / den, u = ((r - p).x * d1.y - (r - p).y * d1.x) / den
            return t >= -1e-9 && t <= 1 + 1e-9 && u >= -1e-9 && u <= 1 + 1e-9 ? [p + d1 * t] : []
        }
        func segCircle(_ p: SIMD2<Double>, _ q: SIMD2<Double>, _ c: SIMD2<Double>, _ r: Double) -> [SIMD2<Double>] {
            let d = q - p, f = p - c
            let A = simd_dot(d, d), B = 2 * simd_dot(f, d), C = simd_dot(f, f) - r * r
            let disc = B * B - 4 * A * C
            guard A > 1e-18, disc >= 0 else { return [] }
            let sq = sqrt(disc)
            return [(-B - sq) / (2 * A), (-B + sq) / (2 * A)].filter { $0 >= -1e-9 && $0 <= 1 + 1e-9 }.map { p + d * $0 }
        }
        func circleCircle(_ c1: SIMD2<Double>, _ r1: Double, _ c2: SIMD2<Double>, _ r2: Double) -> [SIMD2<Double>] {
            let d = simd_distance(c1, c2)
            guard d > 1e-12, d <= r1 + r2 + 1e-9, d >= abs(r1 - r2) - 1e-9 else { return [] }
            let a = (r1 * r1 - r2 * r2 + d * d) / (2 * d), h = sqrt(max(0, r1 * r1 - a * a))
            let m = c1 + (c2 - c1) * (a / d), perp = SIMD2(-(c2 - c1).y, (c2 - c1).x) / d
            return h < 1e-12 ? [m] : [m + perp * h, m - perp * h]
        }
        switch (a, b) {
        case (.segment(let p, let q), .segment(let r, let s)): return segSeg(p, q, r, s)
        case (.segment(let p, let q), .circle(let c, let r)), (.circle(let c, let r), .segment(let p, let q)): return segCircle(p, q, c, r)
        case (.circle(let c1, let r1), .circle(let c2, let r2)): return circleCircle(c1, r1, c2, r2)
        }
    }

    private func trim(at q: SIMD2<Double>) {
        var s = working
        guard let hit = pick(toView(q)), hit.isEdge, !hit.isRoot, var i = s.entities.firstIndex(where: { $0.id == hit.entity }) else { tell("Click an edge."); return }
        // A rectangle's or polygon's side: the shape becomes lines first.
        if [.rectangle, .polygon].contains(s.entities[i].kind) {
            let shape = s.entities[i]
            let g = CADSketchSolver.Reader(sketch: s, layout: CADSketchSolver.Layout(s), x: CADSketchSolver.variables(s))
            let n = shape.kind == .rectangle ? 4 : max(3, shape.sides ?? 6)
            let corners = (0..<n).compactMap { g.point(CADSketchRef(entity: shape.id, part: $0)) }
            let lines = (0..<n).map { CADSketchEntity(kind: .line, points: [corners[$0], corners[($0 + 1) % n]], construction: shape.construction) }
            s.entities.remove(at: i)
            s.entities += lines
            s.constraints = s.constraints?.filter { !$0.refs.contains { $0.entity == shape.id } }
            var extra: [CADConstraint] = []
            for k in 0..<n {
                extra.append(CADConstraint(kind: .coincident, refs: [CADSketchRef(entity: lines[k].id, part: 1), CADSketchRef(entity: lines[(k + 1) % n].id, part: 0)]))
                if shape.kind == .rectangle { extra.append(CADConstraint(kind: k % 2 == 0 ? .horizontal : .vertical, refs: [CADSketchRef(entity: lines[k].id, part: CADSketchRef.edge(0))])) }
            }
            s.constraints = (s.constraints ?? []) + extra
            i = s.entities.firstIndex { $0.id == lines[hit.edgeIndex].id }!
        }
        let e = s.entities[i]
        let cuts = crossings(e, in: s)
        let removeRefs: (UUID) -> Void = { id in s.constraints = s.constraints?.filter { !$0.refs.contains { $0.entity == id } } }
        switch e.kind {
        case .line:
            let a = e.points[0], b = e.points[1], d = b - a
            let t = simd_dot(q - a, d) / max(1e-18, simd_length_squared(d))
            let lo = cuts.last { $0 < t }, hi = cuts.first { $0 > t }
            removeRefs(e.id)
            switch (lo, hi) {
            case (nil, nil): s.entities.remove(at: i)
            case (nil, let h?): s.entities[i].points[0] = a + d * h
            case (let l?, nil): s.entities[i].points[1] = a + d * l
            case (let l?, let h?):
                s.entities[i].points[1] = a + d * l
                s.entities.append(CADSketchEntity(kind: .line, points: [a + d * h, b], construction: e.construction))
            }
        case .arc, .circle:
            let c = e.kind == .circle ? e.points[0] : CADSketchSolver.Reader.circumcentre(e.points[0], e.points[1], e.points[2])
            let r = e.kind == .circle ? e.radius : simd_distance(c, e.points[0])
            let t = Self.angleFromStart(e, q)
            removeRefs(e.id)
            func point(_ angleFromStart: Double) -> SIMD2<Double> {
                if e.kind == .circle { return c + r * SIMD2(cos(angleFromStart), sin(angleFromStart)) }
                let start = atan2(e.points[0].y - c.y, e.points[0].x - c.x)
                let ccw = Self.sweepAngle(e, to: e.points[2], centre: c) >= 0 && {
                    let m = atan2(e.points[2].y - c.y, e.points[2].x - c.x), en = atan2(e.points[1].y - c.y, e.points[1].x - c.x)
                    func norm(_ x: Double) -> Double { var y = x - start; while y < 0 { y += 2 * .pi }; while y >= 2 * .pi { y -= 2 * .pi }; return y }
                    return norm(m) < norm(en)
                }()
                let a = start + (ccw ? angleFromStart : -angleFromStart)
                return c + r * SIMD2(cos(a), sin(a))
            }
            func arcBetween(_ t0: Double, _ t1: Double) -> CADSketchEntity {
                CADSketchEntity(kind: .arc, points: [point(t0), point(t1), point((t0 + t1) / 2)], construction: e.construction)
            }
            if e.kind == .circle {
                guard cuts.count >= 2 else { s.entities.remove(at: i); break }
                // Keep the rest of the circle: from the crossing after the click round to the one before.
                let hi = cuts.first { $0 > t } ?? cuts[0] + 2 * .pi
                let lo = cuts.last { $0 < t } ?? cuts[cuts.count - 1] - 2 * .pi
                s.entities[i] = arcBetween(hi, lo + 2 * .pi)
                s.entities[i].id = e.id
            } else {
                let end = Self.sweepAngle(e, to: e.points[1], centre: c)
                let lo = cuts.last { $0 < t }, hi = cuts.first { $0 > t }
                switch (lo, hi) {
                case (nil, nil): s.entities.remove(at: i)
                case (nil, let h?): s.entities[i] = arcBetween(h, end); s.entities[i].id = e.id
                case (let l?, nil): s.entities[i] = arcBetween(0, l); s.entities[i].id = e.id
                case (let l?, let h?):
                    s.entities[i] = arcBetween(0, l)
                    s.entities[i].id = e.id
                    s.entities.append(arcBetween(h, end))
                }
            }
        default:
            return
        }
        selection = []
        commit(CADSketchSolver.solve(s, values: values, analyse: false).0, "Trim")
    }

    // MARK: Constraints from the selection

    private func kindOf(_ r: CADSketchRef) -> (isPoint: Bool, isLine: Bool, isCircle: Bool) {
        if !r.isEdge { return (true, false, false) }
        switch reader.edge(r) {
        case .segment?: return (false, true, false)
        case .circle?: return (false, false, true)
        case nil: return (false, false, false)
        }
    }

    /// Applies a constraint to what's selected (as FreeCAD does: select, then constrain).
    func constrain(_ kind: CADConstraint.Kind) {
        let sel = selection
        let points = sel.filter { kindOf($0).isPoint }, lines = sel.filter { kindOf($0).isLine }, circles = sel.filter { kindOf($0).isCircle }
        var list: [CADConstraint] = []
        func needs(_ text: String) { tell(text) }
        func dim(_ k: CADConstraint.Kind, _ refs: [CADSketchRef]) -> CADConstraint? {
            guard var v = CADSketchSolver.measure(k, refs: refs, in: sketch) else { return nil }
            var refs = refs
            // A signed distance reads left to right, bottom to top.
            if (k == .distanceX || k == .distanceY), v < 0, refs.count == 2 { refs.reverse(); v = -v }
            return CADConstraint(kind: k, refs: refs, value: CADSketchSolver.format(v))
        }
        switch kind {
        case .coincident:
            guard points.count >= 2 else { return needs("Select two points or more.") }
            list = points.dropFirst().map { CADConstraint(kind: .coincident, refs: [points[0], $0]) }
        case .pointOnObject:
            guard points.count >= 1, let edge = (lines + circles).first else { return needs("Select a point and an edge.") }
            list = points.map { CADConstraint(kind: .pointOnObject, refs: [$0, edge]) }
        case .horizontal, .vertical:
            if !lines.isEmpty { list = lines.map { CADConstraint(kind: kind, refs: [$0]) } } else if points.count == 2 { list = [CADConstraint(kind: kind, refs: points)] } else { return needs("Select lines, or two points.") }
        case .parallel, .perpendicular:
            guard lines.count >= 2 else { return needs("Select two lines.") }
            list = kind == .parallel ? lines.dropFirst().map { CADConstraint(kind: kind, refs: [lines[0], $0]) } : [CADConstraint(kind: kind, refs: [lines[0], lines[1]])]
        case .tangent:
            let edges = lines + circles
            guard edges.count == 2, !circles.isEmpty || lines.count == 2 else { return needs("Select two edges (a line and a circle or arc, or two arcs).") }
            // Edges that meet end to end are tangent there.
            let g = reader
            var met: (CADSketchRef, CADSketchRef)?
            let ends1 = [0, 1].map { CADSketchRef(entity: edges[0].entity, part: $0) }, ends2 = [0, 1].map { CADSketchRef(entity: edges[1].entity, part: $0) }
            for p in ends1 { for q in ends2 { if let a = g.point(p), let b = g.point(q), simd_distance(a, b) < 1e-6 { met = (p, q) } } }
            if let (p, q) = met {
                list = [CADConstraint(kind: .tangent, refs: [p, q], mode: 1)]
            } else if circles.count == 2, case .circle(let c1, let r1)? = g.edge(circles[0]), case .circle(let c2, let r2)? = g.edge(circles[1]) {
                list = [CADConstraint(kind: .tangent, refs: circles, mode: simd_distance(c1, c2) < max(r1, r2) ? 2 : nil)]
            } else {
                list = [CADConstraint(kind: .tangent, refs: edges)]
            }
        case .equal:
            if lines.count >= 2 { list = lines.dropFirst().map { CADConstraint(kind: .equal, refs: [lines[0], $0]) } } else if circles.count >= 2 { list = circles.dropFirst().map { CADConstraint(kind: .equal, refs: [circles[0], $0]) } } else { return needs("Select two lines, or two circles or arcs.") }
        case .symmetric:
            if points.count == 2, let l = lines.first { list = [CADConstraint(kind: .symmetric, refs: points + [l])] } else if points.count == 3 { list = [CADConstraint(kind: .symmetric, refs: points)] } else { return needs("Select two points and a line, or three points (the last the centre).") }
        case .lock:
            guard !points.isEmpty else { return needs("Select points.") }
            let g = reader
            list = points.compactMap { r in g.point(r).map { CADConstraint(kind: .lock, refs: [r], value: CADSketchSolver.format($0.x), value2: CADSketchSolver.format($0.y)) } }
        case .block:
            let ids = Set(sel.filter { !$0.isRoot }.map(\.entity))
            guard !ids.isEmpty else { return needs("Select geometry.") }
            list = sketch.entities.filter { ids.contains($0.id) }.map { CADConstraint(kind: .block, refs: [CADSketchRef(entity: $0.id, part: 0)], fixed: $0.points.flatMap { [$0.x, $0.y] }) }
        case .distanceX, .distanceY:
            if points.count == 2 { list = [dim(kind, points)].compactMap { $0 } } else if let l = lines.first { list = [dim(kind, [l])].compactMap { $0 } } else if points.count == 1 { list = [dim(kind, points)].compactMap { $0 } } else { return needs("Select two points, a line, or a point.") }
        case .distance:
            if points.count == 2 { list = [dim(.distance, points)].compactMap { $0 } } else if points.count == 1, let l = lines.first { list = [dim(.distance, [points[0], l])].compactMap { $0 } } else if let l = lines.first { list = [dim(.distance, [l])].compactMap { $0 } } else { return needs("Select two points, a line, or a point and a line.") }
        case .radius, .diameter:
            guard !circles.isEmpty else { return needs("Select circles or arcs.") }
            list = circles.compactMap { dim(kind, [$0]) }
        case .angle:
            if lines.count >= 2 { list = [dim(.angle, [lines[0], lines[1]])].compactMap { $0 } } else if let l = lines.first { list = [dim(.angle, [l])].compactMap { $0 } } else { return needs("Select one or two lines.") }
        }
        guard !list.isEmpty else { return }
        var s = sketch
        if addConstraints(list, to: &s, quiet: false) {
            commit(s, kind.title)
            selection = []
        }
    }

    /// Construction on or off for what's selected (else for what's drawn next).
    func toggleConstruction() {
        let ids = Set(selection.filter { !$0.isRoot }.map(\.entity))
        if ids.isEmpty { constructionMode.toggle(); needsDisplay = true; return }
        var s = sketch
        for i in s.entities.indices where ids.contains(s.entities[i].id) && s.entities[i].kind != .point {
            s.entities[i].construction = s.entities[i].construction == true ? nil : true
        }
        commit(s, "Toggle Construction")
    }

    func deleteSelection() {
        var s = sketch
        if let c = selectedConstraint {
            s.constraints?.removeAll { $0.id == c }
            selectedConstraint = nil
            commit(s, "Delete Constraint")
            return
        }
        let ids = Set(selection.filter { !$0.isRoot }.map(\.entity))
        guard !ids.isEmpty else { NSSound.beep(); return }
        s.entities.removeAll { ids.contains($0.id) }
        s.constraints = s.constraints?.filter { !$0.refs.contains { ids.contains($0.entity) } }
        selection = []
        commit(s, "Delete Geometry")
    }

    // MARK: Editing a dimension

    private func beginEditing(_ id: UUID) {
        guard let c = sketch.constraints?.first(where: { $0.id == id }), c.kind.isDimension, c.kind != .lock,
              let rect = labelRects.first(where: { $0.id == id })?.rect else { return }
        editor?.removeFromSuperview()
        let field = NSTextField(string: c.value ?? "")
        field.frame = NSRect(x: rect.midX - 60, y: rect.midY - 11, width: 120, height: 22)
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        field.delegate = self
        field.focusRingType = .default
        addSubview(field)
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        editor = field
        editing = id
    }

    private func endEditing(commit save: Bool) {
        guard let field = editor, let id = editing else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        editor = nil
        editing = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        guard save, !text.isEmpty, (try? CADExpression.evaluate(text, values)) != nil, var s = Optional(sketch),
              let i = s.constraints?.firstIndex(where: { $0.id == id }) else { if save, !text.isEmpty { tell("Can't read “\(text)”.") }; return }
        s.constraints?[i].value = text
        let (solved, st) = CADSketchSolver.solve(s, values: values)
        if st.conflicting { tell("The sketch can't take that size."); return }
        commit(solved, "Change Dimension")
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) { endEditing(commit: true); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { endEditing(commit: false); return true }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) { endEditing(commit: true) }

    // MARK: Dragging

    /// Variable targets that move a point (or an edge) to where the mouse is.
    private func dragTargets(_ base: CADSketch, _ r: CADSketchRef, from start: SIMD2<Double>, to q: SIMD2<Double>) -> [Int: Double] {
        let layout = CADSketchSolver.Layout(base)
        guard let i = layout.index[r.entity] else { return [:] }
        let e = base.entities[i], o = layout.offsets[i]
        let delta = q - start
        var t: [Int: Double] = [:]
        func set(_ k: Int, _ p: SIMD2<Double>) { t[o + 2 * k] = p.x; t[o + 2 * k + 1] = p.y }
        func moveAll() { for k in e.points.indices { set(k, e.points[k] + delta) } }
        if r.isEdge {
            switch e.kind {
            case .circle: set(1, e.points[0] + SIMD2(simd_distance(q, e.points[0]), 0))
            case .arc:
                let c = CADSketchSolver.Reader.circumcentre(e.points[0], e.points[1], e.points[2])
                let r0 = simd_distance(c, e.points[0]), r1 = simd_distance(c, q)
                if r0 > 1e-9 { for k in 0..<3 { set(k, c + (e.points[k] - c) * (r1 / r0)) } }
            case .rectangle:
                switch r.edgeIndex {
                case 0: t[o + 1] = e.points[0].y + delta.y
                case 1: t[o + 2] = e.points[1].x + delta.x
                case 2: t[o + 3] = e.points[1].y + delta.y
                default: t[o] = e.points[0].x + delta.x
                }
            default: moveAll()
            }
            return t
        }
        switch (e.kind, r.part) {
        case (.line, 0), (.line, 1), (.arc, 0), (.arc, 1), (.point, 0): set(r.part, e.points[r.part] + delta)
        case (.rectangle, 0): set(0, e.points[0] + delta)
        case (.rectangle, 2): set(1, e.points[1] + delta)
        case (.rectangle, 1): t[o + 2] = e.points[1].x + delta.x; t[o + 1] = e.points[0].y + delta.y
        case (.rectangle, 3): t[o] = e.points[0].x + delta.x; t[o + 3] = e.points[1].y + delta.y
        case (.polygon, let k) where k >= 0:
            let c = e.points[0], n = max(3, e.sides ?? 6), a = -2 * Double.pi * Double(k) / Double(n)
            let v = q - c
            set(1, c + SIMD2(v.x * cos(a) - v.y * sin(a), v.x * sin(a) + v.y * cos(a)))
        default: moveAll()
        }
        return t
    }

    // MARK: Mouse and keys

    override func mouseDown(with event: NSEvent) {
        if editor != nil { endEditing(commit: true) }
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        if tool == .select {
            // A point first (a coincidence's dot is drawn over it); then a constraint's label: select it,
            // double-click a dimension to change it, drag to move it.
            let onPoint = pick(p).map { !$0.isEdge } ?? false
            if !onPoint, let hit = labelRects.last(where: { $0.rect.insetBy(dx: -2, dy: -2).contains(p) }) {
                selection = []
                selectedConstraint = hit.id
                if event.clickCount == 2 { beginEditing(hit.id); return }
                if let c = sketch.constraints?.first(where: { $0.id == hit.id }), c.kind.isDimension {
                    dragConstraint = (hit.id, toSketch(p), c.labelOffset ?? .zero)
                }
                return
            }
            selectedConstraint = nil
            let extend = event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command)
            if let r = pick(p) {
                if extend {
                    if let i = selection.firstIndex(of: r) { selection.remove(at: i) } else { selection.append(r) }
                } else if !selection.contains(r) {
                    selection = [r]
                }
                if !r.isRoot {
                    dragBase = sketch
                    dragRef = r
                    dragFrom = toSketch(p)
                }
                return
            }
            if !extend { selection = [] }
            boxStart = p
            return
        }
        let (q, s) = snap(p)
        downAt = q
        if event.clickCount == 2, tool == .line { endChain(); return }
        click(q, s)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let d = dragConstraint, var cs = sketch.constraints, let i = cs.firstIndex(where: { $0.id == d.id }) {
            cs[i].labelOffset = d.offset + (toSketch(p) - d.start)
            sketch.constraints = cs
            needsDisplay = true
            return
        }
        if let base = dragBase, let r = dragRef, let from = dragFrom {
            let targets = dragTargets(base, r, from: from, to: toSketch(p))
            sketch = CADSketchSolver.solve(base, values: values, drag: targets, analyse: false).0
            needsDisplay = true
            return
        }
        if boxStart != nil { boxEnd = p; needsDisplay = true; return }
        let (q, s) = snap(p)
        hover = q
        hoverSnap = s
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { downAt = nil }
        let p = convert(event.locationInWindow, from: nil)
        if dragConstraint != nil {
            dragConstraint = nil
            onCommit?(sketch, "Move Dimension")
            return
        }
        if let base = dragBase {
            dragBase = nil
            dragRef = nil
            dragFrom = nil
            if sketch != base { onCommit?(sketch, "Drag") }
            needsDisplay = true
            return
        }
        if let a = boxStart {
            boxStart = nil
            if let b = boxEnd {
                boxEnd = nil
                let lo = toSketch(NSPoint(x: min(a.x, b.x), y: min(a.y, b.y))), hi = toSketch(NSPoint(x: max(a.x, b.x), y: max(a.y, b.y)))
                func inside(_ q: SIMD2<Double>) -> Bool { q.x >= lo.x && q.x <= hi.x && q.y >= lo.y && q.y <= hi.y }
                let g = reader
                var picked = pointRefs().filter { !$0.isRoot && g.point($0).map(inside) == true }
                picked += edgeRefs().filter { !$0.isRoot && polyline($0, g).allSatisfy(inside) }
                selection = picked
            }
            needsDisplay = true
            return
        }
        // Dragged out: the shape ends where the mouse went up.
        if let start = downAt, [.circle, .rectangle, .centredRectangle, .roundedRectangle, .polygon, .slot].contains(tool), pending.count == 1 {
            let (q, s) = snap(p)
            if CGFloat(simd_distance(start, q)) * scale > 4 { click(q, s) }
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
        let p = convert(event.locationInWindow, from: nil)
        if tool == .select || tool == .trim || tool == .fillet {
            hover = nil
            hoverSnap = nil
            preselect = pick(p)
        } else {
            preselect = nil
            let (q, s) = snap(p)
            hover = q
            hoverSnap = s
        }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hover = nil
        preselect = nil
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
        case 53:                       // Esc: end what's being drawn, then the selection, then the tool
            if !pending.isEmpty { endChain() } else if !selection.isEmpty || selectedConstraint != nil { selection = []; selectedConstraint = nil } else { tool = .select }
        case 36, 76: endChain()        // Return, Enter
        case 51, 117: deleteSelection() // Delete
        default: super.keyDown(with: event)
        }
    }
}
