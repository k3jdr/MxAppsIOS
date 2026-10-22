//
//  DBMLLanguage.swift
//  Shared/DBML — used by MxDataSQL and MxNoteONE
//
//  DBML (dbml.dbdiagram.io), the Database Markup Language: the schema a .dbml file describes —
//  tables and their columns, enums, relationships (Ref), table groups, sticky notes and the Project —
//  read by a forgiving parser (what it can't read is listed by line; the rest still shows), the
//  diagram section MxDataSQL keeps at the end of a file (its own notes and a layout comment), DBML's
//  colours for a text editor, and the DBML of one schema cut out of a file.
//

import AppKit

// MARK: - The schema DBML describes

struct DBMLSchema {
    struct Column {
        var name: String
        var type: String
        var pk = false
        var notNull = false
        var unique = false
        var increment = false
        var defaultValue: String?
        var note: String?
    }

    struct Table {
        /// The table's key: "name" in the public schema (or none), else "schema.name".
        var name: String
        var alias: String?
        var columns: [Column] = []
        var note: String?
        var headerColor: String?
        var indexCount = 0
        var line: Int
        var endLine: Int = 0

        var id: String { name }
        /// The schema it's in ("public" when none is written).
        var schema: String { name.lastIndex(of: ".").map { String(name[..<$0]) } ?? "public" }
        var shortName: String { name.lastIndex(of: ".").map { String(name[name.index(after: $0)...]) } ?? name }
    }

    struct Enum {
        var name: String
        var values: [(name: String, note: String?)] = []
        var line: Int
        var endLine: Int = 0

        var schema: String { name.lastIndex(of: ".").map { String(name[..<$0]) } ?? "public" }
    }

    struct End: Equatable {
        var table: String
        var columns: [String]
        var text: String { table + "." + (columns.count == 1 ? columns[0] : "(" + columns.joined(separator: ", ") + ")") }
    }

    /// `>` many-to-one, `<` one-to-many, `-` one-to-one, `<>` many-to-many (as written: from `op` to).
    struct Ref {
        var name: String?
        var from: End
        var to: End
        var op: String
        var line: Int
        /// Written inside a column's settings ([ref: > other.id]) rather than as a Ref of its own.
        var inline = false
        /// Its settings as written ([delete: cascade]).
        var settings: String?
        /// MxNoteONE's earlier key for it ("a.b > c.d"; kept to read diagrams saved before the shared library).
        var key = ""

        /// The relationship's id, as MxDataSQL names it in its layout: from.(columns) op to.(columns).
        var id: String {
            "\(from.table).(\(from.columns.joined(separator: ",")))\(op)\(to.table).(\(to.columns.joined(separator: ",")))"
        }
        var fromMany: Bool { op == ">" || op == "<>" }
        var toMany: Bool { op == "<" || op == "<>" }
        var kindTitle: String {
            switch op {
            case ">": "many-to-one"
            case "<": "one-to-many"
            case "-": "one-to-one"
            default: "many-to-many"
            }
        }
        var text: String { "\(from.text) \(op) \(to.text)" }
    }

    struct Group {
        var name: String
        var tables: [String]
        var color: String?
        var line: Int
        var endLine: Int = 0
    }

    struct StickyNote {
        var name: String
        var text: String
        var line: Int
        var endLine: Int = 0
    }

    struct Problem: Equatable {
        var line: Int
        var message: String
    }

    var project: String?
    var projectLines: ClosedRange<Int>?
    var tables: [Table] = []
    var enums: [Enum] = []
    var refs: [Ref] = []
    var groups: [Group] = []
    var notes: [StickyNote] = []
    var problems: [Problem] = []

    func table(_ name: String) -> Table? { tables.first { $0.name == name } }

    /// The schemas its tables are in, in the order they first appear.
    var schemas: [String] {
        var seen = Set<String>()
        return tables.map(\.schema).filter { seen.insert($0).inserted }
    }

    /// The columns of a table that refer to another table (foreign keys), as MxDataSQL marks them.
    func foreignKeys(of table: String) -> Set<String> {
        Set(refs.filter { $0.from.table == table && $0.op != "<" }.flatMap(\.from.columns)
            + refs.filter { $0.to.table == table && $0.op == "<" }.flatMap(\.to.columns))
    }
}

// MARK: - Reading DBML

