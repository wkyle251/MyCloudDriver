import AppKit
import SwiftUI

@MainActor private final class ThumbnailUIFixture: ObservableObject {
    @Published var started = 0
    @Published var finished = 0
    @Published var active = 0
    @Published var peak = 0
    func load(_ url: URL, _ proxy: String) async throws -> NSImage {
        started += 1; active += 1; peak = max(peak, active)
        defer { active -= 1 }
        try await Task.sleep(nanoseconds: 350_000_000)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 200,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 1_280, bitsPerPixel: 32)!
        let seed = url.path.utf8.reduce(0) { ($0 + Int($1)) % 100 }
        let bytes = rep.bitmapData!
        for y in 0..<200 { for x in 0..<320 {
            let offset = y * rep.bytesPerRow + x * 4
            bytes[offset] = UInt8(40 + seed + x / 5)
            bytes[offset + 1] = UInt8(80 + y / 2)
            bytes[offset + 2] = UInt8(220 - seed)
            bytes[offset + 3] = 255
        } }
        finished += 1
        return NSImage(cgImage: rep.cgImage!, size: NSSize(width: 320, height: 200))
    }
}

@main struct FolderThumbnailUITestApp: App {
    @StateObject private var fixture: ThumbnailUIFixture
    @StateObject private var model: DownloaderModel
    private let defaults: UserDefaults
    init() {
        let defaults = UserDefaults(suiteName: "com.wky.FolderThumbnailUI.fixture")!
        defaults.removePersistentDomain(forName: "com.wky.FolderThumbnailUI.fixture")
        defaults.set(0, forKey: "browserViewMode")
        defaults.set(0, forKey: "linksViewMode")
        let fixture = ThumbnailUIFixture()
        _fixture = StateObject(wrappedValue: fixture)
        _model = StateObject(wrappedValue: DownloaderModel.folderThumbnailFixture(defaults: defaults, load: fixture.load))
        self.defaults = defaults
    }
    var body: some Scene {
        WindowGroup("Folder thumbnails · offline test") {
            VStack(spacing: 0) {
                Text("Thumbnail requests: \(fixture.started) · Completed: \(fixture.finished) · Active: \(fixture.active) · Peak: \(fixture.peak)")
                    .font(.system(.body, design: .monospaced)).padding(10)
                ContentView().environmentObject(model).environmentObject(model.finderSettings)
                    .defaultAppStorage(defaults)
            }
        }
        .defaultSize(width: 1_240, height: 850)
        .commands { FinderCommands(settings: model.finderSettings) }
    }
}
