# MxMidiPRO

A MIDI message monitor for macOS that shows the MIDI travelling **in and out of Logic Pro** to and from external
**USB MIDI devices**: what your keyboards and controllers send to Logic Pro (**IN**), and what Logic Pro sends to
your synths, modelers and interfaces (**OUT**), side by side in one log, with a scope of velocity, aftertouch, pitch
bend and a controller over the last few seconds.

Its window is modelled on **MMM — MIDI Message Monitor** by Tim Shoebridge
([soundmangling.com](https://www.soundmangling.com/2022/03/08/mmm-midi-message-monitor/)), a module for Cherry
Audio's Voltage Modular: a light-grey module between rack rails, a dark monospaced message log on the left
(`NOTE_ON  Note=56 G#2  Velocity=40`), and on the right the logo, square lamps, dark port plates beside 5-pin DIN
sockets, colour-square trace toggles (Channel Pressure, Poly Pressure, Velocity) and an oscilloscope-style display.

Seventh app in the MxAppsIOS family. SwiftUI and AppKit, CoreMIDI, and a small CoreMIDI driver in C. No package
dependencies; not sandboxed (it installs its driver in `~/Library/Audio/MIDI Drivers` and restarts the MIDI server
when you ask).

## How it sees the MIDI

| Direction | How | Setup |
| --- | --- | --- |
| **IN** — device → Logic Pro | CoreMIDI gives every app its own copy of every source's messages. MxMidiPRO connects to every source and sees exactly what Logic Pro receives, without being in the way. | None. |
| **OUT** — Logic Pro → device, with the **spy driver** (recommended) | What an app sends to a device goes from the app straight to the device's driver; no other app sees it. **MxMidiPRO Spy** is a CoreMIDI driver that the MIDI server loads the way it loads Roland's and Yamaha's. It calls `MIDIDriverEnableMonitoring`, so the server hands it a copy of every packet sent to every destination, and it passes the copies to MxMidiPRO on a private source that Logic Pro and other apps never see. Nothing changes in Logic Pro or its projects. | Once: **Set Up OUT Monitoring… ▸ Install Driver**, quit Logic Pro, **Restart MIDI Server…**. |
| **OUT**, with **thru ports** (no driver) | MxMidiPRO makes a destination called **MxMidiPRO ▸ *device*** for each USB, Bluetooth or network destination and passes what arrives straight on to the device. In Logic Pro, choose that port as the MIDI output of the track or External Instrument. Only what's routed through these ports is seen. | **Monitor ▸ Thru Ports for Logic Pro**, then re-route in Logic Pro. |

With the spy driver active the thru ports still forward, but the spy does the logging, so nothing is listed twice;
traffic to MxMidiPRO's own thru ports is left out.

**USB devices** means every endpoint whose device belongs to a driver other than Apple's IAC, Network and Bluetooth
drivers: class-compliant gear (`com.apple.AppleMIDIUSBDriver`, e.g. iRig MIDI 2, Yamaha MODX) and makers' USB drivers
(Roland/BOSS `RDUSB…Midi.plugin` for the ME-80, ME-90 and GT-1; Yamaha Steinberg USB). Each plate can widen this to
**All hardware** or **Everything** (IAC buses and app ports such as Logic Pro Virtual Out).

## Getting started

```bash
~/MyCodeGIT/MxAppsIOS/MxMidiPRO/build-install-mxmidipro.command
```

builds the Release app, installs it in `/Applications` (the previous copy goes to `/tmp`), checks its signature,
reports whether the spy driver is installed and current, and opens it. Its log is `build-install.log`. Or open
`MxMidiPRO.xcodeproj` in Xcode and Run.

IN works at once. For OUT, click the **OUT** plate ▸ **Set Up OUT Monitoring…**: install the driver, quit Logic Pro,
restart the MIDI server, reopen Logic Pro. The **OUT Spy** lamp turns green and the status strip says *spy driver
active*.

## The window

One window (1340 × 640 by default, at least 1200 × 480), laid out as MMM's module:

| Part | What it does |
| --- | --- |
| **Buttons** (above the log) | **Reset** clears the log and scope and starts numbering again (⌘K). **Pause** freezes the log and scope while messages keep arriving; the count of new ones shows beside it, and they all appear when you resume (⌘.). **IN** and **OUT** show or hide each direction (⌘1, ⌘2). **Types** picks the kinds of message (Notes, Poly Pressure, Control Change, Program Change, Channel Pressure, Pitch Bend, System Exclusive, MTC/Song Position/Song Select, Start/Continue/Stop, Clock, Active Sensing, System Reset); *Usual* hides Clock and Active Sensing, as at first launch, since a synced Logic Pro sends 24 clocks a beat and many keyboards send Active Sensing three times a second. **Ch** shows one MIDI channel (system messages always show). |
| **Log** | Columns `#`, Time (seconds since Reset, or time of day), Dir (**IN** green, **OUT** orange), Port (▸ before the name when it came through a thru port), Ch, Message (`NOTE_ON`, `CONTROL_CHANGE`, `CHANNEL_PRESSURE`, `SYSEX`, …) and Data: note numbers with names (middle C is C3, as in Logic Pro; C4 in Settings), controller names (`CC=64 Value=127  Sustain`), pitch bend with its offset from centre, system exclusive length, maker and first bytes, MTC pieces, song position in bars. **Bytes** (⌥⌘R) adds the raw hex. It follows the newest message while scrolled to the bottom; scroll up and it stays put. Select rows (click, ⇧, ⌘, ⌘A) and ⌘C, or right-click for *Copy* and *Copy Bytes (hex)*. |
| **Lamps** | **Logic Pro** is lit while Logic Pro is running. **OUT Spy** is green while the spy driver is feeding MxMidiPRO, amber when only thru ports are on. |
| **IN / OUT plates** | Which ports are shown: a scope (*USB devices*, *All hardware*, *Everything*) and a checkbox per port with its transport, maker and driver. The OUT plate also has the spy's state, the thru-port switch and *Set Up OUT Monitoring…*. |
| **Legend** | MMM's colour squares: **Channel Pressure** (orange), **Poly Pressure** (light blue), **Velocity** (green), plus **Pitch Bend** (pink) and one controller, **CC 1** by default (purple; pick another with the arrow). Click to show or hide a trace. |
| **Scope** | The last **5, 10 or 30 s** of the log's messages, 0 – 127 bottom to top. Velocity is a step line holding each note-on's velocity; the others join point to point; every trace holds its last value to the right edge. It follows the filters and freezes with Pause. |
| **Status strip** | The spy's state with the button that fixes it, then IN and OUT counts, messages per second, how many the log shows, and how many were dropped if the app ever fell behind. |

**File ▸ Export Log…** (⌘E) saves what the log shows as text (the log's columns) or CSV (`Seq,Time,Direction,Port,Channel,Message,Data,Bytes`).
**Monitor** menu: Pause/Resume, Reset Log, Show IN, Show OUT, Show Raw Bytes, Set Up OUT Monitoring…, Thru Ports for
Logic Pro, Rescan MIDI Devices.

**Settings** (⌘,): note names (middle C is C3 or C4), the time column, raw bytes, how many messages to keep (10,000 –
500,000; the oldest go first), and the spy driver's controls and thru ports again.

Filters, traces, the scope's length and the display choices are remembered between launches.

## The spy driver

`SpyDriver/` builds **MxMidiPRO Spy.plugin**, a version 2 CoreMIDI driver (CFPlugIn, factory `MxMidiSpyFactory`,
bundle ID `com.k3jdr.MxMidiPRO.SpyDriver`). The app carries it in `Contents/PlugIns` and copies it to
`~/Library/Audio/MIDI Drivers` — a per-user driver folder, no administrator password. Tested on macOS 27 (11/6/26):
the MIDI server loads it from there, asks for interface version 3, takes version 2 when refused, and calls Start.

- On **Start** it creates (or finds, from the last run) a device **MxMidiPRO Spy** with one source, and calls
  `MIDIDriverEnableMonitoring`. Only the **source** is *private*, so Logic Pro and other apps never list it as an
  input; it has the fixed unique ID `0x4D785370` ("MxSp") that MxMidiPRO looks up. The device and entity stay public
  (on macOS 27 a private device vanishes from the device list altogether), so Audio MIDI Setup shows **MxMidiPRO Spy**
  with no ports: a sign the driver is loaded.
- The server then calls its **Monitor** with every outgoing packet list, on its realtime thread. Each packet is
  re-sent on the private source as a system-exclusive envelope — `F0 7D 4D 78 01`, the destination's unique ID (5 × 7
  bits), the host time (10 × 7 bits), the packet's bytes 7-in-8 packed, `F7`; 4096 bytes per envelope — built on the
  stack, nothing allocated. 7D is the MMA's ID for non-commercial use.
- It travels back through CoreMIDI because the MIDI server is sandboxed: a socket or Mach port of our own isn't an
  option. MxMidiPRO finds the source by its unique ID (or through the device, by the driver's bundle ID) and unpacks
  the envelopes (`SpyFeed` in `MIDIParsing.swift`).
- When the server reports that nobody is connected to the spy source (MxMidiPRO is closed), through the driver's
  `EnableSource`, the driver stops copying until someone connects again.

**Updating:** when the driver in the app differs from the installed one (compared by code-directory hash, so a rebuild
of unchanged driver code doesn't count), the status strip shows *Update Driver…*; install it and restart the MIDI
server.

**Restarting the MIDI server** (`launchctl kickstart -k gui/<uid>/com.apple.midiserver`, or `killall MIDIServer`)
drops every app's MIDI connections, and a running app can't get them back: CoreMIDI refuses it a new client (error −2)
until it is reopened. So MxMidiPRO **reopens itself** after *Restart MIDI Server…*, and Logic Pro needs quitting and
reopening — quit it first. The server starts again on demand and loads the driver. It also quits by itself a few
seconds after the last MIDI app closes, so quitting every MIDI app and reopening MxMidiPRO, logging out and in, or
restarting the Mac all load a new driver too.

**Uninstalling:** *Uninstall* in the setup sheet or Settings removes the plug-in; the MIDI server keeps it loaded until
it restarts. Audio MIDI Setup then shows an offline **MxMidiPRO Spy** device, which you can delete there.

### Troubleshooting

- **Installed, but the lamp stays off after a restart.** The driver logs each step of loading; read it with
  `/usr/bin/log show --last 10m --predicate 'subsystem == "com.k3jdr.MxMidiPRO.SpyDriver"'` (the full path: zsh has a
  `log` command of its own). A working load reads *factory called*, *interface 2FD94D0F-… refused*, *interface
  43C98C3C-… given*, then *start: source …, unique ID 1299731312 (set 0), monitoring 0*. Nothing at all means the
  server never loaded it: check that `~/Library/Audio/MIDI Drivers/MxMidiPRO Spy.plugin` exists and
  `codesign --verify --deep` passes on it. The MIDI server allows third-party drivers (it runs without library
  validation), and the driver is signed with the same Apple Development identity as the app.
- **A burst of OUT SysEx to every device when Logic Pro opens a project.** `F0 00 00 66 …` is Mackie's ID: Logic
  Pro asking each port whether a Mackie Control surface is there. It sends the same to **Logic Pro Virtual Out**,
  which shows up as IN when the IN plate's scope is *Everything*.
- **OUT shows messages Logic Pro didn't send.** The spy sees what *any* app sends to a device (an editor/librarian, a
  BOSS TONE STUDIO, MainStage); CoreMIDI doesn't say which app sent a packet. The Port column says where it went.
- **Messages in the log are a few milliseconds out of order.** Logic Pro schedules some output ahead; the spy reports
  the time each packet is due, and the log lists them as they arrive.

## Thru ports

Each hardware destination gets **MxMidiPRO ▸ *its name***, whose unique ID is kept between launches so a Logic Pro
project still finds it. What arrives is sent on unchanged, time stamps included, so Logic Pro's schedule-ahead still
works. Turning thru ports off (or quitting MxMidiPRO) removes the ports, so tracks routed to them send nowhere until
they come back.

## Files

| File | What it is |
| --- | --- |
| `MxMidiPRO/MxMidiPROApp.swift` | The app, its window, menus and Settings. |
| `MxMidiPRO/MonitorStore.swift` | The monitor's state: messages kept, the filtered list, filters, pause, counters, the spy's state, Logic Pro running, export. |
| `MxMidiPRO/MIDI/MIDIEngine.swift` | CoreMIDI: connects to every source, finds and decodes the spy, makes the thru ports. Receive blocks parse on CoreMIDI's thread; the store drains 30 times a second. |
| `MxMidiPRO/MIDI/MIDIParsing.swift` | The byte parser (running status, realtime inside messages, SysEx across packets), Universal MIDI Packets to bytes, the spy envelope. |
| `MxMidiPRO/MIDI/MIDIEvent.swift`, `MIDIFormat.swift`, `MIDIPorts.swift` | A message and its kinds; how it reads (note, controller and maker names); what each port is (USB, Bluetooth, Network, IAC, virtual); host time. |
| `MxMidiPRO/MIDI/SpyDriverInstall.swift` | Installs, updates and removes the driver; restarts the MIDI server. |
| `MxMidiPRO/Views/` | `MonitorView` (the module), `LogTable` (AppKit table), `ScopeView`, `PanelStyle` (rails, buttons, lamps, plates, DIN sockets, logo), `OutSetupView`, `SettingsView`. |
| `SpyDriver/MxSpyDriver.c`, `MxSpyCore.c/.h`, `SpyDriver-Info.plist` | The driver: CFPlugIn glue, and the copying and envelope (kept apart so the tools can run it). |
| `Tools/` | `build-tools.sh`, `MxMidiTests.swift`, `MxMidiDemo.swift`, `make-icon.swift` (draws the app icon). |

## Testing

```bash
~/MyCodeGIT/MxAppsIOS/MxMidiPRO/Tools/build-tools.sh /tmp/mxmidi-tools
```

builds two command-line tools from the app's MIDI sources and the driver's `MxSpyCore.c`:

- **mxmidi-tests** — the byte parser; the spy envelope (the C encoder against the Swift decoder, random packets of 1 –
  4096 bytes); Universal MIDI Packets to bytes; note and message text; and the engine end to end on **virtual ports
  only**: IN from a source, a thru port forwarding to a destination, and the spy path fed by the driver's own
  `MxSpyForwardPacketList` (including a 10,000-byte SysEx arriving byte for byte, and traffic to MxMidiPRO's own thru
  port left out). Run it as
  `mxmidi-tests -MxSpyTestSource "MxTest Spy Feed" -MxThruTestTarget "MxTest Synth"`.
- **mxmidi-demo *seconds*** — plays a keyboard part IN from *MxTest Keyboard* and a "Logic Pro" part OUT to *MxTest
  Synth* through the spy's code, so the screens can be tried without Logic Pro or hardware. Start the app with
  `open -n MxMidiPRO.app --args -MxSpyTestSource "MxTest Spy Feed" -InScope everything -OutScope everything`.

`-MxSpyTestSource` and `-MxThruTestTarget` are read from the command line only, never from saved preferences.
`-InScope`/`-OutScope` on the command line override the saved scopes for that run without changing them.

What the tools can't cover is the driver running inside the real MIDI server. That was checked on 11/6/26 (macOS 27,
Logic Pro 13.0): installed from the app, loaded after *Restart MIDI Server…*, it copied a note, volume, program
change, a SysEx split over two packets and a note-off that one app sent to another app's destination, byte for byte
with the right destination; and with Logic Pro opening a project it showed Logic's Mackie Control probes to the iRig
MIDI 2. Playing notes from a Logic Pro track to a device is still to be watched.
