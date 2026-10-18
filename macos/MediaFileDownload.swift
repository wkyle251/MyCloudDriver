import Foundation

/// Downloads one complete object, including CDNs that cap a response to a
/// byte range. Temporary responses are joined on the background executor;
/// callers never hand a partial object to a decoder or another application.
enum MediaFileDownload {
    private static let chunkSize: UInt64 = 8 * 1024 * 1024
    private static let errorDomain = "PikPakPreviewTransport"

    fileprivate struct ByteRange {
        let first: UInt64
        let last: UInt64
        let total: UInt64?
        var count: UInt64 { last - first + 1 }
    }

    fileprivate static func byteRange(_ response: HTTPURLResponse) -> ByteRange? {
        let fields = (response.value(forHTTPHeaderField: "Content-Range") ?? "").split(whereSeparator: \.isWhitespace)
        guard fields.count == 2, fields[0].lowercased() == "bytes" else { return nil }
        let extent = fields[1].split(separator: "/", omittingEmptySubsequences: false)
        guard extent.count == 2 else { return nil }
        let ends = extent[0].split(separator: "-", omittingEmptySubsequences: false)
        guard ends.count == 2, let first = UInt64(ends[0]), let last = UInt64(ends[1]),
              first <= last, last < UInt64(Int64.max) else { return nil }
        let total = UInt64(extent[1])
        guard extent[1] == "*" || (total != nil && total! > last && total! <= UInt64(Int64.max)) else { return nil }
        return ByteRange(first: first, last: last, total: total)
    }

    private static func failure(_ purpose: String, status: Int, reason: String = "") -> NSError {
        let detail = reason.isEmpty ? "" : " " + reason
        return NSError(domain: errorDomain, code: status, userInfo: [NSLocalizedDescriptionKey:
            "The \(purpose) download could not be completed (HTTP \(status)).\(detail) Retry the operation."])
    }

    /// Used when a caller already has one response. A partial range is never
    /// treated as a whole file; download() can fetch its remaining ranges.
    static func completeSize(at file: URL, response: URLResponse?, purpose: String) throws -> UInt64 {
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard response.statusCode == 200 || response.statusCode == 206 else {
            throw failure(purpose, status: response.statusCode)
        }
        let size = UInt64(max(0, try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0))
        if response.statusCode == 206 {
            guard let range = byteRange(response), range.first == 0, range.total == size, range.count == size else {
                throw failure(purpose, status: 206, reason: "The response did not contain a verified complete file.")
            }
        }
        return size
    }

