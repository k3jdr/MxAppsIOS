//
//  JSONViewer.swift
//  MxDataSQL
//
//  "View JSON…" from the grid's right-click menu: a resizable sheet with the
//  cell's JSON formatted and coloured like VS Code. The text can be edited;
//  Format re-indents it, Copy copies it, and on editable grids Apply to Cell
//  turns it into a pending edit (applied to the table with Update…).
//

import AppKit
import SwiftUI

struct JSONViewer: View {
    let title: String
    let subtitle: String
    let original: String
    /// Nil when the grid is read-only; otherwise stores the text as the cell's pending edit.
    let apply: ((String) -> Void)?
    let close: () -> Void

    @State private var text = ""
    @State private var problem: String?
    @AppStorage("jsonIndentSpaces") private var indentSpaces = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            JSONTextView(text: $text)
                .frame(minWidth: 480, minHeight: 280)
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack {
                Picker("Indent", selection: $indentSpaces) {
                    Text("2 spaces").tag(2)
                    Text("4 spaces").tag(4)
                }
                .fixedSize()
                Button("Format") { format(text) }
                    .help("Re-indent like VS Code's Format Document")
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Spacer()
                if let apply {
                    Button("Apply to Cell") {
                        do {
                            _ = try JSONFormatter.format(text)
                            apply(text.trimmingCharacters(in: .whitespacesAndNewlines))
                            close()
                        } catch {
                            problem = error.localizedDescription
                        }
                    }
                    .help("Make this text the cell's pending edit; Update… writes it to the table")
                }
                Button("Close", action: close)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(minWidth: 520, idealWidth: 680, minHeight: 380, idealHeight: 520)
        .onAppear { format(original) }
        .onChange(of: indentSpaces) { format(text) }
    }

    /// Formats `source` into the text area; invalid JSON is shown as it is, with the error.
    private func format(_ source: String) {
        do {
            text = try JSONFormatter.format(source, indent: String(repeating: " ", count: indentSpaces))
            problem = nil
        } catch {
            text = source
            problem = error.localizedDescription
        }
    }
}

/// Monospaced, plain-text editor that colours JSON after every change.
struct JSONTextView: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.borderType = .bezelBorder
        scroll.hasHorizontalScroller = true
        let textView = scroll.documentView as! NSTextView
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        // Long lines scroll sideways instead of wrapping, as in VS Code.
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude)
        textView.textStorage?.delegate = context.coordinator
        textView.string = text
        textView.delegate = context.coordinator
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        let textView = scroll.documentView as! NSTextView
        if textView.string != text { textView.string = text }
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                         range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            JSONFormatter.apply(to: textStorage)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}

enum JSONViewerPresenter {
    /// Shows the viewer as a resizable sheet on `window`.
    static func show(on window: NSWindow, title: String, subtitle: String, json: String,
                     apply: ((String) -> Void)?) {
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
                             styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        let close = { [weak sheet] in
            guard let sheet else { return }
            window.endSheet(sheet)
        }
        sheet.contentViewController = NSHostingController(rootView: JSONViewer(
            title: title, subtitle: subtitle, original: json, apply: apply, close: close))
        sheet.setContentSize(NSSize(width: 680, height: 520))
        sheet.minSize = NSSize(width: 520, height: 380)
        window.beginSheet(sheet)
    }
}
