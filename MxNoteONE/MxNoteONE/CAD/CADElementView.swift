//
//  CADElementView.swift
//  MxNoteONE
//
//  A 3D model on the page: shown live (drag to orbit, ⇧-drag to pan, pinch — or scroll once clicked — to zoom),
//  double-click to open it in the 3D editor; printed and exported as a picture.
//

import AppKit
import UniformTypeIdentifiers

final class CADElementView: ElementView {
    let viewport = CADViewport()
    private let builder = CADBuilder()
    private var picture: NSImageView?
    private var cameraSave: DispatchWorkItem?
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
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

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
        if let camera = model.camera {
            viewport.scene.camera = camera
        } else {
            var c = CADCamera()
            c.yaw = -45
            c.pitch = 30
            viewport.scene.camera = CADRenderer.fitted(c, bounds: build.bounds)
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
            displayMenu.addItem(ClosureMenuItem(d.rawValue, state: viewport.scene.display == d) { [weak self] in self?.setDisplay(d) })
        }
        display.submenu = displayMenu
        let export = NSMenuItem(title: "Export", action: nil, keyEquivalent: "")
        let exportMenu = NSMenu()
        exportMenu.addItem(ClosureMenuItem("STL…") { [weak self] in self?.export(obj: false) })
        exportMenu.addItem(ClosureMenuItem("OBJ…") { [weak self] in self?.export(obj: true) })
        export.submenu = exportMenu
        let items: [NSMenuItem] = [ClosureMenuItem("Edit 3D Model…") { [weak self] in self?.edit() }, views, display, export]
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
