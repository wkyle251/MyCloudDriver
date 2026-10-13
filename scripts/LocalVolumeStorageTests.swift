import Foundation

private final class ReadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func record(_ url: URL) { lock.lock(); urls.append(url); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return urls.count }
}

@main struct LocalVolumeStorageTests {
    static let gDrive = LocalVolumeCapacity(name: "G-DRIVE", total: 4_000, available: 1_000)
    static let backup = LocalVolumeCapacity(name: "Backup", total: 500, available: 450)

    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let disk = LocalVolumeCapacity(name: " G-DRIVE \n", total: 4_000, available: 1_000)!
        precondition(disk.name == "G-DRIVE" && disk.used == 3_000 && disk.available == 1_000 && disk.usedFraction == 0.75)
        precondition(LocalVolumeCapacity(name: "  ", total: 10, available: 4)!.name == nil)
        precondition(LocalVolumeCapacity(name: nil, total: 10, available: 20)!.used == 0,
            "Available space beyond the total is capped, so used never wraps")
        precondition(LocalVolumeCapacity(name: nil, total: 10, available: 0)!.usedFraction == 1)
        let invalid: [(Int64?, Int64?)] = [(nil, 5), (0, 0), (-1, 0), (10, nil), (10, -1)]
        for (total, available) in invalid {
            precondition(LocalVolumeCapacity(name: "X", total: total, available: available) == nil,
                "A disk that reports no size must read as unavailable, not as an empty disk")
        }
        print("PASS capacity value: used, fraction, name trimming, capping and rejection of missing or negative sizes")

        let temporary = LocalVolumeCapacityReader.read(FileManager.default.temporaryDirectory)
        precondition(temporary != nil && temporary!.total > 0 && temporary!.available <= temporary!.total,
            "A real folder reports the capacity of the volume that holds it")
        precondition(LocalVolumeCapacityReader.read(URL(fileURLWithPath: "/nonexistent/MyCloudDriver-capacity-test")) == nil)
        print("PASS reader: real volume capacity and a missing folder")

        let a = URL(fileURLWithPath: "/Volumes/G-DRIVE"), b = URL(fileURLWithPath: "/Volumes/Backup")
        let reads = ReadLog()
        let model = LocalVolumeStorageModel(read: { url in
            reads.record(url)
            return url == a ? Self.gDrive : Self.backup
        })
        let first = model.refresh(for: a)
        precondition(model.isRefreshing)
        await first?.value
        precondition(model.capacity == Self.gDrive && model.checkedAt != nil && !model.isRefreshing)
        let again = model.refresh(for: a)
        precondition(model.capacity == Self.gDrive && model.isRefreshing,
            "Refreshing the same disk keeps its numbers visible instead of flickering")
        await again?.value
        await model.refresh(for: b)?.value
        precondition(model.capacity == Self.backup && reads.count == 3)
        print("PASS model: refresh publishes capacity, keeps it during a same-disk refresh and follows a new disk")

        let slow = LocalVolumeStorageModel(read: { url in
            if url == a { Thread.sleep(forTimeInterval: 0.15); return Self.gDrive }
            return Self.backup
        })
        let older = slow.refresh(for: a)
        let newer = slow.refresh(for: b)
        precondition(slow.capacity == nil, "Switching disks drops the previous disk's numbers at once")
        await newer?.value; await older?.value
        precondition(slow.capacity == Self.backup && !slow.isRefreshing,
            "A slow read for the previous disk must not replace the newer disk's capacity")
        print("PASS model: a late result for a previous disk is discarded")

        let pending = LocalVolumeStorageModel(read: { _ in Thread.sleep(forTimeInterval: 0.1); return Self.gDrive })
        let request = pending.refresh(for: a)
        pending.clear()
        precondition(pending.capacity == nil && !pending.isRefreshing)
        await request?.value
        precondition(pending.capacity == nil && pending.checkedAt == nil && !pending.isRefreshing,
            "A read that finishes after clear() must not bring the numbers back")
        _ = model.refresh(for: nil)
        precondition(model.capacity == nil && model.checkedAt == nil && !model.isRefreshing)
        print("PASS model: clear() and a missing folder discard in-flight and published capacity")

        let unreadable = LocalVolumeStorageModel(read: { _ in nil })
        await unreadable.refresh(for: a)?.value
        precondition(unreadable.capacity == nil && !unreadable.isRefreshing && unreadable.checkedAt != nil,
            "An unreadable disk ends as unavailable rather than staying in a checking state")
        print("PASS model: an unreadable disk reports unavailable")
    }
}
