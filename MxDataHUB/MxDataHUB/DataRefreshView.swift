//
//  DataRefreshView.swift
//  MxDataHUB
//
//  Data Refresh: every category of market data in the security master — how fresh it is, when it was last
//  loaded, and a Refresh button that runs its srm.py loaders through the SRM loader service
//  (Services/srm-loader, 127.0.0.1:8770). The same loaders run on a schedule, with checks and approval,
//  in MxJobsWMS's SRM Daily Refresh workflow (Automate in MxJobsWMS…). Activity, on the right, streams what the
//  loaders print while they run (the service's GET /log), whoever started them, for whoever is watching the load.
//

import AppKit
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
    var run: Int?
    var loaders: [Loader]
}

/// One line of the SRM loader service's activity log: a line a loader printed, or a refresh / loader starting or ending.
struct ActivityEntry: Decodable, Identifiable, Hashable {
    var seq: Int
    var time: String
    /// info, warning or error
    var level: String
    var loader: String?
    var run: Int?
    /// run-start, run-end, loader-start, loader-end; nil for a loader's own output
    var event: String?
    var text: String

    var id: Int { seq }
    /// HH:mm:ss of the ISO time.
    var clock: String { String(time.dropFirst(11).prefix(8)) }
}

/// The refresh or load the service is running now.
struct ActivityRun: Decodable, Hashable {
    var run: Int
    var category: String?
    var name: String
    var loaders: [String]
    var loader: String?
    var index: Int
    var dryRun: Bool
    /// Seconds since 1970.
    var started: Double
}

struct ActivityPage: Decodable {
    var entries: [ActivityEntry]
    var last: Int
    var running: ActivityRun?
}

@Observable
final class RefreshStore {
    var categories: [RefreshCategory] = []
    var serviceUp: Bool?
    var running: String?
    var dryRun = false
    var results: [RefreshResult] = []
    var error: String?
    /// The service's activity log as far as it has been read (the last 5,000 lines).
    var activity: [ActivityEntry] = []
    var lastSeq = 0
    /// What the service is running now, whoever started it (this window, another, or MxJobsWMS).
    var current: ActivityRun?
    var lastPoll: Date?

