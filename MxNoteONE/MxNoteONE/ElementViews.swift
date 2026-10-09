//
//  ElementViews.swift
//  MxNoteONE
//
//  Containers on the page. Each has a bar along the top for dragging
//  (and a context menu) and a handle on the right edge for resizing.
//  Text containers grow as you type; pictures keep their proportions;
//  attachments open with a double-click; recordings play in place; tables
//  are edited cell by cell.
//

import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, state: Bool = false, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        self.state = state ? .on : .off
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { handler() }
}

// MARK: - Base container

class ElementView: NSView {
    static let gripHeight: CGFloat = 10

    weak var canvas: PageCanvasView?
    var element: PageElement
    var isSelected = false { didSet { refreshChrome() } }
    var isHovered = false { didSet { refreshChrome() } }
    var isEditing = false { didSet { refreshChrome() } }
    let grip = GripView()
    let resizeHandle = ResizeHandleView()
    private var tracking: NSTrackingArea?
    /// Set shortly after the container appears; from then on height changes push the container below it.
    private(set) var settled = false

    var minWidth: CGFloat { 60 }
    var isExport: Bool { canvas?.isExport ?? false }
    var showsChrome: Bool { !isExport && (isSelected || isHovered || isEditing) }
    var controller: CanvasController? { canvas?.controller }

    init(element: PageElement) {
        self.element = element
        super.init(frame: NSRect(x: element.x, y: element.y, width: max(element.width, 60),
                                 height: max(element.height, Self.gripHeight + 20)))
        grip.owner = self
        resizeHandle.owner = self
        addSubview(grip)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// Call after adding the content view, so the resize handle stays on top.
    func finishSetup() {
        addSubview(resizeHandle)
        layoutParts()
    }

    var contentFrame: NSRect {
        NSRect(x: 0, y: Self.gripHeight, width: bounds.width, height: max(0, bounds.height - Self.gripHeight))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutParts()
    }

    func layoutParts() {
        grip.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Self.gripHeight)
        resizeHandle.frame = NSRect(x: bounds.width - 6, y: Self.gripHeight, width: 6, height: max(0, bounds.height - Self.gripHeight))
        layoutContent()
    }

    func layoutContent() {}

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !settled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.settled = true }
    }

    /// Call after the height changed, so a container sitting right below follows along.
    func heightChanged(from oldHeight: CGFloat) {
        guard settled, !isExport, superview != nil else { return }
        controller?.pushElements(below: self, oldMaxY: frame.minY + oldHeight, delta: frame.height - oldHeight)
    }

    func setWidth(_ width: CGFloat) {
        setFrameSize(NSSize(width: max(minWidth, width), height: frame.height))
    }

    func applyFrame(_ rect: NSRect) {
        setFrameOrigin(rect.origin)
        setWidth(rect.width)
    }

    func prepareForExport() {
        grip.isHidden = true
        resizeHandle.isHidden = true
    }

    func makeElement() -> PageElement {
        var e = element
        e.x = frame.minX
        e.y = frame.minY
        e.width = frame.width
        e.height = frame.height
        return e
    }

    func indexText() -> String? { element.fileName }

    func refreshChrome() {
        needsDisplay = true
        grip.needsDisplay = true
        resizeHandle.needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func draw(_ dirtyRect: NSRect) {
        guard showsChrome else { return }
        let path = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = isSelected ? 1.5 : 1
        (isSelected ? NSColor.controlAccentColor : NSColor(white: 0.74, alpha: 1)).setStroke()
        path.stroke()
    }

    /// Drag the container around the page.
    func beginMove(with event: NSEvent) {
        guard let canvas, let window, !isExport else { return }
        canvas.selectedElement = self
        window.makeFirstResponder(canvas)
        let start = canvas.convert(event.locationInWindow, from: nil)
        let oldFrame = frame
        var moved = false
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: NSEvent.foreverDuration,
                           mode: .eventTracking) { ev, stop in
            guard let ev, ev.type == .leftMouseDragged else {
                stop.pointee = true
                return
            }
            let p = canvas.convert(ev.locationInWindow, from: nil)
            self.setFrameOrigin(NSPoint(x: max(0, oldFrame.minX + p.x - start.x), y: max(0, oldFrame.minY + p.y - start.y)))
            moved = true
            canvas.autoscroll(with: ev)
        }
        if moved { controller?.elementFrameChanged(self, from: oldFrame) }
    }

    /// Drag the right edge to change the width.
    func beginResize(with event: NSEvent) {
        guard let canvas, let window, !isExport else { return }
        let start = canvas.convert(event.locationInWindow, from: nil)
        let oldFrame = frame
        var resized = false
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: NSEvent.foreverDuration,
                           mode: .eventTracking) { ev, stop in
            guard let ev, ev.type == .leftMouseDragged else {
                stop.pointee = true
                return
            }
            let p = canvas.convert(ev.locationInWindow, from: nil)
            self.setWidth(oldFrame.width + p.x - start.x)
            resized = true
        }
        if resized { controller?.elementFrameChanged(self, from: oldFrame) }
    }

    func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Cut") { [weak self] in
            guard let self else { return }
            self.controller?.copyElement(self)
            self.controller?.removeElement(self)
        })
        menu.addItem(ClosureMenuItem("Copy") { [weak self] in
            guard let self else { return }
            self.controller?.copyElement(self)
        })
        menu.addItem(ClosureMenuItem("Delete") { [weak self] in
            guard let self else { return }
            self.controller?.removeElement(self)
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Bring to Front") { [weak self] in
            guard let self else { return }
            self.controller?.bringToFront(self)
        })
        menu.addItem(ClosureMenuItem("Send to Back") { [weak self] in
            guard let self else { return }
            self.controller?.sendToBack(self)
        })
        return menu
    }
}

