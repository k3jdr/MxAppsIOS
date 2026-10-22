//
//  SecurityLinks.swift
//  MxPortMGR
//
//  Links on a security's symbol and name in the Earnings by Day and My Holdings tables, made and shown as MxNoteONE
//  makes and shows links: ⌘K (Edit ▸ Link…, or a row's context menu) opens the Link dialog — text to display,
//  address, and formatted hover text that can hold links of its own, with a preview of the hover card — and resting
//  the pointer on a linked symbol or name shows the hover card (LinkHover.swift): the hover text, where the link goes,
//  and Edit Link…, Copy and Remove Link. A click on a linked symbol or name opens it. In place of MxNoteONE's list of
//  notebook pages, the dialog offers pages about the security (Nasdaq.com, SEC EDGAR, Yahoo Finance).
//
//  A link belongs to the security and the column, not to the table: a company's symbol link shows in both tables.
//  Real securities (earnings, the security master) share links by ticker; the illustrative universe's made-up ones
//  keep their own. Links are kept on this Mac.
//

import AppKit
import Observation
import SwiftUI

/// What a link is on: a security's symbol or its name.
struct LinkTarget: Hashable, Identifiable {
    enum Field: String, CaseIterable { case symbol, name }
    /// What kind of public pages the security has (none for a made-up one).
    enum Kind { case stock, etf, mutualFund, other }

    /// The security: a real ticker as the earnings sources match it (BRK.B is BRK-B), or "mx:" and a made-up one.
    var security: String
    var symbol: String
    var name: String
    var field: Field
    /// The table's titles for the two columns ("Symbol" and "Company", or "Ticker" and "Name").
    var columns: [String]
    var kind: Kind?

    var id: String { security + "|" + field.rawValue }
    var cellText: String { field == .symbol ? symbol : name }
    var column: String { columns[field == .symbol ? 0 : 1] }

    func with(_ field: Field) -> LinkTarget {
        var t = self
        t.field = field
        return t
    }

    /// A company in Earnings by Day.
    static func earnings(_ e: EarningsEntry, _ field: Field = .symbol) -> LinkTarget {
        LinkTarget(security: e.key, symbol: e.symbol, name: e.name, field: field, columns: ["Symbol", "Company"], kind: .stock)
    }

    /// A holding in My Holdings (none for cash).
    static func holding(_ h: Holding, _ field: Field = .symbol) -> LinkTarget? {
        guard h.ticker != "CASH" else { return nil }
        let s = h.security
        let symbol = s?.displayTicker ?? h.ticker
        let name = s?.name ?? "Unknown — not in the security master"
        guard let s, s.srmID != nil else {
            return LinkTarget(security: "mx:" + h.ticker, symbol: symbol, name: name, field: field, columns: ["Ticker", "Name"], kind: nil)
        }
        let kind: Kind = switch s.securityType {
        case "ETF", "ETN": .etf
        case "Mutual Fund", "Closed-End Fund": .mutualFund
        case "Collective Investment Trust": .other
        default: .stock
        }
        return LinkTarget(security: EarningsParse.key(symbol), symbol: symbol, name: name, field: field, columns: ["Ticker", "Name"], kind: kind)
    }
}

/// A link: where it goes, the words shown for it (the symbol or name when nil), its hover text (RTF), and for a link
/// copied in MxNoteONE the title copied with it (MxPortMGR can't read MxNoteONE's notebooks to look it up).
nonisolated struct SecurityLink: Codable, Equatable, Sendable {
    var address: String
    var text: String?
    var tip: Data?
    var title: String?

    var url: URL? { URL(string: address) }
    var tipText: NSAttributedString? { LinkRichText.text(tip) }
}

@MainActor
@Observable
final class SecurityLinks {
    static let shared = SecurityLinks()

    private static let key = "securityLinks"

    /// Every link, by LinkTarget.id.
    private(set) var links: [String: SecurityLink] = {
        guard let data = UserDefaults.standard.data(forKey: SecurityLinks.key) else { return [:] }
        return (try? JSONDecoder().decode([String: SecurityLink].self, from: data)) ?? [:]
    }()

    /// The Link dialog is open for this.
    var editing: LinkTarget?
    /// The symbol or name cell under the pointer: ⌘K links that column of the selected row.
    @ObservationIgnored var hovered: LinkTarget?

    func link(_ t: LinkTarget) -> SecurityLink? { links[t.id] }

