//
//  JoinLines.swift
//  MxNoteONE
//
//  Text copied from a PDF (or an email wrapped at 72 characters) ends every
//  line with a paragraph break, so in a text box its lines stop where the
//  PDF's column did, well short of the box's right edge, and a numbered item's
//  second line loses its indent. Pasting into a text box joins those lines back
//  into paragraphs that wrap at the box's edge; Format ▸ Join Lines (and the
//  text box's right-click menu) does the same for text already on a page.
//
//  A break joins when the line before it is full (most of the way across the
//  column the other lines reach) and the line after carries the sentence on:
//  not a new sentence after a full stop, a list item, a blank line or a
//  heading. Blank lines between paragraphs stay. A word hyphenated across the
//  break joins without the hyphen when it's a word as one (compul- sive), and
//  keeps it otherwise (self- esteem). Shift-Return line breaks are never joined,
//  and neither is code.
//
//  Paste joins only text that looks wrapped (a full line carried on in lower
//  case); Paste Options ▸ Paste Keeping Line Breaks pastes it as it was, and
//  ⌘Z after a paste puts the breaks back.
//

import AppKit

enum JoinLines {
    /// A break to take out: the end of one line up to the text of the next, and what goes there (a space, or nothing).
    struct Join: Equatable {
        let range: NSRange
        let replacement: String
    }

    /// A line counts as full from this share of the column across.
    static let fullShare: CGFloat = 0.7
    /// Pasted lines shorter than this aren't a PDF's column (a list of names, an address).
    static let pastedMinimumLength = 30

    private struct Line {
        let content: NSRange      // the line's text, without its break
        let terminator: NSRange   // the paragraph break after it (empty for the last line)
        let text: String          // without the spaces at either end
        let width: CGFloat
        var isBlank: Bool { text.isEmpty }
    }

    /// The breaks to join among the lines a range touches (whole lines; only breaks inside the range).
    /// `pasted`: only text that looks wrapped (see the file comment), with lines a column wide.
    static func joins(in text: NSAttributedString, range: NSRange, pasted: Bool) -> [Join] {
        let ns = text.string as NSString
        guard ns.length > 0, range.location <= ns.length else { return [] }
        let clipped = NSRange(location: range.location, length: min(range.length, ns.length - range.location))
        let span = ns.paragraphRange(for: clipped)
        let lines = Self.lines(of: text, in: span)
        guard lines.count >= 2 else { return [] }

        let widths = lines.filter { !$0.isBlank }.map(\.width).sorted(by: >)
        guard let column = widths.isEmpty ? nil : widths[min(widths.count - 1, widths.count / 5)], column > 0 else { return [] }

        var found: [Join] = []
        var carriesOn = false
        for i in 0..<(lines.count - 1) {
            let line = lines[i], next = lines[i + 1]
            // Only breaks inside the range (a paste: the ones it brought).
            guard line.terminator.length > 0, line.terminator.location >= clipped.location,
                  line.terminator.location < NSMaxRange(clipped) else { continue }
            guard !line.isBlank, !next.isBlank, line.width >= column * fullShare else { continue }
            if pasted, line.text.count < pastedMinimumLength { continue }
            guard let join = join(line, next, in: text) else { continue }
            if let last = line.text.last, let first = next.text.first,
               last.isLetter || last.isNumber || last == "," || last == "-", first.isLowercase {
                carriesOn = true
            }
            found.append(join)
        }
        return pasted && !carriesOn ? [] : found
    }

    /// Every break between two lines with text in a range (Join Lines on lines picked out by hand).
    static func allJoins(in text: NSAttributedString, range: NSRange) -> [Join] {
        let ns = text.string as NSString
        guard ns.length > 0 else { return [] }
        let clipped = NSRange(location: range.location, length: min(range.length, ns.length - range.location))
        let lines = Self.lines(of: text, in: ns.paragraphRange(for: clipped))
        guard lines.count >= 2 else { return [] }
        return (0..<(lines.count - 1)).compactMap { i -> Join? in
            let line = lines[i], next = lines[i + 1]
            guard !line.isBlank, !next.isBlank, line.terminator.length > 0,
                  line.terminator.location >= clipped.location, line.terminator.location < NSMaxRange(clipped) else { return nil }
            return Join(range: gap(line, next, in: ns), replacement: " ")
        }
    }

