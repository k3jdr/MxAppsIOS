//
//  CADSketchSolver.swift
//  MxNoteONE
//
//  Sketch constraints, as FreeCAD's Sketcher has them — coincident, point on object, horizontal, vertical, parallel,
//  perpendicular, tangent, equal, symmetric, lock, block, horizontal / vertical distance, distance, radius, diameter
//  and angle — and the solver that moves the sketch's points until they all hold (Levenberg–Marquardt, taking the
//  smallest step that does, so what isn't constrained stays where it was). Dimensions are expressions of the model's
//  parameters. The solver also counts the degrees of freedom left, says which shapes are fully constrained, and
//  finds constraints that conflict or repeat another.
//

import Foundation
import simd

/// A point or an edge of a sketch: an entity's corner `k` (0, 1, …), its centre, or its edge `k` (`edge(k)`).
struct CADSketchRef: Codable, Hashable {
    var entity: UUID
    var part: Int

    static let centre = -1
    static func edge(_ k: Int = 0) -> Int { 1000 + k }
    var isEdge: Bool { part >= 1000 }
    var edgeIndex: Int { part - 1000 }

    /// The sketch's own origin and its horizontal and vertical axes.
    static let rootID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    static let origin = CADSketchRef(entity: rootID, part: 0)
    static let hAxis = CADSketchRef(entity: rootID, part: 1000)
    static let vAxis = CADSketchRef(entity: rootID, part: 1001)
    var isRoot: Bool { entity == Self.rootID }
}

struct CADConstraint: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case coincident, pointOnObject, horizontal, vertical, parallel, perpendicular, tangent, equal, symmetric
        case lock, block, distanceX, distanceY, distance, radius, diameter, angle

        var title: String {
            switch self {
            case .coincident: "Coincident"
            case .pointOnObject: "Point on Object"
            case .horizontal: "Horizontal"
            case .vertical: "Vertical"
            case .parallel: "Parallel"
            case .perpendicular: "Perpendicular"
            case .tangent: "Tangent"
            case .equal: "Equal"
            case .symmetric: "Symmetric"
            case .lock: "Lock"
            case .block: "Block"
            case .distanceX: "Horizontal Distance"
            case .distanceY: "Vertical Distance"
            case .distance: "Distance"
            case .radius: "Radius"
            case .diameter: "Diameter"
            case .angle: "Angle"
            }
        }
        /// Sets a size (shown as a dimension, edited as an expression).
        var isDimension: Bool { [.distanceX, .distanceY, .distance, .radius, .diameter, .angle, .lock].contains(self) }
        var symbol: String {
            switch self {
            case .coincident: "smallcircle.filled.circle"
            case .pointOnObject: "point.topleft.down.to.point.bottomright.curvepath"
            case .horizontal: "arrow.left.and.right"
            case .vertical: "arrow.up.and.down"
            case .parallel: "pause"
            case .perpendicular: "angle"
            case .tangent: "circle.and.line.horizontal"
            case .equal: "equal"
            case .symmetric: "arrow.left.and.line.vertical.and.arrow.right"
            case .lock: "lock"
            case .block: "lock.square"
            case .distanceX: "arrow.left.and.right.square"
            case .distanceY: "arrow.up.and.down.square"
            case .distance: "ruler"
            case .radius: "circle.dashed"
            case .diameter: "circle.circle"
            case .angle: "angle"
            }
        }
    }

    var id = UUID()
    var kind: Kind
    var refs: [CADSketchRef]
    /// A dimension (mm; an angle's degrees), as an expression; a lock's X.
    var value: String?
    /// A lock's Y.
    var value2: String?
    /// Tangent: 1 where two edges meet end to end, 2 a circle inside another.
    var mode: Int?
    /// Block: the entity's points as they were.
    var fixed: [Double]?
    /// Where a dimension's label is drawn, from its usual place (sketch millimetres).
    var labelOffset: SIMD2<Double>?
}

/// What solving found.
struct CADSketchStatus: Equatable {
    var dof = 0
    var conflicting = false
    var redundant = 0
    /// Entities that can still move.
    var free: Set<UUID> = []
    var solved = true

