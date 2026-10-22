//
//  DBMLDiagram.swift
//  Shared/DBML — used by MxDataSQL and MxNoteONE
//
//  A DBML diagram: the DBML, where each table (and enum) sits, how each relationship is drawn
//  (automatic, straight, or a quadratic or cubic Bézier through its control points, from the side
//  of each table chosen), the diagram's own notes, and the frames of the DBML's sticky notes. It
//  reads and writes MxDataSQL's .dbml files (the DBML, then a section with the notes and a layout
//  comment), arranges tables (a block per table group or schema, related tables together, packed in
//  columns), cuts out one schema, and is laid out and drawn the same in both apps: a header colour
//  per schema, keys and foreign-key links on the columns, crow's-foot ends, schema panels.
//

import AppKit

// MARK: - Points, sides, curves, notes

struct DBMLPoint: Codable, Equatable, Hashable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) { self.x = x; self.y = y }
    init(_ p: CGPoint) { x = p.x; y = p.y }
    var cg: CGPoint { CGPoint(x: x, y: y) }
}

/// The side of a table a relationship leaves or meets.
enum DBMLSide: String, Codable, CaseIterable {
    case left, right
}

/// How a relationship's line runs between its tables.
enum DBMLCurveStyle: String, Codable, CaseIterable, Identifiable {
    /// A smooth S-curve from the tables' positions.
    case automatic
    case straight
    /// One control point (kept as an offset from the middle of the ends).
    case quadratic
    /// Two control points (kept as offsets from the start and from the end).
    case cubic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .straight: "Straight Line"
        case .quadratic: "Quadratic Bézier"
        case .cubic: "Cubic Bézier"
        }
    }

    var symbol: String {
        switch self {
        case .automatic: "point.bottomleft.forward.to.point.topright.scurvepath"
        case .straight: "line.diagonal"
        case .quadratic: "point.topleft.down.to.point.bottomright.curvepath"
        case .cubic: "point.bottomleft.forward.to.point.topright.scurvepath.fill"
        }
    }
}

/// A relationship's line as it was shaped (nothing set: the diagram's way of drawing lines, from automatic sides).
struct DBMLRefCurve: Equatable {
    var style: DBMLCurveStyle?
    var c1: CGPoint?
    var c2: CGPoint?
    var fromSide: DBMLSide?
    var toSide: DBMLSide?
    /// The line's own colour (hex).
    var color: String?

    var isPlain: Bool { self == DBMLRefCurve() }
}

/// A note over the diagram (the diagram's own: written to the file as a DBML sticky note).
struct DBMLDiagramNote: Equatable, Identifiable {
    var id: String
    var text: String
    var frame: CGRect
    /// Its own colour (hex), else the yellow of notes.
    var color: String?

    static let size = CGSize(width: 220, height: 120)
    static let palette: [(String, String)] = [("Yellow", "#FFE680"), ("Blue", "#B8D8FF"), ("Green", "#BDEBB8"),
                                              ("Pink", "#FFC2D6"), ("Orange", "#FFCC99"), ("Gray", "#D9D9D9")]
}

/// What's selected on a diagram.
struct DBMLSelection: Equatable {
    var tables: Set<String> = []
    var ref: String?
    var note: String?

    var isEmpty: Bool { tables.isEmpty && ref == nil && note == nil }
}

// MARK: - The diagram

struct DBMLDiagram: Equatable {
    /// The DBML (without MxDataSQL's diagram section).
    var source: String
    /// Where each table (by id) and enum ("enum:name") sits: its top-left corner.
    var positions: [String: CGPoint] = [:]
    /// The DBML's own sticky notes' frames, by name.
    var stickyFrames: [String: CGRect] = [:]
    /// Each relationship's line, by the relationship's id (DBMLSchema.Ref.id).
    var curves: [String: DBMLRefCurve] = [:]
    /// Notes over the diagram.
    var notes: [DBMLDiagramNote] = []
    /// How lines without a style of their own are drawn.
    var defaultStyle: DBMLCurveStyle = .automatic
    /// Column types left out of the boxes.
    var hidesTypes = false
    /// The scale the diagram was last shown at (kept in the file for MxDataSQL).
    var zoom: Double?

    init(source: String) { self.source = source }

    var schema: DBMLSchema { DBMLParser.parse(source) }

    static let enumPrefix = "enum:"
    static let margin: CGFloat = 60

    // MARK: Lines

    func curve(_ ref: DBMLSchema.Ref) -> DBMLRefCurve { curves[ref.id] ?? DBMLRefCurve() }
    func style(_ ref: DBMLSchema.Ref) -> DBMLCurveStyle { curves[ref.id]?.style ?? defaultStyle }

    /// A line drawn another way: quadratic starts bowed away from the straight line (so its point is easy to
    /// grab), cubic from the automatic curve.
    mutating func setStyle(_ style: DBMLCurveStyle, for refID: String) {
        guard let ref = schema.refs.first(where: { $0.id == refID }) else { return }
        let geometry = DBMLGeometry(self)
        guard let line = geometry.lines.first(where: { $0.ref.id == refID }) else { return }
        var c = curves[refID] ?? DBMLRefCurve()
        c.style = style
        c.c1 = nil
        c.c2 = nil
        switch style {
        case .quadratic:
            let dx = line.end.x - line.start.x, dy = line.end.y - line.start.y
            let len = max(1, (dx * dx + dy * dy).squareRoot())
            c.c1 = CGPoint(x: -dy / len * 70, y: dx / len * 70)
        case .cubic:
            let auto = DBMLGeometry.automaticControls(line.start, line.end, line.startSide, line.endSide)
            c.c1 = CGPoint(x: auto[0].x - line.start.x, y: auto[0].y - line.start.y)
            c.c2 = CGPoint(x: auto[1].x - line.end.x, y: auto[1].y - line.end.y)
        case .automatic, .straight:
            break
        }
        if style == defaultStyle, c.fromSide == nil, c.toSide == nil, c.color == nil, style == .automatic || style == .straight { c.style = nil }
        curves[ref.id] = c.isPlain ? nil : c
    }

