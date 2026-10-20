//
//  PageListView.swift
//  MxNoteONE
//
//  The middle column: the pages of the selected section (indented
//  subpages, drag to reorder), search results from all notebooks while
//  the search field has text, or the password prompt of a locked section.
//

import SwiftUI

struct PageListView: View {
    @Bindable private var store = NotebookStore.shared

    var body: some View {
        Group {
            if !store.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                SearchResultsView()
            } else if let section = store.selectedSection {
                if store.isLocked(section) {
                    LockedSectionView(ref: section)
                } else {
                    PagesList(section: section)
                }
            } else {
                ContentUnavailableView("No Section Selected", systemImage: "rectangle.stack",
                                       description: Text("Choose a section in the sidebar."))
            }
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("New Page") { store.addPageToCurrentSection() }
                    Button("New Subpage") { store.addPageToCurrentSection(subpage: true) }
                    Divider()
                    Section("Templates") {
                        ForEach(PageTemplate.choices.filter { $0 != .blank }) { template in
                            Button {
                                store.addPageToCurrentSection(template: template)
                            } label: {
                                Label(template.title, systemImage: template.symbol)
                            }
                        }
                    }
                } label: {
                    Label("Add Page", systemImage: "doc.badge.plus")
                } primaryAction: {
                    store.addPageToCurrentSection()
                }
                .help("Add Page (⌘N)")
                .disabled(store.selectedSection == nil || store.selectedSection.map(store.isLocked) == true)
            }
        }
    }
}

struct PagesList: View {
    let section: SectionRef
    @Bindable private var store = NotebookStore.shared

    var body: some View {
        let pages = store.visiblePages(in: section)
        let node = store.node(section)
        // AppKit's table (for dependable drag and drop); its rows are PageRow, with PageMenu on right-click.
        PagesTable(section: section, pages: pages, selected: store.selectedPageID)
        // Right-click the empty space (below the pages, or an empty section) for Add New.
        .background(AddNewArea(section: section))
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(node?.color.color ?? .gray)
                    .frame(width: 5, height: 18)
                Text(node?.name ?? "")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text("\(store.pages(in: section)?.count ?? 0) pages")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .overlay {
            if pages.isEmpty {
                ContentUnavailableView {
                    Label("No Pages", systemImage: "doc")
                } actions: {
                    Button("Add Page") { store.addPageToCurrentSection() }
                }
            }
        }
    }
}

/// Right-click in the empty part of the pages list: Add New (a page, blank or from a template, a subpage, a
/// section or a section group). SwiftUI's list menus don't reach the space below the rows, so this watches
/// right-clicks in the pages column and shows the menu when one isn't on a page.
struct AddNewArea: NSViewRepresentable {
    let section: SectionRef

    func makeNSView(context: Context) -> AddNewAreaView {
        let view = AddNewAreaView()
        view.section = section
        return view
    }

    func updateNSView(_ view: AddNewAreaView, context: Context) {
        view.section = section
    }
}

final class AddNewAreaView: NSView {
    var section: SectionRef?
    private var monitor: Any?

    #if DEBUG
    /// Self-tests: receives the menu instead of it popping up.
    nonisolated(unsafe) static var testMenuHandler: ((NSMenu) -> Void)?
    #endif

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .leftMouseDown, !event.modifierFlags.contains(.control) { return event }
            return self.handle(event) ? nil : event
        }
    }

    override func removeFromSuperview() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        super.removeFromSuperview()
    }

    /// Shows Add New for a right-click in the pages column that isn't on a page.
    func handle(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, let section else { return false }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return false }
        // On a page row: the row's own menu.
        if let content = window.contentView, let hit = content.hitTest(content.convert(event.locationInWindow, from: nil)) {
            var view: NSView? = hit
            while let v = view, !(v is NSTableView) { view = v.superview }
            if let table = view as? NSTableView, table.row(at: table.convert(event.locationInWindow, from: nil)) >= 0 { return false }
        }
        let menu = Self.menu(for: section)
        #if DEBUG
        if let handler = Self.testMenuHandler { handler(menu); return true }
        #endif
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        return true
    }

    static func menu(for section: SectionRef) -> NSMenu {
        let store = NotebookStore.shared
        let menu = NSMenu(title: "Add New")
        menu.autoenablesItems = false
        menu.addItem(ClosureMenuItem("New Page") { store.addPageToCurrentSection() })
        let subpage = ClosureMenuItem("New Subpage") { store.addPageToCurrentSection(subpage: true) }
        subpage.isEnabled = !(store.pages(in: section)?.isEmpty ?? true)
        menu.addItem(subpage)
        let templates = NSMenuItem(title: "New Page from Template", action: nil, keyEquivalent: "")
        let list = NSMenu()
        for template in PageTemplate.choices where template != .blank {
            let item = ClosureMenuItem(template.title) { store.addPageToCurrentSection(template: template) }
            item.image = NSImage(systemSymbolName: template.symbol, accessibilityDescription: nil)
            list.addItem(item)
        }
        templates.submenu = list
        menu.addItem(templates)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("New Section") { _ = store.addSection(to: section.notebookID) })
        menu.addItem(ClosureMenuItem("New Section Group") { store.addSectionGroup(to: section.notebookID) })
        return menu
    }
}

