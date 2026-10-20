//
//  CADFreeCAD.swift
//  MxNoteONE
//
//  Working with FreeCAD (freecad.org), when it's installed: a model goes to FreeCAD as a FreeCAD document — Part
//  workbench objects, Sketcher sketches with their constraints, the parameters as a spreadsheet the dimensions are
//  bound to — to open there or to save; it's exported as STEP, IGES or BREP by FreeCAD's OpenCascade kernel (exact
//  surfaces). FreeCAD, STEP, IGES and BREP files come in as bodies (each visible object, triangulated face by face),
//  linked to their file: edited in FreeCAD and saved, the page follows.
//
//  FreeCAD runs out of sight for each job — freecadcmd, or FreeCAD itself with no window when colours and
//  visibility matter — with its own settings folder (so the user's FreeCAD settings aren't touched), running
//  CADFreeCADLibrary's Python on a folder holding job.json; it answers in result.json.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import simd

enum CADFreeCAD {
    enum Format: String, CaseIterable {
        case fcstd = "FCStd", step = "step", iges = "iges", brep = "brep"
        var title: String {
            switch self {
            case .fcstd: "FreeCAD Document"
            case .step: "STEP"
            case .iges: "IGES"
            case .brep: "BREP"
            }
        }
        var key: String { self == .fcstd ? "fcstd" : rawValue }
    }

    static let importTypes = ["fcstd", "step", "stp", "iges", "igs", "brep", "brp"]

    enum Failure: LocalizedError {
        case notInstalled, timedOut, failed(String)
        var errorDescription: String? {
            switch self {
            case .notInstalled: "FreeCAD isn't installed. Get it from freecad.org, then try again."
            case .timedOut: "FreeCAD didn't finish in time."
            case .failed(let s): s
            }
        }
    }

