//
//  PhotosView.swift
//  MxFileMGR
//
//  iCloud Photos browser. The Photos library is not a plain folder (macOS
//  blocks reading it directly and files inside have coded names), so this
//  window uses PhotoKit: browse albums, select photos and videos, export
//  their originals into the active pane's folder (downloading them from
//  iCloud when needed), and clean up the library: delete, find duplicates,
//  long videos, favorite/hide, and add, remove, create, rename or delete albums.
//
//  PhotoKit can't rename a photo itself; "Export & Rename" exports the
//  originals and opens Multi-Rename on the exported files instead.
//

import AppKit
import Photos
import SwiftUI

struct PhotoAlbum: Identifiable, Hashable {
    let id: String
    let title: String
    let collection: PHAssetCollection?

    /// An album you made (or a shared album), as opposed to All Photos and the smart albums.
    var isUserAlbum: Bool { collection?.assetCollectionType == .album }
    func can(_ operation: PHCollectionEditOperation) -> Bool { collection?.canPerform(operation) ?? false }
}

enum PhotoMediaFilter: String, CaseIterable, Identifiable {
    case all = "All", photos = "Photos", videos = "Videos", longVideos = "Long Videos"
    var id: String { rawValue }
}

enum PhotoSort: String, CaseIterable, Identifiable {
    case newest = "Newest First", oldest = "Oldest First"
    var id: String { rawValue }
}

/// Forwards library changes (from this window, the Photos app or iCloud) to the model.
nonisolated final class PhotoLibraryObserver: NSObject, PHPhotoLibraryChangeObserver {
    private let onChange: @Sendable () -> Void
    init(onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }
    func photoLibraryDidChange(_ changeInstance: PHChange) { onChange() }
}

@Observable
final class PhotosModel {
    enum Access { case unknown, granted, denied }

    private(set) var access = Access.unknown
    private(set) var albums: [PhotoAlbum] = []
    var albumID = "all" { didSet { if albumID != oldValue { reload(keepSelection: false) } } }
    var mediaFilter = PhotoMediaFilter.all { didSet { if mediaFilter != oldValue { reload(keepSelection: false) } } }
    var sort = PhotoSort.newest { didSet { if sort != oldValue { reload(keepSelection: true) } } }
    /// Show only likely duplicates (same type, pixel size, capture second and duration), grouped.
    var showDuplicates = false { didSet { if showDuplicates != oldValue { reload(keepSelection: false) } } }
    var selection: Set<String> = []
    private(set) var findingDuplicates = false
    /// Position within its duplicate group, e.g. (1, 3), by local identifier.
    private(set) var duplicateInfo: [String: (index: Int, of: Int)] = [:]

    private var assets: PHFetchResult<PHAsset>?
    private var duplicateAssets: [PHAsset] = []
    @ObservationIgnored let imageManager = PHCachingImageManager()
    @ObservationIgnored private var observer: PhotoLibraryObserver?
    @ObservationIgnored private var reloadScheduled = false

