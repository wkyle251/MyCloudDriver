import AppKit
import AVFoundation
import Foundation

private actor PreviewProgressLog {
    var converted = false
    var downloaded = false
    func record(_ update: CloudDriveProgress) {
        converted = converted || update.message.contains("converted)")
        downloaded = downloaded || (update.message.contains("Downloading") && update.fraction != nil)
    }
}

@main @MainActor struct AVIPreviewTests {
    static func check(_ condition: Bool) { precondition(condition) }
    static func wait(line: Int = #line, _ condition: () async -> Bool) async {
        for _ in 0..<600 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        preconditionFailure("Timed out waiting for AVI preview at test line \(line)")
    }
    static func generate(_ url: URL, codec: String, audio: Bool, long: Bool = false) async throws {
        let process = Process()
        process.executableURL = VideoPreviewPreparation.ffmpegURL!
        process.arguments = ["-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i",
                            long ? "testsrc2=size=1920x1080:rate=30" : "testsrc2=size=160x120:rate=12"]
        if audio { process.arguments! += ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100"] }
        process.arguments! += ["-t", long ? "20" : "2", "-c:v", codec, "-threads", "2", "-q:v", "8"]
        if codec == "mpeg4" { process.arguments! += ["-vtag", "XVID"] }
        if audio { process.arguments! += ["-c:a", "pcm_s16le"] }
        process.arguments! += [url.path]
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        precondition(status == 0)
    }
    static func verifyVideo(_ url: URL, audio: Bool) async throws {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        precondition(tracks.count == 1)
        let formats = try await tracks[0].load(.formatDescriptions)
        precondition(formats.contains { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264 })
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        precondition(audioTracks.isEmpty != audio)
        let generator = AVAssetImageGenerator(asset: asset)
        let frame = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600))
        precondition(frame.image.width == 160 && frame.image.height == 120)
    }
    static func previewDirectories() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("MyCloudDriver-VideoPreview-") })
    }
    static func generateMP4(_ url: URL) throws {
        let process = Process()
        process.executableURL = VideoPreviewPreparation.ffmpegURL!
        process.arguments = ["-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=160x120:rate=12",
                             "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100", "-t", "3",
                             "-c:v", "libx264", "-threads", "2", "-pix_fmt", "yuv420p", "-c:a", "aac", url.path]
        try process.run(); process.waitUntilExit()
        precondition(process.terminationStatus == 0)
    }
    static func generateMatroska(_ url: URL) throws {
        let process = Process()
        process.executableURL = VideoPreviewPreparation.ffmpegURL!
        process.arguments = ["-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=160x120:rate=12",
                             "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100", "-t", "3",
                             "-c:v", "libx264", "-threads", "2", "-pix_fmt", "yuv420p", "-c:a", "aac",
                             "-f", "matroska", url.path]
        try process.run(); process.waitUntilExit()
        precondition(process.terminationStatus == 0)
    }
    static func main() async throws {
        _ = NSApplication.shared
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("AVITests-\(UUID().uuidString)")
        try CloudDriveFiles.privateDirectory(directory)
        defer { try? manager.removeItem(at: directory) }
        let suite = "MyCloudDriver.AVITests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = directory.appendingPathComponent("Legacy.AVI")
        try await generate(original, codec: "mpeg4", audio: true)
        let originalBytes = try Data(contentsOf: original)
        let baseline = try previewDirectories()
        var copy: VideoPreviewCopy? = try await VideoPreviewPreparation.prepare(source: original) { _ in }
        let output = copy!.url
        try await verifyVideo(output, audio: true)
        copy = nil
        precondition(!manager.fileExists(atPath: output.path))
        check(try previewDirectories() == baseline)
        check(try Data(contentsOf: original) == originalBytes)
        print("PASS Xvid AVI video/audio decodes inside AVFoundation; generated copy cleanup preserves the original")

        let silent = directory.appendingPathComponent("Silent.avi")
        try await generate(silent, codec: "mjpeg", audio: false)
        copy = try await VideoPreviewPreparation.prepare(source: silent) { _ in }
        try await verifyVideo(copy!.url, audio: false)
        copy = nil
        let provider = ICloudDriveProvider(rootURL: directory, kind: .local)
        let item = try ICloudDriveProvider.item(original)
        precondition(item.mediaType == "video")
        let model = NativeMediaPreviewModel(settings: .init(defaults: defaults))
        model.prepare(item, provider: provider)
        await wait { model.ready || model.failure != nil }
        precondition(model.failure == nil)
        await wait { model.playback.canSeek }
        model.playback.togglePlayback()
        await wait { model.playback.position > 0.15 }
        model.playback.togglePlayback()
        model.playback.seek(to: 1.2)
        await wait { abs(model.playback.position - 1.2) < 0.1 }
        model.clear()
        check(try previewDirectories() == baseline)
        print("PASS silent MJPEG, uppercase AVI selection, native preview play/pause/seek and cleanup")

        let corrupt = directory.appendingPathComponent("Corrupt.avi")
        try Data("invalid avi".utf8).write(to: corrupt)
        do {
            _ = try await VideoPreviewPreparation.prepare(source: corrupt) { _ in }
            preconditionFailure("Corrupt AVI must fail")
        } catch { precondition(!(error is CancellationError)) }
        check(try previewDirectories() == baseline)
        print("PASS corrupt AVI reports an error and removes incomplete output")

        let large = directory.appendingPathComponent("Long.avi")
        try await generate(large, codec: "mpeg4", audio: false, long: true)
        let progress = PreviewProgressLog()
        let conversion = Task {
            try await VideoPreviewPreparation.prepare(source: large) { value in
                Task { await progress.record(value) }
            }
        }
        await wait { await progress.converted }
        conversion.cancel()
        do { _ = try await conversion.value; preconditionFailure("Cancelled conversion must not publish a copy") }
        catch { precondition(error is CancellationError) }
        check(try previewDirectories() == baseline)
        precondition(manager.fileExists(atPath: large.path))
        print("PASS cancellation stops an active encoder before deleting its output")

        let mp4 = directory.appendingPathComponent("Generated.MP4")
        try generateMP4(mp4)
        let mp4Bytes = try Data(contentsOf: mp4)
        copy = try await VideoPreviewPreparation.prepare(source: mp4, format: .mp4) { _ in }
        try await verifyVideo(copy!.url, audio: true)
        copy = nil
        check(try Data(contentsOf: mp4) == mp4Bytes)
        let parseError = NSError(domain: AVFoundationErrorDomain, code: -11829,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -12848)])
        precondition(VideoPreviewPreparation.isFormatFailure(parseError))
        precondition(VideoPreviewPreparation.isFormatFailure(NSError(domain: "Wrapper", code: 1,
            userInfo: [NSUnderlyingErrorKey: parseError])))
        // AVFoundation cannot open Matroska at all, which is the container the
        // conversion fallback exists for. Its own demuxer must still read it.
        let mkv = directory.appendingPathComponent("Generated.mkv")
        try generateMatroska(mkv)
        let mkvBytes = try Data(contentsOf: mkv)
        var matroskaTracks: [AVAssetTrack] = []
        do { matroskaTracks = try await AVURLAsset(url: mkv).loadTracks(withMediaType: .video) } catch {}
        precondition(matroskaTracks.isEmpty, "A Matroska original must stay unplayable without conversion")
        copy = try await VideoPreviewPreparation.prepare(source: mkv, format: .mkv) { _ in }
        try await verifyVideo(copy!.url, audio: true)
        copy = nil
        check(try Data(contentsOf: mkv) == mkvBytes)
        // An inconsistent sample table surfaces after the container parses, as
        // an unusable cursor (-11880) or a track AVFoundation will not open
        // (-11869). Both are repaired by the same conversion as a parse error.
        for tableFailure in [AVError.Code.invalidSampleCursor, .noSourceTrack] {
            precondition(VideoPreviewPreparation.isFormatFailure(
                NSError(domain: AVFoundationErrorDomain, code: tableFailure.rawValue,
                    userInfo: [NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -12551)])))
        }
        // Every container a local FFmpeg can demux must reach the conversion
        // fallback with an explicit reader, and nothing else may reach it.
        for (extensionName, expected) in [("mp4", "mov"), ("m4v", "mov"), ("mov", "mov"), ("avi", "avi"),
                                          ("mkv", "matroska"), ("webm", "matroska"), ("ts", "mpegts"),
                                          ("flv", "flv"), ("wmv", "asf"), ("rmvb", "rm"), ("vob", "mpeg")] {
            let format = VideoPreviewPreparation.InputFormat(fileExtension: extensionName)
            precondition(format?.inputOptions.first == "-f", extensionName)
            precondition(format?.inputOptions[1] == expected, extensionName)
        }
        for unsupported in ["", "m3u8", "iso", "zip", "txt"] {
            precondition(VideoPreviewPreparation.InputFormat(fileExtension: unsupported) == nil, unsupported)
        }
        for blocked in [URLError(.timedOut) as NSError,
                        NSError(domain: "PikPakPreviewTransport", code: 403),
                        NSError(domain: AVFoundationErrorDomain, code: AVError.Code.contentIsProtected.rawValue)] {
            let wrapped = NSError(domain: AVFoundationErrorDomain, code: -11829, userInfo: [NSUnderlyingErrorKey: blocked])
            precondition(!VideoPreviewPreparation.isFormatFailure(wrapped))
        }
        precondition(!VideoPreviewPreparation.isFormatFailure(nil))
        print("PASS MP4 conversion preserves original bytes; parser failures recover while network/auth/protected errors do not")

        let server = Process(), portPipe = Pipe()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-u", "-c", #"""
