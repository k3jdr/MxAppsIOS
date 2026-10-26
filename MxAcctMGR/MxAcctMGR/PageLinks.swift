//
//  PageLinks.swift
//  MxAcctMGR
//
//  A link on a page of the sidebar (right-click the page in the left panel): a web page, an email address or a page in
//  MxNoteONE, with words of its own and formatted hover text — made in the same Link dialog as the links on securities
//  and target accounts (Shared/Links). Kept on this Mac with the app's preferences, one per page: the pointer resting on
//  the page's row shows the link's hover card (open it, Edit Link…, remove it), and the row's link mark opens it. A click
//  on the row still opens the page.
//

import Observation
import SwiftUI

@MainActor
@Observable
final class PageLinks {
    static let shared = PageLinks()
    private static let key = "pageLinks"

    /// Each page's link, by its screen.
    private(set) var links: [String: SecurityLink]
    /// The Link dialog is open for this page.
    var editing: Screen?

    private init() {
        links = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([String: SecurityLink].self, from: $0) } ?? [:]
    }

    func link(_ screen: Screen) -> SecurityLink? { links[screen.rawValue] }

    /// Saves (or with nil takes off) the page's link.
    func set(_ link: SecurityLink?, for screen: Screen) {
        links[screen.rawValue] = link
        UserDefaults.standard.set(try? JSONEncoder().encode(links), forKey: Self.key)
    }

    func beginEdit(_ screen: Screen) {
        LinkHover.shared.close()
        editing = screen
    }
}

/// The Link dialog for a sidebar page.
struct PageLinkSheet: View {
    let screen: Screen
    let title: String

    var body: some View {
        LinkSheet(subject: title, detail: "A page in the sidebar", initial: PageLinks.shared.link(screen), words: title,
                  whereKept: "Kept on this Mac with MxAcctMGR's sidebar: the pointer resting on \(title) shows its hover text, and its link mark opens it.") { link in
            PageLinks.shared.set(link, for: screen)
            return nil
        }
    }
}

/// A sidebar page's context-menu items: add or edit its link, open it, take it off.
@ViewBuilder
func pageLinkMenu(_ screen: Screen, title: String) -> some View {
    let link = PageLinks.shared.link(screen)
    Button(link == nil ? "Add Link to \(title)…" : "Edit Link on \(title)…") { PageLinks.shared.beginEdit(screen) }
    if let url = link?.url {
        Button("Open Link") { LinkInfo.follow(url) }
        Button("Remove Link") { PageLinks.shared.set(nil, for: screen) }
    }
}

extension View {
    /// A sidebar page's row with its link: the hover card when the pointer rests on it, and a link mark that opens it.
    func pageLink(_ screen: Screen, title: String) -> some View {
        let link = PageLinks.shared.link(screen)
        return background {
            if let link, let url = link.url {
                LinkWordsAnchor(url: url, words: link.text ?? title, tip: link.tipText, title: link.title, testID: "page:\(screen.rawValue)",
                                edit: { PageLinks.shared.beginEdit(screen) }, remove: { PageLinks.shared.set(nil, for: screen) })
            }
        }
        .overlay(alignment: .trailing) {
            if let link, let url = link.url {
                Button { LinkInfo.follow(url) } label: { Image(systemName: "link").font(.caption) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color(nsColor: .linkColor))
                    .help("Open \(link.text ?? title)'s link")
            }
        }
        .contextMenu { pageLinkMenu(screen, title: title) }
    }
}
