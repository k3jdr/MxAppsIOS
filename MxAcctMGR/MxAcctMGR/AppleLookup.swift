//
//  AppleLookup.swift
//  MxAcctMGR
//
//  Apple Purchase Lookup (right-click APPLE.COM/BILL charges in Spending Analysis ▸ Entries or Target Accounts ▸ Show
//  Entries… ▸ Look Up Apple Purchases…): what the Apple charges bought — the App Store, in-app purchases,
//  subscriptions, iCloud+, Apple TV — read from your Apple Account's purchase history (reportaproblem.apple.com) in a
//  window of the app's own. Apple e-mails a receipt for some purchases, not every renewal, and has no API for an
//  account's purchases (V056).
//
//  The window is a web view (WebKit). You sign in to your Apple Account there yourself — your password, and the code
//  Apple shows on your devices (Sign in with Passkey can't work here: Apple offers Touch ID for a passkey only in
//  Safari and its own apps): the app never sees, types or keeps them (the sign-in stays in the web view's cookies, as
//  in Safari; Sign Out of Apple clears them). While the page shows your purchase history, a script in it keeps what
//  Apple's own page receives from reportaproblem.apple.com about your purchases (never the sign-in, which is Apple's
//  sign-in page's, not this one's). The lookup:
//    1. waits for the purchase history (you signing in);
//    2. scrolls it back past the oldest selected charge — Apple's page loads older purchases as it is scrolled, or from
//       its Load More button — one step every 2 seconds, at most 80;
//    3. sends every bill read (its order ID, date, total, how it was paid, and each item's name, detail and amount) to
//       the accounts service (POST /spending/apple/attach), which matches every Apple charge it can: the bill of its
//       amount in the week before it, else the bills that add up to it.
//  Bought in the Entries tab then shows what each charge bought. A purchase a family member made with Family Sharing is
//  in their purchase history, not yours: its charge stays without a bill. It runs only when you ask, and may stop
//  working when Apple changes its page: Steps says what it read.
//

import AppKit
import SwiftUI
import WebKit

@MainActor
@Observable
final class AppleLookup {
    static let home = URL(string: "https://reportaproblem.apple.com/")!
    static let pause = 2.0, maxScrolls = 80
    /// How long the lookup waits for you to sign in.
    static let signInWait = 900

    var charges: [SpendingEntry]
    var status = ""
    var waitingForYou = false
    var running = false
    var problem: String?
    var steps: [String] = []
    /// Each charge as the service answered after the bills were sent: with what it bought, when a bill matched it.
    var answered: [String: SpendingEntry] = [:]
    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private let popups = Popups()
    @ObservationIgnored private lazy var loads = Loads { [weak self] line in self?.steps.append(line) }
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let attached: ([SpendingEntry]) -> Void

    init(entries: [SpendingEntry], attached: @escaping ([SpendingEntry]) -> Void) {
        charges = entries.filter(\.isAppleCharge).sorted { $0.date > $1.date }
        self.attached = attached
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()     // the sign-in stays between lookups, as in Safari
        config.applicationNameForUserAgent = "Version/18.5 Safari/605.1.15"     // Apple's pages ask for a browser
        config.userContentController.addUserScript(WKUserScript(source: Self.captureScript, injectionTime: .atDocumentStart,
                                                                forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: config)
        webView.uiDelegate = popups
        webView.navigationDelegate = loads
    }

    /// The query, in words: how many charges, their dates and amounts.
    var query: String {
        guard let first = charges.map(\.date).min(), let last = charges.map(\.date).max() else {
            return "None of the selected entries is an Apple charge (APPLE.COM/BILL): the App Store, a subscription, iCloud+."
        }
        return "\(charges.count) Apple \(charges.count == 1 ? "charge" : "charges"), \(shortDay(first))\(first == last ? "" : " – \(shortDay(last))"): "
            + charges.prefix(8).map { money2($0.amount) }.joined(separator: ", ") + (charges.count > 8 ? " …" : "")
    }

    func start() {
        guard !running, !charges.isEmpty else { return }
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

    /// Clears Apple's cookies and data from the app's web view: the next lookup asks you to sign in.
    func signOut() async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types).filter { $0.displayName.localizedCaseInsensitiveContains("apple") }
        await store.removeData(ofTypes: types, for: records)
        status = "Signed out of Apple in this window (\(records.count) site record\(records.count == 1 ? "" : "s") cleared)."
        webView.load(URLRequest(url: Self.home))
    }

