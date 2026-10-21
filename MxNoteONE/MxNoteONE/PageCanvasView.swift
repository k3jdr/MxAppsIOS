//
//  PageCanvasView.swift
//  MxNoteONE
//
//  The page: title and date at the top, containers placed anywhere, and an
//  ink layer on top. Click an empty spot to start typing there, drag a
//  container by its top bar, resize it from its right edge. The page is
//  always drawn as light paper, whatever the system appearance.
//

import AppKit

/// The page title: a one-line text view in a scroll view without scroll bars. Shown and edited with the same text
/// engine, so the title never clips tall letters or jumps when you click into it; long titles scroll sideways.
final class TitleView: NSScrollView, NSTextViewDelegate {
    final class Editor: NSTextView {
        var placeholder = "Page Title"

        // Outside the title, the pointer isn't the title's to set (the window sends it every move while typing).
        override func mouseMoved(with event: NSEvent) { if pointerInside(event) { super.mouseMoved(with: event) } }
        override func cursorUpdate(with event: NSEvent) { if pointerInside(event) { super.cursorUpdate(with: event) } }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard string.isEmpty, let font else { return }
            NSAttributedString(string: placeholder, attributes: [.font: font, .foregroundColor: NSColor(white: 0.7, alpha: 1)])
                .draw(at: NSPoint(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0), y: textContainerOrigin.y))
        }
    }

    let editor = Editor(usingTextLayoutManager: false)
    /// Typing changed the title.
    var onChange: (() -> Void)?
    /// Return or Tab in the title (go to the page content).
    var onCommit: (() -> Void)?

    init(frame: NSRect, font: NSFont) {
        super.init(frame: frame)
        drawsBackground = false
        hasVerticalScroller = false
        hasHorizontalScroller = false
        verticalScrollElasticity = .none
        horizontalScrollElasticity = .none
        borderType = .noBorder
        editor.font = font
        editor.textColor = .black
        editor.insertionPointColor = .black
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isContinuousSpellCheckingEnabled = true
        editor.drawsBackground = false
        editor.isHorizontallyResizable = true
        editor.isVerticallyResizable = false
        editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: frame.height)
        editor.textContainer?.lineFragmentPadding = 2
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: frame.height)
        let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: font))
        editor.textContainerInset = NSSize(width: 0, height: max(0, floor((frame.height - lineHeight) / 2)))
        editor.frame = NSRect(x: 0, y: 0, width: frame.width, height: frame.height)
        editor.minSize = NSSize(width: frame.width, height: frame.height)
        editor.delegate = self
        documentView = editor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var stringValue: String {
        get { editor.string }
        set {
            editor.string = newValue.replacingOccurrences(of: "\n", with: " ")
            editor.undoManager?.removeAllActions(withTarget: editor)
            editor.scroll(.zero)
            editor.needsDisplay = true
        }
    }

    var font: NSFont? { editor.font }

    var placeholderString: String {
        get { editor.placeholder }
        set { editor.placeholder = newValue }
    }

    func focus() {
        window?.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
    }

    func textDidChange(_ notification: Notification) {
        if editor.string.contains("\n") {
            editor.string = editor.string.replacingOccurrences(of: "\n", with: " ")
        }
        editor.needsDisplay = true
        onChange?()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), #selector(NSResponder.insertLineBreak(_:)):
            onCommit?()
            return true
        default:
            return false
        }
    }
}

final class PageCanvasView: NSView {
    static let margin: CGFloat = 48
    static let contentTop: CGFloat = 110
    static let titleWidth: CGFloat = 640
    static let elementType = NSPasteboard.PasteboardType("com.k3jdr.mxnoteone.element")

