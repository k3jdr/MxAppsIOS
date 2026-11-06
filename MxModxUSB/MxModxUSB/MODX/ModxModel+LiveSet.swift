//
//  ModxModel+LiveSet.swift — MxModxUSB
//
//  The Live Set screen's data beyond the MODX's own bank: the names of the Performances its slots recall (what the
//  MODX shows on each slot), Live Set banks kept in workspace files (the bank menu), and reading the bank again.
//
//  The MODX can't be switched to another Live Set bank over USB, and it reports only the bank in use. A bank in a
//  workspace file can be looked at here and sent to the MODX's Live Set edit buffer (store it on the MODX to keep it).
//

import AppKit
import Foundation

extension ModxModel {
    /// Where the names of User and Library Performances seen on the MODX are kept between launches.
    static let seenNamesKey = "seenPerformanceNames"

    static func loadSeenNames() -> ModxPerformanceNames {
        ModxPerformanceNames(seen: UserDefaults.standard.dictionary(forKey: seenNamesKey) as? [String: String] ?? [:])
    }

    /// The name the MODX shows on a slot: its Performance's (nil if the app doesn't know it).
    func performanceName(for slot: ModxLiveSlot) -> (name: String, source: ModxPerformanceNames.Source)? {
        performanceNames.name(of: slot)
    }

    /// Notes the name of the Performance just chosen on the MODX, for slots that recall it.
    func learnPerformanceName(lsb: UInt8, number: Int, name: String) {
        if performanceNames.learn(lsb: lsb, number: number, name: name) {
            UserDefaults.standard.set(performanceNames.seen, forKey: Self.seenNamesKey)
        }
    }

    // MARK: Reading again

    /// Reads the MODX's Live Set again (after another bank was chosen on the MODX, say) and looks for workspace files.
    func refreshLiveSet() async {
        guard !liveSetRefreshing else { return }
        liveSetRefreshing = true
        defer { liveSetRefreshing = false }
        if connected, let blocks = await link.bulk(.liveSetBulk, bulkInterval: bulkInterval) {
            let before = liveSet
            keep(blocks)
            rederive(.liveSetBank)
            if liveSet != before {
                // Another bank (or one changed on the MODX): undoing would now write into the wrong slots.
                undoStack.removeAll {
                    switch $0.target { case .liveSetBank, .liveSetPage, .liveSetSlot: true; default: false }
                }
            }
        }
        await findWorkspaceLiveSets()
    }

    // MARK: Banks in workspace files

    /// Looks for workspace files with a Live Set bank: the open one, recent ones, those in Documents (two folders
    /// deep) and any chosen this session. Newest first.
    func findWorkspaceLiveSets() async {
        var urls: [URL] = []
        if let workspaceURL { urls.append(workspaceURL) }
        urls += workspaceLiveSets.map(\.url)
        urls += NSDocumentController.shared.recentDocumentURLs
        for folder in FileManager.default.urls(for: .documentDirectory, in: .userDomainMask) {
            urls += Self.workspaceFiles(in: folder, depth: 2)
        }
        var paths = Set<String>()
        let unique = urls.filter { $0.pathExtension == "modxworkspace" && paths.insert($0.standardizedFileURL.path).inserted }
        let found = await Task.detached(priority: .utility) { unique.compactMap { ModxWorkspaceLiveSet(url: $0) } }.value
        workspaceLiveSets = found.sorted { $0.savedAt > $1.savedAt }
    }

    nonisolated static func workspaceFiles(in folder: URL, depth: Int) -> [URL] {
        guard depth > 0, let items = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found: [URL] = []
        for item in items {
            if item.pathExtension == "modxworkspace" {
                found.append(item)
            } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                found += workspaceFiles(in: item, depth: depth - 1)
            }
        }
        return found
    }

    /// A workspace just saved or opened: a recent document, and its Live Set in the bank menu.
    func noteWorkspace(_ url: URL, _ file: ModxWorkspaceFile) {
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        guard let entry = ModxWorkspaceLiveSet(url: url, file: file) else { return }
        workspaceLiveSets.removeAll { $0.url.standardizedFileURL == url.standardizedFileURL }
        workspaceLiveSets.append(entry)
        workspaceLiveSets.sort { $0.savedAt > $1.savedAt }
    }

    /// Asks for a workspace file and adds its Live Set bank to the menu; its URL, or nil if none was chosen or it
    /// holds no Live Set.
    func chooseWorkspaceLiveSet() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.modxWorkspace, .json]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a MODX7 workspace to show its Live Set bank."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard let file = try? ModxWorkspaceFile.read(url), ModxWorkspaceLiveSet(url: url, file: file) != nil else {
            let alert = NSAlert()
            alert.messageText = "No Live Set bank in “\(url.lastPathComponent)”"
            alert.informativeText = "It isn't a MxModxUSB workspace, or it was saved without the Live Set."
            alert.runModal()
            return nil
        }
        noteWorkspace(url, file)
        return url
    }

    /// Sends a workspace's Live Set bank to the MODX's Live Set edit buffer, then reads it back to compare.
    func sendLiveSet(_ entry: ModxWorkspaceLiveSet) async -> String {
        await sendWorkspace(entry.file, groups: ["liveSet"])
    }
}
