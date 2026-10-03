//
//  PhotosView.swift
//  MxDeskMGR
//
//  iCloud Photos browser. The Photos library is not a plain folder (macOS
//  blocks reading it directly and files inside have coded names), so this
//  window uses PhotoKit: browse albums, select photos and videos, and export
//  their originals into the active pane's folder, downloading them from
//  iCloud when needed.
//

import AppKit
import Photos
import SwiftUI

struct PhotoAlbum: Identifiable, Hashable {
    let id: String
    let title: String
    let collection: PHAssetCollection?
}

enum PhotoMediaFilter: String, CaseIterable, Identifiable {
    case all = "All", photos = "Photos", videos = "Videos"
    var id: String { rawValue }
}

@Observable
final class PhotosModel {
    enum Access { case unknown, granted, denied }

    private(set) var access = Access.unknown
    private(set) var albums: [PhotoAlbum] = []
    var albumID = "all" { didSet { if albumID != oldValue { loadAssets() } } }
    var mediaFilter = PhotoMediaFilter.all { didSet { if mediaFilter != oldValue { loadAssets() } } }
    private(set) var assets: PHFetchResult<PHAsset>?
    var selection: Set<String> = []
    @ObservationIgnored let imageManager = PHCachingImageManager()

    /// Whether this Mac has a Photos library (shown in Favorites only then).
    static var libraryExists: Bool {
        let pictures = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: pictures.path)) ?? []
        return names.contains { $0.hasSuffix(".photoslibrary") }
    }

    func start() async {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        access = (status == .authorized || status == .limited) ? .granted : .denied
        guard access == .granted else { return }
        loadAlbums()
        loadAssets()
    }

    private func loadAlbums() {
        var list = [PhotoAlbum(id: "all", title: "All Photos", collection: nil)]
        let smart: [PHAssetCollectionSubtype] = [
            .smartAlbumFavorites, .smartAlbumRecentlyAdded, .smartAlbumVideos, .smartAlbumLivePhotos,
            .smartAlbumSelfPortraits, .smartAlbumPanoramas, .smartAlbumScreenshots,
        ]
        for subtype in smart {
            if let c = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil).firstObject {
                list.append(PhotoAlbum(id: c.localIdentifier, title: c.localizedTitle ?? "Album", collection: c))
            }
        }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "localizedTitle", ascending: true)]
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options).enumerateObjects { c, _, _ in
            list.append(PhotoAlbum(id: c.localIdentifier, title: c.localizedTitle ?? "Album", collection: c))
        }
        albums = list
    }

    private func loadAssets() {
        guard access == .granted else { return }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        switch mediaFilter {
        case .all: break
        case .photos: options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        case .videos: options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        }
        if let collection = albums.first(where: { $0.id == albumID })?.collection {
            assets = PHAsset.fetchAssets(in: collection, options: options)
        } else {
            assets = PHAsset.fetchAssets(with: options)
        }
        selection = []
    }

    func selectAll() {
        var ids = Set<String>()
        assets?.enumerateObjects { asset, _, _ in ids.insert(asset.localIdentifier) }
        selection = ids
    }

    /// Writes the original files of the selected items into `folder` as a background job.
    /// Live Photos also export their video, and RAW+JPEG pairs both files.
    func exportSelection(to folder: URL) {
        let ids = Array(selection)
        guard !ids.isEmpty else { return }
        TransferManager.shared.start("Exporting \(Fmt.count(ids.count, "item")) from iCloud Photos") { reporter in
            var list: [PHAsset] = []
            PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in list.append(asset) }
            let wanted: Set<PHAssetResourceType> = [.photo, .video, .audio, .pairedVideo, .alternatePhoto]
            for (index, asset) in list.enumerated() where !reporter.isCancelled {
                let all = PHAssetResource.assetResources(for: asset)
                let resources = all.filter { wanted.contains($0.type) }
                for resource in resources.isEmpty ? Array(all.prefix(1)) : resources {
                    if reporter.isCancelled { break }
                    let name = resource.originalFilename
                    reporter.step(index, of: list.count, name)
                    let ext = (name as NSString).pathExtension
                    let dest = FileOps.availableURL(in: folder, stem: (name as NSString).deletingPathExtension, ext: ext)
                    let options = PHAssetResourceRequestOptions()
                    options.isNetworkAccessAllowed = true
                    do {
                        try await PHAssetResourceManager.default().writeData(for: resource, toFile: dest, options: options)
                        if let date = asset.creationDate {
                            try? FileManager.default.setAttributes([.creationDate: date, .modificationDate: date],
                                                                   ofItemAtPath: dest.path)
                        }
                    } catch {
                        reporter.error("\(name): \(error.localizedDescription)")
                    }
                }
            }
        }
    }
}

