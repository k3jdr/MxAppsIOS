import AVFoundation

/// What the running camera lets the app control. Many cameras manage focus themselves and report none of this.
struct CameraControls: Equatable {
    var supportsFocusPoint = false
    var supportsFocusLock = false
    var focusLocked = false
    var supportsExposureLock = false
    var exposureLocked = false
    var supportsWhiteBalanceLock = false
    var formatDescription = ""
    /// Effects that change the picture, and so the measurements. The user controls these from the menu bar's Video item.
    var effectWarnings: [String] = []
}

/// One AVCaptureSession. Frames arrive on a private queue; everything else runs on the session queue.
final class CaptureEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// Called on the video queue with a 32BGRA, IOSurface-backed buffer.
    var onFrame: ((CVPixelBuffer) -> Void)?
    /// Called on the main queue after the camera starts or a control changes.
    var onControlsChanged: ((CameraControls) -> Void)?

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.k3jdr.MxOpenCVD.session")
    private let videoQueue = DispatchQueue(label: "com.k3jdr.MxOpenCVD.video", qos: .userInteractive)
    private var device: AVCaptureDevice?

    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var lastFrameTime: CFTimeInterval = 0
    private var startTime: CFTimeInterval = 0
    private var measuredRate: Double = 0

    override init() {
        super.init()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        output.setSampleBufferDelegate(self, queue: videoQueue)
    }

    /// The newest frame from the camera, for a trigger or a freeze.
    var latestFrame: CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    var framesPerSecond: Double {
        lock.lock()
        defer { lock.unlock() }
        return measuredRate
    }

    /// Seconds without a frame since this camera started; used to spot a camera that has gone quiet.
    var secondsSinceLastFrame: CFTimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return CACurrentMediaTime() - max(lastFrameTime, startTime)
    }

    func start(_ device: AVCaptureDevice, completion: @escaping (Error?) -> Void) {
        sessionQueue.async { [self] in
            do {
                try configure(device)
                session.startRunning()
                try applyBestFormat(to: device)
                lock.lock()
                startTime = CACurrentMediaTime()
                lastFrameTime = 0
                measuredRate = 0
                latest = nil
                lock.unlock()
                self.device = device
                publishControls()
                DispatchQueue.main.async { completion(nil) }
            } catch {
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            session.stopRunning()
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            session.commitConfiguration()
            device = nil
            lock.lock()
            latest = nil
            lock.unlock()
        }
    }

    private func configure(_ device: AVCaptureDevice) throws {
        let input = try AVCaptureDeviceInput(device: device)

        session.beginConfiguration()
        session.inputs.forEach(session.removeInput)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw NSError(domain: "MxOpenCVD", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(device.localizedName) can't be used right now."])
        }
        session.addInput(input)
        if session.outputs.isEmpty, session.canAddOutput(output) {
            session.addOutput(output)
        }

        // A mirrored image can't be read as text, and the data output must not follow the preview's habit.
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        session.commitConfiguration()

        // Center Stage crops and moves the picture, which would change every measurement.
        AVCaptureDevice.centerStageControlMode = .app
        AVCaptureDevice.isCenterStageEnabled = false
    }

    /// Must follow startRunning: macOS has no input-priority preset, so until then the session's preset wins
    /// and the iPhone would stay at 1080p instead of its 1440p.
    private func applyBestFormat(to device: AVCaptureDevice) throws {
        guard let format = CameraCatalog.bestFormat(of: device), format != device.activeFormat else { return }
        try device.lockForConfiguration()
        device.activeFormat = format
        device.unlockForConfiguration()
    }

    private func publishControls() {
        guard let device else { return }
        var controls = CameraControls()
        controls.supportsFocusPoint = device.isFocusPointOfInterestSupported && device.isFocusModeSupported(.autoFocus)
        controls.supportsFocusLock = device.isFocusModeSupported(.locked) && device.isFocusModeSupported(.continuousAutoFocus)
        controls.focusLocked = device.focusMode == .locked
        controls.supportsExposureLock = device.isExposureModeSupported(.locked) && device.isExposureModeSupported(.continuousAutoExposure)
        controls.exposureLocked = device.exposureMode == .locked
        controls.supportsWhiteBalanceLock = device.isWhiteBalanceModeSupported(.locked) && device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance)
        controls.formatDescription = CameraCatalog.describe(device.activeFormat)
        if device.isPortraitEffectActive { controls.effectWarnings.append("Portrait mode is blurring the background.") }
        if device.isStudioLightActive { controls.effectWarnings.append("Studio Light is changing the lighting.") }
        if device.isCenterStageActive { controls.effectWarnings.append("Center Stage is cropping the picture.") }
        let report = onControlsChanged
        DispatchQueue.main.async { report?(controls) }
    }

    func setFocus(at point: CGPoint) {
        sessionQueue.async { [self] in
            withLockedDevice { device in
                guard device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) else { return }
                device.focusPointOfInterest = point
                device.focusMode = .autoFocus
            }
        }
    }

    func setFocusLocked(_ locked: Bool) {
        sessionQueue.async { [self] in
            withLockedDevice { device in
                let mode: AVCaptureDevice.FocusMode = locked ? .locked : .continuousAutoFocus
                if device.isFocusModeSupported(mode) { device.focusMode = mode }
            }
        }
    }

    func setExposureLocked(_ locked: Bool) {
        sessionQueue.async { [self] in
            withLockedDevice { device in
                let mode: AVCaptureDevice.ExposureMode = locked ? .locked : .continuousAutoExposure
                if device.isExposureModeSupported(mode) { device.exposureMode = mode }
            }
        }
    }

    private func withLockedDevice(_ change: (AVCaptureDevice) -> Void) {
        guard let device, (try? device.lockForConfiguration()) != nil else { return }
        change(device)
        device.unlockForConfiguration()
        publishControls()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = CACurrentMediaTime()
        lock.lock()
        if lastFrameTime > 0 {
            let rate = 1 / max(now - lastFrameTime, 0.001)
            measuredRate = measuredRate == 0 ? rate : measuredRate * 0.9 + rate * 0.1
        }
        lastFrameTime = now
        latest = buffer
        lock.unlock()
        onFrame?(buffer)
    }
}
