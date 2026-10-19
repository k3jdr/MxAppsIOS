//
//  CADEditor.swift
//  MxNoteONE
//
//  The 3D editor: a window for one model on a page. A toolbar (create primitives, sketch and extrude or revolve,
//  combine, pattern, mirror, view, import and export), the feature tree with the parameters, the Metal viewport (or
//  the sketch being drawn) and an inspector for what's selected. Every change is one undo step (⌘Z), is rebuilt at
//  once and goes back to the page.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import simd

// MARK: - The document

@Observable
final class CADDocument {
    private(set) var model: CADModel
    /// Selected features, in the order picked (a boolean's first is the body cut or joined).
    var selection: [UUID] = []
    var selectedParameter: UUID?
    var selectedEntity: UUID?
    private(set) var build = CADBuild()
    private(set) var gpu: [CADGPUBody] = []
    var camera: CADCamera
    /// The feature whose sketch is being drawn.
    private(set) var editingSketch: UUID?
    var sketchTool: CADSketchTool = .rectangle
    var polygonSides = 6
    var showGrid = true
    @ObservationIgnored let undoManager = UndoManager()
    @ObservationIgnored private let builder = CADBuilder()
    @ObservationIgnored var onChange: ((CADModel) -> Void)?
    @ObservationIgnored weak var viewport: CADViewport?
    @ObservationIgnored weak var sketchView: CADSketchView?

    init(model: CADModel) {
        self.model = model
        var c = CADCamera()
        c.yaw = -45
        c.pitch = 30
        camera = c
        rebuild()
        camera = CADRenderer.fitted(c, bounds: build.bounds)
    }

    // MARK: Changes

    /// One undoable change to the model.
    func perform(_ name: String, _ change: (inout CADModel) -> Void) {
        var m = model
        change(&m)
        guard m != model else { return }
        set(m, name: name)
    }

    private func set(_ m: CADModel, name: String) {
        let old = model
        undoManager.registerUndo(withTarget: self) { $0.set(old, name: name) }
        undoManager.setActionName(name)
        model = m
        // What's selected may be gone.
        selection = selection.filter { id in m.features.contains { $0.id == id } }
        if let p = selectedParameter, !m.parameters.contains(where: { $0.id == p }) { selectedParameter = nil }
        if let s = editingSketch, m.feature(s)?.sketch == nil { editingSketch = nil }
        rebuild()
        onChange?(m)
    }

    func rebuild() {
        build = builder.build(model)
        gpu = CADRenderer.shared.upload(build.bodies)
    }

    var selectedFeature: CADFeature? { selection.last.flatMap(model.feature) }
    /// Selected bodies on show (what booleans and patterns can use), in the order picked.
    var selectedBodies: [UUID] { selection.filter { id in build.bodies.contains { $0.id == id } } }

    func select(_ id: UUID?, extend: Bool = false) {
        selectedParameter = nil
        guard let id else { if !extend { selection = [] }; return }
        if extend {
            if let i = selection.firstIndex(of: id) { selection.remove(at: i) } else { selection.append(id) }
        } else {
            selection = [id]
        }
    }

    // MARK: Commands

    func add(_ kind: CADFeature.Kind) {
        var newID: UUID?
        perform("Add \(kind.title)") { m in
            var f = m.make(kind)
            f.color = CADColor.palette[m.features.count % CADColor.palette.count]
            m.features.append(f)
            newID = f.id
        }
        selection = newID.map { [$0] } ?? []
    }

    /// A new sketch on a plane, to extrude or revolve — drawn at once.
    func addSketch(_ kind: CADFeature.Kind, on plane: CADSketch.Plane) {
        var newID: UUID?
        perform("New Sketch") { m in
            var f = m.make(kind, name: m.uniqueName(kind == .revolve ? "Revolve" : "Extrude"))
            f.sketch = CADSketch(plane: plane)
            f.color = CADColor.palette[m.features.count % CADColor.palette.count]
            m.features.append(f)
            newID = f.id
        }
        if let newID { selection = [newID]; editSketch(newID) }
    }

    /// Union, Subtract or Intersect of the selected bodies (the first picked is cut or joined).
    func combine(_ kind: CADFeature.Kind) {
        let bodies = selectedBodies
        guard bodies.count >= 2 else { NSSound.beep(); return }
        var newID: UUID?
        perform(kind.title) { m in
            var f = m.make(kind)
            f.inputs = bodies
            f.color = m.feature(bodies[0])?.color
            m.features.append(f)
            newID = f.id
        }
        selection = newID.map { [$0] } ?? []
    }

