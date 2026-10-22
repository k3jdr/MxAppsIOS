//
//  ContentView.swift
//  MxDataHUB
//
//  The main window: a sidebar of screens, the selected screen, and a status bar. The security
//  master screens need a connection to a database that has the srm schema.
//

import SwiftUI

struct ContentView: View {
    @Bindable var store: SRMStore

    var body: some View {
        NavigationSplitView {
            List(SRMSection.allCases, selection: Binding(
                get: { Optional(store.section) },
                set: { if let s = $0 { store.section = s } })
            ) { section in
                Label(section.rawValue, systemImage: section.systemImage)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .quickHelpArea(HubHelp.about(section))
                    .tag(section)
            }
            // Quick Help: what's under the pointer, at the bottom of the sidebar.
            .quickHelpDock()
            .fixedColumnMinimum(width: 180, height: 420)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            VStack(spacing: 0) {
                screen
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                StatusBar(store: store)
                    .quickHelpArea("Status", "The connection — server, database and PostgreSQL version, and whether it has the security master — and the last action's message.",
                                   symbol: "info.circle")
            }
            .navigationTitle(store.section.rawValue)
            .toolbar {
                if store.isConnected {
                    ToolbarItem(placement: .primaryAction) { databasePicker }
                }
            }
        }
        // The window's minimum: the widest sidebar (260) and the widest screen (Data Refresh, about 1017; each
        // screen's panes have fixed minimums). It used to be 1360 while Load History alone needed over 1200, so the
        // split view was wider than the window and centred in it: the sidebar fell off the left edge and the
        // screen's right side was cut off, worst after showing a hidden sidebar.
        .frame(minWidth: 1280, minHeight: 720)
        .quickHelpScreen(store.section.rawValue, HubHelp.screen(store), selection: HubHelp.selection(store))
        .task { await start() }
        .onOpenURL { url in open(AppLink(url: url)) }
        .errorDialog("MxDataHUB", message: $store.errorMessage)
    }

    @ViewBuilder
    private var screen: some View {
        if store.section == .connection {
            ConnectionView(store: store)
        } else if store.section == .refresh {
            DataRefreshView(store: store)
        } else if store.section == .services {
            ServicesWorkflowsView(store: store)
        } else if !store.isConnected {
            ContentUnavailableView {
                Label("Not Connected", systemImage: "cable.connector.slash")
            } description: {
                Text("Connect to the PostgreSQL database that holds the srm schema.")
            } actions: {
                Button("DB Connection…") { store.section = .connection }
            }
        } else if store.available != true {
            ContentUnavailableView {
                Label("No Security Master Here", systemImage: "building.columns")
            } description: {
                Text("Database \(store.connectedSettings?.database ?? "") has no srm schema. Choose the database that has it in the Database drop-down, or create it with SRM/srm.py migrate and load it with SRM/srm.py load all.")
            }
        } else {
            switch store.section {
            case .connection, .refresh, .services: EmptyView()
            case .securities: SRMSecuritiesView(store: store)
            case .portfolios: SRMPortfoliosView(store: store)
            case .benchmarks: SRMBenchmarksView(store: store)
            case .loads: SRMLoadsView(store: store)
            }
        }
    }

    /// mxdatahub:// links from MxJobsWMS (Shared/AppLinks.swift).
    private func open(_ link: AppLink?) {
        switch link {
        case .portfolio(let code)?:
            store.section = .portfolios
            if let p = store.portfolios.first(where: { $0.code.caseInsensitiveCompare(code) == .orderedSame }) {
                store.selectedPortfolioID = p.id
            }
        case .benchmark(let code)?:
            store.section = .benchmarks
            if let b = store.benchmarks.first(where: { $0.code.caseInsensitiveCompare(code) == .orderedSame }) {
                store.selectedBenchmarkID = b.id
            }
        case .dataRefresh?: store.section = .refresh
        case .services?: store.section = .services
        default: break
        }
    }

    /// Database on the connected server; choosing another reconnects with the same user and password.
    private var databasePicker: some View {
        Picker(selection: Binding(
            get: { store.connectedSettings?.database ?? store.settings.database },
            set: { name in Task { await store.switchDatabase(to: name) } })
        ) {
            ForEach(store.databases, id: \.self) { Text($0).tag($0) }
        } label: {
            Label("Database", systemImage: "cylinder.split.1x2")
        }
        .pickerStyle(.menu)
        .fixedSize()
        .disabled(store.busy || store.status == .connecting)
        .help("Database on \(store.connectedSettings?.host ?? ""); choosing another reconnects with the same user and password")
        .quickHelp("Database", "The database on \(store.connectedSettings?.host ?? "the server") this window works in. Choosing another reconnects with the same user and password.")
    }

    /// Saved password, then launch arguments for testing and demos:
    /// `-autoConnect YES -section Portfolios -query AAPL` (connection fields: `-host`, `-port`,
    /// `-user`, `-database`, `-sslMode`). Debug builds also take the password from PGPASSWORD.
    private func start() async {
        store.loadSavedPassword()
        #if DEBUG
        if store.password.isEmpty, let env = ProcessInfo.processInfo.environment["PGPASSWORD"] {
            store.password = env
        }
        #endif
        let defaults = UserDefaults.standard
        if let query = defaults.string(forKey: "query") { store.query = query }
        if defaults.bool(forKey: "autoConnect"), !store.password.isEmpty {
            await store.connect()
            if store.available == true { store.section = .securities }
        }
        if let name = defaults.string(forKey: "section"), let section = SRMSection(rawValue: name) {
            store.section = section
        }
    }
}

extension View {
    /// Gives a split-view column or pane a constant minimum size, as MxJobsWMS does: one taken from the content
    /// (a console's longest line, a text that wraps) changes as the content does, and widened the window or made
    /// AppKit loop on updating constraints. Content that needs more is clipped on the right. Not for the detail
    /// column itself: there it made hiding the sidebar on Securities loop and abort.
    func fixedColumnMinimum(width: CGFloat, height: CGFloat) -> some View {
        frame(minWidth: width, maxWidth: .infinity, minHeight: height, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
    }
}

struct StatusBar: View {
    let store: SRMStore

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).lineLimit(1).truncationMode(.middle)
            Spacer()
            if let info = store.infoMessage {
                Text(info).foregroundStyle(.secondary).lineLimit(1)
            }
            if store.busy || store.status == .connecting {
                ProgressView().controlSize(.small)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var color: Color {
        switch store.status {
        case .connected: .green
        case .connecting: .yellow
        case .failed: .red
        case .disconnected: .secondary
        }
    }

    private var text: String {
        switch store.status {
        case .disconnected: "Not connected"
        case .connecting: "Connecting to \(store.settings.host)…"
        case .connected(let version):
            "\(store.connectedSettings?.displayName ?? "") — PostgreSQL \(version)"
                + (store.available == true ? " — security master" : "")
        case .failed: "Connection failed"
        }
    }
}
