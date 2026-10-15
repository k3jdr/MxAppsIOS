//
//  TableFormulas.swift
//  MxNoteONE
//
//  Excel-style formulas in table cells: a cell whose text starts with "="
//  shows the result (typing in it shows the formula). References use the
//  column letters and row numbers (A1, $B$2, B2:B9), with + - * / ^ & and
//  comparisons, and Excel's common functions — SUM, AVERAGE, COUNT, MIN,
//  MAX, IF, ROUND, SUMIF, COUNTIF, IFERROR… Errors show as Excel shows them
//  (#DIV/0!, #REF!, #NAME?, #VALUE!, #NUM!, #N/A) and loops as #CIRC!.
//  References follow inserted and deleted rows and columns. Dates are
//  Excel serial day numbers (typed dates are recognised), so date ± days
//  and date − date work, with DATE, YEAR, MONTH, DAY, EDATE, DATEDIF…
//

import Foundation

/// A formula's value.
enum FormulaValue: Equatable {
    case number(Double)
    /// A date (and time) as an Excel serial number: days since 30 Dec 1899, the time as the fraction.
    case date(Double)
    case text(String)
    case bool(Bool)
    case error(String)
    case empty
    case range([FormulaValue])

    /// As shown in the cell.
    var display: String {
        switch self {
        case .number(let d): return Formula.format(d)
        case .date(let d): return Formula.generalDate(d)
        case .text(let s): return s
        case .bool(let b): return b ? "TRUE" : "FALSE"
        case .error(let e): return e
        case .empty: return ""
        case .range(let values): return values.first?.display ?? ""
        }
    }

    var isError: Bool { if case .error = self { return true } else { return false } }
}

enum Formula {
    // MARK: Cell text

    static func isFormula(_ text: String) -> Bool {
        text.hasPrefix("=") && text.count > 1
    }

