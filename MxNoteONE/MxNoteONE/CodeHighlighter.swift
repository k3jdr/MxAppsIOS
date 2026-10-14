//
//  CodeHighlighter.swift
//  MxNoteONE
//
//  Format ▸ Format as Code: turns the selected lines into a code block — a
//  monospaced font on a shaded block, coloured like VS Code (Dark+ or
//  Light+): keywords, control flow, types, functions, strings, numbers,
//  comments, constants, properties, tags and attributes. The language is
//  detected, or chosen. Code blocks re-colour as you type.
//

import AppKit

extension NSAttributedString.Key {
    /// The language a code block was formatted as (kept while the page is open).
    static let mxCodeLanguage = NSAttributedString.Key("MxCodeLanguage")
}

enum CodeLanguage: String, CaseIterable, Identifiable {
    case auto, swift, python, javascript, typescript, java, csharp, cpp, go, rust, sql, json, html, css, shell, yaml, plain

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "Detect Language"
        case .swift: "Swift"
        case .python: "Python"
        case .javascript: "JavaScript"
        case .typescript: "TypeScript"
        case .java: "Java"
        case .csharp: "C#"
        case .cpp: "C / C++"
        case .go: "Go"
        case .rust: "Rust"
        case .sql: "SQL"
        case .json: "JSON"
        case .html: "HTML / XML"
        case .css: "CSS"
        case .shell: "Shell"
        case .yaml: "YAML"
        case .plain: "Plain Text"
        }
    }
}

enum TokenKind {
    case keyword, control, type, function, string, number, comment, constant, variable, property, tag, attribute, punctuation, decorator
}

/// VS Code's Dark+ and Light+ colours.
struct CodeTheme {
    let name: String
    let background: NSColor
    let text: NSColor
    let colors: [TokenKind: NSColor]

    private static func hex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    static let darkPlus = CodeTheme(name: "Dark+", background: hex(0x1E1E1E), text: hex(0xD4D4D4), colors: [
        .keyword: hex(0x569CD6), .control: hex(0xC586C0), .type: hex(0x4EC9B0), .function: hex(0xDCDCAA),
        .string: hex(0xCE9178), .number: hex(0xB5CEA8), .comment: hex(0x6A9955), .constant: hex(0x569CD6),
        .variable: hex(0x9CDCFE), .property: hex(0x9CDCFE), .tag: hex(0x569CD6), .attribute: hex(0x9CDCFE),
        .punctuation: hex(0x808080), .decorator: hex(0xDCDCAA),
    ])

    static let lightPlus = CodeTheme(name: "Light+", background: hex(0xF5F5F5), text: hex(0x000000), colors: [
        .keyword: hex(0x0000FF), .control: hex(0xAF00DB), .type: hex(0x267F99), .function: hex(0x795E26),
        .string: hex(0xA31515), .number: hex(0x098658), .comment: hex(0x008000), .constant: hex(0x0000FF),
        .variable: hex(0x001080), .property: hex(0x0451A5), .tag: hex(0x800000), .attribute: hex(0xE50000),
        .punctuation: hex(0x800000), .decorator: hex(0x795E26),
    ])

    static let themeKey = "codeTheme"
    static var current: CodeTheme {
        UserDefaults.standard.string(forKey: themeKey) == lightPlus.name ? lightPlus : darkPlus
    }
}

enum CodeHighlighter {
    // MARK: Languages

    struct Spec {
        var keywords: Set<String> = []
        var control: Set<String> = []
        var types: Set<String> = []
        var constants: Set<String> = []
        var lineComments: [String] = []
        var blockComments: [(String, String)] = []
        var quotes: [String] = ["\"", "'"]
        var multilineQuotes: [String] = []
        var caseInsensitive = false
        var capitalizedAreTypes = true
        var decorators = false
        var preprocessor = false
        var variablesColored = true
    }

    private static func words(_ s: String) -> Set<String> { Set(s.split(separator: " ").map(String.init)) }

