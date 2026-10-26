//
//  SpendingModel.swift
//  MxAcctMGR
//
//  Reporting ▸ Spending Analysis: household spending attribution, kept in the security master (accounts service
//  /spending, V037). Every dollar the registers and expense ledgers spend has two dimensions — a spending category
//  (Food, Housing, Transportation …) and a primary driver (inflation, family growth, a new activity, a lifecycle
//  transition, a preference change, a one-time event) — set by rules on expense and target accounts and by tags on
//  single entries. Like portfolio attribution, a category's change from one year to the next splits into effects:
//
//      change = inflation + usage + lifecycle + behavior + one-time
//
//  Inflation is the prior year's spending times the category's CPI change (FRED, in the security master; else the
//  category's assumption) plus whatever spending tagged "inflation" grew beyond it; each other driver's effect is what
//  its spending grew beyond inflation. The children's ages drive the forward curve: what each lifecycle trigger costs
//  in the years a child is of age for it, ten years ahead.
//

import SwiftUI

// MARK: - Model

/// What a dollar is spent on, with the CPI series its inflation follows.
struct SpendingCategory: Decodable, Identifiable, Hashable {
    var code: String
    var name: String
    var cpiSeries: String?
    var cpiName: String?
    var assumedInflation: Double
    var sortOrder: Int
    var cpiThrough: String?
    var id: String { code }
}

/// A family member; children's birth years drive the lifecycle model.
struct HouseholdMember: Decodable, Identifiable, Hashable {
    var id: Int
    var name: String
    var relation: String
    var birthYear: Int
    var birthMonth: Int?
    var notes: String?
    var active: Bool
    var version: Int
    var isChild: Bool { relation == "child" }
    func age(in year: Int) -> Int { year - birthYear }
}

/// An expense account's or a target account's category, driver and member.
struct SpendingRule: Decodable, Identifiable, Hashable {
    var id: Int
    var expenseAccountId: Int?
    var expenseAccount: String?
    var payeeId: Int?
    var payee: String?
    var category: String?
    var driver: String?
    var memberId: Int?
    var notes: String?
    var updatedBy: String?
}

/// What a child's age brings and costs a year, in today's dollars.
struct LifecycleTrigger: Decodable, Identifiable, Hashable {
    var id: Int
    var name: String
    var category: String
    var kind: String
    var ageFrom: Int
    var ageTo: Int
    var everyYears: Int?
    var annualCost: Double
    var notes: String?
    var active: Bool

    /// It costs something in the year a child is this old.
    func applies(at age: Int) -> Bool {
        guard active, age >= ageFrom, age <= ageTo else { return false }
        if let n = everyYears, n > 1 { return (age - ageFrom) % n == 0 }
        return true
    }

    var ages: String {
        let span = ageFrom == ageTo ? "\(ageFrom)" : "\(ageFrom)–\(ageTo)"
        if let n = everyYears, n > 1 { return "\(span), every \(n) years" }
        return span
    }
}

struct SpendingSetup: Decodable {
    struct Named: Decodable, Identifiable, Hashable { var id: Int; var name: String; var expenseAccountId: Int? }
    struct Series: Decodable, Identifiable, Hashable { var code: String; var name: String; var id: String { code } }
    var members: [HouseholdMember]
    var categories: [SpendingCategory]
    var rules: [SpendingRule]
    var triggers: [LifecycleTrigger]
    var expenseAccounts: [Named]
    var payees: [Named]
    var cpiSeries: [Series]

    func category(_ code: String?) -> SpendingCategory? { categories.first { $0.code == code } }
    func member(_ id: Int?) -> HouseholdMember? { members.first { $0.id == id } }
    var children: [HouseholdMember] { members.filter { $0.isChild && $0.active } }
    func rule(expenseAccount id: Int) -> SpendingRule? { rules.first { $0.expenseAccountId == id } }
    func rule(payee id: Int) -> SpendingRule? { rules.first { $0.payeeId == id } }
}

