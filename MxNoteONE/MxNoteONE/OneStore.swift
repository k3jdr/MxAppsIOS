//
//  OneStore.swift
//  MxNoteONE
//
//  Reader for Microsoft OneNote section files (.one) — the revision store
//  file format published as [MS-ONESTORE]. It reads the file header, the
//  transaction log, file node lists, object spaces, revisions (following
//  dependent revisions), object groups with their global ID tables, object
//  property sets and the embedded file data store, and gives back for
//  each object space the objects of its current revision.
//
//  Read-only. Password-protected (encrypted) sections are not supported.
//

import Foundation

enum OneStoreError: LocalizedError {
    case notOneNote
    case truncated
    case encrypted

    var errorDescription: String? {
        switch self {
        case .notOneNote: "The file is not a OneNote section (.one)."
        case .truncated: "The OneNote file is damaged or incomplete."
        case .encrypted: "The section is password protected in OneNote. Remove the password in OneNote, then export it again."
        }
    }
}

/// A GUID plus a number (ExtendedGUID).
struct ExGUID: Hashable, CustomStringConvertible {
    var guid: UUID
    var n: UInt32

    static let zero = ExGUID(guid: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)), n: 0)
    var isZero: Bool { self == .zero }
    var description: String { "\(guid.uuidString.prefix(8))…:\(n)" }
}

/// Little-endian reader over the file bytes.
struct ByteReader {
    let data: Data
    var offset: Int
    let end: Int

    init(_ data: Data, offset: Int = 0, length: Int? = nil) {
        self.data = data
        self.offset = offset
        end = min(data.count, offset + (length ?? (data.count - offset)))
    }

    var remaining: Int { end - offset }

    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, offset + count <= end else { throw OneStoreError.truncated }
        defer { offset += count }
        let start = data.startIndex + offset
        return data.subdata(in: start..<(start + count))
    }

    mutating func skip(_ count: Int) throws {
        guard offset + count <= end else { throw OneStoreError.truncated }
        offset += count
    }

    mutating func u8() throws -> UInt8 {
        guard offset + 1 <= end else { throw OneStoreError.truncated }
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }

    mutating func u16() throws -> UInt16 {
        let b = try bytes(2)
        return UInt16(b[b.startIndex]) | UInt16(b[b.startIndex + 1]) << 8
    }

    mutating func u32() throws -> UInt32 {
        let b = try bytes(4)
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(b[b.startIndex + i]) << (8 * UInt32(i)) }
        return v
    }

    mutating func u64() throws -> UInt64 {
        let b = try bytes(8)
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(b[b.startIndex + i]) << (8 * UInt64(i)) }
        return v
    }

    mutating func guid() throws -> UUID {
        let b = try bytes(16)
        var u = [UInt8](b)
        // Microsoft GUIDs store the first three fields little-endian.
        u.swapAt(0, 3); u.swapAt(1, 2); u.swapAt(4, 5); u.swapAt(6, 7)
        return UUID(uuid: (u[0], u[1], u[2], u[3], u[4], u[5], u[6], u[7], u[8], u[9], u[10], u[11], u[12], u[13], u[14], u[15]))
    }

    mutating func exGUID() throws -> ExGUID {
        let g = try guid()
        return ExGUID(guid: g, n: try u32())
    }
}

/// A reference to a chunk of the file.
struct ChunkRef {
    var stp: UInt64
    var cb: UInt64

    var isNil: Bool { stp == UInt64.max || (stp == 0 && cb == 0) || stp == 0xFFFF_FFFF }

    /// Offset and length, if the chunk lies inside a file of the given size.
    func span(in size: Int) -> (offset: Int, length: Int)? {
        guard !isNil, stp < UInt64(size), cb <= UInt64(size), stp + cb <= UInt64(size) else { return nil }
        return (Int(stp), Int(cb))
    }
}