    var summary: String {
        if conflicting { return "Conflicting constraints" }
        if redundant > 0 { return "Redundant constraints" }
        if dof == 0 { return "Fully constrained" }
        return "\(dof) degree\(dof == 1 ? "" : "s") of freedom"
    }
}

enum CADSketchSolver {
    enum Edge {
        case segment(SIMD2<Double>, SIMD2<Double>)
        case circle(SIMD2<Double>, Double)
    }

    /// The variables: every entity's points, x then y.
    struct Layout {
        var index: [UUID: Int] = [:]
        var offsets: [Int] = []
        var count = 0

        init(_ s: CADSketch) {
            for (i, e) in s.entities.enumerated() {
                index[e.id] = i
                offsets.append(count)
                count += e.points.count * 2
            }
        }
    }

    static func variables(_ s: CADSketch) -> [Double] { s.entities.flatMap { $0.points.flatMap { [$0.x, $0.y] } } }

    static func apply(_ x: [Double], to s: inout CADSketch) {
        var k = 0
        for i in s.entities.indices {
            for j in s.entities[i].points.indices {
                s.entities[i].points[j] = SIMD2(x[k], x[k + 1])
                k += 2
            }
        }
    }

    /// Reads points and edges for given variables.
    struct Reader {
        let sketch: CADSketch
        let layout: Layout
        let x: [Double]

        func p(_ e: Int, _ k: Int) -> SIMD2<Double> {
            let o = layout.offsets[e] + 2 * k
            return SIMD2(x[o], x[o + 1])
        }

        static func circumcentre(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ m: SIMD2<Double>) -> SIMD2<Double> {
            let d = 2 * (a.x * (m.y - b.y) + m.x * (b.y - a.y) + b.x * (a.y - m.y))
            guard abs(d) > 1e-12 else { return (a + b) / 2 }
            let a2 = simd_length_squared(a), m2 = simd_length_squared(m), b2 = simd_length_squared(b)
            return SIMD2((a2 * (m.y - b.y) + m2 * (b.y - a.y) + b2 * (a.y - m.y)) / d, (a2 * (b.x - m.x) + m2 * (a.x - b.x) + b2 * (m.x - a.x)) / d)
        }

        func point(_ r: CADSketchRef) -> SIMD2<Double>? {
            if r.isRoot { return r.part == 0 ? .zero : nil }
            guard let i = layout.index[r.entity] else { return nil }
            let e = sketch.entities[i]
            switch e.kind {
            case .point:
                return r.part == 0 ? p(i, 0) : nil
            case .line:
                return r.part == 0 || r.part == 1 ? p(i, r.part) : nil
            case .arc:
                if r.part == CADSketchRef.centre { return Self.circumcentre(p(i, 0), p(i, 1), p(i, 2)) }
                return r.part == 0 || r.part == 1 ? p(i, r.part) : nil
            case .circle:
                return r.part == CADSketchRef.centre ? p(i, 0) : nil
            case .rectangle:
                let a = p(i, 0), b = p(i, 1)
                if r.part == CADSketchRef.centre { return (a + b) / 2 }
                let corners = [a, SIMD2(b.x, a.y), b, SIMD2(a.x, b.y)]
                return corners.indices.contains(r.part) ? corners[r.part] : nil
            case .polygon:
                let c = p(i, 0)
                if r.part == CADSketchRef.centre { return c }
                let n = max(3, e.sides ?? 6)
                guard r.part >= 0, r.part < n else { return nil }
                let v = p(i, 1) - c, t = 2 * Double.pi * Double(r.part) / Double(n)
                return c + SIMD2(v.x * cos(t) - v.y * sin(t), v.x * sin(t) + v.y * cos(t))
            }
        }

