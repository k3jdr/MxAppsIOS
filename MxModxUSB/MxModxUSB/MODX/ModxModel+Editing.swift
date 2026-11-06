//
//  ModxModel+Editing.swift — MxModxUSB
//
//  Changing the MODX, and workspace files.
//
//  Edits: nothing is sent until the player unlocks changes. A change is checked against its setting's range,
//  shown at once, sent as a Parameter Change (a run of changes to one setting goes as its last value), then read back
//  from the MODX; if the MODX reads otherwise the screen shows what it really holds and says so. Every change can be
//  undone (⌘Z), which sends the previous value. Performance, Part, effect and Live Set changes go to the MODX's edit
//  buffer — the MODX keeps them only if they're stored on it; System, Sequencer, curve and micro-tuning changes take
//  effect at once.
//
//  Workspaces: Save reads everything afresh (all 16 Parts included) and writes it with a readable summary; Open shows
//  a file without the MODX; Send replays chosen sections as Bulk Dumps and reads them back to compare.
//

import AppKit
import Foundation

struct ModxEdit {
    let target: ModxTarget
    let param: ModxParam
    let old: [UInt8]
    let new: [UInt8]

    var address: ModxAddress { target.base.with(low: target.base.low + UInt8(param.offset)) }
    var key: String { "\(address)" }
    var label: String { "\(param.name) (\(target.title))" }
}

extension ModxModel {
    // MARK: Reading values

    func data(_ target: ModxTarget) -> [UInt8]? { store[target.base]?.data }

    func value(_ param: ModxParam, _ target: ModxTarget) -> Int? { data(target).flatMap(param.value(in:)) }

    func text(_ param: ModxParam, _ target: ModxTarget) -> String? { data(target).flatMap(param.text(in:)) }

    /// Whether a setting can be edited now: changes unlocked, the MODX connected, its block read, and it applies to
    /// the Part (some settings aren't available for drum Parts, for Parts 9–16 …).
    func canEdit(_ param: ModxParam, _ target: ModxTarget) -> Bool {
        guard editsUnlocked, connected, data(target) != nil else { return false }
        if case .part(let p) = target { return param.applies(to: parts[p]) }
        return true
    }

    // MARK: Changing values

    func set(_ param: ModxParam, _ target: ModxTarget, to value: Int) {
        guard let current = data(target), let bytes = param.bytes(for: value, current: current) else { return }
        apply(target, param, bytes, undoable: true)
    }

    func set(_ param: ModxParam, _ target: ModxTarget, text: String) {
        guard let bytes = param.bytes(forText: text) else { return }
        apply(target, param, bytes, undoable: true)
    }

    func undoLastEdit() {
        guard let edit = undoStack.last, canEdit(edit.param, edit.target) else { return }
        undoStack.removeLast()
        apply(edit.target, edit.param, edit.old, undoable: false)
        editStatus = "Undid \(edit.label)."
    }

    var undoTitle: String? { undoStack.last.map { "Undo \($0.param.name)" } }

    private func apply(_ target: ModxTarget, _ param: ModxParam, _ bytes: [UInt8], undoable: Bool) {
        guard canEdit(param, target), var block = store[target.base], param.offset + bytes.count <= block.data.count else { return }
        let range = param.offset..<(param.offset + bytes.count)
        let old = Array(block.data[range])
        guard old != bytes else { return }
        let edit = ModxEdit(target: target, param: param, old: old, new: bytes)
        let writable = param.isText
            ? bytes.indices.allSatisfy { ModxLink.isWritable(edit.address.with(low: edit.address.low + UInt8($0)), data: [bytes[$0]]) }
            : ModxLink.isWritable(edit.address, data: bytes)
        guard writable else { editStatus = "The MODX doesn't take that value."; return }
        var data = block.data
        data.replaceSubrange(range, with: bytes)
        block = ModxBlock(address: block.address, data: data, checksumOK: true)
        store[target.base] = block
        if undoable {
            if let last = undoStack.last, last.key == edit.key {   // a run of changes to one setting undoes as one
                undoStack[undoStack.count - 1] = ModxEdit(target: target, param: param, old: last.old, new: bytes)
            } else {
                undoStack.append(edit)
                if undoStack.count > 200 { undoStack.removeFirst() }
            }
        }
        rederive(target)
        pendingEdits[edit.key] = edit
        editStatus = "Changing \(edit.label)…"
        startSending()
    }

