//
//  TargetAccountEntries.swift
//  MxAcctMGR
//
//  Banking ▸ Target Accounts ▸ Show Entries… (a row's context menu, or double-click the row), in a window of its own
//  (moved, resized and kept open beside the books, one a target account; the last size and place are remembered): the
//  checks and card charges behind a target account's This year — or, with All years, its Total paid — newest first
//  (GET /payees/<id>/entries). Above the table, each month's sum (each year's, with All years) and each Spending
//  Analysis category's: press one to show only its entries. An Amazon charge matched to its order shows what it
//  bought, all of it on hover. Right-click entries for Spending Analysis's menu — tag them, set their category or
//  driver, change their expense account, allocate the target account — or double-click one to tag it: the same
//  entries as Spending Analysis gives them (GET /spending/targets/<id>/entries) carry the changes.
//

import AppKit
import SwiftUI

/// One check or card charge with a target account as its target.
struct TargetEntry: Decodable, Identifiable, Hashable {
    var source: String
    var entryId: Int
    var date: String
    var register: String
    var kind: String?
    var checkNo: String?
    /// The statement's name for it (else the register's).
    var name: String?
    var memo: String?
    /// Spent (negative: money that came in).
    var amount: Double
    /// Its expense account.
    var category: String?
    /// Its Spending Analysis category: its own tag's, else the target account's.
    var spending: String?
    var orders: String?
    /// What an Amazon charge bought, one item a line.
    var bought: String?

    var id: String { "\(source)-\(entryId)" }
}

struct TargetEntries: Decodable {
    var id: Int
    var name: String
    /// Nil: all years.
    var year: Int?
    var total: Double
    var entries: [TargetEntry]
}

extension BankClient {
    /// The entries behind a target account's This year in `year` (nil: every year's, its Total paid).
    static func payeeEntries(_ id: Int, year: Int?) async throws -> TargetEntries {
        try await AccountsClient.request("GET", "/payees/\(id)/entries?year=\(year.map(String.init) ?? "all")", as: TargetEntries.self)
    }
}

extension SpendingClient {
    private struct Entries: Decodable { var entries: [SpendingEntry] }
    /// A target account's entries in `year` (nil: every year) as Spending Analysis gives them, to tag.
    static func targetEntries(_ id: Int, year: Int?) async throws -> [SpendingEntry] {
        try await AccountsClient.request("GET", "/spending/targets/\(id)/entries?year=\(year.map(String.init) ?? "all")", as: Entries.self).entries
    }
}

/// Show Entries…' windows: one a target account, brought forward when it is open already.
@MainActor
enum TargetEntriesWindow {
    private static var windows: [Int: NSWindow] = [:]
    private static var closing: [Int: NSObjectProtocol] = [:]
    /// Where the last one closed: its size and place.
    private static let frameName = "TargetEntriesWindow"

    static func open(_ payee: Payee, year: Int, changed: @escaping () -> Void) {
        if let w = windows[payee.id] { w.makeKeyAndOrderFront(nil); return }
        let host = NSHostingController(rootView: TargetEntriesView(payee: payee, year: year, changed: changed) {
            windows[payee.id]?.close()
        })
        host.sizingOptions = [.minSize]     // as wide and tall as you drag it, not the table's ideal size
        let w = NSWindow(contentViewController: host)
        w.title = "\(payee.name): Entries"
        w.styleMask.insert(.resizable)
        w.isReleasedWhenClosed = false
        if !w.setFrameUsingName(frameName) {
            w.setContentSize(NSSize(width: 1240, height: 760))
            w.center()
        }
        // Another target account's window is open: this one goes just below and right of it.
        if let other = windows.values.first(where: \.isVisible) {
            w.setFrameTopLeftPoint(NSPoint(x: other.frame.minX + 24, y: other.frame.maxY - 24))
        }
        closing[payee.id] = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated {
                w.saveFrame(usingName: frameName)
                windows[payee.id] = nil
                if let o = closing.removeValue(forKey: payee.id) { NotificationCenter.default.removeObserver(o) }
            }
        }
        windows[payee.id] = w
        w.makeKeyAndOrderFront(nil)
    }
}

