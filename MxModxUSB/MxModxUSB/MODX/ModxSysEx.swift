//
//  ModxSysEx.swift — MxModxUSB
//
//  The MODX's system-exclusive messages, as the MODX Data List (modx_en_dl_d0, pp. 186–191) defines them and as a
//  MODX7 on firmware 2.50 answered them over USB Port 1. Requests — Identity Request, Dump Request, Parameter
//  Request — make the MODX report; Parameter Change and Bulk Dump, sent only while changes are unlocked and only
//  for addresses and sizes the MODX itself uses (ModxParams, ModxBulkRules), change it.
//
//    Identity Request  F0 7E 00 06 01 F7        (device 00: the MODX ignores the usual 7F "all devices")
//    Identity Reply    F0 7E 7F 06 02 43 00 41 dd dd mm 00 00 7F F7   dd dd = 56/57/58 06 (MODX6/7/8),
//                                                                       mm = (version − 1.0) × 10
//    Dump Request      F0 43 2n 7F 1C 07 ah am al F7
//    Parameter Request F0 43 3n 7F 1C 07 ah am al F7
//    Bulk Dump         F0 43 0n 7F 1C bh bl 07 ah am al <data> cc F7   byte count = 4 + data;
//                      checksum: model ID + address + data + cc ≡ 0 (mod 128) — measured, the byte count isn't in it
//    Parameter Change  F0 43 1n 7F 1C 07 ah am al <data> F7             (the answer to a Parameter Request)
//
//  System (00 00 00) and Sequencer (00 05 00) can be dumped directly. Performance blocks come only wrapped between a
//  Bulk Header 0E mm nn and Footer 0F mm nn: 0E 53 00 is the current Performance's Common blocks, 0E 52 nn its Part
//  nn, 0E 51 00 the current Live Set bank, 0E 50 00 the user curves.
//

import Foundation

struct ModxAddress: Hashable, CustomStringConvertible {
    let high: UInt8
    let mid: UInt8
    let low: UInt8

    init(_ high: UInt8, _ mid: UInt8, _ low: UInt8) {
        self.high = high
        self.mid = mid
        self.low = low
    }

    var bytes: [UInt8] { [high, mid, low] }
    var description: String { String(format: "%02X %02X %02X", high, mid, low) }

    func with(low: UInt8) -> ModxAddress { ModxAddress(high, mid, low) }

    /// The footer that closes a bulk opened by this header (0E mm nn → 0F mm nn).
    var footer: ModxAddress { ModxAddress(0x0F, mid, low) }

    static let system = ModxAddress(0x00, 0x00, 0x00)
    static let sequencer = ModxAddress(0x00, 0x05, 0x00)
    static let performanceCommonBulk = ModxAddress(0x0E, 0x53, 0x00)
    static func performancePartBulk(_ part: Int) -> ModxAddress { ModxAddress(0x0E, 0x52, UInt8(part)) }
    static let liveSetBulk = ModxAddress(0x0E, 0x51, 0x00)
    static let curveBulk = ModxAddress(0x0E, 0x50, 0x00)
    static func microTuningName(_ table: Int) -> ModxAddress { ModxAddress(0x00, 0x50 | UInt8(table), 0x00) }
    static func microTuningTable(_ table: Int) -> ModxAddress { ModxAddress(0x00, 0x30 | UInt8(table), 0x00) }

    static let common = ModxAddress(0x30, 0x40, 0x00)
    static func part(_ part: Int) -> ModxAddress { ModxAddress(0x31, UInt8(part), 0x00) }
    static func element(_ element: Int, part: Int) -> ModxAddress { ModxAddress(0x41, UInt8(element << 4 | part), 0x00) }
    static func fmCommon(part: Int) -> ModxAddress { ModxAddress(0x48, UInt8(part), 0x00) }
    static func drumKey(_ key: Int, part: Int) -> ModxAddress { ModxAddress(0x50 | UInt8(part), UInt8(key), 0x00) }
}

/// One block of a bulk dump: its address and data.
struct ModxBlock: Equatable {
    let address: ModxAddress
    let data: [UInt8]
    let checksumOK: Bool

    subscript(offset: Int) -> UInt8 { offset < data.count ? data[offset] : 0 }

    /// ASCII text of `length` bytes from `offset`, trailing blanks and NULs trimmed.
    func text(_ offset: Int, _ length: Int) -> String { ModxSysEx.text(Array(data.dropFirst(offset).prefix(length))) }

    /// A 2-byte value whose bytes each hold 7 bits (bit13-7, bit6-0).
    func value14(_ offset: Int) -> Int { Int(self[offset]) << 7 | Int(self[offset + 1]) }
}

struct ModxIdentity: Equatable {
    let family: UInt8
    let member: UInt8
    let versionCode: UInt8

    var model: String {
        switch family {
        case 0x56: "MODX6"
        case 0x57: "MODX7"
        case 0x58: "MODX8"
        default: String(format: "MODX (family %02X %02X)", family, member)
        }
    }

    /// Keys on the keyboard: 61, 76 or 88.
    var keyCount: Int {
        switch family {
        case 0x56: 61
        case 0x58: 88
        default: 76
        }
    }

    var firmware: String { String(format: "%.2f", 1.0 + Double(versionCode) / 10) }
}

enum ModxSysEx {
    static let modelID: UInt8 = 0x07