    weak var controller: CanvasController?
    var style = PageStyle() {
        didSet { needsDisplay = true }
    }
    var showsPage = false {
        didSet {
            titleField.isHidden = !showsPage
            dateLabel.isHidden = !showsPage
            needsDisplay = true
        }
    }
    let titleField = TitleView(frame: NSRect(x: PageCanvasView.margin - 2, y: 20, width: PageCanvasView.titleWidth, height: 48),
                               font: NSFont(name: "HelveticaNeue-Light", size: 26) ?? .systemFont(ofSize: 26, weight: .light))
    let dateLabel = NSTextField(labelWithString: "")
    let inkView = InkView()
    var selectedElement: ElementView? {
        didSet {
            if oldValue !== selectedElement { oldValue?.isSelected = false }
            selectedElement?.isSelected = true
        }
    }

    var isExport: Bool { controller?.mode == .export }

    // MARK: Snap to grid

    /// Grid step: the page's rule lines or grid, else 12 points.
    var gridStep: CGFloat { style.rules.spacing ?? 12 }

    /// Lined paper starts its lines under the title; grids start at the top.
    private var gridOriginY: CGFloat { style.rules.spacing != nil && !style.rules.isGrid ? Self.contentTop : 0 }

    /// Snapping is on (View ▸ Snap to Grid) and ⌥ isn't held.
    var snaps: Bool {
        !isExport && (controller?.editor.snapToGrid ?? false) && !NSEvent.modifierFlags.contains(.option)
    }

    /// Shows the grid while something is dragged with snapping on and the page has no rule lines.
    var showsSnapGuides = false {
        didSet { if oldValue != showsSnapGuides { needsDisplay = true } }
    }

    func snappedX(_ x: CGFloat) -> CGFloat {
        snaps ? (x / gridStep).rounded() * gridStep : x
    }

    func snappedY(_ y: CGFloat) -> CGFloat {
        snaps ? ((y - gridOriginY) / gridStep).rounded() * gridStep + gridOriginY : y
    }

    func snapped(_ point: NSPoint) -> NSPoint {
        NSPoint(x: snappedX(point.x), y: snappedY(point.y))
    }
    var elementViews: [ElementView] { subviews.compactMap { $0 as? ElementView } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: .aqua)

        titleField.placeholderString = "Page Title"
        titleField.onChange = { [weak self] in self?.controller?.titleChanged() }
        titleField.onCommit = { [weak self] in self?.controller?.focusFirstText() }

        dateLabel.font = .systemFont(ofSize: 12)
        dateLabel.textColor = NSColor(white: 0.45, alpha: 1)
        dateLabel.frame = NSRect(x: Self.margin + 2, y: 74, width: 480, height: 18)

        addSubview(titleField)
        addSubview(dateLabel)
        inkView.canvas = self
        inkView.frame = bounds
        addSubview(inkView)
        registerForDraggedTypes([.fileURL, .png, .tiff])
        showsPage = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: Building

    func build(from page: PageContent) {
        style = page.style
        titleField.stringValue = page.title
        showDates(created: page.created, updated: nil)
        for element in page.elements {
            guard let view = makeView(for: element) else { continue }
            // A text box left with nothing in it isn't kept (it would only show as a frame under the pointer).
            if let text = view as? TextElementView, text.isBlank { continue }
            addElementView(view)
        }
        inkView.strokes = page.strokes
        // Printing draws the title itself (an NSTextField clips its glyphs when printed).
        if isExport { titleField.isHidden = true }
        updateSize()
    }

