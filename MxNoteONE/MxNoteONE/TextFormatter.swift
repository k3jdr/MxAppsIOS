//
//  TextFormatter.swift
//  MxNoteONE
//
//  Formatting commands from the ribbon and the menus, applied to the text
//  container being edited: character formatting, paragraph styles, bullets
//  and numbering, tags, links and inserted text. Every change goes through
//  shouldChangeText/didChangeText so it can be undone.
//

import AppKit

/// Paragraph styles (Home ▸ Styles, ⌥⌘1 – ⌥⌘3).
enum TextStyleKind: String, CaseIterable, Identifiable {
    case title, heading1, heading2, heading3, heading4, normal, quote, code

    var id: String { rawValue }

    var title: String {
        switch self {
        case .title: "Page Title"
        case .heading1: "Heading 1"
        case .heading2: "Heading 2"
        case .heading3: "Heading 3"
        case .heading4: "Heading 4"
        case .normal: "Normal"
        case .quote: "Quote"
        case .code: "Code"
        }
    }

    var attributes: [NSAttributedString.Key: Any] {
        let fm = NSFontManager.shared
        let base = Prefs.defaultFont
        let headingColor = NSColor(srgbRed: 0.16, green: 0.31, blue: 0.56, alpha: 1)
        var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.black]
        switch self {
        case .title:
            attrs[.font] = fm.convert(base, toSize: 26)
        case .heading1:
            attrs[.font] = fm.convert(fm.convert(base, toSize: 20), toHaveTrait: .boldFontMask)
            attrs[.foregroundColor] = headingColor
        case .heading2:
            attrs[.font] = fm.convert(fm.convert(base, toSize: 17), toHaveTrait: .boldFontMask)
            attrs[.foregroundColor] = headingColor
        case .heading3:
            attrs[.font] = fm.convert(fm.convert(base, toSize: 15), toHaveTrait: .boldFontMask)
            attrs[.foregroundColor] = NSColor(srgbRed: 0.24, green: 0.43, blue: 0.70, alpha: 1)
        case .heading4:
            attrs[.font] = fm.convert(fm.convert(base, toSize: 14), toHaveTrait: [.boldFontMask, .italicFontMask])
            attrs[.foregroundColor] = NSColor(white: 0.35, alpha: 1)
        case .normal:
            attrs[.font] = base
        case .quote:
            attrs[.font] = fm.convert(base, toHaveTrait: .italicFontMask)
            attrs[.foregroundColor] = NSColor(white: 0.38, alpha: 1)
        case .code:
            attrs[.font] = NSFont.monospacedSystemFont(ofSize: max(11, base.pointSize - 1), weight: .regular)
            attrs[.backgroundColor] = NSColor(white: 0.94, alpha: 1)
        }
        return attrs
    }
}

enum ListKind: Equatable {
    case bullet
    case number(Int)
}

/// Structure of a paragraph's start: indent, list marker, tag.
struct ParagraphInfo {
    var indent = 0
    var list: ListKind?
    var listLength = 0
    var tag: TagKind?
    var tagDone = false
    var tagLength = 0

    /// UTF-16 offset where the paragraph's own text starts.
    var contentStart: Int { indent + listLength + tagLength }
}

enum TextFormatter {
    static let bullet = "• "

    static var defaultAttributes: [NSAttributedString.Key: Any] {
        [.font: Prefs.defaultFont, .foregroundColor: NSColor.black]
    }

    /// The text container being edited (or the last one edited, if focus moved to the ribbon).
    static var target: NoteTextView? {
        if let tv = NSApp.keyWindow?.firstResponder as? NoteTextView { return tv }
        if let tv = NoteTextView.current, let window = tv.window, !(window.firstResponder is PageCanvasView) { return tv }
        return nil
    }

    static func perform(_ body: (NoteTextView) -> Void) {
        guard let tv = target else {
            NSSound.beep()
            return
        }
        if tv.window?.firstResponder !== tv { tv.window?.makeFirstResponder(tv) }
        body(tv)
    }

    // MARK: Paragraph parsing

