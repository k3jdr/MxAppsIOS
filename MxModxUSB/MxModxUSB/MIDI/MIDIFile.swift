//
//  MIDIFile.swift — MxModxUSB
//
//  Standard MIDI Files (.mid): reading formats 0 and 1 (2 is read as 1), writing format 1. A file is a header chunk
//  (MThd: format, track count, ticks per quarter note) and track chunks (MTrk) of events, each after a variable-length
//  delta time: channel messages (with running status), meta events (FF type length data: tempo, time signature, track
//  name, end of track …) and SysEx (F0 / F7 length data). Events are kept with absolute ticks.
//

import Foundation

struct SMF: Equatable {
    struct Event: Equatable {
        var tick: Int
        /// 0x80–0xEF a channel message, 0xFF a meta event, 0xF0 / 0xF7 SysEx.
        var status: UInt8
        /// Channel message: its data bytes. Meta: the type byte, then the data. SysEx: the bytes after the length.
        var data: [UInt8]

        var isMeta: Bool { status == 0xFF }
        var metaType: UInt8? { isMeta ? data.first : nil }
        var metaData: [UInt8] { isMeta ? Array(data.dropFirst()) : [] }
        var channel: Int? { status < 0xF0 ? Int(status & 0x0F) : nil }
        var kind: UInt8 { status < 0xF0 ? status & 0xF0 : status }

        static func meta(_ tick: Int, _ type: UInt8, _ bytes: [UInt8]) -> Event { Event(tick: tick, status: 0xFF, data: [type] + bytes) }
    }

    enum ParseError: LocalizedError {
        case notMIDI, unsupportedTiming, truncated(String)
        var errorDescription: String? {
            switch self {
            case .notMIDI: "This isn't a Standard MIDI File (no MThd header)."
            case .unsupportedTiming: "The file counts time in SMPTE frames; only ticks per quarter note are supported."
            case .truncated(let what): "The file ends in the middle of \(what)."
            }
        }
    }

    var format = 1
    var division = 480
    var tracks: [[Event]] = []

    // MARK: Reading

    static func parse(_ data: Data) throws -> SMF {
        let bytes = [UInt8](data)
        var r = Reader(bytes: bytes)
        guard r.remaining >= 14, Array(r.take(4)) == Array("MThd".utf8) else { throw ParseError.notMIDI }
        let headerLength = Int(try r.u32("the header"))
        let format = Int(try r.u16("the header")), count = Int(try r.u16("the header")), division = Int(try r.u16("the header"))
        if headerLength > 6 { _ = r.take(headerLength - 6) }
        guard division & 0x8000 == 0, division > 0 else { throw ParseError.unsupportedTiming }
        var smf = SMF(format: format, division: division, tracks: [])
        while smf.tracks.count < count, r.remaining >= 8 {
            let id = Array(r.take(4))
            let length = Int(try r.u32("a track header"))
            guard r.remaining >= length else { throw ParseError.truncated("track \(smf.tracks.count + 1)") }
            let chunk = Array(r.take(length))
            if id == Array("MTrk".utf8) { smf.tracks.append(try parseTrack(chunk, number: smf.tracks.count + 1)) }
        }
        return smf
    }

