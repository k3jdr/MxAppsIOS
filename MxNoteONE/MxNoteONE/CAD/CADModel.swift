//
//  CADModel.swift
//  MxNoteONE
//
//  A 3D model: named parameters and a history of features — primitives, sketches extruded or revolved, imported
//  meshes, booleans, patterns and mirrors — rebuilt in order by the geometry kernel (MXSolid). Any number can be an
//  expression of the parameters ("width / 2 + 3"), so changing a parameter changes the part. Units are millimetres.
//

import Foundation
import simd

/// A 3D model on a page.
struct CADModel: Codable, Hashable {
    var name = "Part"
    var parameters: [CADParameter] = []
    var features: [CADFeature] = []
    /// Segments round a full circle for curved surfaces.
    var smoothness = 48
    /// How the page shows it.
    var camera: CADCamera?
    var display: CADDisplay?
    var nextSerial = 1

    /// A new feature with the next serial (its faces are numbered from it).
    mutating func make(_ kind: CADFeature.Kind, name: String? = nil) -> CADFeature {
        var f = CADFeature(kind: kind, name: name ?? uniqueName(kind.title))
        f.serial = nextSerial
        nextSerial += 1
        for field in CADFeature.fields(kind) { f.values[field.key] = field.value }
        return f
    }

    /// "Box", "Box 2", "Box 3"…
    func uniqueName(_ base: String) -> String {
        let names = Set(features.map(\.name))
        if !names.contains(base) { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    func feature(_ id: UUID) -> CADFeature? { features.first { $0.id == id } }

    /// The features a feature is built from (the bodies a boolean, pattern or mirror uses up).
    func consumed() -> Set<UUID> { Set(features.flatMap { $0.inputs ?? [] }) }

    /// A sample: a mounting bracket (a plate with rounded edges and two holes, an upright and a gusset).
    static var bracket: CADModel {
        var m = CADModel(name: "Bracket")
        m.parameters = [CADParameter(name: "width", expression: "80"), CADParameter(name: "thickness", expression: "8"),
                        CADParameter(name: "hole", expression: "8")]
        var plate = m.make(.box, name: "Plate")
        plate.values = ["width": "width", "depth": "40", "height": "thickness", "radius": "2"]
        var upright = m.make(.box, name: "Upright")
        upright.values = ["width": "width", "depth": "thickness", "height": "40", "radius": "2"]
        upright.placement.y = "20 - thickness / 2"
        var holeA = m.make(.cylinder, name: "Hole A")
        holeA.values = ["radius": "hole / 2", "height": "thickness + 2"]
        holeA.placement = CADPlacement(x: "-width / 3", y: "-5", z: "-1")
        var holeB = holeA
        holeB.id = UUID()
        holeB.name = "Hole B"
        holeB.serial = m.nextSerial
        m.nextSerial += 1
        holeB.placement.x = "width / 3"
        m.features = [plate, upright, holeA, holeB]
        var join = m.make(.union, name: "Join")
        join.inputs = [plate.id, upright.id]
        var cut = m.make(.subtract, name: "Holes")
        cut.inputs = [join.id, holeA.id, holeB.id]
        m.features += [join, cut]
        m.features[m.features.count - 1].color = CADColor.palette[1]
        return m
    }

    /// A first model: a box.
    static var starter: CADModel {
        var m = CADModel(name: "Part")
        let box = m.make(.box)
        m.features = [box]
        return m
    }
}

struct CADParameter: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var expression: String
}

struct CADColor: Codable, Hashable {
    var r: Double, g: Double, b: Double
    static let palette: [CADColor] = [
        CADColor(r: 0.62, g: 0.68, b: 0.76), CADColor(r: 0.36, g: 0.55, b: 0.80), CADColor(r: 0.85, g: 0.55, b: 0.30),
        CADColor(r: 0.40, g: 0.70, b: 0.45), CADColor(r: 0.80, g: 0.35, b: 0.40), CADColor(r: 0.65, g: 0.50, b: 0.80),
        CADColor(r: 0.85, g: 0.78, b: 0.40), CADColor(r: 0.30, g: 0.30, b: 0.33),
    ]
}

/// Where a feature sits: a move, then turns about X, Y and Z (degrees) — each an expression.
struct CADPlacement: Codable, Hashable {
    var x = "0", y = "0", z = "0"
    var rx = "0", ry = "0", rz = "0"
}

/// The page's camera: round a target, at a distance, turned and tilted (degrees).
struct CADCamera: Codable, Hashable {
    var target = SIMD3<Double>(0, 0, 0)
    var distance = 200.0
    var yaw = -55.0
    var pitch = 28.0
    var perspective = true
}

enum CADDisplay: String, Codable, CaseIterable {
    case shadedEdges = "Shaded with Edges", shaded = "Shaded", hiddenLine = "Hidden Line"
}

struct CADFeature: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case box, cylinder, cone, sphere, torus, wedge, prism, extrude, revolve, mesh, union, subtract, intersect
        case linearPattern, circularPattern, mirror