    func set(_ link: SecurityLink?, for t: LinkTarget) {
        links[t.id] = link
        if let data = try? JSONEncoder().encode(links) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    /// Opens the Link dialog (⌘K, Edit Link… on a hover card, a row's context menu).
    func beginEdit(_ t: LinkTarget?) {
        guard let t else { return NSSound.beep() }
        LinkHover.shared.close()
        editing = t
    }

    /// What ⌘K links: the selected row — in the column under the pointer when that is the row's — or else the cell
    /// under the pointer.
    func commandTarget(selected: LinkTarget?) -> LinkTarget? {
        guard let selected else { return hovered }
        if let hovered, hovered.security == selected.security { return hovered }
        return selected
    }

    #if DEBUG
    /// Self-tests: the anchors of the linked cells on screen, to show a hover card without moving the pointer.
    @ObservationIgnored var anchors: [String: () -> LinkAnchorView?] = [:]

    /// Shows the hover card of a linked cell as if the pointer rested on it (launch argument -linkHoverTest ID).
    func testHover(_ id: String) {
        guard let view = anchors[id]?(), let window = view.window else { return NSSound.beep() }
        let center = window.convertToScreen(view.convert(view.bounds, to: nil))
        LinkHover.testMouse = NSPoint(x: center.midX, y: center.midY)
        view.hover()
    }
    #endif
}

// MARK: - Cells

/// A symbol or a name in a table: plain text, or with a link the link's words — a click opens it, the pointer resting
/// on it shows the hover card.
struct LinkedCell: View {
    let target: LinkTarget
    var font: Font = .body
    var bold = false
    var color: Color = .primary
    /// The cell's own tooltip when it has no link (with a link, the hover card says where it goes).
    var help: String?

    var body: some View {
        let links = SecurityLinks.shared
        Group {
            if let link = links.link(target), let url = link.url {
                let words = link.text ?? target.cellText
                Button { LinkInfo.follow(url) } label: {
                    Text(words).font(font).fontWeight(bold ? .bold : .regular).underline()
                        .foregroundStyle(Color(nsColor: .linkColor)).lineLimit(1)
                }
                .buttonStyle(.plain)
                .background(LinkHoverAnchor(url: url, target: target, words: words, tip: link.tipText, title: link.title))
                .accessibilityHint("Link to \(url.absoluteString)")
            } else if let help {
                Text(target.cellText).font(font).fontWeight(bold ? .bold : .regular).foregroundStyle(color).lineLimit(1).help(help)
            } else {
                Text(target.cellText).font(font).fontWeight(bold ? .bold : .regular).foregroundStyle(color).lineLimit(1)
            }
        }
        .onHover { inside in
            if inside { links.hovered = target } else if links.hovered == target { links.hovered = nil }
        }
    }
}

/// Behind a link's words: hears the pointer and shows the hover card, as MxNoteONE's text does.
struct LinkHoverAnchor: NSViewRepresentable {
    let url: URL
    let target: LinkTarget
    let words: String
    let tip: NSAttributedString?
    let title: String?

    func makeNSView(context: Context) -> LinkAnchorView { LinkAnchorView() }

    func updateNSView(_ view: LinkAnchorView, context: Context) {
        view.url = url
        view.target = target
        view.words = words
        view.tip = tip
        view.title = title
        #if DEBUG
        SecurityLinks.shared.anchors[target.id] = { [weak view] in view }
        #endif
    }
}

final class LinkAnchorView: NSView {
    var url: URL?
    var target: LinkTarget?
    var words: String?
    var tip: NSAttributedString?
    var title: String?

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
        guard let url, let target else { return }
        LinkHover.shared.pointer(over: url, rect: bounds, in: self) { [weak self] in
            LinkHoverActions(edit: { SecurityLinks.shared.beginEdit(target) },
                             remove: { SecurityLinks.shared.set(nil, for: target) },
                             tip: self?.tip, text: self?.words, title: self?.title)
        }
    }
}

// MARK: - The Link dialog

/// Pages about a security to link to, in place of MxNoteONE's notebook pages.
struct SecurityPage: Identifiable, Hashable {
    var title: String
    var address: String
    var id: String { address }

    static func pages(_ t: LinkTarget) -> [SecurityPage] {
        guard let kind = t.kind else { return [] }
        let symbol = t.symbol.uppercased()
        let nasdaq = symbol.lowercased().replacingOccurrences(of: "-", with: ".").replacingOccurrences(of: "/", with: ".")
        let dashed = EarningsParse.key(symbol)
        var out: [SecurityPage] = []
        switch kind {
        case .stock:
            out.append(SecurityPage(title: "Nasdaq.com — \(symbol) quote", address: "https://www.nasdaq.com/market-activity/stocks/\(nasdaq)"))
            out.append(SecurityPage(title: "Nasdaq.com — \(symbol) earnings", address: "https://www.nasdaq.com/market-activity/stocks/\(nasdaq)/earnings"))
            out.append(SecurityPage(title: "SEC EDGAR — \(symbol) filings", address: "https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany&CIK=\(dashed)&owner=include&count=40"))
        case .etf:
            out.append(SecurityPage(title: "Nasdaq.com — \(symbol) ETF", address: "https://www.nasdaq.com/market-activity/etf/\(nasdaq)"))
        case .mutualFund:
            out.append(SecurityPage(title: "Nasdaq.com — \(symbol) fund", address: "https://www.nasdaq.com/market-activity/mutual-fund/\(nasdaq)"))
        case .other:
            break
        }
        if kind != .other { out.append(SecurityPage(title: "Yahoo Finance — \(symbol)", address: "https://finance.yahoo.com/quote/\(dashed)/")) }
        let search = (t.name + (kind == .stock ? " investor relations" : "")).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        out.append(SecurityPage(title: kind == .stock ? "\(t.name) — investor relations (web search)" : "\(t.name) (web search)",
                                address: "https://www.google.com/search?q=\(search)"))
        return out
    }
}

