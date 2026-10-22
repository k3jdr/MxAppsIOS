//
//  SRMBenchmarksView.swift
//  MxDataHUB
//
//  SRM ▸ Benchmarks: loaded benchmarks with constituents and weights, sector weights and the
//  index level, custom benchmarks built from another benchmark's members (equal or market-cap
//  weighted, optionally one sector), and which benchmarks the data sources can and cannot supply.
//

import Charts
import SwiftUI

struct SRMBenchmarksView: View {
    @Bindable var store: SRMStore
    @State private var building = false
    @State private var showAvailability = false
    @State private var confirmDelete = false
    @State private var filter = ""

    var body: some View {
        SplitPanes(id: "benchmarks", widths: 300...390, ideal: 380, trailingMinimum: 520) {
            VStack(spacing: 8) {
                Table(store.benchmarks, selection: $store.selectedBenchmarkID) {
                    TableColumn("Code", value: \.code).width(min: 50, ideal: 56)
                    TableColumn("Name", value: \.name).width(min: 70, ideal: 100)
                    TableColumn("Members") { Text($0.members.formatted()).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing) }
                        .width(min: 46, ideal: 52)
                    TableColumn("As of", value: \.asOf).width(min: 76, ideal: 80)
                }
                .quickHelpArea(HubHelp.benchmarkList)
                HStack {
                    Button("Build Custom…") { building = true }
                        .quickHelp("Build Custom Benchmark", "A benchmark from another's members on its latest date: equal weighted or by market cap, optionally one sector only.")
                    Button("Availability…") { showAvailability = true }
                        .quickHelp("Availability", "Which benchmarks the data sources can supply, and which they can't (and why).")
                    Button("Track…") {
                        if let b = store.selectedBenchmark {
                            AppLink.sample(id: "passive-tracking", portfolio: nil, benchmark: b.code).open()
                        }
                    }
                    .disabled(store.selectedBenchmark == nil)
                    .help("Build an index-tracking portfolio for this benchmark in MxJobsWMS")
                    .quickHelp("Track", "Opens MxJobsWMS's passive tracking workflow for this benchmark: an index-tracking portfolio within a tracking-error budget.")
                    Spacer()
                    Button("Delete…", role: .destructive) { confirmDelete = true }
                        .disabled(!(store.selectedBenchmark?.isCustom ?? false))
                        .help("Only custom benchmarks built here can be deleted")
                        .quickHelp("Delete Benchmark", "Deletes a custom benchmark built here, after asking. Loaded benchmarks can't be deleted.")
                }
            }
            .padding(10)
        } trailing: {
            detail
        }
        .task { await store.refreshBenchmarks() }
        .task(id: store.selectedBenchmarkID) { await store.loadBenchmark() }
        .sheet(isPresented: $building) { BuildBenchmarkDialog(store: store) }
        .sheet(isPresented: $showAvailability) { BenchmarkAvailabilitySheet() }
        .confirmationDialog("Delete benchmark \(store.selectedBenchmark?.code ?? "")?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                if let id = store.selectedBenchmarkID { Task { await store.deleteBenchmark(id) } }
            }
        }
    }

    private var filteredConstituents: [ConstituentRow] {
        let f = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !f.isEmpty else { return store.constituents }
        return store.constituents.filter { $0.ticker.lowercased().contains(f) || $0.name.lowercased().contains(f) || $0.sector.lowercased().contains(f) }
    }

    @ViewBuilder
    private var detail: some View {
        if let b = store.selectedBenchmark {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(b.name).font(.title3.bold())
                        Text(b.code).foregroundStyle(.secondary)
                        if b.isProxy {
                            Text("PROXY").font(.caption.bold()).padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.orange.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
                                .help(b.proxyNote)
                        }
                    }
                    Text("\(b.method.replacingOccurrences(of: "_", with: " "))-weighted · source: \(b.source)"
                         + (b.asOf.isEmpty ? "" : " · \(b.members) members on \(b.asOf), \(b.snapshots) snapshot\(b.snapshots == 1 ? "" : "s")"))
                        .foregroundStyle(.secondary)
                    if !b.proxyNote.isEmpty { Text(b.proxyNote).font(.callout).foregroundStyle(.secondary) }
                }

                if b.members == 0 {
                    ContentUnavailableView("No constituents loaded", systemImage: "tray",
                                           description: Text("Run SRM/srm.py load ssga (S&P / Dow) or load nasdaq100."))
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        Chart(store.sectorWeights.prefix(12)) { s in
                            BarMark(x: .value("Weight", s.weight * 100), y: .value("Sector", s.sector))
                                .annotation(position: .trailing) {
                                    Text(percentText(s.weight, digits: 1)).font(.caption2).foregroundStyle(.secondary)
                                }
                        }
                        .chartXAxisLabel("% of benchmark")
                        .frame(minWidth: 300)
                        .frame(height: CGFloat(min(12, store.sectorWeights.count)) * 24 + 40)
                        if !store.levels.isEmpty {
                            Chart(store.levels) {
                                LineMark(x: .value("Date", $0.date), y: .value("Level", $0.close))
                            }
                            .chartYScale(domain: .automatic(includesZero: false))
                            .chartXAxisLabel("Index level (\(store.selectedBenchmark?.code ?? ""))")
                            .frame(minWidth: 260, maxHeight: CGFloat(min(12, store.sectorWeights.count)) * 24 + 40)
                        }
                    }

                    TextField("Filter constituents", text: $filter).textFieldStyle(.roundedBorder)
                    Table(filteredConstituents) {
                        TableColumn("Ticker", value: \.ticker).width(min: 45, ideal: 60)
                        TableColumn("Name", value: \.name).width(min: 140, ideal: 240)
                        TableColumn("Sector", value: \.sector).width(min: 80, ideal: 150)
                        TableColumn("Weight") { Text(percentText($0.weight)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing) }
                            .width(min: 60, ideal: 80)
                        TableColumn("Shares") { Text(numberText($0.shares, digits: 0)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing) }
                            .width(min: 60, ideal: 100)
                    }
                    .quickHelpArea(HubHelp.constituents)
                    Text("\(filteredConstituents.count) of \(store.constituents.count) · weights total \(percentText(store.constituents.reduce(0) { $0 + $1.weight }, digits: 2))")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
        } else {
            ContentUnavailableView("Select a benchmark", systemImage: "chart.pie")
        }
    }
}

