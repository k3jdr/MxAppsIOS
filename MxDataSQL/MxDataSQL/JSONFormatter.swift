//
//  JSONFormatter.swift
//  MxDataSQL
//
//  JSON for the grid's "View JSON…" window: formatting like VS Code's
//  Format Document (each member on its own line, `"key": value`, empty {} and
//  [] kept together), done on the original text so key order and number
//  spellings are kept exactly; and colouring in VS Code's Light+ / Dark+ JSON
//  colours (property keys, string values, numbers, true / false / null).
//

import AppKit

nonisolated enum JSONToken: Sendable {
    case key, string, number, literal
}

nonisolated struct JSONFormatError: LocalizedError {
    var message: String
    var line: Int
    var column: Int
    var errorDescription: String? { "\(message) (line \(line), column \(column))" }
}

nonisolated enum JSONFormatter {

    // MARK: Detection

    /// Whether a grid cell should offer "View JSON…": a json / jsonb column, or text that is a JSON
    /// object or array.
    static func looksLikeJSON(_ value: String?, columnType: String) -> Bool {
        guard let value else { return false }
        if columnType.lowercased().contains("json") { return true }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[" else { return false }
        return (try? format(trimmed)) != nil
    }

    // MARK: Formatting

    /// The JSON text re-indented with `indent` (e.g. 4 spaces). Throws, with line and column, when the
    /// text is not valid JSON.
    static func format(_ text: String, indent: String = "    ") throws -> String {
        let s = Array(text.unicodeScalars)
        var i = 0
        var out = String.UnicodeScalarView()
        var depth = 0

        func position(_ k: Int) -> (Int, Int) {
            var line = 1, column = 1
            for c in s[..<min(k, s.count)] { if c == "\n" { line += 1; column = 1 } else { column += 1 } }
            return (line, column)
        }
        func fail(_ message: String, _ k: Int) -> JSONFormatError {
            let (l, c) = position(k)
            return JSONFormatError(message: message, line: l, column: c)
        }
        func skipSpace() { while i < s.count, [" ", "\t", "\n", "\r"].contains(s[i]) { i += 1 } }
        func newline() {
            out.append("\n")
            for _ in 0..<depth { out.append(contentsOf: indent.unicodeScalars) }
        }
        func string() throws {
            let start = i
            out.append(s[i]); i += 1
            while i < s.count {
                let c = s[i]
                if c == "\\" {
                    guard i + 1 < s.count else { break }
                    out.append(c); out.append(s[i + 1]); i += 2; continue
                }
                if c == "\n" { throw fail("Line break inside a string", i) }
                out.append(c); i += 1
                if c == "\"" { return }
            }
            throw fail("Unterminated string", start)
        }
        func scalar() throws {
            let start = i
            while i < s.count, !",]} \t\n\r:".unicodeScalars.contains(s[i]) { i += 1 }
            let word = String(String.UnicodeScalarView(s[start..<i]))
            let isNumber = word.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil
            guard isNumber || ["true", "false", "null"].contains(word) else {
                throw fail(word.isEmpty ? "Unexpected character" : "Unexpected '\(word)'", start)
            }
            out.append(contentsOf: word.unicodeScalars)
        }
        func value() throws {
            skipSpace()
            guard i < s.count else { throw fail("Value expected", i) }
            switch s[i] {
            case "{": try container(close: "}", object: true)
            case "[": try container(close: "]", object: false)
            case "\"": try string()
            default: try scalar()
            }
        }
        func container(close: Unicode.Scalar, object: Bool) throws {
            out.append(s[i]); i += 1
            skipSpace()
            if i < s.count, s[i] == close { out.append(close); i += 1; return }
            depth += 1
            while true {
                newline()
                if object {
                    skipSpace()
                    guard i < s.count, s[i] == "\"" else { throw fail("Property name in double quotes expected", i) }
                    try string()
                    skipSpace()
                    guard i < s.count, s[i] == ":" else { throw fail("Colon expected", i) }
                    i += 1
                    out.append(contentsOf: ": ".unicodeScalars)
                }
                try value()
                skipSpace()
                guard i < s.count else { throw fail("'\(close)' expected", i) }
                if s[i] == "," { out.append(","); i += 1; continue }
                if s[i] == close {
                    depth -= 1
                    newline()
                    out.append(close); i += 1
                    return
                }
                throw fail("Comma or '\(close)' expected", i)
            }
        }

        try value()
        skipSpace()
        guard i == s.count else { throw fail("End of file expected", i) }
        return String(out)
    }

    // MARK: Colouring (VS Code Light+ / Dark+)

    private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                           blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
        }
    }

    static let colors: [JSONToken: NSColor] = [
        .key: dynamic(light: 0x0451A5, dark: 0x9CDCFE),
        .string: dynamic(light: 0xA31515, dark: 0xCE9178),
        .number: dynamic(light: 0x098658, dark: 0xB5CEA8),
        .literal: dynamic(light: 0x0000FF, dark: 0x569CD6),
    ]

    static func apply(to storage: NSTextStorage) {
        let all = NSRange(location: 0, length: storage.length)
        storage.removeAttribute(.foregroundColor, range: all)
        storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: all)
        for (range, token) in tokens(in: storage.string) {
            storage.addAttribute(.foregroundColor, value: colors[token]!, range: range)
        }
    }

    /// Coloured ranges (UTF-16) of `text`; tolerant of invalid JSON while it is being edited.
    static func tokens(in text: String) -> [(NSRange, JSONToken)] {
        let s = Array(text.utf16)
        let n = s.count
        var result: [(NSRange, JSONToken)] = []
        var i = 0
        func isWordChar(_ c: UInt16) -> Bool {
            (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 45 || c == 43 || c == 46
        }
        while i < n {
            let c = s[i]
            if c == 34 {   // "string" or "key"
                var k = i + 1
                while k < n && s[k] != 34 && s[k] != 10 { k += s[k] == 92 ? 2 : 1 }
                k = min(k + 1, n)
                var j = k
                while j < n && (s[j] == 32 || s[j] == 9 || s[j] == 10 || s[j] == 13) { j += 1 }
                result.append((NSRange(location: i, length: k - i), j < n && s[j] == 58 ? .key : .string))
                i = k
                continue
            }
            if isWordChar(c) {
                var k = i
                while k < n && isWordChar(s[k]) { k += 1 }
                let word = String(utf16CodeUnits: Array(s[i..<k]), count: k - i)
                if ["true", "false", "null"].contains(word) {
                    result.append((NSRange(location: i, length: k - i), .literal))
                } else if word.first.map({ $0.isNumber || $0 == "-" }) ?? false {
                    result.append((NSRange(location: i, length: k - i), .number))
                }
                i = k
                continue
            }
            i += 1
        }
        return result
    }
}