        func edge(_ r: CADSketchRef) -> Edge? {
            if r.isRoot {
                if r.part == 1000 { return .segment(.zero, SIMD2(1, 0)) }
                if r.part == 1001 { return .segment(.zero, SIMD2(0, 1)) }
                return nil
            }
            guard r.isEdge, let i = layout.index[r.entity] else { return nil }
            let e = sketch.entities[i]
            let k = r.edgeIndex
            switch e.kind {
            case .line: return k == 0 ? .segment(p(i, 0), p(i, 1)) : nil
            case .arc:
                guard k == 0 else { return nil }
                let c = Self.circumcentre(p(i, 0), p(i, 1), p(i, 2))
                return .circle(c, simd_distance(c, p(i, 0)))
            case .circle: return k == 0 ? .circle(p(i, 0), simd_distance(p(i, 0), p(i, 1))) : nil
            case .rectangle, .polygon:
                let n = e.kind == .rectangle ? 4 : max(3, e.sides ?? 6)
                guard k >= 0, k < n, let a = point(CADSketchRef(entity: r.entity, part: k)),
                      let b = point(CADSketchRef(entity: r.entity, part: (k + 1) % n)) else { return nil }
                return .segment(a, b)
            case .point: return nil
            }
        }
    }

    private static func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { a.x * b.y - a.y * b.x }
    private static func unit(_ v: SIMD2<Double>) -> SIMD2<Double> { let l = simd_length(v); return l > 1e-12 ? v / l : SIMD2(1, 0) }

    /// How far a constraint is from holding (zero when it does), one number per equation.
    static func residuals(_ c: CADConstraint, _ g: Reader, _ vars: [String: Double], into out: inout [Double]) {
        func val(_ s: String?) -> Double? { s.flatMap { try? CADExpression.evaluate($0, vars) } }
        let refs = c.refs
        func pt(_ k: Int) -> SIMD2<Double>? { refs.indices.contains(k) ? g.point(refs[k]) : nil }
        func ed(_ k: Int) -> Edge? { refs.indices.contains(k) ? g.edge(refs[k]) : nil }
        func seg(_ k: Int) -> (SIMD2<Double>, SIMD2<Double>)? { if case .segment(let a, let b)? = ed(k) { return (a, b) }; return nil }
        func circ(_ k: Int) -> (SIMD2<Double>, Double)? { if case .circle(let o, let r)? = ed(k) { return (o, r) }; return nil }
        switch c.kind {
        case .coincident:
            guard let a = pt(0), let b = pt(1) else { return }
            out += [a.x - b.x, a.y - b.y]
        case .pointOnObject:
            guard let q = pt(0) else { return }
            if let (a, b) = seg(1) { out.append(cross(unit(b - a), q - a)) } else if let (o, r) = circ(1) { out.append(simd_distance(q, o) - r) }
        case .horizontal, .vertical:
            let h = c.kind == .horizontal
            if let (a, b) = seg(0) { out.append(h ? b.y - a.y : b.x - a.x) } else if let a = pt(0), let b = pt(1) { out.append(h ? b.y - a.y : b.x - a.x) }
        case .parallel, .perpendicular:
            guard let (a, b) = seg(0), let (p, q) = seg(1) else { return }
            let u = unit(b - a), v = unit(q - p)
            out.append(c.kind == .parallel ? cross(u, v) : simd_dot(u, v))
        case .equal:
            if let (a, b) = seg(0), let (p, q) = seg(1) { out.append(simd_distance(a, b) - simd_distance(p, q)) } else if let (_, r1) = circ(0), let (_, r2) = circ(1) { out.append(r1 - r2) }
        case .tangent:
            if c.mode == 1 {
                // End to end: the edges' directions agree where they meet (refs: the two meeting points).
                guard refs.count >= 2, let p = g.point(refs[0]) else { return }
                let e1 = g.edge(CADSketchRef(entity: refs[0].entity, part: CADSketchRef.edge(0))), e2 = g.edge(CADSketchRef(entity: refs[1].entity, part: CADSketchRef.edge(0)))
                switch (e1, e2) {
                case (.segment(let a, let b)?, .circle(let o, _)?), (.circle(let o, _)?, .segment(let a, let b)?):
                    out.append(simd_dot(unit(b - a), unit(p - o)))
                case (.circle(let o1, _)?, .circle(let o2, _)?):
                    out.append(cross(unit(p - o1), unit(p - o2)))
                case (.segment(let a, let b)?, .segment(let p2, let q2)?):
                    out.append(cross(unit(b - a), unit(q2 - p2)))
                default: return
                }
            } else if let (a, b) = seg(0), let (o, r) = circ(1) {
                out.append(abs(cross(unit(b - a), o - a)) - r)
            } else if let (o, r) = circ(0), let (a, b) = seg(1) {
                out.append(abs(cross(unit(b - a), o - a)) - r)
            } else if let (o1, r1) = circ(0), let (o2, r2) = circ(1) {
                out.append(c.mode == 2 ? simd_distance(o1, o2) - abs(r1 - r2) : simd_distance(o1, o2) - (r1 + r2))
            }
        case .symmetric:
            guard let a = pt(0), let b = pt(1) else { return }
            if let (p, q) = seg(2) {
                let d = unit(q - p), m = (a + b) / 2
                out += [cross(d, m - p), simd_dot(d, b - a)]
            } else if let o = pt(2) {
                let m = (a + b) / 2
                out += [m.x - o.x, m.y - o.y]
            }
        case .lock:
            guard let a = pt(0), let x = val(c.value), let y = val(c.value2) else { return }
            out += [a.x - x, a.y - y]
        case .block:
            guard let r = refs.first, let i = g.layout.index[r.entity], let fixed = c.fixed else { return }
            let e = g.sketch.entities[i]
            for k in 0..<min(e.points.count, fixed.count / 2) {
                let q = g.p(i, k)
                out += [q.x - fixed[2 * k], q.y - fixed[2 * k + 1]]
            }
        case .distanceX, .distanceY:
            guard let v = val(c.value) else { return }
            let horizontal = c.kind == .distanceX
            if let a = pt(0), let b = pt(1) { out.append((horizontal ? b.x - a.x : b.y - a.y) - v) } else if let (a, b) = seg(0) { out.append((horizontal ? b.x - a.x : b.y - a.y) - v) } else if let a = pt(0) { out.append((horizontal ? a.x : a.y) - v) }
        case .distance:
            guard let v = val(c.value) else { return }
            if let a = pt(0), let b = pt(1) { out.append(simd_distance(a, b) - v) } else if let a = pt(0), let (p, q) = seg(1) { out.append(abs(cross(unit(q - p), a - p)) - v) } else if let (a, b) = seg(0) { out.append(simd_distance(a, b) - v) }
        case .radius, .diameter:
            guard let v = val(c.value), let (_, r) = circ(0) else { return }
            out.append((c.kind == .radius ? r : 2 * r) - v)
        case .angle:
            guard let v = val(c.value) else { return }
            let target = v * .pi / 180
            var angle: Double
            if let (a, b) = seg(0), let (p, q) = seg(1) {
                let u = unit(b - a), w = unit(q - p)
                angle = atan2(cross(u, w), simd_dot(u, w))
            } else if let (a, b) = seg(0) {
                angle = atan2(b.y - a.y, b.x - a.x)
            } else { return }
            var d = angle - target
            while d > .pi { d -= 2 * .pi }
            while d < -.pi { d += 2 * .pi }
            out.append(d * 10)
        }
    }