    /// Whether this Mac has a Photos library (shown in Favorites only then).
    static var libraryExists: Bool {
        let pictures = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: pictures.path)) ?? []
        return names.contains { $0.hasSuffix(".photoslibrary") }
    }

    var currentAlbum: PhotoAlbum? { albums.first { $0.id == albumID } }
    /// User albums that photos can be added to.
    var targetAlbums: [PhotoAlbum] { albums.filter { $0.isUserAlbum && $0.can(.addContent) } }
    var count: Int { showDuplicates ? duplicateAssets.count : (assets?.count ?? 0) }

    func asset(at index: Int) -> PHAsset? {
        if showDuplicates { return duplicateAssets.indices.contains(index) ? duplicateAssets[index] : nil }
        guard let assets, index < assets.count else { return nil }
        return assets.object(at: index)
    }

    // MARK: Loading

    func start() async {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        access = (status == .authorized || status == .limited) ? .granted : .denied
        guard access == .granted else { return }
        let observer = PhotoLibraryObserver { [weak self] in
            let model = self
            Task { @MainActor in model?.libraryChanged() }
        }
        PHPhotoLibrary.shared().register(observer)
        self.observer = observer
        loadAlbums()
        reload(keepSelection: false)
    }

    func stop() {
        if let observer { PHPhotoLibrary.shared().unregisterChangeObserver(observer) }
        observer = nil
    }

    private func libraryChanged() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            reloadScheduled = false
            loadAlbums()
            if currentAlbum == nil { albumID = "all" }
            reload(keepSelection: true)
        }
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

    private func reload(keepSelection: Bool) {
        guard access == .granted else { return }
        let options = PHFetchOptions()
        switch mediaFilter {
        case .all: break
        case .photos: options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        case .videos: options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        case .longVideos:
            options.predicate = NSPredicate(format: "mediaType == %d AND duration >= 60", PHAssetMediaType.video.rawValue)
        }
        options.sortDescriptors = mediaFilter == .longVideos
            ? [NSSortDescriptor(key: "duration", ascending: false)]
            : [NSSortDescriptor(key: "creationDate", ascending: sort == .oldest)]
        if let collection = currentAlbum?.collection {
            assets = PHAsset.fetchAssets(in: collection, options: options)
        } else {
            assets = PHAsset.fetchAssets(with: options)
        }
        if showDuplicates {
            findDuplicates(keepSelection: keepSelection)
        } else {
            duplicateAssets = []
            duplicateInfo = [:]
            pruneSelection(keepSelection)
        }
    }

    private func pruneSelection(_ keep: Bool) {
        guard keep, !selection.isEmpty else { selection = []; return }
        let present = PHAsset.fetchAssets(withLocalIdentifiers: Array(selection), options: nil)
        var ids = Set<String>()
        present.enumerateObjects { asset, _, _ in ids.insert(asset.localIdentifier) }
        selection.formIntersection(ids)
    }

    /// Groups the current listing by (type, pixel size, capture second, duration) in the background.
    private func findDuplicates(keepSelection: Bool) {
        guard let assets else { return }
        findingDuplicates = true
        let fetch = assets
        Task {
            let groups = await Task.detached(priority: .userInitiated) { () -> [[String]] in
                var byKey: [String: [String]] = [:]
                var order: [String] = []
                fetch.enumerateObjects { a, _, _ in
                    let seconds = Int(a.creationDate?.timeIntervalSince1970 ?? 0)
                    let key = "\(a.mediaType.rawValue)|\(a.pixelWidth)x\(a.pixelHeight)|\(seconds)|\(Int(a.duration.rounded()))"
                    if byKey[key] == nil { order.append(key) }
                    byKey[key, default: []].append(a.localIdentifier)
                }
                return order.compactMap { byKey[$0] }.filter { $0.count > 1 }
            }.value
            guard showDuplicates else { findingDuplicates = false; return }
            let ids = groups.flatMap { $0 }
            var byID: [String: PHAsset] = [:]
            PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { a, _, _ in byID[a.localIdentifier] = a }
            duplicateAssets = ids.compactMap { byID[$0] }
            var info: [String: (index: Int, of: Int)] = [:]
            for group in groups {
                for (i, id) in group.enumerated() { info[id] = (i + 1, group.count) }
            }
            duplicateInfo = info
            findingDuplicates = false
            pruneSelection(keepSelection)
        }
    }

    var duplicateGroupCount: Int { duplicateInfo.values.filter { $0.index == 1 }.count }

    // MARK: Selection

    func selectAll() {
        if showDuplicates { selection = Set(duplicateAssets.map(\.localIdentifier)); return }
        var ids = Set<String>()
        assets?.enumerateObjects { asset, _, _ in ids.insert(asset.localIdentifier) }
        selection = ids
    }

    /// Selects every duplicate except one per group to keep: a favorite if the group has one, else the first.
    func selectDuplicateExtras() {
        var groups: [[PHAsset]] = []
        for asset in duplicateAssets {
            if duplicateInfo[asset.localIdentifier]?.index == 1 { groups.append([]) }
            if !groups.isEmpty { groups[groups.count - 1].append(asset) }
        }
        var ids = Set<String>()
        for group in groups {
            let keep = group.first(where: \.isFavorite) ?? group.first
            for asset in group where asset !== keep { ids.insert(asset.localIdentifier) }
        }
        selection = ids
    }

    private var selectionIDs: [String] { Array(selection) }

    // MARK: Changes (Photos asks for confirmation where it applies)

    /// Runs a library change; reports errors other than the user cancelling Photos' own confirmation.
    @discardableResult
    private func change(_ block: @escaping @Sendable () -> Void) async -> Bool {
        do {
            try await PHPhotoLibrary.shared().performChanges(block)
            return true
        } catch {
            let ns = error as NSError
            if !(ns.domain == PHPhotosErrorDomain && ns.code == PHPhotosError.userCancelled.rawValue) {
                Alerts.error(error)
            }
            return false
        }
    }

    /// Moves the selection to Recently Deleted (Photos confirms; restorable for 30 days).
    func deleteSelection() async {
        let ids = selectionIDs
        guard !ids.isEmpty else { return }
        if await change({ PHAssetChangeRequest.deleteAssets(PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)) }) {
            selection = []
        }
    }

    func removeSelectionFromAlbum() async {
        guard let album = currentAlbum?.collection, currentAlbum?.can(.removeContent) == true else { return }
        let ids = selectionIDs
        if await change({
            PHAssetCollectionChangeRequest(for: album)?.removeAssets(PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil))
        }) {
            selection = []
        }
    }

    func addSelection(to album: PhotoAlbum) async {
        guard let collection = album.collection else { return }
        let ids = selectionIDs
        await change {
            PHAssetCollectionChangeRequest(for: collection)?.addAssets(PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil))
        }
    }

    func newAlbum(withSelection: Bool) async {
        guard let title = Alerts.prompt(withSelection ? "New Album with \(Fmt.count(selection.count, "Item"))" : "New Album",
                                        initial: "Untitled Album", ok: "Create") else { return }
        let ids = withSelection ? selectionIDs : []
        await change {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            if !ids.isEmpty { request.addAssets(PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)) }
        }
    }

    func rename(_ album: PhotoAlbum) async {
        guard let collection = album.collection, album.can(.rename),
              let title = Alerts.prompt("Rename Album", initial: album.title, ok: "Rename"), title != album.title else { return }
        await change { PHAssetCollectionChangeRequest(for: collection)?.title = title }
    }

    /// Deletes the album only; its photos stay in the library. Photos confirms.
    func delete(_ album: PhotoAlbum) async {
        guard let collection = album.collection, album.can(.delete) else { return }
        await change { PHAssetCollectionChangeRequest.deleteAssetCollections([collection] as NSArray) }
    }

    func setFavorite(_ favorite: Bool) async {
        let ids = selectionIDs
        await change {
            PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { a, _, _ in
                PHAssetChangeRequest(for: a).isFavorite = favorite
            }
        }
    }

    /// Hides the selection (it moves to the Hidden album in Photos).
    func hideSelection() async {
        let ids = selectionIDs
        if await change({
            PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { a, _, _ in
                PHAssetChangeRequest(for: a).isHidden = true
            }
        }) {
            selection = []
        }
    }

    // MARK: Export

    /// Writes the original files of the selected items into `folder` as a background job.
    /// Live Photos also export their video, and RAW+JPEG pairs both files.
    /// `completion` gets the exported files (used by Export & Rename).
    func exportSelection(to folder: URL, completion: (@MainActor ([URL]) -> Void)? = nil) {
        let ids = selectionIDs
        guard !ids.isEmpty else { return }
        TransferManager.shared.start("Exporting \(Fmt.count(ids.count, "item")) from iCloud Photos") { reporter in
            var list: [PHAsset] = []
            PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in list.append(asset) }
            let wanted: Set<PHAssetResourceType> = [.photo, .video, .audio, .pairedVideo, .alternatePhoto]
            var exported: [URL] = []
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
                        exported.append(dest)
                    } catch {
                        reporter.error("\(name): \(error.localizedDescription)")
                    }
                }
            }
            if let completion, !reporter.isCancelled {
                let files = exported
                await MainActor.run { completion(files) }
            }
        }
    }
}