        var title: String {
            switch self {
            case .box: "Box"
            case .cylinder: "Cylinder"
            case .cone: "Cone"
            case .sphere: "Sphere"
            case .torus: "Torus"
            case .wedge: "Wedge"
            case .prism: "Prism"
            case .extrude: "Extrude"
            case .revolve: "Revolve"
            case .mesh: "Mesh"
            case .union: "Union"
            case .subtract: "Subtract"
            case .intersect: "Intersect"
            case .linearPattern: "Linear Pattern"
            case .circularPattern: "Circular Pattern"
            case .mirror: "Mirror"
            }
        }
        var symbol: String {
            switch self {
            case .box: "cube"
            case .cylinder: "cylinder"
            case .cone: "cone"
            case .sphere: "circle.circle"
            case .torus: "torus"
            case .wedge: "triangle"
            case .prism: "hexagon"
            case .extrude: "square.3.layers.3d.top.filled"
            case .revolve: "arrow.trianglehead.2.clockwise.rotate.90"
            case .mesh: "cube.transparent"
            case .union: "square.on.square"
            case .subtract: "minus.square"
            case .intersect: "square.on.square.intersection.dashed"
            case .linearPattern: "square.grid.3x1.below.line.grid.1x2"
            case .circularPattern: "circle.dotted"
            case .mirror: "arrow.left.and.right.righttriangle.left.righttriangle.right"
            }
        }
        var isBoolean: Bool { self == .union || self == .subtract || self == .intersect }
        var usesInput: Bool { isBoolean || self == .linearPattern || self == .circularPattern || self == .mirror }
        var usesSketch: Bool { self == .extrude || self == .revolve }
        var isPlaced: Bool { !isBoolean && self != .linearPattern && self != .circularPattern && self != .mirror }
    }

    var id = UUID()
    var kind: Kind
    var name: String
    /// Each dimension as an expression, by key (see `fields`).
    var values: [String: String] = [:]
    var placement = CADPlacement()
    var sketch: CADSketch?
    /// The bodies it uses (a boolean: the first is cut or joined by the rest; a pattern or mirror: the body).
    var inputs: [UUID]?
    var color: CADColor?
    var hidden: Bool?
    /// An imported mesh: triangles, nine float32s each.
    var meshData: Data?
    /// Its faces are numbered from this (each feature's are its own).
    var serial = 0

    /// A feature's dimensions: key, label, default.
    static func fields(_ kind: Kind) -> [(key: String, label: String, value: String)] {
        switch kind {
        case .box: [("width", "Width", "40"), ("depth", "Depth", "30"), ("height", "Height", "20"), ("radius", "Edge radius", "0")]
        case .cylinder: [("radius", "Radius", "10"), ("height", "Height", "30")]
        case .cone: [("bottom", "Bottom radius", "15"), ("top", "Top radius", "0"), ("height", "Height", "30")]
        case .sphere: [("radius", "Radius", "15")]
        case .torus: [("major", "Ring radius", "20"), ("minor", "Tube radius", "5")]
        case .wedge: [("width", "Width", "40"), ("depth", "Depth", "20"), ("height", "Height", "20")]
        case .prism: [("sides", "Sides", "6"), ("radius", "Radius", "15"), ("height", "Height", "20")]
        case .extrude: [("distance", "Distance", "20")]
        case .revolve: [("angle", "Angle", "360")]
        case .linearPattern: [("count", "Count", "3"), ("dx", "Step X", "30"), ("dy", "Step Y", "0"), ("dz", "Step Z", "0")]
        case .circularPattern: [("count", "Count", "6"), ("angle", "Angle", "360")]
        case .mirror: [("plane", "Plane (YZ, XZ, XY)", "YZ")]
        case .mesh, .union, .subtract, .intersect: []
        }
    }
}

// MARK: - Sketches

/// A 2D sketch on a plane, its closed outlines extruded or revolved (an outline inside another is a hole).
struct CADSketch: Codable, Hashable {
    enum Plane: String, Codable, CaseIterable {
        case xy = "XY", xz = "XZ", yz = "YZ"
        var title: String {
            switch self {
            case .xy: "Top (XY)"
            case .xz: "Front (XZ)"
            case .yz: "Right (YZ)"
            }
        }
        /// The plane's across, up and out directions in the model.
        var axes: (u: SIMD3<Double>, v: SIMD3<Double>, n: SIMD3<Double>) {
            switch self {
            case .xy: (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1))
            case .xz: (SIMD3(1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, -1, 0))
            case .yz: (SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(1, 0, 0))
            }
        }
    }
    var plane: Plane = .xy
    /// How far out along the plane's normal.
    var offset = "0"
    var entities: [CADSketchEntity] = []
}

