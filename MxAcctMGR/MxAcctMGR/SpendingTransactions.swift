//
//  SpendingTransactions.swift
//  MxAcctMGR
//
//  Spending Analysis ▸ Overview ▸ right-click All spending, This year, a category or a register left out of the comparison
//  (the tiles and the Key Metrics table's rows) ▸ Show N Transactions…, in a window of its own (moved, resized and kept
//  open beside the page; the last size and place are remembered): every entry behind that figure, newest first, adding
//  up to it. Above the table, each merchant's sum, each category's, each month's and, with several registers,
//  each register's: press one to show only its entries. Each column header's button sorts and filters it. Double-click
//  an entry to open it in its register; tagging stays on Entries. What the window shows is the page's figures when it
//  was opened: Show … Transactions again reads them anew.
//

import AppKit
import SwiftUI

/// One window a figure, opened anew each time so that it shows the page's figures now.
@MainActor
enum SpendingTransactionsWindow {
    private static var windows: [String: NSWindow] = [:]
    private static var closing: [String: NSObjectProtocol] = [:]
    /// Where the last one closed: its size and place.
    private static let frameName = "SpendingTransactionsWindow"

    static func open(_ name: String, period: String, entries: [SpendingEntry], setup: SpendingSetup, store: PortStore) {
        windows[name]?.close()
        let host = NSHostingController(rootView: SpendingTransactionsView(name: name, period: period, entries: entries, setup: setup, store: store) {
            windows[name]?.close()
        })
        host.sizingOptions = [.minSize]     // as wide and tall as you drag it, not the table's ideal size
        let w = NSWindow(contentViewController: host)
        w.title = "\(name): Transactions"
        w.styleMask.insert(.resizable)
        w.isReleasedWhenClosed = false
        if !w.setFrameUsingName(frameName) {
            w.setContentSize(NSSize(width: 1240, height: 760))
            w.center()
        }
        // Another figure's window is open: this one goes just below and right of it.
        if let other = windows.values.first(where: \.isVisible) {
            w.setFrameTopLeftPoint(NSPoint(x: other.frame.minX + 24, y: other.frame.maxY - 24))
        }
        closing[name] = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated {
                w.saveFrame(usingName: frameName)
                windows[name] = nil
                if let o = closing.removeValue(forKey: name) { NotificationCenter.default.removeObserver(o) }
            }
        }
        windows[name] = w
        w.makeKeyAndOrderFront(nil)
    }
}

struct SpendingTransactionsView: View {
    let name: String
    let period: String
    let entries: [SpendingEntry]
    let setup: SpendingSetup
    let store: PortStore
    /// Closes its window.
    var close: () -> Void
    @State private var target: String?
    @State private var category: String?
    @State private var month: String?
    @State private var register: String?
    @State private var search = ""
    @State private var selected = Set<SpendingEntry.ID>()
    /// The table's Excel-style sorting and column filters (the header buttons).
    @State private var grid = GridQueryOptions()

    private var columns: [String: LocalGridColumn<SpendingEntry>] {
        [
            "Date": .date({ $0.date }, display: { shortDay($0.date) }),
            "From": .text { registerOf($0) },
            "Name": .text { $0.payee },
            "Statement name": .text { $0.statementName ?? $0.description },
            "Category": .text { categoryOf($0) },
            "Driver": .text { setup.driverTitle($0.driver) },
            "Amount": .number({ $0.amount }, display: { money2($0.amount) }),
        ]
    }

    private func registerOf(_ e: SpendingEntry) -> String { e.register ?? e.sourceTitle }
    private func categoryOf(_ e: SpendingEntry) -> String { setup.category(e.category)?.name ?? "Not assigned" }
    private func targetOf(_ e: SpendingEntry) -> String { e.payee ?? "—" }
    private func monthOf(_ e: SpendingEntry) -> String { String(e.date.prefix(7)) }

    private func monthLabel(_ key: String) -> String {
        guard let d = isoDay.date(from: key + "-01") else { return key }
        return d.formatted(.dateTime.month(.abbreviated))
    }

