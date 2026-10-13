import AppKit
import AVKit
import SwiftUI

/// Clicking anywhere in the inspector establishes one keyboard context, even
/// when a native slider or a SwiftUI button subsequently becomes first responder.
struct MediaPreviewKeyboardScope: NSViewRepresentable {
    var playback: MediaPlaybackController?
    var onMove: (Int) -> Void
    func makeNSView(context: Context) -> MediaPreviewKeyView { MediaPreviewKeyView() }
    func updateNSView(_ view: MediaPreviewKeyView, context: Context) {
        view.playback = playback; view.onMove = onMove
    }
    static func dismantleNSView(_ view: MediaPreviewKeyView, coordinator: ()) { view.stop() }
}

final class MediaPreviewKeyView: NSView {
    private static let scopes = NSHashTable<MediaPreviewKeyView>.weakObjects()
    weak var playback: MediaPlaybackController?
    var onMove: ((Int) -> Void)?
    private(set) var hasPreviewFocus = false
    private var monitor: Any?
    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); stop()
        guard window != nil else { return }
        Self.scopes.add(self)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if Self.handle(event) { return nil }
                if event.keyCode == 48 { self.hasPreviewFocus = false }
            } else { self.focus(for: event) }
            return event
        }
    }
    /// Used by the browser's monitors as well, so monitor registration order
    /// cannot let tree navigation consume a media shortcut first.
    static func handle(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              let window = event.window ?? NSApp.keyWindow, NSApp.keyWindow === window,
              !window.isSheet, window.attachedSheet == nil else { return false }
        if let text = window.firstResponder as? NSTextView, text.isEditable { return false }
        if window.firstResponder is NSTextField { return false }
        guard let scope = scopes.allObjects.first(where: {
            $0.window === window && $0.hasPreviewFocus && !$0.isHiddenOrHasHiddenAncestor
        }) else { return false }
        switch event.keyCode {
        case 49:
            // Keep Space in the preview while its player is preparing, too.
            // A held key must not alternate between pause and resume.
            if !event.isARepeat { scope.playback?.togglePlayback() }
        case 123, 124:
            guard let playback = scope.playback else { return false }
            playback.skip(event.keyCode == 123 ? -5 : 5)
        case 125, 126: scope.onMove?(event.keyCode == 125 ? 1 : -1)
        default: return false
        }
        return true
    }
    func focus(for event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hasPreviewFocus = event.window === window && !isHiddenOrHasHiddenAncestor
            && bounds.contains(point) && visibleRect.contains(point)
        if hasPreviewFocus { window?.makeFirstResponder(self) }
    }
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        Self.scopes.remove(self); hasPreviewFocus = false
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}

/// AVKit renders the video; all transport controls and preferences are ours.
private struct MediaVideoSurface: NSViewRepresentable {
    let player: AVPlayer
    let onDisplayChanged: (AVPlayer, Bool) -> Void
    let onFailure: (Error, AVPlayer) -> Void
    func makeNSView(context: Context) -> MediaVideoPlayerView { MediaVideoPlayerView() }
    func updateNSView(_ view: MediaVideoPlayerView, context: Context) {
        view.onDisplayChanged = onDisplayChanged; view.onFailure = onFailure
        view.attach(player)
    }
    static func dismantleNSView(_ view: MediaVideoPlayerView, coordinator: ()) { view.clear() }
}

/// An item can be ready to play its audio while its video track is unusable.
/// Observe the actual rendered frame, and do not leave AVKit's QuickTime
/// placeholder on screen indefinitely after the item has reported success.
final class MediaVideoPlayerView: AVPlayerView {
    var onDisplayChanged: ((AVPlayer, Bool) -> Void)?
    var onFailure: ((Error, AVPlayer) -> Void)?
    private var observations: [NSKeyValueObservation] = []
    private var frameTask: Task<Void, Never>?
    private var generation = UUID()
    private var reportedFailure = false

