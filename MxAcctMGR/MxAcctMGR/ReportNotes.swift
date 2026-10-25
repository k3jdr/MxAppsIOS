//
//  ReportNotes.swift
//  MxAcctMGR
//
//  Your own notes on a report, in Knowledge Library ▸ Report Library ("Which drivers each report moves"): right-click a
//  report's name to add or edit them — formatted text that can hold links of its own (web pages, email, pages in
//  MxNoteONE), written as a link's hover text is (Shared/Links/LinkTips.swift) — and resting the pointer on the name
//  shows them on a hover card, as MxNoteONE shows a link's hover text, beside what the report is: its publisher, how
//  often it comes out, the drivers it moves, its impact and its official source. Kept on this Mac.
//

import AppKit
import Observation
import SwiftUI

/// Notes on a report: formatted text (RTF) and when it was last changed.
nonisolated struct ReportNote: Codable, Equatable, Sendable {
    var text: Data
    var changed: Date

    var attributed: NSAttributedString? { LinkRichText.text(text) }
}

@MainActor
@Observable
final class ReportNotes {
    static let shared = ReportNotes()

    private static let key = "reportNotes"

    /// By MarketReport.id.
    private(set) var notes: [String: ReportNote] = {
        guard let data = UserDefaults.standard.data(forKey: ReportNotes.key) else { return [:] }
        return (try? JSONDecoder().decode([String: ReportNote].self, from: data)) ?? [:]
    }()

    /// The Notes dialog is open for this report.
    var editing: MarketReport?

    func note(_ id: String) -> ReportNote? { notes[id] }

    /// Saves the notes on a report; empty text (or nil) removes them.
    func set(_ text: NSAttributedString?, for id: String) {
        if let data = LinkRichText.data(text) { notes[id] = ReportNote(text: data, changed: Date()) } else { notes[id] = nil }
        if let data = try? JSONEncoder().encode(notes) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    /// Opens the Notes dialog (right-click ▸ Add Notes… or Edit Notes…, or the hover card's button).
    func beginEdit(_ r: MarketReport) {
        LinkHover.shared.close()
        editing = r
    }

    #if DEBUG
    /// Self-tests: the anchors of the reports' names on screen, to show a hover card without moving the pointer.
    @ObservationIgnored var anchors: [String: () -> ReportAnchorView?] = [:]

    /// Shows a report's hover card as if the pointer rested on its name (launch argument -reportHoverTest ID).
    func testHover(_ id: String) {
        guard let view = anchors[id]?(), let window = view.window else { return NSSound.beep() }
        let center = window.convertToScreen(view.convert(view.bounds, to: nil))
        LinkHover.testMouse = NSPoint(x: center.midX, y: center.midY)
        view.hover()
    }
    #endif
}

// MARK: - The report's name

/// A report's name in the table: a click opens its walkthrough, a right-click offers its notes and official source,
/// and the pointer resting on it shows its hover card. A note mark follows the name of a report with notes.
struct ReportLink: View {
    let report: MarketReport
    let open: () -> Void

    var body: some View {
        let note = ReportNotes.shared.note(report.id)
        HStack(spacing: 4) {
            Button(report.title, action: open)
                .buttonStyle(.link)
                .font(.callout)
                .background(ReportHoverAnchor(report: report, note: note, open: open))
                .contextMenu { reportMenu(report, open: open) }
                .accessibilityHint(note == nil ? "Opens its walkthrough" : "Opens its walkthrough. Has your notes.")
            if note != nil {
                Image(systemName: "text.bubble")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Your notes on this report: rest the pointer on its name to read them, right-click it to edit them")
            }
        }
    }
}

/// A report's context menu: its notes, its walkthrough, its official source.
@ViewBuilder
func reportMenu(_ r: MarketReport, open: @escaping () -> Void) -> some View {
    let notes = ReportNotes.shared
    Button(notes.note(r.id) == nil ? "Add Notes…" : "Edit Notes…") { notes.beginEdit(r) }
    Divider()
    Button("Open Walkthrough", action: open)
    if let source = r.sources.first {
        Button("Open Official Source (\(source.publisher))") { LinkInfo.follow(source.url) }
        Button("Copy Official Source Address") { LinkInfo.copy(source.url) }
    }
}

/// Behind a report's name: hears the pointer and shows the hover card, as a link's words do (LinkAnchorView).
struct ReportHoverAnchor: NSViewRepresentable {
    let report: MarketReport
    let note: ReportNote?
    let open: () -> Void

    func makeNSView(context: Context) -> ReportAnchorView { ReportAnchorView() }

