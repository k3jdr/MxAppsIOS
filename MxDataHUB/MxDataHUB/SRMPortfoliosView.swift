//
//  SRMPortfoliosView.swift
//  MxDataHUB
//
//  SRM ▸ Portfolios: portfolios with dated holdings snapshots. Holdings are added by any
//  identifier, as shares and/or a target weight; the snapshot is valued with the latest prices,
//  checked by srm.portfolio_validate, and compared with the portfolio's benchmark.
//

import SwiftUI

struct SRMPortfoliosView: View {
    @Bindable var store: SRMStore
    @State private var taxLotSelection = Set<TaxLotRow.ID>()
    @State private var activeSelection = Set<ActiveWeightRow.ID>()

    /// The tables' columns as text, for ⌘C and Copy Row (TableCopy.swift).
    static let portfoliosText = TableText<PortfolioRow>(
        titles: ["Code", "Name", "Benchmark"], cells: { [$0.code, $0.name, $0.benchmarkCode] })
    static let holdingsText = TableText<HoldingRow>(
        titles: ["Ticker", "Name", "Entered as", "Shares", "Target", "Price", "Market value", "Weight"],
        cells: { [$0.ticker, $0.name, $0.input.isEmpty ? "" : "\($0.input) (\($0.inputType))", numberText($0.quantity, digits: 0),
                  percentText($0.targetWeight, digits: 2), numberText($0.price), numberText($0.marketValue), percentText($0.weight, digits: 2)] })
    static let taxLotsText = TableText<TaxLotRow>(
        titles: ["Ticker", "Name", "Bought", "Shares", "Cost", "Value", "Gain", "Term"],
        cells: { [$0.ticker, $0.name, $0.acquired, numberText($0.quantity, digits: 0), numberText($0.costBasis), numberText($0.marketValue),
                  numberText($0.gain), $0.longTerm ? "long" : "short"] })
    static let activeWeightsText = TableText<ActiveWeightRow>(
        titles: ["Ticker", "Name", "Portfolio", "Benchmark", "Active"],
        cells: { [$0.ticker, $0.name, percentText($0.portfolio, digits: 2), percentText($0.benchmark, digits: 2), percentText($0.active, digits: 2)] })

    @State private var editing: PortfolioRow?
    @State private var creating = false
    @State private var addingHolding = false
    @State private var pasting = false
    @State private var newSnapshot = false
    @State private var snapshotDay = Date()
    @State private var confirmDelete = false
    /// 0 holdings, 1 vs benchmark, 2 tax lots (personal accounts).
    @State private var panel = 0

