//
//  DBMLModel.swift
//  MxNoteONE
//
//  A database diagram written in DBML (dbdiagram.io's Database Markup
//  Language): tables with their columns, enums, relationships (Ref),
//  table groups and sticky notes. The page keeps the DBML, where each table
//  was dragged to, how each relationship's line is drawn (straight, or a
//  quadratic or cubic Bézier curve through control points), and notes laid
//  over the diagram. The parser reads DBML into a schema; the layout gives
//  every box and line its place, for the diagram on the page and its
//  pictures; the writer exports DBML (with the overlay notes as sticky
//  notes).
//

import AppKit

// MARK: - Saved with the page

struct DBMLPoint: Codable, Equatable, Hashable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) { self.x = x; self.y = y }
    init(_ p: CGPoint) { x = p.x; y = p.y }
    var cg: CGPoint { CGPoint(x: x, y: y) }
}

/// How a relationship's line runs between its tables.
enum DBMLCurve: String, Codable, CaseIterable, Identifiable {
    case straight, quadratic, cubic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .straight: "Straight"
        case .quadratic: "Quadratic Bézier Curve"
        case .cubic: "Cubic Bézier Curve"
        }
    }

    var symbol: String {
        switch self {
        case .straight: "line.diagonal"
        case .quadratic: "point.topleft.down.to.point.bottomright.curvepath"
        case .cubic: "point.bottomleft.forward.to.point.topright.scurvepath"
        }
    }
}

/// The side of a table a line leaves or meets.
enum DBMLSide: String, Codable, CaseIterable {
    case left, right
}

/// A relationship line as the user shaped it. Control points are kept as offsets, so the curve keeps its shape
/// when its tables move: a quadratic curve's from the middle of its ends, a cubic curve's first from its start and
/// second from its end.
struct DBMLLine: Codable, Equatable {
    var curve: DBMLCurve?
    var c1: DBMLPoint?
    var c2: DBMLPoint?
    var fromSide: DBMLSide?
    var toSide: DBMLSide?
    /// The line's own colour (hex), else the diagram's.
    var color: String?

    var isPlain: Bool { self == DBMLLine() }
}

/// A note laid over the diagram (also written out as a DBML sticky note).
struct DBMLNote: Codable, Equatable, Identifiable {
    var id = UUID()
    var text: String
    var x: Double
    var y: Double
    var width: Double = 180
    var height: Double = 90
    var color: String?

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    static let palette: [(String, String)] = [("Yellow", "#FFF3B0"), ("Blue", "#D6E9FF"), ("Green", "#D9F5D6"),
                                              ("Pink", "#FFDDE7"), ("Orange", "#FFE2C2"), ("Gray", "#ECECEC")]
}

struct DBMLData: Codable, Equatable {
    var source: String
    var title: String?
    /// Where each box was dragged to (its top-left corner), by its key: a table's name, "enum:…" or "note:…".
    var positions: [String: DBMLPoint] = [:]
    /// Each relationship's line, by the relationship's key (see DBMLSchema.Ref.key).
    var lines: [String: DBMLLine]?
    /// Notes laid over the diagram.
    var notes: [DBMLNote]?
    /// How new lines are drawn (cubic curves when not chosen).
    var curve: DBMLCurve?
    /// The diagram's scale (nil: fit the container's width, at most 100%).
    var zoom: Double?
    /// The DBML is shown beside the diagram, this wide.
    var showsSource: Bool?
    var sourceWidth: Double?
    /// Column types are left out of the boxes.
    var hidesTypes: Bool?

    var defaultCurve: DBMLCurve { curve ?? .cubic }

