//
//  ContentView.swift
//  MxPortMGR
//
//  The main window: the guide in the sidebar (with Quick Help docked under it), the screen, and a status bar.
//  The toolbar picks the account every screen works on and the engine the optimizers use.
//

import SwiftUI

struct ContentView: View {
    @Bindable var store: PortStore

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { Optional(store.screen) }, set: { if let s = $0 { store.screen = s } })) {
                ForEach(Screen.Group.allCases, id: \.self) { group in
                    Section(group.rawValue) {
                        ForEach(Screen.allCases.filter { $0.group == group }) { screen in
                            Label(sidebarTitle(screen),
                                  systemImage: screen == .reportWalkthrough ? store.currentReport.symbol : screen.systemImage)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .quickHelpArea(PortHelp.about(screen))
                                .tag(screen)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
            .quickHelpDock()
        } detail: {
            VStack(spacing: 0) {
                screen
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                StatusBar(store: store)
            }
            .navigationTitle(store.title(store.screen))
            .navigationSubtitle(store.portfolio.name)
            .toolbar {
                ToolbarItem(placement: .primaryAction) { accountPicker }
                ToolbarItem(placement: .primaryAction) { enginePicker }
            }
        }
        .frame(minWidth: 1180, minHeight: 720)
        .quickHelpScreen(store.title(store.screen), PortHelp.about(store.screen), selection: PortHelp.selection(store))
        .task { start() }
        .onOpenURL { url in
            // mxportmgr://my-portfolio/CODE from MxDataHUB or MxJobsWMS (Shared/AppLinks.swift).
            if case let .myPortfolio(code)? = AppLink(url: url) {
                store.go(.myPortfolio)
                if let code {
                    store.srmCode = code
                    Task {
                        if store.portfolio.isSRM { await store.openSRMAccount(code) } else { await store.setMySource(srm: true) }
                    }
                }
            }
        }
        .sheet(item: Binding(get: { SecurityLinks.shared.editing }, set: { SecurityLinks.shared.editing = $0 })) { SecurityLinkSheet(initial: $0) }
        .alert("MxPortMGR", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
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
        case .reportWalkthrough: ReportView(store: store, report: store.currentReport)
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
        .help(store.screen.group == .mine ? "The My Portfolio path always uses My Portfolio" : "The account the report walkthroughs and the Morning Briefing work on")
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
        let defaults = UserDefaults.standard
        if let s = defaults.string(forKey: "screen").flatMap(Screen.init(rawValue:)) { store.screen = s }
        if let d = defaults.string(forKey: "earningsDate"), d.count == 10 { store.earnings.date = d; store.earnings.anchor = d }
        if let m = defaults.string(forKey: "earningsMode").flatMap(EarningsStore.Mode.init(rawValue:)) { store.earnings.mode = m }
        if let symbol = defaults.string(forKey: "earningsSymbol") { store.earnings.selection = EarningsParse.key(symbol) }
        if let ticker = defaults.string(forKey: "holding") { store.holdingSelection = ticker }
        #if DEBUG
        // Self-tests of the links: open the Link dialog for the selected row (-linkEdit symbol|name), or show the hover
        // card of a linked cell (-linkHoverTest ID, e.g. META|symbol) once the table is up.
        if let field = defaults.string(forKey: "linkEdit").flatMap(LinkTarget.Field.init(rawValue:)) {
            Task {
                try? await Task.sleep(for: .seconds(4))
                SecurityLinks.shared.beginEdit(store.linkSelection?.with(field))
            }
        }
        if let id = defaults.string(forKey: "linkHoverTest") {
            Task {
                try? await Task.sleep(for: .seconds(4))
                SecurityLinks.shared.testHover(id)
            }
        }
        #endif
        if let id = defaults.string(forKey: "sample"), store.portfolios.contains(where: { $0.id == id }) { store.selectedID = id }
        if defaults.string(forKey: "mySource") == "srm" { Task { await store.openSRMAccount(store.srmCode) } }
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
