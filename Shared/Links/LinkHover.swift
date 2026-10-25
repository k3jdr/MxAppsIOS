//
//  LinkHover.swift
//  Shared by MxAcctMGR and MxDataHUB (MxAppsIOS/Shared/Links)
//
//  Resting the pointer on a link shows a card, as in MxNoteONE (LinkHover.swift there), Word and OneNote: the link's
//  hover text, where the link goes (a web site, an email address), "Click to open", and buttons to edit the link (the
//  Link dialog), copy its address or remove it. Links in the hover text open from the card. The card goes away when
//  the pointer leaves the link and the card, or on a click or key press elsewhere. Other things can show a card of
//  their own the same way (pointer(over:rect:in:card:)): MxAcctMGR's reports, with your notes on them.
//

import AppKit
import SwiftUI

/// What the card does for one link.
struct LinkHoverActions {
    var edit: () -> Void
    var remove: () -> Void
    /// The link's own hover text (written in the Link dialog), and its words.
    var tip: NSAttributedString?
    var text: String?
    /// For a link copied in MxNoteONE: the page's (paragraph's, section's…) title, copied with it.
    var title: String?
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
    #endif

    /// How long the pointer rests on a link before the card shows.
    static let delay = 0.6

    var isShown: Bool { popover?.isShown == true }

    /// The pointer is over a link (`rect` in `view`), or over no link (`url` nil).
    func pointer(over url: URL?, rect: NSRect, in view: NSView, actions: @escaping () -> LinkHoverActions) {
        pointer(over: url, rect: rect, in: view) { [weak self] close in
            let actions = actions()
            self?.actions = actions
            return AnyView(Self.linkCard(url!, actions, close: close))
        }
    }