/// One spending dollar's entry: a check, a card charge or credit, or an expense-ledger item, positive when spent.
struct SpendingEntry: Decodable, Identifiable, Hashable {
    var source: String
    var entryId: Int
    var date: String
    var register: String?
    var payeeId: Int?
    var payee: String?
    var description: String?
    var expenseAccountId: Int?
    var expenseAccount: String?
    var amount: Double
    var category: String?
    /// Where the category came from: entry, target account or expense account.
    var categoryFrom: String?
    var driver: String?
    var driverFrom: String?
    var memberId: Int?
    var event: String?
    var notes: String?
    var tagged: Bool
    var id: String { "\(source)-\(entryId)" }
    var sourceTitle: String { source == "bank" ? "Checking" : source == "card" ? "Card" : "Expense ledger" }
}

/// A category's price change between the periods: CPI months, else its assumption.
struct CategoryInflation: Decodable, Hashable {
    var category: String
    var series: String?
    var assumed: Double
    var rate: Double
    var basis: String
    var months: Int
    var through: String?
}

/// The dates a register's spending covers.
struct RegisterCoverage: Decodable, Hashable, Identifiable {
    var source: String
    var register: String?
    var first: String
    var last: String
    var entries: Int
    var id: String { source + (register ?? "") }
}

struct SpendingAnalysisData: Decodable {
    var start: String
    var end: String
    var priorStart: String
    var priorEnd: String
    var entries: [SpendingEntry]
    var inflation: [CategoryInflation]
    var coverage: [RegisterCoverage]
}

enum SpendingDriver: String, CaseIterable, Identifiable {
    case inflation, familyGrowth = "family_growth", newActivity = "new_activity", lifecycle, preference, oneTime = "one_time"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .inflation: "Inflation"
        case .familyGrowth: "Family Growth"
        case .newActivity: "New Activity"
        case .lifecycle: "Lifecycle Transition"
        case .preference: "Preference Change"
        case .oneTime: "One-Time Event"
        }
    }

    var help: String {
        switch self {
        case .inflation: "The same thing costs more"
        case .familyGrowth: "More people, more of the same things"
        case .newActivity: "Something the family didn't do before"
        case .lifecycle: "Expected age-related spending: tutors, driving, college"
        case .preference: "A habit or taste changed: eating out more, a better brand"
        case .oneTime: "An event that won't repeat: Philmont, a wedding, a repair"
        }
    }

    /// The attribution effect its spending's growth counts toward.
    var effect: SpendingEffect {
        switch self {
        case .inflation: .inflation
        case .familyGrowth, .newActivity: .usage
        case .lifecycle: .lifecycle
        case .preference: .behavior
        case .oneTime: .oneTime
        }
    }

    static func title(_ raw: String?) -> String { raw.flatMap(SpendingDriver.init(rawValue:))?.title ?? "Not assigned" }
}

/// The attribution formula's terms: change = inflation + usage + lifecycle + behavior + one-time.
enum SpendingEffect: String, CaseIterable, Identifiable {
    case inflation = "Inflation", usage = "Usage", lifecycle = "Lifecycle", behavior = "Behavior", oneTime = "One-Time"
    var id: String { rawValue }

    var color: Color {
        switch self {
        case .inflation: .orange
        case .usage: .blue
        case .lifecycle: .purple
        case .behavior: .pink
        case .oneTime: .teal
        }
    }

    var help: String {
        switch self {
        case .inflation: "Prices: last year's spending times the category's CPI change, plus what spending tagged Inflation grew beyond it"
        case .usage: "More (or less) of the same: family growth, new activities, and spending with no driver assigned"
        case .lifecycle: "Expected age-related costs: the growth of spending tagged Lifecycle Transition, beyond inflation"
        case .behavior: "Habits and tastes: the growth of spending tagged Preference Change, beyond inflation"
        case .oneTime: "Events that won't repeat: the growth of spending tagged One-Time Event, beyond inflation"
        }
    }
}

// MARK: - Attribution

/// A category's spending in both periods and its change split into effects.
struct CategoryAttribution: Identifiable, Hashable {
    var code: String
    var name: String
    var prior: Double
    var current: Double
    var inflationRate: Double
    var basis: String
    var effects: [SpendingEffect: Double]
    var id: String { code }

    var change: Double { current - prior }
    var growth: Double? { prior > 0.005 ? change / prior : nil }
    func effect(_ e: SpendingEffect) -> Double { effects[e] ?? 0 }
    /// The effect's share of the change (they add to 100%); none when nothing changed.
    func share(_ e: SpendingEffect) -> Double? { abs(change) > 0.5 ? effect(e) / change : nil }

