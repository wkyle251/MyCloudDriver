import AVFoundation
import Combine
import Foundation

@main @MainActor struct MediaPlaybackTests {
    static func wait(_ check: () -> Bool) async {
        for _ in 0..<150 {
            if check() { return }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        precondition(check(), "Timed out waiting for AVFoundation")
    }
    static func main() async throws {
        let refreshQueue = MediaPlaybackRefreshQueue()
        var refreshes = 0
        for _ in 0..<1_000 { refreshQueue.schedule { refreshes += 1 } }
        precondition(refreshes == 0)
        await wait { refreshes == 1 }
        for _ in 0..<1_000 { refreshQueue.schedule { refreshes += 1 } }
        await wait { refreshes == 2 }
        print("PASS playback observer bursts coalesce without losing the next refresh")

        let suite = "MyCloudDriver.MediaTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = MediaPlaybackSettings(defaults: defaults)
        settings.setVolume(0.27); settings.toggleMute(); settings.setSpeed(1.5)
        let restored = MediaPlaybackSettings(defaults: defaults)
        precondition(restored.values == settings.values && restored.values.muted)
        settings.setVolume(-1); precondition(settings.values.volume == 0)
        settings.toggleMute(); precondition(settings.values.volume == 0.27 && !settings.values.muted)
        settings.setVolume(2); precondition(settings.values.volume == 1)
        settings.setVolume(.nan); settings.setSpeed(.infinity); settings.setSpeed(3)
        precondition(settings.values.volume == 1 && settings.values.speed == 1.5)
        defaults.set(Double.infinity, forKey: "mediaPreviewVolume")
        defaults.set(-4, forKey: "mediaPreviewSpeed")
        let sanitized = MediaPlaybackSettings(defaults: defaults)
        precondition(sanitized.values.volume == 1 && sanitized.values.speed == 1)
        print("PASS persistence, mute/restore, volume bounds and invalid preferences")

        func range(_ start: Double, _ length: Double) -> CMTimeRange {
            .init(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: length, preferredTimescale: 600))
        }
        let loaded = [range(60, 20), range(-10, 30), range(15, 10), range(20, 30), range(90, 40),
                      range(110, 3), range(-20, 5), range(40, 0), CMTimeRange(start: .invalid, duration: .positiveInfinity)]
        precondition(MediaBuffering.normalizedRanges(loaded, duration: 100) == [0...0.5, 0.6...0.8, 0.9...1],
                     "Overlaps must merge, actual gaps must remain, and ranges must stay within the file duration")
        for duration in [0, -1, Double.nan, Double.infinity] {
            precondition(MediaBuffering.normalizedRanges(loaded, duration: duration).isEmpty)
        }
        precondition(MediaBuffering.normalizedRanges([range(0.2, 0.3)], duration: 0.5) == [0.4...1])
        print("PASS buffered ranges: sparse seeks, overlaps, clipping, empty/invalid durations and sub-second media")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MediaTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Silence.wav")
        try wave(seconds: 3).write(to: url)
        settings.setVolume(0.37)
        let controller = MediaPlaybackController(settings: settings)
        let first = AVPlayer(url: url)
        controller.attach(first)
        await wait { controller.canSeek }
        precondition(abs(controller.duration - 3) < 0.01)
        precondition(abs(first.volume - 0.37) < 0.001 && first.defaultRate == 1.5)
        precondition(first.rate == 0)
        try await Task.sleep(nanoseconds: 150_000_000)
        var publications = 0
        let changes = controller.objectWillChange.sink { publications += 1 }
        try await Task.sleep(nanoseconds: 800_000_000)
        precondition(publications == 0, "Paused periodic observations must not redraw unchanged playback state")
        let memory = PreviewResourceCacheSnapshot(cachedBytes: 16, contentLength: 32, ranges: [0..<16])
        controller.updateMemoryBuffer(memory)
        publications = 0
        for _ in 0..<100 { controller.updateMemoryBuffer(memory) }
        precondition(publications == 0, "Identical memory-buffer snapshots must not publish")
        controller.updateMemoryBuffer(nil)
        withExtendedLifetime(changes) {}
        let audioTracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
        precondition(!audioTracks.isEmpty)
        let hasVideo = try await MediaVideoTracks.hasVideo(audioTracks)
        precondition(!hasVideo)
        let cancelledInspection = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await MediaVideoTracks.hasVideo(audioTracks)
        }
        do { _ = try await cancelledInspection.value; preconditionFailure("Cancelled track inspection must stop") }
        catch is CancellationError {}
        print("PASS paused playback and unchanged buffers avoid publications; bounded background track inspection rejects audio-only and cancelled sources")
        settings.toggleMute(); settings.setSpeed(0.75)
        await wait { first.isMuted && first.defaultRate == 0.75 }
        precondition(first.rate == 0, "Preference changes must not start a paused video")
        controller.togglePlayback()
        await wait { first.timeControlStatus == .playing }
        settings.setSpeed(1.25)
        await wait { abs(first.rate - 1.25) < 0.01 }
        controller.togglePlayback()
        await wait { first.rate == 0 && !controller.wantsPlayback }
        controller.seek(to: 1.8)
        await wait { abs(first.currentTime().seconds - 1.8) < 0.05 }
        controller.skip(-10)
        await wait { first.currentTime().seconds < 0.05 }
        controller.seek(to: .nan)
        precondition(controller.position.isFinite)
        controller.seek(to: 500)
        await wait { controller.phase == .finished }
        controller.togglePlayback()
        await wait { first.timeControlStatus == .playing && first.currentTime().seconds < 1 }
        print("PASS real media play/pause, seeking, skip bounds, speed changes and replay")

        controller.seek(to: 2.4)
        let second = AVPlayer(url: url)
        controller.attach(second)
        await wait { controller.canSeek }
        precondition(first.rate == 0 && second.rate == 0)
        precondition(abs(second.volume - 0.37) < 0.001 && second.isMuted && second.defaultRate == 1.25)
        try? await Task.sleep(nanoseconds: 150_000_000)
        precondition(controller.position < 0.05, "A previous file's seek completion must not update this file")
        controller.attach(nil)
        precondition(!controller.canPlay && controller.position == 0 && controller.duration == 0 && controller.bufferedRanges.isEmpty)
        weak var released: MediaPlaybackController?
        do {
            let temporary = MediaPlaybackController(settings: settings); released = temporary
            temporary.attach(AVPlayer(url: url))
        }
        await wait { released == nil }
        print("PASS file switching preserves preferences, stops old playback and discards stale observers/seeks")
        precondition(MediaPlaybackController.time(3661) == "1:01:01" && MediaPlaybackController.time(.nan) == "—:—")
    }

    static func wave(seconds: Int) -> Data {
        let sampleRate: UInt32 = 8_000, dataSize = UInt32(seconds) * sampleRate * 2
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func u32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        text("RIFF"); u32(36 + dataSize); text("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        text("data"); u32(dataSize); data.append(Data(count: Int(dataSize)))
        return data
    }
}