    func updateNSView(_ view: ReportAnchorView, context: Context) {
        view.report = report
        view.note = note
        view.open = open
        #if DEBUG
        ReportNotes.shared.anchors[report.id] = { [weak view] in view }
        #endif
    }
}

final class ReportAnchorView: NSView {
    var report: MarketReport?
    var note: ReportNote?
    var open: (() -> Void)?

    // Clicks go to the name in front (it opens the walkthrough).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hover() }
    override func mouseMoved(with event: NSEvent) { hover() }
    override func mouseExited(with event: NSEvent) { LinkHover.shared.pointer(over: nil, rect: .zero, in: self, card: { _ in AnyView(EmptyView()) }) }

    func hover() {
        guard let report, let key = URL(string: "mxacctmgr://report/" + report.id) else { return }
        let note = note, open = open
        LinkHover.shared.pointer(over: key, rect: bounds, in: self, card: { close in
            AnyView(ReportCard(report: report, note: note?.attributed, changed: note?.changed,
                               open: { close(); open?() },
                               edit: { close(); ReportNotes.shared.beginEdit(report) },
                               follow: { url in close(); LinkInfo.follow(url) }))
        })
    }
}

// MARK: - The hover card

/// A report's hover card: your notes, what the report is, and buttons for its notes and walkthrough.
struct ReportCard: View {
    let report: MarketReport
    let note: NSAttributedString?
    var changed: Date?
    var preview = false
    var open: () -> Void = {}
    var edit: () -> Void = {}
    /// Opens a link in the notes or the official source (none in the dialog's preview).
    var follow: ((URL) -> Void)?

    private var hasNote: Bool { note.map { !$0.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let note, hasNote {
                TipText(text: note, open: follow)
                if let changed {
                    Text("Your notes · \(changed.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Divider()
            }
            HStack(spacing: 6) {
                Image(systemName: report.symbol)
                    .foregroundStyle(Color.accentColor)
                Text(report.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            Text([report.publisher, report.frequency].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Text("Moves " + report.drivers.map { $0.rawValue.lowercased() }.joined(separator: ", ") + " · impact " + ["", "low", "medium", "high"][report.impact])
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            if let source = report.sources.first {
                Button { follow?(source.url) } label: {
                    Label("\(source.publisher): \(source.title)", systemImage: "arrow.up.right.square").lineLimit(1)
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
                .help("The official source: \(source.address)")
            }
            Text("Click to open the walkthrough · right-click for more")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Divider()
            HStack(spacing: 4) {
                Button(action: edit) { Label(hasNote ? "Edit Notes…" : "Add Notes…", systemImage: "pencil") }
                    .help("Your notes on this report, shown on this card (or right-click the report's name)")
                Button(action: open) { Label("Open Walkthrough", systemImage: "play.rectangle") }
                    .help("Read the report and simulate your reaction")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .focusable(false)
            .fixedSize()
            .disabled(preview)
        }
        .padding(10)
        // A set width, so the card's height is measured with its lines wrapped as shown: sized from its unwrapped
        // width, the publisher's line wrapped once shown and pushed the buttons off the card's bottom.
        .frame(width: 360, alignment: .leading)
    }
}

// MARK: - The Notes dialog

/// Add Notes / Edit Notes: formatted text, with links of its own, and a preview of the hover card.
struct ReportNotesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let report: MarketReport
    @State private var text = NSAttributedString()
    @State private var box = TipEditorBox()

    private var notes: ReportNotes { .shared }
    private var editing: Bool { notes.note(report.id) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editing ? "Edit Notes" : "Add Notes").heading(.name)
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: report.symbol).font(.title3).foregroundStyle(Color.accentColor).frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(report.title).font(.callout.weight(.semibold))
                    Text([report.publisher, report.frequency].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            HStack {
                Text("Your notes — shown on the report's hover card:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                TipToolbar(box: box)
            }
            TipEditor(text: $text, box: box)
                .frame(height: 140)
                .help("What you want to remember about this report: what to watch, how you read it, links to your own notes. Format it with the buttons or ⌘B ⌘I ⌘U; ⌘K (or the link button) links words in it, and addresses typed in it become links — a page in MxNoteONE too (mxnoteone://…).")
            DisclosureGroup("Hover card preview") {
                ReportCard(report: report, note: text, changed: Date(), preview: true)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                    .padding(.vertical, 4)
            }
            .font(.caption)
            Label("Kept on this Mac.", systemImage: "internaldrive")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Where these notes are kept")
            HStack {
                if editing {
                    Button("Remove Notes", role: .destructive) {
                        notes.set(nil, for: report.id)
                        dismiss()
                    }
                    .help("Take the notes off this report")
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(editing ? "Update" : "Save") {
                    notes.set(text, for: report.id)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { text = notes.note(report.id)?.attributed ?? NSAttributedString() }
    }
}
