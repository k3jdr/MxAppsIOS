//
//  WebBrowser.swift
//  MxNoteONE
//
//  Which browser opens web links from MxNoteONE: the Mac's default, or one
//  chosen in Settings ▸ General ▸ Web Links (DuckDuckGo, say, while Safari
//  stays the Mac's default for everything else). Only http and https links
//  go to the chosen browser; email links and other kinds open as usual.
//

import AppKit

enum WebBrowser {
    static let key = "webBrowserBundleID"

    /// A browser on this Mac.
    struct App: Identifiable, Hashable {
        let id: String      // bundle identifier
        let name: String
        let url: URL
        var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }
    }

    private static let probe = URL(string: "https://www.example.com")!

    /// The browser chosen for MxNoteONE's links ("" = the Mac's default).
    static var chosenID: String {
        get { UserDefaults.standard.string(forKey: key) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Every app that can open web pages, by name.
    static func installed() -> [App] {
        var seen = Set<String>()
        return NSWorkspace.shared.urlsForApplications(toOpen: probe).compactMap { url -> App? in
            guard let id = Bundle(url: url)?.bundleIdentifier, seen.insert(id).inserted else { return nil }
            return App(id: id, name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""), url: url)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The Mac's default browser.
    static var systemDefault: App? {
        guard let url = NSWorkspace.shared.urlForApplication(toOpen: probe), let id = Bundle(url: url)?.bundleIdentifier else { return nil }
        return App(id: id, name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""), url: url)
    }

    /// The browser links open in: the chosen one while it's installed, else the Mac's default.
    static var current: App? {
        if !chosenID.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: chosenID) {
            return App(id: chosenID, name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""), url: url)
        }
        return systemDefault
    }

    static func isWeb(_ url: URL) -> Bool { ["http", "https"].contains(url.scheme?.lowercased() ?? "") }

    #if DEBUG
    /// Self-tests: where links were sent, instead of opening them.
    nonisolated(unsafe) static var testOpened: [(url: URL, app: String?)]?
    #endif

    /// Opens a link: web links in the chosen browser, anything else as the Mac would.
    static func open(_ url: URL) {
        let chosen = isWeb(url) && !chosenID.isEmpty ? NSWorkspace.shared.urlForApplication(withBundleIdentifier: chosenID) : nil
        #if DEBUG
        if testOpened != nil { testOpened!.append((url, chosen.flatMap { Bundle(url: $0)?.bundleIdentifier })); return }
        #endif
        guard let chosen else {
            NSWorkspace.shared.open(url)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: chosen, configuration: configuration) { _, error in
            // The chosen browser couldn't take it: the Mac's default instead.
            if error != nil { DispatchQueue.main.async { NSWorkspace.shared.open(url) } }
        }
    }
}
