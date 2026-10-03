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

final class PageCanvasView: NSView, NSTextFieldDelegate {
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
    let titleField = NSTextField()
    let dateLabel = NSTextField(labelWithString: "")
    let inkView = InkView()
    var selectedElement: ElementView? {
        didSet {
            if oldValue !== selectedElement { oldValue?.isSelected = false }
            selectedElement?.isSelected = true
        }
    }

    var isExport: Bool { controller?.mode == .export }
    var elementViews: [ElementView] { subviews.compactMap { $0 as? ElementView } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: .aqua)

        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.focusRingType = .none
        titleField.font = NSFont(name: "HelveticaNeue-Light", size: 26) ?? .systemFont(ofSize: 26, weight: .light)
        titleField.textColor = .black
        titleField.placeholderString = "Page Title"
        titleField.lineBreakMode = .byTruncatingTail
        titleField.usesSingleLineMode = true
        titleField.cell?.isScrollable = true
        titleField.delegate = self
        titleField.frame = NSRect(x: Self.margin, y: 30, width: Self.titleWidth, height: 36)

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
        dateLabel.stringValue = page.created.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
            + "      " + page.created.formatted(date: .omitted, time: .shortened)
        for element in page.elements {
            if let view = makeView(for: element) { addElementView(view) }
        }
        inkView.strokes = page.strokes
        // Printing draws the title itself (an NSTextField clips its glyphs when printed).
        if isExport { titleField.isHidden = true }
        updateSize()
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
            view = isExport ? TableSnapshotView(element: element) : TableElementView(element: element)
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
        selectedElement = nil
        titleField.stringValue = ""
    }

    func snapshotElements() -> [PageElement] {
        elementViews.map { $0.makeElement() }
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
            title.draw(with: NSRect(x: Self.margin + 2, y: 32, width: Self.titleWidth, height: 36),
                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
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
        if controller.editor.tool == .type, p.y > Self.contentTop - 24 {
            controller.createTextElement(at: p)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let controller else { return super.keyDown(with: event) }
        if event.keyCode == 53 {
            controller.editor.tool = .type
            selectedElement = nil
            return
        }
        if let selected = selectedElement {
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
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
                selected.setFrameOrigin(NSPoint(x: max(0, old.minX + delta.x), y: max(0, old.minY + delta.y)))
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
        guard let selected = selectedElement else { return NSSound.beep() }
        controller?.copyElement(selected)
    }

    @objc func cut(_ sender: Any?) {
        guard let selected = selectedElement else { return NSSound.beep() }
        controller?.copyElement(selected)
        controller?.removeElement(selected)
        controller?.undoManager?.setActionName("Cut")
    }

    @objc func paste(_ sender: Any?) {
        controller?.paste()
    }

    @objc func delete(_ sender: Any?) {
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

    // MARK: Title

    func controlTextDidChange(_ obj: Notification) {
        controller?.titleChanged()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) || commandSelector == #selector(NSResponder.insertTab(_:)) {
            controller?.focusFirstText()
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
        guard let kind = tool.strokeTool else { return }
        let highlighter = kind == .highlighter
        current = InkStroke(tool: kind, color: highlighter ? editor.highlighterColor : editor.penColor,
                            width: highlighter ? editor.highlighterWidth : editor.penWidth, points: [p])
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if tool == .eraser {
            erase(at: p)
            return
        }
        guard var stroke = current else { return }
        switch stroke.tool {
        case .pen, .highlighter:
            if let last = stroke.points.last, hypot(last.x - p.x, last.y - p.y) < 1 { return }
            stroke.points.append(p)
        case .line, .arrow, .rectangle, .ellipse:
            var end = p
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
        for stroke in strokes { Self.draw(stroke, in: ctx) }
        if let current { Self.draw(current, in: ctx) }
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
