//
//  MxPortMGRApp.swift
//  MxPortMGR
//
//  A portfolio-management IDE that teaches: one window with a guide in the sidebar — Start Here, My Portfolio, Market
//  Reports (walkthroughs and real earnings), Learn the Why and the Library — over your own account, sample accounts in
//  an illustrative market, or the security master. Optimization and attribution run built-in or through the shared Layer 3
//  services (MXcodeIDE/Services). Educational only; never investment advice.
//

import SwiftUI

@main
struct MxPortMGRApp: App {
    @State private var store = PortStore()

    var body: some Scene {
        Window("MxPortMGR", id: "main") {
            ContentView(store: store)
        }
        .defaultSize(width: 1440, height: 900)
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu("Guide") {
                Button("Welcome") { store.go(.welcome) }
                    .keyboardShortcut("0", modifiers: .command)
                Button("Choose Your Path") { store.go(.choosePath) }
                Divider()
                Section("My Portfolio") {
                    ForEach(Array(Screen.myPath.enumerated()), id: \.element) { i, s in
                        Button(store.title(s, full: false)) { store.go(s) }
                            .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: [.command, .option])
                    }
                }
                Divider()
                Menu("Learn the Why") {
                    ForEach([Screen.whyOptimize, .whyAttribution, .activeVsPassive]) { s in Button(s.title) { store.go(s) } }
                }
                Button("Sample Portfolios") { store.go(.samples) }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Layer 3 Services") { store.go(.services) }
                    .keyboardShortcut("l", modifiers: [.command, .option])
            }
            CommandMenu("Portfolio") {
                Picker("Account", selection: $store.selectedID) {
                    ForEach(store.portfolios) { p in Text(p.name).tag(p.id) }
                }
                Divider()
                // My Portfolio's step 4 follows its approach: optimize (active) or build the tracker (passive).
                Button(store.myApproach == .active ? "Optimize My Portfolio" : "Build My Index Tracker") {
                    store.go(.myImprove)
                    Task { if store.myApproach == .active { await store.optimize() } else { await store.buildTracker() } }
                }
                .keyboardShortcut("r", modifiers: .command)
                Button("Run Attribution") {
                    store.go(.myAttribution)
                    Task { await store.attribute() }
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                Divider()
                Picker("Engine", selection: $store.engine) {
                    ForEach(EngineChoice.allCases) { Text($0.rawValue).tag($0) }
                }
                Divider()
                Button("Copy Account to My Portfolio") {
                    store.copyToMine(store.portfolio)
                    store.go(.myPortfolio)
                }
                    .disabled(store.selectedID == "mine")
                Button("Reset My Portfolio") { store.resetMyPortfolio() }
            }
            CommandMenu("Reports") {
                Button("Report Library") { store.go(.reportLibrary) }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                Button("Morning Briefing") { store.go(.morningBriefing) }
                    .keyboardShortcut("m", modifiers: [.command, .option])
                Button("Earnings Calendar") { store.go(.earningsCalendar) }
                    .keyboardShortcut("e", modifiers: [.command, .option])
                Button("Earnings Today") { store.openEarningsDay(EarningsDates.today()) }
                    .keyboardShortcut("e", modifiers: [.command, .option, .shift])
                Divider()
                Section("The Five Most Important") {
                    ForEach(MarketReport.topFive) { r in
                        Button(r.title) { store.openReport(r.id) }
                            .keyboardShortcut(KeyEquivalent(Character(String(r.topFive!))), modifiers: [.command, .control])
                    }
                }
                Divider()
                ForEach(ReportTier.all) { tier in
                    Menu(tier.title) {
                        ForEach(MarketReport.all.filter { $0.tier == tier.id }) { r in Button(r.title) { store.openReport(r.id) } }
                    }
                }
                Divider()
                Button("Simulate the Long Run") {
                    let r = store.currentReport
                    store.updateReport(r) { $0.step = 5 }
                    Task { await store.simulate(r) }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(store.screen != .reportWalkthrough)
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                // As in MxNoteONE: add or edit the link of the selected company or holding (its symbol, or the name
                // when the pointer rests there).
                Button("Link…") { SecurityLinks.shared.beginEdit(SecurityLinks.shared.commandTarget(selected: store.linkSelection)) }
                    .keyboardShortcut("k")
                    .disabled(store.screen != .earningsDay && store.screen != .myPortfolio || SecurityLinks.shared.editing != nil)
            }
            CommandGroup(after: .sidebar) {
                Button("Previous Step") { if let p = store.screen.previous { store.go(p) } }
                    .keyboardShortcut("[", modifiers: .command)
                Button("Next Step") { if let n = store.screen.next { store.go(n) } }
                    .keyboardShortcut("]", modifiers: .command)
                Divider()
            }
            QuickHelpCommands()
        }
    }
}
