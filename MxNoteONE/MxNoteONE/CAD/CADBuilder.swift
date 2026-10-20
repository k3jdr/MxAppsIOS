//
//  CADBuilder.swift
//  MxNoteONE
//
//  Builds a model feature by feature with the geometry kernel, keeping what didn't change: primitives; sketches
//  solved, then padded or pocketed (a length, two lengths, symmetric, through all), revolved or grooved (round
//  either sketch axis), lofted through sections, swept along a path or round a helix; holes (counterbored,
//  countersunk, drill points); fillets and chamfers; booleans; patterns and mirrors of bodies — or, Part Design's
//  way, of a feature (a pocket repeated); imported meshes and shapes. Part Design features add to or cut from the
//  body they're on.
//

import Foundation
import simd

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

/// An edge of a body: the faces either side and its points.
struct CADBodyEdge: Equatable {
    let a: UInt32
    let b: UInt32
    let points: [SIMD3<Double>]
    let closed: Bool

    var ref: CADEdgeRef { CADEdgeRef(a: a, b: b, near: middle) }
    /// The point halfway along it.
    var middle: SIMD3<Double>? {
        guard var prev = points.first else { return nil }
        var left = length / 2
        for q in points.dropFirst() + (closed ? [points[0]] : []) {
            let d = simd_distance(prev, q)
            if d >= left, d > 0 { return prev + (q - prev) * (left / d) }
            left -= d
            prev = q
        }
        return prev
    }
    var length: Double {
        var l = zip(points, points.dropFirst()).reduce(0) { $0 + simd_distance($1.0, $1.1) }
        if closed, let f = points.first, let last = points.last { l += simd_distance(f, last) }
        return l
    }
    var isStraight: Bool {
        guard let f = points.first, let l = points.last, !closed else { return false }
        let d = l - f, L = simd_length(d)
        guard L > 1e-9 else { return false }
        return points.allSatisfy { simd_length(simd_cross(d / L, $0 - f)) < L * 1e-4 + 1e-5 }
    }
}

/// What a model builds into.
struct CADBuild {
    var bodies: [CADBody] = []
    var solids: [UUID: MXSolid] = [:]
    var errors: [UUID: String] = [:]
    /// Built, but not quite as asked (an edge that couldn't be filleted).
    var warnings: [UUID: String] = [:]
    var parameterValues: [String: Double] = [:]
    var parameterErrors: [UUID: String] = [:]
    /// Part Design: what each feature adds or cuts (a pattern of the feature repeats it).
    var tools: [UUID: MXSolid] = [:]
    /// Sketches, solved, and what solving found.
    var sketches: [UUID: CADSketch] = [:]
    var sketchStatus: [UUID: CADSketchStatus] = [:]
    /// Sketch features not yet used, as lines in the model.
    var sketchLines: [UUID: [[SIMD3<Double>]]] = [:]

    var bounds: (min: SIMD3<Double>, max: SIMD3<Double>)? {
        guard let first = bodies.first else { return nil }
        return bodies.dropFirst().reduce(first.bounds) { (simd_min($0.min, $1.bounds.min), simd_max($0.max, $1.bounds.max)) }
    }
}

enum CADBuildError: LocalizedError {
    case noSketch, noProfile, noMesh, missingInput, needsTwo, needsBody, noCircles, noEdges, needsSections, noPath, badSize
    var errorDescription: String? {
        switch self {
        case .noSketch: "It has no sketch."
        case .noProfile: "Its sketch has no closed outline (lines and arcs must meet end to end)."
        case .noMesh: "The mesh is empty."
        case .missingInput: "A body it uses couldn't be made."
        case .needsTwo: "It needs two bodies or more."
        case .needsBody: "It needs a body to cut (sketch on one of its faces)."
        case .noCircles: "Its sketch has no circles (each circle's centre is a hole)."
        case .noEdges: "It has no edges (select edges, then Add Selected Edges)."
        case .needsSections: "A loft needs two sketches or more."
        case .noPath: "Its path sketch has no lines or arcs."
        case .badSize: "A size must be more than 0."
        }
    }
}

