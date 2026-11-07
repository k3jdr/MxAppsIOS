//
//  ModxModel.swift — MxModxUSB
//
//  Everything the app knows about the connected MODX, and the order it is read in:
//    1. Identity, System and Sequencer — a few milliseconds;
//    2. the current Performance's name and tempo and its 16 Parts, by Parameter Requests — about a second;
//    3. in the background: the Performance's Common bulk (effects, knob names), each Part in use's own bulk (whether
//       it is AWM2, Drum or FM-X, and its elements), the current Live Set, the user curves and micro-tuning names.
//  Selecting another Performance on the MODX (it sends Bank Select and Program Change on Port 1) reads it again; so
//  does a change of name noticed by a light poll every few seconds.
//

import AppKit
import CoreMIDI
import Observation

/// What the MODX's controllers and keys are doing, refreshed 15 times a second.
struct ModxLiveState: Equatable {
    var notes: Set<Int> = []
    var lastVelocity: UInt8 = 0
    var pitchBend = 8192
    var controllers = [UInt8](repeating: 0, count: 128)
    var channelPressure: UInt8 = 0
    var clockBPM: Double?
    var activeSensing = false
    var counts = [0, 0, 0]
    var lastActivity: [Date?] = [nil, nil, nil]
}

struct ModxActivity: Identifiable {
    let id: Int
    let time: Date
    let port: ModxPort
    let text: String
    let kind: String
}

@MainActor
@Observable
final class ModxModel {
    @ObservationIgnored let link = ModxLink()

    // Instrument
    private(set) var connected = false
    private(set) var portNames: [String] = ["", "", ""]
    private(set) var identity: ModxIdentity?
    var system: ModxBlock?
    var sequencer: ModxBlock?

    // Performance
    var common = ModxPerformanceCommon()
    private(set) var commonDetailLoaded = false
    var parts: [ModxPart] = (0..<16).map { ModxPart(index: $0) }
    private(set) var partsLoaded = false

    // Live Set and user data
    var liveSet: ModxLiveSet?
    /// Names of the Performances Live Set slots recall: the preset list, and User and Library Performances' names as
    /// seen on the MODX (kept between launches).
    var performanceNames = ModxModel.loadSeenNames()
    /// Live Set banks in workspace files, for the Live Set screen's bank menu; newest first.
    var workspaceLiveSets: [ModxWorkspaceLiveSet] = []
    var liveSetRefreshing = false

    /// The MIDI Songs page: its song, editing and playing on the MODX (ModxSongStudio.swift).
    @ObservationIgnored let studio = ModxSongStudio()

    // Tutorials (ModxModel+Tutorial.swift)
    /// The FM-X or AWM2 Part a tutorial is using, with a copy of it as it was.
    var tutorial: ModxTutorialSession?
    var tutorialBusy: String?
    var tutorialReport: String?
    /// The engine whose tutorial the report is about (nil: about any, like a Performance change).
    var tutorialEngine: ModxEngine?
    /// The Live Set slot just chosen from the app, until the MODX has loaded its Performance.
    private(set) var selectingSlot: Int?
    var curves: [ModxUserCurve] = []
    var tuningNames: [String] = []

    // Host side
    private(set) var usb: USBDeviceInfo?
    private(set) var audio: AudioDeviceInfo?
    private(set) var midiProperties: [[(String, String)]] = [[], [], []]

    // Progress
    private(set) var status = "Looking for the MODX…"
    private(set) var loading = false
    private(set) var lastRead: Date?

    // Live
    private(set) var live = ModxLiveState()
    private(set) var activity: [ModxActivity] = []
    var showTimingMessages = false
    /// Every request sent to the MODX and what came back (MIDI Activity ▸ Requests).
    private(set) var requests: [ModxRequestRecord] = []
    /// Requests the MODX didn't answer, or bulks that stopped short.
    private(set) var problems = 0
    /// The bank and number of the Performance last selected on the MODX (it sends Bank Select and Program Change).
    private(set) var selection: (lsb: UInt8, number: Int)?

