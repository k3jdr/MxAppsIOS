//
//  ServicesWorkflowsView.swift
//  MxDataHUB
//
//  Services & Workflows: the Layer 3 services (Services/) that refresh and analyse this security master, and
//  the MxJobsMGR workflows built on them. Portfolio workflows open for the portfolio selected in Portfolios.
//

import SwiftUI

struct ServicesWorkflowsView: View {
    @Bindable var store: SRMStore
    /// Launch argument `-servicesTab Services` opens the services list (like `-section`).
    @State private var tab = UserDefaults.standard.string(forKey: "servicesTab") == "Services" ? "Services" : "Workflows"
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Show", selection: $tab) {
                    Text("Workflows").tag("Workflows")
                    Text("Layer 3 Services").tag("Services")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .quickHelp(HubHelp.servicesTabs.title, HubHelp.servicesTabs.detail)
                Spacer()
                Text("MxDataHUB keeps the data; MxJobsMGR runs the workflows over it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
            Divider()
            if tab == "Services" {
                ServicesView(openSample: open, openSampleTitle: "Open in MxJobsMGR")
            } else {
                SampleGalleryView(open: open, openTitle: "Open in MxJobsMGR", note: note)
            }
        }
        .alert("MxDataHUB", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    private var note: String {
        if let p = store.selectedPortfolio {
            return "Portfolio workflows open for \(p.code)" + (p.benchmarkCode.isEmpty ? "" : " against \(p.benchmarkCode)")
                + " — the portfolio selected in Portfolios."
        }
        return "Select a portfolio in Portfolios to open the portfolio workflows for it (otherwise they use DEMO_GROWTH)."
    }

    private func open(_ sample: SampleInfo) {
        let p = sample.takesPortfolio ? store.selectedPortfolio : nil
        if !AppLink.sample(id: sample.id, portfolio: p?.code, benchmark: p.map(\.benchmarkCode)).open() {
            message = "MxJobsMGR is not installed in Applications."
        }
    }
}

/// The MxJobsMGR workflows for a portfolio (Portfolios screen).
struct PortfolioWorkflowsMenu: View {
    var portfolio: PortfolioRow?
    @State private var message: String?

    var body: some View {
        Menu {
            Section("Open in MxJobsMGR") {
                Button("Optimize — active vs \(benchmark)") { open("active-optimization") }
                Button("Track \(benchmark) — passive") { open("passive-tracking") }
                Button("Attribution vs \(benchmark)") { open("attribution") }
            }
        } label: {
            Label("Workflows", systemImage: "flowchart")
        }
        .fixedSize()
        .disabled(portfolio == nil)
        .help("Optimize, track or attribute this portfolio in MxJobsMGR")
        .quickHelp("Workflows", "Opens a workflow for this portfolio in MxJobsMGR: optimize it against \(benchmark) within a tracking-error budget, track \(benchmark) passively, or attribute its returns against \(benchmark).")
        .alert("MxDataHUB", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    private var benchmark: String { portfolio?.benchmarkCode.isEmpty == false ? portfolio!.benchmarkCode : "benchmark" }

    private func open(_ id: String) {
        guard let p = portfolio else { return }
        if !AppLink.sample(id: id, portfolio: p.code, benchmark: p.benchmarkCode).open() {
            message = "MxJobsMGR is not installed in Applications."
        }
    }
}
