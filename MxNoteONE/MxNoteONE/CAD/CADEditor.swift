//
//  CADEditor.swift
//  MxNoteONE
//
//  The 3D editor: a window for one model on a page, laid out as FreeCAD's — a workbench (Part Design or Part) and
//  its toolbars, the Sketcher's toolbars while a sketch is open; the model tree with the parameters; the Metal
//  view with FreeCAD's navigation cube (or the sketch being drawn); the property panel; the status bar. While it's
//  in front the menu bar has FreeCAD's Part Design, Part, Sketch and View menus, and a FreeCAD menu for working
//  with FreeCAD itself (CADMenus). Every change is one undo step (⌘Z), is rebuilt at once and goes back to the page.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import simd

// MARK: - The window

final class CADEditor: NSWindowController, NSWindowDelegate {
    private static var open: [UUID: CADEditor] = [:]
    let elementID: UUID
    let ref: PageRef
    let doc: CADDocument
    private var pendingSave: DispatchWorkItem?
    private var watch: Timer?
    private var refreshing = false

    static func isOpen(_ id: UUID) -> Bool { open[id] != nil }
    static func editor(for id: UUID) -> CADEditor? { open[id] }

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
        doc.pageRef = ref
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 860),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(model.name) — 3D Model"
        window.setFrameAutosaveName("CADEditor")
        if !window.setFrameUsingName("CADEditor") { window.center() }
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 960, height: 580)
        window.identifier = NSUserInterfaceItemIdentifier("cad-\(elementID.uuidString)")
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: CADEditorView(doc: doc))
        doc.onChange = { [weak self] model in
            self?.window?.title = "\(model.name) — 3D Model"
            self?.scheduleSave()
        }
        // Bodies from FreeCAD files follow them.
        watch = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSources() }
        }
    }

    private func checkSources() {
        guard !refreshing, doc.busy == nil else { return }
        let changed = CADFreeCADCommands.changedSources(doc.model)
        guard !changed.isEmpty else { return }
        refreshing = true
        Task { @MainActor in
            defer { refreshing = false }
            if let m = await CADFreeCADCommands.refreshed(doc.model, changed, ref: ref) { doc.replace(m, name: "Update from FreeCAD") }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { doc.undoManager }

    func windowDidBecomeKey(_ notification: Notification) { CADMenus.install(for: self) }
    func windowDidResignKey(_ notification: Notification) { CADMenus.remove(for: self) }

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
        watch?.invalidate()
        pendingSave?.perform()
        CADMenus.remove(for: self)
        CADEditor.open[elementID] = nil
    }
}

// MARK: - Views

func cadSymbol(_ name: String) -> String {
    NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil ? name : "square.dashed"
}

/// FreeCAD's colours for its kinds of tool: additive yellow, subtractive red, dress-up blue, transforms purple.
enum CADTint {
    static let additive = Color(red: 0.86, green: 0.62, blue: 0.05)
    static let subtractive = Color(red: 0.80, green: 0.22, blue: 0.18)
    static let dressUp = Color(red: 0.20, green: 0.45, blue: 0.85)
    static let transform = Color(red: 0.50, green: 0.30, blue: 0.75)
    static let sketch = Color(red: 0.85, green: 0.35, blue: 0.10)
}

struct CADEditorView: View {
    @Bindable var doc: CADDocument

    var body: some View {
        VStack(spacing: 0) {
            CADToolbar(doc: doc)
            Divider()
            HSplitView {
                CADTree(doc: doc)
                    .frame(minWidth: 200, idealWidth: 230, maxWidth: 320)
                CADCentre(doc: doc)
                    .frame(minWidth: 420, maxWidth: .infinity)
                    .layoutPriority(1)
                CADInspector(doc: doc)
                    .frame(minWidth: 260, idealWidth: 290, maxWidth: 360)
            }
            Divider()
            CADStatusBar(doc: doc)
        }
    }
}

private struct ToolButton: View {
    let title: String
    let symbolName: String
    var tint: Color? = nil
    var disabled = false
    var compact = false
    var on = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: cadSymbol(symbolName)).font(.system(size: compact ? 14 : 16)).frame(height: compact ? 18 : 20)
                    .foregroundStyle(disabled ? AnyShapeStyle(.tertiary) : tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
                if !compact { Text(title).font(.system(size: 10)).lineLimit(1) }
            }
            .frame(minWidth: compact ? 26 : 46, minHeight: compact ? 26 : nil)
            .background(on ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 5))
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