    func attach(_ next: AVPlayer) {
        guard player !== next else { return }
        clear()
        controlsStyle = .none; videoGravity = .resizeAspect
        showsFullScreenToggleButton = false
        player = next
        let request = generation
        let changed: () -> Void = { [weak self, weak next] in
            Task { @MainActor in
                guard let self, let next, self.generation == request, self.player === next else { return }
                self.refreshDisplay()
            }
        }
        observations = [observe(\.isReadyForDisplay, options: [.initial, .new]) { _, _ in changed() }]
        if let item = next.currentItem {
            observations.append(item.observe(\.status, options: [.initial, .new]) { _, _ in changed() })
        }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { frameTask?.cancel(); frameTask = nil }
        else { Task { @MainActor [weak self] in self?.refreshDisplay() } }
    }
    private func refreshDisplay() {
        guard let player, let item = player.currentItem else { return }
        onDisplayChanged?(player, isReadyForDisplay)
        if item.status == .failed {
            frameTask?.cancel(); frameTask = nil
            if !reportedFailure {
                reportedFailure = true
                onFailure?(item.error ?? NSError(domain: AVFoundationErrorDomain,
                    code: AVError.Code.decodeFailed.rawValue), player)
            }
            return
        }
        if isReadyForDisplay {
            frameTask?.cancel(); frameTask = nil
            return
        }
        guard window != nil, item.status == .readyToPlay, frameTask == nil, !reportedFailure else { return }
        let request = generation
        frameTask = Task { [weak self, weak player] in
            // Let AVKit finish its initial presentation update before checking
            // tracks. A paused, newly attached view may also need a frame seek.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self, let player,
                  self.generation == request, self.player === player, !self.isReadyForDisplay else { return }
            let hasVideo = item.tracks.contains { $0.isEnabled && $0.assetTrack?.mediaType == .video }
            if hasVideo {
                if player.timeControlStatus == .paused, player.currentTime().seconds == 0 {
                    player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
                }
                try? await Task.sleep(nanoseconds: 12_000_000_000)
            }
            guard !Task.isCancelled, self.generation == request, self.player === player,
                  self.window != nil, item.status == .readyToPlay, !self.isReadyForDisplay else { return }
            self.reportedFailure = true
            let error = NSError(domain: AVFoundationErrorDomain,
                code: (hasVideo ? AVError.Code.decodeFailed : .noSourceTrack).rawValue,
                userInfo: [NSLocalizedDescriptionKey: hasVideo
                    ? "The video opened but could not display a frame."
                    : "This preview source has no playable video track."])
            self.onFailure?(error, player)
        }
    }
    func clear() {
        generation = UUID(); frameTask?.cancel(); frameTask = nil
        observations.removeAll(); reportedFailure = false; player = nil
    }
    deinit { frameTask?.cancel() }
}

struct MediaPreviewView: View {
    @ObservedObject var playback: MediaPlaybackController
    let isAudio: Bool
    var onVideoFailure: ((Error, AVPlayer) -> Void)? = nil
    @State private var displayedPlayer: AVPlayer?
    @State private var failedPlayer: AVPlayer?
    private var displayFailed: Bool { !isAudio && failedPlayer != nil && failedPlayer === playback.player }
    private var preparingVideo: Bool { !isAudio && playback.phase != .failed && !displayFailed && displayedPlayer !== playback.player }
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if isAudio {
                    LinearGradient(colors: [Color.blue.opacity(0.45), Color.indigo.opacity(0.18)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "waveform").font(.system(size: 46, weight: .light)).foregroundStyle(.white.opacity(0.8))
                } else if let player = playback.player {
                    MediaVideoSurface(player: player, onDisplayChanged: { source, ready in
                        guard source === playback.player else { return }
                        displayedPlayer = ready ? source : nil
                    }, onFailure: { error, source in
                        guard source === playback.player else { return }
                        failedPlayer = source; onVideoFailure?(error, source)
                    }).id(ObjectIdentifier(player))
                }
                if preparingVideo || displayFailed { Color.black.allowsHitTesting(false) }
                if playback.phase == .failed || displayFailed {
                    Label("Preview unavailable", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.white).padding()
                } else if preparingVideo || playback.phase == .loading || playback.phase == .buffering {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(preparingVideo || playback.phase == .loading ? "Loading preview…" : "Buffering…").font(.caption)
                    }.padding(10).background(.regularMaterial, in: Capsule())
                        .allowsHitTesting(false)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
            MediaTransportBar(playback: playback, settings: playback.settings, preparingVideo: preparingVideo)
        }.background(Color(nsColor: .controlBackgroundColor))
            .onChange(of: playback.player) { _ in displayedPlayer = nil; failedPlayer = nil }
    }
}

