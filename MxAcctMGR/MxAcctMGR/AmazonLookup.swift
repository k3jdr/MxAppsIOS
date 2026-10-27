//
//  AmazonLookup.swift
//  MxAcctMGR
//
//  Amazon Order Lookup (Reporting ▸ Spending Analysis ▸ Entries ▸ Look Up Amazon Orders…): what the selected Amazon
//  charges bought, read from amazon.com in a window of the app's own. Amazon has no API for a personal account's orders;
//  the Request Your Data export (srm.py load amazon-orders) brings them in bulk, this a few charges at a time.
//
//  The window is a web view (WebKit). You sign in to Amazon there yourself, the first time and whenever Amazon asks:
//  the app never sees, types or keeps the password (the sign-in stays in the web view's cookies, as in Safari; Sign Out
//  of Amazon clears them). When Amazon shows a sign-in, a two-step check or a robot check, the lookup waits for you and
//  never answers it. It reads:
//    1. Your Payments ▸ Transactions, which lists each card charge with the orders it paid — matched to the selected
//       charges by amount, sign and date (within 4 days), the card's name breaking ties. Older charges are further down:
//       its Next page button, or (the newer list) its Show more button or the bottom of the page loads them;
//    2. for charges not found there, Your Orders for their year (each order's total and date), as a fallback — the
//       Digital Orders tab for Prime Video (rentals, purchases, channels), Kindle and other digital charges;
//    3. each order's page, for its items (name, ASIN, quantity, price; a video's title), unless the security master has
//       them already.
//  Pages are opened one at a time, 3 seconds apart, at most 40 Transactions pages, 30 Your Orders pages a year and 25
//  orders a run. A single order can be attached to a charge too: its number typed or pasted (or its page's link), or
//  the order the window shows (This Order) — only that order's page is read. Amazon's Conditions of Use don't allow robots: it runs only when you ask, and may stop working when
//  Amazon changes its pages. The results attach to the charges as the export's do (POST /spending/amazon/attach): the
//  Entries tab's Bought links, with what was bought on hover.
//

import AppKit
import SwiftUI
import WebKit

/// One selected charge and the orders found for it.
struct AmazonLookupCharge: Identifiable, Hashable {
    let entry: SpendingEntry
    var orders: [String] = []
    /// Where they were found: "Transactions", "Your Orders (total and date)".
    var foundIn: String?
    var id: String { entry.id }
    var cents: Int { Int((abs(entry.amount) * 100).rounded()) }
    var isCredit: Bool { entry.amount < 0 }
    /// Prime Video, Kindle and other digital charges: their orders are on the Digital Orders tab.
    var isDigital: Bool { entry.isAmazonDigitalCharge }
}

/// What the pages' scripts read (JSON).
private struct AmazonTransaction: Decodable { var date: String?; var amount: Double; var sign: String?; var card: String?; var orders: [String] }
private struct AmazonTransactionsPage: Decodable { var lines: [AmazonTransaction]; var next: Bool }
private struct AmazonOrderCard: Decodable { var orderId: String; var placed: String?; var total: Double? }
private struct AmazonOrderPage: Decodable {
    struct Item: Decodable { var name: String; var asin: String?; var quantity: Int?; var price: Double? }
    var placed: String?
    var total: Double?
    var payment: String?
    var items: [Item]
}

@MainActor
@Observable
final class AmazonLookup {
    /// amazon.com; in Debug self-tests a local stand-in (-amazonBase http://127.0.0.1:18790).
    static var base: URL {
        #if DEBUG
        if let s = UserDefaults.standard.string(forKey: "amazonBase"), let url = URL(string: s) { return url }
        #endif
        return URL(string: "https://www.amazon.com")!
    }
    /// Seconds between pages (Debug self-tests may shorten it: -amazonPauseSeconds).
    static var pause: Double {
        #if DEBUG
        let s = UserDefaults.standard.double(forKey: "amazonPauseSeconds")
        if s > 0 { return s }
        #endif
        return 3
    }
    static let maxTransactionPages = 40, maxOrderListPages = 30, maxOrderPages = 25

    var charges: [AmazonLookupCharge]
    var status = ""
    var waitingForYou = false
    var running = false
    var problem: String?
    /// What was read, step by step.
    var steps: [String] = []
    /// The order the window shows now (an order's page), for This Order.
    var shownOrder: String?
    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let attached: ([SpendingEntry]) -> Void
    @ObservationIgnored private var watching: NSKeyValueObservation?

    init(entries: [SpendingEntry], attached: @escaping ([SpendingEntry]) -> Void) {
        charges = entries.filter(\.isAmazonLookupCharge).sorted { $0.date > $1.date }.map { AmazonLookupCharge(entry: $0) }
        self.attached = attached
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()     // the sign-in stays between lookups, as in Safari
        webView = WKWebView(frame: .zero, configuration: config)
        watching = webView.observe(\.url, options: [.initial, .new]) { [weak self] web, _ in
            MainActor.assumeIsolated { self?.shownOrder = web.url.flatMap(Self.order(in:)) }
        }
    }