private struct ToolMenu<Content: View>: View {
    let title: String
    let symbolName: String
    var tint: Color? = nil
    var width: CGFloat = 70
    @ViewBuilder let content: Content
    var body: some View {
        Menu { content } label: {
            VStack(spacing: 2) {
                Image(systemName: cadSymbol(symbolName)).font(.system(size: 16)).frame(height: 20).foregroundStyle(tint ?? .primary)
                Text(title).font(.system(size: 10)).lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(minWidth: width)
        .fixedSize()
        .help(title + " ▾")
    }
}

private struct CADToolbar: View {
    @Bindable var doc: CADDocument

    private var primitives: [CADFeature.Kind] { [.box, .cylinder, .sphere, .cone, .ellipsoid, .torus, .prism, .wedge, .tube] }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 0) {
                if doc.editingSketch != nil {
                    sketcher
                } else {
                    VStack(spacing: 3) {
                        Picker("", selection: $doc.workbench) {
                            ForEach(CADWorkbench.allCases) { w in Label(w.rawValue, systemImage: w.symbol).tag(w) }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                        Text("Workbench").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 6)
                    Divider().frame(height: 46)
                    if doc.workbench == .partDesign { partDesign } else { part }
                }
                Divider().frame(height: 46)
                view
                Divider().frame(height: 46)
                ToolGroup(title: "FreeCAD") {
                    ToolButton(title: "Open in FreeCAD", symbolName: "arrow.up.forward.app") { CADFreeCADCommands.openInFreeCAD(doc) }
                    ToolMenu(title: "Import", symbolName: "square.and.arrow.down", width: 62) {
                        Button("FreeCAD, STEP, IGES or BREP…") { CADFreeCADCommands.importFile(doc) }
                        Button("STL or OBJ Mesh…") { doc.importMesh() }
                    }
                    ToolMenu(title: "Export", symbolName: "square.and.arrow.up", width: 62) {
                        ForEach(CADFreeCAD.Format.allCases, id: \.self) { f in Button("\(f.title)…") { CADFreeCADCommands.export(doc, f) } }
                        Divider()
                        Button("STL…") { doc.export(obj: false) }
                        Button("OBJ…") { doc.export(obj: true) }
                    }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
        }
        .background(.background.secondary)
    }

    @ViewBuilder private var partDesign: some View {
        ToolGroup(title: "Sketch") {
            ToolMenu(title: "Sketch", symbolName: CADFeature.Kind.sketch.symbol, tint: CADTint.sketch, width: 64) {
                Button("On the Selected Face") { doc.newSketch(on: nil) }.disabled(doc.selectedFaces.isEmpty)
                Divider()
                ForEach(CADSketch.Plane.allCases, id: \.self) { p in Button("On \(p.title)") { doc.newSketch(on: p) } }
            }
        }
        Divider().frame(height: 46)
        ToolGroup(title: "Additive") {
            ToolButton(title: "Pad", symbolName: CADFeature.Kind.extrude.symbol, tint: CADTint.additive) { doc.sketchFeature(.extrude, .add) }
            ToolButton(title: "Revolution", symbolName: CADFeature.Kind.revolve.symbol, tint: CADTint.additive) { doc.sketchFeature(.revolve, .add) }
            ToolButton(title: "Loft", symbolName: CADFeature.Kind.loft.symbol, tint: CADTint.additive) { doc.sketchFeature(.loft, .add) }
            ToolButton(title: "Pipe", symbolName: CADFeature.Kind.pipe.symbol, tint: CADTint.additive) { doc.sketchFeature(.pipe, .add) }
            ToolButton(title: "Helix", symbolName: CADFeature.Kind.helix.symbol, tint: CADTint.additive) { doc.sketchFeature(.helix, .add) }
            ToolMenu(title: "Primitive", symbolName: "cube.fill", tint: CADTint.additive, width: 64) {
                ForEach(primitives, id: \.self) { k in Button("Additive \(k.title)") { doc.primitive(k, .add) } }
            }
        }
        Divider().frame(height: 46)
        ToolGroup(title: "Subtractive") {
            ToolButton(title: "Pocket", symbolName: "square.3.layers.3d.down.right", tint: CADTint.subtractive) { doc.sketchFeature(.extrude, .subtract) }
            ToolButton(title: "Hole", symbolName: CADFeature.Kind.hole.symbol, tint: CADTint.subtractive) { doc.hole() }
            ToolButton(title: "Groove", symbolName: CADFeature.Kind.revolve.symbol, tint: CADTint.subtractive) { doc.sketchFeature(.revolve, .subtract) }
            ToolButton(title: "Loft", symbolName: CADFeature.Kind.loft.symbol, tint: CADTint.subtractive) { doc.sketchFeature(.loft, .subtract) }
            ToolButton(title: "Pipe", symbolName: CADFeature.Kind.pipe.symbol, tint: CADTint.subtractive) { doc.sketchFeature(.pipe, .subtract) }
            ToolButton(title: "Helix", symbolName: CADFeature.Kind.helix.symbol, tint: CADTint.subtractive) { doc.sketchFeature(.helix, .subtract) }
            ToolMenu(title: "Primitive", symbolName: "cube", tint: CADTint.subtractive, width: 64) {
                ForEach(primitives, id: \.self) { k in Button("Subtractive \(k.title)") { doc.primitive(k, .subtract) } }
            }
        }
        Divider().frame(height: 46)
        ToolGroup(title: "Dress-up") {
            ToolButton(title: "Fillet", symbolName: CADFeature.Kind.fillet.symbol, tint: CADTint.dressUp) { doc.dressUp(.fillet) }
            ToolButton(title: "Chamfer", symbolName: CADFeature.Kind.chamfer.symbol, tint: CADTint.dressUp) { doc.dressUp(.chamfer) }
        }
        Divider().frame(height: 46)
        ToolGroup(title: "Transform") {
            ToolButton(title: "Mirrored", symbolName: CADFeature.Kind.mirror.symbol, tint: CADTint.transform) { doc.pattern(.mirror) }
            ToolButton(title: "Linear Pattern", symbolName: CADFeature.Kind.linearPattern.symbol, tint: CADTint.transform) { doc.pattern(.linearPattern) }
            ToolButton(title: "Polar Pattern", symbolName: CADFeature.Kind.circularPattern.symbol, tint: CADTint.transform) { doc.pattern(.circularPattern) }
        }
        Divider().frame(height: 46)
        editGroup
    }

    @ViewBuilder private var part: some View {
        ToolGroup(title: "Primitives") {
            ForEach([CADFeature.Kind.box, .cylinder, .sphere, .cone, .torus, .tube], id: \.self) { kind in
                ToolButton(title: kind == .box ? "Cube" : kind.title, symbolName: kind.symbol) { doc.add(kind) }
            }
            ToolMenu(title: "More", symbolName: "square.stack.3d.up", width: 56) {
                ForEach([CADFeature.Kind.wedge, .prism, .ellipsoid], id: \.self) { k in Button(k.title) { doc.add(k) } }
            }
        }
        Divider().frame(height: 46)
        ToolGroup(title: "Part Tools") {
            ToolMenu(title: "Sketch", symbolName: CADFeature.Kind.sketch.symbol, tint: CADTint.sketch, width: 64) {
                Button("On the Selected Face") { doc.newSketch(on: nil) }.disabled(doc.selectedFaces.isEmpty)
                Divider()
                ForEach(CADSketch.Plane.allCases, id: \.self) { p in Button("On \(p.title)") { doc.newSketch(on: p) } }
            }
            ToolButton(title: "Extrude", symbolName: CADFeature.Kind.extrude.symbol) { doc.sketchFeature(.extrude, nil) }
            ToolButton(title: "Revolve", symbolName: CADFeature.Kind.revolve.symbol) { doc.sketchFeature(.revolve, nil) }
            ToolButton(title: "Loft", symbolName: CADFeature.Kind.loft.symbol) { doc.sketchFeature(.loft, nil) }
            ToolButton(title: "Sweep", symbolName: CADFeature.Kind.pipe.symbol) { doc.sketchFeature(.pipe, nil) }
            ToolButton(title: "Helix", symbolName: CADFeature.Kind.helix.symbol) { doc.sketchFeature(.helix, nil) }
            ToolButton(title: "Mirror", symbolName: CADFeature.Kind.mirror.symbol, disabled: doc.selectedBodies.isEmpty) { doc.pattern(.mirror) }
            ToolButton(title: "Fillet", symbolName: CADFeature.Kind.fillet.symbol, tint: CADTint.dressUp) { doc.dressUp(.fillet) }
            ToolButton(title: "Chamfer", symbolName: CADFeature.Kind.chamfer.symbol, tint: CADTint.dressUp) { doc.dressUp(.chamfer) }
        }
        Divider().frame(height: 46)
        ToolGroup(title: "Boolean") {
            ToolButton(title: "Union", symbolName: CADFeature.Kind.union.symbol, disabled: doc.selectedBodies.count < 2) { doc.combine(.union) }
            ToolButton(title: "Cut", symbolName: CADFeature.Kind.subtract.symbol, disabled: doc.selectedBodies.count < 2) { doc.combine(.subtract) }
            ToolButton(title: "Common", symbolName: CADFeature.Kind.intersect.symbol, disabled: doc.selectedBodies.count < 2) { doc.combine(.intersect) }
        }
        Divider().frame(height: 46)
        ToolGroup(title: "Arrays") {
            ToolButton(title: "Linear", symbolName: CADFeature.Kind.linearPattern.symbol, disabled: doc.selection.isEmpty) { doc.pattern(.linearPattern) }
            ToolButton(title: "Polar", symbolName: CADFeature.Kind.circularPattern.symbol, disabled: doc.selection.isEmpty) { doc.pattern(.circularPattern) }
        }
        Divider().frame(height: 46)
        editGroup
    }

    @ViewBuilder private var editGroup: some View {
        ToolGroup(title: "Edit") {
            ToolButton(title: "Duplicate", symbolName: "plus.square.on.square", disabled: doc.selection.isEmpty) { doc.duplicateSelected() }
                .keyboardShortcut("d", modifiers: .command)
            ToolButton(title: "Delete", symbolName: "trash", disabled: doc.selection.isEmpty) { doc.deleteSelected() }
                .keyboardShortcut(.delete, modifiers: .command)
        }
    }

    @ViewBuilder private var view: some View {
        ToolGroup(title: "View") {
            ToolButton(title: "Fit All", symbolName: "arrow.up.left.and.down.right.magnifyingglass") { doc.editingSketch != nil ? doc.sketchView?.fit() : doc.viewport?.fit() }
            ToolMenu(title: "Views", symbolName: "cube.transparent", width: 58) {
                ForEach(CADViewport.views, id: \.name) { v in Button(v.name) { doc.viewport?.look(yaw: v.yaw, pitch: v.pitch) } }
            }
            ToolMenu(title: "Draw Style", symbolName: "circle.lefthalf.filled", width: 74) {
                ForEach(CADDisplay.allCases, id: \.self) { d in
                    Button { doc.setModel(display: d) } label: { if (doc.model.display ?? .shadedEdges) == d { Label(d.title, systemImage: "checkmark") } else { Text(d.title) } }
                }
                Divider()
                Toggle("Perspective", isOn: Binding(get: { doc.camera.perspective }, set: { p in var c = doc.camera; c.perspective = p; doc.viewport?.setCamera(c) }))
                Toggle("Grid", isOn: $doc.showGrid)
                Toggle("Navigation Cube", isOn: $doc.showNaviCube)
            }
        }
    }

    // MARK: The Sketcher's toolbars

    private static let geometry: [CADSketchTool] = [.point, .line, .arc, .arc3, .circle, .circle3, .rectangle, .centredRectangle, .roundedRectangle, .polygon, .slot]
    private static let constraints: [CADConstraint.Kind] = [.coincident, .pointOnObject, .vertical, .horizontal, .parallel, .perpendicular, .tangent, .equal, .symmetric, .block, .lock, .distanceX, .distanceY, .distance, .radius, .diameter, .angle]

    @ViewBuilder private var sketcher: some View {
        ToolGroup(title: "Sketcher") {
            Button { doc.finishSketch() } label: {
                VStack(spacing: 2) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 16)).frame(height: 20)
                    Text("Leave Sketch").font(.system(size: 10))
                }
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Leave Sketch (⌘↩)")
            .frame(minWidth: 64)
            ToolButton(title: "View Sketch", symbolName: "viewfinder") { doc.sketchView?.fit() }
            ToolButton(title: "Select", symbolName: CADSketchTool.select.symbol, on: doc.sketchTool == .select) { doc.sketchTool = .select }
        }
        Divider().frame(height: 46)
        ToolGroup(title: "Geometry") {
            ForEach(Self.geometry) { t in ToolButton(title: t.rawValue, symbolName: t.symbol, compact: true, on: doc.sketchTool == t) { doc.sketchTool = t } }
            if doc.sketchTool == .polygon {
                Stepper("\(doc.polygonSides)", value: $doc.polygonSides, in: 3...24).fixedSize().help("Sides")
            }
        }
        Divider().frame(height: 46)
        ToolGroup(title: "Edit Geometry") {
            ToolButton(title: "Fillet", symbolName: CADSketchTool.fillet.symbol, compact: true, on: doc.sketchTool == .fillet) { doc.sketchTool = .fillet }
            ToolButton(title: "Trim", symbolName: CADSketchTool.trim.symbol, compact: true, on: doc.sketchTool == .trim) { doc.sketchTool = .trim }
            ToolButton(title: "Toggle Construction Geometry", symbolName: "line.3.horizontal.decrease", tint: .blue, compact: true, on: doc.constructionMode) { doc.sketchView?.toggleConstruction(); doc.constructionMode = doc.sketchView?.constructionMode ?? doc.constructionMode }
            if doc.sketchTool == .fillet {
                TextField("Radius", value: $doc.filletRadius, format: .number).frame(width: 46).textFieldStyle(.roundedBorder).help("Fillet radius (mm)")
            }
        }
        Divider().frame(height: 46)
        ToolGroup(title: "Constraints") {
            ForEach(Self.constraints, id: \.self) { k in
                ToolButton(title: k.title, symbolName: k.symbol, tint: k.isDimension ? CADTint.subtractive : CADTint.dressUp, compact: true) { doc.sketchView?.constrain(k) }
            }
        }
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
                doc.subSelection = []
                doc.selectedParameter = p
                return
            }
            doc.selectedParameter = nil
            doc.subSelection = []
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
                Section("Model") {
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

    private var tint: Color {
        if feature.kind == .sketch { return CADTint.sketch }
        switch feature.operation {
        case .add?: return CADTint.additive
        case .subtract?: return CADTint.subtractive
        default: break
        }
        if feature.kind == .hole { return CADTint.subtractive }
        if feature.kind.isDressUp { return CADTint.dressUp }
        if feature.kind.isPattern { return CADTint.transform }
        return Color(red: feature.color?.r ?? 0.5, green: feature.color?.g ?? 0.5, blue: feature.color?.b ?? 0.55)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: cadSymbol(feature.operation == .subtract && feature.kind == .extrude ? "square.3.layers.3d.down.right" : feature.kind.symbol))
                .foregroundStyle(tint)
                .frame(width: 18)
            Text(feature.name).foregroundStyle(feature.hidden == true ? .secondary : .primary)
            Spacer()
            if let e = doc.build.errors[feature.id] {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(e)
            } else if let w = doc.build.warnings[feature.id] {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.yellow).help(w)
            }
            if feature.kind == .sketch, let st = doc.build.sketchStatus[feature.id], !feature.sketch!.entities.isEmpty {
                Image(systemName: st.dof == 0 && !st.conflicting ? "checkmark.seal" : "seal").foregroundStyle(st.dof == 0 ? .green : .secondary).help(st.summary)
            }
            if feature.hidden == true { Image(systemName: "eye.slash").foregroundStyle(.secondary) }
            if feature.source?.path != nil { Image(systemName: "link").foregroundStyle(.secondary).help("Follows \(feature.source?.path ?? "")") }
        }
        .contextMenu {
            if feature.sketch != nil { Button("Edit Sketch") { doc.editSketch(feature.id) } }
            if let p = feature.profile { Button("Edit Its Sketch") { doc.editSketch(p) } }
            Button(feature.hidden == true ? "Show" : "Hide") { doc.toggleHidden(feature.id) }
            Button("Duplicate") { doc.select(feature.id); doc.duplicateSelected() }
            if feature.source != nil { Button("Edit in FreeCAD") { CADFreeCADCommands.editSource(doc, feature.id) } }
            Divider()
            Button("Delete") { doc.select(feature.id); doc.deleteSelected() }
        }
        .onTapGesture(count: 2) {
            if feature.sketch != nil { doc.editSketch(feature.id) } else if let p = feature.profile { doc.editSketch(p) }
        }
    }
}