    private func startSending() {
        guard editTask == nil else { return }
        editTask = Task { [weak self] in
            guard let self else { return }
            while let (key, edit) = self.pendingEdits.first {
                self.pendingEdits[key] = nil
                if edit.param.isText {
                    // Name 1 … Name 20 are separate settings in the Data List: one Parameter Change per character.
                    for (i, byte) in edit.new.enumerated() {
                        await self.link.change(edit.address.with(low: edit.address.low + UInt8(i)), data: [byte])
                    }
                } else {
                    await self.link.change(edit.address, data: edit.new)
                }
                self.editedTargets.insert(edit.target)
                if self.pendingEdits.isEmpty { try? await Task.sleep(for: .milliseconds(450)) }   // let a run of edits settle
            }
            await self.verify()
            self.editTask = nil
            if !self.pendingEdits.isEmpty { self.startSending() }
        }
    }

    /// Reads back what was changed and compares. Common and Part settings by Parameter Request; the rest by the same
    /// dumps that read them in the first place.
    private func verify() async {
        let targets = editedTargets
        editedTargets = []
        var differences: [String] = []
        var commonBulk = false, liveSetBulk = false, curveBulk = false
        for target in targets {
            switch target {
            case .common, .part:
                guard let local = data(target) else { continue }
                for param in target.params {
                    let range = param.offset..<(param.offset + param.size)
                    guard range.upperBound <= local.count else { continue }
                    // Only what this session changed: settings whose bytes differ from when they were last read.
                    guard undoStack.contains(where: { $0.target == target && $0.param.offset == param.offset }) else { continue }
                    // A name is twenty one-character settings; anything else is read with one request at its start.
                    var read: [UInt8] = []
                    if param.isText {
                        for i in range {
                            guard let b = await link.parameter(target.base.with(low: UInt8(i)))?.first else { break }
                            read.append(b)
                        }
                    } else if let bytes = await link.parameter(target.base.with(low: UInt8(param.offset))) {
                        read = Array(bytes.prefix(param.size))
                    }
                    if read.count == param.size, read != Array(local[range]) {
                        differences.append(param.name)
                        overwrite(target, range, with: read)
                    }
                }
            case .system:
                if let b = await link.dump(.system) { compare(b, &differences); system = b }
            case .sequencer:
                if let b = await link.dump(.sequencer) { compare(b, &differences); sequencer = b }
            case .reverb, .variation, .insertionA, .insertionB, .masterEffect:
                commonBulk = true
            case .liveSetBank, .liveSetPage, .liveSetSlot:
                liveSetBulk = true
            case .curve:
                curveBulk = true
            case .microTuningName(let n):
                if let b = await link.dump(.microTuningName(n)) { compare(b, &differences) }
            case .microTuningTable(let n):
                if let b = await link.dump(.microTuningTable(n)) { compare(b, &differences) }
            }
        }
        if commonBulk, let blocks = await link.bulk(.performanceCommonBulk, bulkInterval: bulkInterval) {
            for b in blocks where [0x41, 0x42, 0x43, 0x44, 0x46].contains(b.address.mid) { compare(b, &differences) }
            keep(blocks)
        }
        var liveSetRefused = false
        if liveSetBulk, let blocks = await link.bulk(.liveSetBulk, bulkInterval: bulkInterval) {
            let before = differences.count
            for b in blocks { compare(b, &differences) }
            liveSetRefused = differences.count > before
        }
        if curveBulk, let blocks = await link.bulk(.curveBulk, bulkInterval: bulkInterval) {
            for b in blocks { compare(b, &differences) }
        }
        for target in targets { rederive(target) }
        editStatus = differences.isEmpty
            ? "The MODX has the change" + (targets.contains(where: \.isEditBuffer) ? " (in its edit buffer: store it on the MODX to keep it)." : ".")
            : "The MODX didn't take: \(differences.joined(separator: ", ")). The screen now shows what it holds."
        // On a MODX7 (firmware 2.50) a page name sent to the factory Live Set bank, "Preset", was answered but not kept:
        // that bank seems not to take changes.
        if liveSetRefused, store[ModxTarget.liveSetBank.base]?.text(0, 20) == "Preset" {   // the name the MODX holds
            editStatus! += " The preset Live Set bank may not take changes: choose a User bank on the MODX, then Refresh."
        }
    }

