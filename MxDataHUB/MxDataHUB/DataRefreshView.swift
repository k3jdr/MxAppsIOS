//
//  DataRefreshView.swift
//  MxDataHUB
//
//  Data Refresh: every category of market data in the security master — how fresh it is, when it was last
//  loaded, and a Refresh button that runs its srm.py loaders through the SRM loader service
//  (Services/srm-loader, 127.0.0.1:8770). The same loaders run on a schedule, with checks and approval,
//  in MxJobsWMS's SRM Daily Refresh workflow (Automate in MxJobsWMS…).
//

import SwiftUI

struct RefreshLoader: Decodable, Hashable {
    var loader: String
    var status: String
    var lastRun: String?
    var message: String?
}

struct RefreshCategory: Decodable, Identifiable, Hashable {
    var id: String
    var name: String
    var description: String
    var cadence: String
    /// Run only on request: Refresh All skips it.
    var optional: Bool?
    var loaders: [RefreshLoader]
    var lastRun: String?
    var dataAsOf: String?
    var ageDays: Int?
    var state: String
}

struct RefreshResult: Decodable {
    struct Loader: Decodable, Hashable {
        var loader: String
        var status: String
        var seconds: Double?
        var command: String?
        var totals: [String: Double]?
        var outputTail: [String]?
    }
    var category: String
    var name: String
    var status: String
    var seconds: Double?
    var dryRun: Bool?
    var loaders: [Loader]
}

@Observable
final class RefreshStore {
    var categories: [RefreshCategory] = []
    var serviceUp: Bool?
    var running: String?
    var dryRun = false
    var results: [RefreshResult] = []
    var error: String?

    private let base = "http://127.0.0.1:\(ServiceCatalog.service("srm-loader")?.port ?? 8770)"

    func load() async {
        guard let url = URL(string: base + "/categories") else { return }
        do {
            let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 10))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                serviceUp = true
                error = String(decoding: data, as: UTF8.self)
                return
            }
            struct Payload: Decodable { var categories: [RefreshCategory] }
            categories = try JSONDecoder().decode(Payload.self, from: data).categories
            serviceUp = true
            error = nil
        } catch {
            serviceUp = false
        }
    }

    /// Runs one category's loaders, in order.
    func refresh(_ id: String) async {
        guard running == nil, let url = URL(string: base + "/refresh/" + id) else { return }
        running = id
        defer { running = nil }
        var request = URLRequest(url: url, timeoutInterval: 3 * 3600)   // the long loads take tens of minutes
        request.httpMethod = "POST"
        if dryRun { request.setValue("1", forHTTPHeaderField: "X-SRM-Dry-Run") }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 200 {
                results.insert(try JSONDecoder().decode(RefreshResult.self, from: data), at: 0)
            } else {
                error = String(decoding: data, as: UTF8.self)
            }
        } catch {
            self.error = error.localizedDescription
        }
        await load()
    }

    func refreshAll() async {
        for c in categories where c.optional != true {
            await refresh(c.id)
            if results.first?.status == "failed" { break }
        }
    }
}