    // MARK: The lookup

    private func run() async throws {
        let back = Freshness.date(charges.map(\.date).min())!.addingTimeInterval(-8 * 86400)
        if webView.url?.host != Self.home.host { webView.load(URLRequest(url: Self.home)) }
        // 1. The purchase history: once you are signed in, Apple's page loads it.
        var read = try await bills()
        var waited = 0
        while read.bills.isEmpty {
            if !waitingForYou {
                waitingForYou = true
                status = "Sign in to your Apple Account in the page below with your password, then the code Apple shows on this Mac or your iPhone (Sign in with Passkey doesn't work in an app's window). The lookup goes on by itself once your purchases show."
                AppleLookupWindow.bringForward()
            }
            try await Task.sleep(for: .seconds(Self.pause))
            waited += Int(Self.pause)
            if waited > Self.signInWait {
                throw LookupError("waited \(Self.signInWait / 60) minutes for your purchase history" + (read.captured > 0
                    ? ": the page sent \(read.captured) answer\(read.captured == 1 ? "" : "s") (\(read.urls.joined(separator: ", "))) but none read as purchases — Apple may have changed its page"
                    : " (sign in, and open Purchases if the page asks)"))
            }
            read = try await bills()
        }
        waitingForYou = false
        steps.append("Purchase history: \(read.bills.count) bills from \(read.captured) of the page's answers (\(read.urls.joined(separator: ", ")))")
        // 2. Older purchases, back past the oldest charge.
        var still = 0
        for step in 1...Self.maxScrolls {
            guard let oldest = read.oldest, oldest > back else { break }
            status = "Reading your purchase history: \(read.bills.count) bills, back to \(shortDay(Self.iso(oldest)))…"
            let how = try await webView.evaluateJavaScript(Self.moreScript) as? String ?? ""
            try await Task.sleep(for: .seconds(Self.pause))
            let next = try await bills()
            if next.bills.count == read.bills.count {
                still += 1
                if still >= 3 {
                    steps.append("Nothing older came after \(step) steps (\(how == "clicked" ? "pressed Load More" : how == "none" ? "nothing to scroll" : "scrolled to the end")): the history may start there")
                    break
                }
            } else {
                still = 0
            }
            read = next
        }
        let untotalled = read.bills.filter { $0["total"] == nil || $0["total"] is NSNull }.count
        steps.append("Read \(read.bills.count) bills\(read.oldest.map { " back to \(shortDay(Self.iso($0)))" } ?? "")"
                     + (untotalled > 0 ? "; \(untotalled) without a total (they can't be matched by amount)" : ""))
        // 3. The bills to the accounts service, which matches the charges.
        status = "Matching the bills to your Apple charges…"
        let answer = try await SpendingClient.attachApple(invoices: read.bills, charges: charges)
        for e in answer.entries { answered[e.id] = e }
        attached(answer.entries)
        let found = charges.filter { answered[$0.id]?.appleItems != nil }.count
        if !answer.unmatched.isEmpty {
            steps.append("Apple charges in those dates without a bill: " + answer.unmatched.prefix(20).map { "\(shortDay($0.date)) \(money2($0.amount))" }.joined(separator: ", ")
                         + (answer.unmatched.count > 20 ? " …" : ""))
        }
        status = "\(found) of \(charges.count) selected charge\(charges.count == 1 ? "" : "s") matched to their bills (\(answer.matched) newly, of every Apple charge). "
            + (answer.unmatched.isEmpty ? "Every Apple charge in those dates has its bill." : "\(answer.unmatched.count) Apple charge\(answer.unmatched.count == 1 ? "" : "s") in those dates \(answer.unmatched.count == 1 ? "has" : "have") none (a family member's purchase, or one the history didn't show): Steps lists them.")
    }

