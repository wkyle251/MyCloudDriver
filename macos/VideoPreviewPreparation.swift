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
        /// Whether copying the streams into an MP4 can make this file playable. A file already in an Apple container
        /// fails on its codec, which a copy would keep, so only the other containers are repackaged first.
        var repackagingCanHelp: Bool { self != .mp4 }
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

    /// Why a conversion failed, in plain words, from FFmpeg's own error output and what the file's first bytes
    /// show it to be. The input's path never appears. An empty output keeps the generic sentence.
    static func failureReason(fromErrorOutput output: String, input: URL, container: MediaContainer?) -> String {
        let text = output.lowercased()
        let unrecognized = "The data is not valid for a video file: it does not start like any known video format, so it may be damaged or a different kind of file."
        if text.contains("no space left on device") { return "The Mac ran out of space while preparing the preview. Free some space and retry." }
        if text.contains("moov atom not found") {
            return container == .quickTime
                ? "The file ends before its movie index (moov), so it looks incomplete or cut short."
                : unrecognized
        }
        if text.contains("invalid data found when processing input") {
            return container.map { "The data is not valid for a \($0.displayName); the file may be damaged." } ?? unrecognized
        }
        if (text.contains("decoder") && text.contains("not found")) || text.contains("unsupported codec") || text.contains("could not find codec parameters") {
            return "It uses a codec FFmpeg cannot read."
        }
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard var line = lines.last else { return "The file may be damaged or use an unsupported codec." }
        for path in [input.path, input.deletingLastPathComponent().path] where !path.isEmpty { line = line.replacingOccurrences(of: path, with: "the file") }
        line = line.replacingOccurrences(of: #"^\[[^\]]*\]\s*"#, with: "", options: .regularExpression)
        line = line.replacingOccurrences(of: #"(?:/[^/\s]+){2,}"#, with: "a file", options: .regularExpression)
        return "FFmpeg said: \(String(line.prefix(160)))"
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

    /// A decoder failure needs different video encoding, not another copy of
    /// the same bytes. Keep the complete cache available for that conversion.
    static func isVideoDecoderFailure(_ error: Error?) -> Bool {
        guard isFormatFailure(error), let error else { return false }
        var pending = [error as NSError], visited = Set<ObjectIdentifier>()
        let codes = [AVError.Code.decodeFailed, .decoderNotFound, .undecodableMediaData, .noSourceTrack]
        while let current = pending.popLast() {
            guard visited.insert(ObjectIdentifier(current)).inserted else { continue }
            if current.domain == AVFoundationErrorDomain, codes.contains(where: { $0.rawValue == current.code }) { return true }
            if let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError { pending.append(underlying) }
            if let multiple = current.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError] { pending += multiple }
        }
        return false
    }

    static var ffmpegURL: URL? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// `repackage` copies the video untouched into an MP4, which is limited by how fast the file can be read.
    /// `transcode` re-encodes it, which is a real conversion.
    enum Mode { case repackage, transcode }

    /// A preview never needs more than 1920 on its long side, and both encoders need even dimensions.
    static let previewScale = "scale=w='min(1920,iw)':h='min(1920,ih)':force_original_aspect_ratio=decrease:force_divisible_by=2"

    /// FFmpeg's arguments. The input is read with the explicit demuxer, never probed. A damaged or cut stream is
    /// read past its bad packets, and missing timestamps are rebuilt. Hardware decoding and encoding are VideoToolbox.
    static func arguments(mode: Mode, format: InputFormat, input: String, output: String, hardware: Bool, hevcTag: Bool) -> [String] {
        var arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-nostats", "-y",
                         "-progress", "pipe:1", "-protocol_whitelist", "file,pipe"]
        if mode == .transcode && hardware { arguments += ["-hwaccel", "videotoolbox"] }
        arguments += ["-fflags", "+genpts+discardcorrupt"] + format.inputOptions + ["-i", input,
                      "-map", "0:v:0", "-map", "0:a:0?", "-sn", "-dn"]
        switch mode {
        case .repackage:
            // QuickTime reads HEVC only as `hvc1`; the tag is refused for any other codec, so it is tried first.
            arguments += ["-c:v", "copy"] + (hevcTag ? ["-tag:v", "hvc1"] : []) + ["-avoid_negative_ts", "make_zero"]
        case .transcode:
            arguments += ["-vf", previewScale]
            arguments += hardware ? ["-c:v", "h264_videotoolbox", "-b:v", "8M"]
                                  : ["-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-threads", "4"]
            arguments += ["-pix_fmt", "yuv420p"]
        }
        // Audio is always re-encoded: it is cheap, and it removes every audio codec an MP4 cannot hold.
        return arguments + ["-c:a", "aac", "-b:a", "192k", "-ac", "2", "-movflags", "+faststart", output]
    }

    static func prepare(source: URL, format requestedFormat: InputFormat = .avi, expectedSize: UInt64 = 0, proxyURL: String = "",
                        mode: Mode = .transcode,
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
            progress(.init(message: "Downloading \(requestedFormat.displayName) for preview…", fileSize: expectedSize, activity: .transferring))
            input = directory.appendingPathComponent("original.\(requestedFormat.rawValue)")
            try await MediaFileDownload.download(from: source, to: input, expectedSize: expectedSize,
                configuration: PreviewTransport.configuration(proxyURL: proxyURL), purpose: requestedFormat.displayName) { received, total in
                progress(.init(message: "Downloading \(requestedFormat.displayName) for preview…",
                    fraction: total > 0 ? min(1, Double(received) / Double(total)) : nil,
                    bytes: received, fileSize: total, activity: .transferring))
            }
            try Task.checkCancellation()
            let size = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard expectedSize == 0 || UInt64(size) == expectedSize else {
                throw CloudDriveError.message("The \(requestedFormat.displayName) download was incomplete. Retry the preview.")
            }
        }
        try Task.checkCancellation()
        // The file's own bytes say what it is. A name such as .MOV on a transport stream must not pick the reader.
        let container = MediaContainer.sniff(input)
        let format = container?.inputFormat ?? requestedFormat
        let verb = mode == .repackage ? "Repackaging" : "Preparing"
        progress(.init(message: "\(verb) \(format.displayName) preview…", activity: .processing))
        let output = directory.appendingPathComponent("preview.mp4")
        // Each mode has a better attempt and a safer one: the HEVC tag or none, hardware encoding or software.
        let attempts = [true, false].map { first in
            arguments(mode: mode, format: format, input: input.path, output: output.path, hardware: mode == .transcode && first,
                      hevcTag: mode == .repackage && first)
        }
        var failure: Error?
        for attempt in attempts {
            try Task.checkCancellation()
            try? manager.removeItem(at: output)
            do {
                try await VideoPreviewEncoder(format: format, container: container, input: input, verb: verb, progress: progress)
                    .run(executable: executable, arguments: attempt)
                failure = nil; break
            } catch is CancellationError { throw CancellationError() }
            catch { failure = error }
        }
        if let failure { throw failure }
        try Task.checkCancellation()
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        if !source.isFileURL { try? manager.removeItem(at: input) }
        retained = true
        return VideoPreviewCopy(url: output, directory: directory)
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
    private let container: MediaContainer?
    private let input: URL
    private let verb: String
    private var errorTail = Data()
    init(format: VideoPreviewPreparation.InputFormat, container: MediaContainer?, input: URL, verb: String,
         progress: @escaping @Sendable (CloudDriveProgress) -> Void) {
        self.format = format; self.container = container; self.input = input; self.verb = verb; self.progress = progress
    }
    /// Only the end matters, and a runaway decoder must not grow it without bound.
    private func keepErrorOutput(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        lock.lock(); errorTail.append(bytes)
        if errorTail.count > 8_192 { errorTail = errorTail.suffix(8_192) }
        lock.unlock()
    }

    func run(executable: URL, arguments: [String]) async throws {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let child = Process(), pipe = Pipe(), errors = Pipe()
                child.executableURL = executable; child.arguments = arguments
                child.standardInput = FileHandle.nullDevice
                child.standardOutput = pipe; child.standardError = errors
                pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    self?.readProgress(handle.availableData)
                }
                errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    self?.keepErrorOutput(handle.availableData)
                }
                child.terminationHandler = { [self] completed in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    errors.fileHandleForReading.readabilityHandler = nil
                    keepErrorOutput(errors.fileHandleForReading.readDataToEndOfFile())
                    lock.lock()
                    let wasCancelled = cancelled
                    let output = String(decoding: errorTail, as: UTF8.self)
                    process = nil
                    lock.unlock()
                    if wasCancelled { continuation.resume(throwing: CancellationError()) }
                    else if completed.terminationStatus != 0 {
                        let reason = VideoPreviewPreparation.failureReason(fromErrorOutput: output, input: input, container: container)
                        continuation.resume(throwing: CloudDriveError.message("The \(format.displayName) preview could not be prepared. \(reason)"))
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
            progress(.init(message: "\(verb) \(format.displayName) preview… (\(time) converted)", activity: .processing))
        }
    }
}
