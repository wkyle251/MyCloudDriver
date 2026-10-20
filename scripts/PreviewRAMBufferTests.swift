import AppKit
import AVFoundation
import Darwin
import Foundation

private final class RAMFixtureDrive: NativeCloudDrive, @unchecked Sendable {
    let kind: CloudDriveKind
    let root = CloudDriveLocation(id: "ram-fixture", title: "Generated RAM fixtures")
    let files: [CloudDriveItem]
    private let lock = NSLock()
    private var requests: [String] = []
    var requestedIDs: [String] { lock.lock(); defer { lock.unlock() }; return requests }
    init(kind: CloudDriveKind = .local, files: [CloudDriveItem]) { self.kind = kind; self.files = files }
    private func record(_ id: String) { lock.lock(); requests.append(id); lock.unlock() }
    func materialize(_ item: CloudDriveItem, directory: URL, progress: @escaping CloudDriveProgressHandler) async throws -> URL {
        record(item.id); return item.url!
    }
    func list(_ location: CloudDriveLocation, offset: Int, search: String) async throws -> CloudDrivePage { .init(items: files, total: files.count) }
    func scanItems(_ items: [CloudDriveItem], location: CloudDriveLocation, progress: @escaping CloudDriveProgressHandler) async throws -> [CloudDriveItem] { items }
    func createContainer(_ name: String, in location: CloudDriveLocation) async throws -> CloudDriveUndo? { nil }
    func rename(_ item: CloudDriveItem, to name: String) async throws -> CloudDriveUndo? { nil }
    func relocate(_ items: [CloudDriveItem], from: CloudDriveLocation, to: CloudDriveLocation, copy: Bool, progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? { nil }
    func importFiles(_ urls: [URL], into: CloudDriveLocation, progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? { nil }
    func delete(_ items: [CloudDriveItem], progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? { nil }
}

@main @MainActor struct PreviewRAMBufferTests {
    static func wait(_ message: String, seconds: Double = 8, _ check: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !check(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        precondition(check(), message)
    }
    static func ledger() async throws {
        let gib: UInt64 = 1 << 30
        for installed in [16 * gib, 64 * gib] {
            precondition(PreviewMemoryBudget.budgetBytes(capMiB: 0, physicalMemory: installed) == Int64(installed))
            precondition(DownloadBufferPolicy.capsMiB(memory: installed).last == Int(installed >> 20))
            precondition(DownloadBufferPolicy.capsMiB(memory: installed).allSatisfy { UInt64($0) << 20 <= installed })
        }
        precondition(PreviewMemoryBudget.clampedCapMiB(32_768, physicalMemory: 16 * gib) == 16_384)
        precondition(PreviewMemoryBudget.budgetBytes(capMiB: 16_384, physicalMemory: 16 * gib) == Int64(16 * gib))
        precondition(PreviewMemoryBudget.clampedCapMiB(-10, physicalMemory: 16 * gib) == 0)
        let budget = PreviewMemoryBudget(limitBytes: 128, monitorsPressure: false)
        let volume = MemoryRangeBuffer(contentLength: 64, budgetBytes: 64, blockSize: 16, memoryBudget: budget)
        for index in 0..<4 { precondition(volume.store(Data(repeating: UInt8(index), count: 16), block: index)) }
        let cloud = try PreviewResourceCache(memoryBudget: budget)
        cloud.updateMetadata(typeIdentifier: "public.data", contentLength: 96, supportsByteRanges: true)
        precondition(cloud.store(Data(repeating: 7, count: 48), at: 16, allowsEviction: false) != nil)
        precondition(budget.residentBytes == 112)
        precondition(cloud.store(Data(repeating: 7, count: 16), at: 24, allowsEviction: false) != nil && budget.residentBytes == 112,
            "Overlapping network requests must count their bytes once")
        precondition(cloud.snapshot.receivedBytes == 64, "Download speed counts received bytes even when an overlap leaves RAM usage unchanged")
        precondition(cloud.read(at: 20, maximumLength: 60) == Data(repeating: 7, count: 44))
        precondition(cloud.store(Data(count: 32), at: 64, allowsEviction: false) == nil && budget.residentBytes == 112,
            "Cloud, local, next and retired buffers must share one ceiling")
        volume.removeAll()
        precondition(cloud.store(Data(count: 32), at: 64, allowsEviction: false) != nil && budget.residentBytes == 80)
        budget.setPressure(2)
        precondition(!budget.permitsReadAhead && cloud.store(Data(count: 8), at: 0, allowsEviction: false) == nil)
        budget.setPressure(1)
        precondition(cloud.store(Data(count: 8), at: 0, allowsEviction: false) != nil)
        budget.setLimit(32)
        try await wait("Lowering the limit releases existing RAM") { budget.residentBytes == 0 }
        cloud.removeFromDisk()
        print("PASS RAM cap: hardware ceiling, shared byte accounting, sparse overlap, pressure gating and immediate limit changes")
    }

    static func localReader(_ file: URL) async throws {
        let budget = PreviewMemoryBudget(limitBytes: 8 << 20, monitorsPressure: false)
        budget.setPressure(2)
        let loader = try FilePreviewResourceLoader(fileURL: file, blockSize: 64 << 10, memoryBudget: budget)
        defer { loader.invalidate() }
        loader.setReadingAhead(true)
        try await Task.sleep(nanoseconds: 350_000_000)
        precondition(loader.snapshot.cachedBytes == 0 && loader.status.memoryPressure,
            "High pressure must stop speculative disk/share reads")
        budget.setPressure(1)
        try await wait("Read-ahead resumes automatically without playback") { loader.snapshot.fraction == 1 }
        precondition(loader.status.bytesRead == loader.snapshot.contentLength)
        let shared = PreviewMemoryBudget(limitBytes: 1 << 20, monitorsPressure: false)
        let first = try FilePreviewResourceLoader(fileURL: file, blockSize: 64 << 10, memoryBudget: shared)
        defer { first.invalidate() }
        first.setReadingAhead(true)
        try await wait("First window fills the shared allowance") { first.snapshot.cachedBytes == 1 << 20 }
        let second = try FilePreviewResourceLoader(fileURL: file, blockSize: 64 << 10, memoryBudget: shared)
        defer { second.invalidate() }
        try await second.prime(headBlocks: 2, tailBlocks: 0, noProgressTimeout: 4) { _ in }
        precondition(second.snapshot.cachedBytes >= 128 << 10 && shared.residentBytes <= shared.limitBytes,
            "A full buffer in one window must not strand a second window's playback requests")
        print("PASS paused file reader: pressure stops RAM reads, normal pressure resumes and the entire file fills without playback")
    }

    static func native(_ files: [CloudDriveItem], defaults: UserDefaults) async throws {
        let provider = RAMFixtureDrive(files: files)
        let browser = NativeDriveModel(kind: .local, playbackSettings: .init(defaults: defaults), preferences: defaults)
        defer { browser.close() }
        browser.mediaPreview.selectionDelayNanoseconds = 0
        browser.mediaPreview.memoryBlockSize = 64 << 10
        browser.connect(provider)
        try await wait("Generated listing") { !browser.isLoading && browser.visibleRows.count == files.count }
        browser.fileTypeFilter = .fileExtension("mp4")
        browser.select(browser.visibleRows[0], extending: false, toggling: false)
        let a = browser.inspectorItem!
        browser.mediaPreview.prepare(a, provider: provider)
        try await wait("Paused local file completes") { browser.mediaPreview.bufferStatus?.cache.fraction == 1 }
        precondition(browser.mediaPreview.playback.player?.rate == 0 && browser.mediaPreview.memoryLoader != nil,
            "Internal local drives use the same RAM path while paused")
        try await wait("Filtered next file is fully prefetched") { browser.mediaPreview.prefetchedLoader?.snapshot.fraction == 1 }
        precondition(browser.mediaPreview.prefetchedItemID == files[2].id && !provider.requestedIDs.contains(files[1].id))
        let discarded = browser.mediaPreview.prefetchedLoader!
        browser.fileTypeFilter = .all
        try await wait("Changing the filter retargets prefetch") {
            browser.mediaPreview.prefetchedItemID == files[1].id && browser.mediaPreview.prefetchedLoader?.snapshot.fraction == 1
        }
        precondition(discarded.snapshot.cachedBytes == 0)
        let firstLoader = browser.mediaPreview.memoryLoader!, nextLoader = browser.mediaPreview.prefetchedLoader!
        browser.select(browser.visibleRows[1], extending: false, toggling: false)
        browser.mediaPreview.prepare(files[1], provider: provider)
        try await wait("Next file reuses prefetched bytes") { browser.mediaPreview.ready && browser.mediaPreview.memoryLoader === nextLoader }
        precondition(firstLoader.snapshot.cachedBytes > 0, "Previous file survives an accidental selection")
        browser.select(browser.visibleRows[0], extending: false, toggling: false)
        browser.mediaPreview.prepare(a, provider: provider)
        try await wait("Quick return reuses the old loader") { browser.mediaPreview.ready && browser.mediaPreview.memoryLoader === firstLoader }
        browser.select(browser.visibleRows[1], extending: false, toggling: false)
        browser.mediaPreview.prepare(files[1], provider: provider)
        try await wait("Selected second file") { browser.mediaPreview.ready && browser.mediaPreview.itemID == files[1].id }
        try await Task.sleep(nanoseconds: 2_200_000_000)
        precondition(firstLoader.snapshot.cachedBytes == 0, "Previous native file is cleared after two seconds")
        browser.mediaPreview.clear()
        for kind in [CloudDriveKind.icloud, .photos] {
            let cloud = RAMFixtureDrive(kind: kind, files: files)
            let model = NativeMediaPreviewModel(settings: .init(defaults: defaults))
            model.prepare(a, provider: cloud)
            try await wait("Materialized cloud file uses the RAM cap") { model.ready && model.bufferStatus?.cache.fraction == 1 }
            precondition(model.memorySource == .cloud(kind) && model.memoryLoader != nil)
            model.clear()
        }
        print("PASS native RAM: paused internal/cloud media, filtered next file, filter retargeting, prefetch promotion, quick return and two-second eviction")
    }

    static func nativeFolderQueue(_ directory: URL, defaults: UserDefaults) async throws {
        let files = try ["QueueA.mp4", "QueueB.mp4", "QueueC.mp4", "QueueD.mp4", "QueueE.mp4"].map { name -> CloudDriveItem in
            let url = directory.appendingPathComponent(name)
            try Data(repeating: 0, count: 2 << 20).write(to: url)
            return .init(id: name, name: name, isFolder: false, bytes: 2 << 20, url: url, mediaType: "video")
        }
        let shared = PreviewMemoryBudget.shared
        shared.setLimit(6 << 20)
        defer { shared.setLimit(64 << 20); shared.setPressure(1) }
        // The same NativeDriveModel handles internal, external, network, iCloud and Photos.
        for (kind, volume) in [(CloudDriveKind.local, Optional<ExternalVolume.Kind>.none),
                               (.local, .some(.externalDisk)), (.local, .some(.networkShare)),
                               (.icloud, nil), (.photos, nil)] {
            let provider = RAMFixtureDrive(kind: kind, files: files)
            let browser = NativeDriveModel(kind: kind, playbackSettings: .init(defaults: defaults), preferences: defaults)
            browser.mediaPreview.selectionDelayNanoseconds = 0
            browser.mediaPreview.memoryBlockSize = 64 << 10
            browser.mediaPreview.bufferedVolume = { _ in volume }
            browser.connect(provider)
            try await wait("Generated folder queue") { !browser.isLoading && browser.visibleRows.count == files.count }
            browser.select(browser.visibleRows[0], extending: false, toggling: false)
            browser.mediaPreview.prepare(files[0], provider: provider)
            try await wait("Current and two successors fill RAM") {
                browser.mediaPreview.bufferStatus?.cache.fraction == 1 &&
                    browser.mediaPreview.prefetchedLoaders[files[1].id]?.snapshot.fraction == 1 &&
                    browser.mediaPreview.prefetchedLoaders[files[2].id]?.snapshot.fraction == 1
            }
            try await Task.sleep(nanoseconds: 350_000_000)
            precondition(!provider.requestedIDs.contains(files[3].id) && shared.residentBytes <= 6 << 20,
                "No more files materialize when the shared RAM allowance is full")
            shared.setPressure(2); shared.setLimit(8 << 20)
            try await Task.sleep(nanoseconds: 400_000_000)
            precondition(!provider.requestedIDs.contains(files[3].id), "Pressure blocks the next file even with spare RAM")
            shared.setPressure(1)
            try await wait("More RAM resumes the next successor") { browser.mediaPreview.prefetchedLoaders[files[3].id]?.snapshot.fraction == 1 }
            let third = browser.mediaPreview.prefetchedLoaders[files[2].id]!
            let fourth = browser.mediaPreview.prefetchedLoaders[files[3].id]!
            browser.select(browser.visibleRows[2], extending: false, toggling: false)
            browser.selectionChanged()
            browser.mediaPreview.prepare(files[2], provider: provider)
            try await wait("Selecting a later buffered file promotes its cache") { browser.mediaPreview.ready && browser.mediaPreview.memoryLoader === third }
            precondition(browser.mediaPreview.prefetchedLoaders[files[3].id] === fourth,
                "Promoting any queued file preserves its later successors")
            try await wait("Freed RAM continues through following files") { browser.mediaPreview.prefetchedLoaders[files[4].id]?.snapshot.fraction == 1 }
            let future = Array(browser.mediaPreview.prefetchedLoaders.values)
            browser.enter(.init(id: "another-folder", name: "Another folder", isFolder: true))
            try await wait("Leaving a folder clears its speculative buffers") { future.allSatisfy { $0.snapshot.cachedBytes == 0 } }
            browser.close()
            try await wait("Folder RAM released") { shared.residentBytes == 0 }
            shared.setLimit(6 << 20)
        }
        print("PASS folder RAM queue: all native drives, multiple successors, full cap, pressure recovery, later-file promotion and folder cancellation")
    }

    static func http(_ directory: URL, defaults: UserDefaults) async throws {
        let movie = directory.appendingPathComponent("HTTP-fixture.mp4")
        let encoder = Process()
        encoder.executableURL = VideoPreviewPreparation.ffmpegURL!
        encoder.arguments = ["-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=160x120:rate=12", "-t", "2", "-c:v", "libx264", "-threads", "2", "-pix_fmt", "yuv420p", "-movflags", "+faststart", movie.path]
        try encoder.run(); encoder.waitUntilExit(); precondition(encoder.terminationStatus == 0)
        var body = try Data(contentsOf: movie)
        let padding = (2 << 20) - body.count
        precondition(padding >= 8)
        body.append(Data((0..<4).reversed().map { UInt8((padding >> ($0 * 8)) & 255) }))
        body.append(Data("free".utf8)); body.append(Data(count: padding - 8))
        try body.write(to: movie)
        let server = Process(), output = Pipe()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-u", "-c", #"""
import http.server, re, time, sys
body = open(sys.argv[1], "rb").read()
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        match = re.fullmatch(r'bytes=(\d+)-(\d*)', self.headers.get('Range', ''))
        start = int(match[1]) if match else 0
        end = min(int(match[2]), len(body)-1) if match and match[2] else len(body)-1
        self.send_response(206 if match else 200)
        self.send_header('Content-Type', 'video/mp4')
        self.send_header('Content-Length', end-start+1)
        self.send_header('Accept-Ranges', 'bytes')
        if match: self.send_header('Content-Range', f'bytes {start}-{end}/{len(body)}')
        self.end_headers()
        try:
            for offset in range(start, end+1, 16384):
                self.wfile.write(body[offset:min(offset+16384,end+1)]); self.wfile.flush(); time.sleep(.002)
        except (BrokenPipeError, ConnectionResetError): pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
"""#, movie.path]
        server.standardOutput = output; server.standardError = FileHandle.nullDevice
        try server.run(); defer { server.terminate(); server.waitUntilExit() }
        let port = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let budget = PreviewMemoryBudget(limitBytes: 4 << 20, monitorsPressure: false)
        let cache = try PreviewResourceCache(directory: directory.appendingPathComponent("must-not-be-created"), memoryBudget: budget)
        let prefetcher = PreviewResourcePrefetcher(originalURL: URL(string: "http://127.0.0.1:\(port)/movie")!,
            proxyURL: "", cache: cache, onCacheProgress: { _ in })
        defer { prefetcher.invalidate(); cache.removeFromDisk() }
        budget.setPressure(2); prefetcher.start(after: 0)
        try await Task.sleep(nanoseconds: 350_000_000)
        precondition(cache.snapshot.cachedBytes == 0)
        budget.setPressure(1)
        try await wait("HTTP prefetch starts with no player") { cache.snapshot.cachedBytes > 0 }
        budget.setPressure(2)
        try await Task.sleep(nanoseconds: 300_000_000)
        let stopped = cache.snapshot.cachedBytes
        try await Task.sleep(nanoseconds: 400_000_000)
        precondition(cache.snapshot.cachedBytes == stopped && stopped < 2 << 20, "Pressure stops an active HTTP prefetch")
        budget.setPressure(1)
        try await wait("HTTP prefetch resumes after pressure") { cache.snapshot.fraction == 1 }
        precondition(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("must-not-be-created").path), "Normal preview bytes stay in RAM")
        precondition(cache.read(at: 100, maximumLength: 256) == body.subdata(in: 100..<356))
        try await DownloaderModel.testPreviewRAMFolderQueue(defaults: defaults, remote: URL(string: "http://127.0.0.1:\(port)/movie")!, fileBytes: 2 << 20)
        print("PASS HTTP RAM: player-independent buffering, active pressure stop/recovery, exact sparse reads and no disk cache")
    }

    static func settings(_ defaults: UserDefaults) {
        defaults.set(3_072, forKey: DownloadBufferPolicy.legacyPreviewPreferenceKey)
        let migrated = FinderSettings(defaults: defaults)
        precondition(migrated.downloadBufferCapMiB == 3_072 && migrated.previewBufferCapMiB == 3_072)
        precondition(defaults.object(forKey: DownloadBufferPolicy.legacyPreviewPreferenceKey) == nil)
        defaults.set(1_024, forKey: DownloadBufferPolicy.legacyPreviewPreferenceKey)
        defaults.set(0, forKey: DownloadBufferPolicy.preferenceKey)
        let automatic = FinderSettings(defaults: defaults)
        precondition(automatic.previewBufferCapMiB == 0 && automatic.downloadBufferCapMiB == 0,
            "An explicit Automatic download setting overrides the former independent preview cap")
        precondition(PreviewMemoryBudget.shared.limitBytes == Int64(ProcessInfo.processInfo.physicalMemory))
        automatic.downloadBufferCapMiB = 2_048
        precondition(automatic.previewBufferCapMiB == 2_048 && PreviewMemoryBudget.shared.limitBytes == 2 << 30)
        automatic.previewBufferCapMiB = 1_024
        precondition(automatic.downloadBufferCapMiB == 1_024 && automatic.downloadBufferLimit == 1 << 30)
        precondition(FinderSettings(defaults: defaults).downloadBufferCapMiB == 1_024)
        automatic.downloadBufferCapMiB = 0
        precondition(PreviewMemoryBudget.shared.limitBytes == Int64(ProcessInfo.processInfo.physicalMemory))
        print("PASS shared settings: legacy migration, explicit Automatic preference, live preview cap and persistence")
    }

    static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PreviewRAMTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "PreviewRAMTests-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        settings(defaults)
        let settings = FinderSettings(defaults: defaults)
        settings.previewBufferCapMiB = PreviewMemoryBudget.maximumMiB() + 1
        precondition(settings.previewBufferCapMiB == PreviewMemoryBudget.maximumMiB())
        precondition(FinderSettings(defaults: defaults).previewBufferCapMiB == settings.previewBufferCapMiB)
        settings.previewBufferCapMiB = 64
        defer { PreviewMemoryBudget.shared.configure(capMiB: UserDefaults.standard.integer(forKey: PreviewMemoryBudget.preferenceKey)) }
        try await ledger()
        let files = try ["A.mp4", "B.mov", "C.mp4"].map { name -> CloudDriveItem in
            let url = directory.appendingPathComponent(name)
            try Data(repeating: 0, count: 2 << 20).write(to: url)
            return CloudDriveItem(id: name, name: name, isFolder: false, bytes: 2 << 20, url: url, mediaType: "video")
        }
        try await localReader(files[0].url!)
        try await native(files, defaults: defaults)
        try await nativeFolderQueue(directory, defaults: defaults)
        try await http(directory, defaults: defaults)
        try await DownloaderModel.testPreviewRAMQueue(defaults: defaults)
        print("PASS all preview RAM regressions")
    }
}
