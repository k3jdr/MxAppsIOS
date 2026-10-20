//
//  CADDocument.swift
//  MxNoteONE
//
//  The 3D editor's document: the model, what's selected (features, and the faces and edges picked in the view),
//  the sketch being edited, and the commands of FreeCAD's Part Design, Part and Sketcher workbenches. Every change
//  is one undo step, and sketches are solved as part of it (so a parameter driving a dimension moves the sketch).
//
//  Part Design's rules, as FreeCAD's: a sketch goes on a selected planar face (or a base plane); Pad, Pocket,
//  Revolution, Groove, Hole, Loft, Pipe and Helix use the selected sketch (or start one) and go on the body the
//  sketch is on (else the selected body, else the only one); Fillet and Chamfer use the selected edges (or a face's
//  edges); a pattern of a Part Design feature repeats that feature on its body.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import simd

enum CADWorkbench: String, CaseIterable, Identifiable {
    case partDesign = "Part Design", part = "Part"
    var id: String { rawValue }
    var symbol: String { self == .partDesign ? "gearshape.2" : "cube" }
}

@Observable
final class CADDocument {
    private(set) var model: CADModel
    /// Selected features, in the order picked (a boolean's first is the body cut or joined).
    var selection: [UUID] = []
    /// Faces and edges picked in the 3D view.
    var subSelection: [CADSubElement] = []
    /// What's under the pointer.
    var preselection: CADSubElement?
    var selectedParameter: UUID?
    var sketchSelection: [CADSketchRef] = []
    var selectedConstraint: UUID?
    private(set) var build = CADBuild()
    private(set) var gpu: [CADGPUBody] = []
    var camera: CADCamera
    /// The feature whose sketch is being drawn.
    private(set) var editingSketch: UUID?
    var sketchTool: CADSketchTool = .line
    var polygonSides = 6
    var filletRadius = 2.0
    var constructionMode = false
    var showGrid = true
    var showNaviCube = UserDefaults.standard.object(forKey: "cadNaviCube") as? Bool ?? true { didSet { UserDefaults.standard.set(showNaviCube, forKey: "cadNaviCube") } }
    var workbench: CADWorkbench = CADWorkbench(rawValue: UserDefaults.standard.string(forKey: "cadWorkbench") ?? "") ?? .partDesign {
        didSet { UserDefaults.standard.set(workbench.rawValue, forKey: "cadWorkbench") }
    }
    /// A note for the status bar (why a command didn't run…).
    private(set) var message: String?
    /// What FreeCAD is doing for us.
    var busy: String?
    @ObservationIgnored let undoManager = UndoManager()
    @ObservationIgnored let builder = CADBuilder()
    @ObservationIgnored var onChange: ((CADModel) -> Void)?
    @ObservationIgnored weak var viewport: CADViewport?
    @ObservationIgnored weak var sketchView: CADSketchView?
    /// The page it's on (for files the notebook keeps).
    @ObservationIgnored var pageRef: PageRef?
    @ObservationIgnored private var messageClear: DispatchWorkItem?

    init(model: CADModel) {
        var c = CADCamera()
        c.yaw = -45
        c.pitch = 30
        camera = c
        self.model = model
        self.model = solvedSketches(model)
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
        model = solvedSketches(m)
        // What's selected may be gone.
        selection = selection.filter { id in model.features.contains { $0.id == id } }
        subSelection = subSelection.filter { e in model.features.contains { $0.id == e.body } }
        if let p = selectedParameter, !model.parameters.contains(where: { $0.id == p }) { selectedParameter = nil }
        if let s = editingSketch, model.feature(s)?.sketch == nil { editingSketch = nil }
        rebuild()
        onChange?(model)
    }

    /// The model with every constrained sketch solved for the parameters' values.
    private func solvedSketches(_ m: CADModel) -> CADModel {
        var vars: [String: Double] = [:]
        for p in m.parameters { if let v = try? CADExpression.evaluate(p.expression, vars) { vars[p.name] = v } }
        var out = m
        for i in out.features.indices {
            guard let s = out.features[i].sketch, !(s.constraints ?? []).isEmpty else { continue }
            let solved = builder.solved(s, vars).0
            if solved != s { out.features[i].sketch = solved }
        }
        return out
    }

    func rebuild() {
        build = builder.build(model)
        gpu = CADRenderer.shared.upload(build.bodies)
    }

    /// Replaces the model (from FreeCAD, say), as one undo step.
    func replace(_ m: CADModel, name: String) {
        guard m != model else { return }
        set(m, name: name)
    }