/// The bar along the top of a container.
final class GripView: NSView {
    weak var owner: ElementView?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let owner, owner.showsChrome else { return }
        NSColor(white: owner.isSelected ? 0.80 : 0.88, alpha: 1).setFill()
        bounds.fill()
        NSColor(white: 0.52, alpha: 1).setFill()
        for i in -2...2 {
            NSBezierPath(ovalIn: NSRect(x: bounds.midX + CGFloat(i) * 6 - 1, y: bounds.midY - 1, width: 2.2, height: 2.2)).fill()
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        owner?.beginMove(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        owner?.contextMenu()
    }
}

/// The right edge of a container.
final class ResizeHandleView: NSView {
    weak var owner: ElementView?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let owner, owner.showsChrome else { return }
        NSColor(white: 0.6, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.midX - 1, y: bounds.midY - 8, width: 2, height: 16), xRadius: 1, yRadius: 1).fill()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        owner?.beginResize(with: event)
    }
}

// MARK: - Text

final class NoteTextView: NSTextView {
    weak var owner: TextElementView?
    /// The text container edited last (formatting from the ribbon goes here).
    static weak var current: NoteTextView?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            NoteTextView.current = self
            owner?.isEditing = true
            owner?.canvas?.selectedElement = nil
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { owner?.isEditing = false }
        return resigned
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        owner?.textFrameChanged()
    }

    override func mouseDown(with event: NSEvent) {
        if toggleCheckbox(at: event) { return }
        super.mouseDown(with: event)
    }

    /// Clicking ☐ / ☑ checks or unchecks a To Do item.
    private func toggleCheckbox(at event: NSEvent) -> Bool {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage, storage.length > 0 else { return false }
        var p = convert(event.locationInWindow, from: nil)
        p.x -= textContainerOrigin.x
        p.y -= textContainerOrigin.y
        let glyph = lm.glyphIndex(for: p, in: tc, fractionOfDistanceThroughGlyph: nil)
        let rect = lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc)
        guard rect.insetBy(dx: -2, dy: -2).contains(p) else { return false }
        let ns = storage.string as NSString
        let index = lm.characterIndexForGlyph(at: glyph)
        guard index < ns.length else { return false }
        let range = ns.rangeOfComposedCharacterSequence(at: index)
        let char = ns.substring(with: range)
        guard char == TagKind.todo.symbol || char == TagKind.todoDone else { return false }
        let paragraph = ns.paragraphRange(for: range)
        let info = TextFormatter.parseParagraph(ns.substring(with: paragraph))
        guard info.tag == .todo, range.location == paragraph.location + info.indent + info.listLength else { return false }
        let replacement = char == TagKind.todo.symbol ? TagKind.todoDone : TagKind.todo.symbol
        guard shouldChangeText(in: range, replacementString: replacement) else { return true }
        storage.replaceCharacters(in: range, with: replacement)
        didChangeText()
        undoManager?.setActionName(char == TagKind.todo.symbol ? "Check" : "Uncheck")
        return true
    }
}

final class TextElementView: ElementView, NSTextViewDelegate {
    let textView = NoteTextView(usingTextLayoutManager: false)
    private var adjusting = false

    override var minWidth: CGFloat { 80 }

    override init(element: PageElement) {
        super.init(element: element)
        configureTextView()
        if let data = element.rtfd, let text = NSAttributedString(rtfd: data, documentAttributes: nil) {
            textView.textStorage?.setAttributedString(text)
        }
        addSubview(textView)
        finishSetup()
        textView.sizeToFit()
        fitHeight()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func configureTextView() {
        let tv = textView
        tv.owner = self
        tv.delegate = self
        tv.frame = NSRect(x: 0, y: Self.gripHeight, width: frame.width, height: 24)
        tv.isRichText = true
        tv.importsGraphics = true
        tv.allowsImageEditing = true
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = []
        tv.textContainerInset = NSSize(width: 4, height: 4)
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: frame.width, height: .greatestFiniteMagnitude)
        tv.minSize = NSSize(width: 0, height: 24)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.usesFindBar = false
        tv.usesFontPanel = true
        tv.usesRuler = false
        tv.isAutomaticLinkDetectionEnabled = true
        tv.isContinuousSpellCheckingEnabled = true
        tv.insertionPointColor = .black
        tv.typingAttributes = TextFormatter.defaultAttributes
        tv.linkTextAttributes = [
            .foregroundColor: NSColor(srgbRed: 0.10, green: 0.36, blue: 0.80, alpha: 1),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
    }

    override func prepareForExport() {
        super.prepareForExport()
        textView.isEditable = false
        textView.isSelectable = false
    }

    override func layoutContent() {
        guard !adjusting else { return }
        let content = contentFrame
        guard textView.frame.minY != content.minY || textView.frame.width != content.width else { return }
        adjusting = true
        textView.frame = NSRect(x: 0, y: Self.gripHeight, width: content.width, height: textView.frame.height)
        textView.sizeToFit()
        adjusting = false
        fitHeight()
    }

    func textFrameChanged() {
        if !adjusting { fitHeight() }
    }

    private func fitHeight() {
        let height = Self.gripHeight + textView.frame.height
        guard abs(frame.height - height) > 0.5 else { return }
        let oldHeight = frame.height
        adjusting = true
        super.setFrameSize(NSSize(width: frame.width, height: height))
        adjusting = false
        heightChanged(from: oldHeight)
        canvas?.updateSize()
    }

    func focus(atEnd: Bool = true) {
        window?.makeFirstResponder(textView)
        let length = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: atEnd ? length : 0, length: 0))
    }

    override func makeElement() -> PageElement {
        var e = super.makeElement()
        if let storage = textView.textStorage {
            e.rtfd = storage.rtfd(from: NSRange(location: 0, length: storage.length), documentAttributes: [:])
        }
        return e
    }

    override func indexText() -> String? { textView.string }

    override func contextMenu() -> NSMenu {
        let menu = super.contextMenu()
        menu.insertItem(.separator(), at: 0)
        menu.insertItem(ClosureMenuItem("Select All Text") { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.textView)
            self.textView.selectAll(nil)
        }, at: 0)
        return menu
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        controller?.textChanged()
        TextFormatter.convertWikiLink(in: textView)
    }

    func textDidEndEditing(_ notification: Notification) {
        guard let canvas, canvas.selectedElement !== self, let storage = textView.textStorage else { return }
        let empty = storage.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !storage.containsAttachments(in: NSRange(location: 0, length: storage.length))
        guard empty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.superview != nil, self.window?.firstResponder !== self.textView,
                  self.canvas?.selectedElement !== self,
                  self.textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            self.controller?.removeElement(self, undoable: false)
        }
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            return TextFormatter.handleNewline(textView)
        case #selector(NSResponder.insertTab(_:)):
            return TextFormatter.handleTab(textView, outdent: false)
        case #selector(NSResponder.insertBacktab(_:)):
            return TextFormatter.handleTab(textView, outdent: true)
        case #selector(NSResponder.cancelOperation(_:)):
            canvas?.selectedElement = self
            window?.makeFirstResponder(canvas)
            return true
        default:
            return false
        }
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap { URL(string: $0) }
        if let url, url.scheme == NotebookStore.linkScheme {
            NotebookStore.shared.openLink(url)
            return true
        }
        return false
    }
}

