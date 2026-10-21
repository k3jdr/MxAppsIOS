//
//  DBMLDocument.swift
//  MxDataSQL
//
//  DBML (dbml.dbdiagram.io) as the Diagram windows use it: the tables, columns, relationships,
//  table groups and sticky notes of a .dbml file, a parser for them, and the diagram section that
//  MxDataSQL keeps at the end of the file — its sticky notes and one comment line with the
//  layout (table positions, relationship curves, note frames). Other DBML tools read the notes and
//  ignore the comment; everything else in the file is kept as written.
//

import Foundation

nonisolated struct DBMLColumn: Hashable, Sendable {
    var name: String
    var type: String
    var isPrimaryKey = false
    var isNotNull = false
    var isUnique = false
    var isIncrement = false
    var defaultValue: String?
    var note: String?
}

nonisolated struct DBMLTable: Identifiable, Hashable, Sendable {
    /// "name" for tables in public (or without a schema), else "schema.name".
    var id: String
    var schema: String
    var name: String
    var columns: [DBMLColumn] = []
    var note: String?
    var alias: String?
    var indexCount = 0
}

nonisolated struct DBMLEndpoint: Hashable, Sendable {
    var table: String          // table id
    var columns: [String]
}

nonisolated enum DBMLRelation: String, Sendable {
    case manyToOne = ">", oneToMany = "<", oneToOne = "-", manyToMany = "<>"
}

nonisolated struct DBMLRef: Identifiable, Hashable, Sendable {
    var from: DBMLEndpoint
    var to: DBMLEndpoint
    var relation: DBMLRelation
    var color: String?
    var id: String { "\(from.table).(\(from.columns.joined(separator: ",")))\(relation.rawValue)\(to.table).(\(to.columns.joined(separator: ",")))" }
}

nonisolated struct DBMLGroup: Hashable, Sendable {
    var name: String
    var tables: [String]
}

nonisolated struct DBMLStickyNote: Identifiable, Hashable, Sendable {
    var id: String             // the note's DBML name
    var text: String
    /// Written by MxDataSQL in its diagram section (editable); others are shown read-only.
    var isOwn: Bool
}

// MARK: - Layout

nonisolated struct DiagramPoint: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
}

nonisolated enum CurveStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Smooth S-curve computed from the tables' positions.
    case automatic
    case straight
    /// One control point (stored as an offset from the midpoint of the two ends).
    case quadratic
    /// Two control points (stored as offsets from the start and from the end).
    case cubic
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .straight: "Straight Line"
        case .quadratic: "Quadratic Bézier"
        case .cubic: "Cubic Bézier"
        }
    }
}

nonisolated struct RefCurve: Codable, Hashable, Sendable {
    var style: CurveStyle = .automatic
    var c1: DiagramPoint?
    var c2: DiagramPoint?
}

nonisolated struct NoteFrame: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
    var width: Double = 220
    var height: Double = 120
}

nonisolated struct DiagramLayout: Codable, Hashable, Sendable {
    var tables: [String: DiagramPoint] = [:]
    var refs: [String: RefCurve] = [:]
    var notes: [String: NoteFrame] = [:]
    var zoom: Double?
}

// MARK: - Document

