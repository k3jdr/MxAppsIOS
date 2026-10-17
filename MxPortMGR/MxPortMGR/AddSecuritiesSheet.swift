//
//  AddSecuritiesSheet.swift
//  MxPortMGR
//
//  My Portfolio ▸ Add Securities…: find a company, an individual bond (Treasury, TIPS, corporate, high yield,
//  municipal), a fund or cash in the illustrative universe, see what it is and how it behaves under the model, and add
//  it by dollar amount, shares or face value — with a tax lot (cost and date) for a taxable account.
//

import SwiftUI

struct AddSecuritiesSheet: View {
    @Bindable var store: PortStore
    @Environment(\.dismiss) private var dismiss

    enum Kind: String, CaseIterable, Identifiable {
        case all = "All", stocks = "Stocks", bonds = "Individual bonds", funds = "Funds", cash = "Cash"
        var id: String { rawValue }
    }
    enum Entry: String, CaseIterable, Identifiable {
        case amount = "Dollar amount", units = "Shares / face value"
        var id: String { rawValue }
    }

    @State private var search = ""
    @State private var kind: Kind = .all
    @State private var sector = "All sectors"
    @State private var selection: String?
    @State private var entry: Entry = .amount
    @State private var amount = 10_000.0
    @State private var units = 100.0
    @State private var withLot = false
    @State private var cost = 10_000.0
    @State private var acquired = Date()
    @State private var added: [String] = []

    private var rows: [Security] {
        Universe.all.filter { s in
            switch kind {
            case .all: true
            case .stocks: s.assetClass == .equity && s.lookThrough == nil
            case .bonds: s.coupon != nil
            case .funds: s.isFund
            case .cash: s.assetClass == .cash
            }
        }
        .filter { sector == "All sectors" || $0.sector == sector }
        .filter { search.isEmpty || $0.ticker.localizedCaseInsensitiveContains(search) || $0.name.localizedCaseInsensitiveContains(search) || ($0.issuer ?? "").localizedCaseInsensitiveContains(search) }
    }

