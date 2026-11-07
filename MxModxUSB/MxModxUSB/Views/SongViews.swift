//
//  SongViews.swift — MxModxUSB
//
//  The MIDI Songs page, laid out like a very small Logic Pro: a control bar (transport, position, tempo), the tracks
//  — headers with name, channel (the MODX Part it plays), Mute and Solo — beside a timeline, and below them the
//  Piano Roll or the Mixer; the lessons on the right. Everything plays on the MODX7; there are no instruments here.
//

import SwiftUI

struct SongView: View {
    let model: ModxModel
    @Bindable private var studio: ModxSongStudio
    @Environment(\.undoManager) private var undo
    @AppStorage("songEditor") private var editor = "pianoRoll"
    @AppStorage("songLessonsShown") private var lessonsShown = true
    @State private var pixelsPerBeat: CGFloat = 32

    init(model: ModxModel) {
        self.model = model
        studio = model.studio
    }

    var body: some View {
        VStack(spacing: 0) {
            SongControlBar(studio: studio, lessonsShown: $lessonsShown)
            Divider()
            notices
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if studio.hasSong {
                        TracksArea(studio: studio, pixelsPerBeat: pixelsPerBeat)
                        Divider()
                        editorPane
                    } else {
                        emptyState
                    }
                }
                if lessonsShown {
                    Divider()
                    SongLessonsPanel()
                        .frame(width: 300)
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) {
            studio.togglePlay()
            return .handled
        }
    }

    @ViewBuilder private var notices: some View {
        if !model.connected {
            notice("Connect the MODX: songs play on the MODX7 only (its USB Port 1).", "cable.connector")
        } else if studio.singleChannelMode {
            notice("The MODX is in MIDI I/O Mode Single, so it plays one channel only. For a track per Part, set Multi (UTILITY ▸ Settings ▸ MIDI I/O).", "exclamationmark.triangle")
        } else if studio.isPlaying {
            notice("Playing on the MODX. The app asks the MODX nothing while a song plays, and catches up when it stops.", "play.circle")
        } else if let message = studio.message {
            notice(message, "info.circle")
        }
    }

    private func notice(_ text: String, _ icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(Modx.accent)
            Text(text).font(.callout).lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(Modx.accent.opacity(0.07))
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            ContentUnavailableView("No song yet", systemImage: "music.note.list",
                                   description: Text("Make a demo song for the Parts the MODX is playing, start an empty one, or open a Standard MIDI File (.mid). Every note plays on the MODX7."))
            HStack {
                Button("New Demo Song") { studio.newDemo() }.buttonStyle(.borderedProminent)
                Button("New Empty Song") { studio.newEmpty() }
                Button("Open…") { studio.open() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var editorPane: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $editor) {
                    Text("Piano Roll").tag("pianoRoll")
                    Text("Mixer").tag("mixer")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .quickHelp("Piano Roll / Mixer", "The editor under the tracks: the Piano Roll edits the selected track's notes; the Mixer sets each track's volume, pan, mute and solo.")
                Spacer()
                if editor == "pianoRoll" {
                    Text("Zoom").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $pixelsPerBeat, in: 12...96).frame(width: 110).controlSize(.small)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            if editor == "mixer" {
                MixerView(studio: studio)
            } else {
                PianoRollView(studio: studio, pixelsPerBeat: pixelsPerBeat)
            }
        }
        .frame(height: 300)
    }
}

// MARK: - Control bar

private struct SongControlBar: View {
    @Bindable var studio: ModxSongStudio
    @Binding var lessonsShown: Bool
    @Environment(\.undoManager) private var undo
    @State private var tempoText = ""

