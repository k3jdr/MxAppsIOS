//
//  ColumnFilterPopover.swift
//  MxDataSQL
//
//  The panel behind a column header's filter button, laid out like Excel's:
//  sort ascending / descending, then a filter by values (checklist of the
//  column's distinct values with counts and a search box) or by a condition.
//

import SwiftUI

struct ColumnFilterPopover: View {
    let column: ColumnInfo
    let current: GridQueryOptions
    /// Pending grid edits; sorting and filtering are blocked until they are applied or discarded.
    let pendingEdits: Int
    let loadValues: () async throws -> (values: [DistinctValue], truncated: Bool)
    let apply: (GridQueryOptions) -> Void
    let close: () -> Void

    private enum Mode: String, CaseIterable, Identifiable {
        case values = "Values"
        case condition = "Condition"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .values
    @State private var values: [DistinctValue] = []
    @State private var truncated = false
    @State private var loading = true
    @State private var loadError: String?
    @State private var checked: Set<String?> = []
    @State private var search = ""
    @State private var op: FilterOperator = .contains
    @State private var value1 = ""
    @State private var value2 = ""

    private var name: String { column.name }
    private var sortedHere: GridSort? { current.sort?.column == name ? current.sort : nil }
    private var filteredHere: ColumnFilter? { current.filters[name] }

    private var kind: (asc: String, desc: String) {
        let t = column.type.lowercased()
        if ["int", "numeric", "decimal", "real", "double", "float", "money", "serial"].contains(where: t.contains) {
            return ("Sort Smallest to Largest", "Sort Largest to Smallest")
        }
        if ["date", "time"].contains(where: t.contains) {
            return ("Sort Oldest to Newest", "Sort Newest to Oldest")
        }
        return ("Sort A to Z", "Sort Z to A")
    }

    private var visible: [DistinctValue] {
        let s = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty else { return values }
        return values.filter { ($0.value ?? "(null)").lowercased().contains(s) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(name).font(.headline)
            if pendingEdits > 0 {
                Label("Apply or discard \(pendingEdits) pending edit\(pendingEdits == 1 ? "" : "s") before sorting or filtering.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 2) {
                sortButton(kind.asc, systemImage: "arrow.up", ascending: true)
                sortButton(kind.desc, systemImage: "arrow.down", ascending: false)
                if sortedHere != nil {
                    Button("Clear Sort", systemImage: "xmark") {
                        var o = current; o.sort = nil; finish(o)
                    }
                    .buttonStyle(.borderless)
                }
            }

            Divider()

            Picker("Filter by", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if mode == .values { valuesPane } else { conditionPane }

            Divider()

            HStack {
                Button("Clear Filter") {
                    var o = current; o.filters[name] = nil; finish(o)
                }
                .disabled(filteredHere == nil || pendingEdits > 0)
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("OK") { finish(optionsWithFilter()) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canApply)
            }
        }
        .padding(14)
        .frame(width: 320)
        .task { await load() }
        .onAppear(perform: restoreFilter)
    }

    private func sortButton(_ title: String, systemImage: String, ascending: Bool) -> some View {
        Button(title, systemImage: systemImage) {
            var o = current; o.sort = GridSort(column: name, ascending: ascending); finish(o)
        }
        .buttonStyle(.borderless)
        .fontWeight(sortedHere?.ascending == ascending ? .semibold : .regular)
        .disabled(pendingEdits > 0)
    }

    // MARK: Values

    private var valuesPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Search", text: $search).textFieldStyle(.roundedBorder)
            Group {
                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError {
                    Text(loadError).foregroundStyle(.red).font(.callout)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            Toggle("(Select All)", isOn: Binding(
                                get: { visible.allSatisfy { checked.contains($0.value) } },
                                set: { on in
                                    for v in visible { if on { checked.insert(v.value) } else { checked.remove(v.value) } }
                                }))
                            ForEach(visible, id: \.self) { item in
                                Toggle(isOn: Binding(
                                    get: { checked.contains(item.value) },
                                    set: { if $0 { checked.insert(item.value) } else { checked.remove(item.value) } })) {
                                    HStack {
                                        Text(item.value ?? "(NULL)")
                                            .italic(item.value == nil)
                                            .foregroundStyle(item.value == nil ? .secondary : .primary)
                                            .lineLimit(1).truncationMode(.tail)
                                        Spacer()
                                        Text(item.count.formatted()).foregroundStyle(.secondary).monospacedDigit()
                                    }
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            .frame(height: 220)
            if truncated {
                Text("Showing the first \(values.count.formatted()) values. Use Condition for others.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Condition

    private var conditionPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Show rows where \(name)", selection: $op) {
                ForEach(FilterOperator.allCases) { Text($0.rawValue).tag($0) }
            }
            if op.needsValue {
                TextField("Value", text: $value1).textFieldStyle(.roundedBorder)
            }
            if op.needsSecondValue {
                TextField("and", text: $value2).textFieldStyle(.roundedBorder)
            }
            Text("Text conditions ignore case. Greater, less and between compare as \(column.type).")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: 120, alignment: .top)
    }

    // MARK: Logic

    private var canApply: Bool {
        guard pendingEdits == 0 else { return false }
        switch mode {
        case .values: return !loading && loadError == nil
        case .condition: return (!op.needsValue || !value1.isEmpty) && (!op.needsSecondValue || !value2.isEmpty)
        }
    }

    private func restoreFilter() {
        switch filteredHere {
        case .condition(let o, let a, let b)?:
            mode = .condition; op = o; value1 = a; value2 = b
        default:
            mode = .values
        }
    }

    private func load() async {
        do {
            let result = try await loadValues()
            values = result.values
            truncated = result.truncated
            if case .values(let set)? = filteredHere {
                checked = set
            } else {
                checked = Set(values.map(\.value))
            }
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        loading = false
    }

    /// The options with this column's filter as set in the panel (no filter when everything is checked).
    private func optionsWithFilter() -> GridQueryOptions {
        var o = current
        switch mode {
        case .values:
            let searching = !search.trimmingCharacters(in: .whitespaces).isEmpty
            let keep = searching ? checked.intersection(visible.map(\.value)) : checked
            let all = Set(values.map(\.value))
            if !searching && all.isSubset(of: keep) {
                o.filters[name] = nil
            } else {
                o.filters[name] = .values(keep)
            }
        case .condition:
            o.filters[name] = .condition(op, value1, op.needsSecondValue ? value2 : "")
        }
        return o
    }

    private func finish(_ options: GridQueryOptions) {
        close()
        if options != current { apply(options) }
    }
}
