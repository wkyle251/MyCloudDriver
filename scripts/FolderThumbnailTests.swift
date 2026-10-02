import AppKit
import Foundation

@MainActor
private final class ThumbnailGate {
    var starts: [(URL, String)] = []
    var pending: [URL: CheckedContinuation<NSImage, Error>] = [:]
    let image = ThumbnailTestImages.make()
    func load(_ url: URL, _ proxy: String) async throws -> NSImage {
        starts.append((url, proxy))
        // Ignore cancellation until explicitly released to exercise late
        // callbacks and ensure cancelled requests still occupy a pool slot.
        return try await withCheckedThrowingContinuation { pending[url] = $0 }
    }
    func finish(_ url: URL) { pending.removeValue(forKey: url)!.resume(returning: image) }
}

enum ThumbnailTestImages {
    static func make(side: Int = 32) -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32)!
        memset(rep.bitmapData!, 180, rep.bytesPerRow * rep.pixelsHigh)
        return NSImage(cgImage: rep.cgImage!, size: NSSize(width: side, height: side))
    }
}

private final class ThumbnailProtocolFixture: URLProtocol {
    static var png = Data()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "thumbnail.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status = request.url!.lastPathComponent == "missing" ? 404 : 200
        let data = request.url!.lastPathComponent == "corrupt" ? Data("invalid image".utf8) : Self.png
        precondition(request.value(forHTTPHeaderField: "Range") == nil, "small thumbnails use one request each")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "image/png", "Content-Length": String(data.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct FolderThumbnailTests {
    @MainActor static func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<400 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        preconditionFailure("Thumbnail fixture timed out")
    }

    static func url(_ name: String) -> URL { URL(string: "https://thumbnail.invalid/\(name)")! }

    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let gate = ThumbnailGate(), a = url("a"), b = url("b"), c = url("c")
        let cache = ThumbnailCache(concurrency: 2, load: gate.load)
        let first = Task { _ = try await cache.image(at: a, proxyURL: "", priority: .prefetch) }
        let second = Task {
            let image = try await cache.image(at: a, proxyURL: "")
            precondition(image === gate.image)
        }
        try await wait { gate.starts.count == 1 }
        first.cancel()
        do { _ = try await first.value; preconditionFailure("Cancelled consumer must return") } catch is CancellationError {}
        precondition(gate.pending.count == 1, "one consumer cannot cancel another's image")
        gate.finish(a)
        try await second.value
        _ = try await cache.image(at: a, proxyURL: "")
        precondition(gate.starts.count == 1, "grid and preview share the decoded cache")
        let proxy = Task { _ = try await cache.image(at: a, proxyURL: " http://localhost:8888 ") }
        try await wait { gate.starts.count == 2 }
        precondition(gate.starts.last?.1 == "http://localhost:8888", "proxy routes have independent cache keys")
        gate.finish(a); _ = try await proxy.value
        print("PASS thumbnail cache: shared in-flight requests, consumer cancellation, cached reuse, proxy isolation")

        let cancelled = Task { _ = try await cache.image(at: b, proxyURL: "", priority: .prefetch) }
        let visible = Task { _ = try await cache.image(at: c, proxyURL: "") }
        try await wait { gate.pending.count == 2 }
        cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure() } catch is CancellationError {}
        let next = Task { _ = try await cache.image(at: b, proxyURL: "") }
        try await Task.sleep(nanoseconds: 30_000_000)
        precondition(gate.starts.filter { $0.0 == b }.count == 1, "cancelled transport retains its slot until stopped")
        gate.finish(b)
        try await wait { gate.starts.filter { $0.0 == b }.count == 2 }
        gate.finish(b); gate.finish(c)
        _ = try await next.value; _ = try await visible.value
        print("PASS cancellation races: old completion cannot satisfy a new request or exceed concurrency")

        let priorityGate = ThumbnailGate()
        let priorityCache = ThumbnailCache(concurrency: 4, load: priorityGate.load)
        let backgrounds = (0..<5).map { index in Task { _ = try await priorityCache.image(at: url("bg\(index)"), proxyURL: "", priority: .prefetch) } }
        try await wait { priorityGate.pending.count == 2 }
        let foregrounds = (0..<2).map { index in Task { _ = try await priorityCache.image(at: url("fg\(index)"), proxyURL: "") } }
        try await wait { priorityGate.pending.count == 4 }
        precondition(priorityGate.starts.filter { $0.0.lastPathComponent.hasPrefix("fg") }.count == 2)
        for task in backgrounds + foregrounds { task.cancel() }
        for task in backgrounds + foregrounds { _ = try? await task.value }
        for pending in Array(priorityGate.pending.keys) { priorityGate.finish(pending) }
        print("PASS priority: reserved foreground slots, bounded parallel prefetch, queued work cancellation")

        var memoryLoads = 0
        let oneImageCache = ThumbnailCache(memoryLimit: 32 * 32 * 4, load: { _, _ in
            memoryLoads += 1; return ThumbnailTestImages.make()
        })
        _ = try await oneImageCache.image(at: a, proxyURL: "")
        _ = try await oneImageCache.image(at: b, proxyURL: "")
        _ = try await oneImageCache.image(at: b, proxyURL: "")
        _ = try await oneImageCache.image(at: a, proxyURL: "")
        precondition(memoryLoads == 3, "decoded images obey the memory budget")
        var failures = 0
        let failedCache = ThumbnailCache(load: { _, _ in failures += 1; throw URLError(.badServerResponse) })
        for _ in 0..<3 { _ = try? await failedCache.image(at: a, proxyURL: "") }
        precondition(failures == 1, "unavailable thumbnails must not cause a request storm")
        print("PASS limits: decoded-image eviction and failed-thumbnail cooldown")

