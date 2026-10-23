//
//  DBMLElementView.swift
//  MxNoteONE
//
//  A DBML database diagram on the page: the shared DBML canvas (Shared/DBML, as in MxDataSQL) in a
//  container. Drag tables (several at once, or a whole schema), bend relationship lines through their
//  control points, lay notes over it, and right-click a schema to select it, copy it (it pastes onto
//  any page as a diagram of its own) or export it to a new page. Show DBML puts the DBML beside the
//  diagram, coloured and checked as you type. The DBML tab and right-click menus have the rest:
//  Export DBML / Import DBML (MxDataSQL's .dbml files, with their layout), File Layout, pictures.
//

import AppKit
import UniformTypeIdentifiers

final class DBMLElementView: ElementView, NSTextViewDelegate, DBMLCanvasHost {
    /// The diagram being worked on (the DBML ribbon tab acts on it).
    static weak var active: DBMLElementView? {
        didSet {
            NotebookStore.shared.editor.dbmlActive = active != nil
            if oldValue !== active { oldValue?.isEditing = false; oldValue?.diagramCanvas.selection = DBMLSelection() }
            NotebookStore.shared.editor.dbmlChanged += 1
        }
    }

    let scroll = DBMLScrollView()
    /// The diagram itself (the shared canvas).
    let diagramCanvas: DBMLCanvasView
    private var sourceScroll: NSScrollView?
    private(set) var sourceView: DBMLSourceTextView?
    private var problemButton: NSButton?
    private let sourceUndo = UndoManager()
    private var sourceBefore: DBMLData?
    private var reparse: DispatchWorkItem?
    /// While something is dragged, Fit Width keeps its scale (the diagram doesn't rescale under the pointer).
    private var heldZoom: CGFloat?
    /// The page's data when a drag began (its undo step goes back to it).
    private var liveStart: DBMLData?

    var data: DBMLData { element.dbml ?? .starter }
    var isActive: Bool { Self.active === self }
    var showsSource: Bool { data.showsSource == true && !isExport }
    var sourceWidth: CGFloat { CGFloat(data.sourceWidth ?? 300) }
    var geometry: DBMLGeometry { diagramCanvas.geometry }

    /// Around the diagram in its container.
    static let contentMargin: CGFloat = 24

    override init(element: PageElement) {
        var element = element
        if element.dbml == nil { element.dbml = .starter }
        diagramCanvas = DBMLCanvasView(diagram: element.dbml!.diagram)
        super.init(element: element)
        diagramCanvas.host = self
        // The page is light paper: so is the diagram on it.
        diagramCanvas.appearance = NSAppearance(named: .aqua)
        scroll.appearance = NSAppearance(named: .aqua)
        scroll.owner = self
        scroll.documentView = diagramCanvas
        addSubview(scroll)
        finishSetup()
        // Tables placed for the first time keep those places (and a file's section is kept apart).
        var d = data
        d.take(diagramCanvas.diagram)
        if d != data { self.element.dbml = d }
        showProblems()
        setWidth(frame.width)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var minWidth: CGFloat { 300 }

    // MARK: Size

    private func room(_ width: CGFloat) -> CGFloat { width - (showsSource ? sourceWidth + 1 : 0) }

    /// The scale the diagram is drawn at: its own, or (Fit Width) the width there is, at most 100%.
    func zoom(forWidth width: CGFloat) -> CGFloat {
        if let heldZoom { return heldZoom }
        if let z = data.zoom { return CGFloat(z) }
        return max(0.3, min(1, room(width) / max(geometry.extent.maxX + Self.contentMargin, 1)))
    }

    var zoom: CGFloat { zoom(forWidth: frame.width) }

    private func height(forWidth width: CGFloat) -> CGFloat {
        let z = zoom(forWidth: width)
        let scroller: CGFloat = (geometry.extent.maxX + Self.contentMargin) * z > room(width) + 0.5 ? 15 : 0
        return Self.gripHeight + max(showsSource ? 300 : 120, ceil((geometry.extent.maxY + Self.contentMargin) * z) + scroller)
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
        diagramCanvas.zoom = z
        let wide = (geometry.extent.maxX + Self.contentMargin) * z > area.width + 0.5
        scroll.hasHorizontalScroller = wide && !isExport
        diagramCanvas.setFrameSize(diagramCanvas.contentSize(margin: Self.contentMargin,
                                                             minimum: NSSize(width: area.width, height: area.height - (wide ? 15 : 0))))
    }

    override func draw(_ dirtyRect: NSRect) {
        if showsSource {
            NSColor(white: 0.85, alpha: 1).setFill()
            NSRect(x: min(sourceWidth, contentFrame.width - 120), y: contentFrame.minY, width: 1, height: contentFrame.height).fill()
        }
        super.draw(dirtyRect)
    }

    /// After a change: the container's size, the DBML pane's text and problems, the ribbon.
    private func refresh() {
        if let source = sourceView, source.string != diagramCanvas.diagram.source, window?.firstResponder !== source {
            source.string = diagramCanvas.diagram.source
            if let storage = source.textStorage { DBMLSyntax.highlight(storage) }
        }
        showProblems()
        setWidth(frame.width)
        layoutContent()
        NotebookStore.shared.editor.dbmlChanged += 1
    }

    // MARK: Changes (each one an undo step)

    /// The canvas's diagram into the page's data.
    private func store() {
        var d = data
        d.take(diagramCanvas.diagram)
        element.dbml = d
    }

    /// A change to the diagram as one undo step.
    func update(_ name: String, _ body: (inout DBMLDiagram) -> Void) { diagramCanvas.change(name, body) }

    /// A change to the page's data (zoom, DBML pane, an import) as one undo step.
    func updateData(_ name: String, _ body: (inout DBMLData) -> Void) {
        let old = data
        var d = old
        body(&d)
        guard d != old else { return }
        element.dbml = d
        diagramCanvas.diagram = d.diagram
        store()
        commit(name, from: old)
        refresh()
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
            view.diagramCanvas.diagram = old.diagram
            view.refresh()
            view.controller?.markDirty()
            view.registerUndo(name, restoring: now)
        }
        undo.setActionName(name)
    }

