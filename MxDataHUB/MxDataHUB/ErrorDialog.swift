//
//  ErrorDialog.swift
//  MxDataHUB
//
//  Errors you can select and copy: a small dialog in place of an alert (an alert's text can't be selected), with the
//  message as selectable text — scrolling when it is long — and Copy and OK. A service's JSON answer ({"error": "…"})
//  shows as its message, with its line breaks, rather than as escaped JSON.
//

import AppKit
import SwiftUI

extension View {
    /// Shows `message` (while it isn't nil) in a dialog whose text can be selected and copied.
    func errorDialog(_ title: String, message: Binding<String?>) -> some View {
        sheet(isPresented: Binding(get: { message.wrappedValue != nil }, set: { if !$0 { message.wrappedValue = nil } })) {
            ErrorDialog(title: title, message: ErrorDialog.readable(message.wrappedValue ?? "")) { message.wrappedValue = nil }
        }
    }
}

struct ErrorDialog: View {
    let title: String
    let message: String
    let dismiss: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.orange)
                Text(title).font(.headline)
            }
            if message.count > 600 {
                ScrollView { text }
                    .frame(height: 300)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
            } else {
                text
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message, forType: .string)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .help("Copy the whole message")
                .quickHelp("Copy", "Copies the whole message, to paste into a note, a ticket or a message.")
                Spacer()
                Button("OK", action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onExitCommand(perform: dismiss)
    }

    private var text: some View {
        Text(message)
            .font(.callout)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .quickHelpArea("Message", "The error as the service or the database gave it. Select any part to copy it, or use Copy for all of it.", symbol: "exclamationmark.triangle")
    }

    /// A service's answer {"error": "…"} as its message; anything else as it is.
    static func readable(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? String else { return text }
        return error.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