    /// Moves a quadratic or cubic line's control point `index` (0 or 1) to `point`.
    mutating func moveControl(_ index: Int, of refID: String, to point: CGPoint, in geometry: DBMLGeometry? = nil) {
        let geometry = geometry ?? DBMLGeometry(self)
        guard let line = geometry.lines.first(where: { $0.ref.id == refID }) else { return }
        var c = curves[refID] ?? DBMLRefCurve()
        switch line.style {
        case .quadratic:
            let mid = CGPoint(x: (line.start.x + line.end.x) / 2, y: (line.start.y + line.end.y) / 2)
            c.style = .quadratic
            c.c1 = CGPoint(x: point.x - mid.x, y: point.y - mid.y)
        case .cubic:
            c.style = .cubic
            let p1 = index == 0 ? point : line.controls[0], p2 = index == 1 ? point : line.controls[1]
            c.c1 = CGPoint(x: p1.x - line.start.x, y: p1.y - line.start.y)
            c.c2 = CGPoint(x: p2.x - line.end.x, y: p2.y - line.end.y)
        case .automatic, .straight:
            return
        }
        curves[refID] = c
    }

    /// A line as it was before it was shaped (its curve, sides and colour; the diagram's way of drawing lines).
    mutating func resetCurve(_ refID: String) { curves[refID] = nil }

    mutating func setSide(_ side: DBMLSide?, start: Bool, for refID: String) {
        var c = curves[refID] ?? DBMLRefCurve()
        if start { c.fromSide = side } else { c.toSide = side }
        if c.style == .quadratic || c.style == .cubic { c.c1 = nil; c.c2 = nil; curves[refID] = c; setStyle(c.style!, for: refID); return }
        curves[refID] = c.isPlain ? nil : c
    }

    mutating func setColor(_ hex: String?, for refID: String) {
        var c = curves[refID] ?? DBMLRefCurve()
        c.color = hex
        curves[refID] = c.isPlain ? nil : c
    }

    /// Every line drawn one way (their own shapes and styles dropped; sides and colours kept).
    mutating func setAllStyles(_ style: DBMLCurveStyle) {
        defaultStyle = style
        curves = curves.compactMapValues { c in
            var c = c
            c.style = nil
            c.c1 = nil
            c.c2 = nil
            return c.isPlain ? nil : c
        }
    }

    // MARK: Notes

    /// A new note over the diagram at a point, with a name MxDataSQL would give it.
    mutating func addNote(at point: CGPoint, text: String = "") -> String {
        let taken = Set(notes.map(\.id) + schema.notes.map(\.name))
        var n = notes.count + 1
        while taken.contains("mx_note_\(n)") { n += 1 }
        let id = "mx_note_\(n)"
        notes.append(DBMLDiagramNote(id: id, text: text, frame: CGRect(origin: CGPoint(x: max(0, point.x.rounded()), y: max(0, point.y.rounded())),
                                                                       size: DBMLDiagramNote.size)))
        return id
    }

    // MARK: Arrangement

