//
//  CADRenderer.swift
//  MxNoteONE
//
//  The Metal renderer. A scene pass draws the bodies lit (two lights, a highlight) into a colour texture and each
//  pixel's face number into an integer texture; a composite pass then lays the picture over a soft background and
//  draws feature edges wherever neighbouring pixels belong to different faces — so edges stay clean however the
//  booleans cut the polygons. FreeCAD's draw styles (Flat Lines, Shaded, No Shading, Hidden Line, Wireframe);
//  selected and preselected faces and edges in FreeCAD's green and yellow; sketches as lines in the model; a ground
//  grid, the axes, a small axis cross, and pictures drawn off screen.
//

import AppKit
import Metal
import MetalKit
import simd

private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VertexIn { packed_float3 position; packed_float3 normal; uint face; };
struct Uniforms { float4x4 viewProjection; float4x4 view; float4 color; float highlight; uint mode; float2 pad; };
struct VOut { float4 position [[position]]; float3 normal; float3 viewPos; uint face [[flat]]; };
struct FOut { float4 color [[color(0)]]; uint id [[color(1)]]; };

vertex VOut modelVertex(device const VertexIn *v [[buffer(0)]], constant Uniforms &u [[buffer(1)]], uint vid [[vertex_id]]) {
    VOut o;
    float3 p = float3(v[vid].position);
    o.position = u.viewProjection * float4(p, 1);
    o.normal = (u.view * float4(float3(v[vid].normal), 0)).xyz;
    o.viewPos = (u.view * float4(p, 1)).xyz;
    o.face = v[vid].face;
    return o;
}

fragment FOut modelFragment(VOut in [[stage_in]], constant Uniforms &u [[buffer(1)]], bool front [[front_facing]]) {
    float3 n = normalize(in.normal);
    float3 toEye = normalize(-in.viewPos);
    if (dot(n, toEye) < 0) n = -n;
    float3 key = normalize(float3(0.35, 0.6, 1.0));
    float3 fill = normalize(float3(-0.7, -0.3, 0.5));
    float diffuse = max(dot(n, key), 0.0) * 0.72 + max(dot(n, fill), 0.0) * 0.28;
    float specular = pow(max(dot(n, normalize(key + toEye)), 0.0), 40.0) * 0.30;
    float3 base = u.color.rgb;
    FOut o;
    if (u.mode == 2) {
        // Hidden line: white faces (the edges do the drawing).
        o.color = float4(mix(float3(1.0), float3(0.80, 0.88, 1.0), u.highlight), 1);
    } else if (u.mode == 3) {
        // No shading: the colour as it is.
        o.color = float4(mix(base, float3(0.22, 0.50, 1.0), u.highlight), 1);
    } else if (u.mode == 4) {
        // A selected or preselected face: its colour, lightly shaded.
        o.color = float4(base * (0.75 + diffuse * 0.25), 1);
    } else {
        float3 c = base * (0.30 + diffuse * 0.70) + specular;
        o.color = float4(mix(c, float3(0.22, 0.50, 1.0), u.highlight), 1);
    }
    o.id = in.face;
    return o;
}

struct LineIn { packed_float3 position; packed_float4 color; };
struct LOut { float4 position [[position]]; float4 color; };

vertex LOut lineVertex(device const LineIn *v [[buffer(0)]], constant Uniforms &u [[buffer(1)]], uint vid [[vertex_id]]) {
    LOut o;
    o.position = u.viewProjection * float4(float3(v[vid].position), 1);
    o.color = float4(v[vid].color);
    return o;
}

fragment FOut lineFragment(LOut in [[stage_in]]) {
    FOut o;
    o.color = in.color;
    o.id = 0;
    return o;
}

/// A line drawn wide: each segment two triangles, pushed apart across the screen.
struct ThickIn { packed_float3 a; packed_float3 b; float side; float end; packed_float4 color; };

