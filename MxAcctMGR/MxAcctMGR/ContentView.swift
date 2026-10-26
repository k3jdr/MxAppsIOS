//
//  ContentView.swift
//  MxAcctMGR
//
//  The main window: the guide in the sidebar (with Quick Help docked under it), the screen, and a status bar.
//  The toolbar picks the account every screen works on and the engine the optimizers use.
//

import SwiftUI

struct ContentView: View {
    @Bindable var store: PortStore
    /// The sidebar sections folded away, by name (comma-separated).
    @AppStorage("sidebarCollapsed") private var collapsed = ""

    private func expanded(_ group: Screen.Group) -> Binding<Bool> {
        Binding(get: { !collapsed.split(separator: ",").contains(Substring(group.rawValue)) },
                set: { open in
                    var names = Set(collapsed.split(separator: ",").map(String.init))
                    if open { names.remove(group.rawValue) } else { names.insert(group.rawValue) }
                    collapsed = names.sorted().joined(separator: ",")
                })
    }

    private func sidebarRows(_ group: Screen.Group) -> some View {
        ForEach(Screen.allCases.filter { $0.group == group && PortSettings.shared.shows($0) }) { screen in
            Label(sidebarTitle(screen),
                  systemImage: screen == .reportWalkthrough ? store.currentReport.symbol : screen.systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .quickHelpArea(PortHelp.about(screen))
                .tag(screen)
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { Optional(store.screen) }, set: { if let s = $0 { store.screen = s } })) {
                // Every section expands and collapses (its disclosure arrow, shown on hover), kept across launches.
                ForEach(Screen.Group.sidebar, id: \.self) { group in
                    Section(group.rawValue, isExpanded: expanded(group)) { sidebarRows(group) }
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
            .quickHelpDock()
        } detail: {
            VStack(spacing: 0) {
                if let problem = store.dataProblem {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(problem).font(.callout).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("Try Again") { Task { await store.loadAccounts() } }
                        Button("Layer 3 Services…") { store.go(.services) }
                    }
                    .padding(10)
                    .background(.orange.opacity(0.12))
                    Divider()
                }
                screen
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Every screen's text can be selected and copied: lessons, figures, cards, table cells; a whole
                    // page with Edit ▸ Copy Page Text, a section from its context menu (Shared/Copy/PageText.swift).
                    .textSelection(.enabled)
                    .copyableText(PageText.page)
                Divider()
                StatusBar(store: store)
            }
            .navigationTitle(store.title(store.screen))
            .navigationSubtitle(store.portfolio.name)
            .toolbar {
                BackForwardButtons(store: store)
                ToolbarItem(placement: .primaryAction) { accountPicker }
                ToolbarItem(placement: .primaryAction) { enginePicker }
            }
        }
        .frame(minWidth: 1180, minHeight: 720)
        .quickHelpScreen(store.title(store.screen), PortHelp.about(store.screen), selection: PortHelp.selection(store))
        .task { start() }
        // Each place visited joins the history (Back and Forward, Navigation.swift).
        .onChange(of: store.place, initial: true) { store.recordPlace() }
        // Settings ▸ Guidance ▸ Minimal closes a lesson-only page that is open.
        .onChange(of: PortSettings.shared.guidance) {
            if !PortSettings.shared.shows(store.screen) { store.go(.myPortfolio) }
        }
        .onOpenURL { url in
            // mxacctmgr://my-portfolio/CODE from MxDataHUB or MxJobsMGR, mxacctmgr://secure-accounts/… from MxJobsMGR's
            // API Subscriptions (Shared/AppLinks.swift).
            switch AppLink(url: url) {
            case let .myPortfolio(code)?:
                if let code { store.requestOpen(code) } else { store.go(.myPortfolio) }
            case let link? where link.appName == "MxAcctMGR":
                store.secureRequest = link
                store.go(.secureAccounts)
            default:
                break
            }
        }
        .sheet(item: Binding(get: { SecurityLinks.shared.editing }, set: { SecurityLinks.shared.editing = $0 })) { SecurityLinkSheet(initial: $0) }
        .sheet(item: Binding(get: { ReportNotes.shared.editing }, set: { ReportNotes.shared.editing = $0 })) { ReportNotesSheet(report: $0) }
        .sheet(item: Binding(get: { PayeeLinks.shared.editing }, set: { PayeeLinks.shared.editing = $0 })) { PayeeLinkSheet(target: $0) }
        .sheet(isPresented: $store.showOpenPortfolio) { OpenPortfolioSheet(store: store) }
        .sheet(isPresented: $store.showNewPortfolio) { NewPortfolioSheet(store: store) }
        .sheet(isPresented: $store.showDecisions) { DecisionsSheet(store: store) }
        .sheet(isPresented: $store.showDuplicate) { DuplicatePortfolioSheet(store: store) }
        .sheet(isPresented: $store.showRename) { RenamePortfolioSheet(store: store) }
        .sheet(isPresented: $store.showPolicyEditor) { PolicyBenchmarkSheet(store: store) }
        .sheet(item: $store.importPreview) { ImportHoldingsSheet(store: store, preview: $0) }
        // Leaving a portfolio with unsaved changes (PortfolioFile.swift).
        .alert("Save changes to \(store.srmCode)?", isPresented: Binding(get: { store.leavePrompt != nil }, set: { if !$0 { store.leavePrompt = nil } }),
               presenting: store.leavePrompt) { prompt in
            Button("Save") {
                Task { if await store.saveSRMAccount() { await prompt.proceed() } }
            }
            Button("Discard Changes", role: .destructive) {
                Task {
                    if let mine = store.openPortfolio { store.markSaved(mine, version: store.openVersion) }
                    await prompt.proceed()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { prompt in
            Text("Before you \(prompt.action), these changes are not saved:\n" + prompt.looseEnds.map { "• " + $0 }.joined(separator: "\n"))
        }
        .alert("Not saved: \(store.srmCode) changed elsewhere", isPresented: Binding(get: { store.saveConflict != nil }, set: { if !$0 { store.saveConflict = nil } })) {
            Button("Keep Editing", role: .cancel) { store.saveConflict = nil }
            Button("Revert to the Saved Version", role: .destructive) { store.saveConflict = nil; store.resetMyPortfolio() }
        } message: {
            Text((store.saveConflict ?? "") + "\n\nYour edits are still here. Revert reads the saved version (yours are lost); or keep editing and copy what you need first.")
        }
        .alert("MxAcctMGR", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
            if store.engine == .services || store.attributeMaster {
                Button("Layer 3 Services…") { store.errorMessage = nil; store.go(.services) }
            }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var screen: some View {
        switch store.screen {
        case .checking: CheckingView(store: store)
        case .cards: CardsView(store: store)
        case .expenseLedgers: ExpenseLedgersView(store: store)
        case .expenses: TargetAccountsView(store: store)
        case .secureAccounts: SecureAccountsView(store: store)
        case .welcome: WelcomeView(store: store)
        case .choosePath: ChoosePathView(store: store)
        case .whyOptimize: WhyOptimizeView(store: store)
        case .whyAttribution: WhyAttributionView(store: store)
        case .activeVsPassive: ActiveVsPassiveView(store: store)
        case .myPortfolio: PortfolioView(store: store, part: .holdings)
        case .myBenchmark: PortfolioView(store: store, part: .benchmark)
        case .myRisk: RiskView(store: store)
        case .myImprove:
            if store.myApproach == .active { OptimizeView(store: store) } else { TrackView(store: store) }
        case .myTrades:
            if store.myApproach == .active { TradesView(store: store) } else { BandsView(store: store) }
        case .myAttribution: AttributionView(store: store)
        case .reportLibrary: ReportLibraryView(store: store)
        case .morningBriefing: MorningBriefingView(store: store)
        case .earningsCalendar: EarningsCalendarView(store: store)
        case .earningsDay: EarningsDayView(store: store)
        case .vix: VIXView(store: store)
        case .compute: ComputeView(store: store)
        case .reportWalkthrough: ReportView(store: store, report: store.currentReport)
        case .securities: SecuritiesView(store: store)
        case .samples: SamplesView(store: store)
        case .services:
            ServicesView()
                .quickHelpArea(PortHelp.about(.services))
        }
    }

    private func sidebarTitle(_ screen: Screen) -> String { store.title(screen, full: false) }

    private var accountPicker: some View {
        Picker(selection: $store.selectedID) {
            ForEach(store.portfolios.filter { $0.id != "mine" }) { p in Text(p.name).tag(p.id) }
            Divider()
            ForEach(store.portfolios.filter { $0.id == "mine" }) { p in Text(p.name).tag(p.id) }
        } label: {
            Label("Account", systemImage: "briefcase")
        }
        .pickerStyle(.menu)
        .fixedSize()
        .disabled(store.screen.group == .mine)
        .help(store.screen.group == .mine ? "The Investments steps always use My Portfolio, your own account" : "The account the report walkthroughs and the Morning Briefing work on")
        .quickHelpArea(PortHelp.samplePicker)
    }

    private var enginePicker: some View {
        Picker(selection: $store.engine) {
            ForEach(EngineChoice.allCases) { Text($0.rawValue).tag($0) }
        } label: {
            Label("Engine", systemImage: "cpu")
        }
        .pickerStyle(.menu)
        .fixedSize()
        .help("Run the optimizers built-in or through the Layer 3 services (portfolio-java, portfolio-cpp)")
        .quickHelpArea(PortHelp.engine)
    }

    /// Launch arguments for testing and demos: `-screen myImprove -sample employer-stock`, and for a report
    /// walkthrough `-screen reportWalkthrough -report cpi -reportStep 5` (0–6; 5 simulates the long run) with `-reaction sell-all`;
    /// for the earnings screens `-earningsDate 2026-10-20` (Earnings by Day, and the month or week the calendar shows)
    /// with `-earningsSymbol PG` (the company selected), and `-earningsMode Week`.
    private func start() {
        NavigationKeys.install(store)
        // Links on tickers and names live in the security master, through the accounts service; links kept on this
        // Mac for its securities go there once it answers.
        SecurityLinks.shared.use(AccountsLinkBackend())
        Task { await SecurityLinks.shared.load() }
        let defaults = UserDefaults.standard
        if let s = defaults.string(forKey: "screen").flatMap(Screen.init(rawValue:)) { store.screen = s }
        if let d = defaults.string(forKey: "earningsDate"), d.count == 10 { store.earnings.date = d; store.earnings.anchor = d }
        if let m = defaults.string(forKey: "earningsMode").flatMap(EarningsStore.Mode.init(rawValue:)) { store.earnings.mode = m }
        if let symbol = defaults.string(forKey: "earningsSymbol") { store.earnings.selection = EarningsParse.key(symbol) }
        if let ticker = defaults.string(forKey: "holding") { store.holdingSelection = [ticker] }
        #if DEBUG
        // Self-tests of the links: open the Link dialog for the selected row (-linkEdit symbol|name), or show the hover
        // card of a linked cell (-linkHoverTest ID, e.g. META|symbol) once the table is up.
        if let field = defaults.string(forKey: "linkEdit").flatMap(LinkTarget.Field.init(rawValue:)) {
            Task {
                try? await Task.sleep(for: .seconds(4))
                SecurityLinks.shared.beginEdit(store.linkSelection?.with(field))
            }
        }
        // Import Holdings from a file without the open panel (-importHoldingsFile /path/to/file.csv), once a portfolio is open.
        if let path = defaults.string(forKey: "importHoldingsFile") {
            Task {
                try? await Task.sleep(for: .seconds(5))
                store.importHoldings(from: URL(fileURLWithPath: path))
            }
        }
        if let id = defaults.string(forKey: "linkHoverTest") {
            Task {
                try? await Task.sleep(for: .seconds(4))
                SecurityLinks.shared.testHover(id)
            }
        }
        // Notes on reports: open the Notes dialog (-reportNotesEdit ID) or show a report's hover card (-reportHoverTest ID).
        if let id = defaults.string(forKey: "reportNotesEdit") {
            Task {
                try? await Task.sleep(for: .seconds(4))
                ReportNotes.shared.beginEdit(MarketReport.report(id))
            }
        }
        // Copy Page Text onto a pasteboard of its own rather than the clipboard (-pageTextTest NAME), once the page has
        // drawn; -pageTextID TITLE copies that section instead of the page.
        if let name = defaults.string(forKey: "pageTextTest") {
            Task {
                try? await Task.sleep(for: .seconds(10))
                let window = NSApp.windows.first { $0.isVisible && $0.contentView != nil && !($0 is NSPanel) }
                let text = PageText.text(of: defaults.string(forKey: "pageTextID").map(PageText.section) ?? PageText.page, in: window)
                let pb = NSPasteboard(name: NSPasteboard.Name(name))
                pb.clearContents()
                pb.setString(text ?? "<nil>", forType: .string)
            }
        }
        // Links on target accounts: open the Link dialog (-payeeLinkEdit PAYEE_ID) or show a linked target's hover
        // card (-payeeLinkHoverTest entry:TXN_ID in a register, payee:PAYEE_ID in Target Accounts).
        if let id = defaults.object(forKey: "payeeLinkEdit") != nil ? defaults.integer(forKey: "payeeLinkEdit") : nil {
            Task {
                try? await Task.sleep(for: .seconds(4))
                PayeeLinks.shared.beginEdit((try? await BankClient.book())?.payees.first { $0.id == id }.map(PayeeLinkTarget.init))
            }
        }
        if let id = defaults.string(forKey: "payeeLinkHoverTest") {
            Task {
                // Once the register (or Target Accounts) has loaded and shows the linked words.
                for _ in 0..<20 where LinkWordsAnchorView.anchors[id]?() == nil { try? await Task.sleep(for: .seconds(1)) }
                LinkWordsAnchorView.testHover(id)
            }
        }
        if let id = defaults.string(forKey: "reportHoverTest") {
            Task {
                // Once the report's name is on screen (the window can take longer than a few seconds to open).
                for _ in 0..<60 where ReportNotes.shared.anchors[id]?()?.window == nil {
                    try? await Task.sleep(for: .seconds(0.5))
                }
                try? await Task.sleep(for: .seconds(1))
                ReportNotes.shared.testHover(id)
            }
        }
        #endif
        if let id = defaults.string(forKey: "sample"), store.portfolios.contains(where: { $0.id == id }) { store.selectedID = id }
        // Every account — the samples and My Portfolio — comes from the security master.
        Task { await store.loadAccounts() }
        if defaults.bool(forKey: "addSecurities") { store.go(.myPortfolio); store.addingSecurities = true }
        if store.screen == .reportWalkthrough, defaults.object(forKey: "reportStep") != nil {
            let r = store.currentReport
            let step = min(max(defaults.integer(forKey: "reportStep"), 0), MarketReport.steps.count - 1)
            store.updateReport(r) { s in
                s.step = step
                if let reaction = defaults.string(forKey: "reaction") { s.reaction = reaction }
            }
            if step == 5 { Task { await store.simulate(r) } }
        }
    }
}

struct StatusBar: View {
    let store: PortStore

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: store.portfolio.symbol).foregroundStyle(.secondary)
            Text("\(store.portfolio.name) — \(store.portfolio.account.rawValue), \(money(store.portfolio.total)) vs \(store.portfolio.benchmark)")
                .lineLimit(1)
            Spacer()
            if let m = store.message { Text(m).foregroundStyle(.secondary).lineLimit(1) }
            if store.busy { ProgressView().controlSize(.small) }
            EducationalBanner(realData: store.screen == .earningsCalendar || store.screen == .earningsDay)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .quickHelpArea("Status", "The account, its type and value and its benchmark; the last action's message; and the reminder that everything here is educational.", symbol: "info.circle")
    }
}