    private struct Read {
        var captured = 0
        var urls: [String] = []
        /// Each bill as POST /spending/apple/attach takes it.
        var bills: [[String: Any]] = []
        var oldest: Date? { bills.compactMap { Freshness.date($0["date"] as? String) }.min() }
    }

    /// What the page has received about your purchases so far, as bills.
    private func bills() async throws -> Read {
        try Task.checkCancellation()
        guard webView.url?.host == Self.home.host, let text = try? await webView.evaluateJavaScript(Self.billsScript) as? String,
              let o = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return Read() }
        var bills = o["bills"] as? [[String: Any]] ?? []
        // The page's own data for a bill is kept with it, unless it is large.
        for i in bills.indices {
            if let raw = bills[i]["raw"], (try? JSONSerialization.data(withJSONObject: raw))?.count ?? 0 > 20_000 { bills[i]["raw"] = nil }
        }
        return Read(captured: o["captured"] as? Int ?? 0, urls: o["urls"] as? [String] ?? [], bills: bills)
    }

    static func iso(_ d: Date) -> String { isoDay.string(from: d) }

    struct LookupError: LocalizedError {
        var message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// A page that didn't load, for Steps.
    private final class Loads: NSObject, WKNavigationDelegate {
        let note: @MainActor (String) -> Void
        init(_ note: @escaping @MainActor (String) -> Void) { self.note = note }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            failed(webView, error)
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(webView, error) }
        private func failed(_ webView: WKWebView, _ error: Error) {
            let e = error as NSError
            guard e.code != NSURLErrorCancelled else { return }     // a page that moved on to the next
            note("\(webView.url?.host ?? "a page") didn't load: \(e.localizedDescription) (\(e.domain) \(e.code))")
        }
    }

    /// Apple's sign-in may open in a new window: it opens in this one.
    private final class Popups: NSObject, WKUIDelegate {
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            webView.load(action.request)
            return nil
        }
    }

    // MARK: The page's scripts

    /// At the start of each reportaproblem.apple.com page (not Apple's sign-in, a page of its own): keeps the JSON its
    /// own requests to reportaproblem.apple.com's /api/ get back that speak of purchases (window.__mxPurchases), never a
    /// request's body or a sign-in call's answer.
    static let captureScript = #"""
    (() => {
      if (location.hostname !== "reportaproblem.apple.com" || window.__mxPurchases) return;
      const kept = window.__mxPurchases = [];
      const wanted = url => {
        try {
          const u = new URL(url, location.href);
          return u.hostname === location.hostname && /\/api\//.test(u.pathname) && !/auth|login|signin|sign-in|token|password/i.test(u.pathname);
        } catch (e) { return false; }
      };
      const keep = (url, text) => {
        if (kept.length >= 400 || typeof text !== "string" || text.length > 5000000 || !/plis|invoice|purchase/i.test(text)) return;
        try { kept.push({ url: String(url), data: JSON.parse(text) }); } catch (e) {}
      };
      const fetch0 = window.fetch;
      window.fetch = function (input, init) {
        const url = typeof input === "string" ? input : (input && input.url) || "";
        return fetch0.apply(this, arguments).then(r => {
          if (wanted(url)) r.clone().text().then(t => keep(url, t)).catch(() => {});
          return r;
        });
      };
      const open0 = XMLHttpRequest.prototype.open, send0 = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function (method, url) { this.__mxUrl = url; return open0.apply(this, arguments); };
      XMLHttpRequest.prototype.send = function () {
        if (wanted(this.__mxUrl)) this.addEventListener("load", () => {
          try { keep(this.__mxUrl, this.responseType === "json" ? JSON.stringify(this.response) : this.responseText); } catch (e) {}
        });
        return send0.apply(this, arguments);
      };
    })();
    """#

    /// The bills in what the page kept: each object with a date and a list of line items — Apple's purchase history
    /// (POST /api/purchase/search) gives purchases [{weborder, invoiceDate, purchaseDate, invoiceAmount, plis:
    /// [{amountPaid, pliDate, localizedContent: {nameForDisplay, detailForDisplay}}]}] — its order ID, date (this Mac's
    /// day), total (tax in), how it was paid, its items' names, details and amounts, and the bill's own data without
    /// account or device ids, addresses or e-mail. Free downloads and trials (nothing billed) are left out.
    static let billsScript = #"""
    (() => {
      const kept = window.__mxPurchases || [];
      const money = v => {
        if (v === null || v === undefined || v === "") return null;
        if (typeof v === "number") return v;
        if (typeof v === "object") return money(v.amount ?? v.value ?? v.displayAmount ?? null);
        const s = String(v).replace(/[,\s]/g, "");
        const m = s.match(/^(-)?[^\d-]*(-)?(\d+(?:\.\d+)?)/);
        return m ? (m[1] || m[2] ? -1 : 1) * parseFloat(m[3]) : null;
      };
      const day = v => {
        if (v === null || v === undefined || v === "") return null;
        if (typeof v === "string" && /^\d{4}-\d{2}-\d{2}$/.test(v)) return v;
        const d = new Date(typeof v === "number" || /^\d{10,13}$/.test(String(v)) ? Number(v) : String(v));
        if (isNaN(d)) return null;
        return new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 10);
      };
      const pick = (o, keys) => { for (const k of keys) if (o && o[k] !== undefined && o[k] !== null && o[k] !== "") return o[k]; return null; };
      const words = v => typeof v === "string" ? v : v && typeof v === "object" ? String(v.displayName || v.name || v.description || v.type || "") : "";
      const SECRET = /dsid|guid|e-?mail|address|phone|token|cookie|person|appleid|accountid|apple_id|account_id|artwork|supporturl/i;
      const clean = (v, depth) => {
        if (depth > 6) return null;
        if (Array.isArray(v)) return v.slice(0, 60).map(x => clean(x, depth + 1));
        if (v && typeof v === "object") { const o = {}; for (const [k, x] of Object.entries(v)) if (!SECRET.test(k)) o[k] = clean(x, depth + 1); return o; }
        return v;
      };
      const LISTS = ["plis", "lineItems", "purchaseLineItems", "items"];
      const bills = new Map();
      const walk = (v, depth) => {
        if (!v || typeof v !== "object" || depth > 9) return;
        if (Array.isArray(v)) { v.forEach(x => walk(x, depth + 1)); return; }
        const list = LISTS.map(k => v[k]).find(x => Array.isArray(x) && x.length && x[0] && typeof x[0] === "object");
        const date = day(pick(v, ["invoiceDate", "purchaseDate", "orderDate", "date"]));
        if (list && date) {
          const items = list.map(p => {
            const c = p.localizedContent || p.content || {};
            return {
              name: String(pick(c, ["nameForDisplay", "name", "title"]) || pick(p, ["nameForDisplay", "itemName", "name", "title", "description"]) || "").trim(),
              detail: String(pick(c, ["detailForDisplay", "subtitle"]) || pick(p, ["detailForDisplay", "subtitle"]) || "").trim(),
              amount: money(pick(p, ["amountPaid", "price", "amount", "total"])),
              date: day(pick(p, ["pliDate", "purchaseDate", "date"]))
            };
          }).filter(i => i.name);
          const id = String(pick(v, ["weborder", "webOrder", "orderId", "orderID", "invoiceId", "invoiceNumber", "documentNumber", "purchaseId"]) || "");
          const total = money(pick(v, ["invoiceAmount", "estimatedTotalAmount", "totalAmount", "total", "amountPaid", "amount"]));
          const key = id || date + "|" + total + "|" + items.map(i => i.name).join("|");
          // A free download or a free trial's start bills nothing.
          if (items.length && !(total === 0 || total === null && items.every(i => !i.amount))) bills.set(key, { orderId: id || null, date, total, payment: words(pick(v, ["paymentMethod", "paymentMethodDisplay", "payment", "billingMethod"])) || null,
                                             items, raw: clean(v, 0) });
          return;
        }
        Object.values(v).forEach(x => walk(x, depth + 1));
      };
      kept.forEach(k => walk(k.data, 0));
      return JSON.stringify({ captured: kept.length, urls: [...new Set(kept.map(k => k.url.replace(/^https?:\/\/[^/]+/, "").replace(/\?.*/, "")))].slice(0, 6),
                              bills: [...bills.values()] });
    })()
    """#

    /// Loads older purchases: presses a Load More (Show More, See More) button, else scrolls every scrolled part of the
    /// page to its end; answers what it did.
    static let moreScript = #"""
    (() => {
      const more = [...document.querySelectorAll("button, a, [role=button]")]
        .find(b => /^(load|show|see) more|more purchases/i.test((b.innerText || b.getAttribute("aria-label") || "").trim()));
      if (more && !more.disabled) { more.click(); return "clicked"; }
      let n = 0;
      for (const e of [document.scrollingElement, ...document.querySelectorAll("*")]) {
        if (!e || e.scrollHeight <= e.clientHeight + 10) continue;
        if (e !== document.scrollingElement && !/(auto|scroll)/.test(getComputedStyle(e).overflowY)) continue;
        e.scrollTop = e.scrollHeight;
        n++;
      }
      return n ? "scrolled" : "none";
    })()
    """#
}

// MARK: - The window

/// The lookup's own window (one at a time): the charges, what was found, and Apple's page below.
@MainActor
enum AppleLookupWindow {
    private static var window: NSWindow?
    private static var lookup: AppleLookup?
    private static var closing: NSObjectProtocol?

    /// The window for these charges; the lookup starts at once and waits for you to sign in if Apple asks.
    static func open(_ entries: [SpendingEntry], attached: @escaping ([SpendingEntry]) -> Void) {
        lookup?.stop()
        let l = AppleLookup(entries: entries, attached: attached)
        lookup = l
        let host = NSHostingController(rootView: AppleLookupView(lookup: l))
        if let window {
            window.contentViewController = host
        } else {
            let w = NSWindow(contentViewController: host)
            w.title = "Apple Purchase Lookup"
            w.setContentSize(NSSize(width: 1000, height: 860))
            w.isReleasedWhenClosed = false
            w.center()
            closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated { lookup?.stop() }
            }
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        l.start()
    }

    static func bringForward() {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct AppleWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

struct AppleLookupView: View {
    var lookup: AppleLookup
    @State private var showSteps = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Apple Purchase Lookup").font(.title3.weight(.semibold))
                Spacer()
                if lookup.running {
                    ProgressView().controlSize(.small)
                    Button("Stop") { lookup.stop() }
                } else {
                    Button("Look Up") { lookup.start() }.disabled(lookup.charges.isEmpty)
                        .help("Read your purchase history back past these charges and match every Apple charge to its bill")
                }
                Button("Sign Out of Apple") { Task { await lookup.signOut() } }
                    .disabled(lookup.running)
                    .help("Clear Apple's cookies from this window: the next lookup asks you to sign in")
            }
            Text(lookup.query).font(.callout).foregroundStyle(.secondary)
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    GridRow {
                        Text("Date"); Text("From"); Text("Target account"); Text("Amount").gridColumnAlignment(.trailing); Text("Bought")
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(lookup.charges) { c in
                        let now = lookup.answered[c.id] ?? c
                        GridRow {
                            Text(shortDay(c.date)).monospacedDigit()
                            Text(c.register ?? c.sourceTitle).foregroundStyle(.secondary)
                            Text(c.payee ?? c.statementName ?? "").lineLimit(1).frame(maxWidth: 220, alignment: .leading)
                            Text(money2(c.amount)).monospacedDigit()
                            Text(now.bought ?? (lookup.running ? "…" : "—"))
                                .foregroundStyle(now.bought == nil ? .secondary : .primary).lineLimit(1)
                                .help(now.boughtDetail ?? "")
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
            AppleWebView(webView: lookup.webView)
                // The page is the lookup's while it scrolls; yours while it waits for you to sign in.
                .allowsHitTesting(!lookup.running || lookup.waitingForYou)
                .frame(minHeight: 380)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            Text("You sign in to your Apple Account in the page above yourself, with your password and the code Apple shows you (Sign in with Passkey only works in Safari); MxAcctMGR never sees or keeps them. Look Up reads what Apple's purchase history page receives about your purchases, scrolling it back past the oldest charge one step every \(AppleLookup.pause.formatted()) seconds, and matches each Apple charge to the bill of its amount. It runs only when you ask, and may stop working when Apple changes its page.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(minWidth: 820, minHeight: 680)
    }
}
