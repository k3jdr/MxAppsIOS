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
        let responder = NSApp.keyWindow?.firstResponder
        if let tv = responder as? NoteTextView { return tv }
        // Table cells selected (not typing): format the cells' text instead (see perform).
        if let grid = TableGridView.active, grid.window != nil, grid.editing == nil, !grid.targetCells.isEmpty { return nil }
        if let tv = NoteTextView.current, let window = tv.window,
           !(window.firstResponder is PageCanvasView), !(window.firstResponder is TableGridView) { return tv }
        return nil
    }

    static func perform(_ body: (NoteTextView) -> Void) {
        guard let tv = target else {
            // Cells selected in a table: format each cell's text.
            if let grid = TableGridView.active, grid.applyToSelection(body) { return }
            NSSound.beep()
            return
        }
        if tv.window?.firstResponder !== tv { tv.window?.makeFirstResponder(tv) }
        body(tv)
        reportFormatting(tv)
    }

    // MARK: Code

    /// Format ▸ Format as Code: the selected paragraphs become a VS Code-style code block.
    static func formatAsCode(_ language: CodeLanguage = .auto) {
        perform { tv in CodeHighlighter.format(tv, language: language) }
    }

    /// Code theme for new code blocks; a code block at the cursor is re-coloured at once.
    static func setCodeTheme(_ theme: CodeTheme) {
        UserDefaults.standard.set(theme.name, forKey: CodeTheme.themeKey)
        guard let tv = target, let storage = tv.textStorage,
              let range = CodeHighlighter.blockRange(in: storage, at: tv.selectedRange().location) else { return }
        let language = (storage.attribute(.mxCodeLanguage, at: range.location, effectiveRange: nil) as? String)
            .flatMap(CodeLanguage.init(rawValue:)) ?? .auto
        tv.setSelectedRange(range)
        CodeHighlighter.format(tv, language: language, theme: theme)
    }

    private static func inCode(_ tv: NSTextView, at location: Int) -> Bool {
        guard let storage = tv.textStorage, storage.length > 0 else { return false }
        let index = min(location, storage.length - 1)
        if CodeHighlighter.isCode(storage.attributes(at: index, effectiveRange: nil)) { return true }
        return location > 0 && location == storage.length && CodeHighlighter.isCode(tv.typingAttributes)
    }

    /// Enter in code keeps the indent (one more level after { [ ( :); Enter on an empty last line leaves the block.
    private static func codeNewline(_ tv: NSTextView, paragraph text: String, range: NSRange, indent: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let storage = tv.textStorage, trimmed.isEmpty, !text.isEmpty || range.location > 0,
           NSMaxRange(range) >= storage.length || !CodeHighlighter.isCode(storage.attributes(at: NSMaxRange(range), effectiveRange: nil)) {
            if range.length > 0, tv.shouldChangeText(in: range, replacementString: nil) {
                storage.beginEditing()
                for key: NSAttributedString.Key in [.paragraphStyle, .mxCodeLanguage] { storage.removeAttribute(key, range: range) }
                storage.addAttributes(defaultAttributes, range: range)
                storage.endEditing()
                tv.didChangeText()
                tv.undoManager?.setActionName("End Code Block")
            }
            tv.typingAttributes = defaultAttributes
            return true
        }
        var next = indent
        if let last = trimmed.last, "{[(:".contains(last) { next += "    " }
        tv.insertText("\n" + next, replacementRange: tv.selectedRange())
        return true
    }

    /// Tab in code types four spaces (Shift-Tab removes up to four from the line's start).
    private static func codeTab(_ tv: NSTextView, outdent: Bool) -> Bool {
        guard let storage = tv.textStorage else { return false }
        if !outdent, tv.selectedRange().length == 0 {
            tv.insertText("    ", replacementRange: tv.selectedRange())
            return true
        }
        var edits: [(NSRange, String)] = []
        for range in paragraphRanges(tv) {
            if outdent {
                let text = paragraphText(storage, range)
                let spaces = text.prefix(4).prefix { $0 == " " }.count
                let remove = spaces > 0 ? spaces : (text.hasPrefix("\t") ? 1 : 0)
                if remove > 0 { edits.append((NSRange(location: range.location, length: remove), "")) }
            } else {
                edits.append((NSRange(location: range.location, length: 0), "    "))
            }
        }
        replace(tv, edits: edits, actionName: outdent ? "Outdent" : "Indent")
        return true
    }

    /// Places items after the spelling suggestions of a text view's right-click menu (or at the top).
    static func insertAfterSpelling(_ items: [NSMenuItem], into menu: NSMenu) {
        let spelling = menu.items.lastIndex { item in
            guard let action = item.action else { return false }
            let name = NSStringFromSelector(action).lowercased()
            return name.contains("ignorespelling") || name.contains("learnspelling") || name.contains("guess")
        }
        var index = 0
        if let spelling {
            index = spelling + 1
            if index < menu.items.count, menu.items[index].isSeparatorItem { index += 1 }
        }
        for item in items.reversed() { menu.insertItem(item, at: index) }
    }

    // MARK: Current formatting (Home ribbon)

    /// Shows the formatting of a text view's selection (or of what you'll type next) in the ribbon.
    static func reportFormatting(_ tv: NSTextView) {
        guard let storage = tv.textStorage else { return }
        let selection = tv.selectedRange()
        if selection.length == 0 || NSMaxRange(selection) > storage.length {
            report([tv.typingAttributes])
            return
        }
        var runs: [[NSAttributedString.Key: Any]] = []
        storage.enumerateAttributes(in: selection) { attrs, range, _ in
            let text = (storage.string as NSString).substring(with: range)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || runs.isEmpty { runs.append(attrs) }
        }
        report(runs)
    }

    /// Shows the formatting of whole texts (selected table cells) in the ribbon.
    static func reportFormatting(of texts: [NSAttributedString]) {
        var runs: [[NSAttributedString.Key: Any]] = []
        for text in texts {
            if text.length == 0 { continue }
            text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attrs, _, _ in runs.append(attrs) }
        }
        if runs.isEmpty { runs = [defaultAttributes] }
        report(runs)
    }

    private static func report(_ runs: [[NSAttributedString.Key: Any]]) {
        let fm = NSFontManager.shared
        let fonts = runs.map { $0[.font] as? NSFont ?? Prefs.defaultFont }
        let families = Set(fonts.map { $0.familyName ?? $0.fontName })
        let sizes = Set(fonts.map { ($0.pointSize * 2).rounded() / 2 })
        let editor = NotebookStore.shared.editor
        let family = families.count == 1 ? families.first : nil
        let size = sizes.count == 1 ? sizes.first : nil
        let bold = fonts.allSatisfy { fm.traits(of: $0).contains(.boldFontMask) }
        let italic = fonts.allSatisfy { fm.traits(of: $0).contains(.italicFontMask) }
        let underline = runs.allSatisfy { ($0[.underlineStyle] as? Int ?? 0) != 0 }
        let strike = runs.allSatisfy { ($0[.strikethroughStyle] as? Int ?? 0) != 0 }
        if editor.fontFamily != family { editor.fontFamily = family }
        if editor.fontSize != size { editor.fontSize = size }
        if editor.isBold != bold { editor.isBold = bold }
        if editor.isItalic != italic { editor.isItalic = italic }
        if editor.isUnderline != underline { editor.isUnderline = underline }
        if editor.isStrikethrough != strike { editor.isStrikethrough = strike }
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
                storage.removeAttribute(.mxAutoColor, range: range)
            } typing: { attrs in
                attrs[.foregroundColor] = color
                attrs[.mxAutoColor] = nil
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
    /// Enter, OneNote style: lists and To Dos continue (an empty item steps out a level, then ends the list);
    /// a new line keeps the paragraph's indent (an empty indented line steps out); after a heading comes Normal text.
    static func handleNewline(_ tv: NSTextView) -> Bool {
        guard let storage = tv.textStorage else { return false }
        let sel = tv.selectedRange()
        guard sel.length == 0 else { return false }
        let ns = storage.string as NSString
        let range = ns.paragraphRange(for: sel)
        let text = paragraphText(storage, range)
        let info = parseParagraph(text)
        let isTodo = info.tag == .todo
        let length = (text as NSString).length
        if inCode(tv, at: sel.location) {
            return codeNewline(tv, paragraph: text, range: range, indent: (text as NSString).substring(to: info.indent))
        }
        if info.list != nil || isTodo {
            let prefixEnd = info.indent + info.listLength + (isTodo ? info.tagLength : 0)
            guard sel.location >= range.location + prefixEnd else { return false }
            if length <= prefixEnd {
                if info.indent > 0 {
                    // Empty nested item: one level out.
                    replace(tv, edits: [(NSRange(location: range.location, length: 1), "")], actionName: "Outdent")
                } else {
                    replace(tv, edits: [(NSRange(location: range.location + info.indent, length: prefixEnd - info.indent), "")],
                            actionName: "End List")
                }
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
        let indent = (text as NSString).substring(to: info.indent)
        let atEnd = sel.location >= range.location + length
        let heading = length > 0 && atEnd ? headingStyle(storage.attributes(at: range.location, effectiveRange: nil)) : nil
        if !indent.isEmpty, length == info.indent, sel.location >= range.location + info.indent {
            // Empty indented line: one level out.
            replace(tv, edits: [(NSRange(location: range.location, length: 1), "")], actionName: "Outdent")
            return true
        }
        guard !indent.isEmpty || heading != nil else { return false }
        var nextAttrs = tv.typingAttributes
        nextAttrs[.link] = nil
        if heading != nil {
            nextAttrs = TextStyleKind.normal.attributes
            if let style = tv.typingAttributes[.paragraphStyle] { nextAttrs[.paragraphStyle] = style }
        }
        let insertion = NSMutableAttributedString(string: "\n", attributes: tv.typingAttributes)
        insertion.append(NSAttributedString(string: indent, attributes: nextAttrs))
        guard tv.shouldChangeText(in: sel, replacementString: insertion.string) else { return true }
        storage.replaceCharacters(in: sel, with: insertion)
        tv.didChangeText()
        tv.setSelectedRange(NSRange(location: sel.location + insertion.length, length: 0))
        tv.typingAttributes = nextAttrs
        return true
    }

    /// The heading style (Title, Heading 1–4) text is in, if any.
    static func headingStyle(_ attrs: [NSAttributedString.Key: Any]) -> TextStyleKind? {
        guard let font = attrs[.font] as? NSFont else { return nil }
        let fm = NSFontManager.shared
        for kind in [TextStyleKind.title, .heading1, .heading2, .heading3, .heading4] {
            let style = kind.attributes
            guard let styleFont = style[.font] as? NSFont, abs(styleFont.pointSize - font.pointSize) < 0.5,
                  fm.traits(of: styleFont).contains(.boldFontMask) == fm.traits(of: font).contains(.boldFontMask) else { continue }
            let color = (attrs[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB)
            let styleColor = (style[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB)
            if let color, let styleColor, abs(color.redComponent - styleColor.redComponent) < 0.02,
               abs(color.greenComponent - styleColor.greenComponent) < 0.02, abs(color.blueComponent - styleColor.blueComponent) < 0.02 {
                return kind
            }
        }
        return nil
    }

    /// Backspace, OneNote style: at the start of a tagged, bulleted or numbered paragraph the tag or marker goes
    /// (the text stays); at the start of an indented paragraph it steps out one level.
    static func handleBackspace(_ tv: NSTextView) -> Bool {
        guard let storage = tv.textStorage else { return false }
        let sel = tv.selectedRange()
        guard sel.length == 0, sel.location > 0 else { return false }
        let ns = storage.string as NSString
        let range = ns.paragraphRange(for: NSRange(location: sel.location, length: 0))
        let info = parseParagraph(paragraphText(storage, range))
        let offset = sel.location - range.location
        guard offset > 0 else { return false }
        if inCode(tv, at: sel.location) {
            let leading = (paragraphText(storage, range) as NSString).substring(to: info.indent)
            guard offset == info.indent, !leading.contains("\t"), info.indent > 0 else { return false }
            let remove = info.indent % 4 == 0 ? 4 : info.indent % 4
            replace(tv, edits: [(NSRange(location: sel.location - remove, length: remove), "")], actionName: "Outdent")
            return true
        }
        if info.tagLength > 0, offset == info.indent + info.listLength + info.tagLength {
            replace(tv, edits: [(NSRange(location: range.location + info.indent + info.listLength, length: info.tagLength), "")],
                    actionName: "Remove Tag")
            return true
        }
        if info.listLength > 0, offset == info.indent + info.listLength {
            replace(tv, edits: [(NSRange(location: range.location + info.indent, length: info.listLength), "")],
                    actionName: "Remove Bullet")
            return true
        }
        if info.indent > 0, offset == info.indent {
            replace(tv, edits: [(NSRange(location: range.location, length: 1), "")], actionName: "Outdent")
            return true
        }
        return false
    }

    /// ⌥⇧↑ / ⌥⇧↓ (OneNote): moves the selected paragraphs up or down past the neighbouring paragraph.
    static func moveParagraphs(_ tv: NSTextView, up: Bool) -> Bool {
        guard let storage = tv.textStorage, storage.length > 0 else { return true }
        let ns = storage.string as NSString
        let paragraphs = paragraphRanges(tv)
        guard let firstRange = paragraphs.first, let lastRange = paragraphs.last else { return true }
        let block = NSRange(location: firstRange.location, length: NSMaxRange(lastRange) - firstRange.location)
        let neighbor: NSRange
        if up {
            guard block.location > 0 else { NSSound.beep(); return true }
            neighbor = ns.paragraphRange(for: NSRange(location: block.location - 1, length: 0))
        } else {
            guard NSMaxRange(block) < ns.length else { NSSound.beep(); return true }
            neighbor = ns.paragraphRange(for: NSRange(location: NSMaxRange(block), length: 0))
        }
        let combined = up ? NSRange(location: neighbor.location, length: NSMaxRange(block) - neighbor.location)
                          : NSRange(location: block.location, length: NSMaxRange(neighbor) - block.location)
        let first = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: up ? block : neighbor))
        let second = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: up ? neighbor : block))
        // The piece that ends the text has no line break: give the front piece one and take it from the back.
        if !first.string.hasSuffix("\n") {
            let attrs = first.length > 0 ? first.attributes(at: first.length - 1, effectiveRange: nil) : tv.typingAttributes
            first.append(NSAttributedString(string: "\n", attributes: attrs))
            if second.string.hasSuffix("\n") { second.deleteCharacters(in: NSRange(location: second.length - 1, length: 1)) }
        }
        let result = NSMutableAttributedString(attributedString: first)
        result.append(second)
        guard tv.shouldChangeText(in: combined, replacementString: result.string) else { return true }
        storage.replaceCharacters(in: combined, with: result)
        tv.didChangeText()
        tv.undoManager?.setActionName(up ? "Move Paragraph Up" : "Move Paragraph Down")
        let movedLength = up ? first.length : second.length
        let movedStart = up ? combined.location : combined.location + first.length
        var selection = NSRange(location: movedStart, length: movedLength)
        if selection.length > 0, (storage.string as NSString).character(at: NSMaxRange(selection) - 1) == 0x0A { selection.length -= 1 }
        tv.setSelectedRange(selection)
        tv.scrollRangeToVisible(selection)
        return true
    }

    /// Whether the caret is on the first / last visual line of a text view.
    static func caretLine(_ tv: NSTextView) -> (first: Bool, last: Bool) {
        guard let lm = tv.layoutManager, let tc = tv.textContainer, let storage = tv.textStorage, storage.length > 0 else {
            return (true, true)
        }
        lm.ensureLayout(for: tc)
        let location = tv.selectedRange().location
        let caretLine: NSRect
        if location >= storage.length, !lm.extraLineFragmentRect.isEmpty {
            caretLine = lm.extraLineFragmentRect
        } else {
            let glyph = lm.glyphIndexForCharacter(at: min(location, storage.length - 1))
            caretLine = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        }
        let firstLine = lm.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        let lastLine = lm.extraLineFragmentRect.isEmpty
            ? lm.lineFragmentRect(forGlyphAt: max(0, lm.numberOfGlyphs - 1), effectiveRange: nil) : lm.extraLineFragmentRect
        return (caretLine.minY <= firstLine.minY + 0.5, caretLine.minY >= lastLine.minY - 0.5)
    }

    /// The caret's horizontal position in the text view.
    static func caretX(_ tv: NSTextView) -> CGFloat {
        guard let lm = tv.layoutManager, let tc = tv.textContainer, let storage = tv.textStorage, storage.length > 0 else {
            return tv.textContainerOrigin.x
        }
        let location = min(tv.selectedRange().location, storage.length)
        if location >= storage.length {
            let glyph = lm.glyphIndexForCharacter(at: storage.length - 1)
            return tv.textContainerOrigin.x + lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc).maxX
        }
        let glyph = lm.glyphIndexForCharacter(at: location)
        return tv.textContainerOrigin.x + lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc).minX
    }

    /// Tab / Shift-Tab in a list item indents or outdents the item.
    static func handleTab(_ tv: NSTextView, outdent: Bool) -> Bool {
        guard let storage = tv.textStorage else { return false }
        if inCode(tv, at: tv.selectedRange().location) { return codeTab(tv, outdent: outdent) }
        let paragraphs = paragraphRanges(tv)
        let infos = paragraphs.map { parseParagraph(paragraphText(storage, $0)) }
        // OneNote: text followed by Tab starts a table (⌥Tab types a tab character).
        if !outdent, paragraphs.count == 1, tv.selectedRange().length == 0, infos[0].list == nil, infos[0].tag == nil,
           let paragraph = paragraphs.first, tv.selectedRange().location > paragraph.location,
           !paragraphText(storage, paragraph).trimmingCharacters(in: .whitespaces).isEmpty,
           let owner = (tv as? NoteTextView)?.owner, let controller = owner.controller {
            controller.convertParagraphToTable(owner, paragraph: paragraph)
            return true
        }
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
    static func addLink(_ url: URL, title: String, in tv: NSTextView, range: NSRange, tip: NSAttributedString? = nil) {
        guard let storage = tv.textStorage else { return }
        tv.window?.makeFirstResponder(tv)
        let range = NSRange(location: min(range.location, storage.length),
                            length: min(range.length, storage.length - min(range.location, storage.length)))
        if range.length > 0 {
            changeAttributes(tv, ranges: [range], actionName: "Link") { storage, range in
                storage.addAttribute(.link, value: url, range: range)
                if let tip, tip.length > 0 { storage.addAttribute(.linkTip, value: tip, range: range) } else { storage.removeAttribute(.linkTip, range: range) }
            }
        } else {
            var attrs = tv.typingAttributes
            attrs[.link] = url
            attrs[.linkTip] = tip?.length ?? 0 > 0 ? tip : nil
            let text = NSAttributedString(string: title.isEmpty ? url.absoluteString : title, attributes: attrs)
            guard tv.shouldChangeText(in: range, replacementString: text.string) else { return }
            storage.replaceCharacters(in: range, with: text)
            tv.didChangeText()
            attrs[.link] = nil
            attrs[.linkTip] = nil
            tv.typingAttributes = attrs
            tv.setSelectedRange(NSRange(location: range.location + (text.string as NSString).length, length: 0))
        }
    }

    /// The link the caret is in (or the selection is within): its whole range and address.
    static func link(around selection: NSRange, in tv: NSTextView) -> (range: NSRange, url: URL)? {
        guard let storage = tv.textStorage, storage.length > 0 else { return nil }
        var probes = [selection.location]
        if selection.length == 0, selection.location > 0 { probes.append(selection.location - 1) }
        for probe in probes where probe < storage.length {
            var range = NSRange()
            guard let value = storage.attribute(.link, at: probe, longestEffectiveRange: &range,
                                                in: NSRange(location: 0, length: storage.length)) else { continue }
            let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
            // A selection that runs past the link isn't editing it.
            guard let url, NSMaxRange(selection) <= NSMaxRange(range) else { continue }
            return (range, url)
        }
        return nil
    }

    /// Edit Link: the link's text and address both change (the text keeps its formatting).
    static func replaceLink(_ url: URL, title: String, in tv: NSTextView, range: NSRange, tip: NSAttributedString? = nil) {
        guard let storage = tv.textStorage, NSMaxRange(range) <= storage.length else { return }
        let current = (storage.string as NSString).substring(with: range)
        guard !title.isEmpty, title != current else { return addLink(url, title: title, in: tv, range: range, tip: tip) }
        tv.window?.makeFirstResponder(tv)
        var attrs = range.length > 0 ? storage.attributes(at: range.location, effectiveRange: nil) : tv.typingAttributes
        attrs[.link] = url
        attrs[.linkTip] = tip?.length ?? 0 > 0 ? tip : nil
        guard tv.shouldChangeText(in: range, replacementString: title) else { return }
        storage.replaceCharacters(in: range, with: NSAttributedString(string: title, attributes: attrs))
        tv.didChangeText()
        tv.undoManager?.setActionName("Edit Link")
        tv.setSelectedRange(NSRange(location: range.location + (title as NSString).length, length: 0))
    }

    /// A link on the clipboard: an address copied with Copy Link, from a browser, or typed out (one line).
    static func clipboardLink() -> (url: URL, title: String?)? {
        let pb = NSPasteboard.general
        let title = pb.string(forType: NotebookStore.linkTitleType)
        // Rich text from elsewhere (with words of its own) pastes as it is.
        if title == nil, pb.availableType(from: [.rtf, .rtfd, .html]) != nil { return nil }
        let text = (pb.string(forType: .string) ?? (pb.readObjects(forClasses: [NSURL.self]) as? [URL])?.first?.absoluteString)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty, !text.contains(where: \.isWhitespace), let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), ["http", "https", "mailto", NotebookStore.linkScheme].contains(scheme) else { return nil }
        return (url, title)
    }

    /// Pasting a link into text: selected words become the link; otherwise the link goes in with its target's name.
    static func pasteLink(into tv: NSTextView) -> Bool {
        guard let (url, title) = clipboardLink() else { return false }
        let selection = tv.selectedRange()
        if selection.length > 0 {
            addLink(url, title: "", in: tv, range: selection)
        } else {
            addLink(url, title: title ?? url.absoluteString, in: tv, range: selection)
        }
        return true
    }

    /// Paste as Plain Text (⌥⇧⌘V): the text takes on the style where it goes.
    static func pastePlainText() {
        if let tv = target, tv.window?.firstResponder === tv {
            tv.pasteAsPlainText(nil)
        } else if let grid = TableGridView.active, grid.window?.firstResponder === grid {
            grid.pastePlain()
        } else {
            NotebookStore.shared.canvas?.pastePlainText()
        }
    }

    /// Paste with Formatting: fonts, colours and styles as they were copied.
    static func pasteWithFormatting() {
        if let tv = target, tv.window?.firstResponder === tv {
            tv.pasteAsRichText(nil)
        } else if let grid = TableGridView.active, grid.window?.firstResponder === grid {
            grid.paste(nil)
        } else {
            NotebookStore.shared.canvas?.paste()
        }
    }

    /// Right-click items for a text box or cell: Paste Options, and for a link Edit / Open / Copy Address / Remove.
    static func editMenuItems(for tv: NSTextView, at charIndex: Int) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let ns = tv.string as NSString
        if charIndex >= 0, charIndex < ns.length, let found = link(around: NSRange(location: charIndex, length: 0), in: tv) {
            items.append(ClosureMenuItem("Edit Link…") {
                tv.window?.makeFirstResponder(tv)
                tv.setSelectedRange(NSRange(location: charIndex, length: 0))
                NotebookStore.shared.beginInsertLink()
            })
            items.append(ClosureMenuItem("Open Link") {
                if found.url.scheme == NotebookStore.linkScheme { NotebookStore.shared.openLink(found.url) } else { WebBrowser.open(found.url) }
            })
            items.append(ClosureMenuItem("Copy Link Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([found.url as NSURL])
                NSPasteboard.general.addTypes([.string], owner: nil)
                NSPasteboard.general.setString(found.url.absoluteString, forType: .string)
            })
            items.append(ClosureMenuItem("Remove Link") {
                tv.window?.makeFirstResponder(tv)
                tv.setSelectedRange(found.range)
                removeLink()
            })
            items.append(.separator())
        }
        let paste = NSMenuItem(title: "Paste Options", action: nil, keyEquivalent: "")
        let options = NSMenu()
        options.addItem(ClosureMenuItem("Paste with Formatting") { tv.window?.makeFirstResponder(tv); tv.pasteAsRichText(nil) })
        options.addItem(ClosureMenuItem("Paste as Plain Text") { tv.window?.makeFirstResponder(tv); tv.pasteAsPlainText(nil) })
        paste.submenu = options
        paste.isEnabled = NSPasteboard.general.availableType(from: [.string, .rtf, .rtfd, .html]) != nil
        items.append(paste)
        return items
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
                storage.removeAttribute(.linkTip, range: range)
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
