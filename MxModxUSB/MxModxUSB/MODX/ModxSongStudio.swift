//
//  ModxSongStudio.swift — MxModxUSB
//
//  The MIDI Songs page's song and what's done with it: open, edit, save, and play — on the MODX7 only. There are no
//  instruments here: each track plays a MIDI channel, and in the MODX's Multi mode channel n plays Part n of the
//  current Performance. Edits go through the window's undo manager (Edit ▸ Undo, ⌘Z). While a song plays the app
//  sends the MODX no SysEx at all (ModxLink.songPlaying), and never the song's own SysEx; Bank Select and Program
//  Change go only if "Send Program Changes" is on, since they change the Parts' sounds.
//

import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
@Observable
final class ModxSongStudio {
    @ObservationIgnored weak var model: ModxModel?
    @ObservationIgnored let player = ModxSongPlayer()
    @ObservationIgnored private var clock: Timer?

    var song = MIDISong()
    var fileURL: URL?
    /// Changed since it was opened or saved.
    var edited = false
    var selectedTrack: UUID?
    var selectedNotes: Set<UUID> = []
    /// Where playback starts, and where it is while playing (ticks).
    var playhead = 0
    var isPlaying = false
    var sendProgramChanges = false
    var message: String?
    /// Piano roll grid, in ticks (0: off). A sixteenth note to start with.
    var snap = 120

    init() {
        song = MIDISong()
    }

    var track: SongTrack? { song.tracks.first { $0.id == selectedTrack } }
    var hasSong: Bool { !song.tracks.isEmpty }

    // MARK: The MODX

    var destination: UInt32 { model?.link.instrumentDestination ?? 0 }

    /// Why the song can't play on the MODX now, if it can't.
    var playProblem: String? {
        guard let model, model.connected, destination != 0 else { return "Connect the MODX: songs play on the MODX7 only." }
        if model.workspaceBusy != nil || model.tutorialBusy != nil { return "Wait for the MODX to finish what it's doing." }
        return nil
    }

    /// In Single mode the MODX takes one channel only, so tracks on other channels stay silent.
    var singleChannelMode: Bool { model?.system.map { $0[0x30] == 1 } ?? false }

    func partName(_ channel: Int) -> String {
        guard let model else { return "" }
        let part = model.parts[channel]
        return part.inUse ? part.name : "(no Part)"
    }

    // MARK: Files

    func newDemo() {
        guard confirmDiscard() else { return }
        stop()
        let parts = (model?.partsInUse ?? []).map { (index: $0.index, isDrum: $0.type == .drum, name: $0.name) }
        load(MIDISong.demo(parts: parts.isEmpty ? [(0, false, "")] : parts), url: nil)
        message = "A demo song for “\(model?.common.name ?? "the MODX")”: \(song.tracks.count) tracks on its Parts. Press Play."
        edited = true
    }

    func newEmpty() {
        guard confirmDiscard() else { return }
        stop()
        var song = MIDISong()
        song.tracks = [SongTrack(name: "Track 1", channel: 0)]
        load(song, url: nil)
    }

    func open() {
        guard confirmDiscard() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.midi]
        panel.message = "Choose a Standard MIDI File (.mid) to play on the MODX."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    func open(_ url: URL) {
        stop()
        do {
            let smf = try SMF.parse(Data(contentsOf: url))
            let song = MIDISong(smf: smf, name: url.deletingPathExtension().lastPathComponent)
            load(song, url: url)
            message = "Opened \(url.lastPathComponent): \(song.tracks.count) track\(song.tracks.count == 1 ? "" : "s"), \(song.bars) bars, \(Int(song.bpm.rounded())) BPM."
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func load(_ song: MIDISong, url: URL?) {
        self.song = song
        fileURL = url
        edited = false
        selectedTrack = song.tracks.first?.id
        selectedNotes = []
        playhead = 0
    }

    @discardableResult
    func save() -> Bool {
        guard let fileURL, fileURL.pathExtension.lowercased() == "mid" || fileURL.pathExtension.lowercased() == "midi" else { return saveAs() }
        return write(to: fileURL)
    }

    @discardableResult
    func saveAs() -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.midi]
        panel.nameFieldStringValue = "\(song.name).mid"
        panel.message = "Saves a Standard MIDI File (format 1): tempo, time signature and every track."
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return write(to: url)
    }