    /// A date as the page header shows it: Thursday, October 15, 2026      9:12 PM
    static func headerDate(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).month(.wide).day().year()) + "      " + date.formatted(date: .omitted, time: .shortened)
    }

    /// Under the title: when the page was created, and to its right when it was last updated.
    func showDates(created: Date, updated: Date?) {
        let gray = NSColor(white: 0.45, alpha: 1)
        let font = NSFont.systemFont(ofSize: 12)
        let text = NSMutableAttributedString(string: Self.headerDate(created), attributes: [.font: font, .foregroundColor: gray])
        var tip = "Created " + Self.headerDate(created).replacingOccurrences(of: "      ", with: " at ")
        if let updated {
            text.append(NSAttributedString(string: "     │     ", attributes: [.font: font, .foregroundColor: NSColor(white: 0.72, alpha: 1)]))
            text.append(NSAttributedString(string: "Updated  ", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: gray]))
            text.append(NSAttributedString(string: Self.headerDate(updated), attributes: [.font: font, .foregroundColor: gray]))
            tip += "\nLast updated " + Self.headerDate(updated).replacingOccurrences(of: "      ", with: " at ")
        }
        dateLabel.attributedStringValue = text
        dateLabel.toolTip = tip
        dateLabel.sizeToFit()
        dateLabel.frame.size.height = 18
    }

    func makeView(for element: PageElement) -> ElementView? {
        let view: ElementView
        switch element.kind {
        case .text:
            view = TextElementView(element: element)
        case .image:
            let image = element.asset.flatMap { controller?.assetData($0) }.flatMap(NSImage.init(data:))
            view = ImageElementView(element: element, image: image)
        case .file, .audio:
            view = FileElementView(element: element)
        case .table:
            view = TableElementView(element: element)
        case .chart:
            view = ChartElementView(element: element)
        case .score:
            view = ScoreElementView(element: element)
        case .diagram:
            let data = (element.preview ?? element.asset).flatMap { controller?.assetData($0) }
            view = DiagramElementView(element: element, image: data.flatMap(NSImage.init(data:)))
        case .model:
            view = CADElementView(element: element)
        case .map:
            view = MapElementView(element: element)
        case .dbml:
            view = DBMLElementView(element: element)
        }
        view.canvas = self
        if isExport { view.prepareForExport() }
        return view
    }

    func addElementView(_ view: ElementView) {
        view.canvas = self
        addSubview(view, positioned: .below, relativeTo: inkView)
        updateSize()
    }

    func clear() {
        for view in elementViews { view.removeFromSuperview() }
        inkView.strokes = []
        inkView.clearLasso()
        selectedElement = nil
        titleField.stringValue = ""
    }

    /// The containers to keep (a text box with nothing typed in it isn't one).
    func snapshotElements() -> [PageElement] {
        elementViews.filter { !(($0 as? TextElementView)?.isBlank ?? false) }.map { $0.makeElement() }
    }

    /// Text of every container, for search and tags.
    func indexTexts() -> [String] {
        elementViews.compactMap { $0.indexText() }
    }

    // MARK: Size

    func contentBounds() -> NSRect {
        var rect = NSRect(x: 0, y: 0, width: Self.margin + Self.titleWidth, height: Self.contentTop)
        for view in elementViews { rect = rect.union(view.frame) }
        let ink = InkView.bounds(of: inkView.strokes)
        if !ink.isNull { rect = rect.union(ink) }
        return rect
    }

    func updateSize() {
        let content = contentBounds()
        var size: NSSize
        if isExport {
            size = NSSize(width: max(content.maxX + 40, 760), height: content.maxY + 48)
        } else {
            var width = content.maxX + 320
            var height = content.maxY + 480
            if let clip = enclosingScrollView?.contentView {
                width = max(width, clip.bounds.width)
                height = max(height, clip.bounds.height)
            }
            size = NSSize(width: max(width, 900), height: max(height, 1000))
        }
        size.width = ceil(size.width)
        size.height = ceil(size.height)
        if frame.size != size { setFrameSize(size) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        inkView.frame = bounds
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        style.color.nsColor.setFill()
        dirtyRect.fill()
        guard showsPage else { return }

        if let spacing = style.rules.spacing {
            let path = NSBezierPath()
            path.lineWidth = 0.6
            let firstY = style.rules.isGrid ? 0 : Self.contentTop
            var y = max(firstY, floor(dirtyRect.minY / spacing) * spacing)
            while y <= dirtyRect.maxY {
                if y >= firstY {
                    path.move(to: NSPoint(x: dirtyRect.minX, y: y + 0.5))
                    path.line(to: NSPoint(x: dirtyRect.maxX, y: y + 0.5))
                }
                y += spacing
            }
            if style.rules.isGrid {
                var x = floor(dirtyRect.minX / spacing) * spacing
                while x <= dirtyRect.maxX {
                    path.move(to: NSPoint(x: x + 0.5, y: dirtyRect.minY))
                    path.line(to: NSPoint(x: x + 0.5, y: dirtyRect.maxY))
                    x += spacing
                }
                NSColor(srgbRed: 0.45, green: 0.62, blue: 0.85, alpha: 0.28).setStroke()
            } else {
                NSColor(srgbRed: 0.45, green: 0.62, blue: 0.85, alpha: 0.45).setStroke()
            }
            path.stroke()
            if !style.rules.isGrid {
                let margin = NSBezierPath()
                margin.lineWidth = 0.8
                margin.move(to: NSPoint(x: 36.5, y: max(dirtyRect.minY, Self.contentTop - 10)))
                margin.line(to: NSPoint(x: 36.5, y: dirtyRect.maxY))
                NSColor(srgbRed: 0.90, green: 0.45, blue: 0.45, alpha: 0.6).setStroke()
                margin.stroke()
            }
        }

        if isExport {
            let title = NSAttributedString(string: titleField.stringValue, attributes: [
                .font: titleField.font ?? NSFont.systemFont(ofSize: 26), .foregroundColor: NSColor.black,
            ])
            title.draw(with: NSRect(x: Self.margin, y: 26, width: Self.titleWidth, height: 40),
                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }

        if showsSnapGuides, style.rules.spacing == nil {
            let step = gridStep
            NSColor(srgbRed: 0.45, green: 0.62, blue: 0.85, alpha: 0.45).setFill()
            var y = floor(dirtyRect.minY / step) * step
            while y <= dirtyRect.maxY {
                var x = floor(dirtyRect.minX / step) * step
                while x <= dirtyRect.maxX {
                    NSRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5).fill()
                    x += step
                }
                y += step
            }
        }

        let underline = NSBezierPath()
        underline.lineWidth = 1
        underline.move(to: NSPoint(x: Self.margin, y: 69.5))
        underline.line(to: NSPoint(x: Self.margin + Self.titleWidth, y: 69.5))
        NSColor(white: 0.72, alpha: 1).setStroke()
        underline.stroke()
    }

    // MARK: Mouse and keys

    override func mouseDown(with event: NSEvent) {
        guard showsPage, !isExport, let controller else { return }
        let p = convert(event.locationInWindow, from: nil)
        selectedElement = nil
        window?.makeFirstResponder(self)
        // A new text box where the page is clicked (or double-clicked; or not at all — Settings ▸ General ▸ Page).
        let starts: Bool
        switch Prefs.newTextBox {
        case .click: starts = true
        case .doubleClick: starts = event.clickCount >= 2
        case .menu: starts = false
        }
        if starts, controller.editor.tool == .type, p.y > Self.contentTop - 24 {
            controller.createTextElement(at: p)
        }
    }

    /// Right-click on the page: a new text box (or anything else) there, paste there, and what clicks do.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard showsPage, !isExport, let controller else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        guard p.y > Self.contentTop - 24 else { return nil }
        window?.makeFirstResponder(self)
        selectedElement = nil
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("New Text Box Here") { [weak controller] in controller?.createTextElement(at: p) })
        let paste = ClosureMenuItem("Paste Here") { [weak controller] in controller?.paste(at: p) }
        paste.isEnabled = !(NSPasteboard.general.types ?? []).isEmpty
        menu.addItem(paste)
        let insert = NSMenuItem(title: "Insert Here", action: nil, keyEquivalent: "")
        let im = NSMenu()
        func here(_ title: String, _ symbol: String, _ command: @escaping (CanvasController) -> Void) {
            let item = ClosureMenuItem(title) { [weak controller] in
                guard let controller else { return }
                controller.insert(at: p) { command(controller) }
            }
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            im.addItem(item)
        }
        here("Table", "tablecells") { $0.insertTable(rows: 3, columns: 3) }
        here("Picture…", "photo") { $0.choosePictures() }
        here("File Attachment…", "paperclip") { $0.chooseAttachments() }
        im.addItem(.separator())
        here("Map", "map") { $0.insertMap() }
        here("DBML Diagram", "cylinder.split.1x2") { $0.insertDBML() }
        here("Music Score", "music.note.list") { $0.insertScore() }
        here("3D Model", "cube") { $0.insertModel() }
        here("Diagram (draw.io)", "point.3.connected.trianglepath.dotted") { $0.newDiagram() }
        insert.submenu = im
        menu.addItem(insert)
        menu.addItem(.separator())
        let clicks = NSMenuItem(title: "Clicking the Page", action: nil, keyEquivalent: "")
        let cm = NSMenu()
        for option in Prefs.NewTextBox.allCases {
            cm.addItem(ClosureMenuItem(option.menuTitle, state: Prefs.newTextBox == option) { Prefs.newTextBox = option })
        }
        clicks.submenu = cm
        menu.addItem(clicks)
        return menu
    }

    override func keyDown(with event: NSEvent) {
        guard let controller else { return super.keyDown(with: event) }
        if inkView.hasLassoSelection {
            let step: CGFloat = snaps ? gridStep : (event.modifierFlags.contains(.shift) ? 10 : 1)
            switch event.keyCode {
            case 51, 117:
                controller.deleteLassoSelection()
                return
            case 53:
                inkView.clearLasso()
                return
            case 123: return inkView.nudgeLasso(dx: -step, dy: 0)
            case 124: return inkView.nudgeLasso(dx: step, dy: 0)
            case 125: return inkView.nudgeLasso(dx: 0, dy: step)
            case 126: return inkView.nudgeLasso(dx: 0, dy: -step)
            default: break
            }
        }
        if event.keyCode == 53 {
            controller.editor.tool = .type
            selectedElement = nil
            return
        }
        if let selected = selectedElement {
            let step: CGFloat = snaps ? gridStep : (event.modifierFlags.contains(.shift) ? 10 : 1)
            var delta = NSPoint.zero
            switch event.keyCode {
            case 51, 117:
                controller.removeElement(selected)
                return
            case 36, 76:
                (selected as? TextElementView)?.focus()
                return
            case 123: delta.x = -step
            case 124: delta.x = step
            case 125: delta.y = step
            case 126: delta.y = -step
            default: break
            }
            if delta != .zero {
                let old = selected.frame
                let target = snapped(NSPoint(x: old.minX + delta.x, y: old.minY + delta.y))
                selected.setFrameOrigin(NSPoint(x: max(0, target.x), y: max(0, target.y)))
                controller.elementFrameChanged(selected, from: old)
                return
            }
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        controller?.editor.tool = .type
        selectedElement = nil
    }

    @objc func copy(_ sender: Any?) {
        if inkView.hasLassoSelection { return controller?.copyLassoSelection() ?? () }
        guard let selected = selectedElement else { return NSSound.beep() }
        controller?.copyElement(selected)
    }

    @objc func cut(_ sender: Any?) {
        if inkView.hasLassoSelection {
            controller?.copyLassoSelection()
            controller?.deleteLassoSelection()
            controller?.undoManager?.setActionName("Cut")
            return
        }
        guard let selected = selectedElement else { return NSSound.beep() }
        controller?.copyElement(selected)
        controller?.removeElement(selected)
        controller?.undoManager?.setActionName("Cut")
    }

    @objc func paste(_ sender: Any?) {
        controller?.paste()
    }

    @objc func delete(_ sender: Any?) {
        if inkView.hasLassoSelection { return controller?.deleteLassoSelection() ?? () }
        controller?.deleteSelectedElement()
    }

    // MARK: Drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        showsPage && !isExport ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let controller else { return false }
        let p = convert(sender.draggingLocation, from: nil)
        let pb = sender.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            controller.insertFiles(urls, at: p)
            return true
        }
        if let image = NSImage(pasteboard: pb) {
            controller.insertImage(image, at: p)
            return true
        }
        return false
    }

}