/// Rebuilds models feature by feature, keeping what didn't change.
final class CADBuilder {
    private struct Cached {
        let solid: MXSolid
        let tool: MXSolid?
        let warning: String?
    }
    private var cache: [String: Cached] = [:]
    private var meshes: [ObjectIdentifier: (Data, [SIMD3<Float>], [UInt32])] = [:]
    private var sketchCache: [Int: (CADSketch, CADSketchStatus)] = [:]
    private var edgeCache: [ObjectIdentifier: [CADBodyEdge]] = [:]

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
        let a = sketch.axes
        return simd_double4x4(columns: (SIMD4(a.u, 0), SIMD4(a.v, 0), SIMD4(a.n, 0), SIMD4(a.origin + a.n * offset, 1)))
    }

    /// A sketch point in the model.
    static func point(_ q: SIMD2<Double>, _ sketch: CADSketch, offset: Double) -> SIMD3<Double> {
        let a = sketch.axes
        return a.origin + a.u * q.x + a.v * q.y + a.n * offset
    }

    private static func translate(_ t: SIMD3<Double>) -> simd_double4x4 {
        var m = matrix_identity_double4x4
        m.columns.3 = SIMD4(t, 1)
        return m
    }

    /// A sketch with its constraints holding (for the parameters' values).
    func solved(_ sketch: CADSketch, _ vars: [String: Double]) -> (CADSketch, CADSketchStatus) {
        var h = Hasher()
        h.combine(sketch)
        for c in sketch.constraints ?? [] {
            for text in [c.value, c.value2].compactMap({ $0 }) { h.combine((try? CADExpression.evaluate(text, vars)) ?? .nan) }
        }
        let key = h.finalize()
        if let hit = sketchCache[key] { return hit }
        let out = CADSketchSolver.solve(sketch, values: vars)
        if sketchCache.count > 200 { sketchCache.removeAll() }
        sketchCache[key] = out
        return out
    }

    /// A body's edges (worked out once for each solid).
    func edges(_ solid: MXSolid) -> [CADBodyEdge] {
        if let hit = edgeCache[ObjectIdentifier(solid)] { return hit }
        let list = solid.edges.map { e -> CADBodyEdge in
            let d = e.points.withUnsafeBytes { Array($0.bindMemory(to: Double.self)) }
            let pts = stride(from: 0, to: d.count - 2, by: 3).map { SIMD3(d[$0], d[$0 + 1], d[$0 + 2]) }
            return CADBodyEdge(a: e.faceA, b: e.faceB, points: pts, closed: e.closed)
        }
        if edgeCache.count > 64 { edgeCache.removeAll() }
        edgeCache[ObjectIdentifier(solid)] = list
        return list
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
                // Its sketches, solved: its own (or its profile's), and its sections'.
                func sketch(of id: UUID?) throws -> (CADSketch, Double)? {
                    guard let id else { return nil }
                    if let s = result.sketches[id], let sf = model.feature(id), let raw = sf.sketch { return (s, try CADExpression.evaluate(raw.offset, vars)) }
                    guard let sf = model.feature(id), let raw = sf.sketch else { return nil }
                    let (s, status) = solved(raw, vars)
                    result.sketches[id] = s
                    result.sketchStatus[id] = status
                    return (s, try CADExpression.evaluate(raw.offset, vars))
                }
                let own: (CADSketch, Double)? = try f.sketch != nil ? sketch(of: f.id) : sketch(of: f.profile)
                if f.kind == .sketch {
                    if let (s, offset) = own { result.sketchLines[f.id] = s.lines3D(offset: offset) }
                    if let status = result.sketchStatus[f.id], status.conflicting { result.warnings[f.id] = "Its constraints conflict." }
                    continue
                }
                let sections = try (f.sections ?? []).compactMap { try sketch(of: $0) }
                let face = UInt32(f.serial & 0xFFFF) << 16
                let fields = CADFeature.fields(f.kind)
                let numbers = try fields.filter { $0.choices == nil }.map { try value($0.key) }
                let choices = fields.filter { $0.choices != nil }.map { f.choice($0.key) }
                let placed = f.kind.isPlaced
                    ? try [f.placement.x, f.placement.y, f.placement.z, f.placement.rx, f.placement.ry, f.placement.rz].map { try CADExpression.evaluate($0, vars) }
                    : []
                let inputKeys = (f.inputs ?? []).map { keys[$0] ?? "?" }
                let key = "\(f.kind.rawValue)|\(f.serial)|\(numbers)|\(choices)|\(placed)|\(f.operation?.rawValue ?? "")|\(own?.0.hashValue ?? 0)|\(own?.1 ?? 0)|\(sections.map { $0.0.hashValue })|\(sections.map(\.1))|\(f.meshData?.hashValue ?? 0)|\(f.meshFaces?.hashValue ?? 0)|\(f.edges?.hashValue ?? 0)|\(inputKeys)|\(segments)"
                keys[f.id] = key
                if let hit = cache[key] {
                    result.solids[f.id] = hit.solid
                    if let t = hit.tool { result.tools[f.id] = t }
                    if let w = hit.warning { result.warnings[f.id] = w }
                    continue
                }
                let base = try f.base.map { id -> MXSolid in
                    guard let s = result.solids[id] else { throw CADBuildError.missingInput }
                    return s
                }
                var tool: MXSolid?
                var solid: MXSolid
                var warning: String?
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
                case .tube:
                    let outer = try value("outer"), inner = try value("inner"), h = try value("height")
                    guard outer > 0, h > 0, inner < outer else { throw CADBuildError.badSize }
                    solid = .cone(bottom: outer, top: outer, height: h, segments: segments, face: face)
                    if inner > 1e-9 {
                        let hole = MXSolid.cone(bottom: inner, top: inner, height: h + 2, segments: segments, face: face + 3).transformed(Self.data(Self.translate(SIMD3(0, 0, -1))))
                        solid = solid.subtracting(hole)
                    }
                case .ellipsoid:
                    let rx = try value("rx"), ry = try value("ry"), rz = try value("rz")
                    guard rx > 0, ry > 0, rz > 0 else { throw CADBuildError.badSize }
                    solid = MXSolid.sphere(radius: 1, segments: segments, face: face).transformed(Self.data(simd_double4x4(diagonal: SIMD4(rx, ry, rz, 1))))
                case .extrude:
                    guard let (sk, offset) = own else { throw CADBuildError.noSketch }
                    solid = try extrudeTool(f, sk, offset, base: base, segments: segments, face: face, value: value)
                case .revolve:
                    guard let (sk, offset) = own else { throw CADBuildError.noSketch }
                    solid = try revolveTool(f, sk, offset, segments: segments, face: face, value: value)
                case .loft:
                    guard let first = own else { throw CADBuildError.noSketch }
                    solid = try loftTool([first] + sections, ruled: f.choice("ruled") == "Yes", segments: segments, face: face)
                case .pipe:
                    guard let (sk, offset) = own else { throw CADBuildError.noSketch }
                    guard let (path, pathOffset) = sections.first, let chain = path.path(segments: segments) else { throw CADBuildError.noPath }
                    let spine = chain.points.map { Self.point($0, path, offset: pathOffset) }
                    solid = try pipeTool(sk, offset, spine: spine, closed: chain.closed, segments: segments, face: face)
                case .helix:
                    guard let (sk, offset) = own else { throw CADBuildError.noSketch }
                    solid = try helixTool(sk, offset, pitch: try value("pitch"), height: try value("height"), left: f.choice("hand") == "Left-handed", segments: segments, face: face)
                case .hole:
                    guard let (sk, offset) = own else { throw CADBuildError.noSketch }
                    guard let base else { throw CADBuildError.needsBody }
                    let holes = try holeTool(f, sk, offset, base: base, segments: segments, face: face, value: value)
                    tool = holes
                    solid = base.subtracting(holes)
                case .mesh:
                    guard let data = f.meshData, !data.isEmpty else { throw CADBuildError.noMesh }
                    if let faces = f.meshFaces, !faces.isEmpty {
                        solid = .triangles(data, faces: faces, normals: f.meshNormals, face: face)
                    } else {
                        solid = .triangles(data, face: face)
                    }
                case .union, .subtract, .intersect:
                    let ins = try (f.inputs ?? []).map { id -> MXSolid in
                        guard let s = result.solids[id] else { throw CADBuildError.missingInput }
                        return s
                    }
                    guard let target = ins.first, ins.count >= 2 else { throw CADBuildError.needsTwo }
                    solid = ins.dropFirst().reduce(target) { acc, tool in
                        f.kind == .union ? acc.union(tool) : f.kind == .subtract ? acc.subtracting(tool) : acc.intersecting(tool)
                    }
                case .fillet, .chamfer:
                    guard let base else { throw CADBuildError.missingInput }
                    let refs = f.edges ?? []
                    guard !refs.isEmpty else { throw CADBuildError.noEdges }
                    let size = try value(f.kind == .fillet ? "radius" : "size")
                    guard size > 0 else { throw CADBuildError.badSize }
                    var list: [Double] = []
                    for r in refs { list += [Double(r.a), Double(r.b), r.near == nil ? 0 : 1, r.near?.x ?? 0, r.near?.y ?? 0, r.near?.z ?? 0] }
                    var problem: NSString?
                    solid = base.blend(edges: list.withUnsafeBufferPointer { Data(buffer: $0) }, size: size, chamfer: f.kind == .chamfer, segments: segments, face: face, error: &problem)
                    warning = problem as String?
                case .linearPattern, .circularPattern, .mirror:
                    guard let id = f.inputs?.first, let source = result.solids[id] else { throw CADBuildError.missingInput }
                    var transforms: [simd_double4x4] = []
                    if f.kind == .mirror {
                        let plane = f.choice("plane").uppercased()
                        let s = SIMD3<Double>(plane == "YZ" ? -1 : 1, plane == "XZ" ? -1 : 1, plane == "XY" ? -1 : 1)
                        transforms = [simd_double4x4(diagonal: SIMD4(s, 1))]
                    } else {
                        let count = max(1, min(200, Int(try value("count"))))
                        for k in 1..<max(2, count) where k < count {
                            if f.kind == .linearPattern {
                                transforms.append(Self.matrix(translate: SIMD3(try value("dx"), try value("dy"), try value("dz")) * Double(k), rotate: .zero))
                            } else {
                                let angle = try value("angle")
                                let step = abs(abs(angle) - 360) < 1e-9 ? angle / Double(count) : angle / Double(max(1, count - 1))
                                transforms.append(Self.matrix(translate: .zero, rotate: SIMD3(0, 0, step * Double(k))))
                            }
                        }
                    }
                    // A Part Design feature (a pocket, a pad) is repeated on its body; a body is copied.
                    if let sf = model.feature(id), let op = sf.operation ?? (sf.kind == .hole ? .subtract : nil), let t = result.tools[id] {
                        solid = transforms.reduce(source) { Self.combine(op, $0, t.transformed(Self.data($1))) }
                        tool = transforms.reduce(t) { $0.union(t.transformed(Self.data($1))) }
                    } else {
                        solid = transforms.reduce(source) { $0.union(source.transformed(Self.data($1))) }
                    }
                case .sketch:
                    continue
                }
                if placed.count == 6, placed.contains(where: { $0 != 0 }) {
                    solid = solid.transformed(Self.data(Self.matrix(translate: SIMD3(placed[0], placed[1], placed[2]), rotate: SIMD3(placed[3], placed[4], placed[5]))))
                }
                // Part Design: added to (or cut from) the body it's on.
                if let op = f.operation, f.kind.canCombine {
                    tool = solid
                    if let base {
                        solid = Self.combine(op, base, solid)
                    } else if op != .add {
                        throw CADBuildError.needsBody
                    }
                }
                cache[key] = Cached(solid: solid, tool: tool, warning: warning)
                result.solids[f.id] = solid
                if let tool { result.tools[f.id] = tool }
                if let warning { result.warnings[f.id] = warning }
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
        // Used sketches aren't shown (as FreeCAD hides a Pad's sketch).
        for id in result.sketchLines.keys where consumed.contains(id) || model.feature(id)?.hidden == true { result.sketchLines[id] = nil }
        return result
    }

    static func combine(_ op: CADFeature.Operation, _ a: MXSolid, _ b: MXSolid) -> MXSolid {
        switch op {
        case .add: a.union(b)
        case .subtract: a.subtracting(b)
        case .intersect: a.intersecting(b)
        }
    }

    // MARK: Part Design tools

    /// How far "through all" goes: past everything in the body from the sketch plane.
    static func throughAll(_ base: MXSolid?, from origin: SIMD3<Double>) -> Double {
        guard let base, base.polygonCount > 0 else { return 1000 }
        let b = base.bounds.withUnsafeBytes { Array($0.bindMemory(to: Double.self)) }
        let lo = SIMD3(b[0], b[1], b[2]), hi = SIMD3(b[3], b[4], b[5])
        return simd_length(hi - lo) + simd_distance((lo + hi) / 2, origin) * 2 + 1
    }

    /// Outlines from the outside in: material joins, holes cut.
    private static func layered(_ loops: [CADSketch.Loop], _ make: (CADSketch.Loop) -> MXSolid) -> MXSolid {
        let depths = CADSketch.depths(loops)
        var body = MXSolid.empty()
        for (loop, depth) in zip(loops, depths).sorted(by: { $0.1 < $1.1 }) {
            let piece = make(loop)
            body = depth % 2 == 0 ? body.union(piece) : body.subtracting(piece)
        }
        return body
    }

    private func extrudeTool(_ f: CADFeature, _ sk: CADSketch, _ offset: Double, base: MXSolid?, segments: Int, face: UInt32, value: (String) throws -> Double) throws -> MXSolid {
        let loops = sk.loops(segments: segments)
        guard !loops.isEmpty else { throw CADBuildError.noProfile }
        // A pocket goes into the material (against the sketch's normal); Reversed turns either round.
        var dir: Double = f.operation == .subtract ? -1 : 1
        if f.choice("reversed") == "Yes" { dir = -dir }
        let length = try value("distance")
        var z0 = 0.0, z1 = dir * length
        switch f.choice("type") {
        case "Two Lengths": z0 = -dir * (try value("distance2"))
        case "Symmetric": z0 = -length / 2; z1 = length / 2
        case "Through All": z1 = dir * Self.throughAll(base, from: Self.point(.zero, sk, offset: offset))
        default: break
        }
        guard abs(z1 - z0) > 1e-9 else { throw CADBuildError.badSize }
        let body = Self.layered(loops) { Self.extrude($0, height: z1 - z0, face: face).transformed(Self.data(Self.translate(SIMD3(0, 0, z0)))) }
        return body.transformed(Self.data(Self.frame(sk, offset: offset)))
    }

    private func revolveTool(_ f: CADFeature, _ sk: CADSketch, _ offset: Double, segments: Int, face: UInt32, value: (String) throws -> Double) throws -> MXSolid {
        var loops = sk.loops(segments: segments)
        guard !loops.isEmpty else { throw CADBuildError.noProfile }
        let horizontal = f.choice("axis") == "Horizontal"
        if horizontal { loops = loops.map { var l = $0; l.points = l.points.map { SIMD2($0.y, $0.x) }; return l } }
        var degrees = try value("angle")
        if f.choice("reversed") == "Yes" { degrees = -degrees }
        var body = Self.layered(loops) { Self.revolve($0, degrees: degrees, segments: segments, face: face) }
        if f.choice("symmetric") == "Yes" {
            let t = degrees / 2 * .pi / 180
            body = body.transformed(Self.data(simd_double4x4(rows: [SIMD4(cos(t), 0, sin(t), 0), SIMD4(0, 1, 0, 0), SIMD4(-sin(t), 0, cos(t), 0), SIMD4(0, 0, 0, 1)])))
        }
        var frame = Self.frame(sk, offset: offset)
        if horizontal {
            // Round the sketch's horizontal axis: its across and up swapped (and out turned round, to stay right-handed).
            frame = simd_double4x4(columns: (frame.columns.1, frame.columns.0, -frame.columns.2, frame.columns.3))
            frame.columns.2.w = 0
        }
        return body.transformed(Self.data(frame))
    }

    /// Each sketch's outer outline in the model, resampled to the same number of points and lined up.
    private func loftTool(_ sketches: [(CADSketch, Double)], ruled: Bool, segments: Int, face: UInt32) throws -> MXSolid {
        guard sketches.count >= 2 else { throw CADBuildError.needsSections }
        var loops: [CADSketch.Loop] = []
        for (sk, _) in sketches {
            guard let outer = sk.loops(segments: segments).max(by: { abs($0.area) < abs($1.area) }) else { throw CADBuildError.noProfile }
            loops.append(outer)
        }
        let sameCount = Set(loops.map(\.points.count)).count == 1
        let n = sameCount ? loops[0].points.count : max(segments, loops.map(\.points.count).max() ?? segments)
        var rings: [[SIMD3<Double>]] = []
        for (loop, (sk, offset)) in zip(loops, sketches) {
            let pts2 = sameCount ? loop.points : Self.resample(loop.points, n)
            var ring = pts2.map { Self.point($0, sk, offset: offset) }
            if let prev = rings.last {
                // The same way round as the last, starting at the nearest point.
                if simd_dot(Self.normal(ring), Self.normal(prev)) < 0 { ring.reverse() }
                var bestShift = 0, best = Double.infinity
                for s in 0..<n {
                    var d = 0.0
                    for k in 0..<n { d += simd_distance_squared(ring[(k + s) % n], prev[k]) }
                    if d < best { best = d; bestShift = s }
                }
                ring = (0..<n).map { ring[($0 + bestShift) % n] }
            }
            rings.append(ring)
        }
        // A smooth loft through three sections or more (Catmull–Rom between them).
        if !ruled, rings.count >= 3 {
            var smooth: [[SIMD3<Double>]] = []
            let steps = 6
            for i in 0..<(rings.count - 1) {
                let p0 = rings[max(0, i - 1)], p1 = rings[i], p2 = rings[i + 1], p3 = rings[min(rings.count - 1, i + 2)]
                for s in 0..<steps {
                    let t = Double(s) / Double(steps), t2 = t * t, t3 = t2 * t
                    smooth.append((0..<n).map { k -> SIMD3<Double> in
                        let a = 2 * p1[k], b = p2[k] - p0[k], c = 2 * p0[k] - 5 * p1[k] + 4 * p2[k] - p3[k], d = -p0[k] + 3 * p1[k] - 3 * p2[k] + p3[k]
                        return 0.5 * (a + b * t + c * t2 + d * t3)
                    })
                }
            }
            smooth.append(rings[rings.count - 1])
            rings = smooth
        }
        let groups: [Int32] = sameCount ? loops[0].groups : Array(repeating: 0, count: n)
        let smoothFlags: [UInt8] = sameCount ? loops[0].smooth : Array(repeating: 1, count: n)
        return Self.sweep(rings, groups: groups, smooth: smoothFlags, closed: false, face: face)
    }

    /// The profile carried along the path, turning with it (each corner mitred).
    private func pipeTool(_ sk: CADSketch, _ offset: Double, spine: [SIMD3<Double>], closed: Bool, segments: Int, face: UInt32) throws -> MXSolid {
        let loops = sk.loops(segments: segments)
        guard !loops.isEmpty else { throw CADBuildError.noProfile }
        guard spine.count >= 2 else { throw CADBuildError.noPath }
        let m = spine.count
        let segs = closed ? m : m - 1
        var tangents: [SIMD3<Double>] = (0..<segs).map { simd_normalize(spine[($0 + 1) % m] - spine[$0]) }
        tangents = tangents.map { $0.x.isNaN ? SIMD3(0, 0, 1) : $0 }
        // Each stretch's turn from the first: the least turning from one to the next.
        var turns: [simd_double3x3] = [matrix_identity_double3x3]
        for j in 1..<max(1, segs) { turns.append(Self.rotation(from: tangents[j - 1], to: tangents[j]) * turns[j - 1]) }
        let start = spine[0]
        return Self.layered(loops) { loop in
            let profile = loop.points.map { Self.point($0, sk, offset: offset) - start }
            var rings: [[SIMD3<Double>]] = []
            for i in 0..<(closed ? m : m) {
                let incoming = i == 0 ? (closed ? segs - 1 : 0) : i - 1
                let outgoing = i == m - 1 && !closed ? segs - 1 : i % segs
                let R = turns[incoming]
                let pts = profile.map { q -> SIMD3<Double> in
                    let x = R * q
                    if (i == 0 && !closed) || (i == m - 1 && !closed) { return spine[i] + (i == 0 ? q : x) }
                    // Mitred where the stretches meet.
                    let t0 = tangents[incoming], t1 = tangents[outgoing]
                    let b = simd_normalize(t0 + t1)
                    let denom = simd_dot(t0, b)
                    let s = abs(denom) > 1e-6 ? -simd_dot(x, b) / denom : 0
                    return spine[i] + x + t0 * s
                }
                rings.append(pts)
            }
            if closed, var first = rings.first {
                // The first ring, mitred between the last stretch and the first, is in the closed path's place.
                first = profile.map { q -> SIMD3<Double> in
                    let x = turns[segs - 1] * q
                    let t0 = tangents[segs - 1], t1 = tangents[0], b = simd_normalize(t0 + t1)
                    let denom = simd_dot(t0, b)
                    let s = abs(denom) > 1e-6 ? -simd_dot(x, b) / denom : 0
                    return spine[0] + x + t0 * s
                }
                rings[0] = first
            }
            return Self.sweep(rings, groups: loop.groups, smooth: loop.smooth, closed: closed, face: face)
        }
    }

    /// The profile turned round the sketch's vertical axis as it rises (right-handed unless asked).
    private func helixTool(_ sk: CADSketch, _ offset: Double, pitch: Double, height: Double, left: Bool, segments: Int, face: UInt32) throws -> MXSolid {
        guard pitch > 0, height > 0 else { throw CADBuildError.badSize }
        let loops = sk.loops(segments: segments)
        guard !loops.isEmpty else { throw CADBuildError.noProfile }
        let turns = height / pitch
        let steps = max(8, Int((turns * Double(max(12, segments))).rounded(.up)))
        let frame = Self.frame(sk, offset: offset)
        return Self.layered(loops) { loop in
            let rings = (0...steps).map { s -> [SIMD3<Double>] in
                let t = Double(s) / Double(steps)
                let theta = (left ? 1 : -1) * 2 * .pi * turns * t
                return loop.points.map { q in
                    let local = SIMD4(q.x * cos(theta), q.y + height * t, q.x * sin(theta), 1)
                    let w = frame * local
                    return SIMD3(w.x, w.y, w.z)
                }
            }
            return Self.sweep(rings, groups: loop.groups, smooth: loop.smooth, closed: false, face: face)
        }
    }

    /// A hole at each circle's centre, into the body (against the sketch's normal).
    private func holeTool(_ f: CADFeature, _ sk: CADSketch, _ offset: Double, base: MXSolid, segments: Int, face: UInt32, value: (String) throws -> Double) throws -> MXSolid {
        let circles = sk.entities.filter { $0.kind == .circle && !$0.isConstruction && $0.points.count >= 2 && $0.radius > 1e-9 }
        guard !circles.isEmpty else { throw CADBuildError.noCircles }
        let set = try value("diameter")
        let through = f.choice("depthType") == "Through All"
        let depth = through ? Self.throughAll(base, from: Self.point(.zero, sk, offset: offset)) : try value("depth")
        guard depth > 0 else { throw CADBuildError.badSize }
        let cut = f.choice("cut"), cutD = try value("cutDiameter"), cutDepth = try value("cutDepth"), cutAngle = try value("cutAngle")
        let angled = f.choice("point") == "Angled" && !through
        let lift = 0.01
        var all = MXSolid.empty()
        for (k, c) in circles.enumerated() {
            let r = set > 0 ? set / 2 : c.radius
            let fk = face + UInt32(k % 1000) * 8
            func cylinder(_ radius: Double, from z0: Double, to z1: Double, _ fc: UInt32) -> MXSolid {
                MXSolid.cone(bottom: radius, top: radius, height: z1 - z0, segments: segments, face: fc).transformed(Self.data(Self.translate(SIMD3(0, 0, z0))))
            }
            var hole = cylinder(r, from: -depth, to: lift, fk)
            if angled {
                let h = r / tan(59 * Double.pi / 180)
                hole = hole.union(MXSolid.cone(bottom: 0, top: r, height: h, segments: segments, face: fk + 3).transformed(Self.data(Self.translate(SIMD3(0, 0, -depth - h)))))
            }
            if cut == "Counterbore", cutD / 2 > r, cutDepth > 0 {
                hole = hole.union(cylinder(cutD / 2, from: -cutDepth, to: lift, fk + 4))
            } else if cut == "Countersink", cutD / 2 > r, cutAngle > 0, cutAngle < 180 {
                let t = tan(cutAngle / 2 * .pi / 180)
                let sink = (cutD / 2 - r) / t
                hole = hole.union(MXSolid.cone(bottom: r, top: cutD / 2 + lift * t, height: sink + lift, segments: segments, face: fk + 5)
                    .transformed(Self.data(Self.translate(SIMD3(0, 0, -sink)))))
            }
            all = all.union(hole.transformed(Self.data(Self.translate(SIMD3(c.points[0].x, c.points[0].y, 0)))))
        }
        if f.choice("reversed") == "Yes" { all = all.transformed(Self.data(simd_double4x4(diagonal: SIMD4(1, 1, -1, 1)))) }
        return all.transformed(Self.data(Self.frame(sk, offset: offset)))
    }

    // MARK: Helpers

    private static func normal(_ ring: [SIMD3<Double>]) -> SIMD3<Double> {
        var n = SIMD3<Double>.zero
        for i in ring.indices {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            n += SIMD3((a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y))
        }
        return simd_length(n) > 1e-12 ? simd_normalize(n) : SIMD3(0, 0, 1)
    }

    /// Points evenly spaced round a closed outline.
    private static func resample(_ pts: [SIMD2<Double>], _ n: Int) -> [SIMD2<Double>] {
        let m = pts.count
        guard m >= 2 else { return pts }
        var lengths: [Double] = [0]
        for i in 0..<m { lengths.append(lengths.last! + simd_distance(pts[i], pts[(i + 1) % m])) }
        let total = lengths.last!
        guard total > 1e-12 else { return Array(repeating: pts[0], count: n) }
        var out: [SIMD2<Double>] = []
        var seg = 0
        for k in 0..<n {
            let s = total * Double(k) / Double(n)
            while seg < m - 1, lengths[seg + 1] < s { seg += 1 }
            let span = lengths[seg + 1] - lengths[seg]
            let t = span > 1e-12 ? (s - lengths[seg]) / span : 0
            out.append(pts[seg] + (pts[(seg + 1) % m] - pts[seg]) * t)
        }
        return out
    }

    /// The least rotation taking one direction to another.
    private static func rotation(from a: SIMD3<Double>, to b: SIMD3<Double>) -> simd_double3x3 {
        let v = simd_cross(a, b), c = simd_dot(a, b)
        if simd_length(v) < 1e-12 { return c > 0 ? matrix_identity_double3x3 : simd_double3x3(diagonal: SIMD3(-1, -1, 1)) }
        let k = simd_double3x3(rows: [SIMD3(0, -v.z, v.y), SIMD3(v.z, 0, -v.x), SIMD3(-v.y, v.x, 0)])
        return matrix_identity_double3x3 + k + k * k * (1 / (1 + c))
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

    static func sweep(_ rings: [[SIMD3<Double>]], groups: [Int32], smooth: [UInt8], closed: Bool, face: UInt32) -> MXSolid {
        let xyz = rings.flatMap { $0.flatMap { [$0.x, $0.y, $0.z] } }
        return .sweep(rings: xyz.withUnsafeBufferPointer { Data(buffer: $0) }, count: rings.count, groups: groups.withUnsafeBufferPointer { Data(buffer: $0) },
                      smooth: Data(smooth), closed: closed, face: face)
    }

    private static func profileData(_ loop: CADSketch.Loop) -> (Data, Data, Data) {
        let xy = loop.points.flatMap { [$0.x, $0.y] }
        return (xy.withUnsafeBufferPointer { Data(buffer: $0) }, loop.groups.withUnsafeBufferPointer { Data(buffer: $0) }, Data(loop.smooth))
    }
}
