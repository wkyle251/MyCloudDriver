import AVFoundation
import AppKit
import Foundation

/// Generated media and files only. Never reads a user's disk or media.

private final class Fractions: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []
    func append(_ value: Double) { lock.lock(); stored.append(value); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return stored }
}

private final class FileProvider: NativeCloudDrive, @unchecked Sendable {
    let kind: CloudDriveKind = .local
    let root = CloudDriveLocation(id: "buffer-tests", title: "Test")
    func materialize(_ item: CloudDriveItem, directory: URL, progress: @escaping CloudDriveProgressHandler) async throws -> URL { item.url! }
    func list(_ location: CloudDriveLocation, offset: Int, search: String) async throws -> CloudDrivePage { .init(items: [], total: 0) }
    func scanItems(_ items: [CloudDriveItem], location: CloudDriveLocation, progress: @escaping CloudDriveProgressHandler) async throws -> [CloudDriveItem] { items }
    func createContainer(_ name: String, in location: CloudDriveLocation) async throws -> CloudDriveUndo? { nil }
    func rename(_ item: CloudDriveItem, to name: String) async throws -> CloudDriveUndo? { nil }
    func relocate(_ items: [CloudDriveItem], from: CloudDriveLocation, to: CloudDriveLocation, copy: Bool, progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? { nil }
    func importFiles(_ urls: [URL], into: CloudDriveLocation, progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? { nil }
    func delete(_ items: [CloudDriveItem], progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? { nil }
}

@main @MainActor struct ExternalMediaBufferTests {
    static func wait(_ message: String, seconds: Double = 15, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        precondition(condition(), "Timed out: \(message)")
    }
    static func ffmpeg(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        process.arguments = ["-nostdin", "-v", "error", "-y"] + arguments
        try process.run(); process.waitUntilExit()
        precondition(process.terminationStatus == 0, "ffmpeg failed")
    }
    /// Throws if `operation` has not finished in time, instead of hanging the suite.
    static func within<T: Sendable>(_ seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); throw CloudDriveError.message("Timed out after \(seconds)s") }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    // MARK: Which volumes are buffered

    static func volumeRuleTests() {
        precondition(ExternalVolume.isExternal(isInternal: false, isLocal: true), "A mounted external disk is buffered")
        precondition(!ExternalVolume.isExternal(isInternal: true, isLocal: true), "The startup disk is never buffered")
        precondition(!ExternalVolume.isExternal(isInternal: nil, isLocal: true), "Unknown internal-ness is not treated as external, like the sidebar")
        precondition(!ExternalVolume.isExternal(isInternal: false, isLocal: false), "A network share is not an external disk")
        precondition(ExternalVolume.bufferedKind(isInternal: false, isLocal: true) == .externalDisk, "A mounted external disk is buffered")
        precondition(ExternalVolume.bufferedKind(isInternal: nil, isLocal: false) == .networkShare
                     && ExternalVolume.bufferedKind(isInternal: false, isLocal: false) == .networkShare, "A network share is buffered too")
        precondition(ExternalVolume.bufferedKind(isInternal: true, isLocal: true) == nil, "The startup disk is never buffered")
        precondition(ExternalVolume.bufferedKind(isInternal: nil, isLocal: true) == nil, "Unknown internal-ness is not buffered")
        precondition(ExternalVolume.bufferedKind(isInternal: false, isLocal: nil) == nil, "Unknown locality is not buffered")
        precondition(ExternalVolume.bufferedKind(FileManager.default.temporaryDirectory) == nil, "The Mac's own volume is not buffered")
        precondition(ExternalVolume.Kind.networkShare.bufferingMessage == "Buffering from network share…"
                     && ExternalVolume.Kind.externalDisk.bufferingMessage == "Buffering from external disk…")
        precondition(!ExternalVolume.isExternal(isInternal: false, isLocal: nil))
        precondition(!ExternalVolume.isExternal(FileManager.default.temporaryDirectory), "The Mac's own volume is not external")
        print("PASS external disks and network shares are buffered; the startup disk and volumes of unknown kind are not")

        // The download helper is told when it writes to a spinning external disk or a share, so it saves progress calmly.
        let inherited = ["PATH": "/usr/bin", DownloadDestinationPolicy.environmentKey: "stale"]
        precondition(DownloadDestinationPolicy.environment(applying: .externalDisk, to: inherited)[DownloadDestinationPolicy.environmentKey] == "external")
        precondition(DownloadDestinationPolicy.environment(applying: .networkShare, to: inherited)[DownloadDestinationPolicy.environmentKey] == "network")
        let internalDisk = DownloadDestinationPolicy.environment(applying: nil, to: inherited)
        precondition(internalDisk[DownloadDestinationPolicy.environmentKey] == nil && internalDisk["PATH"] == "/usr/bin",
                     "An internal destination removes any inherited value and keeps the rest")
        precondition(DownloadDestinationPolicy.environmentKey == "MYCLOUDDRIVER_DOWNLOAD_DESTINATION", "The engine reads this exact name")
        print("PASS downloads to an external disk or share tell the engine, so it saves progress less often")
    }

    // MARK: The RAM store

    static func bufferTests() {
        let gib: UInt64 = 1 << 30
        precondition(MemoryRangeBuffer.automaticBudget(physicalMemory: 32 * gib) == Int64(gib), "Capped at 1 GiB")
        precondition(MemoryRangeBuffer.automaticBudget(physicalMemory: 8 * gib) == Int64(gib / 2), "One sixteenth of RAM")
        precondition(MemoryRangeBuffer.automaticBudget(physicalMemory: gib) == 64 << 20, "Never below 64 MiB")
        print("PASS automatic budget is one sixteenth of RAM, between 64 MiB and 1 GiB")

        // Three blocks, the last one partial.
        let buffer = MemoryRangeBuffer(contentLength: 10_340, budgetBytes: 3 * 4_096, blockSize: 4_096)
        let bytes = (0..<10_340).map { UInt8($0 % 251) }
        func block(_ index: Int) -> Data { Data(bytes[index * 4_096 ..< min(bytes.count, (index + 1) * 4_096)]) }
        precondition(buffer.blockCount == 3 && buffer.data(from: 0, maxLength: 10) == nil, "Nothing resident at first")
        precondition(!buffer.store(Data(count: 100), block: 0), "A block of the wrong length is rejected")
        precondition(!buffer.store(block(0), block: 3), "A block past the end is rejected")
        for index in 0..<3 { precondition(buffer.store(block(index), block: index)) }
        precondition(buffer.data(from: 0, maxLength: 100_000) == Data(bytes), "Resident blocks read back as one contiguous run")
        precondition(buffer.data(from: 5_000, maxLength: 100) == Data(bytes[5_000..<5_100]), "A read can start inside a block")
        precondition(buffer.data(from: 10_340, maxLength: 10) == nil && buffer.data(from: 20_000, maxLength: 10) == nil)
        precondition(buffer.residentBytes == 10_340 && buffer.snapshot.ranges == [0..<10_340] && buffer.snapshot.contentLength == 10_340,
                     "Adjacent blocks form one range; the partial last block counts its real length")
        print("PASS blocks store, read back contiguously, reject bad sizes and report one merged range")

        // Eight blocks of 1 KiB over a 40 KiB file. The window keeps more ahead of the playhead than behind it.
        let window = MemoryRangeBuffer(contentLength: 40 * 1_024, budgetBytes: 8 * 1_024, blockSize: 1_024)
        func resident(_ buffer: MemoryRangeBuffer) -> [Int] { (0..<buffer.blockCount).filter { buffer.contains($0) } }
        for index in 0...5 { window.store(Data(count: 1_024), block: index) }
        window.setAnchor(5 * 1_024)
        for index in 6...8 { window.store(Data(count: 1_024), block: index); precondition(window.residentBytes <= 8 * 1_024) }
        precondition(resident(window) == [1, 2, 3, 4, 5, 6, 7, 8], "The block farthest behind the playhead goes first: \(resident(window))")
        window.store(Data(count: 1_024), block: 9); window.store(Data(count: 1_024), block: 10)
        precondition(resident(window) == [3, 4, 5, 6, 7, 8, 9, 10] && window.contains(5), "Behind goes before ahead, never the playhead's block: \(resident(window))")
        window.setAnchor(30 * 1_024)
        window.store(Data(count: 1_024), block: 30)
        precondition(window.contains(30) && window.residentBytes <= 8 * 1_024, "A seek far away keeps the new position resident")
        print("PASS the window evicts behind the playhead first, never exceeds its budget and never drops the playhead's block")

        let tiny = MemoryRangeBuffer(contentLength: 10 * 1_024, budgetBytes: 1_024, blockSize: 1_024)
        tiny.store(Data(count: 1_024), block: 0); tiny.setAnchor(0); tiny.store(Data(count: 1_024), block: 5); tiny.store(Data(count: 1_024), block: 6)
        precondition(resident(tiny) == [0, 6], "Even a minimal budget keeps the playhead and the newest block: \(resident(tiny))")
        tiny.removeAll()
        precondition(tiny.residentBytes == 0 && tiny.snapshot.ranges.isEmpty, "removeAll releases everything")
        print("PASS a minimal budget keeps two blocks and removeAll frees them")

        let shared = MemoryRangeBuffer(contentLength: 64 * 1_024, budgetBytes: 16 * 1_024, blockSize: 1_024)
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for round in 0..<400 {
                let index = (worker * 7 + round) % 64
                shared.setAnchor(Int64(index * 1_024))
                shared.store(Data(count: 1_024), block: index)
                _ = shared.data(from: Int64(index * 1_024), maxLength: 4_096); _ = shared.snapshot
            }
        }
        precondition(shared.residentBytes <= 16 * 1_024, "Concurrent use never exceeds the budget")
        print("PASS concurrent readers and writers stay within budget")
    }

    // MARK: The file-backed AVAssetResourceLoader

    static func readActivityTests() {
        var activity = FilePreviewReadActivity()
        precondition(activity.bytesPerSecond(at: 10) == 0 && activity.bytesRead == 0 && !activity.isReading)
        activity.begin(at: 10)
        activity.record(bytes: 1_000, at: 10.5)
        precondition(activity.isReading && abs(activity.bytesPerSecond(at: 10.5) - 2_000) < 0.001)
        activity.record(bytes: 2_000, at: 11.2)
        precondition(activity.bytesRead == 3_000 && abs(activity.bytesPerSecond(at: 11.2) - 3_000) < 0.001)
        precondition(abs(activity.bytesPerSecond(at: 11.6) - 2_000) < 0.001, "Old bytes age out of the one-second rate")
        precondition(activity.bytesPerSecond(at: 12.3) == 0 && activity.isReading, "A stalled read stays active but its speed falls to zero")
        activity.end()
        precondition(activity.bytesPerSecond(at: 12.3) == 0 && !activity.isReading)
        activity.begin(at: 20)
        precondition(activity.bytesPerSecond(at: 20) == 0, "Resuming never reuses the previous burst's speed")
        activity.record(bytes: 1_000, at: 20.25)
        precondition(activity.bytesRead == 4_000 && abs(activity.bytesPerSecond(at: 20.25) - 4_000) < 0.001,
                     "Rereads count even if the retained RAM window stays the same size")
        activity.end()
        print("PASS real read throughput counts rereads, ages out during a stall and resets on idle/resume")
    }

    static func loaderTests(in directory: URL) async throws {
        let small = directory.appendingPathComponent("Small.mp4"), large = directory.appendingPathComponent("Large.mp4")
        try ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=160x120:rate=12", "-t", "3", "-c:v", "libx264", "-threads", "2", "-pix_fmt", "yuv420p", small.path])
        // Several MB at a high bitrate, with the movie header at the end like many camera files.
        try ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=320x240:rate=24", "-vf", "noise=alls=45:allf=t", "-t", "10", "-c:v", "libx264", "-g", "24", "-b:v", "3M",
                    "-minrate", "3M", "-maxrate", "3M", "-bufsize", "3M", "-threads", "2", "-pix_fmt", "yuv420p", large.path])
        let largeLength = Int64(try Data(contentsOf: large).count)
        precondition(largeLength > 3_000_000, "Fixture must exceed the small test budget (\(largeLength))")