// MARK: - Ink layer

/// Pen and highlighter strokes, lines, arrows, rectangles and ellipses, drawn over the page.
final class InkView: NSView {
    weak var canvas: PageCanvasView?
    var strokes: [InkStroke] = [] {
        didSet { needsDisplay = true }
    }
    private var current: InkStroke?
    private var strokesBeforeErasing: [InkStroke]?

    // Lasso selection.
    private(set) var lassoStrokes: Set<UUID> = []
    private(set) var lassoElements: [ElementView] = []
    private var lassoPath: [CGPoint] = []
    private var lassoMove: (start: CGPoint, bounds: CGRect, strokes: [InkStroke], frames: [(ElementView, NSRect)])?

    var hasLassoSelection: Bool { !lassoStrokes.isEmpty || !lassoElements.isEmpty }

    /// Everything the lasso selected.
    var lassoBounds: CGRect {
        var rect = CGRect.null
        for stroke in strokes where lassoStrokes.contains(stroke.id) {
            rect = rect.union(Self.path(for: stroke).boundingBoxOfPath.insetBy(dx: -stroke.width / 2, dy: -stroke.width / 2))
        }
        for view in lassoElements where view.superview != nil { rect = rect.union(view.frame) }
        return rect
    }

    /// Selects the given strokes and containers (after a paste).
    func select(strokes ids: Set<UUID>, elements: [ElementView]) {
        clearLasso()
        lassoStrokes = ids
        lassoElements = elements
        for view in elements { view.isSelected = true }
        needsDisplay = true
    }

