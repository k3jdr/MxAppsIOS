//
//  RibbonLayout.swift
//  MxNoteONE
//
//  The ribbon fits the window: its sections wrap onto more rows instead of
//  running off the side, and each section can be shown in the ribbon,
//  collapsed to one button (its tools in a popover), floated in a palette
//  window of its own (dockable: closing the palette puts it back), or hidden.
//  View ▸ Toolbar (and the ••• button by the ribbon tabs, or right-clicking a
//  section's name) arranges them; Compact makes every section smaller.
//  The arrangement is remembered.
//

import AppKit
import SwiftUI

enum RibbonSectionState: String, CaseIterable, Identifiable, Codable {
    case docked, collapsed, floating, hidden
    var id: String { rawValue }
    var title: String {
        switch self {
        case .docked: "In the Toolbar"
        case .collapsed: "Collapsed to a Button"
        case .floating: "Floating Palette"
        case .hidden: "Hidden"
        }
    }
}

@MainActor
@Observable
final class RibbonLayout {
    static let shared = RibbonLayout()

    private static let statesKey = "ribbonSections", wrapKey = "ribbonWrap", compactKey = "ribbonCompact"

    /// Every tab's sections, in order (as the ribbon shows them).
    static let sections: [(RibbonTab, [String])] = [
        (.home, ["Font", "Format", "Paragraph", "Styles", "Tags"]),
        (.insert, ["Tables", "Music", "3D", "Maps", "Files", "Recording", "Links", "Time Stamp", "Pages"]),
        (.draw, ["Diagram", "Selected Diagram", "Editor", "Ink"]),
        (.view, ["Page Setup", "Zoom", "Views"]),
        (.table, ["Automation", "Insert", "Merge", "Delete", "Shading", "Cell Text", "Table"]),
        (.score, ["Notes", "Expression", "Articulation", "Staves", "Transpose", "Lead Sheet", "Bars", "Voice", "Add", "Selected Note", "Chords & Lyrics", "Analysis", "Score"]),
        (.map, ["Search", "Pins", "Link", "Map", "Directions", "View"]),
        (.dbml, ["DBML", "Tables", "Lines", "Notes", "View"]),
    ]

    static func key(_ tab: RibbonTab, _ title: String) -> String { tab.rawValue + "/" + title }

    private(set) var states: [String: RibbonSectionState] = {
        guard let data = UserDefaults.standard.data(forKey: statesKey),
              let saved = try? JSONDecoder().decode([String: RibbonSectionState].self, from: data) else { return [:] }
        return saved
    }()

    /// Sections wrap onto more rows (else the ribbon scrolls sideways).
    var wrap: Bool = UserDefaults.standard.object(forKey: wrapKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(wrap, forKey: Self.wrapKey) }
    }

    /// Smaller sections: no section names, small buttons.
    var compact: Bool = UserDefaults.standard.bool(forKey: compactKey) {
        didSet { UserDefaults.standard.set(compact, forKey: Self.compactKey) }
    }

    func state(_ key: String) -> RibbonSectionState { states[key] ?? .docked }

    func set(_ key: String, _ state: RibbonSectionState) {
        let old = self.state(key)
        guard old != state else { return }
        states[key] = state == .docked ? nil : state
        save()
        if state == .floating { RibbonPalettes.shared.open(key) }
        if old == .floating { RibbonPalettes.shared.close(key) }
    }

    func binding(_ key: String) -> Binding<RibbonSectionState> {
        Binding(get: { self.state(key) }, set: { self.set(key, $0) })
    }

    /// Every section back in the toolbar (palettes closed).
    func showAll(in tab: RibbonTab? = nil) {
        for (t, titles) in Self.sections where tab == nil || t == tab {
            for title in titles { set(Self.key(t, title), .docked) }
        }
    }

    func collapseAll(in tab: RibbonTab) {
        for title in Self.sections.first(where: { $0.0 == tab })?.1 ?? [] where state(Self.key(tab, title)) == .docked {
            set(Self.key(tab, title), .collapsed)
        }
    }

    func dockAllPalettes() {
        for (key, state) in states where state == .floating { set(key, .docked) }
    }

    var floatingKeys: [String] { states.filter { $0.value == .floating }.map(\.key).sorted() }

    /// Opens the palettes left floating last time.
    func restorePalettes() {
        for key in floatingKeys { RibbonPalettes.shared.open(key) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(states) { UserDefaults.standard.set(data, forKey: Self.statesKey) }
    }
}

// MARK: - Where a section is drawn

private struct RibbonTabKey: EnvironmentKey { static let defaultValue: RibbonTab? = nil }
private struct RibbonPaletteKey: EnvironmentKey { static let defaultValue: String? = nil }

extension EnvironmentValues {
    /// The tab whose sections are being drawn.
    var ribbonTab: RibbonTab? {
        get { self[RibbonTabKey.self] }
        set { self[RibbonTabKey.self] = newValue }
    }

    /// Drawing one section on its own (a floating palette): only that section shows.
    var ribbonPaletteKey: String? {
        get { self[RibbonPaletteKey.self] }
        set { self[RibbonPaletteKey.self] = newValue }
    }
}

/// A tab's sections (for the ribbon and for palettes).
struct RibbonTabContent: View {
    let tab: RibbonTab
    @Bindable private var editor = NotebookStore.shared.editor

