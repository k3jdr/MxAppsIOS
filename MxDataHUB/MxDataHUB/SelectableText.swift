//
//  SelectableText.swift
//  MxDataHUB
//
//  A block of read-only text that can be selected across all its lines. SwiftUI selects within one Text at a time,
//  so a panel built of many (labels, values, a heading per section) could only be copied a word or a line at once.
//  Here headings, label / value rows and columns are one text: drag across any of it, ⌘A, ⌘C or right-click ▸ Copy.
//  It is as tall as its text, for use inside a scroll view.
//

import AppKit
import SwiftUI

struct SelectableText: NSViewRepresentable {
    var text: NSAttributedString

    final class Coordinator { var shown: NSAttributedString? }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextView {
        // TextKit 1, so its height can be measured for a width (sizeThatFits).
        let view = CopyTrimmingTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        guard context.coordinator.shown != text else { return }
        context.coordinator.shown = text
        view.textStorage?.setAttributedString(text)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        let width = proposal.width ?? 480
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
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

    /// A line of plain secondary text (an empty section's note).
    mutating func note(_ line: String) {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 4
        append(line + "\n", Self.font, .secondaryLabelColor, style)
    }

    private mutating func append(_ string: String, _ font: NSFont, _ color: NSColor, _ style: NSParagraphStyle) {
        text.append(NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style]))
    }

    private func width(_ string: String, _ font: NSFont) -> CGFloat {
        ceil(NSAttributedString(string: string, attributes: [.font: font]).size().width)
    }
}
