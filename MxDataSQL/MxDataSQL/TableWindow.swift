//
//  TableWindow.swift
//  MxDataSQL
//
//  "Open in New Window" from DB Table Selection: the DB Table form (SQL box,
//  editable grid, Update, View, Reload) in its own window. Each table window
//  has its own WorkspaceSession and therefore its own database connection, so
//  its transactions never interleave with another window's. Column widths set in a
//  table window are saved to its workspace while that workspace window is open.
//

import SwiftUI

/// Identifies a table window. Only a random id is part of the scene value, so no
/// connection details or password are written to disk by window state restoration.
nonisolated struct TableWindowID: Codable, Hashable {
    var id = UUID()
}

/// What a table window needs in order to open; handed over in memory only.
struct TableWindowRequest {
    var settings: ConnectionSettings
    var password: String
    var table: TableRef
    var view: GridViewSettings
    /// Saves column widths into the workspace the window was opened from. Weak: once
    /// that workspace window closes, widths stay local to the table window.
    weak var widthSink: ColumnWidthSink?
}

/// Owned by a workspace window; writes column widths into its document while it is open.
final class ColumnWidthSink {
    /// Table ("schema.name") → column widths, or nil to clear them.
    var save: ((_ table: String, _ widths: [String: Double]?) -> Void)?
}

enum TableWindows {
    private static var pending: [UUID: TableWindowRequest] = [:]

    /// Registers a request and returns the value to pass to `openWindow(value:)`.
    static func register(_ request: TableWindowRequest) -> TableWindowID {
        let id = TableWindowID()
        pending[id.id] = request
        return id
    }

    /// Hands the request to the window that opened for it (once).
    static func take(_ id: TableWindowID) -> TableWindowRequest? {
        pending.removeValue(forKey: id.id)
    }
}

struct TableWindowView: View {
    let id: TableWindowID?
    @State private var session = WorkspaceSession()
    @State private var request: TableWindowRequest?
    /// View settings of this window; they start as a copy of the workspace's.
    @State private var view = GridViewSettings()
    @State private var started = false

    var body: some View {
        let screen = SQLHelp.tableWindowScreen(session)
        ZStack {
            Color.clear.frame(minWidth: 700, minHeight: 420 + SQLHelp.dockedHeight)
            VStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                QuickHelpDock(height: SQLHelp.dockHeight)
                Divider()
                StatusBar(session: session, settings: request?.settings ?? ConnectionSettings())
            }
        }
        .navigationTitle(title)
        .quickHelpScreen(screen.name, screen.item, selection: SQLHelp.selection(session))
        .onAppear { SQLHelp.install() }
        .focusedSceneValue(\.workspaceSession, session)
        .task { await start() }
        .onChange(of: view.columnWidths) { old, new in
            // Column widths also go to the workspace, like widths set in its own DB Table form.
            // Skipped while starting: that change is the copy of the workspace's own widths.
            guard started else { return }
            for table in Set(old.keys).union(new.keys) where old[table] != new[table] {
                request?.widthSink?.save?(table, new[table])
            }
        }
        .onDisappear {
            let session = session
            Task { await session.disconnect() }
        }
        .sheet(isPresented: $session.showViewDialog) {
            ViewSettingsDialog(settings: $view, session: session)
        }
        .sheet(isPresented: $session.showUpdateDialog) {
            UpdateDialog(session: session, fetchLimit: view.fetchLimit)
        }
        .alert("MxDataSQL", isPresented: Binding(
            get: { session.errorMessage != nil },
            set: { if !$0 { session.errorMessage = nil } })
        ) {
            Button("OK") { session.errorMessage = nil }
        } message: {
            Text(session.errorMessage ?? "")
        }
    }

    @ViewBuilder private var content: some View {
        if request == nil && started {
            ContentUnavailableView("Table Window Unavailable", systemImage: "macwindow.badge.plus",
                                   description: Text("Open the table again from DB Table Selection in its workspace."))
        } else if case .failed(let message) = session.status {
            ContentUnavailableView("Connection Failed", systemImage: "exclamationmark.triangle",
                                   description: Text(message))
        } else if session.status == .connecting || (session.grid == nil && session.busy) || !started {
            ProgressView("Opening \(request?.table.displayName ?? "table")…")
        } else {
            TableGridForm(session: session, view: $view)
        }
    }

    private var title: String {
        guard let request else { return "Table" }
        let s = request.settings
        return "\(request.table.displayName) — \(s.user)@\(s.host)/\(s.database)"
    }

    private func start() async {
        guard !started else { return }
        defer { started = true }
        guard let id, let request = TableWindows.take(id) else { return }
        self.request = request
        view = request.view
        session.password = request.password
        await session.connect(request.settings)
        guard session.isConnected else { return }
        await session.openTable(request.table, limit: view.fetchLimit)
    }
}
