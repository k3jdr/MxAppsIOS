//
//  ModxAudioMeter.swift — MxModxUSB
//
//  The MODX's USB audio as levels. The MODX sends the Mac 10 channels: USB Main L/R — its main mix, after every
//  effect, what its own outputs play — and USB 1–8, Parts whose Output is set straight to USB. The meter opens the
//  MODX's audio input (only while you ask it to listen), measures each channel's peak and RMS in dBFS 30 times a
//  second, and keeps the main mix's level over the last 6 seconds, in 20 ms steps: an echo shows there as repeats.
//  Nothing is recorded, played or sent to the MODX. macOS asks once for permission to use an audio input.
//

import AVFoundation
import CoreAudio
import Observation

@MainActor
@Observable
final class ModxAudioMeter {
    struct Channel: Equatable, Identifiable {
        let index: Int
        var name: String
        var peak: Float = ModxAudioMeter.floor
        var rms: Float = ModxAudioMeter.floor
        /// The highest peak of the last 1.5 seconds.
        var hold: Float = ModxAudioMeter.floor
        var id: Int { index }
    }

    nonisolated static let floor: Float = -96
    nonisolated static let historySeconds = 6.0
    nonisolated static let historyStep = 0.02
    nonisolated static var historyCount: Int { Int(historySeconds / historyStep) }

    private(set) var channels: [Channel] = []
    /// The main mix (the louder of USB Main L and R), RMS in dBFS, one value per 20 ms, oldest first.
    private(set) var history: [Float] = Array(repeating: ModxAudioMeter.floor, count: ModxAudioMeter.historyCount)
    private(set) var running = false
    private(set) var starting = false
    private(set) var problem: String?
    private(set) var sampleRate = 0.0

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private let collector = Collector()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var holdTimes: [Date] = []
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var device: AudioDeviceInfo?
    @ObservationIgnored private var restarts: [Date] = []