nonisolated struct DBMLDocument: Sendable {
    var projectName: String?
    var tables: [DBMLTable] = []
    var refs: [DBMLRef] = []
    var groups: [DBMLGroup] = []
    var notes: [DBMLStickyNote] = []
    var layout = DiagramLayout()
    /// The file's text without MxDataSQL's diagram section (kept as written on save).
    var body: String = ""

    static let sectionMarker = "// ===== MxDataSQL diagram: notes and layout (rewritten when the diagram is saved) ====="
    static let layoutPrefix = "// @mxdatasql-layout "

    func table(_ id: String) -> DBMLTable? { tables.first { $0.id == id } }

    /// The whole file: the body, then the diagram section with `notes` (own ones) and `layout`.
    func fileText(notes: [DBMLStickyNote], layout: DiagramLayout) -> String {
        var text = body
        while text.hasSuffix("\n\n") { text.removeLast() }
        if !text.hasSuffix("\n") { text += "\n" }
        text += "\n" + Self.sectionMarker + "\n"
        for note in notes where note.isOwn {
            text += "Note \(note.id) {\n  '''\n\(note.text.replacingOccurrences(of: "'''", with: "\\'\\'\\'"))\n  '''\n}\n"
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(layout), let json = String(data: data, encoding: .utf8) {
            text += Self.layoutPrefix + json + "\n"
        }
        return text
    }

    /// Splits a file into its body and MxDataSQL's diagram section (if any).
    static func split(_ text: String) -> (body: String, section: String?) {
        guard let range = text.range(of: sectionMarker) else { return (text, nil) }
        let lineStart = text[..<range.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        return (String(text[..<lineStart]), String(text[lineStart...]))
    }

    static func parseLayout(_ section: String?) -> DiagramLayout {
        guard let section,
              let line = section.split(separator: "\n").first(where: { $0.hasPrefix(layoutPrefix) }),
              let data = line.dropFirst(layoutPrefix.count).data(using: .utf8),
              let layout = try? JSONDecoder().decode(DiagramLayout.self, from: data) else { return DiagramLayout() }
        return layout
    }
}

// MARK: - Parser

nonisolated struct DBMLParseError: LocalizedError {
    var message: String
    var line: Int
    var errorDescription: String? { "DBML line \(line): \(message)" }
}

nonisolated enum DBMLParser {
    enum Kind: Equatable { case word, quoted, string, expression, symbol, newline }
    struct Token: Equatable {
        var kind: Kind
        var text: String
        var line: Int
    }

    /// Parses `text` (a whole .dbml file).
    static func parse(_ text: String) throws -> DBMLDocument {
        let (body, section) = DBMLDocument.split(text)
        var doc = DBMLDocument()
        doc.body = body
        doc.layout = DBMLDocument.parseLayout(section)
        var parser = Parser(tokens: tokenize(body))
        try parser.parseDocument(into: &doc, own: false)
        if let section {
            var own = Parser(tokens: tokenize(section))
            try own.parseDocument(into: &doc, own: true)
        }
        doc.resolveReferences()
        return doc
    }

    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(text)
        var i = 0, line = 1
        func peek(_ k: Int) -> Character? { i + k < chars.count ? chars[i + k] : nil }
        while i < chars.count {
            let c = chars[i]
            if c == "\n" {
                tokens.append(Token(kind: .newline, text: "\n", line: line)); line += 1; i += 1
            } else if c.isWhitespace {
                i += 1
            } else if c == "/" && peek(1) == "/" {
                while i < chars.count && chars[i] != "\n" { i += 1 }
            } else if c == "/" && peek(1) == "*" {
                i += 2
                while i < chars.count && !(chars[i] == "*" && peek(1) == "/") {
                    if chars[i] == "\n" { line += 1 }
                    i += 1
                }
                i += 2
            } else if c == "'" && peek(1) == "'" && peek(2) == "'" {
                // '''multi-line string''': common indentation removed, outer blank lines dropped
                i += 3
                var s = ""
                let start = line
                while i < chars.count && !(chars[i] == "'" && peek(1) == "'" && peek(2) == "'") {
                    if chars[i] == "\\" && i + 1 < chars.count { s.append(chars[i + 1]); i += 2; continue }
                    if chars[i] == "\n" { line += 1 }
                    s.append(chars[i]); i += 1
                }
                i += 3
                tokens.append(Token(kind: .string, text: dedent(s), line: start))
            } else if c == "'" || c == "\"" || c == "`" {
                i += 1
                var s = ""
                while i < chars.count && chars[i] != c && chars[i] != "\n" {
                    if chars[i] == "\\" && i + 1 < chars.count {
                        let n = chars[i + 1]
                        s.append(n == "n" ? "\n" : n); i += 2; continue
                    }
                    s.append(chars[i]); i += 1
                }
                i += 1
                tokens.append(Token(kind: c == "'" ? .string : c == "\"" ? .quoted : .expression, text: s, line: line))
            } else if c.isLetter || c.isNumber || c == "_" || c == "#" || (c == "-" && (peek(1)?.isNumber ?? false)) {
                var s = String(c); i += 1
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" || chars[i] == "#"
                        || (chars[i] == "." && (s.first?.isNumber ?? false) && (peek(1)?.isNumber ?? false)) {
                    s.append(chars[i]); i += 1
                }
                tokens.append(Token(kind: .word, text: s, line: line))
            } else if c == "<" && peek(1) == ">" {
                tokens.append(Token(kind: .symbol, text: "<>", line: line)); i += 2
            } else {
                tokens.append(Token(kind: .symbol, text: String(c), line: line)); i += 1
            }
        }
        return tokens
    }

    private static func dedent(_ s: String) -> String {
        var lines = s.components(separatedBy: "\n")
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        let indent = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
        return lines.map { String($0.dropFirst(min(indent, $0.count))) }.joined(separator: "\n")
    }

    struct Parser {
        var tokens: [Token]
        var pos = 0

        var current: Token? { pos < tokens.count ? tokens[pos] : nil }
        mutating func next() -> Token? { defer { pos += 1 }; return current }
        func isSymbol(_ s: String, at offset: Int = 0) -> Bool {
            pos + offset < tokens.count && tokens[pos + offset].kind == .symbol && tokens[pos + offset].text == s
        }
        func isWord(_ s: String) -> Bool {
            current?.kind == .word && current?.text.lowercased() == s.lowercased()
        }
        mutating func skipNewlines() { while current?.kind == .newline { pos += 1 } }
        mutating func skipToEndOfLine() { while let t = current, t.kind != .newline { pos += 1 } }
        var line: Int { current?.line ?? tokens.last?.line ?? 0 }
        mutating func expect(_ s: String) throws {
            guard isSymbol(s) else { throw DBMLParseError(message: "expected \(s)", line: line) }
            pos += 1
        }
        /// Skips a { ... } block (nested braces included).
        mutating func skipBlock() throws {
            try expect("{")
            var depth = 1
            while let t = next() {
                if t.kind == .symbol && t.text == "{" { depth += 1 }
                if t.kind == .symbol && t.text == "}" { depth -= 1; if depth == 0 { return } }
            }
            throw DBMLParseError(message: "missing }", line: line)
        }

        /// A name: word or "quoted"; dotted parts are returned separately.
        mutating func dottedName() -> [String] {
            var parts: [String] = []
            while let t = current, t.kind == .word || t.kind == .quoted {
                parts.append(t.text); pos += 1
                if isSymbol("."), let n = tokens[safe: pos + 1], n.kind == .word || n.kind == .quoted { pos += 1 } else { break }
            }
            return parts
        }

        mutating func parseDocument(into doc: inout DBMLDocument, own: Bool) throws {
            while true {
                skipNewlines()
                guard let t = current else { return }
                guard t.kind == .word else { pos += 1; continue }
                switch t.text.lowercased() {
                case "project":
                    pos += 1
                    let name = dottedName()
                    doc.projectName = doc.projectName ?? name.last
                    try skipBlock()
                case "table":
                    pos += 1
                    doc.tables.append(try parseTable())
                    doc.refs += pendingInline
                    pendingInline = []
                case "ref":
                    pos += 1
                    doc.refs += try parseRefStatement()
                case "tablegroup":
                    pos += 1
                    let name = dottedName().joined(separator: ".")
                    if isSymbol("[") { skipSettings() }
                    skipNewlines()
                    try expect("{")
                    var members: [String] = []
                    while let c = current, !(c.kind == .symbol && c.text == "}") {
                        if c.kind == .word && c.text.lowercased() == "note" && (isSymbol(":", at: 1) || isSymbol("{", at: 1)) {
                            pos += 1
                            if isSymbol("{") { try skipBlock() } else { skipToEndOfLine() }
                        } else if c.kind == .word || c.kind == .quoted {
                            members.append(tableID(dottedName()))
                            if isSymbol("[") { skipSettings() }
                        } else { pos += 1 }
                    }
                    try expect("}")
                    doc.groups.append(DBMLGroup(name: name, tables: members))
                case "note":
                    pos += 1
                    // Sticky note: Note name { 'text' }  (Note: inside other blocks is handled there)
                    let name = dottedName().joined(separator: ".")
                    if isSymbol("[") { skipSettings() }
                    skipNewlines()
                    guard isSymbol("{") else { skipToEndOfLine(); continue }
                    pos += 1
                    var text = ""
                    while let c = current, !(c.kind == .symbol && c.text == "}") {
                        if c.kind == .string { text += (text.isEmpty ? "" : "\n") + c.text }
                        pos += 1
                    }
                    try expect("}")
                    doc.notes.removeAll { $0.id == name }
                    doc.notes.append(DBMLStickyNote(id: name.isEmpty ? "note_\(doc.notes.count + 1)" : name, text: text, isOwn: own))
                default:
                    // Enum, TablePartial, Records, ...: skip the statement and its block.
                    pos += 1
                    while let c = current, c.kind != .newline, !(c.kind == .symbol && c.text == "{") { pos += 1 }
                    if isSymbol("{") { try skipBlock() }
                }
            }
        }

        mutating func skipSettings() {
            var depth = 0
            while let t = next() {
                if t.kind == .symbol && t.text == "[" { depth += 1 }
                if t.kind == .symbol && t.text == "]" { depth -= 1; if depth == 0 { return } }
            }
        }

        /// Splits a [ ... ] settings list into items (tokens per item).
        mutating func settings() -> [[Token]] {
            guard isSymbol("[") else { return [] }
            pos += 1
            var items: [[Token]] = [[]]
            var depth = 0
            while let t = next() {
                if t.kind == .symbol && (t.text == "[" || t.text == "(") { depth += 1 }
                if t.kind == .symbol && t.text == ")" { depth -= 1 }
                if t.kind == .symbol && t.text == "]" {
                    if depth == 0 { break }
                    depth -= 1
                }
                if t.kind == .symbol && t.text == "," && depth == 0 { items.append([]); continue }
                if t.kind == .newline { continue }
                items[items.count - 1].append(t)
            }
            return items.filter { !$0.isEmpty }
        }

        func tableID(_ parts: [String]) -> String {
            guard parts.count >= 2 else { return parts.first ?? "" }
            let schema = parts[parts.count - 2], name = parts[parts.count - 1]
            return schema == "public" ? name : "\(schema).\(name)"
        }

        mutating func parseTable() throws -> DBMLTable {
            let parts = dottedName()
            guard !parts.isEmpty else { throw DBMLParseError(message: "table name expected", line: line) }
            var table = DBMLTable(id: tableID(parts), schema: parts.count >= 2 ? parts[parts.count - 2] : "public",
                                  name: parts[parts.count - 1])
            if isWord("as") { pos += 1; table.alias = dottedName().last }
            _ = settings()
            skipNewlines()
            try expect("{")
            while true {
                skipNewlines()
                guard let t = current else { throw DBMLParseError(message: "missing } after table \(table.id)", line: line) }
                if t.kind == .symbol && t.text == "}" { pos += 1; break }
                if t.kind == .word && t.text.lowercased() == "note" && (isSymbol(":", at: 1) || isSymbol("{", at: 1)) {
                    pos += 1
                    if isSymbol(":") { pos += 1; if current?.kind == .string { table.note = next()?.text } }
                    else {
                        pos += 1
                        while let c = current, !(c.kind == .symbol && c.text == "}") {
                            if c.kind == .string { table.note = c.text }
                            pos += 1
                        }
                        pos += 1
                    }
                    skipToEndOfLine()
                    continue
                }
                if t.kind == .word && t.text.lowercased() == "indexes" && isSymbol("{", at: 1) {
                    pos += 1
                    let start = pos
                    try skipBlock()
                    table.indexCount = tokens[start..<pos].filter { $0.kind == .newline }.count - 1
                    continue
                }
                guard t.kind == .word || t.kind == .quoted else { skipToEndOfLine(); continue }
                // column: name type [settings]
                pos += 1
                var column = DBMLColumn(name: t.text, type: "")
                var type = ""
                while let c = current, c.kind != .newline, !(c.kind == .symbol && c.text == "}") {
                    if c.kind == .symbol && c.text == "[" {
                        if isSymbol("]", at: 1) { type += "[]"; pos += 2; continue }
                        break
                    }
                    switch c.kind {
                    case .quoted: type += c.text
                    case .word: type += (type.isEmpty || type.hasSuffix("(") || type.hasSuffix(",") ? "" : " ") + c.text
                    default: type += c.text
                    }
                    pos += 1
                }
                column.type = type
                for item in settings() {
                    let words = item.map { $0.text.lowercased() }
                    switch words.first {
                    case "pk": column.isPrimaryKey = true
                    case "primary": column.isPrimaryKey = true
                    case "not": column.isNotNull = true
                    case "unique": column.isUnique = true
                    case "increment": column.isIncrement = true
                    case "default": column.defaultValue = item.dropFirst(2).map(\.text).joined(separator: " ")
                    case "note": column.note = item.first { $0.kind == .string }?.text
                    case "ref":
                        // inline ref: ref: > schema.table.column
                        var p = Parser(tokens: Array(item.dropFirst(2)) + [Token(kind: .newline, text: "\n", line: 0)])
                        if let op = p.next(), let relation = DBMLRelation(rawValue: op.text) {
                            let target = p.dottedName()
                            if target.count >= 2 {
                                pendingInline.append(DBMLRef(
                                    from: DBMLEndpoint(table: table.id, columns: [column.name]),
                                    to: DBMLEndpoint(table: tableID(Array(target.dropLast())), columns: [target.last!]),
                                    relation: relation))
                            }
                        }
                    default: break
                    }
                }
                table.columns.append(column)
                skipToEndOfLine()
            }
            return table
        }

        var pendingInline: [DBMLRef] = []

        mutating func endpoint() -> DBMLEndpoint? {
            var parts = dottedName()
            var columns: [String] = []
            if isSymbol("."), isSymbol("(", at: 1) {
                pos += 2
                while let c = current, !(c.kind == .symbol && c.text == ")") {
                    if c.kind == .word || c.kind == .quoted { columns.append(c.text) }
                    pos += 1
                }
                pos += 1
            } else if let last = parts.popLast() {
                columns = [last]
            }
            guard !parts.isEmpty, !columns.isEmpty else { return nil }
            return DBMLEndpoint(table: tableID(parts), columns: columns)
        }

        mutating func refLine() -> DBMLRef? {
            guard let from = endpoint(), let op = current, op.kind == .symbol,
                  let relation = DBMLRelation(rawValue: op.text) else { skipToEndOfLine(); return nil }
            pos += 1
            guard let to = endpoint() else { skipToEndOfLine(); return nil }
            var ref = DBMLRef(from: from, to: to, relation: relation)
            for item in settings() where item.first?.text.lowercased() == "color" {
                ref.color = item.dropFirst(2).map(\.text).joined()
            }
            skipToEndOfLine()
            return ref
        }

        mutating func parseRefStatement() throws -> [DBMLRef] {
            _ = dottedName()                     // optional name
            if isSymbol(":") {
                pos += 1
                return refLine().map { [$0] } ?? []
            }
            skipNewlines()
            try expect("{")
            var refs: [DBMLRef] = []
            while true {
                skipNewlines()
                guard let c = current else { break }
                if c.kind == .symbol && c.text == "}" { pos += 1; break }
                if let ref = refLine() { refs.append(ref) }
            }
            return refs
        }
    }
}

nonisolated extension DBMLDocument {
    /// Inline refs become refs; endpoints written with an alias or a bare name of a table in another
    /// schema are matched to their table.
    mutating func resolveReferences() {
        let ids = Set(tables.map(\.id))
        var byAlias: [String: String] = [:]
        for t in tables {
            if let a = t.alias { byAlias[a] = t.id }
            if byAlias[t.name] == nil { byAlias[t.name] = t.id }
        }
        func fix(_ e: DBMLEndpoint) -> DBMLEndpoint {
            var e = e
            if !ids.contains(e.table), let id = byAlias[e.table] { e.table = id }
            return e
        }
        refs = refs.map { var r = $0; r.from = fix(r.from); r.to = fix(r.to); return r }
            .filter { ids.contains($0.from.table) && ids.contains($0.to.table) }
        groups = groups.map { g in DBMLGroup(name: g.name, tables: g.tables.map { ids.contains($0) ? $0 : byAlias[$0] ?? $0 }) }
        // De-duplicate (the same relationship written twice).
        var seen = Set<String>()
        refs = refs.filter { seen.insert($0.id).inserted }
    }
}

nonisolated private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
