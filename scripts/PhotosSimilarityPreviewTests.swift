import AppKit
import Darwin
import Foundation

@MainActor private final class PreviewFeed {
    var requested = 0
    var release = false
}

private final class PreviewDrive: NativeCloudDrive, @unchecked Sendable {
    let kind = CloudDriveKind.photos
    let root = CloudDriveLocation(id: "photos:root", title: "Generated Photos", isLibrary: true)
    let supportsSimilarityPreviews = true
    let jpeg: Data
    let feed: PreviewFeed
    init(_ jpeg: Data, feed: PreviewFeed) { self.jpeg = jpeg; self.feed = feed }
    func list(_ location: CloudDriveLocation, offset: Int, search: String) async throws -> CloudDrivePage {
        .init(items: (0..<8).map { index in
            .init(id: "asset:generated-\(index)", name: "original-\(index).\(index % 2 == 0 ? "heic" : "mov")",
                isFolder: false, bytes: index == 0 ? 250_000_000 : nil, modified: Date(timeIntervalSince1970: 1234),
                mediaType: index % 2 == 0 ? "image" : "video", canRename: false)
        }, total: 8)
    }
    func scanItems(_ items: [CloudDriveItem], location: CloudDriveLocation, progress: @escaping CloudDriveProgressHandler) async throws -> [CloudDriveItem] {
        try await list(location, offset: 0, search: "").items
    }
    func previewForSimilarity(_ item: CloudDriveItem, progress: @escaping CloudDriveProgressHandler) async throws -> Data {
        await MainActor.run { feed.requested += 1 }
        let index = Int(item.id.split(separator: "-").last!)!
        progress(.init(message: "Fetching preview from iCloud", fraction: Double(index + 1) / 10))
        while await !feed.release { try await Task.sleep(nanoseconds: 10_000_000) }
        return jpeg
    }
    func materialize(_ item: CloudDriveItem, directory: URL, progress: @escaping CloudDriveProgressHandler) async throws -> URL {
        preconditionFailure("Fast Previews must never request originals or export files")
    }
    func streamForSimilarity(_ item: CloudDriveItem, pipe: URL, capacity: UInt64, progress: @escaping CloudDriveProgressHandler) async throws -> URL {
        preconditionFailure("Fast Previews must never stream originals")
    }
    func createContainer(_ name: String, in location: CloudDriveLocation) async throws -> CloudDriveUndo? { throw CocoaError(.featureUnsupported) }
    func rename(_ item: CloudDriveItem, to name: String) async throws -> CloudDriveUndo? { throw CocoaError(.featureUnsupported) }
    func relocate(_ items: [CloudDriveItem], from: CloudDriveLocation, to: CloudDriveLocation, copy: Bool, progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? { throw CocoaError(.featureUnsupported) }
    func importFiles(_ urls: [URL], into: CloudDriveLocation, progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? { throw CocoaError(.featureUnsupported) }
    func delete(_ items: [CloudDriveItem], progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? { throw CocoaError(.featureUnsupported) }
}

@main struct PhotosSimilarityPreviewTests {
    @MainActor static func until(_ condition: () -> Bool, seconds: Double = 90, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        precondition(condition(), "Timed out at line \(line)")
    }
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let engine = URL(fileURLWithPath: CommandLine.arguments[2])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PhotosPreviewTests-\(UUID().uuidString)")
        try CloudDriveFiles.privateDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }

        let context = CGContext(data: nil, width: 2048, height: 1536, bitsPerComponent: 8, bytesPerRow: 2048 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 2048, height: 1536))
        context.setFillColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1); context.fillEllipse(in: CGRect(x: 400, y: 300, width: 600, height: 600))
        let jpeg = try PhotosSimilarityPreview.jpeg(NSImage(cgImage: context.makeImage()!, size: .zero))
        let bitmap = NSBitmapImageRep(data: jpeg)!
        precondition(bitmap.pixelsWide == 1024 && bitmap.pixelsHigh == 768 && jpeg.count < 1 << 20)
        print("PASS photo and video preview JPEGs have a bounded 1024-pixel edge and preserve aspect ratio")

