//
//  VideoElementView.swift
//  MxNoteONE
//
//  Insert ▸ Video: a movie (.mov, .mp4, .m4v) copied into the notebook and
//  played in place. The container shows a poster frame until it plays, keeps
//  the video's proportions, and has its own control bar: play / pause, stop,
//  back and forward 10 seconds, the time, a position slider, mute and volume.
//

import AppKit
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Picture area

/// The poster frame, and the playing video over it.
final class VideoScreenView: NSView {
    weak var owner: VideoElementView?
    var poster: NSImage? { didSet { needsDisplay = true } }
    private(set) var playerLayer: AVPlayerLayer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func show(_ player: AVPlayer?) {
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        guard let player, let layer else { return }
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspect
        playerLayer.frame = bounds
        layer.addSublayer(playerLayer)
        self.playerLayer = playerLayer
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer?.frame = bounds
        CATransaction.commit()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        if let poster {
            poster.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                        hints: [.interpolation: NSImageInterpolation.high.rawValue])
        } else {
            let config = NSImage.SymbolConfiguration(pointSize: 34, weight: .light).applying(.init(paletteColors: [NSColor(white: 0.55, alpha: 1)]))
            if let film = NSImage(systemSymbolName: "film", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                film.draw(in: NSRect(x: bounds.midX - film.size.width / 2, y: bounds.midY - film.size.height / 2,
                                     width: film.size.width, height: film.size.height),
                          from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { owner?.togglePlay() } else { owner?.beginMove(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        owner?.contextMenu()
    }
}

// MARK: - Control bar

/// Play / pause, stop, −10 s, +10 s, the time, the position, mute and volume.
final class VideoControlBar: NSView {
    weak var owner: VideoElementView?

    let playButton = VideoControlBar.button("play.fill", "Play (double-click the video)")
    let stopButton = VideoControlBar.button("stop.fill", "Stop")
    let backButton = VideoControlBar.button("gobackward.10", "Back 10 Seconds")
    let forwardButton = VideoControlBar.button("goforward.10", "Forward 10 Seconds")
    let muteButton = VideoControlBar.button("speaker.wave.2.fill", "Mute")
    let timeLabel = NSTextField(labelWithString: "0:00 / --:--")
    let position = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    let volume = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)

    private static func button(_ symbol: String, _ tip: String) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(), target: nil, action: nil)
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.contentTintColor = .white
        b.toolTip = tip
        b.setAccessibilityLabel(tip)
        return b
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for (button, action) in [(playButton, #selector(play)), (stopButton, #selector(stop)), (backButton, #selector(back)),
                                 (forwardButton, #selector(forward)), (muteButton, #selector(mute))] {
            button.target = self
            button.action = action
            addSubview(button)
        }
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = NSColor(white: 0.92, alpha: 1)
        timeLabel.toolTip = "Time played / length"
        addSubview(timeLabel)
        for (slider, action, tip) in [(position, #selector(seek), "Position: drag to go to a moment in the video"),
                                      (volume, #selector(changeVolume), "Volume")] {
            slider.controlSize = .mini
            slider.isContinuous = true
            slider.target = self
            slider.action = action
            slider.toolTip = tip
            slider.setAccessibilityLabel(tip)
            addSubview(slider)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let h = bounds.height, size: CGFloat = 26
        var x: CGFloat = 4
        for button in [playButton, stopButton, backButton, forwardButton] {
            button.frame = NSRect(x: x, y: (h - size) / 2, width: size, height: size)
            x += size
        }
        x += 4
        timeLabel.sizeToFit()
        timeLabel.frame = NSRect(x: x, y: (h - timeLabel.frame.height) / 2, width: timeLabel.frame.width, height: timeLabel.frame.height)
        x = timeLabel.frame.maxX + 8
        let volumeWidth: CGFloat = 56
        volume.frame = NSRect(x: bounds.width - volumeWidth - 6, y: (h - 16) / 2, width: volumeWidth, height: 16)
        muteButton.frame = NSRect(x: volume.frame.minX - size - 2, y: (h - size) / 2, width: size, height: size)
        let room = muteButton.frame.minX - 8 - x
        position.isHidden = room < 30
        position.frame = NSRect(x: x, y: (h - 16) / 2, width: max(0, room), height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.14, alpha: 1).setFill()
        bounds.fill()
    }

    /// Shows the player's state: play or pause, the time, the position, mute.
    func refresh(playing: Bool, time: Double, duration: Double?, muted: Bool, volume level: Float) {
        playButton.image = NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill", accessibilityDescription: playing ? "Pause" : "Play")
        playButton.toolTip = playing ? "Pause (double-click the video)" : "Play (double-click the video)"
        playButton.setAccessibilityLabel(playing ? "Pause" : "Play")
        muteButton.image = NSImage(systemSymbolName: muted ? "speaker.slash.fill" : level < 0.34 ? "speaker.wave.1.fill" : "speaker.wave.2.fill",
                                   accessibilityDescription: muted ? "Unmute" : "Mute")
        muteButton.toolTip = muted ? "Unmute" : "Mute"
        muteButton.setAccessibilityLabel(muted ? "Unmute" : "Mute")
        let text = Self.clock(time) + " / " + (duration.map(Self.clock) ?? "--:--")
        if timeLabel.stringValue != text {
            let oldWidth = timeLabel.frame.width
            timeLabel.stringValue = text
            if timeLabel.fittingSize.width != oldWidth { needsLayout = true }
        }
        if let duration, duration > 0, !(position.cell?.isHighlighted ?? false) {
            position.maxValue = duration
            position.doubleValue = time
        }
        volume.floatValue = level
    }

    /// 75 → "1:15"; an hour or more → "1:02:03".
    nonisolated static func clock(_ seconds: Double) -> String {
        let s = Int(max(0, seconds.isFinite ? seconds : 0).rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    @objc private func play() { owner?.togglePlay() }
    @objc private func stop() { owner?.stop() }
    @objc private func back() { owner?.skip(by: -10) }
    @objc private func forward() { owner?.skip(by: 10) }
    @objc private func mute() { owner?.toggleMute() }
    @objc private func seek() { owner?.seek(to: position.doubleValue) }
    @objc private func changeVolume() { owner?.setVolume(volume.floatValue) }

    override func mouseDown(with event: NSEvent) {
        owner?.beginMove(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        owner?.contextMenu()
    }

    /// Quick Help for the control under the pointer.
    func quickHelp(at p: NSPoint) -> QuickHelpItem? {
        let playing = owner?.isPlaying == true, muted = owner?.isMuted == true
        let items: [(NSView, String, String, String)] = [
            (playButton, playing ? "Pause" : "Play", playing ? "Pauses the video where it is; Play goes on from there." : "Plays the video here on the page. Double-clicking the video plays and pauses it too.", playing ? "pause.fill" : "play.fill"),
            (stopButton, "Stop", "Stops the video and goes back to the start.", "stop.fill"),
            (backButton, "Back 10 Seconds", "Goes back 10 seconds in the video.", "gobackward.10"),
            (forwardButton, "Forward 10 Seconds", "Goes forward 10 seconds in the video.", "goforward.10"),
            (timeLabel, "Time", "The time played and the video's length.", "clock"),
            (position, "Position", "Where the video is. Drag to go to another moment.", "slider.horizontal.below.rectangle"),
            (muteButton, muted ? "Unmute" : "Mute", muted ? "Turns the sound back on." : "Turns the video's sound off (the volume is kept).", muted ? "speaker.slash.fill" : "speaker.wave.2.fill"),
            (volume, "Volume", "The video's volume. Dragging it turns Mute off.", "speaker.wave.3.fill"),
        ]
        for (view, title, detail, symbol) in items where !view.isHidden && view.frame.insetBy(dx: -2, dy: -2).contains(p) {
            return QuickHelpItem(title: title, detail: detail, shortcut: nil, symbol: symbol)
        }
        return QuickHelpItem(title: "Video Controls", detail: "Play or pause, stop, go back or forward 10 seconds, see the time, drag the position, mute or set the volume. Drag the bar to move the video.",
                             shortcut: nil, symbol: "film")
    }
}

// MARK: - Container

final class VideoElementView: ElementView {
    static let barHeight: CGFloat = 30
    /// Movies the app takes in (.mov, .mp4, .m4v and others AVFoundation plays).
    static func isVideo(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true
    }

    let screen = VideoScreenView()
    let bar = VideoControlBar()
    /// Picture height ÷ width.
    private var aspect: CGFloat
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    /// A decrypted copy played from (a video in a password-protected section); removed when the player goes.
    private var temporaryURL: URL?
    private var duration: Double?
    private(set) var isMuted = false
    private var level: Float = 1

    var isPlaying: Bool { (player?.rate ?? 0) != 0 }

    init(element: PageElement, poster: NSImage?) {
        let pictureHeight = element.height - ElementView.gripHeight - Self.barHeight
        if element.width > 0, pictureHeight > 0 {
            aspect = pictureHeight / element.width
        } else if let poster, poster.size.width > 0 {
            aspect = poster.size.height / poster.size.width
        } else {
            aspect = 9.0 / 16.0
        }
        super.init(element: element)
        screen.owner = self
        screen.poster = poster
        bar.owner = self
        addSubview(screen)
        addSubview(bar)
        finishSetup()
        setWidth(frame.width)
        refreshBar()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    static let minimumWidth: CGFloat = 300
    override var minWidth: CGFloat { Self.minimumWidth }

    override func setWidth(_ width: CGFloat) {
        let w = max(minWidth, width)
        setFrameSize(NSSize(width: w, height: Self.gripHeight + (w * aspect).rounded() + Self.barHeight))
    }

    override func layoutContent() {
        let content = contentFrame
        screen.frame = NSRect(x: content.minX, y: content.minY, width: content.width, height: max(0, content.height - Self.barHeight))
        bar.frame = NSRect(x: content.minX, y: screen.frame.maxY, width: content.width, height: Self.barHeight)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            tearDown()
        } else if duration == nil, let ref = controller?.ref, let asset = element.asset,
                  let url = NotebookStore.shared.plainAssetURL(asset, for: ref) {
            // The length, for the bar (a protected section's video shows it once it plays).
            Task { [weak self] in
                guard let seconds = try? await AVURLAsset(url: url).load(.duration).seconds, seconds.isFinite else { return }
                self?.duration = seconds
                self?.refreshBar()
            }
        }
    }

    // MARK: Playing

    /// The player, made the first time it's needed (from the notebook's file, or a decrypted copy of it).
    private func makePlayer() -> AVPlayer? {
        if let player { return player }
        guard let ref = controller?.ref, let asset = element.asset else { return nil }
        let store = NotebookStore.shared
        var url = store.plainAssetURL(asset, for: ref)
        if url == nil {
            url = store.temporaryCopy(of: asset, fileName: element.fileName, for: ref)
            temporaryURL = url
        }
        guard let url else {
            store.showAlert("Can't play the video", "The video is missing from the notebook.")
            return nil
        }
        let player = AVPlayer(url: url)
        player.volume = level
        player.isMuted = isMuted
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshBar() }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: player.currentItem,
                                                             queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshBar() }
        }
        if duration == nil {
            Task { [weak self] in
                guard let seconds = try? await player.currentItem?.asset.load(.duration).seconds, seconds.isFinite else { return }
                self?.duration = seconds
                self?.refreshBar()
            }
        }
        self.player = player
        screen.show(player)
        return player
    }

    private func tearDown() {
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        player = nil
        screen.show(nil)
        if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL.deletingLastPathComponent()) }
        temporaryURL = nil
        refreshBar()
    }

    private var currentTime: Double {
        let t = player?.currentTime().seconds ?? 0
        return t.isFinite ? t : 0
    }

    func togglePlay() {
        guard let player = makePlayer() else { return NSSound.beep() }
        if isPlaying {
            player.pause()
        } else {
            // At the end, play from the start again.
            if let duration, currentTime >= duration - 0.05 { player.seek(to: .zero) }
            player.play()
        }
        refreshBar()
    }

    func stop() {
        guard let player else { return }
        player.pause()
        player.seek(to: .zero) { [weak self] _ in
            DispatchQueue.main.async { self?.refreshBar() }
        }
        refreshBar()
    }

    func skip(by seconds: Double) {
        guard let player = makePlayer() else { return NSSound.beep() }
        seek(on: player, to: currentTime + seconds)
    }

    func seek(to seconds: Double) {
        guard let player = makePlayer() else { return }
        seek(on: player, to: seconds)
    }

    private func seek(on player: AVPlayer, to seconds: Double) {
        let target = min(max(0, seconds), duration ?? .greatestFiniteMagnitude)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async { self?.refreshBar() }
        }
    }

    func toggleMute() {
        isMuted.toggle()
        player?.isMuted = isMuted
        refreshBar()
    }

    func setVolume(_ value: Float) {
        level = value
        isMuted = false
        player?.volume = value
        player?.isMuted = false
        refreshBar()
    }

    private func refreshBar() {
        bar.refresh(playing: isPlaying, time: currentTime, duration: duration, muted: isMuted, volume: level)
    }

    // MARK: Menu

    /// Takes the frame showing now as the poster (shown until the video plays, and in printouts and exports).
    private func useCurrentFrameAsPoster() {
        guard let player, let item = player.currentItem, let ref = controller?.ref else { return NSSound.beep() }
        let generator = AVAssetImageGenerator(asset: item.asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let time = player.currentTime()
        Task { [weak self] in
            guard let cgImage = try? await generator.image(at: time).image else { return NSSound.beep() }
            let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            guard let self, let jpeg = VideoElementView.jpeg(cgImage),
                  let name = NotebookStore.shared.writeAsset(jpeg, ext: "jpg", for: ref) else { return }
            self.element.preview = name
            self.screen.poster = image
            self.controller?.markDirty()
        }
    }

    static func jpeg(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    override func contextMenu() -> NSMenu {
        let menu = super.contextMenu()
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(isPlaying ? "Pause" : "Play") { [weak self] in self?.togglePlay() })
        let stop = ClosureMenuItem("Stop") { [weak self] in self?.stop() }
        stop.isEnabled = player != nil
        menu.addItem(stop)
        let poster = ClosureMenuItem("Use This Frame as Poster") { [weak self] in self?.useCurrentFrameAsPoster() }
        poster.isEnabled = player != nil
        menu.addItem(poster)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Open in Viewer") { [weak self] in
            guard let self, let ref = self.controller?.ref, let asset = self.element.asset else { return }
            self.player?.pause()
            self.refreshBar()
            NotebookStore.shared.openAsset(asset, fileName: self.element.fileName, for: ref)
        })
        menu.addItem(ClosureMenuItem("Save Video As…") { [weak self] in
            guard let self, let ref = self.controller?.ref, let asset = self.element.asset else { return }
            NotebookStore.shared.saveAssetAs(asset, fileName: self.element.fileName, for: ref)
        })
        return menu
    }
}
