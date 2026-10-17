//
//  SidebarView.swift
//  MxFileMGR
//
//  Favorites (drop folders here to add them), mounted volumes with eject,
//  and recently used servers.
//

import AppKit
import SwiftUI

struct SidebarView: View {
    let workspace: Workspace
    private var settings = AppSettings.shared
    private var volumes = VolumeMonitor.shared
    private let showPhotos = PhotosModel.libraryExists
    private let showS3 = AWSCLI.isAvailable
    private var webDAV = WebDAVStore.shared
    private var sftp = SFTPStore.shared

    init(workspace: Workspace) { self.workspace = workspace }

    var body: some View {
        List {
            Section("Favorites") {
                ForEach(AppSettings.cloudLocations.filter { !settings.favorites.contains($0.url.path) }) { cloud in
                    row(title: cloud.name, icon: cloud.icon, url: cloud.url)
                        .quickHelp(cloud.name, FileHelp.cloudFolder(cloud.name, cloud.url), symbol: cloud.icon)
                        .contextMenu {
                            Button("Open in New Tab") { workspace.activePane.newTab(cloud.url) }
                            Button("Open in Other Pane") { workspace.otherTab.navigate(to: cloud.url) }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([cloud.url]) }
                        }
                }
                if AppSettings.sharePointURLs.isEmpty {
                    windowRow("SharePoint", icon: "building.2", help: FileHelp.sharePointSetup) { workspace.openSharePoint() }
                }
                if AppSettings.teamsChatFolders.isEmpty {
                    windowRow("Microsoft Teams", icon: "bubble.left.and.bubble.right", help: FileHelp.teamsSetup) { workspace.openTeams() }
                }
                if showPhotos {
                    windowRow("iCloud Photos", icon: "photo.on.rectangle", help: FileHelp.photos) { workspace.openPhotos() }
                }
                if showS3 {
                    windowRow("Amazon S3", icon: "server.rack", help: FileHelp.s3) { workspace.openS3() }
                }
                windowRow("Azure Blob Storage", icon: "cylinder.split.1x2", help: FileHelp.azure) { workspace.openAzure() }
                windowRow("Google Cloud Storage", icon: "cloud.circle", help: FileHelp.gcs) { workspace.openGCS() }
                ForEach(webDAV.accounts) { account in
                    let mounted = webDAV.mountPoint(for: account) != nil
                    Button {
                        WebDAVStore.shared.connect(account, in: workspace)
                    } label: {
                        HStack {
                            Label(account.name, systemImage: mounted ? "globe.americas.fill" : "globe").lineLimit(1)
                            if webDAV.connecting.contains(account.id) { Spacer(); ProgressView().controlSize(.mini) }
                        }
                    }
                    .buttonStyle(.plain)
                    .help(account.address)
                    .quickHelp(account.name, FileHelp.webDAVAccount(account, mounted: mounted), symbol: "globe")
                    .contextMenu {
                        Button("Connect and Open") { WebDAVStore.shared.connect(account, in: workspace) }
                        Button("Edit…") { workspace.sheet = .webDAV(account) }
                        Button("Disconnect") { WebDAVStore.shared.disconnect(account) }.disabled(!mounted)
                        Divider()
                        Button("Remove Account…") {
                            if Alerts.confirm("Remove the WebDAV account “\(account.name)”?",
                                              info: "Its saved password is removed from the Keychain too. Files on the server aren't touched.",
                                              ok: "Remove") {
                                WebDAVStore.shared.remove(account)
                            }
                        }
                    }
                }
                .onMove { WebDAVStore.shared.move(from: $0, to: $1) }
                windowRow("Add WebDAV Account…", icon: "plus.circle", help: FileHelp.addWebDAV) { workspace.addWebDAVAccount() }
                ForEach(sftp.accounts) { account in
                    Button {
                        workspace.openSFTP(account)
                    } label: {
                        Label(account.name, systemImage: "terminal").lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help(account.link(account.path))
                    .quickHelp(account.name, FileHelp.sftpAccount(account), symbol: "terminal")
                    .contextMenu {
                        Button("Open") { workspace.openSFTP(account) }
                        Button("Edit…") { workspace.sheet = .sftp(account) }
                        Divider()
                        Button("Remove Account…") {
                            if Alerts.confirm("Remove the SFTP account “\(account.name)”?",
                                              info: "Its saved password is removed from the Keychain too. Files on the server aren't touched.",
                                              ok: "Remove") {
                                SFTPStore.shared.remove(account)
                            }
                        }
                    }
                }
                .onMove { SFTPStore.shared.move(from: $0, to: $1) }
                windowRow("Add SFTP Account…", icon: "plus.circle", help: FileHelp.addSFTP) { workspace.addSFTPAccount() }
                ForEach(settings.favorites, id: \.self) { path in
                    let url = URL(fileURLWithPath: path)
                    row(title: title(forFavorite: path), icon: icon(forFavorite: path), url: url)
                        .quickHelp(title(forFavorite: path), "Opens \(path) in the active pane. Right-click to open it in a new tab or the other pane, or to remove it from Favorites; drag to reorder.", symbol: icon(forFavorite: path))
                        .contextMenu {
                            Button("Open in New Tab") { workspace.activePane.newTab(url) }
                            Button("Open in Other Pane") { workspace.otherTab.navigate(to: url) }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            Divider()
                            Button("Remove from Favorites") { settings.favorites.removeAll { $0 == path } }
                        }
                }
                .onMove { settings.favorites.move(fromOffsets: $0, toOffset: $1) }
            }
            .quickHelpArea(FileHelp.favorites)
            .dropDestination(for: URL.self) { urls, _ in
                let folders = urls.filter(FileOps.isRealDirectory)
                folders.forEach(settings.addFavorite)
                return !folders.isEmpty
            }

            Section("Locations") {
                ForEach(volumes.volumes) { volume in
                    HStack {
                        row(title: volume.name, icon: volume.isNetwork ? "network" : (volume.isEjectable ? "externaldrive" : "internaldrive"),
                            url: volume.url)
                        Spacer()
                        if volume.isEjectable {
                            Button {
                                volumes.eject(volume)
                            } label: {
                                Image(systemName: "eject")
                            }
                            .buttonStyle(.borderless)
                            .help("Eject “\(volume.name)”")
                            .quickHelp("Eject", "Unmounts “\(volume.name)” so it can be unplugged or disconnected.")
                        }
                    }
                    .help(volume.capacityText)
                    .quickHelp(volume.name, "Opens the volume in the active pane. \(volume.capacityText).", symbol: volume.isNetwork ? "network" : "externaldrive")
                    .contextMenu {
                        Button("Open in New Tab") { workspace.activePane.newTab(volume.url) }
                        Button("Open in Other Pane") { workspace.otherTab.navigate(to: volume.url) }
                        if volume.isEjectable { Button("Eject") { volumes.eject(volume) } }
                    }
                }
            }

            Section("Servers") {
                Button {
                    workspace.sheet = .connect(prefill: "")
                } label: {
                    Label("Connect to Server…", systemImage: "network")
                }
                .buttonStyle(.plain)
                .quickHelp("Connect to Server", FileHelp.connect.detail, shortcut: "⌘K", symbol: "network")
                ForEach(settings.recentServers, id: \.self) { address in
                    Button {
                        workspace.sheet = .connect(prefill: address)
                    } label: {
                        Label(address, systemImage: "server.rack").lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .quickHelp(address, "Opens Connect to Server with this address filled in. Right-click to remove it from the list.", symbol: "server.rack")
                    .contextMenu {
                        Button("Remove") { settings.recentServers.removeAll { $0 == address } }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .quickHelpDock()
    }

    /// A Favorites entry that opens a browser window (iCloud Photos, the cloud object stores).
    private func windowRow(_ title: String, icon: String, help: QuickHelpItem, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).lineLimit(1)
        }
        .buttonStyle(.plain)
        .help(help.detail)
        .quickHelp(title, help.detail, symbol: icon)
    }

    private func row(title: String, icon: String, url: URL) -> some View {
        Button {
            workspace.go(to: url)
        } label: {
            Label(title, systemImage: icon).lineLimit(1)
        }
        .buttonStyle(.plain)
        .help(url.path)
    }

    private func title(forFavorite path: String) -> String {
        AppSettings.cloudLocation(at: path)?.name ?? FileManager.default.displayName(atPath: path)
    }

    private func icon(forFavorite path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if let cloud = AppSettings.cloudLocation(at: path) { return cloud.icon }
        switch path {
        case home: return "house"
        case home + "/Desktop": return "menubar.dock.rectangle"
        case home + "/Documents": return "doc"
        case home + "/Downloads": return "arrow.down.circle"
        case "/Applications": return "app.badge"
        default: return "folder"
        }
    }
}

// MARK: - Volumes

nonisolated struct VolumeInfo: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let isEjectable: Bool
    let isNetwork: Bool
    let total: Int64
    let available: Int64
    var id: URL { url }

    var capacityText: String { "\(Fmt.size(available)) available of \(Fmt.size(total))" }
}

@Observable
final class VolumeMonitor {
    static let shared = VolumeMonitor()
    private(set) var volumes: [VolumeInfo] = []

    private init() {
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { VolumeMonitor.shared.refresh() }
            }
        }
    }

    func refresh() {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsEjectableKey, .volumeIsRemovableKey,
                                      .volumeIsLocalKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        volumes = urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return VolumeInfo(url: url,
                              name: v.volumeLocalizedName ?? url.lastPathComponent,
                              isEjectable: (v.volumeIsEjectable ?? false) || (v.volumeIsRemovable ?? false) || !(v.volumeIsLocal ?? true),
                              isNetwork: !(v.volumeIsLocal ?? true),
                              total: Int64(v.volumeTotalCapacity ?? 0),
                              available: Int64(v.volumeAvailableCapacity ?? 0))
        }
    }

    func eject(_ volume: VolumeInfo) {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: volume.url)
        } catch {
            Alerts.message("Couldn't eject “\(volume.name)”.", info: error.localizedDescription)
        }
    }
}
