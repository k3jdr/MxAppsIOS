//
//  MainCommands.swift
//  MxFileMGR
//
//  Menu bar. Total Commander function keys (F2–F8) sit alongside the usual
//  Mac shortcuts; on a Mac keyboard press fn with the F-key unless
//  "Use F1, F2, etc. keys as standard function keys" is on.
//

import AppKit
import SwiftUI

extension KeyEquivalent {
    /// The function key Fn as a menu key equivalent.
    static func f(_ n: Int) -> KeyEquivalent {
        KeyEquivalent(Character(UnicodeScalar(UInt32(NSF1FunctionKey + n - 1))!))
    }
}

struct MainCommands: Commands {
    @FocusedValue(\.workspace) private var workspace
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            item("New Tab", "t") { $0.activePane.newTab() }
            item("Close Tab", "w", [.control]) { $0.activePane.closeTab(at: $0.activePane.activeIndex) }
            Divider()
            item("New Folder…", .f(7), []) { $0.newFolder() }
            item("New File…", .f(4), [.shift]) { $0.newFile() }
            Divider()
            item("Open", "o") { $0.openSelection() }
            item("Open in New Tab", "o", [.command, .shift]) { $0.openInNewTab() }
            item("Show Package Contents") { $0.showPackageContents() }
            Button("Quick Look") { NSApp.sendAction(#selector(FileTableView.toggleQuickLook(_:)), to: nil, from: nil) }
                .keyboardShortcut("y")
            item("View", .f(3), []) { $0.view() }
            item("Edit", .f(4), []) { $0.edit() }
            Divider()
            item("Rename…", .f(2), []) { $0.rename() }
            item("Copy to Other Pane…", .f(5), []) { $0.copyOrMoveToOtherPane(move: false) }
            item("Move to Other Pane…", .f(6), []) { $0.copyOrMoveToOtherPane(move: true) }
            item("Duplicate", "d") { $0.duplicate() }
            item("Compress") { $0.compress() }
            item("Extract to Other Pane", .f(9), [.option]) { $0.extract() }
            Divider()
            item("Move to Trash", .delete) { $0.moveToTrash() }
            item("Delete Immediately…", .delete, [.command, .option]) { $0.deleteImmediately() }
            Divider()
            item("Properties…", "i") { $0.showProperties() }
            item("Show in Finder", "r", [.command, .option]) { $0.revealInFinder() }
            item("Add to Favorites", "d", [.control]) { $0.addToFavorites() }
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Show Clipboard") { openWindow(id: "clipboard") }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            item("Move Item Here", "v", [.command, .option]) { $0.pasteFromPasteboard(move: true) }
            item("Copy Path", "c", [.command, .option]) { $0.copyPaths() }
            Divider()
            item("Select Group…", "=") { $0.sheet = .pattern(select: true) }
            item("Deselect Group…", "-") { $0.sheet = .pattern(select: false) }
            item("Invert Selection", "i", [.command, .shift]) { $0.invertSelection() }
        }

        CommandGroup(after: .sidebar) {
            Toggle("Show Hidden Files", isOn: Binding(
                get: { AppSettings.shared.showHidden },
                set: { AppSettings.shared.showHidden = $0 }))
                .keyboardShortcut(".", modifiers: [.command, .shift])
            Toggle("Folders First", isOn: Binding(
                get: { AppSettings.shared.foldersFirst },
                set: { AppSettings.shared.foldersFirst = $0 }))
            Toggle("Function Key Bar", isOn: Binding(
                get: { AppSettings.shared.showFunctionKeyBar },
                set: { AppSettings.shared.showFunctionKeyBar = $0 }))
            Divider()
            Menu("Sort By") {
                item("Name", "1", [.command, .control]) { $0.sort(by: .name) }
                item("Extension", "2", [.command, .control]) { $0.sort(by: .ext) }
                item("Size", "3", [.command, .control]) { $0.sort(by: .size) }
                item("Date Modified", "4", [.command, .control]) { $0.sort(by: .modified) }
                item("Kind", "5", [.command, .control]) { $0.sort(by: .kind) }
            }
            item("Calculate Folder Sizes", "s", [.command, .option]) { $0.calculateFolderSizes() }
            item("Refresh", "r") { $0.activeTab.reload() }
            Divider()
        }

        CommandMenu("Go") {
            item("Back", "[") { $0.activeTab.goBack() }
            item("Forward", "]") { $0.activeTab.goForward() }
            item("Enclosing Folder", .upArrow) { $0.activeTab.goUp() }
            Divider()
            item("Home", "h", [.command, .shift]) { $0.go(to: FileManager.default.homeDirectoryForCurrentUser) }
            item("Desktop", "d", [.command, .shift]) { $0.go(to: .desktopDirectory) }
            item("Documents", "o", [.command, .option]) { $0.go(to: .documentsDirectory) }
            item("Downloads", "l", [.command, .option]) { $0.go(to: .downloadsDirectory) }
            item("Applications", "a", [.command, .shift]) { $0.go(to: URL(fileURLWithPath: "/Applications")) }
            item("Computer", "c", [.command, .shift]) { $0.go(to: URL(fileURLWithPath: "/")) }
            item("iCloud Drive") { workspace in
                if let url = AppSettings.iCloudDriveURL { workspace.go(to: url) } else { Alerts.message("iCloud Drive isn't turned on.", info: "Turn it on in System Settings ▸ Apple Account ▸ iCloud.") }
            }
            item("OneDrive") { workspace in
                if let url = AppSettings.oneDriveURLs.first { workspace.go(to: url) } else { Alerts.message("OneDrive isn't set up on this Mac.", info: "Install the OneDrive app and sign in; its folder then appears under Favorites.") }
            }
            item("iCloud Photos") { $0.openPhotos() }
            item("Google Drive") { workspace in
                if let url = AppSettings.googleDriveURLs.first { workspace.go(to: url) } else { Alerts.message("Google Drive isn't set up on this Mac.", info: "Install Google Drive for desktop and sign in; its folder then appears under Favorites.") }
            }
            item("Dropbox") { workspace in
                if let url = AppSettings.dropboxURLs.first { workspace.go(to: url) } else { Alerts.message("Dropbox isn't set up on this Mac.", info: "Install the Dropbox app and sign in; its folder then appears under Favorites.") }
            }
            Menu("SFTP") {
                ForEach(SFTPStore.shared.accounts) { account in
                    item(account.name) { $0.openSFTP(account) }
                }
                if !SFTPStore.shared.accounts.isEmpty { Divider() }
                item("Add SFTP Account…") { $0.addSFTPAccount() }
            }
            Menu("WebDAV") {
                ForEach(WebDAVStore.shared.accounts) { account in
                    item(account.name) { WebDAVStore.shared.connect(account, in: $0) }
                }
                if !WebDAVStore.shared.accounts.isEmpty { Divider() }
                item("Add WebDAV Account…") { $0.addWebDAVAccount() }
            }
            item("SharePoint") { $0.openSharePoint() }
            item("Microsoft Teams") { $0.openTeams() }
            item("Amazon S3") { $0.openS3() }
            item("Azure Blob Storage") { $0.openAzure() }
            item("Google Cloud Storage") { $0.openGCS() }
            item("Box") { workspace in
                if let url = AppSettings.boxURLs.first { workspace.go(to: url) } else { Alerts.message("Box isn't set up on this Mac.", info: "Install Box Drive and sign in; its folder then appears under Favorites.") }
            }
            Menu("Favorites") {
                ForEach(AppSettings.shared.favorites, id: \.self) { path in
                    item(FileManager.default.displayName(atPath: path)) { $0.go(to: URL(fileURLWithPath: path)) }
                }
            }
            Divider()
            item("Go to Folder…", "g", [.command, .shift]) { $0.goToFolderPrompt() }
            Divider()
            item("Switch Pane") { $0.switchPane() }
            item("Next Tab", "]", [.command, .shift]) { $0.activePane.selectNextTab(1) }
            item("Previous Tab", "[", [.command, .shift]) { $0.activePane.selectNextTab(-1) }
            item("Swap Panes", "u") { $0.swapPanes() }
            item("Same Folder in Other Pane", "=", [.command, .option]) { $0.mirrorToOtherPane() }
            item("Open Selected Folder in Other Pane", .rightArrow, [.command, .option]) { $0.openInOtherPane() }
        }

        CommandMenu("Commands") {
            item("Find Files…", "f") { $0.search() }
            item("Multi-Rename…", "m", [.control]) { $0.multiRename() }
            Divider()
            item("Compare Folders (Select Differences)", "k", [.command, .option]) { $0.compareFolders() }
            item("Synchronize Folders…", "y", [.command, .option]) { $0.synchronizeFolders() }
            item("Compare Files by Content…", "d", [.command, .option]) { $0.compareFiles() }
            Divider()
            item("Open Terminal Here", "t", [.command, .option]) { $0.openTerminal() }
            item("Connect to Server…", "k") { $0.sheet = .connect(prefill: "") }
        }
    }

    private func item(_ title: String, _ key: KeyEquivalent? = nil, _ modifiers: EventModifiers = .command,
                      action: @escaping (Workspace) -> Void) -> some View {
        Button(title) {
            if let workspace { action(workspace) }
        }
        .keyboardShortcut(key.map { KeyboardShortcut($0, modifiers: modifiers) })
        .disabled(workspace == nil)
    }
}
