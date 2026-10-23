//
//  ClipboardWindow.swift
//  MxNoteONE
//
//  Edit ▸ Show Clipboard, as in the Finder: a window showing what's on the clipboard — text, styled
//  text, a picture, files, a link, a colour, or MxNoteONE containers (what they are, with a preview) —
//  and, under it, "Clipboard contents: …". It follows the clipboard as it changes. macOS asks before an
//  app reads what other apps copied, so their copies show as a summary (from the kinds of data on the
//  clipboard) with Show Contents, unless MxNoteONE is allowed in System Settings ▸ Privacy & Security
//  ▸ Paste from Other Apps; what's copied in MxNoteONE always shows.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class ClipboardModel {
    static let shared = ClipboardModel()

    /// What the window shows.
    enum Content {
        case empty
        case text(NSAttributedString, styled: Bool)
        case image(NSImage)
        case files([URL])
        case link(URL)
        case color(NSColor)
        /// MxNoteONE containers (or a selection): what they are, and a picture or text of them.
        case notes(title: String, detail: String, symbol: String, preview: Preview?)
        /// Kinds of data MxNoteONE can't show.
        case unknown
        /// Another app's copy, not read yet (macOS asks first).
        case notRead
        /// macOS doesn't let MxNoteONE read other apps' copies.
        case denied
    }

    enum Preview {
        case image(NSImage)
        case text(NSAttributedString)
    }

    /// The clipboard (self-tests use a pasteboard of their own).
    var pasteboard = NSPasteboard.general
    /// Self-tests: as if macOS asked before reading another app's copy (nil: ask macOS).
    var assumeAsks: Bool?

    private(set) var content: Content = .empty
    /// "Clipboard contents: …" (as the Finder says it).
    private(set) var kindName = "none"
    /// Its size: characters, pixels, items.
    private(set) var detail = ""
    /// The kinds of data on the clipboard, with their sizes once read.
    private(set) var types: [(name: String, size: Int?)] = []
    private(set) var isShown = false
    private var changeCount = -1
    private var timer: Timer?

    // MARK: Following the clipboard

    func start() {
        isShown = true
        refresh(userAsked: true)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { ClipboardModel.shared.poll() }
        }
    }

    func stop() {
        isShown = false
        timer?.invalidate()
        timer = nil
    }

    /// A new copy (the change count, which macOS gives freely) is read or summed up.
    func poll() {
        guard pasteboard.changeCount != changeCount else { return }
        // Copied here (while MxNoteONE is in front): ours to read. Copied in another app: as macOS allows.
        refresh(userAsked: false, ours: NSApp.isActive)
    }

    /// Show Contents: reading another app's copy (macOS may ask first).
    func showContents() { refresh(userAsked: true) }

    private var macOSAsks: Bool {
        if let assumeAsks { return assumeAsks }
        guard pasteboard.name == .general else { return false }
        return pasteboard.accessBehavior != .alwaysAllow
    }

    func refresh(userAsked: Bool, ours: Bool = false) {
        changeCount = pasteboard.changeCount
        let available = pasteboard.types ?? []
        types = available.map { ($0.rawValue, nil) }
        let mine = available.contains(PageCanvasView.elementType) || available.contains(ClipboardSelection.type)
        if pasteboard.name == .general, assumeAsks == nil, pasteboard.accessBehavior == .alwaysDeny, !mine, !ours {
            content = .denied
            kindName = Self.summary(available)
            detail = ""
            return
        }
        guard userAsked || ours || mine || !macOSAsks else {
            content = available.isEmpty ? .empty : .notRead
            kindName = Self.summary(available)
            detail = ""
            return
        }
        read(available)
    }

    // MARK: Reading

    /// The size of each kind of data (for the list of them; read only when it's shown).
    func loadSizes() {
        switch content {
        case .notRead, .denied: return
        default: types = (pasteboard.types ?? []).map { ($0.rawValue, pasteboard.data(forType: $0)?.count) }
        }
    }

    private func read(_ available: [NSPasteboard.PasteboardType]) {
        detail = ""
        guard !available.isEmpty else {
            content = .empty
            kindName = "none"
            return
        }
        // The first kind of data MxNoteONE can show, in the clipboard's own order (its preferred one first).
        for type in available {
            switch Self.category(type) {
            case .notes?:
                if readNotes(available) { return }
            case .files?:
                if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
                    content = .files(urls)
                    kindName = urls.count == 1 ? (urls[0].hasDirectoryPath ? "folder" : "file") : "\(urls.count) items"
                    detail = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items"
                    return
                }
            case .image?:
                if let image = NSImage(pasteboard: pasteboard), image.isValid {
                    content = .image(image)
                    kindName = "picture"
                    detail = Self.pixels(image)
                    return
                }
            case .styledText?:
                if let text = (pasteboard.readObjects(forClasses: [NSAttributedString.self]) as? [NSAttributedString])?.first, text.length > 0 {
                    content = .text(text, styled: true)
                    kindName = "styled text"
                    detail = Self.count(text.string)
                    return
                }
            case .text?:
                if let s = pasteboard.string(forType: .string) {
                    content = .text(NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.textColor]), styled: false)
                    kindName = "text"
                    detail = Self.count(s)
                    return
                }
            case .link?:
                if let url = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first {
                    content = .link(url)
                    kindName = "URL"
                    detail = url.host() ?? ""
                    return
                }
            case .color?:
                if let color = (pasteboard.readObjects(forClasses: [NSColor.self]) as? [NSColor])?.first ?? NSColor(from: pasteboard) {
                    content = .color(color)
                    kindName = "color"
                    detail = DBMLColor.hexString(color)
                    return
                }
            case nil:
                continue
            }
        }
        content = .unknown
        kindName = "unknown"
    }

    enum Category { case notes, files, image, styledText, text, link, color }

    static func category(_ type: NSPasteboard.PasteboardType) -> Category? {
        switch type {
        case PageCanvasView.elementType, ClipboardSelection.type: return .notes
        case .fileURL, NSPasteboard.PasteboardType("NSFilenamesPboardType"): return .files
        case .rtfd, .rtf, .html, NSPasteboard.PasteboardType("com.apple.webarchive"), NSPasteboard.PasteboardType("com.apple.flat-rtfd"): return .styledText
        case .string: return .text
        case .URL: return .link
        case .color: return .color
        case .tiff, .png, .pdf: return .image
        default:
            if let t = UTType(type.rawValue), t.conforms(to: .image) { return .image }
            return nil
        }
    }

    /// What's on the clipboard, from the kinds of data alone (nothing read).
    static func summary(_ available: [NSPasteboard.PasteboardType]) -> String {
        if available.contains(ClipboardSelection.type) { return "MxNoteONE selection" }
        if available.contains(PageCanvasView.elementType) { return "MxNoteONE container" }
        for type in available {
            switch category(type) {
            case .files?: return "files"
            case .image?: return "picture"
            case .styledText?: return "styled text"
            case .text?: return "text"
            case .link?: return "URL"
            case .color?: return "color"
            case .notes?, nil: continue
            }
        }
        return available.isEmpty ? "none" : "unknown"
    }

    /// MxNoteONE containers: what they are, with the picture or text copied with them.
    private func readNotes(_ available: [NSPasteboard.PasteboardType]) -> Bool {
        let decoder = JSONDecoder()
        if let data = pasteboard.data(forType: ClipboardSelection.type), let selection = try? decoder.decode(ClipboardSelection.self, from: data) {
            let kinds = selection.elements.map { Self.describe($0.element).name }
            var parts: [String] = []
            if !kinds.isEmpty { parts.append("\(kinds.count) container\(kinds.count == 1 ? "" : "s")") }
            if !selection.strokes.isEmpty { parts.append("\(selection.strokes.count) ink stroke\(selection.strokes.count == 1 ? "" : "s")") }
            content = .notes(title: "MxNoteONE selection", detail: (parts.joined(separator: " and ") + (kinds.isEmpty ? "" : ": " + Self.list(kinds))),
                             symbol: "lasso", preview: preview(available))
            kindName = "MxNoteONE selection"
            detail = parts.joined(separator: ", ")
            return true
        }
        if let data = pasteboard.data(forType: PageCanvasView.elementType), let clip = try? decoder.decode(ClipboardElement.self, from: data) {
            let d = Self.describe(clip.element)
            var shown = preview(available)
            if shown == nil, clip.element.kind == .image, let asset = clip.assetData, let image = NSImage(data: asset) { shown = .image(image) }
            content = .notes(title: d.title, detail: d.detail, symbol: d.symbol, preview: shown)
            kindName = "MxNoteONE " + d.name
            detail = d.detail
            return true
        }
        return false
    }

    /// The picture or text copied with containers.
    private func preview(_ available: [NSPasteboard.PasteboardType]) -> Preview? {
        if available.contains(where: { Self.category($0) == .image }), let image = NSImage(pasteboard: pasteboard), image.isValid { return .image(image) }
        if let text = (pasteboard.readObjects(forClasses: [NSAttributedString.self]) as? [NSAttributedString])?.first, text.length > 0 { return .text(text) }
        return nil
    }

    /// A container in words: its kind, a title for it, what's in it, and a symbol.
    static func describe(_ e: PageElement) -> (name: String, title: String, detail: String, symbol: String) {
        switch e.kind {
        case .text:
            let words = e.rtfd.flatMap { NoteRichText.text($0)?.string } ?? ""
            return ("text box", "Text box", count(words), "text.alignleft")
        case .image:
            return ("picture", "Picture", e.fileName ?? "", "photo")
        case .file:
            return ("file attachment", "File attachment", e.fileName ?? "", "paperclip")
        case .audio:
            return ("recording", "Audio recording", e.fileName ?? "", "waveform")
        case .video:
            return ("video", "Video", e.fileName ?? "", "film")
        case .table:
            let rows = e.table?.rows.count ?? 0, columns = e.table?.rows.first?.count ?? 0
            return ("table", "Table", "\(rows) row\(rows == 1 ? "" : "s") × \(columns) column\(columns == 1 ? "" : "s")", "tablecells")
        case .chart:
            let title = e.chart.map { $0.title.isEmpty ? $0.kind.title + " chart" : $0.title } ?? "Chart"
            return ("chart", "Chart", title, "chart.bar")
        case .score:
            return ("score", "Music score", e.score.map { $0.title.isEmpty ? $0.summary : $0.title } ?? "", "music.note.list")
        case .diagram:
            return ("diagram", "draw.io diagram", e.fileName ?? "", "point.3.connected.trianglepath.dotted")
        case .model:
            return ("3D model", "3D model", e.cad?.name ?? "", "cube")
        case .map:
            let pins = e.map?.pins.count ?? 0
            return ("map", "Map", (e.map?.title.map { $0 + ", " } ?? "") + "\(pins) pin\(pins == 1 ? "" : "s")", "map")
        case .dbml:
            let schema = e.dbml.map { DBMLParser.parse(DBMLFileLayout.split($0.source).body) }
            let tables = schema?.tables.count ?? 0, refs = schema?.refs.count ?? 0
            let schemas = schema?.schemas ?? []
            return ("DBML diagram", "DBML diagram" + (e.dbml?.title.map { " “\($0)”" } ?? ""),
                    "\(tables) table\(tables == 1 ? "" : "s"), \(refs) relationship\(refs == 1 ? "" : "s")"
                        + (schemas.count > 1 || schemas.first != "public" ? " · " + schemas.joined(separator: ", ") : ""), "cylinder.split.1x2")
        }
    }

    static func list(_ names: [String]) -> String {
        var counts: [(String, Int)] = []
        for n in names { if let i = counts.firstIndex(where: { $0.0 == n }) { counts[i].1 += 1 } else { counts.append((n, 1)) } }
        return counts.map { $0.1 == 1 ? $0.0 : "\($0.1) \($0.0)s" }.joined(separator: ", ")
    }

    static func count(_ s: String) -> String {
        let lines = s.isEmpty ? 0 : s.components(separatedBy: .newlines).count
        return "\(s.count.formatted()) character\(s.count == 1 ? "" : "s")" + (lines > 1 ? ", \(lines.formatted()) lines" : "")
    }

    static func pixels(_ image: NSImage) -> String {
        if let rep = image.representations.first, rep.pixelsWide > 0 { return "\(rep.pixelsWide) × \(rep.pixelsHigh) pixels" }
        return "\(Int(image.size.width)) × \(Int(image.size.height)) points"
    }
}

