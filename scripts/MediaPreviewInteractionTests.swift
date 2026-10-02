import AppKit
import AVFoundation
import SwiftUI

@main @MainActor final class MediaPreviewInteractionTests: NSObject, NSApplicationDelegate {
    private static var uiWindow: NSWindow?
    static func main() {
        let app = NSApplication.shared, delegate = MediaPreviewInteractionTests()
        app.delegate = delegate; app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do { try await Self.run() }
            catch { fputs("Media preview check failed: \(error)\n", stderr); exit(1) }
            if !CommandLine.arguments.contains("--ui") { NSApp.terminate(nil) }
        }
    }
    static func wait(seconds: Double = 5, line: Int = #line, _ check: () -> Bool) async throws {
        for _ in 0..<Int(seconds * 40) {
            if check() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        precondition(check(), "Preview check timed out at line \(line)")
    }
    static func generate(_ url: URL, codec: String?) throws {
        let child = Process()
        child.executableURL = VideoPreviewPreparation.ffmpegURL!
        child.arguments = ["-nostdin", "-v", "error", "-y"]
        if let codec {
            child.arguments! += ["-f", "lavfi", "-i", "testsrc2=size=160x120:rate=12", "-f", "lavfi", "-i",
                "sine=frequency=440:sample_rate=44100", "-t", "12", "-c:v", codec, "-threads", "2", "-pix_fmt", "yuv420p"]
        } else { child.arguments! += ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100", "-t", "12"] }
        child.arguments! += ["-c:a", "aac", url.path]
        try child.run(); child.waitUntilExit(); precondition(child.terminationStatus == 0)
    }
    static func key(_ code: UInt16, window: NSWindow, modifiers: NSEvent.ModifierFlags = [], repeated: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: repeated, keyCode: code)!
    }
    static func click(_ point: NSPoint, window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }
    static func keyboard(_ playback: MediaPlaybackController, window: NSWindow) async throws {
        let root = NSView(frame: .init(x: 0, y: 0, width: 600, height: 420))
        window.contentView = root
        let scope = MediaPreviewKeyView(frame: .init(x: 200, y: 0, width: 400, height: 420))
        root.addSubview(scope); scope.playback = playback
        var moved: [Int] = []
        scope.onMove = { moved.append($0) }
        let volume = MediaSliderControl(frame: .init(x: 240, y: 30, width: 160, height: 18))
        volume.isVolume = true; volume.maximum = 1; volume.value = 0.5; volume.isEnabled = true
        root.addSubview(volume)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await wait { NSApp.keyWindow === window }
        for point in [NSPoint(x: 300, y: 390), NSPoint(x: 300, y: 200), NSPoint(x: 300, y: 40)] {
            scope.focus(for: click(point, window: window))
            precondition(scope.hasPreviewFocus && window.firstResponder === scope)
            playback.seek(to: 6)
            try await wait { abs(playback.player!.currentTime().seconds - 6) < 0.1 }
            precondition(MediaPreviewKeyView.handle(key(124, window: window)))
            try await wait { abs(playback.player!.currentTime().seconds - 11) < 0.1 }
            precondition(MediaPreviewKeyView.handle(key(123, window: window)))
            try await wait { abs(playback.player!.currentTime().seconds - 6) < 0.1 }
        }
        window.makeFirstResponder(volume)
        precondition(MediaPreviewKeyView.handle(key(125, window: window)))
        precondition(MediaPreviewKeyView.handle(key(126, window: window)))
        precondition(moved == [1, -1] && volume.value == 0.5, "Up/Down on volume must navigate files")
        precondition(MediaPreviewKeyView.handle(key(124, window: window, repeated: true)))
        try await wait { abs(playback.player!.currentTime().seconds - 11) < 0.1 }
        precondition(volume.value == 0.5, "Left/Right on volume must seek the video")
        for modifiers: NSEvent.ModifierFlags in [.command, .shift, .option, .control] {
            precondition(!MediaPreviewKeyView.handle(key(125, window: window, modifiers: modifiers)))
        }
        let field = NSTextField(frame: .init(x: 220, y: 70, width: 180, height: 24))
        root.addSubview(field); window.makeFirstResponder(field)
        precondition(!MediaPreviewKeyView.handle(key(123, window: window)), "Text editing keeps its arrows")
        scope.focus(for: click(.init(x: 100, y: 200), window: window))
        precondition(!scope.hasPreviewFocus && !MediaPreviewKeyView.handle(key(125, window: window)))
        scope.focus(for: click(.init(x: 300, y: 200), window: window))
        scope.removeFromSuperview()
        precondition(!MediaPreviewKeyView.handle(key(125, window: window)), "Unmounted panes release focus")
        print("PASS preview focus: header/video/controls, 5-second seeks, repeats, volume arrows, file steps, text editing and outside clicks")
    }
    static func nativeRecovery(defaults: UserDefaults, unsupported: URL) async throws {
        let before = try Data(contentsOf: unsupported)
        let model = NativeMediaPreviewModel(settings: .init(defaults: defaults))
        defer { model.clear() }
        let provider = ICloudDriveProvider(rootURL: unsupported.deletingLastPathComponent(), kind: .local)
        let item = try ICloudDriveProvider.item(unsupported)
        model.prepare(item, provider: provider)
        try await wait { model.ready && model.playback.canSeek }
        let old = model.playback.player!
        let error = NSError(domain: AVFoundationErrorDomain, code: AVError.Code.decodeFailed.rawValue)
        model.recoverVideo(error, player: old, item: item)
        try await wait(seconds: 15) { model.failure != nil || model.ready && model.playback.canSeek }
        precondition(model.failure == nil && model.playback.player !== old)
        let next = model.playback.player!, url = (next.currentItem!.asset as! AVURLAsset).url
        let frame = try await AVAssetImageGenerator(asset: next.currentItem!.asset).image(at: CMTime(seconds: 1, preferredTimescale: 600))
        precondition(frame.image.width == 160 && next.rate == 0 && url != unsupported)
        model.recoverVideo(error, player: old, item: item)
        precondition(model.playback.player === next)
        model.recoverVideo(error, player: next, item: item)
        precondition(model.failure != nil && !model.ready, "A failed compatible copy must stay retryable without looping")
        model.clear()
        precondition(!FileManager.default.fileExists(atPath: url.path))
        let after = try Data(contentsOf: unsupported)
        precondition(before == after)
        print("PASS native video recovery: decoded compatible frame, paused intent, stale callback, bounded failure, cleanup and original preservation")
    }
    static func showUI(defaults: UserDefaults, good: URL, bad: URL) throws {
        let third = good.deletingLastPathComponent().appendingPathComponent("Supported2.mp4")
        try FileManager.default.copyItem(at: good, to: third)
        let model = NativeMediaPreviewModel(settings: .init(defaults: defaults))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 850, height: 700),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "Media Preview QA"
        window.contentView = NSHostingView(rootView: PreviewInteractionFixture(model: model, urls: [good, bad, third]))
        let menu = NSMenu(), item = NSMenuItem(), appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Preview QA", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu; menu.addItem(item); NSApp.mainMenu = menu
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        uiWindow = window
    }
    static func run() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MediaPreviewQA-\(UUID().uuidString)")
        try CloudDriveFiles.privateDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "MyCloudDriver.MediaPreviewQA.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let good = directory.appendingPathComponent("Supported.mp4"), bad = directory.appendingPathComponent("VP9.mp4")
        let audio = directory.appendingPathComponent("AudioOnly.mp4")
        try generate(good, codec: "libx264"); try generate(bad, codec: "libvpx-vp9"); try generate(audio, codec: nil)
        if CommandLine.arguments.contains("--ui") { try showUI(defaults: defaults, good: good, bad: bad); return }
        let playback = MediaPlaybackController(settings: .init(defaults: defaults))
        playback.attach(AVPlayer(url: good))
        try await wait { playback.canSeek }
        precondition(playback.player!.allowsExternalPlayback == false)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 420),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        try await keyboard(playback, window: window)

        let surface = MediaVideoPlayerView(frame: .init(x: 0, y: 0, width: 600, height: 420))
        window.contentView = surface
        var failures: [(Error, AVPlayer)] = []
        surface.onFailure = { failures.append(($0, $1)) }
        surface.attach(playback.player!)
        try await wait { surface.isReadyForDisplay }
        let unsupported = AVPlayer(url: bad)
        playback.attach(unsupported); surface.attach(unsupported)
        try await wait { playback.canSeek }
        precondition(!surface.isReadyForDisplay && unsupported.currentItem?.error == nil,
            "Reproduce AVKit accepting an MP4 without displaying its unsupported video")
        try await wait(seconds: 16) { !failures.isEmpty }
        precondition(failures.count == 1 && failures[0].1 === unsupported && VideoPreviewPreparation.isFormatFailure(failures[0].0))
        let audioPlayer = AVPlayer(url: audio)
        surface.attach(audioPlayer)
        try await wait { failures.count == 2 }
        precondition((failures[1].0 as NSError).code == AVError.Code.noSourceTrack.rawValue)
        surface.attach(AVPlayer(url: good))
        try await wait { surface.isReadyForDisplay }
        surface.clear()
        print("PASS actual AVKit frames: paused poster, ready-without-picture MP4, first-frame timeout and audio-only source rejection")
        try await nativeRecovery(defaults: defaults, unsupported: bad)
        try await DownloaderModel.testVideoFrameRecovery(defaults: defaults, unsupported: bad, supported: good)

    }
}

