//
//  PortfolioSheets.swift
//  MxAcctMGR
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
            Text("Open Portfolio").heading(.heading)
            Text("Portfolios kept in the security master (srm.portfolio), through the accounts service. One is open at a time.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Toggle("Show the sample accounts", isOn: $showSamples).toggleStyle(.checkbox)
                Toggle("Show closed portfolios", isOn: $showClosed).toggleStyle(.checkbox)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
            }
            Table(visible, selection: $selection) {
                TableColumn("Code") { r in Text(r.code).textKind(.ids) }.width(min: 100, ideal: 130)
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
            .tableText()
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
            Text("New Portfolio").heading(.heading)
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

/// The open portfolio's decisions, newest first, and a form to record one (Portfolio ▸ Decisions…).
struct DecisionsSheet: View {
    @Bindable var store: PortStore
    @Environment(\.dismiss) private var dismiss
    @State private var list: [SRMDecision] = []
    @State private var title = ""
    @State private var rationale = ""
    @State private var category = "allocation"
    @State private var decidedOn = Date()
    @State private var problem: String?
    @State private var working = false

    static let categories = ["allocation", "benchmark", "approach", "limits", "taxes", "trade", "cash", "other"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Decisions · \(store.srmCode)").heading(.heading)
            Text("What was decided for this portfolio and why, kept in the security master with the portfolio's version at the time. Decisions are never edited: a change of mind is a new decision.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if store.openVersion == 0 {
                Label("Save the portfolio first: decisions belong to a saved portfolio.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            Table(list) {
                TableColumn("Date") { d in Text(d.decidedOn).monospacedDigit() }.width(84)
                TableColumn("Category") { d in Text(d.category.capitalized).foregroundStyle(.secondary) }.width(80)
                TableColumn("Decision") { d in Text(d.title).help(d.rationale ?? "") }.width(min: 160, ideal: 240)
                TableColumn("Why") { d in Text(d.rationale ?? "").foregroundStyle(.secondary).lineLimit(2).help(d.rationale ?? "") }.width(min: 160, ideal: 280)
                TableColumn("Version") { d in Text(d.portfolioVersion.map(String.init) ?? "").monospacedDigit() }.width(50)
            }
            .tableText()
            .frame(minHeight: 180)
            GroupBox("Record a decision") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("What was decided", text: $title)
                        Picker("Category", selection: $category) { ForEach(Self.categories, id: \.self) { Text($0.capitalized).tag($0) } }
                            .labelsHidden().fixedSize()
                        DatePicker("On", selection: $decidedOn, in: ...Date(), displayedComponents: .date).labelsHidden().fixedSize()
                    }
                    TextField("Why (the reasoning, what would change it)", text: $rationale, axis: .vertical).lineLimit(2...4)
                    HStack {
                        if let problem { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout) }
                        Spacer()
                        Button("Record") { record() }
                            .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || working || store.openVersion == 0)
                    }
                }
                .padding(4)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(18)
        .frame(width: 880, height: 560)
        .task { await load() }
    }

    private func load() async {
        guard store.openVersion > 0 else { return }
        do { list = try await AccountsClient.decisions(store.srmCode) } catch { problem = error.localizedDescription }
    }

    private func record() {
        working = true
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        Task {
            do {
                list = try await AccountsClient.addDecision(store.srmCode, title: title, rationale: rationale, category: category,
                                                            decidedOn: f.string(from: decidedOn))
                title = ""; rationale = ""; problem = nil
            } catch {
                problem = error.localizedDescription
            }
            working = false
        }
    }
}

/// File ▸ Duplicate Portfolio…: a new code and name for a copy of the saved portfolio.
struct DuplicatePortfolioSheet: View {
    @Bindable var store: PortStore
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Duplicate \(store.srmCode)").heading(.heading)
            Text("A new portfolio with the saved version's holdings, lots, cash, benchmark and preferences, then opened. Unsaved changes are settled first.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("New code", text: $code, prompt: Text("e.g. \(store.srmCode)_PLAN_B"))
                TextField("Name", text: $name, prompt: Text("\(store.portfolio.name) (copy)"))
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Duplicate") {
                    let (c, n) = (code, name.isEmpty ? "\(store.portfolio.name) (copy)" : name)
                    dismiss()
                    store.duplicatePortfolio(to: c, name: n)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(code.range(of: "^[A-Za-z0-9_-]{1,40}$", options: .regularExpression) == nil)
            }
        }
        .padding(18)
        .frame(width: 460)
    }
}

