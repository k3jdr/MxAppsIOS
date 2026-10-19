//
//  MainView.swift
//  MxNoteONE
//
//  The main window: notebooks and sections on the left, the section's
//  pages in the middle, and the page with its ribbon on the right.
//

import SwiftUI

struct MainView: View {
    @Bindable private var store = NotebookStore.shared
    @State private var visibility: NavigationSplitViewVisibility = .all
    @FocusState private var searchFocused: Bool
    @Bindable private var quickHelp = QuickHelp.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 236, max: 360)
                // Quick Help: what's under the pointer, at the bottom of the sidebar.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if quickHelp.visible { QuickHelpPanel() }
                }
        } content: {
            PageListView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 420)
        } detail: {
            PageDetailView()
        }
        .searchable(text: $store.searchText, placement: .sidebar, prompt: "Search All Notebooks")
        .searchFocused($searchFocused)
        .onChange(of: store.focusSearchRequest) {
            if store.showFullPage { store.showFullPage = false }
            searchFocused = true
        }
        .onChange(of: store.showFullPage) { _, full in
            visibility = full ? .detailOnly : .all
            FullPageView.collapseColumns(full)
        }
        .onChange(of: visibility) { _, newValue in
            // Showing the sidebar again (its toolbar button, or dragging a column out) ends Full Page View.
            if newValue == .all, store.showFullPage, !FullPageView.changing { store.showFullPage = false }
        }
        // Nothing of the notebooks shows while MxNoteONE is locked.
        .navigationTitle(store.appLocked ? "MxNoteONE" : store.windowTitle)
        .navigationSubtitle(store.appLocked ? "Locked" : store.windowSubtitle)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                // Click to go back or forward a page; hold for the pages before or after (as in Safari).
                Menu {
                    ForEach(Array(store.backHistory.prefix(15).enumerated()), id: \.offset) { i, ref in
                        Button(store.historyTitle(ref)) { store.goBack(steps: i + 1) }
                    }
                } label: {
                    Label("Back", systemImage: "chevron.left")
                } primaryAction: {
                    store.goBack()
                }
                .menuIndicator(.hidden)
                .disabled(!store.canGoBack)
                .help("Back (⌃← or ⌘[) — hold for the pages before")
                Menu {
                    ForEach(Array(store.forwardHistory.prefix(15).enumerated()), id: \.offset) { i, ref in
                        Button(store.historyTitle(ref)) { store.goForward(steps: i + 1) }
                    }
                } label: {
                    Label("Forward", systemImage: "chevron.right")
                } primaryAction: {
                    store.goForward()
                }
                .menuIndicator(.hidden)
                .disabled(!store.canGoForward)
                .help("Forward (⌃→ or ⌘]) — hold for the pages after")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { store.showFullPage.toggle() } label: {
                    Label("Full Page View", systemImage: store.showFullPage
                          ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .help("Full Page View (⌥⌘F)")
            }
        }
        .overlay {
            if store.appLocked { AppLockView() }
        }
        .toolbar(store.appLocked ? .hidden : .automatic, for: .windowToolbar)
        .alert(store.alert?.title ?? "", isPresented: Binding(get: { store.alert != nil },
                                                             set: { if !$0 { store.alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.alert?.message ?? "")
        }
        .sheet(item: $store.sheet) { sheet in
            SheetView(sheet: sheet)
        }
        .task { store.loadLibraryIfNeeded() }
        .onAppear { if QuickHelp.shared.visible { QuickHelp.shared.startTracking() } }
        .onReceive(NotificationCenter.default.publisher(for: .mxOpenScripts)) { _ in openWindow(id: "scripts") }
    }
}

// MARK: - Page

struct PageDetailView: View {
    @Bindable private var store = NotebookStore.shared