    /// The order numbers in a text: "113-1234567-1234567", "Order # 113-…", or an order page's link.
    static func orderNumbers(in text: String) -> [String] {
        var found: [String] = []
        var rest = text[...]
        while let r = rest.range(of: #"[0-9D]\d{2}-\d{7}-\d{7}"#, options: .regularExpression) {
            if !found.contains(String(rest[r])) { found.append(String(rest[r])) }
            rest = rest[r.upperBound...]
        }
        return found
    }

    /// The order an amazon.com page is about: its orderID (an order's page), else none.
    static func order(in url: URL) -> String? {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let id = query.first(where: { $0.name.lowercased() == "orderid" })?.value else { return nil }
        return orderNumbers(in: id).first
    }

    /// The query, in words: how many charges, their dates and amounts.
    var query: String {
        guard let first = charges.map(\.entry.date).min(), let last = charges.map(\.entry.date).max() else {
            return "None of the selected entries is an Amazon order or Prime Video charge (AWS and Audible bills aren't orders)."
        }
        return "\(charges.count) Amazon \(charges.count == 1 ? "charge" : "charges"), \(shortDay(first))\(first == last ? "" : " – \(shortDay(last))"): "
            + charges.prefix(8).map { money2($0.entry.amount) }.joined(separator: ", ") + (charges.count > 8 ? " …" : "")
    }

    func start() {
        guard !running, !charges.isEmpty else { return }
        for i in charges.indices { charges[i].orders = []; charges[i].foundIn = nil }
        steps = []
        problem = nil
        running = true
        task = Task { [weak self] in
            guard let self else { return }
            do { try await self.run() } catch is CancellationError {
                self.status = "Stopped."
            } catch {
                self.problem = describe(error)
                self.status = "The lookup stopped: \(describe(error))"
            }
            self.running = false
            self.waitingForYou = false
        }
    }

    func stop() { task?.cancel() }

    /// Opens Your Orders (or its Digital Orders tab) in the window, to find an order to attach (no lookup runs).
    func browse(digital: Bool = false) {
        status = "Find the order below (you may need to sign in), open it and press This Order on its charge — or type or paste its number there."
        var url = URLComponents(url: Self.base.appending(path: "your-orders/orders"), resolvingAgainstBaseURL: false)!
        if digital { url.queryItems = [URLQueryItem(name: "orderFilter", value: "digital")] }
        webView.load(URLRequest(url: url.url!))
    }