    var body: some View {
        HStack(spacing: 10) {
            Button { studio.rewind() } label: { Image(systemName: "backward.end.fill") }
                .help("Go to the start")
                .accessibilityLabel("Go to Start")
                .quickHelp("Go to Start", "Moves the playhead to the start of the song.", symbol: "backward.end.fill")
            Button { studio.togglePlay() } label: {
                Image(systemName: studio.isPlaying ? "stop.fill" : "play.fill").frame(width: 18)
            }
            .buttonStyle(.borderedProminent)
            .tint(studio.isPlaying ? .red : .accentColor)
            .disabled(!studio.hasSong)
            .help(studio.isPlaying ? "Stop (Space)" : "Play on the MODX (Space)")
            .quickHelp(studio.isPlaying ? "Stop" : "Play", "Plays the song on the MODX7 from the playhead — its USB Port 1 only. Stop releases every note. Space plays and stops.", shortcut: "Space", symbol: "play.fill")
            VStack(alignment: .leading, spacing: 0) {
                Text(studio.song.position(studio.playhead)).font(.system(.title3, design: .monospaced).weight(.semibold))
                Text(clock).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .frame(width: 96, alignment: .leading)
            .quickHelp("Position", "Bar . beat . sixteenth, and minutes and seconds, of the playhead.", symbol: "clock")
            HStack(spacing: 4) {
                TextField("", text: $tempoText)
                    .frame(width: 48).multilineTextAlignment(.trailing)
                    .onSubmit { if let bpm = Double(tempoText) { studio.setTempo(bpm, undo) }; tempoText = tempoString }
                Text("BPM").font(.caption).foregroundStyle(.secondary)
                Text("\(studio.song.beatsPerBar)/\(studio.song.beatUnit)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            .disabled(!studio.hasSong)
            .quickHelp("Tempo", "The song's tempo in beats per minute (20–300): the notes stay where they are, the song plays faster or slower. Press Return to set it.", symbol: "metronome")
            Divider().frame(height: 22)
            Toggle("Send Program Changes", isOn: $studio.sendProgramChanges)
                .toggleStyle(.checkbox).font(.callout)
                .help("Also send the song's Bank Select and Program Change (they replace the MODX Parts' sounds)")
                .quickHelp("Send Program Changes", "Off: the current Performance's sounds play the song. On: the song's own Bank Select and Program Change are sent too, and replace the Parts' sounds in the MODX's edit buffer.")
            Button("Panic") { studio.panic() }
                .help("All Notes Off on every channel of the MODX")
                .quickHelp("Panic", "Stops the song and sends All Notes Off and Sustain off on all 16 channels of the MODX.")
            Spacer()
            Text(studio.song.name + (studio.edited ? " — Edited" : "")).foregroundStyle(.secondary).lineLimit(1)
            Menu("New") {
                Button("Demo Song") { studio.newDemo() }
                Button("Empty Song") { studio.newEmpty() }
            }
            .fixedSize()
            .quickHelp("New", "Demo Song: eight bars written for the Parts the MODX is playing. Empty Song: one empty track.")
            Button("Open…") { studio.open() }
                .quickHelp("Open", "Opens a Standard MIDI File (.mid); tracks with several channels are split into one track per channel.")
            Button("Save") { studio.save() }
                .disabled(!studio.hasSong)
                .quickHelp("Save", "Saves the song as a Standard MIDI File (format 1) with its tempo, tracks, notes and mix.")
            Button { lessonsShown.toggle() } label: { Image(systemName: "sidebar.right") }
                .help(lessonsShown ? "Hide the lessons" : "Show the lessons")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .onAppear { tempoText = tempoString }
        .onChange(of: studio.song.bpm) { tempoText = tempoString }
    }

    private var tempoString: String { String(format: studio.song.bpm.rounded() == studio.song.bpm ? "%.0f" : "%.1f", studio.song.bpm) }

    private var clock: String {
        let s = studio.song.seconds(atTick: studio.playhead)
        return String(format: "%d:%04.1f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
    }
}

// MARK: - Tracks

private let headerWidth: CGFloat = 250
private let laneHeight: CGFloat = 46
private let rulerHeight: CGFloat = 22

private func trackColor(_ channel: Int) -> Color { Modx.partColors[channel % 16] }

private struct TracksArea: View {
    @Bindable var studio: ModxSongStudio
    let pixelsPerBeat: CGFloat
    @Environment(\.undoManager) private var undo

    private var song: MIDISong { studio.song }
    private var width: CGFloat { CGFloat(song.bars + 4) * CGFloat(song.beatsPerBar) * pixelsPerBeat }

    var body: some View {
        ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    HStack {
                        Text("Tracks").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Button { studio.addTrack(undo) } label: { Image(systemName: "plus") }
                            .buttonStyle(.borderless)
                            .help("Add a track")
                            .quickHelp("Add Track", "Adds an empty track on the next channel whose Part the MODX has in use.", symbol: "plus")
                    }
                    .padding(.horizontal, 8)
                    .frame(height: rulerHeight)
                    ForEach(song.tracks) { track in TrackHeader(studio: studio, track: track) }
                }
                .frame(width: headerWidth)
                Divider()
                ScrollView(.horizontal) {
                    VStack(spacing: 0) {
                        Ruler(song: song, pixelsPerBeat: pixelsPerBeat, width: width) { studio.setPlayhead($0) }
                        ForEach(song.tracks) { track in
                            Lane(song: song, track: track, pixelsPerBeat: pixelsPerBeat, width: width, selected: studio.selectedTrack == track.id,
                                 audible: studio.audibleTracks.contains(track.id))
                                .onTapGesture { studio.selectedTrack = track.id }
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        Rectangle().fill(Color.red).frame(width: 1.5)
                            .offset(x: CGFloat(studio.playhead) / CGFloat(song.ticksPerBeat) * pixelsPerBeat)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .frame(minHeight: 140)
        .quickHelpArea("Tracks", "Each track plays one MIDI channel — in the MODX's Multi mode, channel n is Part n. Click the ruler to move the playhead; click a track to edit it below.")
    }
}

private struct TrackHeader: View {
    @Bindable var studio: ModxSongStudio
    let track: SongTrack
    @Environment(\.undoManager) private var undo
    @State private var name = ""

    var body: some View {
        let selected = studio.selectedTrack == track.id
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(trackColor(track.channel)).frame(width: 5)
            VStack(alignment: .leading, spacing: 2) {
                TextField("Name", text: $name)
                    .textFieldStyle(.plain).font(.callout.weight(.medium))
                    .onSubmit { if name != track.name { studio.rename(track.id, name, undo) } }
                Menu {
                    ForEach(0..<16, id: \.self) { ch in
                        Button("Ch \(ch + 1) · Part \(ch + 1) \(studio.partName(ch))") { studio.setChannel(track.id, ch, undo) }
                    }
                } label: {
                    Text("Ch \(track.channel + 1) · \(studio.partName(track.channel))").font(.caption).lineLimit(1)
                }
                .menuStyle(.button).buttonStyle(.plain).fixedSize()
                .foregroundStyle(.secondary)
                .quickHelp("Channel", "The MIDI channel this track plays — in Multi mode, channel n is Part n of the current Performance, so this chooses the MODX sound.")
            }
            Spacer(minLength: 2)
            MSButton(title: "M", on: track.muted, color: .cyan) { studio.setMute(track.id, !track.muted) }
                .help(track.muted ? "Unmute" : "Mute")
                .quickHelp("Mute", "Silences this track (now, if the song is playing). Not saved in the file.", symbol: "speaker.slash")
            MSButton(title: "S", on: track.soloed, color: .yellow) { studio.setSolo(track.id, !track.soloed) }
                .help(track.soloed ? "Unsolo" : "Solo")
                .quickHelp("Solo", "Plays only soloed tracks. Not saved in the file.", symbol: "s.circle")
        }
        .padding(.horizontal, 8)
        .frame(height: laneHeight)
        .background(selected ? Color.accentColor.opacity(0.14) : Color.clear)
        .overlay(alignment: .bottom) { Divider() }
        .contentShape(Rectangle())
        .onTapGesture { studio.selectedTrack = track.id }
        .contextMenu { Button("Delete Track", role: .destructive) { studio.deleteTrack(track.id, undo) } }
        .onAppear { name = track.name }
        .onChange(of: track.name) { name = track.name }
    }
}

private struct Ruler: View {
    let song: MIDISong
    let pixelsPerBeat: CGFloat
    let width: CGFloat
    let moveTo: (Int) -> Void

    var body: some View {
        Canvas { context, size in
            let barWidth = CGFloat(song.beatsPerBar) * pixelsPerBeat
            var bar = 0
            while CGFloat(bar) * barWidth < size.width {
                let x = CGFloat(bar) * barWidth
                context.stroke(Path { $0.move(to: CGPoint(x: x, y: 10)); $0.addLine(to: CGPoint(x: x, y: size.height)) }, with: .color(.secondary), lineWidth: 1)
                context.draw(Text("\(bar + 1)").font(.caption2).foregroundColor(.secondary), at: CGPoint(x: x + 8, y: 7))
                bar += 1
            }
        }
        .frame(width: width, height: rulerHeight)
        .background(Color.secondary.opacity(0.08))
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { value in
            moveTo(Int(value.location.x / pixelsPerBeat * CGFloat(song.ticksPerBeat)))
        })
        .help("Click to move the playhead")
    }
}

private struct Lane: View {
    let song: MIDISong
    let track: SongTrack
    let pixelsPerBeat: CGFloat
    let width: CGFloat
    let selected: Bool
    /// Not muted, and soloed if anything is: dimmed otherwise, as Logic Pro dims them.
    var audible = true

    var body: some View {
        Canvas { context, size in
            let barWidth = CGFloat(song.beatsPerBar) * pixelsPerBeat
            let quiet = !audible
            var x: CGFloat = 0
            while x < size.width {
                context.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) }, with: .color(.secondary.opacity(0.18)), lineWidth: 1)
                x += barWidth
            }
            guard !track.notes.isEmpty else { return }
            let low = track.notes.map(\.key).min()!, high = track.notes.map(\.key).max()!
            let span = CGFloat(max(12, high - low + 1))
            let color = trackColor(track.channel)
            let region = CGRect(x: 0, y: 3, width: CGFloat(track.lastTick) / CGFloat(song.ticksPerBeat) * pixelsPerBeat, height: size.height - 6)
            context.fill(Path(roundedRect: region, cornerRadius: 4), with: .color(color.opacity(quiet ? 0.07 : 0.22)))
            for n in track.notes {
                let x = CGFloat(n.tick) / CGFloat(song.ticksPerBeat) * pixelsPerBeat
                let w = max(1.5, CGFloat(n.length) / CGFloat(song.ticksPerBeat) * pixelsPerBeat)
                let y = 5 + (1 - CGFloat(n.key - low) / span) * (size.height - 12)
                context.fill(Path(CGRect(x: x, y: y, width: w, height: 2.5)), with: .color(quiet ? Color.secondary.opacity(0.35) : color))
            }
        }
        .frame(width: width, height: laneHeight)
        .background(selected ? Color.accentColor.opacity(0.06) : Color.clear)
        .overlay(alignment: .bottom) { Divider() }
        .contentShape(Rectangle())
    }
}

// MARK: - Piano roll

private let keyHeight: CGFloat = 11

private struct PianoRollView: View {
    @Bindable var studio: ModxSongStudio
    let pixelsPerBeat: CGFloat
    @Environment(\.undoManager) private var undo
    @State private var velocity: Double = 96

    private var song: MIDISong { studio.song }

    var body: some View {
        if let track = studio.track {
            VStack(spacing: 0) {
                toolbar(track)
                Divider()
                ScrollViewReader { reader in
                    ScrollView(.vertical) {
                        HStack(alignment: .top, spacing: 0) {
                            Keyboard(studio: studio)
                            ScrollView(.horizontal) {
                                NoteGrid(studio: studio, track: track, pixelsPerBeat: pixelsPerBeat)
                            }
                        }
                    }
                    .onAppear { reader.scrollTo(centerKey(track), anchor: .center) }
                    .onChange(of: studio.selectedTrack) { if let t = studio.track { reader.scrollTo(centerKey(t), anchor: .center) } }
                }
            }
            .onDeleteCommand { studio.deleteSelected(undo) }
        } else {
            ContentUnavailableView("Select a track", systemImage: "pianokeys", description: Text("Click a track above to edit its notes."))
        }
    }

    private func centerKey(_ track: SongTrack) -> Int {
        guard !track.notes.isEmpty else { return 60 }
        return (track.notes.map(\.key).min()! + track.notes.map(\.key).max()!) / 2
    }

    private func toolbar(_ track: SongTrack) -> some View {
        HStack(spacing: 8) {
            Text(track.name).font(.callout.weight(.semibold)).lineLimit(1)
            Text("\(track.notes.count) notes" + (studio.selectedNotes.isEmpty ? "" : " · \(studio.selectedNotes.count) selected"))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Picker("Grid", selection: $studio.snap) {
                Text("Off").tag(0)
                Text("1/4").tag(song.division)
                Text("1/8").tag(song.division / 2)
                Text("1/16").tag(song.division / 4)
                Text("1/32").tag(song.division / 8)
            }
            .fixedSize()
            .quickHelp("Grid", "New notes are this long, and moves, lengths and Quantize snap to it.")
            if !studio.selectedNotes.isEmpty {
                Text("Velocity").font(.caption).foregroundStyle(.secondary)
                Slider(value: $velocity, in: 1...127) { editing in
                    if !editing { studio.changeSelected("Change Velocity", velocity: Int(velocity), undo) }
                }
                .frame(width: 90).controlSize(.small)
                Text("\(Int(velocity))").font(.caption.monospacedDigit()).frame(width: 26)
            }
            Button("Quantize") { studio.quantize(undo) }
                .disabled(studio.snap == 0)
                .quickHelp("Quantize", "Moves the selected notes' starts (or all the track's, with none selected) to the nearest grid line.")
            ControlGroup {
                Button("−12") { studio.changeSelected("Transpose", dKey: -12, undo) }
                Button("−1") { studio.changeSelected("Transpose", dKey: -1, undo) }
                Button("+1") { studio.changeSelected("Transpose", dKey: 1, undo) }
                Button("+12") { studio.changeSelected("Transpose", dKey: 12, undo) }
            }
            .disabled(studio.selectedNotes.isEmpty)
            .fixedSize()
            .quickHelp("Transpose", "Moves the selected notes down or up a semitone or an octave.")
            Button { studio.deleteSelected(undo) } label: { Image(systemName: "trash") }
                .disabled(studio.selectedNotes.isEmpty)
                .help("Delete the selected notes (Delete)")
            Button("Select All") { studio.selectAll() }
        }
        .controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 5)
        .onChange(of: studio.selectedNotes) {
            if let first = studio.track?.notes.first(where: { studio.selectedNotes.contains($0.id) }) { velocity = Double(first.velocity) }
        }
    }
}

private struct Keyboard: View {
    let studio: ModxSongStudio

