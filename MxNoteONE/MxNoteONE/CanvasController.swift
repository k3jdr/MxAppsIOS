//
//  CanvasController.swift
//  MxNoteONE
//
//  Loads a page into the canvas, saves it shortly after each change, and
//  carries out the canvas commands from the ribbon and menus: inserting
//  tables, pictures, attachments, recordings and screen clippings, page
//  colour and rule lines, zoom, ink, find on page, and undo for container
//  and ink changes. In export mode it builds a read-only canvas for PDF
//  export and printing.
//

import AppKit
import UniformTypeIdentifiers

/// An element on the pasteboard, with its picture or file data.
struct ClipboardElement: Codable {
    var element: PageElement
    var assetData: Data?
}

/// A lasso selection on the pasteboard: containers (with their pictures and files) and ink.
struct ClipboardSelection: Codable {
    static let type = NSPasteboard.PasteboardType("com.k3jdr.mxnoteone.selection")
    var page: UUID?
    var elements: [ClipboardElement]
    var strokes: [InkStroke]
}

final class CanvasController: NSObject {
    enum Mode { case live, export }

    let mode: Mode
    let scrollView = NSScrollView()
    let canvas: PageCanvasView
    private(set) var ref: PageRef?
    private(set) var content: PageContent?
    private var dirty = false
    private var saveTask: Task<Void, Never>?
    private var loadedToken = -1
    private var observers: [NSObjectProtocol] = []
    private var findMatches: [(TextElementView, NSRange)] = []
    private var findIndex = -1
    /// Removed containers stay alive until the next page loads, so undo can bring them back.
    private var graveyard: [ElementView] = []

    var store: NotebookStore { .shared }
    var editor: EditorState { store.editor }
    var undoManager: UndoManager? { canvas.window?.undoManager }

