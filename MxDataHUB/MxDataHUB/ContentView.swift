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
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            VStack(spacing: 0) {
                screen
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                StatusBar(store: store)
            }
            .navigationTitle(store.section.rawValue)
            .toolbar {
                if store.isConnected {
                    ToolbarItem(placement: .primaryAction) { databasePicker }
                }
            }
        }
        .frame(minWidth: 1360, minHeight: 720)
        .task { await start() }
        .onOpenURL { url in open(AppLink(url: url)) }
        .alert("MxDataHUB", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } })
        ) {
            Button("OK") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
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
