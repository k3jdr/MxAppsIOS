//
//  TableSelectionForm.swift
//  MxDataSQL
//
//  Form 2 — DB Table Selection: the tables and views with their row counts, then
//  the functions and procedures; on the right a psql `\d`-style summary of the
//  highlighted table or view (with a view's definition), or the highlighted
//  function's or procedure's code (`\sf`).
//

import SwiftUI

struct TableSelectionForm: View {
    @Bindable var session: WorkspaceSession
    var onOpen: (TableRef) async -> Void

    var body: some View {
        if !session.isConnected {
            ContentUnavailableView("Not Connected", systemImage: "cable.connector.slash",
                                   description: Text("Connect in the DB Connection form to list tables, views, functions and procedures."))
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
                .quickHelp("Show", "Lists the tables, views, functions and procedures, or only one of them.")
                TextField("Filter", text: $session.tableFilter)
                    .textFieldStyle(.roundedBorder)
                    .quickHelp("Filter", "Shows only the tables, views, functions and procedures whose schema or name contains this text.")
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task {
                        await session.refreshTables()
                        await session.describeHighlighted()
                    }
                }
                .quickHelp("Refresh", "Lists the tables, views, functions and procedures again, with fresh row estimates and sizes, and reloads what's on the right.")
                Button("Count Rows") {
                    Task { await session.countAllRows() }
                }
                .help("Replace the estimated row counts with exact count(*) values")
                .disabled(session.countingRows)
                .quickHelp("Count Rows", "Replaces the estimated row counts (~) with exact count(*) values. On big tables this takes a while. "
                    + "Views aren't counted here (each would run its whole query); opening one counts its rows.")
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
                    if let table = entry.table, !(table.isPlainView && table.exactRows == nil) {
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
                Button(openTitle) { open(session.highlightedID) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(session.highlightedEntry?.table == nil)
                    .quickHelp(openTitle, "Opens the selected table's rows in DB Table (or its own window), sorted by its primary key. "
                               + "A view's rows open read-only, in the view's own order.", shortcut: "↩")
            }
        }
        .padding(10)
    }

    private var openTitle: String {
        session.highlightedEntry?.table?.isView == true ? "Open View" : "Open Table"
    }

    /// "56 tables, 7 views, 29 functions, 2 procedures" — what the list shows.
    private var countText: String {
        let entries = session.filteredEntries
        let tables = entries.filter { $0.table.map { !$0.isView } ?? false }.count
        let views = entries.filter { $0.table?.isView ?? false }.count
        let procedures = entries.filter { $0.routine?.isProcedure ?? false }.count
        let functions = entries.count - tables - views - procedures
        let parts = [(tables, "table"), (views, "view"), (functions, "function"), (procedures, "procedure")]
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
                Text("Select a table or view to see its description, or a function or procedure to see its code.")
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
        }
        .defaultScrollAnchor(.topLeading)
        .background(Color(nsColor: .textBackgroundColor))
        .quickHelpArea(session.highlightedRoutine == nil ? SQLHelp.describe : SQLHelp.routineCode)
    }

    /// The function's or procedure's code, or the table's or view's description; code and a view's
    /// definition are coloured like the SQL box.
    private var panelText: AttributedString? {
        if let routine = session.highlightedRoutine { return routine.colored }
        return session.highlightedDescription.map { description in
            var text = AttributedString(description.psqlSummary)
            if let definition = description.viewDefinition {
                text += AttributedString("View definition:\n") + SQLHighlighter.attributed(definition)
            }
            return text
        }
    }

    private func open(_ id: CatalogEntry.ID?) {
        guard let table = session.tables.first(where: { $0.id == id }) else { return }
        Task { await onOpen(table.ref) }
    }
}
