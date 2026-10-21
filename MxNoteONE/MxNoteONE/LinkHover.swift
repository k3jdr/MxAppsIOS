//
//  LinkHover.swift
//  MxNoteONE
//
//  Resting the pointer on a link shows a card, as in Word and OneNote:
//  where the link goes (a page's title and notebook › section, a web
//  address, an email address), "Click to follow", and buttons to edit
//  the link (the Edit Link dialog), copy its address or remove it. Links in
//  the link's hover text open from the card. The card goes away when the
//  pointer leaves the link and the card, or on a click or key press
//  elsewhere.
//

import AppKit
import SwiftUI

/// What the card does for one link (in a text box, or in a table cell).
struct LinkHoverActions {
    var edit: () -> Void
    var remove: () -> Void
    /// The link's own hover text (written in Edit Link), and its words.
    var tip: NSAttributedString?
    var text: String?
}

@MainActor
final class LinkHover {
    static let shared = LinkHover()

    private var popover: NSPopover?
    private var pending: DispatchWorkItem?
    private var poll: Timer?
    private var monitor: Any?
    private weak var view: NSView?
    private var url: URL?
    /// The link's rectangle in `view`.
    private var rect = NSRect.zero
    private var outsideSince: Date?
    private var actions: LinkHoverActions?

    /// The pointer on the screen.
    private var mouseLocation: NSPoint {
        #if DEBUG
        if let testMouse = Self.testMouse { return testMouse }
        #endif
        return NSEvent.mouseLocation
    }

    #if DEBUG
    /// Self-tests: where the pointer is, and the card's buttons.
    static var testMouse: NSPoint?
    func testEdit() { let a = actions; close(); a?.edit() }
    func testRemove() { let a = actions; close(); a?.remove() }
    var shownURL: URL? { isShown ? url : nil }
    var cardView: NSView? { popover?.contentViewController?.view }
    var shownTip: NSAttributedString? { isShown ? actions?.tip : nil }
    var shownText: String? { isShown ? actions?.text : nil }
    #endif

    /// How long the pointer rests on a link before the card shows.
    static let delay = 0.6

    var isShown: Bool { popover?.isShown == true }

