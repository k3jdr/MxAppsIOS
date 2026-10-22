//
//  SyncView.swift
//  MxFileMGR
//
//  Synchronize Folders: compares two folder trees (by date and size, or by
//  content), proposes a copy direction for each difference, lets you change
//  it, then copies.
//

import AppKit
import SwiftUI

nonisolated enum SyncStatus: Sendable {
    case leftOnly, rightOnly, leftNewer, rightNewer, differs, equal

    var symbol: String {
        switch self {
        case .leftOnly: "left only"
        case .rightOnly: "right only"
        case .leftNewer: "left newer"
        case .rightNewer: "right newer"
        case .differs: "different"
        case .equal: "equal"
        }
    }
}

nonisolated enum SyncAction: String, CaseIterable, Identifiable, Sendable {
    case toRight = "→", toLeft = "←", skip = "–"
    var id: String { rawValue }
}

nonisolated struct SyncEntry: Identifiable, Sendable {
    let path: String
    let isDirectory: Bool
    let left: (size: Int64, date: Date)?
    let right: (size: Int64, date: Date)?
    let status: SyncStatus
    var action: SyncAction
    var id: String { path }
}

nonisolated enum SyncEngine {
    private struct Entry { let isDir: Bool; let size: Int64; let date: Date }

    static func compare(left: URL, right: URL, recursive: Bool, includeHidden: Bool, byContent: Bool,
                        flag: CancelFlag) -> [SyncEntry] {
        var result: [SyncEntry] = []

        func list(_ dir: URL) -> [String: Entry] {
            let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: keys, options: includeHidden ? [] : [.skipsHiddenFiles])) ?? []
            var map: [String: Entry] = [:]
            for url in urls {
                guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                map[url.lastPathComponent] = Entry(isDir: (v.isDirectory ?? false) && !(v.isSymbolicLink ?? false),
                                                   size: Int64(v.fileSize ?? 0),
                                                   date: v.contentModificationDate ?? .distantPast)
            }
            return map
        }

        func walk(_ rel: String) {
            if flag.isCancelled { return }
            let l = list(rel.isEmpty ? left : left.appendingPathComponent(rel))
            let r = list(rel.isEmpty ? right : right.appendingPathComponent(rel))
            let names = Set(l.keys).union(r.keys).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            for name in names {
                let path = rel.isEmpty ? name : rel + "/" + name
                let a = l[name], b = r[name]
                let lInfo = a.map { (size: $0.size, date: $0.date) }
                let rInfo = b.map { (size: $0.size, date: $0.date) }
                if let a, let b {
                    if a.isDir && b.isDir {
                        if recursive { walk(path) }
                        continue
                    }
                    if a.isDir != b.isDir {
                        result.append(SyncEntry(path: path, isDirectory: a.isDir, left: lInfo, right: rInfo, status: .differs, action: .skip))
                        continue
                    }
                    let dt = a.date.timeIntervalSince(b.date)
                    var status: SyncStatus
                    if a.size == b.size && abs(dt) <= 2 {
                        status = .equal
                    } else if dt > 2 {
                        status = .leftNewer
                    } else if dt < -2 {
                        status = .rightNewer
                    } else {
                        status = .differs
                    }
                    if byContent, a.size == b.size {
                        let same = sameContents(left.appendingPathComponent(path), right.appendingPathComponent(path))
                        if same { status = .equal } else if status == .equal { status = .differs }
                    }
                    let action: SyncAction = status == .leftNewer ? .toRight : (status == .rightNewer ? .toLeft : .skip)
                    result.append(SyncEntry(path: path, isDirectory: false, left: lInfo, right: rInfo, status: status, action: action))
                } else if let a {
                    result.append(SyncEntry(path: path, isDirectory: a.isDir, left: lInfo, right: nil, status: .leftOnly, action: .toRight))
                } else if let b {
                    result.append(SyncEntry(path: path, isDirectory: b.isDir, left: nil, right: rInfo, status: .rightOnly, action: .toLeft))
                }
            }
        }

        walk("")
        return result
    }

    static func sameContents(_ a: URL, _ b: URL) -> Bool {
        guard let ha = try? FileHandle(forReadingFrom: a), let hb = try? FileHandle(forReadingFrom: b) else { return false }
        defer { try? ha.close(); try? hb.close() }
        while true {
            let da = (try? ha.read(upToCount: 1 << 20)) ?? Data()
            let db = (try? hb.read(upToCount: 1 << 20)) ?? Data()
            if da != db { return false }
            if da.isEmpty { return true }
        }
    }
}

struct SyncView: View {
    @State private var leftPath: String
    @State private var rightPath: String
    @State private var entries: [SyncEntry] = []
    @State private var recursive = true
    @State private var includeHidden = false
    @State private var byContent = false
    @State private var showEqual = false
    @State private var comparing = false
    @State private var compared = false
    @State private var selection = Set<String>()

