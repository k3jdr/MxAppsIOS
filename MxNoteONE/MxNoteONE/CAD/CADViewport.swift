//
//  CADViewport.swift
//  MxNoteONE
//
//  A Metal view of a model, drawn when something changes: drag to orbit, ⇧-drag (or right-drag) to pan, scroll or
//  pinch to zoom, twist to turn; a click picks a body — and the face or edge under the pointer (FreeCAD's
//  sub-elements), which is preselected as the pointer passes. FreeCAD's keys: 0 isometric, 1 front, 2 top, 3 right,
//  4 rear, 5 bottom, 6 left. Used on the page and in the 3D editor.
//

import AppKit
import MetalKit
import simd

/// A face or an edge of a body.
enum CADSubElement: Equatable {
    case face(UUID, UInt32)
    case edge(UUID, CADBodyEdge)

    var body: UUID {
        switch self {
        case .face(let b, _), .edge(let b, _): b
        }
    }
}

final class CADViewport: MTKView, MTKViewDelegate {
    var scene = CADScene() { didSet { needsDisplay = true } }
    /// Scrolling zooms (in the editor always; on the page once the model's been clicked).
    var scrollZooms = true
    var onPick: ((UUID?, UInt32?, NSEvent) -> Void)?
    var onDoubleClick: ((NSEvent) -> Void)?
    var onCameraChange: ((CADCamera) -> Void)?
    /// Hovering highlights the body under the pointer (editor).
    var hoverHighlights = false
    var onContextMenu: ((NSEvent) -> NSMenu?)?
    /// A body's edges (for picking them).
    var edgesOf: ((UUID) -> [CADBodyEdge])?
    var onPickElement: ((CADSubElement?, NSEvent) -> Void)?
    var onHoverElement: ((CADSubElement?) -> Void)?
    private var hoveredElement: CADSubElement?