        var overlays = SimilarityProviderProgress()
        let old = UUID(), new = UUID()
        overlays.begin(1, attempt: old); overlays.update(1, attempt: old, fraction: 0.8)
        overlays.begin(1, attempt: new); overlays.update(1, attempt: new, fraction: 0.2)
        overlays.update(1, attempt: old, fraction: 0.99); overlays.end(1, attempt: old)
        var rows = [SimilarityDownload(event: ["id": 1, "name": "generated", "state": "downloading"])!]
        overlays.apply(to: &rows, photos: true)
        precondition(rows[0].fraction == 0.2 && rows[0].status(age: 0, running: true) == "Fetching from iCloud")
        precondition(rows[0].byteLabel == "20% from iCloud" && rows[0].currentSpeed(age: 0, running: true) == 0)
        overlays.end(1, attempt: new); overlays.apply(to: &rows, photos: true)
        precondition(rows[0].status(age: 0, running: true) == "Waiting for Photos")
        let legacyRow = Data(#"{"id":1,"name":"generated","received":0,"total":0,"speed":0,"state":"downloading","attempt":1,"retrySeconds":0}"#.utf8)
        let decodedRow = try JSONDecoder().decode(SimilarityDownload.self, from: legacyRow)
        precondition(decodedRow.isPhotosRequest == nil)
        print("PASS progress distinguishes cloud preparation; late callbacks cannot overwrite a new attempt; old snapshots decode")

        let feed = PreviewFeed()
        let drive = PreviewDrive(jpeg, feed: feed)
        let model = NativeDriveModel(kind: .photos, temporaryRoot: root.appendingPathComponent("native"))
        let configuration = SimilarityConfiguration(executable: engine, models: resources.appendingPathComponent("FileTwinModels"),
            worker: resources.appendingPathComponent("filetwin-worker"), dataDirectory: root.appendingPathComponent("data"),
            temporaryDirectory: root.appendingPathComponent("temp"), environment: [:])
        model.scanConfiguration = { configuration }; model.connect(drive)
        try await until { !model.isLoading }
        model.findSimilar(presentWindow: false)
        let scan = model.similarity.local
        precondition(scan.usesPhotosPreviews && !scan.exactDuplicates)
        let sources = try await scan.inventoryExternalSources!()
        precondition(sources.count == 8 && sources.allSatisfy { $0.contentKind == PhotosSimilarityPreview.contentKind })
        precondition(sources[0].size == 250_000_000 && sources[1].size == 0)
        let legacyScope = SimilarityNativeScope(drive: .photos, providerRoot: drive.root, location: drive.root, selection: [])
        try model.similarity.restoreNativeScope!(legacyScope)
        precondition(!scan.usesPhotosPreviews, "A legacy saved scan must keep originals")
        model.findSimilar(presentWindow: false)
        precondition(scan.usesPhotosPreviews, "New Photos scans default to previews")
        model.similarity.start(scan)
        try await until { feed.requested == 8 && scan.progress.downloads.count == 8 && scan.progress.downloads.allSatisfy { $0.providerFraction != nil } }
        precondition(scan.progress.downloads.allSatisfy { $0.received == 0 && $0.total == 0 && $0.status(age: 0, running: true) == "Fetching from iCloud" })
        precondition(Set(scan.progress.downloads.compactMap(\.providerFraction)).count == 8)
        precondition(scan.savedSession?.nativeScope?.photosUsePreviews == true && !scan.savedSession!.exactDuplicates)
        scan.choosePhotosPreviews(false); precondition(scan.usesPhotosPreviews, "An active scan cannot change representations")
        feed.release = true
        try await until({ !scan.isRunning }, seconds: 180)
        precondition(!scan.isPaused && scan.error == nil, scan.error ?? scan.message)
        precondition(scan.report?.analysedFiles == 8 && scan.report?.failedFiles == 0, scan.report?.coverage ?? "Missing report")
        precondition(scan.report!.files!.allSatisfy { $0.name.hasPrefix("original-") && $0.id.hasPrefix("asset:") && $0.family == "image" })
        precondition(scan.report!.files!.first { $0.id == "asset:generated-0" }?.bytes == 250_000_000)
        precondition(scan.report!.files!.first { $0.id == "asset:generated-1" }?.bytes == 0)
        precondition(scan.report!.groups.allSatisfy { !$0.isExact })
        try await until { !scan.results.isIndexing && !scan.results.isGrouping }
        precondition(scan.results.groups.count == 1 && scan.results.groups[0].members.count == 8 && !scan.results.groups[0].identical)
        precondition(!scan.results.allowsSizeBasedCleanup && scan.results.keepSmallestPlan() == nil)
        scan.results.identicalOnly = true
        try await until { !scan.results.isGrouping }
        precondition(scan.results.groups.isEmpty, "Identical previews cannot prove identical originals")
        print("PASS eight concurrent photo/video previews use the real RAM pipeline, report per-file iCloud progress, and yield visual groups without original hashes")

        scan.clearSession(); model.findSimilar(presentWindow: false); model.similarity.start(scan)
        try await until({ !scan.isRunning }, seconds: 180)
        precondition(scan.report?.analysedFiles == 8 && scan.error == nil, scan.error ?? "Second scan failed")
        precondition(feed.requested == 8, "A second unchanged preview scan should reuse all vectors without requesting Photos again")
        precondition(scan.report!.files!.first { $0.id == "asset:generated-0" }?.bytes == 250_000_000)
        print("PASS unchanged preview vectors are reused while original sizes and asset identities stay intact")
        scan.clearSession(); model.close()
    }
}
