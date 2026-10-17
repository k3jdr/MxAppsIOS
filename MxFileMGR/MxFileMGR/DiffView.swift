//
//  DiffView.swift
//  MxFileMGR
//
//  Compare Files by Content: a line diff of two text files (binary files
//  are compared byte for byte), with a jump to FileMerge when Xcode is installed.
//

import AppKit
import SwiftUI

nonisolated struct DiffLine: Identifiable, Sendable {
    enum Kind: Sendable { case same, removed, added }
    let id: Int
    let kind: Kind
    let left: Int?
    let right: Int?
    let text: String
}

nonisolated enum Differ {
    static let sizeLimit = 8 << 20

    /// Either diff lines, or a message (binary files, too large, unreadable).
    static func diff(_ a: URL, _ b: URL) -> (lines: [DiffLine], message: String?) {
        guard let da = try? Data(contentsOf: a), let db = try? Data(contentsOf: b) else {
            return ([], "One of the files can't be read.")
        }
        let binary = da.prefix(8192).contains(0) || db.prefix(8192).contains(0)
        if binary || da.count > sizeLimit || db.count > sizeLimit {
            let reason = binary ? "Binary files" : "Large files"
            return ([], da == db ? "\(reason) are identical." : "\(reason) differ (\(Fmt.size(Int64(da.count))) vs \(Fmt.size(Int64(db.count)))).")
        }
        let old = String(decoding: da, as: UTF8.self).components(separatedBy: "\n")
        let new = String(decoding: db, as: UTF8.self).components(separatedBy: "\n")
        let changes = new.difference(from: old)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in changes {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var lines: [DiffLine] = []
        var i = 0, j = 0
        while i < old.count || j < new.count {
            if i < old.count, removed.contains(i) {
                lines.append(DiffLine(id: lines.count, kind: .removed, left: i + 1, right: nil, text: old[i])); i += 1
            } else if j < new.count, inserted.contains(j) {
                lines.append(DiffLine(id: lines.count, kind: .added, left: nil, right: j + 1, text: new[j])); j += 1
            } else {
                lines.append(DiffLine(id: lines.count, kind: .same, left: i + 1, right: j + 1, text: i < old.count ? old[i] : ""))
                i += 1; j += 1
            }
        }
        return (lines, changes.isEmpty ? "The files are identical." : nil)
    }
}

struct DiffView: View {
    let request: DiffRequest
    @State private var lines: [DiffLine] = []
    @State private var message: String?
    @State private var onlyChanges = false
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(request.left.path, systemImage: "minus.square").foregroundStyle(.red).lineLimit(1).truncationMode(.head)
                Spacer()
                Label(request.right.path, systemImage: "plus.square").foregroundStyle(.green).lineLimit(1).truncationMode(.head)
            }
            .font(.caption)
            .padding(8)
            HStack {
                Toggle("Only changes", isOn: $onlyChanges)
                Text("\(lines.filter { $0.kind == .removed }.count) removed, \(lines.filter { $0.kind == .added }.count) added")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open in FileMerge") { openFileMerge() }
            }
            .padding(.horizontal, 8).padding(.bottom, 6)
            Divider()
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let message, lines.isEmpty || message.hasSuffix("identical.") {
                ContentUnavailableView(message, systemImage: "doc.on.doc")
            } else {
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(onlyChanges ? lines.filter { $0.kind != .same } : lines) { line in
                            row(line)
                        }
                    }
                    .padding(4)
                }
                .font(.system(size: 12, design: .monospaced))
            }
        }
        .navigationTitle("\(request.left.lastPathComponent) ↔ \(request.right.lastPathComponent)")
        .quickHelpScreen("Compare Files", FileHelp.diff)
        .task {
            let (a, b) = (request.left, request.right)
            let result = await Task.detached { Differ.diff(a, b) }.value
            lines = result.lines
            message = result.message
            loading = false
        }
    }

    private func row(_ line: DiffLine) -> some View {
        HStack(spacing: 8) {
            Text(line.left.map(String.init) ?? "").frame(width: 44, alignment: .trailing).foregroundStyle(.secondary)
            Text(line.right.map(String.init) ?? "").frame(width: 44, alignment: .trailing).foregroundStyle(.secondary)
            Text(line.kind == .removed ? "-" : (line.kind == .added ? "+" : " "))
            Text(line.text.isEmpty ? " " : line.text).fixedSize()
        }
        .textSelection(.enabled)
        .background(line.kind == .removed ? Color.red.opacity(0.15) : (line.kind == .added ? Color.green.opacity(0.15) : Color.clear))
    }

    private func openFileMerge() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/opendiff")
        process.arguments = [request.left.path, request.right.path]
        do { try process.run() } catch {
            Alerts.message("FileMerge isn't available.", info: "It comes with Xcode. \(error.localizedDescription)")
        }
    }
}
