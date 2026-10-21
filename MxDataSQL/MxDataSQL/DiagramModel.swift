//
//  DiagramModel.swift
//  MxDataSQL
//
//  A Diagram window's state: the DBML document, where each table and note is, how each
//  relationship is drawn (automatic, straight, quadratic or cubic Bézier with its control points),
//  what is selected, and saving it all back into the .dbml file.
//

import AppKit
import SwiftUI

enum DiagramSelection: Hashable {
    case table(String)
    case ref(String)
    case note(String)
}

/// Which side of a table a relationship leaves from.
enum DiagramSide { case left, right }

/// A relationship's drawn geometry, in canvas coordinates.
struct RefGeometry {
    var start: CGPoint
    var end: CGPoint
    var startSide: DiagramSide
    var endSide: DiagramSide
    var style: CurveStyle
    /// Control points: one for quadratic, two for automatic and cubic, none for straight.
    var controls: [CGPoint]

    var path: Path {
        var p = Path()
        p.move(to: start)
        switch style {
        case .straight: p.addLine(to: end)
        case .quadratic: p.addQuadCurve(to: end, control: controls[0])
        case .automatic, .cubic: p.addCurve(to: end, control1: controls[0], control2: controls[1])
        }
        return p
    }

    /// Direction the curve arrives at `end` from (unit vector pointing out of the table).
    var endTangent: CGVector {
        let from = style == .straight ? start : (style == .quadratic ? controls[0] : controls[1])
        return unit(CGVector(dx: from.x - end.x, dy: from.y - end.y), fallback: endSide == .left ? -1 : 1)
    }
    var startTangent: CGVector {
        let to = style == .straight ? end : controls[0]
        return unit(CGVector(dx: to.x - start.x, dy: to.y - start.y), fallback: startSide == .left ? -1 : 1)
    }
    private func unit(_ v: CGVector, fallback: CGFloat) -> CGVector {
        let len = (v.dx * v.dx + v.dy * v.dy).squareRoot()
        return len < 0.001 ? CGVector(dx: fallback, dy: 0) : CGVector(dx: v.dx / len, dy: v.dy / len)
    }
}

@MainActor
@Observable
final class DiagramModel {
    var document: DBMLDocument
    var layout: DiagramLayout
    var notes: [DBMLStickyNote]
    var fileURL: URL?
    var selection: DiagramSelection?
    var editingNote: String?
    var zoom: Double
    var dirty = false
    var errorMessage: String?
    var infoMessage: String?
    /// What the scroll view shows, in zoomed coordinates (for Add Note).
    var visibleRect = CGRect.zero
    /// Keeps the window's close prompt alive (see DiagramWindow.swift).
    @ObservationIgnored var closeGuard: AnyObject?
    /// Shows unsaved changes in the close button, as documents do.
    @ObservationIgnored weak var window: NSWindow?

    static let headerHeight: CGFloat = 28
    static let rowHeight: CGFloat = 19
    static let margin: CGFloat = 60

    /// Table sizes, computed once from the columns (the boxes don't depend on fonts at run time).
    private(set) var sizes: [String: CGSize] = [:]

    init(document: DBMLDocument, fileURL: URL?) {
        self.document = document
        self.layout = document.layout
        self.notes = document.notes
        self.fileURL = fileURL
        self.zoom = document.layout.zoom ?? 1
        for t in document.tables { sizes[t.id] = Self.size(of: t) }
        let missing = document.tables.filter { layout.tables[$0.id] == nil }
        if !missing.isEmpty { arrange(onlyMissing: !layout.tables.isEmpty) }
        for note in notes where layout.notes[note.id] == nil {
            layout.notes[note.id] = NoteFrame(x: Self.margin, y: Self.margin)
        }
    }

    var title: String { (fileURL?.lastPathComponent ?? "Untitled.dbml") }

    static func size(of table: DBMLTable) -> CGSize {
        let nameChars = max(table.columns.map(\.name.count).max() ?? 0, 4)
        let typeChars = table.columns.map(\.type.count).max() ?? 0
        let titleChars = table.id.count
        let body = 34 + CGFloat(nameChars) * 7 + 14 + CGFloat(typeChars) * 6.4
        let width = min(420, max(170, body, 40 + CGFloat(titleChars) * 7.4))
        return CGSize(width: width, height: headerHeight + CGFloat(max(table.columns.count, 1)) * rowHeight + 6)
    }

