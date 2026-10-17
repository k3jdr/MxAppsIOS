//
//  PaneView.swift
//  MxFileMGR
//
//  One side of the window: tab strip, navigation bar with breadcrumb path
//  and quick filter, the file list and a status line.
//

import AppKit
import SwiftUI

struct PaneView: View {
    let workspace: Workspace
    let pane: Pane

    var body: some View {
        let tab = pane.active
        let isActive = workspace.activeSide == pane.side
        VStack(spacing: 0) {
            if pane.tabs.count > 1 {
                TabStrip(workspace: workspace, pane: pane)
                Divider()
            }
            PaneHeader(workspace: workspace, side: pane.side, tab: tab)
            Divider()
            ZStack {
                FileListView(workspace: workspace, side: pane.side, tab: tab,
                             version: tab.version, selection: tab.selection,
                             isActive: isActive, focusToken: workspace.focusToken)
                if let error = tab.error {
                    ContentUnavailableView("Can't Show Folder", systemImage: "exclamationmark.triangle",
                                           description: Text(error))
                        .background(.background)
                }
            }
            Divider()
            StatusLine(tab: tab)
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(isActive ? Color.accentColor : Color.clear)
                .frame(height: 2)
        }
    }
}

private struct TabStrip: View {
    let workspace: Workspace
    let pane: Pane

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(pane.tabs.enumerated()), id: \.element.id) { index, tab in
                    let selected = index == pane.activeIndex
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        Text(tab.title)
                            .lineLimit(1)
                        Button {
                            pane.closeTab(at: index)
                        } label: {
                            Image(systemName: "xmark").font(.caption2)
                        }
                        .buttonStyle(.borderless)
                        .help("Close Tab")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        pane.activeIndex = index
                        workspace.focus(pane.side)
                    }
                    .help(tab.url.path)
                }
                Button {
                    pane.newTab()
                    workspace.focus(pane.side)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New Tab")
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
        }
        .font(.callout)
        .quickHelpArea(FileHelp.tabs)
    }
}

private struct PaneHeader: View {
    let workspace: Workspace
    let side: Side
    @Bindable var tab: BrowserTab

    var body: some View {
        HStack(spacing: 6) {
            Button { tab.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!tab.canGoBack).help("Back")
                .quickHelp("Back", "Goes back to the folder this tab showed before.", shortcut: "⌘[")
            Button { tab.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!tab.canGoForward).help("Forward")
                .quickHelp("Forward", "Goes forward again after Back.", shortcut: "⌘]")
            Button { tab.goUp() } label: { Image(systemName: "arrow.up") }
                .disabled(tab.parentURL == nil).help("Enclosing Folder")
                .quickHelp("Enclosing Folder", "Goes up to the folder that contains this one.", shortcut: "⌘↑")
            PathBar(url: tab.url) { url in
                tab.navigate(to: url)
                workspace.focus(side)
            }
            .contextMenu {
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tab.url.path, forType: .string)
                }
                Button("Go to Folder…") {
                    workspace.focus(side)
                    workspace.goToFolderPrompt()
                }
            }
            .quickHelpArea(FileHelp.pathBar)
            if tab.isLoading { ProgressView().controlSize(.small) }
            TextField("Filter", text: $tab.filterText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 130)
                .onSubmit { workspace.focus(side) }
                .onExitCommand {
                    tab.filterText = ""
                    workspace.focus(side)
                }
                .help("Show only items whose name contains this text (or matches wildcards such as *.txt)")
                .quickHelp(FileHelp.filter.title, FileHelp.filter.detail, shortcut: "⎋")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }
}

/// Clickable breadcrumb of the folder's path.
private struct PathBar: View {
    let url: URL
    let navigate: (URL) -> Void

    private var components: [(String, URL)] {
        var result: [(String, URL)] = []
        var current = url.standardizedFileURL
        while true {
            let name = BrowserTab.displayName(of: current)
            result.insert((name, current), at: 0)
            if current.path == "/" { break }
            current = current.deletingLastPathComponent()
        }
        return result
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(components.enumerated()), id: \.offset) { index, part in
                    if index > 0 {
                        Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
                    }
                    Button(part.0) { navigate(part.1) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(index == components.count - 1 ? .primary : .secondary)
                        .fontWeight(index == components.count - 1 ? .semibold : .regular)
                        .lineLimit(1)
                }
            }
        }
        .defaultScrollAnchor(.trailing)
        .frame(maxWidth: .infinity)
    }
}

private struct StatusLine: View {
    let tab: BrowserTab

    var body: some View {
        let items = tab.items
        let marked = tab.selectedItems
        let markedBytes = marked.reduce(Int64(0)) { $0 + ($1.isDirectory ? (tab.folderSizes[$1.url] ?? 0) : $1.size) }
        let totalBytes = items.reduce(Int64(0)) { $0 + ($1.isDirectory ? 0 : $1.size) }
        HStack {
            if marked.isEmpty {
                Text("\(Fmt.count(items.count, "item")), \(Fmt.size(totalBytes)) in files")
            } else {
                Text("\(marked.count) of \(Fmt.count(items.count, "item")) selected, \(Fmt.size(markedBytes))")
            }
            if !tab.filterText.isEmpty {
                Text("(filtered)").foregroundStyle(.orange)
            }
            Spacer()
            if let free = freeSpace {
                Text("\(Fmt.size(free)) available")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .quickHelpArea(FileHelp.status)
    }

    private var freeSpace: Int64? {
        let url = URL(fileURLWithPath: tab.url.path)
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
