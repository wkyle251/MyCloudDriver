import AppKit
import SwiftUI

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
        let items = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "png" }.map { url in
            CloudDriveItem(id: "demo:" + url.lastPathComponent, name: url.lastPathComponent, isFolder: false, bytes: 1_245_082, modified: Date(), url: url, mediaType: "image", canRename: false)
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
    @StateObject private var hub: CloudDriveHub
    @State private var dark = false
    init() {
        let defaults = UserDefaults(suiteName: "com.wky.MyCloudDriver.DesignFixture.preferences")!
        defaults.removePersistentDomain(forName: "com.wky.MyCloudDriver.DesignFixture.preferences")
        let hub = CloudDriveHub(pikpak: DownloaderModel.finderWorkspaceFixture(defaults: defaults), defaults: defaults, restoreConnections: false)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MyCloudDriverDesignFixture", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for folder in ["Documents", "Projects", "Travel"] { try? FileManager.default.createDirectory(at: directory.appendingPathComponent(folder), withIntermediateDirectories: true) }
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
        let activity = hub.icloud.activity.begin("Exporting project files")
        hub.icloud.activity.update(activity, .init(message: "Copying Project overview.pdf", completed: 12, total: 28, fraction: 0.43))
        _hub = StateObject(wrappedValue: hub)
    }
    var body: some Scene {
        WindowGroup("MyCloudDriver · Design Fixture") {
            MyCloudDriverRootView(hub: hub, settings: hub.pikpak.finderSettings).preferredColorScheme(dark ? .dark : .light)
        }.defaultSize(width: 1240, height: 820)
        .commands {
            FinderCommands(settings: hub.pikpak.finderSettings)
            CommandMenu("Fixture") {
                Button("Toggle Appearance") { dark.toggle() }.keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Minimum Window Size") { NSApp.keyWindow?.setContentSize(.init(width: 1000, height: 720)) }
                Button("Show Photos Grid") { hub.selected = .photos; hub.photos.viewMode = 1; hub.photos.enter(.init(id: "demo:all", name: "All Photos & Videos", isFolder: true)) }
                Button("Show Scan Progress") {
                    let scan = hub.photos.similarity.local
                    scan.externalScopeNames = ["Summer"]
                    scan.setFixtureProgress(["event":"progress", "stage":"analysing", "completed":15, "total":24,
                        "current_file":["name":"Garden.png", "bytes":2_000_000], "operation":"decoding", "counts":["files_ready":15]])
                    hub.photos.similarity.present(source: .local)
                }
            }
        }
        Settings { FinderSettingsView(settings: hub.pikpak.finderSettings, model: hub.pikpak, connections: AnyView(CloudDriveConnectionsView(hub: hub))) }
    }
}