    var body: some View {
        VStack(spacing: 0) {
            ForEach((0..<128).reversed(), id: \.self) { key in
                let black = [1, 3, 6, 8, 10].contains(key % 12)
                ZStack(alignment: .leading) {
                    Rectangle().fill(black ? Color(white: 0.18) : Color(white: 0.96))
                    if key % 12 == 0 {
                        Text(ModxNames.note(key)).font(.system(size: 8)).foregroundStyle(.black).padding(.leading, 3)
                    }
                }
                .frame(width: 44, height: keyHeight)
                .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.15)).frame(height: 0.5) }
                .id(key)
                .onTapGesture { studio.preview(key) }
            }
        }
        .quickHelpArea("Keys", "Click a key to hear it on the MODX, on the track's channel. C3 is middle C, as the MODX names it.")
    }
}

private struct NoteGrid: View {
    @Bindable var studio: ModxSongStudio
    let track: SongTrack
    let pixelsPerBeat: CGFloat
    @Environment(\.undoManager) private var undo

    private enum Drag { case none, create(tick: Int, key: Int), move, resize }
    @State private var drag: Drag = .none
    @State private var offset: CGSize = .zero

    private var song: MIDISong { studio.song }
    private var width: CGFloat { CGFloat(song.bars + 4) * CGFloat(song.beatsPerBar) * pixelsPerBeat }
    private func x(_ tick: Int) -> CGFloat { CGFloat(tick) / CGFloat(song.ticksPerBeat) * pixelsPerBeat }
    private func y(_ key: Int) -> CGFloat { CGFloat(127 - key) * keyHeight }
    private func tick(_ x: CGFloat) -> Int { max(0, Int(x / pixelsPerBeat * CGFloat(song.ticksPerBeat))) }
    private func key(_ y: CGFloat) -> Int { max(0, min(127, 127 - Int(y / keyHeight))) }
    private func snapped(_ t: Int) -> Int { studio.snap > 0 ? Int((Double(t) / Double(studio.snap)).rounded(.down)) * studio.snap : t }
    private func snappedDelta(_ t: Int) -> Int { studio.snap > 0 ? Int((Double(t) / Double(studio.snap)).rounded()) * studio.snap : t }