    func tell(_ text: String) {
        message = text
        messageClear?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.message = nil }
        messageClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
        NSSound.beep()
    }

    // MARK: Selection

    var selectedFeature: CADFeature? { selection.last.flatMap(model.feature) }
    /// Selected bodies on show (what booleans and patterns can use), in the order picked.
    var selectedBodies: [UUID] { selection.filter { id in build.bodies.contains { $0.id == id } } }
    /// Selected sketch features, in the order picked.
    var selectedSketches: [UUID] { selection.filter { model.feature($0)?.kind == .sketch } }
    var selectedEdges: [(UUID, CADBodyEdge)] { subSelection.compactMap { if case .edge(let b, let e) = $0 { return (b, e) }; return nil } }
    var selectedFaces: [(UUID, UInt32)] { subSelection.compactMap { if case .face(let b, let f) = $0 { return (b, f) }; return nil } }
    var selectedEntity: UUID? { sketchSelection.first { !$0.isRoot }?.entity }

    func select(_ id: UUID?, extend: Bool = false) {
        selectedParameter = nil
        subSelection = []
        guard let id else { if !extend { selection = [] }; return }
        if extend {
            if let i = selection.firstIndex(of: id) { selection.remove(at: i) } else { selection.append(id) }
        } else {
            selection = [id]
        }
    }

    /// A pick in the 3D view: the body, and the face or edge (⇧ or ⌘ adds to what's picked).
    func pick(_ element: CADSubElement?, extend: Bool) {
        selectedParameter = nil
        guard let element else {
            if !extend { selection = []; subSelection = [] }
            return
        }
        if extend {
            if let i = subSelection.firstIndex(of: element) { subSelection.remove(at: i) } else { subSelection.append(element) }
            if !selection.contains(element.body) { selection.append(element.body) }
        } else {
            subSelection = [element]
            selection = [element.body]
        }
    }

    func edges(of body: UUID) -> [CADBodyEdge] {
        guard let b = build.bodies.first(where: { $0.id == body }) else { return [] }
        return builder.edges(b.solid)
    }

    /// The body the next Part Design feature goes on: the sketch's, else the selected body, else the only body.
    private func baseBody(for sketch: CADFeature?) -> UUID? {
        if let s = sketch?.support, build.bodies.contains(where: { $0.id == s }) { return s }
        if let b = selectedBodies.last(where: { model.feature($0)?.kind != .sketch }) { return b }
        let bodies = build.bodies.filter { model.feature($0.id)?.kind != .sketch }
        return bodies.count == 1 ? bodies[0].id : nil
    }

    /// A planar face's plane, as a sketch frame: its centre, "up" as near the model's Z as it can be.
    func frame(of body: UUID, face: UInt32) -> CADFrame? {
        guard let b = build.bodies.first(where: { $0.id == body }) else { return nil }
        var normal = SIMD3<Double>.zero, centre = SIMD3<Double>.zero, area = 0.0
        var normals: [SIMD3<Double>] = []
        let p = b.positions
        var t = 0
        while t + 2 < p.count {
            if b.faces[t] == face {
                let a = SIMD3<Double>(p[t]), bb = SIMD3<Double>(p[t + 1]), c = SIMD3<Double>(p[t + 2])
                let n = simd_cross(bb - a, c - a), ar = simd_length(n) / 2
                if ar > 1e-12 {
                    normal += n
                    centre += (a + bb + c) / 3 * ar
                    area += ar
                    normals.append(simd_normalize(n))
                }
            }
            t += 3
        }
        guard area > 1e-12, simd_length(normal) > 1e-12 else { return nil }
        let n = simd_normalize(normal)
        guard normals.allSatisfy({ simd_dot($0, n) > 0.9995 }) else { return nil }
        centre /= area
        let up = SIMD3<Double>(0, 0, 1)
        var v = up - n * simd_dot(up, n)
        if simd_length(v) < 1e-6 { v = simd_cross(n, SIMD3(1, 0, 0)); if n.z < 0 { v = -v } }
        v = simd_normalize(v)
        var u = simd_normalize(simd_cross(v, n))
        // A face looking up or down: across is X (or −X from below, as seen from outside).
        if abs(n.z) > 0.999 { u = SIMD3(n.z > 0 ? 1 : -1, 0, 0); v = simd_normalize(simd_cross(n, u)) }
        // Rounded a little, so sketches on faces read cleanly.
        func tidy(_ x: SIMD3<Double>) -> SIMD3<Double> { (x * 1e6).rounded(.toNearestOrEven) / 1e6 }
        return CADFrame(origin: tidy(centre), u: tidy(u), v: tidy(v))
    }

    // MARK: Part commands

    func add(_ kind: CADFeature.Kind) {
        var newID: UUID?
        perform("Add \(kind.title)") { m in
            var f = m.make(kind)
            f.color = CADColor.palette[m.features.count % CADColor.palette.count]
            m.features.append(f)
            newID = f.id
        }
        selection = newID.map { [$0] } ?? []
        subSelection = []
    }

    /// Union, Subtract or Intersect of the selected bodies (the first picked is cut or joined).
    func combine(_ kind: CADFeature.Kind) {
        let bodies = selectedBodies
        guard bodies.count >= 2 else { return tell("Select two bodies or more (⇧-click), the first the one cut or joined.") }
        var newID: UUID?
        perform(kind.title) { m in
            var f = m.make(kind)
            f.inputs = bodies
            f.color = m.feature(bodies[0])?.color
            m.features.append(f)
            newID = f.id
        }
        selection = newID.map { [$0] } ?? []
        subSelection = []
    }

    /// A linear or polar pattern, or a mirror, of the selected body — or of a Part Design feature on its body.
    func pattern(_ kind: CADFeature.Kind) {
        guard let source = selection.last(where: { id in
            build.bodies.contains { $0.id == id } || (model.feature(id).map { $0.operation != nil || $0.kind == .hole } ?? false)
        }) else { return tell("Select a body, or a feature (a Pocket, a Pad) to repeat.") }
        var newID: UUID?
        perform(kind.title) { m in
            var f = m.make(kind)
            f.inputs = [source]
            f.color = m.feature(source)?.color
            m.features.append(f)
            newID = f.id
        }
        selection = newID.map { [$0] } ?? []
        subSelection = []
    }

    // MARK: Sketches and Part Design

    /// A new sketch: on the selected planar face, or a base plane — opened at once.
    @discardableResult
    func newSketch(on plane: CADSketch.Plane?, open: Bool = true) -> UUID? {
        var sketch = CADSketch(plane: plane ?? .xy)
        var support: UUID?
        if plane == nil, let (body, face) = selectedFaces.last {
            guard let frame = frame(of: body, face: face) else { tell("That face isn't flat: pick a flat face, or a base plane."); return nil }
            sketch.frame = frame
            support = body
        }
        var newID: UUID?
        perform("New Sketch") { m in
            var f = m.make(.sketch)
            f.sketch = sketch
            f.support = support
            f.color = CADColor.palette[0]
            m.features.append(f)
            newID = f.id
        }
        if let newID {
            selection = [newID]
            subSelection = []
            if open { editSketch(newID) }
        }
        return newID
    }

    /// Pad, Pocket, Revolution, Groove, Loft, Pipe, Helix (Part Design, with an operation) or Part's Extrude,
    /// Revolve, Loft and Sweep (without): from the selected sketch, else a new one (drawn next).
    func sketchFeature(_ kind: CADFeature.Kind, _ op: CADFeature.Operation?) {
        var sketches = selectedSketches
        var drawFirst: UUID?
        if kind == .loft, sketches.count < 2 { return tell("Select two sketches or more (⇧-click in the tree), the first the profile.") }
        if kind == .pipe, sketches.count < 2 { return tell("Select the profile sketch, then the path sketch (⇧-click in the tree).") }
        if sketches.isEmpty {
            // Start one: on the selected face, or the top plane.
            guard let id = newSketch(on: selectedFaces.isEmpty ? .xy : nil, open: false) else { return }
            sketches = [id]
            drawFirst = id
        }
        let profile = sketches[0]
        let base = op == nil ? nil : baseBody(for: model.feature(profile))
        if op == .subtract || op == .intersect, base == nil {
            if let d = drawFirst { perform("Undo Sketch") { m in m.features.removeAll { $0.id == d } } }
            return tell("A \(CADFeature(kind: kind, name: "", operation: op).typeTitle) needs a body: select a face of one first.")
        }
        var newID: UUID?
        perform(CADFeature(kind: kind, name: "", operation: op).typeTitle) { m in
            var f = m.make(kind, operation: op)
            f.profile = profile
            if kind == .loft || kind == .pipe { f.sections = Array(sketches.dropFirst()) }
            if let base { f.inputs = [base] }
            f.color = base.flatMap { m.feature($0)?.color } ?? CADColor.palette[m.features.count % CADColor.palette.count]
            if op == .subtract, kind == .extrude { f.values["distance"] = "5" }
            m.features.append(f)
            newID = f.id
        }
        selection = newID.map { [$0] } ?? []
        subSelection = []
        if let d = drawFirst { editSketch(d) }
    }

    /// A Hole at each circle of the selected sketch (else a new sketch on the selected face, to draw circles in).
    func hole() {
        var sketch = selectedSketches.first
        var drawFirst: UUID?
        if sketch == nil {
            guard !selectedFaces.isEmpty else { return tell("Select a face of the body (or a sketch of circles) for the hole.") }
            guard let id = newSketch(on: nil, open: false) else { return }
            sketch = id
            drawFirst = id
        }
        guard let sketch, let base = baseBody(for: model.feature(sketch)) else { return tell("A hole needs a body: sketch its circles on a face of one.") }
        var newID: UUID?
        perform("Hole") { m in
            var f = m.make(.hole)
            f.profile = sketch
            f.inputs = [base]
            f.color = m.feature(base)?.color
            m.features.append(f)
            newID = f.id
        }
        selection = newID.map { [$0] } ?? []
        subSelection = []
        if let d = drawFirst { sketchTool = .circle; editSketch(d) }
    }

    /// The selected edges (or the edges round the selected faces), as references.
    private func pickedEdgeRefs() -> (UUID, [CADEdgeRef])? {
        if let (body, _) = selectedEdges.first {
            return (body, selectedEdges.filter { $0.0 == body }.map { $0.1.ref })
        }
        if let (body, _) = selectedFaces.first {
            let faces = Set(selectedFaces.filter { $0.0 == body }.map(\.1))
            let refs = edges(of: body).filter { faces.contains($0.a) || faces.contains($0.b) }.map(\.ref)
            return refs.isEmpty ? nil : (body, refs)
        }
        return nil
    }

    /// Fillet or Chamfer on the selected edges (or faces' edges).
    func dressUp(_ kind: CADFeature.Kind) {
        guard let (body, refs) = pickedEdgeRefs() else { return tell("Select edges (or faces) of a body in the view first.") }
        var newID: UUID?
        perform(kind.title) { m in
            var f = m.make(kind)
            f.inputs = [body]
            f.edges = refs
            f.color = m.feature(body)?.color
            m.features.append(f)
            newID = f.id
        }
        selection = newID.map { [$0] } ?? []
        subSelection = []
    }

    func addSelectedEdges(to id: UUID) {
        guard let f = model.feature(id), let base = f.inputs?.first else { return }
        guard let (body, refs) = pickedEdgeRefs(), body == base || body == id else { return tell("Select edges of \(model.feature(base)?.name ?? "its body") to add.") }
        update(id, "Add Edges") { f in
            var list = f.edges ?? []
            for r in refs where !list.contains(where: { $0.same(r) }) { list.append(r) }
            f.edges = list
        }
    }

    func removeEdge(_ index: Int, from id: UUID) {
        update(id, "Remove Edge") { f in if f.edges?.indices.contains(index) == true { f.edges?.remove(at: index) } }
    }

    /// An additive or subtractive primitive (Part Design), on the selected body.
    func primitive(_ kind: CADFeature.Kind, _ op: CADFeature.Operation) {
        let base = baseBody(for: nil)
        if op == .subtract, base == nil { return tell("A subtractive primitive needs a body: select it first.") }
        var newID: UUID?
        perform(CADFeature(kind: kind, name: "", operation: op).typeTitle) { m in
            var f = m.make(kind, operation: op)
            if let base { f.inputs = [base] }
            f.color = base.flatMap { m.feature($0)?.color } ?? CADColor.palette[m.features.count % CADColor.palette.count]
            m.features.append(f)
            newID = f.id
        }
        selection = newID.map { [$0] } ?? []
        subSelection = []
    }

    func setSections(_ ids: [UUID], of id: UUID) { update(id, "Change Sections") { $0.sections = ids } }

    // MARK: Editing

    func deleteSelected() {
        if editingSketch != nil { sketchView?.deleteSelection(); return }
        let ids = Set(selection)
        guard !ids.isEmpty else { NSSound.beep(); return }
        perform(ids.count == 1 ? "Delete \(selectedFeature?.name ?? "Feature")" : "Delete Features") { m in
            m.features.removeAll { ids.contains($0.id) }
            for i in m.features.indices {
                m.features[i].inputs = m.features[i].inputs?.filter { !ids.contains($0) }
                if let p = m.features[i].profile, ids.contains(p) { m.features[i].profile = nil }
                m.features[i].sections = m.features[i].sections?.filter { !ids.contains($0) }
                if let s = m.features[i].support, ids.contains(s) { m.features[i].support = nil }
            }
        }
        selection = []
        subSelection = []
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

    /// FreeCAD's Space: the selected features shown or hidden.
    func toggleVisibility() {
        let ids = selection
        guard !ids.isEmpty else { NSSound.beep(); return }
        perform("Toggle Visibility") { m in for i in m.features.indices where ids.contains(m.features[i].id) { m.features[i].hidden = m.features[i].hidden == true ? nil : true } }
    }

    func showAll() { perform("Show All") { m in for i in m.features.indices { m.features[i].hidden = nil } } }

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
                    if let cs = m.features[j].sketch?.constraints {
                        m.features[j].sketch?.constraints = cs.map { c in var c = c; c.value = c.value.map(renamed); c.value2 = c.value2.map(renamed); return c }
                    }
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

    // MARK: Sketching

    func editSketch(_ id: UUID) {
        guard model.feature(id)?.sketch != nil else { return }
        editingSketch = id
        sketchSelection = []
        selectedConstraint = nil
        if sketchTool == .select { sketchTool = .line }
    }

    func finishSketch() {
        editingSketch = nil
        sketchSelection = []
        selectedConstraint = nil
    }

    var editedSketch: CADSketch? { editingSketch.flatMap(model.feature)?.sketch }

    /// The sketch as the Sketcher left it (one undo step).
    func replaceSketch(_ s: CADSketch, _ name: String) {
        guard let id = editingSketch else { return }
        update(id, name) { $0.sketch = s }
    }

    func updateEntity(_ e: CADSketchEntity) {
        guard let id = editingSketch else { return }
        update(id, "Change \(e.kind.title)") { f in
            if let i = f.sketch?.entities.firstIndex(where: { $0.id == e.id }) { f.sketch?.entities[i] = e }
        }
    }

    func removeEntity(_ entityID: UUID) {
        guard let id = editingSketch else { return }
        update(id, "Delete Shape") { f in
            guard var s = f.sketch else { return }
            s.entities.removeAll { $0.id == entityID }
            s.constraints = s.constraints?.filter { !$0.refs.contains { $0.entity == entityID } }
            f.sketch = s
        }
        sketchSelection = []
    }

    func setConstraintValue(_ cid: UUID, _ text: String, second: Bool = false) {
        guard let id = editingSketch ?? selection.last, let s = model.feature(id)?.sketch, let i = s.constraints?.firstIndex(where: { $0.id == cid }) else { return }
        var t = s
        if second { t.constraints?[i].value2 = text } else { t.constraints?[i].value = text }
        let (_, status) = CADSketchSolver.solve(t, values: build.parameterValues)
        if status.conflicting { return tell("The sketch can't take that size.") }
        update(id, "Change Dimension") { $0.sketch = t }
    }

    func removeConstraint(_ cid: UUID) {
        guard let id = editingSketch ?? selection.last else { return }
        update(id, "Delete Constraint") { $0.sketch?.constraints?.removeAll { $0.id == cid } }
        if selectedConstraint == cid { selectedConstraint = nil }
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

    /// The picked face or edge, in words (for the status bar).
    var subSelectionText: String? {
        guard let last = subSelection.last, let body = model.feature(last.body) else { return nil }
        let more = subSelection.count > 1 ? " (+\(subSelection.count - 1) more)" : ""
        switch last {
        case .face(_, let f): return "\(body.name) · Face \(f & 0xFFFF + 1)\(more)"
        case .edge(_, let e): return String(format: "%@ · %@ edge, %.2f mm%@", body.name, e.isStraight ? "Straight" : e.closed ? "Closed" : "Curved", e.length, more)
        }
    }

    /// A row of the feature tree: a feature and the features it's built from (a Part Design body's history
    /// flattened, as FreeCAD's Body lists it).
    struct Node: Identifiable {
        let feature: CADFeature
        let children: [Node]?
        var id: UUID { feature.id }
    }

    var tree: [Node] {
        let consumed = model.consumed()
        func own(_ f: CADFeature) -> [Node] {
            var kids: [Node] = []
            for id in [f.profile].compactMap({ $0 }) + (f.sections ?? []) { if let s = model.feature(id) { kids.append(Node(feature: s, children: nil)) } }
            for id in (f.inputs ?? []) where id != f.base { if let i = model.feature(id) { kids.append(node(i)) } }
            return kids
        }
        func chain(_ f: CADFeature) -> [Node] {
            let earlier = f.base.flatMap(model.feature).map(chain) ?? []
            let kids = own(f)
            return earlier + [Node(feature: f, children: kids.isEmpty ? nil : kids)]
        }
        func node(_ f: CADFeature) -> Node {
            let kids = (f.base.flatMap(model.feature).map(chain) ?? []) + own(f)
            return Node(feature: f, children: kids.isEmpty ? nil : kids)
        }
        return model.features.filter { !consumed.contains($0.id) }.map(node)
    }
}
