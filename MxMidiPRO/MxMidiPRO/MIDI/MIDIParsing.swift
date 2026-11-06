//
//  MIDIParsing.swift — MxMidiPRO
//
//  Everything arrives as MIDI 1.0 bytes in the end: the input port's Universal MIDI Packets are turned back into
//  bytes, the spy's system-exclusive envelopes are unpacked into the bytes Logic Pro sent, and one parser per stream
//  splits bytes into messages (running status, realtime bytes inside other messages, system exclusive across packets).
//

import CoreMIDI
import Foundation

struct MIDIByteParser {
    private var status: UInt8 = 0
    private var expected = 0
    private var count = 0
    private var data1: UInt8 = 0
    private var sysex: [UInt8]?

    /// A runaway system exclusive (no F7) is cut off here so one broken device can't fill memory.
    static let maximumSysexLength = 1 << 20

    /// Feeds one byte; `emit` gets (status, data1, data2, sysex) for each complete message.
    mutating func feed(_ byte: UInt8, _ emit: (UInt8, UInt8, UInt8, [UInt8]?) -> Void) {
        if byte >= 0xF8 {                       // realtime: may sit anywhere, changes nothing
            emit(byte, 0, 0, nil)
            return
        }
        if byte == 0xF0 {
            if let pending = sysex { emit(0xF0, 0, 0, pending) }
            sysex = [0xF0]
            status = 0
            return
        }
        if byte == 0xF7 {
            if sysex != nil {
                sysex!.append(0xF7)
                emit(0xF0, 0, 0, sysex)
                sysex = nil
            }
            return
        }
        if byte >= 0x80 {
            if let pending = sysex {            // a status byte ends an unterminated system exclusive
                emit(0xF0, 0, 0, pending)
                sysex = nil
            }
            status = byte
            count = 0
            switch byte {
            case 0xF1, 0xF3, 0xC0...0xDF: expected = 1
            case 0xF2, 0x80...0xBF, 0xE0...0xEF: expected = 2
            default:                            // F4, F5 (undefined), F6 tune request
                emit(byte, 0, 0, nil)
                status = 0
            }
            return
        }
        if sysex != nil {
            if sysex!.count < Self.maximumSysexLength { sysex!.append(byte) }
            return
        }
        guard status != 0 else { return }       // data with no status to run on
        if count == 0 { data1 = byte }
        count += 1
        if count == expected {
            emit(status, data1, expected == 2 ? byte : 0, nil)
            count = 0
            if status >= 0xF0 { status = 0 }    // system common messages don't set running status
        }
    }
}

enum UMP {
    private static let wordsOffset = MemoryLayout<MIDIEventPacket>.offset(of: \MIDIEventPacket.words) ?? 12

    /// Words in a Universal MIDI Packet of message type `type`.
    static func size(ofType type: UInt32) -> Int {
        switch type {
        case 0x0, 0x1, 0x2, 0x6, 0x7: 1
        case 0x3, 0x4, 0x8, 0x9, 0xA: 2
        case 0xB, 0xC: 3
        default: 4
        }
    }

    /// Calls `body` with each packet's time stamp and its MIDI 1.0 bytes (MIDI 1.0 protocol: system, channel voice
    /// and 7-bit system exclusive packets; utility packets are dropped).
    static func forEachPacket(in list: UnsafePointer<MIDIEventList>,
                              _ body: (_ time: UInt64, _ bytes: UnsafeBufferPointer<UInt8>) -> Void) {
        var buffer: [UInt8] = []
        buffer.reserveCapacity(256)
        for packet in list.unsafeSequence() {
            buffer.removeAll(keepingCapacity: true)
            let count = Int(packet.pointee.wordCount)
            let words = UnsafeRawPointer(packet).advanced(by: wordsOffset).assumingMemoryBound(to: UInt32.self)
            var i = 0
            while i < count {
                let w0 = words[i]
                let type = w0 >> 28
                let size = size(ofType: type)
                guard i + size <= count else { break }
                switch type {
                case 0x1:
                    let status = UInt8((w0 >> 16) & 0xFF)
                    let length = MIDIEvent.length(ofStatus: status)
                    buffer.append(status)
                    if length > 1 { buffer.append(UInt8((w0 >> 8) & 0x7F)) }
                    if length > 2 { buffer.append(UInt8(w0 & 0x7F)) }
                case 0x2:
                    let status = UInt8((w0 >> 16) & 0xFF)
                    buffer.append(status)
                    buffer.append(UInt8((w0 >> 8) & 0x7F))
                    if MIDIEvent.length(ofStatus: status) == 3 { buffer.append(UInt8(w0 & 0x7F)) }
                case 0x3:
                    let w1 = words[i + 1]
                    let form = (w0 >> 20) & 0xF          // 0 complete, 1 start, 2 continue, 3 end
                    let n = min(Int((w0 >> 16) & 0xF), 6)
                    if form == 0 || form == 1 { buffer.append(0xF0) }
                    for k in 0..<n {
                        let byte: UInt32 = switch k {
                        case 0: w0 >> 8
                        case 1: w0
                        case 2: w1 >> 24
                        case 3: w1 >> 16
                        case 4: w1 >> 8
                        default: w1
                        }
                        buffer.append(UInt8(byte & 0x7F))
                    }
                    if form == 0 || form == 3 { buffer.append(0xF7) }
                default:
                    break
                }
                i += size
            }
            buffer.withUnsafeBufferPointer { body(packet.pointee.timeStamp, $0) }
        }
    }
}

/// The spy driver's envelope (SpyDriver/MxSpyCore.h): F0 7D 4D 78 01, the destination's unique ID, the host time,
/// then the original bytes 7-in-8 packed, F7.
enum SpyFeed {
    struct Message {
        let destination: MIDIUniqueID
        let hostTime: UInt64
        let bytes: [UInt8]
    }

    static let headerLength = 20

    static func decode(_ sysex: [UInt8]) -> Message? {
        guard sysex.count > headerLength, sysex[0] == 0xF0, sysex[1] == 0x7D, sysex[2] == 0x4D, sysex[3] == 0x78,
              sysex[4] == 0x01, sysex[sysex.count - 1] == 0xF7 else { return nil }
        var id: UInt32 = 0
        for k in 0..<5 { id |= UInt32(sysex[5 + k] & 0x7F) << UInt32(7 * k) }
        var time: UInt64 = 0
        for k in 0..<10 { time |= UInt64(sysex[10 + k] & 0x7F) << UInt64(7 * k) }

        var bytes: [UInt8] = []
        let end = sysex.count - 1
        bytes.reserveCapacity((end - headerLength) * 7 / 8 + 1)
        var i = headerLength
        while i < end {
            let high = sysex[i]
            i += 1
            var j = 0
            while j < 7 && i < end {
                bytes.append(sysex[i] | ((high >> UInt8(j)) & 1) << 7)
                i += 1
                j += 1
            }
        }
        return Message(destination: MIDIUniqueID(bitPattern: id), hostTime: time, bytes: bytes)
    }
}
