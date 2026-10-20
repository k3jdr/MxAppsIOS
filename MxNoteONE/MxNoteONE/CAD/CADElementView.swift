//
//  CADElementView.swift
//  MxNoteONE
//
//  A 3D model on the page: shown live (drag to orbit, ⇧-drag to pan, pinch — or scroll once clicked — to zoom),
//  double-click to open it in the 3D editor; printed and exported as a picture. Bodies from FreeCAD files follow
//  their files (edited in FreeCAD and saved, the page changes).
//

import AppKit
import UniformTypeIdentifiers

final class CADElementView: ElementView {
    let viewport = CADViewport()
    private let builder = CADBuilder()
    private var picture: NSImageView?
    private var cameraSave: DispatchWorkItem?
    private var watch: Timer?
    private var refreshing = false
    private(set) var build = CADBuild()

    var model: CADModel { element.cad ?? .starter }

    override init(element: PageElement) {
        super.init(element: element)
        viewport.scrollZooms = false
        viewport.onDoubleClick = { [weak self] _ in self?.edit() }
        viewport.onPick = { [weak self] _, _, _ in
            guard let self else { return }
            self.canvas?.selectedElement = self
        }
        viewport.onCameraChange = { [weak self] camera in self?.cameraChanged(camera) }
        viewport.onContextMenu = { [weak self] _ in self?.contextMenu() }
        addSubview(viewport)
        finishSetup()
        rebuild()
        setWidth(frame.width)
        watch = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSources() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit { watch?.invalidate() }

    /// A FreeCAD file one of its bodies came from changed: read again (the editor does it while it's open).
    private func checkSources() {
        guard !refreshing, !CADEditor.isOpen(element.id), model.features.contains(where: { $0.source != nil }) else { return }
        let changed = CADFreeCADCommands.changedSources(model)
        guard !changed.isEmpty else { return }
        refreshing = true
        let ref = controller?.ref
        Task { @MainActor in
            defer { refreshing = false }
            if let m = await CADFreeCADCommands.refreshed(model, changed, ref: ref) { apply(m) }
        }
    }

    /// A document for FreeCAD commands from the page.
    private func document() -> CADDocument {
        let d = CADDocument(model: model)
        d.pageRef = controller?.ref
        return d
    }

    override var minWidth: CGFloat { 160 }

    override func setWidth(_ width: CGFloat) {
        let w = max(minWidth, width)
        setFrameSize(NSSize(width: w, height: Self.gripHeight + (w * 0.62).rounded()))
    }

    override func layoutContent() {
        viewport.frame = contentFrame
        picture?.frame = contentFrame
    }

    /// Builds the model and shows it (from its saved view, else fitted from the front corner).
    func rebuild() {
        build = builder.build(model)
        viewport.scene.bodies = CADRenderer.shared.upload(build.bodies)
        viewport.scene.bounds = build.bounds
        viewport.scene.display = model.display ?? .shadedEdges
        viewport.scene.lines = Self.wireframe(build, builder: builder, display: model.display)
        if let camera = model.camera {
            viewport.scene.camera = camera
        } else {
            var c = CADCamera()
            c.yaw = -45
            c.pitch = 30
            viewport.scene.camera = CADRenderer.fitted(c, bounds: build.bounds)
        }
    }

    /// A wireframe's edges, as lines.
    static func wireframe(_ build: CADBuild, builder: CADBuilder, display: CADDisplay?) -> [CADLineSet] {
        guard display == .wireframe else { return [] }
        return build.bodies.map { body in
            let edges = builder.edges(body.solid)
            return CADLineSet(edges.map(\.points), closed: edges.map(\.closed), color: SIMD4(0.12, 0.13, 0.16, 1), width: 1.4)
        }
    }

    /// The editor's changes (or anyone's): shown at once.
    func apply(_ model: CADModel) {
        element.cad = model
        rebuild()
        controller?.markDirty()
    }

    /// Turning the model on the page keeps that view (not an undo step).
    private func cameraChanged(_ camera: CADCamera) {
        cameraSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            var m = self.model
            m.camera = camera
            self.element.cad = m
            self.controller?.markDirty()
        }
        cameraSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    override func prepareForExport() {
        super.prepareForExport()
        // Printed and exported as a picture (a live Metal view doesn't print).
        let image = NSImageView(image: image() ?? NSImage())
        image.imageScaling = .scaleProportionallyUpOrDown
        addSubview(image)
        picture = image
        viewport.isHidden = true
        layoutContent()
    }

    func image() -> NSImage? {
        let size = contentFrame.size.width > 10 ? contentFrame.size : NSSize(width: 480, height: 300)
        return CADRenderer.shared.image(viewport.scene, size: size)
    }

    override func makeElement() -> PageElement {
        var e = super.makeElement()
        e.cad = model
        return e
    }

    override func indexText() -> String? {
        ([model.name] + model.features.map(\.name)).joined(separator: " ")
    }

    func edit() { CADEditor.open(self) }

    private func setDisplay(_ d: CADDisplay) {
        var m = model
        m.display = d
        apply(m)
    }

    override func contextMenu() -> NSMenu {
        let menu = super.contextMenu()
        menu.insertItem(.separator(), at: 0)
        let views = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        let viewMenu = NSMenu()
        for v in CADViewport.views {
            viewMenu.addItem(ClosureMenuItem(v.name) { [weak self] in self?.viewport.look(yaw: v.yaw, pitch: v.pitch) })
        }
        viewMenu.addItem(.separator())
        viewMenu.addItem(ClosureMenuItem("Fit All") { [weak self] in self?.viewport.fit() })
        viewMenu.addItem(ClosureMenuItem("Perspective", state: viewport.scene.camera.perspective) { [weak self] in
            guard let self else { return }
            var c = self.viewport.scene.camera
            c.perspective.toggle()
            self.viewport.setCamera(c)
        })
        views.submenu = viewMenu
        let display = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
        let displayMenu = NSMenu()
        for d in CADDisplay.allCases {
            displayMenu.addItem(ClosureMenuItem(d.title, state: viewport.scene.display == d) { [weak self] in self?.setDisplay(d) })
        }
        display.submenu = displayMenu
        let export = NSMenuItem(title: "Export", action: nil, keyEquivalent: "")
        let exportMenu = NSMenu()
        exportMenu.addItem(ClosureMenuItem("STL…") { [weak self] in self?.export(obj: false) })
        exportMenu.addItem(ClosureMenuItem("OBJ…") { [weak self] in self?.export(obj: true) })
        exportMenu.addItem(.separator())
        for f in CADFreeCAD.Format.allCases {
            let item = ClosureMenuItem("\(f.title) (FreeCAD)…") { [weak self] in guard let self else { return }; CADFreeCADCommands.export(self.document(), f) }
            item.isEnabled = CADFreeCAD.appURL != nil
            exportMenu.addItem(item)
        }
        export.submenu = exportMenu
        var items: [NSMenuItem] = [ClosureMenuItem("Edit 3D Model…") { [weak self] in self?.edit() }]
        let openIn = ClosureMenuItem("Open in FreeCAD…") { [weak self] in guard let self else { return }; CADFreeCADCommands.openInFreeCAD(self.document()) }
        openIn.isEnabled = CADFreeCAD.appURL != nil
        items.append(openIn)
        if let sourced = model.features.first(where: { $0.source != nil }) {
            items.append(ClosureMenuItem("Edit in FreeCAD") { [weak self] in guard let self else { return }; CADFreeCADCommands.editSource(self.document(), sourced.id) })
        }
        items += [views, display, export]
        for (i, item) in items.enumerated() { menu.insertItem(item, at: i) }
        return menu
    }

    func export(obj: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: obj ? "obj" : "stl") ?? .data]
        panel.nameFieldStringValue = model.name + (obj ? ".obj" : ".stl")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let data = obj ? Data(CADExchange.obj(build.bodies, name: model.name).utf8) : CADExchange.stl(build.bodies, name: model.name)
        do { try data.write(to: url) } catch { NotebookStore.shared.report("Couldn't save \(url.lastPathComponent).", error) }
    }

    /// A model's picture, without a view on screen (OneNote and web exports).
    static func picture(of model: CADModel, size: NSSize) -> NSImage? {
        let build = CADBuilder().build(model)
        var scene = CADScene()
        scene.bodies = CADRenderer.shared.upload(build.bodies)
        scene.bounds = build.bounds
        scene.display = model.display ?? .shadedEdges
        scene.lines = wireframe(build, builder: CADBuilder(), display: model.display)
        var c = CADCamera()
        c.yaw = -45
        c.pitch = 30
        scene.camera = model.camera ?? CADRenderer.fitted(c, bounds: build.bounds)
        return CADRenderer.shared.image(scene, size: size)
    }
}

