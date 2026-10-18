import AppKit
import Foundation

/// Captured-provider reveal uses generated metadata only, including Photos.
private final class RevealFixtureDrive: NativeCloudDrive, @unchecked Sendable {
    let kind: CloudDriveKind
    let root: CloudDriveLocation
    let items: [CloudDriveItem]
    private(set) var undoCalls = 0
    private(set) var materializeCalls = 0
    init(kind: CloudDriveKind, rootURL: URL?, id: String) {
        self.kind = kind
        root = .init(id: rootURL?.absoluteString ?? "generated-photos-library", title: "Generated", url: rootURL)
        items = [.init(id: id, name: "generated.txt", isFolder: false, bytes: 100,
            url: rootURL?.appendingPathComponent("generated.txt"), revision: "generated-revision")]
    }
    func list(_ location: CloudDriveLocation, offset: Int, search: String) async throws -> CloudDrivePage { .init(items: items, total: items.count) }
    func scanItems(_ selected: [CloudDriveItem], location: CloudDriveLocation, progress: @escaping CloudDriveProgressHandler) async throws -> [CloudDriveItem] { items }
    func materialize(_ item: CloudDriveItem, directory: URL, progress: @escaping CloudDriveProgressHandler) async throws -> URL {
        materializeCalls += 1; throw CocoaError(.featureUnsupported)
    }
    func undo() -> CloudDriveUndo {
        .init(title: "Generated Undo") { self.undoCalls += 1; return self.undo() }
    }
    func createContainer(_ name: String, in location: CloudDriveLocation) async throws -> CloudDriveUndo? { throw CocoaError(.featureUnsupported) }
    func rename(_ item: CloudDriveItem, to name: String) async throws -> CloudDriveUndo? { throw CocoaError(.featureUnsupported) }
    func relocate(_ items: [CloudDriveItem], from: CloudDriveLocation, to: CloudDriveLocation, copy: Bool, progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? { throw CocoaError(.featureUnsupported) }
    func importFiles(_ urls: [URL], into location: CloudDriveLocation, progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? { throw CocoaError(.featureUnsupported) }
    func delete(_ items: [CloudDriveItem], progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? { throw CocoaError(.featureUnsupported) }
}

private actor RevealFixtureGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

@main struct SimilarityAcrossDriveRevealTests {
    @MainActor static func until(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(condition(), "Generated captured-provider reveal timed out")
    }
    static func file(_ item: CloudDriveItem) -> SimilarityFile {
        .init(id: item.id, name: item.name, path: item.url?.path ?? "/Generated Photos/" + item.name,
            bytes: item.bytes!, family: "text", localPath: item.url?.path, cloudId: nil, ancestors: [], nativeRevision: item.revision)
    }
    @MainActor static func main() async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited); setbuf(stdout, nil)
        let fm = FileManager.default, root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("AcrossReveal-\(UUID())")
        let browserURL = root.appendingPathComponent("browser"), scannedURL = root.appendingPathComponent("scanned")
        try fm.createDirectory(at: browserURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: scannedURL, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let photos = NativeDriveModel(kind: .photos), photoProvider = RevealFixtureDrive(kind: .photos, rootURL: nil, id: "generated-asset")
        defer { photos.close() }
        let photoItem = photoProvider.items[0], photo = file(photoItem)
        precondition(photos.similarity.local.results.index == nil)
        precondition(photos.revealSimilarityFile(photo, using: photoProvider, scannedItem: photoItem))
        try await until { photos.selectedItems.contains { $0.id == photo.id } }
        precondition(photos.location.id == "photos:all" && photoProvider.materializeCalls == 0,
                     "Photos reveal must use the captured original asset without a single-drive scan or content export")
        print("PASS captured Photos original reveals in its library without scan-map state or materialization")

        let browser = RevealFixtureDrive(kind: .local, rootURL: browserURL, id: "browser-item")
        let scanned = RevealFixtureDrive(kind: .local, rootURL: scannedURL, id: "scanned-item")
        let local = NativeDriveModel(kind: .local); defer { local.close() }
        local.connect(browser)
        local.run("Generated reversible operation", mutating: true) { _, _ in browser.undo() }
        try await until { !local.isBusy && local.undoStack.count == 1 }
        let scannedItem = scanned.items[0], original = file(scannedItem)
        precondition(local.revealSimilarityFile(original, using: scanned, scannedItem: scannedItem))
        try await until { local.selectedItems.contains { $0.id == original.id } }
        precondition(local.provider?.root == scanned.root && local.location.url == scanned.root.url
                     && local.undoStack.count == 1 && scanned.materializeCalls == 0)
        local.undo(); try await until { !local.isBusy }
        precondition(browser.undoCalls == 1, "Adopting a captured root must preserve the prior provider's Undo handle")
        let mismatchedItem = CloudDriveItem(id: "unreviewed-original", name: "generated.txt", isFolder: false, bytes: 100,
            url: scannedItem.url, revision: scannedItem.revision)
        precondition(!local.revealSimilarityFile(original, using: scanned, scannedItem: mismatchedItem))
        var changedSize = scannedItem; changedSize.bytes = 101
        precondition(!local.revealSimilarityFile(original, using: scanned, scannedItem: changedSize))
        var changedPath = scannedItem; changedPath.url = browserURL.appendingPathComponent("generated.txt")
        precondition(!local.revealSimilarityFile(original, using: scanned, scannedItem: changedPath))
        var changedRevision = scannedItem; changedRevision.revision = "different-revision"
        precondition(!local.revealSimilarityFile(original, using: scanned, scannedItem: changedRevision))
        precondition(local.provider?.root == scanned.root, "Invalid captured identity must not change Browser's provider")
        print("PASS outside-root Local reveal adopts its captured provider, preserves Undo and rejects mismatched original identity")

        let busy = NativeDriveModel(kind: .local); defer { busy.close() }
        busy.connect(browser)
        let gate = RevealFixtureGate()
        busy.run("Generated busy operation", mutating: true) { _, _ in await gate.wait(); return nil }
        precondition(busy.isBusy)
        precondition(!busy.revealSimilarityFile(original, using: scanned, scannedItem: scannedItem)
                     && busy.provider?.root == browser.root, "Busy work must prevent changing its captured Browser root")
        precondition(busy.revealSimilarityFile(file(browser.items[0]), using: browser, scannedItem: browser.items[0]),
                     "Browsing within the same provider root must remain available during unrelated work")
        await gate.release(); try await until { !busy.isBusy }
        busy.close()
        precondition(!busy.revealSimilarityFile(original, using: scanned, scannedItem: scannedItem))
        print("PASS busy provider changes and closed-owner reveals are rejected; same-root navigation remains available")

        let actualURL = browserURL.appendingPathComponent("existing-default.txt")
        try Data(repeating: 65, count: 100).write(to: actualURL)
        let ordinary = NativeDriveModel(kind: .local); defer { ordinary.close() }
        ordinary.connect(ICloudDriveProvider(rootURL: browserURL, kind: .local))
        let actual = try ICloudDriveProvider.item(actualURL)
        precondition(ordinary.revealSimilarityFile(file(actual)))
        try await until { ordinary.selectedItems.contains { $0.id == actual.id } }
        print("PASS existing Local reveal call remains compatible for a generated original")
    }
}
