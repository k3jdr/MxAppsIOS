//
//  DeviceViews.swift — MxModxUSB
//
//  The MODX as the Mac sees it — the USB device and its interfaces, the three MIDI ports with everything CoreMIDI
//  knows about them, the audio interface — and the MIDI it is sending right now.
//

import SwiftUI

struct ConnectionView: View {
    let model: ModxModel

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 400), spacing: 16, alignment: .top)], spacing: 16) {
                Card(title: "USB Device", systemImage: "cable.connector") {
                    if let usb = model.usb {
                        ValueRow(name: "Product", value: usb.productName)
                        ValueRow(name: "Vendor", value: usb.vendorName)
                        ValueRow(name: "Vendor ID / Product ID", value: String(format: "0x%04X / 0x%04X", usb.vendorID, usb.productID))
                        ValueRow(name: "Device release", value: USBDeviceInfo.bcd(usb.deviceRelease))
                        ValueRow(name: "USB version", value: USBDeviceInfo.bcd(usb.usbVersion))
                        ValueRow(name: "Speed", value: usb.speedText)
                        ValueRow(name: "Configurations", value: "\(usb.configurations), using \(usb.currentConfiguration)")
                        ValueRow(name: "Device class", value: usb.deviceClass == 239 ? "Miscellaneous (interface association)" : "\(usb.deviceClass)")
                        ValueRow(name: "Serial number", value: usb.serialNumber ?? "none")
                        ValueRow(name: "Location / address", value: String(format: "0x%08X / %d", usb.locationID, usb.address))
                    } else {
                        Text("No Yamaha MODX on USB.").foregroundStyle(.secondary)
                    }
                }
                Card(title: "USB Interfaces", systemImage: "square.split.2x2") {
                    if let usb = model.usb, !usb.interfaces.isEmpty {
                        ForEach(usb.interfaces) { i in
                            ValueRow(name: "Interface \(i.number)" + (i.alternate > 0 ? " alt \(i.alternate)" : ""),
                                     value: i.kind, detail: "\(i.endpoints) ep")
                        }
                    } else {
                        Text("No interfaces listed.").foregroundStyle(.secondary)
                    }
                }
                ForEach(ModxPort.allCases) { port in
                    Card(title: "MIDI \(port.title)", systemImage: "pianokeys") {
                        Text(port.role).font(.callout).foregroundStyle(.secondary)
                        ValueRow(name: "Endpoint", value: model.portNames[port.rawValue].isEmpty ? "—" : model.portNames[port.rawValue])
                        ValueRow(name: "Messages received", value: "\(model.live.counts[port.rawValue])")
                        ValueRow(name: "Last message", value: model.live.lastActivity[port.rawValue].map {
                            $0.formatted(date: .omitted, time: .standard) } ?? "none yet")
                        DisclosureGroup("CoreMIDI properties (\(model.midiProperties[port.rawValue].count))") {
                            ForEach(model.midiProperties[port.rawValue], id: \.0) { key, value in
                                ValueRow(name: key, value: value)
                            }
                        }
                        .font(.callout)
                    }
                }
                Card(title: "USB Audio", systemImage: "speaker.wave.2") {
                    if let a = model.audio {
                        ValueRow(name: "Device", value: "\(a.name) (\(a.manufacturer))")
                        ValueRow(name: "Transport", value: a.transport)
                        ValueRow(name: "Channels", value: "\(a.inputChannels) from the MODX · \(a.outputChannels) to the MODX")
                        ValueRow(name: "Sample rate", value: "\(Int(a.sampleRate)) Hz")
                        ValueRow(name: "Available rates", value: a.sampleRates.map { "\(Int($0))" }.joined(separator: ", "))
                        ValueRow(name: "Latency in / out", value: "\(a.inputLatency) / \(a.outputLatency) frames")
                        ValueRow(name: "Safety offset in / out", value: "\(a.inputSafetyOffset) / \(a.outputSafetyOffset) frames")
                        ValueRow(name: "Buffer", value: "\(a.bufferFrames) frames")
                        ValueRow(name: "In use by an app", value: a.isRunning ? "Yes" : "No")
                        DisclosureGroup("Channel names") {
                            ForEach(Array(a.inputNames.enumerated()), id: \.offset) { i, n in ValueRow(name: "In \(i + 1)", value: n) }
                            ForEach(Array(a.outputNames.enumerated()), id: \.offset) { i, n in ValueRow(name: "Out \(i + 1)", value: n) }
                        }
                        .font(.callout)
                        ValueRow(name: "UID", value: a.uid)
                    } else {
                        Text("No MODX audio device. (MODX audio needs the Yamaha Steinberg USB Driver on some Macs.)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(18)
        }
    }
}

struct ActivityView: View {
    @Bindable var model: ModxModel
    @State private var showRequests = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                Picker("", selection: $showRequests) {
                    Text("From the MODX").tag(false)
                    Text("Requests to the MODX (\(model.requests.count))").tag(true)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                if showRequests {
                    if model.problems > 0 {
                        Label("\(model.problems) unanswered", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    } else {
                        Label("All answered", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(ModxPort.allCases) { port in
                        HStack(spacing: 6) {
                            Lamp(on: (model.live.lastActivity[port.rawValue].map { Date().timeIntervalSince($0) < 1 }) ?? false,
                                 color: Modx.live)
                            Text("\(port.title)  \(model.live.counts[port.rawValue])").monospacedDigit()
                        }
                    }
                    if let bpm = model.live.clockBPM { Text(String(format: "Clock %.1f BPM", bpm)).foregroundStyle(.secondary) }
                }
                Spacer()
                if !showRequests {
                    Toggle("Show Clock & Active Sensing", isOn: $model.showTimingMessages).toggleStyle(.checkbox)
                    Button("Clear") { model.clearActivity() }
                }
            }
            .padding(12)
            Divider()
            if showRequests {
                Table(model.requests.reversed()) {
                    TableColumn("Time") { (r: ModxRequestRecord) in
                        Text(r.time.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3)))).monospacedDigit()
                    }
                    .width(96)
                    TableColumn("Request") { (r: ModxRequestRecord) in Text(r.request) }.width(min: 170, ideal: 200)
                    TableColumn("Answer") { (r: ModxRequestRecord) in
                        Text(r.outcome).foregroundStyle(r.problem ? .orange : .secondary)
                    }
                    .width(min: 150, ideal: 220)
                    TableColumn("Bytes sent") { (r: ModxRequestRecord) in Text(r.bytes).font(.caption.monospaced()) }
                }
            } else {
                Table(model.activity.reversed()) {
                    TableColumn("Time") { (a: ModxActivity) in
                        Text(a.time.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3)))).monospacedDigit()
                    }
                    .width(96)
                    TableColumn("Port") { (a: ModxActivity) in Text(a.port.title) }.width(54)
                    TableColumn("Message") { (a: ModxActivity) in Text(a.text).font(.callout.monospaced()) }
                }
                .overlay {
                    if model.activity.isEmpty {
                        ContentUnavailableView("Play the MODX", systemImage: "pianokeys",
                                               description: Text("Notes, controllers and program changes it sends over USB appear here."))
                    }
                }
            }
        }
    }
}
