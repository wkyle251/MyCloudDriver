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
        root.addSubview(scope); scope.playback = playback; scope.isMediaPreview = true
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
            precondition(MediaPreviewKeyView.handle(key(49, window: window)))
            precondition(playback.wantsPlayback, "Space in the preview resumes playback")
            precondition(MediaPreviewKeyView.handle(key(49, window: window, repeated: true)))
            precondition(playback.wantsPlayback, "Holding Space must not pause again")
            precondition(MediaPreviewKeyView.handle(key(49, window: window)))
            precondition(!playback.wantsPlayback, "Space in the preview pauses playback")
        }
        window.makeFirstResponder(volume)
        precondition(MediaPreviewKeyView.handle(key(49, window: window)))
        precondition(playback.wantsPlayback && volume.value == 0.5, "Space on the volume control resumes playback")
        precondition(MediaPreviewKeyView.handle(key(49, window: window)))
        precondition(!playback.wantsPlayback, "Space on the volume control pauses playback")
        precondition(MediaPreviewKeyView.handle(key(125, window: window)))
        precondition(MediaPreviewKeyView.handle(key(126, window: window)))
        precondition(moved == [1, -1] && volume.value == 0.5, "Up/Down on volume must navigate files")
        precondition(MediaPreviewKeyView.handle(key(124, window: window, repeated: true)))
        try await wait { abs(playback.player!.currentTime().seconds - 11) < 0.1 }
        precondition(volume.value == 0.5, "Left/Right on volume must seek the video")
        for modifiers: NSEvent.ModifierFlags in [.command, .shift, .option, .control] {
            precondition(!MediaPreviewKeyView.handle(key(125, window: window, modifiers: modifiers)))
            precondition(!MediaPreviewKeyView.handle(key(49, window: window, modifiers: modifiers)))
        }
        scope.playback = nil
        precondition(MediaPreviewKeyView.handle(key(49, window: window)), "Space while preparing stays in the preview instead of opening Quick Look")
        scope.playback = playback
        let field = NSTextField(frame: .init(x: 220, y: 70, width: 180, height: 24))
        root.addSubview(field); window.makeFirstResponder(field)
        precondition(!MediaPreviewKeyView.handle(key(123, window: window)), "Text editing keeps its arrows")
        precondition(!MediaPreviewKeyView.handle(key(49, window: window)), "Text editing keeps its spaces")
        scope.focus(for: click(.init(x: 100, y: 200), window: window))
        window.makeFirstResponder(nil)
        precondition(!scope.hasPreviewFocus && !MediaPreviewKeyView.handle(key(125, window: window)))
        precondition(MediaPreviewKeyView.handle(key(49, window: window)) && playback.wantsPlayback,
            "Space in the file list plays the visible media preview without requiring a click in the pane")
        precondition(MediaPreviewKeyView.handle(key(49, window: window, repeated: true)) && playback.wantsPlayback,
            "Holding Space in the file list must not toggle playback repeatedly")
        precondition(MediaPreviewKeyView.handle(key(49, window: window)) && !playback.wantsPlayback)
        scope.playback = nil
        precondition(MediaPreviewKeyView.handle(key(49, window: window)),
            "A media preview that is still preparing keeps Space from opening Quick Look")
        scope.playback = playback
        scope.isMediaPreview = false
        scope.focus(for: click(.init(x: 300, y: 200), window: window))
        precondition(!MediaPreviewKeyView.handle(key(49, window: window)), "Other file types keep Space for Quick Look")
        scope.isMediaPreview = true; scope.isHidden = true
        precondition(!MediaPreviewKeyView.handle(key(49, window: window)), "A hidden media preview cannot claim Space")
        scope.isHidden = false
        scope.focus(for: click(.init(x: 300, y: 200), window: window))
        scope.removeFromSuperview()
        precondition(!MediaPreviewKeyView.handle(key(125, window: window)), "Unmounted panes release focus")
        precondition(!MediaPreviewKeyView.handle(key(49, window: window)), "Unmounted panes release Space")
        print("PASS preview keys: Space plays visible media from the file list, ignores repeats, reserves loading media, preserves typing/Quick Look and ignores hidden/removed panes; focused arrows retain seeking and file navigation")
    }
    static func earlyNetworkPlayback(defaults: UserDefaults, movie: URL) async throws {
        let original = try Data(contentsOf: movie)
        var offset = 0, indexOffset: Int?
        while offset + 8 <= original.count {
            let length = original[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            guard length >= 8, offset + length <= original.count else { break }
            if String(decoding: original[offset + 4..<offset + 8], as: UTF8.self) == "moov" { indexOffset = offset; break }
            offset += length
        }
        guard let indexOffset else { preconditionFailure("Generated MP4 needs a trailing index") }
        // A valid free atom moves the movie index to the far end without
        // moving any video chunks or changing their offsets.
        let paddingLength = 24 << 20
        var padding = Data((0..<4).reversed().map { UInt8((paddingLength >> ($0 * 8)) & 255) })
        padding.append(Data("free".utf8)); padding.append(Data(count: paddingLength - 8))
        var bytes = Data(original.prefix(indexOffset)); bytes.append(padding); bytes.append(original.suffix(from: indexOffset))
        let slow = movie.deletingLastPathComponent().appendingPathComponent("SlowShare-TailIndex.mp4")
        try bytes.write(to: slow)
        let model = NativeMediaPreviewModel(settings: .init(defaults: defaults))
        defer { model.clear() }
        model.selectionDelayNanoseconds = 0
        model.bufferedVolume = { _ in .networkShare }
        model.memoryIO.read = { descriptor, target, length, position in
            usleep(150_000)
            return pread(descriptor, target, length, position)
        }
        let provider = ICloudDriveProvider(rootURL: slow.deletingLastPathComponent(), kind: .local)
        let item = try ICloudDriveProvider.item(slow)
        model.prepare(item, provider: provider)
        try await wait(seconds: 5) { model.ready && model.playback.canPlay }
        precondition(model.bufferStatus!.cache.cachedBytes < Int64(bytes.count / 3),
            "A slow network file with its index at the end must open before a large linear prebuffer fills")
        model.playback.togglePlayback()
        try await wait(seconds: 5) { model.playback.position > 0.1 }
        model.playback.togglePlayback()
        let before = model.memoryLoader!.snapshot.cachedBytes
        try await wait { model.memoryLoader!.snapshot.cachedBytes > before }
        precondition(!model.playback.wantsPlayback && model.playback.player!.rate == 0)
        let frame = try await AVAssetImageGenerator(asset: model.playback.player!.currentItem!.asset).image(at: CMTime(seconds: 1, preferredTimescale: 600))
        precondition(frame.image.width == 160)
        print("PASS slow network startup: trailing movie index fetched early, playback before one-third is buffered, real decoded frame and continued buffering after Pause")
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
    static func cachedSourceOwnership() async throws {
        let bytes = Data((0..<32).map(UInt8.init))
        for mode in ["unknown", "partial", "sparse", "complete"] {
            let cache = try PreviewResourceCache()
            cache.updateMetadata(typeIdentifier: "public.mpeg-4", contentLength: mode == "unknown" ? nil : 32, supportsByteRanges: true)
            cache.store(mode == "partial" || mode == "sparse" ? bytes.prefix(8) : bytes, at: 0)
            if mode == "sparse" { cache.store(bytes.suffix(8), at: 24) }
            if mode != "complete" {
                let input = try cache.takeCompleteFile()
                precondition(input == nil, "A sparse, partial or unknown-length buffer cannot become a local movie")
                cache.removeFromDisk()
                continue
            }
            let wrongSize = try cache.takeCompleteFile(expectedSize: 33)
            precondition(wrongSize == nil)
            var input = try cache.takeCompleteFile(expectedSize: 32)
            let url = input!.url
            cache.removeFromDisk()
            let retainedBytes = try Data(contentsOf: url)
            precondition(retainedBytes == bytes, "Clearing the old cache must preserve the complete conversion input")
            let repeated = try cache.takeCompleteFile()
            precondition(repeated == nil && cache.store(bytes, at: 0) == nil, "Ownership is transferred only once")
            input = nil
            try await wait { !FileManager.default.fileExists(atPath: url.path) }
            precondition(!FileManager.default.fileExists(atPath: url.path), "Generated input is removed when preparation releases it")
        }
        print("PASS complete-cache ownership: no sparse inputs, size validation, no second download and cleanup")
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
        try await earlyNetworkPlayback(defaults: defaults, movie: good)
        try await nativeRecovery(defaults: defaults, unsupported: bad)
        try await cachedSourceOwnership()
        try DownloaderModel.testExternalPreviewHandoff(defaults: defaults)
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
            FinderPreviewPane(mediaPlayback: model.playback, isMediaPreview: true,
                onPreviewMove: { index = min(urls.count - 1, max(0, index + $0)) }) {
                HStack { Image(systemName: "film"); Text("Clip \(index + 1): \(item.name)").font(.headline); Spacer() }
                    .padding(10).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            } media: {
                NativeMediaPreview(item: item, provider: ICloudDriveProvider(rootURL: urls[0].deletingLastPathComponent(), kind: .local), model: model)
            } details: { Text("Synthetic media only. Click anywhere in this pane, then use Left/Right and Up/Down.") }
        }
    }
}
