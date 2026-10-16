//
//  SRMLoadsView.swift
//  MxDataSRM
//
//  SRM ▸ Data & Loads: identifier coverage, the data sources with their plan limits, and the
//  load audit trail (srm.load_run). Loads themselves run from SRM/srm.py.
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
                Text("Run loads with SRM/srm.py load all (or one loader); see SRM/README.md.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(minHeight: 200)
        }
        .task { await store.loadAudit() }
    }
}