    var body: some View {
        let picked = pressed
        let shown = LocalGrid.rows(picked, grid, columns)
        VStack(alignment: .leading, spacing: 10) {
            Text("\(entries.count) \(entries.count == 1 ? "transaction" : "transactions"), \(period): \(money2(Self.total(entries)))")
                .monospacedDigit().foregroundStyle(.secondary)
            sums("By merchant", by: targetOf, selection: $target, largestFirst: true)
            sums("By spending category", by: categoryOf, selection: $category, largestFirst: true)
            sums("By month", by: monthOf, selection: $month, largestFirst: false, label: monthLabel)
            if Set(entries.map(registerOf)).count > 1 {
                sums("By register", by: registerOf, selection: $register, largestFirst: true)
            }
            HStack {
                TextField("Search names, statement names and memos", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                GridFilterStatus(shown: shown.count, of: picked.count, options: $grid)
                Spacer()
                Text("Showing \(shown.count) of \(entries.count): \(money2(Self.total(shown)))").monospacedDigit().foregroundStyle(.secondary)
            }
            table(shown, picked)
            HStack {
                Text("Green is money that came back: it takes off the total. Double-click an entry to open it in its register; tag it or change its category on Entries or Allocation.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Close") { close() }.keyboardShortcut("w", modifiers: .command)
            }
        }
        .padding(18)
        .frame(minWidth: 900, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
    }

    private static func total(_ list: [SpendingEntry]) -> Double { list.reduce(0) { $0 + $1.amount } }

    /// The entries the pressed sums and the search leave, newest first.
    private var pressed: [SpendingEntry] {
        let q = search.lowercased()
        return entries.filter { e in
            (target == nil || targetOf(e) == target) && (category == nil || categoryOf(e) == category)
                && (month == nil || monthOf(e) == month) && (register == nil || registerOf(e) == register)
                && (q.isEmpty || [e.payee, e.statementName, e.description, e.notes].contains { ($0 ?? "").lowercased().contains(q) })
        }
        .sorted { $0.date > $1.date }
    }

    private func sums(_ title: String, by key: (SpendingEntry) -> String, selection: Binding<String?>, largestFirst: Bool, label: @escaping (String) -> String = { $0 }) -> some View {
        let list = Dictionary(grouping: entries, by: key)
            .map { PressableSum(key: $0.key, amount: Self.total($0.value), count: $0.value.count) }
            .sorted { largestFirst ? ($0.amount, $1.key) > ($1.amount, $0.key) : $0.key < $1.key }
        return PressableSums(title: title, list: list, selection: selection, label: label)
    }

    private func table(_ rows: [SpendingEntry], _ picked: [SpendingEntry]) -> some View {
        Table(rows, selection: $selected) {
            TableColumn("Date") { e in Text(shortDay(e.date)).monospacedDigit() }.width(min: 70, ideal: 84)
            TableColumn("From") { e in Text(registerOf(e)).foregroundStyle(.secondary) }.width(min: 60, ideal: 100)
            TableColumn("Name") { e in Text(e.payee ?? "").help(e.notes ?? "") }.width(min: 120, ideal: 180)
            TableColumn("Statement name") { e in Text(e.statementName ?? e.description ?? "").foregroundStyle(.secondary) }.width(min: 100, ideal: 170)
            TableColumn("Category") { e in
                Text(categoryOf(e)).foregroundStyle(e.category == nil ? .secondary : .primary).help(e.categoryFrom.map { "From the \($0)" } ?? "")
            }.width(min: 80, ideal: 110)
            TableColumn("Driver") { e in
                Text(setup.driverTitle(e.driver)).foregroundStyle(e.driver == nil ? .secondary : .primary).help(e.driverFrom.map { "From the \($0)" } ?? "")
            }.width(min: 70, ideal: 110)
            TableColumn("Amount") { e in
                Text(money2(e.amount)).monospacedDigit().foregroundStyle(e.amount < 0 ? .green : .primary).frame(maxWidth: .infinity, alignment: .trailing)
            }.width(min: 80, ideal: 100)
        }
        .tableText()
        // One menu on the whole row, as on Target Categories.
        .textSelection(.disabled)
        .contextMenu(forSelectionType: SpendingEntry.ID.self) { ids in
            let chosen = rows.filter { ids.contains($0.id) }
            if chosen.count == 1, let e = chosen.first { Button("Open \(registerOf(e)) Transaction") { openInRegister(e) } }
            if !chosen.isEmpty { Button(chosen.count == 1 ? "Copy Entry" : "Copy \(chosen.count) Entries") { copy(chosen) } }
        } primaryAction: { ids in
            if ids.count == 1, let e = rows.first(where: { ids.contains($0.id) }) { openInRegister(e) }
        }
        .onCopyCommand {
            let chosen = rows.filter { selected.contains($0.id) }
            return chosen.isEmpty ? [] : [NSItemProvider(object: text(chosen) as NSString)]
        }
        .columnHeaderFilters(types: LocalGrid.types(columns), options: grid,
                             loadValues: { (LocalGrid.values(picked, column: $0, grid, columns), false) },
                             apply: { grid = $0 })
        .frame(minHeight: 260)
    }

    private func openInRegister(_ e: SpendingEntry) {
        store.openRegister(of: e)
        LiveVideo.showMainWindow()
    }

    private func text(_ list: [SpendingEntry]) -> String {
        let head = ["Date", "From", "Name", "Statement name", "Category", "Driver", "Amount"].joined(separator: "\t")
        let lines = list.map { e in
            [e.date, registerOf(e), e.payee ?? "", e.statementName ?? e.description ?? "", categoryOf(e),
             setup.driverTitle(e.driver), String(format: "%.2f", e.amount)].joined(separator: "\t")
        }
        return ([head] + lines).joined(separator: "\n")
    }

    private func copy(_ list: [SpendingEntry]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text(list), forType: .string)
    }
}

/// A sum of entries that can be pressed.
struct PressableSum: Identifiable {
    var key: String
    var amount: Double
    var count: Int
    var id: String { key }
}

/// A row of sums; pressing one shows only its entries, pressing it again all of them.
struct PressableSums: View {
    var title: String
    var list: [PressableSum]
    @Binding var selection: String?
    var label: (String) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(list) { s in
                        Button {
                            selection = selection == s.key ? nil : s.key
                        } label: {
                            VStack(spacing: 1) {
                                Text(label(s.key)).font(.caption)
                                Text(money2(s.amount)).monospacedDigit()
                            }
                            .padding(.horizontal, 2)
                        }
                        .buttonStyle(.bordered)
                        .tint(selection == s.key ? Color.accentColor : nil)
                        .help("\(s.count) \(s.count == 1 ? "entry" : "entries"): \(money2(s.amount)). Press to show only these; again for all")
                    }
                }
            }
        }
    }
}