/// A property value in an object's property set.
indirect enum PropertyValue {
    case none
    case bool(Bool)
    case u8(UInt8)
    case u16(UInt16)
    case u32(UInt32)
    case u64(UInt64)
    case bytes(Data)
    case objectID(ExGUID?)
    case objectIDs([ExGUID?])
    case objectSpaceID(ExGUID?)
    case objectSpaceIDs([ExGUID?])
    case contextID(ExGUID?)
    case contextIDs([ExGUID?])
    case propertyValues([PropertySet])
    case propertySet(PropertySet)
}

struct PropertySet {
    /// Property values by PropertyID (the full 32-bit ID, including type bits).
    var values: [UInt32: PropertyValue] = [:]
    var order: [UInt32] = []

    subscript(_ id: UInt32) -> PropertyValue? { values[id] }
}

/// An object in an object space revision.
struct StoreObject {
    var id: ExGUID
    var jcid: UInt32
    var properties: PropertySet
    /// For file data objects (pictures, attachments): the embedded file bytes, and its extension.
    var fileData: Data?
    var fileExtension: String?
    /// "<file>{GUID}" (inside the section) or "<ifndf>{GUID}" (in the notebook's onefiles folder).
    var fileReference: String?
}

/// One object space (a section's metadata space, or one page) at its current revision.
struct ObjectSpace {
    var id: ExGUID
    var objects: [ExGUID: StoreObject]
    /// Root objects by role (1 = content, 2 = metadata).
    var roots: [UInt32: ExGUID]

    func object(_ id: ExGUID?) -> StoreObject? {
        guard let id else { return nil }
        return objects[id]
    }
}

/// A parsed .one file.
struct OneStoreFile {
    var rootSpace: ExGUID
    var spaces: [ExGUID: ObjectSpace]
}

final class OneStoreReader {
    static let oneFileType = UUID(uuidString: "7B5C52E4-D88C-4DA7-AEB1-5378D02996D3")!
    static let tocFileType = UUID(uuidString: "43FF2FA1-EFD9-4C76-9EE2-10EA5722765F")!
    static let fileFormat = UUID(uuidString: "109ADD3F-911B-49F5-A5D0-1791EDC8AED8")!
    static let listMagic: UInt64 = 0xA456_7AB1_F5F7_F4C4
    static let listFooter: UInt64 = 0x8BC2_15C3_8233_BA4B

    private let data: Data
    /// Committed node count of each file node list (from the transaction log).
    private var listCounts: [UInt32: UInt32] = [:]
    /// Embedded files by their GUID.
    private var fileStore: [UUID: Data] = [:]

    init(data: Data) {
        self.data = data
    }

    static func read(_ url: URL) throws -> OneStoreFile {
        try OneStoreReader(data: Data(contentsOf: url, options: .mappedIfSafe)).parse()
    }

    /// Set to print parse problems (diagnostics).
    static var debug = false
    private func debugStep(_ step: String, _ error: Error) {
        if Self.debug { print("  [onestore] \(step): \(error)") }
    }

    // MARK: Header and lists

    struct FileNode {
        var id: UInt32
        var size: Int
        var stpFormat: Int
        var cbFormat: Int
        var baseType: Int
        /// Offset of the node's data (after the header).
        var dataOffset: Int
        var ref: ChunkRef?
    }