    /// FreeCAD.app: where Launch Services knows it, else in Applications.
    static var appURL: URL? {
        if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.freecad.FreeCAD") { return u }
        for dir in ["/Applications", NSHomeDirectory() + "/Applications"] {
            let u = URL(fileURLWithPath: dir).appending(path: "FreeCAD.app")
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    static var version: String? {
        appURL.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String }
    }

    /// The command-line FreeCAD inside the app.
    static var commandURL: URL? {
        guard let app = appURL else { return nil }
        for name in ["freecadcmd", "FreeCADCmd"] {
            let u = app.appending(path: "Contents/Resources/bin/\(name)")
            if FileManager.default.isExecutableFile(atPath: u.path) { return u }
        }
        return nil
    }

    static var guiURL: URL? {
        guard let app = appURL else { return nil }
        let u = app.appending(path: "Contents/MacOS/FreeCAD")
        return FileManager.default.isExecutableFile(atPath: u.path) ? u : nil
    }

    /// Our own folder for FreeCAD: its settings (FREECAD_USER_HOME), the Python, and jobs.
    static var home: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "MxNoteONE/FreeCAD")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func libraryFolder() throws -> URL {
        let dir = home.appending(path: "lib")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "mxnoteone_freecad.py")
        let data = Data(CADFreeCADLibrary.source.utf8)
        if (try? Data(contentsOf: file)) != data { try data.write(to: file) }
        return dir
    }

    /// Runs a job in FreeCAD and returns its answer. `gui` runs FreeCAD itself (hidden) for colours and visibility;
    /// if that fails, freecadcmd does it without them.
    static func run(_ job: [String: Any], gui: Bool, timeout: TimeInterval = 240) async throws -> [String: Any] {
        do {
            return try await runOnce(job, gui: gui, timeout: timeout)
        } catch let e as Failure where gui {
            if case .notInstalled = e { throw e }
            return try await runOnce(job, gui: false, timeout: timeout)
        }
    }

    private static func runOnce(_ job: [String: Any], gui: Bool, timeout: TimeInterval) async throws -> [String: Any] {
        guard let exe = gui ? guiURL : commandURL else { throw Failure.notInstalled }
        let lib = try libraryFolder()
        let folder = home.appending(path: "jobs/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let jobData = try JSONSerialization.data(withJSONObject: job)
        try jobData.write(to: folder.appending(path: "job.json"))
        let script = """
        import os, sys
        sys.path.insert(0, \(pythonString(lib.path)))
        try:
            import mxnoteone_freecad as mx
            mx.main(\(pythonString(folder.path)))
        finally:
            sys.stdout.flush()
            os._exit(0)
        """
        let runner = folder.appending(path: "run.py")
        try script.write(to: runner, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = exe
        process.arguments = [runner.path]
        var env = ProcessInfo.processInfo.environment
        env["FREECAD_USER_HOME"] = home.appending(path: "user").path
        if gui { env["QT_QPA_PLATFORM"] = "offscreen" }
        process.environment = env
        let logURL = folder.appending(path: "log.txt")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        process.standardOutput = log
        process.standardError = log
        process.currentDirectoryURL = folder
        try process.run()
        let resultURL = folder.appending(path: "result.json")
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: resultURL.path) {
            if !process.isRunning {
                // Gone without an answer.
                try? await Task.sleep(for: .milliseconds(300))
                if FileManager.default.fileExists(atPath: resultURL.path) { break }
                let tail = (try? String(contentsOf: logURL, encoding: .utf8))?.split(separator: "\n").suffix(4).joined(separator: " ") ?? ""
                throw Failure.failed("FreeCAD stopped without finishing. \(tail)")
            }
            if Date() > deadline { process.terminate(); throw Failure.timedOut }
            try? await Task.sleep(for: .milliseconds(150))
        }
        if process.isRunning {
            try? await Task.sleep(for: .milliseconds(500))
            if process.isRunning { process.terminate() }
        }
        try? log.close()
        guard let data = try? Data(contentsOf: resultURL), let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.failed("FreeCAD's answer couldn't be read.")
        }
        if result["ok"] as? Bool != true {
            throw Failure.failed((result["error"] as? String).map { "FreeCAD: \($0)" } ?? "FreeCAD couldn't do it.")
        }
        // Old jobs go after a day.
        cleanJobs()
        var out = result
        out["folder"] = folder.path
        return out
    }

    private static func pythonString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func cleanJobs() {
        let dir = home.appending(path: "jobs")
        let old = Date().addingTimeInterval(-86400)
        for u in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let d = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, d < old { try? FileManager.default.removeItem(at: u) }
        }
    }

    // MARK: Models to FreeCAD

    /// What FreeCAD needs besides the model: every number worked out, sketch planes, axes, hole positions and the
    /// edges to fillet (as points, matched to FreeCAD's edges there).
    static func job(_ model: CADModel, build: CADBuild, builder: CADBuilder, assetFile: (String) -> URL?) throws -> [String: Any] {
        let encoded = try JSONEncoder().encode(model)
        guard let modelJSON = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { throw Failure.failed("The model couldn't be written.") }
        let vars = build.parameterValues
        func num(_ s: String) -> Double { (try? CADExpression.evaluate(s, vars)) ?? 0 }
        func arr(_ v: SIMD3<Double>) -> [Double] { [v.x, v.y, v.z] }
        var features: [String: Any] = [:]
        for f in model.features {
            var r: [String: Any] = [:]
            var values: [String: Double] = [:]
            for field in CADFeature.fields(f.kind) where field.choices == nil { values[field.key] = num(f.values[field.key] ?? field.value) }
            r["values"] = values
            let p = f.placement
            r["placement"] = [p.x, p.y, p.z, p.rx, p.ry, p.rz].map(num)
            func sketchInfo(_ s: CADSketch, offset: Double) -> [String: Any] {
                let a = s.axes
                return ["u": arr(a.u), "v": arr(a.v), "n": arr(a.n), "origin": arr(a.origin), "offset": offset]
            }
            let own: (CADSketch, Double)? = {
                if let s = build.sketches[f.id] ?? f.sketch { return (s, num(s.offset)) }
                if let pid = f.profile, let pf = model.feature(pid), let s = build.sketches[pid] ?? pf.sketch { return (s, num(s.offset)) }
                return nil
            }()
            if let s = build.sketches[f.id] ?? f.sketch {
                r["sketch"] = sketchInfo(s, offset: num(s.offset))
                var cs: [String: Any] = [:]
                for c in s.constraints ?? [] {
                    if c.kind == .lock { cs[c.id.uuidString] = [num(c.value ?? "0"), num(c.value2 ?? "0")] } else if let v = c.value { cs[c.id.uuidString] = num(v) }
                }
                r["constraints"] = cs
                // The model JSON carries the solved points.
            }
            if let (s, offset) = own {
                let a = s.axes
                let base = a.origin + a.n * offset
                switch f.kind {
                case .revolve:
                    let horizontal = f.choice("axis") == "Horizontal"
                    var dir = horizontal ? -a.u : -a.v
                    if f.choice("reversed") == "Yes" { dir = -dir }
                    r["axis"] = ["base": arr(base), "dir": arr(dir)]
                case .helix:
                    let outer = s.loops(segments: model.smoothness).max { abs($0.area) < abs($1.area) }
                    let radius = outer.map { $0.points.reduce(0) { $0 + $1.x } / Double(max(1, $0.points.count)) } ?? 10
                    r["axis"] = ["base": arr(base), "dir": arr(a.v), "u": arr(a.u), "radius": radius]
                case .extrude:
                    let baseSolid = f.base.flatMap { build.solids[$0] }
                    r["throughAll"] = CADBuilder.throughAll(baseSolid, from: base)
                case .hole:
                    let baseSolid = f.base.flatMap { build.solids[$0] }
                    let through = f.choice("depthType") == "Through All"
                    let depth = through ? CADBuilder.throughAll(baseSolid, from: base) : values["depth"] ?? 10
                    let set = values["diameter"] ?? 0
                    let cutD = values["cutDiameter"] ?? 12, cutDepth = values["cutDepth"] ?? 3, angle = values["cutAngle"] ?? 90
                    r["holeAxis"] = arr(f.choice("reversed") == "Yes" ? a.n : -a.n)
                    r["holes"] = s.entities.filter { $0.kind == .circle && !$0.isConstruction && $0.points.count >= 2 }.map { c -> [String: Any] in
                        let rad = set > 0 ? set / 2 : c.radius
                        let t = tan(angle / 2 * .pi / 180)
                        var h: [String: Any] = ["centre": arr(CADBuilder.point(c.points[0], s, offset: offset)), "radius": rad, "depth": depth,
                                                "tip": f.choice("point") == "Angled" && !through ? rad / tan(59 * Double.pi / 180) : 0,
                                                "boreRadius": cutD / 2, "sinkTan": t]
                        if f.choice("cut") == "Counterbore", cutD / 2 > rad { h["bore"] = cutDepth }
                        if f.choice("cut") == "Countersink", cutD / 2 > rad, t > 0 { h["sink"] = (cutD / 2 - rad) / t }
                        return h
                    }
                default: break
                }
            }
            if f.kind.isDressUp, let b = f.base, let solid = build.solids[b] {
                let all = builder.edges(solid)
                var lines: [[[Double]]] = []
                for ref in f.edges ?? [] {
                    let found = all.filter { min($0.a, $0.b) == min(ref.a, ref.b) && max($0.a, $0.b) == max(ref.a, ref.b) }
                    let chosen: [CADBodyEdge]
                    if let near = ref.near, found.count > 1 {
                        chosen = [found.min { e1, e2 in (e1.points.map { simd_distance($0, near) }.min() ?? .infinity) < (e2.points.map { simd_distance($0, near) }.min() ?? .infinity) }!]
                    } else {
                        chosen = found
                    }
                    for e in chosen { lines.append(e.points.map(arr)) }
                }
                r["edges"] = lines
            }
            if f.kind == .mesh {
                if let s = f.source, let file = s.path.map({ URL(fileURLWithPath: $0) }) ?? s.asset.flatMap(assetFile), FileManager.default.fileExists(atPath: file.path) {
                    r["source"] = ["file": file.path, "object": s.object]
                } else if let data = f.meshData {
                    r["triangles"] = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }.map { Double($0) }
                }
            }
            features[f.id.uuidString] = r
        }
        return ["model": modelJSON, "resolved": ["params": vars, "features": features]]
    }

    // MARK: FreeCAD to models

    struct Imported {
        var name: String
        var label: String
        var color: CADColor?
        var triangles: Data
        var faces: Data
        var normals: Data
    }

    /// The visible shapes of a FreeCAD (STEP, IGES, BREP) file, triangulated.
    static func read(_ url: URL) async throws -> [Imported] {
        let result = try await run(["command": "import", "path": url.path], gui: true)
        var out: [Imported] = []
        for o in result["objects"] as? [[String: Any]] ?? [] {
            guard let file = o["file"] as? String, let data = try? Data(contentsOf: URL(fileURLWithPath: file)), data.count >= 4 else { continue }
            let n = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) })
            let pBytes = n * 9 * 4, fBytes = n * 4
            guard data.count >= 4 + 2 * pBytes + fBytes, n > 0 else { continue }
            let tris = data.subdata(in: 4..<(4 + pBytes)), normals = data.subdata(in: (4 + pBytes)..<(4 + 2 * pBytes))
            let faces = data.subdata(in: (4 + 2 * pBytes)..<(4 + 2 * pBytes + fBytes))
            let rgb = o["color"] as? [Double]
            out.append(Imported(name: o["name"] as? String ?? "Shape", label: o["label"] as? String ?? (o["name"] as? String ?? "Shape"),
                                color: rgb.flatMap { $0.count >= 3 ? CADColor(r: $0[0], g: $0[1], b: $0[2]) : nil }, triangles: tris, faces: faces, normals: normals))
        }
        if out.isEmpty { throw Failure.failed("There was nothing to show in \(url.lastPathComponent).") }
        return out
    }

    static func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// Bodies for a file's shapes (added to a model, or a new one).
    static func features(_ items: [Imported], into model: inout CADModel, source: (Imported) -> CADSource) -> [UUID] {
        var ids: [UUID] = []
        for item in items {
            var f = model.make(.mesh, name: model.uniqueName(item.label))
            f.meshData = item.triangles
            f.meshFaces = item.faces
            f.meshNormals = item.normals
            f.color = item.color ?? CADColor.palette[model.features.count % CADColor.palette.count]
            f.source = source(item)
            model.features.append(f)
            ids.append(f.id)
        }
        return ids
    }

    /// The model with its FreeCAD bodies read again from `url` (what's in the file now).
    static func refreshed(_ model: CADModel, from url: URL, items: [Imported], matching: (CADSource) -> Bool) -> CADModel {
        var m = model
        let date = modified(url.path)
        var seen = Set<String>()
        for i in m.features.indices {
            guard let s = m.features[i].source, matching(s), let item = items.first(where: { $0.name == s.object }) else { continue }
            seen.insert(item.name)
            m.features[i].meshData = item.triangles
            m.features[i].meshFaces = item.faces
            m.features[i].meshNormals = item.normals
            if let c = item.color { m.features[i].color = c }
            m.features[i].source?.label = item.label
            m.features[i].source?.modified = date
        }
        // Objects new in the file come in too.
        let template = m.features.first { $0.source.map(matching) == true }?.source
        if let template {
            _ = features(items.filter { !seen.contains($0.name) }, into: &m) { item in
                var s = template
                s.object = item.name
                s.label = item.label
                s.modified = date
                return s
            }
        }
        return m
    }
}