    static func spec(_ language: CodeLanguage) -> Spec {
        switch language {
        case .swift:
            return Spec(keywords: words("import let var func class struct enum protocol extension init deinit self Self super static private fileprivate internal public open final override mutating nonmutating inout some any typealias associatedtype where in is as get set willSet didSet lazy weak unowned subscript operator convenience required indirect actor async await nonisolated isolated macro"),
                        control: words("if else guard switch case default for while repeat return break continue fallthrough do try catch throw throws rethrows defer"),
                        types: words("Int Double Float String Bool Character Array Dictionary Set Optional Void Any AnyObject Never Data Date URL CGFloat"),
                        constants: words("true false nil"), lineComments: ["//"], blockComments: [("/*", "*/")],
                        quotes: ["\""], multilineQuotes: ["\"\"\""], decorators: true)
        case .python:
            return Spec(keywords: words("def class import from as lambda global nonlocal pass del and or not in is with async await self cls print"),
                        control: words("if elif else for while return break continue try except finally raise yield assert match case"),
                        types: words("int float str bool list dict set tuple bytes object type None"),
                        constants: words("True False None"), lineComments: ["#"], quotes: ["\"", "'"],
                        multilineQuotes: ["\"\"\"", "'''"], capitalizedAreTypes: true, decorators: true)
        case .javascript, .typescript:
            var s = Spec(keywords: words("var let const function class extends new this super import export from as default typeof instanceof in of delete void async await static get set yield"),
                         control: words("if else switch case for while do return break continue try catch finally throw"),
                         types: words("Array Object String Number Boolean Promise Map Set Date RegExp Error JSON Math console"),
                         constants: words("true false null undefined NaN Infinity"), lineComments: ["//"],
                         blockComments: [("/*", "*/")], quotes: ["\"", "'"], multilineQuotes: ["`"], decorators: true)
            if language == .typescript {
                s.keywords.formUnion(words("interface type enum implements private public protected readonly namespace declare abstract keyof infer is"))
                s.types.formUnion(words("string number boolean any unknown never void object"))
            }
            return s
        case .java, .csharp:
            var s = Spec(keywords: words("class interface enum extends implements new this super import package public private protected static final abstract void synchronized volatile transient native instanceof var record"),
                         control: words("if else switch case default for while do return break continue try catch finally throw throws"),
                         types: words("int long short byte float double boolean char String Object Integer List Map"),
                         constants: words("true false null"), lineComments: ["//"], blockComments: [("/*", "*/")],
                         quotes: ["\"", "'"], decorators: true)
            if language == .csharp {
                s.keywords.formUnion(words("namespace using struct internal readonly override virtual sealed async await get set value out ref params is as base partial delegate event operator"))
                s.types.formUnion(words("string bool decimal object dynamic"))
                s.control.formUnion(words("foreach yield"))
            }
            return s
        case .cpp:
            return Spec(keywords: words("class struct union enum namespace using template typename public private protected virtual override static const constexpr inline extern volatile mutable friend operator new delete this sizeof typedef auto explicit noexcept nullptr"),
                        control: words("if else switch case default for while do return break continue goto try catch throw"),
                        types: words("int long short char float double bool void unsigned signed size_t string vector map std uint8_t uint32_t int32_t int64_t"),
                        constants: words("true false NULL nullptr"), lineComments: ["//"], blockComments: [("/*", "*/")],
                        quotes: ["\"", "'"], preprocessor: true)
        case .go:
            return Spec(keywords: words("package import func var const type struct interface map chan go defer select range"),
                        control: words("if else switch case default for return break continue goto fallthrough"),
                        types: words("int int8 int16 int32 int64 uint uint8 uint16 uint32 uint64 float32 float64 string bool byte rune error any"),
                        constants: words("true false nil iota"), lineComments: ["//"], blockComments: [("/*", "*/")],
                        quotes: ["\"", "'"], multilineQuotes: ["`"])
        case .rust:
            return Spec(keywords: words("fn let mut const static struct enum trait impl pub crate mod use self Self super where as ref move dyn type unsafe async await extern"),
                        control: words("if else match for while loop return break continue in"),
                        types: words("i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str String Vec Option Result Box"),
                        constants: words("true false None Some Ok Err"), lineComments: ["//"], blockComments: [("/*", "*/")],
                        quotes: ["\""], decorators: true)
        case .sql:
            return Spec(keywords: words("select from where insert into values update set delete create table view index drop alter add column primary key foreign references join inner left right full outer on as and or not null is in like between distinct group by order having limit offset union all case when then else end exists default unique check constraint procedure function returns begin commit rollback transaction materialized refresh with grant revoke asc desc"),
                        types: words("int integer bigint smallint numeric decimal real float double varchar char text boolean date time timestamp timestamptz json jsonb uuid serial"),
                        constants: words("true false null"), lineComments: ["--"], blockComments: [("/*", "*/")],
                        quotes: ["'"], caseInsensitive: true, capitalizedAreTypes: false, variablesColored: false)
        case .shell:
            return Spec(keywords: words("echo export local readonly source alias unset set cd sudo"),
                        control: words("if then else elif fi for in do done while until case esac function return exit"),
                        constants: words("true false"), lineComments: ["#"], quotes: ["\"", "'"],
                        capitalizedAreTypes: false, variablesColored: false)
        case .yaml, .json, .html, .css, .plain, .auto:
            return Spec(constants: words("true false null yes no on off"), lineComments: language == .yaml ? ["#"] : [],
                        blockComments: language == .css ? [("/*", "*/")] : [], quotes: ["\"", "'"],
                        capitalizedAreTypes: false, variablesColored: false)
        }
    }