    /// `-srmLoaderPort 8790` points Data Refresh at a test instance of the service.
    private let base = "http://127.0.0.1:\(UserDefaults.standard.integer(forKey: "srmLoaderPort").nonZero ?? ServiceCatalog.service("srm-loader")?.port ?? 8770)"

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
        await pollActivity()
        await load()
    }

    /// What the service logged since the last poll (GET /log?after=).
    func pollActivity() async {
        guard let url = URL(string: base + "/log?after=\(lastSeq)") else { return }
        do {
            let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 5))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            let page = try JSONDecoder().decode(ActivityPage.self, from: data)
            if page.last < lastSeq {
                // The service restarted and numbers its log from 1 again.
                activity = []
                lastSeq = 0
                return await pollActivity()
            }
            activity.append(contentsOf: page.entries)
            if activity.count > 5000 { activity.removeFirst(activity.count - 5000) }
            lastSeq = page.last
            current = page.running
            lastPoll = Date()
        } catch {
            current = nil
        }
    }

    /// Polls the activity log while the screen is open: every 0.7 s while something runs, else every 3 s.
    func followActivity() async {
        while !Task.isCancelled {
            await pollActivity()
            try? await Task.sleep(for: .milliseconds(running != nil || current != nil ? 700 : 3000))
        }
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
                // 580 + 7 + 430: the widest screen, which sets ContentView's window minimum.
                SplitPanes(id: "dataRefresh", widths: 580...700, ideal: 580, trailingMinimum: 430) {
                    categoryList
                } trailing: {
                    ActivityPanel(refresh: refresh, store: store)
                        .quickHelpArea("Activity", "What the loaders print while they run, line by line, whoever started them (here, another window or MxJobsWMS): "
                                       + "each refresh and loader starting and ending with its status, time and rows, and warnings and errors marked. "
                                       + "Load History has every load's counts.",
                                       symbol: "text.alignleft")
                }
            }
        }
        .task { await refresh.load() }
        .task { await refresh.followActivity() }
        .alert("Data Refresh", isPresented: Binding(get: { refresh.error != nil }, set: { if !$0 { refresh.error = nil } })) {
            Button("OK") { refresh.error = nil }
        } message: {
            Text(refresh.error ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Market data in the security master").font(.headline).lineLimit(1)
                Text("Refresh a category now, or automate the whole refresh — with data-quality checks and approval — in MxJobsWMS.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Toggle("Preview only (dry run)", isOn: $refresh.dryRun)
                .toggleStyle(.checkbox)
                .help("Show the srm.py command each loader would run, without loading")
                .quickHelp("Preview Only", "Refresh and Refresh All show the srm.py command each loader would run, without loading anything.")
            Button {
                Task { await refresh.refreshAll() }
            } label: {
                Label("Refresh All", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(refresh.running != nil || refresh.categories.isEmpty)
            .help("Every category in dependency order, except the optional ones; stops at the first failure")
            .quickHelp("Refresh All", "Refreshes every category in dependency order — later ones use the earlier ones — except the optional ones, and stops at the first failure.")
            Button {
                if !AppLink.sample(id: "srm-daily-refresh", portfolio: nil, benchmark: nil).open() {
                    refresh.error = "MxJobsWMS is not installed in Applications."
                }
            } label: {
                Label("Automate in MxJobsWMS…", systemImage: "flowchart")
            }
            .help("Open the SRM Daily Refresh workflow: scheduled, checked and approved")
            .quickHelp("Automate in MxJobsWMS", "Opens the SRM Daily Refresh workflow in MxJobsWMS: the same loaders on a schedule, with data-quality checks and the data steward's approval.")
            Button {
                Task { await refresh.load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Reload freshness")
            .quickHelp("Reload", "Asks the SRM loader service again how fresh each category is.")
        }
        .padding(12)
    }

    private var categoryList: some View {
        VStack(alignment: .leading, spacing: 0) {
        List {
            Section {
                ForEach(refresh.categories) { category in
                    // A load the service runs for someone else (MxJobsWMS, another window) counts too.
                    CategoryRow(category: category,
                                running: refresh.running == category.id || refresh.current?.category == category.id,
                                busy: refresh.running != nil || refresh.current.map { !$0.dryRun } == true) {
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
}

/// The service's activity log as a console: a live line for what runs now, then every line the loaders print, with
/// filters by run, level and text. Follows new lines unless Follow is off.
private struct ActivityPanel: View {
    var refresh: RefreshStore
    var store: SRMStore

    enum Level: String, CaseIterable { case all = "All", warnings = "Warnings", errors = "Errors" }

    @State private var level = Level.all
    @State private var search = ""
    @State private var runFilter: Int?
    @State private var follow = true
    /// Lines up to here are hidden (Clear); the service keeps them.
    @State private var clearedThrough = 0

    var body: some View {
        let lines = visible
        VStack(alignment: .leading, spacing: 0) {
            // Two rows that fit the pane's 430-point minimum: actions, then filters.
            HStack(spacing: 8) {
                Text("Activity").font(.headline)
                Spacer()
                Toggle(isOn: $follow) { Image(systemName: "arrow.down.to.line") }
                    .toggleStyle(.button)
                    .help("Follow: scroll to new lines as they arrive")
                    .quickHelp("Follow", "Scrolls to each new line as it arrives. Turn it off to read back while a load runs.")
                Button { copy(lines) } label: { Image(systemName: "doc.on.doc") }
                    .disabled(lines.isEmpty)
                    .help("Copy the lines shown")
                    .quickHelp("Copy", "Copies the lines shown, with their times, levels and loaders, for a ticket or a chat.")
                Button { clearedThrough = refresh.lastSeq } label: { Image(systemName: "trash") }
                    .disabled(lines.isEmpty)
                    .help("Clear the lines shown (the service keeps them)")
                    .quickHelp("Clear", "Hides the lines so far; new ones still appear. The service keeps its log.")
                Button("Load History") { store.section = .loads }
                    .disabled(!store.isConnected)
                    .quickHelp("Load History", "Goes to Load History: every loader run (srm.load_run) with its rows and rejects, identifier coverage and the sources. Needs the database connection (DB Connection).", symbol: "tray.and.arrow.down")
            }
            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 6)
            runningNow
            HStack(spacing: 6) {
                Picker("Level", selection: $level) {
                    ForEach(Level.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .quickHelp("Level", "All lines, only warnings and errors, or only errors.")
                Picker("Run", selection: $runFilter) {
                    Text("All runs").tag(Int?.none)
                    ForEach(runs, id: \.run) { run in
                        Text(run.label).tag(Int?.some(run.run))
                    }
                }
                .labelsHidden()
                .frame(minWidth: 90, maxWidth: 240)
                .quickHelp("Run", "Shows one refresh's lines — its loaders' output and their start and end — or every run's.")
                TextField("Filter lines", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 80)
                    .quickHelp("Filter", "Shows only lines containing this text (a ticker, a loader, a word such as rejected).")
            }
            .controlSize(.small)
            .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 8)
            Divider()
            if lines.isEmpty {
                ContentUnavailableView(refresh.activity.isEmpty ? "No Activity Yet" : "No Matching Lines",
                                       systemImage: "text.alignleft",
                                       description: Text(refresh.activity.isEmpty
                                            ? "Refresh a category: what its loaders print appears here as they run, with warnings and errors marked. Loads MxJobsWMS runs through the service appear here too."
                                            : "No lines match the run, level or filter."))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(lines) { ActivityLine(entry: $0) }
                            Color.clear.frame(height: 1).id(Self.end)
                        }
                        .textSelection(.enabled)
                        .padding(.vertical, 4)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                    .onChange(of: lines.last?.seq) { if follow { scrollToEnd(proxy) } }
                    .onChange(of: follow) { _, on in if on { scrollToEnd(proxy) } }
                    .onAppear { scrollToEnd(proxy) }
                }
            }
            Divider()
            footer(lines)
        }
    }

    private static let end = "end"

    /// Scrolls to the last line once the new lines are laid out (a lazy stack only estimates heights before that).
    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        Task {
            await Task.yield()
            proxy.scrollTo(Self.end, anchor: .bottom)
        }
    }

    /// What the service runs now, with the loader and the time it has taken so far.
    @ViewBuilder
    private var runningNow: some View {
        if let run = refresh.current {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("\(run.dryRun ? "Previewing" : "Running") \(run.name)").font(.callout.weight(.semibold)).lineLimit(1)
                    if let loader = run.loader {
                        Text("\(loader) · \(run.index) of \(run.loaders.count)").font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(Duration.seconds(max(0, context.date.timeIntervalSince1970 - run.started))
                        .formatted(.time(pattern: .hourMinuteSecond)))
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.1))
            }
            .quickHelpArea("Running Now", "The refresh or load the SRM loader service is running — from here, another window or MxJobsWMS — its current loader and how long it has run.",
                           symbol: "bolt.horizontal")
        }
    }

    private func footer(_ lines: [ActivityEntry]) -> some View {
        let errors = lines.filter { $0.level == "error" }.count
        let warnings = lines.filter { $0.level == "warning" }.count
        return HStack(spacing: 10) {
            Text("\(lines.count.formatted()) of \(refresh.activity.count.formatted()) lines")
            if errors > 0 { Label("\(errors.formatted())", systemImage: "xmark.octagon.fill").foregroundStyle(.red) }
            if warnings > 0 { Label("\(warnings.formatted())", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            Spacer()
            if let poll = refresh.lastPoll {
                Text("Updated \(poll.formatted(date: .omitted, time: .standard))")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 5)
    }

    private var visible: [ActivityEntry] {
        let text = search.trimmingCharacters(in: .whitespaces)
        return refresh.activity.filter { e in
            e.seq > clearedThrough
                && (runFilter == nil || e.run == runFilter)
                && (level == .all || e.level == "error" || (level == .warnings && e.level == "warning"))
                && (text.isEmpty || e.text.localizedCaseInsensitiveContains(text) || (e.loader ?? "").localizedCaseInsensitiveContains(text))
        }
    }

    /// Runs in the log, newest first, labelled with their start time, name and outcome.
    private var runs: [(run: Int, label: String)] {
        var ends: [Int: String] = [:]
        for e in refresh.activity where e.event == "run-end" {
            if let run = e.run { ends[run] = e.level == "error" ? "failed" : e.level == "warning" ? "with warnings" : "done" }
        }
        return refresh.activity.filter { $0.event == "run-start" && $0.run != nil }.reversed().map { e in
            let name = e.text.split(separator: ":").first.map(String.init) ?? e.text
            return (e.run!, "\(e.clock) \(name) — \(ends[e.run!] ?? "running")")
        }
    }

    private func copy(_ lines: [ActivityEntry]) {
        let text = lines.map { e in
            [e.time, e.level.uppercased(), e.loader ?? "-", e.text].joined(separator: "\t")
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// One console line: time, level or event mark, loader, text.
private struct ActivityLine: View {
    var entry: ActivityEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.clock).foregroundStyle(.tertiary)
            // A space, not "": an empty Text has no baseline and made plain lines taller.
            Text(mark.isEmpty ? " " : mark).foregroundStyle(color).frame(width: 34, alignment: .leading)
            Text(entry.loader ?? " ").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .frame(width: 112, alignment: .leading)
            Text(entry.text)
                .fontWeight(entry.event == nil ? .regular : .semibold)
                .foregroundStyle(entry.level == "error" ? Color.red : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 8).padding(.vertical, 1)
        .background(entry.level == "error" ? Color.red.opacity(0.08) : entry.level == "warning" ? Color.orange.opacity(0.08) : .clear)
    }

    private var mark: String {
        switch entry.event {
        case "run-start", "loader-start": "▶"
        case "run-end", "loader-end": "■"
        default: entry.level == "error" ? "ERR" : entry.level == "warning" ? "WARN" : ""
        }
    }

    private var color: Color {
        entry.level == "error" ? .red : entry.level == "warning" ? .orange : entry.event != nil ? .accentColor : .secondary
    }
}

private extension Int {
    /// nil for 0 (an unset integer default).
    var nonZero: Int? { self == 0 ? nil : self }
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
                .quickHelp("Refresh \(category.name)", "Runs " + category.loaders.map(\.loader).joined(separator: ", ") + " now through the SRM loader service; the result appears on the right.")
        }
        .padding(.vertical, 6)
        .quickHelpArea(QuickHelpItem(
            title: category.name,
            detail: category.description + "\n" + category.state.capitalized + (category.optional == true ? " · optional: Refresh All skips it" : "")
                + " · refreshed \(category.cadence) · loaders " + category.loaders.map { "\($0.loader) (\($0.status))" }.joined(separator: ", ") + ".",
            symbol: "arrow.triangle.2.circlepath"))
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
