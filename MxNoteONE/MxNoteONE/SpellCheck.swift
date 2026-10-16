//
//  SpellCheck.swift
//  MxNoteONE
//
//  F7 checks spelling, as in Office: in the text being typed in (a text
//  container, a table cell, the page title), in the selected table cells, or
//  else on the whole page — the next misspelt word is selected and the macOS
//  Spelling panel offers corrections. When nothing is misspelt, a message
//  says so.
//

import AppKit

enum SpellCheck {
    /// F7 (with or without fn).
    static func isTrigger(_ event: NSEvent) -> Bool {
        event.keyCode == 98 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad]).isEmpty
    }

    /// The first misspelt word in `text` from `start` (wrapping round), if any.
    static func misspelling(in text: String, from start: Int = 0, tag: Int = 0) -> NSRange? {
        guard !text.isEmpty else { return nil }
        var count = 0
        let range = NSSpellChecker.shared.checkSpelling(of: text, startingAt: min(start, (text as NSString).length), language: nil,
                                                         wrap: true, inSpellDocumentWithTag: tag, wordCount: &count)
        return range.location == NSNotFound || range.length == 0 ? nil : range
    }

    /// Checks the text in focus (or the selected cells, or the page).
    static func run() {
        // The document window's focus (F7 again while the Spelling panel is in front carries on there).
        let responder = (NSApp.mainWindow ?? NSApp.keyWindow)?.firstResponder
        // Typing in text: from the caret on, then (in a table) the cells after it.
        if let tv = responder as? NSTextView {
            let start = NSMaxRange(tv.selectedRange())
            if misspelling(in: tv.string, from: start, tag: tv.spellCheckerDocumentTag) != nil {
                return show(in: tv)
            }
            if let grid = tv.superview as? TableGridView, grid.checkSpelling(after: grid.editingCell) { return }
            return done()
        }
        // Table cells selected: those cells (or the whole table for one cell).
        if let grid = responder as? TableGridView {
            if grid.checkSpelling(in: grid.selection.count > 1 ? grid.selection : nil) { return }
            return done()
        }
        // Otherwise the page: its text containers and tables, top to bottom.
        guard let canvas = NotebookStore.shared.canvas?.canvas else { return done() }
        let views = canvas.elementViews.sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
        for view in views {
            if let text = view as? TextElementView, misspelling(in: text.textView.string, tag: text.textView.spellCheckerDocumentTag) != nil {
                text.window?.makeFirstResponder(text.textView)
                text.textView.setSelectedRange(NSRange(location: 0, length: 0))
                return show(in: text.textView)
            }
            if let table = view as? TableElementView, table.grid.checkSpelling(in: nil) { return }
        }
        done()
    }

    /// Selects the next misspelt word and brings up the Spelling panel.
    static func show(in tv: NSTextView) {
        tv.window?.makeFirstResponder(tv)
        tv.checkSpelling(nil)
        tv.scrollRangeToVisible(tv.selectedRange())
        NSSpellChecker.shared.spellingPanel.orderFront(nil)
    }

    private static func done() {
        NotebookStore.shared.showAlert("Spelling check complete", "No spelling mistakes were found.")
    }
}

extension TableGridView {
    /// Starts typing in the first cell (of `cells`, or of the table) with a misspelt word and selects it.
    func checkSpelling(in cells: Set<CellRef>?, after: CellRef? = nil) -> Bool {
        var order = model.visibleCells.filter { cells?.contains($0) ?? true }
        if let after, let i = order.firstIndex(of: after) { order = Array(order[(i + 1)...]) }
        for cell in order {
            let raw = model.text(cell)
            guard !Formula.isFormula(raw), misspelling(raw) else { continue }
            beginEditing(cell, caretAtEnd: false)
            guard let tv = window?.firstResponder as? NSTextView else { return false }
            SpellCheck.show(in: tv)
            return true
        }
        return false
    }

    func checkSpelling(after cell: CellRef?) -> Bool {
        guard let cell else { return false }
        return checkSpelling(in: nil, after: cell)
    }

    private func misspelling(_ text: String) -> Bool { SpellCheck.misspelling(in: text) != nil }
}
