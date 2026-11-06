//
//  ModxLink.swift — MxModxUSB
//
//  The USB MIDI connection to the MODX and the one-at-a-time request engine.
//
//  The MODX shows three ports: Port 1 is the instrument itself (keyboard, controllers, tone generator, SysEx),
//  Port 3 connects the computer to the MODX's 5-pin MIDI IN/OUT jacks, and Port 2 isn't used by the instrument.
//  MxModxUSB listens on all three and sends requests to Port 1 only.
//
//  Only requests the MODX accepts are ever sent (`isAllowed`): it answers a request for anything else with an
//  "Illegal Bulk Data" message on its screen — harmless, but it interrupts the player. Accepted, checked on a MODX7
//  (firmware 2.50): direct Dump Requests for System, Sequencer and the micro-tuning names; the Bulk Headers for the
//  current Performance's Common and Parts, the current Live Set and the user curves; Parameter Requests inside the
//  Performance Common and Part blocks (all 16 Parts always exist).
//

import CoreMIDI
import Foundation

enum ModxPort: Int, CaseIterable, Identifiable {
    case instrument, port2, din

    var id: Int { rawValue }
    var title: String { "Port \(rawValue + 1)" }

    var role: String {
        switch self {
        case .instrument: "The MODX itself: keyboard, controllers, tone generator and SysEx"
        case .port2: "Not used by the instrument"
        case .din: "Bridges USB to the MODX's 5-pin MIDI IN/OUT jacks"
        }
    }
}

/// One request the app sent the MODX and what came back, for MIDI Activity ▸ Requests.
struct ModxRequestRecord: Identifiable {
    let id: Int
    let time: Date
    let request: String
    let bytes: String
    let outcome: String
    let problem: Bool
}

/// A channel or system message the MODX sent, for the live view.
struct ModxLiveMessage {
    let port: ModxPort
    let status: UInt8
    let data1: UInt8
    let data2: UInt8
    /// When CoreMIDI received it (host time), for timing the MIDI clock.
    var hostTime: UInt64 = 0
}

@MainActor
final class ModxLink {
    // MARK: Ports

    struct Endpoints: Equatable {
        var device = MIDIDeviceRef()
        var deviceName = ""
        var sources: [MIDIEndpointRef] = [0, 0, 0]
        var destinations: [MIDIEndpointRef] = [0, 0, 0]
        var names: [String] = ["", "", ""]
    }

    private(set) var endpoints = Endpoints()
    var isConnected: Bool { endpoints.sources[0] != 0 && endpoints.destinations[0] != 0 }

    var onPortsChanged: (() -> Void)?
    var onLive: (([ModxLiveMessage]) -> Void)?

    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var outputPort = MIDIPortRef()
    private let router = Router()
    private var connectedSources: [MIDIEndpointRef] = [0, 0, 0]
    private(set) var lastError: String?

    func start() {
        let router = self.router
        router.link = self
        var newClient = MIDIClientRef()
        let status = MIDIClientCreateWithBlock("MxModxUSB" as CFString, &newClient, Self.notifyBlock(router))
        guard status == noErr else { lastError = "CoreMIDI refused a client (error \(status))."; return }
        client = newClient
        MIDIInputPortCreateWithProtocol(client, "MxModxUSB In" as CFString, ._1_0, &inputPort, Self.receiveBlock(router))
        MIDIOutputPortCreate(client, "MxModxUSB Out" as CFString, &outputPort)
        rescan()
    }

