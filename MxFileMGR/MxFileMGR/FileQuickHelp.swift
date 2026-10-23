//
//  FileQuickHelp.swift
//  MxFileMGR
//
//  What Quick Help (Shared/QuickHelp) says in MxFileMGR: the main window and its sheets, the marked
//  items, the tool windows, and — like MxDataSQL's grid cells — the file-list row and column header
//  under the pointer. The panel docks at the bottom of the sidebar, as in MxDataHUB.
//

import AppKit
import SwiftUI

enum FileHelp {
    /// Sets up the descriptions of AppKit views SwiftUI can't see into (the file lists).
    static func install() {
        let help = QuickHelp.shared
        guard help.describeView == nil else { return }
        help.describeView = { view, point in
            switch view {
            case let table as FileTableView: table.quickHelp(at: point)
            case let header as NSTableHeaderView:
                (header.tableView as? FileTableView).flatMap { column(at: point, in: $0, header: header) }
            default: nil
            }
        }
        help.describeFocus = { responder in
            (responder as? FileTableView)?.quickHelpForSelection()
        }
    }

    // MARK: Main window

    static func screen(_ workspace: Workspace) -> (name: String, item: QuickHelpItem) {
        if let sheet = workspace.sheet { return sheetScreen(sheet) }
        let side = workspace.activeSide == .left ? "left" : "right"
        return ("\(BrowserTab.displayName(of: workspace.activeTab.url)) (\(side))", main)
    }

    static let main = QuickHelpItem(
        title: "MxFileMGR",
        detail: "Two panes, each with tabs; the active one has the accent line on top. Tab switches panes, Return opens, Backspace goes up, "
            + "Space shows Quick Look and typing jumps to a name. Mark items with click, ⇧-click or ⌘-click; F5 copies and F6 moves them "
            + "to the other pane, F2 renames, F7 makes a folder, F8 (⌘⌫) moves to the Trash. The sidebar has Favorites, cloud storage, drives and servers.",
        symbol: "rectangle.split.2x1")

    private static func sheetScreen(_ sheet: WorkspaceSheet) -> (String, QuickHelpItem) {
        switch sheet {
        case .transfer(let request):
            return (request.move ? "Move" : "Copy", QuickHelpItem(
                title: request.move ? "Move" : "Copy",
                detail: "The destination is the other pane's folder unless you type another (relative paths and ~ work; a single item can get a new name). "
                    + "If an item already exists: Ask shows both and offers Replace, Skip, Keep Both or Stop, with Apply to all. Folders that exist are merged.",
                shortcut: request.move ? "F6" : "F5", symbol: request.move ? "arrow.right.doc.on.clipboard" : "doc.on.doc"))
        case .name(let prompt):
            return (prompt.title, QuickHelpItem(title: prompt.title, detail: prompt.message.isEmpty ? "Type a name, then press Return." : prompt.message,
                                                symbol: "character.cursor.ibeam"))
        case .pattern(let select):
            return (select ? "Select Group" : "Deselect Group", QuickHelpItem(
                title: select ? "Select Group" : "Deselect Group",
                detail: "Marks (or unmarks) the items whose names match: * matches anything and ? one character; separate several patterns with ;, e.g. *.jpg;*.png.",
                shortcut: select ? "⌘=" : "⌘-", symbol: "checklist"))
        case .properties:
            return ("Properties", QuickHelpItem(
                title: "Properties",
                detail: "Kind, total size (counted in the background), dates and owner. Change the permission bits — for everything inside a folder too — or the modification date, then Apply.",
                shortcut: "⌘I", symbol: "info.circle"))
        case .connect:
            return ("Connect to Server", connect)
        case .mediaMetadata(let url):
            return ("ffmpeg Meta-data", QuickHelpItem(
                title: "ffmpeg Meta-data — \(url.lastPathComponent)",
                detail: mediaMetadataDetail, symbol: "film"))
        case .sftp(let account):
            return (account == nil ? "Add SFTP Account" : "Edit SFTP Account", sftpSheet)
        case .webDAV(let account):
            return (account == nil ? "Add WebDAV Account" : "Edit WebDAV Account", webDAVSheet)
        }
    }

    static let connect = QuickHelpItem(
        title: "Connect to Server",
        detail: "Mounts a share — smb://, afp://, nfs://, ftp:// (read-only) or WebDAV (http/https) — and opens it in the active pane. It then shows under Locations, and the address is kept in Servers.",
        shortcut: "⌘K", symbol: "network")