        /// The exact frame at `seconds`. With AVFoundation's default tolerance it may return an earlier keyframe,
        /// which would only prove the start of the file is readable.
        @Sendable func exactFrame(_ asset: AVURLAsset, at seconds: Double) async throws -> CGImage {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        }
        func makeAsset(_ loader: FilePreviewResourceLoader) -> AVURLAsset {
            let asset = AVURLAsset(url: loader.assetURL)
            asset.resourceLoader.setDelegate(loader, queue: loader.delegateQueue)
            return asset
        }

        // A file that fits is read into RAM completely, and plays from it.
        do {
            let loader = try FilePreviewResourceLoader(fileURL: small, budgetBytes: 64 << 20, blockSize: 16 * 1_024)
            let reported = Fractions()
            try await loader.prime { reported.append($0) }
            let fractions = reported.values
            precondition(fractions == fractions.sorted() && fractions.last == 1, "Priming reports steady progress up to 1: \(fractions)")
            let asset = makeAsset(loader)
            let item = AVPlayerItem(asset: asset), player = AVPlayer(playerItem: item)
            await wait("player item ready through the loader") { item.status != .unknown }
            precondition(item.status == .readyToPlay, "Status \(item.status.rawValue): \(String(describing: item.error))")
            let frame = try await exactFrame(asset, at: 1)
            precondition(frame.width == 160 && frame.height == 120, "A real frame decodes from the RAM buffer")
            let length = Int64(try Data(contentsOf: small).count)
            loader.setReadingAhead(true)   // playback has started
            await wait("the whole file is held in RAM") { loader.snapshot.cachedBytes == length }
            precondition(loader.snapshot.ranges == [0..<length] && loader.snapshot.fraction == 1)
            await wait("reader stops after filling the buffer") { !loader.status.isReading }
            let status = loader.status
            precondition(status.bytesRead == length && status.bytesPerSecond == 0 && status.title == "Fully buffered")
            precondition(status.cache == loader.snapshot && status.budgetBytes == 64 << 20)
            player.replaceCurrentItem(with: nil); loader.invalidate()
            precondition(loader.snapshot.cachedBytes == 0, "Invalidating releases the RAM")
            precondition(loader.status.bytesPerSecond == 0 && !loader.status.isReading, "Invalidating stops read telemetry")
            print("PASS a file that fits is buffered completely, decodes real frames and is released on invalidate")
        }