// MARK: - Picture

final class ImageContentView: NSView {
    weak var owner: ImageElementView?
    var image: NSImage?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        image?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                    hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { owner?.openInViewer() } else { owner?.beginMove(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        owner?.contextMenu()
    }
}

final class ImageElementView: ElementView {
    let imageContent = ImageContentView()
    private let aspect: CGFloat
    private let imageSize: NSSize

    init(element: PageElement, image: NSImage?) {
        let image = image ?? NSImage(systemSymbolName: "photo", accessibilityDescription: "Missing picture") ?? NSImage()
        imageSize = image.size
        aspect = image.size.width > 0 ? image.size.height / image.size.width : 0.75
        super.init(element: element)
        imageContent.image = image
        imageContent.owner = self
        addSubview(imageContent)
        finishSetup()
        setWidth(frame.width)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var minWidth: CGFloat { 24 }

    override func setWidth(_ width: CGFloat) {
        let w = max(minWidth, width)
        setFrameSize(NSSize(width: w, height: Self.gripHeight + w * aspect))
    }

    override func layoutContent() {
        imageContent.frame = contentFrame
    }

    func openInViewer() {
        guard let ref = controller?.ref, let asset = element.asset else { return }
        NotebookStore.shared.openAsset(asset, fileName: "Picture." + (asset as NSString).pathExtension, for: ref)
    }

    override func contextMenu() -> NSMenu {
        let menu = super.contextMenu()
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Copy Picture") { [weak self] in
            guard let image = self?.imageContent.image else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
        })
        menu.addItem(ClosureMenuItem("Save Picture As…") { [weak self] in
            guard let self, let ref = self.controller?.ref, let asset = self.element.asset else { return }
            NotebookStore.shared.saveAssetAs(asset, fileName: "Picture." + (asset as NSString).pathExtension, for: ref)
        })
        menu.addItem(ClosureMenuItem("Open in Viewer") { [weak self] in self?.openInViewer() })
        menu.addItem(ClosureMenuItem("Original Size") { [weak self] in
            guard let self else { return }
            let old = self.frame
            self.setWidth(self.imageSize.width)
            self.controller?.elementFrameChanged(self, from: old)
        })
        return menu
    }
}

// MARK: - File attachment and audio recording

final class FileContentView: NSView {
    weak var owner: FileElementView?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let owner else { return }
        NSColor(white: 0.97, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        NSColor(white: 0.82, alpha: 1).setStroke()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).stroke()