vertex LOut thickVertex(device const ThickIn *v [[buffer(0)]], constant Uniforms &u [[buffer(1)]], constant float4 &screen [[buffer(2)]], uint vid [[vertex_id]]) {
    ThickIn i = v[vid];
    float4 ca = u.viewProjection * float4(float3(i.a), 1), cb = u.viewProjection * float4(float3(i.b), 1);
    float2 half_size = screen.xy * 0.5;
    float2 sa = ca.xy / max(ca.w, 1e-6) * half_size, sb = cb.xy / max(cb.w, 1e-6) * half_size;
    float2 d = sb - sa;
    float len = length(d);
    d = len > 1e-6 ? d / len : float2(1, 0);
    float2 n = float2(-d.y, d.x);
    float4 c = i.end < 0.5 ? ca : cb;
    LOut o;
    o.position = float4(c.xy + n * i.side * screen.z * 0.5 / half_size * c.w, c.z - screen.w * c.w, c.w);
    o.color = float4(i.color);
    return o;
}

struct Composite { uint edges; float strength; float2 pad; float4 top; float4 bottom; };
struct QOut { float4 position [[position]]; float2 uv; };

vertex QOut quadVertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    QOut o;
    o.position = float4(p * 2 - 1, 0, 1);
    o.uv = float2(p.x, 1 - p.y);
    return o;
}

/// A pixel's face — and, for a crack between two triangles of one face (where the booleans leave a seam), the
/// face on either side.
static uint faceAt(texture2d<uint> ids, int2 p, int2 size) {
    int2 q = clamp(p, int2(0), size - 1);
    uint id = ids.read(uint2(q)).r;
    if (id != 0) return id;
    int2 dirs[2] = { int2(1, 0), int2(0, 1) };
    for (int k = 0; k < 2; k++) {
        uint a = ids.read(uint2(clamp(q + dirs[k], int2(0), size - 1))).r;
        uint b = ids.read(uint2(clamp(q - dirs[k], int2(0), size - 1))).r;
        if (a != 0 && a == b) return a;
    }
    return 0;
}