    func clearLasso() {
        for view in lassoElements { view.isSelected = canvas?.selectedElement === view }
        lassoElements = []
        lassoStrokes = []
        lassoPath = []
        lassoMove = nil
        needsDisplay = true
    }

    /// Selects strokes mostly inside the loop and containers whose middle (and half their corners) are inside it.
    private func finishLasso() {
        defer {
            lassoPath = []
            needsDisplay = true
        }
        guard lassoPath.count > 2 else { return clearLasso() }
        let loop = CGMutablePath()
        loop.addLines(between: lassoPath)
        loop.closeSubpath()
        lassoStrokes = Set(strokes.filter { stroke in
            let inside = stroke.points.filter { loop.contains($0) }.count
            return Double(inside) >= Double(stroke.points.count) * 0.8
        }.map(\.id))
        lassoElements = (canvas?.elementViews ?? []).filter { view in
            let f = view.frame
            let corners = [CGPoint(x: f.minX, y: f.minY), CGPoint(x: f.maxX, y: f.minY),
                           CGPoint(x: f.minX, y: f.maxY), CGPoint(x: f.maxX, y: f.maxY)]
            return loop.contains(CGPoint(x: f.midX, y: f.midY)) && corners.filter { loop.contains($0) }.count >= 2
        }
        for view in lassoElements { view.isSelected = true }
    }

