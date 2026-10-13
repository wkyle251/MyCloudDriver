import Foundation

/// Each workspace owns its activity, so pausing one cannot release another's.
/// The display may sleep; only automatic idle system sleep is disabled.
@MainActor
final class DownloadSleepPrevention {
    private var activity: NSObjectProtocol?
    private let begin: () -> NSObjectProtocol
    private let end: (NSObjectProtocol) -> Void

    init(begin: @escaping () -> NSObjectProtocol = {
        ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled],
            reason: "MyCloudDriver is downloading or saving and verifying downloaded data")
    }, end: @escaping (NSObjectProtocol) -> Void = {
        ProcessInfo.processInfo.endActivity($0)
    }) {
        self.begin = begin
        self.end = end
    }

    var isActive: Bool { activity != nil }

    func setActive(_ active: Bool) {
        if active {
            if activity == nil { activity = begin() }
        } else if let token = activity {
            activity = nil
            end(token)
        }
    }

    deinit {
        if let activity { end(activity) }
    }
}
