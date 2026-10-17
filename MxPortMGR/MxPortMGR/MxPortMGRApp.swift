//
//  MxPortMGRApp.swift
//  MxPortMGR
//
//  A portfolio-management IDE that teaches: one window with a guide in the sidebar — Start Here, Learn the Why, the
//  Active Portfolio and Passive Index Portfolio paths, Market Reports walkthroughs and the Library — over sample
//  accounts in an illustrative market. Optimization and attribution run built-in or through the shared Layer 3
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
                Menu("Learn the Why") {
                    ForEach([Screen.whyOptimize, .whyAttribution, .activeVsPassive]) { s in Button(s.title) { store.go(s) } }
                }
                Divider()
                Section("My Portfolio") {
                    ForEach(Array(Screen.myPath.enumerated()), id: \.element) { i, s in
                        Button(store.title(s, full: false)) { store.go(s) }
                            .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: [.command, .option])
                    }
                }
                Section("Model Portfolio") {
                    ForEach(Array(store.modelPath.enumerated()), id: \.element) { i, s in
                        Button("\(i + 1). \(s.title)") { store.go(s) }
                            .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .command)
                    }
                    Picker("Model Type", selection: Binding(get: { store.modelApproach }, set: { store.setModelApproach($0) })) {
                        Text("Active").tag(PortfolioStyle.active)
                        Text("Passive Index").tag(PortfolioStyle.passive)
                    }
                }
                Divider()
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
                Button("Optimize (Active)") {
                    store.go(.activeOptimize)
                    Task { await store.optimize() }
                }
                .keyboardShortcut("r", modifiers: .command)
                Button("Build Index Tracker (Passive)") {
                    store.go(.passiveTrack)
                    Task { await store.buildTracker() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Run Attribution") {
                    if store.screen != .passiveAttribution { store.go(.activeAttribution) }
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
            CommandGroup(after: .sidebar) {
                Button("Previous Step") { if let p = store.screen.guidePrevious { store.go(p) } }
                    .keyboardShortcut("[", modifiers: .command)
                Button("Next Step") { if let n = store.screen.guideNext { store.go(n) } }
                    .keyboardShortcut("]", modifiers: .command)
                Divider()
            }
            QuickHelpCommands()
        }
    }
}