    /// A linear or circular pattern, or a mirror, of the selected body.
    func pattern(_ kind: CADFeature.Kind) {
        guard let body = selectedBodies.last else { NSSound.beep(); return }
        var newID: UUID?
        perform(kind.title) { m in
            var f = m.make(kind)
            f.inputs = [body]
            f.color = m.feature(body)?.color
            m.features.append(f)
            newID = f.id
        }
        selection = newID.map { [$0] } ?? []
    }

    func deleteSelected() {
        let ids = Set(selection)
        guard !ids.isEmpty else { NSSound.beep(); return }
        perform(ids.count == 1 ? "Delete \(selectedFeature?.name ?? "Feature")" : "Delete Features") { m in
            m.features.removeAll { ids.contains($0.id) }
            for i in m.features.indices { m.features[i].inputs = m.features[i].inputs?.filter { !ids.contains($0) } }
        }
        selection = []
    }

    func duplicateSelected() {
        let ids = selection.filter { model.feature($0)?.kind.isPlaced == true }
        guard !ids.isEmpty else { NSSound.beep(); return }
        var copies: [UUID] = []
        perform("Duplicate") { m in
            for id in ids {
                guard var f = m.feature(id) else { continue }
                f.id = UUID()
                f.name = m.uniqueName(f.name)
                f.serial = m.nextSerial
                m.nextSerial += 1
                f.placement.x = "(\(f.placement.x)) + 10"
                m.features.append(f)
                copies.append(f.id)
            }
        }
        selection = copies
    }

    func update(_ id: UUID, _ name: String, _ change: (inout CADFeature) -> Void) {
        perform(name) { m in
            guard let i = m.features.firstIndex(where: { $0.id == id }) else { return }
            change(&m.features[i])
        }
    }

    func setValue(_ id: UUID, _ key: String, _ text: String) {
        update(id, "Change \(CADFeature.fields(model.feature(id)?.kind ?? .box).first { $0.key == key }?.label ?? key)") { $0.values[key] = text }
    }

    func toggleHidden(_ id: UUID) { update(id, "Hide or Show") { $0.hidden = $0.hidden == true ? nil : true } }

    // MARK: Parameters

    func addParameter() {
        let names = Set(model.parameters.map(\.name))
        var n = 1
        while names.contains("p\(n)") { n += 1 }
        let p = CADParameter(name: "p\(n)", expression: "10")
        perform("Add Parameter") { $0.parameters.append(p) }
        selection = []
        selectedParameter = p.id
    }

    func setParameter(_ id: UUID, name: String? = nil, expression: String? = nil) {
        perform("Change Parameter") { m in
            guard let i = m.parameters.firstIndex(where: { $0.id == id }) else { return }
            let old = m.parameters[i].name
            if let name, !name.isEmpty, name != old {
                m.parameters[i].name = name
                // Expressions that used the old name use the new one.
                func renamed(_ s: String) -> String { s.replacingOccurrences(of: "\\b\(NSRegularExpression.escapedPattern(for: old))\\b", with: name, options: .regularExpression) }
                for j in m.parameters.indices { m.parameters[j].expression = renamed(m.parameters[j].expression) }
                for j in m.features.indices {
                    m.features[j].values = m.features[j].values.mapValues(renamed)
                    let p = m.features[j].placement
                    m.features[j].placement = CADPlacement(x: renamed(p.x), y: renamed(p.y), z: renamed(p.z), rx: renamed(p.rx), ry: renamed(p.ry), rz: renamed(p.rz))
                    if let offset = m.features[j].sketch?.offset { m.features[j].sketch?.offset = renamed(offset) }
                }
            }
            if let expression { m.parameters[i].expression = expression }
        }
    }

    func removeParameter(_ id: UUID) {
        perform("Delete Parameter") { $0.parameters.removeAll { $0.id == id } }
        selectedParameter = nil
    }

    func setModel(_ name: String? = nil, smoothness: Int? = nil, display: CADDisplay? = nil) {
        perform("Change Model") { m in
            if let name, !name.isEmpty { m.name = name }
            if let smoothness { m.smoothness = max(12, min(256, smoothness)) }
            if let display { m.display = display }
        }
    }

    // MARK: Sketches

    func editSketch(_ id: UUID) {
        guard model.feature(id)?.sketch != nil else { return }
        editingSketch = id
        selectedEntity = nil
    }

    func finishSketch() {
        editingSketch = nil
        selectedEntity = nil
    }

    var editedSketch: CADSketch? { editingSketch.flatMap(model.feature)?.sketch }

    func addEntity(_ e: CADSketchEntity) {
        guard let id = editingSketch else { return }
        update(id, "Add \(e.kind.title)") { $0.sketch?.entities.append(e) }
    }

