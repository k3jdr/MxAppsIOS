//
//  ModxModel+Tutorial.swift — MxModxUSB
//
//  The FM Synthesis and AWM2 Synthesis tutorials on the MODX7. A tutorial uses one FM-X or AWM2 Part of the current
//  Performance: starting reads the whole Part and keeps it; each lesson then sets its sound by Parameter Changes to
//  that Part's voice blocks (only the settings that differ; only to a Part of that engine) and reads the Part back
//  to check; Put Part Back sends the kept Part as a Bulk Dump and compares. Everything lands in the MODX's edit
//  buffer, so nothing is stored on the instrument; choosing another Performance on the MODX ends the tutorial.
//

import Foundation

struct ModxTutorialSession: Equatable {
    let engine: ModxEngine
    let part: Int
    /// The Performance the Part belongs to.
    let performance: String
    /// The Part's blocks as the MODX dumped them when the tutorial started.
    let snapshot: [ModxBlock]
    /// Other Parts muted to hear only this one, with their Mute before.
    var mutes: [Int: Int] = [:]
    /// The lesson last set up on the MODX.
    var lesson: String?
}

extension ModxModel {
    /// Parts of the current Performance a tutorial can use.
    func tutorialParts(_ engine: ModxEngine) -> [ModxPart] {
        parts.filter { $0.inUse && $0.type == engine.partType }
    }

    /// Reads the Part and keeps a copy, so the tutorial can put it back.
    func startTutorial(_ engine: ModxEngine, part p: Int) async {
        guard connected, editsUnlocked, tutorial == nil, tutorialBusy == nil, parts[p].type == engine.partType else { return }
        tutorialBusy = "Keeping a copy of Part \(p + 1)…"
        defer { tutorialBusy = nil }
        guard let blocks = await readPartBulk(p), !blocks.isEmpty, parts[p].type == engine.partType else {
            tutorialReport = "Couldn't read Part \(p + 1) from the MODX."
            return
        }
        tutorialEngine = engine
        tutorial = ModxTutorialSession(engine: engine, part: p, performance: common.name, snapshot: blocks)
        tutorialReport = "Part \(p + 1) is kept as it was: Put Part Back restores it."
    }

    /// Sets up a lesson's sound on the tutorial's Part.
    func setUpLesson(_ lesson: TutorialLesson) async {
        guard let session = tutorial, editsUnlocked, connected, tutorialBusy == nil else { return }
        let p = session.part
        guard parts[p].type == session.engine.partType else {
            tutorialReport = "Part \(p + 1) isn't \(session.engine.engineName) any more."
            return
        }
        let changes = lesson.settings(session.engine).compactMap { s in s.param.map { (s.target(part: p), $0, s.value) } }
        tutorialReport = await applyTutorialChanges(changes, part: p, label: "“\(lesson.title)”")
        tutorial?.lesson = lesson.id
    }

    /// Sends what differs as Parameter Changes, then reads the Part back and compares.
    private func applyTutorialChanges(_ changes: [(ModxTarget, ModxParam, Int)], part p: Int, label: String) async -> String {
        tutorialBusy = "Setting up \(label)…"
        defer { tutorialBusy = nil }
        var sends: [(ModxAddress, [UInt8])] = []
        var touched: Set<ModxTarget> = []
        var sent: [(target: ModxTarget, param: ModxParam, bytes: [UInt8])] = []
        for (target, param, value) in changes {
            guard target.partIndex == p, param.applies(to: parts[p]), let block = store[target.base],
                  let bytes = param.bytes(for: value, current: block.data), param.offset + bytes.count <= block.data.count else { continue }
            let range = param.offset..<(param.offset + bytes.count)
            guard Array(block.data[range]) != bytes else { continue }
            let address = target.base.with(low: target.base.low + UInt8(param.offset))
            guard ModxLink.isWritable(address, data: bytes) else { continue }
            var data = block.data
            data.replaceSubrange(range, with: bytes)
            store[target.base] = ModxBlock(address: block.address, data: data, checksumOK: true)
            sends.append((address, bytes))
            touched.insert(target)
            sent.append((target, param, bytes))
        }
        guard !sends.isEmpty else { return "\(label) is already set up on the MODX." }
        for (i, (address, bytes)) in sends.enumerated() {
            if i % 8 == 0 { tutorialBusy = "Setting up \(label): \(i) of \(sends.count) changes…" }
            guard await link.change(address, data: bytes) else { break }
        }
        undoStack.removeAll { touched.contains($0.target) }   // the lesson's sound is the new starting point
        rederive(.part(p))
        tutorialBusy = "Reading Part \(p + 1) back…"
        try? await Task.sleep(for: .milliseconds(300))
        guard let fresh = await readPartBulk(p) else { return "Sent \(sends.count) changes for \(label), but couldn't read Part \(p + 1) back." }
        // Setting by setting, only what was sent (the MODX adjusts some others itself — switching an element's Part
        // LFO off zeroes its Part LFO depth ratios, say — and the screen shows those as it holds them).
        var notes: [String] = []
        for change in sent {
            let range = change.param.offset..<(change.param.offset + change.bytes.count)
            guard let read = fresh.first(where: { $0.address == change.target.base }), range.upperBound <= read.data.count else {
                notes.append("\(change.param.name) (\(change.target.title)): not read back"); continue
            }
            guard Array(read.data[range]) != change.bytes else { continue }
            var sentData = read.data
            sentData.replaceSubrange(range, with: change.bytes)
            let shown = { (d: [UInt8]) in change.param.value(in: d).map(change.param.display) ?? "?" }
            notes.append("\(change.param.name) (\(change.target.title)): sent \(shown(sentData)), reads \(shown(read.data))")
        }
        if notes.isEmpty { return "\(label) is set up on the MODX (\(sends.count) change\(sends.count == 1 ? "" : "s"), read back). Play it." }
        return "Sent \(label), but the MODX holds \(notes.count == 1 ? "one setting" : "\(notes.count) settings") differently — \(notes.prefix(4).joined(separator: "; "))\(notes.count > 4 ? " …" : ""). The screen shows what it holds."
    }