    var body: some View {
        Canvas { context, size in
            for key in 0..<128 where [1, 3, 6, 8, 10].contains(key % 12) {
                context.fill(Path(CGRect(x: 0, y: y(key), width: size.width, height: keyHeight)), with: .color(Color.secondary.opacity(0.08)))
            }
            for key in stride(from: 0, to: 128, by: 12) {
                context.stroke(Path { $0.move(to: CGPoint(x: 0, y: y(key) + keyHeight)); $0.addLine(to: CGPoint(x: size.width, y: y(key) + keyHeight)) },
                               with: .color(.secondary.opacity(0.25)), lineWidth: 0.6)
            }
            var beat = 0
            while CGFloat(beat) * pixelsPerBeat < size.width {
                let bx = CGFloat(beat) * pixelsPerBeat
                let isBar = beat % song.beatsPerBar == 0
                context.stroke(Path { $0.move(to: CGPoint(x: bx, y: 0)); $0.addLine(to: CGPoint(x: bx, y: size.height)) },
                               with: .color(.secondary.opacity(isBar ? 0.4 : 0.15)), lineWidth: isBar ? 1 : 0.5)
                beat += 1
            }
            let color = trackColor(track.channel)
            for n in track.notes {
                let selected = studio.selectedNotes.contains(n.id)
                var rect = CGRect(x: x(n.tick), y: y(n.key) + 1, width: max(3, x(n.end) - x(n.tick)), height: keyHeight - 2)
                if selected {
                    switch drag {
                    case .move:
                        rect.origin.x = x(max(0, n.tick + snappedDelta(tick(offset.width))))
                        rect.origin.y = y(max(0, min(127, n.key - Int((offset.height / keyHeight).rounded())))) + 1
                    case .resize:
                        rect.size.width = max(3, x(max(10, n.length + snappedDelta(tick(offset.width)))))
                    default: break
                    }
                }
                let path = Path(roundedRect: rect, cornerRadius: 2)
                context.fill(path, with: .color(color.opacity(0.35 + 0.65 * Double(n.velocity) / 127)))
                if selected { context.stroke(path, with: .color(.primary), lineWidth: 1.5) }
            }
            context.fill(Path(CGRect(x: x(studio.playhead), y: 0, width: 1.5, height: size.height)), with: .color(.red))
        }
        .frame(width: width, height: CGFloat(128) * keyHeight)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if case .none = drag { begin(at: value.startLocation) }
                offset = value.translation
            }
            .onEnded { value in finish(value) })
        .quickHelpArea("Piano Roll", "The selected track's notes: pitch up the side, time across. Click an empty place to add a note; drag a note to move it, or its right end to lengthen it; Shift-click to select several; Delete removes them. ⌘Z undoes.")
    }

    private func note(at point: CGPoint) -> SongNote? {
        track.notes.last { n in
            CGRect(x: x(n.tick), y: y(n.key), width: max(4, x(n.end) - x(n.tick)), height: keyHeight).contains(point)
        }
    }

    private func begin(at point: CGPoint) {
        studio.selectedTrack = track.id
        if let n = note(at: point) {
            if NSEvent.modifierFlags.contains(.shift) {
                if studio.selectedNotes.contains(n.id) { studio.selectedNotes.remove(n.id) } else { studio.selectedNotes.insert(n.id) }
            } else if !studio.selectedNotes.contains(n.id) {
                studio.selectedNotes = [n.id]
            }
            drag = point.x > x(n.end) - 5 ? .resize : .move
            studio.preview(n.key, velocity: n.velocity)
        } else {
            drag = .create(tick: snapped(tick(point.x)), key: key(point.y))
            if !NSEvent.modifierFlags.contains(.shift) { studio.selectedNotes = [] }
        }
    }

    private func finish(_ value: DragGesture.Value) {
        defer { drag = .none; offset = .zero }
        let moved = abs(value.translation.width) > 3 || abs(value.translation.height) > 3
        switch drag {
        case .create(let t, let k):
            if !moved { studio.addNote(tick: t, key: k, undo) }
        case .move:
            let dTick = snappedDelta(tick(value.translation.width)), dKey = -Int((value.translation.height / keyHeight).rounded())
            if moved, dTick != 0 || dKey != 0 { studio.changeSelected("Move Notes", dTick: dTick, dKey: dKey, undo) }
        case .resize:
            let dLength = snappedDelta(tick(value.translation.width))
            if moved, dLength != 0 { studio.changeSelected("Change Length", dLength: dLength, undo) }
        case .none:
            break
        }
    }
}

