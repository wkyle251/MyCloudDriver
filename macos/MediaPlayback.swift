import AVFoundation
import Combine
import Foundation

/// Playback preferences belong to the app, not to an individual AVPlayer.
@MainActor final class MediaPlaybackSettings: ObservableObject {
    struct Values: Equatable {
        var volume: Double
        var muted: Bool
        var speed: Double
    }
    static let speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
    @Published private(set) var values: Values
    private let defaults: UserDefaults
    private var lastAudibleVolume: Double

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let volume = Self.volume((defaults.object(forKey: "mediaPreviewVolume") as? NSNumber)?.doubleValue ?? 1)
        let speed = (defaults.object(forKey: "mediaPreviewSpeed") as? NSNumber)?.doubleValue ?? 1
        values = .init(volume: volume, muted: defaults.bool(forKey: "mediaPreviewMuted"),
                       speed: Self.speeds.contains(speed) ? speed : 1)
        lastAudibleVolume = Self.volume((defaults.object(forKey: "mediaPreviewAudibleVolume") as? NSNumber)?.doubleValue ?? 1)
        if lastAudibleVolume == 0 { lastAudibleVolume = 1 }
    }
    private static func volume(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 1 }
    func setVolume(_ value: Double) {
        guard value.isFinite else { return }
        var next = values; next.volume = Self.volume(value)
        if next.volume > 0 { next.muted = false; lastAudibleVolume = next.volume }
        save(next)
    }
    func toggleMute() {
        var next = values
        if next.muted || next.volume == 0 {
            next.muted = false
            if next.volume == 0 { next.volume = lastAudibleVolume }
        } else { next.muted = true }
        save(next)
    }
    func setSpeed(_ value: Double) {
        guard Self.speeds.contains(value) else { return }
        var next = values; next.speed = value; save(next)
    }
    private func save(_ next: Values) {
        guard values != next else { return }
        values = next
        defaults.set(next.volume, forKey: "mediaPreviewVolume")
        defaults.set(next.muted, forKey: "mediaPreviewMuted")
        defaults.set(next.speed, forKey: "mediaPreviewSpeed")
        defaults.set(lastAudibleVolume, forKey: "mediaPreviewAudibleVolume")
    }
}

/// Time ranges reported by AVPlayer, normalized to the seek track. Keep gaps
/// after a seek: a later buffered segment does not make the interval before it
/// playable. These ranges describe the player's buffer, not bytes on disk.
enum MediaBuffering {
    static func normalizedRanges(_ ranges: [CMTimeRange], duration: Double) -> [ClosedRange<Double>] {
        guard duration.isFinite, duration > 0 else { return [] }
        let clipped = ranges.compactMap { range -> ClosedRange<Double>? in
            let start = range.start.seconds, end = CMTimeRangeGetEnd(range).seconds
            guard start.isFinite, end.isFinite, end > start else { return nil }
            let lower = min(1, max(0, start / duration)), upper = min(1, max(0, end / duration))
            return upper > lower ? lower...upper : nil
        }.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Double>] = []
        for range in clipped {
            if let previous = merged.last, range.lowerBound <= previous.upperBound {
                merged[merged.count - 1] = previous.lowerBound...max(previous.upperBound, range.upperBound)
            } else { merged.append(range) }
        }
        return merged
    }
}

/// KVO may arrive on several queues and in bursts. Keep one main-actor
/// refresh queued, rather than creating a task for every property callback.
final class MediaPlaybackRefreshQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false
    func schedule(_ refresh: @escaping @MainActor @Sendable () -> Void) {
        lock.lock()
        guard !pending else { lock.unlock(); return }
        pending = true; lock.unlock()
        Task { @MainActor in
            self.consume()
            refresh()
        }
    }
    private func consume() { lock.lock(); pending = false; lock.unlock() }
}

/// Observe only the player surface, avoiding a browser/tree redraw for each tick.
/// The source owner still owns cloud transport, retry and buffer recovery.
@MainActor final class MediaPlaybackController: ObservableObject {
    enum Phase: String { case loading = "Loading", ready = "Ready", playing = "Playing", paused = "Paused", buffering = "Buffering", finished = "Finished", failed = "Unavailable" }
    let settings: MediaPlaybackSettings
    @Published private(set) var player: AVPlayer?
    @Published private(set) var position = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var phase = Phase.loading
    @Published private(set) var wantsPlayback = false
    @Published private(set) var bufferedRanges: [ClosedRange<Double>] = []
    /// What a RAM buffer holds, for a file read from an external disk. While set, the seek bar's lighter
    /// shading shows these ranges instead of AVPlayer's, which only says what the player has asked for.
    @Published private(set) var memoryBuffer: PreviewResourceCacheSnapshot?
    private var observations: [NSKeyValueObservation] = []
    private var timeObserver: Any?
    private var timeObserverPlayer: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var preferencesObserver: AnyCancellable?
    private var seekID = UUID()
    private var pendingSeek: Double?
    var canPlay: Bool { player?.currentItem?.status == .readyToPlay }
    var canSeek: Bool { canPlay && duration > 0 }