    /// The pointer is over a link (`rect` in `view`), or over no link (`url` nil).
    func pointer(over url: URL?, rect: NSRect, in view: NSView, actions: @escaping () -> LinkHoverActions) {
        // (Mouse moves only come to the key window's text, so the card shows only where you're working.)
        guard let url, NotebookStore.shared.editor.tool == .type, view.window != nil else {
            pending?.cancel()
            pending = nil
            return
        }
        // Already showing (or about to show) this link.
        if self.view === view, self.url == url, rect.intersects(self.rect.insetBy(dx: -2, dy: -2)), isShown || pending != nil { return }
        pending?.cancel()
        if isShown { close() }
        self.view = view
        self.url = url
        self.rect = rect
        let work = DispatchWorkItem { [weak self, weak view] in
            guard let self, let view else { return }
            self.pending = nil
            // Still on the link?
            guard let window = view.window else { return }
            let mouse = view.convert(window.convertPoint(fromScreen: self.mouseLocation), from: nil)
            guard rect.insetBy(dx: -2, dy: -2).contains(mouse) else { return }
            self.show(url, actions: actions(), in: view)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
    }

    private func show(_ url: URL, actions: LinkHoverActions, in view: NSView) {
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = false
        var card = LinkCard(info: LinkInfo(url, tip: actions.tip, text: actions.text), edit: { [weak self] in
            self?.close()
            actions.edit()
        }, copy: { [weak self] in
            LinkInfo.copy(url)
            self?.close()
        }, remove: { [weak self] in
            self?.close()
            actions.remove()
        })
        // A link in the hover text goes where it leads.
        card.open = { [weak self] target in
            self?.close()
            LinkInfo.follow(target)
        }
        let host = NSHostingController(rootView: card)
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        let wasKey = view.window?.isKeyWindow == true
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        // The card doesn't take the keyboard: typing goes on where it was.
        if wasKey { view.window?.makeKey() }
        // Opening the card sets the arrow; the pointer is still on the link (checkPointer keeps it so).
        NSCursor.pointingHand.set()
        self.popover = popover
        self.actions = actions
        outsideSince = nil
        poll = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { _ in
            MainActor.assumeIsolated { LinkHover.shared.checkPointer() }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { event in
            MainActor.assumeIsolated {
                let shared = LinkHover.shared
                if event.window == nil || event.window !== shared.popover?.contentViewController?.view.window { shared.close() }
            }
            return event
        }
    }

    /// Closes the card once the pointer has been off both the link and the card for a moment.
    private func checkPointer() {
        guard let popover, popover.isShown, let view, let window = view.window, window.isVisible else { return close() }
        let mouse = mouseLocation
        let linkOnScreen = window.convertToScreen(view.convert(rect, to: nil)).insetBy(dx: -4, dy: -4)
        let cardOnScreen = popover.contentViewController?.view.window?.frame.insetBy(dx: -6, dy: -6) ?? .zero
        // The gap between the link and the card counts as on it (on the way to the card's buttons).
        let low = min(linkOnScreen.minY, cardOnScreen.minY), high = max(linkOnScreen.maxY, cardOnScreen.maxY)
        let bridge = NSRect(x: linkOnScreen.minX, y: low, width: linkOnScreen.width, height: high - low)
        if linkOnScreen.contains(mouse) || cardOnScreen.contains(mouse) || bridge.contains(mouse) {
            outsideSince = nil
            // The card's own view sets the arrow as it opens: over the link, it's the pointing hand.
            if linkOnScreen.insetBy(dx: 2, dy: 2).contains(mouse), NSCursor.current != .pointingHand { NSCursor.pointingHand.set() }
        } else if let since = outsideSince {
            if Date().timeIntervalSince(since) > 0.3 { close() }
        } else {
            outsideSince = Date()
        }
    }

    func close() {
        pending?.cancel()
        pending = nil
        poll?.invalidate()
        poll = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        popover?.close()
        popover = nil
        url = nil
        actions = nil
    }
}

/// Where a link goes, in words.
struct LinkInfo {
    let url: URL
    /// The page's title, a web site's address or an email address.
    var title: String
    /// Notebook › section for a page, else the full address.
    var detail: String
    var symbol: String
    /// The hover text written for this link (Edit Link ▸ Hover text).
    var tip: NSAttributedString?
    /// The link's words in the notes.
    var text: String?
    /// For a page: the start of its text, and when it was last changed.
    var preview: String?
    var updated: Date?
    var isInternal: Bool { url.scheme == NotebookStore.linkScheme }

    @MainActor
    init(_ url: URL, tip: NSAttributedString? = nil, text: String? = nil) {
        self.url = url
        self.tip = tip?.length ?? 0 > 0 ? tip : nil
        let words = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.text = words?.isEmpty == false ? words : nil
        let store = NotebookStore.shared
        if url.scheme == NotebookStore.linkScheme {
            symbol = "doc.text"
            if let ref = store.resolve(url), let meta = store.meta(ref) {
                title = meta.displayTitle
                let nb = store.notebook(ref.notebookID)
                let section = nb?.manifest.sections.find(ref.sectionID)?.name
                detail = [nb?.name, section].compactMap { $0 }.joined(separator: " › ")
                if let target = ParagraphTarget(url), target.pin != nil {
                    // A pin on a map: its name, and its place and notes as the preview.
                    let pin = MapLinks.pin(for: url)
                    symbol = "mappin.and.ellipse"
                    title = pin?.title ?? (target.text.isEmpty ? "Pin" : target.text)
                    detail = "A pin on the map in “\(meta.displayTitle)” · " + detail
                    preview = pin.map { p in [p.address, p.notes].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ") }
                    if preview?.isEmpty == true { preview = nil }
                    updated = meta.modified
                    return
                }
                if url.query != nil { detail += " (a paragraph on the page)" }
                updated = meta.modified
                // The page's opening words (after its title).
                var body = meta.plainText.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                if body.hasPrefix(meta.title), !meta.title.isEmpty { body = String(body.dropFirst(meta.title.count)).trimmingCharacters(in: .whitespaces) }
                if !body.isEmpty { preview = body.count > 160 ? String(body.prefix(160)) + "…" : body }
            } else {
                let parts = url.pathComponents.filter { $0 != "/" }
                switch url.host() {
                case "section":
                    let nb = parts.first.flatMap(UUID.init(uuidString:)).flatMap { store.notebook($0) }
                    let node = parts.count > 1 ? UUID(uuidString: parts[1]).flatMap { nb?.manifest.sections.find($0) } : nil
                    title = node?.name ?? "Section not found"
                    detail = nb.map { "Section in \($0.name)" } ?? "Its notebook may be closed or deleted."
                    symbol = "folder"
                case "notebook":
                    let nb = parts.first.flatMap(UUID.init(uuidString:)).flatMap { store.notebook($0) }
                    title = nb?.name ?? "Notebook not found"
                    detail = nb == nil ? "It may be closed or deleted." : "Notebook"
                    symbol = "book.closed"
                default:
                    title = "Page not found"
                    detail = "The page may have been deleted, or its notebook isn't open."
                }
            }
        } else if url.scheme == "mailto" {
            symbol = "envelope"
            title = url.absoluteString.replacingOccurrences(of: "mailto:", with: "").components(separatedBy: "?").first ?? ""
            detail = "Email"
        } else if url.isFileURL {
            symbol = "doc"
            title = url.lastPathComponent
            detail = url.deletingLastPathComponent().path
        } else {
            symbol = "globe"
            title = url.host() ?? url.absoluteString
            detail = url.absoluteString
        }
    }

    /// Goes where a link leads: a page (or paragraph, pin…), a web page in the chosen browser, an email…
    @MainActor
    static func follow(_ url: URL) {
        if url.scheme == NotebookStore.linkScheme {
            NotebookStore.shared.openLink(url)
        } else if url.scheme == OneNoteImport.missingScheme {
            ImportActivity.shared.locateMissingPictures()
        } else {
            WebBrowser.open(url)
        }
    }

    static func copy(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
        pb.addTypes([.string], owner: nil)
        pb.setString(url.absoluteString, forType: .string)
    }
}

/// The hover card.
struct LinkCard: View {
    let info: LinkInfo
    let edit: () -> Void
    let copy: () -> Void
    let remove: () -> Void

    var preview = false
    /// Opens a link in the hover text (none in the dialog's preview).
    var open: ((URL) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let tip = info.tip {
                TipText(text: tip, open: open)
                Divider()
            }
            HStack(spacing: 6) {
                Image(systemName: info.symbol)
                    .foregroundStyle(Color.accentColor)
                Text(info.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if !info.detail.isEmpty {
                Text(info.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if let previewText = info.preview {
                Text(previewText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let updated = info.updated {
                Text("Updated \(updated.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            if let text = info.text, text != info.title, text != info.url.absoluteString {
                Text("Link text: “\(text)”")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Text(info.isInternal ? "Click to go to it" : info.url.scheme == "mailto" ? "Click to write an email"
                 : WebBrowser.isWeb(info.url) ? "Click to open in \(WebBrowser.current?.name ?? "your browser")" : "Click to follow the link")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Divider()
            HStack(spacing: 4) {
                Button(action: edit) { Label("Edit Link…", systemImage: "pencil") }
                    .help("Change the link's text or where it goes (Edit Link)")
                Button(action: copy) { Label("Copy", systemImage: "doc.on.doc") }
                    .help("Copy the link's address")
                Button("Remove Link", role: .destructive, action: remove)
                    .help("Keep the text, take the link off")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .focusable(false)
            .fixedSize()
            .disabled(preview)
        }
        .padding(10)
        .frame(minWidth: 250, maxWidth: 360, alignment: .leading)
    }
}

/// The hover text on the card, as written (fonts, colours, lines), with its links: a click opens one, and the
/// pointer over one shows where it goes.
struct TipText: NSViewRepresentable {
    let text: NSAttributedString
    var open: ((URL) -> Void)?

    /// The widest the hover text gets on the card.
    static let maxWidth: CGFloat = 340

    /// The text as shown: addresses made into links, and the card's font and colour where none were chosen.
    static func shown(_ text: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: NoteRichText.linked(text))
        let all = NSRange(location: 0, length: result.length)
        result.enumerateAttribute(.font, in: all) { value, range, _ in
            if value == nil { result.addAttribute(.font, value: TipEditorBox.baseFont, range: range) }
        }
        result.enumerateAttribute(.foregroundColor, in: all) { value, range, _ in
            if value == nil { result.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range) }
        }
        return result
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TipCardTextView {
        let tv = TipCardTextView(frame: .zero)
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.displaysLinkToolTips = true
        tv.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue,
                                 .cursor: NSCursor.pointingHand]
        tv.delegate = context.coordinator
        tv.setAccessibilityLabel("Hover text")
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return tv
    }

    func updateNSView(_ tv: TipCardTextView, context: Context) {
        context.coordinator.open = open
        let shown = Self.shown(text)
        if tv.textStorage?.isEqual(to: shown) != true { tv.textStorage?.setAttributedString(shown) }
    }

    /// As wide as the text's longest line (at most `maxWidth`), or the width offered; as tall as its lines.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TipCardTextView, context: Context) -> CGSize? {
        let offered = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let shown = Self.shown(text)
        let bounds = shown.boundingRect(with: NSSize(width: offered ?? Self.maxWidth, height: .greatestFiniteMagnitude),
                                        options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: offered ?? ceil(bounds.width), height: ceil(bounds.height))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var open: ((URL) -> Void)?

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL ?? (link as? String).flatMap({ URL(string: $0) }) else { return true }
            open?(url)
            return true
        }
    }
}

/// The card's hover text view: the first click on it (the card isn't the key window) follows a link.
final class TipCardTextView: NSTextView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension NoteTextView {
    /// The link under a point: its address, its range, and (for the card) the part of it on the pointer's line.
    func linkSpot(at point: NSPoint) -> (url: URL, range: NSRange, rect: NSRect)? {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let p = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = lm.glyphIndex(for: p, in: tc, fractionOfDistanceThroughGlyph: nil)
        guard lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc).contains(p) else { return nil }
        let index = lm.characterIndexForGlyph(at: glyph)
        guard index < storage.length else { return nil }
        var range = NSRange()
        guard let value = storage.attribute(.link, at: index, longestEffectiveRange: &range, in: NSRange(location: 0, length: storage.length)),
              let url = value as? URL ?? (value as? String).flatMap({ URL(string: $0) }) else { return nil }
        let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let line = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        var rect = lm.boundingRect(forGlyphRange: glyphs, in: tc).intersection(line)
        if rect.isEmpty { rect = lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc) }
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        return (url, range, rect)
    }

    /// Shows (or schedules) the hover card for the link under the pointer.
    func hoverLink(_ event: NSEvent) {
        let spot = linkSpot(at: convert(event.locationInWindow, from: nil))
        LinkHover.shared.pointer(over: spot?.url, rect: spot?.rect ?? .zero, in: self) { [weak self] in
            LinkHoverActions(edit: {
                guard let self, let spot else { return }
                self.window?.makeFirstResponder(self)
                self.setSelectedRange(NSRange(location: spot.range.location, length: 0))
                NotebookStore.shared.beginInsertLink()
            }, remove: {
                guard let self, let spot else { return }
                self.window?.makeFirstResponder(self)
                self.setSelectedRange(spot.range)
                TextFormatter.removeLink()
            }, tip: spot.flatMap { NoteRichText.tip(in: self?.textStorage ?? NSAttributedString(), at: $0.range.location) },
               text: spot.flatMap { ((self?.string ?? "") as NSString).substring(with: $0.range) })
        }
    }
}
