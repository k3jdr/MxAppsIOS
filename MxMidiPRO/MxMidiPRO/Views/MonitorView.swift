//
//  MonitorView.swift — MxMidiPRO
//
//  The one window, laid out as MMM's module: the message log on the left under a row of small buttons; on the right
//  the logo, the Logic Pro and OUT Spy lamps, the IN and OUT port plates with their DIN sockets, the trace legend
//  and the scope; a status strip along the bottom.
//

import SwiftUI

struct MonitorView: View {
    @Bindable var store: MonitorStore

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 26)          // the hidden title bar: traffic lights, and drag the window here
            RackRail()
            ModuleFace {
                VStack(spacing: 8) {
                    // The log takes what the scope side leaves: about 40 % of the module, 580 … 760 points.
                    GeometryReader { geometry in
                        let scopeWidth = min(max(geometry.size.width * 0.4, 580), 760)
                        HStack(spacing: 12) {
                            LogPane(store: store)
                            Rectangle().fill(Color.black.opacity(0.25)).frame(width: 1)
                            ScopePane(store: store)
                                .frame(width: scopeWidth)
                        }
                    }
                    StatusStrip(store: store)
                }
            }
            RackRail()
            Color.clear.frame(height: 6)
        }
        .background(Panel.rack)
        .sheet(isPresented: $store.showOutSetup) { OutSetupView(store: store) }
    }
}

// MARK: Log

private struct LogPane: View {
    @Bindable var store: MonitorStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button("Reset") { store.reset() }
                    .buttonStyle(PanelButtonStyle())
                    .help("Clear the log and the scope and start numbering again (⌘K)")
                PanelToggle(title: "Pause", isOn: $store.paused, tint: Panel.pauseTint)
                    .help("Freeze the log and the scope; messages keep arriving and appear when you resume (⌘.)")
                PanelToggle(title: "IN", isOn: $store.showIn, tint: Panel.inTint)
                    .help("Show what devices send to Logic Pro (⌘1)")
                PanelToggle(title: "OUT", isOn: $store.showOut, tint: Panel.outTint)
                    .help("Show what Logic Pro sends to devices (⌘2)")
                TypesButton(store: store)
                ChannelButton(store: store)
                Spacer(minLength: 4)
                if store.paused {
                    Text("PAUSED · \(store.waitingCount.formatted()) new")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color(red: 0.55, green: 0.32, blue: 0.0))
                }
            }
            VStack(spacing: 0) {
                LogHeader(showRaw: store.showRaw)
                LogTable(store: store)
            }
            .screen()
        }
    }
}

private struct TypesButton: View {
    @Bindable var store: MonitorStore
    @State private var open = false

    var body: some View {
        let hidden = store.hiddenGroups.count
        Button { open.toggle() } label: {
            Text(hidden == 0 ? "Types: All ▾" : "Types: \(MIDIFilterGroup.allCases.count - hidden) of \(MIDIFilterGroup.allCases.count) ▾")
        }
        .buttonStyle(PanelButtonStyle())
        .help("Choose which kinds of message the log and the scope show")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Show these messages").font(.headline)
                ForEach(MIDIFilterGroup.allCases) { group in
                    Toggle(group.title, isOn: Binding(
                        get: { !store.hiddenGroups.contains(group) },
                        set: { show in
                            if show { store.hiddenGroups.remove(group) } else { store.hiddenGroups.insert(group) }
                        }))
                }
                Divider()
                HStack {
                    Button("All") { store.hiddenGroups = [] }
                    Button("Usual") { store.hiddenGroups = MIDIFilterGroup.hiddenByDefault }
                        .help("Everything but Clock and Active Sensing")
                    Button("Notes Only") { store.hiddenGroups = Set(MIDIFilterGroup.allCases).subtracting([.notes]) }
                }
            }
            .padding(14)
            .frame(width: 270)
        }
    }
}

private struct ChannelButton: View {
    @Bindable var store: MonitorStore
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Text(store.channel == 0 ? "Ch: All ▾" : "Ch: \(store.channel) ▾")
        }
        .buttonStyle(PanelButtonStyle())
        .help("Show one MIDI channel's messages (system messages such as clock and SysEx always show)")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("MIDI channel").font(.headline)
                Button("All channels") { store.channel = 0; open = false }
                    .buttonStyle(PanelButtonStyle())
                Grid(horizontalSpacing: 5, verticalSpacing: 5) {
                    ForEach(0..<4) { row in
                        GridRow {
                            ForEach(1...4, id: \.self) { col in
                                let ch = row * 4 + col
                                Button { store.channel = ch; open = false } label: {
                                    Text("\(ch)").frame(width: 24)
                                }
                                .buttonStyle(PanelButtonStyle())
                                .overlay(RoundedRectangle(cornerRadius: 3)
                                    .strokeBorder(store.channel == ch ? Color.accentColor : .clear, lineWidth: 2))
                            }
                        }
                    }
                }
            }
            .padding(14)
        }
    }
}