    static let starter = DBMLData(source: """
    // A database diagram in DBML — edit it in the DBML pane (Show DBML), drag the
    // tables around, click a relationship's line to bend it, and add notes.
    // DBML: https://dbml.dbdiagram.io/docs

    Table authors {
      id integer [pk, increment]
      name varchar [not null]
      email varchar [unique]
      joined_at timestamp
    }

    Table books {
      id integer [pk, increment]
      title varchar [not null]
      author_id integer [ref: > authors.id]
      published date
      status book_status
      Note: 'Every book has one author'
    }

    Table reviews {
      id integer [pk]
      book_id integer
      reader_id integer
      stars integer [note: '1 to 5']
      body text
    }

    Enum book_status {
      draft
      published
      out_of_print
    }

    Ref: reviews.book_id > books.id
    Ref: reviews.reader_id > authors.id
    """)
}

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
        /// The table's key: "name", or "schema.name" outside the public schema.
        var name: String
        var alias: String?
        var columns: [Column] = []
        var note: String?
        var headerColor: String?
        var line: Int
    }

    struct Enum {
        var name: String
        var values: [(name: String, note: String?)] = []
        var line: Int
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
        var key = ""

        var fromMark: String { op == "<" || op == "-" ? "1" : "*" }
        var toMark: String { op == ">" || op == "-" ? "1" : "*" }
        var kindTitle: String {
            switch op {
            case ">": "many-to-one"
            case "<": "one-to-many"
            case "-": "one-to-one"
            default: "many-to-many"
            }
        }
    }

    struct Group {
        var name: String
        var tables: [String]
        var color: String?
        var line: Int
    }

    struct StickyNote {
        var name: String
        var text: String
        var line: Int
    }

    struct Problem: Equatable {
        var line: Int
        var message: String
    }

    var project: String?
    var tables: [Table] = []
    var enums: [Enum] = []
    var refs: [Ref] = []
    var groups: [Group] = []
    var notes: [StickyNote] = []
    var problems: [Problem] = []

    func table(_ name: String) -> Table? { tables.first { $0.name == name } }
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

    /// Reads DBML. What it can't read is listed in `problems` (by line); the rest still shows.
    static func parse(_ source: String) -> DBMLSchema {
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
            _ = settings()
            schema.refs.append(.init(name: name, from: from, to: to, op: op.text, line: line))
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
                    skipBlock()
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
                            schema.refs.append(.init(name: nil, from: .init(table: table.name, columns: [col.name]), to: to, op: op.text, line: columnLine))
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
            schema.notes.append(.init(name: noteName, text: text, line: line))
        }
    }
}

// MARK: - Writing DBML