import http.server, pathlib, re, sys, time
avi = pathlib.Path(sys.argv[1]).read_bytes()
mp4 = pathlib.Path(sys.argv[2]).read_bytes()
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        assert self.headers.get('Referer') == 'https://mypikpak.com/'
        assert self.headers.get('Origin') == 'https://mypikpak.com'
        if self.path == '/error':
            self.send_error(403); return
        body = mp4 if self.path.startswith('/mp4') else avi
        match = re.fullmatch(r'bytes=(\d+)-(\d*)', self.headers.get('Range', ''))
        if self.path.startswith('/mp4') and match:
            if self.path.endswith('.repair'): body = bytes(len(body))
            start = int(match[1]); end = min(int(match[2]), len(body)-1) if match[2] else len(body)-1
            if start >= len(body): self.send_error(416); return
            self.send_response(206)
            self.send_header('Content-Range', f'bytes {start}-{end}/{len(body)}')
            self.send_header('Accept-Ranges', 'bytes')
            body = body[start:end+1]
        else: self.send_response(200)
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('Content-Length', len(body))
        self.end_headers()
        try:
            for start in range(0, len(body), 4096):
                self.wfile.write(body[start:start+4096]); self.wfile.flush()
                if self.path == '/slow': time.sleep(0.15)
        except (BrokenPipeError, ConnectionResetError): pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