    // MARK: Detection

    static func detect(_ code: String) -> CodeLanguage {
        let text = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        func has(_ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
        if text.hasPrefix("{") || text.hasPrefix("["), has("\"[^\"]+\"\\s*:") { return .json }
        if text.hasPrefix("<") { return .html }
        if text.hasPrefix("#!") || has("(?m)^\\s*(echo|export|sudo|cd|brew|git|npm|xcodebuild) ") { return .shell }
        if has("(?i)^\\s*(select|insert|update|delete|create|alter|drop|with|call)\\s") { return .sql }
        if has("(?m)^\\s*#include") || has("std::") || has("int main\\s*\\(") { return .cpp }
        if has("(?m)^\\s*using System") || has("(?m)namespace\\s+\\w+") && has("\\bpublic\\b") { return .csharp }
        if has("public\\s+(static\\s+)?(class|void)") || has("System\\.out\\.") { return .java }
        if has("(?m)^\\s*package\\s+\\w+") && has("\\bfunc\\b") || has(":=") && has("\\bfunc\\b") { return .go }
        if has("\\bfn\\s+\\w+") || has("let\\s+mut\\b") || has("\\bimpl\\b") { return .rust }
        if has("(?m)^\\s*(import (SwiftUI|Foundation|AppKit|UIKit))") || has("\\bfunc\\s+\\w+") || has("\\bguard\\b") || has("\\b(let|var)\\s+\\w+\\s*(:\\s*\\w+)?\\s*=") && has("\\bfunc\\b|\\bstruct\\b|\\bclass\\b|\\?\\?") { return .swift }
        if has("(?m)^\\s*(def|class)\\s+\\w+.*:\\s*$") || has("(?m)^\\s*(import|from)\\s+\\w+") && has(":\\s*$") || has("\\bself\\.") && has(":\\s*$") || has("(?m)^\\s*elif\\b") || has("print\\(") && !has(";") { return .python }
        if has("\\binterface\\s+\\w+") && has(":\\s*(string|number|boolean)") || has(":\\s*(string|number|boolean)\\b") { return .typescript }
        if has("\\b(const|let|var|function)\\b") || has("=>") || has("console\\.") { return .javascript }
        if has("(?m)^[\\w.#\\[\\]:-]+\\s*\\{") && has("[\\w-]+\\s*:\\s*[^;]+;") { return .css }
        if has("(?m)^\\s*[\\w-]+:\\s") && !text.contains("{") && !text.contains(";") { return .yaml }
        if lower.contains("select ") || lower.contains(" from ") { return .sql }
        return .plain
    }

    // MARK: Tokens

    static func tokens(_ code: String, language: CodeLanguage) -> [(NSRange, TokenKind)] {
        switch language {
        case .html: return markupTokens(code)
        case .css: return cssTokens(code)
        default: return codeTokens(code, language: language)
        }
    }

    private static func isIdentStart(_ c: unichar) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36
    }

