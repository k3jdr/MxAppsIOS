//
//  DataRefreshView.swift
//  MxDataHUB
//
//  Data Refresh: every category of market data in the security master — how fresh it is, when it was last
//  loaded, and a Refresh button that runs its srm.py loaders through the SRM loader service
//  (Services/srm-loader, 127.0.0.1:8770). The same loaders run on a schedule, with checks and approval,
//  in MxJobsMGR's SRM Daily Refresh workflow (Automate in MxJobsMGR…). Activity, on the right, streams what the
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
    /// The refresh's name on run events; the outcome and its time on the -end events.
    var name: String?
    var status: String?
    var seconds: Double?

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
    /// srm.py's log detail for the refreshes started here: 0 normal, 1 verbose (-v), 2 trace (-vv). Remembered.
    var verbosity = UserDefaults.standard.integer(forKey: "refreshVerbosity") {
        didSet { UserDefaults.standard.set(verbosity, forKey: "refreshVerbosity") }
    }
    var results: [RefreshResult] = []
    var error: String?
    /// The service's activity log as far as it has been read (the last 20,000 lines).
    var activity: [ActivityEntry] = []
    var lastSeq = 0
    /// What the service is running now, whoever started it (this window, another, or MxJobsMGR).
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
        guard running == nil, let url = URL(string: base + "/refresh/" + id + (verbosity > 0 ? "?verbosity=\(verbosity)" : "")) else { return }
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

    private var polling = false

    /// What the service logged since the last poll (GET /log?after=). One poll at a time: Refresh polls once more
    /// when it ends, and two polls from the same point appended the same lines twice.
    func pollActivity() async {
        guard !polling, let url = URL(string: base + "/log?after=\(lastSeq)") else { return }
        polling = true
        defer { polling = false }
        do {
            let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 5))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            let page = try JSONDecoder().decode(ActivityPage.self, from: data)
            if page.last < lastSeq {
                // The service restarted and numbers its log from 1 again.
                activity = []
                lastSeq = 0
                polling = false
                return await pollActivity()
            }
            activity.append(contentsOf: page.entries.filter { $0.seq > lastSeq })
            if activity.count > 20000 { activity.removeFirst(activity.count - 20000) }
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

    /// Which category Refresh All is on, for the header.
    var allProgress: (index: Int, total: Int)?

    func refreshAll() async {
        let all = categories.filter { $0.optional != true }
        defer { allProgress = nil }
        for (i, c) in all.enumerated() {
            allProgress = (i + 1, all.count)
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
                        .quickHelpArea("Activity", "What the loaders print while they run, line by line, whoever started them (here, another window or MxJobsMGR): "
                                       + "each refresh and loader starting and ending with its status, time and rows, and warnings and errors marked. "
                                       + "Load History has every load's counts.",
                                       symbol: "text.alignleft")
                }
            }
        }
        .task { await refresh.load() }
        .task { await refresh.followActivity() }
        .errorDialog("Data Refresh", message: $refresh.error)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Market data in the security master").font(.headline).lineLimit(1)
                Text("Refresh a category now, or automate the whole refresh — with data-quality checks and approval — in MxJobsMGR.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Toggle("Preview only (dry run)", isOn: $refresh.dryRun)
                .toggleStyle(.checkbox)
                .help("Show the srm.py command each loader would run, without loading")
                .quickHelp("Preview Only", "Refresh and Refresh All show the srm.py command each loader would run, without loading anything.")
            Picker("Log detail", selection: $refresh.verbosity) {
                Text("Normal").tag(0)
                Text("Verbose (-v)").tag(1)
                Text("Trace (-vv)").tag(2)
            }
            .fixedSize()
            .help("How much the loaders print in Activity for the refreshes you start here")
            .quickHelp("Log Detail", "How much srm.py prints in Activity for the refreshes you start here. Normal: the progress lines. "
                       + "Verbose (-v): also what each step does — connection, downloads and cache hits, rate-limit waits, retries, every reject, "
                       + "identifier results, timings, and a failing loader's traceback. Trace (-vv): also every HTTP request and SQL statement with its time. "
                       + "The extra lines show as DBG; Level ▸ Info hides them.")
            Button {
                Task { await refresh.refreshAll() }
            } label: {
                if let all = refresh.allProgress {
                    Label("Refreshing \(all.index) of \(all.total)…", systemImage: "arrow.triangle.2.circlepath")
                } else {
                    Label("Refresh All", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .disabled(refresh.running != nil || refresh.categories.isEmpty)
            .help("Every category in dependency order, except the optional ones; stops at the first failure")
            .quickHelp("Refresh All", "Refreshes every category in dependency order — later ones use the earlier ones — except the optional ones, and stops at the first failure.")
            Button {
                if !AppLink.sample(id: "srm-daily-refresh", portfolio: nil, benchmark: nil).open() {
                    refresh.error = "MxJobsMGR is not installed in Applications."
                }
            } label: {
                Label("Automate in MxJobsMGR…", systemImage: "flowchart")
            }
            .help("Open the SRM Daily Refresh workflow: scheduled, checked and approved")
            .quickHelp("Automate in MxJobsMGR", "Opens the SRM Daily Refresh workflow in MxJobsMGR: the same loaders on a schedule, with data-quality checks and the data steward's approval.")
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
                    // A load the service runs for someone else (MxJobsMGR, another window) counts too.
                    let running = refresh.running == category.id || refresh.current?.category == category.id
                    CategoryRow(category: category, running: running,
                                busy: refresh.running != nil || refresh.current.map { !$0.dryRun } == true) {
                        Task {
                            await refresh.refresh(category.id)
                            if store.isConnected { await store.loadAudit() }
                        }
                    }
                    .listRowBackground(running ? Color.accentColor.opacity(0.14) : nil)
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

    /// All lines; Info hides the -v / -vv detail lines; Warnings and Errors.
    enum Level: String, CaseIterable { case all = "All", info = "Info", warnings = "Warnings", errors = "Errors" }

    @State private var level = Level.all
    @State private var search = ""
    @State private var runFilter: Int?
    @State private var follow = true
    /// Lines up to here are hidden (Clear); the service keeps them.
    @State private var clearedThrough = 0
    @State private var console = ConsoleHandle()

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
                    .help("Copy the selected lines, or all the lines shown when none are selected")
                    .quickHelp("Copy", "Copies the lines you selected in the console (drag across them, or ⌘A), or every line shown when none are; "
                               + "with their times, levels and loaders, for a ticket or a chat. ⌘C copies a selection too.")
                Button { clearedThrough = refresh.lastSeq } label: { Image(systemName: "trash") }
                    .disabled(lines.isEmpty)
                    .help("Clear the lines shown (the service keeps them)")
                    .quickHelp("Clear", "Hides the lines so far; new ones still appear. The service keeps its log.")
                Button("Load History") { store.section = .loads }
                    .disabled(!store.isConnected)
                    .quickHelp("Load History", "Goes to Load History: every loader run (srm.load_run) with its rows and rejects, identifier coverage and the sources. Needs the database connection (DB Connection).", symbol: "tray.and.arrow.down")
            }
            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 6)
            statusStrip
            HStack(spacing: 6) {
                Picker("Level", selection: $level) {
                    ForEach(Level.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .quickHelp("Level", "All lines; Info hides the Verbose / Trace detail lines (DBG); only warnings and errors; or only errors.")
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
                                            ? "Refresh a category: what its loaders print appears here as they run, with warnings and errors marked. Loads MxJobsMGR runs through the service appear here too."
                                            : "No lines match the run, level or filter."))
                    .frame(maxHeight: .infinity)
            } else {
                ActivityConsole(lines: lines, follow: follow, handle: console)
            }
            Divider()
            footer(lines)
        }
    }

    /// Always says what the service is doing: running a refresh (with its loader, a bar by loaders done, the latest
    /// line and the time so far), else how the last refresh ended, else that it is idle.
    @ViewBuilder
    private var statusStrip: some View {
        if let run = refresh.current {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(run.dryRun ? "PREVIEWING" : "RUNNING")
                            .font(.caption.weight(.bold)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 4))
                        Text(run.name).font(.headline).lineLimit(1)
                        Spacer()
                        Text(Duration.seconds(max(0, context.date.timeIntervalSince1970 - run.started))
                            .formatted(.time(pattern: .hourMinuteSecond)))
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    ProgressView(value: Double(max(run.index - 1, 0)), total: Double(max(run.loaders.count, 1)))
                    HStack(spacing: 6) {
                        if let loader = run.loader {
                            Text("\(loader) · loader \(run.index) of \(run.loaders.count)").font(.caption.monospaced())
                        }
                        if let latest = refresh.activity.last(where: { $0.run == run.run && $0.event == nil }) {
                            Text(latest.text).font(.caption.monospaced()).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.tail)
                        }
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.12))
                .overlay(alignment: .leading) { Rectangle().fill(Color.accentColor).frame(width: 3) }
            }
            .quickHelpArea("Running Now", "The refresh the SRM loader service is running — from here, another window or MxJobsMGR: its current loader, "
                           + "a bar by loaders finished, the latest line it printed and how long it has run.", symbol: "bolt.horizontal")
        } else if let end = refresh.activity.last(where: { $0.event == "run-end" }) {
            let status = end.status ?? (end.level == "error" ? "failed" : end.level == "warning" ? "partial" : "succeeded")
            HStack(spacing: 8) {
                Image(systemName: status == "succeeded" ? "checkmark.circle.fill" : status == "failed" ? "xmark.octagon.fill"
                      : status == "dry-run" ? "eye.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(StateBadge.color(status))
                Text("Last refresh: \(end.name ?? "") — \(status)" + (end.seconds.map { " in \($0.formatted()) s" } ?? ""))
                    .font(.callout.weight(.semibold)).lineLimit(1)
                Text("ended \(end.clock)").font(.callout).foregroundStyle(.secondary)
                Spacer()
                if let run = end.run, runFilter != run {
                    Button("Show Its Lines") { runFilter = run }
                        .controlSize(.small)
                        .quickHelp("Show Its Lines", "Shows only that refresh's lines (Run ▸ All runs shows everything again).")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(StateBadge.color(status).opacity(0.12))
            .overlay(alignment: .leading) { Rectangle().fill(StateBadge.color(status)).frame(width: 3) }
            .quickHelpArea("Last Refresh", "Nothing is running. How the last refresh ended, when, and how long it took.", symbol: "flag.checkered")
        } else {
            HStack(spacing: 6) {
                Image(systemName: "moon.zzz").foregroundStyle(.secondary)
                Text("Idle — no refresh is running").font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
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
                && (level == .all || e.level == "error" || (level == .info && e.level != "debug")
                    || (level == .warnings && e.level == "warning"))
                && (text.isEmpty || e.text.localizedCaseInsensitiveContains(text) || (e.loader ?? "").localizedCaseInsensitiveContains(text))
        }
    }

    /// Runs in the log, newest first, labelled with their start time, name and outcome.
    private var runs: [(run: Int, label: String)] {
        var ends: [Int: String] = [:]
        for e in refresh.activity where e.event == "run-end" {
            if let run = e.run { ends[run] = e.status ?? (e.level == "error" ? "failed" : e.level == "warning" ? "with warnings" : "done") }
        }
        return refresh.activity.filter { $0.event == "run-start" && $0.run != nil }.reversed().map { e in
            (e.run!, "\(e.clock) \(e.name ?? e.text) — \(ends[e.run!] ?? "running")")
        }
    }

    /// The console's selection, or else every line shown with its date, level and loader.
    private func copy(_ lines: [ActivityEntry]) {
        let text = console.selection ?? lines.map { e in
            [e.time, e.level.uppercased(), e.loader ?? "-", e.text].joined(separator: "\t")
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Gives the Copy button the console's selection.
final class ConsoleHandle {
    weak var textView: NSTextView?

    /// The selected text, or nil when nothing is selected.
    var selection: String? {
        guard let view = textView, view.selectedRange().length > 0 else { return nil }
        return (view.string as NSString).substring(with: view.selectedRange())
    }
}

/// The lines in a read-only text view, so any run of them can be selected: drag across lines (or ⌘A) and ⌘C,
/// right-click ▸ Copy, or ⌘F to find. Columns are tab-separated, so a copied selection pastes into a spreadsheet.
/// New lines are appended without disturbing a selection, and Follow keeps the end in view unless text is selected.
private struct ActivityConsole: NSViewRepresentable {
    var lines: [ActivityEntry]
    var follow: Bool
    var handle: ConsoleHandle

    final class Coordinator {
        var first: Int?
        var last: Int?
        var count = 0
        var follow = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let text = scroll.documentView as! NSTextView
        text.isEditable = false
        text.isSelectable = true
        text.usesFindBar = true
        text.isIncrementalSearchingEnabled = true
        text.textContainerInset = NSSize(width: 4, height: 6)
        text.backgroundColor = .textBackgroundColor
        handle.textView = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView, let storage = text.textStorage else { return }
        handle.textView = text
        let state = context.coordinator
        // The same lines with new ones after them (the usual poll): append those. Anything else (a filter): rebuild.
        let appends = state.count > 0 && lines.count >= state.count
            && lines.first?.seq == state.first && lines[state.count - 1].seq == state.last
        let changed = !(appends && lines.count == state.count)
        if changed {
            let chunk = NSMutableAttributedString()
            for entry in appends ? lines[state.count...] : lines[...] { chunk.append(Self.format(entry)) }
            storage.beginEditing()
            if appends { storage.append(chunk) } else { storage.setAttributedString(chunk) }
            storage.endEditing()
            state.first = lines.first?.seq
            state.last = lines.last?.seq
            state.count = lines.count
        }
        if follow && (changed || !state.follow) && text.selectedRange().length == 0 {
            text.scrollToEndOfDocument(nil)
        }
        state.follow = follow
    }

    private static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private static let boldFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
    /// Time, mark, loader, then the text; wrapped text continues under the text column.
    private static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.tabStops = [64, 100, 232].map { NSTextTab(textAlignment: .left, location: $0) }
        style.headIndent = 232
        return style
    }()

    private static let headerFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
    /// A rule across the console: a tab out past the edge, struck through, clipped at the edge. Copies as one tab.
    private static let rule: NSAttributedString = {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .left, location: 4000)]
        style.lineBreakMode = .byClipping
        style.paragraphSpacingBefore = 6
        return NSAttributedString(string: "\t\n", attributes: [
            .font: NSFont.systemFont(ofSize: 4), .paragraphStyle: style,
            .strikethroughStyle: NSUnderlineStyle.thick.rawValue, .strikethroughColor: NSColor.separatorColor])
    }()

    /// One line; a refresh's END line has a rule below it, between it and the next refresh.
    private static func format(_ entry: ActivityEntry) -> NSAttributedString {
        let line = NSMutableAttributedString()
        func add(_ text: String, _ color: NSColor, _ font: NSFont = Self.font) {
            line.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]))
        }
        let isRun = entry.event == "run-start" || entry.event == "run-end"
        let loader = entry.loader.map { $0.count > 20 ? String($0.prefix(19)) + "…" : $0 } ?? ""
        add(entry.clock + "\t", .tertiaryLabelColor)
        add(mark(entry) + "\t", markColor(entry), entry.event == nil ? font : boldFont)
        add(loader + "\t", .secondaryLabelColor)
        add(entry.text + "\n", textColor(entry), isRun ? headerFont : entry.event == nil ? font : boldFont)
        if entry.event == "run-end" { line.append(rule) }
        return line
    }

    private static func mark(_ entry: ActivityEntry) -> String {
        switch entry.event {
        case "run-start": "START"
        case "run-end": "END"
        case "loader-start": "▶"
        case "loader-end": ["succeeded": "✓", "failed": "✗", "dry-run": "·"][entry.status ?? ""] ?? "!"
        default: ["error": "ERR", "warning": "WARN", "debug": "DBG"][entry.level] ?? ""
        }
    }

    /// The outcome's colour on -end lines (green, red, orange, blue for a preview), else by level.
    private static func outcomeColor(_ entry: ActivityEntry) -> NSColor? {
        guard entry.event == "run-end" || entry.event == "loader-end" else { return nil }
        switch entry.status ?? (entry.level == "error" ? "failed" : entry.level == "warning" ? "partial" : "succeeded") {
        case "succeeded": return .systemGreen
        case "failed": return .systemRed
        case "dry-run": return .systemBlue
        default: return .systemOrange
        }
    }

    private static func markColor(_ entry: ActivityEntry) -> NSColor {
        if let outcome = outcomeColor(entry) { return outcome }
        switch entry.level {
        case "error": return .systemRed
        case "warning": return .systemOrange
        case "debug": return .tertiaryLabelColor
        default: return entry.event != nil ? .controlAccentColor : .secondaryLabelColor
        }
    }

    private static func textColor(_ entry: ActivityEntry) -> NSColor {
        if entry.event == "run-end", let outcome = outcomeColor(entry) { return outcome }
        if entry.event == "run-start" { return .controlAccentColor }
        return entry.level == "error" ? .systemRed : entry.level == "debug" ? .secondaryLabelColor : .labelColor
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
            StateBadge(state: running ? "running" : category.state).frame(width: 70, alignment: .leading)
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
            Button(running ? "Running…" : "Refresh", action: refresh)
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
        case "dry-run", "running": .blue
        default: .gray
        }
    }
}
