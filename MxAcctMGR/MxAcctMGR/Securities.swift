//
//  Securities.swift
//  MxAcctMGR
//
//  Library ▸ Securities: MxDataHUB's Securities page in MxAcctMGR — the security master's securities, searched by
//  name or any identifier (ticker, ISIN, CUSIP, SEDOL, FIGI, CIK, LEI), filtered by type, benchmark and activity and by
//  any column (its header: sort, values, conditions), a thousand at a time; and the selected one's year of prices,
//  identifiers, issuer and security facts, listings, classification, benchmark membership and corporate actions.
//
//  MxDataHUB reads the database itself; MxAcctMGR, sandboxed, reads it through the accounts service (Services/accounts:
//  POST /securities/browse and /securities/browse/values, GET /securities/<id>/detail, GET /security-types), which runs
//  MxDataHUB's queries. Links on tickers and names are the same rows in both apps (Shared/Links).
//

import Charts
import SwiftUI

// MARK: - Rows

struct SecurityRow: Identifiable, Hashable, Decodable {
    var id: Int64
    var ticker: String
    var name: String
    var type: String
    var isin: String
    var cusip: String
    var figi: String
    var sector: String
    var mic: String
    var isActive: Bool
    /// The latest close on any listing, its date, and the latest market value (the detail's security has none).
    var price: Double?
    var priceDate: String?
    var marketCap: Double?
}

struct IdentifierRow: Identifiable, Hashable, Decodable {
    var id: String { "\(type)|\(value)|\(mic)|\(from)" }
    var type: String
    var value: String
    var mic: String
    var from: String
    var to: String
    var source: String
    var lastSeen: String
    var isCurrent: Bool
}

struct ListingRow: Identifiable, Hashable, Decodable {
    var id: String { "\(mic)|\(ticker)|\(from)" }
    var mic: String
    var exchange: String
    var ticker: String
    var isPrimary: Bool
    var from: String
    var to: String
}

struct NameValue: Identifiable, Hashable, Decodable {
    var id: String { name + "|" + value }
    var name: String
    var value: String
}

struct ActionRow: Identifiable, Hashable, Decodable {
    var id: String { "\(type)|\(exDate)|\(source)" }
    var type: String
    var exDate: String
    var detail: String
    var source: String
}

struct PricePoint: Identifiable, Hashable {
    var id: Date { date }
    var date: Date
    var close: Double
}

struct SecurityDetail {
    var security: SecurityRow
    var facts: [NameValue]
    var identifiers: [IdentifierRow]
    var listings: [ListingRow]
    var classifications: [NameValue]
    var memberships: [NameValue]
    var actions: [ActionRow]
    var prices: [PricePoint]
}

extension LinkTarget {
    /// A security on the Securities page (as MxDataHUB's).
    static func master(_ r: SecurityRow, _ field: Field = .symbol) -> LinkTarget {
        let kind: Kind = switch r.type {
        case "ETF", "ETN": .etf
        case "Mutual Fund", "Closed-End Fund": .mutualFund
        case "Collective Investment Trust": .other
        default: .stock
        }
        return LinkTarget(security: r.ticker.isEmpty ? "id:\(r.id)" : LinkTarget.key(r.ticker), securityID: r.id,
                          symbol: r.ticker.isEmpty ? "—" : r.ticker, name: r.name, field: field, columns: ["Ticker", "Name"], kind: kind)
    }
}

// MARK: - The store

@MainActor
@Observable
final class SecuritiesStore {
    static let shared = SecuritiesStore()
    static let pageSize = 1000
    /// The results' columns that sort and filter (the service maps them to v_security's).
    static let columnTypes = ["Ticker", "Name", "Type", "Sector", "MIC"].reduce(into: [String: String]()) { $0[$1] = "text" }
        .merging(["Price": "numeric", "As of": "date", "Market value": "numeric"]) { a, _ in a }

    var query = ""
    var typeFilter = "All"
    var benchmarkFilter = ""
    var activeOnly = true
    private(set) var options = GridQueryOptions()

