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

/// An expense account's, a target account's or a piece of statement text's category, driver and member.
struct SpendingRule: Decodable, Identifiable, Hashable {
    var id: Int
    var expenseAccountId: Int?
    var expenseAccount: String?
    var payeeId: Int?
    var payee: String?
    /// Statement text (V042): entries whose payee, statement name or description contains it, ignoring case.
    var pattern: String?
    /// A statement text rule's link (V043), shown on its text as target accounts' links are (TargetAccountLinks.swift).
    var link: TargetLink?
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
    struct Named: Decodable, Identifiable, Hashable {
        var id: Int
        var name: String
        var expenseAccountId: Int?
        /// An expense account's description.
        var description: String?
        // A target account's details and link (srm.payee_link, V032), for the Rules tab's names and hover text.
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
    func rule(pattern: String) -> SpendingRule? { rules.first { $0.pattern?.lowercased() == pattern.lowercased() } }
    var textRules: [SpendingRule] { rules.filter { $0.pattern != nil } }
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
    /// amazon-orders (the export, by amount and date) or amazon-lookup (Amazon's own Transactions list).
    var amazonMatchedBy: String?
    var id: String { "\(source)-\(entryId)" }

    /// What an Amazon charge bought, in a line: "Kids' Swim Goggles, 3 Pack and 1 more".
    var bought: String? {
        guard let items = amazonItems, let first = items.first else { return nil }
        return items.count == 1 ? first.label : "\(first.label) and \(items.count - 1) more"
    }
    /// Every item with its cost, and the orders: hover text.
    var boughtDetail: String? {
        guard let items = amazonItems, !items.isEmpty else { return nil }
        let lines = items.map { i in i.amount.map { "\(i.label) — \(money2($0))" } ?? i.label }
        let orders = Array(Set(items.map(\.orderId))).sorted()
        return (amount < 0 ? "Refunded:\n" : "Bought:\n") + lines.joined(separator: "\n")
            + "\nAmazon order\(orders.count == 1 ? "" : "s") " + orders.joined(separator: ", ")
            + (amazonMatchedBy == "amazon-lookup" ? " — from Amazon's Transactions list" : amazonMatchedBy == "amazon-orders" ? " — matched by amount and date" : "")
    }
    var amazonOrderIds: [String] { Array(Set((amazonItems ?? []).map(\.orderId))).sorted() }

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
    var sourceTitle: String { source == "bank" ? "Checking" : source == "card" ? "Card" : "Expense ledger" }

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

/// An expense-ledger entry that looks like a card charge or check it isn't linked to (Admin): counted twice while its
/// ledger is in the analysis, once when linked.
struct SpendingOverlap: Decodable, Identifiable, Hashable {
    struct Match: Decodable, Hashable {
        var source: String
        var txnId: Int
        var register: String
        var txnDate: String
        var payee: String?
        var days: Int
    }
    var entryId: Int
    var version: Int
    var ledger: String
    var date: String
    var vendor: String?
    var description: String
    var amount: Double
    /// Nearest date first.
    var matches: [Match]
    var id: Int { entryId }
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
    case inflation, familyGrowth = "family_growth", newActivity = "new_activity", lifecycle, preference, lifestyle, oneTime = "one_time", taxes
    var id: String { rawValue }

    var title: String {
        switch self {
        case .inflation: "Inflation"
        case .familyGrowth: "Family Growth"
        case .newActivity: "New Activity"
        case .lifecycle: "Lifecycle Transition"
        case .preference: "Preference Change"
        case .lifestyle: "Lifestyle & Hobbies"
        case .oneTime: "One-Time Event"
        case .taxes: "Taxes"
        }
    }

    var help: String {
        switch self {
        case .inflation: "The same thing costs more"
        case .familyGrowth: "More people, more of the same things"
        case .newActivity: "Something the family didn't do before"
        case .lifecycle: "Expected age-related spending: tutors, driving, college"
        case .preference: "A habit or taste changed: eating out more, a better brand"
        case .lifestyle: "The family's hobbies and way of living: music gear and lessons, sports, crafts, clubs"
        case .oneTime: "An event that won't repeat: Philmont, a wedding, a repair"
        case .taxes: "Taxes changed: real estate, income, local or sales taxes and their fees"
        }
    }

    /// The attribution effect its spending's growth counts toward.
    var effect: SpendingEffect {
        switch self {
        case .inflation: .inflation
        case .familyGrowth, .newActivity: .usage
        case .lifecycle: .lifecycle
        case .preference, .lifestyle: .behavior
        case .oneTime: .oneTime
        case .taxes: .taxes
        }
    }

