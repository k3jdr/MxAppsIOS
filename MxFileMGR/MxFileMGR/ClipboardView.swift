//
//  ClipboardView.swift
//  MxFileMGR
//
//  Edit ▸ Show Clipboard, as in Finder: a window telling what's on the clipboard — files, a picture, styled or
//  plain text, a web link, a colour — and showing it, kept current while the window is open. For copied files it
//  can also paste or move them into the active pane's folder. macOS sends no notification when the clipboard
//  changes, so the window checks NSPasteboard.changeCount twice a second while it is open.
//

import AppKit
import SwiftUI

@Observable
final class ClipboardMonitor {
    enum Content {
        case empty
        case files([URL])
        case image(NSImage, String)            // image, "PNG · 640 × 480"
        case richText(NSAttributedString)
        case text(String)
        case link(URL)
        case color(NSColor)
        case other
    }

    private(set) var content: Content = .empty
    private(set) var types: [String] = []
    private(set) var changeCount = -1

    /// Text beyond this many characters is shown cut short (the clipboard keeps all of it).
    static let textLimit = 1_000_000

    /// Re-reads the clipboard if it changed since the last look.
    func check() {
        let pb = NSPasteboard.general
        guard pb.changeCount != changeCount else { return }
        changeCount = pb.changeCount
        types = (pb.types ?? []).map(\.rawValue)
        content = Self.read(pb)
    }

    func clear() {
        NSPasteboard.general.clearContents()
        check()
    }

    private static func read(_ pb: NSPasteboard) -> Content {
        guard let types = pb.types, !types.isEmpty else { return .empty }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return .files(urls)
        }
        if NSImage.canInit(with: pb), let image = NSImage(pasteboard: pb) {
            let kind = types.contains(.png) ? "PNG" : types.contains(.tiff) ? "TIFF" : types.contains(.pdf) ? "PDF" : "Picture"
            let rep = image.representations.first
            let pixels = rep.map { "\($0.pixelsWide) × \($0.pixelsHigh)" } ?? "\(Int(image.size.width)) × \(Int(image.size.height))"
            return .image(image, "\(kind) · \(pixels)")
        }
        if types.contains(.rtf) || types.contains(.rtfd) || types.contains(.html),
           let attributed = pb.readObjects(forClasses: [NSAttributedString.self])?.first as? NSAttributedString,
           attributed.length > 0 {
            return .richText(attributed)
        }
        if let string = pb.string(forType: .string) {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed),
               let scheme = url.scheme?.lowercased(), ["http", "https", "mailto", "ftp"].contains(scheme) {
                return .link(url)
            }
            return .text(string)
        }
        if let url = (pb.readObjects(forClasses: [NSURL.self]) as? [URL])?.first { return .link(url) }
        if let color = NSColor(from: pb) { return .color(color) }
        return .other
    }

    /// Finder-style description: "Clipboard contents: text".
    var summary: String {
        switch content {
        case .empty: "Clipboard is empty"
        case .files(let urls): "Clipboard contents: " + (urls.count == 1 ? "1 item" : "\(urls.count) items")
        case .image: "Clipboard contents: picture"
        case .richText: "Clipboard contents: styled text"
        case .text: "Clipboard contents: text"
        case .link: "Clipboard contents: link"
        case .color: "Clipboard contents: color"
        case .other: "Clipboard contents: unknown"
        }
    }
}