    private static func isIdent(_ c: unichar) -> Bool {
        isIdentStart(c) || (c >= 48 && c <= 57)
    }

    private static func isDigit(_ c: unichar) -> Bool { c >= 48 && c <= 57 }

    private static func codeTokens(_ code: String, language: CodeLanguage) -> [(NSRange, TokenKind)] {
        let spec = spec(language)
        let ns = code as NSString
        let n = ns.length
        var result: [(NSRange, TokenKind)] = []
        var i = 0
        var lineStart = true
        func starts(_ s: String, at index: Int) -> Bool {
            let len = (s as NSString).length
            return index + len <= n && ns.substring(with: NSRange(location: index, length: len)) == s
        }
        func lineEnd(from index: Int) -> Int {
            var j = index
            while j < n, ns.character(at: j) != 0x0A { j += 1 }
            return j
        }
        func nextNonSpace(from index: Int) -> unichar? {
            var j = index
            while j < n, ns.character(at: j) == 0x20 || ns.character(at: j) == 0x09 { j += 1 }
            return j < n ? ns.character(at: j) : nil
        }
        scan: while i < n {
            let c = ns.character(at: i)
            if c == 0x0A { lineStart = true; i += 1; continue }
            if c == 0x20 || c == 0x09 { i += 1; continue }
            // comments
            for (open, close) in spec.blockComments where starts(open, at: i) {
                let rest = NSRange(location: i + (open as NSString).length, length: n - i - (open as NSString).length)
                let end = ns.range(of: close, options: [], range: rest)
                let stop = end.location == NSNotFound ? n : NSMaxRange(end)
                result.append((NSRange(location: i, length: stop - i), .comment))
                i = stop
                lineStart = false
                continue scan
            }
            for marker in spec.lineComments where starts(marker, at: i) {
                // "#" in shell/python/yaml only starts a comment at a word boundary
                let stop = lineEnd(from: i)
                result.append((NSRange(location: i, length: stop - i), .comment))
                i = stop
                continue scan
            }
            // preprocessor (#include, #define…)
            if spec.preprocessor, lineStart, c == 0x23 {
                var j = i + 1
                while j < n, isIdent(ns.character(at: j)) { j += 1 }
                result.append((NSRange(location: i, length: j - i), .control))
                i = j
                lineStart = false
                continue
            }
            lineStart = false
            // strings
            for quote in spec.multilineQuotes + spec.quotes where starts(quote, at: i) {
                let qlen = (quote as NSString).length
                let multiline = spec.multilineQuotes.contains(quote)
                var j = i + qlen
                while j < n {
                    let d = ns.character(at: j)
                    if d == 0x5C { j += 2; continue }
                    if !multiline, d == 0x0A { break }
                    if starts(quote, at: j) { j += qlen; break }
                    j += 1
                }
                j = min(j, n)
                var kind: TokenKind = .string
                if language == .json || language == .yaml, nextNonSpace(from: j) == 0x3A { kind = .property }
                result.append((NSRange(location: i, length: j - i), kind))
                i = j
                continue scan
            }
            // numbers
            if isDigit(c) || (c == 0x2E && i + 1 < n && isDigit(ns.character(at: i + 1))) {
                var j = i + 1
                while j < n, isIdent(ns.character(at: j)) || ns.character(at: j) == 0x2E { j += 1 }
                result.append((NSRange(location: i, length: j - i), .number))
                i = j
                continue
            }
            // decorators / attributes (@Published, @dataclass)
            if spec.decorators, c == 0x40, i + 1 < n, isIdentStart(ns.character(at: i + 1)) {
                var j = i + 1
                while j < n, isIdent(ns.character(at: j)) { j += 1 }
                result.append((NSRange(location: i, length: j - i), .decorator))
                i = j
                continue
            }
            // shell variables ($HOME, ${NAME})
            if language == .shell, c == 0x24 {
                var j = i + 1
                if j < n, ns.character(at: j) == 0x7B {
                    while j < n, ns.character(at: j) != 0x7D { j += 1 }
                    j = min(j + 1, n)
                } else {
                    while j < n, isIdent(ns.character(at: j)) { j += 1 }
                }
                result.append((NSRange(location: i, length: j - i), .variable))
                i = j
                continue
            }
            // identifiers
            if isIdentStart(c) {
                var j = i + 1
                while j < n, isIdent(ns.character(at: j)) || (language == .yaml && ns.character(at: j) == 0x2D) { j += 1 }
                let word = ns.substring(with: NSRange(location: i, length: j - i))
                let key = spec.caseInsensitive ? word.lowercased() : word
                let range = NSRange(location: i, length: j - i)
                if language == .yaml, nextNonSpace(from: j) == 0x3A {
                    result.append((range, .property))
                } else if spec.constants.contains(key) || (spec.caseInsensitive && spec.constants.contains(word.lowercased())) {
                    result.append((range, .constant))
                } else if spec.control.contains(key) {
                    result.append((range, .control))
                } else if spec.keywords.contains(key) {
                    result.append((range, .keyword))
                } else if spec.types.contains(key) {
                    result.append((range, .type))
                } else if nextNonSpace(from: j) == 0x28 {
                    result.append((range, .function))
                } else if spec.capitalizedAreTypes, let first = word.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first) {
                    result.append((range, .type))
                } else if spec.variablesColored {
                    result.append((range, .variable))
                }
                i = j
                continue
            }
            i += 1
        }
        return result
    }

    private static func markupTokens(_ code: String) -> [(NSRange, TokenKind)] {
        let ns = code as NSString
        let n = ns.length
        var result: [(NSRange, TokenKind)] = []
        var i = 0
        while i < n {
            if ns.character(at: i) == 0x3C {
                if i + 3 < n, ns.substring(with: NSRange(location: i, length: 4)) == "<!--" {
                    let end = ns.range(of: "-->", options: [], range: NSRange(location: i, length: n - i))
                    let stop = end.location == NSNotFound ? n : NSMaxRange(end)
                    result.append((NSRange(location: i, length: stop - i), .comment))
                    i = stop
                    continue
                }
                result.append((NSRange(location: i, length: 1), .punctuation))
                var j = i + 1
                if j < n, ns.character(at: j) == 0x2F || ns.character(at: j) == 0x3F || ns.character(at: j) == 0x21 {
                    result.append((NSRange(location: j, length: 1), .punctuation))
                    j += 1
                }
                let nameStart = j
                while j < n, isIdent(ns.character(at: j)) || ns.character(at: j) == 0x2D || ns.character(at: j) == 0x3A { j += 1 }
                if j > nameStart { result.append((NSRange(location: nameStart, length: j - nameStart), .tag)) }
                // attributes until '>'
                while j < n, ns.character(at: j) != 0x3E {
                    let c = ns.character(at: j)
                    if c == 0x22 || c == 0x27 {
                        var k = j + 1
                        while k < n, ns.character(at: k) != c { k += 1 }
                        k = min(k + 1, n)
                        result.append((NSRange(location: j, length: k - j), .string))
                        j = k
                    } else if isIdentStart(c) {
                        var k = j + 1
                        while k < n, isIdent(ns.character(at: k)) || ns.character(at: k) == 0x2D || ns.character(at: k) == 0x3A { k += 1 }
                        result.append((NSRange(location: j, length: k - j), .attribute))
                        j = k
                    } else {
                        j += 1
                    }
                }
                if j < n { result.append((NSRange(location: j, length: 1), .punctuation)) }
                i = j + 1
            } else {
                i += 1
            }
        }
        return result
    }

    private static func cssTokens(_ code: String) -> [(NSRange, TokenKind)] {
        let ns = code as NSString
        let n = ns.length
        var result: [(NSRange, TokenKind)] = []
        var i = 0
        var inBlock = false
        var afterColon = false
        while i < n {
            let c = ns.character(at: i)
            if c == 0x2F, i + 1 < n, ns.character(at: i + 1) == 0x2A {
                let end = ns.range(of: "*/", options: [], range: NSRange(location: i, length: n - i))
                let stop = end.location == NSNotFound ? n : NSMaxRange(end)
                result.append((NSRange(location: i, length: stop - i), .comment))
                i = stop
                continue
            }
            switch c {
            case 0x7B: inBlock = true; afterColon = false; i += 1; continue
            case 0x7D: inBlock = false; afterColon = false; i += 1; continue
            case 0x3A where inBlock: afterColon = true; i += 1; continue
            case 0x3B: afterColon = false; i += 1; continue
            default: break
            }
            if c == 0x22 || c == 0x27 {
                var j = i + 1
                while j < n, ns.character(at: j) != c { j += 1 }
                j = min(j + 1, n)
                result.append((NSRange(location: i, length: j - i), .string))
                i = j
                continue
            }
            if c == 0x20 || c == 0x09 || c == 0x0A { i += 1; continue }
            var j = i
            while j < n {
                let d = ns.character(at: j)
                if d == 0x20 || d == 0x09 || d == 0x0A || d == 0x7B || d == 0x7D || d == 0x3B || (d == 0x3A && inBlock && !afterColon) { break }
                j += 1
            }
            if j == i { j = i + 1 }
            let range = NSRange(location: i, length: j - i)
            if !inBlock {
                result.append((range, .tag))
            } else if afterColon {
                result.append((range, isDigit(c) || c == 0x2E || c == 0x2D ? .number : .string))
            } else {
                result.append((range, .property))
            }
            i = j
        }
        return result
    }

    // MARK: Applying

    static var codeFont: NSFont {
        let size = max(11, Prefs.fontSize - 1)
        return NSFont(name: "Menlo", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Whether text uses a code block's look (a monospaced font in a shaded block).
    static func isCode(_ attrs: [NSAttributedString.Key: Any]) -> Bool {
        guard let font = attrs[.font] as? NSFont, font.isFixedPitch || font.fontDescriptor.symbolicTraits.contains(.monoSpace) else {
            return false
        }
        return !((attrs[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.isEmpty ?? true)
    }

    /// Formats whole paragraphs as a code block (undoable through the text view).
    static func format(_ tv: NSTextView, language: CodeLanguage, theme: CodeTheme = .current) {
        guard let storage = tv.textStorage, storage.length > 0 else { return }
        let ns = storage.string as NSString
        var range = ns.paragraphRange(for: tv.selectedRange())
        if range.length == 0 { range = ns.paragraphRange(for: NSRange(location: max(0, range.location - 1), length: 0)) }
        guard tv.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        apply(storage, range: range, language: language, theme: theme)
        storage.endEditing()
        tv.didChangeText()
        tv.undoManager?.setActionName("Format as Code")
        var typing = storage.attributes(at: max(range.location, NSMaxRange(range) - 1), effectiveRange: nil)
        typing[.foregroundColor] = theme.text
        tv.typingAttributes = typing
    }

    static func apply(_ storage: NSTextStorage, range: NSRange, language: CodeLanguage, theme: CodeTheme) {
        let code = (storage.string as NSString).substring(with: range)
        let resolved = language == .auto ? detect(code) : language
        // A one-cell table: unlike a plain text block, RTFD keeps its shading when the page is saved.
        let table = NSTextTable()
        table.numberOfColumns = 1
        table.setContentWidth(100, type: .percentageValueType)
        let block = NSTextTableBlock(table: table, startingRow: 0, rowSpan: 1, startingColumn: 0, columnSpan: 1)
        block.backgroundColor = theme.background
        block.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
        block.setWidth(10, type: .absoluteValueType, for: .padding, edge: .maxX)
        block.setWidth(2, type: .absoluteValueType, for: .padding, edge: .minY)
        block.setWidth(2, type: .absoluteValueType, for: .padding, edge: .maxY)
        let paragraph = NSMutableParagraphStyle()
        paragraph.textBlocks = [block]
        paragraph.lineHeightMultiple = 1.15
        // .mxAutoColor too: table cells drop the colour of "automatic" text when they're saved.
        let keys: [NSAttributedString.Key] = [.backgroundColor, .underlineStyle, .strikethroughStyle, .superscript, .link, .obliqueness, .mxAutoColor]
        for key in keys { storage.removeAttribute(key, range: range) }
        storage.addAttributes([.font: codeFont, .foregroundColor: theme.text, .paragraphStyle: paragraph,
                               .mxCodeLanguage: resolved.rawValue], range: range)
        for (token, kind) in tokens(code, language: resolved) {
            guard let color = theme.colors[kind] else { continue }
            storage.addAttribute(.foregroundColor, value: color, range: NSRange(location: range.location + token.location, length: token.length))
        }
    }

    /// The code block around a location: the neighbouring paragraphs that are also code.
    static func blockRange(in storage: NSTextStorage, at location: Int) -> NSRange? {
        guard storage.length > 0 else { return nil }
        let ns = storage.string as NSString
        let index = min(location, storage.length - 1)
        guard isCode(storage.attributes(at: index, effectiveRange: nil)) else { return nil }
        var range = ns.paragraphRange(for: NSRange(location: index, length: 0))
        while range.location > 0 {
            let previous = ns.paragraphRange(for: NSRange(location: range.location - 1, length: 0))
            guard isCode(storage.attributes(at: previous.location, effectiveRange: nil)) else { break }
            range = NSRange(location: previous.location, length: NSMaxRange(range) - previous.location)
        }
        while NSMaxRange(range) < ns.length {
            let next = ns.paragraphRange(for: NSRange(location: NSMaxRange(range), length: 0))
            guard isCode(storage.attributes(at: next.location, effectiveRange: nil)) else { break }
            range = NSRange(location: range.location, length: NSMaxRange(next) - range.location)
        }
        return range
    }

    /// Re-colours the code block being typed in (colours aren't separate undo steps).
    static func recolor(_ tv: NSTextView) {
        guard let storage = tv.textStorage, let range = blockRange(in: storage, at: max(0, tv.selectedRange().location - 1)) else { return }
        let language = (storage.attribute(.mxCodeLanguage, at: range.location, effectiveRange: nil) as? String)
            .flatMap(CodeLanguage.init(rawValue:)) ?? .auto
        let background = (storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?
            .textBlocks.first?.backgroundColor
        let theme = background.map { $0.usingColorSpace(.sRGB)?.brightnessComponent ?? 0 > 0.5 } == true ? CodeTheme.lightPlus : .darkPlus
        let code = (storage.string as NSString).substring(with: range)
        let resolved = language == .auto ? detect(code) : language
        storage.beginEditing()
        storage.removeAttribute(.mxAutoColor, range: range)
        storage.addAttribute(.foregroundColor, value: theme.text, range: range)
        storage.addAttribute(.mxCodeLanguage, value: resolved.rawValue, range: range)
        for (token, kind) in tokens(code, language: resolved) {
            guard let color = theme.colors[kind] else { continue }
            storage.addAttribute(.foregroundColor, value: color, range: NSRange(location: range.location + token.location, length: token.length))
        }
        storage.endEditing()
    }
}
