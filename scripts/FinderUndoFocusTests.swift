// Standalone generated notification regression; compile with FinderFileUndo.swift.
import AppKit
import Combine
import Foundation

@main @MainActor struct FinderUndoFocusTests {
    static func until(_ check: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !check() && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        precondition(check(), "Generated undo focus fixture timed out")
    }
    static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run(); print("PASS generated undo focus notification suite"); exit(0) }
            catch { preconditionFailure("Generated undo focus fixture failed: \(error.localizedDescription)") }
        }
        app.run()
    }
    static func run() async throws {
        precondition(Thread.isMainThread)
        let window = NSWindow(contentRect: .init(x: 150, y: 150, width: 420, height: 220),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "Generated undo focus fixture"
        let editor = NSTextView(frame: .init(x: 0, y: 0, width: 420, height: 220))
        editor.string = "Generated editable text"; window.contentView = editor
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        defer { window.close() }
        try await until { window.isKeyWindow }
        precondition(window.makeFirstResponder(editor))
        let center = NotificationCenter(), focus = FinderUndoCommandFocus(notificationCenter: center)
        var updating = false, synchronous = 0, publications = 0
        let observation = focus.objectWillChange.sink {
            publications += 1
            if updating { synchronous += 1 }
        }
        defer { observation.cancel() }
        precondition(focus.editor === editor && !focus.allowsFileActions)
        updating = true
        for _ in 0..<10 {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                         NSText.didBeginEditingNotification, NSText.didEndEditingNotification, NSText.didChangeNotification] {
                center.post(name: name, object: editor)
            }
        }
        precondition(window.makeFirstResponder(nil))
        precondition(focus.editor == nil && focus.allowsFileActions,
            "Command validation must read current native focus before its deferred publication")
        updating = false
        precondition(synchronous == 0 && publications == 0, "Notification callbacks must not publish during an update")
        try await until { publications == 1 }
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(publications == 1, "A burst of focus/editing notifications must coalesce")
        updating = true; center.post(name: NSText.didChangeNotification, object: editor); updating = false
        precondition(publications == 1)
        try await until { publications == 2 }
        precondition(synchronous == 0)
        print("PASS50 focus/editing notifications defer and coalesce; fresh focus validation remains immediate and publication rearms")

        let pendingCenter = NotificationCenter()
        var pending: FinderUndoCommandFocus? = FinderUndoCommandFocus(notificationCenter: pendingCenter)
        weak var released = pending
        var droppedPublications = 0
        let pendingObservation = pending!.objectWillChange.sink { droppedPublications += 1 }
        pendingCenter.post(name: NSWindow.didBecomeKeyNotification, object: window)
        pending = nil
        precondition(released == nil, "Queued focus invalidation must not retain the command observer")
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(droppedPublications == 0, "A deallocated observer must not publish a queued change")
        pendingObservation.cancel()
        print("PASS pending focus publication holds only a weak owner and teardown removes observers")
    }
}