    static func parseParagraph(_ text: String) -> ParagraphInfo {
        let ns = text as NSString
        var info = ParagraphInfo()
        var i = 0
        while i < ns.length, ns.character(at: i) == 0x20 || ns.character(at: i) == 0x09 { i += 1 }
        info.indent = i
        let rest = ns.substring(from: i)
        if rest.hasPrefix(bullet) {
            info.list = .bullet
            info.listLength = (bullet as NSString).length
        } else {
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            if !digits.isEmpty, digits.count < 5, rest.dropFirst(digits.count).hasPrefix(". "), let n = Int(digits) {
                info.list = .number(n)
                info.listLength = digits.count + 2
            }
        }
        let afterList = ns.substring(from: info.indent + info.listLength)
        outer: for kind in TagKind.allCases {
            for (symbol, done) in kind.symbols where afterList.hasPrefix(symbol + " ") {
                info.tag = kind
                info.tagDone = done
                info.tagLength = ((symbol + " ") as NSString).length
                break outer
            }
        }
        return info
    }

    /// Ranges of the paragraphs touched by the selection.
    static func paragraphRanges(_ tv: NSTextView) -> [NSRange] {
        let ns = tv.string as NSString
        var result: [NSRange] = []
        for value in tv.selectedRanges {
            let range = ns.paragraphRange(for: value.rangeValue)
            var location = range.location
            repeat {
                let p = ns.paragraphRange(for: NSRange(location: location, length: 0))
                if !result.contains(p) { result.append(p) }
                location = NSMaxRange(p)
            } while location < NSMaxRange(range)
        }
        return result.sorted { $0.location < $1.location }
    }

    private static func paragraphText(_ storage: NSTextStorage, _ range: NSRange) -> String {
        var text = (storage.string as NSString).substring(with: range)
        if text.hasSuffix("\n") { text.removeLast() }
        return text
    }

    // MARK: Editing helpers

    /// Attributes for inserted marker text, taken from the text at the location.
    private static func markerAttributes(_ tv: NSTextView, at location: Int) -> [NSAttributedString.Key: Any] {
        guard let storage = tv.textStorage else { return tv.typingAttributes }
        var attrs = location < storage.length && (storage.string as NSString).character(at: location) != 0x0A
            ? storage.attributes(at: location, effectiveRange: nil) : tv.typingAttributes
        attrs[.attachment] = nil
        attrs[.link] = nil
        return attrs
    }

    /// Replaces text in several places at once as one undoable change.
    static func replace(_ tv: NSTextView, edits: [(NSRange, String)], actionName: String) {
        guard let storage = tv.textStorage, !edits.isEmpty else { return }
        let sorted = edits.sorted { $0.0.location < $1.0.location }
        guard tv.shouldChangeText(inRanges: sorted.map { NSValue(range: $0.0) }, replacementStrings: sorted.map(\.1)) else {
            return
        }
        let caret = tv.selectedRange()
        var shift = 0
        storage.beginEditing()
        for (range, string) in sorted.reversed() {
            let attrs = markerAttributes(tv, at: range.location)
            storage.replaceCharacters(in: range, with: NSAttributedString(string: string, attributes: attrs))
        }
        storage.endEditing()
        for (range, string) in sorted where range.location <= caret.location {
            shift += (string as NSString).length - range.length
        }
        tv.didChangeText()
        tv.undoManager?.setActionName(actionName)
        let location = min(max(0, caret.location + shift), storage.length)
        tv.setSelectedRange(NSRange(location: location, length: min(caret.length, storage.length - location)))
    }

    /// Changes attributes of the selection, or of the typing attributes when nothing is selected.
    static func changeAttributes(_ tv: NSTextView, ranges explicit: [NSRange]? = nil, actionName: String,
                                 _ body: (NSTextStorage, NSRange) -> Void,
                                 typing: ((inout [NSAttributedString.Key: Any]) -> Void)? = nil) {
        guard let storage = tv.textStorage else { return }
        let ranges = (explicit ?? tv.selectedRanges.map(\.rangeValue)).filter { $0.length > 0 }
        if let typing {
            var attrs = tv.typingAttributes
            typing(&attrs)
            tv.typingAttributes = attrs
        }
        guard !ranges.isEmpty,
              tv.shouldChangeText(inRanges: ranges.map { NSValue(range: $0) }, replacementStrings: nil) else { return }
        storage.beginEditing()
        for range in ranges { body(storage, range) }
        storage.endEditing()
        tv.didChangeText()
        tv.undoManager?.setActionName(actionName)
    }