    /// The marked items in the active pane, or its folder.
    static func selection(_ workspace: Workspace) -> QuickHelpItem? {
        let tab = workspace.activeTab
        let marked = tab.selectedItems
        if marked.isEmpty {
            return QuickHelpItem(title: BrowserTab.displayName(of: tab.url),
                                 detail: "\(tab.url.path) — \(Fmt.count(tab.items.count, "item")). Nothing is marked: click an item, or ⌘= to select by pattern.",
                                 symbol: "folder")
        }
        return markedItem(marked, in: tab)
    }

    static func markedItem(_ marked: [FileItem], in tab: BrowserTab) -> QuickHelpItem {
        if marked.count == 1 { return describe(marked[0], in: tab) }
        let bytes = marked.reduce(Int64(0)) { $0 + ($1.isDirectory ? (tab.folderSizes[$1.url] ?? 0) : $1.size) }
        let folders = marked.filter(\.isDirectory).count
        return QuickHelpItem(title: "\(marked.count) Items Marked",
                             detail: "\(Fmt.size(bytes))\(folders > 0 ? " (\(Fmt.count(folders, "folder")) not counted until Calculate Folder Sizes, ⌥⌘S)" : ""). "
                                + "F5 copies or F6 moves them to the other pane; F2 renames them together with Multi-Rename; F8 moves them to the Trash.",
                             symbol: "checkmark.circle")
    }

    static func describe(_ item: FileItem, in tab: BrowserTab?) -> QuickHelpItem {
        var facts: [String] = []
        if !item.kind.isEmpty { facts.append(item.kind) }
        if item.isDirectory {
            if let size = tab?.folderSizes[item.url] { facts.append(Fmt.size(size)) }
        } else if !item.isPackage {
            facts.append(Fmt.size(item.size))
        }
        if item.modified != .distantPast { facts.append("modified \(Fmt.date(item.modified))") }
        if item.isSymlink { facts.append("a symbolic link") }
        if item.isHidden { facts.append("hidden") }
        let action = item.isDirectory ? "Return opens it" : (item.isPackage ? "Return opens it (Show Package Contents to look inside)" : "Return opens it, Space previews it, F3 views it, F4 edits it")
        return QuickHelpItem(title: item.name, detail: facts.joined(separator: ", ") + ". " + action + "; right-click for more.",
                             symbol: item.isDirectory ? "folder" : (item.isPackage ? "shippingbox" : "doc"))
    }

    static func column(_ key: SortKey, sorted: SortOrder) -> QuickHelpItem {
        let what: String
        switch key {
        case .name: what = "The item's name; hidden items are dimmed and symbolic links are in italics."
        case .ext: what = "The file extension."
        case .size: what = "File sizes. Folders show <DIR> until you use Calculate Folder Sizes (⌥⌘S)."
        case .modified: what = "When the item's contents last changed."
        case .kind: what = "The kind of file, as Finder names it."
        }
        let order = sorted.key == key ? " Sorted by this column, \(sorted.ascending ? "ascending" : "descending"); click again to reverse." : " Click to sort by it."
        return QuickHelpItem(title: key.title + " Column", detail: what + order + " Drag to resize or reorder; both are remembered.",
                             symbol: "arrow.up.arrow.down")
    }

    private static func column(at point: NSPoint, in table: FileTableView, header: NSTableHeaderView) -> QuickHelpItem? {
        let index = header.column(at: point)
        guard index >= 0, index < table.tableColumns.count,
              let key = SortKey(rawValue: table.tableColumns[index].identifier.rawValue) else { return nil }
        return column(key, sorted: table.coordinator?.tab?.sort ?? SortOrder())
    }

    // MARK: Sidebar and panes

    static let favorites = QuickHelpItem(
        title: "Favorites",
        detail: "Cloud storage on this Mac (iCloud Drive, OneDrive, SharePoint, Teams, Google Drive, Dropbox, Box), iCloud Photos and the cloud object stores, then your folders. "
            + "Click one to open it in the active pane. Drop a folder here to add it; drag to reorder; right-click to remove. ⌃D adds the current folder.",
        symbol: "star")

