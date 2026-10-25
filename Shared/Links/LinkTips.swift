//
//  LinkTips.swift
//  Shared by MxAcctMGR and MxDataHUB (MxAppsIOS/Shared/Links)
//
//  A link's hover text (its "ScreenTip", as Word calls it), as in MxNoteONE (LinkTips.swift there): formatted text
//  written in the Link dialog and shown on the link's hover card. It is kept as RTF with the link. Hover text can hold
//  links of its own (the Link button or ⌘K, or an address typed in it), each with words of its own to show (Text to
//  display, as in MxNoteONE's Link dialog); they open from the hover card.
//

import AppKit
import SwiftUI

nonisolated enum LinkRichText {
    /// Hover text as RTF (links included), or nil when it is empty.
    static func data(_ tip: NSAttributedString?) -> Data? {
        guard let tip, !tip.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return tip.rtf(from: NSRange(location: 0, length: tip.length), documentAttributes: [:])
    }

    static func text(_ data: Data?) -> NSAttributedString? {
        data.flatMap { NSAttributedString(rtf: $0, documentAttributes: nil) }
    }

    /// Hover text with its web and email addresses — and links copied in MxNoteONE (mxnoteone://…) — made into links.
    /// Words that are already a link keep theirs.
    static func linked(_ tip: NSAttributedString) -> NSAttributedString {
        guard tip.length > 0 else { return tip }
        var result: NSMutableAttributedString?
        for (range, url) in addresses(in: tip.string) {
            var linked = false
            tip.enumerateAttribute(.link, in: range) { value, _, stop in if value != nil { linked = true; stop.pointee = true } }
            if linked || result?.attribute(.link, at: range.location, effectiveRange: nil) != nil { continue }
            if result == nil { result = NSMutableAttributedString(attributedString: tip) }
            result!.addAttribute(.link, value: url, range: range)
        }
        return result ?? tip
    }

    /// The web and email addresses written in a text, and links copied in MxNoteONE (mxnoteone://…).
    static func addresses(in string: String) -> [(range: NSRange, url: URL)] {
        let all = NSRange(location: 0, length: (string as NSString).length)
        var found: [(range: NSRange, url: URL)] = []
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for match in detector.matches(in: string, range: all) { if let url = match.url { found.append((match.range, url)) } }
        }
        if let notes = try? NSRegularExpression(pattern: "mxnoteone://[^\\s<>\"]+") {
            for match in notes.matches(in: string, range: all) {
                let text = (string as NSString).substring(with: match.range).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:)]}"))
                if let url = URL(string: text) { found.append((NSRange(location: match.range.location, length: (text as NSString).length), url)) }
            }
        }
        return found
    }

    /// An address as words: an email address without its mailto:.
    static func addressText(_ url: URL) -> String {
        url.scheme == "mailto" ? String(url.absoluteString.dropFirst("mailto:".count)) : url.absoluteString
    }

    /// A link's address as typed: a web address (https:// is added), an email address, or any link with its scheme.
    static func url(fromAddress address: String) -> URL? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") || trimmed.hasPrefix("mailto:") { return URL(string: trimmed) }
        if trimmed.contains("@"), !trimmed.contains(" ") { return URL(string: "mailto:" + trimmed) }
        return URL(string: "https://" + trimmed)
    }
}

// MARK: - The hover text editor (Link dialog)

/// The editor's text view, for the formatting buttons.
final class TipEditorBox {
    weak var textView: TipTextView?
    var changed: (() -> Void)?

    static let baseFont = NSFont.systemFont(ofSize: 12)