fragment float4 compositeFragment(QOut in [[stage_in]], texture2d<float> color [[texture(0)]], texture2d<uint> ids [[texture(1)]],
                                  constant Composite &c [[buffer(0)]]) {
    int2 size = int2(ids.get_width(), ids.get_height());
    int2 p = min(int2(in.position.xy), size - 1);
    float4 pixel = color.read(uint2(p));
    uint id = faceAt(ids, p, size);
    // A crack: the colour of the face round it.
    if (id != 0 && ids.read(uint2(p)).r == 0) {
        float4 h = (color.read(uint2(clamp(p + int2(1, 0), int2(0), size - 1))) + color.read(uint2(clamp(p - int2(1, 0), int2(0), size - 1)))) / 2;
        float4 v = (color.read(uint2(clamp(p + int2(0, 1), int2(0), size - 1))) + color.read(uint2(clamp(p - int2(0, 1), int2(0), size - 1)))) / 2;
        pixel = h.a > v.a ? h : v;
    }
    float4 background = mix(c.bottom, c.top, in.uv.y < 0 ? 0 : 1 - in.uv.y);
    // The scene's colours are premultiplied (the grid is blended over a clear background).
    float3 rgb = background.rgb * (1 - pixel.a) + pixel.rgb;
    if (c.edges != 0) {
        int differ = 0;
        int2 offsets[4] = { int2(1, 0), int2(0, 1), int2(-1, 0), int2(0, -1) };
        for (int k = 0; k < 4; k++) {
            if (faceAt(ids, p + offsets[k], size) != id) differ++;
        }
        if (differ > 0) rgb = mix(rgb, float3(0.07, 0.08, 0.10), c.strength);
    }
    return float4(rgb, 1);
}
"""

/// A body ready to draw.
struct CADGPUBody {
    let id: UUID
    let buffer: MTLBuffer
    let count: Int
    /// Each triangle's sides as lines, drawn in the face's colour to close the hairline cracks booleans leave
    /// where one face's triangles meet another's mid-edge.
    let lines: MTLBuffer?
    let color: SIMD4<Float>
    let positions: [SIMD3<Float>]
    let faces: [UInt32]
}

/// Lines drawn a few pixels wide: edges picked or hovered, sketches, a wireframe.
struct CADLineSet {
    var segments: [(SIMD3<Float>, SIMD3<Float>)]
    var color: SIMD4<Float>
    var width: Float = 2
    /// Over everything (not hidden by the bodies).
    var onTop = false

    /// Polylines as segments.
    init(_ polylines: [[SIMD3<Double>]], closed: [Bool] = [], color: SIMD4<Float>, width: Float = 2, onTop: Bool = false) {
        var segs: [(SIMD3<Float>, SIMD3<Float>)] = []
        for (k, pl) in polylines.enumerated() {
            for i in 0..<max(0, pl.count - 1) { segs.append((SIMD3<Float>(pl[i]), SIMD3<Float>(pl[i + 1]))) }
            if closed.indices.contains(k), closed[k], let f = pl.first, let l = pl.last, pl.count > 2 { segs.append((SIMD3<Float>(l), SIMD3<Float>(f))) }
        }
        segments = segs
        self.color = color
        self.width = width
        self.onTop = onTop
    }
}

/// A face of a body drawn in a highlight colour: its triangles' vertices (as the body's buffer has them).
struct CADFaceHighlight {
    var vertices: Data
    var color: SIMD4<Float>
}

/// What to draw.
struct CADScene {
    var bodies: [CADGPUBody] = []
    var lines: [CADLineSet] = []
    var faceHighlights: [CADFaceHighlight] = []
    var camera = CADCamera()
    var display: CADDisplay = .shadedEdges
    var selected: Set<UUID> = []
    var hovered: UUID?
    var grid = true
    /// The model's extent (for the grid, clipping and fitting).
    var bounds: (min: SIMD3<Double>, max: SIMD3<Double>)?
}

private func floats(_ m: simd_double4x4) -> simd_float4x4 {
    simd_float4x4(columns: (SIMD4<Float>(m.columns.0), SIMD4<Float>(m.columns.1), SIMD4<Float>(m.columns.2), SIMD4<Float>(m.columns.3)))
}

private struct Uniforms {
    var viewProjection: simd_float4x4
    var view: simd_float4x4
    var color: SIMD4<Float>
    var highlight: Float
    var mode: UInt32
    var pad: SIMD2<Float> = .zero
}

private struct CompositeUniforms {
    var edges: UInt32
    var strength: Float
    var pad: SIMD2<Float> = .zero
    var top: SIMD4<Float>
    var bottom: SIMD4<Float>
}

final class CADRenderer {
    static let shared = CADRenderer()

    let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private var modelPipeline: MTLRenderPipelineState?
    private var linePipeline: MTLRenderPipelineState?
    private var compositePipeline: MTLRenderPipelineState?
    private var thickPipeline: MTLRenderPipelineState?
    private var depthWrite: MTLDepthStencilState?
    private var depthRead: MTLDepthStencilState?
    private var depthAlways: MTLDepthStencilState?
    /// The scene pass's textures, by size (a few sizes kept: the page's views and the editor's).
    private var targets: [String: (color: MTLTexture, ids: MTLTexture, depth: MTLTexture)] = [:]
    /// Why Metal couldn't start (no GPU, shaders that didn't build).
    private(set) var problem: String?

    private init() {
        device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        guard let device else { problem = "This Mac has no Metal GPU."; return }
        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            func pipeline(_ vertex: String, _ fragment: String, scene: Bool, blend: Bool = false) throws -> MTLRenderPipelineState {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = library.makeFunction(name: vertex)
                d.fragmentFunction = library.makeFunction(name: fragment)
                d.colorAttachments[0].pixelFormat = .bgra8Unorm
                if blend {
                    d.colorAttachments[0].isBlendingEnabled = true
                    d.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
                    d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                    d.colorAttachments[0].sourceAlphaBlendFactor = .one
                    d.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
                }
                if scene {
                    d.colorAttachments[1].pixelFormat = .r32Uint
                    if blend { d.colorAttachments[1].writeMask = [] }
                    d.depthAttachmentPixelFormat = .depth32Float
                }
                return try device.makeRenderPipelineState(descriptor: d)
            }
            modelPipeline = try pipeline("modelVertex", "modelFragment", scene: true)
            linePipeline = try pipeline("lineVertex", "lineFragment", scene: true, blend: true)
            thickPipeline = try pipeline("thickVertex", "lineFragment", scene: true, blend: true)
            compositePipeline = try pipeline("quadVertex", "compositeFragment", scene: false)
            func depth(_ compare: MTLCompareFunction, write: Bool) -> MTLDepthStencilState? {
                let d = MTLDepthStencilDescriptor()
                d.depthCompareFunction = compare
                d.isDepthWriteEnabled = write
                return device.makeDepthStencilState(descriptor: d)
            }
            depthWrite = depth(.lessEqual, write: true)
            depthRead = depth(.lessEqual, write: false)
            depthAlways = depth(.always, write: false)
        } catch {
            problem = "The 3D viewer couldn't start: \(error.localizedDescription)"
        }
    }

    var isReady: Bool { modelPipeline != nil && queue != nil }

    /// GPU copies of the bodies.
    func upload(_ bodies: [CADBody]) -> [CADGPUBody] {
        guard let device else { return [] }
        return bodies.compactMap { b in
            guard !b.vertices.isEmpty, let buffer = b.vertices.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: b.vertices.count, options: .storageModeShared) })
            else { return nil }
            let count = b.vertices.count / 28
            var indices: [UInt32] = []
            indices.reserveCapacity(count * 2)
            for t in stride(from: 0, to: count - 2, by: 3) {
                let i = UInt32(t)
                indices += [i, i + 1, i + 1, i + 2, i + 2, i]
            }
            let lines = indices.isEmpty ? nil : device.makeBuffer(bytes: indices, length: indices.count * 4, options: .storageModeShared)
            return CADGPUBody(id: b.id, buffer: buffer, count: count, lines: lines, color: SIMD4(Float(b.color.r), Float(b.color.g), Float(b.color.b), 1),
                              positions: b.positions, faces: b.faces)
        }
    }

    // MARK: Camera

    static func eye(_ c: CADCamera) -> SIMD3<Double> {
        let yaw = c.yaw * .pi / 180, pitch = c.pitch * .pi / 180
        return c.target + c.distance * SIMD3(cos(pitch) * cos(yaw), cos(pitch) * sin(yaw), sin(pitch))
    }

    static func viewMatrix(_ c: CADCamera) -> simd_double4x4 {
        let eye = eye(c)
        let f = simd_normalize(c.target - eye)
        var up = SIMD3<Double>(0, 0, 1)
        if abs(simd_dot(f, up)) > 0.999 { up = SIMD3(0, 1, 0) }
        let s = simd_normalize(simd_cross(f, up)), u = simd_cross(s, f)
        return simd_double4x4(rows: [SIMD4(s, -simd_dot(s, eye)), SIMD4(u, -simd_dot(u, eye)), SIMD4(-f, simd_dot(f, eye)), SIMD4(0, 0, 0, 1)])
    }

    static let fieldOfView = 32.0

    static func projection(_ c: CADCamera, aspect: Double, radius: Double) -> simd_double4x4 {
        let near = max(0.01, c.distance - radius * 3), far = c.distance + radius * 3 + 10
        if c.perspective {
            let near = max(c.distance * 0.02, 0.01)
            let y = 1 / tan(fieldOfView * .pi / 360), x = y / aspect
            return simd_double4x4(rows: [SIMD4(x, 0, 0, 0), SIMD4(0, y, 0, 0), SIMD4(0, 0, far / (near - far), far * near / (near - far)), SIMD4(0, 0, -1, 0)])
        }
        let h = c.distance * tan(fieldOfView * .pi / 360), w = h * aspect
        return simd_double4x4(rows: [SIMD4(1 / w, 0, 0, 0), SIMD4(0, 1 / h, 0, 0), SIMD4(0, 0, 1 / (near - far), near / (near - far)), SIMD4(0, 0, 0, 1)])
    }

    static func radius(_ scene: CADScene) -> Double {
        guard let b = scene.bounds else { return 100 }
        return max(10, simd_length(b.max - b.min) / 2 + simd_length((b.max + b.min) / 2 - scene.camera.target))
    }

    static func viewProjection(_ scene: CADScene, aspect: Double) -> simd_double4x4 {
        projection(scene.camera, aspect: aspect, radius: radius(scene)) * viewMatrix(scene.camera)
    }

    /// The camera that shows all of the model, from where it's looking now (in a view of that shape).
    static func fitted(_ camera: CADCamera, bounds: (min: SIMD3<Double>, max: SIMD3<Double>)?, aspect: Double = 1.6) -> CADCamera {
        var c = camera
        guard let b = bounds else { c.target = .zero; c.distance = 200; return c }
        c.target = (b.min + b.max) / 2
        let r = max(1, simd_length(b.max - b.min) / 2)
        // The field of view is vertical: a narrow view needs to stand further back.
        c.distance = r / sin(fieldOfView * .pi / 360) * 1.1 / min(1, max(0.2, aspect))
        return c
    }

    /// A ray into the scene through a point of the view (0…1 across, 0…1 down).
    static func ray(_ scene: CADScene, at p: CGPoint, aspect: Double) -> (origin: SIMD3<Double>, direction: SIMD3<Double>) {
        let inv = viewProjection(scene, aspect: aspect).inverse
        let x = Double(p.x) * 2 - 1, y = 1 - Double(p.y) * 2
        let near = inv * SIMD4(x, y, 0, 1), far = inv * SIMD4(x, y, 1, 1)
        let a = SIMD3(near.x, near.y, near.z) / near.w, b = SIMD3(far.x, far.y, far.z) / far.w
        return (a, simd_normalize(b - a))
    }

    /// The body (and face) under a point.
    static func pick(_ scene: CADScene, at p: CGPoint, aspect: Double) -> (body: UUID, face: UInt32, distance: Double)? {
        let r = ray(scene, at: p, aspect: aspect)
        let o = SIMD3<Float>(r.origin), d = SIMD3<Float>(r.direction)
        var best: (UUID, UInt32, Double)?
        for body in scene.bodies {
            let ps = body.positions
            var t = 0
            while t + 2 < ps.count {
                let e1 = ps[t + 1] - ps[t], e2 = ps[t + 2] - ps[t]
                let h = simd_cross(d, e2), a = simd_dot(e1, h)
                if abs(a) > 1e-9 {
                    let f = 1 / a, s = o - ps[t], u = f * simd_dot(s, h)
                    if u >= 0, u <= 1 {
                        let q = simd_cross(s, e1), v = f * simd_dot(d, q)
                        if v >= 0, u + v <= 1 {
                            let dist = Double(f * simd_dot(e2, q))
                            if dist > 0, best == nil || dist < best!.2 { best = (body.id, body.faces[t], dist) }
                        }
                    }
                }
                t += 3
            }
        }
        return best.map { (body: $0.0, face: $0.1, distance: $0.2) }
    }

    // MARK: Drawing

    private func makeTargets(_ size: CGSize) -> (color: MTLTexture, ids: MTLTexture, depth: MTLTexture)? {
        let key = "\(Int(size.width))x\(Int(size.height))"
        if let t = targets[key] { return t }
        guard let device else { return nil }
        func texture(_ format: MTLPixelFormat) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: Int(size.width), height: Int(size.height), mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        guard let c = texture(.bgra8Unorm), let i = texture(.r32Uint), let z = texture(.depth32Float) else { return nil }
        if targets.count >= 6 { targets.removeAll() }
        targets[key] = (c, i, z)
        return (c, i, z)
    }

    private func lines(_ scene: CADScene) -> [Float] {
        var v: [Float] = []
        func line(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD4<Float>) {
            v += [Float(a.x), Float(a.y), Float(a.z), c.x, c.y, c.z, c.w, Float(b.x), Float(b.y), Float(b.z), c.x, c.y, c.z, c.w]
        }
        guard scene.grid else { return v }
        // A grid on the ground, spaced to suit the model's size, with every fifth line darker.
        let r = Self.radius(scene)
        let step = pow(10, floor(log10(max(1, r / 4))))
        let extent = ceil(r * 1.6 / step) * step
        let centre = SIMD2(round(scene.camera.target.x / step) * step, round(scene.camera.target.y / step) * step)
        var k = -extent
        while k <= extent + 1e-9 {
            let major = abs((k + centre.x).truncatingRemainder(dividingBy: step * 5)) < 1e-6
            let color = SIMD4<Float>(0.45, 0.48, 0.55, major ? 0.32 : 0.14)
            line(SIMD3(centre.x + k, centre.y - extent, 0), SIMD3(centre.x + k, centre.y + extent, 0), color)
            let majorY = abs((k + centre.y).truncatingRemainder(dividingBy: step * 5)) < 1e-6
            line(SIMD3(centre.x - extent, centre.y + k, 0), SIMD3(centre.x + extent, centre.y + k, 0), SIMD4(0.45, 0.48, 0.55, majorY ? 0.32 : 0.14))
            k += step
        }
        // The axes from the origin.
        let a = extent * 0.5
        line(.zero, SIMD3(a, 0, 0), SIMD4(0.85, 0.25, 0.25, 0.9))
        line(.zero, SIMD3(0, a, 0), SIMD4(0.25, 0.65, 0.30, 0.9))
        line(.zero, SIMD3(0, 0, a), SIMD4(0.25, 0.40, 0.90, 0.9))
        return v
    }

    /// Draws the scene into a texture (the view's drawable, or a picture's).
    func draw(_ scene: CADScene, into output: MTLTexture, commandBuffer: MTLCommandBuffer) {
        let size = CGSize(width: output.width, height: output.height)
        guard let modelPipeline, let linePipeline, let compositePipeline, let t = makeTargets(size), size.width > 0, size.height > 0 else { return }
        let aspect = Double(size.width / size.height)
        let vp = floats(Self.viewProjection(scene, aspect: aspect))
        let view = floats(Self.viewMatrix(scene.camera))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = t.color
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[1].texture = t.ids
        pass.colorAttachments[1].loadAction = .clear
        pass.colorAttachments[1].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[1].storeAction = .store
        pass.depthAttachment.texture = t.depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .dontCare
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(modelPipeline)
        enc.setDepthStencilState(depthWrite)
        enc.setCullMode(.none)
        let mode: UInt32 = scene.display == .hiddenLine ? 2 : scene.display == .noShading ? 3 : 0
        let solidFaces = scene.display != .wireframe
        for body in scene.bodies where solidFaces {
            let highlight: Float = scene.selected.contains(body.id) ? 0.38 : scene.hovered == body.id ? 0.16 : 0
            var u = Uniforms(viewProjection: vp, view: view, color: body.color, highlight: highlight, mode: mode)
            enc.setVertexBuffer(body.buffer, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: body.count)
        }
        // The triangles' sides over them, closing cracks (same faces and colours; nothing new is drawn).
        enc.setDepthStencilState(depthRead)
        for body in scene.bodies where solidFaces {
            guard let lines = body.lines else { continue }
            let highlight: Float = scene.selected.contains(body.id) ? 0.38 : scene.hovered == body.id ? 0.16 : 0
            var u = Uniforms(viewProjection: vp, view: view, color: body.color, highlight: highlight, mode: mode)
            enc.setVertexBuffer(body.buffer, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.drawIndexedPrimitives(type: .line, indexCount: body.count * 2, indexType: .uint32, indexBuffer: lines, indexBufferOffset: 0)
        }
        // Faces picked (green) or under the pointer (yellow).
        if solidFaces, let device {
            for h in scene.faceHighlights where !h.vertices.isEmpty {
                guard let buffer = h.vertices.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: h.vertices.count, options: .storageModeShared) }) else { continue }
                enc.setRenderPipelineState(modelPipeline)
                enc.setDepthStencilState(depthRead)
                var u = Uniforms(viewProjection: vp, view: view, color: h.color, highlight: 0, mode: 4)
                enc.setVertexBuffer(buffer, offset: 0, index: 0)
                enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: h.vertices.count / 28)
            }
        }
        // Wide lines: edges picked, sketches, the wireframe.
        if let thickPipeline, let device, !scene.lines.isEmpty {
            enc.setRenderPipelineState(thickPipeline)
            for set in scene.lines where !set.segments.isEmpty {
                var data: [Float] = []
                data.reserveCapacity(set.segments.count * 72)
                let c = set.color
                for (a, b) in set.segments {
                    for (side, end) in [(Float(-1), Float(0)), (1, 0), (1, 1), (-1, 0), (1, 1), (-1, 1)] {
                        data += [a.x, a.y, a.z, b.x, b.y, b.z, side, end, c.x, c.y, c.z, c.w]
                    }
                }
                guard let buffer = device.makeBuffer(bytes: data, length: data.count * 4, options: .storageModeShared) else { continue }
                enc.setDepthStencilState(set.onTop ? depthAlways : depthRead)
                var u = Uniforms(viewProjection: vp, view: view, color: .one, highlight: 0, mode: 0)
                var screen = SIMD4<Float>(Float(size.width), Float(size.height), set.width * Float(max(1, size.width / 1000)), set.onTop ? 0 : 0.0004)
                enc.setVertexBuffer(buffer, offset: 0, index: 0)
                enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                enc.setVertexBytes(&screen, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: data.count / 12)
            }
        }
        // The grid and axes behind and among the bodies.
        var lineData = lines(scene)
        if !lineData.isEmpty, let device {
            enc.setRenderPipelineState(linePipeline)
            enc.setDepthStencilState(depthRead)
            var u = Uniforms(viewProjection: vp, view: view, color: .one, highlight: 0, mode: 0)
            if let buffer = device.makeBuffer(bytes: &lineData, length: lineData.count * 4, options: .storageModeShared) {
                enc.setVertexBuffer(buffer, offset: 0, index: 0)
                enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: lineData.count / 7)
            }
        }
        // The axis triad in the corner: the camera's turn only.
        if let device {
            let corner = min(size.width, size.height) * 0.16
            enc.setViewport(MTLViewport(originX: 6, originY: Double(size.height - corner - 6), width: Double(corner), height: Double(corner), znear: 0, zfar: 1))
            var c = scene.camera
            c.target = .zero
            c.distance = 4
            c.perspective = false
            var rot = Self.viewMatrix(c)
            rot.columns.3 = SIMD4(0, 0, -2, 1)
            let ortho = simd_double4x4(rows: [SIMD4(0.8, 0, 0, 0), SIMD4(0, 0.8, 0, 0), SIMD4(0, 0, -0.1, 0.5), SIMD4(0, 0, 0, 1)])
            var u = Uniforms(viewProjection: floats(ortho * rot), view: view, color: .one, highlight: 0, mode: 0)
            var triad: [Float] = [0, 0, 0, 0.85, 0.2, 0.2, 1, 1, 0, 0, 0.85, 0.2, 0.2, 1,
                                  0, 0, 0, 0.2, 0.6, 0.25, 1, 0, 1, 0, 0.2, 0.6, 0.25, 1,
                                  0, 0, 0, 0.2, 0.35, 0.9, 1, 0, 0, 1, 0.2, 0.35, 0.9, 1]
            if let buffer = device.makeBuffer(bytes: &triad, length: triad.count * 4, options: .storageModeShared) {
                enc.setRenderPipelineState(linePipeline)
                enc.setDepthStencilState(depthAlways)
                enc.setVertexBuffer(buffer, offset: 0, index: 0)
                enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: 6)
            }
        }
        enc.endEncoding()
        // The picture, the background and the edges.
        let out = MTLRenderPassDescriptor()
        out.colorAttachments[0].texture = output
        out.colorAttachments[0].loadAction = .dontCare
        out.colorAttachments[0].storeAction = .store
        guard let comp = commandBuffer.makeRenderCommandEncoder(descriptor: out) else { return }
        comp.setRenderPipelineState(compositePipeline)
        comp.setFragmentTexture(t.color, index: 0)
        comp.setFragmentTexture(t.ids, index: 1)
        var cu = CompositeUniforms(edges: scene.display == .shaded || scene.display == .wireframe ? 0 : 1, strength: scene.display == .hiddenLine ? 1 : 0.82,
                                   top: SIMD4(0.97, 0.975, 0.985, 1), bottom: SIMD4(0.84, 0.86, 0.90, 1))
        comp.setFragmentBytes(&cu, length: MemoryLayout<CompositeUniforms>.stride, index: 0)
        comp.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        comp.endEncoding()
    }

    /// A picture of the scene, drawn off screen (for the page when exported or printed, previews and copies).
    func image(_ scene: CADScene, size: CGSize, scale: CGFloat = 2) -> NSImage? {
        guard let device, let queue, isReady else { return nil }
        let w = max(1, Int(size.width * scale)), h = max(1, Int(size.height * scale))
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        guard let texture = device.makeTexture(descriptor: d), let buffer = device.makeBuffer(length: w * h * 4, options: .storageModeShared),
              let cb = queue.makeCommandBuffer() else { return nil }
        draw(scene, into: texture, commandBuffer: cb)
        if let blit = cb.makeBlitCommandEncoder() {
            blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: w, height: h, depth: 1),
                      to: buffer, destinationOffset: 0, destinationBytesPerRow: w * 4, destinationBytesPerImage: w * h * 4)
            blit.endEncoding()
        }
        cb.commit()
        cb.waitUntilCompleted()
        let data = Data(bytes: buffer.contents(), count: w * h * 4)
        guard let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return NSImage(cgImage: cg, size: size)
    }

    func commandBuffer() -> MTLCommandBuffer? { queue?.makeCommandBuffer() }
}
