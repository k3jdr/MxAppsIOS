//
//  PageNavigation.swift
//  MxNoteONE
//
//  Back and Forward through the pages you've visited, as in a browser:
//  ⌃← / ⌃→ (Go menu), ⌘[ / ⌘] as in Safari and Finder, and the back and
//  forward buttons of a mouse. macOS gives ⌃← / ⌃→ to Mission Control
//  ("Move left / right a space") unless they're turned off in System Settings,
//  so MxNoteONE notices that and says how to free them.
//

import AppKit

enum NavigationKeys {
    /// The Mission Control shortcuts that use ⌃← and ⌃→ (symbolic hot keys 79 and 81) and the keys they'd have.
    private static let spaceKeys: [(id: String, keyCode: Int)] = [("79", 123), ("81", 124)]

    /// Whether Mission Control's "Move left a space" / "Move right a space" still has ⌃← / ⌃→.
    static var takenByMissionControl: Bool {
        let domain = "com.apple.symbolichotkeys" as CFString
        CFPreferencesAppSynchronize(domain)
        let all = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, domain) as? [String: Any]
        return spaceKeys.contains { id, keyCode in
            // Not set: macOS's default, which is on with ⌃← / ⌃→.
            guard let entry = all?[id] as? [String: Any] else { return true }
            if let enabled = entry["enabled"] as? Bool, !enabled { return false }
            guard let parameters = (entry["value"] as? [String: Any])?["parameters"] as? [Int], parameters.count == 3 else { return true }
            // Control alone (shift 0x20000, control 0x40000, option 0x80000, command 0x100000).
            return parameters[1] == keyCode && parameters[2] & 0x1E0000 == 0x40000
        }
    }

    /// System Settings ▸ Keyboard (Keyboard Shortcuts… is there).
    static func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    static let freeKeysHelp = "macOS uses Control–Left Arrow and Control–Right Arrow to move between Spaces (desktops) and keeps them from every app, so MxNoteONE never sees them.\n\nTo use them for Back and Forward: in System Settings ▸ Keyboard, click Keyboard Shortcuts…, choose Mission Control, open its Mission Control group and turn off “Move left a space” and “Move right a space” (or give them other keys, such as ⌃⌥← and ⌃⌥→).\n\nUntil then, ⌘[ and ⌘] — or a mouse's back and forward buttons — go Back and Forward."

    /// Go ▸ Free ⌃← ⌃→ from Mission Control…
    @MainActor static func explain() {
        let alert = NSAlert()
        alert.messageText = "⌃← and ⌃→ belong to Mission Control"
        alert.informativeText = freeKeysHelp
        alert.addButton(withTitle: "Open Keyboard Settings")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn { openKeyboardSettings() }
    }

    /// The notebook window (not Scripts, Settings, a sheet or a panel).
    @MainActor static func isNotebookWindow(_ window: NSWindow?) -> Bool {
        guard let window, window.sheetParent == nil else { return false }
        return window.identifier?.rawValue.hasPrefix("main") == true
    }

    /// ⌘[ / ⌘] and a mouse's back / forward buttons in the notebook window (⌃← / ⌃→ are the Go menu's).
    @MainActor static func install() {
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .otherMouseDown]) { event in
            MainActor.assumeIsolated { handle(event) } ? nil : event
        }
    }

    @MainActor static func handle(_ event: NSEvent) -> Bool {
        let store = NotebookStore.shared
        switch event.type {
        case .keyDown:
            guard isNotebookWindow(NSApp.keyWindow), !store.appLocked,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function]) == .command
            else { return false }
            switch event.charactersIgnoringModifiers {
            case "[": store.goBack(); return true
            case "]": store.goForward(); return true
            default: return false
            }
        case .otherMouseDown:
            // Buttons 4 and 5 of a mouse (numbered 3 and 4 from 0): back and forward, as in browsers.
            // The window it's over (an event without one — from another app or a script — goes by where it is).
            let window = event.window ?? NSApp.window(withWindowNumber: NSWindow.windowNumber(at: event.locationInWindow, belowWindowWithWindowNumber: 0))
            guard isNotebookWindow(window), !store.appLocked, event.buttonNumber == 3 || event.buttonNumber == 4 else { return false }
            if event.buttonNumber == 3 { store.goBack() } else { store.goForward() }
            return true
        default:
            return false
        }
    }
}