// MARK: - Mixer

private struct MixerView: View {
    @Bindable var studio: ModxSongStudio

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(studio.song.tracks) { track in ChannelStrip(studio: studio, track: track) }
            }
            .padding(12)
        }
        .quickHelpArea("Mixer", "A strip for each track: pan and volume (sent to the MODX as Controller 10 and 7 on the track's channel, and saved at the start of the song), mute and solo.")
    }
}

private struct ChannelStrip: View {
    @Bindable var studio: ModxSongStudio
    let track: SongTrack
    @Environment(\.undoManager) private var undo
    @State private var volume: Double = 100
    @State private var pan: Double = 64

    var body: some View {
        let selected = studio.selectedTrack == track.id
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(trackColor(track.channel)).frame(height: 4)
            Text(track.name).font(.caption.weight(.semibold)).lineLimit(1)
            Text("Ch \(track.channel + 1) · \(studio.partName(track.channel))").font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            VStack(spacing: 1) {
                Slider(value: $pan, in: 0...127) { editing in
                    if !editing { studio.setController(track.id, 10, Int(pan), commit: true, undo) }
                }
                .controlSize(.mini)
                .onChange(of: pan) { studio.setController(track.id, 10, Int(pan), commit: false, undo) }
                Text(ModxNames.pan(UInt8(Int(pan)))).font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
            }
            .quickHelp("Pan", "Where the track sits left to right: Controller 10 on its channel, sent now and saved at the start of the song.")
            Fader(value: $volume) { studio.setController(track.id, 7, Int(volume), commit: true, undo) }
                .onChange(of: volume) { studio.setController(track.id, 7, Int(volume), commit: false, undo) }
                .quickHelp("Volume", "The track's level: Controller 7 on its channel, sent now and saved at the start of the song.")
            Text("\(Int(volume))").font(.caption.monospacedDigit())
            HStack(spacing: 4) {
                MSButton(title: "M", on: track.muted, color: .cyan) { studio.setMute(track.id, !track.muted) }
                MSButton(title: "S", on: track.soloed, color: .yellow) { studio.setSolo(track.id, !track.soloed) }
            }
        }
        .padding(8)
        .frame(width: 96)
        .background(selected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .onTapGesture { studio.selectedTrack = track.id }
        .onAppear { volume = Double(track.volume); pan = Double(track.pan) }
        .onChange(of: track.volume) { volume = Double(track.volume) }
        .onChange(of: track.pan) { pan = Double(track.pan) }
    }
}