"""#, original.path, mp4.path]
        server.standardOutput = portPipe; server.standardError = FileHandle.nullDevice
        try server.run()
        defer { server.terminate(); server.waitUntilExit() }
        let port = String(decoding: portPipe.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let remote = URL(string: "http://127.0.0.1:\(port)/avi")!
        copy = try await VideoPreviewPreparation.prepare(source: remote, expectedSize: UInt64(originalBytes.count)) { _ in }
        try await verifyVideo(copy!.url, audio: true)
        copy = nil
        for (path, expectedSize) in [("avi", UInt64(originalBytes.count + 1)), ("error", UInt64(0))] {
            do {
                _ = try await VideoPreviewPreparation.prepare(source: remote.deletingLastPathComponent().appendingPathComponent(path), expectedSize: expectedSize) { _ in }
                preconditionFailure("Invalid HTTP response must not produce a preview")
            } catch { precondition(!(error is CancellationError)) }
        }
        let download = Task {
            try await VideoPreviewPreparation.prepare(source: remote.deletingLastPathComponent().appendingPathComponent("slow")) { value in
                Task { await progress.record(value) }
            }
        }
        await wait { await progress.downloaded }
        download.cancel()
        do { _ = try await download.value; preconditionFailure("Download cancellation must discard the preview") }
        catch { precondition(error is CancellationError || (error as NSError).code == NSURLErrorCancelled) }
        check(try previewDirectories() == baseline)
        print("PASS cloud download headers, real AVI playback, size/status validation and download cancellation")
        try await DownloaderModel.testAVIPreviewRouting(defaults: defaults, original: original)
        try await DownloaderModel.testMP4PreviewRecovery(defaults: defaults,
            remote: URL(string: "http://127.0.0.1:\(port)/mp4")!, bytes: mp4Bytes)
        check(try Data(contentsOf: mp4) == mp4Bytes)
        check(try previewDirectories() == baseline)
        try DownloaderModel.testMergeFolderSelection(defaults: defaults)
    }
}