    func parse() throws -> OneStoreFile {
        var r = ByteReader(data)
        guard data.count >= 1024 else { throw OneStoreError.notOneNote }
        let fileType = try r.guid()
        guard fileType == Self.oneFileType || fileType == Self.tocFileType else { throw OneStoreError.notOneNote }
        r.offset = 0x30
        guard try r.guid() == Self.fileFormat else { throw OneStoreError.notOneNote }
        r.offset = 96
        let transactions = try r.u32()
        r.offset = 160
        let transactionLog = ChunkRef(stp: try r.u64(), cb: UInt64(try r.u32()))
        let rootList = ChunkRef(stp: try r.u64(), cb: UInt64(try r.u32()))
        do { try readTransactionLog(transactionLog, count: transactions) } catch { debugStep("transaction log", error) }

        var rootSpace = ExGUID.zero
        var manifestLists: [(ExGUID, ChunkRef)] = []
        let rootNodes: [FileNode]
        do { rootNodes = try nodes(rootList) } catch { debugStep("root list", error); throw error }
        for node in rootNodes {
            var nr = ByteReader(data, offset: node.dataOffset)
            switch node.id {
            case 0x004:
                rootSpace = try nr.exGUID()
            case 0x008:
                if let ref = node.ref {
                    manifestLists.append((try nr.exGUID(), ref))
                }
            case 0x090:
                if let ref = node.ref {
                    do { try readFileDataStore(ref) } catch { debugStep("file data store", error) }
                }
            default:
                break
            }
        }
        var spaces: [ExGUID: ObjectSpace] = [:]
        for (gosid, ref) in manifestLists {
            do { spaces[gosid] = try readObjectSpace(gosid, manifest: ref) } catch { debugStep("object space \(gosid)", error) }
        }
        return OneStoreFile(rootSpace: rootSpace, spaces: spaces)
    }

    private func readTransactionLog(_ ref: ChunkRef, count: UInt32) throws {
        var fragment = ref
        var done: UInt32 = 0
        var pending: [UInt32: UInt32] = [:]
        var visited = 0
        while done < count, let span = fragment.span(in: data.count), visited < 10_000 {
            visited += 1
            var r = ByteReader(data, offset: span.offset, length: span.length)
            let entries = (span.length - 12) / 8
            for _ in 0..<max(0, entries) {
                let src = try r.u32()
                let value = try r.u32()
                if src == 1 {
                    for (k, v) in pending { listCounts[k] = v }
                    pending = [:]
                    done += 1
                    if done >= count { return }
                } else if src != 0 {
                    pending[src] = value
                }
            }
            // The next fragment reference follows the last entry.
            r.offset = span.offset + max(0, entries) * 8
            fragment = ChunkRef(stp: try r.u64(), cb: UInt64(try r.u32()))
        }
    }

    private func readRef(_ r: inout ByteReader, stpFormat: Int, cbFormat: Int) throws -> ChunkRef {
        var stp: UInt64
        switch stpFormat {
        case 0: stp = try r.u64()
        case 1: stp = UInt64(try r.u32())
        case 2: stp = UInt64(try r.u16()) * 8
        default: stp = UInt64(try r.u32()) * 8
        }
        var cb: UInt64
        switch cbFormat {
        case 0: cb = UInt64(try r.u32())
        case 1: cb = try r.u64()
        case 2: cb = UInt64(try r.u8()) * 8
        default: cb = UInt64(try r.u16()) * 8
        }
        if stpFormat == 1 && stp == 0xFFFF_FFFF { stp = UInt64.max }
        if stpFormat == 2 && stp == 0xFFFF * 8 { stp = UInt64.max }
        return ChunkRef(stp: stp, cb: cb)
    }

    /// The committed file nodes of a file node list (across its fragments).
    func nodes(_ ref: ChunkRef) throws -> [FileNode] {
        var result: [FileNode] = []
        var fragment = ref
        var listID: UInt32?
        var limit: UInt32?
        var visited = 0
        outer: while let span = fragment.span(in: data.count), span.length >= 36, visited < 100_000 {
            visited += 1
            var r = ByteReader(data, offset: span.offset, length: span.length)
            guard try r.u64() == Self.listMagic else { break }
            let id = try r.u32()
            _ = try r.u32()
            if listID == nil {
                listID = id
                limit = listCounts[id]
            }
            let nodesEnd = span.offset + span.length - 20
            while r.offset + 4 <= nodesEnd {
                if let limit, result.count >= Int(limit) { break outer }
                let header = try r.u32()
                let nodeID = header & 0x3FF
                let size = Int((header >> 10) & 0x1FFF)
                let stpFormat = Int((header >> 23) & 0x3)
                let cbFormat = Int((header >> 25) & 0x3)
                let baseType = Int((header >> 27) & 0xF)
                if nodeID == 0 || nodeID == 0x0FF || size < 4 { break }
                let start = r.offset - 4
                var node = FileNode(id: nodeID, size: size, stpFormat: stpFormat, cbFormat: cbFormat,
                                    baseType: baseType, dataOffset: r.offset, ref: nil)
                if baseType == 1 || baseType == 2 {
                    var rr = r
                    node.ref = try readRef(&rr, stpFormat: stpFormat, cbFormat: cbFormat)
                    node.dataOffset = rr.offset
                }
                result.append(node)
                r.offset = start + size
            }
            r.offset = nodesEnd
            fragment = ChunkRef(stp: try r.u64(), cb: UInt64(try r.u32()))
        }
        return result
    }