struct CADSketchEntity: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case line, arc, circle, rectangle, polygon
        var title: String { rawValue.capitalized }
    }
    var id = UUID()
    var kind: Kind
    /// line: start, end · arc: start, end, a point on it · circle: centre, a point on it · rectangle: two corners ·
    /// polygon: centre, a corner.
    var points: [SIMD2<Double>]
    var sides: Int?

    var radius: Double { points.count >= 2 ? simd_distance(points[0], points[1]) : 0 }
}

extension CADSketch {
    /// One closed outline: its points and each edge's group (an arc's edges share one, and are smooth).
    struct Loop {
        var points: [SIMD2<Double>]
        var groups: [Int32]
        var smooth: [UInt8]
        var area: Double {
            var a = 0.0
            for i in points.indices { let p = points[i], q = points[(i + 1) % points.count]; a += p.x * q.y - q.x * p.y }
            return a / 2
        }
        func contains(_ q: SIMD2<Double>) -> Bool {
            var inside = false
            var j = points.count - 1
            for i in points.indices {
                let a = points[i], b = points[j]
                if (a.y > q.y) != (b.y > q.y), q.x < (b.x - a.x) * (q.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
                j = i
            }
            return inside
        }
    }

    /// The points along an arc through three points (start, end, a point between), and whether it is one.
    static func arcPoints(_ a: SIMD2<Double>, _ b: SIMD2<Double>, through m: SIMD2<Double>, segments: Int) -> [SIMD2<Double>] {
        let d = 2 * (a.x * (m.y - b.y) + m.x * (b.y - a.y) + b.x * (a.y - m.y))
        guard abs(d) > 1e-12 else { return [a, b] }
        let a2 = simd_length_squared(a), m2 = simd_length_squared(m), b2 = simd_length_squared(b)
        let c = SIMD2((a2 * (m.y - b.y) + m2 * (b.y - a.y) + b2 * (a.y - m.y)) / d,
                      (a2 * (b.x - m.x) + m2 * (a.x - b.x) + b2 * (m.x - a.x)) / d)
        let r = simd_distance(a, c)
        func angle(_ p: SIMD2<Double>) -> Double { atan2(p.y - c.y, p.x - c.x) }
        let start = angle(a)
        var end = angle(b), mid = angle(m)
        // Go round the way that passes the middle point.
        func norm(_ x: Double) -> Double { var y = x; while y < start { y += 2 * .pi }; while y >= start + 2 * .pi { y -= 2 * .pi }; return y }
        end = norm(end); mid = norm(mid)
        let sweep = mid < end ? end - start : end - start - 2 * .pi
        let n = max(2, Int((Double(segments) * abs(sweep) / (2 * .pi)).rounded(.up)))
        return (0...n).map { k in
            let t = start + sweep * Double(k) / Double(n)
            return k == n ? b : (k == 0 ? a : c + r * SIMD2(cos(t), sin(t)))
        }
    }

