//
//  SRMSecuritiesView.swift
//  MxDataHUB
//
//  SRM ▸ Securities: search by name or any identifier (ISIN, CUSIP, SEDOL, FIGI, ticker,
//  TICKER:MIC, CIK, LEI), filter by type and benchmark, sort and filter the columns Excel-style
//  (Shared/GridFilters), page through 1,000 at a time, and see a security's identifiers with
//  their history, listings, issuer, classifications, benchmark weights, corporate actions and prices.
//

import Charts
import SwiftUI

struct SRMSecuritiesView: View {
    @Bindable var store: SRMStore
    @State private var identifierSelection = Set<IdentifierRow.ID>()

    /// The tables' columns as text, for ⌘C and Copy Row (TableCopy.swift).
    static let resultsText = TableText<SecurityRow>(
        titles: ["Ticker", "Name", "Type", "ISIN", "CUSIP", "Composite FIGI", "Sector", "MIC"],
        cells: { [$0.ticker, $0.name, $0.type, $0.isin, $0.cusip, $0.figi, $0.sector, $0.mic] })
    static let identifiersText = TableText<IdentifierRow>(
        titles: ["Type", "Value", "MIC", "From", "To", "Source"],
        cells: { [$0.type, $0.value, $0.mic, $0.from == "1900-01-01" ? "" : $0.from, $0.to.isEmpty ? "current" : $0.to, $0.source] })

    var body: some View {
        SplitPanes(id: "securities", widths: 460...720, ideal: 560, trailingMinimum: 440) {
            searchPanel
        } trailing: {
            detailPanel
                .quickHelpArea(store.selectedSecurityID == nil ? nil : HubHelp.securityDetail)
        }
        .task { if store.results.isEmpty { await store.search() } }
        .task(id: store.selectedSecurityID) { await store.loadDetail() }
    }

