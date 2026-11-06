//
//  MonitorStore.swift — MxMidiPRO
//
//  The monitor's state: every message captured (up to the Keep limit), the filtered list the log and scope show,
//  the filters, pause, counters, the spy driver's state and whether Logic Pro is running. Filters and display
//  choices are remembered between launches.
//

import AppKit
import CoreMIDI
import Observation
import UniformTypeIdentifiers

/// The scope's traces. The first three are MMM's; Pitch Bend and one controller are added for Logic Pro work.
enum Trace: String, CaseIterable, Identifiable {
    case channelPressure, polyPressure, velocity, pitchBend, controller

    var id: String { rawValue }

    var title: String {
        switch self {
        case .channelPressure: "Channel Pressure"
        case .polyPressure: "Poly Pressure"
        case .velocity: "Velocity"
        case .pitchBend: "Pitch Bend"
        case .controller: "CC"
        }
    }

    /// The value 0 … 127 this event contributes to the trace, if any.
    func value(of e: MIDIEvent, controller cc: Int) -> Double? {
        switch self {
        case .velocity: e.kind == .noteOn ? Double(e.data2) : nil
        case .channelPressure: e.kind == .channelPressure ? Double(e.data1) : nil
        case .polyPressure: e.kind == .polyPressure ? Double(e.data2) : nil
        case .pitchBend: e.kind == .pitchBend ? Double(e.bend) / 16383 * 127 : nil
        case .controller: e.kind == .controlChange && Int(e.data1) == cc ? Double(e.data2) : nil
        }
    }
}

enum SpyState: Equatable {
    case active, installedNotLoaded, notInstalled
}

@MainActor
@Observable
final class MonitorStore {
    nonisolated static let logicBundleID = "com.apple.logic10"
    static let keepChoices = [10_000, 50_000, 100_000, 250_000, 500_000]

    @ObservationIgnored let engine = MIDIEngine()
    @ObservationIgnored private let defaults = UserDefaults.standard

    // MARK: Log

    /// What the log and scope show: captured messages that pass the filters (frozen while paused).
    private(set) var events: [MIDIEvent] = []
    /// Bumped when messages are appended to `events`.
    private(set) var appendRevision = 0
    /// Bumped when `events` is rebuilt (filters, reset, trimming): the log reloads.
    private(set) var reloadRevision = 0

    @ObservationIgnored private var all: [MIDIEvent] = []
    @ObservationIgnored private var nextSeq = 1
    private(set) var startTime = HostClock.now

    private(set) var inCount = 0
    private(set) var outCount = 0
    private(set) var droppedCount = 0
    private(set) var rate = 0.0
    @ObservationIgnored private var rateTicks: [Int] = Array(repeating: 0, count: 30)
    @ObservationIgnored private var rateIndex = 0

    private(set) var pauseSeq = 0
    private(set) var pausedAt: UInt64 = 0
    var paused = false {
        didSet {
            guard paused != oldValue else { return }
            if paused {
                pauseSeq = nextSeq - 1
                pausedAt = HostClock.now
            } else {
                refilter()
            }
        }
    }
    /// Messages received since Pause (every message is numbered, so the counters say how many there are).
    var waitingCount: Int { paused ? max(0, inCount + outCount - pauseSeq) : 0 }

    // MARK: Filters (remembered)

    var showIn: Bool { didSet { defaults.set(showIn, forKey: "ShowIn"); refilter() } }
    var showOut: Bool { didSet { defaults.set(showOut, forKey: "ShowOut"); refilter() } }
    var hiddenGroups: Set<MIDIFilterGroup> {
        didSet { defaults.set(hiddenGroups.map(\.rawValue), forKey: "HiddenGroups"); refilter() }
    }
    /// 0 is every channel.
    var channel: Int { didSet { defaults.set(channel, forKey: "Channel"); refilter() } }
    var inScope: PortScope { didSet { defaults.set(inScope.rawValue, forKey: "InScope"); refilter() } }
    var outScope: PortScope { didSet { defaults.set(outScope.rawValue, forKey: "OutScope"); refilter() } }
    var hiddenPorts: Set<MIDIUniqueID> {
        didSet { defaults.set(hiddenPorts.map(Int.init), forKey: "HiddenPorts"); refilter() }
    }

    // MARK: Display (remembered)