    /// The sketch's closed outlines: circles, rectangles and polygons, and lines and arcs joined end to end.
    func loops(segments: Int) -> [Loop] {
        var loops: [Loop] = []
        var group: Int32 = 0
        var chains: [(points: [SIMD2<Double>], smooth: Bool)] = []
        for e in entities {
            switch e.kind {
            case .circle:
                guard e.points.count >= 2, e.radius > 1e-9 else { continue }
                let n = max(12, segments)
                let pts = (0..<n).map { k in e.points[0] + e.radius * SIMD2(cos(2 * .pi * Double(k) / Double(n)), sin(2 * .pi * Double(k) / Double(n))) }
                loops.append(Loop(points: pts, groups: Array(repeating: group, count: n), smooth: Array(repeating: 1, count: n)))
                group += 1
            case .rectangle:
                guard e.points.count >= 2 else { continue }
                let a = e.points[0], b = e.points[1]
                guard abs(a.x - b.x) > 1e-9, abs(a.y - b.y) > 1e-9 else { continue }
                loops.append(Loop(points: [a, SIMD2(b.x, a.y), b, SIMD2(a.x, b.y)], groups: (0..<4).map { group + Int32($0) }, smooth: [0, 0, 0, 0]))
                group += 4
            case .polygon:
                guard e.points.count >= 2, e.radius > 1e-9 else { continue }
                let n = max(3, e.sides ?? 6)
                let start = atan2(e.points[1].y - e.points[0].y, e.points[1].x - e.points[0].x)
                let pts = (0..<n).map { k in e.points[0] + e.radius * SIMD2(cos(start + 2 * .pi * Double(k) / Double(n)), sin(start + 2 * .pi * Double(k) / Double(n))) }
                loops.append(Loop(points: pts, groups: (0..<n).map { group + Int32($0) }, smooth: Array(repeating: 0, count: n)))
                group += Int32(n)
            case .line:
                guard e.points.count >= 2 else { continue }
                chains.append(([e.points[0], e.points[1]], false))
            case .arc:
                guard e.points.count >= 3 else { continue }
                chains.append((Self.arcPoints(e.points[0], e.points[1], through: e.points[2], segments: segments), true))
            }
        }
        // Lines and arcs end to end: follow from piece to piece until back at the start.
        let tolerance = 1e-4
        var used = Array(repeating: false, count: chains.count)
        for start in chains.indices where !used[start] {
            used[start] = true
            var pts = chains[start].points
            var groups = Array(repeating: group, count: pts.count - 1)
            var smooth = Array(repeating: UInt8(chains[start].smooth ? 1 : 0), count: pts.count - 1)
            group += 1
            var closed = false
            while !closed {
                if simd_distance(pts[0], pts[pts.count - 1]) < tolerance, pts.count > 2 { closed = true; break }
                guard let last = pts.last,
                      let next = chains.indices.first(where: { !used[$0] && (simd_distance(chains[$0].points.first!, last) < tolerance || simd_distance(chains[$0].points.last!, last) < tolerance) })
                else { break }
                used[next] = true
                var piece = chains[next].points
                if simd_distance(piece.first!, last) >= tolerance { piece.reverse() }
                pts += piece.dropFirst()
                groups += Array(repeating: group, count: piece.count - 1)
                smooth += Array(repeating: UInt8(chains[next].smooth ? 1 : 0), count: piece.count - 1)
                group += 1
            }
            guard closed else { continue }
            pts.removeLast()   // the end is the start
            if pts.count >= 3 { loops.append(Loop(points: pts, groups: groups, smooth: smooth)) }
        }
        return loops
    }

    /// The outlines nested: how many others each is inside (even: material, odd: a hole).
    static func depths(_ loops: [Loop]) -> [Int] {
        loops.indices.map { i in
            loops.indices.filter { j in j != i && abs(loops[j].area) > abs(loops[i].area) && loops[j].contains(loops[i].points[0]) }.count
        }
    }
}

// MARK: - Expressions

enum CADExpressionError: LocalizedError {
    case syntax(String), unknown(String)
    var errorDescription: String? {
        switch self {
        case .syntax(let s): "Can't read “\(s)”"
        case .unknown(let name): "No parameter called “\(name)”"
        }
    }
}

/// Arithmetic on numbers and parameters: + − × ÷ ^, brackets, sin cos tan (degrees), sqrt abs min max, pi,
/// and units after a number (mm, cm, m, in).
enum CADExpression {
    static func evaluate(_ text: String, _ vars: [String: Double]) throws -> Double {
        var p = Parser(chars: Array(text), vars: vars)
        let v = try p.expression()
        p.skipSpace()
        guard p.i == p.chars.count else { throw CADExpressionError.syntax(text) }
        return v
    }

    private struct Parser {
        let chars: [Character]
        let vars: [String: Double]
        var i = 0

        mutating func skipSpace() { while i < chars.count, chars[i].isWhitespace { i += 1 } }
        mutating func peek() -> Character? { skipSpace(); return i < chars.count ? chars[i] : nil }

        mutating func expression() throws -> Double {
            var v = try term()
            while let c = peek(), c == "+" || c == "-" || c == "−" {
                i += 1
                let t = try term()
                v = c == "+" ? v + t : v - t
            }
            return v
        }

        mutating func term() throws -> Double {
            var v = try power()
            while let c = peek(), c == "*" || c == "/" || c == "×" || c == "÷" {
                i += 1
                let t = try power()
                v = (c == "*" || c == "×") ? v * t : v / t
            }
            return v
        }

        mutating func power() throws -> Double {
            let base = try unary()
            if peek() == "^" { i += 1; return pow(base, try power()) }
            return base
        }

        mutating func unary() throws -> Double {
            if let c = peek(), c == "-" || c == "−" { i += 1; return -(try unary()) }
            if peek() == "+" { i += 1; return try unary() }
            return try primary()
        }

