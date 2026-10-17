//
//  ViewerView.swift
//  MxFileMGR
//
//  F3 viewer (Total Commander's Lister): Quick Look preview, plain text
//  with find (⌘F) and wrapping, or a hex dump.
//

import AppKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers

struct ViewerView: View {
    let request: ViewerRequest
    @State private var mode: Mode = .preview
    @State private var text = ""
    @State private var wrap = true
    @State private var note = ""

    enum Mode: String, CaseIterable, Identifiable {
        case preview = "Preview", text = "Text", hex = "Hex"
        var id: String { rawValue }
    }

    nonisolated static let textLimit = 20 << 20
    nonisolated static let hexLimit = 1 << 20

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                if mode == .text { Toggle("Wrap lines", isOn: $wrap) }
                Text(note).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Open") { NSWorkspace.shared.open(request.url) }
                Button("Show in Pane") { Workspace.current?.reveal(request.url) }
            }
            .padding(8)
            Divider()
            switch mode {
            case .preview: QuickLookView(url: request.url)
            case .text, .hex: TextContentView(text: text, wrap: mode == .text && wrap)
            }
        }
        .navigationTitle(request.url.lastPathComponent)
        .quickHelpScreen("Viewer", FileHelp.viewer, selection: QuickHelpItem(title: request.url.lastPathComponent, detail: request.url.path, symbol: "doc"))
        .navigationSubtitle(request.url.deletingLastPathComponent().path)
        .task(id: mode) { await load() }
        .onAppear {
            // Text-like files open straight in the text view.
            if let type = (try? request.url.resourceValues(forKeys: [.contentTypeKey]))?.contentType,
               type.conforms(to: .text) || type.conforms(to: .sourceCode) {
                mode = .text
            }
        }
    }

    private func load() async {
        let url = request.url
        switch mode {
        case .preview:
            note = ""
        case .text:
            let result = await Task.detached { Self.readText(url) }.value
            text = result.0
            note = result.1
        case .hex:
            let result = await Task.detached { Self.hexDump(url) }.value
            text = result.0
            note = result.1
        }
    }

    nonisolated static func readText(_ url: URL) -> (String, String) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ("", "Can't read the file.") }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: textLimit)) ?? Data()
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? data.count
        let truncated = size > data.count ? "  ·  showing the first \(Fmt.size(Int64(data.count)))" : ""
        if let s = String(data: data, encoding: .utf8) { return (s, "UTF-8" + truncated) }
        if let s = String(data: data, encoding: .utf16) , data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return (s, "UTF-16" + truncated)
        }
        return (String(decoding: data, as: UTF8.self), "Not valid UTF-8; invalid bytes replaced" + truncated)
    }

    nonisolated static func hexDump(_ url: URL) -> (String, String) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ("", "Can't read the file.") }
        defer { try? handle.close() }
        let data = [UInt8]((try? handle.read(upToCount: hexLimit)) ?? Data())
        var out = ""
        out.reserveCapacity(data.count * 4 + 64)
        let hex = Array("0123456789abcdef")
        var offset = 0
        while offset < data.count {
            let line = data[offset..<min(offset + 16, data.count)]
            out += String(format: "%08x  ", offset)
            for i in 0..<16 {
                if i < line.count {
                    let b = line[line.startIndex + i]
                    out.append(hex[Int(b >> 4)]); out.append(hex[Int(b & 0xF)]); out.append(" ")
                } else {
                    out += "   "
                }
                if i == 7 { out += " " }
            }
            out += " |"
            for b in line { out.append((b >= 32 && b < 127) ? Character(UnicodeScalar(b)) : ".") }
            out += "|\n"
            offset += 16
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? data.count
        return (out, size > data.count ? "showing the first \(Fmt.size(Int64(data.count))) of \(Fmt.size(Int64(size)))" : Fmt.size(Int64(size)))
    }
}

struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url { view.previewItem = url as NSURL }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}

/// Read-only, monospaced NSTextView with the find bar.
struct TextContentView: NSViewRepresentable {
    let text: String
    let wrap: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let textView = scroll.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        scroll.hasHorizontalScroller = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
            textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        }
        guard let container = textView.textContainer else { return }
        if wrap {
            textView.isHorizontallyResizable = false
            container.widthTracksTextView = true
            container.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
            textView.frame.size.width = scroll.contentSize.width
        } else {
            textView.isHorizontallyResizable = true
            container.widthTracksTextView = false
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        }
    }
}
