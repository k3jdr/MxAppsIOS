//
//  MIDIEngine.swift — MxMidiPRO
//
//  The CoreMIDI side of the monitor.
//
//  IN  — CoreMIDI hands every source's messages to every client that connects, so MxMidiPRO connects an input port
//        to every source and sees exactly what Logic Pro receives from each device, without being in the way.
//  OUT — what Logic Pro sends to a device goes from Logic Pro to the device's driver; no other client sees it. Two
//        ways in:
//        • the MxMidiPRO Spy driver (SpyDriver/), which the MIDI server loads like any device driver and which asks
//          for a copy of every packet sent to every destination; it re-sends the copies on a private source, found
//          here by its driver's bundle identifier;
//        • thru ports: a virtual destination "MxMidiPRO ▸ device" per hardware destination, passed straight on to
//          the device. Logic Pro has to be pointed at them, so they only see what is routed through them.
//
//  CoreMIDI calls the receive blocks on its own thread. They parse there and leave the messages in `pending`, which
//  the store drains on the main thread 30 times a second.
//

import CoreMIDI
import Foundation

final class MIDIEngine {
    static let spyDriverID = "com.k3jdr.MxMidiPRO.SpyDriver"

    /// For Tools/MxSpyHarness: `-MxSpyTestSource "<source name>"` on the command line treats that ordinary source as
    /// the spy's feed. Only the command line is read, so it can't stick in the app's preferences.
    static let spyTestSourceName = commandLineValue("-MxSpyTestSource")

    /// For Tools/MxMidiTests: `-MxThruTestTarget "<destination name>"` also gives that virtual destination a thru
    /// port (normally only hardware gets one), so the thru path can be tested without sending to real devices.
    static let thruTestTargetName = commandLineValue("-MxThruTestTarget")

    private static func commandLineValue(_ flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// One stream of bytes — a source, the spy feed, or a thru port — and its parser. The parser is only touched on
    /// CoreMIDI's receive thread; the object lives as long as the engine because CoreMIDI holds it as a refCon.
    final class Stream {
        let direction: MIDIDirection
        let route: MIDIRoute
        let portID: MIDIUniqueID
        var parser = MIDIByteParser()

        init(direction: MIDIDirection, route: MIDIRoute, portID: MIDIUniqueID) {
            self.direction = direction
            self.route = route
            self.portID = portID
        }
    }

    /// What the receive thread reads: our own thru ports (never logged as destinations), where each thru port
    /// forwards to, and whether the spy is live (then the spy logs what goes through the thru ports).
    private struct Shared {
        var ownIDs: Set<MIDIUniqueID> = []
        var thruTargets: [MIDIUniqueID: MIDIEndpointRef] = [:]
        var spyLive = false
    }

    private(set) var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var outputPort = MIDIPortRef()
    private(set) var lastError: String?

    /// Every port seen since launch, by unique ID; a port that goes away stays, marked offline, so its messages keep
    /// their name.
    private(set) var ports: [MIDIUniqueID: PortInfo] = [:]
    private var connected: [MIDIUniqueID: MIDIEndpointRef] = [:]
    private var inputStreams: [MIDIUniqueID: Stream] = [:]

    private let spyStream = Stream(direction: .output, route: .spy, portID: 0)
    private var spySource = MIDIEndpointRef()
    private(set) var spySourceID: MIDIUniqueID?
    private var spyDestinationParsers: [MIDIUniqueID: MIDIByteParser] = [:]   // receive thread only

    var thruEnabled = false {
        didSet { if thruEnabled != oldValue { refresh() } }
    }
    private var thruPorts: [MIDIUniqueID: MIDIEndpointRef] = [:]               // target → our destination
    private var thruStreams: [MIDIUniqueID: Stream] = [:]
    private(set) var thruPortNames: [String] = []

    private let lock = NSLock()
    private var shared = Shared()
    private var pending: [MIDIEvent] = []
    private var droppedSinceDrain = 0
    private static let pendingLimit = 500_000

    private var refreshScheduled = false

    /// Called on the main thread after the ports change.
    var onChange: (() -> Void)?

    // MARK: Start

    func start() {
        var newClient = MIDIClientRef()
        let status = MIDIClientCreateWithBlock("MxMidiPRO" as CFString, &newClient) { [weak self] notification in
            switch notification.pointee.messageID {
            case .msgSetupChanged, .msgObjectAdded, .msgObjectRemoved, .msgPropertyChanged:
                DispatchQueue.main.async { self?.scheduleRefresh() }
            default:
                break
            }
        }
        guard status == noErr else {
            lastError = "CoreMIDI refused a client (error \(status))."
            return
        }
        client = newClient

        let inStatus = MIDIInputPortCreateWithProtocol(client, "MxMidiPRO Monitor" as CFString, ._1_0,
                                                       &inputPort) { [weak self] list, refCon in
            self?.received(list, refCon: refCon)
        }
        if inStatus != noErr { lastError = "CoreMIDI refused an input port (error \(inStatus))." }
        MIDIOutputPortCreate(client, "MxMidiPRO Thru" as CFString, &outputPort)
        refresh()
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
        }
    }