    /// Lays the tables out as MxDataSQL does: one block per table group (tables in none: a block per schema,
    /// first), tables ordered so related ones sit together, packed into columns; the blocks side by side.
    /// Enums and sticky notes go below. Arranging everything resets the lines' curves; with `onlyMissing`,
    /// what has a place keeps it and the rest goes below everything.
    mutating func arrange(onlyMissing: Bool = false) {
        let s = schema
        let gap: CGFloat = 70
        let sizes = Dictionary(s.tables.map { ($0.name, DBMLGeometry.size(of: $0, hidesTypes: hidesTypes)) }, uniquingKeysWith: { a, _ in a })
        var blocks: [[String]] = []
        var placed = Set<String>()
        for g in s.groups {
            let members = g.tables.filter { sizes[$0] != nil && placed.insert($0).inserted }
            if !members.isEmpty { blocks.append(members) }
        }
        var rest: [[String]] = []
        for schemaName in s.schemas {
            let members = s.tables.filter { $0.schema == schemaName }.map(\.name).filter { placed.insert($0).inserted }
            if !members.isEmpty { rest.append(members) }
        }
        blocks.insert(contentsOf: rest, at: 0)
        var neighbours: [String: [String]] = [:]
        for r in s.refs where r.from.table != r.to.table {
            neighbours[r.from.table, default: []].append(r.to.table)
            neighbours[r.to.table, default: []].append(r.from.table)
        }
        var originX = Self.margin
        var originY = Self.margin
        if onlyMissing {
            let geometry = DBMLGeometry(self, placingMissing: false)
            let done = geometry.boxes.filter { positions[$0.key] != nil }.map(\.rect) + geometry.stickies.map(\.rect)
            if !done.isEmpty { originY = (done.map(\.maxY).max() ?? 0) + gap * 1.5 }
            blocks = blocks.map { $0.filter { positions[$0] == nil } }.filter { !$0.isEmpty }
        }
        var bottom = originY
        for block in blocks {
            // Breadth-first from the most connected table, so neighbours end up close.
            var order: [String] = []
            var seen = Set<String>()
            let members = Set(block)
            for start in block.sorted(by: { (neighbours[$0]?.count ?? 0) > (neighbours[$1]?.count ?? 0) }) where !seen.contains(start) {
                var queue = [start]
                seen.insert(start)
                while !queue.isEmpty {
                    let t = queue.removeFirst()
                    order.append(t)
                    for n in neighbours[t] ?? [] where members.contains(n) && seen.insert(n).inserted { queue.append(n) }
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
            for (t, col, y) in assignment { positions[t] = CGPoint(x: xs[col], y: y) }
            bottom = max(bottom, (heights.max() ?? originY) - gap * 0.6)
            originX = x + gap
        }
        // Enums, then sticky notes without a frame, in rows below.
        var rowX = Self.margin, rowY = bottom + gap, rowHeight: CGFloat = 0
        let width = max(1200, originX)
        func put(_ size: CGSize) -> CGPoint {
            if rowX > Self.margin, rowX + size.width > width { rowX = Self.margin; rowY += rowHeight + gap * 0.6; rowHeight = 0 }
            let p = CGPoint(x: rowX, y: rowY)
            rowX += size.width + gap * 0.6
            rowHeight = max(rowHeight, size.height)
            return p
        }
        for e in s.enums where !onlyMissing || positions[Self.enumPrefix + e.name] == nil {
            positions[Self.enumPrefix + e.name] = put(DBMLGeometry.size(of: e))
        }
        for n in s.notes where !onlyMissing || stickyFrames[n.name] == nil {
            let size = DBMLDiagramNote.size
            stickyFrames[n.name] = CGRect(origin: put(size), size: size)
        }
        if !onlyMissing { curves = curves.compactMapValues { c in var c = c; c.style = nil; c.c1 = nil; c.c2 = nil; return c.isPlain ? nil : c } }
    }

    /// Gives every table, enum and sticky note without a place one (all arranged when none has a place yet).
    mutating func placeMissing() {
        let s = schema
        let missing = s.tables.contains { positions[$0.name] == nil } || s.enums.contains { positions[Self.enumPrefix + $0.name] == nil }
            || s.notes.contains { stickyFrames[$0.name] == nil }
        guard missing else { return }
        let anyPlaced = s.tables.contains { positions[$0.name] != nil }
        arrange(onlyMissing: anyPlaced)
    }

    // MARK: Moving

    /// Moves tables (and enums) by an offset from where they were.
    mutating func move(_ keys: Set<String>, from start: [String: CGPoint], by offset: CGSize) {
        for key in keys {
            guard let p = start[key] else { continue }
            positions[key] = CGPoint(x: max(0, (p.x + offset.width).rounded()), y: max(0, (p.y + offset.height).rounded()))
        }
    }

    /// Everything moved so the diagram starts at the margin (a group's panel above its tables included).
    mutating func moveToMargin() {
        let geometry = DBMLGeometry(self)
        let extent = geometry.extent
        let dx = Self.margin / 2 - extent.minX, dy = Self.margin / 2 - extent.minY
        guard abs(dx) > 0.5 || abs(dy) > 0.5 else { return }
        for (k, p) in positions { positions[k] = CGPoint(x: p.x + dx, y: p.y + dy) }
        for (k, f) in stickyFrames { stickyFrames[k] = f.offsetBy(dx: dx, dy: dy) }
        for i in notes.indices { notes[i].frame = notes[i].frame.offsetBy(dx: dx, dy: dy) }
    }
}

// MARK: - Files (MxDataSQL's format)

extension DBMLDiagram {
    /// A diagram from a .dbml file: the DBML, and from MxDataSQL's section its notes and layout.
    init(fileText text: String) {
        let (body, section) = DBMLFileLayout.split(text)
        self.init(source: body)
        if let section { apply(section: section) }
    }

    /// Takes the notes and layout of a diagram section (MxDataSQL's, or an export's).
    mutating func apply(section: String) {
        let own = DBMLParser.parse(section).notes
        guard let layout = DBMLFileLayout.layout(inSection: section) else {
            for n in own where !notes.contains(where: { $0.id == n.name }) {
                notes.append(DBMLDiagramNote(id: n.name, text: n.text, frame: CGRect(origin: CGPoint(x: Self.margin, y: Self.margin), size: DBMLDiagramNote.size)))
            }
            return
        }
        apply(layout, ownNotes: own)
    }

    mutating func apply(_ layout: DBMLFileLayout.Layout, ownNotes: [DBMLSchema.StickyNote] = []) {
        for (k, p) in layout.tables { positions[k] = CGPoint(x: p.x, y: p.y) }
        for (k, c) in layout.refs {
            var curve = DBMLRefCurve()
            curve.style = c.style.flatMap(DBMLCurveStyle.init(rawValue:)).flatMap { $0 == .automatic ? nil : $0 }
            curve.c1 = c.c1.map { CGPoint(x: $0.x, y: $0.y) }
            curve.c2 = c.c2.map { CGPoint(x: $0.x, y: $0.y) }
            curve.fromSide = c.fromSide.flatMap(DBMLSide.init(rawValue:))
            curve.toSide = c.toSide.flatMap(DBMLSide.init(rawValue:))
            curve.color = c.color
            curves[k] = curve.isPlain ? nil : curve
        }
        func rect(_ f: DBMLFileLayout.Frame) -> CGRect {
            CGRect(x: f.x, y: f.y, width: f.width ?? DBMLDiagramNote.size.width, height: f.height ?? DBMLDiagramNote.size.height)
        }
        let fileNotes = Set(schema.notes.map(\.name))
        for (k, f) in layout.notes where fileNotes.contains(k) { stickyFrames[k] = rect(f) }
        for n in ownNotes where !notes.contains(where: { $0.id == n.name }) {
            let f = layout.notes[n.name]
            notes.append(DBMLDiagramNote(id: n.name, text: n.text,
                                         frame: f.map { rect($0) } ?? CGRect(origin: CGPoint(x: Self.margin, y: Self.margin), size: DBMLDiagramNote.size),
                                         color: f?.color))
        }
        zoom = layout.zoom ?? zoom
    }

    /// The names the diagram's own notes are written with (their ids, when they can be DBML names).
    private var noteNames: [String] {
        var taken = Set(schema.notes.map(\.name)), names: [String] = []
        for (n, note) in notes.enumerated() {
            var name = note.id.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil ? note.id : "mx_note_\(n + 1)"
            while taken.contains(name) { name += "_" }
            taken.insert(name)
            names.append(name)
        }
        return names
    }

    /// The layout as MxDataSQL keeps it: positions, curves, note frames, zoom.
    var fileLayout: DBMLFileLayout.Layout {
        var layout = DBMLFileLayout.Layout()
        for (k, p) in positions { layout.tables[k] = .init(x: p.x, y: p.y) }
        for (k, c) in curves where !c.isPlain {
            layout.refs[k] = .init(style: (c.style ?? .automatic).rawValue, c1: c.c1.map { .init(x: $0.x, y: $0.y) }, c2: c.c2.map { .init(x: $0.x, y: $0.y) },
                                   fromSide: c.fromSide?.rawValue, toSide: c.toSide?.rawValue, color: c.color)
        }
        if defaultStyle != .automatic {
            // Lines drawn the diagram's way are written with that style (MxDataSQL keeps a style per line).
            for r in schema.refs where curves[r.id]?.style == nil {
                var c = layout.refs[r.id] ?? .init()
                c.style = defaultStyle.rawValue
                layout.refs[r.id] = c
            }
        }
        for (k, f) in stickyFrames { layout.notes[k] = .init(x: f.minX, y: f.minY, width: f.width, height: f.height) }
        for (note, name) in zip(notes, noteNames) {
            layout.notes[name] = .init(x: note.frame.minX, y: note.frame.minY, width: note.frame.width, height: note.frame.height, color: note.color)
        }
        layout.zoom = zoom
        return layout
    }

    /// The diagram as a .dbml file: the DBML as written, then MxDataSQL's section — the diagram's notes as DBML
    /// sticky notes and the layout as one comment line (other DBML tools read the notes and skip the comment).
    func fileText(includingLayout: Bool = true) -> String {
        var text = source
        while text.hasSuffix("\n") || text.hasSuffix(" ") { text.removeLast() }
        let written = zip(notes, noteNames).filter { !$0.0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || includingLayout }
        guard includingLayout || !written.isEmpty else { return text + "\n" }
        text += "\n\n" + DBMLFileLayout.sectionMarker + "\n"
        for (note, name) in written {
            text += "Note \(name) {\n  '''\n\(note.text.replacingOccurrences(of: "'''", with: "\\'\\'\\'"))\n  '''\n}\n"
        }
        if includingLayout { text += DBMLFileLayout.line(fileLayout) + "\n" }
        return text
    }
}

// MARK: - One schema of it

extension DBMLDiagram {
    /// One schema's part, to copy or export on its own: its tables and enums (their DBML as written, refs to
    /// tables elsewhere taken off), the relationships among them, its table groups (with only its tables),
    /// where they sit (moved to the top left) with their curves, and the notes over them.
    func subset(schema name: String, from title: String? = nil) -> DBMLDiagram {
        let s = schema
        let lines = source.components(separatedBy: "\n")
        func text(_ range: ClosedRange<Int>) -> String {
            let lo = max(1, range.lowerBound), hi = min(lines.count, range.upperBound)
            return lo <= hi ? lines[(lo - 1)...(hi - 1)].joined(separator: "\n") : ""
        }
        let tables = s.tables.filter { $0.schema == name }
        let ids = Set(tables.map(\.name))
        let shortTypes = Set(tables.flatMap { $0.columns.map { $0.type.lowercased() } })
        let enums = s.enums.filter { $0.schema == name || shortTypes.contains($0.name.lowercased())
            || shortTypes.contains(($0.name.split(separator: ".").last.map(String.init) ?? $0.name).lowercased()) }
        var aliases: [String: String] = [:]
        for t in s.tables { if let a = t.alias { aliases[a] = t.name } }
        func resolved(_ table: String) -> String {
            let t = aliases[table] ?? table
            return t.hasPrefix("public.") ? String(t.dropFirst(7)) : t
        }

        var out = "// The \(name) schema" + (title.map { " of \($0)" } ?? "") + "\n\n"
        if let p = s.projectLines { out += text(p) + "\n\n" }
        for t in tables {
            var body = text(t.line...max(t.line, t.endLine)).components(separatedBy: "\n")
            // Inline refs to tables not in this schema come off (their tables aren't here).
            for r in s.refs where r.inline && r.from.table == t.name && !ids.contains(r.to.table) {
                let k = r.line - t.line
                guard body.indices.contains(k) else { continue }
                body[k] = Self.removingInlineRefs(body[k]) { !ids.contains(resolved($0)) }
            }
            out += body.joined(separator: "\n") + "\n\n"
        }
        for e in enums { out += text(e.line...max(e.line, e.endLine)) + "\n\n" }
        let refs = s.refs.filter { !$0.inline && ids.contains($0.from.table) && ids.contains($0.to.table) }
        var names: [String: Int] = [:]
        for r in refs { if let n = r.name { names[n, default: 0] += 1 } }
        for r in refs {
            let named = r.name.flatMap { names[$0] == 1 ? " " + $0 : nil } ?? ""
            out += "Ref\(named): \(r.from.text) \(r.op) \(r.to.text)\(r.settings.map { " " + $0 } ?? "")\n"
        }
        if !refs.isEmpty { out += "\n" }
        for g in s.groups {
            let members = g.tables.filter(ids.contains)
            guard !members.isEmpty else { continue }
            out += "TableGroup \(g.name)\(g.color.map { " [color: \($0)]" } ?? "") {\n" + members.map { "  " + $0 + "\n" }.joined() + "}\n\n"
        }
        var part = DBMLDiagram(source: out.trimmingCharacters(in: .whitespacesAndNewlines) + "\n")
        part.defaultStyle = defaultStyle
        part.hidesTypes = hidesTypes
        let geometry = DBMLGeometry(self)
        let keys = ids.union(enums.map { Self.enumPrefix + $0.name })
        for k in keys { if let p = positions[k] { part.positions[k] = p } }
        let refIDs = Set(DBMLParser.parse(part.source).refs.map(\.id))
        for (k, c) in curves where refIDs.contains(k) { part.curves[k] = c }
        let area = geometry.boxes.filter { keys.contains($0.key) }.map(\.rect).reduce(CGRect.null) { $0.union($1) }
        if !area.isNull {
            part.notes = notes.filter { $0.frame.intersects(area.insetBy(dx: -40, dy: -60)) }
        }
        part.placeMissing()
        part.moveToMargin()
        return part
    }