    private var dragStart: NSPoint?
    private var dragged = false
    private var tracking: NSTrackingArea?
    private let fallback = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero, device: CADRenderer.shared.device)
        colorPixelFormat = .bgra8Unorm
        depthStencilPixelFormat = .invalid
        framebufferOnly = true
        isPaused = true
        enableSetNeedsDisplay = true
        autoResizeDrawable = true
        delegate = self
        if let problem = CADRenderer.shared.problem {
            fallback.stringValue = problem
            fallback.alignment = .center
            fallback.textColor = .secondaryLabelColor
            addSubview(fallback)
        }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        fallback.frame = bounds.insetBy(dx: 8, dy: bounds.height / 2 - 12)
    }

    // MARK: Drawing

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { needsDisplay = true }

    func draw(in view: MTKView) {
        guard CADRenderer.shared.isReady, let drawable = currentDrawable, let cb = CADRenderer.shared.commandBuffer() else { return }
        CADRenderer.shared.draw(scene, into: drawable.texture, commandBuffer: cb)
        cb.present(drawable)
        cb.commit()
    }

    private var aspect: Double { Double(max(1, bounds.width) / max(1, bounds.height)) }

    // MARK: Camera

    func setCamera(_ c: CADCamera, notify: Bool = true) {
        scene.camera = c
        if notify { onCameraChange?(c) }
    }

    func orbit(dx: CGFloat, dy: CGFloat) {
        var c = scene.camera
        c.yaw -= Double(dx) * 0.5
        c.pitch = max(-89.5, min(89.5, c.pitch + Double(dy) * 0.5))
        setCamera(c)
    }

    func pan(dx: CGFloat, dy: CGFloat) {
        var c = scene.camera
        let view = CADRenderer.viewMatrix(c)
        let right = SIMD3(view[0][0], view[1][0], view[2][0]), up = SIMD3(view[0][1], view[1][1], view[2][1])
        let perPoint = 2 * c.distance * tan(CADRenderer.fieldOfView * .pi / 360) / Double(max(1, bounds.height))
        c.target += (-right * Double(dx) + up * Double(dy)) * perPoint
        setCamera(c)
    }

    func zoom(by factor: Double) {
        var c = scene.camera
        c.distance = max(0.5, min(1e6, c.distance * factor))
        setCamera(c)
    }

    func fit() { setCamera(CADRenderer.fitted(scene.camera, bounds: scene.bounds, aspect: aspect)) }

    /// A standard view (yaw, pitch), then fitted.
    func look(yaw: Double, pitch: Double) {
        var c = scene.camera
        c.yaw = yaw
        c.pitch = pitch
        setCamera(CADRenderer.fitted(c, bounds: scene.bounds, aspect: aspect))
    }

    static let views: [(name: String, yaw: Double, pitch: Double)] = [
        ("Front", -90, 0), ("Rear", 90, 0), ("Right", 0, 0), ("Left", 180, 0), ("Top", -90, 89.5), ("Bottom", -90, -89.5), ("Isometric", -45, 35.264),
    ]

    // MARK: Mouse

    private func unit(_ p: NSPoint) -> CGPoint { CGPoint(x: p.x / max(1, bounds.width), y: p.y / max(1, bounds.height)) }

    func pick(at p: NSPoint) -> (body: UUID, face: UInt32, distance: Double)? {
        CADRenderer.pick(scene, at: unit(p), aspect: aspect)
    }

    /// Where a model point is in the view.
    func project(_ q: SIMD3<Double>) -> NSPoint? {
        let c = CADRenderer.viewProjection(scene, aspect: aspect) * SIMD4(q, 1)
        guard c.w > 1e-9 else { return nil }
        return NSPoint(x: (c.x / c.w + 1) / 2 * Double(bounds.width), y: (1 - c.y / c.w) / 2 * Double(bounds.height))
    }

    /// The edge (within a few points) or face under a point: what FreeCAD would select there.
    func element(at p: NSPoint) -> CADSubElement? {
        let hit = pick(at: p)
        if let edgesOf {
            let ray = CADRenderer.ray(scene, at: unit(p), aspect: aspect)
            let slack = CADRenderer.radius(scene) * 0.01 + 0.2
            var best: (UUID, CADBodyEdge, CGFloat)?
            let bodies = hit.map { h in scene.bodies.filter { $0.id == h.body } + scene.bodies.filter { $0.id != h.body } } ?? scene.bodies
            for body in bodies {
                for e in edgesOf(body.id) {
                    let pts = e.points + (e.closed && e.points.count > 2 ? [e.points[0]] : [])
                    var prev: (NSPoint, SIMD3<Double>)?
                    for q in pts {
                        guard let v = project(q) else { prev = nil; continue }
                        if let (pv, pq) = prev {
                            let ab = CGPoint(x: v.x - pv.x, y: v.y - pv.y), ap = CGPoint(x: p.x - pv.x, y: p.y - pv.y)
                            let t = max(0, min(1, (ab.x * ap.x + ab.y * ap.y) / max(1e-9, ab.x * ab.x + ab.y * ab.y)))
                            let d = hypot(pv.x + ab.x * t - p.x, pv.y + ab.y * t - p.y)
                            if d < 6, best == nil || d < best!.2 {
                                // Not behind the face that was hit: the depth where the pointer's ray passes the edge
                                // (in perspective, the place along it on screen isn't the place along it in space).
                                let ab3 = q - pq, w0 = pq - ray.origin
                                let a = simd_dot(ab3, ab3), b = simd_dot(ab3, ray.direction), dd = simd_dot(ab3, w0), ee = simd_dot(ray.direction, w0)
                                let denom = a - b * b
                                let u = denom > 1e-12 ? max(0, min(1, (b * ee - dd) / denom)) : Double(t)
                                let depth = simd_dot(pq + ab3 * u - ray.origin, ray.direction)
                                if hit == nil || depth <= hit!.distance + slack { best = (body.id, e, d) }
                            }
                        }
                        prev = (v, q)
                    }
                }
            }
            if let best { return .edge(best.0, best.1) }
        }
        return hit.map { .face($0.body, $0.face) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2, let onDoubleClick { onDoubleClick(event); return }
        dragStart = convert(event.locationInWindow, from: nil)
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        dragged = true
        if event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.option) {
            pan(dx: event.deltaX, dy: event.deltaY)
        } else if event.modifierFlags.contains(.control) {
            zoom(by: exp(Double(event.deltaY) * 0.01))
        } else {
            orbit(dx: event.deltaX, dy: event.deltaY)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        guard !dragged else { return }
        let p = convert(event.locationInWindow, from: nil)
        if let onPickElement {
            onPickElement(element(at: p), event)
            return
        }
        let hit = pick(at: p)
        onPick?(hit?.body, hit?.face, event)
    }

    override func keyDown(with event: NSEvent) {
        // FreeCAD's view keys.
        let views: [String: (Double, Double)] = ["0": (-45, 35.264), "1": (-90, 0), "2": (-90, 89.5), "3": (0, 0), "4": (90, 0), "5": (-90, -89.5), "6": (180, 0)]
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty, let c = event.charactersIgnoringModifiers {
            if let v = views[c] { look(yaw: v.0, pitch: v.1); return }
            if c == "f" { fit(); return }
        }
        super.keyDown(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) { dragged = true; pan(dx: event.deltaX, dy: event.deltaY) }
    override func otherMouseDragged(with event: NSEvent) { pan(dx: event.deltaX, dy: event.deltaY) }
    override func rightMouseDown(with event: NSEvent) { dragged = false }

    override func rightMouseUp(with event: NSEvent) {
        guard !dragged, let menu = onContextMenu?(event) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? { nil }

    override func scrollWheel(with event: NSEvent) {
        guard scrollZooms || window?.firstResponder === self else { return super.scrollWheel(with: event) }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
        zoom(by: exp(-Double(delta) * 0.008))
    }

    override func magnify(with event: NSEvent) { zoom(by: exp(-Double(event.magnification) * 1.4)) }
    override func rotate(with event: NSEvent) { orbit(dx: CGFloat(event.rotation) * 2, dy: 0) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        guard hoverHighlights else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard hoverHighlights else { return }
        let p = convert(event.locationInWindow, from: nil)
        if let onHoverElement {
            let e = element(at: p)
            if e != hoveredElement { hoveredElement = e; onHoverElement(e) }
            return
        }
        let hit = pick(at: p)?.body
        if hit != scene.hovered { scene.hovered = hit }
    }

    override func mouseExited(with event: NSEvent) {
        if scene.hovered != nil { scene.hovered = nil }
        if hoveredElement != nil { hoveredElement = nil; onHoverElement?(nil) }
    }

    /// A picture of what the view shows.
    func snapshot() -> NSImage? { CADRenderer.shared.image(scene, size: bounds.size) }
}
