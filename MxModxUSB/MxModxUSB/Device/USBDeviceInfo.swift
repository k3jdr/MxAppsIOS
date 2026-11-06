//
//  USBDeviceInfo.swift — MxModxUSB
//
//  What macOS's USB stack knows about the MODX: its device descriptor and its interfaces, from the I/O Registry
//  (IOUSBHostDevice with Yamaha's vendor ID, 0x0499). Read-only.
//

import Foundation
import IOKit

struct USBInterfaceInfo: Identifiable, Hashable {
    let number: Int
    let alternate: Int
    let interfaceClass: Int
    let subclass: Int
    let interfaceProtocol: Int
    let endpoints: Int
    var id: String { "\(number).\(alternate)" }

    var kind: String {
        switch (interfaceClass, subclass) {
        case (1, 1): "Audio Control"
        case (1, 2): "Audio Streaming"
        case (1, 3): "MIDI Streaming"
        case (0xFF, _): "Vendor specific"
        case (0xFE, _): "Application specific"
        default: "Class \(interfaceClass), subclass \(subclass)"
        }
    }
}

struct USBDeviceInfo: Equatable {
    var productName = ""
    var vendorName = ""
    var vendorID = 0
    var productID = 0
    var deviceRelease = 0
    var usbVersion = 0
    var linkSpeed = 0
    var locationID = 0
    var address = 0
    var configurations = 0
    var currentConfiguration = 0
    var deviceClass = 0
    var serialNumber: String?
    var maxPacketSize0 = 0
    var interfaces: [USBInterfaceInfo] = []

    static let yamahaVendorID = 0x0499

    var speedText: String {
        switch linkSpeed {
        case 0: "—"
        case 480_000_000: "High Speed, 480 Mb/s"
        case 12_000_000: "Full Speed, 12 Mb/s"
        case 5_000_000_000: "SuperSpeed, 5 Gb/s"
        default: "\(linkSpeed / 1_000_000) Mb/s"
        }
    }

    static func bcd(_ value: Int) -> String { String(format: "%X.%02X", value >> 8, value & 0xFF) }

    static func find() -> USBDeviceInfo? {
        // Matching on idVendor in the dictionary finds nothing for IOUSBHostDevice on macOS 27, so every USB device
        // is matched and Yamaha's picked out below.
        guard let matching = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary? else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
            let props = properties(service)
            let name = props["USB Product Name"] as? String ?? props["kUSBProductString"] as? String ?? ""
            guard (props["idVendor"] as? Int) == yamahaVendorID, name.hasPrefix("MODX") else { continue }
            var info = USBDeviceInfo()
            info.productName = name
            info.vendorName = props["USB Vendor Name"] as? String ?? ""
            info.vendorID = props["idVendor"] as? Int ?? 0
            info.productID = props["idProduct"] as? Int ?? 0
            info.deviceRelease = props["bcdDevice"] as? Int ?? 0
            info.usbVersion = props["bcdUSB"] as? Int ?? 0
            info.linkSpeed = props["UsbLinkSpeed"] as? Int ?? 0
            info.locationID = props["locationID"] as? Int ?? 0
            info.address = props["USB Address"] as? Int ?? 0
            info.configurations = props["bNumConfigurations"] as? Int ?? 0
            info.currentConfiguration = props["kUSBCurrentConfiguration"] as? Int ?? 0
            info.deviceClass = props["bDeviceClass"] as? Int ?? 0
            info.maxPacketSize0 = props["bMaxPacketSize0"] as? Int ?? 0
            info.serialNumber = props["USB Serial Number"] as? String ?? props["kUSBSerialNumberString"] as? String
            info.interfaces = interfaces(below: service)
            return info
        }
        return nil
    }

    private static func properties(_ entry: io_registry_entry_t) -> [String: Any] {
        var dict: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &dict, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let result = dict?.takeRetainedValue() as? [String: Any] else { return [:] }
        return result
    }

    private static func interfaces(below device: io_registry_entry_t) -> [USBInterfaceInfo] {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(device, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively),
                                            &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var found: [USBInterfaceInfo] = []
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer { IOObjectRelease(entry); entry = IOIteratorNext(iterator) }
            guard IOObjectConformsTo(entry, "IOUSBHostInterface") != 0 else { continue }
            let p = properties(entry)
            found.append(USBInterfaceInfo(number: p["bInterfaceNumber"] as? Int ?? 0,
                                          alternate: p["bAlternateSetting"] as? Int ?? 0,
                                          interfaceClass: p["bInterfaceClass"] as? Int ?? 0,
                                          subclass: p["bInterfaceSubClass"] as? Int ?? 0,
                                          interfaceProtocol: p["bInterfaceProtocol"] as? Int ?? 0,
                                          endpoints: p["bNumEndpoints"] as? Int ?? 0))
        }
        return found.sorted { ($0.number, $0.alternate) < ($1.number, $1.alternate) }
    }
}
