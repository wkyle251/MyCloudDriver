import Foundation
import CryptoKit

/// Only structured counters enter the saved log. Ordinary helper text can
/// contain a user's filenames, paths or signed URLs and is never persisted here.
struct DownloadDiagnosticMetric: Decodable {
    let count: UInt64
    let bytes: UInt64
    let elapsedMs: UInt64
    let maxMs: UInt64
    let failed: UInt64
    let active: UInt64?
    let transferId: String?
}

enum DownloadDiagnosticReason: String, Codable {
    case scheduled, storage, rateLimited = "rate_limited", server, timeout, connection, authentication, source
    static func classify(_ text: String?, storage: Bool = false, permanent: Bool = false) -> Self {
        if storage { return .storage }; if permanent { return .source }
        guard let text = text?.lowercased() else { return .scheduled }
        if text.contains("429") || text.contains("too many requests") { return .rateLimited }
        if text.contains("timed out") || text.contains("timeout") { return .timeout }
        if text.contains("503") || text.contains("502") || text.contains("504") { return .server }
        if text.contains("401") || text.contains("sign in") { return .authentication }
        if text.contains("connection") || text.contains("socket") || text.contains("stream interrupted") { return .connection }
        return .scheduled
    }
}

enum DownloadReceiveDiagnostics {
    static let waits = ["ram_body_limit", "ram_shared_limit", "ram_pressure", "connection_budget",
                        "connection_cooldown", "connection_endpoint_capacity", "connection_shared_slots"]
    static let counters = ["payload_timeout", "payload_connection", "payload_range_validation", "payload_io",
        "payload_interrupted", "payload_unavailable", "payload_streaming_fallback", "payload_early_empty_retry",
        "payload_deferred_rearm", "payload_http_success", "payload_http_429", "payload_http_5xx", "payload_http_auth",
        "payload_http_416", "payload_http_other", "connection_budget_blocked_polls", "connection_cooldown_blocked_polls",
        "connection_endpoint_blocked_polls", "connection_shared_blocked_polls", "connection_cooldown_events",
        "connection_known_cooldown_remaining_ms"]
    static let keys: Set<String> = Set(counters + waits.flatMap { name in
        ["count", "active", "total_ms", "max_ms", "oldest_ms"].map { name + "_" + $0 }
    })

    static func summary(_ values: [String: Double]) -> String {
        func count(_ key: String) -> Int { Int(values[key] ?? 0) }
        let ram = "RAM waits body/shared/pressure \(count("ram_body_limit_active"))/\(count("ram_shared_limit_active"))/\(count("ram_pressure_active"))"
        let connection = "connection waits budget/endpoint/shared \(count("connection_budget_active"))/\(count("connection_endpoint_capacity_active"))/\(count("connection_shared_slots_active"))"
        let cooldown = "CDN cooldown \(count("connection_known_cooldown_remaining_ms") / 1_000)s"
        let failures = "payload totals timeout/connection/429/5xx \(count("payload_timeout"))/\(count("payload_connection"))/\(count("payload_http_429"))/\(count("payload_http_5xx"))"
        let recovery = "recovery totals stream/retry/rearm \(count("payload_streaming_fallback"))/\(count("payload_early_empty_retry"))/\(count("payload_deferred_rearm"))"
        let validation = "payload totals range/auth/416 \(count("payload_range_validation"))/\(count("payload_http_auth"))/\(count("payload_http_416"))"
        return [ram, connection, cooldown, failures, validation, recovery].joined(separator: "; ")
    }
}

struct DownloadDiagnosticRecord: Codable {
    enum Event: String, Codable {
        case session, downloadWindow = "download_window", retry, completed, failed
        case storageWindow = "storage_window", slowOperation = "slow_operation"
        case droppedRecords = "dropped_records"
    }
    var timestamp: Date
    var session: UUID
    var event: Event
    var transfer: String?
    var reason: DownloadDiagnosticReason? = nil
    var values: [String: Double]
}

struct DownloadLiveSpeedSnapshot: Codable {
    var version = 1
    var helperPID: Int32
    var receivedBytes: UInt64
    var sampledUptime: TimeInterval
    var updatedAt: TimeInterval
    enum CodingKeys: String, CodingKey {
        case version, helperPID = "helper_pid", receivedBytes = "received_bytes"
        case sampledUptime = "sampled_uptime", updatedAt = "updated_at"
    }
}

