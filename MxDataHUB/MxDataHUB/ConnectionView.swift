//
//  ConnectionView.swift
//  MxDataHUB
//
//  DB Connection: PostgreSQL host, port, user, database, password and SSL mode (the same screen
//  as MxDataSQL's). The fields are remembered by the app; the password is kept in the Keychain.
//

import SwiftUI

struct ConnectionView: View {
    @Bindable var store: SRMStore

    var body: some View {
        Form {
            Section("PostgreSQL Connection") {
                TextField("Host", text: $store.settings.host)
                TextField("Port", value: $store.settings.port, format: .number.grouping(.never))
                TextField("User", text: $store.settings.user)
                TextField("Database", text: $store.settings.database)
                SecureField("Password", text: $store.password)
                Picker("SSL", selection: $store.settings.sslMode) {
                    ForEach(SSLMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .quickHelp("SSL Mode", "disable: a plain connection. prefer: encrypted when the server offers TLS, plain otherwise. require: encrypted or no connection. The server's certificate isn't verified in any mode, as with libpq's prefer and require.", symbol: "lock")
                Toggle("Save password in Keychain", isOn: $store.settings.savePasswordInKeychain)
                    .quickHelp("Save Password in Keychain", "Keeps the password in your login Keychain so MxDataHUB can connect without asking. Turning it off removes the saved one.")
                    .onChange(of: store.settings.savePasswordInKeychain) { _, save in
                        if !save { Keychain.deletePassword(for: store.settings.keychainAccount) }
                    }
            }

            Section {
                HStack {
                    Button(store.isConnected ? "Reconnect" : "Connect") {
                        Task {
                            await store.connect()
                            // Go to work once the security master is there.
                            if store.available == true { store.section = .securities }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.status == .connecting || store.settings.host.isEmpty || store.settings.user.isEmpty)
                    .quickHelp(store.isConnected ? "Reconnect" : "Connect", "Connects with these fields and checks the database for the security master; then Securities opens.", shortcut: "⇧⌘K")

                    Button("Disconnect") {
                        Task { await store.disconnect() }
                    }
                    .disabled(!store.isConnected)
                    .quickHelp("Disconnect", "Closes the connection. Data Refresh and Services & Workflows still work: they go through the Layer 3 services.")

                    Spacer()
                    statusView
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("The connection fields are remembered by MxDataHUB; the password only in the Keychain.")
                    if store.isConnected, store.available == false {
                        Text("Database \(store.connectedSettings?.database ?? "") has no srm schema. Pick the database that has it in the Database drop-down, or create it with SRM/srm.py migrate and load it with SRM/srm.py load all.")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Other fields may have their own saved password.
        .onChange(of: store.settings.keychainAccount) {
            if store.settings.savePasswordInKeychain,
               let saved = Keychain.password(for: store.settings.keychainAccount) {
                store.password = saved
            }
        }
    }

    @ViewBuilder private var statusView: some View {
        switch store.status {
        case .disconnected:
            EmptyView()
        case .connecting:
            ProgressView().controlSize(.small)
        case .connected(let version):
            Label("Connected — PostgreSQL \(version)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .lineLimit(3)
                .textSelection(.enabled)
        }
    }
}