    private var selected: Security? { selection.flatMap(Universe.security) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add Securities to My Portfolio").font(.title2.weight(.semibold))
                    Text("Companies, individual bonds, funds and cash from the illustrative universe — fictional names and prices.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            HStack(spacing: 12) {
                TextField("Search ticker, name or issuer", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                Picker("Show", selection: $kind) { ForEach(Kind.allCases) { Text($0.rawValue).tag($0) } }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                Picker("Sector", selection: $sector) {
                    Text("All sectors").tag("All sectors")
                    ForEach(Universe.sectors, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(!(kind == .all || kind == .stocks))
                Spacer(minLength: 0)
                Text("\(rows.count) securities").font(.callout).foregroundStyle(.secondary).fixedSize()
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            HStack(spacing: 0) {
                Table(rows, selection: $selection) {
                    TableColumn("Ticker") { s in Text(s.ticker).font(.body.monospaced()) }.width(90)
                    TableColumn("Name", value: \.name).width(min: 220)
                    TableColumn("Type") { s in Text(typeText(s)).foregroundStyle(.secondary) }.width(150)
                    TableColumn("Price") { s in Text(s.coupon != nil ? String(format: "%.2f", s.price) : money(s.price)).monospacedDigit() }.width(80)
                    TableColumn("Yield") { s in Text(pct(s.yield, 2)).monospacedDigit() }.width(60)
                    TableColumn("Risk") { s in Text(riskText(s)).monospacedDigit().foregroundStyle(.secondary) }.width(110)
                    TableColumn("Held") { s in
                        let v = store.portfolio.holdings.first { $0.ticker == s.ticker }?.value
                        Text(v.map(money) ?? "").monospacedDigit()
                    }
                    .width(90)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .quickHelpArea("Securities", "Every security in the illustrative universe. Filter by type or sector, search by ticker, name or issuer, and select one to see its details and add it. Risk is volatility for a stock or fund and duration for a bond.", symbol: "list.bullet.rectangle")
                Divider()
                detail.frame(width: 380).frame(maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
            if !added.isEmpty {
                Divider()
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Added: " + added.joined(separator: " · ")).lineLimit(1).truncationMode(.head)
                    Spacer()
                    Text("My Portfolio: \(money(store.portfolio.total)), \(store.portfolio.holdings.count) holdings").foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(10)
            }
        }
        .frame(width: 1180, height: 700)
        .onChange(of: selection) { syncUnits() }
        .onChange(of: entry) { syncUnits() }
    }

    @ViewBuilder
    private var detail: some View {
        if let s = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(s.name).font(.title3.weight(.semibold))
                    Text("\(s.ticker) · \(typeText(s))").foregroundStyle(.secondary)
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        if let c = s.coupon {
                            row("Coupon", pct(c, 3))
                            row("Maturity", s.maturity ?? "")
                            row("Credit rating", s.rating ?? "")
                            row("Price", String(format: "%.2f per 100 face", s.price))
                            row("Yield to maturity", pct(s.yield, 2))
                            row("Duration", String(format: "≈ %.1f years — about %.1f%% for a 1-point rise in yields", s.duration, s.duration))
                        } else {
                            row("Price", money(s.price))
                            row(s.assetClass == .bond ? "Yield" : "Dividend yield", pct(s.yield, 2))
                            if s.assetClass == .equity && s.lookThrough == nil { row("Beta", String(format: "%.2f", s.beta)) }
                            if s.fee > 0 { row("Fund fee", pct(s.fee, 2) + " a year") }
                            if let parts = s.lookThrough { row("Holds", "\(parts.count) securities (look-through)") }
                        }
                        if let v = s.volatility { row("Volatility (model)", pct(v)) }
                        row("Expected return (model)", pct(Universe.expectedReturn(s)))
                    }
                    .font(.callout)
                    Text(explain(s)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Divider()
                    Picker("Enter", selection: $entry) { ForEach(Entry.allCases) { Text($0 == .units && s.coupon != nil ? "Face value" : $0 == .units ? "Shares" : $0.rawValue).tag($0) } }
                        .pickerStyle(.segmented)
                    if entry == .amount {
                        LabeledContent("Amount") { TextField("", value: $amount, format: .currency(code: "USD")).frame(width: 140) }
                    } else {
                        LabeledContent(s.coupon != nil ? "Face value" : "Shares") { TextField("", value: $units, format: .number.precision(.fractionLength(0...2))).frame(width: 140) }
                        Text("= \(money(value(s)))").font(.callout).foregroundStyle(.secondary)
                    }
                    if s.assetClass != .cash {
                        Toggle("Record a tax lot (cost and purchase date)", isOn: $withLot)
                            .help("For a taxable account: what you paid and when, so gains, short- or long-term, can be estimated")
                        if withLot {
                            LabeledContent("Cost basis") { TextField("", value: $cost, format: .currency(code: "USD")).frame(width: 140) }
                            DatePicker("Bought", selection: $acquired, displayedComponents: .date)
                        }
                    }
                    Button {
                        let v = value(s)
                        store.addToMine(s.ticker, value: v, cost: withLot ? cost : nil, acquired: withLot ? acquired : nil)
                        added.append("\(money(v)) \(s.ticker)")
                    } label: { Label("Add to My Portfolio", systemImage: "plus.circle.fill") }
                    .buttonStyle(.borderedProminent)
                    .disabled(value(s) <= 0)
                    .help("Add this amount; adding a security you already hold adds to the position (and its lots)")
                }
                .padding(14)
            }
            .quickHelpArea(QuickHelpItem(title: s.name, detail: explain(s), symbol: "info.circle"))
        } else {
            ContentUnavailableView("Select a Security", systemImage: "magnifyingglass", description: Text("Choose a company, bond, fund or cash on the left to see its details and add it."))
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow { Text(k).foregroundStyle(.secondary); Text(v) }
    }

    private func value(_ s: Security) -> Double {
        entry == .amount ? amount : s.coupon != nil ? units * s.price / 100 : units * s.price
    }

    private func syncUnits() {
        guard let s = selected else { return }
        if entry == .units { units = ((s.coupon != nil ? amount / s.price * 100 : amount / s.price) * 100).rounded() / 100 }
        cost = value(s)
    }

    private func typeText(_ s: Security) -> String {
        if let issuer = s.issuer { return "Bond · \(issuer)" }
        if s.lookThrough != nil { return "Index fund · \(s.assetClass.rawValue)" }
        switch s.assetClass {
        case .equity: return "Stock · \(s.sector)"
        case .bond: return "Bond fund"
        case .cash: return "Cash"
        }
    }

    private func riskText(_ s: Security) -> String {
        if s.assetClass == .bond, s.lookThrough == nil { return String(format: "duration %.1f", s.duration) }
        return s.volatility.map { "vol " + pct($0, 0) } ?? (s.lookThrough != nil ? "diversified" : "")
    }

    private func explain(_ s: Security) -> String {
        if let issuer = s.issuer {
            switch issuer {
            case "U.S. Treasury": return "A U.S. government bond: no meaningful default risk; its price moves with interest rates — the longer the maturity, the more. Held to maturity it pays the coupon and returns 100."
            case "U.S. Treasury (TIPS)": return "An inflation-protected Treasury: principal rises with consumer prices, so its low coupon is a real (after-inflation) yield."
            case "Municipal (tax-exempt)": return "A state or city bond: interest is usually free of federal income tax, so its lower yield can be worth more after tax in a taxable account — and is wasted in a retirement account."
            case "Corporate (high yield)": return "A bond rated below investment grade: a higher yield to pay for a real risk of default; it tends to fall with stocks in a downturn."
            default: return "A company's bond: a higher yield than Treasuries for the issuer's credit risk. It ranks ahead of the company's stock if things go wrong."
            }
        }
        if let parts = s.lookThrough { return "An index fund holding \(parts.count) securities in proportion; one purchase diversifies across all of them for a \(pct(s.fee, 2)) yearly fee." }
        switch s.assetClass {
        case .equity: return "One company's stock in the \(s.sector) sector. Beta \(String(format: "%.2f", s.beta)): it tends to move \(String(format: "%.2f", s.beta))% when the market moves 1%, plus its own news."
        case .bond: return "A bond fund: a diversified basket of bonds with a duration of about \(String(format: "%.1f", s.duration)); it never matures, so its price keeps moving with rates."
        case .cash: return "Cash and money-market funds: steady value and today's short-term interest rate; it loses ground to inflation over long periods."
        }
    }
}
