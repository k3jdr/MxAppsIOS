//
//  TableSelectionForm.swift
//  MxDataSQL
//
//  Form 2 — DB Table Selection: available tables with their row counts,
//  and a psql `\d`-style summary of the highlighted table.
//

import SwiftUI

struct TableSelectionForm: View {
    @Bindable var session: WorkspaceSession
    var onOpen: (TableRef) async -> Void

    var body: some View {
        if !session.isConnected {
            ContentUnavailableView("Not Connected", systemImage: "cable.connector.slash",
                                   description: Text("Connect in the DB Connection form to list tables."))
        } else {
            HSplitView {
                tableList
                    .frame(minWidth: 320, idealWidth: 420)
                describePanel
                    .frame(minWidth: 320)
            }
            .task(id: session.highlightedTableID) { await session.describeHighlighted() }
        }
    }

    private var tableList: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Filter", text: $session.tableFilter)
                    .textFieldStyle(.roundedBorder)
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await session.refreshTables() }
                }
                Button("Count Rows") {
                    Task { await session.countAllRows() }
                }
                .help("Replace the estimated row counts with exact count(*) values")
                .disabled(session.countingRows)
            }

            Table(session.filteredTables, selection: $session.highlightedTableID) {
                TableColumn("Schema", value: \.schema)
                TableColumn("Table", value: \.name)
                TableColumn("Rows") { table in
                    Text((table.exactRows == nil ? "~" : "") + table.displayRows.formatted())
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .help(table.exactRows == nil ? "Estimate from the planner statistics" : "Exact count")
                }
                .width(min: 70, ideal: 90)
                TableColumn("Size", value: \.totalSize)
                    .width(min: 60, ideal: 70)
            }
            .contextMenu(forSelectionType: TableSummary.ID.self) { _ in
            } primaryAction: { ids in
                open(ids.first)
            }

            HStack {
                Text("\(session.filteredTables.count) tables")
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("Open in New Window", isOn: $session.openInNewWindow)
                    .toggleStyle(.checkbox)
                    .help("Open the table in its own window, with its own connection")
                Button("Open Table") { open(session.highlightedTableID) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(session.highlightedTableID == nil)
            }
        }
        .padding(10)
    }

    private var describePanel: some View {
        ScrollView([.vertical, .horizontal]) {
            if let description = session.highlightedDescription {
                Text(description.psqlText)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            } else {
                Text("Select a table to see its description.")
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
        }
        .defaultScrollAnchor(.topLeading)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func open(_ id: TableSummary.ID?) {
        guard let table = session.tables.first(where: { $0.id == id }) else { return }
        Task { await onOpen(table.ref) }
    }
}