    // Editing and workspaces (ModxModel+Editing.swift)
    /// The latest bytes of every block read from the MODX, by address: what the screens show, what edits change and
    /// what a workspace saves.
    var store: [ModxAddress: ModxBlock] = [:]
    /// Off at every launch: no setting is sent to the MODX until the player unlocks changes (playing a Live Set
    /// slot, which only chooses what the MODX plays, doesn't need it).
    var editsUnlocked = false
    var undoStack: [ModxEdit] = []
    var editStatus: String?
    var workspace: ModxWorkspaceFile?
    var workspaceURL: URL?
    var workspaceBusy: String?
    @ObservationIgnored var pendingEdits: [String: ModxEdit] = [:]
    @ObservationIgnored var editTask: Task<Void, Never>?
    @ObservationIgnored var editedTargets: Set<ModxTarget> = []

    @ObservationIgnored private var liveDraft = ModxLiveState()
    @ObservationIgnored private var clockTimes: [TimeInterval] = []
    @ObservationIgnored private var lastSensing: TimeInterval = 0
    @ObservationIgnored private var activityID = 0
    @ObservationIgnored private var pendingActivity: [ModxActivity] = []
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var timers: [Timer] = []
    @ObservationIgnored private var lastPoll = Date.distantPast
    @ObservationIgnored private var bankMSB: UInt8 = 64
    @ObservationIgnored private var programChangesSeen = 0
    @ObservationIgnored private var bankLSB: UInt8 = 0