    func updateEntity(_ e: CADSketchEntity) {
        guard let id = editingSketch else { return }
        update(id, "Change \(e.kind.title)") { f in
            if let i = f.sketch?.entities.firstIndex(where: { $0.id == e.id }) { f.sketch?.entities[i] = e }
        }
    }

    func removeEntity(_ entityID: UUID) {
        guard let id = editingSketch else { return }
        update(id, "Delete Shape") { $0.sketch?.entities.removeAll { $0.id == entityID } }
        if selectedEntity == entityID { selectedEntity = nil }
    }

    // MARK: Files

    func importMesh() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["stl", "obj"].compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url),
              let triangles = CADExchange.triangles(from: data, ext: url.pathExtension) else { return }
        var newID: UUID?
        perform("Import \(url.lastPathComponent)") { m in
            var f = m.make(.mesh, name: m.uniqueName(url.deletingPathExtension().lastPathComponent))
            f.meshData = triangles.withUnsafeBufferPointer { Data(buffer: $0) }
            f.color = CADColor.palette[m.features.count % CADColor.palette.count]
            m.features.append(f)
            newID = f.id
        }
        selection = newID.map { [$0] } ?? []
    }

    func export(obj: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: obj ? "obj" : "stl") ?? .data]
        panel.nameFieldStringValue = model.name + (obj ? ".obj" : ".stl")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // The selected bodies, else all of them.
        let chosen = build.bodies.filter { selection.contains($0.id) }
        let bodies = chosen.isEmpty ? build.bodies : chosen
        let data = obj ? Data(CADExchange.obj(bodies, name: model.name).utf8) : CADExchange.stl(bodies, name: model.name)
        do { try data.write(to: url) } catch { NotebookStore.shared.report("Couldn't save \(url.lastPathComponent).", error) }
    }

    // MARK: Measures

    /// Volume, area and size of the selected bodies (or all).
    var measures: (volume: Double, area: Double, size: SIMD3<Double>)? {
        let chosen = build.bodies.filter { selection.contains($0.id) }
        let bodies = chosen.isEmpty ? build.bodies : chosen
        guard let first = bodies.first else { return nil }
        let b = bodies.dropFirst().reduce(first.bounds) { (simd_min($0.min, $1.bounds.min), simd_max($0.max, $1.bounds.max)) }
        return (bodies.reduce(0) { $0 + $1.solid.volume }, bodies.reduce(0) { $0 + $1.solid.area }, b.max - b.min)
    }

    /// A row of the feature tree: a feature and the features it's built from.
    struct Node: Identifiable {
        let feature: CADFeature
        let children: [Node]?
        var id: UUID { feature.id }
    }

    var tree: [Node] {
        let consumed = model.consumed()
        func node(_ f: CADFeature) -> Node {
            let kids = (f.inputs ?? []).compactMap(model.feature).map(node)
            return Node(feature: f, children: kids.isEmpty ? nil : kids)
        }
        return model.features.filter { !consumed.contains($0.id) }.map(node)
    }
}

// MARK: - The window

final class CADEditor: NSWindowController, NSWindowDelegate {
    private static var open: [UUID: CADEditor] = [:]
    let elementID: UUID
    let ref: PageRef
    let doc: CADDocument
    private var pendingSave: DispatchWorkItem?

    static func isOpen(_ id: UUID) -> Bool { open[id] != nil }

    /// Opens (or brings forward) the editor for a model on the page.
    @discardableResult
    static func open(_ view: CADElementView) -> CADEditor? {
        guard let ref = view.controller?.ref else { return nil }
        if let editor = open[view.element.id] {
            editor.window?.makeKeyAndOrderFront(nil)
            return editor
        }
        let editor = CADEditor(elementID: view.element.id, ref: ref, model: view.model)
        open[view.element.id] = editor
        editor.showWindow(nil)
        return editor
    }

