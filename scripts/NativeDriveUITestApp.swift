import AppKit
import SwiftUI
import Photos

@MainActor private final class DemoPhotosAccessState {
    var status = PHAuthorizationStatus.authorized
}

@MainActor private final class DemoICloudStorageState {
    var unavailable = false
    var delay: UInt64 = 200_000_000
}

private final class DemoPhotosDrive: NativeCloudDrive, @unchecked Sendable {
    let kind = CloudDriveKind.photos
    let root = CloudDriveLocation(id: "photos:root", title: "Apple Photos", isLibrary: true)
    let directory: URL
    init(directory: URL) { self.directory = directory }
    func list(_ location: CloudDriveLocation, offset: Int, search: String) async throws -> CloudDrivePage {
        if location.id == root.id && search.isEmpty {
            return .init(items: ["All Photos & Videos", "Summer", "Architecture", "Family"].enumerated().map {
                .init(id: "demo:album:\($0.offset)", name: $0.element, isFolder: true, canRename: $0.offset > 0, canDelete: $0.offset > 0)
            }, total: 4)
        }
        let items = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { ["png", "mp4"].contains($0.pathExtension) }.map { url in
            CloudDriveItem(id: "demo:" + url.lastPathComponent, name: url.lastPathComponent, isFolder: false, bytes: 1_245_082, modified: Date(), url: url, mediaType: url.pathExtension == "mp4" ? "video" : "image", canRename: false)
        }.filter { search.isEmpty || $0.name.localizedStandardContains(search) }
        return .init(items: items, total: items.count)
    }
    func scanItems(_ items: [CloudDriveItem], location: CloudDriveLocation, progress: @escaping CloudDriveProgressHandler) async throws -> [CloudDriveItem] { try await list(.init(id: "demo:all", title: "All Photos"), offset: 0, search: "").items }
    func materialize(_ item: CloudDriveItem, directory: URL, progress: @escaping CloudDriveProgressHandler) async throws -> URL {
        let folder = directory.appendingPathComponent(UUID().uuidString)
        try CloudDriveFiles.privateDirectory(folder)
        let result = folder.appendingPathComponent(item.name)
        try FileManager.default.copyItem(at: item.url!, to: result)
        return result
    }
    func createContainer(_ name: String, in location: CloudDriveLocation) async throws -> CloudDriveUndo? { throw CocoaError(.featureUnsupported) }
    func rename(_ item: CloudDriveItem, to name: String) async throws -> CloudDriveUndo? { throw CocoaError(.featureUnsupported) }
    func relocate(_ items: [CloudDriveItem], from: CloudDriveLocation, to: CloudDriveLocation, copy: Bool, progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? { throw CocoaError(.featureUnsupported) }
    func importFiles(_ urls: [URL], into: CloudDriveLocation, progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? { throw CocoaError(.featureUnsupported) }
    func delete(_ items: [CloudDriveItem], progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? { throw CocoaError(.featureUnsupported) }
}

@main @MainActor struct NativeDriveUITestApp: App {
    @StateObject private var sessions: WorkspaceSessionManager
    private var hub: CloudDriveHub { sessions.activeHub }
    @State private var dark = false
    @State private var stressMenuUpdates = false
    @State private var menuUpdateTicks = 0
    private let menuUpdateTimer = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()
    private let photosAccessState = DemoPhotosAccessState()
    private let storageState = DemoICloudStorageState()
    private let preferences: UserDefaults
    init() {
        let defaults = UserDefaults(suiteName: "com.wky.MyCloudDriver.DesignFixture.preferences")!
        preferences = defaults
        defaults.removePersistentDomain(forName: "com.wky.MyCloudDriver.DesignFixture.preferences")
        defaults.set(0, forKey: "browserViewMode")
        defaults.set(0, forKey: "selectedTransferMode")
        defaults.set(1.0, forKey: "browserListItemZoom")
        defaults.set(1.0, forKey: "browserThumbnailItemZoom")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MyCloudDriverDesignFixture", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let access = photosAccessState
        let storage = storageState
        let hub = CloudDriveHub(pikpak: DownloaderModel.finderWorkspaceFixture(defaults: defaults), defaults: defaults,
            restoreConnections: false, photosAccess: .init(status: { access.status }, request: {
                try? await Task.sleep(nanoseconds: 700_000_000)
                access.status = .authorized; return access.status
            }, provider: { DemoPhotosDrive(directory: directory) }), icloudStorage: ICloudStorageModel(fetch: {
                try await Task.sleep(nanoseconds: storage.delay)
                if storage.unavailable { throw ICloudStorageError.unavailable }
                return 37_500_000_000
            }), localRootURL: directory)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for folder in ["Documents/Drafts", "Projects", "Travel"] { try? FileManager.default.createDirectory(at: directory.appendingPathComponent(folder), withIntermediateDirectories: true) }
        for name in ["Documents/Drafts/Outline.txt", "Documents/Meeting notes.txt", "Documents/Project plan.txt"] {
            try! Data("Synthetic content for \(name).\n".utf8).write(to: directory.appendingPathComponent(name))
        }
        try! Data("A synthetic document for MyCloudDriver UI verification.\nPress Space for Quick Look.\n".utf8).write(to: directory.appendingPathComponent("Welcome.txt"))
        for (index, name) in ["Coast", "Desert", "Forest", "Mountains", "City", "Garden"].enumerated() {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 480, pixelsHigh: 320, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSColor(calibratedHue: CGFloat(index) / 7, saturation: 0.24, brightness: 0.96, alpha: 1).setFill()
            NSBezierPath(rect: .init(x: 0, y: 0, width: 480, height: 320)).fill()
            NSColor(calibratedHue: CGFloat(index) / 7, saturation: 0.50, brightness: 0.72, alpha: 1).setFill()
            let hill = NSBezierPath(); hill.move(to: .init(x: 0, y: 30)); hill.line(to: .init(x: 190, y: 235)); hill.line(to: .init(x: 480, y: 40)); hill.close(); hill.fill()
            NSColor.white.withAlphaComponent(0.7).setFill(); NSBezierPath(ovalIn: .init(x: 335, y: 215, width: 50, height: 50)).fill()
            NSGraphicsContext.restoreGraphicsState()
            try! bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("\(name).png"))
        }
        hub.icloud.connect(ICloudDriveProvider(rootURL: directory)); hub.photos.connect(DemoPhotosDrive(directory: directory))
        let activity = hub.icloud.activity.begin("Exporting project files", transferDirection: 0)
        hub.icloud.activity.update(activity, .init(message: "Copying Project overview.pdf", completed: 12, total: 28, fraction: 0.43))
        let imported = hub.icloud.activity.begin("Importing images", transferDirection: 1)
        hub.icloud.activity.update(imported, .init(message: "Uploaded 6 images", completed: 6, total: 6))
        hub.icloud.activity.finish(imported)
        let exportPhotos = hub.photos.activity.begin("Exporting Summer", transferDirection: 0)
        hub.photos.activity.update(exportPhotos, .init(message: "Fetching Coast.png", completed: 3, total: 12, fraction: 0.25))
        hub.selected = nil
        _sessions = StateObject(wrappedValue: WorkspaceSessionManager(initialHub: hub, makeHub: { id, settings in
            let workspace = CloudDriveHub(pikpak: DownloaderModel.finderWorkspaceFixture(defaults: defaults, workspaceSessionID: id, settings: settings), defaults: defaults,
                restoreConnections: false, photosAccess: .init(status: { access.status }, request: { access.status },
                    provider: { DemoPhotosDrive(directory: directory) }), localRootURL: directory)
            workspace.icloud.connect(ICloudDriveProvider(rootURL: directory)); workspace.photos.connect(DemoPhotosDrive(directory: directory))
            return workspace
        }))
    }
    var body: some Scene {
        Window("MyCloudDriver · Design Fixture", id: "fixture") {
            WorkspaceSessionRoot(hub: sessions.initialHub, manager: sessions).preferredColorScheme(dark ? .dark : .light)
                .defaultAppStorage(preferences)
                .onReceive(menuUpdateTimer) { _ in
                    if stressMenuUpdates {
                        menuUpdateTicks += 1
                        hub.pikpak.status = "Synthetic background update \(menuUpdateTicks)"
                    }
                }
        }.defaultSize(width: 1240, height: 820)
        .commands {
            FinderCommands(settings: sessions.settings, sessions: sessions)
            CommandMenu("Fixture") {
                Button("All Drives") { hub.selected = nil }
                Button("Find Similar Files") { hub.local.findSimilar([]) }
                Button("Toggle Appearance") { dark.toggle() }.keyboardShortcut("d", modifiers: [.command, .shift])
                Toggle("Simulate Background Updates", isOn: $stressMenuUpdates)
                Button("Minimum Window Size") { NSApp.keyWindow?.setContentSize(.init(width: 560, height: 360)) }
                Button("Compact Width") { NSApp.keyWindow?.setContentSize(.init(width: 750, height: 820)) }
                Button("Compact Height") { NSApp.keyWindow?.setContentSize(.init(width: 1240, height: 460)) }
                Button("Show Photos Grid") {
                    hub.open(.photos); hub.pikpakNavigation.showImmediately(0)
                    preferences.set(1, forKey: "browserViewMode")
                    hub.photos.enter(.init(id: "demo:all", name: "All Photos & Videos", isFolder: true))
                }
                Button("Next Drive") {
                    let kinds = CloudDriveKind.allCases
                    hub.open(kinds[((kinds.firstIndex(of: hub.selected ?? .pikpak) ?? 0) + 1) % kinds.count])
                }.keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Standard Window Size") { NSApp.keyWindow?.setContentSize(.init(width: 1240, height: 820)) }
                Button("Show PikPak Media Preview") {
                    let video = FileManager.default.temporaryDirectory.appendingPathComponent("MyCloudDriverDesignFixture/Resize sample.mp4")
                    guard FileManager.default.fileExists(atPath: video.path) else { return }
                    hub.pikpak.configureMediaPreviewFixture(videoURL: video)
                    hub.pikpakNavigation.showImmediately(0); hub.open(.pikpak)
                }
                Button("Use Oversized Preview") {
                    preferences.set(1_500.0, forKey: "previewCanvasWidth")
                    preferences.set(2_000.0, forKey: "previewCanvasHeight")
                }
                Button("Show Second PikPak Video") {
                    let video = FileManager.default.temporaryDirectory.appendingPathComponent("MyCloudDriverDesignFixture/Second sample.mp4")
                    guard FileManager.default.fileExists(atPath: video.path) else { return }
                    hub.pikpak.configureMediaPreviewFixture(videoURL: video)
                    hub.pikpakNavigation.showImmediately(0); hub.open(.pikpak)
                }
                Button("Play Fixture Video") { hub.pikpak.previewPlayer?.play() }
                Button("Show Fixture Playback Position") {
                    let seconds = hub.pikpak.previewPlayer?.currentTime().seconds ?? 0
                    hub.pikpak.status = "Synthetic playback: \(Int(seconds.isFinite ? seconds : 0)) seconds"
                }
                Button("Hold PikPak Request and Return to Browser") {
                    _ = hub.pikpak.activateSharedLinkBrowser()
                    hub.pikpak.isRunning = true
                    hub.pikpakNavigation.showImmediately(0); hub.open(.pikpak)
                }
                Button("Finish Held PikPak Request") { hub.pikpak.isRunning = false }
                Button("Photos Permission Denied") { photosAccessState.status = .denied; hub.refreshPhotosAuthorization() }
                Button("Photos Permission Allowed") { photosAccessState.status = .authorized; hub.refreshPhotosAuthorization() }
                Button("Photos Permission Not Requested") {
                    hub.disconnectPhotos(); photosAccessState.status = .notDetermined; hub.refreshPhotosAuthorization()
                }
                Button("iCloud Storage Available") { storageState.unavailable = false; storageState.delay = 200_000_000; hub.icloudStorage.refresh(force: true) }
                Button("iCloud Storage Unavailable") { storageState.unavailable = true; hub.icloudStorage.refresh(force: true) }
                Button("iCloud Storage Loading") { storageState.unavailable = false; storageState.delay = 12_000_000_000; hub.icloudStorage.refresh(force: true) }
                Button("Show Scan Progress") {
                    let scan = hub.photos.similarity.local
                    scan.externalScopeNames = ["Summer"]
                    scan.setFixtureProgress(["event":"progress", "stage":"analysing", "completed":15, "total":24,
                        "current_file":["name":"Garden.png", "bytes":2_000_000], "operation":"decoding", "counts":["files_ready":15]])
                    hub.photos.similarity.present(source: .local)
                }
            }
        }
        Settings {
            FinderSettingsView(settings: hub.pikpak.finderSettings, model: hub.pikpak, hub: hub)
                .preferredColorScheme(dark ? .dark : .light).defaultAppStorage(preferences)
        }
    }
}