    static func cloudFolder(_ name: String, _ url: URL) -> String {
        if name.hasPrefix("Teams Chat Files") {
            return "\(name): files shared in Microsoft Teams chats, kept by Teams in your OneDrive at \(url.path). "
                + "Channel files are in the team's SharePoint site and show under SharePoint once synced."
        }
        if name.hasPrefix("SharePoint") {
            return "\(name): the SharePoint document libraries the OneDrive app syncs for this organisation, one “Site - Library” folder each, at \(url.path). "
                + "Files stored only online download when opened; changes sync back to SharePoint."
        }
        return "\(name), kept on this Mac by its app at \(url.path). Opens in the active pane like any folder; files stored only online download when opened."
    }

    static let webDAVSheet = QuickHelpItem(
        title: "WebDAV Account",
        detail: "A name for the sidebar, the share's http:// or https:// address, and the user. The password is kept in your login Keychain only if Remember is on; "
            + "left empty, macOS asks for it when connecting. Connect saves the account, mounts the share and opens it; Save just saves it.",
        symbol: "globe")

    static func webDAVAccount(_ account: WebDAVAccount, mounted: Bool) -> String {
        "\(account.address)\(account.user.isEmpty ? "" : " as \(account.user)"). "
            + (mounted ? "Connected: click to open it in the active pane." : "Click to connect (mount) and open it in the active pane.")
            + " Right-click to edit, disconnect or remove it."
    }

    static let mediaMetadataDetail = "Edits the Title and Description tags of this MP4, M4V, MOV, WebM, MKV, AVI, MP3 or M4A file (AVI: Description goes in the comment tag; MP3: in a TXXX frame) with ffmpeg, copying every stream without re-encoding "
        + "(-map 0 -c copy); the other tags are kept and an empty field removes its tag. Apply replaces the original once the new copy is written, "
        + "or saves a new file. Progress shows in the transfer panel; Command shows the equivalent ffmpeg command."

    static let sftpSheet = QuickHelpItem(
        title: "SFTP Account",
        detail: "A name for the sidebar and the server: a host name or an alias from ~/.ssh/config (pick one above), with an optional user, port and starting folder. "
            + "Sign in with your SSH key or agent, as ssh in Terminal does, or with a password kept in your login Keychain. Test Connection tries it.",
        symbol: "terminal")

    static func sftpAccount(_ account: SFTPAccount) -> String {
        "\(account.destination)\(account.port.isEmpty ? "" : ":\(account.port)")\(account.path.isEmpty ? "" : " in \(account.path)"). "
            + "Click to open it in its own window: browse, download to and upload from the active pane, rename, delete. Right-click to edit or remove it."
    }

    static let addSFTP = QuickHelpItem(
        title: "Add SFTP Account",
        detail: "Saves an SFTP server in Favorites — from your ~/.ssh/config hosts or typed in — signing in with your SSH key or a password kept in your Keychain.",
        symbol: "plus.circle")

    static let sftpScreen = QuickHelpItem(
        title: "SFTP",
        detail: "The server's folder, through the system's sftp (macOS can't mount SFTP). Double-click a folder to open it or a file to download it to the active pane; "
            + "Upload sends what's marked there, or drop files on the list. Errors from ssh, such as a refused key or an expired jump-host sign-in, show in red.",
        symbol: "terminal")

    static let addWebDAV = QuickHelpItem(
        title: "Add WebDAV Account",
        detail: "Saves a WebDAV server (Nextcloud, ownCloud, a NAS, …) in Favorites so one click connects and opens it. The password can be kept in your Keychain.",
        symbol: "plus.circle")

    static let clipboard = QuickHelpItem(
        title: "Clipboard",
        detail: "What's on the clipboard, as in Finder's Show Clipboard: files (a Quick Look preview of the selected one, Paste into the active pane, Move Here, Show in Finder; double-click opens the Viewer), "
            + "a picture, styled or plain text, a link or a colour, and the data types underneath. It updates while the window is open; "
            + "Clear Clipboard empties it.",
        shortcut: "⇧⌘V", symbol: "clipboard")

    static let sharePointSetup = QuickHelpItem(
        title: "SharePoint",
        detail: "SharePoint document libraries appear here once the OneDrive app syncs them (work or school account; in SharePoint, a library's Sync or Add shortcut to My files). "
            + "None are synced yet: click for how, and to open OneDrive.",
        symbol: "building.2")