    /// Whether the increase is mostly unavoidable (prices, age) or mostly a habit or an event.
    var reading: String {
        guard change > 0.5 else { return change < -0.5 ? "Spending fell" : "Unchanged" }
        let unavoidable = (share(.inflation) ?? 0) + (share(.lifecycle) ?? 0)
        if unavoidable >= 0.6 { return (share(.lifecycle) ?? 0) > (share(.inflation) ?? 0) ? "Unavoidable: age-related" : "Unavoidable: prices" }
        if (share(.behavior) ?? 0) >= 0.5 { return "Habit change" }
        if (share(.oneTime) ?? 0) >= 0.5 { return "One-time" }
        if (share(.usage) ?? 0) >= 0.5 { return "More of the same" }
        return "Mixed"
    }
}

enum SpendingEngine {
    static let unassigned = "UNASSIGNED"

    /// Each category's attribution (and Not assigned's, when it has spending), in the categories' order.
    static func attribute(_ data: SpendingAnalysisData, entries: [SpendingEntry], categories: [SpendingCategory]) -> [CategoryAttribution] {
        let rates = Dictionary(data.inflation.map { ($0.category, $0) }, uniquingKeysWith: { a, _ in a })
        var prior: [String: [String: Double]] = [:], current: [String: [String: Double]] = [:]
        for e in entries {
            let c = e.category ?? unassigned, d = e.driver ?? ""
            if e.date >= data.start && e.date <= data.end { current[c, default: [:]][d, default: 0] += e.amount }
            else if e.date >= data.priorStart && e.date <= data.priorEnd { prior[c, default: [:]][d, default: 0] += e.amount }
        }
        var codes = categories.map { ($0.code, $0.name) }
        if prior[unassigned] != nil || current[unassigned] != nil { codes.append((unassigned, "Not assigned")) }
        return codes.compactMap { code, name in
            let p = prior[code] ?? [:], c = current[code] ?? [:]
            guard !p.isEmpty || !c.isEmpty else { return nil }
            let inf = rates[code] ?? rates["OTHER"]
            let rate = inf?.rate ?? 0.03
            let priorTotal = p.values.reduce(0, +)
            var effects: [SpendingEffect: Double] = [.inflation: priorTotal * rate]
            for d in Set(p.keys).union(c.keys) {
                let grew = (c[d] ?? 0) - (p[d] ?? 0) * (1 + rate)
                effects[SpendingDriver(rawValue: d)?.effect ?? .usage, default: 0] += grew
            }
            return CategoryAttribution(code: code, name: name, prior: priorTotal, current: c.values.reduce(0, +),
                                       inflationRate: rate, basis: inf?.basis ?? "assumed", effects: effects)
        }
    }

    /// The categories together.
    static func total(_ rows: [CategoryAttribution]) -> CategoryAttribution {
        var effects: [SpendingEffect: Double] = [:]
        for r in rows { for (e, v) in r.effects { effects[e, default: 0] += v } }
        let prior = rows.map(\.prior).reduce(0, +)
        return CategoryAttribution(code: "TOTAL", name: "All spending", prior: prior, current: rows.map(\.current).reduce(0, +),
                                   inflationRate: prior > 0 ? (effects[.inflation] ?? 0) / prior : 0, basis: "", effects: effects)
    }

    /// The registers whose spending starts after the prior period does (a month's grace): comparing them would count
    /// their whole current spending as growth.
    static func partialRegisters(_ data: SpendingAnalysisData) -> [RegisterCoverage] {
        guard let start = isoDay.date(from: data.priorStart) else { return [] }
        let grace = Calendar.current.date(byAdding: .day, value: 31, to: start) ?? start
        return data.coverage.filter { (isoDay.date(from: String($0.first.prefix(10))) ?? .distantPast) > grace }
    }

    // MARK: Forward curve

    /// What one trigger costs one child in one year.
    struct CurvePoint: Identifiable, Hashable {
        var year: Int
        var member: String
        var age: Int
        var category: String
        var trigger: String
        var kind: String
        var amount: Double
        var id: String { "\(year)-\(member)-\(trigger)" }
    }

