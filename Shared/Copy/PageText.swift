//
//  PageText.swift
//  Shared by MxDataHUB and MxAcctMGR (MxAppsIOS/Shared/Copy)
//
//  Copying a whole page or one section of it as text. SwiftUI selects within one Text at a time, so a drag can't run
//  across a page's paragraphs, cards and grids. Instead Edit ▸ Copy Page Text, and Copy Section on a section's
//  context menu, read the text the page shows through accessibility (the same text VoiceOver reads) and lay it out
//  as it stands on screen: things side by side on one line separated by tabs (a grid's columns, cards in a row),
//  lines top to bottom, a blank line where a gap separates blocks. It pastes into a note, an email or a spreadsheet.
//
//  A view marks what can be copied with .copyableText(id) (the page, a section — .copySection(title) adds Copy
//  Section to its context menu); a card with .copyBlock() is copied whole, so cards side by side follow one another
//  instead of mixing line by line; an image that stands for a value (a dot in a grid) says what it means with
//  .copyText("✓").
//

import AppKit
import SwiftUI

@MainActor
enum PageText {
    /// The identifier of the page (the screen's content), for Copy Page Text.
    static let page = "mx.copy.page"
    /// Marks an element whose accessibility label is part of the copied text (an image standing for a value).
    static let valueMark = "mx.copy.value"
    /// Marks a card copied whole (its lines together), and the prefix of a section's identifier.
    static let blockMark = "mx.copy.block"
    static func section(_ title: String) -> String { "mx.copy.section." + title }

    /// The text of the element marked `id` in the key window, laid out as on screen; nil if there's none.
    static func text(of id: String, in window: NSWindow? = nil) -> String? {
        guard let window = window ?? NSApp.keyWindow ?? NSApp.mainWindow, let root = window.contentView,
              let element = find(id, in: root, depth: 0) else { return nil }
        var pieces: [Piece] = []
        collect(element, into: &pieces, depth: 0)
        let text = layout(pieces)
        return text.isEmpty ? nil : text
    }

    /// Copies the element's text; beeps when there's nothing to copy.
    static func copy(_ id: String) {
        guard let text = text(of: id) else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }


    // MARK: Reading

    private struct Piece {
        var text: String
        var frame: CGRect
        /// A card's text, several lines: copied as a paragraph of its own, not as a cell of a line.
        var isBlock = false
    }

    // SwiftUI's accessibility objects answer the NSAccessibility methods without declaring the protocol, so they are
    // asked through Objective-C (a cast to NSAccessibilityProtocol would skip them: buttons, images, cards).
    private static func children(_ element: Any) -> [Any] {
        ((element as AnyObject).accessibilityChildren?() as? [Any]) ?? []
    }
    private static func identifier(_ element: Any) -> String? { (element as AnyObject).accessibilityIdentifier?() }
    private static func role(_ element: Any) -> NSAccessibility.Role? { (element as AnyObject).accessibilityRole?() ?? nil }
    private static func label(_ element: Any) -> String? { (element as AnyObject).accessibilityLabel?() ?? nil }
    private static func value(_ element: Any) -> Any? { (element as AnyObject).accessibilityValue?() ?? nil }
    /// Its frame on screen; an element with no place of its own (an empty frame) gives .zero.
    private static func frame(_ element: Any) -> CGRect {
        let f = (element as AnyObject).accessibilityFrame?() ?? .zero
        return f.isNull || f.isInfinite || !f.origin.x.isFinite || !f.origin.y.isFinite || !f.width.isFinite || !f.height.isFinite ? .zero : f
    }

