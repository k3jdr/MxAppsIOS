//
//  EditorState.swift
//  MxJobsMGR
//
//  Per-window editing state (selection, zoom, open panels) and the diagram
//  layout metrics. Menu commands reach the focused window through FocusedValues.
//

import SwiftUI

nonisolated enum Metrics {
    static let laneHeight: CGFloat = 240
    /// Width of the lane title column on the left of the canvas.
    static let gutter: CGFloat = 170
    static let nodeSize = CGSize(width: 190, height: 78)
    static let grid: CGFloat = 10
    static let minCanvasWidth: CGFloat = 2200

    static func laneTop(_ layer: Layer) -> CGFloat { CGFloat(layer.rawValue - 1) * laneHeight }
    static func laneCenter(_ layer: Layer) -> CGFloat { laneTop(layer) + laneHeight / 2 }

    static func canvasSize(for space: Jobspace) -> CGSize {
        let maxX = space.nodes.map { CGFloat($0.x) }.max() ?? 0
        return CGSize(width: max(minCanvasWidth, maxX + 600), height: laneHeight * 3)
    }

    /// Keeps a node centre inside its own lane and right of the gutter, snapped to the grid.
    static func place(_ point: CGPoint, in layer: Layer) -> CGPoint {
        let halfW = nodeSize.width / 2, halfH = nodeSize.height / 2
        let top = laneTop(layer) + halfH + 14
        let bottom = laneTop(layer) + laneHeight - halfH - 14
        let x = max(gutter + halfW + 20, point.x)
        let y = min(max(point.y, top), bottom)
        return CGPoint(x: (x / grid).rounded() * grid, y: (y / grid).rounded() * grid)
    }

    static func layer(atY y: CGFloat) -> Layer {
        Layer(rawValue: min(3, max(1, Int(y / laneHeight) + 1))) ?? .operations
    }
}

extension Layer {
    var color: Color {
        switch self {
        case .operations: .indigo
        case .agents: .orange
        case .data: .teal
        }
    }
}

extension NodeKind {
    var color: Color { layer.color }
}

@Observable
final class EditorState {
    var selectedNodes: Set<UUID> = []
    var selectedLink: UUID?
    var zoom: CGFloat = 1
    var showInspector = true
    var showSubscriptions = false
    var showIssues = false
    /// Subscription to show first when the subscriptions dialog opens.
    var subscriptionToEdit: UUID?
    /// Bumped when API keys may have changed, so checks that read the Keychain run again.
    var keyRevision = 0
    var showConsole = false
    var consoleHeight: CGFloat = 230

    /// Runs and debugs this window's jobspace.
    let run = RunEngine()

    /// The window's document; set by ContentView so menu commands can edit it.
    @ObservationIgnored var document: Binding<JobspaceDocument>? {
        didSet { run.currentSpace = { [weak self] in self?.document?.wrappedValue.space } }
    }

    var hasSelection: Bool { !selectedNodes.isEmpty || selectedLink != nil }

    func select(node id: UUID, extending: Bool = false) {
        selectedLink = nil
        if extending {
            if selectedNodes.contains(id) { selectedNodes.remove(id) } else { selectedNodes.insert(id) }
        } else {
            selectedNodes = [id]
        }
    }

    func select(link id: UUID) {
        selectedNodes = []
        selectedLink = id
    }

    func clearSelection() {
        selectedNodes = []
        selectedLink = nil
    }

    // MARK: Commands

    func deleteSelection() {
        guard let document, hasSelection else { return }
        document.wrappedValue.space.delete(nodes: selectedNodes, links: selectedLink.map { [$0] } ?? [])
        clearSelection()
    }

    func duplicateSelection() {
        guard let document, !selectedNodes.isEmpty else { return }
        selectedNodes = document.wrappedValue.space.duplicate(selectedNodes)
    }

    func selectAll() {
        guard let document else { return }
        selectedLink = nil
        selectedNodes = Set(document.wrappedValue.space.nodes.map(\.id))
    }

    func nudge(dx: CGFloat, dy: CGFloat) {
        guard let document, !selectedNodes.isEmpty else { return }
        var space = document.wrappedValue.space
        for i in space.nodes.indices where selectedNodes.contains(space.nodes[i].id) {
            let p = Metrics.place(CGPoint(x: space.nodes[i].x + dx, y: space.nodes[i].y + dy), in: space.nodes[i].layer)
            space.nodes[i].x = p.x
            space.nodes[i].y = p.y
        }
        document.wrappedValue.space = space
    }