    private static func currentFont(_ tv: NSTextView) -> NSFont {
        let sel = tv.selectedRange()
        if sel.length > 0, let font = tv.textStorage?.attribute(.font, at: sel.location, effectiveRange: nil) as? NSFont {
            return font
        }
        return tv.typingAttributes[.font] as? NSFont ?? Prefs.defaultFont
    }

    private static func currentAttribute(_ tv: NSTextView, _ key: NSAttributedString.Key) -> Any? {
        let sel = tv.selectedRange()
        if sel.length > 0, let storage = tv.textStorage { return storage.attribute(key, at: sel.location, effectiveRange: nil) }
        return tv.typingAttributes[key]
    }

    // MARK: Character formatting

    static func toggleTrait(_ trait: NSFontTraitMask, name: String) {
        perform { tv in
            let fm = NSFontManager.shared
            let has = fm.traits(of: currentFont(tv)).contains(trait)
            let convert: (NSFont) -> NSFont = { has ? fm.convert($0, toNotHaveTrait: trait) : fm.convert($0, toHaveTrait: trait) }
            changeAttributes(tv, actionName: name) { storage, range in
                storage.enumerateAttribute(.font, in: range) { value, sub, _ in
                    storage.addAttribute(.font, value: convert(value as? NSFont ?? Prefs.defaultFont), range: sub)
                }
            } typing: { attrs in
                attrs[.font] = convert(attrs[.font] as? NSFont ?? Prefs.defaultFont)
            }
        }
    }

    static func toggleBold() { toggleTrait(.boldFontMask, name: "Bold") }
    static func toggleItalic() { toggleTrait(.italicFontMask, name: "Italic") }

    static func toggleLineAttribute(_ key: NSAttributedString.Key, name: String) {
        perform { tv in
            let on = (currentAttribute(tv, key) as? Int ?? 0) != 0
            let value = NSUnderlineStyle.single.rawValue
            changeAttributes(tv, actionName: name) { storage, range in
                if on { storage.removeAttribute(key, range: range) } else { storage.addAttribute(key, value: value, range: range) }
            } typing: { attrs in
                attrs[key] = on ? nil : value
            }
        }
    }

    static func toggleUnderline() { toggleLineAttribute(.underlineStyle, name: "Underline") }
    static func toggleStrikethrough() { toggleLineAttribute(.strikethroughStyle, name: "Strikethrough") }

    /// +1 superscript, -1 subscript.
    static func toggleScript(_ direction: Int) {
        perform { tv in
            let on = (currentAttribute(tv, .superscript) as? Int ?? 0) == direction
            changeAttributes(tv, actionName: direction > 0 ? "Superscript" : "Subscript") { storage, range in
                if on { storage.removeAttribute(.superscript, range: range) } else { storage.addAttribute(.superscript, value: direction, range: range) }
            } typing: { attrs in
                attrs[.superscript] = on ? nil : direction
            }
        }
    }

    static func setFontFamily(_ family: String) {
        perform { tv in
            let fm = NSFontManager.shared
            changeAttributes(tv, actionName: "Font") { storage, range in
                storage.enumerateAttribute(.font, in: range) { value, sub, _ in
                    storage.addAttribute(.font, value: fm.convert(value as? NSFont ?? Prefs.defaultFont, toFamily: family), range: sub)
                }
            } typing: { attrs in
                attrs[.font] = fm.convert(attrs[.font] as? NSFont ?? Prefs.defaultFont, toFamily: family)
            }
        }
    }

    static func setFontSize(_ size: CGFloat) {
        perform { tv in
            let fm = NSFontManager.shared
            changeAttributes(tv, actionName: "Font Size") { storage, range in
                storage.enumerateAttribute(.font, in: range) { value, sub, _ in
                    storage.addAttribute(.font, value: fm.convert(value as? NSFont ?? Prefs.defaultFont, toSize: size), range: sub)
                }
            } typing: { attrs in
                attrs[.font] = fm.convert(attrs[.font] as? NSFont ?? Prefs.defaultFont, toSize: size)
            }
        }
    }