// MARK: Scope side

private struct ScopePane: View {
    @Bindable var store: MonitorStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                MxLogo()
                    .padding(.top, 2)
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 9) {
                    HStack(spacing: 6) {
                        Text("Logic Pro").panelLabel().fixedSize()
                        SquareLamp(on: store.logicRunning, tint: Panel.inTint, size: 18)
                    }
                    .help(store.logicRunning ? "Logic Pro is running" : "Logic Pro isn't running")
                    HStack(spacing: 6) {
                        Text("OUT Spy").panelLabel().fixedSize()
                        SquareLamp(on: store.spyState == .active || store.thruEnabled,
                                   tint: store.spyState == .active ? Panel.inTint : Panel.pauseTint, size: 18)
                    }
                    .help(spyHelp)
                }
                .padding(.top, 4)
                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: 6) {
                        PortPlate(store: store, direction: .input)
                        DINSocket(size: 27)
                    }
                    HStack(spacing: 6) {
                        PortPlate(store: store, direction: .output)
                        DINSocket(size: 27)
                    }
                }
            }
            Legend(store: store)
            ScopeView(store: store)
                .screen()
                .frame(minHeight: 160)
            HStack(spacing: 6) {
                Text("Scope").panelLabel()
                ForEach([5.0, 10.0, 30.0], id: \.self) { seconds in
                    Button("\(Int(seconds)) s") { store.scopeSeconds = seconds }
                        .buttonStyle(PanelButtonStyle())
                        .overlay(RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(store.scopeSeconds == seconds ? Panel.ink : .clear, lineWidth: 1.5))
                        .help("Show the last \(Int(seconds)) seconds")
                }
                Spacer()
                Text("0 – 127; pitch bend scaled to fit")
                    .font(.system(size: 10))
                    .foregroundStyle(Panel.inkSoft)
            }
        }
    }

    private var spyHelp: String {
        switch store.spyState {
        case .active: "The spy driver is copying everything Logic Pro sends to MIDI devices"
        case .installedNotLoaded: "The spy driver is installed but the MIDI server hasn't loaded it yet"
        case .notInstalled: store.thruEnabled ? "OUT comes only through the MxMidiPRO ▸ thru ports"
            : "OUT isn't monitored: set it up from the OUT plate"
        }
    }
}

private struct Legend: View {
    @Bindable var store: MonitorStore

    var body: some View {
        HStack(spacing: 14) {
            ForEach(Trace.allCases) { trace in
                HStack(spacing: 3) {
                    LegendToggle(trace: trace, isOn: Binding(
                        get: { store.traces.contains(trace) },
                        set: { on in if on { store.traces.insert(trace) } else { store.traces.remove(trace) } }),
                                 title: trace == .controller ? "CC \(store.controllerNumber)" : nil)
                    if trace == .controller { ControllerMenu(store: store) }
                }
                .help(help(trace))
            }
            Spacer(minLength: 0)
        }
    }

    private func help(_ trace: Trace) -> String {
        switch trace {
        case .channelPressure: "Plot channel (mono) aftertouch"
        case .polyPressure: "Plot polyphonic aftertouch, every note on one line"
        case .velocity: "Plot note-on velocities, each held until the next note"
        case .pitchBend: "Plot pitch bend, 0 … 16383 scaled to 0 … 127 (centre is 64)"
        case .controller: "Plot one controller; pick which with the arrow"
        }
    }
}

private struct ControllerMenu: View {
    @Bindable var store: MonitorStore

    private static let common: [Int] = [1, 2, 4, 7, 10, 11, 64, 71, 74, 91, 93]

    var body: some View {
        Menu {
            ForEach(Self.common, id: \.self) { cc in
                Button("CC \(cc)  \(MIDINames.controller(UInt8(cc)))") { store.controllerNumber = cc }
            }
            Divider()
            ForEach(0..<8) { block in
                Menu("CC \(block * 16) – \(block * 16 + 15)") {
                    ForEach(block * 16..<(block * 16 + 16), id: \.self) { cc in
                        let name = MIDINames.controller(UInt8(cc))
                        Button(name.isEmpty ? "CC \(cc)" : "CC \(cc)  \(name)") { store.controllerNumber = cc }
                    }
                }
            }
        } label: {
            Image(systemName: "chevron.down")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(Panel.ink)
    }
}

// MARK: Port plates

private struct PortPlate: View {
    @Bindable var store: MonitorStore
    let direction: MIDIDirection
    @State private var open = false