    var body: some View {
        SplitPanes(id: "portfolios", widths: 200...300, ideal: 230, trailingMinimum: 560) {
            portfolioList
        } trailing: {
            holdingsPanel
        }
        .task { await store.refreshPortfolios() }
        .task(id: store.selectedPortfolioID) { await store.loadSnapshots() }
        .sheet(isPresented: $creating) { PortfolioDialog(store: store, existing: nil) }
        .sheet(item: $editing) { PortfolioDialog(store: store, existing: $0) }
        .sheet(isPresented: $addingHolding) { AddHoldingDialog(store: store) }
        .sheet(isPresented: $pasting) { PasteHoldingsDialog(store: store) }
        .confirmationDialog("Delete portfolio \(store.selectedPortfolio?.code ?? "")?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                if let id = store.selectedPortfolioID { Task { await store.deletePortfolio(id) } }
            }
        } message: {
            Text("Its holdings and transactions are deleted too. This cannot be undone.")
        }
    }

    private var portfolioList: some View {
        VStack(spacing: 8) {
            Table(store.portfolios, selection: $store.selectedPortfolioID) {
                TableColumn("Code", value: \.code).width(min: 60, ideal: 80)
                TableColumn("Name", value: \.name)
                TableColumn("Benchmark", value: \.benchmarkCode).width(min: 50, ideal: 70)
            }
            .contextMenu(forSelectionType: Int.self) { ids in
                CopyRowsButton(rows: store.portfolios, ids: ids, text: Self.portfoliosText)
            } primaryAction: { ids in
                editing = store.portfolios.first { $0.id == ids.first }
            }
            .copiesSelectedRows(store.portfolios, selected: store.selectedPortfolioID, as: Self.portfoliosText)
            .quickHelpArea(HubHelp.portfolioList)
            HStack {
                Button("New…") { creating = true }
                    .quickHelp("New Portfolio", "A portfolio with a code, name, currency and optional benchmark; then add its holdings.")
                Button("Edit…") { editing = store.selectedPortfolio }
                    .disabled(store.selectedPortfolio == nil)
                    .quickHelp("Edit Portfolio", "Changes the selected portfolio's code, name, currency, benchmark or description (double-clicking it does too).")
                PortfolioWorkflowsMenu(portfolio: store.selectedPortfolio)
                Spacer()
                Button("Delete…", role: .destructive) { confirmDelete = true }
                    .disabled(store.selectedPortfolio == nil)
                    .quickHelp("Delete Portfolio", "Deletes the selected portfolio with its holdings and transactions, after asking. It can't be undone.")
            }
        }
        .padding(10)
    }

    @ViewBuilder
    private var holdingsPanel: some View {
        if let portfolio = store.selectedPortfolio {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(portfolio.name).font(.title3.bold())
                    Text(portfolio.code + " · " + portfolio.currency
                         + (portfolio.benchmarkCode.isEmpty ? "" : " · benchmark " + portfolio.benchmarkCode))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if portfolio.isPersonal {
                        Button("Open in MxAcctMGR") {
                            if !AppLink.myPortfolio(portfolio.code).open() { store.errorMessage = "MxAcctMGR is not installed." }
                        }
                        .help("Open this account as My Portfolio in MxAcctMGR")
                        .quickHelp("Open in MxAcctMGR", "Opens this personal account as My Portfolio in MxAcctMGR, where its tax lots are edited and it is analysed, optimized or tracked.")
                    }
                }
                if portfolio.isPersonal {
                    HStack(spacing: 8) {
                        Label("Personal account", systemImage: "person.crop.circle").font(.callout.weight(.semibold))
                        Text([portfolio.accountType.capitalized, portfolio.approach.isEmpty ? "" : portfolio.approach.capitalized + " approach",
                              portfolio.cash > 0 ? "cash " + numberText(portfolio.cash) : "",
                              portfolio.managedBy.isEmpty ? "" : "maintained in " + portfolio.managedBy]
                            .filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .quickHelpArea("Personal Account", "A portfolio with an account type (V011): taxable, retirement or Roth, run actively or passively, with uninvested cash and open tax lots. \(portfolio.managedBy.isEmpty ? "" : "\(portfolio.managedBy) rewrites today's holdings from the lots whenever it saves, so edit the lots there.")", symbol: "person.crop.circle")
                }
                HStack {
                    Picker("Holdings on", selection: Binding(
                        get: { store.snapshotDate ?? "" },
                        set: { store.snapshotDate = $0; Task { await store.loadHoldings() } })) {
                        ForEach(snapshotChoices, id: \.self) { Text($0).tag($0) }
                    }
                    .fixedSize()
                    .quickHelp("Holdings On", "The snapshot date shown: each date has its own holdings, valued with the latest prices.")
                    Button("New Snapshot…") { snapshotDay = Date(); newSnapshot = true }
                        .quickHelp("New Snapshot", "Starts holdings on another date, copied from the latest earlier snapshot, to change from there.")
                        .help("Start holdings on another date, copied from the latest earlier snapshot")
                        .popover(isPresented: $newSnapshot) {
                            VStack(alignment: .leading, spacing: 10) {
                                DatePicker("Date", selection: $snapshotDay, displayedComponents: .date)
                                Text("Copies the latest earlier snapshot.").font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    Spacer()
                                    Button("Create") {
                                        newSnapshot = false
                                        Task { await store.newSnapshot(on: snapshotDay) }
                                    }
                                    .keyboardShortcut(.defaultAction)
                                }
                            }
                            .padding(14)
                            .frame(width: 260)
                        }
                    Spacer()
                    Picker("", selection: $panel) {
                        Text("Holdings").tag(0)
                        Text("vs Benchmark").tag(1)
                        if portfolio.isPersonal { Text("Tax Lots").tag(2) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .quickHelp("Holdings / vs Benchmark / Tax Lots", "The holdings, each security's weight against the benchmark's (needs a benchmark), or — for a personal account — its open tax lots.")
                }

                if panel == 1 && portfolio.benchmarkID != nil {
                    activeWeightsTable
                        .quickHelpArea(HubHelp.activeWeights)
                } else if panel == 2 && portfolio.isPersonal {
                    taxLotsTable
                        .quickHelpArea("Tax Lots", "Open tax lots: shares bought on a date at a cost, valued with the latest price, with the unrealised gain and whether a sale today would be long-term (held over a year).", symbol: "doc.text")
                } else {
                    holdingsTable
                        .quickHelpArea(HubHelp.holdings)
                }

                if !store.issues.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(store.issues.prefix(8)) { issue in
                            Label(issue.message, systemImage: issue.severity == "error" ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(issue.severity == "error" ? .red : .orange)
                                .lineLimit(1)
                        }
                        if store.issues.count > 8 {
                            Text("… and \(store.issues.count - 8) more").foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                } else if !store.holdings.isEmpty {
                    Label("Valid: weights add up and every holding is priced", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green).font(.callout)
                }

                HStack {
                    Button("Add Holding…") { addingHolding = true }
                        .keyboardShortcut("n", modifiers: [.command, .shift])
                        .quickHelp("Add Holding", "Adds a security by any identifier (ticker, TICKER:MIC, ISIN, CUSIP, SEDOL, FIGI) as shares or a weight; one already held is replaced.", shortcut: "⇧⌘N")
                    Button("Paste Holdings…") { pasting = true }
                        .quickHelp("Paste Holdings", "Adds many holdings from pasted lines: an identifier, optionally its type, then shares or a weight ending in % (\"AAPL 100\", \"US5949181045, 4.5%\").")
                    Menu("Copy Benchmark") {
                        ForEach(store.benchmarks.filter { $0.members > 0 }) { b in
                            Button("\(b.code) — \(b.members) members") { Task { await store.copyBenchmark(b.id) } }
                        }
                    }
                    .fixedSize()
                    .help("Fill this snapshot with a benchmark's weights")
                    .quickHelp("Copy Benchmark", "Fills this snapshot with a benchmark's members and weights, as target weights — a start for an index-like portfolio.")
                    Button("Normalize Weights") { Task { await store.normalizeWeights() } }
                        .help("Scale target weights to add up to 100%")
                        .disabled(!store.holdings.contains { $0.targetWeight != nil })
                        .quickHelp("Normalize Weights", "Scales the target weights so they add up to 100%.")
                    Spacer()
                    Button("Remove", role: .destructive) { Task { await store.removeHoldings(store.selectedHoldingIDs) } }
                        .disabled(store.selectedHoldingIDs.isEmpty)
                        .quickHelp("Remove", "Takes the selected holdings out of this snapshot.")
                }
            }
            .padding(10)
        } else {
            ContentUnavailableView {
                Label("No Portfolio", systemImage: "briefcase")
            } description: {
                Text("Create a portfolio, then add holdings by ticker, ISIN, CUSIP, SEDOL or FIGI.")
            } actions: {
                Button("New Portfolio…") { creating = true }
            }
        }
    }

    private var snapshotChoices: [String] {
        var dates = store.snapshotDates
        if let current = store.snapshotDate, !dates.contains(current) { dates.insert(current, at: 0) }
        return dates
    }

    private var totalValue: Double { store.holdings.compactMap(\.marketValue).reduce(0, +) }

    private var holdingsTable: some View {
        VStack(alignment: .leading, spacing: 4) {
            Table(store.holdings, selection: $store.selectedHoldingIDs) {
                TableColumn("Ticker") { h in LinkedCell(target: .holding(h)) }.width(min: 40, ideal: 52)
                TableColumn("Name") { h in LinkedCell(target: .holding(h, .name)) }.width(min: 100, ideal: 150)
                TableColumn("Entered as") { Text($0.input.isEmpty ? "" : "\($0.input) (\($0.inputType))").foregroundStyle(.secondary) }
                    .width(min: 60, ideal: 100)
                TableColumn("Shares") { Text(numberText($0.quantity, digits: 0)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing) }
                    .width(min: 45, ideal: 65)
                TableColumn("Target") { Text(percentText($0.targetWeight, digits: 2)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing) }
                    .width(min: 45, ideal: 58)
                TableColumn("Price") { row in
                    Text(numberText(row.price)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                        .help(row.priceDate.isEmpty ? "No price" : "Close on \(row.priceDate)")
                }
                    .width(min: 45, ideal: 62)
                TableColumn("Market value") { Text(numberText($0.marketValue)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing) }
                    .width(min: 60, ideal: 85)
                TableColumn("Weight") { Text(percentText($0.weight, digits: 2)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing) }
                    .width(min: 50, ideal: 70)
            }
            .contextMenu(forSelectionType: HoldingRow.ID.self) { ids in
                if let id = ids.first, let h = store.holdings.first(where: { $0.id == id }) { linkMenu(.holding(h)) }
                Divider()
                CopyRowsButton(rows: store.holdings, ids: ids, text: Self.holdingsText)
            }
            .copiesSelectedRows(store.holdings, selected: store.selectedHoldingIDs, as: Self.holdingsText)
            .task(id: store.holdings.map(\.id)) { await SecurityLinks.shared.load(securityIDs: store.holdings.map(\.id)) }
            HStack {
                Text("\(store.holdings.count) holdings")
                if totalValue > 0 { Text("· market value \(numberText(totalValue))") }
                let targets = store.holdings.compactMap(\.targetWeight)
                if !targets.isEmpty { Text("· target weights \(percentText(targets.reduce(0, +), digits: 2))") }
            }
            .foregroundStyle(.secondary)
        }
    }

    private var taxLotsTable: some View {
        VStack(alignment: .leading, spacing: 4) {
            Table(store.taxLots, selection: $taxLotSelection) {
                TableColumn("Ticker", value: \.ticker).width(min: 40, ideal: 60)
                TableColumn("Name", value: \.name).width(min: 100, ideal: 180)
                TableColumn("Bought", value: \.acquired).width(min: 70, ideal: 85)
                TableColumn("Shares") { Text(numberText($0.quantity, digits: 0)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing) }
                TableColumn("Cost") { Text(numberText($0.costBasis)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing) }
                TableColumn("Value") { Text(numberText($0.marketValue)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing) }
                TableColumn("Gain") { row in
                    Text(numberText(row.gain)).monospacedDigit().foregroundStyle((row.gain ?? 0) >= 0 ? .green : .red)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                TableColumn("Term") { Text($0.longTerm ? "long" : "short").foregroundStyle($0.longTerm ? Color.secondary : .orange) }.width(min: 40, ideal: 50)
            }
            .copyRowsMenu(store.taxLots, as: Self.taxLotsText)
            .copiesSelectedRows(store.taxLots, selected: taxLotSelection, as: Self.taxLotsText)
            let value = store.taxLots.compactMap(\.marketValue).reduce(0, +), cost = store.taxLots.reduce(0) { $0 + $1.costBasis }
            Text("\(store.taxLots.count) lots · value \(numberText(value)) · cost \(numberText(cost)) · unrealised \(numberText(value - cost))")
                .foregroundStyle(.secondary)
        }
        .task(id: store.selectedPortfolioID) { await store.loadTaxLots() }
    }

    private var activeWeightsTable: some View {
        VStack(alignment: .leading, spacing: 4) {
            Table(store.activeWeights, selection: $activeSelection) {
                TableColumn("Ticker", value: \.ticker).width(min: 45, ideal: 60)
                TableColumn("Name", value: \.name).width(min: 120, ideal: 220)
                TableColumn("Portfolio") { Text(percentText($0.portfolio, digits: 2)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing) }
                TableColumn("Benchmark") { Text(percentText($0.benchmark, digits: 2)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing) }
                TableColumn("Active") { row in
                    Text(percentText(row.active, digits: 2)).monospacedDigit()
                        .foregroundStyle(row.active >= 0 ? .green : .red)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .copyRowsMenu(store.activeWeights, as: Self.activeWeightsText)
            .copiesSelectedRows(store.activeWeights, selected: activeSelection, as: Self.activeWeightsText)
            let overlap = store.activeWeights.reduce(0) { $0 + min($1.portfolio, $1.benchmark) }
            Text("Largest 200 active weights · overlap with benchmark \(percentText(overlap, digits: 1)) · active share \(percentText(1 - overlap, digits: 1))")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - New / Edit portfolio

struct PortfolioDialog: View {
    let store: SRMStore
    let existing: PortfolioRow?
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var name = ""
    @State private var currency = "USD"
    @State private var benchmarkID: Int?
    @State private var description = ""

    private var problems: [String] {
        var out: [String] = []
        if code.range(of: #"^[A-Za-z0-9_\-]{1,40}$"#, options: .regularExpression) == nil {
            out.append("Code: 1–40 letters, digits, - or _")
        }
        if store.portfolios.contains(where: { $0.code.lowercased() == code.lowercased() && $0.id != existing?.id }) {
            out.append("Code \(code) is already used")
        }
        if name.trimmingCharacters(in: .whitespaces).isEmpty { out.append("Enter a name") }
        if currency.range(of: "^[A-Z]{3}$", options: .regularExpression) == nil { out.append("Currency: ISO 4217 code, e.g. USD") }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(existing == nil ? "New Portfolio" : "Edit Portfolio").font(.headline)
            Form {
                TextField("Code", text: $code, prompt: Text("GROWTH1"))
                TextField("Name", text: $name, prompt: Text("Growth portfolio"))
                TextField("Base currency", text: $currency)
                    .onChange(of: currency) { currency = String(currency.uppercased().prefix(3)) }
                Picker("Benchmark", selection: $benchmarkID) {
                    Text("None").tag(Int?.none)
                    ForEach(store.benchmarks) { Text("\($0.code) — \($0.name)").tag(Int?.some($0.id)) }
                }
                TextField("Description", text: $description, axis: .vertical)
                    .lineLimit(2...4)
            }
            ForEach(problems, id: \.self) { Text($0).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Create" : "Save") {
                    Task {
                        if await store.savePortfolio(id: existing?.id, code: code, name: name, currency: currency,
                                                     benchmarkID: benchmarkID, description: description) {
                            dismiss()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!problems.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 440)
        .onAppear {
            if let p = existing {
                code = p.code; name = p.name; currency = p.currency; benchmarkID = p.benchmarkID; description = p.description
            } else {
                benchmarkID = store.benchmarks.first { $0.code == "SP500" }?.id
            }
        }
    }
}

// MARK: - Add holding

let identifierTypes = ["Auto", "ISIN", "CUSIP", "SEDOL", "FIGI", "COMPOSITE_FIGI", "SHARE_CLASS_FIGI", "TICKER",
                       "FMP_SYMBOL", "CIK", "LEI"]

struct AddHoldingDialog: View {
    let store: SRMStore
    @Environment(\.dismiss) private var dismiss
    @State private var identifier = ""
    @State private var type = "Auto"
    @State private var byWeight = false
    @State private var amount = ""
    @State private var matches: [ResolveMatch] = []
    @State private var searched = false
    @State private var failures: [String] = []

    private var value: Double? { Double(amount.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "%", with: "")) }

    private var problems: [String] {
        var out: [String] = []
        if searched && matches.isEmpty && !identifier.isEmpty { out.append("No security found for \(identifier)") }
        if matches.count > 1, let first = matches.first,
           !["ISIN", "CUSIP", "FIGI", "COMPOSITE_FIGI", "SHARE_CLASS_FIGI"].contains(first.matchedType) {
            out.append("\(matches.count) securities match; pick an identifier type, or use an ISIN, CUSIP, FIGI or TICKER:MIC")
        }
        if !amount.isEmpty && value == nil { out.append(byWeight ? "Weight must be a number (percent)" : "Shares must be a number") }
        if let v = value, byWeight, !(v >= -100 && v <= 100) { out.append("Weight must be between -100% and 100%") }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Holding to \(store.selectedPortfolio?.code ?? "") on \(store.snapshotDate ?? "")").font(.headline)
            Form {
                TextField("Identifier", text: $identifier, prompt: Text("AAPL, US0378331005, 037833100, 2046251, BBG000B9XRY4, AAPL:XNAS"))
                Picker("Identifier type", selection: $type) {
                    ForEach(identifierTypes, id: \.self) { Text($0 == "Auto" ? "Detect" : $0).tag($0) }
                }
                Picker("Enter", selection: $byWeight) {
                    Text("Shares").tag(false)
                    Text("Weight %").tag(true)
                }
                .pickerStyle(.segmented)
                TextField(byWeight ? "Weight %" : "Shares", text: $amount, prompt: Text(byWeight ? "2.5" : "100"))
            }

            GroupBox("Matches") {
                if matches.isEmpty {
                    Text(identifier.isEmpty ? "Type an identifier." : searched ? "No match." : "Looking…")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(matches.prefix(6)) { m in
                            HStack {
                                Image(systemName: m.id == matches.first?.id ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(m.id == matches.first?.id ? Color.accentColor : .secondary)
                                Text(m.ticker).bold()
                                Text(m.name).lineLimit(1)
                                Spacer()
                                Text("\(m.matchedType) · \(m.isin.isEmpty ? m.type : m.isin)").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            ForEach(problems + failures, id: \.self) { Text($0).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Close", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    Task {
                        failures = await store.addHoldings([(identifier, type, byWeight ? nil : value, byWeight ? value : nil)])
                        if failures.isEmpty {
                            identifier = ""; amount = ""; matches = []; searched = false
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(matches.isEmpty || value == nil || !problems.isEmpty)
            }
            Text("Add keeps the dialog open for the next holding; an existing holding of the same security is replaced.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 560)
        .task(id: identifier + "|" + type) {
            searched = false
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            matches = await store.resolve(identifier, type: type)
            searched = !identifier.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }
}

// MARK: - Paste holdings

struct PasteHoldingsDialog: View {
    let store: SRMStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var failures: [String] = []
    @State private var added = 0

    /// Lines of "identifier value": value is shares, or a weight when it ends with %.
    private var parsed: (entries: [(identifier: String, type: String, shares: Double?, weightPercent: Double?)], bad: [String]) {
        var entries: [(String, String, Double?, Double?)] = []
        var bad: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let parts = raw.split(whereSeparator: { $0 == "," || $0 == "\t" || $0 == " " || $0 == ";" }).map(String.init)
            guard parts.count >= 2 else {
                if !raw.trimmingCharacters(in: .whitespaces).isEmpty { bad.append(String(raw)) }
                continue
            }
            var number = parts[parts.count - 1].replacingOccurrences(of: ",", with: "")
            let isWeight = number.hasSuffix("%")
            number = number.replacingOccurrences(of: "%", with: "")
            guard let value = Double(number) else { bad.append(String(raw)); continue }
            let id = parts[0]
            let type = parts.count >= 3 && identifierTypes.contains(parts[1].uppercased()) ? parts[1].uppercased() : "Auto"
            entries.append((id, type, isWeight ? nil : value, isWeight ? value : nil))
        }
        return (entries, bad)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paste Holdings into \(store.selectedPortfolio?.code ?? "") on \(store.snapshotDate ?? "")").font(.headline)
            Text("One holding per line: identifier, optional identifier type, then shares or a weight ending in %. Separated by commas, tabs or spaces, e.g. \"AAPL 100\", \"US5949181045, 4.5%\", \"2046251 SEDOL 50\".")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(height: 220)
                .border(Color(nsColor: .separatorColor))
            let p = parsed
            Text("\(p.entries.count) holdings ready" + (p.bad.isEmpty ? "" : ", \(p.bad.count) lines not understood"))
                .foregroundStyle(p.bad.isEmpty ? Color.secondary : Color.orange)
            if added > 0 { Text("Added \(added).").foregroundStyle(.green) }
            if !failures.isEmpty {
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(failures, id: \.self) { Text($0).foregroundStyle(.red) }
                    }
                }
                .frame(maxHeight: 120)
            }
            HStack {
                Spacer()
                Button("Close", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Holdings") {
                    Task {
                        let entries = parsed.entries
                        failures = await store.addHoldings(entries)
                        added = entries.count - failures.count
                        if failures.isEmpty { text = "" }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(parsed.entries.isEmpty || store.busy)
            }
        }
        .padding(18)
        .frame(width: 560)
    }
}
