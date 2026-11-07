//
//  ModxSongLessons.swift — MxModxUSB
//
//  The MIDI Songs page's lessons, at the instruction level in Settings ▸ Guidance. The page is a very small Logic
//  Pro for the MODX7 — tracks, a piano roll, a mixer, mute and solo, a transport — with no instruments of its own:
//  every sound comes from the MODX.
//

import Foundation

enum ModxSongLessons {
    static let lessons: [TutorialLesson] = [
        TutorialLesson(
            id: "song.what", title: "What a MIDI Song Is",
            goal: "Not sound, but instructions: which key, how hard, when — for the MODX to play.",
            theory: [
                "A MIDI file (a Standard MIDI File, .mid) holds no audio. It holds events: Note On and Note Off (which key, how hard), controllers (volume, pan, sustain, the wheels), program changes, and when each happens. Whatever plays the file makes the sound — here, the MODX7.",
                "Time is counted in ticks: so many ticks per quarter note (often 480). A tempo map turns ticks into seconds, so the same file plays faster or slower without changing a note. A time signature groups beats into bars.",
                "Events travel on 16 channels. A file's tracks usually each play one channel. On the MODX in MIDI I/O Mode Multi, channel 1 plays Part 1 of the current Performance, channel 2 Part 2, and so on — so the Performance is the band and the song is the score.",
                "This page is a very small Logic Pro: tracks, a piano roll to edit notes, a mixer with volume, pan, mute and solo, and a transport. It has no instruments of its own; everything you hear is the MODX.",
            ],
            steps: ["Make a demo song or open a .mid file (next lesson).", "Each lesson's steps use the page around it; play along on the MODX's keyboard any time."],
            lessonOnly: true),
        TutorialLesson(
            id: "song.make", title: "Make a Song or Open One",
            goal: "Start with a demo built for the current Performance, or open any Standard MIDI File.",
            theory: [
                "New ▸ Demo Song writes eight bars for the Parts the MODX is playing: chords on the first Part, a bass line on the second, a melody on the third, and drums if the Performance has a drum Part. Open… reads any .mid file; tracks that play several channels are split into one track per channel, as Logic does when it imports one.",
            ],
            steps: ["Choose New ▸ Demo Song (or Open… a .mid file).", "Look at the tracks: each one's channel and the MODX Part it plays."],
            listen: "Nothing yet — that's the next lesson."),
        TutorialLesson(
            id: "song.play", title: "Play It on the MODX",
            goal: "Play, stop, and move the playhead: the MODX plays every note.",
            theory: [
                "Play sends the song's events to the MODX's USB Port 1 — only there — just ahead of time, so the timing is exact. Stop releases every note. Clicking the ruler moves the playhead; playing from the middle first sends each track's volume, pan and other controllers as they'd be at that point.",
                "While a song plays the app asks the MODX nothing (no SysEx goes out), so the song has the connection to itself; the app catches up when it stops. Panic sends All Notes Off on every channel if anything ever hangs.",
            ],
            steps: ["Press Play (or Space) and listen.", "Click the ruler to jump to bar 5.", "Stop, then Go to Start."],
            listen: "The song in the current Performance's sounds — change the Performance on the MODX and the same song sounds different."),
        TutorialLesson(
            id: "song.channels", title: "Tracks, Channels and Parts",
            goal: "A track's channel chooses which Part of the MODX plays it.",
            theory: [
                "Each track plays one MIDI channel, and in Multi mode channel n is Part n. The channel menu shows each Part's name, so you can choose a sound by choosing a Part. Two tracks on one channel play the same Part.",
                "If the MODX is in MIDI I/O Mode Single it takes one channel only, so the other tracks stay silent; set Multi in UTILITY ▸ Settings ▸ MIDI I/O.",
            ],
            steps: ["Play the song.", "Move the melody to another Part with its channel menu.", "Add a track (+) and choose its channel."],
            listen: "The melody's notes in another Part's sound — same notes, new instrument."),
        TutorialLesson(
            id: "song.muteSolo", title: "Mute and Solo",
            goal: "Mute silences a track; Solo plays only the soloed tracks.",
            theory: [
                "M mutes a track. S solos it: once any track is soloed only soloed tracks play, whatever their mute. Both work while the song plays, releasing the notes of a track they silence. They aren't saved in the file — they're how you listen while you work.",
            ],
            steps: ["Play the song and mute the chords.", "Solo the bass; then solo the melody too.", "Clear the solos."],
            listen: "Each part of the arrangement on its own, then back together."),
        TutorialLesson(
            id: "song.mixer", title: "The Mixer: Volume and Pan",
            goal: "Balance the tracks: a volume fader and a pan control for each.",
            theory: [
                "The mixer's fader sends Controller 7 (Volume) and the pan control Controller 10 (Pan) on the track's channel: the MODX's Part follows at once, as it would from a sequencer. Letting go saves the value at the start of the song, so the file opens balanced.",
                "Unlike Logic Pro there's no audio here, so no effects or meters: the MODX's own Part and Performance settings do the rest.",
            ],
            steps: ["Open the Mixer (under the tracks).", "Play, and bring the chords down.", "Pan the melody left and the chords right."],
            listen: "The balance and stereo picture change while the notes stay the same."),
        TutorialLesson(
            id: "song.pianoRoll", title: "Edit Notes in the Piano Roll",
            goal: "Add, move, lengthen and delete notes; change their velocity; tidy their timing.",
            theory: [
                "The piano roll shows the selected track: pitch up the side, time across. Click an empty place to add a note (as long as the grid); drag a note to move it, or its right end to lengthen it; Delete removes the selected notes. Each click plays the note on the MODX.",
                "Velocity is how hard a note is played (1–127). Quantize moves note starts to the grid; Transpose moves pitches by a semitone or an octave. Every edit can be undone with ⌘Z.",
            ],
            steps: ["Select the Melody track and open the Piano Roll.", "Add a few notes in bar 2; drag one up a step.", "Select all (⌘A) and Quantize; transpose up an octave; undo it."],
            listen: "Your own melody, played by the MODX."),
        TutorialLesson(
            id: "song.tempo", title: "Tempo and Time",
            goal: "Change the tempo without changing a note.",
            theory: [
                "The song's notes are in ticks; the tempo (beats per minute) decides how long a tick lasts. Change it and the whole song plays faster or slower, in time. The position shows bar.beat.sixteenth.",
            ],
            steps: ["Play at the song's tempo.", "Set the tempo to 80, then to 140."],
            listen: "The same song, slower and faster, every note in place."),
        TutorialLesson(
            id: "song.programs", title: "Program Changes",
            goal: "A file can also choose sounds — but on the MODX the Performance does that.",
            theory: [
                "Many MIDI files carry Bank Select and Program Change for each channel, made for a General MIDI player. Sent to the MODX they'd replace each Part's sound in its edit buffer (Bank Select MSB 0 picks the MODX's GM voices). So the app plays them only if Send Program Changes is on; otherwise the current Performance's sounds stay.",
            ],
            steps: ["Open a General MIDI file.", "Play it with Send Program Changes off, then on.", "Choose the Performance again on the MODX to get its sounds back."],
            listen: "Off: your Performance plays the file. On: the file picks GM voices for the Parts."),
        TutorialLesson(
            id: "song.save", title: "Save It",
            goal: "Save the song as a Standard MIDI File, ready for Logic Pro or any sequencer.",
            theory: [
                "Save writes format 1: a first track with the song's name, time signature and tempos, then one track per song track with its name, its notes and its controllers — including the mixer's volume and pan. Events the page doesn't edit (other controllers, pitch bend, text, SysEx) are kept.",
            ],
            steps: ["Save (⌘S on the page's Save button) and choose a place.", "Open the file in Logic Pro: the tracks, notes, tempo and mix are there."]),
    ]
}