private struct MediaTransportBar: View {
    @ObservedObject var playback: MediaPlaybackController
    @ObservedObject var settings: MediaPlaybackSettings
    var preparingVideo = false
    @State private var isScrubbing = false
    @State private var scrubPosition = 0.0
    private var position: Double { isScrubbing ? scrubPosition : playback.position }
    private var muted: Bool { settings.values.muted || settings.values.volume == 0 }

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 5) {
                Text(MediaPlaybackController.time(position))
                Spacer(minLength: 2)
                Text(isScrubbing ? "Seeking" : preparingVideo ? "Loading" : playback.phase.rawValue).foregroundStyle(.secondary)
                Spacer(minLength: 2)
                Text(playback.duration > 0 ? MediaPlaybackController.time(playback.duration) : "—:—")
            }.font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
            MediaSeekSlider(position: playback.position, duration: playback.duration, enabled: playback.canSeek,
                source: playback.player, bufferedRanges: playback.bufferedRanges,
                onScrub: { value in scrubPosition = value; isScrubbing = true },
                onCommit: { value, source in
                    isScrubbing = false
                    guard playback.player === source else { return }
                    playback.seek(to: value)
                })
                .frame(height: 18)
                .help(playback.bufferHelp.map { "Drag to seek. The solid section is played; lighter sections are held in memory. \($0)" }
                    ?? "Drag to seek. The solid section is played; lighter sections are buffered.")

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    transportButtons
                    Spacer(minLength: 20)
                    volumeControls.frame(width: 164)
                    speedMenu
                }.frame(minWidth: 400)
                VStack(spacing: 7) {
                    HStack { transportButtons; Spacer(minLength: 0); speedMenu }
                    volumeControls
                }
            }
        }.padding(10)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(alignment: .top) { Divider() }
            .onChange(of: playback.player) { _ in isScrubbing = false; scrubPosition = 0 }
    }
    private var transportButtons: some View {
        HStack(spacing: 7) {
            control("Back 5 seconds", symbol: "gobackward.5", enabled: playback.canSeek) { playback.skip(-5) }
            control(playback.wantsPlayback ? "Pause" : playback.phase == .finished ? "Replay" : "Play",
                    symbol: playback.wantsPlayback ? "pause.fill" : "play.fill", enabled: playback.canPlay, prominent: true) { playback.togglePlayback() }
            control("Forward 5 seconds", symbol: "goforward.5", enabled: playback.canSeek) { playback.skip(5) }
        }.fixedSize()
    }
    private var speedMenu: some View {
        Menu {
            ForEach(MediaPlaybackSettings.speeds, id: \.self) { speed in
                Button { settings.setSpeed(speed) } label: {
                    if settings.values.speed == speed { Label(speedLabel(speed), systemImage: "checkmark") }
                    else { Text(speedLabel(speed)) }
                }
            }
        } label: { Text(speedLabel(settings.values.speed)).font(.caption.weight(.semibold)).monospacedDigit() }
            .menuStyle(.borderlessButton).fixedSize().buttonStyle(.automatic)
            .help("Playback speed · remembered for every video").accessibilityLabel("Playback speed")
    }
    private var volumeControls: some View {
        HStack(spacing: 8) {
            control(muted ? "Unmute" : "Mute", symbol: muted ? "speaker.slash.fill" : "speaker.wave.2.fill") { settings.toggleMute() }
            MediaSeekSlider(position: settings.values.volume, duration: 1, enabled: true, source: nil,
                label: "Preview volume", onScrub: { settings.setVolume($0) }, onCommit: { value, _ in settings.setVolume(value) })
                .frame(height: 18)
                .help("Preview volume · remembered for every video")
            Text(muted ? "Muted" : "\(Int((settings.values.volume * 100).rounded()))%")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
        }
    }
    private func speedLabel(_ value: Double) -> String { "\(value.formatted(.number.precision(.fractionLength(0...2))))×" }
    private func control(_ title: String, symbol: String, enabled: Bool = true, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: prominent ? 14 : 13, weight: .semibold))
                .frame(width: prominent ? 34 : 24, height: 26)
                .foregroundStyle(prominent ? .white : Color.accentColor)
                .background(prominent ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).pointingHandCursor().disabled(!enabled).opacity(enabled ? 1 : 0.4)
            .help(title).accessibilityLabel(title)
    }
}

