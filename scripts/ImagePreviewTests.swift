import AppKit
import Combine
import Foundation

@MainActor
private final class ImageLoaderFixture {
    struct Pending {
        let url: URL
        let continuation: CheckedContinuation<NSImage, Error>
    }
    var pending: [Pending] = []
    var count = 0
    func load(_ url: URL, _ proxy: String) async throws -> NSImage {
        count += 1
        // Deliberately ignores cancellation until resolved. This tests that
        // late callbacks cannot repaint the wrong selection or quality.
        return try await withCheckedThrowingContinuation { pending.append(Pending(url: url, continuation: $0)) }
    }
    func resolve(_ url: URL, _ result: Result<NSImage, Error>) {
        let index = pending.firstIndex { $0.url == url }!
        pending.remove(at: index).continuation.resume(with: result)
    }
}

@main
struct ImagePreviewTests {
    @MainActor
    static func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        preconditionFailure("Image preview fixture timed out")
    }

    @MainActor
    static func main() async throws {
        let thumb = URL(string: "https://example.invalid/thumbnail")!
        let full = URL(string: "https://example.invalid/original")!
        let fresh = URL(string: "https://example.invalid/refreshed-original")!
        let low = NSImage(size: NSSize(width: 80, height: 40))
        let high = NSImage(size: NSSize(width: 800, height: 400))
        let newest = NSImage(size: NSSize(width: 1600, height: 800))
        let failure = NSError(domain: NSURLErrorDomain, code: -1200,
                              userInfo: [NSLocalizedDescriptionKey: "Fixture TLS error"])
        func request(_ id: String = "A", thumbnail: URL? = thumb, original: URL? = nil, generation: UUID = UUID()) -> ImagePreviewRequest {
            ImagePreviewRequest(fileID: id, thumbnailURL: thumbnail, contentURL: original, generation: generation, proxyURL: "")
        }

        let fixture = ImageLoaderFixture()
        let model = ImagePreviewModel(load: fixture.load)
        var displayed: [ImagePreviewModel.Frame?] = []
        let observation = model.$frame.sink { displayed.append($0) }
        var failures: [NSError] = []
        let generation = UUID()
        model.update(request(generation: generation))
        try await waitUntil { fixture.pending.count == 1 }
        fixture.resolve(thumb, .success(low))
        try await waitUntil { model.frame?.image === low }
        let firstVisible = displayed.count - 1

        model.reset(unlessFileID: "A")
        precondition(model.frame?.image === low, "automatic metadata request must retain the thumbnail")
        let originalRequest = request(original: full, generation: generation)
        model.update(originalRequest) { failures.append($0 as NSError) }
        model.update(originalRequest) // Layout changes/re-rendering must not re-download.
        try await waitUntil { fixture.pending.count == 1 }
        precondition(model.frame?.image === low && model.isLoading && fixture.count == 2)
        fixture.resolve(full, .failure(failure))
        try await waitUntil { !model.isLoading }
        precondition(model.frame?.image === low && failures.first?.code == -1200)

        model.update(request(original: full))
        try await waitUntil { fixture.pending.count == 1 }
        precondition(model.frame?.image === low, "retry cannot flash a placeholder")
        fixture.resolve(full, .success(high))
        try await waitUntil { model.frame?.image === high }
        precondition(model.frame?.quality == .original && model.error == nil)
        model.update(request()) // Metadata cleared while Reload Preview fetches a new signed URL.
        precondition(model.frame?.image === high, "keep original while metadata reloads")
        model.update(request(original: fresh))
        try await waitUntil { fixture.pending.count == 1 }
        fixture.resolve(fresh, .failure(failure))
        try await waitUntil { !model.isLoading }
        precondition(model.frame?.image === high, "failed refresh must not downgrade to thumbnail")
        precondition(displayed.dropFirst(firstVisible).allSatisfy { $0 != nil }, "no intermediate empty frame after the thumbnail appears")
        model.reset()
        precondition(model.frame == nil && model.request == nil && !model.isLoading)
        observation.cancel()
        print("PASS: thumbnail retained during API/full-image loading, no second empty frame, retries, errors, stable re-rendering, explicit reset")

        let raceFixture = ImageLoaderFixture()
        let race = ImagePreviewModel(load: raceFixture.load)
        race.update(request(original: full))
        try await waitUntil { raceFixture.pending.count == 2 }
        raceFixture.resolve(full, .success(high))
        try await waitUntil { race.frame?.image === high }
        raceFixture.resolve(thumb, .success(low))
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(race.frame?.image === high && race.frame?.quality == .original, "late thumbnail cannot replace original")

        race.update(request(original: full))
        try await waitUntil { raceFixture.pending.count == 1 }
        race.update(request(original: fresh))
        try await waitUntil { raceFixture.pending.count == 2 }
        raceFixture.resolve(fresh, .success(newest))
        try await waitUntil { race.frame?.image === newest }
        raceFixture.resolve(full, .success(high))
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(race.frame?.image === newest, "old signed URL completion cannot overwrite newer image")

        race.update(request(original: full))
        try await waitUntil { raceFixture.pending.count == 1 }
        race.update(request("B", thumbnail: nil, original: full))
        precondition(race.frame == nil, "a different file must clear the previous image immediately")
        try await waitUntil { raceFixture.pending.count == 2 }
        raceFixture.resolve(full, .success(high)) // stale A (same URL as B)
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(race.frame == nil, "cancelled file A cannot flash into file B")
        raceFixture.resolve(full, .success(newest))
        try await waitUntil { race.frame?.fileID == "B" }
        precondition(race.frame?.image === newest)
        race.reset(unlessFileID: "A")
        precondition(race.frame == nil, "retention is scoped to the selected file")
        print("PASS: late thumbnail/original suppression, signed-URL refresh races, rapid selection changes, no previous-file leakage")

        let sameFixture = ImageLoaderFixture()
        let same = ImagePreviewModel(load: sameFixture.load)
        same.update(request(thumbnail: full, original: full))
        try await waitUntil { sameFixture.pending.count == 1 }
        precondition(sameFixture.count == 1, "identical thumbnail/original URLs need one request")
        sameFixture.resolve(full, .success(high))
        try await waitUntil { same.frame?.quality == .original }
        same.update(request(thumbnail: fresh, original: full, generation: same.request!.generation))
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(sameFixture.pending.isEmpty && same.frame?.image === high, "thumbnail metadata updates cannot downgrade original")
        same.reset()

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pikpak-image-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func png(width: Int, height: Int, name: String) throws -> URL {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32)!
            bitmap.bitmapData!.initialize(repeating: 0, count: width * height * 4)
            bitmap.setColor(NSColor(deviceRed: 0, green: 0.4, blue: 1, alpha: 1), atX: 0, y: 0)
            let file = directory.appendingPathComponent(name)
            try bitmap.representation(using: .png, properties: [:])!.write(to: file)
            return file
        }
        let decoded = try ImagePreviewTransport.decode(png(width: 8, height: 4, name: "alpha.png"))
        precondition(decoded.size == NSSize(width: 8, height: 4))
        let large = try ImagePreviewTransport.decode(png(width: 10_000, height: 2, name: "wide.png"))
        precondition(large.size.width <= 8192, "bound decompressed preview memory")
        let invalid = directory.appendingPathComponent("not-an-image.png")
        try Data("corrupt fixture".utf8).write(to: invalid)
        do { _ = try ImagePreviewTransport.decode(invalid); preconditionFailure("corrupt image must fail") }
        catch { precondition((error as NSError).domain == "ImagePreview") }
        do { _ = try await ImagePreviewTransport.load(URL(string: "http://example.invalid/image")!, proxyURL: ""); preconditionFailure("insecure source must fail before networking") }
        catch { precondition((error as NSError).code == 1) }
        print("PASS: identical URL deduplication, bitmap decoding, alpha PNG, oversized image bounds, corrupt-image diagnostics, HTTPS-only sources")
        print("All image-preview tests passed; no account or network accessed.")
    }
}