    private func readFileDataStore(_ ref: ChunkRef) throws {
        for node in try nodes(ref) where node.id == 0x094 {
            guard let span = node.ref?.span(in: data.count) else { continue }
            var nr = ByteReader(data, offset: node.dataOffset)
            let guid = try nr.guid()
            var r = ByteReader(data, offset: span.offset, length: span.length)
            try r.skip(16)
            let length = try r.u64()
            try r.skip(12)
            if length <= UInt64(r.remaining) { fileStore[guid] = try r.bytes(Int(length)) }
        }
    }

    // MARK: Object spaces and revisions

    private struct Revision {
        var id: ExGUID
        var dependent: ExGUID
        var objects: [ExGUID: StoreObject] = [:]
        var roots: [UInt32: ExGUID] = [:]
    }

    private func readObjectSpace(_ gosid: ExGUID, manifest: ChunkRef) throws -> ObjectSpace {
        // The last revision manifest list reference is the current one.
        guard let revisionList = try nodes(manifest).last(where: { $0.id == 0x010 })?.ref else {
            return ObjectSpace(id: gosid, objects: [:], roots: [:])
        }
        var revisions: [ExGUID: Revision] = [:]
        var roleMap: [String: ExGUID] = [:]
        var current: Revision?
        var lastRevision: ExGUID?
        var globalTable: [UInt32: UUID] = [:]
        for node in try nodes(revisionList) {
            var r = ByteReader(data, offset: node.dataOffset)
            switch node.id {
            case 0x01B, 0x01E, 0x01F:
                let rid = try r.exGUID()
                let dependent = try r.exGUID()
                if node.id == 0x01B { _ = try r.u64() }
                let role = try r.u32()
                _ = try r.u16()
                var context = ExGUID.zero
                if node.id == 0x01F { context = try r.exGUID() }
                current = Revision(id: rid, dependent: dependent)
                roleMap["\(context)|\(role)"] = rid
                globalTable = [:]
            case 0x01C:
                if let revision = current {
                    revisions[revision.id] = revision
                    lastRevision = revision.id
                }
                current = nil
            case 0x0B0:
                if let ref = node.ref, current != nil {
                    try readObjectGroup(ref, into: &current!)
                }
            case 0x021, 0x022:
                globalTable = [:]
            case 0x024:
                let index = try r.u32()
                globalTable[index] = try r.guid()
            case 0x025:
                let from = try r.u32(), to = try r.u32()
                globalTable[to] = globalTable[from]
            case 0x026:
                let from = try r.u32(), count = try r.u32(), to = try r.u32()
                for i in 0..<count { globalTable[to + i] = globalTable[from + i] }
            case 0x059:
                let oid = resolve(try r.u32(), globalTable)
                let role = try r.u32()
                if let oid { current?.roots[role] = oid }
            case 0x05A:
                let oid = try r.exGUID()
                current?.roots[try r.u32()] = oid
            case 0x041, 0x042, 0x02D, 0x02E:
                // Older-style object revisions declared directly in the revision (CompactID references).
                guard let ref = node.ref, current != nil else { break }
                let compact = try r.u32()
                guard let oid = resolve(compact, globalTable) else { break }
                var jcid: UInt32 = 0
                if node.id == 0x02D || node.id == 0x02E {
                    let bits = try r.u32()
                    jcid = bits & 0x3FF
                }
                if let object = try? readObject(oid, jcid: jcid, ref: ref, table: globalTable) {
                    current!.objects[oid] = object
                }
            case 0x05C:
                let rid = try r.exGUID()
                roleMap["\(ExGUID.zero)|\(try r.u32())"] = rid
            case 0x05D:
                let rid = try r.exGUID()
                let role = try r.u32()
                let context = try r.exGUID()
                roleMap["\(context)|\(role)"] = rid
            default:
                break
            }
        }
        // Current content revision: default context, role 1.
        let target = roleMap["\(ExGUID.zero)|1"] ?? lastRevision
        var objects: [ExGUID: StoreObject] = [:]
        var roots: [UInt32: ExGUID] = [:]
        var chain: [Revision] = []
        var next = target
        var guardCount = 0
        while let id = next, let revision = revisions[id], guardCount < 10_000 {
            chain.append(revision)
            next = revision.dependent.isZero ? nil : revision.dependent
            guardCount += 1
        }
        for revision in chain.reversed() {
            objects.merge(revision.objects) { $1 }
            roots.merge(revision.roots) { $1 }
        }
        // Metadata root lives in the role-2 revision when there is one.
        if let metaID = roleMap["\(ExGUID.zero)|2"], let meta = revisions[metaID] {
            var metaChain: [Revision] = []
            var id: ExGUID? = metaID
            while let rid = id, let revision = revisions[rid], metaChain.count < 10_000 {
                metaChain.append(revision)
                id = revision.dependent.isZero ? nil : revision.dependent
            }
            for revision in metaChain.reversed() { objects.merge(revision.objects) { old, _ in old } }
            if let root = meta.roots[2] ?? meta.roots[1] { roots[2] = roots[2] ?? root }
        }
        return ObjectSpace(id: gosid, objects: objects, roots: roots)
    }

