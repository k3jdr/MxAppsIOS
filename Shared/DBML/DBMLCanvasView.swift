//
//  DBMLCanvasView.swift
//  Shared/DBML — used by MxDataSQL and MxNoteONE
//
//  A DBML diagram to work on: drag tables (⇧- or ⌘-click to select more; click a schema panel's
//  name to select all its tables) and the selection moves together; click a relationship to pick
//  its curve and drag its control points; notes over the diagram are added with a double-click on
//  empty space, dragged, resized from their corner and typed in place. Right-click for the line's
//  curve, sides and colour, a note's colour, and the Schema menu — select a schema, copy it, or
//  export it (to a file in MxDataSQL, to a page of its own in MxNoteONE). The app around it (the
//  host) hears each change as one step, and adds its own commands to the menu. A host with a snap
//  grid (MxNoteONE's Snap to Grid) has dragged tables and notes, resized notes and arrow-key moves
//  land on its grid, which shows as dots while dragging.
//

import AppKit

/// What a point on the canvas is on.
enum DBMLHit: Equatable {
    /// A control point of the selected line (its id, and 0 or 1).
    case handle(String, Int)
    /// The corner of one of the diagram's own notes (drag to resize it).
    case noteCorner(String)
    /// A note: the diagram's own (its id) or the DBML's (its name).
    case note(String)
    /// A table (its id) or enum ("enum:name").
    case box(String)
    case line(String)
    /// The name strip of a schema panel (a table group).
    case panel(String)
}

/// A grid to snap to, in the canvas view's own coordinates (the host's page grid, so it lines up with it).
struct DBMLSnapGrid: Equatable {
    var step: CGFloat
    var origin: CGPoint
}

/// The app around a canvas: told of each change (for undo, saving), and adding its own commands.
protocol DBMLCanvasHost: AnyObject {
    /// An edit finished, as one step called `name`; `old` is the diagram before it.
    func canvas(_ canvas: DBMLCanvasView, didChange old: DBMLDiagram, name: String)
    /// The diagram changes while something is dragged (the host may resize around it).
    func canvasDidChangeLive(_ canvas: DBMLCanvasView)
    func canvasSelectionDidChange(_ canvas: DBMLCanvasView)
    /// A click on the canvas.
    func canvasWasClicked(_ canvas: DBMLCanvasView)
    /// The app's own commands for the right-click menu (after the canvas's).
    func canvasMenuItems(_ canvas: DBMLCanvasView, at point: CGPoint, hit: DBMLHit?) -> [NSMenuItem]
    /// The Schema menu's export: its title ("Export Schema…", "Export Schema to a New Page") and what it does.
    var schemaExportTitle: String { get }
    func canvas(_ canvas: DBMLCanvasView, export part: DBMLDiagram, schema: String)
    /// Copy Schema: the app may add its own types to the clipboard item (the DBML and a picture are on it).
    func canvas(_ canvas: DBMLCanvasView, copy part: DBMLDiagram, schema: String, to item: NSPasteboardItem)
    /// Double-click a table or line: its DBML (where the app shows DBML).
    func canvas(_ canvas: DBMLCanvasView, showSourceLine line: Int)
    /// The diagram's name, for a schema cut out of it.
    var diagramTitle: String? { get }
    /// The grid dragged tables and notes snap to right now (nil: none — no grid, or snapping is off or held off).
    func canvasSnapGrid(_ canvas: DBMLCanvasView) -> DBMLSnapGrid?
}

extension DBMLCanvasHost {
    func canvasDidChangeLive(_ canvas: DBMLCanvasView) {}
    func canvasSelectionDidChange(_ canvas: DBMLCanvasView) {}
    func canvasWasClicked(_ canvas: DBMLCanvasView) {}
    func canvasMenuItems(_ canvas: DBMLCanvasView, at point: CGPoint, hit: DBMLHit?) -> [NSMenuItem] { [] }
    func canvas(_ canvas: DBMLCanvasView, copy part: DBMLDiagram, schema: String, to item: NSPasteboardItem) {}
    func canvas(_ canvas: DBMLCanvasView, showSourceLine line: Int) {}
    var diagramTitle: String? { nil }
    func canvasSnapGrid(_ canvas: DBMLCanvasView) -> DBMLSnapGrid? { nil }
}

