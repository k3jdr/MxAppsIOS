//
//  Navigation.swift
//  MxDataHUB
//
//  Back and Forward through the places you've visited, as in a browser and in MxAcctMGR and MxNoteONE: the toolbar's
//  ‹ and › (hold either for the places before or after), Go ▸ Back / Forward / History, ⌘[ and ⌘] as in Safari and
//  Finder, ⌃← and ⌃→ (unless Mission Control keeps them for moving between Spaces), and a mouse's back and forward
//  buttons. A place is a screen with what it shows: the security, portfolio or benchmark selected there.
//

import AppKit
import SwiftUI

/// A place in the window, for Back and Forward.
struct Place: Equatable {
    var section: SRMSection
    /// The security, portfolio or benchmark selected on Securities, Portfolios or Benchmarks.
    var item: Int64?
}

/// A place and its title when it was visited (rows may be gone from the screen by the time the menus show it).
struct Visit {
    var place: Place
    var title: String
}

extension SRMStore {
    /// Where the window is now.
    var place: Place {
        switch section {
        case .securities: Place(section: section, item: selectedSecurityID)
        case .portfolios: Place(section: section, item: selectedPortfolioID.map(Int64.init))
        case .benchmarks: Place(section: section, item: selectedBenchmarkID.map(Int64.init))
        default: Place(section: section)
        }
    }

    /// Notes where the window is now (ContentView calls it whenever `place` changes): the place before joins the Back
    /// list and the Forward list goes, as in a browser. Another row picked on the same screen within a second of the
    /// last change (arrowing down a table, a screen choosing its first row) updates the place instead of adding one.
    func recordPlace() {
        let now = Visit(place: place, title: title(place))
        guard now.place != historyCurrent?.place else { return }
        let quick = Date().timeIntervalSince(historyStamp) < 1
        historyStamp = Date()
        if let current = historyCurrent, current.place.section == now.place.section, quick {
            historyCurrent = now
            return
        }
        if let previous = historyCurrent {
            backStack.append(previous)
            if backStack.count > 100 { backStack.removeFirst() }
        }
        if !forwardStack.isEmpty { forwardStack.removeAll() }
        historyCurrent = now
    }

    /// The places Back goes to, the nearest first (the ‹ button's menu, Go ▸ History).
    var backHistory: [Visit] {
        _ = historyVersion
        return backStack.reversed()
    }

    /// The places Forward goes to, the nearest first.
    var forwardHistory: [Visit] {
        _ = historyVersion
        return forwardStack.reversed()
    }

    /// Back one place (⌘[, ⌃←, ‹, a mouse's back button), or several (the ‹ button's menu, Go ▸ History).
    func goBack(steps: Int = 1) { travel(back: true, steps: steps) }

    /// Forward one place (⌘], ⌃→, ›, a mouse's forward button), or several.
    func goForward(steps: Int = 1) { travel(back: false, steps: steps) }

    /// Moves through the history like a browser: the places passed go onto the other list.
    private func travel(back: Bool, steps: Int) {
        var target: Visit?
        var moved = 0
        while moved < steps, let visit = back ? backStack.popLast() : forwardStack.popLast() {
            if let current = historyCurrent {
                if back { forwardStack.append(current) } else { backStack.append(current) }
            }
            historyCurrent = visit
            target = visit
            moved += 1
        }
        guard let place = target?.place else { return NSSound.beep() }
        historyStamp = Date()
        switch place.section {
        case .securities: if let id = place.item { selectedSecurityID = id }
        case .portfolios: if let id = place.item { selectedPortfolioID = Int(id) }
        case .benchmarks: if let id = place.item { selectedBenchmarkID = Int(id) }
        default: break
        }
        section = place.section
    }

    /// A place in the history menus: the screen, and what it showed.
    func title(_ place: Place) -> String {
        guard let item = place.item else { return place.section.rawValue }
        let shown: String? = switch place.section {
        case .securities:
            results.first { $0.id == item }.map { [$0.ticker, $0.name].filter { !$0.isEmpty }.joined(separator: " ") }
                ?? (detail?.security.id == item ? detail.map { [$0.security.ticker, $0.security.name].filter { !$0.isEmpty }.joined(separator: " ") } : nil)
        case .portfolios: portfolios.first { Int64($0.id) == item }.map { "\($0.code) \($0.name)" }
        case .benchmarks: benchmarks.first { Int64($0.id) == item }.map { "\($0.code) \($0.name)" }
        default: nil
        }
        return "\(place.section.rawValue) — \(shown ?? "#\(item)")"
    }
}

