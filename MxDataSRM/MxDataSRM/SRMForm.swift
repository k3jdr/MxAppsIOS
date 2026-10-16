//
//  SRMForm.swift
//  MxDataSRM
//
//  Form 4 — SRM: the security reference master in schema srm (created by SRM/srm.py migrate).
//  Securities, Portfolios, Benchmarks, and Data & Loads, each on its own tab.
//

import SwiftUI

struct SRMForm: View {
    @Bindable var store: SRMStore
    let session: WorkspaceSession

    var body: some View {
        Group {
            if !session.isConnected {
                ContentUnavailableView("Not Connected", systemImage: "cable.connector.slash",
                                       description: Text("Connect in the DB Connection form, to the database that holds the srm schema."))
            } else if store.available == false {
                ContentUnavailableView {
                    Label("No Security Master Here", systemImage: "building.columns")
                } description: {
                    Text("Database \(session.connectedSettings?.database ?? "") has no srm schema. Choose the database that has it in the Database drop-down, or create it with SRM/srm.py migrate and load it with SRM/srm.py load all.")
                }
            } else if store.available == nil {
                ProgressView("Opening the security master…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Picker("Section", selection: $store.section) {
                            ForEach(SRMSection.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        Spacer()
                        if store.busy { ProgressView().controlSize(.small) }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    Divider()
                    switch store.section {
                    case .securities: SRMSecuritiesView(store: store)
                    case .portfolios: SRMPortfoliosView(store: store)
                    case .benchmarks: SRMBenchmarksView(store: store)
                    case .loads: SRMLoadsView(store: store)
                    }
                }
            }
        }
        // Raises the window minimum while the SRM form is shown: the tabs need room for a list and a detail panel.
        .frame(minWidth: 1180, minHeight: 720)
        // Follows the workspace's live connection (not the editable connection fields): reconnects
        // when the workspace switches database or reconnects.
        .task(id: session.connectedSettings.map { "\($0.keychainAccount)|\($0.sslMode)" } ?? "") {
            if let settings = session.connectedSettings {
                await store.attach(settings: settings, password: session.password)
            } else {
                await store.detach()
            }
        }
        .alert("Security Master", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } })
        ) {
            Button("OK") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }
}

/// "12.3456%" for a fraction.
func percentText(_ value: Double?, digits: Int = 4) -> String {
    guard let value else { return "" }
    return (value * 100).formatted(.number.precision(.fractionLength(digits))) + "%"
}

func numberText(_ value: Double?, digits: Int = 2) -> String {
    guard let value else { return "" }
    return value.formatted(.number.precision(.fractionLength(digits)))
}

/// A label / value grid row used by the detail panels.
struct FactRow: View {
    let name: String
    let value: String
    var body: some View {
        GridRow {
            Text(name).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled).gridColumnAlignment(.leading)
        }
    }
}