        var pages: [String] = [], loaded: [URL] = []
        let pagingCache = ThumbnailCache(load: { url, _ in loaded.append(url); return ThumbnailTestImages.make() })
        let prefetch = FolderThumbnailPrefetcher(cache: pagingCache)
        let context = FolderThumbnailPrefetcher.Context(source: "share:first", folderID: "folder", proxyURL: "")
        prefetch.start(context: context, urls: [a, a], nextPageToken: "next") { token in
            pages.append(token)
            return .init(urls: [a, b, c], nextPageToken: "next")
        }
        try await wait { !prefetch.isRunning }
        precondition(Set(loaded) == Set([a, b, c]) && loaded.count == 3 && pages == ["next"])
        prefetch.start(context: context, urls: [a], nextPageToken: "next") { _ in preconditionFailure() }
        precondition(!prefetch.isRunning, "another file in the same folder does not repeat the sweep")
        print("PASS folder pages: all thumbnails, duplicate URLs, repeated page-token protection, same-folder reuse")

        var latePage: CheckedContinuation<FolderThumbnailPrefetcher.Page, Error>?
        prefetch.cancel()
        prefetch.start(context: context, urls: [], nextPageToken: "slow") { _ in
            try await withCheckedThrowingContinuation { latePage = $0 }
        }
        try await wait { latePage != nil }
        prefetch.start(context: .init(source: "share:second", folderID: "folder", proxyURL: ""),
                       urls: [url("new-link")], nextPageToken: nil) { _ in preconditionFailure() }
        latePage!.resume(returning: .init(urls: [url("stale-link")], nextPageToken: nil))
        try await wait { !prefetch.isRunning }
        precondition(loaded.contains(url("new-link")) && !loaded.contains(url("stale-link")))
        print("PASS workspace switch: late folder-page results cannot start stale downloads")

        let configuration = ThumbnailTransport.configuration(proxyURL: "")
        precondition(configuration.httpMaximumConnectionsPerHost == 8)
        precondition(configuration.connectionProxyDictionary?.isEmpty == true && !configuration.httpShouldSetCookies)
        precondition(configuration.timeoutIntervalForResource == 30)
        let png = FileManager.default.temporaryDirectory.appendingPathComponent("thumbnail-test-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: png) }
        let rep = NSBitmapImageRep(data: ThumbnailTestImages.make(side: 1_024).tiffRepresentation!)!
        try rep.representation(using: .png, properties: [:])!.write(to: png)
        let bitmap = try ImagePreviewTransport.decodeBitmap(png, maximumPixelSize: 512)
        precondition(bitmap.width == 512 && bitmap.height == 512)
        do { _ = try await ThumbnailTransport.load(URL(string: "http://thumbnail.invalid/insecure")!, proxyURL: ""); preconditionFailure() }
        catch let error as URLError { precondition(error.code == .unsupportedURL) }
        ThumbnailProtocolFixture.png = try Data(contentsOf: png)
        let networkConfiguration = ThumbnailTransport.configuration(proxyURL: "")
        networkConfiguration.protocolClasses = [ThumbnailProtocolFixture.self]
        let session = URLSession(configuration: networkConfiguration)
        defer { session.invalidateAndCancel() }
        let downloaded = try await ThumbnailTransport.load(url("success"), using: session)
        precondition(downloaded.size.width == 512 && downloaded.size.height == 512)
        do { _ = try await ThumbnailTransport.load(url("missing"), using: session); preconditionFailure() }
        catch let error as URLError { precondition(error.code == .badServerResponse) }
        do { _ = try await ThumbnailTransport.load(url("corrupt"), using: session); preconditionFailure() }
        catch { precondition((error as NSError).domain == "ImagePreview") }
        print("PASS transport: eight pooled connections, explicit direct routing, timeouts, bounded decoding, HTTPS")

        let suite = "com.wky.ThumbnailTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try await DownloaderModel.testFolderThumbnailSelection(defaults: defaults)
        DownloaderModel.testSharedSelection(defaults: defaults)

        for concurrency in [1, 8] {
            var active = 0, maximum = 0
            let benchmarkCache = ThumbnailCache(concurrency: concurrency, load: { _, _ in
                active += 1; maximum = max(maximum, active)
                defer { active -= 1 }
                try await Task.sleep(nanoseconds: 60_000_000)
                return ThumbnailTestImages.make()
            })
            let folder = FolderThumbnailPrefetcher(cache: benchmarkCache)
            let start = Date()
            folder.start(context: context, urls: (0..<24).map { url("benchmark\($0)") }, nextPageToken: nil) { _ in preconditionFailure() }
            try await wait { !folder.isRunning }
            print(String(format: "BENCH simulated 60ms thumbnails: concurrency %d, peak %d, 24 thumbnails %.3fs", concurrency, maximum, Date().timeIntervalSince(start)))
            precondition(maximum == benchmarkCache.prefetchConcurrency)
        }
        print("All folder-thumbnail tests passed; no credentials or external network used.")
    }
}