    /// Equations every sketch has: an arc's middle point stays midway along it, a circle's edge point level with
    /// its centre (so neither adds a freedom of its own).
    static func implicitResiduals(_ g: Reader, into out: inout [Double]) {
        for (i, e) in g.sketch.entities.enumerated() {
            switch e.kind {
            case .arc where e.points.count >= 3:
                out.append(simd_distance(g.p(i, 2), g.p(i, 0)) - simd_distance(g.p(i, 2), g.p(i, 1)))
            case .circle where e.points.count >= 2:
                out.append(g.p(i, 1).y - g.p(i, 0).y)
            default: break
            }
        }
    }

    static func allResiduals(_ s: CADSketch, _ layout: Layout, _ x: [Double], _ vars: [String: Double]) -> [Double] {
        let g = Reader(sketch: s, layout: layout, x: x)
        var out: [Double] = []
        for c in s.constraints ?? [] { residuals(c, g, vars, into: &out) }
        implicitResiduals(g, into: &out)
        return out
    }

    /// The sketch with its constraints holding, and what solving found. `drag` pulls variables towards targets
    /// (gently, so constraints win).
    static func solve(_ sketch: CADSketch, values vars: [String: Double], drag: [Int: Double] = [:], analyse: Bool = true) -> (CADSketch, CADSketchStatus) {
        var s = sketch
        let layout = Layout(sketch)
        var x = variables(sketch)
        let n = x.count
        guard n > 0 else { return (s, CADSketchStatus()) }
        let weight = 0.05
        func r(_ x: [Double]) -> [Double] {
            var out = allResiduals(s, layout, x, vars)
            for (i, t) in drag.sorted(by: { $0.key < $1.key }) where i < n { out.append((x[i] - t) * weight) }
            return out
        }
        var res = r(x)
        var cost = res.reduce(0) { $0 + $1 * $1 }
        var lambda = 1e-6
        var iteration = 0
        while cost > 1e-22, iteration < 80, !res.isEmpty {
            iteration += 1
            let J = jacobian(r, x, res)
            let m = res.count
            // The smallest step: (J Jᵀ + λI) y = −r, Δx = Jᵀ y.
            var A = [Double](repeating: 0, count: m * m)
            for a in 0..<m {
                for b in a..<m {
                    var sum = 0.0
                    for k in 0..<n { sum += J[a * n + k] * J[b * n + k] }
                    A[a * m + b] = sum
                    A[b * m + a] = sum
                }
            }
            var improved = false
            for _ in 0..<12 {
                var M = A
                for a in 0..<m { M[a * m + a] += lambda * max(1, A[a * m + a]) }
                guard let y = solveLinear(M, res.map { -$0 }, m) else { lambda *= 10; continue }
                var x2 = x
                for k in 0..<n {
                    var sum = 0.0
                    for a in 0..<m { sum += J[a * n + k] * y[a] }
                    x2[k] += sum
                }
                let res2 = r(x2)
                let cost2 = res2.reduce(0) { $0 + $1 * $1 }
                if cost2 < cost {
                    x = x2
                    res = res2
                    cost = cost2
                    lambda = max(1e-12, lambda / 5)
                    improved = true
                    break
                }
                lambda *= 8
            }
            if !improved { break }
        }
        apply(x, to: &s)
        var status = CADSketchStatus()
        let plain = allResiduals(s, layout, x, vars)
        let error = plain.reduce(0) { max($0, abs($1)) }
        status.conflicting = error > 1e-6
        status.solved = !status.conflicting
        if analyse { analyseFreedom(s, layout, x, vars, plain, &status) }
        return (s, status)
    }

