# MxModxUSB

An overview of a **Yamaha MODX7** (MODX6 and MODX8 too) and everything it makes available over its one USB cable:
the instrument and its firmware, the current Performance and its 16 Parts, the Live Set bank, every System
setting, the user curves and micro-tuning tables, the USB device with its MIDI and audio interfaces, and what the
keyboard, wheels and knobs are doing right now.

It also **changes** them: with changes unlocked, the System, Sequencer, Performance, Part, effect, Live Set, curve and
micro-tuning settings can be edited, and each change goes to the MODX as you make it and is read back to confirm it. A **MODX7 workspace** file (`.modxworkspace`) saves everything
the MODX makes available over USB and sends it back.

**Until you unlock changes no setting is changed.** The MODX is sent requests (Identity Request, Dump Request,
Parameter Request) that make it report. The one exception is playing a Live Set slot: clicking a slot sends the
MODX's Live Set Select, as touching the slot on the MODX does, and the MODX loads that slot's Performance. The app
never sends a note.

Eighth app in the MxAppsIOS family. SwiftUI, CoreMIDI, IOKit and Core Audio; no package dependencies; not sandboxed.

## Getting started

```bash
~/MyCodeGIT/MxAppsIOS/MxModxUSB/build-install-mxmodxusb.command
```

builds the Release app, installs it in `/Applications` (the previous copy goes to `/tmp`), checks its signature and
opens it (log: `build-install.log`). Then

```bash
~/MyCodeGIT/MxAppsIOS/MxModxUSB/Tools/package.sh
```

packages that Release build as `build/MxModxUSB-<version>.dmg`, with an Applications shortcut. It's signed for
development only, not notarized, so it's for Macs under this Apple Developer team. Or open `MxModxUSB.xcodeproj` in Xcode and Run.

Connect the MODX by USB (TO HOST) and turn it on; MxModxUSB finds it by itself and reads everything in about 15
seconds, the first screen in about one. On the MODX, **MIDI IN/OUT** should be **USB** (Utility ▸ Settings ▸ MIDI
I/O) — with it set to MIDI the instrument talks through its 5-pin jacks instead.

## The window

| Section | What it shows |
| --- | --- |
| **Overview** | A dark panel like the MODX's own: model and firmware; a display with the current Performance's name, tempo, Parts in use with their categories, and its place in the Live Set; lamps for USB, the three MIDI ports, USB audio, the MIDI clock (measured, in BPM) and Active Sensing; the pitch and mod wheels, Super Knob and eight assignable knobs (named as in the Performance, moving as you turn them); the keyboard lighting the keys you play, with each Part's key range drawn above it. Cards below: the Parts, Keyboard & MIDI settings, Sound (volume, tune, effects), the connection. |
| **Performance** | Common values (tempo, volume, pan, knob and slider function, portamento, swing, unit multiply, USB monitor volume); effects (Reverb, Variation, Insertion for the A/D Part, Master Effect, by name); the assignable knobs with their names, values and controller numbers, the foot controllers and Super Knob; a table of the Parts: name, category, type (AWM2 with its active elements, Drum, FM-X), on/keyboard/mute, key and velocity range, volume and pan, reverb and variation sends, output, mono/poly, note shift and what each receives. *Show unused Parts* lists all 16. Unlocked, the Common values, effects and knobs are edited in place, and a Part opens in its own sheet (double-click it, or **Edit Part…**) with every setting the Part has. |
| **Live Set** | Laid out like the MODX's own Live Set screen. The top row has the **Bank** and **Page** names, each a drop-down: the bank menu offers the MODX's bank and every Live Set bank kept in a workspace file, the page menu the bank's 16 pages. While changes are unlocked you can also type in either box to rename the MODX's bank or page. **Refresh** is at the far right. Below are the page's 16 slots in their own colours, each **named by the Performance it recalls, as the MODX shows it** ("Ocean Pad", not the slot's stored name "SYN PAD"), with its bank, number and volume. The slot playing on the MODX is marked CURRENT. **Clicking a slot plays it on the MODX**, as touching it there does. Its **ⓘ** button (or a right-click) opens its settings, editable when unlocked, with a **Play This Slot** button. In a workspace's bank a click just shows the settings. |
| **System Settings** | Every System and Sequencer setting, grouped — Tone Generator, Keyboard, Controllers, MIDI, Audio, Power On, Panel, Sequencer & Click — each with its address in the Data List, and each editable when unlocked. |
| **User Data** | The 32 user velocity curves, drawn, and the 8 micro-tuning user tables with their names and the cents of each note. Unlocked, clicking a curve opens its name, type and eight points; table names and notes are edited in place. |
| **Workspace** | Save a workspace from the MODX, open one, see what it holds and how each part compares with the MODX, and send chosen parts back (below). |
| **USB · MIDI · Audio** | The USB device descriptor (vendor 0x0499, product, release, USB version, speed, configurations, class) and its interfaces (Audio Control, Audio Streaming, MIDI Streaming); each MIDI port with its role, message count, last message and every CoreMIDI property of its endpoints, port and device; the USB audio device (channels each way and their names, sample rate, latency, safety offset, buffer, whether an app is using it). |
| **MIDI Activity** | **From the MODX**: what it sends on each port, newest first: notes, controllers, program changes, pitch bend, pressure; Clock and Active Sensing (the MODX sends both all the time) are hidden unless you ask. **Requests to the MODX**: every request the app has sent, with the time, the bytes and what came back (answered in so many ms, so many blocks, or *no answer*). An unanswered request also shows as a warning in the toolbar. |