struct PhotosView: View {
    @State private var model = PhotosModel()
    @State private var thumbSize: CGFloat = 120
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            switch model.access {
            case .unknown:
                ProgressView("Opening iCloud Photos…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .denied:
                ContentUnavailableView {
                    Label("No Access to Photos", systemImage: "lock")
                } description: {
                    Text("Allow MxFileMGR in System Settings ▸ Privacy & Security ▸ Photos, then reopen this window.")
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
        .quickHelpScreen("iCloud Photos", FileHelp.photosScreen, selection: model.selection.isEmpty ? nil : QuickHelpItem(title: Fmt.count(model.selection.count, "Item") + " Selected", detail: "Export copies the originals to the active pane; Delete moves them to Recently Deleted; Organize adds them to an album, favorites or hides them.", symbol: "checkmark.circle"))
        .task { await model.start() }
        .onDisappear { model.stop() }
    }

    // MARK: Layout

    private var browser: some View {
        HSplitView {
            albumList
                .frame(minWidth: 170, idealWidth: 210, maxWidth: 320)
            VStack(spacing: 0) {
                topBar
                if model.showDuplicates { duplicatesBar }
                Divider()
                grid
                Divider()
                footer
            }
            .frame(minWidth: 520)
        }
    }

    private var albumList: some View {
        List(selection: Binding(get: { model.albumID }, set: { model.albumID = $0 ?? "all" })) {
            Section("Library") {
                ForEach(model.albums.filter { !$0.isUserAlbum }) { album in
                    Label(album.title, systemImage: album.collection == nil ? "photo.on.rectangle" : "gearshape")
                        .tag(album.id)
                }
            }
            Section("Albums") {
                ForEach(model.albums.filter(\.isUserAlbum)) { album in
                    Label(album.title, systemImage: "rectangle.stack")
                        .tag(album.id)
                        .contextMenu {
                            Button("Rename Album…") { Task { await model.rename(album) } }
                                .disabled(!album.can(.rename))
                            Button("Delete Album…") { Task { await model.delete(album) } }
                                .disabled(!album.can(.delete))
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { Task { await model.newAlbum(withSelection: false) } } label: {
                    Label("New Album", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
                if let album = model.currentAlbum, album.isUserAlbum {
                    Menu {
                        Button("Rename Album…") { Task { await model.rename(album) } }.disabled(!album.can(.rename))
                        Button("Delete Album…") { Task { await model.delete(album) } }.disabled(!album.can(.delete))
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
            }
            .padding(8)
        }
    }

    private var topBar: some View {
        HStack {
            Picker("", selection: $model.mediaFilter) {
                ForEach(PhotoMediaFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Picker("", selection: $model.sort) {
                ForEach(PhotoSort.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().fixedSize()
            .disabled(model.mediaFilter == .longVideos)
            .help(model.mediaFilter == .longVideos ? "Long videos are listed longest first" : "")
            Toggle(isOn: $model.showDuplicates) {
                Label("Duplicates", systemImage: "square.on.square")
            }
            .toggleStyle(.button)
            .help("Show only likely duplicates: same type, size, capture time and duration")
            .quickHelp("Duplicates", "Shows only likely duplicates — same type, pixel size, capture second and duration — in numbered groups. Select Extras then selects all but one of each.")
            Spacer()
            Image(systemName: "photo").imageScale(.small)
            Slider(value: $thumbSize, in: 70...260).frame(width: 110)
            Image(systemName: "photo").imageScale(.large)
        }
        .padding(8)
    }

    private var duplicatesBar: some View {
        HStack {
            if model.findingDuplicates {
                ProgressView().controlSize(.small)
                Text("Looking for duplicates…")
            } else {
                Text("\(Fmt.count(model.duplicateGroupCount, "group")) of duplicates, \(Fmt.count(model.count, "item"))")
            }
            Spacer()
            Button("Select Extras") { model.selectDuplicateExtras() }
                .disabled(model.count == 0)
                .help("Select all but one of each group (keeps a favorite if there is one), ready to delete")
        }
        .font(.callout)
        .padding(.horizontal, 8).padding(.bottom, 6)
    }

    private var grid: some View {
        let count = model.count
        return ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbSize, maximum: thumbSize + 40), spacing: 6)], spacing: 6) {
                ForEach(0..<count, id: \.self) { index in
                    if let asset = model.asset(at: index) {
                        let id = asset.localIdentifier
                        PhotoCell(asset: asset, manager: model.imageManager, side: thumbSize,
                                  selected: model.selection.contains(id), duplicate: model.duplicateInfo[id])
                            .onTapGesture {
                                if model.selection.contains(id) { model.selection.remove(id) } else { model.selection.insert(id) }
                            }
                            .contextMenu { itemMenu(for: id) }
                    }
                }
            }
            .padding(8)
        }
        .focusable()
        .focusEffectDisabled()
        .onDeleteCommand { Task { await model.deleteSelection() } }
        .overlay {
            if count == 0, !model.findingDuplicates {
                ContentUnavailableView(model.showDuplicates ? "No Duplicates" : "No Items",
                                       systemImage: model.showDuplicates ? "checkmark.circle" : "photo")
            }
        }
    }

    /// Right-clicking an item that isn't selected makes it the selection first, so the menu acts on it.
    @ViewBuilder private func itemMenu(for id: String) -> some View {
        organizeItems(for: id)
        Divider()
        Button("Delete…", role: .destructive) {
            pick(id)
            Task { await model.deleteSelection() }
        }
    }

    private func pick(_ id: String?) {
        if let id, !model.selection.contains(id) { model.selection = [id] }
    }

    /// Favorite, hide, album and Export & Rename commands; `id` is the right-clicked item, if any.
    @ViewBuilder private func organizeItems(for id: String?) -> some View {
        Button("Favorite") { pick(id); Task { await model.setFavorite(true) } }
        Button("Unfavorite") { pick(id); Task { await model.setFavorite(false) } }
        Button("Hide") { pick(id); Task { await model.hideSelection() } }
        Divider()
        Menu("Add to Album") {
            ForEach(model.targetAlbums) { album in
                Button(album.title) { pick(id); Task { await model.addSelection(to: album) } }
            }
            if !model.targetAlbums.isEmpty { Divider() }
            Button("New Album with Selection…") { pick(id); Task { await model.newAlbum(withSelection: true) } }
        }
        if let album = model.currentAlbum, album.isUserAlbum {
            Button("Remove from “\(album.title)”") { pick(id); Task { await model.removeSelectionFromAlbum() } }
                .disabled(!album.can(.removeContent))
        }
        Divider()
        Button("Export & Rename…") { pick(id); exportAndRename() }
            .disabled(Workspace.current == nil)
    }

    private var footer: some View {
        let folder = Workspace.current?.activeTab.url
        let none = model.selection.isEmpty
        return HStack {
            Text("\(model.selection.count) of \(Fmt.count(model.count, "item")) selected")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Select All") { model.selectAll() }
            Button("Select None") { model.selection = [] }.disabled(none)
            Menu("Organize") { organizeItems(for: nil) }
                .fixedSize()
                .disabled(none)
            Button("Delete…", role: .destructive) { Task { await model.deleteSelection() } }
                .disabled(none)
                .help("Move to Recently Deleted in Photos (recoverable for 30 days). Also the Delete key.")
            Button("Open Photos") {
                if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Photos") {
                    NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
                }
            }
            Button(folder.map { "Export to “\(BrowserTab.displayName(of: $0))”" } ?? "Export") {
                if let folder { model.exportSelection(to: folder) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(none || folder == nil)
            .help(folder.map { "Export the originals into \($0.path) (the active pane's folder)" } ?? "Open a main window first")
        }
        .padding(10)
    }

    /// Photos can't rename a photo, so export the originals and rename the files with Multi-Rename.
    private func exportAndRename() {
        guard let workspace = Workspace.current, !model.selection.isEmpty else { return }
        let folder = workspace.activeTab.url
        model.exportSelection(to: folder) { files in
            guard !files.isEmpty else { return }
            openWindow(value: RenameRequest(urls: files))
        }
    }
}

private struct PhotoCell: View {
    let asset: PHAsset
    let manager: PHCachingImageManager
    let side: CGFloat
    let selected: Bool
    let duplicate: (index: Int, of: Int)?
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
            HStack(spacing: 3) {
                if asset.isFavorite { Image(systemName: "heart.fill") }
                if asset.mediaType == .video { Label(duration, systemImage: "video.fill") }
                if let duplicate { Text("\(duplicate.index) of \(duplicate.of)") }
            }
            .font(.caption2).foregroundStyle(.white)
            .padding(3).background(.black.opacity(asset.isFavorite || asset.mediaType == .video || duplicate != nil ? 0.45 : 0),
                                   in: RoundedRectangle(cornerRadius: 3))
            .padding(4)
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
        .help(tooltip)
        .task(id: "\(asset.localIdentifier)-\(Int(side))") { image = await thumbnail() }
    }

    private var tooltip: String {
        var parts = [asset.creationDate.map(Fmt.date) ?? ""]
        parts.append("\(asset.pixelWidth) × \(asset.pixelHeight)")
        return parts.joined(separator: " · ")
    }

    private var duration: String {
        let s = Int(asset.duration.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
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
