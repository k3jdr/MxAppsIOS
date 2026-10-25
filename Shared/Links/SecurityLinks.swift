//
//  SecurityLinks.swift
//  Shared by MxAcctMGR and MxDataHUB (MxAppsIOS/Shared/Links)
//
//  Links on a security's ticker and name in the apps' tables (MxDataHUB: Securities, Portfolios ▸ Holdings; MxAcctMGR:
//  My Holdings, Earnings by Day), made and shown as MxNoteONE makes and shows links: ⌘K (Edit ▸ Link…, or a row's
//  context menu) opens the Link dialog — text to display, address, and formatted hover text that can hold links of its
//  own, with a preview of the hover card — and resting the pointer on a linked ticker or name shows the hover card
//  (LinkHover.swift): the hover text, where the link goes, and Edit Link…, Copy and Remove Link. A click on a linked
//  ticker or name opens it. In place of MxNoteONE's list of notebook pages, the dialog offers pages about the security
//  (Nasdaq.com, SEC EDGAR, Yahoo Finance) and a link copied in MxNoteONE.
//
//  A link belongs to the security and the column, not to a table or an app: it is kept in the security master
//  (srm.security_link, migration V014), through the app's backend — MxDataHUB's own database connection, MxAcctMGR's
//  accounts service — so it shows wherever the security is listed. Securities the security master doesn't have (the
//  illustrative market's made-up ones, a ticker it doesn't list) keep their links on this Mac; so does a link saved
//  while the security master can't be reached, until it can.
//

import AppKit
import Observation
import SwiftUI

/// What a link is on: a security's ticker (symbol) or its name.
struct LinkTarget: Hashable, Identifiable {
    enum Field: String, CaseIterable, Sendable {
        case symbol, name

        /// The column's name in srm.security_link.
        var column: String { self == .symbol ? "ticker" : "name" }
        init?(column: String) { self.init(rawValue: column == "ticker" ? "symbol" : column) }
    }
    /// What kind of public pages the security has (none for a made-up one).
    enum Kind { case stock, etf, mutualFund, other }

    /// The security on this Mac: a real ticker as the apps match it (BRK.B is BRK-B), or "mx:" and a made-up one.
    var security: String
    /// The security in the security master, when the table knows it; else it is looked up by `security` (a ticker).
    var securityID: Int64?
    var symbol: String
    var name: String
    var field: Field
    /// The table's titles for the two columns ("Symbol" and "Company", or "Ticker" and "Name").
    var columns: [String]
    var kind: Kind?

    var id: String { security + "|" + field.rawValue }
    var cellText: String { field == .symbol ? symbol : name }
    var column: String { columns[field == .symbol ? 0 : 1] }
    /// A made-up security of MxAcctMGR's illustrative market: its links stay on this Mac.
    var isMadeUp: Bool { security.hasPrefix("mx:") }

    func with(_ field: Field) -> LinkTarget {
        var t = self
        t.field = field
        return t
    }

    /// A ticker as the apps match it: upper case, share classes with "-" (BRK.B, BRK/B → BRK-B).
    static func key(_ ticker: String) -> String {
        ticker.trimmingCharacters(in: .whitespaces).uppercased()
            .replacingOccurrences(of: ".", with: "-").replacingOccurrences(of: "/", with: "-")
    }
}

/// A link: where it goes, the words shown for it (the ticker or name when nil), its hover text (RTF), and for a link
/// copied in MxNoteONE the title copied with it (these apps can't read MxNoteONE's notebooks to look it up).
nonisolated struct SecurityLink: Codable, Equatable, Sendable {
    var address: String
    var text: String?
    var tip: Data?
    var title: String?

    var url: URL? { URL(string: address) }
    var tipText: NSAttributedString? { LinkRichText.text(tip) }
    /// The hover text as plain text (kept beside the RTF in the security master, to read and search).
    var tipPlain: String? { tipText.map(\.string).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } }
}