    /// Finds the MODX's device and its three ports, and listens to the ports' sources.
    func rescan() {
        guard client != 0 else { return }
        var found = Endpoints()
        for i in 0..<MIDIGetNumberOfDevices() {
            let device = MIDIGetDevice(i)
            let name = Self.string(device, kMIDIPropertyName) ?? ""
            let model = Self.string(device, kMIDIPropertyModel) ?? ""
            let maker = Self.string(device, kMIDIPropertyManufacturer) ?? ""
            guard (name.hasPrefix("MODX") || model.hasPrefix("MODX")), maker.contains("Yamaha"),
                  Self.integer(device, kMIDIPropertyOffline) != 1 else { continue }
            found.device = device
            found.deviceName = name
            for e in 0..<min(MIDIDeviceGetNumberOfEntities(device), 3) {
                let entity = MIDIDeviceGetEntity(device, e)
                if MIDIEntityGetNumberOfSources(entity) > 0 { found.sources[e] = MIDIEntityGetSource(entity, 0) }
                if MIDIEntityGetNumberOfDestinations(entity) > 0 { found.destinations[e] = MIDIEntityGetDestination(entity, 0) }
                found.names[e] = Self.string(found.sources[e], kMIDIPropertyDisplayName) ?? "MODX Port \(e + 1)"
            }
            break
        }
        for port in 0..<3 where connectedSources[port] != found.sources[port] {
            if connectedSources[port] != 0 { MIDIPortDisconnectSource(inputPort, connectedSources[port]) }
            connectedSources[port] = 0
            if found.sources[port] != 0,
               MIDIPortConnectSource(inputPort, found.sources[port], UnsafeMutableRawPointer(bitPattern: port + 1)) == noErr {
                connectedSources[port] = found.sources[port]
            }
        }
        let changed = found != endpoints
        endpoints = found
        if !isConnected { failPending() }
        if changed { onPortsChanged?() }
    }

    // MARK: Requests

    enum Kind {
        case identity
        case parameter(ModxAddress)
        case dump(ModxAddress)
        case bulk(ModxAddress)
    }

    /// Whether the MODX accepts this request (see the file's header).
    static func isAllowed(_ kind: Kind) -> Bool {
        switch kind {
        case .identity:
            return true
        case .dump(let a):
            return a == .system || a == .sequencer || (a.high == 0x00 && (a.mid >> 4 == 0x5 || a.mid >> 4 == 0x3) && a.mid & 0x0F < 8 && a.low == 0)
        case .bulk(let a):
            return a == .performanceCommonBulk || a == .liveSetBulk || a == .curveBulk
                || (a.high == 0x0E && a.mid == 0x52 && a.low < 16)
        case .parameter(let a):
            return (a.high == 0x30 && a.mid == 0x40 && a.low < 0x5E) || (a.high == 0x31 && a.mid < 16 && a.low < 0x79)
        }
    }

    private struct Pending {
        let id: Int
        let kind: Kind
        let message: [UInt8]
        let started: Date
        var blocks: [ModxBlock] = []
        var sawHeader = false
        var deadline: Date
        let idle: TimeInterval
        let finish: (Result) -> Void
    }

    enum Result {
        case identity(ModxIdentity)
        case parameter([UInt8])
        case block(ModxBlock)
        case bulk([ModxBlock])
        case timeout
    }

    private var pending: Pending?
    private var nextID = 0
    private var gateBusy = false
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []
    private var watchdog: Timer?
    private(set) var requestsSent = 0
    private(set) var unanswered = 0
    var onProgress: ((Int) -> Void)?
    var onRecord: ((ModxRequestRecord) -> Void)?

    /// No request goes out before this: set when the MODX sends Bank Select or Program Change (it is loading a
    /// Performance), so the app never asks while the instrument is busy.
    private var quietUntil = Date.distantPast
    /// The last bulk block or unrequested SysEx from the MODX; a request waits for a short silence after it, so it
    /// never lands mid-dump. (A single answer to a single request needs no gap.)
    private var lastSysex = Date.distantPast
    private static let settleAfterSelect: TimeInterval = 1.5
    private static let gapAfterSysex: TimeInterval = 0.12

    /// Holds requests back for a while (the model calls this when the player is changing things on the MODX).
    func holdRequests(for seconds: TimeInterval) {
        quietUntil = max(quietUntil, Date().addingTimeInterval(seconds))
    }

    func identity() async -> ModxIdentity? {
        if case .identity(let id) = await run(.identity, timeout: 0.6, idle: 0) { return id }
        return nil
    }

    /// One parameter's data bytes (Parameter Request → Parameter Change).
    func parameter(_ address: ModxAddress) async -> [UInt8]? {
        if case .parameter(let data) = await run(.parameter(address), timeout: 0.3, idle: 0) { return data }
        return nil
    }

    func dump(_ address: ModxAddress) async -> ModxBlock? {
        if case .block(let block) = await run(.dump(address), timeout: 1.0, idle: 0) { return block }
        return nil
    }