    private static func jacobian(_ f: ([Double]) -> [Double], _ x: [Double], _ r0: [Double]) -> [Double] {
        let n = x.count, m = r0.count
        var J = [Double](repeating: 0, count: m * n)
        var xp = x
        for k in 0..<n {
            let h = 1e-7 * max(1, abs(x[k]))
            xp[k] = x[k] + h
            let r1 = f(xp)
            xp[k] = x[k]
            guard r1.count == m else { continue }
            for a in 0..<m { J[a * n + k] = (r1[a] - r0[a]) / h }
        }
        return J
    }

    /// Gaussian elimination with partial pivoting.
    private static func solveLinear(_ A: [Double], _ b: [Double], _ m: Int) -> [Double]? {
        var M = A, v = b
        for col in 0..<m {
            var piv = col
            for r in (col + 1)..<max(col + 1, m) where abs(M[r * m + col]) > abs(M[piv * m + col]) { piv = r }
            guard abs(M[piv * m + col]) > 1e-300 else { return nil }
            if piv != col {
                for k in 0..<m { M.swapAt(col * m + k, piv * m + k) }
                v.swapAt(col, piv)
            }
            let d = M[col * m + col]
            for r in (col + 1)..<max(col + 1, m) {
                let f = M[r * m + col] / d
                if f == 0 { continue }
                for k in col..<m { M[r * m + k] -= f * M[col * m + k] }
                v[r] -= f * v[col]
            }
        }
        var x = [Double](repeating: 0, count: m)
        for r in stride(from: m - 1, through: 0, by: -1) {
            var sum = v[r]
            for k in (r + 1)..<max(r + 1, m) { sum -= M[r * m + k] * x[k] }
            x[r] = sum / M[r * m + r]
        }
        return x.allSatisfy(\.isFinite) ? x : nil
    }