    /// The pointer is over something with a card of its own (MxAcctMGR's reports), told apart by `key`, or over
    /// nothing (nil). The card gets a function that closes it.
    func pointer(over key: URL?, rect: NSRect, in view: NSView, card: @escaping (_ close: @escaping () -> Void) -> AnyView) {
        guard let url = key, view.window != nil else {
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
            self.show(card, in: view)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
    }

    /// A link's card: its hover text, where it goes, and Edit Link…, Copy and Remove Link.
    private static func linkCard(_ url: URL, _ actions: LinkHoverActions, close: @escaping () -> Void) -> LinkCard {
        var card = LinkCard(info: LinkInfo(url, tip: actions.tip, text: actions.text, noteTitle: actions.title), edit: {
            close()
            actions.edit()
        }, copy: {
            LinkInfo.copy(url)
            close()
        }, remove: {
            close()
            actions.remove()
        })
        // A link in the hover text goes where it leads.
        card.open = { target in
            close()
            LinkInfo.follow(target)
        }
        return card
    }

    private func show(_ card: (_ close: @escaping () -> Void) -> AnyView, in view: NSView) {
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = false
        let host = NSHostingController(rootView: card { LinkHover.shared.close() })
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        let wasKey = view.window?.isKeyWindow == true
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        // The card doesn't take the keyboard: typing goes on where it was.
        if wasKey { view.window?.makeKey() }
        NSCursor.pointingHand.set()
        self.popover = popover
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
    /// A web site's address, an email address, or the title of what an MxNoteONE link opens.
    var title: String
    /// The full address, or (an MxNoteONE link) what it opens.
    var detail: String
    var symbol: String
    /// The hover text written for this link (Link ▸ Hover text).
    var tip: NSAttributedString?
    /// The link's words in the table.
    var text: String?

    /// MxNoteONE's links (Copy Link to Page, Paragraph, Section, Notebook or Pin): mxnoteone://page/NOTEBOOK/PAGE
    /// (?e=…&p=… a paragraph, ?e=…&pin=… a pin on a map), section/NOTEBOOK/SECTION, notebook/NOTEBOOK.
    static let noteScheme = "mxnoteone"
    /// What MxNoteONE puts on the pasteboard beside a copied link: its title.
    static let noteTitleType = NSPasteboard.PasteboardType("com.k3jdr.mxnoteone.link-title")

    var isNote: Bool { url.scheme == Self.noteScheme }

    /// Where a link copied in MxNoteONE is found: the general pasteboard (a named one in Debug self-tests,
    /// -linkPasteboard NAME, so tests leave the clipboard alone).
    static var pasteboard: NSPasteboard {
        #if DEBUG
        if let name = UserDefaults.standard.string(forKey: "linkPasteboard") { return NSPasteboard(name: NSPasteboard.Name(name)) }
        #endif
        return .general
    }

    init(_ url: URL, tip: NSAttributedString? = nil, text: String? = nil, noteTitle: String? = nil) {
        self.url = url
        self.tip = tip?.length ?? 0 > 0 ? tip : nil
        let words = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.text = words?.isEmpty == false ? words : nil
        if url.scheme == Self.noteScheme {
            // These apps can't read MxNoteONE's notebooks: the title is the one copied with the link.
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let kind: String
            switch url.host() {
            case "section": (symbol, kind) = ("folder", "A section")
            case "notebook": (symbol, kind) = ("book.closed", "A notebook")
            default:
                if query.contains(where: { $0.name == "pin" }) { (symbol, kind) = ("mappin.and.ellipse", "A pin on a map") }
                else if query.contains(where: { $0.name == "e" }) { (symbol, kind) = ("text.alignleft", "A paragraph") }
                else { (symbol, kind) = ("doc.text", "A page") }
            }
            let named = noteTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            title = named?.isEmpty == false ? named! : kind + " in MxNoteONE"
            detail = kind + " in your MxNoteONE notebooks"
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

    var isWeb: Bool { url.scheme == "http" || url.scheme == "https" }

    /// The app that opens web pages (the default browser).
    static var browserName: String? {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) else { return nil }
        return FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }

    /// The app that opens this link, if any (MxNoteONE for its links, once it has registered them).
    var opener: String? {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
        return FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }

    /// Goes where a link leads: a web page in the default browser, an email, a page in MxNoteONE…
    static func follow(_ url: URL) {
        guard !NSWorkspace.shared.open(url) else { return }
        let alert = NSAlert()
        alert.messageText = "No app opens this link"
        alert.informativeText = url.scheme == noteScheme
            ? "Links copied in MxNoteONE open in MxNoteONE, from the version that opens links from other apps on. Install the updated MxNoteONE, open it once, and try again.\n\n\(url.absoluteString)"
            : url.absoluteString
        alert.runModal()
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
            if let text = info.text, text != info.title, text != info.url.absoluteString {
                Text("Link text: “\(text)”")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Text(info.url.scheme == "mailto" ? "Click to write an email"
                 : info.isWeb ? "Click to open in \(LinkInfo.browserName ?? "your browser")"
                 : info.isNote ? (info.opener.map { "Click to open in \($0)" } ?? "Opens in MxNoteONE once it's updated")
                 : "Click to follow the link")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Divider()
            HStack(spacing: 4) {
                Button(action: edit) { Label("Edit Link…", systemImage: "pencil") }
                    .help("Change the link's text, address or hover text (the Link dialog, ⌘K)")
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
        let result = NSMutableAttributedString(attributedString: LinkRichText.linked(text))
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

    /// The tallest the hover text gets on the card. Longer text scrolls, with a scroll bar that stays visible (the
    /// system's overlay scroll bars stay hidden until you scroll, so nothing showed there was more).
    static let maxHeight: CGFloat = 220

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(frame: .zero)
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        // Shown only when the text is taller than the card, and then always (not only while scrolling).
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .legacy
        let tv = TipCardTextView(frame: .zero)
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.displaysLinkToolTips = true
        tv.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue,
                                 .cursor: NSCursor.pointingHand]
        tv.delegate = context.coordinator
        tv.setAccessibilityLabel("Hover text")
        scroll.documentView = tv
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.open = open
        guard let tv = scroll.documentView as? TipCardTextView else { return }
        let shown = Self.shown(text)
        if tv.textStorage?.isEqual(to: shown) != true {
            tv.textStorage?.setAttributedString(shown)
            tv.scroll(.zero)
        }
    }

    /// As wide as the text's longest line (at most `maxWidth`), or the width offered; as tall as its lines, up to
    /// `maxHeight` — beyond that the text scrolls beside a scroll bar.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let offered = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let shown = Self.shown(text)
        func measure(_ width: CGFloat) -> CGRect {
            shown.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                               options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
        let bounds = measure(offered ?? Self.maxWidth)
        if ceil(bounds.height) <= Self.maxHeight {
            return CGSize(width: offered ?? ceil(bounds.width), height: ceil(bounds.height))
        }
        return CGSize(width: offered ?? Self.maxWidth, height: Self.maxHeight)
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