    /// A column's line with its `ref: …` settings to the tables `outside` says are elsewhere taken off.
    static func removingInlineRefs(_ line: String, outside: (String) -> Bool) -> String {
        guard let open = line.firstIndex(of: "["), let close = line.lastIndex(of: "]"), open < close else { return line }
        let inside = String(line[line.index(after: open)..<close])
        var parts: [String] = [], depth = 0, current = ""
        for ch in inside {
            if ch == "(" { depth += 1 } else if ch == ")" { depth -= 1 }
            if ch == ",", depth == 0 { parts.append(current); current = "" } else { current.append(ch) }
        }
        parts.append(current)
        let kept = parts.filter { part in
            let p = part.trimmingCharacters(in: .whitespaces)
            guard p.lowercased().hasPrefix("ref") else { return true }
            let target = p.drop { $0 != ":" }.dropFirst().trimmingCharacters(in: CharacterSet(charactersIn: " <>-"))
            let table = target.contains("(") ? String(target[..<(target.range(of: ".(")?.lowerBound ?? target.endIndex)])
                : (target.lastIndex(of: ".").map { String(target[..<$0]) } ?? target)
            return !outside(table.replacingOccurrences(of: "\"", with: ""))
        }
        let head = String(line[..<open]), tail = String(line[line.index(after: close)...])
        if kept.isEmpty { return head.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) + tail }
        return head + "[" + kept.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ") + "]" + tail
    }
}

// MARK: - Where everything goes

/// The diagram laid out: each box (table or enum), each relationship's line, each schema panel and note.
struct DBMLGeometry {
    enum BoxKind { case table, enumeration }

    struct Row {
        var name: String
        var type: String
        var pk = false
        var fk = false
        var notNull = false
        var unique = false
        var defaultValue: String?
        var note: String?
    }

