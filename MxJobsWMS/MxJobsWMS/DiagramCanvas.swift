//
//  DiagramCanvas.swift
//  MxJobsWMS
//
//  The draw.io-style editor: three horizontal lanes (one per layer), nodes that can be
//  dragged (they stay in their own lane and snap to a 10-point grid) and curved links.
//
//  - Drag palette items onto the canvas to add nodes.
//  - Drag a node's ● handle onto another node to link them.
//  - Click to select, ⇧-click to add to the selection, drag on empty canvas to rubber-band.
//  - Delete removes the selection, arrow keys nudge it (⇧ for 10× steps).
//

import SwiftUI

private let canvasSpace = "diagramCanvas"

struct LinkGeometry {
    var path: Path
    var start: CGPoint
    var end: CGPoint
    var control1: CGPoint
    var control2: CGPoint
    var mid: CGPoint
    var arrowAngle: CGFloat

    /// Bottom→top when the target lane is lower, top→bottom when higher, side to side within a lane.
    init(from a: CGPoint, to b: CGPoint) {
        let w = Metrics.nodeSize.width / 2, h = Metrics.nodeSize.height / 2
        let dy = b.y - a.y
        var c1: CGPoint, c2: CGPoint
        if dy > Metrics.nodeSize.height {
            start = CGPoint(x: a.x, y: a.y + h); end = CGPoint(x: b.x, y: b.y - h)
            let k = max(40, (end.y - start.y) / 2)
            c1 = CGPoint(x: start.x, y: start.y + k); c2 = CGPoint(x: end.x, y: end.y - k)
        } else if dy < -Metrics.nodeSize.height {
            start = CGPoint(x: a.x, y: a.y - h); end = CGPoint(x: b.x, y: b.y + h)
            let k = max(40, (start.y - end.y) / 2)
            c1 = CGPoint(x: start.x, y: start.y - k); c2 = CGPoint(x: end.x, y: end.y + k)
        } else {
            let right = b.x >= a.x
            start = CGPoint(x: a.x + (right ? w : -w), y: a.y)
            end = CGPoint(x: b.x + (right ? -w : w), y: b.y)
            let k = max(30, abs(end.x - start.x) / 2) * (right ? 1 : -1)
            c1 = CGPoint(x: start.x + k, y: start.y); c2 = CGPoint(x: end.x - k, y: end.y)
        }
        var p = Path()
        p.move(to: start)
        p.addCurve(to: end, control1: c1, control2: c2)
        path = p
        control1 = c1
        control2 = c2
        // Point at t = 0.5 on the cubic.
        mid = CGPoint(x: (start.x + 3 * c1.x + 3 * c2.x + end.x) / 8,
                      y: (start.y + 3 * c1.y + 3 * c2.y + end.y) / 8)
        arrowAngle = atan2(end.y - c2.y, end.x - c2.x)
    }

    var arrowHead: Path {
        var p = Path()
        let len: CGFloat = 11, spread: CGFloat = .pi / 7
        p.move(to: end)
        p.addLine(to: CGPoint(x: end.x - len * cos(arrowAngle - spread), y: end.y - len * sin(arrowAngle - spread)))
        p.addLine(to: CGPoint(x: end.x - len * cos(arrowAngle + spread), y: end.y - len * sin(arrowAngle + spread)))
        p.closeSubpath()
        return p
    }
}

private struct PendingLink: Equatable {
    var from: UUID
    var point: CGPoint
}

struct DiagramCanvas: View {
    @Binding var space: Jobspace
    @Bindable var editor: EditorState
    var issues: [ValidationIssue]

    @State private var dragOffset: CGSize = .zero
    @State private var draggingIDs: Set<UUID> = []
    @State private var pendingLink: PendingLink?
    @State private var rubberBand: CGRect?
    @State private var dropTargetLayer: Layer?
    /// The lane under the pointer, for Quick Help.
    @State private var hoverLane: Layer?
    @FocusState private var focused: Bool

