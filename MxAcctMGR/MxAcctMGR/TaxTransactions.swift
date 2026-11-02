//
//  TaxTransactions.swift
//  MxAcctMGR
//
//  Spending Analysis ▸ Year-End Tax ▸ Tax-Applicable Expenses ▸ right-click an item, a category, the total or the tile ▸
//  Show N Transactions…, in a window of its own: every payment behind that figure, the ones the year's report counted
//  (a payment moved to this year included, one moved away not), adding up to it. Above the table, each item's sum, each
//  category's, each month's and, with several, each register's: press one to show only its payments. Each column
//  header's button sorts and filters it. Double-click a payment to open it in its register or cash ledger. What the
//  window shows is the report's figures when it was opened: Show … Transactions again reads them anew.
//

import AppKit
import SwiftUI

@MainActor
enum TaxTransactionsWindow {
    static func open(_ name: String, entries: [TaxReport.Entry], report: TaxReport, store: PortStore) {
        SpendingTransactionsWindow.present("Tax: \(name)", title: "\(name): Tax-Applicable Expenses, \(String(report.year))") { close in
            TaxTransactionsView(entries: entries, report: report, store: store, close: close)
        }
    }
}

/// A right-click on a Tax-Applicable Expenses figure: the payments behind it.
struct ShowsTaxTransactions: ViewModifier {
    var name: String
    var entries: [TaxReport.Entry]
    var report: TaxReport
    var store: PortStore

    func body(content: Content) -> some View {
        // Selectable text would open the text's own menu instead.
        content.textSelection(.disabled).contextMenu {
            Button("Show \(entries.count) \(entries.count == 1 ? "Transaction" : "Transactions")…") {
                TaxTransactionsWindow.open(name, entries: entries, report: report, store: store)
            }
            .disabled(entries.isEmpty)
        }
    }
}

private struct TaxTransactionsView: View {
    let entries: [TaxReport.Entry]
    let report: TaxReport
    let store: PortStore
    var close: () -> Void
    @State private var item: String?
    @State private var category: String?
    @State private var month: String?
    @State private var register: String?
    @State private var search = ""
    @State private var selected = Set<TaxReport.Entry.ID>()
    @State private var grid = GridQueryOptions()

    private func itemOf(_ e: TaxReport.Entry) -> String { report.item(e.itemId)?.label ?? "—" }
    private func categoryOf(_ e: TaxReport.Entry) -> String { report.item(e.itemId)?.taxCategory ?? "—" }
    private func registerOf(_ e: TaxReport.Entry) -> String { e.register ?? e.source }
    private func monthOf(_ e: TaxReport.Entry) -> String { String(e.date.prefix(7)) }
    private func deductible(_ e: TaxReport.Entry) -> Double { e.amount * (report.item(e.itemId)?.deductibleShare ?? 0) }
    private func periodOf(_ e: TaxReport.Entry) -> String { e.moved ? "\(e.period) (moved)" : e.period }

    private var columns: [String: LocalGridColumn<TaxReport.Entry>] {
        [
            "Date": .date({ $0.date }, display: { shortDay($0.date) }),
            "From": .text { registerOf($0) },
            "Name": .text { $0.payee },
            "Item": .text { itemOf($0) },
            "Category": .text { categoryOf($0) },
            "Memo": .text { $0.description },
            "Counts toward": .text { periodOf($0) },
            "Amount": .number({ $0.amount }, display: { money2($0.amount) }),
            "Deductible": .number({ deductible($0) }, display: { money2(deductible($0)) }),
        ]
    }

    private func monthLabel(_ key: String) -> String {
        guard let d = isoDay.date(from: key + "-01") else { return key }
        return d.formatted(.dateTime.month(.abbreviated).year(.twoDigits))
    }

    private static func total(_ list: [TaxReport.Entry]) -> Double { list.reduce(0) { $0 + $1.amount } }
    private func totalDeductible(_ list: [TaxReport.Entry]) -> Double { list.reduce(0) { $0 + deductible($1) } }

    /// The payments the pressed sums and the search leave, newest first.
    private var pressed: [TaxReport.Entry] {
        let q = search.lowercased()
        return entries.filter { e in
            (item == nil || itemOf(e) == item) && (category == nil || categoryOf(e) == category)
                && (month == nil || monthOf(e) == month) && (register == nil || registerOf(e) == register)
                && (q.isEmpty || [e.payee, e.description, e.note, itemOf(e)].contains { ($0 ?? "").lowercased().contains(q) })
        }
        .sorted { $0.date > $1.date }
    }