    /// Attaches the orders a text names (typed or pasted numbers, or an order page's link) to one charge, in place of
    /// what it had; reads each order's page unless the security master has it.
    func attach(_ text: String, to chargeID: String) {
        guard !running, let i = charges.firstIndex(where: { $0.id == chargeID }) else { return }
        let ids = Self.orderNumbers(in: text)
        guard !ids.isEmpty else {
            problem = "not an order number"
            status = "That isn't an Amazon order number: it looks like 113-1234567-1234567."
            return
        }
        running = true
        problem = nil
        let charge = charges[i]
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let known = try await SpendingClient.amazonKnown(ids)
                var pages: [[String: Any]] = []
                for id in ids where (known[id] ?? 0) == 0 {
                    if !pages.isEmpty { try await self.wait() }
                    self.status = "Reading order \(id)…"
                    guard let page = try await self.readOrder(id) else {
                        throw LookupError("order \(id)'s page shows no items: is it an order of yours?")
                    }
                    pages.append(page)
                }
                let entries = try await SpendingClient.attachAmazon(
                    charges: [["source": charge.entry.source, "entryId": charge.entry.entryId, "orderIds": ids]], orders: pages)
                if let j = self.charges.firstIndex(where: { $0.id == chargeID }) {
                    self.charges[j].orders = ids
                    self.charges[j].foundIn = "yours"
                }
                self.attached(entries)
                self.status = "Attached order\(ids.count == 1 ? "" : "s") \(ids.joined(separator: ", ")) to the \(money2(charge.entry.amount)) charge of \(shortDay(charge.entry.date))."
            } catch is CancellationError {
                self.status = "Stopped."
            } catch {
                self.problem = describe(error)
                self.status = "Not attached: \(describe(error))"
            }
            self.running = false
            self.waitingForYou = false
        }
    }

    /// Clears amazon.com's cookies and data from the app's web view: the next lookup asks you to sign in.
    func signOut() async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types).filter { $0.displayName.localizedCaseInsensitiveContains("amazon") }
        await store.removeData(ofTypes: types, for: records)
        status = "Signed out of Amazon in this window (\(records.count) site record\(records.count == 1 ? "" : "s") cleared)."
    }

    // MARK: The lookup

    private func run() async throws {
        let earliest = Freshness.date(charges.map(\.entry.date).min())!
        // 1. Your Payments ▸ Transactions: each charge with its orders.
        status = "Reading Amazon's Transactions list…"
        try await open(Self.base.appending(path: "cpe/yourpayments/transactions"))
        var seen = Set<String>()
        for page in 1...Self.maxTransactionPages {
            try onPage("transactions", "Amazon's Transactions list")
            let read = try await json(Self.transactionsScript, as: AmazonTransactionsPage.self)
            let fresh = read.lines.filter { seen.insert("\($0.date ?? "")|\($0.amount)|\($0.orders.joined())").inserted }
            match(fresh)
            let dates = read.lines.compactMap { Self.day($0.date) }
            steps.append("Transactions page \(page): \(read.lines.count) charges\(dates.min().map { " back to \(shortDay(Self.iso($0)))" } ?? "")")
            if read.lines.isEmpty && page == 1 { steps.append("No charges recognized on the Transactions page: Amazon may have changed it") }
            if charges.allSatisfy({ !$0.orders.isEmpty }) { break }
            if let oldest = dates.min(), oldest < earliest.addingTimeInterval(-7 * 86400) { break }
            guard fresh.count > 0 else { break }
            try await wait()
            status = "Reading Amazon's Transactions list, page \(page + 1)…"
            if read.next {
                let before = read.lines.first.map { "\($0.date ?? "")\($0.amount)" }
                guard try await js(Self.nextPageScript) as? Bool == true else { break }
                try await settle()
                for _ in 0..<20 {      // the list may page without loading a new document
                    let now = try await json(Self.transactionsScript, as: AmazonTransactionsPage.self).lines.first.map { "\($0.date ?? "")\($0.amount)" }
                    if now != before { break }
                    try await Task.sleep(for: .milliseconds(500))
                }
            } else {
                // The newer list has no Next page: it loads older charges below the others, from its Show more button
                // or when the page is scrolled to the end.
                let how = try await js(Self.moreScript) as? String ?? ""
                var grew = false
                for _ in 0..<20 {
                    try await Task.sleep(for: .milliseconds(500))
                    if try await json(Self.transactionsScript, as: AmazonTransactionsPage.self).lines.count > read.lines.count { grew = true; break }
                }
                guard grew else {
                    let controls = try await js(Self.controlsScript) as? String ?? ""
                    steps.append("Transactions: nothing more after page \(page) (\(how == "clicked" ? "pressed Show more" : "scrolled to the end"); controls on the page: \(controls.isEmpty ? "none" : controls))")
                    break
                }
            }
        }
        // 2. Your Orders for each charge's year (and the year before, for a January charge), for charges the Transactions
        //    list didn't show: an order whose total is the charge. Amazon shows the past 3 months unless asked for a year
        //    (timeFilter). Digital charges look on its Digital Orders tab.
        for digital in [false, true] {
            let left = { (year: String) -> [Date] in
                self.charges.filter { $0.orders.isEmpty && !$0.isCredit && $0.isDigital == digital }.compactMap { c -> Date? in
                    let d = c.entry.date
                    let january = d.hasPrefix(String((Int(year) ?? 0) + 1)) && d.dropFirst(5) < "02-05"
                    return d.hasPrefix(year) || january ? Freshness.date(d) : nil
                }
            }
            let years = Set(charges.filter { $0.orders.isEmpty && !$0.isCredit && $0.isDigital == digital }.flatMap { c -> [String] in
                let y = Int(c.entry.date.prefix(4)) ?? 0
                return c.entry.date.dropFirst(5) < "02-05" ? [String(y), String(y - 1)] : [String(y)]
            }).sorted(by: >)
            let tab = digital ? "Digital Orders" : "Your Orders"
            for year in years {
                for page in 0..<Self.maxOrderListPages {
                    guard let need = left(year).min() else { break }
                    try await wait()
                    status = "Reading \(tab) for \(year)\(page > 0 ? ", page \(page + 1)" : "")…"
                    var url = URLComponents(url: Self.base.appending(path: "your-orders/orders"), resolvingAgainstBaseURL: false)!
                    url.queryItems = (digital ? [URLQueryItem(name: "orderFilter", value: "digital")] : [])
                        + [URLQueryItem(name: "timeFilter", value: "year-\(year)"), URLQueryItem(name: "startIndex", value: "\(page * 10)")]
                        + (digital ? [URLQueryItem(name: "page", value: "\(page + 1)")] : [])
                    try await open(url.url!)
                    try onPage("order", tab)
                    let cards = try await json(Self.orderListScript, as: [AmazonOrderCard].self)
                    let placed = cards.compactMap { Self.day($0.placed) }
                    steps.append("\(tab) \(year), page \(page + 1): \(cards.count) orders\(placed.min().map { " back to \(shortDay(Self.iso($0)))" } ?? "")")
                    matchOrders(cards, digital: digital)
                    if cards.count < 10 { break }
                    // Newest first: stop past the oldest charge left (and the month before it, when it may have been ordered).
                    if let oldest = placed.min(), oldest < need.addingTimeInterval(-35 * 86400) { break }
                }
            }
        }
        // 3. Each order's page, for what it holds, unless the security master has it.
        let ids = Array(Set(charges.flatMap(\.orders))).sorted()
        let known = try await SpendingClient.amazonKnown(ids)
        var pages: [[String: Any]] = []
        for (n, id) in ids.filter({ (known[$0] ?? 0) == 0 }).prefix(Self.maxOrderPages).enumerated() {
            try await wait()
            status = "Reading order \(id) (\(n + 1) of \(min(ids.count, Self.maxOrderPages)))…"
            if let page = try await readOrder(id) { pages.append(page) }
        }
        // 4. Attach them, as the export's matches are.
        let found = charges.filter { !$0.orders.isEmpty }
        guard !found.isEmpty else {
            status = "No order found for \(charges.count == 1 ? "this charge" : "these charges") on Amazon's Transactions list or Your Orders."
            return
        }
        status = "Attaching the orders…"
        let entries = try await SpendingClient.attachAmazon(
            charges: found.map { ["source": $0.entry.source, "entryId": $0.entry.entryId, "orderIds": $0.orders] }, orders: pages)
        attached(entries)
        let missing = charges.count - found.count
        status = "Attached \(found.count) of \(charges.count) charge\(charges.count == 1 ? "" : "s") to their orders"
            + (missing > 0 ? "; \(missing) not found" : "") + ". Hover a Bought link in Entries to see what was bought."
    }

    /// An order's page read: what POST /spending/amazon/attach takes for it, or nil when it shows no items.
    private func readOrder(_ id: String) async throws -> [String: Any]? {
        // The window may show it already (This Order): no need to load it again.
        let path = id.hasPrefix("D") ? "order" : "order-details"     // a digital order's page may be its order summary
        if webView.isLoading || webView.url.flatMap(Self.order(in:)) != id || webView.url?.path.contains(path) != true {
            var url = URLComponents(url: Self.base.appending(path: "gp/your-account/order-details"), resolvingAgainstBaseURL: false)!
            url.queryItems = [URLQueryItem(name: "orderID", value: id)]
            try await open(url.url!)
        }
        try onPage(path, "order \(id)'s page")
        let page = try await json(Self.orderPageScript, as: AmazonOrderPage.self)
        steps.append("Order \(id): \(page.items.count) item\(page.items.count == 1 ? "" : "s")\(page.total.map { ", total \(money2($0))" } ?? "")")
        guard !page.items.isEmpty else { return nil }
        let items: [[String: Any]] = page.items.map { i in
            var item: [String: Any] = ["name": i.name, "quantity": i.quantity ?? 1]
            if let asin = i.asin { item["asin"] = asin }
            if let price = i.price { item["price"] = price }
            return item
        }
        var order: [String: Any] = ["orderId": id, "items": items]
        if let placed = Self.day(page.placed) { order["orderedAt"] = Self.iso(placed) }
        if let total = page.total { order["total"] = total }
        if let payment = page.payment { order["payment"] = payment }
        return order
    }

    /// The Transactions list's lines matched to the charges: the same amount and sign, dated within 4 days, the
    /// closest first and, at the same distance, the one whose card the register's name names.
    private func match(_ lines: [AmazonTransaction]) {
        var pairs: [(days: Int, card: Int, charge: Int, line: Int)] = []
        for (l, t) in lines.enumerated() where !t.orders.isEmpty {
            guard let d = Self.day(t.date) else { continue }
            let cents = Int((t.amount * 100).rounded())
            for (c, charge) in charges.enumerated() where charge.orders.isEmpty && charge.cents == cents {
                if let sign = t.sign, !sign.isEmpty, (sign == "+") != charge.isCredit { continue }
                let days = abs(Calendar.current.dateComponents([.day], from: d, to: Freshness.date(charge.entry.date)!).day ?? 99)
                guard days <= 4 else { continue }
                let words = (charge.entry.register ?? "").split(separator: "_").map { $0.lowercased() }
                let card = words.contains { (t.card ?? "").lowercased().contains($0) } ? 0 : 1
                pairs.append((days, card, c, l))
            }
        }
        var usedLines = Set<Int>()
        for p in pairs.sorted(by: { ($0.days, $0.card) < ($1.days, $1.card) }) where charges[p.charge].orders.isEmpty && !usedLines.contains(p.line) {
            usedLines.insert(p.line)
            charges[p.charge].orders = lines[p.line].orders
            charges[p.charge].foundIn = "Transactions"
        }
    }

    /// Your Orders' orders matched to the charges left: a total equal to the charge, placed from a day before it to 30
    /// days before it (Amazon charges when it ships) — a digital order within 5 days (it is charged at once, and a
    /// channel's renewals cost the same every month).
    private func matchOrders(_ cards: [AmazonOrderCard], digital: Bool) {
        let window = digital ? -1...5 : -1...30
        for card in cards {
            guard let total = card.total, let placed = Self.day(card.placed) else { continue }
            let cents = Int((total * 100).rounded())
            let best = charges.indices.filter { charges[$0].orders.isEmpty && !charges[$0].isCredit && charges[$0].isDigital == digital && charges[$0].cents == cents }
                .compactMap { i -> (Int, Int)? in
                    let days = Calendar.current.dateComponents([.day], from: placed, to: Freshness.date(charges[i].entry.date)!).day ?? 99
                    return window.contains(days) ? (i, days) : nil
                }
                .min { $0.1 < $1.1 }
            if let (i, _) = best, !charges.contains(where: { $0.orders.contains(card.orderId) }) {
                charges[i].orders = [card.orderId]
                charges[i].foundIn = "\(digital ? "Digital Orders" : "Your Orders") (total and date)"
            }
        }
    }

    // MARK: Pages

    /// Opens a page and waits for it; when Amazon asks you to sign in on the way, waits for you, then opens it again
    /// unless Amazon brought you back to it.
    private func open(_ url: URL) async throws {
        webView.load(URLRequest(url: url))
        if try await settle(), webView.url?.path != url.path || (webView.url?.query ?? "") != (url.query ?? "") {
            webView.load(URLRequest(url: url))
            try await settle()
        }
    }

    /// Waits for the page to load, then for you when Amazon asks you to sign in or check something. True when it did.
    @discardableResult
    private func settle() async throws -> Bool {
        try await Task.sleep(for: .milliseconds(500))
        for _ in 0..<120 {
            try Task.checkCancellation()
            if !webView.isLoading, (try? await js("document.readyState")) as? String == "complete" { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        var waited = 0
        while try await asksForYou() {
            if !waitingForYou {
                waitingForYou = true
                status = "Amazon asks you to sign in or confirm it's you: do that in the page below. The lookup goes on by itself afterwards."
                AmazonLookupWindow.bringForward()
            }
            try await Task.sleep(for: .seconds(1))
            waited += 1
            if waited > 600 { throw LookupError("waited ten minutes for Amazon's sign-in") }
        }
        guard waitingForYou else { return false }
        waitingForYou = false
        try await Task.sleep(for: .seconds(1))
        return true
    }

    /// A sign-in, a two-step check, a robot check or an error page: yours to deal with, never the lookup's.
    private func asksForYou() async throws -> Bool {
        try Task.checkCancellation()
        let path = webView.url?.path ?? ""
        if path.hasPrefix("/ap/") || path.contains("validateCaptcha") || path.hasPrefix("/errors/") { return true }
        return (try? await js(Self.challengeScript)) as? Bool ?? false
    }

    private func wait() async throws { try await Task.sleep(for: .seconds(Self.pause)) }

    /// The page the lookup is about to read is the one it opened (Amazon may redirect, or a click may have moved it).
    private func onPage(_ path: String, _ what: String) throws {
        guard webView.url?.path.contains(path) == true else {
            throw LookupError("\(what) didn't stay open (the page is \(webView.url?.absoluteString ?? "empty")); Look Up Again tries once more")
        }
    }

    private func js(_ script: String) async throws -> Any? { try await webView.evaluateJavaScript(script) }

    private func json<T: Decodable>(_ script: String, as: T.Type) async throws -> T {
        guard let text = try await js(script) as? String else { throw LookupError("the page gave nothing to read") }
        return try JSONDecoder().decode(T.self, from: Data(text.utf8))
    }

    struct LookupError: LocalizedError {
        var message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    // MARK: Dates

    private static let longDay: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "MMMM d, yyyy"; return f }()
    private static let shortMonth: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "MMM d, yyyy"; return f }()
    private static let isoDay: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f }()

    /// "October 8, 2026", "Oct 8, 2026" or "Oct. 8, 2026".
    static func day(_ s: String?) -> Date? {
        guard let s = s?.replacingOccurrences(of: ".", with: "").trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        return longDay.date(from: s) ?? shortMonth.date(from: s)
    }
    static func iso(_ d: Date) -> String { isoDay.string(from: d) }

    // MARK: Scripts (they read the pages' words, not their layout, so a redesign is likelier to keep them working)

    /// A sign-in form, a robot check (captcha) or a password field on the page.
    static let challengeScript = #"!!document.querySelector('input[type=password], form[action*="validateCaptcha"], #captchacharacters, form[name="signIn"], #auth-mfa-otpcode')"#

    /// The Transactions list: each line (the smallest part of the page holding an order number and one amount) with
    /// the date heading above it, its amount and sign, its card, and its orders; and whether there is a next page.
    static let transactionsScript = """
    (() => {
      \(nextPageTest)
      const ORDER = /\\b([0-9D]\\d{2}-\\d{7}-\\d{7})\\b/g;
      const AMOUNT = /([-+−–])?\\s*\\$\\s?([\\d,]+\\.\\d{2})/g;
      const DATE = /^(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\\.? \\d{1,2}, \\d{4}$/;
      const CARD = /([A-Za-z][A-Za-z .]*?)\\s*(?:\\*{2,}|ending in|•{2,})\\s*(\\d{4})/i;
      const text = e => (e.innerText || "").replace(/\\s+/g, " ").trim();
      const els = [...document.body.querySelectorAll("*")].filter(e => !/^(script|style|noscript|template|svg)$/i.test(e.tagName));
      const found = new Map();
      for (const e of els) {
        const t = text(e);
        if (!t || t.length > 1500) continue;
        const orders = [...new Set([...t.matchAll(ORDER)].map(m => m[1]))];
        if (!orders.length) continue;
        const amounts = [...t.matchAll(AMOUNT)];
        if (amounts.length && new Set(amounts.map(a => a[2])).size === 1) found.set(e, { t, orders, amount: amounts[0] });
      }
      const keys = [...found.keys()];
      const lines = new Set(keys.filter(e => !keys.some(o => o !== e && e.contains(o))));
      const out = [];
      let date = null;
      for (const e of els) {
        if (lines.has(e)) {
          const f = found.get(e), card = f.t.match(CARD);
          const sign = f.amount[1] ? (f.amount[1] === "+" ? "+" : "-") : null;
          out.push({ date, amount: parseFloat(f.amount[2].replace(/,/g, "")), sign, card: card ? card[0] : null, orders: f.orders });
          continue;
        }
        if (![...e.children].some(c => text(c))) { const t = text(e); if (DATE.test(t)) date = t; }
      }
      const next = [...document.querySelectorAll('input, button, a, .a-button-text, [role=button]')].some(isNext);
      return JSON.stringify({ lines: out, next });
    })()
    """

    /// The Transactions list's Next page control: its words (Next page, Next →), its label, or Amazon's own widget event
    /// name (ppw-widgetEvent:DefaultNextPageNavigationEvent), not disabled.
    static let nextPageTest = #"""
    const isNext = e => {
        const words = (e.value || e.innerText || e.getAttribute("aria-label") || e.getAttribute("title") || "").replace(/\s+/g, " ").trim();
        return (/^next( page)?\s*[→›>»]?$/i.test(words) || /NextPage/i.test(e.getAttribute("name") || ""))
               && !e.disabled && !e.closest(".a-disabled, [aria-disabled=true]");
      };
    """#

    /// Presses the Transactions list's Next page control (its button's input, when the words are a label on one).
    static let nextPageScript = """
    (() => {
      \(nextPageTest)
      const all = [...document.querySelectorAll('input, button, a, .a-button-text, [role=button]')].filter(isNext);
      const next = all.find(e => /NextPage/i.test(e.getAttribute("name") || "")) || all[0];
      if (!next) return false;
      (next.closest(".a-button")?.querySelector("input, button") || next).click();
      return true;
    })()
    """

    /// The newer Transactions list's Show more (Load more, See more) button pressed, else the page scrolled to its end:
    /// "clicked" or "scrolled".
    static let moreScript = #"""
    (() => {
      const more = [...document.querySelectorAll('button, a, input[type=submit], [role=button], .a-button-text')]
        .find(e => /^((show|load|see|view) more( transactions)?|more transactions)$/i.test((e.value || e.innerText || e.getAttribute("aria-label") || "").replace(/\s+/g, " ").trim())
                   && !e.disabled && !e.closest(".a-disabled, [aria-disabled=true]"));
      if (more) { (more.closest(".a-button")?.querySelector("input, button") || more).click(); return "clicked"; }
      window.scrollTo(0, document.body.scrollHeight);
      return "scrolled";
    })()
    """#

    /// The page's controls in words, without numbers or amounts (for Steps, when the list wouldn't page): the last 12.
    static let controlsScript = #"""
    (() => {
      const words = [...document.querySelectorAll('button, a, input[type=submit], [role=button], .a-button-text')]
        .map(e => (e.value || e.innerText || e.getAttribute("aria-label") || "").replace(/\s+/g, " ").trim())
        .filter(t => t && t.length <= 40 && !/\d{2}|\$/.test(t));
      return [...new Set(words)].slice(-12).join(" | ");
    })()
    """#

    /// Your Orders: each order card (the smallest part of the page holding one order number and "Order placed") with
    /// its date and total.
    static let orderListScript = #"""
    (() => {
      const ORDER = /\b([0-9D]\d{2}-\d{7}-\d{7})\b/g;
      const text = e => (e.innerText || "").replace(/\s+/g, " ").trim();
      const found = new Map();
      for (const e of document.body.querySelectorAll("*")) {
        const t = text(e);
        if (!t || t.length > 4000 || !/order placed|ordered on/i.test(t)) continue;
        const orders = [...new Set([...t.matchAll(ORDER)].map(m => m[1]))];
        if (orders.length === 1) found.set(e, { t, orderId: orders[0] });
      }
      const keys = [...found.keys()];
      return JSON.stringify(keys.filter(e => !keys.some(o => o !== e && e.contains(o))).map(e => {
        const f = found.get(e);
        const placed = f.t.match(/(?:order placed|ordered on)\s*([A-Z][a-z]+\.? \d{1,2}, \d{4})/i);
        const total = f.t.match(/total\s*\$\s?([\d,]+\.\d{2})/i);
        return { orderId: f.orderId, placed: placed ? placed[1] : null, total: total ? parseFloat(total[1].replace(/,/g, "")) : null };
      }));
    })()
    """#

    /// An order's page: when it was placed, its total, how it was paid, and its items — each product link's name, its
    /// ASIN, and the price and quantity in the part of the page around it that names no other product.
    static let orderPageScript = #"""
    (() => {
      const text = e => (e.innerText || "").replace(/\s+/g, " ").trim();
      const body = text(document.body);
      const placed = body.match(/(?:order placed|ordered on)\s*([A-Z][a-z]+\.? \d{1,2}, \d{4})/i);
      const total = body.match(/grand total:?\s*\$\s?([\d,]+\.\d{2})/i) || body.match(/order total:?\s*\$\s?([\d,]+\.\d{2})/i);
      const payment = body.match(/((?:visa|mastercard|american express|amex|discover)[a-z ]{0,20}?(?:ending in|\*{2,})\s*\d{4})/i);
      const ASIN = /\/(?:dp|gp\/product|gp\/video\/detail|video\/detail)\/([A-Z0-9]{10})/;
      const PRODUCTS = 'a[href*="/dp/"], a[href*="/gp/product/"], a[href*="/video/detail/"]';
      const links = [...document.querySelectorAll(PRODUCTS)];
      const items = new Map();
      for (const a of links) {
        const m = (a.getAttribute("href") || "").match(ASIN);
        const name = text(a);
        if (!m || items.has(m[1]) || name.length < 4 || /buy it again|view your item|write a (product )?review|track package|return or replace|get product support/i.test(name)) continue;
        // The item's area: the largest part around the link that names no other product. Its price is the first in
        // the smallest part holding one; its quantity, a "Qty: 2" or the badge on its picture, anywhere in it.
        let price = null, quantity = 1, area = null;
        for (let box = a.parentElement, i = 0; box && i < 8; box = box.parentElement, i++) {
          const others = [...box.querySelectorAll(PRODUCTS)]
            .map(x => ((x.getAttribute("href") || "").match(ASIN) || [])[1]).filter(x => x && x !== m[1]);
          if (others.length) break;
          area = box;
          const p = price === null && text(box).match(/\$\s?([\d,]+\.\d{2})/);
          if (p) price = parseFloat(p[1].replace(/,/g, ""));
        }
        if (area) {
          const badge = area.querySelector('[class*="qty"]');
          const q = text(area).match(/(?:qty|quantity):?\s*(\d+)/i) || (badge && text(badge).match(/^(\d+)$/));
          if (q) quantity = parseInt(q[1]);
        }
        items.set(m[1], { name, asin: m[1], quantity, price });
      }
      // Offers on the page (Amazon's cards) are product links too: an item has a price when the others do.
      let list = [...items.values()].filter(i => !/business card|credit card|store card|prime visa|amazon visa|rewards visa/i.test(i.name));
      if (list.some(i => i.price !== null)) list = list.filter(i => i.price !== null);
      // No product links (a channel's renewal, some digital orders): the item titles Amazon marks as such.
      if (!list.length) {
        const names = new Set();
        for (const t of document.querySelectorAll('[data-component="itemTitle"], .yohtmlc-product-title, .yohtmlc-item a')) {
          const name = text(t);
          if (name.length < 3 || names.has(name)) continue;
          names.add(name);
          let price = null;
          for (let box = t.parentElement, i = 0; box && i < 6 && price === null; box = box.parentElement, i++) {
            const p = text(box).match(/\$\s?([\d,]+\.\d{2})/);
            if (p) price = parseFloat(p[1].replace(/,/g, ""));
          }
          list.push({ name, asin: null, quantity: 1, price });
        }
      }
      return JSON.stringify({ placed: placed ? placed[1] : null, total: total ? parseFloat(total[1].replace(/,/g, "")) : null,
                              payment: payment ? payment[1] : null, items: list });
    })()
    """#
}

// MARK: - The window

/// The lookup's own window (one at a time): the charges, what was found, and Amazon's pages below.
@MainActor
enum AmazonLookupWindow {
    private static var window: NSWindow?
    private static var lookup: AmazonLookup?
    private static var closing: NSObjectProtocol?

    /// The window for these charges: the lookup runs at once (scan), or you attach orders one by one, Your Orders open.
    static func open(_ entries: [SpendingEntry], scan: Bool = true, attached: @escaping ([SpendingEntry]) -> Void) {
        lookup?.stop()
        let l = AmazonLookup(entries: entries, attached: attached)
        lookup = l
        let host = NSHostingController(rootView: AmazonLookupView(lookup: l))
        if let window {
            window.contentViewController = host
        } else {
            let w = NSWindow(contentViewController: host)
            w.title = "Amazon Order Lookup"
            w.setContentSize(NSSize(width: 1000, height: 860))
            w.isReleasedWhenClosed = false
            w.center()
            closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated { lookup?.stop() }
            }
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        if scan { l.start() } else { l.browse() }
    }

    static func bringForward() {
        #if DEBUG
        if UserDefaults.standard.string(forKey: "amazonBase") != nil { return }   // a self-test: leave the screen alone
        #endif
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct AmazonWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

struct AmazonLookupView: View {
    var lookup: AmazonLookup
    @State private var showSteps = false
    /// The order numbers typed on each charge's row.
    @State private var typed: [String: String] = [:]

    /// One order for this charge: its number typed or pasted (or its page's link), or the order shown below.
    @ViewBuilder
    private func attachControls(_ c: AmazonLookupCharge) -> some View {
        let text = Binding(get: { typed[c.id] ?? "" }, set: { typed[c.id] = $0 })
        HStack(spacing: 4) {
            TextField("Order # or link", text: text)
                .textFieldStyle(.roundedBorder).frame(width: 170)
                .onSubmit { lookup.attach(text.wrappedValue, to: c.id) }
            Button("Attach") { lookup.attach(text.wrappedValue, to: c.id) }
                .disabled(AmazonLookup.orderNumbers(in: text.wrappedValue).isEmpty)
                .help("Attach this order (or these, comma-separated) to the charge, in place of what it has; its page is read unless it is known")
            Button("This Order") { lookup.attach(lookup.shownOrder ?? "", to: c.id) }
                .disabled(lookup.shownOrder == nil)
                .help(lookup.shownOrder.map { "Attach order \($0), shown below, to this charge" } ?? "Open an order below (Your Orders ▸ View order details) to attach it here")
        }
        .controlSize(.small)
        .disabled(lookup.running)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Amazon Order Lookup").font(.title3.weight(.semibold))
                Spacer()
                if lookup.running {
                    ProgressView().controlSize(.small)
                    Button("Stop") { lookup.stop() }
                } else {
                    Button("Look Up") { lookup.start() }.disabled(lookup.charges.isEmpty)
                        .help("Find these charges' orders on Amazon's Transactions list and Your Orders")
                    Button("Your Orders") { lookup.browse() }
                        .help("Open Your Orders below, to find an order and attach it to a charge (This Order)")
                    Button("Digital Orders") { lookup.browse(digital: true) }
                        .help("Open Your Orders' Digital Orders tab below: Prime Video rentals, purchases and channels, Kindle books")
                }
                Button("Sign Out of Amazon") { Task { await lookup.signOut() } }
                    .disabled(lookup.running)
                    .help("Clear amazon.com's cookies from this window: the next lookup asks you to sign in")
            }
            Text(lookup.query).font(.callout).foregroundStyle(.secondary)
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    GridRow {
                        Text("Date"); Text("From"); Text("Statement"); Text("Amount").gridColumnAlignment(.trailing); Text("Orders found")
                        Text("Attach an order")
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(lookup.charges) { c in
                        GridRow {
                            Text(shortDay(c.entry.date)).monospacedDigit()
                            Text(c.entry.register ?? c.entry.sourceTitle).foregroundStyle(.secondary)
                            Text(c.entry.payee ?? "").lineLimit(1).frame(maxWidth: 320, alignment: .leading)
                            Text(money2(c.entry.amount)).monospacedDigit()
                            Text(c.orders.isEmpty ? (lookup.running ? "…" : "—") : c.orders.joined(separator: ", ") + (c.foundIn.map { " (\($0))" } ?? ""))
                                .foregroundStyle(c.orders.isEmpty ? .secondary : .primary).textSelection(.enabled)
                            attachControls(c)
                        }
                        .font(.callout)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 170)
            HStack(alignment: .firstTextBaseline) {
                Label(lookup.status.isEmpty ? "Starting…" : lookup.status,
                      systemImage: lookup.waitingForYou ? "person.badge.key" : lookup.problem != nil ? "exclamationmark.triangle.fill" : "magnifyingglass")
                    .foregroundStyle(lookup.waitingForYou || lookup.problem != nil ? Color.orange : .primary)
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer()
                if !lookup.steps.isEmpty { Toggle("Steps", isOn: $showSteps).toggleStyle(.button).controlSize(.small) }
            }
            if showSteps {
                Text(lookup.steps.joined(separator: "\n")).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            AmazonWebView(webView: lookup.webView)
                // The page is the lookup's while it reads (a click would move it); yours while Amazon asks you something.
                .allowsHitTesting(!lookup.running || lookup.waitingForYou)
                .frame(minHeight: 380)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            Text("You sign in to Amazon in the page above yourself; MxAcctMGR never sees or keeps your password, and leaves sign-in and robot checks to you. Look Up reads Your Payments ▸ Transactions, then Your Orders (Digital Orders for Prime Video) and each order's page, one page every \(AmazonLookup.pause.formatted()) seconds; Attach reads only the order you name. Amazon's Conditions of Use don't allow robots: this runs only when you ask, and may stop working when Amazon changes its pages.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(minWidth: 820, minHeight: 680)
    }
}
