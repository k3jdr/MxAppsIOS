//
//  QuickHelp.swift
//  Shared by MxDataHUB, MxJobsWMS, MxDataSQL and MxFileMGR (MXcodeIDE/Shared/QuickHelp; MxDataSQL and MxFileMGR compile only this folder of Shared)
//
//  Quick Help, as in MxNoteONE (and Logic Pro): a panel that describes what's under the pointer — a
//  button, a list, a table cell, a node — in a sentence or two, with its shortcut. With the pointer over
//  nothing it can describe, it tells about what's selected, and then about the screen you're on.
//
//  The panel docks at the bottom of the sidebar (MxDataSQL: of the window), or floats in a small window
//  of its own: its ⧉ button floats it, and closing the floating window docks it again, as MxNoteONE's
//  toolbar palettes do. View ▸ Quick Help (⌥⌘/) shows or hides it; View ▸ Float / Dock Quick Help moves
//  it. Both are remembered, and so is where the floating window was.
//
//  An app tells Quick Help about itself with three view modifiers:
//    .quickHelpScreen(name, screen, selection:)   the screen a window shows and what's selected in it
//    .quickHelpArea(item)                         a list, panel or node, while the pointer is in it
//    .quickHelp(title, detail, shortcut:)         a control, while the pointer is on it
//  and, for AppKit views SwiftUI can't see into (a grid's cells), QuickHelp.shared.describeView.
//

import AppKit
import SwiftUI

nonisolated struct QuickHelpItem: Equatable, Sendable {
    var title: String
    var detail: String
    var shortcut: String? = nil
    var symbol: String = "questionmark.circle"
}

@MainActor
@Observable
final class QuickHelp {
    static let shared = QuickHelp()
    static let visibleKey = "quickHelpVisible", floatingKey = "quickHelpFloating"

    /// Shown unless turned off (bool(forKey:) also reads a `-quickHelpVisible NO` launch argument).
    var visible: Bool = UserDefaults.standard.object(forKey: visibleKey) == nil || UserDefaults.standard.bool(forKey: visibleKey) {
        didSet {
            UserDefaults.standard.set(visible, forKey: Self.visibleKey)
            updateTracking()
            QuickHelpWindow.shared.sync()
        }
    }

    /// In a floating window of its own rather than docked in the main window.
    var floating: Bool = UserDefaults.standard.bool(forKey: floatingKey) {
        didSet {
            UserDefaults.standard.set(floating, forKey: Self.floatingKey)
            QuickHelpWindow.shared.sync()
        }
    }

    /// Docked in the window (shown and not floating).
    var isDocked: Bool { visible && !floating }

    /// A control under the pointer, an AppKit view under it (a grid cell), the areas it's in (innermost
    /// last), what has the keyboard focus, what's selected, and the screen.
    private(set) var tool: QuickHelpItem?
    private(set) var pointer: QuickHelpItem?
    private var areas: [Area] = []
    private(set) var focus: QuickHelpItem?
    private(set) var selection: QuickHelpItem?
    private(set) var screen: QuickHelpItem?
    /// The screen's name, beside "Quick Help".
    private(set) var screenName: String?

    var shown: QuickHelpItem? { tool ?? pointer ?? areas.last?.item ?? focus ?? selection ?? screen }

    private struct Area: Equatable {
        var id: UUID
        var item: QuickHelpItem
    }

    private var toolID: UUID?

    // MARK: Hover (SwiftUI)

    func hover(tool item: QuickHelpItem?, id: UUID, _ inside: Bool) {
        if inside, let item {
            tool = item
            toolID = id
        } else if toolID == id {
            tool = nil
            toolID = nil
        }
    }

    func hover(area item: QuickHelpItem?, id: UUID, _ inside: Bool) {
        if inside, let item {
            if let i = areas.firstIndex(where: { $0.id == id }) {
                areas[i].item = item
            } else {
                areas.append(Area(id: id, item: item))
            }
        } else {
            areas.removeAll { $0.id == id }
        }
    }

    /// The window whose screen and selection show: the last one that was key.
    @ObservationIgnored private var owner: UUID?

    /// A window's screen and selection. `claim` (the window became key) makes it the one shown; otherwise
    /// only the window shown (or the first) updates them, so a window in the back doesn't take over.
    func publish(from window: UUID, claim: Bool, name: String?, screen: QuickHelpItem?, selection: QuickHelpItem?) {
        guard claim || owner == nil || owner == window else { return }
        owner = window
        if screenName != name { screenName = name }
        if self.screen != screen { self.screen = screen }
        if self.selection != selection { self.selection = selection }
    }

    /// The window closed.
    func resign(_ window: UUID) {
        if owner == window { owner = nil }
    }

    // MARK: AppKit views under the pointer

    /// Describes an AppKit view at a point in it (a grid cell, a column header); nil for views it doesn't know.
    /// Set by an app that has such views; the pointer is then tracked while Quick Help shows.
    @ObservationIgnored var describeView: ((NSView, NSPoint) -> QuickHelpItem?)? {
        didSet { updateTracking() }
    }

