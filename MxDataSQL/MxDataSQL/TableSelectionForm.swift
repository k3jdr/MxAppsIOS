//
//  TableSelectionForm.swift
//  MxDataSQL
//
//  Form 2 — DB Table Selection: the tables with their row counts, then the
//  functions and procedures; on the right a psql `\d`-style summary of the
//  highlighted table, or the highlighted function's or procedure's code (`\sf`).
//

import SwiftUI

struct TableSelectionForm: View {
    @Bindable var session: WorkspaceSession
    var onOpen: (TableRef) async -> Void

    var body: some View {
        if !session.isConnected {
            ContentUnavailableView("Not Connected", systemImage: "cable.connector.slash",
                                   description: Text("Connect in the DB Connection form to list tables, functions and procedures."))
        } else {
            HSplitView {
                tableList
                    .frame(minWidth: 320, idealWidth: 420)
                describePanel
                    .frame(minWidth: 320)
            }
            .task(id: session.highlightedID) { await session.describeHighlighted() }
        }
    }

    private var tableList: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("Show", selection: $session.catalogKind) {
                    ForEach(CatalogKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .quickHelp("Show", "Lists the tables, functions and procedures, or only one of them.")
                TextField("Filter", text: $session.tableFilter)
                    .textFieldStyle(.roundedBorder)
                    .quickHelp("Filter", "Shows only the tables, functions and procedures whose schema or name contains this text.")
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task {
                        await session.refreshTables()
                        await session.describeHighlighted()
                    }
                }
                .quickHelp("Refresh", "Lists the tables, functions and procedures again, with fresh row estimates and sizes, and reloads what's on the right.")
                Button("Count Rows") {
                    Task { await session.countAllRows() }
                }
                .help("Replace the estimated row counts with exact count(*) values")
                .disabled(session.countingRows)
                .quickHelp("Count Rows", "Replaces the estimated row counts (~) with exact count(*) values. On big tables this takes a while.")
            }

            Table(session.filteredEntries, selection: $session.highlightedID) {
                TableColumn("Schema", value: \.schema)
                TableColumn("Name") { entry in
                    Text(entry.name)
                        .help(entry.routine?.facts ?? "")
                }
                TableColumn("Type") { entry in
                    Label(entry.kind, systemImage: entry.symbol)
                        .foregroundStyle(entry.table == nil ? .secondary : .primary)
                }
                .width(min: 80, ideal: 100)
                TableColumn("Rows") { entry in
                    if let table = entry.table {
                        Text((table.exactRows == nil ? "~" : "") + table.displayRows.formatted())
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .help(table.exactRows == nil ? "Estimate from the planner statistics" : "Exact count")
                    }
                }
                .width(min: 70, ideal: 90)
                TableColumn("Size") { entry in
                    Text(entry.table?.totalSize ?? "")
                }
                .width(min: 60, ideal: 70)
            }
            .contextMenu(forSelectionType: CatalogEntry.ID.self) { _ in
            } primaryAction: { ids in
                open(ids.first)
            }
            .quickHelpArea(SQLHelp.tableList)

            HStack {
                Text(countText)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Toggle("Open in New Window", isOn: $session.openInNewWindow)
                    .toggleStyle(.checkbox)
                    .help("Open the table in its own window, with its own connection")
                    .quickHelp("Open in New Window", "Opens tables in a window of their own, with their own connection, instead of in this workspace's DB Table form.")
                Button("Open Table") { open(session.highlightedID) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(session.highlightedEntry?.table == nil)
                    .quickHelp("Open Table", "Opens the selected table's rows in DB Table (or its own window), sorted by its primary key.", shortcut: "↩")
            }
        }
        .padding(10)
    }

    /// "31 tables, 29 functions, 2 procedures" — what the list shows.
    private var countText: String {
        let entries = session.filteredEntries
        let tables = entries.filter { $0.table != nil }.count
        let procedures = entries.filter { $0.routine?.isProcedure ?? false }.count
        let functions = entries.count - tables - procedures
        let parts = [(tables, "table"), (functions, "function"), (procedures, "procedure")]
            .filter { $0.0 > 0 }
            .map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }
        return parts.isEmpty ? "Nothing listed" : parts.joined(separator: ", ")
    }

    private var describePanel: some View {
        ScrollView([.vertical, .horizontal]) {
            if let text = panelText {
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            } else {
                Text("Select a table to see its description, or a function or procedure to see its code.")
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
        }
        .defaultScrollAnchor(.topLeading)
        .background(Color(nsColor: .textBackgroundColor))
        .quickHelpArea(session.highlightedRoutine == nil ? SQLHelp.describe : SQLHelp.routineCode)
    }

    /// The function's or procedure's code (coloured like the SQL box), or the table's description.
    private var panelText: AttributedString? {
        if let routine = session.highlightedRoutine { return routine.colored }
        return session.highlightedDescription.map { AttributedString($0.psqlText) }
    }

    private func open(_ id: CatalogEntry.ID?) {
        guard let table = session.tables.first(where: { $0.id == id }) else { return }
        Task { await onOpen(table.ref) }
    }
}
