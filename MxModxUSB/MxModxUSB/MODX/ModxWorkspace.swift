//
//  ModxWorkspace.swift — MxModxUSB
//
//  A MODX7 workspace file (.modxworkspace): everything MxModxUSB can read from the MODX, kept as the MODX's own
//  bulk blocks (address and data bytes, exactly as dumped) so it can be sent back unchanged, plus a readable summary
//  of the settings for looking at without the instrument. JSON, so it can be read, compared and kept in git.
//
//  Sections:  system · sequencer · performance.common · performance.part1 … part16 · liveSet · curves · microTuning
//  Sending a section back replays its blocks as Bulk Dumps (with the Bulk Header and Footer the MODX dumped them
//  between), after checking each against ModxBulkRules.
//

import Foundation
import UniformTypeIdentifiers

extension UTType {
    static let modxWorkspace = UTType(exportedAs: "com.k3jdr.mxmodxusb.workspace", conformingTo: .json)
}

struct ModxWorkspaceFile: Codable, Equatable {
    static let formatName = "MxModxUSB MODX workspace"

    var format = formatName
    var version = 1
    var savedAt = Date()
    var savedBy = "MxModxUSB"
    var model = ""
    var firmware = ""
    var performance = ""
    var liveSetBank = ""
    var note = ""
    var sections: [Section] = []
    var summary: [SummaryGroup] = []

    struct Section: Codable, Equatable, Identifiable {
        var id: String
        var title: String
        /// The Bulk Header the blocks were dumped under ("0E 53 00"), nil for blocks the MODX dumps on their own.
        var header: String?
        var blocks: [Block]
    }

    struct Block: Codable, Equatable {
        var address: String
        var data: String
    }

    struct SummaryGroup: Codable, Equatable, Identifiable {
        var title: String
        var rows: [[String]]
        var id: String { title }
    }

    /// The groups the app offers to send back, each a list of section ids.
    static let groups: [(id: String, title: String, sections: (String) -> Bool)] = [
        ("system", "System settings", { $0 == "system" || $0 == "sequencer" }),
        ("performance", "Performance (Common and 16 Parts)", { $0.hasPrefix("performance.") }),
        ("liveSet", "Live Set bank", { $0 == "liveSet" }),
        ("curves", "User curves", { $0 == "curves" }),
        ("microTuning", "Micro-tuning tables", { $0 == "microTuning" }),
    ]

    // MARK: Bytes

    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02X", $0) }.joined(separator: " ") }

    static func bytes(_ hex: String) -> [UInt8]? {
        let parts = hex.split(separator: " ")
        let bytes = parts.compactMap { UInt8($0, radix: 16) }
        return bytes.count == parts.count ? bytes : nil
    }

    static func address(_ text: String) -> ModxAddress? {
        guard let b = bytes(text), b.count == 3 else { return nil }
        return ModxAddress(b[0], b[1], b[2])
    }

    /// A section's blocks as the MODX's own, nil if any is malformed or isn't one MxModxUSB may send.
    func blocks(of section: Section) -> [ModxBlock]? {
        var out: [ModxBlock] = []
        for b in section.blocks {
            guard let address = Self.address(b.address), let data = Self.bytes(b.data), data.allSatisfy({ $0 < 0x80 }),
                  ModxBulkRules.isAllowed(address, size: data.count) else { return nil }
            out.append(ModxBlock(address: address, data: data, checksumOK: true))
        }
        return out
    }

    /// What would be sent for a section: header (if any), its blocks, footer. Nil if the section doesn't check out.
    func messages(for section: Section) -> [(ModxAddress, [UInt8])]? {
        guard let blocks = blocks(of: section) else { return nil }
        var messages = blocks.map { ($0.address, $0.data) }
        if let headerText = section.header {
            guard let header = Self.address(headerText), ModxBulkRules.isAllowed(header, size: 0),
                  blocks.allSatisfy({ Self.belongs($0.address, toHeader: header) }) else { return nil }
            messages = [(header, [])] + messages + [(header.footer, [])]
        }
        return messages
    }

    /// Whether a block can travel under a header: Performance Common blocks under 0E 53 00, a Part's blocks under
    /// its own 0E 52 0p, Live Set blocks under 0E 51 00, curves under 0E 50 00.
    static func belongs(_ a: ModxAddress, toHeader h: ModxAddress) -> Bool {
        switch (h.mid, h.low) {
        case (0x53, 0): return a.high == 0x30
        case (0x52, let p): return ModxBulkRules.part(of: a) == Int(p) && a.high != 0x30
        case (0x51, 0): return (0x02...0x05).contains(a.high)
        case (0x50, 0): return a.high == 0x01
        default: return false
        }
    }

    static func read(_ url: URL) throws -> ModxWorkspaceFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(ModxWorkspaceFile.self, from: Data(contentsOf: url))
        guard file.format == formatName else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "This isn't a MxModxUSB workspace."])
        }
        return file
    }

    func write(_ url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// A Live Set bank kept in a workspace file: what the Live Set screen's bank menu offers beside the MODX's own bank.
struct ModxWorkspaceLiveSet: Identifiable, Equatable {
    let url: URL
    let savedAt: Date
    let model: String
    let firmware: String
    let liveSet: ModxLiveSet
    /// The file cut down to its Live Set section, ready for sending.
    let file: ModxWorkspaceFile

    var id: URL { url }
    var fileName: String { url.deletingPathExtension().lastPathComponent }

    /// The file's Live Set bank, nil if it has none or its blocks don't check out.
    init?(url: URL, file: ModxWorkspaceFile) {
        guard let section = file.sections.first(where: { $0.id == "liveSet" }), let blocks = file.blocks(of: section),
              file.messages(for: section) != nil else { return nil }
        let liveSet = ModxLiveSet(blocks: blocks)
        guard !liveSet.slots.isEmpty else { return nil }
        self.url = url
        savedAt = file.savedAt
        model = file.model
        firmware = file.firmware
        self.liveSet = liveSet
        var only = file
        only.sections = [section]
        only.summary = []
        self.file = only
    }

    init?(url: URL) {
        guard let file = try? ModxWorkspaceFile.read(url) else { return nil }
        self.init(url: url, file: file)
    }
}
