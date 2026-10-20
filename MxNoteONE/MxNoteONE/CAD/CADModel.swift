//
//  CADModel.swift
//  MxNoteONE
//
//  A 3D model: named parameters and a history of features, as FreeCAD's Part and Part Design workbenches have them —
//  primitives; sketches (with constraints) padded, pocketed, revolved, grooved, lofted, swept along a path or round a
//  helix; holes; fillets and chamfers on edges; booleans, patterns and mirrors; meshes and shapes brought in from STL,
//  OBJ or FreeCAD — rebuilt in order by the geometry kernel (MXSolid, see CADBuilder). Any number can be an
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
    mutating func make(_ kind: CADFeature.Kind, name: String? = nil, operation: CADFeature.Operation? = nil) -> CADFeature {
        var f = CADFeature(kind: kind, name: "")
        f.operation = operation
        f.name = name ?? uniqueName(f.typeTitle)
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

    /// The features a feature is built from (the bodies a boolean, pattern, mirror, Pad or Fillet uses up, and the
    /// sketches it's made from).
    func consumed() -> Set<UUID> { Set(features.flatMap { ($0.inputs ?? []) + ($0.profile.map { [$0] } ?? []) + ($0.sections ?? []) }) }

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

/// FreeCAD's draw styles.
enum CADDisplay: String, Codable, CaseIterable {
    case shadedEdges = "Shaded with Edges", shaded = "Shaded", noShading = "No Shading", hiddenLine = "Hidden Line", wireframe = "Wireframe"

    var title: String {
        switch self {
        case .shadedEdges: "Flat Lines"
        case .shaded: "Shaded"
        case .noShading: "No Shading"
        case .hiddenLine: "Hidden Line"
        case .wireframe: "Wireframe"
        }
    }
}

/// One of a feature's settings: a number (an expression), or a choice among `choices`.
struct CADField {
    let key: String
    let label: String
    let value: String
    var choices: [String]? = nil
}

/// An edge picked for a fillet or chamfer: the two faces it lies between, and a point on it (for when they meet
/// along more than one edge).
struct CADEdgeRef: Codable, Hashable {
    var a: UInt32
    var b: UInt32
    var near: SIMD3<Double>?

    func same(_ o: CADEdgeRef) -> Bool { min(a, b) == min(o.a, o.b) && max(a, b) == max(o.a, o.b) && (near == nil || o.near == nil || simd_distance(near!, o.near!) < 1e-3) }
}

/// Where an imported shape came from: a FreeCAD (or STEP, IGES, BREP) file outside the notebook — followed when it
/// changes — or one kept in it, and the object in it.
struct CADSource: Codable, Hashable {
    var path: String?
    var asset: String?
    var object: String
    var label: String?
    var format: String
    var modified: Date?
}

struct CADFeature: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case box, cylinder, cone, sphere, torus, wedge, prism, extrude, revolve, mesh, union, subtract, intersect
        case linearPattern, circularPattern, mirror
        case tube, ellipsoid, sketch, loft, pipe, helix, hole, fillet, chamfer

        var title: String {
            switch self {
            case .box: "Box"
            case .cylinder: "Cylinder"
            case .cone: "Cone"
            case .sphere: "Sphere"
            case .torus: "Torus"
            case .wedge: "Wedge"
            case .prism: "Prism"
            case .tube: "Tube"
            case .ellipsoid: "Ellipsoid"
            case .sketch: "Sketch"
            case .extrude: "Extrude"
            case .revolve: "Revolve"
            case .loft: "Loft"
            case .pipe: "Sweep"
            case .helix: "Helix"
            case .hole: "Hole"
            case .mesh: "Mesh"
            case .union: "Union"
            case .subtract: "Subtract"
            case .intersect: "Intersect"
            case .fillet: "Fillet"
            case .chamfer: "Chamfer"
            case .linearPattern: "Linear Pattern"
            case .circularPattern: "Polar Pattern"
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
            case .tube: "smallcircle.circle"
            case .ellipsoid: "oval"
            case .sketch: "pencil.and.outline"
            case .extrude: "square.3.layers.3d.top.filled"
            case .revolve: "arrow.trianglehead.2.clockwise.rotate.90"
            case .loft: "skew"
            case .pipe: "scribble.variable"
            case .helix: "tornado"
            case .hole: "record.circle"
            case .mesh: "cube.transparent"
            case .union: "square.on.square"
            case .subtract: "minus.square"
            case .intersect: "square.on.square.intersection.dashed"
            case .fillet: "rectangle.roundedtop"
            case .chamfer: "righttriangle"
            case .linearPattern: "square.grid.3x1.below.line.grid.1x2"
            case .circularPattern: "circle.dotted"
            case .mirror: "arrow.left.and.right.righttriangle.left.righttriangle.right"
            }
        }
        var isBoolean: Bool { self == .union || self == .subtract || self == .intersect }
        var isPattern: Bool { self == .linearPattern || self == .circularPattern || self == .mirror }
        var isDressUp: Bool { self == .fillet || self == .chamfer }
        var isPrimitive: Bool { [.box, .cylinder, .cone, .sphere, .torus, .wedge, .prism, .tube, .ellipsoid].contains(self) }
        var usesInput: Bool { isBoolean || isPattern || isDressUp }
        var usesSketch: Bool { [.extrude, .revolve, .loft, .pipe, .helix, .hole, .sketch].contains(self) }
        var isPlaced: Bool { isPrimitive || self == .extrude || self == .revolve || self == .mesh }
        /// Makes a solid of its own (Part Design adds it to a body, or cuts it out).
        var canCombine: Bool { isPrimitive || [.extrude, .revolve, .loft, .pipe, .helix].contains(self) }
    }

    /// Part Design: what a feature does to the body it's on (its first input) — Pad adds, Pocket cuts.
    enum Operation: String, Codable, CaseIterable {
        case add, subtract, intersect
    }

    var id = UUID()
    var kind: Kind
    var name: String
    /// Each dimension as an expression, by key (see `fields`); a choice as its title.
    var values: [String: String] = [:]
    var placement = CADPlacement()
    /// Its own sketch (a sketch feature's; older models' Extrude and Revolve).
    var sketch: CADSketch?
    /// The bodies it uses (a boolean: the first is cut or joined by the rest; a pattern or mirror: the body or
    /// feature; Part Design: the body it's added to or cut from).
    var inputs: [UUID]?
    var color: CADColor?
    var hidden: Bool?
    /// An imported mesh: triangles, nine float32s each.
    var meshData: Data?
    /// Its faces are numbered from this (each feature's are its own).
    var serial = 0
    var operation: Operation?
    /// The sketch feature it's made from (a Pad's sketch).
    var profile: UUID?
    /// More sketch features: a loft's further sections; a pipe's path.
    var sections: [UUID]?
    /// A sketch drawn on a body's face: that body (what a Pad or Pocket from it goes on).
    var support: UUID?
    /// A fillet's or chamfer's edges.
    var edges: [CADEdgeRef]?
    /// An imported shape's file and object.
    var source: CADSource?
    /// An imported shape's face number for each triangle (uint32), and its normals (nine float32s a triangle).
    var meshFaces: Data?
    var meshNormals: Data?

    /// What it is, as FreeCAD names it: Pad, Pocket, Revolution, Groove, Additive Box…
    var typeTitle: String {
        switch (kind, operation) {
        case (.extrude, .add?): "Pad"
        case (.extrude, .subtract?): "Pocket"
        case (.revolve, .add?): "Revolution"
        case (.revolve, .subtract?): "Groove"
        case (.loft, .add?): "Additive Loft"
        case (.loft, .subtract?): "Subtractive Loft"
        case (.pipe, .add?): "Additive Pipe"
        case (.pipe, .subtract?): "Subtractive Pipe"
        case (.helix, .add?): "Additive Helix"
        case (.helix, .subtract?): "Subtractive Helix"
        case (_, .add?) where kind.isPrimitive: "Additive \(kind.title)"
        case (_, .subtract?) where kind.isPrimitive: "Subtractive \(kind.title)"
        case (_, .intersect?): "\(kind.title) (Common)"
        default: kind.title
        }
    }

    /// The body it adds to or cuts from (Part Design), or fillets.
    var base: UUID? { (operation != nil || kind.isDressUp || kind == .hole) ? inputs?.first : nil }

    /// A choice's value (its default when not set).
    func choice(_ key: String) -> String {
        values[key] ?? CADFeature.fields(kind).first { $0.key == key }?.value ?? ""
    }

    /// A feature's settings: key, label, default (and choices).
    static func fields(_ kind: Kind) -> [CADField] {
        let yesNo = ["No", "Yes"]
        switch kind {
        case .box: return [CADField(key: "width", label: "Width", value: "40"), CADField(key: "depth", label: "Depth", value: "30"),
                           CADField(key: "height", label: "Height", value: "20"), CADField(key: "radius", label: "Edge radius", value: "0")]
        case .cylinder: return [CADField(key: "radius", label: "Radius", value: "10"), CADField(key: "height", label: "Height", value: "30")]
        case .cone: return [CADField(key: "bottom", label: "Bottom radius", value: "15"), CADField(key: "top", label: "Top radius", value: "0"),
                            CADField(key: "height", label: "Height", value: "30")]
        case .sphere: return [CADField(key: "radius", label: "Radius", value: "15")]
        case .torus: return [CADField(key: "major", label: "Ring radius", value: "20"), CADField(key: "minor", label: "Tube radius", value: "5")]
        case .wedge: return [CADField(key: "width", label: "Width", value: "40"), CADField(key: "depth", label: "Depth", value: "20"),
                             CADField(key: "height", label: "Height", value: "20")]
        case .prism: return [CADField(key: "sides", label: "Sides", value: "6"), CADField(key: "radius", label: "Radius", value: "15"),
                             CADField(key: "height", label: "Height", value: "20")]
        case .tube: return [CADField(key: "outer", label: "Outer radius", value: "12"), CADField(key: "inner", label: "Inner radius", value: "8"),
                            CADField(key: "height", label: "Height", value: "20")]
        case .ellipsoid: return [CADField(key: "rx", label: "Radius X", value: "20"), CADField(key: "ry", label: "Radius Y", value: "15"),
                                 CADField(key: "rz", label: "Radius Z", value: "10")]
        case .extrude: return [CADField(key: "type", label: "Type", value: "Length", choices: ["Length", "Two Lengths", "Symmetric", "Through All"]),
                               CADField(key: "distance", label: "Length", value: "20"), CADField(key: "distance2", label: "Second length", value: "10"),
                               CADField(key: "reversed", label: "Reversed", value: "No", choices: yesNo)]
        case .revolve: return [CADField(key: "axis", label: "Axis", value: "Vertical", choices: ["Vertical", "Horizontal"]),
                               CADField(key: "angle", label: "Angle", value: "360"), CADField(key: "symmetric", label: "Symmetric", value: "No", choices: yesNo),
                               CADField(key: "reversed", label: "Reversed", value: "No", choices: yesNo)]
        case .loft: return [CADField(key: "ruled", label: "Ruled", value: "No", choices: yesNo)]
        case .helix: return [CADField(key: "pitch", label: "Pitch", value: "5"), CADField(key: "height", label: "Height", value: "20"),
                             CADField(key: "hand", label: "Turns", value: "Right-handed", choices: ["Right-handed", "Left-handed"])]
        case .hole: return [CADField(key: "diameter", label: "Diameter (0: as drawn)", value: "0"),
                            CADField(key: "depthType", label: "Depth", value: "Dimension", choices: ["Dimension", "Through All"]),
                            CADField(key: "depth", label: "Depth (mm)", value: "10"),
                            CADField(key: "cut", label: "Hole cut", value: "None", choices: ["None", "Counterbore", "Countersink"]),
                            CADField(key: "cutDiameter", label: "Cut diameter", value: "12"), CADField(key: "cutDepth", label: "Counterbore depth", value: "3"),
                            CADField(key: "cutAngle", label: "Countersink angle", value: "90"),
                            CADField(key: "point", label: "Drill point", value: "Angled", choices: ["Angled", "Flat"]),
                            CADField(key: "reversed", label: "Reversed", value: "No", choices: yesNo)]
        case .fillet: return [CADField(key: "radius", label: "Radius", value: "2")]
        case .chamfer: return [CADField(key: "size", label: "Size", value: "1")]
        case .linearPattern: return [CADField(key: "count", label: "Count", value: "3"), CADField(key: "dx", label: "Step X", value: "30"),
                                     CADField(key: "dy", label: "Step Y", value: "0"), CADField(key: "dz", label: "Step Z", value: "0")]
        case .circularPattern: return [CADField(key: "count", label: "Count", value: "6"), CADField(key: "angle", label: "Angle", value: "360")]
        case .mirror: return [CADField(key: "plane", label: "Plane", value: "YZ", choices: ["YZ", "XZ", "XY"])]
        case .mesh, .union, .subtract, .intersect, .sketch, .pipe: return []
        }
    }
}