    /// Grow (+) or shrink (-) the font.
    static func stepFontSize(_ delta: CGFloat) {
        perform { tv in
            let fm = NSFontManager.shared
            let step: (NSFont) -> NSFont = { fm.convert($0, toSize: max(6, min(144, $0.pointSize + delta))) }
            changeAttributes(tv, actionName: "Font Size") { storage, range in
                storage.enumerateAttribute(.font, in: range) { value, sub, _ in
                    storage.addAttribute(.font, value: step(value as? NSFont ?? Prefs.defaultFont), range: sub)
                }
            } typing: { attrs in
                attrs[.font] = step(attrs[.font] as? NSFont ?? Prefs.defaultFont)
            }
        }
    }

    static func setTextColor(_ color: NSColor) {
        perform { tv in
            changeAttributes(tv, actionName: "Font Color") { storage, range in
                storage.addAttribute(.foregroundColor, value: color, range: range)
            } typing: { attrs in
                attrs[.foregroundColor] = color
            }
        }
    }

    /// Text highlight colour (nil removes the highlight).
    static func setHighlight(_ color: NSColor?) {
        perform { tv in
            changeAttributes(tv, actionName: "Highlight") { storage, range in
                if let color { storage.addAttribute(.backgroundColor, value: color, range: range) } else { storage.removeAttribute(.backgroundColor, range: range) }
            } typing: { attrs in
                attrs[.backgroundColor] = color
            }
        }
    }

    static func clearFormatting() {
        perform { tv in
            let keys: [NSAttributedString.Key] = [.font, .foregroundColor, .backgroundColor, .underlineStyle,
                                                   .strikethroughStyle, .superscript, .baselineOffset, .paragraphStyle,
                                                   .shadow, .obliqueness, .expansion, .kern]
            changeAttributes(tv, actionName: "Clear Formatting") { storage, range in
                for key in keys { storage.removeAttribute(key, range: range) }
                storage.addAttributes(defaultAttributes, range: range)
            } typing: { attrs in
                for key in keys { attrs[key] = nil }
                attrs.merge(defaultAttributes) { $1 }
            }
        }
    }

    // MARK: Paragraph formatting

    static func modifyParagraphStyle(_ tv: NSTextView, actionName: String, _ body: @escaping (NSMutableParagraphStyle) -> Void) {
        let ranges = paragraphRanges(tv)
        changeAttributes(tv, ranges: ranges, actionName: actionName) { storage, range in
            storage.enumerateAttribute(.paragraphStyle, in: range) { value, sub, _ in
                let style = ((value as? NSParagraphStyle) ?? .default).mutableCopy() as! NSMutableParagraphStyle
                body(style)
                storage.addAttribute(.paragraphStyle, value: style, range: sub)
            }
        } typing: { attrs in
            let style = ((attrs[.paragraphStyle] as? NSParagraphStyle) ?? .default).mutableCopy() as! NSMutableParagraphStyle
            body(style)
            attrs[.paragraphStyle] = style
        }
    }

    static func setAlignment(_ alignment: NSTextAlignment) {
        perform { tv in
            modifyParagraphStyle(tv, actionName: "Alignment") { $0.alignment = alignment }
        }
    }

    /// Indent (+1) or outdent (-1) whole paragraphs.
    static func indent(_ direction: CGFloat) {
        perform { tv in
            modifyParagraphStyle(tv, actionName: direction > 0 ? "Indent" : "Outdent") { style in
                style.headIndent = max(0, style.headIndent + 28 * direction)
                style.firstLineHeadIndent = max(0, style.firstLineHeadIndent + 28 * direction)
            }
        }
    }

    static func setLineSpacing(_ multiple: CGFloat) {
        perform { tv in
            modifyParagraphStyle(tv, actionName: "Line Spacing") { $0.lineHeightMultiple = multiple }
        }
    }

    static func applyStyle(_ kind: TextStyleKind) {
        perform { tv in
            let ranges = paragraphRanges(tv)
            let attrs = kind.attributes
            changeAttributes(tv, ranges: ranges, actionName: kind.title) { storage, range in
                storage.removeAttribute(.backgroundColor, range: range)
                storage.addAttributes(attrs, range: range)
            } typing: { typing in
                typing[.backgroundColor] = nil
                typing.merge(attrs) { $1 }
            }
        }
    }

    // MARK: Lists