/// A vertical fader, 0–127.
private struct Fader: View {
    @Binding var value: Double
    let committed: () -> Void
    private let height: CGFloat = 130

    var body: some View {
        GeometryReader { geo in
            let y = (1 - value / 127) * (geo.size.height - 14)
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.3)).frame(width: 4).frame(maxHeight: .infinity)
                RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.85)).frame(width: 30, height: 14)
                    .overlay(Rectangle().fill(Color.black.opacity(0.5)).frame(height: 1))
                    .shadow(radius: 1)
                    .offset(y: y)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in value = max(0, min(127, (1 - (drag.location.y - 7) / (geo.size.height - 14)) * 127)).rounded() }
                .onEnded { _ in committed() })
        }
        .frame(width: 40, height: height)
    }
}

// MARK: - Lessons

private struct SongLessonsPanel: View {
    @Bindable private var settings = ModxSettings.shared
    @AppStorage("songLesson") private var lessonID = "song.what"

    private var lessons: [TutorialLesson] { ModxSongLessons.lessons.filter(settings.shows) }
    private var lesson: TutorialLesson? { lessons.first { $0.id == lessonID } ?? lessons.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Lessons").font(.headline)
                Spacer()
                Picker("", selection: $settings.guidance) {
                    ForEach(ModxGuidance.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().fixedSize()
                .help("How much the lessons teach (also Settings ▸ Guidance)")
            }
            .padding(10)
            Picker("", selection: Binding(get: { lesson?.id ?? "" }, set: { lessonID = $0 })) {
                ForEach(Array(lessons.enumerated()), id: \.element.id) { i, l in Text("\(i + 1). \(l.title)").tag(l.id) }
            }
            .labelsHidden()
            .padding(.horizontal, 10)
            Divider().padding(.top, 8)
            if let lesson {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(lesson.title).font(.title3.weight(.semibold))
                        if settings.showsIntroductions { Text(lesson.goal).foregroundStyle(.secondary) }
                        if settings.showsTheory {
                            ForEach(Array(lesson.theory.enumerated()), id: \.offset) { _, text in
                                Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        if !lesson.steps.isEmpty {
                            Text("Try this").font(.callout.weight(.semibold)).padding(.top, 4)
                            ForEach(Array(lesson.steps.enumerated()), id: \.offset) { i, text in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text("\(i + 1).").monospacedDigit().foregroundStyle(.secondary)
                                    Text(text).fixedSize(horizontal: false, vertical: true)
                                }
                                .font(.callout)
                            }
                        }
                        if settings.showsListening, let listen = lesson.listen {
                            Text("Listen for").font(.callout.weight(.semibold)).padding(.top, 4)
                            Text(listen).font(.callout).fixedSize(horizontal: false, vertical: true)
                        }
                        HStack {
                            Button("Previous") { move(-1) }
                            Spacer()
                            Button("Next") { move(1) }
                        }
                        .controlSize(.small)
                        .padding(.top, 6)
                    }
                    .padding(12)
                }
                .quickHelpArea(lesson.title, lesson.goal, symbol: "graduationcap")
            }
        }
        .background(Color.secondary.opacity(0.04))
    }

    private func move(_ step: Int) {
        guard let lesson, let i = lessons.firstIndex(where: { $0.id == lesson.id }), lessons.indices.contains(i + step) else { return }
        lessonID = lessons[i + step].id
    }
}

/// Mute or Solo: filled in its colour when on, plain when off.
private struct MSButton: View {
    let title: String
    let on: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .bold)).frame(width: 22, height: 18)
                .foregroundStyle(on ? Color.black : Color.secondary)
                .background(on ? color : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(on ? color : Color.secondary.opacity(0.3)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title == "M" ? "Mute" : "Solo")
        .accessibilityValue(on ? "on" : "off")
    }
}
