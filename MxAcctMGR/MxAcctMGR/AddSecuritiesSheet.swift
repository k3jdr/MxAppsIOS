//
//  AddSecuritiesSheet.swift
//  MxAcctMGR
//
//  Investments ▸ Add Securities…: find securities in the security master (stocks, ETFs, bond funds, mutual funds,
//  Treasuries) and add them to My Portfolio by shares, with a tax lot (cost and date).
//

import SwiftUI

struct AddSecuritiesSheet: View {
    @Bindable var store: PortStore

    var body: some View { SRMAddSecurities(store: store) }
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
    /// What the search is doing now, and since when (shown next to the spinner and over an empty table).
    @State private var stage: String?
    @State private var stageStart = Date()
    /// The steps of this search so far, each with how long it took.
    @State private var steps: [(String, Double)] = []
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
                    Text("Add Securities from the Security Master").heading(.heading)
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
                if searching, let stage {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        TimelineView(.periodic(from: stageStart, by: 1)) { t in
                            Text("\(stage) \(Int(t.date.timeIntervalSince(stageStart)))s").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .help(stage)
                    }
                }
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
                    TableColumn(title("Ticker", !tickerFilter.isEmpty), value: \.ticker) { s in LinkedCell(target: .srm(s), font: PortSettings.shared.font(.ids)) }.width(70)
                    TableColumn(title("Name", !nameFilter.isEmpty), value: \.name) { s in LinkedCell(target: .srm(s, .name)) }.width(min: 160, ideal: 220)
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
                .tableText()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay { if results.isEmpty && (searching || !steps.isEmpty) { progressPanel } }
                // Links on tickers and names: the security master's (as on the Securities page and in MxDataHUB);
                // right-click to add, edit or open one, ⌘K for the selected row, or a hover card's Edit Link….
                .contextMenu(forSelectionType: SRMSecurity.ID.self) { ids in
                    if let id = ids.first, let s = results.first(where: { $0.id == id }) { linkMenu(.srm(s)) }
                }
                .task(id: results.map(\.securityId)) { await SecurityLinks.shared.load(securityIDs: results.map { Int64($0.securityId) }) }
                // A click picks a row (the screens' text is selectable, the rows' words aren't).
                .textSelection(.disabled)
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
        // The Link dialog over this one (the window's own can't show while this sheet is up). Edit ▸ Link… (⌘K) takes
        // the selected row here (store.addSecuritiesLink) instead of My Holdings' selection.
        .sheet(item: Binding(get: { SecurityLinks.shared.editing }, set: { SecurityLinks.shared.editing = $0 })) { SecurityLinkSheet(initial: $0) }
        .onChange(of: selection, initial: true) { store.addSecuritiesLink = selected.map { .srm($0) } }
        .onDisappear { store.addSecuritiesLink = nil }
        #if DEBUG
        // Self-test: -addLinkEdit TICKER|symbol (or |name) selects that row once the first page is in and opens the
        // Link dialog for it, as ⌘K would.
        .task(id: results.isEmpty) {
            guard let arg = UserDefaults.standard.string(forKey: "addLinkEdit"), !results.isEmpty else { return }
            let parts = arg.split(separator: "|").map(String.init)
            guard let s = results.first(where: { $0.ticker == parts[0] }) else { return }
            selection = s.id
            try? await Task.sleep(for: .seconds(1))
            SecurityLinks.shared.beginEdit(LinkTarget.srm(s, parts.count > 1 && parts[1] == "name" ? .name : .symbol))
        }
        #endif
        .task(id: request) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await page(more: false)
        }
        .onChange(of: selection) { cost = (selected?.price ?? 0) * shares }
        .onChange(of: shares) { cost = (selected?.price ?? 0) * shares }
    }

    // MARK: Progress

    /// Over the empty table while the first page loads: each step done (with its time) and the one running.
    private var progressPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(searching ? "Reading the security master" : "No securities match").heading(.name)
            Text("The accounts service (127.0.0.1:8774) queries MxDataHUB's srm database on 192.168.0.223.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                Label { Text(step.0) + Text(String(format: "  %.1fs", step.1)).foregroundStyle(.secondary) } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            if searching, let stage {
                Label { Text(stage) } icon: { ProgressView().controlSize(.small) }
            }
        }
        .font(.callout)
        .padding(16)
        .frame(maxWidth: 520, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }

    private var kindWords: String {
        switch kind {
        case .all: "stocks, ETFs, mutual funds and bond funds"
        case .stocks: "stocks"
        case .funds: "ETFs and mutual funds"
        case .bonds: "bond funds"
        }
    }

    private func begin(_ text: String) {
        stage = text
        stageStart = Date()
    }

    private func finish(_ text: String) {
        steps.append((text, Date().timeIntervalSince(stageStart)))
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
    /// The rows come first; the filter menus' value counts (a second, heavier query) follow when the search or kind
    /// changed, so the table fills without waiting for them.
    private func page(more: Bool) async {
        let r = request
        let key = "\(r.text)|\(r.kind)"
        searching = true
        defer { searching = false; stage = nil }
        if !more { steps = [] }
        do {
            if more {
                begin("Reading the next \(min(pageSize, total - results.count).formatted()) securities…")
            } else {
                let what = r.text.isEmpty ? kindWords : "\(kindWords) matching “\(r.text)”"
                begin("Finding \(what), with each one's latest price and market value…")
            }
            let page = try await AccountsClient.search(r, offset: more ? results.count : 0, limit: pageSize)
            guard r == request else { return }
            results = more ? results + page.securities : page.securities
            total = page.total
            error = nil
            if !more {
                finish("Found \(total.formatted()) \(kindWords); showing the first \(results.count.formatted())")
            }
            if !more && key != facetKey {
                begin("Counting values for the filter menus…")
                if let f = try await AccountsClient.search(r, offset: 0, limit: 1, facets: true).facets {
                    facets = f
                    facetKey = key
                }
                finish("Filter menus ready")
            }
        } catch {
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let s = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(s.name).heading(.subheading)
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
                    .textKind(.results)
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
