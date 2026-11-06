//
//  MIDIBytes.swift — MxModxUSB
//
//  MIDI 1.0 bytes in and out of CoreMIDI's Universal MIDI Packets, and a byte parser (running status, realtime
//  bytes inside messages, system exclusive across packets). The parser and the UMP reader are MxMidiPRO's
//  (MxMidiPRO/MxMidiPRO/MIDI/MIDIParsing.swift).
//

import CoreMIDI
import Foundation

struct MIDIByteParser {
    private var status: UInt8 = 0
    private var expected = 0
    private var count = 0
    private var data1: UInt8 = 0
    private var sysex: [UInt8]?

    static let maximumSysexLength = 1 << 20

    /// Feeds one byte; `emit` gets (status, data1, data2, sysex) for each complete message.
    mutating func feed(_ byte: UInt8, _ emit: (UInt8, UInt8, UInt8, [UInt8]?) -> Void) {
        if byte >= 0xF8 { emit(byte, 0, 0, nil); return }
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
            if let pending = sysex { emit(0xF0, 0, 0, pending); sysex = nil }
            status = byte
            count = 0
            switch byte {
            case 0xF1, 0xF3, 0xC0...0xDF: expected = 1
            case 0xF2, 0x80...0xBF, 0xE0...0xEF: expected = 2
            default: emit(byte, 0, 0, nil); status = 0
            }
            return
        }
        if sysex != nil {
            if sysex!.count < Self.maximumSysexLength { sysex!.append(byte) }
            return
        }
        guard status != 0 else { return }
        if count == 0 { data1 = byte }
        count += 1
        if count == expected {
            emit(status, data1, expected == 2 ? byte : 0, nil)
            count = 0
            if status >= 0xF0 { status = 0 }
        }
    }

    static func length(ofStatus status: UInt8) -> Int {
        switch status {
        case 0x80...0xBF, 0xE0...0xEF, 0xF2: return 3
        case 0xC0...0xDF, 0xF1, 0xF3: return 2
        default: return 1
        }
    }
}

enum UMP {
    private static let wordsOffset = MemoryLayout<MIDIEventPacket>.offset(of: \MIDIEventPacket.words) ?? 12

    static func size(ofType type: UInt32) -> Int {
        switch type {
        case 0x0, 0x1, 0x2, 0x6, 0x7: 1
        case 0x3, 0x4, 0x8, 0x9, 0xA: 2
        case 0xB, 0xC: 3
        default: 4
        }
    }

    /// Each packet's time stamp (host time, 0 for "now") and MIDI 1.0 bytes (MIDI 1.0 protocol).
    static func forEachPacket(in list: UnsafePointer<MIDIEventList>, _ body: (UInt64, UnsafeBufferPointer<UInt8>) -> Void) {
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
                    let length = MIDIByteParser.length(ofStatus: status)
                    buffer.append(status)
                    if length > 1 { buffer.append(UInt8((w0 >> 8) & 0x7F)) }
                    if length > 2 { buffer.append(UInt8(w0 & 0x7F)) }
                case 0x2:
                    let status = UInt8((w0 >> 16) & 0xFF)
                    buffer.append(status)
                    buffer.append(UInt8((w0 >> 8) & 0x7F))
                    if MIDIByteParser.length(ofStatus: status) == 3 { buffer.append(UInt8(w0 & 0x7F)) }
                case 0x3:
                    let w1 = words[i + 1]
                    let form = (w0 >> 20) & 0xF
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

    /// The Universal MIDI Packet words for one system-exclusive message (F0 … F7 included or not): 7-bit SysEx
    /// packets of up to six bytes, marked complete, start, continue and end.
    static func sysexWords(_ message: [UInt8]) -> [UInt32] {
        var payload = message
        if payload.first == 0xF0 { payload.removeFirst() }
        if payload.last == 0xF7 { payload.removeLast() }
        var words: [UInt32] = []
        let chunks = stride(from: 0, to: max(payload.count, 1), by: 6).map {
            Array(payload[$0..<min($0 + 6, payload.count)])
        }
        for (index, chunk) in chunks.enumerated() {
            let form: UInt32 = chunks.count == 1 ? 0 : index == 0 ? 1 : index == chunks.count - 1 ? 3 : 2
            var bytes = chunk.map(UInt32.init)
            while bytes.count < 6 { bytes.append(0) }
            words.append(0x3000_0000 | form << 20 | UInt32(chunk.count) << 16 | bytes[0] << 8 | bytes[1])
            words.append(bytes[2] << 24 | bytes[3] << 16 | bytes[4] << 8 | bytes[5])
        }
        return words
    }

    /// The words for a MIDI 1.0 channel voice or system message.
    static func messageWords(_ bytes: [UInt8]) -> [UInt32] {
        guard let status = bytes.first else { return [] }
        let d1 = bytes.count > 1 ? UInt32(bytes[1]) : 0
        let d2 = bytes.count > 2 ? UInt32(bytes[2]) : 0
        let type: UInt32 = status >= 0xF0 ? 0x1 : 0x2
        return [type << 28 | UInt32(status) << 16 | d1 << 8 | d2]
    }
}