    // MARK: Ports

    /// Rescans sources and destinations, connects to new sources, finds the spy and keeps the thru ports in step.
    func refresh() {
        guard client != 0 else { onChange?(); return }
        updateThruPorts()
        let ownIDs = Set(thruPorts.values.map { MIDIProps.uniqueID($0) })
        var seen = Set<MIDIUniqueID>()

        let spy = findSpySource()
        for i in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(i)
            if source == spy?.endpoint { continue }
            let info = MIDIProps.info(for: source, isSource: true)
            if info.transport == .own { continue }
            seen.insert(info.id)
            ports[info.id] = info
            if connected[info.id] != source { connect(source, id: info.id) }
        }
        for i in 0..<MIDIGetNumberOfDestinations() {
            let destination = MIDIGetDestination(i)
            var info = MIDIProps.info(for: destination, isSource: false)
            if ownIDs.contains(info.id) { info.transport = .own }
            seen.insert(info.id)
            ports[info.id] = info
        }
        for (id, info) in ports where !seen.contains(id) && info.online {
            ports[id]?.online = false
        }
        for id in connected.keys where !seen.contains(id) { connected[id] = nil }

        if spy?.endpoint != spySource {
            if spySource != 0 { MIDIPortDisconnectSource(inputPort, spySource) }
            spySource = 0
            spySourceID = nil
            if let spy,
               MIDIPortConnectSource(inputPort, spy.endpoint, Unmanaged.passUnretained(spyStream).toOpaque()) == noErr {
                spySource = spy.endpoint
                spySourceID = spy.id
            }
        }

