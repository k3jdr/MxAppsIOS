//
//  CADMenus.swift
//  MxNoteONE
//
//  While a 3D editor is in front, the menu bar has FreeCAD's menus for it — Part Design, Part, Sketch and 3D View
//  (FreeCAD's View) — and a FreeCAD menu (open the model in FreeCAD, import and export its files); the notebook's
//  own Format, Tags, Insert, Go and Notebook menus step aside until a notebook window is in front again. Each menu
//  is filled as it opens, so what's enabled follows the selection.
//

import AppKit

@MainActor
enum CADMenus {
    private static weak var current: CADEditor?
    private static var added: [NSMenuItem] = []
    private static var hiddenItems: [NSMenuItem] = []
    private static let delegate = Filler()
    static let titles = ["Part Design", "Part", "Sketch", "3D View", "FreeCAD"]
    private static let notebookMenus: Set<String> = ["Format", "Tags", "Insert", "Go", "Notebook"]

    static var installed: Bool { !added.isEmpty }

    static func install(for editor: CADEditor) {
        clear()
        current = editor
        guard let main = NSApp.mainMenu else { return }
        let at = main.items.firstIndex { $0.submenu === NSApp.windowsMenu || $0.title == "Window" } ?? main.items.count
        for (k, title) in titles.enumerated() {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            menu.autoenablesItems = false
            menu.delegate = delegate
            item.submenu = menu
            fill(menu)
            main.insertItem(item, at: min(main.items.count, at + k))
            added.append(item)
        }
        for item in main.items where notebookMenus.contains(item.title) && !item.isHidden {
            item.isHidden = true
            hiddenItems.append(item)
        }
    }

    static func remove(for editor: CADEditor) {
        guard current === editor || current == nil else { return }
        clear()
    }

    private static func clear() {
        for item in added { item.menu?.removeItem(item) }
        added = []
        for item in hiddenItems { item.isHidden = false }
        hiddenItems = []
        current = nil
    }

    private final class Filler: NSObject, NSMenuDelegate {
        func menuNeedsUpdate(_ menu: NSMenu) { MainActor.assumeIsolated { CADMenus.fill(menu) } }
    }

    // MARK: The menus

    private static func item(_ title: String, enabled: Bool = true, state: Bool = false, _ action: @escaping () -> Void) -> NSMenuItem {
        let i = ClosureMenuItem(title, state: state, handler: action)
        i.isEnabled = enabled
        return i
    }

    private static func sub(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let m = NSMenu(title: title)
        m.autoenablesItems = false
        for x in items { m.addItem(x) }
        i.submenu = m
        return i
    }

    private static let primitives: [CADFeature.Kind] = [.box, .cylinder, .sphere, .cone, .ellipsoid, .torus, .prism, .wedge, .tube]