    /// Every block between a Bulk Header and its Footer. `bulkInterval` is the MODX's own gap between blocks.
    func bulk(_ header: ModxAddress, bulkInterval: TimeInterval = 0.05) async -> [ModxBlock]? {
        if case .bulk(let blocks) = await run(.bulk(header), timeout: 3.0 + bulkInterval, idle: 3.0 + bulkInterval * 2) {
            return blocks
        }
        return nil
    }

    private func run(_ kind: Kind, timeout: TimeInterval, idle: TimeInterval) async -> Result {
        guard Self.isAllowed(kind) else {
            assertionFailure("MxModxUSB only sends requests the MODX accepts")
            return .timeout
        }
        await acquire()
        defer { release() }
        while isConnected, Date() < quietUntil || Date().timeIntervalSince(lastSysex) < Self.gapAfterSysex {
            try? await Task.sleep(for: .milliseconds(40))
        }
        guard isConnected else { return .timeout }
        let message: [UInt8] = switch kind {
        case .identity: ModxSysEx.identityRequest
        case .parameter(let a): ModxSysEx.parameterRequest(a)
        case .dump(let a), .bulk(let a): ModxSysEx.dumpRequest(a)
        }
        return await withCheckedContinuation { continuation in
            nextID += 1
            pending = Pending(id: nextID, kind: kind, message: message, started: Date(),
                              deadline: Date().addingTimeInterval(timeout), idle: idle) {
                continuation.resume(returning: $0)
            }
            startWatchdog()
            send(message)
        }
    }

    // MARK: Writing

    /// Whether MxModxUSB may send this Parameter Change: the address and size must be a setting in ModxParams and
    /// the value one the MODX accepts.
    static func isWritable(_ address: ModxAddress, data: [UInt8]) -> Bool {
        guard let (_, param) = ModxParams.find(address, size: data.count), data.allSatisfy({ $0 < 0x80 }) else { return false }
        if param.isText { return data.count == 1 && data[0] >= 0x20 && data[0] < 0x7F }   // one character at a time
        if case .bit = param.encoding { return true }
        var block = [UInt8](repeating: 0, count: param.offset + param.size)
        block.replaceSubrange(param.offset..<(param.offset + param.size), with: data)
        guard let value = param.value(in: block) else { return false }
        return param.isAllowed(value)
    }

    /// Sends one Parameter Change. The MODX doesn't answer one, so the caller reads the setting back to confirm it.
    @discardableResult
    func change(_ address: ModxAddress, data: [UInt8]) async -> Bool {
        guard Self.isWritable(address, data: data) else {
            assertionFailure("MxModxUSB only changes settings it knows, to values the MODX accepts")
            return false
        }
        await acquire()
        defer { release() }
        while isConnected, Date() < quietUntil || Date().timeIntervalSince(lastSysex) < Self.gapAfterSysex {
            try? await Task.sleep(for: .milliseconds(40))
        }
        guard isConnected else { return false }
        let message = ModxSysEx.parameterChange(address, data: data)
        nextID += 1
        send(message)
        onRecord?(ModxRequestRecord(id: nextID, time: Date(), request: "Parameter Change \(address)",
                                    bytes: message.map { String(format: "%02X", $0) }.joined(separator: " "),
                                    outcome: "sent", problem: false))
        try? await Task.sleep(for: .milliseconds(12))
        return true
    }

    /// Live Set Select, as touching a slot on the MODX does: Bank Select MSB 62, LSB = page (0–15), Program Change =
    /// slot (0–15), on the channel the MODX takes Performance changes on (Data List: "Live Set Page 1 … 16, 62, 0 … 15,
    /// Receive only"). The MODX then loads the slot's Performance, so requests wait as after its own Program Change.
    /// The only channel messages MxModxUSB sends.
    static func liveSetSelect(page: Int, slot: Int, channel: UInt8) -> [[UInt8]]? {
        guard (0..<16).contains(page), (0..<16).contains(slot), channel < 16 else { return nil }
        return [[0xB0 | channel, 0x00, 0x3E], [0xB0 | channel, 0x20, UInt8(page)], [0xC0 | channel, UInt8(slot)]]
    }

