import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct BrowserDragDropTests {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    @MainActor
    static func main() async throws {
        require(BrowserDropPayload.classify(hasCloudItems: true, hasFileURLs: true) == .move,
                "an internal file promise must never be downloaded back into an upload")
        require(BrowserDropPayload.classify(hasCloudItems: false, hasFileURLs: true) == .upload, "Finder copy")
        require(BrowserDropPayload.classify(hasCloudItems: false, hasFileURLs: false) == nil, "reject unrelated pasteboard types")

        let root = BrowserLocation.root
        let a = BrowserLocation(id: "A", name: "Folder A", path: "/Folder A")
        let sub = BrowserLocation(id: "Sub", name: "Nested", path: "/Folder A/Nested")
        let b = BrowserLocation(id: "B", name: "Folder B", path: "/Folder B")
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
        var zones = [
            "A": BrowserDropZone(id: "A", destination: a, isFolder: true, frame: CGRect(x: 0, y: 0, width: 600, height: 30), cornerRadius: 5),
            "Sub": BrowserDropZone(id: "Sub", destination: sub, isFolder: true, frame: CGRect(x: 0, y: 30, width: 600, height: 30), cornerRadius: 5),
            "File": BrowserDropZone(id: "File", destination: sub, isFolder: false, frame: CGRect(x: 0, y: 60, width: 600, height: 30), cornerRadius: 5),
            "B": BrowserDropZone(id: "B", destination: b, isFolder: true, frame: CGRect(x: 0, y: 90, width: 600, height: 30), cornerRadius: 5),
            "Unknown": BrowserDropZone(id: "Unknown", destination: nil, isFolder: false, frame: CGRect(x: 0, y: 120, width: 600, height: 30), cornerRadius: 5),
        ]
        func target(_ x: CGFloat, _ y: CGFloat) -> BrowserDropTarget? {
            BrowserDropTargetResolver.resolve(at: CGPoint(x: x, y: y), zones: zones, bounds: bounds, current: root)
        }
        require(target(20, 15)?.destination == a, "folder name target")
        require(target(590, 15)?.destination == a, "whole row, including metadata columns, targets the same folder")
        require(target(590, 45)?.destination == sub, "expanded nested folder target")
        require(target(20, 75)?.destination == sub && target(20, 75)?.highlightFrame == zones["Sub"]?.frame,
                "a file row accepts into and highlights its actual parent, not the browser root")
        require(target(20, 105)?.destination == b, "adjacent folder target")
        require(target(20, 140)?.destination == nil, "unknown parent never falls through into another folder")
        require(target(20, 250)?.destination == root && target(20, 250)?.highlightFrame == nil, "blank area means current folder")
        require(target(-1, 10) == nil && target(20, 401) == nil, "outside the viewport is not a drop target")

        let coordinator = BrowserDropCoordinator()
        coordinator.setGeometry(zones: zones, bounds: bounds)
        var expanded: [String] = []
        _ = coordinator.update(point: CGPoint(x: 300, y: 45), current: root, payload: .upload, count: 3,
                               validate: { _, _ in nil }, expand: { expanded.append($0) })
        require(coordinator.hover?.target.destination == sub && coordinator.hover?.count == 3, "hover matches hit test and count")
        try await Task.sleep(nanoseconds: 950_000_000)
        require(expanded == ["Sub"], "hover spring-expands a folder once without navigating away")
        // Simulate scrolling while the pointer remains still; the new geometry
        // must update both the destination and the highlight before mouse-up.
        zones = zones.mapValues { zone in
            BrowserDropZone(id: zone.id, destination: zone.destination, isFolder: zone.isFolder,
                            frame: zone.frame.offsetBy(dx: -30, dy: -60), cornerRadius: zone.cornerRadius)
        }
        coordinator.setGeometry(zones: zones, bounds: bounds)
        require(coordinator.hover?.target.destination == b, "stationary pointer re-targets after scrolling")
        require(coordinator.hover?.target.highlightFrame == CGRect(x: 0, y: 30, width: 570, height: 30), "highlight clipped to viewport")
        let offscreenParent = BrowserDropTargetResolver.resolve(at: CGPoint(x: 20, y: 15), zones: zones, bounds: bounds, current: root)
        require(offscreenParent?.destination == sub && offscreenParent?.highlightFrame == nil,
                "off-screen parent uses canvas feedback, never infinite CGRect.null coordinates")
        coordinator.clear()
        try await Task.sleep(nanoseconds: 950_000_000)
        require(coordinator.hover == nil && expanded == ["Sub"], "exit/Escape cancels pending spring loading and feedback")
        require(!coordinator.isTracking && !coordinator.geometryIsReady && coordinator.zones.isEmpty,
                "idle scrolling must not retain active drop geometry")
        coordinator.beginTracking()
        let pending = coordinator.update(point: CGPoint(x: 300, y: 40), current: root, payload: .move, count: 1,
                                         validate: { _, _ in nil }, expand: nil)
        require(pending == nil, "a drop before fresh geometry arrives must not fall through to the root")
        coordinator.setGeometry(zones: zones, bounds: bounds)
        require(coordinator.hover?.target.destination == b, "the first geometry update resolves the actual row under the pointer")
        let rejected = coordinator.update(point: CGPoint(x: 300, y: 40), current: root, payload: .move, count: 1,
                                          validate: { _, _ in "Cannot move into itself" }, expand: { expanded.append($0) })
        require(rejected?.isAllowed == false && rejected?.target.destination == b, "rejection keeps the actual target")
        try await Task.sleep(nanoseconds: 900_000_000)
        require(expanded == ["Sub"], "invalid targets do not spring-open")
        coordinator.clear()
        let tileZones = ["tile": BrowserDropZone(id: "tile", destination: b, isFolder: true,
                                                frame: CGRect(x: 230, y: 100, width: 180, height: 210), cornerRadius: 12)]
        coordinator.setGeometry(zones: tileZones, bounds: bounds)
        let tile = coordinator.update(point: CGPoint(x: 300, y: 220), current: a, payload: .upload, count: 2,
                                      validate: { _, _ in nil }, expand: nil)
        require(tile?.target.destination == b && tile?.target.cornerRadius == 12, "thumbnail target and geometry")
        let blank = coordinator.update(point: CGPoint(x: 20, y: 220), current: a, payload: .upload, count: 2,
                                       validate: { _, _ in nil }, expand: nil)
        require(blank?.target.destination == a, "thumbnail gaps mean current folder")
        coordinator.clear()
        print("PASS targets: full rows, nested/file parents, blank space, thumbnails, clipping, scrolling, spring loading, cancellation, rejection, cloud-priority payloads")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pikpak-drop-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("Folder 報告", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let child = folder.appendingPathComponent("résumé 1.txt")
        let sibling = directory.appendingPathComponent("two.txt")
        try Data("fixture one".utf8).write(to: child)
        try Data("fixture two".utf8).write(to: sibling)
        let roots = try LocalUploadFileURLLoader.validatedRoots([child, sibling, folder, sibling])
        require(roots == [sibling, folder], "preserve order; selecting a folder and child uploads the child only once")
        do {
            _ = try LocalUploadFileURLLoader.validatedRoots([child, directory.appendingPathComponent("missing.txt")])
            preconditionFailure("missing item must fail the whole drop")
        } catch { }
        do {
            _ = try LocalUploadFileURLLoader.validatedRoots([child, URL(string: "https://example.invalid/file.txt")!])
            preconditionFailure("a web URL is not a Finder source")
        } catch { }
        func provider(_ url: URL?, delay: Double) -> NSItemProvider {
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { complete in
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                    if let url { complete(url.dataRepresentation, nil) }
                    else { complete(nil, NSError(domain: "OfflineFinderFixture", code: 17, userInfo: [NSLocalizedDescriptionKey: "Fixture unreadable item"])) }
                }
                return nil
            }
            return provider
        }
        func load(_ providers: [NSItemProvider]) async -> Result<[URL], Error> {
            await withCheckedContinuation { continuation in
                LocalUploadFileURLLoader.loadResult(providers) { result in
                    require(Thread.isMainThread, "drop callbacks run on main")
                    continuation.resume(returning: result)
                }
            }
        }
        let ordered = try await load([provider(child, delay: 0.15), provider(sibling, delay: 0.01), provider(folder, delay: 0.05)]).get()
        require(ordered == [child, sibling, folder], "provider completion order must not reorder the selection")
        switch await load([provider(child, delay: 0.01), provider(nil, delay: 0.02)]) {
        case .success: preconditionFailure("one broken provider must not silently upload the remainder")
        case .failure: break
        }
        switch await load([]) {
        case .success: preconditionFailure("empty drop")
        case .failure: break
        }
        let native = try await load([NSItemProvider(object: child as NSURL)]).get()
        require(native == [child], "native NSURL provider")
        let serialized = try await load([
            NSItemProvider(item: sibling.absoluteString as NSString, typeIdentifier: UTType.fileURL.identifier),
            NSItemProvider(item: child.dataRepresentation as NSData, typeIdentifier: UTType.fileURL.identifier)
        ]).get()
        require(serialized == [sibling, child], "serialized NSString/Data file providers")
        let permissionProbe = DropPermissionProbe(url: sibling)
        let permitted: Result<[URL], Error> = await withCheckedContinuation { continuation in
            permissionProbe.releaseIsActive = true
            LocalUploadFileURLLoader.loadResult([permissionProbe]) { continuation.resume(returning: $0) }
            permissionProbe.releaseIsActive = false
            require(permissionProbe.earlyReads == 2 && permissionProbe.lateReads == 0,
                    "all supported reads must start before the release permission window closes")
        }
        let permittedURLs = try permitted.get()
        require(permittedURLs == [sibling] && permissionProbe.lateReads == 0,
                "a delayed primary error must not postpone the successful typed read until after release")
        require(FileManager.default.fileExists(atPath: child.path), "Finder uploads copy, never remove local originals")
        print("PASS Finder providers: native NSURL, async ordering, Unicode paths, atomic failure, root deduplication, local originals retained")

        // Exercise the actual delegate's hover -> layout -> release boundary.
        // No extra pointer update occurs after geometry becomes available.
        let dropModel = DownloaderModel.browserDropUIFixture()
        let dropCoordinator = BrowserDropCoordinator()
        var openedUploads = 0
        let receiver = BrowserDropDelegate(model: dropModel, current: root, coordinator: dropCoordinator,
            springLoadsFolders: false, onUploadStarted: { openedUploads += 1 })
        let point = CGPoint(x: 300, y: 20)
        let destination = BrowserLocation(id: "Folder B", name: "Folder B", path: "/Folder B")
        let destinationZones = [destination.id: BrowserDropZone(id: destination.id, destination: destination,
            isFolder: true, frame: CGRect(x: 0, y: 0, width: 600, height: 40), cornerRadius: 5)]
        require(receiver.proposal(at: point, payload: .upload).operation == .copy,
                "the first update must keep Finder's offer alive while layout is pending")
        require(dropCoordinator.hover == nil && !dropCoordinator.geometryIsReady,
                "pending geometry must not invent a root destination")
        dropCoordinator.setGeometry(zones: destinationZones, bounds: bounds)
        require(dropCoordinator.hover?.isAllowed == true && dropCoordinator.hover?.count == 0,
                "hover can become ready without fetching providers or another pointer event")
        var providerReads = 0
        require(receiver.receive(at: point, payload: .upload) { payload in
            providerReads += 1
            require(payload == .upload && dropCoordinator.geometryIsReady && dropCoordinator.isTracking,
                    "capture providers synchronously on release before clearing the receiver")
            return [provider(sibling, delay: 0.05)]
        }, "release accepts the resolved destination after delayed layout")
        require(providerReads == 1 && openedUploads == 0 && dropModel.status.contains("Preparing 1 dropped item"),
                "release immediately reports preparation while Finder supplies its URLs")
        require(!dropCoordinator.isTracking && dropCoordinator.hover == nil, "release clears feedback")
        dropModel.setUploadDestination(BrowserLocation(id: "Folder A", name: "Folder A", path: "/Folder A"))
        for _ in 0..<100 where openedUploads == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        require(openedUploads == 1 && dropModel.status == "TEST upload accepted: 1 item(s) to /Folder B",
                "async completion opens Uploads once and preserves the release destination after another destination is chosen")

        _ = receiver.proposal(at: point, payload: .upload)
        require(!receiver.receive(at: point, payload: .upload) { _ in
            preconditionFailure("unresolved geometry must not read providers or upload to root")
        }, "release before any layout is rejected")
        require(dropModel.statusIsError && dropModel.status.contains("destination is not ready"),
                "an unresolved destination reports a visible error, never a silent no-op")
        _ = receiver.proposal(at: point, payload: .upload)
        dropCoordinator.setGeometry(zones: destinationZones, bounds: bounds)
        require(!receiver.receive(at: point, payload: .upload) { _ in [] }, "empty provider list is rejected")
        require(dropModel.statusIsError && dropModel.status.contains("Finder did not supply"),
                "an empty release reports why nothing started")
        _ = receiver.proposal(at: point, payload: .upload)
        dropCoordinator.setGeometry(zones: destinationZones, bounds: bounds)
        dropModel.isRunning = true
        require(receiver.proposal(at: point, payload: .upload).operation == .cancel, "known rejected targets stay rejected")
        require(!receiver.receive(at: point, payload: .upload) { _ in
            preconditionFailure("an unavailable upload must not consume providers")
        }, "revalidate availability at release")
        require(dropModel.statusIsError && openedUploads == 1, "a rejected drop cannot switch tabs or start another upload")
        require(receiver.proposal(at: point, payload: nil).operation == .cancel, "unrelated drag is rejected")
        require(receiver.proposal(at: point, payload: .move).operation == .move, "an internal move stays a move while layout is pending")
        dropCoordinator.clear()
        print("PASS release handoff: pending geometry, stationary pointer, synchronous provider capture, visible preparation/errors, destination capture, one tab switch and rejected offers")
        DownloaderModel.testBrowserDropModel(localFiles: [sibling, folder])
        print("All Browser drag-and-drop tests passed (no cloud operations).")
    }
}