struct PhotosView: View {
    @State private var model = PhotosModel()
    @State private var thumbSize: CGFloat = 120

    var body: some View {
        Group {
            switch model.access {
            case .unknown:
                ProgressView("Opening iCloud Photos…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .denied:
                ContentUnavailableView {
                    Label("No Access to Photos", systemImage: "lock")
                } description: {
                    Text("Allow MxDeskMGR in System Settings ▸ Privacy & Security ▸ Photos, then reopen this window.")
                } actions: {
                    Button("Open Privacy Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!)
                    }
                }
            case .granted:
                browser
            }
        }
        .navigationTitle("iCloud Photos")
        .task { await model.start() }
    }

    private var browser: some View {
        HSplitView {
            List(model.albums, selection: Binding(get: { model.albumID }, set: { model.albumID = $0 ?? "all" })) { album in
                Label(album.title, systemImage: album.collection == nil ? "photo.on.rectangle" : "rectangle.stack")
                    .tag(album.id)
            }
            .listStyle(.sidebar)
            .frame(minWidth: 160, idealWidth: 200, maxWidth: 300)

            VStack(spacing: 0) {
                HStack {
                    Picker("", selection: $model.mediaFilter) {
                        ForEach(PhotoMediaFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Spacer()
                    Image(systemName: "photo").imageScale(.small)
                    Slider(value: $thumbSize, in: 70...260).frame(width: 120)
                    Image(systemName: "photo").imageScale(.large)
                }
                .padding(8)
                Divider()
                grid
                Divider()
                footer
            }
            .frame(minWidth: 420)
        }
    }

    private var grid: some View {
        let count = model.assets?.count ?? 0
        return ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbSize, maximum: thumbSize + 40), spacing: 6)], spacing: 6) {
                ForEach(0..<count, id: \.self) { index in
                    if let asset = model.assets?.object(at: index) {
                        let id = asset.localIdentifier
                        PhotoCell(asset: asset, manager: model.imageManager, side: thumbSize,
                                  selected: model.selection.contains(id))
                            .onTapGesture {
                                if model.selection.contains(id) { model.selection.remove(id) } else { model.selection.insert(id) }
                            }
                    }
                }
            }
            .padding(8)
        }
        .overlay {
            if count == 0 { ContentUnavailableView("No Items", systemImage: "photo") }
        }
    }

    private var footer: some View {
        let folder = Workspace.current?.activeTab.url
        return HStack {
            Text("\(model.selection.count) of \(Fmt.count(model.assets?.count ?? 0, "item")) selected")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Select All") { model.selectAll() }
            Button("Select None") { model.selection = [] }.disabled(model.selection.isEmpty)
            Button("Open Photos") {
                if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Photos") {
                    NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
                }
            }
            Button(folder.map { "Export to “\(BrowserTab.displayName(of: $0))”" } ?? "Export") {
                if let folder { model.exportSelection(to: folder) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.selection.isEmpty || folder == nil)
            .help(folder.map { "Export the originals into \($0.path) (the active pane's folder)" } ?? "Open a main window first")
        }
        .padding(10)
    }
}

private struct PhotoCell: View {
    let asset: PHAsset
    let manager: PHCachingImageManager
    let side: CGFloat
    let selected: Bool
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(alignment: .bottomLeading) {
            if asset.mediaType == .video {
                Label(duration, systemImage: "video.fill")
                    .font(.caption2).foregroundStyle(.white)
                    .padding(3).background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 3))
                    .padding(4)
            }
        }
        .overlay(alignment: .topTrailing) {
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
                    .font(.title3).padding(4)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? Color.accentColor : .clear, lineWidth: 3))
        .contentShape(Rectangle())
        .help(asset.creationDate.map(Fmt.date) ?? "")
        .task(id: "\(asset.localIdentifier)-\(Int(side))") { image = await thumbnail() }
    }

    private var duration: String {
        let s = Int(asset.duration.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func thumbnail() async -> NSImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat   // one callback
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        let size = CGSize(width: side * 2, height: side * 2)
        return await withCheckedContinuation { continuation in
            manager.requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
}