        let iconRect = NSRect(x: 8, y: (bounds.height - 32) / 2, width: 32, height: 32)
        if owner.element.kind == .audio {
            let name = owner.isPlaying ? "stop.circle.fill" : "play.circle.fill"
            let config = NSImage.SymbolConfiguration(pointSize: 26, weight: .regular)
                .applying(.init(paletteColors: [.white, .controlAccentColor]))
            NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)?
                .draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            owner.icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let title = NSAttributedString(string: owner.element.fileName ?? "Attachment", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.black,
        ])
        title.draw(with: NSRect(x: 48, y: 7, width: bounds.width - 56, height: 18),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        let subtitle = NSAttributedString(string: owner.subtitle, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(white: 0.45, alpha: 1),
        ])
        subtitle.draw(with: NSRect(x: 48, y: 25, width: bounds.width - 56, height: 16),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    override func mouseDown(with event: NSEvent) {
        guard let owner else { return }
        let p = convert(event.locationInWindow, from: nil)
        if owner.element.kind == .audio, p.x < 44 {
            owner.togglePlay()
        } else if event.clickCount == 2 {
            owner.open()
        } else {
            owner.beginMove(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        owner?.contextMenu()
    }
}

final class FileElementView: ElementView {
    let body = FileContentView()
    private var player: AVAudioPlayer?
    private var duration: TimeInterval?
    lazy var icon: NSImage = {
        let ext = ((element.fileName ?? element.asset ?? "") as NSString).pathExtension
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
    }()

    var isPlaying: Bool { player?.isPlaying == true }

    var subtitle: String {
        if element.kind == .audio {
            let length = duration.map { Duration.seconds($0).formatted(.time(pattern: .minuteSecond)) } ?? ""
            return isPlaying ? "Playing… \(length)" : "Audio recording \(length)"
        }
        return "Double-click to open"
    }

    override init(element: PageElement) {
        super.init(element: element)
        body.owner = self
        addSubview(body)
        finishSetup()
        setWidth(frame.width)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var minWidth: CGFloat { 160 }

    override func setWidth(_ width: CGFloat) {
        setFrameSize(NSSize(width: max(minWidth, width), height: Self.gripHeight + 46))
    }

    override func layoutContent() {
        body.frame = contentFrame
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            player?.stop()
        } else if element.kind == .audio, duration == nil, let asset = element.asset,
                  let data = controller?.assetData(asset) {
            duration = (try? AVAudioPlayer(data: data))?.duration
            body.needsDisplay = true
        }
    }

    func open() {
        if element.kind == .audio { return togglePlay() }
        guard let ref = controller?.ref, let asset = element.asset else { return }
        NotebookStore.shared.openAsset(asset, fileName: element.fileName, for: ref)
    }

    func togglePlay() {
        if let player, player.isPlaying {
            player.stop()
            body.needsDisplay = true
            return
        }
        guard let asset = element.asset, let data = controller?.assetData(asset),
              let player = try? AVAudioPlayer(data: data) else { return NSSound.beep() }
        self.player = player
        duration = player.duration
        player.play()
        body.needsDisplay = true
        Task { [weak self] in
            while let self, self.player?.isPlaying == true {
                try? await Task.sleep(for: .milliseconds(250))
            }
            self?.body.needsDisplay = true
        }
    }

    override func contextMenu() -> NSMenu {
        let menu = super.contextMenu()
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(element.kind == .audio ? (isPlaying ? "Stop" : "Play") : "Open") { [weak self] in
            self?.open()
        })
        menu.addItem(ClosureMenuItem("Save As…") { [weak self] in
            guard let self, let ref = self.controller?.ref, let asset = self.element.asset else { return }
            NotebookStore.shared.saveAssetAs(asset, fileName: self.element.fileName, for: ref)
        })
        return menu
    }
}

// MARK: - Table

/// A table cell (row, column).
struct CellRef: Hashable {
    var row: Int
    var column: Int
}

final class TableModel {
    var data: TableData
    var width: CGFloat
    /// Cell to continue editing in after a Tab / Return / Backspace command.
    var focusRequest: CellRef?
    /// Called when the table needs a wider (+) or narrower (-) container.
    var onWidthChange: ((CGFloat) -> Void)?
    var onChange: (() -> Void)?

    init(data: TableData, width: CGFloat) {
        self.data = data
        self.width = width
    }

    func columnWidth(_ column: Int) -> CGFloat {
        let total = data.columnWidths.reduce(0, +)
        guard column < data.columnWidths.count, total > 0 else { return 80 }
        return max(36, width * data.columnWidths[column] / total)
    }

    func text(_ cell: CellRef) -> String {
        guard data.rows.indices.contains(cell.row), data.rows[cell.row].indices.contains(cell.column) else { return "" }
        return data.rows[cell.row][cell.column]
    }

    func setText(_ text: String, _ cell: CellRef) {
        guard data.rows.indices.contains(cell.row), data.rows[cell.row].indices.contains(cell.column) else { return }
        data.rows[cell.row][cell.column] = text
    }

    func contains(_ cell: CellRef) -> Bool {
        data.rows.indices.contains(cell.row) && cell.column >= 0 && cell.column < data.columnCount
    }

    func insertRow(at index: Int) {
        let i = min(max(index, 0), data.rows.count)
        data.rows.insert(Array(repeating: "", count: data.columnCount), at: i)
        if data.shading != nil {
            data.shading!.insert(Array(repeating: nil, count: data.columnCount), at: min(i, data.shading!.count))
            data.padShading()
        }
        onChange?()
    }

    func insertColumn(at index: Int) {
        let i = min(max(index, 0), data.columnCount)
        for r in data.rows.indices { data.rows[r].insert("", at: i) }
        if data.shading != nil {
            // A new column takes the shading of the column next to it.
            data.padShading()
            for r in data.shading!.indices {
                let neighbor = i > 0 ? i - 1 : i
                let color = data.shading![r].indices.contains(neighbor) ? data.shading![r][neighbor] : nil
                data.shading![r].insert(color, at: min(i, data.shading![r].count))
            }
            data.padShading()
        }
        let average = data.columnWidths.isEmpty ? 120 : data.columnWidths.reduce(0, +) / Double(data.columnWidths.count)
        data.columnWidths.insert(average, at: min(i, data.columnWidths.count))
        onChange?()
    }

    func deleteRow(_ index: Int) {
        guard data.rows.count > 1, data.rows.indices.contains(index) else { return }
        data.rows.remove(at: index)
        if data.shading?.indices.contains(index) == true { data.shading!.remove(at: index) }
        onChange?()
    }

    func deleteColumn(_ index: Int) {
        guard data.columnCount > 1, index < data.columnCount else { return }
        for r in data.rows.indices { data.rows[r].remove(at: index) }
        if data.shading != nil {
            for r in data.shading!.indices where data.shading![r].indices.contains(index) { data.shading![r].remove(at: index) }
        }
        if data.columnWidths.indices.contains(index) { data.columnWidths.remove(at: index) }
        onChange?()
    }

    /// Inserts a column and widens the container by one average column, so the other columns keep their size.
    func addColumn(at index: Int) {
        let extra = width / CGFloat(max(data.columnCount, 1))
        insertColumn(at: index)
        onWidthChange?(extra)
    }

    /// Deletes a column and narrows the container by its width.
    func removeColumn(_ index: Int) {
        guard data.columnCount > 1, index < data.columnCount else { return }
        let removed = columnWidth(index)
        deleteColumn(index)
        onWidthChange?(-removed)
    }

    // MARK: OneNote-style keys

    /// Tab: next cell. In a one-row table, Tab in the filled last cell adds a column;
    /// Tab in the last cell of the last row adds a row. Shift-Tab goes back.
    func tab(from cell: CellRef, backward: Bool) {
        let rows = data.rows.count, columns = data.columnCount
        if backward {
            if cell.column > 0 {
                focusRequest = CellRef(row: cell.row, column: cell.column - 1)
            } else if cell.row > 0 {
                focusRequest = CellRef(row: cell.row - 1, column: columns - 1)
            }
            return
        }
        if cell.column < columns - 1 {
            focusRequest = CellRef(row: cell.row, column: cell.column + 1)
        } else if rows == 1, !text(cell).trimmingCharacters(in: .whitespaces).isEmpty {
            addColumn(at: columns)
            focusRequest = CellRef(row: 0, column: columns)
        } else if cell.row < rows - 1 {
            focusRequest = CellRef(row: cell.row + 1, column: 0)
        } else {
            insertRow(at: rows)
            focusRequest = CellRef(row: rows, column: 0)
        }
    }

    /// Return: in the last row adds a row; elsewhere moves down. ⌘Return inserts a row below.
    func newline(from cell: CellRef, insertBelow: Bool) {
        if insertBelow || cell.row == data.rows.count - 1 {
            insertRow(at: cell.row + 1)
            focusRequest = CellRef(row: cell.row + 1, column: insertBelow ? cell.column : 0)
        } else {
            focusRequest = CellRef(row: cell.row + 1, column: cell.column)
        }
    }

    /// Backspace in an empty cell: takes back an extra Tab or Return — removes the last column if it is empty,
    /// or the last row if it is empty. Returns the cell to continue in, or nil if nothing was removed.
    func removeEmpty(at cell: CellRef) -> CellRef? {
        let isEmpty: (String) -> Bool = { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let lastColumn = data.columnCount - 1, lastRow = data.rows.count - 1
        if cell.column == lastColumn, lastColumn > 0, data.rows.allSatisfy({ isEmpty($0[lastColumn]) }) {
            removeColumn(lastColumn)
            return CellRef(row: cell.row, column: lastColumn - 1)
        }
        if cell.row == lastRow, lastRow > 0, data.rows[lastRow].allSatisfy(isEmpty) {
            deleteRow(lastRow)
            return CellRef(row: lastRow - 1, column: data.columnCount - 1)
        }
        return nil
    }

    func toggleHeaderRow() {
        data.headerRow.toggle()
        onChange?()
    }

    func sort(byColumn column: Int, ascending: Bool) {
        data.padShading()
        let skip = data.headerRow && !data.rows.isEmpty ? 1 : 0
        let pairs = Array(zip(data.rows, data.shading ?? []))
        var body = Array(pairs.dropFirst(skip))
        body.sort {
            let order = $0.0[column].localizedStandardCompare($1.0[column])
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
        let sorted = Array(pairs.prefix(skip)) + body
        data.rows = sorted.map(\.0)
        data.shading = sorted.map(\.1)
        onChange?()
    }

    func clear(_ cells: Set<CellRef>) {
        for cell in cells { setText("", cell) }
        onChange?()
    }

    // MARK: Shading

    enum ShadingScope {
        case cell, row, column, headerRow, table
    }

    /// Sets the background colour of the cell, its row, its column, the header row or the whole table (nil clears it).
    func setShading(_ color: NSColor?, scope: ShadingScope, at cell: CellRef) {
        var cells: Set<CellRef> = []
        for r in data.rows.indices {
            for c in 0..<data.columnCount {
                let hit: Bool
                switch scope {
                case .cell: hit = r == cell.row && c == cell.column
                case .row: hit = r == cell.row
                case .column: hit = c == cell.column
                case .headerRow: hit = r == 0
                case .table: hit = true
                }
                if hit { cells.insert(CellRef(row: r, column: c)) }
            }
        }
        setShading(color, cells: cells)
    }

    /// Sets the background colour of the given cells (nil clears it).
    func setShading(_ color: NSColor?, cells: Set<CellRef>) {
        data.padShading()
        let value = color.map { RGBA($0) }
        for cell in cells where contains(cell) { data.shading![cell.row][cell.column] = value }
        if data.shading!.allSatisfy({ $0.allSatisfy { $0 == nil } }) { data.shading = nil }
        onChange?()
    }
}

/// The editable table: cells are drawn here, and one text editor moves to the cell being typed in.
/// Click a cell to type in it; drag across cells, ⇧-click or ⌘-click to select several (they are
/// highlighted); right-click for shading and row / column commands, which apply to the selected cells.
final class TableGridView: NSView, NSTextViewDelegate {
    static let padX: CGFloat = 6
    static let padY: CGFloat = 5
    static let minRowHeight: CGFloat = 26

    weak var owner: TableElementView?
    let model: TableModel
    private(set) var selection: Set<CellRef> = []
    private var anchor: CellRef?
    /// The moving corner of a ⇧-extended selection.
    private var extent: CellRef?
    private(set) var editing: CellRef?
    private let editor = NSTextView(usingTextLayoutManager: false)
    private var editorUndo = UndoManager()
    private var rowHeights: [CGFloat] = []
    private var relayingOut = false

    init(model: TableModel) {
        self.model = model
        super.init(frame: .zero)
        editor.isRichText = false
        editor.importsGraphics = false
        editor.drawsBackground = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = true
        editor.allowsUndo = true
        editor.usesFindBar = false
        editor.isContinuousSpellCheckingEnabled = true
        editor.insertionPointColor = .black
        editor.focusRingType = .none
        editor.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: Geometry

    private var columns: Int { model.data.columnCount }
    private var rows: Int { model.data.rows.count }

    private func columnX(_ column: Int) -> CGFloat {
        (0..<column).reduce(0) { $0 + model.columnWidth($1) }
    }

    func cellRect(_ cell: CellRef) -> NSRect {
        let y = rowHeights.prefix(cell.row).reduce(0, +)
        let height = cell.row < rowHeights.count ? rowHeights[cell.row] : Self.minRowHeight
        return NSRect(x: columnX(cell.column), y: y, width: model.columnWidth(cell.column), height: height)
    }

    private func cell(at point: NSPoint) -> CellRef? {
        guard rows > 0, columns > 0 else { return nil }
        var y: CGFloat = 0
        var row = rows - 1
        for (r, height) in rowHeights.enumerated() where point.y < y + height {
            row = r
            break
        }
        if point.y < 0 { row = 0 }
        y = 0
        var x: CGFloat = 0
        var column = columns - 1
        for c in 0..<columns {
            x += model.columnWidth(c)
            if point.x < x { column = c; break }
        }
        _ = y
        return CellRef(row: row, column: column)
    }

    private func font(_ row: Int) -> NSFont {
        model.data.headerRow && row == 0
            ? NSFontManager.shared.convert(Prefs.defaultFont, toHaveTrait: .boldFontMask) : Prefs.defaultFont
    }

    private func textColor(_ cell: CellRef) -> NSColor {
        model.data.textIsLight(cell.row, cell.column) ? .white : .black
    }

    private func textHeight(_ text: String, width: CGFloat, font: NSFont) -> CGFloat {
        let string = text.isEmpty || text.hasSuffix("\n") ? text + " " : text
        return ceil((string as NSString).boundingRect(with: NSSize(width: max(width, 10), height: .greatestFiniteMagnitude),
                                                      options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                      attributes: [.font: font]).height)
    }

    /// Measures rows, resizes the container to fit and repositions the editor.
    func relayout() {
        guard !relayingOut else { return }
        relayingOut = true
        defer { relayingOut = false }
        selection = selection.filter(model.contains)
        if let editing, !model.contains(editing) { stopEditing(commit: false) }
        rowHeights = (0..<rows).map { r in
            let f = font(r)
            let tallest = (0..<columns).map { c -> CGFloat in
                let cell = CellRef(row: r, column: c)
                let text = editing == cell ? editor.string : model.text(cell)
                return textHeight(text, width: model.columnWidth(c) - 2 * Self.padX, font: f)
            }.max() ?? 0
            return max(Self.minRowHeight, tallest + 2 * Self.padY)
        }
        owner?.fitTableHeight(rowHeights.reduce(0, +))
        positionEditor()
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let highlightSelection = selection.count > 1 || editing == nil
        for r in 0..<rows {
            for c in 0..<columns {
                let cell = CellRef(row: r, column: c)
                let rect = cellRect(cell)
                guard rect.intersects(dirtyRect) else { continue }
                (model.data.shade(r, c)?.nsColor ?? .white).setFill()
                rect.fill()
                if highlightSelection && selection.contains(cell) {
                    NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
                    rect.fill(using: .sourceOver)
                }
                NSColor(white: 0.6, alpha: 1).setStroke()
                NSBezierPath(rect: rect.insetBy(dx: 0.25, dy: 0.25)).stroke()
                if editing != cell {
                    model.text(cell).draw(with: rect.insetBy(dx: Self.padX, dy: Self.padY),
                                          options: [.usesLineFragmentOrigin, .usesFontLeading],
                                          attributes: [.font: font(r), .foregroundColor: textColor(cell)])
                }
            }
        }
        if highlightSelection {
            NSColor.controlAccentColor.setStroke()
            for cell in selection {
                let path = NSBezierPath(rect: cellRect(cell).insetBy(dx: 1, dy: 1))
                path.lineWidth = 1.5
                path.stroke()
            }
        }
    }

    // MARK: Editing

    func beginEditing(_ cell: CellRef, at point: NSPoint? = nil, caretAtEnd: Bool = true) {
        guard model.contains(cell) else { return }
        if editing != nil { stopEditing(commit: true) }
        editing = cell
        selection = [cell]
        anchor = cell
        extent = nil
        editorUndo = UndoManager()
        editor.font = font(cell.row)
        editor.textColor = textColor(cell)
        editor.insertionPointColor = textColor(cell)
        editor.typingAttributes = [.font: font(cell.row), .foregroundColor: textColor(cell)]
        editor.string = model.text(cell)
        if editor.superview !== self { addSubview(editor) }
        relayout()
        window?.makeFirstResponder(editor)
        if let point {
            let index = editor.characterIndexForInsertion(at: editor.convert(point, from: self))
            editor.setSelectedRange(NSRange(location: index, length: 0))
        } else {
            editor.setSelectedRange(NSRange(location: caretAtEnd ? (editor.string as NSString).length : 0, length: 0))
        }
        needsDisplay = true
    }

    private func positionEditor() {
        guard let editing, model.contains(editing) else { return }
        let rect = cellRect(editing).insetBy(dx: Self.padX, dy: Self.padY)
        editor.textContainer?.containerSize = NSSize(width: rect.width, height: .greatestFiniteMagnitude)
        editor.frame = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(rect.height, 16))
    }

    /// Stops typing in the cell (keeping the text) and leaves the cell selected.
    func endEditing() {
        guard editing != nil else { return }
        let editorWasFocused = window?.firstResponder === editor
        stopEditing(commit: true)
        if editorWasFocused { window?.makeFirstResponder(self) }
        relayout()
    }

    private func stopEditing(commit: Bool) {
        guard let cell = editing else { return }
        if commit, model.text(cell) != editor.string {
            model.setText(editor.string, cell)
            owner?.controller?.markDirty()
        }
        editing = nil
        editor.removeFromSuperview()
        needsDisplay = true
    }

    private func continueAtFocusRequest() {
        guard let next = model.focusRequest else { return }
        model.focusRequest = nil
        beginEditing(next)
    }

    func textDidChange(_ notification: Notification) {
        guard let cell = editing else { return }
        model.setText(editor.string, cell)
        owner?.controller?.markDirty()
        relayout()
    }

    func textDidEndEditing(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.editing != nil, self.window?.firstResponder !== self.editor else { return }
            if self.window?.firstResponder !== self { self.selection = [] }
            self.stopEditing(commit: true)
            self.relayout()
        }
    }

    func undoManager(for view: NSTextView) -> UndoManager? { editorUndo }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard let cell = editing else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            stopEditing(commit: true)
            model.tab(from: cell, backward: commandSelector == #selector(NSResponder.insertBacktab(_:)))
            if model.focusRequest == nil { beginEditing(cell) } else { continueAtFocusRequest() }
            return true
        case #selector(NSResponder.insertNewline(_:)):
            stopEditing(commit: true)
            model.newline(from: cell, insertBelow: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
            continueAtFocusRequest()
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), #selector(NSResponder.insertLineBreak(_:)):
            textView.insertText("\n", replacementRange: textView.selectedRange())
            return true
        case #selector(NSResponder.deleteBackward(_:)):
            guard textView.string.isEmpty else { return false }
            stopEditing(commit: true)
            if let next = model.removeEmpty(at: cell) {
                beginEditing(next)
            } else {
                beginEditing(cell)
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endEditing()
            selection = [cell]
            anchor = cell
            needsDisplay = true
            return true
        default:
            return false
        }
    }

    /// Right-click while typing: the table commands come first, then the usual text commands.
    func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        guard let cell = editing else { return menu }
        let table = tableMenu(for: cell)
        let items = table.items
        table.removeAllItems()
        for (i, item) in items.enumerated() { menu.insertItem(item, at: i) }
        menu.insertItem(.separator(), at: items.count)
        return menu
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        guard let owner, !owner.isExport, let window else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard let start = cell(at: p) else { return }
        owner.canvas?.selectedElement = nil
        if event.modifierFlags.contains(.shift), let anchor {
            endEditing()
            extent = start
            selectRange(anchor, start)
            window.makeFirstResponder(self)
            return
        }
        if event.modifierFlags.contains(.command) {
            endEditing()
            if selection.contains(start) { selection.remove(start) } else { selection.insert(start) }
            anchor = start
            window.makeFirstResponder(self)
            needsDisplay = true
            return
        }
        var current = start
        var dragged = false
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: NSEvent.foreverDuration,
                           mode: .eventTracking) { ev, stop in
            guard let ev, ev.type == .leftMouseDragged else {
                stop.pointee = true
                return
            }
            guard let cell = self.cell(at: self.convert(ev.locationInWindow, from: nil)) else { return }
            if cell != current || dragged {
                if !dragged { self.endEditing() }
                dragged = true
                current = cell
                self.selectRange(start, cell)
            }
        }
        if dragged {
            anchor = start
            extent = current
            window.makeFirstResponder(self)
        } else if editing == start {
            let index = editor.characterIndexForInsertion(at: editor.convert(p, from: self))
            editor.setSelectedRange(NSRange(location: index, length: 0))
        } else {
            beginEditing(start, at: p)
        }
    }

    private func selectRange(_ a: CellRef, _ b: CellRef) {
        var cells: Set<CellRef> = []
        for r in min(a.row, b.row)...max(a.row, b.row) {
            for c in min(a.column, b.column)...max(a.column, b.column) { cells.insert(CellRef(row: r, column: c)) }
        }
        selection = cells
        needsDisplay = true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let owner, !owner.isExport, let cell = cell(at: convert(event.locationInWindow, from: nil)) else { return nil }
        if !selection.contains(cell) {
            endEditing()
            selection = [cell]
            anchor = cell
            needsDisplay = true
        }
        return tableMenu(for: cell)
    }

    // MARK: Keys (cells selected, not typing)

    override func keyDown(with event: NSEvent) {
        let anchor = self.anchor ?? selection.first ?? CellRef(row: 0, column: 0)
        switch event.keyCode {
        case 36, 76: // Return
            beginEditing(anchor)
        case 51, 117: // Delete
            model.clear(selection)
        case 48: // Tab
            model.tab(from: anchor, backward: event.modifierFlags.contains(.shift))
            continueAtFocusRequest()
        case 53: // Escape: select the whole table container
            selection = []
            needsDisplay = true
            owner?.canvas?.selectedElement = owner
            window?.makeFirstResponder(owner?.canvas)
        case 123, 124, 125, 126:
            let shift = event.modifierFlags.contains(.shift)
            var next = shift ? (extent ?? anchor) : anchor
            switch event.keyCode {
            case 123: next.column -= 1
            case 124: next.column += 1
            case 125: next.row += 1
            default: next.row -= 1
            }
            guard model.contains(next) else { return }
            if shift {
                extent = next
                selectRange(anchor, next)
                self.anchor = anchor
            } else {
                selection = [next]
                self.anchor = next
                extent = nil
                needsDisplay = true
            }
        default:
            // Typing replaces the cell's text, as in a spreadsheet.
            if let characters = event.characters, !characters.isEmpty,
               characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
               !event.modifierFlags.contains(.command) {
                model.setText("", anchor)
                beginEditing(anchor)
                editor.insertText(characters, replacementRange: editor.selectedRange())
            } else {
                super.keyDown(with: event)
            }
        }
    }

    @objc func copy(_ sender: Any?) {
        guard !selection.isEmpty else { return }
        let rowRange = selection.map(\.row), columnRange = selection.map(\.column)
        let text = (rowRange.min()!...rowRange.max()!).map { r in
            (columnRange.min()!...columnRange.max()!).map { c in
                selection.contains(CellRef(row: r, column: c)) ? model.text(CellRef(row: r, column: c)) : ""
            }.joined(separator: "\t")
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func cut(_ sender: Any?) {
        copy(sender)
        model.clear(selection)
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string),
              let start = selection.min(by: { ($0.row, $0.column) < ($1.row, $1.column) }) else { return }
        for (r, line) in text.components(separatedBy: "\n").enumerated() {
            for (c, value) in line.components(separatedBy: "\t").enumerated() {
                let cell = CellRef(row: start.row + r, column: start.column + c)
                if model.contains(cell) { model.setText(value, cell) }
            }
        }
        model.onChange?()
    }

    @objc override func selectAll(_ sender: Any?) {
        selectRange(CellRef(row: 0, column: 0), CellRef(row: rows - 1, column: columns - 1))
    }

    // MARK: Menu

    private func paletteMenu(_ title: String, _ apply: @escaping (NSColor?) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        for (name, color) in Palette.shading {
            let entry = ClosureMenuItem(name) { [weak self] in
                self?.endEditing()
                apply(color)
            }
            entry.image = Palette.swatch(color)
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("No Color") { [weak self] in
            self?.endEditing()
            apply(nil)
        })
        item.submenu = menu
        return item
    }

    private func perform(_ body: @escaping () -> Void) -> () -> Void {
        { [weak self] in
            self?.endEditing()
            body()
        }
    }

    func tableMenu(for cell: CellRef) -> NSMenu {
        let model = self.model
        let selected = selection.isEmpty ? [cell] : selection
        let menu = NSMenu()
        let many = selected.count > 1
        menu.addItem(paletteMenu(many ? "Shade Selected Cells (\(selected.count))" : "Cell Shading") { color in
            model.setShading(color, cells: selected)
        })
        if model.data.headerRow || cell.row == 0 {
            menu.addItem(paletteMenu("Header Row Shading") { model.setShading($0, scope: .headerRow, at: cell) })
        }
        menu.addItem(paletteMenu("Row Shading") { color in
            model.setShading(color, cells: Set(selected.flatMap { s in (0..<model.data.columnCount).map { CellRef(row: s.row, column: $0) } }))
        })
        menu.addItem(paletteMenu("Column Shading") { color in
            model.setShading(color, cells: Set(selected.flatMap { s in model.data.rows.indices.map { CellRef(row: $0, column: s.column) } }))
        })
        menu.addItem(paletteMenu("Table Shading") { model.setShading($0, scope: .table, at: cell) })
        menu.addItem(.separator())
        let selectedRows = Set(selected.map(\.row)).sorted(), selectedColumns = Set(selected.map(\.column)).sorted()
        menu.addItem(ClosureMenuItem("Insert Row Above", handler: perform { model.insertRow(at: selectedRows.first ?? cell.row) }))
        menu.addItem(ClosureMenuItem("Insert Row Below", handler: perform { model.insertRow(at: (selectedRows.last ?? cell.row) + 1) }))
        menu.addItem(ClosureMenuItem("Insert Column Left", handler: perform { model.addColumn(at: selectedColumns.first ?? cell.column) }))
        menu.addItem(ClosureMenuItem("Insert Column Right", handler: perform { model.addColumn(at: (selectedColumns.last ?? cell.column) + 1) }))
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(selectedRows.count > 1 ? "Delete \(selectedRows.count) Rows" : "Delete Row", handler: perform {
            for r in selectedRows.reversed() where model.data.rows.count > 1 { model.deleteRow(r) }
        }))
        menu.addItem(ClosureMenuItem(selectedColumns.count > 1 ? "Delete \(selectedColumns.count) Columns" : "Delete Column", handler: perform {
            for c in selectedColumns.reversed() where model.data.columnCount > 1 { model.removeColumn(c) }
        }))
        menu.addItem(ClosureMenuItem(many ? "Clear Selected Cells" : "Clear Cell", handler: perform { model.clear(selected) }))
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Sort Ascending by This Column", handler: perform { model.sort(byColumn: cell.column, ascending: true) }))
        menu.addItem(ClosureMenuItem("Sort Descending by This Column", handler: perform { model.sort(byColumn: cell.column, ascending: false) }))
        menu.addItem(ClosureMenuItem("Header Row", state: model.data.headerRow, handler: perform { model.toggleHeaderRow() }))
        menu.addItem(ClosureMenuItem("Select Entire Table") { [weak self] in
            self?.endEditing()
            self?.selectAll(nil)
            self?.window?.makeFirstResponder(self)
        })
        return menu
    }
}

