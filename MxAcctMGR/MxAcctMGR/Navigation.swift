//
//  Navigation.swift
//  MxAcctMGR
//
//  Back and Forward through the places you've visited, as in a browser and in MxNoteONE: the toolbar's ‹ and ›
//  (hold either for the places before or after), Go ▸ Back / Forward / History, ⌘[ and ⌘] as in Safari, Finder and
//  MxNoteONE, ⌃← and ⌃→ (unless Mission Control keeps them for moving between Spaces), and a mouse's back and
//  forward buttons. A place is a screen — with the report a walkthrough shows, and the day Earnings by Day shows.
//

import AppKit
import SwiftUI

/// A place in the window, for Back and Forward.
struct Place: Equatable {
    var screen: Screen
    /// The walkthrough's report.
    var report: String?
    /// Earnings by Day's day.
    var date: String?
}

extension PortStore {
    /// Where the window is now.
    var place: Place {
        Place(screen: screen, report: screen == .reportWalkthrough ? reportID : nil, date: screen == .earningsDay ? earnings.date : nil)
    }

    /// Notes where the window is now (ContentView calls it whenever `place` changes): the place before joins the Back
    /// list, and the Forward list goes, as in a browser.
    func recordPlace() {
        let now = place
        guard now != historyCurrent else { return }
        if let previous = historyCurrent {
            backStack.append(previous)
            if backStack.count > 100 { backStack.removeFirst() }
        }
        if !forwardStack.isEmpty { forwardStack.removeAll() }
        historyCurrent = now
    }

    /// The places Back goes to, the nearest first (the ‹ button's menu, Go ▸ History).
    var backHistory: [Place] {
        _ = historyVersion
        return backStack.reversed()
    }

    /// The places Forward goes to, the nearest first.
    var forwardHistory: [Place] {
        _ = historyVersion
        return forwardStack.reversed()
    }

    /// Back one place (⌘[, ⌃←, ‹, a mouse's back button), or several (the ‹ button's menu, Go ▸ History).
    func goBack(steps: Int = 1) { travel(back: true, steps: steps) }

    /// Forward one place (⌘], ⌃→, ›, a mouse's forward button), or several.
    func goForward(steps: Int = 1) { travel(back: false, steps: steps) }

    /// Moves through the history like a browser: the places passed go onto the other list.
    private func travel(back: Bool, steps: Int) {
        var target: Place?
        var moved = 0
        while moved < steps, let p = back ? backStack.popLast() : forwardStack.popLast() {
            if let current = historyCurrent {
                if back { forwardStack.append(current) } else { backStack.append(current) }
            }
            historyCurrent = p
            target = p
            moved += 1
        }
        guard let target else { return NSSound.beep() }
        if let r = target.report { reportID = r }
        if let d = target.date { earnings.date = d }
        screen = target.screen
    }

    /// A place in the history menus: the screen's title, the report's, or the day's.
    func historyTitle(_ p: Place) -> String {
        if let r = p.report { return MarketReport.report(r).title }
        if let d = p.date {
            let day = EarningsDates.date(d).formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
            return "\(p.screen.title) — \(day)"
        }
        return title(p.screen)
    }

    func historySymbol(_ p: Place) -> String {
        p.report.map { MarketReport.report($0).symbol } ?? p.screen.systemImage
    }
}

// MARK: - The toolbar's ‹ and ›