extension DBMLData {
    /// The diagram as a .dbml file: its DBML, then the notes laid over it as DBML sticky notes.
    var exportText: String {
        var text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let schema = DBMLParser.parse(source)
        var taken = Set(schema.notes.map(\.name))
        for (n, note) in (notes ?? []).enumerated() where !note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var name = "note_\(n + 1)"
            while taken.contains(name) { name += "_" }
            taken.insert(name)
            let body = note.text.replacingOccurrences(of: "'''", with: "\\'\\'\\'")
            text += "\n\nNote \(name) {\n'''\n\(body)\n'''\n}"
        }
        return text + "\n"
    }

    var searchText: String {
        let s = DBMLParser.parse(source)
        var words: [String] = [title ?? ""]
        for t in s.tables { words.append(t.name); words += t.columns.map(\.name); if let n = t.note { words.append(n) } }
        for e in s.enums { words.append(e.name); words += e.values.map(\.name) }
        words += s.groups.map(\.name)
        words += s.notes.map(\.text)
        words += (notes ?? []).map(\.text)
        return words.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

// MARK: - Where everything goes

/// The diagram laid out: every box's rectangle and every line's ends and control points, in diagram points.
struct DBMLLayout {
    enum BoxKind { case table, enumeration, sticky }

    struct Box {
        var key: String
        var kind: BoxKind
        var title: String
        var rows: [(name: String, type: String, pk: Bool, notNull: Bool, unique: Bool, note: String?)]
        var note: String?
        var color: NSColor
        var rect: CGRect
        var line: Int
    }

    struct Line {
        var ref: DBMLSchema.Ref
        var start: CGPoint
        var end: CGPoint
        var startSide: DBMLSide
        var endSide: DBMLSide
        var curve: DBMLCurve
        /// Quadratic: one control point; cubic: two (absolute).
        var controls: [CGPoint]
        var color: NSColor?

        var path: NSBezierPath {
            let p = NSBezierPath()
            p.move(to: start)
            switch curve {
            case .straight: p.line(to: end)
            case .quadratic: p.curve(to: end, controlPoint1: start + (controls[0] - start) * (2.0 / 3.0), controlPoint2: end + (controls[0] - end) * (2.0 / 3.0))
            case .cubic: p.curve(to: end, controlPoint1: controls[0], controlPoint2: controls[1])
            }
            return p
        }
    }

    struct Group {
        var name: String
        var rect: CGRect
        var color: NSColor
    }

    var schema: DBMLSchema
    var boxes: [Box] = []
    var lines: [Line] = []
    var groups: [Group] = []
    /// All of it (with a margin), from the origin.
    var size = CGSize(width: 300, height: 200)
    /// How far it reaches above or left of the origin (a group's label, a control point pulled out): negative.
    var overflow = CGPoint.zero

    static let headerHeight: CGFloat = 30
    static let rowHeight: CGFloat = 24
    static let minWidth: CGFloat = 170
    static let pad: CGFloat = 12
    static let margin: CGFloat = 24
    static let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let nameFont = NSFont.systemFont(ofSize: 12)
    static let typeFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let noteFont = NSFont.systemFont(ofSize: 12)
    static let defaultHeader = NSColor(hex: "#316896") ?? .systemBlue
    static let enumHeader = NSColor(hex: "#7B5EA7") ?? .systemPurple
    static let lineColor = NSColor(hex: "#7D8B99") ?? .gray

    init(_ data: DBMLData, schema: DBMLSchema? = nil) {
        let schema = schema ?? DBMLParser.parse(data.source)
        self.schema = schema
        let showTypes = data.hidesTypes != true
        var unplaced: [Int] = []
        for t in schema.tables {
            let rows = t.columns.map { ($0.name, $0.type, $0.pk, $0.notNull, $0.unique, $0.note) }
            let size = Self.size(title: t.name, rows: rows.map { ($0.0, showTypes ? $0.1 : "") })
            let color = t.headerColor.flatMap { NSColor(hex: $0) } ?? Self.defaultHeader
            boxes.append(Box(key: t.name, kind: .table, title: t.name, rows: rows, note: t.note, color: color,
                             rect: CGRect(origin: .zero, size: size), line: t.line))
        }
        for e in schema.enums {
            let rows = e.values.map { ($0.name, "", false, false, false, $0.note) }
            let size = Self.size(title: "enum " + e.name, rows: rows.map { ($0.0, "") })
            boxes.append(Box(key: "enum:" + e.name, kind: .enumeration, title: e.name, rows: rows, note: nil, color: Self.enumHeader,
                             rect: CGRect(origin: .zero, size: size), line: e.line))
        }
        for n in schema.notes {
            let size = DBMLLayout.noteSize(n.text)
            boxes.append(Box(key: "note:" + n.name, kind: .sticky, title: n.name, rows: [], note: n.text,
                             color: NSColor(hex: DBMLNote.palette[0].1) ?? .yellow, rect: CGRect(origin: .zero, size: size), line: n.line))
        }
        for (k, box) in boxes.enumerated() {
            if let p = data.positions[box.key] { boxes[k].rect.origin = p.cg } else { unplaced.append(k) }
        }
        if !unplaced.isEmpty { place(unplaced) }
        // Groups around their tables.
        for g in schema.groups {
            let rects = boxes.filter { $0.kind == .table && g.tables.contains($0.key) }.map(\.rect)
            guard let first = rects.first else { continue }
            let r = rects.dropFirst().reduce(first) { $0.union($1) }.insetBy(dx: -14, dy: -14)
            let color = g.color.flatMap { NSColor(hex: $0) } ?? NSColor(hex: "#5B7A99") ?? .gray
            groups.append(Group(name: g.name, rect: CGRect(x: r.minX, y: r.minY - 18, width: r.width, height: r.height + 18), color: color))
        }
        // Lines from column to column.
        for ref in schema.refs {
            guard let a = boxes.first(where: { $0.kind == .table && $0.key == ref.from.table }),
                  let b = boxes.first(where: { $0.kind == .table && $0.key == ref.to.table }) else { continue }
            let saved = data.lines?[ref.key] ?? DBMLLine()
            let ya = Self.rowY(a, ref.from.columns.first), yb = Self.rowY(b, ref.to.columns.first)
            var sides: (DBMLSide, DBMLSide)
            if b.rect.minX > a.rect.maxX + 16 { sides = (.right, .left) } else if b.rect.maxX < a.rect.minX - 16 { sides = (.left, .right) } else { sides = (.right, .right) }
            if let s = saved.fromSide { sides.0 = s }
            if let s = saved.toSide { sides.1 = s }
            let start = CGPoint(x: sides.0 == .right ? a.rect.maxX : a.rect.minX, y: ya)
            let end = CGPoint(x: sides.1 == .right ? b.rect.maxX : b.rect.minX, y: yb)
            let curve = saved.curve ?? data.defaultCurve
            let controls = Self.controls(curve, start: start, end: end, sides: sides, saved: saved)
            lines.append(Line(ref: ref, start: start, end: end, startSide: sides.0, endSide: sides.1, curve: curve, controls: controls,
                              color: saved.color.flatMap { NSColor(hex: $0) }))
        }
        var extent = CGRect(x: 0, y: 0, width: 200, height: 120)
        var low = CGPoint(x: CGFloat.greatestFiniteMagnitude, y: CGFloat.greatestFiniteMagnitude)
        func add(_ r: CGRect) {
            extent = extent.union(r)
            low = CGPoint(x: min(low.x, r.minX), y: min(low.y, r.minY))
        }
        for b in boxes { add(b.rect) }
        for g in groups { add(g.rect) }
        for n in data.notes ?? [] { add(n.rect) }
        for l in lines { for c in l.controls { add(CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12)) } }
        if low.x < .greatestFiniteMagnitude { overflow = CGPoint(x: min(0, (low.x - 4).rounded(.down)), y: min(0, (low.y - 4).rounded(.down))) }
        size = CGSize(width: ceil(extent.maxX + Self.margin - overflow.x), height: ceil(extent.maxY + Self.margin - overflow.y))
    }

    static func size(title: String, rows: [(String, String)]) -> CGSize {
        var width = (title as NSString).size(withAttributes: [.font: titleFont]).width + 2 * pad + 20
        for (name, type) in rows {
            let w = (name as NSString).size(withAttributes: [.font: nameFont]).width + (type as NSString).size(withAttributes: [.font: typeFont]).width
            width = max(width, w + 2 * pad + 40)
        }
        return CGSize(width: max(minWidth, ceil(width)), height: headerHeight + CGFloat(max(rows.count, 1)) * rowHeight + 4)
    }

    static func noteSize(_ text: String) -> CGSize {
        let r = (text as NSString).boundingRect(with: CGSize(width: 200, height: 2000), options: [.usesLineFragmentOrigin], attributes: [.font: noteFont])
        return CGSize(width: 220, height: max(60, ceil(r.height) + 34))
    }

    static func rowY(_ box: Box, _ column: String?) -> CGFloat {
        let index = column.flatMap { c in box.rows.firstIndex { $0.name == c } } ?? 0
        return box.rect.minY + headerHeight + (CGFloat(index) + 0.5) * rowHeight
    }

    /// The row a point is on (nil on the header).
    static func row(in box: Box, at p: CGPoint) -> Int? {
        let y = p.y - box.rect.minY - headerHeight
        guard y >= 0 else { return nil }
        let r = Int(y / rowHeight)
        return r < box.rows.count ? r : nil
    }

    /// A curve's control points: the saved offsets, or the default shape for its sides.
    static func controls(_ curve: DBMLCurve, start: CGPoint, end: CGPoint, sides: (DBMLSide, DBMLSide), saved: DBMLLine) -> [CGPoint] {
        let ds: CGFloat = sides.0 == .right ? 1 : -1, de: CGFloat = sides.1 == .right ? 1 : -1
        let reach = max(50, abs(end.x - start.x) / 2) + (sides.0 == sides.1 ? 30 : 0)
        switch curve {
        case .straight:
            return []
        case .quadratic:
            let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            if let c = saved.c1 { return [mid + c.cg] }
            // Ends on the same side: out beyond them; else level with the start, halfway across.
            if sides.0 == sides.1 {
                return [CGPoint(x: (ds > 0 ? max(start.x, end.x) : min(start.x, end.x)) + ds * reach, y: mid.y)]
            }
            return [CGPoint(x: mid.x, y: start.y)]
        case .cubic:
            let c1 = saved.c1.map { start + $0.cg } ?? CGPoint(x: start.x + ds * reach, y: start.y)
            let c2 = saved.c2.map { end + $0.cg } ?? CGPoint(x: end.x + de * reach, y: end.y)
            return [c1, c2]
        }
    }

    /// New boxes go in columns: each table right of the tables it points to (a many-to-one Ref's "one" side first).
    private mutating func place(_ indices: [Int]) {
        var placed = boxes.indices.filter { !indices.contains($0) }.map { boxes[$0].rect }
        let tables = indices.filter { boxes[$0].kind == .table }
        var rank: [String: Int] = [:]
        for k in tables { rank[boxes[k].key] = 0 }
        // Longest path from the referenced tables (a few passes are enough for a page's diagram).
        for _ in 0..<tables.count {
            var changed = false
            for r in schema.refs {
                let (child, parent): (String, String) = r.op == "<" ? (r.to.table, r.from.table) : (r.from.table, r.to.table)
                guard child != parent, let pr = rank[parent], let cr = rank[child], cr < pr + 1, pr + 1 < 8 else { continue }
                rank[child] = pr + 1
                changed = true
            }
            if !changed { break }
        }
        let startX = (placed.map(\.maxX).max() ?? 0) + (placed.isEmpty ? Self.margin : 60)
        var columnTop: [Int: CGFloat] = [:]
        var columnX: [Int: CGFloat] = [:]
        let ranks = Set(tables.map { rank[boxes[$0].key] ?? 0 }).sorted()
        var x = startX
        for r in ranks {
            columnX[r] = x
            let width = tables.filter { rank[boxes[$0].key] == r }.map { boxes[$0].rect.width }.max() ?? Self.minWidth
            x += width + 90
        }
        for k in tables {
            let r = rank[boxes[k].key] ?? 0
            let y = columnTop[r] ?? Self.margin
            boxes[k].rect.origin = CGPoint(x: columnX[r] ?? startX, y: y)
            columnTop[r] = y + boxes[k].rect.height + 40
            placed.append(boxes[k].rect)
        }
        // Enums and sticky notes below.
        var bottom = (placed.map(\.maxY).max() ?? 0) + (placed.isEmpty ? Self.margin : 50)
        var rowX = Self.margin, rowHeight: CGFloat = 0
        for k in indices where boxes[k].kind != .table {
            if rowX + boxes[k].rect.width > max(900, x) { rowX = Self.margin; bottom += rowHeight + 40; rowHeight = 0 }
            boxes[k].rect.origin = CGPoint(x: rowX, y: bottom)
            rowX += boxes[k].rect.width + 40
            rowHeight = max(rowHeight, boxes[k].rect.height)
        }
    }

    /// Every box where the layout puts it (for Arrange: start afresh).
    static func arranged(_ data: DBMLData) -> [String: DBMLPoint] {
        var fresh = data
        fresh.positions = [:]
        let layout = DBMLLayout(fresh)
        return Dictionary(layout.boxes.map { ($0.key, DBMLPoint($0.rect.origin)) }, uniquingKeysWith: { a, _ in a })
    }
}

