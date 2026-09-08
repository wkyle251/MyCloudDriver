// Offline visual harness. Uses the production image presentation and a
// manually released loader, so the thumbnail/loading/original states can be inspected.
import AppKit
import SwiftUI

@MainActor
private final class ImageFixture {
    let thumbnail = ImageFixture.bitmap(width: 60, height: 36)
    let original = ImageFixture.bitmap(width: 1000, height: 600)
    private var waiting: [CheckedContinuation<NSImage, Error>] = []

    func load(_ url: URL, _ proxy: String) async throws -> NSImage {
        if url.lastPathComponent == "thumbnail" { return thumbnail }
        return try await withCheckedThrowingContinuation { waiting.append($0) }
    }

    func finish(failing: Bool = false) {
        let completions = waiting
        waiting = []
        for completion in completions {
            if failing { completion.resume(throwing: NSError(domain: "OfflineImageFixture", code: 17)) }
            else { completion.resume(returning: original) }
        }
    }

    static func bitmap(width: Int, height: Int) -> NSImage {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32)!
        let bytes = bitmap.bitmapData!
        for y in 0..<height { for x in 0..<width {
            let offset = (y * width + x) * 4
            let ring = abs(hypot(Double(x) / Double(width) - 0.5, Double(y) / Double(height) - 0.5) - 0.23) < 0.035
            bytes[offset] = ring ? 255 : UInt8(20 + x * 100 / width)
            bytes[offset + 1] = ring ? 255 : UInt8(60 + y * 140 / height)
            bytes[offset + 2] = ring ? 255 : 210
            bytes[offset + 3] = 255
        } }
        return NSImage(cgImage: bitmap.cgImage!, size: NSSize(width: width, height: height))
    }
}

@MainActor
private struct ImageTestRoot: View {
    private let fixture: ImageFixture
    @StateObject private var model: ImagePreviewModel
    @State private var generation = UUID()
    @State private var originalURL: URL?
    @State private var failure = "None"
    init() {
        let fixture = ImageFixture()
        self.fixture = fixture
        _model = StateObject(wrappedValue: ImagePreviewModel(load: fixture.load))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Image preview · offline transition test").font(.title2.bold())
            Text("The bitmap stays visible while loading; only a complete original replaces it.")
            ImagePreviewSurface(model: model, request: ImagePreviewRequest(
                fileID: "synthetic-image", thumbnailURL: URL(string: "https://example.invalid/thumbnail")!,
                contentURL: originalURL, generation: generation, proxyURL: ""
            ), onFailure: { failure = $0.localizedDescription })
                .frame(height: 360)
                .background(Color.blue.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            Text("Displayed: \(model.frame?.quality == .original ? "original" : (model.frame == nil ? "placeholder" : "thumbnail")) · \(model.isLoading ? "loading" : "idle")")
            HStack {
                Button("Load original ⌘L") {
                    generation = UUID()
                    originalURL = URL(string: "https://example.invalid/original")!
                    failure = "None"
                }.keyboardShortcut("l", modifiers: .command)
                Button("Finish ⌘↩") { fixture.finish() }.keyboardShortcut(.return, modifiers: .command)
                Button("Fail ⌘E") { fixture.finish(failing: true) }.keyboardShortcut("e", modifiers: .command)
                Button("Metadata reload ⌘R") {
                    generation = UUID(); originalURL = nil
                }.keyboardShortcut("r", modifiers: .command)
            }
            Text("Error: \(failure)").font(.caption).textSelection(.enabled)
            Text("No account data or network is used.").font(.caption).foregroundStyle(.secondary)
        }.padding(24)
    }
}

@main
struct ImagePreviewUITestApp: App {
    var body: some Scene {
        WindowGroup("PikPak · Image Preview Test") { ImageTestRoot() }
            .defaultSize(width: 800, height: 600)
    }
}