/// A menu item that runs a closure.
final class DBMLMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, checked: Bool = false, enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
        isEnabled = enabled
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { handler() }
}

final class DBMLCanvasView: NSView, NSTextViewDelegate {
    weak var host: DBMLCanvasHost?

    /// The diagram shown (setting it lays it out again).
    var diagram: DBMLDiagram {
        didSet { if diagram != oldValue { relayout() } }
    }
    private(set) var geometry: DBMLGeometry
    var zoom: CGFloat = 1 {
        didSet { if oldValue != zoom { needsDisplay = true; updateToolTips(); positionNoteEditor() } }
    }
    var selection = DBMLSelection() {
        didSet {
            guard selection != oldValue else { return }
            needsDisplay = true
            host?.canvasSelectionDidChange(self)
        }
    }
    /// Off for printing and pictures of the page.
    var showsSelection = true { didSet { needsDisplay = true } }
    var drawsBackground = true { didSet { needsDisplay = true } }
    var isEditable = true
    private(set) var editingNote: String?
    /// The snap grid shown while something is dragged.
    private var shownGrid: DBMLSnapGrid? {
        didSet { if shownGrid != oldValue { needsDisplay = true } }
    }
    private var noteEditor: DBMLNoteEditor?
    private var tracking: NSTrackingArea?

    /// Where Copy Schema puts it (the clipboard; tests use a pasteboard of their own).
    static var pasteboard = NSPasteboard.general

    init(diagram: DBMLDiagram) {
        var d = diagram
        d.placeMissing()
        self.diagram = d
        geometry = DBMLGeometry(d)
        super.init(frame: .zero)
        updateToolTips()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isEditable }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The size the canvas needs at its zoom, with a margin around the diagram (at least `minimum`).
    func contentSize(margin: CGFloat, minimum: CGSize = .zero) -> CGSize {
        CGSize(width: max(minimum.width, ceil((geometry.extent.maxX + margin) * zoom)),
               height: max(minimum.height, ceil((geometry.extent.maxY + margin) * zoom)))
    }

    private func relayout() {
        var d = diagram
        d.placeMissing()
        if d != diagram {
            diagram = d
            return
        }
        geometry = DBMLGeometry(diagram)
        let keys = Set(geometry.boxes.map(\.key))
        if !selection.tables.isSubset(of: keys) { selection.tables = selection.tables.intersection(keys) }
        if let id = selection.ref, geometry.line(id) == nil { selection.ref = nil }
        if let id = selection.note, !geometry.stickies.contains(where: { $0.id == id }) { selection.note = nil }
        updateToolTips()
        positionNoteEditor()
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        if drawsBackground {
            NSColor.textBackgroundColor.setFill()
            dirtyRect.fill()
        }
        if let grid = shownGrid, grid.step >= 4 {
            NSColor(srgbRed: 0.45, green: 0.62, blue: 0.85, alpha: 0.45).setFill()
            var y = grid.origin.y + floor((dirtyRect.minY - grid.origin.y) / grid.step) * grid.step
            while y <= dirtyRect.maxY {
                var x = grid.origin.x + floor((dirtyRect.minX - grid.origin.x) / grid.step) * grid.step
                while x <= dirtyRect.maxX {
                    NSRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5).fill()
                    x += grid.step
                }
                y += grid.step
            }
        }
        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform()
        t.scale(by: zoom)
        t.concat()
        DBMLRenderer.draw(geometry, selection: showsSelection ? selection : DBMLSelection(), editingNote: editingNote)
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Finding things

    func point(_ event: NSEvent) -> CGPoint {
        let v = convert(event.locationInWindow, from: nil)
        return CGPoint(x: v.x / zoom, y: v.y / zoom)
    }

    func hit(_ p: CGPoint) -> DBMLHit? {
        let reach = 7 / zoom
        if let id = selection.ref, let line = geometry.line(id), line.style == .quadratic || line.style == .cubic {
            for (k, c) in line.controls.enumerated() where hypot(c.x - p.x, c.y - p.y) <= reach + 2 { return .handle(id, k) }
        }
        for s in geometry.stickies.reversed() {
            if s.own, s.id == selection.note, hypot(s.rect.maxX - p.x, s.rect.maxY - p.y) <= 12 / zoom { return .noteCorner(s.id) }
            if s.rect.contains(p) { return .note(s.id) }
        }
        for box in geometry.boxes.reversed() where box.rect.contains(p) { return .box(box.key) }
        if let id = line(near: p, within: 5 / zoom) { return .line(id) }
        for g in geometry.groups.reversed() where CGRect(x: g.rect.minX, y: g.rect.minY, width: g.rect.width, height: 30).contains(p) {
            return .panel(g.name)
        }
        return nil
    }