    init() {
        link.onPortsChanged = { [weak self] in self?.portsChanged() }
        link.onLive = { [weak self] in self?.received($0) }
        link.onRecord = { [weak self] record in
            guard let self else { return }
            self.requests.append(record)
            if self.requests.count > 1500 { self.requests.removeFirst(self.requests.count - 1500) }
            if record.problem { self.problems += 1 }
        }
        studio.model = self
        link.start()
        refreshHost()
        AudioDeviceInfo.watchDevices { [weak self] in
            MainActor.assumeIsolated { self?.audio = AudioDeviceInfo.find() }
        }
        timers.append(Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.publishLive() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollIfIdle() }
        })
        portsChanged()
    }

    // MARK: Connection

    private func portsChanged() {
        let was = connected
        connected = link.isConnected
        portNames = link.endpoints.names
        refreshHost()
        if connected && !was {
            readEverything()
        } else if !connected {
            studio.stop()
            status = link.endpoints.device == 0 ? "No MODX on USB. Connect it and turn it on." : "The MODX's ports are offline."
            identity = nil
        }
    }

    func refreshHost() {
        usb = USBDeviceInfo.find()
        audio = AudioDeviceInfo.find()
        let e = link.endpoints
        midiProperties = (0..<3).map { Self.portProperties(source: e.sources[$0], destination: e.destinations[$0]) }
    }

    /// Everything CoreMIDI holds for a port: its source's and destination's own properties, then what they inherit
    /// from the entity (the port) and the device (the MODX).
    private static func portProperties(source: MIDIEndpointRef, destination: MIDIEndpointRef) -> [(String, String)] {
        guard source != 0 || destination != 0 else { return [] }
        var rows: [(String, String)] = []
        rows += ModxLink.properties(source).map { ("Source · \($0.0)", $0.1) }
        rows += ModxLink.properties(destination).map { ("Destination · \($0.0)", $0.1) }
        var entity = MIDIEntityRef()
        var device = MIDIDeviceRef()
        if MIDIEndpointGetEntity(source != 0 ? source : destination, &entity) == noErr, entity != 0 {
            rows += ModxLink.properties(entity).map { ("Port · \($0.0)", $0.1) }
            if MIDIEntityGetDevice(entity, &device) == noErr, device != 0 {
                rows += ModxLink.properties(device).map { ("Device · \($0.0)", $0.1) }
            }
        }
        return rows
    }

    /// Reads everything again (the toolbar's Refresh).
    func readEverything() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in await self?.loadAll() }
    }

    private func loadAll() async {
        guard link.isConnected else { return }
        loading = true
        defer { loading = false; lastRead = Date() }
        status = "Asking the MODX who it is…"
        identity = await link.identity()
        status = "Reading System settings…"
        system = await link.dump(.system)
        sequencer = await link.dump(.sequencer)
        keep([system, sequencer].compactMap { $0 })
        await loadPerformance()
        if Task.isCancelled { return }
        status = "Reading the current Live Set…"
        if let blocks = await link.bulk(.liveSetBulk, bulkInterval: bulkInterval) {
            keep(blocks)
            liveSet = ModxLiveSet(blocks: blocks)
        }
        status = "Reading user curves and micro-tuning tables…"
        if let blocks = await link.bulk(.curveBulk, bulkInterval: bulkInterval) {
            keep(blocks)
            curves = blocks.compactMap(ModxUserCurve.init(block:))
        }
        var names: [String] = []
        for table in 0..<8 {
            if let block = await link.dump(.microTuningName(table)) { keep([block]); names.append(block.text(0, 20)) }
            if let block = await link.dump(.microTuningTable(table)) { keep([block]) }
        }
        tuningNames = names
        status = identity.map { "\($0.model), firmware \($0.firmware) — everything read." } ?? "Read what the MODX answered."
        if problems > 0 { status += " \(problems) request\(problems == 1 ? "" : "s") went unanswered (MIDI Activity ▸ Requests)." }
    }

    var bulkInterval: TimeInterval { Double(system?[0x1F] ?? 1) * 0.05 }

    /// The current Performance: name and Common values first, then the Parts, then the detail bulks.
    func loadPerformance() async {
        status = "Reading the current Performance…"
        commonDetailLoaded = false
        var newCommon = ModxPerformanceCommon()
        newCommon.name = await readText(.common, length: 20)
        if let tempo = await link.parameter(.common.with(low: 0x2C)), tempo.count >= 2 {
            newCommon.tempo = Int(tempo[0]) << 7 | Int(tempo[1])
        }
        if let volume = await link.parameter(.common.with(low: 0x38))?.first { newCommon.volume = Int(volume) }
        common = newCommon
        lastPoll = Date()

        status = "Reading the 16 Parts…"
        var newParts = (0..<16).map { ModxPart(index: $0) }
        for p in 0..<16 {
            if Task.isCancelled { return }
            let base = ModxAddress.part(p)
            guard let first = await link.parameter(base)?.first, first != 0 else { continue }   // an unused Part
            newParts[p].name = await readText(base, length: 20)
            for offset in ModxPart.requested where offset > 0x13 {
                if let value = await link.parameter(base.with(low: offset))?.first {
                    newParts[p].apply(offset: offset, value: value)
                }
            }
            newParts[p].loaded = true
            parts = newParts
        }
        parts = newParts
        partsLoaded = true

        status = "Reading the Performance's effects and knobs…"
        store = store.filter { $0.key.high != 0x30 && !ModxModel.isPartBlock($0.key) }   // a new Performance
        if let blocks = await link.bulk(.performanceCommonBulk, bulkInterval: bulkInterval) {
            keep(blocks)
            var detail = common
            for block in blocks { detail.read(block: block) }
            common = detail
            commonDetailLoaded = true
        }
        for p in 0..<16 where parts[p].inUse {
            if Task.isCancelled { return }
            status = "Reading Part \(p + 1)'s voice…"
            await readPartBulk(p)
        }
    }

    static func isPartBlock(_ a: ModxAddress) -> Bool {
        (0x31...0x38).contains(a.high) || a.high == 0x41 || a.high == 0x42 || a.high == 0x48 || a.high == 0x49
            || (0x50...0x5F).contains(a.high)
    }

    /// A Part's whole bulk: every block of it into the store, and its type (AWM2, Drum, FM-X) and elements. Returns
    /// the blocks in the order the MODX sent them.
    @discardableResult
    func readPartBulk(_ p: Int) async -> [ModxBlock]? {
        guard let blocks = await link.bulk(.performancePartBulk(p), bulkInterval: bulkInterval) else { return nil }
        keep(blocks)
        if let block = blocks.first(where: { $0.address == ModxAddress.part(p) }) { parts[p].read(block: block) }
        do {
            let elements = blocks.filter { $0.address.high == 0x41 }
            if !elements.isEmpty {
                parts[p].type = .awm2
                parts[p].elementsOn = elements.filter { $0[0] == 1 }.count
            } else if blocks.contains(where: { $0.address.high == 0x48 }) {
                parts[p].type = .fmx
            } else if blocks.contains(where: { $0.address.high & 0xF0 == 0x50 }) {
                parts[p].type = .drum
                parts[p].elementsOn = blocks.filter { $0.address.high & 0xF0 == 0x50 && $0[0] == 1 }.count
            }
        }
        return blocks
    }

    /// Puts blocks into the store (the newest bytes of each address win).
    func keep(_ blocks: [ModxBlock]) {
        for block in blocks { store[block.address] = block }
    }

    private func readText(_ base: ModxAddress, length: Int) async -> String {
        var bytes: [UInt8] = []
        for i in 0..<length {
            guard let b = await link.parameter(base.with(low: base.low + UInt8(i)))?.first else { break }
            bytes.append(b)
        }
        return ModxSysEx.text(bytes)
    }

    /// A Performance change noticed on the panel: Program Change on Port 1, or a new name in the light poll.
    /// `chosen`: the Bank Select and Program Change the MODX sent, if that's how the change was noticed. `selected`: the
    /// Live Set slot chosen from the app, when the MODX didn't answer with a Program Change of its own.
    private func performanceMayHaveChanged(chosen: (msb: UInt8, lsb: UInt8, number: Int)? = nil,
                                           selected: (slot: ModxLiveSlot, nameBefore: String)? = nil) {
        guard lastRead != nil else { readEverything(); return }   // the first full read isn't finished: start it over
        reloadTask?.cancel()
        if tutorial != nil {
            tutorial = nil
            tutorialEngine = nil
            tutorialReport = "Another Performance was chosen on the MODX, so the tutorial's changes went with the one before. Start again with a Part of this one."
        }
        // The edit buffer now holds another Performance (the Live Set's edit buffer stays as it was).
        undoStack.removeAll {
            switch $0.target { case .liveSetBank, .liveSetPage, .liveSetSlot: false; default: $0.target.isEditBuffer }
        }
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            self.loading = true
            await self.loadPerformance()
            // A whole Performance (MSB 64) now loaded under its own name: Live Set slots recalling it show that name.
            // (MSB 63 changes one Part only, so the name then is still the old Performance's.)
            if let chosen, chosen.msb == 64, !Task.isCancelled, !self.common.name.isEmpty {
                self.learnPerformanceName(lsb: chosen.lsb, number: chosen.number, name: self.common.name)
            }
            self.loading = false
            self.lastRead = Date()
            self.status = "Read “\(self.common.name)”."
            if let selected, !Task.isCancelled { self.confirmSelection(selected.slot, nameBefore: selected.nameBefore) }
            self.selectingSlot = nil
        }
    }

    // MARK: Choosing a Live Set slot

    /// Why the MODX won't take a Live Set Select now, or nil if it will.
    var liveSetSelectProblem: String? {
        guard connected else { return "Connect the MODX first." }
        guard let system, liveSet != nil else { return "The MODX hasn't been read yet." }
        if system[0x14] == 0 || system[0x15] == 0 {
            return "The MODX is set not to receive Bank Select and Program Change: switch both on (UTILITY ▸ Settings ▸ MIDI I/O) to choose slots from here."
        }
        return nil
    }

    /// Whether changes made here to the Performance are still only in the MODX's edit buffer: choosing a slot
    /// replaces the Performance, and they're lost.
    var hasUnstoredPerformanceEdits: Bool {
        undoStack.contains {
            switch $0.target { case .liveSetBank, .liveSetPage, .liveSetSlot: false; default: $0.target.isEditBuffer }
        }
    }

    /// Chooses a slot of the MODX's Live Set, as touching it on the MODX does: the MODX loads the slot's Performance.
    /// The app then reads the Performance, at once if the MODX answers with its Bank Select and Program Change, or
    /// after a moment if it doesn't.
    func selectLiveSetSlot(_ slot: ModxLiveSlot) {
        guard liveSetSelectProblem == nil, !slot.isEmpty, selectingSlot == nil, let system else { return }
        // Single channel mode: the MIDI I/O Channel; Multi: Part 1's channel (the Data List's receive rules).
        let channel: UInt8 = system[0x30] == 1 ? min(system[0x31], 15) : 0
        let nameBefore = common.name
        let programChanges = programChangesSeen
        selectingSlot = slot.id
        selection = nil   // until the MODX shows it took the slot
        status = "Choosing page \(slot.page + 1), slot \(slot.slot + 1) on the MODX…"
        Task { [weak self] in
            guard let self else { return }
            guard await self.link.selectLiveSetSlot(page: slot.page, slot: slot.slot, channel: channel) else {
                self.selectingSlot = nil
                self.status = "Couldn't reach the MODX."
                return
            }
            try? await Task.sleep(for: .milliseconds(300))
            if self.programChangesSeen == programChanges {
                self.performanceMayHaveChanged(selected: (slot, nameBefore))
            }
            try? await Task.sleep(for: .seconds(8))
            if self.selectingSlot == slot.id { self.selectingSlot = nil }   // in case no read finished
        }
    }

    /// After choosing a slot when the MODX sent no Program Change back: whether it now plays the slot's Performance.
    private func confirmSelection(_ slot: ModxLiveSlot, nameBefore: String) {
        let name = common.name
        let known = performanceNames.name(of: slot)
        // The MODX took the slot if it now plays the Performance the slot names, or anything other than before.
        let took = !name.isEmpty && (name == known?.name || name != nameBefore)
        let place = "page \(slot.page + 1), slot \(slot.slot + 1)"
        guard took else {
            status = "Sent \(place) to the MODX; it still plays “\(name)”."
            return
        }
        selection = (slot.bankLSB, slot.number)
        // A User or Library Performance's name, now known (never a preset's from this guess: the list has those).
        if slot.bankMSB == 64, known?.source != .preset { learnPerformanceName(lsb: slot.bankLSB, number: slot.number, name: name) }
        status = "Chose \(place): “\(name)”."
    }

    /// The MODX sends Program Change when a Performance is chosen if "Receive/Transmit Program Change" is on (the
    /// default); only when it's off does the app check the name now and then.
    private func pollIfIdle() {
        guard connected, !loading, let system, system[0x15] == 0, Date().timeIntervalSince(lastPoll) > 8 else { return }
        lastPoll = Date()
        Task { [weak self] in
            guard let self else { return }
            let name = await self.readText(.common, length: 20)
            if !name.isEmpty, name != self.common.name, !self.loading { self.performanceMayHaveChanged() }
        }
    }

    // MARK: Live messages

    private func received(_ messages: [ModxLiveMessage]) {
        let now = Date()
        for m in messages {
            liveDraft.counts[m.port.rawValue] += 1
            liveDraft.lastActivity[m.port.rawValue] = now
            switch m.status {
            case 0xF8:
                if m.port == .instrument { clock(Self.seconds(m.hostTime)) }
                if showTimingMessages { note(m, now) }
                continue
            case 0xFE:
                if m.port == .instrument { lastSensing = now.timeIntervalSinceReferenceDate }
                if showTimingMessages { note(m, now) }
                continue
            default:
                break
            }
            note(m, now)
            guard m.port == .instrument else { continue }
            switch m.status & 0xF0 {
            case 0x90 where m.data2 > 0:
                liveDraft.notes.insert(Int(m.data1))
                liveDraft.lastVelocity = m.data2
            case 0x80, 0x90:
                liveDraft.notes.remove(Int(m.data1))
            case 0xB0:
                liveDraft.controllers[Int(m.data1)] = m.data2
                if m.data1 == 0 { bankMSB = m.data2 }
                if m.data1 == 32 { bankLSB = m.data2 }
                if m.data1 == 123 || m.data1 == 120 { liveDraft.notes.removeAll() }
            case 0xD0:
                liveDraft.channelPressure = m.data1
            case 0xE0:
                liveDraft.pitchBend = Int(m.data2) << 7 | Int(m.data1)
            case 0xC0:
                programChangesSeen += 1
                selection = (bankLSB, Int(m.data1) + 1)
                performanceMayHaveChanged(chosen: (bankMSB, bankLSB, Int(m.data1) + 1))
            default:
                break
            }
        }
    }

    private static let tickSeconds: Double = {
        var base = mach_timebase_info_data_t()
        mach_timebase_info(&base)
        return Double(base.numer) / Double(base.denom) / 1e9
    }()

    private static func seconds(_ hostTime: UInt64) -> TimeInterval { Double(hostTime) * tickSeconds }

    /// The MIDI clock's tempo from CoreMIDI's time stamps (24 clocks a beat), averaged over the last two beats.
    private func clock(_ t: TimeInterval) {
        clockTimes.append(t)
        if clockTimes.count > 49 { clockTimes.removeFirst(clockTimes.count - 49) }
        if clockTimes.count >= 25, let first = clockTimes.first, let last = clockTimes.last, last > first {
            let interval = (last - first) / Double(clockTimes.count - 1)
            liveDraft.clockBPM = 60 / (interval * 24)
        }
    }

    private func note(_ m: ModxLiveMessage, _ time: Date) {
        activityID += 1
        pendingActivity.append(ModxActivity(id: activityID, time: time, port: m.port, text: ModxLiveText.describe(m),
                                            kind: ModxLiveText.kind(m.status)))
    }

    private func publishLive() {
        let now = Date().timeIntervalSinceReferenceDate
        liveDraft.activeSensing = now - lastSensing < 1
        if let last = clockTimes.last, Self.seconds(mach_absolute_time()) - last > 1 {
            liveDraft.clockBPM = nil
            clockTimes.removeAll()
        }
        if liveDraft != live { live = liveDraft }
        if !pendingActivity.isEmpty {
            activity.append(contentsOf: pendingActivity)
            pendingActivity.removeAll()
            if activity.count > 500 { activity.removeFirst(activity.count - 500) }
        }
    }

    func clearActivity() {
        activity.removeAll()
        liveDraft.counts = [0, 0, 0]
    }

    // MARK: Derived

    var systemSettings: [ModxSetting] {
        (system.map(ModxSystemTable.settings) ?? []) + (sequencer.map(ModxSystemTable.sequencer) ?? [])
    }

    func systemValue(_ name: String) -> String {
        systemSettings.first { $0.name == name }?.value ?? "—"
    }

    var partsInUse: [ModxPart] { parts.filter(\.inUse) }

    /// The Live Set slot holding the current Performance: the one with the bank and number last selected on the
    /// MODX, or else one whose Performance has the current one's name (or, failing that, a slot named like it).
    var currentSlot: ModxLiveSlot? {
        if let selection, let slot = liveSet?.slots.first(where: { $0.bankLSB == selection.lsb && $0.number == selection.number }) {
            return slot
        }
        guard !common.name.isEmpty else { return nil }
        return liveSet?.slots.first { performanceNames.name(of: $0)?.name == common.name }
            ?? liveSet?.slots.first { $0.name == common.name }
    }

    var superKnobControl: UInt8 { system?[0x17] ?? 95 }

    /// The controller number an assignable knob sends, from the Performance (0 if off or unknown).
    func knobControl(_ knob: Int) -> UInt8 {
        knob < common.knobNumbers.count ? common.knobNumbers[knob] : 0
    }
}