    func frame(of table: String) -> CGRect {
        let p = layout.tables[table] ?? DiagramPoint(x: 0, y: 0)
        return CGRect(origin: CGPoint(x: p.x, y: p.y), size: sizes[table] ?? CGSize(width: 170, height: 60))
    }

    func noteFrame(_ id: String) -> CGRect {
        let f = layout.notes[id] ?? NoteFrame(x: Self.margin, y: Self.margin)
        return CGRect(x: f.x, y: f.y, width: f.width, height: f.height)
    }

    /// Canvas extent: everything plus a margin, at least a screenful.
    var canvasSize: CGSize {
        var maxX: CGFloat = 1200, maxY: CGFloat = 800
        for t in document.tables { let f = frame(of: t.id); maxX = max(maxX, f.maxX); maxY = max(maxY, f.maxY) }
        for n in notes { let f = noteFrame(n.id); maxX = max(maxX, f.maxX); maxY = max(maxY, f.maxY) }
        for r in document.refs { for c in geometry(of: r).controls { maxX = max(maxX, c.x); maxY = max(maxY, c.y) } }
        return CGSize(width: maxX + 400, height: maxY + 400)
    }

    // MARK: Relationships

    func columnY(_ table: String, _ column: String?) -> CGFloat {
        let f = frame(of: table)
        guard let column, let index = document.table(table)?.columns.firstIndex(where: { $0.name == column }) else {
            return f.minY + Self.headerHeight / 2
        }
        return f.minY + Self.headerHeight + CGFloat(index) * Self.rowHeight + Self.rowHeight / 2
    }

    func curve(_ ref: DBMLRef) -> RefCurve { layout.refs[ref.id] ?? RefCurve() }

    func geometry(of ref: DBMLRef) -> RefGeometry {
        let a = frame(of: ref.from.table), b = frame(of: ref.to.table)
        let ya = columnY(ref.from.table, ref.from.columns.first), yb = columnY(ref.to.table, ref.to.columns.first)
        let startSide: DiagramSide, endSide: DiagramSide
        if ref.from.table == ref.to.table {
            (startSide, endSide) = (.right, .right)
        } else if a.maxX + 30 < b.minX {
            (startSide, endSide) = (.right, .left)
        } else if b.maxX + 30 < a.minX {
            (startSide, endSide) = (.left, .right)
        } else {
            // Overlapping columns of the canvas: loop out on the side with more room.
            (startSide, endSide) = a.midX <= b.midX ? (.left, .left) : (.right, .right)
        }
        let start = CGPoint(x: startSide == .right ? a.maxX : a.minX, y: ya)
        let end = CGPoint(x: endSide == .right ? b.maxX : b.minX, y: yb)
        let c = curve(ref)
        let auto = automaticControls(start, end, startSide, endSide)
        var controls: [CGPoint]
        switch c.style {
        case .straight: controls = []
        case .automatic: controls = auto
        case .quadratic:
            let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            let o = c.c1 ?? DiagramPoint(x: 0, y: -60)
            controls = [CGPoint(x: mid.x + o.x, y: mid.y + o.y)]
        case .cubic:
            let o1 = c.c1.map { CGPoint(x: start.x + $0.x, y: start.y + $0.y) } ?? auto[0]
            let o2 = c.c2.map { CGPoint(x: end.x + $0.x, y: end.y + $0.y) } ?? auto[1]
            controls = [o1, o2]
        }
        return RefGeometry(start: start, end: end, startSide: startSide, endSide: endSide, style: c.style, controls: controls)
    }

    private func automaticControls(_ s: CGPoint, _ e: CGPoint, _ ss: DiagramSide, _ es: DiagramSide) -> [CGPoint] {
        let reach = max(50, min(220, abs(e.x - s.x) / 2 + (ss == es ? 60 : 0)))
        return [CGPoint(x: s.x + (ss == .right ? reach : -reach), y: s.y),
                CGPoint(x: e.x + (es == .right ? reach : -reach), y: e.y)]
    }

