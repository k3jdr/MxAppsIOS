//
//  NotebookStore.swift
//  MxNoteONE
//
//  Open notebooks, the current selection (section and page), navigation
//  history, and every change to notebooks, sections and pages. Files are
//  written as soon as something changes; the page canvas saves page content
//  a moment after typing stops.
//

import AppKit
import CryptoKit
import Observation

@Observable
final class Notebook: Identifiable {
    var url: URL
    var manifest: NotebookManifest
    /// Loaded page lists, by section ID. Locked sections are not loaded.
    var sections: [UUID: SectionContent] = [:]
    /// Unlocked password-protected sections.
    var unlocked: Set<UUID> = []
    @ObservationIgnored var keys: [UUID: SymmetricKey] = [:]

    var id: UUID { manifest.id }
    var name: String { manifest.name }

    init(url: URL, manifest: NotebookManifest) {
        self.url = url
        self.manifest = manifest
    }

    var manifestURL: URL { url.appending(path: "notebook.json") }
    func sectionURL(_ id: UUID) -> URL { url.appending(path: "sections/\(id.uuidString).json") }
    func pageURL(_ id: UUID) -> URL { url.appending(path: "pages/\(id.uuidString).json") }
    func assetURL(_ name: String) -> URL { url.appending(path: "assets/\(name)") }
}

struct AlertInfo: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

enum PasswordMode: String {
    case set, change, remove, unlock
}

enum ActiveSheet: Identifiable {
    case newNotebook
    case renameNotebook(UUID)
    case renameNode(SectionRef)
    case password(SectionRef, PasswordMode)
    case movePage(PageRef)
    case insertTable
    case insertLink
    case oneDriveOpen
    case notebookFonts(UUID)

    var id: String {
        switch self {
        case .newNotebook: "newNotebook"
        case .renameNotebook(let id): "renameNotebook-\(id)"
        case .renameNode(let ref): "renameNode-\(ref.sectionID)"
        case .password(let ref, let mode): "password-\(ref.sectionID)-\(mode.rawValue)"
        case .movePage(let ref): "movePage-\(ref.pageID)"
        case .insertTable: "insertTable"
        case .insertLink: "insertLink"
        case .oneDriveOpen: "oneDriveOpen"
        case .notebookFonts(let id): "notebookFonts-\(id)"
        }
    }
}

/// Where a paragraph link points: a container (and table cell), the paragraph's position and its first words.
struct ParagraphTarget {
    var element: UUID
    var paragraph: Int
    var cell: CellRef?
    var text: String
    /// A pin on a map (the element is the map).
    var pin: UUID?

    init?(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let element = value("e").flatMap(UUID.init(uuidString:)) else { return nil }
        self.element = element
        paragraph = Int(value("p") ?? "") ?? 0
        let parts = (value("c") ?? "").split(separator: ",").compactMap { Int($0) }
        cell = parts.count == 2 ? CellRef(row: parts[0], column: parts[1]) : nil
        text = value("t") ?? ""
        pin = value("pin").flatMap(UUID.init(uuidString:))
    }
}

struct SearchHit: Identifiable {
    var id: PageRef { ref }
    let ref: PageRef
    let title: String
    let snippet: String
    let location: String
    let titleMatch: Bool
    let modified: Date
}

struct TagHit: Identifiable {
    let id = UUID()
    let ref: PageRef
    let pageTitle: String
    let location: String
    let item: TagItem
    let modified: Date
}

@Observable
final class NotebookStore {
    static let shared = NotebookStore()
    static let linkScheme = "mxnoteone"

    var notebooks: [Notebook] = []
    private(set) var sidebarSelection: SidebarItem?
    private(set) var selectedPageID: UUID?
    var searchText = ""
    var expandedNotebooks: Set<UUID> = []
    /// Section groups open in the sidebar.
    var expandedGroups: Set<UUID> = []
    var alert: AlertInfo?
    var sheet: ActiveSheet?
    var showFullPage = false
    /// MxNoteONE is covered until Touch ID / the Mac password confirms it's you (Settings ▸ Security).
    var appLocked = DeviceUnlock.appLockEnabled
    var focusSearchRequest = 0
    /// Bumped to make the canvas reload the current page from disk.
    var reloadToken = 0
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    /// Bumped whenever the Back / Forward lists change (their menus redraw).
    private(set) var historyVersion = 0
    /// ⌃← / ⌃→ are Mission Control's "Move left / right a space" (macOS keeps them from every app).
    private(set) var navigationKeysTaken = NavigationKeys.takenByMissionControl
    /// Notebook shown when the Recycle Bin window opens.
    var recycleBinNotebookID: UUID?
    let editor = EditorState()

    @ObservationIgnored weak var canvas: CanvasController?
    /// Text to find on the page that opens next (from search and the tag summary).
    @ObservationIgnored var pendingFind: String?
    /// Paragraph to show on the page that opens next (from a paragraph link).
    @ObservationIgnored var pendingReveal: ParagraphTarget?
    /// Put the cursor in the title of the page that opens next (new pages).
    @ObservationIgnored var focusTitleOnLoad = false
    @ObservationIgnored private var lastPageInSection: [UUID: UUID] = [:]
    @ObservationIgnored private var backStack: [PageRef] = []
    @ObservationIgnored private var forwardStack: [PageRef] = []
    @ObservationIgnored private var historyCurrent: PageRef?
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var autoLockTask: Task<Void, Never>?
    /// Where Insert ▸ Link puts the link (saved before the sheet takes focus).
    @ObservationIgnored weak var linkTextView: NoteTextView?
    @ObservationIgnored var linkRange = NSRange()
    /// The link being edited (Edit Link: the caret or selection was in a link).
    @ObservationIgnored var linkExisting: URL?

    @ObservationIgnored private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    @ObservationIgnored private let prettyEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    @ObservationIgnored private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private init() {}

    // MARK: - Lookup

    func notebook(_ id: UUID?) -> Notebook? {
        guard let id else { return nil }
        return notebooks.first { $0.id == id }
    }

    func node(_ ref: SectionRef) -> SectionNode? {
        notebook(ref.notebookID)?.manifest.sections.find(ref.sectionID)
    }

    func isLocked(_ ref: SectionRef) -> Bool {
        guard let nb = notebook(ref.notebookID), let node = nb.manifest.sections.find(ref.sectionID) else { return false }
        return node.isProtected && !nb.unlocked.contains(ref.sectionID)
    }

    func pages(in ref: SectionRef) -> [PageMeta]? {
        notebook(ref.notebookID)?.sections[ref.sectionID]?.pages
    }

    /// Pages shown in the page list (subpages of collapsed pages are hidden).
    func visiblePages(in ref: SectionRef) -> [PageMeta] {
        var result: [PageMeta] = []
        var hideDeeperThan: Int?
        for page in pages(in: ref) ?? [] {
            if let level = hideDeeperThan {
                if page.level > level { continue }
                hideDeeperThan = nil
            }
            result.append(page)
            if page.collapsed { hideDeeperThan = page.level }
        }
        return result
    }

    func hasSubpages(_ pageID: UUID, in ref: SectionRef) -> Bool {
        guard let pages = pages(in: ref), let i = pages.firstIndex(where: { $0.id == pageID }) else { return false }
        return i + 1 < pages.count && pages[i + 1].level > pages[i].level
    }

    func meta(_ ref: PageRef) -> PageMeta? {
        pages(in: ref.section)?.first { $0.id == ref.pageID }
    }

    var selectedSection: SectionRef? {
        if case .section(let ref)? = sidebarSelection { return ref }
        return nil
    }

    var currentNotebook: Notebook? {
        switch sidebarSelection {
        case .section(let ref)?, .group(let ref)?: notebook(ref.notebookID)
        case nil: notebooks.first
        }
    }

    var currentPageRef: PageRef? {
        guard let section = selectedSection, let pageID = selectedPageID,
              meta(PageRef(notebookID: section.notebookID, sectionID: section.sectionID, pageID: pageID)) != nil
        else { return nil }
        return PageRef(notebookID: section.notebookID, sectionID: section.sectionID, pageID: pageID)
    }