/// Link / Edit Link, as MxNoteONE's: the link's words, its address, its hover text, a preview of its hover card.
struct SecurityLinkSheet: View {
    @Environment(\.dismiss) private var dismiss
    let initial: LinkTarget
    @State private var field = LinkTarget.Field.symbol
    @State private var text = ""
    @State private var address = ""
    @State private var page: SecurityPage.ID?
    /// The hover text shown on the link's card.
    @State private var tip = NSAttributedString()
    @State private var tipBox = TipEditorBox()
    /// A link copied in MxNoteONE: its title, while the address is that link.
    @State private var noteTitle: String?
    @State private var noteAddress: String?
    /// The pasteboard holds a link copied in MxNoteONE (seen from its types, without reading it).
    @State private var noteOnPasteboard = false

    private var links: SecurityLinks { .shared }
    private var target: LinkTarget { initial.with(field) }
    private var editing: Bool { links.link(target) != nil }
    private var url: URL? { LinkRichText.url(fromAddress: address) }
    private var pages: [SecurityPage] { SecurityPage.pages(target) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(editing ? "Edit Link" : "Link").font(.headline)
            Form {
                Picker("Link on:", selection: $field) {
                    ForEach(LinkTarget.Field.allCases, id: \.self) { f in
                        Text(initial.columns[f == .symbol ? 0 : 1]).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .help("The link goes on the \(initial.columns[0].lowercased()) or on the \(initial.columns[1].lowercased()); each can have its own")
                TextField("Text to display:", text: $text)
                    .help("The words shown for the link in the table (leave as they are, or empty, to show the \(target.column.lowercased()))")
                TextField("Address:", text: $address, prompt: Text("https://…, mxnoteone://…, or pick a page below"))
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
                Text("Or link to a page about \(target.symbol):")
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
                .frame(height: 140)
                .onChange(of: page) { if let p = pages.first(where: { $0.id == page }) { address = p.address } }
                .help("Pick a page to link to it")
            } else if target.kind == nil {
                Text("\(target.symbol) is a made-up security of the illustrative market: it has no public pages, but any address works.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if editing {
                    Button("Remove Link", role: .destructive) {
                        links.set(nil, for: target)
                        dismiss()
                    }
                    .help("Keep the text, take the link off")
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(editing ? "Update" : "Insert") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(url == nil)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            field = initial.field
            load()
            checkPasteboard()
        }
        .onChange(of: field) { load() }
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

    /// The words the link shows: the text to display, or the symbol or name.
    private var shownText: String {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? target.cellText : words
    }

    /// The link on the chosen column, to edit (or empty for a new one).
    private func load() {
        let link = links.link(target)
        text = link?.text ?? target.cellText
        address = link?.address ?? ""
        tip = link?.tipText ?? NSAttributedString()
        page = pages.first { $0.address == address }?.id
        noteTitle = link?.title
        noteAddress = link?.title == nil ? nil : link?.address
    }

    private func save() {
        guard let url else { return }
        let words = shownText
        links.set(SecurityLink(address: url.absoluteString, text: words == target.cellText ? nil : words, tip: LinkRichText.data(tip),
                               title: url.scheme == LinkInfo.noteScheme ? noteTitle : nil), for: target)
        dismiss()
    }
}

/// A row's context menu: add or edit the link on its symbol or its name (as ⌘K does), and open them.
@ViewBuilder
func linkMenu(_ row: LinkTarget) -> some View {
    let links = SecurityLinks.shared
    ForEach(LinkTarget.Field.allCases, id: \.self) { f in
        let t = row.with(f)
        Button(links.link(t) == nil ? "Add Link to \(t.column)…" : "Edit Link on \(t.column)…") { links.beginEdit(t) }
    }
    let open = LinkTarget.Field.allCases.compactMap { f in links.link(row.with(f))?.url.map { (row.with(f), $0) } }
    if !open.isEmpty {
        Divider()
        ForEach(open, id: \.0) { t, url in
            Button("Open \(t.column) Link") { LinkInfo.follow(url) }
        }
    }
}