struct TargetEntriesView: View {
    let payee: Payee
    /// After a change to the target account's entries or allocation: Target Accounts reads its book again.
    var changed: () -> Void = {}
    /// Closes its window.
    var close: () -> Void
    /// The year shown (nil: all years); it starts at the one Target Accounts shows.
    @State private var year: Int?
    @State private var data: TargetEntries?
    @State private var error: String?
    /// The month ("2026-10") or, with all years, the year ("2025") pressed above the table.
    @State private var period: String?
    /// The Spending Analysis category pressed ("—": none).
    @State private var spending: String?
    @State private var search = ""
    @State private var selected = Set<TargetEntry.ID>()
    /// The categories, drivers, family members and expense accounts the menus offer.
    @State private var setup: SpendingSetup?
    /// Each entry as Spending Analysis gives it, which the menus change (none for a target account that isn't spending).
    @State private var editable: [TargetEntry.ID: SpendingEntry] = [:]
    @State private var tagging: [SpendingEntry]?
    @State private var refiling: [SpendingEntry]?
    @State private var allocating: RuleTarget?
    /// Set Category / Set Driver / Clear Tags: saving, and what went wrong.
    @State private var saving = false
    @State private var bulkError: String?

    private static let thisYear = Calendar.current.component(.year, from: .now)
    private static let none = "—"

