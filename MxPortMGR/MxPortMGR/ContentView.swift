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
                            Label(screen == .reportWalkthrough ? store.currentReport.title : screen.step.map { "\($0). \(screen.title)" } ?? screen.title,
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
            .navigationTitle(store.screen.fullTitle)
            .navigationSubtitle(store.portfolio.name)
            .toolbar {
                ToolbarItem(placement: .primaryAction) { accountPicker }
                ToolbarItem(placement: .primaryAction) { enginePicker }
            }
        }
        .frame(minWidth: 1180, minHeight: 720)
        .quickHelpScreen(store.screen.fullTitle, PortHelp.about(store.screen), selection: PortHelp.selection(store))
        .task { start() }
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
        case .activePortfolio, .passivePortfolio: PortfolioView(store: store)
        case .activeRisk: RiskView(store: store)
        case .activeOptimize: OptimizeView(store: store)
        case .activeTrades: TradesView(store: store)
        case .activeAttribution, .passiveAttribution: AttributionView(store: store)
        case .passiveDrift: DriftView(store: store)
        case .passiveTrack: TrackView(store: store)
        case .passiveBands: BandsView(store: store)
        case .reportLibrary: ReportLibraryView(store: store)
        case .morningBriefing: MorningBriefingView(store: store)
        case .reportWalkthrough: ReportView(store: store, report: store.currentReport)
        case .samples: SamplesView(store: store)
        case .services:
            ServicesView()
                .quickHelpArea(PortHelp.about(.services))
        }
    }

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
        .help("The account every screen works on")
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

    /// Launch arguments for testing and demos: `-screen activeOptimize -sample employer-stock`, and for a report
    /// walkthrough `-screen reportWalkthrough -report cpi -reportStep 5` (0–6; 5 simulates the long run) with `-reaction sell-all`.
    private func start() {
        let defaults = UserDefaults.standard
        if let s = defaults.string(forKey: "screen").flatMap(Screen.init(rawValue:)) { store.screen = s }
        if let id = defaults.string(forKey: "sample"), store.portfolios.contains(where: { $0.id == id }) { store.selectedID = id }
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
            EducationalBanner()
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .quickHelpArea("Status", "The account, its type and value and its benchmark; the last action's message; and the reminder that everything here is educational.", symbol: "info.circle")
    }
}