        // A file larger than the budget uses a window that follows the playhead; head, middle and tail all play.
        do {
            let budget: Int64 = 1 << 20
            let loader = try FilePreviewResourceLoader(fileURL: large, budgetBytes: budget, blockSize: 64 * 1_024)
            try await loader.prime { _ in }
            let asset = makeAsset(loader)
            let item = AVPlayerItem(asset: asset), player = AVPlayer(playerItem: item)
            await wait("player item ready through the loader") { item.status != .unknown }
            precondition(item.status == .readyToPlay, "Status \(item.status.rawValue): \(String(describing: item.error))")
            for seconds in [0.5, 5.0, 9.4, 2.0] {
                let frame = try await within(30) { try await exactFrame(asset, at: seconds) }
                precondition(frame.width == 320 && frame.height == 240, "Frame at \(seconds)s")
                precondition(loader.snapshot.cachedBytes <= budget, "Resident \(loader.snapshot.cachedBytes) exceeds the \(budget) byte budget at \(seconds)s")
            }
            precondition(loader.snapshot.cachedBytes > 0 && loader.snapshot.cachedBytes < largeLength, "Only a window of the file is resident")
            precondition(loader.status.bytesRead > loader.status.cache.cachedBytes, "Throughput includes evicted blocks")
            player.replaceCurrentItem(with: nil); loader.invalidate()
            print("PASS a file larger than the budget plays from head, middle and tail within its RAM budget")
        }