/// Aggregate dashboard state only. This is separate from live-speed-v1 so
/// existing rate monitors retain their strict, small numeric schema.
struct DownloadMonitorSnapshot: Codable {
    var version = 1
    var helperPID: Int32
    var updatedAt: TimeInterval
    var values: [String: Double]
    enum CodingKeys: String, CodingKey {
        case version, helperPID = "helper_pid", updatedAt = "updated_at", values
    }
}

/// One writer shared by every window. An unavailable/slow log disk cannot
/// block transfers or grow an unbounded queue. Logs are disposable diagnostics:
/// batch writes run on a utility queue without drive-cache flushes.
final class DownloadDiagnosticsStore: @unchecked Sendable {
    static let shared = DownloadDiagnosticsStore()
    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MyCloudDriver/Downloads", isDirectory: true)
    }
    let directory: URL
    let session = UUID()
    private let key: SymmetricKey
    private let queue = DispatchQueue(label: "com.wky.MyCloudDriver.download-diagnostics", qos: .utility)
    private let lock = NSLock()
    private var pending: [DownloadDiagnosticRecord] = []
    private var pendingSpeed: DownloadLiveSpeedSnapshot?
    private var pendingMonitor: DownloadMonitorSnapshot?
    private var dropped: UInt64 = 0
    private var scheduled = false
    private var failures: UInt64 = 0
    private var handle: FileHandle?
    private var currentURL: URL?
    private var currentBytes = 0
    private let segmentBytes: Int
    private let segments: Int
    private let retentionDays: Int
    private let pendingLimit: Int
    private let clock: @Sendable () -> Date

    init(directory: URL = defaultDirectory, segmentBytes: Int = 16 * 1_024 * 1_024,
         segments: Int = 8, retentionDays: Int = 8, pendingLimit: Int = 256,
         clock: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.segmentBytes = max(512, segmentBytes)
        self.segments = max(1, segments)
        self.retentionDays = max(1, retentionDays)
        self.pendingLimit = max(1, pendingLimit)
        self.clock = clock
        // Stable opaque identifiers across app restarts, private to this Mac.
        // The key is never included in copied logs.
        let keyURL = directory.appendingPathComponent("identity-key")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if let data = try? Data(contentsOf: keyURL), data.count == 32 {
            self.key = SymmetricKey(data: data)
        } else {
            let key = SymmetricKey(size: .bits256)
            self.key = key
            let data = key.withUnsafeBytes { Data($0) }
            try? data.write(to: keyURL, options: .atomic)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
    }

    deinit { try? handle?.close() }

    func anonymousID(_ transfer: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(transfer.utf8), using: key)
            .prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    var writeFailureCount: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return failures
    }

    func record(_ event: DownloadDiagnosticRecord.Event, transferID: String? = nil,
                reason: DownloadDiagnosticReason? = nil, values: [String: Double] = [:], at date: Date? = nil) {
        // Fixed keys supplied by callers; no arbitrary messages are accepted.
        let values = values.filter { key, value in
            key.count <= 64 && value.isFinite && key.range(of: "^[a-z][a-z0-9_]*$", options: .regularExpression) != nil
        }
        // Queue counters plus storage and scheduling metrics can exceed 96 fields.
        // Keep rich windows while retaining fixed key/record/segment bounds.
        guard values.count <= 384 else { return }
        let record = DownloadDiagnosticRecord(timestamp: date ?? clock(), session: session,
            event: event, transfer: transferID.map(anonymousID), reason: reason, values: values)
        lock.lock()
        if pending.count < pendingLimit { pending.append(record) } else { dropped &+= 1 }
        let start = !scheduled
        scheduled = true
        lock.unlock()
        if start { queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.drain() } }
    }

    /// One disposable, numeric snapshot for terminal monitoring. Share the
    /// asynchronous writer and coalesce to the latest value if storage stalls.
    /// No process/socket enumeration or unbounded per-second history is needed.
    func recordLiveSpeed(receivedBytes: UInt64, helperPID: Int32,
                         uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let updated = clock().timeIntervalSince1970
        guard helperPID > 0, uptime.isFinite, uptime >= 0, updated.isFinite else { return }
        let speed = DownloadLiveSpeedSnapshot(helperPID: helperPID, receivedBytes: receivedBytes,
            sampledUptime: uptime, updatedAt: updated)
        lock.lock()
        pendingSpeed = speed
        let start = !scheduled
        scheduled = true
        lock.unlock()
        if start { queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.drain() } }
    }

    /// Coalesced and disposable: monitoring never waits for storage or retains
    /// per-file identities. Callers provide fixed keys and numeric aggregates.
    func recordMonitor(values: [String: Double], helperPID: Int32) {
        let updated = clock().timeIntervalSince1970
        guard helperPID > 0, updated.isFinite, values.count <= 192 else { return }
        let clean = values.filter { key, value in
            value.isFinite && value >= 0 && key.count <= 64
                && key.range(of: "^[a-z][a-z0-9_]*$", options: .regularExpression) != nil
        }
        let snapshot = DownloadMonitorSnapshot(helperPID: helperPID, updatedAt: updated, values: clean)
        lock.lock()
        pendingMonitor = snapshot
        let start = !scheduled
        scheduled = true
        lock.unlock()
        if start { queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.drain() } }
    }

    /// Used when copying a bounded tail and in tests. The transfer path only
    /// calls record(), which never waits for disk I/O.
    func flush() { queue.sync { drain() } }

    private func drain() {
        lock.lock()
        var records = pending
        pending.removeAll(keepingCapacity: true)
        let speed = pendingSpeed; pendingSpeed = nil
        let monitor = pendingMonitor; pendingMonitor = nil
        let lost = dropped; dropped = 0; scheduled = false
        lock.unlock()
        if lost > 0 {
            records.append(.init(timestamp: clock(), session: session, event: .droppedRecords,
                transfer: nil, values: ["count": Double(lost)]))
        }
        guard !records.isEmpty || speed != nil || monitor != nil else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            if let speed {
                let data = try encoder.encode(speed)
                guard data.count <= 512 else { return }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                let url = directory.appendingPathComponent("live-speed-v1.json")
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            if let monitor {
                let data = try encoder.encode(monitor)
                if data.count <= 16_384 {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700])
                    let url = directory.appendingPathComponent("monitor-state-v1.json")
                    try data.write(to: url, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                }
            }
            // One coalesced write per batch/segment, rather than per event.
            var batch = Data()
            for record in records {
                var line = try encoder.encode(record)
                line.append(0x0A)
                guard line.count <= min(segmentBytes, 16_384) else { continue }
                if handle == nil || !isToday(currentURL) || currentBytes + batch.count + line.count > segmentBytes {
                    if !batch.isEmpty { try handle?.write(contentsOf: batch); currentBytes += batch.count; batch.removeAll(keepingCapacity: true) }
                    try selectSegment(required: line.count)
                }
                batch.append(line)
            }
            if !batch.isEmpty { try handle?.write(contentsOf: batch); currentBytes += batch.count }
        } catch {
            try? handle?.close(); handle = nil; currentURL = nil; currentBytes = 0
            lock.lock(); failures &+= 1; lock.unlock()
        }
    }

    private func day(_ date: Date) -> String {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withFullDate]
        format.timeZone = TimeZone(secondsFromGMT: 0)
        return String(format.string(from: date).prefix(10))
    }
    private func isToday(_ url: URL?) -> Bool { url?.lastPathComponent.hasPrefix("downloads-" + day(clock()) + "-") == true }
    private func stamp() -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX"); format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "yyyy-MM-dd-HHmmssSSS"
        return format.string(from: clock())
    }
    private func logFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .creationDateKey])
            .filter { url in
                guard url.lastPathComponent.range(of: "^downloads-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{9}-[A-Fa-f0-9-]{36}\\.jsonl$", options: .regularExpression) != nil,
                      let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
                return info.isRegularFile == true && info.isSymbolicLink != true
            }.sorted {
                let lhs = String($0.lastPathComponent.prefix(19)), rhs = String($1.lastPathComponent.prefix(19))
                if lhs != rhs { return lhs < rhs }
                let leftDate = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let rightDate = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return leftDate == rightDate ? $0.lastPathComponent < $1.lastPathComponent : leftDate < rightDate
            }
    }
    private func selectSegment(required: Int) throws {
        try handle?.close(); handle = nil
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let oldest = day(clock().addingTimeInterval(-Double(retentionDays - 1) * 86_400))
        var files = try logFiles()
        for url in files where String(url.lastPathComponent.dropFirst(10).prefix(10)) < oldest { try manager.removeItem(at: url) }
        files = try logFiles()
        // Reuse the same day's tail after restart; repeated launches do not
        // consume the eight-file history by creating almost-empty segments.
        if let last = files.last, isToday(last), last.path != currentURL?.path,
           let size = try last.resourceValues(forKeys: [.fileSizeKey]).fileSize, size + required + 1 <= segmentBytes {
            currentURL = last; currentBytes = size
        } else {
            while files.count >= segments { try manager.removeItem(at: files.removeFirst()) }
            currentURL = directory.appendingPathComponent("downloads-\(stamp())-\(UUID().uuidString).jsonl")
            guard manager.createFile(atPath: currentURL!.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            currentBytes = 0
        }
        // Also bound pre-existing segments if the configured cap changed.
        files = try logFiles()
        while files.count > segments {
            guard let index = files.firstIndex(where: { $0.lastPathComponent != currentURL?.lastPathComponent }) else { break }
            try manager.removeItem(at: files.remove(at: index))
        }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: currentURL!.path)
        handle = try FileHandle(forWritingTo: currentURL!)
        try handle?.seekToEnd()
        // A crash may leave a partial last line. Isolate it from the next valid
        // record so the bounded reader can discard only that partial line.
        if currentBytes > 0, let reader = try? FileHandle(forReadingFrom: currentURL!) {
            defer { try? reader.close() }
            try reader.seek(toOffset: UInt64(currentBytes - 1))
            if try reader.read(upToCount: 1) != Data([0x0A]) {
                try handle?.write(contentsOf: Data([0x0A])); currentBytes += 1
            }
        }
    }

    /// Read at most 512 KiB; skip an incomplete crash-tail JSON record. Never
    /// load a week's history into RAM or enumerate a download destination.
    func recentText(maxBytes: Int = 512 * 1_024) -> String {
        queue.sync {
            drain()
            let cap = max(0, min(maxBytes, 512 * 1_024))
            var remaining = cap
            var records: [String] = []
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            for url in ((try? logFiles()) ?? []).reversed() where remaining > 0 {
                guard let reader = try? FileHandle(forReadingFrom: url) else { continue }
                defer { try? reader.close() }
                guard let end = try? reader.seekToEnd() else { continue }
                let take = min(UInt64(remaining), end)
                try? reader.seek(toOffset: end - take)
                guard let data = try? reader.read(upToCount: Int(take)) else { continue }
                remaining -= data.count
                let valid = String(decoding: data, as: UTF8.self).split(separator: "\n").filter {
                    (try? decoder.decode(DownloadDiagnosticRecord.self, from: Data($0.utf8))) != nil
                }.map(String.init)
                records.insert(contentsOf: valid, at: 0)
            }
            return records.joined(separator: "\n") + (records.isEmpty ? "" : "\n")
        }
    }
}