    static func title(_ raw: String?) -> String { raw.flatMap(SpendingDriver.init(rawValue:))?.title ?? "Not assigned" }
}

/// The attribution formula's terms: change = inflation + usage + lifecycle + behavior + one-time + taxes.
enum SpendingEffect: String, CaseIterable, Identifiable {
    case inflation = "Inflation", usage = "Usage", lifecycle = "Lifecycle", behavior = "Behavior", oneTime = "One-Time", taxes = "Taxes"
    var id: String { rawValue }

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
        case .inflation: "Prices: last year's spending times the category's CPI change, plus what spending tagged Inflation grew beyond it"
        case .usage: "More (or less) of the same: family growth, new activities, and spending with no driver assigned"
        case .lifecycle: "Expected age-related costs: the growth of spending tagged Lifecycle Transition, beyond inflation"
        case .behavior: "Habits, tastes and hobbies: the growth of spending tagged Preference Change or Lifestyle & Hobbies, beyond inflation"
        case .oneTime: "Events that won't repeat: the growth of spending tagged One-Time Event, beyond inflation"
        case .taxes: "Taxes: the growth of spending tagged Taxes, beyond inflation"
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

// MARK: - Sources

/// Where the analysis's data comes from (Sources tab): each register, whether it is included, its drop folders and
/// downloads, the tables its data lands in, its last import and its spending in both periods; every SRM table and view
/// the analysis reads with its rows, newest data and last change; and the download and CPI loaders' last runs.
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
        var id: String { source + code }
        var kindTitle: String { source == "bank" ? "Checking account" : source == "card" ? "Credit card" : "Expense ledger" }
        var symbol: String { source == "bank" ? "checkmark.rectangle.stack" : source == "card" ? "creditcard" : "briefcase" }
        var screen: String { source == "bank" ? "Banking ▸ Checking Accounts" : source == "card" ? "Banking ▸ Credit Card Accounts" : "Banking ▸ Expense Ledgers" }
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
    }
    struct Register: Decodable, Hashable { var source: String; var register: String; var name: String; var first: String? }
    struct Line: Decodable, Hashable, Identifiable { var id: Int; var name: String; var ledger: String }

    var year: Int
    var items: [Item]
    var entries: [Entry]
    var summary: Summary
    var partialRegisters: [Register]
    var ledgerLines: [Line]

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
    static func saveRule(_ body: [String: Any]) async throws -> SpendingSetup {
        try await AccountsClient.request("PUT", "/spending/rules", body: signed(body), as: SpendingSetup.self)
    }
    /// Files card and check entries under another expense account; with fileFuture, their target account (or a new
    /// one named targetName, with their statement names) too, so future downloads land there.
    static func changeExpenseAccount(_ entries: [SpendingEntry], to account: Int, fileFuture: Bool, targetName: String) async throws -> SpendingSetup {
        try await AccountsClient.request("POST", "/spending/expense-account",
                                         body: signed(["entries": entries.map { ["source": $0.source, "id": $0.entryId] }, "expenseAccountId": account,
                                                       "fileFuture": fileFuture, "targetName": targetName]), as: SpendingSetup.self)
    }
    /// Expense-ledger entries that match an unlinked card charge or check (Admin).
    static func overlaps() async throws -> [SpendingOverlap] {
        struct Answer: Decodable { var overlaps: [SpendingOverlap] }
        return try await AccountsClient.request("GET", "/spending/overlaps", as: Answer.self).overlaps
    }
    /// Links a ledger entry to the card charge or check that paid it: the purchase then counts once.
    static func link(_ o: SpendingOverlap, to m: SpendingOverlap.Match) async throws {
        struct Ignored: Decodable {}
        _ = try await AccountsClient.request("POST", "/expense-entries/\(o.entryId)/link",
                                             body: signed(["version": o.version, "source": m.source, "txnId": m.txnId]), as: Ignored.self)
    }
    /// A statement text rule's link (V043), saved or with nil taken off, as BankClient.savePayeeLink does a target's.
    static func saveRuleLink(_ id: Int, _ link: SecurityLink?) async throws -> SpendingSetup {
        guard let link else { return try await AccountsClient.request("DELETE", "/spending/rules/\(id)/link", as: SpendingSetup.self) }
        let body: [String: Any] = ["address": link.address, "text": link.text ?? "", "hoverText": link.tipPlain ?? "",
                                   "hoverRtf": link.tip.flatMap { String(data: $0, encoding: .utf8) } ?? "", "title": link.title ?? ""]
        return try await AccountsClient.request("PUT", "/spending/rules/\(id)/link", body: signed(body), as: SpendingSetup.self)
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
    /// Which of these Amazon orders the security master keeps, with how many items.
    static func amazonKnown(_ ids: [String]) async throws -> [String: Int] {
        struct Known: Decodable { var orderId: String; var items: Int }
        struct Answer: Decodable { var known: [Known] }
        guard !ids.isEmpty else { return [:] }
        let list = ids.joined(separator: ",").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let known = try await AccountsClient.request("GET", "/spending/amazon/known?ids=\(list)", as: Answer.self).known
        return Dictionary(known.map { ($0.orderId, $0.items) }, uniquingKeysWith: { a, _ in a })
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
