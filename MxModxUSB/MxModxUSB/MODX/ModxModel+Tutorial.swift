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
    /// Parts Hear only this Part muted, each with its Mute before (also those an earlier launch muted and the MODX
    /// still holds muted: ModxHearOnlyRecord).
    var mutes: [Int: Int] = [:]
    /// Hear only this Part is on.
    var hearingOnly = false
    /// The lesson last set up on the MODX.
    var lesson: String?
}

/// What Hear only this Part muted, kept between launches: the MODX keeps those Parts muted until its Performance is
/// chosen again, so if the app quits with Hear only on, the next launch still knows which Parts to unmute.
struct ModxHearOnlyRecord: Codable, Equatable {
    var performance: String
    /// Part (0-based) → its Mute before Hear only changed it.
    var mutes: [Int: Int]

    static let defaultsKey = "hearOnlyMutes"

    static func load() -> ModxHearOnlyRecord? {
        UserDefaults.standard.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }

    static func save(_ record: ModxHearOnlyRecord?) {
        if let record, !record.mutes.isEmpty, let data = try? JSONEncoder().encode(record) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
    }

    /// The record's Parts that are still as Hear only left them (in this Performance, their Mute not back as it was).
    func stillChanged(performance name: String, parts: [ModxPart]) -> [Int: Int] {
        guard performance == name else { return [:] }
        return mutes.filter { q, before in q >= 0 && q < parts.count && parts[q].inUse && (parts[q].mute ? 1 : 0) != before }
    }
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
        var session = ModxTutorialSession(engine: engine, part: p, performance: common.name, snapshot: blocks)
        // Parts an earlier Hear only this Part muted and the MODX still holds muted: this one unmutes them.
        let leftover = hearOnlyRecord?.stillChanged(performance: common.name, parts: parts) ?? [:]
        session.mutes = leftover
        session.hearingOnly = !leftover.isEmpty
        rememberHearOnly(leftover)
        tutorial = session
        var report = "Part \(p + 1) is kept as it was: Put Part Back restores it."
        if !leftover.isEmpty {
            report += " \(Self.partList(leftover.keys.sorted())) \(leftover.count == 1 ? "is" : "are") still muted by Hear only this Part from before: turn it off to unmute \(leftover.count == 1 ? "it" : "them")."
        }
        if parts[p].mute || !parts[p].partSwitch {
            report += " Part \(p + 1) itself is \(parts[p].mute ? "muted" : "switched off") on the MODX: Set Up on the MODX switches it on and unmutes it."
        }
        tutorialReport = report
    }

    /// "Part 2", "Parts 2 and 3", "Parts 2, 3 and 5" (0-based in).
    static func partList(_ parts: [Int]) -> String {
        let numbers = parts.map { String($0 + 1) }
        guard numbers.count > 1 else { return "Part \(numbers.first ?? "")" }
        return "Parts " + numbers.dropLast().joined(separator: ", ") + " and " + numbers.last!
    }

    /// Keeps (or forgets) what Hear only this Part muted, between launches.
    func rememberHearOnly(_ mutes: [Int: Int]) {
        hearOnlyRecord = mutes.isEmpty ? nil : ModxHearOnlyRecord(performance: common.name, mutes: mutes)
        ModxHearOnlyRecord.save(hearOnlyRecord)
    }

    /// Parts muted by Hear only this Part now: the tutorial's, or an earlier launch's still held by the MODX.
    var hearOnlyMuted: Set<Int> {
        if let tutorial { return Set(tutorial.mutes.keys.filter { $0 < parts.count && parts[$0].mute }) }
        return Set((hearOnlyRecord?.stillChanged(performance: common.name, parts: parts) ?? [:]).filter { $0.value == 0 }.keys)
    }

    /// The tutorial's Part no longer plays a voice of its engine: its voice was changed on the MODX's own screens
    /// (the MODX doesn't tell the app; a read finds it), so the lessons can't use it.
    var tutorialPartChanged: Bool {
        guard let session = tutorial else { return false }
        let type = parts[session.part].type
        return type != .unknown && type != session.engine.partType   // unknown: being read again (Read Again)
    }

    /// What the strip says when the tutorial's Part changed.
    var tutorialPartChangedText: String {
        guard let session = tutorial else { return "" }
        let part = parts[session.part]
        let voice = part.type == .unknown ? "another voice" : "\(part.type == .awm2 ? "an" : "a") \(part.type.rawValue) voice"
        return "Part \(session.part + 1) now plays “\(part.name)”, \(voice), so the \(session.engine.engineName) lessons can't use it."
    }

    /// Sets up a lesson's sound on the tutorial's Part. The Part is read first: if its voice was changed on the
    /// MODX's own screens since, nothing is sent (and what's sent is compared with what the MODX holds now).
    func setUpLesson(_ lesson: TutorialLesson) async {
        guard let session = tutorial, editsUnlocked, connected, tutorialBusy == nil else { return }
        let p = session.part
        tutorialBusy = "Checking Part \(p + 1) on the MODX…"
        let read = await readPartBulk(p)
        tutorialBusy = nil
        guard read != nil else {
            tutorialReport = "Couldn't read Part \(p + 1) from the MODX, so nothing was sent."
            return
        }
        guard parts[p].type == session.engine.partType else {
            tutorialReport = tutorialPartChangedText + " Nothing was sent. Put Part \(p + 1) Back brings back the \(session.engine.engineName) Part of “\(session.performance)”; End Tutorial keeps what the MODX has."
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

    /// On: mutes every other Part of the Performance that's switched on and playing, keeping each one's Mute before
    /// (between launches too). Off: puts each Part it muted back as it was. Each change is read back; the report says
    /// what was muted, what was silent already, and anything the MODX didn't take.
    func setTutorialSolo(_ solo: Bool) async {
        guard var session = tutorial, editsUnlocked, connected, tutorialBusy == nil,
              let mute = ModxParams.part.first(where: { $0.key == "part.mute" }) else { return }
        tutorialBusy = solo ? "Muting the other Parts…" : "Unmuting the other Parts…"
        defer { tutorialBusy = nil }
        let own = session.part
        let changes: [(part: Int, value: Int)] = solo
            ? partsInUse.map(\.index).filter { $0 != own && parts[$0].partSwitch && !parts[$0].mute }.map { ($0, 1) }
            : session.mutes.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        var done: [Int] = [], failed: [Int] = []
        for (q, value) in changes {
            let address = ModxTarget.part(q).base.with(low: UInt8(mute.offset))
            guard ModxLink.isWritable(address, data: [UInt8(value)]), await link.change(address, data: [UInt8(value)]) else {
                failed.append(q); continue
            }
            if solo, session.mutes[q] == nil { session.mutes[q] = 0 }
            if let read = await link.parameter(address)?.first, var block = store[ModxTarget.part(q).base] {
                var data = block.data
                data[mute.offset] = read
                block = ModxBlock(address: block.address, data: data, checksumOK: true)
                store[block.address] = block
                parts[q].read(block: block)
                if Int(read) == value { done.append(q) } else { failed.append(q) }
            } else {
                done.append(q)
            }
        }
        if solo {
            session.hearingOnly = true
        } else {
            session.mutes = session.mutes.filter { failed.contains($0.key) }
            session.hearingOnly = !session.mutes.isEmpty
        }
        tutorial = session
        rememberHearOnly(session.mutes)

        var report: String
        let silent = partsInUse.map(\.index).filter { $0 != own && !done.contains($0) && !failed.contains($0) }
        if solo {
            report = done.isEmpty ? (silent.isEmpty ? "No other Part is in use: only Part \(own + 1) plays." : "Only Part \(own + 1) plays.")
                : "Only Part \(own + 1) plays now: \(Self.partList(done)) muted."
            let off = silent.filter { !parts[$0].partSwitch }, already = silent.filter { parts[$0].partSwitch && parts[$0].mute }
            if !off.isEmpty { report += " \(Self.partList(off)) \(off.count == 1 ? "is" : "are") switched off." }
            if !already.isEmpty { report += " \(Self.partList(already)) \(already.count == 1 ? "was" : "were") muted already." }
            if parts[own].mute || !parts[own].partSwitch {
                report += " Part \(own + 1) itself is \(parts[own].mute ? "muted" : "switched off"): Set Up on the MODX switches it on and unmutes it."
            }
        } else {
            report = done.isEmpty ? "No Part needed unmuting." : "The other Parts play again: \(Self.partList(done)) unmuted."
            let stillMuted = silent.filter { parts[$0].partSwitch && parts[$0].mute }
            if !stillMuted.isEmpty { report += " \(Self.partList(stillMuted)) \(stillMuted.count == 1 ? "stays" : "stay") muted, as \(stillMuted.count == 1 ? "it was" : "they were") before." }
        }
        if !failed.isEmpty { report += " The MODX didn't take the change to \(Self.partList(failed))." }
        tutorialReport = report
    }

    /// Ends the tutorial without sending the Part back: the MODX keeps what it has (a voice chosen on its screens,
    /// or the last lesson's sound). Parts Hear only this Part muted are unmuted first.
    func endTutorial() async {
        guard let session = tutorial, tutorialBusy == nil else { return }
        if editsUnlocked, connected, !session.mutes.isEmpty || session.hearingOnly { await setTutorialSolo(false) }
        tutorial = nil
        tutorialReport = "The tutorial ended; Part \(session.part + 1) stays as the MODX has it."
            + (tutorialReport?.hasPrefix("The other Parts play again") == true ? " " + tutorialReport! : "")
    }

    /// Sends the Part back as it was when the tutorial started, and ends the tutorial.
    func putTutorialPartBack() async {
        guard let session = tutorial, editsUnlocked, connected, tutorialBusy == nil else { return }
        if !session.mutes.isEmpty || session.hearingOnly { await setTutorialSolo(false) }
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