    init(elementID: UUID, ref: PageRef, model: CADModel) {
        self.elementID = elementID
        self.ref = ref
        doc = CADDocument(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(model.name) — 3D Model"
        window.setFrameAutosaveName("CADEditor")
        if !window.setFrameUsingName("CADEditor") { window.center() }
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 900, height: 560)
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: CADEditorView(doc: doc))
        doc.onChange = { [weak self] model in
            self?.window?.title = "\(model.name) — 3D Model"
            self?.scheduleSave()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { doc.undoManager }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Self.store(self.doc.model, elementID: self.elementID, ref: self.ref)
            self.pendingSave = nil
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// Puts the model back on its page (on screen at once, else in the background).
    static func store(_ model: CADModel, elementID: UUID, ref: PageRef) {
        let store = NotebookStore.shared
        if store.canvas?.ref == ref, let view = store.canvas?.canvas.elementViews.compactMap({ $0 as? CADElementView }).first(where: { $0.element.id == elementID }) {
            var m = model
            m.camera = view.model.camera
            view.apply(m)
        } else if var content = store.loadPage(ref), let i = content.elements.firstIndex(where: { $0.id == elementID }) {
            var m = model
            m.camera = content.elements[i].cad?.camera
            content.elements[i].cad = m
            let index = PageIndexer.index(elements: content.elements)
            store.savePage(content, ref: ref, plainText: index.text, tags: index.tags)
        }
    }

    func windowWillClose(_ notification: Notification) {
        pendingSave?.perform()
        CADEditor.open[elementID] = nil
    }
}

// MARK: - Views

private func symbol(_ name: String) -> String {
    NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil ? name : "square.dashed"
}

struct CADEditorView: View {
    @Bindable var doc: CADDocument

    var body: some View {
        VStack(spacing: 0) {
            CADToolbar(doc: doc)
            Divider()
            HSplitView {
                CADTree(doc: doc)
                    .frame(minWidth: 190, idealWidth: 220, maxWidth: 300)
                CADCentre(doc: doc)
                    .frame(minWidth: 420, maxWidth: .infinity)
                    .layoutPriority(1)
                CADInspector(doc: doc)
                    .frame(minWidth: 250, idealWidth: 270, maxWidth: 330)
            }
            Divider()
            CADStatusBar(doc: doc)
        }
    }
}

private struct ToolButton: View {
    let title: String
    let symbolName: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol(symbolName)).font(.system(size: 16)).frame(height: 20)
                Text(title).font(.system(size: 10)).lineLimit(1)
            }
            .frame(minWidth: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(disabled)
        .help(title)
    }
}

private struct ToolGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 2) { content }
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
    }
}

private struct CADToolbar: View {
    @Bindable var doc: CADDocument

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 0) {
                ToolGroup(title: "Create") {
                    ForEach([CADFeature.Kind.box, .cylinder, .cone, .sphere, .torus, .wedge, .prism], id: \.self) { kind in
                        ToolButton(title: kind.title, symbolName: kind.symbol) { doc.add(kind) }
                    }
                }
                Divider().frame(height: 46)
                ToolGroup(title: "Sketch") {
                    Menu {
                        ForEach(CADSketch.Plane.allCases, id: \.self) { plane in Button("On \(plane.title)") { doc.addSketch(.extrude, on: plane) } }
                    } label: { Label("Extrude", systemImage: symbol(CADFeature.Kind.extrude.symbol)) }
                        .menuStyle(.borderlessButton).frame(width: 92)
                        .help("Draw a sketch and extrude it")
                    Menu {
                        ForEach(CADSketch.Plane.allCases, id: \.self) { plane in Button("On \(plane.title)") { doc.addSketch(.revolve, on: plane) } }
                    } label: { Label("Revolve", systemImage: symbol(CADFeature.Kind.revolve.symbol)) }
                        .menuStyle(.borderlessButton).frame(width: 92)
                        .help("Draw a profile and revolve it round the sketch's vertical axis")
                }
                Divider().frame(height: 46)
                ToolGroup(title: "Combine") {
                    ForEach([CADFeature.Kind.union, .subtract, .intersect], id: \.self) { kind in
                        ToolButton(title: kind.title, symbolName: kind.symbol, disabled: doc.selectedBodies.count < 2) { doc.combine(kind) }
                    }
                }
                Divider().frame(height: 46)
                ToolGroup(title: "Pattern") {
                    ToolButton(title: "Linear", symbolName: CADFeature.Kind.linearPattern.symbol, disabled: doc.selectedBodies.isEmpty) { doc.pattern(.linearPattern) }
                    ToolButton(title: "Circular", symbolName: CADFeature.Kind.circularPattern.symbol, disabled: doc.selectedBodies.isEmpty) { doc.pattern(.circularPattern) }
                    ToolButton(title: "Mirror", symbolName: CADFeature.Kind.mirror.symbol, disabled: doc.selectedBodies.isEmpty) { doc.pattern(.mirror) }
                }
                Divider().frame(height: 46)
                ToolGroup(title: "Edit") {
                    ToolButton(title: "Duplicate", symbolName: "plus.square.on.square", disabled: doc.selection.isEmpty) { doc.duplicateSelected() }
                        .keyboardShortcut("d", modifiers: .command)
                    ToolButton(title: "Delete", symbolName: "trash", disabled: doc.selection.isEmpty) { doc.deleteSelected() }
                        .keyboardShortcut(.delete, modifiers: .command)
                }
                Divider().frame(height: 46)
                ToolGroup(title: "View") {
                    ToolButton(title: "Fit", symbolName: "arrow.up.left.and.down.right.magnifyingglass") { doc.viewport?.fit() }
                    Menu {
                        ForEach(CADViewport.views, id: \.name) { v in Button(v.name) { doc.viewport?.look(yaw: v.yaw, pitch: v.pitch) } }
                    } label: { Label("Views", systemImage: "cube.transparent") }
                        .menuStyle(.borderlessButton).frame(width: 84)
                    Menu {
                        ForEach(CADDisplay.allCases, id: \.self) { d in
                            Button { doc.setModel(display: d) } label: { if (doc.model.display ?? .shadedEdges) == d { Label(d.rawValue, systemImage: "checkmark") } else { Text(d.rawValue) } }
                        }
                        Divider()
                        Toggle("Perspective", isOn: Binding(get: { doc.camera.perspective }, set: { p in var c = doc.camera; c.perspective = p; doc.viewport?.setCamera(c) }))
                        Toggle("Grid", isOn: $doc.showGrid)
                    } label: { Label("Display", systemImage: "circle.lefthalf.filled") }
                        .menuStyle(.borderlessButton).frame(width: 92)
                }
                Divider().frame(height: 46)
                ToolGroup(title: "File") {
                    ToolButton(title: "Import", symbolName: "square.and.arrow.down") { doc.importMesh() }
                    ToolButton(title: "STL", symbolName: "square.and.arrow.up") { doc.export(obj: false) }
                    ToolButton(title: "OBJ", symbolName: "square.and.arrow.up.on.square") { doc.export(obj: true) }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
        }
        .background(.background.secondary)
    }
}

