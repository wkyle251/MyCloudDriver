import Foundation

@main struct DownloadReadQueueTests {
    static func main() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let legacy = Data(#"{"pending_read_bytes":20,"reading_bytes":80,"pending_read_tasks":2,"reading_tasks":8,"read_drives":1,"write_drives":0,"batch_remaining_bytes":80,"active_read_tasks":1,"active_read_bytes":30}"#.utf8)
        let old = try decoder.decode(DownloadDiskTraffic.self, from: legacy)
        precondition(old.waitingCheckCount == 9 && old.waitingCheckBytes == 70,
                     "Selected checks must remain queued when an older helper reports only one active read")
        var values = try JSONSerialization.jsonObject(with: legacy) as! [String: Any]
        values["waiting_read_tasks"] = 8
        values["waiting_read_bytes"] = 65
        values["oldest_waiting_read_ms"] = 90_000
        values["read_turn_latency_handoffs"] = 4
        values["active_read_tasks"] = 2 // Includes a replay reader outside the check queue.
        let fresh = try decoder.decode(DownloadDiskTraffic.self, from: JSONSerialization.data(withJSONObject: values))
        precondition(fresh.waitingCheckCount == 8 && fresh.waitingCheckBytes == 65,
                     "Authoritative waiting counters must not subtract unrelated replay readers")
        precondition(fresh.oldestWaitingReadMs == 90_000)
        precondition(fresh.readTurnLatencyHandoffs == 4)
        var boundedTurn = fresh
        boundedTurn.turnElapsedMs = 9_000; boundedTurn.turnTargetMs = 10_000
        boundedTurn.readWriteThresholdPercent = 80
        boundedTurn.lastReadHandoverReason = 7
        precondition(boundedTurn.turnSummary?.contains("write batch after 10s") == true)
        precondition(boundedTurn.lastReadHandoverSummary?.contains("read-turn limit") == true)
        values.removeValue(forKey: "waiting_read_tasks")
        values.removeValue(forKey: "waiting_read_bytes")
        values["active_read_bytes"] = 200
        let bounded = try decoder.decode(DownloadDiskTraffic.self, from: JSONSerialization.data(withJSONObject: values))
        precondition(bounded.waitingCheckBytes == 0, "Mixed-version snapshots must not underflow")
        print("Download read queue: selected/active separation, replay reads, wait age and legacy compatibility passed")
    }
}