    private func compare(_ fresh: ModxBlock, _ differences: inout [String]) {
        if let local = store[fresh.address], local.data != fresh.data { differences.append(fresh.address.description) }
        store[fresh.address] = fresh
    }

    private func overwrite(_ target: ModxTarget, _ range: Range<Int>, with bytes: [UInt8]) {
        guard var block = store[target.base] else { return }
        var data = block.data
        data.replaceSubrange(range, with: bytes)
        block = ModxBlock(address: block.address, data: data, checksumOK: true)
        store[target.base] = block
    }

    /// Rebuilds what the screens show from the store.
    func rederive(_ target: ModxTarget) {
        switch target {
        case .system: system = store[ModxTarget.system.base]
        case .sequencer: sequencer = store[ModxTarget.sequencer.base]
        case .common, .reverb, .variation, .insertionA, .insertionB, .masterEffect:
            var c = common
            for (address, block) in store where address.high == 0x30 { c.read(block: block) }
            common = c
        case .part(let p):
            if let block = store[target.base] { parts[p].read(block: block) }
        case .liveSetBank, .liveSetPage, .liveSetSlot:
            liveSet = ModxLiveSet(blocks: store.values.filter { (0x02...0x05).contains($0.address.high) })
        case .curve:
            curves = store.values.filter { $0.address.high == 0x01 }.compactMap(ModxUserCurve.init(block:)).sorted { $0.number < $1.number }
        case .microTuningName, .microTuningTable:
            tuningNames = (0..<8).map { store[ModxAddress.microTuningName($0)]?.text(0, 20) ?? "" }
        }
    }

    /// Reads a Part's whole block if it isn't in the store yet (an unused Part, before editing it).
    func ensurePartBlock(_ p: Int) {
        guard store[ModxAddress.part(p)] == nil, connected else { return }
        Task { await readPartBulk(p) }
    }

    // MARK: Workspace files

    /// Reads everything afresh — System, Sequencer, the whole Performance with all 16 Parts, the Live Set, user
    /// curves and micro-tuning tables — and makes a workspace of it.
    func captureWorkspace() async -> ModxWorkspaceFile? {
        guard connected else { return nil }
        workspaceBusy = "Reading System and Sequencer…"
        defer { workspaceBusy = nil }
        guard let system = await link.dump(.system), let sequencer = await link.dump(.sequencer) else { return nil }
        keep([system, sequencer])
        self.system = system
        self.sequencer = sequencer
        workspaceBusy = "Reading the Performance's Common blocks…"
        guard let common = await link.bulk(.performanceCommonBulk, bulkInterval: bulkInterval) else { return nil }
        keep(common)
        var sections = [
            ModxWorkspaceFile.Section(id: "system", title: "System", header: nil, blocks: [entry(system)]),
            ModxWorkspaceFile.Section(id: "sequencer", title: "Sequencer", header: nil, blocks: [entry(sequencer)]),
            ModxWorkspaceFile.Section(id: "performance.common", title: "Performance Common", header: "0E 53 00",
                                      blocks: common.map(entry)),
        ]
        for p in 0..<16 {
            workspaceBusy = "Reading Part \(p + 1) of 16…"
            guard let blocks = await link.bulk(.performancePartBulk(p), bulkInterval: bulkInterval) else { return nil }
            keep(blocks)
            sections.append(.init(id: "performance.part\(p + 1)", title: "Part \(p + 1)",
                                  header: ModxAddress.performancePartBulk(p).description, blocks: blocks.map(entry)))
        }
        workspaceBusy = "Reading the Live Set…"
        if let blocks = await link.bulk(.liveSetBulk, bulkInterval: bulkInterval) {
            keep(blocks)
            sections.append(.init(id: "liveSet", title: "Live Set", header: "0E 51 00", blocks: blocks.map(entry)))
        }
        workspaceBusy = "Reading user curves…"
        if let blocks = await link.bulk(.curveBulk, bulkInterval: bulkInterval) {
            keep(blocks)
            sections.append(.init(id: "curves", title: "User Curves", header: "0E 50 00", blocks: blocks.map(entry)))
        }
        workspaceBusy = "Reading micro-tuning tables…"
        var tuning: [ModxBlock] = []
        for n in 0..<8 {
            if let b = await link.dump(.microTuningTable(n)) { tuning.append(b) }
            if let b = await link.dump(.microTuningName(n)) { tuning.append(b) }
        }
        keep(tuning)
        sections.append(.init(id: "microTuning", title: "Micro-Tuning", header: nil, blocks: tuning.map(entry)))
        for target in [ModxTarget.common, .liveSetBank, .curve(0), .microTuningName(0)] { rederive(target) }
        for p in 0..<16 { rederive(.part(p)) }

        var file = ModxWorkspaceFile()
        file.model = identity?.model ?? ""
        file.firmware = identity?.firmware ?? ""
        file.performance = self.common.name
        file.liveSetBank = liveSet?.bankName ?? ""
        file.sections = sections
        file.summary = Self.summary(of: file)
        return file
    }