    init(request: SyncRequest) {
        _leftPath = State(initialValue: request.left.path)
        _rightPath = State(initialValue: request.right.path)
    }

    private var visible: [SyncEntry] { entries.filter { showEqual || $0.status != .equal } }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Left folder", text: $leftPath).textFieldStyle(.roundedBorder)
                    Button { (leftPath, rightPath) = (rightPath, leftPath) } label: { Image(systemName: "arrow.left.arrow.right") }
                        .help("Swap sides")
                    TextField("Right folder", text: $rightPath).textFieldStyle(.roundedBorder)
                }
                HStack {
                    Toggle("Subfolders", isOn: $recursive)
                    Toggle("Hidden items", isOn: $includeHidden)
                    Toggle("Compare content", isOn: $byContent)
                    Toggle("Show equal", isOn: $showEqual)
                    Spacer()
                    if comparing { ProgressView().controlSize(.small) }
                    Button("Compare") { compare() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(comparing)
                }
            }
            .padding(14)
            Divider()
            Table(visible, selection: $selection) {
                TableColumn("Path") { e in
                    Label(e.path, systemImage: e.isDirectory ? "folder" : "doc")
                }
                TableColumn("Left") { e in Text(info(e.left, dir: e.isDirectory)).foregroundStyle(.secondary) }
                    .width(min: 120, ideal: 170)
                TableColumn("Action") { e in
                    Picker("", selection: binding(for: e.id)) {
                        ForEach(SyncAction.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .width(70)
                TableColumn("Right") { e in Text(info(e.right, dir: e.isDirectory)).foregroundStyle(.secondary) }
                    .width(min: 120, ideal: 170)
                TableColumn("Status") { e in Text(e.status.symbol).foregroundStyle(color(e.status)) }
                    .width(90)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                Button("Copy → Right") { set(ids, .toRight) }
                Button("Copy ← Left") { set(ids, .toLeft) }
                Button("Skip") { set(ids, .skip) }
            }
            Divider()
            HStack {
                let toRight = entries.filter { $0.action == .toRight }.count
                let toLeft = entries.filter { $0.action == .toLeft }.count
                Text(compared ? "\(toRight) to copy right, \(toLeft) to copy left, \(entries.filter { $0.status == .equal }.count) equal" : "Press Compare.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Synchronize") { synchronize() }
                    .disabled(toRight + toLeft == 0)
                    .quickHelp("Synchronize", "Copies every row with a direction (→ or ←) after asking, replacing older files at the destination.")
            }
            .padding(10)
        }
        .navigationTitle("Synchronize Folders")
        .quickHelpScreen("Synchronize Folders", FileHelp.sync)
    }

    private func info(_ side: (size: Int64, date: Date)?, dir: Bool) -> String {
        guard let side else { return "" }
        return dir ? "folder" : "\(Fmt.size(side.size))  \(Fmt.date(side.date))"
    }

    private func color(_ s: SyncStatus) -> Color {
        switch s {
        case .equal: .secondary
        case .differs: .red
        case .leftOnly, .leftNewer: .blue
        case .rightOnly, .rightNewer: .green
        }
    }

    private func binding(for id: String) -> Binding<SyncAction> {
        Binding(get: { entries.first { $0.id == id }?.action ?? .skip },
                set: { value in
                    if let i = entries.firstIndex(where: { $0.id == id }) { entries[i].action = value }
                })
    }

    private func set(_ ids: Set<String>, _ action: SyncAction) {
        for i in entries.indices where ids.contains(entries[i].id) { entries[i].action = action }
    }

    private var leftURL: URL { URL(fileURLWithPath: (leftPath as NSString).expandingTildeInPath) }
    private var rightURL: URL { URL(fileURLWithPath: (rightPath as NSString).expandingTildeInPath) }

    private func compare() {
        comparing = true
        let (l, r, rec, hidden, content) = (leftURL, rightURL, recursive, includeHidden, byContent)
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                SyncEngine.compare(left: l, right: r, recursive: rec, includeHidden: hidden, byContent: content, flag: CancelFlag())
            }.value
            entries = result
            comparing = false
            compared = true
        }
    }

    private func synchronize() {
        var pairs: [(URL, URL)] = []
        for e in entries {
            switch e.action {
            case .toRight: pairs.append((leftURL.appendingPathComponent(e.path), rightURL.appendingPathComponent(e.path)))
            case .toLeft: pairs.append((rightURL.appendingPathComponent(e.path), leftURL.appendingPathComponent(e.path)))
            case .skip: break
            }
        }
        guard Alerts.confirm("Copy \(Fmt.count(pairs.count, "item"))?",
                             info: "Existing files at the destination are replaced.", ok: "Synchronize") else { return }
        TransferManager.shared.copy(pairs, move: false, policy: .overwrite)
        entries = []
        compared = false
    }
}
