import AppKit
import Darwin
import Foundation

/// Real helpers and isolated synthetic files exercise window ownership and the
/// same shutdown/recovery entry points used by AppDelegate.
@main struct SimilarityLifecycleTests {
    @MainActor final class Feed {
        var available = 1
        var resolved: [String: Int] = [:]
    }
    @MainActor static func until(_ condition: () -> Bool, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        precondition(condition(), "Timed out at line \(line)")
    }
    static func testClock() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var clock = SimilarityScanClock()
        clock.resume(at: start)
        clock.pause(at: start.addingTimeInterval(12))
        precondition(clock.elapsed(at: start.addingTimeInterval(3_600)) == 12)
        clock.pause(at: start.addingTimeInterval(3_601))
        clock.resume(at: start.addingTimeInterval(3_700))
        clock.resume(at: start.addingTimeInterval(3_705))
        precondition(clock.elapsed(at: start.addingTimeInterval(3_708)) == 20)
        clock.pause(at: start.addingTimeInterval(3_710))
        var recovered = SimilarityScanClock(elapsedSeconds: clock.elapsed(at: start.addingTimeInterval(90_000)))
        recovered.resume(at: start.addingTimeInterval(100_000))
        precondition(recovered.elapsed(at: start.addingTimeInterval(100_003)) == 25)
        print("PASS active timer excludes pauses and time offline; repeated pause/resume is idempotent")
    }
    @MainActor static func main() async throws {
        testClock()
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let suite = "com.wky.MyCloudDriver.SimilarityLifecycleTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite).resolvingSymlinksInPath()
        let inputs = root.appendingPathComponent("inputs")
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let content = String(repeating: "A garden with trees, flowers and a green lawn. ", count: 30)
        for name in ["one.txt", "two.txt", "three.txt"] { try content.write(to: inputs.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let config = SimilarityConfiguration(executable: resources.appendingPathComponent("pikpak"), models: resources.appendingPathComponent("FileTwinModels"),
            worker: resources.appendingPathComponent("filetwin-worker"), dataDirectory: root.appendingPathComponent("data"),
            temporaryDirectory: root.appendingPathComponent("temp"), environment: [:])
        func hub(_ id: String, settings: FinderSettings? = nil) -> CloudDriveHub {
            CloudDriveHub(pikpak: DownloaderModel.finderWorkspaceFixture(defaults: defaults, workspaceSessionID: id, settings: settings),
                defaults: defaults, restoreConnections: false,
                photosAccess: .init(status: { .denied }, request: { .denied }, provider: { PhotosDriveProvider() }), localRootURL: inputs)
        }
        func configure(_ owner: FileSimilarityCoordinator, feed: Feed) {
            owner.configuration = { _ in config }
            let scan = owner.local
            scan.externalTitle = "Test Drive"; scan.externalScopeNames = ["Synthetic files"]; scan.localURLs = [inputs]; scan.families = ["text"]
            scan.streamExternalSources = { emit in
                for (index, name) in ["one.txt", "two.txt", "three.txt"].enumerated() {
                    while index >= feed.available { try await Task.sleep(nanoseconds: 20_000_000) }
                    let url = inputs.appendingPathComponent(name)
                    try await emit(.init(id: name, name: name, path: url.path, size: UInt64(content.utf8.count), localPath: url.path))
                }
            }
            scan.resolveExternalSource = { id, _, _ in
                feed.resolved[id, default: 0] += 1
                return inputs.appendingPathComponent(id)
            }
        }
        let primaryHub = hub("primary")
        let manager = WorkspaceSessionManager(initialHub: primaryHub, makeHub: { hub($0, settings: $1) })
        manager.presentsWindows = false
        var lastCloses = 0
        manager.lastWindowClosedForTesting = { lastCloses += 1 }
        let browser = NSWindow(contentRect: .init(x: 0, y: 0, width: 1_000, height: 700),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        browser.isReleasedWhenClosed = false
        manager.register(browser, hub: primaryHub)
        let owner = primaryHub.local.similarity, feed = Feed(), scan = owner.local
        configure(owner, feed: feed)
        owner.present(source: .local)
        let scanWindow = primaryHub.pikpak.fileSimilarity.presentedWindow!
        scanWindow.orderOut(nil)
        owner.start(scan)
        try await until { scan.progress.analysed == 1 }
        try await until { scan.savedSession!.elapsedSeconds >= 5 }
        let checkpoint = SimilaritySessionStore.directory(config, id: scan.savedSession!.id)
        let heartbeat = try JSONDecoder().decode(SimilaritySavedSession.self, from: Data(contentsOf: checkpoint.appendingPathComponent("session.json")))
        precondition(heartbeat.activeElapsedSeconds != nil && heartbeat.elapsedSeconds >= 5, "Long-running scans checkpoint the timer before shutdown")
        let pid = scan.processIdentifier!, sessionID = scan.savedSession!.id
        browser.close()
        precondition(manager.workspaceCount == 0 && lastCloses == 0 && scan.isRunning && scan.processIdentifier == pid)
        precondition(primaryHub.pikpak.fileSimilarity.presentedWindow === scanWindow)
        feed.available = 2
        try await until { scan.progress.analysed == 2 }
        precondition(scan.processIdentifier == pid && !scan.isPaused, "Analysis must continue after the browser closes")
        // The closed view reserves its slot so the scan's browser can come back
        // in place. Additional browsers own independent workspace state; focus
        // on the scan must still return to its original hub and running helper.
        manager.activateBrowser(in: primaryHub)
        let reopened = manager.windowForTesting("primary")!
        precondition(reopened !== browser && manager.workspaceCount == 1 && manager.activeHub === primaryHub)
        manager.newWindow()
        let secondary = manager.windowForTesting("secondary")!
        let secondaryHub = manager.hubForTesting("secondary")!
        precondition(manager.workspaceCount == 2 && secondary !== reopened && secondaryHub !== primaryHub)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: secondary)
        precondition(manager.activeHub === secondaryHub && manager.canPresentSimilarity)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: scanWindow)
        precondition(manager.activeHub === primaryHub && manager.canPresentSimilarity)
        precondition(scan.processIdentifier == pid && !scan.isPaused, "Reopening views must not disturb the running scan")
        reopened.close(); secondary.close()
        precondition(manager.workspaceCount == 0 && lastCloses == 0 && scan.isRunning)
        print("PASS browser close keeps the same scan helper processing; restoring its browser and focusing independent windows preserve scan ownership")

        scan.pause()
        let pausedElapsed = scan.elapsedSeconds(at: Date())
        try await until { scan.isPaused && !scan.isRunning }
        precondition(scan.elapsedSeconds(at: Date().addingTimeInterval(86_400)) == pausedElapsed)
        precondition(scan.savedSession?.activeElapsedSeconds == pausedElapsed)
        owner.resume(scan)
        precondition(scan.processIdentifier == pid && scan.elapsedSeconds(at: Date()) >= pausedElapsed)
        precondition(scan.elapsedSeconds(at: Date().addingTimeInterval(60)) >= pausedElapsed + 60)
        manager.closeAll()
        try await until { scan.processIdentifier == nil && !scan.isRunning }
        precondition(kill(pid, 0) != 0 && scan.isPaused && lastCloses == 0)
        let available = SimilaritySessionStore.available(config, source: .local)
        let saved = available.first { $0.id == sessionID }!
        precondition(saved.activeElapsedSeconds != nil && saved.elapsedSeconds >= pausedElapsed)
        precondition(scan.elapsedSeconds(at: Date().addingTimeInterval(86_400)) == saved.elapsedSeconds)
        print("PASS Quit saves active time and completed work, stops the helper, and releases the recovery claim")

        var legacyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as! [String: Any]
        legacyJSON.removeValue(forKey: "activeElapsedSeconds")
        legacyJSON["startedAt"] = 1_000.0; legacyJSON["updatedAt"] = 1_300.0
        let legacy = try JSONDecoder().decode(SimilaritySavedSession.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        precondition(legacy.activeElapsedSeconds == nil && legacy.elapsedSeconds == 300)
        let afterQuit = FileSimilarityCoordinator(activity: FinderTaskActivityStore()), recoveredFeed = Feed()
        recoveredFeed.available = 3; configure(afterQuit, feed: recoveredFeed)
        afterQuit.refreshRecovery()
        afterQuit.resume(afterQuit.local, session: afterQuit.local.recoverableSessions.first { $0.id == sessionID }!)
        precondition(afterQuit.local.elapsedSeconds(at: Date()) >= saved.elapsedSeconds)
        precondition(afterQuit.local.elapsedSeconds(at: Date()) < saved.elapsedSeconds + 2)
        try await until { !afterQuit.local.isRunning }
        let report = afterQuit.local.report!
        precondition(report.analysedFiles == 3 && !afterQuit.local.isPaused)
        precondition(recoveredFeed.resolved["one.txt"] == nil && recoveredFeed.resolved["two.txt"] == nil && recoveredFeed.resolved["three.txt"] == 1)
        precondition(report.elapsedSeconds == afterQuit.local.elapsedSeconds(at: Date().addingTimeInterval(86_400)))
        precondition(SimilaritySessionStore.loadReport(config, id: sessionID)?.elapsedSeconds == report.elapsedSeconds)
        afterQuit.local.clearSession()
        print("PASS a fresh coordinator resumes the saved session without fetching completed files; final report preserves cumulative active time; older descriptors remain readable")

        let closingHub = hub("primary"), closingFeed = Feed()
        let closingManager = WorkspaceSessionManager(initialHub: closingHub)
        closingManager.presentsWindows = false
        var finalCloses = 0
        closingManager.lastWindowClosedForTesting = { finalCloses += 1 }
        let closingBrowser = NSWindow(contentRect: .init(x: 0, y: 0, width: 1_000, height: 700),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        closingBrowser.isReleasedWhenClosed = false
        closingManager.register(closingBrowser, hub: closingHub)
        let closingOwner = closingHub.local.similarity, closingScan = closingOwner.local
        configure(closingOwner, feed: closingFeed)
        closingOwner.present(source: .local)
        closingHub.pikpak.fileSimilarity.presentedWindow!.orderOut(nil)
        closingOwner.start(closingScan)
        try await until { closingScan.progress.analysed == 1 }
        let closingID = closingScan.savedSession!.id
        closingBrowser.close()
        precondition(finalCloses == 0 && closingScan.isRunning)
        closingHub.pikpak.fileSimilarity.presentedWindow!.close()
        try await until { closingScan.processIdentifier == nil && !closingScan.isRunning }
        precondition(finalCloses == 1 && closingManager.workspaceCount == 0 && closingScan.isPaused)
        precondition(SimilaritySessionStore.available(config, source: .local).contains { $0.id == closingID })
        closingScan.clearSession()
        print("PASS closing the final scan window saves the orphaned workspace and requests app termination exactly once")
    }
}
