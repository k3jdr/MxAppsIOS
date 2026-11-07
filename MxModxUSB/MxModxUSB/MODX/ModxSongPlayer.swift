//
//  ModxSongPlayer.swift — MxModxUSB
//
//  Plays a song on the MODX: its channel messages go to one destination only — the MODX's Port 1, the instrument —
//  each with a CoreMIDI timestamp a little ahead of time (up to 120 ms), from a timer on a queue of its own, so the
//  window can be busy without the music stumbling. Muting or soloing while it plays takes effect at once (the notes
//  of a silenced track are released). Stopping unschedules what was sent ahead and sends Note Off for every note
//  still sounding, then All Notes Off and Sustain off on each channel the song used. Starting mid-song first sends
//  each track's latest controllers and pitch bend, so volume, pan and sustain are right.
//

import CoreMIDI
import Foundation

final class ModxSongPlayer: @unchecked Sendable {
    private let lock = NSLock()
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private let queue = DispatchQueue(label: "MxModxUSB.song", qos: .userInteractive)
    private var timer: DispatchSourceTimer?

    private var destination: MIDIEndpointRef = 0
    private var events: [MIDISong.PlayEvent] = []
    private var times: [Double] = []
    private var next = 0
    private var startHost: UInt64 = 0
    private var startSeconds = 0.0
    private var audible: Set<UUID> = []
    /// Notes sent and not yet released: track → status/channel and key.
    private var sounding: [UUID: Set<[UInt8]>] = [:]
    private var channels: Set<UInt8> = []
    private var playing = false
    private var finished: (() -> Void)?

    private static let lookahead = 0.12
    private static let ticksPerSecond: Double = {
        var base = mach_timebase_info_data_t()
        mach_timebase_info(&base)
        return 1e9 * Double(base.denom) / Double(base.numer)
    }()

    init() {
        MIDIClientCreateWithBlock("MxModxUSB Song" as CFString, &client, nil)
        MIDIOutputPortCreate(client, "MxModxUSB Song Out" as CFString, &port)
    }

    var isPlaying: Bool { lock.withLock { playing } }

    /// The song position now, in seconds, while playing.
    var position: Double? {
        lock.withLock { playing ? startSeconds + (Double(mach_absolute_time()) - Double(startHost)) / Self.ticksPerSecond : nil }
    }

    /// Starts at `seconds` into the song. `times[i]` is when `events[i]` falls, in seconds from the song's start.
    func play(_ events: [MIDISong.PlayEvent], times: [Double], from seconds: Double, to destination: MIDIEndpointRef,
              audible: Set<UUID>, chase: [MIDISong.PlayEvent], finished: @escaping () -> Void) {
        stop()
        lock.withLock {
            self.destination = destination
            self.events = events
            self.times = times
            self.audible = audible
            self.finished = finished
            next = times.firstIndex { $0 >= seconds } ?? times.count
            channels = Set(events.map { $0.bytes[0] & 0x0F })
            sounding = [:]
            startHost = mach_absolute_time() + UInt64(0.03 * Self.ticksPerSecond)
            startSeconds = seconds
            playing = true
            for e in chase where audible.contains(e.track) { sendLocked(e.bytes, at: 0) }
        }
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    /// The song changed while playing: carry on with the new events from where playback is.
    func replace(_ events: [MIDISong.PlayEvent], times: [Double]) {
        lock.withLock {
            guard playing else { return }
            let sentUpTo = next > 0 && next <= self.times.count ? self.times[next - 1] : startSeconds
            self.events = events
            self.times = times
            next = times.firstIndex { $0 > sentUpTo } ?? times.count
            channels.formUnion(events.map { $0.bytes[0] & 0x0F })
        }
    }

    func setAudible(_ ids: Set<UUID>) {
        lock.withLock {
            let silenced = audible.subtracting(ids)
            audible = ids
            for track in silenced { releaseLocked(track) }
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        lock.withLock {
            guard playing else { return }
            playing = false
            if destination != 0 { MIDIFlushOutput(destination) }
            for track in Array(sounding.keys) { releaseLocked(track) }
            for ch in channels {
                sendLocked([0xB0 | ch, 64, 0], at: 0)    // sustain off
                sendLocked([0xB0 | ch, 123, 0], at: 0)   // all notes off
            }
        }
    }

    /// A message now (the mixer, Panic), to the MODX only.
    func send(_ bytes: [UInt8], to destination: MIDIEndpointRef) {
        guard destination != 0 else { return }
        lock.withLock { sendLocked(bytes, at: 0, to: destination) }
    }

    /// A short note now (clicking in the piano roll).
    func preview(channel: Int, key: Int, velocity: Int, to destination: MIDIEndpointRef) {
        guard destination != 0 else { return }
        lock.withLock {
            let ch = UInt8(channel & 0x0F)
            sendLocked([0x90 | ch, UInt8(clamping: key), UInt8(clamping: max(1, velocity))], at: 0, to: destination)
            sendLocked([0x80 | ch, UInt8(clamping: key), 64], at: mach_absolute_time() + UInt64(0.35 * Self.ticksPerSecond), to: destination)
        }
    }

    // MARK: On the player's queue

    private func tick() {
        var done: (() -> Void)?
        lock.withLock {
            guard playing else { return }
            let now = startSeconds + (Double(mach_absolute_time()) - Double(startHost)) / Self.ticksPerSecond
            while next < events.count, times[next] <= now + Self.lookahead {
                let e = events[next]
                let at = startHost + UInt64(max(0, times[next] - startSeconds) * Self.ticksPerSecond)
                let key = [e.bytes[0] & 0x0F, e.bytes.count > 1 ? e.bytes[1] : 0]
                if e.isNoteOn {
                    if audible.contains(e.track) {
                        sendLocked(e.bytes, at: at)
                        sounding[e.track, default: []].insert(key)
                    }
                } else if e.bytes[0] & 0xF0 == 0x80 {
                    if sounding[e.track]?.remove(key) != nil { sendLocked(e.bytes, at: at) }
                } else if audible.contains(e.track) {
                    sendLocked(e.bytes, at: at)
                }
                next += 1
            }
            if next >= events.count, now > (times.last ?? 0) + 0.3 {
                done = finished
            }
        }
        if let done { DispatchQueue.main.async { done() } }
    }

    /// Note Off for a track's sounding notes, now.
    private func releaseLocked(_ track: UUID) {
        for key in sounding[track] ?? [] { sendLocked([0x80 | key[0], key[1], 64], at: 0) }
        sounding[track] = nil
    }

    private func sendLocked(_ bytes: [UInt8], at time: MIDITimeStamp, to target: MIDIEndpointRef? = nil) {
        let destination = target ?? self.destination
        guard destination != 0 else { return }
        var words = UMP.messageWords(bytes)
        let size = 64 + words.count * 4
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: MIDIEventList.self, capacity: 1)
        let packet = MIDIEventListInit(list, ._1_0)
        MIDIEventListAdd(list, size, packet, time, words.count, &words)
        MIDISendEventList(port, destination, list)
    }
}