    @discardableResult
    func selectLiveSetSlot(page: Int, slot: Int, channel: UInt8) async -> Bool {
        guard let messages = Self.liveSetSelect(page: page, slot: slot, channel: channel) else { return false }
        await acquire()
        defer { release() }
        while isConnected, Date() < quietUntil || Date().timeIntervalSince(lastSysex) < Self.gapAfterSysex {
            try? await Task.sleep(for: .milliseconds(40))
        }
        guard isConnected else { return false }
        for message in messages { send(words: UMP.messageWords(message)) }
        holdRequests(for: Self.settleAfterSelect)
        nextID += 1
        onRecord?(ModxRequestRecord(id: nextID, time: Date(), request: "Live Set Select page \(page + 1), slot \(slot + 1)",
                                    bytes: messages.map { $0.map { String(format: "%02X", $0) }.joined(separator: " ") }.joined(separator: "  "),
                                    outcome: "sent", problem: false))
        return true
    }

    /// Sends Bulk Dump messages one after another (a workspace section: header, blocks, footer), `pause` apart.
    @discardableResult
    func sendBulk(_ blocks: [(ModxAddress, [UInt8])], label: String, pause: TimeInterval = 0.03,
                  progress: ((Int) -> Void)? = nil) async -> Bool {
        guard blocks.allSatisfy({ ModxBulkRules.isAllowed($0.0, size: $0.1.count) }) else {
            assertionFailure("MxModxUSB only sends blocks the MODX itself dumps")
            return false
        }
        await acquire()
        defer { release() }
        while isConnected, Date() < quietUntil || Date().timeIntervalSince(lastSysex) < Self.gapAfterSysex {
            try? await Task.sleep(for: .milliseconds(40))
        }
        guard isConnected else { return false }
        let started = Date()
        for (i, (address, data)) in blocks.enumerated() {
            guard isConnected else { return false }
            send(ModxSysEx.bulkDump(address, data: data))
            progress?(i + 1)
            try? await Task.sleep(for: .seconds(pause))
        }
        nextID += 1
        onRecord?(ModxRequestRecord(id: nextID, time: started, request: "Bulk Dump \(label)",
                                    bytes: "\(blocks.count) blocks from \(blocks.first.map { "\($0.0)" } ?? "—")",
                                    outcome: "sent in \(Int(Date().timeIntervalSince(started) * 1000)) ms", problem: false))
        return true
    }

    private static func describe(_ kind: Kind) -> String {
        switch kind {
        case .identity: "Identity Request"
        case .parameter(let a): "Parameter Request \(a)"
        case .dump(let a): "Dump Request \(a)"
        case .bulk(let a): "Bulk Request \(a)"
        }
    }

    private func acquire() async {
        if !gateBusy { gateBusy = true; return }
        await withCheckedContinuation { gateWaiters.append($0) }
    }

    private func release() {
        if gateWaiters.isEmpty { gateBusy = false } else { gateWaiters.removeFirst().resume() }
    }

    private func complete(_ result: Result, footer: Bool = true) {
        guard let p = pending else { return }
        pending = nil
        let ms = Int(Date().timeIntervalSince(p.started) * 1000)
        let (outcome, problem): (String, Bool) = switch result {
        case .timeout: ("no answer", true)
        case .bulk(let blocks): footer ? ("\(blocks.count) blocks in \(ms) ms", false)
            : ("\(blocks.count) blocks, then silence — no closing block", true)
        default: ("answered in \(ms) ms", false)
        }
        if problem { unanswered += 1 }
        onRecord?(ModxRequestRecord(id: p.id, time: p.started, request: Self.describe(p.kind),
                                    bytes: p.message.map { String(format: "%02X", $0) }.joined(separator: " "),
                                    outcome: outcome, problem: problem))
        p.finish(result)
    }

    private func failPending() { complete(.timeout) }

