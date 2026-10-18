import Foundation

@main struct WorkWakeMonitorTests {
    @MainActor static func blockUIBriefly() { Thread.sleep(forTimeInterval: 0.2) }
    @MainActor static func main() async throws {
        let options = DownloadSleepPrevention.activityOptions(fullWake: true)
        precondition(options.contains(.userInitiated) && options.contains(.idleSystemSleepDisabled)
            && options.contains(.idleDisplaySleepDisabled) && !options.contains(.latencyCritical))
        precondition(DownloadSleepPrevention.activityOptions(fullWake: false) == [.idleSystemSleepDisabled])
        var begins = 0, ends = 0, changes: [Bool] = []
        var helper: DownloadSleepPrevention? = DownloadSleepPrevention(begin: { begins += 1; return NSObject() },
            end: { _ in ends += 1 }, recordActivity: { changes.append($0) })
        for _ in 0..<20 { helper?.setActive(true) }
        precondition(begins == 1 && ends == 0 && changes == [true])
        helper?.setActive(false); helper?.setActive(false)
        precondition(begins == 1 && ends == 1 && changes == [true,false])
        helper?.setActive(true); helper = nil
        precondition(begins == 2 && ends == 2 && changes == [true,false,true,false])
        print("PASS full-wake options prevent idle system/display sleep without latency-critical flags; activity/report ownership is idempotent and balanced")

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("GeneratedWakeMonitor-\(UUID())", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let monitor = FullWakeWorkMonitor(directory: root, processID: 1234, interval: 0.05)
        let first = UUID(), second = UUID()
        let file = root.appendingPathComponent("awake-work-state-v1.json")
        func snapshot() throws -> [String: Any] {
            monitor.waitForPendingWrites()
            return try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        }
        for _ in 0..<20 { monitor.setActive(true, owner: first) }
        monitor.setActive(true, owner: second)
        var row = try snapshot()
        precondition(Set(row.keys) == ["version","app_pid","updated_at","active_work_count"])
        precondition(row["version"] as? Int == 1 && row["app_pid"] as? Int == 1234 && row["active_work_count"] as? Int == 2)
        let initial = row["updated_at"] as! Double
        blockUIBriefly()
        row = try snapshot()
        precondition((row["updated_at"] as! Double) > initial,
            "Full-wake heartbeat must keep updating while the main actor is occupied")
        monitor.setActive(false, owner: first); monitor.setActive(false, owner: first)
        row = try snapshot(); precondition(row["active_work_count"] as? Int == 1)
        monitor.setActive(false, owner: second)
        row = try snapshot(); precondition(row["active_work_count"] as? Int == 0)
        let finished = row["updated_at"] as! Double
        try await Task.sleep(nanoseconds: 150_000_000)
        row = try snapshot(); precondition(row["updated_at"] as? Double == finished)
        let attributes = try fm.attributesOfItem(atPath: file.path)
        precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        print("PASS generated numeric wake heartbeat: independent owners, fresh under UI load, private schema/permissions and stopped after final owner")
    }
}
