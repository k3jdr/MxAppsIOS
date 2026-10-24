//
//  PortfolioSheets.swift
//  MxPortMGR
//
//  File ▸ Open Portfolio… (the personal accounts in the security master, with their value, version and who saved
//  them last) and File ▸ New Portfolio… (a code, name, account type, approach and benchmark; empty or from a sample).
//  Both settle the open portfolio first (PortfolioFile.swift: Save / Discard / Cancel).
//

import SwiftUI

struct OpenPortfolioSheet: View {
    @Bindable var store: PortStore
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [SRMAccountSummary] = []
    @State private var selection: SRMAccountSummary.ID?
    @State private var showSamples = false
    @State private var showClosed = false
    @State private var problem: String?
    @State private var loading = true

    private var visible: [SRMAccountSummary] {
        rows.filter { (showSamples || !$0.isSample) && (showClosed || $0.closedDate == nil) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Open Portfolio").font(.title2.weight(.semibold))
            Text("Portfolios kept in the security master (srm.portfolio), through the accounts service. One is open at a time.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Toggle("Show the sample accounts", isOn: $showSamples).toggleStyle(.checkbox)
                Toggle("Show closed portfolios", isOn: $showClosed).toggleStyle(.checkbox)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
            }
            Table(visible, selection: $selection) {
                TableColumn("Code") { r in Text(r.code).font(.body.monospaced()) }.width(min: 100, ideal: 130)
                TableColumn("Name") { r in Text(r.name) }.width(min: 100, ideal: 150)
                TableColumn("Type") { r in Text(r.accountType ?? "—").foregroundStyle(.secondary) }.width(70)
                TableColumn("Benchmark") { r in Text(r.benchmark ?? "—").foregroundStyle(.secondary) }.width(72)
                TableColumn("Lots") { r in Text("\(r.lots ?? 0)").monospacedDigit() }.width(40)
                TableColumn("Value") { r in Text(money((r.investedValue ?? 0) + (r.cashBalance ?? 0))).monospacedDigit() }.width(100)
                TableColumn("Version") { r in Text("\(r.version ?? 1)").monospacedDigit() }.width(54)
                TableColumn("Saved") { r in Text(((r.updatedAt ?? "").prefix(16)).replacingOccurrences(of: "T", with: " ") + (r.updatedBy.map { " · \($0)" } ?? "")).foregroundStyle(.secondary) }
                    .width(min: 120, ideal: 150)
                TableColumn("Status") { r in Text(r.closedDate.map { "Closed \($0)" } ?? (r.code.caseInsensitiveCompare(store.srmCode) == .orderedSame ? "Open now" : ""))
                    .foregroundStyle(.secondary) }.width(80)
            }
            .contextMenu(forSelectionType: SRMAccountSummary.ID.self) { _ in } primaryAction: { ids in
                if let id = ids.first { open(id) }
            }
            .frame(minHeight: 260)
            if let problem { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout) }
            HStack {
                Button("New Portfolio…") { dismiss(); store.showNewPortfolio = true }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Open") { if let id = selection { open(id) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
            }
        }
        .padding(18)
        .frame(width: 960, height: 520)
        .task {
            do {
                rows = try await AccountsClient.accountList()
                selection = rows.first { $0.code.caseInsensitiveCompare(store.srmCode) == .orderedSame }?.id
            } catch {
                problem = error.localizedDescription
            }
            loading = false
        }
    }

    private func open(_ code: String) {
        dismiss()
        store.requestOpen(code)
    }
}

struct NewPortfolioSheet: View {
    @Bindable var store: PortStore
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var name = ""
    @State private var account: AccountType = .taxable
    @State private var approach: PortfolioStyle = .active
    @State private var benchmark = "SP500"
    @State private var sampleID = ""
    private var codeOK: Bool { code.range(of: "^[A-Za-z0-9_-]{1,40}$", options: .regularExpression) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Portfolio").font(.title2.weight(.semibold))
            Text("Created in the security master and opened. Its holdings, tax lots, preferences and every saved version are kept there.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Code", text: $code, prompt: Text("e.g. IRA_ROLLOVER"))
                    .help("Letters, digits, _ or -, up to 40: the portfolio's code in srm.portfolio")
                TextField("Name", text: $name, prompt: Text("e.g. Rollover IRA"))
                Picker("Account type", selection: $account) { ForEach(AccountType.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                Picker("Approach", selection: $approach) {
                    Text("Active").tag(PortfolioStyle.active)
                    Text("Passive index").tag(PortfolioStyle.passive)
                }
                Picker("Benchmark", selection: $benchmark) {
                    ForEach(store.srmBenchmarks) { b in Text("\(b.code) — \(b.name)").tag(b.code) }
                }
                Picker("Start with", selection: $sampleID) {
                    Text("No holdings").tag("")
                    ForEach(store.portfolios.filter { $0.id != "mine" && !$0.holdings.isEmpty }) { s in Text("A copy of \(s.name)").tag(s.id) }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!codeOK)
            }
        }
        .padding(18)
        .frame(width: 520)
        .onChange(of: sampleID) {
            if let s = store.portfolios.first(where: { $0.id == sampleID }) { benchmark = s.benchmark; account = s.account }
        }
    }

    private func create() {
        let sample = store.portfolios.first { $0.id == sampleID }
        let (c, n, a, ap, b) = (code, name, account, approach, benchmark)
        dismiss()
        // The open portfolio is settled first (its Save / Discard / Cancel shows in the window, not over this sheet).
        store.whenSettled("create \(c.uppercased())") { [store] in
            if let failure = await store.createPortfolio(code: c, name: n, account: a, approach: ap, benchmark: b, from: sample) {
                store.errorMessage = "\(c.uppercased()) was not created: \(failure)"
            }
        }
    }
}