/// Where an app keeps links in the security master: its own database connection (MxDataHUB) or a service (MxAcctMGR).
protocol SecurityLinkBackend: Sendable {
    /// What it is, for messages ("the security master", "the accounts service").
    var name: String { get }
    /// The links on these securities, by id or by ticker; tickers are looked up to their securities (`resolved`).
    func links(securityIDs: [Int64], tickers: [String]) async throws -> (resolved: [String: Int64], links: [Int64: [LinkTarget.Field: SecurityLink]])
    func save(_ link: SecurityLink, securityID: Int64, field: LinkTarget.Field) async throws
    func delete(securityID: Int64, field: LinkTarget.Field) async throws
}

@MainActor
@Observable
final class SecurityLinks {
    static let shared = SecurityLinks()

    private static let key = "securityLinks"

    /// Where links on securities of the security master are kept; nil keeps every link on this Mac.
    @ObservationIgnored private(set) var backend: SecurityLinkBackend?

    /// What saving a link did.
    enum Saved: Equatable {
        case saved
        /// Kept on this Mac for now: the security master couldn't be reached (it goes there on the next load).
        case keptHere(String)
        case failed(String)
    }

    /// Uses another backend (connected to another database, or disconnected): what was loaded from the last one goes.
    func use(_ backend: SecurityLinkBackend?) {
        self.backend = backend
        remote = [:]
        resolved = [:]
        unknown = []
        problem = nil
    }

    /// Links kept on this Mac, by LinkTarget.id: made-up securities, tickers the security master doesn't list, and
    /// links waiting to go to the security master.
    private(set) var local: [String: SecurityLink] = {
        guard let data = UserDefaults.standard.data(forKey: SecurityLinks.key) else { return [:] }
        return (try? JSONDecoder().decode([String: SecurityLink].self, from: data)) ?? [:]
    }()
    /// Links in the security master, by security and field, as far as they have been loaded.
    private(set) var remote: [Int64: [LinkTarget.Field: SecurityLink]] = [:]
    /// Tickers looked up in the security master (LinkTarget.key → security), and those it doesn't list.
    private(set) var resolved: [String: Int64] = [:]
    private var unknown: Set<String> = []
    /// Why the security master couldn't be reached, the last time it was tried.
    var problem: String?

    /// The Link dialog is open for this.
    var editing: LinkTarget?
    /// The ticker or name cell under the pointer: ⌘K links that column of the selected row.
    @ObservationIgnored var hovered: LinkTarget?

    /// The target's security in the security master, if it is known or has been looked up.
    func securityID(_ t: LinkTarget) -> Int64? {
        guard !t.isMadeUp else { return nil }
        return t.securityID ?? resolved[t.security]
    }

    func link(_ t: LinkTarget) -> SecurityLink? {
        if let id = securityID(t), let link = remote[id]?[t.field] { return link }
        return local[t.id]
    }

    /// Where the target's link is kept, in words (for the Link dialog).
    func whereKept(_ t: LinkTarget) -> String {
        if t.isMadeUp { return "Kept on this Mac: the security is a made-up one of the illustrative market." }
        guard let backend else { return "Kept on this Mac." }
        if securityID(t) != nil { return "Kept in the security master (through \(backend.name)): it shows in MxDataHUB and MxAcctMGR." }
        if unknown.contains(t.security) { return "Kept on this Mac: the security master doesn't list \(t.symbol)." }
        return "Kept on this Mac until the security master can be reached (\(backend.name))."
    }

