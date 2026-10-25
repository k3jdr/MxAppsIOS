//
//  LinkSheet.swift
//  Shared by MxAcctMGR and MxDataHUB (MXcodeIDE/Shared/Links)
//
//  A link on something other than a security's ticker or name — MxAcctMGR's external accounts — made and shown as the
//  securities' links are (SecurityLinks.swift), after MxNoteONE's: the words shown as a link (a click opens it, the
//  pointer resting on them shows the hover card, LinkHover.swift) and the Link dialog — Text to display, Address,
//  formatted hover text with a preview of the card, pages to pick, and a link copied in MxNoteONE. Where the link is
//  kept is the caller's: it hands the words what Edit Link… and Remove Link do, and the dialog a save function.
//

import AppKit
import SwiftUI

// MARK: - The linked words

/// Words shown as a link: a click opens it, the pointer resting on them shows the hover card.
struct LinkedWords: View {
    let link: SecurityLink
    /// The words when the link has none of its own (an external account's name).
    let words: String
    var font: Font = .body
    var struck = false
    /// Tells the cards apart in Debug self-tests (LinkWordsAnchorView.testHover).
    var testID = ""
    var edit: () -> Void
    var remove: () -> Void

    var body: some View {
        let shown = link.text ?? words
        if let url = link.url {
            Button { LinkInfo.follow(url) } label: {
                Text(shown).font(font).underline().strikethrough(struck)
                    .foregroundStyle(Color(nsColor: .linkColor)).lineLimit(1)
            }
            .buttonStyle(.plain)
            .textSelection(.disabled)
            .background(LinkWordsAnchor(url: url, words: shown, tip: link.tipText, title: link.title, testID: testID, edit: edit, remove: remove))
            .accessibilityHint("Link to \(url.absoluteString)")
        } else {
            Text(shown).font(font).strikethrough(struck).lineLimit(1)
        }
    }
}

/// Behind the linked words: hears the pointer and shows the hover card, as MxNoteONE's text does.
struct LinkWordsAnchor: NSViewRepresentable {
    let url: URL
    let words: String
    let tip: NSAttributedString?
    let title: String?
    let testID: String
    let edit: () -> Void
    let remove: () -> Void

    func makeNSView(context: Context) -> LinkWordsAnchorView { LinkWordsAnchorView() }

    func updateNSView(_ view: LinkWordsAnchorView, context: Context) {
        view.url = url
        view.words = words
        view.tip = tip
        view.title = title
        view.edit = edit
        view.remove = remove
        #if DEBUG
        if !testID.isEmpty { LinkWordsAnchorView.anchors[testID] = { [weak view] in view } }
        #endif
    }
}

final class LinkWordsAnchorView: NSView {
    var url: URL?
    var words: String?
    var tip: NSAttributedString?
    var title: String?
    var edit: (() -> Void)?
    var remove: (() -> Void)?

    // Clicks go to the words in front (they open the link).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        // As in MxNoteONE, the card shows only in the key window, where you're working.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hover() }
    override func mouseMoved(with event: NSEvent) { hover() }
    override func mouseExited(with event: NSEvent) { LinkHover.shared.pointer(over: nil, rect: .zero, in: self) { LinkHoverActions(edit: {}, remove: {}) } }

    func hover() {
        guard let url else { return }
        LinkHover.shared.pointer(over: url, rect: bounds, in: self) { [weak self] in
            let edit = self?.edit, remove = self?.remove
            return LinkHoverActions(edit: { edit?() }, remove: { remove?() }, tip: self?.tip, text: self?.words, title: self?.title)
        }
    }

    #if DEBUG
    /// Self-tests: the linked words on screen by their test id, to show a hover card without moving the pointer.
    static var anchors: [String: () -> LinkWordsAnchorView?] = [:]

    static func testHover(_ id: String) {
        guard let view = anchors[id]?(), let window = view.window else { return NSSound.beep() }
        let center = window.convertToScreen(view.convert(view.bounds, to: nil))
        LinkHover.testMouse = NSPoint(x: center.midX, y: center.midY)
        view.hover()
    }
    #endif
}

// MARK: - The Link dialog