    var body: some View {
        let size = Metrics.canvasSize(for: space)
        ScrollView([.horizontal, .vertical]) {
            DiagramContent(space: space, selectedNodes: editor.selectedNodes, selectedLink: editor.selectedLink,
                           issues: issues, runStates: editor.run.states, currentNode: editor.run.currentNode,
                           breakpointsEnabled: space.run.breakpointsEnabled,
                           size: size, position: position,
                           dropTargetLayer: dropTargetLayer, pendingLink: pendingLink, rubberBand: rubberBand,
                           nodeGesture: nodeGesture, handleGesture: handleGesture, onNodeTap: tapNode,
                           nodeMenu: nodeMenu)
                .background {
                    // Background interactions: click to select links / clear, drag to rubber-band.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(coordinateSpace: .named(canvasSpace)) { tapBackground(at: $0) }
                        .gesture(rubberBandGesture)
                }
                .onContinuousHover { phase in
                    var lane: Layer?
                    if case .active(let p) = phase { lane = Metrics.layer(atY: p.y) }
                    if lane != hoverLane { hoverLane = lane }
                }
                .quickHelpArea(JobsHelp.canvas(lane: hoverLane))
                .coordinateSpace(.named(canvasSpace))
                .contextMenu {
                    Button(editor.run.canContinue ? "Continue" : "Run") { editor.startRun() }
                        .disabled(editor.run.isActive && !editor.run.canContinue)
                    Button("Step") { editor.stepRun() }
                        .disabled(editor.run.phase == .running || editor.run.phase == .waiting)
                    Button("Stop") { editor.run.stop() }
                        .disabled(!editor.run.isActive)
                    Divider()
                    Button("Save as PNG…") { DiagramExport.savePNG(space: space) }
                    Button("Save as draw.io SVG…") { DiagramExport.saveDrawioSVG(space: space) }
                }
                .dropDestination(for: String.self) { items, location in
                    dropTargetLayer = nil
                    guard let raw = items.first, let kind = NodeKind(rawValue: raw) else { return false }
                    editor.add(kind, at: location)
                    focused = true
                    return true
                } isTargeted: { targeted in
                    if !targeted { dropTargetLayer = nil }
                }
                .scaleEffect(editor.zoom, anchor: .topLeading)
                .frame(width: size.width * editor.zoom, height: size.height * editor.zoom, alignment: .topLeading)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onDeleteCommand { editor.deleteSelection() }
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
            guard !editor.selectedNodes.isEmpty else { return .ignored }
            let step: CGFloat = press.modifiers.contains(.shift) ? 100 : Metrics.grid
            switch press.key {
            case .upArrow: editor.nudge(dx: 0, dy: -step)
            case .downArrow: editor.nudge(dx: 0, dy: step)
            case .leftArrow: editor.nudge(dx: -step, dy: 0)
            default: editor.nudge(dx: step, dy: 0)
            }
            return .handled
        }
        .onKeyPress(.escape) {
            editor.clearSelection()
            return .handled
        }
        .gesture(MagnifyGesture().onEnded { value in
            editor.zoom = min(2, max(0.4, (editor.zoom * value.magnification).rounded(toPlaces: 1)))
        })
        .onAppear { focused = true }
    }

    private func nodeMenu(_ node: JobNode) -> AnyView {
        AnyView(Group {
            Button(node.breakpoint ? "Remove Breakpoint" : "Add Breakpoint") {
                if !editor.selectedNodes.contains(node.id) { editor.select(node: node.id) }
                editor.toggleBreakpoint()
            }
            Button(node.enabled ? "Disable Step" : "Enable Step") {
                if let i = space.index(of: node.id) { space.nodes[i].enabled.toggle() }
            }
            Divider()
            Button("Duplicate") {
                if !editor.selectedNodes.contains(node.id) { editor.select(node: node.id) }
                editor.duplicateSelection()
            }
            Button("Delete") {
                if !editor.selectedNodes.contains(node.id) { editor.select(node: node.id) }
                editor.deleteSelection()
            }
        })
    }

    // MARK: Geometry

    private func position(_ node: JobNode) -> CGPoint {
        let base = CGPoint(x: node.x, y: node.y)
        guard draggingIDs.contains(node.id) else { return base }
        return CGPoint(x: base.x + dragOffset.width, y: base.y + dragOffset.height)
    }