    var body: some View {
        let ports = store.ports(for: direction).filter(\.online)
        let shown = ports.filter { !store.hiddenPorts.contains($0.id) }
        let scope = direction == .input ? store.inScope : store.outScope
        Button { open.toggle() } label: {
            Plate {
                HStack(spacing: 6) {
                    Text(direction.label)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(direction == .input ? Panel.inTint : Panel.outTint)
                    Text(summary(shown: shown, all: ports, scope: scope))
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
            }
            .frame(width: 186, alignment: .trailing)
        }
        .buttonStyle(.plain)
        .help(direction == .input ? "Devices whose messages to Logic Pro are shown" : "Devices whose messages from Logic Pro are shown")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            PortPicker(store: store, direction: direction)
        }
    }

    private func summary(shown: [PortInfo], all: [PortInfo], scope: PortScope) -> String {
        if all.isEmpty { return "No \(scope == .usb ? "USB devices" : "ports")" }
        if shown.count == 1 { return shown[0].name }
        if shown.count == all.count { return "\(scope.shortTitle) (\(all.count))" }
        return "\(shown.count) of \(all.count) ports"
    }
}

private struct PortPicker: View {
    @Bindable var store: MonitorStore
    let direction: MIDIDirection

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(direction == .input ? "IN — what devices send to Logic Pro" : "OUT — what Logic Pro sends to devices")
                .font(.headline)
            Picker("Show", selection: direction == .input ? $store.inScope : $store.outScope) {
                ForEach(PortScope.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            Divider()
            let ports = store.ports(for: direction)
            if ports.isEmpty {
                Text("Nothing of this kind is connected.").foregroundStyle(.secondary)
            } else {
                ForEach(ports) { port in
                    Toggle(isOn: Binding(
                        get: { !store.hiddenPorts.contains(port.id) },
                        set: { show in
                            if show { store.hiddenPorts.remove(port.id) } else { store.hiddenPorts.insert(port.id) }
                        })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(port.name)
                            Text(detail(port)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if direction == .output {
                Divider()
                HStack(spacing: 6) {
                    SquareLamp(on: store.spyState == .active, size: 14)
                    Text(store.spyState == .active ? "Spy driver active" : "Spy driver not active")
                }
                Toggle("Thru ports for Logic Pro (MxMidiPRO ▸ device)", isOn: $store.thruEnabled)
                Button("Set Up OUT Monitoring…") { store.showOutSetup = true }
            }
        }
        .padding(14)
        .frame(width: 360)
    }

    private func detail(_ port: PortInfo) -> String {
        var parts = [port.transport.rawValue]
        if !port.manufacturer.isEmpty { parts.append(port.manufacturer) }
        if !port.driverNote.isEmpty { parts.append(port.driverNote) }
        if !port.online { parts.append("offline") }
        return parts.joined(separator: " · ")
    }
}

// MARK: Status strip

private struct StatusStrip: View {
    @Bindable var store: MonitorStore

    var body: some View {
        HStack(spacing: 8) {
            SquareLamp(on: store.spyState == .active || store.thruEnabled,
                       tint: store.spyState == .active ? Panel.inTint : Panel.pauseTint, size: 14)
            Text(spyText).panelLabel()
            if !store.spyIsCurrent {
                Button("Update Driver…") { store.showOutSetup = true }
                    .buttonStyle(PanelButtonStyle())
            } else if store.spyState != .active {
                Button(store.spyState == .installedNotLoaded ? "Restart MIDI Server…" : "Set Up OUT…") {
                    store.showOutSetup = true
                }
                .buttonStyle(PanelButtonStyle())
            }
            if let error = store.engineError {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            }
            Spacer(minLength: 8)
            Text(stats)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Panel.ink)
                .lineLimit(1)
        }
        .frame(height: 22)
    }

    private var spyText: String {
        switch store.spyState {
        case .active: "OUT: spy driver active — sees everything Logic Pro sends"
        case .installedNotLoaded: "OUT: spy driver installed — the MIDI server loads it when it restarts"
        case .notInstalled:
            store.thruEnabled ? "OUT: thru ports only — route Logic Pro's outputs to “MxMidiPRO ▸ …”"
                : "OUT: not monitored — install the spy driver or turn on thru ports"
        }
    }

    private var stats: String {
        var text = "IN \(store.inCount.formatted())   OUT \(store.outCount.formatted())   \(Int(store.rate)) msg/s   showing \(store.events.count.formatted())"
        if store.droppedCount > 0 { text += "   dropped \(store.droppedCount.formatted())" }
        return text
    }
}
