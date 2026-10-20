import AppKit
import SwiftUI

/// A held provider makes the actual loading footer reviewable without a network
/// share. The workspace beside it operates only on generated files in /tmp.
private final class HeldPreviewDrive: NativeCloudDrive, @unchecked Sendable {
    let kind = CloudDriveKind.icloud
    let root: CloudDriveLocation
    private let lock = NSLock()
    private var held = true
    init(_ directory: URL) { root = .init(id: directory.absoluteString, title: "Generated share", url: directory) }
    func release() { lock.lock(); held = false; lock.unlock() }
    private var isHeld: Bool { lock.lock(); defer { lock.unlock() }; return held }
    func materialize(_ item: CloudDriveItem, directory: URL, progress: @escaping CloudDriveProgressHandler) async throws -> URL {
        var step = 0
        while isHeld {
            try Task.checkCancellation()
            step = min(45, step + 1)
            progress(.init(message: "Buffering from network share…", fraction: Double(step) / 100,
                bytes: UInt64(step) * 10_000, fileSize: 1_000_000, activity: .transferring))
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        return item.url!
    }
    func list(_ location: CloudDriveLocation, offset: Int, search: String) async throws -> CloudDrivePage { .init(items: [], total: 0) }
    func scanItems(_ items: [CloudDriveItem], location: CloudDriveLocation, progress: @escaping CloudDriveProgressHandler) async throws -> [CloudDriveItem] { items }
    func createContainer(_ name: String, in location: CloudDriveLocation) async throws -> CloudDriveUndo? { nil }
    func rename(_ item: CloudDriveItem, to name: String) async throws -> CloudDriveUndo? { nil }
    func relocate(_ items: [CloudDriveItem], from: CloudDriveLocation, to: CloudDriveLocation, copy: Bool, progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? { nil }
    func importFiles(_ urls: [URL], into: CloudDriveLocation, progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? { nil }
    func delete(_ items: [CloudDriveItem], progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? { nil }
}

private struct PreviewFooterFixture: View {
    @ObservedObject var hub: CloudDriveHub
    @ObservedObject var loading: NativeMediaPreviewModel
    let held: HeldPreviewDrive
    let movie: CloudDriveItem
    @State private var dark = false
    @State private var wideLoadingPreview = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Generated media only").font(.caption).foregroundStyle(.secondary)
                VStack {
                    FinderPreviewLayoutControls(settings: hub.pikpak.finderSettings)
                }.frame(width: 440)
                Spacer()
                Button(wideLoadingPreview ? "Narrow loading preview" : "Wide loading preview") { wideLoadingPreview.toggle() }
                Button("Release download") { held.release() }
                Button("Toggle appearance") { dark.toggle() }
            }.padding(8)
            HStack(spacing: 0) {
                NativeDriveWorkspace(model: hub.local, hub: hub, settings: hub.pikpak.finderSettings)
                Divider()
                VStack(spacing: 0) {
                    Text("Preparing preview").font(.headline).padding(10)
                    NativeMediaPreview(item: movie, provider: held, model: loading)
                }.frame(width: wideLoadingPreview ? 780 : 330)
            }
        }.preferredColorScheme(dark ? .dark : .light)
    }
}

@main @MainActor final class PreviewFooterUITestApp: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var hub: CloudDriveHub?
    private var loading: NativeMediaPreviewModel?
    private var directory: URL?
    private var suite: String?
    static func main() {
        let app = NSApplication.shared, delegate = PreviewFooterUITestApp()
        app.delegate = delegate; app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let suite = "PreviewFooterUI-\(UUID())"
            self.suite = suite
            let defaults = UserDefaults(suiteName: suite)!
            defaults.set(0, forKey: "browserViewMode")
            defaults.set(true, forKey: "finderShowsPreviewPane")
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("PreviewFooterUI-\(UUID())", isDirectory: true)
            directory = root
            try CloudDriveFiles.privateDirectory(root)
            let movieURL = root.appendingPathComponent("Generated sample.mp4")
            let child = Process()
            child.executableURL = VideoPreviewPreparation.ffmpegURL!
            child.arguments = ["-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24", "-t", "20", "-c:v", "libx264", "-threads", "2", "-pix_fmt", "yuv420p", movieURL.path]
            try child.run(); child.waitUntilExit(); precondition(child.terminationStatus == 0)
            try Data("Generated file for Return-to-Trash testing.\n".utf8).write(to: root.appendingPathComponent("Trash keyboard fixture.txt"))
            let hub = CloudDriveHub(pikpak: DownloaderModel.finderWorkspaceFixture(defaults: defaults), defaults: defaults,
                restoreConnections: false, localRootURL: root)
            self.hub = hub
            Task { @MainActor in
                // Let the hub finish its initial local connection before
                // installing a disk Trash rooted only in this fixture folder.
                for _ in 0..<200 where hub.local.provider == nil {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
                hub.local.connect(ICloudDriveProvider(rootURL: root, kind: .local, diskTrashRootURL: root))
            }
            let loading = NativeMediaPreviewModel(settings: .init(defaults: defaults))
            self.loading = loading
            let held = HeldPreviewDrive(root)
            let movie = try ICloudDriveProvider.item(movieURL)
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1320, height: 700),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            self.window = window
            window.isReleasedWhenClosed = false; window.title = "Preview Footer and Trash Keyboard QA"
            window.contentView = NSHostingView(rootView: PreviewFooterFixture(hub: hub, loading: loading, held: held, movie: movie).defaultAppStorage(defaults))
            let menu = NSMenu(), item = NSMenuItem(), appMenu = NSMenu()
            appMenu.addItem(withTitle: "Quit Preview QA", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            item.submenu = appMenu; menu.addItem(item); NSApp.mainMenu = menu
            window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            print("FIXTURE_DIRECTORY \(root.path)"); fflush(stdout)
        } catch { fputs("Preview fixture failed: \(error)\n", stderr); NSApp.terminate(nil) }
    }
    func applicationWillTerminate(_ notification: Notification) {
        loading?.clear(); hub?.local.close()
        if let directory { try? FileManager.default.removeItem(at: directory) }
        if let suite { UserDefaults.standard.removePersistentDomain(forName: suite) }
    }
}
