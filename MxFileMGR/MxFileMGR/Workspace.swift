//
//  Workspace.swift
//  MxFileMGR
//
//  State of one main window: the two panes, which one is active,
//  the sheet being shown, and the saved session (open tabs).
//

import AppKit
import SwiftUI

extension FocusedValues {
    @Entry var workspace: Workspace?
}

enum WorkspaceSheet: Identifiable {
    case transfer(TransferRequest)
    case name(NamePrompt)
    case pattern(select: Bool)
    case properties([URL])
    case connect(prefill: String)
    case webDAV(WebDAVAccount?)
    case sftp(SFTPAccount?)
    case mediaMetadata(URL)

    var id: String {
        switch self {
        case .transfer(let r): "transfer-\(r.id)"
        case .name(let p): "name-\(p.id)"
        case .pattern(let select): "pattern-\(select)"
        case .properties(let urls): "properties-\(urls.hashValue)"
        case .connect: "connect"
        case .webDAV(let account): "webdav-\(account?.id.uuidString ?? "new")"
        case .sftp(let account): "sftp-\(account?.id.uuidString ?? "new")"
        case .mediaMetadata(let url): "media-\(url.path)"
        }
    }
}

struct TransferRequest {
    let id = UUID()
    var sources: [URL]
    var destination: String
    var move: Bool
}

/// A one-line text prompt (new folder, rename, go to folder, ...).
struct NamePrompt {
    let id = UUID()
    var title: String
    var message: String = ""
    var initial: String
    var okTitle: String
    /// Preselect the name without its extension, as Finder does when renaming.
    var selectStem = false
    var action: (String) -> Void
}

private struct SessionState: Codable {
    var left: [String]
    var leftActive: Int
    var right: [String]
    var rightActive: Int
    var activeSide: Side
}

@Observable
final class Workspace {
    /// The workspace of the most recently active main window (used by tool windows).
    static weak var current: Workspace?

    let left: Pane
    let right: Pane
    var activeSide: Side = .left
    /// Bumped to move keyboard focus to the active pane's file list.
    private(set) var focusToken = 1
    var sheet: WorkspaceSheet?

    @ObservationIgnored var openWindow: OpenWindowAction?
    @ObservationIgnored weak var window: NSWindow?

    init(left: Pane, right: Pane, activeSide: Side) {
        self.left = left
        self.right = right
        self.activeSide = activeSide
    }

    /// A new window starts with the tabs that were open when the session was last saved.
    static func restored() -> Workspace {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var state = SessionState(left: [home.path], leftActive: 0,
                                 right: [home.appendingPathComponent("Desktop").path], rightActive: 0, activeSide: .left)
        if let data = UserDefaults.standard.data(forKey: "session"),
           let saved = try? JSONDecoder().decode(SessionState.self, from: data) {
            state = saved
        }
        func urls(_ paths: [String]) -> [URL] {
            let list = paths.map { URL(fileURLWithPath: $0) }.filter(FileOps.isRealDirectory)
            return list.isEmpty ? [home] : list
        }
        return Workspace(left: Pane(side: .left, urls: urls(state.left), activeIndex: state.leftActive),
                         right: Pane(side: .right, urls: urls(state.right), activeIndex: state.rightActive),
                         activeSide: state.activeSide)
    }

    /// Changes whenever a tab opens, closes or changes folder.
    var sessionSignature: String {
        [left, right].map { pane in
            pane.tabs.map(\.url.path).joined(separator: "|") + "#\(pane.activeIndex)"
        }.joined(separator: "||") + activeSide.rawValue
    }

    func saveSession() {
        let state = SessionState(left: left.tabs.map(\.url.path), leftActive: left.activeIndex,
                                 right: right.tabs.map(\.url.path), rightActive: right.activeIndex,
                                 activeSide: activeSide)
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: "session")
        }
    }

    var activePane: Pane { pane(activeSide) }
    var otherPane: Pane { pane(activeSide.other) }
    var activeTab: BrowserTab { activePane.active }
    var otherTab: BrowserTab { otherPane.active }

    func pane(_ side: Side) -> Pane { side == .left ? left : right }

    /// Makes `side` active and gives its file list keyboard focus.
    func focus(_ side: Side) {
        activeSide = side
        focusToken += 1
    }

    func switchPane() { focus(activeSide.other) }
}