    private(set) var results: [SecurityRow] = []
    private(set) var total = 0
    private(set) var offset = 0
    /// The rows selected (⌘-click, ⇧-click, ⌘A): ⌘C and the context menu copy them all.
    var selection = Set<SecurityRow.ID>() {
        didSet {
            // The details show one: the only one, else the row just added to the selection, else the one shown.
            if selection.count <= 1 { selectedID = selection.first }
            else if let added = selection.subtracting(oldValue).first { selectedID = added }
            else if let id = selectedID, !selection.contains(id) { selectedID = selection.first }
        }
    }
    /// The security whose details show.
    private(set) var selectedID: SecurityRow.ID?
    private(set) var detail: SecurityDetail?
    private(set) var types: [String] = []
    /// The benchmarks the In filter offers: each one's code and name.
    struct BenchmarkChoice: Decodable, Identifiable, Hashable {
        var code: String
        var name: String
        var id: String { code }
    }
    private(set) var benchmarks: [BenchmarkChoice] = []
    private(set) var busy = false
    private(set) var problem: String?

    var hasPrevious: Bool { offset > 0 }
    var hasNext: Bool { offset + results.count < total }

    // MARK: Calls

    private nonisolated static func call(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> Data {
        var r = URLRequest(url: URL(string: AccountsClient.base + path)!, timeoutInterval: 60)
        r.httpMethod = method
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: r)
        } catch {
            throw ServiceClient.Failure.from(error, AccountsClient.service)
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let error = json["error"] as? String {
            throw ServiceClient.Failure.rejected(error.contains("no such endpoint")
                ? "The accounts service has no Securities endpoints yet — restart it: python3 Services/mxservices.py restart accounts"
                : "The security master, through the accounts service: \(error)")
        }
        return data
    }

    /// The search box, Type, In, Active only, and the columns' sort and filters, as the service takes them.
    private func searchBody(except column: String? = nil) -> [String: Any] {
        var filters: [String: Any] = [:]
        for (name, f) in options.filters where name != column {
            switch f {
            case .values(let set): filters[name] = ["values": set.map { $0 as Any? ?? NSNull() }]
            case .condition(let op, let a, let b): filters[name] = ["op": op.rawValue, "v1": a, "v2": b]
            }
        }
        var body: [String: Any] = ["q": query.trimmingCharacters(in: .whitespaces), "type": typeFilter,
                                   "benchmark": benchmarkFilter, "activeOnly": activeOnly, "filters": filters]
        if let sort = options.sort { body["sort"] = ["column": sort.column, "ascending": sort.ascending] }
        return body
    }

    private struct Page: Decodable {
        var total: Int
        var offset: Int
        var securities: [SecurityRow]
    }

