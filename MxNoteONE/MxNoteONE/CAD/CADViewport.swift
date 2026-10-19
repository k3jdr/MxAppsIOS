//
//  CADViewport.swift
//  MxNoteONE
//
//  A Metal view of a model, drawn when something changes: drag to orbit, ⇧-drag (or right-drag) to pan, scroll or
//  pinch to zoom, twist to turn; a click picks a body. Used on the page and in the 3D editor.
//

import AppKit
import MetalKit

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
        ("Front", -90, 0), ("Back", 90, 0), ("Right", 0, 0), ("Left", 180, 0), ("Top", -90, 89.5), ("Bottom", -90, -89.5), ("Isometric", -45, 35.264),
    ]

    // MARK: Mouse

    private func unit(_ p: NSPoint) -> CGPoint { CGPoint(x: p.x / max(1, bounds.width), y: p.y / max(1, bounds.height)) }

    func pick(at p: NSPoint) -> (body: UUID, face: UInt32, distance: Double)? {
        CADRenderer.pick(scene, at: unit(p), aspect: aspect)
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
        let hit = pick(at: p)
        onPick?(hit?.body, hit?.face, event)
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
        let hit = pick(at: convert(event.locationInWindow, from: nil))?.body
        if hit != scene.hovered { scene.hovered = hit }
    }

    override func mouseExited(with event: NSEvent) {
        if scene.hovered != nil { scene.hovered = nil }
    }

    /// A picture of what the view shows.
    func snapshot() -> NSImage? { CADRenderer.shared.image(scene, size: bounds.size) }
}