/// ‹ and ›: click to go back or forward a place; hold for the places before or after (as in Safari and MxNoteONE).
struct BackForwardButtons: ToolbarContent {
    @Bindable var store: PortStore

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Menu {
                ForEach(Array(store.backHistory.prefix(15).enumerated()), id: \.offset) { i, p in
                    Button { store.goBack(steps: i + 1) } label: { Label(store.historyTitle(p), systemImage: store.historySymbol(p)) }
                }
            } label: {
                Label("Back", systemImage: "chevron.left")
            } primaryAction: {
                store.goBack()
            }
            .menuIndicator(.hidden)
            .disabled(!store.canGoBack)
            .help(store.backHistory.first.map { "Back to \(store.historyTitle($0)) (⌘[ or ⌃←) — hold for the places before" } ?? "Back (⌘[ or ⌃←)")
            .quickHelp("Back", "Back to the place before, as in a browser: the screen, walkthrough or earnings day you came from. Hold the button for the places before it; Go ▸ History lists them too. Also ⌃←, or a mouse's back button.", shortcut: "⌘[", symbol: "chevron.left")
            Menu {
                ForEach(Array(store.forwardHistory.prefix(15).enumerated()), id: \.offset) { i, p in
                    Button { store.goForward(steps: i + 1) } label: { Label(store.historyTitle(p), systemImage: store.historySymbol(p)) }
                }
            } label: {
                Label("Forward", systemImage: "chevron.right")
            } primaryAction: {
                store.goForward()
            }
            .menuIndicator(.hidden)
            .disabled(!store.canGoForward)
            .help(store.forwardHistory.first.map { "Forward to \(store.historyTitle($0)) (⌘] or ⌃→) — hold for the places after" } ?? "Forward (⌘] or ⌃→)")
            .quickHelp("Forward", "Forward again to where you went Back from. Hold the button for the places after it. Also ⌃→, or a mouse's forward button.", shortcut: "⌘]", symbol: "chevron.right")
        }
    }
}

// MARK: - The Go menu

/// Go ▸ Back, Forward and History, then the guide's Previous and Next Step.
struct GoCommands: Commands {
    let store: PortStore

    var body: some Commands {
        CommandMenu("Go") {
            GoHistoryItems(store: store)
            Divider()
            Button("Previous Step") { if let p = store.screen.previous { store.go(p) } }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Next Step") { if let n = store.screen.next { store.go(n) } }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
        }
    }
}

/// A view of their own, so the items follow the history as it changes.
private struct GoHistoryItems: View {
    let store: PortStore

    var body: some View {
        // ⌃← / ⌃→ and a mouse's side buttons also work (NavigationKeys).
        Button("Back") { store.goBack() }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(!store.canGoBack)
        Button("Forward") { store.goForward() }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(!store.canGoForward)
        Menu("History") {
            let back = store.backHistory.prefix(15)
            let forward = store.forwardHistory.prefix(15)
            ForEach(Array(forward.enumerated()).reversed(), id: \.offset) { i, p in
                Button(store.historyTitle(p)) { store.goForward(steps: i + 1) }
            }
            Toggle(store.historyTitle(store.place), isOn: .constant(true)).disabled(true)
            ForEach(Array(back.enumerated()), id: \.offset) { i, p in
                Button(store.historyTitle(p)) { store.goBack(steps: i + 1) }
            }
        }
    }
}

// MARK: - ⌃← ⌃→ and the mouse's buttons

enum NavigationKeys {
    /// ⌃← / ⌃→ and a mouse's back / forward buttons in the main window (⌘[ / ⌘] are the Go menu's).
    @MainActor static func install(_ store: PortStore) {
        guard !installed else { return }
        installed = true
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .otherMouseDown]) { event in
            MainActor.assumeIsolated { handle(event, store) } ? nil : event
        }
    }

    @MainActor private static var installed = false

    /// The main window — not a sheet, a panel or the hover card.
    @MainActor static func isMainWindow(_ window: NSWindow?) -> Bool {
        guard let window, window.sheetParent == nil, window.attachedSheet == nil else { return false }
        return window.identifier?.rawValue.hasPrefix("main") == true
    }

    @MainActor static func handle(_ event: NSEvent, _ store: PortStore) -> Bool {
        switch event.type {
        case .keyDown:
            // Control and an arrow alone, while no text has the keyboard (there ⌃← / ⌃→ move the insertion point).
            let window = event.window ?? NSApp.keyWindow
            guard isMainWindow(window), !(window?.firstResponder is NSText),
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function]) == .control
            else { return false }
            switch event.keyCode {
            case 123: store.goBack(); return true
            case 124: store.goForward(); return true
            default: return false
            }
        case .otherMouseDown:
            // Buttons 4 and 5 of a mouse (numbered 3 and 4 from 0): back and forward, as in browsers. The window it's
            // over (an event without one goes by where it is: its location is then on the screen).
            let window = event.window ?? NSApp.window(withWindowNumber: NSWindow.windowNumber(at: event.locationInWindow, belowWindowWithWindowNumber: 0))
            guard isMainWindow(window), event.buttonNumber == 3 || event.buttonNumber == 4 else { return false }
            if event.buttonNumber == 3 { store.goBack() } else { store.goForward() }
            return true
        default:
            return false
        }
    }
}
