//
//  OneDriveViews.swift
//  MxNoteONE
//
//  Open Notebook from OneDrive, the OneDrive settings pane, and the
//  OneDrive items of the notebook menus.
//

import SwiftUI

struct OneDriveOpenSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var sync = OneDriveSync.shared
    @Bindable private var auth = OneDriveAuth.shared
    @State private var selection: String?
    @State private var folder = Prefs.notebooksFolder

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open Notebook from OneDrive").font(.headline)
            if auth.clientID.isEmpty {
                Text(OneDriveError.noClientID.localizedDescription)
                    .foregroundStyle(.secondary)
                SettingsLink { Text("Open Settings…") }
            } else if !auth.isSignedIn {
                Text("Sign in with your Microsoft account to see your OneNote notebooks.")
                    .foregroundStyle(.secondary)
                Button("Sign In…") { sync.signIn() }
            } else {
                HStack {
                    Text(auth.account ?? "").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        Task { await sync.loadRemoteNotebooks() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh")
                }
                List(selection: $selection) {
                    ForEach(sync.remoteNotebooks) { notebook in
                        let linked = NotebookStore.shared.notebooks.contains { $0.manifest.oneNote?.notebookID == notebook.id }
                        HStack {
                            Image(systemName: "book.closed.fill").foregroundStyle(.purple)
                            VStack(alignment: .leading) {
                                Text(notebook.name)
                                Text((notebook.modified?.formatted(date: .abbreviated, time: .shortened) ?? "")
                                     + (notebook.shared ? " · Shared" : "") + (linked ? " · Already open" : ""))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(notebook.id)
                    }
                }
                .frame(height: 260)
                .overlay {
                    if sync.loadingNotebooks {
                        ProgressView()
                    } else if sync.remoteNotebooks.isEmpty {
                        Text("No OneNote notebooks found.").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Keep the local copy in:") {
                    HStack {
                        Text(folder.path(percentEncoded: false)).lineLimit(1).truncationMode(.middle)
                        Button("Choose…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.canCreateDirectories = true
                            panel.directoryURL = folder
                            if panel.runModal() == .OK, let url = panel.url { folder = url }
                        }
                    }
                }
                .font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open") {
                    if let notebook = sync.remoteNotebooks.first(where: { $0.id == selection }) {
                        sync.open(notebook, in: folder)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil || sync.busy)
            }
        }
        .padding(20)
        .frame(width: 500)
        .task(id: auth.isSignedIn) { await sync.loadRemoteNotebooks() }
    }
}

struct OneDriveSettingsView: View {
    @AppStorage(OneDriveAuth.clientIDKey) private var clientID = ""
    @AppStorage(OneDriveAuth.tenantKey) private var tenant = ""
    @AppStorage(Prefs.oneDriveAutoSyncKey) private var autoSync = 0
    @Bindable private var auth = OneDriveAuth.shared
    @Bindable private var sync = OneDriveSync.shared

    var body: some View {
        Form {
            Section("Microsoft Account") {
                LabeledContent("Status:") {
                    if auth.isSignedIn {
                        HStack {
                            Text(auth.account ?? "Signed in")
                            Spacer()
                            Button("Sign Out") { auth.signOut() }
                        }
                    } else {
                        HStack {
                            Text("Not signed in").foregroundStyle(.secondary)
                            Spacer()
                            Button("Sign In…") { sync.signIn() }
                                .disabled(clientID.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
                Picker("Sync automatically:", selection: $autoSync) {
                    Text("Only when I choose Sync").tag(0)
                    Text("Every 5 minutes").tag(5)
                    Text("Every 15 minutes").tag(15)
                    Text("Every hour").tag(60)
                }
                .onChange(of: autoSync) { sync.scheduleAutoSync() }
            }
            Section("App Registration") {
                TextField("Application (client) ID:", text: $clientID, prompt: Text("00000000-0000-0000-0000-000000000000"))
                TextField("Tenant:", text: $tenant, prompt: Text("common"))
                VStack(alignment: .leading, spacing: 6) {
                    Text("One-time setup:").fontWeight(.medium)
                    Text("1. In the Azure portal, open App registrations ▸ New registration. Supported accounts: “Accounts in any organizational directory and personal Microsoft accounts”.")
                    Text("2. Authentication ▸ Add a platform ▸ iOS / macOS, bundle ID com.k3jdr.MxNoteONE. This adds the redirect URI:")
                    Text(OneDriveAuth.redirectURI).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Text("3. API permissions ▸ Microsoft Graph ▸ Delegated: Notes.ReadWrite and User.Read.")
                    Text("4. Paste the Application (client) ID above, then Sign In.")
                    Link("Open App registrations in the Azure portal",
                         destination: URL(string: "https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade")!)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

/// OneDrive items for a notebook's menus.
struct OneDriveNotebookMenu: View {
    let notebook: Notebook

    var body: some View {
        let sync = OneDriveSync.shared
        if let link = notebook.manifest.oneNote {
            Button("Sync with OneDrive") { sync.sync(notebook) }
            if let url = link.clientURL.flatMap(URL.init(string:)) {
                Button("Open in OneNote") { NSWorkspace.shared.open(url) }
            }
            if let url = link.webURL.flatMap(URL.init(string:)) {
                Button("Open in OneNote for the Web") { WebBrowser.open(url) }
            }
            Button("Stop Syncing with OneDrive") { sync.unlink(notebook) }
        } else {
            Button("Save to OneDrive (OneNote)") { sync.save(notebook) }
        }
    }
}

/// Sync progress shown at the bottom of the sidebar.
struct OneDriveStatusView: View {
    @Bindable private var sync = OneDriveSync.shared
    @Bindable private var importer = ImportActivity.shared

    var body: some View {
        if importer.busy {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(importer.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
        }
        if sync.busy || !sync.status.isEmpty {
            HStack(spacing: 6) {
                if sync.busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "checkmark.icloud").foregroundStyle(.secondary)
                }
                Text(sync.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
                if !sync.busy {
                    Button {
                        sync.status = ""
                    } label: {
                        Image(systemName: "xmark").font(.caption2)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
        }
    }
}