    var body: some View {
        let picked = pressed
        let shown = LocalGrid.rows(picked, grid, columns)
        VStack(alignment: .leading, spacing: 10) {
            Text("\(entries.count) \(entries.count == 1 ? "transaction" : "transactions") counted toward \(String(report.year)): \(money2(Self.total(entries))) paid, \(money2(totalDeductible(entries))) deductible")
                .monospacedDigit().foregroundStyle(.secondary)
            sums("By item", by: itemOf, selection: $item, largestFirst: true)
            sums("By tax category", by: categoryOf, selection: $category, largestFirst: true)
            sums("By month", by: monthOf, selection: $month, largestFirst: false, label: monthLabel)
            if Set(entries.map(registerOf)).count > 1 {
                sums("By register", by: registerOf, selection: $register, largestFirst: true)
            }
            HStack {
                TextField("Search names, memos, notes and items", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                GridFilterStatus(shown: shown.count, of: picked.count, options: $grid)
                Spacer()
                Text("Showing \(shown.count) of \(entries.count): \(money2(Self.total(shown))) paid, \(money2(totalDeductible(shown))) deductible")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            table(shown, picked)
            HStack {
                Text("Double-click a payment to open it where it is kept. Move a payment to another year on Year-End Tax; change an item's deductible share there too.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Close") { close() }.keyboardShortcut("w", modifiers: .command)
            }
        }
        .padding(18)
        .frame(minWidth: 900, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
    }

    private func sums(_ title: String, by key: (TaxReport.Entry) -> String, selection: Binding<String?>, largestFirst: Bool, label: @escaping (String) -> String = { $0 }) -> some View {
        let list = Dictionary(grouping: entries, by: key)
            .map { PressableSum(key: $0.key, amount: Self.total($0.value), count: $0.value.count) }
            .sorted { largestFirst ? ($0.amount, $1.key) > ($1.amount, $0.key) : $0.key < $1.key }
        return PressableSums(title: title, list: list, selection: selection, label: label)
    }

    private func table(_ rows: [TaxReport.Entry], _ picked: [TaxReport.Entry]) -> some View {
        Table(rows, selection: $selected) {
            TableColumn("Date") { e in Text(shortDay(e.date)).monospacedDigit() }.width(min: 70, ideal: 84)
            TableColumn("From") { e in Text(registerOf(e)).foregroundStyle(.secondary) }.width(min: 60, ideal: 100)
            TableColumn("Name") { e in Text(e.payee ?? "") }.width(min: 110, ideal: 170)
            TableColumn("Item") { e in Text(itemOf(e)) }.width(min: 90, ideal: 140)
            TableColumn("Category") { e in Text(categoryOf(e)).foregroundStyle(.secondary) }.width(min: 80, ideal: 110)
            TableColumn("Memo") { e in Text(e.description ?? "").foregroundStyle(.secondary) }.width(min: 70, ideal: 120)
            TableColumn("Counts toward") { e in
                Text(periodOf(e)).foregroundStyle(e.moved ? Color.accentColor : .secondary).help(e.note ?? "")
            }.width(min: 70, ideal: 90)
            TableColumn("Amount") { e in
                Text(money2(e.amount)).monospacedDigit().foregroundStyle(e.amount < 0 ? .green : .primary).frame(maxWidth: .infinity, alignment: .trailing)
            }.width(min: 70, ideal: 90)
            TableColumn("Deductible") { e in
                Text(money2(deductible(e))).monospacedDigit().foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
            }.width(min: 70, ideal: 90)
        }
        .tableText()
        .textSelection(.disabled)
        .contextMenu(forSelectionType: TaxReport.Entry.ID.self) { ids in
            let chosen = rows.filter { ids.contains($0.id) }
            if chosen.count == 1, let e = chosen.first { Button("Open \(registerOf(e)) Transaction") { open(e) } }
            if !chosen.isEmpty { Button(chosen.count == 1 ? "Copy Entry" : "Copy \(chosen.count) Entries") { copy(chosen) } }
        } primaryAction: { ids in
            if ids.count == 1, let e = rows.first(where: { ids.contains($0.id) }) { open(e) }
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

    private func open(_ e: TaxReport.Entry) {
        store.openEntry(source: e.source, register: e.register, entryId: e.entryId)
        LiveVideo.showMainWindow()
    }

    private func text(_ list: [TaxReport.Entry]) -> String {
        let head = ["Date", "From", "Name", "Item", "Category", "Memo", "Counts toward", "Amount", "Deductible"].joined(separator: "\t")
        let lines = list.map { e in
            [e.date, registerOf(e), e.payee ?? "", itemOf(e), categoryOf(e), e.description ?? "", periodOf(e),
             String(format: "%.2f", e.amount), String(format: "%.2f", deductible(e))].joined(separator: "\t")
        }
        return ([head] + lines).joined(separator: "\n")
    }

    private func copy(_ list: [TaxReport.Entry]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text(list), forType: .string)
    }
}