    /// Bold or italic on (or off) for the selection, or for what's typed next.
    func toggle(_ trait: NSFontTraitMask) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let fm = NSFontManager.shared
        let range = tv.selectedRange()
        tv.window?.makeFirstResponder(tv)
        if range.length == 0 {
            let font = tv.typingAttributes[.font] as? NSFont ?? Self.baseFont
            let on = fm.traits(of: font).contains(trait)
            tv.typingAttributes[.font] = on ? fm.convert(font, toNotHaveTrait: trait) : fm.convert(font, toHaveTrait: trait)
            return
        }
        let first = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? Self.baseFont
        let on = fm.traits(of: first).contains(trait)
        change(range) { storage, range in
            storage.enumerateAttribute(.font, in: range) { value, r, _ in
                let font = value as? NSFont ?? Self.baseFont
                storage.addAttribute(.font, value: on ? fm.convert(font, toNotHaveTrait: trait) : fm.convert(font, toHaveTrait: trait), range: r)
            }
        }
    }

    /// Underline or strikethrough on (or off).
    func toggle(_ key: NSAttributedString.Key) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = tv.selectedRange()
        tv.window?.makeFirstResponder(tv)
        if range.length == 0 {
            let on = (tv.typingAttributes[key] as? Int ?? 0) != 0
            tv.typingAttributes[key] = on ? nil : NSUnderlineStyle.single.rawValue
            return
        }
        let on = (storage.attribute(key, at: range.location, effectiveRange: nil) as? Int ?? 0) != 0
        change(range) { storage, range in
            if on { storage.removeAttribute(key, range: range) } else { storage.addAttribute(key, value: NSUnderlineStyle.single.rawValue, range: range) }
        }
    }

    func setColor(_ color: NSColor?) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        tv.window?.makeFirstResponder(tv)
        if range.length == 0 {
            tv.typingAttributes[.foregroundColor] = color ?? NSColor.labelColor
            return
        }
        change(range) { storage, range in
            if let color { storage.addAttribute(.foregroundColor, value: color, range: range) } else { storage.removeAttribute(.foregroundColor, range: range) }
        }
    }

    func setSize(_ size: CGFloat) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        tv.window?.makeFirstResponder(tv)
        if range.length == 0 {
            let font = tv.typingAttributes[.font] as? NSFont ?? Self.baseFont
            tv.typingAttributes[.font] = NSFontManager.shared.convert(font, toSize: size)
            return
        }
        change(range) { storage, range in
            storage.enumerateAttribute(.font, in: range) { value, r, _ in
                storage.addAttribute(.font, value: NSFontManager.shared.convert(value as? NSFont ?? Self.baseFont, toSize: size), range: r)
            }
        }
    }

    /// Plain text again (the selection, or all of it).
    func clearFormatting() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        var range = tv.selectedRange()
        if range.length == 0 { range = NSRange(location: 0, length: storage.length) }
        change(range) { storage, range in
            var links: [(NSRange, Any)] = []
            storage.enumerateAttribute(.link, in: range) { value, r, _ in if let value { links.append((r, value)) } }
            storage.setAttributes([.font: Self.baseFont, .foregroundColor: NSColor.labelColor], range: range)
            // Links stay links.
            for (r, value) in links { storage.addAttribute(.link, value: value, range: r) }
        }
        tv.typingAttributes = [.font: Self.baseFont, .foregroundColor: NSColor.labelColor]
    }

    // MARK: Links in the hover text

    /// Asks the toolbar for the link's address (⌘K in the hover text).
    var askForLink: (() -> Void)?

    /// The whole link around a character.
    private func linkRange(at index: Int) -> NSRange? {
        guard let storage = textView?.textStorage, index >= 0, index < storage.length else { return nil }
        var range = NSRange()
        guard storage.attribute(.link, at: index, longestEffectiveRange: &range, in: NSRange(location: 0, length: storage.length)) != nil else { return nil }
        return range
    }

    /// What the Link button changes, and what its popover starts from.
    struct LinkSpot {
        /// The words: selected, a link's, or an address typed in the text; empty at the caret.
        var range: NSRange
        var text: String
        /// The link there (`isLink`), or the address the words are.
        var url: URL?
        var isLink: Bool
    }

    /// The selected words, the link around the caret, an address typed around the caret, or else the caret.
    func linkSpot() -> LinkSpot? {
        guard let tv = textView, let storage = tv.textStorage else { return nil }
        let string = storage.string as NSString
        var range = tv.selectedRange()
        if range.length == 0, let around = linkRange(at: range.location) ?? linkRange(at: range.location - 1) { range = around }
        if range.length == 0 {
            guard let typed = LinkRichText.addresses(in: storage.string)
                .first(where: { NSLocationInRange(range.location, $0.range) || NSMaxRange($0.range) == range.location })
            else { return LinkSpot(range: range, text: "", url: nil, isLink: false) }
            return LinkSpot(range: typed.range, text: string.substring(with: typed.range), url: typed.url, isLink: false)
        }
        let text = string.substring(with: range)
        if let value = storage.attribute(.link, at: range.location, effectiveRange: nil) {
            return LinkSpot(range: range, text: text, url: value as? URL ?? (value as? String).flatMap { URL(string: $0) }, isLink: true)
        }
        // Selected words that are an address themselves.
        let typed = LinkRichText.addresses(in: text).first { $0.range.length == (text as NSString).length }
        return LinkSpot(range: range, text: text, url: typed?.url, isLink: false)
    }

    /// Links the spot (the one the popover opened on, or the selection's) to `url`, showing `text` — or the words
    /// there, or else the address itself; nil takes the link off and keeps the words.
    func setLink(_ url: URL?, text: String? = nil, at spot: LinkSpot? = nil) {
        guard let tv = textView, let storage = tv.textStorage, let spot = spot ?? linkSpot(),
              NSMaxRange(spot.range) <= storage.length else { return }
        tv.window?.makeFirstResponder(tv)
        let range = spot.range
        guard let url else {
            if range.length > 0 { change(range) { storage, range in storage.removeAttribute(.link, range: range) } }
            return
        }
        let typed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let words = !typed.isEmpty ? typed : range.length > 0 ? spot.text : LinkRichText.addressText(url)
        if range.length > 0, words == spot.text {
            // The same words keep their formatting.
            change(range) { storage, range in storage.addAttribute(.link, value: url, range: range) }
            return
        }
        // Other words, formatted as the ones they replace (or as what's typed next).
        var attrs = range.length > 0 ? storage.attributes(at: range.location, effectiveRange: nil) : tv.typingAttributes
        attrs[.link] = url
        guard tv.shouldChangeText(in: range, replacementString: words) else { return }
        storage.replaceCharacters(in: range, with: NSAttributedString(string: words, attributes: attrs))
        tv.didChangeText()
        tv.setSelectedRange(NSRange(location: range.location + (words as NSString).length, length: 0))
        tv.typingAttributes[.link] = nil
        changed?()
    }

    private func change(_ range: NSRange, _ body: (NSTextStorage, NSRange) -> Void) {
        guard let tv = textView, let storage = tv.textStorage, tv.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        body(storage, range)
        storage.endEditing()
        tv.didChangeText()
        changed?()
    }
}

