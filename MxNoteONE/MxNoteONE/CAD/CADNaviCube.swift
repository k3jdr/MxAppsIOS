//
//  CADNaviCube.swift
//  MxNoteONE
//
//  FreeCAD's navigation cube: a cube turned as the model is, its faces named; click a face for that standard view, an
//  edge or a corner for the view from there (a corner is an isometric view); the arrows below turn the view.
//

import SwiftUI
import simd

struct CADNaviCube: View {
    let camera: CADCamera
    let look: (Double, Double) -> Void
    let orbit: (Double) -> Void
    @State private var hover: SIMD3<Double>?

    private static let faces: [(normal: SIMD3<Double>, label: String)] = [
        (SIMD3(0, 0, 1), "TOP"), (SIMD3(0, 0, -1), "BOTTOM"), (SIMD3(0, -1, 0), "FRONT"),
        (SIMD3(0, 1, 0), "REAR"), (SIMD3(1, 0, 0), "RIGHT"), (SIMD3(-1, 0, 0), "LEFT"),
    ]
    private static let size: CGFloat = 104

    /// The camera's turn: model directions into the view (x right, y up, z towards the viewer).
    private var rotation: simd_double3x3 {
        var c = camera
        c.target = .zero
        c.distance = 1
        let m = CADRenderer.viewMatrix(c)
        return simd_double3x3(rows: [SIMD3(m[0][0], m[1][0], m[2][0]), SIMD3(m[0][1], m[1][1], m[2][1]), SIMD3(m[0][2], m[1][2], m[2][2])])
    }

    private func screen(_ p: SIMD3<Double>, _ r: simd_double3x3) -> CGPoint {
        let v = r * p
        let s = Double(Self.size) * 0.27
        return CGPoint(x: Double(Self.size) / 2 + v.x * s, y: Double(Self.size) / 2 - v.y * s)
    }

    private func corners(of n: SIMD3<Double>) -> [SIMD3<Double>] {
        let a = abs(n.z) > 0.5 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 0, 1)
        let b = simd_cross(n, a)
        return [n + a + b, n - a + b, n - a - b, n + a - b]
    }

    /// The direction a point of the cube looks from: a corner, an edge's middle, or a face.
    private func target(at p: CGPoint) -> SIMD3<Double>? {
        let r = rotation
        var cubeCorners: [SIMD3<Double>] = []
        for x in [-1.0, 1] { for y in [-1.0, 1] { for z in [-1.0, 1] { cubeCorners.append(SIMD3(x, y, z)) } } }
        func near(_ q: SIMD3<Double>, _ d: CGFloat) -> Bool {
            guard (r * q).z > -0.05 else { return false }
            let s = screen(q, r)
            return hypot(s.x - p.x, s.y - p.y) < d
        }
        if let c = cubeCorners.first(where: { near($0, 9) }) { return c }
        var mids: [SIMD3<Double>] = []
        for i in 0..<3 {
            for a in [-1.0, 1] { for b in [-1.0, 1] {
                var v = SIMD3<Double>(repeating: 0)
                v[(i + 1) % 3] = a
                v[(i + 2) % 3] = b
                mids.append(v)
            } }
        }
        if let m = mids.first(where: { near($0, 8) }) { return m }
        for f in Self.faces where (r * f.normal).z > 0.05 {
            let poly = corners(of: f.normal).map { screen($0, r) }
            if contains(poly, p) { return f.normal }
        }
        return nil
    }

    private func contains(_ poly: [CGPoint], _ p: CGPoint) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in poly.indices {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    var body: some View {
        VStack(spacing: 2) {
            Canvas { ctx, _ in
                let r = rotation
                let visible = Self.faces.map { ($0, (r * $0.normal).z) }.filter { $0.1 > 0.02 }.sorted { $0.1 < $1.1 }
                for (f, facing) in visible {
                    let pts = corners(of: f.normal).map { screen($0, r) }
                    var path = Path()
                    path.addLines(pts)
                    path.closeSubpath()
                    let lit = 0.78 + 0.2 * facing
                    let hot = hover.map { simd_distance(simd_normalize($0), f.normal) < 1e-6 } ?? false
                    ctx.fill(path, with: .color(hot ? Color(red: 0.55, green: 0.75, blue: 1.0) : Color(white: lit)))
                    ctx.stroke(path, with: .color(Color(white: 0.35)), lineWidth: 1)
                    let c = screen(f.normal, r)
                    if facing > 0.25 {
                        ctx.draw(Text(f.label).font(.system(size: 9 + 3 * facing, weight: .semibold)).foregroundStyle(Color(white: 0.2)), at: c)
                    }
                }
                // The point (corner or edge) under the pointer.
                if let h = hover, simd_length(h) > 1.01 {
                    let s = screen(h, r)
                    ctx.fill(Path(ellipseIn: CGRect(x: s.x - 5, y: s.y - 5, width: 10, height: 10)), with: .color(Color(red: 0.2, green: 0.5, blue: 1.0)))
                }
            }
            .frame(width: Self.size, height: Self.size)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let p) = phase { hover = target(at: p) } else { hover = nil }
            }
            .gesture(SpatialTapGesture().onEnded { value in
                guard let d0 = target(at: value.location) else { return }
                let d = simd_normalize(d0)
                let yaw = abs(d.x) < 1e-9 && abs(d.y) < 1e-9 ? camera.yaw : atan2(d.y, d.x) * 180 / .pi
                let pitch = max(-89.5, min(89.5, asin(max(-1, min(1, d.z))) * 180 / .pi))
                look(yaw, pitch)
            })
            .help("Click a face, edge or corner for that view")
            HStack(spacing: 10) {
                Button { orbit(-15) } label: { Image(systemName: "arrow.counterclockwise") }.help("Turn the view left")
                Button { look(-45, 35.264) } label: { Image(systemName: "cube") }.help("Isometric")
                Button { orbit(15) } label: { Image(systemName: "arrow.clockwise") }.help("Turn the view right")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