        mutating func primary() throws -> Double {
            guard let c = peek() else { throw CADExpressionError.syntax(String(chars)) }
            if c == "(" {
                i += 1
                let v = try expression()
                guard peek() == ")" else { throw CADExpressionError.syntax(String(chars)) }
                i += 1
                return v
            }
            if c.isNumber || c == "." {
                var s = ""
                while i < chars.count, chars[i].isNumber || chars[i] == "." || ((chars[i] == "e" || chars[i] == "E") && i + 1 < chars.count && chars[i + 1].isNumber) {
                    s.append(chars[i]); i += 1
                }
                guard let v = Double(s) else { throw CADExpressionError.syntax(s) }
                // A unit after the number.
                let rest = String(chars[i...]).lowercased()
                for (unit, scale) in [("mm", 1.0), ("cm", 10.0), ("in", 25.4), ("m", 1000.0)] where rest.hasPrefix(unit) {
                    let after = i + unit.count < chars.count ? chars[i + unit.count] : " "
                    if !after.isLetter && !after.isNumber && after != "_" { i += unit.count; return v * scale }
                }
                return v
            }
            if c.isLetter || c == "_" {
                var name = ""
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" { name.append(chars[i]); i += 1 }
                if peek() == "(" {
                    i += 1
                    var args = [try expression()]
                    while peek() == "," { i += 1; args.append(try expression()) }
                    guard peek() == ")" else { throw CADExpressionError.syntax(String(chars)) }
                    i += 1
                    let rad = args[0] * .pi / 180
                    switch name.lowercased() {
                    case "sin": return sin(rad)
                    case "cos": return cos(rad)
                    case "tan": return tan(rad)
                    case "sqrt": return sqrt(args[0])
                    case "abs": return abs(args[0])
                    case "min": return args.min()!
                    case "max": return args.max()!
                    case "round": return args[0].rounded()
                    default: throw CADExpressionError.unknown(name)
                    }
                }
                if name.lowercased() == "pi" { return .pi }
                guard let v = vars[name] else { throw CADExpressionError.unknown(name) }
                return v
            }
            throw CADExpressionError.syntax(String(chars))
        }
    }
}

// MARK: - Building

/// A body to show: a feature's solid as triangles for the viewport.
struct CADBody {
    let id: UUID
    let name: String
    let color: CADColor
    let solid: MXSolid
    /// Each vertex: position (3 floats), normal (3 floats), face (uint32) — 28 bytes.
    let vertices: Data
    let positions: [SIMD3<Float>]
    let faces: [UInt32]
    let bounds: (min: SIMD3<Double>, max: SIMD3<Double>)
}

/// What a model builds into.
struct CADBuild {
    var bodies: [CADBody] = []
    var solids: [UUID: MXSolid] = [:]
    var errors: [UUID: String] = [:]
    var parameterValues: [String: Double] = [:]
    var parameterErrors: [UUID: String] = [:]

    var bounds: (min: SIMD3<Double>, max: SIMD3<Double>)? {
        guard let first = bodies.first else { return nil }
        return bodies.dropFirst().reduce(first.bounds) { (simd_min($0.min, $1.bounds.min), simd_max($0.max, $1.bounds.max)) }
    }
}

/// Rebuilds models feature by feature, keeping what didn't change.
final class CADBuilder {
    private var cache: [String: MXSolid] = [:]
    private var meshes: [ObjectIdentifier: (Data, [SIMD3<Float>], [UInt32])] = [:]

    static func matrix(translate t: SIMD3<Double>, rotate r: SIMD3<Double>) -> simd_double4x4 {
        let (x, y, z) = (r.x * .pi / 180, r.y * .pi / 180, r.z * .pi / 180)
        let rx = simd_double4x4(rows: [SIMD4(1, 0, 0, 0), SIMD4(0, cos(x), -sin(x), 0), SIMD4(0, sin(x), cos(x), 0), SIMD4(0, 0, 0, 1)])
        let ry = simd_double4x4(rows: [SIMD4(cos(y), 0, sin(y), 0), SIMD4(0, 1, 0, 0), SIMD4(-sin(y), 0, cos(y), 0), SIMD4(0, 0, 0, 1)])
        let rz = simd_double4x4(rows: [SIMD4(cos(z), -sin(z), 0, 0), SIMD4(sin(z), cos(z), 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1)])
        var m = rz * ry * rx
        m.columns.3 = SIMD4(t.x, t.y, t.z, 1)
        return m
    }

