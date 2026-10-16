//
//  SRMSecuritiesView.swift
//  MxDataHUB
//
//  SRM ▸ Securities: search by name or any identifier (ISIN, CUSIP, SEDOL, FIGI, ticker,
//  TICKER:MIC, CIK, LEI), filter by type and benchmark, and see a security's identifiers with
//  their history, listings, issuer, classifications, benchmark weights, corporate actions and prices.
//

import Charts
import SwiftUI

struct SRMSecuritiesView: View {
    @Bindable var store: SRMStore

    var body: some View {
        HSplitView {
            searchPanel
                .frame(minWidth: 460, idealWidth: 600, maxWidth: 720)
            detailPanel
                .frame(minWidth: 440, idealWidth: 540)
        }
        .task { if store.results.isEmpty { await store.search() } }
        .task(id: store.selectedSecurityID) { await store.loadDetail() }
    }

    private var searchPanel: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Name, ticker, ISIN, CUSIP, SEDOL, FIGI, CIK or LEI", text: $store.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await store.search() } }
                Button("Search") { Task { await store.search() } }
                    .keyboardShortcut(.defaultAction)
            }
            HStack {
                Picker("Type", selection: $store.typeFilter) {
                    Text("All types").tag("All")
                    ForEach(store.securityTypes, id: \.self) { Text($0).tag($0) }
                }
                .fixedSize()
                Picker("In", selection: $store.benchmarkFilter) {
                    Text("Any benchmark").tag("")
                    ForEach(store.benchmarks) { Text($0.code).tag($0.code) }
                }
                .fixedSize()
                Toggle("Active only", isOn: $store.activeOnly)
                    .toggleStyle(.checkbox)
                Spacer()
            }
            .onChange(of: store.typeFilter) { Task { await store.search() } }
            .onChange(of: store.benchmarkFilter) { Task { await store.search() } }
            .onChange(of: store.activeOnly) { Task { await store.search() } }

            Table(store.results, selection: $store.selectedSecurityID) {
                TableColumn("Ticker", value: \.ticker).width(min: 50, ideal: 70)
                TableColumn("Name", value: \.name).width(min: 140, ideal: 220)
                TableColumn("Type", value: \.type).width(min: 60, ideal: 90)
                TableColumn("ISIN", value: \.isin).width(min: 90, ideal: 110)
                TableColumn("CUSIP", value: \.cusip).width(min: 70, ideal: 85)
                TableColumn("Composite FIGI", value: \.figi).width(min: 90, ideal: 110)
                TableColumn("Sector", value: \.sector).width(min: 60, ideal: 120)
                TableColumn("MIC", value: \.mic).width(min: 40, ideal: 45)
            }
            HStack {
                Text(store.resultsTruncated ? "First 1,000 matches — narrow the search" : "\(store.results.count.formatted()) securities")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(10)
    }

    @ViewBuilder
    private var detailPanel: some View {
        if let detail = store.detail, detail.security.id == store.selectedSecurityID {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(detail.security.name).font(.title2.bold()).textSelection(.enabled)
                        Text([detail.security.ticker, detail.security.mic, detail.security.type, detail.security.sector]
                            .filter { !$0.isEmpty }.joined(separator: " · "))
                            .foregroundStyle(.secondary)
                    }

                    if !detail.prices.isEmpty {
                        Chart(detail.prices) {
                            LineMark(x: .value("Date", $0.date), y: .value("Close", $0.close))
                                .interpolationMethod(.linear)
                        }
                        .chartYScale(domain: .automatic(includesZero: false))
                        .frame(height: 140)
                    }

                    section("Identifiers") {
                        Table(detail.identifiers) {
                            TableColumn("Type", value: \.type).width(min: 60, ideal: 90)
                            TableColumn("Value") { Text($0.value).textSelection(.enabled).foregroundStyle($0.isCurrent ? .primary : .secondary) }
                                .width(min: 100, ideal: 112)
                            TableColumn("MIC", value: \.mic).width(min: 40, ideal: 44)
                            TableColumn("From") { Text(knownDate($0.from)) }.width(min: 56, ideal: 66)
                            TableColumn("To") { Text($0.to.isEmpty ? "current" : $0.to) }.width(min: 50, ideal: 58)
                            TableColumn("Source", value: \.source).width(min: 50, ideal: 74)
                        }
                        .frame(height: CGFloat(min(12, detail.identifiers.count + 1)) * 24 + 8)
                    }

                    section("Issuer and security") {
                        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                            ForEach(detail.facts) { FactRow(name: $0.name, value: $0.value) }
                        }
                    }

                    if !detail.listings.isEmpty {
                        section("Listings") {
                            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                                ForEach(detail.listings) { l in
                                    GridRow {
                                        Text(l.ticker).bold()
                                        Text("\(l.mic) \(l.exchange)").lineLimit(1)
                                        Text(l.isPrimary ? "primary" : "").foregroundStyle(.secondary)
                                        Text(l.to.isEmpty ? (knownDate(l.from).isEmpty ? "current" : "since \(l.from)") : "\(knownDate(l.from)) – \(l.to)")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }

                    if !detail.classifications.isEmpty {
                        section("Classification") {
                            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                                ForEach(detail.classifications) { FactRow(name: $0.name, value: $0.value) }
                            }
                        }
                    }

                    section("Benchmark membership") {
                        if detail.memberships.isEmpty {
                            Text("Not in any loaded benchmark").foregroundStyle(.secondary)
                        } else {
                            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                                ForEach(detail.memberships) { FactRow(name: $0.name, value: $0.value) }
                            }
                        }
                    }

                    if !detail.actions.isEmpty {
                        section("Corporate actions") {
                            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                                ForEach(detail.actions) { a in
                                    GridRow {
                                        Text(a.exDate).monospacedDigit()
                                        Text(a.type.replacingOccurrences(of: "_", with: " ").capitalized)
                                        Text(a.detail)
                                        Text(a.source).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("Select a security", systemImage: "magnifyingglass",
                                   description: Text("Search by name or any identifier."))
        }
    }

    /// 1900-01-01 marks a value whose start is unknown (it was already valid at the first load).
    private func knownDate(_ day: String) -> String { day == "1900-01-01" ? "" : day }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }
}