// MARK: - Drawing

enum DBMLDrawing {
    /// What's selected, for drawing it (none in pictures and prints).
    struct Highlight {
        var box: String?
        var line: String?
        var note: UUID?
        var hoverLine: String?
    }

    static func draw(_ layout: DBMLLayout, _ data: DBMLData, highlight: Highlight = Highlight(), editingNote: UUID? = nil) {
        for g in layout.groups { drawGroup(g) }
        for line in layout.lines where line.ref.key != highlight.line { drawLine(line, selected: false, hover: line.ref.key == highlight.hoverLine) }
        for box in layout.boxes { drawBox(box, selected: box.key == highlight.box, hidesTypes: data.hidesTypes == true) }
        if let key = highlight.line, let line = layout.lines.first(where: { $0.ref.key == key }) { drawLine(line, selected: true, hover: false) }
        for note in data.notes ?? [] { drawNote(note, selected: note.id == highlight.note, editing: note.id == editingNote) }
    }

    static func drawGroup(_ g: DBMLLayout.Group) {
        let path = NSBezierPath(roundedRect: g.rect, xRadius: 10, yRadius: 10)
        g.color.withAlphaComponent(0.07).setFill()
        path.fill()
        path.lineWidth = 1
        path.setLineDash([5, 3], count: 2, phase: 0)
        g.color.withAlphaComponent(0.55).setStroke()
        path.stroke()
        (g.name as NSString).draw(at: CGPoint(x: g.rect.minX + 10, y: g.rect.minY + 3),
                                  withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: g.color])
    }

    static func drawBox(_ box: DBMLLayout.Box, selected: Bool, hidesTypes: Bool) {
        let r = box.rect
        if box.kind == .sticky {
            drawStickyBox(box, selected: selected)
            return
        }
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.16)
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowBlurRadius = 5
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
        NSGraphicsContext.restoreGraphicsState()
        // Header.
        let header = NSBezierPath()
        let h = CGRect(x: r.minX, y: r.minY, width: r.width, height: DBMLLayout.headerHeight)
        header.appendRoundedRect(h, xRadius: 6, yRadius: 6)
        header.append(NSBezierPath(rect: CGRect(x: h.minX, y: h.midY, width: h.width, height: h.height / 2)))
        box.color.setFill()
        header.fill()
        let light = (box.color.usingColorSpace(.sRGB)?.brightnessComponent ?? 0) > 0.75
        let titleColor: NSColor = light ? .black : .white
        let title = box.kind == .enumeration ? "enum " + box.title : box.title
        (title as NSString).draw(in: CGRect(x: r.minX + DBMLLayout.pad, y: r.minY + 7, width: r.width - 2 * DBMLLayout.pad - (box.note == nil ? 0 : 16), height: 18),
                                 withAttributes: [.font: DBMLLayout.titleFont, .foregroundColor: titleColor])
        if box.note != nil, let icon = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Note")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular).applying(.init(paletteColors: [titleColor]))) {
            icon.draw(in: CGRect(x: r.maxX - DBMLLayout.pad - 13, y: r.minY + 8, width: 14, height: 13))
        }
        // Rows.
        for (k, row) in box.rows.enumerated() {
            let y = r.minY + DBMLLayout.headerHeight + CGFloat(k) * DBMLLayout.rowHeight
            if k % 2 == 1 {
                NSColor(white: 0.97, alpha: 1).setFill()
                CGRect(x: r.minX + 1, y: y, width: r.width - 2, height: DBMLLayout.rowHeight).fill()
            }
            var x = r.minX + DBMLLayout.pad
            if row.pk, let key = NSImage(systemSymbolName: "key.fill", accessibilityDescription: "Primary key")?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .regular).applying(.init(paletteColors: [NSColor(hex: "#C9A227") ?? .systemYellow]))) {
                key.draw(in: CGRect(x: x, y: y + 6, width: 12, height: 11))
                x += 16
            }
            let nameAttrs: [NSAttributedString.Key: Any] = [.font: row.pk ? NSFont.systemFont(ofSize: 12, weight: .semibold) : DBMLLayout.nameFont,
                                                            .foregroundColor: NSColor(white: 0.12, alpha: 1)]
            (row.name as NSString).draw(at: CGPoint(x: x, y: y + 4), withAttributes: nameAttrs)
            var right = r.maxX - DBMLLayout.pad
            if row.note != nil {
                NSColor(hex: "#316896")?.withAlphaComponent(0.6).setFill()
                NSBezierPath(ovalIn: CGRect(x: right - 5, y: y + 10, width: 5, height: 5)).fill()
                right -= 10
            }
            if !hidesTypes, !row.type.isEmpty {
                let type = row.type + (row.notNull ? " !" : "") as NSString
                let attrs: [NSAttributedString.Key: Any] = [.font: DBMLLayout.typeFont, .foregroundColor: NSColor(white: 0.45, alpha: 1)]
                let w = type.size(withAttributes: attrs).width
                type.draw(at: CGPoint(x: right - w, y: y + 5), withAttributes: attrs)
            }
        }
        let outline = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        outline.lineWidth = selected ? 2 : 1
        (selected ? NSColor.controlAccentColor : NSColor(white: 0.78, alpha: 1)).setStroke()
        outline.stroke()
    }

    static func drawStickyBox(_ box: DBMLLayout.Box, selected: Bool) {
        drawNoteShape(box.rect, color: box.color, selected: selected)
        (box.title as NSString).draw(at: CGPoint(x: box.rect.minX + 10, y: box.rect.minY + 6),
                                     withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor(white: 0.3, alpha: 1)])
        ((box.note ?? "") as NSString).draw(with: CGRect(x: box.rect.minX + 10, y: box.rect.minY + 24, width: box.rect.width - 20, height: box.rect.height - 30),
                                            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                            attributes: [.font: DBMLLayout.noteFont, .foregroundColor: NSColor(white: 0.1, alpha: 1)])
    }

    static func drawNoteShape(_ r: CGRect, color: NSColor, selected: Bool) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.18)
        shadow.shadowOffset = NSSize(width: 1, height: -2)
        shadow.shadowBlurRadius = 4
        shadow.set()
        color.setFill()
        NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
        NSGraphicsContext.restoreGraphicsState()
        let outline = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        outline.lineWidth = selected ? 2 : 0.75
        (selected ? NSColor.controlAccentColor : color.shadow(withLevel: 0.25) ?? .gray).setStroke()
        outline.stroke()
    }

    static func drawNote(_ note: DBMLNote, selected: Bool, editing: Bool) {
        let color = note.color.flatMap { NSColor(hex: $0) } ?? NSColor(hex: DBMLNote.palette[0].1) ?? .yellow
        drawNoteShape(note.rect, color: color, selected: selected)
        if !editing {
            (note.text as NSString).draw(with: note.rect.insetBy(dx: 9, dy: 8), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                         attributes: [.font: DBMLLayout.noteFont, .foregroundColor: NSColor(white: 0.1, alpha: 1)])
        }
        if selected {
            // The corner that resizes it.
            let c = CGPoint(x: note.rect.maxX - 3, y: note.rect.maxY - 3)
            let grip = NSBezierPath()
            for d in [5.0, 9.0] { grip.move(to: CGPoint(x: c.x - d, y: c.y)); grip.line(to: CGPoint(x: c.x, y: c.y - d)) }
            grip.lineWidth = 1
            NSColor(white: 0.35, alpha: 0.8).setStroke()
            grip.stroke()
        }
    }

    static func drawLine(_ line: DBMLLayout.Line, selected: Bool, hover: Bool) {
        let color = selected ? NSColor.controlAccentColor : hover ? (line.color ?? DBMLLayout.lineColor).blended(withFraction: 0.35, of: .controlAccentColor) ?? .gray
            : line.color ?? DBMLLayout.lineColor
        let path = line.path
        path.lineWidth = selected || hover ? 2.2 : 1.5
        if line.ref.op == "<>" { path.setLineDash([6, 3], count: 2, phase: 0) }
        color.setStroke()
        path.stroke()
        // The ends: a dot on each table, and 1 / * beside it.
        for (p, side, mark) in [(line.start, line.startSide, line.ref.fromMark), (line.end, line.endSide, line.ref.toMark)] {
            color.setFill()
            NSBezierPath(ovalIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)).fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: color]
            let w = (mark as NSString).size(withAttributes: attrs).width
            (mark as NSString).draw(at: CGPoint(x: side == .right ? p.x + 6 : p.x - 6 - w, y: p.y - 17), withAttributes: attrs)
        }
        guard selected else { return }
        // Control points, on lines to the ends they pull from.
        let guides = NSBezierPath()
        switch line.curve {
        case .straight: break
        case .quadratic:
            guides.move(to: line.start); guides.line(to: line.controls[0]); guides.line(to: line.end)
        case .cubic:
            guides.move(to: line.start); guides.line(to: line.controls[0])
            guides.move(to: line.end); guides.line(to: line.controls[1])
        }
        guides.lineWidth = 1
        guides.setLineDash([3, 3], count: 2, phase: 0)
        NSColor.controlAccentColor.withAlphaComponent(0.7).setStroke()
        guides.stroke()
        for c in line.controls {
            let handle = NSBezierPath(ovalIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10))
            NSColor.white.setFill()
            handle.fill()
            handle.lineWidth = 1.5
            NSColor.controlAccentColor.setStroke()
            handle.stroke()
        }
    }

    /// The whole diagram as a picture (pages, exports, copies), at a scale.
    static func picture(_ data: DBMLData, scale: CGFloat = 1) -> NSImage {
        let layout = DBMLLayout(data)
        let size = CGSize(width: layout.size.width * scale, height: layout.size.height * scale)
        return NSImage(size: size, flipped: true) { _ in
            NSColor.white.setFill()
            CGRect(origin: .zero, size: size).fill()
            let t = NSAffineTransform()
            t.scale(by: scale)
            t.translateX(by: -layout.overflow.x, yBy: -layout.overflow.y)
            t.concat()
            draw(layout, data)
            return true
        }
    }
}

// MARK: - Points

func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
func * (a: CGPoint, k: CGFloat) -> CGPoint { CGPoint(x: a.x * k, y: a.y * k) }