    /// Moves the lasso selection (from where it was when the move started).
    private func moveLasso(from move: (start: CGPoint, bounds: CGRect, strokes: [InkStroke], frames: [(ElementView, NSRect)]),
                           dx rawX: CGFloat, dy rawY: CGFloat) {
        var dx = rawX, dy = rawY
        if let canvas, canvas.snaps {
            let origin = canvas.snapped(CGPoint(x: move.bounds.minX + dx, y: move.bounds.minY + dy))
            dx = origin.x - move.bounds.minX
            dy = origin.y - move.bounds.minY
        }
        dx = max(dx, -move.bounds.minX)
        dy = max(dy, -move.bounds.minY)
        strokes = move.strokes.map { stroke in
            guard lassoStrokes.contains(stroke.id) else { return stroke }
            var moved = stroke
            moved.points = stroke.points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
            return moved
        }
        for (view, frame) in move.frames { view.setFrameOrigin(NSPoint(x: frame.minX + dx, y: frame.minY + dy)) }
    }

    /// Arrow keys: nudge the lasso selection.
    func nudgeLasso(dx: CGFloat, dy: CGFloat) {
        let move = (start: CGPoint.zero, bounds: lassoBounds, strokes: strokes, frames: lassoElements.map { ($0, $0.frame) })
        moveLasso(from: move, dx: dx, dy: dy)
        canvas?.controller?.lassoMoved(frames: move.frames, oldStrokes: move.strokes)
    }

