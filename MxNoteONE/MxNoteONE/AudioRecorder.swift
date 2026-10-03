//
//  AudioRecorder.swift
//  MxNoteONE
//
//  Insert ▸ Record Audio: records from the microphone and puts the
//  recording on the current page when you stop.
//

import AVFoundation
import AppKit

final class AudioRecorder {
    static let shared = AudioRecorder()

    private var recorder: AVAudioRecorder?
    private var url: URL?
    private var timer: Task<Void, Never>?
    private var store: NotebookStore { .shared }

    var isRecording: Bool { recorder?.isRecording == true }

    func toggle() {
        if isRecording { stop() } else { start() }
    }

    func start() {
        guard store.currentPageRef != nil else { return NSSound.beep() }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            begin()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    if granted { AudioRecorder.shared.begin() } else { AudioRecorder.shared.denied() }
                }
            }
        default:
            denied()
        }
    }

    private func denied() {
        store.showAlert("Microphone access is off",
                        "Allow MxNoteONE to use the microphone in System Settings ▸ Privacy & Security ▸ Microphone.")
    }

    private func begin() {
        let url = FileManager.default.temporaryDirectory.appending(path: "MxNoteONE-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            guard recorder.record() else { throw CocoaError(.fileWriteUnknown) }
            self.recorder = recorder
            self.url = url
            store.editor.isRecording = true
            store.editor.recordingSeconds = 0
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, self.isRecording else { break }
                    self.store.editor.recordingSeconds = Int(self.recorder?.currentTime ?? 0)
                }
            }
        } catch {
            store.report("Couldn't start recording.", error)
        }
    }

    func stop() {
        guard let recorder, let url else { return }
        recorder.stop()
        timer?.cancel()
        self.recorder = nil
        self.url = nil
        store.editor.isRecording = false
        let name = "Audio Recording " + Date().formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute()) + ".m4a"
        if let data = try? Data(contentsOf: url) {
            store.canvas?.insertAttachment(data: data, fileName: name.replacingOccurrences(of: ":", with: "."), kind: .audio)
        }
        try? FileManager.default.removeItem(at: url)
    }
}
