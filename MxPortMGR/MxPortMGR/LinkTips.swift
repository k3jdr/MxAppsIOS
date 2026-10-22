//
//  LinkTips.swift
//  MxPortMGR
//
//  A link's hover text (its "ScreenTip", as Word calls it), as in MxNoteONE (LinkTips.swift there): formatted text
//  written in the Link dialog and shown on the link's hover card. It is kept as RTF with the link. Hover text can hold
//  links of its own (the Link button or ⌘K, or an address typed in it); they open from the hover card.
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
        let string = tip.string
        let all = NSRange(location: 0, length: tip.length)
        guard tip.length > 0 else { return tip }
        var found: [(NSRange, URL)] = []
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for match in detector.matches(in: string, range: all) { if let url = match.url { found.append((match.range, url)) } }
        }
        if let notes = try? NSRegularExpression(pattern: "mxnoteone://[^\\s<>\"]+") {
            for match in notes.matches(in: string, range: all) {
                let text = (string as NSString).substring(with: match.range).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:)]}"))
                if let url = URL(string: text) { found.append((NSRange(location: match.range.location, length: (text as NSString).length), url)) }
            }
        }
        var result: NSMutableAttributedString?
        for (range, url) in found {
            var linked = false
            tip.enumerateAttribute(.link, in: range) { value, _, stop in if value != nil { linked = true; stop.pointee = true } }
            if linked || result?.attribute(.link, at: range.location, effectiveRange: nil) != nil { continue }
            if result == nil { result = NSMutableAttributedString(attributedString: tip) }
            result!.addAttribute(.link, value: url, range: range)
        }
        return result ?? tip
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

    /// The link the Link button changes: on the selection, or around the caret.
    var selectedLink: URL? {
        guard let tv = textView, let storage = tv.textStorage else { return nil }
        let range = tv.selectedRange()
        let index = range.length > 0 || linkRange(at: range.location) != nil ? range.location : range.location - 1
        guard index >= 0, index < storage.length, let value = storage.attribute(.link, at: index, effectiveRange: nil) else { return nil }
        return value as? URL ?? (value as? String).flatMap { URL(string: $0) }
    }

    /// Makes the selected words (or the link at the caret) a link to `url`, or the address itself where the caret
    /// is; nil takes the link off.
    func setLink(_ url: URL?) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        tv.window?.makeFirstResponder(tv)
        var range = tv.selectedRange()
        if range.length == 0, let around = linkRange(at: range.location) ?? linkRange(at: range.location - 1) { range = around }
        if range.length > 0 {
            change(range) { storage, range in
                if let url { storage.addAttribute(.link, value: url, range: range) } else { storage.removeAttribute(.link, range: range) }
            }
            return
        }
        guard let url else { return }
        let words = url.scheme == "mailto" ? String(url.absoluteString.dropFirst("mailto:".count)) : url.absoluteString
        var attrs = tv.typingAttributes
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
                .help("Link: make the selected words a link (⌘K) — to a web or email address")
                .popover(isPresented: $askingLink, arrowEdge: .bottom) { linkEditor }
            Button { box.clearFormatting() } label: { Image(systemName: "eraser") }.help("Clear formatting (links stay)")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .onAppear {
            let asking = $askingLink, address = $address, hadLink = $hadLink
            let editor = box
            editor.askForLink = { [weak editor] in
                hadLink.wrappedValue = editor?.selectedLink != nil
                address.wrappedValue = editor?.selectedLink?.absoluteString ?? ""
                asking.wrappedValue = true
            }
        }
    }

    /// The address for the hover text's link.
    private var linkEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Link in the hover text").font(.headline)
            TextField("Address:", text: $address, prompt: Text("https://…, an email address, or mxnoteone://…"))
                .frame(width: 300)
                .focused($addressFocused)
                .onSubmit(applyLink)
                .help("A web address, an email address, or a link copied in MxNoteONE (Copy Link to Page, Paragraph or Section)")
            HStack {
                if hadLink {
                    Button("Remove Link", role: .destructive) {
                        box.setLink(nil)
                        askingLink = false
                    }
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
        box.setLink(url)
    }
}