    init(settings: MediaPlaybackSettings) {
        self.settings = settings
        preferencesObserver = settings.$values.receive(on: DispatchQueue.main).sink { [weak self] values in
            self?.apply(values)
        }
    }
    deinit {
        observations.forEach { $0.invalidate() }
        if let timeObserver { timeObserverPlayer?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func attach(_ next: AVPlayer?) {
        guard player !== next else { return }
        observations.removeAll()
        if let timeObserver { timeObserverPlayer?.removeTimeObserver(timeObserver) }; timeObserver = nil; timeObserverPlayer = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }; endObserver = nil
        player?.pause()
        seekID = UUID(); pendingSeek = nil
        player = next
        if position != 0 { position = 0 }; if duration != 0 { duration = 0 }
        if !bufferedRanges.isEmpty { bufferedRanges = [] }; if memoryBuffer != nil { memoryBuffer = nil }
        if wantsPlayback { wantsPlayback = false }; if phase != .loading { phase = .loading }
        guard let next, let item = next.currentItem else { return }
        // Inline previews must render here even when another player has left
        // an external video route active on the system.
        next.allowsExternalPlayback = false
        apply(settings.values)
        let refreshQueue = MediaPlaybackRefreshQueue()
        let changed: () -> Void = { [weak self, weak next] in
            refreshQueue.schedule { [weak self, weak next] in
                guard let self, let next, self.player === next else { return }
                self.refresh()
            }
        }
        observations = [
            next.observe(\.timeControlStatus, options: [.initial, .new]) { _, _ in changed() },
            item.observe(\.status, options: [.initial, .new]) { _, _ in changed() },
            item.observe(\.duration, options: [.initial, .new]) { _, _ in changed() },
            item.observe(\.loadedTimeRanges, options: [.initial, .new]) { _, _ in changed() },
        ]
        timeObserverPlayer = next
        timeObserver = next.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { _ in changed() }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self, weak next] _ in
            Task { @MainActor in
                guard let self, let next, self.player === next else { return }
                if self.wantsPlayback { self.wantsPlayback = false }
                if self.phase != .finished { self.phase = .finished }
                if self.position != self.duration { self.position = self.duration }
            }
        }
        refresh()
    }

    /// Byte ranges mapped proportionally onto the track, so they need no known duration; approximate for variable bitrates.
    func updateMemoryBuffer(_ snapshot: PreviewResourceCacheSnapshot?) {
        if memoryBuffer != snapshot { memoryBuffer = snapshot }
        if let snapshot { if snapshot.normalizedRanges != bufferedRanges { bufferedRanges = snapshot.normalizedRanges } }
        else if player != nil { refresh() }
        else if !bufferedRanges.isEmpty { bufferedRanges = [] }
    }
    var bufferHelp: String? {
        guard let memoryBuffer else { return nil }
        let amount = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory) }
        let total = memoryBuffer.contentLength.map { " of \(amount($0))" } ?? ""
        return "In memory: \(amount(memoryBuffer.cachedBytes))\(total)."
    }

    private func apply(_ values: MediaPlaybackSettings.Values) {
        guard let player else { return }
        player.volume = Float(values.volume); player.isMuted = values.muted
        let speedChanged = player.defaultRate != Float(values.speed)
        player.defaultRate = Float(values.speed)
        if speedChanged && (player.rate > 0 || player.timeControlStatus == .waitingToPlayAtSpecifiedRate) { player.play() }
    }
    private func refresh() {
        guard let player, let item = player.currentItem else { return }
        let total = item.duration.seconds
        let nextDuration = total.isFinite && total > 0 ? total : 0
        if duration != nextDuration { duration = nextDuration }
        let current = pendingSeek ?? player.currentTime().seconds
        let nextPosition = current.isFinite ? max(0, duration > 0 ? min(current, duration) : current) : 0
        if position != nextPosition { position = nextPosition }
        let loaded = memoryBuffer?.normalizedRanges
            ?? MediaBuffering.normalizedRanges(item.loadedTimeRanges.map(\.timeRangeValue), duration: duration)
        if loaded != bufferedRanges { bufferedRanges = loaded }
        let nextPhase: Phase, nextWantsPlayback: Bool
        if item.status == .failed { nextPhase = .failed; nextWantsPlayback = false }
        else if item.status != .readyToPlay { nextPhase = .loading; nextWantsPlayback = wantsPlayback }
        else if player.timeControlStatus == .waitingToPlayAtSpecifiedRate { nextPhase = .buffering; nextWantsPlayback = true }
        else if player.timeControlStatus == .playing { nextPhase = .playing; nextWantsPlayback = true }
        else if duration > 0 && position >= duration - 0.05 { nextPhase = .finished; nextWantsPlayback = false }
        else { nextPhase = position > 0.05 ? .paused : .ready; nextWantsPlayback = false }
        if phase != nextPhase { phase = nextPhase }
        if wantsPlayback != nextWantsPlayback { wantsPlayback = nextWantsPlayback }
    }
    func togglePlayback() {
        guard let player, canPlay else { return }
        if wantsPlayback || player.timeControlStatus != .paused {
            player.pause(); wantsPlayback = false; phase = .paused
        } else {
            if phase == .finished { seek(to: 0) }
            wantsPlayback = true; player.play(); phase = .buffering
        }
    }
    func skip(_ seconds: Double) { seek(to: position + seconds) }
    func seek(to seconds: Double) {
        guard let player, canSeek, seconds.isFinite else { return }
        let target = min(duration, max(0, seconds)), request = UUID()
        seekID = request; pendingSeek = target; position = target
        player.currentItem?.cancelPendingSeeks()
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] _ in
            Task { @MainActor in
                guard let self, let player, self.player === player, self.seekID == request else { return }
                self.pendingSeek = nil; self.refresh()
            }
        }
    }
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—:—" }
        let value = Int(min(seconds, 359_999))
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
            : String(format: "%d:%02d", value / 60, value % 60)
    }
}