    // MARK: The canvas's host

    func canvas(_ canvas: DBMLCanvasView, didChange old: DBMLDiagram, name: String) {
        heldZoom = nil
        let before = liveStart ?? data
        liveStart = nil
        store()
        commit(name, from: before)
        refresh()
    }

    func canvasDidChangeLive(_ canvas: DBMLCanvasView) {
        if heldZoom == nil { heldZoom = canvas.zoom }
        if liveStart == nil { liveStart = data }
        store()
        setWidth(frame.width)
        layoutContent()
    }

    func canvasSelectionDidChange(_ canvas: DBMLCanvasView) { NotebookStore.shared.editor.dbmlChanged += 1 }

    func canvasWasClicked(_ canvas: DBMLCanvasView) {
        heldZoom = nil
        liveStart = nil
        activate()
    }

    var schemaExportTitle: String { "Export Schema to a New Page" }

    var diagramTitle: String? { data.title ?? controller?.content?.title }

    /// A schema on a page of its own (after this one), as a diagram (its DBML, places, curves and notes).
    func canvas(_ canvas: DBMLCanvasView, export part: DBMLDiagram, schema: String) {
        guard let ref = controller?.ref else { return NSSound.beep() }
        var d = DBMLData(source: part.source)
        d.take(part)
        d.title = schema
        let store = NotebookStore.shared
        let title = (diagramTitle.map { $0 + " — " } ?? "") + schema
        controller?.flush()
        guard let page = store.addPage(in: SectionRef(notebookID: ref.notebookID, sectionID: ref.sectionID), after: ref.pageID, title: title,
                                       select: false), var content = store.loadPage(page) else { return NSSound.beep() }
        // The diagram goes on the new page before it opens.
        var diagram = PageElement(kind: .dbml, x: Double(PageCanvasView.margin), y: Double(PageCanvasView.contentTop), width: max(600, element.width))
        diagram.dbml = d
        content.elements.append(diagram)
        let index = PageIndexer.index(elements: content.elements)
        store.savePage(content, ref: page, plainText: index.text, tags: index.tags)
        store.selectPage(page.pageID)
    }

    /// Copy Schema: it also pastes onto a page as a diagram of its own.
    func canvas(_ canvas: DBMLCanvasView, copy part: DBMLDiagram, schema: String, to item: NSPasteboardItem) {
        var d = DBMLData(source: part.source)
        d.take(part)
        d.title = schema
        var copied = PageElement(kind: .dbml, x: 0, y: 0, width: max(400, element.width))
        copied.dbml = d
        if let clip = try? JSONEncoder().encode(ClipboardElement(element: copied, assetData: nil)) {
            item.setData(clip, forType: PageCanvasView.elementType)
        }
    }

    func canvas(_ canvas: DBMLCanvasView, showSourceLine line: Int) { showInSource(line: line) }