    private func write(to url: URL) -> Bool {
        do {
            try song.smf.encode().write(to: url, options: .atomic)
            fileURL = url
            edited = false
            message = "Saved \(url.lastPathComponent)."
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    private func confirmDiscard() -> Bool {
        guard edited, hasSong else { return true }
        let alert = NSAlert()
        alert.messageText = "Save the changes to “\(song.name)”?"
        alert.informativeText = "They're lost if you don't."
        alert.addButton(withTitle: "Save…")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    // MARK: Transport

    func togglePlay() { isPlaying ? stop() : play() }

    func play() {
        guard !isPlaying, hasSong else { return }
        if let problem = playProblem { message = problem; return }
        if playhead >= song.length { playhead = 0 }
        let (events, times) = scheduled()
        let start = song.seconds(atTick: playhead)
        model?.link.songPlaying = true
        player.play(events, times: times, from: start, to: destination, audible: audibleTracks,
                    chase: chase(before: playhead)) { [weak self] in self?.stop() }
        isPlaying = true
        message = nil
        clock = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let seconds = self.player.position else { return }
                self.playhead = max(0, self.song.tick(atSeconds: seconds))
            }
        }
    }

    func stop() {
        clock?.invalidate()
        clock = nil
        let was = isPlaying
        player.stop()
        isPlaying = false
        model?.link.songPlaying = false
        if was, playhead > song.length { playhead = song.length }
    }

    func rewind() {
        let playing = isPlaying
        if playing { stop() }
        playhead = 0
        if playing { play() }
    }

    func setPlayhead(_ tick: Int) {
        let playing = isPlaying
        if playing { stop() }
        playhead = max(0, tick)
        if playing { play() }
    }

    /// Note Off everywhere: All Notes Off and Sustain off on all 16 channels of the MODX.
    func panic() {
        stop()
        for ch in 0..<16 {
            player.send([0xB0 | UInt8(ch), 64, 0], to: destination)
            player.send([0xB0 | UInt8(ch), 123, 0], to: destination)
        }
        message = "Sent All Notes Off on every channel."
    }

    private func scheduled() -> ([MIDISong.PlayEvent], [Double]) {
        let events = song.playEvents(sendProgramChanges: sendProgramChanges)
        return (events, events.map { song.seconds(atTick: $0.tick) })
    }

    /// Each track's latest controller and pitch bend before `tick` (and program, if they're sent).
    private func chase(before tick: Int) -> [MIDISong.PlayEvent] {
        guard tick > 0 else { return [] }
        var last: [String: MIDISong.PlayEvent] = [:]
        for e in song.playEvents(sendProgramChanges: sendProgramChanges) where e.tick < tick && !e.isNoteOn && e.bytes[0] & 0xF0 != 0x80 {
            let kind = e.bytes[0] & 0xF0
            last["\(e.track)-\(kind)-\(kind == 0xB0 ? e.bytes[1] : 0)"] = e
        }
        return Array(last.values)
    }

    /// The song changed: if it's playing, play the new version from here.
    private func changed() {
        edited = true
        if isPlaying {
            let (events, times) = scheduled()
            player.replace(events, times: times)
        }
    }

    // MARK: Tracks

    var audibleTracks: Set<UUID> {
        let soloed = song.tracks.filter(\.soloed)
        return Set((soloed.isEmpty ? song.tracks.filter { !$0.muted } : soloed).map(\.id))
    }

    func setMute(_ id: UUID, _ on: Bool) {
        guard let i = song.tracks.firstIndex(where: { $0.id == id }) else { return }
        song.tracks[i].muted = on
        player.setAudible(audibleTracks)
    }

    func setSolo(_ id: UUID, _ on: Bool) {
        guard let i = song.tracks.firstIndex(where: { $0.id == id }) else { return }
        song.tracks[i].soloed = on
        player.setAudible(audibleTracks)
    }

    /// An undoable change to the song (Edit ▸ Undo).
    func edit(_ action: String, _ undo: UndoManager?, _ change: (inout MIDISong) -> Void) {
        let before = song
        change(&song)
        guard song != before else { return }
        register(before, action, undo)
        selectedNotes = selectedNotes.filter { id in song.tracks.contains { $0.notes.contains { $0.id == id } } }
        changed()
    }

    private func register(_ previous: MIDISong, _ action: String, _ undo: UndoManager?) {
        undo?.registerUndo(withTarget: self) { studio in
            let current = studio.song
            studio.song = previous
            studio.register(current, action, undo)
            studio.changed()
        }
        undo?.setActionName(action)
    }

    func addTrack(_ undo: UndoManager?) {
        let used = Set(song.tracks.map(\.channel))
        let channel = (0..<16).first { !used.contains($0) && (model?.parts[$0].inUse ?? false) } ?? (0..<16).first { !used.contains($0) } ?? 0
        let track = SongTrack(name: "Track \(song.tracks.count + 1)", channel: channel)
        edit("Add Track", undo) { $0.tracks.append(track) }
        selectedTrack = track.id
    }

    func deleteTrack(_ id: UUID, _ undo: UndoManager?) {
        edit("Delete Track", undo) { $0.tracks.removeAll { $0.id == id } }
        if selectedTrack == id { selectedTrack = song.tracks.first?.id }
        player.setAudible(audibleTracks)
    }

    func setChannel(_ id: UUID, _ channel: Int, _ undo: UndoManager?) {
        edit("Change Channel", undo) { song in
            if let i = song.tracks.firstIndex(where: { $0.id == id }) { song.tracks[i].setChannel(channel) }
        }
    }

    func rename(_ id: UUID, _ name: String, _ undo: UndoManager?) {
        edit("Rename Track", undo) { song in
            if let i = song.tracks.firstIndex(where: { $0.id == id }) { song.tracks[i].name = name }
        }
    }

    /// The mixer: a controller (7 volume, 10 pan) sent to the MODX at once; `commit` saves it at the song's start.
    func setController(_ id: UUID, _ number: UInt8, _ value: Int, commit: Bool, _ undo: UndoManager?) {
        guard let track = song.tracks.first(where: { $0.id == id }) else { return }
        player.send([0xB0 | UInt8(track.channel), number, UInt8(clamping: max(0, min(127, value)))], to: destination)
        guard commit else { return }
        edit(number == 7 ? "Change Volume" : "Change Pan", undo) { song in
            if let i = song.tracks.firstIndex(where: { $0.id == id }) { song.tracks[i].setController(number, value) }
        }
    }

    func setTempo(_ bpm: Double, _ undo: UndoManager?) {
        edit("Change Tempo", undo) { $0.setTempo(bpm) }
        if isPlaying { setPlayhead(playhead) }   // restart on the new tempo
    }

    // MARK: Notes

    func preview(_ key: Int, velocity: Int = 96) {
        guard let track, destination != 0 else { return }
        player.preview(channel: track.channel, key: key, velocity: velocity, to: destination)
    }

    func addNote(tick: Int, key: Int, _ undo: UndoManager?) {
        guard let id = selectedTrack else { return }
        let length = snap > 0 ? snap : song.division / 4
        let note = SongNote(tick: max(0, tick), length: length, key: max(0, min(127, key)), velocity: 96)
        edit("Add Note", undo) { song in
            if let i = song.tracks.firstIndex(where: { $0.id == id }) { song.tracks[i].notes.append(note) }
        }
        selectedNotes = [note.id]
        preview(note.key)
    }

    /// Moves (dTick, dKey) or lengthens (dLength) the selected notes.
    func changeSelected(_ action: String, dTick: Int = 0, dKey: Int = 0, dLength: Int = 0, velocity: Int? = nil, _ undo: UndoManager?) {
        guard let id = selectedTrack, !selectedNotes.isEmpty else { return }
        let ids = selectedNotes
        edit(action, undo) { song in
            guard let i = song.tracks.firstIndex(where: { $0.id == id }) else { return }
            for j in song.tracks[i].notes.indices where ids.contains(song.tracks[i].notes[j].id) {
                song.tracks[i].notes[j].tick = max(0, song.tracks[i].notes[j].tick + dTick)
                song.tracks[i].notes[j].key = max(0, min(127, song.tracks[i].notes[j].key + dKey))
                song.tracks[i].notes[j].length = max(10, song.tracks[i].notes[j].length + dLength)
                if let velocity { song.tracks[i].notes[j].velocity = max(1, min(127, velocity)) }
            }
            song.tracks[i].notes.sort { ($0.tick, $0.key) < ($1.tick, $1.key) }
        }
    }

    func deleteSelected(_ undo: UndoManager?) {
        guard let id = selectedTrack, !selectedNotes.isEmpty else { return }
        let ids = selectedNotes
        edit("Delete Notes", undo) { song in
            if let i = song.tracks.firstIndex(where: { $0.id == id }) { song.tracks[i].notes.removeAll { ids.contains($0.id) } }
        }
        selectedNotes = []
    }

    /// Moves the selected notes' starts (all the track's, if none is selected) to the nearest grid line.
    func quantize(_ undo: UndoManager?) {
        guard let id = selectedTrack, snap > 0 else { return }
        let ids = selectedNotes, grid = snap
        edit("Quantize", undo) { song in
            guard let i = song.tracks.firstIndex(where: { $0.id == id }) else { return }
            for j in song.tracks[i].notes.indices where ids.isEmpty || ids.contains(song.tracks[i].notes[j].id) {
                let t = song.tracks[i].notes[j].tick
                song.tracks[i].notes[j].tick = Int((Double(t) / Double(grid)).rounded()) * grid
            }
            song.tracks[i].notes.sort { ($0.tick, $0.key) < ($1.tick, $1.key) }
        }
    }

    func selectAll() {
        selectedNotes = Set(track?.notes.map(\.id) ?? [])
    }
}
