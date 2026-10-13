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
        let session = URLSession(configuration: configuration)
        var ownsDestination = false, complete = false
        defer {
            session.invalidateAndCancel()
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
            let delegate = DownloadProgress(offset: received, total: total, progress: progress)
            let (temporary, rawResponse) = try await session.download(for: request, delegate: delegate)
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

    private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let offset: UInt64
        let total: UInt64?
        let progress: @Sendable (UInt64, UInt64) -> Void
        private var lastReport = -TimeInterval.infinity
        init(offset: UInt64, total: UInt64?, progress: @escaping @Sendable (UInt64, UInt64) -> Void) {
            self.offset = offset; self.total = total; self.progress = progress
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastReport >= 0.2 || totalBytesWritten == totalBytesExpectedToWrite else { return }
            lastReport = now
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
