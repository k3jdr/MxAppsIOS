//
//  UpdateDialog.swift
//  MxDataSQL
//
//  Table ▸ Update…: reviews the pending cell edits, asks how rows are
//  identified and how the change is applied, previews the SQL, then runs it.
//

import SwiftUI

struct UpdateDialog: View {
    let session: WorkspaceSession
    let fetchLimit: Int
    @State private var options = UpdateOptions()
    @State private var applying = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let grid = session.grid, !session.edits.isEmpty {
                Text("Update \(grid.ref?.displayName ?? grid.title)").font(.headline)
                changesList(grid)
                keyOptions(grid)
                behaviourOptions
                sqlPreview(grid)
                buttons(canApply: plan(grid).error == nil)
            } else {
                Text("Update Table").font(.headline)
                Text("There are no pending edits. Edit cells in the DB Table grid, then choose Table ▸ Update.")
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 620)
        .disabled(applying)
        .onAppear {
            if let grid = session.grid, grid.description?.primaryKey.isEmpty ?? false {
                options.keyMode = grid.rowIDs.isEmpty ? .columns : .rowID
            }
        }
    }

    private var sortedEdits: [(key: CellKey, value: CellEdit)] {
        session.edits.sorted { ($0.key.row, $0.key.column) < ($1.key.row, $1.key.column) }
    }

    private func changesList(_ grid: GridData) -> some View {
        GroupBox("\(session.edits.count) changed cell\(session.edits.count == 1 ? "" : "s")") {
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("Row"); Text("Column"); Text("Old value"); Text("New value")
                    }
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    ForEach(sortedEdits, id: \.key) { key, edit in
                        GridRow {
                            Text("\(grid.offset + key.row + 1)").monospacedDigit()
                            Text(grid.columns[key.column].name)
                            Text(grid.rows[key.row][key.column] ?? "NULL").foregroundStyle(.secondary)
                            Text(displayNew(edit.value))
                        }
                        .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
            .frame(maxHeight: 140)
        }
    }

    private func displayNew(_ value: String?) -> String {
        guard let value else { return "NULL" }
        if value.isEmpty { return options.emptyAsNull ? "NULL" : "''" }
        return value
    }

    private func keyOptions(_ grid: GridData) -> some View {
        GroupBox("Identify each row by") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Row key", selection: $options.keyMode) {
                    // Row IDs exist only when the whole table was loaded, not for query results.
                    ForEach(RowKeyMode.allCases.filter { $0 != .rowID || !grid.rowIDs.isEmpty }) { mode in
                        Text(label(for: mode, grid)).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                if options.keyMode == .columns {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(grid.columns, id: \.name) { column in
                                Toggle(column.name, isOn: Binding(
                                    get: { options.matchColumns.contains(column.name) },
                                    set: { if $0 { options.matchColumns.insert(column.name) } else { options.matchColumns.remove(column.name) } }))
                                    .toggleStyle(.checkbox)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private func label(for mode: RowKeyMode, _ grid: GridData) -> String {
        switch mode {
        case .primaryKey:
            (grid.description?.primaryKey ?? []).isEmpty
                ? "Primary key (none on this table)"
                : "Primary key (\(grid.description!.primaryKey.joined(separator: ", ")))"
        case .rowID: "Physical row ID (ctid, as loaded)"
        case .columns: "Loaded values of selected columns"
        }
    }

    private var behaviourOptions: some View {
        GroupBox("Options") {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Only update rows whose edited columns still have the loaded values", isOn: $options.checkOriginalValues)
                Toggle("Write empty cells as NULL", isOn: $options.emptyAsNull)
                Toggle("All rows in one transaction (all or nothing)", isOn: $options.singleTransaction)
            }
            .toggleStyle(.checkbox)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private func plan(_ grid: GridData) -> (updates: [PlannedUpdate], error: String?) {
        do {
            return (try planUpdates(grid: grid, edits: session.edits, options: options), nil)
        } catch {
            return ([], error.localizedDescription)
        }
    }

    private func sqlPreview(_ grid: GridData) -> some View {
        let result = plan(grid)
        return GroupBox("SQL") {
            ScrollView {
                Group {
                    if let error = result.error {
                        Text(error).foregroundStyle(.red)
                    } else {
                        Text(result.updates.map(sqlText).joined(separator: "\n"))
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
            .frame(maxHeight: 120)
        }
    }

    /// Statement with the parameter values shown in a trailing comment.
    private func sqlText(_ update: PlannedUpdate) -> String {
        let params = update.binds.enumerated()
            .map { "$\($0 + 1)=\($1.map { "'\($0)'" } ?? "NULL")" }
            .joined(separator: " ")
        return update.sql + ";  -- " + params
    }

    private func buttons(canApply: Bool) -> some View {
        HStack {
            Button("Discard Edits", role: .destructive) {
                session.discardEdits()
                dismiss()
            }
            Spacer()
            if applying { ProgressView().controlSize(.small) }
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Apply Updates") {
                applying = true
                Task {
                    _ = await session.applyUpdates(options: options, limit: fetchLimit)
                    applying = false
                    dismiss()
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canApply)
        }
    }
}