/// File ▸ Rename Portfolio…: the name (the code stays: other apps link to it).
struct RenamePortfolioSheet: View {
    @Bindable var store: PortStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename \(store.srmCode)").heading(.heading)
            Text("The code stays the same — MxDataHUB and links (mxacctmgr://my-portfolio/\(store.srmCode)) use it. The new name is saved with File ▸ Save.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Name", text: $name)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename") { store.renamePortfolio(name); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 460)
        .onAppear { name = store.portfolio.name }
    }
}

/// File ▸ Import Holdings…: the CSV's rows resolved against the security master, then added or replacing.
struct ImportHoldingsSheet: View {
    @Bindable var store: PortStore
    var preview: ImportPreview
    @Environment(\.dismiss) private var dismiss

    private var usable: Int { preview.rows.filter { $0.security != nil }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Import Holdings from \(preview.file)").heading(.heading)
            Text("\(preview.rows.count) rows: \(usable) found in the security master. Rows without a cost are costed at today's price; without a date, today. Nothing is saved until File ▸ Save.")
                .font(.callout).foregroundStyle(.secondary)
            Table(preview.rows) {
                TableColumn("Line") { r in Text("\(r.line)").monospacedDigit().foregroundStyle(.secondary) }.width(36)
                TableColumn("Ticker") { r in Text(r.ticker).textKind(.ids) }.width(80)
                TableColumn("Security") { r in Text(r.security?.name ?? "—") }.width(min: 160, ideal: 240)
                TableColumn("Shares") { r in Text(r.quantity.formatted()).monospacedDigit() }.width(80)
                TableColumn("Cost") { r in Text(r.cost.map(money) ?? "").monospacedDigit() }.width(90)
                TableColumn("Acquired") { r in Text(r.acquired.map { $0.formatted(date: .numeric, time: .omitted) } ?? "").monospacedDigit() }.width(84)
                TableColumn("Status") { r in
                    Text(r.security == nil ? (r.problem ?? "") : (r.problem ?? "ok"))
                        .foregroundStyle(r.security == nil ? .red : (r.problem == nil ? .green : .orange))
                }
                .width(150)
            }
            .tableText()
            .frame(minHeight: 240)
            if !preview.skipped.isEmpty {
                Text("Skipped: " + preview.skipped.joined(separator: "; ")).font(.caption).foregroundStyle(.orange).lineLimit(3)
            }
            HStack {
                Spacer()
                Button("Cancel") { store.importPreview = nil; dismiss() }.keyboardShortcut(.cancelAction)
                Button("Replace Holdings") { store.applyImport(preview, replace: true); dismiss() }
                    .disabled(usable == 0)
                    .help("Remove the current holdings (cash stays) and add these")
                Button("Add to Holdings") { store.applyImport(preview, replace: false); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(usable == 0)
            }
        }
        .padding(18)
        .frame(width: 900, height: 520)
    }
}

/// Portfolio ▸ Policy Benchmarks…: benchmarks defined as a policy — dated mixes of index funds or ETFs standing in for
/// asset classes — kept in the security master; saving one writes its month-end snapshots (srm-loader), so attribution
/// measures each month against the mix in force then.
struct PolicyBenchmarkSheet: View {
    @Bindable var store: PortStore
    @Environment(\.dismiss) private var dismiss

    struct Row: Identifiable { let id = UUID(); var ticker = ""; var percent = 0.0 }
    struct EditMix: Identifiable { let id = UUID(); var from = Date(); var rows: [Row] = [Row(), Row()] }

    @State private var list: [SRMPolicyBenchmark] = []
    @State private var selected: String?
    @State private var isNew = false
    @State private var code = ""
    @State private var name = ""
    @State private var mixes: [EditMix] = []
    @State private var problem: String?
    @State private var status: String?
    @State private var working = false

