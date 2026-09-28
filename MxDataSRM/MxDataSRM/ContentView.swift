//
//  ContentView.swift
//  MxDataSRM
//
//  A workspace window: the three forms (DB Connection, DB Table Selection,
//  DB Table) selected with a segmented control, plus a status bar.
//

import SwiftUI

struct ContentView: View {
    @Binding var document: WorkspaceDocument
    @State private var session = WorkspaceSession()
    @Environment(\.openWindow) private var openWindow
    /// Receives column widths from table windows opened from this workspace.
    @State private var widthSink = ColumnWidthSink()

    var body: some View {
        ZStack {
            // Window floor of 760 x 520; unlike .frame(minHeight:), this still lets a form that
            // needs more height (DB Table) raise the window minimum.
            Color.clear.frame(minWidth: 760, minHeight: 520)
            VStack(spacing: 0) {
                Picker("Form", selection: $session.form) {
                    ForEach(WorkspaceForm.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(10)

                Divider()

                Group {
                    switch session.form {
                    case .connection:
                        ConnectionForm(settings: $document.workspace.connection, session: session) {
                            await afterConnect()
                        }
                    case .tableSelection:
                        TableSelectionForm(session: session) { ref in
                            document.workspace.selectedTable = ref
                            if session.openInNewWindow {
                                openTableWindow(ref)
                            } else {
                                await session.openTable(ref, limit: document.workspace.view.fetchLimit)
                            }
                        }
                    case .table:
                        TableGridForm(session: session, view: $document.workspace.view)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()
                StatusBar(session: session, settings: document.workspace.connection)
            }
        }
        .focusedSceneValue(\.workspaceSession, session)
        .task { session.loadSavedPassword(for: document.workspace.connection) }
        .onDisappear {
            widthSink.save = nil
            let session = session
            Task { await session.disconnect() }
        }
        .sheet(isPresented: $session.showViewDialog) {
            ViewSettingsDialog(settings: $document.workspace.view, session: session)
        }
        .sheet(isPresented: $session.showUpdateDialog) {
            UpdateDialog(session: session, fetchLimit: document.workspace.view.fetchLimit)
        }
        .alert("MxDataSRM", isPresented: Binding(
            get: { session.errorMessage != nil },
            set: { if !$0 { session.errorMessage = nil } })
        ) {
            Button("OK") { session.errorMessage = nil }
        } message: {
            Text(session.errorMessage ?? "")
        }
    }

    /// Opens the DB Table form for `ref` in its own window, with its own connection.
    private func openTableWindow(_ ref: TableRef) {
        let document = $document
        widthSink.save = { table, widths in
            document.wrappedValue.workspace.view.columnWidths[table] = widths
        }
        let id = TableWindows.register(TableWindowRequest(
            settings: document.wrappedValue.workspace.connection, password: session.password,
            table: ref, view: document.wrappedValue.workspace.view, widthSink: widthSink))
        openWindow(value: id)
    }

    /// After connecting, show the table list with the workspace's saved table highlighted.
    private func afterConnect() async {
        guard session.isConnected else { return }
        session.form = .tableSelection
        if let saved = document.workspace.selectedTable {
            session.highlightedTableID = session.tables.first { $0.ref == saved }?.id
        }
    }
}

struct StatusBar: View {
    let session: WorkspaceSession
    let settings: ConnectionSettings

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).lineLimit(1).truncationMode(.middle)
            Spacer()
            if let info = session.infoMessage {
                Text(info).foregroundStyle(.secondary).lineLimit(1)
            }
            if session.busy || session.status == .connecting || session.countingRows {
                ProgressView().controlSize(.small)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var color: Color {
        switch session.status {
        case .connected: .green
        case .connecting: .yellow
        case .failed: .red
        case .disconnected: .secondary
        }
    }

    private var text: String {
        switch session.status {
        case .disconnected: "Not connected"
        case .connecting: "Connecting to \(settings.host)…"
        case .connected(let version): "\(settings.user)@\(settings.host):\(settings.port)/\(settings.database) — PostgreSQL \(version)"
        case .failed: "Connection failed"
        }
    }
}