/// The hover text's text view: ⌘B ⌘I ⌘U format it, ⌘K links words in it.
final class TipTextView: NSTextView {
    weak var box: TipEditorBox?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "b": box?.toggle(.boldFontMask)
        case "i": box?.toggle(.italicFontMask)
        case "u": box?.toggle(.underlineStyle)
        case "k": box?.askForLink?()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}

/// A small formatted-text editor.
struct TipEditor: NSViewRepresentable {
    @Binding var text: NSAttributedString
    let box: TipEditorBox

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let tv = TipTextView(frame: .zero)
        tv.box = box
        tv.isRichText = true
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = true
        tv.textContainerInset = NSSize(width: 4, height: 4)
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.typingAttributes = [.font: TipEditorBox.baseFont, .foregroundColor: NSColor.labelColor]
        tv.textStorage?.setAttributedString(text)
        tv.delegate = context.coordinator
        tv.setAccessibilityLabel("Hover text")
        scroll.documentView = tv
        box.textView = tv
        box.changed = { [weak tv, coordinator = context.coordinator] in
            if let tv { coordinator.parent.text = NSAttributedString(attributedString: tv.attributedString()) }
        }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        // The dialog loaded another link's hover text (Link on: Symbol / Company).
        if let tv = nsView.documentView as? NSTextView, !tv.attributedString().isEqual(to: text) {
            tv.textStorage?.setAttributedString(text)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TipEditor
        init(_ parent: TipEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = NSAttributedString(attributedString: tv.attributedString())
        }

        /// A click in a link here edits it (the caret goes there); ⌘-click follows it.
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if NSApp.currentEvent?.modifierFlags.contains(.command) == true,
               let url = link as? URL ?? (link as? String).flatMap({ URL(string: $0) }) {
                LinkInfo.follow(url)
            } else {
                textView.setSelectedRange(NSRange(location: charIndex, length: 0))
            }
            return true
        }
    }
}

