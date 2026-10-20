//
//  LinkHover.swift
//  MxNoteONE
//
//  Resting the pointer on a link shows a card, as in Word and OneNote:
//  where the link goes (a page's title and notebook › section, a web
//  address, an email address), "Click to follow", and buttons to edit
//  the link (the Edit Link dialog), copy its address or remove it. The card
//  goes away when the pointer leaves the link and the card, or on a click
//  or key press elsewhere.
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
        let card = LinkCard(info: LinkInfo(url, tip: actions.tip, text: actions.text), edit: { [weak self] in
            self?.close()
            actions.edit()
        }, copy: { [weak self] in
            LinkInfo.copy(url)
            self?.close()
        }, remove: { [weak self] in
            self?.close()
            actions.remove()
        })
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let tip = info.tip {
                Text(LinkCard.attributed(tip))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
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

    /// Formatted hover text for SwiftUI: font size, bold, italic, underline, strikethrough and colour.
    static func attributed(_ text: NSAttributedString) -> AttributedString {
        var result = AttributedString()
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attrs, range, _ in
            var run = AttributedString((text.string as NSString).substring(with: range))
            let font = attrs[.font] as? NSFont
            let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
            var f = Font.system(size: font?.pointSize ?? 12)
            if traits.contains(.boldFontMask) { f = f.bold() }
            if traits.contains(.italicFontMask) { f = f.italic() }
            run.font = f
            if let color = attrs[.foregroundColor] as? NSColor { run.foregroundColor = Color(nsColor: color) }
            if (attrs[.underlineStyle] as? Int ?? 0) != 0 { run.underlineStyle = .single }
            if (attrs[.strikethroughStyle] as? Int ?? 0) != 0 { run.strikethroughStyle = .single }
            result += run
        }
        return result
    }
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