    struct Box {
        var key: String
        var kind: BoxKind
        /// "name" in public, else "schema.name" (as MxDataSQL heads its tables).
        var title: String
        var schema: String
        var rows: [Row]
        var note: String?
        var color: NSColor
        var rect: CGRect
        var line: Int
        var indexCount = 0
    }

    struct Line {
        var ref: DBMLSchema.Ref
        var start: CGPoint
        var end: CGPoint
        var startSide: DBMLSide
        var endSide: DBMLSide
        var style: DBMLCurveStyle
        /// One control point for quadratic, two for automatic and cubic, none for straight.
        var controls: [CGPoint]
        var color: NSColor?

        var path: NSBezierPath {
            let p = NSBezierPath()
            p.move(to: start)
            switch style {
            case .straight: p.line(to: end)
            case .quadratic:
                p.curve(to: end, controlPoint1: CGPoint(x: start.x + (controls[0].x - start.x) * 2 / 3, y: start.y + (controls[0].y - start.y) * 2 / 3),
                        controlPoint2: CGPoint(x: end.x + (controls[0].x - end.x) * 2 / 3, y: end.y + (controls[0].y - end.y) * 2 / 3))
            case .automatic, .cubic: p.curve(to: end, controlPoint1: controls[0], controlPoint2: controls[1])
            }
            return p
        }

        /// The direction the line leaves its start in (a unit vector pointing away from the table).
        var startTangent: CGVector {
            let to = style == .straight ? end : controls[0]
            return Self.unit(CGVector(dx: to.x - start.x, dy: to.y - start.y), fallback: startSide == .left ? -1 : 1)
        }
        /// The direction it comes into its end from.
        var endTangent: CGVector {
            let from = style == .straight ? start : style == .quadratic ? controls[0] : controls[1]
            return Self.unit(CGVector(dx: from.x - end.x, dy: from.y - end.y), fallback: endSide == .left ? -1 : 1)
        }
        private static func unit(_ v: CGVector, fallback: CGFloat) -> CGVector {
            let len = (v.dx * v.dx + v.dy * v.dy).squareRoot()
            return len < 0.001 ? CGVector(dx: fallback, dy: 0) : CGVector(dx: v.dx / len, dy: v.dy / len)
        }
    }

    struct Group {
        var name: String
        /// The panel's label (MxDataSQL's schema groups lose their "_schema").
        var label: String
        var rect: CGRect
        var color: NSColor?
        var tables: [String]
    }

    struct Sticky {
        /// The DBML note's name, or the diagram note's id.
        var id: String
        var text: String
        var rect: CGRect
        /// The diagram's own (editable) note, not one of the DBML's.
        var own: Bool
        var color: NSColor?
    }

    var schema: DBMLSchema
    var boxes: [Box] = []
    var lines: [Line] = []
    var groups: [Group] = []
    var stickies: [Sticky] = []
    /// Everything (boxes, panels, notes, control points), in diagram points.
    var extent = CGRect(x: 0, y: 0, width: 200, height: 120)

    static let headerHeight: CGFloat = 28
    static let rowHeight: CGFloat = 19

    /// A table's box, sized from its text (as MxDataSQL sizes them: the boxes don't depend on fonts).
    static func size(of table: DBMLSchema.Table, hidesTypes: Bool = false) -> CGSize {
        size(title: table.name, names: table.columns.map(\.name), types: hidesTypes ? [] : table.columns.map(\.type))
    }

    static func size(of e: DBMLSchema.Enum) -> CGSize {
        size(title: "enum " + e.name, names: e.values.map(\.name), types: [])
    }

    static func size(title: String, names: [String], types: [String]) -> CGSize {
        let nameChars = max(names.map(\.count).max() ?? 0, 4)
        let typeChars = types.map(\.count).max() ?? 0
        let body = 34 + CGFloat(nameChars) * 7 + 14 + CGFloat(typeChars) * 6.4
        let width = min(420, max(170, body, 40 + CGFloat(title.count) * 7.4))
        return CGSize(width: width, height: headerHeight + CGFloat(max(names.count, 1)) * rowHeight + 6)
    }

    /// A header colour per schema, so a schema's tables share one (public blue).
    static func color(forSchema schema: String) -> NSColor {
        let palette: [NSColor] = [.systemBlue, .systemTeal, .systemIndigo, .systemPurple, .systemOrange, .systemGreen, .systemPink, .systemBrown]
        let index = schema == "public" ? 0 : (abs(schema.unicodeScalars.reduce(7) { $0 &* 31 &+ Int($1.value) }) % (palette.count - 1)) + 1
        return palette[index]
    }