final class TableElementView: ElementView {
    let model: TableModel
    let grid: TableGridView

    override init(element: PageElement) {
        model = TableModel(data: element.table ?? TableData(rows: 2, columns: 2), width: element.width)
        grid = TableGridView(model: model)
        super.init(element: element)
        grid.owner = self
        model.onChange = { [weak self] in
            self?.controller?.markDirty()
            self?.grid.relayout()
        }
        model.onWidthChange = { [weak self] delta in
            guard let self else { return }
            self.setWidth(self.frame.width + delta)
            self.canvas?.updateSize()
        }
        addSubview(grid)
        finishSetup()
        grid.relayout()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var minWidth: CGFloat { 120 }

    override func layoutContent() {
        let content = contentFrame
        let widthChanged = model.width != content.width
        grid.frame = NSRect(x: 0, y: Self.gripHeight, width: content.width, height: content.height)
        if widthChanged {
            model.width = content.width
            grid.relayout()
        }
    }

    func fitTableHeight(_ height: CGFloat) {
        let target = Self.gripHeight + ceil(height)
        guard abs(frame.height - target) > 0.5 else { return }
        let oldHeight = frame.height
        setFrameSize(NSSize(width: frame.width, height: target))
        heightChanged(from: oldHeight)
        canvas?.updateSize()
    }

    func beginEditing(_ cell: CellRef) {
        grid.beginEditing(cell)
    }

    override func makeElement() -> PageElement {
        var e = super.makeElement()
        var table = model.data
        table.columnWidths = (0..<table.columnCount).map { Double(model.columnWidth($0)) }
        e.table = table
        return e
    }

    override func indexText() -> String? {
        model.data.rows.map { $0.joined(separator: " ") }.joined(separator: "\n")
    }

    override func contextMenu() -> NSMenu {
        let menu = super.contextMenu()
        menu.addItem(.separator())
        let table = grid.tableMenu(for: CellRef(row: 0, column: 0))
        let items = table.items
        table.removeAllItems()
        for item in items { menu.addItem(item) }
        return menu
    }
}

/// A table drawn for printing and PDF export.
final class TableSnapshotView: ElementView {
    private let table: TableData
    private var rowHeights: [CGFloat] = []