struct PageRow: View {
    let meta: PageMeta
    let ref: PageRef
    let hasSubpages: Bool
    @Bindable private var store = NotebookStore.shared

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if hasSubpages {
                Button {
                    store.toggleCollapsed(ref)
                } label: {
                    Image(systemName: meta.collapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            } else {
                Color.clear.frame(width: 12, height: 1)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(meta.displayTitle)
                    .fontWeight(meta.level == 0 ? .medium : .regular)
                    .foregroundStyle(meta.title.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if meta.tags.contains(where: { $0.kind == .todo && !$0.done }) {
                Spacer(minLength: 0)
                Image(systemName: "checkmark.square")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Has unfinished To Do items")
            }
        }
        .padding(.leading, CGFloat(meta.level) * 16)
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        let date = meta.modified.formatted(date: .abbreviated, time: .omitted)
        let firstLine = meta.plainText.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return firstLine.isEmpty ? date : "\(date)  \(firstLine)"
    }
}

struct PageMenu: View {
    let ref: PageRef
    let meta: PageMeta
    let hasSubpages: Bool
    @Bindable private var store = NotebookStore.shared

    var body: some View {
        Button("New Page") { store.addPage(in: ref.section, after: ref.pageID) }
        Button("New Subpage") { store.addPage(in: ref.section, after: ref.pageID, subpage: true) }
        Divider()
        Button("Make Subpage") { store.changeLevel(ref, by: 1) }
        Button("Promote Subpage") { store.changeLevel(ref, by: -1) }
            .disabled(meta.level == 0)
        if hasSubpages {
            Button(meta.collapsed ? "Expand Subpages" : "Collapse Subpages") { store.toggleCollapsed(ref) }
        }
        Divider()
        Button("Move or Copy…") { store.sheet = .movePage(ref) }
        Button("Duplicate Page") { store.duplicatePage(ref) }
        Button("Copy Link to this Page") { store.copyLink(ref) }
        Divider()
        Button("Export as PDF…") { PageExporter.exportPDF([ref], suggestedName: meta.displayTitle) }
        Button("Export as Markdown…") { PageExporter.exportMarkdown(ref) }
        Button("Print…") { PageExporter.printPage(ref) }
        Divider()
        Button("Delete Page", role: .destructive) { store.deletePage(ref) }
    }
}

struct SearchResultsView: View {
    @Bindable private var store = NotebookStore.shared

    var body: some View {
        let query = store.searchText
        let hits = store.search(query)
        let firstWord = query.split(whereSeparator: \.isWhitespace).first.map(String.init)
        List {
            ForEach(hits) { hit in
                Button {
                    store.open(hit.ref, find: firstWord)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(hit.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(hit.location)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if !hit.snippet.isEmpty {
                            Text(hit.snippet)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(store.currentPageRef == hit.ref ? Color.accentColor.opacity(0.18) : Color.clear)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Text(hits.count == 1 ? "1 page in all notebooks" : "\(hits.count) pages in all notebooks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
        .overlay {
            if hits.isEmpty { ContentUnavailableView.search(text: query) }
        }
    }
}

struct LockedSectionView: View {
    let ref: SectionRef
    @Bindable private var store = NotebookStore.shared
    @State private var password = ""
    @State private var failed = false
    @State private var rememberWithDevice = true

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("This section is password protected")
                .font(.headline)
                .multilineTextAlignment(.center)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .onSubmit(unlock)
            if failed {
                Text("The password is not correct.")
                    .font(.caption)
                    .foregroundStyle(.red)
                if let hint = store.node(ref)?.protection?.hint, !hint.isEmpty {
                    Text("Hint: \(hint)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Button("Unlock", action: unlock)
            if DeviceUnlock.isAvailable {
                if store.canUnlockWithDevice(ref) {
                    Divider().frame(width: 200)
                    Button {
                        store.unlockWithDevice(ref)
                    } label: {
                        Label("Unlock with \(DeviceUnlock.methodName)", systemImage: DeviceUnlock.symbol)
                    }
                    .controlSize(.large)
                } else {
                    Toggle("Use \(DeviceUnlock.methodName) to unlock next time", isOn: $rememberWithDevice)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: ref) {
            password = ""
            failed = false
        }
    }

    private func unlock() {
        failed = !store.unlock(ref, password: password,
                                rememberWithDevice: rememberWithDevice && DeviceUnlock.isAvailable && !store.canUnlockWithDevice(ref))
        if !failed { password = "" }
    }
}
