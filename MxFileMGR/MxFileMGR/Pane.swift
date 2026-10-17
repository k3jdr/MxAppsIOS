//
//  Pane.swift
//  MxFileMGR
//
//  A pane holds tabs; a tab shows one folder with its own history,
//  sort order, quick filter and selection.
//

import Foundation
import Observation

enum Side: String, Codable {
    case left, right
    var other: Side { self == .left ? .right : .left }
}

@Observable
final class BrowserTab: Identifiable {
    let id = UUID()
    private(set) var url: URL
    /// Entries after the quick filter, in display order.
    private(set) var items: [FileItem] = []
    /// Bumped whenever `items` or `folderSizes` change, so the list view knows to reload.
    private(set) var version = 0
    private(set) var error: String?
    private(set) var isLoading = false
    private(set) var folderSizes: [URL: Int64] = [:]

    var sort = SortOrder() {
        didSet { if sort != oldValue { refreshItems() } }
    }
    var filterText = "" {
        didSet { if filterText != oldValue { refreshItems() } }
    }
    /// Marked (selected) items, by URL. The ".." row is never part of it.
    var selection: Set<URL> = []

    /// Item to select and scroll to once the next listing arrives (e.g. the folder we came up from).
    @ObservationIgnored private var pendingFocus: URL?
    /// Read and cleared by the list view after a reload.
    @ObservationIgnored var scrollTarget: URL?

    @ObservationIgnored private var allItems: [FileItem] = []
    @ObservationIgnored private var backStack: [URL] = []
    @ObservationIgnored private var forwardStack: [URL] = []
    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var reloadScheduled = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(url: URL) {
        self.url = url.standardizedFileURL
        for name in [Notification.Name.mxListingOptionsChanged, .mxFilesChanged] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleReload() }
            })
        }
        startWatching()
        load()
    }

    /// Stops watching the folder; call when the tab is closed.
    func close() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        watcher = nil
        loadTask?.cancel()
    }

    var title: String { BrowserTab.displayName(of: url) }

    /// Folder name as shown in tabs and the path bar ("Macintosh HD" for /, "iCloud Drive", "OneDrive", "Google Drive", "Dropbox", "Box").
    static func displayName(of url: URL) -> String {
        if url.path == "/" { return FileManager.default.displayName(atPath: "/") }
        if let cloud = AppSettings.cloudLocation(at: url.path) { return cloud.name }
        return url.lastPathComponent
    }
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var parentURL: URL? { url.path == "/" ? nil : url.deletingLastPathComponent() }
    var selectedItems: [FileItem] { items.filter { selection.contains($0.url) } }

    // MARK: Navigation

    func navigate(to newURL: URL, focus: URL? = nil, recordHistory: Bool = true) {
        let target = newURL.standardizedFileURL
        guard target != url else {
            if let focus { pendingFocus = focus; load() }
            return
        }
        if recordHistory {
            backStack.append(url)
            forwardStack.removeAll()
        }
        url = target
        selection = []
        folderSizes = [:]
        allItems = []
        pendingFocus = focus
        filterText = ""
        startWatching()
        load()
    }

    func goUp() {
        guard let parent = parentURL else { return }
        navigate(to: parent, focus: url)
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(url)
        navigate(to: previous, focus: url, recordHistory: false)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(url)
        navigate(to: next, recordHistory: false)
    }

    func reload() { load() }

    /// Selects `url` after the next listing (used after creating or renaming an item).
    func focus(on url: URL) {
        pendingFocus = url.standardizedFileURL
        load()
    }

    // MARK: Folder sizes

    func calculateFolderSizes(_ targets: [FileItem]) {
        let dirs = (targets.isEmpty ? items : targets).filter(\.isDirectory)
        for dir in dirs {
            let url = dir.url
            Task { [weak self] in
                let bytes = await Task.detached(priority: .utility) { FileOps.totals(of: [url]).bytes }.value
                guard let self else { return }
                self.folderSizes[url] = bytes
                self.version += 1
            }
        }
    }

    // MARK: Loading

    private func load() {
        loadTask?.cancel()
        let dir = url
        let hidden = AppSettings.shared.showHidden
        isLoading = true
        loadTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result(catching: { try DirectoryLoader.load(dir, showHidden: hidden) })
            }.value
            guard let self, !Task.isCancelled, dir == self.url else { return }
            self.isLoading = false
            switch result {
            case .success(let list):
                self.allItems = list
                self.error = nil
            case .failure(let err):
                self.allItems = []
                self.error = err.localizedDescription
            }
            self.refreshItems()
        }
    }

    private func refreshItems() {
        var list = allItems
        let filter = filterText.trimmingCharacters(in: .whitespaces)
        if !filter.isEmpty {
            let matcher = NameMatcher(filter, substringIfPlain: true)
            list = list.filter { matcher.matches($0.name) }
        }
        items = DirectoryLoader.sorted(list, by: sort, foldersFirst: AppSettings.shared.foldersFirst)
        let present = Set(items.map(\.url))
        if let focus = pendingFocus, present.contains(focus) {
            selection = [focus]
            scrollTarget = focus
            pendingFocus = nil
        } else {
            selection.formIntersection(present)
        }
        version += 1
    }

    private func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self else { return }
            self.reloadScheduled = false
            self.load()
        }
    }

    private func startWatching() {
        watcher = DirectoryWatcher(url: url) { [weak self] in
            let tab = self
            Task { @MainActor in tab?.scheduleReload() }
        }
    }
}

@Observable
final class Pane {
    let side: Side
    private(set) var tabs: [BrowserTab]
    var activeIndex: Int

    init(side: Side, urls: [URL], activeIndex: Int) {
        self.side = side
        let list = urls.isEmpty ? [FileManager.default.homeDirectoryForCurrentUser] : urls
        let newTabs = list.map { BrowserTab(url: $0) }
        tabs = newTabs
        self.activeIndex = min(max(activeIndex, 0), newTabs.count - 1)
    }

    var active: BrowserTab { tabs[activeIndex] }

    func newTab(_ url: URL? = nil) {
        tabs.insert(BrowserTab(url: url ?? active.url), at: activeIndex + 1)
        activeIndex += 1
    }

    func closeTab(at index: Int) {
        guard tabs.count > 1, tabs.indices.contains(index) else { return }
        tabs[index].close()
        tabs.remove(at: index)
        if activeIndex >= index, activeIndex > 0 { activeIndex -= 1 }
    }

    func selectNextTab(_ step: Int) {
        guard tabs.count > 1 else { return }
        activeIndex = (activeIndex + step + tabs.count) % tabs.count
    }

    /// Exchanges the tabs of two panes (Swap Panes).
    func swapContents(with other: Pane) {
        (tabs, other.tabs) = (other.tabs, tabs)
        (activeIndex, other.activeIndex) = (other.activeIndex, activeIndex)
    }
}