extension NSImage {
    var pngData: Data? {
        tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:])
    }
}

// MARK: - Putting models on the page

extension CanvasController {
    /// Insert ▸ 3D Model: a new model (a box, or the sample bracket), opened in the 3D editor.
    func insertModel(sample: Bool = false, open: Bool = true) {
        guard ref != nil else { return }
        let p = nextInsertionPoint()
        var element = PageElement(kind: .model, x: p.x, y: p.y, width: 480)
        element.cad = sample ? .bracket : .starter
        guard let view = addElement(element) as? CADElementView else { return }
        undoManager?.setActionName("Insert 3D Model")
        if open { DispatchQueue.main.async { view.edit() } }
    }

    /// Insert ▸ 3D Model from FreeCAD File…: a FreeCAD (STEP, IGES, BREP) file's bodies as a model — the file kept
    /// in the notebook (edit it in FreeCAD from the model's menu), or with `link` the file followed where it is.
    func importFreeCADModel() {
        guard ref != nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = CADFreeCAD.importTypes.compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose a FreeCAD, STEP, IGES or BREP file to put on the page as a 3D model"
        let link = NSButton(checkboxWithTitle: "Follow the file where it is (instead of keeping a copy in the notebook)", target: nil, action: nil)
        panel.accessoryView = link
        panel.isAccessoryViewDisclosed = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        insertFreeCAD(url, link: link.state == .on)
    }

