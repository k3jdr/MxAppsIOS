//
//  OfficeFonts.swift
//  MxNoteONE
//
//  Microsoft Office for Mac keeps its fonts (Calibri, Consolas, Cambria,
//  Aptos, Segoe UI…) inside its app bundles, so other apps can't use them.
//  When Office is installed, MxNoteONE loads those fonts for itself only:
//  nothing is copied or installed, and other apps are not affected.
//  Settings ▸ General ▸ Fonts turns this off.
//

import AppKit
import CoreText
import Observation

/// Font families for the app's font menus (including fonts loaded only for MxNoteONE).
@Observable
final class FontLibrary {
    static let shared = FontLibrary()

    private(set) var families: [String] = FontLibrary.currentFamilies()

    func refresh() {
        families = Self.currentFamilies()
    }

    private static func currentFamilies() -> [String] {
        let names = (CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? NSFontManager.shared.availableFontFamilies
        return Array(Set(names.filter { !$0.hasPrefix(".") })).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

enum OfficeFonts {
    static let enabledKey = "useOfficeFonts"
    private static let apps = ["Word", "Excel", "PowerPoint", "OneNote", "Outlook"]

    /// On unless turned off in Settings.
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    private(set) static var loaded: [URL] = []
    /// The Office apps the loaded fonts came from.
    private(set) static var sources: [String] = []

    /// Office font files, each file name once (the apps carry copies of the same fonts).
    static func fontFiles() -> (files: [URL], apps: [String]) {
        var seen = Set<String>()
        var files: [URL] = []
        var found: [String] = []
        let roots = [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications")]
        for app in apps {
            for root in roots {
                let folder = root.appending(path: "Microsoft \(app).app/Contents/Resources/DFonts")
                guard let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
                var added = false
                for url in items where ["ttf", "otf", "ttc"].contains(url.pathExtension.lowercased()) {
                    if seen.insert(url.lastPathComponent.lowercased()).inserted {
                        files.append(url)
                        added = true
                    }
                }
                if added { found.append("Microsoft \(app)") }
                break
            }
        }
        return (files, found)
    }

    /// Loads the Office fonts for MxNoteONE (at launch, or when turned on in Settings).
    static func load() {
        guard enabled, loaded.isEmpty else { return }
        let (files, apps) = fontFiles()
        guard !files.isEmpty else { return }
        CTFontManagerRegisterFontURLs(files as CFArray, .process, true, nil)
        loaded = files
        sources = apps
        FontLibrary.shared.refresh()
    }

    /// Turning on loads the fonts now; turning off takes effect the next time MxNoteONE opens
    /// (macOS keeps fonts that pages are showing).
    static func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: enabledKey)
        if on { load() }
    }
}