    init(payee: Payee, year: Int, changed: @escaping () -> Void = {}, close: @escaping () -> Void) {
        self.payee = payee
        self.changed = changed
        self.close = close
        _year = State(initialValue: year)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if let data {
                    Text("\(data.entries.count) \(data.entries.count == 1 ? "entry" : "entries") \(data.year.map { "in \($0)" } ?? "in all years"): \(money2(data.total))\(data.year == nil ? " (Total paid)" : " (This year)")")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Year", selection: $year) {
                    ForEach(((Self.thisYear - 5)...Self.thisYear).reversed(), id: \.self) { y in Text(verbatim: "\(y)").tag(Optional(y)) }
                    Text("All years").tag(Int?.none)
                }
                .frame(maxWidth: 180)
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
            if let data {
                if !data.entries.isEmpty {
                    sums(data.year == nil ? "By year" : "By month", Self.sums(data.entries, by: periodKey), selection: $period, label: periodLabel)
                    sums("By spending category", Self.sums(data.entries, by: { $0.spending ?? Self.none }).sorted { $0.amount > $1.amount },
                         selection: $spending, label: { $0 })
                }
                HStack {
                    TextField("Search names, memos and what was bought", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                    if saving { ProgressView().controlSize(.small) }
                    Spacer()
                    let s = shown(data)
                    Text("Showing \(s.count) of \(data.entries.count): \(money2(s.reduce(0) { $0 + $1.amount }))").monospacedDigit().foregroundStyle(.secondary)
                }
                table(shown(data))
            } else if error == nil {
                ProgressView().controlSize(.small)
                Spacer()
            }
            HStack {
                Text(editable.isEmpty
                     ? "Its role isn't Spending, so these entries aren't in Spending Analysis: Allocate… (right-click) makes it a spending account."
                     : "Right-click entries (⇧ or ⌘ click for several) to tag them, set their category or driver, or change their expense account; double-click one to tag it. Drag a column header's edge to widen it.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Close") { close() }.keyboardShortcut("w", modifiers: .command)
            }
        }
        .padding(18)
        .frame(minWidth: 900, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
        .task(id: year) { await load() }
        .sheet(isPresented: Binding(get: { tagging != nil }, set: { if !$0 { tagging = nil } })) {
            if let picked = tagging, let setup { SpendingTagSheet(setup: setup, entries: picked) { body in await tag(picked, body) } }
        }
        .sheet(isPresented: Binding(get: { refiling != nil }, set: { if !$0 { refiling = nil } })) {
            if let picked = refiling, let setup { RefileSheet(setup: setup, entries: picked) { saved($0) } }
        }
        .sheet(item: $allocating) { target in
            if let setup {
                TargetAllocationSheet(setup: setup, target: target, entries: Array(editable.values),
                                      entriesIn: year.map { "in \($0)" } ?? "in all years") { saved($0) }
            }
        }
        .alert("Some entries weren't changed", isPresented: Binding(get: { bulkError != nil }, set: { if !$0 { bulkError = nil } })) {
            Button("OK") { bulkError = nil }
        } message: {
            Text(bulkError ?? "")
        }
    }

    // MARK: Sums

    private struct Sum: Identifiable {
        var key: String
        var amount: Double
        var count: Int
        var id: String { key }
    }

    private static func sums(_ entries: [TargetEntry], by key: (TargetEntry) -> String) -> [Sum] {
        Dictionary(grouping: entries, by: key)
            .map { Sum(key: $0.key, amount: $0.value.reduce(0) { $0 + $1.amount }, count: $0.value.count) }
            .sorted { $0.key < $1.key }
    }

    private func periodKey(_ e: TargetEntry) -> String { String(e.date.prefix(year == nil ? 4 : 7)) }

    private func periodLabel(_ key: String) -> String {
        guard key.count == 7, let d = isoDay.date(from: key + "-01") else { return key }
        return d.formatted(.dateTime.month(.abbreviated))
    }

    /// A row of sums; pressing one shows only its entries, pressing it again all of them.
    private func sums(_ title: String, _ list: [Sum], selection: Binding<String?>, label: @escaping (String) -> String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(list) { s in
                        Button {
                            selection.wrappedValue = selection.wrappedValue == s.key ? nil : s.key
                        } label: {
                            VStack(spacing: 1) {
                                Text(label(s.key)).font(.caption)
                                Text(money2(s.amount)).monospacedDigit()
                            }
                            .padding(.horizontal, 2)
                        }
                        .buttonStyle(.bordered)
                        .tint(selection.wrappedValue == s.key ? Color.accentColor : nil)
                        .help("\(s.count) \(s.count == 1 ? "entry" : "entries"): \(money2(s.amount)). Press to show only these; again for all")
                    }
                }
            }
        }
    }

    // MARK: Entries

    private func shown(_ d: TargetEntries) -> [TargetEntry] {
        let q = search.lowercased()
        return d.entries.filter { e in
            (period == nil || periodKey(e) == period)
                && (spending == nil || (e.spending ?? Self.none) == spending)
                && (q.isEmpty || [e.name, e.memo, e.bought, e.orders, e.register].contains { ($0 ?? "").lowercased().contains(q) })
        }
    }

    private func table(_ rows: [TargetEntry]) -> some View {
        Table(rows, selection: $selected) {
            TableColumn("Date") { e in Text(shortDay(e.date)).monospacedDigit() }.width(min: 70, ideal: 84)
            TableColumn("Register") { e in Text(e.register).foregroundStyle(.secondary) }.width(min: 60, ideal: 100)
            TableColumn("Statement name") { e in
                Text((e.checkNo.map { "#\($0) " } ?? "") + (e.name ?? "")).help([e.name, e.memo].compactMap { $0 }.joined(separator: "\n"))
            }.width(min: 140, ideal: 240)
            TableColumn("Expense account") { e in Text(e.category ?? "").foregroundStyle(.secondary) }.width(min: 80, ideal: 120)
            TableColumn("Category") { e in
                let s = editable[e.id]
                HStack(spacing: 3) {
                    if s?.tagged == true { Image(systemName: "tag.fill").font(.caption2).foregroundStyle(.secondary) }
                    Text(e.spending ?? Self.none).foregroundStyle(e.spending == nil ? .secondary : .primary)
                }
                .help(s?.categoryFrom.map { "From the \($0)" } ?? (s == nil ? "Not in Spending Analysis" : "Its target account has no category, and no tag gives one"))
            }.width(min: 90, ideal: 130)
            TableColumn("Driver") { e in
                let s = editable[e.id]
                Text(s.map { setup?.driverTitle($0.driver) ?? ($0.driver ?? "") } ?? "")
                    .foregroundStyle(s?.driver == nil ? .secondary : .primary)
                    .help(s?.driverFrom.map { "From the \($0)" } ?? (s == nil ? "Not in Spending Analysis" : "No driver from its target account or a tag: counts as usage"))
            }.width(min: 80, ideal: 120)
            TableColumn("Amount") { e in
                Text(money2(abs(e.amount))).monospacedDigit().foregroundStyle(e.amount < 0 ? .green : .primary)
            }.width(min: 70, ideal: 90)
            TableColumn("Bought") { e in
                let items = (e.bought ?? "").split(separator: "\n").map(String.init)
                Text(items.first.map { items.count > 1 ? "\($0) (+\(items.count - 1) more)" : $0 } ?? "")
                    .foregroundStyle(.secondary)
                    .help(items.isEmpty ? "" : (e.orders.map { "Order \($0)\n" } ?? "") + items.joined(separator: "\n"))
            }.width(min: 120, ideal: 260)
        }
        .tableText()
        // One menu on the whole row, as on Target Accounts.
        .textSelection(.disabled)
        .contextMenu(forSelectionType: TargetEntry.ID.self) { ids in
            menu(rows.filter { ids.contains($0.id) }.compactMap { editable[$0.id] })
        } primaryAction: { ids in
            // Double-click: tag it (them).
            let picked = rows.filter { ids.contains($0.id) }.compactMap { editable[$0.id] }
            if !picked.isEmpty, setup != nil { tagging = picked }
        }
        .frame(minHeight: 260)
    }

    // MARK: The menu (Spending Analysis ▸ Entries')

    @ViewBuilder
    private func menu(_ picked: [SpendingEntry]) -> some View {
        let ready = !picked.isEmpty && setup != nil && !saving
        Button(picked.count > 1 ? "Tag \(picked.count) Entries…" : "Tag Entry…") { tagging = picked }.disabled(!ready)
        categoryMenu(picked, label: picked.count > 1 ? "Set Category of \(picked.count) Entries" : "Set Category").disabled(!ready)
        driverMenu(picked, label: picked.count > 1 ? "Set Driver of \(picked.count) Entries" : "Set Driver").disabled(!ready)
        if picked.contains(where: \.tagged) {
            Button("Clear Tags") { Task { await setTags(picked.filter(\.tagged), [:]) } }.disabled(!ready)
        }
        Button(picked.count > 1 ? "Change Expense Account of \(picked.count) Entries…" : "Change Expense Account…") { refiling = picked }
            .disabled(!ready || !picked.contains { $0.source != "ledger" })
        Divider()
        Button("Allocate \(payee.name)…") { allocating = RuleTarget(payeeId: payee.id, name: payee.name) }
            .help("Its role, and the category, driver and family member its spending goes to unless an entry's own tag says otherwise")
            .disabled(setup == nil)
    }

    private func categoryMenu(_ picked: [SpendingEntry], label: String) -> some View {
        Menu(label) {
            ForEach(setup?.categories ?? []) { c in
                Button(c.name) { Task { await setField(picked, "category", c.code) } }
            }
            Divider()
            Button("Follow the Target Account") { Task { await setField(picked, "category", "") } }
                .help("Take the entries' own category off: their target account's allocation sets it again")
        }
    }

    private func driverMenu(_ picked: [SpendingEntry], label: String) -> some View {
        Menu(label) {
            ForEach(setup?.drivers ?? []) { d in
                Button(d.title) { Task { await setField(picked, "driver", d.code) } }.help(d.help ?? "")
            }
            Divider()
            Button("Follow the Target Account") { Task { await setField(picked, "driver", "") } }
                .help("Take the entries' own driver off: their target account's allocation sets it again")
        }
    }

    /// Sets one dimension (category or driver; "" follows the target account again) on each entry, leaving the rest of
    /// its own tag as it is (the service's merge). Entries already tagged that way are skipped.
    private func setField(_ picked: [SpendingEntry], _ field: String, _ value: String) async {
        let todo = picked.filter { e in
            let (current, from) = field == "category" ? (e.category, e.categoryFrom) : (e.driver, e.driverFrom)
            return value.isEmpty ? from == "entry" : !(from == "entry" && current == value)
        }
        await setTags(todo, [field: value, "merge": true])
    }

    private func setTags(_ picked: [SpendingEntry], _ body: [String: Any]) async {
        if let problem = await tag(picked, body) { bulkError = problem }
    }

    /// Tags each entry (PUT /spending/tags), then reads the entries again; what went wrong, else nil.
    private func tag(_ picked: [SpendingEntry], _ body: [String: Any]) async -> String? {
        guard !picked.isEmpty else { return nil }
        saving = true
        defer { saving = false }
        var failed = 0
        var last: String?
        for e in picked {
            do { _ = try await SpendingClient.tag(e, body) } catch { failed += 1; last = describe(error) }
        }
        await refresh()
        guard let last else { return nil }
        return failed == picked.count ? last : "\(failed) of \(picked.count) entries: \(last)"
    }

    /// Change Expense Account… or Allocate… saved: the setup they answer with, the entries again, and Target Accounts.
    private func saved(_ s: SpendingSetup) {
        setup = s
        Task { await refresh(); changed() }
    }

    private func load() async {
        error = nil
        period = nil
        await refresh()
    }

    /// The entries again (and the setup the first time), keeping what is pressed, searched and selected.
    private func refresh() async {
        do {
            async let entries = BankClient.payeeEntries(payee.id, year: year)
            async let mine = SpendingClient.targetEntries(payee.id, year: year)
            if setup == nil { setup = try await SpendingClient.setup() }
            data = try await entries
            editable = Dictionary((try await mine).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            error = nil
        } catch { self.error = describe(error) }
    }
}