/// Nonblocking pointer tracking keeps playback ticks out of an active drag.
/// Seek once on release; volume uses the same control and updates continuously.
private struct MediaSeekSlider: NSViewRepresentable {
    let position: Double
    let duration: Double
    let enabled: Bool
    let source: AVPlayer?
    var bufferedRanges: [ClosedRange<Double>] = []
    var label = "Playback position"
    let onScrub: (Double) -> Void
    let onCommit: (Double, AVPlayer?) -> Void
    func makeNSView(context: Context) -> MediaSliderControl { MediaSliderControl() }
    func updateNSView(_ slider: MediaSliderControl, context: Context) {
        slider.maximum = duration.isFinite && duration > 0 ? duration : 1
        slider.isEnabled = enabled
        slider.setAccessibilityLabel(label)
        slider.isVolume = label == "Preview volume"
        slider.bufferedRanges = bufferedRanges
        slider.onScrub = onScrub; slider.onCommit = onCommit; slider.source = source
        if !slider.tracking { slider.value = min(max(0, position), slider.maximum) }
        slider.needsDisplay = true
    }
}

/// Which keys belong to a focused slider, and which pages have files to walk through. Up and Down always move
/// to the previous or next file, so a slider that happens to have focus can never turn them into a seek.
enum PreviewKeyRouting {
    /// Left, Right, Home and End.
    static func sliderOwns(keyCode: UInt16) -> Bool { [123, 124, 115, 119].contains(keyCode) }

    /// The Browser, the Links tab and an open bookmark folder list files beside a preview.
    static func isFilePreviewTab(_ tab: Int, bookmarkBrowserIsOpen: Bool) -> Bool {
        tab == FinderWorkspaceSection.browser.rawValue || tab == FinderWorkspaceSection.links.rawValue
            || (tab == FinderWorkspaceSection.bookmarks.rawValue && bookmarkBrowserIsOpen)
    }
}