    override init(element: PageElement) {
        table = element.table ?? TableData(rows: 1, columns: 1)
        super.init(element: element)
        finishSetup()
        measure()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func columnWidths() -> [CGFloat] {
        let total = table.columnWidths.reduce(0, +)
        return table.columnWidths.map { total > 0 ? bounds.width * $0 / total : 80 }
    }

    private func attributes(header: Bool) -> [NSAttributedString.Key: Any] {
        let font = header ? NSFontManager.shared.convert(Prefs.defaultFont, toHaveTrait: .boldFontMask) : Prefs.defaultFont
        return [.font: font, .foregroundColor: NSColor.black]
    }

    private func measure() {
        let widths = columnWidths()
        rowHeights = table.rows.enumerated().map { r, row in
            let attrs = attributes(header: table.headerRow && r == 0)
            return row.enumerated().map { c, text in
                let width = (c < widths.count ? widths[c] : 80) - 12
                let rect = (text.isEmpty ? " " : text).boundingRect(with: NSSize(width: max(width, 10), height: .greatestFiniteMagnitude),
                                                                     options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                                     attributes: attrs)
                return ceil(rect.height) + 10
            }.max() ?? 24
        }
        setFrameSize(NSSize(width: frame.width, height: Self.gripHeight + rowHeights.reduce(0, +)))
    }

    override func draw(_ dirtyRect: NSRect) {
        let widths = columnWidths()
        var y = Self.gripHeight
        for (r, row) in table.rows.enumerated() {
            let height = r < rowHeights.count ? rowHeights[r] : 24
            var x: CGFloat = 0
            let header = table.headerRow && r == 0
            for (c, text) in row.enumerated() {
                let width = c < widths.count ? widths[c] : 80
                let cell = NSRect(x: x, y: y, width: width, height: height)
                (table.shade(r, c)?.nsColor ?? NSColor.white).setFill()
                cell.fill()
                NSColor(white: 0.6, alpha: 1).setStroke()
                NSBezierPath(rect: cell.insetBy(dx: 0.25, dy: 0.25)).stroke()
                var attrs = attributes(header: header)
                if table.textIsLight(r, c) { attrs[.foregroundColor] = NSColor.white }
                text.draw(with: cell.insetBy(dx: 6, dy: 5), options: [.usesLineFragmentOrigin, .usesFontLeading],
                          attributes: attrs)
                x += width
            }
            y += height
        }
    }
}
