//
//  ProjectOpener.swift
//  MxJobsWMS
//
//  "Open in IDE" for a subscription's source project (e.g. Services/portfolio-java in IntelliJ IDEA).
//  VS Code and IntelliJ IDEA are reached through their URL schemes, which works from the sandbox
//  without access to the folder. CLion, Xcode and Finder have none: the sandbox can hand them only a
//  folder the user chose (Choose… / Grant Access…), remembered as a security-scoped bookmark.
//

import AppKit

enum ProjectOpener {
    /// The real home folder (in the sandbox, NSHomeDirectory() is the app's container).
    static var realHome: String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }

    /// Expands a leading "~" to the real home folder.
    static func expand(_ path: String) -> String {
        let p = path.trimmingCharacters(in: .whitespaces)
        if p == "~" { return realHome }
        if p.hasPrefix("~/") { return realHome + p.dropFirst(1) }
        return p
    }

    private static let bundleIDs: [IDEChoice: [String]] = [
        .vscode: ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"],
        .intellij: ["com.jetbrains.intellij", "com.jetbrains.intellij.ce"],
        .clion: ["com.jetbrains.CLion"],
        .xcode: ["com.apple.dt.Xcode"],
        .finder: ["com.apple.finder"],
    ]

    static func appURL(for ide: IDEChoice) -> URL? {
        for id in bundleIDs[ide] ?? [] {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        }
        return nil
    }

    static func isInstalled(_ ide: IDEChoice) -> Bool { appURL(for: ide) != nil }

    // MARK: Access (security-scoped bookmarks)

    private static let bookmarksKey = "projectFolderBookmarks"

    /// Remembers access to a folder the user chose, so it can later be handed to an IDE.
    static func remember(_ url: URL) {
        guard let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil,
                                               relativeTo: nil) else { return }
        var all = UserDefaults.standard.dictionary(forKey: bookmarksKey) as? [String: Data] ?? [:]
        all[url.standardizedFileURL.path] = data
        UserDefaults.standard.set(all, forKey: bookmarksKey)
    }

    /// The folder with access granted earlier, if the user chose it with Choose… / Grant Access….
    static func accessibleURL(for folder: String) -> URL? {
        let path = URL(fileURLWithPath: expand(folder)).standardizedFileURL.path
        guard let data = (UserDefaults.standard.dictionary(forKey: bookmarksKey) as? [String: Data])?[path] else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        if stale { remember(url) }
        return url
    }

    /// Whether `ide` can be given `folder`: URL-scheme IDEs always can; the others need granted access.
    static func needsAccess(_ folder: String, for ide: IDEChoice) -> Bool {
        ide != .vscode && ide != .intellij && accessibleURL(for: folder) == nil
    }

    /// Asks the user to choose (confirm) the folder, granting access; returns the chosen path.
    static func grantAccess(startingAt folder: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Grant Access"
        panel.message = "Choose the project folder so MxJobsWMS can open it in your IDE."
        let start = URL(fileURLWithPath: expand(folder), isDirectory: true)
        panel.directoryURL = start
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        remember(url)
        return url
    }

    // MARK: Opening

    /// Opens `folder` in `ide`. Calls `done` with an error message, or nil once the IDE took it.
    static func open(_ folder: String, in ide: IDEChoice, done: @escaping (String?) -> Void = { _ in }) {
        let path = expand(folder)
        guard !path.isEmpty else { return done("No project folder set.") }
        guard let app = appURL(for: ide) else { return done("\(ide.title) isn't installed.") }
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        switch ide {
        case .vscode:
            // VS Code's documented form for opening a project folder: vscode://file/<path>/
            let folderPath = encoded.hasSuffix("/") ? encoded : encoded + "/"
            if let url = URL(string: "vscode://file\(folderPath)"), NSWorkspace.shared.open(url) { return done(nil) }
            return done("VS Code did not accept the request.")
        case .intellij:
            if let url = URL(string: "idea://open?file=\(encoded)"), NSWorkspace.shared.open(url) { return done(nil) }
            return done("IntelliJ IDEA did not accept the request.")
        case .clion, .xcode, .finder:
            // No URL scheme: the sandbox can hand over only a folder the user granted access to.
            guard let url = accessibleURL(for: folder) else {
                return done("MxJobsWMS needs access to this folder to open it in \(ide.title): use Grant Access….")
            }
            let scoped = url.startAccessingSecurityScopedResource()
            if ide == .finder {
                NSWorkspace.shared.activateFileViewerSelecting([url])
                if scoped { url.stopAccessingSecurityScopedResource() }
                return done(nil)
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration) { _, error in
                DispatchQueue.main.async {
                    if scoped { url.stopAccessingSecurityScopedResource() }
                    done(error.map { "Could not open it in \(ide.title): \($0.localizedDescription)" })
                }
            }
        }
    }
}
