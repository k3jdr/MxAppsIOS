//
//  DBMLElementView.swift
//  MxNoteONE
//
//  A DBML database diagram on the page. Drag a table (or enum, or note) to
//  move it; click a relationship's line to select it and drag its control
//  points (a quadratic Bézier curve has one, a cubic two) to bend it; right-
//  click for its curve, sides and colour. Notes can be laid over the diagram:
//  double-click empty space (or Add Note), type, drag, resize from the corner.
//  Show DBML puts the DBML beside the diagram, coloured and checked as you
//  type. The DBML tab and right-click menus have the rest, including Export
//  DBML and Import DBML.
//

import AppKit
import UniformTypeIdentifiers

final class DBMLElementView: ElementView, NSTextViewDelegate {
    /// The diagram being worked on (the DBML ribbon tab acts on it).
    static weak var active: DBMLElementView? {
        didSet {
            NotebookStore.shared.editor.dbmlActive = active != nil
            if oldValue !== active { oldValue?.isEditing = false; oldValue?.clearSelection() }
            NotebookStore.shared.editor.dbmlChanged += 1
        }
    }

    let scroll = DBMLScrollView()
    let diagram = DBMLDiagramView()
    private var sourceScroll: NSScrollView?
    private(set) var sourceView: DBMLSourceTextView?
    private var problemButton: NSButton?
    private let sourceUndo = UndoManager()
    private var sourceBefore: DBMLData?
    private var reparse: DispatchWorkItem?
    private var noteEditor: DBMLNoteTextView?

    private(set) var layout: DBMLLayout
    private(set) var selectedBox: String?
    private(set) var selectedLine: String?
    private(set) var selectedNote: UUID?
    var hoverLine: String? { didSet { if oldValue != hoverLine { diagram.needsDisplay = true } } }
    private(set) var editingNote: UUID?

    var data: DBMLData { element.dbml ?? .starter }
    var isActive: Bool { Self.active === self }
    var showsSource: Bool { data.showsSource == true && !isExport }
    var sourceWidth: CGFloat { CGFloat(data.sourceWidth ?? 300) }

