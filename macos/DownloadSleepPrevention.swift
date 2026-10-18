import Foundation

/// Each workspace owns its activity, so pausing one cannot release another's.
/// Full-wake work prevents idle system/display sleep and background App Nap.
@MainActor
final class DownloadSleepPrevention {
    private var activity: NSObjectProtocol?
    private let begin: () -> NSObjectProtocol
    private let end: (NSObjectProtocol) -> Void
    private let recordActivity: (Bool) -> Void

    static func activityOptions(fullWake: Bool) -> ProcessInfo.ActivityOptions {
        fullWake ? [.userInitiated, .idleDisplaySleepDisabled] : [.idleSystemSleepDisabled]
    }

    init(fullWake: Bool = true,
         reason: String = "MyCloudDriver is downloading or saving and verifying downloaded data",
         begin: (() -> NSObjectProtocol)? = nil, end: @escaping (NSObjectProtocol) -> Void = {
        ProcessInfo.processInfo.endActivity($0)
    }, recordActivity: ((Bool) -> Void)? = nil) {
        let options = Self.activityOptions(fullWake: fullWake)
        self.begin = begin ?? { ProcessInfo.processInfo.beginActivity(options: options, reason: reason) }
        self.end = end
        if let recordActivity { self.recordActivity = recordActivity }
        else if fullWake, begin == nil, Bundle.main.bundleIdentifier == "com.wky.PikPakDownloader" {
            let owner = UUID()
            self.recordActivity = { FullWakeWorkMonitor.shared.setActive($0, owner: owner) }
        } else { self.recordActivity = { _ in } }
    }

    var isActive: Bool { activity != nil }

    func setActive(_ active: Bool) {
        if active {
            if activity == nil { activity = begin(); recordActivity(true) }
        } else if let token = activity {
            activity = nil
            end(token)
            recordActivity(false)
        }
    }

    deinit {
        if let activity { end(activity); recordActivity(false) }
    }
}

/// Numeric, app-wide heartbeat for the optional AC/closed-lid wake guard.
/// Its worker never waits on the main actor or persists names, paths or tokens.
final class FullWakeWorkMonitor: @unchecked Sendable {
    static let shared = FullWakeWorkMonitor(directory: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/MyCloudDriver/Downloads", isDirectory: true))
    private let queue = DispatchQueue(label: "com.wky.MyCloudDriver.full-wake-monitor", qos: .utility)
    private let directory: URL
    private let processID: Int32
    private let interval: TimeInterval
    private let clock: @Sendable () -> Date
    private var owners = Set<UUID>()
    private var timer: DispatchSourceTimer?

    init(directory: URL, processID: Int32 = ProcessInfo.processInfo.processIdentifier,
         interval: TimeInterval = 1, clock: @escaping @Sendable () -> Date = Date.init) {
        self.directory = directory; self.processID = processID
        self.interval = max(0.05, interval); self.clock = clock
    }
    func setActive(_ active: Bool, owner: UUID) {
        queue.async { [self] in
            if active { owners.insert(owner) } else { owners.remove(owner) }
            if !owners.isEmpty && timer == nil {
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(50))
                timer.setEventHandler { [weak self] in self?.publish() }
                self.timer = timer; timer.resume()
            } else if owners.isEmpty {
                timer?.cancel(); timer = nil
            }
            publish()
        }
    }
    func waitForPendingWrites() { queue.sync {} }

    private func publish() {
        let snapshot: [String: Any] = ["version": 1, "app_pid": processID,
            "updated_at": clock().timeIntervalSince1970, "active_work_count": owners.count]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let url = directory.appendingPathComponent("awake-work-state-v1.json")
            try JSONSerialization.data(withJSONObject: snapshot).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { /* Stale/unavailable heartbeat is handled by the guard's bounded grace. */ }
    }
    deinit { timer?.cancel() }
}