    /// Adds a node of `kind` in its lane, right of the nodes already there.
    func add(_ kind: NodeKind, at point: CGPoint? = nil) {
        guard let document else { return }
        let space = document.wrappedValue.space
        let laneNodes = space.nodes.filter { $0.layer == kind.layer }
        let fallback = CGPoint(
            x: (laneNodes.map { CGFloat($0.x) }.max() ?? Metrics.gutter) + Metrics.nodeSize.width + 50,
            y: Metrics.laneCenter(kind.layer))
        let p = Metrics.place(point ?? fallback, in: kind.layer)
        let node = JobNode(kind: kind, x: p.x, y: p.y)
        document.wrappedValue.space.nodes.append(node)
        selectedLink = nil
        selectedNodes = [node.id]
    }

    /// Adds a Layer 3 step calling a catalog service's endpoint, creating the service's subscription if needed.
    func addServiceStep(_ service: ServiceInfo, _ endpoint: ServiceEndpoint?) {
        guard let document else { return }
        var space = document.wrappedValue.space
        let sub: ApiSubscription
        if let existing = space.subscriptions.first(where: { ServiceAboutSection.service(for: $0)?.id == service.id }) {
            sub = existing
        } else {
            var new = ApiSubscription.localService(port: service.port)
            new.name = service.name
            new.provider = "\(service.language) service on this Mac (Services/\(service.folder))"
            new.projectFolder = service.projectPath
            new.notes = service.purpose + " Start it with: " + ServiceCatalog.startCommand
            space.subscriptions.append(new)
            sub = new
        }
        let laneNodes = space.nodes.filter { $0.layer == .data }
        let p = Metrics.place(CGPoint(x: (laneNodes.map { CGFloat($0.x) }.max() ?? Metrics.gutter) + Metrics.nodeSize.width + 50,
                                      y: Metrics.laneCenter(.data)), in: .data)
        let ep = endpoint ?? service.endpoints.first
        var node = JobNode(kind: .apiRead, title: ep?.summary ?? service.name, x: p.x, y: p.y)
        node.api?.subscriptionID = sub.id
        node.api?.method = ep?.method == "POST" ? .POST : .GET
        // "/quote?symbol=" → path /quote and an empty symbol parameter; "/refresh/{category}" keeps its placeholder.
        let raw = ep?.path ?? "/"
        let parts = raw.split(separator: "?", maxSplits: 1).map(String.init)
        node.api?.path = parts[0].replacingOccurrences(of: "{", with: "{{").replacingOccurrences(of: "}", with: "}}")
        if parts.count > 1 {
            node.api?.query = parts[1].split(separator: "&").map { KeyValue(String($0.split(separator: "=").first ?? ""), "") }
        }
        if node.api?.method == .POST, node.api?.body.isEmpty ?? true { node.api?.body = "{}" }
        node.notes = "\(service.name) (\(service.language)): \(ep?.summary ?? "")"
        node.outcome.successStatus = "200"
        space.nodes.append(node)
        document.wrappedValue.space = space
        selectedLink = nil
        selectedNodes = [node.id]
    }

    /// The editor of the jobspace window last in front (for the Services and Samples windows).
    static weak var lastActive: EditorState?

    // MARK: Run

    func startRun() {
        guard let space = document?.wrappedValue.space else { return }
        showConsole = true
        run.run(space)
    }

    func stepRun() {
        guard let space = document?.wrappedValue.space else { return }
        showConsole = true
        run.step(space)
    }

    /// Toggles the breakpoint on the selected steps.
    func toggleBreakpoint() {
        guard let document, !selectedNodes.isEmpty else { return }
        let space = document.wrappedValue.space
        let turnOn = !space.nodes.filter { selectedNodes.contains($0.id) }.allSatisfy(\.breakpoint)
        for i in space.nodes.indices where selectedNodes.contains(space.nodes[i].id) {
            document.wrappedValue.space.nodes[i].breakpoint = turnOn
        }
        if turnOn { document.wrappedValue.space.run.breakpointsEnabled = true }
    }

    func zoomIn() { zoom = min(2, (zoom + 0.1).rounded(toPlaces: 1)) }
    func zoomOut() { zoom = max(0.4, (zoom - 0.1).rounded(toPlaces: 1)) }
}

extension CGFloat {
    func rounded(toPlaces places: Int) -> CGFloat {
        let f = pow(10, CGFloat(places))
        return (self * f).rounded() / f
    }
}

extension FocusedValues {
    @Entry var editor: EditorState?
}
