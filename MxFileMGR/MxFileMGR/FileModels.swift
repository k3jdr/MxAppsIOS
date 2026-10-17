//
//  FileModels.swift
//  MxFileMGR
//
//  Directory entries, sorting, wildcard matching and formatting.
//  Everything here is nonisolated so listings can be built off the main thread.
//

import Foundation

nonisolated struct FileItem: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    /// A folder you can enter (including a symlink to one). Packages such as .app are not.
    let isDirectory: Bool
    let isPackage: Bool
    let isSymlink: Bool
    let isHidden: Bool
    let size: Int64
    let modified: Date
    let created: Date
    let kind: String

    var id: URL { url }
    var ext: String { isDirectory ? "" : url.pathExtension }
}

/// The sortable columns of a file list. The raw value is also the table column identifier.
nonisolated enum SortKey: String, Codable, CaseIterable, Sendable {
    case name, ext, size, modified, kind

    var title: String {
        switch self {
        case .name: "Name"
        case .ext: "Ext"
        case .size: "Size"
        case .modified: "Date Modified"
        case .kind: "Kind"
        }
    }
}

nonisolated struct SortOrder: Equatable, Codable, Sendable {
    var key: SortKey = .name
    var ascending = true
}

nonisolated enum DirectoryLoader {
    static let keys: Set<URLResourceKey> = [
        .nameKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey,
        .fileSizeKey, .contentModificationDateKey, .creationDateKey, .localizedTypeDescriptionKey,
    ]

    static func item(at url: URL) -> FileItem? {
        guard let v = try? url.resourceValues(forKeys: keys) else { return nil }
        let isLink = v.isSymbolicLink ?? false
        var isDir = v.isDirectory ?? false
        if isLink {
            isDir = (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        }
        let isPackage = v.isPackage ?? false
        return FileItem(
            url: url,
            name: v.name ?? url.lastPathComponent,
            isDirectory: isDir && !isPackage,
            isPackage: isPackage,
            isSymlink: isLink,
            isHidden: v.isHidden ?? url.lastPathComponent.hasPrefix("."),
            size: Int64(v.fileSize ?? 0),
            modified: v.contentModificationDate ?? .distantPast,
            created: v.creationDate ?? .distantPast,
            kind: v.localizedTypeDescription ?? ""
        )
    }

    static func load(_ dir: URL, showHidden: Bool) throws -> [FileItem] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: Array(keys),
            options: showHidden ? [] : [.skipsHiddenFiles])
        return urls.compactMap(item(at:))
    }

    static func sorted(_ items: [FileItem], by order: SortOrder, foldersFirst: Bool) -> [FileItem] {
        items.sorted { a, b in
            if foldersFirst, a.isDirectory != b.isDirectory { return a.isDirectory }
            var result: ComparisonResult
            switch order.key {
            case .name: result = a.name.localizedStandardCompare(b.name)
            case .ext: result = a.ext.localizedStandardCompare(b.ext)
            case .size: result = a.size == b.size ? .orderedSame : (a.size < b.size ? .orderedAscending : .orderedDescending)
            case .modified: result = a.modified.compare(b.modified)
            case .kind: result = a.kind.localizedStandardCompare(b.kind)
            }
            if result == .orderedSame { result = a.name.localizedStandardCompare(b.name) }
            return order.ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }
}

/// Matches names against `*.swift;*.md` style wildcards (or regular expressions).
/// Patterns are separated by `;`. With `substringIfPlain`, a pattern without
/// wildcards matches anywhere in the name (used by the quick filter).
nonisolated struct NameMatcher: Sendable {
    private let regexes: [NSRegularExpression]
    private let substrings: [String]
    private let caseSensitive: Bool

    init(_ text: String, substringIfPlain: Bool = false, regex: Bool = false, caseSensitive: Bool = false) {
        self.caseSensitive = caseSensitive
        let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
        if regex {
            regexes = (try? NSRegularExpression(pattern: text, options: options)).map { [$0] } ?? []
            substrings = []
            return
        }
        var res: [NSRegularExpression] = []
        var subs: [String] = []
        for raw in text.split(separator: ";") {
            let p = raw.trimmingCharacters(in: .whitespaces)
            if p.isEmpty { continue }
            if substringIfPlain, !p.contains("*"), !p.contains("?") {
                subs.append(caseSensitive ? p : p.lowercased())
                continue
            }
            let escaped = NSRegularExpression.escapedPattern(for: p)
                .replacingOccurrences(of: "\\*", with: ".*")
                .replacingOccurrences(of: "\\?", with: ".")
            if let re = try? NSRegularExpression(pattern: "^" + escaped + "$", options: options) {
                res.append(re)
            }
        }
        regexes = res
        substrings = subs
    }

    var isEmpty: Bool { regexes.isEmpty && substrings.isEmpty }

    func matches(_ name: String) -> Bool {
        if isEmpty { return true }
        let folded = caseSensitive ? name : name.lowercased()
        if substrings.contains(where: { folded.contains($0) }) { return true }
        let range = NSRange(name.startIndex..., in: name)
        return regexes.contains { $0.firstMatch(in: name, range: range) != nil }
    }
}

nonisolated enum Fmt {
    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func date(_ date: Date) -> String {
        date == .distantPast ? "" : date.formatted(date: .numeric, time: .shortened)
    }

    static func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(n) " + (n == 1 ? singular : (plural ?? singular + "s"))
    }
}

extension URL {
    /// Path for display and POSIX calls, without a trailing slash.
    nonisolated var fsPath: String { standardizedFileURL.path }
}