enum DBMLParser {
    enum Kind: Equatable { case word, quoted, string, expr, number, color, symbol, newline }

    struct Token {
        var kind: Kind
        var text: String
        var line: Int
    }

    static let keywords: Set<String> = ["table", "ref", "enum", "note", "project", "tablegroup", "indexes", "as", "tablepartial", "records"]

    /// Splits DBML into tokens (comments dropped; newlines kept, since a table has a column per line).
    static func tokens(_ source: String) -> [Token] {
        let chars = Array(source)
        var result: [Token] = []
        var i = 0, line = 1
        func peek(_ k: Int = 0) -> Character? { i + k < chars.count ? chars[i + k] : nil }
        while i < chars.count {
            let c = chars[i]
            if c == "\n" {
                result.append(Token(kind: .newline, text: "\n", line: line))
                line += 1
                i += 1
            } else if c.isWhitespace {
                i += 1
            } else if c == "/", peek(1) == "/" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
            } else if c == "/", peek(1) == "*" {
                i += 2
                while i < chars.count, !(chars[i] == "*" && peek(1) == "/") {
                    if chars[i] == "\n" { line += 1 }
                    i += 1
                }
                i += 2
            } else if c == "'" {
                let start = line
                if peek(1) == "'", peek(2) == "'" {
                    // '''multi-line''': its lines lose the indent they share.
                    i += 3
                    var s = ""
                    while i < chars.count, !(chars[i] == "'" && peek(1) == "'" && peek(2) == "'") {
                        if chars[i] == "\n" { line += 1 }
                        s.append(chars[i])
                        i += 1
                    }
                    i += 3
                    result.append(Token(kind: .string, text: dedent(s), line: start))
                } else {
                    i += 1
                    var s = ""
                    while i < chars.count, chars[i] != "'", chars[i] != "\n" {
                        if chars[i] == "\\", let next = peek(1) { s.append(next == "n" ? "\n" : next); i += 2; continue }
                        s.append(chars[i])
                        i += 1
                    }
                    i += 1
                    result.append(Token(kind: .string, text: s, line: start))
                }
            } else if c == "\"" {
                i += 1
                var s = ""
                while i < chars.count, chars[i] != "\"", chars[i] != "\n" { s.append(chars[i]); i += 1 }
                i += 1
                result.append(Token(kind: .quoted, text: s, line: line))
            } else if c == "`" {
                i += 1
                var s = ""
                while i < chars.count, chars[i] != "`" { s.append(chars[i]); i += 1 }
                i += 1
                result.append(Token(kind: .expr, text: s, line: line))
            } else if c == "#" {
                var s = "#"
                i += 1
                while i < chars.count, chars[i].isHexDigit { s.append(chars[i]); i += 1 }
                result.append(Token(kind: .color, text: s, line: line))
            } else if c.isNumber || (c == "-" && (peek(1)?.isNumber ?? false) && result.last.map { $0.kind == .symbol && $0.text == ":" } == true) {
                var s = String(c)
                i += 1
                while i < chars.count, chars[i].isNumber || chars[i] == "." { s.append(chars[i]); i += 1 }
                result.append(Token(kind: .number, text: s, line: line))
            } else if c.isLetter || c == "_" {
                var s = ""
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" { s.append(chars[i]); i += 1 }
                result.append(Token(kind: .word, text: s, line: line))
            } else if c == "<", peek(1) == ">" {
                result.append(Token(kind: .symbol, text: "<>", line: line))
                i += 2
            } else {
                result.append(Token(kind: .symbol, text: String(c), line: line))
                i += 1
            }
        }
        return result
    }

    private static func dedent(_ s: String) -> String {
        var lines = s.components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        if lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        let indent = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
        return lines.map { String($0.dropFirst(min(indent, $0.prefix { $0 == " " || $0 == "\t" }.count))) }.joined(separator: "\n")
    }

    /// The last few DBML texts read (a diagram is laid out again on every move while dragging).
    private static var parsed: [(source: String, schema: DBMLSchema)] = []

    /// Reads DBML. What it can't read is listed in `problems` (by line); the rest still shows.
    static func parse(_ source: String) -> DBMLSchema {
        if let hit = parsed.first(where: { $0.source == source }) { return hit.schema }
        let schema = read(source)
        parsed.insert((source, schema), at: 0)
        if parsed.count > 6 { parsed.removeLast() }
        return schema
    }

    private static func read(_ source: String) -> DBMLSchema {
        var p = Reader(tokens: tokens(source))
        p.run()
        var schema = p.schema
        // Aliases and the public schema name the same table.
        var aliases: [String: String] = [:]
        for t in schema.tables { if let a = t.alias { aliases[a] = t.name } }
        func resolve(_ end: DBMLSchema.End) -> DBMLSchema.End {
            var e = end
            if let real = aliases[e.table] { e.table = real }
            if e.table.hasPrefix("public.") { e.table = String(e.table.dropFirst(7)) }
            return e
        }
        var seen: [String: Int] = [:]
        var ids = Set<String>()
        schema.refs = schema.refs.map { r in var r = r; r.from = resolve(r.from); r.to = resolve(r.to); return r }
            .filter { ids.insert($0.id).inserted }
        for i in schema.refs.indices {
            schema.refs[i].from = resolve(schema.refs[i].from)
            schema.refs[i].to = resolve(schema.refs[i].to)
            let r = schema.refs[i]
            var key = r.from.text + " " + r.op + " " + r.to.text
            seen[key, default: 0] += 1
            if seen[key]! > 1 { key += " #\(seen[key]!)" }
            schema.refs[i].key = key
            for end in [r.from, r.to] {
                if let t = schema.table(end.table) {
                    for c in end.columns where !t.columns.contains(where: { $0.name == c }) {
                        schema.problems.append(.init(line: r.line, message: "Table “\(t.name)” has no column “\(c)”"))
                    }
                } else {
                    schema.problems.append(.init(line: r.line, message: "No table “\(end.table)” (in Ref \(r.from.text) \(r.op) \(r.to.text))"))
                }
            }
        }
        for g in schema.groups.indices {
            schema.groups[g].tables = schema.groups[g].tables.map { aliases[$0] ?? ($0.hasPrefix("public.") ? String($0.dropFirst(7)) : $0) }
        }
        return schema
    }

    private struct Reader {
        let tokens: [Token]
        var i = 0
        var schema = DBMLSchema()

        init(tokens: [Token]) { self.tokens = tokens }

        /// The line of the last token read (a statement's closing brace).
        var lastLine: Int { i > 0 && i - 1 < tokens.count ? tokens[i - 1].line : line }

        var current: Token? { i < tokens.count ? tokens[i] : nil }
        var line: Int { current?.line ?? (tokens.last?.line ?? 1) }

        func isSymbol(_ s: String, _ offset: Int = 0) -> Bool {
            i + offset < tokens.count && tokens[i + offset].kind == .symbol && tokens[i + offset].text == s
        }
        func isWord(_ w: String) -> Bool {
            guard let t = current, t.kind == .word else { return false }
            return t.text.lowercased() == w
        }
        mutating func skipNewlines() { while current?.kind == .newline { i += 1 } }
        mutating func skipLine() { while let t = current, t.kind != .newline { i += 1 } }
        mutating func problem(_ message: String) { schema.problems.append(.init(line: line, message: message)) }

        /// A name: words or "quoted" parts joined by dots (schema.table).
        mutating func name() -> String? {
            var parts: [String] = []
            while let t = current, t.kind == .word || t.kind == .quoted {
                parts.append(t.text)
                i += 1
                if isSymbol("."), i + 1 < tokens.count, tokens[i + 1].kind == .word || tokens[i + 1].kind == .quoted { i += 1 } else { break }
            }
            return parts.isEmpty ? nil : parts.joined(separator: ".")
        }

        /// Skips a { … } block (nested blocks too).
        mutating func skipBlock() {
            guard isSymbol("{") else { return }
            var depth = 0
            while let t = current {
                i += 1
                if t.kind == .symbol, t.text == "{" { depth += 1 }
                if t.kind == .symbol, t.text == "}" { depth -= 1; if depth == 0 { return } }
            }
        }

        /// The settings in [ … ], as (name, value) pairs: `pk`, `not null`, `note: '…'`, `ref: > a.b`…
        mutating func settings() -> [(String, [Token])] {
            guard isSymbol("[") else { return [] }
            i += 1
            var result: [(String, [Token])] = []
            var name: [String] = [], value: [Token] = [], inValue = false, depth = 0
            func flush() {
                let n = name.joined(separator: " ").lowercased()
                if !n.isEmpty || !value.isEmpty { result.append((n, value)) }
                name = []; value = []; inValue = false
            }
            while let t = current {
                if t.kind == .symbol, t.text == "]", depth == 0 { i += 1; break }
                if t.kind == .newline { i += 1; continue }
                if t.kind == .symbol, t.text == "(" || t.text == "[" { depth += 1 }
                if t.kind == .symbol, t.text == ")" || (t.text == "]" && depth > 0) { depth -= 1 }
                if t.kind == .symbol, t.text == ",", depth == 0 { flush(); i += 1; continue }
                if !inValue, t.kind == .symbol, t.text == ":" { inValue = true; i += 1; continue }
                if inValue { value.append(t) } else if t.kind == .word { name.append(t.text) } else { value.append(t) }
                i += 1
            }
            flush()
            return result
        }

        static func text(_ value: [Token]) -> String {
            var s = ""
            for t in value {
                switch t.kind {
                case .symbol where t.text == "(" || t.text == ")" || t.text == "," || t.text == ".": s += t.text
                default: s += (s.isEmpty || s.hasSuffix("(") || s.hasSuffix(".") || s.hasSuffix(",") ? "" : " ") + t.text
                }
            }
            return s
        }

        /// One end of a relationship: table.column, schema.table.column or table.(a, b).
        mutating func end() -> DBMLSchema.End? {
            var parts: [String] = []
            while let t = current, t.kind == .word || t.kind == .quoted {
                parts.append(t.text)
                i += 1
                guard isSymbol(".") else { break }
                i += 1
                if isSymbol("(") {
                    i += 1
                    var columns: [String] = []
                    while let c = current, !(c.kind == .symbol && c.text == ")") {
                        if c.kind == .word || c.kind == .quoted { columns.append(c.text) }
                        if c.kind == .newline { break }
                        i += 1
                    }
                    if isSymbol(")") { i += 1 }
                    return parts.isEmpty ? nil : DBMLSchema.End(table: parts.joined(separator: "."), columns: columns)
                }
            }
            guard parts.count >= 2 else { return nil }
            return DBMLSchema.End(table: parts.dropLast().joined(separator: "."), columns: [parts.last!])
        }

        mutating func refBody(name: String?, line: Int) {
            guard let from = end() else { problem("A Ref needs table.column on each side (users.id < posts.user_id)"); skipLine(); return }
            guard let op = current, op.kind == .symbol, ["<", ">", "-", "<>"].contains(op.text) else {
                problem("A Ref needs <, >, - or <> between its ends"); skipLine(); return
            }
            i += 1
            guard let to = end() else { problem("A Ref needs table.column on each side"); skipLine(); return }
            let s = settings()
            let written = s.map { $0.0 + ($0.1.isEmpty ? "" : ": " + Self.text($0.1)) }.joined(separator: ", ")
            schema.refs.append(.init(name: name, from: from, to: to, op: op.text, line: line, settings: written.isEmpty ? nil : "[" + written + "]"))
        }

        mutating func run() {
            while current != nil {
                skipNewlines()
                guard let t = current else { break }
                let startLine = t.line
                guard t.kind == .word else {
                    problem("Unexpected “\(t.text)”")
                    i += 1
                    skipLine()
                    continue
                }
                switch t.text.lowercased() {
                case "table":
                    i += 1
                    table(line: startLine)
                case "enum":
                    i += 1
                    enumeration(line: startLine)
                case "ref":
                    i += 1
                    let refName = isSymbol(":") || isSymbol("{") ? nil : name()
                    if isSymbol(":") {
                        i += 1
                        refBody(name: refName, line: startLine)
                    } else if isSymbol("{") {
                        i += 1
                        while current != nil, !isSymbol("}") {
                            skipNewlines()
                            if isSymbol("}") { break }
                            refBody(name: refName, line: line)
                            skipNewlines()
                        }
                        if isSymbol("}") { i += 1 }
                    } else {
                        problem("A Ref is written Ref: a.b > c.d (or Ref name { … })")
                        skipLine()
                    }
                case "tablegroup":
                    i += 1
                    group(line: startLine)
                case "note":
                    i += 1
                    stickyNote(line: startLine)
                case "project":
                    i += 1
                    schema.project = name()
                    _ = settings()
                    skipNewlines()
                    skipBlock()
                    schema.projectLines = startLine...max(startLine, lastLine)
                case "tablepartial", "records":
                    i += 1
                    _ = name()
                    while let c = current, c.kind != .newline, !(c.kind == .symbol && c.text == "{") { i += 1 }
                    skipBlock()
                default:
                    problem("Unknown “\(t.text)” (expected Table, Enum, Ref, TableGroup, Note or Project)")
                    i += 1
                    skipLine()
                }
            }
        }

        mutating func table(line: Int) {
            guard var tableName = name() else { problem("A Table needs a name"); skipLine(); return }
            if tableName.hasPrefix("public.") { tableName = String(tableName.dropFirst(7)) }
            var table = DBMLSchema.Table(name: tableName, line: line)
            if isWord("as") {
                i += 1
                table.alias = name()
            }
            for (key, value) in settings() {
                if key == "headercolor" { table.headerColor = value.first?.text }
                if key == "note" { table.note = value.first?.text }
            }
            skipNewlines()
            guard isSymbol("{") else { problem("Table \(tableName) needs { … }"); skipLine(); return }
            i += 1
            while let t = current, !(t.kind == .symbol && t.text == "}") {
                if t.kind == .newline { i += 1; continue }
                if t.kind == .word, t.text.lowercased() == "note" {
                    i += 1
                    if isSymbol(":") {
                        i += 1
                        table.note = current?.text
                        skipLine()
                    } else if isSymbol("{") {
                        i += 1
                        skipNewlines()
                        table.note = current?.text
                        while current != nil, !isSymbol("}") { i += 1 }
                        if isSymbol("}") { i += 1 }
                    }
                    continue
                }
                if t.kind == .word, t.text.lowercased() == "indexes" {
                    i += 1
                    skipNewlines()
                    indexes(&table)
                    continue
                }
                if t.kind == .symbol, t.text == "~" {
                    // A table partial (~name) brings in columns written elsewhere.
                    skipLine()
                    continue
                }
                column(&table)
            }
            if isSymbol("}") { i += 1 } else { problem("Table \(tableName) is missing its closing }") }
            table.endLine = lastLine
            if schema.tables.contains(where: { $0.name == table.name }) { schema.problems.append(.init(line: line, message: "Table “\(table.name)” is defined twice")) }
            schema.tables.append(table)
        }

        mutating func column(_ table: inout DBMLSchema.Table) {
            let columnLine = line
            guard let t = current, t.kind == .word || t.kind == .quoted else {
                problem("Expected a column name in table \(table.name)")
                skipLine()
                return
            }
            i += 1
            var type: [Token] = []
            while let c = current, c.kind != .newline, !(c.kind == .symbol && (c.text == "}" || (c.text == "[" && !isSymbol("]", 1)))) {
                if c.kind == .symbol, c.text == "[" { type.append(c); i += 1; type.append(current!); i += 1; continue }
                type.append(c)
                i += 1
            }
            var col = DBMLSchema.Column(name: t.text, type: Self.text(type).replacingOccurrences(of: " [ ]", with: "[]").replacingOccurrences(of: " []", with: "[]"))
            if col.type.isEmpty { schema.problems.append(.init(line: columnLine, message: "Column \(table.name).\(t.text) needs a type")) }
            for (key, value) in settings() {
                switch key {
                case "pk", "primary key": col.pk = true
                case "not null": col.notNull = true
                case "unique": col.unique = true
                case "increment": col.increment = true
                case "note": col.note = value.first?.text
                case "default": col.defaultValue = Self.text(value)
                case "ref":
                    var sub = Reader(tokens: value + [Token(kind: .newline, text: "\n", line: columnLine)])
                    if let op = sub.current, op.kind == .symbol, ["<", ">", "-", "<>"].contains(op.text) {
                        sub.i += 1
                        if let to = sub.end() {
                            schema.refs.append(.init(name: nil, from: .init(table: table.name, columns: [col.name]), to: to, op: op.text, line: columnLine, inline: true))
                            continue
                        }
                    }
                    schema.problems.append(.init(line: columnLine, message: "An inline ref is written [ref: > table.column]"))
                default: break
                }
            }
            table.columns.append(col)
            if let c = current, c.kind != .newline, !(c.kind == .symbol && c.text == "}") { skipLine() }
        }

        /// indexes { … }: a primary key on a column (or columns) marks them.
        mutating func indexes(_ table: inout DBMLSchema.Table) {
            guard isSymbol("{") else { return }
            i += 1
            while let t = current, !(t.kind == .symbol && t.text == "}") {
                if t.kind == .newline { i += 1; continue }
                var columns: [String] = []
                if isSymbol("(") {
                    i += 1
                    while let c = current, !(c.kind == .symbol && c.text == ")"), c.kind != .newline {
                        if c.kind == .word || c.kind == .quoted { columns.append(c.text) }
                        i += 1
                    }
                    if isSymbol(")") { i += 1 }
                } else if t.kind == .word || t.kind == .quoted {
                    columns = [t.text]
                    i += 1
                } else {
                    i += 1
                }
                let s = settings()
                if !columns.isEmpty { table.indexCount += 1 }
                if s.contains(where: { $0.0 == "pk" || $0.0 == "primary key" }) {
                    for c in columns { if let k = table.columns.firstIndex(where: { $0.name == c }) { table.columns[k].pk = true } }
                }
                if s.contains(where: { $0.0 == "unique" }), columns.count == 1, let k = table.columns.firstIndex(where: { $0.name == columns[0] }) {
                    table.columns[k].unique = true
                }
                skipLine()
            }
            if isSymbol("}") { i += 1 }
        }

        mutating func enumeration(line: Int) {
            guard let enumName = name() else { problem("An Enum needs a name"); skipLine(); return }
            var e = DBMLSchema.Enum(name: enumName.hasPrefix("public.") ? String(enumName.dropFirst(7)) : enumName, line: line)
            skipNewlines()
            guard isSymbol("{") else { problem("Enum \(enumName) needs { … }"); skipLine(); return }
            i += 1
            while let t = current, !(t.kind == .symbol && t.text == "}") {
                if t.kind == .newline { i += 1; continue }
                if t.kind == .word || t.kind == .quoted || t.kind == .number {
                    i += 1
                    let note = settings().first { $0.0 == "note" }?.1.first?.text
                    e.values.append((t.text, note))
                } else {
                    i += 1
                }
            }
            if isSymbol("}") { i += 1 }
            e.endLine = lastLine
            schema.enums.append(e)
        }

        mutating func group(line: Int) {
            guard let groupName = name() else { problem("A TableGroup needs a name"); skipLine(); return }
            var g = DBMLSchema.Group(name: groupName, tables: [], line: line)
            for (key, value) in settings() where key == "color" { g.color = value.first?.text }
            skipNewlines()
            guard isSymbol("{") else { problem("TableGroup \(groupName) needs { … }"); skipLine(); return }
            i += 1
            while let t = current, !(t.kind == .symbol && t.text == "}") {
                if t.kind == .newline { i += 1; continue }
                if t.kind == .word, t.text.lowercased() == "note" { skipLine(); continue }
                if let n = name() { g.tables.append(n) } else { i += 1 }
            }
            if isSymbol("}") { i += 1 }
            g.endLine = lastLine
            schema.groups.append(g)
        }

        mutating func stickyNote(line: Int) {
            guard let noteName = name() else { problem("A sticky note is written Note name { '…' }"); skipLine(); return }
            skipNewlines()
            guard isSymbol("{") else { problem("Note \(noteName) needs { '…' }"); skipLine(); return }
            i += 1
            skipNewlines()
            let text = current?.kind == .string ? current!.text : ""
            while current != nil, !isSymbol("}") { i += 1 }
            if isSymbol("}") { i += 1 }
            schema.notes.append(.init(name: noteName, text: text, line: line, endLine: lastLine))
        }
    }
}