    func line(near p: CGPoint, within distance: CGFloat) -> String? {
        var best: (String, CGFloat)?
        for line in geometry.lines {
            let d = DBMLGeometry.distance(from: p, to: line.path.flattened)
            if d <= distance, best == nil || d < best!.1 { best = (line.ref.id, d) }
        }
        return best?.0
    }

    /// The schema of what's at a point: a table's or enum's, a panel's tables', or (elsewhere) none.
    func schema(at hit: DBMLHit?) -> String? {
        switch hit {
        case .box(let key)?: return geometry.box(key)?.schema
        case .panel(let name)?:
            let tables = geometry.groups.first { $0.name == name }?.tables ?? []
            return tables.compactMap { geometry.schema.table($0)?.schema }.first
        case .line(let id)?, .handle(let id, _)?: return geometry.line(id).flatMap { geometry.schema.table($0.ref.from.table)?.schema }
        default: return nil
        }
    }

    // MARK: Changes

    private func commit(_ name: String, from old: DBMLDiagram) {
        guard diagram != old else { return }
        host?.canvas(self, didChange: old, name: name)
    }

    /// A change as one step.
    func change(_ name: String, _ body: (inout DBMLDiagram) -> Void) {
        let old = diagram
        var d = diagram
        body(&d)
        diagram = d
        commit(name, from: old)
    }

    private func live(_ body: (inout DBMLDiagram) -> Void) {
        var d = diagram
        body(&d)
        guard d != diagram else { return }
        diagram = d
        host?.canvasDidChangeLive(self)
    }

    // MARK: Snap to grid

    /// A diagram point put on the grid (the grid is in view coordinates, the diagram scaled by the zoom).
    private func snapped(_ p: CGPoint, to grid: DBMLSnapGrid) -> CGPoint {
        CGPoint(x: (grid.origin.x + ((p.x * zoom - grid.origin.x) / grid.step).rounded() * grid.step) / zoom,
                y: (grid.origin.y + ((p.y * zoom - grid.origin.y) / grid.step).rounded() * grid.step) / zoom)
    }

    /// A drag's offset, changed so `anchor` (the dragged thing's top-left corner) lands on the host's grid; the
    /// grid shows while it snaps. Held ⌥ (the host says no grid) moves freely.
    private func snapOffset(_ offset: CGSize, anchor: CGPoint?) -> CGSize {
        guard let anchor, let grid = host?.canvasSnapGrid(self) else {
            shownGrid = nil
            return offset
        }
        shownGrid = grid
        let target = snapped(CGPoint(x: anchor.x + offset.width, y: anchor.y + offset.height), to: grid)
        return CGSize(width: target.x - anchor.x, height: target.y - anchor.y)
    }

    /// An arrow key's move with a grid: to the next grid line that way (from where the anchor is, on a line or not).
    private func gridStep(_ anchor: CGPoint, dx: CGFloat, dy: CGFloat, grid: DBMLSnapGrid) -> CGSize {
        func next(_ v: CGFloat, _ origin: CGFloat, _ dir: CGFloat) -> CGFloat {
            guard dir != 0 else { return v }
            let u = (v * zoom - origin) / grid.step
            let n = dir > 0 ? floor(u + 0.001) + 1 : ceil(u - 0.001) - 1
            return (origin + n * grid.step) / zoom
        }
        return CGSize(width: next(anchor.x, grid.origin.x, dx) - anchor.x, height: next(anchor.y, grid.origin.y, dy) - anchor.y)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        guard isEditable else { return }
        host?.canvasWasClicked(self)
        endNoteEditing()
        window?.makeFirstResponder(self)
        let p = point(event)
        if event.clickCount == 2 { return doubleClick(at: p) }
        let adding = !event.modifierFlags.intersection([.shift, .command]).isEmpty
        switch hit(p) {
        case .handle(let id, let k)?:
            dragControl(id, k, from: event)
        case .noteCorner(let id)?:
            resizeNote(id, from: event)
        case .note(let id)?:
            selection = DBMLSelection(note: id)
            dragNote(id, from: event)
        case .box(let key)?:
            if adding {
                var s = selection
                s.ref = nil
                s.note = nil
                if s.tables.contains(key) { s.tables.remove(key) } else { s.tables.insert(key) }
                selection = s
                if !selection.tables.contains(key) { return }
            } else if !selection.tables.contains(key) {
                selection = DBMLSelection(tables: [key])
            }
            dragTables(selection.tables, lead: key, from: event)
        case .line(let id)?:
            selection = DBMLSelection(ref: id)
        case .panel(let name)?:
            let tables = Set(geometry.groups.first { $0.name == name }?.tables ?? []).intersection(geometry.boxes.map(\.key))
            selection = DBMLSelection(tables: adding ? selection.tables.union(tables) : tables)
            dragTables(selection.tables, lead: nil, from: event)
        case nil:
            if !adding { selection = DBMLSelection() }
        }
    }