    /// Mutes the Performance's other Parts in use, or unmutes them as they were.
    func setTutorialSolo(_ solo: Bool) async {
        guard var session = tutorial, editsUnlocked, connected, tutorialBusy == nil,
              let mute = ModxParams.part.first(where: { $0.key == "part.mute" }) else { return }
        tutorialBusy = solo ? "Muting the other Parts…" : "Unmuting the other Parts…"
        defer { tutorialBusy = nil }
        let others = solo ? partsInUse.map(\.index).filter { $0 != session.part && !parts[$0].mute }.map { ($0, 1) }
            : session.mutes.map { ($0.key, $0.value) }
        for (q, value) in others {
            let address = ModxTarget.part(q).base.with(low: UInt8(mute.offset))
            if solo { session.mutes[q] = parts[q].mute ? 1 : 0 }
            guard ModxLink.isWritable(address, data: [UInt8(value)]), await link.change(address, data: [UInt8(value)]) else { continue }
            if let read = await link.parameter(address)?.first, var block = store[ModxTarget.part(q).base] {
                var data = block.data
                data[mute.offset] = read
                block = ModxBlock(address: block.address, data: data, checksumOK: true)
                store[block.address] = block
                parts[q].read(block: block)
            }
        }
        if !solo { session.mutes = [:] }
        tutorial = session
        tutorialReport = solo ? (others.isEmpty ? "No other Part is playing." : "Only Part \(session.part + 1) plays now.")
            : "The other Parts play again."
    }

    /// Sends the Part back as it was when the tutorial started, and ends the tutorial.
    func putTutorialPartBack() async {
        guard let session = tutorial, editsUnlocked, connected, tutorialBusy == nil else { return }
        if !session.mutes.isEmpty { await setTutorialSolo(false) }
        let p = session.part
        tutorialBusy = "Putting Part \(p + 1) back…"
        defer { tutorialBusy = nil }
        let header = ModxAddress.performancePartBulk(p)
        let messages = [(header, [UInt8]())] + session.snapshot.map { ($0.address, $0.data) } + [(header.footer, [UInt8]())]
        guard messages.allSatisfy({ ModxBulkRules.isAllowed($0.0, size: $0.1.count) }) else {
            tutorialReport = "Part \(p + 1)'s copy holds a block the app may not send, so it wasn't sent. Choose the Performance again on the MODX to get the Part back."
            return
        }
        guard await link.sendBulk(messages, label: "Part \(p + 1) as it was", pause: 0.03) else {
            tutorialReport = "Couldn't send Part \(p + 1) to the MODX."
            return
        }
        try? await Task.sleep(for: .milliseconds(300))
        let fresh = await readPartBulk(p) ?? []
        let differing = session.snapshot.filter { b in fresh.first { $0.address == b.address }.map { $0.data != b.data } ?? true }
        undoStack.removeAll { $0.target.partIndex == p }
        tutorial = nil
        tutorialReport = differing.isEmpty ? "Part \(p + 1) is back as it was before the tutorial."
            : "Sent Part \(p + 1) back, but \(differing.count) of its blocks read differently. Choosing the Performance again on the MODX restores it fully."
    }
}
