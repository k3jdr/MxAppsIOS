//
//  CSVExport.swift
//  MxDataSQL
//
//  Export CSV…: writes the grid to a CSV file (RFC 4180, UTF-8, CRLF line ends,
//  header row of column names). NULL is an empty field; an empty string is "".
//  The rows loaded in the grid are exported as shown, including unapplied edits;
//  "All rows" re-runs the grid's query read-only and streams it to the file.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One CSV record, CRLF-terminated. Fields holding a comma, quote, line break or
/// leading/trailing space are quoted; quotes inside are doubled.
nonisolated func csvLine(_ fields: [String?]) -> Data {
    let line = fields.map { field -> String in
        guard let field else { return "" }
        let needsQuotes = field.isEmpty
            || field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
            || field.first == " " || field.last == " "
        return needsQuotes ? "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : field
    }.joined(separator: ",")
    return Data((line + "\r\n").utf8)
}

@Observable
final class CSVExportChoice {
    var allRows = false
}

enum CSVExport {
    /// Shows a Save panel for the session's grid and exports to the chosen file.
    static func begin(for session: WorkspaceSession) {
        guard let grid = session.grid else { return }
        let panel = NSSavePanel()
        panel.title = "Export CSV"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = (grid.ref?.name ?? "query-result") + ".csv"

        let choice = CSVExportChoice()
        let moreAvailable = grid.hasMore || (grid.totalRows ?? 0) > grid.rows.count
        if moreAvailable || !session.edits.isEmpty {
            let options = NSHostingView(rootView: CSVExportOptions(
                choice: choice, loaded: grid.rows.count, total: grid.totalRows,
                moreAvailable: moreAvailable, edits: session.edits.count))
            options.frame.size = options.fittingSize
            panel.accessoryView = options
        }

        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            let allRows = choice.allRows
            Task { await session.exportCSV(to: url, allRows: allRows) }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }
}

/// Save panel accessory: loaded rows or all rows.
private struct CSVExportOptions: View {
    @Bindable var choice: CSVExportChoice
    let loaded: Int
    let total: Int?
    let moreAvailable: Bool
    let edits: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if moreAvailable {
                Picker("Export", selection: $choice.allRows) {
                    Text("Loaded rows (\(loaded.formatted()))" + (edits > 0 ? ", including \(edits) unapplied edit\(edits == 1 ? "" : "s")" : ""))
                        .tag(false)
                    Text("All rows" + (total.map { " (\($0.formatted()))" } ?? "") + " — runs the query again, read-only")
                        .tag(true)
                }
                .pickerStyle(.radioGroup)
            } else {
                Text("Includes \(edits) unapplied edit\(edits == 1 ? "" : "s") shown in the grid.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }
}

extension WorkspaceSession {
    /// Writes the grid to `url`: the loaded rows as shown, or every row of the grid's query.
    func exportCSV(to url: URL, allRows: Bool) async {
        guard let grid else { return }
        busy = true
        defer { busy = false }
        do {
            let count: Int
            if allRows {
                guard let sql = grid.customSQL ?? grid.description?.defaultSQL else { return }
                guard let service = currentService else { throw DatabaseError(message: "Not connected.") }
                do {
                    // Same sorting and filters as the grid.
                    count = try await service.exportCSV(sql, to: url, options: grid.options, columns: grid.columns)
                } catch is WriteNotAllowed {
                    throw DatabaseError(message: "This statement changes data, so it is not run again. Export the loaded rows instead.")
                }
            } else {
                var data = csvLine(grid.columns.map(\.name))
                for (r, row) in grid.rows.enumerated() {
                    data.append(csvLine(row.indices.map { c in
                        if let edit = edits[CellKey(row: r, column: c)] { edit.value } else { row[c] }
                    }))
                }
                try data.write(to: url, options: .atomic)
                count = grid.rows.count
            }
            infoMessage = "Exported \(count.formatted()) row\(count == 1 ? "" : "s") to \(url.lastPathComponent)."
        } catch {
            errorMessage = "CSV export failed.\n\n" + DatabaseError.from(error).message
        }
    }
}
