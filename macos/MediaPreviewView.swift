import AppKit
import AVKit
import SwiftUI

/// Space controls visible media from anywhere in the file window. Clicking the
/// inspector gives arrows a preview context, including on sliders and buttons.
struct MediaPreviewKeyboardScope: NSViewRepresentable {
    var playback: MediaPlaybackController?
    var isMediaPreview = false
    var onMove: (Int) -> Void
    func makeNSView(context: Context) -> MediaPreviewKeyView { MediaPreviewKeyView() }
    func updateNSView(_ view: MediaPreviewKeyView, context: Context) {
        view.playback = playback; view.isMediaPreview = isMediaPreview; view.onMove = onMove
    }
    static func dismantleNSView(_ view: MediaPreviewKeyView, coordinator: ()) { view.stop() }
}

final class MediaPreviewKeyView: NSView {
    private static let scopes = NSHashTable<MediaPreviewKeyView>.weakObjects()
    weak var playback: MediaPlaybackController?
    var isMediaPreview = false
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
            $0.window === window && !$0.isHiddenOrHasHiddenAncestor
                && (event.keyCode == 49 ? $0.isMediaPreview : $0.hasPreviewFocus)
        }) else { return false }
        switch event.keyCode {
        case 49:
            // Reserve Space for visible media while its player is preparing, too.
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
    private var reportedDisplay: Bool?

    func attach(_ next: AVPlayer) {
        guard player !== next else { return }
        clear()
        controlsStyle = .none; videoGravity = .resizeAspect
        showsFullScreenToggleButton = false
        player = next
        let request = generation
        let refreshQueue = MediaPlaybackRefreshQueue()
        let changed: () -> Void = { [weak self, weak next] in
            refreshQueue.schedule { [weak self, weak next] in
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
        if reportedDisplay != isReadyForDisplay {
            reportedDisplay = isReadyForDisplay
            onDisplayChanged?(player, isReadyForDisplay)
        }
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
            // Player-item tracks belong to the player's notification queue
            // (main). Inspect asset-track properties through the bounded
            // worker: their synchronous getters may wait for metadata I/O.
            let tracks = item.tracks.compactMap { $0.isEnabled ? $0.assetTrack : nil }
            let hasVideo: Bool
            do { hasVideo = try await MediaVideoTracks.hasVideo(tracks) }
            catch {
                guard !Task.isCancelled, self.generation == request, self.player === player,
                      self.window != nil, item.status == .readyToPlay, !self.isReadyForDisplay else { return }
                self.reportedFailure = true; self.onFailure?(error, player)
                return
            }
            guard !Task.isCancelled, self.generation == request, self.player === player,
                  self.window != nil, item.status == .readyToPlay, !self.isReadyForDisplay else { return }
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
        observations.removeAll(); reportedFailure = false; reportedDisplay = nil; player = nil
    }
    deinit { frameTask?.cancel() }
}

enum MediaVideoTracks {
    static func hasVideo(_ tracks: [AVAssetTrack]) async throws -> Bool {
        try Task.checkCancellation()
        for track in tracks {
            try Task.checkCancellation()
            // This SDK has no AVAsyncProperty key for mediaType. Keep its
            // synchronous accessor off AppKit and the cooperative executor.
            let type = try await NativeFileWork.run { track.mediaType }
            try Task.checkCancellation()
            if type == .video { return true }
        }
        return false
    }
}

struct MediaPreviewView: View {
    @ObservedObject var playback: MediaPlaybackController
    let isAudio: Bool
    var transfer = MediaPreviewTransferState()
    var placeholder: AnyView? = nil
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
                        let next = ready ? source : nil
                        if displayedPlayer !== next { displayedPlayer = next }
                    }, onFailure: { error, source in
                        guard source === playback.player else { return }
                        failedPlayer = source; onVideoFailure?(error, source)
                    }).id(ObjectIdentifier(player))
                }
                if preparingVideo || displayFailed || playback.phase == .failed {
                    if let placeholder { placeholder.allowsHitTesting(false) }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
            MediaTransportBar(playback: playback, settings: playback.settings, transfer: transfer,
                preparingVideo: preparingVideo)
        }.background(Color(nsColor: .controlBackgroundColor))
            .onChange(of: playback.player) { _ in displayedPlayer = nil; failedPlayer = nil }
    }
}

struct MediaTransportBar: View {
    @ObservedObject var playback: MediaPlaybackController
    @ObservedObject var settings: MediaPlaybackSettings
    var transfer = MediaPreviewTransferState()
    var preparingVideo = false
    @State private var isScrubbing = false
    @State private var scrubPosition = 0.0
    private var position: Double { isScrubbing ? scrubPosition : playback.position }
    private var muted: Bool { settings.values.muted || settings.values.volume == 0 }
    private var canPlay: Bool { !transfer.preparing && playback.canPlay }
    private var canSeek: Bool { !transfer.preparing && playback.canSeek }

