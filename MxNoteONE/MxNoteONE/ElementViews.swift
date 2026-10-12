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