        // Selecting a video reads only its head and tail. More is read ahead once playback starts, and only a window.
        do {
            let block: Int64 = 64 * 1_024
            let loader = try FilePreviewResourceLoader(fileURL: large, budgetBytes: 1 << 20, blockSize: Int(block), readAheadBytes: 8 * block)
            try await loader.prime(headBlocks: 4, tailBlocks: 1) { _ in }
            let primed = loader.snapshot.cachedBytes
            precondition(primed > 0 && primed <= 5 * block, "Head and tail only: \(primed)")
            try await Task.sleep(nanoseconds: 400_000_000)
            precondition(loader.snapshot.cachedBytes == primed, "Nothing more is read before playback starts: \(primed) then \(loader.snapshot.cachedBytes)")
            loader.setReadingAhead(true)
            await wait("a window ahead of the playhead is read") { loader.snapshot.cachedBytes >= primed + 4 * block }
            try await Task.sleep(nanoseconds: 400_000_000)
            precondition(loader.snapshot.cachedBytes == primed + 4 * block, "Only the window is read, not the file: \(loader.snapshot.cachedBytes) of \(largeLength)")
            precondition(loader.snapshot.ranges.first == 0..<(8 * block), "The window starts at the playhead: \(loader.snapshot.ranges)")
            loader.setReadingAhead(false); loader.setReadingAhead(true)
            try await Task.sleep(nanoseconds: 200_000_000)
            precondition(loader.snapshot.cachedBytes == primed + 4 * block, "Pausing and resuming does not read more than the window")
            loader.invalidate(); loader.setReadingAhead(true)
            precondition(loader.snapshot.cachedBytes == 0, "A released preview reads nothing")
            print("PASS reading ahead waits for playback and stops at a bounded window")
        }

