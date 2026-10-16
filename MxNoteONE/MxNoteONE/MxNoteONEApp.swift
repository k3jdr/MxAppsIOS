//
//  MxNoteONEApp.swift
//  MxNoteONE
//
//  A digital notebook in the spirit of Microsoft OneNote: notebooks with
//  sections, section groups and pages; free-form pages with text, tables,
//  pictures, attachments, recordings and ink; tags, search, links between
//  pages, password-protected sections and a recycle bin.
//

import SwiftUI

@main
struct MxNoteONEApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("MxNoteONE", id: "main") {
            MainView()
        }
        .defaultSize(width: 1380, height: 860)
        .defaultLaunchBehavior(.presented)
        .commands {
            MainCommands()
            SidebarCommands()
        }

        Window("Tag Summary", id: "tags") {
            TagSummaryView()
        }
        .defaultSize(width: 640, height: 560)
        .restorationBehavior(.disabled)

        Window("Recycle Bin", id: "trash") {
            RecycleBinView()
        }
        .defaultSize(width: 680, height: 420)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Calibri, Consolas and the other Microsoft Office fonts, for MxNoteONE only.
        OfficeFonts.load()
        // ⌃Z / ⌃Y (as in OneNote for Windows) also undo and redo; ⌘Z / ⇧⌘Z are the Mac keys.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // F7: check spelling of the text in focus.
            if SpellCheck.isTrigger(event) {
                SpellCheck.run()
                return nil
            }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard mods == .control || mods == [.control, .shift] else { return event }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "z": NSApp.sendAction(mods.contains(.shift) ? Selector(("redo:")) : Selector(("undo:")), to: nil, from: nil)
            case "y" where mods == .control: NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
            default: return event
            }
            return nil
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotebookStore.shared.canvas?.flush()
    }

    func applicationDidResignActive(_ notification: Notification) {
        NotebookStore.shared.appDidResignActive()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        NotebookStore.shared.appDidBecomeActive()
    }
}