Choosing another Performance on the MODX (it sends Bank Select and Program Change) reads the new one. If the MODX
is set not to transmit Program Change, a light check of the name every 8 seconds notices the change instead.
**Read Again** (⌘R) reads everything.

## Changing settings

The lock in the toolbar (**Changes Locked / Unlocked**) guards every change; it starts locked each time the app opens.
Unlocked, the values become controls — a menu for named values, effect types and controller numbers, a switch for
on/off, a slider and stepper for numbers, a field for names (sent when you press Return or leave the field) — and an
orange strip above the window says what happens to them and shows the result of the last change.

- **Each change is sent at once** as a Parameter Change (`F0 43 10 7F 1C 07 ah am al <data> F7`), then read back
  about half a second later: the strip says *The MODX has the change* or *The MODX didn't take* it. A name goes one
  character at a time (the MODX has 20 one-character parameters, Name 1–20), each checked.
- **Where it lands.** System, Sequencer, user curve and micro-tuning changes take effect at once and stay.
  Performance, Part, effect and Live Set changes go to the MODX's **edit buffer**, as if made on its own panel: they
  are lost when another Performance is chosen unless you press **STORE** on the MODX.
- **Undo** (Edit ▸ Undo … on the MODX, ⌥⌘Z) puts back the last change, one at a time; several steps of the same
  setting count as one. ⌘Z stays with text fields. Choosing another Performance clears the edit-buffer undos.
- **Only what the MODX accepts is sent** (`ModxLink.isWritable`): an address and size from the app's own parameter
  table (`ModxParams`), a value inside the setting's range and, for effect types, one the slot can hold (Effect
  Type List: 13 reverbs, the Variation and Insertion types, the A/D Part's shorter list, 26 Master Effects). Settings
  a Part doesn't have — drum-only or non-drum ones, ones for Parts 1–8 only — aren't offered for it.
- **Two settings ask first.** *MIDI IN/OUT* set to MIDI stops the MODX talking over USB (set it back on the MODX:
  UTILITY ▸ Settings ▸ MIDI I/O), and *Local Control* off silences its own keyboard.
- A setting can be edited only once its block has been read; its tooltip says why it can't when it can't.

## Workspace files

**Save Workspace from MODX…** (⌘S) reads everything afresh, all 16 Parts included, and saves it as a
`.modxworkspace` file; **Open Workspace…** (⌘O), or opening one in Finder, shows it with or without the MODX.

What it holds, as the MODX's own bulk data:

| Section | Blocks |
| --- | --- |
| `system` | System, `00 00 00`, 60 bytes |
| `sequencer` | Sequencer & Click, `00 05 00`, 21 bytes |
| `performance.common` | The Performance Common bulk under its header `0E 53 00`: name, tempo, effects, knobs, scenes, motion sequencer… |
| `performance.part1` … `part16` | Each Part's bulk under `0E 52 0p`, unused Parts too: its settings, elements or drum keys, FM-X operators |
| `liveSet` | The Live Set bank under `0E 51 00`: bank and page names and the 256 slots |
| `curves` | The 32 user curves under `0E 50 00` |
| `microTuning` | The 8 micro-tuning tables (`00 3n 00`) and their names (`00 5n 00`) |

