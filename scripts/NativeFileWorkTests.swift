import Foundation

private final class WorkCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private(set) var peak = 0
    private(set) var started = 0
    private(set) var stopped = 0
    func begin() { lock.lock(); active += 1; started += 1; peak = max(peak, active); lock.unlock() }
    func end() { lock.lock(); active -= 1; stopped += 1; lock.unlock() }
    var snapshot: (Int, Int, Int) { lock.lock(); defer { lock.unlock() }; return (peak, started, stopped) }
}

@main struct NativeFileWorkTests {
    static func wait(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !condition() {
            precondition(ProcessInfo.processInfo.systemUptime < deadline)
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    static func main() async throws {
        setbuf(stdout, nil)
        let counters = WorkCounters(), release = DispatchSemaphore(value: 0)
        let jobs = (0..<20).map { _ in Task {
            do {
                return try await NativeFileWork.run(timeout: 0.15) {
                    counters.begin(); release.wait(); counters.end(); return 1
                }
            } catch NativeFileWorkFailure.timedOut { return 0 }
        } }
        try await wait { counters.snapshot.1 == 4 }
        let start = ProcessInfo.processInfo.systemUptime
        for job in jobs { let value = try await job.value; precondition(value == 0) }
        precondition(ProcessInfo.processInfo.systemUptime - start < 1)
        precondition(counters.snapshot.0 == 4 && counters.snapshot.1 == 4,
                     "Timed-out queued requests must not begin, and blocked workers must remain bounded")
        for _ in 0..<4 { release.signal() }
        try await wait { counters.snapshot.2 == 4 }
        let resumed = try await NativeFileWork.run { 42 }; precondition(resumed == 42)
        print("PASS deadlines release callers; blocked storage is bounded and canceled queued work is skipped")

        let entered = WorkCounters(), leave = DispatchSemaphore(value: 0)
        let cancelled = Task {
            try await NativeFileWork.run(timeout: 10) { entered.begin(); leave.wait(); entered.end(); return 5 }
        }
        // Wait without blocking Swift's cooperative executor.
        try await wait { entered.snapshot.1 == 1 }
        let cancelTime = ProcessInfo.processInfo.systemUptime
        cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("Cancellation must win") }
        catch is CancellationError { }
        precondition(ProcessInfo.processInfo.systemUptime - cancelTime < 0.5)
        leave.signal()
        print("PASS cancellation resumes without waiting for a blocked syscall")

        let hook = WorkCounters(), hookRelease = DispatchSemaphore(value: 0)
        let hookWork = WorkCounters(), hookWorkRelease = DispatchSemaphore(value: 0)
        let withHook = Task {
            try await NativeFileWork.run(onCancel: { hook.begin(); hookRelease.wait(); hook.end() }) {
                hookWork.begin(); hookWorkRelease.wait(); hookWork.end(); return 1
            }
        }
        try await wait { hookWork.snapshot.1 == 1 }
        let hookCancelTime = ProcessInfo.processInfo.systemUptime
        withHook.cancel()
        do { _ = try await withHook.value; preconditionFailure("Cancellation must win") }
        catch is CancellationError { }
        precondition(ProcessInfo.processInfo.systemUptime - hookCancelTime < 0.5)
        try await wait { hook.snapshot.1 == 1 }
        hookRelease.signal(); hookWorkRelease.signal()
        print("PASS even a blocked provider cancellation hook cannot block the UI caller")

        let closes = WorkCounters(), closeRelease = DispatchSemaphore(value: 0), memory = WorkCounters()
        for _ in 0..<2 { NativeFileWork.performDescriptorCleanup { closes.begin(); closeRelease.wait(); closes.end() } }
        try await wait { closes.snapshot.1 == 2 }
        NativeFileWork.performMemoryCleanup { memory.begin(); memory.end() }
        try await wait { memory.snapshot.2 == 1 }
        closeRelease.signal(); closeRelease.signal()
        print("PASS stalled network closes cannot hold up preview RAM release")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NativeFileWork-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("owned")
        let writerStarted = WorkCounters()
        let writer = Task {
            let lease = NativePreviewDirectory(directory)
            return try await NativeFileWork.asyncRun(timeout: 0.08) {
                try FileManager.default.createDirectory(at: lease.url, withIntermediateDirectories: false)
                writerStarted.begin()
                // An external provider can ignore cancellation while writing.
                await Task.detached { try? await Task.sleep(nanoseconds: 250_000_000) }.value
                precondition(FileManager.default.fileExists(atPath: lease.url.path))
                try Data("generated".utf8).write(to: lease.url.appendingPathComponent("generated"))
                writerStarted.end()
                return true
            }
        }
        do { _ = try await writer.value; preconditionFailure("Writer must time out") }
        catch NativeFileWorkFailure.timedOut { }
        precondition(FileManager.default.fileExists(atPath: directory.path), "Live writer retains its directory")
        try await wait { writerStarted.snapshot.2 == 1 && !FileManager.default.fileExists(atPath: directory.path) }
        print("PASS timed-out provider retains staging until its late writer finishes, then cleanup runs")
    }
}