private struct PreviewInteractionFixture: View {
    @ObservedObject var model: NativeMediaPreviewModel
    let urls: [URL]
    @State private var index = 0
    @State private var search = ""
    private var item: CloudDriveItem { try! ICloudDriveProvider.item(urls[index]) }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading) {
                TextField("Search fixture", text: $search)
                ForEach(urls.indices, id: \.self) { number in
                    Button("Clip \(number + 1): \(urls[number].lastPathComponent)") { index = number }
                        .buttonStyle(.borderless)
                }
                Text("Selected clip: \(index + 1)").accessibilityIdentifier("selected-clip")
                Spacer()
            }.padding(16).frame(width: 230)
            Divider()
            FinderPreviewPane(mediaPlayback: model.playback, onPreviewMove: { index = min(urls.count - 1, max(0, index + $0)) }) {
                HStack { Image(systemName: "film"); Text("Clip \(index + 1): \(item.name)").font(.headline); Spacer() }
                    .padding(10).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            } media: {
                NativeMediaPreview(item: item, provider: ICloudDriveProvider(rootURL: urls[0].deletingLastPathComponent(), kind: .local), model: model)
            } details: { Text("Synthetic media only. Click anywhere in this pane, then use Left/Right and Up/Down.") }
        }
    }
}