    var traces: Set<Trace> { didSet { defaults.set(traces.map(\.rawValue), forKey: "Traces") } }
    var controllerNumber: Int { didSet { defaults.set(controllerNumber, forKey: "ControllerNumber") } }
    var scopeSeconds: Double { didSet { defaults.set(scopeSeconds, forKey: "ScopeSeconds") } }
    var showRaw: Bool { didSet { defaults.set(showRaw, forKey: "ShowRaw") } }
    var middleCOctave: Int { didSet { defaults.set(middleCOctave, forKey: "MiddleCOctave"); formatRevision += 1 } }
    var timeDisplay: TimeDisplay {
        didSet { defaults.set(timeDisplay.rawValue, forKey: "TimeDisplay"); formatRevision += 1 }
    }
    var keep: Int { didSet { defaults.set(keep, forKey: "Keep"); trimIfNeeded(force: true) } }
    private(set) var formatRevision = 0

    var thruEnabled: Bool {
        didSet {
            defaults.set(thruEnabled, forKey: "ThruEnabled")
            engine.thruEnabled = thruEnabled
        }
    }

    // MARK: Ports, spy, Logic Pro

    private(set) var ports: [MIDIUniqueID: PortInfo] = [:]
    private(set) var spyState: SpyState = .notInstalled
    private(set) var spyIsCurrent = true
    private(set) var thruPortNames: [String] = []
    private(set) var logicRunning = false
    private(set) var engineError: String?
    var spyMessage: String?
    var showOutSetup = false

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        let d = UserDefaults.standard
        showIn = d.object(forKey: "ShowIn") as? Bool ?? true
        showOut = d.object(forKey: "ShowOut") as? Bool ?? true
        if let saved = d.stringArray(forKey: "HiddenGroups") {
            hiddenGroups = Set(saved.compactMap(MIDIFilterGroup.init(rawValue:)))
        } else {
            hiddenGroups = MIDIFilterGroup.hiddenByDefault
        }
        channel = d.integer(forKey: "Channel")
        inScope = PortScope(rawValue: d.string(forKey: "InScope") ?? "") ?? .usb
        outScope = PortScope(rawValue: d.string(forKey: "OutScope") ?? "") ?? .usb
        hiddenPorts = Set((d.array(forKey: "HiddenPorts") as? [Int] ?? []).map { MIDIUniqueID(truncatingIfNeeded: $0) })
        if let saved = d.stringArray(forKey: "Traces") {
            traces = Set(saved.compactMap(Trace.init(rawValue:)))
        } else {
            traces = [.channelPressure, .polyPressure, .velocity]
        }
        controllerNumber = d.object(forKey: "ControllerNumber") as? Int ?? 1
        scopeSeconds = d.object(forKey: "ScopeSeconds") as? Double ?? 10
        showRaw = d.bool(forKey: "ShowRaw")
        middleCOctave = d.object(forKey: "MiddleCOctave") as? Int ?? 3
        timeDisplay = TimeDisplay(rawValue: d.string(forKey: "TimeDisplay") ?? "") ?? .sinceReset
        keep = d.object(forKey: "Keep") as? Int ?? 100_000
        thruEnabled = d.bool(forKey: "ThruEnabled")

        engine.onChange = { [weak self] in
            MainActor.assumeIsolated { self?.portsChanged() }
        }
        engine.thruEnabled = thruEnabled
        engine.start()
        engineError = engine.lastError
        watchLogic()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    // MARK: Receiving

    private func tick() {
        let (batch, dropped) = engine.drain()
        droppedCount += dropped
        rateTicks[rateIndex] = batch.count
        rateIndex = (rateIndex + 1) % rateTicks.count
        if rateIndex % 10 == 0 {
            let newRate = Double(rateTicks.reduce(0, +))
            if newRate != rate { rate = newRate }
        }
        guard !batch.isEmpty else { return }

        var numbered = batch
        var ins = 0
        for i in numbered.indices {
            numbered[i].seq = nextSeq
            nextSeq += 1
            if numbered[i].direction == .input { ins += 1 }
        }
        inCount += ins
        outCount += numbered.count - ins
        all.append(contentsOf: numbered)

        if trimIfNeeded() { return }
        guard !paused else { return }
        let shown = numbered.filter(passes)
        if !shown.isEmpty {
            events.append(contentsOf: shown)
            appendRevision += 1
        }
    }

    /// Drops the oldest messages once there are a tenth more than Keep; returns whether the log was rebuilt.
    @discardableResult
    private func trimIfNeeded(force: Bool = false) -> Bool {
        guard all.count > (force ? keep : keep + keep / 10) else { return false }
        all.removeFirst(all.count - keep)
        refilter()
        return true
    }