    var body: some View {
        switch tab {
        case .home: HomeRibbon()
        case .insert: InsertRibbon()
        case .draw: DrawRibbon()
        case .view: ViewRibbon()
        case .table: TableRibbon()
        case .score: ScoreRibbon()
        case .map: MapRibbon()
        case .dbml: DBMLRibbon()
        }
    }
}

// MARK: - Wrapping

/// Lays sections out left to right, starting a new row when one doesn't fit.
struct RibbonFlow: Layout {
    var spacing: CGFloat = 6
    var rowSpacing: CGFloat = 4

    private func rows(_ subviews: Subviews, width: CGFloat) -> [[(index: Int, size: CGSize)]] {
        var rows: [[(Int, CGSize)]] = [[]]
        var x: CGFloat = 0
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if !rows[rows.count - 1].isEmpty, x + size.width > width {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append((i, size))
            x += size.width + spacing
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let all = rows(subviews, width: width)
        let height = all.reduce(0) { $0 + ($1.map(\.size.height).max() ?? 0) } + rowSpacing * CGFloat(max(0, all.count - 1))
        let used = all.map { row in row.reduce(0) { $0 + $1.size.width } + spacing * CGFloat(max(0, row.count - 1)) }.max() ?? 0
        return CGSize(width: width.isFinite ? width : used, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            var x = bounds.minX
            let height = row.map(\.size.height).max() ?? 0
            for item in row {
                subviews[item.index].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += height + rowSpacing
        }
    }
}

// MARK: - The section menu

/// Where a section goes: toolbar, collapsed, palette, hidden.
struct RibbonSectionMenu: View {
    let key: String
    let title: String
    @Bindable private var layout = RibbonLayout.shared

    var body: some View {
        Picker(title, selection: layout.binding(key)) {
            ForEach(RibbonSectionState.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.inline)
    }
}

/// Toolbar options for a tab (the ••• button, and View ▸ Toolbar).
struct RibbonOptionsMenu: View {
    let tab: RibbonTab
    @Bindable private var layout = RibbonLayout.shared
    @Bindable private var editor = NotebookStore.shared.editor

    var body: some View {
        Toggle("Wrap Sections onto More Rows", isOn: $layout.wrap)
        Toggle("Compact Toolbar", isOn: $layout.compact)
        Divider()
        Section("\(tab.rawValue) Sections") {
            ForEach(RibbonLayout.sections.first { $0.0 == tab }?.1 ?? [], id: \.self) { title in
                Menu(title) { RibbonSectionMenu(key: RibbonLayout.key(tab, title), title: title) }
            }
        }
        Divider()
        Button("Collapse All \(tab.rawValue) Sections") { layout.collapseAll(in: tab) }
        Button("Show All \(tab.rawValue) Sections") { layout.showAll(in: tab) }
        if !layout.floatingKeys.isEmpty {
            Button("Dock All Palettes") { layout.dockAllPalettes() }
        }
    }
}

// MARK: - Floating palettes

/// One section floating in a small window of its own; closing it docks the section again.
@MainActor
final class RibbonPalettes: NSObject, NSWindowDelegate {
    static let shared = RibbonPalettes()
    private var panels: [String: NSPanel] = [:]
    private var closing = Set<String>()

    func open(_ key: String) {
        if let panel = panels[key] { panel.orderFront(nil); return }
        let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, let tab = RibbonTab(rawValue: parts[0]) else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
                            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = parts[1]
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let host = NSHostingController(rootView: RibbonPaletteView(tab: tab, key: key))
        host.sizingOptions = .preferredContentSize
        panel.contentViewController = host
        panel.setFrameAutosaveName("RibbonPalette " + key)
        if !panel.setFrameUsingName("RibbonPalette " + key) {
            // Near the top of the main window, a little apart from other palettes.
            if let main = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }) {
                let offset = CGFloat(panels.count) * 24
                panel.setFrameTopLeftPoint(NSPoint(x: main.frame.maxX - 360 - offset, y: main.frame.maxY - 140 - offset))
            } else {
                panel.center()
            }
        }
        panels[key] = panel
        panel.orderFront(nil)
    }

    func close(_ key: String) {
        guard let panel = panels.removeValue(forKey: key) else { return }
        closing.insert(key)
        panel.close()
        closing.remove(key)
    }

    var openKeys: [String] { Array(panels.keys) }

    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel, let key = panels.first(where: { $0.value === panel })?.key ?? closingKey(panel) else { return }
        // Closed with its close button: the section goes back into the toolbar.
        if !closing.contains(key) {
            panels.removeValue(forKey: key)
            RibbonLayout.shared.set(key, .docked)
        }
    }

    private func closingKey(_ panel: NSPanel) -> String? { nil }
}

/// A palette's content: its tab's sections, of which only this one draws.
struct RibbonPaletteView: View {
    let tab: RibbonTab
    let key: String
    @Bindable private var editor = NotebookStore.shared.editor

    private var available: Bool {
        switch tab {
        case .table: editor.tableActive
        case .score: editor.scoreActive
        case .map: editor.mapActive
        case .dbml: editor.dbmlActive
        default: true
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            RibbonTabContent(tab: tab)
        }
        .environment(\.ribbonTab, tab)
        .environment(\.ribbonPaletteKey, key)
        .disabled(!available)
        .opacity(available ? 1 : 0.45)
        .help(available ? "" : (tab == .score ? "Click in a music score to use these" : tab == .map ? "Click a map to use these" : tab == .dbml ? "Click a DBML diagram to use these" : "Click in a table to use these"))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .fixedSize()
    }
}
