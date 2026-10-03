//
//  AppSettings.swift
//  MxDeskMGR
//
//  User preferences, favorites and recent servers, kept in UserDefaults.
//

import Foundation
import Observation

extension Notification.Name {
    /// Hidden files or folder ordering changed: every pane re-lists its folder.
    static let mxListingOptionsChanged = Notification.Name("MxDeskMGR.listingOptionsChanged")
    /// A file operation finished: panes refresh in case their folder was affected.
    static let mxFilesChanged = Notification.Name("MxDeskMGR.filesChanged")
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
