//
//  MainView.swift
//  MxDeskMGR
//
//  Main window: sidebar, the two panes, the transfer panel and the
//  function key bar.
//

import AppKit
import SwiftUI

struct MainView: View {
    @State private var workspace = Workspace.restored()
    @Environment(\.openWindow) private var openWindow
    private var settings = AppSettings.shared

    var body: some View {
        NavigationSplitView {
            SidebarView(workspace: workspace)
                .navigationSplitViewColumnWidth(min: 150, ideal: 190, max: 320)
        } detail: {
            VStack(spacing: 0) {
                HSplitView {
                    PaneView(workspace: workspace, pane: workspace.left)
                        .frame(minWidth: 300, maxWidth: .infinity)
                    PaneView(workspace: workspace, pane: workspace.right)
                        .frame(minWidth: 300, maxWidth: .infinity)
                }
                TransferPanel()
                if settings.showFunctionKeyBar {
                    Divider()
                    FunctionKeyBar(workspace: workspace)
                }
            }
        }
        .navigationTitle(workspace.activeTab.title)
        .navigationSubtitle(workspace.activeTab.url.path)
        .toolbar { MainToolbar(workspace: workspace) }
        .focusedSceneValue(\.workspace, workspace)
        .sheet(item: $workspace.sheet) { sheet in
            WorkspaceSheetView(workspace: workspace, sheet: sheet)
        }
        .background(WindowReader(workspace: workspace))
        .onAppear {
            workspace.openWindow = openWindow
            Workspace.current = workspace
        }
        .onChange(of: workspace.sessionSignature) {
            workspace.saveSession()
        }
        .frame(minWidth: 820, minHeight: 420)
    }
}

private struct MainToolbar: ToolbarContent {
    let workspace: Workspace
    private var settings = AppSettings.shared

    init(workspace: Workspace) { self.workspace = workspace }

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { workspace.activePane.newTab() } label: { Label("New Tab", systemImage: "plus.square.on.square") }
                .help("New Tab (⌘T)")
            Button { workspace.swapPanes() } label: { Label("Swap Panes", systemImage: "arrow.left.arrow.right") }
                .help("Swap Panes (⌘U)")
            Button { workspace.mirrorToOtherPane() } label: { Label("Same Folder", systemImage: "equal.square") }
                .help("Show this folder in the other pane")
            Toggle(isOn: Binding(get: { settings.showHidden }, set: { settings.showHidden = $0 })) {
                Label("Hidden Files", systemImage: settings.showHidden ? "eye" : "eye.slash")
            }
            .help("Show Hidden Files (⌘⇧.)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { workspace.search() } label: { Label("Find", systemImage: "magnifyingglass") }
                .help("Find Files (⌘F)")
            Button { workspace.multiRename() } label: { Label("Multi-Rename", systemImage: "character.cursor.ibeam") }
                .help("Multi-Rename (⌃M)")
            Button { workspace.compareFolders() } label: { Label("Compare", systemImage: "rectangle.split.2x1") }
                .help("Select differences between the panes")
            Button { workspace.synchronizeFolders() } label: { Label("Synchronize", systemImage: "arrow.triangle.2.circlepath") }
                .help("Synchronize Folders…")
            Button { workspace.openTerminal() } label: { Label("Terminal", systemImage: "terminal") }
                .help("Open Terminal Here (⌥⌘T)")
            Button { workspace.sheet = .connect(prefill: "") } label: { Label("Connect", systemImage: "network") }
                .help("Connect to Server (⌘K)")
        }
    }
}

/// Bottom row of Total Commander style function key buttons.
private struct FunctionKeyBar: View {
    let workspace: Workspace

    var body: some View {
        HStack(spacing: 0) {
            key("F2", "Rename") { workspace.rename() }
            key("F3", "View") { workspace.view() }
            key("F4", "Edit") { workspace.edit() }
            key("F5", "Copy") { workspace.copyOrMoveToOtherPane(move: false) }
            key("F6", "Move") { workspace.copyOrMoveToOtherPane(move: true) }
            key("F7", "New Folder") { workspace.newFolder() }
            key("F8", "Trash") { workspace.moveToTrash() }
            key("⌥F7", "Find") { workspace.search() }
        }
        .padding(.vertical, 3)
    }

    private func key(_ name: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(name).fontWeight(.semibold).foregroundStyle(.secondary)
                Text(title)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .overlay(alignment: .trailing) { Divider().frame(height: 14) }
    }
}

/// Running and recently finished file operations.
private struct TransferPanel: View {
    private var manager = TransferManager.shared

    var body: some View {
        if !manager.jobs.isEmpty {
            VStack(spacing: 0) {
                Divider()
                ForEach(manager.jobs) { job in
                    JobRow(job: job)
                    Divider()
                }
            }
            .background(.bar)
        }
    }
}

private struct JobRow: View {
    let job: TransferJob
    @State private var showErrors = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(job.title).fontWeight(.medium)
                Text(job.detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                switch job.state {
                case .running:
                    Button("Stop", systemImage: "stop.circle") { job.cancel() }
                        .labelStyle(.iconOnly).buttonStyle(.borderless).help("Stop")
                case .finished, .cancelled:
                    if !job.errors.isEmpty {
                        Button("\(Fmt.count(job.errors.count, "problem"))") { showErrors.toggle() }
                            .buttonStyle(.link)
                    }
                    Text(job.state == .cancelled ? "Stopped" : "Done").foregroundStyle(.secondary)
                    Button("Dismiss", systemImage: "xmark.circle") { TransferManager.shared.dismiss(job) }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                }
            }
            if job.state == .running {
                if let fraction = job.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
            if showErrors {
                ScrollView {
                    Text(job.errors.joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 90)
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}

/// Gives the workspace its NSWindow and makes it `Workspace.current` when the window becomes key.
private struct WindowReader: NSViewRepresentable {
    let workspace: Workspace

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.workspace = workspace
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.workspace = workspace
    }

    final class ReaderView: NSView {
        weak var workspace: Workspace?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            workspace?.window = window
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                                              object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if let workspace = self?.workspace { Workspace.current = workspace }
                }
            }
        }
    }
}