    var body: some View {
        // Keep the same controls mounted as the pane crosses between two and
        // three rows, preserving native slider focus and an active scrub.
        MediaTransportLayout {
            Text(transfer.waitingForMemory ? "Waiting for memory" : transfer.preparing || preparingVideo ? "Preparing…" : MediaPlaybackController.time(position))
                .lineLimit(1)
            Text(!transfer.preparing && playback.duration > 0 ? MediaPlaybackController.time(playback.duration) : "—:—")
                .lineLimit(1)
            HStack(spacing: 0) {
                if !transfer.complete {
                    Label(transfer.speedText, systemImage: "arrow.down")
                        .lineLimit(1).fixedSize()
                        .help("Average download speed over the last five seconds")
                        .accessibilityLabel("Download speed: \(transfer.speedText), five-second average")
                }
            }
            MediaSeekSlider(position: transfer.preparing ? 0 : playback.position, duration: transfer.preparing ? 0 : playback.duration, enabled: canSeek,
                source: playback.player, bufferedRanges: transfer.ranges ?? playback.bufferedRanges, showsThumb: canSeek,
                onScrub: { value in scrubPosition = value; isScrubbing = true },
                onCommit: { value, source in
                    isScrubbing = false
                    guard playback.player === source else { return }
                    playback.seek(to: value)
                })
                .frame(height: 18)
                .help("Drag to seek. Solid color is played; lighter color shows buffered parts of the file. Gaps are not buffered.")
            transportButtons
            GeometryReader { viewport in
                volumeControls(compact: viewport.size.width < 180).frame(height: 26)
            }.frame(height: 26)
            speedMenu.disabled(transfer.preparing)
        }.font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(alignment: .top) { Divider() }
            .onChange(of: playback.player) { _ in isScrubbing = false; scrubPosition = 0 }
    }
    private var transportButtons: some View {
        HStack(spacing: 7) {
            control("Back 5 seconds", symbol: "gobackward.5", enabled: canSeek) { playback.skip(-5) }
            control(playback.wantsPlayback ? "Pause" : playback.phase == .finished ? "Replay" : "Play",
                    symbol: playback.wantsPlayback ? "pause.fill" : "play.fill", enabled: canPlay, prominent: true) { playback.togglePlayback() }
            control("Forward 5 seconds", symbol: "goforward.5", enabled: canSeek) { playback.skip(5) }
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
    private func volumeControls(compact: Bool) -> some View {
        HStack(spacing: compact ? 4 : 6) {
            control(muted ? "Unmute" : "Mute", symbol: muted ? "speaker.slash.fill" : "speaker.wave.2.fill") { settings.toggleMute() }
            MediaSeekSlider(position: settings.values.volume, duration: 1, enabled: true, source: nil,
                label: "Preview volume", onScrub: { settings.setVolume($0) }, onCommit: { value, _ in settings.setVolume(value) })
                .frame(width: compact ? 56 : 110, height: 18)
                .help("Preview volume · remembered for every video")
            if !compact {
                Text(muted ? "Muted" : "\(Int((settings.values.volume * 100).rounded()))%")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
            }
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

/// Wide previews put the clocks beside the timeline and download speed beside
/// the controls. Narrow previews give the clocks/download speed their own row.
/// Width, rather than the saved pane placement, also handles expanded previews.
private struct MediaTransportLayout: Layout {
    private let wideMinimumWidth: CGFloat = 520

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? wideMinimumWidth
        return .init(width: width, height: width >= wideMinimumWidth ? 50 : 68)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // Stable slots: elapsed, duration, download, timeline, transport, volume, rate.
        guard subviews.count == 7 else { return }
        let width = bounds.width, wide = width >= wideMinimumWidth, compact = width < 360
        let duration = subviews[1].sizeThatFits(.unspecified).width
        // Reserve the duration's clock width so minute/hour changes never
        // move the seek track underneath an active drag.
        let elapsed = max(duration, subviews[0].sizeThatFits(.unspecified).width)
        let download = subviews[2].sizeThatFits(.unspecified).width
        let transport = subviews[4].sizeThatFits(.unspecified).width
        let volume: CGFloat = compact ? 84 : 180
        let rate = subviews[6].sizeThatFits(.unspecified).width
        let gap: CGFloat = compact ? 6 : 10
        let volumeX = transport + gap, rateX = max(0, width - rate)
        let controlsY: CGFloat = wide ? 24 : 42
        func place(_ index: Int, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
            subviews[index].place(at: .init(x: bounds.minX + x + width / 2, y: bounds.minY + y + height / 2),
                anchor: .center, proposal: .init(width: max(0, width), height: height))
        }
        place(4, x: 0, y: controlsY, width: transport, height: 26)
        place(5, x: volumeX, y: controlsY, width: volume, height: 26)
        place(6, x: rateX, y: controlsY, width: rate, height: 26)
        if wide {
            place(0, x: 0, y: 0, width: elapsed, height: 18)
            place(3, x: elapsed + 6, y: 0, width: width - elapsed - duration - 12, height: 18)
            place(1, x: width - duration, y: 0, width: duration, height: 18)
            let availableStart = volumeX + volume + gap
            let availableEnd = rateX - gap
            place(2, x: (availableStart + availableEnd - download) / 2, y: controlsY, width: download, height: 26)
        } else {
            place(0, x: 0, y: 0, width: elapsed, height: 14)
            place(1, x: width - duration, y: 0, width: duration, height: 14)
            let availableStart = elapsed + 6, availableEnd = width - duration - 6
            let downloadX = min(max((width - download) / 2, availableStart), availableEnd - download)
            place(2, x: downloadX, y: 0, width: download, height: 14)
            place(3, x: 0, y: 18, width: width, height: 18)
        }
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
    var showsThumb = true
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
        slider.showsThumb = showsThumb
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
    var showsThumb = true { didSet { if oldValue != showsThumb { needsDisplay = true } } }
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
            NSColor.controlAccentColor.withAlphaComponent(0.30).setFill()
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
        if showsThumb {
            let knob = NSBezierPath(ovalIn: .init(x: x - 6, y: center - 6, width: 12, height: 12))
            NSColor.controlBackgroundColor.setFill(); knob.fill()
            NSColor.separatorColor.withAlphaComponent(0.5).setStroke(); knob.lineWidth = 0.7; knob.stroke()
            if window?.firstResponder === self {
                NSColor.keyboardFocusIndicatorColor.setStroke()
                let ring = NSBezierPath(ovalIn: .init(x: x - 8, y: center - 8, width: 16, height: 16))
                ring.lineWidth = 1; ring.stroke()
            }
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