struct BuildBenchmarkDialog: View {
    let store: SRMStore
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var name = ""
    @State private var parent = "SP500"
    @State private var method = "equal"
    @State private var sector = ""

    private var problems: [String] {
        var out: [String] = []
        if code.range(of: "^[A-Za-z0-9_]{2,30}$", options: .regularExpression) == nil { out.append("Code: 2–30 letters, digits or _") }
        if let existing = store.benchmarks.first(where: { $0.code == code.uppercased() }), !existing.isCustom {
            out.append("\(existing.code) is a loaded benchmark; choose another code")
        }
        if name.trimmingCharacters(in: .whitespaces).isEmpty { out.append("Enter a name") }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Build Custom Benchmark").font(.headline)
            Form {
                TextField("Code", text: $code, prompt: Text("SP500_EW"))
                TextField("Name", text: $name, prompt: Text("S&P 500 Equal Weight"))
                Picker("Members of", selection: $parent) {
                    ForEach(store.benchmarks.filter { $0.members > 0 }) { Text("\($0.code) — \($0.name)").tag($0.code) }
                }
                Picker("Weighting", selection: $method) {
                    Text("Equal weight").tag("equal")
                    Text("Market cap (latest FMP / Nasdaq caps)").tag("cap")
                }
                Picker("Sector", selection: $sector) {
                    Text("All sectors").tag("")
                    ForEach(store.sectors, id: \.self) { Text($0).tag($0) }
                }
            }
            Text("Uses the members on the latest date. Market-cap weighting needs market caps, which the FMP profile loader stores; members without one are left out. A sector filter needs FMP sectors.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(problems, id: \.self) { Text($0).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Build") {
                    Task {
                        if await store.buildBenchmark(code: code, name: name, parent: parent, method: method,
                                                      sector: sector.isEmpty ? nil : sector) {
                            dismiss()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!problems.isEmpty || store.busy)
            }
        }
        .padding(18)
        .frame(width: 480)
    }
}

/// Which benchmarks the subscriptions and free sources can supply, and why.
struct BenchmarkAvailabilitySheet: View {
    @Environment(\.dismiss) private var dismiss

    private let can: [(String, String)] = [
        ("S&P 500", "Members, weights and shares from State Street's daily SPY holdings (SPY fully replicates the index). Index level ^GSPC from FMP."),
        ("Dow Jones Industrial Average", "Members and weights from the DIA holdings (price-weighted). Level ^DJI from FMP."),
        ("S&P MidCap 400 / SmallCap 600", "Members and weights from the MDY / SPSM holdings. No index levels on the FMP plan."),
        ("Nasdaq-100", "Official members from Nasdaq.com with market caps; weights are plain cap weights, not Nasdaq's modified-cap weights. No ^NDX levels on the FMP plan."),
        ("Custom", "Equal- or cap-weighted subsets of any loaded benchmark, optionally by sector (Build Custom…)."),
    ]
    private let cannot: [(String, String)] = [
        ("Official S&P / Dow / Nasdaq weights", "Licensed index data. FMP's sp500-constituent, nasdaq-constituent, dowjones-constituent and historical constituent endpoints return 402 on this plan."),
        ("ETF holdings via FMP", "etf/holdings is not on the plan (402); SPDR files are read directly instead."),
        ("Russell 1000 / 2000 / 3000", "FTSE Russell data is licensed; iShares holdings downloads (IWB, IWM) were blocked when probed. Would need iShares files or a paid feed."),
        ("MSCI, FTSE, STOXX and other non-US indexes", "Licensed; no free constituent source, and the securities universe loaded here is US listings."),
        ("Constituent history before the first load", "Free sources publish only the current holdings; history accumulates one snapshot per load from now on."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Benchmark availability").font(.headline)
            GroupBox("Can be built") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(can, id: \.0) { item in
                        Label { Text("**\(item.0)** — \(item.1)") } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Cannot be built") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(cannot, id: \.0) { item in
                        Label { Text("**\(item.0)** — \(item.1)") } icon: { Image(systemName: "xmark.circle.fill").foregroundStyle(.red) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(18)
        .frame(width: 620)
        .fixedSize(horizontal: false, vertical: true)
    }
}