/// Models a cross-process provider that needs typed NSURL loading and only
/// permits a read to begin while the drop callback is on the stack.
private final class DropPermissionProbe: NSItemProvider, @unchecked Sendable {
    let url: URL
    var releaseIsActive = false
    var earlyReads = 0
    var lateReads = 0

    init(url: URL) { self.url = url; super.init() }
    required init?(coder: NSCoder) { fatalError("Not used") }
    override func canLoadObject(ofClass aClass: NSItemProviderReading.Type) -> Bool { true }

    override func loadItem(forTypeIdentifier typeIdentifier: String, options: [AnyHashable: Any]? = nil,
                           completionHandler: NSItemProvider.CompletionHandler? = nil) {
        if releaseIsActive { earlyReads += 1 } else { lateReads += 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            completionHandler?(nil, NSError(domain: "OfflineDropFixture", code: 1))
        }
    }

    override func loadObject(ofClass aClass: NSItemProviderReading.Type,
                             completionHandler: @escaping @Sendable (NSItemProviderReading?, Error?) -> Void) -> Progress {
        let allowed = releaseIsActive
        if allowed { earlyReads += 1 } else { lateReads += 1 }
        let url = self.url
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            completionHandler(allowed ? url as NSURL : nil,
                              allowed ? nil : NSError(domain: "OfflineDropFixture", code: 2))
        }
        return Progress(totalUnitCount: 1)
    }
}
