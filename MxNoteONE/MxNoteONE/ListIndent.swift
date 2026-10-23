//
//  ListIndent.swift
//  MxNoteONE
//
//  Bullets, numbers and tags are text at the start of a paragraph ("• ",
//  "1. ", "☐ "). Without more, a long item's wrapped lines start back at the
//  margin, under the marker. Each such paragraph gets a hanging indent as wide
//  as its marker, so wrapped lines line up under the item's first character
//  (as in OneNote and Word). It's worked out when a text box loads and after
//  every edit, and taken off again when a paragraph loses its marker.
//

import AppKit

extension NSAttributedString.Key {
    /// On a paragraph given a hanging indent here: the marker's width.
    static let mxListHang = NSAttributedString.Key("MxListHang")
}

enum ListIndent {
    static func apply(_ storage: NSTextStorage) {
        let ns = storage.string as NSString
        guard ns.length > 0 else { return }
        var location = 0
        var editing = false
        while location < ns.length {
            let para = ns.paragraphRange(for: NSRange(location: location, length: 0))
            guard para.length > 0 else { break }
            location = NSMaxRange(para)
            var text = ns.substring(with: para)
            if text.hasSuffix("\n") { text.removeLast() }
            let info = TextFormatter.parseParagraph(text)
            let style = (storage.attribute(.paragraphStyle, at: para.location, effectiveRange: nil) as? NSParagraphStyle) ?? .default
            let marked = storage.attribute(.mxListHang, at: para.location, effectiveRange: nil) != nil
            var target: CGFloat?
            if info.list != nil || info.tag != nil, info.contentStart > 0 {
                let marker = storage.attributedSubstring(from: NSRange(location: para.location, length: info.contentStart))
                let width = marker.size().width
                target = style.firstLineHeadIndent + width
            } else if !marked {
                continue
            }
            // A paragraph that lost its marker: wrapped lines go back to where its first line starts.
            let headIndent = target ?? style.firstLineHeadIndent
            let needsMark = target != nil
            guard abs(style.headIndent - headIndent) > 0.5 || needsMark != marked else { continue }
            if !editing { storage.beginEditing(); editing = true }
            let changed = style.mutableCopy() as! NSMutableParagraphStyle
            changed.headIndent = headIndent
            storage.addAttribute(.paragraphStyle, value: changed, range: para)
            if needsMark {
                storage.addAttribute(.mxListHang, value: headIndent - style.firstLineHeadIndent, range: para)
            } else {
                storage.removeAttribute(.mxListHang, range: para)
            }
        }
        if editing { storage.endEditing() }
    }
}
