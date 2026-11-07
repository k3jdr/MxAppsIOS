//
//  AudioDeviceInfo.swift — MxModxUSB
//
//  The MODX as a USB audio interface, as Core Audio sees it: channels each way and their names, sample rates,
//  latency and buffer size. Read-only.
//

import CoreAudio
import Foundation

struct AudioDeviceInfo: Equatable {
    var name = ""
    var manufacturer = ""
    var uid = ""
    var modelUID = ""
    var transport = ""
    var sampleRate = 0.0
    var sampleRates: [Double] = []
    var inputChannels = 0
    var outputChannels = 0
    var inputNames: [String] = []
    var outputNames: [String] = []
    var inputLatency = 0
    var outputLatency = 0
    var inputSafetyOffset = 0
    var outputSafetyOffset = 0
    var bufferFrames = 0
    var isRunning = false
    /// Core Audio's ID for the device, while it's connected (the audio meter opens it by this).
    var deviceID: AudioDeviceID = 0

    static func find() -> AudioDeviceInfo? {
        for device in devices() {
            let name = string(device, kAudioObjectPropertyName) ?? ""
            guard name.hasPrefix("MODX") else { continue }
            var info = AudioDeviceInfo()
            info.name = name
            info.deviceID = device
            info.manufacturer = string(device, kAudioObjectPropertyManufacturer) ?? ""
            info.uid = string(device, kAudioDevicePropertyDeviceUID) ?? ""
            info.modelUID = string(device, kAudioDevicePropertyModelUID) ?? ""
            info.transport = transportName(value(device, kAudioDevicePropertyTransportType) ?? 0)
            info.sampleRate = double(device, kAudioDevicePropertyNominalSampleRate) ?? 0
            info.sampleRates = rates(device)
            info.inputChannels = channels(device, kAudioObjectPropertyScopeInput)
            info.outputChannels = channels(device, kAudioObjectPropertyScopeOutput)
            info.inputNames = channelNames(device, kAudioObjectPropertyScopeInput, info.inputChannels)
            info.outputNames = channelNames(device, kAudioObjectPropertyScopeOutput, info.outputChannels)
            info.inputLatency = Int(value(device, kAudioDevicePropertyLatency, scope: kAudioObjectPropertyScopeInput) ?? 0)
            info.outputLatency = Int(value(device, kAudioDevicePropertyLatency, scope: kAudioObjectPropertyScopeOutput) ?? 0)
            info.inputSafetyOffset = Int(value(device, kAudioDevicePropertySafetyOffset, scope: kAudioObjectPropertyScopeInput) ?? 0)
            info.outputSafetyOffset = Int(value(device, kAudioDevicePropertySafetyOffset, scope: kAudioObjectPropertyScopeOutput) ?? 0)
            info.bufferFrames = Int(value(device, kAudioDevicePropertyBufferFrameSize) ?? 0)
            info.isRunning = (value(device, kAudioDevicePropertyDeviceIsRunningSomewhere) ?? 0) != 0
            return info
        }
        return nil
    }

    /// Calls `changed` on the main queue when audio devices come and go.
    static func watchDevices(_ changed: @escaping @Sendable () -> Void) {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in changed() }
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private static func devices() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                               element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> String? {
        var addr = address(selector, scope, element)
        guard AudioObjectHasProperty(object, &addr) else { return nil }
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func value(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                              scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var addr = address(selector, scope)
        guard AudioObjectHasProperty(object, &addr) else { return nil }
        var result: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &result) == noErr ? result : nil
    }

    private static func double(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Double? {
        var addr = address(selector)
        var result: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &result) == noErr ? result : nil
    }

    private static func rates(_ device: AudioObjectID) -> [Double] {
        var addr = address(kAudioDevicePropertyAvailableNominalSampleRates)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &ranges) == noErr else { return [] }
        return Array(Set(ranges.flatMap { [$0.mMinimum, $0.mMaximum] })).sorted()
    }

    private static func channels(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func channelNames(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope, _ count: Int) -> [String] {
        guard count > 0 else { return [] }
        return (1...count).map { channel in
            let name = string(device, kAudioObjectPropertyElementName, scope: scope, element: UInt32(channel)) ?? ""
            return name.isEmpty ? "Channel \(channel)" : name
        }
    }

    private static func transportName(_ value: UInt32) -> String {
        switch value {
        case kAudioDeviceTransportTypeUSB: "USB"
        case kAudioDeviceTransportTypeBuiltIn: "Built-in"
        case kAudioDeviceTransportTypeVirtual: "Virtual"
        case kAudioDeviceTransportTypeAggregate: "Aggregate"
        case 0: "—"
        default: "Other"
        }
    }
}
