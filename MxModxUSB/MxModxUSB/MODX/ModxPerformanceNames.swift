//
//  ModxPerformanceNames.swift — MxModxUSB
//
//  The names of the Performances Live Set slots recall. The MODX shows a slot by its Performance's name ("Ocean
//  Pad"), not by the slot's own stored name ("SYN PAD"), but over USB it reports only the current Performance's name.
//  So: preset Performances by number from the Data List's Performance List (ModxPresetPerformances), and User and
//  Library Performances as the app saw them when they were chosen on the MODX.
//
//  Performance numbers: Bank Select MSB 63 (one Part) or 64 (a whole Performance); LSB 0–31 Preset 1–32, 32–36
//  User 1–5, 40–79 Library 1–40; Program 0–127. Preset Performance n of the list is LSB (n − 1) / 128, Program
//  (n − 1) % 128 — checked against all 256 slots of the preset Live Set bank on a MODX7 (firmware 2.50).
//

import Foundation

struct ModxPerformanceNames: Equatable {
    enum Source: Equatable {
        /// From the Data List's list of preset Performances.
        case preset
        /// Read from the MODX when the Performance was chosen on it (the name it had then).
        case seen
    }

    /// Names seen on the MODX, by "LSB.number" (number 1–128).
    private(set) var seen: [String: String] = [:]

    init(seen: [String: String] = [:]) { self.seen = seen }

    static func key(lsb: UInt8, number: Int) -> String { "\(lsb).\(number)" }

    static func preset(lsb: UInt8, number: Int) -> String? {
        guard lsb < 32, (1...128).contains(number) else { return nil }
        let index = Int(lsb) * 128 + number - 1
        return index < ModxPresetPerformances.names.count ? ModxPresetPerformances.names[index] : nil
    }

    /// The Performance at a bank and number: as last seen on the MODX, else the preset list's name.
    func name(lsb: UInt8, number: Int) -> (name: String, source: Source)? {
        if let name = seen[Self.key(lsb: lsb, number: number)] { return (name, .seen) }
        if let name = Self.preset(lsb: lsb, number: number) { return (name, .preset) }
        return nil
    }

    func name(of slot: ModxLiveSlot) -> (name: String, source: Source)? {
        guard slot.bankMSB == 63 || slot.bankMSB == 64 else { return nil }
        return name(lsb: slot.bankLSB, number: slot.number)
    }

    /// Records the name of the Performance just chosen on the MODX; true if it was new or had changed.
    @discardableResult
    mutating func learn(lsb: UInt8, number: Int, name: String) -> Bool {
        guard (1...128).contains(number), !name.isEmpty else { return false }
        let key = Self.key(lsb: lsb, number: number)
        // A preset's name is already known; keep only what differs from the list (or isn't in it).
        if Self.preset(lsb: lsb, number: number) == name {
            return seen.removeValue(forKey: key) != nil
        }
        guard seen[key] != name else { return false }
        seen[key] = name
        return true
    }
}
