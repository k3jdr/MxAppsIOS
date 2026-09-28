//
//  TableGridForm.swift
//  MxDataSRM
//
//  Form 3 — DB Table: the loaded rows in an editable grid whose viewport
//  shows View ▸ rows × columns (default 10 × 3); scroll bars reach the rest.
//

import SwiftUI

struct TableGridForm: View {
    let session: WorkspaceSession
    let view: GridViewSettings

    var body: some View {
        if let grid = session.grid {
            VStack(alignment: .leading, spacing: 10) {
                header(grid)

                let size = GridMetrics.viewport(rows: view.visibleRows, columns: view.visibleColumns)
                DataGridView(session: session, version: session.gridVersion)
                    .frame(maxWidth: size.width, maxHeight: size.height)

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
                .frame(maxWidth: max(size.width, 520))

                Text("Click a cell in the selected row to edit it; press Return to keep the change. Right-click a cell to set it to NULL.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
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