    func setStyle(_ style: CurveStyle, for refID: String) {
        guard let ref = document.refs.first(where: { $0.id == refID }) else { return }
        let g = geometry(of: ref)
        var c = RefCurve(style: style)
        switch style {
        case .quadratic:
            // Start bowed away from the straight line, so the control point is easy to grab.
            let dx = g.end.x - g.start.x, dy = g.end.y - g.start.y
            let len = max(1, (dx * dx + dy * dy).squareRoot())
            c.c1 = DiagramPoint(x: -dy / len * 70, y: dx / len * 70)
        case .cubic:
            // Begin from the automatic curve.
            let auto = automaticControls(g.start, g.end, g.startSide, g.endSide)
            c.c1 = DiagramPoint(x: auto[0].x - g.start.x, y: auto[0].y - g.start.y)
            c.c2 = DiagramPoint(x: auto[1].x - g.end.x, y: auto[1].y - g.end.y)
        default: break
        }
        layout.refs[refID] = style == .automatic ? nil : c
        changed()
    }

    /// Moves control point `index` (0 or 1) of a quadratic / cubic relationship to `point`.
    func moveControl(_ index: Int, of refID: String, to point: CGPoint) {
        guard let ref = document.refs.first(where: { $0.id == refID }) else { return }
        let g = geometry(of: ref)
        var c = curve(ref)
        switch c.style {
        case .quadratic:
            let mid = CGPoint(x: (g.start.x + g.end.x) / 2, y: (g.start.y + g.end.y) / 2)
            c.c1 = DiagramPoint(x: point.x - mid.x, y: point.y - mid.y)
        case .cubic:
            if index == 0 { c.c1 = DiagramPoint(x: point.x - g.start.x, y: point.y - g.start.y) }
            else { c.c2 = DiagramPoint(x: point.x - g.end.x, y: point.y - g.end.y) }
        default: return
        }
        layout.refs[refID] = c
        changed()
    }

    func refs(touching table: String) -> Set<String> {
        Set(document.refs.filter { $0.from.table == table || $0.to.table == table }.map(\.id))
    }

    // MARK: Tables and notes

    func moveTable(_ id: String, to origin: CGPoint) {
        layout.tables[id] = DiagramPoint(x: max(0, origin.x.rounded()), y: max(0, origin.y.rounded()))
        changed()
    }

    func addNote(at point: CGPoint) {
        var n = notes.count + 1
        while notes.contains(where: { $0.id == "mx_note_\(n)" }) { n += 1 }
        let id = "mx_note_\(n)"
        notes.append(DBMLStickyNote(id: id, text: "Note", isOwn: true))
        layout.notes[id] = NoteFrame(x: max(0, point.x), y: max(0, point.y))
        selection = .note(id)
        editingNote = id
        changed()
    }

    func addNoteAtVisibleCenter() {
        let z = max(zoom, 0.01)
        let center = visibleRect.isEmpty ? CGPoint(x: 200, y: 200)
            : CGPoint(x: visibleRect.midX / z - 110, y: visibleRect.midY / z - 60)
        addNote(at: center)
    }

