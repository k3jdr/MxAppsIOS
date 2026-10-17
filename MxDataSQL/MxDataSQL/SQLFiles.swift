//
//  SQLFiles.swift
//  MxDataSQL
//
//  Saving and recalling .sql files from the SQL box (right-click menu).
//  SQLLibrary remembers the SQL folder and recently used files for the whole
//  app. The app is sandboxed, so both are kept as security-scoped bookmarks in
//  UserDefaults; access lasts across launches without asking again.
//

import AppKit
import UniformTypeIdentifiers

extension UTType {
    static let sql = UTType(filenameExtension: "sql", conformingTo: .plainText) ?? .plainText
}

@MainActor
final class SQLLibrary {
    static let shared = SQLLibrary()

    private let defaults = UserDefaults.standard
    private static let folderKey = "sqlFolderBookmark"
    private static let recentKey = "sqlRecentBookmarks"
    private static let recentLimit = 10

    /// The configured SQL folder (security scope held while the app runs).
    private(set) var folderURL: URL?

    private init() {
        if let data = defaults.data(forKey: Self.folderKey), let url = Self.resolve(data) {
            if url.startAccessingSecurityScopedResource() || FileManager.default.isReadableFile(atPath: url.path) {
                folderURL = url
            }
        }
    }

    // MARK: Folder