private struct CADTree: View {
    @Bindable var doc: CADDocument

    private var selection: Binding<Set<UUID>> {
        Binding(get: {
            Set(doc.selection + (doc.selectedParameter.map { [$0] } ?? []))
        }, set: { new in
            if let p = new.first(where: { id in doc.model.parameters.contains { $0.id == id } }), new.count == 1 {
                doc.selection = []
                doc.selectedParameter = p
                return
            }
            doc.selectedParameter = nil
            let features = new.filter { id in doc.model.features.contains { $0.id == id } }
            doc.selection = doc.selection.filter { features.contains($0) } + features.filter { !doc.selection.contains($0) }
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: selection) {
                Section("Parameters") {
                    ForEach(doc.model.parameters) { p in
                        HStack {
                            Image(systemName: "function").foregroundStyle(.secondary)
                            Text(p.name)
                            Spacer()
                            if doc.build.parameterErrors[p.id] != nil {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            } else {
                                Text(doc.build.parameterValues[p.name].map { CADInspector.format($0) } ?? "").foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        .tag(p.id)
                    }
                }
                Section("Features") {
                    OutlineGroup(doc.tree, children: \.children) { node in
                        FeatureRow(doc: doc, feature: node.feature).tag(node.id)
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack {
                Button { doc.addParameter() } label: { Label("Parameter", systemImage: "plus") }
                    .buttonStyle(.borderless)
                Spacer()
                Text("\(doc.model.features.count) features").font(.caption).foregroundStyle(.secondary)
            }
            .padding(6)
        }
    }
}

private struct FeatureRow: View {
    let doc: CADDocument
    let feature: CADFeature

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol(feature.kind.symbol))
                .foregroundStyle(Color(red: feature.color?.r ?? 0.5, green: feature.color?.g ?? 0.5, blue: feature.color?.b ?? 0.55))
                .frame(width: 18)
            Text(feature.name).foregroundStyle(feature.hidden == true ? .secondary : .primary)
            Spacer()
            if doc.build.errors[feature.id] != nil {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(doc.build.errors[feature.id] ?? "")
            }
            if feature.hidden == true { Image(systemName: "eye.slash").foregroundStyle(.secondary) }
        }
        .contextMenu {
            if feature.sketch != nil { Button("Edit Sketch") { doc.editSketch(feature.id) } }
            Button(feature.hidden == true ? "Show" : "Hide") { doc.toggleHidden(feature.id) }
            Button("Duplicate") { doc.select(feature.id); doc.duplicateSelected() }
            Divider()
            Button("Delete") { doc.select(feature.id); doc.deleteSelected() }
        }
    }
}

private struct CADCentre: View {
    @Bindable var doc: CADDocument

    var body: some View {
        if let id = doc.editingSketch, let sketch = doc.editedSketch {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Picker("", selection: $doc.sketchTool) {
                        ForEach(CADSketchTool.allCases) { t in Label(t.rawValue, systemImage: symbol(t.symbol)).tag(t) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 520)
                    if doc.sketchTool == .polygon {
                        Stepper("\(doc.polygonSides) sides", value: $doc.polygonSides, in: 3...24).fixedSize()
                    }
                    Spacer()
                    Button("Fit") { doc.sketchView?.fit() }
                    Button("Finish Sketch") { doc.finishSketch() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                }
                .padding(8)
                Divider()
                CADSketchRepresentable(doc: doc, sketch: sketch, featureID: id)
            }
        } else {
            CADViewportRepresentable(doc: doc)
                .overlay(alignment: .bottomTrailing) {
                    if let problem = CADRenderer.shared.problem { Text(problem).padding().foregroundStyle(.secondary) }
                }
        }
    }
}

private struct CADViewportRepresentable: NSViewRepresentable {
    let doc: CADDocument

    func makeNSView(context: Context) -> CADViewport {
        let v = CADViewport()
        v.hoverHighlights = true
        v.scrollZooms = true
        doc.viewport = v
        // Fitted to the view's real shape once it has one.
        DispatchQueue.main.async { [weak v] in v?.fit() }
        v.onPick = { [weak doc] id, _, event in
            guard let doc else { return }
            doc.select(id, extend: event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command))
        }
        v.onCameraChange = { [weak doc] c in doc?.camera = c }
        v.onDoubleClick = { [weak doc, weak v] event in
            guard let doc, let v else { return }
            // Double-click a sketched body: edit its sketch; empty space: fit.
            if let hit = v.pick(at: v.convert(event.locationInWindow, from: nil))?.body, doc.model.feature(hit)?.sketch != nil {
                doc.select(hit)
                doc.editSketch(hit)
            } else {
                v.fit()
            }
        }
        return v
    }

    func updateNSView(_ v: CADViewport, context: Context) {
        v.scene.bodies = doc.gpu
        v.scene.bounds = doc.build.bounds
        v.scene.display = doc.model.display ?? .shadedEdges
        v.scene.selected = Set(doc.selection)
        v.scene.grid = doc.showGrid
        if v.scene.camera != doc.camera { v.scene.camera = doc.camera }
    }
}

private struct CADSketchRepresentable: NSViewRepresentable {
    let doc: CADDocument
    let sketch: CADSketch
    let featureID: UUID

