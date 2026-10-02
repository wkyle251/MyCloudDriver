import AVFoundation
import Foundation

/// Runs only against generated media and a loopback HTTP server. No app data.
@main @MainActor struct PreviewResourceLoaderTests {
    static func main() async throws {
        guard #available(macOS 14.0, *) else { return }
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("PreviewLoaderTests-\(UUID())")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }
        let movie = directory.appendingPathComponent("Generated.mp4")
        let encoder = Process()
        encoder.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        encoder.arguments = ["-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i",
                             "testsrc2=size=160x120:rate=12", "-t", "3", "-c:v", "libx264",
                             "-threads", "2", "-pix_fmt", "yuv420p", movie.path]
        try encoder.run(); encoder.waitUntilExit()
        precondition(encoder.terminationStatus == 0)
        let server = Process(), portPipe = Pipe()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-u", "-c", #"""
import http.server, pathlib, re, sys
body = pathlib.Path(sys.argv[1]).read_bytes()
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        match = re.fullmatch(r'bytes=(\d+)-(\d*)', self.headers.get('Range', ''))
        start = int(match[1]) if match else 0
        end = min(int(match[2]), len(body)-1) if match and match[2] else len(body)-1
        if start >= len(body):
            self.send_response(416); self.end_headers(); return
        self.send_response(206 if match else 200)
        if 'missing-mime' not in self.path:
            self.send_header('Content-Type', 'application/octet-stream' if 'generic' in self.path else ('video/x-msvideo' if 'wrong-mime' in self.path else 'video/mp4'))
        self.send_header('Content-Length', end-start+1)
        self.send_header('Accept-Ranges', 'bytes')
        if match: self.send_header('Content-Range', f'bytes {start}-{end}/{len(body)}')
        self.end_headers()
        try: self.wfile.write(body[start:end+1])
        except (BrokenPipeError, ConnectionResetError): pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
"""#, movie.path]
        server.standardOutput = portPipe; server.standardError = FileHandle.nullDevice
        try server.run()
        defer { server.terminate(); server.waitUntilExit() }
        let port = String(decoding: portPipe.fileHandleForReading.availableData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var failures = 0
        for path in ["correct-mime", "generic", "generic.mp4", "missing-mime", "wrong-mime", "complete-cache", "bad-cache"] {
            let cache = try PreviewResourceCache()
            if path == "bad-cache" || path == "complete-cache" {
                let generatedBytes = try Data(contentsOf: movie)
                let length = generatedBytes.count
                cache.updateMetadata(typeIdentifier: "public.mpeg-4", contentLength: Int64(length), supportsByteRanges: true)
                cache.store(path == "bad-cache" ? Data(repeating: 0, count: length) : generatedBytes, at: 0)
            }
            var progressCount = 0
            let loader = PreviewResourceLoader(originalURL: URL(string: "http://127.0.0.1:\(port)/\(path)")!,
                                               proxyURL: "", cache: cache, onCacheProgress: { _ in progressCount += 1 })
            let asset = AVURLAsset(url: loader.assetURL, options: [AVURLAssetOverrideMIMETypeKey: "video/mp4"])
            asset.resourceLoader.setDelegate(loader, queue: loader.delegateQueue)
            let item = AVPlayerItem(asset: asset), player = AVPlayer()
            player.replaceCurrentItem(with: item)
            for _ in 0..<160 {
                if item.status != .unknown { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            if path == "bad-cache" {
                let error = item.error as NSError?
                let underlying = error?.userInfo[NSUnderlyingErrorKey] as? NSError
                precondition(item.status == .failed && error?.domain == AVFoundationErrorDomain && error?.code == -11829)
                print("PASS damaged synthetic cache reproduces AVFoundation -11829, underlying \(underlying?.code ?? 0)")
            } else if item.status == .readyToPlay {
                do {
                    let generator = AVAssetImageGenerator(asset: asset)
                    let frame = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600))
                    precondition(frame.image.width == 160 && frame.image.height == 120)
                    print("PASS \(path): AVPlayer ready and actual MP4 frame decoded")
                } catch { failures += 1; print("FAIL \(path) frame: \(error as NSError)") }
            } else {
                failures += 1
                let error = item.error as NSError?
                print("FAIL \(path): status \(item.status.rawValue), \(String(describing: error)), underlying \(String(describing: error?.userInfo[NSUnderlyingErrorKey]))")
            }
            if path == "complete-cache" {
                try await Task.sleep(nanoseconds: 300_000_000)
                precondition(progressCount == 1, "Repeated completed-cache reads must publish only one snapshot")
            }
            player.replaceCurrentItem(with: nil); loader.invalidate(); cache.removeFromDisk()
        }
        if failures > 0 { exit(1) }

        let longMovie = directory.appendingPathComponent("GeneratedLong.mp4")
        let longEncoder = Process()
        longEncoder.executableURL = encoder.executableURL
        longEncoder.arguments = ["-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i",
                                 "testsrc2=size=160x120:rate=2", "-t", "90", "-c:v", "libx264",
                                 "-threads", "2", "-pix_fmt", "yuv420p", longMovie.path]
        try longEncoder.run(); longEncoder.waitUntilExit()
        precondition(longEncoder.terminationStatus == 0)
        let suite = "PreviewBufferTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try await DownloaderModel.testPreviewBufferLimit(defaults: defaults, mediaURL: longMovie)
    }
}