    /// Each child's lifecycle costs for `years` years from `start`: a trigger costs its annual amount in each year
    /// the child is of age for it (a replacement once every n years), grown by its category's inflation when
    /// `inflate` — except peak events, which distance and participation drive, not prices.
    static func forwardCurve(children: [HouseholdMember], triggers: [LifecycleTrigger], rates: [String: Double],
                             start: Int, years: Int = 10, inflate: Bool) -> [CurvePoint] {
        var out: [CurvePoint] = []
        for year in start..<(start + years) {
            for child in children {
                let age = child.age(in: year)
                for t in triggers where t.applies(at: age) {
                    let grow = inflate && t.kind != "peak" ? pow(1 + (rates[t.category] ?? 0.03), Double(year - start)) : 1
                    out.append(CurvePoint(year: year, member: child.name, age: age, category: t.category, trigger: t.name,
                                          kind: t.kind, amount: t.annualCost * grow))
                }
            }
        }
        return out
    }

    /// The years whose lifecycle cost rises most over the year before: the waves to plan for.
    static func waves(_ points: [CurvePoint], start: Int, years: Int = 10) -> [(year: Int, total: Double, rise: Double, starting: [String])] {
        let byYear = Dictionary(grouping: points, by: \.year)
        var out: [(year: Int, total: Double, rise: Double, starting: [String])] = []
        for year in (start + 1)..<(start + years) {
            let now = byYear[year] ?? [], before = byYear[year - 1] ?? []
            let total = now.map(\.amount).reduce(0, +), rise = total - before.map(\.amount).reduce(0, +)
            let had = Set(before.map { $0.member + "|" + $0.trigger })
            let starting = now.filter { !had.contains($0.member + "|" + $0.trigger) }.map { "\($0.member): \($0.trigger)" }
            out.append((year, total, rise, starting))
        }
        return out.filter { $0.rise > 0 }.sorted { $0.rise > $1.rise }
    }
}

// MARK: - Client

nonisolated enum SpendingClient {
    private static func signed(_ body: [String: Any]) -> [String: Any] { body.merging(["by": BankClient.by]) { a, _ in a } }
    struct TagAnswer: Decodable { var entry: SpendingEntry? }

    static func setup() async throws -> SpendingSetup {
        try await AccountsClient.request("GET", "/spending/setup", as: SpendingSetup.self)
    }
    static func analysis(start: String, end: String, priorStart: String, priorEnd: String) async throws -> SpendingAnalysisData {
        try await AccountsClient.request("GET", "/spending/analysis?start=\(start)&end=\(end)&priorStart=\(priorStart)&priorEnd=\(priorEnd)",
                                         as: SpendingAnalysisData.self)
    }
    static func saveMember(_ id: Int, _ body: [String: Any]) async throws -> SpendingSetup {
        try await AccountsClient.request("PUT", "/spending/members/\(id)", body: signed(body), as: SpendingSetup.self)
    }
    static func deleteMember(_ id: Int) async throws -> SpendingSetup {
        try await AccountsClient.request("DELETE", "/spending/members/\(id)", as: SpendingSetup.self)
    }
    static func saveCategory(_ code: String, _ body: [String: Any]) async throws -> SpendingSetup {
        try await AccountsClient.request("PUT", "/spending/categories/\(code)", body: signed(body), as: SpendingSetup.self)
    }
    static func saveRule(_ body: [String: Any]) async throws -> SpendingSetup {
        try await AccountsClient.request("PUT", "/spending/rules", body: signed(body), as: SpendingSetup.self)
    }
    static func saveTrigger(_ id: Int, _ body: [String: Any]) async throws -> SpendingSetup {
        try await AccountsClient.request("PUT", "/spending/triggers/\(id)", body: signed(body), as: SpendingSetup.self)
    }
    static func deleteTrigger(_ id: Int) async throws -> SpendingSetup {
        try await AccountsClient.request("DELETE", "/spending/triggers/\(id)", as: SpendingSetup.self)
    }
    static func tag(_ entry: SpendingEntry, _ body: [String: Any]) async throws -> SpendingEntry? {
        try await AccountsClient.request("PUT", "/spending/tags/\(entry.source)/\(entry.entryId)", body: signed(body), as: TagAnswer.self).entry
    }
}
