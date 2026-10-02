import AVFoundation
import Foundation

/// A preview owns only its generated copy. Releasing it never removes a local
/// original, and preparation cleans up only after its download/encoder stops.
final class VideoPreviewCopy: @unchecked Sendable {
    let url: URL
    private let directory: URL
    init(url: URL, directory: URL) { self.url = url; self.directory = directory }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

enum VideoPreviewPreparation {
    enum InputFormat: String {
        case avi, mp4, mkv, webm, ts, flv, wmv, rm, mpg, ogv
        var displayName: String { rawValue.uppercased() }
        // Select a local media demuxer explicitly; never interpret a downloaded
        // playlist or allow MOV external track references to fetch other files.
        var inputOptions: [String] {
            switch self {
            case .avi: return ["-f", "avi"]
            case .mp4: return ["-f", "mov", "-enable_drefs", "0", "-use_absolute_path", "0"]
            case .mkv, .webm: return ["-f", "matroska"]
            case .ts: return ["-f", "mpegts"]
            case .flv: return ["-f", "flv"]
            case .wmv: return ["-f", "asf"]
            case .rm: return ["-f", "rm"]
            case .mpg: return ["-f", "mpeg"]
            case .ogv: return ["-f", "ogg"]
            }
        }

        /// The containers a local FFmpeg can demux with an explicit reader.
        /// An extension with no entry keeps the external-player fallback
        /// rather than downloading a whole file FFmpeg may not open.
        init?(fileExtension value: String) {
            switch value {
            case "avi": self = .avi
            case "mp4", "m4v", "mov", "3gp", "3g2": self = .mp4
            case "mkv", "mk3d": self = .mkv
            case "webm": self = .webm
            case "ts", "m2ts", "mts", "m2t": self = .ts
            case "flv", "f4v": self = .flv
            case "wmv", "asf": self = .wmv
            case "rm", "rmvb": self = .rm
            case "mpg", "mpeg", "mpe", "vob", "m2v": self = .mpg
            case "ogv", "ogm": self = .ogv
            default: return nil
            }
        }
    }

    /// A format/decoder failure can be repaired by preparing a conventional
    /// MP4. Network, authorization and protected-content failures cannot.
    /// An inconsistent sample table reaches AVFoundation after the container
    /// parses, as an unusable cursor or a track it refuses to open, so both
    /// belong here alongside the outright parse failures.
    static func isFormatFailure(_ error: Error?) -> Bool {
        guard let error else { return false }
        var pending = [error as NSError], visited = Set<ObjectIdentifier>()
        var foundFormatFailure = false
        let recoverable = [AVError.Code.fileFailedToParse, .fileFormatNotRecognized,
                           .decodeFailed, .decoderNotFound, .undecodableMediaData, .formatUnsupported,
                           .invalidSampleCursor, .noSourceTrack]
        while let current = pending.popLast() {
            guard visited.insert(ObjectIdentifier(current)).inserted else { continue }
            if current.domain == NSURLErrorDomain || current.domain == "PikPakPreviewTransport" { return false }
            if current.domain == AVFoundationErrorDomain {
                if [AVError.Code.contentIsProtected, .contentIsNotAuthorized, .applicationIsNotAuthorized]
                    .contains(where: { $0.rawValue == current.code }) { return false }
                foundFormatFailure = foundFormatFailure || recoverable.contains { $0.rawValue == current.code }
            }
            if let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError { pending.append(underlying) }
            if let multiple = current.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError] { pending += multiple }
        }
        return foundFormatFailure
    }

    static var ffmpegURL: URL? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    static func prepare(source: URL, format: InputFormat = .avi, expectedSize: UInt64 = 0, proxyURL: String = "",
                        progress: @escaping @Sendable (CloudDriveProgress) -> Void) async throws -> VideoPreviewCopy {
        try Task.checkCancellation()
        guard let executable = ffmpegURL else {
            throw CloudDriveError.message("Compatible previews require FFmpeg. Install FFmpeg on this Mac, then retry the preview.")
        }
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("MyCloudDriver-VideoPreview-\(UUID().uuidString)", isDirectory: true)
        try CloudDriveFiles.privateDirectory(directory)
        var retained = false
        defer { if !retained { try? manager.removeItem(at: directory) } }
        let input: URL
        if source.isFileURL { input = source }
        else {
            progress(.init(message: "Downloading \(format.displayName) for preview…"))
            input = directory.appendingPathComponent("original.\(format.rawValue)")
            let download = VideoPreviewDownload(destination: input, format: format, progress: progress)
            try await download.run(source: source, proxyURL: proxyURL)
            try Task.checkCancellation()
            let size = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard expectedSize == 0 || UInt64(size) == expectedSize else {
                throw CloudDriveError.message("The \(format.displayName) download was incomplete. Retry the preview.")
            }
        }
        try Task.checkCancellation()
        progress(.init(message: "Preparing \(format.displayName) preview…"))
        let output = directory.appendingPathComponent("preview.mp4")
        let encoder = VideoPreviewEncoder(format: format, progress: progress)
        try await encoder.run(executable: executable, arguments: [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-nostats", "-y",
            "-progress", "pipe:1", "-filter_threads", "2", "-threads", "2",
            "-protocol_whitelist", "file,pipe",
        ] + format.inputOptions + ["-i", input.path,
            "-map", "0:v:0", "-map", "0:a:0?", "-sn", "-dn",
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "21", "-threads", "2",
            "-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "192k", "-ac", "2", "-movflags", "+faststart", output.path,
        ])
        try Task.checkCancellation()
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        if !source.isFileURL { try? manager.removeItem(at: input) }
        retained = true
        return VideoPreviewCopy(url: output, directory: directory)
    }
}