    init(mode: Mode = .live) {
        self.mode = mode
        canvas = PageCanvasView(frame: NSRect(x: 0, y: 0, width: 1000, height: 1200))
        super.init()
        canvas.controller = self
        guard mode == .live else { return }
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.25
        scrollView.maxMagnification = 4
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .white
        scrollView.contentView.postsFrameChangedNotifications = true
        scrollView.contentView.postsBoundsChangedNotifications = true

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView.contentView,
                                        queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.canvas.updateSize() }
        })
        observers.append(nc.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView,
                                        queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStickyHeaders() }
        })
        observers.append(nc.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification, object: scrollView,
                                        queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.editor.zoom = self.scrollView.magnification
                self.canvas.updateSize()
            }
        })
        for name in [NSApplication.willResignActiveNotification, NSApplication.willTerminateNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.flush() }
            })
        }
    }

    // MARK: - Loading and saving

    func load(_ newRef: PageRef?, token: Int) {
        if newRef == ref && token == loadedToken { return }
        flush()
        loadedToken = token
        ref = newRef
        clearFind()
        canvas.clear()
        graveyard.removeAll()
        undoManager?.removeAllActions()
        guard let newRef, let page = store.loadPage(newRef) else {
            content = nil
            canvas.showsPage = false
            return
        }
        content = page
        canvas.showsPage = true
        canvas.build(from: page)
        canvas.showDates(created: page.created, updated: store.meta(newRef)?.modified)
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        if store.focusTitleOnLoad {
            store.focusTitleOnLoad = false
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.canvas.titleField.focus()
            }
        }
        applyPendingFind()
        applyPendingReveal()
        updateStickyHeaders()
    }

    func loadForExport(_ page: PageContent, ref: PageRef) {
        self.ref = ref
        content = page
        canvas.showsPage = true
        canvas.build(from: page)
        canvas.showDates(created: page.created, updated: store.meta(ref)?.modified)
    }

    func markDirty() {
        guard mode == .live, ref != nil else { return }
        dirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Saves pending changes now.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        if dirty { saveNow() }
    }

    private func saveNow() {
        guard dirty, let ref, var content else { return }
        dirty = false
        content.title = canvas.titleField.stringValue
        content.elements = canvas.snapshotElements()
        content.strokes = canvas.inkView.strokes
        content.style = canvas.style
        self.content = content
        let index = PageIndexer.index(texts: canvas.indexTexts())
        store.savePage(content, ref: ref, plainText: index.text, tags: index.tags)
        // The header's "Updated" time moves on.
        canvas.showDates(created: content.created, updated: store.meta(ref)?.modified)
    }

    func titleChanged() {
        guard let ref else { return }
        store.setTitle(canvas.titleField.stringValue, for: ref)
        markDirty()
    }

    func textChanged() {
        if !findMatches.isEmpty { clearFind() }
        markDirty()
    }

    func assetData(_ name: String) -> Data? {
        guard let ref else { return nil }
        return store.assetData(name, for: ref)
    }

    // MARK: - Containers

    @discardableResult
    func addElement(_ element: PageElement, undoable: Bool = true) -> ElementView? {
        guard ref != nil, let view = canvas.makeView(for: element) else { return nil }
        canvas.addElementView(view)
        if undoable { registerRemovalUndo(view, actionName: "Insert") }
        markDirty()
        return view
    }

    /// Starts a new text container at the point (clicking an empty part of the page).
    @discardableResult
    func createTextElement(at point: NSPoint, text: NSAttributedString? = nil, width: CGFloat = 520) -> TextElementView? {
        var element = PageElement(kind: .text, x: max(4, canvas.snappedX(point.x - 8)),
                                  y: max(4, canvas.snappedY(point.y - ElementView.gripHeight - 10)), width: width)
        if let text { element.rtfd = NoteRichText.data(text) }
        guard let view = addElement(element, undoable: text != nil) as? TextElementView else { return nil }
        view.focus()
        return view
    }

    func insertTextBlock(_ string: String) {
        guard ref != nil else { return }
        if let view = createTextElement(at: nextInsertionPoint()) {
            view.textView.insertText(string, replacementRange: view.textView.selectedRange())
        }
    }

    func focusFirstText() {
        if let first = canvas.elementViews.compactMap({ $0 as? TextElementView })
            .min(by: { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }) {
            first.focus(atEnd: false)
        } else {
            createTextElement(at: NSPoint(x: PageCanvasView.margin + 8, y: PageCanvasView.contentTop + 20))
        }
    }

    /// Where inserted things go: where the page was right-clicked (Insert Here), under the container being edited,
    /// or near the top of the visible page.
    func nextInsertionPoint() -> NSPoint {
        canvas.snapped(insertionPoint ?? rawInsertionPoint())
    }

    /// Set while an Insert Here command runs (the point right-clicked).
    private var insertionPoint: NSPoint?

    /// Runs an insert command putting what it inserts at a point on the page.
    func insert(at point: NSPoint, _ command: () -> Void) {
        insertionPoint = point
        defer { insertionPoint = nil }
        command()
    }

    private func rawInsertionPoint() -> NSPoint {
        if let tv = NoteTextView.current, let owner = tv.owner, owner.superview === canvas {
            return NSPoint(x: owner.frame.minX, y: owner.frame.maxY + 14)
        }
        if let selected = canvas.selectedElement {
            return NSPoint(x: selected.frame.minX, y: selected.frame.maxY + 14)
        }
        let visible = scrollView.documentVisibleRect
        return NSPoint(x: max(PageCanvasView.margin, visible.minX + PageCanvasView.margin),
                       y: max(PageCanvasView.contentTop, visible.minY + 60))
    }

    func removeElement(_ view: ElementView, undoable: Bool = true) {
        guard view.superview === canvas else { return }
        let below = canvas.subviews.firstIndex(of: view).flatMap { i in
            i + 1 < canvas.subviews.count ? canvas.subviews[i + 1] : nil
        }
        if canvas.selectedElement === view { canvas.selectedElement = nil }
        view.removeFromSuperview()
        graveyard.append(view)
        if undoable {
            undoManager?.registerUndo(withTarget: self) { controller in
                controller.restoreElement(view, below: below)
            }
            undoManager?.setActionName("Delete")
        }
        canvas.updateSize()
        markDirty()
    }

    private func restoreElement(_ view: ElementView, below: NSView?) {
        if let below, below.superview === canvas {
            canvas.addSubview(view, positioned: .below, relativeTo: below)
        } else {
            canvas.addElementView(view)
        }
        graveyard.removeAll { $0 === view }
        registerRemovalUndo(view, actionName: "Delete")
        canvas.updateSize()
        markDirty()
    }

    private func registerRemovalUndo(_ view: ElementView, actionName: String) {
        undoManager?.registerUndo(withTarget: self) { controller in
            controller.removeElement(view)
        }
        undoManager?.setActionName(actionName)
    }

    func deleteSelectedElement() {
        if let selected = canvas.selectedElement { removeElement(selected) } else { NSSound.beep() }
    }

    /// Records a move or resize for undo.
    func elementFrameChanged(_ view: ElementView, from old: NSRect) {
        let new = view.frame
        guard old != new else { return }
        undoManager?.registerUndo(withTarget: self) { controller in
            view.applyFrame(old)
            controller.elementFrameChanged(view, from: new)
        }
        undoManager?.setActionName(old.size == new.size ? "Move" : "Resize")
        canvas.updateSize()
        markDirty()
    }

    /// A container grew or shrank: containers sitting just below it (and overlapping it horizontally) move with it.
    func pushElements(below view: ElementView, oldMaxY: CGFloat, delta: CGFloat) {
        guard abs(delta) > 0.5 else { return }
        var moved: Set<ObjectIdentifier> = [ObjectIdentifier(view)]
        var queue: [(ElementView, CGFloat)] = [(view, oldMaxY)]
        while let (source, bottom) = queue.first {
            queue.removeFirst()
            for other in canvas.elementViews where !moved.contains(ObjectIdentifier(other)) {
                let f = other.frame
                guard f.minY >= bottom - 1, f.minY <= bottom + 24,
                      f.maxX > source.frame.minX, f.minX < source.frame.maxX else { continue }
                moved.insert(ObjectIdentifier(other))
                other.setFrameOrigin(NSPoint(x: f.minX, y: max(0, f.minY + delta)))
                queue.append((other, f.maxY))
            }
        }
        if moved.count > 1 {
            canvas.updateSize()
            markDirty()
        }
    }

    /// OneNote-style: text followed by Tab turns the paragraph into a two-column table
    /// (the text goes in the first cell, the cursor in the second). Text after it moves below the table.
    func convertParagraphToTable(_ view: TextElementView, paragraph: NSRange) {
        let tv = view.textView
        guard let storage = tv.textStorage, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        let ns = storage.string as NSString
        var text = ns.substring(with: paragraph)
        if text.hasSuffix("\n") { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespaces)
        let font = storage.attribute(.font, at: paragraph.location, effectiveRange: nil) as? NSFont ?? Prefs.defaultFont
        let firstWidth = min(max(ceil((text as NSString).size(withAttributes: [.font: font]).width) + 28, 90), 360)
        var table = TableData(rows: 1, columns: 2)
        table.headerRow = false
        table.rows[0][0] = text
        table.columnWidths = [Double(firstWidth), 120]

        let glyphs = lm.glyphRange(forCharacterRange: paragraph, actualCharacterRange: nil)
        let rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
        let paragraphTop = view.frame.minY + ElementView.gripHeight + tv.textContainerOrigin.y + rect.minY
        let after = NSRange(location: NSMaxRange(paragraph), length: ns.length - NSMaxRange(paragraph))
        let trailing = after.length > 0 ? storage.attributedSubstring(from: after) : nil
        let x = view.frame.minX

        undoManager?.beginUndoGrouping()
        let tableY: CGFloat
        if paragraph.location == 0 && trailing == nil {
            tableY = view.frame.minY
            removeElement(view)
        } else {
            var cut = NSRange(location: paragraph.location, length: ns.length - paragraph.location)
            if cut.location > 0 {
                cut.location -= 1
                cut.length += 1
            }
            if paragraph.location == 0 {
                removeElement(view)
            } else if tv.shouldChangeText(in: cut, replacementString: "") {
                storage.replaceCharacters(in: cut, with: "")
                tv.didChangeText()
            }
            tableY = paragraphTop - ElementView.gripHeight + 2
        }
        var element = PageElement(kind: .table, x: x, y: max(0, tableY), width: Double(firstWidth) + 120)
        element.table = table
        let tableView = addElement(element) as? TableElementView
        if let trailing, let tableView {
            var rest = PageElement(kind: .text, x: x, y: tableView.frame.maxY + 14, width: view.frame.width)
            rest.rtfd = NoteRichText.data(trailing)
            addElement(rest)
        }
        undoManager?.endUndoGrouping()
        undoManager?.setActionName("Table")
        canvas.selectedElement = nil
        tableView?.beginEditing(CellRef(row: 0, column: 1))
    }

    func bringToFront(_ view: ElementView) {
        canvas.addSubview(view, positioned: .below, relativeTo: canvas.inkView)
        markDirty()
    }

    func sendToBack(_ view: ElementView) {
        canvas.addSubview(view, positioned: .above, relativeTo: canvas.dateLabel)
        markDirty()
    }

    // MARK: - Ink

    func strokesChanged(from old: [InkStroke]) {
        let new = canvas.inkView.strokes
        undoManager?.registerUndo(withTarget: self) { controller in
            controller.canvas.inkView.strokes = old
            controller.strokesChanged(from: new)
        }
        undoManager?.setActionName("Ink")
        canvas.updateSize()
        markDirty()
    }

    /// Records a lasso move (containers and strokes) as one undo step.
    func lassoMoved(frames: [(ElementView, NSRect)], oldStrokes: [InkStroke]) {
        let movedFrames = frames.filter { $0.0.frame != $0.1 }
        let strokesMoved = oldStrokes != canvas.inkView.strokes
        guard !movedFrames.isEmpty || strokesMoved else { return }
        undoManager?.beginUndoGrouping()
        for (view, old) in movedFrames { elementFrameChanged(view, from: old) }
        if strokesMoved { strokesChanged(from: oldStrokes) }
        undoManager?.endUndoGrouping()
        undoManager?.setActionName("Move")
        canvas.updateSize()
    }

    /// Delete: removes what the lasso selected (one undo step).
    func deleteLassoSelection() {
        let ink = canvas.inkView
        let views = ink.lassoElements
        let ids = ink.lassoStrokes
        let old = ink.strokes
        ink.clearLasso()
        undoManager?.beginUndoGrouping()
        for view in views { removeElement(view) }
        if !ids.isEmpty {
            ink.strokes.removeAll { ids.contains($0.id) }
            strokesChanged(from: old)
        }
        undoManager?.endUndoGrouping()
        undoManager?.setActionName("Delete")
    }

    // MARK: Lasso clipboard

    /// ⌘C with a lasso selection: the selection for MxNoteONE, plus its text and a picture of it for other apps.
    func copyLassoSelection() {
        guard let ref else { return }
        let ink = canvas.inkView
        let views = ink.lassoElements
        let strokes = ink.strokes.filter { ink.lassoStrokes.contains($0.id) }
        let clip = ClipboardSelection(page: ref.pageID, elements: views.map { view in
            let element = view.makeElement()
            return ClipboardElement(element: element, assetData: element.asset.flatMap { store.assetData($0, for: ref) })
        }, strokes: strokes)
        let item = NSPasteboardItem()
        if let data = try? JSONEncoder().encode(clip) { item.setData(data, forType: ClipboardSelection.type) }
        let text = views.sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
            .compactMap { $0.indexText() }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        if !text.isEmpty { item.setString(text, forType: .string) }
        if let png = selectionImage(views: views, strokes: strokes) { item.setData(png, forType: .png) }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([item])
        pasteCount = (pb.changeCount, 0)
    }

    /// A picture of the selected containers and ink (for pasting into other apps).
    private func selectionImage(views: [ElementView], strokes: [InkStroke]) -> Data? {
        let bounds = canvas.inkView.lassoBounds.insetBy(dx: -4, dy: -4).integral
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = bounds.size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        for view in views { view.isSelected = false }
        defer { for view in views { view.isSelected = true } }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let cg = context.cgContext
        NSColor.white.setFill()
        NSRect(origin: .zero, size: bounds.size).fill()
        // Flip to page coordinates (y down) with the selection's corner at the origin.
        cg.translateBy(x: 0, y: bounds.height)
        cg.scaleBy(x: 1, y: -1)
        cg.translateBy(x: -bounds.minX, y: -bounds.minY)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        for view in views {
            guard let snapshot = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: snapshot)
            snapshot.draw(in: view.frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        for stroke in strokes { InkView.draw(stroke, in: cg) }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// Repeated pastes of the same copy move down and right, so copies don't land on top of each other.
    private var pasteCount = (changeCount: -1, count: 0)

    /// ⌘V of a lasso selection: same layout, then selected (Lasso Select) so it can be moved right away.
    func pasteSelection(_ clip: ClipboardSelection) {
        guard let ref, !(clip.elements.isEmpty && clip.strokes.isEmpty) else { return }
        var bounds = InkView.bounds(of: clip.strokes)
        for item in clip.elements { bounds = bounds.union(item.element.frame) }
        let pb = NSPasteboard.general
        var dx: CGFloat = 0, dy: CGFloat = 0
        if clip.page == ref.pageID {
            pasteCount = (pb.changeCount, pasteCount.changeCount == pb.changeCount ? pasteCount.count + 1 : 1)
            dx = 20 * CGFloat(pasteCount.count)
            dy = 20 * CGFloat(pasteCount.count)
        } else {
            let visible = scrollView.documentVisibleRect
            if !visible.isEmpty, !visible.intersects(bounds) {
                dx = visible.minX + 40 - bounds.minX
                dy = max(PageCanvasView.contentTop, visible.minY + 40) - bounds.minY
            }
        }
        if canvas.snaps {
            let origin = canvas.snapped(CGPoint(x: bounds.minX + dx, y: bounds.minY + dy))
            dx = origin.x - bounds.minX
            dy = origin.y - bounds.minY
        }
        let ink = canvas.inkView
        editor.tool = .lasso
        undoManager?.beginUndoGrouping()
        var views: [ElementView] = []
        for item in clip.elements {
            var element = item.element
            element.id = UUID()
            element.x += dx
            element.y += dy
            if let data = item.assetData {
                element.asset = store.writeAsset(data, ext: ((item.element.asset ?? "") as NSString).pathExtension, for: ref)
            }
            if let view = addElement(element) { views.append(view) }
        }
        var strokeIDs: Set<UUID> = []
        if !clip.strokes.isEmpty {
            let old = ink.strokes
            let pasted = clip.strokes.map { stroke -> InkStroke in
                var copy = stroke
                copy.id = UUID()
                copy.points = stroke.points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
                return copy
            }
            strokeIDs = Set(pasted.map(\.id))
            ink.strokes += pasted
            strokesChanged(from: old)
        }
        undoManager?.endUndoGrouping()
        undoManager?.setActionName("Paste")
        canvas.window?.makeFirstResponder(canvas)
        ink.select(strokes: strokeIDs, elements: views)
        canvas.updateSize()
    }

    func clearInk() {
        let old = canvas.inkView.strokes
        guard !old.isEmpty else { return }
        canvas.inkView.strokes = []
        strokesChanged(from: old)
    }

    func toolChanged() {
        if editor.tool != .lasso { canvas.inkView.clearLasso() }
        canvas.window?.invalidateCursorRects(for: canvas.inkView)
        if editor.tool.isInk, let window = canvas.window, window.firstResponder is NSTextView {
            window.makeFirstResponder(canvas)
        }
    }

    // MARK: - Inserting

    /// Insert ▸ Music Score from MusicXML…: a score from a MuseScore / Finale / Sibelius / Dorico file.
    func chooseMusicXML() {
        guard ref != nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = MusicXML.fileTypes
        panel.allowsMultipleSelection = false
        panel.message = "Choose a MusicXML score (.musicxml, .mxl or .xml)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = importMusicXML(url)
    }

    @discardableResult
    func importMusicXML(_ url: URL, at point: NSPoint? = nil) -> ScoreElementView? {
        guard ref != nil else { return nil }
        do {
            let imported = try MusicXML.read(url)
            let p = point ?? nextInsertionPoint()
            var element = PageElement(kind: .score, x: p.x, y: p.y, width: 620)
            var score = imported.score
            if score.title.isEmpty { score.title = url.deletingPathExtension().lastPathComponent }
            element.score = score
            guard let view = addElement(element) as? ScoreElementView else { return nil }
            undoManager?.setActionName("Import MusicXML")
            if !imported.notes.isEmpty {
                store.showAlert("Imported “\(score.title)”", imported.notes.joined(separator: "\n"))
            }
            return view
        } catch {
            store.showAlert("Couldn't import \(url.lastPathComponent)", error.localizedDescription)
            return nil
        }
    }

    /// Insert ▸ Music Score: an empty treble staff in 4/4, ready for notes.
    func insertScore(piano: Bool = false, drums: Bool = false, leadSheet: Bool = false, chordChart: Bool = false) {
        guard ref != nil else { return }
        let p = nextInsertionPoint()
        var element = PageElement(kind: .score, x: p.x, y: p.y, width: 560)
        var score = ScoreData()
        if leadSheet || chordChart {
            // A lead sheet: title, composer, a style and tempo, four bars a line — melody, chord symbols and lyrics.
            score.title = chordChart ? "Chord Chart" : "Lead Sheet"
            score.composer = "Composer"
            score.barsPerLine = 4
            score.tempo = 120
            score.setMark(0) { $0.tempoText = "Medium Swing" }
            if chordChart {
                // Eight bars of beat slashes over a progression to start from (they play the chords).
                let middle = score.middleLine
                for (bar, chord) in ["C", "Am7", "Dm7", "G7", "C", "A7", "Dm7 G7", "C"].enumerated() {
                    let chords = chord.split(separator: " ").map(String.init)
                    for beat in 0..<4 {
                        var n = ScoreNote(duration: .quarter)
                        n.slash = "beat"
                        n.step = middle.step
                        n.octave = middle.octave
                        if beat == 0 { n.chordSymbol = chords[0] } else if beat == 2, chords.count > 1 { n.chordSymbol = chords[1] }
                        score.notes.append(n)
                    }
                    _ = bar
                }
            }
        }
        if drums {
            // A drum score: a percussion staff, eighth notes ready.
            score.clef = .percussion
            score.title = "Drums"
            ScoreView.inputDuration = .eighth
        }
        if piano {
            // A piano score: treble and bass staves joined by a brace.
            var bass = ScoreData()
            bass.clef = .bass
            score.setStaff(1, bass)
            score.grandStaff = true
        }
        element.score = score
        guard let view = addElement(element) as? ScoreElementView else { return }
        DispatchQueue.main.async { view.staff.activate() }
    }

    func insertTable(rows: Int, columns: Int) {
        guard ref != nil else { return }
        let p = nextInsertionPoint()
        let width = Double(min(max(columns * 130, 260), 780))
        var element = PageElement(kind: .table, x: p.x, y: p.y, width: width)
        element.table = TableData(rows: rows, columns: columns, width: width)
        addElement(element)
    }

    func insertImage(data: Data, ext: String, at point: NSPoint? = nil) {
        guard let ref, let image = NSImage(data: data), image.size.width > 0,
              let name = store.writeAsset(data, ext: ext, for: ref) else { return }
        let p = point ?? nextInsertionPoint()
        let width = min(max(image.size.width, 40), 640)
        let element = PageElement(kind: .image, x: p.x, y: p.y, width: width,
                                  height: ElementView.gripHeight + width * image.size.height / image.size.width,
                                  asset: name)
        addElement(element)
    }

    func insertImage(_ image: NSImage, at point: NSPoint? = nil) {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        insertImage(data: png, ext: "png", at: point)
    }

    func insertAttachment(data: Data, fileName: String, kind: PageElement.Kind, at point: NSPoint? = nil) {
        guard let ref, let name = store.writeAsset(data, ext: (fileName as NSString).pathExtension, for: ref) else { return }
        let p = point ?? nextInsertionPoint()
        let element = PageElement(kind: kind, x: p.x, y: p.y, width: 280, height: ElementView.gripHeight + 46,
                                  asset: name, fileName: fileName)
        addElement(element)
    }

    /// Dropped or chosen files: pictures go on the page, other files become attachments.
    func insertFiles(_ urls: [URL], at point: NSPoint? = nil) {
        var p = point ?? nextInsertionPoint()
        for url in urls {
            // MusicXML files come in as scores.
            if ["musicxml", "mxl"].contains(url.pathExtension.lowercased()), let view = importMusicXML(url, at: p) {
                p.y = view.frame.maxY + 14
                continue
            }
            // 3D models: STL and OBJ meshes; FreeCAD, STEP, IGES and BREP files (⌥ follows the file where it is).
            let ext3D = url.pathExtension.lowercased()
            if ["stl", "obj"].contains(ext3D), let view = insertModel(from: url) {
                p.y = view.frame.maxY + 14
                continue
            }
            if CADFreeCAD.importTypes.contains(ext3D) {
                insertFreeCAD(url, link: NSEvent.modifierFlags.contains(.option), at: p)
                p.y += 320
                continue
            }
            // draw.io diagrams (.drawio.svg, .drawio) come in as diagrams; ⌥ while dropping links the file instead.
            let lower = url.lastPathComponent.lowercased()
            if lower.hasSuffix(".drawio.svg") || lower.hasSuffix(".drawio"),
               let view = insertDiagram(from: url, link: NSEvent.modifierFlags.contains(.option), at: p) {
                p.y = view.frame.maxY + 14
                continue
            }
            guard let data = try? Data(contentsOf: url) else { continue }
            let type = UTType(filenameExtension: url.pathExtension)
            if type?.conforms(to: .image) == true, NSImage(data: data) != nil {
                insertImage(data: data, ext: url.pathExtension, at: p)
            } else if type?.conforms(to: .audio) == true {
                insertAttachment(data: data, fileName: url.lastPathComponent, kind: .audio, at: p)
            } else {
                insertAttachment(data: data, fileName: url.lastPathComponent, kind: .file, at: p)
            }
            p.y = (canvas.selectedElement?.frame.maxY ?? canvas.elementViews.last?.frame.maxY ?? p.y) + 14
        }
    }

    func choosePictures() {
        guard ref != nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        insertFiles(panel.urls)
    }

    func chooseAttachments() {
        guard ref != nil else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        insertFiles(panel.urls)
    }

    /// Hides the app, lets you drag a screen area, and puts the picture on the page.
    func screenClipping() {
        guard ref != nil else { return }
        let url = FileManager.default.temporaryDirectory.appending(path: "MxNoteONE-clip-\(UUID().uuidString).png")
        NSApp.hide(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", "-x", url.path]
            process.terminationHandler = { _ in
                DispatchQueue.main.async {
                    NSApp.unhide(nil)
                    NSApp.activate()
                    if let data = try? Data(contentsOf: url) {
                        self?.insertImage(data: data, ext: "png")
                        try? FileManager.default.removeItem(at: url)
                    }
                }
            }
            do {
                try process.run()
            } catch {
                NSApp.unhide(nil)
                self?.store.report("Screen clipping isn't available.", error)
            }
        }
    }

    // MARK: - Clipboard

    func copyElement(_ view: ElementView) {
        guard let ref else { return }
        let element = view.makeElement()
        let clip = ClipboardElement(element: element, assetData: element.asset.flatMap { store.assetData($0, for: ref) })
        let item = NSPasteboardItem()
        if let data = try? JSONEncoder().encode(clip) { item.setData(data, forType: PageCanvasView.elementType) }
        switch element.kind {
        case .text:
            if let storage = (view as? TextElementView)?.textView.textStorage {
                if let rtf = storage.rtf(from: NSRange(location: 0, length: storage.length), documentAttributes: [:]) {
                    item.setData(rtf, forType: .rtf)
                }
                item.setString(storage.string, forType: .string)
            }
        case .image:
            if let data = clip.assetData, let tiff = NSImage(data: data)?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        case .table:
            item.setString(element.table?.rows.map { $0.joined(separator: "\t") }.joined(separator: "\n") ?? "", forType: .string)
        case .file, .audio:
            item.setString(element.fileName ?? "", forType: .string)
        case .chart:
            if let tiff = (view as? ChartElementView)?.image()?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        case .score:
            if let tiff = (view as? ScoreElementView)?.image()?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        case .diagram:
            if let tiff = (view as? DiagramElementView)?.picture.image?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
            if let data = clip.assetData { item.setData(data, forType: NSPasteboard.PasteboardType("public.svg-image")) }
        case .model:
            if let tiff = (view as? CADElementView)?.image()?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        case .map:
            if let tiff = (view as? MapElementView)?.image()?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
            if let m = element.map { item.setString(m.pinLines(markdown: false).joined(separator: "\n"), forType: .string) }
        case .dbml:
            if let d = element.dbml {
                DBMLRenderer.add(d.diagram, to: item)
                item.setString(d.exportText, forType: .string)
            }
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([item])
    }

    /// Paste as Plain Text on the page: a new text box with the clipboard's text in the default style.
    func pastePlainText() {
        guard ref != nil, let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return NSSound.beep() }
        createTextElement(at: nextInsertionPoint(), text: NSAttributedString(string: text, attributes: TextFormatter.defaultAttributes))
    }

    func paste(at point: NSPoint? = nil) {
        guard let ref else { return }
        let pb = NSPasteboard.general
        if let data = pb.data(forType: ClipboardSelection.type),
           let clip = try? JSONDecoder().decode(ClipboardSelection.self, from: data) {
            return pasteSelection(clip)
        }
        let p = point ?? nextInsertionPoint()
        if let data = pb.data(forType: PageCanvasView.elementType),
           var clip = try? JSONDecoder().decode(ClipboardElement.self, from: data) {
            clip.element.id = UUID()
            clip.element.x = p.x
            clip.element.y = p.y
            if let assetData = clip.assetData {
                clip.element.asset = store.writeAsset(assetData, ext: ((clip.element.asset ?? "") as NSString).pathExtension, for: ref)
            }
            if let view = addElement(clip.element) { canvas.selectedElement = view }
            return
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            insertFiles(urls, at: p)
            return
        }
        // A copied link → a text box with the link (named after what it goes to).
        if let (url, title) = TextFormatter.clipboardLink() {
            var attrs = TextFormatter.defaultAttributes
            attrs[.link] = url
            createTextElement(at: p, text: NSAttributedString(string: title ?? url.absoluteString, attributes: attrs))
            return
        }
        // Cells from Excel, Numbers or a table (Excel also puts a picture of them on the clipboard) → a new table.
        if let cells = TableClipboard.readForPage() {
            pasteTable(cells, at: p)
            return
        }
        if pb.availableType(from: [.png, .tiff]) != nil, let image = NSImage(pasteboard: pb) {
            insertImage(image, at: p)
            return
        }
        if let text = (pb.readObjects(forClasses: [NSAttributedString.self]) as? [NSAttributedString])?.first, text.length > 0 {
            createTextElement(at: p, text: text)
        }
    }

    /// A new table from pasted cells, its columns fitted to their contents.
    func pasteTable(_ cells: PastedTable, at point: NSPoint) {
        var element = PageElement(kind: .table, x: point.x, y: point.y, width: CGFloat(cells.columnCount) * 120)
        element.table = TableClipboard.tableData(cells)
        guard let view = addElement(element) as? TableElementView else { return }
        view.grid.fitAllColumns()
        undoManager?.setActionName("Paste")
        canvas.selectedElement = view
    }

    // MARK: - Page style and zoom

    func setPageColor(_ color: PageColor) {
        guard ref != nil else { return }
        canvas.style.color = color
        markDirty()
    }

    func setRuleLines(_ rules: RuleLines) {
        guard ref != nil else { return }
        canvas.style.rules = rules
        markDirty()
    }

    func zoom(to magnification: CGFloat) {
        let m = min(max(magnification, scrollView.minMagnification), scrollView.maxMagnification)
        let visible = scrollView.documentVisibleRect
        scrollView.setMagnification(m, centeredAt: NSPoint(x: visible.midX, y: visible.minY))
        editor.zoom = m
        canvas.updateSize()
    }

    func zoomIn() { zoom(to: scrollView.magnification * 1.25) }
    func zoomOut() { zoom(to: scrollView.magnification / 1.25) }

    func zoomToPageWidth() {
        let width = canvas.contentBounds().maxX + PageCanvasView.margin
        zoom(to: scrollView.bounds.width / max(width, 300))
    }

    // MARK: - Find on page

    func updateFind() {
        clearFind()
        let query = editor.findText
        guard !query.isEmpty else {
            editor.findStatus = ""
            return
        }
        let views = canvas.elementViews.compactMap { $0 as? TextElementView }
            .sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
        let highlight = NSColor(srgbRed: 1, green: 0.85, blue: 0.2, alpha: 0.7)
        for view in views {
            let ns = view.textView.string as NSString
            var range = NSRange(location: 0, length: ns.length)
            while range.length > 0 {
                let found = ns.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: range)
                if found.location == NSNotFound { break }
                findMatches.append((view, found))
                view.textView.layoutManager?.addTemporaryAttribute(.backgroundColor, value: highlight, forCharacterRange: found)
                let next = NSMaxRange(found)
                range = NSRange(location: next, length: ns.length - next)
            }
        }
        editor.findStatus = findMatches.isEmpty ? "No matches" : "\(findMatches.count) match\(findMatches.count == 1 ? "" : "es")"
    }

    func findNext(forward: Bool = true) {
        if findMatches.isEmpty { updateFind() }
        guard !findMatches.isEmpty else {
            NSSound.beep()
            return
        }
        let n = findMatches.count
        findIndex = forward ? (findIndex + 1) % n : (findIndex - 1 + n) % n
        let (view, range) = findMatches[findIndex]
        view.textView.scrollRangeToVisible(range)
        view.textView.showFindIndicator(for: range)
        editor.findStatus = "\(findIndex + 1) of \(n)"
    }

    func clearFind() {
        for (view, _) in findMatches {
            let length = (view.textView.string as NSString).length
            view.textView.layoutManager?.removeTemporaryAttribute(.backgroundColor,
                                                                  forCharacterRange: NSRange(location: 0, length: length))
        }
        findMatches = []
        findIndex = -1
    }

    // MARK: - Arrow keys between containers

    /// ↑ on the first line / ↓ on the last line: continue into the text box or table directly above / below
    /// (as if the page's containers were one outline). Returns false when there's none.
    @discardableResult
    func moveFocus(from view: ElementView, up: Bool, x: CGFloat) -> Bool {
        let source = view.frame
        let candidates = canvas.elementViews.filter { other in
            guard other !== view, other is TextElementView || other is TableElementView else { return false }
            let f = other.frame
            guard f.maxX > source.minX - 40, f.minX < source.maxX + 40 else { return false }
            return up ? f.maxY <= source.minY + 4 : f.minY >= source.maxY - 4
        }
        let target = up ? candidates.max { $0.frame.maxY < $1.frame.maxY } : candidates.min { $0.frame.minY < $1.frame.minY }
        guard let target else { return false }
        if let text = target as? TextElementView {
            text.focus(lastLine: up, pageX: x)
        } else if let table = target as? TableElementView {
            table.grid.enter(fromAbove: !up, pageX: x)
        }
        return true
    }

    // MARK: - Frozen header rows

    /// Tables whose header row has scrolled above the visible area keep it pinned at the top of the view.
    func updateStickyHeaders() {
        guard mode == .live else { return }
        let visible = scrollView.documentVisibleRect
        for view in canvas.elementViews {
            (view as? TableElementView)?.updateStickyHeader(visible: visible)
        }
    }

    // MARK: - Paragraph links

    /// Shows the paragraph a link points to: scrolls to it and selects it.
    func applyPendingReveal() {
        guard let target = store.pendingReveal, ref != nil, ref == store.currentPageRef else { return }
        store.pendingReveal = nil
        // A pin: its map scrolled to, the pin centred and its callout open (any map with it, if the map was replaced).
        if let pin = target.pin {
            let maps = canvas.elementViews.compactMap { $0 as? MapElementView }
            if let map = maps.first(where: { $0.element.id == target.element && $0.data.pins.contains { $0.id == pin } })
                ?? maps.first(where: { $0.data.pins.contains { $0.id == pin } }) {
                map.reveal(pin)
            } else {
                NSSound.beep()
            }
            return
        }
        if let table = canvas.elementViews.first(where: { $0.element.id == target.element }) as? TableElementView,
           let cell = target.cell {
            table.grid.reveal(cell)
            return
        }
        let texts = canvas.elementViews.compactMap { $0 as? TextElementView }
        if let view = texts.first(where: { $0.element.id == target.element }),
           let range = paragraphRange(in: view.textView.string, index: target.paragraph, matching: target.text) {
            return select(range, in: view)
        }
        // The paragraph moved or its container was replaced: look for its words.
        guard !target.text.isEmpty else { return }
        for view in texts {
            let ns = view.textView.string as NSString
            let found = ns.range(of: target.text)
            if found.location != NSNotFound {
                return select(ns.paragraphRange(for: found), in: view)
            }
        }
    }

    /// The paragraph at a position, or the one starting with the given words.
    private func paragraphRange(in text: String, index: Int, matching words: String) -> NSRange? {
        let ns = text as NSString
        var paragraphs: [NSRange] = []
        var location = 0
        while location < ns.length {
            let range = ns.paragraphRange(for: NSRange(location: location, length: 0))
            paragraphs.append(range)
            location = NSMaxRange(range)
        }
        let matches: (NSRange) -> Bool = { range in
            words.isEmpty || ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(words)
        }
        if paragraphs.indices.contains(index), matches(paragraphs[index]) { return paragraphs[index] }
        return paragraphs.first(where: matches) ?? (paragraphs.indices.contains(index) ? paragraphs[index] : nil)
    }

    private func select(_ range: NSRange, in view: TextElementView) {
        var range = range
        let ns = view.textView.string as NSString
        while range.length > 0, ns.character(at: NSMaxRange(range) - 1) == 0x0A { range.length -= 1 }
        view.window?.makeFirstResponder(view.textView)
        view.textView.setSelectedRange(range)
        view.textView.scrollRangeToVisible(range)
        view.textView.showFindIndicator(for: range)
    }

    func applyPendingFind() {
        guard let query = store.pendingFind, ref != nil, ref == store.currentPageRef else { return }
        store.pendingFind = nil
        editor.findText = query
        editor.showFindBar = true
        updateFind()
        if !findMatches.isEmpty { findNext() }
    }
}
