//
//  TableFillSeries.swift
//  MxNoteONE
//
//  What Excel's fill handle continues: numbers (1, 2 → 3, 4; uneven ones
//  along their best-fit line), dates (a single date by the day, 1/15 and
//  2/15 by the month), month and day names, quarters (Q4 → Q1), and text
//  with a number in it (Item 1 → Item 2, A09 → A10, 1st → 2nd).
//

import Foundation

enum FillSeries {
    enum Level {
        /// Copies: Fill Down, Fill Right, Copy Cells.
        case none
        /// As the fill handle does: a single number is copied, everything else that can continue does.
        case automatic
        /// Fill Series: a single number counts up too.
        case all
    }

    /// The text of the cells past the sources (0 = the first one past them), or nil when the sources just repeat.
    /// `texts` and `values` are the source cells in the order the fill runs (reversed when filling up or left);
    /// `backward` is that direction, which is all a single source has to go by (Mon filled up gives Sun).
    static func continuation(of texts: [String], values: [FormulaValue], level: Level, backward: Bool = false) -> ((Int) -> String)? {
        guard level != .none, !texts.isEmpty, texts.count == values.count, !texts.contains(where: Formula.isFormula) else { return nil }
        let single = backward ? -1 : 1
        let numbers = values.compactMap { v -> Double? in
            if case .number(let d) = v { return d }
            return nil
        }
        if numbers.count == values.count { return continuing(numbers: numbers, level: level, single: single) }
        let dates = values.compactMap { v -> Double? in
            if case .date(let d) = v { return d }
            return nil
        }
        if dates.count == values.count { return continuing(dates: dates, typed: texts, single: single) }
        return continuing(names: texts, single: single) ?? continuing(quarters: texts, single: single) ?? continuing(numbered: texts, single: single)
    }

    // MARK: Numbers and dates

    /// The best-fit line through the values (evenly spaced ones lie on it), at the given position past the first.
    private static func line(_ values: [Double]) -> (Int) -> Double {
        let n = Double(values.count)
        let meanX = (n - 1) / 2
        let meanY = values.reduce(0, +) / n
        var top = 0.0, bottom = 0.0
        for (i, y) in values.enumerated() {
            top += (Double(i) - meanX) * (y - meanY)
            bottom += (Double(i) - meanX) * (Double(i) - meanX)
        }
        let slope = top / bottom
        return { meanY + slope * (Double($0) - meanX) }
    }

    private static func continuing(numbers: [Double], level: Level, single: Int) -> ((Int) -> String)? {
        if numbers.count == 1 {
            guard level == .all else { return nil }
            return { Formula.format(numbers[0] + Double(single * ($0 + 1))) }
        }
        let fit = line(numbers)
        return { Formula.format(fit(numbers.count + $0)) }
    }

    private static func continuing(dates: [Double], typed: [String], single: Int) -> (Int) -> String {
        // New dates are written the way the last source was.
        let pattern = typed.last.flatMap(Formula.datePattern)
        let show: (Double) -> String = { serial in pattern.map { Formula.formatDate(serial, pattern: $0) } ?? Formula.generalDate(serial) }
        if dates.count == 1 {
            // A single date goes by the day; a time alone by the hour.
            let step = dates[0] < 1 ? 1.0 / 24 : 1
            return { show(dates[0] + step * Double(single * ($0 + 1))) }
        }
        if let months = monthlyStep(dates) {
            return { show(Formula.addingMonths(months * (dates.count + $0), to: dates[0])) }
        }
        let fit = line(dates)
        return { show(fit(dates.count + $0)) }
    }

    /// The months between the dates, when they fall on one day of the month and are evenly spaced in months.
    private static func monthlyStep(_ dates: [Double]) -> Int? {
        let parts = dates.map { Formula.components($0) }
        guard dates.allSatisfy({ $0 == $0.rounded(.down) }), Set(parts.map(\.day)).count == 1 else { return nil }
        let months = parts.compactMap { p in p.year.flatMap { y in p.month.map { y * 12 + $0 } } }
        guard months.count == dates.count else { return nil }
        let step = months[1] - months[0]
        guard step != 0, zip(months, months.dropFirst()).allSatisfy({ $1 - $0 == step }) else { return nil }
        return step
    }

    // MARK: Text

    /// Short lists first: "May" alone goes on to "Jun", and "April, May" to "June".
    private static let nameLists: [[String]] = [
        ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"],
        ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"],
        ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"],
        ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"],
    ]