    /// Plain cell text as a value: numbers (1,234.5  $12  12%  (5)), TRUE / FALSE, text, or empty.
    static func value(ofText raw: String) -> FormulaValue {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .empty }
        if let number = number(from: text) { return .number(number) }
        if let serial = dateSerial(from: text) { return .date(serial) }
        switch text.uppercased() {
        case "TRUE": return .bool(true)
        case "FALSE": return .bool(false)
        default: return .text(raw)
        }
    }

    static func number(from text: String) -> Double? {
        var s = text.trimmingCharacters(in: .whitespaces)
        var negative = false
        if s.hasPrefix("("), s.hasSuffix(")") { negative = true; s = String(s.dropFirst().dropLast()) }
        var percent = false
        if s.hasSuffix("%") { percent = true; s.removeLast() }
        s = s.replacingOccurrences(of: ",", with: "")
        for symbol in ["$", "€", "£", "¥"] where s.hasPrefix(symbol) || s.hasPrefix("-" + symbol) {
            s = s.replacingOccurrences(of: symbol, with: "")
        }
        s = s.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, s.range(of: "^[-+]?(\\d+\\.?\\d*|\\.\\d+)([eE][-+]?\\d+)?$", options: .regularExpression) != nil,
              var d = Double(s) else { return nil }
        if percent { d /= 100 }
        return negative ? -d : d
    }

    /// A number or a date typed in a cell, as a number (a date as its serial number).
    static func numeric(_ text: String) -> Double? {
        number(from: text) ?? dateSerial(from: text)
    }

    // MARK: Dates

    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }()

    /// Excel's day 0.
    private static let epoch = calendar.date(from: DateComponents(year: 1899, month: 12, day: 30))!

    /// Dates and times typed as in Excel (US order).
    private static let datePatterns = [
        "yyyy-MM-dd", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "M/d/yyyy", "M/d/yyyy h:mm a", "M/d/yyyy H:mm", "M/d/yy",
        "d-MMM-yyyy", "d-MMM-yy", "d MMM yyyy", "MMM d, yyyy", "MMMM d, yyyy", "EEEE, MMMM d, yyyy", "EEE, MMM d, yyyy",
        "MMMM yyyy", "MMM yyyy", "h:mm a", "H:mm",
    ]

    private static let dateParsers: [DateFormatter] = datePatterns.map { pattern in
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = .current
        f.dateFormat = pattern
        f.isLenient = false
        // Missing parts (the day of "October 2026") come from 1 Jan 2000.
        f.defaultDate = calendar.date(from: DateComponents(year: 2000, month: 1, day: 1))
        return f
    }

    /// A typed date or time as an Excel serial number (a time alone is the fraction of a day).
    static func dateSerial(from text: String) -> Double? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count >= 4, s.count <= 40, s.contains(where: \.isNumber),
              s.contains(where: { "/-:, ".contains($0) || $0.isLetter }) else { return nil }
        for (i, parser) in dateParsers.enumerated() {
            guard let date = parser.date(from: s) else { continue }
            let timeOnly = datePatterns[i].hasPrefix("h:") || datePatterns[i].hasPrefix("H:")
            let value = serial(date)
            return timeOnly ? value - value.rounded(.down) : value
        }
        return nil
    }

    static func serial(_ date: Date) -> Double {
        let day = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: epoch, to: day).day ?? 0
        return Double(days) + date.timeIntervalSince(day) / 86_400
    }

    static func date(fromSerial serial: Double) -> Date {
        let days = Int(serial.rounded(.down))
        let day = calendar.date(byAdding: .day, value: days, to: epoch) ?? epoch
        return day.addingTimeInterval(((serial - Double(days)) * 86_400).rounded())
    }

    static func components(_ serial: Double) -> DateComponents {
        calendar.dateComponents([.year, .month, .day, .weekday], from: date(fromSerial: serial))
    }

    static func serial(year: Int, month: Int, day: Int) -> Double? {
        calendar.date(from: DateComponents(year: year, month: month, day: day)).map(serial)
    }

    /// A date as General shows it: 10/14/2026, with the time when there is one.
    static func generalDate(_ serial: Double) -> String {
        let hasTime = abs(serial - serial.rounded(.down)) > 1e-9
        return formatDate(serial, pattern: hasTime ? (serial < 1 ? "h:mm a" : "M/d/yyyy h:mm a") : "M/d/yyyy")
    }

    static func formatDate(_ serial: Double, pattern: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.calendar = calendar
        f.timeZone = .current
        f.dateFormat = pattern
        return f.string(from: date(fromSerial: serial))
    }

    /// Numbers as Excel's General format shows them.
    static func format(_ d: Double) -> String {
        guard d.isFinite else { return "#NUM!" }
        if d == 0 { return "0" }
        if abs(d) >= 1e15 || abs(d) < 1e-9 { return String(format: "%.6G", d) }
        var s = String(format: "%.10f", d)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s == "-0" ? "0" : s
    }

    // MARK: References

    /// A1-style reference: 0-based row and column.
    struct Ref: Hashable {
        var row: Int
        var column: Int
        var absoluteRow = false
        var absoluteColumn = false

        var text: String {
            (absoluteColumn ? "$" : "") + TableData.columnName(column) + (absoluteRow ? "$" : "") + "\(row + 1)"
        }
    }

    static func parseRef(_ s: String) -> Ref? {
        let pattern = "^(\\$?)([A-Za-z]{1,3})(\\$?)([0-9]+)$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) else { return nil }
        let ns = s as NSString
        let letters = ns.substring(with: m.range(at: 2)).uppercased()
        guard let row = Int(ns.substring(with: m.range(at: 4))), row >= 1 else { return nil }
        var column = 0
        for scalar in letters.unicodeScalars { column = column * 26 + Int(scalar.value) - 64 }
        return Ref(row: row - 1, column: column - 1, absoluteRow: m.range(at: 3).length > 0, absoluteColumn: m.range(at: 1).length > 0)
    }

    // MARK: Tokens

    enum Token: Equatable {
        case number(Double)
        case text(String)
        case ref(String)
        case name(String)
        case op(String)
        case lparen, rparen, comma, colon
    }

    /// Tokens with their places in the text (for rewriting references).
    static func tokenize(_ formula: String) -> [(token: Token, range: Range<String.Index>)]? {
        var result: [(Token, Range<String.Index>)] = []
        var i = formula.startIndex
        func peek(_ offset: Int = 0) -> Character? {
            guard let j = formula.index(i, offsetBy: offset, limitedBy: formula.endIndex), j < formula.endIndex else { return nil }
            return formula[j]
        }
        while i < formula.endIndex {
            let c = formula[i]
            let start = i
            if c.isWhitespace { i = formula.index(after: i); continue }
            if c == "\"" {
                var s = ""
                i = formula.index(after: i)
                var closed = false
                while i < formula.endIndex {
                    if formula[i] == "\"" {
                        let next = formula.index(after: i)
                        if next < formula.endIndex, formula[next] == "\"" { s.append("\""); i = formula.index(after: next); continue }
                        i = next
                        closed = true
                        break
                    }
                    s.append(formula[i])
                    i = formula.index(after: i)
                }
                guard closed else { return nil }
                result.append((.text(s), start..<i))
                continue
            }
            if c.isNumber || (c == "." && peek(1)?.isNumber == true) {
                while i < formula.endIndex, formula[i].isNumber || formula[i] == "." { i = formula.index(after: i) }
                if i < formula.endIndex, formula[i] == "e" || formula[i] == "E" {
                    let save = i
                    i = formula.index(after: i)
                    if i < formula.endIndex, formula[i] == "+" || formula[i] == "-" { i = formula.index(after: i) }
                    if i < formula.endIndex, formula[i].isNumber {
                        while i < formula.endIndex, formula[i].isNumber { i = formula.index(after: i) }
                    } else {
                        i = save
                    }
                }
                guard let d = Double(formula[start..<i]) else { return nil }
                result.append((.number(d), start..<i))
                continue
            }
            if c.isLetter || c == "$" || c == "_" {
                while i < formula.endIndex, formula[i].isLetter || formula[i].isNumber || formula[i] == "$" || formula[i] == "_" || formula[i] == "." {
                    i = formula.index(after: i)
                }
                let word = String(formula[start..<i])
                result.append((parseRef(word) != nil ? .ref(word) : .name(word.uppercased()), start..<i))
                continue
            }
            i = formula.index(after: i)
            switch c {
            case "(": result.append((.lparen, start..<i))
            case ")": result.append((.rparen, start..<i))
            case ",", ";": result.append((.comma, start..<i))
            case ":": result.append((.colon, start..<i))
            case "<", ">":
                if i < formula.endIndex, formula[i] == "=" || (c == "<" && formula[i] == ">") {
                    i = formula.index(after: i)
                }
                result.append((.op(String(formula[start..<i])), start..<i))
            case "+", "-", "*", "/", "^", "&", "=", "%": result.append((.op(String(c)), start..<i))
            default: return nil
            }
        }
        return result
    }

    // MARK: Parsing

    indirect enum Node {
        case number(Double)
        case text(String)
        case bool(Bool)
        case ref(Ref)
        case range(Ref, Ref)
        case unary(String, Node)
        case percent(Node)
        case binary(String, Node, Node)
        case call(String, [Node])
        case error(String)
    }

    struct Parser {
        var tokens: [Token]
        var i = 0

        mutating func parse() -> Node? {
            guard let node = comparison(), i == tokens.count else { return nil }
            return node
        }

        private mutating func next() -> Token? { i < tokens.count ? tokens[i] : nil }
        private mutating func take(_ t: Token) -> Bool {
            if next() == t { i += 1; return true }
            return false
        }

        private mutating func comparison() -> Node? {
            guard var left = concat() else { return nil }
            while case .op(let o)? = next(), ["=", "<>", "<", ">", "<=", ">="].contains(o) {
                i += 1
                guard let right = concat() else { return nil }
                left = .binary(o, left, right)
            }
            return left
        }

        private mutating func concat() -> Node? {
            guard var left = additive() else { return nil }
            while take(.op("&")) {
                guard let right = additive() else { return nil }
                left = .binary("&", left, right)
            }
            return left
        }

        private mutating func additive() -> Node? {
            guard var left = multiplicative() else { return nil }
            while case .op(let o)? = next(), o == "+" || o == "-" {
                i += 1
                guard let right = multiplicative() else { return nil }
                left = .binary(o, left, right)
            }
            return left
        }

        private mutating func multiplicative() -> Node? {
            guard var left = power() else { return nil }
            while case .op(let o)? = next(), o == "*" || o == "/" {
                i += 1
                guard let right = power() else { return nil }
                left = .binary(o, left, right)
            }
            return left
        }

        private mutating func power() -> Node? {
            guard var left = unary() else { return nil }
            while take(.op("^")) {
                guard let right = unary() else { return nil }
                left = .binary("^", left, right)
            }
            return left
        }

        private mutating func unary() -> Node? {
            if case .op(let o)? = next(), o == "-" || o == "+" {
                i += 1
                guard let operand = unary() else { return nil }
                return o == "-" ? .unary("-", operand) : operand
            }
            guard var node = primary() else { return nil }
            while take(.op("%")) { node = .percent(node) }
            return node
        }

        private mutating func primary() -> Node? {
            guard let token = next() else { return nil }
            i += 1
            switch token {
            case .number(let d): return .number(d)
            case .text(let s): return .text(s)
            case .ref(let s):
                guard let a = parseRef(s) else { return nil }
                if take(.colon) {
                    guard case .ref(let t)? = next(), let b = parseRef(t) else { return nil }
                    i += 1
                    return .range(a, b)
                }
                return .ref(a)
            case .name(let name):
                if take(.lparen) {
                    var args: [Node] = []
                    if take(.rparen) { return .call(name, args) }
                    while true {
                        guard let arg = comparison() else { return nil }
                        args.append(arg)
                        if take(.comma) { continue }
                        guard take(.rparen) else { return nil }
                        return .call(name, args)
                    }
                }
                switch name {
                case "TRUE": return .bool(true)
                case "FALSE": return .bool(false)
                case "#REF!": return .error("#REF!")
                default: return .error("#NAME?")
                }
            case .lparen:
                guard let inner = comparison(), take(.rparen) else { return nil }
                return inner
            case .op("#"):
                return nil
            default:
                return nil
            }
        }
    }

    static func parse(_ formula: String) -> Node? {
        var body = formula
        if body.hasPrefix("=") { body.removeFirst() }
        // A reference made invalid by a deleted row or column.
        guard let tokens = tokenize(body.replacingOccurrences(of: "#REF!", with: "REF_ERROR_")) else { return nil }
        var parser = Parser(tokens: tokens.map { t in
            if case .name("REF_ERROR_") = t.token { return .name("#REF!") }
            return t.token
        })
        return parser.parse()
    }

    // MARK: Evaluating

    /// Evaluates a formula; `cell` gives a referenced cell's value (or nil when it's outside the table).
    static func evaluate(_ formula: String, cell: (Ref) -> FormulaValue?) -> FormulaValue {
        guard let node = parse(formula) else { return .error("#ERROR!") }
        let result = withoutActuallyEscaping(cell) { Evaluator(cell: $0).eval(node) }
        if case .range(let values) = result { return values.count == 1 ? scalar(values[0]) : .error("#VALUE!") }
        return scalar(result)
    }

    private static func scalar(_ v: FormulaValue) -> FormulaValue {
        if case .empty = v { return .number(0) }
        return v
    }

    struct Evaluator {
        let cell: (Ref) -> FormulaValue?

        func eval(_ node: Node) -> FormulaValue {
            switch node {
            case .number(let d): return .number(d)
            case .text(let s): return .text(s)
            case .bool(let b): return .bool(b)
            case .error(let e): return .error(e)
            case .ref(let r): return cell(r) ?? .error("#REF!")
            case .range(let a, let b):
                var values: [FormulaValue] = []
                for row in min(a.row, b.row)...max(a.row, b.row) {
                    for column in min(a.column, b.column)...max(a.column, b.column) {
                        guard let v = cell(Ref(row: row, column: column)) else { return .error("#REF!") }
                        values.append(v)
                    }
                }
                return .range(values)
            case .unary(_, let operand):
                let v = single(eval(operand))
                guard let d = numberValue(v) else { return v.isError ? v : .error("#VALUE!") }
                return .number(-d)
            case .percent(let operand):
                let v = single(eval(operand))
                guard let d = numberValue(v) else { return v.isError ? v : .error("#VALUE!") }
                return .number(d / 100)
            case .binary(let op, let l, let r):
                return binary(op, single(eval(l)), single(eval(r)))
            case .call(let name, let args):
                return call(name, args)
            }
        }

        /// A range used where one value is expected: its only cell, else #VALUE!.
        private func single(_ v: FormulaValue) -> FormulaValue {
            if case .range(let values) = v { return values.count == 1 ? values[0] : .error("#VALUE!") }
            return v
        }

        private func numberValue(_ v: FormulaValue) -> Double? {
            switch v {
            case .number(let d), .date(let d): return d
            case .bool(let b): return b ? 1 : 0
            case .empty: return 0
            case .text(let s): return Formula.numeric(s)
            default: return nil
            }
        }

        private func textValue(_ v: FormulaValue) -> String {
            switch v {
            case .empty: return ""
            default: return v.display
            }
        }

        private func truth(_ v: FormulaValue) -> Bool? {
            switch v {
            case .bool(let b): return b
            case .number(let d), .date(let d): return d != 0
            case .empty: return false
            case .text(let s):
                if s.uppercased() == "TRUE" { return true }
                if s.uppercased() == "FALSE" { return false }
                return nil
            default: return nil
            }
        }

        private func binary(_ op: String, _ a: FormulaValue, _ b: FormulaValue) -> FormulaValue {
            if a.isError { return a }
            if b.isError { return b }
            switch op {
            case "&": return .text(textValue(a) + textValue(b))
            case "=", "<>", "<", ">", "<=", ">=":
                let order = compare(a, b)
                switch op {
                case "=": return .bool(order == .orderedSame)
                case "<>": return .bool(order != .orderedSame)
                case "<": return .bool(order == .orderedAscending)
                case ">": return .bool(order == .orderedDescending)
                case "<=": return .bool(order != .orderedDescending)
                default: return .bool(order != .orderedAscending)
                }
            default:
                guard let x = numberValue(a), let y = numberValue(b) else { return .error("#VALUE!") }
                // A date plus or minus days is a date; one date minus another is days.
                let aDate = isDate(a), bDate = isDate(b)
                switch op {
                case "+": return aDate != bDate ? .date(x + y) : .number(x + y)
                case "-": return aDate && !bDate ? .date(x - y) : .number(x - y)
                case "*": return .number(x * y)
                case "/": return y == 0 ? .error("#DIV/0!") : .number(x / y)
                case "^":
                    let p = pow(x, y)
                    return p.isFinite ? .number(p) : .error("#NUM!")
                default: return .error("#VALUE!")
                }
            }
        }

        private func isDate(_ v: FormulaValue) -> Bool {
            if case .date = v { return true }
            if case .text(let s) = v { return Formula.number(from: s) == nil && Formula.dateSerial(from: s) != nil }
            return false
        }

        /// Excel's ordering: numbers before text before logical values; text ignores case.
        private func compare(_ a: FormulaValue, _ b: FormulaValue) -> ComparisonResult {
            func rank(_ v: FormulaValue) -> Int {
                switch v {
                case .number, .date, .empty: return 0
                case .text: return 1
                case .bool: return 2
                default: return 3
                }
            }
            var a = a, b = b
            if case .empty = a { if case .text = b { a = .text("") } else { a = .number(0) } }
            if case .empty = b { if case .text = a { b = .text("") } else { b = .number(0) } }
            if rank(a) != rank(b) { return rank(a) < rank(b) ? .orderedAscending : .orderedDescending }
            switch (a, b) {
            case (.number, _) where numberValue(b) != nil && rank(b) == 0, (.date, _) where numberValue(b) != nil && rank(b) == 0:
                let x = numberValue(a)!, y = numberValue(b)!
                return x == y ? .orderedSame : x < y ? .orderedAscending : .orderedDescending
            case (.bool(let x), .bool(let y)): return x == y ? .orderedSame : !x ? .orderedAscending : .orderedDescending
            default: return textValue(a).caseInsensitiveCompare(textValue(b))
            }
        }

        // MARK: Functions

        /// Numbers from the arguments: ranges give only their numbers; typed values are converted.
        private func numbers(_ args: [Node]) -> Result<[Double], FormulaValueError> {
            var result: [Double] = []
            for arg in args {
                let v = eval(arg)
                switch v {
                case .range(let values):
                    for item in values {
                        if item.isError, case .error(let e) = item { return .failure(FormulaValueError(e)) }
                        if case .number(let d) = item { result.append(d) }
                        if case .date(let d) = item { result.append(d) }
                    }
                case .error(let e): return .failure(FormulaValueError(e))
                default:
                    guard let d = numberValue(v) else { return .failure(FormulaValueError("#VALUE!")) }
                    result.append(d)
                }
            }
            return .success(result)
        }

        private func flat(_ args: [Node]) -> [FormulaValue] {
            args.flatMap { arg -> [FormulaValue] in
                let v = eval(arg)
                if case .range(let values) = v { return values }
                return [v]
            }
        }

        private func withNumbers(_ args: [Node], _ body: ([Double]) -> FormulaValue) -> FormulaValue {
            switch numbers(args) {
            case .success(let list): return body(list)
            case .failure(let e): return .error(e.code)
            }
        }

        private func arg(_ args: [Node], _ i: Int) -> FormulaValue { i < args.count ? single(eval(args[i])) : .empty }

        private func numberArg(_ args: [Node], _ i: Int) -> Result<Double, FormulaValueError> {
            let v = arg(args, i)
            if case .error(let e) = v { return .failure(FormulaValueError(e)) }
            guard let d = numberValue(v) else { return .failure(FormulaValueError("#VALUE!")) }
            return .success(d)
        }

        private func call(_ name: String, _ args: [Node]) -> FormulaValue {
            func need(_ range: ClosedRange<Int>) -> Bool { range.contains(args.count) }
            switch name {
            case "SUM":
                return withNumbers(args) { .number($0.reduce(0, +)) }
            case "AVERAGE":
                return withNumbers(args) { $0.isEmpty ? .error("#DIV/0!") : .number($0.reduce(0, +) / Double($0.count)) }
            case "MIN", "MAX":
                // The earliest / latest of dates is a date.
                let numeric = flat(args).filter { if case .number = $0 { return true }; if case .date = $0 { return true }; return false }
                let dates = !numeric.isEmpty && numeric.allSatisfy { if case .date = $0 { return true } else { return false } }
                return withNumbers(args) { list in
                    let v = (name == "MIN" ? list.min() : list.max()) ?? 0
                    return dates ? .date(v) : .number(v)
                }
            case "PRODUCT":
                return withNumbers(args) { .number($0.isEmpty ? 0 : $0.reduce(1, *)) }
            case "MEDIAN":
                return withNumbers(args) { list in
                    guard !list.isEmpty else { return .error("#NUM!") }
                    let s = list.sorted(), n = s.count
                    return .number(n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2)
                }
            case "COUNT":
                return .number(Double(flat(args).filter {
                    if case .number = $0 { return true }
                    if case .date = $0 { return true }
                    return false
                }.count))
            case "COUNTA":
                return .number(Double(flat(args).filter { $0 != .empty }.count))
            case "COUNTBLANK":
                return .number(Double(flat(args).filter { $0 == .empty || $0 == .text("") }.count))
            case "ABS", "SQRT", "INT", "EXP", "LN", "LOG10":
                guard need(1...1) else { return .error("#VALUE!") }
                switch numberArg(args, 0) {
                case .failure(let e): return .error(e.code)
                case .success(let x):
                    switch name {
                    case "ABS": return .number(abs(x))
                    case "SQRT": return x < 0 ? .error("#NUM!") : .number(x.squareRoot())
                    case "INT": return .number(x.rounded(.down))
                    case "EXP": return .number(exp(x))
                    case "LN": return x <= 0 ? .error("#NUM!") : .number(log(x))
                    default: return x <= 0 ? .error("#NUM!") : .number(log10(x))
                    }
                }
            case "ROUND", "ROUNDUP", "ROUNDDOWN":
                guard need(1...2) else { return .error("#VALUE!") }
                guard case .success(let x) = numberArg(args, 0) else { return .error("#VALUE!") }
                let digits = args.count > 1 ? (try? numberArg(args, 1).get()) ?? 0 : 0
                let scale = pow(10, digits.rounded(.towardZero))
                let rule: FloatingPointRoundingRule = name == "ROUND" ? .toNearestOrAwayFromZero
                    : name == "ROUNDUP" ? .awayFromZero : .towardZero
                return .number((x * scale).rounded(rule) / scale)
            case "MOD":
                guard need(2...2), case .success(let x) = numberArg(args, 0), case .success(let y) = numberArg(args, 1) else {
                    return .error("#VALUE!")
                }
                guard y != 0 else { return .error("#DIV/0!") }
                return .number(x - y * (x / y).rounded(.down))
            case "POWER":
                guard need(2...2), case .success(let x) = numberArg(args, 0), case .success(let y) = numberArg(args, 1) else {
                    return .error("#VALUE!")
                }
                let p = pow(x, y)
                return p.isFinite ? .number(p) : .error("#NUM!")
            case "PI":
                return .number(Double.pi)
            case "IF":
                guard need(2...3) else { return .error("#VALUE!") }
                let condition = arg(args, 0)
                if condition.isError { return condition }
                guard let t = truth(condition) else { return .error("#VALUE!") }
                if t { return single(eval(args[1])) }
                return args.count > 2 ? single(eval(args[2])) : .bool(false)
            case "IFERROR":
                guard need(2...2) else { return .error("#VALUE!") }
                let v = arg(args, 0)
                return v.isError ? arg(args, 1) : v
            case "AND", "OR":
                var values: [Bool] = []
                for v in flat(args) {
                    if v.isError { return v }
                    if case .text = v { continue }
                    if case .empty = v { continue }
                    if let t = truth(v) { values.append(t) }
                }
                guard !values.isEmpty else { return .error("#VALUE!") }
                return .bool(name == "AND" ? values.allSatisfy { $0 } : values.contains(true))
            case "NOT":
                guard need(1...1), let t = truth(arg(args, 0)) else { return .error("#VALUE!") }
                return .bool(!t)
            case "CONCAT", "CONCATENATE":
                var s = ""
                for v in flat(args) {
                    if v.isError { return v }
                    s += textValue(v)
                }
                return .text(s)
            case "LEN", "UPPER", "LOWER", "TRIM":
                guard need(1...1) else { return .error("#VALUE!") }
                let v = arg(args, 0)
                if v.isError { return v }
                let s = textValue(v)
                switch name {
                case "LEN": return .number(Double(s.count))
                case "UPPER": return .text(s.uppercased())
                case "LOWER": return .text(s.lowercased())
                default: return .text(s.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " "))
                }
            case "LEFT", "RIGHT":
                guard need(1...2) else { return .error("#VALUE!") }
                let s = textValue(arg(args, 0))
                let n = args.count > 1 ? Int((try? numberArg(args, 1).get()) ?? 1) : 1
                guard n >= 0 else { return .error("#VALUE!") }
                return .text(String(name == "LEFT" ? s.prefix(n) : s.suffix(n)))
            case "MID":
                guard need(3...3), case .success(let start) = numberArg(args, 1), case .success(let count) = numberArg(args, 2),
                      start >= 1, count >= 0 else { return .error("#VALUE!") }
                let s = Array(textValue(arg(args, 0)))
                let from = min(Int(start) - 1, s.count)
                return .text(String(s[from..<min(s.count, from + Int(count))]))
            case "SUMIF", "COUNTIF", "AVERAGEIF":
                guard need(name == "COUNTIF" ? 2...2 : 2...3) else { return .error("#VALUE!") }
                guard case .range(let tested) = eval(args[0]) else { return .error("#VALUE!") }
                let criterion = arg(args, 1)
                var summed = tested
                if args.count > 2, case .range(let other) = eval(args[2]) { summed = other }
                var total = 0.0, count = 0
                for (i, v) in tested.enumerated() where matches(v, criterion) {
                    count += 1
                    if i < summed.count, case .number(let d) = summed[i] { total += d }
                }
                switch name {
                case "COUNTIF": return .number(Double(count))
                case "SUMIF": return .number(total)
                default: return count == 0 ? .error("#DIV/0!") : .number(total / Double(count))
                }
            case "TODAY", "NOW":
                let now = Formula.serial(Date())
                return .date(name == "NOW" ? now : now.rounded(.down))
            case "DATE":
                guard need(3...3), case .success(let y) = numberArg(args, 0), case .success(let m) = numberArg(args, 1),
                      case .success(let d) = numberArg(args, 2),
                      let serial = Formula.serial(year: Int(y), month: Int(m), day: Int(d)) else { return .error("#VALUE!") }
                return .date(serial)
            case "YEAR", "MONTH", "DAY", "WEEKDAY":
                guard need(1...1), case .success(let serial) = numberArg(args, 0) else { return .error("#VALUE!") }
                let c = Formula.components(serial)
                switch name {
                case "YEAR": return .number(Double(c.year ?? 0))
                case "MONTH": return .number(Double(c.month ?? 0))
                case "DAY": return .number(Double(c.day ?? 0))
                default: return .number(Double(c.weekday ?? 0))
                }
            case "EDATE", "EOMONTH":
                guard need(2...2), case .success(let serial) = numberArg(args, 0), case .success(let months) = numberArg(args, 1) else {
                    return .error("#VALUE!")
                }
                let c = Formula.components(serial)
                let y = c.year ?? 1900, m = (c.month ?? 1) + Int(months)
                if name == "EDATE" {
                    // The same day, or the month's last day when it's shorter.
                    let last = Formula.serial(year: y, month: m + 1, day: 0).map { Formula.components($0).day ?? 28 } ?? 28
                    return Formula.serial(year: y, month: m, day: min(c.day ?? 1, last)).map(FormulaValue.date) ?? .error("#NUM!")
                }
                return Formula.serial(year: y, month: m + 1, day: 0).map(FormulaValue.date) ?? .error("#NUM!")
            case "DAYS":
                guard need(2...2), case .success(let end) = numberArg(args, 0), case .success(let start) = numberArg(args, 1) else {
                    return .error("#VALUE!")
                }
                return .number(end.rounded(.down) - start.rounded(.down))
            case "DATEDIF":
                guard need(3...3), case .success(let start) = numberArg(args, 0), case .success(let end) = numberArg(args, 1),
                      start <= end else { return .error("#NUM!") }
                let unit = textValue(arg(args, 2)).uppercased()
                let a = Formula.components(start), b = Formula.components(end)
                var months = ((b.year ?? 0) - (a.year ?? 0)) * 12 + (b.month ?? 0) - (a.month ?? 0)
                if (b.day ?? 0) < (a.day ?? 0) { months -= 1 }
                switch unit {
                case "D": return .number(end.rounded(.down) - start.rounded(.down))
                case "M": return .number(Double(months))
                case "Y": return .number(Double(months / 12))
                default: return .error("#NUM!")
                }
            default:
                return .error("#NAME?")
            }
        }

        /// COUNTIF-style criteria: ">5", "<=3", "<>x", "=x", "x" (text ignores case; * and ? are wildcards).
        private func matches(_ value: FormulaValue, _ criterion: FormulaValue) -> Bool {
            var op = "="
            var operand = criterion
            if case .text(let s) = criterion {
                for candidate in ["<=", ">=", "<>", "<", ">", "="] where s.hasPrefix(candidate) {
                    op = candidate
                    operand = Formula.value(ofText: String(s.dropFirst(candidate.count)))
                    break
                }
            }
            if case .text(let pattern) = operand, op == "=" || op == "<>", pattern.contains("*") || pattern.contains("?") {
                let regex = "^" + NSRegularExpression.escapedPattern(for: pattern)
                    .replacingOccurrences(of: "\\*", with: ".*").replacingOccurrences(of: "\\?", with: ".") + "$"
                let hit = textValue(value).range(of: regex, options: [.regularExpression, .caseInsensitive]) != nil
                return op == "=" ? hit : !hit
            }
            if case .empty = value, op == "=", case .text(let s) = operand, s.isEmpty { return true }
            if case .empty = value { return op == "<>" ? operand != .empty : false }
            if case .number = operand, numberValue(value) == nil { return op == "<>" }
            if case .number = operand, case .text = value { return op == "<>" }
            let order = compare(value, operand)
            switch op {
            case "=": return order == .orderedSame
            case "<>": return order != .orderedSame
            case "<": return order == .orderedAscending
            case ">": return order == .orderedDescending
            case "<=": return order != .orderedDescending
            default: return order != .orderedAscending
            }
        }
    }

    struct FormulaValueError: Error {
        let code: String
        init(_ code: String) { self.code = code }
    }

    // MARK: Rewriting references

    /// References after a row (axis .row) or column was inserted (+1) or removed (-1) at an index, as Excel moves them.
    static func shift(_ formula: String, rows: Bool, at index: Int, by delta: Int) -> String {
        guard isFormula(formula), let tokens = tokenize(String(formula.dropFirst())) else { return formula }
        let body = String(formula.dropFirst())
        var out = ""
        var cursor = body.startIndex
        var k = 0
        func moved(_ ref: Ref, isEnd: Bool, partnerRemoved: Bool) -> Ref? {
            var r = ref
            let value = rows ? r.row : r.column
            var newValue = value
            if delta > 0 {
                if value >= index { newValue += delta }
            } else {
                if value > index { newValue -= 1 }
                else if value == index {
                    // A single reference to the removed row is lost; a range just gets smaller.
                    if partnerRemoved { return nil }
                    if isEnd { newValue -= 1 }
                }
            }
            if rows { r.row = newValue } else { r.column = newValue }
            return (rows ? r.row : r.column) >= 0 ? r : nil
        }
        while k < tokens.count {
            let (token, range) = tokens[k]
            guard case .ref(let text) = token, let ref = parseRef(text) else { k += 1; continue }
            out += body[cursor..<range.lowerBound]
            // A range A1:B5 moves its two ends separately.
            if k + 2 < tokens.count, tokens[k + 1].token == .colon, case .ref(let endText) = tokens[k + 2].token,
               let end = parseRef(endText) {
                let lowFirst = (rows ? ref.row : ref.column) <= (rows ? end.row : end.column)
                let lo = lowFirst ? ref : end, hi = lowFirst ? end : ref
                let both = (rows ? lo.row : lo.column) == index && (rows ? hi.row : hi.column) == index
                if let a = moved(lo, isEnd: false, partnerRemoved: both), let b = moved(hi, isEnd: true, partnerRemoved: both),
                   (rows ? b.row : b.column) >= (rows ? a.row : a.column) {
                    out += a.text + ":" + b.text
                } else {
                    out += "#REF!"
                }
                cursor = tokens[k + 2].range.upperBound
                k += 3
                continue
            }
            out += moved(ref, isEnd: false, partnerRemoved: true)?.text ?? "#REF!"
            cursor = range.upperBound
            k += 1
        }
        out += body[cursor...]
        return "=" + out
    }

    /// A formula moved to another row (sorting, moving rows): its relative row references move with it, as when
    /// Excel sorts; $-anchored rows stay.
    static func offset(_ formula: String, rows delta: Int, columns across: Int = 0) -> String {
        guard delta != 0 || across != 0, isFormula(formula), let tokens = tokenize(String(formula.dropFirst())) else { return formula }
        let body = String(formula.dropFirst())
        var out = ""
        var cursor = body.startIndex
        for (token, range) in tokens {
            guard case .ref(let text) = token, var ref = parseRef(text) else { continue }
            out += body[cursor..<range.lowerBound]
            if !ref.absoluteRow { ref.row += delta }
            if !ref.absoluteColumn { ref.column += across }
            out += ref.row >= 0 && ref.column >= 0 ? ref.text : "#REF!"
            cursor = range.upperBound
        }
        out += body[cursor...]
        return "=" + out
    }

    /// Functions offered in the Formulas menu (name, description).
    static let menuFunctions: [(String, String)] = [
        ("SUM", "Adds numbers"), ("AVERAGE", "Average of numbers"), ("COUNT", "Counts numbers"),
        ("COUNTA", "Counts filled cells"), ("MIN", "Smallest number"), ("MAX", "Largest number"),
        ("ROUND", "Rounds to digits"), ("IF", "Chooses by a condition"), ("SUMIF", "Adds where a condition holds"),
        ("COUNTIF", "Counts where a condition holds"), ("AVERAGEIF", "Averages where a condition holds"),
        ("IFERROR", "A value instead of an error"), ("CONCAT", "Joins text"), ("MEDIAN", "Middle number"),
        ("PRODUCT", "Multiplies numbers"), ("ABS", "Absolute value"), ("TODAY", "Today's date"),
        ("DATE", "A date from year, month, day"), ("EDATE", "A date months later"), ("DATEDIF", "Days, months or years between"),
    ]
}