enum ModxLiveText {
    static func describe(_ m: ModxLiveMessage) -> String {
        let ch = Int(m.status & 0x0F) + 1
        switch m.status & 0xF0 {
        case 0x80: return "Note Off  \(ModxNames.note(Int(m.data1)))  ch \(ch)"
        case 0x90: return m.data2 == 0 ? "Note Off  \(ModxNames.note(Int(m.data1)))  ch \(ch)"
            : "Note On  \(ModxNames.note(Int(m.data1)))  velocity \(m.data2)  ch \(ch)"
        case 0xA0: return "Poly Pressure  \(ModxNames.note(Int(m.data1)))  \(m.data2)  ch \(ch)"
        case 0xB0: return "Control Change  CC \(m.data1) = \(m.data2)  ch \(ch)"
        case 0xC0: return "Program Change  \(Int(m.data1) + 1)  ch \(ch)"
        case 0xD0: return "Channel Pressure  \(m.data1)  ch \(ch)"
        case 0xE0: return "Pitch Bend  \(Int(m.data2) << 7 | Int(m.data1) - 8192)  ch \(ch)"
        default:
            switch m.status {
            case 0xF8: return "Clock"
            case 0xFA: return "Start"
            case 0xFB: return "Continue"
            case 0xFC: return "Stop"
            case 0xFE: return "Active Sensing"
            case 0xF2: return "Song Position  \(Int(m.data2) << 7 | Int(m.data1))"
            default: return String(format: "Status %02X", m.status)
            }
        }
    }

    static func kind(_ status: UInt8) -> String {
        switch status & 0xF0 {
        case 0x80, 0x90: "note"
        case 0xB0: "cc"
        case 0xC0: "program"
        case 0xE0, 0xD0, 0xA0: "expression"
        default: status == 0xF8 || status == 0xFE ? "timing" : "system"
        }
    }
}
