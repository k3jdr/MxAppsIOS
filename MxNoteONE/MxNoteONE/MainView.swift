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

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 236, max: 360)
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
            withAnimation { visibility = full ? .detailOnly : .all }
        }
        .onChange(of: visibility) { _, newValue in
            if newValue != .detailOnly, store.showFullPage { store.showFullPage = false }
        }
        .navigationTitle(store.windowTitle)
        .navigationSubtitle(store.windowSubtitle)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { store.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                    .disabled(!store.canGoBack)
                    .help("Back (⌘[)")
                Button { store.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                    .disabled(!store.canGoForward)
                    .help("Forward (⌘])")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { store.showFullPage.toggle() } label: {
                    Label("Full Page View", systemImage: store.showFullPage
                          ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .help("Full Page View (⌥⌘F)")
            }
        }
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
