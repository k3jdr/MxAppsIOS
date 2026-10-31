//
//  SpendingModel.swift
//  MxAcctMGR
//
//  Banking ▸ Spending Analysis: household spending attribution, kept in the security master (accounts service
//  /spending, V037). Every dollar the registers and cash ledgers spend has two dimensions — a spending category
//  (Food, Housing, Transportation …) and a primary driver (inflation, family growth, a new activity, a lifecycle
//  transition, a preference change, a one-time event) — allocated on target accounts (V052) and by tags on
//  single entries. Like portfolio attribution, a category's change from one year to the next splits into effects:
//
//      change = inflation + usage + lifecycle + behavior + one-time + taxes
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
    /// What it covers (V047).
    var description: String?
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
    struct Named: Decodable, Identifiable, Hashable {
        var id: Int
        var name: String
        var expenseAccountId: Int?
        /// An expense account's description.
        var description: String?
        // A target account's spending role and allocation (V052): spending, transfer or income; the category, driver
        // and family member its spending goes to; the statement names it matches.
        var role: String?
        var category: String?
        var driver: String?
        var memberId: Int?
        var patterns: [String]?
        var bankNames: [String]?
        // A target account's details and link (srm.payee_link, V032), for its name's hover text.
        var institution: String?
        var last4: String?
        var logonUrl: String?
        var nickname: String?
        var notes: String?
        var link: TargetLink?
    }
    struct Series: Decodable, Identifiable, Hashable { var code: String; var name: String; var id: String { code } }
    var members: [HouseholdMember]
    var categories: [SpendingCategory]
    var triggers: [LifecycleTrigger]
    var expenseAccounts: [Named]
    var payees: [Named]
    var cpiSeries: [Series]
    /// Why spending changed, in their order (srm.spending_driver, V047; changed on Admin).
    var drivers: [SpendingDriver]

    func category(_ code: String?) -> SpendingCategory? { categories.first { $0.code == code } }
    func driver(_ code: String?) -> SpendingDriver? { drivers.first { $0.code == code } }
    /// A driver's title; Not assigned for none (or one taken off since the entry was read).
    func driverTitle(_ code: String?) -> String { driver(code)?.title ?? "Not assigned" }
    func member(_ id: Int?) -> HouseholdMember? { members.first { $0.id == id } }
    var children: [HouseholdMember] { members.filter { $0.isChild && $0.active } }
    func payee(_ id: Int?) -> Named? { payees.first { $0.id == id } }
    /// What a target account's allocation says, in words: "Food · Family Growth · Ann"; nil when it says nothing.
    func allocation(_ p: Named) -> String? {
        let parts = [category(p.category)?.name, p.driver.map { driverTitle($0) }, member(p.memberId)?.name].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// One spending dollar's entry: a check, a card charge or credit, or a cash-ledger item, positive when spent.
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
    /// Where the category came from: entry, target account, statement text or expense account.
    var categoryFrom: String?
    var driver: String?
    var driverFrom: String?
    var memberId: Int?
    var event: String?
    var notes: String?
    var tagged: Bool
    /// The statement text rule it matches (V042), the longest when several do.
    var rulePattern: String?
    /// An Amazon charge or credit matched to its orders (V046): the order numbers and what was bought.
    var amazonOrders: String?
    var amazonItems: [AmazonItem]?
    /// amazon-orders (the export, by amount and date), amazon-email (Amazon's order e-mails, by amount and date, V055)
    /// or amazon-lookup (Amazon's own Transactions list).
    var amazonMatchedBy: String?
    /// An Apple charge or credit matched to its bills (V056): the order IDs and what was bought.
    var appleOrders: String?
    var appleItems: [AppleItem]?
    /// The card's or bank's own name for it: "APPLE.COM/BILL 866-712-7753 CA".
    var statementName: String?
    var id: String { "\(source)-\(entryId)" }

    /// What an Amazon or Apple charge bought, in a line: "Kids' Swim Goggles, 3 Pack and 1 more".
    var bought: String? {
        if let items = appleItems, let first = items.first, amazonItems == nil {
            return items.count == 1 ? first.label : "\(first.label) and \(items.count - 1) more"
        }
        guard let items = amazonItems, let first = items.first else { return nil }
        return items.count == 1 ? first.label : "\(first.label) and \(items.count - 1) more"
    }
    /// Every item with its cost, and the orders: hover text.
    var boughtDetail: String? {
        if let items = appleItems, !items.isEmpty, amazonItems == nil {
            let lines = items.map { i in i.amount.map { "\(i.label) — \(money2($0))" } ?? i.label }
            return (amount < 0 ? "Refunded:\n" : "Bought:\n") + lines.joined(separator: "\n")
                + "\nApple order\(appleOrderIds.count == 1 ? "" : "s") " + appleOrderIds.joined(separator: ", ")
                + " — from your Apple Account's purchase history"
        }
        guard let items = amazonItems, !items.isEmpty else { return nil }
        let lines = items.map { i in i.amount.map { "\(i.label) — \(money2($0))" } ?? i.label }
        let orders = Array(Set(items.map(\.orderId))).sorted()
        return (amount < 0 ? "Refunded:\n" : "Bought:\n") + lines.joined(separator: "\n")
            + "\nAmazon order\(orders.count == 1 ? "" : "s") " + orders.joined(separator: ", ")
            + (amazonMatchedBy == "amazon-lookup" ? " — from Amazon's Transactions list"
               : amazonMatchedBy == "amazon-email" ? " — from Amazon's order e-mails, matched by amount and date"
               : amazonMatchedBy == "amazon-orders" ? " — matched by amount and date" : "")
    }
    var amazonOrderIds: [String] { Array(Set((amazonItems ?? []).map(\.orderId))).sorted() }
    var appleOrderIds: [String] { Array(Set((appleItems ?? []).map(\.orderId))).sorted() }

    /// An Apple charge or credit (APPLE.COM/BILL): the App Store, a subscription, iCloud+, Apple TV — what the Apple
    /// Purchase Lookup looks up; not APPLE.COM/US, the Apple Store's hardware.
    var isAppleCharge: Bool {
        guard source != "ledger" else { return false }
        let text = [statementName, payee, description].compactMap { $0 }.joined(separator: " ").lowercased()
        return ["apple.com/bill", "itunes.com", "apple services"].contains { text.contains($0) }
    }

    /// A Prime Video charge (a rental, a purchase, a channel), a Kindle book or another Amazon digital charge: its order
    /// (D01-…) is on Amazon's Transactions list and Digital Orders, never in the order export.
    var isAmazonDigitalCharge: Bool {
        guard source != "ledger" else { return false }
        let text = [payee, description].compactMap { $0 }.joined(separator: " ").lowercased()
        return ["prime video", "primevideo", "amazon prime", "kindle", "amazon digital", "amzn digital"].contains { text.contains($0) }
    }
    /// What the Amazon Order Lookup looks up: an order charge or a digital one.
    var isAmazonLookupCharge: Bool { isAmazonOrderCharge || isAmazonDigitalCharge }

    /// A card charge or checking debit (or credit) from Amazon for an order: not a membership, video, e-book, audiobook or
    /// AWS bill (as the amazon-orders loader tells them).
    var isAmazonOrderCharge: Bool {
        guard source != "ledger" else { return false }
        let text = [payee, description].compactMap { $0 }.joined(separator: " ").lowercased()
        return (text.contains("amazon") || text.contains("amzn"))
            && !["prime video", "amazon prime", "primevideo", "prime membership", "kindle", "audible", "web services",
                 "amazon music", "amazon digital", "amzn digital"].contains { text.contains($0) }
            && text.range(of: #"\baws\b"#, options: .regularExpression) == nil
    }
    var sourceTitle: String { source == "bank" ? "Checking" : source == "card" ? "Card" : "Cash ledger" }

    /// Statement text to start a rule from: the payee's first words, without a card processor's prefix ("SQ *",
    /// "IN *") and stopping at store numbers, phone numbers and "#": "APPLE.COM/BILL 866-712-7753 CA" → "APPLE.COM/BILL".
    var statementKey: String {
        var text = (payee ?? description ?? "").trimmingCharacters(in: .whitespaces)
        if let r = text.range(of: #"^[A-Za-z]{1,4} ?\* ?"#, options: .regularExpression) { text = String(text[r.upperBound...]) }
        var words: [Substring] = []
        for w in text.split(separator: " ") {
            if w.contains(where: { $0.isNumber || $0 == "#" || $0 == "*" }) || words.count == 3 { break }
            words.append(w)
        }
        while let last = words.last, ["AND", "&", "OF", "THE", "-", "/"].contains(last.uppercased()) { words.removeLast() }
        let key = words.joined(separator: " ")
        return key.count >= 3 ? key : String(text.prefix(30))
    }

    /// Its payee or description contains the text, ignoring case, as a statement text rule matches.
    func contains(statement text: String) -> Bool {
        let t = text.lowercased()
        return !t.isEmpty && [payee, description].contains { ($0 ?? "").lowercased().contains(t) }
    }
}

/// Something an Apple bill bought (V056): an app, an in-app purchase, a subscription, a film.
struct AppleItem: Decodable, Hashable {
    var name: String
    /// Monthly, the app an in-app purchase was in, the device.
    var detail: String?
    var amount: Double?
    var orderId: String
    var orderedAt: String?
    /// "Apple Music (Individual, Monthly)"
    var label: String { detail.map { $0.isEmpty ? name : "\(name) (\($0))" } ?? name }
}

/// Something bought in the Amazon order a card charge or checking debit paid, or a credit refunded (V046).
struct AmazonItem: Decodable, Hashable {
    var name: String
    var asin: String?
    var quantity: Int?
    var amount: Double?
    var orderId: String
    var orderedAt: String?
    /// "2 × Dog Chew Toys"
    var label: String { (quantity ?? 1) > 1 ? "\(quantity ?? 1) × \(name)" : name }

    /// The order on amazon.com (the user signs in there).
    static func orderURL(_ id: String) -> URL? {
        URL(string: "https://www.amazon.com/gp/your-account/order-details?orderID=\(id)")
    }
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

/// Why spending changed (Family Growth, One-Time Event …): srm.spending_driver (V047), added and changed on Admin.
/// Target accounts and tags store its code.
struct SpendingDriver: Decodable, Identifiable, Hashable {
    var code: String
    var title: String
    /// What it means.
    var help: String?
    /// The effect's code (srm.spending_driver.effect).
    var effectCode: String
    var sortOrder: Int
    var id: String { code }

    private enum CodingKeys: String, CodingKey { case code, title, help, effectCode = "effect", sortOrder }

    /// The attribution effect its spending's growth counts toward.
    var effect: SpendingEffect { SpendingEffect(code: effectCode) ?? .usage }
}

/// The attribution formula's terms: change = inflation + usage + lifecycle + behavior + one-time + taxes.
enum SpendingEffect: String, CaseIterable, Identifiable {
    case inflation = "Inflation", usage = "Usage", lifecycle = "Lifecycle", behavior = "Behavior", oneTime = "One-Time", taxes = "Taxes"
    var id: String { rawValue }

    /// How the security master names it (srm.spending_driver.effect).
    var code: String { self == .oneTime ? "one_time" : rawValue.lowercased() }
    init?(code: String) {
        guard let e = Self.allCases.first(where: { $0.code == code }) else { return nil }
        self = e
    }

    var color: Color {
        switch self {
        case .inflation: .orange
        case .usage: .blue
        case .lifecycle: .purple
        case .behavior: .pink
        case .oneTime: .teal
        case .taxes: .brown
        }
    }

    var help: String {
        switch self {
        case .inflation: "Prices: last year's spending times the category's CPI change, plus what spending whose driver counts as Inflation grew beyond it"
        case .usage: "More (or less) of the same: the growth beyond inflation of spending whose driver counts as Usage (Family Growth, New Activity …), and of spending with no driver"
        case .lifecycle: "Expected age-related costs: the growth beyond inflation of spending whose driver counts as Lifecycle (Lifecycle Transition …)"
        case .behavior: "Habits, tastes and hobbies: the growth beyond inflation of spending whose driver counts as Behavior (Preference Change, Lifestyle & Hobbies …)"
        case .oneTime: "Events that won't repeat: the growth beyond inflation of spending whose driver counts as One-Time (One-Time Event …)"
        case .taxes: "Taxes: the growth beyond inflation of spending whose driver counts as Taxes"
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
        if (share(.taxes) ?? 0) >= 0.5 { return "Taxes" }
        if (share(.usage) ?? 0) >= 0.5 { return "More of the same" }
        return "Mixed"
    }
}

enum SpendingEngine {
    static let unassigned = "UNASSIGNED"

    /// Each category's attribution (and Not assigned's, when it has spending), in the categories' order.
    static func attribute(_ data: SpendingAnalysisData, entries: [SpendingEntry], setup: SpendingSetup) -> [CategoryAttribution] {
        let categories = setup.categories
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
                effects[setup.driver(d)?.effect ?? .usage, default: 0] += grew
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

// MARK: - Sources

/// Where the analysis's data comes from (Sources tab): each register, whether it is included, its drop folders and
/// downloads, the tables its data lands in, its last import and its spending in both periods; every SRM table and view
/// the analysis reads with its rows, newest data and last change; and the download and CPI loaders' last runs.
/// An allocation call's answer: the setup with how many payments were given to the target account (and a new one's id).
struct AllocatedAnswer: Decodable {
    var setup: SpendingSetup
    var assigned: Int?
    var created: Int?

    init(from decoder: Decoder) throws {
        setup = try SpendingSetup(from: decoder)
        let c = try decoder.container(keyedBy: Keys.self)
        assigned = try c.decodeIfPresent(Int.self, forKey: .assigned)
        created = try c.decodeIfPresent(Int.self, forKey: .created)
    }
    private enum Keys: String, CodingKey { case assigned, created }
}

/// Sources ▸ Unallocated Payments (GET /spending/unallocated): checks and card charges no target account matches, not
/// in the analysis, grouped by their statement's own words.
struct SpendingUnallocated: Decodable {
    struct Entry: Decodable, Identifiable, Hashable {
        var source: String
        var entryId: Int
        var date: String
        var register: String
        var name: String
        var amount: Double
        var id: String { source + String(entryId) }
        private enum CodingKeys: String, CodingKey { case source, entryId = "id", date, register, name, amount }
    }
    struct Like: Decodable, Hashable, Identifiable { var id: Int; var name: String }
    struct Group: Decodable, Identifiable, Hashable {
        var key: String
        var label: String
        var names: [String]
        var nameCount: Int
        /// The words its statements start with, to match them by.
        var pattern: String
        var count: Int
        var now: Double
        var before: Double
        var total: Double
        var entries: [Entry]
        /// Target accounts with a name like it.
        var like: [Like]
        var id: String { key }
    }
    var start: String
    var end: String
    var priorStart: String
    var priorEnd: String
    var groups: [Group]
    var count: Int
    var now: Double
    var before: Double
}

/// Sources ▸ Transfers & Income (GET /spending/transfers): target accounts left out of the analysis as moving money
/// (filed under a transfer or income account), the ones that look like they should be, and the accounts to file under.
struct SpendingTransfers: Decodable {
    struct Why: Decodable, Hashable { var kind: String; var text: String }
    struct Target: Decodable, Identifiable, Hashable {
        var id: Int
        var name: String
        var expenseAccountId: Int?
        var expenseAccount: String?
        /// Its account's kind: expense, income or transfer (nil: no category).
        var kind: String?
        /// Its spending role (V052): spending, transfer or income.
        var role: String
        var entries: Int
        var lastDate: String?
        /// What it moved in each period, signed as spending: paid out positive, came in negative.
        var now: Double
        var before: Double
        var paidOut: Double
        var cameIn: Double
        var cards: [String]?
        var ledgers: [String]?
        /// A suggestion's reasons; certain when a card is paid with it or a cash ledger funded from it.
        var why: [Why]?
        var certain: Bool?
        /// transfer or income.
        var suggest: String?
    }
    struct Filed: Decodable, Hashable { var id: Int; var role: String }
    var start: String
    var end: String
    var priorStart: String
    var priorEnd: String
    var leftOut: [Target]
    var suggested: [Target]
    var filed: Filed?
}

/// What disconnecting a spending source undoes and keeps (GET /spending/sources/<source>/<code>/links).
struct SourceLinks: Decodable {
    struct Link: Decodable, Hashable { var kind: String; var what: String; var count: Int }
    var source: String
    var code: String
    var name: String
    var connected: Bool
    var links: [Link]
    /// Links kept from when it was disconnected, to put back.
    var kept: Int
    var spendingEntries: Int
}

struct SpendingSources: Decodable {
    struct Run: Decodable, Hashable {
        var loadId: Int
        var loader: String
        var status: String
        var startedAt: String?
        var finishedAt: String?
        var rowsRead: Int?
        var rowsInserted: Int?
        var message: String?
    }
    struct Download: Decodable, Hashable { var path: String; var name: String; var bytes: Int; var modified: String }
    struct Source: Decodable, Identifiable, Hashable {
        var source: String
        var code: String
        var name: String
        var institution: String?
        var last4: String?
        var closedDate: String?
        var entries: Int?
        var first: String?
        var last: String?
        var edited: String?
        var fromDownloads: Int?
        var lines: Int?
        var firstLine: String?
        var lastLine: String?
        var included: Bool
        var choiceBy: String?
        var choiceAt: String?
        var linesTable: String?
        var registerTable: String
        var loader: String?
        var dropFolders: [String]
        var downloads: [Download]
        var lastImport: Run?
        var spendingFirst: String?
        var spendingLast: String?
        var entriesNow: Int
        var spentNow: Double
        var entriesBefore: Int
        var spentBefore: Double
        /// Disconnected (V049): out of the analysis, its links to the other sources undone and kept.
        var connected: Bool
        var disconnectedBy: String?
        var disconnectedAt: String?
        /// A card's: lines of a removed card with the same last four digits whose tags and links wait to re-attach.
        var remembered: Int
        var id: String { source + code }
        var kindTitle: String { source == "bank" ? "Checking account" : source == "card" ? "Credit card" : "Cash ledger" }
        var symbol: String { source == "bank" ? "checkmark.rectangle.stack" : source == "card" ? "creditcard" : "briefcase" }
        var screen: String { source == "bank" ? "Banking ▸ Checking Accounts" : source == "card" ? "Banking ▸ Credit Card Accounts" : "Banking ▸ Cash Ledger" }
    }
    struct Table: Decodable, Identifiable, Hashable {
        var name: String
        var kind: String
        var role: String
        var rows: Int
        var newest: String?
        var changed: String?
        var id: String { name }
    }
    var start: String
    var end: String
    var priorStart: String
    var priorEnd: String
    var sources: [Source]
    var tables: [Table]
    var loaders: [Run]
    /// Amazon's order export (V046); nil before it.
    var amazon: AmazonOrders?
    /// Reconnect's answer: how many kept links were put back, and how many couldn't be.
    var reconnected: Reconnected?
    struct Reconnected: Decodable, Hashable { var code: String; var restored: Int; var skipped: Int }
    var now: String?

    func table(_ name: String) -> Table? { tables.first { $0.name == name } }
    func run(_ loader: String) -> Run? { loaders.first { $0.loader == loader } }
}

/// Amazon's Request Your Data ▸ Your Orders export (V046): where it comes from, what it holds and its last load; the
/// period's Amazon charges and how many it matched; and the period's charges no order matched and shipments no charge
/// paid.
struct AmazonOrders: Decodable, Hashable {
    struct Charge: Decodable, Hashable, Identifiable {
        var source: String
        var entryId: Int
        var date: String
        var register: String?
        var payee: String?
        var amount: Double
        var id: String { "\(source)-\(entryId)" }
    }
    struct Shipment: Decodable, Hashable, Identifiable {
        var shipmentId: Int
        var orderId: String
        var ordered: String?
        var shipped: String?
        var amount: Double
        var status: String?
        var payment: String?
        var items: String?
        var id: Int { shipmentId }
    }
    var orders: Int
    var firstOrder: String?
    var lastOrder: String?
    var items: Int
    var chargesNow: Int
    var matchedNow: Int
    var spentNow: Double
    var matchedSpentNow: Double
    var charges: Int
    var matched: Int
    var newestCharge: String?
    /// Amazon charges after the export's last order, not matched: a newer export is due.
    var afterExport: Int
    var loader: String
    var dropFolders: [String]?
    var foldersListed: Bool
    var downloads: [SpendingSources.Download]
    var lastImport: SpendingSources.Run?
    var unmatchedCharges: [Charge]
    var unmatchedShipments: [Shipment]
    /// How many of the orders came from the export, Amazon's e-mails and order pages (the Order Lookup).
    var ordersFrom: OrdersFrom?
    struct OrdersFrom: Decodable, Hashable { var export: Int; var email: Int; var orderPage: Int }
    /// Amazon's order e-mails (V055); nil before it.
    var email: AmazonEmail?
}

/// Amazon's order, shipment and refund e-mails (V055), read by srm.py load amazon-email from Gmail (read-only) or a
/// Google Takeout .mbox in the drop folder: the mailbox, the e-mails read, the orders they gave and the charges matched
/// to them.
struct AmazonEmail: Decodable, Hashable {
    struct Emails: Decodable, Hashable {
        var emails: Int
        var first: String?
        var last: String?
        var orders: Int
        var shipments: Int
        var refunds: Int
        var cancels: Int
        var other: Int
    }
    var loader: String
    /// A Gmail sign-in is kept in the Keychain (srm.py gmail-auth); nil where the loaders aren't.
    var connected: Bool?
    var since: String?
    var mailboxes: [String]
    var emails: Emails
    var orders: Int
    var firstOrder: String?
    var lastOrder: String?
    /// Amazon entries matched to orders from e-mails.
    var matched: Int
    var mboxFiles: [SpendingSources.Download]
    var lastImport: SpendingSources.Run?
}

/// A note on the page from its read-only web page on the home network (Services/spending-web, V039), and the answer.
struct SpendingFeedback: Decodable, Identifiable, Hashable {
    /// The page's state when the note was sent, and the entry it is about.
    struct Context: Decodable, Hashable {
        var year: Int?
        var yearToDate: Bool?
        var date: String?
        var payee: String?
        var amount: Double?
        var category: String?
        var driver: String?
    }
    var id: Int
    var createdAt: String
    var author: String
    var kind: String
    var tab: String?
    var section: String?
    var category: String?
    var entrySource: String?
    var entryId: Int?
    var suggestion: String?
    var message: String
    var context: Context?
    var status: String
    var reply: String?
    var repliedBy: String?
    var repliedAt: String?

    static let statuses = [("new", "New"), ("seen", "Seen"), ("planned", "Planned"), ("done", "Done"), ("declined", "Not planned")]
    var kindTitle: String {
        ["layout": "How the page looks", "number": "A number looks wrong", "rule": "A category or rule", "entry": "One purchase",
         "idea": "An idea", "question": "A question", "change": "A change on the family page"][kind] ?? kind
    }
    var open: Bool { status == "new" || status == "seen" || status == "planned" }
}

/// Year-End Tax (V040): the year's tax items with what they paid, every payment that counts toward the year (with its
/// tax year and quarter), and the summary.
struct TaxReport: Decodable {
    struct Item: Decodable, Identifiable, Hashable {
        var id: Int
        var payeeId: Int?
        var payee: String?
        var ledgerLineId: Int?
        var ledgerLine: String?
        var ledger: String?
        var namePattern: String?
        var label: String
        var section: String
        var taxCategory: String
        var jurisdiction: String?
        var deductibleShare: Double
        var quarterly: Bool
        var notes: String?
        var sortOrder: Int
        var active: Bool
        var paid: Double
        var entries: Int
        var deductible: Double?

        /// Where its payments come from, in words.
        var origin: String {
            if let payee { return "Target account \(payee)" }
            if let ledgerLine { return "Ledger \(ledger ?? "") line \(ledgerLine)" }
            if let namePattern { return "Card names containing \(namePattern)" }
            return ""
        }
    }
    struct Entry: Decodable, Identifiable, Hashable {
        var source: String
        var entryId: Int
        var date: String
        var payee: String?
        var description: String?
        var register: String?
        var amount: Double
        var itemId: Int
        var taxYear: Int
        var quarter: Int?
        var moved: Bool
        var note: String?
        var id: String { "\(source)-\(entryId)" }
        var period: String { quarter.map { "\(taxYear) Q\($0)" } ?? String(taxYear) }
    }
    struct Quarters: Decodable, Hashable {
        var q1: Double, q2: Double, q3: Double, q4: Double, other: Double, total: Double
        var all: [Double] { [q1, q2, q3, q4, other, total] }
    }
    struct Summary: Decodable, Hashable {
        var expensesPaid: Double
        var expensesDeductible: Double
        var payments: [String: Quarters]
        var paymentsTotal: Double
        var realEstate: Double
        var refunds: Double
        var savingsSetAside: Double
        var savingsTakenOut: Double
        /// The deductible loans' interest for the year (V053).
        var mortgageInterest: Double?
    }
    struct Register: Decodable, Hashable { var source: String; var register: String; var name: String; var first: String? }
    struct Line: Decodable, Hashable, Identifiable { var id: Int; var name: String; var ledger: String }

    var year: Int
    var items: [Item]
    var entries: [Entry]
    var summary: Summary
    var partialRegisters: [Register]
    var ledgerLines: [Line]
    /// Each loan whose interest is deductible, with the year's interest (Banking ▸ Loan Accounts, V053).
    var loans: [LoanYear]?

    static let sections = [("expense", "Tax-applicable expense"), ("payment", "Tax payment"), ("real_estate", "Real estate tax"),
                           ("refund", "Refund received"), ("savings", "Tax savings account")]
    static let jurisdictions = [("federal", "Federal"), ("state", "State (PA)"), ("local", "Local")]
    func item(_ id: Int) -> Item? { items.first { $0.id == id } }
    func entries(of section: String) -> [Entry] { entries.filter { item($0.itemId)?.section == section } }

    /// The year as CSV for the accountant: every payment with its item, then each item's totals and the estimated
    /// payments by quarter.
    var csv: String {
        func f(_ s: String?) -> String {
            let s = s ?? ""
            return s.contains(where: { ",\"\n".contains($0) }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        let n = { (x: Double) in String(format: "%.2f", x) }
        var rows = ["Year-End Tax \(year)", "",
                    "Section,Item,Category,Jurisdiction,Date,Payee,Register,Amount,Deductible share,Deductible,Tax year,Quarter,Note"]
        for e in entries {
            guard let i = item(e.itemId) else { continue }
            let deductible = ["expense", "real_estate"].contains(i.section)
            rows.append([f(Self.sections.first { $0.0 == i.section }?.1), f(i.label), f(i.taxCategory), f(i.jurisdiction), e.date,
                         f(e.payee ?? e.description), f(e.register), n(e.amount), deductible ? String(format: "%.0f%%", i.deductibleShare * 100) : "",
                         deductible ? n(e.amount * i.deductibleShare) : "", String(e.taxYear), e.quarter.map { "Q\($0)" } ?? "", f(e.note)].joined(separator: ","))
        }
        rows += ["", "Totals", "Section,Item,Category,Paid,Deductible share,Deductible,Payments"]
        for i in items where i.entries > 0 {
            rows.append([f(Self.sections.first { $0.0 == i.section }?.1), f(i.label), f(i.taxCategory), n(i.paid),
                         i.deductible == nil ? "" : String(format: "%.0f%%", i.deductibleShare * 100), i.deductible.map(n) ?? "", String(i.entries)].joined(separator: ","))
        }
        rows += ["", "Estimated and local tax payments", "Jurisdiction,Q1,Q2,Q3,Q4,Other,Total"]
        for (j, title) in Self.jurisdictions {
            if let q = summary.payments[j] { rows.append(([title] + q.all.map(n)).joined(separator: ",")) }
        }
        rows += ["", "Summary",
                 "Tax-applicable expenses paid,\(n(summary.expensesPaid))", "Deductible,\(n(summary.expensesDeductible))",
                 "Tax payments,\(n(summary.paymentsTotal))", "Real estate taxes,\(n(summary.realEstate))",
                 "Refunds received,\(n(summary.refunds))", "Tax savings set aside,\(n(summary.savingsSetAside))",
                 "Tax savings taken out,\(n(summary.savingsTakenOut))"]
        if let loans, !loans.isEmpty {
            rows += ["", "Mortgage interest", "Loan,Lender,Interest,From,Points (1098 box 6),Mortgage insurance (box 5),Property tax (box 10)"]
            for l in loans {
                rows.append([f(l.name), f(l.lender), n(l.interest), f(l.source), n(l.form1098?.pointsPaid ?? 0),
                             n(l.form1098?.mortgageInsurance ?? 0), n(l.form1098?.propertyTax ?? 0)].joined(separator: ","))
            }
        }
        return rows.joined(separator: "\n") + "\n"
    }
}

/// How old a date or time is, for the freshness of the analysis's data.
enum Freshness {
    /// Registers older than this (days) are flagged: a download is due.
    static let staleDays = 14
    /// CPI is monthly and published about six weeks after the month starts.
    static let staleCPIDays = 75

    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let stampWhole = ISO8601DateFormatter()

    /// A date (yyyy-mm-dd) or a timestamp as the service sends them.
    static func date(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        if s.count == 10 { return isoDay.date(from: s) }
        let t = s.replacingOccurrences(of: " ", with: "T")
        return stamp.date(from: t) ?? stampWhole.date(from: t)
    }

    static func days(_ s: String?) -> Int? {
        guard let d = date(s) else { return nil }
        return Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: d), to: Calendar.current.startOfDay(for: .now)).day
    }

    /// "today", "yesterday", "12 days ago", "in 4 days" (a scheduled entry).
    static func age(_ s: String?) -> String {
        guard let n = days(s) else { return "" }
        switch n {
        case 0: return "today"
        case 1: return "yesterday"
        case ..<0: return "in \(-n) day\(n == -1 ? "" : "s")"
        default: return "\(n) days ago"
        }
    }

    /// A timestamp as a day and time.
    static func when(_ s: String?) -> String {
        guard let d = date(s) else { return s ?? "" }
        return s?.count == 10 ? shortDay(s) : d.formatted(.dateTime.month(.twoDigits).day(.twoDigits).year().hour().minute())
    }

    static func isStale(_ s: String?, days limit: Int = staleDays) -> Bool { (days(s) ?? 0) > limit }
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
    static func addCategory(_ body: [String: Any]) async throws -> SpendingSetup {
        try await AccountsClient.request("POST", "/spending/categories", body: signed(body), as: SpendingSetup.self)
    }
    static func categoryUsage(_ code: String) async throws -> SpendingUsage {
        try await AccountsClient.request("GET", "/spending/categories/\(code)/usage", as: SpendingUsage.self)
    }
    /// Removes a category; its target accounts, tags, lifecycle triggers and notes move to `moveTo` first (none: they lose it).
    static func deleteCategory(_ code: String, moveTo: String?) async throws -> SpendingSetup {
        try await AccountsClient.request("DELETE", "/spending/categories/\(code)?moveTo=\(moveTo ?? "")&by=\(byQuery)", as: SpendingSetup.self)
    }
    static func orderCategories(_ codes: [String]) async throws -> SpendingSetup {
        try await AccountsClient.request("PUT", "/spending/category-order", body: signed(["codes": codes]), as: SpendingSetup.self)
    }
    static func addDriver(_ body: [String: Any]) async throws -> SpendingSetup {
        try await AccountsClient.request("POST", "/spending/drivers", body: signed(body), as: SpendingSetup.self)
    }
    static func saveDriver(_ code: String, _ body: [String: Any]) async throws -> SpendingSetup {
        try await AccountsClient.request("PUT", "/spending/drivers/\(code)", body: signed(body), as: SpendingSetup.self)
    }
    static func driverUsage(_ code: String) async throws -> SpendingUsage {
        try await AccountsClient.request("GET", "/spending/drivers/\(code)/usage", as: SpendingUsage.self)
    }
    /// Removes a driver; its target accounts and tags move to `moveTo` first (none: they lose their driver).
    static func deleteDriver(_ code: String, moveTo: String?) async throws -> SpendingSetup {
        try await AccountsClient.request("DELETE", "/spending/drivers/\(code)?moveTo=\(moveTo ?? "")&by=\(byQuery)", as: SpendingSetup.self)
    }
    static func orderDrivers(_ codes: [String]) async throws -> SpendingSetup {
        try await AccountsClient.request("PUT", "/spending/driver-order", body: signed(["codes": codes]), as: SpendingSetup.self)
    }
    private static var byQuery: String { BankClient.by.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }
    /// A target account's role, category, driver, member or patterns (the keys sent change); unallocated payments its
    /// patterns now match are given to it.
    static func allocateTarget(_ id: Int, _ body: [String: Any]) async throws -> (SpendingSetup, Int) {
        let out = try await AccountsClient.request("PUT", "/spending/targets/\(id)", body: signed(body), as: AllocatedAnswer.self)
        return (out.setup, out.assigned ?? 0)
    }
    /// A new target account for unallocated payments: the entries sent and every one its name or patterns match.
    static func addTarget(_ body: [String: Any]) async throws -> (SpendingSetup, Int) {
        let out = try await AccountsClient.request("POST", "/spending/targets", body: signed(body), as: AllocatedAnswer.self)
        return (out.setup, out.assigned ?? 0)
    }
    /// Gives unallocated payments to a target account.
    static func assignPayments(_ id: Int, _ entries: [SpendingUnallocated.Entry]) async throws -> (SpendingSetup, Int) {
        let out = try await AccountsClient.request("POST", "/spending/targets/\(id)/assign",
                                                   body: signed(["entries": entries.map { ["source": $0.source, "id": $0.entryId] }]), as: AllocatedAnswer.self)
        return (out.setup, out.assigned ?? 0)
    }
    static func unallocated(window: SpendingSources) async throws -> SpendingUnallocated {
        try await AccountsClient.request("GET", "/spending/unallocated?start=\(window.start)&end=\(window.end)&priorStart=\(window.priorStart)&priorEnd=\(window.priorEnd)",
                                         as: SpendingUnallocated.self)
    }
    /// Files card and check entries under another expense account; with fileFuture, their target account (or a new
    /// one named targetName, with their statement names) too, so future downloads land there.
    static func changeExpenseAccount(_ entries: [SpendingEntry], to account: Int, fileFuture: Bool, targetName: String) async throws -> SpendingSetup {
        try await AccountsClient.request("POST", "/spending/expense-account",
                                         body: signed(["entries": entries.map { ["source": $0.source, "id": $0.entryId] }, "expenseAccountId": account,
                                                       "fileFuture": fileFuture, "targetName": targetName]), as: SpendingSetup.self)
    }
    static func saveTrigger(_ id: Int, _ body: [String: Any]) async throws -> SpendingSetup {
        try await AccountsClient.request("PUT", "/spending/triggers/\(id)", body: signed(body), as: SpendingSetup.self)
    }
    static func deleteTrigger(_ id: Int) async throws -> SpendingSetup {
        try await AccountsClient.request("DELETE", "/spending/triggers/\(id)", as: SpendingSetup.self)
    }
    static func sources(start: String, end: String, priorStart: String, priorEnd: String) async throws -> SpendingSources {
        try await AccountsClient.request("GET", "/spending/sources?start=\(start)&end=\(end)&priorStart=\(priorStart)&priorEnd=\(priorEnd)",
                                         as: SpendingSources.self)
    }
    static func include(_ s: SpendingSources.Source, _ included: Bool, window: SpendingSources) async throws -> SpendingSources {
        try await AccountsClient.request("PUT", "/spending/sources/\(s.source)/\(s.code)?start=\(window.start)&end=\(window.end)&priorStart=\(window.priorStart)&priorEnd=\(window.priorEnd)",
                                         body: signed(["included": included]), as: SpendingSources.self)
    }
    static func transfers(window: SpendingSources) async throws -> SpendingTransfers {
        try await AccountsClient.request("GET", "/spending/transfers?start=\(window.start)&end=\(window.end)&priorStart=\(window.priorStart)&priorEnd=\(window.priorEnd)",
                                         as: SpendingTransfers.self)
    }
    /// A target account's role (V052): transfer or income leaves its payments out of the analysis, spending puts them back.
    static func fileTarget(_ id: Int, role: String, window: SpendingSources) async throws -> SpendingTransfers {
        try await AccountsClient.request("PUT", "/spending/transfers/\(id)?start=\(window.start)&end=\(window.end)&priorStart=\(window.priorStart)&priorEnd=\(window.priorEnd)",
                                         body: signed(["role": role]), as: SpendingTransfers.self)
    }
    /// What disconnecting a source undoes (its links to the other sources), and what stays.
    static func sourceLinks(_ s: SpendingSources.Source) async throws -> SourceLinks {
        try await AccountsClient.request("GET", "/spending/sources/\(s.source)/\(s.code)/links", as: SourceLinks.self)
    }
    /// Disconnects a source (V049), or reconnects it: its register stays; the links come back with it.
    static func connect(_ s: SpendingSources.Source, _ connect: Bool, window: SpendingSources) async throws -> SpendingSources {
        try await AccountsClient.request("POST", "/spending/sources/\(s.source)/\(s.code)/\(connect ? "reconnect" : "disconnect")?start=\(window.start)&end=\(window.end)&priorStart=\(window.priorStart)&priorEnd=\(window.priorEnd)",
                                         body: signed([:]), as: SpendingSources.self)
    }
    /// Reads Amazon's order export again (srm-loader amazon-orders); with a file, first saves it — the zip as
    /// downloaded, or a Retail.OrderHistory CSV — in the export's drop folder.
    static func loadAmazon(_ file: URL?, window: SpendingSources) async throws -> SpendingSources {
        var body: [String: Any] = [:]
        if let file {
            body = ["filename": file.lastPathComponent, "data": try Data(contentsOf: file).base64EncodedString()]
        }
        return try await AccountsClient.request("POST", "/spending/amazon/load?start=\(window.start)&end=\(window.end)&priorStart=\(window.priorStart)&priorEnd=\(window.priorEnd)",
                                                body: signed(body), as: SpendingSources.self)
    }
    /// Reads Amazon's order e-mails (srm-loader amazon-email: Gmail, read-only, and the .mbox files in the drop folder).
    static func loadAmazonEmail(window: SpendingSources) async throws -> SpendingSources {
        try await AccountsClient.request("POST", "/spending/amazon/email/load?start=\(window.start)&end=\(window.end)&priorStart=\(window.priorStart)&priorEnd=\(window.priorEnd)",
                                         body: signed([:]), as: SpendingSources.self)
    }
    /// An Amazon order the security master keeps: how many items, where it was read (export, email, order page), when it
    /// was placed and the entries it is on.
    struct KnownOrder: Decodable {
        struct Charge: Decodable { var source: String; var entryId: Int; var date: String; var amount: Double }
        var orderId: String
        var origin: String
        var items: Int
        var orderedAt: String?
        var charges: [Charge]?
    }
    /// Which of these Amazon orders the security master keeps.
    static func amazonKnown(_ ids: [String]) async throws -> [String: KnownOrder] {
        struct Answer: Decodable { var known: [KnownOrder] }
        guard !ids.isEmpty else { return [:] }
        let list = ids.joined(separator: ",").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let known = try await AccountsClient.request("GET", "/spending/amazon/known?ids=\(list)", as: Answer.self).known
        return Dictionary(known.map { ($0.orderId, $0) }, uniquingKeysWith: { a, _ in a })
    }
    /// The Amazon Order Lookup's results: the orders its pages gave, and each charge's orders; answers with the entries.
    static func attachAmazon(charges: [[String: Any]], orders: [[String: Any]]) async throws -> [SpendingEntry] {
        struct Answer: Decodable { var entries: [SpendingEntry] }
        return try await AccountsClient.request("POST", "/spending/amazon/attach", body: signed(["charges": charges, "orders": orders]),
                                                as: Answer.self).entries
    }
    /// Takes the Amazon orders off a charge for good (the export doesn't match it again).
    static func unlinkAmazon(_ e: SpendingEntry) async throws -> SpendingEntry? {
        try await AccountsClient.request("POST", "/spending/amazon/unlink/\(e.source)/\(e.entryId)", body: signed([:]), as: TagAnswer.self).entry
    }
    /// What POST /spending/apple/attach answers: how many bills were kept and charges matched, the Apple charges in
    /// the bills' dates still without one, and the charges asked about.
    struct AppleAttached: Decodable {
        /// An Apple charge without a bill, and the order its description names (Discover's), if any.
        struct Left: Decodable, Hashable { var source: String; var entryId: Int; var date: String; var amount: Double; var orderId: String? }
        var invoices: Int
        var matched: Int
        var kept: Int
        var first: String?
        var last: String?
        var unmatched: [Left]
        var entries: [SpendingEntry]
    }
    /// The Apple Purchase Lookup's bills (V056); the service matches every Apple charge it can and answers with these charges.
    static func attachApple(invoices: [[String: Any]], charges: [SpendingEntry]) async throws -> AppleAttached {
        try await AccountsClient.request("POST", "/spending/apple/attach",
                                         body: signed(["invoices": invoices, "charges": charges.map { ["source": $0.source, "entryId": $0.entryId] }]),
                                         as: AppleAttached.self)
    }
    static func unlinkApple(_ e: SpendingEntry) async throws -> SpendingEntry? {
        try await AccountsClient.request("POST", "/spending/apple/unlink/\(e.source)/\(e.entryId)", body: signed([:]), as: TagAnswer.self).entry
    }
    private struct Notes: Decodable { var feedback: [SpendingFeedback] }
    static func feedback() async throws -> [SpendingFeedback] {
        try await AccountsClient.request("GET", "/spending/feedback", as: Notes.self).feedback
    }
    /// Puts back what a family-page change replaced (V041); its note becomes Not planned, "Undone."
    static func undo(_ id: Int) async throws -> [SpendingFeedback] {
        try await AccountsClient.request("POST", "/spending/feedback/\(id)/undo", body: signed([:]), as: Notes.self).feedback
    }
    static func answer(_ id: Int, status: String, reply: String) async throws -> [SpendingFeedback] {
        try await AccountsClient.request("PUT", "/spending/feedback/\(id)", body: signed(["status": status, "reply": reply]), as: Notes.self).feedback
    }
    static func tax(year: Int) async throws -> TaxReport {
        try await AccountsClient.request("GET", "/spending/tax?year=\(year)", as: TaxReport.self)
    }
    static func saveTaxItem(_ id: Int, _ body: [String: Any], year: Int) async throws -> TaxReport {
        try await AccountsClient.request("PUT", "/spending/tax/items/\(id)?year=\(year)", body: signed(body), as: TaxReport.self)
    }
    static func deleteTaxItem(_ id: Int, year: Int) async throws -> TaxReport {
        try await AccountsClient.request("DELETE", "/spending/tax/items/\(id)?year=\(year)", as: TaxReport.self)
    }
    static func move(_ e: TaxReport.Entry, toYear: Int?, quarter: Int?, note: String, year: Int) async throws -> TaxReport {
        try await AccountsClient.request("PUT", "/spending/tax/assign/\(e.source)/\(e.entryId)?year=\(year)",
                                         body: signed(["taxYear": toYear ?? NSNull(), "quarter": quarter ?? NSNull(), "note": note]), as: TaxReport.self)
    }
    static func tag(_ entry: SpendingEntry, _ body: [String: Any]) async throws -> SpendingEntry? {
        try await AccountsClient.request("PUT", "/spending/tags/\(entry.source)/\(entry.entryId)", body: signed(body), as: TagAnswer.self).entry
    }
}
