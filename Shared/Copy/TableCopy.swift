//
//  TableCopy.swift
//  Shared by MxDataHUB and MxAcctMGR (MxAppsIOS/Shared/Copy)
//
//  Copying a table's rows: select rows (⇧-click or ⌘-click for several, ⌘A for all), then Edit ▸
//  Copy (⌘C) or the row's Copy Row puts them on the clipboard as lines of tab-separated columns under the table's
//  column titles, so they paste into a spreadsheet, a ticket or a note. Tables select rows, not their words; the rest
//  of each screen's text can be selected as text (ContentView), and copied a section or a page at a time (PageText).
//

import AppKit
import SwiftUI

/// A table's columns as text: their titles, and each row's values in the same order.
struct TableText<Row> {
    var titles: [String]
    var cells: (Row) -> [String]

    func text(_ rows: [Row]) -> String {
        ([titles] + rows.map(cells)).map { $0.map(Self.clean).joined(separator: "\t") }.joined(separator: "\n")
    }

    func copy(_ rows: [Row]) {
        guard !rows.isEmpty else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text(rows), forType: .string)
    }

    /// A tab or line break inside a value would split it across columns or lines.
    nonisolated private static func clean(_ value: String) -> String {
        value.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
    }
}

extension View {
    /// ⌘C (Edit ▸ Copy) copies the selected rows under the column titles. Rows are selected, not their words, so the
    /// table turns text selection off for its cells.
    func copiesSelectedRows<Row: Identifiable>(_ rows: [Row], selected: Set<Row.ID>, as text: TableText<Row>) -> some View {
        textSelection(.disabled)
            .onCopyCommand {
                let picked = rows.filter { selected.contains($0.id) }
                return picked.isEmpty ? [] : [NSItemProvider(object: text.text(picked) as NSString)]
            }
    }

    /// The same, for a table that selects one row at a time.
    func copiesSelectedRows<Row: Identifiable>(_ rows: [Row], selected: Row.ID?, as text: TableText<Row>) -> some View {
        copiesSelectedRows(rows, selected: selected.map { [$0] } ?? [], as: text)
    }

    /// A row's context menu with Copy Row (or Copy N Rows, when the row is one of several selected), for a table
    /// that has no menu of its own.
    func copyRowsMenu<Row: Identifiable>(_ rows: [Row], as text: TableText<Row>) -> some View {
        contextMenu(forSelectionType: Row.ID.self) { ids in
            CopyRowsButton(rows: rows, ids: ids, text: text)
        }
    }
}

/// Copy Row / Copy N Rows, for a table's context menu.
struct CopyRowsButton<Row: Identifiable>: View {
    var rows: [Row]
    var ids: Set<Row.ID>
    var text: TableText<Row>

    var body: some View {
        Button(ids.count > 1 ? "Copy \(ids.count) Rows" : "Copy Row") {
            text.copy(rows.filter { ids.contains($0.id) })
        }
        .disabled(ids.isEmpty)
    }
}