    /// Degrees of freedom (variables less the rank of the constraints' Jacobian), repeated constraints, and which
    /// entities can still move (any of their variables in the Jacobian's null space).
    private static func analyseFreedom(_ s: CADSketch, _ layout: Layout, _ x: [Double], _ vars: [String: Double], _ r0: [Double], _ status: inout CADSketchStatus) {
        let n = x.count, m = r0.count
        guard m > 0 else {
            status.dof = n - s.entities.reduce(0) { $0 + ($1.kind == .arc || $1.kind == .circle ? 1 : 0) }
            status.free = Set(s.entities.map(\.id))
            return
        }
        var J = jacobian({ allResiduals(s, layout, $0, vars) }, x, r0)
        // Row echelon form, columns by variable.
        let scale = J.reduce(0) { max($0, abs($1)) }
        let tol = max(1e-9, scale * 1e-8)
        var pivots: [(row: Int, col: Int)] = []
        var row = 0
        for col in 0..<n where row < m {
            var piv = row
            for r in row..<m where abs(J[r * n + col]) > abs(J[piv * n + col]) { piv = r }
            guard abs(J[piv * n + col]) > tol else { continue }
            if piv != row { for k in 0..<n { J.swapAt(row * n + k, piv * n + k) } }
            let d = J[row * n + col]
            for k in 0..<n { J[row * n + k] /= d }
            for r in 0..<m where r != row {
                let f = J[r * n + col]
                if f == 0 { continue }
                for k in 0..<n { J[r * n + k] -= f * J[row * n + k] }
            }
            pivots.append((row, col))
            row += 1
        }
        let rank = pivots.count
        status.dof = n - rank
        status.redundant = status.conflicting ? 0 : m - rank
        let pivotCols = Set(pivots.map(\.col))
        var moving = Set<Int>()
        for f in 0..<n where !pivotCols.contains(f) {
            moving.insert(f)
            for p in pivots where abs(J[p.row * n + f]) > 1e-7 { moving.insert(p.col) }
        }
        for (i, e) in s.entities.enumerated() {
            let o = layout.offsets[i]
            if (o..<(o + e.points.count * 2)).contains(where: moving.contains) { status.free.insert(e.id) }
        }
    }

    // MARK: Measuring (a new dimension starts at what's there)

    static func measure(_ kind: CADConstraint.Kind, refs: [CADSketchRef], in s: CADSketch) -> Double? {
        let g = Reader(sketch: s, layout: Layout(s), x: variables(s))
        func pt(_ k: Int) -> SIMD2<Double>? { refs.indices.contains(k) ? g.point(refs[k]) : nil }
        func seg(_ k: Int) -> (SIMD2<Double>, SIMD2<Double>)? { if refs.indices.contains(k), case .segment(let a, let b)? = g.edge(refs[k]) { return (a, b) }; return nil }
        func circ(_ k: Int) -> Double? { if refs.indices.contains(k), case .circle(_, let r)? = g.edge(refs[k]) { return r }; return nil }
        switch kind {
        case .distanceX, .distanceY:
            let h = kind == .distanceX
            if let a = pt(0), let b = pt(1) { return h ? b.x - a.x : b.y - a.y }
            if let (a, b) = seg(0) { return h ? b.x - a.x : b.y - a.y }
            if let a = pt(0) { return h ? a.x : a.y }
        case .distance:
            if let a = pt(0), let b = pt(1) { return simd_distance(a, b) }
            if let a = pt(0), let (p, q) = seg(1) { return abs(cross(unit(q - p), a - p)) }
            if let (a, b) = seg(0) { return simd_distance(a, b) }
        case .radius: return circ(0)
        case .diameter: return circ(0).map { $0 * 2 }
        case .angle:
            if let (a, b) = seg(0), let (p, q) = seg(1) {
                let u = unit(b - a), w = unit(q - p)
                return atan2(cross(u, w), simd_dot(u, w)) * 180 / .pi
            }
            if let (a, b) = seg(0) { return atan2(b.y - a.y, b.x - a.x) * 180 / .pi }
        default: break
        }
        return nil
    }

    nonisolated static func format(_ v: Double) -> String {
        let r = (v * 1000).rounded() / 1000
        return abs(r - r.rounded()) < 1e-9 ? String(Int(r.rounded())) : String(format: "%g", r)
    }
}