    init(_ d: DBMLDiagram, placingMissing: Bool = true) {
        var d = d
        if placingMissing { d.placeMissing() }
        let schema = d.schema
        self.schema = schema
        for t in schema.tables {
            let fks = schema.foreignKeys(of: t.name)
            let rows = t.columns.map { Row(name: $0.name, type: d.hidesTypes ? "" : $0.type, pk: $0.pk, fk: fks.contains($0.name),
                                           notNull: $0.notNull, unique: $0.unique, defaultValue: $0.defaultValue, note: $0.note) }
            let color = t.headerColor.flatMap { DBMLColor.hex($0) } ?? Self.color(forSchema: t.schema)
            boxes.append(Box(key: t.name, kind: .table, title: t.name, schema: t.schema, rows: rows, note: t.note, color: color,
                             rect: CGRect(origin: d.positions[t.name] ?? .zero, size: Self.size(of: t, hidesTypes: d.hidesTypes)),
                             line: t.line, indexCount: t.indexCount))
        }
        for e in schema.enums {
            let key = DBMLDiagram.enumPrefix + e.name
            boxes.append(Box(key: key, kind: .enumeration, title: "enum " + e.name, schema: e.schema,
                             rows: e.values.map { Row(name: $0.name, type: "", note: $0.note) }, note: nil, color: .systemGray,
                             rect: CGRect(origin: d.positions[key] ?? .zero, size: Self.size(of: e)), line: e.line))
        }
        let frames = Dictionary(boxes.map { ($0.key, $0.rect) }, uniquingKeysWith: { a, _ in a })
        for g in schema.groups {
            let rects = g.tables.compactMap { frames[$0] }
            guard let first = rects.first else { continue }
            let box = rects.dropFirst().reduce(first) { $0.union($1) }
            groups.append(Group(name: g.name, label: g.name.replacingOccurrences(of: "_schema", with: ""),
                                rect: box.insetBy(dx: -24, dy: -36).offsetBy(dx: 0, dy: -8), color: g.color.flatMap { DBMLColor.hex($0) }, tables: g.tables))
        }
        for ref in schema.refs {
            guard let a = frames[ref.from.table], let b = frames[ref.to.table] else { continue }
            let c = d.curve(ref)
            var sides: (DBMLSide, DBMLSide)
            if ref.from.table == ref.to.table {
                sides = (.right, .right)
            } else if a.maxX + 30 < b.minX {
                sides = (.right, .left)
            } else if b.maxX + 30 < a.minX {
                sides = (.left, .right)
            } else {
                // One above the other: loop out on the side with more room.
                sides = a.midX <= b.midX ? (.left, .left) : (.right, .right)
            }
            if let s = c.fromSide { sides.0 = s }
            if let s = c.toSide { sides.1 = s }
            let start = CGPoint(x: sides.0 == .right ? a.maxX : a.minX, y: Self.columnY(a, schema.table(ref.from.table), ref.from.columns.first))
            let end = CGPoint(x: sides.1 == .right ? b.maxX : b.minX, y: Self.columnY(b, schema.table(ref.to.table), ref.to.columns.first))
            let style = d.style(ref)
            let auto = Self.automaticControls(start, end, sides.0, sides.1)
            var controls: [CGPoint]
            switch style {
            case .straight: controls = []
            case .automatic: controls = auto
            case .quadratic:
                let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
                let o = c.c1 ?? CGPoint(x: 0, y: -60)
                controls = [CGPoint(x: mid.x + o.x, y: mid.y + o.y)]
            case .cubic:
                controls = [c.c1.map { CGPoint(x: start.x + $0.x, y: start.y + $0.y) } ?? auto[0],
                            c.c2.map { CGPoint(x: end.x + $0.x, y: end.y + $0.y) } ?? auto[1]]
            }
            lines.append(Line(ref: ref, start: start, end: end, startSide: sides.0, endSide: sides.1, style: style, controls: controls,
                              color: c.color.flatMap { DBMLColor.hex($0) }))
        }
        for n in schema.notes {
            stickies.append(Sticky(id: n.name, text: n.text, rect: d.stickyFrames[n.name] ?? CGRect(origin: .zero, size: DBMLDiagramNote.size), own: false))
        }
        for n in d.notes {
            stickies.append(Sticky(id: n.id, text: n.text, rect: n.frame, own: true, color: n.color.flatMap { DBMLColor.hex($0) }))
        }
        var all = CGRect.null
        for b in boxes { all = all.union(b.rect) }
        for g in groups { all = all.union(g.rect) }
        for s in stickies { all = all.union(s.rect) }
        for l in lines { for c in l.controls { all = all.union(CGRect(x: c.x - 8, y: c.y - 8, width: 16, height: 16)) } }
        extent = all.isNull ? CGRect(x: 0, y: 0, width: 200, height: 120) : all
    }

    static func columnY(_ frame: CGRect, _ table: DBMLSchema.Table?, _ column: String?) -> CGFloat {
        guard let column, let index = table?.columns.firstIndex(where: { $0.name == column }) else { return frame.minY + headerHeight / 2 }
        return frame.minY + headerHeight + CGFloat(index) * rowHeight + rowHeight / 2
    }

    static func automaticControls(_ s: CGPoint, _ e: CGPoint, _ ss: DBMLSide, _ es: DBMLSide) -> [CGPoint] {
        let reach = max(50, min(220, abs(e.x - s.x) / 2 + (ss == es ? 60 : 0)))
        return [CGPoint(x: s.x + (ss == .right ? reach : -reach), y: s.y),
                CGPoint(x: e.x + (es == .right ? reach : -reach), y: e.y)]
    }

    func box(_ key: String) -> Box? { boxes.first { $0.key == key } }
    func line(_ id: String) -> Line? { lines.first { $0.ref.id == id } }

    /// The row of a box at a point (nil on its header).
    static func row(in box: Box, at p: CGPoint) -> Int? {
        let y = p.y - box.rect.minY - headerHeight
        guard y >= 0 else { return nil }
        let r = Int(y / rowHeight)
        return r < box.rows.count ? r : nil
    }

    /// How far a point is from a line (for clicking it).
    static func distance(from p: CGPoint, to path: NSBezierPath) -> CGFloat {
        var best = CGFloat.greatestFiniteMagnitude
        var last: CGPoint?
        var points = [CGPoint](repeating: .zero, count: 3)
        for i in 0..<path.elementCount {
            let kind = path.element(at: i, associatedPoints: &points)
            let q = points[0]
            if kind == .lineTo, let a = last {
                let ab = CGPoint(x: q.x - a.x, y: q.y - a.y), ap = CGPoint(x: p.x - a.x, y: p.y - a.y)
                let t = max(0, min(1, (ap.x * ab.x + ap.y * ab.y) / max(ab.x * ab.x + ab.y * ab.y, 0.0001)))
                best = min(best, hypot(p.x - (a.x + ab.x * t), p.y - (a.y + ab.y * t)))
            }
            last = q
        }
        return best
    }
}

// MARK: - Drawing

/// Draws a diagram as both apps show it.
enum DBMLRenderer {
    private static let titleFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private static let nameFont = NSFont.systemFont(ofSize: 11)
    private static let keyFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    private static let typeFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    private static let noteFont = NSFont.systemFont(ofSize: 12)
    private static let panelFont = NSFont.systemFont(ofSize: 13, weight: .semibold)

    /// Everything, in diagram points, into the current (flipped) graphics context.
    static func draw(_ g: DBMLGeometry, selection: DBMLSelection = DBMLSelection(), editingNote: String? = nil) {
        for group in g.groups { drawPanel(group) }
        for line in g.lines where line.ref.id != selection.ref {
            let touching = selection.tables.contains(line.ref.from.table) || selection.tables.contains(line.ref.to.table)
            drawLine(line, selected: false, highlighted: touching)
        }
        for box in g.boxes { drawBox(box, selected: selection.tables.contains(box.key)) }
        if let id = selection.ref, let line = g.line(id) {
            drawLine(line, selected: true, highlighted: false)
            drawHandles(line)
        }
        for s in g.stickies { drawSticky(s, selected: selection.note == s.id, editing: editingNote == s.id) }
    }

