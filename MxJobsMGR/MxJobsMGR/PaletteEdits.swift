//
//  PaletteEdits.swift
//  MxJobsMGR
//
//  Your own words for the palette (the left panel): each element (Refresh Trigger, Agent Task, API Data Read…) can be
//  renamed and given a description of its own (right-click ▸ Edit Element…, or select it and press Return), and each
//  element and each layer's header can carry a link — a web page, an email address or a page in MxNoteONE — with
//  formatted hover text, made in the Link dialog the other apps use (Shared/Links), as MxAcctMGR's sidebar pages do
//  (PageLinks.swift there). The pointer resting on a linked row shows the link's hover card; its link mark opens it.
//  Everything is kept on this Mac with the app's preferences, the same in every jobspace. Steps added from a renamed
//  element take its new title; steps already on a canvas keep theirs.
//

import Observation
import SwiftUI

/// Something in the palette that can carry a link: an element, or a layer's header.
enum PaletteItem: Hashable, Identifiable {
    case kind(NodeKind)
    case layer(Layer)

    /// Also the link's key in the preferences.
    var id: String {
        switch self {
        case .kind(let kind): "kind:" + kind.rawValue
        case .layer(let layer): "layer:\(layer.rawValue)"
        }
    }
}

@MainActor
@Observable
final class PaletteEdits {
    static let shared = PaletteEdits()
    private static let key = "paletteEdits"

    /// An element's own title and description; nil keeps the built-in one.
    struct Element: Codable, Equatable {
        var title: String?
        var summary: String?
    }

    private struct Stored: Codable {
        var elements: [String: Element] = [:]
        var links: [String: SecurityLink] = [:]
    }

    /// By NodeKind's raw value.
    private(set) var elements: [String: Element]
    /// By PaletteItem.id.
    private(set) var links: [String: SecurityLink]

    private init() {
        let stored = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored()
        elements = stored.elements
        links = stored.links
    }

    func title(_ kind: NodeKind) -> String { elements[kind.rawValue]?.title ?? kind.title }
    func summary(_ kind: NodeKind) -> String { elements[kind.rawValue]?.summary ?? kind.summary }
    func isEdited(_ kind: NodeKind) -> Bool { elements[kind.rawValue] != nil }

    func title(_ item: PaletteItem) -> String {
        switch item {
        case .kind(let kind): title(kind)
        case .layer(let layer): "Layer \(layer.rawValue) · \(layer.title)"
        }
    }

    /// Saves an element's title and description; empty or built-in words go back to the built-in ones.
    func set(title: String, summary: String, for kind: NodeKind) {
        func own(_ text: String, _ builtIn: String) -> String? {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty || t == builtIn ? nil : t
        }
        let element = Element(title: own(title, kind.title), summary: own(summary, kind.summary))
        elements[kind.rawValue] = element == Element() ? nil : element
        save()
    }

    func reset(_ kind: NodeKind) {
        elements[kind.rawValue] = nil
        save()
    }

    func link(_ item: PaletteItem) -> SecurityLink? { links[item.id] }

    /// Saves (or with nil takes off) the item's link.
    func setLink(_ link: SecurityLink?, for item: PaletteItem) {
        links[item.id] = link
        save()
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(Stored(elements: elements, links: links)), forKey: Self.key)
    }
}

// MARK: - Edit Element

/// Renames an element of the palette and rewrites its description.
struct PaletteElementSheet: View {
    @Environment(\.dismiss) private var dismiss
    let kind: NodeKind
    @State private var title = ""
    @State private var summary = ""

    private var edits: PaletteEdits { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Edit Element", systemImage: kind.symbol).font(.headline)
            Text("Layer \(kind.layer.rawValue) · \(kind.layer.title)").font(.caption).foregroundStyle(kind.layer.color)
            Form {
                TextField("Title:", text: $title, prompt: Text(kind.title))
                    .quickHelp("Title", "The element's name in the palette, and the title of new steps added from it. Leave it empty for the built-in name, \(kind.title).")
                TextField("Description:", text: $summary, prompt: Text(kind.summary), axis: .vertical)
                    .lineLimit(2...4)
                    .quickHelp("Description", "The line under the element's name in the palette. Leave it empty for the built-in one.")
            }
            Text("Built in: \(kind.title) — \(kind.summary)")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label("Kept on this Mac with MxJobsMGR's palette, the same in every jobspace. Steps already on a canvas keep their titles.",
                  systemImage: "externaldrive")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Reset to Built-in") {
                    title = kind.title
                    summary = kind.summary
                }
                .disabled(title == kind.title && summary == kind.summary)
                .quickHelp("Reset to Built-in", "Puts back the element's built-in name and description (saved with Save).")
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .quickHelp("Cancel", "Closes the dialog without changing the element.", shortcut: "⎋")
                Button("Save") {
                    edits.set(title: title, summary: summary, for: kind)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .quickHelp("Save", "Keeps the element's title and description.", shortcut: "↩")
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            title = edits.title(kind)
            summary = edits.summary(kind)
        }
    }
}

// MARK: - Links

/// The Link dialog for an element or a layer's header.
struct PaletteLinkSheet: View {
    let item: PaletteItem

    var body: some View {
        let title = PaletteEdits.shared.title(item)
        LinkSheet(subject: title, detail: detail, initial: PaletteEdits.shared.link(item), words: title,
                  whereKept: "Kept on this Mac with MxJobsMGR's palette: the pointer resting on \(title) shows its hover text, and its link mark opens it.") { link in
            PaletteEdits.shared.setLink(link, for: item)
            return nil
        }
    }

    private var detail: String {
        switch item {
        case .kind(let kind): "An element of Layer \(kind.layer.rawValue) in the palette"
        case .layer: "A layer of the palette"
        }
    }
}

/// An item's context-menu items: add or edit its link, open it, take it off.
@ViewBuilder
func paletteLinkMenu(_ item: PaletteItem, edit: @escaping () -> Void) -> some View {
    let link = PaletteEdits.shared.link(item)
    Button(link == nil ? "Add Link…" : "Edit Link…") { LinkHover.shared.close(); edit() }
    if let url = link?.url {
        Button("Open Link") { LinkInfo.follow(url) }
        Button("Remove Link") { PaletteEdits.shared.setLink(nil, for: item) }
    }
}

extension View {
    /// A palette row with its link: the hover card when the pointer rests on it, and a link mark that opens it.
    func paletteLink(_ item: PaletteItem, edit: @escaping () -> Void) -> some View {
        let link = PaletteEdits.shared.link(item)
        let title = PaletteEdits.shared.title(item)
        return background {
            if let link, let url = link.url {
                LinkWordsAnchor(url: url, words: link.text ?? title, tip: link.tipText, title: link.title, testID: "palette:\(item.id)",
                                edit: edit, remove: { PaletteEdits.shared.setLink(nil, for: item) })
            }
        }
        .overlay(alignment: .trailing) {
            if let link, let url = link.url {
                Button { LinkInfo.follow(url) } label: { Image(systemName: "link").font(.caption) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color(nsColor: .linkColor))
                    .quickHelp("Open Link", "Opens \(link.text ?? title)'s link: \(LinkRichText.addressText(url))", symbol: "link")
            }
        }
    }
}