    private func node(at point: CGPoint) -> JobNode? {
        space.nodes.last { node in
            let p = position(node)
            return CGRect(x: p.x - Metrics.nodeSize.width / 2, y: p.y - Metrics.nodeSize.height / 2,
                          width: Metrics.nodeSize.width, height: Metrics.nodeSize.height).contains(point)
        }
    }

    // MARK: Interaction

    private func tapNode(_ node: JobNode) {
        focused = true
        editor.select(node: node.id, extending: NSEvent.modifierFlags.contains(.shift))
    }

    private func tapBackground(at point: CGPoint) {
        focused = true
        for link in space.links.reversed() {
            guard let a = space.node(link.from), let b = space.node(link.to) else { continue }
            let g = LinkGeometry(from: position(a), to: position(b))
            if g.path.strokedPath(StrokeStyle(lineWidth: 12, lineCap: .round)).contains(point) {
                editor.select(link: link.id)
                return
            }
        }
        editor.clearSelection()
    }

    private func nodeGesture(_ node: JobNode) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(canvasSpace))
            .onChanged { value in
                if draggingIDs.isEmpty {
                    focused = true
                    if !editor.selectedNodes.contains(node.id) { editor.select(node: node.id) }
                    draggingIDs = editor.selectedNodes
                }
                dragOffset = value.translation
            }
            .onEnded { _ in
                var updated = space
                for i in updated.nodes.indices where draggingIDs.contains(updated.nodes[i].id) {
                    let n = updated.nodes[i]
                    let p = Metrics.place(CGPoint(x: n.x + dragOffset.width, y: n.y + dragOffset.height), in: n.layer)
                    updated.nodes[i].x = p.x
                    updated.nodes[i].y = p.y
                }
                draggingIDs = []
                dragOffset = .zero
                if updated != space { space = updated }
            }
    }

    private func handleGesture(_ node: JobNode) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(canvasSpace))
            .onChanged { value in
                pendingLink = PendingLink(from: node.id, point: value.location)
            }
            .onEnded { value in
                pendingLink = nil
                if let target = self.node(at: value.location), target.id != node.id,
                   let id = space.addLink(from: node.id, to: target.id) {
                    editor.select(link: id)
                }
            }
    }

    private var rubberBandGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(canvasSpace))
            .onChanged { value in
                focused = true
                rubberBand = CGRect(x: min(value.startLocation.x, value.location.x),
                                    y: min(value.startLocation.y, value.location.y),
                                    width: abs(value.location.x - value.startLocation.x),
                                    height: abs(value.location.y - value.startLocation.y))
            }
            .onEnded { _ in
                if let band = rubberBand {
                    let hits = space.nodes.filter { node in
                        CGRect(x: node.x - Metrics.nodeSize.width / 2, y: node.y - Metrics.nodeSize.height / 2,
                               width: Metrics.nodeSize.width, height: Metrics.nodeSize.height).intersects(band)
                    }
                    editor.selectedLink = nil
                    let extending = NSEvent.modifierFlags.contains(.shift)
                    editor.selectedNodes = (extending ? editor.selectedNodes : []).union(hits.map(\.id))
                }
                rubberBand = nil
            }
    }
}

/// Everything drawn on the canvas; also used (non-interactive) for image export.
struct DiagramContent<NG: Gesture, HG: Gesture>: View {
    var space: Jobspace
    var selectedNodes: Set<UUID>
    var selectedLink: UUID?
    var issues: [ValidationIssue]
    var runStates: [UUID: NodeRunState] = [:]
    var currentNode: UUID?
    var breakpointsEnabled = true
    var size: CGSize
    var position: (JobNode) -> CGPoint
    var dropTargetLayer: Layer?
    fileprivate var pendingLink: PendingLink?
    var rubberBand: CGRect?
    var nodeGesture: (JobNode) -> NG
    var handleGesture: (JobNode) -> HG
    var onNodeTap: (JobNode) -> Void
    var interactive = true
    /// Right-click menu of a node (canvas only).
    var nodeMenu: ((JobNode) -> AnyView)?