    /// The Type and In lists.
    func loadLists() async {
        guard types.isEmpty else { return }
        struct Types: Decodable { var types: [String] }
        struct Benchmarks: Decodable { var benchmarks: [BenchmarkChoice] }
        if let data = try? await Self.call("GET", "/security-types"), let t = try? JSONDecoder().decode(Types.self, from: data) { types = t.types }
        if let data = try? await Self.call("GET", "/benchmarks"), let b = try? JSONDecoder().decode(Benchmarks.self, from: data) {
            benchmarks = b.benchmarks.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    /// Runs the search from its first page.
    func search() async {
        offset = 0
        await loadPage()
    }

    func showPage(next: Bool) async {
        guard next ? hasNext : hasPrevious else { return }
        offset = next ? offset + Self.pageSize : max(0, offset - Self.pageSize)
        await loadPage()
    }

    /// New sorting or column filters from a column header; the search runs again from its first page.
    func apply(_ newOptions: GridQueryOptions) async {
        options = newOptions
        await search()
    }

    private func loadPage() async {
        busy = true
        defer { busy = false }
        var body = searchBody()
        body["offset"] = offset
        body["limit"] = Self.pageSize
        do {
            let page = try JSONDecoder().decode(Page.self, from: try await Self.call("POST", "/securities/browse", body))
            results = page.securities
            total = page.total
            problem = nil
            if let first = results.first, results.count == 1 || selectedID == nil || !results.contains(where: { $0.id == selectedID }) {
                selection = [first.id]
            } else {
                selection = selection.filter { id in results.contains { $0.id == id } }
            }
        } catch {
            if !(error is CancellationError) { problem = error.localizedDescription }
        }
    }

    /// A column's values with their counts, for its filter panel (the other columns' filters applied).
    func values(column: String) async throws -> (values: [DistinctValue], truncated: Bool) {
        struct Values: Decodable { struct V: Decodable { var value: String?; var count: Int }; var values: [V]; var truncated: Bool }
        var body = searchBody(except: column)
        body["column"] = column
        let v = try JSONDecoder().decode(Values.self, from: try await Self.call("POST", "/securities/browse/values", body))
        return (v.values.map { DistinctValue(value: $0.value, count: $0.count) }, v.truncated)
    }

    private struct DetailPayload: Decodable {
        struct Price: Decodable { var date: String; var close: Double }
        var security: SecurityRow
        var facts: [NameValue]
        var identifiers: [IdentifierRow]
        var listings: [ListingRow]
        var classifications: [NameValue]
        var memberships: [NameValue]
        var actions: [ActionRow]
        var prices: [Price]
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    func loadDetail() async {
        guard let id = selectedID else { detail = nil; return }
        do {
            let p = try JSONDecoder().decode(DetailPayload.self, from: try await Self.call("GET", "/securities/\(id)/detail"))
            guard selectedID == id else { return }
            detail = SecurityDetail(security: p.security, facts: p.facts, identifiers: p.identifiers, listings: p.listings,
                                    classifications: p.classifications, memberships: p.memberships, actions: p.actions,
                                    prices: p.prices.compactMap { pr in Self.day.date(from: pr.date).map { PricePoint(date: $0, close: pr.close) } })
        } catch {
            if !(error is CancellationError) { problem = error.localizedDescription }
        }
    }
}

// MARK: - The screen

struct SecuritiesView: View {
    @Bindable var store: PortStore
    @State private var master = SecuritiesStore.shared

    /// The tables' columns as text, for ⌘C and Copy Row (Shared/Copy/TableCopy.swift).
    static let resultsText = TableText<SecurityRow>(
        titles: ["Ticker", "Name", "Type", "Sector", "MIC", "Price", "As of", "Market value"],
        cells: { [$0.ticker, $0.name, $0.type, $0.sector, $0.mic, $0.price.map { String(format: "%.2f", $0) } ?? "",
                  $0.priceDate ?? "", $0.marketCap.map { String(format: "%.0f", $0) } ?? ""] })
    static let identifiersText = TableText<IdentifierRow>(
        titles: ["Type", "Value", "MIC", "From", "To", "Source"],
        cells: { [$0.type, $0.value, $0.mic, $0.from == "1900-01-01" ? "" : $0.from, $0.to.isEmpty ? "current" : $0.to, $0.source] })

    @State private var identifierSelection = Set<IdentifierRow.ID>()

    static func compact(_ x: Double) -> String {
        x >= 1e12 ? String(format: "$%.2fT", x / 1e12) : x >= 1e9 ? String(format: "$%.1fB", x / 1e9) : x >= 1e6 ? String(format: "$%.0fM", x / 1e6) : money(x)
    }

    var body: some View {
        // A new id: the pane is wider since it shows prices (a width saved for the old columns would hide them).
        SplitPanes(id: "portSecuritiesPrices", widths: 560...980, ideal: 820, trailingMinimum: 380) {
            searchPanel
        } trailing: {
            detailPanel
                .quickHelpArea(master.selectedID == nil ? nil : QuickHelpItem(
                    title: "Security", detail: "The selected security: its last year of closing prices, every identifier with its dates and source, then the issuer and security facts, listings, classification, benchmark membership and corporate actions as one text — drag across any of it, ⌘A, ⌘C.",
                    symbol: "doc.text.magnifyingglass"))
        }
        .task {
            await master.loadLists()
            if master.results.isEmpty { await master.search() }
        }
        .task(id: master.selectedID) { await master.loadDetail() }
    }

    private var searchPanel: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Name, ticker, ISIN, CUSIP, SEDOL, FIGI, CIK or LEI", text: $master.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await master.search() } }
                Button("Search") { Task { await master.search() } }
                    .keyboardShortcut(.defaultAction)
            }
            .quickHelpArea("Search", "Any identifier finds its security — ticker, ISIN, CUSIP, SEDOL, FIGI, CIK or LEI, current or past — and any part of a name or issuer finds the securities that have it. Return searches.", symbol: "magnifyingglass")
            HStack {
                Picker("Type", selection: $master.typeFilter) {
                    Text("All types").tag("All")
                    ForEach(master.types, id: \.self) { Text($0).tag($0) }
                }
                .fixedSize()
                .quickHelp("Type", "Only securities of this type: common stock, ETF, ADR…")
                Picker("In", selection: $master.benchmarkFilter) {
                    Text("Any benchmark").tag("")
                    ForEach(master.benchmarks) { Text($0.name).tag($0.code) }
                }
                .fixedSize()
                .quickHelp("In", "Only the members of a benchmark on its latest date.")
                Toggle("Active only", isOn: $master.activeOnly)
                    .toggleStyle(.checkbox)
                    .quickHelp("Active Only", "Leaves out securities that are no longer active (delisted, matured, merged).")
                Spacer()
            }
            .onChange(of: master.typeFilter) { Task { await master.search() } }
            .onChange(of: master.benchmarkFilter) { Task { await master.search() } }
            .onChange(of: master.activeOnly) { Task { await master.search() } }

            Table(master.results, selection: $master.selection) {
                TableColumn("Ticker") { r in LinkedCell(target: .master(r)) }.width(min: 44, ideal: 58)
                TableColumn("Name") { r in LinkedCell(target: .master(r, .name)) }.width(min: 110, ideal: 150)
                TableColumn("Type", value: \.type).width(min: 50, ideal: 72)
                TableColumn("Sector", value: \.sector).width(min: 50, ideal: 88)
                TableColumn("MIC", value: \.mic).width(min: 40, ideal: 46)
                TableColumn("Price") { r in
                    Text(r.price.map(money) ?? "no prices").monospacedDigit().foregroundStyle(r.price == nil ? .orange : .primary)
                }
                .width(min: 56, ideal: 70)
                TableColumn("As of") { r in Text(r.priceDate ?? "").foregroundStyle(.secondary) }.width(min: 84, ideal: 90)
                TableColumn("Market value") { r in Text(r.marketCap.map(Self.compact) ?? "").monospacedDigit().foregroundStyle(.secondary) }
                    .width(min: 56, ideal: 72)
            }
            .tableText()
            .columnHeaderFilters(
                types: SecuritiesStore.columnTypes, options: master.options,
                loadValues: { [master] in try await master.values(column: $0) },
                apply: { [master] options in Task { await master.apply(options) } })
            .contextMenu(forSelectionType: SecurityRow.ID.self) { ids in
                if let id = ids.first, let r = master.results.first(where: { $0.id == id }) { linkMenu(.master(r)) }
                Divider()
                CopyRowsButton(rows: master.results, ids: ids, text: Self.resultsText)
            }
            .copiesSelectedRows(master.results, selected: master.selection, as: Self.resultsText)
            .task(id: master.results.map(\.id)) { await SecurityLinks.shared.load(securityIDs: master.results.map(\.id)) }
            .quickHelpArea("Securities", "The securities found, a thousand at a time, with the latest price, its date and the market value. Select several with ⌘-click or ⇧-click (⌘A for the page) and ⌘C — or right-click ▸ Copy N Rows — to copy them with the column titles, tab-separated for a spreadsheet; the details show the last one clicked. The identifiers (ISIN, CUSIP, FIGI …) are in the details on the right. Click a column's header to sort it or filter it by its values or a condition; select one for its details on the right. ⌘C copies the selected row; right-click for its link.", symbol: "tablecells")
            pageBar
            if !master.options.isEmpty { sortAndFilterLine }
            if let problem = master.problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
    }

    private var pageBar: some View {
        HStack {
            Text(rowsText).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Button("Previous", systemImage: "chevron.left") { Task { await master.showPage(next: false) } }
                .disabled(!master.hasPrevious || master.busy)
                .help("Show the previous \(SecuritiesStore.pageSize.formatted()) securities")
            Button { Task { await master.showPage(next: true) } } label: {
                HStack(spacing: 4) { Text("Next"); Image(systemName: "chevron.right") }
            }
            .disabled(!master.hasNext || master.busy)
            .help("Show the next \(SecuritiesStore.pageSize.formatted()) securities")
        }
    }

    /// "1–1,000 of 13,263 securities", and how many are selected when more than one.
    private var rowsText: String {
        let total = master.total
        guard !master.results.isEmpty else { return master.offset > 0 ? "No securities on this page" : (master.busy ? "Searching…" : "No securities") }
        let selected = master.selection.count > 1 ? " · \(master.selection.count.formatted()) selected" : ""
        if master.offset == 0 && master.results.count == total { return "\(total.formatted()) \(total == 1 ? "security" : "securities")" + selected }
        return "\((master.offset + 1).formatted())–\((master.offset + master.results.count).formatted()) of \(total.formatted()) securities" + selected
    }

    private var sortAndFilterLine: some View {
        HStack(spacing: 10) {
            if let sort = master.options.sort {
                Label("sorted by \(sort.column)", systemImage: sort.ascending ? "arrow.up" : "arrow.down")
                Button("Clear Sort") {
                    var o = master.options
                    o.sort = nil
                    Task { await master.apply(o) }
                }
                .buttonStyle(.link)
                .textSelection(.disabled)
            }
            if !master.options.filters.isEmpty {
                Label("filtered: \(master.options.filters.keys.sorted().joined(separator: ", "))", systemImage: "line.3.horizontal.decrease.circle.fill")
                    .lineLimit(1)
                Button("Clear Filters") {
                    var o = master.options
                    o.filters = [:]
                    Task { await master.apply(o) }
                }
                .buttonStyle(.link)
                .textSelection(.disabled)
            }
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(Color.accentColor)
        .disabled(master.busy)
    }

    private var detailPanel: some View {
        ZStack {
            if let detail = master.detail, master.selectedID != nil {
                ScrollViewReader { proxy in
                    detailContent(detail)
                        .onChange(of: detail.security.id) { proxy.scrollTo("top", anchor: .top) }
                }
            } else {
                ContentUnavailableView("Select a security", systemImage: "magnifyingglass",
                                       description: Text("Search by name or any identifier."))
            }
        }
    }

    private func detailContent(_ detail: SecurityDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(detail.security.name).heading(.heading).textSelection(.enabled)
                    Text([detail.security.ticker, detail.security.mic, detail.security.type, detail.security.sector]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                }
                .id("top")

                if !detail.prices.isEmpty {
                    Chart(detail.prices) {
                        LineMark(x: .value("Date", $0.date), y: .value("Close", $0.close))
                            .interpolationMethod(.linear)
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .frame(height: 140)
                }

                if !detail.identifiers.isEmpty {
                    section("Identifiers") {
                        Table(detail.identifiers, selection: $identifierSelection) {
                            TableColumn("Type", value: \.type).width(min: 60, ideal: 90)
                            TableColumn("Value") { Text($0.value).foregroundStyle($0.isCurrent ? .primary : .secondary) }
                                .width(min: 100, ideal: 150)
                            TableColumn("MIC", value: \.mic).width(min: 40, ideal: 44)
                            TableColumn("From") { Text(Self.known($0.from)) }.width(min: 56, ideal: 66)
                            TableColumn("To") { Text($0.to.isEmpty ? "current" : $0.to) }.width(min: 50, ideal: 58)
                            TableColumn("Source", value: \.source).width(min: 50, ideal: 74)
                        }
                        .tableText()
                        .copyRowsMenu(detail.identifiers, as: Self.identifiersText)
                        .copiesSelectedRows(detail.identifiers, selected: identifierSelection, as: Self.identifiersText)
                        .frame(height: CGFloat(min(12, detail.identifiers.count + 1)) * 24 + 8)
                    }
                }

                // From here down one text, so a drag selects across sections and rows (Shared/Copy/SelectableText.swift).
                SelectableText(text: Self.factsText(detail))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 1900-01-01 marks a value whose start is unknown (it was already valid at the first load).
    private static func known(_ day: String) -> String { day == "1900-01-01" ? "" : day }

    /// Issuer and security, listings, classification, benchmark membership and corporate actions, as one text.
    static func factsText(_ detail: SecurityDetail) -> NSAttributedString {
        var lines = RichLines()
        lines.heading("Issuer and security")
        lines.facts(detail.facts.map { ($0.name, $0.value) })
        if !detail.listings.isEmpty {
            lines.heading("Listings")
            lines.columns(detail.listings.map { l in
                [(l.ticker, RichLines.boldFont, .labelColor),
                 ("\(l.mic) \(l.exchange)", RichLines.font, .labelColor),
                 (l.isPrimary ? "primary" : "", RichLines.font, .secondaryLabelColor),
                 (l.to.isEmpty ? (known(l.from).isEmpty ? "current" : "since \(l.from)") : "\(known(l.from)) – \(l.to)",
                  RichLines.font, .secondaryLabelColor)]
            })
        }
        if !detail.classifications.isEmpty {
            lines.heading("Classification")
            lines.facts(detail.classifications.map { ($0.name, $0.value) })
        }
        lines.heading("Benchmark membership")
        if detail.memberships.isEmpty {
            lines.note("Not in any loaded benchmark")
        } else {
            lines.facts(detail.memberships.map { ($0.name, $0.value) })
        }
        if !detail.actions.isEmpty {
            lines.heading("Corporate actions")
            lines.columns(detail.actions.map { a in
                [(a.exDate, RichLines.digitFont, .labelColor),
                 (a.type.replacingOccurrences(of: "_", with: " ").capitalized, RichLines.font, .labelColor),
                 (a.detail, RichLines.font, .labelColor),
                 (a.source, RichLines.font, .secondaryLabelColor)]
            })
        }
        return lines.result
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).heading(.name)
            content()
        }
    }
}