    /// The text with the joins made, every joined paragraph taking its first line's paragraph style.
    static func applying(_ joins: [Join], to text: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        var starts: [Int] = []   // where each joined paragraph starts, in the result
        for join in joins.sorted(by: { $0.range.location > $1.range.location }) {
            result.replaceCharacters(in: join.range, with: join.replacement)
            starts = starts.map { $0 > join.range.location ? $0 - join.range.length + (join.replacement as NSString).length : $0 }
            starts.append((result.string as NSString).paragraphRange(for: NSRange(location: join.range.location, length: 0)).location)
        }
        let ns = result.string as NSString
        for start in Set(starts) where start < ns.length {
            let paragraph = ns.paragraphRange(for: NSRange(location: start, length: 0))
            if let style = result.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) {
                result.addAttribute(.paragraphStyle, value: style, range: paragraph)
            } else {
                result.removeAttribute(.paragraphStyle, range: paragraph)
            }
        }
        return result
    }

    // MARK: Text boxes

    /// After a paste into a text box: joins the pasted lines if they look wrapped. Runs a moment later, once the
    /// paste's undo step has closed (AppKit closes it when the key press or menu choice that pasted is done), so ⌘Z
    /// puts the breaks back before it takes the paste away.
    static func joinPasted(_ range: NSRange, in tv: NSTextView) {
        guard let storage = tv.textStorage, range.length > 0, NSMaxRange(range) <= storage.length,
              !CodeHighlighter.isCode(storage.attributes(at: range.location, effectiveRange: nil)) else { return }
        let joins = joins(in: storage, range: range, pasted: true)
        guard !joins.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            // Nothing else changed the text in the meantime.
            guard let now = tv.textStorage, now.length == storage.length, joins == Self.joins(in: now, range: range, pasted: true) else { return }
            let end = NSMaxRange(range)
            if let change = apply(joins, in: tv, actionName: "Join Lines") {
                tv.setSelectedRange(NSRange(location: end + change.delta, length: 0))
            }
        }
    }

    /// Format ▸ Join Lines: the selected lines, or all of the text box with nothing selected. Lines picked out by hand
    /// join anyway if none look wrapped.
    static func joinSelection(in tv: NSTextView) {
        guard let storage = tv.textStorage, storage.length > 0 else { return NSSound.beep() }
        let selection = tv.selectedRange()
        let whole = selection.length == 0
        let range = whole ? NSRange(location: 0, length: storage.length) : selection
        if CodeHighlighter.isCode(storage.attributes(at: min(range.location, storage.length - 1), effectiveRange: nil)) {
            return NSSound.beep()
        }
        var joins = joins(in: storage, range: range, pasted: false)
        if joins.isEmpty, !whole { joins = allJoins(in: storage, range: range) }
        guard let change = apply(joins, in: tv, actionName: "Join Lines") else { return NSSound.beep() }
        if !whole {
            let start = min(selection.location, change.range.location)
            tv.setSelectedRange(NSRange(location: start, length: max(0, NSMaxRange(selection) + change.delta - start)))
        }
    }

    /// Whether Join Lines has anything to do: the selection (or the text box) runs over more than one line.
    static func canJoin(in tv: NSTextView) -> Bool {
        let ns = tv.string as NSString
        let selection = tv.selectedRange()
        let range = selection.length == 0 ? NSRange(location: 0, length: ns.length) : selection
        guard NSMaxRange(range) <= ns.length else { return false }
        return ns.rangeOfCharacter(from: breaks, options: [], range: range).location != NSNotFound
    }

    /// Makes the joins as one change (one undo step): the paragraphs they touch are replaced together.
    private static func apply(_ joins: [Join], in tv: NSTextView, actionName: String) -> (range: NSRange, delta: Int)? {
        guard let storage = tv.textStorage, let first = joins.map(\.range.location).min(),
              let last = joins.map({ NSMaxRange($0.range) }).max() else { return nil }
        let ns = storage.string as NSString
        let touched = ns.paragraphRange(for: NSRange(location: first, length: last - first))
        let local = joins.map { Join(range: NSRange(location: $0.range.location - touched.location, length: $0.range.length),
                                     replacement: $0.replacement) }
        let joined = applying(local, to: storage.attributedSubstring(from: touched))
        // Its own undo step, not part of the paste or typing before it.
        tv.breakUndoCoalescing()
        guard tv.shouldChangeText(in: touched, replacementString: joined.string) else { return nil }
        storage.replaceCharacters(in: touched, with: joined)
        tv.didChangeText()
        tv.undoManager?.setActionName(actionName)
        return (touched, joined.length - touched.length)
    }

    // MARK: Lines

    /// Paragraph breaks: Return, a Windows or old Mac line end, a Unicode paragraph separator. Not Shift-Return (U+2028).
    private static let breaks = CharacterSet(charactersIn: "\n\r\u{2029}")

    private static func lines(of text: NSAttributedString, in span: NSRange) -> [Line] {
        let ns = text.string as NSString
        var lines: [Line] = []
        var start = span.location
        let end = NSMaxRange(span)
        while start <= end {
            let found = ns.rangeOfCharacter(from: breaks, options: [], range: NSRange(location: start, length: end - start))
            var terminator = found.location == NSNotFound ? NSRange(location: end, length: 0) : found
            if terminator.length > 0, ns.character(at: terminator.location) == 13, NSMaxRange(terminator) < ns.length,
               ns.character(at: NSMaxRange(terminator)) == 10 {
                terminator.length = 2   // \r\n
            }
            let content = NSRange(location: start, length: terminator.location - start)
            let raw = ns.substring(with: content)
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let width = trimmed.isEmpty ? 0 : ceil(text.attributedSubstring(from: content).size().width)
            if content.length > 0 || terminator.length > 0 {
                lines.append(Line(content: content, terminator: terminator, text: trimmed, width: width))
            }
            if terminator.length == 0 { break }
            start = NSMaxRange(terminator)
            if start == end {
                // The span ends with a break: an empty last line, so the line before still has a line after it.
                break
            }
        }
        return lines
    }

    /// The join for a break between two lines with text, or nil when the break ends a paragraph.
    private static func join(_ line: Line, _ next: Line, in text: NSAttributedString) -> Join? {
        let ns = text.string as NSString
        guard let first = next.text.first else { return nil }
        // Code keeps its lines; Shift-Return breaks aren't paragraph breaks at all.
        if let font = text.attribute(.font, at: line.content.location, effectiveRange: nil) as? NSFont, font.isFixedPitch { return nil }
        // A list item, To Do or numbered line starts a paragraph of its own.
        if startsListItem(next.text) { return nil }
        // A new sentence after one that ended at the line's end.
        let opening = next.text.drop { "\"'“‘([".contains($0) }.first ?? first
        if endsSentence(line.text), opening.isUppercase || opening.isNumber { return nil }
        // A heading (a bold line before text that isn't) stands on its own.
        if isBold(line.content, in: text), !isBold(NSRange(location: next.content.location, length: min(1, next.content.length)), in: text) {
            return nil
        }
        var gap = Self.gap(line, next, in: ns)
        var replacement = " "
        // A word hyphenated across the break.
        if let last = line.text.last, "-\u{2010}\u{00AD}".contains(last), first.isLowercase,
           line.text.dropLast().last?.isLetter == true {
            let hyphen = (ns.substring(with: line.content) as NSString).range(of: String(last), options: .backwards)
            let before = String(line.text.dropLast().reversed().prefix { $0.isLetter }.reversed())
            let after = String(next.text.prefix { $0.isLetter })
            if last == "\u{00AD}" || isWord(before + after) {
                gap = NSRange(location: line.content.location + hyphen.location, length: NSMaxRange(gap) - line.content.location - hyphen.location)
            }
            replacement = ""
        }
        return Join(range: gap, replacement: replacement)
    }

    /// From the end of one line's text (past its trailing spaces) to the start of the next line's text.
    private static func gap(_ line: Line, _ next: Line, in ns: NSString) -> NSRange {
        var from = NSMaxRange(line.content)
        while from > line.content.location, isSpace(ns.character(at: from - 1)) { from -= 1 }
        var to = next.content.location
        while to < NSMaxRange(next.content), isSpace(ns.character(at: to)) { to += 1 }
        return NSRange(location: from, length: to - from)
    }

    private static func isSpace(_ c: unichar) -> Bool { c == 32 || c == 9 || c == 0xA0 }

    private static func endsSentence(_ text: String) -> Bool {
        let core = text.reversed().drop { "\"'”’)]".contains($0) }
        guard let last = core.first else { return false }
        return ".!?:;…".contains(last)
    }

    private static let listMarker = try! NSRegularExpression(
        pattern: #"^([•◦▪▫‣⁃●○■□☐☑✓✔–—*+-]|\d{1,3}[.)]|[A-Za-z][.)]|\(\w{1,3}\))\s"#)

    static func startsListItem(_ text: String) -> Bool {
        listMarker.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    private static func isBold(_ range: NSRange, in text: NSAttributedString) -> Bool {
        guard range.length > 0 else { return false }
        var bold = true
        text.enumerateAttribute(.font, in: range) { value, sub, stop in
            let blank = (text.string as NSString).substring(with: sub).trimmingCharacters(in: .whitespaces).isEmpty
            if !blank, !((value as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) ?? false) {
                bold = false
                stop.pointee = true
            }
        }
        return bold
    }

    private static func isWord(_ word: String) -> Bool {
        guard word.count > 1 else { return false }
        return NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0).location == NSNotFound
    }
}
