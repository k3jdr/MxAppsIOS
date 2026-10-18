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
        if store.portfolio.isSRM { SRMAddSecurities(store: store) } else { illustrative }
    }

    private var illustrative: some View {
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


/// Add Securities from the security master: search srm (stocks, funds, bond funds) through the accounts service, sort
/// by any column and filter each column like a spreadsheet's autofilter, and add shares with a tax lot. Sorting and
/// filtering run in the database, across every match, not just the page shown.
struct SRMAddSecurities: View {
    @Bindable var store: PortStore
    @Environment(\.dismiss) private var dismiss

    enum Kind: String, CaseIterable, Identifiable {
        case all = "All", stocks = "Stocks", funds = "Funds", bonds = "Bond funds"
        var id: String { rawValue }
        var query: String { self == .all ? "all" : self == .stocks ? "stocks" : self == .funds ? "funds" : "bonds" }
    }
    enum Priced: String, CaseIterable, Identifiable {
        case any = "Any", yes = "With a price", no = "No price yet"
        var id: String { rawValue }
    }

    @State private var search = ""
    @State private var kind: Kind = .all
    @State private var results: [SRMSecurity] = []
    @State private var total = 0
    @State private var facets: [String: [AccountsClient.Facet]] = [:]
    @State private var facetKey = ""
    @State private var selection: Int?
    @State private var searching = false
    @State private var error: String?
    @State private var shares = 10.0
    @State private var cost = 0.0
    @State private var acquired = Date()
    @State private var added: [String] = []
    // Sorting and column filters.
    @State private var sortOrder: [KeyPathComparator<SRMSecurity>] = []
    @State private var tickerFilter = ""
    @State private var nameFilter = ""
    @State private var types: Set<String> = []
    @State private var sectors: Set<String> = []
    @State private var exchanges: Set<String> = []
    @State private var priceMin: Double?
    @State private var priceMax: Double?
    @State private var priced: Priced = .any
    private let pageSize = 200

    private var selected: SRMSecurity? { results.first { $0.securityId == selection } }

    private var request: AccountsClient.Search {
        var f: [String: String] = [:]
        f["ticker"] = tickerFilter.trimmingCharacters(in: .whitespaces)
        f["name"] = nameFilter.trimmingCharacters(in: .whitespaces)
        f["type"] = types.sorted().joined(separator: ",")
        f["sector"] = sectors.sorted().joined(separator: ",")
        f["exchange"] = exchanges.sorted().joined(separator: ",")
        if let priceMin { f["priceMin"] = String(priceMin) }
        if let priceMax { f["priceMax"] = String(priceMax) }
        if priced != .any { f["priced"] = priced == .yes ? "1" : "0" }
        let (sort, desc) = sortKey
        return AccountsClient.Search(text: search, kind: kind.query, filters: f, sort: sort, descending: desc)
    }

    /// The service's sort column for the table's first sort comparator (none: relevance).
    private var sortKey: (String, Bool) {
        guard let c = sortOrder.first else { return ("relevance", false) }
        let keys: [PartialKeyPath<SRMSecurity>: String] = [\SRMSecurity.ticker: "ticker", \SRMSecurity.name: "name", \SRMSecurity.typeKey: "type",
                                                          \SRMSecurity.sectorKey: "sector", \SRMSecurity.micKey: "exchange", \SRMSecurity.priceKey: "price",
                                                          \SRMSecurity.asOfKey: "asOf", \SRMSecurity.marketCapKey: "marketCap"]
        return (keys[c.keyPath] ?? "relevance", c.order == .reverse)
    }

    private var activeFilters: Int {
        [!tickerFilter.isEmpty, !nameFilter.isEmpty, !types.isEmpty, !sectors.isEmpty, !exchanges.isEmpty,
         priceMin != nil || priceMax != nil, priced != .any].filter { $0 }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add Securities from the Security Master").font(.title2.weight(.semibold))
                    Text("Real securities and prices in MxDataHUB's srm database (192.168.0.223), through the accounts service.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            HStack(spacing: 12) {
                TextField("Search ticker, name, ISIN or CUSIP", text: $search).textFieldStyle(.roundedBorder).frame(width: 280)
                Picker("Show", selection: $kind) { ForEach(Kind.allCases) { Text($0.rawValue).tag($0) } }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                if searching { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
                if let error {
                    Text(error).font(.callout).foregroundStyle(.red).lineLimit(2)
                } else {
                    Text("Showing \(results.count.formatted()) of \(total.formatted())").font(.callout).foregroundStyle(.secondary)
                    if results.count < total {
                        Button("Show \(min(pageSize, total - results.count).formatted()) More") { Task { await page(more: true) } }
                            .disabled(searching)
                            .help("Load the next page of matches")
                    }
                }
            }
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)
            filterRow
                .padding(.horizontal, 16).padding(.bottom, 8)
            Divider()
            HStack(spacing: 0) {
                Table(results, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn(title("Ticker", !tickerFilter.isEmpty), value: \.ticker) { s in Text(s.ticker).font(.body.monospaced()) }.width(70)
                    TableColumn(title("Name", !nameFilter.isEmpty), value: \.name) { s in Text(s.name) }.width(min: 160, ideal: 220)
                    TableColumn(title("Type", !types.isEmpty), value: \.typeKey) { s in Text(s.securityType ?? "—").foregroundStyle(.secondary) }.width(100)
                    TableColumn(title("Sector", !sectors.isEmpty), value: \.sectorKey) { s in Text(s.sector ?? "—").foregroundStyle(.secondary) }.width(120)
                    TableColumn(title("Exchange", !exchanges.isEmpty), value: \.micKey) { s in Text(s.mic ?? "—").foregroundStyle(.secondary) }.width(64)
                    TableColumn(title("Price", priceMin != nil || priceMax != nil), value: \.priceKey) { s in
                        Text(s.price.map(money) ?? "no prices").monospacedDigit().foregroundStyle(s.price == nil ? .orange : .primary)
                    }
                    .width(84)
                    TableColumn(title("As of", priced != .any), value: \.asOfKey) { s in Text(s.priceDate ?? "").foregroundStyle(.secondary) }.width(80)
                    TableColumn("Market value", value: \.marketCapKey) { s in Text(s.marketCap.map { compact($0) } ?? "").monospacedDigit().foregroundStyle(.secondary) }.width(84)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .quickHelpArea("Security Master", "Every match in srm, a page at a time. Click a column header to sort by it (again to reverse) — across all matches, in the database. The filter row above narrows each column like a spreadsheet's autofilter: text contains, pick values with their counts, a price range, priced or not. A column title with ⏷ is filtered.", symbol: "cylinder.split.1x2")
                Divider()
                detail.frame(width: 320).frame(maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
            if !added.isEmpty {
                Divider()
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Added: " + added.joined(separator: " · ")).lineLimit(1).truncationMode(.head)
                    Spacer()
                    Text(store.srmStatus ?? "").foregroundStyle(.secondary).lineLimit(1)
                }
                .font(.callout).padding(10)
            }
        }
        .frame(width: 1300, height: 740)
        .task(id: request) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await page(more: false)
        }
        .onChange(of: selection) { cost = (selected?.price ?? 0) * shares }
        .onChange(of: shares) { cost = (selected?.price ?? 0) * shares }
    }

    // MARK: Filters

    private var filterRow: some View {
        HStack(spacing: 8) {
            Label("Filter", systemImage: "line.3.horizontal.decrease.circle\(activeFilters > 0 ? ".fill" : "")")
                .foregroundStyle(activeFilters > 0 ? Color.accentColor : .secondary)
            TextField("Ticker contains", text: $tickerFilter).textFieldStyle(.roundedBorder).frame(width: 110)
            TextField("Name contains", text: $nameFilter).textFieldStyle(.roundedBorder).frame(width: 150)
            valueMenu("Type", "type", $types)
            valueMenu("Sector", "sector", $sectors)
            valueMenu("Exchange", "exchange", $exchanges)
            Text("Price").foregroundStyle(.secondary)
            TextField("min", value: $priceMin, format: .number).textFieldStyle(.roundedBorder).frame(width: 64)
            Text("–").foregroundStyle(.secondary)
            TextField("max", value: $priceMax, format: .number).textFieldStyle(.roundedBorder).frame(width: 64)
            Picker("Priced", selection: $priced) { ForEach(Priced.allCases) { Text($0.rawValue).tag($0) } }
                .labelsHidden().fixedSize()
                .help("Securities with a price in the security master (about 1,500 of 13,000), or without one yet")
            Spacer(minLength: 0)
            Button("Clear Filters") {
                tickerFilter = ""; nameFilter = ""; types = []; sectors = []; exchanges = []
                priceMin = nil; priceMax = nil; priced = .any; sortOrder = []
            }
            .disabled(activeFilters == 0 && sortOrder.isEmpty)
            .help("Remove every column filter and go back to the relevance order")
        }
        .font(.callout)
        .quickHelpArea("Column Filters", "Like a spreadsheet's autofilter: Ticker and Name keep rows that contain the text; Type, Sector and Exchange keep the values you tick (with how many securities have each, for the current search); Price keeps a range; the last menu keeps securities with or without a price. Filters combine.", symbol: "line.3.horizontal.decrease.circle")
    }

    /// A multi-select menu of a column's values with their counts, Excel autofilter style.
    private func valueMenu(_ title: String, _ key: String, _ selection: Binding<Set<String>>) -> some View {
        let values = facets[key] ?? []
        return Menu {
            Button("Select All (show every \(title.lowercased()))") { selection.wrappedValue = [] }
            Divider()
            ForEach(values, id: \.value) { f in
                Toggle("\(f.value)  (\(f.count.formatted()))", isOn: Binding(
                    get: { selection.wrappedValue.contains(f.value) },
                    set: { on in if on { selection.wrappedValue.insert(f.value) } else { selection.wrappedValue.remove(f.value) } }))
            }
        } label: {
            Text(selection.wrappedValue.isEmpty ? "\(title): All" : selection.wrappedValue.count == 1 ? "\(title): \(selection.wrappedValue.first!)" : "\(title): \(selection.wrappedValue.count) selected")
        }
        .fixedSize()
        .help("Keep only securities with the ticked \(title.lowercased()) values")
    }

    private func title(_ name: String, _ filtered: Bool) -> String { filtered ? "\(name) ⏷" : name }

    private func compact(_ x: Double) -> String {
        x >= 1e12 ? String(format: "$%.2fT", x / 1e12) : x >= 1e9 ? String(format: "$%.1fB", x / 1e9) : x >= 1e6 ? String(format: "$%.0fM", x / 1e6) : money(x)
    }

    /// The first page for the request (with fresh value counts when the search or kind changed), or the next page.
    private func page(more: Bool) async {
        let r = request
        let key = "\(r.text)|\(r.kind)"
        searching = true
        defer { searching = false }
        do {
            let page = try await AccountsClient.search(r, offset: more ? results.count : 0, limit: pageSize, facets: !more && key != facetKey)
            results = more ? results + page.securities : page.securities
            total = page.total
            if let f = page.facets { facets = f; facetKey = key }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let s = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(s.name).font(.title3.weight(.semibold))
                    Text("\(s.ticker)\(s.mic.map { ":" + $0 } ?? "") · \(s.kindTitle)").foregroundStyle(.secondary)
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        row("Price", s.price.map { "\(money($0)) on \(s.priceDate ?? "")" } ?? "No prices in the security master yet")
                        if let sector = s.sector { row("Sector", sector + (s.industry.map { " · " + $0 } ?? "")) }
                        if let b = s.beta { row("Beta", String(format: "%.2f", b)) }
                        if let m = s.marketCap { row("Market value", money(m)) }
                        if let isin = s.isin { row("ISIN", isin) }
                        if let cusip = s.cusip { row("CUSIP", cusip) }
                        row("Security master id", "\(s.securityId)")
                    }
                    .font(.callout)
                    Text(s.kind == "bond" ? "A bond fund: its price moves with interest rates; the risk model treats it as fixed income."
                         : s.kind == "fund" ? "A fund: one purchase holds many securities." : "One company's shares.")
                        .font(.callout).foregroundStyle(.secondary)
                    Divider()
                    LabeledContent("Shares") { TextField("", value: $shares, format: .number.precision(.fractionLength(0...4))).frame(width: 140) }
                    if let price = s.price { Text("= \(money(price * shares)) at the latest price").font(.callout).foregroundStyle(.secondary) }
                    LabeledContent("Cost basis") { TextField("", value: $cost, format: .currency(code: "USD")).frame(width: 140) }
                        .help("What you paid in total for these shares (the tax lot's cost)")
                    DatePicker("Bought", selection: $acquired, in: ...Date(), displayedComponents: .date)
                    Button {
                        store.addSRMHolding(s, quantity: shares, cost: cost, acquired: acquired)
                        added.append("\(String(format: "%g", shares)) \(s.ticker)")
                    } label: { Label("Add to My Portfolio", systemImage: "plus.circle.fill") }
                    .buttonStyle(.borderedProminent)
                    .disabled(shares <= 0)
                    .help("Adds a tax lot; adding a security already held adds to the position. The account is saved to the security master.")
                }
                .padding(14)
            }
        } else {
            ContentUnavailableView("Select a Security", systemImage: "magnifyingglass", description: Text("Search the security master and choose a stock, fund or bond fund."))
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow { Text(k).foregroundStyle(.secondary); Text(v) }
    }
}