    static func data(_ m: simd_double4x4) -> Data {
        var values: [Double] = []
        for c in 0..<4 { for r in 0..<4 { values.append(m[c][r]) } }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// The sketch plane's frame: profile coordinates into the model.
    static func frame(_ sketch: CADSketch, offset: Double) -> simd_double4x4 {
        let a = sketch.plane.axes
        return simd_double4x4(columns: (SIMD4(a.u, 0), SIMD4(a.v, 0), SIMD4(a.n, 0), SIMD4(a.n * offset, 1)))
    }

    func build(_ model: CADModel) -> CADBuild {
        var result = CADBuild()
        // Parameters, in order (each may use the ones before it).
        var vars: [String: Double] = [:]
        for p in model.parameters {
            do { vars[p.name] = try CADExpression.evaluate(p.expression, vars) } catch { result.parameterErrors[p.id] = error.localizedDescription }
        }
        result.parameterValues = vars
        var keys: [UUID: String] = [:]
        let segments = max(8, model.smoothness)
        for f in model.features {
            do {
                func value(_ key: String) throws -> Double {
                    let text = f.values[key] ?? CADFeature.fields(f.kind).first { $0.key == key }?.value ?? "0"
                    return try CADExpression.evaluate(text, vars)
                }
                let face = UInt32(f.serial & 0xFFFF) << 16
                let numbers = try CADFeature.fields(f.kind).filter { $0.key != "plane" }.map { try value($0.key) }
                let placed = f.kind.isPlaced
                    ? try [f.placement.x, f.placement.y, f.placement.z, f.placement.rx, f.placement.ry, f.placement.rz].map { try CADExpression.evaluate($0, vars) }
                    : []
                let inputKeys = (f.inputs ?? []).map { keys[$0] ?? "?" }
                let sketchOffset = try f.sketch.map { try CADExpression.evaluate($0.offset, vars) } ?? 0
                let key = "\(f.kind.rawValue)|\(f.serial)|\(numbers)|\(placed)|\(f.values["plane"] ?? "")|\(f.sketch?.hashValue ?? 0)|\(sketchOffset)|\(f.meshData?.hashValue ?? 0)|\(inputKeys)|\(segments)"
                keys[f.id] = key
                if let cached = cache[key] {
                    result.solids[f.id] = cached
                    continue
                }
                var solid: MXSolid
                switch f.kind {
                case .box:
                    solid = .box(width: try value("width"), depth: try value("depth"), height: try value("height"), radius: try value("radius"), segments: segments, face: face)
                case .cylinder:
                    let r = try value("radius")
                    solid = .cone(bottom: r, top: r, height: try value("height"), segments: segments, face: face)
                case .cone:
                    solid = .cone(bottom: try value("bottom"), top: try value("top"), height: try value("height"), segments: segments, face: face)
                case .sphere:
                    solid = .sphere(radius: try value("radius"), segments: segments, face: face)
                case .torus:
                    solid = .torus(major: try value("major"), minor: try value("minor"), segments: segments, face: face)
                case .wedge:
                    // A ramp: a right triangle (in XZ) through the depth.
                    let w = try value("width"), d = try value("depth"), h = try value("height")
                    let profile = CADSketch.Loop(points: [SIMD2(-w / 2, 0), SIMD2(w / 2, 0), SIMD2(-w / 2, h)], groups: [0, 1, 2], smooth: [0, 0, 0])
                    solid = Self.extrude(profile, height: d, face: face)
                        .transformed(Self.data(simd_double4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, -1, 0, 0), SIMD4(0, d / 2, 0, 1)))))
                case .prism:
                    let n = max(3, Int(try value("sides"))), r = try value("radius")
                    let pts = (0..<n).map { k in r * SIMD2(cos(2 * .pi * Double(k) / Double(n) + .pi / 2), sin(2 * .pi * Double(k) / Double(n) + .pi / 2)) }
                    solid = Self.extrude(CADSketch.Loop(points: pts, groups: (0..<n).map { Int32($0) }, smooth: Array(repeating: 0, count: n)), height: try value("height"), face: face)
                case .extrude, .revolve:
                    guard let sketch = f.sketch else { throw CADBuildError.noSketch }
                    let loops = sketch.loops(segments: segments)
                    guard !loops.isEmpty else { throw CADBuildError.noProfile }
                    let depths = CADSketch.depths(loops)
                    var body = MXSolid.empty()
                    // Outlines from the outside in: material joins, holes cut.
                    for (loop, depth) in zip(loops, depths).sorted(by: { $0.1 < $1.1 }) {
                        let piece = f.kind == .extrude
                            ? Self.extrude(loop, height: try value("distance"), face: face)
                            : Self.revolve(loop, degrees: try value("angle"), segments: segments, face: face)
                        body = depth % 2 == 0 ? body.union(piece) : body.subtracting(piece)
                    }
                    solid = body.transformed(Self.data(Self.frame(sketch, offset: sketchOffset)))
                case .mesh:
                    guard let data = f.meshData, !data.isEmpty else { throw CADBuildError.noMesh }
                    solid = .triangles(data, face: face)
                case .union, .subtract, .intersect:
                    let ins = try (f.inputs ?? []).map { id -> MXSolid in
                        guard let s = result.solids[id] else { throw CADBuildError.missingInput }
                        return s
                    }
                    guard let target = ins.first, ins.count >= 2 else { throw CADBuildError.needsTwo }
                    solid = ins.dropFirst().reduce(target) { acc, tool in
                        f.kind == .union ? acc.union(tool) : f.kind == .subtract ? acc.subtracting(tool) : acc.intersecting(tool)
                    }
                case .linearPattern, .circularPattern, .mirror:
                    guard let id = f.inputs?.first, let source = result.solids[id] else { throw CADBuildError.missingInput }
                    if f.kind == .mirror {
                        let plane = (f.values["plane"] ?? "YZ").uppercased()
                        let s = SIMD3<Double>(plane == "YZ" ? -1 : 1, plane == "XZ" ? -1 : 1, plane == "XY" ? -1 : 1)
                        let m = simd_double4x4(diagonal: SIMD4(s, 1))
                        solid = source.union(source.transformed(Self.data(m)))
                    } else {
                        let count = max(1, min(200, Int(try value("count"))))
                        solid = source
                        for k in 1..<max(2, count) where k < count {
                            let m: simd_double4x4
                            if f.kind == .linearPattern {
                                m = Self.matrix(translate: SIMD3(try value("dx"), try value("dy"), try value("dz")) * Double(k), rotate: .zero)
                            } else {
                                let angle = try value("angle")
                                let step = abs(abs(angle) - 360) < 1e-9 ? angle / Double(count) : angle / Double(max(1, count - 1))
                                m = Self.matrix(translate: .zero, rotate: SIMD3(0, 0, step * Double(k)))
                            }
                            solid = solid.union(source.transformed(Self.data(m)))
                        }
                    }
                }
                if placed.count == 6, placed.contains(where: { $0 != 0 }) {
                    solid = solid.transformed(Self.data(Self.matrix(translate: SIMD3(placed[0], placed[1], placed[2]), rotate: SIMD3(placed[3], placed[4], placed[5]))))
                }
                cache[key] = solid
                result.solids[f.id] = solid
            } catch {
                result.errors[f.id] = error.localizedDescription
            }
        }
        // Don't keep solids no longer used.
        let live = Set(keys.values)
        cache = cache.filter { live.contains($0.key) }
        // The bodies: what isn't used up by a later feature, and isn't hidden.
        let consumed = model.consumed()
        for f in model.features where !consumed.contains(f.id) && f.hidden != true {
            guard let solid = result.solids[f.id], solid.polygonCount > 0 else { continue }
            let (vertices, positions, faces) = mesh(solid)
            let b = solid.bounds.withUnsafeBytes { Array($0.bindMemory(to: Double.self)) }
            result.bodies.append(CADBody(id: f.id, name: f.name, color: f.color ?? CADColor.palette[0], solid: solid, vertices: vertices,
                                         positions: positions, faces: faces, bounds: (SIMD3(b[0], b[1], b[2]), SIMD3(b[3], b[4], b[5]))))
        }
        return result
    }

    /// A solid's triangles, interleaved for Metal (kept while the solid is).
    private func mesh(_ solid: MXSolid) -> (Data, [SIMD3<Float>], [UInt32]) {
        if let m = meshes[ObjectIdentifier(solid)] { return m }
        let p = solid.meshPositions.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let n = solid.meshNormals.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let f = solid.meshFaces.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
        var data = Data(capacity: f.count * 28)
        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity(f.count)
        for i in f.indices {
            var v: (Float, Float, Float, Float, Float, Float, UInt32) = (p[3 * i], p[3 * i + 1], p[3 * i + 2], n[3 * i], n[3 * i + 1], n[3 * i + 2], f[i])
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0.prefix(28)) }
            positions.append(SIMD3(p[3 * i], p[3 * i + 1], p[3 * i + 2]))
        }
        let m = (data, positions, f)
        if meshes.count > 64 { meshes.removeAll() }
        meshes[ObjectIdentifier(solid)] = m
        return m
    }

    static func extrude(_ loop: CADSketch.Loop, height: Double, face: UInt32) -> MXSolid {
        let (points, groups, smooth) = profileData(loop)
        return .extrude(points: points, groups: groups, smooth: smooth, height: height, face: face)
    }

    static func revolve(_ loop: CADSketch.Loop, degrees: Double, segments: Int, face: UInt32) -> MXSolid {
        let (points, groups, smooth) = profileData(loop)
        return .revolve(points: points, groups: groups, smooth: smooth, degrees: degrees, segments: segments, face: face)
    }

    private static func profileData(_ loop: CADSketch.Loop) -> (Data, Data, Data) {
        let xy = loop.points.flatMap { [$0.x, $0.y] }
        return (xy.withUnsafeBufferPointer { Data(buffer: $0) }, loop.groups.withUnsafeBufferPointer { Data(buffer: $0) }, Data(loop.smooth))
    }
}