    /// "Notebook › Group › Section".
    func location(_ ref: SectionRef) -> String {
        guard let nb = notebook(ref.notebookID), let node = nb.manifest.sections.find(ref.sectionID) else { return "" }
        let groups = nb.manifest.sections.path(to: ref.sectionID) ?? []
        return ([nb.name] + groups + [node.name]).joined(separator: " › ")
    }

    var windowTitle: String {
        if let ref = currentPageRef, let meta = meta(ref) { return meta.displayTitle }
        return "MxNoteONE"
    }

    var windowSubtitle: String {
        selectedSection.map(location) ?? ""
    }

    // MARK: - Files

    private func read(_ url: URL, key: SymmetricKey?) throws -> Data {
        let data = try Data(contentsOf: url)
        guard let key else { return data }
        return try NoteCrypto.open(data, key: key)
    }

    private func write(_ data: Data, to url: URL, key: SymmetricKey?) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let out = try key.map { try NoteCrypto.seal(data, key: $0) } ?? data
        try out.write(to: url, options: .atomic)
    }

    func saveManifest(_ nb: Notebook) {
        do {
            try write(prettyEncoder.encode(nb.manifest), to: nb.manifestURL, key: nil)
        } catch {
            report("Couldn't save the notebook \"\(nb.name)\".", error)
        }
    }

    private func loadSectionContent(_ nb: Notebook, _ id: UUID, key: SymmetricKey?) -> SectionContent {
        guard let data = try? read(nb.sectionURL(id), key: key),
              let content = try? decoder.decode(SectionContent.self, from: data)
        else { return SectionContent() }
        return content
    }

    func saveSection(_ nb: Notebook, _ id: UUID) {
        guard let content = nb.sections[id] else { return }
        let key = nb.keys[id]
        if nb.manifest.sections.find(id)?.isProtected == true && key == nil { return }
        do {
            try write(encoder.encode(content), to: nb.sectionURL(id), key: key)
        } catch {
            report("Couldn't save the section.", error)
        }
    }

    func report(_ title: String, _ error: Error) {
        alert = AlertInfo(title: title, message: error.localizedDescription)
    }

    func showAlert(_ title: String, _ message: String) {
        alert = AlertInfo(title: title, message: message)
    }

    // MARK: - Notebooks

    func loadLibraryIfNeeded() {
        guard !loaded else { return }
        loaded = true
        for path in Prefs.openNotebookPaths {
            openNotebook(at: URL(fileURLWithPath: path, isDirectory: true), persist: false, select: false, quiet: true)
        }
        if notebooks.isEmpty { createDefaultNotebook() }
        persistOpenNotebooks()
        expandedNotebooks = Set(notebooks.map(\.id))
        if sidebarSelection == nil { selectFirstSection(of: notebooks.first) }
        OneDriveSync.shared.scheduleAutoSync()
        if Prefs.oneDriveAutoSyncMinutes > 0, OneDriveAuth.shared.isSignedIn { OneDriveSync.shared.syncAll(quiet: true) }
    }

    private func selectFirstSection(of nb: Notebook?) {
        guard let nb, let node = nb.manifest.sections.flattenedSections.first else { return }
        selectSidebar(.section(SectionRef(notebookID: nb.id, sectionID: node.id)))
    }

    private func persistOpenNotebooks() {
        Prefs.openNotebookPaths = notebooks.map(\.url.path)
    }

    @discardableResult
    func openNotebook(at url: URL, persist: Bool = true, select: Bool = true, quiet: Bool = false) -> Notebook? {
        let url = url.standardizedFileURL
        if let existing = notebooks.first(where: { $0.url == url }) {
            if select { selectFirstSection(of: existing) }
            return existing
        }
        do {
            let manifest = try decoder.decode(NotebookManifest.self, from: Data(contentsOf: url.appending(path: "notebook.json")))
            if notebooks.contains(where: { $0.id == manifest.id }) {
                if !quiet { showAlert("Notebook already open", "A copy of \"\(manifest.name)\" is already open.") }
                return nil
            }
            let nb = Notebook(url: url, manifest: manifest)
            for node in manifest.sections.flattenedSections where !node.isProtected {
                nb.sections[node.id] = loadSectionContent(nb, node.id, key: nil)
            }
            notebooks.append(nb)
            purgeOldTrash(nb)
            expandedNotebooks.insert(nb.id)
            if persist { persistOpenNotebooks() }
            if select { selectFirstSection(of: nb) }
            return nb
        } catch {
            if !quiet {
                showAlert("Couldn't open the notebook", "\(url.lastPathComponent) is not an MxNoteONE notebook, or it can't be read.\n\n\(error.localizedDescription)")
            }
            return nil
        }
    }

    func openNotebookPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open Notebook"
        panel.message = "Choose a notebook folder (Name.mxnotebook)."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = Prefs.notebooksFolder
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { openNotebook(at: url) }
    }

    @discardableResult
    func createNotebook(name: String, color: NoteColor, in folder: URL, firstSection: String? = "New Section 1",
                        template: PageTemplate = .blank) -> Notebook? {
        let fm = FileManager.default
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var url = folder.appending(path: "\(safe).mxnotebook", directoryHint: .isDirectory)
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = folder.appending(path: "\(safe) \(n).mxnotebook", directoryHint: .isDirectory)
            n += 1
        }
        do {
            for sub in ["sections", "pages", "assets"] {
                try fm.createDirectory(at: url.appending(path: sub), withIntermediateDirectories: true)
            }
            let nb = Notebook(url: url, manifest: NotebookManifest(name: name, color: color))
            try write(prettyEncoder.encode(nb.manifest), to: nb.manifestURL, key: nil)
            notebooks.append(nb)
            expandedNotebooks.insert(nb.id)
            persistOpenNotebooks()
            if let firstSection { addSection(to: nb.id, name: firstSection, template: template) }
            return nb
        } catch {
            report("Couldn't create the notebook.", error)
            return nil
        }
    }

    private func createDefaultNotebook() {
        createNotebook(name: "My Notebook", color: .purple, in: Prefs.notebooksFolder,
                       firstSection: "Quick Notes", template: .welcome)
    }

    func closeNotebook(_ id: UUID) {
        guard let nb = notebook(id) else { return }
        canvas?.flush()
        if currentPageRef?.notebookID == id || selectedSection?.notebookID == id || {
            if case .group(let ref)? = sidebarSelection { return ref.notebookID == id }
            return false
        }() {
            sidebarSelection = nil
            selectedPageID = nil
        }
        notebooks.removeAll { $0 === nb }
        backStack.removeAll { $0.notebookID == id }
        forwardStack.removeAll { $0.notebookID == id }
        updateHistoryFlags()
        persistOpenNotebooks()
        if sidebarSelection == nil { selectFirstSection(of: notebooks.first) }
    }

    /// File ▸ Save Notebook As…: copies the notebook folder to a new place (a OneDrive folder, for example)
    /// and keeps working there. The original folder is left as it was.
    func saveNotebookAs(_ id: UUID) {
        guard let nb = notebook(id) else { return }
        canvas?.flush()
        let panel = NSSavePanel()
        panel.title = "Save Notebook As"
        panel.message = "Choose where to keep “\(nb.name)” — on this Mac or in your OneDrive folder. The original stays where it is."
        panel.nameFieldStringValue = nb.url.lastPathComponent
        panel.canCreateDirectories = true
        panel.directoryURL = Prefs.oneDriveFolders.first ?? Prefs.notebooksFolder
        guard panel.runModal() == .OK, var destination = panel.url else { return }
        if destination.pathExtension != "mxnotebook" { destination.appendPathExtension("mxnotebook") }
        guard destination.standardizedFileURL != nb.url.standardizedFileURL else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                showAlert("Can't save the notebook", "\(destination.lastPathComponent) already exists there.")
                return
            }
            try FileManager.default.copyItem(at: nb.url, to: destination)
            nb.url = destination.standardizedFileURL
            persistOpenNotebooks()
        } catch {
            report("Couldn't save the notebook.", error)
        }
    }

    func renameNotebook(_ id: UUID, to name: String) {
        guard let nb = notebook(id), !name.isEmpty else { return }
        nb.manifest.name = name
        saveManifest(nb)
    }

    func setNotebookColor(_ id: UUID, _ color: NoteColor) {
        guard let nb = notebook(id) else { return }
        nb.manifest.color = color
        saveManifest(nb)
    }

    func showInFinder(_ id: UUID) {
        guard let nb = notebook(id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([nb.url])
    }

    /// Re-reads every notebook from disk (for notebooks kept in a synced folder).
    func reloadAll() {
        canvas?.flush()
        for nb in notebooks {
            guard let data = try? Data(contentsOf: nb.manifestURL),
                  let manifest = try? decoder.decode(NotebookManifest.self, from: data) else { continue }
            nb.manifest = manifest
            var sections: [UUID: SectionContent] = [:]
            for node in manifest.sections.flattenedSections {
                if node.isProtected {
                    if let key = nb.keys[node.id] { sections[node.id] = loadSectionContent(nb, node.id, key: key) }
                } else {
                    sections[node.id] = loadSectionContent(nb, node.id, key: nil)
                }
            }
            nb.sections = sections
        }
        if let section = selectedSection, node(section) == nil { sidebarSelection = nil; selectedPageID = nil }
        reloadToken += 1
    }

    // MARK: - Selection and history

    func selectSidebar(_ item: SidebarItem?) {
        guard item != sidebarSelection else { return }
        canvas?.flush()
        sidebarSelection = item
        if case .section(let ref)? = item, let pages = pages(in: ref) {
            let remembered = lastPageInSection[ref.sectionID]
            selectedPageID = pages.contains(where: { $0.id == remembered }) ? remembered : pages.first?.id
        } else {
            selectedPageID = nil
        }
        recordHistory()
    }

    func selectPage(_ id: UUID?) {
        guard id != selectedPageID else { return }
        canvas?.flush()
        selectedPageID = id
        if let section = selectedSection, let id { lastPageInSection[section.sectionID] = id }
        recordHistory()
    }

    /// Opens a page anywhere, optionally finding text on it.
    func open(_ ref: PageRef, find: String? = nil) {
        pendingFind = find
        navigate(to: ref)
        recordHistory()
        if find != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.canvas?.applyPendingFind()
            }
        }
    }

    private func navigate(to ref: PageRef) {
        canvas?.flush()
        expandedNotebooks.insert(ref.notebookID)
        sidebarSelection = .section(ref.section)
        selectedPageID = ref.pageID
        lastPageInSection[ref.sectionID] = ref.pageID
    }

    private func recordHistory() {
        guard let current = currentPageRef, current != historyCurrent else { return }
        if let previous = historyCurrent {
            backStack.append(previous)
            if backStack.count > 100 { backStack.removeFirst() }
        }
        forwardStack.removeAll()
        historyCurrent = current
        updateHistoryFlags()
    }

    private func updateHistoryFlags() {
        canGoBack = !backStack.isEmpty
        canGoForward = !forwardStack.isEmpty
        historyVersion += 1
    }

    /// The pages Back goes to, the nearest first (the Back button's menu, Go ▸ History).
    var backHistory: [PageRef] {
        _ = historyVersion
        return backStack.reversed().compactMap(relocate)
    }

    /// The pages Forward goes to, the nearest first.
    var forwardHistory: [PageRef] {
        _ = historyVersion
        return forwardStack.reversed().compactMap(relocate)
    }

    /// "Page — Section" for the history menus.
    func historyTitle(_ ref: PageRef) -> String {
        let page = meta(ref)?.displayTitle ?? "Untitled Page"
        guard let section = notebook(ref.notebookID)?.manifest.sections.find(ref.sectionID)?.name else { return page }
        return "\(page) — \(section)"
    }

    /// The page's current location (it may have moved to another section).
    private func relocate(_ ref: PageRef) -> PageRef? {
        if meta(ref) != nil { return ref }
        return findPage(ref.pageID, in: ref.notebookID)
    }

    /// Back one page (⌃←, ⌘[, the mouse's back button), or several (the Back button's menu).
    func goBack(steps: Int = 1) { travel(back: true, steps: steps) }

    /// Forward one page (⌃→, ⌘], the mouse's forward button), or several.
    func goForward(steps: Int = 1) { travel(back: false, steps: steps) }

    /// Moves through the history like a browser: pages passed go onto the other list; pages since deleted are skipped.
    private func travel(back: Bool, steps: Int) {
        var target: PageRef?
        var moved = 0
        while moved < steps, let ref = back ? backStack.popLast() : forwardStack.popLast() {
            guard let found = relocate(ref) else { continue }
            if let current = historyCurrent {
                if back { forwardStack.append(current) } else { backStack.append(current) }
            }
            historyCurrent = found
            target = found
            moved += 1
        }
        if let target { navigate(to: target) }
        updateHistoryFlags()
    }

    /// Looks again whether Mission Control has ⌃← / ⌃→ (after a visit to System Settings).
    func refreshNavigationKeys() {
        let taken = NavigationKeys.takenByMissionControl
        if taken != navigationKeysTaken { navigationKeysTaken = taken }
    }

    /// Next or previous page in the current section.
    func selectAdjacentPage(_ delta: Int) {
        guard let section = selectedSection else { return }
        let pages = visiblePages(in: section)
        guard !pages.isEmpty else { return }
        let i = pages.firstIndex { $0.id == selectedPageID } ?? 0
        let j = min(max(i + delta, 0), pages.count - 1)
        selectPage(pages[j].id)
    }

    /// Next or previous section in the current notebook.
    func selectAdjacentSection(_ delta: Int) {
        guard let nb = currentNotebook else { return }
        let sections = nb.manifest.sections.flattenedSections
        guard !sections.isEmpty else { return }
        let i = sections.firstIndex { $0.id == selectedSection?.sectionID } ?? 0
        let j = (i + delta + sections.count) % sections.count
        selectSidebar(.section(SectionRef(notebookID: nb.id, sectionID: sections[j].id)))
    }

    // MARK: - Pages

    func loadPage(_ ref: PageRef) -> PageContent? {
        guard let nb = notebook(ref.notebookID), let meta = meta(ref), !isLocked(ref.section) else { return nil }
        if let data = try? read(nb.pageURL(ref.pageID), key: nb.keys[ref.sectionID]),
           let content = try? decoder.decode(PageContent.self, from: data) {
            return content
        }
        return PageContent(id: meta.id, title: meta.title, created: meta.created,
                           style: PageStyle(color: Prefs.pageColor, rules: Prefs.ruleLines))
    }

    /// A page, but only if it has a table (pages without one are skipped without being decoded) — for scripts.
    func loadPageWithTables(_ ref: PageRef) -> PageContent? {
        guard let nb = notebook(ref.notebookID), !isLocked(ref.section),
              let data = try? read(nb.pageURL(ref.pageID), key: nb.keys[ref.sectionID]),
              data.range(of: Data("\"table\"".utf8)) != nil else { return nil }
        return try? decoder.decode(PageContent.self, from: data)
    }

    private func writePage(_ content: PageContent, nb: Notebook, key: SymmetricKey?) throws {
        try write(encoder.encode(content), to: nb.pageURL(content.id), key: key)
    }

    /// Called by the canvas: writes the page and refreshes its entry in the page list.
    func savePage(_ content: PageContent, ref: PageRef, plainText: String, tags: [TagItem]) {
        guard let nb = notebook(ref.notebookID), !isLocked(ref.section),
              let i = nb.sections[ref.sectionID]?.pages.firstIndex(where: { $0.id == ref.pageID }) else { return }
        do {
            try writePage(content, nb: nb, key: nb.keys[ref.sectionID])
        } catch {
            report("Couldn't save the page.", error)
            return
        }
        nb.sections[ref.sectionID]!.pages[i].title = content.title
        nb.sections[ref.sectionID]!.pages[i].modified = Date()
        nb.sections[ref.sectionID]!.pages[i].plainText = plainText
        nb.sections[ref.sectionID]!.pages[i].tags = tags
        saveSection(nb, ref.sectionID)
    }

    /// Writes a page that came from OneDrive: replaces the local page with the same ID, or appends it.
    func storeImportedPage(_ content: PageContent, meta: PageMeta, in section: SectionRef) {
        guard let nb = notebook(section.notebookID), nb.sections[section.sectionID] != nil else { return }
        let isOpen = canvas?.ref?.pageID == meta.id
        if isOpen { canvas?.flush() }
        do {
            try writePage(content, nb: nb, key: nb.keys[section.sectionID])
        } catch {
            report("Couldn't save a page from OneDrive.", error)
            return
        }
        if let i = nb.sections[section.sectionID]!.pages.firstIndex(where: { $0.id == meta.id }) {
            nb.sections[section.sectionID]!.pages[i] = meta
        } else {
            nb.sections[section.sectionID]!.pages.append(meta)
        }
        saveSection(nb, section.sectionID)
        if isOpen { reloadToken += 1 }
    }

    /// Creates a section for an import, inside section groups named by `groups` (created as needed).
    func createImportedSection(name: String, color: NoteColor?, groups: [String], in nb: Notebook) -> SectionRef {
        var parent: UUID?
        for groupName in groups {
            let siblings = parent.flatMap { nb.manifest.sections.find($0)?.children } ?? nb.manifest.sections
            if let existing = siblings.first(where: { $0.isGroup && $0.name == groupName }) {
                parent = existing.id
            } else {
                let group = SectionNode(kind: .group, name: groupName, color: .gray, children: [])
                nb.manifest.sections.append(group, toGroup: parent)
                parent = group.id
            }
        }
        let count = nb.manifest.sections.flattenedSections.count
        let node = SectionNode(kind: .section, name: name,
                               color: color ?? NoteColor.allCases[count % NoteColor.allCases.count])
        nb.manifest.sections.append(node, toGroup: parent)
        nb.sections[node.id] = SectionContent()
        saveManifest(nb)
        saveSection(nb, node.id)
        expandedNotebooks.insert(nb.id)
        return SectionRef(notebookID: nb.id, sectionID: node.id)
    }

    /// Adds imported pages to a section (the section is saved once at the end).
    func addImportedPages(_ pages: [(PageContent, PageMeta)], to section: SectionRef) {
        guard let nb = notebook(section.notebookID), nb.sections[section.sectionID] != nil else { return }
        for (content, meta) in pages {
            do {
                try writePage(content, nb: nb, key: nb.keys[section.sectionID])
                nb.sections[section.sectionID]!.pages.append(meta)
            } catch {
                report("Couldn't save an imported page.", error)
                break
            }
        }
        saveSection(nb, section.sectionID)
    }

    /// Removes a page deleted in OneNote (it goes to the Recycle Bin).
    func removeSyncedPage(_ ref: PageRef) {
        deletePage(ref)
    }

    /// Live title update while typing (saved with the page).
    func setTitle(_ title: String, for ref: PageRef) {
        guard let nb = notebook(ref.notebookID),
              let i = nb.sections[ref.sectionID]?.pages.firstIndex(where: { $0.id == ref.pageID }),
              nb.sections[ref.sectionID]!.pages[i].title != title else { return }
        nb.sections[ref.sectionID]!.pages[i].title = title
    }

    @discardableResult
    func addPage(in ref: SectionRef, after anchor: UUID? = nil, subpage: Bool = false, template: PageTemplate = .blank,
                 title: String? = nil, select: Bool = true) -> PageRef? {
        guard let nb = notebook(ref.notebookID), var pages = nb.sections[ref.sectionID]?.pages, !isLocked(ref) else {
            return nil
        }
        let built = template.build()
        var meta = PageMeta(title: title ?? built.title)
        let index = PageIndexer.index(elements: built.elements)
        meta.plainText = index.text
        meta.tags = index.tags
        let content = PageContent(id: meta.id, title: meta.title, created: meta.created,
                                  style: built.style ?? PageStyle(color: Prefs.pageColor, rules: Prefs.ruleLines),
                                  elements: built.elements)
        var insertAt = pages.count
        if let anchor, let i = pages.firstIndex(where: { $0.id == anchor }) {
            let base = pages[i].level
            meta.level = subpage ? min(base + 1, 2) : base
            var j = i + 1
            while j < pages.count, pages[j].level > base { j += 1 }
            insertAt = j
            if subpage { pages[i].collapsed = false }
        }
        pages.insert(meta, at: insertAt)
        nb.sections[ref.sectionID]!.pages = pages
        do {
            try writePage(content, nb: nb, key: nb.keys[ref.sectionID])
        } catch {
            report("Couldn't create the page.", error)
        }
        saveSection(nb, ref.sectionID)
        let pageRef = PageRef(notebookID: ref.notebookID, sectionID: ref.sectionID, pageID: meta.id)
        if select {
            searchText = ""
            focusTitleOnLoad = template == .blank
            editor.tool = .type
            if selectedSection != ref {
                canvas?.flush()
                sidebarSelection = .section(ref)
            }
            selectPage(meta.id)
        }
        return pageRef
    }

    func addPageToCurrentSection(template: PageTemplate = .blank, subpage: Bool = false) {
        guard let section = selectedSection else {
            if let nb = currentNotebook { addSection(to: nb.id, template: template) }
            return
        }
        addPage(in: section, after: selectedPageID, subpage: subpage, template: template)
    }

    func newQuickNote() {
        guard let nb = notebooks.first else {
            createDefaultNotebook()
            return
        }
        if let node = nb.manifest.sections.flattenedSections.first(where: { $0.name == "Quick Notes" }),
           !isLocked(SectionRef(notebookID: nb.id, sectionID: node.id)) {
            let ref = SectionRef(notebookID: nb.id, sectionID: node.id)
            addPage(in: ref, after: pages(in: ref)?.last(where: { $0.level == 0 })?.id)
        } else {
            addSection(to: nb.id, name: "Quick Notes")
        }
    }

    func deletePage(_ ref: PageRef) {
        guard let nb = notebook(ref.notebookID), let node = node(ref.section),
              var content = nb.sections[ref.sectionID],
              let i = content.pages.firstIndex(where: { $0.id == ref.pageID }) else { return }
        if canvas?.ref == ref { canvas?.flush() }
        var meta = content.pages.remove(at: i)
        var j = i
        while j < content.pages.count, content.pages[j].level > meta.level {
            content.pages[j].level -= 1
            j += 1
        }
        if node.isProtected {
            meta.plainText = ""
            meta.tags = []
        }
        nb.manifest.trash.insert(TrashedItem(kind: .page, name: meta.displayTitle, page: meta, fromSectionID: node.id,
                                             fromSectionName: node.name, encrypted: node.isProtected), at: 0)
        nb.sections[ref.sectionID] = content
        saveSection(nb, ref.sectionID)
        saveManifest(nb)
        if selectedPageID == ref.pageID {
            let remaining = visiblePages(in: ref.section)
            selectedPageID = remaining.isEmpty ? nil : remaining[min(i, remaining.count - 1)].id
            recordHistory()
        }
    }

    /// Drag-reordering in the page list (offsets are into the visible pages). Subpages move with their page.
    func movePages(in ref: SectionRef, from source: IndexSet, to destination: Int) {
        guard let nb = notebook(ref.notebookID), var pages = nb.sections[ref.sectionID]?.pages else { return }
        let visible = visiblePages(in: ref)
        let movingIDs = source.map { visible[$0].id }
        let destinationID: UUID? = destination < visible.count ? visible[destination].id : nil
        var moving: [PageMeta] = []
        for id in movingIDs {
            guard let i = pages.firstIndex(where: { $0.id == id }) else { continue }
            var end = i + 1
            while end < pages.count, pages[end].level > pages[i].level { end += 1 }
            moving += pages[i..<end]
            pages.removeSubrange(i..<end)
        }
        let insertAt = destinationID.flatMap { id in pages.firstIndex { $0.id == id } } ?? pages.count
        pages.insert(contentsOf: moving, at: insertAt)
        nb.sections[ref.sectionID]!.pages = normalizedLevels(pages)
        saveSection(nb, ref.sectionID)
    }

    func normalizedLevels(_ pages: [PageMeta]) -> [PageMeta] {
        var result = pages
        for i in result.indices {
            let maxLevel = i == 0 ? 0 : min(result[i - 1].level + 1, 2)
            result[i].level = min(max(result[i].level, 0), maxLevel)
        }
        return result
    }

    /// Make Subpage (+1) / Promote Subpage (-1). Subpages move with their page.
    func changeLevel(_ ref: PageRef, by delta: Int) {
        guard let nb = notebook(ref.notebookID), var pages = nb.sections[ref.sectionID]?.pages,
              let i = pages.firstIndex(where: { $0.id == ref.pageID }) else { return }
        let base = pages[i].level
        var end = i + 1
        while end < pages.count, pages[end].level > base { end += 1 }
        let maxLevel = i == 0 ? 0 : min(pages[i - 1].level + 1, 2)
        let newLevel = min(max(base + delta, 0), maxLevel)
        let shift = newLevel - base
        guard shift != 0 else { return }
        for k in i..<end { pages[k].level = min(max(pages[k].level + shift, 0), 2) }
        nb.sections[ref.sectionID]!.pages = normalizedLevels(pages)
        saveSection(nb, ref.sectionID)
    }

    func toggleCollapsed(_ ref: PageRef) {
        guard let nb = notebook(ref.notebookID),
              let i = nb.sections[ref.sectionID]?.pages.firstIndex(where: { $0.id == ref.pageID }) else { return }
        nb.sections[ref.sectionID]!.pages[i].collapsed.toggle()
        saveSection(nb, ref.sectionID)
    }

    func duplicatePage(_ ref: PageRef) {
        guard let nb = notebook(ref.notebookID), var pages = nb.sections[ref.sectionID]?.pages,
              let i = pages.firstIndex(where: { $0.id == ref.pageID }) else { return }
        if canvas?.ref == ref { canvas?.flush() }
        guard var content = loadPage(ref) else { return }
        var meta = pages[i]
        meta.id = UUID()
        meta.created = Date()
        meta.modified = Date()
        meta.collapsed = false
        content.id = meta.id
        content.created = meta.created
        do {
            try writePage(content, nb: nb, key: nb.keys[ref.sectionID])
        } catch {
            report("Couldn't duplicate the page.", error)
            return
        }
        var end = i + 1
        while end < pages.count, pages[end].level > pages[i].level { end += 1 }
        pages.insert(meta, at: end)
        nb.sections[ref.sectionID]!.pages = pages
        saveSection(nb, ref.sectionID)
        selectPage(meta.id)
    }

    /// Moves or copies a page to another section, in this or another notebook.
    func movePage(_ ref: PageRef, to dest: SectionRef, copy: Bool) {
        guard let srcNB = notebook(ref.notebookID), let dstNB = notebook(dest.notebookID),
              !isLocked(ref.section), !isLocked(dest), dstNB.sections[dest.sectionID] != nil,
              var meta = meta(ref) else { return }
        if !copy && ref.section == dest { return }
        if canvas?.ref == ref { canvas?.flush() }
        guard var content = loadPage(ref) else { return }
        let srcKey = srcNB.keys[ref.sectionID]
        let dstKey = dstNB.keys[dest.sectionID]
        let sameStorage = srcNB === dstNB && (ref.sectionID == dest.sectionID || (srcKey == nil && dstKey == nil))
        if copy {
            meta.id = UUID()
            content.id = meta.id
        }
        meta.level = 0
        meta.collapsed = false
        do {
            if !sameStorage {
                for i in content.elements.indices {
                    guard let asset = content.elements[i].asset,
                          let data = try? read(srcNB.assetURL(asset), key: srcKey) else { continue }
                    content.elements[i].asset = try storeAsset(data, ext: (asset as NSString).pathExtension, nb: dstNB, key: dstKey)
                }
            }
            try writePage(content, nb: dstNB, key: dstKey)
        } catch {
            report(copy ? "Couldn't copy the page." : "Couldn't move the page.", error)
            return
        }
        dstNB.sections[dest.sectionID]!.pages.append(meta)
        saveSection(dstNB, dest.sectionID)
        if !copy {
            if var pages = srcNB.sections[ref.sectionID]?.pages, let i = pages.firstIndex(where: { $0.id == ref.pageID }) {
                let level = pages[i].level
                pages.remove(at: i)
                var j = i
                while j < pages.count, pages[j].level > level { pages[j].level -= 1; j += 1 }
                srcNB.sections[ref.sectionID]!.pages = pages
                saveSection(srcNB, ref.sectionID)
            }
            if srcNB !== dstNB { try? FileManager.default.removeItem(at: srcNB.pageURL(ref.pageID)) }
            if selectedPageID == ref.pageID {
                open(PageRef(notebookID: dest.notebookID, sectionID: dest.sectionID, pageID: meta.id))
            }
        }
    }

    // MARK: - Sections and section groups

    @discardableResult
    func addSection(to notebookID: UUID, inGroup groupID: UUID? = nil, name: String? = nil,
                    template: PageTemplate = .blank) -> SectionRef? {
        guard let nb = notebook(notebookID) else { return nil }
        let count = nb.manifest.sections.flattenedSections.count
        let node = SectionNode(kind: .section, name: name ?? "New Section \(count + 1)",
                               color: NoteColor.allCases[count % NoteColor.allCases.count])
        nb.manifest.sections.append(node, toGroup: groupID)
        nb.sections[node.id] = SectionContent()
        saveManifest(nb)
        saveSection(nb, node.id)
        let ref = SectionRef(notebookID: notebookID, sectionID: node.id)
        expandedNotebooks.insert(notebookID)
        selectSidebar(.section(ref))
        addPage(in: ref, template: template)
        return ref
    }

    func addSectionToCurrentNotebook() {
        guard let nb = currentNotebook else {
            sheet = .newNotebook
            return
        }
        var group: UUID?
        if case .group(let ref)? = sidebarSelection { group = ref.sectionID }
        if let section = selectedSection { group = nb.manifest.sections.parentGroup(of: section.sectionID)?.id }
        addSection(to: nb.id, inGroup: group)
    }

    func addSectionGroup(to notebookID: UUID, inGroup groupID: UUID? = nil) {
        guard let nb = notebook(notebookID) else { return }
        let node = SectionNode(kind: .group, name: "New Section Group", color: .gray, children: [])
        nb.manifest.sections.append(node, toGroup: groupID)
        saveManifest(nb)
        expandedNotebooks.insert(notebookID)
        sheet = .renameNode(SectionRef(notebookID: notebookID, sectionID: node.id))
    }

    func renameNode(_ ref: SectionRef, to name: String) {
        guard let nb = notebook(ref.notebookID), !name.isEmpty else { return }
        nb.manifest.sections.modify(ref.sectionID) { $0.name = name }
        saveManifest(nb)
    }

    func setColor(_ ref: SectionRef, _ color: NoteColor) {
        guard let nb = notebook(ref.notebookID) else { return }
        nb.manifest.sections.modify(ref.sectionID) { $0.color = color }
        saveManifest(nb)
    }

    func moveNode(_ ref: SectionRef, by delta: Int) {
        guard let nb = notebook(ref.notebookID) else { return }
        nb.manifest.sections.moveSibling(ref.sectionID, by: delta)
        saveManifest(nb)
    }

    /// Moves a section or group into a group (nil = top level of the notebook).
    func moveNode(_ ref: SectionRef, toGroup groupID: UUID?) {
        guard let nb = notebook(ref.notebookID), let node = nb.manifest.sections.find(ref.sectionID) else { return }
        if let groupID, groupID == node.id || (node.children?.find(groupID) != nil) { return }
        guard let removed = nb.manifest.sections.removeNode(ref.sectionID) else { return }
        nb.manifest.sections.append(removed, toGroup: groupID)
        saveManifest(nb)
    }

    func deleteNode(_ ref: SectionRef) {
        guard let nb = notebook(ref.notebookID), let node = nb.manifest.sections.find(ref.sectionID) else { return }
        let contained = Set([node].flattenedSections.map(\.id))
        if let current = selectedSection, contained.contains(current.sectionID) || current.sectionID == node.id {
            canvas?.flush()
            sidebarSelection = nil
            selectedPageID = nil
        }
        if case .group(let g)? = sidebarSelection, g.sectionID == node.id || node.children?.find(g.sectionID) != nil {
            sidebarSelection = nil
        }
        _ = nb.manifest.sections.removeNode(ref.sectionID)
        nb.manifest.trash.insert(TrashedItem(kind: .section, name: node.name, section: node), at: 0)
        for id in contained {
            nb.sections[id] = nil
            nb.keys[id] = nil
            nb.unlocked.remove(id)
        }
        saveManifest(nb)
        if sidebarSelection == nil { selectFirstSection(of: nb) }
    }

    // MARK: - Recycle Bin

    func restore(_ item: TrashedItem, in nb: Notebook) {
        switch item.kind {
        case .page:
            guard var meta = item.page else { return }
            var target: UUID?
            if let from = item.fromSectionID, nb.manifest.sections.find(from) != nil { target = from }
            if item.encrypted {
                guard let t = target else {
                    showAlert("Can't restore the page", "The page came from a password-protected section that no longer exists. Restore the section first.")
                    return
                }
                guard !isLocked(SectionRef(notebookID: nb.id, sectionID: t)) else {
                    showAlert("Section is locked", "Unlock the section \"\(item.fromSectionName)\" to restore this page.")
                    return
                }
            } else if target == nil || isLocked(SectionRef(notebookID: nb.id, sectionID: target!)) {
                target = nb.manifest.sections.flattenedSections.first(where: { !$0.isProtected })?.id
                if target == nil {
                    let node = SectionNode(kind: .section, name: "Restored Pages", color: .gray)
                    nb.manifest.sections.append(node)
                    nb.sections[node.id] = SectionContent()
                    target = node.id
                }
            }
            guard let sectionID = target else { return }
            if !item.encrypted, let key = nb.keys[sectionID] {
                try? reencryptPage(meta.id, nb: nb, from: nil, to: key)
            }
            meta.level = 0
            nb.sections[sectionID]?.pages.append(meta)
            saveSection(nb, sectionID)
        case .section:
            guard let node = item.section else { return }
            nb.manifest.sections.append(node)
            for section in [node].flattenedSections where !section.isProtected {
                nb.sections[section.id] = loadSectionContent(nb, section.id, key: nil)
            }
        }
        nb.manifest.trash.removeAll { $0.id == item.id }
        saveManifest(nb)
    }

    func deletePermanently(_ item: TrashedItem, in nb: Notebook, save: Bool = true) {
        let fm = FileManager.default
        switch item.kind {
        case .page:
            if let meta = item.page { try? fm.removeItem(at: nb.pageURL(meta.id)) }
        case .section:
            if let node = item.section {
                for section in [node].flattenedSections {
                    if !section.isProtected {
                        for page in loadSectionContent(nb, section.id, key: nil).pages {
                            try? fm.removeItem(at: nb.pageURL(page.id))
                        }
                    }
                    try? fm.removeItem(at: nb.sectionURL(section.id))
                }
            }
        }
        nb.manifest.trash.removeAll { $0.id == item.id }
        if save { saveManifest(nb) }
    }

    func emptyTrash(_ nb: Notebook) {
        for item in nb.manifest.trash { deletePermanently(item, in: nb, save: false) }
        nb.manifest.trash = []
        saveManifest(nb)
    }

    private func purgeOldTrash(_ nb: Notebook) {
        let cutoff = Date().addingTimeInterval(-60 * 24 * 3600)
        let old = nb.manifest.trash.filter { $0.deleted < cutoff }
        guard !old.isEmpty else { return }
        for item in old { deletePermanently(item, in: nb, save: false) }
        saveManifest(nb)
    }

    // MARK: - Password protection

    /// Sets or changes a section's password (the section must be unlocked).
    @discardableResult
    func setPassword(_ ref: SectionRef, password: String, hint: String) -> Bool {
        guard let nb = notebook(ref.notebookID), node(ref) != nil, !isLocked(ref), !password.isEmpty else { return false }
        if canvas?.ref?.section == ref { canvas?.flush() }
        let oldKey = nb.keys[ref.sectionID]
        let (protection, key) = NoteCrypto.makeProtection(password: password, hint: hint)
        do {
            try reencryptSection(nb, ref.sectionID, from: oldKey, to: key)
        } catch {
            report("Couldn't protect the section.", error)
            return false
        }
        nb.manifest.sections.modify(ref.sectionID) { $0.protection = protection }
        nb.keys[ref.sectionID] = key
        nb.unlocked.insert(ref.sectionID)
        if DeviceUnlock.isEnrolled(ref.sectionID) { DeviceUnlock.save(key, for: ref.sectionID) }
        saveSection(nb, ref.sectionID)
        saveManifest(nb)
        return true
    }

    func removePassword(_ ref: SectionRef) {
        guard let nb = notebook(ref.notebookID), let key = nb.keys[ref.sectionID] else { return }
        if canvas?.ref?.section == ref { canvas?.flush() }
        do {
            try reencryptSection(nb, ref.sectionID, from: key, to: nil)
        } catch {
            report("Couldn't remove the password.", error)
            return
        }
        nb.manifest.sections.modify(ref.sectionID) { $0.protection = nil }
        DeviceUnlock.remove(ref.sectionID)
        nb.keys[ref.sectionID] = nil
        nb.unlocked.remove(ref.sectionID)
        saveSection(nb, ref.sectionID)
        saveManifest(nb)
    }

    /// Unlocks with the password; `rememberWithDevice` keeps the key so Touch ID can open the section next time.
    func unlock(_ ref: SectionRef, password: String, rememberWithDevice: Bool = false) -> Bool {
        guard node(ref)?.protection != nil, let protection = node(ref)?.protection,
              let key = NoteCrypto.unlock(protection, password: password) else { return false }
        if rememberWithDevice { DeviceUnlock.save(key, for: ref.sectionID) }
        return unlock(ref, key: key)
    }

    /// Opens a section with Touch ID (or Apple Watch / the Mac password) when its key is kept on this Mac.
    func unlockWithDevice(_ ref: SectionRef, completion: @escaping @MainActor (Bool) -> Void = { _ in }) {
        let name = node(ref)?.name ?? "the section"
        DeviceUnlock.key(for: ref.sectionID, reason: "open the protected section “\(name)”") { [weak self] key in
            guard let self, let key else { return completion(false) }
            let ok = self.unlock(ref, key: key)
            // A key from before the password changed no longer opens it.
            if !ok { DeviceUnlock.remove(ref.sectionID) }
            completion(ok)
        }
    }

    func canUnlockWithDevice(_ ref: SectionRef) -> Bool {
        DeviceUnlock.isAvailable && DeviceUnlock.isEnrolled(ref.sectionID)
    }

    /// Starts or stops opening an unlocked section with Touch ID.
    func setDeviceUnlock(_ ref: SectionRef, _ on: Bool) {
        guard let nb = notebook(ref.notebookID) else { return }
        if on, let key = nb.keys[ref.sectionID] { DeviceUnlock.save(key, for: ref.sectionID) } else { DeviceUnlock.remove(ref.sectionID) }
    }

    /// Unlocks with the section's key (checked against the section before it's used).
    private func unlock(_ ref: SectionRef, key: SymmetricKey) -> Bool {
        guard let nb = notebook(ref.notebookID), let protection = node(ref)?.protection,
              NoteCrypto.verifier(for: key) == protection.verifier else { return false }
        nb.keys[ref.sectionID] = key
        nb.sections[ref.sectionID] = loadSectionContent(nb, ref.sectionID, key: key)
        nb.unlocked.insert(ref.sectionID)
        if selectedSection == ref, selectedPageID == nil {
            selectedPageID = pages(in: ref)?.first?.id
            recordHistory()
        }
        return true
    }

    func lock(_ ref: SectionRef) {
        guard let nb = notebook(ref.notebookID), node(ref)?.isProtected == true else { return }
        if canvas?.ref?.section == ref { canvas?.flush() }
        nb.keys[ref.sectionID] = nil
        nb.sections[ref.sectionID] = nil
        nb.unlocked.remove(ref.sectionID)
        if selectedSection == ref { selectedPageID = nil }
    }

    func lockAll() {
        for nb in notebooks {
            for id in nb.unlocked { lock(SectionRef(notebookID: nb.id, sectionID: id)) }
        }
    }

    /// Asks for Touch ID / the Mac password to show MxNoteONE again.
    func unlockApp() {
        DeviceUnlock.authenticate(reason: "open MxNoteONE") { [weak self] ok in
            if ok { self?.appLocked = false }
        }
    }

    func appDidResignActive() {
        autoLockTask?.cancel()
        let minutes = Prefs.autoLockMinutes
        guard minutes > 0, notebooks.contains(where: { !$0.unlocked.isEmpty }) || DeviceUnlock.appLockEnabled else { return }
        autoLockTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(minutes * 60))
            guard !Task.isCancelled else { return }
            self?.lockAll()
            if DeviceUnlock.appLockEnabled { self?.canvas?.flush(); self?.appLocked = true }
        }
    }

    func appDidBecomeActive() {
        autoLockTask?.cancel()
        refreshNavigationKeys()
    }

    /// Re-writes a section's page list, pages, assets and recycled pages with another key.
    private func reencryptSection(_ nb: Notebook, _ id: UUID, from oldKey: SymmetricKey?, to newKey: SymmetricKey?) throws {
        for page in nb.sections[id]?.pages ?? [] {
            try reencryptPage(page.id, nb: nb, from: oldKey, to: newKey)
        }
        for i in nb.manifest.trash.indices where nb.manifest.trash[i].kind == .page && nb.manifest.trash[i].fromSectionID == id {
            guard let pageID = nb.manifest.trash[i].page?.id else { continue }
            guard nb.manifest.trash[i].encrypted == (oldKey != nil) else { continue }
            try reencryptPage(pageID, nb: nb, from: oldKey, to: newKey)
            nb.manifest.trash[i].encrypted = newKey != nil
            if newKey != nil {
                nb.manifest.trash[i].page?.plainText = ""
                nb.manifest.trash[i].page?.tags = []
            }
        }
    }

    private func reencryptPage(_ pageID: UUID, nb: Notebook, from oldKey: SymmetricKey?, to newKey: SymmetricKey?) throws {
        let url = nb.pageURL(pageID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try read(url, key: oldKey)
        if let content = try? decoder.decode(PageContent.self, from: data) {
            for asset in content.elements.compactMap(\.asset) {
                let assetURL = nb.assetURL(asset)
                guard let assetData = try? read(assetURL, key: oldKey) else { continue }
                try write(assetData, to: assetURL, key: newKey)
            }
        }
        try write(data, to: url, key: newKey)
    }

    // MARK: - Assets

    private func storeAsset(_ data: Data, ext: String, nb: Notebook, key: SymmetricKey?) throws -> String {
        let name = UUID().uuidString + (ext.isEmpty ? "" : "." + ext.lowercased())
        try write(data, to: nb.assetURL(name), key: key)
        return name
    }

    /// Stores a picture, attachment or recording for a page; returns the asset name.
    func writeAsset(_ data: Data, ext: String, for ref: PageRef) -> String? {
        guard let nb = notebook(ref.notebookID) else { return nil }
        do {
            return try storeAsset(data, ext: ext, nb: nb, key: nb.keys[ref.sectionID])
        } catch {
            report("Couldn't store the file in the notebook.", error)
            return nil
        }
    }

    /// Writes new contents to an existing asset (a diagram saved again keeps its file).
    func overwriteAsset(_ name: String, data: Data, for ref: PageRef) {
        guard let nb = notebook(ref.notebookID) else { return }
        do {
            try write(data, to: nb.assetURL(name), key: nb.keys[ref.sectionID])
        } catch {
            report("Couldn't save the diagram in the notebook.", error)
        }
    }

    func assetData(_ name: String, for ref: PageRef) -> Data? {
        guard let nb = notebook(ref.notebookID) else { return nil }
        return try? read(nb.assetURL(name), key: nb.keys[ref.sectionID])
    }

    /// A temporary copy of an attachment under its original name, for opening or dragging out.
    func temporaryCopy(of name: String, fileName: String?, for ref: PageRef) -> URL? {
        guard let data = assetData(name, for: ref) else { return nil }
        let folder = FileManager.default.temporaryDirectory.appending(path: "MxNoteONE/\(UUID().uuidString)")
        let url = folder.appending(path: fileName ?? name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    func openAsset(_ name: String, fileName: String?, for ref: PageRef) {
        guard let url = temporaryCopy(of: name, fileName: fileName, for: ref) else {
            showAlert("Can't open the file", "The attachment is missing from the notebook.")
            return
        }
        NSWorkspace.shared.open(url)
    }

    func saveAssetAs(_ name: String, fileName: String?, for ref: PageRef) {
        guard let data = assetData(name, for: ref) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName ?? name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url) } catch { report("Couldn't save the file.", error) }
    }

    // MARK: - Search and tags

    func search(_ query: String) -> [SearchHit] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var hits: [SearchHit] = []
        for nb in notebooks {
            for node in nb.manifest.sections.flattenedSections {
                guard let content = nb.sections[node.id] else { continue }
                let sectionRef = SectionRef(notebookID: nb.id, sectionID: node.id)
                let location = location(sectionRef)
                for page in content.pages {
                    let haystack = page.title + "\n" + page.plainText
                    guard words.allSatisfy({ haystack.range(of: $0, options: options) != nil }) else { continue }
                    let titleMatch = words.allSatisfy { page.title.range(of: $0, options: options) != nil }
                    hits.append(SearchHit(ref: PageRef(notebookID: nb.id, sectionID: node.id, pageID: page.id),
                                          title: page.displayTitle,
                                          snippet: Self.snippet(page.plainText, around: words[0]),
                                          location: location, titleMatch: titleMatch, modified: page.modified))
                }
            }
        }
        return hits.sorted { ($0.titleMatch ? 1 : 0, $0.modified) > ($1.titleMatch ? 1 : 0, $1.modified) }
    }

    static func snippet(_ text: String, around word: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard let range = flat.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return String(flat.prefix(120))
        }
        let start = flat.index(range.lowerBound, offsetBy: -50, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(range.upperBound, offsetBy: 80, limitedBy: flat.endIndex) ?? flat.endIndex
        return (start > flat.startIndex ? "…" : "") + flat[start..<end] + (end < flat.endIndex ? "…" : "")
    }

    func allTags() -> [TagHit] {
        var hits: [TagHit] = []
        for nb in notebooks {
            for node in nb.manifest.sections.flattenedSections {
                guard let content = nb.sections[node.id] else { continue }
                let sectionRef = SectionRef(notebookID: nb.id, sectionID: node.id)
                let location = location(sectionRef)
                for page in content.pages {
                    for item in page.tags {
                        hits.append(TagHit(ref: PageRef(notebookID: nb.id, sectionID: node.id, pageID: page.id),
                                           pageTitle: page.displayTitle, location: location, item: item,
                                           modified: page.modified))
                    }
                }
            }
        }
        return hits
    }

    // MARK: - Links to pages

    /// Insert ▸ Link (⌘K): remembers the text selection and shows the link sheet. With the caret (or selection) in a
    /// link, the whole link is edited: the sheet shows its text and address.
    func beginInsertLink() {
        guard let tv = TextFormatter.target else { return NSSound.beep() }
        linkTextView = tv
        let found = TextFormatter.link(around: tv.selectedRange(), in: tv)
        linkRange = found?.range ?? tv.selectedRange()
        linkExisting = found?.url
        sheet = .insertLink
    }

    func link(for ref: PageRef) -> URL {
        URL(string: "\(Self.linkScheme)://page/\(ref.notebookID.uuidString)/\(ref.pageID.uuidString)")!
    }

    func findPage(_ pageID: UUID, in notebookID: UUID) -> PageRef? {
        guard let nb = notebook(notebookID) else { return nil }
        for (sectionID, content) in nb.sections where content.pages.contains(where: { $0.id == pageID }) {
            return PageRef(notebookID: notebookID, sectionID: sectionID, pageID: pageID)
        }
        return nil
    }

    func resolve(_ url: URL) -> PageRef? {
        guard url.scheme == Self.linkScheme, url.host() == "page" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2, let notebookID = UUID(uuidString: parts[0]), let pageID = UUID(uuidString: parts[1]) else {
            return nil
        }
        return findPage(pageID, in: notebookID)
    }

    /// A link opened from another app (mxnoteone://…, registered in Info.plist), e.g. a link on a company in
    /// MxPortMGR: the notebooks load first if MxNoteONE was just launched for it, then it goes where the link leads.
    func openExternalLink(_ url: URL) {
        guard url.scheme == Self.linkScheme else { return }
        loadLibraryIfNeeded()
        openLink(url)
    }

    func openLink(_ url: URL) {
        guard url.scheme == Self.linkScheme else { return }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch url.host() {
        case "section":
            guard parts.count >= 2, let nbID = UUID(uuidString: parts[0]), let nodeID = UUID(uuidString: parts[1]),
                  let nb = notebook(nbID), let node = nb.manifest.sections.find(nodeID) else {
                return showAlert("Section not found", "The linked section may have been deleted, or its notebook isn't open.")
            }
            expandedNotebooks.insert(nbID)
            let target = node.isGroup ? [node].flattenedSections.first : node
            if let target {
                selectSidebar(.section(SectionRef(notebookID: nbID, sectionID: target.id)))
            } else {
                selectSidebar(.group(SectionRef(notebookID: nbID, sectionID: node.id)))
            }
        case "notebook":
            guard let nbID = parts.first.flatMap(UUID.init(uuidString:)), let nb = notebook(nbID) else {
                return showAlert("Notebook not open", "Open the notebook first (File ▸ Open Notebook…).")
            }
            expandedNotebooks.insert(nbID)
            if let first = nb.manifest.sections.flattenedSections.first {
                selectSidebar(.section(SectionRef(notebookID: nbID, sectionID: first.id)))
            }
        default:
            guard let ref = resolve(url) else {
                return showAlert("Page not found", "The linked page may have been deleted, or it is in a locked section or a notebook that isn't open.")
            }
            pendingReveal = ParagraphTarget(url)
            open(ref)
            if pendingReveal != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.canvas?.applyPendingReveal() }
            }
        }
    }

    /// The name of what a copied link goes to (used when it's pasted into a note with nothing selected).
    static let linkTitleType = NSPasteboard.PasteboardType("com.k3jdr.mxnoteone.link-title")

    /// Copy Link: just the address (as a URL and as text), so where it's pasted the link can have any text — paste it on
    /// selected words to link them, or into Insert Link's address. The target's name goes along for a plain paste.
    private func copyLink(_ url: URL, title: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
        pb.addTypes([.string, Self.linkTitleType], owner: nil)
        pb.setString(url.absoluteString, forType: .string)
        pb.setString(title, forType: Self.linkTitleType)
    }

    func copyLink(_ ref: PageRef) {
        copyLink(link(for: ref), title: meta(ref)?.displayTitle ?? "Page")
    }

    func sectionLink(_ ref: SectionRef) -> URL {
        URL(string: "\(Self.linkScheme)://section/\(ref.notebookID.uuidString)/\(ref.sectionID.uuidString)")!
    }

    func copySectionLink(_ ref: SectionRef) {
        copyLink(sectionLink(ref), title: node(ref)?.name ?? "Section")
    }

    func copyNotebookLink(_ id: UUID) {
        copyLink(URL(string: "\(Self.linkScheme)://notebook/\(id.uuidString)")!, title: notebook(id)?.name ?? "Notebook")
    }

    /// A link to one paragraph: its container (and table cell), its position, and its first words to find it again.
    func paragraphLink(_ ref: PageRef, element: UUID, paragraph: Int, cell: CellRef?, text: String) -> URL {
        var components = URLComponents(url: link(for: ref), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "e", value: element.uuidString), URLQueryItem(name: "p", value: String(paragraph))]
        if let cell { items.append(URLQueryItem(name: "c", value: "\(cell.row),\(cell.column)")) }
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty { items.append(URLQueryItem(name: "t", value: String(words.prefix(60)))) }
        components.queryItems = items
        return components.url!
    }

    /// A link to a pin on a map: the map's container, the pin, and its title (for the link's name).
    func pinLink(_ ref: PageRef, map: UUID, pin: UUID, title: String) -> URL {
        var components = URLComponents(url: link(for: ref), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "e", value: map.uuidString), URLQueryItem(name: "pin", value: pin.uuidString),
                                 URLQueryItem(name: "t", value: String(title.prefix(60)))]
        return components.url!
    }

    func copyPinLink(_ ref: PageRef, map: UUID, pin: UUID, title: String) {
        copyLink(pinLink(ref, map: map, pin: pin, title: title), title: title)
    }

    func copyParagraphLink(_ ref: PageRef, element: UUID, paragraph: Int, cell: CellRef?, text: String) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = words.isEmpty ? (meta(ref)?.displayTitle ?? "Paragraph") : String(words.prefix(80)) + (words.count > 80 ? "…" : "")
        copyLink(paragraphLink(ref, element: element, paragraph: paragraph, cell: cell, text: text), title: title)
    }

    /// Link for [[Page Name]]: an existing page in the current notebook, or a new page in the current section.
    func linkForPage(titled title: String) -> URL? {
        guard let nb = currentNotebook else { return nil }
        for (sectionID, content) in nb.sections {
            if let page = content.pages.first(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame }) {
                return link(for: PageRef(notebookID: nb.id, sectionID: sectionID, pageID: page.id))
            }
        }
        guard let section = selectedSection, section.notebookID == nb.id,
              let ref = addPage(in: section, title: title, select: false) else { return nil }
        return link(for: ref)
    }
}