/// B I U S, size, colour, link and Clear for the hover text.
struct TipToolbar: View {
    let box: TipEditorBox
    @State private var askingLink = false
    @State private var address = ""
    /// The words the link shows.
    @State private var text = ""
    /// What the popover links: the words or caret it opened on.
    @State private var spot: TipEditorBox.LinkSpot?
    @State private var hadLink = false
    @FocusState private var addressFocused: Bool

    private static let colors: [(String, NSColor?)] = [
        ("Automatic", nil), ("Red", .systemRed), ("Orange", .systemOrange), ("Green", .systemGreen),
        ("Blue", .systemBlue), ("Purple", .systemPurple), ("Gray", .systemGray),
    ]

    var body: some View {
        HStack(spacing: 2) {
            Button { box.toggle(.boldFontMask) } label: { Image(systemName: "bold") }.help("Bold (⌘B)")
            Button { box.toggle(.italicFontMask) } label: { Image(systemName: "italic") }.help("Italic (⌘I)")
            Button { box.toggle(.underlineStyle) } label: { Image(systemName: "underline") }.help("Underline (⌘U)")
            Button { box.toggle(.strikethroughStyle) } label: { Image(systemName: "strikethrough") }.help("Strikethrough")
            Menu {
                ForEach([10, 11, 12, 13, 14, 16, 18], id: \.self) { size in
                    Button("\(size) pt") { box.setSize(CGFloat(size)) }
                }
            } label: { Image(systemName: "textformat.size") }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Text size")
            Menu {
                ForEach(Self.colors, id: \.0) { name, color in
                    Button(name) { box.setColor(color) }
                }
            } label: { Image(systemName: "paintpalette") }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Text colour")
            Button { box.askForLink?() } label: { Image(systemName: "link") }
                .help("Link (⌘K): make the selected words a link, or change a link's words and address — to a web or email address, or a page in MxNoteONE")
                .popover(isPresented: $askingLink, arrowEdge: .bottom) { linkEditor }
            Button { box.clearFormatting() } label: { Image(systemName: "eraser") }.help("Clear formatting (links stay)")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .onAppear {
            let asking = $askingLink, address = $address, text = $text, spot = $spot, hadLink = $hadLink
            let editor = box
            editor.askForLink = { [weak editor] in
                let found = editor?.linkSpot()
                spot.wrappedValue = found
                hadLink.wrappedValue = found?.isLink == true
                address.wrappedValue = found?.url?.absoluteString ?? ""
                text.wrappedValue = found?.text ?? ""
                asking.wrappedValue = true
            }
        }
    }

    /// The link's words and address, as MxNoteONE's Link dialog has them.
    private var linkEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(hadLink ? "Edit Link in the Hover Text" : "Link in the Hover Text").font(.headline)
            Form {
                TextField("Text to display:", text: $text, prompt: Text("The address itself"))
                    .onSubmit(applyLink)
                    .help("The words the hover text shows for the link (empty: the address itself). The address shows when the pointer rests on them.")
                TextField("Address:", text: $address, prompt: Text("https://…, an email address, or mxnoteone://…"))
                    .focused($addressFocused)
                    .onSubmit(applyLink)
                    .help("A web address, an email address, or a link copied in MxNoteONE (Copy Link to Page, Paragraph or Section)")
            }
            .frame(width: 380)
            // Words that were the address itself follow it as it changes.
            .onChange(of: address) { old, new in
                let shown = LinkRichText.url(fromAddress: old).map(LinkRichText.addressText)
                if text == old || text == shown { text = LinkRichText.url(fromAddress: new).map(LinkRichText.addressText) ?? new }
            }
            HStack {
                if hadLink {
                    Button("Remove Link", role: .destructive) {
                        box.setLink(nil, at: spot)
                        askingLink = false
                    }
                    .help("Keep the words, take the link off")
                }
                Spacer()
                Button("Cancel") { askingLink = false }
                    .keyboardShortcut(.cancelAction)
                Button(hadLink ? "Update" : "Link", action: applyLink)
                    .keyboardShortcut(.defaultAction)
                    .disabled(LinkRichText.url(fromAddress: address) == nil)
            }
        }
        .padding(12)
        .onAppear { addressFocused = true }
    }

    private func applyLink() {
        guard let url = LinkRichText.url(fromAddress: address) else { return }
        askingLink = false
        box.setLink(url, text: text, at: spot)
    }
}