    private static func parseTrack(_ bytes: [UInt8], number: Int) throws -> [Event] {
        var r = Reader(bytes: bytes)
        var events: [Event] = []
        var tick = 0
        var running: UInt8 = 0
        let what = "track \(number)"
        while r.remaining > 0 {
            tick += try r.vlq(what)
            guard let first = r.peek() else { throw ParseError.truncated(what) }
            var status = first
            if first < 0x80 {
                guard running >= 0x80 else { throw ParseError.truncated("\(what) (data without a status)") }
                status = running
            } else {
                _ = r.take(1)
            }
            switch status {
            case 0xFF:
                guard let type = r.take(1).first else { throw ParseError.truncated(what) }
                let length = try r.vlq(what)
                guard r.remaining >= length else { throw ParseError.truncated(what) }
                events.append(Event(tick: tick, status: 0xFF, data: [type] + r.take(length)))
                if type == 0x2F { return events }   // End of Track
            case 0xF0, 0xF7:
                let length = try r.vlq(what)
                guard r.remaining >= length else { throw ParseError.truncated(what) }
                events.append(Event(tick: tick, status: status, data: Array(r.take(length))))
                running = 0
            default:
                guard status >= 0x80, status < 0xF0 else { throw ParseError.truncated("\(what) (status \(String(format: "%02X", status)))") }
                running = status
                let count = (status & 0xF0 == 0xC0 || status & 0xF0 == 0xD0) ? 1 : 2
                guard r.remaining >= count else { throw ParseError.truncated(what) }
                events.append(Event(tick: tick, status: status, data: Array(r.take(count))))
            }
        }
        return events
    }

    private struct Reader {
        let bytes: [UInt8]
        var at = 0
        var remaining: Int { bytes.count - at }
        func peek() -> UInt8? { at < bytes.count ? bytes[at] : nil }
        mutating func take(_ n: Int) -> ArraySlice<UInt8> {
            let end = min(bytes.count, at + n)
            defer { at = end }
            return bytes[at..<end]
        }
        mutating func u16(_ what: String) throws -> UInt16 {
            guard remaining >= 2 else { throw ParseError.truncated(what) }
            let b = take(2)
            return UInt16(b[b.startIndex]) << 8 | UInt16(b[b.startIndex + 1])
        }
        mutating func u32(_ what: String) throws -> UInt32 {
            guard remaining >= 4 else { throw ParseError.truncated(what) }
            return take(4).reduce(0) { $0 << 8 | UInt32($1) }
        }
        mutating func vlq(_ what: String) throws -> Int {
            var value = 0
            for _ in 0..<4 {
                guard let b = take(1).first else { throw ParseError.truncated(what) }
                value = value << 7 | Int(b & 0x7F)
                if b & 0x80 == 0 { return value }
            }
            throw ParseError.truncated("\(what) (a delta time longer than 4 bytes)")
        }
    }

    // MARK: Writing

    /// The file as bytes: format 1 (0 if there's a single track), each track ending with End of Track.
    func encode() -> Data {
        var out = Array("MThd".utf8) + Self.be32(6) + Self.be16(UInt16(tracks.count == 1 ? 0 : 1))
            + Self.be16(UInt16(tracks.count)) + Self.be16(UInt16(division))
        for track in tracks {
            var body: [UInt8] = []
            var last = 0
            let sorted = track.enumerated().sorted { ($0.element.tick, $0.offset) < ($1.element.tick, $1.offset) }.map(\.element)
                .filter { $0.metaType != 0x2F }
            for e in sorted {
                body += Self.vlq(max(0, e.tick - last))
                last = max(last, e.tick)
                switch e.status {
                case 0xFF: body += [0xFF, e.data.first ?? 0] + Self.vlq(max(0, e.data.count - 1)) + e.data.dropFirst()
                case 0xF0, 0xF7: body += [e.status] + Self.vlq(e.data.count) + e.data
                default: body += [e.status] + e.data
                }
            }
            let end = max(last, track.last { $0.metaType == 0x2F }?.tick ?? last)
            body += Self.vlq(end - last) + [0xFF, 0x2F, 0x00]
            out += Array("MTrk".utf8) + Self.be32(UInt32(body.count)) + body
        }
        return Data(out)
    }

    static func vlq(_ value: Int) -> [UInt8] {
        var v = max(0, value)
        var out = [UInt8(v & 0x7F)]
        v >>= 7
        while v > 0 {
            out.insert(UInt8(v & 0x7F) | 0x80, at: 0)
            v >>= 7
        }
        return out
    }

    private static func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
    private static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
}
