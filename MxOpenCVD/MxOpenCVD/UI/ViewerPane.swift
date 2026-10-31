import AVFoundation
import SwiftUI

extension Verdict {
    var color: Color {
        switch self {
        case .pass: return .green
        case .fail: return .red
        case .info: return .secondary
        }
    }
}

struct ViewerPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var live: LiveState

    @State private var dragStart: CGPoint?
    @State private var dragEnd: CGPoint?
    @State private var focusMark: CGPoint?
    @State private var pointer: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            let imageRect = fitted(in: CGRect(origin: .zero, size: geometry.size))
            ZStack {
                FrameLayerView(display: model.display)
                overlayCanvas(imageRect: imageRect)
                    .allowsHitTesting(false)
                if model.isDrawingROI {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(roiGesture(imageRect: imageRect))
                        .onHover { inside in
                            if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
                        }
                } else if model.controls.supportsFocusPoint && model.frozenFrame == nil {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { location in focus(at: location, imageRect: imageRect) }
                }
                if let focusMark {
                    Circle()
                        .stroke(.yellow, lineWidth: 1.5)
                        .frame(width: 44, height: 44)
                        .position(focusMark)
                        .allowsHitTesting(false)
                }
                if live.imageSize == .zero {
                    placeholder
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let location) = phase { pointer = location } else { pointer = nil }
            }
            .quickHelpArea(quickHelp(imageRect: imageRect))
            .overlay(alignment: .topLeading) { verdictBadge.padding(12) }
            .overlay(alignment: .bottomLeading) { statusStrip.padding(10) }
            .overlay(alignment: .top) {
                if model.isDrawingROI {
                    Text("Drag across the image to draw the region")
                        .font(.callout)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 12)
                }
            }
        }
        .background(Color.black)
    }

    /// What a tool found under the pointer, and otherwise the image and the pixel there.
    private func quickHelp(imageRect: CGRect) -> QuickHelpItem {
        var pixel: CGPoint?
        if let pointer, imageRect.contains(pointer), imageRect.width > 0 {
            let scale = live.imageSize.width / imageRect.width
            pixel = CGPoint(x: (pointer.x - imageRect.minX) * scale, y: (pointer.y - imageRect.minY) * scale)
        }
        if let pixel, !model.isDrawingROI, let report = live.report, report.imageSize == live.imageSize,
           let found = AppQuickHelp.found(at: pixel, in: report, tolerance: max(3, live.imageSize.width / imageRect.width * 4)) {
            return found
        }
        return AppQuickHelp.image(pixel: pixel, imageSize: live.imageSize, isDrawing: model.isDrawingROI,
                                  sourceName: model.stillName ?? model.activeCamera?.name, isFrozen: model.frozenFrame != nil,
                                  canFocus: model.controls.supportsFocusPoint, scale: model.currentScale)
    }

    private func fitted(in bounds: CGRect) -> CGRect {
        guard live.imageSize.width > 0 else { return bounds }
        return AVMakeRect(aspectRatio: live.imageSize, insideRect: bounds)
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "camera.metering.unknown")
                .font(.system(size: 40))
            Text(model.cameraStatus)
                .multilineTextAlignment(.center)
            if model.cameraAccessDenied {
                Button("Open Privacy Settings") { model.openCameraPrivacySettings() }
            }
        }
        .foregroundStyle(.white.opacity(0.8))
        .padding()
    }

    @ViewBuilder
    private var verdictBadge: some View {
        if let report = live.report {
            Text(report.verdict.rawValue)
                .font(.system(size: report.verdict == .info ? 15 : 26, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(report.verdict == .info ? Color.gray.opacity(0.7) : report.verdict.color.opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var statusStrip: some View {
        HStack(spacing: 12) {
            if let still = model.stillName {
                Label(still, systemImage: "photo")
            } else if model.frozenFrame != nil {
                Label("Frozen", systemImage: "pause.circle.fill")
            } else if let camera = model.activeCamera {
                Label(camera.name, systemImage: camera.tier.symbol)
                if live.framesPerSecond > 0 {
                    Text(String(format: "%.0f fps", live.framesPerSecond))
                }
            }
            if live.imageSize.width > 0 {
                Text("\(Int(live.imageSize.width)) × \(Int(live.imageSize.height))")
            }
            if let report = live.report {
                Text(String(format: "%.0f ms", report.totalMs))
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.black.opacity(0.55), in: Capsule())
    }

    private func overlayCanvas(imageRect: CGRect) -> some View {
        Canvas { context, _ in
            let scale = live.imageSize.width > 0 ? imageRect.width / live.imageSize.width : 1
            func place(_ point: CGPoint) -> CGPoint {
                CGPoint(x: imageRect.minX + point.x * scale, y: imageRect.minY + point.y * scale)
            }

            if let report = live.report, report.imageSize == live.imageSize {
                for tool in report.tools {
                    for overlay in tool.output.overlays {
                        draw(overlay, in: &context, place: place)
                    }
                }
            }

            for tool in model.job.tools where tool.enabled {
                guard let area = tool.roi else { continue }
                let rect = CGRect(x: imageRect.minX + area.minX * imageRect.width,
                                  y: imageRect.minY + area.minY * imageRect.height,
                                  width: area.width * imageRect.width,
                                  height: area.height * imageRect.height)
                let selected = tool.id == model.selectedToolID
                context.stroke(Path(rect), with: .color(selected ? .accentColor : .white.opacity(0.45)),
                               style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: [6, 4]))
                drawLabel(tool.name, at: CGPoint(x: rect.minX, y: rect.minY - 2), color: selected ? .accentColor : .gray, in: &context)
            }

            if let start = dragStart, let end = dragEnd {
                context.stroke(Path(CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(start.x - end.x), height: abs(start.y - end.y))),
                               with: .color(.accentColor), lineWidth: 2)
            }
        }
    }

    private func draw(_ overlay: MXVOverlay, in context: inout GraphicsContext, place: (CGPoint) -> CGPoint) {
        let points = overlay.points.map { place($0.pointValue) }
        guard let first = points.first else { return }
        let color: Color
        switch overlay.style {
        case .good: color = .green
        case .bad: color = .red
        default: color = .yellow
        }
        var path = Path()
        path.addLines(points)
        if overlay.closed { path.closeSubpath() }
        context.stroke(path, with: .color(color), lineWidth: 1.5)
        if !overlay.label.isEmpty {
            let top = points.min { $0.y < $1.y } ?? first
            drawLabel(overlay.label, at: top, color: color, in: &context)
        }
    }

    private func drawLabel(_ text: String, at point: CGPoint, color: Color, in context: inout GraphicsContext) {
        let resolved = context.resolve(Text(text).font(.caption.weight(.semibold)).foregroundStyle(.white))
        let size = resolved.measure(in: CGSize(width: 400, height: 40))
        let box = CGRect(x: point.x, y: point.y - size.height - 3, width: size.width + 8, height: size.height + 3)
        context.fill(Path(roundedRect: box, cornerRadius: 3), with: .color(color.opacity(0.75)))
        context.draw(resolved, at: CGPoint(x: box.minX + 4, y: box.minY + 1.5), anchor: .topLeading)
    }

    private func roiGesture(imageRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                dragStart = clamp(value.startLocation, to: imageRect)
                dragEnd = clamp(value.location, to: imageRect)
            }
            .onEnded { value in
                let start = clamp(value.startLocation, to: imageRect)
                let end = clamp(value.location, to: imageRect)
                dragStart = nil
                dragEnd = nil
                model.isDrawingROI = false
                NSCursor.pop()
                guard imageRect.width > 0, imageRect.height > 0, abs(start.x - end.x) > 4, abs(start.y - end.y) > 4,
                      let index = model.job.tools.firstIndex(where: { $0.id == model.selectedToolID })
                else { return }
                model.job.tools[index].roi = CGRect(x: (min(start.x, end.x) - imageRect.minX) / imageRect.width,
                                                    y: (min(start.y, end.y) - imageRect.minY) / imageRect.height,
                                                    width: abs(start.x - end.x) / imageRect.width,
                                                    height: abs(start.y - end.y) / imageRect.height)
            }
    }

    private func clamp(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, rect.minX), rect.maxX), y: min(max(point.y, rect.minY), rect.maxY))
    }

    private func focus(at location: CGPoint, imageRect: CGRect) {
        guard imageRect.contains(location) else { return }
        model.focus(at: CGPoint(x: (location.x - imageRect.minX) / imageRect.width, y: (location.y - imageRect.minY) / imageRect.height))
        focusMark = location
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { focusMark = nil }
    }
}