/// Link / Edit Link, as MxNoteONE's and the securities' (SecurityLinkSheet): the words, the address, the hover text and
/// a preview of the hover card. `save` keeps the link (nil takes it off) and answers why it couldn't, or nil.
struct LinkSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// What the link is on, as the dialog names it, and a line about it.
    let subject: String
    var detail: String? = nil
    let initial: SecurityLink?
    /// The words shown when the link has none of its own.
    let words: String
    var pages: [SecurityPage] = []
    /// Where the link is kept, and so where it shows.
    var whereKept: String
    var save: (SecurityLink?) async -> String?

    @State private var text = ""
    @State private var address = ""
    @State private var page: SecurityPage.ID?
    @State private var tip = NSAttributedString()
    @State private var tipBox = TipEditorBox()
    /// A link copied in MxNoteONE: its title, while the address is that link.
    @State private var noteTitle: String?
    @State private var noteAddress: String?
    /// The pasteboard holds a link copied in MxNoteONE (seen from its types, without reading it).
    @State private var noteOnPasteboard = false
    @State private var saving = false
    @State private var failure: String?

    private var editing: Bool { initial != nil }
    private var url: URL? { LinkRichText.url(fromAddress: address) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(editing ? "Edit Link" : "Link").font(.headline)
            VStack(alignment: .leading, spacing: 1) {
                Text(subject).font(.callout.weight(.semibold))
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Form {
                TextField("Text to display:", text: $text)
                    .help("The words shown for the link (leave them, or empty, to show \(words))")
                TextField("Address:", text: $address, prompt: Text("https://…, an email address, or mxnoteone://…"))
                    .onChange(of: address) {
                        if address != pages.first(where: { $0.id == page })?.address { page = nil }
                        if address != noteAddress { noteTitle = nil; noteAddress = nil }
                    }
                    .help("A web address (https://…), an email address, or a link copied in MxNoteONE (Copy Link to Page, Paragraph, Section or Notebook)")
            }
            if noteOnPasteboard || url?.scheme == LinkInfo.noteScheme {
                HStack(spacing: 8) {
                    if noteOnPasteboard {
                        Button { useCopiedNote() } label: { Label("Use the Link Copied in MxNoteONE", systemImage: "note.text") }
                            .help("The link you copied in MxNoteONE (right-click a page, paragraph, section or notebook ▸ Copy Link to …), with its title")
                    }
                    if let url, url.scheme == LinkInfo.noteScheme {
                        let info = LinkInfo(url, noteTitle: noteTitle)
                        Label(info.title, systemImage: info.symbol).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            .help("Opens in MxNoteONE: \(info.detail.lowercased())")
                    }
                }
            }
            HStack {
                Text("Hover text — shown when the pointer rests on the link:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                TipToolbar(box: tipBox)
            }
            TipEditor(text: $tip, box: tipBox)
                .frame(height: 64)
                .help("Your own description for the link's hover card (optional). Format it with the buttons or ⌘B ⌘I ⌘U; ⌘K (or the link button) links words in it, and addresses typed in it become links.")
            if let url {
                DisclosureGroup("Hover card preview") {
                    LinkCard(info: LinkInfo(url, tip: tip, text: shownText, noteTitle: noteTitle), edit: {}, copy: {}, remove: {}, preview: true)
                        .background(.background, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                        .padding(.vertical, 4)
                }
                .font(.caption)
            }
            if !pages.isEmpty {
                Text("Or link to a page about \(words):")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                List(selection: $page) {
                    ForEach(pages) { p in
                        VStack(alignment: .leading) {
                            Text(p.title)
                            Text(p.address).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        .tag(p.id)
                    }
                }
                .frame(height: CGFloat(min(pages.count, 4)) * 36 + 8)
                .onChange(of: page) { if let p = pages.first(where: { $0.id == page }) { address = p.address } }
                .help("Pick a page to link to it")
            }
            Label(failure ?? whereKept, systemImage: failure == nil ? "externaldrive" : "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(failure == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                .fixedSize(horizontal: false, vertical: true)
                .help("Where this link is kept, and so where it shows")
            HStack {
                if editing {
                    Button("Remove Link", role: .destructive) { finish(nil) }
                        .help("Keep the words, take the link off")
                }
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(editing ? "Update" : "Insert") { insert() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(url == nil || saving)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            text = initial?.text ?? words
            address = initial?.address ?? ""
            tip = initial?.tipText ?? NSAttributedString()
            page = pages.first { $0.address == address }?.id
            noteTitle = initial?.title
            noteAddress = initial?.title == nil ? nil : initial?.address
            checkPasteboard()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in checkPasteboard() }
    }

    /// Whether MxNoteONE's Copy Link put a link on the pasteboard (its title type is there); the pasteboard itself is
    /// read only when you use it.
    private func checkPasteboard() {
        noteOnPasteboard = LinkInfo.pasteboard.types?.contains(LinkInfo.noteTitleType) == true
    }

    /// The link copied in MxNoteONE and its title.
    private func useCopiedNote() {
        let pb = LinkInfo.pasteboard
        let copied = (pb.readObjects(forClasses: [NSURL.self]) as? [URL])?.first?.absoluteString ?? pb.string(forType: .string)
        guard let copied, copied.hasPrefix(LinkInfo.noteScheme + "://") else { return NSSound.beep() }
        noteTitle = pb.string(forType: LinkInfo.noteTitleType)
        noteAddress = copied
        address = copied
    }

    /// The words the link shows: the text to display, or the default words.
    private var shownText: String {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? words : typed
    }

    private func insert() {
        guard let url else { return }
        let shown = shownText
        finish(SecurityLink(address: url.absoluteString, text: shown == words ? nil : shown, tip: LinkRichText.data(tip),
                            title: url.scheme == LinkInfo.noteScheme ? noteTitle : nil))
    }

    private func finish(_ link: SecurityLink?) {
        Task {
            saving = true
            failure = await save(link)
            saving = false
            if failure == nil { dismiss() }
        }
    }
}