    static func toggleBullets() {
        perform { tv in
            guard let storage = tv.textStorage else { return }
            let paragraphs = paragraphRanges(tv)
            let infos = paragraphs.map { parseParagraph(paragraphText(storage, $0)) }
            let allBulleted = infos.allSatisfy { $0.list == .bullet }
            var edits: [(NSRange, String)] = []
            for (range, info) in zip(paragraphs, infos) {
                let markerRange = NSRange(location: range.location + info.indent, length: info.listLength)
                edits.append((markerRange, allBulleted ? "" : bullet))
            }
            replace(tv, edits: edits, actionName: "Bullets")
        }
    }

    static func toggleNumbering() {
        perform { tv in
            guard let storage = tv.textStorage else { return }
            let paragraphs = paragraphRanges(tv)
            let infos = paragraphs.map { parseParagraph(paragraphText(storage, $0)) }
            let allNumbered = infos.allSatisfy {
                if case .number = $0.list { return true }
                return false
            }
            var edits: [(NSRange, String)] = []
            for (n, (range, info)) in zip(paragraphs, infos).enumerated() {
                let markerRange = NSRange(location: range.location + info.indent, length: info.listLength)
                edits.append((markerRange, allNumbered ? "" : "\(n + 1). "))
            }
            replace(tv, edits: edits, actionName: "Numbering")
        }
    }

    // MARK: Tags

    /// Adds the tag to the selected paragraphs, or removes it if they all have it.
    static func toggleTag(_ kind: TagKind) {
        perform { tv in
            guard let storage = tv.textStorage else { return }
            let paragraphs = paragraphRanges(tv)
            let infos = paragraphs.map { parseParagraph(paragraphText(storage, $0)) }
            let allTagged = infos.allSatisfy { $0.tag == kind }
            var edits: [(NSRange, String)] = []
            for (range, info) in zip(paragraphs, infos) {
                let tagRange = NSRange(location: range.location + info.indent + info.listLength, length: info.tagLength)
                edits.append((tagRange, allTagged ? "" : kind.symbol + " "))
            }
            replace(tv, edits: edits, actionName: kind.title)
        }
    }

    static func removeTags() {
        perform { tv in
            guard let storage = tv.textStorage else { return }
            var edits: [(NSRange, String)] = []
            for range in paragraphRanges(tv) {
                let info = parseParagraph(paragraphText(storage, range))
                if info.tagLength > 0 {
                    edits.append((NSRange(location: range.location + info.indent + info.listLength, length: info.tagLength), ""))
                }
            }
            replace(tv, edits: edits, actionName: "Remove Tag")
        }
    }

    // MARK: Keys in lists

    /// Return in a list item continues the list; Return on an empty item ends it.
    static func handleNewline(_ tv: NSTextView) -> Bool {
        guard let storage = tv.textStorage else { return false }
        let sel = tv.selectedRange()
        guard sel.length == 0 else { return false }
        let ns = storage.string as NSString
        let range = ns.paragraphRange(for: sel)
        let text = paragraphText(storage, range)
        let info = parseParagraph(text)
        let isTodo = info.tag == .todo
        guard info.list != nil || isTodo else { return false }
        let prefixEnd = info.indent + info.listLength + (isTodo ? info.tagLength : 0)
        guard sel.location >= range.location + prefixEnd else { return false }
        if (text as NSString).length <= prefixEnd {
            replace(tv, edits: [(NSRange(location: range.location + info.indent, length: prefixEnd - info.indent), "")],
                    actionName: "End List")
            return true
        }
        var next = (text as NSString).substring(to: info.indent)
        switch info.list {
        case .bullet?: next += bullet
        case .number(let n)?: next += "\(n + 1). "
        case nil: break
        }
        if isTodo { next += TagKind.todo.symbol + " " }
        var attrs = tv.typingAttributes
        attrs[.link] = nil
        tv.typingAttributes = attrs
        tv.insertText("\n" + next, replacementRange: sel)
        return true
    }