    /// Loads the links on these securities from the security master, and sends it links kept on this Mac for them.
    func load(securityIDs: [Int64] = [], tickers: [String] = []) async {
        guard let backend else { return }
        let keys = Set(tickers.map(LinkTarget.key)).subtracting(resolved.keys).subtracting(unknown)
        // Links kept here for real tickers go with the first load.
        let pending = Set(local.keys.compactMap { id -> String? in
            let security = String(id.split(separator: "|").first ?? "")
            return security.hasPrefix("mx:") || resolved[security] != nil || unknown.contains(security) ? nil : security
        })
        let ask = keys.union(pending)
        guard !securityIDs.isEmpty || !ask.isEmpty else { return }
        do {
            let answer = try await backend.links(securityIDs: securityIDs, tickers: Array(ask))
            for (ticker, id) in answer.resolved { resolved[LinkTarget.key(ticker)] = id }
            unknown.formUnion(ask.filter { resolved[$0] == nil })
            for (id, links) in answer.links { remote[id] = links }
            for id in Set(securityIDs).union(answer.resolved.values) where answer.links[id] == nil { remote[id] = [:] }
            problem = nil
            await sendKept()
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Links kept on this Mac for securities now found in the security master go there (unless it already has one).
    private func sendKept() async {
        guard let backend else { return }
        for (id, link) in local {
            let parts = id.split(separator: "|").map(String.init)
            guard parts.count == 2, let field = LinkTarget.Field(rawValue: parts[1]), let securityID = resolved[parts[0]] else { continue }
            if remote[securityID]?[field] == nil {
                do { try await backend.save(link, securityID: securityID, field: field) } catch { problem = error.localizedDescription; return }
                remote[securityID, default: [:]][field] = link
            }
            local[id] = nil
        }
        saveLocal()
    }

    /// Saves (or with nil removes) the target's link: in the security master when the security is there, else on this
    /// Mac. A link that can't reach the security master is kept here and sent later; removing one there needs it.
    @discardableResult
    func set(_ link: SecurityLink?, for t: LinkTarget) async -> Saved {
        if let backend, let id = securityID(t) {
            do {
                if let link { try await backend.save(link, securityID: id, field: t.field) } else { try await backend.delete(securityID: id, field: t.field) }
                remote[id, default: [:]][t.field] = link
                local[t.id] = nil
                saveLocal()
                problem = nil
                return .saved
            } catch {
                problem = error.localizedDescription
                guard let link else { return .failed(error.localizedDescription) }
                local[t.id] = link
                saveLocal()
                return .keptHere(error.localizedDescription)
            }
        }
        local[t.id] = link
        saveLocal()
        return .saved
    }

    private func saveLocal() {
        if let data = try? JSONEncoder().encode(local) { UserDefaults.standard.set(data, forKey: Self.key) }
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

/// A ticker or a name in a table: plain text, or with a link the link's words — a click opens it, the pointer resting
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
                // A click on the words follows the link, even on a screen whose text is selectable.
                .textSelection(.disabled)
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
                             remove: { Task { await SecurityLinks.shared.set(nil, for: target) } },
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
        let dashed = LinkTarget.key(symbol)
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
    @State private var saving = false
    @State private var failure: String?
    /// Saved, but only on this Mac: the dialog stays to say so, and closes with Done.
    @State private var kept = false

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
            Label(failure ?? links.whereKept(target), systemImage: failure == nil ? "externaldrive" : "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(failure == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                .fixedSize(horizontal: false, vertical: true)
                .help("Where this link is kept, and so where it shows")
            HStack {
                if editing {
                    Button("Remove Link", role: .destructive) {
                        Task {
                            saving = true
                            if case .failed(let why) = await links.set(nil, for: target) {
                                failure = "Couldn't take it off in the security master: " + why
                            } else {
                                dismiss()
                            }
                            saving = false
                        }
                    }
                    .help("Keep the text, take the link off")
                }
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                if kept {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button(editing ? "Update" : "Insert") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(url == nil || saving)
                }
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

    /// The words the link shows: the text to display, or the ticker or name.
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
        failure = nil
    }

    private func save() {
        guard let url else { return }
        let words = shownText
        let link = SecurityLink(address: url.absoluteString, text: words == target.cellText ? nil : words, tip: LinkRichText.data(tip),
                                title: url.scheme == LinkInfo.noteScheme ? noteTitle : nil)
        Task {
            saving = true
            let saved = await links.set(link, for: target)
            saving = false
            if case .keptHere(let why) = saved {
                // Say so, rather than closing as if it had gone to the security master.
                failure = "Saved on this Mac for now: the security master couldn't be reached (\(why)). It goes there when it can."
                kept = true
            } else {
                dismiss()
            }
        }
    }
}

/// A row's context menu: add or edit the link on its ticker or its name (as ⌘K does), and open them.
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
