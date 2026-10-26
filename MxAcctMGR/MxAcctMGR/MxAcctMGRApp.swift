//
//  MxAcctMGRApp.swift
//  MxAcctMGR
//
//  A portfolio-management IDE that teaches: one window with a guide in the sidebar — My Portfolio, Knowledge Library
//  (walkthroughs, real earnings and the Why lessons) and the Library; Welcome in the Guide menu — over your own account or the sample
//  accounts, all in the security master (real securities and prices). Risk inputs and attribution come from the shared
//  Layer 3 services (MxAppsIOS/Services); the optimizer runs built-in or there. Educational only; never investment advice.
//

import SwiftUI

@main
struct MxAcctMGRApp: App {
    @State private var store = PortStore()
    // Quitting with unsaved portfolio changes asks to Save, Don't Save or Cancel (PortfolioFile.swift).
    @NSApplicationDelegateAdaptor(PortAppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("MxAcctMGR", id: "main") {
            ContentView(store: store)
                .onAppear { PortAppDelegate.store = store }
        }
        .defaultSize(width: 1440, height: 900)
        .windowResizability(.contentMinSize)
        .commands {
            // Back, Forward and History (⌘[ ⌘]), and the guide's Previous and Next Step (⌥⌘↑ ⌥⌘↓) — Navigation.swift.
            GoCommands(store: store)
            // File: one portfolio open at a time, kept in the security master (PortfolioFile.swift).
            CommandGroup(replacing: .newItem) {
                Button("New Portfolio…") { store.showNewPortfolio = true }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Open Portfolio…") { store.showOpenPortfolio = true }
                    .keyboardShortcut("o", modifiers: .command)
                Menu("Open Recent") {
                    ForEach(store.recentPortfolios, id: \.self) { code in Button(code) { store.requestOpen(code) } }
                    if !store.recentPortfolios.isEmpty { Divider() }
                    Button("Clear Menu") { store.clearRecent() }.disabled(store.recentPortfolios.isEmpty)
                }
            }
            CommandGroup(replacing: .saveItem) {
                Button("Close Portfolio") { store.closePortfolio() }
                    .disabled(store.openPortfolio == nil)
                Button("Save") { Task { await store.saveSRMAccount() } }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(store.openPortfolio == nil || !store.isDirty)
                Button("Revert to Saved") { store.resetMyPortfolio() }
                    .disabled(store.openPortfolio == nil || !store.isDirty)
                Divider()
                Button("Duplicate Portfolio…") { store.showDuplicate = true }
                    .disabled(store.openPortfolio == nil || store.openVersion == 0)
                Button("Rename Portfolio…") { store.showRename = true }
                    .disabled(store.openPortfolio == nil)
                Divider()
                Button("Import Holdings…") { store.importHoldings() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(store.openPortfolio == nil)
                Menu("Export Portfolio") {
                    Button("As JSON (account, lots, preferences, decisions)…") { store.exportPortfolio(csv: false) }
                    Button("As CSV (tax lots)…") { store.exportPortfolio(csv: true) }
                }
                .disabled(store.openPortfolio == nil || store.openVersion == 0)
            }
            CommandMenu("Guide") {
                LessonPageItems {
                    Button("Welcome") { store.go(.welcome) }
                        .keyboardShortcut("0", modifiers: .command)
                    Button("Choose Your Path") { store.go(.choosePath) }
                    Divider()
                }
                Section("Investments") {
                    ForEach(Array(Screen.myPath.enumerated()), id: \.element) { i, s in
                        Button(store.title(s, full: false)) { store.go(s) }
                            .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: [.command, .option])
                    }
                }
                Divider()
                LessonPageItems {
                    Menu("Learn the Why") {
                        ForEach([Screen.whyOptimize, .whyAttribution, .activeVsPassive]) { s in Button(s.title) { store.go(s) } }
                    }
                }
                Button("Spending Analysis") { store.go(.spending) }
                Button("SRM Table") { store.go(.securities) }
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
                // Investments' step 4 follows its approach: optimize (active) or build the tracker (passive).
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
                Button("Decisions…") { store.showDecisions = true }
                    .keyboardShortcut("d", modifiers: [.command, .option])
                    .disabled(store.openPortfolio == nil)
                Button("Policy Benchmarks…") { store.showPolicyEditor = true }
                Divider()
                Picker("Engine", selection: $store.engine) {
                    ForEach(EngineChoice.allCases) { Text($0.rawValue).tag($0) }
                }
                Divider()
                Button("Copy Account into the Open Portfolio") {
                    store.copyToMine(store.portfolio)
                    store.go(.myPortfolio)
                }
                    .disabled(store.selectedID == "mine" || store.openPortfolio == nil)
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
                Button("CBOE Volatility Index (VIX)") { store.go(.vix) }
                    .keyboardShortcut("v", modifiers: [.command, .option])
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
                        ForEach(MarketReport.all.filter { $0.tier == tier.id }) { r in
                            Button(r.title) { store.openReport(r.id) }
                            // The hyperscalers' capex sits with the chip makers' sales.
                            if r.id == MarketReport.semiconductors.id {
                                Button("Compute Hyperscalers Tracking") { store.go(.compute) }
                                    .keyboardShortcut("u", modifiers: [.command, .option])
                            }
                        }
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
                // The whole page as text, laid out as on screen (Shared/Copy/PageText.swift); a section's context menu
                // has Copy Section.
                Button("Copy Page Text") { PageText.copy(PageText.page) }
                    .keyboardShortcut("c", modifiers: [.command, .option, .shift])
                // As in MxNoteONE: add or edit the link of the selected company or holding (its symbol, or the name
                // when the pointer rests there).
                Button("Link…") {
                    SecurityLinks.shared.beginEdit(SecurityLinks.shared.commandTarget(
                        selected: store.addingSecurities ? store.addSecuritiesLink : store.linkSelection))
                }
                .keyboardShortcut("k")
                .disabled(store.screen != .earningsDay && store.screen != .myPortfolio || SecurityLinks.shared.editing != nil
                          || store.addingSecurities && store.addSecuritiesLink == nil)
            }
            QuickHelpCommands()
        }
        // MxAcctMGR ▸ Settings (⌘,): the headings' fonts and the instruction level (PortSettings.swift).
        Settings {
            PortSettingsView()
        }
    }
}