// MARK: - The window

struct ClipboardView: View {
    @Bindable private var model = ClipboardModel.shared
    @State private var showsTypes = false

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
            Divider()
            HStack(spacing: 8) {
                Text("Clipboard contents: \(model.kindName)")
                    .lineLimit(1)
                Spacer(minLength: 8)
                if !model.detail.isEmpty {
                    Text(model.detail)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button { showsTypes.toggle() } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.borderless)
                    .help("The kinds of data on the clipboard")
                    .disabled(model.types.isEmpty)
                    .popover(isPresented: $showsTypes, arrowEdge: .top) { typeList.onAppear { model.loadSizes() } }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .frame(minWidth: 360, minHeight: 220)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    @ViewBuilder private var content: some View {
        switch model.content {
        case .empty:
            message("The clipboard is empty.", symbol: "clipboard")
        case .text(let text, _):
            ClipboardTextView(text: text)
        case .image(let image):
            ClipboardPicture(image: image)
        case .files(let urls):
            List(urls, id: \.self) { url in
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(url.lastPathComponent).lineLimit(1)
                        Text(url.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
        case .link(let url):
            VStack(spacing: 8) {
                Image(systemName: "link").font(.system(size: 28)).foregroundStyle(.secondary)
                Link(url.absoluteString, destination: url).lineLimit(3).multilineTextAlignment(.center)
            }
            .padding()
        case .color(let color):
            VStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: color)).frame(width: 120, height: 80)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                Text(DBMLColor.hexString(color)).font(.system(.body, design: .monospaced))
            }
        case .notes(let title, let detail, let symbol, let preview):
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(Color.accentColor).frame(width: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.headline)
                        if !detail.isEmpty { Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
                        Text("Paste it onto a page (⌘V) to place a copy there.").font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .padding(12)
                Divider()
                switch preview {
                case .image(let image)?: ClipboardPicture(image: image)
                case .text(let text)?: ClipboardTextView(text: text)
                case nil: Spacer()
                }
            }
        case .unknown:
            message("MxNoteONE can't show this kind of data.", symbol: "questionmark.square.dashed",
                    detail: model.types.map(\.name).prefix(6).joined(separator: "\n"))
        case .notRead:
            VStack(spacing: 10) {
                Image(systemName: "eye.slash").font(.system(size: 28)).foregroundStyle(.secondary)
                Text("Another app copied \(copied(model.kindName)).").font(.headline)
                Button("Show Contents") { model.showContents() }
                    .keyboardShortcut(.defaultAction)
                Text("macOS asks before MxNoteONE reads what other apps copied. To see each copy as it's made, allow MxNoteONE in System Settings ▸ Privacy & Security ▸ Paste from Other Apps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            .padding()
        case .denied:
            message("macOS doesn't let MxNoteONE read what other apps copy.", symbol: "hand.raised",
                    detail: "Allow it in System Settings ▸ Privacy & Security ▸ Paste from Other Apps.")
        }
    }

    /// “Another app copied …”: the kind of data, as a phrase.
    private func copied(_ kind: String) -> String {
        switch kind {
        case "text", "styled text": "some \(kind)"
        case "files": "files"
        case "unknown": "data of a kind MxNoteONE can't show"
        case "MxNoteONE selection", "MxNoteONE container": "an \(kind)"
        default: "a \(kind)"
        }
    }

    private func message(_ text: String, symbol: String, detail: String? = nil) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary)
            if let detail, !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            }
        }
        .padding()
    }

    private var typeList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("On the clipboard").font(.headline)
            ForEach(Array(model.types.enumerated()), id: \.offset) { _, t in
                HStack {
                    Text(t.name).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                    Spacer(minLength: 16)
                    if let size = t.size {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .frame(minWidth: 320)
    }
}

/// A picture as big as it is, smaller to fit the window.
struct ClipboardPicture: View {
    let image: NSImage

    var body: some View {
        GeometryReader { geo in
            let size = image.size
            let scale = min(1, (geo.size.width - 24) / max(size.width, 1), (geo.size.height - 24) / max(size.height, 1))
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: max(1, size.width * scale), height: max(1, size.height * scale))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Text (formatted, as copied) to read and select, not edit.
struct ClipboardTextView: NSViewRepresentable {
    let text: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        if let tv = scroll.documentView as? NSTextView {
            tv.isEditable = false
            tv.isSelectable = true
            tv.isRichText = true
            tv.drawsBackground = true
            tv.backgroundColor = .textBackgroundColor
            tv.textContainerInset = NSSize(width: 8, height: 8)
            tv.setAccessibilityLabel("Clipboard contents")
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView, tv.textStorage?.isEqual(to: text) != true else { return }
        tv.textStorage?.setAttributedString(text)
    }
}
