import AVFoundation

/// The acquisition order: the iPhone close to the part first, then the USB camera, then the MacBook's own.
enum CameraTier: Int, CaseIterable, Comparable {
    case iPhone = 1
    case usb
    case builtIn
    case other

    static func < (a: CameraTier, b: CameraTier) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .iPhone: return "iPhone (Continuity Camera)"
        case .usb: return "USB web camera"
        case .builtIn: return "MacBook camera"
        case .other: return "Other camera"
        }
    }

    var role: String {
        switch self {
        case .iPhone: return "Primary"
        case .usb: return "Secondary"
        case .builtIn: return "Third"
        case .other: return "Last resort"
        }
    }

    var symbol: String {
        switch self {
        case .iPhone: return "iphone"
        case .usb: return "web.camera"
        case .builtIn: return "laptopcomputer"
        case .other: return "video"
        }
    }
}

struct CameraInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let model: String
    let tier: CameraTier
    let isDeskView: Bool
    var isSuspended: Bool

    /// Auto selection takes the first of these. Desk View only shows when someone picks it.
    var canBeChosenAutomatically: Bool { !isDeskView && !isSuspended }
}

enum CameraCatalog {
    private static let transportUSB = Int32(bitPattern: 0x7573_6220)  // 'usb ', IOAudioTypes' kIOAudioDeviceTransportTypeUSB

    static func makeDiscovery() -> AVCaptureDevice.DiscoverySession {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.continuityCamera, .deskViewCamera, .external, .builtInWideAngleCamera],
                                         mediaType: .video, position: .unspecified)
    }

    static func tier(of device: AVCaptureDevice) -> CameraTier {
        tier(isContinuity: device.deviceType == .continuityCamera || device.isContinuityCamera,
             isDeskView: device.deviceType == .deskViewCamera,
             isBuiltIn: device.deviceType == .builtInWideAngleCamera,
             isUSB: device.transportType == transportUSB,
             model: device.modelID)
    }

    /// Virtual cameras and capture cards also report as external, and they shouldn't outrank the MacBook's camera.
    static func tier(isContinuity: Bool, isDeskView: Bool, isBuiltIn: Bool, isUSB: Bool, model: String) -> CameraTier {
        if isContinuity || model.hasPrefix("iPhone") { return .iPhone }
        // A MacBook has a Desk View of its own, and that one belongs with the MacBook's camera.
        if isBuiltIn || isDeskView { return .builtIn }
        return isUSB ? .usb : .other
    }

    static func info(for device: AVCaptureDevice) -> CameraInfo {
        CameraInfo(id: device.uniqueID, name: device.localizedName, model: device.modelID, tier: tier(of: device),
                   isDeskView: device.deviceType == .deskViewCamera, isSuspended: device.isSuspended)
    }

    /// In acquisition order, with Desk View after the iPhone's main camera.
    static func ranked(_ devices: [AVCaptureDevice]) -> [CameraInfo] {
        inRankOrder(devices.map(info(for:)))
    }

    static func inRankOrder(_ cameras: [CameraInfo]) -> [CameraInfo] {
        cameras.sorted {
            if $0.tier != $1.tier { return $0.tier < $1.tier }
            if $0.isDeskView != $1.isDeskView { return !$0.isDeskView }
            return $0.name < $1.name
        }
    }

    /// The camera to use, from a list in rank order: the pinned one when it can run, otherwise the highest-ranked that can.
    static func choose(from cameras: [CameraInfo], pinned: String?, excluding stalled: Set<String>) -> CameraInfo? {
        if let pinned, let camera = cameras.first(where: { $0.id == pinned }), !camera.isSuspended, !stalled.contains(camera.id) {
            return camera
        }
        return cameras.first { $0.canBeChosenAutomatically && !stalled.contains($0.id) }
    }

    /// The largest landscape format that still runs at video rate. A close-up needs the pixels more than extra
    /// frames, so when sizes tie it takes the slowest rate that qualifies, which leaves the most light per frame.
    static func bestFormat(of device: AVCaptureDevice, maxWidth: Int32 = 4096) -> AVCaptureDevice.Format? {
        let options = device.formats.map { format -> FormatOption in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return FormatOption(width: size.width, height: size.height,
                                maxRate: format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
        }
        return bestOption(in: options, maxWidth: maxWidth).map { device.formats[$0] }
    }

    struct FormatOption {
        let width: Int32
        let height: Int32
        let maxRate: Double
        var pixels: Int64 { Int64(width) * Int64(height) }
    }

    /// The index of the option to use. Portrait and square formats only count if there is nothing else.
    static func bestOption(in options: [FormatOption], maxWidth: Int32 = 4096) -> Int? {
        var candidates = Array(options.indices).filter { options[$0].width <= maxWidth }
        let landscape = candidates.filter { options[$0].width > options[$0].height }
        if !landscape.isEmpty { candidates = landscape }
        let smooth = candidates.filter { options[$0].maxRate >= 24 }
        if !smooth.isEmpty { candidates = smooth }
        return candidates.max { a, b in
            if options[a].pixels != options[b].pixels { return options[a].pixels < options[b].pixels }
            return options[a].maxRate > options[b].maxRate
        }
    }

    static func describe(_ format: AVCaptureDevice.Format) -> String {
        let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let rate = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
        return "\(size.width) × \(size.height) at \(Int(rate.rounded())) fps"
    }
}