    override init(element: PageElement) {
        var element = element
        if element.dbml == nil { element.dbml = .starter }
        layout = DBMLLayout(element.dbml!)
        super.init(element: element)
        scroll.owner = self
        diagram.owner = self
        scroll.documentView = diagram
        addSubview(scroll)
        finishSetup()
        rebuild()
        setWidth(frame.width)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var minWidth: CGFloat { 300 }

    // MARK: Size

    /// The scale while something is dragged (Fit Width doesn't rescale under the pointer).
    private var heldZoom: CGFloat?

    /// The scale the diagram is drawn at: its own, or (Fit) the width there is, at most 100%.
    func zoom(forWidth width: CGFloat) -> CGFloat {
        if let heldZoom { return heldZoom }
        if let z = data.zoom { return CGFloat(z) }
        let room = width - (showsSource ? sourceWidth + 1 : 0)
        return max(0.3, min(1, room / max(layout.size.width, 1)))
    }

    var zoom: CGFloat { zoom(forWidth: frame.width) }

    private func height(forWidth width: CGFloat) -> CGFloat {
        let z = zoom(forWidth: width)
        let room = width - (showsSource ? sourceWidth + 1 : 0)
        let scroller: CGFloat = layout.size.width * z > room + 0.5 ? 15 : 0
        return Self.gripHeight + max(showsSource ? 300 : 120, ceil(layout.size.height * z) + scroller)
    }

    override func setWidth(_ width: CGFloat) {
        let w = max(minWidth, width)
        let old = frame.height
        setFrameSize(NSSize(width: w, height: height(forWidth: w)))
        if abs(old - frame.height) > 0.5 { heightChanged(from: old) }
    }

    override func layoutContent() {
        let c = contentFrame
        var area = c
        if showsSource {
            let w = min(sourceWidth, c.width - 120)
            if sourceScroll == nil { makeSourcePane() }
            sourceScroll?.isHidden = false
            let problems = problemButton?.isHidden == false ? 22.0 : 0
            sourceScroll?.frame = NSRect(x: c.minX, y: c.minY, width: w, height: c.height - problems)
            problemButton?.frame = NSRect(x: c.minX, y: c.maxY - problems, width: w, height: problems)
            area.origin.x += w + 1
            area.size.width -= w + 1
        } else {
            sourceScroll?.isHidden = true
            problemButton?.isHidden = true
        }
        scroll.frame = area
        let z = zoom
        diagram.zoom = z
        diagram.setFrameSize(NSSize(width: max(area.width, ceil(layout.size.width * z)), height: max(area.height - (layout.size.width * z > area.width + 0.5 ? 15 : 0), ceil(layout.size.height * z))))
        scroll.hasHorizontalScroller = layout.size.width * z > area.width + 0.5
        positionNoteEditor()
    }

    override func draw(_ dirtyRect: NSRect) {
        if showsSource {
            NSColor(white: 0.85, alpha: 1).setFill()
            NSRect(x: min(sourceWidth, contentFrame.width - 120), y: contentFrame.minY, width: 1, height: contentFrame.height).fill()
        }
        super.draw(dirtyRect)
    }

    // MARK: The diagram as the data has it

    /// Lays the diagram out again (after any change) and redraws it.
    func rebuild() {
        layout = DBMLLayout(data)
        // Every box keeps the place it was given (so later tables don't move the ones before them).
        let missing = layout.boxes.filter { data.positions[$0.key] == nil }
        if !missing.isEmpty {
            var d = data
            for b in missing { d.positions[b.key] = DBMLPoint(b.rect.origin) }
            element.dbml = d
        }
        // Something reaching past the top or left (a group's label, a control point pulled out): all of it moves in.
        if layout.overflow != .zero {
            var d = data
            let dx = -layout.overflow.x, dy = -layout.overflow.y
            for (key, p) in d.positions { d.positions[key] = DBMLPoint(x: p.x + dx, y: p.y + dy) }
            for i in (d.notes ?? []).indices { d.notes![i].x += dx; d.notes![i].y += dy }
            element.dbml = d
            layout = DBMLLayout(d)
        }
        if let key = selectedBox, !layout.boxes.contains(where: { $0.key == key }) { selectedBox = nil }
        if let key = selectedLine, !layout.lines.contains(where: { $0.ref.key == key }) { selectedLine = nil }
        if let id = selectedNote, !(data.notes ?? []).contains(where: { $0.id == id }) { selectedNote = nil }
        if let source = sourceView, source.string != data.source, window?.firstResponder !== source {
            source.string = data.source
            DBMLSourceTextView.highlight(source)
        }
        showProblems()
        diagram.updateToolTips()
        setWidth(frame.width)
        layoutContent()
        diagram.needsDisplay = true
        NotebookStore.shared.editor.dbmlChanged += 1
    }

    /// A change, as one undo step.
    func update(_ name: String, _ change: (inout DBMLData) -> Void) {
        let old = data
        var new = old
        change(&new)
        guard new != old else { return }
        element.dbml = new
        rebuild()
        commit(name, from: old)
    }

    private func commit(_ name: String, from old: DBMLData) {
        guard data != old else { return }
        controller?.markDirty()
        registerUndo(name, restoring: old)
    }

    private func registerUndo(_ name: String, restoring old: DBMLData) {
        guard let undo = controller?.undoManager else { return }
        undo.registerUndo(withTarget: self) { view in
            let now = view.data
            view.element.dbml = old
            view.rebuild()
            view.controller?.markDirty()
            view.registerUndo(name, restoring: now)
        }
        undo.setActionName(name)
    }

    /// While dragging: the data changes as the pointer moves (one undo step when it's let go).
    private func live(_ change: (inout DBMLData) -> Void) {
        var d = data
        change(&d)
        guard d != data else { return }
        element.dbml = d
        layout = DBMLLayout(d)
        setWidth(frame.width)
        layoutContent()
        diagram.needsDisplay = true
    }

    // MARK: Active (the DBML tab)

    func activate() {
        if !isActive {
            Self.active = self
            isEditing = true
        }
        if NotebookStore.shared.editor.ribbonTab != .dbml { NotebookStore.shared.editor.ribbonTab = .dbml }
    }

    /// Focus moving elsewhere on the page ends working on the diagram (not its own DBML or note editor).
    func focusMoved() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, let canvas = self.canvas else { return }
            if let v = window.firstResponder as? NSView, !v.isDescendant(of: self), v.isDescendant(of: canvas) { self.deactivate() }
        }
    }

    func deactivate() {
        endNoteEditing()
        if isActive { Self.active = nil }
        isEditing = false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, isActive { Self.active = nil }
    }

    func clearSelection() {
        selectedBox = nil
        selectedLine = nil
        selectedNote = nil
        diagram.needsDisplay = true
    }

    private func select(box: String? = nil, line: String? = nil, note: UUID? = nil) {
        selectedBox = box
        selectedLine = line
        selectedNote = note
        diagram.needsDisplay = true
        NotebookStore.shared.editor.dbmlChanged += 1
    }

    var selectedLineInfo: DBMLLayout.Line? { selectedLine.flatMap { key in layout.lines.first { $0.ref.key == key } } }
    var selectedNoteInfo: DBMLNote? { selectedNote.flatMap { id in data.notes?.first { $0.id == id } } }

    // MARK: Finding things

    enum Hit {
        case handle(String, Int)
        case noteCorner(UUID)
        case note(UUID)
        case box(String)
        case line(String)
    }

    func hit(_ p: CGPoint) -> Hit? {
        let z = zoom
        let reach = 7 / z
        if let line = selectedLineInfo {
            for (k, c) in line.controls.enumerated() where hypot(c.x - p.x, c.y - p.y) <= reach + 2 { return .handle(line.ref.key, k) }
        }
        for note in (data.notes ?? []).reversed() {
            if note.id == selectedNote, hypot(note.rect.maxX - p.x, note.rect.maxY - p.y) <= 12 / z { return .noteCorner(note.id) }
            if note.rect.contains(p) { return .note(note.id) }
        }
        for box in layout.boxes.reversed() where box.rect.contains(p) { return .box(box.key) }
        if let key = line(near: p, within: 5 / z) { return .line(key) }
        return nil
    }

    func line(near p: CGPoint, within distance: CGFloat) -> String? {
        var best: (String, CGFloat)?
        for line in layout.lines {
            let d = Self.distance(from: p, to: line.path.flattened)
            if d <= distance, best == nil || d < best!.1 { best = (line.ref.key, d) }
        }
        return best?.0
    }

    static func distance(from p: CGPoint, to path: NSBezierPath) -> CGFloat {
        var best = CGFloat.greatestFiniteMagnitude
        var last: CGPoint?
        var points = [CGPoint](repeating: .zero, count: 3)
        for i in 0..<path.elementCount {
            let kind = path.element(at: i, associatedPoints: &points)
            let q = points[0]
            if kind == .lineTo, let a = last {
                let ab = q - a, ap = p - a
                let t = max(0, min(1, (ap.x * ab.x + ap.y * ab.y) / max(ab.x * ab.x + ab.y * ab.y, 0.0001)))
                let c = a + ab * t
                best = min(best, hypot(p.x - c.x, p.y - c.y))
            }
            last = q
        }
        return best
    }

    // MARK: Mouse

    func mouseDown(at p: CGPoint, event: NSEvent) {
        endNoteEditing()
        if event.clickCount == 2 { return doubleClick(at: p) }
        switch hit(p) {
        case .handle(let key, let k)?:
            dragControl(key, k, from: event)
        case .noteCorner(let id)?:
            resizeNote(id, from: event)
        case .note(let id)?:
            select(note: id)
            drag(note: id, from: event)
        case .box(let key)?:
            select(box: key)
            drag(box: key, from: event)
        case .line(let key)?:
            select(line: key)
        case nil:
            clearSelection()
            NotebookStore.shared.editor.dbmlChanged += 1
        }
    }

    func doubleClick(at p: CGPoint) {
        switch hit(p) {
        case .note(let id)?, .noteCorner(let id)?:
            editNote(id)
        case .box(let key)?:
            if let box = layout.boxes.first(where: { $0.key == key }) { showInSource(line: box.line) }
        case .line(let key)?, .handle(let key, _)?:
            if let line = layout.lines.first(where: { $0.ref.key == key }) { showInSource(line: line.ref.line) }
        case nil:
            addNote(at: p)
        }
    }

    private func diagramPoint(_ event: NSEvent) -> CGPoint {
        let v = diagram.convert(event.locationInWindow, from: nil)
        return CGPoint(x: v.x / zoom, y: v.y / zoom)
    }

    private func track(_ event: NSEvent, _ body: (CGPoint, NSEvent) -> Void) -> Bool {
        guard let window else { return false }
        heldZoom = zoom
        defer { heldZoom = nil }
        var moved = false
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: NSEvent.foreverDuration, mode: .eventTracking) { ev, stop in
            guard let ev, ev.type == .leftMouseDragged else {
                stop.pointee = true
                return
            }
            moved = true
            body(self.diagramPoint(ev), ev)
            self.diagram.autoscroll(with: ev)
        }
        return moved
    }

    private func drag(box key: String, from event: NSEvent) {
        guard let origin = data.positions[key]?.cg else { return }
        let before = data
        let start = diagramPoint(event)
        let moved = track(event) { p, _ in
            self.live { d in
                d.positions[key] = DBMLPoint(x: max(0, (origin.x + p.x - start.x).rounded()), y: max(0, (origin.y + p.y - start.y).rounded()))
            }
        }
        if moved { rebuild(); commit("Move Table", from: before) }
    }

    private func drag(note id: UUID, from event: NSEvent) {
        guard let note = data.notes?.first(where: { $0.id == id }) else { return }
        let before = data
        let start = diagramPoint(event)
        let moved = track(event) { p, _ in
            self.live { d in
                guard let i = d.notes?.firstIndex(where: { $0.id == id }) else { return }
                d.notes![i].x = max(0, (note.x + p.x - start.x).rounded())
                d.notes![i].y = max(0, (note.y + p.y - start.y).rounded())
            }
        }
        if moved { rebuild(); commit("Move Note", from: before) }
    }

    private func resizeNote(_ id: UUID, from event: NSEvent) {
        guard let note = data.notes?.first(where: { $0.id == id }) else { return }
        let before = data
        let start = diagramPoint(event)
        let moved = track(event) { p, _ in
            self.live { d in
                guard let i = d.notes?.firstIndex(where: { $0.id == id }) else { return }
                d.notes![i].width = max(80, (note.width + p.x - start.x).rounded())
                d.notes![i].height = max(40, (note.height + p.y - start.y).rounded())
            }
        }
        if moved { rebuild(); commit("Resize Note", from: before) }
    }

    /// Dragging a control point bends the curve (both of a cubic curve's points are kept from then on).
    private func dragControl(_ key: String, _ k: Int, from event: NSEvent) {
        guard let line = layout.lines.first(where: { $0.ref.key == key }) else { return }
        let before = data
        let moved = track(event) { p, _ in
            self.live { d in
                var saved = d.lines?[key] ?? DBMLLine()
                saved.curve = line.curve
                switch line.curve {
                case .straight: return
                case .quadratic:
                    let mid = CGPoint(x: (line.start.x + line.end.x) / 2, y: (line.start.y + line.end.y) / 2)
                    saved.c1 = DBMLPoint(p - mid)
                case .cubic:
                    let c1 = k == 0 ? p : line.controls[0], c2 = k == 1 ? p : line.controls[1]
                    saved.c1 = DBMLPoint(c1 - line.start)
                    saved.c2 = DBMLPoint(c2 - line.end)
                }
                var lines = d.lines ?? [:]
                lines[key] = saved
                d.lines = lines
            }
        }
        if moved { rebuild(); commit("Bend Line", from: before) }
    }

    // MARK: Lines

    func setCurve(_ curve: DBMLCurve, line key: String? = nil) {
        guard let key = key ?? selectedLine else {
            // No line selected: every line, and new ones.
            return update("Line Style") { d in
                d.curve = curve
                d.lines = d.lines?.mapValues { var l = $0; l.curve = nil; l.c1 = nil; l.c2 = nil; return l }.filter { !$0.value.isPlain }
            }
        }
        update("Line Style") { d in
            var lines = d.lines ?? [:]
            var l = lines[key] ?? DBMLLine()
            if l.curve != curve { l.c1 = nil; l.c2 = nil }
            l.curve = curve
            lines[key] = l
            d.lines = lines
        }
    }

    func resetLine(_ key: String? = nil) {
        guard let key = key ?? selectedLine else { return NSSound.beep() }
        update("Reset Line") { d in
            d.lines?[key]?.c1 = nil
            d.lines?[key]?.c2 = nil
            d.lines?[key]?.fromSide = nil
            d.lines?[key]?.toSide = nil
            if d.lines?[key]?.isPlain == true { d.lines?[key] = nil }
        }
    }

    func setSide(_ side: DBMLSide?, start: Bool, line key: String? = nil) {
        guard let key = key ?? selectedLine else { return NSSound.beep() }
        update("Line Side") { d in
            var lines = d.lines ?? [:]
            var l = lines[key] ?? DBMLLine()
            if start { l.fromSide = side } else { l.toSide = side }
            l.c1 = nil
            l.c2 = nil
            lines[key] = l.isPlain ? nil : l
            d.lines = lines
        }
    }

    func setLineColor(_ hex: String?, line key: String? = nil) {
        guard let key = key ?? selectedLine else { return NSSound.beep() }
        update("Line Color") { d in
            var lines = d.lines ?? [:]
            var l = lines[key] ?? DBMLLine()
            l.color = hex
            lines[key] = l.isPlain ? nil : l
            d.lines = lines
        }
    }

    // MARK: Notes over the diagram

    func addNote(at point: CGPoint? = nil) {
        let p = point ?? {
            let visible = scroll.contentView.bounds
            return CGPoint(x: (visible.midX / zoom) - 90, y: max(10, (visible.minY / zoom) + 20))
        }()
        let note = DBMLNote(text: "", x: max(0, p.x.rounded()), y: max(0, p.y.rounded()))
        update("Add Note") { d in d.notes = (d.notes ?? []) + [note] }
        select(note: note.id)
        editNote(note.id)
    }

    func deleteNote(_ id: UUID? = nil) {
        guard let id = id ?? selectedNote else { return NSSound.beep() }
        endNoteEditing(commitText: false)
        update("Delete Note") { d in
            d.notes?.removeAll { $0.id == id }
            if d.notes?.isEmpty == true { d.notes = nil }
        }
        selectedNote = nil
    }

    func setNoteColor(_ hex: String, note id: UUID? = nil) {
        guard let id = id ?? selectedNote else { return NSSound.beep() }
        update("Note Color") { d in
            if let i = d.notes?.firstIndex(where: { $0.id == id }) { d.notes![i].color = hex == DBMLNote.palette[0].1 ? nil : hex }
        }
    }

    /// Typing in a note, in place.
    func editNote(_ id: UUID) {
        guard let note = data.notes?.first(where: { $0.id == id }) else { return }
        endNoteEditing()
        select(note: id)
        editingNote = id
        let tv = DBMLNoteTextView(frame: .zero)
        tv.owner = self
        tv.string = note.text
        tv.drawsBackground = false
        tv.isRichText = false
        tv.textContainerInset = NSSize(width: 4, height: 4)
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.font = NSFont.systemFont(ofSize: DBMLLayout.noteFont.pointSize * zoom)
        tv.textColor = NSColor(white: 0.1, alpha: 1)
        tv.insertionPointColor = .black
        tv.allowsUndo = true
        tv.delegate = self
        diagram.addSubview(tv)
        noteEditor = tv
        positionNoteEditor()
        window?.makeFirstResponder(tv)
        tv.selectAll(nil)
        diagram.needsDisplay = true
    }

    private func positionNoteEditor() {
        guard let tv = noteEditor, let id = editingNote, let note = data.notes?.first(where: { $0.id == id }) else { return }
        let z = zoom
        tv.frame = NSRect(x: note.x * z + 5, y: note.y * z + 4, width: max(20, note.width * z - 10), height: max(20, note.height * z - 8))
    }

    func endNoteEditing(commitText: Bool = true) {
        guard let tv = noteEditor, let id = editingNote else { return }
        let text = tv.string
        noteEditor = nil
        editingNote = nil
        tv.removeFromSuperview()
        if commitText {
            update("Edit Note") { d in if let i = d.notes?.firstIndex(where: { $0.id == id }) { d.notes![i].text = text } }
        }
        diagram.needsDisplay = true
        if window?.firstResponder == nil || window?.firstResponder === window { window?.makeFirstResponder(diagram) }
    }

    // MARK: Tables

    /// Every box placed afresh: a block for each table group (or schema), side by side; in a block, columns by
    /// relationship (a table right of the tables it points to).
    func arrange() {
        update("Arrange Tables") { d in d.positions = DBMLLayout.arranged(d) }
    }

    /// The DBML has a layout of its own (written by MxDataSQL): where its tables were put there.
    var hasFileLayout: Bool { DBMLFileLayout.layout(in: data.source).map { !$0.tables.isEmpty } ?? false }

    /// Every box where the DBML file's layout puts it (spread out for this diagram's taller rows), curves too.
    func arrangeFromFile() {
        guard let file = DBMLFileLayout.layout(in: data.source) else { return NSSound.beep() }
        update("Arrange as in the DBML File") { d in
            d.positions = DBMLLayout.fileArranged(d)
            let ids = Set(file.refs.keys)
            d.lines = d.lines?.filter { key, _ in !DBMLParser.parse(d.source).refs.contains { $0.key == key && ids.contains(DBMLFileLayout.refID($0)) } }
        }
    }

    func toggleTypes() {
        update(data.hidesTypes == true ? "Show Column Types" : "Hide Column Types") { d in d.hidesTypes = d.hidesTypes == true ? nil : true }
    }

    func setZoom(_ z: Double?) {
        update("Zoom") { d in d.zoom = z }
    }

    func zoom(by factor: Double) {
        setZoom(max(0.3, min(3, ((Double(zoom) * factor) * 20).rounded() / 20)))
    }

    // MARK: The DBML beside the diagram

    func toggleSource() {
        let showing = !showsSource
        update(showing ? "Show DBML" : "Hide DBML") { d in d.showsSource = showing ? true : nil }
        if showing, let source = sourceView { window?.makeFirstResponder(source) }
    }

    private func makeSourcePane() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(white: 0.985, alpha: 1)
        let tv = DBMLSourceTextView(frame: NSRect(x: 0, y: 0, width: sourceWidth, height: 300))
        tv.owner = self
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.font = DBMLSourceTextView.font
        tv.textColor = NSColor(white: 0.15, alpha: 1)
        tv.backgroundColor = NSColor(white: 0.985, alpha: 1)
        tv.insertionPointColor = .black
        tv.textContainerInset = NSSize(width: 6, height: 6)
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.string = data.source
        tv.delegate = self
        tv.setAccessibilityLabel("DBML")
        DBMLSourceTextView.highlight(tv)
        scroll.documentView = tv
        addSubview(scroll, positioned: .below, relativeTo: resizeHandle)
        let button = NSButton(title: "", target: self, action: #selector(goToProblem))
        button.isBordered = false
        button.alignment = .left
        button.font = .systemFont(ofSize: 11)
        button.contentTintColor = .systemRed
        button.isHidden = true
        addSubview(button, positioned: .below, relativeTo: resizeHandle)
        sourceScroll = scroll
        sourceView = tv
        problemButton = button
        showProblems()
    }

    private func showProblems() {
        guard let button = problemButton else { return }
        let problems = layout.schema.problems
        let wasHidden = button.isHidden
        if let first = problems.first, showsSource {
            let more = problems.count > 1 ? "  (+\(problems.count - 1) more)" : ""
            button.attributedTitle = NSAttributedString(string: "  ⚠︎ Line \(first.line): \(first.message)\(more)",
                                                        attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.systemRed])
            button.toolTip = problems.map { "Line \($0.line): \($0.message)" }.joined(separator: "\n")
            button.isHidden = false
        } else {
            button.isHidden = true
        }
        if wasHidden != button.isHidden { layoutContent() }
    }

    @objc private func goToProblem() {
        if let first = layout.schema.problems.first { showInSource(line: first.line) }
    }

    /// Shows the DBML with a line selected (a table's or relationship's definition).
    func showInSource(line: Int) {
        if !showsSource { toggleSource() }
        guard let tv = sourceView else { return }
        let ns = tv.string as NSString
        var location = 0
        for _ in 1..<max(1, line) {
            let r = ns.lineRange(for: NSRange(location: min(location, ns.length), length: 0))
            location = NSMaxRange(r)
            if location >= ns.length { break }
        }
        let range = ns.lineRange(for: NSRange(location: min(location, ns.length), length: 0))
        window?.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: range.location, length: max(0, range.length - (ns.substring(with: range).hasSuffix("\n") ? 1 : 0))))
        tv.scrollRangeToVisible(range)
    }

    func textDidBeginEditing(_ notification: Notification) {
        if notification.object as? NSTextView === sourceView, sourceBefore == nil { sourceBefore = data }
    }

    func textDidChange(_ notification: Notification) {
        guard let tv = notification.object as? DBMLSourceTextView, tv === sourceView else { return }
        if sourceBefore == nil { sourceBefore = data }
        DBMLSourceTextView.highlight(tv)
        reparse?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.applySource() }
        reparse = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// The typed DBML, shown in the diagram (an undo step for the typing when the DBML pane is left).
    private func applySource() {
        guard let tv = sourceView, tv.string != data.source else { return }
        var d = data
        d.source = tv.string
        element.dbml = d
        rebuild()
        controller?.markDirty()
    }

    func textDidEndEditing(_ notification: Notification) {
        if let tv = notification.object as? NSTextView, tv === noteEditor {
            endNoteEditing()
            return
        }
        guard notification.object as? NSTextView === sourceView else { return }
        reparse?.cancel()
        applySource()
        if let before = sourceBefore { commit("Edit DBML", from: before) }
        sourceBefore = nil
    }

    func undoManager(for view: NSTextView) -> UndoManager? { view === sourceView ? sourceUndo : nil }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if textView === noteEditor, commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            endNoteEditing()
            return true
        }
        if textView === sourceView, commandSelector == #selector(NSResponder.insertTab(_:)) {
            textView.insertText("  ", replacementRange: textView.selectedRange())
            return true
        }
        return false
    }

    // MARK: Files

    func exportDBML() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.dbmlType]
        panel.nameFieldStringValue = Self.safeName(data.title ?? layout.schema.project ?? "Diagram") + ".dbml"
        panel.message = "The DBML, with the notes laid over the diagram written as DBML sticky notes."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.exportText.write(to: url, atomically: true, encoding: .utf8) } catch {
            NotebookStore.shared.report("Couldn't export the DBML.", error)
        }
    }

    func importDBML() {
        guard let text = Self.chooseDBML() else { return }
        update("Import DBML") { d in
            d.source = text.source
            if d.title == nil { d.title = text.name }
            // The file's own layout (MxDataSQL's) places its tables, not where tables of the same names were.
            if let file = DBMLFileLayout.layout(in: text.source) {
                d.positions = d.positions.filter { file.tables[$0.key] == nil && !$0.key.hasPrefix("note:") }
                d.lines = nil
            }
        }
    }

    static let dbmlType = UTType(filenameExtension: "dbml") ?? .plainText

    /// A .dbml file's text (and its name), chosen in an open panel.
    static func chooseDBML() -> (source: String, name: String)? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [dbmlType, .plainText, UTType(filenameExtension: "sql") ?? .plainText]
        panel.message = "Choose a DBML file (from dbdiagram.io, dbdocs or written by hand)."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            return (try String(contentsOf: url, encoding: .utf8), url.deletingPathExtension().lastPathComponent)
        } catch {
            NotebookStore.shared.report("Couldn't read the DBML file.", error)
            return nil
        }
    }

    static func safeName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = s.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Diagram" : cleaned
    }

    func image(scale: CGFloat = 2) -> NSImage { DBMLDrawing.picture(data, scale: scale) }

    func copyPicture() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image()])
    }

    func exportPicture() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = Self.safeName(data.title ?? "Diagram") + ".png"
        guard panel.runModal() == .OK, let url = panel.url, let png = image().pngData else { return }
        do { try png.write(to: url) } catch { NotebookStore.shared.report("Couldn't save the picture.", error) }
    }

    // MARK: Page

    override func prepareForExport() {
        super.prepareForExport()
        clearSelection()
        scroll.hasHorizontalScroller = false
        layoutContent()
    }

    override func makeElement() -> PageElement {
        var e = super.makeElement()
        e.dbml = data
        return e
    }

    override func indexText() -> String? { data.searchText }

    // MARK: Menus

    func menu(at p: CGPoint) -> NSMenu {
        let menu = NSMenu()
        switch hit(p) {
        case .note(let id)?, .noteCorner(let id)?:
            select(note: id)
            menu.addItem(ClosureMenuItem("Edit Note") { [weak self] in self?.editNote(id) })
            let colors = NSMenuItem(title: "Note Color", action: nil, keyEquivalent: "")
            let cm = NSMenu()
            for (name, hex) in DBMLNote.palette {
                let current = selectedNoteInfo?.color ?? DBMLNote.palette[0].1
                cm.addItem(ClosureMenuItem(name, state: current == hex) { [weak self] in self?.setNoteColor(hex, note: id) })
            }
            colors.submenu = cm
            menu.addItem(colors)
            menu.addItem(ClosureMenuItem("Delete Note") { [weak self] in self?.deleteNote(id) })
        case .line(let key)?, .handle(let key, _)?:
            select(line: key)
            addLineItems(to: menu, key: key)
        case .box(let key)?:
            select(box: key)
            if let box = layout.boxes.first(where: { $0.key == key }) {
                menu.addItem(ClosureMenuItem("Show in DBML") { [weak self] in self?.showInSource(line: box.line) })
            }
            menu.addItem(ClosureMenuItem("Add Note Here") { [weak self] in self?.addNote(at: CGPoint(x: p.x + 20, y: p.y + 20)) })
        case nil:
            clearSelection()
            menu.addItem(ClosureMenuItem("Add Note Here") { [weak self] in self?.addNote(at: p) })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(showsSource ? "Hide DBML" : "Show DBML") { [weak self] in self?.toggleSource() })
        menu.addItem(ClosureMenuItem("Arrange Tables") { [weak self] in self?.arrange() })
        if hasFileLayout {
            menu.addItem(ClosureMenuItem("Arrange as in the DBML File") { [weak self] in self?.arrangeFromFile() })
        }
        menu.addItem(ClosureMenuItem("Show Column Types", state: data.hidesTypes != true) { [weak self] in self?.toggleTypes() })
        let newLines = NSMenuItem(title: "Lines", action: nil, keyEquivalent: "")
        let nm = NSMenu()
        for c in DBMLCurve.allCases {
            nm.addItem(ClosureMenuItem("All " + c.title + "s", state: data.defaultCurve == c && (data.lines ?? [:]).values.allSatisfy { $0.curve == nil }) { [weak self] in
                self?.setCurve(c, line: nil)
            })
        }
        newLines.submenu = nm
        menu.addItem(newLines)
        let zoomItem = NSMenuItem(title: "Zoom", action: nil, keyEquivalent: "")
        let zm = NSMenu()
        zm.addItem(ClosureMenuItem("Fit Width", state: data.zoom == nil) { [weak self] in self?.setZoom(nil) })
        for z in [0.5, 0.75, 1.0, 1.25, 1.5, 2.0] {
            zm.addItem(ClosureMenuItem("\(Int(z * 100))%", state: data.zoom == z) { [weak self] in self?.setZoom(z) })
        }
        zoomItem.submenu = zm
        menu.addItem(zoomItem)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Export DBML…") { [weak self] in self?.exportDBML() })
        menu.addItem(ClosureMenuItem("Import DBML…") { [weak self] in self?.importDBML() })
        menu.addItem(ClosureMenuItem("Copy Picture") { [weak self] in self?.copyPicture() })
        menu.addItem(ClosureMenuItem("Export Picture…") { [weak self] in self?.exportPicture() })
        menu.addItem(.separator())
        let container = super.contextMenu()
        for item in container.items {
            container.removeItem(item)
            menu.addItem(item)
        }
        return menu
    }

    func addLineItems(to menu: NSMenu, key: String) {
        guard let line = layout.lines.first(where: { $0.ref.key == key }) else { return }
        let title = NSMenuItem(title: "\(line.ref.from.text) \(line.ref.op) \(line.ref.to.text) (\(line.ref.kindTitle))", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        for c in DBMLCurve.allCases {
            let item = ClosureMenuItem(c.title, state: line.curve == c) { [weak self] in self?.setCurve(c, line: key) }
            item.image = NSImage(systemSymbolName: c.symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        menu.addItem(ClosureMenuItem("Reset Curve") { [weak self] in self?.resetLine(key) })
        let saved = data.lines?[key]
        let sides = NSMenuItem(title: "Sides", action: nil, keyEquivalent: "")
        let sm = NSMenu()
        sm.addItem(ClosureMenuItem("Start on the Left", state: saved?.fromSide == .left) { [weak self] in self?.setSide(.left, start: true, line: key) })
        sm.addItem(ClosureMenuItem("Start on the Right", state: saved?.fromSide == .right) { [weak self] in self?.setSide(.right, start: true, line: key) })
        sm.addItem(ClosureMenuItem("End on the Left", state: saved?.toSide == .left) { [weak self] in self?.setSide(.left, start: false, line: key) })
        sm.addItem(ClosureMenuItem("End on the Right", state: saved?.toSide == .right) { [weak self] in self?.setSide(.right, start: false, line: key) })
        sm.addItem(.separator())
        sm.addItem(ClosureMenuItem("Automatic", state: saved?.fromSide == nil && saved?.toSide == nil) { [weak self] in
            self?.setSide(nil, start: true, line: key)
            self?.setSide(nil, start: false, line: key)
        })
        sides.submenu = sm
        menu.addItem(sides)
        let colors = NSMenuItem(title: "Line Color", action: nil, keyEquivalent: "")
        let cm = NSMenu()
        cm.addItem(ClosureMenuItem("Automatic", state: saved?.color == nil) { [weak self] in self?.setLineColor(nil, line: key) })
        for (name, hex) in Self.lineColors {
            cm.addItem(ClosureMenuItem(name, state: saved?.color == hex) { [weak self] in self?.setLineColor(hex, line: key) })
        }
        colors.submenu = cm
        menu.addItem(colors)
        menu.addItem(ClosureMenuItem("Show in DBML") { [weak self] in self?.showInSource(line: line.ref.line) })
    }

    static let lineColors: [(String, String)] = [("Blue", "#2F6FD0"), ("Green", "#2E9E5B"), ("Orange", "#E07B24"),
                                                 ("Red", "#D0453A"), ("Purple", "#8A55C9"), ("Gray", "#7D8B99")]

    // MARK: Keys

    func keyDown(_ event: NSEvent) -> Bool {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 51, 117:
            if selectedNote != nil { deleteNote(); return true }
        case 53:
            clearSelection()
            return true
        case 123, 124, 125, 126:
            let dx: CGFloat = event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0
            let dy: CGFloat = event.keyCode == 126 ? -step : event.keyCode == 125 ? step : 0
            if let key = selectedBox {
                update("Move Table") { d in
                    if let p = d.positions[key] { d.positions[key] = DBMLPoint(x: max(0, p.x + dx), y: max(0, p.y + dy)) }
                }
                return true
            }
            if let id = selectedNote {
                update("Move Note") { d in
                    if let i = d.notes?.firstIndex(where: { $0.id == id }) { d.notes![i].x = max(0, d.notes![i].x + dx); d.notes![i].y = max(0, d.notes![i].y + dy) }
                }
                return true
            }
        default: break
        }
        return false
    }

    /// The pointer for what's under it.
    func cursor(at p: CGPoint) -> NSCursor {
        switch hit(p) {
        case .handle?: return .crosshair
        case .noteCorner?: return .frameResize(position: .bottomRight, directions: .all)
        case .note?, .box?: return .openHand
        case .line?: return .pointingHand
        case nil: return .arrow
        }
    }
}

// MARK: - The views inside

/// The diagram's scroller: across when it's wider than the container; up and down scrolls the page.
final class DBMLScrollView: NSScrollView {
    weak var owner: DBMLElementView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        hasVerticalScroller = false
        hasHorizontalScroller = false
        autohidesScrollers = true
        drawsBackground = true
        backgroundColor = .white
        borderType = .noBorder
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY), hasHorizontalScroller {
            super.scrollWheel(with: event)
        } else if let page = superview?.enclosingScrollView {
            page.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

/// Draws the diagram and takes its clicks and drags.
final class DBMLDiagramView: NSView, SetsOwnPointer {
    weak var owner: DBMLElementView?
    var zoom: CGFloat = 1 { didSet { if oldValue != zoom { needsDisplay = true } } }
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { owner?.isExport != true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let owner else { return }
        NSColor.white.setFill()
        dirtyRect.fill()
        if !owner.isExport {
            // A faint dot grid, as on a drawing board.
            NSColor(white: 0.86, alpha: 1).setFill()
            let step = 20 * zoom
            if step >= 6 {
                var y = (dirtyRect.minY / step).rounded(.down) * step
                while y <= dirtyRect.maxY {
                    var x = (dirtyRect.minX / step).rounded(.down) * step
                    while x <= dirtyRect.maxX {
                        NSRect(x: x, y: y, width: 1.2, height: 1.2).fill()
                        x += step
                    }
                    y += step
                }
            }
        }
        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform()
        t.scale(by: zoom)
        t.concat()
        let highlight = owner.isExport ? DBMLDrawing.Highlight()
            : DBMLDrawing.Highlight(box: owner.selectedBox, line: owner.selectedLine, note: owner.selectedNote, hoverLine: owner.hoverLine)
        DBMLDrawing.draw(owner.layout, owner.data, highlight: highlight, editingNote: owner.editingNote)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func point(_ event: NSEvent) -> CGPoint {
        let v = convert(event.locationInWindow, from: nil)
        return CGPoint(x: v.x / zoom, y: v.y / zoom)
    }

    override func mouseDown(with event: NSEvent) {
        guard let owner, !owner.isExport else { return }
        owner.activate()
        window?.makeFirstResponder(self)
        owner.mouseDown(at: point(event), event: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let owner, !owner.isExport else { return nil }
        owner.activate()
        return owner.menu(at: point(event))
    }

    override func keyDown(with event: NSEvent) {
        if owner?.keyDown(event) != true { super.keyDown(with: event) }
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { owner?.focusMoved() }
        return ok
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    // The pointer is set here only where the diagram is on top: over the container's resize edge (which covers the
    // diagram's right side) the edge's ↔ stays, instead of the two taking turns on every move.
    override func mouseMoved(with event: NSEvent) {
        guard let owner else { return }
        guard isUnderPointer(event) else {
            owner.hoverLine = nil
            return
        }
        let p = point(event)
        owner.hoverLine = owner.line(near: p, within: 5 / zoom)
        owner.cursor(at: p).set()
    }

    override func cursorUpdate(with event: NSEvent) {
        guard let owner, isUnderPointer(event) else { return }
        owner.cursor(at: point(event)).set()
    }

    override func mouseExited(with event: NSEvent) { owner?.hoverLine = nil }

    /// Table and column notes, and what each relationship is, as tips.
    func updateToolTips() {
        removeAllToolTips()
        guard let owner else { return }
        let z = zoom
        func scaled(_ r: CGRect) -> NSRect { NSRect(x: r.minX * z, y: r.minY * z, width: r.width * z, height: r.height * z) }
        for box in owner.layout.boxes where box.kind != .sticky {
            if let note = box.note {
                addToolTip(scaled(CGRect(x: box.rect.minX, y: box.rect.minY, width: box.rect.width, height: DBMLLayout.headerHeight)), owner: note as NSString, userData: nil)
            }
            for (k, row) in box.rows.enumerated() {
                var tip = [row.name + (row.type.isEmpty ? "" : " " + row.type)]
                var flags: [String] = []
                if row.pk { flags.append("primary key") }
                if row.notNull { flags.append("not null") }
                if row.unique { flags.append("unique") }
                if !flags.isEmpty { tip[0] += " (" + flags.joined(separator: ", ") + ")" }
                if let n = row.note { tip.append(n) }
                let r = CGRect(x: box.rect.minX, y: box.rect.minY + DBMLLayout.headerHeight + CGFloat(k) * DBMLLayout.rowHeight,
                               width: box.rect.width, height: DBMLLayout.rowHeight)
                addToolTip(scaled(r), owner: tip.joined(separator: "\n") as NSString, userData: nil)
            }
        }
    }
}

/// The DBML pane: monospaced, coloured as it's typed.
final class DBMLSourceTextView: NSTextView {
    weak var owner: DBMLElementView?

    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    private static let rules: [(NSRegularExpression, NSColor)] = {
        func re(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: o) }
        return [
            (re("\\b(Table|Ref|Enum|Note|Project|TableGroup|TablePartial|Records|indexes|as)\\b", [.caseInsensitive]), NSColor(hex: "#AF00DB") ?? .purple),
            (re("\\[[^\\]\\n]*\\]"), NSColor(hex: "#267F99") ?? .systemTeal),
            (re("(?<![\\w.])-?\\d+(\\.\\d+)?\\b"), NSColor(hex: "#098658") ?? .systemGreen),
            (re("\\s(<>|<|>|-)\\s"), NSColor(hex: "#E07B24") ?? .orange),
            (re("#[0-9A-Fa-f]{3,8}\\b"), NSColor(hex: "#795E26") ?? .brown),
            (re("\"[^\"\\n]*\""), NSColor(hex: "#001080") ?? .blue),
            (re("`[^`]*`"), NSColor(hex: "#795E26") ?? .brown),
            (re("'''[\\s\\S]*?'''|'[^'\\n]*'"), NSColor(hex: "#A31515") ?? .red),
            (re("//[^\\n]*|/\\*[\\s\\S]*?\\*/"), NSColor(hex: "#008000") ?? .systemGreen),
        ]
    }()

    /// Colours DBML: keywords, settings, numbers, relationships, strings and comments.
    static func highlight(_ tv: NSTextView) {
        guard let storage = tv.textStorage else { return }
        let all = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: NSColor(white: 0.15, alpha: 1)], range: all)
        for (rule, color) in rules {
            for m in rule.matches(in: storage.string, range: all) { storage.addAttribute(.foregroundColor, value: color, range: m.range) }
        }
        storage.endEditing()
        tv.typingAttributes = [.font: font, .foregroundColor: NSColor(white: 0.15, alpha: 1)]
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { owner?.activate() }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { owner?.focusMoved() }
        return ok
    }
}

/// Typing in a note over the diagram.
final class DBMLNoteTextView: NSTextView {
    weak var owner: DBMLElementView?

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { DispatchQueue.main.async { [weak self] in self?.owner?.endNoteEditing() } }
        return ok
    }
}

// MARK: - Putting diagrams on the page

extension CanvasController {
    /// Insert ▸ DBML Diagram: a sample diagram with its DBML showing, to write your own.
    func insertDBML(source: String? = nil, title: String? = nil) {
        guard ref != nil else { return }
        let p = nextInsertionPoint()
        var element = PageElement(kind: .dbml, x: p.x, y: p.y, width: 1000)
        var d = DBMLData.starter
        if let source { d.source = source; d.title = title } else { d.showsSource = true }
        element.dbml = d
        guard let view = addElement(element) as? DBMLElementView else { return }
        undoManager?.setActionName("Insert DBML Diagram")
        DispatchQueue.main.async {
            view.activate()
            view.window?.makeFirstResponder(view.diagram)
        }
    }

    /// Insert ▸ DBML Diagram from File…
    func importDBMLFile() {
        guard ref != nil, let file = DBMLElementView.chooseDBML() else { return }
        insertDBML(source: file.source, title: file.name)
    }
}

// MARK: - Quick Help

extension DBMLDiagramView {
    /// What's under the pointer, in words.
    func quickHelp(at p: NSPoint) -> QuickHelpItem? {
        guard let owner else { return nil }
        let q = CGPoint(x: p.x / zoom, y: p.y / zoom)
        switch owner.hit(q) {
        case .box(let key)?:
            guard let box = owner.layout.boxes.first(where: { $0.key == key }) else { return nil }
            switch box.kind {
            case .table:
                let refs = owner.layout.lines.filter { $0.ref.from.table == key || $0.ref.to.table == key }.count
                return QuickHelpItem(title: "Table \(box.title)", detail: "\(box.rows.count) column\(box.rows.count == 1 ? "" : "s"), \(refs) relationship\(refs == 1 ? "" : "s"). "
                                     + (box.note.map { $0 + "\n" } ?? "") + "Drag it to move it (the lines follow); double-click for its DBML.",
                                     shortcut: nil, symbol: "tablecells")
            case .enumeration:
                return QuickHelpItem(title: "Enum \(box.title)", detail: box.rows.map(\.name).joined(separator: ", ") + ". Drag it to move it.", shortcut: nil, symbol: "list.bullet")
            case .sticky:
                return QuickHelpItem(title: "Note \(box.title)", detail: "A sticky note from the DBML. Drag it to move it; double-click to edit it in the DBML.", shortcut: nil, symbol: "note.text")
            }
        case .line(let key)?, .handle(let key, _)?:
            guard let line = owner.layout.lines.first(where: { $0.ref.key == key }) else { return nil }
            return QuickHelpItem(title: "Ref \(line.ref.from.text) \(line.ref.op) \(line.ref.to.text)",
                                 detail: "A \(line.ref.kindTitle) relationship, drawn as a \(line.curve.title.lowercased()). Click it, then drag its control points to bend it; right-click for straight, quadratic or cubic, its sides and colour.",
                                 shortcut: nil, symbol: line.curve.symbol)
        case .note?, .noteCorner?:
            return QuickHelpItem(title: "Note", detail: "A note over the diagram: drag to move, drag its corner to resize, double-click to type; right-click for its colour. Exported as a DBML sticky note.",
                                 shortcut: nil, symbol: "note.text")
        case nil:
            return QuickHelpItem(title: "DBML Diagram", detail: "Click it to work on it (the DBML tab). Double-click empty space for a note; right-click for Show DBML, Arrange Tables, line styles, zoom and Export DBML.",
                                 shortcut: nil, symbol: "cylinder.split.1x2")
        }
    }
}