    func setNoteText(_ id: String, _ text: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }), notes[i].isOwn, notes[i].text != text else { return }
        notes[i].text = text
        changed()
    }

    func moveNote(_ id: String, to frame: CGRect) {
        layout.notes[id] = NoteFrame(x: max(0, frame.minX.rounded()), y: max(0, frame.minY.rounded()),
                                     width: max(120, frame.width.rounded()), height: max(60, frame.height.rounded()))
        changed()
    }

    func deleteNote(_ id: String) {
        guard notes.first(where: { $0.id == id })?.isOwn == true else { return }
        notes.removeAll { $0.id == id }
        layout.notes[id] = nil
        if selection == .note(id) { selection = nil }
        changed()
    }

    func deleteSelection() {
        switch selection {
        case .note(let id): deleteNote(id)
        case .ref(let id): setStyle(.automatic, for: id)
        default: break
        }
    }

    // MARK: Arrangement

    /// Lays the tables out: one block per table group (schema), tables ordered so related ones sit
    /// together, packed into columns. With `onlyMissing`, tables that have a position keep it and new
    /// ones go below everything.
    func arrange(onlyMissing: Bool = false) {
        let gap: CGFloat = 70
        var blocks: [[String]] = []
        var placed = Set<String>()
        for g in document.groups {
            let members = g.tables.filter { sizes[$0] != nil && placed.insert($0).inserted }
            if !members.isEmpty { blocks.append(members) }
        }
        let rest = document.tables.map(\.id).filter { placed.insert($0).inserted }
        if !rest.isEmpty { blocks.insert(rest, at: 0) }

        var neighbours: [String: [String]] = [:]
        for r in document.refs where r.from.table != r.to.table {
            neighbours[r.from.table, default: []].append(r.to.table)
            neighbours[r.to.table, default: []].append(r.from.table)
        }

        var originX = Self.margin
        var originY = Self.margin
        if onlyMissing {
            let done = document.tables.filter { layout.tables[$0.id] != nil }.map { frame(of: $0.id) }
            originY = (done.map(\.maxY).max() ?? 0) + gap * 1.5
            blocks = blocks.map { $0.filter { layout.tables[$0] == nil } }.filter { !$0.isEmpty }
        }
        for block in blocks {
            // Order: breadth-first from the most connected table, so neighbours end up close.
            var order: [String] = []
            var seen = Set<String>()
            let members = Set(block)
            for start in block.sorted(by: { (neighbours[$0]?.count ?? 0) > (neighbours[$1]?.count ?? 0) }) where !seen.contains(start) {
                var queue = [start]
                seen.insert(start)
                while !queue.isEmpty {
                    let t = queue.removeFirst()
                    order.append(t)
                    for n in (neighbours[t] ?? []) where members.contains(n) && seen.insert(n).inserted { queue.append(n) }
                }
            }
            let columns = max(1, Int(Double(order.count).squareRoot().rounded(.up)))
            var heights = Array(repeating: originY, count: columns)
            var widths = Array(repeating: CGFloat(0), count: columns)
            var assignment: [(String, Int, CGFloat)] = []
            for t in order {
                let col = heights.indices.min { heights[$0] < heights[$1] } ?? 0
                assignment.append((t, col, heights[col]))
                heights[col] += (sizes[t]?.height ?? 60) + gap * 0.6
                widths[col] = max(widths[col], sizes[t]?.width ?? 170)
            }
            var xs: [CGFloat] = []
            var x = originX
            for w in widths { xs.append(x); x += w + gap }
            for (t, col, y) in assignment { layout.tables[t] = DiagramPoint(x: xs[col], y: y) }
            originX = x + gap
        }
        if !onlyMissing { layout.refs = [:] }
    }

    func autoArrange() {
        arrange()
        changed()
    }

    /// Bounding boxes of the table groups, for their background panels.
    var groupFrames: [(name: String, frame: CGRect)] {
        guard document.groups.count > 0 else { return [] }
        return document.groups.compactMap { g in
            let frames = g.tables.filter { sizes[$0] != nil }.map { frame(of: $0) }
            guard let first = frames.first else { return nil }
            let box = frames.dropFirst().reduce(first) { $0.union($1) }
            return (g.name, box.insetBy(dx: -24, dy: -36).offsetBy(dx: 0, dy: -8))
        }
    }

    // MARK: Saving

    func changed() {
        dirty = true
        window?.isDocumentEdited = true
    }

    /// Writes the diagram (notes and layout) back into the file; the rest of the file is kept as is.
    func save() -> Bool {
        guard let url = fileURL else { return saveAs() }
        layout.zoom = zoom
        let text = document.fileText(notes: notes, layout: layout)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            dirty = false
            window?.isDocumentEdited = false
            infoMessage = "Saved \(url.lastPathComponent)"
            return true
        } catch {
            errorMessage = "Could not save \(url.lastPathComponent): \(error.localizedDescription)"
            return false
        }
    }

    func saveAs() -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [DBMLFile.type]
        panel.nameFieldStringValue = fileURL?.lastPathComponent ?? "diagram.dbml"
        panel.title = "Save Diagram As"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        fileURL = url
        return save()
    }
}
