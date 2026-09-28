//
//  TableGridForm.swift
//  MxDataSRM
//
//  Form 3 — DB Table: an SQL box (pre-filled with the statement that loaded
//  the grid) with a Run SQL button, above the rows in a grid that fills the
//  form. View ▸ columns (default 3) are sized to span its width and View ▸ rows
//  (default 10) set its minimum height; scroll bars reach the rest. Columns the
//  user resized keep their width, saved per table in the workspace.
//

import SwiftUI

struct TableGridForm: View {
    @Bindable var session: WorkspaceSession
    @Binding var view: GridViewSettings

    var body: some View {
        if !session.isConnected {
            ContentUnavailableView("Not Connected", systemImage: "cable.connector.slash",
                                   description: Text("Connect in the DB Connection form first."))
        } else {
            VStack(alignment: .leading, spacing: 10) {
                sqlBar
                if let grid = session.grid {
                    gridSection(grid)
                } else {
                    ContentUnavailableView("No Table Open", systemImage: "tablecells",
                                           description: Text("Choose a table in the DB Table Selection form, or type a query above and click Run SQL."))
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .confirmationDialog("Run a statement that changes data?",
                                isPresented: Binding(get: { session.pendingWriteSQL != nil },
                                                     set: { if !$0 { session.pendingWriteSQL = nil } }),
                                presenting: session.pendingWriteSQL) { sql in
                Button("Run and Commit", role: .destructive) {
                    Task { await session.runSQL(sql, limit: view.fetchLimit, confirmedWrite: true) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { sql in
                Text("This statement can insert, update or delete rows. It runs in its own transaction, which is committed if it succeeds.\n\n\(String(sql.prefix(400)))")
            }
        }
    }

    // MARK: SQL

    private var sqlBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = session.sqlError {
                Label {
                    Text(error)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(8)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "xmark.octagon.fill")
                }
                .foregroundStyle(.red)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.red.opacity(0.4)))
            }

            HStack(alignment: .top, spacing: 8) {
                SQLTextView(text: $session.sqlText)
                    .frame(height: 76)
                VStack(spacing: 6) {
                    Button {
                        Task { await session.runSQL(limit: view.fetchLimit) }
                    } label: {
                        Label("Run SQL", systemImage: "play.fill")
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(session.runningSQL || session.busy)
                    if session.runningSQL {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("⌘↩").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Text("Fetches up to \(view.fetchLimit.formatted()) rows (Table ▸ View…). Queries run read-only; statements that change data ask before they run.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Grid

    @ViewBuilder private func gridSection(_ grid: GridData) -> some View {
        header(grid)

        // Fills the form; View ▸ columns fit across its width, View ▸ rows set its minimum height.
        DataGridView(session: session, version: session.gridVersion, visibleColumns: view.visibleColumns,
                     savedWidths: view.columnWidths[grid.widthKey] ?? [:]) { widths in
            view.columnWidths[grid.widthKey] = widths.isEmpty ? nil : widths
        }
            // At least View ▸ rows are visible (up to 10, so the window still fits on a small
            // screen); a taller window shows more.
            .frame(minHeight: GridMetrics.viewport(rows: min(view.visibleRows, 10), columns: 0).height,
                   idealHeight: min(GridMetrics.viewport(rows: view.visibleRows, columns: 0).height, 600),
                   maxHeight: .infinity)

        HStack {
            Button("Reload", systemImage: "arrow.clockwise") {
                Task { await session.reloadGrid(limit: view.fetchLimit) }
            }
            Button("View…") { session.showViewDialog = true }
            Button("Export CSV…", systemImage: "square.and.arrow.up") {
                CSVExport.begin(for: session)
            }
            .disabled(session.busy)
            Spacer()
            Button("Discard Edits") { session.discardEdits() }
                .disabled(session.edits.isEmpty)
            Button("Update…") { session.showUpdateDialog = true }
                .disabled(session.edits.isEmpty)
        }

        Text(grid.isEditable
             ? "Click a cell in the selected row to edit it; press Return to keep the change. Right-click a cell to set it to NULL."
             : "Read-only result. To edit rows, query a single table and include its primary key columns.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private func header(_ grid: GridData) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(grid.title).font(.title2.bold())
            HStack(spacing: 12) {
                Text(rowsText(grid))
                Text("\(grid.columns.count) columns")
                if let description = grid.description {
                    Text(description.primaryKey.isEmpty
                         ? "no primary key"
                         : "key: \(description.primaryKey.joined(separator: ", "))")
                }
                if !grid.isEditable {
                    Text("read-only")
                }
                if !session.edits.isEmpty {
                    Text("\(session.edits.count) pending edit\(session.edits.count == 1 ? "" : "s")")
                        .foregroundStyle(.orange)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private func rowsText(_ grid: GridData) -> String {
        if let total = grid.totalRows {
            return "\(grid.rows.count.formatted()) of \(total.formatted()) rows loaded"
        }
        return "\(grid.rows.count.formatted()) rows" + (grid.hasMore ? " (fetch limit reached)" : "")
    }
}