enum CADBuildError: LocalizedError {
    case noSketch, noProfile, noMesh, missingInput, needsTwo
    var errorDescription: String? {
        switch self {
        case .noSketch: "It has no sketch."
        case .noProfile: "Its sketch has no closed outline (lines and arcs must meet end to end)."
        case .noMesh: "The mesh is empty."
        case .missingInput: "A body it uses couldn't be made."
        case .needsTwo: "It needs two bodies or more."
        }
    }
}

// MARK: - STL and OBJ

enum CADExchange {
    /// Binary STL of the bodies.
    static func stl(_ bodies: [CADBody], name: String) -> Data {
        var data = Data(count: 80)
        let header = Array("MxNoteONE \(name)".utf8.prefix(80))
        data.replaceSubrange(0..<header.count, with: header)
        let triangles = bodies.reduce(0) { $0 + $1.positions.count / 3 }
        var count = UInt32(triangles)
        data.append(Data(bytes: &count, count: 4))
        for body in bodies {
            let p = body.positions
            for t in stride(from: 0, to: p.count - 2, by: 3) {
                let n = simd_normalize(simd_cross(p[t + 1] - p[t], p[t + 2] - p[t]))
                var floats: [Float] = [n.x.isNaN ? 0 : n.x, n.y.isNaN ? 0 : n.y, n.z.isNaN ? 0 : n.z]
                for k in 0..<3 { floats += [p[t + k].x, p[t + k].y, p[t + k].z] }
                floats.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
                data.append(contentsOf: [0, 0])
            }
        }
        return data
    }

