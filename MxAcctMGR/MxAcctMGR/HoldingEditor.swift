//
//  HoldingEditor.swift
//  MxAcctMGR
//
//  My Holdings ▸ Edit Holding… (double-click a row, its context menu, or the pencil): a holding's tax lots — purchase
//  date, shares and total cost of each — edited, added or removed; for cash, the amount. The holding's shares are the
//  lots' total and its value follows the latest price (cost where there is none). Like every edit, it is kept when the
//  portfolio is saved (File ▸ Save).
//

import SwiftUI

extension PortStore {
    /// Replaces a holding's lots (shares and total cost each); no lots left removes the holding.
    func updateHolding(_ ticker: String, lots: [(acquired: String, shares: Double, cost: Double, note: String?)]) {
        guard var mine = openPortfolio, let i = mine.holdings.firstIndex(where: { $0.ticker == ticker }) else { return }
        let kept = lots.filter { $0.shares > 0 }
        let quantity = kept.reduce(0) { $0 + $1.shares }
        guard quantity > 0 else {
            mine.holdings.remove(at: i)
            portfolio = mine
            return
        }
        var h = mine.holdings[i]
        let price = h.security.flatMap { $0.price > 0 && !h.unpriced ? $0.price : nil }
        h.lots = kept.map { TaxLot(acquired: $0.acquired, share: $0.shares / quantity, costBasis: max(0, $0.cost), note: $0.note) }
        h.quantity = quantity
        h.value = price.map { $0 * quantity } ?? kept.reduce(0) { $0 + max(0, $1.cost) }
        mine.holdings[i] = h
        portfolio = mine
    }

    /// Sets the cash held (0 removes it).
    func updateCash(_ amount: Double) {
        guard var mine = openPortfolio else { return }
        mine.holdings.removeAll { $0.ticker == "CASH" }
        if amount > 0 { mine.holdings.append(Holding(ticker: "CASH", value: amount)) }
        portfolio = mine
    }
}

struct EditHoldingSheet: View {
    @Bindable var store: PortStore
    let ticker: String
    @Environment(\.dismiss) private var dismiss

    struct Row: Identifiable { let id = UUID(); var acquired = Date(); var shares = 0.0; var cost = 0.0; var note: String? }
    @State private var rows: [Row] = []
    @State private var cash = 0.0

    private static let day: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    private var holding: Holding? { store.portfolio.holdings.first { $0.ticker == ticker } }
    private var price: Double? { holding?.security.flatMap { $0.price > 0 ? $0.price : nil } }
    private var shares: Double { rows.reduce(0) { $0 + $1.shares } }
    private var cost: Double { rows.reduce(0) { $0 + $1.cost } }
    /// The lot list's height: all of its rows up to what leaves the rest of the sheet on screen.
    private var lotsHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return min(CGFloat(rows.count) * 30 + 26, max(160, screen - 380))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if ticker == "CASH" {
                Text("Edit Cash").heading(.heading)
                Form {
                    TextField("Cash ($)", value: $cash, format: .number.precision(.fractionLength(0...2)))
                }
            } else {
                let s = holding?.security
                VStack(alignment: .leading, spacing: 2) {
                    Text("Edit \(s?.displayTicker ?? ticker)").heading(.heading)
                    Text(s?.name ?? "").foregroundStyle(.secondary)
                    Text(price.map { "Latest price \(money($0))" + (s?.priceDate.map { " on \($0)" } ?? "") } ?? "No price yet: valued at cost")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Text("Each tax lot: when it was bought, how many shares, and what they cost in total. The holding's shares are the lots' total. Changing a lot's shares changes its cost in proportion (a partial sale); change the cost after it to correct it.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                // A plan account has a lot per trade day — dozens a fund — so the lots scroll inside a height that
                // fits the screen, and the totals and the Cancel / Done buttons stay in view.
                ScrollViewReader { scroller in
                    ScrollView(.vertical) {
                        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                            GridRow {
                                Text("Bought").font(.caption).foregroundStyle(.secondary)
                                Text("Shares").font(.caption).foregroundStyle(.secondary)
                                Text("Total cost ($)").font(.caption).foregroundStyle(.secondary)
                                Text("Cost / share").font(.caption).foregroundStyle(.secondary)
                                Text("")
                            }
                            ForEach($rows) { $r in
                                GridRow {
                                    DatePicker("", selection: $r.acquired, in: ...Date(), displayedComponents: .date).labelsHidden().fixedSize()
                                        .help(r.note ?? "")
                                    TextField("", value: Binding(get: { r.shares }, set: { v in
                                        // Scale the lot's cost with its shares, as a partial sale or a split would.
                                        if r.shares > 0, v >= 0 { r.cost *= v / r.shares }
                                        r.shares = max(0, v)
                                    }), format: .number.precision(.fractionLength(0...6))).frame(width: 110)
                                    TextField("", value: $r.cost, format: .number.precision(.fractionLength(0...2))).frame(width: 120)
                                    Text(r.shares > 0 ? money(r.cost / r.shares) : "—").monospacedDigit().foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
                                    Button { rows.removeAll { $0.id == r.id } } label: { Image(systemName: "minus.circle") }
                                        .buttonStyle(.borderless)
                                        .help("Remove this lot")
                                }
                                .id(r.id)
                            }
                        }
                        .padding(.trailing, 14)
                    }
                    .frame(height: lotsHeight)
                    .onChange(of: rows.count) { old, new in
                        // A lot added (not the sheet opening): show it.
                        if old > 0, new > old, let last = rows.last { withAnimation { scroller.scrollTo(last.id, anchor: .bottom) } }
                    }
                }
                HStack {
                    Button("Add a Lot") { rows.append(Row(acquired: Date(), shares: 0, cost: 0)) }.buttonStyle(.link)
                    Spacer()
                    Text("\(rows.count) lot\(rows.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                HStack(spacing: 18) {
                    Text("\(shares.formatted(.number.precision(.fractionLength(0...4)))) shares").monospacedDigit()
                    Text("cost \(money(cost))").monospacedDigit()
                    if let price { Text("value \(money(price * shares))").monospacedDigit() }
                    if let price, cost > 0 { Text("gain \(money(price * shares - cost))").monospacedDigit().foregroundStyle(Color.signed(price * shares - cost)) }
                }
                .font(.callout)
                if shares == 0 {
                    Label("No shares left: saving removes the holding.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Done") { apply(); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: ticker == "CASH" ? 360 : 640)
        .onAppear(perform: load)
    }

    private func load() {
        guard let h = holding else { return }
        if ticker == "CASH" { cash = h.value; return }
        let q = h.quantity ?? 0
        rows = h.lots.isEmpty
            ? [Row(acquired: Date(), shares: q, cost: h.value)]
            : h.lots.map { Row(acquired: Self.day.date(from: $0.acquired) ?? Date(), shares: q * $0.share, cost: $0.costBasis, note: $0.note) }
    }

    private func apply() {
        if ticker == "CASH" {
            store.updateCash(cash)
        } else {
            store.updateHolding(ticker, lots: rows.map { (Self.day.string(from: $0.acquired), $0.shares, $0.cost, $0.note) })
        }
    }
}