    @discardableResult
    static func download(from source: URL, to destination: URL, expectedSize: UInt64 = 0,
                         configuration: URLSessionConfiguration, purpose: String,
                         progress: @escaping @Sendable (UInt64, UInt64) -> Void = { _, _ in }) async throws -> UInt64 {
        try Task.checkCancellation()
        let manager = FileManager.default
        guard !manager.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
        let delegate = DownloadDelegate()
        // Classic download tasks deliver didWriteData on this serial delegate
        // queue. The async download(for:delegate:) overlay can consume those
        // callbacks internally instead of forwarding incremental progress.
        let delegateQueue = OperationQueue()
        delegateQueue.name = "MyCloudDriver.media-download"
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.qualityOfService = .userInitiated
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: delegateQueue)
        var ownsDestination = false, complete = false
        defer {
            NativeFileWork.performCancellation { session.invalidateAndCancel() }
            if ownsDestination && !complete { try? manager.removeItem(at: destination) }
        }
        var received: UInt64 = 0
        var total: UInt64? = expectedSize > 0 ? expectedSize : nil
        var validator: (field: String, value: String)?
        var explicitInitialRange = false
        while true {
            try Task.checkCancellation()
            var request = URLRequest(url: source)
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            if received > 0 || explicitInitialRange {
                let end = total.map { received + min($0 - received, chunkSize) - 1 }
                request.setValue("bytes=\(received)-\(end.map(String.init) ?? "")", forHTTPHeaderField: "Range")
                if let validator { request.setValue(validator.value, forHTTPHeaderField: "If-Range") }
            }
            let responseProgress = DownloadProgress(offset: received, total: total, progress: progress)
            // Construct/register before installing cancellation: if a caller
            // cancels before bind(), the existing task can still be cancelled
            // without racing creation against session invalidation.
            let task = session.downloadTask(with: request)
            delegate.register(responseProgress, task: task)
            let (temporary, rawResponse) = try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    responseProgress.install(continuation)
                    responseProgress.bind(task)
                }
            }, onCancel: { responseProgress.cancel() })
            defer { try? manager.removeItem(at: temporary) }
            try Task.checkCancellation()
            guard let response = rawResponse as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard response.statusCode == 200 || response.statusCode == 206 else {
                throw failure(purpose, status: response.statusCode)
            }
            let size = UInt64(max(0, try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0))
            let missingRange = (response.value(forHTTPHeaderField: "Content-Range") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            // A few CDNs label a whole-object GET as 206 without its range
            // header. A trusted metadata size can still verify this whole
            // initial body; an unknown-size or shorter body needs ranges.
            let verifiedWholeBody = response.statusCode == 206 && received == 0
                && missingRange && expectedSize > 0 && size == expectedSize
            if response.statusCode == 200 || verifiedWholeBody {
                // A server may ignore Range or answer If-Range with a fresh
                // whole object. Replace the prefix instead of appending it.
                guard total == nil || size == total else {
                    throw failure(purpose, status: 200, reason: "The file size did not match the expected total.")
                }
                if ownsDestination { try manager.removeItem(at: destination); ownsDestination = false }
                try manager.moveItem(at: temporary, to: destination); ownsDestination = true
                received = size; total = size
            } else {
                // Some servers omit range metadata on an ordinary GET. Ask
                // explicitly once before giving up, never guess its offset.
                guard let range = byteRange(response), range.first == received,
                      range.total != nil || total != nil else {
                    if received == 0 && !explicitInitialRange { explicitInitialRange = true; continue }
                    throw failure(purpose, status: 206, reason: "The server returned a missing or unexpected byte range.")
                }
                guard size > 0, size == range.count else {
                    throw failure(purpose, status: 206, reason: "The response ended before its advertised byte range was complete.")
                }
                if let known = total, let reported = range.total, known != reported {
                    throw failure(purpose, status: 206, reason: "The file size changed between responses.")
                }
                total = range.total ?? total
                guard let length = total, range.last < length else {
                    throw failure(purpose, status: 206, reason: "The byte range exceeded the expected file size.")
                }
                if let validator, let current = response.value(forHTTPHeaderField: validator.field), current != validator.value {
                    throw failure(purpose, status: 206, reason: "The file changed between responses.")
                }
                if validator == nil {
                    if let tag = response.value(forHTTPHeaderField: "ETag"), !tag.hasPrefix("W/") {
                        validator = ("ETag", tag)
                    } else if let date = response.value(forHTTPHeaderField: "Last-Modified") {
                        validator = ("Last-Modified", date)
                    }
                }
                if !ownsDestination {
                    try manager.moveItem(at: temporary, to: destination); ownsDestination = true
                } else {
                    let input = try FileHandle(forReadingFrom: temporary)
                    defer { try? input.close() }
                    let output = try FileHandle(forWritingTo: destination)
                    defer { try? output.close() }
                    guard try output.seekToEnd() == received else { throw CocoaError(.fileReadCorruptFile) }
                    while true {
                        try Task.checkCancellation()
                        guard let bytes = try input.read(upToCount: 1024 * 1024), !bytes.isEmpty else { break }
                        try output.write(contentsOf: bytes)
                    }
                }
                received = range.last + 1
            }
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            progress(received, total ?? 0)
            if received == total {
                try Task.checkCancellation()
                let saved = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard UInt64(max(0, saved)) == received else { throw CocoaError(.fileReadCorruptFile) }
                complete = true
                return received
            }
        }
    }

    /// One session is reused across capped byte-range responses. Its relay
    /// owns each response until didComplete, including cancelled responses.
    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var responses: [Int: DownloadProgress] = [:]
        func register(_ response: DownloadProgress, task: URLSessionDownloadTask) {
            lock.lock(); responses[task.taskIdentifier] = response; lock.unlock()
        }
        private func response(for task: URLSessionTask, removing: Bool = false) -> DownloadProgress? {
            lock.lock(); defer { lock.unlock() }
            return removing ? responses.removeValue(forKey: task.taskIdentifier) : responses[task.taskIdentifier]
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            response(for: downloadTask)?.wrote(downloadTask, totalBytesWritten: totalBytesWritten,
                totalBytesExpectedToWrite: totalBytesExpectedToWrite)
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            response(for: downloadTask)?.downloaded(location, response: downloadTask.response)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            response(for: task, removing: true)?.completed(error: error)
        }
    }

    /// Exactly one result owns the preserved response file. Cancellation can
    /// win before continuation installation, task binding or file movement.
    private final class DownloadProgress: @unchecked Sendable {
        typealias Output = (URL, URLResponse)
        let offset: UInt64
        let total: UInt64?
        let progress: @Sendable (UInt64, UInt64) -> Void
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Output, Error>?
        private var result: Result<Output, Error>?
        private weak var task: URLSessionDownloadTask?
        private var file: Output?
        private var finished = false
        private var lastReport = -TimeInterval.infinity
        init(offset: UInt64, total: UInt64?, progress: @escaping @Sendable (UInt64, UInt64) -> Void) {
            self.offset = offset; self.total = total; self.progress = progress
        }
        func install(_ continuation: CheckedContinuation<Output, Error>) {
            lock.lock()
            if finished {
                let result = result!; self.result = nil; lock.unlock()
                continuation.resume(with: result)
            } else { self.continuation = continuation; lock.unlock() }
        }
        func bind(_ task: URLSessionDownloadTask) {
            lock.lock(); self.task = task; let finished = finished; lock.unlock()
            if finished { NativeFileWork.performCancellation { task.cancel() } }
            else { task.resume() }
        }
        func cancel() {
            finish(.failure(CancellationError()), cancelling: true)
        }
        func downloaded(_ location: URL, response: URLResponse?) {
            lock.lock(); let finished = finished; lock.unlock()
            guard !finished else { return }
            guard let response else { finish(.failure(URLError(.badServerResponse))); return }
            // Foundation deletes location when this callback returns. Move it
            // now on the non-main delegate queue; no staging folder is needed.
            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent("MyCloudDriver-MediaResponse-\(UUID().uuidString)")
            var accepted = false
            defer { if !accepted { NativeFileWork.cleanup(temporary) } }
            do {
                try FileManager.default.moveItem(at: location, to: temporary)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
                lock.lock()
                if !self.finished, file == nil { file = (temporary, response); accepted = true }
                lock.unlock()
            } catch { finish(.failure(error)) }
        }
        func completed(error: Error?) {
            lock.lock(); let file = file; lock.unlock()
            if let error { finish(.failure(error)) }
            else if let file { finish(.success(file)) }
            else { finish(.failure(URLError(.badServerResponse))) }
        }
        private func finish(_ result: Result<Output, Error>, cancelling: Bool = false) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            let continuation = continuation; self.continuation = nil
            if continuation == nil { self.result = result }
            let file = file; self.file = nil
            let task = cancelling ? task : nil; lock.unlock()
            continuation?.resume(with: result)
            if let task { NativeFileWork.performCancellation { task.cancel() } }
            if case .failure = result, let file { NativeFileWork.cleanup(file.0) }
        }
        func wrote(_ downloadTask: URLSessionDownloadTask, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            let now = ProcessInfo.processInfo.systemUptime
            lock.lock()
            guard !finished, now - lastReport >= 0.2 || totalBytesWritten == totalBytesExpectedToWrite else { lock.unlock(); return }
            lastReport = now; lock.unlock()
            let response = downloadTask.response as? HTTPURLResponse
            let base = response?.statusCode == 200 ? 0 : offset
            let (received, overflow) = base.addingReportingOverflow(UInt64(max(0, totalBytesWritten)))
            guard !overflow else { return }
            let length = response.flatMap(MediaFileDownload.byteRange)?.total
                ?? total ?? (response?.statusCode == 200 ? UInt64(max(0, totalBytesExpectedToWrite)) : 0)
            progress(received, length)
        }
    }
}