    private func entry(_ b: ModxBlock) -> ModxWorkspaceFile.Block {
        .init(address: b.address.description, data: ModxWorkspaceFile.hex(b.data))
    }

    /// The readable half of a workspace: each section's settings by name.
    static func summary(of file: ModxWorkspaceFile) -> [ModxWorkspaceFile.SummaryGroup] {
        var groups: [ModxWorkspaceFile.SummaryGroup] = []
        func blocks(_ id: String) -> [ModxBlock] { file.sections.first { $0.id == id }.flatMap { file.blocks(of: $0) } ?? [] }
        if let system = blocks("system").first {
            groups.append(.init(title: "System", rows: ModxSystemTable.settings(system).map { [$0.group, $0.name, $0.value] }))
        }
        if let sequencer = blocks("sequencer").first {
            groups.append(.init(title: "Sequencer", rows: ModxSystemTable.sequencer(sequencer).map { [$0.group, $0.name, $0.value] }))
        }
        var common = ModxPerformanceCommon()
        for b in blocks("performance.common") { common.read(block: b) }
        if !common.name.isEmpty {
            groups.append(.init(title: "Performance", rows: [
                ["Performance", "Name", common.name], ["Performance", "Tempo", "\(common.tempo) BPM"],
                ["Performance", "Volume", "\(common.volume)"], ["Effects", "Reverb", common.reverb],
                ["Effects", "Variation", common.variation], ["Effects", "Master Effect", common.masterEffect],
            ]))
        }
        var partRows: [[String]] = []
        for p in 0..<16 {
            let part = blocks("performance.part\(p + 1)")
            guard let b = part.first(where: { $0.address == ModxAddress.part(p) }) else { continue }
            var info = ModxPart(index: p)
            info.read(block: b)
            guard info.inUse else { continue }
            let type = part.contains { $0.address.high == 0x41 } ? "AWM2" : part.contains { $0.address.high == 0x48 } ? "FM-X" : "Drum"
            partRows.append(["Part \(p + 1)", info.name, "\(info.category) · \(type) · \(info.noteRange) · vol \(info.volume)"])
        }
        if !partRows.isEmpty { groups.append(.init(title: "Parts", rows: partRows)) }
        let live = ModxLiveSet(blocks: blocks("liveSet"))
        if !live.slots.isEmpty {
            let names = ModxPerformanceNames()   // the preset list (names seen on the MODX belong to the app, not the file)
            groups.append(.init(title: "Live Set “\(live.bankName)”", rows: live.slots.filter { !$0.isEmpty }.map { slot in
                let performance = names.name(of: slot)?.name
                let shown = performance.map { $0 == slot.name ? $0 : "\($0) (slot “\(slot.name)”)" } ?? slot.name
                return ["Page \(slot.page + 1) \(live.pageNames[slot.page])", "Slot \(slot.slot + 1)", "\(shown) · \(slot.bankName) #\(slot.number)"]
            }))
        }
        return groups
    }