    private var tool: CanvasTool { NotebookStore.shared.editor.tool }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let canvas, !canvas.isExport, canvas.showsPage, tool.isInk else { return nil }
        return super.hitTest(point)
    }

    private static let eraserCursor: NSCursor = {
        let size: CGFloat = 18
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor.white.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
            NSColor.black.setStroke()
            NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: size / 2, y: size / 2))
    }()

    override func resetCursorRects() {
        guard tool.isInk else { return }
        addCursorRect(bounds, cursor: tool == .eraser ? Self.eraserCursor : .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(canvas)
        canvas?.selectedElement = nil
        let p = convert(event.locationInWindow, from: nil)
        let editor = NotebookStore.shared.editor
        if tool == .eraser {
            strokesBeforeErasing = strokes
            erase(at: p)
            return
        }
        if tool == .lasso {
            if hasLassoSelection, lassoBounds.insetBy(dx: -6, dy: -6).contains(p) {
                lassoMove = (p, lassoBounds, strokes, lassoElements.map { ($0, $0.frame) })
            } else {
                clearLasso()
                lassoPath = [p]
            }
            return
        }
        guard let kind = tool.strokeTool else { return }
        let highlighter = kind == .highlighter
        let isShape = kind != .pen && kind != .highlighter
        current = InkStroke(tool: kind, color: highlighter ? editor.highlighterColor : editor.penColor,
                            width: highlighter ? editor.highlighterWidth : editor.penWidth,
                            points: [isShape ? (canvas?.snapped(p) ?? p) : p])
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if tool == .eraser {
            erase(at: p)
            return
        }
        if tool == .lasso {
            if let move = lassoMove {
                moveLasso(from: move, dx: p.x - move.start.x, dy: p.y - move.start.y)
                canvas?.showsSnapGuides = canvas?.snaps ?? false
            } else if let last = lassoPath.last, hypot(last.x - p.x, last.y - p.y) >= 2 {
                lassoPath.append(p)
            }
            needsDisplay = true
            autoscroll(with: event)
            return
        }
        guard var stroke = current else { return }
        switch stroke.tool {
        case .pen, .highlighter:
            if let last = stroke.points.last, hypot(last.x - p.x, last.y - p.y) < 1 { return }
            stroke.points.append(p)
        case .line, .arrow, .rectangle, .ellipse:
            var end = canvas?.snapped(p) ?? p
            if event.modifierFlags.contains(.shift), let start = stroke.points.first {
                end = Self.constrained(from: start, to: p, square: stroke.tool == .rectangle || stroke.tool == .ellipse)
            }
            stroke.points = [stroke.points[0], end]
        }
        current = stroke
        needsDisplay = true
        autoscroll(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if tool == .lasso {
            if let move = lassoMove {
                lassoMove = nil
                canvas?.showsSnapGuides = false
                canvas?.controller?.lassoMoved(frames: move.frames, oldStrokes: move.strokes)
            } else {
                finishLasso()
            }
            return
        }
        if tool == .eraser, let before = strokesBeforeErasing {
            strokesBeforeErasing = nil
            if before.count != strokes.count { canvas?.controller?.strokesChanged(from: before) }
            return
        }
        guard var stroke = current else { return }
        current = nil
        if stroke.points.count == 1, let p = stroke.points.first {
            stroke.points.append(CGPoint(x: p.x + 0.5, y: p.y + 0.5))
        }
        let before = strokes
        strokes.append(stroke)
        canvas?.controller?.strokesChanged(from: before)
    }

    private func erase(at p: CGPoint) {
        let hit = Set(strokes.filter { stroke in
            Self.path(for: stroke)
                .copy(strokingWithWidth: max(stroke.width, 1) + 10, lineCap: .round, lineJoin: .round, miterLimit: 10)
                .contains(p)
        }.map(\.id))
        if !hit.isEmpty { strokes.removeAll { hit.contains($0.id) } }
    }

    /// Shift-drag: 45° lines, squares and circles.
    private static func constrained(from start: CGPoint, to p: CGPoint, square: Bool) -> CGPoint {
        let dx = p.x - start.x, dy = p.y - start.y
        if square {
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
        }
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        let length = hypot(dx, dy)
        return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        for stroke in strokes {
            if lassoStrokes.contains(stroke.id) {
                ctx.saveGState()
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                ctx.setLineWidth(stroke.width + 8)
                ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.3).cgColor)
                ctx.addPath(Self.path(for: stroke))
                ctx.strokePath()
                ctx.restoreGState()
            }
            Self.draw(stroke, in: ctx)
        }
        if let current { Self.draw(current, in: ctx) }
        if lassoPath.count > 1 {
            let loop = NSBezierPath()
            loop.move(to: lassoPath[0])
            for p in lassoPath.dropFirst() { loop.line(to: p) }
            loop.lineWidth = 1.2
            loop.setLineDash([5, 3], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            loop.stroke()
        }
        if hasLassoSelection {
            let frame = NSBezierPath(rect: lassoBounds.insetBy(dx: -5, dy: -5))
            frame.lineWidth = 1
            frame.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            frame.stroke()
        }
    }

    static func draw(_ stroke: InkStroke, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(stroke.width)
        ctx.setStrokeColor(stroke.color.nsColor.cgColor)
        if stroke.tool == .highlighter { ctx.setBlendMode(.multiply) }
        ctx.addPath(path(for: stroke))
        ctx.strokePath()
        ctx.restoreGState()
    }

    static func path(for stroke: InkStroke) -> CGPath {
        let path = CGMutablePath()
        let pts = stroke.points
        guard let first = pts.first else { return path }
        let last = pts.last ?? first
        switch stroke.tool {
        case .pen, .highlighter:
            path.move(to: first)
            if pts.count < 3 {
                for p in pts.dropFirst() { path.addLine(to: p) }
            } else {
                for i in 1..<(pts.count - 1) {
                    let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
                    path.addQuadCurve(to: mid, control: pts[i])
                }
                path.addLine(to: last)
            }
        case .line:
            path.move(to: first)
            path.addLine(to: last)
        case .arrow:
            path.move(to: first)
            path.addLine(to: last)
            let angle = atan2(last.y - first.y, last.x - first.x)
            let length = max(10, stroke.width * 4)
            for side in [-1.0, 1.0] {
                let a = angle + .pi - side * 0.45
                path.move(to: last)
                path.addLine(to: CGPoint(x: last.x + cos(a) * length, y: last.y + sin(a) * length))
            }
        case .rectangle:
            path.addRect(CGRect(x: first.x, y: first.y, width: last.x - first.x, height: last.y - first.y).standardized)
        case .ellipse:
            path.addEllipse(in: CGRect(x: first.x, y: first.y, width: last.x - first.x, height: last.y - first.y).standardized)
        }
        return path
    }

    static func bounds(of strokes: [InkStroke]) -> CGRect {
        strokes.reduce(CGRect.null) { rect, stroke in
            rect.union(path(for: stroke).boundingBoxOfPath.insetBy(dx: -stroke.width, dy: -stroke.width))
        }
    }
}
