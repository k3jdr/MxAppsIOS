//
//  MIDIPorts.swift — MxMidiPRO
//
//  What each MIDI source and destination is: USB (class compliant, or a maker's USB driver such as Roland's or
//  Yamaha Steinberg's), Bluetooth, Network, an IAC bus, or a virtual port an app made (Logic Pro Virtual Out).
//

import CoreMIDI
import Foundation

enum PortTransport: String {
    case usb = "USB"
    case bluetooth = "Bluetooth"
    case network = "Network"
    case iac = "IAC"
    case virtual = "Virtual"
    case own = "MxMidiPRO"

    var isHardware: Bool { self == .usb || self == .bluetooth || self == .network }
}

/// Which ports the IN and OUT plates show. USB devices is the default: Logic Pro and the gear on its cables.
enum PortScope: String, CaseIterable, Identifiable {
    case usb, hardware, everything

    var id: String { rawValue }

    var title: String {
        switch self {
        case .usb: "USB devices"
        case .hardware: "All hardware (USB, Bluetooth, Network)"
        case .everything: "Everything (also IAC and app ports)"
        }
    }

    var shortTitle: String {
        switch self {
        case .usb: "USB devices"
        case .hardware: "All hardware"
        case .everything: "Everything"
        }
    }

    func includes(_ transport: PortTransport) -> Bool {
        switch self {
        case .usb: transport == .usb
        case .hardware: transport.isHardware
        case .everything: transport != .own
        }
    }
}

struct PortInfo: Identifiable, Equatable {
    let id: MIDIUniqueID
    var name: String
    var transport: PortTransport
    /// The driver's bundle identifier (com.apple.AppleMIDIUSBDriver, jp.co.roland.…), empty for virtual ports.
    var driver: String
    var manufacturer: String
    var isSource: Bool
    var online: Bool

    var driverNote: String {
        switch driver {
        case "": transport == .virtual ? "made by an app" : ""
        case "com.apple.AppleMIDIUSBDriver": "class-compliant USB"
        case let d where d.hasPrefix("com.apple."): ""
        default: "\(driver) driver"
        }
    }
}

enum MIDIProps {
    static func string(_ object: MIDIObjectRef, _ key: CFString) -> String? {
        var value: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(object, key, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func integer(_ object: MIDIObjectRef, _ key: CFString) -> Int32? {
        var value: Int32 = 0
        return MIDIObjectGetIntegerProperty(object, key, &value) == noErr ? value : nil
    }

    static func uniqueID(_ object: MIDIObjectRef) -> MIDIUniqueID {
        integer(object, kMIDIPropertyUniqueID) ?? 0
    }

    static func device(of endpoint: MIDIEndpointRef) -> MIDIDeviceRef? {
        var entity = MIDIEntityRef()
        guard MIDIEndpointGetEntity(endpoint, &entity) == noErr, entity != 0 else { return nil }
        var device = MIDIDeviceRef()
        guard MIDIEntityGetDevice(entity, &device) == noErr, device != 0 else { return nil }
        return device
    }

    static func transport(driver: String?, hasDevice: Bool) -> PortTransport {
        guard hasDevice else { return .virtual }
        let d = driver ?? ""
        if d == MIDIEngine.spyDriverID { return .own }
        if d.contains("IACDriver") { return .iac }
        if d.contains("NetworkDriver") || d.contains("RTP") { return .network }
        if d.contains("Bluetooth") { return .bluetooth }
        return .usb
    }

    static func info(for endpoint: MIDIEndpointRef, isSource: Bool) -> PortInfo {
        let device = device(of: endpoint)
        let driver = device.flatMap { string($0, kMIDIPropertyDriverOwner) }
        let name = string(endpoint, kMIDIPropertyDisplayName) ?? string(endpoint, kMIDIPropertyName) ?? "Unnamed"
        let manufacturer = device.flatMap { string($0, kMIDIPropertyManufacturer) } ?? ""
        let offline = (integer(endpoint, kMIDIPropertyOffline) ?? 0) != 0
        return PortInfo(id: uniqueID(endpoint), name: name,
                        transport: transport(driver: driver, hasDevice: device != nil),
                        driver: driver ?? "", manufacturer: manufacturer, isSource: isSource, online: !offline)
    }
}

/// Host time (mach_absolute_time) to seconds.
enum HostClock {
    private static let ratio: Double = {
        var base = mach_timebase_info_data_t()
        mach_timebase_info(&base)
        return Double(base.numer) / Double(base.denom) / 1e9
    }()

    static var now: UInt64 { mach_absolute_time() }

    static func seconds(_ ticks: UInt64) -> Double { Double(ticks) * ratio }

    static func ticks(_ seconds: Double) -> UInt64 { UInt64(max(0, seconds) / ratio) }

    /// Seconds from `earlier` to `later`, negative when `later` comes first.
    static func interval(from earlier: UInt64, to later: UInt64) -> Double {
        later >= earlier ? seconds(later - earlier) : -seconds(earlier - later)
    }
}