    /// Snap to Grid reaches into the diagram: dragged tables and notes land on the page's grid (⌥ moves freely).
    func canvasSnapGrid(_ canvas: DBMLCanvasView) -> DBMLSnapGrid? {
        guard let page = self.canvas, page.snaps else { return nil }
        return DBMLSnapGrid(step: page.gridStep, origin: canvas.convert(page.gridOrigin, from: page))
    }

    func canvasMenuItems(_ canvas: DBMLCanvasView, at point: CGPoint, hit: DBMLHit?) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if case .box(let key)? = hit, let box = geometry.box(key) {
            items.append(ClosureMenuItem("Show in DBML") { [weak self] in self?.showInSource(line: box.line) })
        }
        items.append(ClosureMenuItem(showsSource ? "Hide DBML" : "Show DBML") { [weak self] in self?.toggleSource() })
        if hasFileLayout {
            items.append(ClosureMenuItem("Arrange as in the DBML File") { [weak self] in self?.arrangeFromFile() })
        }
        let zoomItem = NSMenuItem(title: "Zoom", action: nil, keyEquivalent: "")
        let zm = NSMenu()
        zm.addItem(ClosureMenuItem("Fit Width", state: data.zoom == nil) { [weak self] in self?.setZoom(nil) })
        for z in [0.5, 0.75, 1.0, 1.25, 1.5, 2.0] {
            zm.addItem(ClosureMenuItem("\(Int(z * 100))%", state: data.zoom == z) { [weak self] in self?.setZoom(z) })
        }
        zoomItem.submenu = zm
        items.append(zoomItem)
        items.append(.separator())
        items.append(ClosureMenuItem("Export DBML…") { [weak self] in self?.exportDBML() })
        items.append(ClosureMenuItem("Import DBML…") { [weak self] in self?.importDBML() })
        items.append(ClosureMenuItem("Copy Picture") { [weak self] in self?.copyPicture() })
        items.append(ClosureMenuItem("Export Picture…") { [weak self] in self?.exportPicture() })
        items.append(.separator())
        let container = contextMenu()
        for item in container.items {
            container.removeItem(item)
            items.append(item)
        }
        return items
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
            guard let self, let window = self.window, let page = self.canvas else { return }
            if let v = window.firstResponder as? NSView, !v.isDescendant(of: self), v.isDescendant(of: page) { self.deactivate() }
        }
    }

    func deactivate() {
        diagramCanvas.endNoteEditing()
        if isActive { Self.active = nil }
        isEditing = false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, isActive { Self.active = nil }
    }

    // MARK: Commands (the DBML tab, the menus)

    var selectedLineInfo: DBMLGeometry.Line? { diagramCanvas.selection.ref.flatMap { geometry.line($0) } }
    var selectedNote: String? {
        diagramCanvas.selection.note.flatMap { id in diagramCanvas.diagram.notes.contains { $0.id == id } ? id : nil }
    }

    /// A line style: the selected line's, or (none selected) every line's.
    func setCurve(_ style: DBMLCurveStyle) {
        if let id = diagramCanvas.selection.ref {
            update("Line Style") { $0.setStyle(style, for: id) }
        } else {
            update("Line Style") { $0.setAllStyles(style) }
        }
    }

    func resetLine() {
        guard let id = diagramCanvas.selection.ref else { return NSSound.beep() }
        update("Reset Line") { $0.resetCurve(id) }
    }

    func setLineColor(_ hex: String?) {
        guard let id = diagramCanvas.selection.ref else { return NSSound.beep() }
        update("Line Color") { $0.setColor(hex, for: id) }
    }

    func addNote() {
        let visible = scroll.contentView.bounds
        diagramCanvas.addNote(at: CGPoint(x: max(10, visible.midX / zoom - 110), y: max(10, visible.minY / zoom + 20)))
    }

    func setNoteColor(_ hex: String) {
        guard let id = selectedNote else { return NSSound.beep() }
        diagramCanvas.setNoteColor(hex, id)
    }

    func deleteNote() {
        guard let id = selectedNote else { return NSSound.beep() }
        diagramCanvas.deleteNote(id)
    }

    /// Every table placed afresh (as MxDataSQL arranges: a block per table group or schema, related tables together).
    func arrange() { update("Arrange Tables") { $0.arrange() } }

    /// The diagram came from a .dbml file with a layout of its own (MxDataSQL's).
    var hasFileLayout: Bool { data.fileLayout.map { !$0.tables.isEmpty } ?? false }

    /// Tables, notes and curves where the DBML file's layout has them.
    func arrangeFromFile() {
        guard let layout = data.fileLayout else { return NSSound.beep() }
        update("Arrange as in the DBML File") { d in
            d.positions = [:]
            d.stickyFrames = [:]
            d.curves = [:]
            d.apply(layout)
            d.placeMissing()
        }
    }

    func toggleTypes() {
        update(diagramCanvas.diagram.hidesTypes ? "Show Column Types" : "Hide Column Types") { $0.hidesTypes.toggle() }
    }

    func setZoom(_ z: Double?) { updateData("Zoom") { $0.zoom = z } }

    func zoom(by factor: Double) {
        setZoom(max(0.3, min(3, ((Double(zoom) * factor) * 20).rounded() / 20)))
    }

    // MARK: The DBML beside the diagram

    func toggleSource() {
        let showing = !showsSource
        updateData(showing ? "Show DBML" : "Hide DBML") { $0.showsSource = showing ? true : nil }
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
        tv.font = DBMLSyntax.font
        tv.textColor = NSColor(white: 0.15, alpha: 1)
        tv.backgroundColor = NSColor(white: 0.985, alpha: 1)
        tv.insertionPointColor = .black
        tv.textContainerInset = NSSize(width: 6, height: 6)
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.string = diagramCanvas.diagram.source
        tv.delegate = self
        tv.setAccessibilityLabel("DBML")
        if let storage = tv.textStorage { DBMLSyntax.highlight(storage) }
        tv.typingAttributes = [.font: DBMLSyntax.font, .foregroundColor: NSColor(white: 0.15, alpha: 1)]
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
        let problems = geometry.schema.problems
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
        if let first = geometry.schema.problems.first { showInSource(line: first.line) }
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
        if let storage = tv.textStorage { DBMLSyntax.highlight(storage) }
        tv.typingAttributes = [.font: DBMLSyntax.font, .foregroundColor: NSColor(white: 0.15, alpha: 1)]
        reparse?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.applySource() }
        reparse = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// The typed DBML, shown in the diagram (an undo step for the typing when the DBML pane is left).
    private func applySource() {
        guard let tv = sourceView, tv.string != diagramCanvas.diagram.source else { return }
        diagramCanvas.diagram.source = tv.string
        store()
        refresh()
        controller?.markDirty()
    }

    func textDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextView === sourceView else { return }
        reparse?.cancel()
        applySource()
        if let before = sourceBefore { commit("Edit DBML", from: before) }
        sourceBefore = nil
    }

    func undoManager(for view: NSTextView) -> UndoManager? { view === sourceView ? sourceUndo : nil }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
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
        panel.nameFieldStringValue = Self.safeName(data.title ?? geometry.schema.project ?? "Diagram") + ".dbml"
        panel.message = "The DBML, then MxDataSQL's diagram section: the notes as DBML sticky notes and where every table sits."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.exportText.write(to: url, atomically: true, encoding: .utf8) } catch {
            NotebookStore.shared.report("Couldn't export the DBML.", error)
        }
    }

    func importDBML() {
        guard let file = Self.chooseDBML() else { return }
        updateData("Import DBML") { d in
            var fresh = DBMLData.fromFile(file.source, title: d.title ?? file.name)
            fresh.zoom = d.zoom
            fresh.showsSource = d.showsSource
            fresh.sourceWidth = d.sourceWidth
            if DBMLFileLayout.layout(in: file.source) == nil {
                // Tables keep their places while their names stay.
                for (k, p) in d.positions where fresh.positions[k] == nil { fresh.positions[k] = p }
            }
            d = fresh
        }
    }

    static let dbmlType = UTType(filenameExtension: "dbml") ?? .plainText

    /// A .dbml file's text (and its name), chosen in an open panel.
    static func chooseDBML() -> (source: String, name: String)? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [dbmlType, .plainText, UTType(filenameExtension: "sql") ?? .plainText]
        panel.message = "Choose a DBML file (from MxDataSQL, dbdiagram.io, dbdocs or written by hand)."
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

    /// Where Copy Picture puts the picture (the clipboard; self-tests use a pasteboard of their own).
    static var pasteboard = NSPasteboard.general

    /// Copy Picture: the diagram on the clipboard as PDF (sharp at any size), PNG and TIFF.
    func copyPicture() {
        if !DBMLRenderer.copy(diagramCanvas.diagram, to: Self.pasteboard) { NSSound.beep() }
    }

    func exportPicture() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = Self.safeName(data.title ?? "Diagram") + ".png"
        guard panel.runModal() == .OK, let url = panel.url,
              let png = DBMLRenderer.bitmap(diagramCanvas.diagram)?.representation(using: .png, properties: [:]) else { return }
        do { try png.write(to: url) } catch { NotebookStore.shared.report("Couldn't save the picture.", error) }
    }

    // MARK: Page

    override func prepareForExport() {
        super.prepareForExport()
        diagramCanvas.showsSelection = false
        diagramCanvas.isEditable = false
        scroll.hasHorizontalScroller = false
        layoutContent()
    }

    override func makeElement() -> PageElement {
        var e = super.makeElement()
        e.dbml = data
        return e
    }

    override func indexText() -> String? { data.searchText }
}