// MARK: - Sketches

/// A sketch's plane when it's on a body's face: its origin and across and up directions in the model.
struct CADFrame: Codable, Hashable {
    var origin: SIMD3<Double>
    var u: SIMD3<Double>
    var v: SIMD3<Double>
    var n: SIMD3<Double> { simd_normalize(simd_cross(u, v)) }
}

/// A 2D sketch on a plane — its closed outlines padded, revolved, lofted or swept (an outline inside another is a
/// hole), its open chains a path — held in shape by its constraints.
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
    /// On a body's face: the face's plane (instead of `plane`).
    var frame: CADFrame?
    var constraints: [CADConstraint]?

    var planeTitle: String { frame != nil ? "On a face" : plane.title }

    /// Across, up and out in the model, and the origin (before the offset).
    var axes: (u: SIMD3<Double>, v: SIMD3<Double>, n: SIMD3<Double>, origin: SIMD3<Double>) {
        if let f = frame { return (f.u, f.v, f.n, f.origin) }
        let a = plane.axes
        return (a.u, a.v, a.n, .zero)
    }
}

struct CADSketchEntity: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case line, arc, circle, rectangle, polygon, point
        var title: String { rawValue.capitalized }
    }
    var id = UUID()
    var kind: Kind
    /// line: start, end · arc: start, end, a point on it · circle: centre, a point on it · rectangle: two corners ·
    /// polygon: centre, a corner · point: where it is.
    var points: [SIMD2<Double>]
    var sides: Int?
    /// Construction geometry: guides and references, not part of any outline.
    var construction: Bool?

    var radius: Double { points.count >= 2 ? simd_distance(points[0], points[1]) : 0 }
    var isConstruction: Bool { construction == true || kind == .point }

    /// Its outline as points (closed shapes end where they start).
    func outline(segments: Int = 64) -> [SIMD2<Double>] {
        switch kind {
        case .line: return points.count >= 2 ? [points[0], points[1]] : []
        case .arc: return points.count >= 3 ? CADSketch.arcPoints(points[0], points[1], through: points[2], segments: segments) : []
        case .circle:
            guard points.count >= 2 else { return [] }
            return (0...segments).map { k in points[0] + radius * SIMD2(cos(2 * .pi * Double(k) / Double(segments)), sin(2 * .pi * Double(k) / Double(segments))) }
        case .rectangle:
            guard points.count >= 2 else { return [] }
            let a = points[0], b = points[1]
            return [a, SIMD2(b.x, a.y), b, SIMD2(a.x, b.y), a]
        case .polygon:
            guard points.count >= 2 else { return [] }
            let n = max(3, sides ?? 6)
            let start = atan2(points[1].y - points[0].y, points[1].x - points[0].x)
            return (0...n).map { k in points[0] + radius * SIMD2(cos(start + 2 * .pi * Double(k) / Double(n)), sin(start + 2 * .pi * Double(k) / Double(n))) }
        case .point: return points.isEmpty ? [] : [points[0]]
        }
    }
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

    /// Lines and arcs (not construction) as point chains.
    private func chains(segments: Int) -> [(points: [SIMD2<Double>], smooth: Bool)] {
        entities.compactMap { e -> ([SIMD2<Double>], Bool)? in
            guard !e.isConstruction else { return nil }
            switch e.kind {
            case .line where e.points.count >= 2: return ([e.points[0], e.points[1]], false)
            case .arc where e.points.count >= 3: return (Self.arcPoints(e.points[0], e.points[1], through: e.points[2], segments: segments), true)
            default: return nil
            }
        }
    }

    /// The sketch's closed outlines: circles, rectangles and polygons, and lines and arcs joined end to end.
    func loops(segments: Int) -> [Loop] {
        var loops: [Loop] = []
        var group: Int32 = 0
        for e in entities where !e.isConstruction {
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
            default: break
            }
        }
        let chains = chains(segments: segments)
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

    /// A path (a pipe's): the longest chain of lines and arcs end to end, open or closed — or a closed outline.
    func path(segments: Int) -> (points: [SIMD2<Double>], closed: Bool)? {
        let chains = chains(segments: segments)
        let tolerance = 1e-4
        var best: ([SIMD2<Double>], Bool)?
        var used = Array(repeating: false, count: chains.count)
        func length(_ p: [SIMD2<Double>]) -> Double { zip(p, p.dropFirst()).reduce(0) { $0 + simd_distance($1.0, $1.1) } }
        for start in chains.indices where !used[start] {
            used[start] = true
            var pts = chains[start].points
            var grew = true
            while grew {
                grew = false
                for k in chains.indices where !used[k] {
                    let c = chains[k].points
                    if simd_distance(c.first!, pts.last!) < tolerance { pts += c.dropFirst() }
                    else if simd_distance(c.last!, pts.last!) < tolerance { pts += c.reversed().dropFirst() }
                    else if simd_distance(c.last!, pts.first!) < tolerance { pts = c.dropLast() + pts }
                    else if simd_distance(c.first!, pts.first!) < tolerance { pts = c.reversed().dropLast() + pts }
                    else { continue }
                    used[k] = true
                    grew = true
                }
            }
            var closed = false
            if pts.count > 2, simd_distance(pts.first!, pts.last!) < tolerance { pts.removeLast(); closed = true }
            if best == nil || length(pts) > length(best!.0) { best = (pts, closed) }
        }
        if let best, best.0.count >= 2 { return best }
        if let loop = loops(segments: segments).first { return (loop.points, true) }
        return nil
    }

    /// The sketch's shapes as lines in the model (for showing it in the 3D view).
    func lines3D(offset: Double, segments: Int = 48) -> [[SIMD3<Double>]] {
        let a = axes
        return entities.map { e in e.outline(segments: segments).map { a.origin + a.u * $0.x + a.v * $0.y + a.n * offset } }
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
