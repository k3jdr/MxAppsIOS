//
//  SRMLoadsView.swift
//  MxDataHUB
//
//  SRM ▸ Load History: identifier coverage, the data sources with their plan limits, the weight history
//  (dated benchmark and portfolio snapshots) and the load audit trail (srm.load_run). Loads themselves run
//  from SRM/srm.py.
//

import SwiftUI

struct SRMLoadsView: View {
    @Bindable var store: SRMStore

    var body: some View {
        VSplitView {
            // Coverage | sources | snapshot history; together within the window minimum ContentView sets.
            SplitPanes(id: "loadsCoverage", widths: 340...640, ideal: 440, trailingMinimum: 647) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Identifier coverage").font(.headline)
                    Table(store.coverage) {
                        TableColumn("Identifier", value: \.name).width(min: 120, ideal: 180)
                        TableColumn("Securities") { Text($0.securities.formatted()).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing) }
                            .width(min: 60, ideal: 80)
                        TableColumn("Coverage") { row in
                            HStack {
                                ProgressView(value: min(1, row.percent / 100)).frame(width: 60)
                                Text("\(row.percent.formatted())%").monospacedDigit()
                            }
                        }
                        .width(min: 100, ideal: 120)
                        TableColumn("Sources", value: \.sources)
                    }
                }
                .quickHelpArea("Identifier Coverage", "How many securities have each kind of identifier (ISIN, CUSIP, FIGI, LEI…), as a share of all, and the sources they came from.",
                               symbol: "checklist")
                .padding(10)
            } trailing: {
                SplitPanes(id: "loadsSources", widths: 300...600, ideal: 380, trailingMinimum: 340) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Sources").font(.headline)
                        Table(store.sources) {
                            TableColumn("Code", value: \.code).width(min: 70, ideal: 100)
                            TableColumn("Last load", value: \.lastLoad).width(min: 90, ideal: 110)
                            TableColumn("Terms and plan") { Text($0.note).lineLimit(3).help($0.note) }
                        }
                    }
                    .quickHelpArea("Sources", "The data sources the loaders read, when each last loaded, and its terms and plan limits (rest the pointer on a note for all of it).",
                                   symbol: "shippingbox")
                    .padding(10)
                } trailing: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Snapshot history").font(.headline)
                            .help("Dated weight snapshots: attribution uses the one at the start of each month")
                        Table(store.snapshotCoverage) {
                            TableColumn("Weights of") { (row: SnapshotCoverageRow) in
                                Text(row.code).help(row.kind == "benchmark" ? "Benchmark" : "Portfolio")
                            }
                            .width(min: 80, ideal: 110)
                            TableColumn("Snapshots") { (row: SnapshotCoverageRow) in
                                Text(row.snapshots.formatted()).monospacedDigit()
                                    .foregroundStyle(row.snapshots < 2 ? .orange : .primary)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                    .help(row.drifted > 0 ? "\(row.drifted) carried forward by portfolio-snapshots" : "")
                            }
                            .width(min: 55, ideal: 65)
                            TableColumn("From") { (row: SnapshotCoverageRow) in Text(row.first).monospacedDigit() }.width(min: 75, ideal: 85)
                            TableColumn("To") { (row: SnapshotCoverageRow) in Text(row.last).monospacedDigit() }.width(min: 75, ideal: 85)
                            TableColumn("Months") { (row: SnapshotCoverageRow) in
                                Text(row.months.formatted()).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                            }
                            .width(min: 45, ideal: 55)
                            TableColumn("Longest gap") { (row: SnapshotCoverageRow) in
                                Text(row.maxGapDays.map { "\($0) d" } ?? "—").monospacedDigit()
                                    .foregroundStyle((row.maxGapDays ?? 0) > 35 ? .orange : .primary)
                                    .help("Longest stretch between snapshots; over a month means a month used an older one")
                            }
                            .width(min: 60, ideal: 75)
                        }
                        if store.snapshotCoverage.isEmpty {
                            Text("Needs migration V010 (SRM/srm.py migrate).").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .quickHelpArea("Snapshot History", "The dated weight snapshots of each benchmark and portfolio: how many, from when to when, over how many months, and the longest gap. "
                                   + "Attribution uses the snapshot at the start of each month, so fewer than two snapshots or a gap over a month shows in orange.",
                                   symbol: "calendar")
                    .padding(10)
                }
            }
            .frame(minHeight: 220)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Loads").font(.headline)
                    Spacer()
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.loadAudit() } }
                        .quickHelp("Refresh", "Reads the coverage, sources, snapshots and loads again.")
                }
                Table(store.loads) {
                    TableColumn("#") { Text(String($0.id)).monospacedDigit() }.width(min: 30, ideal: 40)
                    TableColumn("Started", value: \.started).width(min: 120, ideal: 140)
                    TableColumn("Loader", value: \.loader).width(min: 100, ideal: 150)
                    TableColumn("Status") { row in
                        Text(row.status).foregroundStyle(row.status == "succeeded" ? .green : row.status == "partial" ? .orange
                                                         : row.status == "running" ? .blue : .red)
                    }
                    .width(min: 60, ideal: 70)
                    Group {
                        TableColumn("Read") { (row: LoadRow) in Text(row.read.formatted()).monospacedDigit() }.width(min: 50, ideal: 60)
                        TableColumn("Inserted") { (row: LoadRow) in Text(row.inserted.formatted()).monospacedDigit() }.width(min: 50, ideal: 60)
                        TableColumn("Updated") { (row: LoadRow) in Text(row.updated.formatted()).monospacedDigit() }.width(min: 50, ideal: 60)
                        TableColumn("Rejected") { (row: LoadRow) in Text(row.rejected.formatted()).monospacedDigit() }.width(min: 50, ideal: 60)
                        TableColumn("API calls") { (row: LoadRow) in Text(row.apiCalls.formatted()).monospacedDigit() }.width(min: 50, ideal: 60)
                    }
                    TableColumn("Time", value: \.duration).width(min: 55, ideal: 65)
                    TableColumn("Message") { Text($0.message).help($0.message) }
                }
                .quickHelpArea("Loads", "Every loader run (srm.load_run), newest first: when, which loader, how it ended, rows read, inserted, updated and rejected, API calls, how long it took and its message.",
                               symbol: "tray.and.arrow.down")
                HStack {
                    Text("Refresh data in Data Refresh, or with SRM/srm.py load all; automate it in MxJobsWMS.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Data Refresh") { store.section = .refresh }
                        .quickHelp("Data Refresh", "Goes to Data Refresh, to see how fresh each category is and run its loaders.", shortcut: "⌘5")
                }
            }
            .padding(10)
            .frame(minHeight: 200)
        }
        .task { await store.loadAudit() }
    }
}