struct DataRefreshView: View {
    @Bindable var store: SRMStore
    @State private var refresh = RefreshStore()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if refresh.serviceUp == false {
                ContentUnavailableView {
                    Label("SRM Loader Service Not Running", systemImage: "bolt.horizontal.circle")
                } description: {
                    Text("Data Refresh runs the security master's loaders through the SRM loader service on this Mac. Start the Layer 3 services, then check again.")
                } actions: {
                    VStack(spacing: 8) {
                        CopyCommand(title: "Start all", command: ServiceCatalog.startCommand).frame(width: 560)
                        Button("Check Again") { Task { await refresh.load() } }
                    }
                }
            } else {
                HSplitView {
                    categoryList
                        .frame(minWidth: 640, maxWidth: .infinity, maxHeight: .infinity)
                    resultsPanel
                        .frame(minWidth: 320, idealWidth: 400, maxWidth: 520, maxHeight: .infinity)
                }
            }
        }
        .task { await refresh.load() }
        .alert("Data Refresh", isPresented: Binding(get: { refresh.error != nil }, set: { if !$0 { refresh.error = nil } })) {
            Button("OK") { refresh.error = nil }
        } message: {
            Text(refresh.error ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Market data in the security master").font(.headline)
                Text("Refresh a category now, or automate the whole refresh — with data-quality checks and approval — in MxJobsWMS.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Preview only (dry run)", isOn: $refresh.dryRun)
                .toggleStyle(.checkbox)
                .help("Show the srm.py command each loader would run, without loading")
            Button {
                Task { await refresh.refreshAll() }
            } label: {
                Label("Refresh All", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(refresh.running != nil || refresh.categories.isEmpty)
            .help("Every category in dependency order, except the optional ones; stops at the first failure")
            Button {
                if !AppLink.sample(id: "srm-daily-refresh", portfolio: nil, benchmark: nil).open() {
                    refresh.error = "MxJobsWMS is not installed in Applications."
                }
            } label: {
                Label("Automate in MxJobsWMS…", systemImage: "flowchart")
            }
            .help("Open the SRM Daily Refresh workflow: scheduled, checked and approved")
            Button {
                Task { await refresh.load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Reload freshness")
        }
        .padding(12)
    }

    private var categoryList: some View {
        VStack(alignment: .leading, spacing: 0) {
        List {
            Section {
                ForEach(refresh.categories) { category in
                    CategoryRow(category: category, running: refresh.running == category.id,
                                busy: refresh.running != nil) {
                        Task {
                            await refresh.refresh(category.id)
                            if store.isConnected { await store.loadAudit() }
                        }
                    }
                }
            } header: {
                Text("In dependency order — later categories use the earlier ones")
            }
        }
        .listStyle(.inset)
        Divider()
        Text("Before optimizing or attributing a portfolio, make sure Benchmark constituents and Prices & index levels are fresh. "
             + "Identifiers matter when portfolios or benchmarks change; reference data rarely does.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
        }
    }

    private var resultsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("This session's refreshes").font(.headline)
                Spacer()
                Button("Load History") { store.section = .loads }
                    .disabled(!store.isConnected)
            }
            .padding(10)
            Divider()
            if refresh.results.isEmpty {
                ContentUnavailableView("No Refreshes Yet", systemImage: "clock.arrow.circlepath",
                                       description: Text("Results of the refreshes you run here appear in this panel."))
                    .frame(maxHeight: .infinity)
            } else {
                List(Array(refresh.results.enumerated()), id: \.offset) { _, result in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            StateBadge(state: result.dryRun == true ? "dry-run" : result.status)
                            Text(result.name).font(.callout.weight(.semibold))
                            Spacer()
                            if let s = result.seconds { Text("\(s.formatted()) s").font(.caption).foregroundStyle(.secondary) }
                        }
                        ForEach(result.loaders, id: \.self) { l in
                            DisclosureGroup {
                                Text((l.outputTail ?? []).joined(separator: "\n"))
                                    .font(.caption2.monospaced())
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } label: {
                                HStack {
                                    Text(l.loader).font(.caption.monospaced())
                                    Text(l.status).font(.caption).foregroundStyle(StateBadge.color(l.status))
                                    Spacer()
                                    if let t = l.totals {
                                        Text("read \(Int(t["rows_read"] ?? 0).formatted()) · rejected \(Int(t["rows_rejected"] ?? 0).formatted())")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    } else if let c = l.command {
                                        Text(c).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

private struct CategoryRow: View {
    var category: RefreshCategory
    var running: Bool
    var busy: Bool
    var refresh: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StateBadge(state: category.state).frame(width: 70, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(category.name).font(.headline)
                    if category.optional == true {
                        Text("Optional").font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.secondary.opacity(0.15), in: Capsule())
                    }
                }
                Text(category.description).font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    if let asOf = category.dataAsOf { Label("Data as of \(asOf)", systemImage: "calendar").font(.caption) }
                    Label("Last load \(shortDate(category.lastRun))", systemImage: "clock").font(.caption)
                    Label("Refresh \(category.cadence)", systemImage: "repeat").font(.caption)
                }
                .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(category.loaders, id: \.self) { l in
                        Text(l.loader)
                            .font(.caption2.monospaced())
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(StateBadge.color(l.status).opacity(0.15), in: Capsule())
                            .help("\(l.loader): \(l.status)" + (l.message.map { " — \($0)" } ?? ""))
                    }
                }
            }
            Spacer()
            if running {
                ProgressView().controlSize(.small)
            }
            Button("Refresh", action: refresh)
                .disabled(busy)
        }
        .padding(.vertical, 6)
    }

    private func shortDate(_ iso: String?) -> String {
        guard let iso else { return "never" }
        return String(iso.prefix(16)).replacingOccurrences(of: "T", with: " ")
    }
}

struct StateBadge: View {
    var state: String

    var body: some View {
        Text(state.capitalized)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Self.color(state), in: RoundedRectangle(cornerRadius: 4))
    }

    static func color(_ state: String) -> Color {
        switch state {
        case "fresh", "succeeded": .green
        case "due", "partial": .orange
        case "stale", "failed": .red
        case "dry-run": .blue
        default: .gray
        }
    }
}
