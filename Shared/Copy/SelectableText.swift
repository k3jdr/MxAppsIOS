//
//  SelectableText.swift
//  Shared by MxDataHUB and MxAcctMGR (MxAppsIOS/Shared/Copy)
//
//  A block of read-only text that can be selected across all its lines. SwiftUI selects within one Text at a time,
//  so a panel built of many (labels, values, a heading per section) could only be copied a word or a line at once.
//  Here headings, label / value rows and columns are one text: drag across any of it, ⌘A, ⌘C or right-click ▸ Copy.
//  It is as tall as its text, for use inside a scroll view. Links in it (RichLines.links, .bullets with addresses)
//  open with a click, as on a web page.
//

import AppKit
import SwiftUI

struct SelectableText: NSViewRepresentable {
    var text: NSAttributedString

    final class Coordinator { var shown: NSAttributedString? }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextView {
        // TextKit 1, as the measuring below.
        let view = CopyTrimmingTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        // SwiftUI sets the frame from sizeThatFits; the view neither grows nor shrinks itself to its text (it did,
        // and drew its lines outside the frame SwiftUI gave it, over the views below).
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.heightTracksTextView = true
        view.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        guard context.coordinator.shown != text else { return }
        context.coordinator.shown = text
        view.textStorage?.setAttributedString(text)
    }

    /// As wide as offered, as tall as the text wrapped to that width — measured apart from the view, whose own
    /// layout follows its frame (measuring by resizing the view's text container left the text wrapped to whatever
    /// width SwiftUI asked about last, and the lines ran over the views below).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        guard let offered = proposal.width else {
            // Its ideal size: a comfortable reading width.
            return CGSize(width: 480, height: Self.height(of: text, width: 480))
        }
        // As wide as it may get (a maximum): any width, the text on as few lines as it has paragraphs.
        if !offered.isFinite { return CGSize(width: offered, height: Self.height(of: text, width: 100_000)) }
        let width = max(offered, 40)
        return CGSize(width: width, height: Self.height(of: text, width: width))
    }

    /// The height of the text wrapped to `width`.
    static func height(of text: NSAttributedString, width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        return ceil(layout.usedRect(for: container).height)
    }
}

/// Copies without the tab that right-aligns a label (it would indent every pasted line).
final class CopyTrimmingTextView: NSTextView {
    override func copy(_ sender: Any?) {
        let range = selectedRange()
        guard range.length > 0 else { return super.copy(sender) }
        let lines = (string as NSString).substring(with: range).components(separatedBy: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.map { $0.hasPrefix("\t") ? String($0.dropFirst()) : $0 }.joined(separator: "\n"),
                                       forType: .string)
    }
}

/// Builds a SelectableText's contents: headings, label / value rows with the labels right-aligned, and columns.
struct RichLines {
    private var text = NSMutableAttributedString()

    /// The text, without the last line's line break (it would add an empty line).
    var result: NSAttributedString {
        let copy = NSMutableAttributedString(attributedString: text)
        if copy.string.hasSuffix("\n") { copy.deleteCharacters(in: NSRange(location: copy.length - 1, length: 1)) }
        return copy
    }

    static let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    static let boldFont = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
    static let digitFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    /// SwiftUI's .callout: the size of the lessons and boxes' text in MxAcctMGR.
    static let calloutFont = NSFont.preferredFont(forTextStyle: .callout)
    static let calloutBoldFont = NSFont.systemFont(ofSize: calloutFont.pointSize, weight: .semibold)
    static let captionFont = NSFont.preferredFont(forTextStyle: .caption1)

    /// A text cell: its words, font and colour, and the address it links to.
    struct Cell {
        var text: String
        var font: NSFont = RichLines.font
        var color: NSColor = .labelColor
        var link: URL? = nil
    }

    /// A section heading, with space above it unless it opens the text.
    mutating func heading(_ title: String) {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = text.length == 0 ? 0 : 14
        style.paragraphSpacing = 4
        append(title + "\n", Self.boldFont, .labelColor, style)
    }