/// Real elapsed-time rates, not a moving average. The diagnostic window keeps
/// one-second minima/maxima so a short stall is visible after a week of uptime.
struct DownloadDiagnosticRates {
    private var previous: (UInt64, Date)?
    private var totalBytes: UInt64 = 0
    private var seconds: Double = 0
    private var minimum = Double.infinity
    private var maximum: Double = 0
    private var samples = 0

    mutating func sample(bytes: UInt64, at now: Date) -> [String: Double]? {
        defer { previous = (bytes, now) }
        guard let (old, time) = previous, bytes >= old else {
            totalBytes = 0; seconds = 0; samples = 0; minimum = .infinity; maximum = 0
            return nil
        }
        let elapsed = now.timeIntervalSince(time)
        guard elapsed > 0, elapsed <= 5 else { totalBytes = 0; seconds = 0; samples = 0; minimum = .infinity; maximum = 0; return nil }
        let delta = bytes - old
        let rate = Double(delta) / elapsed
        totalBytes += delta; seconds += elapsed; samples += 1
        minimum = min(minimum, rate); maximum = max(maximum, rate)
        guard seconds >= 9.5 else { return nil }
        let result = ["received_bytes": Double(totalBytes), "seconds": seconds, "bytes_per_second": Double(totalBytes) / seconds,
                      "min_bytes_per_second": minimum, "max_bytes_per_second": maximum, "samples": Double(samples)]
        totalBytes = 0; seconds = 0; samples = 0; minimum = .infinity; maximum = 0
        return result
    }
}
