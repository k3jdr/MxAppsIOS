//
//  ViewSettingsDialog.swift
//  MxDataSQL
//
//  Table ▸ View…: number of rows and columns shown in the grid viewport,
//  and how many rows are fetched from the table.
//

import SwiftUI

struct ViewSettingsDialog: View {
    @Binding var settings: GridViewSettings
    let session: WorkspaceSession
    @State private var draft = GridViewSettings()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Table View").font(.headline)
            Form {
                numberRow("Rows to display", value: $draft.visibleRows, range: 1...200)
                numberRow("Columns to display", value: $draft.visibleColumns, range: 1...50)
                numberRow("Rows to fetch", value: $draft.fetchLimit, range: 1...1_000_000, step: 100)
            }
            if draft.fetchLimit != settings.fetchLimit && !session.edits.isEmpty {
                Label("Changing the fetch limit reloads the table and discards \(session.edits.count) pending edits.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { apply() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { draft = settings }
    }

    private func numberRow(_ label: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int = 1) -> some View {
        LabeledContent(label) {
            HStack {
                TextField(label, value: value, format: .number.grouping(.never))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                Stepper(label, value: value, in: range, step: step)
                    .labelsHidden()
            }
        }
    }

    private func apply() {
        draft.visibleRows = draft.visibleRows.clamped(to: 1...200)
        draft.visibleColumns = draft.visibleColumns.clamped(to: 1...50)
        draft.fetchLimit = draft.fetchLimit.clamped(to: 1...1_000_000)
        let reload = draft.fetchLimit != settings.fetchLimit && session.grid != nil
        settings = draft
        dismiss()
        if reload {
            let limit = draft.fetchLimit
            Task { await session.reloadGrid(limit: limit) }
        }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