    static func fill(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let doc = current?.doc else { return }
        let sketching = doc.editingSketch != nil
        func sketchMenu() -> NSMenuItem {
            sub("Create Sketch", [item("On the Selected Face", enabled: !doc.selectedFaces.isEmpty && !sketching) { doc.newSketch(on: nil) }, .separator()]
                + CADSketch.Plane.allCases.map { p in item("On \(p.title)", enabled: !sketching) { doc.newSketch(on: p) } })
        }
        switch menu.title {
        case "Part Design":
            menu.addItem(sketchMenu())
            menu.addItem(item("Edit Sketch", enabled: !sketching && (doc.selectedFeature?.sketch != nil || doc.selectedFeature?.profile != nil)) {
                if let f = doc.selectedFeature { doc.editSketch(f.sketch != nil ? f.id : f.profile!) }
            })
            menu.addItem(.separator())
            menu.addItem(sub("Create an Additive Feature", [
                item("Pad") { doc.sketchFeature(.extrude, .add) },
                item("Revolution") { doc.sketchFeature(.revolve, .add) },
                item("Additive Loft") { doc.sketchFeature(.loft, .add) },
                item("Additive Pipe") { doc.sketchFeature(.pipe, .add) },
                item("Additive Helix") { doc.sketchFeature(.helix, .add) },
                .separator(),
            ] + primitives.map { k in item("Additive \(k.title)") { doc.primitive(k, .add) } }))
            menu.addItem(sub("Create a Subtractive Feature", [
                item("Pocket") { doc.sketchFeature(.extrude, .subtract) },
                item("Hole") { doc.hole() },
                item("Groove") { doc.sketchFeature(.revolve, .subtract) },
                item("Subtractive Loft") { doc.sketchFeature(.loft, .subtract) },
                item("Subtractive Pipe") { doc.sketchFeature(.pipe, .subtract) },
                item("Subtractive Helix") { doc.sketchFeature(.helix, .subtract) },
                .separator(),
            ] + primitives.map { k in item("Subtractive \(k.title)") { doc.primitive(k, .subtract) } }))
            menu.addItem(sub("Apply a Dress-up Feature", [
                item("Fillet", enabled: !doc.subSelection.isEmpty) { doc.dressUp(.fillet) },
                item("Chamfer", enabled: !doc.subSelection.isEmpty) { doc.dressUp(.chamfer) },
            ]))
            menu.addItem(sub("Apply a Pattern", [
                item("Mirrored", enabled: !doc.selection.isEmpty) { doc.pattern(.mirror) },
                item("Linear Pattern", enabled: !doc.selection.isEmpty) { doc.pattern(.linearPattern) },
                item("Polar Pattern", enabled: !doc.selection.isEmpty) { doc.pattern(.circularPattern) },
            ]))
            menu.addItem(.separator())
            menu.addItem(item("Boolean Union", enabled: doc.selectedBodies.count >= 2) { doc.combine(.union) })
        case "Part":
            menu.addItem(sub("Primitives", [CADFeature.Kind.box, .cylinder, .sphere, .cone, .torus, .tube, .wedge, .prism, .ellipsoid].map { k in
                item(k == .box ? "Cube" : k.title) { doc.add(k) }
            }))
            menu.addItem(sub("Boolean", [
                item("Union (Fuse)", enabled: doc.selectedBodies.count >= 2) { doc.combine(.union) },
                item("Cut", enabled: doc.selectedBodies.count >= 2) { doc.combine(.subtract) },
                item("Common", enabled: doc.selectedBodies.count >= 2) { doc.combine(.intersect) },
            ]))
            menu.addItem(.separator())
            menu.addItem(sketchMenu())
            menu.addItem(item("Extrude…") { doc.sketchFeature(.extrude, nil) })
            menu.addItem(item("Revolve…") { doc.sketchFeature(.revolve, nil) })
            menu.addItem(item("Mirroring…", enabled: !doc.selectedBodies.isEmpty) { doc.pattern(.mirror) })
            menu.addItem(item("Fillet…", enabled: !doc.subSelection.isEmpty) { doc.dressUp(.fillet) })
            menu.addItem(item("Chamfer…", enabled: !doc.subSelection.isEmpty) { doc.dressUp(.chamfer) })
            menu.addItem(item("Loft…", enabled: doc.selectedSketches.count >= 2) { doc.sketchFeature(.loft, nil) })
            menu.addItem(item("Sweep…", enabled: doc.selectedSketches.count >= 2) { doc.sketchFeature(.pipe, nil) })
            menu.addItem(item("Helix…") { doc.sketchFeature(.helix, nil) })
            menu.addItem(.separator())
            menu.addItem(sub("Arrays", [
                item("Linear Array", enabled: !doc.selection.isEmpty) { doc.pattern(.linearPattern) },
                item("Polar Array", enabled: !doc.selection.isEmpty) { doc.pattern(.circularPattern) },
            ]))
        case "Sketch":
            menu.addItem(sketchMenu())
            menu.addItem(item("Edit Sketch", enabled: !sketching && (doc.selectedFeature?.sketch != nil || doc.selectedFeature?.profile != nil)) {
                if let f = doc.selectedFeature { doc.editSketch(f.sketch != nil ? f.id : f.profile!) }
            })
            menu.addItem(item("Leave Sketch", enabled: sketching) { doc.finishSketch() })
            menu.addItem(item("View Sketch", enabled: sketching) { doc.sketchView?.fit() })
            menu.addItem(.separator())
            menu.addItem(sub("Sketcher Geometries", CADSketchTool.allCases.filter { $0 != .select && $0 != .fillet && $0 != .trim }.map { t in
                item(t.rawValue, enabled: sketching, state: doc.sketchTool == t) { doc.sketchTool = t }
            }))
            menu.addItem(sub("Sketcher Edit Tools", [
                item("Fillet", enabled: sketching, state: doc.sketchTool == .fillet) { doc.sketchTool = .fillet },
                item("Trim", enabled: sketching, state: doc.sketchTool == .trim) { doc.sketchTool = .trim },
                item("Toggle Construction Geometry", enabled: sketching, state: doc.constructionMode) {
                    doc.sketchView?.toggleConstruction()
                    doc.constructionMode = doc.sketchView?.constructionMode ?? doc.constructionMode
                },
            ]))
            menu.addItem(sub("Sketcher Constraints", CADConstraint.Kind.allCases.map { k in
                item("Constrain \(k.title)", enabled: sketching && !doc.sketchSelection.isEmpty) { doc.sketchView?.constrain(k) }
            }))
            menu.addItem(.separator())
            menu.addItem(item("Select", enabled: sketching, state: doc.sketchTool == .select) { doc.sketchTool = .select })
            menu.addItem(item("Delete Selected", enabled: sketching) { doc.sketchView?.deleteSelection() })
        case "3D View":
            menu.addItem(sub("Workbench", CADWorkbench.allCases.map { w in item(w.rawValue, state: doc.workbench == w) { doc.workbench = w } }))
            menu.addItem(.separator())
            menu.addItem(sub("Standard Views", [item("Fit All") { doc.viewport?.fit() }, .separator()]
                + zip(CADViewport.views, ["(1)", "(4)", "(3)", "(6)", "(2)", "(5)", "(0)"]).map { v, key in item("\(v.name)  \(key)") { doc.viewport?.look(yaw: v.yaw, pitch: v.pitch) } }))
            menu.addItem(sub("Draw Style", CADDisplay.allCases.map { d in item(d.title, state: (doc.model.display ?? .shadedEdges) == d) { doc.setModel(display: d) } }))
            menu.addItem(item("Orthographic View", state: !doc.camera.perspective) {
                guard let v = doc.viewport else { return }
                var c = v.scene.camera
                c.perspective = false
                v.setCamera(c)
            })
            menu.addItem(item("Perspective View", state: doc.camera.perspective) {
                guard let v = doc.viewport else { return }
                var c = v.scene.camera
                c.perspective = true
                v.setCamera(c)
            })
            menu.addItem(.separator())
            menu.addItem(item("Toggle Axis Grid", state: doc.showGrid) { doc.showGrid.toggle() })
            menu.addItem(item("Navigation Cube", state: doc.showNaviCube) { doc.showNaviCube.toggle() })
            menu.addItem(.separator())
            menu.addItem(item("Toggle Visibility", enabled: !doc.selection.isEmpty) { doc.toggleVisibility() })
            menu.addItem(item("Show All Objects") { doc.showAll() })
        case "FreeCAD":
            let app = CADFreeCAD.appURL
            menu.addItem(item("Open in FreeCAD", enabled: app != nil) { CADFreeCADCommands.openInFreeCAD(doc) })
            let source = doc.selectedFeature?.source != nil
            menu.addItem(item("Edit in FreeCAD", enabled: app != nil && source) { if let f = doc.selectedFeature { CADFreeCADCommands.editSource(doc, f.id) } })
            menu.addItem(item("Read FreeCAD Files Again", enabled: app != nil && doc.model.features.contains { $0.source != nil }) { CADFreeCADCommands.reloadAll(doc) })
            menu.addItem(.separator())
            menu.addItem(item("Import FreeCAD, STEP, IGES or BREP…", enabled: app != nil) { CADFreeCADCommands.importFile(doc) })
            menu.addItem(sub("Export", CADFreeCAD.Format.allCases.map { f in item("\(f.title)…", enabled: app != nil) { CADFreeCADCommands.export(doc, f) } }
                + [.separator(), item("STL…") { doc.export(obj: false) }, item("OBJ…") { doc.export(obj: true) }]))
            menu.addItem(.separator())
            if let app {
                let info = item("FreeCAD \(CADFreeCAD.version ?? "") — \(app.deletingLastPathComponent().path)", enabled: false) {}
                menu.addItem(info)
                menu.addItem(item("Open FreeCAD") { NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil) })
            } else {
                menu.addItem(item("FreeCAD isn't installed", enabled: false) {})
                menu.addItem(item("Get FreeCAD…") { NSWorkspace.shared.open(URL(string: "https://www.freecad.org/downloads.php")!) })
            }
        default:
            break
        }
    }
}