    func saveWorkspace() {
        Task {
            guard let file = await captureWorkspace() else {
                editStatus = "Couldn't read everything from the MODX; nothing saved."
                return
            }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.modxWorkspace]
            panel.nameFieldStringValue = "\(file.model.isEmpty ? "MODX" : file.model) \(file.performance).modxworkspace"
            panel.message = "Everything read from the \(file.model): System, the Performance with all 16 Parts, the Live Set, curves and micro-tuning."
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try file.write(url)
                workspace = file
                workspaceURL = url
                noteWorkspace(url, file)
                editStatus = "Saved \(url.lastPathComponent)."
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    func openWorkspace() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.modxWorkspace, .json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openWorkspace(url)
    }

    func openWorkspace(_ url: URL) {
        do {
            let file = try ModxWorkspaceFile.read(url)
            workspace = file
            workspaceURL = url
            noteWorkspace(url, file)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// For a section of a workspace (the open one unless another is given): whether the MODX, as last read, holds the
    /// same bytes; nil if the app hasn't read those blocks.
    func sameAsMODX(_ section: ModxWorkspaceFile.Section, in file: ModxWorkspaceFile? = nil) -> Bool? {
        guard let workspace = file ?? workspace, let blocks = workspace.blocks(of: section), !blocks.isEmpty else { return nil }
        var any = false
        for b in blocks {
            guard let local = store[b.address] else { continue }
            any = true
            if local.data != b.data { return false }
        }
        return any ? true : nil
    }

    /// Sends the chosen groups of a workspace (the open one unless another is given) to the MODX as Bulk Dumps, then
    /// reads them back to compare.
    func sendWorkspace(_ file: ModxWorkspaceFile? = nil, groups: Set<String>) async -> String {
        guard let workspace = file ?? workspace, editsUnlocked, connected else { return "Unlock changes and connect the MODX first." }
        var report: [String] = []
        for group in ModxWorkspaceFile.groups where groups.contains(group.id) {
            for section in workspace.sections where group.sections(section.id) {
                guard let messages = workspace.messages(for: section) else {
                    report.append("\(section.title): not sent — the file's blocks don't check out")
                    continue
                }
                workspaceBusy = "Sending \(section.title)…"
                if !(await link.sendBulk(messages, label: section.title, pause: 0.03)) {
                    report.append("\(section.title): not sent — the MODX was disconnected")
                }
            }
        }
        workspaceBusy = "Reading back what was sent…"
        let sentSections = workspace.sections.filter { s in ModxWorkspaceFile.groups.contains { groups.contains($0.id) && $0.sections(s.id) } }
        // Read back exactly as a workspace capture would, then compare section by section.
        if groups.contains("system") {
            if let b = await link.dump(.system) { keep([b]) }
            if let b = await link.dump(.sequencer) { keep([b]) }
        }
        if groups.contains("performance") {
            if let blocks = await link.bulk(.performanceCommonBulk, bulkInterval: bulkInterval) { keep(blocks) }
            for p in 0..<16 { await readPartBulk(p) }
        }
        if groups.contains("liveSet"), let blocks = await link.bulk(.liveSetBulk, bulkInterval: bulkInterval) { keep(blocks) }
        if groups.contains("curves"), let blocks = await link.bulk(.curveBulk, bulkInterval: bulkInterval) { keep(blocks) }
        if groups.contains("microTuning") {
            for n in 0..<8 {
                if let b = await link.dump(.microTuningTable(n)) { keep([b]) }
                if let b = await link.dump(.microTuningName(n)) { keep([b]) }
            }
        }
        workspaceBusy = nil
        for target in [ModxTarget.system, .sequencer, .common, .liveSetBank, .curve(0), .microTuningName(0)] { rederive(target) }
        for p in 0..<16 { rederive(.part(p)) }
        let differing = sentSections.filter { sameAsMODX($0, in: workspace) == false }.map(\.title)
        undoStack.removeAll()
        let skipped = !report.isEmpty
        report.insert(!differing.isEmpty ? "The MODX reads differently in: \(differing.joined(separator: ", "))."
                      : skipped ? "What was sent, the MODX now holds — but not everything was sent:"
                      : "The MODX now holds what the workspace has.", at: 0)
        editStatus = report.first
        return report.joined(separator: "\n")
    }
}