    private var searchPanel: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Name, ticker, ISIN, CUSIP, SEDOL, FIGI, CIK or LEI", text: $store.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await store.search() } }
                Button("Search") { Task { await store.search() } }
                    .keyboardShortcut(.defaultAction)
            }
            .quickHelpArea(HubHelp.search)
            HStack {
                Picker("Type", selection: $store.typeFilter) {
                    Text("All types").tag("All")
                    ForEach(store.securityTypes, id: \.self) { Text($0).tag($0) }
                }
                .fixedSize()
                .quickHelp("Type", "Only securities of this type: common stock, ETF, ADR…")
                Picker("In", selection: $store.benchmarkFilter) {
                    Text("Any benchmark").tag("")
                    ForEach(store.benchmarks) { Text($0.code).tag($0.code) }
                }
                .fixedSize()
                .quickHelp("In", "Only the members of a benchmark on its latest date.")
                Toggle("Active only", isOn: $store.activeOnly)
                    .toggleStyle(.checkbox)
                    .quickHelp("Active Only", "Leaves out securities that are no longer active (delisted, matured, merged).")
                Spacer()
            }
            .onChange(of: store.typeFilter) { Task { await store.search() } }
            .onChange(of: store.benchmarkFilter) { Task { await store.search() } }
            .onChange(of: store.activeOnly) { Task { await store.search() } }

            Table(store.results, selection: $store.selectedSecurityID) {
                TableColumn("Ticker") { r in LinkedCell(target: .security(r)) }.width(min: 50, ideal: 70)
                TableColumn("Name") { r in LinkedCell(target: .security(r, .name)) }.width(min: 140, ideal: 220)
                TableColumn("Type", value: \.type).width(min: 60, ideal: 90)
                TableColumn("ISIN", value: \.isin).width(min: 90, ideal: 110)
                TableColumn("CUSIP", value: \.cusip).width(min: 70, ideal: 85)
                TableColumn("Composite FIGI", value: \.figi).width(min: 90, ideal: 110)
                TableColumn("Sector", value: \.sector).width(min: 60, ideal: 120)
                TableColumn("MIC", value: \.mic).width(min: 56, ideal: 60)
            }
            .columnHeaderFilters(
                types: SRMStore.securityColumnTypes, options: store.securityOptions,
                loadValues: { [store] in try await store.securityValues(column: $0) },
                apply: { [store] options in Task { await store.applySecurityOptions(options) } })
            .contextMenu(forSelectionType: SecurityRow.ID.self) { ids in
                if let id = ids.first, let r = store.results.first(where: { $0.id == id }) { linkMenu(.security(r)) }
                Divider()
                CopyRowsButton(rows: store.results, ids: ids, text: Self.resultsText)
            }
            .copiesSelectedRows(store.results, selected: store.selectedSecurityID, as: Self.resultsText)
            .task(id: store.results.map(\.id)) { await SecurityLinks.shared.load(securityIDs: store.results.map(\.id)) }
            .quickHelpArea(HubHelp.results)
            pageBar
            if !store.securityOptions.isEmpty { sortAndFilterLine }
        }
        .padding(10)
    }

    /// Directly below the grid: which rows are shown, then Previous / Next on the right (as in MxDataSQL's DB Table).
    private var pageBar: some View {
        HStack {
            Text(rowsText)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button("Previous", systemImage: "chevron.left") {
                Task { await store.showSecurityPage(next: false) }
            }
            .disabled(!store.hasPreviousSecurityPage || store.busy)
            .help("Show the previous \(SRMStore.securityPageSize.formatted()) securities")
            .quickHelp("Previous", "Shows the previous \(SRMStore.securityPageSize.formatted()) securities.")
            Button {
                Task { await store.showSecurityPage(next: true) }
            } label: {
                HStack(spacing: 4) {
                    Text("Next")
                    Image(systemName: "chevron.right")
                }
            }
            .disabled(!store.hasNextSecurityPage || store.busy)
            .help("Show the next \(SRMStore.securityPageSize.formatted()) securities")
            .quickHelp("Next", "Shows the next \(SRMStore.securityPageSize.formatted()) securities.")
        }
    }

    /// "1–1,000 of 13,263 securities"
    private var rowsText: String {
        let total = store.securityTotal
        guard !store.results.isEmpty else { return store.securityOffset > 0 ? "No securities on this page" : "No securities" }
        if store.securityOffset == 0 && store.results.count == total {
            return "\(total.formatted()) \(total == 1 ? "security" : "securities")"
        }
        return "\((store.securityOffset + 1).formatted())–\((store.securityOffset + store.results.count).formatted()) of \(total.formatted()) securities"
    }

    /// The column sort and filters in force, with Clear Sort / Clear Filters.
    private var sortAndFilterLine: some View {
        HStack(spacing: 10) {
            if let sort = store.securityOptions.sort {
                Label("sorted by \(sort.column)", systemImage: sort.ascending ? "arrow.up" : "arrow.down")
                Button("Clear Sort") {
                    var options = store.securityOptions
                    options.sort = nil
                    Task { await store.applySecurityOptions(options) }
                }
                .buttonStyle(.link)
                .textSelection(.disabled)
            }
            if !store.securityOptions.filters.isEmpty {
                Label("filtered: \(store.securityOptions.filters.keys.sorted().joined(separator: ", "))",
                      systemImage: "line.3.horizontal.decrease.circle.fill")
                    .lineLimit(1)
                Button("Clear Filters") {
                    var options = store.securityOptions
                    options.filters = [:]
                    Task { await store.applySecurityOptions(options) }
                }
                .buttonStyle(.link)
                .textSelection(.disabled)
            }
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(Color.accentColor)
        .disabled(store.busy)
    }

    /// One container for both states, so the split view keeps the same pane; the previous security stays on
    /// screen while the next one loads (swapping in the placeholder for that moment flashed the whole screen white).
    private var detailPanel: some View {
        ZStack {
            if let detail = store.detail, store.selectedSecurityID != nil {
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
                    Text(detail.security.name).font(.title2.bold()).textSelection(.enabled)
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

                section("Identifiers") {
                    Table(detail.identifiers, selection: $identifierSelection) {
                        TableColumn("Type", value: \.type).width(min: 60, ideal: 90)
                        TableColumn("Value") { Text($0.value).foregroundStyle($0.isCurrent ? .primary : .secondary) }
                            .width(min: 100, ideal: 112)
                        TableColumn("MIC", value: \.mic).width(min: 40, ideal: 44)
                        TableColumn("From") { Text(knownDate($0.from)) }.width(min: 56, ideal: 66)
                        TableColumn("To") { Text($0.to.isEmpty ? "current" : $0.to) }.width(min: 50, ideal: 58)
                        TableColumn("Source", value: \.source).width(min: 50, ideal: 74)
                    }
                    .copyRowsMenu(detail.identifiers, as: Self.identifiersText)
                    .copiesSelectedRows(detail.identifiers, selected: identifierSelection, as: Self.identifiersText)
                    .frame(height: CGFloat(min(12, detail.identifiers.count + 1)) * 24 + 8)
                }

                // From here down one text, so a drag selects across sections and rows (SelectableText.swift).
                SelectableText(text: Self.factsText(detail))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 1900-01-01 marks a value whose start is unknown (it was already valid at the first load).
    private func knownDate(_ day: String) -> String { Self.known(day) }
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
            Text(title).font(.headline)
            content()
        }
    }
}
