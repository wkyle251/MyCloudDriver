import AppKit
import SwiftUI

/// Generated PNGs stand in for folder artwork; the synthetic video's provider
/// deliberately delays playback so its cached thumbnail remains inspectable.
private final class ThumbnailDemoProvider: NativeCloudDrive, @unchecked Sendable {
    let kind = CloudDriveKind.local
    let root: CloudDriveLocation
    let items: [CloudDriveItem]
    init(root: URL, items: [CloudDriveItem]) { self.root = .init(id: root.absoluteString, title: "Thumbnail QA", url: root); self.items = items }
    func list(_ location: CloudDriveLocation, offset: Int, search: String) async throws -> CloudDrivePage { .init(items: items, total: items.count) }
    func materialize(_ item: CloudDriveItem, directory: URL, progress: @escaping CloudDriveProgressHandler) async throws -> URL {
        if item.mediaType == "video" {
            progress(.init(message: "Buffering from external disk…", fraction: 0.4))
            try await Task.sleep(nanoseconds: 120_000_000_000)
        }
        return item.url!
    }
    func scanItems(_ items: [CloudDriveItem], location: CloudDriveLocation, progress: @escaping CloudDriveProgressHandler) async throws -> [CloudDriveItem] { items }
    func createContainer(_ name: String, in location: CloudDriveLocation) async throws -> CloudDriveUndo? { nil }
    func rename(_ item: CloudDriveItem, to name: String) async throws -> CloudDriveUndo? { nil }
    func relocate(_ items: [CloudDriveItem], from: CloudDriveLocation, to: CloudDriveLocation, copy: Bool, progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? { nil }
    func importFiles(_ urls: [URL], into: CloudDriveLocation, progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? { nil }
    func delete(_ items: [CloudDriveItem], progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? { nil }
}

@main @MainActor final class NativeThumbnailUITestApp: NSObject, NSApplicationDelegate {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("NativeThumbnailUI-\(UUID())")
    private let suite = "com.wky.MyCloudDriver.ThumbnailQA.\(UUID())"
    private var defaults: UserDefaults!
    private var hub: CloudDriveHub!
    private var sessions: WorkspaceSessionManager!
    private var window: NSWindow!
    static func main() {
        let app = NSApplication.shared, delegate = NativeThumbnailUITestApp()
        app.delegate = delegate; app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(0,forKey:"browserViewMode"); defaults.set(true,forKey:"showsPreviewPane")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var items: [CloudDriveItem] = []
        for (index, title) in ["Garden clip.mp4", "Coast.png", "Mountain.png", "Forest.png"].enumerated() {
            let pixels = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:480,pixelsHigh:320,bitsPerSample:8,
                samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:pixels)
            NSColor(calibratedHue:CGFloat(index) / 5,saturation:0.3,brightness:0.95,alpha:1).setFill()
            NSBezierPath(rect:.init(x:0,y:0,width:480,height:320)).fill()
            NSColor(calibratedHue:CGFloat(index) / 5,saturation:0.8,brightness:0.55,alpha:1).setFill()
            let hill=NSBezierPath(); hill.move(to:.init(x:0,y:20)); hill.line(to:.init(x:190,y:260)); hill.line(to:.init(x:480,y:30)); hill.close(); hill.fill()
            NSColor.white.setFill(); NSBezierPath(ovalIn:.init(x:340,y:210,width:50,height:50)).fill()
            NSGraphicsContext.restoreGraphicsState()
            let url=root.appendingPathComponent("Generated-\(index).png")
            try! pixels.representation(using:.png,properties:[:])!.write(to:url)
            items.append(.init(id:"generated-\(index)",name:title,isFolder:false,bytes:10_000,
                url:url,mediaType:index == 0 ? "video" : "image",revision:"generated"))
        }
        hub = CloudDriveHub(pikpak:DownloaderModel.finderWorkspaceFixture(defaults:defaults),defaults:defaults,
            restoreConnections:false,localRootURL:root)
        hub.local.connect(ThumbnailDemoProvider(root:root,items:items)); hub.open(.local)
        sessions = WorkspaceSessionManager(initialHub:hub)
        window = NSWindow(contentRect:.init(x:100,y:100,width:1180,height:820),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title="Native Thumbnails · Generated Files Only"; window.isReleasedWhenClosed=false
        window.contentView=NSHostingView(rootView:WorkspaceSessionRoot(hub:hub,manager:sessions).defaultAppStorage(defaults))
        sessions.register(window,hub:hub); window.makeKeyAndOrderFront(nil)
        let menu=NSMenu(), item=NSMenuItem(), actions=NSMenu()
        item.submenu=actions; menu.addItem(item)
        for (title,action,key) in [("List",#selector(list),"1"),("Thumbnails",#selector(grid),"2"),("Quit Thumbnail QA",#selector(NSApplication.terminate(_:)),"q")] {
            let item=NSMenuItem(title:title,action:action,keyEquivalent:key); item.target=action == #selector(NSApplication.terminate(_:)) ? NSApp : self; actions.addItem(item)
        }
        NSApp.mainMenu=menu
    }
    @objc func list() { defaults.set(0,forKey:"browserViewMode") }
    @objc func grid() { defaults.set(1,forKey:"browserViewMode") }
    func applicationWillTerminate(_ notification:Notification) {
        sessions.closeAll(); defaults.removePersistentDomain(forName:suite); try? FileManager.default.removeItem(at:root)
    }
}