    private static let day: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f }()

    private var valid: Bool {
        code.range(of: "^[A-Za-z0-9_-]{1,40}$", options: .regularExpression) != nil && !mixes.isEmpty
            && mixes.allSatisfy { m in abs(m.rows.filter { !$0.ticker.isEmpty }.reduce(0) { $0 + $1.percent } - 100) < 0.1 }
    }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Policy Benchmarks").heading(.name)
                List(list, selection: $selected) { b in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(b.code).textKind(.ids)
                        Text(b.name).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(b.code)
                }
                .frame(width: 220)
                Button("New Policy Benchmark") { startNew() }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("A benchmark that is your plan: index funds or ETFs standing in for asset classes, with the weights you aim for, and the date each mix took effect. Saved in the security master; month-end snapshots are written for the last two years — months before the first mix use it.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Form {
                    TextField("Code", text: $code, prompt: Text("e.g. POLICY_GROWTH")).disabled(!isNew)
                    TextField("Name", text: $name, prompt: Text("e.g. Growth policy 70/20/10"))
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach($mixes) { $m in mixEditor($m) }
                    }
                }
                HStack {
                    Button("Add a Later Mix") { mixes.append(EditMix(from: Date(), rows: mixes.last?.rows.map { Row(ticker: $0.ticker, percent: $0.percent) } ?? [Row(), Row()])) }
                    if let problem { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout).lineLimit(2) }
                    if let status { Text(status).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
                    Spacer()
                    if working { ProgressView().controlSize(.small) }
                    Button("Use for This Portfolio") { use() }
                        .disabled(isNew || selected == nil || store.openPortfolio == nil)
                        .help("Make it the open portfolio's benchmark (saved with File ▸ Save)")
                    Button("Save") { save() }.disabled(!valid || working)
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(18)
        .frame(width: 980, height: 600)
        .task { await reload(select: nil) }
        .onChange(of: selected) { if let s = selected, let b = list.first(where: { $0.code == s }) { edit(b) } }
    }

    private func mixEditor(_ m: Binding<EditMix>) -> some View {
        let total = m.wrappedValue.rows.filter { !$0.ticker.isEmpty }.reduce(0) { $0 + $1.percent }
        return GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    DatePicker("In effect from", selection: m.from, displayedComponents: .date).fixedSize()
                    Spacer()
                    Text("Total \(total, specifier: "%.1f")%").monospacedDigit().foregroundStyle(abs(total - 100) < 0.1 ? .green : .red)
                    Button("Remove Mix", role: .destructive) { mixes.removeAll { $0.id == m.wrappedValue.id } }
                        .disabled(mixes.count == 1)
                }
                ForEach(m.rows) { $r in
                    HStack {
                        TextField("Ticker (e.g. VTI)", text: $r.ticker).frame(width: 140)
                            .onSubmit { r.ticker = r.ticker.uppercased() }
                        TextField("Weight %", value: $r.percent, format: .number).frame(width: 80)
                        Text("%").foregroundStyle(.secondary)
                        Button { m.wrappedValue.rows.removeAll { $0.id == r.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Add a Security") { m.wrappedValue.rows.append(Row()) }.buttonStyle(.link)
            }
            .padding(4)
        }
    }

    private func startNew() {
        isNew = true; selected = nil; code = ""; name = ""; status = nil; problem = nil
        mixes = [EditMix(from: Calendar.current.date(from: DateComponents(year: Calendar.current.component(.year, from: Date()) - 2, month: 1, day: 1)) ?? Date(),
                         rows: [Row(ticker: "VTI", percent: 60), Row(ticker: "BND", percent: 40)])]
    }

    private func edit(_ b: SRMPolicyBenchmark) {
        isNew = false; code = b.code; name = b.name; status = b.description; problem = nil
        mixes = b.mixes.sorted { $0.effectiveFrom < $1.effectiveFrom }.map { mix in
            EditMix(from: Self.day.date(from: mix.effectiveFrom) ?? Date(),
                    rows: mix.components.map { Row(ticker: $0.ticker, percent: ($0.weight * 1000).rounded() / 10) })
        }
    }

    private func reload(select code: String?) async {
        do {
            list = try await AccountsClient.policyBenchmarks()
            if let code { selected = code } else if list.isEmpty { startNew() } else { selected = list.first?.code }
        } catch {
            problem = error.localizedDescription
        }
    }

    private func save() {
        let p = SRMPolicyBenchmark(code: code.uppercased(), name: name.isEmpty ? code.uppercased() : name, description: nil,
                                   mixes: mixes.map { m in
                                       .init(effectiveFrom: Self.day.string(from: m.from),
                                             components: m.rows.filter { !$0.ticker.isEmpty }.map { .init(ticker: $0.ticker.uppercased(), weight: $0.percent / 100) })
                                   })
        working = true; problem = nil
        Task {
            do {
                let saved = try await AccountsClient.savePolicy(p)
                status = "Saved \(saved.code); its snapshots were written (srm-loader). " + (saved.description ?? "")
                store.srmBenchmarks = (try? await AccountsClient.benchmarks()) ?? store.srmBenchmarks
                SRMRegistry.shared.forgetBenchmark(saved.code)
                await reload(select: saved.code)
                isNew = false
            } catch {
                problem = error.localizedDescription
            }
            working = false
        }
    }

    private func use() {
        guard let code = selected, var mine = store.openPortfolio else { return }
        mine.benchmark = code
        store.portfolio = mine
        Task { await store.useSRMBenchmark(code) }
        status = "\(code) is now the open portfolio's benchmark — File ▸ Save to keep it."
    }
}