// MARK: - Search index

enum PageIndexer {
    /// Plain text and tags of page elements (used when the page isn't open in the canvas).
    static func index(elements: [PageElement]) -> (text: String, tags: [TagItem]) {
        var texts: [String] = []
        for element in elements {
            switch element.kind {
            case .text:
                if let data = element.rtfd, let s = NoteRichText.text(data) {
                    texts.append(s.string)
                    // Links' hover texts are found by search too.
                    s.enumerateAttribute(.linkTip, in: NSRange(location: 0, length: s.length)) { value, _, _ in
                        if let tip = value as? NSAttributedString { texts.append(tip.string) }
                    }
                }
            case .table:
                texts.append(element.table?.rows.map { $0.joined(separator: " ") }.joined(separator: "\n") ?? "")
            case .file, .audio, .image:
                if let name = element.fileName { texts.append(name) }
            case .diagram:
                // A diagram's name and its shapes' labels.
                texts.append([element.fileName, element.diagramText].compactMap { $0 }.joined(separator: " "))
            case .chart:
                if let title = element.chart?.title, !title.isEmpty { texts.append(title) }
            case .score:
                if let title = element.score?.title, !title.isEmpty { texts.append(title) }
            case .model:
                // A model's name and its features' (found by search).
                if let m = element.cad { texts.append(([m.name] + m.features.map(\.name)).joined(separator: " ")) }
            case .map:
                // A map's title and its pins' titles, notes, addresses and categories.
                if let m = element.map { texts.append(m.searchText) }
            case .dbml:
                // A database diagram's tables, columns, enums, groups and notes.
                if let d = element.dbml { texts.append(d.searchText) }
            }
        }
        return index(texts: texts)
    }

    static func index(texts: [String]) -> (text: String, tags: [TagItem]) {
        var tags: [TagItem] = []
        for text in texts {
            for line in text.components(separatedBy: .newlines) {
                let info = TextFormatter.parseParagraph(line)
                guard let tag = info.tag else { continue }
                let rest = (line as NSString).substring(from: info.contentStart).trimmingCharacters(in: .whitespaces)
                tags.append(TagItem(kind: tag, text: rest, done: info.tagDone))
            }
        }
        let text = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n")
        return (text, tags)
    }
}
