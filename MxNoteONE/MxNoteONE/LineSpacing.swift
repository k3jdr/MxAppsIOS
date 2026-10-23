//
//  LineSpacing.swift
//  MxNoteONE
//
//  Line spacing (Format ▸ Line Spacing, Home ▸ Paragraph): the space between
//  the lines of the selected paragraphs, or of what's typed next, as a
//  multiple of single spacing — 1.0, 1.15, 1.5, 2.0 … or a custom value, as
//  in Word and Pages. It's the paragraph style's line height multiple, which
//  RTFD saves with the text (in 240ths of a line: 1.37 reads back as 1.367).
//
//  Shift-Return breaks the line inside a paragraph (U+2028, RTF's \line): the
//  paragraph's bullet, tag and formatting carry on, and Return still starts a
//  new paragraph. The line after a break is single spaced (1.0) whatever the
//  paragraph's spacing; Settings ▸ Line breaks chooses another spacing.
//

import AppKit

enum LineSpacing {
    /// The spacings the menus offer (Custom… takes any other).
    static let presets: [CGFloat] = [1, 1.15, 1.5, 2, 2.5, 3]
    static let range: ClosedRange<CGFloat> = 0.5...5

    /// What Shift-Return types: a line break inside the paragraph.
    static let lineBreak = "\u{2028}"
    static let lineBreakCharacter: unichar = 0x2028

    static let lineBreakKey = "lineBreakSpacing"
    /// Settings ▸ Line breaks: (title, spacing), 0 = the paragraph's own spacing.
    static let lineBreakChoices: [(String, Double)] = [
        ("Single spaced (1.0)", 1), ("1.15", 1.15), ("1.5", 1.5), ("Double spaced (2.0)", 2), ("Spaced like the paragraph", 0),
    ]

    /// Spacing of the line after a line break; nil = the paragraph's own.
    static var lineBreakSpacing: CGFloat? {
        let value = UserDefaults.standard.object(forKey: lineBreakKey) as? Double ?? 1
        return value > 0 ? CGFloat(value) : nil
    }

    /// A paragraph style's spacing (no multiple set is single spacing).
    static func multiple(of style: NSParagraphStyle?) -> CGFloat {
        guard let multiple = style?.lineHeightMultiple, multiple > 0 else { return 1 }
        return multiple
    }

    /// 1.0, 1.15, 1.5, 2.0, 2.5 …
    static func title(_ multiple: CGFloat) -> String {
        let rounded = (multiple * 100).rounded() / 100
        return rounded == rounded.rounded() ? String(format: "%.1f", rounded) : String(format: "%g", rounded)
    }

    static func same(_ a: CGFloat?, _ b: CGFloat) -> Bool {
        guard let a else { return false }
        return abs(a - b) < 0.005
    }

    /// Line Spacing ▸ Custom…: any spacing from 0.5 to 5 lines.
    static func askCustom() {
        let current = NotebookStore.shared.editor.lineSpacing ?? 1
        let alert = NSAlert()
        alert.messageText = "Line Spacing"
        alert.informativeText = "The space between the lines of the selected paragraphs, in lines: 1.0 is single spacing, 2.0 double (0.5 to 5)."
        let field = NSTextField(string: title(current))
        field.frame = NSRect(x: 0, y: 0, width: 120, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let value = Double(text), value > 0 else { NSSound.beep(); return }
        TextFormatter.setLineSpacing(min(max(CGFloat(value), range.lowerBound), range.upperBound))
    }

    /// Settings changed the line-break spacing: the open page's text boxes lay out again.
    static func relayoutOpenPage() {
        guard let canvas = NotebookStore.shared.canvas?.canvas else { return }
        for case let box as TextElementView in canvas.elementViews {
            let tv = box.textView
            guard let layout = tv.layoutManager, let storage = tv.textStorage else { continue }
            layout.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)
            tv.sizeToFit()
            tv.needsDisplay = true
        }
    }
}

/// Lays out text boxes and table cells: the line after a line break (Shift-Return) is spaced at the line-break spacing
/// instead of the paragraph's. TextKit 1 puts a multiple's extra space above a line, so that line is made as tall as
/// it would be at the line-break spacing, and its text moves up (or down) with it.
final class NoteLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    override init() {
        super.init()
        delegate = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        delegate = self
    }

    /// How a line starting at a character changes height: nil unless it follows a line break in a paragraph spaced
    /// differently from line breaks.
    private func breakScale(at index: Int) -> CGFloat? {
        guard let storage = textStorage, index > 0, index <= storage.length,
              (storage.string as NSString).character(at: index - 1) == LineSpacing.lineBreakCharacter,
              let spacing = LineSpacing.lineBreakSpacing else { return nil }
        let style = storage.attribute(.paragraphStyle, at: index - 1, effectiveRange: nil) as? NSParagraphStyle
        let multiple = LineSpacing.multiple(of: style)
        return abs(multiple - spacing) < 0.001 ? nil : spacing / multiple
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        guard let scale = breakScale(at: characterIndexForGlyph(at: glyphRange.location)) else { return false }
        let change = lineFragmentRect.pointee.height * (scale - 1)
        lineFragmentRect.pointee.size.height += change
        lineFragmentUsedRect.pointee.size.height += change
        baselineOffset.pointee += change
        return true
    }

    /// The empty line after a break at the end of the text (where the caret waits) is spaced the same way.
    override func setExtraLineFragmentRect(_ fragmentRect: NSRect, usedRect: NSRect, textContainer container: NSTextContainer) {
        var rect = fragmentRect, used = usedRect
        if let storage = textStorage, let scale = breakScale(at: storage.length) {
            let change = rect.height * (scale - 1)
            rect.size.height += change
            used.size.height += change
        }
        super.setExtraLineFragmentRect(rect, usedRect: used, textContainer: container)
    }
}

// MARK: - Menu

import SwiftUI

/// The Line Spacing menu (Home ▸ Paragraph and Format ▸ Line Spacing), with the selection's spacing checked.
struct LineSpacingMenuItems: View {
    private var editor: EditorState { NotebookStore.shared.editor }

    var body: some View {
        ForEach(LineSpacing.presets, id: \.self) { value in
            Toggle(LineSpacing.title(value), isOn: Binding(get: { LineSpacing.same(editor.lineSpacing, value) },
                                                           set: { _ in TextFormatter.setLineSpacing(value) }))
        }
        Divider()
        let custom = editor.lineSpacing.flatMap { spacing in LineSpacing.presets.contains { LineSpacing.same(spacing, $0) } ? nil : spacing }
        Toggle(custom.map { "Custom (\(LineSpacing.title($0)))…" } ?? "Custom…",
               isOn: Binding(get: { custom != nil }, set: { _ in DispatchQueue.main.async { LineSpacing.askCustom() } }))
    }
}