    /// Describes what has the keyboard focus in a window (the selected grid cell).
    @ObservationIgnored var describeFocus: ((NSResponder) -> QuickHelpItem?)?

    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var keyObserver: Any?
    @ObservationIgnored private var lastCheck = Date.distantPast

    private func updateTracking() {
        if visible, describeView != nil || describeFocus != nil { startTracking() } else { stopTracking() }
    }

    private func startTracking() {
        guard monitor == nil else { return }
        for window in NSApp.windows where !(window is NSPanel) { window.acceptsMouseMovedEvents = true }
        // Document windows opened later get mouse-moved events too.
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                if let window = note.object as? NSWindow, !(window is NSPanel) { window.acceptsMouseMovedEvents = true }
            }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseUp, .keyUp]) { event in
            MainActor.assumeIsolated { QuickHelp.shared.update(event) }
            return event
        }
    }

    private func stopTracking() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        monitor = nil
        keyObserver = nil
        pointer = nil
        focus = nil
    }

    private func update(_ event: NSEvent) {
        if event.type == .mouseMoved, Date().timeIntervalSince(lastCheck) < 0.06 { return }
        lastCheck = Date()
        // The floating Quick Help window itself (an NSPanel) leaves what it shows alone.
        guard let window = event.window, !(window is NSPanel), let content = window.contentView else { return }
        let point = event.locationInWindow
        var found: QuickHelpItem?
        if let describeView {
            // hitTest takes a point in the view's superview (the window's frame view).
            var view = content.hitTest(content.superview?.convert(point, from: nil) ?? point)
            while let v = view, found == nil {
                found = describeView(v, v.convert(point, from: nil))
                view = v.superview
            }
        }
        if pointer != found { pointer = found }
        let focused = window.firstResponder.flatMap { describeFocus?($0) }
        if focus != focused { focus = focused }
    }
}

// MARK: - The panel

struct QuickHelpPanel: View {
    enum Style { case docked, fixedHeight(CGFloat), floating }
    var style: Style = .docked
    @Bindable private var help = QuickHelp.shared

    init(style: Style = .docked) { self.style = style }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let item = help.shown {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: item.symbol).foregroundStyle(Color.accentColor)
                    Text(item.title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                    Spacer(minLength: 0)
                    if let shortcut = item.shortcut {
                        Text(shortcut)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                if !item.detail.isEmpty {
                    if scrolls {
                        ScrollView(.vertical) { detail(item.detail) }
                            .scrollIndicators(.automatic)
                    } else {
                        detail(item.detail)
                    }
                }
            } else {
                Text("Point at a control or at something in the window to see what it does.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: minHeight, maxHeight: maxHeight, alignment: .topLeading)
        .animation(nil, value: help.shown)
    }

    private var header: some View {
        HStack(spacing: 4) {
            // The floating window's title bar already says Quick Help.
            if !isFloating {
                Text("Quick Help").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }
            if let name = help.screenName {
                Text(isFloating ? name : "· " + name).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            Button { help.floating.toggle() } label: {
                Image(systemName: help.floating ? "pip.enter" : "pip.exit").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help(help.floating ? "Dock Quick Help in the window" : "Float Quick Help in a window of its own")
            if !isFloating {
                Button { help.visible = false } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.borderless)
                    .help("Hide Quick Help (⌥⌘/)")
            }
        }
    }

    private func detail(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    private var isFloating: Bool { if case .floating = style { true } else { false } }

    /// A fixed-height dock and the floating window keep their size and scroll a long description.
    private var scrolls: Bool { if case .docked = style { false } else { true } }

    private var minHeight: CGFloat {
        switch style {
        case .docked: 96
        case .fixedHeight(let h): h
        case .floating: 80
        }
    }

    private var maxHeight: CGFloat? {
        switch style {
        case .docked: nil
        case .fixedHeight(let h): h
        case .floating: .infinity
        }
    }
}

/// The docked panel, where an app puts it (bottom of the sidebar); nothing while hidden or floating.
struct QuickHelpDock: View {
    /// Height of Quick Help docked at the bottom of a sidebar.
    static let sidebarHeight: CGFloat = 140

    var height: CGFloat? = nil
    @Bindable private var help = QuickHelp.shared

    init(height: CGFloat? = nil) { self.height = height }

    var body: some View {
        if help.isDocked {
            QuickHelpPanel(style: height.map { .fixedHeight($0) } ?? .docked)
                // The sidebar's list scrolls under the panel: blur it rather than let it show through.
                .background(.regularMaterial)
                .overlay(alignment: .top) { Divider() }
        }
    }
}

extension View {
    /// Quick Help docked at the bottom of this view (a sidebar), as in MxNoteONE. A fixed height that scrolls a long
    /// description: a dock that grew with its text changed the split view column's minimum size whenever Quick Help
    /// changed, and AppKit aborted on the update-constraints loop (MxJobsWMS, 2026-10-18).
    func quickHelpDock(height: CGFloat = QuickHelpDock.sidebarHeight) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) { QuickHelpDock(height: height) }
    }

    /// Quick Help for a control while the pointer is on it. The control keeps its own tooltip.
    func quickHelp(_ title: String, _ detail: String, shortcut: String? = nil, symbol: String = "hand.point.up.left") -> some View {
        modifier(QuickHelpHover(item: QuickHelpItem(title: title, detail: detail, shortcut: shortcut, symbol: symbol), isTool: true))
    }

    /// Quick Help for an area (a list, a panel, a node) while the pointer is in it; an area inside it wins.
    func quickHelpArea(_ item: QuickHelpItem?) -> some View {
        modifier(QuickHelpHover(item: item, isTool: false))
    }

    func quickHelpArea(_ title: String, _ detail: String, shortcut: String? = nil, symbol: String = "rectangle.dashed") -> some View {
        quickHelpArea(QuickHelpItem(title: title, detail: detail, shortcut: shortcut, symbol: symbol))
    }

    /// The screen this window shows and what's selected in it: Quick Help falls back to them when the pointer
    /// is over nothing it can describe. Published when they change and when the window becomes key.
    func quickHelpScreen(_ name: String?, _ screen: QuickHelpItem?, selection: QuickHelpItem? = nil) -> some View {
        modifier(QuickHelpScreen(name: name, screen: screen, selection: selection))
    }
}

private struct QuickHelpHover: ViewModifier {
    var item: QuickHelpItem?
    var isTool: Bool
    @State private var id = UUID()
    @State private var inside = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                inside = hovering
                report(hovering)
            }
            // A label that changes while the pointer is on it (Run → Continue) shows the new text.
            .onChange(of: item) { if inside { report(true) } }
            .onDisappear {
                if inside { report(false) }
                inside = false
            }
    }

