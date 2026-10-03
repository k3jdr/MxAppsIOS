//
//  WorkspaceActions.swift
//  MxDeskMGR
//
//  Commands shared by the menus, the function key bar, the toolbar and
//  the file lists' context menus. They act on the active pane's tab
//  (its marked items), with the other pane as the usual target.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension Workspace {
    private var marked: [FileItem] { activeTab.selectedItems }

    /// Marked items, or a beep when there are none.
    private func requireMarked() -> [FileItem]? {
        let items = marked
        if items.isEmpty { NSSound.beep(); return nil }
        return items
    }

    // MARK: Opening

    func open(_ item: FileItem, in tab: BrowserTab) {
        if item.isDirectory {
            tab.navigate(to: item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    func openSelection() {
        guard let items = requireMarked() else { return }
        if items.count == 1 { open(items[0], in: activeTab); return }
        for item in items where !item.isDirectory { NSWorkspace.shared.open(item.url) }
    }

    func open(_ urls: [URL], with app: URL) {
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    func chooseApplicationAndOpen(_ urls: [URL]) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Open"
        if panel.runModal() == .OK, let app = panel.url { open(urls, with: app) }
    }

    func showPackageContents() {
        guard let item = marked.first, item.isPackage else { NSSound.beep(); return }
        activeTab.navigate(to: item.url)
    }

    func openInNewTab() {
        let target = marked.first(where: \.isDirectory)?.url ?? activeTab.url
        activePane.newTab(target)
    }

    /// F3: built-in viewer (Quick Look preview, text and hex).
    func view() {
        guard let items = requireMarked() else { return }
        for item in items.filter({ !$0.isDirectory }).prefix(8) {
            openWindow?(value: ViewerRequest(url: item.url))
        }
    }

    /// F4: opens files in the editor chosen in Settings.
    func edit() {
        guard let items = requireMarked() else { return }
        let files = items.filter { !$0.isDirectory }.map(\.url)
        guard !files.isEmpty else { NSSound.beep(); return }
        let editor = URL(fileURLWithPath: AppSettings.shared.editorPath)
        if FileManager.default.fileExists(atPath: editor.path) {
            open(files, with: editor)
        } else {
            files.forEach { NSWorkspace.shared.open($0) }
        }
    }

    // MARK: Copy / move

    /// F5 / F6: asks for the target (the other pane's folder by default).
    func copyOrMoveToOtherPane(move: Bool) {
        guard let items = requireMarked() else { return }
        sheet = .transfer(TransferRequest(sources: items.map(\.url), destination: otherTab.url.path, move: move))
    }

    func performTransfer(_ request: TransferRequest, destination text: String, policy: ConflictPolicy) {
        var path = (text.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        if !path.hasPrefix("/") { path = activeTab.url.appendingPathComponent(path).path }
        let dest = URL(fileURLWithPath: path).standardizedFileURL
        let pairs: [(URL, URL)]
        if FileOps.isRealDirectory(dest) || (FileOps.exists(dest) && dest.resolvingSymlinksInPath().hasDirectoryPath) {
            pairs = request.sources.map { ($0, dest.appendingPathComponent($0.lastPathComponent)) }
        } else if request.sources.count == 1 {
            // A single item copied to a path that isn't a folder is copied under that name.
            pairs = [(request.sources[0], dest)]
        } else {
            pairs = request.sources.map { ($0, dest.appendingPathComponent($0.lastPathComponent)) }
        }
        TransferManager.shared.copy(pairs, move: request.move, policy: policy)
    }

    /// Drag and drop, and paste: copies or moves `urls` into `folder`.
    func transfer(_ urls: [URL], to folder: URL, move: Bool) {
        let pairs = urls.map { ($0, folder.appendingPathComponent($0.lastPathComponent)) }
        TransferManager.shared.copy(pairs, move: move, policy: .ask)
    }

    func duplicate() {
        guard let items = requireMarked() else { return }
        let pairs = items.map { ($0.url, FileOps.keepBothURL(for: $0.url)) }
        TransferManager.shared.copy(pairs, move: false, policy: .keepBoth)
    }

    func copyToPasteboard() {
        guard let items = requireMarked() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(items.map { $0.url as NSURL })
    }

    func pasteFromPasteboard(move: Bool) {
        let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self],
                                                    options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { NSSound.beep(); return }
        transfer(urls, to: activeTab.url, move: move)
    }

    func copyPaths() {
        let paths = marked.isEmpty ? [activeTab.url.path] : marked.map(\.url.path)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    // MARK: Delete

    func moveToTrash() {
        guard let items = requireMarked() else { return }
        if AppSettings.shared.confirmTrash,
           !Alerts.confirm("Move \(describe(items)) to the Trash?", ok: "Move to Trash") { return }
        TransferManager.shared.trash(items.map(\.url))
    }

    func deleteImmediately() {
        guard let items = requireMarked() else { return }
        guard Alerts.confirm("Delete \(describe(items)) immediately?",
                             info: "This can't be undone.", ok: "Delete", destructive: true) else { return }
        TransferManager.shared.delete(items.map(\.url))
    }

    private func describe(_ items: [FileItem]) -> String {
        items.count == 1 ? "“\(items[0].name)”" : Fmt.count(items.count, "item")
    }

    // MARK: Create / rename

    func newFolder() {
        let tab = activeTab
        let initial = FileOps.availableURL(in: tab.url, stem: "untitled folder", ext: "").lastPathComponent
        sheet = .name(NamePrompt(title: "New Folder", message: "Create a folder in “\(tab.title)”:",
                                 initial: initial, okTitle: "Create") { name in
            let url = tab.url.appendingPathComponent(name)
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                tab.focus(on: url)
            } catch { Alerts.error(error) }
        })
    }

    /// Shift-F4: creates an empty file and opens it in the editor.
    func newFile() {
        let tab = activeTab
        let initial = FileOps.availableURL(in: tab.url, stem: "untitled", ext: "txt").lastPathComponent
        sheet = .name(NamePrompt(title: "New File", message: "Create a file in “\(tab.title)”:",
                                 initial: initial, okTitle: "Create", selectStem: true) { [weak self] name in
            let url = tab.url.appendingPathComponent(name)
            guard !FileOps.exists(url) else { Alerts.message("“\(name)” already exists."); return }
            guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
                Alerts.message("Couldn't create “\(name)”."); return
            }
            tab.focus(on: url)
            let editor = URL(fileURLWithPath: AppSettings.shared.editorPath)
            if FileManager.default.fileExists(atPath: editor.path) { self?.open([url], with: editor) }
        })
    }

    /// F2: renames one item, or opens Multi-Rename for several.
    func rename() {
        guard let items = requireMarked() else { return }
        if items.count > 1 { multiRename(); return }
        let item = items[0]
        let tab = activeTab
        sheet = .name(NamePrompt(title: "Rename", message: "New name for “\(item.name)”:",
                                 initial: item.name, okTitle: "Rename", selectStem: !item.isDirectory) { name in
            guard name != item.name else { return }
            let dest = item.url.deletingLastPathComponent().appendingPathComponent(name)
            do {
                try FileManager.default.moveItem(at: item.url, to: dest)
                tab.focus(on: dest)
            } catch { Alerts.error(error) }
        })
    }

    func multiRename() {
        guard let items = requireMarked() else { return }
        openWindow?(value: RenameRequest(urls: items.map(\.url)))
    }

    // MARK: Archives

    func compress() {
        guard let items = requireMarked() else { return }
        let stem = items.count == 1 ? items[0].url.deletingPathExtension().lastPathComponent : "Archive"
        let archive = FileOps.availableURL(in: activeTab.url, stem: stem, ext: "zip")
        TransferManager.shared.compress(items.map(\.url), in: activeTab.url, to: archive)
        activeTab.focus(on: archive)
    }

    /// Extracts the marked archives into the other pane's folder.
    func extract() {
        guard let items = requireMarked() else { return }
        let archives = items.map(\.url).filter(FileOps.isArchive)
        guard !archives.isEmpty else { Alerts.message("No supported archives are selected."); return }
        TransferManager.shared.extract(archives, into: otherTab.url)
    }

    // MARK: Selection

    func selectPattern(_ pattern: String, select: Bool, includeFolders: Bool) {
        let matcher = NameMatcher(pattern)
        let tab = activeTab
        let hits = tab.items.filter { (includeFolders || !$0.isDirectory) && matcher.matches($0.name) }.map(\.url)
        if select { tab.selection.formUnion(hits) } else { tab.selection.subtract(hits) }
    }

    func invertSelection() {
        let tab = activeTab
        tab.selection = Set(tab.items.map(\.url)).subtracting(tab.selection)
    }

    /// Marks, in both panes, items missing from the other side or newer than their counterpart.
    func compareFolders() {
        let l = left.active, r = right.active
        func marks(_ a: BrowserTab, against b: BrowserTab) -> Set<URL> {
            let other = Dictionary(b.items.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            return Set(a.items.filter { item in
                guard let twin = other[item.name] else { return true }
                if item.isDirectory || twin.isDirectory { return false }
                return item.modified.timeIntervalSince(twin.modified) > 2
                    || (abs(item.modified.timeIntervalSince(twin.modified)) <= 2 && item.size != twin.size)
            }.map(\.url))
        }
        l.selection = marks(l, against: r)
        r.selection = marks(r, against: l)
        if l.selection.isEmpty, r.selection.isEmpty {
            Alerts.message("The folders have the same items.", info: "Compared by name, date and size (not subfolders).")
        }
    }

    // MARK: Navigation

    func go(to url: URL) {
        activeTab.navigate(to: url)
        focus(activeSide)
    }

    func goToFolderPrompt() {
        let tab = activeTab
        sheet = .name(NamePrompt(title: "Go to Folder", message: "Folder path (~ for your home folder):",
                                 initial: tab.url.path, okTitle: "Go") { [weak self] text in
            let path = (text.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
            let url = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : tab.url.appendingPathComponent(path))
                .standardizedFileURL
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                if isDir.boolValue { tab.navigate(to: url) } else { tab.navigate(to: url.deletingLastPathComponent(), focus: url) }
                self?.focus(self?.activeSide ?? .left)
            } else {
                Alerts.message("The folder “\(path)” can't be found.")
            }
        })
    }

    func swapPanes() {
        left.swapContents(with: right)
        focus(activeSide)
    }

    /// Shows the active pane's folder in the other pane too.
    func mirrorToOtherPane() {
        otherTab.navigate(to: activeTab.url)
    }

    /// Opens the marked folder (or the current one) in the other pane.
    func openInOtherPane() {
        let target = marked.first(where: \.isDirectory)?.url ?? activeTab.url
        otherTab.navigate(to: target)
    }

    func sort(by key: SortKey) {
        let tab = activeTab
        if tab.sort.key == key { tab.sort.ascending.toggle() } else { tab.sort = SortOrder(key: key, ascending: true) }
    }

    func addToFavorites() {
        AppSettings.shared.addFavorite(marked.first(where: \.isDirectory)?.url ?? activeTab.url)
    }

    /// Shows `url` in the active pane, with the item selected.
    func reveal(_ url: URL) {
        activeTab.navigate(to: url.deletingLastPathComponent(), focus: url)
        window?.makeKeyAndOrderFront(nil)
        focus(activeSide)
    }

    // MARK: Tools

    func revealInFinder() {
        let urls = marked.map(\.url)
        if urls.isEmpty { NSWorkspace.shared.open(activeTab.url) } else { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    func openTerminal() {
        let folder = marked.count == 1 && marked[0].isDirectory ? marked[0].url : activeTab.url
        let terminal = URL(fileURLWithPath: AppSettings.shared.terminalPath)
        open([folder], with: terminal)
    }

    func showProperties() {
        let urls = marked.isEmpty ? [activeTab.url] : marked.map(\.url)
        sheet = .properties(urls)
    }

    func calculateFolderSizes() {
        activeTab.calculateFolderSizes(marked)
    }

    func search() {
        openWindow?(value: SearchRequest(root: activeTab.url))
    }

    func synchronizeFolders() {
        openWindow?(value: SyncRequest(left: left.active.url, right: right.active.url))
    }

    /// Compares two files: two marked in the active pane, or one marked in each pane,
    /// or the marked file with the same-named file in the other pane.
    func compareFiles() {
        let mine = marked.filter { !$0.isDirectory }
        let theirs = otherTab.selectedItems.filter { !$0.isDirectory }
        var pair: (URL, URL)?
        if mine.count == 2 {
            pair = (mine[0].url, mine[1].url)
        } else if mine.count == 1, theirs.count == 1 {
            pair = (mine[0].url, theirs[0].url)
        } else if mine.count == 1, let twin = otherTab.items.first(where: { $0.name == mine[0].name && !$0.isDirectory }) {
            pair = (mine[0].url, twin.url)
        }
        guard let (a, b) = pair else {
            Alerts.message("Select two files to compare.",
                           info: "Mark two files in one pane, one file in each pane, or a file whose name also exists in the other pane.")
            return
        }
        let (l, r) = activeSide == .left ? (a, b) : (b, a)
        openWindow?(value: DiffRequest(left: l, right: r))
    }
}

// MARK: - Alerts

enum Alerts {
    static func message(_ text: String, info: String = "") {
        let alert = NSAlert()
        alert.messageText = text
        alert.informativeText = info
        alert.runModal()
    }

    static func error(_ error: Error) {
        NSAlert(error: error).runModal()
    }

    static func confirm(_ text: String, info: String = "", ok: String, destructive: Bool = false) -> Bool {
        let alert = NSAlert()
        alert.messageText = text
        alert.informativeText = info
        alert.alertStyle = destructive ? .critical : .warning
        let button = alert.addButton(withTitle: ok)
        button.hasDestructiveAction = destructive
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