private struct CADCentre: View {
    @Bindable var doc: CADDocument

    var body: some View {
        if let id = doc.editingSketch, let sketch = doc.editedSketch {
            CADSketchRepresentable(doc: doc, sketch: sketch, featureID: id)
        } else {
            CADViewportRepresentable(doc: doc)
                .overlay(alignment: .topTrailing) {
                    if doc.showNaviCube {
                        CADNaviCube(camera: doc.camera) { yaw, pitch in doc.viewport?.look(yaw: yaw, pitch: pitch) } orbit: { dy in
                            guard let v = doc.viewport else { return }
                            var c = v.scene.camera
                            c.yaw += dy
                            v.setCamera(c)
                        }
                        .padding(10)
                    }
                }
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
        v.edgesOf = { [weak doc] id in doc?.edges(of: id) ?? [] }
        v.onPickElement = { [weak doc] element, event in
            doc?.pick(element, extend: event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command))
        }
        v.onHoverElement = { [weak doc] e in doc?.preselection = e }
        v.onCameraChange = { [weak doc] c in doc?.camera = c }
        v.onDoubleClick = { [weak doc, weak v] event in
            guard let doc, let v else { return }
            // Double-click a sketched body: edit its sketch; empty space: fit.
            if let hit = v.pick(at: v.convert(event.locationInWindow, from: nil))?.body, let f = doc.model.feature(hit) {
                doc.select(hit)
                if f.sketch != nil { doc.editSketch(hit) } else if let p = f.profile { doc.editSketch(p) }
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
        v.scene.selected = Set(doc.selection.filter { id in !doc.subSelection.contains { $0.body == id } })
        v.scene.grid = doc.showGrid
        v.scene.lines = Self.lines(doc)
        v.scene.faceHighlights = Self.faces(doc)
        if v.scene.camera != doc.camera { v.scene.camera = doc.camera }
    }

    static let selectedColor = SIMD4<Float>(0.11, 0.68, 0.11, 1)
    static let preselectColor = SIMD4<Float>(0.88, 0.80, 0.0, 1)

    /// Sketches, picked and hovered edges, and the wireframe, as wide lines.
    static func lines(_ doc: CADDocument) -> [CADLineSet] {
        var out: [CADLineSet] = []
        if (doc.model.display ?? .shadedEdges) == .wireframe {
            for body in doc.build.bodies {
                let edges = doc.builder.edges(body.solid)
                out.append(CADLineSet(edges.map(\.points), closed: edges.map(\.closed), color: SIMD4(0.12, 0.13, 0.16, 1), width: 1.4))
            }
        }
        // Sketches not used yet (and selected ones) in the model.
        for (id, polylines) in doc.build.sketchLines {
            let selected = doc.selection.contains(id)
            out.append(CADLineSet(polylines, color: selected ? selectedColor : SIMD4(0.85, 0.35, 0.10, 1), width: 2, onTop: true))
        }
        for id in doc.selection where doc.build.sketchLines[id] == nil {
            guard let f = doc.model.feature(id), f.kind == .sketch, let s = doc.build.sketches[id] ?? f.sketch else { continue }
            let offset = (try? CADExpression.evaluate(s.offset, doc.build.parameterValues)) ?? 0
            out.append(CADLineSet(s.lines3D(offset: offset), color: selectedColor, width: 2, onTop: true))
        }
        let picked = doc.selectedEdges.map(\.1)
        if !picked.isEmpty { out.append(CADLineSet(picked.map(\.points), closed: picked.map(\.closed), color: selectedColor, width: 3.5)) }
        if case .edge(_, let e)? = doc.preselection, !picked.contains(e) { out.append(CADLineSet([e.points], closed: [e.closed], color: preselectColor, width: 3.5)) }
        return out
    }

    /// Picked faces green, the hovered one yellow (FreeCAD's colours).
    static func faces(_ doc: CADDocument) -> [CADFaceHighlight] {
        var out: [CADFaceHighlight] = []
        func vertices(_ body: UUID, _ face: UInt32) -> Data? {
            guard let b = doc.build.bodies.first(where: { $0.id == body }) else { return nil }
            var data = Data()
            b.vertices.withUnsafeBytes { raw in
                var t = 0
                while t + 2 < b.faces.count {
                    if b.faces[t] == face { data.append(contentsOf: raw[(t * 28)..<((t + 3) * 28)]) }
                    t += 3
                }
            }
            return data
        }
        for (b, f) in doc.selectedFaces { if let d = vertices(b, f) { out.append(CADFaceHighlight(vertices: d, color: selectedColor)) } }
        if case .face(let b, let f)? = doc.preselection, !doc.selectedFaces.contains(where: { $0 == (b, f) }), let d = vertices(b, f) {
            out.append(CADFaceHighlight(vertices: d, color: preselectColor))
        }
        return out
    }
}

private struct CADSketchRepresentable: NSViewRepresentable {
    let doc: CADDocument
    let sketch: CADSketch
    let featureID: UUID

    func makeNSView(context: Context) -> CADSketchView {
        let v = CADSketchView()
        doc.sketchView = v
        v.onCommit = { [weak doc] s, name in doc?.replaceSketch(s, name) }
        v.onSelection = { [weak doc] refs in if doc?.sketchSelection != refs { doc?.sketchSelection = refs } }
        v.onSelectConstraint = { [weak doc] id in if doc?.selectedConstraint != id { doc?.selectedConstraint = id } }
        v.sketch = sketch
        DispatchQueue.main.async { v.fit() }
        return v
    }

    func updateNSView(_ v: CADSketchView, context: Context) {
        if v.sketch != sketch { v.sketch = sketch }
        v.values = doc.build.parameterValues
        v.status = doc.build.sketchStatus[featureID] ?? CADSketchStatus()
        if v.tool != doc.sketchTool { v.tool = doc.sketchTool }
        v.polygonSides = doc.polygonSides
        v.filletRadius = doc.filletRadius
        v.constructionMode = doc.constructionMode
        if v.selection != doc.sketchSelection { v.select(doc.sketchSelection) }
        if v.selectedConstraint != doc.selectedConstraint { v.selectConstraint(doc.selectedConstraint) }
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
            } else if let id = doc.editingSketch, let f = doc.model.feature(id) {
                SketchInspector(doc: doc, feature: f)
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
            Picker("Draw style", selection: Binding(get: { doc.model.display ?? .shadedEdges }, set: { doc.setModel(display: $0) })) {
                ForEach(CADDisplay.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        }
        Section("Getting started (as in FreeCAD)") {
            Text("Part Design: pick a flat face (or nothing, for the top plane), Sketch, draw and constrain it, Leave Sketch, then Pad or Pocket. Select edges, then Fillet or Chamfer. Part: primitives, and Union, Cut and Common of selected bodies.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Drag to orbit · ⇧-drag or right-drag to pan · scroll or pinch to zoom · 0–6 standard views · the cube's faces and corners turn the view · double-click a feature to edit its sketch.")
                .font(.caption).foregroundStyle(.secondary)
        }
        CADFreeCADStatus()
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
            Text("FreeCAD gets parameters as a spreadsheet (Parameters), with the expressions bound to it.").font(.caption).foregroundStyle(.secondary)
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

    private var sketchFeatures: [CADFeature] { doc.model.features.filter { $0.kind == .sketch } }

    var body: some View {
        Section(feature.typeTitle) {
            ExpressionField(label: "Name", value: feature.name) { name in doc.update(feature.id, "Rename") { $0.name = name } }
                .id("name-\(feature.id)")
            ForEach(CADFeature.fields(feature.kind), id: \.key) { field in
                if let choices = field.choices {
                    Picker(field.label, selection: Binding(get: { feature.choice(field.key) }, set: { doc.setValue(feature.id, field.key, $0) })) {
                        ForEach(choices, id: \.self) { Text($0).tag($0) }
                    }
                } else {
                    let text = feature.values[field.key] ?? field.value
                    ExpressionField(label: field.label, value: text, result: result(text)) { doc.setValue(feature.id, field.key, $0) }
                        .id("\(feature.id)-\(field.key)")
                }
            }
            if let error = doc.build.errors[feature.id] { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption) }
            if let w = doc.build.warnings[feature.id] { Label(w, systemImage: "exclamationmark.circle").foregroundStyle(.secondary).font(.caption) }
        }
        if feature.operation != nil || feature.kind.isDressUp || feature.kind == .hole {
            Section("Body") {
                if let b = feature.base { Text(doc.model.feature(b)?.name ?? "(missing)") } else { Text("A new body").foregroundStyle(.secondary) }
            }
        }
        if let p = feature.profile, let s = doc.model.feature(p) {
            Section(feature.kind == .pipe ? "Profile" : "Sketch") {
                LabeledContent(s.name) { Button("Edit Sketch") { doc.editSketch(p) } }
                if feature.kind == .loft {
                    ForEach(Array((feature.sections ?? []).enumerated()), id: \.offset) { k, id in
                        LabeledContent("Section \(k + 2)") {
                            HStack {
                                Text(doc.model.feature(id)?.name ?? "(missing)")
                                Button { doc.setSections((feature.sections ?? []).filter { $0 != id }, of: feature.id) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                            }
                        }
                    }
                    Menu("Add Section") {
                        ForEach(sketchFeatures.filter { $0.id != p && !(feature.sections ?? []).contains($0.id) }) { s in
                            Button(s.name) { doc.setSections((feature.sections ?? []) + [s.id], of: feature.id) }
                        }
                    }
                }
                if feature.kind == .pipe {
                    Picker("Path", selection: Binding(get: { feature.sections?.first }, set: { id in doc.setSections(id.map { [$0] } ?? [], of: feature.id) })) {
                        Text("None").tag(UUID?.none)
                        ForEach(sketchFeatures.filter { $0.id != p }) { s in Text(s.name).tag(Optional(s.id)) }
                    }
                }
            }
        }
        if let sketch = feature.sketch { SketchSection(doc: doc, feature: feature, sketch: sketch) }
        if feature.kind.isDressUp {
            Section("Edges") {
                ForEach(Array((feature.edges ?? []).enumerated()), id: \.offset) { k, e in
                    HStack {
                        Text("Edge \(k + 1) · faces \(e.a & 0xFFFF + 1) and \(e.b & 0xFFFF + 1)").font(.caption)
                        Spacer()
                        Button { doc.removeEdge(k, from: feature.id) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
                Button("Add Selected Edges") { doc.addSelectedEdges(to: feature.id) }
                Text("Pick edges of its body in the view (⇧-click for more), then add them.").font(.caption).foregroundStyle(.secondary)
            }
        }
        if feature.kind.isPlaced {
            Section("Placement") {
                PlacementFields(doc: doc, feature: feature, result: result)
            }
        }
        if let inputs = feature.inputs, !inputs.isEmpty, !(feature.operation != nil || feature.kind.isDressUp || feature.kind == .hole) {
            Section(feature.kind.isBoolean ? "Bodies (the first is \(feature.kind == .subtract ? "cut" : "joined"))" : "Of") {
                ForEach(inputs, id: \.self) { id in Text(doc.model.feature(id)?.name ?? "(missing)") }
            }
        }
        if let source = feature.source {
            Section("FreeCAD") {
                LabeledContent("Object", value: source.label ?? source.object)
                if let path = source.path {
                    LabeledContent("Follows") { Text((path as NSString).lastPathComponent).help(path) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                } else {
                    Text("Kept in the notebook (\(source.format)).").font(.caption).foregroundStyle(.secondary)
                }
                Button("Edit in FreeCAD") { CADFreeCADCommands.editSource(doc, feature.id) }
                Button("Read Again") { CADFreeCADCommands.reload(doc, feature.id) }
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

/// A sketch's plane, offset and state.
private struct SketchSection: View {
    let doc: CADDocument
    let feature: CADFeature
    let sketch: CADSketch

    var body: some View {
        Section("Sketch") {
            if sketch.frame != nil {
                LabeledContent("Plane", value: "On a face\(feature.support.flatMap { doc.model.feature($0)?.name }.map { " of \($0)" } ?? "")")
            } else {
                Picker("Plane", selection: Binding(get: { sketch.plane }, set: { p in doc.update(feature.id, "Sketch Plane") { $0.sketch?.plane = p } })) {
                    ForEach(CADSketch.Plane.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            ExpressionField(label: "Offset", value: sketch.offset, result: nil) { o in doc.update(feature.id, "Sketch Offset") { $0.sketch?.offset = o } }
                .id("offset-\(feature.id)")
            if feature.kind == .extrude || feature.kind == .revolve {
                Picker("Make", selection: Binding(get: { feature.kind }, set: { k in
                    doc.update(feature.id, k.title) { f in
                        f.kind = k
                        for field in CADFeature.fields(k) where f.values[field.key] == nil { f.values[field.key] = field.value }
                    }
                })) {
                    Text("Extrude").tag(CADFeature.Kind.extrude)
                    Text("Revolve").tag(CADFeature.Kind.revolve)
                }
            }
            let status = doc.build.sketchStatus[feature.id]
            Text("\(sketch.entities.count) shapes · \(sketch.constraints?.count ?? 0) constraints · \(sketch.loops(segments: 32).count) closed outlines" + (status.map { " · " + $0.summary } ?? ""))
                .font(.caption).foregroundStyle(.secondary)
            Button(doc.editingSketch == feature.id ? "Leave Sketch" : "Edit Sketch") {
                doc.editingSketch == feature.id ? doc.finishSketch() : doc.editSketch(feature.id)
            }
        }
    }
}

/// While a sketch is open: the selected shape and the sketch's constraints, their dimensions editable.
private struct SketchInspector: View {
    let doc: CADDocument
    let feature: CADFeature

    var body: some View {
        if let sketch = feature.sketch {
            SketchSection(doc: doc, feature: feature, sketch: sketch)
            if let eid = doc.selectedEntity, let entity = sketch.entities.first(where: { $0.id == eid }) {
                EntityInspector(doc: doc, entity: entity)
            }
            Section("Constraints") {
                if (sketch.constraints ?? []).isEmpty {
                    Text("Select points and edges in the sketch, then a constraint in the toolbar (or the Sketch menu).").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(sketch.constraints ?? []) { c in
                    HStack(spacing: 6) {
                        Image(systemName: cadSymbol(c.kind.symbol)).foregroundStyle(c.kind.isDimension ? CADTint.subtractive : CADTint.dressUp).frame(width: 16)
                        if c.kind.isDimension, c.kind != .lock {
                            ExpressionField(label: c.kind.title, value: c.value ?? "", result: c.value.flatMap { Double($0) == nil ? (try? CADExpression.evaluate($0, doc.build.parameterValues)).map { "= " + CADInspector.format($0) } : nil }) {
                                doc.setConstraintValue(c.id, $0)
                            }
                            .id("c-\(c.id)")
                        } else if c.kind == .lock {
                            ExpressionField(label: "Lock X", value: c.value ?? "") { doc.setConstraintValue(c.id, $0) }.id("cx-\(c.id)")
                            ExpressionField(label: "Y", value: c.value2 ?? "") { doc.setConstraintValue(c.id, $0, second: true) }.id("cy-\(c.id)")
                        } else {
                            Text(c.kind.title)
                            Spacer()
                        }
                        Button { doc.removeConstraint(c.id) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                    .background(doc.selectedConstraint == c.id ? Color.accentColor.opacity(0.15) : .clear)
                    .onTapGesture { doc.selectedConstraint = c.id; doc.sketchView?.selectConstraint(c.id) }
                }
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
        Section(entity.isConstruction && entity.kind != .point ? "\(entity.kind.title) (construction)" : entity.kind.title) {
            let names: [String] = switch entity.kind {
            case .line: ["Start", "End"]
            case .arc: ["Start", "End", "Through"]
            case .circle: ["Centre", "Edge"]
            case .rectangle: ["Corner", "Opposite"]
            case .polygon: ["Centre", "Corner"]
            case .point: ["Point"]
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
            if let busy = doc.busy {
                ProgressView().controlSize(.small)
                Text(busy)
            }
            if let m = doc.message {
                Label(m, systemImage: "info.circle").foregroundStyle(.orange)
            } else if let picked = doc.subSelectionText {
                Text("Selected: \(picked)")
            } else if case .face(let b, let f)? = doc.preselection, let body = doc.model.feature(b) {
                Text("Preselected: \(body.name) · Face \(f & 0xFFFF + 1)").foregroundStyle(.secondary)
            } else if case .edge(let b, let e)? = doc.preselection, let body = doc.model.feature(b) {
                Text(String(format: "Preselected: %@ · edge, %.2f mm", body.name, e.length)).foregroundStyle(.secondary)
            } else {
                Text("\(doc.build.bodies.count) bod\(doc.build.bodies.count == 1 ? "y" : "ies")")
            }
            if let m = doc.measures {
                Text(String(format: "%@ volume %.2f cm³ · area %.1f mm² · %.1f × %.1f × %.1f mm",
                            doc.selection.isEmpty ? "All:" : "Selected:", m.volume / 1000, m.area, m.size.x, m.size.y, m.size.z))
            }
            if !doc.build.errors.isEmpty {
                Label("\(doc.build.errors.count) feature\(doc.build.errors.count == 1 ? "" : "s") couldn't be built", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Spacer()
            Text(doc.editingSketch != nil ? "Sketcher" : doc.workbench.rawValue).foregroundStyle(.secondary)
            Text("millimetres").foregroundStyle(.secondary)
        }
        .font(.caption)
        .monospacedDigit()
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}