    var body: some View {
        ZStack(alignment: .topLeading) {
            LanesView(size: size, emptyLayers: Set(Layer.allCases).subtracting(space.nodes.map(\.layer)))
                .allowsHitTesting(false)

            linksLayer
                .allowsHitTesting(false)

            ForEach(space.nodes) { node in
                NodeView(node: node, space: space,
                         selected: selectedNodes.contains(node.id),
                         issue: issues.filter { $0.nodeID == node.id }.map(\.severity).max(),
                         runState: runStates[node.id],
                         isCurrent: currentNode == node.id,
                         breakpointsEnabled: breakpointsEnabled,
                         interactive: interactive,
                         handleGesture: handleGesture(node))
                    .position(position(node))
                    .onTapGesture { onNodeTap(node) }
                    .gesture(nodeGesture(node))
                    .contextMenu { if let nodeMenu { nodeMenu(node) } }
            }

            if let pendingLink, let from = space.node(pendingLink.from) {
                Path { p in
                    p.move(to: position(from))
                    p.addLine(to: pendingLink.point)
                }
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .allowsHitTesting(false)
            }

            if let rubberBand {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.08))
                    .stroke(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .frame(width: rubberBand.width, height: rubberBand.height)
                    .offset(x: rubberBand.minX, y: rubberBand.minY)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private var linksLayer: some View {
        Canvas { ctx, _ in
            for link in space.links {
                guard let a = space.node(link.from), let b = space.node(link.to) else { continue }
                let g = LinkGeometry(from: position(a), to: position(b))
                let selected = link.id == selectedLink
                // Calls go down the layers, results come back up (dashed).
                let upward = b.layer.rawValue < a.layer.rawValue
                let color: Color = selected ? .accentColor : (upward ? b.layer.color : a.layer.color).opacity(0.85)
                let style = StrokeStyle(lineWidth: selected ? 3 : 1.8, lineCap: .round,
                                        dash: upward ? [7, 5] : [])
                ctx.stroke(g.path, with: .color(color), style: style)
                ctx.fill(g.arrowHead, with: .color(color))
                if !link.label.isEmpty {
                    let text = ctx.resolve(Text(link.label).font(.caption).foregroundStyle(.secondary))
                    let s = text.measure(in: CGSize(width: 300, height: 40))
                    let r = CGRect(x: g.mid.x - s.width / 2 - 5, y: g.mid.y - s.height / 2 - 2,
                                   width: s.width + 10, height: s.height + 4)
                    ctx.fill(Path(roundedRect: r, cornerRadius: 4), with: .color(Color(nsColor: .textBackgroundColor)))
                    ctx.stroke(Path(roundedRect: r, cornerRadius: 4), with: .color(color.opacity(0.5)), lineWidth: 1)
                    ctx.draw(text, at: g.mid)
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

struct LanesView: View {
    var size: CGSize
    var emptyLayers: Set<Layer>

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Layer.allCases) { layer in
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(layer.color.opacity(layer.rawValue % 2 == 0 ? 0.07 : 0.045))
                    Rectangle()
                        .fill(layer.color.opacity(0.12))
                        .frame(width: Metrics.gutter)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("LAYER \(layer.rawValue)")
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(layer.color)
                        Text(layer.title)
                            .font(.headline)
                        Text(layer.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(width: Metrics.gutter - 24, alignment: .leading)
                    .padding(12)

                    if emptyLayers.contains(layer) {
                        Text("Drag \(layer.title.lowercased()) steps here from the palette")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, Metrics.gutter + 40)
                            .frame(maxHeight: .infinity)
                    }
                    Rectangle()
                        .fill(layer.color.opacity(0.35))
                        .frame(height: 1)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .frame(width: size.width, height: Metrics.laneHeight)
                .offset(y: Metrics.laneTop(layer))
            }
            GridDots(size: size)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

private struct GridDots: View {
    var size: CGSize
    var body: some View {
        Canvas { ctx, s in
            let step: CGFloat = 20
            var y: CGFloat = step
            while y < s.height {
                var x = Metrics.gutter + step
                while x < s.width {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5)),
                             with: .color(.secondary.opacity(0.25)))
                    x += step
                }
                y += step
            }
        }
        .frame(width: size.width, height: size.height)
    }
}