    private func doubleClick(at p: CGPoint) {
        switch hit(p) {
        case .note(let id)?, .noteCorner(let id)?:
            if geometry.stickies.first(where: { $0.id == id })?.own == true { editNote(id) }
        case .box(let key)?:
            if let box = geometry.box(key) { host?.canvas(self, showSourceLine: box.line) }
        case .line(let id)?, .handle(let id, _)?:
            if let line = geometry.line(id) { host?.canvas(self, showSourceLine: line.ref.line) }
        case .panel?:
            break
        case nil:
            addNote(at: CGPoint(x: p.x - 20, y: p.y - 20))
        }
    }

    /// Follows a drag; true if the pointer moved.
    private func track(_ event: NSEvent, _ body: (CGPoint) -> Void) -> Bool {
        guard let window else { return false }
        var moved = false
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: NSEvent.foreverDuration, mode: .eventTracking) { ev, stop in
            guard let ev, ev.type == .leftMouseDragged else {
                stop.pointee = true
                return
            }
            moved = true
            body(self.point(ev))
            self.autoscroll(with: ev)
        }
        return moved
    }

    /// Moves tables together; with a snap grid, the table dragged by (`lead`, else the group's top-left corner)
    /// lands on it and the others keep their places around it.
    private func dragTables(_ keys: Set<String>, lead: String?, from event: NSEvent) {
        let start = point(event)
        let origins = diagram.positions.filter { keys.contains($0.key) }
        let anchor = lead.flatMap { origins[$0] }
            ?? (origins.isEmpty ? nil : CGPoint(x: origins.values.map(\.x).min()!, y: origins.values.map(\.y).min()!))
        let old = diagram
        let moved = track(event) { p in
            let offset = self.snapOffset(CGSize(width: p.x - start.x, height: p.y - start.y), anchor: anchor)
            self.live { d in d.move(keys, from: origins, by: offset) }
        }
        shownGrid = nil
        if moved { commit(keys.count == 1 ? "Move Table" : "Move Tables", from: old) }
    }

    private func dragNote(_ id: String, from event: NSEvent) {
        let start = point(event)
        let old = diagram
        let own = diagram.notes.first { $0.id == id }?.frame
        let sticky = geometry.stickies.first { $0.id == id && !$0.own }?.rect
        let moved = track(event) { p in
            let offset = self.snapOffset(CGSize(width: p.x - start.x, height: p.y - start.y), anchor: own?.origin ?? sticky?.origin)
            let dx = offset.width, dy = offset.height
            self.live { d in
                if let own, let i = d.notes.firstIndex(where: { $0.id == id }) {
                    d.notes[i].frame.origin = CGPoint(x: max(0, (own.minX + dx).rounded()), y: max(0, (own.minY + dy).rounded()))
                } else if let sticky {
                    d.stickyFrames[id] = CGRect(origin: CGPoint(x: max(0, (sticky.minX + dx).rounded()), y: max(0, (sticky.minY + dy).rounded())), size: sticky.size)
                }
            }
        }
        shownGrid = nil
        if moved { commit("Move Note", from: old) }
    }

    private func resizeNote(_ id: String, from event: NSEvent) {
        guard let frame = diagram.notes.first(where: { $0.id == id })?.frame else { return }
        let start = point(event)
        let old = diagram
        let moved = track(event) { p in
            // With a grid, the corner dragged lands on it.
            let offset = self.snapOffset(CGSize(width: p.x - start.x, height: p.y - start.y), anchor: CGPoint(x: frame.maxX, y: frame.maxY))
            self.live { d in
                guard let i = d.notes.firstIndex(where: { $0.id == id }) else { return }
                d.notes[i].frame.size = CGSize(width: max(120, (frame.width + offset.width).rounded()), height: max(60, (frame.height + offset.height).rounded()))
            }
        }
        shownGrid = nil
        if moved { commit("Resize Note", from: old) }
    }

    private func dragControl(_ id: String, _ k: Int, from event: NSEvent) {
        let old = diagram
        let moved = track(event) { p in
            self.live { d in d.moveControl(k, of: id, to: p, in: self.geometry) }
        }
        if moved { commit("Bend Line", from: old) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard isEditable else { return nil }
        host?.canvasWasClicked(self)
        endNoteEditing()
        return menu(at: point(event))
    }

    // MARK: Notes

    func addNote(at point: CGPoint) {
        var id = ""
        change("Add Note") { d in id = d.addNote(at: point) }
        selection = DBMLSelection(note: id)
        editNote(id)
    }

    func deleteNote(_ id: String) {
        endNoteEditing(commitText: false)
        change("Delete Note") { d in d.notes.removeAll { $0.id == id } }
    }

    func setNoteColor(_ hex: String?, _ id: String) {
        change("Note Color") { d in
            if let i = d.notes.firstIndex(where: { $0.id == id }) { d.notes[i].color = hex == DBMLDiagramNote.palette[0].1 ? nil : hex }
        }
    }

    /// Typing in one of the diagram's notes, in place.
    func editNote(_ id: String) {
        guard let note = diagram.notes.first(where: { $0.id == id }) else { return }
        endNoteEditing()
        selection = DBMLSelection(note: id)
        editingNote = id
        let tv = DBMLNoteEditor(frame: .zero)
        tv.canvas = self
        tv.string = note.text
        tv.drawsBackground = false
        tv.isRichText = false
        tv.textContainerInset = NSSize(width: 3, height: 4)
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.font = NSFont.systemFont(ofSize: 12 * zoom)
        tv.textColor = .labelColor
        tv.allowsUndo = true
        tv.delegate = self
        addSubview(tv)
        noteEditor = tv
        positionNoteEditor()
        window?.makeFirstResponder(tv)
        tv.selectAll(nil)
        needsDisplay = true
    }

    private func positionNoteEditor() {
        guard let tv = noteEditor, let id = editingNote, let note = diagram.notes.first(where: { $0.id == id }) else { return }
        tv.frame = NSRect(x: note.frame.minX * zoom + 5, y: note.frame.minY * zoom + 4,
                          width: max(20, note.frame.width * zoom - 10), height: max(20, note.frame.height * zoom - 8))
        tv.font = NSFont.systemFont(ofSize: 12 * zoom)
    }

    func endNoteEditing(commitText: Bool = true) {
        guard let tv = noteEditor, let id = editingNote else { return }
        let text = tv.string
        noteEditor = nil
        editingNote = nil
        tv.removeFromSuperview()
        if commitText, diagram.notes.first(where: { $0.id == id })?.text != text {
            change("Edit Note") { d in if let i = d.notes.firstIndex(where: { $0.id == id }) { d.notes[i].text = text } }
        }
        needsDisplay = true
        if window?.firstResponder == nil || window?.firstResponder === window { window?.makeFirstResponder(self) }
    }

    func textDidEndEditing(_ notification: Notification) {
        if notification.object as? NSTextView === noteEditor { endNoteEditing() }
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if textView === noteEditor, commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            endNoteEditing()
            return true
        }
        return false
    }

    // MARK: Schemas

    /// Selects every table (and enum) of a schema.
    func selectSchema(_ name: String) {
        selection = DBMLSelection(tables: Set(geometry.boxes.filter { $0.schema == name }.map(\.key)))
    }

    /// Copy Schema: the schema's DBML (with its layout), a picture of it, and what the app adds.
    func copySchema(_ name: String) {
        let part = diagram.subset(schema: name, from: host?.diagramTitle)
        let item = NSPasteboardItem()
        DBMLRenderer.add(part, to: item)
        item.setString(part.fileText(), forType: .string)
        host?.canvas(self, copy: part, schema: name, to: item)
        Self.pasteboard.clearContents()
        Self.pasteboard.writeObjects([item])
    }

    func exportSchema(_ name: String) {
        host?.canvas(self, export: diagram.subset(schema: name, from: host?.diagramTitle), schema: name)
    }

    private func schemaMenu(_ name: String) -> NSMenuItem {
        let count = geometry.schema.tables.filter { $0.schema == name }.count
        let item = NSMenuItem(title: "Schema “\(name)” (\(count) table\(count == 1 ? "" : "s"))", action: nil, keyEquivalent: "")
        let m = NSMenu()
        m.addItem(DBMLMenuItem("Select Schema") { [weak self] in self?.selectSchema(name) })
        m.addItem(DBMLMenuItem("Copy Schema") { [weak self] in self?.copySchema(name) })
        if let title = host?.schemaExportTitle {
            m.addItem(DBMLMenuItem(title) { [weak self] in self?.exportSchema(name) })
        }
        item.submenu = m
        return item
    }

    // MARK: Menu

    func menu(at p: CGPoint) -> NSMenu {
        let menu = NSMenu()
        let found = hit(p)
        switch found {
        case .line(let id)?, .handle(let id, _)?:
            selection = DBMLSelection(ref: id)
            addLineItems(to: menu, id: id)
        case .note(let id)?, .noteCorner(let id)?:
            selection = DBMLSelection(note: id)
            if diagram.notes.contains(where: { $0.id == id }) {
                menu.addItem(DBMLMenuItem("Edit Note") { [weak self] in self?.editNote(id) })
                let colors = NSMenuItem(title: "Note Color", action: nil, keyEquivalent: "")
                let cm = NSMenu()
                let current = diagram.notes.first { $0.id == id }?.color ?? DBMLDiagramNote.palette[0].1
                for (name, hex) in DBMLDiagramNote.palette {
                    cm.addItem(DBMLMenuItem(name, checked: current == hex) { [weak self] in self?.setNoteColor(hex, id) })
                }
                colors.submenu = cm
                menu.addItem(colors)
                menu.addItem(DBMLMenuItem("Delete Note") { [weak self] in self?.deleteNote(id) })
            } else {
                menu.addItem(DBMLMenuItem("Note “\(id)” is part of the DBML (read-only)", enabled: false) {})
            }
        case .box(let key)?:
            if !selection.tables.contains(key) { selection = DBMLSelection(tables: [key]) }
        case .panel?, nil:
            break
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        // The schema of what's here — or, elsewhere, each schema.
        let schemas = geometry.schema.schemas
        if let name = schema(at: found) {
            menu.addItem(schemaMenu(name))
        } else if !schemas.isEmpty {
            if schemas.count == 1 {
                menu.addItem(schemaMenu(schemas[0]))
            } else {
                let all = NSMenuItem(title: "Schemas", action: nil, keyEquivalent: "")
                let m = NSMenu()
                for s in schemas { m.addItem(schemaMenu(s)) }
                all.submenu = m
                menu.addItem(all)
            }
        }
        menu.addItem(DBMLMenuItem("Select All Tables") { [weak self] in
            guard let self else { return }
            self.selection = DBMLSelection(tables: Set(self.geometry.boxes.map(\.key)))
        })
        menu.addItem(.separator())
        if found == nil || found.map({ if case .panel = $0 { return true } else { return false } }) == true {
            menu.addItem(DBMLMenuItem("Add Note Here") { [weak self] in self?.addNote(at: p) })
        }
        menu.addItem(DBMLMenuItem("Arrange Tables") { [weak self] in self?.change("Arrange Tables") { $0.arrange() } })
        menu.addItem(DBMLMenuItem("Show Column Types", checked: !diagram.hidesTypes) { [weak self] in
            self?.change("Column Types") { $0.hidesTypes.toggle() }
        })
        let lines = NSMenuItem(title: "All Lines", action: nil, keyEquivalent: "")
        let lm = NSMenu()
        for style in DBMLCurveStyle.allCases {
            lm.addItem(DBMLMenuItem(style.title, checked: diagram.defaultStyle == style && diagram.curves.values.allSatisfy { $0.style == nil }) { [weak self] in
                self?.change("Line Style") { $0.setAllStyles(style) }
            })
        }
        lines.submenu = lm
        menu.addItem(lines)
        let extra = host?.canvasMenuItems(self, at: p, hit: found) ?? []
        if !extra.isEmpty {
            menu.addItem(.separator())
            for item in extra { menu.addItem(item) }
        }
        return menu
    }

    static let lineColors: [(String, String)] = [("Blue", "#2F6FD0"), ("Green", "#2E9E5B"), ("Orange", "#E07B24"),
                                                 ("Red", "#D0453A"), ("Purple", "#8A55C9"), ("Gray", "#7D8B99")]

    func addLineItems(to menu: NSMenu, id: String) {
        guard let line = geometry.line(id) else { return }
        menu.addItem(DBMLMenuItem("\(line.ref.text) (\(line.ref.kindTitle))", enabled: false) {})
        for style in DBMLCurveStyle.allCases {
            let item = DBMLMenuItem(style.title, checked: line.style == style) { [weak self] in
                self?.change("Line Style") { $0.setStyle(style, for: id) }
            }
            item.image = NSImage(systemSymbolName: style.symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        menu.addItem(DBMLMenuItem("Reset Curve") { [weak self] in self?.change("Reset Line") { $0.resetCurve(id) } })
        let saved = diagram.curves[id]
        let sides = NSMenuItem(title: "Sides", action: nil, keyEquivalent: "")
        let sm = NSMenu()
        sm.addItem(DBMLMenuItem("Start on the Left", checked: saved?.fromSide == .left) { [weak self] in self?.change("Line Side") { $0.setSide(.left, start: true, for: id) } })
        sm.addItem(DBMLMenuItem("Start on the Right", checked: saved?.fromSide == .right) { [weak self] in self?.change("Line Side") { $0.setSide(.right, start: true, for: id) } })
        sm.addItem(DBMLMenuItem("End on the Left", checked: saved?.toSide == .left) { [weak self] in self?.change("Line Side") { $0.setSide(.left, start: false, for: id) } })
        sm.addItem(DBMLMenuItem("End on the Right", checked: saved?.toSide == .right) { [weak self] in self?.change("Line Side") { $0.setSide(.right, start: false, for: id) } })
        sm.addItem(.separator())
        sm.addItem(DBMLMenuItem("Automatic", checked: saved?.fromSide == nil && saved?.toSide == nil) { [weak self] in
            self?.change("Line Side") { d in d.setSide(nil, start: true, for: id); d.setSide(nil, start: false, for: id) }
        })
        sides.submenu = sm
        menu.addItem(sides)
        let colors = NSMenuItem(title: "Line Color", action: nil, keyEquivalent: "")
        let cm = NSMenu()
        cm.addItem(DBMLMenuItem("Automatic", checked: saved?.color == nil) { [weak self] in self?.change("Line Color") { $0.setColor(nil, for: id) } })
        for (name, hex) in Self.lineColors {
            cm.addItem(DBMLMenuItem(name, checked: saved?.color == hex) { [weak self] in self?.change("Line Color") { $0.setColor(hex, for: id) } })
        }
        colors.submenu = cm
        menu.addItem(colors)
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 51, 117:
            if let id = selection.note, diagram.notes.contains(where: { $0.id == id }) { return deleteNote(id) }
            if let id = selection.ref, diagram.curves[id] != nil { return change("Reset Line") { $0.resetCurve(id) } }
        case 53:
            selection = DBMLSelection()
            return
        case 123, 124, 125, 126:
            let dx: CGFloat = event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0
            let dy: CGFloat = event.keyCode == 126 ? -step : event.keyCode == 125 ? step : 0
            // With a snap grid, one grid step at a time onto the grid.
            let grid = host?.canvasSnapGrid(self)
            if !selection.tables.isEmpty {
                let keys = selection.tables
                let origins = diagram.positions.filter { keys.contains($0.key) }
                var offset = CGSize(width: dx, height: dy)
                if let grid, !origins.isEmpty {
                    let anchor = CGPoint(x: origins.values.map(\.x).min()!, y: origins.values.map(\.y).min()!)
                    offset = gridStep(anchor, dx: dx, dy: dy, grid: grid)
                }
                return change(keys.count == 1 ? "Move Table" : "Move Tables") { d in d.move(keys, from: d.positions, by: offset) }
            }
            if let id = selection.note, let i = diagram.notes.firstIndex(where: { $0.id == id }) {
                let offset = grid.map { gridStep(diagram.notes[i].frame.origin, dx: dx, dy: dy, grid: $0) } ?? CGSize(width: dx, height: dy)
                return change("Move Note") { d in
                    d.notes[i].frame.origin = CGPoint(x: max(0, d.notes[i].frame.minX + offset.width), y: max(0, d.notes[i].frame.minY + offset.height))
                }
            }
        case 0 where event.modifierFlags.contains(.command):
            selection = DBMLSelection(tables: Set(geometry.boxes.map(\.key)))
            return
        default:
            break
        }
        super.keyDown(with: event)
    }

    // MARK: Pointer and tips

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    /// Whether the canvas is what's under the pointer (not covered there by its container's edges).
    private func isOnTop(_ event: NSEvent) -> Bool {
        guard event.window === window, let frame = window?.contentView?.superview else { return false }
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.contains(p), visibleRect.contains(p),
              let hit = frame.hitTest(frame.convert(event.locationInWindow, from: nil)) else { return false }
        return hit === self || hit.isDescendant(of: self)
    }

    func cursor(at p: CGPoint) -> NSCursor {
        switch hit(p) {
        case .handle?: return .crosshair
        case .noteCorner?: return .frameResize(position: .bottomRight, directions: .all)
        case .note?, .box?, .panel?: return .openHand
        case .line?: return .pointingHand
        case nil: return .arrow
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard isEditable, isOnTop(event) else { return }
        cursor(at: point(event)).set()
    }

    override func cursorUpdate(with event: NSEvent) {
        guard isEditable, isOnTop(event) else { return }
        cursor(at: point(event)).set()
    }

    /// Tips as MxDataSQL gives them (each rectangle's text is worked out when it shows: the canvas owns them).
    func updateToolTips() {
        removeAllToolTips()
        let z = zoom
        func scaled(_ r: CGRect) -> NSRect { NSRect(x: r.minX * z, y: r.minY * z, width: r.width * z, height: r.height * z) }
        for box in geometry.boxes {
            addToolTip(scaled(CGRect(x: box.rect.minX, y: box.rect.minY, width: box.rect.width, height: DBMLGeometry.headerHeight)), owner: self, userData: nil)
            for k in box.rows.indices {
                addToolTip(scaled(CGRect(x: box.rect.minX, y: box.rect.minY + DBMLGeometry.headerHeight + CGFloat(k) * DBMLGeometry.rowHeight,
                                         width: box.rect.width, height: DBMLGeometry.rowHeight)), owner: self, userData: nil)
            }
        }
        for s in geometry.stickies { addToolTip(scaled(s.rect), owner: self, userData: nil) }
    }

    /// A table's note (or name), a column's type, keys, default and note, or what a note is for.
    func toolTip(at p: CGPoint) -> String? {
        if let s = geometry.stickies.last(where: { $0.rect.contains(p) }) {
            return s.own ? "Double-click to edit; drag to move" : "Sticky note \(s.id) from the DBML file"
        }
        guard let box = geometry.boxes.last(where: { $0.rect.contains(p) }) else { return nil }
        guard let k = DBMLGeometry.row(in: box, at: p) else { return box.note ?? box.title }
        let row = box.rows[k]
        var parts = [row.name + (row.type.isEmpty ? "" : " " + row.type)]
        if row.pk { parts.append("primary key") }
        if row.notNull, !row.pk { parts.append("not null") }
        if row.unique { parts.append("unique") }
        if let d = row.defaultValue { parts.append("default \(d)") }
        var tip = parts.joined(separator: ", ")
        if let note = row.note { tip += "\n" + note }
        return tip
    }
}

extension DBMLCanvasView: NSViewToolTipOwner {
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        toolTip(at: CGPoint(x: point.x / zoom, y: point.y / zoom)) ?? ""
    }
}

/// Typing in a note over the diagram.
final class DBMLNoteEditor: NSTextView {
    weak var canvas: DBMLCanvasView?

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { DispatchQueue.main.async { [weak self] in self?.canvas?.endNoteEditing() } }
        return ok
    }
}
