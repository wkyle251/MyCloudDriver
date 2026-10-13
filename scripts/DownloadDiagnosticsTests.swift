import Foundation
import Darwin

@main struct DownloadDiagnosticsTests {
    final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_791_504_000)
    }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mycloud-generated-log-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = Clock()
        let store = DownloadDiagnosticsStore(directory: root.appendingPathComponent("rotation"), segmentBytes: 2_048, segments: 3, pendingLimit: 256, clock: { clock.now })
        let privateName = "generated-private-name.bin"
        let id = store.anonymousID(privateName)
        precondition(id.count == 12 && id != privateName)
        for index in 0..<300 {
            clock.now.addTimeInterval(1)
            store.record(.retry, transferID: privateName,
                reason: .classify("503 https://example.invalid/\(privateName)?token=secret"), values: ["attempt": Double(index)])
            if index % 32 == 31 { store.flush() }
        }
        store.flush()
        let files = try FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "jsonl" }
        precondition(files.count <= 3)
        let totalSize = try files.reduce(0) { try $0 + $1.resourceValues(forKeys: [.fileSizeKey]).fileSize! }
        precondition(totalSize <= 6_144)
        for file in files {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize!
            precondition(size <= 2_048)
            let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber
            precondition(mode.intValue & 0o777 == 0o600)
        }
        let text = store.recentText()
        precondition(!text.contains(privateName) && !text.contains("example.invalid") && !text.contains("token") && !text.contains("secret"))
        precondition(text.contains(id) && text.contains("server") && text.contains("299"))
        precondition(store.recentText(maxBytes: 400).utf8.count <= 400)
        let reopened = DownloadDiagnosticsStore(directory: store.directory, segmentBytes: 2_048, segments: 3, clock: { clock.now })
        precondition(reopened.anonymousID(privateName) == id, "Anonymous IDs remain stable after restart")
        reopened.record(.completed, transferID: privateName)
        reopened.flush()
        precondition(reopened.recentText().contains("completed"))

        // An incomplete crash tail must not consume the following valid event.
        let crashRoot = root.appendingPathComponent("crash")
        do {
            let initial = DownloadDiagnosticsStore(directory: crashRoot, clock: { clock.now })
            initial.record(.session); initial.flush()
        }
        let crashFile = try FileManager.default.contentsOfDirectory(at: crashRoot, includingPropertiesForKeys: nil).first { $0.pathExtension == "jsonl" }!
        let tail = try FileHandle(forWritingTo: crashFile)
        try tail.seekToEnd(); try tail.write(contentsOf: Data("{\"partial\":".utf8)); try tail.close()
        let recovered = DownloadDiagnosticsStore(directory: crashRoot, clock: { clock.now })
        recovered.record(.completed); recovered.flush()
        precondition(recovered.recentText().contains("completed") && !recovered.recentText().contains("partial"))

        // Overflow is bounded and explicitly reported, rather than stalling
        // the caller or silently accumulating a week's queue in memory.
        let bounded = DownloadDiagnosticsStore(directory: root.appendingPathComponent("bounded"), pendingLimit: 3)
        for _ in 0..<1_000 { bounded.record(.retry) }
        bounded.flush()
        let overflow = bounded.recentText()
        precondition(overflow.split(separator: "\n").count == 4 && overflow.contains("997") && overflow.contains("dropped_records"))

        // A busy summary has queue counters plus all sixteen storage and scheduling metrics.
        // Rich diagnostic windows must not disappear behind a 96-key ceiling.
        let rich = DownloadDiagnosticsStore(directory: root.appendingPathComponent("rich"))
        let values = Dictionary(uniqueKeysWithValues: (0..<384).map { ("generated_counter_\($0)", Double($0)) })
        rich.record(.downloadWindow, values: values);rich.flush()
        let richRecords = rich.recentText().split(separator: "\n")
        precondition(richRecords.count == 1, "Busy diagnostic windows must be retained")
        let decoder = JSONDecoder();decoder.dateDecodingStrategy = .iso8601
        let richRecord = try decoder.decode(DownloadDiagnosticRecord.self, from: Data(richRecords[0].utf8))
        precondition(richRecord.values == values)
        let tooMany = Dictionary(uniqueKeysWithValues: (0..<385).map { ("generated_counter_\($0)", Double($0)) })
        rich.record(.downloadWindow, values: tooMany);rich.flush()
        precondition(rich.recentText().split(separator: "\n").count == 1, "The diagnostic field count remains bounded")

        // Simulate a continuously running app across nine days. Daily
        // rotation retains only the latest eight days under the byte cap.
        let week = DownloadDiagnosticsStore(directory: root.appendingPathComponent("week"), clock: { clock.now })
        for day in 0..<9 {
            week.record(.downloadWindow, values: ["day": Double(day)]); week.flush()
            clock.now.addTimeInterval(86_400)
        }
        let recent = week.recentText()
        precondition(!recent.contains("\"day\":0") && recent.contains("\"day\":8"))
        let weekFiles = try FileManager.default.contentsOfDirectory(at: week.directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "jsonl" }
        precondition(weekFiles.count == 8)

        var rates = DownloadDiagnosticRates()
        let start = clock.now
        _ = rates.sample(bytes: 0, at: start)
        var bytes: UInt64 = 0; var window: [String:Double]?
        for second in 1...10 {
            bytes += second == 5 ? 0 : 1_048_576
            window = rates.sample(bytes: bytes, at: start.addingTimeInterval(Double(second))) ?? window
        }
        precondition(window?["min_bytes_per_second"] == 0 && window?["max_bytes_per_second"] == 1_048_576)
        precondition(window?["received_bytes"] == 9 * 1_048_576 && window?["seconds"] == 10)
        // Restart and sleep gaps establish a new baseline, not an artificial
        // rate spike or a week of accumulated inactive time.
        precondition(rates.sample(bytes: 0, at: start.addingTimeInterval(11)) == nil)
        precondition(rates.sample(bytes: 100, at: start.addingTimeInterval(100)) == nil)
        // A week's terminal monitoring keeps one tiny snapshot, coalesces a
        // stalled writer, and contains no transfer identity or user strings.
        let live = DownloadDiagnosticsStore(directory: root.appendingPathComponent("live"), clock: { clock.now })
        for index in 0..<10_000 { live.recordLiveSpeed(receivedBytes: UInt64(index), helperPID: 41, uptime: Double(index)) }
        live.flush()
        let liveURL = live.directory.appendingPathComponent("live-speed-v1.json")
        let liveData = try Data(contentsOf: liveURL)
        let speed = try JSONDecoder().decode(DownloadLiveSpeedSnapshot.self, from: liveData)
        precondition(speed.version == 1 && speed.receivedBytes == 9_999 && speed.helperPID == 41)
        precondition(liveData.count <= 512)
        let liveMode = try FileManager.default.attributesOfItem(atPath: liveURL.path)[.posixPermissions] as! NSNumber
        precondition(liveMode.intValue & 0o777 == 0o600)
        let liveFiles = try FileManager.default.contentsOfDirectory(at: live.directory, includingPropertiesForKeys: nil)
        precondition(liveFiles.count == 2,
            "Per-second monitoring must not create per-second history files")
        live.recordLiveSpeed(receivedBytes: 99_999, helperPID: 0, uptime: 10_001)
        live.recordLiveSpeed(receivedBytes: 99_999, helperPID: 41, uptime: .nan)
        live.flush()
        let unchangedLiveData = try Data(contentsOf: liveURL)
        precondition(unchangedLiveData == liveData, "Invalid samples cannot replace a known numeric snapshot")
        live.recordLiveSpeed(receivedBytes: 0, helperPID: 42, uptime: 10_002); live.flush()
        let restarted = try JSONDecoder().decode(DownloadLiveSpeedSnapshot.self, from: Data(contentsOf: liveURL))
        precondition(restarted.helperPID == 42 && restarted.receivedBytes == 0, "Helper restarts are explicit and never imply a speed spike")
        for index in 0..<1_000 {
            live.recordMonitor(values: ["downloaded_bytes": Double(index), "ram_limit_bytes": 8_589_934_592,
                "generated-private-name.bin": 123, "invalid_number": .nan, "negative": -1], helperPID: 42)
        }
        live.flush()
        let monitorURL = live.directory.appendingPathComponent("monitor-state-v1.json")
        let monitorData = try Data(contentsOf: monitorURL)
        let monitor = try JSONDecoder().decode(DownloadMonitorSnapshot.self, from: monitorData)
        precondition(monitor.version == 1 && monitor.helperPID == 42 && monitor.values["downloaded_bytes"] == 999)
        precondition(monitor.values.count == 2 && monitorData.count <= 16_384)
        precondition(!String(decoding: monitorData, as: UTF8.self).contains(privateName))
        let monitorMode = try FileManager.default.attributesOfItem(atPath: monitorURL.path)[.posixPermissions] as! NSNumber
        precondition(monitorMode.intValue & 0o777 == 0o600)
        live.recordMonitor(values: ["downloaded_bytes": 1], helperPID: 0)
        live.recordMonitor(values: Dictionary(uniqueKeysWithValues: (0..<193).map { ("counter_\($0)", Double($0)) }), helperPID: 42)
        live.flush()
        let unchangedMonitorData = try Data(contentsOf: monitorURL)
        precondition(unchangedMonitorData == monitorData, "Invalid dashboard snapshots must not replace the known state")
        var receiveValues = Dictionary(uniqueKeysWithValues: DownloadReceiveDiagnostics.keys.map { ($0, 1.0) })
        receiveValues["connection_known_cooldown_remaining_ms"] = 12_345
        let richMonitor = receiveValues.merging(Dictionary(uniqueKeysWithValues: (0..<80).map { ("generated_\($0)", Double($0)) })) { a, _ in a }
        live.recordMonitor(values: richMonitor, helperPID: 42); live.flush()
        let richMonitorData = try Data(contentsOf: monitorURL)
        precondition(richMonitorData.count <= 16_384)
        let decodedRichMonitor = try JSONDecoder().decode(DownloadMonitorSnapshot.self, from: richMonitorData)
        precondition(decodedRichMonitor.values == richMonitor)
        rich.record(.downloadWindow, values: receiveValues); rich.flush()
        precondition(rich.recentText().contains("payload_range_validation") && rich.recentText().contains("connection_shared_slots_active"))
        let summary = DownloadReceiveDiagnostics.summary(receiveValues)
        precondition(summary.contains("CDN cooldown 12s") && summary.contains("RAM waits body/shared/pressure 1/1/1"))
        precondition(summary.contains("connection waits budget/endpoint/shared 1/1/1") && !summary.contains(privateName))
        print("PASS anonymous diagnostics: rotation/size/age caps, bounded overflow, restart IDs, private permissions, crash tails, one-second stalls and counter resets")
        print("PASS live speed: bounded latest-only snapshot, private permissions, coalescing, invalid sample rejection and helper restart")
        print("PASS live dashboard: separate bounded numeric snapshot, coalescing, private permissions and invalid input rejection")
    }
}