struct ClipboardView: View {
    @State private var monitor = ClipboardMonitor()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(monitor.summary).font(.headline)
                Spacer()
                Button("Clear Clipboard", systemImage: "xmark.circle") { monitor.clear() }
                    .disabled(monitor.types.isEmpty)
                    .quickHelp("Clear Clipboard", "Empties the clipboard, for this app and every other.")
            }
            .padding(10)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 420, minHeight: 300)
        .navigationTitle("Clipboard")
        .quickHelpScreen("Clipboard", FileHelp.clipboard)
        // No change notification exists for the clipboard: look twice a second while the window is open.
        .task {
            while !Task.isCancelled {
                monitor.check()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch monitor.content {
        case .empty:
            ContentUnavailableView("Nothing on the Clipboard", systemImage: "clipboard",
                                   description: Text("Copy something (⌘C) and it shows here."))
        case .files(let urls):
            ClipboardFilesView(urls: urls)
        case .image(let image, let info):
            VStack(spacing: 6) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(10)
                Text(info).font(.caption).foregroundStyle(.secondary).padding(.bottom, 6)
            }
            .background(Color(nsColor: .textBackgroundColor))
        case .richText(let attributed):
            RichTextView(text: attributed)
        case .text(let string):
            VStack(spacing: 0) {
                TextContentView(text: string.count > ClipboardMonitor.textLimit
                                    ? String(string.prefix(ClipboardMonitor.textLimit)) : string,
                                wrap: true)
                Text(textInfo(string)).font(.caption).foregroundStyle(.secondary).padding(4)
            }
        case .link(let url):
            VStack(spacing: 10) {
                Image(systemName: "link").font(.largeTitle).foregroundStyle(.secondary)
                Link(url.absoluteString, destination: url).textSelection(.enabled)
                    .multilineTextAlignment(.center)
            }
            .padding()
        case .color(let color):
            VStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: color))
                    .frame(width: 140, height: 90)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                Text(colorInfo(color)).font(.callout.monospaced()).textSelection(.enabled)
            }
        case .other:
            ContentUnavailableView("Can't Show This Content", systemImage: "questionmark.square.dashed",
                                   description: Text("The clipboard holds data of the types listed below."))
        }
    }

    private var footer: some View {
        DisclosureGroup("Types (\(monitor.types.count))") {
            ScrollView {
                Text(monitor.types.joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 80)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .quickHelpArea("Types", "The forms the clipboard holds this content in (UTIs), as the app that copied it offered them.",
                       symbol: "list.bullet")
    }

    private func textInfo(_ s: String) -> String {
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false).count
        var info = "\(s.count.formatted()) characters · \(lines.formatted()) line\(lines == 1 ? "" : "s")"
        if s.count > ClipboardMonitor.textLimit { info += " · showing the first \(ClipboardMonitor.textLimit.formatted())" }
        return info
    }

    private func colorInfo(_ color: NSColor) -> String {
        guard let c = color.usingColorSpace(.sRGB) else { return color.description }
        let r = Int((c.redComponent * 255).rounded()), g = Int((c.greenComponent * 255).rounded()), b = Int((c.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X  ·  rgb(%d, %d, %d)", r, g, b, r, g, b)
    }
}

/// Copied files: name, folder and size, a Quick Look preview of the selected one, and Paste Here / Move Here
/// into the active pane. Double-click opens a file in the Viewer (F3).
private struct ClipboardFilesView: View {
    let urls: [URL]
    @State private var selection: URL?
    @AppStorage("clipboardShowsPreview") private var showPreview = true
    @Environment(\.openWindow) private var openWindow

    /// The selected file, else the first; nil when it no longer exists.
    private var previewURL: URL? {
        let url = selection.flatMap { urls.contains($0) ? $0 : nil } ?? urls.first
        return url.flatMap { FileOps.exists($0) ? $0 : nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                list
                    .frame(minWidth: 220, maxWidth: .infinity, maxHeight: .infinity)
                if showPreview {
                    preview
                        .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            footer
        }
        .onChange(of: urls) { selection = urls.first }
        .onAppear { if selection == nil { selection = urls.first } }
    }

    private var list: some View {
        List(urls, id: \.self, selection: $selection) { url in
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable().frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent).lineLimit(1)
                    Text(url.deletingLastPathComponent().path)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text(size(of: url)).font(.caption).foregroundStyle(.secondary)
            }
            .opacity(FileOps.exists(url) ? 1 : 0.45)
            .help(FileOps.exists(url) ? url.path : "\(url.path) — no longer exists")
            .tag(url)
        }
        .contextMenu(forSelectionType: URL.self) { picked in
            if let url = picked.first, FileOps.exists(url), !FileOps.isRealDirectory(url) {
                Button("Open in Viewer") { openWindow(value: ViewerRequest(url: url)) }
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(picked.filter(FileOps.exists)) }
        } primaryAction: { picked in
            guard let url = picked.first, FileOps.exists(url) else { return }
            if FileOps.isRealDirectory(url) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            else { openWindow(value: ViewerRequest(url: url)) }
        }
        .quickHelpArea("Copied Items", "The files and folders on the clipboard. Select one to preview it on the right; double-click a file to open it in the Viewer (F3).",
                       symbol: "doc.on.clipboard")
    }

    @ViewBuilder private var preview: some View {
        if let url = previewURL {
            VStack(spacing: 0) {
                QuickLookView(url: url)
                Divider()
                Text(url.lastPathComponent)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .padding(4)
            }
            .quickHelpArea("Quick Look", "A Quick Look preview of the selected copied item, as Finder's preview pane shows it. Double-click the item for the Viewer.",
                           symbol: "eye")
        } else {
            ContentUnavailableView("No Preview", systemImage: "eye.slash",
                                   description: Text("The copied item no longer exists."))
        }
    }

    private var footer: some View {
        HStack {
            let folder = Workspace.current?.activeTab.url
            Toggle(isOn: $showPreview) {
                Label("Preview", systemImage: "sidebar.right")
            }
            .toggleStyle(.button)
            .quickHelp("Preview", "Shows or hides the Quick Look preview of the selected item.")
            Text(totals).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls.filter(FileOps.exists)) }
                .quickHelp("Show in Finder", "Selects the copied items in Finder.")
            Button("Move Here") { if let folder { Workspace.current?.transfer(urls, to: folder, move: true) } }
                .disabled(folder == nil)
                .quickHelp("Move Here", "Moves the copied items into the active pane's folder\(folder.map { ", “\(BrowserTab.displayName(of: $0))”" } ?? ""), as ⌥⌘V does.", shortcut: "⌥⌘V")
            Button(folder.map { "Paste into “\(BrowserTab.displayName(of: $0))”" } ?? "Paste") {
                if let folder { Workspace.current?.transfer(urls, to: folder, move: false) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(folder == nil)
            .quickHelp("Paste", "Copies the items into the active pane's folder, as ⌘V in the file list does.", shortcut: "⌘V")
        }
        .padding(10)
    }

    private var totals: String {
        let existing = urls.filter(FileOps.exists)
        let files = existing.filter { !FileOps.isRealDirectory($0) }
        let bytes = files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        var text = Fmt.count(urls.count, "item")
        if !files.isEmpty { text += ", \(Fmt.size(bytes)) in files" }
        if existing.count < urls.count { text += " · \(urls.count - existing.count) no longer exist" }
        return text
    }

    private func size(of url: URL) -> String {
        if FileOps.isRealDirectory(url) { return "folder" }
        guard let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return "" }
        return Fmt.size(Int64(bytes))
    }
}

/// Read-only styled text (RTF, HTML) with the find bar.
private struct RichTextView: NSViewRepresentable {
    let text: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.isEditable = false
        view.isSelectable = true
        view.usesFindBar = true
        view.textContainerInset = NSSize(width: 8, height: 8)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.attributedString() != text else { return }
        view.textStorage?.setAttributedString(text)
    }
}