    static let identityRequest: [UInt8] = [0xF0, 0x7E, 0x00, 0x06, 0x01, 0xF7]

    static func dumpRequest(_ address: ModxAddress) -> [UInt8] {
        [0xF0, 0x43, 0x20, 0x7F, 0x1C, modelID] + address.bytes + [0xF7]
    }

    static func parameterRequest(_ address: ModxAddress) -> [UInt8] {
        [0xF0, 0x43, 0x30, 0x7F, 0x1C, modelID] + address.bytes + [0xF7]
    }

    /// F0 43 1n 7F 1C 07 ah am al <data> F7 — sets one setting (the MODX sends nothing back).
    static func parameterChange(_ address: ModxAddress, data: [UInt8]) -> [UInt8] {
        [0xF0, 0x43, 0x10, 0x7F, 0x1C, modelID] + address.bytes + data + [0xF7]
    }

    /// F0 43 0n 7F 1C bh bl 07 ah am al <data> cc F7 — one block, exactly as the MODX sends its own: the byte count
    /// is 4 + the data, the checksum makes model ID + address + data + checksum ≡ 0 (mod 128).
    static func bulkDump(_ address: ModxAddress, data: [UInt8]) -> [UInt8] {
        let count = 4 + data.count
        let body = [modelID] + address.bytes + data
        let sum = body.reduce(0) { $0 + Int($1) }
        let checksum = UInt8((128 - sum & 0x7F) & 0x7F)
        return [0xF0, 0x43, 0x00, 0x7F, 0x1C, UInt8(count >> 7 & 0x7F), UInt8(count & 0x7F)] + body + [checksum, 0xF7]
    }

    enum Reply: Equatable {
        case identity(ModxIdentity)
        case parameter(ModxAddress, [UInt8])
        case block(ModxBlock)
    }

    static func parse(_ m: [UInt8]) -> Reply? {
        guard m.count >= 6, m.first == 0xF0, m.last == 0xF7 else { return nil }
        if m.count >= 15, m[1] == 0x7E, m[3] == 0x06, m[4] == 0x02, m[5] == 0x43 {
            return .identity(ModxIdentity(family: m[8], member: m[9], versionCode: m[10]))
        }
        guard m.count >= 11, m[1] == 0x43, m[3] == 0x7F, m[4] == 0x1C else { return nil }
        switch m[2] & 0xF0 {
        case 0x10:
            guard m[5] == modelID else { return nil }
            return .parameter(ModxAddress(m[6], m[7], m[8]), Array(m[9..<(m.count - 1)]))
        case 0x00:
            guard m.count >= 13, m[7] == modelID else { return nil }
            let address = ModxAddress(m[8], m[9], m[10])
            let data = Array(m[11..<(m.count - 2)])
            let sum = m[7..<(m.count - 1)].reduce(0) { $0 + Int($1) }
            return .block(ModxBlock(address: address, data: data, checksumOK: sum & 0x7F == 0))
        default:
            return nil
        }
    }

    static func text(_ bytes: [UInt8]) -> String {
        let scalars = bytes.map { $0 >= 0x20 && $0 < 0x7F ? Character(UnicodeScalar($0)) : " " }
        return String(scalars).trimmingCharacters(in: .whitespaces)
    }
}

/// The blocks MxModxUSB may send back to the MODX: only those the MODX itself dumps, at their own sizes (MODX Data
/// List, Bulk Dump Block, p. 192), and the Bulk Header/Footer pairs it reads with.
enum ModxBulkRules {
    static func isAllowed(_ a: ModxAddress, size: Int) -> Bool {
        switch a.high {
        case 0x0E, 0x0F:   // header / footer: no data
            return size == 0 && ((a.mid == 0x53 && a.low == 0) || (a.mid == 0x52 && a.low < 16) || (a.mid == 0x51 && a.low == 0)
                                 || (a.mid == 0x50 && a.low == 0))
        case 0x00:
            switch (a.mid, a.low) {
            case (0x00, 0x00): return size == 60
            case (0x05, 0x00): return size == 21 || size == 22   // the Data List says 22; a MODX7 on 2.50 dumps 21
            case (0x30...0x37, 0x00): return size == 24
            case (0x50...0x57, 0x00): return size == 20
            default: return false
            }
        case 0x01: return a.mid < 32 && a.low == 0 && size == 37
        case 0x02: return a.mid == 0 && a.low == 0 && size == 20
        case 0x03: return a.mid < 16 && a.low == 0 && size == 20
        case 0x04, 0x05: return a.low == 0 && (size == 26 || size == 30)   // the Data List says 26; a MODX7 on 2.50 dumps 30
        case 0x30: return a.low == 0 && a.mid <= 0x6F && size > 0 && size <= 128
        case 0x31...0x38, 0x41, 0x42, 0x48, 0x49, 0x50...0x5F: return a.low == 0 && size > 0 && size <= 128
        default: return false
        }
    }

    /// Which Part a Performance Part block belongs to (its address carries the Part number), nil for Common blocks.
    static func part(of a: ModxAddress) -> Int? {
        switch a.high {
        case 0x31...0x36, 0x41, 0x42, 0x49: Int(a.mid & 0x0F)
        case 0x37, 0x38, 0x48: Int(a.mid & 0x0F)
        case 0x50...0x5F: Int(a.high & 0x0F)
        default: nil
        }
    }
}