    /// The even step through a cycle or line of positions; `single` for a single source, nil when uneven or still.
    private static func step(_ positions: [Int], single: Int, cycle: Int? = nil) -> Int? {
        guard positions.count > 1 else { return single }
        let wrap: (Int) -> Int = { d in cycle.map { ((d % $0) + $0) % $0 } ?? d }
        let first = wrap(positions[1] - positions[0])
        guard first != 0, zip(positions, positions.dropFirst()).allSatisfy({ wrap($1 - $0) == first }) else { return nil }
        return first
    }

    private static func continuing(names texts: [String], single: Int) -> ((Int) -> String)? {
        let trimmed = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        for list in nameLists {
            let lower = list.map { $0.lowercased() }
            let positions = trimmed.compactMap { lower.firstIndex(of: $0) }
            guard positions.count == texts.count, let step = step(positions, single: single, cycle: list.count), let last = texts.last else { continue }
            // JAN → FEB, jan → feb, Jan → Feb.
            let shape: (String) -> String = last == last.uppercased() ? { $0.uppercased() } : last == last.lowercased() ? { $0.lowercased() } : { $0 }
            return { shape(list[((positions.last! + step * ($0 + 1)) % list.count + list.count) % list.count]) }
        }
        return nil
    }

    /// Q1, Qtr 2, Quarter 3, with or without a year: Q4 goes on to Q1 (of the next year, if it has one).
    private static func continuing(quarters texts: [String], single: Int) -> ((Int) -> String)? {
        guard let regex = try? NSRegularExpression(pattern: "^(q|qtr ?|quarter ?)([1-4])( \\d{4})?$", options: .caseInsensitive) else { return nil }
        var parts: [(prefix: String, position: Int, hasYear: Bool)] = []
        for text in texts {
            let ns = text as NSString
            guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
            let year = m.range(at: 3).location == NSNotFound ? nil : Int(ns.substring(with: m.range(at: 3)).dropFirst())
            parts.append((ns.substring(with: m.range(at: 1)), (year ?? 0) * 4 + (Int(ns.substring(with: m.range(at: 2))) ?? 1) - 1, year != nil))
        }
        guard let last = parts.last, parts.allSatisfy({ $0.prefix == last.prefix && $0.hasYear == last.hasYear }),
              let step = step(parts.map(\.position), single: single, cycle: last.hasYear ? nil : 4) else { return nil }
        return { n in
            let position = last.position + step * (n + 1)
            let quarter = ((position % 4) + 4) % 4 + 1
            return last.hasYear ? "\(last.prefix)\(quarter) \(Int((Double(position) / 4).rounded(.down)))" : "\(last.prefix)\(quarter)"
        }
    }

    /// Text with a number in it: the last number counts, as in Excel (Item 1 → Item 2, 1st → 2nd, A09 → A10).
    private static func continuing(numbered texts: [String], single: Int) -> ((Int) -> String)? {
        var parts: [(prefix: String, digits: String, suffix: String)] = []
        for text in texts {
            guard let end = text.lastIndex(where: isDigit) else { return nil }
            var start = end
            while start > text.startIndex, isDigit(text[text.index(before: start)]) { start = text.index(before: start) }
            parts.append((String(text[..<start]), String(text[start...end]), String(text[text.index(after: end)...])))
        }
        guard let last = parts.last, parts.allSatisfy({ $0.prefix == last.prefix && $0.suffix == last.suffix && $0.digits.count <= 15 }) else { return nil }
        let numbers = parts.compactMap { Int($0.digits) }
        guard numbers.count == parts.count, let step = step(numbers, single: single) else { return nil }
        let padded = parts.contains { $0.digits.count > 1 && $0.digits.hasPrefix("0") }
        let ordinal = last.prefix.isEmpty && ["st", "nd", "rd", "th"].contains(last.suffix)
        return { n in
            let number = abs(numbers.last! + step * (n + 1))
            var digits = String(number)
            if padded, digits.count < last.digits.count { digits = String(repeating: "0", count: last.digits.count - digits.count) + digits }
            return last.prefix + digits + (ordinal ? ordinalSuffix(number) : last.suffix)
        }
    }

    private static func isDigit(_ c: Character) -> Bool { c.isASCII && c.isNumber }

    private static func ordinalSuffix(_ n: Int) -> String {
        if (11...13).contains(n % 100) { return "th" }
        switch n % 10 {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
    }
}