        // Priming reads the head and the tail, where many movies keep their header.
        do {
            let loader = try FilePreviewResourceLoader(fileURL: large, budgetBytes: 1 << 20, blockSize: 64 * 1_024)
            try await loader.prime(headBlocks: 4, tailBlocks: 2) { _ in }
            let ranges = loader.snapshot.ranges
            precondition(ranges.first?.lowerBound == 0 && ranges.first!.upperBound >= 4 * 64 * 1_024, "Head primed: \(ranges)")
            let lastBlockStart = ((largeLength - 1) / 65_536) * 65_536
            precondition(ranges.last?.upperBound == largeLength && ranges.last!.lowerBound <= lastBlockStart - 65_536, "Tail primed: \(ranges)")
            loader.invalidate()
            print("PASS priming reads the head and the tail of the file")
        }

        // The disk goes away: a read that fails ends the request with an error, and what is already in RAM still plays.
        do {
            let copy = directory.appendingPathComponent("Unplugged.mp4")
            try FileManager.default.copyItem(at: large, to: copy)
            let loader = try FilePreviewResourceLoader(fileURL: copy, budgetBytes: 1 << 20, blockSize: 64 * 1_024)
            try await loader.prime(headBlocks: 4, tailBlocks: 1) { _ in }
            let handle = try FileHandle(forWritingTo: copy)
            try handle.truncate(atOffset: 256 * 1_024); try handle.close()
            let asset = makeAsset(loader)
            let outcome: String
            do {
                _ = try await within(30) { try await exactFrame(asset, at: 8) }
                outcome = "decoded"
            } catch { outcome = (error as? CloudDriveError) == nil ? "failed" : "timed out" }
            precondition(outcome == "failed", "A vanished file must fail the request, not hang or decode: \(outcome)")
            precondition(loader.failure != nil, "The loader records why reads stopped")
            precondition(loader.status.failed && loader.status.title == "Read failed" && loader.status.bytesPerSecond == 0,
                         "A failed disk never keeps displaying an old read speed")
            loader.invalidate()
            print("PASS a file that becomes unreadable fails the player's request instead of hanging")
        }
    }

    // MARK: The preview model and the seek bar

    static func modelTests(in directory: URL, defaults: UserDefaults) async throws {
        let movie = directory.appendingPathComponent("Model.mp4")
        try ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=160x120:rate=12", "-t", "4", "-c:v", "libx264", "-threads", "2", "-pix_fmt", "yuv420p", movie.path])
        let item = CloudDriveItem(id: "movie", name: "Model.mp4", isFolder: false, url: movie, mediaType: "video")
        let provider = FileProvider()

        // External disk: the player reads through the RAM loader, and the seek bar shows what is in RAM.
        let external = NativeMediaPreviewModel(settings: MediaPlaybackSettings(defaults: defaults))
        external.bufferedVolume = { _ in .externalDisk }
        external.memoryBlockSize = 16 * 1_024
        external.prepare(item, provider: provider)
        await wait("external preview ready") { external.ready }
        let asset = external.playback.player?.currentItem?.asset as? AVURLAsset
        precondition(asset?.url.scheme == FilePreviewResourceLoader.scheme && external.memoryLoader != nil, "External files play through the RAM loader")
        await wait("seek bar shows RAM ranges and duration is known") { !external.playback.bufferedRanges.isEmpty && external.playback.duration > 0 }
        precondition(external.playback.bufferedRanges.allSatisfy { $0.lowerBound >= 0 && $0.upperBound <= 1 && $0.upperBound > $0.lowerBound })
        let length = Int64(try Data(contentsOf: movie).count)
        await wait("whole small file in RAM") { external.playback.memoryBuffer?.cachedBytes == length }
        await wait("external buffer status catches up") { external.bufferStatus?.cache.cachedBytes == length && external.bufferStatus?.isReading == false }
        precondition(external.bufferSource == .externalDisk && external.bufferStatus?.title == "Fully buffered")
        precondition(external.playback.bufferedRanges == [0...1], "A fully buffered file fills the seek bar: \(external.playback.bufferedRanges)")
        precondition(external.playback.bufferHelp?.contains("memory") == true, "The seek bar explains the shading")
        external.clear()
        precondition(external.memoryLoader == nil && external.playback.bufferedRanges.isEmpty && external.playback.memoryBuffer == nil, "clear() frees the buffer")
        precondition(external.bufferStatus == nil && external.bufferSource == nil, "clear() removes the buffering status")
        print("PASS external preview plays through the RAM loader, shows RAM ranges on the seek bar and frees them on clear")

        // A network share is read through the same RAM loader, so seeking does not wait on the network.
        let share = NativeMediaPreviewModel(settings: MediaPlaybackSettings(defaults: defaults))
        share.bufferedVolume = { _ in .networkShare }
        share.memoryBlockSize = 16 * 1_024
        share.prepare(item, provider: provider)
        await wait("network share preview ready") { share.ready }
        let shareAsset = share.playback.player?.currentItem?.asset as? AVURLAsset
        precondition(shareAsset?.url.scheme == FilePreviewResourceLoader.scheme && share.memoryLoader != nil, "Network files play through the RAM loader")
        await wait("whole small network file in RAM") { share.playback.memoryBuffer?.cachedBytes == length }
        await wait("network buffer status catches up") { share.bufferStatus?.cache.cachedBytes == length && share.bufferStatus?.isReading == false }
        precondition(share.bufferSource == .networkShare && share.bufferStatus?.bytesRead == length && share.bufferStatus?.bytesPerSecond == 0)
        precondition(share.playback.bufferedRanges == [0...1] && share.playback.bufferHelp?.contains("memory") == true)
        share.clear()
        precondition(share.memoryLoader == nil && share.playback.memoryBuffer == nil, "clear() frees a network file's buffer")
        try await Task.sleep(nanoseconds: 300_000_000)
        precondition(share.bufferStatus == nil && share.bufferSource == nil, "A pending status update cannot restore a cleared preview")
        print("PASS a network share plays through the RAM loader, shows RAM ranges on the seek bar and frees them on clear")

        // Internal disk and everything else are untouched: the original is played directly.
        let internalModel = NativeMediaPreviewModel(settings: MediaPlaybackSettings(defaults: defaults))
        internalModel.bufferedVolume = { _ in nil }
        internalModel.prepare(item, provider: provider)
        await wait("internal preview ready") { internalModel.ready }
        let direct = internalModel.playback.player?.currentItem?.asset as? AVURLAsset
        precondition(direct?.url == movie && internalModel.memoryLoader == nil && internalModel.playback.memoryBuffer == nil,
                     "A file on the Mac's own disk plays directly")
        precondition(internalModel.bufferStatus == nil && internalModel.bufferSource == nil)
        precondition(internalModel.sourceBufferStatus == nil, "The internal disk has no fallback buffering panel either")
        internalModel.clear()
        print("PASS a file on an internal volume still plays directly")

        let legacy = directory.appendingPathComponent("Legacy.avi")
        try ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=160x120:rate=12", "-t", "2", "-c:v", "mpeg4", "-threads", "2", legacy.path])
        let legacyItem = CloudDriveItem(id: "legacy", name: "Legacy.avi", isFolder: false, url: legacy, mediaType: "video")
        let compatible = NativeMediaPreviewModel(settings: MediaPlaybackSettings(defaults: defaults))
        compatible.bufferedVolume = { _ in .externalDisk }
        compatible.prepare(legacyItem, provider: provider)
        await wait("compatible external preview") { compatible.ready || compatible.failure != nil }
        precondition(compatible.ready && compatible.preparation != nil && compatible.memoryLoader == nil)
        precondition(compatible.sourceBufferStatus?.source == .volume(.externalDisk)
            && compatible.sourceBufferStatus?.phase == .available && compatible.sourceBufferStatus?.fraction == 1,
            "A compatible copy keeps the external disk's buffering panel even when it no longer uses the RAM loader")
        compatible.clear()
        precondition(compatible.sourceBufferStatus == nil)
        print("PASS compatible external video copies retain the buffering panel and clear it on close")

        // Switching files releases the previous file's buffer.
        let second = CloudDriveItem(id: "second", name: "Second.mp4", isFolder: false, url: movie, mediaType: "video", revision: "other")
        let switching = NativeMediaPreviewModel(settings: MediaPlaybackSettings(defaults: defaults))
        switching.bufferedVolume = { _ in .externalDisk }; switching.memoryBlockSize = 16 * 1_024
        switching.prepare(item, provider: provider)
        await wait("first preview ready") { switching.ready }
        let first = switching.memoryLoader
        switching.prepare(second, provider: provider)
        precondition(first?.snapshot.cachedBytes == 0, "Selecting another file invalidates the previous loader and releases its RAM")
        await wait("second preview ready") { switching.ready && switching.memoryLoader !== first }
        await wait("second preview status") { switching.bufferStatus?.cache.cachedBytes == length }
        switching.clear()
        print("PASS selecting another file releases the previous file's RAM")

        // The seek bar maps byte ranges onto the track, whatever the player has loaded itself.
        let playback = MediaPlaybackController(settings: MediaPlaybackSettings(defaults: defaults))
        playback.updateMemoryBuffer(PreviewResourceCacheSnapshot(cachedBytes: 300, contentLength: 1_000, ranges: [0..<100, 600..<800]))
        precondition(playback.bufferedRanges == [0...0.1, 0.6...0.8], "Ranges map proportionally: \(playback.bufferedRanges)")
        precondition(playback.bufferHelp?.contains("300") == true || playback.bufferHelp?.contains("bytes") == true, "Help reports the amount: \(String(describing: playback.bufferHelp))")
        playback.updateMemoryBuffer(nil)
        precondition(playback.bufferedRanges.isEmpty && playback.bufferHelp == nil)
        print("PASS the seek bar maps RAM byte ranges proportionally and reverts when there is no buffer")
    }

    static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("ExternalMediaBufferTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "MyCloudDriver.ExternalMediaBufferTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        volumeRuleTests()
        bufferTests()
        readActivityTests()
        try await loaderTests(in: directory)
        try await modelTests(in: directory, defaults: defaults)
    }
}