private final class VideoPreviewDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let destination: URL
    private let format: VideoPreviewPreparation.InputFormat
    private let progress: @Sendable (CloudDriveProgress) -> Void
    private var lastReport = Date.distantPast
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private var continuation: CheckedContinuation<Void, Error>?
    // Download callbacks use URLSession's serial delegate queue.
    private var result: Result<Void, Error>?
    init(destination: URL, format: VideoPreviewPreparation.InputFormat, progress: @escaping @Sendable (CloudDriveProgress) -> Void) {
        self.destination = destination; self.format = format; self.progress = progress
    }
    func run(source: URL, proxyURL: String) async throws {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                guard !cancelled else {
                    lock.unlock(); continuation.resume(throwing: CancellationError()); return
                }
                self.continuation = continuation
                let session = URLSession(configuration: PreviewTransport.configuration(proxyURL: proxyURL), delegate: self, delegateQueue: nil)
                self.session = session
                var request = URLRequest(url: source)
                for (field, value) in PreviewTransport.mediaHeaders { request.setValue(value, forHTTPHeaderField: field) }
                task = session.downloadTask(with: request)
                task?.resume()
                lock.unlock()
            }
        }, onCancel: {
            self.lock.lock()
            self.cancelled = true
            self.task?.cancel()
            self.lock.unlock()
        })
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        result = Result {
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 else {
                throw CloudDriveError.message("The \(format.displayName) download could not be completed. Retry the preview.")
            }
            try FileManager.default.moveItem(at: location, to: destination)
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation, wasCancelled = cancelled
        self.continuation = nil; self.session = nil; self.task = nil
        lock.unlock()
        session.finishTasksAndInvalidate()
        if wasCancelled { continuation?.resume(throwing: CancellationError()) }
        else if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume(with: result ?? .failure(CloudDriveError.message("The \(format.displayName) download did not return a file."))) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let now = Date()
        guard now.timeIntervalSince(lastReport) >= 0.2 || totalBytesWritten == totalBytesExpectedToWrite else { return }
        lastReport = now
        let fraction = totalBytesExpectedToWrite > 0 ? min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) : nil
        progress(.init(message: "Downloading \(format.displayName) for preview…", fraction: fraction))
    }
}

/// Cancellation can race launch or completion. Keep the continuation alive
/// until the child exits so callers cannot remove files it is still writing.
private final class VideoPreviewEncoder: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var progressBytes = Data()
    private let progress: @Sendable (CloudDriveProgress) -> Void
    private let format: VideoPreviewPreparation.InputFormat
    init(format: VideoPreviewPreparation.InputFormat, progress: @escaping @Sendable (CloudDriveProgress) -> Void) {
        self.format = format; self.progress = progress
    }

    func run(executable: URL, arguments: [String]) async throws {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let child = Process(), pipe = Pipe()
                child.executableURL = executable; child.arguments = arguments
                child.standardInput = FileHandle.nullDevice
                child.standardOutput = pipe; child.standardError = FileHandle.nullDevice
                pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    self?.readProgress(handle.availableData)
                }
                child.terminationHandler = { [self] completed in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    lock.lock()
                    let wasCancelled = cancelled
                    process = nil
                    lock.unlock()
                    if wasCancelled { continuation.resume(throwing: CancellationError()) }
                    else if completed.terminationStatus != 0 {
                        continuation.resume(throwing: CloudDriveError.message("The \(format.displayName) preview could not be prepared. The file may be damaged or use an unsupported codec."))
                    } else { continuation.resume() }
                }
                lock.lock()
                do {
                    guard !cancelled else { throw CancellationError() }
                    try child.run()
                    process = child
                    lock.unlock()
                } catch {
                    lock.unlock()
                    child.terminationHandler = nil
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        }, onCancel: { self.cancel() })
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        let child = process
        if let child, child.isRunning { child.terminate() }
        lock.unlock()
        // FFmpeg normally exits promptly. A stuck decoder must not retain a
        // cancelled preview and its temporary directory indefinitely.
        if let child {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
    }

    private func readProgress(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        lock.lock()
        progressBytes.append(bytes)
        var seconds: Int?
        while let newline = progressBytes.firstIndex(of: 10) {
            let line = String(decoding: progressBytes[..<newline], as: UTF8.self)
            progressBytes.removeSubrange(...newline)
            if line.hasPrefix("out_time_us="), let time = Int64(line.dropFirst(12)), time >= 0 {
                seconds = Int(time / 1_000_000)
            }
        }
        let shouldReport = !cancelled
        lock.unlock()
        if shouldReport, let seconds {
            let time = String(format: "%d:%02d", seconds / 60, seconds % 60)
            progress(.init(message: "Preparing \(format.displayName) preview… (\(time) converted)"))
        }
    }
}