    func makeNSView(context: Context) -> CADSketchView {
        let v = CADSketchView()
        doc.sketchView = v
        v.onAdd = { [weak doc] e in doc?.addEntity(e) }
        v.onUpdate = { [weak doc] e in doc?.updateEntity(e) }
        v.onRemove = { [weak doc] id in doc?.removeEntity(id) }
        v.onSelect = { [weak doc] id in if doc?.selectedEntity != id { doc?.selectedEntity = id } }
        v.sketch = sketch
        DispatchQueue.main.async { v.fit() }
        return v
    }

    func updateNSView(_ v: CADSketchView, context: Context) {
        if v.sketch != sketch { v.sketch = sketch }
        if v.tool != doc.sketchTool { v.tool = doc.sketchTool }
        v.polygonSides = doc.polygonSides
        if v.selectedEntity != doc.selectedEntity { v.select(doc.selectedEntity) }
    }
}

// MARK: - Inspector

/// A field for an expression: committed with Return or on leaving it.
private struct ExpressionField: View {
    let label: String
    let value: String
    var result: String?
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                TextField("", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { if text != value { commit(text) } }
                    .onChange(of: focused) { _, now in if !now, text != value { commit(text) } }
                if let result { Text(result).font(.caption).foregroundStyle(.secondary).monospacedDigit().frame(minWidth: 40, alignment: .trailing) }
            }
        }
        .onAppear { text = value }
        .onChange(of: value) { _, v in text = v }
    }
}

struct CADInspector: View {
    @Bindable var doc: CADDocument

    nonisolated static func format(_ v: Double) -> String {
        abs(v - v.rounded()) < 1e-9 ? String(Int(v.rounded())) : String(format: "%.3g", v)
    }