    /// Asks for the SQL folder; nil when cancelled.
    func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose SQL Folder"
        panel.message = "MxDataSQL lists the .sql files in this folder and opens Save and Open panels there."
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folderURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        setFolder(url)
        return url
    }

    func setFolder(_ url: URL) {
        folderURL?.stopAccessingSecurityScopedResource()
        if let data = Self.bookmark(url) { defaults.set(data, forKey: Self.folderKey) }
        _ = url.startAccessingSecurityScopedResource()
        folderURL = url
    }

    /// The .sql files in the SQL folder, sorted by name.
    func folderFiles() -> [URL] {
        guard let folderURL,
              let urls = try? FileManager.default.contentsOfDirectory(
                at: folderURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return urls.filter { $0.pathExtension.lowercased() == "sql" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    // MARK: Recent files

    /// Recently opened or saved files that still exist, newest first.
    var recentFiles: [URL] {
        let list = (defaults.array(forKey: Self.recentKey) as? [Data] ?? []).compactMap(Self.resolve)
        return list.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func noteRecent(_ url: URL) {
        var list = (defaults.array(forKey: Self.recentKey) as? [Data] ?? [])
            .filter { Self.resolve($0)?.standardizedFileURL != url.standardizedFileURL }
        if let data = Self.bookmark(url) { list.insert(data, at: 0) }
        defaults.set(Array(list.prefix(Self.recentLimit)), forKey: Self.recentKey)
    }

    func clearRecent() {
        defaults.removeObject(forKey: Self.recentKey)
    }

    // MARK: Panels

    func openPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Open SQL File"
        panel.allowedContentTypes = [.sql, .plainText]
        panel.allowsMultipleSelection = false
        panel.directoryURL = folderURL
        return panel.runModal() == .OK ? panel.url : nil
    }

    func savePanel(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Save SQL"
        panel.allowedContentTypes = [.sql]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName
        panel.directoryURL = folderURL
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: Reading and writing

    func read(_ url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .isoLatin1) { return text }
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }

    func write(_ text: String, to url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var contents = text
        if !contents.hasSuffix("\n") { contents += "\n" }
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Bookmarks

    private static func bookmark(_ url: URL) -> Data? {
        try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private static func resolve(_ data: Data) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil,
                        bookmarkDataIsStale: &stale)
    }
}

// MARK: - SQL box file commands

@MainActor
extension WorkspaceSession {
    var sqlFileName: String? { sqlFileURL?.lastPathComponent }

    /// The SQL box came from a file and has changed since it was opened or saved.
    var sqlIsEdited: Bool { sqlFileURL != nil && sqlText != sqlSavedText }

    /// Before the SQL box is replaced: offers to save unsaved changes to its file.
    /// Returns false when the user cancels.
    func confirmReplacingSQL() -> Bool {
        guard sqlIsEdited, let name = sqlFileName else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to \(name)?"
        alert.informativeText = "Your changes to the SQL will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return saveSQL()
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    func newSQL() {
        guard confirmReplacingSQL() else { return }
        sqlText = ""
        sqlFileURL = nil
        sqlSavedText = nil
        sqlError = nil
    }

    /// Opens `url`, or asks for a file when nil.
    func openSQLFile(_ url: URL? = nil) {
        guard confirmReplacingSQL(), let url = url ?? SQLLibrary.shared.openPanel() else { return }
        do {
            let text = try SQLLibrary.shared.read(url)
            sqlText = text
            sqlSavedText = text
            sqlFileURL = url
            sqlError = nil
            SQLLibrary.shared.noteRecent(url)
            infoMessage = "Opened \(url.lastPathComponent)."
        } catch {
            errorMessage = "Could not open \(url.lastPathComponent).\n\n\(error.localizedDescription)"
        }
    }

    /// Saves to the current file, or asks where when there is none.
    @discardableResult
    func saveSQL() -> Bool {
        guard let url = sqlFileURL else { return saveSQLAs() }
        return write(to: url)
    }

    @discardableResult
    func saveSQLAs() -> Bool {
        let suggested = sqlFileName ?? ((grid?.ref?.name ?? "query") + ".sql")
        guard let url = SQLLibrary.shared.savePanel(suggestedName: suggested) else { return false }
        return write(to: url)
    }

    private func write(to url: URL) -> Bool {
        do {
            try SQLLibrary.shared.write(sqlText, to: url)
            sqlFileURL = url
            sqlSavedText = sqlText
            SQLLibrary.shared.noteRecent(url)
            infoMessage = "Saved \(url.lastPathComponent)."
            return true
        } catch {
            errorMessage = "Could not save \(url.lastPathComponent).\n\n\(error.localizedDescription)"
            return false
        }
    }

    func revertSQL() {
        guard let url = sqlFileURL else { return }
        do {
            let text = try SQLLibrary.shared.read(url)
            sqlText = text
            sqlSavedText = text
        } catch {
            errorMessage = "Could not read \(url.lastPathComponent).\n\n\(error.localizedDescription)"
        }
    }

    /// Items placed above the standard text items in the SQL box's right-click menu.
    func sqlMenuItems(run: @escaping () -> Void) -> [NSMenuItem] {
        let library = SQLLibrary.shared
        var items: [NSMenuItem] = []
        items.append(ActionMenuItem("Run SQL", enabled: isConnected && !runningSQL, action: run))
        items.append(.separator())
        items.append(ActionMenuItem("New SQL") { [weak self] in self?.newSQL() })
        items.append(ActionMenuItem("Open SQL File…") { [weak self] in self?.openSQLFile() })

        let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu()
        let recentFiles = library.recentFiles
        for url in recentFiles {
            let item = ActionMenuItem(url.lastPathComponent) { [weak self] in self?.openSQLFile(url) }
            item.toolTip = url.path
            recentMenu.addItem(item)
        }
        if recentFiles.isEmpty { recentMenu.addItem(ActionMenuItem("No Recent Files", enabled: false) {}) }
        recentMenu.addItem(.separator())
        recentMenu.addItem(ActionMenuItem("Clear Menu", enabled: !recentFiles.isEmpty) { library.clearRecent() })
        recent.submenu = recentMenu
        items.append(recent)

        let folder = NSMenuItem(title: "SQL Folder", action: nil, keyEquivalent: "")
        let folderMenu = NSMenu()
        if let folderURL = library.folderURL {
            let files = library.folderFiles()
            let header = NSMenuItem(title: folderURL.lastPathComponent, action: nil, keyEquivalent: "")
            header.isEnabled = false
            folderMenu.addItem(header)
            for url in files {
                folderMenu.addItem(ActionMenuItem(url.lastPathComponent) { [weak self] in self?.openSQLFile(url) })
            }
            if files.isEmpty { folderMenu.addItem(ActionMenuItem("No .sql Files", enabled: false) {}) }
            folderMenu.addItem(.separator())
            folderMenu.addItem(ActionMenuItem("Show SQL Folder in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([folderURL])
            })
        }
        folderMenu.addItem(ActionMenuItem(library.folderURL == nil ? "Choose SQL Folder…" : "Change SQL Folder…") {
            _ = library.chooseFolder()
        })
        folder.submenu = folderMenu
        items.append(folder)

        items.append(.separator())
        items.append(ActionMenuItem(sqlFileURL == nil ? "Save SQL…" : "Save SQL",
                                    enabled: sqlFileURL == nil ? !sqlText.isEmpty : sqlIsEdited) { [weak self] in
            self?.saveSQL()
        })
        items.append(ActionMenuItem("Save SQL As…", enabled: !sqlText.isEmpty) { [weak self] in self?.saveSQLAs() })
        items.append(ActionMenuItem("Revert to Saved", enabled: sqlIsEdited) { [weak self] in self?.revertSQL() })
        if let url = sqlFileURL {
            items.append(ActionMenuItem("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) })
        }
        items.append(.separator())
        return items
    }
}

/// Menu item that runs a closure (for the SQL box's context menu).
final class ActionMenuItem: NSMenuItem, NSMenuItemValidation {
    private let handler: () -> Void
    private let enabledFlag: Bool

    init(_ title: String, enabled: Bool = true, action handler: @escaping () -> Void) {
        self.handler = handler
        self.enabledFlag = enabled
        super.init(title: title, action: #selector(fire(_:)), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire(_ sender: Any?) { handler() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { enabledFlag }
}
