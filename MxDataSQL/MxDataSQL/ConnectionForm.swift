//
//  ConnectionForm.swift
//  MxDataSQL
//
//  Form 1 — DB Connection: PostgreSQL host, port, user, database, password.
//

import SwiftUI

struct ConnectionForm: View {
    @Binding var settings: ConnectionSettings
    @Bindable var session: WorkspaceSession
    var onConnected: () async -> Void

    var body: some View {
        Form {
            Section("PostgreSQL Connection") {
                TextField("Host", text: $settings.host)
                TextField("Port", value: $settings.port, format: .number.grouping(.never))
                TextField("User", text: $settings.user)
                TextField("Database", text: $settings.database)
                SecureField("Password", text: $session.password)
                Picker("SSL", selection: $settings.sslMode) {
                    ForEach(SSLMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .quickHelp("SSL Mode", "disable: a plain connection. prefer: encrypted when the server offers TLS, plain otherwise. require: encrypted or no connection. The server's certificate isn't verified in any mode, as with libpq's prefer and require.", symbol: "lock")
                Toggle("Save password in Keychain", isOn: $settings.savePasswordInKeychain)
                    .quickHelp("Save Password in Keychain", "Keeps the password in your login Keychain (never in the workspace file) so the workspace can connect without asking. Turning it off removes it.")
                    .onChange(of: settings.savePasswordInKeychain) { _, save in
                        if !save { Keychain.deletePassword(for: settings.keychainAccount) }
                    }
            }

            Section {
                HStack {
                    Button(session.isConnected ? "Reconnect" : "Connect") {
                        Task {
                            await session.connect(settings)
                            await onConnected()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(session.status == .connecting || settings.host.isEmpty || settings.user.isEmpty)
                    .quickHelp(session.isConnected ? "Reconnect" : "Connect", "Connects with these fields, then lists the database's tables in DB Table Selection.", shortcut: "↩")

                    Button("Disconnect") {
                        Task { await session.disconnect() }
                    }
                    .disabled(!session.isConnected)
                    .quickHelp("Disconnect", "Closes this workspace's connection. Table windows opened from it keep their own.")

                    Spacer()
                    statusView
                }
            } footer: {
                Text("The password is not stored in the workspace file.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 560)
    }

    @ViewBuilder private var statusView: some View {
        switch session.status {
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