// MARK: - MxDataSQL's diagram section

/// The end of a .dbml file as MxDataSQL writes it: after a marker line, its own sticky notes and one comment
/// line with the diagram's layout — where each table sits, each relationship's curve, each note's frame.
/// Other DBML tools read the notes and skip the comment.
enum DBMLFileLayout {
    static let sectionMarker = "// ===== MxDataSQL diagram: notes and layout (rewritten when the diagram is saved) ====="
    static let prefix = "// @mxdatasql-layout "

    struct Point: Codable, Equatable {
        var x: Double
        var y: Double
    }

    struct Curve: Codable, Equatable {
        var style: String?
        var c1: Point?
        var c2: Point?
        var fromSide: String?
        var toSide: String?
        var color: String?
    }

    struct Frame: Codable, Equatable {
        var x: Double
        var y: Double
        var width: Double?
        var height: Double?
        var color: String?
    }

    struct Layout: Codable, Equatable {
        var tables: [String: Point] = [:]
        var refs: [String: Curve] = [:]
        var notes: [String: Frame] = [:]
        var zoom: Double?
        /// Written by an MxNoteONE before the shared library (its boxes were taller then); read and ignored.
        var mxnoteone: Bool?

        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tables = (try? c.decode([String: Point].self, forKey: .tables)) ?? [:]
            refs = (try? c.decode([String: Curve].self, forKey: .refs)) ?? [:]
            notes = (try? c.decode([String: Frame].self, forKey: .notes)) ?? [:]
            zoom = try? c.decode(Double.self, forKey: .zoom)
            mxnoteone = try? c.decode(Bool.self, forKey: .mxnoteone)
        }
    }

    /// The file's DBML, and its diagram section (from the marker line on), if it has one.
    static func split(_ text: String) -> (body: String, section: String?) {
        guard let range = text.range(of: sectionMarker) else { return (text, nil) }
        let lineStart = text[..<range.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        return (String(text[..<lineStart]), String(text[lineStart...]))
    }

    /// The layout line in a diagram section (nil without one).
    static func layout(inSection section: String) -> Layout? {
        guard let line = section.split(separator: "\n").first(where: { $0.hasPrefix(prefix) }),
              let data = line.dropFirst(prefix.count).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Layout.self, from: data)
    }

    static func layout(in text: String) -> Layout? { split(text).section.flatMap { layout(inSection: $0) } }

    /// The layout as its comment line.
    static func line(_ layout: Layout) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(layout), let json = String(data: data, encoding: .utf8) else { return "" }
        return prefix + json
    }
}

