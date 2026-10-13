import Foundation

private actor DownloadSamples {
    var values: [(UInt64, UInt64)] = []
    func record(_ bytes: UInt64, _ total: UInt64) { values.append((bytes, total)) }
    var sawPartial: Bool { values.contains { $0.0 > 0 && $0.0 < $0.1 } }
}

@main struct MediaFileDownloadTests {
    static func main() async throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("media-range-tests-\(UUID().uuidString)")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: directory) }
        let bytes = Data((0..<131_071).map { UInt8(($0 * 13 + $0 / 257) % 251) })
        let source = directory.appendingPathComponent("fixture.bin")
        try bytes.write(to: source)
        let server = Process(), portPipe = Pipe()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-u", "-c", #"""
import http.server, pathlib, re, sys, time, json
body = pathlib.Path(sys.argv[1]).read_bytes()
counts = {}
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        assert self.headers.get('Origin') == 'https://mypikpak.com'
        assert self.headers.get('Referer') == 'https://mypikpak.com/'
        if self.path == '/stats':
            data = json.dumps(counts).encode()
            self.send_response(200); self.send_header('Content-Length',len(data)); self.end_headers(); self.wfile.write(data); return
        counts[self.path] = counts.get(self.path, 0) + 1
        if self.path == '/error': self.send_error(403); return
        match = re.fullmatch(r'bytes=(\d+)-(\d*)',self.headers.get('Range',''))
        first = int(match[1]) if match else 0
        if first:
            assert self.headers.get('If-Range') == '"fixture-v1"'
        whole = self.path == '/whole' or (self.path == '/ignore-range' and first > 0)
        if self.path == '/missing-complete':
            self.send_response(206); self.send_header('Content-Length',len(body)); self.end_headers(); self.wfile.write(body); return
        if whole:
            self.send_response(200); self.send_header('Content-Length',len(body)); self.end_headers(); self.wfile.write(body); return
        if self.path == '/suffix-first' and not match: first = 1
        if self.path == '/repeat' and first: first = 0
        if self.path == '/gap' and first: first += 1
        if self.path == '/overlap' and first: first -= 1
        last = min(first+4092,len(body)-1)
        total = str(len(body)+1) if self.path == '/changed-total' and first else str(len(body))
        if self.path == '/unknown': total = '*'
        if self.path == '/overflow': total = str(2**64-1)
        data = body[first:last+1]
        if self.path == '/truncated': data = data[:-1]
        self.send_response(206)
        if self.path != '/missing' and not (self.path == '/missing-first' and not match):
            self.send_header('Content-Range',f'bytes {first}-{last}/{total}')
        self.send_header('ETag','"fixture-v2"' if self.path == '/changed-tag' and first else '"fixture-v1"')
        self.send_header('Content-Length',len(data)); self.end_headers()
        try:
            for start in range(0,len(data),1024):
                self.wfile.write(data[start:start+1024]); self.wfile.flush()
                if self.path == '/cancel': time.sleep(0.05)
        except (BrokenPipeError,ConnectionResetError): pass
server = http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
print(server.server_port,flush=True)
server.serve_forever()
"""#, source.path]
        server.standardOutput = portPipe; server.standardError = FileHandle.nullDevice
        try server.run()
        defer { server.terminate(); server.waitUntilExit() }
        let port = String(decoding: portPipe.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let base = URL(string: "http://127.0.0.1:\(port)")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = ["Origin": "https://mypikpak.com", "Referer": "https://mypikpak.com/"]
        configuration.timeoutIntervalForRequest = 5
        let samples = DownloadSamples()
        for path in ["whole", "chunks", "missing-first", "suffix-first", "ignore-range", "unknown", "missing-complete"] {
            let destination = directory.appendingPathComponent(UUID().uuidString)
            let count = try await MediaFileDownload.download(from: base.appendingPathComponent(path), to: destination,
                expectedSize: UInt64(bytes.count), configuration: configuration, purpose: "MP4") { received, total in
                    Task { await samples.record(received, total) }
                }
            precondition(count == bytes.count && (try! Data(contentsOf: destination)) == bytes, "Complete bytes must match for \(path)")
            let permissions = try manager.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber
            precondition(permissions?.intValue == 0o600)
            try manager.removeItem(at: destination)
        }
        let sawPartial = await samples.sawPartial
        precondition(sawPartial, "Progress must describe the entire object, not just one response")
        print("PASS whole GET, capped HTTP 206 ranges, explicit metadata retry, ignored Range, trusted size, exact bytes and private output")
        for path in ["repeat", "gap", "overlap", "changed-total", "changed-tag", "truncated", "missing", "overflow", "error"] {
            let destination = directory.appendingPathComponent(UUID().uuidString)
            do {
                try await MediaFileDownload.download(from: base.appendingPathComponent(path), to: destination,
                    configuration: configuration, purpose: "MP4")
                preconditionFailure("Invalid response \(path) must fail")
            } catch {
                let detail = error as NSError
                precondition(detail.domain == "PikPakPreviewTransport" && detail.code == (path == "error" ? 403 : 206), "\(path): \(detail)")
                precondition(!manager.fileExists(atPath: destination.path), "Failed downloads must remove their partial file")
            }
        }
        for path in ["unknown", "missing-complete"] {
            let destination = directory.appendingPathComponent(UUID().uuidString)
            do {
                try await MediaFileDownload.download(from: base.appendingPathComponent(path), to: destination,
                    configuration: configuration, purpose: "MP4")
                preconditionFailure("Unknown-length 206 cannot prove a whole object")
            } catch { precondition((error as NSError).code == 206 && !manager.fileExists(atPath: destination.path)) }
        }
        print("PASS repeated/missing/overlapping ranges, changed objects, truncated bodies, unknown totals and HTTP errors fail without partial output")
        let destination = directory.appendingPathComponent("cancelled.part")
        let download = Task {
            try await MediaFileDownload.download(from: base.appendingPathComponent("cancel"), to: destination,
                configuration: configuration, purpose: "MP4")
        }
        let deadline = Date().addingTimeInterval(5)
        while !manager.fileExists(atPath: destination.path) {
            precondition(Date() < deadline)
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        download.cancel()
        do { _ = try await download.value; preconditionFailure("Cancelled transfer completed") }
        catch { precondition(error is CancellationError || (error as NSError).code == NSURLErrorCancelled) }
        precondition(!manager.fileExists(atPath: destination.path))
        let existing = directory.appendingPathComponent("existing.bin")
        try bytes.write(to: existing)
        do {
            try await MediaFileDownload.download(from: base.appendingPathComponent("whole"), to: existing,
                configuration: configuration, purpose: "MP4")
            preconditionFailure("Existing files must stay untouched")
        } catch { precondition((try! Data(contentsOf: existing)) == bytes) }
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, _) = try await session.data(from: base.appendingPathComponent("stats"))
        let counts = try JSONSerialization.jsonObject(with: data) as! [String: Int]
        precondition(counts["/missing"] == 2 && counts["/overflow"] == 2 && counts["/repeat"] == 2,
            "Bad range responses must terminate instead of looping")
        print("PASS cancellation after a completed prefix, partial cleanup, existing-file protection and bounded malformed-response retries")
    }
}
