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
            HSplitView {
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
                .padding(10)
                .frame(minWidth: 420)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sources").font(.headline)
                    Table(store.sources) {
                        TableColumn("Code", value: \.code).width(min: 70, ideal: 100)
                        TableColumn("Last load", value: \.lastLoad).width(min: 90, ideal: 110)
                        TableColumn("Terms and plan") { Text($0.note).lineLimit(3).help($0.note) }
                    }
                }
                .padding(10)
                .frame(minWidth: 360)
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
                .padding(10)
                .frame(minWidth: 420)
            }
            .frame(minHeight: 220)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Loads").font(.headline)
                    Spacer()
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.loadAudit() } }
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
                HStack {
                    Text("Refresh data in Data Refresh, or with SRM/srm.py load all; automate it in MxJobsWMS.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Data Refresh") { store.section = .refresh }
                }
            }
            .padding(10)
            .frame(minHeight: 200)
        }
        .task { await store.loadAudit() }
    }
}
