import Foundation

/// No live devices, accounts or files: inject generated counters and a blocked
/// temperature reader to verify task attribution and the monitor's lifecycle.
@main struct TaskDiskResourceTests {
    static func process(_ pid: Int32, parent: Int32 = 500, started: UInt64 = 1,
                        read: UInt64? = 0, write: UInt64? = 0) -> TaskProcessSample {
        .init(pid: pid, name: "Generated helper", started: started, cpuNanoseconds: 0,
              residentBytes: 1_024, threads: 1, parentPID: parent,
              diskReadBytes: read, diskWrittenBytes: write)
    }

    @MainActor static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        fatalError("Timed out waiting for the generated monitor")
    }

    @MainActor static func main() async throws {
        var accumulator = TaskResourceAccumulator()
        let samples = [process(500, parent: 1), process(501), process(502, parent: 501)]
        let first = accumulator.update(samples, at: 1)
        precondition(first.allSatisfy { $0.diskReadBytesPerSecond == nil && $0.diskWrittenBytesPerSecond == nil })
        let measured = accumulator.update([process(500, parent: 1, read: 20, write: 40),
                                          process(501, read: 60, write: 80),
                                          process(502, parent: 501, read: 100, write: 120)], at: 3)
        let groups = TaskResourceAttribution.group(measured, activities: [501: .init(name: "Download")], rootPID: 500)
        let helper = groups.first { $0.id == 501 }!
        let app = groups.first { $0.id == 500 }!
        precondition(helper.processIDs == [501, 502] && helper.diskReadBytesPerSecond == 80 && helper.diskWrittenBytesPerSecond == 100,
                     "Nested helpers must be counted once in their owning task")
        precondition(app.diskReadBytesPerSecond == 10 && app.diskWrittenBytesPerSecond == 20,
                     "App I/O must remain separate from the named task")
        let reused = accumulator.update([process(501, started: 2, read: 1_000_000, write: 2_000_000)], at: 5)[0]
        precondition(reused.diskReadBytesPerSecond == nil && reused.diskWrittenBytesPerSecond == nil, "PID reuse needs a fresh baseline")
        let unknown = accumulator.update([process(501, started: 2, read: nil, write: 2_000_020)], at: 7)[0]
        precondition(unknown.diskReadBytesPerSecond == nil && unknown.diskWrittenBytesPerSecond == 10, "Unknown process reads must not become zero")
        let missingChild = TaskResourceRow(pid: 502, name: "Generated child", cpuPercent: 0,
            residentBytes: 1_024, threads: 1, parentPID: 501, diskReadBytesPerSecond: nil, diskWrittenBytesPerSecond: 0)
        let partial = TaskResourceAttribution.group([measured[1], missingChild], activities: [501: .init(name: "Download")], rootPID: 500)[0]
        precondition(partial.diskReadBytesPerSecond == nil, "An unavailable member must not turn into an understated task total")
        print("PASS task disk I/O: elapsed rates, nested attribution, PID reuse and unavailable accounting")

        let fixture = SensorFixture()
        defer { fixture.release.signal() }
        let monitor = TaskResourceMonitor(sample: {
            ([process(500, parent: 1)], [], [.init(id: 1, deviceID: 101, name: "Generated disk", device: "disk9",
                                                location: "External", interconnect: "USB", medium: "HDD", readBytes: 0, writtenBytes: 0)])
        }, sampleTemperatures: { fixture.sample() })
        let firstWatch = Task { await monitor.watch() }
        try await waitUntil { monitor.sampledAt != nil && fixture.started }
        precondition(monitor.rows.count == 1 && monitor.disks.count == 1 && monitor.temperaturesSampledAt == nil,
                     "Slow SMART queries must not block kernel counter updates")
        firstWatch.cancel()
        await firstWatch.value
        precondition(monitor.rows.isEmpty && monitor.disks.isEmpty && monitor.diskTemperatures.isEmpty,
                     "Closing Resources must immediately clear live samples")

        let secondWatch = Task { await monitor.watch() }
        try await waitUntil { monitor.diskTemperatures[101]?.celsius == 42 }
        fixture.release.signal()
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(monitor.diskTemperatures[101]?.celsius == 42 && monitor.sampledAt != nil,
                     "A late temperature result from a closed pane must not overwrite its replacement")
        secondWatch.cancel()
        await secondWatch.value
        precondition(monitor.sampledAt == nil && monitor.temperaturesSampledAt == nil,
                     "Cancellation must clear sample timestamps as well as values")
        let calls = fixture.calls
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(fixture.calls == calls, "Hidden Resources must not keep polling sensors")
        print("PASS monitoring lifecycle: slow sensors, responsive counters, cancellation, stale-result rejection and no hidden polling")
        if CommandLine.arguments.contains("--sample") {
            let own = TaskResourceSampler.sample().first { $0.pid == getpid() }
            precondition(own?.diskReadBytes != nil && own?.diskWrittenBytes != nil,
                         "macOS process disk accounting must be readable for the app")
            print("PASS live process accounting: app disk byte counters available")
        }
    }
}

private final class SensorFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let release = DispatchSemaphore(value: 0)
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    var started: Bool { calls > 0 }
    func sample() -> [UInt64: TaskDiskTemperature] {
        lock.lock(); count += 1; let invocation = count; lock.unlock()
        if invocation == 1 { _ = release.wait(timeout: .now() + 5) }
        return [101: .init(celsius: invocation == 1 ? 64 : 42, measuredAt: Date())]
    }
}