    static let teamsSetup = QuickHelpItem(
        title: "Microsoft Teams",
        detail: "Teams files live in OneDrive (chat files, in “Microsoft Teams Chat Files”) and in the team's SharePoint site (channel files, which show under SharePoint once synced). "
            + "Neither is on this Mac yet: click for how, and to open Teams.",
        symbol: "bubble.left.and.bubble.right")

    static let photos = QuickHelpItem(
        title: "iCloud Photos",
        detail: "Opens a window on your Photos library: browse albums, find duplicates and long videos, delete, organize and rename albums, and export originals into the active pane's folder.",
        symbol: "photo.on.rectangle")

    static let s3 = QuickHelpItem(
        title: "Amazon S3",
        detail: "Opens a window on your S3 buckets through the AWS CLI and your ~/.aws profiles (SSO sign-in included): browse, download to and upload from the active pane, rename, delete, copy URIs and presigned links.",
        symbol: "server.rack")

    static let azure = QuickHelpItem(
        title: "Azure Blob Storage",
        detail: "Opens a window on your storage accounts through the Azure CLI after az login: browse containers, download to and upload from the active pane, rename files, delete, copy URLs and SAS links.",
        symbol: "cylinder.split.1x2")

    static let gcs = QuickHelpItem(
        title: "Google Cloud Storage",
        detail: "Opens a window on your Cloud Storage buckets through the Google Cloud CLI after gcloud auth login: pick a project and bucket, browse, download to and upload from the active pane, rename, delete, copy gs:// URIs and browser links.",
        symbol: "cloud.circle")

    static let pathBar = QuickHelpItem(
        title: "Path",
        detail: "The folder's path: click any part to go there. Right-click to copy the path or type one with Go to Folder (⇧⌘G).",
        symbol: "point.topleft.down.to.point.bottomright.curvepath")

    static let filter = QuickHelpItem(
        title: "Filter",
        detail: "Shows only the items whose name contains this text, or matches wildcards such as *.txt. Escape clears it.",
        symbol: "line.3.horizontal.decrease.circle")

    static let tabs = QuickHelpItem(
        title: "Tabs",
        detail: "Each tab keeps its own folder, history, sort and filter. Click to switch; × closes (⌃W); + opens a new one (⌘T). ⇧⌘] and ⇧⌘[ move between them.",
        symbol: "rectangle.stack")

    static let status = QuickHelpItem(
        title: "Status",
        detail: "How many items the pane lists and their size, or what's marked, and the space available on the volume.",
        symbol: "info.circle")

    static let transfers = QuickHelpItem(
        title: "Transfers",
        detail: "Copies, moves, deletes, archives and cloud transfers running in the background, with their progress. Stop ends one; jobs with problems stay listed until dismissed.",
        symbol: "arrow.up.arrow.down.circle")

    static let functionKeys = QuickHelpItem(
        title: "Function Keys",
        detail: "The Total Commander keys, for the marked items: F2 Rename, F3 View, F4 Edit, F5 Copy, F6 Move, F7 New Folder, F8 Trash, ⌥F7 Find. "
            + "On a Mac keyboard hold fn with them. View ▸ Function Key Bar hides the row.",
        symbol: "keyboard")

    // MARK: Cloud storage windows

    static let uploadDetail = "Uploads the items marked in the active pane into this folder (folders with everything in them), after asking before replacing anything. You can also drop files on the list."
    static let downloadDetail = "Downloads the selected items into the active pane's folder; folders come with everything in them. Double-clicking a file does the same."

    static func remoteList(_ service: String) -> QuickHelpItem {
        QuickHelpItem(title: "\(service) Items",
                      detail: "Folders first, then files with their size and date. Double-click a folder to open it or a file to download it; right-click to copy links, rename or delete. Drop files here to upload them.",
                      symbol: "list.bullet")
    }

    static func remoteSelection(_ entries: [RemoteEntry]) -> QuickHelpItem? {
        guard !entries.isEmpty else { return nil }
        if entries.count == 1, let e = entries.first {
            return QuickHelpItem(title: e.name,
                                 detail: e.isFolder ? "A folder. Double-click to open it." : "\(Fmt.size(e.size)), modified \(Fmt.date(e.modified))\(e.storageClass.isEmpty ? "" : ", \(e.storageClass)"). Download (↩) copies it to the active pane.",
                                 symbol: e.isFolder ? "folder" : "doc")
        }
        let bytes = entries.reduce(Int64(0)) { $0 + $1.size }
        return QuickHelpItem(title: "\(entries.count) Items Selected", detail: "\(Fmt.size(bytes)) in files. Download (↩) copies them to the active pane; Delete removes them.",
                             symbol: "checkmark.circle")
    }