final class MediaSliderControl: NSControl {
    var tracking = false
    var source: AVPlayer?
    private var dragSource: AVPlayer?
    var value = 0.0 { didSet { needsDisplay = true } }
    var maximum = 1.0
    var isVolume = false
    var bufferedRanges: [ClosedRange<Double>] = [] { didSet { if oldValue != bufferedRanges { needsDisplay = true } } }
    var onScrub: ((Double) -> Void)?
    var onCommit: ((Double, AVPlayer?) -> Void)?
    override var acceptsFirstResponder: Bool { isEnabled }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var intrinsicContentSize: NSSize { .init(width: NSView.noIntrinsicMetric, height: 18) }
    override func resetCursorRects() { if isEnabled { addCursorRect(bounds, cursor: .pointingHand) } }
    private var trackRect: NSRect {
        .init(x: bounds.minX + min(7, bounds.width / 2), y: bounds.midY - 2, width: max(0, bounds.width - 14), height: 4)
    }
    override func draw(_ dirtyRect: NSRect) {
        let track = trackRect, center = bounds.midY
        let fraction = maximum.isFinite && maximum > 0 && value.isFinite ? min(1, max(0, value / maximum)) : 0
        let x = track.minX + track.width * fraction
        let rail = NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2)
        NSColor.separatorColor.withAlphaComponent(0.25).setFill()
        rail.fill()
        NSGraphicsContext.saveGraphicsState()
        rail.addClip()
        // Share the exact same rail, insets and time mapping as the playhead.
        // Buffered islands stay separate, and played content is drawn on top.
        if !isVolume {
            NSColor.controlAccentColor.withAlphaComponent(isEnabled ? 0.28 : 0.12).setFill()
            for range in bufferedRanges where range.lowerBound.isFinite && range.upperBound.isFinite {
                let start = min(1, max(0, range.lowerBound)), end = min(1, max(0, range.upperBound))
                guard end > start else { continue }
                NSBezierPath(rect: .init(x: track.minX + track.width * start, y: track.minY,
                    width: track.width * (end - start), height: track.height)).fill()
            }
        }
        NSColor.controlAccentColor.withAlphaComponent(isEnabled ? 1 : 0.3).setFill()
        NSBezierPath(rect: .init(x: track.minX, y: track.minY, width: max(0, x - track.minX), height: track.height)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let knob = NSBezierPath(ovalIn: .init(x: x - 6, y: center - 6, width: 12, height: 12))
        NSColor.controlBackgroundColor.setFill(); knob.fill()
        NSColor.separatorColor.withAlphaComponent(0.5).setStroke(); knob.lineWidth = 0.7; knob.stroke()
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let ring = NSBezierPath(ovalIn: .init(x: x - 8, y: center - 8, width: 16, height: 16))
            ring.lineWidth = 1; ring.stroke()
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self); dragSource = source; tracking = true
        scrub(event)
    }
    override func mouseDragged(with event: NSEvent) { if tracking { scrub(event) } }
    override func mouseUp(with event: NSEvent) {
        guard tracking else { return }
        scrub(event); tracking = false; onCommit?(value, dragSource); dragSource = nil
    }
    private func scrub(_ event: NSEvent) {
        let track = trackRect
        value = min(1, max(0, (convert(event.locationInWindow, from: nil).x - track.minX) / max(1, track.width))) * maximum
        onScrub?(value)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }
    override func keyDown(with event: NSEvent) {
        guard PreviewKeyRouting.sliderOwns(keyCode: event.keyCode) else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 123: adjust(-1)
        case 124: adjust(1)
        case 115: commit(0)
        default: commit(maximum)
        }
    }
    private func adjust(_ direction: Double) { commit(value + direction * (isVolume ? 0.05 : 5)) }
    private func commit(_ proposed: Double) {
        guard isEnabled, proposed.isFinite else { return }
        value = min(maximum, max(0, proposed)); onCommit?(value, source)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityValue() -> Any? { value }
    override func accessibilityMinValue() -> Any? { 0.0 }
    override func accessibilityMaxValue() -> Any? { maximum }
    override func accessibilityValueDescription() -> String? {
        isVolume ? "\(Int((value * 100).rounded())) percent" : "\(MediaPlaybackController.time(value)) of \(MediaPlaybackController.time(maximum))"
    }
    override func setAccessibilityValue(_ value: Any?) { if let value = value as? NSNumber { commit(value.doubleValue) } }
    override func accessibilityPerformIncrement() -> Bool { adjust(1); return isEnabled }
    override func accessibilityPerformDecrement() -> Bool { adjust(-1); return isEnabled }
}
