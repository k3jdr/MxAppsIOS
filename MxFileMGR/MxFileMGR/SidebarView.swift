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

    init(workspace: Workspace) { self.workspace = workspace }

    var body: some View {
        List {
            Section("Favorites") {
                ForEach(AppSettings.cloudLocations.filter { !settings.favorites.contains($0.url.path) }) { cloud in
                    row(title: cloud.name, icon: cloud.icon, url: cloud.url)
                        .contextMenu {
                            Button("Open in New Tab") { workspace.activePane.newTab(cloud.url) }
                            Button("Open in Other Pane") { workspace.otherTab.navigate(to: cloud.url) }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([cloud.url]) }
                        }
                }
                if showPhotos {
                    Button {
                        workspace.openPhotos()
                    } label: {
                        Label("iCloud Photos", systemImage: "photo.on.rectangle").lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help("Browse iCloud Photos and export originals into the active pane's folder")
                }
                if showS3 {
                    Button {
                        workspace.openS3()
                    } label: {
                        Label("Amazon S3", systemImage: "server.rack").lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help("Browse Amazon S3 buckets with your AWS CLI profiles")
                }
                Button {
                    workspace.openAzure()
                } label: {
                    Label("Azure Blob Storage", systemImage: "cylinder.split.1x2").lineLimit(1)
                }
                .buttonStyle(.plain)
                .help("Browse Azure Blob Storage with the Azure CLI (az login)")
                ForEach(settings.favorites, id: \.self) { path in
                    let url = URL(fileURLWithPath: path)
                    row(title: title(forFavorite: path), icon: icon(forFavorite: path), url: url)
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
                        }
                    }
                    .help(volume.capacityText)
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
                ForEach(settings.recentServers, id: \.self) { address in
                    Button {
                        workspace.sheet = .connect(prefill: address)
                    } label: {
                        Label(address, systemImage: "server.rack").lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Remove") { settings.recentServers.removeAll { $0 == address } }
                    }
                }
            }
        }
        .listStyle(.sidebar)
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
