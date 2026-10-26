//
//  StepLinks.swift
//  MxJobsMGR
//
//  Right-click a step on the canvas (Refresh Trigger, Agent Task, API Data Read…) to edit its title and description
//  (Edit Step…) or to add, edit, open or remove a link of its own — a web page, an email address or a page in
//  MxNoteONE — with formatted hover text, made in the Link dialog the other apps use (Shared/Links). A step without a
//  link of its own shows its palette element's (PaletteEdits.swift). The pointer resting on a linked step shows the
//  hover card; the step's link mark opens it. A step's own link is kept with the step in the jobspace file.
//

import SwiftUI

/// A dialog open for a step on the canvas.
struct StepSheet: Identifiable {
    enum Kind { case edit, link }
    var node: UUID
    var kind: Kind
    var id: String { node.uuidString + (kind == .edit ? ":edit" : ":link") }
}

extension JobNode {
    /// The link the step shows: its own, else its palette element's.
    @MainActor var shownLink: SecurityLink? { link ?? PaletteEdits.shared.link(.kind(kind)) }
}

/// Edit Step…: the step's title and description (its notes, also in the inspector).
struct StepEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var space: Jobspace
    let id: UUID
    @State private var title = ""
    @State private var notes = ""

    var body: some View {
        if let node = space.node(id) {
            VStack(alignment: .leading, spacing: 14) {
                Label("Edit Step", systemImage: node.kind.symbol).font(.headline)
                Text("\(node.kind.title) · Layer \(node.layer.rawValue) · \(node.layer.title)")
                    .font(.caption).foregroundStyle(node.layer.color)
                Form {
                    TextField("Title:", text: $title, prompt: Text(PaletteEdits.shared.title(node.kind)))
                        .quickHelp("Title", "The step's name on the canvas, in the run log and in the inspector.")
                    TextField("Description:", text: $notes, prompt: Text("What this step is for"), axis: .vertical)
                        .lineLimit(3...6)
                        .quickHelp("Description", "Your notes on the step (Notes in the inspector), kept in the jobspace.")
                }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .quickHelp("Cancel", "Closes the dialog without changing the step.", shortcut: "⎋")
                    Button("Save") {
                        if let i = space.index(of: id) {
                            let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
                            space.nodes[i].title = t.isEmpty ? PaletteEdits.shared.title(node.kind) : t
                            space.nodes[i].notes = notes
                        }
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .quickHelp("Save", "Keeps the step's title and description in the jobspace.", shortcut: "↩")
                }
            }
            .padding(20)
            .frame(width: 440)
            .onAppear {
                title = node.title
                notes = node.notes
            }
        }
    }
}

/// The Link dialog for a step's own link.
struct StepLinkSheet: View {
    @Binding var space: Jobspace
    let id: UUID

    var body: some View {
        if let node = space.node(id) {
            let inherited = node.link == nil ? PaletteEdits.shared.link(.kind(node.kind)) : nil
            LinkSheet(subject: node.title, detail: "Step: \(node.kind.title), Layer \(node.layer.rawValue)", initial: node.link, words: node.title,
                      whereKept: "Kept with the step in this jobspace: the pointer resting on the step shows its hover text, and its link mark opens it."
                        + (inherited == nil ? "" : " Until then it shows its palette element's link (\(LinkRichText.addressText(inherited!.url!))).")) { link in
                if let i = space.index(of: id) { space.nodes[i].link = link }
                return nil
            }
        }
    }
}

/// Behind a step on the canvas: the hover card for the link it shows. Edit Link… and Remove Link act on the step's own
/// link, or on its palette element's when it has none.
struct StepLinkAnchor: View {
    let node: JobNode
    var edit: () -> Void
    var remove: () -> Void

    var body: some View {
        if let link = node.shownLink, let url = link.url {
            LinkWordsAnchor(url: url, words: link.text ?? node.title, tip: link.tipText, title: link.title, testID: "step:\(node.id.uuidString)",
                            edit: edit, remove: remove)
        }
    }
}

/// A step's link mark: opens the link it shows (its own in the link color, its element's dimmer).
struct StepLinkMark: View {
    let node: JobNode

    var body: some View {
        if let link = node.shownLink, let url = link.url {
            Image(systemName: "link")
                .font(.caption)
                .foregroundStyle(node.link == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color(nsColor: .linkColor)))
                .contentShape(Rectangle())
                .onTapGesture { LinkInfo.follow(url) }
                .quickHelp("Open Link", "Opens " + (node.link == nil ? "the \(PaletteEdits.shared.title(node.kind)) element's link" : "the step's link")
                            + ": \(LinkRichText.addressText(url))", symbol: "link")
        }
    }
}
