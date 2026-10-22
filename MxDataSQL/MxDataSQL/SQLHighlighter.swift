//
//  SQLHighlighter.swift
//  MxDataSQL
//
//  Syntax colouring for the SQL box, in the colours of VS Code's Light+ and
//  Dark+ themes (they follow the system appearance). A small scanner that
//  knows PostgreSQL's lexical rules: '...' and E'...' strings, $tag$ ... $tag$
//  dollar quoting, "quoted identifiers", -- and nested /* */ comments,
//  numbers, $1 parameters, keywords, data types (also after ::) and function
//  calls (a name followed by an opening parenthesis).
//

import AppKit
import SwiftUI

nonisolated enum SQLToken: Sendable {
    case keyword, type, function, string, number, comment, quotedIdentifier, parameter
}

nonisolated enum SQLHighlighter {

    // MARK: Colours (VS Code Light+ / Dark+)

    private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                           blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
        }
    }

    static let colors: [SQLToken: NSColor] = [
        .keyword: dynamic(light: 0x0000FF, dark: 0x569CD6),
        .type: dynamic(light: 0x267F99, dark: 0x4EC9B0),
        .function: dynamic(light: 0x795E26, dark: 0xDCDCAA),
        .string: dynamic(light: 0xA31515, dark: 0xCE9178),
        .number: dynamic(light: 0x098658, dark: 0xB5CEA8),
        .comment: dynamic(light: 0x008000, dark: 0x6A9955),
        .quotedIdentifier: dynamic(light: 0x001080, dark: 0x9CDCFE),
        .parameter: dynamic(light: 0xAF00DB, dark: 0xC586C0),
    ]

    /// Recolours all of `storage` (call after its characters change).
    static func apply(to storage: NSTextStorage) {
        let all = NSRange(location: 0, length: storage.length)
        storage.removeAttribute(.foregroundColor, range: all)
        storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: all)
        for (range, token) in tokens(in: storage.string) {
            storage.addAttribute(.foregroundColor, value: colors[token]!, range: range)
        }
    }

    /// `text` in the same colours, for read-only SwiftUI text (a function's code in DB Table Selection).
    /// With `sqlBodies`, the body of pg_get_functiondef's `AS $function$ ... $function$` (or `$procedure$`)
    /// is coloured as SQL rather than as one dollar-quoted string — for LANGUAGE sql and plpgsql.
    static func attributed(_ text: String, sqlBodies: Bool = false) -> AttributedString {
        var out = AttributedString(text)
        let ns = text as NSString
        func paint(_ range: NSRange, _ token: SQLToken) {
            guard let r = Range(range, in: out) else { return }
            out[r].foregroundColor = Color(nsColor: colors[token]!)
        }
        for (range, token) in tokens(in: text) {
            let quoted = ns.substring(with: range)
            if sqlBodies, token == .string,
               let tag = ["$function$", "$procedure$"].first(where: { quoted.hasPrefix($0) && quoted.hasSuffix($0) }),
               range.length >= 2 * tag.utf16.count {
                let length = tag.utf16.count
                let body = NSRange(location: range.location + length, length: range.length - 2 * length)
                paint(NSRange(location: range.location, length: length), .string)
                paint(NSRange(location: body.upperBound, length: length), .string)
                for (inner, innerToken) in tokens(in: ns.substring(with: body)) {
                    paint(NSRange(location: body.location + inner.location, length: inner.length), innerToken)
                }
            } else {
                paint(range, token)
            }
        }
        return out
    }

    // MARK: Words

    static let keywords: Set<String> = Set("""
        abort absolute access action add admin after aggregate all also alter always analyse analyze and any array as \
        asc assertion assignment asymmetric at attach authorization backward before begin between both by cache call \
        called cascade cascaded case cast catalog chain characteristics check checkpoint class close cluster coalesce \
        collate collation column columns comment comments commit committed concurrently configuration conflict \
        connection constraint constraints content continue conversion copy cost create cross csv cube current cursor \
        cycle data database day deallocate declare default defaults deferrable deferred definer delete delimiter \
        delimiters depends desc detach dictionary disable discard distinct do document domain drop each else enable \
        encoding encrypted end enum escape event except exclude excluding exclusive execute exists explain expression \
        extension external extract false family fetch filter first following for force foreign forward freeze from \
        full function functions generated global grant granted greatest group grouping groups handler having header \
        hold hour identity if ilike immediate immutable implicit import in include including increment index indexes \
        inherit inherits initially inline inner inout input insensitive insert instead intersect into invoker is \
        isnull isolation join key label language large last lateral leading leakproof least left level like limit \
        listen load local localtime localtimestamp location lock locked logged mapping match matched materialized \
        maxvalue merge method minute minvalue mode month move name names natural new next nfc nfd nfkc nfkd no none \
        normalize not nothing notify notnull nowait null nullif nulls object of off offset oids old on only operator \
        option options or order ordinality others out outer over overlaps overlay overriding owned owner parallel \
        parser partial partition passing password placing plans policy position preceding prepare prepared preserve \
        primary prior privileges procedural procedure procedures program publication quote range read reassign \
        recheck recursive ref references referencing refresh reindex relative release rename repeatable replace \
        replica reset restart restrict return returning returns revoke right role rollback rollup routine routines \
        row rows rule savepoint schema schemas scroll search second security select sequence sequences serializable \
        server session session_user set setof sets share show similar simple skip snapshot some sql stable standalone \
        start statement statistics stdin stdout storage stored strict strip subscription substring support symmetric \
        sysid system table tables tablesample tablespace temp template temporary then ties to trailing transaction \
        transform treat trigger trim true truncate trusted type types uescape unbounded uncommitted unencrypted union \
        unique unknown unlisten unlogged until update user using vacuum valid validate validator value values \
        variadic verbose version view views volatile when where whitespace window with within without work wrapper \
        write year yes zone current_date current_time current_timestamp current_user current_role current_schema \
        returns language plpgsql loop exit raise notice exception perform elsif while foreach reverse found strict
        """.split(whereSeparator: \.isWhitespace).map(String.init))

    static let types: Set<String> = Set("""
        bigint bigserial bit bool boolean bpchar bytea char character cidr circle date decimal double float float4 \
        float8 inet int int2 int4 int8 integer interval json jsonb lseg macaddr macaddr8 money numeric oid \
        polygon precision real record regclass regproc regtype serial serial2 serial4 serial8 smallint \
        smallserial text time timestamp timestamptz timetz tsquery tsvector txid_snapshot uuid varbit varchar varying \
        void xml anyelement anyarray cstring tid xid
        """.split(whereSeparator: \.isWhitespace).map(String.init))

    // MARK: Scanner

    /// Coloured ranges (UTF-16, as NSString / NSTextStorage count) of `text`.
    static func tokens(in text: String) -> [(NSRange, SQLToken)] {
        let s = Array(text.utf16)
        let n = s.count
        var result: [(NSRange, SQLToken)] = []
        var i = 0
        var afterCast = false   // the next word follows ::, so it is a type

        func at(_ k: Int) -> UInt16 { k < n ? s[k] : 0 }
        func isIdentStart(_ c: UInt16) -> Bool {
            (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c >= 128
        }
        func isIdentChar(_ c: UInt16) -> Bool { isIdentStart(c) || (c >= 48 && c <= 57) || c == 36 }
        func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
        func add(_ start: Int, _ end: Int, _ token: SQLToken) {
            if end > start { result.append((NSRange(location: start, length: end - start), token)) }
        }
        /// Index just past a quoted run starting at `start` (the opening quote), with doubled quotes
        /// as escapes and, for E'...' strings, backslash escapes.
        func endOfQuoted(_ start: Int, quote: UInt16, backslash: Bool) -> Int {
            var k = start + 1
            while k < n {
                if backslash && s[k] == 92 { k += 2; continue }
                if s[k] == quote {
                    if at(k + 1) == quote { k += 2; continue }
                    return k + 1
                }
                k += 1
            }
            return n
        }

        while i < n {
            let c = s[i]
            // -- comment
            if c == 45 && at(i + 1) == 45 {
                var k = i + 2
                while k < n && s[k] != 10 { k += 1 }
                add(i, k, .comment); i = k; continue
            }
            // /* comment */ (nests in PostgreSQL)
            if c == 47 && at(i + 1) == 42 {
                var depth = 1, k = i + 2
                while k < n && depth > 0 {
                    if s[k] == 47 && at(k + 1) == 42 { depth += 1; k += 2 }
                    else if s[k] == 42 && at(k + 1) == 47 { depth -= 1; k += 2 }
                    else { k += 1 }
                }
                add(i, k, .comment); i = k; continue
            }
            // 'string', E'string'
            if c == 39 {
                let k = endOfQuoted(i, quote: 39, backslash: false)
                add(i, k, .string); i = k; afterCast = false; continue
            }
            if (c == 69 || c == 101) && at(i + 1) == 39 && (i == 0 || !isIdentChar(s[i - 1])) {
                let k = endOfQuoted(i + 1, quote: 39, backslash: true)
                add(i, k, .string); i = k; afterCast = false; continue
            }
            // "quoted identifier"
            if c == 34 {
                let k = endOfQuoted(i, quote: 34, backslash: false)
                add(i, k, afterCast ? .type : .quotedIdentifier); i = k; afterCast = false; continue
            }
            // $1 parameter, or $tag$ ... $tag$ dollar-quoted string
            if c == 36 {
                if isDigit(at(i + 1)) {
                    var k = i + 1
                    while k < n && isDigit(s[k]) { k += 1 }
                    add(i, k, .parameter); i = k; continue
                }
                var k = i + 1
                while k < n && isIdentChar(s[k]) && s[k] != 36 { k += 1 }
                if at(k) == 36 && (k == i + 1 || isIdentStart(s[i + 1])) {
                    let tag = Array(s[i...k])
                    var j = k + 1
                    var close = n
                    while j + tag.count <= n {
                        if s[j] == 36 && Array(s[j..<(j + tag.count)]) == tag { close = j + tag.count; break }
                        j += 1
                    }
                    add(i, close, .string); i = close; continue
                }
            }
            // number (not part of an identifier such as col1)
            if isDigit(c) || (c == 46 && isDigit(at(i + 1))) {
                var k = i
                while k < n && (isDigit(s[k]) || s[k] == 46) { k += 1 }
                if (at(k) == 101 || at(k) == 69) && (isDigit(at(k + 1)) || ((at(k + 1) == 43 || at(k + 1) == 45) && isDigit(at(k + 2)))) {
                    k += 2
                    while k < n && isDigit(s[k]) { k += 1 }
                }
                add(i, k, .number); i = k; afterCast = false; continue
            }
            // word: keyword, type, function name or plain identifier
            if isIdentStart(c) {
                var k = i
                while k < n && isIdentChar(s[k]) { k += 1 }
                let word = String(utf16CodeUnits: Array(s[i..<k]), count: k - i).lowercased()
                var j = k
                while j < n && (s[j] == 32 || s[j] == 9) { j += 1 }
                let call = at(j) == 40
                let previousIsDot = i > 0 && s[i - 1] == 46
                if afterCast || (types.contains(word) && !previousIsDot) {
                    add(i, k, .type)
                } else if keywords.contains(word) && !previousIsDot && !(call && !Self.keywordsBeforeParen.contains(word)) {
                    add(i, k, .keyword)
                } else if call {
                    add(i, k, .function)
                }
                i = k; afterCast = false; continue
            }
            // :: cast
            if c == 58 && at(i + 1) == 58 {
                afterCast = true; i += 2; continue
            }
            if c != 32 && c != 9 && c != 10 && c != 13 { afterCast = false }
            i += 1
        }
        return result
    }

    /// Keywords that stay keywords when followed by "(" (otherwise "name(" is a function call).
    private static let keywordsBeforeParen: Set<String> = [
        "in", "exists", "values", "any", "all", "some", "array", "as", "on", "using", "over", "filter", "within",
        "and", "or", "not", "from", "join", "select", "where", "returns", "table", "row", "cast", "case", "when",
        "then", "else", "into", "partition", "by", "with", "lateral", "unique", "primary", "key", "check",
        "references", "default", "is", "like", "ilike", "between", "set", "update", "insert", "delete", "call",
        "coalesce", "nullif", "greatest", "least", "extract", "substring", "trim", "position", "overlay", "exists",
    ]
}
