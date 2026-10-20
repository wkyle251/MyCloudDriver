import AppKit

/// Native menu tracking must finish before SwiftUI rebuilds its commands.
/// Use both AppKit notifications and the run-loop mode: menu-bar tracking does
/// not deliver the same notifications as pop-up menus on every macOS version.
@MainActor final class FinderCommandPublication {
    private let notificationCenter: NotificationCenter
    private let publish: () -> Void
    private var observers: [NSObjectProtocol] = []
    private var trackingMenus = Set<ObjectIdentifier>()
    private var pending = false
    private var scheduled = false

    init(notificationCenter: NotificationCenter = .default, publish: @escaping () -> Void) {
        self.notificationCenter = notificationCenter
        self.publish = publish
        observers.append(notificationCenter.addObserver(forName: NSMenu.didBeginTrackingNotification,
            object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let menu = notification.object as? NSMenu else { return }
                    self?.trackingMenus.insert(ObjectIdentifier(menu))
                }
            })
        observers.append(notificationCenter.addObserver(forName: NSMenu.didEndTrackingNotification,
            object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, let menu = notification.object as? NSMenu else { return }
                    self.trackingMenus.remove(ObjectIdentifier(menu))
                    self.schedule()
                }
            })
    }

    func request() { pending = true; schedule() }

    private func schedule() {
        guard pending, !scheduled, trackingMenus.isEmpty else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in self?.flush() }
    }

    private func flush() {
        guard trackingMenus.isEmpty else { scheduled = false; return }
        if RunLoop.main.currentMode == .eventTracking {
            // DispatchQueue.main also runs inside AppKit's tracking loop.
            // A default-mode block waits for that loop to exit without polling.
            RunLoop.main.perform(inModes: [.default]) { [weak self] in
                MainActor.assumeIsolated { self?.flush() }
            }
            return
        }
        scheduled = false
        guard pending else { return }
        pending = false
        publish()
    }

    deinit { observers.forEach(notificationCenter.removeObserver) }
}
