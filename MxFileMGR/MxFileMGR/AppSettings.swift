//
//  AppSettings.swift
//  MxFileMGR
//
//  User preferences, favorites and recent servers, kept in UserDefaults.
//

import Foundation
import Observation

extension Notification.Name {
    /// Hidden files or folder ordering changed: every pane re-lists its folder.
    static let mxListingOptionsChanged = Notification.Name("MxFileMGR.listingOptionsChanged")
    /// A file operation finished: panes refresh in case their folder was affected.
    static let mxFilesChanged = Notification.Name("MxFileMGR.filesChanged")
}

/// A cloud storage root (iCloud Drive, OneDrive, SharePoint, Teams, Google Drive, Dropbox, Box) with the name to show for it.
struct CloudLocation: Identifiable {
    let name: String
    let icon: String
    let url: URL
    var id: String { url.path }
}

@Observable
final class AppSettings {
    static let shared = AppSettings()

    @ObservationIgnored private let defaults = UserDefaults.standard

    var showHidden: Bool {
        didSet { defaults.set(showHidden, forKey: "showHidden"); listingChanged() }
    }
    var foldersFirst: Bool {
        didSet { defaults.set(foldersFirst, forKey: "foldersFirst"); listingChanged() }
    }
    var confirmTrash: Bool {
        didSet { defaults.set(confirmTrash, forKey: "confirmTrash") }
    }
    var showFunctionKeyBar: Bool {
        didSet { defaults.set(showFunctionKeyBar, forKey: "showFunctionKeyBar") }
    }
    /// Application used by Edit (F4).
    var editorPath: String {
        didSet { defaults.set(editorPath, forKey: "editorPath") }
    }
    /// Application used by Open Terminal Here.
    var terminalPath: String {
        didSet { defaults.set(terminalPath, forKey: "terminalPath") }
    }
    var favorites: [String] {
        didSet { defaults.set(favorites, forKey: "favorites") }
    }
    var recentServers: [String] {
        didSet { defaults.set(recentServers, forKey: "recentServers") }
    }

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        defaults.register(defaults: [
            "showHidden": false,
            "foldersFirst": true,
            "confirmTrash": false,
            "showFunctionKeyBar": true,
            "editorPath": "/System/Applications/TextEdit.app",
            "terminalPath": "/System/Applications/Utilities/Terminal.app",
            "favorites": [home, home + "/Desktop", home + "/Documents", home + "/Downloads", "/Applications"],
            "recentServers": [String](),
        ])
        showHidden = defaults.bool(forKey: "showHidden")
        foldersFirst = defaults.bool(forKey: "foldersFirst")
        confirmTrash = defaults.bool(forKey: "confirmTrash")
        showFunctionKeyBar = defaults.bool(forKey: "showFunctionKeyBar")
        editorPath = defaults.string(forKey: "editorPath") ?? ""
        terminalPath = defaults.string(forKey: "terminalPath") ?? ""
        favorites = defaults.stringArray(forKey: "favorites") ?? []
        recentServers = defaults.stringArray(forKey: "recentServers") ?? []
    }

    /// The local iCloud Drive folder, when iCloud Drive is turned on for this account.
    static var iCloudDriveURL: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        return FileOps.isRealDirectory(url) ? url : nil
    }

    /// OneDrive accounts synced by the OneDrive app (File Provider folders in ~/Library/CloudStorage):
    /// "OneDrive-Personal" and "OneDrive-<Organisation>" for work or school accounts.
    static var oneDriveURLs: [URL] {
        cloudStorageFolders(prefix: "OneDrive").filter { !$0.lastPathComponent.hasPrefix(sharePointPrefix) }
    }

    /// SharePoint document libraries synced by the OneDrive app ("Sync" in SharePoint, or OneDrive's
    /// "Add shortcut"): one "OneDrive-SharedLibraries-<Organisation>" folder per organisation in
    /// ~/Library/CloudStorage, holding a "<Site> - <Library>" folder for each library.
    static var sharePointURLs: [URL] { cloudStorageFolders(prefix: sharePointPrefix) }

    private static let sharePointPrefix = "OneDrive-SharedLibraries"

    /// Files shared in Microsoft Teams chats: the "Microsoft Teams Chat Files" folder Teams keeps in each
    /// OneDrive account. (Channel files live in the team's SharePoint site and sync as SharePoint libraries.)
    static var teamsChatFolders: [URL] {
        oneDriveURLs.map { $0.appendingPathComponent("Microsoft Teams Chat Files") }.filter(FileOps.isRealDirectory)
    }

    /// "Teams Chat Files", or "Teams Chat Files – Contoso" when several OneDrive accounts have one.
    static func teamsChatName(_ url: URL, accounts: Int) -> String {
        guard accounts > 1 else { return "Teams Chat Files" }
        let account = url.deletingLastPathComponent().lastPathComponent.dropFirst("OneDrive".count)
            .trimmingCharacters(in: CharacterSet(charactersIn: "- "))
        return "Teams Chat Files – " + (account.isEmpty ? "OneDrive" : account)
    }

    /// "SharePoint – Contoso" for "OneDrive-SharedLibraries-Contoso".
    static func sharePointName(_ url: URL) -> String {
        let org = url.lastPathComponent.dropFirst(sharePointPrefix.count).trimmingCharacters(in: CharacterSet(charactersIn: "- "))
        return org.isEmpty ? "SharePoint" : "SharePoint – \(org)"
    }

    /// Google Drive accounts: "GoogleDrive-<email>" in ~/Library/CloudStorage (Google Drive for desktop),
    /// or the older /Volumes/GoogleDrive (streaming) and ~/Google Drive (Backup and Sync) folders.
    static var googleDriveURLs: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let legacy = [URL(fileURLWithPath: "/Volumes/GoogleDrive"), home.appendingPathComponent("Google Drive")]
        return cloudStorageFolders(prefix: "GoogleDrive") + legacy.filter(FileOps.isRealDirectory)
    }

    /// Dropbox folders: the paths Dropbox records in ~/.dropbox/info.json (personal and business),
    /// "Dropbox…" folders in ~/Library/CloudStorage, and the older ~/Dropbox, ~/Dropbox (Personal),
    /// ~/Dropbox (Team) folders. Symlinks are resolved so each account is listed once.
    static var dropboxURLs: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates: [URL] = []
        if let data = try? Data(contentsOf: home.appendingPathComponent(".dropbox/info.json")),
           let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["personal", "business"] {
                if let account = info[key] as? [String: Any], let path = account["path"] as? String {
                    candidates.append(URL(fileURLWithPath: path))
                }
            }
        }
        candidates += cloudStorageFolders(prefix: "Dropbox")
        let homeNames = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        candidates += homeNames.filter { $0 == "Dropbox" || $0.hasPrefix("Dropbox (") }
            .sorted().map { home.appendingPathComponent($0) }
        var seen = Set<String>()
        return candidates.map { $0.resolvingSymlinksInPath() }
            .filter { FileOps.isRealDirectory($0) && seen.insert($0.path).inserted }
    }

    /// "Dropbox" for a personal folder, "Dropbox – Acme" for "Dropbox-Acme" or "Dropbox (Acme)".
    static func dropboxName(_ url: URL) -> String {
        var account = url.lastPathComponent.dropFirst("Dropbox".count)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-() "))
        if account.caseInsensitiveCompare("Personal") == .orderedSame { account = "" }
        return account.isEmpty ? "Dropbox" : "Dropbox – \(account)"
    }

    /// Box Drive: "Box-Box" in ~/Library/CloudStorage (current Box Drive) or the older ~/Box folder.
    /// Symlinks are resolved so the account is listed once.
    static var boxURLs: [URL] {
        let candidates = cloudStorageFolders(prefix: "Box-")
            + [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Box")]
        var seen = Set<String>()
        return candidates.map { $0.resolvingSymlinksInPath() }
            .filter { FileOps.isRealDirectory($0) && seen.insert($0.path).inserted }
    }

    /// "Box" for Box Drive's "Box-Box" or ~/Box; "Box – <name>" for any other "Box-<name>" folder.
    static func boxName(_ url: URL) -> String {
        let account = url.lastPathComponent.dropFirst("Box".count).trimmingCharacters(in: CharacterSet(charactersIn: "- "))
        return account.isEmpty || account == "Box" ? "Box" : "Box – \(account)"
    }

    /// Account folders in ~/Library/CloudStorage whose names start with `prefix`.
    private static func cloudStorageFolders(prefix: String) -> [URL] {
        let storage = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: storage.path)) ?? []
        return names.filter { $0.hasPrefix(prefix) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { storage.appendingPathComponent($0) }
            .filter(FileOps.isRealDirectory)
    }

    /// Display name for a Google Drive folder: "Google Drive", or "Google Drive – <email>" when there are several.
    static func googleDriveName(_ url: URL, accounts: Int) -> String {
        let folder = url.lastPathComponent
        guard folder.hasPrefix("GoogleDrive-"), accounts > 1 else { return "Google Drive" }
        return "Google Drive – " + folder.dropFirst("GoogleDrive-".count)
    }

    /// iCloud Drive, OneDrive, SharePoint, Teams chat files, Google Drive, Dropbox and Box accounts present on this Mac, shown at the top of Favorites.
    /// Re-scanned at most every few seconds (the path bar asks on every redraw).
    static var cloudLocations: [CloudLocation] {
        if let cached = cloudCache, Date().timeIntervalSince(cached.time) < 5 { return cached.list }
        var list: [CloudLocation] = []
        if let iCloud = iCloudDriveURL { list.append(CloudLocation(name: "iCloud Drive", icon: "icloud", url: iCloud)) }
        for url in oneDriveURLs {
            let account = url.lastPathComponent.dropFirst("OneDrive".count).drop { $0 == "-" || $0 == " " }
            let name = account.isEmpty || account == "Personal" ? "OneDrive" : "OneDrive – \(account)"
            list.append(CloudLocation(name: name, icon: "cloud", url: url))
        }
        for url in sharePointURLs {
            list.append(CloudLocation(name: sharePointName(url), icon: "building.2", url: url))
        }
        let chats = teamsChatFolders
        for url in chats {
            list.append(CloudLocation(name: teamsChatName(url, accounts: chats.count), icon: "bubble.left.and.bubble.right", url: url))
        }
        let google = googleDriveURLs
        for url in google {
            list.append(CloudLocation(name: googleDriveName(url, accounts: google.count), icon: "triangle", url: url))
        }
        for url in dropboxURLs {
            list.append(CloudLocation(name: dropboxName(url), icon: "shippingbox", url: url))
        }
        for url in boxURLs {
            list.append(CloudLocation(name: boxName(url), icon: "archivebox", url: url))
        }
        cloudCache = (Date(), list)
        return list
    }

    private static var cloudCache: (time: Date, list: [CloudLocation])?

    /// The cloud location whose root is `path`, if any.
    static func cloudLocation(at path: String) -> CloudLocation? {
        cloudLocations.first { $0.url.path == path }
    }

    func addFavorite(_ url: URL) {
        let path = url.fsPath
        if !favorites.contains(path) { favorites.append(path) }
    }

    func addRecentServer(_ address: String) {
        recentServers.removeAll { $0 == address }
        recentServers.insert(address, at: 0)
        if recentServers.count > 10 { recentServers.removeLast(recentServers.count - 10) }
    }

    private func listingChanged() {
        NotificationCenter.default.post(name: .mxListingOptionsChanged, object: nil)
    }
}