extension DBMLCanvasView: SetsOwnPointer {}

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

/// The DBML pane: monospaced, coloured as it's typed (DBMLSyntax).
final class DBMLSourceTextView: NSTextView {
    weak var owner: DBMLElementView?

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

// MARK: - Quick Help

extension DBMLCanvasView {
    /// What's under the pointer, in words.
    func quickHelp(at p: NSPoint) -> QuickHelpItem? {
        let q = CGPoint(x: p.x / zoom, y: p.y / zoom)
        switch hit(q) {
        case .box(let key)?:
            guard let box = geometry.box(key) else { return nil }
            if box.kind == .enumeration {
                return QuickHelpItem(title: box.title, detail: box.rows.map(\.name).joined(separator: ", ") + ". Drag it to move it.", shortcut: nil, symbol: "list.bullet")
            }
            let refs = geometry.lines.filter { $0.ref.from.table == key || $0.ref.to.table == key }.count
            return QuickHelpItem(title: "Table \(box.title)", detail: "\(box.rows.count) column\(box.rows.count == 1 ? "" : "s"), \(refs) relationship\(refs == 1 ? "" : "s"). "
                                 + (box.note.map { $0 + "\n" } ?? "") + "Drag it to move it (⇧-click for more tables: they move together); double-click for its DBML; right-click for its schema.",
                                 shortcut: nil, symbol: "tablecells")
        case .line(let id)?, .handle(let id, _)?:
            guard let line = geometry.line(id) else { return nil }
            return QuickHelpItem(title: "Ref \(line.ref.text)",
                                 detail: "A \(line.ref.kindTitle) relationship, drawn \(line.style.title.lowercased()). Click it, then drag its control points (Bézier curves) to bend it; right-click for its curve, sides and colour.",
                                 shortcut: nil, symbol: line.style.symbol)
        case .note?, .noteCorner?:
            return QuickHelpItem(title: "Note", detail: "A note over the diagram: drag to move, drag its corner to resize, double-click to type; right-click for its colour. Exported as a DBML sticky note.",
                                 shortcut: nil, symbol: "note.text")
        case .panel(let name)?:
            return QuickHelpItem(title: "Schema \(name)", detail: "Click its name to select all its tables (drag to move them together); right-click to copy the schema or export it to a page of its own.",
                                 shortcut: nil, symbol: "square.dashed")
        case nil:
            return QuickHelpItem(title: "DBML Diagram", detail: "Click it to work on it (the DBML tab). Drag tables and notes (with Snap to Grid on they land on the page grid; ⌥ places freely). Double-click empty space for a note; right-click for a schema's Select / Copy / Export, Show DBML, Arrange Tables, line styles and zoom.",
                                 shortcut: nil, symbol: "cylinder.split.1x2")
        }
    }
}

// MARK: - Putting diagrams on the page

extension CanvasController {
    /// Insert ▸ DBML Diagram: a sample diagram with its DBML showing, to write your own.
    func insertDBML(source: String? = nil, title: String? = nil) {
        var d = source.map { DBMLData.fromFile($0, title: title) } ?? DBMLData.starter
        if source == nil { d.showsSource = true }
        insertDBML(data: d)
    }

    func insertDBML(data: DBMLData) {
        guard ref != nil else { return }
        let p = nextInsertionPoint()
        var element = PageElement(kind: .dbml, x: p.x, y: p.y, width: 1000)
        element.dbml = data
        guard let view = addElement(element) as? DBMLElementView else { return }
        undoManager?.setActionName("Insert DBML Diagram")
        DispatchQueue.main.async {
            view.activate()
            view.window?.makeFirstResponder(view.diagramCanvas)
        }
    }

    /// Insert ▸ DBML Diagram from File…
    func importDBMLFile() {
        guard ref != nil, let file = DBMLElementView.chooseDBML() else { return }
        insertDBML(source: file.source, title: file.name)
    }
}