    func insertFreeCAD(_ url: URL, link: Bool, at point: NSPoint? = nil) {
        guard let ref, CADFreeCAD.appURL != nil else {
            NotebookStore.shared.alert = AlertInfo(title: "FreeCAD isn't installed", message: "Install FreeCAD (free, from freecad.org) to bring in FreeCAD, STEP, IGES and BREP files.")
            return
        }
        let p = point ?? nextInsertionPoint()
        Task { @MainActor in
            do {
                let items = try await CADFreeCAD.read(url)
                var model = CADModel(name: url.deletingPathExtension().lastPathComponent)
                let ext = url.pathExtension.lowercased()
                let asset = link ? nil : (try? Data(contentsOf: url)).flatMap { NotebookStore.shared.writeAsset($0, ext: url.pathExtension, for: ref) }
                _ = CADFreeCAD.features(items, into: &model) { item in
                    CADSource(path: link ? url.path : nil, asset: asset, object: item.name, label: item.label, format: ext, modified: link ? CADFreeCAD.modified(url.path) : nil)
                }
                var element = PageElement(kind: .model, x: p.x, y: p.y, width: 480)
                element.cad = model
                addElement(element)
                undoManager?.setActionName("Insert 3D Model")
            } catch {
                NotebookStore.shared.alert = AlertInfo(title: "Couldn't read \(url.lastPathComponent)", message: error.localizedDescription)
            }
        }
    }

    /// Insert ▸ 3D Model from STL / OBJ…: the file's triangles as a model.
    func importModel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["stl", "obj"].compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose an STL or OBJ file to put on the page as a 3D model"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        insertModel(from: url)
    }

    @discardableResult
    func insertModel(from url: URL) -> CADElementView? {
        guard ref != nil, let data = try? Data(contentsOf: url),
              let triangles = CADExchange.triangles(from: data, ext: url.pathExtension) else {
            NotebookStore.shared.alert = AlertInfo(title: "Couldn't read \(url.lastPathComponent)", message: "It isn't an STL or OBJ file with triangles in it.")
            return nil
        }
        var model = CADModel(name: url.deletingPathExtension().lastPathComponent)
        var mesh = model.make(.mesh, name: model.name)
        mesh.meshData = triangles.withUnsafeBufferPointer { Data(buffer: $0) }
        model.features = [mesh]
        let p = nextInsertionPoint()
        var element = PageElement(kind: .model, x: p.x, y: p.y, width: 480)
        element.cad = model
        let view = addElement(element) as? CADElementView
        undoManager?.setActionName("Insert 3D Model")
        return view
    }
}
