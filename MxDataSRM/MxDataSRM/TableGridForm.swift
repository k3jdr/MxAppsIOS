//
//  TableGridForm.swift
//  MxDataSRM
//
//  Form 3 — DB Table: the loaded rows in an editable grid that fills the
//  form. View ▸ columns (default 3) are sized to span its width and View ▸ rows
//  (default 10) set its minimum height; scroll bars reach the rest. Columns the
//  user resized keep their width, saved per table in the workspace.
//

import SwiftUI

struct TableGridForm: View {
    let session: WorkspaceSession
    @Binding var view: GridViewSettings

    var body: some View {
        if let grid = session.grid {
            VStack(alignment: .leading, spacing: 10) {
                header(grid)

                // Fills the form; View ▸ columns fit across its width, View ▸ rows set its minimum height.
                DataGridView(session: session, version: session.gridVersion, visibleColumns: view.visibleColumns,
                             savedWidths: view.columnWidths[grid.ref.displayName] ?? [:]) { widths in
                    view.columnWidths[grid.ref.displayName] = widths.isEmpty ? nil : widths
                }
                    .frame(minHeight: min(GridMetrics.viewport(rows: view.visibleRows, columns: 0).height, 600),
                           maxHeight: .infinity)

                HStack {
                    Button("Reload", systemImage: "arrow.clockwise") {
                        Task { await session.reloadGrid(limit: view.fetchLimit) }
                    }
                    Button("View…") { session.showViewDialog = true }
                    Spacer()
                    Button("Discard Edits") { session.discardEdits() }
                        .disabled(session.edits.isEmpty)
                    Button("Update…") { session.showUpdateDialog = true }
                        .keyboardShortcut(.defaultAction)
                        .disabled(session.edits.isEmpty)
                }

                Text("Click a cell in the selected row to edit it; press Return to keep the change. Right-click a cell to set it to NULL.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ContentUnavailableView("No Table Open", systemImage: "tablecells",
                                   description: Text("Choose a table in the DB Table Selection form."))
        }
    }

    private func header(_ grid: GridData) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(grid.ref.displayName).font(.title2.bold())
            HStack(spacing: 12) {
                Text("\(grid.rows.count.formatted()) of \(grid.totalRows.formatted()) rows loaded")
                Text("\(grid.columns.count) columns")
                Text(grid.description.primaryKey.isEmpty
                     ? "no primary key"
                     : "key: \(grid.description.primaryKey.joined(separator: ", "))")
                if !session.edits.isEmpty {
                    Text("\(session.edits.count) pending edit\(session.edits.count == 1 ? "" : "s")")
                        .foregroundStyle(.orange)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }
}