    var body: some View {
        Form {
            if let id = doc.selectedParameter, let p = doc.model.parameters.first(where: { $0.id == id }) {
                ParameterInspector(doc: doc, parameter: p)
            } else if let f = doc.selectedFeature {
                FeatureInspector(doc: doc, feature: f)
            } else {
                ModelInspector(doc: doc)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ModelInspector: View {
    @Bindable var doc: CADDocument
    var body: some View {
        Section("Model") {
            ExpressionField(label: "Name", value: doc.model.name) { doc.setModel($0) }
            Stepper("Smoothness: \(doc.model.smoothness)", value: Binding(get: { doc.model.smoothness }, set: { doc.setModel(smoothness: $0) }), in: 12...256, step: 12)
            Picker("Display", selection: Binding(get: { doc.model.display ?? .shadedEdges }, set: { doc.setModel(display: $0) })) {
                ForEach(CADDisplay.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
        }
        Section("Getting started") {
            Text("Create a primitive, or draw a sketch and extrude or revolve it. Select two bodies (⇧-click) to join, cut or intersect them. Any number can be an expression of the parameters — width / 2 + 3.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Drag to orbit · ⇧-drag or right-drag to pan · scroll or pinch to zoom · double-click a sketched body to edit its sketch.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ParameterInspector: View {
    let doc: CADDocument
    let parameter: CADParameter
    var body: some View {
        Section("Parameter") {
            ExpressionField(label: "Name", value: parameter.name) { doc.setParameter(parameter.id, name: $0) }
                .id("name-\(parameter.id)")
            ExpressionField(label: "Value", value: parameter.expression, result: doc.build.parameterValues[parameter.name].map(CADInspector.format)) {
                doc.setParameter(parameter.id, expression: $0)
            }
            .id("expr-\(parameter.id)")
            if let error = doc.build.parameterErrors[parameter.id] { Text(error).foregroundStyle(.orange).font(.caption) }
            Button("Delete Parameter", role: .destructive) { doc.removeParameter(parameter.id) }
        }
    }
}

private struct FeatureInspector: View {
    let doc: CADDocument
    let feature: CADFeature

    private func result(_ text: String) -> String? {
        guard Double(text.trimmingCharacters(in: .whitespaces)) == nil, let v = try? CADExpression.evaluate(text, doc.build.parameterValues) else { return nil }
        return "= " + CADInspector.format(v)
    }

    var body: some View {
        Section(feature.kind.title) {
            ExpressionField(label: "Name", value: feature.name) { name in doc.update(feature.id, "Rename") { $0.name = name } }
                .id("name-\(feature.id)")
            ForEach(CADFeature.fields(feature.kind), id: \.key) { field in
                let text = feature.values[field.key] ?? field.value
                ExpressionField(label: field.label, value: text, result: result(text)) { doc.setValue(feature.id, field.key, $0) }
                    .id("\(feature.id)-\(field.key)")
            }
            if let error = doc.build.errors[feature.id] { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption) }
        }
        if let sketch = feature.sketch {
            Section("Sketch") {
                Picker("Plane", selection: Binding(get: { sketch.plane }, set: { p in doc.update(feature.id, "Sketch Plane") { $0.sketch?.plane = p } })) {
                    ForEach(CADSketch.Plane.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                ExpressionField(label: "Offset", value: sketch.offset, result: result(sketch.offset)) { o in doc.update(feature.id, "Sketch Offset") { $0.sketch?.offset = o } }
                    .id("offset-\(feature.id)")
                Picker("Make", selection: Binding(get: { feature.kind }, set: { k in
                    doc.update(feature.id, k.title) { f in
                        f.kind = k
                        for field in CADFeature.fields(k) where f.values[field.key] == nil { f.values[field.key] = field.value }
                    }
                })) {
                    Text("Extrude").tag(CADFeature.Kind.extrude)
                    Text("Revolve").tag(CADFeature.Kind.revolve)
                }
                Text("\(sketch.entities.count) shapes · \(sketch.loops(segments: 32).count) closed outlines").font(.caption).foregroundStyle(.secondary)
                Button(doc.editingSketch == feature.id ? "Finish Sketch" : "Edit Sketch") {
                    doc.editingSketch == feature.id ? doc.finishSketch() : doc.editSketch(feature.id)
                }
            }
            if doc.editingSketch == feature.id, let eid = doc.selectedEntity, let entity = sketch.entities.first(where: { $0.id == eid }) {
                EntityInspector(doc: doc, entity: entity)
            }
        }
        if feature.kind.isPlaced {
            Section("Placement") {
                PlacementFields(doc: doc, feature: feature, result: result)
            }
        }
        if let inputs = feature.inputs, !inputs.isEmpty {
            Section(feature.kind.isBoolean ? "Bodies (the first is \(feature.kind == .subtract ? "cut" : "joined"))" : "Body") {
                ForEach(inputs, id: \.self) { id in Text(doc.model.feature(id)?.name ?? "(missing)") }
            }
        }
        if let data = feature.meshData {
            Section("Mesh") { Text("\(data.count / 36) triangles").foregroundStyle(.secondary) }
        }
        Section("Appearance") {
            HStack(spacing: 6) {
                ForEach(Array(CADColor.palette.enumerated()), id: \.offset) { _, c in
                    Circle().fill(Color(red: c.r, green: c.g, blue: c.b)).frame(width: 18, height: 18)
                        .overlay(Circle().stroke(feature.color == c ? Color.accentColor : .clear, lineWidth: 2.5))
                        .onTapGesture { doc.update(feature.id, "Colour") { $0.color = c } }
                }
            }
            Toggle("Hidden", isOn: Binding(get: { feature.hidden == true }, set: { _ in doc.toggleHidden(feature.id) }))
        }
        if let solid = doc.build.solids[feature.id] {
            Section("Measure") {
                let b = solid.bounds.withUnsafeBytes { Array($0.bindMemory(to: Double.self)) }
                LabeledContent("Volume", value: String(format: "%.2f cm³", solid.volume / 1000))
                LabeledContent("Surface area", value: String(format: "%.1f mm²", solid.area))
                if b.count == 6 { LabeledContent("Size", value: String(format: "%.2f × %.2f × %.2f mm", b[3] - b[0], b[4] - b[1], b[5] - b[2])) }
            }
        }
    }
}

private struct PlacementFields: View {
    let doc: CADDocument
    let feature: CADFeature
    let result: (String) -> String?

    var body: some View {
        let p = feature.placement
        let rows: [(String, String, WritableKeyPath<CADPlacement, String>)] = [
            ("X", p.x, \.x), ("Y", p.y, \.y), ("Z", p.z, \.z), ("Turn X°", p.rx, \.rx), ("Turn Y°", p.ry, \.ry), ("Turn Z°", p.rz, \.rz),
        ]
        ForEach(rows, id: \.0) { row in
            ExpressionField(label: row.0, value: row.1, result: result(row.1)) { text in doc.update(feature.id, "Move \(feature.name)") { $0.placement[keyPath: row.2] = text } }
                .id("\(feature.id)-\(row.0)")
        }
    }
}

private struct EntityInspector: View {
    let doc: CADDocument
    let entity: CADSketchEntity

    var body: some View {
        Section(entity.kind.title) {
            let names: [String] = switch entity.kind {
            case .line: ["Start", "End"]
            case .arc: ["Start", "End", "Through"]
            case .circle: ["Centre", "Edge"]
            case .rectangle: ["Corner", "Opposite"]
            case .polygon: ["Centre", "Corner"]
            }
            ForEach(Array(entity.points.enumerated()), id: \.offset) { k, q in
                ExpressionField(label: k < names.count ? names[k] : "Point", value: String(format: "%g, %g", q.x, q.y)) { text in
                    let parts = text.split(separator: ",").compactMap { try? CADExpression.evaluate(String($0), doc.build.parameterValues) }
                    guard parts.count == 2 else { return }
                    var e = entity
                    e.points[k] = SIMD2(parts[0], parts[1])
                    doc.updateEntity(e)
                }
                .id("\(entity.id)-\(k)")
            }
            if entity.kind == .circle || entity.kind == .polygon {
                LabeledContent("Radius", value: String(format: "%.3g mm", entity.radius))
            }
            if entity.kind == .polygon {
                Stepper("\(entity.sides ?? 6) sides", value: Binding(get: { entity.sides ?? 6 }, set: { n in var e = entity; e.sides = n; doc.updateEntity(e) }), in: 3...48)
            }
            Button("Delete \(entity.kind.title)", role: .destructive) { doc.removeEntity(entity.id) }
        }
    }
}

private struct CADStatusBar: View {
    let doc: CADDocument

    var body: some View {
        HStack(spacing: 14) {
            Text("\(doc.build.bodies.count) bod\(doc.build.bodies.count == 1 ? "y" : "ies")")
            if let m = doc.measures {
                Text(String(format: "%@ volume %.2f cm³ · area %.1f mm² · %.1f × %.1f × %.1f mm",
                            doc.selection.isEmpty ? "All:" : "Selected:", m.volume / 1000, m.area, m.size.x, m.size.y, m.size.z))
            }
            if !doc.build.errors.isEmpty {
                Label("\(doc.build.errors.count) feature\(doc.build.errors.count == 1 ? "" : "s") couldn't be built", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Spacer()
            Text("millimetres").foregroundStyle(.secondary)
        }
        .font(.caption)
        .monospacedDigit()
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}