    private func resolve(_ compact: UInt32, _ table: [UInt32: UUID]) -> ExGUID? {
        let n = compact & 0xFF
        let index = compact >> 8
        if n == 0 && index == 0 { return nil }
        guard let guid = table[index] else { return nil }
        return ExGUID(guid: guid, n: n)
    }

    private func readObjectGroup(_ ref: ChunkRef, into revision: inout Revision) throws {
        var table: [UInt32: UUID] = [:]
        for node in try nodes(ref) {
            var r = ByteReader(data, offset: node.dataOffset)
            switch node.id {
            case 0x021, 0x022:
                table = [:]
            case 0x024:
                let index = try r.u32()
                table[index] = try r.guid()
            case 0x025:
                let from = try r.u32(), to = try r.u32()
                table[to] = table[from]
            case 0x026:
                let from = try r.u32(), count = try r.u32(), to = try r.u32()
                for i in 0..<count { table[to + i] = table[from + i] }
            case 0x0A4, 0x0A5, 0x0C4, 0x0C5:
                guard let ref = node.ref else { break }
                let compact = try r.u32()
                let jcid = try r.u32()
                guard let oid = resolve(compact, table) else { break }
                if let object = try? readObject(oid, jcid: jcid, ref: ref, table: table) {
                    revision.objects[oid] = object
                }
            case 0x072, 0x073:
                let compact = try r.u32()
                let jcid = try r.u32()
                if node.id == 0x072 { _ = try r.u8() } else { _ = try r.u32() }
                let reference = try storageString(&r)
                let ext = try storageString(&r)
                guard let oid = resolve(compact, table) else { break }
                var object = StoreObject(id: oid, jcid: jcid, properties: PropertySet())
                object.fileExtension = ext.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                object.fileReference = reference
                if reference.hasPrefix("<file>"), let guid = UUID(uuidString: String(reference.dropFirst(6))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "{}"))) {
                    object.fileData = fileStore[guid]
                }
                revision.objects[oid] = object
            case 0x07C:
                throw OneStoreError.encrypted
            default:
                break
            }
        }
    }

    private func storageString(_ r: inout ByteReader) throws -> String {
        let count = Int(try r.u32())
        let bytes = try r.bytes(count * 2)
        return String(data: bytes, encoding: .utf16LittleEndian) ?? ""
    }

    // MARK: Property sets

    private func readObject(_ oid: ExGUID, jcid: UInt32, ref: ChunkRef, table: [UInt32: UUID]) throws -> StoreObject {
        guard let span = ref.span(in: data.count) else { throw OneStoreError.truncated }
        var r = ByteReader(data, offset: span.offset, length: span.length)
        func stream() throws -> (ids: [ExGUID?], osidAbsent: Bool, extended: Bool) {
            let header = try r.u32()
            let count = Int(header & 0xFFFFFF)
            var ids: [ExGUID?] = []
            ids.reserveCapacity(count)
            for _ in 0..<count { ids.append(resolve(try r.u32(), table)) }
            return (ids, header & 0x8000_0000 != 0, header & 0x4000_0000 != 0)
        }
        let oids = try stream()
        var osids: [ExGUID?] = []
        var contexts: [ExGUID?] = []
        if !oids.osidAbsent {
            let s = try stream()
            osids = s.ids
            if s.extended || oids.extended { contexts = try stream().ids }
        }
        var cursor = (oid: 0, osid: 0, context: 0)
        let properties = try propertySet(&r, oids: oids.ids, osids: osids, contexts: contexts, cursor: &cursor)
        return StoreObject(id: oid, jcid: jcid, properties: properties)
    }

    private func propertySet(_ r: inout ByteReader, oids: [ExGUID?], osids: [ExGUID?], contexts: [ExGUID?],
                             cursor: inout (oid: Int, osid: Int, context: Int)) throws -> PropertySet {
        let count = Int(try r.u16())
        var ids: [UInt32] = []
        for _ in 0..<count { ids.append(try r.u32()) }
        var set = PropertySet()
        func take(_ list: [ExGUID?], _ index: inout Int) -> ExGUID? {
            defer { index += 1 }
            return index < list.count ? list[index] : nil
        }
        for id in ids {
            let type = (id >> 26) & 0x1F
            let value: PropertyValue
            switch type {
            case 0x1: value = .none
            case 0x2: value = .bool(id & 0x8000_0000 != 0)
            case 0x3: value = .u8(try r.u8())
            case 0x4: value = .u16(try r.u16())
            case 0x5: value = .u32(try r.u32())
            case 0x6: value = .u64(try r.u64())
            case 0x7:
                let length = Int(try r.u32())
                value = .bytes(try r.bytes(length))
            case 0x8: value = .objectID(take(oids, &cursor.oid))
            case 0x9:
                let n = Int(try r.u32())
                value = .objectIDs((0..<n).map { _ in take(oids, &cursor.oid) })
            case 0xA: value = .objectSpaceID(take(osids, &cursor.osid))
            case 0xB:
                let n = Int(try r.u32())
                value = .objectSpaceIDs((0..<n).map { _ in take(osids, &cursor.osid) })
            case 0xC: value = .contextID(take(contexts, &cursor.context))
            case 0xD:
                let n = Int(try r.u32())
                value = .contextIDs((0..<n).map { _ in take(contexts, &cursor.context) })
            case 0x10:
                let n = Int(try r.u32())
                var sets: [PropertySet] = []
                if n > 0 {
                    _ = try r.u32()
                    for _ in 0..<n { sets.append(try propertySet(&r, oids: oids, osids: osids, contexts: contexts, cursor: &cursor)) }
                }
                value = .propertyValues(sets)
            case 0x11:
                value = .propertySet(try propertySet(&r, oids: oids, osids: osids, contexts: contexts, cursor: &cursor))
            default:
                value = .none
            }
            let key = id & 0x7FFF_FFFF
            set.values[key] = value
            set.order.append(key)
        }
        return set
    }
}
