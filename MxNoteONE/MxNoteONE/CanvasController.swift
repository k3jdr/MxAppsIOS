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
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        if store.focusTitleOnLoad {
            store.focusTitleOnLoad = false
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.canvas.window?.makeFirstResponder(self.canvas.titleField)
            }
        }
        applyPendingFind()
    }

    func loadForExport(_ page: PageContent, ref: PageRef) {
        self.ref = ref
        content = page
        canvas.showsPage = true
        canvas.build(from: page)
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
        var element = PageElement(kind: .text, x: max(4, point.x - 8), y: max(4, point.y - ElementView.gripHeight - 10),
                                  width: width)
        if let text { element.rtfd = text.rtfd(from: NSRange(location: 0, length: text.length), documentAttributes: [:]) }
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

    /// Where inserted things go: under the container being edited, or near the top of the visible page.
    func nextInsertionPoint() -> NSPoint {
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

    func clearInk() {
        let old = canvas.inkView.strokes
        guard !old.isEmpty else { return }
        canvas.inkView.strokes = []
        strokesChanged(from: old)
    }

    func toolChanged() {
        canvas.window?.invalidateCursorRects(for: canvas.inkView)
        if editor.tool.isInk, let window = canvas.window, window.firstResponder is NSTextView {
            window.makeFirstResponder(canvas)
        }
    }

    // MARK: - Inserting

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
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([item])
    }

    func paste(at point: NSPoint? = nil) {
        guard let ref else { return }
        let pb = NSPasteboard.general
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
        if pb.availableType(from: [.png, .tiff]) != nil, let image = NSImage(pasteboard: pb) {
            insertImage(image, at: p)
            return
        }
        if let text = (pb.readObjects(forClasses: [NSAttributedString.self]) as? [NSAttributedString])?.first, text.length > 0 {
            createTextElement(at: p, text: text)
        }
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

    func applyPendingFind() {
        guard let query = store.pendingFind, ref != nil, ref == store.currentPageRef else { return }
        store.pendingFind = nil
        editor.findText = query
        editor.showFindBar = true
        updateFind()
        if !findMatches.isEmpty { findNext() }
    }
}
