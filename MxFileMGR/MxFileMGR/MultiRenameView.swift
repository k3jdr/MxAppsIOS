//
//  MultiRenameView.swift
//  MxFileMGR
//
//  Batch rename (Total Commander's Multi-Rename Tool). Name and extension
//  masks with placeholders, search and replace, case change and a counter,
//  with a live preview. The last batch can be undone.
//
//  Placeholders: [N] name, [N2-5] characters 2 to 5 of the name, [N3] the 3rd
//  character, [E] extension, [C] counter, [P] parent folder name,
//  [YMD] / [hms] modification date and time.
//

import AppKit
import SwiftUI

nonisolated enum CaseMode: String, CaseIterable, Identifiable, Sendable {
    case unchanged = "Unchanged", lower = "lowercase", upper = "UPPERCASE", title = "Title Case"
    var id: String { rawValue }
}

nonisolated struct RenameRule: Sendable {
    var nameMask = "[N]"
    var extMask = "[E]"
    var search = ""
    var replace = ""
    var useRegex = false
    var caseMode = CaseMode.unchanged
    var counterStart = 1
    var counterStep = 1
    var counterDigits = 1

    func newName(for url: URL, index: Int) -> String {
        let isDir = FileOps.isRealDirectory(url)
        let ext = isDir ? "" : url.pathExtension
        let stem = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        let date = FileOps.modificationDate(url)
        let counter = counterStart + index * counterStep
        let counterText = String(repeating: "0", count: max(0, counterDigits - String(counter).count)) + String(counter)

        func expand(_ mask: String) -> String {
            var out = ""
            var i = mask.startIndex
            while i < mask.endIndex {
                if mask[i] == "[", let close = mask[i...].firstIndex(of: "]") {
                    let token = String(mask[mask.index(after: i)..<close])
                    out += value(of: token) ?? "[\(token)]"
                    i = mask.index(after: close)
                } else {
                    out.append(mask[i])
                    i = mask.index(after: i)
                }
            }
            return out
        }

        func value(of token: String) -> String? {
            switch token {
            case "N": return stem
            case "E": return ext
            case "C": return counterText
            case "P": return url.deletingLastPathComponent().lastPathComponent
            case "YMD":
                let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
                return String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
            case "hms":
                let c = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
                return String(format: "%02d%02d%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
            default:
                // [Nx-y] or [Nx]: characters x...y (1-based) of the name.
                guard token.hasPrefix("N") else { return nil }
                let parts = token.dropFirst().split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
                let chars = Array(stem)
                guard let from = parts.first ?? nil, from >= 1 else { return nil }
                let to = parts.count > 1 ? (parts[1] ?? chars.count) : from
                let lo = min(from - 1, chars.count), hi = min(max(to, lo), chars.count)
                return String(chars[lo..<hi])
            }
        }

        var name = expand(nameMask)
        let newExt = expand(extMask)
        if !newExt.isEmpty { name += "." + newExt }
        if !search.isEmpty {
            if useRegex, let re = try? NSRegularExpression(pattern: search) {
                name = re.stringByReplacingMatches(in: name, range: NSRange(name.startIndex..., in: name), withTemplate: replace)
            } else {
                name = name.replacingOccurrences(of: search, with: replace)
            }
        }
        switch caseMode {
        case .unchanged: break
        case .lower: name = name.lowercased()
        case .upper: name = name.uppercased()
        case .title: name = name.capitalized
        }
        return name
    }
}

struct MultiRenameView: View {
    @State private var urls: [URL]
    @State private var rule = RenameRule()
    @State private var undo: [(from: URL, to: URL)] = []
    @State private var message = ""

    init(request: RenameRequest) {
        _urls = State(initialValue: request.urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
    }

    private struct Preview: Identifiable {
        let id: URL
        let old: String
        let new: String
        let problem: String?
    }

    private var preview: [Preview] {
        let names = urls.enumerated().map { rule.newName(for: $1, index: $0) }
        var seen: [String: Int] = [:]
        names.forEach { seen[$0.lowercased(), default: 0] += 1 }
        let sources = Set(urls.map { $0.lastPathComponent.lowercased() })
        return zip(urls, names).map { url, name in
            var problem: String?
            if name.isEmpty || name.contains("/") || name == "." || name == ".." {
                problem = "Invalid name"
            } else if (seen[name.lowercased()] ?? 0) > 1 {
                problem = "Duplicate"
            } else if name.lowercased() != url.lastPathComponent.lowercased(),
                      !sources.contains(name.lowercased()),
                      FileOps.exists(url.deletingLastPathComponent().appendingPathComponent(name)) {
                problem = "Already exists"
            }
            return Preview(id: url, old: url.lastPathComponent, new: name, problem: problem)
        }
    }

    var body: some View {
        let rows = preview
        VStack(spacing: 0) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Name mask:")
                    TextField("[N]", text: $rule.nameMask)
                    Text("Extension:")
                    TextField("[E]", text: $rule.extMask).frame(width: 90)
                }
                GridRow {
                    Text("Search for:")
                    TextField("", text: $rule.search)
                    Text("Replace with:")
                    TextField("", text: $rule.replace).frame(width: 160)
                }
                GridRow {
                    Text("Case:")
                    HStack {
                        Picker("", selection: $rule.caseMode) {
                            ForEach(CaseMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                        Toggle("Regular expressions", isOn: $rule.useRegex)
                    }
                    Text("Counter [C]:")
                    HStack {
                        Stepper("start \(rule.counterStart)", value: $rule.counterStart, in: 0...999_999)
                        Stepper("step \(rule.counterStep)", value: $rule.counterStep, in: 1...1000)
                        Stepper("digits \(rule.counterDigits)", value: $rule.counterDigits, in: 1...9)
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
            .padding(14)
            Text("Placeholders: [N] name · [N2-5] characters 2–5 · [E] extension · [C] counter · [P] parent folder · [YMD] date · [hms] time")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.bottom, 8)
            Divider()
            Table(rows) {
                TableColumn("Old Name") { Text($0.old) }
                TableColumn("New Name") { row in
                    Text(row.new).foregroundStyle(row.problem != nil ? .red : (row.new == row.old ? .secondary : .primary))
                }
                TableColumn("") { Text($0.problem ?? "").foregroundStyle(.red) }.width(110)
            }
            Divider()
            HStack {
                Text(message).foregroundStyle(.secondary)
                Spacer()
                Button("Undo") { performUndo() }.disabled(undo.isEmpty)
                    .quickHelp("Undo", "Gives the files of the last batch their old names back.")
                Button("Rename") { rename(rows) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(rows.contains { $0.problem != nil } || rows.allSatisfy { $0.old == $0.new })
            }
            .padding(10)
        }
        .navigationTitle("Multi-Rename — \(Fmt.count(urls.count, "item"))")
        .quickHelpScreen("Multi-Rename", FileHelp.multiRename)
    }

    /// Renames in two passes through temporary names so swaps (a→b, b→a) work.
    private func rename(_ rows: [Preview]) {
        let moves = rows.filter { $0.old != $0.new }.map { ($0.id, $0.id.deletingLastPathComponent().appendingPathComponent($0.new)) }
        let done = applyMoves(moves)
        undo = done.map { (from: $0.1, to: $0.0) }
        // Keep working on the renamed files.
        let map = Dictionary(done.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
        urls = urls.map { map[$0] ?? $0 }
        message = "Renamed \(Fmt.count(done.count, "item"))."
        NotificationCenter.default.post(name: .mxFilesChanged, object: nil)
    }

    private func performUndo() {
        let done = applyMoves(undo.map { ($0.from, $0.to) })
        let map = Dictionary(done.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
        urls = urls.map { map[$0] ?? $0 }
        undo = []
        message = "Undid \(Fmt.count(done.count, "rename"))."
        NotificationCenter.default.post(name: .mxFilesChanged, object: nil)
    }

    private func applyMoves(_ moves: [(URL, URL)]) -> [(URL, URL)] {
        let fm = FileManager.default
        var staged: [(URL, URL, URL)] = []   // original, temporary, final
        var failures: [String] = []
        for (from, to) in moves {
            let temp = from.deletingLastPathComponent().appendingPathComponent(".mxrename-\(UUID().uuidString)")
            do {
                try fm.moveItem(at: from, to: temp)
                staged.append((from, temp, to))
            } catch { failures.append("\(from.lastPathComponent): \(error.localizedDescription)") }
        }
        var done: [(URL, URL)] = []
        for (from, temp, to) in staged {
            do {
                try fm.moveItem(at: temp, to: to)
                done.append((from, to))
            } catch {
                try? fm.moveItem(at: temp, to: from)
                failures.append("\(to.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty {
            Alerts.message("Some items couldn't be renamed.", info: failures.prefix(20).joined(separator: "\n"))
        }
        return done
    }
}