// MARK: - Commands

@MainActor
enum CADFreeCADCommands {
    /// Working copies of FreeCAD files kept in a notebook, open in FreeCAD (asset name → file, and when it was
    /// written).
    static var workingCopies: [String: URL] = [:]
    private static var workingWritten: [String: Date] = [:]

    private static func assetFile(_ doc: CADDocument) -> (String) -> URL? {
        { name in
            if let w = workingCopies[name] { return w }
            guard let ref = doc.pageRef, let data = NotebookStore.shared.assetData(name, for: ref) else { return nil }
            let u = CADFreeCAD.home.appending(path: "assets/\(name)")
            try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: u)
            return u
        }
    }

    private static func fail(_ doc: CADDocument?, _ error: Error) {
        doc?.busy = nil
        NotebookStore.shared.alert = AlertInfo(title: "FreeCAD", message: error.localizedDescription)
    }

    private static func requireFreeCAD() -> Bool {
        if CADFreeCAD.appURL != nil { return true }
        let alert = NSAlert()
        alert.messageText = "FreeCAD isn't installed"
        alert.informativeText = "MxNoteONE uses FreeCAD (free, from freecad.org) to open models in FreeCAD, to read and write FreeCAD, STEP, IGES and BREP files."
        alert.addButton(withTitle: "Get FreeCAD…")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(URL(string: "https://www.freecad.org/downloads.php")!) }
        return false
    }

    static func export(_ doc: CADDocument, _ format: CADFreeCAD.Format) {
        guard requireFreeCAD() else { return }
        let panel = NSSavePanel()
        let ext = format == .fcstd ? "FCStd" : format.rawValue
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]
        panel.nameFieldStringValue = doc.model.name + "." + ext
        guard panel.runModal() == .OK, let url = panel.url else { return }
        save(doc, format, to: url, open: false)
    }

    /// The model as a FreeCAD document, opened in FreeCAD.
    static func openInFreeCAD(_ doc: CADDocument) {
        guard requireFreeCAD() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "FCStd") ?? .data]
        panel.nameFieldStringValue = doc.model.name + ".FCStd"
        panel.message = "Save the model as a FreeCAD document, to open in FreeCAD"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        save(doc, .fcstd, to: url, open: true)
    }

    private static func save(_ doc: CADDocument, _ format: CADFreeCAD.Format, to url: URL, open: Bool) {
        do {
            var job = try CADFreeCAD.job(doc.model, build: doc.build, builder: doc.builder, assetFile: assetFile(doc))
            job["command"] = "document"
            job["output"] = [format.key: url.path]
            doc.busy = "FreeCAD is making the \(format.title)…"
            Task { @MainActor in
                do {
                    let result = try await CADFreeCAD.run(job, gui: true)
                    doc.busy = nil
                    let problems = (result["log"] as? [String] ?? []).filter { $0.hasPrefix("couldn't make") }
                    if !problems.isEmpty { doc.tell("FreeCAD made it, but: " + problems.joined(separator: "; ")) }
                    if open, let app = CADFreeCAD.appURL {
                        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
                    } else if !open {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                } catch {
                    fail(doc, error)
                }
            }
        } catch {
            fail(doc, error)
        }
    }

    /// FreeCAD, STEP, IGES and BREP files as bodies, following the file.
    static func importFile(_ doc: CADDocument) {
        guard requireFreeCAD() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = CADFreeCAD.importTypes.compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose a FreeCAD, STEP, IGES or BREP file — its bodies follow the file as it changes"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        doc.busy = "FreeCAD is reading \(url.lastPathComponent)…"
        Task { @MainActor in
            do {
                let items = try await CADFreeCAD.read(url)
                doc.busy = nil
                var ids: [UUID] = []
                doc.perform("Import \(url.lastPathComponent)") { m in
                    ids = CADFreeCAD.features(items, into: &m) { item in
                        CADSource(path: url.path, object: item.name, label: item.label, format: url.pathExtension.lowercased(), modified: CADFreeCAD.modified(url.path))
                    }
                }
                doc.selection = ids
                doc.viewport?.fit()
            } catch {
                fail(doc, error)
            }
        }
    }

    /// Opens a body's FreeCAD file in FreeCAD (a notebook's copy as a working file, saved back when FreeCAD saves).
    static func editSource(_ doc: CADDocument, _ id: UUID) {
        guard requireFreeCAD(), let s = doc.model.feature(id)?.source, let app = CADFreeCAD.appURL else { return }
        var file: URL?
        if let p = s.path { file = URL(fileURLWithPath: p) } else if let a = s.asset, let ref = doc.pageRef {
            file = openWorkingCopy(asset: a, format: s.format, ref: ref)
        }
        guard let file, FileManager.default.fileExists(atPath: file.path) else { return fail(doc, CADFreeCAD.Failure.failed("The file isn't there any more.")) }
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    static func openWorkingCopy(asset: String, format: String, ref: PageRef) -> URL? {
        if let w = workingCopies[asset] { return w }
        guard let data = NotebookStore.shared.assetData(asset, for: ref) else { return nil }
        let dir = CADFreeCAD.home.appending(path: "editing/\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let u = dir.appending(path: (asset as NSString).deletingPathExtension + "." + (format == "fcstd" ? "FCStd" : format))
        guard (try? data.write(to: u)) != nil else { return nil }
        workingCopies[asset] = u
        workingWritten[asset] = CADFreeCAD.modified(u.path)
        return u
    }

    /// The file a source is followed through: the linked file, or the working copy open in FreeCAD.
    static func followed(_ s: CADSource) -> URL? {
        if let p = s.path { return URL(fileURLWithPath: p) }
        return s.asset.flatMap { workingCopies[$0] }
    }

    static func reload(_ doc: CADDocument, _ id: UUID) {
        guard let s = doc.model.feature(id)?.source, let url = followed(s) ?? s.asset.flatMap(assetFile(doc)) else { return }
        refresh(doc, url: url, source: s)
    }

    static func reloadAll(_ doc: CADDocument) {
        var done = Set<String>()
        for f in doc.model.features {
            guard let s = f.source, let url = followed(s), done.insert(url.path).inserted else { continue }
            refresh(doc, url: url, source: s)
        }
    }

    private static func refresh(_ doc: CADDocument, url: URL, source: CADSource) {
        doc.busy = "FreeCAD is reading \(url.lastPathComponent)…"
        Task { @MainActor in
            if let m = await refreshed(doc.model, [(url, source)], ref: doc.pageRef) { doc.replace(m, name: "Update from FreeCAD") }
            doc.busy = nil
        }
    }

    /// The model with the changed files read again (a working copy's changes kept in the notebook too).
    static func refreshed(_ model: CADModel, _ changed: [(URL, CADSource)], ref: PageRef?) async -> CADModel? {
        var m = model
        var any = false
        for (url, source) in changed {
            do {
                let items = try await CADFreeCAD.read(url)
                m = CADFreeCAD.refreshed(m, from: url, items: items) { $0.path == source.path && $0.asset == source.asset }
                if let a = source.asset, source.path == nil, let ref, let data = try? Data(contentsOf: url) {
                    NotebookStore.shared.overwriteAsset(a, data: data, for: ref)
                    workingWritten[a] = CADFreeCAD.modified(url.path)
                }
                any = true
            } catch {
                // Mid-save, or not a file FreeCAD can read now: tried again when it next changes.
                for i in m.features.indices where m.features[i].source == source { m.features[i].source?.modified = CADFreeCAD.modified(url.path) }
                any = true
            }
        }
        return any ? m : nil
    }

    /// Sources whose file changed since they were read (linked files, and working copies FreeCAD saved).
    static func changedSources(_ model: CADModel) -> [(URL, CADSource)] {
        var out: [(URL, CADSource)] = []
        var seen = Set<String>()
        for f in model.features {
            guard let s = f.source, let url = followed(s), seen.insert(url.path).inserted, let date = CADFreeCAD.modified(url.path) else { continue }
            let since = max(s.modified ?? .distantPast, s.asset.flatMap { workingWritten[$0] } ?? .distantPast)
            if date.timeIntervalSince(since) > 0.5 { out.append((url, s)) }
        }
        return out
    }
}

/// The inspector's note about FreeCAD.
struct CADFreeCADStatus: View {
    var body: some View {
        Section("FreeCAD") {
            if let app = CADFreeCAD.appURL {
                LabeledContent("FreeCAD", value: CADFreeCAD.version ?? "installed")
                Text("Open in FreeCAD, export STEP / IGES / BREP, and import FreeCAD files (they follow the file) — from the FreeCAD menu or the toolbar.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open FreeCAD") { NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil) }
            } else {
                Text("Install FreeCAD (free, from freecad.org) to open models in it and to read and write FreeCAD, STEP, IGES and BREP files.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Get FreeCAD…") { NSWorkspace.shared.open(URL(string: "https://www.freecad.org/downloads.php")!) }
            }
        }
    }
}