// MARK: - The toolbar's ‹ and ›

/// ‹ and ›: click to go back or forward a place; hold for the places before or after (as in Safari and MxAcctMGR).
struct BackForwardButtons: ToolbarContent {
    @Bindable var store: SRMStore

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Menu {
                ForEach(Array(store.backHistory.prefix(15).enumerated()), id: \.offset) { i, visit in
                    Button { store.goBack(steps: i + 1) } label: { Label(visit.title, systemImage: visit.place.section.systemImage) }
                }
            } label: {
                Label("Back", systemImage: "chevron.left")
            } primaryAction: {
                store.goBack()
            }
            .menuIndicator(.hidden)
            .disabled(!store.canGoBack)
            .help(store.backHistory.first.map { "Back to \($0.title) (⌘[ or ⌃←) — hold for the places before" } ?? "Back (⌘[ or ⌃←)")
            .quickHelp("Back", "Back to the place before, as in a browser: the screen you came from, with the security, portfolio or benchmark it showed. Hold the button for the places before it; Go ▸ History lists them too. Also ⌃←, or a mouse's back button.", shortcut: "⌘[", symbol: "chevron.left")
            Menu {
                ForEach(Array(store.forwardHistory.prefix(15).enumerated()), id: \.offset) { i, visit in
                    Button { store.goForward(steps: i + 1) } label: { Label(visit.title, systemImage: visit.place.section.systemImage) }
                }
            } label: {
                Label("Forward", systemImage: "chevron.right")
            } primaryAction: {
                store.goForward()
            }
            .menuIndicator(.hidden)
            .disabled(!store.canGoForward)
            .help(store.forwardHistory.first.map { "Forward to \($0.title) (⌘] or ⌃→) — hold for the places after" } ?? "Forward (⌘] or ⌃→)")
            .quickHelp("Forward", "Forward again to where you went Back from. Hold the button for the places after it. Also ⌃→, or a mouse's forward button.", shortcut: "⌘]", symbol: "chevron.right")
        }
    }
}

// MARK: - The Go menu

/// Go ▸ Back, Forward and History.
struct GoCommands: Commands {
    let store: SRMStore

    var body: some Commands {
        CommandMenu("Go") {
            GoHistoryItems(store: store)
        }
    }
}

/// A view of their own, so the items follow the history as it changes.
private struct GoHistoryItems: View {
    let store: SRMStore

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
            ForEach(Array(forward.enumerated()).reversed(), id: \.offset) { i, visit in
                Button(visit.title) { store.goForward(steps: i + 1) }
            }
            Toggle(store.title(store.place), isOn: .constant(true)).disabled(true)
            ForEach(Array(back.enumerated()), id: \.offset) { i, visit in
                Button(visit.title) { store.goBack(steps: i + 1) }
            }
        }
    }
}

// MARK: - ⌃← ⌃→ and the mouse's buttons

enum NavigationKeys {
    /// ⌃← / ⌃→ and a mouse's back / forward buttons in the main window (⌘[ / ⌘] are the Go menu's).
    @MainActor static func install(_ store: SRMStore) {
        guard !installed else { return }
        installed = true
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .otherMouseDown]) { event in
            MainActor.assumeIsolated { handle(event, store) } ? nil : event
        }
    }

    @MainActor private static var installed = false

    /// The main window — not a sheet, a panel or a hover card.
    @MainActor static func isMainWindow(_ window: NSWindow?) -> Bool {
        guard let window, window.sheetParent == nil, window.attachedSheet == nil else { return false }
        return window.identifier?.rawValue.hasPrefix("main") == true
    }

    @MainActor static func handle(_ event: NSEvent, _ store: SRMStore) -> Bool {
        switch event.type {
        case .keyDown:
            // Control and an arrow alone, while no text has the keyboard (there ⌃← / ⌃→ move the insertion point;
            // that includes Data Refresh's Activity console).
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
            // Buttons 4 and 5 of a mouse (numbered 3 and 4 from 0): back and forward, as in browsers.
            let window = event.window ?? NSApp.window(withWindowNumber: NSWindow.windowNumber(at: event.locationInWindow, belowWindowWithWindowNumber: 0))
            guard isMainWindow(window), event.buttonNumber == 3 || event.buttonNumber == 4 else { return false }
            if event.buttonNumber == 3 { store.goBack() } else { store.goForward() }
            return true
        default:
            return false
        }
    }
}
