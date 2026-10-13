import Foundation

/// Generated counters and SMART pages only. --sample reads real kernel metrics
/// and sensor pages, never file contents, directory listings or account data.
@main struct DiskResourceMonitorTests {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    static func disk(_ id: UInt64 = 1, read: UInt64? = 0, write: UInt64? = 0) -> TaskDiskSample {
        .init(id: id, deviceID: id + 100, name: "Generated drive", device: "disk9", location: "External",
              interconnect: "USB", medium: "HDD", readBytes: read, writtenBytes: write)
    }

    static func page(_ attributes: [(UInt8, UInt8)]) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: 512)
        data[0] = 1
        for (index, attribute) in attributes.enumerated() {
            data[2 + index * 12] = attribute.0
            data[7 + index * 12] = attribute.1
        }
        data[511] = 0 &- data.reduce(UInt8(0), &+)
        return data
    }

    @MainActor static func main() async throws {
        var accumulator = TaskDiskAccumulator()
        let baseline = accumulator.update([disk(read: 100, write: 200)], at: 1)[0]
        require(baseline.readBytesPerSecond == nil && baseline.writtenBytesPerSecond == nil, "A new disk needs two measurements")
        let busy = accumulator.update([disk(read: 100 + 62 * 1_048_576, write: 200 + 50 * 1_048_576)], at: 3)[0]
        require(busy.readBytesPerSecond == 31 * 1_048_576 && busy.writtenBytesPerSecond == 25 * 1_048_576,
                "Rates must use actual elapsed time and binary MiB units")
        require(TaskDiskRate.text(busy.readBytesPerSecond) == "31.00 MiB/s", "Display units must match the measurement")
        let idle = accumulator.update([busy.sample], at: 5)[0]
        require(idle.readBytesPerSecond == 0 && idle.writtenBytesPerSecond == 0, "A measured idle disk must show zero")
        let reset = accumulator.update([disk(read: 10, write: 20)], at: 7)[0]
        require(reset.readBytesPerSecond == nil && reset.writtenBytesPerSecond == nil, "Counter resets must not become spikes")
        let resumed = accumulator.update([disk(read: 30, write: 60)], at: 9)[0]
        require(resumed.readBytesPerSecond == 10 && resumed.writtenBytesPerSecond == 20, "A reset counter must recover on its next measurement")
        require(accumulator.update([disk(read: 40, write: 70)], at: 30)[0].readBytesPerSecond == nil, "Wake from sleep needs a fresh baseline")
        require(accumulator.update([], at: 32).isEmpty, "Disconnected drives must disappear")
        require(accumulator.update([disk(read: 100, write: 200)], at: 34)[0].readBytesPerSecond == nil, "Reconnection must not reuse a disconnected sample")
        let replacement = accumulator.update([disk(2, read: 10_000, write: 20_000)], at: 36)[0]
        require(replacement.readBytesPerSecond == nil, "A different drive with the same BSD name needs its own baseline")
        let missing = accumulator.update([disk(2, read: nil, write: 20_000)], at: 38)[0]
        require(missing.readBytesPerSecond == nil && missing.writtenBytesPerSecond == 0, "Missing counters must not masquerade as idle")
        require(accumulator.update([disk(2, read: 50, write: 20_000)], at: 40)[0].readBytesPerSecond == nil, "A recovered counter needs a baseline")
        for interval in [0, -1, 11, Double.nan, Double.infinity, 1e-310] {
            require(TaskDiskRate.bytesPerSecond(UInt64.max, previous: 0, elapsed: interval) == nil, "Invalid intervals must never produce a rate")
        }
        require(TaskDiskRate.bytesPerSecond(UInt64.max, previous: UInt64.max - 8, elapsed: 2) == 4,
                "Large cumulative counters must retain small exact deltas")
        for invalid in [-1, true, "123", 12.5, Double.nan, Double.infinity] as [Any] {
            require(TaskDiskSampler.counter(invalid) == nil, "Malformed kernel counters must stay unavailable")
        }
        require(TaskDiskSampler.counter(NSNumber(value: UInt64.max)) == UInt64.max, "Unsigned kernel counters must not overflow")
        require(TaskDiskSampler.counter(NSNumber(value: 0)) == 0, "Zero is a valid cumulative counter")
        print("PASS live disk rates: measured intervals, idle, counter reset, sleep, disconnect, replacement and unavailable counters")

        let source = DownloadRateFixture()
        let monitor = DownloadDiskRateMonitor(sample: { source.sample() }, resolve: { _ in 102 }, intervalNanoseconds: 20_000_000)
        let watch = Task { await monitor.watch(destination: URL(fileURLWithPath: "/generated-destination")) }
        for _ in 0..<100 where monitor.usage?.readBytesPerSecond == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        require(monitor.usage?.sample.deviceID == 102 && (monitor.usage?.readBytesPerSecond ?? 0) > 0,
                "The dashboard must select the physical destination, never sum unrelated disks")
        let beforeBusyInterface = source.calls
        // Deliberately occupy the UI thread, as a restored queue did. Kernel
        // sampling must continue and retain only the newest completed sample.
        func occupyInterface() { Thread.sleep(forTimeInterval: 0.15) }
        occupyInterface()
        require(source.calls >= beforeBusyInterface + 3, "A busy interface must not stop destination disk sampling")
        try await Task.sleep(nanoseconds: 30_000_000)
        require((monitor.usage?.readBytesPerSecond ?? 0) > 0, "The latest valid disk rate must survive a busy interface")
        watch.cancel(); await watch.value
        require(monitor.usage == nil, "Hidden dashboards must clear stale live rates")
        let stoppedCalls = source.calls
        try await Task.sleep(nanoseconds: 60_000_000)
        require(source.calls == stoppedCalls, "Hidden dashboards must stop sampling")
        let unavailable = DownloadDiskRateMonitor(sample: { source.sample() }, resolve: { _ in nil }, intervalNanoseconds: 20_000_000)
        let unknownWatch = Task { await unavailable.watch(destination: URL(fileURLWithPath: "/generated-network-destination")) }
        try await Task.sleep(nanoseconds: 60_000_000)
        require(unavailable.usage == nil, "An unknown or network destination must not display another disk's rates")
        unknownWatch.cancel(); await unknownWatch.value
        print("PASS download dashboard rates: physical destination selection, sampling during a busy interface, unavailable destinations, cancellation and no hidden polling")

        require(TaskDiskTemperatureSampler.celsius(from: page([(194, 64)])) == 64, "ATA temperature must use the raw Celsius value")
        require(TaskDiskTemperatureSampler.celsius(from: page([(190, 41), (194, 48)])) == 48, "Prefer the drive temperature over airflow")
        require(TaskDiskTemperatureSampler.celsius(from: page([(190, 41)])) == 41, "Airflow can supply a fallback temperature")
        for attributes: [(UInt8, UInt8)] in [[], [(194, 0)], [(194, 255)], [(1, 42)]] {
            require(TaskDiskTemperatureSampler.celsius(from: page(attributes)) == nil, "Missing/invalid temperature must stay unavailable")
        }
        var corrupt = page([(194, 64)]); corrupt[20] ^= 1
        require(TaskDiskTemperatureSampler.celsius(from: corrupt) == nil, "Reject a bad SMART checksum")
        require(TaskDiskTemperatureSampler.celsius(from: [UInt8](repeating: 0, count: 511)) == nil, "Reject truncated SMART data")
        require(abs(TaskDiskTemperatureSampler.celsius(kelvin: 310)! - 36.85) < 1e-10, "NVMe temperatures must convert from Kelvin")
        require(TaskDiskTemperatureSampler.celsius(kelvin: 0) == nil && TaskDiskTemperatureSampler.celsius(kelvin: .max) == nil,
                "Unspecified/invalid NVMe temperatures must stay unavailable")
        let measured = Date(timeIntervalSince1970: 1_000)
        let temperature = TaskDiskTemperature(celsius: 64, measuredAt: measured)
        require(temperature.text(at: measured.addingTimeInterval(30)) == "64°C", "A fresh sensor value should display")
        require(temperature.text(at: measured.addingTimeInterval(65)) == "64°C · cached", "Old sensor values must be explicitly marked cached")
        require(temperature.text(at: measured.addingTimeInterval(300)) == "Unavailable", "Cached readings must expire after five minutes")
        require(temperature.text(at: measured.addingTimeInterval(-1)) == "Unavailable", "Clock rollback must not preserve a future sample")
        require(TaskDiskTemperature(celsius: .nan, measuredAt: measured).text(at: measured) == "Unavailable", "Malformed temperatures must not display")
        print("PASS temperature: ATA attributes and checksum, NVMe Kelvin conversion, unsupported sensors and stale values")

        var cache = TaskDiskTemperatureCache()
        let failed = TaskDiskTemperature(celsius: nil, measuredAt: measured.addingTimeInterval(30), issue: "Sensor busy.")
        cache.update([101: temperature], at: measured)
        cache.update([101: failed], at: measured.addingTimeInterval(30))
        require(cache.values[101]?.text(at: measured.addingTimeInterval(30)) == "64°C · cached", "A failed query must retain a clearly marked last-known reading")
        require(cache.values[101]?.measuredAt == measured && cache.values[101]?.issue == "Sensor busy.", "A failed query must preserve the successful timestamp and explain the failure")
        require(TaskDiskTemperatureCache.retryNanoseconds(for: [101: failed]) == 5_000_000_000, "Failed sensors need an earlier retry")
        require(TaskDiskTemperatureCache.retryNanoseconds(for: [101: temperature]) == 30_000_000_000, "Healthy sensors keep the normal interval")
        require(TaskDiskTemperatureCache.retryNanoseconds(for: [:]) == 5_000_000_000, "A failed enumeration must retry promptly")
        let unsupported = TaskDiskTemperature(celsius: nil, measuredAt: measured, issue: "No sensor.", retryable: false)
        require(TaskDiskTemperatureCache.retryNanoseconds(for: [102: unsupported]) == 30_000_000_000, "Unsupported devices must not trigger frequent requests")
        let recovered = TaskDiskTemperature(celsius: 62, measuredAt: measured.addingTimeInterval(35))
        cache.update([101: recovered], at: measured.addingTimeInterval(35))
        require(cache.values[101]?.text(at: measured.addingTimeInterval(35)) == "62°C" && cache.values[101]?.issue == nil,
                "A successful retry must replace the cached value and clear its warning")
        cache.update([102: unsupported], at: measured.addingTimeInterval(40))
        require(cache.values[101] == nil && cache.values[102]?.celsius == nil, "Removed devices must not retain temperatures or transfer them to a replacement")
        cache.update([101: temperature], at: measured)
        cache.update([:], at: measured.addingTimeInterval(30))
        require(cache.values[101]?.text(at: measured.addingTimeInterval(30)) == "64°C · cached", "Enumeration failure must mark retained readings cached")
        cache.update([101: failed], at: measured.addingTimeInterval(300))
        require(cache.values[101]?.text(at: measured.addingTimeInterval(300)) == "Unavailable", "Repeated failures must not extend a cached reading's lifetime")
        cache.update([101: temperature], at: measured)
        cache.update([:], at: measured.addingTimeInterval(300))
        require(cache.values.isEmpty, "Expired readings must not survive an enumeration failure")
        cache.update([101: temperature], at: measured)
        cache.update([101: failed], at: measured.addingTimeInterval(-1))
        require(cache.values[101]?.celsius == nil, "Clock rollback must discard future cached readings")
        print("PASS temperature recovery: transient failures, cached labels, original timestamps, retry intervals, expiry, removal and successful recovery")

        if let index = CommandLine.arguments.firstIndex(of: "--destination"), index + 1 < CommandLine.arguments.count {
            let target = DownloadDiskDestination.deviceID(URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            require(target != nil, "Expected a resolvable physical destination device")
            var live = TaskDiskAccumulator()
            _ = live.update(TaskDiskSampler.sample(), at: ProcessInfo.processInfo.systemUptime)
            try await Task.sleep(nanoseconds: 2_000_000_000)
            let matching = live.update(TaskDiskSampler.sample(), at: ProcessInfo.processInfo.systemUptime).filter { $0.sample.deviceID == target }
            require(matching.count == 1, "Destination ancestry must match exactly one physical counter source")
            let value = matching[0]
            let output: [String: Any] = ["destination_device_id":value.sample.deviceID,
                "read_bytes_per_second":value.readBytesPerSecond ?? -1, "write_bytes_per_second":value.writtenBytesPerSecond ?? -1]
            print("DESTINATION_RATES " + String(data: try JSONSerialization.data(withJSONObject: output, options: .sortedKeys), encoding: .utf8)!)
        }

        if CommandLine.arguments.contains("--sample") {
            var live = TaskDiskAccumulator()
            _ = live.update(TaskDiskSampler.sample(), at: ProcessInfo.processInfo.systemUptime)
            try await Task.sleep(nanoseconds: 2_000_000_000)
            let disks = live.update(TaskDiskSampler.sample(), at: ProcessInfo.processInfo.systemUptime)
            let temperatures = TaskDiskTemperatureSampler.sample()
            for disk in disks {
                print("LIVE \(disk.sample.name) [\(disk.detail)] read=\(TaskDiskRate.text(disk.readBytesPerSecond)) write=\(TaskDiskRate.text(disk.writtenBytesPerSecond)) temperature=\(temperatures[disk.sample.deviceID]?.text() ?? "Unavailable")")
                if let reading = temperatures[disk.sample.deviceID], reading.celsius == nil { print("SENSOR STATUS \(disk.sample.device): \(reading.help)") }
            }
            require(!disks.isEmpty, "Expected physical drives on this Mac")
            require(Set(disks.map(\.id)).count == disks.count, "A physical drive must be counted once")
        }
    }
}

private final class DownloadRateFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var count: UInt64 = 0
    var calls: UInt64 { lock.lock(); defer { lock.unlock() }; return count }
    func sample() -> [TaskDiskSample] {
        lock.lock(); count += 1; let value = count; lock.unlock()
        return [DiskResourceMonitorTests.disk(1, read: value * 10_000, write: value * 20_000),
                DiskResourceMonitorTests.disk(2, read: value * 40_000, write: value * 50_000)]
    }
}
