import AppKit
import CoreVideo
import QuartzCore
import SwiftUI

/// Shows camera frames straight from their IOSurfaces, so the preview costs no copies.
final class FrameDisplay: @unchecked Sendable {
    let layer = CALayer()
    /// Called on the main queue.
    var onSizeChange: ((CGSize) -> Void)?

    private let lock = NSLock()
    private var pending: CVPixelBuffer?
    private var size = CGSize.zero

    init() {
        layer.contentsGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
    }

    /// From any queue. If the main thread is behind, the newest frame replaces the one still waiting.
    func present(_ buffer: CVPixelBuffer) {
        lock.lock()
        let alreadyScheduled = pending != nil
        pending = buffer
        lock.unlock()
        guard !alreadyScheduled else { return }
        DispatchQueue.main.async { [self] in
            lock.lock()
            let next = pending
            pending = nil
            lock.unlock()
            guard let next, let surface = CVPixelBufferGetIOSurface(next)?.takeUnretainedValue() else { return }
            show(surface, size: CGSize(width: CVPixelBufferGetWidth(next), height: CVPixelBufferGetHeight(next)))
        }
    }

    /// On the main queue. Replaces any camera frame still on its way, which would otherwise cover this image.
    func present(_ image: CGImage) {
        lock.lock()
        pending = nil
        lock.unlock()
        show(image, size: CGSize(width: image.width, height: image.height))
    }

    private func show(_ contents: Any, size newSize: CGSize) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = contents
        CATransaction.commit()
        if newSize != size {
            size = newSize
            onSizeChange?(newSize)
        }
    }
}

struct FrameLayerView: NSViewRepresentable {
    let display: FrameDisplay

    func makeNSView(context: Context) -> NSView {
        let view = LayerHostView()
        view.wantsLayer = true
        view.layer?.addSublayer(display.layer)
        view.hosted = display.layer
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class LayerHostView: NSView {
        var hosted: CALayer?

        // Only draws: clicks and the pointer belong to the SwiftUI views over it.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hosted?.frame = bounds
            CATransaction.commit()
        }
    }
}
