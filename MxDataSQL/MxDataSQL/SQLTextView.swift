//
//  SQLTextView.swift
//  MxDataSQL
//
//  Plain-text, monospaced SQL editor. Wraps NSTextView so smart quotes, smart
//  dashes and autocorrection can be turned off; they would corrupt SQL. Its
//  right-click menu starts with `menuItems` (Open / Save SQL file, ...). The SQL is
//  syntax-coloured by SQLHighlighter after every change.
//

import AppKit
import SwiftUI

struct SQLTextView: NSViewRepresentable {
    @Binding var text: String
    /// Items put above the standard text items of the right-click menu.
    var menuItems: () -> [NSMenuItem] = { [] }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        let textView = scroll.documentView as! NSTextView
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textStorage?.delegate = context.coordinator
        textView.string = text
        textView.delegate = context.coordinator
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.menuItems = menuItems
        let textView = scroll.documentView as! NSTextView
        if textView.string != text {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var text: Binding<String>
        var menuItems: () -> [NSMenuItem] = { [] }

        init(text: Binding<String>) {
            self.text = text
        }

        /// Recolours the SQL when its characters change (attribute-only edits are ignored).
        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                         range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            SQLHighlighter.apply(to: textStorage)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }

        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            // The menu passed in may be shared by all text views: add to a copy.
            let result = (menu.copy() as? NSMenu) ?? NSMenu()
            for (index, item) in menuItems().enumerated() { result.insertItem(item, at: index) }
            return result
        }
    }
}