    /// Opens the MODX's audio input and starts measuring.
    func start(device: AudioDeviceInfo?) async {
        guard !running, !starting else { return }
        problem = nil
        guard let device, device.deviceID != 0, device.inputChannels > 0 else {
            problem = "The MODX's USB audio isn't on the Mac: connect the MODX by USB."
            return
        }
        starting = true
        defer { starting = false }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                problem = "MxModxUSB wasn't allowed to hear audio inputs. Allow it in System Settings ▸ Privacy & Security ▸ Microphone."
                return
            }
        default:
            problem = "MxModxUSB isn't allowed to hear audio inputs. Allow it in System Settings ▸ Privacy & Security ▸ Microphone."
            return
        }
        let engine = AVAudioEngine()
        if let failure = open(engine, device) {
            problem = failure
            return
        }
        self.engine = engine
        self.device = device
        restarts = []
        history = Array(repeating: Self.floor, count: Self.historyCount)
        running = true
        // macOS reports a configuration change when the input's device or format changes — often once just after
        // starting. If the engine stopped, open the MODX's input again (a few times at most); otherwise carry on.
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.configurationChanged() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.publish() }
        }
    }

    /// Points the engine's input at the MODX, taps it and starts it; the problem if it couldn't.
    private func open(_ engine: AVAudioEngine, _ device: AudioDeviceInfo) -> String? {
        let input = engine.inputNode
        var id = device.deviceID
        guard let unit = input.audioUnit,
              AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id,
                                   UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
            return "Couldn't open the MODX's audio input."
        }
        let format = input.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { return "The MODX's audio input has no channels open." }
        let count = Int(format.channelCount)
        collector.reset(channels: count, rate: format.sampleRate)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 512, format: format) { [collector] buffer, _ in collector.add(buffer) }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            return "Couldn't start listening to the MODX: \(error.localizedDescription)"
        }
        sampleRate = format.sampleRate
        if channels.count != count {
            channels = (0..<count).map { i in
                Channel(index: i, name: i < device.inputNames.count && !device.inputNames[i].isEmpty ? device.inputNames[i] : "Input \(i + 1)")
            }
            holdTimes = Array(repeating: .distantPast, count: count)
        }
        return nil
    }

    private func configurationChanged() {
        guard running, let engine, let device, !engine.isRunning else { return }
        let now = Date()
        restarts = restarts.filter { now.timeIntervalSince($0) < 10 } + [now]
        if restarts.count <= 3, open(engine, device) == nil { return }
        stop()
        problem = "The MODX's audio changed (connected again, or another sample rate) and couldn't be reopened: listen again."
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        running = false
        for i in channels.indices { channels[i].peak = Self.floor; channels[i].rms = Self.floor; channels[i].hold = Self.floor }
    }

    /// The level of channels together (the louder one), for a Part's output pair.
    func level(_ indices: [Int]) -> (rms: Float, peak: Float)? {
        let present = indices.filter { $0 < channels.count }
        guard running, !present.isEmpty else { return nil }
        return (present.map { channels[$0].rms }.max()!, present.map { channels[$0].peak }.max()!)
    }

    private func publish() {
        let snapshot = collector.take()
        let now = Date()
        for i in channels.indices where i < snapshot.peaks.count {
            let peak = Self.decibels(snapshot.peaks[i])
            channels[i].peak = peak
            channels[i].rms = Self.decibels(snapshot.rms[i])
            if peak >= channels[i].hold || now.timeIntervalSince(holdTimes[i]) > 1.5 {
                channels[i].hold = peak
                holdTimes[i] = now
            }
        }
        if !snapshot.history.isEmpty {
            history.append(contentsOf: snapshot.history.map(Self.decibels))
            if history.count > Self.historyCount { history.removeFirst(history.count - Self.historyCount) }
        }
    }

    static func decibels(_ amplitude: Float) -> Float {
        amplitude > 0 ? max(floor, 20 * log10(amplitude)) : floor
    }

    /// Gathers levels on the audio thread; the main thread takes them 30 times a second.
    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var peaks: [Float] = []
        private var squares: [Double] = []
        private var frames = 0
        private var stepFrames = 882
        private var stepSquares = 0.0
        private var stepCount = 0
        private var steps: [Float] = []

        func reset(channels: Int, rate: Double) {
            lock.lock(); defer { lock.unlock() }
            peaks = Array(repeating: 0, count: channels)
            squares = Array(repeating: 0, count: channels)
            frames = 0
            stepFrames = max(1, Int(rate * ModxAudioMeter.historyStep))
            stepSquares = 0
            stepCount = 0
            steps = []
        }

        func add(_ buffer: AVAudioPCMBuffer) {
            guard let data = buffer.floatChannelData else { return }
            let n = Int(buffer.frameLength)
            let count = Int(buffer.format.channelCount)
            lock.lock(); defer { lock.unlock() }
            guard count == peaks.count, n > 0 else { return }
            for c in 0..<count {
                let samples = data[c]
                var peak = peaks[c], sum = 0.0
                for i in 0..<n {
                    let s = samples[i]
                    peak = max(peak, abs(s))
                    sum += Double(s * s)
                }
                peaks[c] = peak
                squares[c] += sum
            }
            frames += n
            // The main mix's level over time: the louder of channels 1 and 2 (USB Main L/R), every 20 ms.
            let left = data[0], right = count > 1 ? data[1] : data[0]
            for i in 0..<n {
                stepSquares += Double(max(left[i] * left[i], right[i] * right[i]))
                stepCount += 1
                if stepCount == stepFrames {
                    steps.append(Float((stepSquares / Double(stepCount)).squareRoot()))
                    stepSquares = 0
                    stepCount = 0
                }
            }
        }

        func take() -> (peaks: [Float], rms: [Float], history: [Float]) {
            lock.lock(); defer { lock.unlock() }
            let rms = squares.map { frames > 0 ? Float(($0 / Double(frames)).squareRoot()) : 0 }
            let result = (peaks, rms, steps)
            peaks = Array(repeating: 0, count: peaks.count)
            squares = Array(repeating: 0, count: squares.count)
            frames = 0
            steps = []
            return result
        }
    }
}