        let spyLive = spySourceID != nil
        lock.withLock {
            shared.ownIDs = ownIDs
            shared.spyLive = spyLive
        }
        onChange?()
    }

    private func connect(_ source: MIDIEndpointRef, id: MIDIUniqueID) {
        let stream = inputStreams[id] ?? Stream(direction: .input, route: .direct, portID: id)
        inputStreams[id] = stream
        if let old = connected[id] { MIDIPortDisconnectSource(inputPort, old) }
        if MIDIPortConnectSource(inputPort, source, Unmanaged.passUnretained(stream).toOpaque()) == noErr {
            connected[id] = source
        }
    }

    /// The spy source's fixed unique ID, "MxSp" (MXSPY_SOURCE_UNIQUE_ID in SpyDriver/MxSpyCore.h).
    static let spySourceUniqueID: MIDIUniqueID = 0x4D78_5370

    /// The spy driver's private source, or the harness's stand-in. Private endpoints aren't in MIDIGetSource, so it is
    /// looked up by its fixed unique ID, then through the driver's device.
    private func findSpySource() -> (endpoint: MIDIEndpointRef, id: MIDIUniqueID)? {
        if let name = Self.spyTestSourceName {     // a test run uses its stand-in even when the real spy is loaded
            for i in 0..<MIDIGetNumberOfSources() {
                let source = MIDIGetSource(i)
                if MIDIProps.string(source, kMIDIPropertyDisplayName) == name
                    || MIDIProps.string(source, kMIDIPropertyName) == name {
                    return (source, MIDIProps.uniqueID(source))
                }
            }
            return nil
        }
        var object = MIDIObjectRef()
        var type = MIDIObjectType.other
        if MIDIObjectFindByUniqueID(Self.spySourceUniqueID, &object, &type) == noErr, object != 0,
           type == .source || type == .externalSource {
            let device = MIDIProps.device(of: object)
            let offline = (MIDIProps.integer(object, kMIDIPropertyOffline) ?? 0) != 0
                || (device.flatMap { MIDIProps.integer($0, kMIDIPropertyOffline) } ?? 0) != 0
            if !offline, device.flatMap({ MIDIProps.string($0, kMIDIPropertyDriverOwner) }) == Self.spyDriverID {
                return (object, Self.spySourceUniqueID)
            }
        }
        for i in 0..<MIDIGetNumberOfDevices() {
            let device = MIDIGetDevice(i)
            guard MIDIProps.string(device, kMIDIPropertyDriverOwner) == Self.spyDriverID,
                  (MIDIProps.integer(device, kMIDIPropertyOffline) ?? 0) == 0 else { continue }
            for e in 0..<MIDIDeviceGetNumberOfEntities(device) {
                let entity = MIDIDeviceGetEntity(device, e)
                guard MIDIEntityGetNumberOfSources(entity) > 0 else { continue }
                let source = MIDIEntityGetSource(entity, 0)
                if source != 0 { return (source, MIDIProps.uniqueID(source)) }
            }
        }
        return nil
    }

    // MARK: Thru ports

    private static let thruIDsKey = "ThruPortIDs"

    private func updateThruPorts() {
        guard thruEnabled else {
            for ref in thruPorts.values { MIDIEndpointDispose(ref) }
            thruPorts.removeAll()
            thruPortNames = []
            lock.withLock { shared.thruTargets = [:] }
            return
        }
        var targets: [MIDIUniqueID: MIDIEndpointRef] = [:]
        var names: [MIDIUniqueID: String] = [:]
        for i in 0..<MIDIGetNumberOfDestinations() {
            let destination = MIDIGetDestination(i)
            let info = MIDIProps.info(for: destination, isSource: false)
            guard info.transport.isHardware || (info.transport == .virtual && info.name == Self.thruTestTargetName)
            else { continue }
            targets[info.id] = destination
            names[info.id] = info.name
        }
        for (id, name) in names where thruPorts[id] == nil {
            makeThruPort(for: id, name: name)
        }
        thruPortNames = thruPorts.keys.compactMap { names[$0] ?? ports[$0]?.name }.sorted().map { "MxMidiPRO ▸ \($0)" }
        lock.withLock { shared.thruTargets = targets }
    }

    private func makeThruPort(for targetID: MIDIUniqueID, name: String) {
        let stream = thruStreams[targetID] ?? Stream(direction: .output, route: .thru, portID: targetID)
        thruStreams[targetID] = stream
        var ref = MIDIEndpointRef()
        let status = MIDIDestinationCreateWithProtocol(client, "MxMidiPRO ▸ \(name)" as CFString, ._1_0,
                                                       &ref) { [weak self] list, _ in
            self?.thruReceived(list, stream: stream)
        }
        guard status == noErr else { return }

        // Keep the port's unique ID from launch to launch so Logic Pro still finds it in a saved project.
        let defaults = UserDefaults.standard
        var saved = defaults.dictionary(forKey: Self.thruIDsKey) as? [String: Int] ?? [:]
        let key = String(targetID)
        if let id = saved[key], MIDIObjectSetIntegerProperty(ref, kMIDIPropertyUniqueID, Int32(truncatingIfNeeded: id)) == noErr {
            // reused
        } else {
            saved[key] = Int(MIDIProps.uniqueID(ref))
            defaults.set(saved, forKey: Self.thruIDsKey)
        }
        MIDIObjectSetStringProperty(ref, kMIDIPropertyManufacturer, "MxMidiPRO" as CFString)
        thruPorts[targetID] = ref
    }

    private func thruReceived(_ list: UnsafePointer<MIDIEventList>, stream: Stream) {
        let (target, spyLive) = lock.withLock { (shared.thruTargets[stream.portID], shared.spyLive) }
        if let target { MIDISendEventList(outputPort, target, list) }
        guard !spyLive else { return }   // the spy logs the copy just sent to the device
        var events: [MIDIEvent] = []
        collect(stream, list, now: HostClock.now, into: &events)
        enqueue(events)
    }

    // MARK: Receiving (CoreMIDI's thread)

    private func received(_ list: UnsafePointer<MIDIEventList>, refCon: UnsafeMutableRawPointer?) {
        guard let refCon else { return }
        let stream = Unmanaged<Stream>.fromOpaque(refCon).takeUnretainedValue()
        let now = HostClock.now
        var events: [MIDIEvent] = []
        if stream.route == .spy {
            spyReceived(list, now: now, into: &events)
        } else {
            collect(stream, list, now: now, into: &events)
        }
        enqueue(events)
    }

    private func collect(_ stream: Stream, _ list: UnsafePointer<MIDIEventList>, now: UInt64,
                         into events: inout [MIDIEvent]) {
        UMP.forEachPacket(in: list) { time, bytes in
            let when = time == 0 ? now : time
            for byte in bytes {
                stream.parser.feed(byte) { status, d1, d2, sysex in
                    events.append(MIDIEvent(hostTime: when, direction: stream.direction, route: stream.route,
                                            portID: stream.portID, status: status, data1: d1, data2: d2,
                                            sysex: sysex))
                }
            }
        }
    }

    private func spyReceived(_ list: UnsafePointer<MIDIEventList>, now: UInt64, into events: inout [MIDIEvent]) {
        var envelopes: [[UInt8]] = []
        UMP.forEachPacket(in: list) { _, bytes in
            for byte in bytes {
                spyStream.parser.feed(byte) { _, _, _, sysex in
                    if let sysex { envelopes.append(sysex) }
                }
            }
        }
        guard !envelopes.isEmpty else { return }
        let own = lock.withLock { shared.ownIDs }
        for envelope in envelopes {
            guard let message = SpyFeed.decode(envelope), !own.contains(message.destination) else { continue }
            let when = message.hostTime == 0 ? now : message.hostTime
            var parser = spyDestinationParsers[message.destination] ?? MIDIByteParser()
            for byte in message.bytes {
                parser.feed(byte) { status, d1, d2, sysex in
                    events.append(MIDIEvent(hostTime: when, direction: .output, route: .spy,
                                            portID: message.destination, status: status, data1: d1, data2: d2,
                                            sysex: sysex))
                }
            }
            spyDestinationParsers[message.destination] = parser
        }
    }

    private func enqueue(_ events: [MIDIEvent]) {
        guard !events.isEmpty else { return }
        lock.lock()
        if pending.count < Self.pendingLimit {
            pending.append(contentsOf: events)
        } else {
            droppedSinceDrain += events.count
        }
        lock.unlock()
    }

    /// Everything received since the last call, in arrival order, and how many were dropped because nobody drained.
    func drain() -> (events: [MIDIEvent], dropped: Int) {
        lock.lock()
        defer { lock.unlock() }
        let events = pending
        let dropped = droppedSinceDrain
        pending = []
        pending.reserveCapacity(min(events.count, 4096))
        droppedSinceDrain = 0
        return (events, dropped)
    }
}