    private func report(_ hovering: Bool) {
        if isTool {
            QuickHelp.shared.hover(tool: item, id: id, hovering)
        } else {
            QuickHelp.shared.hover(area: item, id: id, hovering)
        }
    }
}

private struct QuickHelpScreen: ViewModifier {
    var name: String?
    var screen: QuickHelpItem?
    var selection: QuickHelpItem?
    @Environment(\.controlActiveState) private var active
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear {
                publish(claim: active == .key)
                // Quick Help left floating last time floats again.
                QuickHelpWindow.shared.sync()
            }
            .onChange(of: screen) { publish() }
            .onChange(of: selection) { publish() }
            .onChange(of: name) { publish() }
            .onChange(of: active) { if active == .key { publish(claim: true) } }
            .onDisappear { QuickHelp.shared.resign(id) }
    }

    private func publish(claim: Bool = false) {
        QuickHelp.shared.publish(from: id, claim: claim, name: name, screen: screen, selection: selection)
    }
}

// MARK: - Floating

/// Quick Help floating in a small window of its own; closing it docks Quick Help again.
@MainActor
final class QuickHelpWindow: NSObject, NSWindowDelegate {
    static let shared = QuickHelpWindow()
    private static let frameName = "QuickHelpPanel"
    private var panel: NSPanel?
    private var closingInCode = false

    /// Opens or closes the window to match Quick Help's settings (at launch, too).
    func sync() {
        let help = QuickHelp.shared
        if help.visible && help.floating { open() } else { close() }
    }

    private func open() {
        if let panel { panel.orderFront(nil); return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 150),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = "Quick Help"
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.contentMinSize = NSSize(width: 220, height: 90)
        panel.delegate = self
        let host = NSHostingController(rootView: QuickHelpPanel(style: .floating))
        // The window keeps the size it's given; a long description scrolls.
        host.sizingOptions = [.minSize]
        panel.contentViewController = host
        panel.setContentSize(NSSize(width: 300, height: 150))
        panel.setFrameAutosaveName(Self.frameName)
        if !panel.setFrameUsingName(Self.frameName) {
            // Over the bottom left of the main window, where it docks.
            if let main = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }) {
                panel.setFrameOrigin(NSPoint(x: main.frame.minX + 16, y: main.frame.minY + 40))
            } else {
                panel.center()
            }
        }
        self.panel = panel
        panel.orderFront(nil)
    }

    private func close() {
        guard let panel else { return }
        self.panel = nil
        closingInCode = true
        panel.close()
        closingInCode = false
    }

    func windowWillClose(_ notification: Notification) {
        guard !closingInCode else { return }
        // Closed with its close button: Quick Help docks again.
        panel = nil
        QuickHelp.shared.floating = false
    }
}

// MARK: - Menu

/// View ▸ Quick Help (⌥⌘/) and Float / Dock Quick Help.
struct QuickHelpCommands: Commands {
    var body: some Commands {
        CommandGroup(before: .sidebar) {
            QuickHelpMenuItems()
            Divider()
        }
    }
}

private struct QuickHelpMenuItems: View {
    @Bindable private var help = QuickHelp.shared

    var body: some View {
        Toggle("Quick Help", isOn: $help.visible)
            .keyboardShortcut("/", modifiers: [.command, .option])
        Button(help.floating ? "Dock Quick Help" : "Float Quick Help") {
            help.floating.toggle()
            help.visible = true
        }
    }
}
