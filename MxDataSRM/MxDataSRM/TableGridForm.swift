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
                Text(WorkspaceSession.isCall(sql)
                     ? "This calls a stored procedure, which can change data. Its work is committed if it succeeds.\n\n\(String(sql.prefix(400)))"
                     : "This statement can insert, update or delete rows. It runs in its own transaction, which is committed if it succeeds.\n\n\(String(sql.prefix(400)))")
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
                SQLTextView(text: $session.sqlText) {
                    session.sqlMenuItems { Task { await session.runSQL(limit: view.fetchLimit) } }
                }
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

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let name = session.sqlFileName {
                    Label(name, systemImage: "doc.text")
                        .help(session.sqlFileURL?.path ?? "")
                    if session.sqlIsEdited {
                        Text("— Edited").foregroundStyle(.orange)
                    }
                    Text("·")
                }
                Text("Right-click the SQL to open or save .sql files. Fetches up to \(view.fetchLimit.formatted()) rows (Table ▸ View…); queries run read-only, and statements that change data ask before they run.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
    }

    // MARK: Grid

    @ViewBuilder private func gridSection(_ grid: GridData) -> some View {
        header(grid)

        // Fills the form; View ▸ columns fit across its width, View ▸ rows set its minimum height.
        DataGridView(session: session, version: session.gridVersion, visibleColumns: view.visibleColumns,
                     savedWidths: view.columnWidths[grid.widthKey] ?? [:],
                     onApplyOptions: { options in
                         Task { await session.applyGridOptions(options, limit: view.fetchLimit) }
                     }) { widths in
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
            Button("Previous", systemImage: "chevron.left") {
                Task { await session.showPage(next: false, limit: view.fetchLimit) }
            }
            .disabled(!grid.hasPreviousPage || session.busy || session.runningSQL)
            .help("Load the previous \(view.fetchLimit.formatted()) rows")
            Button {
                Task { await session.showPage(next: true, limit: view.fetchLimit) }
            } label: {
                HStack(spacing: 4) {
                    Text("Next")
                    Image(systemName: "chevron.right")
                }
            }
            .disabled(!grid.hasNextPage || session.busy || session.runningSQL)
            .help("Load the next \(view.fetchLimit.formatted()) rows")
            Button("Discard Edits") { session.discardEdits() }
                .disabled(session.edits.isEmpty)
            Button("Update…") { session.showUpdateDialog = true }
                .disabled(session.edits.isEmpty)
        }

        Text(grid.isEditable
             ? "Click, shift-click or drag to select cells; ⌘C copies and ⌘V pastes. Double-click a cell or press Return to edit it. Right-click for NULL and Revert."
             : "Read-only result: select cells and press ⌘C to copy. To edit rows, query one table with SELECT * (any WHERE / ORDER BY), or include its primary key columns.")
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
                if let sort = grid.options.sort {
                    Label("sorted by \(sort.column)", systemImage: sort.ascending ? "arrow.up" : "arrow.down")
                        .foregroundStyle(Color.accentColor)
                }
                if !grid.options.filters.isEmpty {
                    let names = grid.options.filters.keys.sorted().joined(separator: ", ")
                    Label("filtered: \(names)", systemImage: "line.3.horizontal.decrease.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                    Button("Clear Filters") {
                        var options = grid.options
                        options.filters = [:]
                        Task { await session.applyGridOptions(options, limit: view.fetchLimit) }
                    }
                    .buttonStyle(.link)
                    .disabled(session.busy)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    /// "Rows 1,001–2,000 of 5,432"; without a known total, "(more on the next page)".
    private func rowsText(_ grid: GridData) -> String {
        guard !grid.rows.isEmpty else {
            return grid.offset > 0 ? "No rows after row \(grid.offset.formatted())" : "No rows"
        }
        let range = "Rows \((grid.offset + 1).formatted())–\((grid.offset + grid.rows.count).formatted())"
        if let total = grid.totalRows, let unfiltered = grid.unfilteredTotal {
            return range + " of \(total.formatted()) (filtered from \(unfiltered.formatted()))"
        }
        if let total = grid.totalRows {
            return range + " of \(total.formatted())"
        }
        return range + (grid.hasMore ? " (more on the next page)" : "")
    }
}