    private func startWatchdog() {
        guard watchdog == nil else { return }
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let p = self.pending else { self.watchdog?.invalidate(); self.watchdog = nil; return }
                if Date() > p.deadline {
                    if case .bulk = p.kind, !p.blocks.isEmpty { self.complete(.bulk(p.blocks), footer: false) }
                    else { self.complete(.timeout) }
                }
            }
        }
    }

    private func send(_ message: [UInt8]) {
        send(words: UMP.sysexWords(message))
    }

    private func send(words: [UInt32]) {
        guard isConnected else { return }
        requestsSent += 1
        var words = words
        let size = 64 + words.count * 4
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: MIDIEventList.self, capacity: 1)
        let packet = MIDIEventListInit(list, ._1_0)
        MIDIEventListAdd(list, size, packet, 0, words.count, &words)
        MIDISendEventList(outputPort, endpoints.destinations[0], list)
    }

    // MARK: Receiving (on the main thread, from the router)

    fileprivate func received(sysex: [[UInt8]], live: [ModxLiveMessage]) {
        if !live.isEmpty {
            // Bank Select or Program Change from the instrument: it is loading a Performance; let it finish.
            if live.contains(where: { $0.port == .instrument && ($0.status & 0xF0 == 0xC0
                || ($0.status & 0xF0 == 0xB0 && ($0.data1 == 0 || $0.data1 == 32))) }) {
                holdRequests(for: Self.settleAfterSelect)
            }
            onLive?(live)
        }
        for message in sysex {
            guard let reply = ModxSysEx.parse(message), var p = pending else { lastSysex = Date(); continue }
            switch (p.kind, reply) {
            case (.identity, .identity(let id)):
                complete(.identity(id))
            case (.parameter(let a), .parameter(let b, let data)) where a == b:
                complete(.parameter(data))
            case (.dump(let a), .block(let block)) where block.address == a:
                complete(.block(block))
            case (.bulk(let header), .block(let block)):
                lastSysex = Date()
                if block.address == header {
                    p.blocks = []
                } else if block.address == header.footer {
                    complete(.bulk(p.blocks))
                    continue
                } else {
                    p.blocks.append(block)
                    onProgress?(p.blocks.count)
                }
                p.deadline = Date().addingTimeInterval(p.idle)
                pending = p
            default:
                lastSysex = Date()
            }
        }
    }

    // MARK: CoreMIDI callbacks (built outside the main actor: CoreMIDI calls them on its own threads)

    private final class Router: @unchecked Sendable {
        weak var link: ModxLink?
        var parsers = [MIDIByteParser](repeating: MIDIByteParser(), count: 3)   // receive thread only
    }

    private nonisolated static func receiveBlock(_ router: Router) -> MIDIReceiveBlock {
        { list, refCon in
            let index = Int(bitPattern: refCon) - 1
            guard (0..<3).contains(index), let port = ModxPort(rawValue: index) else { return }
            var sysex: [[UInt8]] = []
            var live: [ModxLiveMessage] = []
            UMP.forEachPacket(in: list) { time, bytes in
                let when = time != 0 ? time : mach_absolute_time()
                for byte in bytes {
                    router.parsers[index].feed(byte) { status, d1, d2, message in
                        if let message { sysex.append(message) }
                        else { live.append(ModxLiveMessage(port: port, status: status, data1: d1, data2: d2, hostTime: when)) }
                    }
                }
            }
            guard !sysex.isEmpty || !live.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { router.link?.received(sysex: sysex, live: live) }
            }
        }
    }

    private nonisolated static func notifyBlock(_ router: Router) -> MIDINotifyBlock {
        { notification in
            switch notification.pointee.messageID {
            case .msgSetupChanged, .msgObjectAdded, .msgObjectRemoved:
                DispatchQueue.main.async { MainActor.assumeIsolated { router.link?.rescan() } }
            default:
                break
            }
        }
    }

    // MARK: Properties

    nonisolated static func string(_ object: MIDIObjectRef, _ key: CFString) -> String? {
        guard object != 0 else { return nil }
        var value: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(object, key, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    nonisolated static func integer(_ object: MIDIObjectRef, _ key: CFString) -> Int32? {
        guard object != 0 else { return nil }
        var value: Int32 = 0
        return MIDIObjectGetIntegerProperty(object, key, &value) == noErr ? value : nil
    }

    /// Every property CoreMIDI holds for an object (device, entity or endpoint), as text.
    nonisolated static func properties(_ object: MIDIObjectRef) -> [(String, String)] {
        guard object != 0 else { return [] }
        var list: Unmanaged<CFPropertyList>?
        guard MIDIObjectGetProperties(object, &list, false) == noErr,
              let dict = list?.takeRetainedValue() as? [String: Any] else { return [] }
        return dict.keys.sorted().map { key in
            let value = dict[key]
            let text: String = switch value {
            case let n as NSNumber: n.stringValue
            case let s as String: s
            case let d as Data: d.map { String(format: "%02X", $0) }.joined(separator: " ")
            case let a as [Any]: "\(a.count) items"
            case let d as [String: Any]: "\(d.count) entries"
            default: String(describing: value ?? "")
            }
            return (key, text)
        }
    }
}