A file from a MODX7 on firmware 2.50 with one Performance has about 1,500 blocks (380 KB). It is JSON: `format`
("MxModxUSB MODX workspace"), `version` (1), `savedAt`, `savedBy`, `model`, `firmware`, `performance`,
`liveSetBank`, `note`, `sections` (each with `id`, `title`, its bulk `header` and `blocks` of `address` and `data`
in hex) and a readable `summary` of every decoded setting, which the Workspace screen also shows.

**Sending it back** (unlocked, MODX connected): tick System settings, Performance, Live Set bank, User curves and/or
Micro-tuning tables, then **Send Selected to MODX…**. Each section goes as its header, blocks and footer, 30 ms
apart, then everything sent is read back and compared; the report says whether the MODX now holds what the file
has. Before sending, each group shows whether it is *same as the MODX* or *differs* (or neither, when the app hasn't
read all of that part of the MODX — the Performance's unused Parts, say). A section whose blocks don't
pass the same rules as the MODX's own dumps — address, size, a Part's blocks only under that Part's header — is not
sent. The Performance and Live Set go to the edit buffer (store them on the MODX to keep them); the rest take
effect at once. A file saved from another model or firmware is flagged.

Two block sizes differ from the Data List, and the app goes by the instrument: the MODX7 dumps the **Sequencer**
block as 21 bytes (the Data List says 22) and each **Live Set slot** as 30 (it says 26).

## The Live Set screen

**Slot names.** The MODX shows each Live Set slot by the name of the Performance it recalls. The slot's own stored
name is something else: in the preset bank it's a description ("SYN PAD", "E.PIANO RD"). Over USB the MODX reports
only the current Performance's name, so the app takes the names from two places:

- **Preset Performances** come from the Performance List in Yamaha's MODX Data List: 2,227 names for firmware 2.50,
  in `ModxPresetPerformances.swift`. Bank Select MSB 63 or 64, LSB 0–31 (Preset 1–32) and Program 0–127 give
  Performance number LSB × 128 + Program + 1. That was checked against all 256 slots of the preset Live Set bank,
  whose Performance names the Data List's Live Set List also gives.
- **User and Library Performances** are learned. When one is chosen on the MODX (it sends Bank Select MSB 64 and a
  Program Change) and the app reads its name, the app remembers it for that bank and number, between launches too.
  Until then a slot shows its own stored name in italics, and its tooltip says why. MSB 63 (one Part) changes only
  a Part, so nothing is learned from it.

**Bank menu.** The MODX can't be switched to another Live Set bank over USB, and it reports only the bank in use.
So the menu lists that bank first, then the Live Set bank of every workspace file the app finds. It looks at the
open workspace, recent workspace files and `~/Documents` (two folders deep), and **Choose a Workspace File…** adds
any other. Picking a workspace's bank shows it (a strip says which file, when it was saved, and from which MODX),
and **Send to MODX…** puts it into the MODX's Live Set edit buffer, then reads it back and compares. **Show the
MODX's Bank** goes back.

**Playing a slot** sends Live Set Select: Bank Select MSB 62, LSB = page (0–15), Program Change = slot (0–15). It
goes on the channel the MODX takes Performance changes on: Part 1's (1) in MIDI I/O Mode Multi, the MIDI I/O
Channel in Single. The MODX then loads the slot's Performance. It sends no Program Change back for this, so the app
reads the Performance after a moment and moves CURRENT once the name shows the MODX took the slot. Requests wait
1.5 s while it loads. Nothing is sent unless *Receive/Transmit Bank Select* and *Program Change* are on (UTILITY ▸
Settings ▸ MIDI I/O); the screen says so otherwise. If the Performance has changes made here that aren't stored,
the app asks first, because playing another slot replaces it. Tested on a MODX7 (firmware 2.50): slots 10, 14 and 6
of Best of MODX 1, clicked from the app, played on the MODX.

**Refresh** reads the MODX's Live Set again and looks for workspace files again. Use it after choosing another
bank on the MODX, which sends nothing over USB. If the bank has changed, Live Set undos are dropped, since they
would now write into the wrong slots.

**Renaming** sends each character as its own Parameter Change and reads the Live Set back. On a MODX7 (firmware
2.50) a page name sent to the factory bank, **"Preset"**, was answered but not kept. That bank seems not to take
changes, so the app says so when that happens. A User bank is the place to edit.

## The three USB MIDI ports

| Port | Role |
| --- | --- |
| **Port 1** | The MODX itself: keyboard, controllers, tone generator, and the SysEx MxModxUSB reads with. It also carries the MIDI clock (when MIDI Clock Out is on) and Active Sensing. |
| **Port 2** | Not used by the instrument. |
| **Port 3** | Joins the computer to the MODX's 5-pin MIDI IN/OUT jacks. |

## How it reads the MODX

From the **MODX Data List** (`modx_en_dl_d0.pdf`, Yamaha, pp. 186–221), checked against a MODX7 on firmware 2.50:

- **Identity Request** `F0 7E 00 06 01 F7` → `F0 7E 7F 06 02 43 00 41 57 06 0F 00 00 7F F7` (MODX7, version byte 0F
  = 2.50). The MODX answers only device number 00, not the usual 7F "all devices".
- **Dump Request** `F0 43 20 7F 1C 07 ah am al F7`, **Parameter Request** `F0 43 30 7F 1C 07 ah am al F7`.
  Replies: Bulk Dump `F0 43 00 7F 1C bh bl 07 ah am al <data> cc F7` (byte count = 4 + data; the checksum covers the
  model ID, address and data — the byte count is not in it, whatever the Data List's wording suggests) and Parameter
  Change `F0 43 10 7F 1C 07 ah am al <data> F7`.
- Order of reading: Identity, System (`00 00 00`, 60 bytes) and Sequencer (`00 05 00`) by Dump Request; the
  Performance's name, tempo and volume and the 16 Parts' settings by Parameter Request (`30 40 xx`, `31 0p xx`, a few
  milliseconds each, about a second in all); then in the background the Performance Common bulk (`0E 53 00`: effects
  and knob names), each Part in use's bulk (`0E 52 0p`: its type and elements), the Live Set (`0E 51 00`), the user
  curves (`0E 50 00`) and the micro-tuning names (`00 5n 00`).

**Only requests the MODX accepts are sent** (`ModxLink.isAllowed`). Anything else — a Dump Request for a block it
only sends inside a bulk (`30 40 00`, `31 0p 00`), or a Parameter Request for a block a Part doesn't have (FM-X or drum
addresses on an AWM2 Part) — makes it show **"Illegal Bulk Data"** on its screen. That is harmless (the request is
refused and nothing changes) but it interrupts the player. It happened while the protocol was being worked out, and
once more while the first version of the app ran — every request it sent had been answered, so the likely cause was
timing. The app now paces itself:

- after the MODX sends **Bank Select or Program Change** (it is loading a Performance) no request goes out for
  1.5 seconds;
- a request waits for 0.12 seconds of silence after any **bulk block or unrequested SysEx**, so it never arrives
  while the MODX is still sending;
- a bulk counts as finished only at its **closing block** (Bulk Footer); one that stops short is logged as a problem;
- choosing a Performance re-reads only the Performance, not the Live Set, and the name check runs only when the MODX
  doesn't send Program Change.

If the message ever appears again, MIDI Activity ▸ Requests to the MODX shows exactly what was sent, and when.

## Files

| File | What it is |
| --- | --- |
| `MxModxUSB/MxModxUSBApp.swift` | The app, its window and menu (Open and Save Workspace, Undo on the MODX), and opening workspace files from Finder. |
| `Info.plist` | The workspace file type (`com.k3jdr.mxmodxusb.workspace`, `.modxworkspace`). |
| `MxModxUSB/MODX/ModxSysEx.swift` | The MODX's SysEx: addresses, request, Parameter Change and Bulk Dump messages, parsing replies, checksums, identity; the rules a bulk block must meet (`ModxBulkRules`). |
| `MxModxUSB/MODX/ModxLink.swift` | CoreMIDI: finds the MODX's three ports, listens to all of them, sends one request or change at a time to Port 1 and waits for its answer; the lists of allowed requests and changes. |
| `MxModxUSB/MODX/ModxTables.swift` | What the bytes mean: System, Sequencer, Performance Common, Part, Live Set, user curves; categories, banks, slot colours, effect types. |
| `MxModxUSB/MODX/ModxParameters.swift` | Every editable setting: block, offset, encoding, range, how it's shown, which Parts have it, warnings; the effect types each slot can hold. |
| `MxModxUSB/MODX/ModxModel.swift` | The order things are read in, re-reading when the Performance changes, and the live state of keys, wheels, knobs and clock. |
| `MxModxUSB/MODX/ModxModel+Editing.swift` | Changes: sending, reading back, undo; saving, opening and sending workspaces. |
| `MxModxUSB/MODX/ModxWorkspace.swift` | The workspace file: its sections and blocks, the readable summary, reading and writing; a file's Live Set bank (`ModxWorkspaceLiveSet`). |
| `MxModxUSB/MODX/ModxModel+LiveSet.swift` | The Live Set screen's data: slots' Performance names, learning names, finding workspace banks, Refresh, sending a bank. |
| `MxModxUSB/MODX/ModxPerformanceNames.swift` | A slot's Performance name: the preset list by bank and number, and names seen on the MODX. |
| `MxModxUSB/MODX/ModxPresetPerformances.swift` | The 2,227 preset Performance names, generated from the Data List by `Tools/make-preset-names.swift`. |
| `MxModxUSB/Device/USBDeviceInfo.swift`, `AudioDeviceInfo.swift` | The USB device and interfaces from the I/O Registry; the audio interface from Core Audio. |
| `MxModxUSB/MIDI/MIDIBytes.swift` | MIDI bytes in and out of Universal MIDI Packets; the byte parser (MxMidiPRO's). |
| `MxModxUSB/Views/` | `ContentView` (sidebar), `OverviewView` (the instrument panel and cards), `DetailViews` (Performance, System, User Data), `LiveSetViews` (the Live Set screen, its name drop-downs, slots), `EditorViews` (the editing rows, Part sheet, slot and curve editors, the strip), `WorkspaceView`, `DeviceViews` (USB · MIDI · Audio, MIDI Activity), `Style` (cards, lamps, dials, wheels, keyboard). |
| `Tools/` | `build-tools.sh` and `ModxTests.swift` (the decoding tests), `make-icon.swift` (draws the icon), `make-preset-names.swift` (regenerates the preset Performance names from a Data List PDF), `package.sh` (the DMG). |

## Testing

```bash
~/MyCodeGIT/MxAppsIOS/MxModxUSB/Tools/build-tools.sh /tmp/modx-tools && /tmp/modx-tools/modx-tests
```

checks the decoding against replies a MODX7 really sent (11/6/26, Performance "CFX + FM EP 2", Live Set bank
"Preset"): identity, every block's checksum, the System and Sequencer settings, the Performance's name, tempo,
knobs and effects, Part 1, two Live Set slots, a user curve, the allowed and refused requests, and the SysEx
packing; and for changes: Parameter Change and Bulk Dump messages (a block rebuilt byte for byte), value encodings
(tempo, tune, bits, names), the effect-type rules, which changes and bulk blocks may be sent (names only one
character at a time, the device's block sizes), and a workspace's round trip, summary and sending order; and for
the Live Set screen: the preset names (Preset 4 #97 is "Ocean Pad"; the two fixture slots recall what the Data
List's Live Set List says), learned names and their precedence, and a workspace's Live Set bank and what it sends; and the
Live Set Select messages a slot click sends. 56 checks; no MODX is needed.

## Not covered (yet)

- **Element, drum-key and FM operator detail**: the app counts a Part's active elements and keys but doesn't list
  or edit waveforms or operator settings (the Part bulk holds them, and a workspace saves and restores them).
- **Scenes, Arpeggio and Super Knob settings** are in the Common bulk, and so in a workspace, but not decoded or
  edited one by one.
- **Storing** a Performance or Live Set in the MODX's user memory is left to its STORE button.
- **Which Performance is current** is known only after one is chosen on the MODX while the app is open (the MODX
  doesn't report its bank and number when asked). Until then the Live Set's CURRENT mark falls back to a slot whose
  Performance has the current one's name.
- **User and Library Performance names** show only once each has been chosen on the MODX while the app runs.
- **Other Live Set banks on the MODX** can't be listed or chosen over USB: choose one on the MODX, then Refresh.