    /// Wavefront OBJ of the bodies, each an object.
    static func obj(_ bodies: [CADBody], name: String) -> String {
        var out = "# MxNoteONE — \(name) (millimetres)\n"
        var base = 1
        for body in bodies {
            out += "o \(body.name.replacingOccurrences(of: " ", with: "_"))\n"
            for p in body.positions { out += "v \(p.x) \(p.y) \(p.z)\n" }
            for t in stride(from: 0, to: body.positions.count - 2, by: 3) { out += "f \(base + t) \(base + t + 1) \(base + t + 2)\n" }
            base += body.positions.count
        }
        return out
    }

    /// Triangles (nine floats each) from an STL (binary or text) or OBJ file.
    static func triangles(from data: Data, ext: String) -> [Float]? {
        if ext.lowercased() == "obj" { return objTriangles(String(decoding: data, as: UTF8.self)) }
        // Binary STL: 80-byte header, a count, 50 bytes a triangle.
        if data.count >= 84 {
            let count = data.subdata(in: 80..<84).withUnsafeBytes { $0.load(as: UInt32.self) }
            if 84 + Int(count) * 50 == data.count {
                var out: [Float] = []
                out.reserveCapacity(Int(count) * 9)
                data.withUnsafeBytes { raw in
                    for t in 0..<Int(count) {
                        for k in 0..<9 { out.append(raw.loadUnaligned(fromByteOffset: 84 + t * 50 + 12 + k * 4, as: Float.self)) }
                    }
                }
                return out
            }
        }
        // Text STL: "vertex x y z" lines.
        let text = String(decoding: data, as: UTF8.self)
        var out: [Float] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.first == "vertex", parts.count >= 4 { out += parts[1...3].compactMap { Float($0) } }
        }
        return out.count >= 9 ? Array(out.prefix(out.count / 9 * 9)) : nil
    }

    private static func objTriangles(_ text: String) -> [Float]? {
        var vs: [SIMD3<Float>] = []
        var out: [Float] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let head = parts.first else { continue }
            if head == "v", parts.count >= 4 {
                vs.append(SIMD3(Float(parts[1]) ?? 0, Float(parts[2]) ?? 0, Float(parts[3]) ?? 0))
            } else if head == "f", parts.count >= 4 {
                let idx = parts.dropFirst().compactMap { Int($0.split(separator: "/").first ?? "") }.map { $0 < 0 ? vs.count + $0 : $0 - 1 }
                guard idx.allSatisfy({ vs.indices.contains($0) }), idx.count >= 3 else { continue }
                for k in 1..<(idx.count - 1) {
                    for i in [idx[0], idx[k], idx[k + 1]] { out += [vs[i].x, vs[i].y, vs[i].z] }
                }
            }
        }
        return out.count >= 9 ? out : nil
    }
}