    static func drawPanel(_ group: DBMLGeometry.Group) {
        let path = NSBezierPath(roundedRect: group.rect, xRadius: 14, yRadius: 14)
        let tint = group.color ?? .secondaryLabelColor
        tint.withAlphaComponent(group.color == nil ? 0.06 : 0.1).setFill()
        path.fill()
        let border = NSBezierPath(roundedRect: group.rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
        border.lineWidth = 1
        border.setLineDash([5, 4], count: 2, phase: 0)
        tint.withAlphaComponent(group.color == nil ? 0.25 : 0.5).setStroke()
        border.stroke()
        (group.label as NSString).draw(at: CGPoint(x: group.rect.minX + 12, y: group.rect.minY + 8),
                                       withAttributes: [.font: panelFont, .foregroundColor: group.color ?? NSColor.secondaryLabelColor])
    }

    static func drawBox(_ box: DBMLGeometry.Box, selected: Bool) {
        let r = box.rect
        let shape = NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.12)
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 3
        shadow.set()
        NSColor.controlBackgroundColor.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        box.color.setFill()
        CGRect(x: r.minX, y: r.minY, width: r.width, height: DBMLGeometry.headerHeight).fill()
        NSGraphicsContext.restoreGraphicsState()
        // Header: the table's name (schema.name outside public), and an index mark.
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingTail
        var titleWidth = r.width - 16
        if box.indexCount > 0, let icon = symbol("list.number", pointSize: 9, color: NSColor.white.withAlphaComponent(0.8)) {
            icon.draw(in: CGRect(x: r.maxX - 8 - icon.size.width, y: r.minY + (DBMLGeometry.headerHeight - icon.size.height) / 2,
                                 width: icon.size.width, height: icon.size.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            titleWidth -= icon.size.width + 4
        }
        (box.title as NSString).draw(with: CGRect(x: r.minX + 8, y: r.minY + (DBMLGeometry.headerHeight - 15) / 2, width: titleWidth, height: 16),
                                     options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                     attributes: [.font: titleFont, .foregroundColor: NSColor.white, .paragraphStyle: truncating])
        // Rows: a key on the primary key, a link on foreign keys; the name, and the type at the right.
        for (k, row) in box.rows.enumerated() {
            let y = r.minY + DBMLGeometry.headerHeight + CGFloat(k) * DBMLGeometry.rowHeight
            let icon: NSImage? = row.pk ? symbol("key.fill", pointSize: 9, color: .systemYellow)
                : row.fk ? symbol("link", pointSize: 9, color: .secondaryLabelColor) : nil
            if let icon {
                icon.draw(in: CGRect(x: r.minX + 8 + (12 - icon.size.width) / 2, y: y + (DBMLGeometry.rowHeight - icon.size.height) / 2,
                                     width: icon.size.width, height: icon.size.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            var right = r.maxX - 8
            if !row.type.isEmpty {
                let attrs: [NSAttributedString.Key: Any] = [.font: typeFont, .foregroundColor: NSColor.secondaryLabelColor]
                let w = min((row.type as NSString).size(withAttributes: attrs).width, r.width * 0.55)
                (row.type as NSString).draw(with: CGRect(x: right - w, y: y + (DBMLGeometry.rowHeight - 13) / 2, width: w, height: 14),
                                            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                            attributes: attrs.merging([.paragraphStyle: truncating]) { a, _ in a })
                right -= w + 8
            }
            let x = r.minX + 8 + 12 + 4
            (row.name as NSString).draw(with: CGRect(x: x, y: y + (DBMLGeometry.rowHeight - 14) / 2, width: max(10, right - x), height: 15),
                                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                        attributes: [.font: row.pk ? keyFont : nameFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: truncating])
        }
        let w: CGFloat = selected ? 2.5 : 1
        let border = NSBezierPath(roundedRect: r.insetBy(dx: w / 2, dy: w / 2), xRadius: 7 - w / 2, yRadius: 7 - w / 2)
        border.lineWidth = w
        (selected ? NSColor.controlAccentColor : NSColor.secondaryLabelColor.withAlphaComponent(0.45)).setStroke()
        border.stroke()
    }

    static func drawLine(_ line: DBMLGeometry.Line, selected: Bool, highlighted: Bool) {
        let color: NSColor = selected ? .controlAccentColor : highlighted ? .systemOrange : line.color ?? .secondaryLabelColor
        let path = line.path
        path.lineWidth = selected || highlighted ? 2.4 : 1.3
        color.setStroke()
        path.stroke()
        // Crow's foot at a "many" end, a bar at a "one" end.
        let ends = NSBezierPath()
        mark(ends, at: line.start, direction: line.startTangent, many: line.ref.fromMany)
        mark(ends, at: line.end, direction: line.endTangent, many: line.ref.toMany)
        ends.lineWidth = selected || highlighted ? 2 : 1.2
        ends.stroke()
    }

    private static func mark(_ p: NSBezierPath, at point: CGPoint, direction d: CGVector, many: Bool) {
        let n = CGVector(dx: -d.dy, dy: d.dx)
        if many {
            let tip = CGPoint(x: point.x + d.dx * 13, y: point.y + d.dy * 13)
            for s: CGFloat in [-7, 0, 7] {
                p.move(to: tip)
                p.line(to: CGPoint(x: point.x + n.dx * s, y: point.y + n.dy * s))
            }
        } else {
            let c = CGPoint(x: point.x + d.dx * 9, y: point.y + d.dy * 9)
            p.move(to: CGPoint(x: c.x + n.dx * 6, y: c.y + n.dy * 6))
            p.line(to: CGPoint(x: c.x - n.dx * 6, y: c.y - n.dy * 6))
        }
    }

    /// The selected quadratic / cubic line's control points, on guides to the ends they pull from.
    static func drawHandles(_ line: DBMLGeometry.Line) {
        guard line.style == .quadratic || line.style == .cubic else { return }
        let guides = NSBezierPath()
        if line.style == .quadratic {
            guides.move(to: line.start); guides.line(to: line.controls[0]); guides.line(to: line.end)
        } else {
            guides.move(to: line.start); guides.line(to: line.controls[0])
            guides.move(to: line.end); guides.line(to: line.controls[1])
        }
        guides.lineWidth = 1
        guides.setLineDash([4, 3], count: 2, phase: 0)
        NSColor.controlAccentColor.withAlphaComponent(0.6).setStroke()
        guides.stroke()
        for c in line.controls {
            let handle = NSBezierPath(ovalIn: CGRect(x: c.x - 6.5, y: c.y - 6.5, width: 13, height: 13))
            NSColor.white.setFill()
            handle.fill()
            let ring = NSBezierPath(ovalIn: CGRect(x: c.x - 5.5, y: c.y - 5.5, width: 11, height: 11))
            ring.lineWidth = 2
            NSColor.controlAccentColor.setStroke()
            ring.stroke()
        }
    }

    static func drawSticky(_ s: DBMLGeometry.Sticky, selected: Bool, editing: Bool) {
        let shape = NSBezierPath(roundedRect: s.rect, xRadius: 5, yRadius: 5)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.15)
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowBlurRadius = 3
        shadow.set()
        NSColor.textBackgroundColor.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        (s.own ? (s.color ?? NSColor.systemYellow.withAlphaComponent(0.28)) : NSColor.systemGray.withAlphaComponent(0.18)).setFill()
        shape.fill()
        let w: CGFloat = selected ? 2 : 1
        let border = NSBezierPath(roundedRect: s.rect.insetBy(dx: w / 2, dy: w / 2), xRadius: 5, yRadius: 5)
        border.lineWidth = w
        (selected ? NSColor.controlAccentColor : NSColor.systemYellow.withAlphaComponent(0.8)).setStroke()
        border.stroke()
        if !editing {
            (s.text as NSString).draw(with: s.rect.insetBy(dx: 8, dy: 8), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                      attributes: [.font: noteFont, .foregroundColor: NSColor.labelColor])
        }
        if s.own, let corner = symbol("arrow.down.right", pointSize: 9, weight: .bold, color: .secondaryLabelColor) {
            corner.draw(in: CGRect(x: s.rect.maxX - 8 - corner.size.width / 2, y: s.rect.maxY - 8 - corner.size.height / 2,
                                   width: corner.size.width, height: corner.size.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    // MARK: Symbols

    private static var symbols: [String: NSImage] = [:]

    /// A symbol as a small bitmap in its colour (drawn as a symbol, it prints and copies to PDF as a solid square).
    static func symbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) -> NSImage? {
        let resolved = color.usingColorSpace(.sRGB) ?? color
        let key = "\(name) \(pointSize) \(weight.rawValue) \(DBMLColor.hexString(resolved)) \(resolved.alphaComponent)"
        if let known = symbols[key] { return known }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight).applying(.init(paletteColors: [resolved]))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return nil }
        let size = symbol.size, k: CGFloat = 4
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width * k)), pixelsHigh: Int(ceil(size.height * k)),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        symbol.draw(in: CGRect(x: 0, y: 0, width: CGFloat(rep.pixelsWide), height: CGFloat(rep.pixelsHigh)))
        NSGraphicsContext.restoreGraphicsState()
        rep.size = size
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        if symbols.count > 200 { symbols.removeAll() }
        symbols[key] = image
        return image
    }

    // MARK: Pictures

    /// Around the diagram in its pictures.
    static let pictureMargin: CGFloat = 24
    /// The most pixels a picture of a diagram gets (a big diagram is drawn at a lower scale to stay under it).
    static let maxPixels: CGFloat = 24_000_000

    static func pictureSize(_ g: DBMLGeometry) -> CGSize {
        CGSize(width: ceil(g.extent.width + 2 * pictureMargin), height: ceil(g.extent.height + 2 * pictureMargin))
    }

    /// The whole diagram as a picture (a real bitmap, its size the diagram's in points), light as on paper.
    static func picture(_ d: DBMLDiagram, scale: CGFloat = 2) -> NSImage {
        let g = DBMLGeometry(d)
        let image = NSImage(size: pictureSize(g))
        if let rep = bitmap(d, scale: scale, geometry: g) { image.addRepresentation(rep) }
        return image
    }

    /// The diagram drawn into a bitmap at `scale` pixels per point (less for a very big one).
    static func bitmap(_ d: DBMLDiagram, scale: CGFloat = 2, geometry: DBMLGeometry? = nil) -> NSBitmapImageRep? {
        let g = geometry ?? DBMLGeometry(d)
        let size = pictureSize(g)
        let s = max(0.2, min(scale, (maxPixels / max(size.width * size.height, 1)).squareRoot()))
        let w = Int((size.width * s).rounded(.up)), h = Int((size.height * s).rounded(.up))
        guard w > 0, h > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        render(g, into: context.cgContext, height: CGFloat(h), scale: s)
        rep.size = size
        return rep
    }

    /// The diagram as PDF: sharp at any size where it's pasted.
    static func pdf(_ d: DBMLDiagram) -> Data? {
        let g = DBMLGeometry(d)
        var box = CGRect(origin: .zero, size: pictureSize(g))
        let out = NSMutableData()
        guard let consumer = CGDataConsumer(data: out as CFMutableData), let cg = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        cg.beginPDFPage(nil)
        render(g, into: cg, height: box.height, scale: 1)
        cg.endPDFPage()
        cg.closePDF()
        return out as Data
    }

    /// Draws into a Core Graphics context top down, white behind it, in the light appearance (as on paper).
    private static func render(_ g: DBMLGeometry, into cg: CGContext, height: CGFloat, scale: CGFloat) {
        cg.saveGState()
        cg.translateBy(x: 0, y: height)
        cg.scaleBy(x: scale, y: -scale)
        cg.translateBy(x: pictureMargin - g.extent.minX, y: pictureMargin - g.extent.minY)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        (NSAppearance(named: .aqua) ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
            NSColor.white.setFill()
            g.extent.insetBy(dx: -pictureMargin, dy: -pictureMargin).fill()
            draw(g)
        }
        NSGraphicsContext.restoreGraphicsState()
        cg.restoreGState()
    }

    /// The picture for the clipboard: PDF, PNG and TIFF of it, on a pasteboard item.
    static func add(_ d: DBMLDiagram, to item: NSPasteboardItem) {
        if let pdf = pdf(d) { item.setData(pdf, forType: .pdf) }
        if let rep = bitmap(d) {
            if let png = rep.representation(using: .png, properties: [:]) { item.setData(png, forType: .png) }
            if let tiff = rep.tiffRepresentation(using: .lzw, factor: 0) { item.setData(tiff, forType: .tiff) }
        }
    }

    /// Copy Picture: the diagram on a pasteboard (false if it couldn't be drawn or written).
    @discardableResult
    static func copy(_ d: DBMLDiagram, to pasteboard: NSPasteboard = .general) -> Bool {
        let item = NSPasteboardItem()
        add(d, to: item)
        guard !item.types.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }
}