// MARK: - Colours for DBML being typed

enum DBMLSyntax {
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    private static func hex(_ s: String) -> NSColor { DBMLColor.hex(s) ?? .labelColor }

    private static let rules: [(NSRegularExpression, NSColor)] = {
        func re(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: o) }
        return [
            (re("\\b(Table|Ref|Enum|Note|Project|TableGroup|TablePartial|Records|indexes|as)\\b", [.caseInsensitive]), hex("#AF00DB")),
            (re("\\[[^\\]\\n]*\\]"), hex("#267F99")),
            (re("(?<![\\w.])-?\\d+(\\.\\d+)?\\b"), hex("#098658")),
            (re("\\s(<>|<|>|-)\\s"), hex("#E07B24")),
            (re("#[0-9A-Fa-f]{3,8}\\b"), hex("#795E26")),
            (re("\"[^\"\\n]*\""), hex("#001080")),
            (re("`[^`]*`"), hex("#795E26")),
            (re("'''[\\s\\S]*?'''|'[^'\\n]*'"), hex("#A31515")),
            (re("//[^\\n]*|/\\*[\\s\\S]*?\\*/"), hex("#008000")),
        ]
    }()

    /// Colours DBML text in place: keywords, settings, numbers, relationships, colours, strings and comments.
    static func highlight(_ storage: NSTextStorage, font: NSFont = font, text color: NSColor = NSColor(white: 0.15, alpha: 1)) {
        let all = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: color], range: all)
        for (rule, c) in rules {
            for m in rule.matches(in: storage.string, range: all) { storage.addAttribute(.foregroundColor, value: c, range: m.range) }
        }
        storage.endEditing()
    }
}

/// Colours written as "#rrggbb".
enum DBMLColor {
    static func hex(_ s: String) -> NSColor? {
        var t = s.trimmingCharacters(in: CharacterSet(charactersIn: "#'\" "))
        if t.count == 3 { t = t.map { "\($0)\($0)" }.joined() }
        guard t.count == 6, let v = Int(t, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    static func hexString(_ c: NSColor) -> String {
        let s = c.usingColorSpace(.sRGB) ?? c
        return String(format: "#%02X%02X%02X", Int(s.redComponent * 255), Int(s.greenComponent * 255), Int(s.blueComponent * 255))
    }
}