    func passes(_ e: MIDIEvent) -> Bool {
        if e.direction == .input ? !showIn : !showOut { return false }
        if hiddenGroups.contains(e.kind.group) { return false }
        if channel != 0, let c = e.channel, c != channel { return false }
        if hiddenPorts.contains(e.portID) { return false }
        let transport = ports[e.portID]?.transport ?? .usb
        return (e.direction == .input ? inScope : outScope).includes(transport)
    }

    private func refilter() {
        let limit = paused ? pauseSeq : Int.max
        events = all.filter { $0.seq <= limit && passes($0) }
        reloadRevision += 1
    }

    func reset() {
        all.removeAll()
        events.removeAll()
        nextSeq = 1
        pauseSeq = 0
        inCount = 0
        outCount = 0
        droppedCount = 0
        startTime = HostClock.now
        pausedAt = startTime
        reloadRevision += 1
    }

    // MARK: Ports

    private func portsChanged() {
        ports = engine.ports
        thruPortNames = engine.thruPortNames
        engineError = engine.lastError
        updateSpyState()
        refilter()
    }

    func updateSpyState() {
        if engine.spySourceID != nil {
            spyState = .active
        } else {
            spyState = SpyDriverInstall.isInstalled ? .installedNotLoaded : .notInstalled
        }
        spyIsCurrent = !SpyDriverInstall.isInstalled || SpyDriverInstall.isCurrent
    }

    /// Ports of one direction that the plate's scope includes, online first.
    func ports(for direction: MIDIDirection) -> [PortInfo] {
        let scope = direction == .input ? inScope : outScope
        return ports.values
            .filter { $0.isSource == (direction == .input) && scope.includes($0.transport) }
            .sorted { ($0.online ? 0 : 1, $0.name) < ($1.online ? 0 : 1, $1.name) }
    }

    func rescan() {
        engine.refresh()
    }

    // MARK: Spy driver

    func installSpyDriver() {
        do {
            try SpyDriverInstall.install()
            spyMessage = "Installed in ~/Library/Audio/MIDI Drivers. Restart the MIDI server to load it."
        } catch {
            spyMessage = "Couldn't install the driver: \(error.localizedDescription)"
        }
        updateSpyState()
    }

    func uninstallSpyDriver() {
        do {
            try SpyDriverInstall.uninstall()
            spyMessage = "Removed. The MIDI server keeps the driver loaded until it restarts."
        } catch {
            spyMessage = "Couldn't remove the driver: \(error.localizedDescription)"
        }
        updateSpyState()
    }

    /// Restarts the MIDI server, then reopens MxMidiPRO: once the server has gone, CoreMIDI won't give this process a
    /// new client (error -2), while a fresh process starts the server again and it loads the driver.
    func restartMIDIServer() {
        do {
            try SpyDriverInstall.restartMIDIServer()
        } catch {
            spyMessage = error.localizedDescription
            return
        }
        showOutSetup = false
        SpyDriverInstall.relaunchApp()
    }

    // MARK: Logic Pro

    private func watchLogic() {
        let workspace = NSWorkspace.shared
        logicRunning = workspace.runningApplications.contains { $0.bundleIdentifier == Self.logicBundleID }
        for (name, running) in [(NSWorkspace.didLaunchApplicationNotification, true),
                                (NSWorkspace.didTerminateApplicationNotification, false)] {
            let token = workspace.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == Self.logicBundleID else { return }
                MainActor.assumeIsolated { self?.logicRunning = running }
            }
            observers.append(token)
        }
    }

    // MARK: Text

    var formatter: MIDIFormatter {
        MIDIFormatter(middleCOctave: middleCOctave, timeDisplay: timeDisplay, startTime: startTime,
                      portNames: ports.mapValues(\.name))
    }

    func copyText(rows: IndexSet) -> String {
        let f = formatter
        return rows.compactMap { $0 < events.count ? f.line(events[$0], raw: showRaw) : nil }.joined(separator: "\n")
    }

    func exportLog() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText, .commaSeparatedText]
        panel.showsContentTypes = true
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: ".")
        panel.nameFieldStringValue = "MxMidiPRO \(stamp).txt"
        panel.message = "Exports the \(events.count) messages the log shows (its filters apply)."
        let snapshot = events
        let f = formatter
        let raw = showRaw
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text: String
        if url.pathExtension.lowercased() == "csv" {
            text = ([MIDIFormatter.csvHeader] + snapshot.map(f.csvRow)).joined(separator: "\n") + "\n"
        } else {
            text = snapshot.map { f.line($0, raw: raw) }.joined(separator: "\n") + "\n"
        }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