    /// Tab / Shift-Tab in a list item indents or outdents the item.
    static func handleTab(_ tv: NSTextView, outdent: Bool) -> Bool {
        guard let storage = tv.textStorage else { return false }
        let paragraphs = paragraphRanges(tv)
        let infos = paragraphs.map { parseParagraph(paragraphText(storage, $0)) }
        guard infos.contains(where: { $0.list != nil || $0.tag != nil }) || outdent else { return false }
        var edits: [(NSRange, String)] = []
        for (range, info) in zip(paragraphs, infos) {
            if outdent {
                guard info.indent > 0 else { continue }
                edits.append((NSRange(location: range.location, length: 1), ""))
            } else {
                edits.append((NSRange(location: range.location, length: 0), "\t"))
            }
        }
        if edits.isEmpty { return outdent }
        replace(tv, edits: edits, actionName: outdent ? "Outdent" : "Indent")
        return true
    }

    // MARK: Inserting

    static func insert(_ string: String) {
        if let tv = target {
            tv.window?.makeFirstResponder(tv)
            tv.insertText(string, replacementRange: tv.selectedRange())
        } else {
            NotebookStore.shared.canvas?.insertTextBlock(string)
        }
    }

    static func insertDate() {
        insert(Date().formatted(date: .long, time: .omitted))
    }

    static func insertTime() {
        insert(Date().formatted(date: .omitted, time: .shortened))
    }

    static func insertDateTime() {
        insert(Date().formatted(date: .long, time: .shortened))
    }

    /// Makes the range a link; with an empty range, inserts the title as a link.
    static func addLink(_ url: URL, title: String, in tv: NSTextView, range: NSRange) {
        guard let storage = tv.textStorage else { return }
        tv.window?.makeFirstResponder(tv)
        let range = NSRange(location: min(range.location, storage.length),
                            length: min(range.length, storage.length - min(range.location, storage.length)))
        if range.length > 0 {
            changeAttributes(tv, ranges: [range], actionName: "Link") { storage, range in
                storage.addAttribute(.link, value: url, range: range)
            }
        } else {
            var attrs = tv.typingAttributes
            attrs[.link] = url
            let text = NSAttributedString(string: title.isEmpty ? url.absoluteString : title, attributes: attrs)
            guard tv.shouldChangeText(in: range, replacementString: text.string) else { return }
            storage.replaceCharacters(in: range, with: text)
            tv.didChangeText()
            attrs[.link] = nil
            tv.typingAttributes = attrs
            tv.setSelectedRange(NSRange(location: range.location + (text.string as NSString).length, length: 0))
        }
    }

    static func removeLink() {
        perform { tv in
            let sel = tv.selectedRange()
            guard let storage = tv.textStorage else { return }
            var range = sel
            if sel.length == 0, sel.location < storage.length {
                var effective = NSRange()
                if storage.attribute(.link, at: sel.location, effectiveRange: &effective) != nil { range = effective }
            }
            changeAttributes(tv, ranges: [range], actionName: "Remove Link") { storage, range in
                storage.removeAttribute(.link, range: range)
            }
        }
    }

    /// [[Page Name]] typed in text becomes a link to that page (created if needed).
    static func convertWikiLink(in tv: NSTextView) {
        guard let storage = tv.textStorage else { return }
        let sel = tv.selectedRange()
        guard sel.length == 0, sel.location >= 5 else { return }
        let ns = storage.string as NSString
        guard ns.substring(with: NSRange(location: sel.location - 2, length: 2)) == "]]" else { return }
        let lineStart = ns.paragraphRange(for: sel).location
        let before = ns.substring(with: NSRange(location: lineStart, length: sel.location - 2 - lineStart)) as NSString
        let open = before.range(of: "[[", options: .backwards)
        guard open.location != NSNotFound else { return }
        let name = before.substring(from: NSMaxRange(open)).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("]"), !name.contains("[") else { return }
        let range = NSRange(location: lineStart + open.location, length: sel.location - lineStart - open.location)
        DispatchQueue.main.async {
            guard let url = NotebookStore.shared.linkForPage(titled: name),
                  NSMaxRange(range) <= storage.length else { return }
            var attrs = storage.attributes(at: range.location, effectiveRange: nil)
            attrs[.link] = url
            let text = NSAttributedString(string: name, attributes: attrs)
            guard tv.shouldChangeText(in: range, replacementString: name) else { return }
            storage.replaceCharacters(in: range, with: text)
            tv.didChangeText()
            tv.undoManager?.setActionName("Link to Page")
            tv.setSelectedRange(NSRange(location: range.location + (name as NSString).length, length: 0))
            attrs[.link] = nil
            tv.typingAttributes = attrs
        }
    }
}
