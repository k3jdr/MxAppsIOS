//
//  LinkTips.swift
//  MxNoteONE
//
//  A link's hover text (its "ScreenTip", as Word calls it): formatted text
//  written in the Edit Link dialog and shown on the link's hover card. It's
//  kept on the link's words as an attribute, and saved with the text — RTF
//  has no place for it, so the saved text carries the tips in its document
//  comment (where each tip's range and formatted text are listed).
//

import AppKit

extension NSAttributedString.Key {
    /// A link's hover text (an NSAttributedString).
    static let linkTip = NSAttributedString.Key("MxLinkTip")
}

enum NoteRichText {
    private static let marker = "MxNoteONE-link-tips:"

    /// Text as RTFD, with its links' hover texts.
    static func data(_ text: NSAttributedString) -> Data? {
        let all = NSRange(location: 0, length: text.length)
        var tips: [[String: Any]] = []
        text.enumerateAttribute(.linkTip, in: all) { value, range, _ in
            guard let tip = value as? NSAttributedString, tip.length > 0,
                  let rtf = tip.rtf(from: NSRange(location: 0, length: tip.length), documentAttributes: [:]) else { return }
            tips.append(["at": range.location, "length": range.length, "rtf": rtf.base64EncodedString()])
        }
        var attributes: [NSAttributedString.DocumentAttributeKey: Any] = [:]
        if !tips.isEmpty, let json = try? JSONSerialization.data(withJSONObject: tips), let string = String(data: json, encoding: .utf8) {
            attributes[.comment] = marker + string
        }
        return text.rtfd(from: all, documentAttributes: attributes)
    }

    /// Text from RTFD (or RTF), with its links' hover texts back on them.
    static func text(_ data: Data) -> NSAttributedString? {
        var info: NSDictionary?
        guard let text = NSAttributedString(rtfd: data, documentAttributes: &info)
                ?? NSAttributedString(rtf: data, documentAttributes: &info) else { return nil }
        guard let comment = info?[NSAttributedString.DocumentAttributeKey.comment] as? String, comment.hasPrefix(marker),
              let json = comment.dropFirst(marker.count).data(using: .utf8),
              let tips = (try? JSONSerialization.jsonObject(with: json)) as? [[String: Any]] else { return text }
        let result = NSMutableAttributedString(attributedString: text)
        for tip in tips {
            guard let at = tip["at"] as? Int, let length = tip["length"] as? Int, at >= 0, length > 0, at + length <= result.length,
                  let rtf = (tip["rtf"] as? String).flatMap({ Data(base64Encoded: $0) }),
                  let value = NSAttributedString(rtf: rtf, documentAttributes: nil) else { continue }
            result.addAttribute(.linkTip, value: value, range: NSRange(location: at, length: length))
        }
        return result
    }

    /// The hover text of the link at a character, if it has one.
    static func tip(in text: NSAttributedString, at index: Int) -> NSAttributedString? {
        guard index >= 0, index < text.length else { return nil }
        return text.attribute(.linkTip, at: index, effectiveRange: nil) as? NSAttributedString
    }
}

// MARK: - The hover text editor (Edit Link dialog)

import SwiftUI

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
            storage.setAttributes([.font: Self.baseFont, .foregroundColor: NSColor.labelColor], range: range)
        }
        tv.typingAttributes = [.font: Self.baseFont, .foregroundColor: NSColor.labelColor]
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

/// The hover text's text view: ⌘B ⌘I ⌘U format it here (not the notes behind the dialog).
final class TipTextView: NSTextView {
    weak var box: TipEditorBox?

    override func mouseMoved(with event: NSEvent) { if pointerInside(event) { super.mouseMoved(with: event) } }
    override func cursorUpdate(with event: NSEvent) { if pointerInside(event) { super.cursorUpdate(with: event) } }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "b": box?.toggle(.boldFontMask)
        case "i": box?.toggle(.italicFontMask)
        case "u": box?.toggle(.underlineStyle)
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
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TipEditor
        init(_ parent: TipEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = NSAttributedString(attributedString: tv.attributedString())
        }
    }
}

/// B I U S, size, colour and Clear for the hover text.
struct TipToolbar: View {
    let box: TipEditorBox

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
            Button { box.clearFormatting() } label: { Image(systemName: "eraser") }.help("Clear formatting")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }
}