    static let s3Screen = QuickHelpItem(
        title: "Amazon S3",
        detail: "Choose a profile from ~/.aws and a bucket, then browse with the path, Up and Filter. Download copies to the active pane's folder; Upload sends what's marked there. "
            + "When an SSO session expires, Sign In runs aws sso login in your browser.",
        symbol: "server.rack")

    static let azureScreen = QuickHelpItem(
        title: "Azure Blob Storage",
        detail: "Choose a subscription, storage account and container, then browse with the path, Up and Filter. Download copies to the active pane's folder; Upload sends what's marked there. "
            + "Access uses your Entra sign-in, falling back to the account key when the account refuses it.",
        symbol: "cylinder.split.1x2")

    // MARK: Tool windows

    static let search = QuickHelpItem(
        title: "Find Files",
        detail: "Searches from a folder by name (wildcards such as *.swift;*.md, or a regular expression), by text inside files, and by size and age, optionally into subfolders and hidden items. "
            + "Double-click a result to show it in the active pane.",
        shortcut: "⌘F", symbol: "magnifyingglass")

    static let multiRename = QuickHelpItem(
        title: "Multi-Rename",
        detail: "Builds new names from masks: [N] name, [N2-5] characters 2–5, [E] extension, [C] counter, [P] parent folder, [YMD] and [hms] dates. "
            + "Search and replace (or regex) and case changes; the preview flags duplicates and taken names. Rename applies it; Undo reverts the last batch.",
        shortcut: "⌃M", symbol: "character.cursor.ibeam")

    static let sync = QuickHelpItem(
        title: "Synchronize Folders",
        detail: "Compare lists what differs between two folder trees, by date and size or by content. Each row gets a direction (→, ← or skip) you can change; Synchronize copies, replacing older files.",
        shortcut: "⌥⌘Y", symbol: "arrow.triangle.2.circlepath")

    static let viewer = QuickHelpItem(
        title: "Viewer",
        detail: "Preview shows the file as Quick Look does; Text shows it as text (⌘F finds, Wrap lines folds long ones); Hex shows its bytes.",
        shortcut: "F3", symbol: "doc.text.magnifyingglass")

    static let diff = QuickHelpItem(
        title: "Compare Files",
        detail: "Lines removed from the left file are red, lines added in the right one green. Only changes hides the rest. Binary files are compared byte for byte. Open in FileMerge uses Xcode's tool.",
        shortcut: "⌥⌘D", symbol: "doc.on.doc")

    static let photosScreen = QuickHelpItem(
        title: "iCloud Photos",
        detail: "Albums on the left; click thumbnails to select. Export writes the originals into the active pane's folder. Delete moves to Recently Deleted (Photos asks first). "
            + "Duplicates groups likely duplicates; Select Extras keeps one of each. Organize adds to albums, favorites or hides; right-click an album to rename or delete it.",
        symbol: "photo.on.rectangle")
}

// MARK: - File list under the pointer

extension FileTableView {
    /// The row under the pointer: the item and the column's value.
    func quickHelp(at point: NSPoint) -> QuickHelpItem? {
        let rowIndex = row(at: point)
        guard rowIndex >= 0, let coordinator else { return nil }
        if let item = coordinator.item(at: rowIndex) {
            return FileHelp.describe(item, in: coordinator.tab)
        }
        if rowIndex == 0, let parent = coordinator.tab?.parentURL {
            return QuickHelpItem(title: "..", detail: "The enclosing folder, \(parent.path). Return or double-click goes up; so does Backspace or ⌘↑ anywhere in the list.",
                                 shortcut: "⌫", symbol: "arrow.turn.left.up")
        }
        return nil
    }

    /// What's marked in this list (it has the keyboard focus).
    func quickHelpForSelection() -> QuickHelpItem? {
        guard let tab = coordinator?.tab else { return nil }
        let marked = tab.selectedItems
        return marked.isEmpty ? nil : FileHelp.markedItem(marked, in: tab)
    }
}
