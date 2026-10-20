import AppKit

/// Exercises AppKit's actual tracking run-loop mode without user files or input.
@main @MainActor struct FinderCommandPublicationTests {
    static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Timer.scheduledTimer(withTimeInterval: 0.01, repeats: false) { _ in
            MainActor.assumeIsolated { run(); exit(0) }
        }
        app.run()
    }

    static func pump(_ mode: RunLoop.Mode, seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { _ = RunLoop.main.run(mode: mode, before: end) }
    }

    static func run() {
        let center = NotificationCenter()
        var publications = 0, dispatchDuringTracking = 0
        let publication = FinderCommandPublication(notificationCenter: center) { publications += 1 }
        let timer = Timer(timeInterval: 0.005, repeats: false) { _ in
            MainActor.assumeIsolated {
                precondition(RunLoop.main.currentMode == .eventTracking)
                for _ in 0..<100 { publication.request() }
                DispatchQueue.main.async {
                    if RunLoop.main.currentMode == .eventTracking { dispatchDuringTracking += 1 }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        pump(.eventTracking, seconds: 0.1)
        precondition(dispatchDuringTracking == 1, "The fixture must actually drain DispatchQueue.main during native tracking")
        precondition(publications == 0, "Menu-bar tracking without notifications must still block command rebuilding")
        pump(.default, seconds: 0.05)
        precondition(publications == 1, "Tracking exit must publish pending validation once")
        print("PASS native event tracking: 100 updates wait for the default run loop, including when AppKit sends no menu notification")

        let parent = NSMenu(title: "View"), child = NSMenu(title: "Preview Placement")
        center.post(name: NSMenu.didBeginTrackingNotification, object: parent)
        center.post(name: NSMenu.didBeginTrackingNotification, object: child)
        publication.request()
        center.post(name: NSMenu.didEndTrackingNotification, object: child)
        pump(.default, seconds: 0.03)
        precondition(publications == 1)
        center.post(name: NSMenu.didEndTrackingNotification, object: parent)
        pump(.default, seconds: 0.03)
        precondition(publications == 2)
        print("PASS nested native menus: closing a child keeps its parent stable; cancelling the parent resumes validation")

        var released: FinderCommandPublication? = FinderCommandPublication(notificationCenter: center) { publications += 1 }
        weak var weakPublication = released
        released?.request(); released = nil
        pump(.default, seconds: 0.03)
        precondition(weakPublication == nil && publications == 2)
        print("PASS publication teardown: queued refreshes do not retain or publish a released command owner")
    }
}