    private static func find(_ id: String, in element: Any, depth: Int) -> Any? {
        guard depth < 80 else { return nil }
        if identifier(element) == id { return element }
        for child in children(element) {
            if let found = find(id, in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    private static func collect(_ element: Any, into pieces: inout [Piece], depth: Int) {
        guard depth < 80 else { return }
        if identifier(element) == blockMark {
            var inner: [Piece] = []
            for child in children(element) { collect(child, into: &inner, depth: depth + 1) }
            let text = layout(inner)
            if !text.isEmpty { pieces.append(Piece(text: text, frame: frame(element), isBlock: true)) }
            return
        }
        let role = role(element)
        let frame = frame(element)
        let isValue = identifier(element) == valueMark
        var text: String?
        if isValue {
            text = label(element) ?? ""
        } else if role == .staticText || role == .textField || role == .textArea || role == .link {
            text = (value(element) as? String).flatMap { $0.isEmpty ? nil : $0 } ?? label(element)
        } else if role == .button || role == .menuButton {
            // Cards, report names and other things drawn as buttons carry their words as the button's label.
            text = label(element)
        } else if role == .popUpButton {
            text = value(element) as? String
        }
        if let text {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // A value mark stands even when it is empty: it keeps its column in a grid.
            if !t.isEmpty || isValue, frame.width > 0 { pieces.append(Piece(text: t, frame: frame)) }
            if role != .link && role != .button { return }
        }
        // Images and other controls aren't text; their children (and a button's, beside its label) may be.
        for child in children(element) { collect(child, into: &pieces, depth: depth + 1) }
    }

    // MARK: Laying out

    /// Pieces side by side make one line (tab-separated, left to right); lines go top to bottom, with a blank line
    /// where a gap of more than a line separates them.
    private static func layout(_ pieces: [Piece]) -> String {
        // Screen coordinates: y grows upward, so the top of the page has the largest y.
        let sorted = pieces.sorted { $0.frame.midY != $1.frame.midY ? $0.frame.midY > $1.frame.midY : $0.frame.minX < $1.frame.minX }
        var lines: [(top: CGFloat, bottom: CGFloat, items: [Piece])] = []
        for piece in sorted {
            // On the line if its middle is within the line, or the line's middle within it (a small dot beside a title).
            if var last = lines.last,
               piece.frame.midY <= last.top && piece.frame.midY >= last.bottom
                || (last.top + last.bottom) / 2 <= piece.frame.maxY && (last.top + last.bottom) / 2 >= piece.frame.minY {
                last.items.append(piece)
                last.top = max(last.top, piece.frame.maxY)
                last.bottom = min(last.bottom, piece.frame.minY)
                lines[lines.count - 1] = last
            } else {
                lines.append((piece.frame.maxY, piece.frame.minY, [piece]))
            }
        }
        var out: [String] = []
        var previousBottom: CGFloat?
        for line in lines {
            if let previousBottom, previousBottom - line.top > 14 { out.append("") }
            let items = line.items.sorted { $0.frame.minX < $1.frame.minX }
            // Cards side by side: each card's lines together, one card after the other.
            if items.contains(where: \.isBlock) {
                if !out.isEmpty, out.last != "" { out.append("") }
                out.append(items.map(\.text).joined(separator: "\n\n"))
                out.append("")
                previousBottom = line.bottom
                continue
            }
            var seen = Set<String>()
            let cells = items.compactMap { piece -> String? in
                // The same words twice on a line (a label and its copy for accessibility) count once.
                let key = piece.text + "@\(Int(piece.frame.minX))"
                return seen.insert(key).inserted ? piece.text.replacingOccurrences(of: "\t", with: " ") : nil
            }
            out.append(cells.joined(separator: "\t"))
            previousBottom = line.bottom
        }
        while out.last == "" { out.removeLast() }
        // No more than one blank line in a row.
        out = out.enumerated().filter { i, line in !(line.isEmpty && i > 0 && out[i - 1].isEmpty) }.map(\.element)
        return out.joined(separator: "\n")
    }
}

extension View {
    /// Marks a page or a section whose text Copy Page Text or Copy Section copies.
    func copyableText(_ id: String) -> some View {
        accessibilityElement(children: .contain).accessibilityIdentifier(id)
    }

    /// A section (a box with a title): its text can be copied, and its context menu has Copy Section.
    func copySection(_ title: String) -> some View {
        copyableText(PageText.section(title))
            .contextMenu {
                Button("Copy Section") { PageText.copy(PageText.section(title)) }
            }
    }

    /// A card copied whole: its lines together, and cards side by side one after the other.
    func copyBlock() -> some View {
        accessibilityElement(children: .contain).accessibilityIdentifier(PageText.blockMark)
    }

    /// An image that stands for a value (a dot in a grid): the words it means when the text is copied ("✓", "high").
    func copyText(_ words: String) -> some View {
        accessibilityLabel(Text(words)).accessibilityIdentifier(PageText.valueMark)
    }
}