    var body: some View {
        let ref = store.currentPageRef
        VStack(spacing: 0) {
            if store.editor.showRibbon {
                RibbonView()
                Divider()
            }
            if store.editor.showFindBar && ref != nil {
                FindBar()
                Divider()
            }
            ZStack {
                PageCanvas(ref: ref, token: store.reloadToken)
                if ref == nil {
                    placeholder
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(nsColor: .windowBackgroundColor))
                }
            }
        }
    }

    @ViewBuilder private var placeholder: some View {
        if let section = store.selectedSection, store.isLocked(section) {
            ContentUnavailableView {
                Label("Section Locked", systemImage: "lock.fill")
            } description: {
                Text("Enter the password in the page list to unlock this section.")
            }
        } else if store.selectedSection != nil {
            ContentUnavailableView {
                Label("No Page", systemImage: "doc.text")
            } description: {
                Text("Add a page to this section to start writing.")
            } actions: {
                Button("Add Page") { store.addPageToCurrentSection() }
            }
        } else {
            ContentUnavailableView {
                Label("No Section Selected", systemImage: "books.vertical")
            } description: {
                Text("Choose a section in the sidebar, or create a notebook.")
            } actions: {
                Button("New Notebook…") { store.sheet = .newNotebook }
            }
        }
    }
}

/// Hosts the AppKit page canvas.
struct PageCanvas: NSViewRepresentable {
    var ref: PageRef?
    var token: Int

    func makeCoordinator() -> CanvasController { CanvasController() }

    func makeNSView(context: Context) -> NSScrollView {
        NotebookStore.shared.canvas = context.coordinator
        return context.coordinator.scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let controller = context.coordinator
        let ref = ref
        let token = token
        DispatchQueue.main.async { controller.load(ref, token: token) }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: CanvasController) {
        coordinator.flush()
    }
}

/// Find on page (⌘F).
struct FindBar: View {
    @Bindable private var editor = NotebookStore.shared.editor
    @FocusState private var focused: Bool

    private var canvas: CanvasController? { NotebookStore.shared.canvas }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find on page", text: $editor.findText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
                .focused($focused)
                .onSubmit { canvas?.findNext() }
                .onChange(of: editor.findText) { canvas?.updateFind() }
            Button { canvas?.findNext(forward: false) } label: { Image(systemName: "chevron.up") }
                .help("Find Previous (⇧⌘G)")
            Button { canvas?.findNext() } label: { Image(systemName: "chevron.down") }
                .help("Find Next (⌘G)")
            Text(editor.findStatus)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Done") { close() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .onAppear {
            focused = true
            canvas?.updateFind()
        }
        .onChange(of: editor.findFocusRequest) { focused = true }
    }

    private func close() {
        canvas?.clearFind()
        editor.findStatus = ""
        editor.showFindBar = false
    }
}

// MARK: - Full Page View

/// Full Page View hides the notebooks and page list. A three-column NavigationSplitView doesn't collapse its
/// columns for .detailOnly on macOS, so the window's split view items are collapsed directly.
enum FullPageView {
    /// True while the columns are being collapsed or shown (their visibility changes aren't the user's).
    private(set) static var changing = false

    static func collapseColumns(_ collapse: Bool) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow, let content = window.contentView,
              let split = splitViewController(in: content) else { return }
        let items = split.splitViewItems.dropLast()
        guard items.contains(where: { $0.isCollapsed != collapse }) else { return }
        changing = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            for item in items { item.animator().isCollapsed = collapse }
        } completionHandler: {
            DispatchQueue.main.async { changing = false }
        }
    }

    /// The split view controller of the window's split view (SwiftUI doesn't add it as a child controller).
    private static func splitViewController(in view: NSView) -> NSSplitViewController? {
        if let split = view as? NSSplitView, let controller = split.delegate as? NSSplitViewController,
           controller.splitViewItems.count == 3 {
            return controller
        }
        for subview in view.subviews {
            if let found = splitViewController(in: subview) { return found }
        }
        return nil
    }
}

// MARK: - App lock

/// Covers MxNoteONE until Touch ID / an Apple Watch / the Mac password confirms it's you.
struct AppLockView: View {
    private var store: NotebookStore { .shared }

    var body: some View {
        ZStack {
            Rectangle().fill(.background)
            VStack(spacing: 16) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("MxNoteONE is locked").font(.title2.weight(.semibold))
                Button {
                    store.unlockApp()
                } label: {
                    Label("Unlock with \(DeviceUnlock.methodName)", systemImage: DeviceUnlock.symbol)
                        .padding(.horizontal, 8)
                }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { store.unlockApp() }
    }
}
