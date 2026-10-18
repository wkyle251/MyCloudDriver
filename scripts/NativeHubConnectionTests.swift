import AppKit
import Foundation
import Photos

private final class ConnectionWorkers: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let release = DispatchSemaphore(value: 0)
    var started: Int { lock.lock(); defer { lock.unlock() }; return count }
    func block() {
        lock.lock(); count += 1; lock.unlock()
        precondition(release.wait(timeout: .now() + 5) == .success)
    }
    func finish() { for _ in 0..<4 { release.signal() } }
}

@main @MainActor struct NativeHubConnectionTests {
    static func until(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !condition() {
            precondition(ProcessInfo.processInfo.systemUptime < deadline, "Generated connection did not settle")
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    private static func occupy(_ workers: ConnectionWorkers) async throws -> [Task<Void, Error>] {
        let jobs = (0..<4).map { _ in Task { try await NativeFileWork.run { workers.block() } } }
        try await until { workers.started == 4 }
        return jobs
    }
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("NativeHubConnection-\(UUID().uuidString)", isDirectory: true)
        let a = root.appendingPathComponent("A", isDirectory: true), b = root.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        try Data("generated A".utf8).write(to: a.appendingPathComponent("A.txt"))
        try Data("generated B".utf8).write(to: b.appendingPathComponent("B.txt"))
        defer { try? FileManager.default.removeItem(at: root) }
        let domain = "NativeHubConnection.\(UUID().uuidString)", defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }

        let workers = ConnectionWorkers(); defer { workers.finish() }
        let jobs = try await occupy(workers)
        let hub = CloudDriveHub(pikpak: DownloaderModel.finderWorkspaceFixture(defaults: defaults), defaults: defaults,
            restoreConnections: false,
            photosAccess: .init(status: { .notDetermined }, request: { .denied }, provider: { PhotosDriveProvider() }),
            localRootURL: a)
        defer { hub.close() }
        precondition(hub.local.isLoading && hub.local.provider == nil)
        hub.open(.local)
        precondition(hub.local.isLoading, "Opening Local Disk must not cancel its initial background connection")
        precondition(hub.connectLocalFolder(b, remember: false))
        for _ in 0..<5 { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(hub.local.isLoading && hub.local.provider == nil)
        workers.finish(); for job in jobs { try await job.value }
        try await until { !hub.local.isLoading }
        precondition(hub.local.provider?.root.url?.path == b.path && hub.local.items.map(\.name) == ["B.txt"])
        print("PASS pending initial/replacement connections leave UI responsive and publish only the newest generated root")

        precondition(hub.connectLocalFolder(root.appendingPathComponent("Missing"), remember: false))
        try await until { !hub.local.isLoading }
        precondition(hub.connectionError != nil && hub.local.provider?.root.url?.path == b.path,
                     "Failed validation must preserve the connected root")
        precondition(hub.connectLocalFolder(a, remember: false, volumeID: "wrong-generated-volume"))
        try await until { !hub.local.isLoading }
        precondition(hub.connectionError != nil && hub.local.provider?.root.url?.path == b.path)
        print("PASS missing or replaced disks cannot replace a previously connected provider")

        let closeWorkers = ConnectionWorkers(); defer { closeWorkers.finish() }
        let closeJobs = try await occupy(closeWorkers)
        precondition(hub.connectLocalFolder(a, remember: false))
        hub.close(); closeWorkers.finish()
        for job in closeJobs { try await job.value }
        try await Task.sleep(nanoseconds: 50_000_000)
        precondition(hub.local.provider?.root.url?.path == b.path,
                     "Closing the workspace must discard pending provider construction")
        print("PASS workspace close rejects late background connections")
    }
}