    /// Label / value rows: labels right-aligned in a column as wide as the longest (at most `maxLabel`), values after.
    mutating func facts(_ rows: [(String, String)], maxLabel: CGFloat = 260) {
        let labelWidth = min(maxLabel, rows.map { width($0.0, Self.font) }.max() ?? 0)
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: labelWidth), NSTextTab(textAlignment: .left, location: labelWidth + 10)]
        style.headIndent = labelWidth + 10
        style.paragraphSpacing = 4
        for (label, value) in rows {
            append("\t" + label + "\t", Self.font, .secondaryLabelColor, style)
            append(value + "\n", Self.font, .labelColor, style)
        }
    }

    /// Rows of columns, each column as wide as its widest cell (cells: text, font, colour).
    mutating func columns(_ rows: [[(String, NSFont, NSColor)]]) {
        let count = rows.map(\.count).max() ?? 0
        var stops: [NSTextTab] = []
        var x: CGFloat = 0
        for c in 0..<max(count - 1, 0) {
            x += (rows.map { c < $0.count ? width($0[c].0, $0[c].1) : 0 }.max() ?? 0) + 14
            stops.append(NSTextTab(textAlignment: .left, location: x))
        }
        let style = NSMutableParagraphStyle()
        style.tabStops = stops
        style.headIndent = stops.last?.location ?? 0
        style.paragraphSpacing = 4
        for row in rows {
            for (i, cell) in row.enumerated() {
                append(cell.0 + (i < row.count - 1 ? "\t" : "\n"), cell.1, cell.2, style)
            }
        }
    }

    /// A paragraph, wrapping as wide as the text is.
    mutating func paragraph(_ line: String, font: NSFont = RichLines.font, color: NSColor = .labelColor, spacing: CGFloat = 6) {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = spacing
        append(line + "\n", font, color, style)
    }

    /// A list, each item after its marker ("•", or "1." "2." … when `numbered`) with its wrapped lines indented to
    /// the item's text, as a list in a document.
    mutating func bullets(_ items: [String], numbered: Bool = false, marker bullet: String = "•", font: NSFont = RichLines.font,
                          color: NSColor = .labelColor, spacing: CGFloat = 6) {
        let marker = numbered ? "\(items.count)." : bullet
        let indent = width(marker, numbered ? Self.emboldened(font) : font) + 8
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
        style.headIndent = indent
        style.paragraphSpacing = spacing
        for (i, item) in items.enumerated() {
            let m = numbered ? "\(i + 1)." : bullet
            append(m + "\t", numbered ? Self.emboldened(font) : font, numbered ? .labelColor : .secondaryLabelColor, style)
            append(item + "\n", font, color, style)
        }
    }

    /// Label / value rows with the labels at the left, in a column as wide as the longest (at most `maxLabel`), and
    /// values wrapping under themselves.
    mutating func labelled(_ rows: [(String, String)], font: NSFont = RichLines.font, maxLabel: CGFloat = 200) {
        let labelWidth = min(maxLabel, rows.map { width($0.0, font) }.max() ?? 0) + 14
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .left, location: labelWidth)]
        style.headIndent = labelWidth
        style.paragraphSpacing = 5
        for (label, value) in rows {
            append(label + "\t", font, .secondaryLabelColor, style)
            append(value + "\n", font, .labelColor, style)
        }
    }

    /// Rows of cells in columns, each as wide as its widest cell; a cell with an address is a link.
    mutating func cells(_ rows: [[Cell]], spacing: CGFloat = 6) {
        let count = rows.map(\.count).max() ?? 0
        var stops: [NSTextTab] = []
        var x: CGFloat = 0
        for c in 0..<max(count - 1, 0) {
            x += (rows.map { c < $0.count ? width($0[c].text, $0[c].font) : 0 }.max() ?? 0) + 14
            stops.append(NSTextTab(textAlignment: .left, location: x))
        }
        let style = NSMutableParagraphStyle()
        style.tabStops = stops
        style.headIndent = stops.last?.location ?? 0
        style.paragraphSpacing = spacing
        for row in rows {
            for (i, cell) in row.enumerated() {
                append(cell.text, cell.font, cell.color, style, link: cell.link)
                append(i < row.count - 1 ? "\t" : "\n", cell.font, cell.color, style)
            }
        }
    }

    private static func emboldened(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }

    /// A line of plain secondary text (an empty section's note).
    mutating func note(_ line: String) {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 4
        append(line + "\n", Self.font, .secondaryLabelColor, style)
    }

    private mutating func append(_ string: String, _ font: NSFont, _ color: NSColor, _ style: NSParagraphStyle, link: URL? = nil) {
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        if let link { attributes[.link] = link }
        text.append(NSAttributedString(string: string, attributes: attributes))
    }

    private func width(_ string: String, _ font: NSFont) -> CGFloat {
        ceil(NSAttributedString(string: string, attributes: [.font: font]).size().width)
    }
}
